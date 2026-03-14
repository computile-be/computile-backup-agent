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
#   - Installs gateway scripts (manager, user management)
#
# Must be run as root on the gateway VM.
# Tested on: Ubuntu 24.04, Debian 12/13
#
# Usage:
#   sudo ./setup_gateway.sh              # First-time setup
#   sudo ./setup_gateway.sh --update     # Update scripts only
#   sudo ./setup_gateway.sh --rollback   # Revert to previous version
# ================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly BACKUP_BASE="/srv/backups"
readonly SMB_CREDENTIALS="/root/.smb-credentials"
readonly INSTALL_BIN="/usr/local/bin"
readonly INSTALL_LIB="/usr/local/lib/computile-gateway"

UPDATE_MODE=false
ROLLBACK_MODE=false
FORCE_MODE=false
SKIP_CRON=false

readonly CRON_FILE="/etc/cron.d/computile-backup-monitor"

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
# Version helpers
# ──────────────────────────────────────────────
get_new_version() {
    if [[ -f "${SCRIPT_DIR}/../VERSION" ]]; then
        head -1 "${SCRIPT_DIR}/../VERSION" | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

get_installed_version() {
    if [[ -f "${INSTALL_LIB}/VERSION" ]]; then
        head -1 "${INSTALL_LIB}/VERSION" | tr -d '[:space:]'
    else
        echo "unknown"
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
        whiptail \
        ncurses-bin \
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
    local fstab_entry="//${smb_server}/${smb_share}  ${BACKUP_BASE}  cifs  credentials=${SMB_CREDENTIALS},vers=3.0,noperm,nofail,_netdev  0  0"

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
# Install monitoring cron job
# ──────────────────────────────────────────────
install_monitor_cron() {
    if $SKIP_CRON; then
        info "Skipping cron installation (--no-cron)"
        return 0
    fi

    if [[ -f "$CRON_FILE" ]]; then
        info "Monitor cron already exists: $CRON_FILE (not overwritten)"
        return 0
    fi

    info "Installing monitoring cron job..."

    cat > "$CRON_FILE" <<'EOF'
# computile-backup gateway monitoring
# Runs every 15 minutes, sends alerts via healthcheck/webhook if configured
*/15 * * * * root /usr/local/bin/computile-gateway-manager --monitor 2>&1 | logger -t computile-gateway
EOF
    chmod 644 "$CRON_FILE"

    info "Monitor cron installed: $CRON_FILE"
    info "Configure GATEWAY_HEALTHCHECK_URL and/or GATEWAY_WEBHOOK_URL in /etc/computile-backup/gateway.conf to enable alerts"
}

# ──────────────────────────────────────────────
# Install gateway scripts
# ──────────────────────────────────────────────
install_gateway_scripts() {
    info "Installing gateway scripts..."

    mkdir -p "$INSTALL_LIB"

    # Gateway manager
    if [[ -f "${SCRIPT_DIR}/computile-gateway-manager.sh" ]]; then
        install -m 0755 "${SCRIPT_DIR}/computile-gateway-manager.sh" \
            "${INSTALL_BIN}/computile-gateway-manager"
        info "Gateway manager installed: ${INSTALL_BIN}/computile-gateway-manager"
    else
        warn "Gateway manager script not found"
    fi

    # User management scripts
    if [[ -f "${SCRIPT_DIR}/create_backup_user.sh" ]]; then
        install -m 0755 "${SCRIPT_DIR}/create_backup_user.sh" \
            "${INSTALL_BIN}/computile-create-backup-user"
        info "Create user script installed: ${INSTALL_BIN}/computile-create-backup-user"
    fi

    if [[ -f "${SCRIPT_DIR}/remove_backup_user.sh" ]]; then
        install -m 0755 "${SCRIPT_DIR}/remove_backup_user.sh" \
            "${INSTALL_BIN}/computile-remove-backup-user"
        info "Remove user script installed: ${INSTALL_BIN}/computile-remove-backup-user"
    fi

    # Restore test script
    if [[ -f "${SCRIPT_DIR}/restore-test.sh" ]]; then
        install -m 0755 "${SCRIPT_DIR}/restore-test.sh" \
            "${INSTALL_BIN}/computile-restore-test"
        info "Restore test script installed: ${INSTALL_BIN}/computile-restore-test"
    fi

    # Version file
    if [[ -f "${SCRIPT_DIR}/../VERSION" ]]; then
        install -m 0644 "${SCRIPT_DIR}/../VERSION" "${INSTALL_LIB}/VERSION"
    fi

    # Record source repo path for future updates
    echo "${SCRIPT_DIR}/.." > "${INSTALL_LIB}/.source-repo"

    # Gateway config (don't overwrite existing)
    local gw_config="/etc/computile-backup/gateway.conf"
    mkdir -p /etc/computile-backup
    if [[ ! -f "$gw_config" ]]; then
        if [[ -f "${SCRIPT_DIR}/gateway.conf.example" ]]; then
            install -m 0600 "${SCRIPT_DIR}/gateway.conf.example" "$gw_config"
            info "Gateway config installed: $gw_config (edit to enable monitoring)"
        fi
    else
        info "Gateway config already exists: $gw_config (not overwritten)"
    fi
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
# Backup current scripts for rollback
# ──────────────────────────────────────────────
backup_current_scripts() {
    local rollback_dir="${INSTALL_LIB}/.rollback"

    if [[ ! -d "$INSTALL_LIB" ]]; then
        return 0
    fi

    info "Backing up current scripts for rollback..."
    rm -rf "$rollback_dir"
    mkdir -p "$rollback_dir"

    # Back up VERSION
    [[ -f "${INSTALL_LIB}/VERSION" ]] && cp "${INSTALL_LIB}/VERSION" "$rollback_dir/"

    # Back up installed scripts
    for script in computile-gateway-manager computile-create-backup-user computile-remove-backup-user computile-restore-test; do
        [[ -f "${INSTALL_BIN}/${script}" ]] && cp "${INSTALL_BIN}/${script}" "$rollback_dir/"
    done

    info "Rollback backup saved to $rollback_dir"
}

# ──────────────────────────────────────────────
# Show changelog between two versions
# ──────────────────────────────────────────────
show_changelog() {
    local from_version="$1"
    local to_version="$2"
    local changelog="${SCRIPT_DIR}/../CHANGELOG.md"

    if [[ ! -f "$changelog" ]]; then
        return 0
    fi

    echo
    info "Changes since v${from_version}:"
    echo "────────────────────────────────────────────"

    local printing=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ \[.*\] ]]; then
            if $printing; then
                if [[ "$line" == *"[${from_version}]"* ]]; then
                    break
                fi
            fi
            printing=true
        fi
        if $printing; then
            echo "  $line"
        fi
    done < "$changelog"

    echo "────────────────────────────────────────────"
}

# ──────────────────────────────────────────────
# Update gateway (scripts only)
# ──────────────────────────────────────────────
update_gateway() {
    local installed_version
    installed_version=$(get_installed_version)
    local new_version
    new_version=$(get_new_version)

    echo "╔══════════════════════════════════════════════╗"
    echo "║   computile-backup — Gateway Update          ║"
    echo "╚══════════════════════════════════════════════╝"
    echo

    check_root

    # Pre-flight checks
    if [[ ! -f "${INSTALL_BIN}/computile-gateway-manager" ]]; then
        die "Gateway is not installed. Run setup_gateway.sh without --update for first-time setup."
    fi

    if [[ "$new_version" == "unknown" ]]; then
        die "Cannot determine new version. Is the VERSION file present in the repo?"
    fi

    if [[ "$installed_version" == "unknown" ]]; then
        info "Installed version: pre-release (no VERSION file)"
        info "Available version: v${new_version}"
    else
        info "Installed version: v${installed_version}"
        info "Available version: v${new_version}"

        if [[ "$installed_version" == "$new_version" ]] && ! $FORCE_MODE; then
            info "Already up to date (v${installed_version})"
            return 0
        fi
    fi

    # Back up current version
    backup_current_scripts

    # Update scripts
    install_gateway_scripts

    # Install cron if not already present
    install_monitor_cron

    # Verify
    if [[ -f "${INSTALL_LIB}/VERSION" ]]; then
        local verify_version
        verify_version=$(head -1 "${INSTALL_LIB}/VERSION" | tr -d '[:space:]')
        info "Verified: v${verify_version} installed"
    fi

    # Show changelog
    show_changelog "$installed_version" "$new_version"

    echo
    echo "════════════════════════════════════════════════"
    echo "Gateway update complete: v${installed_version} → v${new_version}"
    echo
    echo "Rollback if needed: sudo ./setup_gateway.sh --rollback"
    echo "════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────
# Rollback to previous version
# ──────────────────────────────────────────────
rollback_gateway() {
    local rollback_dir="${INSTALL_LIB}/.rollback"

    echo "╔══════════════════════════════════════════════╗"
    echo "║   computile-backup — Gateway Rollback        ║"
    echo "╚══════════════════════════════════════════════╝"
    echo

    check_root

    if [[ ! -d "$rollback_dir" ]]; then
        die "No rollback data found. Cannot rollback."
    fi

    local rollback_version="unknown"
    if [[ -f "$rollback_dir/VERSION" ]]; then
        rollback_version=$(head -1 "$rollback_dir/VERSION" | tr -d '[:space:]')
    fi

    local current_version
    current_version=$(get_installed_version)

    info "Current version:  v${current_version}"
    info "Rollback target:  v${rollback_version}"

    # Restore scripts
    for script in computile-gateway-manager computile-create-backup-user computile-remove-backup-user computile-restore-test; do
        if [[ -f "$rollback_dir/${script}" ]]; then
            install -m 0755 "$rollback_dir/${script}" "${INSTALL_BIN}/${script}"
        fi
    done

    # Restore VERSION
    [[ -f "$rollback_dir/VERSION" ]] && install -m 0644 "$rollback_dir/VERSION" "${INSTALL_LIB}/"

    # Remove rollback data (can only rollback once)
    rm -rf "$rollback_dir"

    local verify_version
    verify_version=$(get_installed_version)

    echo
    echo "════════════════════════════════════════════════"
    echo "Rollback complete: v${current_version} → v${verify_version}"
    echo "════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────
# Parse CLI arguments
# ──────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --update)
                UPDATE_MODE=true
                shift
                ;;
            --rollback)
                ROLLBACK_MODE=true
                shift
                ;;
            --force)
                FORCE_MODE=true
                shift
                ;;
            --no-cron)
                SKIP_CRON=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo
                echo "Options:"
                echo "  --update     Update gateway scripts (preserves config)"
                echo "  --rollback   Rollback to previous version"
                echo "  --force      Force update even if version matches"
                echo "  --no-cron    Skip monitoring cron job installation"
                echo "  --help, -h   Show this help"
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    parse_args "$@"

    # Route to the right mode
    if $ROLLBACK_MODE; then
        rollback_gateway
        return 0
    fi

    if $UPDATE_MODE; then
        update_gateway
        return 0
    fi

    # Fresh install
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
    install_gateway_scripts
    install_monitor_cron

    echo
    echo "════════════════════════════════════════════════"
    echo "Gateway setup complete! (v$(get_new_version))"
    echo
    echo "Next steps:"
    echo "  1. Create backup users:  computile-create-backup-user <client-id>"
    echo "  2. Add SSH public keys for each VPS"
    echo "  3. Verify SMB mount:     df -h $BACKUP_BASE"
    echo "  4. Test SFTP access from a VPS"
    echo "  5. Launch the gateway manager: computile-gateway-manager"
    echo
    echo "To update later: cd /opt/computile-backup-agent && git pull && sudo ./gateway/setup_gateway.sh --update"
    echo "════════════════════════════════════════════════"
}

main "$@"
