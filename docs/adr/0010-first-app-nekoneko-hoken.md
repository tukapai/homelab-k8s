# ADR-0010: 最初のアプリ「ねこねこ保険」— Kong / Keycloak をプラットフォームに追加

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

最初に載せる実アプリが決まった: **ねこねこ保険**（架空の猫専門ペット保険デモ、
`github.com/tukapai/cat_insureance_demo_app`）。

- **フロントエンド**: 静的 HTML/CSS/JS。今すぐ動く（localStorage 擬似認証）。
- **バックエンド**: `docs/backend-design.md` に設計あり・実装なし。
  Spring Boot 3 / Java 21 / **Kong Gateway (OSS)** / **Keycloak** /
  PostgreSQL 16 / Redis / S3 互換ストレージ。13 テーブル、REST API 約 19 本、
  Spring Batch（月次請求）。

homelab の既存プラットフォーム（ADR-0002/0005）は ingress-nginx + Cloudflare
Tunnel、認証なし。アプリの設計書は Kong と Keycloak を前提にしている。

ユーザー決定:
- **Kong Ingress Controller を導入**（設計書に合わせる / 学習・評価も兼ねる）
- **バックエンドも今回実装**する
- **Keycloak を今入れて**開発に備える

## Decision

### 1. Kong が唯一の Ingress コントローラ（ingress-nginx を置き換え）

`platform/kong`（Kong Ingress Controller 3.x、DB-less モード）を導入し、
**`platform/ingress-nginx` は無効化**する。2 つの Ingress を並立させない
（ADR-0005 の「lean」を維持）。

- Cloudflare Tunnel（cloudflared）→ **Kong の proxy Service**（ClusterIP）
- `Ingress` リソース + `KongPlugin` CRD で rate-limit / CORS / request-size /
  ログを宣言的に管理（GitOps）
- ADR-0002 / ADR-0005 をこの ADR で更新（下記「Consequences」）

### 2. Keycloak を今導入（`platform/keycloak`）

- Helm: `codecentric/keycloakx`（community、GitOps 実績あり）
- DB: **CloudNativePG の専用 Cluster**（`keycloak-pg`、keycloak namespace）
- Realm `nekoneko` を realm JSON でインポート（`--import-realm`）
  - クライアント: `nekoneko-spa`（public / Authorization Code + PKCE）、
    `nekoneko-api`（bearer-only / audience 用）
  - ロール: `MEMBER` / `ASSESSOR` / `ADMIN`
- 公開: `auth.<domain>` を Kong 経由（または Tunnel 直マッピング）

### 3. バックエンドは新リポジトリ `nekoneko-hoken-api`（ADR-0007）

- Spring Boot 3.x / Java 21 / Gradle (Kotlin DSL)
- Flyway（`V1__init.sql` に 13 テーブル）、Spring Data JPA、MapStruct、
  Bean Validation、springdoc-openapi
- Spring Security **Resource Server**（Keycloak の JWKS で JWT 検証。
  認可の最終判断はアプリ側。Kong の `jwt` プラグインは多層防御の一次検証）
- Spring Batch（月次請求・契約更新）
- Dockerfile（distroless or eclipse-temurin jammy）、Helm チャート、CI
- **段階実装**: まず認証まわり + 参照系（`/me`, `/plans`, `/simulate`,
  `/me/pets`, `/me/contracts`, `/me/claims`）→ 更新系 → admin → batch

### 4. オブジェクトストレージは R2（S3 互換）

領収書画像・保険証券 PDF。ADR-0004 の barman バックアップと同じ R2 アカウント、
別バケット（`nekoneko-attachments`）。SDK は AWS SDK for Java v2（S3 互換）。

### 5. 監視はプラットフォーム標準に寄せる（ADR-0008）

設計書は Prometheus/Grafana + Sentry だが、homelab は New Relic + OTel。
Spring Boot Actuator + Micrometer の **OTLP エクスポート**で
`otel-collector` に送る → New Relic。Sentry は使わず New Relic の
エラートラッキングで代替。

### 6. フロントエンドはまず静的のまま公開

`platform/kong` 経由で `www.<domain>`。nginx イメージに静的ファイルを載せる。
将来のマイページ SPA 化 + `keycloak-js` 連携は設計書 §11 の通り別フェーズ。

## Options Considered

### Ingress: Kong vs ingress-nginx 継続 vs 併用

| 案 | 評価 |
|---|---|
| **Kong が唯一の Ingress（採用）** | 設計書と一致。プラグイン CRD で API ゲートウェイ的関心事を宣言的に。Ingress は 1 つ |
| ingress-nginx 継続、Kong 不使用 | 最軽量。rate-limit/CORS は annotation、JWT は Spring のみ。だが設計書と乖離、ユーザーは Kong 希望 |
| ingress-nginx（一般）+ Kong（API のみ）| 二重管理。cloudflared のルーティングも複雑化 |

### 認証: Keycloak vs Cloudflare Access vs 自前

| 案 | 評価 |
|---|---|
| **Keycloak（採用）** | 設計書通り。OIDC 標準、ロール管理、管理画面。ただし ~1Gi + 専用 DB |
| Cloudflare Access | エッジで完結、軽い。だが会員セルフサインアップ・ロール・SPA トークンには不向き |
| 自前 JWT | 設計書が明確に非推奨（廃止方針） |

### バックエンドの置き場所

| 案 | 評価 |
|---|---|
| **新リポジトリ `nekoneko-hoken-api`（採用）** | ADR-0007 通り。フロント（`cat_insureance_demo_app`）と分離 |
| フロントと同一リポジトリ | ADR-0007 に反する。CI・デプロイ単位が混ざる |

## Consequences

**ADR の更新**
- **ADR-0002**: cloudflared の接続先を `ingress-nginx` → **Kong proxy Service** に。
- **ADR-0005**: 「ingress-nginx（ClusterIP）」→ **「Kong Ingress Controller が唯一の
  Ingress」**。MetalLB / cert-manager 不要は変わらず。

**楽になること**
- API ゲートウェイの横断的関心事（rate-limit / CORS / サイズ制限 / ログ）が
  `KongPlugin` CRD で一元管理・GitOps 化。
- 認証が Keycloak に集約。会員・査定・管理のロールが 1 か所。
- 監視・DB・ストレージは既存プラットフォームを再利用（New Relic / CNPG / R2）。

**難しくなること / 新たな負担**
- Kong + Keycloak + Keycloak 用 PG で **~1.5–2GB 追加**（worker-2 の余裕に載せる）。
- Kong の設定パラダイム（Ingress + Kong CRD）と DB-less の運用を覚える。
- Keycloak realm を IaC 管理（realm JSON / または terraform-provider-keycloak）。
- Spring Boot バックエンドの実装量が大きい（13 テーブル / 19 エンドポイント）。
  段階実装で進める。
- 設計書の一部（Prometheus/Grafana、Sentry、CloudFront）は homelab では
  別物に読み替える（本 ADR §5, §6 で明示）。

**あとで見直す**
- Kong OSS の OIDC ブローカー制約（Enterprise 限定）。当面「ログインは
  SPA⇔Keycloak 直、Kong は API ゲートウェイ専念」で回避（設計書 §2.1 通り）。
- Keycloak realm 管理を terraform-provider-keycloak に寄せるか。
- フロント SPA 化のタイミング。

## Action Items

**プラットフォーム（homelab-gitops）**
1. [ ] `platform/kong/`（KIC 3.x、DB-less、proxy=ClusterIP）Application
2. [ ] `platform/ingress-nginx` を `.disabled` 化、cloudflared の upstream を Kong に
3. [ ] `platform/keycloak/`（keycloakx + CNPG `keycloak-pg` + realm JSON ConfigMap）
4. [ ] `platform/otel-collector` を有効化（Actuator OTLP の受け先）

**アプリ**
5. [ ] `nekoneko-hoken-api` リポジトリ作成（Gradle / Spring Boot 3 / Java 21）
6. [ ] `V1__init.sql`（13 テーブル）+ Entity + Repository
7. [ ] SecurityConfig（Resource Server）+ `JwtRoleConverter`
8. [ ] 参照系エンドポイント（`/me`, `/plans`, `/simulate`, `/me/pets`,
       `/me/contracts`, `/me/claims`）
9. [ ] 更新系 → admin → Spring Batch（段階）
10. [ ] Dockerfile / Helm チャート / GitHub Actions
11. [ ] `cat_insureance_demo_app`: Dockerfile(nginx) / チャート / CI、`main` ブランチ作成
12. [ ] `homelab-gitops/apps/{nekoneko-frontend,nekoneko-api}/` overlay
13. [ ] R2 バケット `nekoneko-attachments` + SealedSecret
14. [ ] フロントの `NekoAuth` を API クライアントへ差し替え（設計書 §11、後フェーズ）
