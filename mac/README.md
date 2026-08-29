# Mac から Kubernetes を見る

クラスタは libvirt NAT（`192.168.122.0/24`）内にあり、**KVM ホスト経由でしか
API サーバ（既定 `192.168.122.11:6443`）に到達できない**。Mac からは SSH で
トンネルするか、KVM ホストにポート転送を入れる。

このドキュメントでは以下を使う（自分の環境に読み替え）:

| プレースホルダ | 意味 | 例 |
|---|---|---|
| `$KVM_HOST` | KVM ホストの `user@LAN-IP` | `alice@192.168.0.10` |
| `$REPO` | KVM ホスト上のリポジトリの場所 | `~/homelab-k8s` |

- API サーバ証明書の SAN: `<CP_NAME>`, `kubernetes*`, `10.96.0.1`, `<CP_IP>`
- `kubeconfig-tunnel` は `server: https://127.0.0.1:6443` /
  `tls-server-name: <CP_NAME>` に書き換え済み（SSH トンネル併用前提）。
  `20-control-plane.yml` が生成する。

---

## 推奨: Headlamp（デスクトップ GUI）+ 自動トンネル

Mac で 1 回だけ:

```bash
scp "$KVM_HOST:$REPO/mac/setup-headlamp-mac.sh" .
HOST_SSH="$KVM_HOST" REMOTE_REPO="$REPO" ./setup-headlamp-mac.sh
```

スクリプトがやること:

1. `brew install autossh` / `brew install --cask headlamp`
2. `kubeconfig-tunnel` を `~/.kube/config` に配置（既存があれば `.bak` へ退避）
3. `~/Library/LaunchAgents/com.kvm-k8s.tunnel.plist` を作成し
   `autossh -L 6443:<CP_IP>:6443 $KVM_HOST` を
   **ログイン時に自動起動・切断時に自動復旧**
4. `kubectl get nodes` で疎通確認

以降は **Headlamp.app を開くだけ**。`~/.kube/config` のクラスタが出る。

前提: `ssh $KVM_HOST` が鍵認証でパスワード無しに通ること。

トンネル管理（モダンな launchctl 構文。`load`/`unload` は使わない）:

```bash
launchctl bootout   gui/$(id -u)/com.kvm-k8s.tunnel                       # 停止
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.kvm-k8s.tunnel.plist  # 開始
launchctl kickstart -k gui/$(id -u)/com.kvm-k8s.tunnel                    # 再起動
launchctl print     gui/$(id -u)/com.kvm-k8s.tunnel                       # 状態
tail -f /tmp/com.kvm-k8s.tunnel.log                                       # ログ
```

`launchctl load` が `Load failed: 5: Input/output error` になる場合は上の
`bootout` → `bootstrap` を使う。`plutil -lint <plist>` で plist 検証、
`which autossh` が plist 内のパスと一致しているかも確認。

### 手動でやる場合

```bash
brew install autossh
brew install --cask headlamp
mkdir -p ~/.kube
scp "$KVM_HOST:$REPO/mac/kubeconfig-tunnel" ~/.kube/config
chmod 600 ~/.kube/config
# 使う間つないでおく（別ターミナル）
ssh -N -L 6443:192.168.122.11:6443 "$KVM_HOST"
```

### メトリクス（Headlamp で CPU/メモリを見る）

```bash
# KVM ホストで
cd "$REPO/ansible" && ansible-playbook playbooks/42-metrics-server.yml
export KUBECONFIG="$REPO/ansible/kubeconfig"
kubectl top nodes
```

---

## 代替: ブラウザで Kubernetes Dashboard を見る

Headlamp でなくブラウザの Web コンソールが良い場合。

### 1. 導入（KVM ホストで 1 回）

```bash
cd "$REPO/ansible" && ansible-playbook playbooks/40-web-console.yml
```

- `kubernetes-dashboard` 名前空間に Dashboard、NodePort **30443**
- `cluster-admin` の ServiceAccount と無期限トークン
- `mac/dashboard-token.txt`（トークン）と `mac/dashboard.kubeconfig`
  （トークン埋め込み kubeconfig）が回収される

### 2. 到達方法

| | 手順 | URL |
|---|---|---|
| すぐ見る | Mac で `ssh -N -L 8443:<CP_IP>:30443 $KVM_HOST` | `https://localhost:8443` |
| 常用 | KVM ホストで `./scripts/40-expose-console.sh add` | `https://<KVMホストIP>:8443` |

### 3. ログイン

- **Token**: `mac/dashboard-token.txt` の中身を貼る
- **Kubeconfig**: `mac/dashboard.kubeconfig` を選ぶ（貼り付け不要）

> Dashboard の Kubeconfig ログインは**トークンを含む** kubeconfig が必要。
> `ansible/kubeconfig`（クライアント証明書のみ）は Dashboard では使えない。

---

## ファイル一覧

| ファイル | コミット | 用途 |
|---|---|---|
| `setup-headlamp-mac.sh` | ○ | Mac 側セットアップ（Headlamp + 自動トンネル）|
| `kubeconfig-tunnel` | × | `~/.kube/config` 用（`20-control-plane.yml` が生成）|
| `dashboard.kubeconfig` | × | Dashboard ブラウザログイン用（`40-web-console.yml` が生成）|
| `dashboard-token.txt` | × | Dashboard ログイントークン（同上）|

× は認証情報を含むため Git 追跡外（`.gitignore` 済み）。

## セキュリティメモ

- Dashboard トークンは `cluster-admin`（全権限）。
- `40-expose-console.sh add` は LAN 全体に 8443 を晒す（認証は必要）。
  絞るなら PREROUTING ルールに `-s <MacのIP>` を追加。
- Dashboard 破棄: `kubectl delete ns kubernetes-dashboard` +
  `kubectl delete clusterrolebinding dashboard-admin`
