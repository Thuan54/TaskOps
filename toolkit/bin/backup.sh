#!/usr/bin/env bash
# backup.sh - Sao lưu PostgreSQL + nội dung web thành một archive có timestamp
# Archive gồm: db.sql.gz, web_app.tar.gz, web_status.tar.gz
# -E: để trap ERR hoạt động bên trong các hàm
set -Eeuo pipefail

# Xác định thư mục lib và nạp thư viện dùng chung nếu có
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" &>/dev/null && pwd)"

if [[ -f "$LIB_DIR/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/common.sh"
fi

cd /  

# ===== CẤU HÌNH (hỗ trợ biến môi trường hoặc cấu hình mặc định) =====
: "${DB_NAME:=taskops}"
: "${WEB_APP_DIR:=/var/www/taskops-app}"
: "${WEB_STATUS_DIR:=/var/www/taskops-status}"
: "${BACKUP_DIR:=/srv/backup}"
: "${MIN_FREE_MB:=500}"
: "${RETENTION_DAYS:=7}"

# ===== HÀM LOG & LỖI DỰ PHÒNG (nếu chưa nạp lib/common.sh) =====
if ! declare -F log >/dev/null; then
    log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
fi
if ! declare -F die >/dev/null; then
    die() {
        local code=1 msg=""
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
            code="$1"
            shift
        fi
        msg="$*"
        log ERROR "$msg"
        exit "$code"
    }
fi

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

# RETENTION: xóa bản backup tồn tại quá lâu
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

    # Retention lỗi thì chỉ cảnh báo, vì bản backup mới vẫn hợp lệ.
    if ! apply_retention; then
        log WARN "Retention gặp lỗi, backup mới vẫn hợp lệ"
    fi

    echo "$final"
}

main "$@"
