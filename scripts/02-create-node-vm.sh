#!/usr/bin/env bash
#
# 02-create-node-vm.sh
# Ubuntu cloud イメージ + cloud-init で Kubernetes ノード用の VM を作成する。
#
# 設定は config.env に集約。ここでは「どのノードを作るか」だけ指定する。
#
# 使い方:
#   ./scripts/02-create-node-vm.sh                        # control-plane を作成
#   ROLE=worker NODE_NUM=1 ./scripts/02-create-node-vm.sh # worker-1 を追加（NAT）
#   ROLE=worker NODE_NUM=2 VCPUS=4 RAM_MB=8192 \          # スペックだけ上書き
#       ./scripts/02-create-node-vm.sh
#   # 2 台目の KVM ホストで（config.env: NET_MODE=bridge, LIBVIRT_NET=br0, NET_PREFIX=192.168.1）
#   ROLE=worker NODE_NUM=2 ./scripts/02-create-node-vm.sh # LAN 直結・静的 IP
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_logging "$0"
resolve_node

BASE_IMG="${POOL_DIR}/$(basename "$IMG_URL")"
DISK_PATH="${POOL_DIR}/${VM_NAME}.qcow2"
MAC="$(mac_for "$VM_NAME")"

NET_MODE="${NET_MODE:-nat}"
# macvtap モードで直付けする物理 NIC。未指定なら既定ルートの出口 IF を自動検出。
MACVTAP_SOURCE="${MACVTAP_SOURCE:-$(ip -o -4 route show default | awk '{print $5; exit}')}"

echo "==> 設定:"
printf '    %-10s %s\n' ROLE "$ROLE" NAME "$VM_NAME" IP "$VM_IP" \
    VCPUS "$VCPUS" RAM_MB "$RAM_MB" DISK_GB "$DISK_GB" \
    NET "$LIBVIRT_NET" NET_MODE "$NET_MODE" MAC "$MAC"
[[ "$NET_MODE" == "macvtap" ]] && printf '    %-10s %s\n' MACVTAP_SRC "$MACVTAP_SOURCE"

# ---- SSH 鍵 -------------------------------------------------------------
if [[ ! -f "$SSH_PUBKEY" ]]; then
    echo "==> SSH 鍵が無いので生成: ${SSH_PUBKEY%.pub}"
    ssh-keygen -t ed25519 -N '' -f "${SSH_PUBKEY%.pub}"
fi
PUBKEY_CONTENT="$(cat "$SSH_PUBKEY")"

# ---- 既存 VM のチェック ------------------------------------------------
if $VIRSH dominfo "$VM_NAME" &>/dev/null; then
    echo "ERROR: VM '$VM_NAME' は既に存在します。削除するには:" >&2
    echo "    ./scripts/03-destroy-node-vm.sh $VM_NAME" >&2
    exit 1
fi

# ---- ベースイメージ取得（初回のみ）---------------------------------
if [[ ! -f "$BASE_IMG" ]]; then
    echo "==> cloud イメージをダウンロード: $IMG_URL"
    TMP_IMG="$(mktemp /tmp/cloudimg-XXXXXX.img)"
    curl -fL --progress-bar -o "$TMP_IMG" "$IMG_URL"
    sudo mv "$TMP_IMG" "$BASE_IMG"
fi

# ---- VM ディスク作成（ベースをコピーしてリサイズ）-----------------
echo "==> ディスク作成: $DISK_PATH (${DISK_GB}G)"
sudo cp --reflink=auto "$BASE_IMG" "$DISK_PATH"
sudo qemu-img resize "$DISK_PATH" "${DISK_GB}G"

# ---- ネットワーク設定 -------------------------------------------------
NETCFG=""
case "$NET_MODE" in
  bridge|macvtap)
    # LAN 直結。libvirt DHCP は無いので cloud-init で静的 IP + 経路。
    NETCFG="$(mktemp "/tmp/${VM_NAME}-netcfg-XXXXXX.yaml")"
    _routes=""
    IFS=';' read -ra _rlist <<< "${VM_ROUTES//[[:space:]]/}"
    for r in "${_rlist[@]}"; do
        [[ -z "$r" ]] && continue
        _routes+=$'\n'"      - to: ${r%%,*}"$'\n'"        via: ${r##*,}"
    done
    cat > "$NETCFG" <<EOF
version: 2
ethernets:
  primary:
    match:
      macaddress: "${MAC}"
    set-name: primary
    dhcp4: false
    addresses: [${VM_IP}/24]
    nameservers:
      addresses: [${VM_NAMESERVERS// /, }]
    routes:
      - to: default
        via: ${VM_GATEWAY}${_routes}
EOF
    echo "==> ${NET_MODE} モード: ${VM_IP}/24 gw ${VM_GATEWAY}  routes: ${VM_ROUTES}"
    [[ "$NET_MODE" == "macvtap" ]] && \
        echo "    （macvtap: この KVM ホスト自身と VM は直接通信不可。Ansible は別ホストから）"
    ;;
  *)
    echo "==> MAC $MAC / IP $VM_IP を '$LIBVIRT_NET' に予約（NAT）"
    $VIRSH net-update "$LIBVIRT_NET" delete ip-dhcp-host \
        "<host mac='$MAC'/>" --live --config 2>/dev/null || true
    $VIRSH net-update "$LIBVIRT_NET" add ip-dhcp-host \
        "<host mac='$MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config
    ;;
esac

# ---- cloud-init user-data --------------------------------------------
USERDATA="$(mktemp "/tmp/${VM_NAME}-userdata-XXXXXX.yaml")"
trap 'rm -f "$USERDATA" "$NETCFG"' EXIT
cat > "$USERDATA" <<EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.${GUEST_DOMAIN}
manage_etc_hosts: true
users:
  - name: ${GUEST_USER}
    groups: [sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${PUBKEY_CONTENT}
ssh_pwauth: false
package_update: true
package_upgrade: false
runcmd:
  - [ swapoff, -a ]
  - [ sed, -ri, '/\\sswap\\s/s/^/#/', /etc/fstab ]
EOF

# ---- VM 作成 ---------------------------------------------------------
case "$NET_MODE" in
  bridge)
    NET_ARG="bridge=${LIBVIRT_NET},model=virtio,mac=${MAC}"
    CI_ARG="user-data=${USERDATA},network-config=${NETCFG}"
    ;;
  macvtap)
    # 既存 NIC に macvtap（bridge モード）。ホスト側のブリッジ作成不要。
    NET_ARG="type=direct,source=${MACVTAP_SOURCE},source_mode=bridge,model=virtio,mac=${MAC}"
    CI_ARG="user-data=${USERDATA},network-config=${NETCFG}"
    ;;
  *)
    NET_ARG="network=${LIBVIRT_NET},model=virtio,mac=${MAC}"
    CI_ARG="user-data=${USERDATA}"
    ;;
esac

echo "==> virt-install"
sudo virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$VM_NAME" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --os-variant "$OS_VARIANT" \
    --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
    --network "$NET_ARG" \
    --cloud-init "$CI_ARG" \
    --import \
    --graphics none \
    --noautoconsole

# ---- 起動待ち ------------------------------------------------------
if [[ "$NET_MODE" == "macvtap" ]]; then
    # macvtap ではこのホストから VM に届かない。console で cloud-init を待つ。
    echo "==> macvtap のため SSH 確認はスキップ。cloud-init 完了まで ~60 秒待機"
    sleep 60
    echo "    確認は別ホストから: ssh ${GUEST_USER}@${VM_IP}"
    echo "    or このホストで: $VIRSH console $VM_NAME"
else
    echo "==> VM の SSH 起動を待機 (${VM_IP})"
    for i in $(seq 1 60); do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
               -o ConnectTimeout=5 "${GUEST_USER}@${VM_IP}" true 2>/dev/null; then
            echo "==> SSH OK"
            break
        fi
        sleep 5
        [[ $i -eq 60 ]] && echo "WARN: SSH タイムアウト。'$VIRSH console $VM_NAME' で確認を" >&2
    done
fi

# ---- 次の手順 -----------------------------------------------------
INV_GROUP="control_plane"; [[ "$ROLE" =~ ^(worker|w)$ ]] && INV_GROUP="workers"
cat <<EOF

============================================================
VM '${VM_NAME}' 作成完了。

  SSH:       ssh ${GUEST_USER}@${VM_IP}
  コンソール:  $VIRSH console ${VM_NAME}

ansible/inventory.ini の [${INV_GROUP}] にこの行を追加:

  ${VM_NAME} ansible_host=${VM_IP}

その後:

  cd ansible && ansible-playbook site.yml
============================================================
EOF
