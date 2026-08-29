# 自宅の Ubuntu マシンを KVM ホストにして kubeadm + Ansible で Kubernetes クラスタを立てる

<!--
Qiita 投稿用ドラフト。タグ候補: Kubernetes, kubeadm, KVM, libvirt, Ansible
リポジトリ: https://github.com/<your-account>/homelab-k8s
-->

## この記事でやること

- 手元の Ubuntu 24.04 マシン 1 台を **KVM ホスト**にする
- cloud-init で Ubuntu の VM を払い出す
- **kubeadm + Ansible** で single node の Kubernetes クラスタを構築する
- あとから **worker ノードを追加**してスケールアウトする
- **Mac から Headlamp（GUI）** でクラスタを見る

すべてスクリプト化してあるので、リポジトリを clone すれば再現できる。

```
homelab-k8s/
├── config.env.example          環境依存の設定（コピーして使う）
├── scripts/
│   ├── 01-install-kvm-host.sh   KVM ホスト初期化
│   ├── 02-create-node-vm.sh     VM を 1 台作成（cloud-init）
│   ├── 03-destroy-node-vm.sh    VM を削除
│   └── 40-expose-console.sh     ホストの LAN ポート → NodePort へ転送
├── ansible/
│   ├── inventory.ini.example
│   ├── group_vars/all.yml       K8s バージョン・CNI・Pod CIDR
│   ├── site.yml
│   └── playbooks/
│       ├── 10-common.yml        全ノード共通（containerd, kubeadm ...）
│       ├── 20-control-plane.yml kubeadm init + Flannel
│       ├── 30-workers.yml       kubeadm join
│       ├── 40-web-console.yml   Kubernetes Dashboard（任意）
│       └── 42-metrics-server.yml metrics-server（任意）
└── mac/                         Mac から見るための手順とスクリプト
```

## 前提環境

| 項目 | 値 |
|---|---|
| KVM ホスト | Ubuntu 24.04 / CPU 仮想化支援(VT-x か AMD-V)有効 / 空きメモリ 16GB+ |
| ゲスト | Ubuntu 24.04 cloud image |
| Kubernetes | v1.31（`pkgs.k8s.io`）|
| ランタイム / CNI | containerd + SystemdCgroup / Flannel |
| VM ネットワーク | libvirt `default`（NAT `192.168.122.0/24`）|
| 操作端末 | Mac（SSH で KVM ホストに接続）|

アドレス規約（`config.env` で変更可）:

- control-plane = `192.168.122.11`
- worker N = `192.168.122.(20 + N)` → `.21`, `.22`, …

## 1. KVM ホストのセットアップ

`scripts/01-install-kvm-host.sh` の中身は要するにこれだけ:

```bash
sudo apt-get install -y \
    qemu-kvm libvirt-daemon-system libvirt-clients \
    virtinst bridge-utils cloud-image-utils genisoimage \
    ansible python3-libvirt
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"
sudo virsh net-autostart default
```

```bash
git clone https://github.com/<your-account>/homelab-k8s.git ~/homelab-k8s
cd ~/homelab-k8s
cp config.env.example config.env
cp ansible/inventory.ini.example ansible/inventory.ini

./scripts/01-install-kvm-host.sh
newgrp libvirt      # グループ反映（or 再ログイン）
```

`kvm-ok` で `KVM acceleration can be used` が出れば OK。

## 2. cloud-init で VM を払い出す

`scripts/02-create-node-vm.sh` がやっていること:

1. Ubuntu cloud image をダウンロードしてコピー・リサイズ
2. VM 名から決定的に MAC を生成し、libvirt の `default` ネットワークに
   `MAC → 固定 IP` の DHCP 予約を追加
3. cloud-init の user-data を生成（`ubuntu` ユーザー + 公開鍵、swap 無効化）
4. `virt-install --import --cloud-init` で起動
5. SSH が通るまで待機

```bash
./scripts/02-create-node-vm.sh
#   → k8s-cp-1 / 192.168.122.11 / 4 vCPU / 8GB / 60GB
```

固定 IP の肝は「VM 名 → MAC を md5 で決定的に生成」しているところ。
作り直しても MAC が変わらないので DHCP 予約と一致する。

```bash
mac_for() {
    local h; h="$(echo -n "$1" | md5sum | cut -c1-6)"
    echo "52:54:00:${h:0:2}:${h:2:2}:${h:4:2}"
}
```

## 3. kubeadm + Ansible でクラスタ構築

`ansible/inventory.ini` は最初これだけ:

```ini
[control_plane]
k8s-cp-1 ansible_host=192.168.122.11

[workers]
# k8s-worker-1 ansible_host=192.168.122.21
```

```bash
cd ansible
ansible all -m ping
ansible-playbook site.yml
```

`site.yml` は 3 本の playbook を順に流す。

### 10-common.yml（全ノード共通）

- swap 無効化 / `overlay`・`br_netfilter` / sysctl（`bridge-nf-call-iptables`, `ip_forward`）
- `containerd` を入れて `containerd config default` → `SystemdCgroup = true`
- `pkgs.k8s.io` の apt リポジトリを追加して `kubelet kubeadm kubectl` を install & hold
- **`conntrack` `socat` `ethtool` も入れる**（後述）

### 20-control-plane.yml

```yaml
kubeadm init
  --pod-network-cidr=10.244.0.0/16
  --apiserver-advertise-address=192.168.122.11
  --cri-socket=unix:///run/containerd/containerd.sock
```

そのあと Flannel を `kubectl apply`、single node なら control-plane の
taint を外す、join コマンドを保存、`admin.conf` を手元に `fetch`。

### つまづきポイント: `conntrack not found`

初回は `kubeadm init` の preflight でこけた。

```
[ERROR FileExisting-conntrack]: conntrack not found in system path
```

cloud image には `conntrack` が入っていない。`10-common.yml` の
パッケージリストに `conntrack` / `socat` / `ethtool` を足して解決。

### 確認

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           AGE   VERSION
k8s-cp-1   Ready    control-plane   43s   v1.31.14
```

CoreDNS が `Running` になっていれば CNI も OK。

## 4. worker ノードを追加する

同じスクリプトを **ロール指定**で叩くだけ。

```bash
ROLE=worker NODE_NUM=1 ./scripts/02-create-node-vm.sh
#   → k8s-worker-1 / 192.168.122.21 / 2 vCPU / 4GB / 40GB
```

`inventory.ini` の `[workers]` に 1 行足して、

```bash
cd ansible && ansible-playbook site.yml   # 冪等なので再実行でOK
```

`30-workers.yml` が control-plane から join コマンドを取り、worker で実行する。

### taint を戻す

worker を分けたので、control-plane にアプリが載らないよう taint を戻したい。
`group_vars/all.yml` で `single_node_cluster: false` にすると
`20-control-plane.yml` が

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
```

を実行する（`true` なら逆に外す）。

```
$ kubectl get nodes
NAME           STATUS   ROLES           AGE
k8s-cp-1       Ready    control-plane   25m
k8s-worker-1   Ready    <none>          4m
```

## 5. Mac から Headlamp で見る

クラスタは NAT の中なので、Mac からは **KVM ホスト経由で API サーバに
トンネル**する。`mac/setup-headlamp-mac.sh` が:

1. `brew install --cask headlamp` / `brew install autossh`
2. トンネル用 kubeconfig（`server: 127.0.0.1:6443` / `tls-server-name`）を
   `~/.kube/config` に配置
3. `autossh -L 6443:192.168.122.11:6443 <KVMホスト>` を LaunchAgent 化
   （ログイン時に自動起動・切断時に自動復旧）

```bash
scp "<KVMホスト>:~/homelab-k8s/mac/setup-headlamp-mac.sh" .
HOST_SSH="<user@KVMホストIP>" REMOTE_REPO="~/homelab-k8s" ./setup-headlamp-mac.sh
```

あとは Headlamp.app を開くだけ。CPU/メモリのグラフを出すなら
`ansible-playbook playbooks/42-metrics-server.yml` で metrics-server も入れる
（kubeadm ノードは kubelet 証明書が自己署名なので `--kubelet-insecure-tls` が必要）。

### つまづきポイント: `launchctl load` が `Input/output error`

最近の macOS は `launchctl load/unload` が不安定。`bootstrap` を使う。

```bash
launchctl bootout   gui/$(id -u)/com.kvm-k8s.tunnel
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kvm-k8s.tunnel.plist
launchctl kickstart -k gui/$(id -u)/com.kvm-k8s.tunnel
```

### ブラウザで見たい場合（Kubernetes Dashboard）

`ansible-playbook playbooks/40-web-console.yml` で Dashboard + NodePort 30443 +
無期限トークンを作成。KVM ホストで `scripts/40-expose-console.sh add` を実行すると
`https://<KVMホストIP>:8443` でブラウザから開ける（iptables DNAT + systemd で永続化）。

## まとめ

- KVM ホスト初期化・VM 払い出し・kubeadm・worker 追加まで全部スクリプト化
- 環境依存の値は `config.env` 1 ファイルに集約、`inventory.ini` は IP だけ
- `site.yml` は冪等なので、ノード追加も設定変更も「再実行」で済む
- ハマったのは `conntrack` 不足、taint の戻し、macOS の `launchctl`

リポジトリ: https://github.com/<your-account>/homelab-k8s
