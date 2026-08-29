#!/usr/bin/env bash
#
# 40-expose-console.sh
# KVM ホストの LAN ポート → libvirt NAT 内ノードの NodePort へ転送する。
# これで Mac のブラウザから https://<KVMホストIP>:<LAN_PORT> でコンソールを開ける。
#
#   ./scripts/40-expose-console.sh add        # 転送を追加 + 再起動時も復元
#   ./scripts/40-expose-console.sh remove     # 転送を削除
#   ./scripts/40-expose-console.sh status     # 現在のルール確認
#
# 変数（config.env / 環境変数で調整）:
#   LAN_PORT   ホスト側の待受ポート            (既定 8443)
#   TARGET_IP  転送先ノード IP                  (既定 CP_IP = 192.168.122.11)
#   NODE_PORT  転送先の NodePort                (既定 30443 = 40-web-console.yml)
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_logging "$0"

ACTION="${1:-add}"
LAN_PORT="${LAN_PORT:-8443}"
TARGET_IP="${TARGET_IP:-${CP_IP}}"
NODE_PORT="${NODE_PORT:-30443}"
UNIT=/etc/systemd/system/k8s-console-forward.service
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# iptables は「-t <table>」を -I/-C/-D より前に置く必要がある。
rule_pre() { sudo iptables -t nat "$1" PREROUTING  -p tcp --dport "$LAN_PORT" -j DNAT --to-destination "${TARGET_IP}:${NODE_PORT}"; }
rule_out() { sudo iptables -t nat "$1" OUTPUT      -p tcp -d 127.0.0.1 --dport "$LAN_PORT" -j DNAT --to-destination "${TARGET_IP}:${NODE_PORT}"; }
rule_fwd() { sudo iptables         "$1" FORWARD     -p tcp -d "$TARGET_IP" --dport "$NODE_PORT" -j ACCEPT; }
rule_snat(){ sudo iptables -t nat "$1" POSTROUTING -p tcp -d "$TARGET_IP" --dport "$NODE_PORT" -j MASQUERADE; }

add_rules() {
    rule_pre  -C 2>/dev/null || rule_pre  -I
    rule_out  -C 2>/dev/null || rule_out  -I
    rule_fwd  -C 2>/dev/null || rule_fwd  -I
    rule_snat -C 2>/dev/null || rule_snat -I
    echo "==> 追加: <KVMホスト>:${LAN_PORT} -> ${TARGET_IP}:${NODE_PORT}"
}

del_rules() {
    rule_pre  -D 2>/dev/null || true
    rule_out  -D 2>/dev/null || true
    rule_fwd  -D 2>/dev/null || true
    rule_snat -D 2>/dev/null || true
    echo "==> 削除しました"
}

install_unit() {
    sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=Forward LAN ${LAN_PORT} to k8s NodePort ${NODE_PORT}
After=libvirtd.service network-online.target
Wants=libvirtd.service network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${SELF} add-rules-only
ExecStop=${SELF} remove

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable k8s-console-forward.service
    echo "==> systemd ユニット登録済み（再起動後も自動復元）"
}

case "$ACTION" in
    add)             add_rules; install_unit ;;
    add-rules-only)  add_rules ;;                       # systemd から呼ばれる
    remove)
        del_rules
        sudo systemctl disable k8s-console-forward.service 2>/dev/null || true
        sudo rm -f "$UNIT"; sudo systemctl daemon-reload
        ;;
    status)
        echo "== nat PREROUTING / OUTPUT / POSTROUTING =="
        sudo iptables -t nat -S | grep -E "dport ${LAN_PORT}|${TARGET_IP}.*${NODE_PORT}" || echo "(なし)"
        echo "== filter FORWARD =="
        sudo iptables -S FORWARD | grep -E "${TARGET_IP}.*${NODE_PORT}" || echo "(なし)"
        ;;
    *) echo "使い方: $0 {add|remove|status}" >&2; exit 1 ;;
esac
