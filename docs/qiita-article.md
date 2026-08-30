# 自宅の物理2台でKubernetesを組んで、GitOps・Ingress・認証・監視まで載せて本番公開する

<!--
Qiita 投稿用ドラフト。
タグ候補: Kubernetes, kubeadm, KVM, ArgoCD, Observability
リポジトリ:
  - https://github.com/tukapai/homelab-k8s      （インフラ: KVM / kubeadm / Ansible）
  - homelab-gitops（private: Argo CD の desired state）
  - cat_insureance_demo_app / nekoneko-hoken-api（private: アプリ）
-->

## この記事でやること

自宅の Ubuntu マシン 2 台を使って、次のものを **1 人で無理なく運用できる**ように組み上げた記録です。

- KVM 上に kubeadm で Kubernetes クラスタ（3 ノード / 物理 2 台にまたがる）
- Argo CD による GitOps（app-of-apps、SealedSecrets）
- Kong Ingress Controller + Keycloak（OIDC）
- Cloudflare Tunnel でルーター開放なしのインターネット公開
- 実アプリ（架空のペット保険デモ「ねこねこ保険」）を `nekonekoinsurance.com` で公開
- New Relic（常用）+ Instana（評価）の 2 系統監視

全部スクリプト / マニフェスト化してあるので、リポジトリを clone すれば再現できます。
分量が多いので、**各フェーズの「ハマったところ」を中心に**まとめます。

### 最終構成

```
                Internet
                   │ HTTPS
        ┌──────────▼───────────┐
        │ Cloudflare (DNS/TLS/  │
        │  WAF) + Tunnel        │
        └──────────┬───────────┘
                   │ アウトバウンド接続のみ（ポート開放なし）
        ┌──────────▼──────────────────────────────────────────┐
        │ 自宅LAN 192.168.1.0/24                               │
        │                                                     │
        │  物理ホストA (192.168.1.35)     物理ホストB (192.168.1.188)│
        │  ├ libvirt NAT 192.168.122.0/24  └ macvtap 直付け      │
        │  │  ├ k8s-cp-1     .122.11                            │
        │  │  └ k8s-worker-1 .122.21        k8s-worker-2 .1.22   │
        │  │                                                   │
        │  └─ Flannel VXLAN がサブネットを跨いで疎通（後述）      │
        │                                                     │
        │  cloudflared ──▶ Kong ──▶ ┌ nekoneko-frontend (静的)  │
        │                           ├ nekoneko-hoken-api (Spring)│
        │                           └ Keycloak (OIDC)           │
        │  Argo CD が homelab-gitops リポジトリと全部を同期        │
        │  監視: New Relic + Instana（OTel Collector 経由）      │
        └─────────────────────────────────────────────────────┘
```

### リポジトリは 3 つに分けた

| リポジトリ | 役割 | 可視性 |
|---|---|---|
| `homelab-k8s` | インフラ: KVM / kubeadm / Ansible / スクリプト / ADR | public |
| `homelab-gitops` | Argo CD が同期する desired state | private |
| `cat_insureance_demo_app` / `nekoneko-hoken-api` | アプリのコード + Helm チャート + CI | private |

「インフラの作り方」と「クラスタに今何が載っているか」を分離したかったのが理由です（設計判断は各リポの ADR に残しています）。

---

## Phase 1: KVM + kubeadm でクラスタを立てる

### KVM ホストのセットアップ

`scripts/01-install-kvm-host.sh` は要するにこれだけです。

```bash
sudo apt-get install -y \
    qemu-kvm libvirt-daemon-system libvirt-clients \
    virtinst cloud-image-utils ansible python3-libvirt
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"
```

### cloud-init で VM を払い出す

`scripts/02-create-node-vm.sh` の肝は「**VM 名から MAC を決定的に生成**」しているところです。

```bash
mac_for() {
    local h; h="$(echo -n "$1" | md5sum | cut -c1-6)"
    echo "52:54:00:${h:0:2}:${h:2:2}:${h:4:2}"
}
```

同じ名前なら必ず同じ MAC になるので、libvirt の DHCP 予約（`MAC → 固定 IP`）と常に一致します。VM を作り直しても IP がずれません。

```bash
./scripts/02-create-node-vm.sh
#   → k8s-cp-1 / 192.168.122.11 / 4 vCPU / 8GB / 60GB
```

### kubeadm + Ansible

`ansible-playbook site.yml` で 3 本（共通 → control-plane → workers）を流します。中身は素直な kubeadm です。

```yaml
kubeadm init
  --pod-network-cidr=10.244.0.0/16
  --apiserver-advertise-address=192.168.122.11
  --cri-socket=unix:///run/containerd/containerd.sock
```

その後 Flannel を `kubectl apply`、`admin.conf` を手元に `fetch`。

### ハマり: `conntrack not found`

初回の `kubeadm init` の preflight でこけました。

```
[ERROR FileExisting-conntrack]: conntrack not found in system path
```

Ubuntu cloud image には `conntrack` が入っていません。共通 playbook のパッケージリストに `conntrack` / `socat` / `ethtool` を足して解決。

### ハマり: containerd 2.x の SystemdCgroup

`containerd config default` で吐いた設定を `SystemdCgroup = true` に置換してから restart、を忘れると kubelet がぐずります。playbook で毎回やるようにしています。

---

## Phase 2: 2 台目の物理マシンを worker にする

ここが一番苦労しました。既存クラスタ（ホスト A の libvirt NAT `192.168.122.0/24`）を**止めずに**、別の物理ホスト B 上の VM を worker として join させます。

### 方針: NAT だけ部分的に無効化

ホスト B の VM を LAN 直結（`192.168.1.22`）にして、
ホスト A 側で「**libvirt subnet ↔ LAN の間の NAT だけ**」を無効化します。VM → インターネットの NAT は残します。

`scripts/04-interconnect.sh` がやること:

```bash
# libvirt の MASQUERADE より前に「この2サブネット間は NAT しない」を挿入
iptables -t nat -I POSTROUTING -s 192.168.122.0/24 -d 192.168.1.0/24 -j RETURN
iptables -t nat -I POSTROUTING -s 192.168.1.0/24 -d 192.168.122.0/24 -j RETURN
# FORWARD も通す
iptables -I FORWARD -s 192.168.122.0/24 -d 192.168.1.0/24 -j ACCEPT
iptables -I FORWARD -s 192.168.1.0/24 -d 192.168.122.0/24 -j ACCEPT
```

これを systemd unit で永続化（再起動 / libvirt リロード後も復元）。ダウンタイムゼロで入ります。worker-2 VM 側には cloud-init で `192.168.122.0/24 via 192.168.1.35` の静的経路を入れます。

これで **Flannel の VXLAN（UDP 8472）がサブネットを跨いで実 IP のまま流れる**ようになり、Pod 間通信 / DNS が通ります。

### ハマり: `iptables` の引数順

配列で `("-t" "nat" "POSTROUTING" ...)` を組んで `iptables -I "${rule[@]}"` のように展開したら、

```
iptables v1.8.10 (nf_tables): Invalid rule number 'nat'
```

`iptables -I -t nat ...` という順序になって死んでいました。`-t nat` は `-I` より前に置く必要があります。関数化して `iptables -t nat "$1" CHAIN ...`（`$1` は `-C` / `-I` / `-D`）に修正。

### ハマり: bridge をあきらめて macvtap に

当初はホスト B に `br0` を作る予定でしたが、ホスト B は NetworkManager renderer で `netplan try` が**ブリッジの revert に非対応**。設定ミスで SSH が切れると詰みます。

→ **macvtap（`--network type=direct,source=<NIC>,source_mode=bridge`）** に変更。host bridge を作らないので安全です。制約として「ホスト ↔ 自分の VM は直接通信できない」がありますが、Ansible はホスト A から実行するので問題なし。

### ハマり: taint が worker にも付く

`single_node_cluster: false` にすると control-plane に taint を付け直す処理が走りますが、これが

```bash
kubectl taint nodes --all node-role.kubernetes.io/control-plane=:NoSchedule
```

と `--all` になっていて、**worker-1 にも taint が付いて**全 Pod が worker-2 に偏っていました。`-l node-role.kubernetes.io/control-plane` に修正。

---

## Phase 3: Argo CD で GitOps

クラスタができたら、以降のプラットフォーム / アプリは Ansible では触りません。`50-argocd.yml` で Argo CD をブートストラップし、**app-of-apps** の root Application が `homelab-gitops` リポジトリの `bootstrap/children/` を読みます。

```
root Application
  └─ bootstrap/children/*.yaml を全部 Application として apply
        platform-sealed-secrets   (wave -1)
        platform-local-path       (wave -1)   default StorageClass
        platform-cnpg-operator    (wave  0)
        platform-kong             (wave  0)
        platform-keycloak-infra   (wave  1)
        platform-keycloak         (wave  2)
        app-nekoneko-*            (wave  3)
        ...
```

依存順は `argocd.argoproj.io/sync-wave` で制御します。

### Secret は SealedSecret

平文 Secret はコミットしません。`kubeseal` で暗号化して git に入れ、クラスタ内のコントローラが復号します。

```bash
make seal-newrelic LICENSE='...'      # New Relic license
make seal-cloudflared TOKEN='...'     # Cloudflare Tunnel token
make seal-ghcr PAT='...'              # private ghcr の imagePullSecret
```

**sealing key のバックアップだけは必須**です（失うと git 内の全 SealedSecret が復号不能）。

### ハマり: chart repo が消えている

`sealed-secrets` を chart repo（`bitnami-labs.github.io/sealed-secrets`）から入れようとしたら 404。GitHub Pages のチャート配信が廃止されていました。

→ Argo CD は **git リポジトリを直接 Helm チャートソースにできる**ので、`github.com/bitnami-labs/sealed-secrets` の `helm/sealed-secrets` パスをタグ固定で参照。

```yaml
source:
  repoURL: https://github.com/bitnami-labs/sealed-secrets
  targetRevision: helm-v2.19.3
  path: helm/sealed-secrets
```

### ハマり: StorageClass が無くて全 stateful が Pending

kubeadm 素のクラスタには動的プロビジョナが無いので、CNPG も Keycloak も PVC で止まります。`local-path-provisioner`（Rancher）を wave -1 で入れて default StorageClass に。

### ハマり: inline helm values が子 App に伝播しない

`bootstrap/children/*.yaml` の中に `helm.values` をインラインで書いている場合、
そのファイルを変えたら **root を先に sync**（hard refresh）しないと子 Application に伝わりません。root が Application リソース自体を書き換える → 子が新しい values で再同期、という順序です。`kubectl patch app <child> sync` だけだと古い values のままになります。

### ハマり: private リポの認証

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

---

## Phase 4: Kong + Keycloak + Cloudflare Tunnel で公開

### Ingress は Kong Ingress Controller

当初 ingress-nginx を想定していましたが、アプリ設計側が Kong 前提だったので **Kong Ingress Controller（DB-less モード）**に置換。proxy Service は `ClusterIP` にして、外からは Cloudflare Tunnel 経由でのみ到達します。

### Cloudflare Tunnel（token モード）

`cloudflared` を 2 レプリカでクラスタ内に置き、Cloudflare へ**アウトバウンド接続**します。自宅ルーターのポート開放は一切不要。公開ホスト名 → 内部サービスの対応は Cloudflare ダッシュボードで設定します。

| Hostname | Service |
|---|---|
| `www` / `api` / `auth`.nekonekoinsurance.com | `http://kong-kong-proxy.kong.svc.cluster.local:80` |

TLS はエッジ終端。クラスタ内は HTTP なので cert-manager も MetalLB も不要です。

### Keycloak

`codecentric/keycloakx` チャートで Keycloak 26。realm 定義（ロール、SPA / API クライアント）を ConfigMap にして `--import-realm` で流し込みます。

#### ハマり: `kc.sh` が help を出して終了する

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

#### ハマり: CrashLoop（JGroups DNS_PING）

`start` の既定はクラスタキャッシュ（Infinispan + JGroups DNS_PING）で、単一レプリカだと `dns_query can not be null or empty` で落ちます。`--cache=local` で解決。

#### ハマり: `/auth` 配下で配信される

keycloakx チャートの既定 `http.relativePath` が `/auth`。`"/"` に上書き。

### ハマり: private ghcr からの pull

パッケージを private のまま使いたかったので、`nekoneko` namespace に `ghcr-pull`（`dockerconfigjson`）の SealedSecret を配布し、各アプリの values で `imagePullSecrets` を指定。チャート側は `{{- with .Values.imagePullSecrets }}` で Pod spec に注入します。

---

## Phase 5: 実アプリ「ねこねこ保険」を載せる

架空の猫用ペット保険のデモアプリです。

- **フロント**: 静的 HTML/CSS/JS（`nginxinc/nginx-unprivileged`）
- **バックエンド**: Spring Boot 3.4 / Java 21 / Gradle、Flyway（13 テーブル）、Spring Security Resource Server（Keycloak の JWT 検証）

### ハマり: fine-grained PAT でリポジトリが作れない / workflow が push できない

```
refusing to allow a Personal Access Token to create or update workflow ... without workflow scope
```

fine-grained PAT の制限です。リモートを SSH に切り替えて解決。

### ハマり: Gradle wrapper をコミットできない

`gradlew` の jar はバイナリで、こちらから生成してコミットするのが難しい。
→ Dockerfile も CI も `gradle:8.12` イメージ / `gradle` コマンドを直接使う構成にして wrapper 依存をなくしました。

### ハマり: nginx-unprivileged で `RUN rm` が Permission denied

Dockerfile で `RUN rm /usr/share/nginx/html/Dockerfile` していたら non-root ユーザーで消せずビルド失敗。`.dockerignore` で除外する方式に。

### 結果

```
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

---

## Phase 6: New Relic + Instana で監視

方針（ADR）:

- **常用 = New Relic**（GitOps 管理）
- **評価 = Instana**（GitOps 外・gitignore・撤去前提）。エージェントと Instana の AI 機能の連携を検証したい
- アプリの計装は **OpenTelemetry / Micrometer 1 本**。OTel Collector が New Relic に送る（評価中は Instana にも fan-out）

```
アプリ (Micrometer/OTel, OTLP/HTTP :4318)
        │
        ▼
OTel Collector ──┬──▶ New Relic OTLP        （常用 / GitOps）
                 └──▶ Instana agent :4317   （評価中のみ overlay で追加）

ホスト/KVM : NR Infra agent + Instana host agent（Ansible）
k8s       : nri-bundle + instana-agent（helm）
```

### ハマり: nri-bundle V3 が `resources:` を受け付けない

```
The chart cannot be rendered since ... 'resources' option ... not fully compatible with the v3 version.
```

`newrelic-infrastructure` が V3 になり、`resources` は `kubelet` / `ksm` / `controlPlane` 別に指定する形式に変わっていました。

### ハマり: OTel Collector の 0.116.0 イメージが壊れている

```
exec /otelcol-contrib: no such file or directory
```

`otel/opentelemetry-collector-contrib` の `linux/amd64` イメージが、
`0.115` / `0.116` で壊れていました（`0.114` と `0.119` は OK）。`0.128.0` に固定して回避。

### ハマり: `telemetry.metrics.address` が廃止されていた

Collector 0.123+ で `service.telemetry.metrics.address` が削除。`readers:`（Prometheus pull exporter）形式に書き換え。

### ハマり: アプリが OTLP を gRPC ポートに送っていた

```
Failed to publish metrics ... url=http://otel-collector:4317/v1/metrics ... HTTP status code -1
```

Micrometer の OTLP registry も Spring Boot の tracing も **OTLP/HTTP エクスポータ**なので、送り先は **`:4318`**（gRPC の `:4317` ではない）。`management.otlp.metrics.export.url` / `management.otlp.tracing.endpoint` を `:4318` に統一。

### ハマり: Instana agent への OTLP がクロスホストで届かない

Instana agent（hostNetwork DaemonSet）は各ノード IP で `:4317` を LISTEN しますが、Service 経由だと kube-proxy が**他ホストのノード IP**に振り分けることがあり、Phase 2 の制約（Pod → 他ホストの node IP は経路なし）で `connection refused`。

→ OTel Collector に downward API で `NODE_IP`（`status.hostIP`）を渡し、
`otlp/instana` の endpoint を `${env:NODE_IP}:4317` にして**自ノードの agent へ直送**。

### ハマり: Instana セットアップスクリプトがハングする

Ansible の `shell` から `/tmp/instana-setup.sh` を叩くと、

- `set -o pipefail` が `/bin/sh`（dash）で動かない → `args: { executable: /bin/bash }`
- `Do you want to continue? [y/N]` の対話プロンプトで無限待ち → `-y` を付与

### ハマり: `apt-get update` の巻き添え

ホスト A で New Relic playbook を流したら `Failed to update apt cache`。
原因はホストに元々あった**別のリポジトリ**（rocm 等）が壊れていて `apt-get update` 全体が非 0 を返していたため。

→ 導入済みなら repo 操作をスキップ。新規導入時も

```bash
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/newrelic-infra.list \
               -o Dir::Etc::sourceparts=/dev/null
```

で **New Relic のリポジトリだけ**を対象に。

### 評価用コードを GitOps に混ぜない工夫

Instana は「評価が終わったら消す」ものなので、

- `install.sh`（helm 直接）と host agent playbook は `.gitignore`
- OTel Collector の差し替えは別 ConfigMap（`eval-instana/`、gitignore）
- 差し替え中だけ root(app-of-apps) の `selfHeal` を OFF にして、`platform-otel-collector` の auto-sync を止める

撤去手順はその ConfigMap のヘッダコメントに全部書いてあります。

---

## ハマったポイント総まとめ

| フェーズ | 症状 | 原因 / 対処 |
|---|---|---|
| kubeadm | `conntrack not found` | cloud image に無い。共通 playbook で apt install |
| cross-host | `iptables Invalid rule number 'nat'` | `-t nat` は `-I` より前 |
| cross-host | netplan で bridge が revert できず SSH 断リスク | macvtap に変更 |
| cross-host | 全 Pod が worker-2 に偏る | `taint nodes --all` → `-l ...control-plane` |
| Argo CD | chart repo が 404 | git リポジトリを直接 Helm ソースに |
| Argo CD | stateful 全 Pending | local-path-provisioner を default SC に |
| Argo CD | inline values が反映されない | root を先に hard refresh + sync |
| Keycloak | help 出して終了 / CrashLoop / `/auth` 配下 | `command` 明示 / `--cache=local` / `relativePath: "/"` |
| アプリ | fine-grained PAT で workflow push 不可 | SSH リモートに |
| アプリ | `gradlew` をコミットできない | `gradle:8.12` イメージを直接使う |
| 監視 | nri-bundle V3 が `resources:` 拒否 | component 別に指定 |
| 監視 | `exec /otelcol-contrib: no such file` | 0.116 イメージ破損。0.128 に |
| 監視 | Micrometer OTLP が `HTTP status code -1` | 送り先は `:4318`（HTTP）、`:4317` ではない |
| 監視 | Instana agent に OTLP 届かず | `${env:NODE_IP}:4317` で自ノード直送 |
| 監視 | Instana setup script がハング | `-y` + `executable: /bin/bash` |

---

## まとめ

- 物理 2 台・3 ノードのクラスタを、既存クラスタを止めずに拡張できた（NAT 部分無効化 + macvtap）
- クラスタ構築後は Argo CD がすべて（プラットフォーム / アプリ / 監視）を GitOps で管理
- Kong + Keycloak + Cloudflare Tunnel でルーター開放なしの本番公開
- New Relic を常用、Instana は「消せる形」で評価導入
- 環境依存値は `config.env` / `values-prod.yaml` に隔離、Secret は SealedSecret

「1 人で運用」を最優先にすると、**再現可能性**（IaC + GitOps）と**片付けやすさ**（評価コードを混ぜない）が効いてきます。

### リポジトリ

- インフラ: https://github.com/tukapai/homelab-k8s
- 設計判断は各リポの `docs/adr/`、運用手順は `docs/runbooks/` に
