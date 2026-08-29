# Runbook: Instana 評価（セットアップ / 撤去）

ADR-0008。Instana を**評価目的・時間箱**で導入する。New Relic は常用として
並行稼働させたまま。

## 評価の期限

- 開始日: __________  終了日: __________（例: 4 週間）
- 終了日をカレンダーに登録すること。過ぎたら §撤去 を実行。

## 前提

- Instana テナント（SaaS）とその **agent key** / **download key** / **endpoint host**
  （例 `ingress-red-saas.instana.io:443`）
- Argo CD / sealed-secrets 稼働済み
- `kubeseal` が手元にある

## セットアップ

### 1. k8s エージェント（Argo CD 経由）

```bash
cd homelab-gitops
make seal-instana KEY='<agent key>' DOWNLOAD_KEY='<download key>'
# platform/eval/instana/kustomization.yaml の resources のコメントを外す
$EDITOR platform/eval/instana/values.yaml   # agent.endpointHost をテナントに合わせる
$EDITOR bootstrap/children/platform-eval-instana*.yaml  # repoURL の CHANGEME を置換
git add -A && git commit -m "instana: 評価開始" && git push
```

Argo CD で `platform-eval-instana-key` → `platform-eval-instana` が Synced/Healthy に
なるのを確認:

```bash
argocd app list | grep instana
kubectl -n instana-agent get pods         # DaemonSet が各ノードで Running
kubectl -n instana-agent logs ds/instana-agent | tail
```

### 2. ホストエージェント（KVM ホスト）

```bash
cd homelab-k8s/ansible
ansible-playbook playbooks/60-host-agents.yml \
  -e instana_enabled=true \
  -e instana_agent_key=XXX -e instana_download_key=YYY \
  -e instana_endpoint_host=ingress-red-saas.instana.io \
  -e newrelic_license_key=ZZZ            # NR は常用なので毎回必要
```

`~/instana-agent-dynamic.amd64.deb` があればそれを使い、無ければ setup スクリプト。

```bash
sudo systemctl status instana-agent
sudo tail -f /opt/instana/agent/data/log/agent.log
```

### 3. アプリのトレース（OTel 経由）

アプリは OTel SDK で `otel-collector.observability.svc:4317` に送っており、
Collector が Instana agent（`instana-agent.instana-agent.svc:4317`）へ fan-out する。
**アプリ側の追加設定は不要**（`app-template` の chart が OTLP env を配線済み）。

Instana UI の Applications / Traces にサービスが出るか確認。

## 評価チェックリスト

- [ ] Infrastructure: KVM ホスト・VM・ノードのメトリクスが見える
- [ ] Kubernetes: クラスタ / Namespace / Workload / Pod のトポロジ
- [ ] PostgreSQL センサー（接続数・スロークエリ・レプリケーション）
- [ ] Redis センサー（ヒット率・メモリ・コマンド）
- [ ] ingress-nginx センサー
- [ ] Application: サービスマップ / エンドポイント / トレース（OTel 由来）
- [ ] アラート / スマートアラートの使用感
- [ ] New Relic と比べた: 設定量 / 自動ディスカバリの精度 / ノイズ / コスト感
- [ ] クラスタリソース影響（`kubectl top nodes` を導入前後で比較）

所感メモ: ______________________________________________

## 撤去

### 1. k8s エージェント

```bash
cd homelab-gitops
git rm bootstrap/children/platform-eval-instana.yaml \
       bootstrap/children/platform-eval-instana-key.yaml
git rm -r platform/eval
git commit -m "instana: 評価終了・撤去" && git push
```

Argo CD が prune（`automated.prune: true`）。残留確認:

```bash
argocd app list | grep instana        # 消えている
kubectl get ns instana-agent          # 手動削除が必要な場合あり
kubectl delete ns instana-agent
```

### 2. ホストエージェント

```bash
sudo systemctl disable --now instana-agent
sudo apt-get remove --purge -y instana-agent
sudo rm -rf /opt/instana
```

（New Relic infra agent はそのまま。`60-host-agents.yml` を
`-e instana_enabled=false` で再実行しても OK）

### 3. OTel Collector から Instana exporter を外す

`homelab-gitops/platform/otel-collector/configmap.yaml`:

- `exporters.otlp/instana` を削除
- `service.pipelines.{traces,metrics}.exporters` から `otlp/instana` を除去
- Deployment の `checksum/config` annotation を変更して再起動を促す

```bash
git commit -am "otel: instana exporter 撤去" && git push
```

### 4. Instana テナント側

不要なら Instana 側でホスト / エージェントを削除、サブスクリプション整理。

## 完了条件

- [ ] `kubectl get ns instana-agent` → NotFound
- [ ] KVM ホストに instana-agent プロセスなし
- [ ] OTel Collector の config に instana への参照なし
- [ ] New Relic は引き続き Healthy
- [ ] 評価所感を design.md か別メモに記録
