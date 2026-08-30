# 自宅の物理2台でKubernetesをGitOpsまで【第3回】New Relic + Instana で監視（評価ツールを「消せる形」で入れる）

<!--
Qiita 連載（全3回）第3回。
タグ候補: Kubernetes, OpenTelemetry, NewRelic, Instana, ArgoCD
連載インデックス: docs/qiita-article.md
-->

## この連載について

自宅の Ubuntu マシン 2 台で本番運用できる Kubernetes 基盤を組む記録の最終回です。

1. 第1回: KVM + kubeadm で 3 ノードクラスタ（物理 2 台にまたがる）
2. 第2回: Argo CD で GitOps + Kong / Keycloak / Cloudflare Tunnel で公開
3. **【第3回・本記事】New Relic + Instana で監視**

第2回で実アプリが `nekonekoinsurance.com` で公開できました。この回では監視を入れます。用語は都度説明します。

---

## 0. 前提知識の整理

### オブザーバビリティの 3 本柱

「監視（monitoring）」は事前に決めた指標を見ること、「オブザーバビリティ（observability）」は未知の問題も外から追える状態のこと。実務では次の 3 つのシグナルを集めます。

| シグナル | 何 | 例 |
|---|---|---|
| **メトリクス（metrics）** | 数値の時系列 | CPU 使用率、リクエスト数/秒、レイテンシの分位数 |
| **トレース（traces）** | 1 リクエストが複数サービスをどう通ったか | `POST /simulate` → DB クエリ 3 回（各 2ms）→ レスポンス |
| **ログ（logs）** | イベントのテキスト記録 | `ERROR ... NullPointerException` |

トレースの単位は **スパン（span）**。1 リクエストが「API で 10ms、うち DB で 3ms」なら親スパン 1 + 子スパン 1。

### OpenTelemetry（OTel）と OTLP

**OpenTelemetry** は、これら 3 シグナルの**収集・生成・送信を標準化**したプロジェクト（CNCF）。ベンダー中立なので、「アプリの計装コードは OTel で書き、送り先だけ後で選ぶ」ができます。

- **OTLP（OpenTelemetry Protocol）**: OTel の転送プロトコル。2 つの通信方式がある
  - **gRPC 版**: ポート **4317**
  - **HTTP 版**（protobuf over HTTP/1.1）: ポート **4318**、パスは `/v1/traces` `/v1/metrics` `/v1/logs`
  - **この 4317 / 4318 の取り違えが今回の大きなハマりポイント**（後述）
- **OTel Collector**: 受け取ったテレメトリを加工して転送する中継エージェント。構成は 3 段
  - **receivers**: 受け口（OTLP、Prometheus scrape など）
  - **processors**: 加工（バッチ化、属性付与、メモリ制限など）
  - **exporters**: 送り先（New Relic、Instana、...）
  - これらを **pipeline**（`traces` / `metrics` / `logs` 別）で繋ぐ

### エージェント方式 vs OTel 方式

商用 APM（New Relic / Instana / Datadog...）には 2 つのデータ取得経路があります。

- **エージェント方式**: ベンダー製のエージェントをホストや K8s に常駐させ、ホスト/コンテナ/K8s の状態を自動収集。インフラ監視が得意
- **OTel 方式**: アプリが OTel で計装して Collector 経由でベンダーに送る。アプリ内部（トレース）が得意

今回は **両方**使います。インフラはエージェント、アプリは OTel。

### Kubernetes の Workload と Downward API

- **Deployment**: レプリカ数を保つ。Pod がどのノードに載るかは気にしない（stateless 向け）
- **DaemonSet**: **全ノードに 1 つずつ** Pod を置く。ノードエージェント（監視、ログ収集、CNI）向け
- **hostNetwork**: Pod がノードのネットワーク名前空間をそのまま使う。Pod IP = ノード IP になる。ノードのポートを直接 LISTEN するエージェントで使う
- **Downward API**: Pod 自身の情報（ノード IP、Pod 名など）を環境変数やファイルで取れる仕組み。`fieldRef: { fieldPath: status.hostIP }` で「自分が載っているノードの IP」が取れる

---

## 方針: 常用は GitOps、評価は「消せる形」で

- **常用 = New Relic**（GitOps 管理）
- **評価 = Instana**（GitOps 外・gitignore・撤去前提）。**通常のエージェントと Instana の AI 機能（Smart Alerts / 自動 RCA / AI Assistant）がどう連携するか**を検証したい
- アプリの計装は OTel / Micrometer 1 本。Collector が New Relic に送る（評価中は Instana にも fan-out）

```
アプリ (Micrometer/OTel, OTLP/HTTP :4318)
        │
        ▼
OTel Collector ──┬──▶ New Relic OTLP        （常用 / GitOps）
                 └──▶ Instana agent :4317   （評価中のみ overlay で追加）

ホスト/KVM : NR Infra agent + Instana host agent（Ansible）
k8s       : nri-bundle + instana-agent（helm）
```

評価用コードを本流に混ぜないため:

- Instana の `install.sh`（helm 直接）と host agent playbook は `.gitignore`
- OTel Collector の差し替えは別 ConfigMap（`platform/otel-collector/eval-instana/`、gitignore）
- 差し替え中だけ root(app-of-apps) の `selfHeal` を OFF、`platform-otel-collector` の auto-sync を停止

---

## New Relic（常用・GitOps）

### 3 つの Application

| Application | wave | 中身 |
|---|---|---|
| `platform-newrelic-license` | 0 | license の SealedSecret。cluster-wide scope で `newrelic` / `observability` 両 namespace で使う |
| `platform-newrelic` | 1 | **nri-bundle**（後述）|
| `platform-otel-collector` | 0 | OTel Collector（アプリ OTLP → New Relic OTLP）|

```bash
make seal-newrelic LICENSE='<New Relic ライセンスキー>'
# platform/{newrelic,otel-collector}/ に SealedSecret が生成される → commit/push
```

### nri-bundle とは

New Relic の Kubernetes 統合をまとめた Helm チャート（複数サブチャートの束）。

- **newrelic-infrastructure**: 各ノードの CPU/メモリ/ディスク + K8s の状態（Pod/Deployment 等）を収集する DaemonSet
- **nri-kube-events**: Kubernetes のイベント（`kubectl get events`）を送る
- **kube-state-metrics（KSM）**: K8s オブジェクトの状態をメトリクス化する定番 exporter
- **newrelic-logging**: Fluent Bit ベースの DaemonSet。全 Pod のログを転送
- **Pixie / prometheus-agent**: 非力クラスタなので**無効**にしている

KVM ホスト（物理 2 台）には Ansible で **New Relic Infra agent** を入れます。inventory に `[kvm_hosts]` グループ（host-a=local / host-b=SSH）を作り:

```bash
ansible-playbook playbooks/60-host-agents.yml --limit kvm-host-a -K -e newrelic_license_key='...'
ansible-playbook playbooks/60-host-agents.yml --limit kvm-host-b -K -e newrelic_license_key='...'
```

（`-K` は sudo パスワードのプロンプト。ホスト A と B で違うので `--limit` で分けて実行）

### ハマり①: nri-bundle V3 が `resources:` を受け付けない

`helm template` の段階でこける:

```
The chart cannot be rendered since the values listed below are not supported.
... 'resources' option ... not fully compatible with the v3 version.
Please use ksm.resources, controlPlane.resources, kubelet.resources.
```

`newrelic-infrastructure` サブチャートが **V3** になり、内部が「kubelet 監視」「KSM 監視」「control plane 監視」の 3 つの Deployment/DaemonSet に分かれました。リソース制限も**コンポーネント別**に指定します。

```yaml
newrelic-infrastructure:
  kubelet:      { resources: { limits: {memory: 300Mi}, requests: {cpu: 100m, memory: 150Mi} } }
  ksm:          { resources: { limits: {memory: 150Mi}, requests: {cpu: 50m,  memory: 64Mi} } }
  controlPlane: { resources: { limits: {memory: 150Mi}, requests: {cpu: 50m,  memory: 64Mi} } }
```

kubelet を監視する DaemonSet は control plane ノードにも載る必要があるので、taint を許容します（V3 の既定 toleration で概ね OK）。

### ハマり②: OTel Collector の 0.116.0 イメージが壊れている

Pod が起動直後にこける:

```
exec /otelcol-contrib: no such file or directory
```

これは通常「エントリポイントのバイナリが無い / アーキ不一致」を意味します。調べると、`otel/opentelemetry-collector-contrib` の **`linux/amd64` イメージが `0.115` / `0.116` で壊れて**いました（同じ Dockerfile 記述で `0.114` と `0.119` は正常起動）。

タグを二分探索して **`0.128.0`** に固定して回避。「特定バージョンのイメージが壊れている」は稀ですが起きるので、`--version` だけ叩く使い捨て Pod で切り分けるのが早いです。

```bash
kubectl -n observability run t --rm -it --image=otel/opentelemetry-collector-contrib:0.119.0 -- --version
```

### ハマり③: `telemetry.metrics.address` が廃止されていた

0.128 に上げたら別のエラー:

```
error decoding 'service.telemetry.metrics': '' has invalid keys: address
```

Collector 0.123+ で **Collector 自身の内部メトリクス公開設定**の書き方が変わりました。旧 `address: 0.0.0.0:8888` は廃止、`readers:` 形式に:

```yaml
service:
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: 0.0.0.0
                port: 8888
```

### ハマり④: `platform-newrelic` が常時 OutOfSync 表示

`newrelic-logging` の DaemonSet だけ、Argo CD の CLI で `argocd app diff` すると**差分ゼロ**なのに、Application は `OutOfSync` 表示のまま。

> **Server-Side Apply（SSA）と managed fields**
> Kubernetes には「どのフィールドを誰（どのコントローラ）が管理しているか」を記録する **managedFields** がある。SSA では apply する側が「自分はこのフィールド群のオーナー」と宣言する。
> API server は apply されなかったフィールドに**既定値を埋める**（`terminationMessagePath` や `revisionHistoryLimit: 10` など）。それを **kube-controller-manager** が「Update」操作で所有する。
> Helm チャートが `initContainers: null` のような**明示的 null** を吐くと、この「チャートの意図」と「API server の defaulting」と「SSA の正規化」の 3 者がわずかにズレ、Argo の内部比較だけが `OutOfSync` を出す（実際の差分は無い）。

機能影響が無いので**許容**しています。`ignoreDifferences` で `.spec.template` を無視すると「将来チャートの値を変えても反映されない」副作用があるので、あえて付けず、design ドキュメントに「既知の軽微な差分」と明記しました。

---

## アプリ側（Spring Boot）の計装

Spring Boot は 2 つの経路でテレメトリを出します。

- **メトリクス**: **Micrometer**（Spring の計装ファサード）の **OTLP registry** が定期的に送る
- **トレース**: **Micrometer Tracing** + OTel ブリッジ + **Boot の OTLP tracing exporter**

### ハマり⑤: アプリが OTLP を gRPC ポートに送っていた（最重要）

アプリのログに毎分:

```
Failed to publish metrics ... url=http://otel-collector:4317/v1/metrics ... HTTP status code -1
```

原因: Micrometer の OTLP registry も Boot の OTLP tracing exporter も、実装は **OTLP/HTTP**（protobuf over HTTP）です。つまり送り先は **`:4318`**。

`:4317` は **gRPC 版**のポートで、そこに HTTP のリクエストを投げると当然プロトコル不一致（`HTTP status code -1` = 応答すら得られない）。

環境変数 1 つを両方で使い回していて、それが `:4317` を指していたのが元凶。分けて `:4318` に統一:

```yaml
# application.yml
management:
  otlp:
    metrics:
      export:
        url: ${OTEL_OTLP_HTTP_ENDPOINT}/v1/metrics
    tracing:
      endpoint:  ${OTEL_OTLP_HTTP_ENDPOINT}/v1/traces
```

`OTEL_OTLP_HTTP_ENDPOINT = http://otel-collector.observability.svc.cluster.local:4318`。

> 教訓: OTLP を触るときは「gRPC(4317) か HTTP(4318) か」を最初に確定する。SDK やライブラリによって既定が違う。Collector 側は両方 LISTEN させておくと切り分けが楽。

### 確認（Collector の内部メトリクス）

Collector 自身が `:8888` で「受け取ったスパン数 / 送ったスパン数 / 失敗数」を出しています。

```bash
$ kubectl -n observability port-forward deploy/otel-collector 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_(receiver_accepted|exporter_sent|exporter_send_failed)_(spans|metric_points)_total'
otelcol_receiver_accepted_spans_total{...}                       60
otelcol_exporter_sent_spans_total{exporter="otlp/newrelic"}      60
otelcol_exporter_sent_spans_total{exporter="otlp/instana"}       60
otelcol_exporter_send_failed_spans_total{...}                     0
```

「receiver_accepted」と「exporter_sent」が同じで「send_failed」が 0 なら、パイプラインは健全です。

---

## Instana（評価・GitOps 外）

### k8s エージェント（helm 直接）

Instana の Kubernetes 統合は **instana-agent**（各ノードの DaemonSet）+ **k8sensor**（クラスタ全体の状態を見る Deployment）。GitOps に載せず helm で直接入れます。

```bash
cd platform/eval/instana
export INSTANA_AGENT_KEY='...' INSTANA_ENDPOINT_HOST='ingress-<色>-saas.instana.io'
./install.sh install
```

> **agent key / endpoint host の入手**
> Instana のウィザードは直接キーを見せてくれないことがある。**Settings → Agents → Agent Keys**（エージェント・キー）タブに直接コピーボタンがある。または「Kubernetes / Helm」を選ぶと生成される `helm install` コマンドの `--set agent.key=` / `--set agent.endpointHost=` が値。

### ハマり⑥: agent が control plane に載らない

instana-agent の DaemonSet が control plane の taint（`node-role.kubernetes.io/control-plane:NoSchedule`）を許容しておらず、cp ノードに Pod が来ませんでした。

```yaml
agent:
  pod:
    tolerations:
      - operator: Exists       # あらゆる taint を許容
```

### ハマり⑦: Instana agent への OTLP がクロスホストで届かない

これは第1回のネットワーク制約が効いてきた例です。

- Instana agent は **hostNetwork** の DaemonSet。**各ノードの実 IP** で `:4317`（OTLP gRPC）を LISTEN する
- OTel Collector が `instana-agent` **Service** 宛に送ると、**kube-proxy** が Service の仮想 IP を実エンドポイント（＝どこかのノード IP）に **DNAT** する

> **kube-proxy と Service の DNAT**
> `Service` の ClusterIP はカーネルには存在しない仮想 IP。kube-proxy が iptables/ipvs ルールを入れ、ClusterIP 宛パケットの**宛先を、生きている Pod（エンドポイント）のどれかにランダムで書き換える（DNAT）**ことで負荷分散を実現する。

Collector は worker-2 上の Pod（`10.244.2.x`）。DNAT 先が worker-2 のノード IP（`192.168.1.22`）なら届くが、cp や worker-1 のノード IP（`192.168.122.x`）に振られると、**Pod ネットワークから他ホストの libvirt サブネットへは経路が無い**（第1回で「LAN 向けだけ NAT 無効化」した＝逆方向の経路は張っていない）ので `connection refused`。

→ Collector に **Downward API** で「自分のノード IP」を渡し、Service を経由せず**同じノードの agent へ直送**:

```yaml
env:
  - name: NODE_IP
    valueFrom: { fieldRef: { fieldPath: status.hostIP } }
# exporter:
#   otlp/instana:
#     endpoint: ${env:NODE_IP}:4317
#     tls: { insecure: true }
```

Collector と agent は「全ノードに 1 つずつ」いるので、必ず同居しています。

### ハマり⑧: Instana セットアップスクリプトがハングする

ホスト B（Instana 未導入）は `setup.instana.io/agent` のシェルスクリプトで入れます。Ansible の `shell` モジュールから叩くと固まりました。

- **`set -o pipefail` が `/bin/sh`（dash）で動かない**
  Ubuntu の `/bin/sh` は dash で、`pipefail` は bash 拡張。`shell` モジュールは既定 `/bin/sh`。
  → `args: { executable: /bin/bash }`
- **`Do you want to continue? [y/N]` の対話プロンプトで stdin 待ち**
  非対話コンテキストなので永遠に待つ。
  → スクリプトに `-y`（`--assume-yes`）を付与

### ハマり⑨: `apt-get update` の巻き添え

ホスト A で New Relic playbook を流したら:

```
Failed to update apt cache: unknown reason
```

Ansible の `apt_repository` は追加後に**フルの `apt-get update`** を走らせます。ホスト A には元々 rocm など**別のリポジトリ**があり、そこが署名エラーで `apt-get update` 全体を非 0 にしていたため、New Relic とは無関係に失敗していました。

対策:
- `newrelic-infra` が**導入済みなら** repo 操作を丸ごとスキップし、config だけ収束
- 新規導入時も **New Relic のリポジトリだけ**を対象に update

```bash
apt-get update \
  -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/newrelic-infra.list \
  -o Dir::Etc::sourceparts=/dev/null \
  -o APT::Get::List-Cleanup=0
```

`Dir::Etc::sourcelist` で単一ファイルを指定、`sourceparts=/dev/null` で `sources.list.d/` の他ファイルを無視。

### ハマり⑩: apt 鍵が armored のまま

```
W: GPG error: ... NO_PUBKEY BB29EE038ECCE87C
```

apt の `signed-by=/etc/apt/keyrings/xxx.gpg` は、鍵ファイルが **ASCII-armored**（`-----BEGIN PGP PUBLIC KEY BLOCK-----` のテキスト形式）だと環境によって読めません。**dearmor**（バイナリ化）してから配置:

```bash
curl -fsSL https://download.newrelic.com/.../newrelic-infra.gpg \
  | gpg --dearmor --yes -o /etc/apt/keyrings/newrelic-infra.gpg
```

---

## Instana の撤去（評価が終わったら）

評価コードは全部 gitignore してあるので、撤去は次の順で戻すだけです。

```bash
# 1) root と子 App の同期を通常に戻す
kubectl -n argocd patch app platform-otel-collector --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl -n argocd patch app root --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl -n argocd annotate app root argocd.argoproj.io/refresh=hard --overwrite
#   → root の selfHeal が Collector の ConfigMap を git 版（New Relic のみ）に復元

# 2) エージェントを撤去
helm -n instana-agent uninstall instana-agent
ansible-playbook playbooks/local/60b-instana-host-agent.yml -e instana_state=absent
```

GitOps 管理下（New Relic）には一切傷が残りません。「評価は消せる形で入れる」という最初の方針が、ここで効きます。

### 何が検証できたか

- **エージェント方式**は「入れるだけで」ホスト / K8s / DB のトポロジと基本メトリクスが自動で埋まる。導入の速さはエージェントの強み
- **OTel 方式**でアプリの分散トレースを流すと、エージェントが把握しているインフラのエンティティと**自動で紐付く**（同じホスト / Pod として名寄せされる）
- その上で **AI 機能（異常検知 / RCA）** は、エージェントが集めた「正常時のベースライン」と「トポロジ」を前提に効く。つまり「エージェントの網羅性」が AI の精度を規定する、という関係が見えた

---

## 連載まとめ

3 回を通してやったこと:

- 物理 2 台・3 ノードのクラスタを、既存クラスタを止めずに拡張（NAT 部分無効化 + macvtap + Flannel クロスサブネット）
- クラスタ構築後は Argo CD がすべて（プラットフォーム / アプリ / 監視）を GitOps で管理
- Kong + Keycloak + Cloudflare Tunnel でルーター開放なしの本番公開
- New Relic を常用、Instana は「消せる形」で評価導入

「1 人で運用」を最優先にすると、**再現可能性**（IaC + GitOps）と**片付けやすさ**（評価コードを混ぜない）が効いてきます。ハマりの多くは「バージョン差でオプションが消えた / 形式が変わった」「ネットワークの前提が層をまたいで効いてくる」の 2 パターンでした。

### リポジトリ

- インフラ: https://github.com/tukapai/homelab-k8s
- 設計判断は各リポの `docs/adr/`、運用手順は `docs/runbooks/`
