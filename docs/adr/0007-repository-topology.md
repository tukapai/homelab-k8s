# ADR-0007: リポジトリ構成（infra / gitops / アプリ を分割）

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

ADR-0001 で GitOps（Argo CD）を採用した。マニフェストと Argo CD の
`Application` をどのリポジトリに置くかを決める必要がある。

判断に影響する事情:

- アプリは今後増える。全部を `homelab-k8s` に入れると巨大モノレポになる懸念。
- アプリは**ローカルでテスト**したい（`homelab-k8s` を clone せずに、
  アプリ単体で開発ループを回したい）。
- `homelab-k8s` は公開（MIT）。アプリには非公開にしたい情報
  （ビジネスロジック、内部 API 契約、顧客名を含む設定値など）が出うる。
  → 公開インフラリポに混ぜるとリポジトリの「文脈」が曖昧になる。
- 将来、資産の一部を AWS 等の別プラットフォームへ移す可能性がある。
- 運用者は 1人。リポを増やしすぎると CI 設定の分散などの負担が出る。

（Secret は ADR-0006 の仕組みで扱い、**どのリポにも平文で置かない**ことは前提）

## Decision

**3 層に分割する。**

| リポジトリ | 可視性 | 内容 |
|---|---|---|
| `homelab-k8s` | public | インフラのみ（KVM/kubeadm/Ansible/scripts/docs）。**現状のまま** |
| `homelab-gitops` | private | Argo CD が同期する唯一の「あるべき状態」。`bootstrap/`（app-of-apps root + Application 定義）、`platform/`、`apps/<app>/overlays/{dev,prod}/` |
| `app-<name>` | private | アプリごとに 1 つ。`src/`、`Dockerfile`、`deploy/base/`（環境非依存のベースマニフェスト or Helm チャート）、ローカルテスト（compose / Tiltfile）、CI |

サブ決定:

- **ベースマニフェストはアプリリポ、環境固有の overlay は gitops リポ**に置く。
  アプリリポには homelab 前提（`local-path` StorageClass、
  `nodeSelector: k8s-worker-1`、Cloudflare Tunnel の annotation、自宅ホスト名）
  を**入れない**。それらは gitops の overlay に隔離する。
- Argo CD の `Application` 定義は `homelab-gitops/bootstrap/` に集約。
  アプリが増えたら **ApplicationSet + Git generator** で `apps/*` を自動検出。
- CI（GitHub Actions）はアプリリポ側に置き、
  「test → build → `ghcr.io` push → `homelab-gitops` の image タグ更新コミット」
  まで行う。クラスタ適用は Argo CD。
- Argo CD への private リポ登録は **GitHub App 1 つ**（複数リポにまたがれる）
  を基本とし、その資格情報は `homelab-gitops` に Sealed Secret で置く。

## Options Considered

### Option A: 3 層分割（infra / gitops / per-app）（採用）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med（リポ 3 種、Argo CD にリポ資格情報）|
| モノレポ肥大 | 回避（コードは分散、gitops は YAML のみで小さい）|
| ローカルテスト | ◎ アプリリポ単体で完結 |
| 可視性の分離 | ◎ infra=public、アプリ=private を独立に設定 |
| 移植性 | ◎ アプリリポは環境非依存 |

**Pros:** 各リポの責務が明確。アプリの追加が gitops に線形にしか効かない。
アプリ単体で clone/テスト/CI。AWS 移行はアプリリポ不変で overlay 差し替え。
**Cons:** リポが増え CI 設定が分散（reusable workflow / テンプレートリポで緩和）。
コード＋マニフェスト両方要る変更は 2 PR。Argo CD にリポ資格情報が要る。

### Option B: 2 リポ（infra / アプリは code+deploy 同居、Application は infra 側）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low–Med |
| モノレポ肥大 | 回避 |
| ローカルテスト | ◎ |
| 可視性の分離 | ○ |
| 移植性 | △ アプリリポに deploy 設定が混在 |

**Pros:** リポ数が少ない。1 アプリ = 1 リポで完結感がある。
**Cons:** アプリリポに環境固有マニフェストが混ざり、移植時に整理が要る。
Argo CD が各アプリリポの `deploy/` パスを直接見るため、
「全体のあるべき状態」を 1 か所で俯瞰できない。

### Option C: 単一モノレポ（すべて `homelab-k8s`）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（最初だけ）|
| モノレポ肥大 | ×（まさに懸念どおり）|
| 可視性の分離 | ×（public に非公開情報を混ぜられない）|
| 移植性 | × |

**Pros:** リポ 1 つ、最初は楽。
**Cons:** 懸念事項すべてに該当。公開リポにアプリの非公開文脈を入れられず、
アプリコードの変更で image タグが動いて履歴がノイズだらけになる
（Argo CD 公式が「コードと manifest を同居させるな」と言う理由）。

### Option D: 2 リポ（infra+gitops 同居 / アプリは別）

**Pros:** A よりリポ 1 つ少ない。
**Cons:** `homelab-k8s`（public）に gitops（private にしたい Application 定義や
overlay の設定値）が混ざる。可視性の分離ができない。

## Trade-off Analysis

懸念は「モノレポ肥大」「public への非公開情報混在」「ローカルテスト」
「移植性」。C と D は可視性分離で失格。B は概ね良いが、アプリリポに
環境固有設定が残り移植性と俯瞰性で A に劣る。

A の追加コスト（リポ数、CI 分散、リポ資格情報）は、reusable workflow と
GitHub App で実務上吸収できる範囲。1人でも「アプリを足す」操作が
`app-<name>` 作成 + `homelab-gitops/apps/<name>/overlays` 追加に収まり、
スケールする。→ **A**。

## Consequences

**楽になること**
- `homelab-gitops` は YAML のみで小さく保たれる（アプリが増えても）。
- アプリは単体で clone・ローカルテスト・CI が回る。
- `homelab-k8s` は public のまま、アプリの非公開文脈は private リポに閉じる。
- AWS 等への移行は「別 gitops/overlay を用意 + 同じイメージ」。アプリリポ不変。

**難しくなること / 新たな負担**
- リポジトリが 1 + N 個に増える。CI 設定は GitHub の reusable workflow か
  テンプレートリポで共通化する規律が要る。
- コードとマニフェスト双方に触る変更は 2 リポ・2 PR にまたがる。
- Argo CD に private リポの資格情報（GitHub App 推奨）を設定・維持する。
- 「どの gitops commit がどのアプリ commit か」は **image タグ = git sha**
  で対応付ける運用を徹底する。

**あとで見直す**
- アプリが 1〜2 個で当分増えないと分かったら B に寄せて簡素化してもよい。
- チームが増えたら per-app リポの権限分離がむしろ効いてくる（A のまま）。
- gitops リポが大きくなったら環境ごと（`gitops-prod` / `gitops-dev`）に分割。

## Action Items

1. [ ] `homelab-gitops`（private）を作成。`bootstrap/ platform/ apps/` を用意
2. [ ] `homelab-k8s` の README / ADR-0001 から `homelab-gitops` へリンク
3. [ ] アプリの雛形リポ（`app-template`）を作成
       （`deploy/base/`、`compose.yaml`、`.github/workflows/` 込み）
4. [ ] GitHub App を作成し Argo CD にリポ資格情報として登録、Sealed Secret 化
5. [ ] reusable workflow（`build-and-push`, `bump-gitops-tag`）を
       専用リポか `homelab-gitops/.github/` に定義
6. [ ] 最初のアプリで A の流れ（push → build → タグ更新 → Argo 同期）を通す
