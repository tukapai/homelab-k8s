#!/usr/bin/env bash
#
# 03-destroy-node-vm.sh
# VM を停止・削除し、libvirt ネットワークの DHCP 予約も外す。
#
#   ./scripts/03-destroy-node-vm.sh k8s-cp-1
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_logging "$0"

VM_NAME="${1:?使い方: $0 <VM名>}"
MAC="$(mac_for "$VM_NAME")"

$VIRSH destroy "$VM_NAME" 2>/dev/null || true
$VIRSH undefine "$VM_NAME" --remove-all-storage --nvram 2>/dev/null \
    || $VIRSH undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
$VIRSH net-update "$LIBVIRT_NET" delete ip-dhcp-host \
    "<host mac='$MAC'/>" --live --config 2>/dev/null || true

echo "==> '$VM_NAME' を削除しました"
echo "    ansible/inventory.ini から該当行を消すのを忘れずに"
