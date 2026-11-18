#!/usr/bin/env bash
# backup.sh - Sao lưu PostgreSQL + nội dung web thành một archive có timestamp
# Archive gồm: db.sql.gz, web_app.tar.gz, web_status.tar.gz
# -E: để trap ERR hoạt động bên trong các hàm
set -Eeuo pipefail

# Xác định thư mục lib và nạp alert.sh trước khi cd /
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" &>/dev/null && pwd)"

if [[ -f "$LIB_DIR/alert.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/alert.sh"
fi
if ! declare -F send_alert >/dev/null; then
    send_alert() { :; }
fi

cd /  

# Gán cứng, sau này lấy từ interface
DB_NAME="taskops_db"
WEB_APP_DIR="/var/www/taskops-app"
WEB_STATUS_DIR="/var/www/taskops-status"
BACKUP_DIR="/srv/backup"
MIN_FREE_MB=500
RETENTION_DAYS=7

# Giả lập hàm log (sau này lấy của F1)
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
# Báo lỗi, gửi alert và dừng script
die() {
    log ERROR "$1"
    send_alert CRIT "Sao lưu thất bại: $1"
    exit 1
}

WORK_DIR=""
cleanup() {
    # Nếu WORK_DIR không rỗng và thư mục có tồn tại trên ổ đĩa
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
on_error() {
    local exit_code=$?
    log ERROR "Backup thất bại ở dòng $1 (exit code: $exit_code)"
    send_alert CRIT "Sao lưu thất bại tại dòng $1 (mã lỗi: $exit_code)"
}

# Lắng nghe tín hiệu ERR,khi có lỗi nó kích hoạt hàm on_error() kèm theo số dòng
trap 'on_error $LINENO' ERR
# Gọi hàm cleanup khi tiến trình thành công hoặc thất bại để dọn dẹp thư mục tạm
trap cleanup EXIT

# Kiểm tra trước khi thực hiện backup
preflight() {
    # Lệnh backup yêu cầu chạy với quyền sudo
    if [[ $EUID -ne 0 ]]; then
        die "Cần chạy bằng root (sudo)"
    fi

    # Thực mục backup phải tồn tại
    if [[ ! -d "$BACKUP_DIR" || ! -w "$BACKUP_DIR" ]]; then
        die "Thư mục backup không tồn tại hoặc không ghi được: $BACKUP_DIR"
    fi

    # biến dùng duyệt đường dẫn thư mục web
    local d 
    for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
        # Thư mục web phải tồn tại
        if [[ ! -d "$d" ]]; then
            die "Thiếu thư mục web: $d"
        fi
    done

    # PostgreSQL phải hoạt động
    if ! pg_isready -q; then
        die "PostgreSQL không sẵn sàng"
    fi

    # Biến lưu dung lượng đĩa trống
    local free_mb
    # Lấy dung lượng trống của phân vùng hiện tại (MB)
    free_mb=$(df --output=avail -BM "$BACKUP_DIR" | tail -n 1 | tr -dc '0-9')

    # Nếu dung lượng trống hiện tại nhỏ hơn ngưỡng tối thiểu cho phép để backup
    if (( free_mb < MIN_FREE_MB )); then
        die "Đĩa còn ${free_mb}MB, thấp hơn ngưỡng ${MIN_FREE_MB}MB"
    fi

    # Thành công thì in log thông báo
    log INFO "Preflight OK (còn trống ${free_mb}MB)"
}

# RETENTION: xóa bản backup tồn tại quá lâu
apply_retention() {
    # RETENTION_DAYS phải là số nguyên >= 1.
    # Nếu rỗng/chữ/0 thì find sẽ khớp MỌI file và xóa sạch backup.
    if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 1 )); then
        log ERROR "RETENTION_DAYS không hợp lệ: '$RETENTION_DAYS' (cần số nguyên >= 1)"
        return 1
    fi

    # Đổi ngày ra phút để so sánh chính xác
    local max_age_min=$(( RETENTION_DAYS * 24 * 60 ))
    # file dùng lưu đường dẫn file quét được, deleted đếm số lượng file đã xóa
    local file deleted=0

    log INFO "Retention: xóa backup cũ hơn ${RETENTION_DAYS} ngày"

    # find liệt kê file cần xóa:
    #   -maxdepth 1  : chỉ xét trực tiếp trong BACKUP_DIR, không vào thư mục con
    #   -type f      : chỉ file thường (bỏ qua thư mục .work.*)
    #   -name        : chỉ file đúng mẫu tên của script backup
    #   -mmin +N     : sửa đổi lần cuối cách đây hơn N phút
    # Vòng while đọc từng tên file (read -d '' khớp với -print0).
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

    # ts là timestamp, final lưu đường dẫn file backup hoàn chỉnh
    local ts final

    ts=$(date +%F_%H%M%S)

    # Đường dẫn và tên tệp backup
    final="$BACKUP_DIR/taskops_backup_${ts}.tar"

    # Tạo thư mục làm việc dạng ẩn để lưu file nháp trong quá trình xử lý
    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")

    # Bắt đầu backup database
    log INFO "Dump database $DB_NAME"
    # Chạy quyền sudo để backup database
    sudo -u postgres pg_dump "$DB_NAME" | gzip > "$WORK_DIR/db.sql.gz"
    gzip -t "$WORK_DIR/db.sql.gz"

    # Bắt đầu backup nội dung web
    log INFO "Nén nội dung web"
    tar -czf "$WORK_DIR/web_app.tar.gz"    -C "$(dirname "$WEB_APP_DIR")"    "$(basename "$WEB_APP_DIR")"
    tar -czf "$WORK_DIR/web_status.tar.gz" -C "$(dirname "$WEB_STATUS_DIR")" "$(basename "$WEB_STATUS_DIR")"

    # Gôm file backup database và web lại thành archive
    log INFO "Gom thành archive"
    tar -cf "$WORK_DIR/final.tar" -C "$WORK_DIR" db.sql.gz web_app.tar.gz web_status.tar.gz
    tar -tf "$WORK_DIR/final.tar" > /dev/null

    # Chỉ có chủ sở hữu mới đọc và ghi được vào file backup
    chmod 600 "$WORK_DIR/final.tar"
    # Chuyển archive sang folder lưu trữ chính thức
    # thư mục tạm tự động được xóa do có cấu hình trap cleanup EXIT
    mv "$WORK_DIR/final.tar" "$final"

    local size
    size=$(du -h "$final" | cut -f1)
    log INFO "Backup xong: $final ($size)"
    send_alert INFO "Sao lưu thành công: $(basename "$final") ($size)"

    # Retention lỗi thì chỉ cảnh báo, vì bản backup mới vẫn hợp lệ.
    if ! apply_retention; then
        log WARN "Retention gặp lỗi, backup mới vẫn hợp lệ"
        send_alert WARN "Sao lưu hoàn tất nhưng dọn dẹp bản cũ (retention) gặp sự cố"
    fi

    echo "$final"
}

main "$@"