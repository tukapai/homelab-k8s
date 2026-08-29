# ADR-0003: 当面は単一物理ホスト、後日 物理ノード追加、暫定は cp の taint 解除

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

現在のクラスタ:

- KVM ホスト（物理 1 台、Ubuntu 24.04、約 64GB RAM）
- `k8s-cp-1`: 4 vCPU / 8GB / **taint NoSchedule**
- `k8s-worker-1`: 2 vCPU / 4GB（空きは実質 3.5GB 前後）

これから載せる想定:

- プラットフォーム: Argo CD / ingress-nginx / cloudflared / sealed-secrets /
  CloudNativePG operator / Redis（ADR-0001,0002,0004,0005）
- アプリ: Web API / worker / PostgreSQL インスタンス

概算で **プラットフォームだけで 1.5–2GB**。worker 単独ではアプリまで載らない。

制約:

- 物理ホストが 1 台である限り、worker VM をいくら増やしても
  **物理故障で全滅**する。真の HA にはならない。
- 可用性は「バックアップ + IaC による高速再構築」で担保する方針。

## Decision

1. **今は VM のスペック変更も VM 追加もしない。**
2. **2 台目の物理マシンを後日調達**し、LAN 上で `k8s-worker-2` として
   join させる（ブリッジ接続、README「別の物理マシンをノードにする」）。
3. **暫定策**: `group_vars/all.yml` の `single_node_cluster: true` にして
   `20-control-plane.yml` に cp の taint を外させる。プラットフォーム Pod を
   cp(8GB) + worker(4GB) の計 ~12GB に分散させる。
4. **ステートフル（PostgreSQL / Redis）は `nodeSelector` で worker に固定**。
   データを cp に置かない（local-path PV はどのみちノード固定）。
5. すべてのプラットフォーム/アプリ Pod に **resource requests/limits を設定**し、
   cp の apiserver/etcd をワークロードが圧迫しないようにする。
6. 物理ノード join 後: `single_node_cluster: false` に戻して cp を再 taint、
   プラットフォームを worker 群へ、PostgreSQL は無停止移行（下記）。

## Options Considered

### Option A: cp の taint を暫定的に外す（採用）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（フラグ 1 つ + nodeSelector）|
| Cost | ゼロ（VM 変更なし）|
| Reversibility | 高（フラグを戻して再 taint）|
| Risk | 中（control-plane がワークロードと同居）|

**Pros:** インフラ変更ゼロで即着手。可逆。ホスト RAM を無駄にしない。
**Cons:** cp がワークロードと資源を共有。requests/limits を怠ると
apiserver/etcd が不安定化するリスク。「本番では cp を汚さない」原則から一時逸脱。

### Option B: worker VM を 8–16GB に増強

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（`config.env` 変更 + VM 作り直し）|
| Cost | ゼロ（ホストに RAM 余裕あり）|
| Reversibility | 中（また作り直し）|
| Risk | 低 |

**Pros:** クリーン。cp を汚さない。ホストに余力あり。
**Cons:** VM 作り直し（5–10 分 + 再 join）。ユーザーは「増強しない」と選択済み。
物理 1 台の SPOF は変わらない。

### Option C: 同一ホストに worker VM を 2 台目追加

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med |
| Cost | ゼロ |
| Risk | 低 |

**Pros:** スケジューリングの分散、実運用に近い形。
**Cons:** B と実質同じ効果で管理対象が増えるだけ。物理 SPOF は不変。

### Option D: 今すぐ 2 台目の物理ノードを追加

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med（ハード調達 + ブリッジ構成）|
| Cost | ハードウェア費 |
| Risk | 低（唯一 HA に近づく）|

**Pros:** 物理冗長への第一歩。cp を汚さず容量も確保。
**Cons:** ハードが今ない。今すぐは不可。

## Trade-off Analysis

D が本筋だがハードが未調達。B/C はクリーンだがユーザーは VM 変更を望まず、
かつ物理 SPOF は解消しない（＝ VM をいじる価値が薄い）。

A は「物理ノードが来るまでの純粋なつなぎ」。可逆で、インフラ変更ゼロ。
唯一のリスク（cp とワークロードの同居）は **resource requests/limits の徹底**と
**ステートフルの worker 固定**で管理できる。物理ノード到着時に本来の姿へ戻す。
→ **A**（暫定）+ **D**（本命、時期未定）。

## Consequences

**楽になること**
- インフラを一切いじらずにアプリ/プラットフォーム構築を開始できる。

**難しくなること / 新たな負担**
- 全 Pod に requests/limits を必ず設定する規律が要る（cp 保護のため）。
- 物理ノード join 時に「cp 再 taint + プラットフォーム移動 + DB 移行」作業。
- それまで **HA なし**。ノード/ホスト故障 = ダウン。対策はバックアップ
  （ADR-0004）と IaC 再構築のみ。
- ブリッジネットワーク構成（物理ノードは NAT 外の LAN に置く必要）。

**あとで見直す（物理ノード join 時のランブック）**
1. 物理マシンに Ubuntu + `scripts/01`、`config.env` を `LIBVIRT_NET=br0` 等に
2. `inventory.ini` に `k8s-worker-2` を追加し `site.yml`
3. `group_vars/all.yml`: `single_node_cluster: false` → `site.yml`（cp 再 taint）
4. PostgreSQL: CNPG Cluster の `instances` を一時的に増やして新ノードに
   レプリカ作成 → スイッチオーバー → 旧インスタンス削除
5. Redis: バックアップ（RDB/AOF）から新ノードで作り直し、または
   一時レプリカ経由で移行
6. プラットフォーム App の `nodeSelector` / affinity を worker 群向けに更新

## Action Items

1. [ ] `group_vars/all.yml`: `single_node_cluster: true`（暫定）→ `site.yml`
2. [ ] プラットフォーム/アプリの Kustomize base に requests/limits を必須化
3. [ ] PostgreSQL / Redis の manifest に `nodeSelector: {kubernetes.io/hostname: k8s-worker-1}`
       （または worker 用ラベルを付与）
4. [ ] cp の kubelet に system-reserved / kube-reserved を検討（apiserver 保護）
5. [ ] 物理ノード追加ランブックを `docs/runbooks/add-physical-node.md` に清書
6. [ ] ハードウェア調達の検討（予算・時期）
