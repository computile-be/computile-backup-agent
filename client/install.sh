#!/usr/bin/env bash
# ================================================================
# computile-backup-agent — Installer
#
# Installs the backup agent on a VPS.
# Must be run as root.
#
# Usage: sudo ./install.sh
# ================================================================
set -euo pipefail

readonly INSTALL_BIN="/usr/local/bin"
readonly INSTALL_LIB="/usr/local/lib/computile-backup"
readonly CONFIG_DIR="/etc/computile-backup"
readonly BACKUP_DIR="/var/backups/computile"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly RESTIC_VERSION="0.17.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ──────────────────────────────────────────────
# Install restic (official binary)
# ──────────────────────────────────────────────
install_restic() {
    if command -v restic &>/dev/null; then
        local current_version
        current_version=$(restic version 2>/dev/null | awk '{print $2}')
        info "Restic already installed: v${current_version}"
        return 0
    fi

    info "Installing restic v${RESTIC_VERSION}..."

    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    local url="https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${arch}.bz2"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tmp_bz2="${tmp_dir}/restic.bz2"
    trap "rm -rf $tmp_dir" RETURN

    if ! wget -q -O "$tmp_bz2" "$url"; then
        die "Failed to download restic from $url"
    fi

    bunzip2 -f "$tmp_bz2"

    install -m 0755 "${tmp_dir}/restic" "${INSTALL_BIN}/restic"
    info "Restic installed: $(restic version)"
}

# ──────────────────────────────────────────────
# Install msmtp
# ──────────────────────────────────────────────
install_msmtp() {
    if command -v msmtp &>/dev/null; then
        info "msmtp already installed"
        return 0
    fi

    info "Installing msmtp..."
    apt-get update -qq
    apt-get install -y -qq msmtp msmtp-mta ca-certificates > /dev/null
    info "msmtp installed"
}

# ──────────────────────────────────────────────
# Install agent files
# ──────────────────────────────────────────────
install_agent() {
    info "Installing backup agent..."

    # Libraries
    mkdir -p "$INSTALL_LIB"
    install -m 0644 "${SCRIPT_DIR}/lib/common.sh"   "$INSTALL_LIB/"
    install -m 0644 "${SCRIPT_DIR}/lib/docker.sh"    "$INSTALL_LIB/"
    install -m 0644 "${SCRIPT_DIR}/lib/database.sh"  "$INSTALL_LIB/"
    install -m 0644 "${SCRIPT_DIR}/lib/notify.sh"    "$INSTALL_LIB/"
    install -m 0644 "${SCRIPT_DIR}/lib/restic.sh"    "$INSTALL_LIB/"

    # Main script
    install -m 0755 "${SCRIPT_DIR}/backup-agent.sh" "${INSTALL_BIN}/computile-backup"

    info "Agent installed to ${INSTALL_BIN}/computile-backup"
}

# ──────────────────────────────────────────────
# Setup configuration directory
# ──────────────────────────────────────────────
setup_config() {
    info "Setting up configuration directory..."

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    # Copy example config if no config exists
    if [[ ! -f "${CONFIG_DIR}/backup-agent.conf" ]]; then
        install -m 0600 "${SCRIPT_DIR}/backup-agent.conf.example" "${CONFIG_DIR}/backup-agent.conf"
        info "Example config copied to ${CONFIG_DIR}/backup-agent.conf — EDIT THIS FILE"
    else
        info "Config file already exists, not overwriting"
    fi

    # Copy example excludes if not present
    if [[ ! -f "${CONFIG_DIR}/excludes.txt" ]]; then
        install -m 0644 "${SCRIPT_DIR}/backup-agent.exclude.example" "${CONFIG_DIR}/excludes.txt"
        info "Exclusion file copied to ${CONFIG_DIR}/excludes.txt"
    fi

    # Create placeholder for restic password
    if [[ ! -f "${CONFIG_DIR}/restic-password" ]]; then
        head -c 32 /dev/urandom | base64 | tr -d '\n' > "${CONFIG_DIR}/restic-password"
        chmod 600 "${CONFIG_DIR}/restic-password"
        info "Generated random restic password in ${CONFIG_DIR}/restic-password"
        warn "SAVE THIS PASSWORD SECURELY — it is required to restore backups!"
    fi

    # Create placeholder for SMTP password
    if [[ ! -f "${CONFIG_DIR}/smtp-password" ]]; then
        touch "${CONFIG_DIR}/smtp-password"
        chmod 600 "${CONFIG_DIR}/smtp-password"
        info "Created ${CONFIG_DIR}/smtp-password — add your SMTP password to this file"
    fi
}

# ──────────────────────────────────────────────
# Setup backup directories
# ──────────────────────────────────────────────
setup_dirs() {
    info "Creating backup directories..."
    mkdir -p "${BACKUP_DIR}/db/mysql" "${BACKUP_DIR}/db/postgres" "${BACKUP_DIR}/db/redis" "${BACKUP_DIR}/tmp"
    chmod 700 "$BACKUP_DIR"
}

# ──────────────────────────────────────────────
# Install systemd units
# ──────────────────────────────────────────────
install_systemd() {
    info "Installing systemd units..."

    install -m 0644 "${SCRIPT_DIR}/systemd/computile-backup.service" "$SYSTEMD_DIR/"
    install -m 0644 "${SCRIPT_DIR}/systemd/computile-backup.timer"   "$SYSTEMD_DIR/"

    systemctl daemon-reload
    info "Systemd units installed"
    info "Enable with: systemctl enable --now computile-backup.timer"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    echo "╔══════════════════════════════════════════════╗"
    echo "║   computile-backup-agent — Installer         ║"
    echo "╚══════════════════════════════════════════════╝"
    echo

    check_root

    install_restic
    install_msmtp
    install_agent
    setup_config
    setup_dirs
    install_systemd

    echo
    echo "════════════════════════════════════════════════"
    echo "Installation complete!"
    echo
    echo "Next steps:"
    echo "  1. Edit ${CONFIG_DIR}/backup-agent.conf"
    echo "  2. Set your SMTP password in ${CONFIG_DIR}/smtp-password"
    echo "  3. Configure SSH key for the backup gateway"
    echo "  4. Test: sudo computile-backup --dry-run --verbose"
    echo "  5. Initialize repo: sudo computile-backup --init"
    echo "  6. Enable timer: sudo systemctl enable --now computile-backup.timer"
    echo "════════════════════════════════════════════════"
}

main "$@"
