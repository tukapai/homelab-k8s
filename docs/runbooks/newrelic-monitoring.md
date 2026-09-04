# Runbook: New Relic で天使ちゃんを詳しく監視する

ADR-0008（監視スタック）と ADR-0012（天使ちゃん）の実運用編。
**何がどの経路で New Relic に入るか**を押さえてから、
NRQL・アラート・ダッシュボードを作る。

---

## 1. データの流れ（まずこれを把握する）

```
天使ちゃん(Pod)
  ├─ stdout に JSON ログ ──▶ Fluent Bit (nri-bundle) ──▶ New Relic  [Log]
  ├─ OTLP metrics ─────────▶ otel-collector :4318 ────▶ New Relic  [Metric]
  └─ OTLP traces  ─────────▶ otel-collector :4318 ────▶ New Relic  [Span]

Kubernetes 自体
  └─ nri-kubernetes / KSM ─────────────────────────────▶ New Relic  [K8s*Sample]
```

| 種類 | NRQL の型 | 中身 |
|---|---|---|
| ログ | `Log` | bot の構造化ログ（`level` / `error.class` / `error.stack` / `guild_id` …） |
| アプリのメトリクス | `Metric` | `angel_bot_*`（下表） |
| トレース | `Span` | `openai.chat.completions` / `gameserver.start` など |
| k8s インフラ | `K8sContainerSample` / `K8sPodSample` | 再起動回数・CPU・メモリ・Pod 状態 |

> **⚠️ ログの二重取り込みに注意。**
> `OTEL_LOGS_ENABLED=true` にすると OTLP でもログを送るため、
> Fluent Bit の分と合わせて **同じログが 2 回**入る（コストもノイズも倍）。
> 既定は `false`。トレースとログを厳密に相関させたい場合だけ true にし、
> そのときは Fluent Bit 側で `angel-bot` namespace を除外すること。

### アプリが送るメトリクス

| 名前 | 種別 | ラベル | 意味 |
|---|---|---|---|
| `angel_bot_up` | gauge | — | 1=Discord 接続済み / 0=未接続 |
| `angel_bot_gateway_latency_seconds` | gauge | — | gateway のレイテンシ |
| `angel_bot_uptime_seconds` | gauge | — | 起動からの経過秒 |
| `angel_bot_guilds` | gauge | — | 参加サーバー数 |
| `angel_bot_voice_connections` | gauge | — | ボイス接続数 |
| `angel_bot_tts_queue_depth` | gauge | `guild_id` | 読み上げ待ち |
| `angel_bot_messages_seen_total` | counter | — | 観測メッセージ数 |
| `angel_bot_tts_enqueued_total` / `_played_total` | counter | `guild_id` | 読み上げ |
| `angel_bot_tts_failures_total` / `_dropped_total` | counter | `guild_id` | 読み上げ失敗・キュー溢れ |
| `angel_bot_chat_requests_total` / `_failures_total` | counter | `model` | OpenAI |
| `angel_bot_command_invocations_total` / `_errors_total` | counter | `command` | コマンド |
| `angel_bot_gateway_reconnects_total` | counter | — | 再接続回数 |
| `angel_bot_game_actions_total` / `_failures_total` | counter | `server`, `action` | ゲームサーバー操作 |

一度も記録されていないカウンタも **0 を送る**ようにしてある。
「まだ失敗 0 件」と「そもそも届いていない」を区別するため。

---

## 2. まず疎通を確認する

デプロイ後、**データが本当に届いているか**を最初に確かめる。
届いていないのに気づかないのが一番まずい。

```sql
-- メトリクスが来ているか（1 行でも返れば OK）
SELECT uniques(metricName)
FROM Metric
WHERE metricName LIKE 'angel_bot_%'
SINCE 30 minutes ago
```

```sql
-- ログが来ているか
SELECT count(*) FROM Log
WHERE service.name = 'angel-bot'
SINCE 30 minutes ago
```

```sql
-- トレースが来ているか
SELECT count(*) FROM Span
WHERE service.name = 'angel-bot'
SINCE 1 hour ago
```

空なら:
- `kubectl -n angel-bot logs deploy/angel-bot | grep -i otel` で
  「OpenTelemetry トレースを有効化しました」が出ているか
- `values-prod.yaml` の `otel.enabled: true` か
- エンドポイントが **:4318（HTTP）** か。`:4317`（gRPC）だと届かない
- `kubectl -n observability logs deploy/otel-collector` にエラーが無いか

---

## 3. アラート（ここが本題）

New Relic の **Alerts → Alert conditions → NRQL** で作る。

### 3-1. ★ 天使ちゃんが死んだ（Loss of signal）

**これが New Relic 側の死活監視の主役。**
「値が閾値を超えた」ではなく「**データが来なくなった**」で発報させる。
プロセスが死ねばメトリクスも止まるので、これが一番確実に落下を捉える。

```sql
SELECT latest(angel_bot_up)
FROM Metric
WHERE service.name = 'angel-bot'
```

- **Signal loss**: `Open a new incident` を有効化、`Signal loss expiration` を **180 秒**
  （メトリクスの export 周期は 60 秒なので、3 回分の欠測で発報）
- **Threshold**: `below 1` を `for at least 5 minutes` でも 1 本作る
  → こちらは「プロセスは生きているが Discord と切れている」を捉える
- `Fill data gaps with`: **Last known value** にしない（欠測を検出したいので）

> クラスタ内の watchdog CronJob（5 分ごとに `/readyz`）とは**わざと二重化**している。
> CronJob は仕組みが単純で New Relic 障害時も動く。
> New Relic 側は「なぜ落ちたか」を調べる材料つきで通知できる。

### 3-2. エラーログが増えた

```sql
SELECT count(*)
FROM Log
WHERE service.name = 'angel-bot' AND level = 'ERROR'
```
閾値: `above 5` / `for at least 5 minutes`

### 3-3. Discord への再接続を繰り返している

```sql
SELECT derivative(angel_bot_gateway_reconnects_total, 5 minutes)
FROM Metric
WHERE service.name = 'angel-bot'
```
閾値: `above 3`（5 分に 3 回以上の再接続はネットワーク側を疑う）

### 3-4. gateway が遅い

```sql
SELECT latest(angel_bot_gateway_latency_seconds) * 1000
FROM Metric
WHERE service.name = 'angel-bot'
```
閾値: `above 1000`（ms）/ `for at least 10 minutes`

### 3-5. 読み上げが失敗し続けている（VoiceVox 不調）

```sql
SELECT derivative(angel_bot_tts_failures_total, 5 minutes)
FROM Metric
WHERE service.name = 'angel-bot'
```
閾値: `above 5`

### 3-6. OpenAI の失敗率が高い

```sql
SELECT derivative(angel_bot_chat_failures_total, 10 minutes)
FROM Metric
WHERE service.name = 'angel-bot'
```
閾値: `above 3`（キー失効・レート制限・残高切れで一気に増える）

### 3-7. Pod が再起動を繰り返している（CrashLoop）

```sql
SELECT latest(restartCount)
FROM K8sContainerSample
WHERE containerName = 'bot' AND namespaceName = 'angel-bot'
```
閾値: `above 3` / `for at least 15 minutes`

### 3-8. メモリが上限に近い

```sql
SELECT latest(memoryWorkingSetBytes) / latest(memoryLimitBytes) * 100
FROM K8sContainerSample
WHERE containerName = 'bot' AND namespaceName = 'angel-bot'
```
閾値: `above 90`（%）。Minecraft と同時起動でここが効く（ADR-0013）

### 3-9. ゲームサーバーの操作が失敗している

```sql
SELECT derivative(angel_bot_game_action_failures_total, 10 minutes)
FROM Metric
WHERE service.name = 'angel-bot'
FACET server, action
```
閾値: `above 0`（RBAC 不足や namespace 誤りは即わかる）

---

## 4. 通知を Discord に飛ばす

New Relic → **Alerts → Destinations → Webhook**。

- **Endpoint URL**: Discord のチャンネル webhook URL
- **Custom payload**（Discord は `content` フィールドを読む）:

```json
{
  "content": "🚨 **{{ annotations.title.[0] }}**\n状態: {{ state }}\n優先度: {{ priority }}\n{{#if issuePageUrl}}{{ issuePageUrl }}{{/if}}"
}
```

Workflow で「どの条件をこの宛先に流すか」を選ぶ。
`angel-bot` のタグで絞ると、ねこねこ保険側のアラートと混ざらない。

> watchdog CronJob と同じチャンネルに送ると重複するので、
> **別チャンネル**（例 `#alerts-newrelic`）にするか、
> watchdog は「最後の砦」として残しつつ New Relic 側を主にする、と決めておく。

---

## 5. ダッシュボード

**Dashboards → Create → 各ウィジェットに以下の NRQL**。

```sql
-- 稼働状況（Billboard）
SELECT latest(angel_bot_up) AS '接続', latest(angel_bot_guilds) AS 'サーバー数',
       latest(angel_bot_voice_connections) AS 'ボイス接続'
FROM Metric WHERE service.name = 'angel-bot'
```

```sql
-- 稼働時間（Billboard）。再起動すると 0 に戻るので、落ちた回数が視覚的に分かる
SELECT latest(angel_bot_uptime_seconds) / 3600 AS '稼働時間(h)'
FROM Metric WHERE service.name = 'angel-bot'
```

```sql
-- gateway レイテンシの推移（Line）
SELECT average(angel_bot_gateway_latency_seconds) * 1000 AS 'ms'
FROM Metric WHERE service.name = 'angel-bot' TIMESERIES SINCE 6 hours ago
```

```sql
-- 読み上げの成否（Area）
SELECT derivative(angel_bot_tts_played_total, 1 minute) AS '再生',
       derivative(angel_bot_tts_failures_total, 1 minute) AS '失敗',
       derivative(angel_bot_tts_dropped_total, 1 minute) AS 'キュー溢れ'
FROM Metric WHERE service.name = 'angel-bot' TIMESERIES SINCE 6 hours ago
```

```sql
-- コマンドの利用状況（Bar）
SELECT sum(angel_bot_command_invocations_total)
FROM Metric WHERE service.name = 'angel-bot' FACET command SINCE 1 day ago
```

```sql
-- エラーログ（Table）
SELECT timestamp, `error.class`, message
FROM Log WHERE service.name = 'angel-bot' AND level = 'ERROR'
SINCE 1 day ago LIMIT 50
```

```sql
-- OpenAI のトークン消費（コスト監視。Line）
SELECT sum(`gen_ai.usage.total_tokens`)
FROM Span WHERE service.name = 'angel-bot' AND name = 'openai.chat.completions'
TIMESERIES SINCE 1 day ago
```

```sql
-- ゲームサーバーの操作履歴（Table）
SELECT timestamp, `gameserver.name`, `gameserver.action`, `gameserver.actor`,
       `gameserver.state`, duration
FROM Span WHERE service.name = 'angel-bot' AND name LIKE 'gameserver.%'
SINCE 7 days ago LIMIT 100
```

```sql
-- Pod の再起動（Billboard）
SELECT latest(restartCount) FROM K8sContainerSample
WHERE containerName = 'bot' AND namespaceName = 'angel-bot'
```

---

## 6. ログを掘る

ログは 1 行 1 JSON で出しているので、フィールドがそのまま属性になる。
New Relic は JSON 形式のログ本文を自動でパースする。
されていない場合は **Logs → Parsing** で `service.name = angel-bot` に対する
JSON パースルールを 1 つ作る。

```sql
-- 落ちた瞬間の原因を見る（スタックトレースつき）
SELECT timestamp, `error.class`, `error.message`, `error.stack`
FROM Log WHERE service.name = 'angel-bot' AND `error.class` IS NOT NULL
SINCE 1 day ago
```

```sql
-- 特定のサーバーで何が起きているか
SELECT * FROM Log
WHERE service.name = 'angel-bot' AND guild_id = '<ギルドID>'
SINCE 3 hours ago
```

```sql
-- 起動と停止の履歴（何回落ちたか）
SELECT timestamp, message FROM Log
WHERE service.name = 'angel-bot'
  AND message IN ('天使ちゃんを起動します', 'シャットダウンを開始します')
SINCE 7 days ago
```

> **秘密情報はログに出ない。** Discord トークンと OpenAI キーは
> redaction フィルタで伏せている（設定値そのものに加え、
> トークンの形をした文字列も正規表現で伏せる）。
> ただし過信せず、ログを共有する前には目視すること。

---

## 7. トレース

Distributed tracing で `angel-bot` を選ぶと、以下の span が見える。

| span 名 | 属性 | 使いどころ |
|---|---|---|
| `openai.chat.completions` | `gen_ai.request.model`, `gen_ai.usage.*_tokens` | 応答が遅い / トークンを使いすぎ |
| `gameserver.start` / `.stop` / `.restart` | `gameserver.name`, `.actor`, `.state` | 誰がいつ操作したか、何秒かかったか |

`gen_ai.usage.total_tokens` はコスト監視に直結する。
モデルによっては usage が返らないので、その場合は属性が付かない。

---

## 8. 注意点

- **メトリクスの粒度は 60 秒**（OTLP の export 周期）。
  それより短い事象は捉えられない。秒単位が必要なら周期を縮めるが、
  非力なクラスタ（ADR-0003）では送信量が増えるので慎重に。
- **`guild_id` ラベルはカーディナリティに注意。** サーバーが増えるほど
  時系列が増える。個人利用の範囲なら問題ないが、
  数百サーバーに入れるならラベルを外すこと。
- **無料枠**（100GB/月）。ログが一番食う。
  `LOG_LEVEL=DEBUG` にすると一気に増えるので、常用は `INFO`。
- Instana の評価期間中（ADR-0008）は otel-collector の ConfigMap が
  差し替わっていることがある。メトリクスが来ないときはここも疑う。

---

## 9. 関連

- ADR-0008: 監視スタックの選定
- ADR-0012: 天使ちゃんの死活監視設計（3 層構成の意図）
- [angel-bot-down.md](angel-bot-down.md): 実際に落ちたときの切り分け手順
