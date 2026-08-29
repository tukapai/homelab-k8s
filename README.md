# KVM 上に Kubernetes クラスタを構築する

この Ubuntu 24.04 マシンを **KVM ホスト**にして libvirt VM を立て、
**kubeadm + Ansible** で Kubernetes クラスタを構築する IaC 一式。

- 最初は **single node**（control-plane 1台、taint を外して Pod も載せる）
- あとから **worker VM を追加**してスケールアウトできる（同じスクリプト／Playbook を再利用）
- 別の物理マシンを node にする拡張にも対応（ブリッジ接続 + `config.env` の変更のみ）

> 設計ドキュメント（全体像）: [docs/design.md](docs/design.md)
> 設計判断の記録（ADR）: [docs/adr/](docs/adr/) ／ 運用手順: [docs/runbooks/](docs/runbooks/)
> 関連記事: （Qiita URL をここに）／ ドラフト: [docs/qiita-article.md](docs/qiita-article.md)

## clone 後の準備

環境依存ファイルは `*.example` だけをコミットしている。コピーして自分の値に:

```bash
cp config.env.example config.env
cp ansible/inventory.ini.example ansible/inventory.ini
$EDITOR config.env ansible/inventory.ini
```

`config.env` / `ansible/inventory.ini` / `ansible/kubeconfig` /
`mac/kubeconfig-tunnel` などは `.gitignore` 済み。

---

## 全体構成

```
┌─ KVM ホスト (この Ubuntu 24.04 マシン) ─────────────────────────┐
│                                                                │
│  scripts/01  … KVM/libvirt/Ansible をインストール               │
│  scripts/02  … cloud-init で VM を作成 ─────┐                   │
│  scripts/03  … VM を削除                    │                   │
│                                            ▼                   │
│   libvirt network "default" (NAT 192.168.122.0/24)             │
│   ┌────────────────┐  ┌────────────────┐  ┌────────────────┐    │
│   │ k8s-cp-1       │  │ k8s-worker-1   │  │ k8s-worker-2   │    │
│   │ .11  cp+etcd   │  │ .21 (任意)     │  │ .22 (任意)     │    │
│   │ containerd     │  │                │  │                │    │
│   └───────┬────────┘  └───────┬────────┘  └───────┬────────┘    │
│           │      Flannel VXLAN (Pod: 10.244.0.0/16)             │
│           └───────────────────┴───────────────────┘            │
│                            ▲                                   │
│  ansible/  ── SSH ─────────┘  kubeadm init / join, CNI 適用      │
│  ansible/kubeconfig ← 回収した管理者 kubeconfig                  │
└────────────────────────────────────────────────────────────────┘
```

```
homelab-k8s/
├── config.env.example          ★ 環境依存の設定（cp して config.env に）
├── LICENSE                     MIT
├── docs/
│   ├── design.md               設計ドキュメント（全体像）
│   ├── adr/                    設計判断の記録(ADR 0001-0007)
│   ├── runbooks/               物理ノード追加 / PG リストア / 全損復旧
│   └── qiita-article.md        解説記事ドラフト
├── scripts/
│   ├── lib.sh                   共通関数（config 読込 / ログ / MAC 生成 / ノード解決）
│   ├── 01-install-kvm-host.sh   KVM ホスト初期化
│   ├── 02-create-node-vm.sh     VM を 1 台作成（cloud-init）
│   ├── 03-destroy-node-vm.sh    VM を削除
│   └── 40-expose-console.sh     ホストの LAN ポート → Dashboard NodePort へ転送
├── cloud-init/
│   └── user-data.sample.yaml    02 が生成する user-data の参考
├── ansible/
│   ├── ansible.cfg              inventory / become / log_path(../logs/ansible.log)
│   ├── inventory.ini.example    ノード一覧（cp して inventory.ini に。IP はここで管理）
│   ├── group_vars/all.yml       K8s バージョン・CNI・Pod CIDR など
│   ├── site.yml                 10→20→30 をまとめて実行
│   ├── requirements.yml         community.general / ansible.posix
│   └── playbooks/
│       ├── 10-common.yml        全ノード共通（swap/カーネル/containerd/kube パッケージ）
│       ├── 20-control-plane.yml kubeadm init + Flannel + taint + kubeconfig 回収
│       ├── 30-workers.yml       kubeadm join
│       ├── 40-web-console.yml   Kubernetes Dashboard（任意・site.yml 非含）
│       ├── 42-metrics-server.yml metrics-server（任意・kubectl top / GUI グラフ用）
│       ├── 50-argocd.yml        Argo CD ブートストラップ（ADR-0001, 以降は GitOps）
│       └── 60-host-agents.yml   KVM ホストの New Relic Infra agent（ADR-0008）
├── mac/                         Mac から見るための手順とファイル（mac/README.md）
└── logs/                        スクリプト／Ansible の実行ログ（gitignore）
```

---

## 環境依存の設定 — `config.env`

スクリプトが参照する環境固有値はすべて [config.env](config.env) に集約。
**別マシン・別ネットワークへ移すときは基本ここだけ変更する。**
各値は実行時の環境変数でも上書きできる（`LIBVIRT_NET=br0 ./scripts/02-...`）。

| 変数 | 既定値 | 意味 |
|---|---|---|
| `LIBVIRT_URI` | `qemu:///system` | virsh / virt-install の接続先 |
| `LIBVIRT_NET` | `default` | VM を繋ぐ libvirt ネットワーク。別物理マシンと組むなら `br0` 等のブリッジ |
| `POOL_DIR` | `/var/lib/libvirt/images` | qcow2 の置き場所 |
| `IMG_URL` | Ubuntu 24.04 noble cloud image | ゲスト OS イメージ URL |
| `OS_VARIANT` | `ubuntu24.04` | `virt-install --os-variant` |
| `GUEST_USER` | `ubuntu` | cloud-init が作るユーザー（= `ansible_user`）|
| `SSH_PUBKEY` | `~/.ssh/id_ed25519.pub` | ゲストに登録する公開鍵（無ければ 02 が生成）|
| `NET_PREFIX` | `192.168.122` | アドレスの /24 プレフィックス |
| `CP_IP` | `192.168.122.11` | control-plane の固定 IP（= apiserver アドレス）|
| `WORKER_IP_BASE` | `20` | worker N の IP = `NET_PREFIX.(20+N)` |
| `CP_VCPUS/RAM_MB/DISK_GB` | `4 / 8192 / 60` | control-plane VM のスペック |
| `WORKER_VCPUS/RAM_MB/DISK_GB` | `2 / 4096 / 40` | worker VM のスペック |
| `CP_NAME` | `k8s-cp-1` | control-plane の VM 名 |
| `WORKER_NAME_PREFIX` | `k8s-worker-` | worker 名の接頭辞（+ ノード番号）|
| `GUEST_DOMAIN` | `k8s.local` | FQDN サフィックス |

Kubernetes 側の設定（バージョン・CNI・Pod CIDR）は [ansible/group_vars/all.yml](ansible/group_vars/all.yml) に分離:

| 変数 | 既定値 | 意味 |
|---|---|---|
| `kube_version` | `1.31` | pkgs.k8s.io のマイナー系列 |
| `pod_network_cidr` | `10.244.0.0/16` | Flannel の既定に合わせる |
| `flannel_manifest_url` | latest | CNI マニフェスト |
| `apiserver_advertise_address` | cp の `ansible_host` を自動参照 | |
| `single_node_cluster` | `false` | `true`=cp の taint を外す / `false`=cp に taint を付ける |

---

## 手順（初回）

### 1. KVM ホストのセットアップ（sudo パスワードが必要）

```bash
./scripts/01-install-kvm-host.sh
newgrp libvirt          # または一度ログアウト／ログイン
```

### 2. control-plane VM を作成

```bash
./scripts/02-create-node-vm.sh
```

### 3. inventory に登録して Ansible 実行

`ansible/inventory.ini` の `[control_plane]` は既定で `k8s-cp-1` を含む。そのまま:

```bash
cd ansible
ansible all -m ping
ansible-playbook site.yml
```

### 4. kubectl で確認

```bash
export KUBECONFIG=$PWD/kubeconfig   # ansible/ ディレクトリで実行
kubectl get nodes -o wide
kubectl get pods -A
```

---

## スクリプト設計

すべてのスクリプトは冒頭で `scripts/lib.sh` を source し、そこで `config.env`
を読み込む。全出力は画面表示と同時に `logs/<script>-<timestamp>.log` に記録される。

### `scripts/lib.sh`（共通ライブラリ）

| 関数 | 役割 |
|---|---|
| （読み込み時）| `REPO_ROOT` を決定し `config.env` を source。無ければエラー終了。`VIRSH="virsh --connect $LIBVIRT_URI"` を定義 |
| `setup_logging "$0"` | `exec > >(tee -a LOGFILE) 2>&1` で以降の stdout/stderr をログにも複製 |
| `mac_for NAME` | VM 名の md5 先頭6桁から `52:54:00:xx:xx:xx` を生成。**同じ名前→同じ MAC** なので作り直しても DHCP 予約と一致する |
| `resolve_node` | `ROLE`(control-plane/worker) と `NODE_NUM` から `VM_NAME` `VM_IP` `VCPUS` `RAM_MB` `DISK_GB` を決定。個別の環境変数指定が最優先 |

### `scripts/01-install-kvm-host.sh`

- **入力**: なし（`config.env` の `LIBVIRT_NET` のみ参照）
- **要 sudo**: あり
- **処理**:
  1. `/proc/cpuinfo` に `vmx|svm` があるか確認（無ければ中止）
  2. `apt-get install` — `qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils cloud-image-utils genisoimage ansible python3-libvirt`
  3. `systemctl enable --now libvirtd`
  4. `usermod -aG libvirt,kvm $USER`（**要再ログイン or `newgrp libvirt`**）
  5. `virsh net-start` / `net-autostart` で `LIBVIRT_NET` を有効化
  6. `kvm-ok` と `virsh version` で確認
- **冪等性**: apt は再実行しても既インストールなら変化なし。グループ追加・net 設定も再実行安全
- **出力**: `logs/01-install-kvm-host-*.log`

### `scripts/02-create-node-vm.sh`

- **入力（環境変数）**:
  - `ROLE` = `control-plane`(既定) / `worker`
  - `ROLE=worker` のとき `NODE_NUM`（1,2,3…）が必須
  - 任意で `VM_NAME` `VM_IP` `VCPUS` `RAM_MB` `DISK_GB` `LIBVIRT_NET` などを直接上書き
- **要 sudo**: あり（イメージ配置・`qemu-img`・`virt-install`）
- **処理**:
  1. `resolve_node` で名前 / IP / スペックを確定、`mac_for` で MAC を確定
  2. `SSH_PUBKEY` が無ければ `ssh-keygen -t ed25519` で生成
  3. 同名 VM が既にあれば中止（削除方法を案内）
  4. ベースイメージ `POOL_DIR/<image>.img` が無ければ `IMG_URL` から DL
  5. ベースを `cp --reflink=auto` でコピー → `qemu-img resize` で `DISK_GB` に拡張
     （backing file 方式ではなく**独立したディスク**にしている）
  6. `virsh net-update ... add ip-dhcp-host` で `MAC → IP` の DHCP 予約を追加
     （既存の同 MAC 予約は事前に delete。`--live --config` で稼働中と永続の両方）
  7. cloud-init `user-data` を生成（一時ファイル、終了時に削除）:
     - `hostname` / `fqdn`（`GUEST_DOMAIN`）
     - `GUEST_USER` を sudo NOPASSWD で作成し公開鍵を登録、パスワードログイン無効
     - `runcmd` で `swapoff -a` と `/etc/fstab` の swap 行コメントアウト
  8. `virt-install --import --cloud-init --graphics none --noautoconsole`
     （`--cpu host-passthrough`、ディスク／NIC とも virtio）
  9. `GUEST_USER@VM_IP` に SSH できるまで最大 5 分ポーリング
  10. inventory に追記すべき行を表示（`<name> ansible_host=<ip>`）
- **冪等性**: なし（新規作成用）。作り直しは 03 で削除してから再実行
- **出力**: VM 本体、`logs/02-create-node-vm-*.log`

### `scripts/03-destroy-node-vm.sh`

- **入力**: 第1引数に VM 名
- **処理**: `virsh destroy` → `virsh undefine --remove-all-storage` →
  `net-update ... delete ip-dhcp-host`（`mac_for` で MAC を再計算）
- **冪等性**: あり（存在しなくてもエラーにしない）
- **注意**: `inventory.ini` の該当行は手動で削除する

### `scripts/40-expose-console.sh {add|remove|status}`

- **要 sudo**: あり（iptables / systemd）
- **処理（add）**: `<host>:LAN_PORT`(既定 8443) → `TARGET_IP:NODE_PORT`(既定
  `CP_IP:30443`) の転送を iptables に追加（nat PREROUTING/OUTPUT/POSTROUTING +
  filter FORWARD を libvirt の REJECT より前に挿入）。さらに
  `/etc/systemd/system/k8s-console-forward.service` を作成・enable し、
  再起動や libvirt リロード後もルールを復元する
- **remove**: ルールと systemd ユニットを削除
- **冪等性**: あり（`iptables -C` で存在確認してから挿入）

---

## Ansible 設計

`ansible/ansible.cfg`: `inventory=inventory.ini` / `become=True` /
`host_key_checking=False` / `log_path=../logs/ansible.log`（`ansible/` から実行する前提）。

### `playbooks/10-common.yml` — 全ノード共通（hosts: k8s）

| ブロック | 内容 |
|---|---|
| swap | `swapoff -a` / `/etc/fstab` の swap 行をコメントアウト |
| カーネル | `overlay` `br_netfilter` を `modprobe` + `/etc/modules-load.d/k8s.conf` |
| sysctl | `bridge-nf-call-iptables=1` `ip_forward=1` を `/etc/sysctl.d/99-kubernetes-cri.conf` |
| ランタイム | `containerd` ほか `conntrack` `socat` `ethtool`（kubeadm 必須）等を apt install |
| containerd 設定 | `containerd config default` を生成し `SystemdCgroup = true` に置換 → restart |
| K8s リポジトリ | `pkgs.k8s.io/core:/stable:/v{{kube_version}}` の鍵と apt source を追加 |
| K8s パッケージ | `kubelet kubeadm kubectl` を install し `dpkg hold`、`kubelet` を enable |

冪等。バージョン変更は `group_vars/all.yml` の `kube_version` を変えて再実行。

### `playbooks/20-control-plane.yml` — hosts: control_plane

1. `/etc/kubernetes/admin.conf` の有無で初期化済みか判定
2. 未初期化なら
   `kubeadm init --pod-network-cidr={{pod_network_cidr}} --apiserver-advertise-address={{apiserver_advertise_address}} --cri-socket=unix:///run/containerd/containerd.sock`
3. `GUEST_USER` 用に `~/.kube/config` を配置
4. `/healthz` が通るまで待機
5. Flannel DaemonSet が無ければ `flannel_manifest_url` を `kubectl apply`
6. `single_node_cluster` が true なら `kubectl taint nodes --all node-role.kubernetes.io/control-plane-`
7. `kubeadm token create --print-join-command` の結果を
   `~/kubeadm-join.sh` に保存
8. `/etc/kubernetes/admin.conf` を Ansible 実行側の `ansible/kubeconfig` に `fetch`

冪等（各ステップに存在チェックあり）。

### `playbooks/30-workers.yml` — hosts: workers

1. `/etc/kubernetes/kubelet.conf` の有無で join 済みか判定
2. 未 join なら control-plane 上で `kubeadm token create --print-join-command`
   （`delegate_to` + `run_once`）
3. その join コマンドを worker で実行（`--cri-socket` 付き）

`[workers]` が空なら `skipping: no hosts matched` で無害にスキップ。

### `site.yml`

`10-common.yml` → `20-control-plane.yml` → `30-workers.yml` を順に `import_playbook`。
**何度実行しても安全**なので、ノード追加時もこれ 1 本で足りる。

### `playbooks/42-metrics-server.yml` — hosts: control_plane（任意）

metrics-server を導入し、kubeadm ノード向けに `--kubelet-insecure-tls` を付与、
`kubectl top nodes` が返るまで待機。**導入済み**。冪等。

### `playbooks/50-argocd.yml` — hosts: control_plane（ADR-0001）

Argo CD をブートストラップする。**以降のプラットフォーム/アプリは
このリポジトリでは管理せず、Argo CD が `homelab-gitops` から同期する**
（ADR-0007）。

```bash
cd ansible
# homelab-gitops を作ってから:
ansible-playbook playbooks/50-argocd.yml -e gitops_repo_url=git@github.com:you/homelab-gitops.git
```

- `argocd` namespace に Argo CD（バージョンは `group_vars/all.yml` の `argocd_version`）
- `gitops_repo_url` があれば app-of-apps の `root` Application を作成
- 初期 admin パスワードを表示
- private リポは別途 repo 資格情報の登録が必要（実行後の案内 / runbook 参照）

## 運用 Runbook

| Runbook | 内容 |
|---|---|
| [add-physical-node.md](docs/runbooks/add-physical-node.md) | 2 台目の物理マシンを worker として追加、暫定策の解除 |
| [restore-postgres.md](docs/runbooks/restore-postgres.md) | CloudNativePG のバックアップ／リストア（PITR、DR）|
| [backup-and-recovery.md](docs/runbooks/backup-and-recovery.md) | 何を退避するか、全損からの復旧手順、sealing key 管理 |

> `docs/runbooks/instana-eval.md` と `ansible/playbooks/local/` は Instana 評価用の
> 一時ファイルで **gitignore**（ADR-0008）。

### `playbooks/40-web-console.yml` — hosts: control_plane（任意）

`site.yml` には含まれない。実行すると `kubernetes-dashboard` 名前空間に
公式 Dashboard マニフェスト（`v2.7.0`）を適用し、外部アクセス用の NodePort
サービス（`30443`）、`cluster-admin` の ServiceAccount、無期限トークンを作成。
トークンは control-plane の `~/dashboard-token.txt` と実行側の
`mac/dashboard-token.txt` に保存される。冪等。

---

## ノードを追加する（同一 KVM ホスト内）

このスクリプト群は**そのまま worker 追加に使える**。

```bash
# 1) worker VM を作成（config.env の WORKER_* と命名規約が適用される）
ROLE=worker NODE_NUM=1 ./scripts/02-create-node-vm.sh
#   → k8s-worker-1 / 192.168.122.21 / 2vCPU / 4GB / 40GB

# 2) inventory に追記
#    ansible/inventory.ini の [workers] に:
#      k8s-worker-1 ansible_host=192.168.122.21

# 3) 共通セットアップ + join（site.yml は冪等なので再実行で OK）
cd ansible && ansible-playbook site.yml

# 4) 確認
export KUBECONFIG=$PWD/kubeconfig   # ansible/ ディレクトリで実行
kubectl get nodes
```

スペックだけ変えたいとき:

```bash
ROLE=worker NODE_NUM=2 VCPUS=4 RAM_MB=8192 DISK_GB=80 ./scripts/02-create-node-vm.sh
```

複数ノードで control-plane の taint を戻したい場合は
`group_vars/all.yml` の `single_node_cluster: false` にして `site.yml` を再実行。

## 別の物理マシンを node にする

1. その物理マシンにも Ubuntu を入れ、`scripts/01` 相当（KVM）をセットアップ
   （または物理マシン自体を bare-metal node にするなら KVM 不要）
2. **ブリッジ接続が必要**: libvirt NAT `default` は他ホストから到達できないので、
   各 KVM ホストで `br0`（LAN 直結）を作り、`config.env` を
   ```
   LIBVIRT_NET=br0
   NET_PREFIX=<LAN の /24>
   CP_IP=<LAN 内の空きアドレス>
   ```
   に変更してから `scripts/02` を実行
3. `inventory.ini` に各ノードの LAN IP を記載して `site.yml`
4. ノード間で以下が通ること: TCP 6443（API）、UDP 8472（Flannel VXLAN）、
   TCP 10250（kubelet）、TCP 2379-2380（etcd, HA 時）

---

## Mac から見る

詳細は [mac/README.md](mac/README.md)。

**推奨 = Headlamp（デスクトップ GUI）+ 自動 SSH トンネル**。Mac で 1 回:

```bash
# $KVM_HOST = user@<KVMホストのLAN-IP>,  $REPO = KVM ホスト上のリポジトリの場所
scp "$KVM_HOST:$REPO/mac/setup-headlamp-mac.sh" .
HOST_SSH="$KVM_HOST" REMOTE_REPO="$REPO" ./setup-headlamp-mac.sh
```
以降は Headlamp.app を開くだけ（トンネルはログイン時に自動起動）。

### 代替: ブラウザで Kubernetes Dashboard を見る

```bash
# 1) コンソールを導入（KVM ホストで 1 回）
cd ansible && ansible-playbook playbooks/40-web-console.yml
#    → NodePort 30443、ログイントークンが mac/dashboard-token.txt に回収される

# 2a) すぐ見る: Mac で SSH トンネル → https://localhost:8443
ssh -N -L 8443:<CP_IP>:30443 "$KVM_HOST"

# 2b) ブックマーク常用: ホストにポート転送を設定 → https://<KVMホストIP>:8443
./scripts/40-expose-console.sh add        # remove / status も可
```

## 動作確認済み構成

以下の構成でクラスタ構築〜worker 追加〜Mac から Headlamp 接続まで確認済み。

| 項目 | 値 |
|---|---|
| KVM ホスト | Ubuntu 24.04（AMD-V, 12 vCPU / 64GB RAM 相当）|
| control-plane VM | `k8s-cp-1` / `<NET_PREFIX>.11` / 4 vCPU / 8GB / 60GB |
| worker VM | `k8s-worker-1` / `<NET_PREFIX>.21` / 2 vCPU / 4GB / 40GB |
| Kubernetes | v1.31（`pkgs.k8s.io`）|
| ランタイム / CNI | containerd + SystemdCgroup / Flannel |
| アドオン | metrics-server（任意）、Kubernetes Dashboard（任意）|

---

## 後片付け

```bash
./scripts/03-destroy-node-vm.sh k8s-cp-1
# inventory.ini の該当行も削除する
```

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `virsh` が permission denied | `newgrp libvirt` するかログインし直す |
| VM に SSH できない | `virsh --connect qemu:///system console <name>` で cloud-init ログ確認 |
| `ansible ping` 失敗 | `~/.ssh/known_hosts` の古い鍵、鍵パス、VM の IP を確認 |
| `kubeadm init` preflight `conntrack not found` | `10-common.yml` が `conntrack` を入れる。VM 作成前から入れておくか再実行 |
| node が `NotReady` | Flannel Pod のログ: `kubectl -n kube-flannel logs ds/kube-flannel-ds` |
| `kubeadm init` を最初からやり直したい | VM で `sudo kubeadm reset -f` → `site.yml` 再実行、または 03→02 で作り直し |
