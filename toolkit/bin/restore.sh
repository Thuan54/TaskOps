#!/usr/bin/env bash
# restore.sh - Khôi phục PostgreSQL + nội dung web từ archive do backup.sh tạo ra
#
# Archive đầu vào phải có đúng 3 file bên trong:
#   db.sql.gz, web_app.tar.gz, web_status.tar.gz
#
# Các lớp an toàn (vì restore GHI ĐÈ dữ liệu thật):
#   1. Kiểm tra archive đầy đủ và đọc được TRƯỚC khi đụng vào hệ thống
#   2. Hỏi xác nhận (gõ "yes"), trừ khi dùng -y
#   3. Chụp lại trạng thái hiện tại thành pre_restore_*.tar để còn đường lui
#   4. Nạp DB vào một database TẠM trước; chỉ khi thành công mới thay DB thật
#      => restore lỗi giữa chừng thì DB cũ vẫn nguyên
#   5. Thư mục web cũng được giải nén ra chỗ tạm rồi mới đổi chỗ

# -E: để trap ERR cũng hoạt động bên trong các hàm
# -e: lệnh lỗi thì dừng; -u: biến chưa khai báo thì lỗi; pipefail: lỗi trong pipe tính là lỗi
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" &>/dev/null && pwd)"

if [[ -f "$LIB_DIR/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/common.sh"
fi

# ===== CẤU HÌNH (hỗ trợ biến môi trường hoặc cấu hình mặc định) =====
: "${DB_NAME:=taskops}"
: "${DB_APP_USER:=taskops_app}"            # role của ứng dụng (quyền tối thiểu)
: "${WEB_APP_DIR:=/var/www/taskops-app}"
: "${WEB_STATUS_DIR:=/var/www/taskops-status}"
: "${BACKUP_DIR:=/srv/backup}"
: "${MIN_FREE_MB:=500}"
: "${CHECK_TABLE:=tasks}"                   # bảng dùng để đếm dòng kiểm chứng

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

# chạy 1 lệnh bất kì dưới quyền postgres
as_postgres() { ( cd / && sudo -u postgres "$@" ); }
# chạy các câu lệnh truy vấn, tận dụng as_postgres() để chạy dưới quyền postgres
pg() { as_postgres psql -X -v ON_ERROR_STOP=1 "$@"; }

# ===== BIẾN TOÀN CỤC DÙNG CHO DỌN DẸP =====
WORK_DIR=""            # thư mục tạm giải nén archive
TMP_DB=""              # tên database tạm (rỗng khi không còn tồn tại)
STAGING_DIRS=()        # các thư mục tạm khi đổi chỗ web

cleanup() {
    local s
    for s in "${STAGING_DIRS[@]}"; do
        [[ -d "$s" ]] && rm -rf "$s"
    done

    # Nếu còn DB tạm (restore lỗi giữa chừng) thì xóa đi.
    if [[ -n "$TMP_DB" ]]; then
        pg -d postgres -c "DROP DATABASE IF EXISTS \"$TMP_DB\" WITH (FORCE)" >/dev/null 2>&1 || true
    fi

    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
on_error() {
    local line="$1"
    log ERROR "Restore thất bại ở dòng $line"
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT

# ===== THAM SỐ DÒNG LỆNH =====
ARCHIVE=""  # -f: file archive; rỗng = dùng bản mới nhất
MODE="all"  # -m: all | db | web
ASSUME_YES=0  # -y: bỏ qua bước hỏi xác nhận

usage() {
    cat <<EOF
Cách dùng: sudo $0 [-f FILE] [-m all|db|web] [-y] [-h]

Khôi phục dữ liệu từ archive do backup.sh tạo ra.

Tùy chọn:
  -f FILE   Archive cần khôi phục (mặc định: bản taskops_backup_*.tar mới nhất
            trong ${BACKUP_DIR})
  -m MODE   all = DB + web (mặc định) | db = chỉ database | web = chỉ nội dung web
  -y        Không hỏi xác nhận (dùng khi chạy tự động)
  -h        Hiện trợ giúp này

Ví dụ:
  sudo $0                                   # khôi phục bản mới nhất, có hỏi xác nhận
  sudo $0 -m db                             # chỉ khôi phục database
  sudo $0 -f ${BACKUP_DIR}/taskops_backup_2026-11-08_020000.tar -y
EOF
}

# hàm xử lý các tham số
parse_args() {
    local opt
    while getopts ":f:m:yh" opt; do
        case "$opt" in
            f) ARCHIVE="$OPTARG" ;;
            m) MODE="$OPTARG" ;;
            y) ASSUME_YES=1 ;;
            h) usage; exit 0 ;;
            :) usage >&2; die "Tùy chọn -$OPTARG cần một giá trị" ;;
            *) usage >&2; die "Tùy chọn không hợp lệ: -$OPTARG" ;;
        esac
    done
    case "$MODE" in
        all|db|web) ;;
        *) die "Giá trị -m không hợp lệ: '$MODE' (chỉ nhận all, db, web)" ;;
    esac
}

# kiểm tra các điều kiện cần thiết trước khi restore
preflight() {
    # Kiểm tra quyền root (ưu tiên hàm validate nếu có)
    if declare -F require_root >/dev/null; then
        require_root
    elif [[ $EUID -ne 0 ]]; then
        die "Cần chạy bằng root (sudo)"
    fi

    if [[ ! -d "$BACKUP_DIR" || ! -w "$BACKUP_DIR" ]]; then
        die "Thư mục backup không tồn tại hoặc không ghi được: $BACKUP_DIR"
    fi

    if [[ "$MODE" != "web" ]] && ! pg_isready -q; then
        die "PostgreSQL không sẵn sàng"
    fi

    local free_mb
    free_mb=$(df --output=avail -BM "$BACKUP_DIR" | tail -n 1 | tr -dc '0-9')
    if (( free_mb < MIN_FREE_MB )); then
        die "Đĩa còn ${free_mb}MB, thấp hơn ngưỡng ${MIN_FREE_MB}MB"
    fi
    log INFO "Preflight OK (còn trống ${free_mb}MB)"
}

# Chọn và kiểm tra bản backup
select_archive() {
    if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'taskops_backup_*.tar' \
                      | sort | tail -n 1)
        [[ -n "$ARCHIVE" ]] || die "Không tìm thấy bản backup nào trong $BACKUP_DIR"
        log INFO "Không chỉ định -f, dùng bản mới nhất: $ARCHIVE"
    fi
    [[ -f "$ARCHIVE" ]] || die "Không tìm thấy file archive: $ARCHIVE"
    ARCHIVE=$(realpath -- "$ARCHIVE")
}

# kiểm tra archive đầy đủ và đọc được
validate_and_extract() {
    local members list m
    members=(db.sql.gz web_app.tar.gz web_status.tar.gz)

    list=$(tar -tf "$ARCHIVE") || die "Archive không đọc được (hỏng?): $ARCHIVE"

    for m in "${members[@]}"; do
        grep -qxF "$m" <<<"$list" || die "Archive thiếu thành phần bắt buộc: $m"
    done

    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.restore.XXXXXX")
    tar -xf "$ARCHIVE" -C "$WORK_DIR" "${members[@]}"

    gzip -t "$WORK_DIR/db.sql.gz"                 || die "db.sql.gz bị hỏng"
    tar -tzf "$WORK_DIR/web_app.tar.gz" >/dev/null    || die "web_app.tar.gz bị hỏng"
    tar -tzf "$WORK_DIR/web_status.tar.gz" >/dev/null || die "web_status.tar.gz bị hỏng"
    log INFO "Archive hợp lệ: $ARCHIVE"
}

# hàm yêu cầu xác nhận từ người dùng trước khi thực hiện restore
confirm_action() {
    if (( ASSUME_YES )); then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Không có terminal để xác nhận. Dùng -y nếu chắc chắn muốn khôi phục"
    fi
    local answer
    log WARN "Sắp GHI ĐÈ dữ liệu hiện tại (chế độ: $MODE) bằng bản: $ARCHIVE"
    read -r -p "Gõ 'yes' để tiếp tục: " answer
    if [[ "$answer" != "yes" ]]; then
        log INFO "Đã hủy, không có gì bị thay đổi"
        exit 0
    fi
}

# chụp lại toàn bộ hiện trạng hệ thống trước khi restore
safety_backup() {
    local ts safety out d
    ts=$(date +%F_%H%M%S)
    safety="$WORK_DIR/safety"
    mkdir -p "$safety"

    log INFO "Tạo bản sao lưu an toàn trước khi khôi phục"

    if [[ "$MODE" != "web" ]]; then
        if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
            sudo -u postgres pg_dump "$DB_NAME" | gzip > "$safety/db.sql.gz"
        else
            echo "-- Database $DB_NAME chưa tồn tại trước khi restore" | gzip > "$safety/db.sql.gz"
        fi
    fi

    if [[ "$MODE" != "db" ]]; then
        for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
            local base
            base=$(basename "$d")
            if [[ -d "$d" ]]; then
                tar -czf "$safety/${base}.tar.gz" -C "$(dirname "$d")" "$base"
            else
                tar -czf "$safety/${base}.tar.gz" --files-from /dev/null
            fi
        done
        mv "$safety/$(basename "$WEB_APP_DIR").tar.gz"    "$safety/web_app.tar.gz"
        mv "$safety/$(basename "$WEB_STATUS_DIR").tar.gz" "$safety/web_status.tar.gz"
    fi

    [[ -f "$safety/db.sql.gz" ]]         || echo "-- dummy" | gzip > "$safety/db.sql.gz"
    [[ -f "$safety/web_app.tar.gz" ]]    || tar -czf "$safety/web_app.tar.gz" --files-from /dev/null
    [[ -f "$safety/web_status.tar.gz" ]] || tar -czf "$safety/web_status.tar.gz" --files-from /dev/null

    out="$BACKUP_DIR/pre_restore_${ts}.tar"
    tar -cf "$out" -C "$safety" db.sql.gz web_app.tar.gz web_status.tar.gz
    chmod 600 "$out"
    log INFO "Đã lưu trạng thái hiện tại để phòng khi cần quay lại: $out"
}

# Đảm bảo role của ứng dụng tồn tại
ensure_app_role() {
    local exists
    exists=$(pg -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_APP_USER'")
    if [[ "$exists" != "1" ]]; then
        pg -d postgres -c "CREATE ROLE \"$DB_APP_USER\" LOGIN" >/dev/null
        log WARN "Role $DB_APP_USER chưa tồn tại nên đã tạo lại (KHÔNG có mật khẩu)." \
                 "Hãy đặt mật khẩu khớp với EnvironmentFile của ứng dụng."
    fi
}

# khôi phục database
restore_database() {
    log INFO "Khôi phục database $DB_NAME"
    ensure_app_role

    TMP_DB="${DB_NAME}_restore_$$"
    pg -d postgres -c "CREATE DATABASE \"$TMP_DB\"" >/dev/null
    zcat "$WORK_DIR/db.sql.gz" | pg --single-transaction -q -d "$TMP_DB" >/dev/null

    local tables
    tables=$(pg -d "$TMP_DB" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")
    (( tables > 0 )) || die "Dump nạp xong nhưng không có bảng nào, hủy để bảo vệ DB hiện tại"

    pg -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE)" >/dev/null
    pg -d postgres -c "ALTER DATABASE \"$TMP_DB\" RENAME TO \"$DB_NAME\"" >/dev/null
    TMP_DB=""

    pg -d "$DB_NAME" >/dev/null <<SQL
GRANT CONNECT ON DATABASE "$DB_NAME" TO "$DB_APP_USER";
GRANT USAGE ON SCHEMA public TO "$DB_APP_USER";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$DB_APP_USER";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$DB_APP_USER";
SQL
    log INFO "Database $DB_NAME đã được khôi phục và cấp lại quyền cho $DB_APP_USER"
}

# khôi phục cho từng thư mục web
restore_web_dir() {
    local target="$1" tarball="$2"
    local parent base stage
    parent=$(dirname "$target")
    base=$(basename "$target")

    stage=$(mktemp -d "$parent/.restore.XXXXXX")
    STAGING_DIRS+=("$stage")

    tar -xzf "$tarball" -C "$stage"
    [[ -d "$stage/$base" ]] || die "Tarball không chứa thư mục '$base' như mong đợi: $tarball"

    if [[ -d "$target" ]]; then
        mv "$target" "$stage/old"
    fi
    mv "$stage/$base" "$target"
    log INFO "Đã khôi phục $target"
}

# khôi phục toàn bộ phần web
restore_web() {
    log INFO "Khôi phục nội dung web"
    restore_web_dir "$WEB_APP_DIR"    "$WORK_DIR/web_app.tar.gz"
    restore_web_dir "$WEB_STATUS_DIR" "$WORK_DIR/web_status.tar.gz"
}

# kiểm chứng sau khi khôi phục
verify() {
    local rows files d
    if [[ "$MODE" != "web" ]]; then
        rows=$(pg -d "$DB_NAME" -tAc "SELECT count(*) FROM \"$CHECK_TABLE\"")
        log INFO "Kiểm chứng DB: bảng $CHECK_TABLE có $rows dòng"
    fi
    if [[ "$MODE" != "db" ]]; then
        for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
            [[ -d "$d" ]] || die "Kiểm chứng thất bại: thiếu thư mục $d"
            files=$(find "$d" -type f | wc -l)
            log INFO "Kiểm chứng web: $d có $files file"
        done
    fi
}

# ===== LUỒNG CHÍNH =====
main() {
    parse_args "$@"
    preflight
    select_archive
    validate_and_extract
    confirm_action
    safety_backup

    if [[ "$MODE" != "web" ]]; then restore_database; fi
    if [[ "$MODE" != "db" ]];  then restore_web;      fi

    verify
    log INFO "Restore hoàn tất từ: $ARCHIVE"
}

main "$@"
