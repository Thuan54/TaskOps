#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034
# ============================================================================
# lib/common.sh - Nền tảng dùng chung cho mọi script trong toolkit
#
#   * Chế độ nghiêm ngặt: set -Eeuo pipefail
#   * Mã thoát chuẩn (EX_*)
#   * trap ERR / EXIT / INT / TERM: báo lỗi rõ ràng, dọn file tạm
#   * Nạp luôn lib/log.sh (F04) và lib/validate.sh (F05)
#
# Cách dùng trong một script nằm trong toolkit/:
#   TOOLKIT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
#   source "$TOOLKIT_DIR/lib/common.sh"
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

# ---------------------------------------------------------------------------
# Nạp các thư viện con
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$TOOLKIT_DIR/lib/log.sh"
# shellcheck source=/dev/null
source "$TOOLKIT_DIR/lib/validate.sh"

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

# die MÃ_THOÁT "thông báo": ghi log lỗi rồi thoát
die() {
  local code=$1
  shift
  log_error "$*"
  exit "$code"
}
