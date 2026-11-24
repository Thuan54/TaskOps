#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# ============================================================================
# lib/common.sh - Nền tảng dùng chung cho mọi script trong toolkit
#
#   * Chế độ nghiêm ngặt: set -Eeuo pipefail
#   * Mã thoát chuẩn (EX_*)
#   * trap ERR / EXIT / INT / TERM: báo lỗi rõ ràng, dọn file tạm
#   * Structured logging (log_*) và các hàm kiểm tra đầu vào (require_*, validate_*)
#
# Cách dùng trong một script nằm trong toolkit/bin/:
#   # shellcheck source=/dev/null
#   source "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)/common.sh"
# ============================================================================

# Chỉ nạp một lần
if [[ -n "${_TOOLKIT_COMMON_LOADED:-}" ]]; then
  return 0
fi
_TOOLKIT_COMMON_LOADED=1

# -E: ERR trap có hiệu lực trong hàm; -e: dừng khi lệnh lỗi;
# -u: dùng biến chưa gán là lỗi; pipefail: lỗi trong pipe không bị che
set -Eeuo pipefail

readonly TOOLKIT_NAME="taskops-toolkit"
readonly TOOLKIT_VERSION="1.0.0"

# Mã thoát
readonly EX_OK=0
readonly EX_GENERAL=1    # lỗi chung
readonly EX_USAGE=2      # sai tham số / sai cú pháp
readonly EX_NODEP=3      # thiếu lệnh/công cụ cần thiết
readonly EX_NOPERM=4     # thiếu quyền (ví dụ cần root)
readonly EX_NOFILE=5     # không tìm thấy file/thư mục
readonly EX_INTERRUPT=130

# Thư mục gốc của toolkit (cha của lib/)
: "${TOOLKIT_DIR:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)}"
export TOOLKIT_DIR

SECONDS=0

# ===========================================================================
# PHẦN 1: Structured logging (F04)
# ===========================================================================
# ============================================================================
# Structured logging (F04)
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

# ===========================================================================
# PHẦN 2: Kiểm tra đầu vào (F05)
# ===========================================================================
# ============================================================================
# Kiểm tra đầu vào và điều kiện chạy (F05)
#
# Mọi hàm đều dừng script bằng die() kèm mã thoát phù hợp khi kiểm tra
# thất bại, thay vì để lỗi xảy ra muộn hoặc âm thầm.
# ============================================================================

# require_cmd lệnh... : mọi lệnh phải có trong PATH
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$EX_NODEP" "Thiếu lệnh cần thiết: $c"
  done
}

# require_root : phải chạy bằng root
require_root() {
  [[ $EUID -eq 0 ]] || die "$EX_NOPERM" "Cần chạy với quyền root (hãy dùng sudo)"
}

# require_file đường_dẫn : file phải tồn tại và đọc được
require_file() {
  [[ -f "$1" ]] || die "$EX_NOFILE" "Không tìm thấy file: $1"
  [[ -r "$1" ]] || die "$EX_NOPERM" "Không đọc được file: $1"
}

# require_dir đường_dẫn : thư mục phải tồn tại
require_dir() {
  [[ -d "$1" ]] || die "$EX_NOFILE" "Không tìm thấy thư mục: $1"
}

# is_uint giá_trị : true nếu là số nguyên không âm
is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# validate_uint TÊN GIÁ_TRỊ [MIN] [MAX]
validate_uint() {
  local name=$1 val=$2 min=${3:-0} max=${4:-}
  is_uint "$val" || die "$EX_USAGE" "$name phải là số nguyên không âm (nhận được: '$val')"
  ((val >= min)) || die "$EX_USAGE" "$name phải >= $min (nhận được: $val)"
  if [[ -n "$max" ]]; then
    ((val <= max)) || die "$EX_USAGE" "$name phải <= $max (nhận được: $val)"
  fi
}

# validate_choice TÊN GIÁ_TRỊ lựa_chọn...
validate_choice() {
  local name=$1 val=$2 c
  shift 2
  for c in "$@"; do
    [[ "$val" == "$c" ]] && return 0
  done
  die "$EX_USAGE" "$name không hợp lệ: '$val' (hợp lệ: $*)"
}

# validate_name TÊN GIÁ_TRỊ : chỉ chữ, số, '.', '_', '-' (dùng cho tên DB, nhãn...)
validate_name() {
  local name=$1 val=$2
  [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "$EX_USAGE" "$name chỉ được chứa chữ, số, '.', '_', '-' (nhận được: '$val')"
}

# validate_path TÊN GIÁ_TRỊ : không rỗng, không có '..', không ký tự nguy hiểm
validate_path() {
  local name=$1 val=$2
  [[ -n "$val" ]] || die "$EX_USAGE" "$name không được để trống"
  [[ "$val" != *..* ]] || die "$EX_USAGE" "$name không được chứa '..' (nhận được: '$val')"
  [[ "$val" =~ ^[A-Za-z0-9_./@:+-]+$ ]] ||
    die "$EX_USAGE" "$name chứa ký tự không hợp lệ (nhận được: '$val')"
}

# confirm "Câu hỏi?" : hỏi có/không, mặc định là không. Trả về 0 nếu đồng ý.
confirm() {
  local ans
  read -r -p "$1 [y/N]: " ans || return 1
  [[ "$ans" =~ ^[yY]([eE][sS])?$ ]]
}

# ---------------------------------------------------------------------------
# File tạm: đăng ký để tự xóa khi script kết thúc (kể cả khi lỗi)
# Chỉ đăng ký file/thư mục tạm do chính script tạo ra.
# ---------------------------------------------------------------------------
_CLEANUP_PATHS=()

register_cleanup() {
  _CLEANUP_PATHS+=("$@")
}

# make_tmp BIẾN : tạo file tạm, gán đường dẫn vào BIẾN và đăng ký dọn dẹp.
# (Không dùng $(make_tmp) vì command substitution chạy trong subshell,
#  đăng ký dọn dẹp sẽ bị mất.)
make_tmp() {
  local -n _out_ref=$1
  _out_ref=$(mktemp "${TMPDIR:-/tmp}/${TOOLKIT_NAME}.XXXXXX")
  register_cleanup "$_out_ref"
}

# ---------------------------------------------------------------------------
# Trap
# ---------------------------------------------------------------------------
_ERR_REPORTED=""

# Gọi khi một lệnh trả về mã lỗi (ERR). Chỉ báo lỗi đầu tiên để tránh lặp.
_on_err() {
  local rc=$1 line=$2 cmd=$3
  [[ -z "$_ERR_REPORTED" ]] || return 0
  _ERR_REPORTED=1
  local where="${BASH_SOURCE[1]:-$0}"
  log_error "Lệnh bị lỗi: ${cmd}" "file=${where##*/}" "line=${line}" "exit_code=${rc}"
}

# Gọi khi script kết thúc (dù thành công hay lỗi)
_on_exit() {
  local rc=$?
  trap - ERR
  local p
  for p in "${_CLEANUP_PATHS[@]}"; do
    [[ -z "$p" ]] || rm -rf -- "$p"
  done
  if ((rc == 0)); then
    log_debug "Kết thúc thành công" "duration_s=${SECONDS}"
  else
    log_error "Kết thúc với lỗi" "exit_code=${rc}" "duration_s=${SECONDS}"
  fi
}

# Gọi khi nhận tín hiệu (Ctrl+C, kill)
_on_signal() {
  local sig=$1 code=$2
  log_warn "Nhận tín hiệu ${sig}, dừng script"
  exit "$code"
}

trap '_on_err $? $LINENO "$BASH_COMMAND"' ERR
trap _on_exit EXIT
trap '_on_signal INT 130' INT
trap '_on_signal TERM 143' TERM

# die [MÃ_THOÁT] "thông báo": ghi log lỗi rồi thoát.
# Gọi die "thông báo" (không có mã) thì thoát với mã 1, để script viết theo kiểu cũ chạy không cần sửa.
die() {
  local code=1
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code=$1
    shift
  fi
  log_error "$*"
  exit "$code"
}
