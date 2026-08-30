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

第2回で実アプリが `nekonekoinsurance.com` で公開できました。この回では監視を入れます。

---

## 方針: 常用は GitOps、評価は「消せる形」で

- **常用 = New Relic**（GitOps 管理）
- **評価 = Instana**（GitOps 外・gitignore・撤去前提）。エージェントと Instana の AI 機能（Smart Alerts / 自動 RCA / AI Assistant）の連携を検証したい
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

評価用コードを本流に混ぜないため:

- Instana の `install.sh`（helm 直接）と host agent playbook は `.gitignore`
- OTel Collector の差し替えは別 ConfigMap（`platform/otel-collector/eval-instana/`、gitignore）
- 差し替え中だけ root(app-of-apps) の `selfHeal` を OFF にして、`platform-otel-collector` の auto-sync を止める

---

## New Relic（常用・GitOps）

3 つの Application を足します。

| Application | wave | 中身 |
|---|---|---|
| `platform-newrelic-license` | 0 | license の SealedSecret（`newrelic` ns。cluster-wide scope で `observability` ns の Collector とも共用）|
| `platform-newrelic` | 1 | nri-bundle 5.0.106（infra / nri-kubernetes / KSM / logs）|
| `platform-otel-collector` | 0 | OTel Collector（アプリ OTLP → New Relic OTLP）|

```bash
make seal-newrelic LICENSE='<New Relic ライセンスキー>'
# platform/{newrelic,otel-collector}/ に SealedSecret が生成される → commit/push
```

KVM ホスト（物理 2 台）には Ansible で Infra agent を入れます。inventory に `[kvm_hosts]` グループ（host-a=local / host-b=SSH）を作り:

```bash
ansible-playbook playbooks/60-host-agents.yml --limit kvm-host-a -K -e newrelic_license_key='...'
ansible-playbook playbooks/60-host-agents.yml --limit kvm-host-b -K -e newrelic_license_key='...'
```

### ハマり①: nri-bundle V3 が `resources:` を受け付けない

```
The chart cannot be rendered since ... 'resources' option ... not fully compatible with the v3 version.
Please use ksm.resources, controlPlane.resources, kubelet.resources.
```

`newrelic-infrastructure` が V3 になり、`resources` は component 別に指定する形式に変わっていました。

```yaml
newrelic-infrastructure:
  kubelet:      { resources: {...} }
  ksm:          { resources: {...} }
  controlPlane: { resources: {...} }
```

### ハマり②: OTel Collector の 0.116.0 イメージが壊れている

```
exec /otelcol-contrib: no such file or directory
```

`otel/opentelemetry-collector-contrib` の `linux/amd64` イメージが `0.115` / `0.116` で壊れていました（`0.114` と `0.119` は OK）。バージョンを bisect して `0.128.0` に固定。

### ハマり③: `telemetry.metrics.address` が廃止されていた

Collector 0.123+ で `service.telemetry.metrics.address` が削除。`readers:` 形式に書き換え。

```yaml
service:
  telemetry:
    metrics:
      readers:
        - pull: { exporter: { prometheus: { host: 0.0.0.0, port: 8888 } } }
```

### ハマり④: `platform-newrelic` が常時 OutOfSync 表示

`newrelic-logging` DaemonSet が、`argocd app diff` はクリーンなのに Application は OutOfSync。チャートが吐く明示的な `null`（`initContainers: null` 等）と API server の defaulting、SSA の正規化の差が原因。機能影響は無いので許容しています（`ignoreDifferences` で消そうとすると将来の値変更まで無視してしまうので、あえて付けない）。

---

## アプリ側（Spring Boot）の計装

### ハマり⑤: アプリが OTLP を gRPC ポートに送っていた

```
Failed to publish metrics ... url=http://otel-collector:4317/v1/metrics ... HTTP status code -1
```

Micrometer の OTLP registry も Spring Boot の tracing も **OTLP/HTTP エクスポータ**なので、送り先は **`:4318`**（gRPC の `:4317` ではない）。

```yaml
management:
  otlp:
    metrics: { export: { url: ${OTEL_OTLP_HTTP_ENDPOINT}/v1/metrics } }
    tracing: { endpoint:  ${OTEL_OTLP_HTTP_ENDPOINT}/v1/traces }
```

`OTEL_OTLP_HTTP_ENDPOINT = http://otel-collector.observability.svc.cluster.local:4318` に統一。

### 確認（Collector の内部メトリクス）

```bash
$ kubectl -n observability port-forward deploy/otel-collector 8888:8888 &
$ curl -s localhost:8888/metrics | grep -E 'otelcol_exporter_(sent|send_failed)_(spans|metric_points)_total'
otelcol_exporter_sent_metric_points_total{exporter="otlp/newrelic"} 409
otelcol_exporter_sent_metric_points_total{exporter="otlp/instana"}  409
otelcol_exporter_send_failed_metric_points_total{...} 0
```

---

## Instana（評価・GitOps 外）

### k8s エージェント（helm 直接）

```bash
cd platform/eval/instana
export INSTANA_AGENT_KEY='...' INSTANA_ENDPOINT_HOST='ingress-<色>-saas.instana.io'
./install.sh install
```

### ハマり⑥: agent が control-plane に載らない

instana-agent の DaemonSet が cp の taint を許容していませんでした。

```yaml
agent:
  pod:
    tolerations:
      - operator: Exists
```

### ハマり⑦: Instana agent への OTLP がクロスホストで届かない

Instana agent（hostNetwork DaemonSet）は各ノード IP で `:4317` を LISTEN しますが、Service 経由だと kube-proxy が**他ホストのノード IP**に振り分けることがあり、第1回の制約（Pod → 他ホストの node IP は経路なし）で `connection refused`。

→ OTel Collector に downward API で `NODE_IP` を渡し、endpoint を `${env:NODE_IP}:4317` にして**自ノードの agent へ直送**。

```yaml
env:
  - name: NODE_IP
    valueFrom: { fieldRef: { fieldPath: status.hostIP } }
# exporter:
#   otlp/instana: { endpoint: ${env:NODE_IP}:4317, tls: { insecure: true } }
```

### ハマり⑧: Instana セットアップスクリプトがハングする

Ansible の `shell` から `setup.instana.io/agent` のスクリプトを叩くと固まる。

- `set -o pipefail` が `/bin/sh`（dash）で動かない → `args: { executable: /bin/bash }`
- `Do you want to continue? [y/N]` の対話プロンプトで無限待ち → スクリプトに `-y` を付与

### ハマり⑨: `apt-get update` の巻き添え

ホスト A で New Relic playbook を流したら `Failed to update apt cache: unknown reason`。原因はホストに元々あった**別のリポジトリ**（rocm 等）が壊れていて `apt-get update` 全体が非 0 を返していたため。

→ 導入済みなら repo 操作をスキップ。新規導入時も **New Relic のリポジトリだけ**を対象に update。

```bash
apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/newrelic-infra.list \
               -o Dir::Etc::sourceparts=/dev/null
```

### ハマり⑩: apt 鍵が armored のまま

`signed-by=` で参照する鍵が ASCII-armored のままだと `NO_PUBKEY`。`gpg --dearmor` してから配置。

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

GitOps 管理下（New Relic）には一切傷が残りません。

---

## 連載まとめ

3 回を通してやったこと:

- 物理 2 台・3 ノードのクラスタを、既存クラスタを止めずに拡張（NAT 部分無効化 + macvtap + Flannel クロスサブネット）
- クラスタ構築後は Argo CD がすべて（プラットフォーム / アプリ / 監視）を GitOps で管理
- Kong + Keycloak + Cloudflare Tunnel でルーター開放なしの本番公開
- New Relic を常用、Instana は「消せる形」で評価導入

「1 人で運用」を最優先にすると、**再現可能性**（IaC + GitOps）と**片付けやすさ**（評価コードを混ぜない）が効いてきます。

### リポジトリ

- インフラ: https://github.com/tukapai/homelab-k8s
- 設計判断は各リポの `docs/adr/`、運用手順は `docs/runbooks/`
