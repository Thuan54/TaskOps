#!/usr/bin/env bash
# ============================================================================
# toolkit.sh - Điểm vào của bộ công cụ vận hành TaskOps
#
#   toolkit.sh                      mở menu tương tác (F01)
#   toolkit.sh [tùy chọn] <lệnh>    chạy trực tiếp một công cụ
#   toolkit.sh --help               xem hướng dẫn (F02)
# ============================================================================
TOOLKIT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
export TOOLKIT_DIR
# shellcheck source=/dev/null
source "$TOOLKIT_DIR/lib/common.sh"

# shellcheck disable=SC2034 # biến này được lib/log.sh sử dụng
LOG_COMPONENT="toolkit"

# Các công cụ do toolkit điều phối. Mỗi công cụ là một script <lệnh>.sh trong toolkit/bin/ (theo toolkit/README.md).
readonly COMMANDS=(deploy backup restore healthcheck logrotate)
declare -A COMMAND_DESC=(
  [deploy]="Triển khai app/web (test -> reload -> verify, rollback khi lỗi)"
  [backup]="Sao lưu CSDL + nội dung web, nén, retention, rsync sang VM2"
  [restore]="Khôi phục CSDL / nội dung web từ bản sao lưu"
  [healthcheck]="Kiểm tra CPU, RAM, disk, cổng, dịch vụ và cảnh báo"
  [logrotate]="Xoay vòng, nén và xóa log cũ"
)

# ---------------------------------------------------------------------------
# F02 - Hướng dẫn sử dụng
# ---------------------------------------------------------------------------
usage() {
  cat <<EOT
${TOOLKIT_NAME} ${TOOLKIT_VERSION} - Bộ công cụ vận hành TaskOps

SỬ DỤNG
  ${0##*/}                          Mở menu tương tác
  ${0##*/} [tùy chọn chung] <lệnh> [tham số của lệnh]
  ${0##*/} help <lệnh>              Xem hướng dẫn của một lệnh

TÙY CHỌN CHUNG (đặt trước <lệnh>)
  -h, --help          Hiện hướng dẫn này
  -V, --version       Hiện phiên bản
  -v, --verbose       Ghi log chi tiết (mức DEBUG)
  -q, --quiet         Chỉ ghi cảnh báo và lỗi (mức WARN)
  -j, --json          Ghi log dạng JSON
  -l FILE, --log-file=FILE
                      Ghi log vào FILE (mặc định: ${TASKOPS_LOG_DIR}/toolkit.log)

LỆNH
EOT
  local c
  for c in "${COMMANDS[@]}"; do
    printf '  %-12s %s\n' "$c" "${COMMAND_DESC[$c]}"
  done
  cat <<EOT

VÍ DỤ
  ${0##*/}                          # menu
  ${0##*/} backup                   # chạy sao lưu với tham số mặc định
  ${0##*/} -v healthcheck           # chạy healthcheck, log chi tiết
  ${0##*/} backup --help            # hướng dẫn riêng của backup
  ${0##*/} help restore             # tương tự

MÃ THOÁT
  0 thành công | 1 lỗi chung | 2 sai tham số | 3 thiếu công cụ
  4 thiếu quyền | 5 không thấy file/thư mục | 130 bị ngắt (Ctrl+C)
EOT
}

# ---------------------------------------------------------------------------
# F03 - Xử lý tham số
# getopts chỉ hiểu tùy chọn ngắn, nên đổi các tùy chọn dài đứng TRƯỚC <lệnh>
# sang dạng ngắn. Các tham số sau <lệnh> giữ nguyên để công cụ con tự xử lý.
# ---------------------------------------------------------------------------
ARGS=()
translate_long_opts() {
  local seen_cmd=0 expect_val=0 a
  for a in "$@"; do
    if ((seen_cmd || expect_val)); then
      ARGS+=("$a")
      expect_val=0
      continue
    fi
    case "$a" in
      --help) ARGS+=(-h) ;;
      --version) ARGS+=(-V) ;;
      --verbose) ARGS+=(-v) ;;
      --quiet) ARGS+=(-q) ;;
      --json) ARGS+=(-j) ;;
      --log-file=*) ARGS+=(-l "${a#*=}") ;;
      -l) ARGS+=("$a")
        expect_val=1 ;;
      -*) ARGS+=("$a") ;;
      *)
        seen_cmd=1
        ARGS+=("$a")
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Chạy một công cụ con
# ---------------------------------------------------------------------------
run_command() {
  local cmd=$1
  shift
  validate_choice "lệnh" "$cmd" "${COMMANDS[@]}"

  # Theo toolkit/README.md, các công cụ nằm trong toolkit/bin/<lệnh>.sh.
  # Dùng return (không dùng die) để menu không bị thoát khi một công cụ chưa sẵn sàng.
  local script="$TOOLKIT_DIR/bin/$cmd.sh"
  if [[ ! -f "$script" ]]; then
    log_error "Chưa có script cho lệnh '$cmd'" "path=$script"
    return "$EX_NOFILE"
  fi

  log_info "Chạy công cụ" "command=$cmd" "args=$*"
  local rc=0
  # Chạy bằng bash để không phụ thuộc vào quyền thực thi của file (git trên Windows hay làm mất)
  bash "$script" "$@" || rc=$?
  if ((rc == 0)); then
    log_info "Công cụ hoàn tất" "command=$cmd"
  else
    log_error "Công cụ kết thúc với lỗi" "command=$cmd" "exit_code=$rc"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# F01 - Menu tương tác
# ---------------------------------------------------------------------------
print_menu() {
  cat <<EOT

==========================================
  TASKOPS TOOLKIT ${TOOLKIT_VERSION}
==========================================
  1) Deploy        - ${COMMAND_DESC[deploy]}
  2) Backup        - ${COMMAND_DESC[backup]}
  3) Restore       - ${COMMAND_DESC[restore]}
  4) Healthcheck   - ${COMMAND_DESC[healthcheck]}
  5) Log rotation  - ${COMMAND_DESC[logrotate]}
  6) Xem log gần đây của toolkit
  0) Thoát
------------------------------------------
  File log: ${LOG_FILE}
EOT
}

# menu_run LỆNH : hỏi tham số bổ sung rồi chạy công cụ; lỗi không làm thoát menu
menu_run() {
  local cmd=$1 line
  local re='^[A-Za-z0-9_./=:,@ -]*$'
  local -a extra=()

  read -r -p "Tham số cho '$cmd' (Enter = mặc định, -h = xem trợ giúp): " line || line=""
  if [[ ! "$line" =~ $re ]]; then
    printf 'Tham số chứa ký tự không hợp lệ, đã bỏ qua.\n' >&2
    return 0
  fi
  read -r -a extra <<<"$line"

  if ! run_command "$cmd" "${extra[@]}"; then
    log_warn "Công cụ '$cmd' thất bại, quay lại menu"
  fi
  read -r -p "Nhấn Enter để quay lại menu..." _ || true
}

show_recent_logs() {
  if [[ -f "$LOG_FILE" ]]; then
    tail -n 20 -- "$LOG_FILE"
  else
    printf 'Chưa có file log: %s\n' "$LOG_FILE"
  fi
}

menu() {
  local choice
  while true; do
    print_menu
    if ! read -r -p "Chọn chức năng [0-6]: " choice; then
      printf '\n'
      log_info "Hết dữ liệu nhập, thoát menu"
      return 0
    fi
    case "$choice" in
      1) menu_run deploy ;;
      2) menu_run backup ;;
      3) menu_run restore ;;
      4) menu_run healthcheck ;;
      5) menu_run logrotate ;;
      6) show_recent_logs ;;
      0 | q | Q)
        log_info "Thoát menu"
        return 0
        ;;
      "") ;; # Enter: hiện lại menu
      *) printf 'Lựa chọn không hợp lệ: %q. Vui lòng nhập một số từ 0 đến 6.\n' "$choice" >&2 ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  translate_long_opts "$@"
  set -- "${ARGS[@]}"

  local opt
  OPTIND=1
  while getopts ':hVvqjl:' opt; do
    case "$opt" in
      h)
        usage
        exit "$EX_OK"
        ;;
      V)
        printf '%s %s\n' "$TOOLKIT_NAME" "$TOOLKIT_VERSION"
        exit "$EX_OK"
        ;;
      v) LOG_LEVEL=DEBUG ;;
      q) LOG_LEVEL=WARN ;;
      j) LOG_FORMAT=json ;;
      l) LOG_FILE=$OPTARG ;;
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

  log_init
  # Truyền cấu hình log xuống các công cụ con
  export LOG_LEVEL LOG_FORMAT LOG_FILE

  if (($# == 0)); then
    if [[ -t 0 ]]; then
      menu
      return 0
    fi
    usage >&2
    die "$EX_USAGE" "Không có lệnh nào và đầu vào không phải terminal"
  fi

  local cmd=$1
  shift
  if [[ "$cmd" == "help" ]]; then
    if (($# == 0)); then
      usage
      return 0
    fi
    run_command "$1" -h
    return 0
  fi
  run_command "$cmd" "$@" || exit "$?"
}

main "$@"
