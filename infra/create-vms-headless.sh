#!/usr/bin/env bash
# ==============================================================================
# Script Name : create-vms-headless.sh
# Description : Tự động dựng 2 máy ảo (todo-primary & todo-backup) từ con số 0
#               hoàn toàn bằng dòng lệnh (KHÔNG CẦN GIAO DIỆN UI)
#               Hỗ trợ 2 chế độ: Multipass (KVM/QEMU) hoặc VMware CLI (vmrun)
# ==============================================================================

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_GREEN=$'\033[0;32m'
readonly C_CYAN=$'\033[0;36m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_RED=$'\033[0;31m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/bootstrap-vm.sh"
VERIFY_SCRIPT="${SCRIPT_DIR}/verify-group-a.sh"

log_info()    { printf "%b[INFO]%b %s\n" "${C_CYAN}" "${C_RESET}" "$*"; }
log_success() { printf "%b[OK]%b   %s\n" "${C_GREEN}" "${C_RESET}" "$*"; }
log_warn()    { printf "%b[WARN]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*"; }
log_error()   { printf "%b[ERR]%b  %s\n" "${C_RED}" "${C_RESET}" "$*" >&2; }

usage() {
    cat <<EOF
Cách dùng: bash $(basename "$0") [OPTION]

Tùy chọn:
  --multipass          Tự động tạo 2 VM (todo-primary, todo-backup) từ đầu bằng Multipass CLI,
                       tự gắn ổ phụ 10GB và chạy luôn bootstrap-vm.sh (Không cần UI).
  --vmware-add-disk    Tự động tạo file ổ cứng 10GB (.vmdk) và bật VMware chạy ngầm (nogui).
                       Cần truyền đường dẫn file .vmx: --vmware-add-disk /path/to/vm.vmx
  -h, --help           Hiển thị hướng dẫn này.
EOF
}

# ------------------------------------------------------------------------------
# Chế độ 1: Tự động hóa 100% từ con số 0 với Multipass (Không cần mở UI)
# ------------------------------------------------------------------------------
provision_with_multipass() {
    if ! command -v multipass &>/dev/null; then
        log_info "Chưa cài Multipass. Đang cài đặt Multipass qua snap..."
        sudo snap install multipass
    fi

    for vm_name in "todo-primary" "todo-backup"; do
        if multipass info "${vm_name}" &>/dev/null; then
            log_info "Máy ảo '${vm_name}' đã tồn tại. Đang bật máy..."
            multipass start "${vm_name}" || true
        else
            log_info "Đang tạo máy ảo '${vm_name}' (Ubuntu 22.04, 2 CPU, 2GB RAM, 20GB Disk)..."
            multipass launch 22.04 --name "${vm_name}" --cpus 2 --memory 2G --disk 20G
        fi

        log_info "Đang đẩy bootstrap-vm.sh và verify-group-a.sh vào '${vm_name}'..."
        multipass transfer "${BOOTSTRAP_SCRIPT}" "${vm_name}:/home/ubuntu/bootstrap-vm.sh"
        multipass transfer "${VERIFY_SCRIPT}" "${vm_name}:/home/ubuntu/verify-group-a.sh"
    done

    log_info "Đang tạo ổ đĩa khối 10GB (/dev/loop10) và chạy bootstrap cho 'todo-primary'..."
    # shellcheck disable=SC2016
    multipass exec todo-primary -- sudo bash -c '
        if [ ! -f /var/lib/backup-disk-10g.img ]; then
            fallocate -l 10G /var/lib/backup-disk-10g.img
        fi
        LOOP_DEV=$(losetup -j /var/lib/backup-disk-10g.img | cut -d: -f1)
        if [ -z "${LOOP_DEV}" ]; then
            LOOP_DEV=$(losetup -fP --show /var/lib/backup-disk-10g.img)
        fi
        echo "Using loop block device: ${LOOP_DEV}"
        bash /home/ubuntu/bootstrap-vm.sh --mode vm1 --disk "${LOOP_DEV}"
    '

    log_info "Đang chạy bootstrap cho 'todo-backup'..."
    multipass exec todo-backup -- sudo bash /home/ubuntu/bootstrap-vm.sh --mode vm2

    log_success "Hoàn tất khởi tạo cả 2 VM không cần UI! Kiểm tra kết quả trên todo-primary:"
    multipass exec todo-primary -- sudo bash /home/ubuntu/verify-group-a.sh || true
}

# ------------------------------------------------------------------------------
# Chế độ 2: Điều khiển VMware Workstation ngầm không cần mở giao diện (vmrun CLI)
# ------------------------------------------------------------------------------
provision_vmware_headless() {
    local vmx_path="${1:-}"
    if [ -z "${vmx_path}" ] || [ ! -f "${vmx_path}" ]; then
        log_error "Vui lòng truyền đường dẫn file .vmx hợp lệ của máy ảo VMware."
        exit 1
    fi

    local vm_dir
    vm_dir="$(dirname "${vmx_path}")"
    local disk_10gb="${vm_dir}/backup-10gb.vmdk"

    log_info "1. Tắt máy ảo tạm thời để gắn ổ cứng 10GB..."
    vmrun -T ws stop "${vmx_path}" soft 2>/dev/null || true

    if [ ! -f "${disk_10gb}" ]; then
        log_info "2. Đang tạo ổ cứng ảo 10GB bằng vmware-vdiskmanager (không cần UI)..."
        vmware-vdiskmanager -c -s 10GB -a lsilogic -t 0 "${disk_10gb}"
    fi

    if ! grep -q "backup-10gb.vmdk" "${vmx_path}"; then
        log_info "3. Đang gắn ổ 10GB vào cấu hình máy ảo (.vmx)..."
        cat >> "${vmx_path}" <<EOF
scsi0:1.present = "TRUE"
scsi0:1.fileName = "backup-10gb.vmdk"
scsi0:1.redo = ""
EOF
    fi

    log_info "4. Đang khởi động máy ảo ở chế độ chạy ngầm (Headless - nogui)..."
    vmrun -T ws start "${vmx_path}" nogui
    log_success "Máy ảo đã bật ngầm thành công kèm ổ cứng 10GB!"
}

case "${1:-}" in
    --multipass)
        provision_with_multipass
        ;;
    --vmware-add-disk)
        provision_vmware_headless "${2:-}"
        ;;
    *)
        usage
        ;;
esac
