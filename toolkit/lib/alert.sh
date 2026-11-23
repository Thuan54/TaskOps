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
#   2. send_alert LUÔN trả về 0: gửi cảnh báo hỏng (mất mạng, sai token)
#      không được làm sập script đang chạy (backup, healthcheck...)
#   3. Token không xuất hiện trên dòng lệnh (tránh lộ qua `ps`) và không bị ghi vào log

# cấu hình
: "${ALERT_ENV_FILE:=/etc/taskops-toolkit/alert.env}"
: "${ALERT_TIMEOUT:=10}"     # số giây tối đa chờ mỗi lần gửi, tránh treo script

# hàm log dự phòng
# Nếu script gọi đã có hàm log() (từ common.sh của F1) thì dùng hàm đó,
# nếu chưa có thì dùng bản tạm, ghi ra stderr.
if ! declare -F log >/dev/null; then
    log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
fi

# KÊNH 1: TELEGRAM 
_alert_telegram() {
    local text="$1"
    # URL chứa token nên đưa cho curl qua stdin (-K -) thay vì ghi trên dòng lệnh,
    # nếu không ai chạy `ps` cũng thấy token.
    #   -sS         : im lặng nhưng vẫn báo lỗi
    #   --fail      : mã HTTP >= 400 (sai token, sai chat id) thì curl trả về lỗi
    #   --max-time  : giới hạn thời gian
    #   --data-urlencode : tự mã hóa ký tự đặc biệt/tiếng Việt, và chuyển sang POST
    # stderr bỏ đi (2>/dev/null) để thông báo lỗi của curl không lộ chi tiết nhạy cảm.
    printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$TELEGRAM_BOT_TOKEN" \
        | curl -sS --fail --max-time "$ALERT_TIMEOUT" -K - \
               --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
               --data-urlencode "text=${text}" \
               -o /dev/null 2>/dev/null
}

# KÊNH 2: EMAIL QUA MSMTP 
# Chỉ dùng khi file bí mật có ALERT_EMAIL_TO và máy đã cài + cấu hình msmtp.
_alert_email() {
    local text="$1" subject
    command -v msmtp >/dev/null 2>&1 || return 1
    # Tiêu đề lấy 80 ký tự đầu, thay xuống dòng bằng dấu cách
    # (xuống dòng trong header email có thể bị lợi dụng để chèn header giả)
    subject="[TaskOps] ${text:0:80}"
    subject="${subject//$'\n'/ }"
    printf 'To: %s\nSubject: %s\n\n%s\n' "$ALERT_EMAIL_TO" "$subject" "$text" \
        | msmtp --timeout="$ALERT_TIMEOUT" "$ALERT_EMAIL_TO" 2>/dev/null
}

# send_alert <MỨC ĐỘ> <NỘI DUNG>
#   MỨC ĐỘ: INFO | WARN | CRIT (chỉ dùng để gắn nhãn đầu tin nhắn)
send_alert() {
    local level="${1:-INFO}" message="${2:-}" host text
    host=$(hostname -s)
    text="[${level}] ${host}: ${message}"
    # Telegram giới hạn 4096 ký tự mỗi tin; cắt bớt để không bị từ chối
    text="${text:0:3500}"

    log INFO "alert: ${level} - ${message}"

    # Chạy trong subshell ( ... ) để việc `source` file bí mật bên dưới
    # không làm rò biến TELEGRAM_BOT_TOKEN ra script đang gọi.
    # "|| true" cuối cùng đảm bảo mọi lỗi bất ngờ cũng không làm sập script gọi.
    (
        if [[ ! -r "$ALERT_ENV_FILE" ]]; then
            log WARN "alert: không đọc được $ALERT_ENV_FILE, bỏ qua cảnh báo"
            exit 0
        fi

        # Cảnh báo nếu file bí mật cho nhóm/người khác đọc (quyền phải là 600 hoặc 400)
        local mode
        mode=$(stat -c '%a' "$ALERT_ENV_FILE")
        if [[ "${mode: -2}" != "00" ]]; then
            log WARN "alert: $ALERT_ENV_FILE có quyền $mode, nên chạy: chmod 600"
        fi

        # shellcheck source=/dev/null
        source "$ALERT_ENV_FILE"

        local sent=0
        if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
            if _alert_telegram "$text"; then
                sent=1
                log INFO "alert: đã gửi qua Telegram"
            else
                log WARN "alert: gửi Telegram thất bại (kiểm tra mạng, token, chat id)"
            fi
        fi

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

# CHẾ ĐỘ CHẠY TRỰC TIẾP (để test hoặc systemd OnFailure/ExecStopPost gọi)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    arg1="${1:-INFO}"
    arg2="${2:-Tin nhắn thử từ alert.sh}"
    case "${arg1^^}" in
        INFO|WARN|WARNING|CRIT|CRITICAL|ERROR)
            send_alert "${arg1^^}" "$arg2"
            ;;
        *)
            # Nếu $1 là tiêu đề tự do (ví dụ từ systemd service: "[TaskOps] todo-backup thất bại..."):
            send_alert "CRIT" "${arg1}: ${arg2}"
            ;;
    esac
fi
