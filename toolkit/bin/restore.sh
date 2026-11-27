#!/usr/bin/env bash
# restore.sh - Khôi phục PostgreSQL + nội dung web từ archive do backup.sh tạo ra
#
# Archive đầu vào gồm:
#   db.sql.gz
#   web_app.tar.gz
#   web_status.tar.gz
#
# Các lớp an toàn:
#   1. Kiểm tra archive trước khi thay đổi hệ thống.
#   2. Yêu cầu xác nhận (gõ "yes"), trừ khi dùng -y.
#   3. Sao lưu trạng thái hiện tại thành pre_restore_*.tar.
#   4. Restore DB vào database tạm trước khi thay thế DB chính.
#   5. Giải nén web vào staging trước khi thay thế thư mục thật.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" &>/dev/null && pwd)"

# ===== NẠP THƯ VIỆN =====
# Nạp common trước để alert.sh có thể sử dụng các hàm log chung.
if [[ -f "$LIB_DIR/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/common.sh"
fi

if [[ -f "$LIB_DIR/alert.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/alert.sh"
fi

# Fallback nếu thư viện chưa được triển khai.
if ! declare -F log >/dev/null; then
    log() {
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2
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

if ! declare -F send_alert >/dev/null; then
    send_alert() {
        return 0
    }
fi

# ===== CẤU HÌNH =====
: "${DB_NAME:=taskops}"
: "${DB_APP_USER:=taskops_app}"

: "${WEB_APP_DIR:=/var/www/taskops-app}"
: "${WEB_STATUS_DIR:=/var/www/taskops-status}"

: "${BACKUP_DIR:=/srv/backup}"
: "${MIN_FREE_MB:=500}"
: "${CHECK_TABLE:=tasks}"

# Chỉ chấp nhận identifier PostgreSQL an toàn.
validate_identifier() {
    local name="$1"
    local label="$2"

    if [[ ! "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$ ]]; then
        die "Tên $label không hợp lệ: '$name'"
    fi
}

# ===== KIỂM TRA CẤU HÌNH =====
validate_identifier "$DB_NAME" "database"
validate_identifier "$DB_APP_USER" "application role"
validate_identifier "$CHECK_TABLE" "check table"

# ===== POSTGRESQL HELPERS =====
as_postgres() {
    (
        cd /
        sudo -u postgres "$@"
    )
}

pg() {
    as_postgres psql -X -v ON_ERROR_STOP=1 "$@"
}

# ===== BIẾN TOÀN CỤC =====
WORK_DIR=""
TMP_DB=""
STAGING_DIRS=()

# Theo dõi các thư mục web đã thay thế để rollback nếu restore web thất bại.
SWAP_TARGETS=()
SWAP_STAGES=()
SWAP_HAD_OLD=()

RESTORE_SUCCESS=0

cleanup() {
    local i stage target had_old

    # Nếu restore thất bại, cố gắng phục hồi các thư mục web cũ.
    if (( ! RESTORE_SUCCESS )); then
        for ((i=${#SWAP_TARGETS[@]}-1; i>=0; i--)); do
            target="${SWAP_TARGETS[$i]}"
            stage="${SWAP_STAGES[$i]}"
            had_old="${SWAP_HAD_OLD[$i]}"

            if [[ "$had_old" == "1" && -d "$stage/old" ]]; then
                rm -rf -- "$target"
                mv -- "$stage/old" "$target" || {
                    log ERROR "Không thể rollback thư mục: $target"
                    send_alert CRIT "Rollback web thất bại: $target" || true
                }
            elif [[ "$had_old" == "0" ]]; then
                rm -rf -- "$target"
            fi
        done
    fi

    # Xóa database tạm nếu restore chưa hoàn tất.
    if [[ -n "$TMP_DB" ]]; then
        pg -d postgres \
            -c "DROP DATABASE IF EXISTS \"$TMP_DB\" WITH (FORCE)" \
            >/dev/null 2>&1 || true
    fi

    # Dọn các thư mục staging.
    for stage in "${STAGING_DIRS[@]}"; do
        [[ -d "$stage" ]] && rm -rf -- "$stage"
    done

    # Xóa thư mục làm việc.
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

on_error() {
    local line="$1"

    log ERROR "Restore thất bại tại dòng $line"
    send_alert CRIT "Restore gặp lỗi tại dòng $line" || true
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
  -f FILE   Archive cần khôi phục.
            Mặc định: bản taskops_backup_*.tar mới nhất.
  -m MODE   all = DB + web (mặc định)
            db  = chỉ database
            web = chỉ nội dung web
  -y        Bỏ qua bước xác nhận.
  -h        Hiện trợ giúp.

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
            h)
                usage
                exit 0
                ;;
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
        *) die "Giá trị -m không hợp lệ: '$MODE'" ;;
    esac
}

# ===== PREFLIGHT =====
preflight() {
    if declare -F require_root >/dev/null; then
        require_root
    elif [[ $EUID -ne 0 ]]; then
        die "Cần chạy bằng root (sudo)"
    fi

    [[ -d "$BACKUP_DIR" && -w "$BACKUP_DIR" ]] ||
        die "Thư mục backup không tồn tại hoặc không ghi được: $BACKUP_DIR"

    if [[ "$MODE" != "web" ]] && ! pg_isready -q; then
        die "PostgreSQL không sẵn sàng"
    fi

    local free_mb
    free_mb=$(df --output=avail -BM "$BACKUP_DIR" |
        tail -n 1 | tr -dc '0-9')

    [[ "$free_mb" =~ ^[0-9]+$ ]] ||
        die "Không xác định được dung lượng đĩa còn trống"

    if (( free_mb < MIN_FREE_MB )); then
        die "Đĩa còn ${free_mb}MB, thấp hơn ngưỡng ${MIN_FREE_MB}MB"
    fi

    log INFO "Preflight OK (còn trống ${free_mb}MB)"
}

# ===== CHỌN ARCHIVE =====
select_archive() {
    if [[ -z "$ARCHIVE" ]]; then
        ARCHIVE=$(
            find "$BACKUP_DIR" -maxdepth 1 -type f \
                -name 'taskops_backup_*.tar' |
                sort | tail -n 1
        )

        [[ -n "$ARCHIVE" ]] ||
            die "Không tìm thấy bản backup trong $BACKUP_DIR"

        log INFO "Sử dụng bản backup mới nhất: $ARCHIVE"
    fi

    [[ -f "$ARCHIVE" ]] ||
        die "Không tìm thấy archive: $ARCHIVE"

    ARCHIVE=$(realpath -- "$ARCHIVE")
}

# ===== KIỂM TRA ARCHIVE =====
validate_tar_paths() {
    local tarball="$1"
    local entry

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue

        # Không cho phép đường dẫn tuyệt đối hoặc traversal.
        [[ "$entry" != /* ]] ||
            die "Tarball chứa đường dẫn tuyệt đối: $entry"

        [[ "/$entry/" != *"/../"* ]] ||
            die "Tarball chứa đường dẫn traversal: $entry"
    done < <(tar -tzf "$tarball")
}

validate_and_extract() {
    local members=(db.sql.gz web_app.tar.gz web_status.tar.gz)
    local list m
    local expected actual

    list=$(tar -tf "$ARCHIVE") ||
        die "Archive không đọc được hoặc bị hỏng"

    expected=$(printf '%s\n' "${members[@]}" | sort)
    actual=$(printf '%s\n' "$list" | sort)

    [[ "$actual" == "$expected" ]] ||
        die "Archive phải chứa đúng 3 file: db.sql.gz, web_app.tar.gz, web_status.tar.gz"

    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.restore.XXXXXX")

    tar -xf "$ARCHIVE" -C "$WORK_DIR" "${members[@]}" ||
        die "Không thể giải nén archive chính"

    gzip -t "$WORK_DIR/db.sql.gz" ||
        die "db.sql.gz bị hỏng"

    for m in web_app.tar.gz web_status.tar.gz; do
        tar -tzf "$WORK_DIR/$m" >/dev/null ||
            die "$m bị hỏng"

        validate_tar_paths "$WORK_DIR/$m"

        # Không cho phép symlink/hardlink trong archive web.
        if tar -tvzf "$WORK_DIR/$m" |
            awk 'substr($0,1,1)=="l" || substr($0,1,1)=="h" {bad=1} END {exit !bad}'; then
            die "$m chứa symbolic link hoặc hard link không được phép"
        fi
    done

    log INFO "Archive hợp lệ: $ARCHIVE"
}

# ===== XÁC NHẬN =====
confirm_action() {
    if (( ASSUME_YES )); then
        return 0
    fi

    [[ -t 0 ]] ||
        die "Không có terminal để xác nhận. Dùng -y nếu chắc chắn muốn restore"

    local answer

    log WARN "Sắp GHI ĐÈ dữ liệu hiện tại (chế độ: $MODE)"
    log WARN "Archive: $ARCHIVE"

    read -r -p "Gõ 'yes' để tiếp tục: " answer

    if [[ "$answer" != "yes" ]]; then
        log INFO "Đã hủy, không có dữ liệu nào bị thay đổi"
        exit 0
    fi
}

# ===== BACKUP AN TOÀN TRƯỚC RESTORE =====
safety_backup() {
    local ts safety out d base

    ts=$(date +%F_%H%M%S)
    safety="$WORK_DIR/safety"

    mkdir -p "$safety"

    log INFO "Tạo bản sao lưu trạng thái hiện tại"

    if [[ "$MODE" != "web" ]]; then
        if pg -d postgres -tAc \
            "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" |
            grep -qx "1"; then

            as_postgres pg_dump "$DB_NAME" |
                gzip > "$safety/db.sql.gz"
        else
            printf '%s\n' "-- Database chưa tồn tại" |
                gzip > "$safety/db.sql.gz"
        fi
    fi

    if [[ "$MODE" != "db" ]]; then
        for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
            base=$(basename "$d")

            if [[ -d "$d" ]]; then
                tar -czf "$safety/${base}.tar.gz" \
                    -C "$(dirname "$d")" "$base"
            else
                tar -czf "$safety/${base}.tar.gz" \
                    --files-from /dev/null
            fi
        done

        mv "$safety/$(basename "$WEB_APP_DIR").tar.gz" \
            "$safety/web_app.tar.gz"

        mv "$safety/$(basename "$WEB_STATUS_DIR").tar.gz" \
            "$safety/web_status.tar.gz"
    fi

    # Bổ sung các file rỗng để archive luôn có đúng 3 thành phần.
    [[ -f "$safety/db.sql.gz" ]] ||
        printf '%s\n' "-- DB không được backup trong chế độ này" |
            gzip > "$safety/db.sql.gz"

    [[ -f "$safety/web_app.tar.gz" ]] ||
        tar -czf "$safety/web_app.tar.gz" --files-from /dev/null

    [[ -f "$safety/web_status.tar.gz" ]] ||
        tar -czf "$safety/web_status.tar.gz" --files-from /dev/null

    out="$BACKUP_DIR/pre_restore_${ts}.tar"

    tar -cf "$out" -C "$safety" \
        db.sql.gz web_app.tar.gz web_status.tar.gz

    chmod 600 "$out"

    log INFO "Đã lưu bản dự phòng: $out"
}

# ===== ĐẢM BẢO APPLICATION ROLE =====
ensure_app_role() {
    local exists

    exists=$(pg -d postgres -tAc \
        "SELECT 1 FROM pg_roles WHERE rolname='$DB_APP_USER'")

    if [[ "$exists" != "1" ]]; then
        pg -d postgres \
            -c "CREATE ROLE \"$DB_APP_USER\" LOGIN" >/dev/null

        log WARN "Đã tạo role $DB_APP_USER nhưng chưa có mật khẩu."
        log WARN "Cần đặt mật khẩu khớp với EnvironmentFile của ứng dụng."
    fi
}

# ===== RESTORE DATABASE =====
restore_database() {
    local tables old_exists rename_ok=0
    local OLD_DB="${DB_NAME}_pre_restore_$$"

    log INFO "Khôi phục database $DB_NAME"

    ensure_app_role

    # Không ghi đè database backup cũ nếu tên dự phòng đã tồn tại.
    if [[ ${#OLD_DB} -gt 63 ]]; then
        die "Tên database dự phòng vượt giới hạn PostgreSQL"
    fi

    if [[ "$(pg -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$OLD_DB'")" == "1" ]]; then
        die "Database dự phòng đã tồn tại: $OLD_DB"
    fi

    TMP_DB="${DB_NAME}_restore_$$"

    pg -d postgres -c "CREATE DATABASE \"$TMP_DB\"" >/dev/null

    zcat "$WORK_DIR/db.sql.gz" |
        pg --single-transaction -q -d "$TMP_DB" >/dev/null

    tables=$(pg -d "$TMP_DB" -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")

    (( tables > 0 )) ||
        die "Database restore không có bảng nào. Hủy để bảo vệ dữ liệu hiện tại"

    # Kiểm tra database chính có tồn tại không.
    old_exists=$(pg -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")

    if [[ "$old_exists" == "1" ]]; then
        # Đóng các kết nối trước khi đổi tên database.
        pg -d postgres -c \
            "SELECT pg_terminate_backend(pid)
             FROM pg_stat_activity
             WHERE datname='$DB_NAME'
             AND pid <> pg_backend_pid()" >/dev/null

        pg -d postgres \
            -c "ALTER DATABASE \"$DB_NAME\" RENAME TO \"$OLD_DB\"" >/dev/null

        # Nếu đổi tên database mới thất bại, khôi phục tên DB cũ.
        if ! pg -d postgres \
            -c "ALTER DATABASE \"$TMP_DB\" RENAME TO \"$DB_NAME\"" >/dev/null; then

            pg -d postgres \
                -c "ALTER DATABASE \"$OLD_DB\" RENAME TO \"$DB_NAME\"" >/dev/null ||
                log ERROR "Không thể phục hồi tên database cũ: $OLD_DB"

            die "Không thể đổi tên database tạm thành $DB_NAME"
        fi

        rename_ok=1
    else
        pg -d postgres \
            -c "ALTER DATABASE \"$TMP_DB\" RENAME TO \"$DB_NAME\"" >/dev/null
    fi

    TMP_DB=""

    # Chỉ xóa DB cũ sau khi DB mới đã được thay thế thành công.
    if (( rename_ok )); then
        pg -d postgres \
            -c "DROP DATABASE \"$OLD_DB\" WITH (FORCE)" >/dev/null ||
            log WARN "Không xóa được database cũ: $OLD_DB"
    fi

    # Cấp lại quyền cho application role.
    pg -d "$DB_NAME" >/dev/null <<SQL
GRANT CONNECT ON DATABASE "$DB_NAME" TO "$DB_APP_USER";
GRANT USAGE ON SCHEMA public TO "$DB_APP_USER";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "$DB_APP_USER";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO "$DB_APP_USER";
SQL

    log INFO "Database $DB_NAME đã được khôi phục"
}

# ===== RESTORE TỪNG THƯ MỤC WEB =====
restore_web_dir() {
    local target="$1"
    local tarball="$2"
    local parent base stage had_old=0

    parent=$(dirname "$target")
    base=$(basename "$target")

    mkdir -p "$parent"

    stage=$(mktemp -d "$parent/.restore.XXXXXX")
    STAGING_DIRS+=("$stage")

    tar --no-same-owner --no-same-permissions \
        -xzf "$tarball" -C "$stage"

    [[ -d "$stage/$base" ]] ||
        die "Tarball không chứa thư mục '$base' như mong đợi"

    if [[ -d "$target" ]]; then
        mv -- "$target" "$stage/old"
        had_old=1
    fi

    # Đăng ký để cleanup có thể rollback nếu bước tiếp theo lỗi.
    SWAP_TARGETS+=("$target")
    SWAP_STAGES+=("$stage")
    SWAP_HAD_OLD+=("$had_old")

    mv -- "$stage/$base" "$target"

    log INFO "Đã khôi phục $target"
}

# ===== RESTORE WEB =====
restore_web() {
    log INFO "Khôi phục nội dung web"

    restore_web_dir "$WEB_APP_DIR" \
        "$WORK_DIR/web_app.tar.gz"

    restore_web_dir "$WEB_STATUS_DIR" \
        "$WORK_DIR/web_status.tar.gz"
}

# ===== KIỂM CHỨNG =====
verify() {
    local rows files d

    if [[ "$MODE" != "web" ]]; then
        rows=$(pg -d "$DB_NAME" -tAc \
            "SELECT count(*) FROM public.\"$CHECK_TABLE\"") ||
            die "Không thể kiểm tra bảng $CHECK_TABLE"

        log INFO "Kiểm chứng DB: bảng $CHECK_TABLE có $rows dòng"
    fi

    if [[ "$MODE" != "db" ]]; then
        for d in "$WEB_APP_DIR" "$WEB_STATUS_DIR"; do
            [[ -d "$d" ]] ||
                die "Kiểm chứng thất bại: thiếu thư mục $d"

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

    # Phải kiểm tra archive trước khi đụng vào hệ thống.
    validate_and_extract

    confirm_action

    send_alert WARN \
        "Bắt đầu restore hệ thống (chế độ: $MODE) từ $(basename "$ARCHIVE") bởi $(whoami)" \
        || log WARN "Không gửi được cảnh báo bắt đầu restore"

    safety_backup

    if [[ "$MODE" != "web" ]]; then
        restore_database
    fi

    if [[ "$MODE" != "db" ]]; then
        restore_web
    fi

    verify

    # Đánh dấu thành công để cleanup không rollback các thư mục web.
    RESTORE_SUCCESS=1

    log INFO "Restore hoàn tất từ: $ARCHIVE"

    send_alert INFO \
        "Restore hoàn tất thành công từ $(basename "$ARCHIVE") (chế độ: $MODE)" \
        || log WARN "Không gửi được cảnh báo hoàn tất restore"
}

main "$@"
