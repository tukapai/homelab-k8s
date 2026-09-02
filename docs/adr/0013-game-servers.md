# ADR-0013: ゲームサーバーはクラスタに載せ、公開は Cloudflare Tunnel の TCP で行う

**Status:** Accepted
**Date:** 2026-09-02
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

天使ちゃん（ADR-0012）に「ゲームサーバーの管理」をさせたい。
具体的には Discord から起動・停止・状態確認・バックアップができること。

ここには 2 つの独立した問題がある。

### 問題 1: どこで動かし、どう操作させるか

ゲームサーバー（まずは Minecraft）をクラスタに載せると、
bot は Kubernetes API 経由で操作できる。ただし bot に API 権限を与えるので、
**Discord のコマンド 1 つでクラスタに何ができてしまうか**を厳密に決める必要がある。

### 問題 2: どうやって外から繋ぐか — これが本題

現状のクラスタは **HTTP しか外に出せない**。

```
Internet → Cloudflare → Tunnel → cloudflared(Pod) → Kong(ClusterIP) → 各 Service
```

- ADR-0002: 公開は Cloudflare Tunnel。**ルーターのポートは 1 つも開けていない。**
- ADR-0005: MetalLB を入れていない。`type: LoadBalancer` は使えない。
- Kong は HTTP/HTTPS の Ingress コントローラ。**ホスト名で振り分ける**。

しかし Minecraft は **生の TCP 25565**。HTTP ではないので Ingress に載らない。
「Host ヘッダで振り分ける」という前提が成立しない。

つまり既存の公開経路はそのままでは使えず、**新しい判断が要る**。

### 問題 3: そもそも載るのか（容量）

- `k8s-cp-1`: 4 vCPU / 8GB（taint 済み、システム専用）
- `k8s-worker-1`: 2 vCPU / 4GB（実質の空きは 3.5GB 前後）
- `k8s-worker-2`: 物理ホスト B 上の VM。**このリポジトリにスペックの記録が無い。**
  現在ステートフルとアプリの配置先になっている（ADR-0003 の「フルスペック機」）。

プラットフォームだけで 1.5–2GB（ADR-0003）、
監視が New Relic + Instana 並行で ~2–2.5GB（ADR-0008 の評価期間）。
そこに Minecraft の JVM 2GB を**常時**足すのは現実的でない。

## Decision

### 1. クラスタに載せる。ただし普段は止めておく

`gameservers` namespace に **`replicas: 0` の StatefulSet** として置く。
遊ぶときだけ天使ちゃんが 1 にする。

- 停止中のコストは PVC のディスクだけ。メモリも CPU も使わない。
- 誰も居ない状態が 30 分続いたら bot が自動で 0 に戻す
  （RCON の `list` でプレイヤー数を見る）。
- **人数が取得できないときは自動停止しない。** 数えられないのに止めるのは最悪の挙動。

これにより「非力なクラスタに 2GB の常駐を足す」問題が
「遊んでいる間だけ 2GB を借りる」問題に変わる。

### 2. ★ Argo CD に replicas を同期させない

`app-gameservers` の Application で `/spec/replicas` を `ignoreDifferences` に入れる。

これが無いと:

```
/game start minecraft → bot が replicas を 1 に
  → Argo が「Git では 0 なのに 1 だ」と判断
  → selfHeal が 0 に戻す
  → 起動直後に落ちる（原因が非常に分かりにくい）
```

Git 上の `replicas: 0` は「初回作成時の値」でしかなく、
以降の起動・停止の権限は完全に bot 側にある、と決める。

### 3. 公開は Cloudflare Tunnel の TCP（`cloudflared access tcp`）

**採用**: Cloudflare Tunnel に `tcp://minecraft.gameservers.svc.cluster.local:25565`
のルートを追加し、参加者はクライアント側で

```bash
cloudflared access tcp --hostname mc.example.com --url localhost:25565
```

を実行してから、Minecraft で `localhost:25565` に接続する。

**理由**: ADR-0002 の「ルーターのポートを開けない」という判断を維持できる唯一の案。
自宅の IP アドレスが露出せず、DDoS の的にならず、
ISP のインバウンド制限にも左右されない。Cloudflare Access で
「誰が繋いでよいか」も制御できる。

**代償**: 参加者全員が `cloudflared` をインストールし、
繋ぐ前にコマンドを 1 つ実行する必要がある。**これは小さくない摩擦**で、
身内で遊ぶ範囲を超えると現実的でなくなる。

### 4. bot に与える Kubernetes 権限

`gameservers` namespace に閉じた **Role のみ**（ClusterRole は作らない）。

| 対象 | verb | 理由 |
|---|---|---|
| `statefulsets`, `deployments` | get/list/watch | 状態表示 |
| `statefulsets/scale`, `deployments/scale` | get/update/patch | 起動・停止 |
| `pods` | get/list/watch | Pod の状態・再起動回数 |
| `pods/log` | get | `/game logs` |
| `cronjobs` | get/list | バックアップのテンプレート読み取り |
| `jobs` | get/list/create | バックアップの実行 |

**与えないもの**（明示的に決めておく）:

- `secrets` の読み取り … RCON パスワードは env で渡す。API から読ませない。
- `pods/exec` … これがあると実質何でもできる。
- workload 本体の `update` / `delete` … **`scale` サブリソースだけに絞る**ことで、
  Discord のコマンドからイメージやコマンドを差し替えられないようにする。
- namespace 横断の権限、`nodes` へのアクセス。

さらに Discord 側でも二重に絞る:

- 変更系コマンドは `tenshi-admin` ロール（または明示した user ID、サーバー所有者）のみ。
- `ALLOWED_GUILD_IDS` に無いサーバーからは、管理者であっても拒否。
- 停止・再起動は**確認ボタン**を挟む（遊んでいる人が居れば人数を出して警告する）。
- registry が許可外の namespace を指していたらコードが読み込みを拒否（RBAC と二重）。

### 5. ゲームを増やすのは設定変更にする

bot 側はプロバイダ抽象（`start/stop/status/logs/backup`）と
YAML の registry で構成する。2 つ目のゲームを足すのは
`values-prod.yaml` に数行足すだけで、**コード変更を伴わない**。

## Options Considered

### 公開方式（本題）

| 案 | 仕組み | Pros | Cons | 判定 |
|---|---|---|---|---|
| **A: Cloudflare Tunnel の TCP（採用）**| `cloudflared access tcp` でクライアントがトンネルを張る | ポート開放ゼロ。自宅 IP を秘匿。ADR-0002 と整合。Access で認可できる | **参加者全員が cloudflared を入れる必要がある**。UX の摩擦が大きい | ✅ |
| B: NodePort + ルーターのポート転送 | ルーターで 25565 を worker に転送 | 参加者は普通に IP:ポートで繋げる。摩擦ゼロ | **自宅 IP が露出**し DDoS の的になる。ADR-0002 の判断を覆す。ISP がインバウンドを塞いでいる可能性。動的 IP なら DDNS も要る | 次善 |
| C: hostPort / hostNetwork | Pod をノードのポートに直結 | NodePort より単純 | B と同じ露出の問題に加え、Pod がノードに固定される。B より優位性が無い | ❌ |
| D: MetalLB を入れて `type: LoadBalancer` | LAN に固定 IP を払い出す | k8s らしい | **これは外部公開の解にならない。** MetalLB が配るのは LAN の IP であって、インターネットからの到達性は別問題（結局 B が必要）。ADR-0005 を覆すコストに見合わない | ❌ |
| E: k8s の外（KVM ホスト上）で直接動かす | docker compose 等 | ネットワークが単純 | bot からの操作手段を別に作る必要がある（SSH?）。ADR-0001 の GitOps から外れる。管理対象が二重化 | ❌ |
| F: 公開しない（LAN 内のみ）| そのまま | 一番安全 | 友人と遊べない。目的を満たさない | ❌ |

**D について補足**: 「LoadBalancer が無いから公開できない」というのは誤解で、
MetalLB を入れても外部公開の問題は解けない。ここを混同すると
「とりあえず MetalLB を入れる」という無駄な判断に至るので明記しておく。

### 起動・停止の主体

| 案 | 評価 |
|---|---|
| **A: bot が scale する（採用）**| Discord から完結。RBAC を絞れば影響範囲は明確 |
| B: 常時起動 | 非力なクラスタで 2GB を常時占有。ADR-0003 と衝突 |
| C: 人が `kubectl scale` する | それができるなら bot は要らない。目的を満たさない |
| D: 接続を検知して自動起動（オンデマンド）| 理想だが、TCP の待ち受けプロキシを自作することになる。Minecraft のクライアントは待ってくれず、初回接続は必ず失敗する。複雑さに見合わない |

### バックアップ

| 案 | 評価 |
|---|---|
| **A: itzg/mc-backup の CronJob（採用）**| RCON で save-off/save-all/save-on を挟むので、稼働中でも整合性が取れる。bot からの手動実行も同じ CronJob をテンプレートに使える |
| B: PVC のスナップショット | local-path は CSI スナップショット非対応 |
| C: バックアップしない | ワールドが飛んだら終わり。ADR-0003 の「バックアップ + 再構築」方針に反する |

## Trade-off Analysis

**公開方式が最大の争点。** A（Tunnel TCP）と B（ポート転送）は
「安全性」と「参加者の手間」を正面から交換している。

B の魅力は本物で、参加者は何も準備せずアドレスを入れるだけで繋がる。
ゲームサーバーとして「正しい」体験はこちら。

しかし B を採ると:

- ADR-0002 で明示的に選んだ「ポートを開けない」という前提が崩れる。
  一度開けると、以後「なぜ開いているか」を管理し続ける必要がある。
- Minecraft サーバーは**恒常的にスキャンされる**。公開 IP:25565 は
  数時間で探索対象になる。単独メンテナが守り続けるには重い。
- 自宅の IP が Minecraft サーバー一覧サイトに載る可能性がある。

A の代償は「参加者が cloudflared を入れる」ことだけで、
これは**身内数人であれば説明すれば済む**。まずは A で始め、
参加者が増えて摩擦が問題になったら B を再検討する、という順序が可逆で安全。

逆順（まず B、駄目なら A）は不可逆に近い（一度露出した IP は戻せない）。

→ **A**。ただし「摩擦が許容できなければ B に切り替える」ことを明記しておく。

**容量**については、`replicas: 0` 既定と無人自動停止によって
「常時 2GB」を「遊ぶ間だけ 2GB」に変換したことで折り合いをつけた。
それでも稼働中は worker-2 が苦しくなるのは事実で、
**Minecraft を起動している間は他の重い作業を避ける**という運用上の制約が残る。

## Consequences

**楽になること**

- Discord から `/game start minecraft` でサーバーが立つ。SSH 不要。
- 遊んでいないときはメモリも CPU も使わない。
- ワールドが毎日バックアップされる。`/game backup` で手動実行もできる。
- ゲームを増やすのが設定変更だけで済む（コード変更なし）。
- ルーターのポートは 1 つも開いていない状態を維持できる。

**難しくなること / 新たな負担**

- **参加者に `cloudflared` の導入を頼む必要がある。**
  これが本方式の最大のコストで、人によっては断られる。
  手順は runbook（`docs/runbooks/game-server-ops.md`）に用意する。
- 起動に数分かかる（JVM + ワールド読み込み）。`/game start` してすぐは繋がらない。
- 稼働中は worker-2 のメモリが逼迫する。
  **worker-2 の実 RAM がこのリポジトリに記録されていない**ので、
  有効化の前に実測して ADR-0003 に追記すること。
- bot に Kubernetes API の権限を与えた。scale に絞ってはいるが、
  bot のトークンが漏れればゲームサーバーを止められる（クラスタ全体ではない）。
- Argo の `ignoreDifferences` により、replicas は Git の真実から外れた。
  「Git がクラスタの唯一の真実」という原則の例外を 1 つ作ったことになる。
  この例外は design.md §16 に明記した。
- バックアップは当面ノード内 PVC のみ。worker-2 が全損するとワールドも失われる。

**あとで見直す**

- 参加者が増えて cloudflared の摩擦が問題になったら B（ポート転送）へ。
  その際は DDoS 対策と fail2ban 相当を併せて検討する。
- バックアップの R2 転送（nekoneko の PG バックアップと同じ R2 待ち）。
- 2 つ目のゲーム（Valheim / Terraria 等）を足すときに、
  registry だけで足りるか（プロバイダ抽象が妥当だったか）を検証する。
- worker-2 のメモリが厳しければ、Minecraft 起動中だけ VoiceVox を
  `replicas: 0` にするなどの相互排他を検討する。

## Action Items

1. [x] プロバイダ抽象 + registry + Kubernetes 実装 + RCON クライアント
2. [x] `/game list|status|start|stop|restart|logs|backup` と認可・確認 UI
3. [x] 無人自動停止（人数不明のときは止めない）
4. [x] 最小権限の Role/RoleBinding（scale サブリソースのみ）
5. [x] `apps/gameservers/` に Minecraft StatefulSet（replicas: 0）+ バックアップ CronJob
6. [x] `app-gameservers` の `ignoreDifferences` で replicas を除外
7. [ ] **worker-2 の実 RAM を確認し、ADR-0003 に追記する**（有効化の前提）
8. [ ] `make seal-minecraft-rcon` で RCON パスワードを封入
9. [ ] Cloudflare Zero Trust で TCP アプリを作成し、Tunnel にルートを追加
10. [ ] 参加者向けの `cloudflared access tcp` 手順を配布（runbook）
11. [ ] 実際に起動 → 接続 → 無人 30 分で自動停止、までを一度通す
12. [ ] バックアップからワールドを復元する手順を一度試す（試していない手順は手順ではない）
