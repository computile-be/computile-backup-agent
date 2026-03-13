#!/usr/bin/env bash
# ================================================================
# computile-backup — Create a backup user on the gateway
#
# Creates an isolated SFTP-only user for a client/VPS.
# Each user is chrooted to their own backup directory.
#
# Usage: sudo ./create_backup_user.sh <client-id> [--vps <vps-id>] [--key <pubkey-file>]
#
# Examples:
#   ./create_backup_user.sh client-a
#   ./create_backup_user.sh client-a --vps vps-prod-01
#   ./create_backup_user.sh client-a --key /tmp/id_ed25519.pub
# ================================================================
set -euo pipefail

readonly BACKUP_BASE="/srv/backups"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)"
    fi
}

usage() {
    echo "Usage: $0 <client-id> [--vps <vps-id>] [--key <pubkey-file>]"
    echo
    echo "Creates an SFTP-only backup user chrooted to their directory."
    echo
    echo "Options:"
    echo "  --vps <vps-id>       Create sub-directory for a specific VPS"
    echo "  --key <pubkey-file>  Path to SSH public key to authorize"
    exit 1
}

# ──────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────
CLIENT_ID=""
VPS_ID=""
PUBKEY_FILE=""

if [[ $# -lt 1 ]]; then
    usage
fi

CLIENT_ID="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps)
            VPS_ID="$2"; shift 2 ;;
        --key)
            PUBKEY_FILE="$2"; shift 2 ;;
        *)
            die "Unknown option: $1" ;;
    esac
done

# ──────────────────────────────────────────────
# Validate
# ──────────────────────────────────────────────
check_root

# Sanitize client ID (allow alphanumeric, dash, underscore)
if [[ ! "$CLIENT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Invalid client ID: '$CLIENT_ID' — use only alphanumeric, dash, underscore"
fi

USERNAME="backup-${CLIENT_ID}"

# ──────────────────────────────────────────────
# Create system user
# ──────────────────────────────────────────────
if id "$USERNAME" &>/dev/null; then
    info "User $USERNAME already exists"
else
    info "Creating system user: $USERNAME"
    useradd \
        --system \
        --shell /usr/sbin/nologin \
        --home-dir "${BACKUP_BASE}/${USERNAME}" \
        --no-create-home \
        --groups backupusers \
        "$USERNAME"
    info "User created: $USERNAME"
fi

# ──────────────────────────────────────────────
# Setup chroot directory structure
# ──────────────────────────────────────────────
# For ChrootDirectory to work with SFTP:
#   - The chroot directory must be owned by root
#   - The user writes into a subdirectory they own
#
CHROOT_DIR="${BACKUP_BASE}/${USERNAME}"
DATA_DIR="${CHROOT_DIR}/data"

info "Setting up directory structure..."

# Chroot root — must be owned by root
mkdir -p "$CHROOT_DIR"
chown root:root "$CHROOT_DIR"
chmod 755 "$CHROOT_DIR"

# Data directory — owned by the backup user
mkdir -p "$DATA_DIR"
chown "$USERNAME:backupusers" "$DATA_DIR"
chmod 750 "$DATA_DIR"

# Create VPS subdirectory if specified
if [[ -n "$VPS_ID" ]]; then
    vps_dir="${DATA_DIR}/${VPS_ID}"
    mkdir -p "$vps_dir"
    chown "$USERNAME:backupusers" "$vps_dir"
    chmod 750 "$vps_dir"
    info "Created VPS directory: $vps_dir"
fi

# ──────────────────────────────────────────────
# Setup SSH key
# ──────────────────────────────────────────────
SSH_DIR="${CHROOT_DIR}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$USERNAME:backupusers" "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$USERNAME:backupusers" "$AUTH_KEYS"

if [[ -n "$PUBKEY_FILE" ]]; then
    if [[ ! -f "$PUBKEY_FILE" ]]; then
        die "Public key file not found: $PUBKEY_FILE"
    fi

    # Avoid duplicates
    local key_content
    key_content=$(cat "$PUBKEY_FILE")
    if grep -qF "$key_content" "$AUTH_KEYS" 2>/dev/null; then
        info "SSH key already authorized"
    else
        cat "$PUBKEY_FILE" >> "$AUTH_KEYS"
        info "SSH key added to $AUTH_KEYS"
    fi
else
    warn "No SSH key provided — add one manually to $AUTH_KEYS"
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════"
echo "Backup user created: $USERNAME"
echo
echo "  Chroot directory: $CHROOT_DIR"
echo "  Data directory:   $DATA_DIR"
echo "  SSH keys:         $AUTH_KEYS"
echo
echo "From a VPS, configure restic repository as:"
if [[ -n "$VPS_ID" ]]; then
    echo "  sftp:${USERNAME}@<gateway-ip>:${DATA_DIR}/${VPS_ID}"
else
    echo "  sftp:${USERNAME}@<gateway-ip>:${DATA_DIR}/<vps-id>"
fi
echo
echo "To add an SSH key later:"
echo "  cat /path/to/key.pub >> $AUTH_KEYS"
echo "════════════════════════════════════════════════"
