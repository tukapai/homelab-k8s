# ADR-0008: 監視スタック（New Relic 常用 + Instana 評価、計装は OpenTelemetry で共通化）

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

design.md §11 では監視を「段階的に」としていたが、具体を決める。

- **New Relic** をこのインフラの**常用の監視**として使う（既に標準ツール）。
- **Instana** を**評価目的**で導入し、アプリ・インフラの可観測性を試したい。
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

`homelab-k8s/ansible/playbooks/60-host-agents.yml` で:

- **New Relic Infrastructure agent**（apt、常設）
- **Instana host agent**（`instana-agent-dynamic.amd64.deb` / apt、評価期間のみ）

物理マシン・libvirt・OS メトリクスを取る。k8s の外側なのでここは素直に host agent。

### 層 2（Kubernetes / ミドルウェア）: 各社の k8s 統合を Argo CD で

- **New Relic**: `nri-bundle` Helm（infra agent DaemonSet + nri-kubernetes +
  kube-state-metrics + Fluent Bit ログ）。**Pixie と nri-prometheus は当面無効**
  （非力クラスタ配慮）。**常設**。
- **Instana**: `instana-agent` Helm（Operator + DaemonSet）。PostgreSQL / Redis /
  nginx / ランタイムを自動ディスカバリ。**評価期間のみ**。
  `homelab-gitops/platform/eval/` に置き、撤去しやすくする。

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
- ホスト層は Ansible playbook 1 本で両エージェント。
- Instana の撤去が容易（gitops の `platform/eval/` を削除 + host agent 停止）。

**難しくなること / 新たな負担**
- 評価期間中、監視だけで **~2 CPU / ~2.5GB** をクラスタから食う。
  アプリ/PG/Redis のリソース余裕が減る。requests/limits を注意深く。
- OTel Collector という新コンポーネントの運用。
- API キー（New Relic license / Instana agent key）を SealedSecret で管理（ADR-0006）。
- New Relic と Instana でメトリクス名・タグ体系が違い、ダッシュボードは各社別。
- 評価の撤去を**忘れない**運用（カレンダー登録推奨）。

**あとで見直す**
- 評価結果で監視ツールを一本化 → ADR-000X で決定、不要な方を撤去。
- クラスタに余裕が出たら Pixie / nri-prometheus / Grafana などを追加検討。
- OTel Collector を DaemonSet + Gateway 2 段構成にするか（規模が出たら）。

## Action Items

1. [ ] `homelab-gitops/platform/otel-collector/`（Deployment + config、両社へ export）
2. [ ] `homelab-gitops/platform/newrelic/`（`nri-bundle` Application、最小 values、
       license key の SealedSecret）
3. [ ] `homelab-gitops/platform/eval/instana/`（`instana-agent` Application、
       agent key の SealedSecret）
4. [ ] `homelab-k8s/ansible/playbooks/60-host-agents.yml`（NR infra agent 常設 +
       Instana host agent 評価用）
5. [ ] `app-template`: OTel SDK 初期化のサンプルと chart の `OTEL_*` env 配線
6. [ ] `docs/runbooks/instana-eval.md`（セットアップ + 撤去手順、評価チェックリスト）
7. [ ] design.md §11 を本 ADR に合わせて更新
8. [ ] 評価終了日をカレンダー登録
