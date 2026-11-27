#!/usr/bin/env bash
# alert.sh - Điểm gọi tương thích cho systemd unit và các script khác
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
exec bash "$SCRIPT_DIR/lib/alert.sh" "$@"
