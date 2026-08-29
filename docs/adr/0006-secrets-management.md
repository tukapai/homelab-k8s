# ADR-0006: Secret 管理方式

**Status:** Proposed
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

GitOps（ADR-0001）ではマニフェストを Git に置く。しかし Secret を平文で
コミットはできない。管理すべき機密の例:

- Cloudflare Tunnel トークン（ADR-0002）
- オブジェクトストレージ（R2/B2）のアクセスキー（ADR-0004）
- アプリの API キー、外部サービス認証情報
- （DB 認証情報は CNPG が生成するので原則対象外）

制約:

- 運用者 1人。鍵管理の手間を最小化したい。
- **可用性戦略が「IaC + バックアップで再構築」**（ADR-0003）。
  → Secret の復号に必要な鍵材料も「再構築後に復元できる」必要がある。
  クラスタに固有の鍵を使う方式では、その鍵を別途バックアップしないと
  再構築後に Git 内の Secret を一切復号できなくなる。

## Decision（案）

**Sealed Secrets（Bitnami）を採用する。**
ただし **sealing key（`sealed-secrets` コントローラの秘密鍵）を
バックアップ対象に含める**ことを必須の運用ルールとする。

- `kubeseal` でクラスタ公開鍵に対して暗号化 → `SealedSecret` を Git にコミット
  → クラスタ内コントローラが `Secret` に復号。
- sealing key は
  `kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml`
  を暗号化して安全な場所（パスワードマネージャ / オフラインストレージ）に保管。
- 代替案（SOPS + age）が優位になる条件は「Consequences」に明記し、
  運用してみて負担が大きければ Supersetde する。

## Options Considered

### Option A: Sealed Secrets

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（コントローラ 1 つ + `kubeseal` CLI）|
| 外部依存 | なし |
| Argo CD 連携 | 追加設定ほぼ不要（`SealedSecret` は普通の CR）|
| 再構築耐性 | △ sealing key を別途バックアップしないと復号不能 |
| ローテーション | 弱い（手動再シール）|

**Pros:** セットアップが最も簡単。外部システム不要。Argo CD にプラグイン不要。
**Cons:** 鍵がクラスタ固有 → 再構築時に鍵の復元が要る（DR 戦略と相性に注意）。
Secret の中身を確認するのが面倒（復号済み Secret を見るしかない）。

### Option B: SOPS + age（+ Argo CD プラグイン ksops / argocd-vault-plugin）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med（Argo CD の repo-server にプラグイン組み込み）|
| 外部依存 | なし（age 鍵をローカル管理）|
| Argo CD 連携 | 要プラグイン設定 |
| 再構築耐性 | ◎ age 秘密鍵 1 つを保管すればどこでも復号 |
| ローテーション | 中（鍵の再暗号化）|

**Pros:** 暗号化ファイルをローカル/CI でも復号できる。**鍵は age 秘密鍵 1 つ**で、
パスワードマネージャに入れておけば再構築後もそのまま使える（DR と好相性）。
**Cons:** Argo CD の repo-server にカスタムプラグイン（ksops か avp）を仕込む
必要があり、初期セットアップとアップグレード時の手当てが増える。

### Option C: External Secrets Operator + バックエンド（Cloudflare/AWS/Vault 等）

**Pros:** 多数の Secret・ローテーション運用に強い。Secret 本体は Git に載らない。
**Cons:** 外部の Secret ストアが前提。1人 / 少数 Secret にはオーバースペック。

### Option D: HashiCorp Vault（自ホスト）

**Pros:** 動的シークレット、監査、フル機能。
**Cons:** Vault 自体の運用（unseal、HA、バックアップ）が 1人には重い。過剰。

## Trade-off Analysis

C/D は機密の数・チーム規模・ローテーション要件が大きいときに効く。今は
機密が数個、運用者 1人なので過剰。

A vs B が実質的な選択。純粋な「楽さ」は A。ただし本プロジェクトの
**DR 戦略が「再構築」**である点が効いてくる: A は sealing key を
確実にバックアップする運用規律が要る（怠ると Git の Secret が復号不能になる）。
B はその一点を構造的に回避できる（age 秘密鍵だけ守ればよい）が、
Argo CD プラグインという継続的な複雑さを負う。

→ 初期は **A（Sealed Secrets）+ sealing key バックアップの明文化**で開始。
sealing key 管理が負担、あるいは再構築を実際に行って辛かった場合に
**B へ移行**（この ADR を Superseded にする）。

## Consequences

**楽になること**
- Secret も含めてすべて Git で管理でき、Argo CD がそのまま同期。
- 追加の外部システムなし。プラグインなし。

**難しくなること / 新たな負担**
- **sealing key のバックアップが必須運用**。バックアップセット
  （ADR-0004 の R2 等）に暗号化して含め、復元手順を runbook 化する。
- Secret 値の確認・更新のたびに `kubeseal` を回す。
- クラスタ再構築時は「sealing key を先に復元 → Argo CD 同期」の順序厳守。

**あとで見直す（B への移行トリガー）**
- クラスタ再構築を実施し、sealing key 復元がボトルネックだった。
- CI やローカルでも Secret を復号したくなった。
- 機密数が増え、ローテーション運用が必要 → B もしくは C。

## Action Items

1. [ ] この ADR を Accepted にするか、B（SOPS+age）に差し替えるか決定
2. [ ] `gitops/platform/sealed-secrets/` にコントローラ
3. [ ] `kubeseal` を開発機に導入
4. [ ] Cloudflare Tunnel トークン / R2 キーを `SealedSecret` 化してコミット
5. [ ] sealing key のバックアップ & 復元手順を
       `docs/runbooks/backup-restore.md` に記載し、一度復元テスト
