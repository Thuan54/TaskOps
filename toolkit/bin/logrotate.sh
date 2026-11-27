#!/usr/bin/env bash
# Rotate and compress TaskOps toolkit logs using the system logrotate state.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
TOOLKIT_DIR="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
LIB_DIR="$TOOLKIT_DIR/lib"

# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

require_root
require_cmd logrotate

LOGROTATE_CONF="${LOGROTATE_CONF:-/etc/logrotate.d/taskops}"
if [[ ! -r "$LOGROTATE_CONF" ]]; then
  LOGROTATE_CONF="$TOOLKIT_DIR/conf/taskops-logrotate.conf"
fi
require_file "$LOGROTATE_CONF"

log_info "Bắt đầu xoay vòng log TaskOps" "config=$LOGROTATE_CONF"
logrotate --verbose "$LOGROTATE_CONF"
log_info "Xoay vòng log TaskOps hoàn tất"
