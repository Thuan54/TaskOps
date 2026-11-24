#!/usr/bin/env bash
# healthcheck.sh - Kiểm tra sức khỏe hệ thống (F12) và gửi cảnh báo tự động (F13)
# Giám sát: CPU, RAM, Dung lượng đĩa (/ và /srv/backup), Cổng lắng nghe (Ports), Dịch vụ systemd

set -Eeuo pipefail

# Xác định thư mục script và nạp các thư viện dùng chung
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TOOLKIT_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
LIB_DIR="$TOOLKIT_DIR/lib"
CONF_DIR="$TOOLKIT_DIR/conf"

# Nạp thư viện chung nếu có (F01-F05)
if [[ -f "$LIB_DIR/common.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/common.sh"
fi

# Nạp thư viện cảnh báo nếu có (F13)
if [[ -f "$LIB_DIR/alert.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/alert.sh"
fi
if ! declare -F send_alert >/dev/null; then
    send_alert() { :; }
fi

# Hàm log và die dự phòng nếu chưa nạp common.sh
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

# File cấu hình mặc định
CUSTOM_CONF=""
HEALTH_CONF="/etc/taskops-toolkit/health.conf"

usage() {
    cat <<EOF
Cách dùng: $0 [tùy chọn]

Kiểm tra sức khỏe hệ thống TaskOps (F12) và kích hoạt cảnh báo khi có sự cố (F13).
Giám sát: CPU, RAM, Dung lượng đĩa, Cổng lắng nghe (Ports), và Trạng thái dịch vụ.

Tùy chọn:
  -c FILE, --conf=FILE   Đường dẫn tới file cấu hình ngưỡng (mặc định: $HEALTH_CONF)
  -h, --help             Hiển thị hướng dẫn này

Mã thoát:
  0: Hệ thống hoạt động tốt (HEALTHY)
  1: Phát hiện ít nhất một sự cố hoặc thông số vượt ngưỡng (UNHEALTHY)
EOF
}

# Xử lý tham số dòng lệnh
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -c|--conf)
                CUSTOM_CONF="${2:-}"
                shift 2
                ;;
            --conf=*)
                CUSTOM_CONF="${1#*=}"
                shift
                ;;
            *)
                log WARN "Tham số không hợp lệ: $1 (bỏ qua)"
                shift
                ;;
        esac
    done
}

# Nạp file cấu hình ngưỡng
load_config() {
    if [[ -n "$CUSTOM_CONF" ]]; then
        if [[ -f "$CUSTOM_CONF" ]]; then
            HEALTH_CONF="$CUSTOM_CONF"
        else
            log WARN "Không tìm thấy file cấu hình chỉ định: $CUSTOM_CONF, dùng mặc định"
        fi
    fi

    # Nếu file cấu hình ở /etc chưa có, thử tìm trong thư mục conf của repo
    if [[ ! -f "$HEALTH_CONF" && -f "$CONF_DIR/health.conf" ]]; then
        HEALTH_CONF="$CONF_DIR/health.conf"
    fi

    if [[ -f "$HEALTH_CONF" ]]; then
        # shellcheck source=/dev/null
        source "$HEALTH_CONF"
        log INFO "Đã nạp file cấu hình: $HEALTH_CONF"
    else
        log INFO "Không tìm thấy health.conf, áp dụng ngưỡng mặc định"
    fi

    # Thiết lập giá trị mặc định nếu biến chưa được gán
    : "${MAX_CPU_USAGE:=80}"
    : "${MAX_RAM_USAGE:=85}"
    : "${MAX_ROOT_DISK_USAGE:=90}"
    : "${MAX_BACKUP_DISK_USAGE:=85}"
    : "${MONITORED_SERVICES:=postgresql nginx taskops}"
    : "${MONITORED_PORTS:=80 443 5432 5000}"
}

failed_checks=0

# 1. Kiểm tra mức tải CPU (%)
check_cpu() {
    local cpu_usage=""
    if command -v vmstat >/dev/null 2>&1; then
        cpu_usage=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print 100 - $15}')
    fi

    # Fallback bằng top nếu vmstat không trả về số
    if [[ -z "$cpu_usage" || ! "$cpu_usage" =~ ^[0-9]+$ ]]; then
        cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%.0f", 100 - $1}')
    fi

    if [[ -n "$cpu_usage" && "$cpu_usage" =~ ^[0-9]+$ ]]; then
        if (( cpu_usage > MAX_CPU_USAGE )); then
            log WARN "CPU vượt ngưỡng: ${cpu_usage}% (ngưỡng: ${MAX_CPU_USAGE}%)"
            send_alert WARN "CPU quá tải: ${cpu_usage}% (vượt ngưỡng cho phép ${MAX_CPU_USAGE}%)"
            failed_checks=$((failed_checks + 1))
        else
            log INFO "CPU ổn định: ${cpu_usage}% (ngưỡng: ${MAX_CPU_USAGE}%)"
        fi
    else
        log WARN "Không đo được thông số CPU"
    fi
}

# 2. Kiểm tra bộ nhớ RAM (%)
check_ram() {
    local ram_usage=""
    if command -v free >/dev/null 2>&1; then
        ram_usage=$(free -m 2>/dev/null | awk '/Mem:/ {if ($2 > 0) printf "%.0f", ($3/$2)*100; else print 0}')
    fi

    if [[ -n "$ram_usage" && "$ram_usage" =~ ^[0-9]+$ ]]; then
        if (( ram_usage > MAX_RAM_USAGE )); then
            log WARN "RAM vượt ngưỡng: ${ram_usage}% (ngưỡng: ${MAX_RAM_USAGE}%)"
            send_alert WARN "Bộ nhớ RAM quá tải: ${ram_usage}% (vượt ngưỡng cho phép ${MAX_RAM_USAGE}%)"
            failed_checks=$((failed_checks + 1))
        else
            log INFO "RAM ổn định: ${ram_usage}% (ngưỡng: ${MAX_RAM_USAGE}%)"
        fi
    else
        log WARN "Không đo được thông số RAM"
    fi
}

# 3. Kiểm tra dung lượng các phân vùng ổ đĩa
check_disk_usage() {
    # Kiểm tra phân vùng gốc /
    local root_usage
    root_usage=$(df / --output=pcent | tail -n 1 | tr -dc '0-9')
    if (( root_usage > MAX_ROOT_DISK_USAGE )); then
        log WARN "Phân vùng gốc / quá đầy: ${root_usage}% (ngưỡng: ${MAX_ROOT_DISK_USAGE}%)"
        send_alert WARN "Dung lượng đĩa gốc (/) vượt ngưỡng: ${root_usage}%"
        failed_checks=$((failed_checks + 1))
    else
        log INFO "Phân vùng gốc / ổn định: ${root_usage}% (ngưỡng: ${MAX_ROOT_DISK_USAGE}%)"
    fi

    # Kiểm tra phân vùng /srv/backup nếu tồn tại
    if [[ -d "/srv/backup" ]]; then
        local backup_usage
        backup_usage=$(df /srv/backup --output=pcent | tail -n 1 | tr -dc '0-9' || echo "0")
        if [[ -n "$backup_usage" && "$backup_usage" =~ ^[0-9]+$ ]]; then
            if (( backup_usage > MAX_BACKUP_DISK_USAGE )); then
                log WARN "Phân vùng backup /srv/backup quá đầy: ${backup_usage}% (ngưỡng: ${MAX_BACKUP_DISK_USAGE}%)"
                send_alert WARN "Dung lượng đĩa backup (/srv/backup) vượt ngưỡng: ${backup_usage}%"
                failed_checks=$((failed_checks + 1))
            else
                log INFO "Phân vùng backup /srv/backup ổn định: ${backup_usage}% (ngưỡng: ${MAX_BACKUP_DISK_USAGE}%)"
            fi
        fi
    fi
}

# 4. Kiểm tra trạng thái các cổng mạng TCP bắt buộc phải lắng nghe (LISTEN)
check_ports() {
    local port
    for port in $MONITORED_PORTS; do
        if ss -tlnH sport = :"$port" 2>/dev/null | grep -q LISTEN; then
            log INFO "Cổng mạng $port đang hoạt động (LISTEN)"
        else
            log ERROR "Cổng mạng $port KHÔNG hoạt động (dịch vụ chưa mở hoặc chết cổng)"
            send_alert CRIT "Cổng mạng $port bị đóng hoặc dịch vụ tương ứng gặp sự cố"
            failed_checks=$((failed_checks + 1))
        fi
    done
}

# 5. Kiểm tra trạng thái các dịch vụ systemd
check_services() {
    local svc
    for svc in $MONITORED_SERVICES; do
        local is_active=0
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            is_active=1
        elif [[ "$svc" == "taskops" ]] && systemctl is-active --quiet "taskops-app" 2>/dev/null; then
            # Hỗ trợ linh hoạt nếu dịch vụ backend được đặt tên là taskops-app
            is_active=1
            svc="taskops-app"
        fi

        if (( is_active == 1 )); then
            log INFO "Dịch vụ $svc đang chạy bình thường (active)"
        else
            log ERROR "Dịch vụ $svc đang không hoạt động (inactive/failed)"
            send_alert CRIT "Dịch vụ quan trọng bị dừng: $svc không hoạt động"
            failed_checks=$((failed_checks + 1))
        fi
    done
}

# Luồng thực thi chính
main() {
    parse_args "$@"
    load_config

    log INFO "Bắt đầu kiểm tra sức khỏe hệ thống TaskOps (F12)..."

    check_cpu
    check_ram
    check_disk_usage
    check_ports
    check_services

    if (( failed_checks > 0 )); then
        log ERROR "Healthcheck hoàn tất: phát hiện ${failed_checks} thông số cảnh báo/sự cố."
        exit 1
    else
        log INFO "Healthcheck hoàn tất: toàn bộ hệ thống hoạt động ổn định (OK)."
        exit 0
    fi
}

main "$@"
