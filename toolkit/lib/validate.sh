#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# lib/validate.sh - Kiểm tra đầu vào và điều kiện chạy (F05)
#
# Mọi hàm đều dừng script bằng die() kèm mã thoát phù hợp khi kiểm tra
# thất bại, thay vì để lỗi xảy ra muộn hoặc âm thầm.
# Yêu cầu: lib/common.sh đã được nạp (cung cấp die và các mã EX_*).
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
