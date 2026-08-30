# 自宅の物理2台でKubernetesをGitOpsまで【第2回】Argo CD + Kong + Keycloak + Cloudflare Tunnel で本番公開

<!--
Qiita 連載（全3回）第2回。
タグ候補: Kubernetes, ArgoCD, Kong, Keycloak, Cloudflare
連載インデックス: docs/qiita-article.md
-->

## この連載について

自宅の Ubuntu マシン 2 台で本番運用できる Kubernetes 基盤を組む記録の第2回です。

1. 第1回: KVM + kubeadm で 3 ノードクラスタ（物理 2 台にまたがる）
2. **【第2回・本記事】Argo CD で GitOps + Kong / Keycloak / Cloudflare Tunnel で公開**
3. 第3回: New Relic + Instana で監視

第1回で 3 ノードの素のクラスタができました。この回では、以降のプラットフォーム / アプリを**すべて GitOps で管理**し、実アプリ（架空のペット保険デモ「ねこねこ保険」）を `nekonekoinsurance.com` で公開します。用語は都度説明します。

### リポジトリを 3 つに分けた

| リポジトリ | 役割 | 可視性 |
|---|---|---|
| `homelab-k8s` | インフラ: KVM / kubeadm / Ansible | public |
| `homelab-gitops` | Argo CD が同期する desired state | private |
| `cat_insureance_demo_app` / `nekoneko-hoken-api` | アプリのコード + Helm チャート + CI | private |

「インフラの作り方（一度きり）」と「クラスタに今何が載っているか（頻繁に変わる）」は変更頻度もライフサイクルも違うので、リポジトリを分けました。

---

## 0. 前提知識の整理

### GitOps とは

**「クラスタのあるべき状態を Git に置き、Git と実クラスタの差分を自動で埋め続ける」**運用スタイルです。

- **宣言的**: 「こうなっていてほしい」を YAML で書く（手順ではなく状態）
- **Git が唯一の真実**: `kubectl apply` を人間が直接叩かない。変更は必ず Git 経由
- **自動同期（reconcile）**: エージェントが「Git の状態」と「クラスタの現状」を比べ、ズレたら Git 側に寄せる
- **監査可能 / ロールバック可能**: `git log` が変更履歴、`git revert` が切り戻し

これを実現するエージェントが **Argo CD** です。

### Argo CD の基本概念

| 用語 | 意味 |
|---|---|
| **Application** | 「この Git リポジトリのこのパスを、このクラスタのこの namespace に同期する」という 1 単位。CRD（後述）として登録される |
| **Sync（同期）** | Git の内容をクラスタに `apply` する操作 |
| **Sync status** | `Synced`（Git と一致）/ `OutOfSync`（差分あり）|
| **Health status** | 同期されたリソースが実際に動いているか（`Healthy` / `Progressing` / `Degraded`）|
| **Sync policy** | `manual`（人が sync ボタンを押す）/ `automated`（自動）。`automated` には `prune`（Git から消えたものはクラスタからも消す）と `selfHeal`（手で変えられても Git に戻す）がある |

### CRD と Operator

- **CRD（Custom Resource Definition）**: Kubernetes に**新しい種類のリソース**を教える仕組み。標準の `Pod` / `Service` に加えて、例えば `Cluster`（PostgreSQL クラスタ）という独自リソースを `kubectl get cluster` で扱えるようにする
- **Operator（オペレータ）**: その CRD を監視し、「`Cluster` が 1 個できたら、StatefulSet と Service と Secret を作って、フェイルオーバーも面倒みる」といった運用ロジックを実装したコントローラ

この記事では **CloudNativePG**（PostgreSQL オペレータ）を使います。`Cluster` を 1 つ書くだけで PG 一式が立ちます。

### Helm と Kustomize

どちらも「YAML を生成する」ツールですが方向性が違います。

- **Helm**: テンプレート + 値（`values.yaml`）。「chart」というパッケージ単位で配布される。`{{ .Values.image.tag }}` のような変数展開。ベンダーが配布する複雑なミドルウェアを入れるのに向く
- **Kustomize**: テンプレートなし。「ベースの YAML に対してパッチを当てる / 名前を書き換える」。自前の manifest を環境別に少し変えるのに向く

Argo CD は両方を Application のソースにできます。

---

## Phase 3: Argo CD で GitOps

### app-of-apps パターン

Argo CD で 15 個のコンポーネントを管理するとき、Application を 15 個手で作るのは大変です。そこで **app-of-apps**（アプリのアプリ）パターンを使います。

```
50-argocd.yml が作る「root」Application
  │  source: homelab-gitops / bootstrap/children （directory: recurse）
  │  ＝「このディレクトリの YAML を全部 Application として apply する」
  ▼
  bootstrap/children/platform-sealed-secrets.yaml   → Application
  bootstrap/children/platform-kong.yaml             → Application
  bootstrap/children/app-nekoneko-frontend.yaml     → Application
  ...
```

root Application を 1 つブートストラップすれば、あとは `bootstrap/children/` にファイルを足して push するだけで新コンポーネントが増えます。

**設計ルール**: `bootstrap/children/*.yaml` は「Application の一覧」、`platform/` `apps/` は「その Application が指す中身（Kustomize ディレクトリ / values）」。新規追加時は両方に置きます。

### sync-wave（依存順）

コンポーネントには順序があります。例えば「SealedSecrets のコントローラ」が動く前に「暗号化された Secret」を apply しても復号できません。

Argo CD は各 Application の annotation `argocd.argoproj.io/sync-wave: "N"` を見て、**wave N が Healthy になってから wave N+1 を同期**します。

| wave | Application | なぜこの順序 |
|---|---|---|
| **-1** | sealed-secrets、local-path-provisioner | Secret 復号 / StorageClass は全ての土台 |
| **0** | cnpg-operator、kong、newrelic-license、cloudflared、otel-collector | CRD 提供 / Ingress / 独立コンポーネント |
| **1** | keycloak-infra、newrelic | cnpg-operator の CRD に依存 / license Secret に依存 |
| **2** | keycloak、nekoneko-shared | keycloak-pg（CNPG Cluster）に依存 / ghcr pull secret |
| **3** | nekoneko-frontend、nekoneko-api | 上記すべてに依存 |

### Secret は SealedSecret

**問題**: Kubernetes の `Secret` は base64 されているだけで暗号化ではない。Git にそのまま置けない。

**SealedSecrets の仕組み**:

1. クラスタ内に **controller** が動いていて、非対称鍵ペア（公開鍵 / 秘密鍵）を持つ
2. 手元で `kubeseal` を使い、controller の**公開鍵**で `Secret` を暗号化 → `SealedSecret` という CRD になる
3. `SealedSecret` は暗号文なので Git に置ける
4. クラスタに apply されると、controller が**秘密鍵**で復号し、通常の `Secret` を生成する

つまり「**公開鍵で封をして、クラスタの中でだけ開けられる**」。秘密鍵はクラスタから出ません。

```bash
make seal-newrelic   LICENSE='...'   # New Relic license
make seal-cloudflared TOKEN='...'    # Cloudflare Tunnel token
make seal-ghcr       PAT='...'       # private ghcr の imagePullSecret
```

**`--scope cluster-wide`** を付けると、その SealedSecret を任意の namespace で復号できます（既定は「同じ namespace かつ同じ名前」でしか復号できない縛りがある）。New Relic の license は `newrelic` と `observability` の 2 つの namespace で使うので cluster-wide にしています。

> **最重要: sealing key（controller の秘密鍵）のバックアップ**
> これを失うと、Git 内の全 SealedSecret が**永久に復号不能**になります。この homelab の DR 戦略は「壊れたら再構築」なので、秘密鍵を暗号化して 2 か所に退避しておくのが生命線です。

### ハマり①: chart repo が消えている

`sealed-secrets` を Helm chart repo（`bitnami-labs.github.io/sealed-secrets`）から入れようとしたら 404。GitHub Pages でのチャート配信が廃止されていました。

**Argo CD は Git リポジトリを直接 Helm チャートのソースにできる**ので、リポジトリ内のチャートディレクトリをタグ固定で参照します。

```yaml
source:
  repoURL: https://github.com/bitnami-labs/sealed-secrets
  targetRevision: helm-v2.19.3      # git のタグ
  path: helm/sealed-secrets         # チャートのあるディレクトリ
  helm:
    releaseName: sealed-secrets
```

`local-path-provisioner` も同じ方式。「chart repo の URL が変わる / 消える」は普通に起きるので、この参照方法は覚えておくと便利です。

### ハマり②: StorageClass が無くて全 stateful が Pending

**PVC（PersistentVolumeClaim）** は「これだけの容量のディスクをくれ」という要求。それに応える実体（**PV**）を**動的に**作るのが **プロビジョナ**で、`StorageClass` がその設定です。

kubeadm 素のクラスタにはプロビジョナが無いので、PVC を出す Pod（CNPG、Keycloak）は永遠に `Pending` になります（`kubectl get pvc` すると `Pending`）。

**local-path-provisioner**（Rancher 製）を wave -1 で入れ、**default StorageClass** に設定しました。これは「Pod がスケジュールされたノードのローカルディスクに `hostPath` の PV を切る」シンプルなもの。単一ノード / homelab 向けです（可用性はないが、DB のバックアップは別途取る方針）。

`volumeBindingMode: WaitForFirstConsumer` にしておくと、「Pod がどのノードに置かれるか決まってから PV を作る」ので、`nodeSelector` との齟齬が起きません。

### ハマり③: inline helm values が子 App に伝播しない

一部の Application は `bootstrap/children/xxx.yaml` の中に `helm.values` を**インラインで**書いています。

```yaml
# bootstrap/children/platform-newrelic.yaml
spec:
  source:
    helm:
      values: |
        global:
          cluster: nekonekoinsurance
```

この `values` を変更したとき、`platform-newrelic` Application を直接 sync しても**古い値のまま**でした。

理由: `platform-newrelic` という Application リソース自体を書き換えるのは **root** Application の仕事です。root が sync されて初めて、`platform-newrelic` の `.spec.source.helm.values` が新しくなり、そのあと `platform-newrelic` が新しい値で再同期します。

```
1. bootstrap/children/platform-newrelic.yaml を編集して push
2. root を hard refresh + sync   ← これを忘れる
3. すると platform-newrelic Application の中身が更新される
4. platform-newrelic が新しい values で再同期
```

`kubectl -n argocd patch app platform-newrelic ... sync` だけだと 1→3 が飛ばされます。**「values を変えたら root を先に」**が鉄則。

### ハマり④: private リポの認証

`homelab-gitops` もアプリも private。Argo CD がクローンするには認証情報が要ります。個別リポごとに Secret を作ってもいいですが、**repo-creds テンプレート**を 1 つ登録すると、URL プレフィックスが一致するリポジトリすべてに効きます。

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-creds-tukapai
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds   # ← これがテンプレート印
stringData:
  type: git
  url: https://github.com/tukapai/               # このプレフィックス配下すべてに適用
  username: tukapai
  password: <GitHub PAT: Contents Read-only>
```

### ハマり⑤: `.disabled` で「まだ有効化しない」

Argo の `directory: recurse` は `.yaml` / `.yml` / `.json` しか拾いません。前提が未達のコンポーネント（例: license を seal する前の New Relic）は `xxx.yaml.disabled` という拡張子にしておき、**有効化 = `git mv xxx.yaml.disabled xxx.yaml` して push** という運用にしています。ブランチを分けるより単純で、差分も見やすい。

---

## Phase 4: Kong + Keycloak + Cloudflare Tunnel で公開

### Ingress と Ingress Controller

- **Ingress**: 「`api.example.com` は Service A へ、`www.example.com` は Service B へ」という**ルーティングルール**を書く Kubernetes リソース。ルール定義でしかない
- **Ingress Controller**: そのルールを読んで実際にリバースプロキシとして動く実体。nginx、Kong、Traefik など

当初 ingress-nginx を想定していましたが、アプリ設計側が Kong 前提だったので **Kong Ingress Controller** に置換しました。

**DB-less モード**: Kong は本来 PostgreSQL に設定を持ちますが、Kubernetes では「Ingress リソースを読んで設定を組み立てる」だけなので DB 不要にできます。運用が単純になります。

Kong の proxy Service は **ClusterIP**（クラスタ内からしか見えない）にしています。外部公開は次の Cloudflare Tunnel が担うので、`LoadBalancer` や `NodePort` は不要です。

### Cloudflare Tunnel（token モード）

**普通の公開**: 外 → 自宅ルーターのポート開放 → 中のサーバ。IP がバレる、ポートスキャンされる、CGNAT だと不可能。

**Cloudflare Tunnel**: クラスタ内の `cloudflared` が Cloudflare へ**アウトバウンド接続**を張り、その中を通してリクエストが届く。

```
ブラウザ → Cloudflare エッジ（TLS 終端 / WAF）
           │  ↑ ここで張られっぱなしのトンネル（cloudflared が外向きに接続）
           ▼
       cloudflared Pod（2 レプリカ）
           │  http://kong-kong-proxy.kong.svc.cluster.local:80
           ▼
         Kong → 各サービス
```

- **ルーター開放不要**（アウトバウンドのみ）
- **自宅 IP が隠れる**（公開されるのは Cloudflare の IP）
- **TLS はエッジで終端**。クラスタ内は HTTP でよい → **cert-manager 不要**

「token モード」は、Cloudflare ダッシュボードで発行したトークンを `cloudflared` に渡すだけの構成。公開ホスト名 → 内部サービスの対応もダッシュボード（Zero Trust → Tunnels → Public Hostnames）で設定します。

| Hostname | Service |
|---|---|
| `www` / `api` / `auth`.nekonekoinsurance.com | `http://kong-kong-proxy.kong.svc.cluster.local:80` |

Cloudflare からは全部 Kong に流し、Kong の Ingress ルール（`ingressClassName: kong`）でホスト名ごとに振り分けます。

### Keycloak と OIDC

**Keycloak** はオープンソースの ID プロバイダ（IdP）。「ログイン」「ユーザー管理」「トークン発行」を肩代わりしてくれます。

> **OIDC（OpenID Connect）まわりの用語**
> - **realm（レルム）**: Keycloak 内の独立した領域。ユーザー・ロール・クライアントの集合。アプリ 1 セットにつき 1 realm
> - **client（クライアント）**: realm に登録するアプリ。`public`（SPA など秘密を持てない）と `confidential`（サーバサイド）がある
> - **JWT（JSON Web Token）**: 署名付きの JSON。中に「誰が」「どのロールを持つか」「いつまで有効か」が入っている。改ざんすると署名が合わなくなる
> - **access token**: API を叩くときに `Authorization: Bearer <JWT>` で送るトークン
> - **PKCE**: public クライアントが安全に認可コードを交換するための拡張
> - **Resource Server**: トークンを**検証する側**（＝ API サーバ）。Keycloak の公開鍵で JWT の署名を検証し、中のロールで認可する

この homelab では realm `nekoneko` を定義し、SPA 用の public クライアントと API 用のクライアントを登録。realm 定義（ロール、クライアント）は JSON にして ConfigMap に入れ、Keycloak の `--import-realm` で起動時に流し込みます。

`codecentric/keycloakx` という Helm チャートを使いました。

#### ハマり⑥: `kc.sh` が help を出して終了する

keycloakx チャートは `command` 未指定だとコンテナイメージの既定 CMD で起動しますが、そこに `start` サブコマンドが含まれず、`kc.sh` がヘルプを出して終了 → Pod が `CrashLoopBackOff`。

明示指定で解決:

```yaml
command:
  - /opt/keycloak/bin/kc.sh
  - start
  - --http-enabled=true
  - --hostname-strict=false      # リバースプロキシ配下なのでホスト厳格チェックを緩める
  - --proxy-headers=forwarded    # X-Forwarded-* を信頼する
  - --cache=local                # ← 次項
  - --import-realm
```

#### ハマり⑦: CrashLoop（JGroups DNS_PING）

Keycloak の `start` は既定で**クラスタモード**（複数レプリカでセッションを共有する）で起動します。その内部で **Infinispan**（分散キャッシュ）が **JGroups** というライブラリで他のレプリカを探します。探索方式が **DNS_PING**（Headless Service の DNS を引いて仲間を見つける）なのですが、設定が無いと:

```
java.lang.IllegalStateException: dns_query can not be null or empty
```

で落ちます。単一レプリカなので **`--cache=local`**（クラスタリングしない、ローカルキャッシュだけ）にして解決。

#### ハマり⑧: `/auth` 配下で配信される

keycloakx チャートの既定 `http.relativePath` が `/auth`（旧 Keycloak の慣習）。`auth.nekonekoinsurance.com/` 直下で配信したいので:

```yaml
http:
  relativePath: "/"
```

### ハマり⑨: RFC1123 違反

Ingress のホスト名にプレースホルダとして `CHANGEME.example` と大文字を入れていて apply が失敗:

```
Invalid value: "CHANGEME.example": a lowercase RFC 1123 subdomain must consist of lower case alphanumeric characters, '-' or '.'
```

Kubernetes のホスト名・リソース名の多くは **RFC 1123**（小文字英数字とハイフンのみ）準拠が必須。小文字の実ドメインに置換。

---

## Phase 5: 実アプリ「ねこねこ保険」を載せる

架空の猫用ペット保険のデモアプリです。

- **フロント**: 静的 HTML/CSS/JS（`nginxinc/nginx-unprivileged` イメージ）
- **バックエンド**: Spring Boot 3.4 / Java 21 / Gradle、Flyway、Spring Security Resource Server

> **Flyway**: DB スキーマのマイグレーションツール。`V1__create_tables.sql`, `V2__...` と番号付き SQL を置くと、起動時に「まだ当てていないものを順に実行」してくれる。スキーマのバージョン管理。

### マルチソース Application

アプリの Helm チャートは**アプリのリポジトリ**に置き、homelab 固有の値（ホスト名 / nodeSelector / image タグ / imagePullSecrets）は **gitops リポジトリ**の `values-prod.yaml` に置きます。理由: チャートは環境非依存で再利用したい、環境差分だけ gitops で管理したい。

Argo CD の **マルチソース Application** で「チャートは A リポジトリ、values は B リポジトリ」を実現します。

```yaml
spec:
  sources:
    - repoURL: https://github.com/tukapai/cat_insureance_demo_app.git
      targetRevision: main
      path: chart
      helm:
        valueFiles:
          - $values/apps/nekoneko-frontend/values-prod.yaml   # ← $values を参照
    - repoURL: https://github.com/tukapai/homelab-gitops.git
      targetRevision: main
      ref: values                                             # ← $values の実体
```

### ハマり⑩: fine-grained PAT でリポジトリが作れない / workflow が push できない

```
refusing to allow a Personal Access Token to create or update workflow ... without workflow scope
```

**PAT（Personal Access Token）** には旧来の「classic」と新しい「fine-grained」があり、fine-grained は権限が細かい代わりに**リポジトリ作成**や **`.github/workflows/` の push** に制約があります（HTTPS 経由の場合）。

→ リモートを **SSH**（`git@github.com:...`）に切り替えて解決。SSH 鍵なら scope の制約を受けません。

### ハマり⑪: Gradle wrapper をコミットできない

**Gradle wrapper**（`gradlew` + `gradle/wrapper/gradle-wrapper.jar`）は「その場に Gradle が無くてもビルドできる」仕組みですが、`.jar` はバイナリで、手元で生成してコミットするのが手間でした。

→ wrapper に依存しない構成に:
- **Dockerfile**: `FROM gradle:8.12-jdk21 AS build` でビルドステージに Gradle 入りイメージを使う
- **CI**: `gradle/actions/setup-gradle@v4` で Gradle を入れて `gradle` コマンドを直接実行

### ハマり⑫: nginx-unprivileged で `RUN rm` が Permission denied

```dockerfile
COPY . /usr/share/nginx/html/
RUN rm /usr/share/nginx/html/Dockerfile   # ← ここで失敗
```

```
rm: can't remove '/usr/share/nginx/html/Dockerfile': Permission denied
```

`nginxinc/nginx-unprivileged` は**非 root ユーザー**（nginx uid=101）で動くセキュアなイメージ。`RUN` もそのユーザーで実行されるので、root 所有のファイルを消せません。

→ そもそもコピーしないように **`.dockerignore`** で `Dockerfile` / `.git` / `chart` / `docs` を除外。

### ハマり⑬: private ghcr からの pull

コンテナイメージは **ghcr.io**（GitHub Container Registry）に private で置いています。private イメージを Pod が pull するには **imagePullSecret** が要ります。

> **imagePullSecret の仕組み**
> `kubernetes.io/dockerconfigjson` 型の Secret に、`~/.docker/config.json` 相当（レジストリの URL + Base64 の `user:token`）を入れる。Pod spec の `imagePullSecrets: [{name: ...}]` で参照すると、kubelet がその認証情報でレジストリにログインして pull する。

`nekoneko` namespace に `ghcr-pull` という SealedSecret を配布し（`apps/nekoneko-shared` という専用の小さな Application が担当）、各アプリの `values-prod.yaml` で:

```yaml
imagePullSecrets:
  - name: ghcr-pull
```

チャート側は `{{- with .Values.imagePullSecrets }}` で Pod spec に注入します。「パッケージを public にする」を避け、private を維持できました。

### 結果

```bash
$ curl -s https://api.nekonekoinsurance.com/api/v1/plans | jq '.[].code'
"lite"
"standard"
"premium"

# 8歳・純血種の standard 保険料 = 2200 × 1.45(年齢係数) × 1.10(血統係数) = ¥3509
$ curl -s -XPOST https://api.nekonekoinsurance.com/api/v1/simulate \
    -H 'content-type: application/json' \
    -d '{"planCode":"standard","petAge":8,"petBreedType":"pure"}'
{"monthlyPremium":3509, ...}
```

経路は `Internet → Cloudflare → Tunnel → cloudflared → Kong → {frontend, api, keycloak}`。すべて Argo CD 管理で、`git revert` すれば戻せます。

---

## 第2回まとめ

- クラスタ構築後は Argo CD がすべて（プラットフォーム / アプリ）を GitOps で管理
  - app-of-apps で「root 1 個をブートストラップ → あとはファイルを足すだけ」
  - sync-wave で依存順を制御
- Secret は SealedSecret（公開鍵で封をし、クラスタ内でだけ開ける。sealing key のバックアップは必須）
- chart repo が消えても Git リポジトリを直接 Helm ソースにできる
- Kong + Keycloak + Cloudflare Tunnel でルーター開放なしの本番公開（TLS はエッジ終端）
- ハマったのは chart repo 404、StorageClass 不在、inline values の伝播、Keycloak の起動オプション 3 連発、fine-grained PAT、非 root イメージ

次回は、この構成に **New Relic（常用）と Instana（評価）の 2 系統監視**を入れます。評価ツールを「あとで綺麗に消せる形」で導入する工夫も書きます。

→ 第3回: New Relic + Instana で監視
