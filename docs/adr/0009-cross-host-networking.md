# ADR-0009: 複数 KVM ホストにまたがるクラスタのネットワーク

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

ADR-0003 の「物理ノード追加」を実施する。2 台目の物理マシン
（`192.168.1.188`）を用意し、その上の **VM** を `k8s-worker-2` にする
（ユーザー選択。ベアメタルではなく VM）。

- 1 台目の KVM ホスト（`192.168.1.35`）: libvirt **NAT** ネットワーク
  `192.168.122.0/24` に `k8s-cp-1`(.11) と `k8s-worker-1`(.21)。
  この subnet は 1 台目のホストからしか到達できない。
- 2 台目の worker VM は別セグメント（LAN `192.168.1.0/24`）に置くことになる。
- **Flannel は VXLAN でノード間トンネルを張り、両端に各ノードの InternalIP を
  使う。** 経路上に NAT（source IP 書き換え）があると、対向が期待する
  送信元と一致せずトンネルが確立しない。
- 既存クラスタは稼働中。ダウンタイムは避けたい。
- ホームルーターの設定変更ができるかは不確実（「任せる」）。

## Decision

1. **2 台目の worker は host B 上の VM を `192.168.1.0/24` に直結**。
   方式は **macvtap（`NET_MODE=macvtap`）を既定**とする。既存 NIC に直付けする
   ので host B 側のブリッジ作成（netplan 変更 = SSH 断リスク）が不要。
   VM に静的 IP（例 `192.168.1.22`）を cloud-init で設定。
   - 制約: macvtap では **host B 自身と worker VM が直接通信できない**。
     Ansible / kubectl は host A から流すので実運用上は許容。
   - host B ↔ VM 通信が要る場合のみ `NET_MODE=bridge` +（手動で `br0` 作成）。

2. **1 台目のホストで、libvirt subnet ↔ LAN の間だけ NAT を無効化**する。
   `scripts/04-interconnect.sh add`:
   - `iptables -t nat -I POSTROUTING -s 192.168.122.0/24 -d 192.168.1.0/24 -j RETURN`
     （libvirt の MASQUERADE より前 → VM↔LAN は素通し、VM→インターネットの NAT は維持）
   - `iptables -I FORWARD` に双方向 ACCEPT（libvirt の REJECT より前）
   - systemd oneshot ユニットで libvirt リロード / 再起動後も復元
   - **ネットワーク再定義なし = ダウンタイムなし**

3. **worker VM に 1 台目 subnet への静的経路**
   `192.168.122.0/24 via 192.168.1.35`（`config.env` の `VM_ROUTES`、
   `02-create-node-vm.sh` が cloud-init network-config に埋める）。
   既存の cp / worker-1 は既定 GW が 1 台目ホスト（`192.168.122.1`）なので
   追加設定不要。

4. **（推奨・任意）ホームルーターに静的ルート
   `192.168.122.0/24 via 192.168.1.35`** を追加。すると LAN 全体（Mac 含む）
   からクラスタ subnet に直接到達でき、`mac/` の SSH トンネルが不要になる。

## Options Considered

### Option A: 部分的 NAT 無効化 + 静的経路（採用）

| Dimension | Assessment |
|---|---|
| Complexity | 中（iptables 3 本 + systemd + VM 経路 1 本）|
| ダウンタイム | **なし** |
| ルーター依存 | なし（推奨オプションとしてはあり）|
| 可逆性 | 高（`04-interconnect.sh remove`）|

**Pros:** 稼働クラスタに触れずに済む。対象は host A / host B / worker VM の
3 点だけ。既存 `40-expose-console.sh` と同じ運用パターン。
**Cons:** iptables ルールを libvirt の内部ルールより前に挿す前提に依存。
LAN の他機器はルーター静的ルートを足さない限り subnet に届かない。

### Option B: libvirt を routed モードに変更 + ルーター静的ルート

| Dimension | Assessment |
|---|---|
| Complexity | 中（`net-define` + 再起動）|
| ダウンタイム | 数秒（`net-destroy`/`net-start` で cp/worker-1 が瞬断）|
| ルーター依存 | **必須**（無いと戻り経路が消える）|

**Pros:** 宣言的（libvirt XML に載る）。masquerade が完全に外れて挙動が素直。
**Cons:** 稼働中のクラスタでネットワーク再起動。consumer ルーターは
静的ルート不可のこともある。ルーター無しだと全機器に手動ルートが要る。

### Option C: 全ノードを LAN ブリッジへ移行

**Pros:** フラットな L2。ルーティング不要。Flannel は `host-gw` も選べる。
**Cons:** cp の IP が変わる → `apiserver-advertise-address` / 証明書 SAN /
kubeconfig / join 設定を作り直し。破壊的。得られるものに対して割に合わない。

### Option D: host B にも routed な libvirt subnet（192.168.123.0/24）

**Pros:** host A と対称的な構成。
**Cons:** 管理する subnet が 3 つ。ルーティングが増える。VM を LAN 直結する
だけの A/B に対して複雑さだけ増える。

## Trade-off Analysis

要件は「稼働クラスタを止めない」「ルーター設定に依存しない形も選べる」。
C は破壊的、D は複雑。B は宣言的で美しいが、**稼働中のネットワーク再起動**と
**ルーター必須**が引っかかる。

A は iptables の運用パターンが既に repo にあり（`40-expose-console.sh`）、
ダウンタイムゼロ・可逆・対象 3 点で完結する。ルーター静的ルートは
「あると Mac のトンネルも消せる」ボーナスとして推奨に留める。→ **A**。

## Consequences

**楽になること**
- 稼働クラスタを止めずに 3 ノード目を追加できる。
- ルーター静的ルートを入れれば `mac/` の SSH トンネルが不要に。
- `02-create-node-vm.sh` が bridge モード対応 → 以後の LAN 直結ノードが楽。

**難しくなること / 新たな負担**
- host A に iptables ルール + systemd ユニットがもう 1 つ
  （`k8s-interconnect.service`）。libvirt の内部ルール順序に依存。
- host B が新たに KVM ホスト（`scripts/01` + `br0` ブリッジ設定が必要）。
- worker-2 は別 subnet なので inventory / トポロジで「LAN 側」と意識が要る。
- **etcd は依然 cp 単独** = まだ真の HA ではない（ADR-0003）。物理 2 台に
  なったので、次は control-plane の冗長化 or etcd 外出しが視野に入る。

**あとで見直す**
- control-plane を HA 化するなら、この段でネットワーク設計を再検討
  （routed モード or 全ノード LAN 直結が選択肢に戻る）。
- ノードがさらに増えたら Cilium など overlay 非依存の CNI も検討。

## Action Items

1. [ ] host B に `scripts/01-install-kvm-host.sh` + `br0` ブリッジ（netplan）
2. [ ] host A で `./scripts/04-interconnect.sh add`
3. [ ] host B の `config.env`: `NET_MODE=bridge` / `LIBVIRT_NET=br0` /
       `NET_PREFIX=192.168.1` / `VM_GATEWAY` / `VM_ROUTES`
4. [ ] `ROLE=worker NODE_NUM=2 ./scripts/02-create-node-vm.sh`（host B）
5. [ ] `inventory.ini` に `k8s-worker-2 ansible_host=192.168.1.22`
6. [ ] `group_vars/all.yml`: `single_node_cluster: false`（済）→ `site.yml`
7. [ ] Flannel が worker-2 で Ready、Pod 間疎通（別ノードの Pod へ ping / DNS）
8. [ ] （任意）ルーターに `192.168.122.0/24 via 192.168.1.35`
9. [ ] 詳細手順は `docs/runbooks/add-physical-node.md`
