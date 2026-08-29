# ADR-0005: MetalLB / cert-manager は当面入れない

**Status:** Accepted（Ingress は ADR-0010 で ingress-nginx → **Kong** に変更。
MetalLB / cert-manager 不要の判断は不変）
**Date:** 2026-08-29
**Deciders:** Masashi Otsuka（単独メンテナ）

> 更新: 唯一の Ingress コントローラは **Kong Ingress Controller**（DB-less、
> `Service.type: ClusterIP`）。以下の本文の ingress-nginx は Kong に読み替える。

## Context

Kubernetes に Web アプリを公開する構成では `MetalLB`（ベアメタル用
LoadBalancer）と `cert-manager`（ACME による証明書自動発行）が定番。
しかし本構成では:

- 公開経路は **Cloudflare Tunnel → cloudflared → ingress-nginx(ClusterIP)**
  （ADR-0002）。外部からの入口に `type: LoadBalancer` は不要。
- **エッジ TLS は Cloudflare** が終端。クラスタ内 `cloudflared → ingress` は
  HTTP でよい。公開用の Let's Encrypt 証明書は要らない。
- PostgreSQL の内部 TLS は **CloudNativePG が自前の CA で発行**（ADR-0004）。
- クラスタは非力（ADR-0003）。使わないコンポーネントを常駐させたくない。

## Decision

- `ingress-nginx` は **`Service.type: ClusterIP`** で導入。
- **MetalLB は入れない。**
- **cert-manager は入れない。**
- どちらも「必要になった時点で追加する」。追加はいずれも Kustomize/Helm
  1 コンポーネント分で、既存構成に非破壊。

## Options Considered

### Option A: 両方入れない（採用）

**Pros:** フットプリント最小（約 0.5GB とコントローラ 4–5 個を節約）、
ブートストラップが速い、運用対象が減る。
**Cons:** LAN から `type: LoadBalancer` で直接叩けない（`kubectl port-forward`
か NodePort で代替）。クラスタ内 ACME 証明書がない。

### Option B: 定番だから両方入れる

**Pros:** 「普通の」構成。あとで LAN 公開や内部 mTLS が要るとき即使える。
**Cons:** 非力クラスタで未使用のコントローラが常時 RAM を食う。
cert-manager の CRD / Issuer 設定、MetalLB の IP プール設定という
初期作業と運用が、当面リターンなしで増える。

### Option C: MetalLB だけ入れる

LAN 内の他デバイスから一部サービスを固定 IP で使いたい場合に価値。
現時点でその要件はない。

### Option D: cert-manager だけ入れる

サービス間 mTLS や、LAN 用ホスト名の HTTPS が要るなら価値。
現時点でその要件はない（CNPG は自前で証明書を持つ）。

## Trade-off Analysis

MetalLB / cert-manager が解く問題（L2 LoadBalancer、ACME 証明書）は、
Cloudflare Tunnel + エッジ TLS + CNPG 内部 CA の組み合わせで**現状すべて
充足されている**。非力クラスタで「将来使うかも」のために常駐させるのは
純損失。両者とも後付けが容易（非破壊）なので、YAGNI に倒す。
→ **A**。

## Consequences

**楽になること**
- プラットフォームの常駐コンポーネントが最小。
- ブートストラップとアップグレード対象が減る。
- IP プール設計・Issuer 設計という初期タスクが不要。

**難しくなること / 新たな負担**
- LAN の他マシンからクラスタ内サービスへ直接アクセスするには
  `kubectl port-forward` / NodePort / SSH トンネルを使う（既存 `mac/` の方式）。
- クラスタ内で ACME 証明書が要る場面が出たら、その時 cert-manager を追加。
- 「なぜ入っていないのか」を忘れないよう、この ADR を参照点にする。

**あとで見直す（追加のトリガー）**
- LAN 内から固定 IP の `type: LoadBalancer` サービスが必要 → **MetalLB**
- サービス間 mTLS / 内部ホスト名の HTTPS / webhook 証明書管理 → **cert-manager**
- Cloudflare をやめてルーター port-forward に移行（ADR-0002 の見直し）→ 両方

## Action Items

1. [ ] `gitops/platform/ingress-nginx/` の values を `controller.service.type=ClusterIP`
2. [ ] `cloudflared` の ingress ルールを
       `service: http://ingress-nginx-controller.ingress-nginx.svc:80` に
3. [ ] README / docs に「LAN からサービスを見る方法（port-forward / NodePort）」を明記
4. [ ] 将来 MetalLB / cert-manager を足す手順の骨子を `docs/` にメモ
