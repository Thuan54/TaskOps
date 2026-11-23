#!/usr/bin/env bash
# backup.sh - Sao lưu PostgreSQL + nội dung web thành một archive có timestamp
# Archive gồm: db.sql.gz, web_app.tar.gz, web_status.tar.gz
# -E: để trap ERR hoạt động bên trong các hàm
set -Eeuo pipefail

# Xác định thư mục lib và nạp thư viện dùng chung / alert nếu có
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" &>/dev/null && pwd)"

if [[ -f "$LIB_DIR/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/common.sh"
fi

if [[ -f "$LIB_DIR/alert.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/alert.sh"
fi
if ! declare -F send_alert >/dev/null; then
    send_alert() { :; }
fi

cd /  

# ===== CẤU HÌNH (hỗ trợ biến môi trường hoặc cấu hình mặc định) =====
: "${DB_NAME:=taskops}"
: "${WEB_APP_DIR:=/var/www/taskops-app}"
: "${WEB_STATUS_DIR:=/var/www/taskops-status}"
: "${BACKUP_DIR:=/srv/backup}"
: "${MIN_FREE_MB:=500}"
: "${RETENTION_DAYS:=7}"

# ===== CẤU HÌNH ĐỒNG BỘ SANG VM2 (F10 - Rsync) =====
# Hostname hoặc IP của VM2 (theo tài liệu: todo-backup hoặc 192.168.56.20)
: "${REMOTE_BACKUP_HOST:=todo-backup}"
# Thư mục đích nhận bản sao lưu trên VM2
: "${REMOTE_BACKUP_DIR:=/srv/backup/incoming/}"
# User SSH trên VM2 (để trống nếu dùng user hiện tại hoặc cấu hình trong ~/.ssh/config)
: "${REMOTE_BACKUP_USER:=ubuntu}"
# Đường dẫn file SSH key riêng biệt (nếu có, ví dụ ~/.ssh/id_ed25519_taskops)
: "${SSH_KEY:=/root/.ssh/id_ed25519_taskops}"
# Biến cờ bật/tắt đồng bộ: 1 = bật (mặc định), 0 = tắt (hữu ích khi test lab chưa có VM2)
: "${SYNC_ENABLED:=1}"

# ===== HÀM LOG & LỖI DỰ PHÒNG (nếu chưa nạp lib/common.sh) =====
if ! declare -F log >/dev/null; then
    log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
fi
die() {
    local code=1 msg=""
    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        code="$1"
        shift
    fi
    msg="$*"
    log ERROR "$msg"
    send_alert CRIT "Sao lưu thất bại: $msg"
    exit "$code"
}

WORK_DIR=""

# Nếu lib/common.sh chưa đăng ký trap dọn dẹp thì dùng bẫy cục bộ
if ! declare -F register_cleanup >/dev/null; then
    cleanup() {
        if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
            rm -rf "$WORK_DIR"
        fi
    }
    on_error() {
        local exit_code=$?
        log ERROR "Backup thất bại ở dòng $1 (exit code: $exit_code)"
        send_alert CRIT "Sao lưu thất bại tại dòng $1 (mã lỗi: $exit_code)"
    }
    trap 'on_error $LINENO' ERR
    trap cleanup EXIT
fi

# Kiểm tra trước khi thực hiện backup
preflight() {
    # Kiểm tra quyền root (ưu tiên hàm validate nếu có)
    if declare -F require_root >/dev/null; then
        require_root
    elif [[ $EUID -ne 0 ]]; then
        die "Cần chạy bằng root (sudo)"
    fi

    # Thư mục backup phải tồn tại và ghi được
    if [[ ! -d "$BACKUP_DIR" || ! -w "$BACKUP_DIR" ]]; then
        die "Thư mục backup không tồn tại hoặc không ghi được: $BACKUP_DIR"
    fi

    # Thư mục web phải tồn tại
    local d 
    for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
        if [[ ! -d "$d" ]]; then
            die "Thiếu thư mục web: $d"
        fi
    done

    # PostgreSQL phải hoạt động
    if ! pg_isready -q; then
        die "PostgreSQL không sẵn sàng"
    fi

    # Lấy dung lượng trống của phân vùng backup (MB)
    local free_mb
    free_mb=$(df --output=avail -BM "$BACKUP_DIR" | tail -n 1 | tr -dc '0-9')

    if (( free_mb < MIN_FREE_MB )); then
        die "Đĩa còn ${free_mb}MB, thấp hơn ngưỡng ${MIN_FREE_MB}MB"
    fi

    log INFO "Preflight OK (còn trống ${free_mb}MB)"
}

# RETENTION: xóa bản backup tồn tại quá lâu (F09)
apply_retention() {
    # RETENTION_DAYS phải là số nguyên >= 1
    if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 1 )); then
        log ERROR "RETENTION_DAYS không hợp lệ: '$RETENTION_DAYS' (cần số nguyên >= 1)"
        return 1
    fi

    local max_age_min=$(( RETENTION_DAYS * 24 * 60 ))
    local file deleted=0

    log INFO "Retention: xóa backup cũ hơn ${RETENTION_DAYS} ngày"

    while IFS= read -r -d '' file; do
        rm -f -- "$file"      
        log INFO "Đã xóa bản cũ: $file"
        deleted=$(( deleted + 1 ))
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \
                  -name 'taskops_backup_*.tar' \
                  -mmin +"$max_age_min" -print0)

    log INFO "Retention xong: đã xóa ${deleted} bản"
}

# F10: Đồng bộ bản sao lưu sang VM2 bằng Rsync qua kết nối SSH
sync_to_remote() {
    local archive_path="$1"

    # Kiểm tra xem tính năng đồng bộ có đang được bật hay không
    if [[ "${SYNC_ENABLED}" != "1" ]]; then
        log INFO "Đồng bộ từ xa (F10) đang tắt (SYNC_ENABLED != 1), bỏ qua bước rsync"
        return 0
    fi

    # Kiểm tra máy đã cài đặt tiện ích rsync chưa
    if ! command -v rsync >/dev/null 2>&1; then
        log WARN "Không tìm thấy công cụ rsync trên hệ thống, bỏ qua đồng bộ sang VM2"
        return 1
    fi

    log INFO "Bắt đầu đồng bộ bản sao lưu sang VM2 ($REMOTE_BACKUP_HOST)..."

    # Tạo địa chỉ đích theo cú pháp rsync: [user@]host:thư_mục_đích
    local destination
    if [[ -n "${REMOTE_BACKUP_USER}" ]]; then
        destination="${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_DIR}"
    else
        destination="${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_DIR}"
    fi

    # Cấu hình các tham số bảo vệ cho SSH:
    # - BatchMode=yes: Không dừng lại hỏi mật khẩu nếu SSH key chưa được thiết lập (tránh treo script tự động)
    # - ConnectTimeout=10: Hết thời gian chờ sau 10 giây nếu VM2 không phản hồi
    # - StrictHostKeyChecking=accept-new: Tự động lưu fingerprint của host mới mà không làm gián đoạn
    local ssh_opts=(-o "BatchMode=yes" -o "ConnectTimeout=10" -o "StrictHostKeyChecking=accept-new")
    if [[ -n "${SSH_KEY}" && -f "${SSH_KEY}" ]]; then
        ssh_opts+=(-i "${SSH_KEY}")
    fi

    # Tiến hành chạy rsync:
    # -a: chế độ archive (giữ nguyên quyền phân quyền, ngày giờ sửa đổi, ownership)
    # -z: nén dữ liệu trong lúc truyền qua mạng để tiết kiệm băng thông
    # --partial: cho phép truyền tiếp dữ liệu nếu kết nối mạng bị ngắt quãng giữa chừng
    # -e: truyền lệnh SSH kèm các cờ an toàn đã thiết lập ở trên
    if rsync -az --partial -e "ssh ${ssh_opts[*]}" "$archive_path" "$destination"; then
        log INFO "Đã đồng bộ thành công sang VM2: $destination"
        send_alert INFO "Đã đồng bộ bản sao lưu sang VM2 ($REMOTE_BACKUP_HOST): $(basename "$archive_path")"
        return 0
    else
        # Nếu rsync thất bại (do mạng đứt hoặc VM2 tắt), script chỉ ghi cảnh báo WARN
        # chứ KHÔNG làm chết tiến trình backup vì bản sao lưu cục bộ đã tạo xong an toàn.
        log WARN "Đồng bộ Rsync sang VM2 thất bại (kiểm tra SSH key hoặc kết nối tới $REMOTE_BACKUP_HOST)"
        send_alert WARN "Đồng bộ Rsync sang VM2 ($REMOTE_BACKUP_HOST) thất bại"
        return 1
    fi
}

# Luồng backup chính
main() {
    preflight

    local ts final
    ts=$(date +%F_%H%M%S)
    final="$BACKUP_DIR/taskops_backup_${ts}.tar"

    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")
    if declare -F register_cleanup >/dev/null; then
        register_cleanup "$WORK_DIR"
    fi

    # Bắt đầu backup database
    log INFO "Dump database $DB_NAME"
    sudo -u postgres pg_dump "$DB_NAME" | gzip > "$WORK_DIR/db.sql.gz"
    gzip -t "$WORK_DIR/db.sql.gz"

    # Bắt đầu backup nội dung web
    log INFO "Nén nội dung web"
    tar -czf "$WORK_DIR/web_app.tar.gz"    -C "$(dirname "$WEB_APP_DIR")"    "$(basename "$WEB_APP_DIR")"
    tar -czf "$WORK_DIR/web_status.tar.gz" -C "$(dirname "$WEB_STATUS_DIR")" "$(basename "$WEB_STATUS_DIR")"

    # Gom file backup database và web lại thành archive
    log INFO "Gom thành archive"
    tar -cf "$WORK_DIR/final.tar" -C "$WORK_DIR" db.sql.gz web_app.tar.gz web_status.tar.gz
    tar -tf "$WORK_DIR/final.tar" > /dev/null

    chmod 600 "$WORK_DIR/final.tar"
    mv "$WORK_DIR/final.tar" "$final"

    local size
    size=$(du -h "$final" | cut -f1)
    log INFO "Backup xong: $final ($size)"
    send_alert INFO "Sao lưu thành công: $(basename "$final") ($size)"

    # F10: Đồng bộ bản sao lưu sang VM2 qua Rsync
    if ! sync_to_remote "$final"; then
        log WARN "Đồng bộ sang VM2 không thành công nhưng bản sao lưu cục bộ đã hoàn tất"
    fi

    # F09: Áp dụng chính sách lưu giữ (Retention policy)
    # Retention lỗi thì chỉ cảnh báo, vì bản backup mới vẫn hợp lệ.
    if ! apply_retention; then
        log WARN "Retention gặp lỗi, backup mới vẫn hợp lệ"
        send_alert WARN "Sao lưu hoàn tất nhưng dọn dẹp bản cũ (retention) gặp sự cố"
    fi

    echo "$final"
}

main "$@"
