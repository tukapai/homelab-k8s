# Qiita 連載: 自宅の物理2台でKubernetesをGitOpsまで

<!--
Qiita 投稿用ドラフト（連載・全3回）。本体は docs/qiita/ にある。
共通タグ: Kubernetes
リポジトリ: https://github.com/tukapai/homelab-k8s
-->

自宅の Ubuntu マシン 2 台で、**1 人で無理なく運用できる** Kubernetes 基盤を
クラスタ構築から本番公開・監視まで組み上げた記録。各回とも「ハマったところ」中心。

| 回 | タイトル | 内容 | ドラフト |
|---|---|---|---|
| 第1回 | KVM + kubeadm で3ノードクラスタを組む | KVM / cloud-init / kubeadm、2台目の物理ホストを worker に（NAT 部分無効化 + macvtap + Flannel クロスサブネット）| [qiita/01-cluster.md](qiita/01-cluster.md) |
| 第2回 | Argo CD + Kong + Keycloak + Cloudflare Tunnel で本番公開 | GitOps（app-of-apps / SealedSecrets）、Kong Ingress、Keycloak、Cloudflare Tunnel、実アプリのデプロイ | [qiita/02-gitops-publish.md](qiita/02-gitops-publish.md) |
| 第3回 | New Relic + Instana で監視（評価ツールを「消せる形」で入れる）| OTel Collector fan-out、nri-bundle、Instana 評価導入と撤去 | [qiita/03-observability.md](qiita/03-observability.md) |

## タグ候補

- 第1回: `Kubernetes` `kubeadm` `KVM` `libvirt` `Ansible`
- 第2回: `Kubernetes` `ArgoCD` `Kong` `Keycloak` `Cloudflare`
- 第3回: `Kubernetes` `OpenTelemetry` `NewRelic` `Instana` `ArgoCD`

## 投稿前チェック

- [ ] 各回の冒頭 / 末尾の「前後の回へのリンク」を Qiita の実 URL に差し替え
- [ ] コードブロックの言語指定
- [ ] スクリーンショット（Argo CD / Headlamp / New Relic / Instana のダッシュボード）を追加
- [ ] 環境固有値（ドメイン・IP）は公開済みのためそのまま記載
