#!/usr/bin/env bash
# shellcheck shell=bash
# alert.sh - Thư viện gửi cảnh báo (F13)
#
# CÁCH DÙNG TRONG SCRIPT KHÁC:
#   source "$SCRIPT_DIR/../lib/alert.sh"
#   send_alert CRIT "Nginx đã dừng"
#
# CÁCH TEST / GỌI TRỰC TIẾP TỪ CLI HOẶC SYSTEMD:
#   sudo ./toolkit/lib/alert.sh CRIT "Tin nhắn thử"
#   sudo ./toolkit/lib/alert.sh "[TaskOps] Service lỗi" "Chi tiết lỗi"
#
# NGUYÊN TẮC THIẾT KẾ:
#   1. Bí mật (token, chat id) nằm trong file RIÊNG ngoài repo, quyền 600
#   2. send_alert LUÔN trả về 0: gửi cảnh báo hỏng không được làm sập script
#   3. Token không xuất hiện trên dòng lệnh và không bị ghi vào log

# ===== CẤU HÌNH =====
: "${ALERT_ENV_FILE:=/etc/taskops-toolkit/alert.env}"
: "${ALERT_TIMEOUT:=10}"

# ===== HÀM LOG DỰ PHÒNG =====
if ! declare -F log >/dev/null; then
    log() {
        printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2
    }
fi

# ===== KÊNH 1: TELEGRAM =====
_alert_telegram() {
    local text="$1"

    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
        | curl -sS --fail --max-time "$ALERT_TIMEOUT" -K - \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${text}" \
            -o /dev/null 2>/dev/null
}

# ===== KÊNH 2: EMAIL QUA MSMTP =====
_alert_email() {
    local text="$1"
    local subject

    command -v msmtp >/dev/null 2>&1 || return 1

    subject="[TaskOps] ${text:0:80}"
    subject="${subject//$'\n'/ }"

    printf 'To: %s\nSubject: %s\n\n%s\n' \
        "$ALERT_EMAIL_TO" "$subject" "$text" \
        | msmtp --timeout="$ALERT_TIMEOUT" "$ALERT_EMAIL_TO" 2>/dev/null
}

# ===== HÀM GỬI CẢNH BÁO =====
# send_alert <MỨC ĐỘ> <NỘI DUNG>
#   MỨC ĐỘ: INFO | WARN | CRIT | ERROR
send_alert() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local host text

    host=$(hostname -s)
    text="[${level}] ${host}: ${message}"

    # Telegram giới hạn 4096 ký tự mỗi tin.
    text="${text:0:3500}"

    log INFO "alert: ${level} - ${message}"

    # Chạy trong subshell để không làm rò biến bí mật ra script gọi.
    (
        if [[ ! -r "$ALERT_ENV_FILE" ]]; then
            log WARN "alert: không đọc được $ALERT_ENV_FILE, bỏ qua cảnh báo"
            exit 0
        fi

        # Kiểm tra quyền truy cập file bí mật.
        local mode
        mode=$(stat -c '%a' "$ALERT_ENV_FILE") || {
            log WARN "alert: không kiểm tra được quyền file cấu hình"
            exit 0
        }

        if [[ "${mode: -2}" != "00" ]]; then
            log WARN "alert: $ALERT_ENV_FILE có quyền $mode, nên chạy: chmod 600"
        fi

        # Nạp cấu hình bí mật.
        # shellcheck source=/dev/null
        source "$ALERT_ENV_FILE"

        local sent=0

        # Gửi Telegram nếu có cấu hình.
        if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
            if _alert_telegram "$text"; then
                sent=1
                log INFO "alert: đã gửi qua Telegram"
            else
                log WARN "alert: gửi Telegram thất bại (kiểm tra mạng, token, chat id)"
            fi
        fi

        # Gửi email nếu có cấu hình.
        if [[ -n "${ALERT_EMAIL_TO:-}" ]]; then
            if _alert_email "$text"; then
                sent=1
                log INFO "alert: đã gửi email tới $ALERT_EMAIL_TO"
            else
                log WARN "alert: gửi email thất bại (msmtp chưa cài hoặc chưa cấu hình?)"
            fi
        fi

        if (( sent == 0 )); then
            log WARN "alert: KHÔNG có kênh nào gửi được tin này"
        fi
    ) || true

    return 0
}

# ===== CHẾ ĐỘ CHẠY TRỰC TIẾP =====
# Hỗ trợ:
#   alert.sh CRIT "Nội dung"
#   alert.sh WARN "Nội dung"
#   alert.sh "[TaskOps] Service lỗi" "Chi tiết lỗi"
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail

    arg1="${1:-INFO}"
    arg2="${2:-Tin nhắn thử từ alert.sh}"

    case "${arg1^^}" in
        INFO|WARN|WARNING|CRIT|CRITICAL|ERROR)
            send_alert "${arg1^^}" "$arg2"
            ;;
        *)
            send_alert "CRIT" "${arg1}: ${arg2}"
            ;;
    esac
fi
