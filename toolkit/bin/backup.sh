#!/usr/bin/env bash
# backup.sh - Sao lưu PostgreSQL + nội dung web sang VM2
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" &>/dev/null && pwd)"
if [[ -f "$LIB_DIR/alert.sh" ]]; then
    source "$LIB_DIR/alert.sh"
fi
if ! declare -F send_alert >/dev/null; then
    send_alert() { :; }
fi
: "${DB_NAME:=taskops}"
: "${WEB_APP_DIR:=/var/www/taskops-app}"
: "${WEB_STATUS_DIR:=/var/www/taskops-status}"
: "${BACKUP_DIR:=/srv/backup}"
: "${REMOTE_BACKUP_HOST:=todo-backup}"
: "${REMOTE_BACKUP_DIR:=/srv/backup/incoming/}"
: "${REMOTE_BACKUP_USER:=ubuntu}"
: "${SSH_KEY:=/root/.ssh/id_ed25519_taskops}"
: "${SYNC_ENABLED:=1}"

log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" >&2; }
die() { log ERROR "$*"; exit 1; }

main() {
    log INFO "Bắt đầu backup..."
    local ts final
    ts=$(date +%F_%H%M%S)
    final="$BACKUP_DIR/taskops_backup_${ts}.tar"
    
    local WORK_DIR
    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.work.XXXXXX")
    
    sudo -u postgres pg_dump "$DB_NAME" | gzip > "$WORK_DIR/db.sql.gz"
    tar -czf "$WORK_DIR/web_app.tar.gz" -C "$(dirname "$WEB_APP_DIR")" "$(basename "$WEB_APP_DIR")"
    tar -czf "$WORK_DIR/web_status.tar.gz" -C "$(dirname "$WEB_STATUS_DIR")" "$(basename "$WEB_STATUS_DIR")"
    
    tar -cf "$WORK_DIR/final.tar" -C "$WORK_DIR" db.sql.gz web_app.tar.gz web_status.tar.gz
    chmod 600 "$WORK_DIR/final.tar"
    mv "$WORK_DIR/final.tar" "$final"
    
    log INFO "Sao lưu thành công: $final"
    send_alert INFO "Sao lưu thành công: $(basename "$final")"

    if [[ "${SYNC_ENABLED}" == "1" ]] && command -v rsync >/dev/null 2>&1; then
        log INFO "Bắt đầu đồng bộ bản sao lưu sang VM2 ($REMOTE_BACKUP_HOST)..."
        local destination="${REMOTE_BACKUP_USER}@${REMOTE_BACKUP_HOST}:${REMOTE_BACKUP_DIR}"
        local ssh_opts=(-o "BatchMode=yes" -o "ConnectTimeout=10" -o "StrictHostKeyChecking=accept-new")
        if [[ -n "${SSH_KEY}" && -f "${SSH_KEY}" ]]; then
            ssh_opts+=(-i "${SSH_KEY}")
        fi
        if rsync -az --partial -e "ssh ${ssh_opts[*]}" "$final" "$destination"; then
            log INFO "Đã đồng bộ thành công sang VM2: $destination"
            send_alert INFO "Đã đồng bộ bản sao lưu sang VM2 ($REMOTE_BACKUP_HOST): $(basename "$final")"
        else
            log WARN "Đồng bộ Rsync sang VM2 thất bại"
            send_alert WARN "Đồng bộ Rsync sang VM2 ($REMOTE_BACKUP_HOST) thất bại"
        fi
    fi
    echo "$final"
}

main "$@"
