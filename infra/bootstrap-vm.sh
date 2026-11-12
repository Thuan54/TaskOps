#!/usr/bin/env bash
# ==============================================================================
# Script Name   : bootstrap-vm.sh
# Description   : Automated Infrastructure Bootstrap for TaskOps Project (HCMUS)
# Group         : Group A - VM Infrastructure & Initial Setup
# Compatibility : Ubuntu 22.04 LTS Server (VMware Workstation / Player)
# Standard      : POSIX compliant Bash, set -euo pipefail, trap, shellcheck clean
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Global Constants & Defaults
# ------------------------------------------------------------------------------
SCRIPT_NAME="$(basename "${0}")"
readonly SCRIPT_NAME
readonly LOG_FILE="/var/log/taskops-bootstrap.log"

DEFAULT_MODE="vm1"
DEFAULT_DISK="/dev/sdb"
DEFAULT_MOUNT_POINT="/srv/backup"
DEFAULT_USERS=("van" "vinh" "thuan" "nhat" "thi")

TARGET_MODE=""
TARGET_DISK=""
TARGET_HOSTNAME=""
DRY_RUN=false
NON_INTERACTIVE=false

# ANSI Colors for Output
readonly C_RESET=$'\033[0m'
readonly C_RED=$'\033[0;31m'
readonly C_GREEN=$'\033[0;32m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_BLUE=$'\033[0;34m'
readonly C_CYAN=$'\033[0;36m'
readonly C_BOLD=$'\033[1m'

# ------------------------------------------------------------------------------
# Logging Functions
# ------------------------------------------------------------------------------
log_to_file() {
    local formatted_entry="${1}"
    if [ -w "${LOG_FILE}" ] || { [ ! -e "${LOG_FILE}" ] && [ -w "$(dirname "${LOG_FILE}")" ]; }; then
        printf "%s\n" "${formatted_entry}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

log_info() {
    local msg="${1}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%b[INFO]%b  [%s] %s\n" "${C_BLUE}" "${C_RESET}" "${timestamp}" "${msg}"
    log_to_file "[INFO]  [${timestamp}] ${msg}"
}

log_success() {
    local msg="${1}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%b[SUCCESS]%b [%s] %s\n" "${C_GREEN}" "${C_RESET}" "${timestamp}" "${msg}"
    log_to_file "[SUCCESS] [${timestamp}] ${msg}"
}

log_warn() {
    local msg="${1}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%b[WARN]%b  [%s] %s\n" "${C_YELLOW}" "${C_RESET}" "${timestamp}" "${msg}" >&2
    log_to_file "[WARN]  [${timestamp}] ${msg}"
}

log_error() {
    local msg="${1}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf "%b[ERROR]%b [%s] %s\n" "${C_RED}" "${C_RESET}" "${timestamp}" "${msg}" >&2
    log_to_file "[ERROR] [${timestamp}] ${msg}"
}

# ------------------------------------------------------------------------------
# Error Handling & Trap
# ------------------------------------------------------------------------------
cleanup() {
    local exit_code="${1}"
    local line_no="${2}"
    if [ "${exit_code}" -ne 0 ]; then
        log_error "Bootstrap failed unexpectedly at line ${line_no} with exit code ${exit_code}."
        log_error "Check detailed logs at: ${LOG_FILE}"
    fi
}

trap 'cleanup $? $LINENO' EXIT

# ------------------------------------------------------------------------------
# Help & Usage Display
# ------------------------------------------------------------------------------
show_help() {
    cat << EOF
${C_BOLD}NAME${C_RESET}
    ${SCRIPT_NAME} - Automated VM Bootstrap and Provisioning Tool

${C_BOLD}SYNOPSIS${C_RESET}
    sudo ./${SCRIPT_NAME} [OPTIONS]

${C_BOLD}DESCRIPTION${C_RESET}
    Initializes and bootstraps Ubuntu 22.04 LTS virtual machines for the HCMUS
    Linux & Application Final Project (TaskOps). It performs full setup for
    Task Group A:
      - Hostname configuration (todo-primary / todo-backup)
      - Non-root user creation (5 members) with sudo privileges
      - Secondary 10GB disk partitioning, formatting (ext4), and persistent fstab mounting
        at /srv/backup (and /srv/backup/incoming on VM2)
      - Core packages installation (Git, Curl, Rsync, Node.js 20.x LTS)
      - Infrastructure packages (PostgreSQL, UFW, Fail2ban, Auditd, Lynis)
      - PostgreSQL localhost binding configuration (ss verification)
      - Tailscale installation & SSH restriction via Tailscale interface

${C_BOLD}OPTIONS${C_RESET}
    -m, --mode <vm1|vm2>
        Specify machine role.
        vm1: Primary application server (Full stack: DB, Node.js, Services)
        vm2: Backup / Secondary node (Rsync target: /srv/backup/incoming)
        Default: ${DEFAULT_MODE}

    -d, --disk <device_path>
        Path to secondary raw 10GB disk.
        Default: ${DEFAULT_DISK}

    -n, --hostname <hostname>
        Explicit hostname to assign. Defaults to 'todo-primary' or 'todo-backup'.

    -y, --non-interactive
        Run automatically without prompting for confirmation.

    --dry-run
        Simulate actions without applying changes to the system.

    -h, --help
        Display this comprehensive manual and exit.

${C_BOLD}EXAMPLES${C_RESET}
    sudo ./${SCRIPT_NAME} --mode vm1 --disk /dev/sdb
    sudo ./${SCRIPT_NAME} --mode vm2 --disk /dev/sdb -y
    sudo ./${SCRIPT_NAME} --help

EOF
}

# ------------------------------------------------------------------------------
# Privilege & Environment Checks
# ------------------------------------------------------------------------------
check_prerequisites() {
    log_info "Verifying execution environment and privileges..."

    if [ "${DRY_RUN}" = false ] && [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be executed with root privileges. Use 'sudo ./${SCRIPT_NAME}'"
        exit 1
    fi

    if [ ! -f /etc/os-release ]; then
        log_error "Cannot detect operating system release file (/etc/os-release)."
        exit 1
    fi

    # Check Ubuntu 22.04
    # shellcheck source=/dev/null
    . /etc/os-release
    if [ "${ID:-}" != "ubuntu" ]; then
        log_warn "Current OS is '${ID:-unknown}'. Expected 'ubuntu'. Proceeding with caution..."
    fi

    if [ "${DRY_RUN}" = false ]; then
        touch "${LOG_FILE}" || true
        chmod 600 "${LOG_FILE}" || true
    fi
    log_success "Privilege verification passed. Log: ${LOG_FILE}"
}

# ------------------------------------------------------------------------------
# Hostname Configuration
# ------------------------------------------------------------------------------
configure_hostname() {
    local target_host="${1}"
    log_info "Configuring system hostname to '${target_host}'..."

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] hostnamectl set-hostname ${target_host}"
        return 0
    fi

    local current_host
    current_host="$(hostname)"
    if [ "${current_host}" = "${target_host}" ]; then
        log_info "Hostname is already set to '${target_host}'. Skipping."
        return 0
    fi

    hostnamectl set-hostname "${target_host}"

    # Update /etc/hosts idempotently
    if ! grep -q "127.0.1.1\s\+${target_host}" /etc/hosts; then
        sed -i "s/^127.0.1.1.*/127.0.1.1\t${target_host}/" /etc/hosts || echo -e "127.0.1.1\t${target_host}" >> /etc/hosts
    fi

    log_success "Hostname successfully configured to '${target_host}'."
}

# ------------------------------------------------------------------------------
# 5 Team Accounts Setup (Task A04)
# ------------------------------------------------------------------------------
create_team_accounts() {
    log_info "Setting up 5 team accounts on the system (Task A04)..."

    for username in "${DEFAULT_USERS[@]}"; do
        if id "${username}" &>/dev/null; then
            log_info "User '${username}' already exists. Ensuring membership in sudo group."
            if [ "${DRY_RUN}" = false ]; then
                usermod -aG sudo "${username}"
            fi
        else
            log_info "Creating user '${username}' with home directory and /bin/bash shell..."
            if [ "${DRY_RUN}" = false ]; then
                useradd -m -s /bin/bash "${username}"
                usermod -aG sudo "${username}"

                # Set default temporary password
                echo "${username}:TaskOps@2026" | chpasswd

                # Prepare .ssh directory
                local user_ssh="/home/${username}/.ssh"
                mkdir -p "${user_ssh}"
                chmod 700 "${user_ssh}"
                touch "${user_ssh}/authorized_keys"
                chmod 600 "${user_ssh}/authorized_keys"
                chown -R "${username}:${username}" "/home/${username}/.ssh"
            else
                log_info "[DRY-RUN] useradd -m -s /bin/bash ${username}"
            fi
            log_success "User '${username}' created successfully."
        fi
    done
}

# ------------------------------------------------------------------------------
# Secondary 10GB Disk Partitioning & Persistent Mounting (Task A05)
# Target: /srv/backup (and /srv/backup/incoming on VM2)
# ------------------------------------------------------------------------------
setup_secondary_storage() {
    local raw_disk="${1}"
    local mount_dir="${DEFAULT_MOUNT_POINT}"
    log_info "Configuring dedicated 10GB storage disk '${raw_disk}' at '${mount_dir}' (Task A05)..."

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] Partitioning, formatting, and mounting ${raw_disk} to ${mount_dir}"
        return 0
    fi

    if [ ! -b "${raw_disk}" ]; then
        log_warn "Block device '${raw_disk}' not found. Please ensure 10GB disk is added in VMware settings."
        log_warn "Skipping disk partitioning for now. You can re-run with: sudo ./${SCRIPT_NAME} --disk <path>"
        return 0
    fi

    # Determine partition name (e.g. /dev/sdb1 or /dev/nvme0n1p1)
    local part_device
    if [[ "${raw_disk}" =~ [0-9]$ ]]; then
        part_device="${raw_disk}p1"
    else
        part_device="${raw_disk}1"
    fi

    # Check if already partitioned
    if ! lsblk -n -o NAME "${part_device}" &>/dev/null; then
        log_info "Creating GPT partition table and partition on ${raw_disk}..."
        parted -s "${raw_disk}" mklabel gpt
        parted -s "${raw_disk}" mkpart primary ext4 1MiB 100%
        # Refresh partition table in kernel
        udevadm settle || sleep 2
    else
        log_info "Partition ${part_device} already exists."
    fi

    # Format partition if not already ext4
    local current_fs
    current_fs="$(lsblk -no FSTYPE "${part_device}" 2>/dev/null || true)"
    if [ "${current_fs}" != "ext4" ]; then
        log_info "Formatting ${part_device} with ext4 filesystem..."
        mkfs.ext4 -F -L "TASKBACKUP" "${part_device}"
    else
        log_info "Filesystem on ${part_device} is already ext4. Skipping format."
    fi

    # Create mount point
    mkdir -p "${mount_dir}"

    # Get UUID
    local disk_uuid
    disk_uuid="$(blkid -s UUID -o value "${part_device}")"
    if [ -z "${disk_uuid}" ]; then
        log_error "Failed to retrieve UUID for ${part_device}."
        exit 1
    fi
    log_info "Retrieved UUID: ${disk_uuid}"

    # Persistent fstab configuration
    local fstab_entry="UUID=${disk_uuid} ${mount_dir} ext4 defaults,nofail 0 2"
    if ! grep -q "${disk_uuid}" /etc/fstab; then
        log_info "Adding persistent mount entry to /etc/fstab..."
        cp /etc/fstab "/etc/fstab.backup.$(date +%Y%m%d%H%M%S)"
        echo "${fstab_entry}" >> /etc/fstab
    else
        log_info "Entry for UUID ${disk_uuid} already exists in /etc/fstab."
    fi

    # Mount disk
    if ! mountpoint -q "${mount_dir}"; then
        log_info "Mounting ${part_device} to ${mount_dir}..."
        mount -a
    fi

    # Specific directory setup based on role
    if [ "${TARGET_MODE}" = "vm2" ]; then
        log_info "Setting up VM2 rsync incoming target: ${mount_dir}/incoming..."
        mkdir -p "${mount_dir}/incoming"
        chmod 775 "${mount_dir}/incoming"
    fi

    if mountpoint -q "${mount_dir}"; then
        log_success "Storage successfully mounted at ${mount_dir}."
        df -h "${mount_dir}"
    else
        log_error "Mount verification failed for ${mount_dir}."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Core Packages & Toolchain Installation (Task A06)
# ------------------------------------------------------------------------------
install_core_packages() {
    log_info "Updating apt index and installing core packages (Git, Curl, Rsync) (Task A06)..."

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] apt-get update && apt-get install -y git curl rsync build-essential"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        git \
        curl \
        rsync \
        ca-certificates \
        gnupg \
        build-essential \
        tar \
        gzip \
        jq \
        net-tools \
        parted \
        iputils-ping

    # Install Node.js 20.x LTS via NodeSource
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js 20.x LTS via NodeSource repository..."
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
        apt-get update -y
        apt-get install -y nodejs
    else
        log_info "Node.js is already installed ($(node -v))."
    fi

    log_success "Core toolchain installed: Git ($(git --version)), Curl, Rsync, Node.js ($(node -v)), NPM ($(npm -v))."
}

# ------------------------------------------------------------------------------
# Infrastructure & Security Packages (Task A07)
# ------------------------------------------------------------------------------
install_infra_packages() {
    log_info "Installing infrastructure & security stack: PostgreSQL, UFW, Fail2ban, Auditd, Lynis (Task A07)..."

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] apt-get install -y postgresql postgresql-contrib ufw fail2ban auditd audispd-plugins lynis"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y \
        postgresql \
        postgresql-contrib \
        ufw \
        fail2ban \
        auditd \
        audispd-plugins \
        lynis

    # Enable core system services
    systemctl enable postgresql
    systemctl start postgresql
    systemctl enable fail2ban
    systemctl start fail2ban
    systemctl enable auditd
    systemctl start auditd

    # Prepare project environment directory for secrets (Task H01 preparation)
    mkdir -p /etc/taskops
    chmod 750 /etc/taskops

    log_success "PostgreSQL, UFW, Fail2ban, Auditd, and Lynis successfully installed and enabled."
}

# ------------------------------------------------------------------------------
# PostgreSQL Localhost Hardening (Task A10)
# ------------------------------------------------------------------------------
configure_postgresql_localhost() {
    log_info "Hardening PostgreSQL to strictly listen on localhost (127.0.0.1) (Task A10)..."

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] Configure postgresql.conf listen_addresses = 'localhost'"
        return 0
    fi

    # Locate postgresql.conf dynamically
    local pg_conf
    pg_conf="$(find /etc/postgresql/ -name postgresql.conf 2>/dev/null | sort -V | tail -n 1 || true)"

    if [ -z "${pg_conf}" ] || [ ! -f "${pg_conf}" ]; then
        log_error "postgresql.conf not found. Ensure postgresql package is installed."
        exit 1
    fi

    log_info "Found PostgreSQL config at: ${pg_conf}"

    # Ensure listen_addresses = 'localhost'
    if grep -q "^#*listen_addresses" "${pg_conf}"; then
        sed -i "s/^#*listen_addresses\s*=.*/listen_addresses = 'localhost'/" "${pg_conf}"
    else
        echo "listen_addresses = 'localhost'" >> "${pg_conf}"
    fi

    # Restart PostgreSQL service
    systemctl restart postgresql

    # Verify using ss
    log_info "Verifying PostgreSQL port binding via 'ss'..."
    local pg_socket
    pg_socket="$(ss -tulpn | grep 5432 || true)"
    log_info "Active 5432 binding: ${pg_socket}"

    if echo "${pg_socket}" | grep -q "127.0.0.1:5432"; then
        log_success "PostgreSQL is confirmed strictly listening on 127.0.0.1:5432."
    else
        log_warn "Socket output does not explicitly show 127.0.0.1:5432. Please inspect ${pg_conf}."
    fi
}

# ------------------------------------------------------------------------------
# Tailscale Setup & SSH Restriction (Tasks A01, A02, A03)
# ------------------------------------------------------------------------------
setup_tailscale_and_ssh_hardening() {
    log_info "Setting up Tailscale repository and network client (Task A01, A02, A03)..."

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] Install Tailscale and configure UFW rule for tailscale0"
        return 0
    fi

    if ! command -v tailscale &>/dev/null; then
        log_info "Adding Tailscale official apt repository..."
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
        apt-get update -y
        apt-get install -y tailscale
        systemctl enable --now tailscaled
        log_success "Tailscale installed successfully."
    else
        log_info "Tailscale is already installed ($(tailscale version | head -n 1))."
    fi

    # Check Tailscale status and trigger authentication automatically
    local ts_status
    ts_status="$(tailscale status 2>&1 || true)"
    if echo "${ts_status}" | grep -qE "Logged out|NeedsLogin"; then
        log_warn "Tailscale is not authenticated yet. Initiating connection..."
        log_info "Please open the URL below in your browser to authenticate this VM:"
        tailscale up --operator="${SUDO_USER:-root}" || true
    elif echo "${ts_status}" | grep -q "100\."; then
        log_success "Tailscale is already connected! Active IP: $(tailscale ip -4 2>/dev/null || echo 'OK')"
    else
        log_info "Starting Tailscale connection..."
        tailscale up --operator="${SUDO_USER:-root}" || true
    fi

    log_info "Hardening UFW for SSH restriction through Tailscale (Task A03)..."
    # Basic UFW initialization
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH strictly via Tailscale interface tailscale0
    ufw allow in on tailscale0 to any port 22 proto tcp comment 'Allow SSH strictly via Tailscale VPN'

    # Allow Web traffic for Nginx (ports 80 & 443) on VM1
    ufw allow 80/tcp comment 'Allow HTTP for Nginx'
    ufw allow 443/tcp comment 'Allow HTTPS for Nginx'

    # Enable UFW
    ufw --force enable
    log_success "UFW configured: Inbound denied by default; SSH restricted strictly to tailscale0 interface."
}

# ------------------------------------------------------------------------------
# SSH Keypair Setup for Inter-VM Communication (Task A08)
# ------------------------------------------------------------------------------
setup_inter_vm_ssh_key() {
    log_info "Setting up SSH keypair for automated operations (Task A08)..."

    local current_user="${SUDO_USER:-root}"
    local user_home
    user_home="$(eval echo "~${current_user}")"
    local key_file="${user_home}/.ssh/id_ed25519_taskops"

    if [ "${DRY_RUN}" = true ]; then
        log_info "[DRY-RUN] Generate ed25519 keypair at ${key_file}"
        return 0
    fi

    mkdir -p "${user_home}/.ssh"
    chmod 700 "${user_home}/.ssh"

    if [ ! -f "${key_file}" ]; then
        log_info "Generating Ed25519 keypair: ${key_file}..."
        ssh-keygen -t ed25519 -N "" -f "${key_file}" -C "taskops-intervm-key"
        chown -R "${current_user}:${current_user}" "${user_home}/.ssh"
        log_success "SSH keypair generated: ${key_file}.pub"
    else
        log_info "SSH keypair already exists at ${key_file}."
    fi

    cat << EOF

${C_CYAN}----------------------------------------------------------------------${C_RESET}
${C_BOLD}[Action Required for Task A08]${C_RESET}
Public Key for VM-to-VM synchronization:
${C_GREEN}$(cat "${key_file}.pub" 2>/dev/null || true)${C_RESET}

To authorize VM1 to access VM2 without password, run on VM1:
    ${C_YELLOW}ssh-copy-id -i ${key_file}.pub <user>@todo-backup${C_RESET}
${C_CYAN}----------------------------------------------------------------------${C_RESET}
EOF
}

# ------------------------------------------------------------------------------
# Interactive Confirmation Prompt
# ------------------------------------------------------------------------------
confirm_execution() {
    if [ "${NON_INTERACTIVE}" = true ] || [ "${DRY_RUN}" = true ]; then
        return 0
    fi

    cat << EOF
${C_BOLD}======================================================================${C_RESET}
${C_CYAN} TaskOps VM Infrastructure Bootstrap (HCMUS OS Lab) ${C_RESET}
${C_BOLD}======================================================================${C_RESET}
Target Role      : ${C_YELLOW}${TARGET_MODE}${C_RESET}
Target Hostname  : ${C_YELLOW}${TARGET_HOSTNAME}${C_RESET}
Target Disk      : ${C_YELLOW}${TARGET_DISK}${C_RESET}
Mount Point      : ${C_YELLOW}${DEFAULT_MOUNT_POINT}${C_RESET}
Team Accounts    : ${C_YELLOW}${DEFAULT_USERS[*]}${C_RESET}
Log Output       : ${C_YELLOW}${LOG_FILE}${C_RESET}
${C_BOLD}======================================================================${C_RESET}
EOF

    read -r -p "Do you wish to proceed with this configuration? [y/N]: " choice
    case "${choice}" in
        [yY][eE][sS]|[yY])
            log_info "User confirmed execution. Starting bootstrap pipeline..."
            ;;
        *)
            log_warn "Execution aborted by user."
            exit 0
            ;;
    esac
}

# ------------------------------------------------------------------------------
# CLI Option Parsing (getopts)
# ------------------------------------------------------------------------------
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "${1}" in
            -m|--mode)
                TARGET_MODE="${2:-}"
                shift 2
                ;;
            -d|--disk)
                TARGET_DISK="${2:-}"
                shift 2
                ;;
            -n|--hostname)
                TARGET_HOSTNAME="${2:-}"
                shift 2
                ;;
            -y|--non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: ${1}"
                show_help
                exit 1
                ;;
        esac
    done

    # Default values assignment if not provided
    if [ -z "${TARGET_MODE}" ]; then
        TARGET_MODE="${DEFAULT_MODE}"
    fi

    if [ "${TARGET_MODE}" != "vm1" ] && [ "${TARGET_MODE}" != "vm2" ]; then
        log_error "Invalid mode '${TARGET_MODE}'. Allowed values: 'vm1' or 'vm2'."
        exit 1
    fi

    if [ -z "${TARGET_DISK}" ]; then
        TARGET_DISK="${DEFAULT_DISK}"
    fi

    if [ -z "${TARGET_HOSTNAME}" ]; then
        if [ "${TARGET_MODE}" = "vm1" ]; then
            TARGET_HOSTNAME="todo-primary"
        else
            TARGET_HOSTNAME="todo-backup"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Main Pipeline
# ------------------------------------------------------------------------------
main() {
    parse_arguments "${@}"
    check_prerequisites
    confirm_execution

    log_info "=== Starting TaskOps Bootstrap Pipeline [Mode: ${TARGET_MODE}] ==="

    configure_hostname "${TARGET_HOSTNAME}"
    create_team_accounts
    setup_secondary_storage "${TARGET_DISK}"
    install_core_packages
    install_infra_packages

    if [ "${TARGET_MODE}" = "vm1" ]; then
        configure_postgresql_localhost
    fi

    setup_tailscale_and_ssh_hardening
    setup_inter_vm_ssh_key

    log_success "=== TaskOps Infrastructure Bootstrap Completed Successfully! ==="
    log_info "Review full execution log at: ${LOG_FILE}"
}

main "${@}"

