#!/usr/bin/env bash
# restore.sh - Khôi phục PostgreSQL + nội dung web từ archive do backup.sh tạo ra
#
# Archive đầu vào phải có đúng 3 file bên trong:
#   db.sql.gz, web_app.tar.gz, web_status.tar.gz
#
# Các lớp an toàn:
#   1. Kiểm tra archive trước khi tác động vào hệ thống.
#   2. Hỏi xác nhận (gõ "yes"), trừ khi dùng -y.
#   3. Sao lưu trạng thái hiện tại thành pre_restore_*.tar.
#   4. Nạp DB vào database tạm trước khi thay DB thật.
#   5. Giải nén web vào thư mục staging trước khi thay thế.
#
# -E: ERR trap hoạt động bên trong hàm.
# -e: Lệnh lỗi thì dừng.
# -u: Biến chưa khai báo thì lỗi.
# pipefail: Lỗi trong pipeline được tính là lỗi.

set -Eeuo pipefail

# ===== NẠP THƯ VIỆN DÙNG CHUNG =====
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

# Alert dự phòng nếu thư viện không cung cấp send_alert.
if ! declare -F send_alert >/dev/null; then
    send_alert() { :; }
fi

# ===== CẤU HÌNH =====
: "${DB_NAME:=taskops}"
: "${DB_APP_USER:=taskops_app}"
: "${WEB_APP_DIR:=/var/www/taskops-app}"
: "${WEB_STATUS_DIR:=/var/www/taskops-status}"
: "${BACKUP_DIR:=/srv/backup}"
: "${MIN_FREE_MB:=500}"
: "${CHECK_TABLE:=tasks}"

# ===== HÀM LOG VÀ XỬ LÝ LỖI DỰ PHÒNG =====
if ! declare -F log >/dev/null; then
    log() {
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2
    }
fi

die() {
    local code=1
    local msg=""

    if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
        code="$1"
        shift
    fi

    msg="$*"
    log ERROR "$msg"
    send_alert CRIT "Restore thất bại: $msg"
    exit "$code"
}

# Chạy lệnh dưới quyền postgres.
as_postgres() {
    ( cd / && sudo -u postgres "$@" )
}

# Chạy truy vấn PostgreSQL.
pg() {
    as_postgres psql -X -v ON_ERROR_STOP=1 "$@"
}

# ===== BIẾN TOÀN CỤC DÙNG CHO DỌN DẸP =====
WORK_DIR=""
TMP_DB=""
STAGING_DIRS=()

cleanup() {
    local s

    # Dọn dẹp các thư mục staging.
    for s in "${STAGING_DIRS[@]}"; do
        [[ -d "$s" ]] && rm -rf "$s"
    done

    # Nếu còn DB tạm (restore lỗi giữa chừng) thì xóa đi.
    if [[ -n "$TMP_DB" ]]; then
        pg -d postgres \
            -c "DROP DATABASE IF EXISTS \"$TMP_DB\" WITH (FORCE)" \
            >/dev/null 2>&1 || true
    fi

    # Dọn dẹp thư mục làm việc chính.
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

on_error() {
    local line="$1"
    log ERROR "Restore thất bại ở dòng $line"
    send_alert CRIT "Restore gặp lỗi bất ngờ ở dòng $line"
}

trap 'on_error $LINENO' ERR
trap cleanup EXIT

# ===== THAM SỐ DÒNG LỆNH =====
ARCHIVE=""
MODE="all"
ASSUME_YES=0

usage() {
    cat <<EOF
Cách dùng: sudo $0 [-f FILE] [-m all|db|web] [-y] [-h]

Khôi phục dữ liệu từ archive do backup.sh tạo ra.

Tùy chọn:
  -f FILE   Archive cần khôi phục (mặc định: bản mới nhất
            trong ${BACKUP_DIR})
  -m MODE   all = DB + web (mặc định)
            db  = chỉ database
            web = chỉ nội dung web
  -y        Không hỏi xác nhận (dùng khi chạy tự động)
  -h        Hiện trợ giúp này

Ví dụ:
  sudo $0
  sudo $0 -m db
  sudo $0 -f ${BACKUP_DIR}/taskops_backup_2026-11-08_020000.tar -y
EOF
}

parse_args() {
    local opt

    while getopts ":f:m:yh" opt; do
        case "$opt" in
            f) ARCHIVE="$OPTARG" ;;
            m) MODE="$OPTARG" ;;
            y) ASSUME_YES=1 ;;
            h) usage; exit 0 ;;
            :)
                usage >&2
                die "Tùy chọn -$OPTARG cần một giá trị"
                ;;
            *)
                usage >&2
                die "Tùy chọn không hợp lệ: -$OPTARG"
                ;;
        esac
    done

    case "$MODE" in
        all|db|web) ;;
        *) die "Giá trị -m không hợp lệ: '$MODE' (chỉ nhận all, db, web)" ;;
    esac
}

# ===== KIỂM TRA ĐIỀU KIỆN BAN ĐẦU =====
preflight() {
    # Kiểm tra quyền root.
    if declare -F require_root >/dev/null; then
        require_root
    elif [[ $EUID -ne 0 ]]; then
        die "Cần chạy bằng root (sudo)"
    fi

    # Kiểm tra thư mục backup.
    if [[ ! -d "$BACKUP_DIR" || ! -w "$BACKUP_DIR" ]]; then
        die "Thư mục backup không tồn tại hoặc không ghi được: $BACKUP_DIR"
    fi

    # Kiểm tra PostgreSQL.
    if [[ "$MODE" != "web" ]] && ! pg_isready -q; then
        die "PostgreSQL không sẵn sàng"
    fi

    # Kiểm tra dung lượng ổ đĩa.
    local free_mb
    free_mb=$(df --output=avail -BM "$BACKUP_DIR" | tail -n 1 | tr -dc '0-9')

    if (( free_mb < MIN_FREE_MB )); then
        die "Đĩa còn ${free_mb}MB, thấp hơn ngưỡng ${MIN_FREE_MB}MB"
    fi

    log INFO "Preflight OK (còn trống ${free_mb}MB)"
}

# ===== CHỌN VÀ KIỂM TRA ARCHIVE =====
select_archive() {
    if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
            -name 'taskops_backup_*.tar' | sort | tail -n 1)

        [[ -n "$ARCHIVE" ]] || die "Không tìm thấy bản backup nào trong $BACKUP_DIR"

        log INFO "Không chỉ định -f, dùng bản mới nhất: $ARCHIVE"
    fi

    [[ -f "$ARCHIVE" ]] || die "Không tìm thấy file archive: $ARCHIVE"

    # Chuyển thành đường dẫn tuyệt đối.
    ARCHIVE=$(realpath -- "$ARCHIVE")
}

validate_and_extract() {
    local members list m

    members=(
        db.sql.gz
        web_app.tar.gz
        web_status.tar.gz
    )

    # Kiểm tra archive có đọc được không.
    list=$(tar -tf "$ARCHIVE") \
        || die "Archive không đọc được (hỏng?): $ARCHIVE"

    # Kiểm tra đủ các thành phần bắt buộc.
    for m in "${members[@]}"; do
        grep -qxF "$m" <<<"$list" \
            || die "Archive thiếu thành phần bắt buộc: $m"
    done

    # Tạo thư mục làm việc tạm.
    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.restore.XXXXXX")

    # Giải nén các file cần thiết.
    tar -xf "$ARCHIVE" -C "$WORK_DIR" "${members[@]}"

    # Kiểm tra tính toàn vẹn.
    gzip -t "$WORK_DIR/db.sql.gz" \
        || die "db.sql.gz bị hỏng"

    tar -tzf "$WORK_DIR/web_app.tar.gz" >/dev/null \
        || die "web_app.tar.gz bị hỏng"

    tar -tzf "$WORK_DIR/web_status.tar.gz" >/dev/null \
        || die "web_status.tar.gz bị hỏng"

    log INFO "Archive hợp lệ: $ARCHIVE"
}

# ===== XÁC NHẬN TRƯỚC KHI RESTORE =====
confirm_action() {
    if (( ASSUME_YES )); then
        return 0
    fi

    # Không có terminal thì dừng để bảo đảm an toàn.
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

# ===== SAO LƯU TRẠNG THÁI HIỆN TẠI =====
safety_backup() {
    local ts safety out d base exists

    ts=$(date +%F_%H%M%S)
    safety="$WORK_DIR/safety"
    mkdir -p "$safety"

    out="$BACKUP_DIR/pre_restore_${ts}.tar"

    log INFO "Tạo bản sao lưu an toàn trước khi khôi phục"

    # Sao lưu database hiện tại.
    if [[ "$MODE" != "web" ]]; then
        exists=$(pg -d postgres -tAc \
            "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")

        if [[ "$exists" == "1" ]]; then
            # DB tồn tại thì bắt buộc dump thành công.
            as_postgres pg_dump "$DB_NAME" | gzip > "$safety/db.sql.gz"

            gzip -t "$safety/db.sql.gz" \
                || die "Bản sao lưu database hiện tại bị lỗi"
        else
            log WARN "Database $DB_NAME chưa tồn tại trước khi restore"
        fi
    fi

    # Sao lưu các thư mục web hiện tại.
    if [[ "$MODE" != "db" ]]; then
        for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
            base=$(basename "$d")

            if [[ -d "$d" ]]; then
                tar -czf "$safety/${base}.tar.gz" \
                    -C "$(dirname "$d")" "$base"
            else
                log WARN "Thư mục $d không tồn tại, bỏ qua sao lưu"
            fi
        done
    fi

    # Tạo file placeholder để archive luôn có đủ 3 thành phần.
    [[ -f "$safety/db.sql.gz" ]] \
        || echo "-- Database chưa được sao lưu trong chế độ này" \
            | gzip > "$safety/db.sql.gz"

    [[ -f "$safety/web_app.tar.gz" ]] \
        || tar -czf "$safety/web_app.tar.gz" --files-from /dev/null

    [[ -f "$safety/web_status.tar.gz" ]] \
        || tar -czf "$safety/web_status.tar.gz" --files-from /dev/null

    # Đóng gói bản sao lưu an toàn.
    tar -cf "$out" -C "$safety" \
        db.sql.gz web_app.tar.gz web_status.tar.gz

    chmod 600 "$out"

    log INFO "Đã lưu trạng thái hiện tại để phòng khi cần quay lại: $out"
}

# ===== ĐẢM BẢO ROLE ỨNG DỤNG TỒN TẠI =====
ensure_app_role() {
    local exists

    exists=$(pg -d postgres -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname = '$DB_APP_USER'")

    if [[ "$exists" != "1" ]]; then
        pg -d postgres -c \
            "CREATE ROLE \"$DB_APP_USER\" LOGIN" >/dev/null

        log WARN "Role $DB_APP_USER chưa tồn tại nên đã tạo lại (KHÔNG có mật khẩu). Hãy đặt mật khẩu khớp với EnvironmentFile của ứng dụng."
    fi
}

# ===== KHÔI PHỤC DATABASE =====
restore_database() {
    log INFO "Khôi phục database $DB_NAME"

    ensure_app_role

    # Bước 1: Tạo DB tạm.
    TMP_DB="${DB_NAME}_restore_$$"

    pg -d postgres -c \
        "CREATE DATABASE \"$TMP_DB\"" >/dev/null

    # Bước 2: Nạp dump vào DB tạm.
    zcat "$WORK_DIR/db.sql.gz" \
        | pg --single-transaction -q -d "$TMP_DB" >/dev/null

    # Bước 3: Kiểm tra DB tạm có bảng.
    local tables

    tables=$(pg -d "$TMP_DB" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")

    (( tables > 0 )) \
        || die "Dump nạp xong nhưng không có bảng nào, hủy để bảo vệ DB hiện tại"

    # Bước 4: Thay DB thật bằng DB tạm.
    pg -d postgres -c \
        "DROP DATABASE IF EXISTS \"$DB_NAME\" WITH (FORCE)" >/dev/null

    pg -d postgres -c \
        "ALTER DATABASE \"$TMP_DB\" RENAME TO \"$DB_NAME\"" >/dev/null

    TMP_DB=""

    # Bước 5: Cấp lại quyền tối thiểu cho role ứng dụng.
    pg -d "$DB_NAME" >/dev/null <<SQL
GRANT CONNECT ON DATABASE "$DB_NAME" TO "$DB_APP_USER";
GRANT USAGE ON SCHEMA public TO "$DB_APP_USER";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$DB_APP_USER";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$DB_APP_USER";
SQL

    log INFO "Database $DB_NAME đã được khôi phục và cấp lại quyền cho $DB_APP_USER"
}

# ===== KHÔI PHỤC TỪNG THƯ MỤC WEB =====
restore_web_dir() {
    local target="$1"
    local tarball="$2"
    local parent base stage

    parent=$(dirname "$target")
    base=$(basename "$target")

    # Giải nén vào thư mục tạm cùng filesystem với đích.
    mkdir -p "$parent"

    stage=$(mktemp -d "$parent/.restore.XXXXXX")
    STAGING_DIRS+=("$stage")

    # Root giữ nguyên quyền và chủ sở hữu trong archive.
    tar -xzf "$tarball" -C "$stage"

    [[ -d "$stage/$base" ]] \
        || die "Tarball không chứa thư mục '$base' như mong đợi: $tarball"

    # Đưa bản cũ sang chỗ tạm.
    if [[ -d "$target" ]]; then
        mv "$target" "$stage/old"
    fi

    # Đưa bản khôi phục vào vị trí chính thức.
    mv "$stage/$base" "$target"

    log INFO "Đã khôi phục $target"
}

# ===== KHÔI PHỤC TOÀN BỘ WEB =====
restore_web() {
    log INFO "Khôi phục nội dung web"

    restore_web_dir "$WEB_APP_DIR" "$WORK_DIR/web_app.tar.gz"
    restore_web_dir "$WEB_STATUS_DIR" "$WORK_DIR/web_status.tar.gz"
}

# ===== KIỂM CHỨNG SAU RESTORE =====
verify() {
    local rows files d

    # Kiểm chứng database.
    if [[ "$MODE" != "web" ]]; then
        rows=$(pg -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM \"$CHECK_TABLE\"")

        log INFO "Kiểm chứng DB: bảng $CHECK_TABLE có $rows dòng"
    fi

    # Kiểm chứng mã nguồn web.
    if [[ "$MODE" != "db" ]]; then
        for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
            [[ -d "$d" ]] \
                || die "Kiểm chứng thất bại: thiếu thư mục $d"

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

    # Kiểm tra kỹ archive trước khi tác động vào hệ thống.
    validate_and_extract

    # Xác nhận người dùng.
    confirm_action

    send_alert WARN \
        "Bắt đầu restore hệ thống (chế độ: $MODE) từ $(basename "$ARCHIVE") bởi $(whoami)"

    # Sao lưu trạng thái hiện tại.
    safety_backup

    # Khôi phục database.
    if [[ "$MODE" != "web" ]]; then
        restore_database
    fi

    # Khôi phục nội dung web.
    if [[ "$MODE" != "db" ]]; then
        restore_web
    fi

    # Kiểm chứng.
    verify

    log INFO "Restore hoàn tất từ: $ARCHIVE"

    send_alert INFO \
        "Restore hoàn tất thành công từ $(basename "$ARCHIVE") (chế độ: $MODE)"
}

main "$@"
