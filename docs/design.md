# 設計ドキュメント — homelab Kubernetes 基盤

自宅の物理マシン上に Kubernetes クラスタを構築し、その上でインターネット公開
する Web アプリケーションと周辺ミドルウェアを **1 人で無理なく運用する**ための
設計。個々の意思決定の根拠は [ADR](adr/)、手順は [runbook](runbooks/) を参照。

- 対象読者: 将来の自分、この構成を参考にする人
- ステータス: **稼働中**（3 ノードクラスタ / GitOps 全同期 / 初アプリ公開 / 監視稼働）
- 最終更新: 2026-08-30

### 現在の稼働状態（2026-08-30）

| 項目 | 状態 |
|---|---|
| クラスタ | 3 ノード Ready（cp-1 + worker-1 + worker-2）。物理 2 台（ホスト A / B）にまたがる |
| ノード間ネットワーク | Flannel VXLAN がサブネット跨ぎで疎通（ADR-0009。worker-2 は macvtap）|
| Argo CD | ブートストラップ済み。root + 子 App 13 個。プラットフォームは全て Synced/Healthy |
| Ingress | **Kong**（ingress-nginx は無効化。ADR-0010）|
| 認証基盤 | Keycloak 26.0.7、realm `nekoneko` インポート済み（ルートパス配信）|
| 公開アプリ | `www` / `api` / `auth`.nekonekoinsurance.com が Cloudflare Tunnel 経由で HTTP 200 |
| アプリ | nekoneko-frontend（静的サイト）+ nekoneko-hoken-api（Spring Boot 3、Flyway 7 マイグレーション適用済み）|
| DB | CloudNativePG `Cluster`（keycloak-pg / nekoneko-api-pg）。local-path PV |
| 監視 | New Relic（常用）+ Instana（評価中）両方稼働。§11 |

未了は §13。

---

## 1. 目的とスコープ

### ゴール

- 自宅の Ubuntu マシンを Kubernetes クラスタにする（再現可能・IaC）
- インターネット公開の Web API + PostgreSQL + Redis（cache/queue）を載せる
- **デプロイと運用が 1 人で回るくらい軽い**こと
- 物理ホストが増えたときにスムーズに拡張できること
- 資産の一部を将来 AWS 等へ移せる余地を残すこと

### 非ゴール（当面やらない）

- マルチリージョン / 地理冗長
- 物理 1 台での「真の HA」（不可能。§8 の方針で代替）
- マルチテナント、チーム運用向けの権限分離
- 自前のコンテナレジストリ / Git サーバ / Vault
- サービスメッシュ、Kafka 級のイベント基盤

### 制約

| 制約 | 影響 |
|---|---|
| 運用者 1 人 | 運用コスト最小化を最優先。手作業に依存しない |
| 物理ホスト当面 1 台 | 真の HA 不可 → バックアップ + 高速再構築で守る（ADR-0003）|
| 自宅回線（CGNAT / IP 変動 / ポートブロックの可能性）| 公開は Cloudflare Tunnel（ADR-0002）|
| worker VM 2 vCPU / 4GB | プラットフォームを絞る（ADR-0005）+ 暫定で cp も使う（ADR-0003）|

---

## 2. システムコンテキスト

```
        ┌──────────────┐        ┌──────────────────┐
        │  エンドユーザ  │        │  開発者(=運用者)   │
        │  (ブラウザ)    │        │   Mac            │
        └──────┬───────┘        └───┬─────────┬────┘
               │ HTTPS               │ git push │ SSH / kubectl(トンネル)
               ▼                     ▼          ▼
        ┌──────────────┐      ┌──────────┐  ┌──────────────────────────┐
        │  Cloudflare   │      │  GitHub   │  │  自宅: KVM ホスト + k8s     │
        │ DNS/TLS/WAF   │      │ repos/CI/ │  │                          │
        │  + Tunnel     │◀─────│  ghcr.io  │─▶│  （§3）                   │
        └──────────────┘ tunnel└──────────┘  └──────────┬───────────────┘
                                                        │ 定期バックアップ
                                                        ▼
                                            ┌──────────────────────┐
                                            │ Cloudflare R2 / B2    │
                                            │ (S3 互換, オフホスト)  │
                                            └──────────────────────┘
```

外部依存:

| 依存先 | 用途 | 失われた場合 |
|---|---|---|
| Cloudflare | DNS / エッジ TLS / WAF / Tunnel | 公開停止（内部は生存）。ADR-0002 |
| GitHub | ソース・GitOps・CI・ghcr.io | デプロイ不可（稼働中は生存）|
| R2 / B2 | DB・Redis バックアップ | 新規バックアップ不可。既存リストアは可 |

---

## 3. アーキテクチャ（レイヤ構成）

```
┌─ L5 アプリケーション ────────────────────────────────────────────┐
│  nekoneko-frontend (nginx 静的)   nekoneko-hoken-api (Spring Boot)│
│  namespace: nekoneko                                            │
├─ L4 アプリ付随ミドルウェア ──────────────────────────────────────┤
│  PostgreSQL (CloudNativePG Cluster)   ※Redis は未導入（必要時）   │
│  keycloak-pg / nekoneko-api-pg ·  nodeSelector: worker-2        │
├─ L3 プラットフォーム（Argo CD が homelab-gitops から同期）────────┤
│  Argo CD   Kong Ingress Controller   cloudflared   Keycloak     │
│  sealed-secrets  CloudNativePG operator  local-path  metrics-srv │
│  New Relic nri-bundle  OTel Collector  （Instana は評価中・GitOps外）│
├─ L2 Kubernetes クラスタ（kubeadm, homelab-k8s/ansible）──────────┤
│  control-plane: k8s-cp-1(.122.11)                               │
│  worker: k8s-worker-1(.122.21, ホストA)  k8s-worker-2(.1.22, ホストB)│
│  containerd 2.x + SystemdCgroup / CNI Flannel / v1.31.14        │
├─ L1 仮想化基盤（homelab-k8s/scripts）───────────────────────────┤
│  KVM / libvirt  ·  cloud-init で Ubuntu 24.04 VM を払い出し      │
│  ホストA=libvirt NAT / ホストB=macvtap（ADR-0009）              │
├─ L0 物理 ─────────────────────────────────────────────────────┤
│  ホストA: Ubuntu 24.04 (192.168.1.35)  ホストB: (192.168.1.188) │
└───────────────────────────────────────────────────────────────┘
```

各レイヤの管理主体:

| レイヤ | 管理方法 | リポジトリ |
|---|---|---|
| L0–L2 | bash スクリプト + Ansible | `homelab-k8s` |
| L3 | Argo CD（app-of-apps）| `homelab-gitops` |
| L4 | Argo CD（アプリの Helm チャートに内包）| `app-<name>` + `homelab-gitops` |
| L5 | Argo CD（同上）| 同上 |

---

## 4. コンポーネント一覧

| コンポーネント | 役割 | 導入 | 根拠 |
|---|---|---|---|
| KVM / libvirt | 仮想化 | `scripts/01` | — |
| kubeadm | クラスタ | `ansible/site.yml` | — |
| containerd | CRI | `10-common.yml` | — |
| Flannel | CNI | `20-control-plane.yml` | — |
| metrics-server | `kubectl top` / GUI グラフ | `42-metrics-server.yml` | — |
| Argo CD | GitOps コントローラ | `50-argocd.yml` | ADR-0001 |
| sealed-secrets | Secret を git に載せる | gitops `platform/` | ADR-0006 |
| **Kong Ingress Controller** | L7 ルーティング（DB-less、ClusterIP proxy）| gitops `platform/` | ADR-0010（ingress-nginx を置換）|
| cloudflared | Cloudflare Tunnel 終端（2 レプリカ、token モード）| gitops `platform/` | ADR-0002 |
| Keycloak | OIDC（keycloakx chart、realm `nekoneko`）| gitops `platform/keycloak` | ADR-0010 |
| CloudNativePG | PostgreSQL operator | gitops `platform/` | ADR-0004 |
| PostgreSQL | RDB（`Cluster` CRD）| アプリ Helm チャート | ADR-0004 |
| local-path-provisioner | StorageClass（default、WaitForFirstConsumer）| gitops `platform/`（導入済み）| ADR-0004 |
| New Relic nri-bundle | k8s / インフラ監視（常用）| gitops `platform/newrelic` | ADR-0008 |
| OTel Collector | アプリ OTLP → New Relic（評価中は Instana にも）| gitops `platform/otel-collector` | ADR-0008 |
| Redis | cache + queue | 未導入（バックエンド設計に含むが現状不使用）| ADR-0004 |

> **MetalLB / cert-manager は入れない**（ADR-0005）。Instana は評価目的で GitOps 外（§11）。

---

## 5. ネットワークとトラフィック経路

### 5.1 公開リクエスト（南北）

```
ブラウザ
  │  https://api.nekonekoinsurance.com
  ▼
Cloudflare エッジ         TLS 終端 / WAF / レート制限 / キャッシュ
  │  (Tunnel: アウトバウンド接続)
  ▼
cloudflared Pod (2 レプリカ, namespace: cloudflared)
  │  http://kong-kong-proxy.kong.svc.cluster.local:80
  ▼
Kong Ingress Controller (ClusterIP, DB-less)
  │  Ingress ルール (ingressClassName: kong, host 振り分け)
  │    www.nekonekoinsurance.com  → nekoneko-frontend
  │    api.nekonekoinsurance.com  → nekoneko-hoken-api (:8080)
  │    auth.nekonekoinsurance.com → keycloak-keycloakx-http
  ▼
Service <app>   →   Pod
```

- 公開ホスト名 → Kong proxy の対応は **Cloudflare ダッシュボード**で設定
  （cloudflared は token モード）
- クラスタ内は HTTP（TLS はエッジで終端済み、ADR-0005）
- 自宅ルーターのポート開放は**一切不要**

### 5.2 ノード配置とサブネット間接続（ADR-0009）

```
LAN 192.168.1.0/24
 ├─ KVM ホストA 192.168.1.35 ── libvirt NAT 192.168.122.0/24
 │                                 ├─ k8s-cp-1     .11
 │                                 └─ k8s-worker-1 .21
 └─ KVM ホストB 192.168.1.188 ── macvtap（bridge mode, LAN 直結）
                                   └─ k8s-worker-2  192.168.1.22
```

- ホスト B は当初 br0 を検討したが、NetworkManager renderer + `netplan try` が
  ブリッジの revert 非対応で SSH 断のリスク → **macvtap（`type=direct, source_mode=bridge`）**に変更。
  ホスト↔自 VM は直接通信できない制約があるが、Ansible はホスト A から実行するので許容。
- ホスト A で **libvirt subnet ↔ LAN の NAT だけ無効化**
  （`scripts/04-interconnect.sh`: iptables no-SNAT + FORWARD ACCEPT + systemd）。
  VM→インターネットの NAT は維持。ダウンタイムなし。
- worker-2 VM に `192.168.122.0/24 via 192.168.1.35` の静的経路（cloud-init）。
- → **Flannel VXLAN（UDP 8472）がサブネット跨ぎで実 IP のまま流れる**（疎通確認済み）。
- （任意）ルーターに `192.168.122.0/24 via 192.168.1.35` → LAN 全体から到達可能。
- **既知の制約**: Pod ネットワーク（10.244.x）から他ホストの node IP（192.168.122.x）への
  経路は通らない。Instana host agent への OTLP 送信は otel-collector に `NODE_IP`
  （downward API）を渡して**自ノードの agent へ直送**することで回避（§11）。

### 5.3 クラスタ内（東西）

| 経路 | アドレス |
|---|---|
| API → PostgreSQL | `<release>-pg-rw.<ns>.svc:5432`（CNPG が RW Service を提供）|
| API / Worker → Redis | `<release>-redis.<ns>.svc:6379`（headless）|
| Pod ネットワーク | Flannel VXLAN `10.244.0.0/16` |
| Service ネットワーク | `10.96.0.0/12` |
| ノード間 VXLAN | ノード InternalIP:8472（跨ぎは §5.2 の相互接続経由）|

### 5.4 運用者アクセス（LAN）

クラスタ API（`192.168.122.11:6443`）は libvirt subnet 内。Mac からは
**SSH トンネル + kubeconfig**（`mac/` 一式）。ルーター静的ルート（§5.2）を
入れればトンネル不要になる。詳細は [mac/README.md](../mac/README.md)。

---

## 6. データと状態

| 状態 | 保管 | 冗長化 | バックアップ |
|---|---|---|---|
| PostgreSQL データ | worker のローカルディスク（local-path PV）| なし（将来 CNPG replica）| CNPG → R2/B2（base + WAL, PITR）|
| Redis（queue/cache）| worker のローカルディスク（AOF）| なし | CronJob で RDB → R2（queue 用途時）|
| Kubernetes オブジェクト | etcd（cp）| なし | **不要**（GitOps で再生成可能）|
| Secret（平文）| どこにも保存しない | — | sealing key を退避（§9）|
| マニフェスト / コード | GitHub | GitHub + ローカル clone | git |

**原則**: 状態は「Git」か「オブジェクトストレージ」のどちらかにあり、
物理ホストが消えても復元できること。詳細は
[backup-and-recovery.md](runbooks/backup-and-recovery.md)。

---

## 7. デプロイと CI/CD

### 7.1 リポジトリ構成（ADR-0007）

```
homelab-k8s   (public)   インフラ: KVM/kubeadm/Ansible/scripts/docs
homelab-gitops(private)  Argo CD の desired state: Application / platform / overlay
app-<name>    (private)  アプリ: コード / Dockerfile / Helm チャート / CI
```

### 7.2 フロー

```
app-<name> に push
   │
   ├─ CI: go test / helm lint
   ├─ CI: docker build → ghcr.io/<owner>/<name>:sha-xxxxxxxxxxxx
   └─ CI: homelab-gitops の apps/<name>/values-prod.yaml の
          image.tag を sha-xxxxxxxxxxxx に書き換えて commit/push
                    │
                    ▼
        Argo CD が homelab-gitops の変更を検知
                    │
                    ▼
        クラスタへ同期（自動 / prune / selfHeal）
```

- ロールバック = `homelab-gitops` を `git revert`
- gitops commit ↔ アプリ commit の対応は **image タグ = git sha**

### 7.3 Argo CD の構成

- `app-of-apps`: root Application → `homelab-gitops/bootstrap/children/` を recurse
- 依存順は **sync-wave**（実際の値）:
  - `-1`: sealed-secrets、local-path-provisioner
  - `0`: cnpg-operator、kong、newrelic-license
  - `1`: keycloak-infra（CNPG Cluster）、newrelic（nri-bundle）
  - `2`: keycloak、nekoneko-shared（ghcr pull secret）
  - `3`: nekoneko-frontend、nekoneko-api
  - cloudflared / otel-collector は独立（`0`）
- プラットフォームは Helm チャート直参照、アプリはマルチソース
  （chart は `app-<name>`、values は `homelab-gitops`）
- AppProject は `default`（1 人なので制限なし）
- private リポは repo-creds テンプレート 1 つ（`https://github.com/tukapai/` 配下に効く）
- 詳細な構造・運用は `homelab-gitops/docs/design.md`

---

## 8. 可用性・キャパシティ・DR

### 8.1 キャパシティ（ADR-0003 → ADR-0009 で解消済み）

- 物理 2 台構成。`k8s-worker-2` = ホスト B 上の VM（フルスペック）。
- `single_node_cluster: false`。cp は再 taint 済み（cp はシステムコンポーネント専用）。
  - 注: playbook が `taint nodes --all` していたため worker-1 にも taint が付く不具合があり、
    `-l node-role.kubernetes.io/control-plane` に修正した。
- ステートフル（CNPG）と重めのアプリは `nodeSelector: kubernetes.io/hostname: k8s-worker-2`。
- 全 Pod の requests/limits は引き続き必須（非力な worker-1・cp 保護）。
- 監視 DaemonSet（nri / instana agent）は cp の taint を許容（`tolerations: operator Exists`）。
- 手順: [add-physical-node.md](runbooks/add-physical-node.md)

### 8.2 可用性の考え方

物理 2 台になったが **etcd / control-plane は cp 単独**なので、まだ真の HA では
ない（次の課題: control-plane 冗長化 or etcd 外出し）。当面:

| 指標 | 目標 | 手段 |
|---|---|---|
| RPO（復旧地点）| PostgreSQL 数分 / その他 数時間 | WAL 連続アーカイブ、定期スナップショット |
| RTO（復旧時間）| 2–3 時間 | IaC 一発再構築 + Argo CD 全同期 + バックアップリストア |

Pod / ノード単位の障害は Kubernetes が自己修復。**ホスト全損**は
[backup-and-recovery.md](runbooks/backup-and-recovery.md) の通し手順で対応。

### 8.3 スケーリング

| 対象 | 方法 |
|---|---|
| Web API | HPA（CPU / 後でカスタムメトリクス）。stateless |
| PostgreSQL | 物理ノード追加後に CNPG `instances: 2+`（読みレプリカ / HA）|
| Redis | 当面スケールしない。必要なら Sentinel / Cluster を検討 |
| ノード | 物理マシン追加（VM を bridge 接続で join）|

---

## 9. Secret 管理（ADR-0006, Proposed）

- 平文 Secret は**どのリポジトリにもコミットしない**
- `kubeseal` で `SealedSecret` 化 → `homelab-gitops` にコミット →
  クラスタ内コントローラが復号
- 対象: Cloudflare Tunnel トークン、R2/B2 アクセスキー、アプリの外部 API キー、
  ghcr.io pull secret
- **sealing key のバックアップが必須**（暗号化して 2 か所）。
  失うと git 内の全 SealedSecret が復号不能 → §8 の再構築が破綻する
- 代替案: SOPS + age（age 秘密鍵 1 つで済み再構築に強い）。運用してみて
  sealing key 管理が負担なら移行

---

## 10. 環境（dev / prod）

- **クラスタは 1 つ**。staging クラスタは作らない（1 人には過剰）
- `dev` / `prod` は **namespace + Kustomize/Helm values の overlay** で分離
- `homelab-gitops/apps/<name>/values-dev.yaml` / `values-prod.yaml`
- 現状は `prod` のみ（`nekoneko` namespace）。dev は必要になったら別ホスト名で
  （`api-dev.nekonekoinsurance.com`、replica 1・小リソース）

---

## 11. 監視（ADR-0008）

**New Relic を常用（GitOps 管理）**。**Instana は評価目的で GitOps 外**
（一時導入・gitignore・撤去前提）。特に検証したいのは Instana の
「通常エージェント（収集） ↔ バックエンドの AI 機能」の連携。
アプリの計装は **OpenTelemetry / Micrometer**（Collector 経由、OTLP/HTTP :4318）。

**現在: 両方稼働中。** アプリ（nekoneko-hoken-api）の metrics / traces は
otel-collector から New Relic と Instana の両方へファンアウト（送信確認済み）。
KVM ホスト（A / B）には NR Infra agent と Instana host agent の両方が稼働。

```
                    ┌──────────────────────────────────┐
アプリ (OTel SDK) ──▶│ OTel Collector (observability ns) │──▶ New Relic OTLP   常用/GitOps
                    └───────────────┬──────────────────┘ (評価中のみ eval-instana overlay で
                                    ▼                       instana-agent OTLP も追加)
層1 ホスト/KVM : NR Infra agent（60-host-agents.yml, 常設）
                Instana host agent（playbooks/local/60b-…, 評価・gitignore）
層2 k8s/ミドル : NR nri-bundle（gitops platform/newrelic, 常設）
                instana-agent（platform/eval/instana/install.sh = helm 直接, 評価・gitignore）
層3 アプリ    : OTel SDK → Collector（上図）
```

| 層 | 常用（New Relic・GitOps）| 評価（Instana・GitOps 外）|
|---|---|---|
| ホスト / KVM | Infra agent（apt）| host agent（deb / setup script）|
| k8s / ミドルウェア | nri-bundle（infra/k8s/KSM/logs、Pixie・prometheus 無効）| instana-agent（Operator + DaemonSet）|
| アプリ | OTel → Collector → NR OTLP | 評価中: Collector の ConfigMap を一時差し替え |

- NR license は SealedSecret（cluster-wide scope で `newrelic` / `observability` 両 ns 共用）
- Instana の agent key は評価用スクリプト（`homelab-gitops/platform/eval/instana/install.sh`、
  helm 直接）が `kubectl create secret` / host agent は `60b-instana-host-agent.yml`（gitignore）
- Instana に app トレースも流すため、評価中は `platform/otel-collector/eval-instana/` の
  ConfigMap で otel-collector を一時差し替え（`otlp/instana` exporter 追加）。
  root(app-of-apps) の selfHeal を一時 OFF にして差し替えを維持する（撤去手順は同ファイル）。
- otel-collector → Instana host agent は Service 経由だとクロスホスト経路で不通のため
  `${env:NODE_IP}:4317`（自ノードの agent 直送）。
- Instana は非力クラスタ + 2 スタック常設不可のため**期限を切る**（トライアル期限あり）。
- Instana host agent が cp に載らない → `agent.pod.tolerations: [{operator: Exists}]`
- 外形監視: healthchecks.io / UptimeRobot で公開ヘルスエンドポイント（TODO）
- 評価後にツールを一本化する判断は別 ADR で

#### nri-bundle / otel-collector で踏んだ点（記録）

| 事象 | 対処 |
|---|---|
| nri-bundle が helm template 失敗（V3 で legacy `resources:` 不可）| `kubelet` / `ksm` / `controlPlane` 別に `resources` を指定 |
| otel-collector `0.116.0` の amd64 イメージが `exec /otelcol-contrib: no such file` | `0.128.0` に固定（0.115–0.116 が壊れている）|
| `service.telemetry.metrics.address` が 0.123+ で廃止 | `readers:` (prometheus pull) 形式に |
| アプリが OTLP メトリクスを gRPC ポート :4317 に送り失敗 | Micrometer / Boot tracing は **OTLP/HTTP :4318**。`management.otlp.{metrics,tracing}` に統一 |
| `platform-newrelic` が logging DS で常時 OutOfSync（`argocd app diff` は clean）| chart の明示 null + API server defaulting の差。機能影響なしとして許容 |

---

## 12. セキュリティ

| 項目 | 対策 |
|---|---|
| 公開面 | Cloudflare（WAF / レート制限 / DDoS / 実 IP 秘匿）。ルーター開放なし |
| クラスタ API | NAT 内。外部露出なし。運用者は SSH トンネル経由 |
| Secret | git に平文を置かない（§9）|
| コンテナ | distroless / nonroot、requests/limits、`imagePullPolicy` 明示 |
| ネットワークポリシー | TODO（namespace 間の既定 deny を検討）|
| 認証情報の権限 | CI の gitops 書き込みは専用 PAT / GitHub App に限定 |
| Dashboard トークン | `cluster-admin`。LAN のみ公開、`.gitignore` 済み |
| ノード | `kubeadm` 既定 + `apt-mark hold`。定期パッチ（TODO: 自動化）|

---

## 13. 未決事項・ロードマップ

### 完了

- ✅ 3 リポジトリを GitHub へ push（SSH remote。fine-grained PAT は repo 作成 / workflow push 不可）
- ✅ Argo CD ブートストラップ、platform 一式 Synced/Healthy
- ✅ Kong / Keycloak / cloudflared / local-path / CNPG operator
- ✅ Sealed Secrets（ADR-0006 は Sealed Secrets で開始）
- ✅ imagePullSecret（`nekoneko-shared` + `ghcr-pull`、private ghcr のまま）
- ✅ 初アプリ（nekoneko-frontend + nekoneko-hoken-api）を公開まで
- ✅ 2 台目物理ノード（ホスト B / macvtap）→ 3 ノード化
- ✅ 監視（New Relic 常用 + Instana 評価）両方稼働
- ✅ `GITOPS_TOKEN` 設定（CI の bump-gitops が image タグを sha に自動更新、動作確認済み）

### 未決 / TODO

- Keycloak admin パスワードの SealedSecret 化
- R2 バケット `nekoneko-attachments` + PG バックアップ有効化 → リストア訓練
- NetworkPolicy の方針（namespace 間 既定 deny）
- 外形監視（healthchecks.io / UptimeRobot）
- control-plane 冗長化 or etcd 外出し（真の HA）
- Instana 評価の完了 → 撤去 → 一本化の ADR
- 漏洩した PAT 2 本のローテーション

---

## 14. 参照

| 種別 | 場所 |
|---|---|
| 意思決定記録 | [docs/adr/](adr/) （0001–0010）|
| GitOps の構造・運用 | `homelab-gitops/docs/design.md` |
| 運用手順 | [docs/runbooks/](runbooks/) |
| インフラ手順 | [README.md](../README.md) |
| Mac からの接続 | [mac/README.md](../mac/README.md) |
| 解説記事ドラフト | [docs/qiita-article.md](qiita-article.md) |
