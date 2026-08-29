#!/usr/bin/env bash
#
# 04-interconnect.sh   （1 台目の KVM ホストで実行・ADR-0009）
#
# 1 台目の libvirt subnet（既定 192.168.122.0/24）と、2 台目以降の KVM ホストが
# いる LAN（既定 192.168.1.0/24）の間だけ NAT を無効化する。
# → Flannel のノード間 VXLAN が実 IP のまま通るようになる。
#   VM → インターネットの NAT はそのまま維持。ダウンタイムなし。
#
#   ./scripts/04-interconnect.sh add       # ルール追加 + 再起動時も復元
#   ./scripts/04-interconnect.sh remove
#   ./scripts/04-interconnect.sh status
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_logging "$0"

ACTION="${1:-add}"
V="${LIBVIRT_SUBNET_CIDR}"     # libvirt subnet
L="${LAN_CIDR}"                # LAN
UNIT=/etc/systemd/system/k8s-interconnect.service
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# libvirt の MASQUERADE より前に「LAN 宛はマスカレードしない」を挿す
NO_SNAT=(-t nat POSTROUTING -s "$V" -d "$L" -j RETURN)
# libvirt の REJECT より前に双方向 FORWARD ACCEPT
FWD_IN=(FORWARD -s "$L" -d "$V" -j ACCEPT)
FWD_OUT=(FORWARD -s "$V" -d "$L" -j ACCEPT)

add_rules() {
    sudo sysctl -qw net.ipv4.ip_forward=1
    sudo iptables -C "${NO_SNAT[@]}" 2>/dev/null || sudo iptables -I "${NO_SNAT[@]}"
    sudo iptables -C "${FWD_IN[@]}"  2>/dev/null || sudo iptables -I "${FWD_IN[@]}"
    sudo iptables -C "${FWD_OUT[@]}" 2>/dev/null || sudo iptables -I "${FWD_OUT[@]}"
    echo "==> $V <-> $L を NAT なしで相互接続"
}
del_rules() {
    sudo iptables -D "${NO_SNAT[@]}" 2>/dev/null || true
    sudo iptables -D "${FWD_IN[@]}"  2>/dev/null || true
    sudo iptables -D "${FWD_OUT[@]}" 2>/dev/null || true
    echo "==> ルール削除"
}
install_unit() {
    sudo tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=k8s cross-host interconnect ($V <-> $L)
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
    sudo systemctl enable k8s-interconnect.service
    echo "==> systemd ユニット登録（libvirt リロード / 再起動後も復元）"
}

case "$ACTION" in
    add)            add_rules; install_unit
                    echo
                    echo "2 台目以降のノード / VM 側で 1 台目 subnet への経路が必要:"
                    echo "    ip route add $V via ${KVM_HOST_LAN_IP:-<1台目のLAN IP>}"
                    echo "（02-create-node-vm.sh の bridge モードは cloud-init で自動設定）"
                    ;;
    add-rules-only) add_rules ;;
    remove)
        del_rules
        sudo systemctl disable k8s-interconnect.service 2>/dev/null || true
        sudo rm -f "$UNIT"; sudo systemctl daemon-reload
        ;;
    status)
        echo "== nat POSTROUTING =="; sudo iptables -t nat -S POSTROUTING | grep -E "$V|$L" || echo "(なし)"
        echo "== filter FORWARD ==";  sudo iptables -S FORWARD | grep -E "$V|$L" || echo "(なし)"
        ;;
    *) echo "usage: $0 {add|remove|status}" >&2; exit 1 ;;
esac
