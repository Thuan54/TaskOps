#!/usr/bin/env bash
# ============================================================================
# toolkit-script-template.sh - MẪU cho các công cụ con (deploy, backup, restore, ...)
# Dùng: sao chép file này thành toolkit/bin/<tên>.sh rồi sửa phần "NỘI DUNG".
#
# Mẫu đã có sẵn: strict mode + trap (qua lib/common.sh), getopts, --help,
# kiểm tra đầu vào, ghi log có cấu trúc.
# ============================================================================
# Tìm thư mục gốc của toolkit (chứa lib/common.sh). Khi để ở toolkit/bin/ thì là thư mục cha;
# khi chạy thử ngay tại docs/ thì là ../toolkit.
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for _d in "$_here/.." "$_here/../toolkit"; do
  if [[ -f "$_d/lib/common.sh" ]]; then
    TOOLKIT_DIR="$(cd "$_d" && pwd)"
    break
  fi
done
: "${TOOLKIT_DIR:?Không tìm thấy lib/common.sh}"
export TOOLKIT_DIR
# shellcheck source=/dev/null
source "$TOOLKIT_DIR/lib/common.sh"

# shellcheck disable=SC2034 # biến này được lib/common.sh sử dụng
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
