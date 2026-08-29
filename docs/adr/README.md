# Architecture Decision Records

`homelab-k8s` 上でアプリケーションと周辺ミドルウェアを運用するための設計判断の記録。

前提（全 ADR 共通の制約）:

- **運用者は 1人**（単独メンテナ）。運用コストの低さを最優先する。
- 物理ホストは当面 **1 台**。真の HA は不可能 → 「バックアップ + IaC で高速再構築」で可用性を担保する。
- 2 台目の**物理マシン**を後日追加し、そこに worker を載せる予定。
- アプリは **インターネット公開**する Web API + PostgreSQL + Redis（cache / queue）。
- クラスタは kubeadm v1.31 / containerd / Flannel。control-plane 1 + worker(VM) 1。

| ADR | タイトル | Status |
|---|---|---|
| [0001](0001-gitops-argocd.md) | デプロイは GitOps（Argo CD）| Accepted |
| [0002](0002-ingress-cloudflare-tunnel.md) | インターネット公開は Cloudflare Tunnel | Accepted |
| [0003](0003-single-host-interim-scaling.md) | 当面は単一物理ホスト、後日 物理ノード追加、暫定は cp の taint 解除 | Accepted |
| [0004](0004-stateful-middleware.md) | PostgreSQL は CloudNativePG、queue/cache は Redis | Accepted |
| [0005](0005-lean-platform.md) | MetalLB / cert-manager は当面入れない | Accepted |
| [0006](0006-secrets-management.md) | Secret 管理方式 | Proposed |
| [0007](0007-repository-topology.md) | リポジトリ構成（infra / gitops / アプリ を分割）| Accepted |

## フォーマット

各 ADR は Context / Decision / Options Considered / Trade-off Analysis /
Consequences / Action Items の順。Status は
Proposed → Accepted → (Deprecated | Superseded by ADR-XXXX)。
