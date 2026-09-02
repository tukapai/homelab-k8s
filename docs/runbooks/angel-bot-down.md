# Runbook: 天使ちゃんが落ちたとき

ADR-0012 の死活監視が発報したとき、または「天使ちゃんが反応しない」と
言われたときの手順。

## 0. まず状況を切り分ける

Discord に 🚨 の通知が来た場合、watchdog CronJob が
`/readyz` に 3 回連続で失敗している。

```bash
export KUBECONFIG=~/homelab-k8s/ansible/kubeconfig

# Pod は居るか。何回再起動しているか。
kubectl -n angel-bot get pod -l app.kubernetes.io/name=angel-bot

# readyz が何と言っているか（これが一番情報量が多い）
kubectl -n angel-bot run curl-tmp --rm -it --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  curl -s http://angel-bot-probe:8080/readyz
```

`/readyz` は「なぜ ready でないか」を `reasons` に日本語で返す。
ここを最初に読むこと。

| reasons の内容 | 意味 | 次に見るところ |
|---|---|---|
| `Discord gateway が ready でない` | 起動中、またはログイン失敗 | §1 |
| `gateway イベントが N 秒間途絶` | Discord とは繋がっているが無反応 | §2 |
| `Discord 接続が閉じている` | 切断された | §2 |
| `gateway ハートビートが取得できない` | 未接続 | §1 / §2 |
| （そもそも応答が無い）| Pod が居ない / CrashLoop | §3 |

## 1. ログインできていない

```bash
kubectl -n angel-bot logs deploy/angel-bot --tail=50
```

ログは 1 行 1 JSON。`level` が `ERROR` の行を探す。

| ログ | 原因 | 対処 |
|---|---|---|
| `Discord へのログインに失敗しました` | トークンが無効 / 失効 | Discord Developer Portal で再発行 → `make seal-angel-bot ...` → commit/push |
| `特権 intent が有効になっていません` | Portal 側の設定漏れ | Developer Portal → Bot → **MESSAGE CONTENT INTENT** を有効化 → Pod を再起動 |
| `必要な環境変数が設定されていません: BOT_TOKEN` | Secret が届いていない | §4 |

## 2. Discord と繋がらない / 無反応

まず Discord 側の障害を疑う（自分のせいとは限らない）:

- https://discordstatus.com/

Discord が正常なら:

```bash
# 再接続を繰り返していないか
kubectl -n angel-bot logs deploy/angel-bot --tail=100 | grep -i "gateway\|disconnect\|resumed"

# メトリクスで確認
kubectl -n angel-bot run curl-tmp --rm -it --restart=Never \
  --image=curlimages/curl:8.11.1 -- \
  curl -s http://angel-bot-probe:8080/metrics | grep -E "angel_bot_up|reconnect|latency"
```

`angel_bot_gateway_reconnects_total` が増え続けているならネットワーク側を疑う。
worker-2 のホスト（B、`192.168.1.188`）から外への疎通を確認する。

一時的な切断は自動で復帰する。10 分待っても戻らなければ再起動:

```bash
kubectl -n angel-bot rollout restart deploy/angel-bot
```

## 3. Pod が起動しない / CrashLoopBackOff

```bash
kubectl -n angel-bot describe pod -l app.kubernetes.io/name=angel-bot
# 直前のコンテナのログ（落ちた理由はここ）
kubectl -n angel-bot logs deploy/angel-bot --previous --tail=100
```

| 症状 | 原因 | 対処 |
|---|---|---|
| `ImagePullBackOff` | ghcr の pull secret | §4。`make seal-ghcr-ns NS=angel-bot PAT=...` |
| `CreateContainerConfigError` | Secret のキー不足 | §4 |
| Pod が `Pending` | PVC がノードに固定されている | `kubectl -n angel-bot describe pvc`。worker-2 が居るか確認 |
| OOMKilled | メモリ上限 | `values-prod.yaml` の `resources.limits.memory` を上げる。Minecraft と同時起動していないか確認（ADR-0013）|

## 4. Secret まわり

```bash
kubectl -n angel-bot get secret angel-bot-secrets -o jsonpath='{.data}' | tr ',' '\n'
kubectl -n angel-bot get sealedsecret
```

`SealedSecret` はあるのに `Secret` が無い場合、復号に失敗している:

```bash
kubectl -n kube-system logs deploy/sealed-secrets-controller --tail=30
```

`no key could decrypt secret` なら、sealing key が変わっている
（クラスタを作り直した等）。`backup-and-recovery.md` の手順で鍵を復元するか、
`make seal-angel-bot ...` で作り直す。

## 5. どうしても直らないとき

天使ちゃんが居なくても、ゲームサーバーは `kubectl` で直接操作できる:

```bash
kubectl -n gameservers scale statefulset/minecraft --replicas=1   # 起動
kubectl -n gameservers scale statefulset/minecraft --replicas=0   # 停止
```

Argo が replicas を戻すことは無い（ADR-0013 の `ignoreDifferences`）。

## 6. 落ち着いたら

- New Relic で該当時刻のログを見る（`service.name = angel-bot`）。
  stdout の JSON がそのまま構造化ログとして入っている。
  `error.class` / `error.stack` で原因を追える。
- 同じことが再発しそうなら、回帰テストを 1 つ足してから直す
  （`tests/` に 121 件ある。ここに足す）。

## 付録: 監視が本当に動くかを確かめる

**試していない監視は監視ではない。** ときどき次を実行する:

```bash
# わざと止めて、5 分以内に Discord へ通知が来ることを確認する
kubectl -n angel-bot scale deploy/angel-bot --replicas=0
# …通知を確認したら戻す
kubectl -n angel-bot scale deploy/angel-bot --replicas=1
```

通知が来なければ、watchdog CronJob と webhook の SealedSecret を確認する:

```bash
kubectl -n angel-bot get cronjob angel-bot-watchdog
kubectl -n angel-bot get job -l app.kubernetes.io/component=watchdog
kubectl -n angel-bot logs job/<最新の watchdog job>
```
