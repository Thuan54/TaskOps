#!/usr/bin/env bash
# backup.sh - Sao lưu PostgreSQL + nội dung web thành archive có timestamp
#
# Archive gồm:
#   db.sql.gz
#   web_app.tar.gz
#   web_status.tar.gz
#
# F09: Retention tự động
# F10: Đồng bộ sang VM2 bằng Rsync/SSH

set -Eeuo pipefail
umask 077

# ===== XÁC ĐỊNH THƯ MỤC VÀ NẠP THƯ VIỆN =====
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

# ===== CẤU HÌNH =====
: "${DB_NAME:=taskops}"
: "${WEB_APP_DIR:=/var/www/taskops-app}"
: "${WEB_STATUS_DIR:=/var/www/taskops-status}"

: "${BACKUP_DIR:=/srv/backup}"
: "${MIN_FREE_MB:=500}"
: "${RETENTION_DAYS:=7}"

# ===== CẤU HÌNH ĐỒNG BỘ VM2 (F10) =====
: "${REMOTE_BACKUP_HOST:=todo-backup}"
: "${REMOTE_BACKUP_DIR:=/srv/backup/incoming/}"
: "${REMOTE_BACKUP_USER:=ubuntu}"
: "${SSH_KEY:=/root/.ssh/id_ed25519_taskops}"
: "${SYNC_ENABLED:=1}"

# ===== LOG & ALERT FALLBACK =====
if ! declare -F log >/dev/null; then
    log() {
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2
    }
fi

if ! declare -F send_alert >/dev/null; then
    send_alert() {
        return 0
    }
fi

if ! declare -F die >/dev/null; then
    die() {
        local code=1

        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
            code="$1"
            shift
        fi

        log ERROR "$*"
        exit "$code"
    }
fi

# ===== BIẾN TOÀN CỤC =====
WORK_DIR=""
ALERT_SENT=0

# ===== DỌN DẸP =====
cleanup() {
    local exit_code=$?

    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR" || {
            log WARN "Không thể xóa thư mục tạm: $WORK_DIR"
        }
    fi

    if (( exit_code != 0 && ! ALERT_SENT )); then
        send_alert CRIT \
            "Sao lưu thất bại (exit code: $exit_code)" || true
    fi

    return "$exit_code"
}

on_error() {
    local line="$1"
    local exit_code="$2"

    log ERROR "Backup thất bại tại dòng $line (exit code: $exit_code)"

    if (( ! ALERT_SENT )); then
        ALERT_SENT=1
        send_alert CRIT \
            "Sao lưu thất bại tại dòng $line (mã lỗi: $exit_code)" || true
    fi
}

trap 'on_error "$LINENO" "$?"' ERR
trap cleanup EXIT

# ===== PREFLIGHT =====
preflight() {
    # Kiểm tra quyền root.
    if declare -F require_root >/dev/null; then
        require_root
    elif [[ $EUID -ne 0 ]]; then
        die "Cần chạy bằng root (sudo)"
    fi

    # Kiểm tra cấu hình số.
    [[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] ||
        die "MIN_FREE_MB không hợp lệ"

    (( MIN_FREE_MB > 0 )) ||
        die "MIN_FREE_MB phải lớn hơn 0"

    [[ "$SYNC_ENABLED" == "0" || "$SYNC_ENABLED" == "1" ]] ||
        die "SYNC_ENABLED chỉ nhận 0 hoặc 1"

    # Kiểm tra thư mục backup.
    [[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]] ||
        die "Thư mục backup không tồn tại hoặc không ghi được: $BACKUP_DIR"

    # Kiểm tra các thư mục web.
    local d

    for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
        [[ -d "$d" && -r "$d" ]] ||
            die "Thiếu thư mục web hoặc không có quyền đọc: $d"
    done

    # Kiểm tra PostgreSQL.
    pg_isready -q ||
        die "PostgreSQL không sẵn sàng"

    # Kiểm tra dung lượng.
    local free_mb

    free_mb=$(
        df --output=avail -BM "$BACKUP_DIR" |
            tail -n 1 | tr -dc '0-9'
    )

    [[ "$free_mb" =~ ^[0-9]+$ ]] ||
        die "Không xác định được dung lượng đĩa"

    if (( free_mb < MIN_FREE_MB )); then
        die "Đĩa còn ${free_mb}MB, thấp hơn ngưỡng ${MIN_FREE_MB}MB"
    fi

    log INFO "Preflight OK (còn trống ${free_mb}MB)"
}

# ===== F09: RETENTION =====
apply_retention() {
    if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] ||
        (( RETENTION_DAYS < 1 )); then

        log WARN "RETENTION_DAYS không hợp lệ: '$RETENTION_DAYS'"
        return 1
    fi

    local max_age_min=$(( RETENTION_DAYS * 24 * 60 ))
    local file deleted=0

    log INFO "Retention: xóa backup cũ hơn ${RETENTION_DAYS} ngày"

    while IFS= read -r -d '' file; do
        if rm -f -- "$file"; then
            log INFO "Đã xóa bản backup cũ: $file"
            ((deleted += 1))
        else
            log WARN "Không thể xóa: $file"
            return 1
        fi
    done < <(
        find "$BACKUP_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'taskops_backup_*.tar' \
            -mmin "+$max_age_min" \
            -print0
    )

    log INFO "Retention hoàn tất: đã xóa $deleted bản"
}

# ===== F10: ĐỒNG BỘ VM2 QUA RSYNC =====
sync_to_remote() {
    local archive_path="$1"
    local destination
    local ssh_command
    local -a ssh_opts

    if [[ "$SYNC_ENABLED" != "1" ]]; then
        log INFO "Đồng bộ VM2 đang tắt, bỏ qua"
        return 0
    fi

    if ! command -v rsync >/dev/null 2>&1; then
        log WARN "Không tìm thấy rsync, bỏ qua đồng bộ VM2"
        return 1
    fi

    if ! command -v ssh >/dev/null 2>&1; then
        log WARN "Không tìm thấy ssh, bỏ qua đồng bộ VM2"
        return 1
    fi

    [[ -n "$REMOTE_BACKUP_HOST" ]] || {
        log WARN "REMOTE_BACKUP_HOST chưa được cấu hình"
        return 1
    }

    [[ -n "$REMOTE_BACKUP_DIR" ]] || {
        log WARN "REMOTE_BACKUP_DIR chưa được cấu hình"
        return 1
    }

    log INFO "Bắt đầu đồng bộ sang VM2: $REMOTE_BACKUP_HOST"

    if [[ -n "$REMOTE_BACKUP_USER" ]]; then
        destination="${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_DIR}"
    else
        destination="${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_DIR}"
    fi

    ssh_opts=(
        -o BatchMode=yes
        -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new
    )

    if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
        ssh_opts+=(-i "$SSH_KEY")
    fi

    # Escape từng tham số trước khi truyền cho rsync -e.
    printf -v ssh_command '%q ' ssh "${ssh_opts[@]}"

    if rsync -az \
        --partial \
        -e "$ssh_command" \
        -- "$archive_path" "$destination"; then

        log INFO "Đồng bộ VM2 thành công: $destination"

        send_alert INFO \
            "Đã đồng bộ backup sang VM2 ($REMOTE_BACKUP_HOST): $(basename "$archive_path")" \
            || log WARN "Không gửi được cảnh báo đồng bộ thành công"

        return 0
    fi

    log WARN "Đồng bộ VM2 thất bại, backup cục bộ vẫn an toàn"

    send_alert WARN \
        "Đồng bộ Rsync sang VM2 ($REMOTE_BACKUP_HOST) thất bại" \
        || true

    return 1
}

# ===== KIỂM TRA ARCHIVE SAU KHI TẠO =====
validate_archive() {
    local archive="$1"
    local expected actual

    expected=$(
        printf '%s\n' \
            db.sql.gz \
            web_app.tar.gz \
            web_status.tar.gz |
            sort
    )

    actual=$(tar -tf "$archive" | sort) ||
        die "Archive không đọc được"

    [[ "$actual" == "$expected" ]] ||
        die "Archive không chứa đúng 3 thành phần bắt buộc"

    gzip -t "$WORK_DIR/db.sql.gz" ||
        die "Database dump bị hỏng"

    tar -tzf "$WORK_DIR/web_app.tar.gz" >/dev/null ||
        die "web_app.tar.gz bị hỏng"

    tar -tzf "$WORK_DIR/web_status.tar.gz" >/dev/null ||
        die "web_status.tar.gz bị hỏng"

    log INFO "Kiểm tra archive thành công"
}

# ===== LUỒNG BACKUP CHÍNH =====
main() {
    preflight

    local ts final size

    ts=$(date +%F_%H%M%S)

    # Thêm PID để tránh ghi đè khi chạy đồng thời.
    final="$BACKUP_DIR/taskops_backup_${ts}_$$.tar"

    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")

    # Backup database.
    log INFO "Dump database $DB_NAME"

    sudo -u postgres pg_dump "$DB_NAME" |
        gzip > "$WORK_DIR/db.sql.gz"

    gzip -t "$WORK_DIR/db.sql.gz" ||
        die "Database dump không hợp lệ"

    # Backup web.
    log INFO "Nén nội dung web"

    tar -czf "$WORK_DIR/web_app.tar.gz" \
        -C "$(dirname "$WEB_APP_DIR")" \
        "$(basename "$WEB_APP_DIR")"

    tar -czf "$WORK_DIR/web_status.tar.gz" \
        -C "$(dirname "$WEB_STATUS_DIR")" \
        "$(basename "$WEB_STATUS_DIR")"

    # Kiểm tra từng archive web.
    tar -tzf "$WORK_DIR/web_app.tar.gz" >/dev/null ||
        die "Không thể kiểm tra web_app.tar.gz"

    tar -tzf "$WORK_DIR/web_status.tar.gz" >/dev/null ||
        die "Không thể kiểm tra web_status.tar.gz"

    # Gom thành archive tổng.
    log INFO "Gom thành archive"

    tar -cf "$WORK_DIR/final.tar" \
        -C "$WORK_DIR" \
        db.sql.gz \
        web_app.tar.gz \
        web_status.tar.gz

    # Kiểm tra archive tổng trước khi công bố.
    validate_archive "$WORK_DIR/final.tar"

    chmod 600 "$WORK_DIR/final.tar"

    # Kiểm tra tên file đích trước khi di chuyển.
    [[ ! -e "$final" ]] ||
        die "File backup đã tồn tại: $final"

    # Cùng filesystem nên thao tác rename có tính nguyên tử.
    mv -- "$WORK_DIR/final.tar" "$final"

    size=$(du -h "$final" | cut -f1)

    log INFO "Backup hoàn tất: $final ($size)"

    send_alert INFO \
        "Sao lưu thành công: $(basename "$final") ($size)" ||
        log WARN "Không gửi được cảnh báo backup thành công"

    # F10: Đồng bộ VM2.
    if ! sync_to_remote "$final"; then
        log WARN "Backup cục bộ thành công nhưng đồng bộ VM2 thất bại"
    fi

    # F09: Retention.
    if ! apply_retention; then
        log WARN "Retention gặp sự cố, backup mới vẫn được giữ nguyên"

        send_alert WARN \
            "Backup hoàn tất nhưng retention gặp sự cố" || true
    fi

    # Xuất đường dẫn archive.
    printf '%s\n' "$final"
}

main "$@"
