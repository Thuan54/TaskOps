#!/usr/bin/env bash
# ============================================================================
# lib/template.sh - MẪU cho các công cụ con (deploy, backup, restore, ...)
# Sao chép file này ra toolkit/ (ví dụ toolkit/backup.sh), rồi sửa phần "NỘI DUNG".
#
# Mẫu đã có sẵn: strict mode + trap (qua lib/common.sh), getopts, --help,
# kiểm tra đầu vào, ghi log có cấu trúc.
# ============================================================================
# Tìm thư mục gốc của toolkit (chứa lib/); chạy được cả khi file còn nằm trong lib/ lẫn khi đã chép ra toolkit/
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -f "$_here/lib/common.sh" ]]; then
  TOOLKIT_DIR="$_here"
else
  TOOLKIT_DIR="$(cd "$_here/.." && pwd)"
fi
export TOOLKIT_DIR
# shellcheck source=/dev/null
source "$TOOLKIT_DIR/lib/common.sh"

# shellcheck disable=SC2034 # biến này được lib/log.sh sử dụng
LOG_COMPONENT="template"
# Nếu chạy qua toolkit.sh thì dùng chung file log; chạy riêng thì tự chọn.
log_init

usage() {
  cat <<EOT
Sử dụng: ${0##*/} [-h] [-n NGÀY] [-d]

  -h        Hiện hướng dẫn này
  -n NGÀY   Số ngày lưu giữ (mặc định 7, từ 1 đến 365)
  -d        Chạy thử, không thay đổi gì (dry-run)
EOT
}

main() {
  local days=7 dry_run=0 opt arg
  # getopts không hiểu --help, nên xử lý riêng
  for arg in "$@"; do
    if [[ "$arg" == "--help" ]]; then
      usage
      exit "$EX_OK"
    fi
  done
  OPTIND=1
  while getopts ':hn:d' opt; do
    case "$opt" in
      h)
        usage
        exit "$EX_OK"
        ;;
      n) days=$OPTARG ;;
      d) dry_run=1 ;;
      :)
        usage >&2
        die "$EX_USAGE" "Tùy chọn -$OPTARG cần một giá trị"
        ;;
      \?)
        usage >&2
        die "$EX_USAGE" "Tùy chọn không hợp lệ: -$OPTARG"
        ;;
    esac
  done
  shift $((OPTIND - 1))

  # --- Kiểm tra đầu vào ---
  validate_uint "số ngày (-n)" "$days" 1 365
  require_cmd date

  # --- NỘI DUNG ---
  log_info "Bắt đầu" "days=$days" "dry_run=$dry_run"
  # ... việc cần làm ...
  log_info "Hoàn tất"
}

main "$@"
