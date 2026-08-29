#!/usr/bin/env bash
#
# 02-create-node-vm.sh
# Ubuntu cloud イメージ + cloud-init で Kubernetes ノード用の VM を作成する。
#
# 設定は config.env に集約。ここでは「どのノードを作るか」だけ指定する。
#
# 使い方:
#   ./scripts/02-create-node-vm.sh                        # control-plane を作成
#   ROLE=worker NODE_NUM=1 ./scripts/02-create-node-vm.sh # worker-1 を追加
#   ROLE=worker NODE_NUM=2 VCPUS=4 RAM_MB=8192 \          # スペットだけ上書き
#       ./scripts/02-create-node-vm.sh
#
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
setup_logging "$0"
resolve_node

BASE_IMG="${POOL_DIR}/$(basename "$IMG_URL")"
DISK_PATH="${POOL_DIR}/${VM_NAME}.qcow2"
MAC="$(mac_for "$VM_NAME")"

echo "==> 設定:"
printf '    %-10s %s\n' ROLE "$ROLE" NAME "$VM_NAME" IP "$VM_IP" \
    VCPUS "$VCPUS" RAM_MB "$RAM_MB" DISK_GB "$DISK_GB" \
    NET "$LIBVIRT_NET" MAC "$MAC"

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

# ---- 固定 IP（libvirt ネットワークに DHCP 予約を追加）-------------
echo "==> MAC $MAC / IP $VM_IP を '$LIBVIRT_NET' に予約"
$VIRSH net-update "$LIBVIRT_NET" delete ip-dhcp-host \
    "<host mac='$MAC'/>" --live --config 2>/dev/null || true
$VIRSH net-update "$LIBVIRT_NET" add ip-dhcp-host \
    "<host mac='$MAC' name='$VM_NAME' ip='$VM_IP'/>" --live --config

# ---- cloud-init user-data --------------------------------------------
USERDATA="$(mktemp "/tmp/${VM_NAME}-userdata-XXXXXX.yaml")"
trap 'rm -f "$USERDATA"' EXIT
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
echo "==> virt-install"
sudo virt-install \
    --connect "$LIBVIRT_URI" \
    --name "$VM_NAME" \
    --memory "$RAM_MB" \
    --vcpus "$VCPUS" \
    --cpu host-passthrough \
    --os-variant "$OS_VARIANT" \
    --disk "path=${DISK_PATH},format=qcow2,bus=virtio" \
    --network "network=${LIBVIRT_NET},model=virtio,mac=${MAC}" \
    --cloud-init "user-data=${USERDATA}" \
    --import \
    --graphics none \
    --noautoconsole

# ---- 起動待ち ------------------------------------------------------
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
