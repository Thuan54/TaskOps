#!/usr/bin/env bash
# G01: Configure UFW on the personal TaskOps lab VM.
# Existing firewall rules are preserved.

set -euo pipefail
trap 'printf "[ERROR] Line %s: command failed\n" "$LINENO" >&2' ERR

usage() {
    cat <<'HELP'
Usage: sudo bash security/setup-ufw.sh
       bash security/setup-ufw.sh --help

Configure the personal lab firewall:
  - Deny incoming connections by default.
  - Allow outgoing connections.
  - Allow TCP ports 22 (SSH), 80 (HTTP), 443 (HTTPS).
  - Enable logging and UFW.

Existing rules are preserved.
Review SSH access restrictions before using on shared VMs.
HELP
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if (( $# > 0 )); then
    usage >&2
    exit 2
fi

if (( EUID != 0 )); then
    printf '[ERROR] Run this script with sudo.\n' >&2
    exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
    printf '[ERROR] UFW is not installed.\n' >&2
    exit 1
fi

printf '[INFO] Configuring default policies...\n'
ufw default deny incoming
ufw default allow outgoing

printf '[INFO] Allowing SSH, HTTP and HTTPS...\n'
ufw allow 22/tcp comment 'SSH - personal lab'
ufw allow 80/tcp comment 'TaskOps HTTP'
ufw allow 443/tcp comment 'TaskOps HTTPS'

printf '[INFO] Enabling firewall logging...\n'
ufw logging low

printf '[INFO] Enabling UFW...\n'
ufw enable

printf '[INFO] Current firewall status:\n'
ufw status verbose
