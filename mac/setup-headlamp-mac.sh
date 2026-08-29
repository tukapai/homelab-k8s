#!/usr/bin/env bash
#
# setup-headlamp-mac.sh  —  Mac 側で 1 回実行する
#
# - Headlamp（デスクトップ GUI）と autossh を導入
# - kubeconfig を ~/.kube/config に配置
# - API サーバへの SSH トンネルを LaunchAgent 化（ログイン時に自動起動・自動復旧）
#
# 使い方:
#   HOST_SSH=youruser@<KVMホストのLAN-IP> ./setup-headlamp-mac.sh
#
# 前提: この Mac から `ssh $HOST_SSH` が鍵認証でパスワード無しに通ること。
#
set -euo pipefail

# KVM ホスト（user@host）。必ず指定する。
HOST_SSH="${HOST_SSH:?HOST_SSH=youruser@<KVMホストIP> を指定してください}"
# KVM ホスト上のリポジトリの場所（clone 先に合わせる）。
REMOTE_REPO="${REMOTE_REPO:-\$HOME/homelab-k8s}"
REMOTE_KUBECONFIG="${REMOTE_REPO}/mac/kubeconfig-tunnel"
LOCAL_PORT="${LOCAL_PORT:-6443}"
# control-plane VM の IP:PORT（config.env の CP_IP に合わせる）。
VM_APISERVER="${VM_APISERVER:-192.168.122.11:6443}"
LABEL="com.kvm-k8s.tunnel"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

echo "==> Homebrew パッケージ"
command -v brew >/dev/null || { echo "Homebrew が必要です: https://brew.sh"; exit 1; }
brew list autossh          >/dev/null 2>&1 || brew install autossh
brew list --cask headlamp  >/dev/null 2>&1 || brew install --cask headlamp

echo "==> kubeconfig を ~/.kube/config に配置"
mkdir -p "${HOME}/.kube"
if [[ -s "${HOME}/.kube/config" ]] && ! grep -q "127.0.0.1:${LOCAL_PORT}" "${HOME}/.kube/config"; then
    cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak.$(date +%s)"
    echo "    既存 config を .bak に退避しました"
fi
scp "${HOST_SSH}:${REMOTE_KUBECONFIG}" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"

echo "==> SSH トンネルの LaunchAgent を作成"
AUTOSSH_BIN="$(command -v autossh)"
mkdir -p "${HOME}/Library/LaunchAgents"
cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${AUTOSSH_BIN}</string>
    <string>-M</string><string>0</string>
    <string>-N</string>
    <string>-o</string><string>ServerAliveInterval=30</string>
    <string>-o</string><string>ServerAliveCountMax=3</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-L</string><string>${LOCAL_PORT}:${VM_APISERVER}</string>
    <string>${HOST_SSH}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/${LABEL}.log</string>
  <key>StandardErrorPath</key><string>/tmp/${LABEL}.log</string>
</dict>
</plist>
EOF

plutil -lint "${PLIST}" >/dev/null || { echo "plist が不正です"; exit 1; }
launchctl bootout   "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${PLIST}"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"
sleep 2

echo "==> 疎通確認"
if kubectl get nodes 2>/dev/null; then
    echo
    echo "OK. Headlamp.app を開くと ~/.kube/config のクラスタが表示されます。"
else
    echo "まだ繋がりません。数秒後に 'kubectl get nodes' を再試行、"
    echo "またはログ: tail -f /tmp/${LABEL}.log"
fi

cat <<EOF

------------------------------------------------------------
トンネル管理:
  停止:   launchctl bootout   gui/\$(id -u)/${LABEL}
  開始:   launchctl bootstrap gui/\$(id -u) ${PLIST}
  再起動: launchctl kickstart -k gui/\$(id -u)/${LABEL}
  状態:   launchctl print     gui/\$(id -u)/${LABEL}
  ログ:   tail -f /tmp/${LABEL}.log
------------------------------------------------------------
EOF
