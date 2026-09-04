# Runbook: ゲームサーバーの運用

ADR-0013 の実運用手順。普段の操作は Discord から、
困ったときは `kubectl` から。

## 普段の操作（Discord）

| したいこと | コマンド | 権限 |
|---|---|---|
| 一覧と状態を見る | `/game list` | 誰でも |
| 詳しい状態を見る | `/game status minecraft` | 誰でも |
| 起動する | `/game start minecraft` | `tenshi-admin` |
| 停止する | `/game stop minecraft` | `tenshi-admin`（確認ボタンあり）|
| 再起動する | `/game restart minecraft` | `tenshi-admin`（確認ボタンあり）|
| ログを見る | `/game logs minecraft` | `tenshi-admin` |
| バックアップする | `/game backup minecraft` | `tenshi-admin` |

- 起動には **数分**かかる（JVM 起動 + ワールド読み込み）。
  `/game start` の直後は繋がらない。`/game status` が 🟢 になるまで待つ。
- **誰も居ない状態が 30 分続くと自動で停止する。**
  停止したら通知チャンネルにお知らせが出る。
- 停止・再起動は、遊んでいる人が居ると人数と名前を出して警告する。

## 参加者向け: サーバーへの繋ぎ方

ADR-0013 のとおり、ルーターのポートを開けていないので
**Cloudflare のトンネル経由**で繋ぐ。参加者に以下を伝える。

### 1. cloudflared を入れる（初回だけ）

- Windows: `winget install --id Cloudflare.cloudflared`
- macOS: `brew install cloudflared`
- Linux: https://github.com/cloudflare/cloudflared/releases

### 2. 遊ぶたびに、繋ぐ前に実行する

```bash
cloudflared access tcp --hostname mc.example.com --url localhost:25565
```

このウィンドウは**開いたままにしておく**（閉じると切断される）。
初回はブラウザが開いて Cloudflare Access の認証を求められる。

### 3. Minecraft から接続する

サーバーアドレスに **`localhost:25565`** を入れる。
（`mc.example.com` ではない。トンネルの手前に繋ぐ）

> 摩擦が大きいのは承知の上での構成（ADR-0013 の Trade-off）。
> 参加者が増えて厳しくなったら、ポート転送方式への切り替えを検討する。

## 管理者向け: Cloudflare 側の設定（初回のみ）

1. Cloudflare Zero Trust ダッシュボード → Networks → Tunnels
   → 既存のトンネル（ADR-0002 で作ったもの）を編集
2. **Published application routes** に追加:
   - Type: `TCP`
   - URL: `tcp://minecraft.gameservers.svc.cluster.local:25565`
   - Hostname: `mc.example.com`（実際のドメインに読み替え）
3. Access → Applications で `mc.example.com` に対する
   self-hosted アプリを作り、許可するメールアドレスを登録する
4. **RCON（25575）は絶対にトンネルに載せないこと。**
   これは天使ちゃん専用で、外に出す理由が無い。
   そのために Service を `minecraft` と `minecraft-rcon` に分けてある。

## kubectl での直接操作

天使ちゃんが落ちているときの代替手段。

```bash
export KUBECONFIG=~/homelab-k8s/ansible/kubeconfig

# 起動 / 停止
kubectl -n gameservers scale statefulset/minecraft --replicas=1
kubectl -n gameservers scale statefulset/minecraft --replicas=0

# 状態
kubectl -n gameservers get statefulset,pod
kubectl -n gameservers logs minecraft-0 --tail=50

# コンソール（RCON）
kubectl -n gameservers exec -it minecraft-0 -- rcon-cli
```

Argo CD が replicas を戻すことは無い（ADR-0013 の `ignoreDifferences`）。

## バックアップ

### 自動

> **いまは止めてあります（`suspend: true`）。**
> Minecraft がまだ 1 度も起動していないうちは、ワールドの PVC
> `data-minecraft-0` も Secret `minecraft-rcon` も存在しないため、
> この CronJob は毎晩かならず失敗します。常に赤い Job が並ぶと
> 監視そのものが信用されなくなるので、使い始めるまで止めています。
> 再開手順は
> [`apps/gameservers/backup-cronjob.yaml`](https://github.com/tukapai/homelab-gitops/blob/main/apps/gameservers/backup-cronjob.yaml)
> の先頭コメントにあります（RCON の Secret → 1 度起動 → `suspend: false` → 手動で 1 回実行して確認）。

毎日 04:00 JST（19:00 UTC）に `minecraft-backup` CronJob が走る。
`itzg/mc-backup` が RCON で `save-off` → `save-all` → tar → `save-on` を行うので、
**サーバーを止めずに**整合性のあるバックアップが取れる。7 日分保持。

```bash
kubectl -n gameservers get cronjob minecraft-backup
kubectl -n gameservers get job -l app.kubernetes.io/component=backup
```

### 手動

Discord から `/game backup minecraft`。CronJob をテンプレートに Job を作る。
`suspend: true` は定期実行を止めるだけなので、**手動のこちらは止まっていない**
（ただしワールドと RCON の Secret が無ければ当然失敗する）。

### 中身を見る

```bash
kubectl -n gameservers debug -it minecraft-0 --image=busybox --target=minecraft -- \
  ls -lh /backups
```

### 復元

> ⚠️ **この手順はまだ一度も実行していない**（ADR-0013 Action Item 12）。
> 本当に必要になる前に一度試すこと。試していない手順は手順ではない。

```bash
# 1. サーバーを止める
kubectl -n gameservers scale statefulset/minecraft --replicas=0

# 2. 復元用の Pod を立てて、両方の PVC をマウントする
kubectl -n gameservers apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: mc-restore
spec:
  nodeSelector:
    kubernetes.io/hostname: k8s-worker-2
  containers:
    - name: restore
      image: busybox:1.37
      command: ["sleep", "3600"]
      volumeMounts:
        - { name: data, mountPath: /data }
        - { name: backups, mountPath: /backups }
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: data-minecraft-0 }
    - name: backups
      persistentVolumeClaim: { claimName: minecraft-backups }
EOF

# 3. 戻したい世代を選んで展開する
kubectl -n gameservers exec -it mc-restore -- sh -c 'ls -lt /backups'
kubectl -n gameservers exec -it mc-restore -- sh -c '
  rm -rf /data/world* && tar -xzf /backups/<選んだファイル>.tgz -C /data'

# 4. 後始末してから起動
kubectl -n gameservers delete pod mc-restore
kubectl -n gameservers scale statefulset/minecraft --replicas=1
```

> バックアップは現在 worker-2 のノード内 PVC にしかない。
> worker-2 が全損するとワールドも失われる。R2 への転送は TODO
> （`homelab-gitops/docs/design.md` §15）。

## 困ったとき

| 症状 | 原因 | 対処 |
|---|---|---|
| `/game start` しても 🟡 のまま | 起動に時間がかかっている | 5 分待つ。`/game logs` で進行を見る |
| ずっと 🔴 異常 | CrashLoop | `kubectl -n gameservers logs minecraft-0 --previous` |
| Pod が `Pending` | worker-2 のメモリ不足 | 他の重い Pod を確認。ADR-0013 の容量の話 |
| プレイヤー数が出ない | RCON に繋がっていない | RCON パスワードが bot 側と一致しているか確認（`make seal-angel-bot` の `RCON=`）|
| 遊んでいるのに自動停止した | 人数取得が失敗していた | 本来は「人数不明なら止めない」実装。`/game logs` と bot のログを確認 |
| `cloudflared access tcp` が繋がらない | Access の許可 / トンネル設定 | Zero Trust ダッシュボードで該当アプリの許可メールを確認 |

## ゲームを増やす

コード変更は不要（ADR-0013）。

1. `homelab-gitops/apps/gameservers/` にマニフェストを足す
   （`minecraft.yaml` を複製。**`replicas: 0` を守ること**）
2. `kustomization.yaml` の `resources` に足す
3. `homelab-gitops/apps/angel-bot/values-prod.yaml` の
   `gameServers.registry.servers` にエントリを足す
4. commit / push → Argo が同期 → bot が ConfigMap を読み直す
   （bot の Pod は ConfigMap の checksum で再起動する）

`namespace` は `gameservers` のままにすること。
bot の RBAC はこの namespace にしか無く、
他を指定すると registry の読み込み時点で拒否される。
