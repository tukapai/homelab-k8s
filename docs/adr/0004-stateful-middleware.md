# ADR-0004: PostgreSQL は CloudNativePG、queue/cache は Redis

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

アプリは Web API + **リレーショナル DB** + **ジョブキュー** + **キャッシュ**。

- 運用者 1人。ミドルウェアの運用（バックアップ、フェイルオーバー、
  アップグレード）をなるべく宣言的にしたい。
- 当面は単一ノードにステートフルが集中する（ADR-0003）。
  → **ノード故障時のデータ保護 = オフホストへのバックアップ**が必須。
- クラスタは非力。重いブローカー（Kafka 等）は避けたい。
- キューの用途は「API が投入 → worker が処理」の一般的なジョブキュー。
  現時点でストリーミングや多数コンシューマのファンアウトは要件にない。

## Decision

### PostgreSQL: CloudNativePG（CNPG）operator

- 当面 **1 インスタンス**（`instances: 1`）。
- **スケジュールバックアップ**（base + WAL アーカイブ）を
  S3 互換オブジェクトストレージ（Cloudflare R2 または Backblaze B2）へ。
  → PITR とクラスタ再構築時のリストアが宣言的に可能。
- API を複数レプリカにする段階で **CNPG 内蔵 Pooler（PgBouncer）** を有効化。
- 読みレプリカ / HA は物理ノード追加後に `instances: 2+` で対応（ADR-0003）。

### Queue + Cache: Redis 1 インスタンス

- **cache と queue を 1 つの Redis で兼ねる**。
- queue はアプリ言語のライブラリ（Sidekiq / BullMQ / Celery / RQ 等）で実装。
- 永続化: queue 用途があるので **AOF 有効**（`appendonly yes`）。
- アプリ側で **キューのインターフェースを抽象化**しておき、将来
  NATS JetStream 等へ差し替え可能にする。

## Options Considered

### DB — Option A: CloudNativePG（採用）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low–Med（CRD で Cluster を宣言）|
| Backup/Restore | ◎ 宣言的（`ScheduledBackup` + WAL、PITR）|
| Failover | ◎ operator が管理（複数インスタンス時）|
| Overhead | 小（operator + Postgres 本体）|

**Pros:** バックアップ・リストア・フェイルオーバー・マイナーアップグレードが
すべて宣言的。活発なプロジェクト。GitOps と相性良。
**Cons:** operator の概念を覚える。CNPG 固有の運用知識。

### DB — Option B: 素の StatefulSet + 公式イメージ

**Pros:** 依存ゼロ、単純。
**Cons:** バックアップ・PITR・フェイルオーバーを全部自作。1人には負担大。

### DB — Option C: Zalando postgres-operator

**Pros:** 実績豊富、HA(Patroni)。
**Cons:** Spilo イメージ含め一式が重め、設定の癖。CNPG より学習コスト高。

### DB — Option D: マネージド（Neon / Supabase / RDS 等）

**Pros:** 運用ほぼゼロ。
**Cons:** 月額、データが自宅外に出る、外向き egress とレイテンシ、
「homelab で完結」という趣旨から外れる。

### Queue — Option A: Redis（採用）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（1 コンポーネントで cache と兼用）|
| 言語サポート | ◎ どの言語にもライブラリ |
| 配信保証 | 中（ライブラリ依存、厳密な at-least-once は設計次第）|
| Overhead | 小（約 100–256Mi）|

**Pros:** cache と queue を 1 つで賄える。エコシステムが巨大。運用が枯れている。
**Cons:** ネイティブなストリーム/コンシューマグループは Redis Streams で可能だが、
JetStream ほどの永続・再配信の作り込みはない。大規模ファンアウトには不向き。

### Queue — Option B: NATS + JetStream

**Pros:** 軽量、cloud-native、pub/sub・ストリーム・ワークキューが綺麗。
**Cons:** もう 1 コンポーネント。cache は別途 Redis が必要（結局 2 つ）。
クライアントライブラリの普及度は Redis に劣る。

### Queue — Option C / D: RabbitMQ / Kafka

**Pros:** 本格的なメッセージング / イベント基盤。
**Cons:** 非力クラスタにはオーバースペック。運用重い。現要件に対して過剰。

### Queue — Option E: マネージド（Upstash 等）

**Pros:** 運用ゼロ。
**Cons:** 月額・外部依存・レイテンシ。homelab の趣旨外。

## Trade-off Analysis

**DB**: 1人運用で最も効くのは「バックアップ/リストア/フェイルオーバーが
宣言的か」。B は初期は楽だがその 3 つを自作する羽目になる。C/D は
それぞれ重さ・コスト・データ主権の難点。CNPG はちょうど中間で、
GitOps とも噛み合う。→ **A**。

**Queue**: 現要件（単純なジョブキュー）+ cache が別途必要、という前提だと、
Redis 1 つで両方賄えるのが最小構成。JetStream の強みが要る要件はまだない。
アプリ側でキューを抽象化しておけば、後で B へ移行しても影響を局所化できる。
→ **A**（Redis）。

## Consequences

**楽になること**
- DB のバックアップ・PITR・（将来の）フェイルオーバーが manifest で完結。
- cache + queue が 1 コンポーネント。監視・運用対象が減る。

**難しくなること / 新たな負担**
- オブジェクトストレージ（R2/B2）のバケットと認証情報が必要（Sealed Secret）。
- 単一インスタンスなので**ノード故障 = 一時ダウン**。復旧は「バックアップから
  リストア」または「物理ノードにレプリカ追加してスイッチ」（ADR-0003）。
- Redis を queue に使う以上、AOF の I/O とディスク使用に注意。
- 要件が育つと Redis→JetStream 移行の可能性（抽象化で緩和）。
- CNPG / Redis のアップグレード追従。

**あとで見直す**
- 読みレプリカ / HA が必要になったら CNPG `instances` を増やす（物理ノード後）。
- キューにストリーミング・多数コンシューマ・厳密な再配信が要るなら
  NATS JetStream を追加（cache は Redis のまま）。
- バックアップ先を複数リージョン / 複数プロバイダに。

## Action Items

1. [ ] R2（または B2）バケット作成、アクセスキーを Sealed Secret 化
2. [ ] `gitops/platform/cnpg-operator/` に CloudNativePG operator
3. [ ] `gitops/apps/<app>/base/` に CNPG `Cluster`（`instances: 1`）+
       `ScheduledBackup` + `nodeSelector: worker`
4. [ ] `gitops/apps/<app>/base/` に Redis（StatefulSet、`appendonly yes`、
       `nodeSelector: worker`、requests/limits）
5. [ ] アプリに「キュー」インターフェースを定義（実装は Redis バックエンド）
6. [ ] リストア手順を `docs/runbooks/restore-postgres.md` に清書し、実際に試す
