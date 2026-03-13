#!/usr/bin/env bash
# ================================================================
# computile-backup-agent — TUI Manager
#
# Interactive terminal UI for managing backup operations.
# Uses whiptail (pre-installed on Debian/Ubuntu).
#
# Usage: sudo computile-manager
# ================================================================
set -euo pipefail

readonly CONFIG_DIR="/etc/computile-backup"
readonly CONFIG_FILE="${CONFIG_DIR}/backup-agent.conf"
readonly INSTALL_LIB="/usr/local/lib/computile-backup"
readonly INSTALL_BIN="/usr/local/bin"
readonly LOCKDIR="/var/run/computile-backup.lock"
readonly LOG_FILE_DEFAULT="/var/log/computile-backup.log"

# Terminal dimensions
TERM_LINES=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
WT_HEIGHT=$(( TERM_LINES - 4 ))
WT_WIDTH=$(( TERM_COLS - 10 ))
[[ $WT_HEIGHT -gt 40 ]] && WT_HEIGHT=40
[[ $WT_WIDTH -gt 90 ]] && WT_WIDTH=90
[[ $WT_HEIGHT -lt 20 ]] && WT_HEIGHT=20
[[ $WT_WIDTH -lt 60 ]] && WT_WIDTH=60
WT_LIST_HEIGHT=$(( WT_HEIGHT - 8 ))

# ──────────────────────────────────────────────
# Detect TUI backend
# ──────────────────────────────────────────────
DIALOG=""
if command -v whiptail &>/dev/null; then
    DIALOG="whiptail"
elif command -v dialog &>/dev/null; then
    DIALOG="dialog"
else
    echo "[ERROR] Neither whiptail nor dialog found. Install one:" >&2
    echo "  apt-get install whiptail" >&2
    exit 1
fi

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
msg_box() {
    $DIALOG --title "$1" --msgbox "$2" $WT_HEIGHT $WT_WIDTH
}

msg_scroll() {
    local title="$1"
    local content="$2"
    # Use a temp file for --textbox (better for long content)
    local tmpfile
    tmpfile=$(mktemp)
    echo "$content" > "$tmpfile"
    $DIALOG --title "$title" --scrolltext --textbox "$tmpfile" $WT_HEIGHT $WT_WIDTH || true
    rm -f "$tmpfile"
}

yesno() {
    $DIALOG --title "$1" --yesno "$2" 10 $WT_WIDTH
}

get_version() {
    if [[ -f "${INSTALL_LIB}/VERSION" ]]; then
        head -1 "${INSTALL_LIB}/VERSION" | tr -d '[:space:]'
    else
        echo "unknown"
    fi
}

load_config_vars() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # Source config in a subshell-safe way
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
}

is_backup_running() {
    if [[ -d "$LOCKDIR" ]]; then
        local pid
        pid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# ──────────────────────────────────────────────
# Status dashboard
# ──────────────────────────────────────────────
show_status() {
    load_config_vars

    local version
    version=$(get_version)

    local client_id="${CLIENT_ID:-<not configured>}"
    local host_id="${HOST_ID:-<not configured>}"
    local environment="${ENVIRONMENT:-<not set>}"
    local role="${ROLE:-<not set>}"
    local repo="${RESTIC_REPOSITORY:-<not configured>}"

    # Timer status
    local timer_status="unknown"
    if systemctl is-active computile-backup.timer &>/dev/null; then
        timer_status="active"
    elif systemctl is-enabled computile-backup.timer &>/dev/null; then
        timer_status="enabled (not active)"
    else
        timer_status="disabled"
    fi

    # Next run
    local next_run="N/A"
    next_run=$(systemctl show computile-backup.timer --property=NextElapseUSecRealtime 2>/dev/null \
        | cut -d= -f2 | head -1) || true
    [[ -z "$next_run" || "$next_run" == "n/a" ]] && next_run="N/A"

    # Last run result
    local last_result="N/A"
    local last_run_ts=""
    if systemctl show computile-backup.service --property=ExecMainStatus &>/dev/null; then
        local exit_code
        exit_code=$(systemctl show computile-backup.service --property=ExecMainStatus 2>/dev/null | cut -d= -f2)
        last_run_ts=$(systemctl show computile-backup.service --property=ExecMainStartTimestamp 2>/dev/null | cut -d= -f2-)
        if [[ "$exit_code" == "0" ]] && [[ -n "$last_run_ts" && "$last_run_ts" != *"n/a"* ]]; then
            last_result="SUCCESS ($last_run_ts)"
        elif [[ -n "$last_run_ts" && "$last_run_ts" != *"n/a"* ]]; then
            last_result="FAILED (exit $exit_code) — $last_run_ts"
        fi
    fi

    # Backup running?
    local running_status="No"
    if is_backup_running; then
        local pid
        pid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
        running_status="YES (PID $pid)"
    fi

    # Disk space on backup root
    local backup_root="${BACKUP_ROOT:-/var/backups/computile}"
    local disk_info="N/A"
    if [[ -d "$backup_root" ]]; then
        disk_info=$(df -h "$backup_root" 2>/dev/null | awk 'NR==2 {printf "%s used / %s total (%s)", $3, $2, $5}') || true
    fi

    # Log file
    local log_file="${LOG_FILE:-$LOG_FILE_DEFAULT}"
    local log_size="N/A"
    if [[ -f "$log_file" ]]; then
        log_size=$(du -h "$log_file" 2>/dev/null | cut -f1) || true
    fi

    local status_text=""
    status_text+="AGENT\n"
    status_text+="  Version:       v${version}\n"
    status_text+="  Client ID:     ${client_id}\n"
    status_text+="  Host ID:       ${host_id}\n"
    status_text+="  Environment:   ${environment}\n"
    status_text+="  Role:          ${role}\n"
    status_text+="\n"
    status_text+="REPOSITORY\n"
    status_text+="  ${repo}\n"
    status_text+="\n"
    status_text+="SCHEDULE\n"
    status_text+="  Timer:         ${timer_status}\n"
    status_text+="  Next run:      ${next_run}\n"
    status_text+="  Last result:   ${last_result}\n"
    status_text+="  Running now:   ${running_status}\n"
    status_text+="\n"
    status_text+="STORAGE\n"
    status_text+="  Backup root:   ${backup_root}\n"
    status_text+="  Disk usage:    ${disk_info}\n"
    status_text+="  Log file:      ${log_file} (${log_size})\n"

    msg_scroll "Status Dashboard" "$(echo -e "$status_text")"
}

# ──────────────────────────────────────────────
# Run backup
# ──────────────────────────────────────────────
run_backup() {
    local dry_run="${1:-no}"

    if is_backup_running; then
        local pid
        pid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
        msg_box "Backup Running" "A backup is already in progress (PID $pid).\n\nWait for it to finish before starting a new one."
        return
    fi

    local confirm_msg="Run a full backup now?"
    local cmd_args=""
    if [[ "$dry_run" == "yes" ]]; then
        confirm_msg="Run a DRY RUN backup? (no changes will be made)"
        cmd_args="--dry-run --verbose"
    fi

    if ! yesno "Confirm" "$confirm_msg"; then
        return
    fi

    clear
    echo "════════════════════════════════════════════════"
    if [[ "$dry_run" == "yes" ]]; then
        echo "  Running backup (DRY RUN)..."
    else
        echo "  Running backup..."
    fi
    echo "════════════════════════════════════════════════"
    echo
    echo "Press Ctrl+C to abort."
    echo

    # shellcheck disable=SC2086
    "${INSTALL_BIN}/computile-backup" $cmd_args || {
        echo
        echo "[DONE] Backup finished with errors. Press Enter to continue."
        read -r
        return
    }

    echo
    echo "[DONE] Backup completed successfully. Press Enter to continue."
    read -r
}

# ──────────────────────────────────────────────
# View snapshots
# ──────────────────────────────────────────────
show_snapshots() {
    load_config_vars

    if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
        msg_box "Error" "RESTIC_REPOSITORY not configured."
        return
    fi

    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${CONFIG_DIR}/restic-password}"

    local output
    output=$(restic snapshots --compact 2>&1) || {
        msg_scroll "Snapshots — Error" "$output"
        return
    }

    if [[ -z "$output" ]]; then
        msg_box "Snapshots" "No snapshots found in repository."
        return
    fi

    msg_scroll "Snapshots" "$output"
}

# ──────────────────────────────────────────────
# View logs
# ──────────────────────────────────────────────
show_logs() {
    load_config_vars
    local log_file="${LOG_FILE:-$LOG_FILE_DEFAULT}"

    if [[ ! -f "$log_file" ]]; then
        msg_box "Logs" "Log file not found: $log_file"
        return
    fi

    # Show last 200 lines
    local content
    content=$(tail -200 "$log_file" 2>/dev/null || echo "Cannot read log file")
    msg_scroll "Last 200 log lines — $log_file" "$content"
}

# ──────────────────────────────────────────────
# Show journal (systemd logs)
# ──────────────────────────────────────────────
show_journal() {
    local output
    output=$(journalctl -u computile-backup.service --no-pager -n 100 2>&1) || {
        msg_scroll "Journal — Error" "$output"
        return
    }

    msg_scroll "Systemd Journal (last 100 entries)" "$output"
}

# ──────────────────────────────────────────────
# Check repository health
# ──────────────────────────────────────────────
check_repo_health() {
    load_config_vars

    if [[ -z "${RESTIC_REPOSITORY:-}" ]]; then
        msg_box "Error" "RESTIC_REPOSITORY not configured."
        return
    fi

    export RESTIC_REPOSITORY
    export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${CONFIG_DIR}/restic-password}"

    clear
    echo "════════════════════════════════════════════════"
    echo "  Checking repository health..."
    echo "════════════════════════════════════════════════"
    echo
    echo "This may take a moment."
    echo

    local output=""
    local rc=0

    # Basic check
    echo "→ Running restic check..."
    local check_output
    check_output=$(restic check 2>&1) || rc=$?
    output+="REPOSITORY CHECK\n"
    output+="${check_output}\n\n"

    if [[ $rc -ne 0 ]]; then
        output+="⚠ Repository check reported issues (exit code $rc)\n\n"
    else
        output+="✓ Repository check passed\n\n"
    fi

    # Stats
    echo "→ Fetching repository stats..."
    local stats_output
    stats_output=$(restic stats --mode restore-size latest 2>&1) || true
    output+="LATEST SNAPSHOT STATS\n"
    output+="${stats_output}\n"

    msg_scroll "Repository Health" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Show Docker containers (DB discovery)
# ──────────────────────────────────────────────
show_docker_containers() {
    if ! command -v docker &>/dev/null; then
        msg_box "Docker" "Docker is not installed on this system."
        return
    fi

    local output=""

    # All running containers
    local all_containers
    all_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" 2>&1) || {
        msg_box "Docker — Error" "Cannot connect to Docker: $all_containers"
        return
    }

    output+="ALL RUNNING CONTAINERS\n"
    output+="${all_containers}\n\n"

    # Database containers (auto-detection)
    output+="DATABASE CONTAINERS (auto-detected)\n"

    local found_db=false
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        local image name
        image=$(docker inspect --format '{{.Config.Image}}' "$cid" 2>/dev/null | cut -d: -f1)
        name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        local image_lower
        image_lower=$(echo "$image" | tr '[:upper:]' '[:lower:]')

        local db_type=""
        for pattern in mysql mariadb; do
            [[ "$image_lower" == *"$pattern"* ]] && db_type="MySQL/MariaDB"
        done
        for pattern in postgres postgresql; do
            [[ "$image_lower" == *"$pattern"* ]] && db_type="PostgreSQL"
        done
        [[ "$image_lower" == *"redis"* ]] && db_type="Redis"

        if [[ -n "$db_type" ]]; then
            output+="  • ${name} — ${db_type} (${image})\n"
            found_db=true
        fi
    done < <(docker ps --no-trunc --format '{{.ID}}' 2>/dev/null)

    if ! $found_db; then
        output+="  (none detected)\n"
    fi

    msg_scroll "Docker Containers" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Edit configuration
# ──────────────────────────────────────────────
edit_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        msg_box "Config" "Config file not found: $CONFIG_FILE\n\nRun the installer first."
        return
    fi

    local editor="${EDITOR:-nano}"
    if ! command -v "$editor" &>/dev/null; then
        editor="vi"
    fi

    "$editor" "$CONFIG_FILE"
}

# ──────────────────────────────────────────────
# Manage systemd timer
# ──────────────────────────────────────────────
manage_timer() {
    while true; do
        local timer_active="inactive"
        local timer_enabled="disabled"
        systemctl is-active computile-backup.timer &>/dev/null && timer_active="active"
        systemctl is-enabled computile-backup.timer &>/dev/null && timer_enabled="enabled"

        local next_run="N/A"
        next_run=$(systemctl show computile-backup.timer --property=NextElapseUSecRealtime 2>/dev/null \
            | cut -d= -f2 | head -1) || true
        [[ -z "$next_run" || "$next_run" == "n/a" ]] && next_run="N/A"

        local status_line="Status: ${timer_enabled} / ${timer_active}  |  Next: ${next_run}"

        local choice
        choice=$($DIALOG --title "Timer Management" \
            --menu "$status_line" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "enable"   "Enable and start timer" \
            "disable"  "Disable and stop timer" \
            "status"   "Show detailed timer status" \
            "trigger"  "Trigger backup now (via systemd)" \
            "back"     "← Back to main menu" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            enable)
                systemctl enable --now computile-backup.timer 2>&1
                msg_box "Timer" "Timer enabled and started."
                ;;
            disable)
                if yesno "Confirm" "Disable the backup timer?\n\nAutomatic backups will stop."; then
                    systemctl disable --now computile-backup.timer 2>&1
                    msg_box "Timer" "Timer disabled."
                fi
                ;;
            status)
                local output
                output=$(systemctl status computile-backup.timer 2>&1 || true)
                output+="\n\n────────────────────────────────────\n\n"
                output+=$(systemctl list-timers computile-backup.timer 2>&1 || true)
                msg_scroll "Timer Status" "$(echo -e "$output")"
                ;;
            trigger)
                if yesno "Confirm" "Trigger a backup run via systemd?\n\nThis will start the backup service immediately."; then
                    systemctl start computile-backup.service 2>&1 || true
                    msg_box "Triggered" "Backup service started.\n\nUse 'View journal' to follow progress."
                fi
                ;;
            back|"") break ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Update agent
# ──────────────────────────────────────────────
update_agent() {
    # Find source repo
    local source_repo=""
    if [[ -f "${INSTALL_LIB}/.source-repo" ]]; then
        source_repo=$(cat "${INSTALL_LIB}/.source-repo" 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -z "$source_repo" ]] || [[ ! -d "$source_repo" ]]; then
        # Try common path
        if [[ -d "/opt/computile-backup-agent" ]]; then
            source_repo="/opt/computile-backup-agent"
        else
            msg_box "Update" "Cannot find agent source repository.\n\nExpected at: ${source_repo:-/opt/computile-backup-agent}\n\nClone it first:\n  git clone <repo-url> /opt/computile-backup-agent"
            return
        fi
    fi

    if ! yesno "Update Agent" "Pull latest changes and update?\n\nSource: ${source_repo}"; then
        return
    fi

    clear
    echo "════════════════════════════════════════════════"
    echo "  Updating agent..."
    echo "════════════════════════════════════════════════"
    echo

    echo "→ Pulling latest changes..."
    if ! (cd "$source_repo" && git pull); then
        echo
        echo "[ERROR] git pull failed. Press Enter to continue."
        read -r
        return
    fi

    echo
    echo "→ Running install.sh --update..."
    echo
    if bash "${source_repo}/client/install.sh" --update; then
        echo
        echo "[DONE] Update complete. Press Enter to continue."
    else
        echo
        echo "[ERROR] Update failed. Press Enter to continue."
    fi
    read -r
}

# ──────────────────────────────────────────────
# Verify SSH connectivity to gateway
# ──────────────────────────────────────────────
check_ssh_connectivity() {
    load_config_vars

    local repo="${RESTIC_REPOSITORY:-}"
    if [[ -z "$repo" ]]; then
        msg_box "Error" "RESTIC_REPOSITORY not configured."
        return
    fi

    # Extract user@host from sftp:user@host:/path
    local ssh_target=""
    if [[ "$repo" =~ ^sftp:([^:]+): ]]; then
        ssh_target="${BASH_REMATCH[1]}"
    else
        msg_box "Error" "Cannot parse SSH target from repository:\n$repo"
        return
    fi

    clear
    echo "════════════════════════════════════════════════"
    echo "  Testing SSH connectivity to gateway..."
    echo "════════════════════════════════════════════════"
    echo
    echo "Target: ${ssh_target}"
    echo

    local output=""

    # Test 1: SFTP connectivity (the gateway uses ForceCommand internal-sftp,
    # so regular SSH commands won't work — SFTP is the real transport)
    echo "→ Testing SFTP connection..."
    local sftp_rc=0
    local sftp_output
    sftp_output=$(echo "ls" | sftp -o ConnectTimeout=10 -o BatchMode=yes "${ssh_target}" 2>&1) || sftp_rc=$?

    output+="SFTP CONNECTION\n"
    output+="  Target: ${ssh_target}\n"
    if [[ $sftp_rc -eq 0 ]]; then
        output+="  Result: ✓ SFTP connected successfully\n"
    else
        output+="  Result: ✗ SFTP connection failed (exit code ${sftp_rc})\n"
        output+="  Output:\n"
        # Indent sftp output for readability
        while IFS= read -r errline; do
            output+="    ${errline}\n"
        done <<< "$sftp_output"
        output+="\n"
    fi
    output+="\n"

    # Test 2: SSH transport layer (key exchange, auth)
    echo "→ Testing SSH transport..."
    local ssh_rc=0
    local ssh_output
    ssh_output=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_target}" true 2>&1) || ssh_rc=$?

    output+="SSH TRANSPORT\n"
    # exit code 0 = shell access (unlikely with ForceCommand)
    # exit code 1 = connected but command rejected (expected with ForceCommand internal-sftp)
    # exit code 255 = connection failed
    if [[ $ssh_rc -eq 0 ]] || [[ $ssh_rc -eq 1 ]]; then
        output+="  Result: ✓ SSH auth OK (exit $ssh_rc"
        if [[ $ssh_rc -eq 1 ]]; then
            output+=" — expected: ForceCommand blocks shell access"
        fi
        output+=")\n"
    else
        output+="  Result: ✗ SSH connection failed (exit code ${ssh_rc})\n"
        output+="  Output:\n"
        while IFS= read -r errline; do
            output+="    ${errline}\n"
        done <<< "$ssh_output"
        output+="\n"
    fi
    output+="\n"

    # Overall verdict
    if [[ $sftp_rc -eq 0 ]]; then
        output+="VERDICT: ✓ Gateway is reachable and SFTP works — backups will function.\n"
    elif [[ $ssh_rc -le 1 ]]; then
        output+="VERDICT: ⚠ SSH auth works but SFTP failed — check gateway SFTP config.\n"
    else
        output+="VERDICT: ✗ Cannot reach gateway.\n\n"
        output+="TROUBLESHOOTING\n"
        output+="  • Is Tailscale running? tailscale status\n"
        output+="  • Is the gateway reachable? ping $(echo "${ssh_target}" | cut -d@ -f2)\n"
        output+="  • Is the SSH key authorized? Check gateway authorized_keys\n"
        output+="  • Check SSH config: cat ~/.ssh/config\n"
        output+="  • Verbose test: sftp -v ${ssh_target}\n"
    fi

    msg_scroll "SSH Connectivity" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Show configuration summary
# ──────────────────────────────────────────────
show_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        msg_box "Config" "Config file not found: $CONFIG_FILE"
        return
    fi

    # Show config without secret values
    local content
    content=$(sed -E 's/(PASS|PASSWORD|SECRET)([^=]*)="[^"]+"/\1\2="********"/g' "$CONFIG_FILE" 2>/dev/null \
        || cat "$CONFIG_FILE")

    msg_scroll "Configuration — $CONFIG_FILE" "$content"
}

# ──────────────────────────────────────────────
# Disk & system checks
# ──────────────────────────────────────────────
show_system_health() {
    load_config_vars

    local output=""

    # Disk space
    output+="DISK SPACE\n"
    local backup_root="${BACKUP_ROOT:-/var/backups/computile}"
    if [[ -d "$backup_root" ]]; then
        output+="  Backup root ($backup_root):\n"
        output+="  $(df -h "$backup_root" 2>/dev/null | awk 'NR==2 {printf "  %s used / %s total (%s available)", $3, $2, $4}')\n\n"
    fi
    output+="  Root filesystem:\n"
    output+="  $(df -h / 2>/dev/null | awk 'NR==2 {printf "  %s used / %s total (%s available)", $3, $2, $4}')\n\n"

    # DB dump directory
    local dump_dir="${backup_root}/db"
    if [[ -d "$dump_dir" ]]; then
        local dump_size
        dump_size=$(du -sh "$dump_dir" 2>/dev/null | cut -f1) || dump_size="N/A"
        local dump_count
        dump_count=$(find "$dump_dir" -type f \( -name "*.sql.gz" -o -name "*.rdb" \) 2>/dev/null | wc -l) || dump_count=0
        output+="DATABASE DUMPS\n"
        output+="  Directory:  $dump_dir\n"
        output+="  Total size: $dump_size\n"
        output+="  Files:      $dump_count\n\n"
    fi

    # Prerequisites
    output+="PREREQUISITES\n"
    for cmd in restic docker msmtp curl jq ssh; do
        if command -v "$cmd" &>/dev/null; then
            local ver=""
            case "$cmd" in
                restic)  ver=" ($(restic version 2>/dev/null | awk '{print $2}'))" ;;
                docker)  ver=" ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ','))" ;;
                ssh)     ver=" ($(ssh -V 2>&1 | head -1))" ;;
            esac
            output+="  ✓ ${cmd}${ver}\n"
        else
            output+="  ✗ ${cmd} — not installed\n"
        fi
    done
    output+="\n"

    # SSH key
    output+="SSH KEY\n"
    if [[ -f /root/.ssh/backup_ed25519 ]]; then
        output+="  ✓ /root/.ssh/backup_ed25519 exists\n"
        output+="  Public key fingerprint:\n"
        output+="  $(ssh-keygen -lf /root/.ssh/backup_ed25519.pub 2>/dev/null || echo "N/A")\n"
    else
        output+="  ✗ No backup SSH key found at /root/.ssh/backup_ed25519\n"
    fi
    output+="\n"

    # Restic password file
    output+="SECRET FILES\n"
    local pw_file="${RESTIC_PASSWORD_FILE:-${CONFIG_DIR}/restic-password}"
    if [[ -f "$pw_file" ]]; then
        local perms
        perms=$(stat -c '%a' "$pw_file" 2>/dev/null || true)
        if [[ "$perms" == "600" ]]; then
            output+="  ✓ Restic password: ${pw_file} (mode $perms)\n"
        else
            output+="  ⚠ Restic password: ${pw_file} (mode $perms — should be 600)\n"
        fi
    else
        output+="  ✗ Restic password file not found: ${pw_file}\n"
    fi

    if [[ -f "${CONFIG_DIR}/smtp-password" ]]; then
        local perms
        perms=$(stat -c '%a' "${CONFIG_DIR}/smtp-password" 2>/dev/null || true)
        output+="  ✓ SMTP password: ${CONFIG_DIR}/smtp-password (mode $perms)\n"
    fi
    output+="\n"

    # Tailscale
    output+="TAILSCALE\n"
    if command -v tailscale &>/dev/null; then
        local ts_status
        ts_status=$(tailscale status --self 2>/dev/null | head -1) || ts_status="cannot get status"
        output+="  ✓ ${ts_status}\n"
    else
        output+="  ✗ Tailscale not installed\n"
    fi

    msg_scroll "System Health" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Main menu
# ──────────────────────────────────────────────
main_menu() {
    while true; do
        local version
        version=$(get_version)

        local running_tag=""
        if is_backup_running; then
            running_tag="  ⚡ BACKUP RUNNING"
        fi

        local choice
        choice=$($DIALOG --title "computile-backup-agent v${version}${running_tag}" \
            --menu "Select an operation:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "status"     "📊  Status dashboard" \
            "backup"     "▶  Run backup now" \
            "dry-run"    "🔍  Run backup (dry run)" \
            "snapshots"  "📦  View snapshots" \
            "logs"       "📄  View backup log" \
            "journal"    "📋  View systemd journal" \
            "health"     "🏥  Check repository health" \
            "ssh"        "🔗  Test SSH connectivity" \
            "docker"     "🐳  Docker containers" \
            "system"     "🖥  System health check" \
            "config"     "📝  View configuration" \
            "edit"       "✏  Edit configuration" \
            "timer"      "⏰  Manage timer" \
            "update"     "⬆  Update agent" \
            "quit"       "❌  Quit" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            status)    show_status ;;
            backup)    run_backup "no" ;;
            dry-run)   run_backup "yes" ;;
            snapshots) show_snapshots ;;
            logs)      show_logs ;;
            journal)   show_journal ;;
            health)    check_repo_health ;;
            ssh)       check_ssh_connectivity ;;
            docker)    show_docker_containers ;;
            system)    show_system_health ;;
            config)    show_config ;;
            edit)      edit_config ;;
            timer)     manage_timer ;;
            update)    update_agent ;;
            quit|"")   break ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This tool must be run as root (use sudo)" >&2
    exit 1
fi

# Handle --version
if [[ "${1:-}" == "--version" ]]; then
    echo "computile-manager v$(get_version)"
    exit 0
fi

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    cat <<'HELP'
computile-manager — TUI manager for computile-backup-agent

Usage: sudo computile-manager

Interactive terminal interface for managing backup operations:
  • Status dashboard and health checks
  • Run backups (full or dry-run)
  • View snapshots, logs, and systemd journal
  • Check repository health and SSH connectivity
  • Manage systemd timer (enable/disable/trigger)
  • Edit configuration and update the agent

Requires: whiptail or dialog
HELP
    exit 0
fi

main_menu
