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

第1回で 3 ノードの素のクラスタができました。この回では、以降のプラットフォーム / アプリを**すべて GitOps で管理**し、実アプリ（架空のペット保険デモ「ねこねこ保険」）を `nekonekoinsurance.com` で公開します。

### リポジトリを 3 つに分けた

| リポジトリ | 役割 | 可視性 |
|---|---|---|
| `homelab-k8s` | インフラ: KVM / kubeadm / Ansible | public |
| `homelab-gitops` | Argo CD が同期する desired state | private |
| `cat_insureance_demo_app` / `nekoneko-hoken-api` | アプリのコード + Helm チャート + CI | private |

「インフラの作り方」と「クラスタに今何が載っているか」を分離したかったのが理由です。

---

## Phase 3: Argo CD で GitOps

### app-of-apps

`ansible/playbooks/50-argocd.yml` で Argo CD をブートストラップし、**root Application** が `homelab-gitops` の `bootstrap/children/` を読みます。

```
root Application  (source: homelab-gitops / bootstrap/children, directory: recurse)
  └─ bootstrap/children/*.yaml を全部 Application として apply
        platform-sealed-secrets    (wave -1)
        platform-local-path        (wave -1)   default StorageClass
        platform-cnpg-operator     (wave  0)
        platform-kong              (wave  0)
        platform-cloudflared       (wave  0)
        platform-newrelic-license  (wave  0)
        platform-keycloak-infra    (wave  1)   CNPG Cluster + realm
        platform-keycloak          (wave  2)
        app-nekoneko-shared        (wave  2)   ghcr pull secret
        app-nekoneko-frontend      (wave  3)
        app-nekoneko-api           (wave  3)
```

依存順は `argocd.argoproj.io/sync-wave` annotation で制御します。Argo は wave N が Healthy になってから wave N+1 を同期します。

**「`bootstrap/children/*.yaml` = Application の一覧」「`platform/` `apps/` = その中身」**という分け方にして、新しいものを足すときは両方に置く運用にしています。

### Secret は SealedSecret

平文 Secret はコミットしません。`kubeseal` で暗号化して git に入れ、クラスタ内のコントローラが復号します。

```bash
make seal-newrelic   LICENSE='...'   # New Relic license（cluster-wide scope）
make seal-cloudflared TOKEN='...'    # Cloudflare Tunnel token
make seal-ghcr       PAT='...'       # private ghcr の imagePullSecret
```

**sealing key のバックアップだけは必須**です（失うと git 内の全 SealedSecret が復号不能 → 再構築が破綻）。

### ハマり①: chart repo が消えている

`sealed-secrets` を chart repo（`bitnami-labs.github.io/sealed-secrets`）から入れようとしたら 404。GitHub Pages のチャート配信が廃止されていました。

→ Argo CD は **git リポジトリを直接 Helm チャートソースにできる**ので、タグ固定で参照します。

```yaml
source:
  repoURL: https://github.com/bitnami-labs/sealed-secrets
  targetRevision: helm-v2.19.3
  path: helm/sealed-secrets
```

`local-path-provisioner` も同じ方式です。

### ハマり②: StorageClass が無くて全 stateful が Pending

kubeadm 素のクラスタには動的プロビジョナが無いので、CNPG も Keycloak も PVC で止まります。`local-path-provisioner`（Rancher）を wave -1 で入れて default StorageClass に。

### ハマり③: inline helm values が子 App に伝播しない

`bootstrap/children/*.yaml` の中に `helm.values` をインラインで書いている場合、そのファイルを変えたら **root を先に sync**（hard refresh）しないと子 Application に伝わりません。

```
root を hard refresh + sync
  → root が子 Application リソース自体を書き換える
  → 子が新しい values で再同期
```

`kubectl patch app <child> sync` だけだと古い values のままになります。

### ハマり④: private リポの認証

`homelab-gitops` もアプリも private。Argo CD には **repo-creds テンプレート**を 1 つ登録すると `https://github.com/<org>/` 配下すべてに効きます。

```yaml
kind: Secret
metadata:
  labels: { argocd.argoproj.io/secret-type: repo-creds }
stringData:
  url: https://github.com/tukapai/
  username: tukapai
  password: <PAT: Contents Read-only>
```

### ハマり⑤: `.disabled` で「まだ有効化しない」

Argo の `directory: recurse` は `.yaml` / `.yml` / `.json` しか拾いません。これを利用して、前提が未達のものは `xxx.yaml.disabled` にしておき、**有効化 = リネームして commit/push** という運用にしています。

---

## Phase 4: Kong + Keycloak + Cloudflare Tunnel で公開

### Ingress は Kong Ingress Controller

当初 ingress-nginx を想定していましたが、アプリ設計側が Kong 前提だったので **Kong Ingress Controller（DB-less モード）**に置換。proxy Service は `ClusterIP` にして、外からは Cloudflare Tunnel 経由でのみ到達します。

### Cloudflare Tunnel（token モード）

`cloudflared` を 2 レプリカでクラスタ内に置き、Cloudflare へ**アウトバウンド接続**します。自宅ルーターのポート開放は一切不要。公開ホスト名 → 内部サービスの対応は Cloudflare ダッシュボード（Zero Trust → Tunnels → Public Hostnames）で設定します。

| Hostname | Service |
|---|---|
| `www` / `api` / `auth`.nekonekoinsurance.com | `http://kong-kong-proxy.kong.svc.cluster.local:80` |

TLS はエッジ終端。クラスタ内は HTTP なので cert-manager も MetalLB も不要です。

### Keycloak（keycloakx チャート）

Keycloak 26。realm 定義（ロール、SPA / API クライアント）を ConfigMap にして `--import-realm` で流し込みます。

#### ハマり⑥: `kc.sh` が help を出して終了する

keycloakx チャートは `command` 未指定だとイメージの既定 CMD で起動しますが、そこに `start` サブコマンドが無く help が出て終わります。明示指定で解決。

```yaml
command:
  - /opt/keycloak/bin/kc.sh
  - start
  - --http-enabled=true
  - --hostname-strict=false
  - --proxy-headers=forwarded
  - --cache=local        # ← 次項
  - --import-realm
```

#### ハマり⑦: CrashLoop（JGroups DNS_PING）

`start` の既定はクラスタキャッシュ（Infinispan + JGroups DNS_PING）で、単一レプリカだと `dns_query can not be null or empty` で落ちます。`--cache=local` で解決。

#### ハマり⑧: `/auth` 配下で配信される

keycloakx チャートの既定 `http.relativePath` が `/auth`。`"/"` に上書き。

### ハマり⑨: RFC1123 違反

Ingress のホスト名にプレースホルダとして `CHANGEME.example` と大文字を使っていて、apply が RFC1123 違反で失敗。小文字の実ドメインに。

---

## Phase 5: 実アプリ「ねこねこ保険」を載せる

架空の猫用ペット保険のデモアプリです。

- **フロント**: 静的 HTML/CSS/JS（`nginxinc/nginx-unprivileged`）
- **バックエンド**: Spring Boot 3.4 / Java 21 / Gradle、Flyway（13 テーブル）、Spring Security Resource Server（Keycloak の JWT 検証）

チャートはアプリリポジトリに置き、homelab 固有の値（ホスト名 / nodeSelector / image タグ / imagePullSecrets）は gitops 側の `values-prod.yaml` で上書きする**マルチソース Application**にしています。

```yaml
spec:
  sources:
    - repoURL: https://github.com/tukapai/cat_insureance_demo_app.git
      path: chart
      helm:
        valueFiles: [$values/apps/nekoneko-frontend/values-prod.yaml]
    - repoURL: https://github.com/tukapai/homelab-gitops.git
      ref: values
```

### ハマり⑩: fine-grained PAT でリポジトリが作れない / workflow が push できない

```
refusing to allow a Personal Access Token to create or update workflow ... without workflow scope
```

fine-grained PAT の制限です。リモートを SSH に切り替えて解決。

### ハマり⑪: Gradle wrapper をコミットできない

`gradlew` の jar はバイナリで、生成してコミットするのが面倒。
→ Dockerfile も CI も `gradle:8.12` イメージ / `gradle` コマンドを直接使う構成にして wrapper 依存をなくしました。

### ハマり⑫: nginx-unprivileged で `RUN rm` が Permission denied

Dockerfile で `RUN rm /usr/share/nginx/html/Dockerfile` していたら non-root ユーザーで消せずビルド失敗。`.dockerignore` で除外する方式に。

### ハマり⑬: private ghcr からの pull

パッケージを private のまま使いたかったので、`nekoneko` namespace に `ghcr-pull`（`dockerconfigjson`）の SealedSecret を配布し、各アプリの values で `imagePullSecrets` を指定。チャート側は `{{- with .Values.imagePullSecrets }}` で Pod spec に注入します。

### 結果

```bash
$ curl -s https://api.nekonekoinsurance.com/api/v1/plans | jq '.[].code'
"lite"
"standard"
"premium"

# 8歳・純血種の standard 保険料 = 2200 × 1.45(年齢) × 1.10(血統) = ¥3509
$ curl -s -XPOST https://api.nekonekoinsurance.com/api/v1/simulate \
    -H 'content-type: application/json' \
    -d '{"planCode":"standard","petAge":8,"petBreedType":"pure"}'
{"monthlyPremium":3509, ...}
```

経路は `Internet → Cloudflare → Tunnel → cloudflared → Kong → {frontend, api, keycloak}`。すべて Argo CD 管理で、`git revert` すれば戻せます。

---

## 第2回まとめ

- クラスタ構築後は Argo CD がすべて（プラットフォーム / アプリ）を GitOps で管理
- Secret は SealedSecret（sealing key のバックアップは必須）
- chart repo が消えても git リポジトリを直接 Helm ソースにできる
- Kong + Keycloak + Cloudflare Tunnel でルーター開放なしの本番公開
- ハマったのは chart repo 404、StorageClass 不在、inline values 伝播、Keycloak の起動オプション、fine-grained PAT

次回は、この構成に **New Relic（常用）と Instana（評価）の 2 系統監視**を入れます。評価ツールを「あとで綺麗に消せる形」で導入する工夫も書きます。

→ 第3回: New Relic + Instana で監視
