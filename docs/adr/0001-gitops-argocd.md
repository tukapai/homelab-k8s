# ADR-0001: デプロイは GitOps（Argo CD）

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

`homelab-k8s` クラスタにアプリと周辺ミドルウェアを載せていくにあたり、
「何を・どのバージョンで・どのクラスタに」当てるかを管理する仕組みが要る。

- 運用者は 1人。手順書や手作業に依存すると必ず破綻する。
- アプリは今後増える（API、worker、DB、Redis、将来の追加コンポーネント）。
- 変更履歴・ロールバック・現状把握が「見れば分かる」状態であってほしい。
- クラスタは非力（当面 cp 8GB + worker 4GB、ADR-0003）。導入コンポーネントの
  リソース消費も判断材料になる。
- GUI でクラスタを見たいという要望が別途あった。

## Decision

**GitOps を採用し、コントローラは Argo CD**。マニフェストは Git に置き
（Kustomize でパッケージング）、`app-of-apps` パターンで
`platform/` と `apps/` を 1 つの root Application から束ねる。

デプロイ = `git push`。CI（GitHub Actions）は「テスト → イメージビルド →
`ghcr.io` へ push → マニフェストの image タグ更新コミット」までに限定し、
クラスタへの適用は Argo CD に任せる（CI に kubeconfig を持たせない）。

## Options Considered

### Option A: Argo CD

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med（初期セットアップと repo 構成の学習）|
| Cost | Med（app-controller / repo-server / server / redis / 約 0.5–1GB）|
| Scalability | 十分（単一クラスタ・数十 App 規模なら余裕）|
| Team familiarity | 中（情報が豊富、UI があり学習しやすい）|

**Pros:** Web UI（差分・同期状態・履歴・手動同期）、`app-of-apps`、
SSO なしでも使える、drift 検知、ロールバックが revert。
**Cons:** Flux より重い、CRD と概念（Application/Project）を覚える必要。

### Option B: Flux

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med |
| Cost | Low（コントローラ群が軽量、約 0.2–0.4GB）|
| Scalability | 十分 |
| Team familiarity | 低め（UI がなく CLI/manifest 中心）|

**Pros:** 軽量、Kustomize/Helm ネイティブ、GitOps Toolkit がシンプル。
**Cons:** 標準では UI なし（別途 Weave GitOps 等）。1人だと状態把握が
コマンド頼みになりがち。

### Option C: 手元から `kubectl` / `helm` を直接実行

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（最初だけ）|
| Cost | ゼロ |
| Scalability | 悪い |

**Pros:** 追加コンポーネント不要、すぐ始められる。
**Cons:** 適用履歴が残らない、drift 検知なし、複数環境で破綻、
「手元のマシンにしか真実がない」状態。あとで GitOps へ移行するのが面倒。

### Option D: CI がクラスタへ push（GitHub Actions で `kubectl apply`）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low–Med |
| Cost | ゼロ（クラスタ側）|
| Scalability | 中 |

**Pros:** 追加コンポーネント不要、パイプラインが直感的。
**Cons:** CI にクラスタ認証情報を保持（NAT 内クラスタなので接続経路も要る）、
drift 検知なし、ロールバックはパイプライン再実行、宣言的な現状が Git にない。

## Trade-off Analysis

核心は「1人運用で破綻しないこと」。C と D は初速は速いが、アプリが増えると
線形以上に運用が重くなる。A/B（GitOps）は初期コストと引き換えに、以後の
運用が「Git 操作」に収束する。

A vs B はリソースと UI のトレードオフ。クラスタは非力だが、Argo CD の
0.5–1GB は ADR-0003 の暫定策（cp taint 解除で計 12GB）に収まる範囲。
UI がある分 1人での状態把握・トラブルシュートが速く、GUI 要望も満たす。
→ **A（Argo CD）**。RAM が本当に逼迫したら B への乗り換えを再検討。

## Consequences

**楽になること**
- デプロイ = `git push`。手順書・デプロイスクリプト不要。
- ロールバック = `git revert`。履歴と差分が常に Git にある。
- クラスタの drift を Argo CD が検知・是正。
- CI が軽い（ビルドとタグ更新だけ）。

**難しくなること / 新たな負担**
- `gitops/` リポジトリ構成の設計と初期ブートストラップ。
- Argo CD 自体の運用（アップグレード、CRD）。
- Argo CD のリソース消費（非力クラスタでは無視できない）。
- Argo CD への到達（NAT 内なので UI は SSH トンネル or Cloudflare 経由、ADR-0002）。

**あとで見直す**
- RAM 逼迫時に Flux へ。
- App 数が増えたら ApplicationSet / 複数 Project。
- PR プレビュー環境（1人なら当面不要）。

## Action Items

1. [ ] `homelab-gitops` リポジトリの構成を確定（ADR-0007）
       （`bootstrap/` `platform/` `apps/<app>/overlays/{dev,prod}`）
2. [ ] `ansible/playbooks/50-argocd.yml` で Argo CD を導入（Helm or manifest）
3. [ ] `app-of-apps` の root Application を作成
4. [ ] Argo CD 管理外の初期リソース（namespace 等）の扱いを決める
5. [ ] Argo CD UI への到達手段を決める（当面 SSH トンネル、後で Cloudflare）
