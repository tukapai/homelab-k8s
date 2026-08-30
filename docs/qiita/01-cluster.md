# 自宅の物理2台でKubernetesをGitOpsまで【第1回】KVM + kubeadm で3ノードクラスタを組む

<!--
Qiita 連載（全3回）第1回。
タグ候補: Kubernetes, kubeadm, KVM, libvirt, Ansible
連載インデックス: docs/qiita-article.md
-->

## この連載について

自宅の Ubuntu マシン 2 台で、次のものを **1 人で無理なく運用できる**ように組み上げた記録です。

1. **【第1回・本記事】KVM + kubeadm で 3 ノードクラスタ**（物理 2 台にまたがる）
2. 第2回: Argo CD で GitOps + Kong / Keycloak / Cloudflare Tunnel で公開
3. 第3回: New Relic + Instana で監視（評価ツールを「消せる形」で入れる）

全部スクリプト / マニフェスト化してあり、リポジトリを clone すれば再現できます。各回とも**「ハマったところ」を中心に**まとめます。

- インフラのリポジトリ: https://github.com/tukapai/homelab-k8s

### 最終的にこうなる

```
自宅LAN 192.168.1.0/24
 ├─ 物理ホストA (192.168.1.35)  ── libvirt NAT 192.168.122.0/24
 │                                  ├─ k8s-cp-1     .122.11
 │                                  └─ k8s-worker-1 .122.21
 └─ 物理ホストB (192.168.1.188) ── macvtap 直付け
                                    └─ k8s-worker-2  192.168.1.22
     Flannel VXLAN がサブネットを跨いで疎通（本記事の山場）
```

### この回で使うもの

```
homelab-k8s/
├── config.env.example          環境依存の設定（コピーして使う）
├── scripts/
│   ├── lib.sh                   共通関数（config 読込 / ログ / MAC 生成）
│   ├── 01-install-kvm-host.sh   KVM ホスト初期化
│   ├── 02-create-node-vm.sh     VM を 1 台作成（nat / bridge / macvtap）
│   ├── 03-destroy-node-vm.sh    VM を削除
│   └── 04-interconnect.sh       複数 KVM ホスト時のサブネット間接続
└── ansible/
    ├── inventory.ini.example
    ├── group_vars/all.yml       K8s バージョン・CNI・Pod CIDR
    ├── site.yml
    └── playbooks/
        ├── 10-common.yml        全ノード共通（containerd, kubeadm ...）
        ├── 20-control-plane.yml kubeadm init + Flannel
        └── 30-workers.yml       kubeadm join
```

### 前提環境

| 項目 | 値 |
|---|---|
| KVM ホスト | Ubuntu 24.04 / CPU 仮想化支援(VT-x か AMD-V)有効 |
| ゲスト | Ubuntu 24.04 cloud image |
| Kubernetes | v1.31.14（`pkgs.k8s.io`）|
| ランタイム / CNI | containerd 2.x + SystemdCgroup / Flannel |
| 操作端末 | Mac（SSH で KVM ホストに接続）|

アドレス規約（`config.env` で変更可）:

- control-plane = `192.168.122.11`
- worker N = `192.168.122.(20 + N)` → `.21`, `.22`, …

---

## Phase 1: KVM + kubeadm で 1 ノード

### KVM ホストのセットアップ

`scripts/01-install-kvm-host.sh` は要するにこれだけです。

```bash
sudo apt-get install -y \
    qemu-kvm libvirt-daemon-system libvirt-clients \
    virtinst cloud-image-utils ansible python3-libvirt
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"
```

```bash
git clone https://github.com/tukapai/homelab-k8s.git ~/kvm
cd ~/kvm
cp config.env.example config.env
cp ansible/inventory.ini.example ansible/inventory.ini

./scripts/01-install-kvm-host.sh
newgrp libvirt      # グループ反映（or 再ログイン）
```

`kvm-ok` で `KVM acceleration can be used` が出れば OK。

### cloud-init で VM を払い出す

`scripts/02-create-node-vm.sh` がやること:

1. Ubuntu cloud image をダウンロードしてコピー・リサイズ
2. VM 名から**決定的に** MAC を生成し、libvirt の `default` ネットワークに `MAC → 固定 IP` の DHCP 予約を追加
3. cloud-init の user-data を生成（`ubuntu` ユーザー + 公開鍵、swap 無効化）
4. `virt-install --import --cloud-init` で起動
5. SSH が通るまで待機

```bash
./scripts/02-create-node-vm.sh
#   → k8s-cp-1 / 192.168.122.11 / 4 vCPU / 8GB / 60GB
```

固定 IP の肝は「VM 名 → MAC を md5 で決定的に生成」しているところです。作り直しても MAC が変わらないので DHCP 予約と一致します。

```bash
mac_for() {
    local h; h="$(echo -n "$1" | md5sum | cut -c1-6)"
    echo "52:54:00:${h:0:2}:${h:2:2}:${h:4:2}"
}
```

### kubeadm + Ansible

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

`site.yml` は 3 本の playbook を順に流します（共通 → control-plane → workers）。中身は素直な kubeadm です。

```yaml
kubeadm init
  --pod-network-cidr=10.244.0.0/16
  --apiserver-advertise-address=192.168.122.11
  --cri-socket=unix:///run/containerd/containerd.sock
```

その後 Flannel を `kubectl apply`、`admin.conf` を手元に `fetch`。

### ハマり①: `conntrack not found`

初回の `kubeadm init` の preflight でこけました。

```
[ERROR FileExisting-conntrack]: conntrack not found in system path
```

Ubuntu cloud image には `conntrack` が入っていません。共通 playbook のパッケージリストに `conntrack` / `socat` / `ethtool` を足して解決。

### ハマり②: containerd 2.x の SystemdCgroup

`containerd config default` で吐いた設定を `SystemdCgroup = true` に置換してから restart、を忘れると kubelet がぐずります。playbook で毎回やるようにしています。

### 確認

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           AGE   VERSION
k8s-cp-1   Ready    control-plane   43s   v1.31.14
```

---

## Phase 2: 2 台目の物理マシンを worker にする

ここが一番苦労しました。既存クラスタ（ホスト A の libvirt NAT `192.168.122.0/24`）を**止めずに**、別の物理ホスト B 上の VM を worker として join させます。

### 方針: NAT だけ部分的に無効化する

ホスト B の VM を LAN 直結（`192.168.1.22`）にして、ホスト A 側で「**libvirt subnet ↔ LAN の間の NAT だけ**」を無効化します。VM → インターネットの NAT は残します。

`scripts/04-interconnect.sh` がやること:

```bash
# libvirt の MASQUERADE より前に「この2サブネット間は NAT しない」を挿入
iptables -t nat -I POSTROUTING -s 192.168.122.0/24 -d 192.168.1.0/24 -j RETURN
iptables -t nat -I POSTROUTING -s 192.168.1.0/24 -d 192.168.122.0/24 -j RETURN
# FORWARD も通す
iptables -I FORWARD -s 192.168.122.0/24 -d 192.168.1.0/24 -j ACCEPT
iptables -I FORWARD -s 192.168.1.0/24 -d 192.168.122.0/24 -j ACCEPT
```

これを systemd unit で永続化（再起動 / libvirt リロード後も復元）。**ダウンタイムゼロ**で入ります。worker-2 VM 側には cloud-init で `192.168.122.0/24 via 192.168.1.35` の静的経路を入れます。

これで **Flannel の VXLAN（UDP 8472）がサブネットを跨いで実 IP のまま流れる**ようになり、Pod 間通信 / DNS が通ります。

### ハマり③: `iptables` の引数順

配列で `("-t" "nat" "POSTROUTING" ...)` を組んで `iptables -I "${rule[@]}"` のように展開したら、

```
iptables v1.8.10 (nf_tables): Invalid rule number 'nat'
```

`iptables -I -t nat ...` という順序になって死んでいました。`-t nat` は `-I` より前に置く必要があります。関数化して `iptables -t nat "$1" CHAIN ...`（`$1` は `-C` / `-I` / `-D`）に修正。

### ハマり④: bridge をあきらめて macvtap に

当初はホスト B に `br0` を作る予定でしたが、ホスト B は NetworkManager renderer で `netplan try` が**ブリッジの revert に非対応**でした。設定ミスで SSH が切れると詰みます。

→ **macvtap（`--network type=direct,source=<NIC>,source_mode=bridge`）** に変更。host bridge を作らないので安全です。制約として「ホスト ↔ 自分の VM は直接通信できない」がありますが、Ansible はホスト A から実行するので問題なし。

`config.env` は 2 台目用にこう書きます:

```bash
NET_MODE="macvtap"
MACVTAP_SOURCE="enp3s0"          # ホスト B の LAN NIC
NET_PREFIX="192.168.1"
VM_GATEWAY="192.168.1.1"
VM_ROUTES="192.168.122.0/24,192.168.1.35"   # ホスト A の libvirt subnet 経由
EXTRA_SSH_PUBKEYS="$(cat /path/to/hostA_id_ed25519.pub)"  # Ansible がホスト A から SSH するため
```

### ハマり⑤: taint が worker にも付く

`single_node_cluster: false` にすると control-plane に taint を付け直す処理が走りますが、これが

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane=:NoSchedule
```

と `--all` になっていて、**worker-1 にも taint が付いて**全 Pod が worker-2 に偏っていました（気づいたのは監視を入れた第3回）。`-l node-role.kubernetes.io/control-plane` に修正。

### ハマり⑥: `30-workers.yml` の `run_once` + `when`

worker-2 を追加したとき、join コマンド取得タスクに `run_once: true` と `when: not kubelet_conf.stat.exists` が両方付いていて、**worker-1 が既に join 済みだとタスク全体がスキップ**され、worker-2 用の join コマンドが未定義になりました。`when` を外して解決（`kubeadm token create` は安いので毎回実行して問題なし）。

### 確認

```
$ kubectl get nodes -o wide
NAME           STATUS   ROLES           VERSION      INTERNAL-IP
k8s-cp-1       Ready    control-plane   v1.31.14     192.168.122.11
k8s-worker-1   Ready    <none>          v1.31.14     192.168.122.21
k8s-worker-2   Ready    <none>          v1.31.14     192.168.1.22
```

跨ぎで Pod・DNS が通ることも確認します。

```bash
kubectl run -it --rm net --image=busybox --overrides='{"spec":{"nodeName":"k8s-worker-2"}}' \
  -- wget -qO- http://<worker-1 上の Pod IP>:<port>
```

---

## 第1回まとめ

- KVM ホスト初期化・VM 払い出し・kubeadm・worker 追加まで全部スクリプト化
- 環境依存の値は `config.env` に集約、`inventory.ini` は IP だけ
- `site.yml` は冪等なので、ノード追加も設定変更も「再実行」で済む
- **既存クラスタを止めずに別の物理ホストを worker にできた**（NAT 部分無効化 + macvtap + Flannel クロスサブネット）
- ハマったのは `conntrack` 不足、iptables 引数順、bridge の revert 不可、taint の `--all`

次回は、このクラスタに **Argo CD を入れて以降を全部 GitOps 化**し、Kong + Keycloak + Cloudflare Tunnel で実アプリをインターネット公開します。

→ 第2回: Argo CD で GitOps + Kong / Keycloak / Cloudflare Tunnel で公開
