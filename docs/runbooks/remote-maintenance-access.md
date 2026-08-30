# リモートメンテナンスアクセス（Cloudflare Access / VPN クライアント不要）

ADR-0011。外出先から KVM ホストに SSH するための手順。VPN クライアントは
使わず、Cloudflare Access（Zero Trust）で ID 認証つきの Tunnel を張る。

Web 公開用の cloudflared（`homelab-gitops/platform/cloudflared/`、クラスタ内
Deployment）とは**別物**。こちらはホスト OS に直接常駐する。

---

## 1. Cloudflare 側の準備（ダッシュボード作業・ホストごとに実施）

Cloudflare ダッシュボード → 左メニュー **Zero Trust** → **Networks → Tunnels**

### 1-1. Tunnel を作成（host A 用）

1. **Create a tunnel** → connector type: **Cloudflared** → 名前: `kvm-host-a-ssh`
2. 「Install and run a connector」画面で表示されるコマンドから **トークン部分だけ**controlすれば良い
   （`cloudflared service install <ここがトークン>` の `<...>`）。**ターミナルにメモするだけで、チャットには貼らない。**
3. 続けて **Published application routes** タブ → **Add a public hostname**
   - Subdomain: `ssh-hosta`
   - Domain: `nekonekoinsurance.com`
   - Service Type: **SSH**
   - URL: `localhost:22`
4. Save

### 1-2. host B も同様に

- Tunnel 名: `kvm-host-b-ssh`
- Public hostname: `ssh-hostb.nekonekoinsurance.com` → Service Type **SSH** → `localhost:22`
- トークンをメモ

これで Tunnel は 2 本（ホスト1台につき1本、1トークン）。

### 1-3. Access アプリケーションでログインを必須化

Zero Trust → **Access → Applications → Add an application → Self-hosted**

- Application name: `SSH Maintenance`
- Public hostname に `ssh-hosta.nekonekoinsurance.com` と
  `ssh-hostb.nekonekoinsurance.com` の両方を追加
- Policy: **Allow**
  - Include: **Emails** → 自分のメールアドレスのみ
  - Session duration: 好みで（例: 24時間）
- 認証方法（Login method）はメール OTP か、既に使っている IdP（Google 等）でよい

---

## 2. ホスト側のセットアップ（Ansible）

```bash
cd ~/kvm/ansible

# host A
ansible-playbook playbooks/61-remote-access.yml --limit kvm-host-a -K \
  -e cloudflared_ssh_token='<1-1 でメモした host A のトークン>'

# host B
ansible-playbook playbooks/61-remote-access.yml --limit kvm-host-b -K \
  -e cloudflared_ssh_token='<1-2 でメモした host B のトークン>'
```

確認:

```bash
ansible kvm_hosts -m shell -a 'systemctl is-active cloudflared ssh' -K
```

両ホストで `active active` になれば OK。

---

## 3. 接続方法

### 3-1. ブラウザだけで（推奨・クライアント不要）

Zero Trust ダッシュボード → **Networks → Tunnels** → 対象の Public Hostname
の「…」メニュー、または直接 `https://ssh-hosta.nekonekoinsurance.com` に
ブラウザでアクセス → Access のログイン画面 → 認証後、**ブラウザ内蔵ターミナル**
がそのまま開く。インストール一切不要。

### 3-2. 手元の `ssh` コマンドを使いたい場合

Mac/Windows に `cloudflared` を1回だけ入れる（VPN ではなく単発のローカル
プロキシ）:

```bash
brew install cloudflared   # Mac の場合
```

SSH config に追記（`~/.ssh/config`）:

```
Host ssh-hosta.nekonekoinsurance.com
  ProxyCommand cloudflared access ssh --hostname %h

Host ssh-hostb.nekonekoinsurance.com
  ProxyCommand cloudflared access ssh --hostname %h
```

あとは普通に:

```bash
ssh tukapai@ssh-hosta.nekonekoinsurance.com
```

初回接続時にブラウザが開き Access のログインを求められる（以降は
セッション期限まで再認証不要）。

---

## トークンのローテーション / 撤去

```bash
# 撤去（cloudflared service をアンインストール）
ansible-playbook playbooks/61-remote-access.yml --limit kvm-host-a -K \
  -e cloudflared_ssh_state=absent

# ローテーション = 撤去 → Cloudflare 側で Tunnel のトークン再生成 → 再導入
```

## トラブルシュート

| 症状 | 確認 |
|---|---|
| Access のログイン画面すら出ない | Tunnel の Public Hostname 設定・DNS 反映を確認（数分かかることがある）|
| ログインは通るがターミナルに繋がらない | ホスト側 `systemctl status cloudflared`、`journalctl -u cloudflared` |
| `cloudflared access ssh` が固まる | ブラウザでの Access ログインが裏で必要。ブラウザが開いているか確認 |
| sshd に繋がらない | `systemctl status ssh` （host 側で sshd が動いているか）|

## 関連

- ADR-0011（この機能の設計判断）
- ADR-0002（Web 公開の Cloudflare Tunnel。こちらとは別プロセス）
- `mac/README.md`（Headlamp 用の既存 SSH トンネル。将来この仕組みに統一するかも）
