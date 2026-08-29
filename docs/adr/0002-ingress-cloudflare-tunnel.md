# ADR-0002: インターネット公開は Cloudflare Tunnel

**Status:** Accepted
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

## Context

Web API を **インターネットに公開**する。クラスタは自宅の KVM ホスト上の
libvirt NAT（`192.168.122.0/24`）内にあり、外からは直接届かない。

- 自宅回線: CGNAT の可能性、ISP による 80/443 ブロックの可能性、
  グローバル IP が変動、DDoS 対策なし、自宅 IP を晒したくない。
- 運用者は 1人。証明書更新・DDNS・ルーター設定を増やしたくない。
- TLS 終端と最低限の WAF/レート制限はほしい。
- クラスタは非力（ADR-0003）。エッジで吸収できるものは吸収したい。

## Decision

**Cloudflare Tunnel** を採用。`cloudflared` をクラスタ内 Deployment
（2 レプリカ）として動かし、Cloudflare へ**アウトバウンド接続のみ**で
トンネルを張る。DNS・エッジ TLS・WAF・DDoS 対策は Cloudflare 側。

トラフィック経路:

```
Internet → Cloudflare(edge) → cloudflared(Pod) → ingress-nginx(ClusterIP) → Service
```

`ingress-nginx` は `ClusterIP`。公開ホスト名は Cloudflare の DNS →
Tunnel にマッピングし、Tunnel の ingress ルールで
`http://ingress-nginx-controller.ingress-nginx.svc:80` に流す。

## Options Considered

### Option A: Cloudflare Tunnel（cloudflared in-cluster）

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low（Deployment + トークン 1 つ）|
| Cost | 無料プランで可 / クラスタ負荷 約 50–100Mi |
| Home network への影響 | なし（ポート開放不要）|
| Security | 実 IP 秘匿、エッジ WAF/DDoS、mTLS(cloudflared↔edge) |

**Pros:** ルーター設定ゼロ、CGNAT でも動く、TLS/DDoS/WAF がタダ、
自宅 IP 非公開、cert-manager と MetalLB が不要になる（ADR-0005）。
**Cons:** Cloudflare への依存（アカウント・SPOF ではないが経路の一部）。
無料プランの規約は基本 Web トラフィック向け（大容量メディア配信や
非 HTTP は Spectrum / 有料 / 別手段）。デバッグが CF 経由になる。

### Option B: ルーター port-forward + MetalLB + cert-manager + DDNS

| Dimension | Assessment |
|-----------|------------|
| Complexity | High |
| Cost | 無料（ただし DDNS / ドメイン）|
| Home network への影響 | 大（80/443 を自宅に開放）|
| Security | 実 IP 露出、DDoS 直撃、WAF は自前 |

**Pros:** 外部依存が最小、フルコントロール、非 HTTP も可。
**Cons:** CGNAT だとそもそも不可。自宅 IP 露出。ルーター・DDNS・
Let's Encrypt 更新・MetalLB を自分で面倒みる。KVM ホストでの
DNAT（既存の `40-expose-console.sh` 相当）も必要。

### Option C: 安い VPS をリバースプロキシにして WireGuard で自宅へ

| Dimension | Assessment |
|-----------|------------|
| Complexity | Med–High |
| Cost | VPS 代（月数百円〜）|
| Home network への影響 | なし（VPN アウトバウンド）|
| Security | VPS の IP を晒す（自宅は隠れる）、TLS は自前 |

**Pros:** Cloudflare 非依存、非 HTTP も通せる、固定 IP。
**Cons:** VPS の月額・パッチ当て・WireGuard 運用が増える。TLS は自前
（VPS 上で cert-manager or Caddy）。1人には重い。

### Option D: Tailscale Funnel

| Dimension | Assessment |
|-----------|------------|
| Complexity | Low |
| Cost | 無料枠あり |
| Home network への影響 | なし |
| Security | Tailscale 依存、ポート/帯域に制限 |

**Pros:** セットアップが非常に簡単。
**Cons:** 公開できるポート・パスに制限、帯域も控えめ、
本番の公開 API 用途としては機能不足。

## Trade-off Analysis

要件は「インターネット公開」「1人で楽」「自宅回線」。B は自宅回線の
リスク（CGNAT・IP 露出・ISP ブロック）を正面から受け、運用項目が最多。
C は依存を減らせるが月額と VPN 運用が増える。D は簡単だが力不足。

A は Cloudflare 依存と無料プラン規約という条件付きだが、
**運用項目が圧倒的に少なく**、cert-manager・MetalLB・DDNS・ルーター設定を
まとめて不要にできる。ユーザーは依存と規約を許容すると明言済み。
→ **A（Cloudflare Tunnel）**。

## Consequences

**楽になること**
- ルーター・DDNS・ポート開放が一切不要。CGNAT でも動く。
- TLS / DDoS / WAF / レート制限がエッジで完結。
- `cert-manager` と `MetalLB` を入れずに済む（ADR-0005）。
- 自宅グローバル IP が露出しない。

**難しくなること / 新たな負担**
- Cloudflare アカウント・ドメインが前提。
- Tunnel トークンという機密が増える（Sealed Secret 等で管理、ADR-0006）。
- `cloudflared` を冗長化（2 レプリカ）してもトラフィックは CF 経由が前提。
- 障害切り分けが「CF → tunnel → ingress → app」と 1 段増える。
- 無料プラン規約の範囲を意識（大容量・非 HTTP は別手段）。

**あとで見直す**
- トラフィックが規約や無料枠を超えたら、有料 / Spectrum / Option C へ。
- LAN からの直接アクセスが必要になったら MetalLB を追加（ADR-0005）。

## Action Items

1. [ ] Cloudflare アカウント + ドメインを用意、Zero Trust で Tunnel を作成
2. [ ] Tunnel トークンを Sealed Secret 化して `gitops/platform/cloudflared/` に
3. [ ] `cloudflared` Deployment（2 レプリカ）+ ConfigMap（ingress ルール）
4. [ ] `ingress-nginx` を `ClusterIP` で導入（`gitops/platform/ingress-nginx/`）
5. [ ] 公開ホスト名（例 `api.example.com`）を Tunnel にマッピングし疎通確認
6. [ ] Cloudflare 側で WAF / レート制限 / キャッシュ設定
