#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# lib/log.sh - Structured logging (F04)
#
# Mỗi dòng log có các trường cố định: thời gian, mức độ, thành phần, PID,
# thông điệp, và các cặp key=value tùy chọn.
#
#   Định dạng text (mặc định):
#     2026-10-15T10:00:00+0700 INFO  backup[1234] Bắt đầu sao lưu db=taskops_db
#   Định dạng JSON (LOG_FORMAT=json):
#     {"ts":"2026-10-15T10:00:00+0700","level":"INFO","component":"backup",
#      "pid":1234,"msg":"Bắt đầu sao lưu","db":"taskops_db"}
#
# Biến môi trường (đều có giá trị mặc định):
#   LOG_LEVEL      DEBUG | INFO | WARN | ERROR      (mặc định INFO)
#   LOG_FORMAT     text | json                      (mặc định text)
#   LOG_COMPONENT  tên thành phần ghi log           (mặc định tên script)
#   LOG_FILE       file log; nếu trống sẽ chọn trong log_init
#   TASKOPS_LOG_DIR thư mục log (mặc định /var/log/taskops)
#
# Dùng:  log_info "Thông điệp" "khoá=giá trị" "khoá2=giá trị2"
# Log luôn ra stderr (có màu nếu là terminal) và ghi vào LOG_FILE.
# ============================================================================

: "${LOG_LEVEL:=INFO}"
: "${LOG_FORMAT:=text}"
: "${TASKOPS_LOG_DIR:=/var/log/taskops}"
: "${LOG_FILE:=}"

if [[ -z "${LOG_COMPONENT:-}" ]]; then
  LOG_COMPONENT="${0##*/}"
  LOG_COMPONENT="${LOG_COMPONENT%.sh}"
fi

_LOG_FILE_WARNED=""

# Đổi tên mức độ sang số để so sánh
_log_level_num() {
  case "${1^^}" in
    DEBUG) echo 10 ;;
    INFO) echo 20 ;;
    WARN | WARNING) echo 30 ;;
    ERROR) echo 40 ;;
    *) echo 20 ;;
  esac
}

# Thoát ký tự đặc biệt cho JSON
_json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Chọn và chuẩn bị file log. Nếu không ghi được vào TASKOPS_LOG_DIR
# (ví dụ chạy bằng user thường) thì dùng thư mục trong $HOME.
log_init() {
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p -- "$(dirname -- "$LOG_FILE")" 2>/dev/null || true
    return 0
  fi
  local dir="$TASKOPS_LOG_DIR"
  if ! { mkdir -p -- "$dir" 2>/dev/null && [[ -w "$dir" ]]; }; then
    dir="${XDG_STATE_HOME:-$HOME/.local/state}/taskops"
    mkdir -p -- "$dir"
  fi
  LOG_FILE="$dir/toolkit.log"
}

# _log MỨC "thông điệp" [key=value ...]
_log() {
  local level=$1 msg=${2:-}
  shift $(($# >= 2 ? 2 : $#))

  # Bỏ qua nếu thấp hơn mức cấu hình
  (($(_log_level_num "$level") >= $(_log_level_num "$LOG_LEVEL"))) || return 0

  local ts line kv key val
  ts=$(date '+%Y-%m-%dT%H:%M:%S%z')

  if [[ "$LOG_FORMAT" == "json" ]]; then
    line="{\"ts\":\"$ts\",\"level\":\"$level\",\"component\":\"$(_json_escape "$LOG_COMPONENT")\",\"pid\":$$,\"msg\":\"$(_json_escape "$msg")\""
    for kv in "$@"; do
      key=${kv%%=*}
      val=${kv#*=}
      line+=",\"$(_json_escape "$key")\":\"$(_json_escape "$val")\""
    done
    line+="}"
  else
    line=$(printf '%s %-5s %s[%s] %s' "$ts" "$level" "$LOG_COMPONENT" "$$" "$msg")
    for kv in "$@"; do
      line+=" $kv"
    done
  fi

  # Ra console (stderr), có màu khi là terminal
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    local color
    case "$level" in
      DEBUG) color=$'\e[90m' ;;
      INFO) color=$'\e[32m' ;;
      WARN) color=$'\e[33m' ;;
      ERROR) color=$'\e[31m' ;;
      *) color="" ;;
    esac
    printf '%s%s\e[0m\n' "$color" "$line" >&2
  else
    printf '%s\n' "$line" >&2
  fi

  # Ghi vào file; nếu lỗi thì cảnh báo một lần (không im lặng)
  if [[ -n "$LOG_FILE" ]]; then
    if ! printf '%s\n' "$line" 2>/dev/null >>"$LOG_FILE"; then
      if [[ -z "$_LOG_FILE_WARNED" ]]; then
        _LOG_FILE_WARNED=1
        printf 'CẢNH BÁO: không ghi được vào file log %s\n' "$LOG_FILE" >&2
      fi
    fi
  fi
  return 0
}

log_debug() { _log DEBUG "$@"; }
log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }

# Tương thích kiểu cũ: log MỨC "thông điệp" [khóa=giá trị ...]
# (ví dụ log ERROR "Thiếu thư mục"), để script viết theo kiểu này chạy được mà không phải sửa từng dòng.
log() {
  local level=${1:-INFO}
  shift || true
  _log "${level^^}" "$@"
}
