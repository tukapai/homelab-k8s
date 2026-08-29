#!/usr/bin/env bash
#
# 01-install-kvm-host.sh
# この Ubuntu マシンを KVM ホストにセットアップする。
# 実行には sudo 権限が必要（パスワードを聞かれる）。
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_logging "$0"

echo "==> CPU の仮想化支援を確認"
if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
    echo "ERROR: CPU が仮想化(VT-x/AMD-V)に対応していないか、BIOS で無効化されています" >&2
    exit 1
fi

echo "==> KVM / libvirt / ツール類をインストール"
sudo apt-get update
sudo apt-get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    bridge-utils \
    cloud-image-utils \
    genisoimage \
    ansible \
    python3-libvirt

echo "==> libvirtd を有効化・起動"
sudo systemctl enable --now libvirtd

echo "==> 現在のユーザーを libvirt / kvm グループに追加"
sudo usermod -aG libvirt,kvm "$USER"

echo "==> '${LIBVIRT_NET}' ネットワークを起動・自動起動化"
sudo virsh net-start   "${LIBVIRT_NET}" 2>/dev/null || true
sudo virsh net-autostart "${LIBVIRT_NET}"

echo
echo "==> 動作確認"
sudo kvm-ok || true
$VIRSH version || true

cat <<'EOF'

============================================================
セットアップ完了。

重要: グループ変更を反映するため、いったんログアウト/ログイン
      するか、以下を実行してください:

    newgrp libvirt

その後、VM を作成します:

    ./scripts/02-create-node-vm.sh

============================================================
EOF
