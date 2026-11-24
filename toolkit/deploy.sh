#!/usr/bin/env bash
# deploy.sh - Điểm gọi tương thích cho toolkit.sh dispatch
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
exec bash "$SCRIPT_DIR/bin/deploy.sh" "$@"
