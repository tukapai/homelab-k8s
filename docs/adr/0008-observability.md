# ADR-0008: 監視スタック（New Relic 常用 + Instana 評価、計装は OpenTelemetry で共通化）

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

design.md §11 では監視を「段階的に」としていたが、具体を決める。

- **New Relic** をこのインフラの**常用の監視**として使う（既に標準ツール）。
- **Instana** を**評価目的**で導入する。特に検証したいのは
  **通常のエージェント（データ収集）と Instana バックエンドの AI 機能
  （Smart Alerts / 自動 Root Cause / AI Assistant / MCP Server）の連携**。
- Instana は**検証が終わったら削除する前提の一時導入**。関連コード・設定は
  リポジトリにコミットしない（GitOps 外・gitignore）。
- したがって当面は **2 つの監視スタックを並行稼働**させる（評価期間）。
- クラスタは非力（ADR-0003: cp 8GB + worker 4GB を暫定共用）。監視エージェントの
  リソース消費は無視できない。
- アプリは Go（`app-template`）。Go はエージェントによる自動計装が効かず、
  トレースには SDK 組み込み（コード変更）が必要。
- ADR-0007 の方針（アプリを他プラットフォームへ移せる余地）を監視でも守りたい
  = ベンダー固有の SDK を 2 つ埋め込むのは避けたい。
- 監視対象は 3 層:
  1. **ホスト / KVM**（物理マシン、libvirt、OS）
  2. **Kubernetes / ミドルウェア**（ノード、Pod、PostgreSQL、Redis、ingress）
  3. **アプリケーション**（トレース、メトリクス、ログ）

## Decision

### 計装（アプリ）: OpenTelemetry で 1 回だけ

アプリは **OpenTelemetry SDK** で計装し（traces + metrics + logs）、OTLP で
**OpenTelemetry Collector**（クラスタ内、Deployment）に送る。Collector が
**Instana と New Relic の両方**へ fan-out する。

```
app (OTel SDK) ──OTLP──▶ OTel Collector ──┬─▶ Instana agent (OTLP :4317)
                                          └─▶ New Relic OTLP (otlp.nr-data.net)
```

→ コード変更は 1 回。評価終了後に Instana を外しても Collector の exporter を
1 つ消すだけ。将来の AWS 移行でもそのまま使える。

### 層 1（ホスト / KVM）: 両者のネイティブ host agent を KVM ホストに

物理マシン・libvirt・OS メトリクスを取る。k8s の外側なのでここは素直に host agent。

- **New Relic Infrastructure agent**（apt、常設）
  → `homelab-k8s/ansible/playbooks/60-host-agents.yml`（コミット対象）
- **Instana host agent**（`instana-agent-dynamic.amd64.deb` / apt、評価期間のみ）
  → `homelab-k8s/ansible/playbooks/local/60b-instana-host-agent.yml`（gitignore）

### 層 2（Kubernetes / ミドルウェア）: 各社の k8s 統合を Argo CD で

- **New Relic**: `nri-bundle` Helm（infra agent DaemonSet + nri-kubernetes +
  kube-state-metrics + Fluent Bit ログ）。**Pixie と nri-prometheus は当面無効**
  （非力クラスタ配慮）。**常設・GitOps 管理**。
- **Instana**: `instana-agent` Helm（Operator + DaemonSet）。PostgreSQL / Redis /
  nginx / ランタイムを自動ディスカバリ。**評価期間のみ・GitOps 外**。
  `homelab-gitops/platform/eval/instana/install.sh`（helm 直接）で導入・撤去。
  関連ファイルは gitignore（`/platform/eval/`、`bootstrap/children/platform-eval-*`、
  `platform/otel-collector/eval-instana/`）。

### Instana の AI 機能の検証方法

AI 機能はすべて**バックエンド側**で、エージェントが送ったデータ
（メトリクス / トレース / ログ / トポロジ / イベント）を対象に動く。
エージェント側に AI 用の特別な設定はない。検証は
`docs/runbooks/instana-eval.md`（gitignore）の §AI 機能の検証:

- Smart Alerts: ベースライン学習 → 意図的な異常 → 発報
- Incidents / 自動 RCA: 依存障害（DB 停止 → API エラー）で root cause を当てるか
- AI Assistant: 自然言語 Q&A がデータに基づくか
- MCP Server: API トークンで起動し、外部 LLM / エージェントが観測データを使えるか

### 評価の時間箱

Instana は**期限を切る**（例: 4 週間）。評価終了時に
[runbooks/instana-eval.md](../runbooks/instana-eval.md) の手順で撤去。
2 スタック常設はこのクラスタの容量では非現実的。

## Options Considered

### 計装方式

| 案 | 内容 | 評価 |
|---|---|---|
| **A: OTel + Collector fan-out（採用）** | SDK 1 つ、Collector が両社へ | コード変更 1 回、ベンダー中立、移植可。Collector 分のリソース(+~150Mi) |
| B: Instana Go SDK + New Relic Go agent 両方 | 各社ネイティブ | 実装 2 系統、コードがベンダーに密結合、評価終了後もコードに痕跡 |
| C: どちらか一方だけ計装 | 妥協 | 評価にならない / 常用が手薄に |
| D: eBPF 自動計装（Pixie / Grafana Beyla 等）| コード変更なし | Pixie は重い。Beyla は別コンポーネント。Go の HTTP は取れるが DB スパン等は限定的。補助的にはあり |

### 層 2 の New Relic 構成

| 案 | 評価 |
|---|---|
| **nri-bundle 最小（infra + k8s + KSM + logs）（採用）** | 必要十分。~0.6–0.9GB |
| nri-bundle フル（+ Pixie + prometheus）| Pixie が重く非力クラスタに不適 |
| OTel Collector から New Relic だけに送る | k8s インフラ/イベント/自動統合が手薄 |

### Instana in-cluster vs host agent のみ

| 案 | 評価 |
|---|---|
| **Operator + DaemonSet（採用、評価期間）** | k8s・ミドルウェアの本来の体験。~0.5–0.75GB/node |
| host agent のみ | 導入は軽いが k8s の可視性が不足。評価にならない |

## Trade-off Analysis

**計装**: B は評価が終わってもコードにベンダー依存が残り、ADR-0007 の移植性に
反する。A は Collector 分のオーバーヘッドと引き換えに、計装を資産として中立に
保てる。→ **A**。

**並行稼働**: 公平な評価には既存ツール（New Relic）と Instana を同一環境で
同時に回す必要がある。だが両方**常設**はクラスタ容量的に無理。
→ New Relic 常設 + Instana **時間箱**。評価結果で「Instana に寄せる / New Relic
継続」を後日 ADR で決める。

## Consequences

**楽になること**
- アプリ計装が 1 系統（OTel）。監視ツールの差し替えが exporter 設定だけ。
- Instana は GitOps 外・gitignore なので、撤去してもリポジトリに痕跡が残らない
  （`install.sh uninstall` + host playbook `-e instana_state=absent` + Collector を sync 戻し）。
- New Relic（常用）は GitOps 管理で通常どおり。

**難しくなること / 新たな負担**
- 評価期間中、監視だけで **~2 CPU / ~2.5GB** をクラスタから食う。
  アプリ/PG/Redis のリソース余裕が減る。requests/limits を注意深く。
- OTel Collector という新コンポーネントの運用。
- Instana 評価中は OTel Collector の Argo 自動同期を一時停止して ConfigMap を
  手差し替えする（`eval-instana/`）。戻し忘れると trace が Instana に流れ続ける。
- New Relic license は SealedSecret（ADR-0006）。Instana の key は評価用に
  `install.sh` / host playbook が直接 `kubectl create secret` / ファイル配置（git 外）。
- New Relic と Instana でメトリクス名・タグ体系が違い、ダッシュボードは各社別。
- 評価の撤去を**忘れない**運用（カレンダー登録必須）。gitignore 済みなので
  「消し忘れても push で漏れない」が、稼働リソースは残る。

**あとで見直す**
- 評価結果で監視ツールを一本化 → ADR-000X で決定、不要な方を撤去。
- クラスタに余裕が出たら Pixie / nri-prometheus / Grafana などを追加検討。
- OTel Collector を DaemonSet + Gateway 2 段構成にするか（規模が出たら）。

## Action Items

**常用（コミット済み）**

1. [x] `homelab-gitops/platform/otel-collector/`（Deployment + config、New Relic へ export）
2. [x] `homelab-gitops/platform/newrelic/`（`nri-bundle` Application、最小 values）
3. [x] `homelab-k8s/ansible/playbooks/60-host-agents.yml`（NR infra agent 常設）
4. [x] `app-template`: chart の `OTEL_*` env 配線 + README に Go SDK 骨子
5. [x] design.md §11 を本 ADR に合わせて更新
6. [ ] New Relic license key を `make seal-newrelic` で封入、リージョン設定

**評価（GitOps 外・gitignore）**

7. [x] `homelab-gitops/platform/eval/instana/install.sh`（helm 直接、導入/撤去）
8. [x] `homelab-k8s/ansible/playbooks/local/60b-instana-host-agent.yml`
9. [x] `homelab-gitops/platform/otel-collector/eval-instana/`（ConfigMap 一時差し替え）
10. [x] `docs/runbooks/instana-eval.md`（AI 機能の検証手順 + 撤去 + チェックリスト）
11. [ ] Instana テナント / agent key / endpoint / API トークンを用意
12. [ ] 評価終了日をカレンダー登録
13. [ ] 評価後: ツール一本化を別 ADR で決定、Instana 資産を撤去
