# shellcheck shell=bash
# =============================================================================
# lib.sh  —  scripts/*.sh 共通の関数と設定読み込み
#   すべてのスクリプト冒頭で:  source "$(dirname "$0")/lib.sh"
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- config.env を読み込む -------------------------------------------------
if [[ -f "${REPO_ROOT}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/config.env"
else
    echo "ERROR: ${REPO_ROOT}/config.env が見つかりません" >&2
    exit 1
fi

VIRSH="virsh --connect ${LIBVIRT_URI}"

# ---- 画面 + ログファイルの両方へ出力 ------------------------------------
# 使い方:  setup_logging "$0"
setup_logging() {
    local name; name="$(basename "$1" .sh)"
    local dir="${REPO_ROOT}/logs"
    mkdir -p "$dir"
    local file="${dir}/${name}-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$file") 2>&1
    echo "==> ログ: $file"
}

# ---- VM 名から決定的に MAC を生成 --------------------------------------
# 同じ名前なら常に同じ MAC → 作り直しても DHCP 予約が一致する。
mac_for() {
    local h; h="$(echo -n "$1" | md5sum | cut -c1-6)"
    echo "52:54:00:${h:0:2}:${h:2:2}:${h:4:2}"
}

# ---- ロール + ノード番号 → NAME / IP / スペックを決定 -----------------
# 環境変数 ROLE(control-plane|worker), NODE_NUM を見る。
# VM_NAME / VM_IP / VCPUS / RAM_MB / DISK_GB が明示されていれば最優先。
resolve_node() {
    ROLE="${ROLE:-control-plane}"
    case "$ROLE" in
        control-plane|cp)
            VM_NAME="${VM_NAME:-${CP_NAME}}"
            VM_IP="${VM_IP:-${CP_IP}}"
            VCPUS="${VCPUS:-${CP_VCPUS}}"
            RAM_MB="${RAM_MB:-${CP_RAM_MB}}"
            DISK_GB="${DISK_GB:-${CP_DISK_GB}}"
            ;;
        worker|w)
            NODE_NUM="${NODE_NUM:?ROLE=worker のときは NODE_NUM=1,2,3… が必要}"
            VM_NAME="${VM_NAME:-${WORKER_NAME_PREFIX}${NODE_NUM}}"
            VM_IP="${VM_IP:-${NET_PREFIX}.$((WORKER_IP_BASE + NODE_NUM))}"
            VCPUS="${VCPUS:-${WORKER_VCPUS}}"
            RAM_MB="${RAM_MB:-${WORKER_RAM_MB}}"
            DISK_GB="${DISK_GB:-${WORKER_DISK_GB}}"
            ;;
        *)
            echo "ERROR: ROLE は control-plane / worker のいずれか (指定: $ROLE)" >&2
            exit 1
            ;;
    esac
}
