#!/usr/bin/env bash
# ================================================================
# computile-backup-agent — Installer
#
# Installs the backup agent on a VPS.
# Must be run as root.
#
# Usage: sudo ./install.sh [--non-interactive]
# ================================================================
set -euo pipefail

readonly INSTALL_BIN="/usr/local/bin"
readonly INSTALL_LIB="/usr/local/lib/computile-backup"
readonly CONFIG_DIR="/etc/computile-backup"
readonly BACKUP_DIR="/var/backups/computile"
readonly SYSTEMD_DIR="/etc/systemd/system"
readonly RESTIC_VERSION="0.17.3"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERACTIVE=true
UPDATE_MODE=false
ROLLBACK_MODE=false
FORCE_MODE=false

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

    if [[ "$INTERACTIVE" != true ]]; then
        echo "$default"
        return
    fi

    if [[ -n "$default" ]]; then
        read -rp "  ${prompt} [${default}]: " value
        echo "${value:-$default}"
    else
        read -rp "  ${prompt}: " value
        echo "$value"
    fi
}

prompt_secret() {
    local prompt="$1"
    local value

    if [[ "$INTERACTIVE" != true ]]; then
        echo ""
        return
    fi

    read -rsp "  ${prompt}: " value
    echo >&2  # newline after hidden input
    echo "$value"
}

prompt_yesno() {
    local prompt="$1"
    local default="${2:-yes}"

    if [[ "$INTERACTIVE" != true ]]; then
        echo "$default"
        return
    fi

    local value
    read -rp "  ${prompt} [${default}]: " value
    value="${value:-$default}"
    echo "$value"
}

prompt_choice() {
    local prompt="$1"
    local default="$2"
    shift 2
    local choices=("$@")

    if [[ "$INTERACTIVE" != true ]]; then
        echo "$default"
        return
    fi

    echo "  ${prompt}"
    local i=1
    for choice in "${choices[@]}"; do
        if [[ "$choice" == "$default" ]]; then
            echo "    ${i}) ${choice} (default)"
        else
            echo "    ${i}) ${choice}"
        fi
        ((i++))
    done

    local value
    read -rp "  Choice [${default}]: " value

    # Accept number or value
    if [[ "$value" =~ ^[0-9]+$ ]] && [[ "$value" -ge 1 ]] && [[ "$value" -le ${#choices[@]} ]]; then
        echo "${choices[$((value - 1))]}"
    elif [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
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
    trap 'rm -rf "${tmp_dir:?}"' RETURN

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

    # Version file
    if [[ -f "${SCRIPT_DIR}/../VERSION" ]]; then
        install -m 0644 "${SCRIPT_DIR}/../VERSION" "$INSTALL_LIB/VERSION"
    fi

    # Main script
    install -m 0755 "${SCRIPT_DIR}/backup-agent.sh" "${INSTALL_BIN}/computile-backup"

    # TUI manager
    install -m 0755 "${SCRIPT_DIR}/computile-manager.sh" "${INSTALL_BIN}/computile-manager"

    # Record source repo path for future updates
    echo "${SCRIPT_DIR}/.." > "${INSTALL_LIB}/.source-repo"

    info "Agent installed to ${INSTALL_BIN}/computile-backup"
    info "Manager installed to ${INSTALL_BIN}/computile-manager"
}

# ──────────────────────────────────────────────
# Interactive configuration
# ──────────────────────────────────────────────
configure_interactive() {
    info "Setting up configuration directory..."

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    # If config already exists, ask whether to reconfigure
    if [[ -f "${CONFIG_DIR}/backup-agent.conf" ]]; then
        if [[ "$INTERACTIVE" == true ]]; then
            local overwrite
            overwrite=$(prompt_yesno "Config file already exists. Reconfigure?" "no")
            if [[ "$overwrite" != "yes" ]]; then
                info "Keeping existing configuration"
                _setup_secrets ""
                return 0
            fi
        else
            info "Config file already exists, not overwriting"
            _setup_secrets ""
            return 0
        fi
    fi

    # Copy example excludes if not present
    if [[ ! -f "${CONFIG_DIR}/excludes.txt" ]]; then
        install -m 0644 "${SCRIPT_DIR}/backup-agent.exclude.example" "${CONFIG_DIR}/excludes.txt"
        info "Exclusion file copied to ${CONFIG_DIR}/excludes.txt"
    fi

    if [[ "$INTERACTIVE" != true ]]; then
        install -m 0600 "${SCRIPT_DIR}/backup-agent.conf.example" "${CONFIG_DIR}/backup-agent.conf"
        info "Example config copied to ${CONFIG_DIR}/backup-agent.conf — EDIT THIS FILE"
        _setup_secrets ""
        return 0
    fi

    # ── Interactive prompts ──
    echo
    echo "──── Identity ────"
    local client_id host_id environment role
    client_id=$(prompt_value "Client ID (e.g. client-name)" "")
    while [[ -z "$client_id" ]]; do
        warn "Client ID is required"
        client_id=$(prompt_value "Client ID" "")
    done
    host_id=$(prompt_value "Host ID (e.g. vps-prod-01)" "$(hostname -s)")
    environment=$(prompt_choice "Environment:" "prod" "prod" "staging" "dev")
    role=$(prompt_choice "Server role:" "coolify" "coolify" "forge" "hybrid" "docker" "bare")

    echo
    echo "──── Backup gateway ────"
    local gateway_host
    gateway_host=$(prompt_value "Gateway hostname (Tailscale or IP)" "backup-gateway")
    local restic_repo="sftp:backup-${client_id}@${gateway_host}:/srv/backups/backup-${client_id}/data/${host_id}"
    info "Restic repository: $restic_repo"

    echo
    echo "──── Paths to backup ────"
    local include_paths_str
    case "$role" in
        coolify)
            include_paths_str="/etc /home /root /opt /srv /data /data/coolify"
            ;;
        forge)
            include_paths_str="/etc /home /root /var/www"
            ;;
        hybrid)
            include_paths_str="/etc /home /root /var/www /data/coolify /opt /srv"
            ;;
        docker)
            include_paths_str="/etc /home /opt /srv"
            ;;
        *)
            include_paths_str="/etc /home /root /var/www /opt /srv"
            ;;
    esac
    include_paths_str=$(prompt_value "Include paths (space-separated)" "$include_paths_str")

    echo
    echo "──── Docker & databases ────"
    local docker_enabled="no"
    if command -v docker &>/dev/null; then
        docker_enabled=$(prompt_yesno "Docker detected. Enable DB auto-discovery?" "yes")
    else
        docker_enabled=$(prompt_yesno "Enable Docker integration?" "no")
    fi

    # Host-level databases (Forge, bare metal)
    local host_db_enabled="no"
    local host_mysql_user="" host_mysql_pass_file=""
    local host_postgres_user=""

    if [[ "$role" == "forge" ]] || [[ "$role" == "bare" ]]; then
        local host_db_default="yes"
    else
        local host_db_default="no"
    fi

    if command -v mysqldump &>/dev/null || command -v mariadb-dump &>/dev/null || \
       command -v pg_dump &>/dev/null; then
        host_db_enabled=$(prompt_yesno "Host-level databases detected. Enable host DB dumps?" "$host_db_default")
    elif [[ "$host_db_default" == "yes" ]]; then
        host_db_enabled=$(prompt_yesno "Enable host-level database dumps? (Forge installs MySQL/PostgreSQL on host)" "yes")
    fi

    if [[ "$host_db_enabled" == "yes" ]]; then
        if command -v mysqldump &>/dev/null || command -v mariadb-dump &>/dev/null; then
            host_mysql_user=$(prompt_value "Host MySQL user" "root")
            host_mysql_pass_file="${CONFIG_DIR}/mysql-password"
            local host_mysql_password
            host_mysql_password=$(prompt_secret "Host MySQL password (leave empty to set later)")
        fi
        if command -v pg_dump &>/dev/null; then
            host_postgres_user=$(prompt_value "Host PostgreSQL user" "postgres")
        fi
    fi

    echo
    echo "──── Email notifications ────"
    local email_enabled
    email_enabled=$(prompt_yesno "Enable email notifications?" "yes")

    local email_to="" email_from="" smtp_host="" smtp_port="" smtp_user="" smtp_password=""
    if [[ "$email_enabled" == "yes" ]]; then
        email_to=$(prompt_value "Alert recipient email" "alerts@computile.be")
        email_from=$(prompt_value "Sender email (FROM)" "backup-${client_id}@computile.email")
        smtp_host=$(prompt_value "SMTP host" "ssl0.ovh.net")
        smtp_port=$(prompt_value "SMTP port" "587")
        smtp_user=$(prompt_value "SMTP username" "$email_from")
        smtp_password=$(prompt_secret "SMTP password (leave empty to set later)")
    fi

    echo
    echo "──── Healthcheck ────"
    local healthcheck_url
    healthcheck_url=$(prompt_value "Healthcheck ping URL (leave empty to skip)" "")

    echo
    echo "──── Retention policy ────"
    local keep_daily keep_weekly keep_monthly keep_yearly
    keep_daily=$(prompt_value "Daily snapshots to keep" "7")
    keep_weekly=$(prompt_value "Weekly snapshots to keep" "4")
    keep_monthly=$(prompt_value "Monthly snapshots to keep" "6")
    keep_yearly=$(prompt_value "Yearly snapshots to keep" "2")

    # ── Generate config file (atomic: write to temp, then move) ──
    info "Generating configuration..."

    local tmp_conf
    tmp_conf=$(mktemp "${CONFIG_DIR}/backup-agent.conf.XXXXXX")

    # Build INCLUDE_PATHS array syntax
    local include_paths_array=""
    for path in $include_paths_str; do
        include_paths_array+="    ${path}"$'\n'
    done

    cat > "$tmp_conf" <<EOF
# ================================================================
# computile-backup-agent — Configuration file
# Generated by install.sh on $(date '+%Y-%m-%d %H:%M:%S')
# ================================================================

# ──────────────────────────────────────────────
# Identity
# ──────────────────────────────────────────────
CLIENT_ID="${client_id}"
HOST_ID="${host_id}"
ENVIRONMENT="${environment}"
ROLE="${role}"

# ──────────────────────────────────────────────
# Restic repository (via SFTP over Tailscale)
# ──────────────────────────────────────────────
RESTIC_REPOSITORY="${restic_repo}"
RESTIC_PASSWORD_FILE="${CONFIG_DIR}/restic-password"
# RESTIC_CACHE_DIR="/var/cache/restic"

# ──────────────────────────────────────────────
# Paths
# ──────────────────────────────────────────────
BACKUP_ROOT="${BACKUP_DIR}"
LOG_FILE="/var/log/computile-backup.log"

# Paths to include in backup
INCLUDE_PATHS=(
${include_paths_array})

# Exclusion file (one pattern per line)
EXCLUDE_FILE="${CONFIG_DIR}/excludes.txt"

# ──────────────────────────────────────────────
# Retention policy
# ──────────────────────────────────────────────
RETENTION_KEEP_DAILY=${keep_daily}
RETENTION_KEEP_WEEKLY=${keep_weekly}
RETENTION_KEEP_MONTHLY=${keep_monthly}
RETENTION_KEEP_YEARLY=${keep_yearly}

# ──────────────────────────────────────────────
# Docker & database discovery
# ──────────────────────────────────────────────
DOCKER_ENABLED="${docker_enabled}"
DOCKER_DB_AUTO_DISCOVERY="${docker_enabled}"

# Per-database type toggle
MYSQL_DUMP_ENABLED="yes"
POSTGRES_DUMP_ENABLED="yes"
REDIS_SNAPSHOT_ENABLED="no"

# Days to keep local dump files before cleanup
DUMP_CLEANUP_DAYS=3

# ──────────────────────────────────────────────
# Manual database entries (optional)
# ──────────────────────────────────────────────
# Format: "container_name|db_type|user|password|databases"
# MANUAL_DBS=(
#     "my-mariadb|mysql|root||app_db,other_db"
#     "my-postgres|postgres|postgres||"
# )

# ──────────────────────────────────────────────
# Host-level databases (Forge, bare metal)
# ──────────────────────────────────────────────
HOST_DB_ENABLED="${host_db_enabled}"
EOF

    if [[ "$host_db_enabled" == "yes" ]]; then
        if [[ -n "$host_mysql_user" ]]; then
            cat >> "$tmp_conf" <<EOF
HOST_MYSQL_USER="${host_mysql_user}"
HOST_MYSQL_PASS_FILE="${host_mysql_pass_file}"
# HOST_MYSQL_DATABASES=""
EOF
        fi
        if [[ -n "$host_postgres_user" ]]; then
            cat >> "$tmp_conf" <<EOF
HOST_POSTGRES_USER="${host_postgres_user}"
# HOST_POSTGRES_DATABASES=""
EOF
        fi
    fi

    cat >> "$tmp_conf" <<EOF

# ──────────────────────────────────────────────
# Email notifications (via msmtp)
# ──────────────────────────────────────────────
EMAIL_ENABLED="${email_enabled}"
EOF

    if [[ "$email_enabled" == "yes" ]]; then
        cat >> "$tmp_conf" <<EOF
EMAIL_TO="${email_to}"
EMAIL_FROM="${email_from}"
EMAIL_ON_SUCCESS="no"

# SMTP settings
SMTP_HOST="${smtp_host}"
SMTP_PORT="${smtp_port}"
SMTP_USER="${smtp_user}"
SMTP_PASS_FILE="${CONFIG_DIR}/smtp-password"
EOF
    else
        cat >> "$tmp_conf" <<EOF
# EMAIL_TO=""
# EMAIL_FROM=""
# EMAIL_ON_SUCCESS="no"
# SMTP_HOST=""
# SMTP_PORT="587"
# SMTP_USER=""
# SMTP_PASS_FILE="${CONFIG_DIR}/smtp-password"
EOF
    fi

    if [[ -n "$healthcheck_url" ]]; then
        cat >> "$tmp_conf" <<EOF

# ──────────────────────────────────────────────
# Healthcheck ping
# ──────────────────────────────────────────────
HEALTHCHECK_URL="${healthcheck_url}"
EOF
    fi

    cat >> "$tmp_conf" <<EOF

# ──────────────────────────────────────────────
# Verification
# ──────────────────────────────────────────────
VERIFY_AFTER_BACKUP="yes"
VERIFY_CHECK_DATA="no"

# ──────────────────────────────────────────────
# Misc
# ──────────────────────────────────────────────
VERBOSE="no"
DRY_RUN="no"
EOF

    # Atomic move: config is complete or not written at all
    chmod 600 "$tmp_conf"
    mv "$tmp_conf" "${CONFIG_DIR}/backup-agent.conf"
    info "Config written to ${CONFIG_DIR}/backup-agent.conf"

    # ── Setup secrets ──
    _setup_secrets "$smtp_password" "${host_mysql_password:-}"
}

_setup_secrets() {
    local smtp_password="${1:-}"
    local host_mysql_password="${2:-}"

    # Restic password
    if [[ ! -f "${CONFIG_DIR}/restic-password" ]]; then
        head -c 32 /dev/urandom | base64 | tr -d '\n' > "${CONFIG_DIR}/restic-password"
        chmod 600 "${CONFIG_DIR}/restic-password"
        info "Generated random restic password in ${CONFIG_DIR}/restic-password"
        warn "SAVE THIS PASSWORD SECURELY — it is required to restore backups!"
    fi

    # SMTP password
    if [[ ! -f "${CONFIG_DIR}/smtp-password" ]] || [[ -n "$smtp_password" ]]; then
        if [[ -n "$smtp_password" ]]; then
            echo -n "$smtp_password" > "${CONFIG_DIR}/smtp-password"
            info "SMTP password saved to ${CONFIG_DIR}/smtp-password"
        else
            touch "${CONFIG_DIR}/smtp-password"
            info "Created ${CONFIG_DIR}/smtp-password — add your SMTP password to this file"
        fi
        chmod 600 "${CONFIG_DIR}/smtp-password"
    fi

    # MySQL password (host-level)
    if [[ ! -f "${CONFIG_DIR}/mysql-password" ]] || [[ -n "$host_mysql_password" ]]; then
        if [[ -n "$host_mysql_password" ]]; then
            echo -n "$host_mysql_password" > "${CONFIG_DIR}/mysql-password"
            chmod 600 "${CONFIG_DIR}/mysql-password"
            info "MySQL password saved to ${CONFIG_DIR}/mysql-password"
        fi
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
# Install logrotate config
# ──────────────────────────────────────────────
install_logrotate() {
    if [[ -d /etc/logrotate.d ]]; then
        install -m 0644 "${SCRIPT_DIR}/logrotate/computile-backup" /etc/logrotate.d/computile-backup
        info "Logrotate config installed"
    else
        warn "logrotate not found, skipping log rotation config"
    fi
}

# ──────────────────────────────────────────────
# Setup SSH key for backup gateway
# ──────────────────────────────────────────────
setup_ssh_key() {
    local ssh_key="/root/.ssh/backup_ed25519"

    if [[ -f "$ssh_key" ]]; then
        info "SSH key already exists: $ssh_key"
        return 0
    fi

    if [[ "$INTERACTIVE" != true ]]; then
        info "Skipping SSH key generation in non-interactive mode"
        return 0
    fi

    local generate
    generate=$(prompt_yesno "Generate SSH key for backup gateway?" "yes")
    if [[ "$generate" != "yes" ]]; then
        return 0
    fi

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    ssh-keygen -t ed25519 -f "$ssh_key" -N "" -C "computile-backup@$(hostname -f)" >/dev/null 2>&1
    chmod 600 "$ssh_key"
    chmod 644 "${ssh_key}.pub"

    info "SSH key generated: $ssh_key"
    echo
    echo "──── Public key (add to gateway's authorized_keys) ────"
    cat "${ssh_key}.pub"
    echo "────────────────────────────────────────────────────────"
    echo

    # Offer to configure SSH host alias
    local gateway_host
    gateway_host=$(prompt_value "Gateway Tailscale IP or hostname (for SSH config)" "backup-gateway")

    # Read CLIENT_ID from generated config
    local ssh_user="backup-unknown"
    if [[ -f "${CONFIG_DIR}/backup-agent.conf" ]]; then
        local client_id_val
        client_id_val=$(grep '^CLIENT_ID=' "${CONFIG_DIR}/backup-agent.conf" | head -1 | cut -d'"' -f2)
        if [[ -n "$client_id_val" ]]; then
            ssh_user="backup-${client_id_val}"
        fi
    fi

    # Add SSH config block if not already present
    if ! grep -q "^Host backup-gateway" /root/.ssh/config 2>/dev/null; then
        cat >> /root/.ssh/config <<EOF

# Computile backup gateway
Host backup-gateway
    HostName ${gateway_host}
    User ${ssh_user}
    IdentityFile ${ssh_key}
    StrictHostKeyChecking accept-new
EOF
        chmod 600 /root/.ssh/config
        info "SSH config updated with backup-gateway alias"
    else
        info "SSH config already contains backup-gateway entry"
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
# Backup current scripts for rollback
# ──────────────────────────────────────────────
backup_current_scripts() {
    local rollback_dir="${INSTALL_LIB}/.rollback"

    if [[ ! -d "$INSTALL_LIB" ]]; then
        return 0  # Nothing to back up
    fi

    info "Backing up current scripts for rollback..."
    rm -rf "$rollback_dir"
    mkdir -p "$rollback_dir/lib"

    # Back up libraries
    for f in "$INSTALL_LIB"/*.sh; do
        [[ -f "$f" ]] && cp "$f" "$rollback_dir/lib/"
    done

    # Back up VERSION
    [[ -f "$INSTALL_LIB/VERSION" ]] && cp "$INSTALL_LIB/VERSION" "$rollback_dir/"

    # Back up main script and manager
    [[ -f "${INSTALL_BIN}/computile-backup" ]] && \
        cp "${INSTALL_BIN}/computile-backup" "$rollback_dir/"
    [[ -f "${INSTALL_BIN}/computile-manager" ]] && \
        cp "${INSTALL_BIN}/computile-manager" "$rollback_dir/"

    # Back up systemd units
    mkdir -p "$rollback_dir/systemd"
    for unit in computile-backup.service computile-backup.timer; do
        [[ -f "${SYSTEMD_DIR}/${unit}" ]] && cp "${SYSTEMD_DIR}/${unit}" "$rollback_dir/systemd/"
    done

    # Back up logrotate
    mkdir -p "$rollback_dir/logrotate"
    [[ -f /etc/logrotate.d/computile-backup ]] && \
        cp /etc/logrotate.d/computile-backup "$rollback_dir/logrotate/"

    info "Rollback backup saved to $rollback_dir"
}

# ──────────────────────────────────────────────
# Update agent (scripts only, no config)
# ──────────────────────────────────────────────
update_agent() {
    local installed_version
    installed_version=$(get_installed_version)
    local new_version
    new_version=$(get_new_version)

    echo "╔══════════════════════════════════════════════╗"
    echo "║   computile-backup-agent — Update             ║"
    echo "╚══════════════════════════════════════════════╝"
    echo

    check_root

    # Pre-flight checks
    if [[ ! -f "${INSTALL_BIN}/computile-backup" ]]; then
        die "Agent is not installed. Run install.sh without --update for first-time setup."
    fi

    if [[ ! -f "${CONFIG_DIR}/backup-agent.conf" ]]; then
        die "No config found at ${CONFIG_DIR}/backup-agent.conf. Run install.sh without --update."
    fi

    if [[ "$new_version" == "unknown" ]]; then
        die "Cannot determine new version. Is the VERSION file present in the repo?"
    fi

    if [[ "$installed_version" == "unknown" ]]; then
        info "Installed version: pre-release (no VERSION file)"
        info "Available version: ${new_version}"
    else
        info "Installed version: v${installed_version}"
        info "Available version: v${new_version}"

        if [[ "$installed_version" == "$new_version" ]] && ! $FORCE_MODE; then
            info "Already up to date (v${installed_version})"
            return 0
        fi
    fi

    # Check no backup is running
    if [[ -d "/var/run/computile-backup.lock" ]]; then
        local pid
        pid=$(cat /var/run/computile-backup.lock/pid 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "A backup is currently running (PID $pid). Wait for it to finish or stop it first."
        fi
    fi

    # Back up current version
    backup_current_scripts

    # Update scripts
    info "Updating agent scripts..."
    install_agent

    # Update systemd units (with diff)
    _update_systemd_units

    # Update config (detect new parameters)
    _update_config

    # Update logrotate
    install_logrotate

    # Update restic if needed
    install_restic

    # Verify
    local verify_version
    verify_version=$("${INSTALL_BIN}/computile-backup" --version 2>/dev/null | awk '{print $NF}')
    info "Verified: ${INSTALL_BIN}/computile-backup reports v${verify_version}"

    # Show changelog
    _show_changelog "$installed_version" "$new_version"

    echo
    echo "════════════════════════════════════════════════"
    echo "Update complete: v${installed_version} → v${new_version}"
    echo
    echo "Rollback if needed:  sudo ./install.sh --rollback"
    echo "Test backup:         sudo computile-backup --dry-run --verbose"
    echo "════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────
# Config migration: detect and add new sections
# ──────────────────────────────────────────────
_update_config() {
    local config_file="${CONFIG_DIR}/backup-agent.conf"
    local example_file="${SCRIPT_DIR}/backup-agent.conf.example"

    if [[ ! -f "$example_file" ]] || [[ ! -f "$config_file" ]]; then
        return 0
    fi

    # Collect all variable names present in the installed config
    local -a config_vars=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)= ]]; then
            config_vars+=("${BASH_REMATCH[1]}")
        elif [[ "$line" =~ ^[[:space:]]*#[[:space:]]*([A-Z_][A-Z0-9_]*)= ]]; then
            config_vars+=("${BASH_REMATCH[1]}")
        fi
    done < "$config_file"

    _var_in_config() {
        local var="$1"
        for cvar in "${config_vars[@]}"; do
            [[ "$var" == "$cvar" ]] && return 0
        done
        return 1
    }

    # Parse example config into sections
    # Format: delimiter line / title line / delimiter line / body lines
    # e.g.:  # ──────────────────────────────────────────────
    #        # Healthcheck ping (healthchecks.io, ...)
    #        # ──────────────────────────────────────────────
    #        content...

    local -a elines=()
    while IFS= read -r line; do
        elines+=("$line")
    done < "$example_file"
    local etotal=${#elines[@]}

    local -a section_titles=()
    local -a section_bodies=()

    local ei=0
    while [[ $ei -lt $etotal ]]; do
        if [[ "${elines[$ei]}" =~ ^#\ ─{3,} ]]; then
            local enext=$((ei + 1))
            local enext2=$((ei + 2))
            if [[ $enext2 -lt $etotal ]] && [[ "${elines[$enext2]}" =~ ^#\ ─{3,} ]]; then
                local stitle="${elines[$enext]}"
                local body_start=$((enext2 + 1))

                local sbody=""
                local ej=$body_start
                while [[ $ej -lt $etotal ]]; do
                    [[ "${elines[$ej]}" =~ ^#\ ─{3,} ]] && break
                    sbody+="${elines[$ej]}"$'\n'
                    ((ej++))
                done

                section_titles+=("$stitle")
                section_bodies+=("$sbody")
                ei=$ej
                continue
            fi
        fi
        ((ei++))
    done

    # For each section, check if it contains variables missing from the config
    local -a missing_sections_idx=()
    local -a all_missing_vars=()

    for i in "${!section_bodies[@]}"; do
        local body="${section_bodies[$i]}"
        local has_missing=false

        while IFS= read -r line; do
            local var=""
            if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)= ]]; then
                var="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^[[:space:]]*#[[:space:]]*([A-Z_][A-Z0-9_]*)= ]]; then
                var="${BASH_REMATCH[1]}"
            fi
            if [[ -n "$var" ]] && ! _var_in_config "$var"; then
                has_missing=true
                all_missing_vars+=("$var")
            fi
        done <<< "$body"

        if $has_missing; then
            missing_sections_idx+=("$i")
        fi
    done

    if [[ ${#missing_sections_idx[@]} -eq 0 ]]; then
        info "Config file is up to date — no new parameters"
        return 0
    fi

    info "New config parameters detected: ${all_missing_vars[*]}"

    # Build section blocks to add
    local -a section_blocks=()
    for i in "${missing_sections_idx[@]}"; do
        local title="${section_titles[$i]}"
        local body="${section_bodies[$i]}"

        local block=""
        block+="# ──────────────────────────────────────────────"$'\n'
        block+="${title}"$'\n'
        block+="# ──────────────────────────────────────────────"$'\n'
        block+="${body}"
        section_blocks+=("$block")
    done

    # Show what will be added
    echo
    echo "──── New config sections ────"
    for block in "${section_blocks[@]}"; do
        echo "$block"
    done
    echo "─────────────────────────────"
    echo

    if [[ "$INTERACTIVE" == true ]]; then
        local do_add
        do_add=$(prompt_yesno "Add these sections to your config?" "yes")
        if [[ "$do_add" != "yes" ]]; then
            warn "Skipped config update. You may need to add these sections manually."
            return 0
        fi

        # For active (uncommented) variables in new sections, prompt for values
        {
            echo ""
            echo "# ── Added by update to v$(get_new_version) on $(date '+%Y-%m-%d') ──"

            for i in "${missing_sections_idx[@]}"; do
                local title="${section_titles[$i]}"
                local body="${section_bodies[$i]}"

                echo ""
                echo "# ──────────────────────────────────────────────"
                echo "${title}"
                echo "# ──────────────────────────────────────────────"

                while IFS= read -r line; do
                    [[ -z "$line" ]] && continue
                    local var=""
                    local is_commented=false

                    if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)= ]]; then
                        var="${BASH_REMATCH[1]}"
                    elif [[ "$line" =~ ^[[:space:]]*#[[:space:]]*([A-Z_][A-Z0-9_]*)= ]]; then
                        var="${BASH_REMATCH[1]}"
                        is_commented=true
                    fi

                    if [[ -n "$var" ]] && ! _var_in_config "$var"; then
                        if $is_commented; then
                            # Optional param — keep commented
                            echo "$line"
                        else
                            # Active param — prompt for value
                            local default_val=""
                            if [[ "$line" =~ =[\"\']?([^\"\']*)[\"\']? ]]; then
                                default_val="${BASH_REMATCH[1]}"
                            fi
                            local user_val
                            user_val=$(prompt_value "${var}" "$default_val")
                            if [[ -n "$user_val" ]]; then
                                echo "${var}=\"${user_val}\""
                            else
                                echo "# ${var}=\"${default_val}\""
                            fi
                        fi
                    elif [[ -n "$var" ]]; then
                        # Variable already exists in config — skip
                        :
                    else
                        # Comment-only line (description) — include for context
                        echo "$line"
                    fi
                done <<< "$body"
            done
        } >> "$config_file"
        info "Config updated with new sections"

    else
        # Non-interactive: append entire sections with active vars commented out
        {
            echo ""
            echo "# ── Added by update to v$(get_new_version) on $(date '+%Y-%m-%d') ──"
            for block in "${section_blocks[@]}"; do
                echo "$block" | sed 's/^[[:space:]]*\([A-Z_][A-Z0-9_]*=\)/# \1/'
            done
        } >> "$config_file"
        info "New sections appended (active params commented out). Edit ${config_file} to activate."
    fi
}

# ──────────────────────────────────────────────
# Update systemd units with diff
# ──────────────────────────────────────────────
_update_systemd_units() {
    local changed=false

    for unit in computile-backup.service computile-backup.timer; do
        local src="${SCRIPT_DIR}/systemd/${unit}"
        local dst="${SYSTEMD_DIR}/${unit}"

        if [[ ! -f "$src" ]]; then continue; fi

        if [[ -f "$dst" ]] && diff -q "$src" "$dst" &>/dev/null; then
            continue  # No changes
        fi

        if [[ -f "$dst" ]]; then
            info "Systemd unit changed: ${unit}"
            diff --color=auto -u "$dst" "$src" || true
            echo
        fi

        install -m 0644 "$src" "$dst"
        changed=true
    done

    if $changed; then
        systemctl daemon-reload
        info "Systemd units updated and daemon reloaded"
    fi
}

# ──────────────────────────────────────────────
# Show changelog between two versions
# ──────────────────────────────────────────────
_show_changelog() {
    local from_version="$1"
    local to_version="$2"
    local changelog="${SCRIPT_DIR}/../CHANGELOG.md"

    if [[ ! -f "$changelog" ]]; then
        return 0
    fi

    echo
    info "Changes since v${from_version}:"
    echo "────────────────────────────────────────────"

    # Extract entries between from_version and to_version
    # Print everything from the to_version header until the from_version header
    local printing=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^##\ \[.*\] ]]; then
            if $printing; then
                # Hit the next version header — stop if it's older than from_version
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
# Rollback to previous version
# ──────────────────────────────────────────────
rollback_agent() {
    local rollback_dir="${INSTALL_LIB}/.rollback"

    echo "╔══════════════════════════════════════════════╗"
    echo "║   computile-backup-agent — Rollback           ║"
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

    # Restore libraries
    if [[ -d "$rollback_dir/lib" ]]; then
        for f in "$rollback_dir/lib"/*.sh; do
            [[ -f "$f" ]] && install -m 0644 "$f" "$INSTALL_LIB/"
        done
    fi

    # Restore VERSION
    [[ -f "$rollback_dir/VERSION" ]] && install -m 0644 "$rollback_dir/VERSION" "$INSTALL_LIB/"

    # Restore main script and manager
    [[ -f "$rollback_dir/computile-backup" ]] && \
        install -m 0755 "$rollback_dir/computile-backup" "${INSTALL_BIN}/computile-backup"
    [[ -f "$rollback_dir/computile-manager" ]] && \
        install -m 0755 "$rollback_dir/computile-manager" "${INSTALL_BIN}/computile-manager"

    # Restore systemd units
    local systemd_changed=false
    if [[ -d "$rollback_dir/systemd" ]]; then
        for f in "$rollback_dir/systemd"/*; do
            [[ -f "$f" ]] && install -m 0644 "$f" "$SYSTEMD_DIR/" && systemd_changed=true
        done
    fi

    if $systemd_changed; then
        systemctl daemon-reload
    fi

    # Restore logrotate
    [[ -f "$rollback_dir/logrotate/computile-backup" ]] && \
        install -m 0644 "$rollback_dir/logrotate/computile-backup" /etc/logrotate.d/computile-backup

    # Remove rollback data (can only rollback once)
    rm -rf "$rollback_dir"

    local verify_version
    verify_version=$("${INSTALL_BIN}/computile-backup" --version 2>/dev/null | awk '{print $NF}')

    echo
    echo "════════════════════════════════════════════════"
    echo "Rollback complete: v${current_version} → v${verify_version}"
    echo
    echo "Test backup: sudo computile-backup --dry-run --verbose"
    echo "════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────
# Parse CLI arguments
# ──────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                INTERACTIVE=false
                shift
                ;;
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
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo
                echo "Options:"
                echo "  --non-interactive   Skip interactive prompts, use defaults"
                echo "  --update            Update agent scripts (preserves config)"
                echo "  --rollback          Rollback to previous version"
                echo "  --force             Force update even if version matches"
                echo "  --help, -h          Show this help"
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
        rollback_agent
        return 0
    fi

    if $UPDATE_MODE; then
        update_agent
        return 0
    fi

    # Fresh install
    echo "╔══════════════════════════════════════════════╗"
    echo "║   computile-backup-agent — Installer         ║"
    echo "╚══════════════════════════════════════════════╝"
    echo

    check_root

    install_restic
    install_msmtp
    install_agent
    configure_interactive
    setup_dirs
    setup_ssh_key
    install_logrotate
    install_systemd

    echo
    echo "════════════════════════════════════════════════"
    echo "Installation complete! (v$(get_new_version))"
    echo
    echo "Next steps:"
    echo "  1. Review ${CONFIG_DIR}/backup-agent.conf"
    echo "  2. Add the SSH public key to the backup gateway"
    echo "  3. Test SSH: ssh backup-gateway echo ok"
    echo "  4. Test: sudo computile-backup --dry-run --verbose"
    echo "  5. Initialize repo: sudo computile-backup --init"
    echo "  6. Enable timer: sudo systemctl enable --now computile-backup.timer"
    echo
    echo "To update later: cd /opt/computile-backup-agent && git pull && sudo ./client/install.sh --update"
    echo "════════════════════════════════════════════════"
}

main "$@"
