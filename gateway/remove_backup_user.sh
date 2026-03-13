#!/usr/bin/env bash
# ================================================================
# computile-backup — Remove a backup user from the gateway
#
# Removes the system user and optionally deletes their backup data.
#
# Usage: sudo ./remove_backup_user.sh <client-id> [--delete-data]
#
# Examples:
#   ./remove_backup_user.sh client-a              # Remove user, keep data
#   ./remove_backup_user.sh client-a --delete-data # Remove user AND data
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
    echo "Usage: $0 <client-id> [--delete-data]"
    echo
    echo "Removes the SFTP backup user for a client."
    echo
    echo "Options:"
    echo "  --delete-data  Also delete the client's backup data (IRREVERSIBLE)"
    exit 1
}

# ──────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────
CLIENT_ID=""
DELETE_DATA=false

if [[ $# -lt 1 ]]; then
    usage
fi

CLIENT_ID="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete-data)
            DELETE_DATA=true; shift ;;
        *)
            die "Unknown option: $1" ;;
    esac
done

# ──────────────────────────────────────────────
# Validate
# ──────────────────────────────────────────────
check_root

if [[ ! "$CLIENT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Invalid client ID: '$CLIENT_ID'"
fi

USERNAME="backup-${CLIENT_ID}"
CHROOT_DIR="${BACKUP_BASE}/${USERNAME}"

if ! id "$USERNAME" &>/dev/null; then
    die "User $USERNAME does not exist"
fi

# ──────────────────────────────────────────────
# Confirm
# ──────────────────────────────────────────────
echo "════════════════════════════════════════════════"
echo "About to remove backup user: $USERNAME"
echo
echo "  User:      $USERNAME"
echo "  Directory: $CHROOT_DIR"
if $DELETE_DATA; then
    echo
    echo "  ⚠  --delete-data: backup data will be PERMANENTLY DELETED"
    data_size=$(du -sh "$CHROOT_DIR" 2>/dev/null | cut -f1) || data_size="unknown"
    echo "  Data size: $data_size"
fi
echo "════════════════════════════════════════════════"
echo
read -rp "Type 'yes' to confirm: " confirm
if [[ "$confirm" != "yes" ]]; then
    die "Aborted"
fi

# ──────────────────────────────────────────────
# Remove user
# ──────────────────────────────────────────────
info "Removing system user: $USERNAME"
userdel "$USERNAME" 2>/dev/null || warn "userdel failed (user may have been partially removed)"

# ──────────────────────────────────────────────
# Handle data
# ──────────────────────────────────────────────
if $DELETE_DATA; then
    if [[ -d "$CHROOT_DIR" ]]; then
        info "Deleting backup data: $CHROOT_DIR"
        rm -rf "$CHROOT_DIR"
        info "Data deleted"
    fi
else
    if [[ -d "$CHROOT_DIR" ]]; then
        info "Backup data preserved at: $CHROOT_DIR"
        info "To delete later: rm -rf $CHROOT_DIR"
    fi
fi

echo
echo "════════════════════════════════════════════════"
echo "User $USERNAME removed."
if ! $DELETE_DATA && [[ -d "$CHROOT_DIR" ]]; then
    echo "Backup data is still at: $CHROOT_DIR"
fi
echo "════════════════════════════════════════════════"
