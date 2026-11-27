#!/usr/bin/env bash
# ==============================================================================
# TaskOps Toolkit - F06 & F07: Tự động triển khai (Auto Deployment & Rollback)
#
# Chức năng:
#   1. Sao lưu snapshot phiên bản hiện tại trước khi triển khai (cho F07 Rollback)
#   2. Triển khai frontend tĩnh (React/HTML) sang thư mục phục vụ web (/var/www/taskops)
#   3. Thiết lập quyền sở hữu và phân quyền an toàn (chown/chmod www-data / taskops)
#   4. Cập nhật và kiểm tra cú pháp cấu hình Nginx (nginx -t)
#   5. Quy trình an toàn: Test -> Reload -> Verify (HTTP 200)
#   6. Tự động rollback về snapshot gần nhất nếu có lỗi ở bất kỳ bước nào (F07)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TOOLKIT_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
LIB_DIR="$TOOLKIT_ROOT/lib"

# Nạp thư viện dùng chung nếu có
# shellcheck disable=SC1091
if [[ -f "$LIB_DIR/common.sh" ]]; then
    source "$LIB_DIR/common.sh"
fi

if [[ -f "$LIB_DIR/alert.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/alert.sh"
fi

if ! declare -F send_alert >/dev/null; then
    send_alert() { :; }
fi

# Hàm log và die dự phòng nếu chưa có common.sh
if ! declare -F log >/dev/null; then
    log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
fi

if ! declare -F die >/dev/null; then
    # shellcheck disable=SC2317
    die() {
        local code=1 msg=""
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
            code="$1"; shift
        fi
        msg="$*"
        log ERROR "$msg"
        exit "$code"
    }
fi

# Cấu hình mặc định
WEB_ROOT_DEFAULT="/var/www/taskops"
# shellcheck disable=SC2034
APP_DIR_DEFAULT="/opt/taskops"
NGINX_CONF_AVAILABLE="/etc/nginx/sites-available/taskops"
NGINX_CONF_ENABLED="/etc/nginx/sites-enabled/taskops"
BACKUP_SNAPSHOT_DIR="/var/backups/taskops-deploy"
DEFAULT_VERIFY_URL="http://127.0.0.1"

SRC_WEB_DIR=""
SRC_NGINX_CONF=""
VERIFY_URL="$DEFAULT_VERIFY_URL"
DO_ROLLBACK=0
SNAPSHOT_TAG=""

usage() {
    cat <<EOF
Cách dùng: $0 [tùy chọn]

Tùy chọn:
  -s, --src-web DIR       Thư mục nguồn chứa bản build web/static (mặc định: auto-detect app/static)
  -w, --web-root DIR      Thư mục web root đích trên server (mặc định: $WEB_ROOT_DEFAULT)
  -c, --nginx-conf FILE   File cấu hình Nginx nguồn để triển khai
  -u, --url URL           URL nội bộ dùng để verify sau reload (mặc định: $DEFAULT_VERIFY_URL)
  -r, --rollback [TAG]    Khôi phục về snapshot trước đó (F07)
  -h, --help              Hiển thị hướng dẫn này

Ví dụ:
  sudo $0
  sudo $0 --src-web ./app/static --nginx-conf ./infra/nginx-taskops.conf
  sudo $0 --rollback
EOF
}

# Xử lý tham số dòng lệnh
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--src-web)
            SRC_WEB_DIR="$2"
            shift 2
            ;;
        -w|--web-root)
            WEB_ROOT_DEFAULT="$2"
            shift 2
            ;;
        -c|--nginx-conf)
            SRC_NGINX_CONF="$2"
            shift 2
            ;;
        -u|--url)
            VERIFY_URL="$2"
            shift 2
            ;;
        -r|--rollback)
            DO_ROLLBACK=1
            if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                SNAPSHOT_TAG="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Tham số không hợp lệ: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Kiểm tra quyền root
check_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        log ERROR "Lệnh deploy yêu cầu quyền root (vui lòng chạy với sudo)."
        exit 1
    fi
}

# Tạo snapshot dự phòng trước khi thay đổi (F07 Rollback preparation)
create_pre_deploy_snapshot() {
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local snapshot_path="$BACKUP_SNAPSHOT_DIR/$timestamp"

    mkdir -p "$snapshot_path"
    chmod 700 "$BACKUP_SNAPSHOT_DIR"

    log INFO "Tạo bản sao lưu snapshot trước khi triển khai: $snapshot_path"

    # Sao lưu web root nếu đã tồn tại
    if [[ -d "$WEB_ROOT_DEFAULT" && "$(ls -A "$WEB_ROOT_DEFAULT" 2>/dev/null)" ]]; then
        mkdir -p "$snapshot_path/web"
        cp -a "$WEB_ROOT_DEFAULT/." "$snapshot_path/web/"
    fi

    # Sao lưu nginx config nếu đã có
    if [[ -f "$NGINX_CONF_AVAILABLE" ]]; then
        mkdir -p "$snapshot_path/nginx"
        cp -a "$NGINX_CONF_AVAILABLE" "$snapshot_path/nginx/"
    fi

    echo "$timestamp" > "$BACKUP_SNAPSHOT_DIR/latest"
    CURRENT_SNAPSHOT="$timestamp"
}

# Thực hiện rollback về bản snapshot
perform_rollback() {
    local target_tag="${1:-}"
    if [[ -z "$target_tag" ]]; then
        if [[ -f "$BACKUP_SNAPSHOT_DIR/latest" ]]; then
            target_tag="$(cat "$BACKUP_SNAPSHOT_DIR/latest")"
        else
            log ERROR "Không tìm thấy snapshot gần nhất để rollback."
            return 1
        fi
    fi

    local snapshot_path="$BACKUP_SNAPSHOT_DIR/$target_tag"
    if [[ ! -d "$snapshot_path" ]]; then
        log ERROR "Thư mục snapshot không tồn tại: $snapshot_path"
        return 1
    fi

    log WARN ">>> TIẾN HÀNH ROLLBACK VỀ SNAPSHOT: $target_tag <<<"

    # 1. Khôi phục web root
    if [[ -d "$snapshot_path/web" ]]; then
        log INFO "Đang khôi phục web root từ $snapshot_path/web..."
        mkdir -p "$WEB_ROOT_DEFAULT"
        rm -rf "${WEB_ROOT_DEFAULT:?}"/*
        cp -a "$snapshot_path/web/." "$WEB_ROOT_DEFAULT/"
        chown -R www-data:www-data "$WEB_ROOT_DEFAULT" 2>/dev/null || true
    fi

    # 2. Khôi phục cấu hình Nginx
    if [[ -f "$snapshot_path/nginx/taskops" ]]; then
        log INFO "Đang khôi phục cấu hình Nginx..."
        cp -a "$snapshot_path/nginx/taskops" "$NGINX_CONF_AVAILABLE"
        ln -sf "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED" 2>/dev/null || true
    fi

    # 3. Reload lại Nginx
    if command -v nginx >/dev/null 2>&1; then
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
            log INFO "Rollback cấu hình Nginx và reload thành công."
        else
            log ERROR "Cấu hình snapshot Nginx không vượt qua nginx -t!"
        fi
    fi

    log INFO "Rollback hoàn tất thành công về phiên bản $target_tag."
    send_alert WARN "Hệ thống TaskOps vừa thực hiện rollback về bản $target_tag"
    return 0
}

# Bắt lỗi bất ngờ để tự động rollback
on_deploy_error() {
    local exit_code=$?
    log ERROR "Phát hiện lỗi trong quá trình triển khai (exit_code=$exit_code)!"
    send_alert CRIT "Deploy TaskOps thất bại tại bước tự động hóa. Đang tiến hành rollback..."
    if [[ -n "${CURRENT_SNAPSHOT:-}" ]]; then
        perform_rollback "$CURRENT_SNAPSHOT" || true
    fi
    exit "$exit_code"
}

# Tìm source code build tĩnh
detect_source_files() {
    if [[ -z "$SRC_WEB_DIR" ]]; then
        # Thử tìm các vị trí quen thuộc
        if [[ -d "$TOOLKIT_ROOT/app/static" ]]; then
            SRC_WEB_DIR="$TOOLKIT_ROOT/app/static"
        elif [[ -d "$TOOLKIT_ROOT/../app/static" ]]; then
            SRC_WEB_DIR="$TOOLKIT_ROOT/../app/static"
        elif [[ -d "/home/ubuntu/TaskOps/app/static" ]]; then
            SRC_WEB_DIR="/home/ubuntu/TaskOps/app/static"
        fi
    fi

    if [[ -n "$SRC_WEB_DIR" && -d "$SRC_WEB_DIR" ]]; then
        log INFO "Thư mục web artifacts nguồn: $SRC_WEB_DIR"
    else
        log WARN "Chưa chỉ định thư mục web artifacts (sử dụng trang index mặc định nếu web root trống)."
    fi
}

main() {
    check_root

    # Nếu người dùng yêu cầu lệnh rollback riêng biệt
    if [[ "$DO_ROLLBACK" -eq 1 ]]; then
        perform_rollback "$SNAPSHOT_TAG"
        exit $?
    fi

    log INFO "=========================================================="
    log INFO "Bắt đầu quy trình tự động triển khai TaskOps (F06)"
    log INFO "=========================================================="

    detect_source_files

    # Bước 1: Sao lưu snapshot trước khi đụng vào hệ thống
    CURRENT_SNAPSHOT=""
    create_pre_deploy_snapshot

    # Đăng ký trap on error để kích hoạt F07 Rollback tự động
    trap on_deploy_error ERR

    # Bước 2: Triển khai web content / static build
    log INFO "[1/4] Triển khai static build artifacts tới $WEB_ROOT_DEFAULT..."
    mkdir -p "$WEB_ROOT_DEFAULT"

    if [[ -n "$SRC_WEB_DIR" && -d "$SRC_WEB_DIR" ]]; then
        cp -r "$SRC_WEB_DIR"/. "$WEB_ROOT_DEFAULT/"
    elif [[ ! -f "$WEB_ROOT_DEFAULT/index.html" ]]; then
        # Tạo trang placeholder nếu chưa có gì
        cat <<'HTML' > "$WEB_ROOT_DEFAULT/index.html"
<!DOCTYPE html>
<html lang="vi">
<head><meta charset="utf-8"><title>TaskOps App</title></head>
<body><h1>TaskOps Service is Running</h1></body>
</html>
HTML
    fi

    # Phân quyền chuẩn bảo mật: www-data sở hữu web root, file 644, dir 755
    log INFO "[2/4] Thiết lập ownership và phân quyền (chown www-data, chmod 755/644)..."
    chown -R www-data:www-data "$WEB_ROOT_DEFAULT"
    find "$WEB_ROOT_DEFAULT" -type d -exec chmod 755 {} +
    find "$WEB_ROOT_DEFAULT" -type f -exec chmod 644 {} +

    # Bước 3: Cấu hình Nginx Virtual Host (nếu có file mẫu hoặc cấu hình mới)
    log INFO "[3/4] Cập nhật và kiểm tra cấu hình Nginx..."
    if [[ -n "$SRC_NGINX_CONF" && -f "$SRC_NGINX_CONF" ]]; then
        mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled
        cp "$SRC_NGINX_CONF" "$NGINX_CONF_AVAILABLE"
        ln -sf "$NGINX_CONF_AVAILABLE" "$NGINX_CONF_ENABLED"
    fi

    # Kiểm tra cú pháp cấu hình Nginx (Test)
    if command -v nginx >/dev/null 2>&1; then
        log INFO "Kiểm tra cú pháp cấu hình: 'nginx -t'..."
        if ! nginx -t; then
            log ERROR "Cấu hình Nginx không hợp lệ! Dừng triển khai ngay lập tức."
            false # trigger ERR trap
        fi
        log INFO "Cú pháp Nginx hợp lệ (nginx -t [OK])."

        # Reload dịch vụ an toàn (Reload)
        log INFO "Thực hiện reload Nginx an toàn..."
        if systemctl is-active --quiet nginx; then
            systemctl reload nginx
        else
            systemctl restart nginx || systemctl start nginx
        fi
    else
        log WARN "Nginx chưa được cài đặt trên hệ thống này, bỏ qua reload Nginx."
    fi

    # Bước 4: Kiểm tra xác nhận hoạt động (Verify)
    log INFO "[4/4] Xác nhận dịch vụ sau khi reload (Verify: $VERIFY_URL)..."
    sleep 1

    local verify_success=0
    if command -v curl >/dev/null 2>&1; then
        # Thử curl tối đa 3 lần
        for i in {1..3}; do
            local http_code
            http_code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 3 "$VERIFY_URL" || true)"
            if [[ "$http_code" =~ ^(200|301|302)$ ]]; then
                log INFO "Verify thành công: HTTP $http_code từ $VERIFY_URL (lần thử $i)"
                verify_success=1
                break
            else
                log WARN "Lần thử $i: $VERIFY_URL trả về mã HTTP $http_code, thử lại sau 2 giây..."
                sleep 2
            fi
        done

        if [[ "$verify_success" -ne 1 ]]; then
            log ERROR "Xác nhận thất bại: $VERIFY_URL không phản hồi HTTP 200/30x hợp lệ sau khi reload!"
            false # trigger ERR trap -> perform_rollback
        fi
    else
        log WARN "Lệnh curl không khả dụng, bỏ qua bước verify HTTP."
    fi

    # Huỷ bỏ trap sau khi deploy thành công
    trap - ERR

    log INFO "=========================================================="
    log INFO "TRIỂN KHAI THÀNH CÔNG! (Test -> Reload -> Verify: OK)"
    log INFO "Snapshot phiên bản này: $CURRENT_SNAPSHOT"
    log INFO "=========================================================="

    send_alert INFO "Deploy TaskOps thành công phiên bản mới tại $WEB_ROOT_DEFAULT"
    return 0
}

main "$@"
