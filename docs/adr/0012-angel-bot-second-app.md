# ADR-0012: 2 つ目のアプリとして Discord bot「天使ちゃん」を載せる（死活監視つき）

**Status:** Accepted
**Date:** 2026-09-02
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

Discord bot「天使ちゃん」（`angel-girl-discord-bot`）は、これまで
**クラスタの外**で systemd により手動運用していた。README に書かれた手順は
「VM に git clone → venv → systemd unit を書く → `systemctl start`」で、
更新は SSH して `git pull` する。

この運用には具体的な問題があった。

### 落ちても分からない

- ログは `logging.FileHandler('app.log', mode='w')` で開かれていた。
  **再起動のたびにログが切り詰められる**ので、「なぜ落ちたか」は再起動した瞬間に消える。
- 外形監視が無い。プロセスが死んでも、Discord 側と切断されて無反応になっても、
  誰かが「天使ちゃん反応しないね」と気づくまで分からない。
- `Restart=on-failure` は再起動こそするが、CrashLoop していても通知は無い。

### 起動しないことがある

コードを読み直したところ、次の 2 つは「設定を 1 つ忘れると必ず起動しない」構造だった。

- `chat_gpt.py` が **import 時に** `OpenAI(api_key=OPENAI_API_KEY)` を実行していた。
  キーが空だと openai SDK は `OpenAIError` を投げる。これは `ImportError` ではないので
  周囲の `except ImportError` に捕まらず、`apps.bot.main` の import 自体が失敗する。
- `main.py` が **import 時に** `bot.run()` を呼んでいた。
  そのためテストも起動前検証もできず、SIGTERM を受けて後始末する余地も無かった。

### そのほか実運用で効いていた不具合

- VoiceVox を `requests`（同期）で呼んでいた。合成に 1 秒かかれば、その 1 秒
  **bot 全体**（他サーバーの応答も gateway のハートビートも）が止まる。
- 読み上げ対象のチャンネルをプロセス全体で 1 組しか持っていなかった
  （`global_vars.py`）。2 つ目のサーバーで `ang-join` すると
  1 つ目の読み上げが黙って壊れる。
- 会話要約テーブルの主キーが `user_id` 単独なのに、参照は
  `(guild_id, channel_id, user_id)` だった。同じ人の要約が**サーバーをまたいで
  共有**され、かつ取り出せない行が残る。
- 読み上げ整形処理（URL 省略・カスタム絵文字の展開）は `tests/` の中にしか無く、
  本番の読み上げ経路からは呼ばれていなかった。URL がそのまま音読されていた。

一方で、クラスタ側は ADR-0010 で「ねこねこ保険」を載せたことにより、
Kong / Keycloak / CNPG / cloudflared / 監視（New Relic + OTel Collector）が
すでに揃っている。**2 つ目のアプリを載せる下地はできている。**

## Decision

**天使ちゃんをクラスタに載せ、他のアプリと同じ GitOps の流れに統合する。**
そのうえで「落ちたら分かる」ことを設計要件として明示的に作り込む。

### 1. 配置と配信経路

- `angel-bot` namespace に Deployment 1 レプリカ。
- Discord bot は **常に 1 個だけ**動かす（2 個動くと同じ発言に二重に反応する）。
  SQLite の PVC が ReadWriteOnce なので `strategy: Recreate` にして、
  新旧が同時に生きない構成にする。
- **Ingress は作らない。** bot は Discord へ *outbound* の WebSocket を張るだけで、
  外から入ってくる経路が要らない。ADR-0002 の Cloudflare Tunnel も Kong も通さない。
- VoiceVox エンジンは同じ namespace の Service（`voicevox:50021`）として分離する。
  以前は「bot と同じホストの localhost」を前提にしていた。

### 2. 死活監視: 3 層で構える

**bot 自身は自分の死を通知できない**（死んでいるので）。
したがって「bot が言うこと」に依存しない層を必ず外側に置く。

| 層 | 仕組み | 検出できるもの |
|---|---|---|
| **1. Kubernetes** | `/healthz`（liveness）| プロセス停止 / event loop の停止 |
| | `/readyz`（readiness）| Discord と切断・ハートビート途絶 |
| **2. watchdog CronJob** | 5 分ごとに `/readyz` を叩き、3 回連続失敗で Discord webhook | 上記すべて + CrashLoop |
| **3. New Relic** | OTLP で送るメトリクス・ログへの NRQL アラート | 傾向・原因調査 |

層 2 が「通知」の主役。仕組みが単純で、**New Relic 自体が落ちていても動く**。
層 3 は「なぜ落ちたか」を調べるためのもの。

`/readyz` の判定は次を **すべて**満たすこととする:

1. シャットダウン中でない
2. Discord クライアントが閉じていない
3. `on_ready` 済み
4. gateway のレイテンシが取得できる（`discord.py` は未接続だと `nan` を返す）
5. 直近の gateway イベントから 120 秒以内

4 と 5 があるので、「プロセスは生きているが Discord とは死んでいる」という
一番厄介な状態を検出できる。

**ヘルスサーバーは Discord へのログインより前に起動する。**
`setup_hook` はログイン成功後にしか呼ばれないため、そこで起動すると
トークン不正や Discord 障害のときに `/healthz` が一切応答せず、
監視側からは「接続拒否」としか見えない。理由つきの 503 を返せるようにする。

readiness が落ちると通常の Service からは Endpoint が消え、
「落ちていることの確認」自体ができなくなる。
そのため `publishNotReadyAddresses: true` の probe 用 Service を別に用意する。

### 3. ログ

- **stdout に 1 行 1 JSON。** ファイルには書かない。
  コンテナの標準出力は nri-bundle の Fluent Bit が拾って New Relic に送る（ADR-0008）。
  「再起動でログが消える」問題はこれで構造的に消える。
- Discord トークンと OpenAI キーを伏せる redaction フィルタを全ハンドラに付ける。
  設定値そのものに加え、**トークンの形をした文字列**も正規表現で伏せる。

### 4. 計装

ADR-0008 のとおり OpenTelemetry SDK → OTLP → `otel-collector`。
エンドポイントは **HTTP の :4318**（gRPC :4317 では届かないことが
`homelab-gitops/docs/design.md` §12 に記録されている）。

### 5. デプロイ

ADR-0007 / ADR-0001 の流れに合わせる。

```
push to main
  → GitHub Actions: test / lint / helm template / イメージ build
  → ghcr.io/tukapai/angel-girl-discord-bot:sha-xxxxxxxxxxxx
  → GITOPS_TOKEN で homelab-gitops の image.tag を書き換えて commit
  → Argo CD が app-angel-bot を自動同期
```

チャートはアプリリポの `chart/`、環境固有値は gitops の
`apps/angel-bot/values-prod.yaml`（パターン D）。nekoneko-* と完全に同じ形。

## Options Considered

### 載せる場所

| 案 | 内容 | 評価 |
|---|---|---|
| **A: クラスタに載せる（採用）** | 他アプリと同じ GitOps / 監視 / CI に統合 | 監視とデプロイの仕組みを 1 つに統一できる。VoiceVox の分だけメモリを食う |
| B: 現状維持（VM + systemd）| 触らない | 死活監視とデプロイを bot のためだけに別建てする必要がある。「落ちても分からない」が残る |
| C: 外部 PaaS（Fly.io 等）| クラスタ外 | ホームラボを持っている意味が薄い。VoiceVox の常時稼働が高くつく |

### 死活監視の通知経路

| 案 | 評価 |
|---|---|
| **A: watchdog CronJob + New Relic（採用）**| 単純な経路と賢い経路の二重化。CronJob 側は New Relic 障害時も動く |
| B: New Relic のアラートだけ | 設定が GUI 側に散る。New Relic が落ちると気づけない。無料枠のアラート数も気になる |
| C: bot 自身が定期的に「生きてます」と投稿 | **死んだら投稿が止まるだけで、誰も気づかない。**通知としては成立しない |
| D: k8s の Event / CrashLoop を人が見る | 見ない。見ないから今の状態になっている |

C を明確に否定しておくことが重要で、「bot が言うこと」に依存する監視は
監視ではない。

### readiness の判定条件

| 案 | 評価 |
|---|---|
| **A: 接続 + ハートビート + イベント鮮度（採用）**| 「プロセスは生きているが Discord とは死んでいる」を検出できる |
| B: プロセスが生きていれば ready | 一番危険な故障を素通しする |
| C: Discord API を毎回叩いて確認 | レート制限を食う。probe の頻度で叩くものではない |

## Trade-off Analysis

**B（現状維持）の誘惑は強い。**動いているものを触るのはリスクで、
実際いま天使ちゃんは（起動さえすれば）役目を果たしている。

しかし「落ちても分からない」を解くには、結局

- 外形監視の口（HTTP エンドポイント）
- 通知経路
- ログの保全

の 3 つが要る。これらは**クラスタ側に既にある**（probe / CronJob / Fluent Bit →
New Relic）。VM 上で同じものを作り直すと、bot のためだけに二重の運用が生まれる。
単独メンテナにとってこれは純損失。

コストは **VoiceVox の常駐メモリ（~512Mi〜1.5Gi）**。これは無視できないが、
worker-2 に固定し limits で上限を切ることで他アプリを守る。
読み上げを使わない時期が続くなら `replicas: 0` にできる。

→ **A**。

## Consequences

**楽になること**

- 落ちたら Discord に通知が来る。原因は New Relic の構造化ログで追える。
- 更新が `git push` だけになる。SSH して `git pull` する運用が消える。
- 設定を 1 つ忘れても起動する（機能が縮退するだけ）。
  OpenAI キーが無ければお話し機能だけが止まり、読み上げは動く。
- テストが書けるようになった（import しても bot が起動しないため）。
  5 件 → 121 件に増やし、上記の不具合はすべて回帰テストで固定した。
- マルチサーバー対応。2 つ目の Discord サーバーに入れても壊れない。

**難しくなること / 新たな負担**

- クラスタの常駐メモリが増える（bot ~192Mi + VoiceVox ~512Mi〜1.5Gi）。
  ADR-0003 の非力なクラスタでは無視できない。worker-2 のみに配置する。
- SealedSecret が 3 つ増える（ghcr-pull / bot 本体 / watchdog webhook）。
  sealing key のバックアップ（runbooks/backup-and-recovery.md）の重要度が上がる。
- 会話メモリ（SQLite）が PVC になった。local-path なのでノードに紐づく。
  worker-2 が死ぬと会話履歴は失われる（実害は小さいので許容する）。
- Discord bot は 1 レプリカ固定なので、更新時に数十秒の無応答が生じる。
- watchdog の webhook URL は bot とは別経路で持つ必要がある
  （bot の Secret に入れると、bot が壊れたときに一緒に読めなくなる意味は無いが、
  役割として分けておく）。

**あとで見直す**

- VoiceVox のメモリが厳しければ、読み上げを使うときだけ
  天使ちゃん自身に `replicas: 0 ↔ 1` させる（ゲームサーバーと同じ手口）。
- 会話メモリを SQLite から CNPG（ADR-0004）へ移すか。
  現状は 1 レプリカなので SQLite で足りている。
- New Relic の NRQL アラートを整備する（現状は watchdog が主）。

## Action Items

1. [x] `main.py` を import 副作用なしに分離し、SIGTERM で後始末する
2. [x] `chat_gpt.py` のクライアント生成を遅延化（キー未設定でも起動する）
3. [x] `/healthz` `/readyz` `/metrics` を提供するヘルスサーバー
4. [x] JSON ログ + 秘密の redaction フィルタ
5. [x] OTLP エクスポート（traces / metrics / logs、HTTP :4318）
6. [x] VoiceVox 呼び出しの非同期化とキュー上限
7. [x] ギルドごとの読み上げ状態（`global_vars` 廃止）
8. [x] 要約テーブルの複合主キー化 + 既存 DB の移行
9. [x] 読み上げ整形処理を本体へ移動
10. [x] Dockerfile（python:3.12-slim・非 root・ffmpeg/opus）
11. [x] Helm チャート（probe / RBAC / PVC / watchdog CronJob）
12. [x] CI（lint / test / helm template / イメージ起動確認）と
        release（ghcr push → gitops bump）
13. [x] `homelab-gitops` に Application と values-prod.yaml
14. [ ] SealedSecret を 3 つ生成して kustomization のコメントを外す
15. [ ] CI を 1 度回して初回イメージを作り、`image.tag` を sha に更新
16. [ ] Discord サーバーに `tenshi-admin` ロールを作成、`allowedGuildIds` を設定
17. [ ] 実際に落として、watchdog の通知が届くことを確認する（重要）
