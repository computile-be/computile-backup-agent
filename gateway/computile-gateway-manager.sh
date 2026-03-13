#!/usr/bin/env bash
# ================================================================
# computile-backup — Gateway Manager (TUI)
#
# Interactive terminal UI for monitoring and managing the backup
# gateway. Provides overview of all clients, storage usage,
# active sessions, and alerting for stale backups.
#
# Usage: sudo computile-gateway-manager
# ================================================================
set -euo pipefail

readonly BACKUP_BASE="/srv/backups"
readonly STALE_THRESHOLD_DAYS=2  # Alert if no backup activity in N days

# Terminal dimensions
TERM_LINES=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
WT_HEIGHT=$(( TERM_LINES - 4 ))
WT_WIDTH=$(( TERM_COLS - 10 ))
[[ $WT_HEIGHT -gt 40 ]] && WT_HEIGHT=40
[[ $WT_WIDTH -gt 100 ]] && WT_WIDTH=100
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
    local tmpfile
    tmpfile=$(mktemp)
    echo "$content" > "$tmpfile"
    $DIALOG --title "$title" --scrolltext --textbox "$tmpfile" $WT_HEIGHT $WT_WIDTH || true
    rm -f "$tmpfile"
}

yesno() {
    $DIALOG --title "$1" --yesno "$2" 10 $WT_WIDTH
}

# ──────────────────────────────────────────────
# Data collection helpers
# ──────────────────────────────────────────────

# List all backup-* users (client IDs)
list_clients() {
    # Find backup-* directories in BACKUP_BASE
    local clients=()
    for dir in "${BACKUP_BASE}"/backup-*; do
        [[ -d "$dir" ]] || continue
        local username
        username=$(basename "$dir")
        clients+=("$username")
    done
    printf '%s\n' "${clients[@]}"
}

# Get disk usage for a path (human-readable)
get_size() {
    du -sh "$1" 2>/dev/null | cut -f1 || echo "N/A"
}

# Get disk usage in bytes for sorting
get_size_bytes() {
    du -sb "$1" 2>/dev/null | cut -f1 || echo "0"
}

# Get last modification time of any file under a path
get_last_activity() {
    local path="$1"
    local newest
    newest=$(find "$path" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    if [[ -n "$newest" ]]; then
        date -d "@${newest%%.*}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "N/A"
    else
        echo "never"
    fi
}

# Get last modification timestamp (epoch) for staleness check
get_last_activity_epoch() {
    local path="$1"
    find "$path" -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1
}

# Count restic snapshots by counting files in snapshots/ directory
# (works without restic password — just filesystem inspection)
count_snapshots() {
    local data_dir="$1"
    local count=0
    # Look for restic snapshot files in any VPS subdir
    for snapdir in "$data_dir"/*/snapshots "$data_dir"/snapshots; do
        if [[ -d "$snapdir" ]]; then
            count=$(( count + $(find "$snapdir" -type f 2>/dev/null | wc -l) ))
        fi
    done
    echo "$count"
}

# List VPS directories for a client
list_vps_dirs() {
    local data_dir="$1"
    for vps_dir in "$data_dir"/*/; do
        [[ -d "$vps_dir" ]] || continue
        local vps_name
        vps_name=$(basename "$vps_dir")
        # Skip restic internal dirs at top level
        [[ "$vps_name" == "data" || "$vps_name" == "keys" || "$vps_name" == "locks" || \
           "$vps_name" == "snapshots" || "$vps_name" == "index" || "$vps_name" == "config" ]] && continue
        echo "$vps_name"
    done
}

# Check if a path contains a restic repository (has config file)
is_restic_repo() {
    [[ -f "$1/config" ]]
}

# Get active SFTP sessions
get_sftp_sessions() {
    # Method 1: Check sshd processes for sftp subsystem
    ps aux 2>/dev/null | grep '[s]ftp-server' | awk '{print $1, $2, $9, $10, $11}' || true
}

# ──────────────────────────────────────────────
# Client overview dashboard
# ──────────────────────────────────────────────
show_overview() {
    local output=""
    local now
    now=$(date +%s)
    local stale_secs=$(( STALE_THRESHOLD_DAYS * 86400 ))

    local total_clients=0
    local stale_clients=0
    local active_clients=0
    local total_size="N/A"

    output+="CLIENT OVERVIEW\n"
    output+="$(printf '%-24s  %-8s  %-6s  %-18s  %s\n' 'CLIENT' 'SIZE' 'SNAPS' 'LAST ACTIVITY' 'STATUS')\n"
    output+="$(printf '%0.s─' {1..80})\n"

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        ((total_clients++))

        local client_dir="${BACKUP_BASE}/${client}"
        local data_dir="${client_dir}/data"

        local size
        size=$(get_size "$client_dir")

        local snaps=0
        local last_activity="never"
        local last_epoch=""
        local status="OK"

        if [[ -d "$data_dir" ]]; then
            snaps=$(count_snapshots "$data_dir")
            last_activity=$(get_last_activity "$data_dir")
            last_epoch=$(get_last_activity_epoch "$data_dir")
        fi

        if [[ -z "$last_epoch" ]] || [[ "$last_epoch" == "0" ]]; then
            status="EMPTY"
            ((stale_clients++))
        elif [[ $(( now - last_epoch )) -gt $stale_secs ]]; then
            status="STALE"
            ((stale_clients++))
        else
            ((active_clients++))
        fi

        # Client ID without "backup-" prefix for display
        local display_name="${client#backup-}"

        output+="$(printf '%-24s  %-8s  %-6s  %-18s  %s\n' "$display_name" "$size" "$snaps" "$last_activity" "$status")\n"
    done < <(list_clients)

    output+="\n"

    # Summary
    total_size=$(get_size "$BACKUP_BASE")
    output+="SUMMARY\n"
    output+="  Total clients:  ${total_clients}\n"
    output+="  Active:         ${active_clients}\n"
    output+="  Stale/empty:    ${stale_clients}\n"
    output+="  Total storage:  ${total_size}\n"

    # Active SFTP sessions
    local sessions
    sessions=$(get_sftp_sessions)
    if [[ -n "$sessions" ]]; then
        local session_count
        session_count=$(echo "$sessions" | wc -l)
        output+="\n  Active SFTP:    ${session_count} session(s)\n"
    else
        output+="\n  Active SFTP:    none\n"
    fi

    msg_scroll "Gateway Overview" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Per-client detail view
# ──────────────────────────────────────────────
show_client_detail() {
    # Build menu of clients
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local size
        size=$(get_size "${BACKUP_BASE}/${client}")
        clients+=("$display" "${size}")
    done < <(list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_box "Clients" "No backup clients found."
        return
    fi

    local choice
    choice=$($DIALOG --title "Select Client" \
        --menu "Choose a client to inspect:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return

    local username="backup-${choice}"
    local client_dir="${BACKUP_BASE}/${username}"
    local data_dir="${client_dir}/data"

    local output=""
    output+="CLIENT: ${choice}\n"
    output+="$(printf '%0.s─' {1..60})\n"
    output+="  User:      ${username}\n"
    output+="  Directory: ${client_dir}\n"
    output+="  Total size: $(get_size "$client_dir")\n"
    output+="  Last activity: $(get_last_activity "$data_dir" 2>/dev/null || echo 'N/A')\n"

    # SSH key
    local auth_keys="${client_dir}/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        local key_count
        key_count=$(grep -c '^ssh-' "$auth_keys" 2>/dev/null || echo "0")
        output+="  SSH keys: ${key_count}\n"
    else
        output+="  SSH keys: none\n"
    fi
    output+="\n"

    # Check for VPS directories vs direct restic repo
    if [[ -d "$data_dir" ]]; then
        if is_restic_repo "$data_dir"; then
            # Single restic repo directly in data/
            output+="REPOSITORY (direct)\n"
            local snaps
            snaps=$(count_snapshots "$data_dir")
            output+="  Snapshots: ${snaps}\n"
            output+="  Size:      $(get_size "$data_dir")\n"
            output+="  Last mod:  $(get_last_activity "$data_dir")\n"
        else
            # VPS subdirectories
            output+="VPS DIRECTORIES\n"
            output+="$(printf '  %-20s  %-8s  %-6s  %s\n' 'VPS' 'SIZE' 'SNAPS' 'LAST ACTIVITY')\n"
            output+="  $(printf '%0.s─' {1..64})\n"

            local vps_found=false
            for vps_path in "$data_dir"/*/; do
                [[ -d "$vps_path" ]] || continue
                local vps_name
                vps_name=$(basename "$vps_path")
                # Skip _meta directory (recovery metadata, shown separately)
                [[ "$vps_name" == "_meta" ]] && continue

                local vps_size
                vps_size=$(get_size "$vps_path")
                local vps_snaps
                vps_snaps=$(count_snapshots "$vps_path")
                # If no snapshots dir but has restic config, count at this level
                if [[ $vps_snaps -eq 0 ]] && is_restic_repo "$vps_path"; then
                    vps_snaps=$(find "$vps_path/snapshots" -type f 2>/dev/null | wc -l)
                fi
                local vps_last
                vps_last=$(get_last_activity "$vps_path")

                output+="$(printf '  %-20s  %-8s  %-6s  %s\n' "$vps_name" "$vps_size" "$vps_snaps" "$vps_last")\n"
                vps_found=true
            done

            if ! $vps_found; then
                output+="  (no VPS directories found)\n"
            fi
        fi
    else
        output+="  Data directory not found\n"
    fi

    # Recovery metadata
    local meta_dir="${data_dir}/_meta"
    output+="\n"
    output+="RECOVERY METADATA\n"
    if [[ -d "$meta_dir" ]]; then
        for vps_meta in "$meta_dir"/*/; do
            [[ -d "$vps_meta" ]] || continue
            local vps_id
            vps_id=$(basename "$vps_meta")
            local has_password="no"
            local has_config="no"
            local has_key="no"
            [[ -f "$vps_meta/restic-password" ]] && has_password="yes"
            [[ -f "$vps_meta/backup-agent.conf" ]] && has_config="yes"
            [[ -f "$vps_meta/ssh-public-key.pub" ]] && has_key="yes"
            local meta_age
            meta_age=$(get_last_activity "$vps_meta")
            output+="  ${vps_id}: password=${has_password} config=${has_config} ssh-key=${has_key} (updated: ${meta_age})\n"
        done
    else
        output+="  No recovery metadata synced yet.\n"
        output+="  (VPS agents v1.5.1+ sync automatically after each backup)\n"
    fi

    # Disk usage breakdown
    output+="\n"
    output+="DISK USAGE\n"
    local du_output
    du_output=$(du -h --max-depth=2 "$client_dir" 2>/dev/null | sort -rh | head -15) || true
    if [[ -n "$du_output" ]]; then
        output+="$du_output\n"
    fi

    msg_scroll "Client: ${choice}" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Active SFTP sessions
# ──────────────────────────────────────────────
show_active_sessions() {
    local output=""
    output+="ACTIVE SFTP SESSIONS\n"
    output+="$(printf '%0.s─' {1..70})\n\n"

    # Method 1: sftp-server processes
    local sftp_procs
    sftp_procs=$(ps aux 2>/dev/null | grep '[s]ftp-server' || true)

    if [[ -n "$sftp_procs" ]]; then
        output+="SFTP server processes:\n"
        output+="$(printf '  %-16s  %-8s  %-8s  %s\n' 'USER' 'PID' 'CPU' 'TIME')\n"
        while IFS= read -r line; do
            local user pid cpu time
            user=$(echo "$line" | awk '{print $1}')
            pid=$(echo "$line" | awk '{print $2}')
            cpu=$(echo "$line" | awk '{print $3}')
            time=$(echo "$line" | awk '{print $10}')
            output+="$(printf '  %-16s  %-8s  %-8s  %s\n' "$user" "$pid" "$cpu" "$time")\n"
        done <<< "$sftp_procs"
    else
        output+="  No active SFTP sessions.\n"
    fi

    output+="\n"

    # Method 2: SSH connections from backupusers
    output+="SSH CONNECTIONS (backup users)\n"
    local ssh_conns
    ssh_conns=$(ss -tnp 2>/dev/null | grep ':22' | grep 'sshd' || true)
    if [[ -n "$ssh_conns" ]]; then
        output+="$ssh_conns\n"
    else
        output+="  No active SSH connections from backup users.\n"
    fi

    output+="\n"

    # Restic lock files (indicate active backup operations)
    output+="ACTIVE LOCKS (restic)\n"
    local locks_found=false
    for client_dir in "${BACKUP_BASE}"/backup-*/data; do
        [[ -d "$client_dir" ]] || continue
        # Search for lock files recursively
        local locks
        locks=$(find "$client_dir" -path '*/locks/*' -type f 2>/dev/null) || true
        if [[ -n "$locks" ]]; then
            while IFS= read -r lock; do
                local lock_age
                lock_age=$(stat -c '%Y' "$lock" 2>/dev/null || echo "0")
                local now
                now=$(date +%s)
                local age_mins=$(( (now - lock_age) / 60 ))
                local client_name
                client_name=$(echo "$lock" | sed "s|${BACKUP_BASE}/||" | cut -d/ -f1)
                output+="  ${client_name}: lock file (${age_mins}min old) — $(basename "$lock")\n"
                locks_found=true
            done <<< "$locks"
        fi
    done
    if ! $locks_found; then
        output+="  No active locks.\n"
    fi

    msg_scroll "Active Sessions & Operations" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Stale backup alerts
# ──────────────────────────────────────────────
show_stale_alerts() {
    local output=""
    local now
    now=$(date +%s)
    local stale_secs=$(( STALE_THRESHOLD_DAYS * 86400 ))

    local alerts=0
    local warnings=0

    output+="BACKUP FRESHNESS CHECK\n"
    output+="Threshold: ${STALE_THRESHOLD_DAYS} day(s)\n"
    output+="$(printf '%0.s─' {1..70})\n\n"

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local data_dir="${BACKUP_BASE}/${client}/data"

        if [[ ! -d "$data_dir" ]]; then
            output+="  ALERT  ${display}: data directory missing\n"
            ((alerts++))
            continue
        fi

        local last_epoch
        last_epoch=$(get_last_activity_epoch "$data_dir")

        if [[ -z "$last_epoch" ]] || [[ "$last_epoch" == "0" ]]; then
            output+="  ALERT  ${display}: no backup data found (never backed up?)\n"
            ((alerts++))
            continue
        fi

        local age_secs=$(( now - last_epoch ))
        local age_days=$(( age_secs / 86400 ))
        local age_hours=$(( (age_secs % 86400) / 3600 ))
        local last_time
        last_time=$(date -d "@${last_epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

        if [[ $age_secs -gt $(( stale_secs * 3 )) ]]; then
            output+="  ALERT  ${display}: last backup ${age_days}d ${age_hours}h ago (${last_time})\n"
            ((alerts++))
        elif [[ $age_secs -gt $stale_secs ]]; then
            output+="  WARN   ${display}: last backup ${age_days}d ${age_hours}h ago (${last_time})\n"
            ((warnings++))
        else
            output+="  OK     ${display}: last backup ${age_days}d ${age_hours}h ago (${last_time})\n"
        fi
    done < <(list_clients)

    output+="\n$(printf '%0.s─' {1..70})\n"
    if [[ $alerts -gt 0 ]]; then
        output+="RESULT: ${alerts} alert(s), ${warnings} warning(s) — action required\n"
    elif [[ $warnings -gt 0 ]]; then
        output+="RESULT: ${warnings} warning(s) — monitor closely\n"
    else
        output+="RESULT: All clients backed up within threshold\n"
    fi

    msg_scroll "Stale Backup Alerts" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# System health
# ──────────────────────────────────────────────
show_system_health() {
    local output=""

    # SMB mount
    output+="SMB MOUNT\n"
    if mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        local mount_info
        mount_info=$(mount | grep "$BACKUP_BASE" | head -1)
        output+="  Status: mounted\n"
        output+="  ${mount_info}\n"
        local disk_info
        disk_info=$(df -h "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {printf "  Used: %s / %s (%s available)", $3, $2, $4}') || true
        output+="  ${disk_info}\n"
    else
        if [[ -d "$BACKUP_BASE" ]]; then
            output+="  Status: NOT MOUNTED (directory exists but not a mount point)\n"
            output+="  Try: mount ${BACKUP_BASE}\n"
        else
            output+="  Status: MISSING (${BACKUP_BASE} does not exist)\n"
        fi
    fi
    output+="\n"

    # Root filesystem
    output+="ROOT FILESYSTEM\n"
    output+="  $(df -h / 2>/dev/null | awk 'NR==2 {printf "Used: %s / %s (%s available)", $3, $2, $4}')\n\n"

    # SSH service
    output+="SSH SERVICE\n"
    if systemctl is-active sshd &>/dev/null; then
        output+="  Status: running\n"
    elif systemctl is-active ssh &>/dev/null; then
        output+="  Status: running\n"
    else
        output+="  Status: NOT RUNNING\n"
    fi

    # Check backupusers group
    if getent group backupusers &>/dev/null; then
        local members
        members=$(getent group backupusers | cut -d: -f4)
        local member_count
        member_count=$(echo "$members" | tr ',' '\n' | grep -c . 2>/dev/null || echo "0")
        output+="  Backup users group: ${member_count} member(s)\n"
    else
        output+="  Backup users group: NOT FOUND\n"
    fi
    output+="\n"

    # fail2ban
    output+="FAIL2BAN\n"
    if systemctl is-active fail2ban &>/dev/null; then
        output+="  Status: running\n"
        local banned
        banned=$(fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print $NF}') || true
        if [[ -n "$banned" ]]; then
            output+="  Currently banned IPs: ${banned}\n"
        fi
        local total_banned
        total_banned=$(fail2ban-client status sshd 2>/dev/null | grep 'Total banned' | awk '{print $NF}') || true
        if [[ -n "$total_banned" ]]; then
            output+="  Total banned (since start): ${total_banned}\n"
        fi
    else
        output+="  Status: NOT RUNNING\n"
    fi
    output+="\n"

    # Tailscale
    output+="TAILSCALE\n"
    if command -v tailscale &>/dev/null; then
        local ts_status
        ts_status=$(tailscale status --self 2>/dev/null | head -1) || ts_status="cannot get status"
        output+="  ${ts_status}\n"
        local ts_peers
        ts_peers=$(tailscale status 2>/dev/null | grep -c 'linux' 2>/dev/null) || ts_peers="?"
        output+="  Linux peers: ${ts_peers}\n"
    else
        output+="  Not installed\n"
    fi
    output+="\n"

    # System uptime & load
    output+="SYSTEM\n"
    output+="  $(uptime 2>/dev/null || echo 'N/A')\n"

    msg_scroll "System Health" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# User management
# ──────────────────────────────────────────────
manage_users() {
    while true; do
        local choice
        choice=$($DIALOG --title "User Management" \
            --menu "Manage backup users:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "list"    "List all backup users" \
            "create"  "Create new backup user" \
            "remove"  "Remove backup user" \
            "keys"    "View SSH keys for a user" \
            "back"    "Back to main menu" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            list)   show_user_list ;;
            create) create_user_interactive ;;
            remove) remove_user_interactive ;;
            keys)   show_user_keys ;;
            back|"") break ;;
        esac
    done
}

show_user_list() {
    local output=""
    output+="BACKUP USERS\n"
    output+="$(printf '%-20s  %-12s  %-8s  %s\n' 'USERNAME' 'CLIENT ID' 'KEYS' 'DIRECTORY')\n"
    output+="$(printf '%0.s─' {1..70})\n"

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local auth_keys="${BACKUP_BASE}/${client}/.ssh/authorized_keys"
        local key_count=0
        if [[ -f "$auth_keys" ]]; then
            key_count=$(grep -c '^ssh-' "$auth_keys" 2>/dev/null || echo "0")
        fi
        output+="$(printf '%-20s  %-12s  %-8s  %s\n' "$client" "$display" "$key_count" "${BACKUP_BASE}/${client}")\n"
    done < <(list_clients)

    msg_scroll "Backup Users" "$(echo -e "$output")"
}

create_user_interactive() {
    local create_script=""
    if command -v computile-create-backup-user &>/dev/null; then
        create_script="computile-create-backup-user"
    else
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        create_script="${script_dir}/create_backup_user.sh"
        if [[ ! -f "$create_script" ]]; then
            create_script="/opt/computile-backup-agent/gateway/create_backup_user.sh"
        fi
    fi

    if [[ ! -f "$create_script" ]] && ! command -v "$create_script" &>/dev/null; then
        msg_box "Error" "Cannot find create_backup_user script"
        return
    fi

    local client_id
    client_id=$($DIALOG --title "Create User" \
        --inputbox "Enter client ID (alphanumeric, dash, underscore):" 10 $WT_WIDTH \
        3>&1 1>&2 2>&3) || return

    [[ -z "$client_id" ]] && return

    local vps_id
    vps_id=$($DIALOG --title "Create User" \
        --inputbox "Enter VPS ID (optional, leave empty to skip):" 10 $WT_WIDTH \
        3>&1 1>&2 2>&3) || return

    local args=("$client_id")
    [[ -n "$vps_id" ]] && args+=("--vps" "$vps_id")

    clear
    echo "════════════════════════════════════════════════"
    echo "  Creating backup user..."
    echo "════════════════════════════════════════════════"
    echo
    bash "$create_script" "${args[@]}" || true
    echo
    echo "Press Enter to continue."
    read -r
}

remove_user_interactive() {
    local remove_script=""
    if command -v computile-remove-backup-user &>/dev/null; then
        remove_script="computile-remove-backup-user"
    else
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        remove_script="${script_dir}/remove_backup_user.sh"
        if [[ ! -f "$remove_script" ]]; then
            remove_script="/opt/computile-backup-agent/gateway/remove_backup_user.sh"
        fi
    fi

    if [[ ! -f "$remove_script" ]] && ! command -v "$remove_script" &>/dev/null; then
        msg_box "Error" "Cannot find remove_backup_user script"
        return
    fi

    # Build list of clients for selection
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local size
        size=$(get_size "${BACKUP_BASE}/${client}")
        clients+=("$display" "$size")
    done < <(list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_box "Remove User" "No backup users found."
        return
    fi

    local choice
    choice=$($DIALOG --title "Remove User" \
        --menu "Select client to remove:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return

    local delete_data=false
    if yesno "Delete Data?" "Also delete all backup data for ${choice}?\n\nThis is IRREVERSIBLE."; then
        delete_data=true
    fi

    clear
    echo "════════════════════════════════════════════════"
    echo "  Removing backup user: backup-${choice}"
    echo "════════════════════════════════════════════════"
    echo
    local args=("$choice")
    $delete_data && args+=("--delete-data")
    bash "$remove_script" "${args[@]}" || true
    echo
    echo "Press Enter to continue."
    read -r
}

show_user_keys() {
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        clients+=("$display" "")
    done < <(list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_box "SSH Keys" "No backup users found."
        return
    fi

    local choice
    choice=$($DIALOG --title "SSH Keys" \
        --menu "Select client:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return

    local auth_keys="${BACKUP_BASE}/backup-${choice}/.ssh/authorized_keys"
    local output=""
    output+="SSH KEYS FOR: backup-${choice}\n"
    output+="File: ${auth_keys}\n"
    output+="$(printf '%0.s─' {1..60})\n\n"

    if [[ -f "$auth_keys" ]]; then
        local idx=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            ((idx++))
            # Show key type and comment (last field), truncate the key itself
            local key_type
            key_type=$(echo "$line" | awk '{print $1}')
            local key_comment
            key_comment=$(echo "$line" | awk '{print $NF}')
            local key_hash
            key_hash=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}') || key_hash="N/A"
            output+="  Key ${idx}:\n"
            output+="    Type:        ${key_type}\n"
            output+="    Fingerprint: ${key_hash}\n"
            output+="    Comment:     ${key_comment}\n\n"
        done < "$auth_keys"

        if [[ $idx -eq 0 ]]; then
            output+="  No SSH keys found in authorized_keys.\n"
        fi
    else
        output+="  File does not exist.\n"
    fi

    msg_scroll "SSH Keys: ${choice}" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Storage breakdown
# ──────────────────────────────────────────────
show_storage() {
    local output=""

    output+="STORAGE OVERVIEW\n"
    output+="$(printf '%0.s─' {1..70})\n\n"

    # Overall
    if mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        output+="MOUNT: ${BACKUP_BASE} (SMB)\n"
    else
        output+="DIRECTORY: ${BACKUP_BASE} (local)\n"
    fi
    output+="$(df -h "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {printf "  Total: %s  Used: %s  Available: %s  Usage: %s", $2, $3, $4, $5}')\n\n"

    # Per-client breakdown sorted by size
    output+="PER-CLIENT USAGE (sorted by size)\n"
    output+="$(printf '  %-24s  %s\n' 'CLIENT' 'SIZE')\n"
    output+="  $(printf '%0.s─' {1..40})\n"

    # Collect sizes and sort
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local size_bytes
        size_bytes=$(get_size_bytes "${BACKUP_BASE}/${client}")
        local size_human
        size_human=$(get_size "${BACKUP_BASE}/${client}")
        echo "${size_bytes} ${client} ${size_human}" >> "$tmpfile"
    done < <(list_clients)

    sort -rn "$tmpfile" | while IFS=' ' read -r _ client size; do
        local display="${client#backup-}"
        output+="$(printf '  %-24s  %s\n' "$display" "$size")"
        echo "$output" > /dev/null  # force variable in subshell
        printf '  %-24s  %s\n' "$display" "$size"
    done > "${tmpfile}.display"

    output+="$(cat "${tmpfile}.display" 2>/dev/null)\n"
    rm -f "$tmpfile" "${tmpfile}.display"

    msg_scroll "Storage" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Check alert (non-interactive, for cron)
# ──────────────────────────────────────────────
check_alerts_cli() {
    local now
    now=$(date +%s)
    local stale_secs=$(( STALE_THRESHOLD_DAYS * 86400 ))
    local exit_code=0

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local data_dir="${BACKUP_BASE}/${client}/data"

        if [[ ! -d "$data_dir" ]]; then
            echo "ALERT: ${display} — data directory missing"
            exit_code=1
            continue
        fi

        local last_epoch
        last_epoch=$(get_last_activity_epoch "$data_dir")

        if [[ -z "$last_epoch" ]] || [[ "$last_epoch" == "0" ]]; then
            echo "ALERT: ${display} — never backed up"
            exit_code=1
            continue
        fi

        local age_secs=$(( now - last_epoch ))
        local age_days=$(( age_secs / 86400 ))
        local age_hours=$(( (age_secs % 86400) / 3600 ))

        if [[ $age_secs -gt $stale_secs ]]; then
            echo "ALERT: ${display} — last backup ${age_days}d ${age_hours}h ago"
            exit_code=1
        fi
    done < <(list_clients)

    return $exit_code
}

# ──────────────────────────────────────────────
# View recent SSH/SFTP auth logs
# ──────────────────────────────────────────────
show_auth_logs() {
    local output=""
    output+="RECENT SFTP AUTH LOGS (last 50 backup-related entries)\n"
    output+="$(printf '%0.s─' {1..70})\n\n"

    local logs
    logs=$(grep 'backup-' /var/log/auth.log 2>/dev/null | tail -50) || true

    if [[ -n "$logs" ]]; then
        output+="$logs\n"
    else
        output+="  No recent backup-related auth entries found.\n"
    fi

    msg_scroll "Auth Logs" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Main menu
# ──────────────────────────────────────────────
main_menu() {
    while true; do
        # Quick count for menu title
        local client_count=0
        while IFS= read -r c; do [[ -n "$c" ]] && ((client_count++)); done < <(list_clients)

        local sftp_count=0
        local sftp_procs
        sftp_procs=$(get_sftp_sessions)
        [[ -n "$sftp_procs" ]] && sftp_count=$(echo "$sftp_procs" | wc -l)

        local title="computile-backup Gateway — ${client_count} clients"
        [[ $sftp_count -gt 0 ]] && title+=" — ${sftp_count} active"

        local choice
        choice=$($DIALOG --title "$title" \
            --menu "Select an operation:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "overview"   "Client overview (all clients)" \
            "client"     "Inspect a specific client" \
            "sessions"   "Active SFTP sessions & locks" \
            "alerts"     "Stale backup alerts" \
            "storage"    "Storage breakdown" \
            "health"     "System health (SMB, SSH, fail2ban)" \
            "logs"       "View auth logs" \
            "users"      "User management" \
            "quit"       "Quit" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            overview) show_overview ;;
            client)   show_client_detail ;;
            sessions) show_active_sessions ;;
            alerts)   show_stale_alerts ;;
            storage)  show_storage ;;
            health)   show_system_health ;;
            logs)     show_auth_logs ;;
            users)    manage_users ;;
            quit|"")  break ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Entry point
# ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This tool must be run as root (use sudo)" >&2
    exit 1
fi

case "${1:-}" in
    --check-alerts)
        # Non-interactive mode for cron/monitoring
        # Returns exit code 1 if any alerts
        check_alerts_cli
        exit $?
        ;;
    --help|-h)
        cat <<'HELP'
computile-gateway-manager — TUI manager for the backup gateway

Usage:
  sudo computile-gateway-manager              # Interactive TUI
  sudo computile-gateway-manager --check-alerts  # Non-interactive alert check (for cron)

Interactive features:
  - Client overview: all clients, sizes, snapshot counts, last activity
  - Per-client detail: VPS directories, storage breakdown
  - Active SFTP sessions and restic locks
  - Stale backup alerting (configurable threshold)
  - Storage analysis per client
  - System health: SMB mount, SSH, fail2ban, Tailscale
  - User management: create, remove, view SSH keys
  - Auth log viewer

Non-interactive (--check-alerts):
  Prints alerts for stale/missing backups and exits with code 1
  if any alerts are found. Suitable for cron + email alerting.

Example cron entry:
  0 8 * * * /usr/local/bin/computile-gateway-manager --check-alerts || mail -s "Backup alerts" admin@example.com
HELP
        exit 0
        ;;
    --version)
        echo "computile-gateway-manager v$(cat /usr/local/lib/computile-backup/VERSION 2>/dev/null || echo 'dev')"
        exit 0
        ;;
    "")
        main_menu
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Run with --help for usage information" >&2
        exit 1
        ;;
esac
