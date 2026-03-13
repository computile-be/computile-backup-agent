#!/usr/bin/env bash
# ================================================================
# computile-backup — Gateway setup script
#
# Sets up a Linux VM as a backup gateway:
#   - Installs required packages
#   - Configures SMB mount to Synology
#   - Creates backup storage structure
#   - Hardens SSH
#   - Installs fail2ban
#
# Must be run as root on the gateway VM.
# Tested on: Ubuntu 24.04, Debian 12/13
#
# Usage: sudo ./setup_gateway.sh
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly BACKUP_BASE="/srv/backups"
readonly SMB_CREDENTIALS="/root/.smb-credentials"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; }
die()   { error "$@"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

prompt_value() {
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        read -rp "${prompt} [${default}]: " value
        echo "${value:-$default}"
    else
        read -rp "${prompt}: " value
        echo "$value"
    fi
}

# ──────────────────────────────────────────────
# Install packages
# ──────────────────────────────────────────────
install_packages() {
    info "Updating package lists..."
    apt-get update -qq

    info "Installing required packages..."
    apt-get install -y -qq \
        cifs-utils \
        openssh-server \
        fail2ban \
        rsync \
        tree \
        > /dev/null

    info "Packages installed"
}

# ──────────────────────────────────────────────
# Configure SMB mount
# ──────────────────────────────────────────────
setup_smb_mount() {
    info "Setting up SMB mount to Synology..."

    echo
    echo "Enter your Synology SMB share details:"
    local smb_server
    smb_server=$(prompt_value "  Synology IP or hostname" "192.168.1.100")
    local smb_share
    smb_share=$(prompt_value "  Share name" "backups")
    local smb_user
    smb_user=$(prompt_value "  SMB username" "backup-svc")
    local smb_password
    read -rsp "  SMB password: " smb_password
    echo

    # Create credentials file
    cat > "$SMB_CREDENTIALS" <<EOF
username=${smb_user}
password=${smb_password}
EOF
    chmod 600 "$SMB_CREDENTIALS"
    info "SMB credentials saved to $SMB_CREDENTIALS"

    # Create mount point
    mkdir -p "$BACKUP_BASE"

    # Add fstab entry
    local fstab_entry="//${smb_server}/${smb_share}  ${BACKUP_BASE}  cifs  credentials=${SMB_CREDENTIALS},uid=0,gid=0,dir_mode=0755,file_mode=0644,iocharset=utf8,nofail,_netdev  0  0"

    if grep -qF "$BACKUP_BASE" /etc/fstab 2>/dev/null; then
        warn "An entry for $BACKUP_BASE already exists in /etc/fstab — skipping"
    else
        echo "$fstab_entry" >> /etc/fstab
        info "Added fstab entry for SMB mount"
    fi

    # Try mounting
    if mount "$BACKUP_BASE" 2>/dev/null; then
        info "SMB share mounted successfully at $BACKUP_BASE"
    else
        warn "Could not mount SMB share — verify credentials and network connectivity"
        warn "You can mount manually with: mount $BACKUP_BASE"
    fi
}

# ──────────────────────────────────────────────
# Harden SSH
# ──────────────────────────────────────────────
setup_ssh() {
    info "Configuring SSH..."

    local sshd_snippet="${SCRIPT_DIR}/templates/sshd_config_snippet"
    local sshd_target="/etc/ssh/sshd_config.d/computile-backup.conf"

    if [[ -f "$sshd_snippet" ]]; then
        cp "$sshd_snippet" "$sshd_target"
        info "SSH configuration installed to $sshd_target"
    else
        warn "SSH config template not found, creating default"
        cat > "$sshd_target" <<'EOF'
# computile-backup — SSH hardening for backup gateway
# Restrict backup users to SFTP only

Match Group backupusers
    ChrootDirectory /srv/backups/%u
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    AllowAgentForwarding no
    PasswordAuthentication no
EOF
    fi

    # Create backup users group
    if ! getent group backupusers &>/dev/null; then
        groupadd backupusers
        info "Created group: backupusers"
    fi

    # Restart SSH
    systemctl restart sshd
    info "SSH restarted with new configuration"
}

# ──────────────────────────────────────────────
# Setup fail2ban
# ──────────────────────────────────────────────
setup_fail2ban() {
    info "Configuring fail2ban..."

    local jail_template="${SCRIPT_DIR}/templates/fail2ban_jail.local"
    local jail_target="/etc/fail2ban/jail.local"

    if [[ -f "$jail_template" ]]; then
        cp "$jail_template" "$jail_target"
    else
        cat > "$jail_target" <<'EOF'
# computile-backup — fail2ban configuration
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime  = 3600
EOF
    fi

    systemctl enable --now fail2ban
    info "fail2ban configured and running"
}

# ──────────────────────────────────────────────
# Create directory structure
# ──────────────────────────────────────────────
setup_directories() {
    info "Creating backup directory structure..."
    mkdir -p "$BACKUP_BASE"
    chmod 755 "$BACKUP_BASE"
    info "Base backup directory: $BACKUP_BASE"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    echo "╔══════════════════════════════════════════════╗"
    echo "║   computile-backup — Gateway Setup           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo

    check_root

    install_packages
    setup_directories
    setup_smb_mount
    setup_ssh
    setup_fail2ban

    echo
    echo "════════════════════════════════════════════════"
    echo "Gateway setup complete!"
    echo
    echo "Next steps:"
    echo "  1. Create backup users:  ./create_backup_user.sh <client-id>"
    echo "  2. Add SSH public keys for each VPS"
    echo "  3. Verify SMB mount:     df -h $BACKUP_BASE"
    echo "  4. Test SFTP access from a VPS"
    echo "════════════════════════════════════════════════"
}

main "$@"
