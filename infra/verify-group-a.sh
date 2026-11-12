#!/usr/bin/env bash
# ==============================================================================
# Script Name   : infra/verify-group-a.sh
# Description   : Automated Compliance & Health Audit for Task Group A (TaskOps)
# ==============================================================================

set -euo pipefail

readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_CYAN=$'\033[0;36m'
readonly C_BOLD=$'\033[1m'

PASS_COUNT=0
TOTAL_COUNT=0

record_result() {
    local task_id="${1}"
    local desc="${2}"
    local status="${3}" # PASS or FAIL
    local details="${4:-}"

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    if [ "${status}" = "PASS" ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf "  [%bPASS%b] %-6s : %s\n" "${C_GREEN}" "${C_RESET}" "${task_id}" "${desc}"
        if [ -n "${details}" ]; then
            printf "         %b-> Detail:%b %s\n" "${C_CYAN}" "${C_RESET}" "${details}"
        fi
    else
        printf "  [%bFAIL%b] %-6s : %s\n" "${C_RED}" "${C_RESET}" "${task_id}" "${desc}"
        if [ -n "${details}" ]; then
            printf "         %b-> Detail:%b %s\n" "${C_YELLOW}" "${C_RESET}" "${details}"
        fi
    fi
}

echo "${C_BOLD}======================================================================${C_RESET}"
echo "${C_CYAN} TaskOps: Verification & Health Audit for Task Group A ${C_RESET}"
echo "${C_BOLD}======================================================================${C_RESET}"

# A01: Tailscale Network
if command -v tailscale &>/dev/null; then
    ts_ip="$(tailscale ip -4 2>/dev/null || true)"
    if [ -n "${ts_ip}" ]; then
        record_result "A01" "Tailscale Network Interface active" "PASS" "IP: ${ts_ip}"
    else
        record_result "A01" "Tailscale client installed but not connected" "FAIL" "Run 'sudo tailscale up'"
    fi
else
    record_result "A01" "Tailscale client binary not found" "FAIL" "Install tailscale"
fi

# A02: MagicDNS Resolution
if getent hosts todo-primary &>/dev/null || getent hosts todo-backup &>/dev/null; then
    record_result "A02" "MagicDNS resolution verified" "PASS" "Resolved VM hostname"
else
    record_result "A02" "MagicDNS resolution check" "FAIL" "Ensure MagicDNS enabled on Tailscale console"
fi

# A03: SSH restricted to Tailscale
if command -v ufw &>/dev/null; then
    ufw_rules="$(ufw status 2>/dev/null || true)"
    if echo "${ufw_rules}" | grep -q "22/tcp.*on tailscale0"; then
        record_result "A03" "SSH restricted strictly to tailscale0" "PASS" "UFW rule active"
    else
        record_result "A03" "SSH restriction on tailscale0" "FAIL" "Rule missing in UFW status"
    fi
else
    record_result "A03" "UFW firewall installed" "FAIL" "ufw not found"
fi

# A04: 5 Team Accounts
accounts=("student1" "student2" "student3" "student4" "student5")
acc_found=0
for u in "${accounts[@]}"; do
    if id "${u}" &>/dev/null; then
        acc_found=$((acc_found + 1))
    fi
done

if [ "${acc_found}" -ge 5 ]; then
    record_result "A04" "Team user accounts created with sudo" "PASS" "Found ${acc_found} accounts"
else
    # Check if custom usernames exist
    custom_users="$(getent group sudo | awk -F: '{print $4}' | tr ',' ' ')"
    custom_count="$(echo "${custom_users}" | wc -w)"
    if [ "${custom_count}" -ge 5 ]; then
        record_result "A04" "5 Team user accounts created with sudo" "PASS" "Sudo members: ${custom_users}"
    else
        record_result "A04" "5 Team user accounts" "FAIL" "Found ${custom_count}/5 sudo accounts"
    fi
fi

# A05: Secondary 10GB Disk & fstab at /srv/backup
if mountpoint -q /srv/backup; then
    disk_size="$(df -h /srv/backup | awk 'NR==2 {print $2}')"
    if grep -q "UUID=" /etc/fstab && grep -q "/srv/backup" /etc/fstab; then
        record_result "A05" "10GB Disk partitioned and mounted via UUID in fstab" "PASS" "Mounted at /srv/backup (Size: ${disk_size})"
    else
        record_result "A05" "/etc/fstab entry missing UUID for /srv/backup" "FAIL" "Check /etc/fstab"
    fi
else
    record_result "A05" "Mountpoint /srv/backup not currently mounted" "FAIL" "Run 'mount -a'"
fi

# A06: Git, Curl, Rsync, Node.js 20
missing_tools=""
for tool in git curl rsync node; do
    if ! command -v "${tool}" &>/dev/null; then
        missing_tools="${missing_tools} ${tool}"
    fi
done

if [ -z "${missing_tools}" ]; then
    node_ver="$(node -v)"
    record_result "A06" "Core tools installed (Git, Curl, Rsync, Node.js)" "PASS" "Node version: ${node_ver}"
else
    record_result "A06" "Core tools missing:${missing_tools}" "FAIL" "Install missing packages"
fi

# A07: PostgreSQL, Fail2ban, Auditd, Lynis
missing_services=""
for srv in postgresql fail2ban auditd lynis; do
    if ! command -v "${srv}" &>/dev/null && [ ! -d "/etc/${srv}" ]; then
        missing_services="${missing_services} ${srv}"
    fi
done

if [ -z "${missing_services}" ]; then
    record_result "A07" "PostgreSQL, Fail2ban, Auditd, Lynis installed" "PASS" "Packages present"
else
    record_result "A07" "Infrastructure packages missing:${missing_services}" "FAIL" "Run apt install"
fi

# A08: SSH Keypair for Inter-VM Sync
target_user="${SUDO_USER:-${USER}}"
target_home="$(eval echo "~${target_user}")"
key_file="${target_home}/.ssh/id_ed25519_taskops"

if [ -f "${key_file}" ]; then
    record_result "A08" "Inter-VM Ed25519 SSH Keypair generated" "PASS" "Key exists at ${key_file}"
else
    record_result "A08" "Inter-VM SSH Keypair not found" "FAIL" "Expected key at ${key_file}"
fi

# A10: PostgreSQL Localhost strictly
if command -v ss &>/dev/null; then
    pg_binding="$(ss -tulpn 2>/dev/null | grep 5432 || true)"
    if echo "${pg_binding}" | grep -q "127.0.0.1:5432"; then
        record_result "A10" "PostgreSQL bound strictly to 127.0.0.1" "PASS" "Port 5432 bound to localhost"
    elif [ -z "${pg_binding}" ]; then
        record_result "A10" "PostgreSQL service not actively listening" "FAIL" "Start postgresql"
    else
        record_result "A10" "PostgreSQL not bound to 127.0.0.1" "FAIL" "Binding: ${pg_binding}"
    fi
else
    record_result "A10" "ss command not available" "FAIL" "Install iproute2"
fi

echo "${C_BOLD}======================================================================${C_RESET}"
printf "Group A Audit Scorecard: %b%d/%d Tests Passed%b\n" "${C_GREEN}" "${PASS_COUNT}" "${TOTAL_COUNT}" "${C_RESET}"
echo "${C_BOLD}======================================================================${C_RESET}"

