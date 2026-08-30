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

全部スクリプト / マニフェスト化してあり、リポジトリを clone すれば再現できます。各回とも**「ハマったところ」を中心に**、そのとき何が起きていたのか（仕組み）まで踏み込んで書きます。自分が後で見返すためのメモを兼ねているので、一般に自明とされる用語も都度説明します。

- インフラのリポジトリ: https://github.com/tukapai/homelab-k8s

### 最終的にこうなる

```
自宅LAN 192.168.1.0/24
 ├─ 物理ホストA (192.168.1.35)  ── libvirt NAT ネットワーク 192.168.122.0/24
 │                                  ├─ k8s-cp-1     .122.11   （control plane）
 │                                  └─ k8s-worker-1 .122.21
 └─ 物理ホストB (192.168.1.188) ── macvtap 直付け
                                    └─ k8s-worker-2  192.168.1.22
     Flannel VXLAN がサブネットを跨いで疎通（本記事の山場）
```

3 ノード = control plane 1 + worker 2。物理は 2 台で、ホスト A には VM 2 つ（cp と worker-1）、ホスト B には VM 1 つ（worker-2）が載っています。

---

## 0. 前提知識の整理

### 仮想化まわりの登場人物

| 用語 | ざっくり |
|---|---|
| **KVM** | Linux カーネルの機能。CPU の仮想化支援（Intel VT-x / AMD-V）を使って、ゲスト OS をほぼネイティブ速度で動かす。カーネルモジュール `kvm` + `kvm_intel` / `kvm_amd` |
| **QEMU** | ユーザー空間のエミュレータ。CPU 以外（ディスク、NIC、チップセット等）をエミュレートする。KVM と組み合わせると「CPU は KVM、周辺は QEMU」になる |
| **libvirt** | KVM/QEMU を操作するための管理レイヤ（デーモン `libvirtd` + ライブラリ + CLI `virsh`）。VM 定義を XML で持ち、ネットワークやストレージプールも管理する |
| **virt-install** | libvirt 経由で VM を作る CLI。XML を手書きしなくてよい |
| **cloud image** | クラウド用にチューニングされた OS イメージ（`.img` / qcow2）。**cloud-init** が入っていて、初回起動時に外から設定を注入できる。デスクトップ ISO と違い対話インストール不要 |
| **cloud-init** | 初回起動時に「ユーザー作成」「SSH 公開鍵登録」「パッケージ導入」「任意コマンド実行」などを行う仕組み。設定を **user-data** / **network-config** というファイルで渡す。ローカルで渡す方式を **NoCloud データソース**と呼ぶ |

この記事では「KVM ホスト = 物理マシン」「ゲスト / VM / ノード = その上の仮想マシン = Kubernetes のノード」です。

### Kubernetes のノード構成

- **control plane（コントロールプレーン）**: クラスタの頭脳。次のコンポーネントが動く。
  - **kube-apiserver**: すべての操作の入り口（REST API）。`kubectl` はここに話す
  - **etcd**: 分散 KV ストア。クラスタの全状態（Pod 定義など）を保存する唯一の真実
  - **kube-scheduler**: 新しい Pod をどのノードに置くか決める
  - **kube-controller-manager**: 「あるべき状態」に寄せ続けるループ群（ReplicaSet の数を保つ等）
- **worker ノード**: 実際にコンテナ（Pod）を動かす。
  - **kubelet**: そのノードの管理エージェント。API server の指示で Pod を起動/監視する
  - **kube-proxy**: Service（仮想 IP）の負荷分散を iptables/ipvs ルールで実現する
  - **コンテナランタイム**: 実際にコンテナを動かす（後述の containerd）

**kubeadm** は、この control plane / worker のセットアップを自動化するツールです。`kubeadm init` で control plane を作り、`kubeadm join` で worker を参加させます。

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

- `qemu-kvm` … QEMU 本体（KVM 連携ビルド）
- `libvirt-daemon-system` / `libvirt-clients` … `libvirtd` と `virsh`
- `virtinst` … `virt-install`
- `cloud-image-utils` … cloud-init 用の seed ISO を作る `cloud-localds` など
- `usermod -aG libvirt,kvm` … 一般ユーザーが `sudo` なしで `virsh` / `/dev/kvm` を使えるようにする。**グループ追加は再ログイン（または `newgrp`）で反映**される点に注意

```bash
git clone https://github.com/tukapai/homelab-k8s.git ~/kvm
cd ~/kvm
cp config.env.example config.env
cp ansible/inventory.ini.example ansible/inventory.ini

./scripts/01-install-kvm-host.sh
newgrp libvirt      # グループ反映（or 再ログイン）
```

`kvm-ok` で `KVM acceleration can be used` が出れば OK。出ない場合は BIOS/UEFI で VT-x / AMD-V が無効になっています。

> **環境依存値は `config.env` 1 ファイルに集約**しています。別マシンへ移すときはここだけ変える設計です。`scripts/lib.sh` が起動時に `config.env` を source し、ログ出力（`logs/<script>-<timestamp>.log` へ tee）とノード名・IP の解決を担います。

### cloud-init で VM を払い出す

`scripts/02-create-node-vm.sh` がやること:

1. **Ubuntu cloud image をダウンロードしてコピー・リサイズ**
   qcow2 のベースイメージを `cp --reflink=auto` で複製し、`qemu-img resize` で目標サイズに拡張します。backing file（差分ディスク）方式ではなく**独立したディスク**にしているのは、ベースイメージを消しても VM が壊れないようにするためです。
2. **VM 名から決定的に MAC を生成**し、libvirt のネットワークに `MAC → 固定 IP` の DHCP 予約を追加
3. **cloud-init の user-data を生成**（`ubuntu` ユーザー + SSH 公開鍵、`swapoff -a` と `/etc/fstab` の swap 行コメントアウト）
4. `virt-install --import --cloud-init` で起動
5. SSH が通るまで最大 5 分ポーリング

```bash
./scripts/02-create-node-vm.sh
#   → k8s-cp-1 / 192.168.122.11 / 4 vCPU / 8GB / 60GB
```

#### なぜ「決定的な MAC」なのか

libvirt の NAT ネットワーク（`default`）は内部に **dnsmasq** を持っていて、DHCP を配ります。特定の VM に固定 IP を割り当てたいときは「この MAC アドレスにはこの IP」という **DHCP 予約**を登録します。

問題は、VM を作り直すと MAC がランダムに変わり、予約とズレて別の IP を掴んでしまうこと。そこで **VM 名の md5 ハッシュ先頭 6 桁から MAC を組み立てる**ことで、「同じ名前 → 必ず同じ MAC → 予約と一致」を保証します。

```bash
mac_for() {
    local h; h="$(echo -n "$1" | md5sum | cut -c1-6)"
    echo "52:54:00:${h:0:2}:${h:2:2}:${h:4:2}"
}
```

`52:54:00` は QEMU/KVM に割り当てられた OUI（ベンダプレフィックス）です。

#### なぜ swap を無効化するのか

kubelet は既定で **swap が有効だと起動を拒否**します（`--fail-swap-on=true`）。理由は、swap があると「メモリ不足時にどの Pod を殺すか」という QoS 制御や eviction の挙動が予測不能になり、レイテンシも読めなくなるため。cloud-init の `runcmd` で `swapoff -a` し、`/etc/fstab` の swap 行をコメントアウトして永続的に無効化します。

### kubeadm + Ansible

Ansible を使う理由は、**冪等（idempotent）**だからです。「あるべき状態」を宣言しておけば、何度実行しても同じ結果になり、途中で失敗しても再実行で続きから収束します。手順書を人間が順に叩くより安全で、ノード追加も「同じ playbook を再実行するだけ」になります。

`ansible/inventory.ini`（対象ホスト一覧）は最初これだけ:

```ini
[control_plane]
k8s-cp-1 ansible_host=192.168.122.11

[workers]
# k8s-worker-1 ansible_host=192.168.122.21
```

```bash
cd ansible
ansible all -m ping          # SSH 疎通確認
ansible-playbook site.yml
```

`site.yml` は 3 本の playbook を順に `import_playbook` します。

#### 10-common.yml — 全ノード共通

| ブロック | やること | なぜ |
|---|---|---|
| swap | `swapoff -a` + fstab | 上記のとおり kubelet が要求 |
| カーネルモジュール | `overlay`, `br_netfilter` を `modprobe` + `/etc/modules-load.d/` | `overlay` はコンテナのオーバーレイ FS、`br_netfilter` は「Linux ブリッジを通るパケットを iptables に見せる」ために必要 |
| sysctl | `net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1` | 前者は Pod 間通信の NetworkPolicy / Service ルーティングが iptables で効くように。後者はノードがルータとして他ネットワーク宛パケットを転送できるように（CNI が要求） |
| ランタイム | `containerd` + `conntrack` `socat` `ethtool` を apt install | 下記 |
| containerd 設定 | `containerd config default` を生成し `SystemdCgroup = true` に | 下記 |
| K8s リポジトリ | `pkgs.k8s.io` の鍵と apt source を追加 | 公式の新しいパッケージ配布元 |
| K8s パッケージ | `kubelet kubeadm kubectl` を install し `apt-mark hold` | `hold` は「勝手にアップグレードさせない」。K8s は自動マイナー更新すると壊れやすい |

##### コンテナランタイムと CRI

Kubernetes は直接コンテナを起動せず、**CRI（Container Runtime Interface）**という gRPC API 越しにランタイムへ指示します。今の標準実装が **containerd** です（Docker は内部で containerd を使っているが、K8s から見ると余計なレイヤなので直接 containerd を使う）。kubelet は `--cri-socket=unix:///run/containerd/containerd.sock` で containerd に繋ぎます。

##### cgroup ドライバを揃える（超重要）

**cgroup（control group）** は Linux カーネルの機能で、プロセス群の CPU / メモリ使用量を制限・計測します。コンテナのリソース制限はこれで実現されます。

cgroup を操作する方式が 2 つあります:

- **cgroupfs**: `/sys/fs/cgroup` を直接叩く
- **systemd**: systemd に「このスコープを作って」と依頼する

systemd が PID 1 のシステム（＝現代の Ubuntu）では、**cgroup 階層の所有者は systemd**。ここに containerd が cgroupfs で直接書き込むと、2 つの管理者が同じ木を触ることになり不整合が起きます。なので **kubelet と containerd の両方を systemd ドライバに揃える**必要があります。

kubelet 側は kubeadm が既定で systemd にしてくれますが、**containerd 側は明示設定が必要**です。

```bash
containerd config default > /etc/containerd/config.toml
# [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
#   SystemdCgroup = true
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
```

これを忘れると、Pod は一応起動するのに kubelet が定期的にエラーを吐き、ノードが不安定になります。

##### conntrack / socat / ethtool

- **conntrack**: `conntrack-tools`。カーネルの接続追跡テーブル（NAT や Service の戻りパケットを正しく返すのに使う）を操作する CLI。kube-proxy が iptables モードで動くのに必要
- **socat**: `kubectl port-forward` の実装に使われる
- **ethtool**: NIC の機能確認。CNI が使うことがある

kubeadm の preflight check がこれらの存在を要求します。

#### 20-control-plane.yml

```yaml
kubeadm init
  --pod-network-cidr=10.244.0.0/16
  --apiserver-advertise-address=192.168.122.11
  --cri-socket=unix:///run/containerd/containerd.sock
```

- **`--pod-network-cidr`**: Pod に割り当てる IP の範囲。`10.244.0.0/16` は Flannel の既定値。各ノードにこの中から `/24` が切り出され、そのノードの Pod はそこから IP をもらう
- **`--apiserver-advertise-address`**: API server が「自分はこの IP にいる」と広告するアドレス。ノードが複数 NIC を持つときに重要

その後 playbook が:

1. `ubuntu` ユーザー用に `~/.kube/config` を配置
2. `/healthz` が通るまで待機
3. **Flannel（CNI プラグイン）**を `kubectl apply`
4. `single_node_cluster` の値に応じて control plane の taint を付け外し
5. join コマンドを `~/kubeadm-join.sh` に保存
6. `admin.conf` を Ansible 実行側の `ansible/kubeconfig` に `fetch`（回収）

##### CNI と Flannel と「オーバーレイネットワーク」

**CNI（Container Network Interface）** は「Pod にネットワークインタフェースを与える」プラグインの規格です。kubeadm はネットワークを**入れてくれない**ので、自分で選んで入れます。

**Flannel** はシンプルな CNI で、既定で **VXLAN** を使います。

- 各ノードは Pod 用サブネット（例: cp = `10.244.0.0/24`、worker-1 = `10.244.1.0/24`）を持つ
- ノード A の Pod からノード B の Pod へパケットを送るとき、Flannel は元のパケットを**まるごと UDP パケットの中に入れて**（カプセル化）、ノード B の実 IP 宛に送る
- ノード B 側で開封して、中の Pod 宛パケットを取り出す

この「実ネットワークの上に、Pod 用の仮想ネットワークを一枚かぶせる」のが**オーバーレイネットワーク**です。VXLAN のカプセル化には **UDP ポート 8472** を使います（後述、これが Phase 2 で効いてくる）。

##### taint と toleration

**taint（テイント、汚れ）** はノードに付ける「敬遠マーク」です。`kubectl taint nodes k8s-cp-1 node-role.kubernetes.io/control-plane:NoSchedule` と付けると、「このノードには普通の Pod を置くな」という意味になります。

- **`NoSchedule`**: 新規 Pod を置かない（既存はそのまま）
- **`NoExecute`**: 既存 Pod も追い出す

対になるのが **toleration（トレレーション、許容）** で、Pod 側に「この taint は我慢できる」と書くと、その taint のあるノードにも置けます。監視エージェントのような「全ノードで動きたい」ものは `tolerations: [{operator: Exists}]`（＝どんな taint も許容）を付けます。

kubeadm は既定で control plane に上記 taint を付けます。単一ノードで使いたいときは外し（`single_node_cluster: true`）、worker を分けたときは付け直します。

#### ハマり①: `conntrack not found`

初回の `kubeadm init` の preflight でこけました。

```
[ERROR FileExisting-conntrack]: conntrack not found in system path
```

Ubuntu cloud image は最小構成で、`conntrack` が入っていません。前述のとおり `10-common.yml` のパッケージリストに `conntrack` / `socat` / `ethtool` を足して解決。

#### ハマり②: containerd の SystemdCgroup

「Pod は起動するのに kubelet が定期的にエラーを吐く」状態になりました。原因は上記の cgroup ドライバ不一致。`SystemdCgroup = true` にして restart。

### 確認

```bash
export KUBECONFIG=$PWD/kubeconfig   # ansible/ ディレクトリで
kubectl get nodes -o wide
```

```
NAME       STATUS   ROLES           AGE   VERSION
k8s-cp-1   Ready    control-plane   43s   v1.31.14
```

`STATUS Ready` は「kubelet が生きていて CNI も動いている」印。CNI が入る前は `NotReady` です。`kubectl get pods -A` で CoreDNS が `Running` なら Pod ネットワークも OK。

---

## Phase 2: 2 台目の物理マシンを worker にする

ここが一番苦労しました。既存クラスタ（ホスト A の libvirt NAT `192.168.122.0/24`）を**止めずに**、別の物理ホスト B 上の VM を worker として join させます。

### なぜ難しいのか

Flannel の VXLAN は「**ノードの実 IP 同士が L3 で到達可能**」であることを前提にしています。ノード A（`192.168.122.11`）からノード B（`192.168.1.22`）へ UDP 8472 が届き、かつ**戻りも届く**必要があります。

ホスト A の VM は libvirt の NAT ネットワークの中にいます。libvirt はこの NAT を **iptables の MASQUERADE**（＝ SNAT の一種、送信元 IP をホストの IP に書き換える）で実現しています。

> **NAT / SNAT / MASQUERADE / DNAT の整理**
> - **NAT（Network Address Translation）**: パケットの IP アドレスを書き換える総称
> - **SNAT（Source NAT）**: 送信元アドレスを書き換える。プライベート IP の端末が外へ出るとき、送信元をルータのグローバル IP にするのがこれ
> - **MASQUERADE**: SNAT の亜種で「出ていく NIC の IP に自動で書き換える」。IP が動的なとき便利
> - **DNAT（Destination NAT）**: 宛先アドレスを書き換える。ポートフォワードがこれ

libvirt の NAT ネットワークだと、`192.168.122.x` の VM が `192.168.1.x`（LAN）宛にパケットを出すと、**送信元が `192.168.122.x` からホスト A の LAN IP に書き換えられて**しまいます。すると worker-2 から見た通信相手が「ホスト A」になり、Flannel が期待する「ノード同士の直接通信」が成立しません。

### 方針: LAN 向けの NAT だけ無効化する

そこで、`scripts/04-interconnect.sh` で「**libvirt subnet ↔ LAN の間の通信は NAT しない**」ルールを、libvirt の MASQUERADE ルールより**前**に挿入します（iptables は上から順に評価し、先にマッチしたルールが勝つ）。

```bash
# nat テーブルの POSTROUTING チェーン: この2サブネット間は「何もしない(RETURN)」
iptables -t nat -I POSTROUTING -s 192.168.122.0/24 -d 192.168.1.0/24 -j RETURN
iptables -t nat -I POSTROUTING -s 192.168.1.0/24 -d 192.168.122.0/24 -j RETURN

# filter テーブルの FORWARD チェーン: 転送を明示的に許可
iptables -I FORWARD -s 192.168.122.0/24 -d 192.168.1.0/24 -j ACCEPT
iptables -I FORWARD -s 192.168.1.0/24 -d 192.168.122.0/24 -j ACCEPT
```

> **iptables のテーブルとチェーン**
> - **テーブル**: `nat`（アドレス変換）、`filter`（通す/落とす）など目的別
> - **チェーン**: パケットが通る位置。`PREROUTING`（受信直後）→ ルーティング判断 → `FORWARD`（自分宛でない＝転送する）または `INPUT`（自分宛）→ `POSTROUTING`（送信直前）
> - `POSTROUTING` で `-j RETURN` すると「このチェーンの残りのルール（＝ libvirt の MASQUERADE）を評価せずに抜ける」＝ NAT されない
> - `-I` は先頭に挿入（`-A` は末尾に追加）

**VM → インターネット**の通信（宛先が `192.168.1.0/24` 以外）は上のルールにマッチしないので、libvirt の MASQUERADE がそのまま効きます。つまり「LAN の別ホストとは素の IP で、インターネットへは今まで通り NAT で」を両立できます。

worker-2 VM 側には cloud-init の network-config で `192.168.122.0/24 via 192.168.1.35`（ホスト A 経由）の静的経路を入れます。これで双方向の経路が揃います。

### 永続化

iptables のルールは再起動で消えます。また libvirt は自分のネットワークを再起動するたびに自前のルールを入れ直すので、その後に自分のルールを再挿入する必要があります。`k8s-interconnect.service`（systemd unit）を作り、`After=libvirtd.service` で起動時とマニュアル実行時にルールを再適用します。**適用中にダウンタイムはありません**（既存接続は conntrack で維持される）。

### ハマり③: `iptables` の引数順

ルールを bash 配列で組んで展開したら、

```
iptables v1.8.10 (nf_tables): Invalid rule number 'nat'
```

`(-t nat POSTROUTING ...)` を `iptables -I "${arr[@]}"` で展開したので `iptables -I -t nat POSTROUTING ...` という順序になり、`-I` が「チェーン名」として `-t` を、「ルール番号」として `nat` を食べていました。

`-t nat` は**サブコマンド（`-I` 等）より前**に置く必要があります。関数化して解決:

```bash
rule_nosnat() {  # $1 = -C（確認） / -I（挿入） / -D（削除）
  sudo iptables -t nat "$1" POSTROUTING -s "$A" -d "$B" -j RETURN
}
```

`-C`（check）でルールの有無を確認してから `-I` するので冪等です。

### ハマり④: bridge をあきらめて macvtap に

当初はホスト B に **Linux ブリッジ `br0`**（物理 NIC と VM の仮想 NIC を同じ L2 セグメントに繋ぐ仮想スイッチ）を作る予定でした。ブリッジなら VM が LAN に直結され、素の IP で見えます。

ところがホスト B は **NetworkManager renderer** で netplan を使っており、`netplan try`（60 秒で自動ロールバックする安全な適用コマンド）が**ブリッジ構成の revert に非対応**でした。

```
Reverting/Applying config
An error occurred: ... reverting custom parameters for bridges is not supported
```

適用に失敗すると、SSH でしか触れない遠隔のホストでネットワークが壊れる = 詰みです。

→ **macvtap** に変更しました。

> **macvtap とは**
> 物理 NIC に「サブインタフェース」を生やし、そこに VM を直結する方式。ブリッジと違い**仮想スイッチを作らない**ので、ホスト側のネットワーク設定をほぼ変えずに済む（＝ SSH 断リスクが低い）。
> 制約: 同じ物理 NIC 上の **ホスト自身と VM は直接通信できない**（macvtap の仕様。L2 的にホストの NIC を「素通り」するため）。
> `bridge` モード（macvtap の中の一モード）だと VM 同士は通信できる。

制約の「ホスト B ↔ worker-2 が直接通信できない」は、Ansible をホスト A から実行する運用なので許容できました。`virt-install` のオプションは:

```
--network type=direct,source=enp3s0,source_mode=bridge
```

`config.env`（ホスト B 用）:

```bash
NET_MODE="macvtap"
MACVTAP_SOURCE="enp3s0"                        # ホスト B の LAN NIC
NET_PREFIX="192.168.1"
VM_GATEWAY="192.168.1.1"
VM_ROUTES="192.168.122.0/24,192.168.1.35"      # ホスト A の libvirt subnet 経由
VM_NAMESERVERS="192.168.1.1"
EXTRA_SSH_PUBKEYS="$(cat /tmp/hostA_id_ed25519.pub)"   # Ansible がホスト A から SSH するため
```

`NET_MODE` が `nat` 以外のときは cloud-init の **network-config（v2 形式）**を生成し、静的 IP + ゲートウェイ + 追加経路を焼き込みます（NAT のときは libvirt の DHCP に任せる）。

### ハマり⑤: taint が worker にも付く

`single_node_cluster: false` にすると control plane に taint を付け直す処理が走りますが、これが

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane=:NoSchedule
```

と **`--all`（全ノード対象）**になっていて、worker-1 にも taint が付いていました。結果、スケジューラが「置ける worker は worker-2 だけ」と判断し、全 Pod が worker-2 に偏っていました（気づいたのは監視を入れた第3回で、Pod 配置を見たとき）。

セレクタ指定に修正:

```bash
kubectl taint nodes -l node-role.kubernetes.io/control-plane \
  node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
```

`-l` はラベルセレクタ。control plane ノードには `node-role.kubernetes.io/control-plane` ラベルが付いているので、それだけを対象にできます。

### ハマり⑥: `30-workers.yml` の `run_once` + `when`

worker-2 を追加したとき、join コマンド取得タスクでこのエラー:

```
'dict object' has no attribute 'stdout'
```

該当タスクには **`run_once: true`**（インベントリ内の最初の 1 ホストだけで実行）と **`when: not kubelet_conf.stat.exists`**（未 join のときだけ）が両方付いていました。

worker-1 は既に join 済みなので `when` が false → タスク全体がスキップ → `join_cmd` 変数が未定義のまま → worker-2 の join タスクが `join_cmd.stdout` を参照して落ちる。

`kubeadm token create --print-join-command` は安い操作なので、`when` を外して**毎回実行**（`changed_when: false` で「変更あり」とは報告しない）に修正しました。

### 確認

```
$ kubectl get nodes -o wide
NAME           STATUS   ROLES           VERSION      INTERNAL-IP
k8s-cp-1       Ready    control-plane   v1.31.14     192.168.122.11
k8s-worker-1   Ready    <none>          v1.31.14     192.168.122.21
k8s-worker-2   Ready    <none>          v1.31.14     192.168.1.22
```

跨ぎで Pod・DNS が通ることも確認します（worker-2 の Pod から worker-1 の Pod / CoreDNS に到達できるか）。

ノード間で開いている必要があるポート:

| ポート | 用途 |
|---|---|
| TCP 6443 | kube-apiserver |
| UDP 8472 | Flannel VXLAN |
| TCP 10250 | kubelet API（`kubectl logs` / `exec` / metrics）|
| TCP 2379-2380 | etcd（control plane 冗長化時のみ）|

---

## 第1回まとめ

- KVM ホスト初期化・VM 払い出し・kubeadm・worker 追加まで全部スクリプト化
- 環境依存の値は `config.env` に集約、`inventory.ini` は IP だけ
- Ansible の冪等性のおかげで、ノード追加も設定変更も「`site.yml` 再実行」で済む
- **既存クラスタを止めずに別の物理ホストを worker にできた**
  - libvirt NAT の「LAN 向けだけ」を無効化 → ノード実 IP 同士が素で疎通
  - ブリッジは SSH 断リスクがあったので macvtap
  - Flannel VXLAN（UDP 8472）がサブネットを跨いで流れる
- ハマったのは `conntrack` 不足、cgroup ドライバ、iptables 引数順、bridge の revert 不可、taint の `--all`、Ansible の `run_once`+`when`

次回は、このクラスタに **Argo CD を入れて以降を全部 GitOps 化**し、Kong + Keycloak + Cloudflare Tunnel で実アプリをインターネット公開します。

→ 第2回: Argo CD で GitOps + Kong / Keycloak / Cloudflare Tunnel で公開
