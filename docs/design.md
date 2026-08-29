# 設計ドキュメント — homelab Kubernetes 基盤

自宅の物理マシン上に Kubernetes クラスタを構築し、その上でインターネット公開
する Web アプリケーションと周辺ミドルウェアを **1 人で無理なく運用する**ための
設計。個々の意思決定の根拠は [ADR](adr/)、手順は [runbook](runbooks/) を参照。

- 対象読者: 将来の自分、この構成を参考にする人
- ステータス: 基盤構築済み / プラットフォーム・アプリは実装フェーズ
- 最終更新: 2026-08-29

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
│  Web API (Deployment/HPA)   Worker (queue consumer)             │
│  namespace: <app>-prod / <app>-dev                              │
├─ L4 アプリ付随ミドルウェア ──────────────────────────────────────┤
│  PostgreSQL (CloudNativePG Cluster)   Redis (StatefulSet)       │
│  ※ nodeSelector で worker 固定（ADR-0003/0004）                 │
├─ L3 プラットフォーム（Argo CD が homelab-gitops から同期）────────┤
│  Argo CD   ingress-nginx(ClusterIP)   cloudflared               │
│  sealed-secrets   CloudNativePG operator   metrics-server       │
├─ L2 Kubernetes クラスタ（kubeadm, homelab-k8s/ansible）──────────┤
│  control-plane: k8s-cp-1     worker: k8s-worker-1 (VM)          │
│  containerd + SystemdCgroup / CNI Flannel / v1.31              │
├─ L1 仮想化基盤（homelab-k8s/scripts）───────────────────────────┤
│  KVM / libvirt  ·  cloud-init で Ubuntu 24.04 VM を払い出し      │
├─ L0 物理 ─────────────────────────────────────────────────────┤
│  Ubuntu 24.04 / AMD-V / ~64GB RAM （当面 1 台）                  │
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
| ingress-nginx | L7 ルーティング（ClusterIP）| gitops `platform/` | ADR-0002/0005 |
| cloudflared | Cloudflare Tunnel 終端 | gitops `platform/` | ADR-0002 |
| CloudNativePG | PostgreSQL operator | gitops `platform/` | ADR-0004 |
| PostgreSQL | RDB | アプリ Helm チャート | ADR-0004 |
| Redis | cache + queue | アプリ Helm チャート | ADR-0004 |
| local-path-provisioner | StorageClass（単一ノード）| （k3s 由来ではないため要導入 TODO）| ADR-0004 |

> **MetalLB / cert-manager は入れない**（ADR-0005）。

---

## 5. ネットワークとトラフィック経路

### 5.1 公開リクエスト（南北）

```
ブラウザ
  │  https://api.example.com
  ▼
Cloudflare エッジ         TLS 終端 / WAF / レート制限 / キャッシュ
  │  (Tunnel: アウトバウンド接続)
  ▼
cloudflared Pod (2 レプリカ, namespace: cloudflared)
  │  http://ingress-nginx-controller.ingress-nginx.svc:80
  ▼
ingress-nginx (ClusterIP)
  │  Ingress ルール (host: api.example.com)
  ▼
Service <app>   →   Web API Pod (:8080)
```

- 公開ホスト名 → サービスの対応は **Cloudflare ダッシュボード**で設定
  （cloudflared は token モード）
- クラスタ内は HTTP（TLS はエッジで終端済み、ADR-0005）
- 自宅ルーターのポート開放は**一切不要**

### 5.2 ノード配置とサブネット間接続（ADR-0009）

```
LAN 192.168.1.0/24
 ├─ KVM ホストA 192.168.1.35 ── libvirt NAT 192.168.122.0/24
 │                                 ├─ k8s-cp-1     .11
 │                                 └─ k8s-worker-1 .21
 └─ KVM ホストB 192.168.1.188 ── br0（LAN 直結）
                                   └─ k8s-worker-2  192.168.1.22
```

- ホスト A で **libvirt subnet ↔ LAN の NAT だけ無効化**
  （`scripts/04-interconnect.sh`: iptables no-SNAT + FORWARD ACCEPT + systemd）。
  VM→インターネットの NAT は維持。ダウンタイムなし。
- worker-2 VM に `192.168.122.0/24 via 192.168.1.35` の静的経路（cloud-init）。
- → **Flannel VXLAN（UDP 8472）がサブネット跨ぎで実 IP のまま流れる**。
- （任意）ルーターに `192.168.122.0/24 via 192.168.1.35` → LAN 全体から到達可能。

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
- 依存順は **sync-wave**: sealed-secrets(-1) → ingress-nginx / cnpg-operator(0)
  → cloudflared(1) → アプリ(2)
- プラットフォームは Helm チャート直参照、アプリはマルチソース
  （chart は `app-<name>`、values は `homelab-gitops`）
- AppProject は `default`（1 人なので制限なし）

---

## 8. 可用性・キャパシティ・DR

### 8.1 キャパシティ（ADR-0003 → ADR-0009 で解消中）

- 物理 2 台構成へ移行中。`k8s-worker-2` = ホスト B 上の VM（フルスペック）。
- `single_node_cluster: false` に戻し、cp を再 taint。プラットフォーム / アプリは
  worker 群（worker-1 = 2vCPU/4GB、worker-2 = フルスペック）へ。
- ステートフル（CNPG / Redis）の `nodeSelector` を worker-1 固定から見直し。
- 全 Pod の requests/limits は引き続き必須（スケジューリングの健全性）。
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
- dev は replica 1・小リソース・別ホスト名（`api-dev.example.com`）

---

## 11. 監視（ADR-0008）

**New Relic を常用（GitOps 管理）**。**Instana は評価目的で GitOps 外**
（一時導入・gitignore・撤去前提）。特に検証したいのは Instana の
「通常エージェント（収集） ↔ バックエンドの AI 機能」の連携。
アプリの計装は **OpenTelemetry 1 本**（Collector 経由）。

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
- Instana の agent key は評価用スクリプトが直接 `kubectl create secret` / ファイル配置（git 外）
- Instana は非力クラスタ + 2 スタック常設不可のため**期限を切る**。
  導入・AI 機能の検証・撤去は `docs/runbooks/instana-eval.md`（gitignore）
- 評価期間中は監視だけで **~2 CPU / ~2.5GB** 消費（§8 のリソース余裕に注意）
- 外形監視: healthchecks.io / UptimeRobot で公開ヘルスエンドポイント（別途）
- 評価後にツールを一本化する判断は別 ADR で

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

### 未決

- ADR-0006（Secret 管理）: Sealed Secrets で開始か SOPS+age か
- `local-path-provisioner` の導入（gitops `platform/` に追加）
- ghcr.io の imagePullSecret 配布方法
- NetworkPolicy の方針
- 監視のフェーズ 2 の具体（Grafana Cloud か自ホストか）

### ロードマップ

1. `single_node_cluster: true` 反映（`site.yml` 再実行）
2. 3 リポジトリを GitHub へ push
3. `50-argocd.yml` で Argo CD ブートストラップ
4. `homelab-gitops` の `CHANGEME` 置換、Cloudflare Tunnel トークン封入
5. platform 一式が Synced/Healthy になることを確認
6. `local-path-provisioner` を追加
7. 最初のアプリ（`app-template` 派生）を通す
8. R2/B2 バケット作成、PostgreSQL バックアップ有効化 → リストア訓練
9. 監視フェーズ 2
10. 2 台目物理ノード（時期未定）→ 暫定策解除

---

## 14. 参照

| 種別 | 場所 |
|---|---|
| 意思決定記録 | [docs/adr/](adr/) （0001–0007）|
| 運用手順 | [docs/runbooks/](runbooks/) |
| インフラ手順 | [README.md](../README.md) |
| Mac からの接続 | [mac/README.md](../mac/README.md) |
| 解説記事ドラフト | [docs/qiita-article.md](qiita-article.md) |
