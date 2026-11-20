#!/usr/bin/env bash
# ============================================================================
# install-timer.sh - Cài (hoặc gỡ) service + timer sao lưu của TaskOps
#
# Việc làm: kiểm tra unit bằng systemd-analyze verify, chép vào
# /etc/systemd/system, daemon-reload, bật todo-backup.timer.
# ============================================================================
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOLKIT_DIR="$(cd "$_here/.." && pwd)"
export TOOLKIT_DIR
# shellcheck source=/dev/null
source "$TOOLKIT_DIR/lib/common.sh"

# shellcheck disable=SC2034 # biến này được lib/log.sh sử dụng
LOG_COMPONENT="install-timer"
log_init

readonly UNIT_DIR="/etc/systemd/system"
readonly TIMER_UNIT="todo-backup.timer"
readonly UNITS=("todo-backup.service" "todo-backup.timer" "todo-alert@.service")
DRY_RUN=0

usage() {
  cat <<EOT
Sử dụng: ${0##*/} [-h] [-d THƯ_MỤC] [-n] [-u]

Cài service + timer sao lưu hằng ngày (02:00) của TaskOps.

  -h           Hiện hướng dẫn này
  -d THƯ_MỤC   Nơi toolkit được cài, các unit sẽ trỏ tới đây
               (mặc định /opt/taskops-toolkit)
  -n           Chạy thử: chỉ in việc sẽ làm, không thay đổi hệ thống
  -u           Gỡ cài đặt (tắt timer, xóa unit)

Cần quyền root (sudo), trừ khi dùng -n.
EOT
}

# run LỆNH...: ghi log rồi chạy; ở chế độ -n thì chỉ in ra
run() {
  if ((DRY_RUN)); then
    log_info "[chạy thử] $*"
    return 0
  fi
  log_debug "Chạy: $*"
  "$@"
}

main() {
  local install_dir="/opt/taskops-toolkit" uninstall=0 opt arg u tmp
  for arg in "$@"; do
    if [[ "$arg" == "--help" ]]; then
      usage
      exit "$EX_OK"
    fi
  done

  OPTIND=1
  while getopts ':hd:nu' opt; do
    case "$opt" in
      h)
        usage
        exit "$EX_OK"
        ;;
      d) install_dir=$OPTARG ;;
      n) DRY_RUN=1 ;;
      u) uninstall=1 ;;
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

  validate_path "thư mục cài (-d)" "$install_dir"
  if ((!DRY_RUN)); then
    require_root
    require_cmd systemctl systemd-analyze install sed
  fi

  # --- Gỡ cài đặt ---
  if ((uninstall)); then
    log_info "Gỡ timer và unit sao lưu"
    run systemctl disable --now "$TIMER_UNIT" || log_warn "Timer chưa được bật hoặc đã gỡ"
    for u in "${UNITS[@]}"; do
      run rm -f "$UNIT_DIR/$u"
    done
    run systemctl daemon-reload
    log_info "Đã gỡ xong"
    return 0
  fi

  # --- Cài đặt ---
  if [[ ! -d "$install_dir" ]]; then
    if ((DRY_RUN)); then
      log_warn "Chưa có thư mục $install_dir (các unit sẽ trỏ tới đó)"
    else
      die "$EX_NOFILE" "Chưa có $install_dir. Khi phát triển có thể tạo liên kết: sudo ln -s <repo>/toolkit $install_dir"
    fi
  fi

  # Tạo bản unit đã thay đường dẫn cài đặt vào thư mục tạm (tự dọn khi thoát)
  tmp=$(mktemp -d)
  register_cleanup "$tmp"
  for u in "${UNITS[@]}"; do
    require_file "$_here/$u"
    sed "s#/opt/taskops-toolkit#${install_dir}#g" "$_here/$u" >"$tmp/$u"
  done

  log_info "Kiểm tra cú pháp unit bằng systemd-analyze verify"
  if ! run systemd-analyze verify "$tmp"/*.service "$tmp"/*.timer; then
    log_warn "systemd-analyze verify báo vấn đề, hãy đọc thông báo phía trên"
  fi

  for u in "${UNITS[@]}"; do
    log_info "Cài unit" "unit=$u"
    run install -m 0644 "$tmp/$u" "$UNIT_DIR/$u"
  done

  run systemctl daemon-reload
  run systemctl enable --now "$TIMER_UNIT"
  run systemctl list-timers "$TIMER_UNIT" --no-pager
  log_info "Hoàn tất: timer sẽ chạy sao lưu lúc 02:00 hằng ngày"
}

main "$@"
