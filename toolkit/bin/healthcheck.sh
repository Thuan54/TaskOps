#!/usr/bin/env bash
# healthcheck.sh - Kiểm tra sức khỏe hệ thống (F12) và gửi cảnh báo tự động (F13)
# Giám sát: Dịch vụ systemd (Nginx, PostgreSQL, App), Dung lượng đĩa (/ và /srv/backup)

set -Eeuo pipefail

# Xác định thư mục script và nạp thư viện cảnh báo
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" &>/dev/null && pwd)"
CONF_DIR="$(cd -- "$SCRIPT_DIR/../conf" &>/dev/null && pwd)"

if [[ -f "$LIB_DIR/alert.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/alert.sh"
fi

if ! declare -F send_alert >/dev/null; then
    send_alert() { :; }
fi

# Nạp file cấu hình ngưỡng (nếu có ở /etc hoặc trong toolkit/conf)
HEALTH_CONF="/etc/taskops-toolkit/health.conf"
if [[ ! -f "$HEALTH_CONF" && -f "$CONF_DIR/health.conf" ]]; then
    HEALTH_CONF="$CONF_DIR/health.conf"
fi

if [[ -f "$HEALTH_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$HEALTH_CONF"
fi

# Thiết lập giá trị mặc định nếu chưa cấu hình
: "${MAX_ROOT_DISK_USAGE:=90}"
: "${MAX_BACKUP_DISK_USAGE:=85}"
: "${MONITORED_SERVICES:=postgresql nginx taskops-app}"

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }

failed_checks=0

# 1. Kiểm tra trạng thái các dịch vụ systemd
check_services() {
    local svc
    for svc in $MONITORED_SERVICES; do
        if ! systemctl is-active --quiet "$svc"; then
            log ERROR "Dịch vụ $svc đang không hoạt động (stopped/failed)"
            send_alert CRIT "Dịch vụ quan trọng bị dừng: $svc không hoạt động"
            failed_checks=$((failed_checks + 1))
        else
            log INFO "Dịch vụ $svc hoạt động bình thường"
        fi
    done
}

# 2. Kiểm tra dung lượng đĩa trên các phân vùng quan trọng
check_disk_usage() {
    # Kiểm tra phân vùng gốc /
    local root_usage
    root_usage=$(df / --output=pcent | tail -n 1 | tr -dc '0-9')
    if (( root_usage > MAX_ROOT_DISK_USAGE )); then
        log WARN "Phân vùng gốc / đã đầy: ${root_usage}% (ngưỡng: ${MAX_ROOT_DISK_USAGE}%)"
        send_alert WARN "Dung lượng đĩa gốc (/) vượt ngưỡng cảnh báo: ${root_usage}%"
        failed_checks=$((failed_checks + 1))
    fi

    # Kiểm tra phân vùng backup /srv/backup (nếu tồn tại)
    if [[ -d "/srv/backup" ]]; then
        local backup_usage
        backup_usage=$(df /srv/backup --output=pcent | tail -n 1 | tr -dc '0-9' || echo "0")
        if (( backup_usage > MAX_BACKUP_DISK_USAGE )); then
            log WARN "Phân vùng backup /srv/backup đã đầy: ${backup_usage}% (ngưỡng: ${MAX_BACKUP_DISK_USAGE}%)"
            send_alert WARN "Dung lượng đĩa backup (/srv/backup) vượt ngưỡng: ${backup_usage}%"
            failed_checks=$((failed_checks + 1))
        fi
    fi
}

# Luồng thực thi chính
main() {
    log INFO "Bắt đầu quét sức khỏe hệ thống (Healthcheck)..."
    
    check_services
    check_disk_usage

    if (( failed_checks > 0 )); then
        log ERROR "Healthcheck hoàn tất: phát hiện ${failed_checks} sự cố."
        exit 1
    else
        log INFO "Healthcheck hoàn tất: mọi hệ thống hoạt động ổn định."
        exit 0
    fi
}

main "$@"
