# ADR-0011: リモートメンテナンスアクセスは Cloudflare Access（VPN クライアントなし）

**Status:** Accepted
**Date:** 2026-08-30
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

普段のメンテナンスは自宅 LAN 内から行うが、外出先から SSH でホストに
入りたい場面（障害対応・ちょっとした確認）を考慮したい。

- 自宅ルーターのポート開放はしたくない（ADR-0002 と同じ方針）
- VPN クライアント（WireGuard/Tailscale 等）を常駐させたくない
  （端末を選ばず、設定済みの1台に依存したくない）
- 運用者は1人。IDaaS を自前で立てたくない
- Web 公開で Cloudflare Tunnel を既に採用しており（ADR-0002）、
  同じ仕組み・同じアカウントで完結させたい

## Decision

**Cloudflare Access（Zero Trust）** を SSH にも使う。KVM ホスト（物理2台）
それぞれに、Web 公開用（クラスタ内 Deployment）とは別の **ホスト常駐の
cloudflared** を立て、`ssh://localhost:22` への専用 Tunnel を張る。
Cloudflare Access のポリシーで自分のメールアドレスのみ許可する。

```
外出先のブラウザ（クライアント不要）
   │ HTTPS + Cloudflare Access ログイン（メールOTP等）
   ▼
Cloudflare Zero Trust
   │ Tunnel（アウトバウンド接続のみ、ポート開放不要）
   ▼
KVM ホスト常駐の cloudflared（Web公開用と別プロセス）
   │ ssh://localhost:22
   ▼
sshd
```

- 接続は Zero Trust ダッシュボードの **ブラウザ内蔵ターミナル**が第一候補
  （クライアントのインストール一切不要）
- 使い慣れた `ssh` コマンドを使いたい場合のみ `cloudflared access ssh`
  （単発のローカルプロキシ。仮想NICもルーティング変更も無い点で
  VPN クライアントとは性質が異なる）を任意でインストール

## Options Considered

### Option A: Cloudflare Access（採用）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（Tunnel 2本 + Access アプリ1つ）|
| Cost | 無料プランで可 |
| Home network への影響 | なし（ポート開放不要、既存方針と同一）|
| Client | 不要（ブラウザ完結）。CLI 併用も VPN ではない |
| Security | ID 認証（メール限定）、短命セッション、接続ログが CF 側に残る |

**Pros:** 既存の Cloudflare Tunnel 運用の延長で学習コストがほぼゼロ。
VPN クライアント・仮想NIC無し。Web 公開と同じ「アウトバウンドのみ」原則。
Argo CD UI や Headlamp も将来同じ仕組みに統一できる。
**Cons:** Cloudflare への依存が SSH アクセスにも広がる（ADR-0002 で
許容済みの依存を拡張するだけ、と判断）。

### Option B: WireGuard / Tailscale

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low〜Med |
| Client | **必要**（明確に除外条件）|

**Pros:** オフラインでも同じ操作感、帯域制限なし。
**Cons:** 端末ごとにクライアント常駐が必要 → 今回の要件に反する。

### Option C: 踏み台 VPS + 固定 IP 許可

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med〜High |
| Cost | VPS 代 |
| Client | 不要 |

**Pros:** Cloudflare 非依存。
**Cons:** VPS のパッチ運用・固定 IP 前提（外出先の IP は変わりやすく
相性が悪い）。1人運用には過剰。

### Option D: Teleport（自前ホスト）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med〜High |
| Client | 不要（ブラウザ可）|
| Security | セッション録画・詳細な RBAC 監査まで可能 |

**Pros:** 監査要件が強いなら最強。
**Cons:** 自前の Auth Server 運用が増える。ホームラボ・単独メンテナには
オーバースペック。将来チームで使うことになったら再検討。

## Trade-off Analysis

要件は「VPN クライアント無し」「自宅回線に手を入れない」「1人で楽」。
B は要件を満たさず除外。C は自宅回線への依存は減らせるが VPS 運用と
固定IP前提が今回に合わない。D は機能過多で運用コストが見合わない。

A は既存の Cloudflare Tunnel 資産（アカウント・ドメイン・運用知識）を
そのまま再利用でき、追加コストがほぼゼロ。ADR-0002 で受け入れ済みの
Cloudflare 依存の延長でしかないため、心理的にも運用的にも自然。
→ **A（Cloudflare Access）**。

## Consequences

**楽になること**
- ルーター設定・VPN クライアント管理が一切不要
- ブラウザさえあればどの端末からでもメンテナンス可能
- 同じ仕組みを Argo CD UI / Headlamp / Dashboard にも展開できる
  （SSH トンネルを段階的に置き換え可能）
- 接続ログが Cloudflare 側に残る（who/when の監査になる）

**難しくなること / 新たな負担**
- ホストごとに Tunnel トークンという機密が増える（`config.env` 同様に
  `.gitignore` 対象。Ansible の `-e` で都度渡す運用）
- Cloudflare のセッション・ポリシー設定を Zero Trust ダッシュボードで
  手動管理する必要がある（GitOps 対象外）
- Cloudflare 障害時は SSH アクセスも道連れになる
  （LAN 内からの直接 SSH は従来通り可能なので、自宅にいる限り影響なし）

**あとで見直す**
- 複数人でメンテナンスするようになったら Option D（Teleport）を再検討
- Argo CD UI / Headlamp の SSH トンネルをこの仕組みに統一するか検討

## Action Items

1. [x] `ansible/playbooks/61-remote-access.yml`（`[kvm_hosts]` 対象、
   `cloudflared service install <token>` で systemd 常駐化）
2. [x] 手順書 `docs/runbooks/remote-maintenance-access.md`
   （Cloudflare ダッシュボードでの Tunnel/Access 作成手順）
3. [ ] ホストA・B それぞれで Tunnel を作成しトークンを発行（ユーザー作業）
4. [ ] Access アプリケーション作成・ポリシー設定（自分のメールのみ許可、ユーザー作業）
5. [ ] 疎通確認（ブラウザ内蔵ターミナル / `cloudflared access ssh`）
6. [ ] 将来: Argo CD UI・Headlamp も Access 経由に統一するか検討
