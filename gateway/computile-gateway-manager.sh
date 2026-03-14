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

BACKUP_BASE="/srv/backups"
readonly GATEWAY_CONFIG="/etc/computile-backup/gateway.conf"

# Defaults (can be overridden by gateway.conf)
STALE_THRESHOLD_DAYS=2
DISK_WARN_PERCENT=85
DISK_CRITICAL_PERCENT=95
GATEWAY_HEALTHCHECK_URL=""
GATEWAY_WEBHOOK_URL=""
GATEWAY_WEBHOOK_HEADERS=()
MONITOR_RESTIC_CHECK="no"
MONITOR_AUTO_UNLOCK="no"
MONITOR_AUTO_UNLOCK_HOURS=4

# ──────────────────────────────────────────────
# Gateway config loading
# ──────────────────────────────────────────────
_load_gateway_config() {
    if [[ -f "$GATEWAY_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$GATEWAY_CONFIG" 2>/dev/null || true
    fi
}

_load_gateway_config
readonly BACKUP_BASE 2>/dev/null || true

# ──────────────────────────────────────────────
# Check dependencies
# ──────────────────────────────────────────────
check_dependencies() {
    local missing=()
    for cmd in tput du find stat date awk; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if ! command -v whiptail &>/dev/null && ! command -v dialog &>/dev/null; then
        missing+=("whiptail (or dialog)")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[ERROR] Missing required commands: ${missing[*]}" >&2
        echo "  Install them with: apt-get install ncurses-bin coreutils whiptail" >&2
        exit 1
    fi
}

check_dependencies

# Ensure TERM is set (LXC containers may not have it)
export TERM="${TERM:-linux}"

# Terminal dimensions
TERM_LINES=$(tput lines 2>/dev/null || echo 24)
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
WT_HEIGHT=$(( TERM_LINES - 4 ))
WT_WIDTH=$(( TERM_COLS - 10 ))
if [[ $WT_HEIGHT -gt 40 ]]; then WT_HEIGHT=40; fi
if [[ $WT_WIDTH -gt 100 ]]; then WT_WIDTH=100; fi
if [[ $WT_HEIGHT -lt 20 ]]; then WT_HEIGHT=20; fi
if [[ $WT_WIDTH -lt 60 ]]; then WT_WIDTH=60; fi
WT_LIST_HEIGHT=$(( WT_HEIGHT - 8 ))

# ──────────────────────────────────────────────
# Detect TUI backend
# ──────────────────────────────────────────────
DIALOG=""
if command -v whiptail &>/dev/null; then
    DIALOG="whiptail"
elif command -v dialog &>/dev/null; then
    DIALOG="dialog"
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

# Find the source git repo for this project
# Checks .source-repo, then common install paths
_find_source_repo() {
    local repo=""
    # 1. Saved path from setup_gateway.sh
    if [[ -f /usr/local/lib/computile-gateway/.source-repo ]]; then
        repo=$(head -1 /usr/local/lib/computile-gateway/.source-repo 2>/dev/null)
    fi
    # 2. Resolve relative paths (setup writes "SCRIPT_DIR/..")
    if [[ -n "$repo" ]] && [[ -d "$repo" ]]; then
        repo=$(cd "$repo" && pwd)
    fi
    # 3. Fallback: try common locations
    if [[ -z "$repo" ]] || [[ ! -d "$repo/.git" ]]; then
        for candidate in /srv/computile-backup-agent /opt/computile-backup-agent; do
            if [[ -d "$candidate/.git" ]]; then
                repo="$candidate"
                break
            fi
        done
    fi
    echo "$repo"
}

# ──────────────────────────────────────────────
# Data collection helpers
# ──────────────────────────────────────────────

# List all backup-* users (client IDs)
list_clients() {
    # Find backup-* directories in BACKUP_BASE
    for dir in "${BACKUP_BASE}"/backup-*; do
        [[ -d "$dir" ]] || continue
        basename "$dir"
    done
}

# Size cache: avoids repeated expensive du calls over SMB
# Cache lives in /tmp and is valid for SIZE_CACHE_TTL seconds
readonly SIZE_CACHE_DIR="/tmp/computile-gateway-cache"
readonly SIZE_CACHE_TTL=3600  # 1 hour

_init_size_cache() {
    mkdir -p "$SIZE_CACHE_DIR"
}

# Get cached size or compute it. Use get_size_cached for expensive paths.
_cache_key() {
    echo "$1" | md5sum | cut -d' ' -f1
}

get_size() {
    local path="$1"
    _init_size_cache
    local key
    key=$(_cache_key "$path")
    local cache_file="${SIZE_CACHE_DIR}/${key}"

    # Return cached value if fresh enough
    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c '%Y' "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt $SIZE_CACHE_TTL ]]; then
            head -1 "$cache_file"
            return
        fi
    fi

    # Compute and cache
    local size
    size=$(du -sh --max-depth=0 "$path" 2>/dev/null | cut -f1 || echo "N/A")
    echo "$size" > "$cache_file"
    echo "$size"
}

# Get disk usage in bytes for sorting (also cached)
get_size_bytes() {
    local path="$1"
    _init_size_cache
    local key
    key=$(_cache_key "${path}__bytes")
    local cache_file="${SIZE_CACHE_DIR}/${key}"

    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c '%Y' "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt $SIZE_CACHE_TTL ]]; then
            head -1 "$cache_file"
            return
        fi
    fi

    local size
    size=$(du -sb --max-depth=0 "$path" 2>/dev/null | cut -f1 || echo "0")
    echo "$size" > "$cache_file"
    echo "$size"
}

# Get last modification time — uses restic locks/snapshots dir mtime
# instead of expensive recursive find across SMB
get_last_activity() {
    local path="$1"
    local newest=0

    # Check mtime of key directories (fast — no recursion)
    for marker in "$path"/*/snapshots "$path"/*/locks "$path"/snapshots "$path"/locks; do
        if [[ -d "$marker" ]]; then
            local mtime
            mtime=$(stat -c '%Y' "$marker" 2>/dev/null) || continue
            if [[ $mtime -gt $newest ]]; then
                newest=$mtime
            fi
        fi
    done

    # Fallback: check the data dir itself
    if [[ $newest -eq 0 ]]; then
        newest=$(stat -c '%Y' "$path" 2>/dev/null || echo "0")
    fi

    if [[ $newest -gt 0 ]]; then
        date -d "@${newest}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "N/A"
    else
        echo "never"
    fi
}

# Get last modification timestamp (epoch) for staleness check
get_last_activity_epoch() {
    local path="$1"
    local newest=0

    for marker in "$path"/*/snapshots "$path"/*/locks "$path"/snapshots "$path"/locks; do
        if [[ -d "$marker" ]]; then
            local mtime
            mtime=$(stat -c '%Y' "$marker" 2>/dev/null) || continue
            if [[ $mtime -gt $newest ]]; then
                newest=$mtime
            fi
        fi
    done

    if [[ $newest -eq 0 ]]; then
        newest=$(stat -c '%Y' "$path" 2>/dev/null || echo "0")
    fi

    echo "$newest"
}

# Count restic snapshots by counting files in snapshots/ directory
# Uses ls instead of find for speed on SMB mounts
count_snapshots() {
    local data_dir="$1"
    local count=0
    for snapdir in "$data_dir"/*/snapshots "$data_dir"/snapshots; do
        if [[ -d "$snapdir" ]]; then
            local n
            n=$(ls -1 "$snapdir" 2>/dev/null | wc -l)
            count=$(( count + n ))
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
    output+="$(printf '%-24s  %-6s  %-18s  %s\n' 'CLIENT' 'SNAPS' 'LAST ACTIVITY' 'STATUS')\n"
    output+="$(printf '%0.s-' {1..70})\n"

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        ((total_clients++)) || true

        local client_dir="${BACKUP_BASE}/${client}"
        local data_dir="${client_dir}/data"

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
            ((stale_clients++)) || true
        elif [[ $(( now - last_epoch )) -gt $stale_secs ]]; then
            status="STALE"
            ((stale_clients++)) || true
        else
            ((active_clients++)) || true
        fi

        local display_name="${client#backup-}"

        output+="$(printf '%-24s  %-6s  %-18s  %s\n' "$display_name" "$snaps" "$last_activity" "$status")\n"
    done < <(list_clients)

    output+="\n"

    # Summary — use df for total mount usage (instant, no traversal)
    local mount_usage
    mount_usage=$(df -h "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {printf "%s used / %s total (%s)", $3, $2, $5}') || true
    output+="SUMMARY\n"
    output+="  Total clients:  ${total_clients}\n"
    output+="  Active:         ${active_clients}\n"
    output+="  Stale/empty:    ${stale_clients}\n"
    output+="  Storage:        ${mount_usage:-N/A}\n"

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
    # Build menu of clients (no du — use snapshot count for quick info)
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local data_dir="${BACKUP_BASE}/${client}/data"
        local snaps=0
        if [[ -d "$data_dir" ]]; then
            snaps=$(count_snapshots "$data_dir")
        fi
        clients+=("$display" "${snaps} snapshots")
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

    _show_client_detail_for "$choice"
}

# ──────────────────────────────────────────────
# Active SFTP sessions
# ──────────────────────────────────────────────
show_active_sessions() {
    local output=""
    output+="ACTIVE SFTP SESSIONS\n"
    output+="$(printf '%0.s-' {1..70})\n\n"

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
    local now_lock
    now_lock=$(date +%s)
    for client_dir in "${BACKUP_BASE}"/backup-*/data; do
        [[ -d "$client_dir" ]] || continue
        local client_name
        client_name=$(basename "$(dirname "$client_dir")")
        # Check known lock paths: data/locks/ and data/*/locks/
        for lockdir in "$client_dir"/locks "$client_dir"/*/locks; do
            [[ -d "$lockdir" ]] || continue
            for lock in "$lockdir"/*; do
                [[ -f "$lock" ]] || continue
                local lock_epoch
                lock_epoch=$(stat -c '%Y' "$lock" 2>/dev/null || echo "0")
                local age_mins=$(( (now_lock - lock_epoch) / 60 ))
                local stale_marker=""
                if [[ $age_mins -gt 60 ]]; then stale_marker=" [STALE - may be stuck]"; fi
                output+="  ${client_name}: $(basename "$lock") (${age_mins}min old)${stale_marker}\n"
                locks_found=true
            done
        done
    done
    if ! $locks_found; then
        output+="  No active locks.\n"
    fi

    msg_scroll "Active Sessions & Operations" "$(echo -e "$output")"

    # Offer to remove stale locks if any were found
    if $locks_found; then
        remove_stale_locks
    fi
}

# Remove stale restic lock files (older than 1 hour)
remove_stale_locks() {
    local stale_locks=()
    local stale_labels=()
    local now_rm
    now_rm=$(date +%s)

    for client_dir in "${BACKUP_BASE}"/backup-*/data; do
        [[ -d "$client_dir" ]] || continue
        local client_name
        client_name=$(basename "$(dirname "$client_dir")")
        for lockdir in "$client_dir"/locks "$client_dir"/*/locks; do
            [[ -d "$lockdir" ]] || continue
            for lock in "$lockdir"/*; do
                [[ -f "$lock" ]] || continue
                local lock_epoch
                lock_epoch=$(stat -c '%Y' "$lock" 2>/dev/null || echo "0")
                local age_mins=$(( (now_rm - lock_epoch) / 60 ))
                if [[ $age_mins -gt 60 ]]; then
                    stale_locks+=("$lock")
                    stale_labels+=("${client_name#backup-}: $(basename "$lock") (${age_mins}min)")
                fi
            done
        done
    done

    if [[ ${#stale_locks[@]} -eq 0 ]]; then
        return
    fi

    local detail=""
    for label in "${stale_labels[@]}"; do
        detail+="  ${label}\n"
    done

    if ! yesno "Stale Locks" "Found ${#stale_locks[@]} stale lock(s) (>1h old):\n\n${detail}\nRemove them?"; then
        return
    fi

    local removed=0
    local errors=0
    for lock in "${stale_locks[@]}"; do
        if rm -f "$lock" 2>/dev/null; then
            ((removed++)) || true
        else
            ((errors++)) || true
        fi
    done

    if [[ $errors -eq 0 ]]; then
        msg_box "Stale Locks" "Removed ${removed} stale lock(s)."
    else
        msg_box "Stale Locks" "Removed ${removed}, failed ${errors}. Check permissions."
    fi
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
    output+="$(printf '%0.s-' {1..70})\n\n"

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local data_dir="${BACKUP_BASE}/${client}/data"

        if [[ ! -d "$data_dir" ]]; then
            output+="  ALERT  ${display}: data directory missing\n"
            ((alerts++)) || true
            continue
        fi

        local last_epoch
        last_epoch=$(get_last_activity_epoch "$data_dir")

        if [[ -z "$last_epoch" ]] || [[ "$last_epoch" == "0" ]]; then
            output+="  ALERT  ${display}: no backup data found (never backed up?)\n"
            ((alerts++)) || true
            continue
        fi

        local age_secs=$(( now - last_epoch ))
        local age_days=$(( age_secs / 86400 ))
        local age_hours=$(( (age_secs % 86400) / 3600 ))
        local last_time
        last_time=$(date -d "@${last_epoch}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

        if [[ $age_secs -gt $(( stale_secs * 3 )) ]]; then
            output+="  ALERT  ${display}: last backup ${age_days}d ${age_hours}h ago (${last_time})\n"
            ((alerts++)) || true
        elif [[ $age_secs -gt $stale_secs ]]; then
            output+="  WARN   ${display}: last backup ${age_days}d ${age_hours}h ago (${last_time})\n"
            ((warnings++)) || true
        else
            output+="  OK     ${display}: last backup ${age_days}d ${age_hours}h ago (${last_time})\n"
        fi
    done < <(list_clients)

    output+="\n$(printf '%0.s-' {1..70})\n"
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

    # Gateway SSH key (for restore test)
    output+="GATEWAY SSH KEY (for restore test)\n"
    local _gw_key_found=false
    for _gw_kf in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ecdsa.pub; do
        if [[ -f "$_gw_kf" ]]; then
            local _gw_key
            _gw_key=$(cat "$_gw_kf")
            local _gw_fp
            _gw_fp=$(ssh-keygen -lf "$_gw_kf" 2>/dev/null | awk '{print $1, $2, $NF}') || _gw_fp="N/A"
            output+="  File: ${_gw_kf}\n"
            output+="  Fingerprint: ${_gw_fp}\n"
            output+="  Public key:\n"
            output+="  ${_gw_key}\n"
            _gw_key_found=true
            break
        fi
    done
    if [[ "$_gw_key_found" != true ]]; then
        output+="  No SSH key found. Run setup_gateway.sh --update to generate one.\n"
    fi
    output+="\n"

    # System uptime & load
    output+="SYSTEM\n"
    output+="  $(uptime 2>/dev/null || echo 'N/A')\n"

    msg_scroll "System Health" "$(echo -e "$output")"

    # Offer to remount SMB if not mounted
    if ! mountpoint -q "$BACKUP_BASE" 2>/dev/null && [[ -d "$BACKUP_BASE" ]]; then
        if yesno "SMB Not Mounted" "The backup storage at ${BACKUP_BASE} is not mounted.\n\nAttempt to mount it now?"; then
            _remount_smb
        fi
    fi
}

_remount_smb() {
    local mount_output
    mount_output=$(mount "$BACKUP_BASE" 2>&1)
    local rc=$?

    if [[ $rc -eq 0 ]]; then
        local disk_info
        disk_info=$(df -h "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {printf "%s used / %s total (%s available)", $3, $2, $4}') || true
        msg_box "SMB Mount" "Successfully mounted ${BACKUP_BASE}\n\n${disk_info}"
    else
        msg_box "SMB Mount Failed" "Could not mount ${BACKUP_BASE}:\n\n${mount_output}\n\nCheck /etc/fstab and SMB credentials."
    fi
}

# ──────────────────────────────────────────────
# Fail2ban management
# ──────────────────────────────────────────────
manage_fail2ban() {
    while true; do
        # Get current status
        local banned_count=0
        local banned_list=""
        if systemctl is-active fail2ban &>/dev/null; then
            banned_count=$(fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print $NF}') || true
            banned_list=$(fail2ban-client status sshd 2>/dev/null | grep 'Banned IP list' | sed 's/.*Banned IP list:\s*//') || true
        else
            msg_box "Fail2ban" "fail2ban is not running."
            return
        fi

        local choice
        choice=$($DIALOG --title "Fail2ban — ${banned_count:-0} banned IP(s)" \
            --menu "Manage banned IPs:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "status"    "📊  View fail2ban status" \
            "unban"     "🔓  Unban a specific IP" \
            "unban-all" "🔓  Unban ALL IPs" \
            "back"      "↩  Back to main menu" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            status)    _f2b_status ;;
            unban)     _f2b_unban_ip ;;
            unban-all) _f2b_unban_all ;;
            back|"")   break ;;
        esac
    done
}

_f2b_status() {
    local output=""
    output+="FAIL2BAN STATUS\n"
    output+="$(printf '%0.s-' {1..70})\n\n"

    local f2b_status
    f2b_status=$(fail2ban-client status sshd 2>&1) || true
    output+="${f2b_status}\n\n"

    # Show banned IP details
    local banned_list
    banned_list=$(fail2ban-client status sshd 2>/dev/null | grep 'Banned IP list' | sed 's/.*Banned IP list:\s*//') || true

    if [[ -n "$banned_list" ]]; then
        output+="BANNED IPS\n"
        output+="$(printf '%0.s-' {1..70})\n"
        for ip in $banned_list; do
            # Try to get whois/reverse DNS info
            local hostname
            hostname=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}') || hostname=""
            if [[ -n "$hostname" ]]; then
                output+="  ${ip}  (${hostname})\n"
            else
                output+="  ${ip}\n"
            fi
        done
    else
        output+="No IPs currently banned.\n"
    fi

    msg_scroll "Fail2ban Status" "$(echo -e "$output")"
}

_f2b_unban_ip() {
    local banned_list
    banned_list=$(fail2ban-client status sshd 2>/dev/null | grep 'Banned IP list' | sed 's/.*Banned IP list:\s*//') || true

    if [[ -z "$banned_list" ]]; then
        msg_box "Unban IP" "No IPs currently banned."
        return
    fi

    # Build menu of banned IPs
    local ips=()
    for ip in $banned_list; do
        local hostname
        hostname=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}') || hostname="unknown"
        ips+=("$ip" "$hostname")
    done

    local choice
    choice=$($DIALOG --title "Unban IP" \
        --menu "Select IP to unban:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${ips[@]}" \
        3>&1 1>&2 2>&3) || return

    if fail2ban-client set sshd unbanip "$choice" &>/dev/null; then
        msg_box "Unban IP" "Successfully unbanned: ${choice}"
    else
        msg_box "Unban IP" "Failed to unban ${choice}. Check fail2ban logs."
    fi
}

_f2b_unban_all() {
    local banned_list
    banned_list=$(fail2ban-client status sshd 2>/dev/null | grep 'Banned IP list' | sed 's/.*Banned IP list:\s*//') || true

    if [[ -z "$banned_list" ]]; then
        msg_box "Unban All" "No IPs currently banned."
        return
    fi

    local count=0
    for ip in $banned_list; do
        ((count++)) || true
    done

    if ! yesno "Unban All" "Unban all ${count} banned IP(s)?\n\n${banned_list}"; then
        return
    fi

    local errors=0
    for ip in $banned_list; do
        if ! fail2ban-client set sshd unbanip "$ip" &>/dev/null; then
            ((errors++)) || true
        fi
    done

    if [[ $errors -eq 0 ]]; then
        msg_box "Unban All" "Successfully unbanned ${count} IP(s)."
    else
        msg_box "Unban All" "Unbanned with ${errors} error(s). Check fail2ban logs."
    fi
}

# ──────────────────────────────────────────────
# User management
# ──────────────────────────────────────────────
manage_users() {
    while true; do
        local choice
        choice=$($DIALOG --title "User Management" \
            --menu "Manage backup users:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "list"      "📋  List all backup users" \
            "create"    "➕  Create new backup user" \
            "remove"    "🗑  Remove backup user" \
            "keys"      "🔑  View SSH keys for a user" \
            "addkey"    "🔑  Add SSH key to a user" \
            "removekey" "🗑  Remove SSH key from a user" \
            "back"      "↩  Back to main menu" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            list)      show_user_list ;;
            create)    create_user_interactive ;;
            remove)    remove_user_interactive ;;
            keys)      show_user_keys ;;
            addkey)    add_user_key ;;
            removekey) remove_user_key ;;
            back|"")   break ;;
        esac
    done
}

show_user_list() {
    local output=""
    output+="BACKUP USERS\n"
    output+="$(printf '%-20s  %-12s  %-8s  %s\n' 'USERNAME' 'CLIENT ID' 'KEYS' 'DIRECTORY')\n"
    output+="$(printf '%0.s-' {1..70})\n"

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
            local src_repo
            src_repo=$(_find_source_repo)
            [[ -n "$src_repo" ]] && create_script="${src_repo}/gateway/create_backup_user.sh"
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
    if [[ -n "$vps_id" ]]; then args+=("--vps" "$vps_id"); fi

    clear
    echo "================================================"
    echo "  Creating backup user..."
    echo "================================================"
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
            local src_repo
            src_repo=$(_find_source_repo)
            [[ -n "$src_repo" ]] && remove_script="${src_repo}/gateway/remove_backup_user.sh"
        fi
    fi

    if [[ ! -f "$remove_script" ]] && ! command -v "$remove_script" &>/dev/null; then
        msg_box "Error" "Cannot find remove_backup_user script"
        return
    fi

    # Build list of clients for selection (no du for speed)
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        clients+=("$display" "${BACKUP_BASE}/${client}")
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
    echo "================================================"
    echo "  Removing backup user: backup-${choice}"
    echo "================================================"
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
    output+="$(printf '%0.s-' {1..60})\n\n"

    if [[ -f "$auth_keys" ]]; then
        local idx=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            ((idx++)) || true
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

add_user_key() {
    # Select client
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        clients+=("$display" "")
    done < <(list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_box "Add SSH Key" "No backup users found."
        return
    fi

    local choice
    choice=$($DIALOG --title "Add SSH Key" \
        --menu "Select client:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return

    local username="backup-${choice}"
    local ssh_dir="${BACKUP_BASE}/${username}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    # Get the public key — either paste or file path
    local method
    method=$($DIALOG --title "Add SSH Key" \
        --menu "How to provide the key?" 10 $WT_WIDTH 3 \
        "paste" "Paste the public key" \
        "file"  "Read from a file path" \
        3>&1 1>&2 2>&3) || return

    local pubkey=""
    case "$method" in
        paste)
            pubkey=$($DIALOG --title "Add SSH Key" \
                --inputbox "Paste the full public key (ssh-ed25519 ... or ssh-rsa ...):" 10 $WT_WIDTH \
                3>&1 1>&2 2>&3) || return
            ;;
        file)
            local keyfile
            keyfile=$($DIALOG --title "Add SSH Key" \
                --inputbox "Path to public key file:" 10 $WT_WIDTH "/tmp/id_ed25519.pub" \
                3>&1 1>&2 2>&3) || return
            if [[ ! -f "$keyfile" ]]; then
                msg_box "Error" "File not found: ${keyfile}"
                return
            fi
            pubkey=$(cat "$keyfile")
            ;;
    esac

    if [[ -z "$pubkey" ]]; then
        msg_box "Error" "No key provided."
        return
    fi

    # Strip newlines and validate using ssh-keygen
    pubkey=$(echo "$pubkey" | tr -d '\n\r')
    if ! echo "$pubkey" | ssh-keygen -l -f /dev/stdin &>/dev/null; then
        msg_box "Error" "Invalid SSH public key format.\nKey must be a valid OpenSSH public key (ssh-rsa, ssh-ed25519, ecdsa-sha2, etc.)"
        return
    fi

    # Check for duplicates
    if [[ -f "$auth_keys" ]] && grep -qF "$pubkey" "$auth_keys" 2>/dev/null; then
        msg_box "Add SSH Key" "This key is already authorized for ${username}."
        return
    fi

    # Ensure .ssh directory exists with correct permissions
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"
    chown "${username}:backupusers" "$ssh_dir"
    touch "$auth_keys"
    chmod 600 "$auth_keys"
    chown "${username}:backupusers" "$auth_keys"

    # Add the key
    echo "$pubkey" >> "$auth_keys"
    msg_box "Add SSH Key" "Key added successfully for ${username}.\n\nFingerprint: $(echo "$pubkey" | ssh-keygen -lf /dev/stdin 2>/dev/null || echo 'N/A')"
}

remove_user_key() {
    # Select client
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local auth_keys="${BACKUP_BASE}/${client}/.ssh/authorized_keys"
        local key_count=0
        if [[ -f "$auth_keys" ]]; then
            key_count=$(grep -c '^ssh-' "$auth_keys" 2>/dev/null || echo "0")
        fi
        if [[ $key_count -gt 0 ]]; then
            clients+=("$display" "${key_count} key(s)")
        fi
    done < <(list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_box "Remove SSH Key" "No clients with SSH keys found."
        return
    fi

    local choice
    choice=$($DIALOG --title "Remove SSH Key" \
        --menu "Select client:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return

    local username="backup-${choice}"
    local auth_keys="${BACKUP_BASE}/${username}/.ssh/authorized_keys"

    if [[ ! -f "$auth_keys" ]]; then
        msg_box "Remove SSH Key" "No authorized_keys file for ${username}."
        return
    fi

    # Build menu of keys with fingerprint and comment
    local keys=()
    local key_lines=()
    local idx=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        [[ ! "$line" =~ ^(ssh-|ecdsa-) ]] && continue
        ((idx++)) || true
        local key_type
        key_type=$(echo "$line" | awk '{print $1}')
        local key_comment
        key_comment=$(echo "$line" | awk '{print $NF}')
        local key_hash
        key_hash=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}') || key_hash="N/A"
        keys+=("${idx}" "${key_type} ${key_hash} (${key_comment})")
        key_lines+=("$line")
    done < "$auth_keys"

    if [[ ${#keys[@]} -eq 0 ]]; then
        msg_box "Remove SSH Key" "No SSH keys found for ${username}."
        return
    fi

    local key_choice
    key_choice=$($DIALOG --title "Remove SSH Key — ${username}" \
        --menu "Select key to remove:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${keys[@]}" \
        3>&1 1>&2 2>&3) || return

    # key_choice is 1-based index
    local key_idx=$(( key_choice - 1 ))
    local selected_key="${key_lines[$key_idx]}"
    local selected_info="${keys[$(( key_choice * 2 - 1 ))]}"

    if ! yesno "Confirm Removal" "Remove this key from ${username}?\n\n${selected_info}"; then
        return
    fi

    # Remove the key line from authorized_keys
    local tmpfile
    tmpfile=$(mktemp)
    grep -vF "$selected_key" "$auth_keys" > "$tmpfile" 2>/dev/null || true
    cp "$tmpfile" "$auth_keys"
    rm -f "$tmpfile"
    chmod 600 "$auth_keys"
    chown "${username}:backupusers" "$auth_keys"

    msg_box "Remove SSH Key" "Key removed successfully from ${username}."
}

# ──────────────────────────────────────────────
# Tailscale peers overview
# ──────────────────────────────────────────────
show_tailscale_peers() {
    local output=""
    output+="TAILSCALE PEERS\n"
    output+="$(printf '%0.s-' {1..70})\n\n"

    if ! command -v tailscale &>/dev/null; then
        output+="Tailscale is not installed on this gateway.\n"
        msg_scroll "Tailscale Peers" "$(echo -e "$output")"
        return
    fi

    local ts_self
    ts_self=$(tailscale status --self 2>/dev/null | head -1) || ts_self=""
    if [[ -n "$ts_self" ]]; then
        output+="THIS NODE\n"
        output+="  ${ts_self}\n\n"
    fi

    local ts_status
    ts_status=$(tailscale status 2>/dev/null) || true

    if [[ -z "$ts_status" ]]; then
        output+="Cannot retrieve Tailscale status. Is Tailscale running?\n"
        msg_scroll "Tailscale Peers" "$(echo -e "$output")"
        return
    fi

    local online=0
    local offline=0
    local total=0

    output+="$(printf '%-20s  %-16s  %-10s  %-10s  %s\n' 'HOSTNAME' 'IP' 'OS' 'STATUS' 'RELAY')\n"
    output+="$(printf '%0.s-' {1..70})\n"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Skip header line if present
        [[ "$line" == *"#"* ]] && continue
        # tailscale status format: IP hostname user OS ... idle/active/offline ...
        local ip hostname os status_field
        ip=$(echo "$line" | awk '{print $1}')
        hostname=$(echo "$line" | awk '{print $2}')
        os=$(echo "$line" | awk '{print $5}')
        # Check for relay info and online/offline
        local relay="-"
        local peer_status="online"
        if echo "$line" | grep -q 'offline'; then
            peer_status="offline"
            ((offline++)) || true
        else
            ((online++)) || true
            # Check for relay (DERP) vs direct
            if echo "$line" | grep -q 'relay'; then
                relay=$(echo "$line" | grep -oP 'relay "\K[^"]+' 2>/dev/null) || relay="relayed"
            elif echo "$line" | grep -q 'direct'; then
                relay="direct"
            fi
        fi
        ((total++)) || true

        output+="$(printf '%-20s  %-16s  %-10s  %-10s  %s\n' "$hostname" "$ip" "$os" "$peer_status" "$relay")\n"
    done <<< "$ts_status"

    output+="\n$(printf '%0.s-' {1..70})\n"
    output+="Total: ${total} peers (${online} online, ${offline} offline)\n"

    msg_scroll "Tailscale Peers" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# SFTP connectivity test per client
# ──────────────────────────────────────────────
test_sftp_client() {
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local auth_keys="${BACKUP_BASE}/${client}/.ssh/authorized_keys"
        local key_count=0
        if [[ -f "$auth_keys" ]]; then
            key_count=$(grep -c '^ssh-' "$auth_keys" 2>/dev/null || echo "0")
        fi
        clients+=("$display" "${key_count} key(s)")
    done < <(list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_box "SFTP Test" "No backup clients found."
        return
    fi

    local choice
    choice=$($DIALOG --title "SFTP Test" \
        --menu "Select client to test:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return

    local username="backup-${choice}"
    local client_dir="${BACKUP_BASE}/${username}"
    local output=""
    output+="SFTP CONNECTIVITY TEST: ${username}\n"
    output+="$(printf '%0.s-' {1..60})\n\n"

    # Check 1: User exists
    if id "$username" &>/dev/null; then
        output+="  [OK]    User '${username}' exists\n"
        local user_groups
        user_groups=$(id -nG "$username" 2>/dev/null)
        output+="          Groups: ${user_groups}\n"
    else
        output+="  [FAIL]  User '${username}' does not exist\n"
        msg_scroll "SFTP Test: ${choice}" "$(echo -e "$output")"
        return
    fi

    # Check 2: Home directory
    if [[ -d "$client_dir" ]]; then
        output+="  [OK]    Home directory exists: ${client_dir}\n"
        local dir_perms
        dir_perms=$(stat -c '%a %U:%G' "$client_dir" 2>/dev/null || echo "?")
        output+="          Permissions: ${dir_perms}\n"
    else
        output+="  [FAIL]  Home directory missing: ${client_dir}\n"
    fi

    # Check 3: SSH keys
    local auth_keys="${client_dir}/.ssh/authorized_keys"
    if [[ -f "$auth_keys" ]]; then
        local key_count
        key_count=$(grep -c '^ssh-' "$auth_keys" 2>/dev/null || echo "0")
        output+="  [OK]    authorized_keys: ${key_count} key(s)\n"
        local key_perms
        key_perms=$(stat -c '%a %U:%G' "$auth_keys" 2>/dev/null || echo "?")
        output+="          Permissions: ${key_perms}\n"
        # Warn if permissions are wrong
        local key_mode
        key_mode=$(stat -c '%a' "$auth_keys" 2>/dev/null || echo "000")
        if [[ "$key_mode" != "600" ]]; then
            output+="  [WARN]  authorized_keys should be 600, is ${key_mode}\n"
        fi
    else
        output+="  [FAIL]  No authorized_keys file\n"
    fi

    # Check 4: .ssh directory permissions
    local ssh_dir="${client_dir}/.ssh"
    if [[ -d "$ssh_dir" ]]; then
        local ssh_perms
        ssh_perms=$(stat -c '%a' "$ssh_dir" 2>/dev/null || echo "000")
        if [[ "$ssh_perms" == "700" ]]; then
            output+="  [OK]    .ssh directory permissions: ${ssh_perms}\n"
        else
            output+="  [WARN]  .ssh directory should be 700, is ${ssh_perms}\n"
        fi
    fi

    # Check 5: Data directory
    local data_dir="${client_dir}/data"
    if [[ -d "$data_dir" ]]; then
        output+="  [OK]    Data directory exists\n"
        local data_perms
        data_perms=$(stat -c '%a %U:%G' "$data_dir" 2>/dev/null || echo "?")
        output+="          Permissions: ${data_perms}\n"
    else
        output+="  [WARN]  Data directory missing (will be created on first backup)\n"
    fi

    # Check 6: SSHD config allows this user
    output+="\n"
    output+="SSHD CONFIG\n"
    if [[ -f /etc/ssh/sshd_config.d/computile-backup.conf ]]; then
        output+="  [OK]    computile-backup.conf present\n"
        if grep -q 'ForceCommand internal-sftp' /etc/ssh/sshd_config.d/computile-backup.conf 2>/dev/null; then
            output+="  [OK]    ForceCommand internal-sftp configured\n"
        else
            output+="  [WARN]  ForceCommand internal-sftp not found in config\n"
        fi
    else
        output+="  [WARN]  No computile-backup.conf in sshd_config.d/\n"
    fi

    # Check 7: Actual SFTP test (connect as the user via localhost)
    output+="\n"
    output+="SFTP CONNECTION TEST\n"
    # We can't do a real SFTP test as root without the user's private key,
    # but we can verify the chroot setup and that sshd would accept the user
    if getent group backupusers | grep -qw "$username" 2>/dev/null; then
        output+="  [OK]    User is member of 'backupusers' group\n"
    else
        output+="  [FAIL]  User NOT in 'backupusers' group (SFTP will be rejected)\n"
    fi

    # Check chroot ownership (sshd requires root:root for ChrootDirectory)
    local chroot_owner
    chroot_owner=$(stat -c '%U:%G' "$client_dir" 2>/dev/null || echo "?:?")
    if [[ "$chroot_owner" == "root:root" ]] || [[ "$chroot_owner" == "root:backupusers" ]]; then
        output+="  [OK]    Chroot directory owner: ${chroot_owner}\n"
    else
        output+="  [WARN]  Chroot directory owner is ${chroot_owner} (sshd may require root ownership)\n"
    fi

    msg_scroll "SFTP Test: ${choice}" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Client search
# ──────────────────────────────────────────────
search_client() {
    local query
    query=$($DIALOG --title "Search Client" \
        --inputbox "Enter search term (partial name):" 10 $WT_WIDTH \
        3>&1 1>&2 2>&3) || return

    [[ -z "$query" ]] && return

    # Find matching clients
    local matches=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        # Case-insensitive match
        if echo "$display" | grep -qi "$query" 2>/dev/null; then
            local data_dir="${BACKUP_BASE}/${client}/data"
            local snaps=0
            if [[ -d "$data_dir" ]]; then
                snaps=$(count_snapshots "$data_dir")
            fi
            matches+=("$display" "${snaps} snapshots")
        fi
    done < <(list_clients)

    if [[ ${#matches[@]} -eq 0 ]]; then
        msg_box "Search" "No clients matching '${query}'."
        return
    fi

    # If only one match, go directly to detail
    if [[ ${#matches[@]} -eq 2 ]]; then
        _show_client_detail_for "${matches[0]}"
        return
    fi

    local choice
    choice=$($DIALOG --title "Search Results: '${query}'" \
        --menu "Select a client:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${matches[@]}" \
        3>&1 1>&2 2>&3) || return

    _show_client_detail_for "$choice"
}

# Show detail for a specific client (reusable from search and detail view)
_show_client_detail_for() {
    local choice="$1"
    local username="backup-${choice}"
    local client_dir="${BACKUP_BASE}/${username}"
    local data_dir="${client_dir}/data"

    local output=""
    output+="CLIENT: ${choice}\n"
    output+="$(printf '%0.s-' {1..60})\n"
    output+="  User:      ${username}\n"
    output+="  Directory: ${client_dir}\n"
    output+="  Total size: $(get_size "$client_dir") (cached up to 1h)\n"
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
            output+="REPOSITORY (direct)\n"
            local snaps
            snaps=$(count_snapshots "$data_dir")
            output+="  Snapshots: ${snaps}\n"
            output+="  Size:      $(get_size "$data_dir")\n"
            output+="  Last mod:  $(get_last_activity "$data_dir")\n"
        else
            output+="VPS DIRECTORIES\n"
            output+="$(printf '  %-20s  %-8s  %-6s  %s\n' 'VPS' 'SIZE' 'SNAPS' 'LAST ACTIVITY')\n"
            output+="  $(printf '%0.s-' {1..64})\n"

            local vps_found=false
            for vps_path in "$data_dir"/*/; do
                [[ -d "$vps_path" ]] || continue
                local vps_name
                vps_name=$(basename "$vps_path")
                [[ "$vps_name" == "_meta" ]] && continue

                local vps_size
                vps_size=$(get_size "$vps_path")
                local vps_snaps
                vps_snaps=$(count_snapshots "$vps_path")
                if [[ $vps_snaps -eq 0 ]] && is_restic_repo "$vps_path"; then
                    vps_snaps=$(ls -1 "$vps_path/snapshots" 2>/dev/null | wc -l)
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
            if [[ -f "$vps_meta/restic-password" ]]; then has_password="yes"; fi
            if [[ -f "$vps_meta/backup-agent.conf" ]]; then has_config="yes"; fi
            if [[ -f "$vps_meta/ssh-public-key.pub" ]]; then has_key="yes"; fi
            local meta_age
            meta_age=$(get_last_activity "$vps_meta")
            output+="  ${vps_id}: password=${has_password} config=${has_config} ssh-key=${has_key} (updated: ${meta_age})\n"
        done
    else
        output+="  No recovery metadata synced yet.\n"
        output+="  (VPS agents v1.5.1+ sync automatically after each backup)\n"
    fi

    msg_scroll "Client: ${choice}" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Storage breakdown
# ──────────────────────────────────────────────
show_storage() {
    local output=""

    output+="STORAGE OVERVIEW\n"
    output+="$(printf '%0.s-' {1..70})\n\n"

    # Overall
    if mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        output+="MOUNT: ${BACKUP_BASE} (SMB)\n"
    else
        output+="DIRECTORY: ${BACKUP_BASE} (local)\n"
    fi
    output+="$(df -h "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {printf "  Total: %s  Used: %s  Available: %s  Usage: %s", $2, $3, $4, $5}')\n\n"

    # Check cache freshness
    local cache_info="(not cached yet)"
    if [[ -d "$SIZE_CACHE_DIR" ]]; then
        local newest_cache
        newest_cache=$(stat -c '%Y' "$SIZE_CACHE_DIR"/* 2>/dev/null | sort -rn | head -1) || true
        if [[ -n "$newest_cache" ]]; then
            local cache_age_mins=$(( ($(date +%s) - newest_cache) / 60 ))
            cache_info="(cached ${cache_age_mins}min ago)"
        fi
    fi

    # Per-client breakdown sorted by size
    output+="PER-CLIENT USAGE ${cache_info}\n"
    output+="$(printf '  %-24s  %s\n' 'CLIENT' 'SIZE')\n"
    output+="  $(printf '%0.s-' {1..40})\n"

    # Collect sizes and sort
    local tmpfile
    tmpfile=$(mktemp)
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local size_bytes
        size_bytes=$(get_size_bytes "${BACKUP_BASE}/${client}")
        local size_human
        size_human=$(get_size "${BACKUP_BASE}/${client}")
        printf '%s %s %s\n' "$size_bytes" "$client" "$size_human" >> "$tmpfile"
    done < <(list_clients)

    # Read sorted output (avoid subshell variable loss)
    while IFS=' ' read -r _ client size; do
        local display="${client#backup-}"
        output+="$(printf '  %-24s  %s\n' "$display" "$size")\n"
    done < <(sort -rn "$tmpfile")
    rm -f "$tmpfile"

    msg_scroll "Storage" "$(echo -e "$output")"
}

_clear_size_cache() {
    rm -rf "${SIZE_CACHE_DIR:?}"/*
    msg_box "Cache" "Size cache cleared. Next storage view will recompute all sizes."
}

# ──────────────────────────────────────────────
# Self-update
# ──────────────────────────────────────────────
self_update() {
    # Find the source repo
    local source_repo
    source_repo=$(_find_source_repo)

    if [[ ! -d "$source_repo/.git" ]]; then
        msg_box "Update" "Cannot find source repository.\n\nExpected at: ${source_repo}\n\nClone the repo first:\n  git clone https://github.com/computile-be/computile-backup-agent.git ${source_repo}"
        return
    fi

    local installed_version
    installed_version=$(cat /usr/local/lib/computile-gateway/VERSION 2>/dev/null || echo "unknown")

    # Check for updates
    clear
    echo "================================================"
    echo "  Checking for updates..."
    echo "================================================"
    echo
    echo "Source repo: ${source_repo}"
    echo "Installed:   v${installed_version}"
    echo

    cd "$source_repo" || {
        msg_box "Update" "Cannot access source repo: ${source_repo}"
        return
    }

    # Fetch latest
    echo "Fetching latest changes..."
    if ! git fetch origin 2>&1; then
        echo
        echo "[ERROR] git fetch failed. Check network connectivity."
        echo "Press Enter to continue."
        read -r
        return
    fi

    # Check if there are updates
    local local_head
    local_head=$(git rev-parse HEAD 2>/dev/null)
    local remote_head
    remote_head=$(git rev-parse origin/master 2>/dev/null || git rev-parse origin/main 2>/dev/null) || true

    if [[ "$local_head" == "$remote_head" ]]; then
        # Repo is up to date, but check if installed scripts match repo version
        local repo_version
        repo_version=$(head -1 VERSION 2>/dev/null || echo "unknown")
        if [[ "$installed_version" != "$repo_version" ]]; then
            echo
            echo "Repo is current but installed scripts are outdated (v${installed_version} vs v${repo_version})."
            echo "Reinstalling..."
            echo
            if bash gateway/setup_gateway.sh --update --force; then
                echo
                echo "================================================"
                echo "  Update complete: v${installed_version} -> v${repo_version}"
                echo "  The manager will restart with the new version."
                echo "================================================"
            else
                echo
                echo "[WARN] Update script returned an error. Check output above."
            fi
            echo "Press Enter to continue."
            read -r
            return
        fi
        echo
        echo "Already up to date (v${repo_version})."
        echo "Press Enter to continue."
        read -r
        return
    fi

    # Show what changed
    echo
    echo "Changes available:"
    git log --oneline "${local_head}..${remote_head}" 2>/dev/null | head -20
    echo

    echo "Pulling changes..."
    if ! git pull origin master 2>&1 && ! git pull origin main 2>&1; then
        echo
        echo "[ERROR] git pull failed."
        echo "Press Enter to continue."
        read -r
        return
    fi

    local new_version
    new_version=$(head -1 VERSION 2>/dev/null || echo "unknown")
    echo
    echo "Repo updated: v${installed_version} -> v${new_version}"
    echo

    # Run the update script
    echo "Running setup_gateway.sh --update..."
    echo
    if bash gateway/setup_gateway.sh --update --force; then
        echo
        echo "================================================"
        echo "  Update complete: v${installed_version} -> v${new_version}"
        echo "  The manager will restart with the new version."
        echo "================================================"
    else
        echo
        echo "[WARN] Update script returned an error. Check output above."
    fi
    echo
    echo "Press Enter to continue."
    read -r

    # Re-exec the new version of the manager
    exec computile-gateway-manager
}

# ──────────────────────────────────────────────
# Report export (non-interactive)
# ──────────────────────────────────────────────
generate_report() {
    local format="${1:-text}"
    local now
    now=$(date +%s)
    local now_human
    now_human=$(date '+%Y-%m-%d %H:%M:%S')
    local stale_secs=$(( STALE_THRESHOLD_DAYS * 86400 ))
    local version
    version=$(cat /usr/local/lib/computile-gateway/VERSION 2>/dev/null || echo "dev")

    if [[ "$format" == "json" ]]; then
        _generate_report_json "$now" "$stale_secs" "$now_human" "$version"
    else
        _generate_report_text "$now" "$stale_secs" "$now_human" "$version"
    fi
}

_generate_report_text() {
    local now="$1" stale_secs="$2" now_human="$3" version="$4"

    echo "=============================================="
    echo "  COMPUTILE BACKUP GATEWAY - HEALTH REPORT"
    echo "=============================================="
    echo "Generated: ${now_human}"
    echo "Gateway version: v${version}"
    echo

    # System health summary
    echo "SYSTEM HEALTH"
    echo "----------------------------------------------"

    # SMB mount
    if mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        echo "  SMB Mount:    OK (mounted at ${BACKUP_BASE})"
        df -h "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {printf "  Storage:      %s used / %s total (%s available)\n", $3, $2, $4}'
    else
        echo "  SMB Mount:    FAIL (not mounted)"
    fi

    # SSH
    if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then
        echo "  SSH Service:  OK"
    else
        echo "  SSH Service:  FAIL (not running)"
    fi

    # fail2ban
    if systemctl is-active fail2ban &>/dev/null; then
        local banned
        banned=$(fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print $NF}') || banned="?"
        echo "  Fail2ban:     OK (${banned} banned IPs)"
    else
        echo "  Fail2ban:     FAIL (not running)"
    fi

    # Tailscale
    if command -v tailscale &>/dev/null; then
        local ts_self
        ts_self=$(tailscale status --self 2>/dev/null | awk '{print $1}') || ts_self="?"
        local ts_peers
        ts_peers=$(tailscale status 2>/dev/null | wc -l) || ts_peers="?"
        echo "  Tailscale:    OK (${ts_self}, ${ts_peers} peers)"
    else
        echo "  Tailscale:    N/A (not installed)"
    fi

    echo

    # Client overview
    echo "CLIENT STATUS"
    echo "----------------------------------------------"
    printf "  %-24s  %-6s  %-18s  %s\n" "CLIENT" "SNAPS" "LAST ACTIVITY" "STATUS"
    printf "  %-24s  %-6s  %-18s  %s\n" "------------------------" "------" "------------------" "------"

    local total_clients=0
    local stale_clients=0
    local active_clients=0
    local alert_details=""

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        ((total_clients++)) || true

        local display="${client#backup-}"
        local data_dir="${BACKUP_BASE}/${client}/data"
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
            ((stale_clients++)) || true
            alert_details+="  ALERT: ${display} - no backup data\n"
        elif [[ $(( now - last_epoch )) -gt $(( stale_secs * 3 )) ]]; then
            local age_days=$(( (now - last_epoch) / 86400 ))
            status="ALERT"
            ((stale_clients++)) || true
            alert_details+="  ALERT: ${display} - last backup ${age_days}d ago\n"
        elif [[ $(( now - last_epoch )) -gt $stale_secs ]]; then
            local age_days=$(( (now - last_epoch) / 86400 ))
            status="STALE"
            ((stale_clients++)) || true
            alert_details+="  WARN:  ${display} - last backup ${age_days}d ago\n"
        else
            ((active_clients++)) || true
        fi

        printf "  %-24s  %-6s  %-18s  %s\n" "$display" "$snaps" "$last_activity" "$status"
    done < <(list_clients)

    echo
    echo "SUMMARY"
    echo "----------------------------------------------"
    echo "  Total clients:  ${total_clients}"
    echo "  Active:         ${active_clients}"
    echo "  Stale/alert:    ${stale_clients}"

    if [[ -n "$alert_details" ]]; then
        echo
        echo "ALERTS"
        echo "----------------------------------------------"
        echo -e "$alert_details"
    fi

    # Active locks
    local locks_output=""
    for client_dir in "${BACKUP_BASE}"/backup-*/data; do
        [[ -d "$client_dir" ]] || continue
        local client_name
        client_name=$(basename "$(dirname "$client_dir")")
        for lockdir in "$client_dir"/locks "$client_dir"/*/locks; do
            [[ -d "$lockdir" ]] || continue
            for lock in "$lockdir"/*; do
                [[ -f "$lock" ]] || continue
                local lock_epoch
                lock_epoch=$(stat -c '%Y' "$lock" 2>/dev/null || echo "0")
                local age_mins=$(( (now - lock_epoch) / 60 ))
                local stale_marker=""
                if [[ $age_mins -gt 60 ]]; then stale_marker=" [STALE]"; fi
                locks_output+="  ${client_name#backup-}: $(basename "$lock") (${age_mins}min)${stale_marker}\n"
            done
        done
    done

    if [[ -n "$locks_output" ]]; then
        echo "ACTIVE LOCKS"
        echo "----------------------------------------------"
        echo -e "$locks_output"
    fi

    echo "=============================================="
}

_generate_report_json() {
    local now="$1" stale_secs="$2" now_human="$3" version="$4"

    local smb_ok="false"
    if mountpoint -q "$BACKUP_BASE" 2>/dev/null; then smb_ok="true"; fi

    local ssh_ok="false"
    if systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null; then ssh_ok="true"; fi

    local f2b_ok="false"
    local f2b_banned=0
    if systemctl is-active fail2ban &>/dev/null; then
        f2b_ok="true"
        f2b_banned=$(fail2ban-client status sshd 2>/dev/null | grep 'Currently banned' | awk '{print $NF}') || f2b_banned=0
    fi

    local disk_total="" disk_used="" disk_avail=""
    if mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        disk_total=$(df -B1 "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {print $2}') || true
        disk_used=$(df -B1 "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {print $3}') || true
        disk_avail=$(df -B1 "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {print $4}') || true
    fi

    # Build clients array
    local clients_json=""
    local first_client=true
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local data_dir="${BACKUP_BASE}/${client}/data"
        local snaps=0
        local last_epoch=0
        local status="ok"

        if [[ -d "$data_dir" ]]; then
            snaps=$(count_snapshots "$data_dir")
            last_epoch=$(get_last_activity_epoch "$data_dir")
        fi

        if [[ -z "$last_epoch" ]] || [[ "$last_epoch" == "0" ]]; then
            status="empty"
        elif [[ $(( now - last_epoch )) -gt $(( stale_secs * 3 )) ]]; then
            status="alert"
        elif [[ $(( now - last_epoch )) -gt $stale_secs ]]; then
            status="stale"
        fi

        if ! $first_client; then clients_json+=","; fi
        first_client=false
        clients_json+="{\"name\":\"${display}\",\"snapshots\":${snaps},\"last_activity_epoch\":${last_epoch},\"status\":\"${status}\"}"
    done < <(list_clients)

    cat <<ENDJSON
{
  "generated_at": "${now_human}",
  "generated_epoch": ${now},
  "gateway_version": "${version}",
  "system": {
    "smb_mounted": ${smb_ok},
    "ssh_running": ${ssh_ok},
    "fail2ban_running": ${f2b_ok},
    "fail2ban_banned": ${f2b_banned},
    "disk_total_bytes": ${disk_total:-0},
    "disk_used_bytes": ${disk_used:-0},
    "disk_available_bytes": ${disk_avail:-0}
  },
  "clients": [${clients_json}]
}
ENDJSON
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
    output+="$(printf '%0.s-' {1..70})\n\n"

    local logs=""
    # Try /var/log/auth.log first, fall back to journald
    if [[ -f /var/log/auth.log ]]; then
        logs=$(grep 'backup-' /var/log/auth.log 2>/dev/null | tail -50) || true
        output+="Source: /var/log/auth.log\n\n"
    elif command -v journalctl &>/dev/null; then
        logs=$(journalctl -u ssh -u sshd --no-pager -n 200 2>/dev/null | grep 'backup-' | tail -50) || true
        output+="Source: journald (ssh/sshd)\n\n"
    fi

    if [[ -n "$logs" ]]; then
        output+="$logs\n"
    else
        output+="  No recent backup-related auth entries found.\n"
    fi

    msg_scroll "Auth Logs" "$(echo -e "$output")"
}

# ──────────────────────────────────────────────
# Restore helper
# ──────────────────────────────────────────────

_restore_select_client() {
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        clients+=("$display" "$display")
    done < <(list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        msg_box "Restore" "No backup clients found."
        return 1
    fi

    local choice
    choice=$($DIALOG --title "Restore — Select Client" \
        --menu "Choose a client:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return 1

    echo "$choice"
}

_restore_select_vps() {
    local client="$1"
    local data_dir="${BACKUP_BASE}/backup-${client}/data"
    if [[ ! -d "$data_dir" ]]; then
        msg_box "Restore" "No data directory found for client '${client}'."
        return 1
    fi

    local entries=()
    for dir in "$data_dir"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")
        [[ "$name" == "_meta" ]] && continue
        entries+=("$name" "$name")
    done

    if [[ ${#entries[@]} -eq 0 ]]; then
        msg_box "Restore" "No VPS repositories found for client '${client}'."
        return 1
    fi

    local choice
    choice=$($DIALOG --title "Restore — Select VPS" \
        --menu "Choose a VPS repository:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${entries[@]}" \
        3>&1 1>&2 2>&3) || return 1

    echo "$choice"
}

_restore_get_restic_env() {
    local client="$1"
    local vps="$2"

    export RESTIC_REPOSITORY="${BACKUP_BASE}/backup-${client}/data/${vps}"
    local pw_file="${BACKUP_BASE}/backup-${client}/data/_meta/${vps}/restic-password"

    if [[ ! -f "$pw_file" ]]; then
        msg_box "Restore — Error" "Password file not found:\n${pw_file}"
        return 1
    fi

    export RESTIC_PASSWORD_FILE="$pw_file"
}

_restore_select_snapshot() {
    local snap_items=()

    if command -v jq &>/dev/null; then
        local json
        json=$(restic snapshots --json --no-lock 2>/dev/null) || {
            msg_box "Restore — Error" "Failed to list snapshots from repository."
            return 1
        }

        local count
        count=$(echo "$json" | jq 'length')
        if [[ "$count" -eq 0 || "$count" == "null" ]]; then
            msg_box "Restore" "No snapshots found in this repository."
            return 1
        fi

        while IFS=$'\t' read -r sid stime shost; do
            snap_items+=("$sid" "${stime}  ${shost}")
        done < <(echo "$json" | jq -r '.[] | [.short_id, (.time | split(".")[0] | gsub("T";" ")), .hostname] | @tsv')
    else
        local text_output
        text_output=$(restic snapshots --no-lock --compact 2>/dev/null) || {
            msg_box "Restore — Error" "Failed to list snapshots from repository."
            return 1
        }

        # Parse tabular output: lines that start with a hex id (8 chars)
        while IFS= read -r line; do
            local sid
            sid=$(echo "$line" | awk '{print $1}')
            # short_id is 8 hex chars
            if [[ "$sid" =~ ^[0-9a-f]{8}$ ]]; then
                local rest
                rest=$(echo "$line" | sed "s/^${sid}[[:space:]]*//" | sed 's/[[:space:]]*$//')
                snap_items+=("$sid" "$rest")
            fi
        done <<< "$text_output"

        if [[ ${#snap_items[@]} -eq 0 ]]; then
            msg_box "Restore" "No snapshots found in this repository."
            return 1
        fi
    fi

    local choice
    choice=$($DIALOG --title "Restore — Select Snapshot" \
        --menu "Choose a snapshot:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${snap_items[@]}" \
        3>&1 1>&2 2>&3) || return 1

    echo "$choice"
}

_human_size() {
    awk "BEGIN {
        b=$1
        if      (b >= 1073741824) printf \"%.1f GB\", b/1073741824
        else if (b >= 1048576)    printf \"%.1f MB\", b/1048576
        else if (b >= 1024)       printf \"%.1f KB\", b/1024
        else                      printf \"%d B\", b
    }"
}

_restore_browse() {
    local snapshot_id="$1"
    local current_dir="/"

    # Cache the full file listing with metadata
    # restic ls --long format: perms uid gid size date time path
    local cache_file entries_file
    cache_file=$(mktemp /tmp/restic-browse-XXXXXX) || return
    entries_file=$(mktemp /tmp/restic-entries-XXXXXX) || return
    trap "rm -f '$cache_file' '$entries_file'" RETURN

    $DIALOG --title "Browse" --infobox "Loading file list from snapshot ${snapshot_id}..." 5 $WT_WIDTH
    restic ls --long --no-lock "$snapshot_id" 2>/dev/null > "$cache_file" || {
        msg_box "Browse — Error" "Unable to list snapshot files."
        return
    }

    while true; do
        # Use awk to extract direct children of current_dir with metadata
        # restic ls --long fields: $1=perms $2=uid $3=gid $4=size $5=date $6=time $7+=path
        # Output: name\ttype\tsize\tdate
        awk -v dir="$current_dir" '
        {
            perms=$1; size=$4; date=$5
            # Path is everything from field 7 onwards
            path=""
            for(i=7;i<=NF;i++) path=(path ? path " " : "") $i
            if (path == "") next

            # Determine if direct child of dir
            if (dir == "/") {
                if (path !~ /^\/[^\/]+$/) next
                name = substr(path, 2)
            } else {
                prefix = dir "/"
                if (substr(path, 1, length(prefix)) != prefix) next
                rest = substr(path, length(prefix) + 1)
                if (rest == "" || index(rest, "/") > 0) next
                name = rest
            }

            type = (substr(perms,1,1) == "d") ? "dir" : "file"
            printf "%s\t%s\t%s\t%s\n", name, type, size, date
        }
        ' "$cache_file" | sort -t$'\t' -k2,2r -k1,1 | uniq > "$entries_file"

        # Build menu items
        local -a menu_items=()
        if [[ "$current_dir" != "/" ]]; then
            menu_items+=(".." ".. parent directory")
        fi

        while IFS=$'\t' read -r name type size date; do
            [[ -z "$name" ]] && continue
            if [[ "$type" == "dir" ]]; then
                menu_items+=("${name}/" "${date}  <DIR>")
            else
                local hsize
                hsize=$(_human_size "$size")
                menu_items+=("$name" "${date}  ${hsize}")
            fi
        done < "$entries_file"

        if [[ ${#menu_items[@]} -eq 0 ]]; then
            msg_box "Browse" "No entries in ${current_dir}"
            return
        fi

        local choice
        choice=$($DIALOG --title "Browse — ${current_dir}" \
            --menu "Select entry (Esc to go back):" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "${menu_items[@]}" \
            3>&1 1>&2 2>&3) || return

        if [[ "$choice" == ".." ]]; then
            if [[ "$current_dir" == "/" ]]; then
                continue
            fi
            current_dir="${current_dir%/*}"
            [[ -z "$current_dir" ]] && current_dir="/"
        elif [[ "$choice" == */ ]]; then
            local dir_name="${choice%/}"
            if [[ "$current_dir" == "/" ]]; then
                current_dir="/${dir_name}"
            else
                current_dir="${current_dir}/${dir_name}"
            fi
        else
            # File selected — look up metadata
            local full_path
            if [[ "$current_dir" == "/" ]]; then
                full_path="/${choice}"
            else
                full_path="${current_dir}/${choice}"
            fi

            # Extract file metadata from cache
            # restic ls --long fields: $1=perms $2=uid $3=gid $4=size $5=date $6=time $7+=path
            local file_meta
            file_meta=$(awk -v fp="$full_path" '{
                path=""; for(i=7;i<=NF;i++) path=(path ? path " " : "") $i
                if (path == fp) { printf "%s  %s %s  %s", $1, $5, $6, $4; exit }
            }' "$cache_file")

            local file_info="Path: ${full_path}"
            if [[ -n "$file_meta" ]]; then
                local f_perms f_date f_size_raw
                f_perms=$(echo "$file_meta" | awk '{print $1}')
                f_date=$(echo "$file_meta" | awk '{print $2, $3}')
                f_size_raw=$(echo "$file_meta" | awk '{print $4}')
                local f_hsize
                f_hsize=$(_human_size "$f_size_raw")
                file_info="Path: ${full_path}\nSize: ${f_hsize}\nDate: ${f_date}\nMode: ${f_perms}"
            fi

            local file_action
            file_action=$($DIALOG --title "File — ${choice}" \
                --menu "$file_info" $WT_HEIGHT $WT_WIDTH 3 \
                "restore" "Restore this file" \
                "copy"    "Copy path to clipboard" \
                "back"    "Go back" \
                3>&1 1>&2 2>&3) || continue

            case "$file_action" in
                restore)
                    local timestamp
                    timestamp=$(date +%Y%m%d-%H%M%S)
                    local target
                    target=$($DIALOG --title "Restore — Target" \
                        --inputbox "Directory to restore into:" 10 $WT_WIDTH \
                        "/tmp/computile-restore-${timestamp}" \
                        3>&1 1>&2 2>&3) || continue

                    yesno "Confirm Restore" \
                        "Restore: ${full_path}\nTarget: ${target}\n\nProceed?" || continue

                    local result
                    result=$(restic restore --no-lock "$snapshot_id" \
                        --target "$target" --include "$full_path" 2>&1) || true
                    msg_scroll "Restore Result" "$result"
                    ;;
                copy)
                    echo -n "$full_path" | xclip -selection clipboard 2>/dev/null \
                        || echo -n "$full_path" | xsel --clipboard 2>/dev/null \
                        || msg_box "Path" "$full_path"
                    ;;
                back) ;;
            esac
        fi
    done
}

_restore_action_menu() {
    local snapshot_id="$1"

    local action
    action=$($DIALOG --title "Restore — Action" \
        --menu "Snapshot: ${snapshot_id}" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "browse"  "Browse files" \
        "restore" "Restore to directory" \
        3>&1 1>&2 2>&3) || return

    case "$action" in
        browse)
            _restore_browse "$snapshot_id"
            ;;
        restore)
            local path target timestamp
            path=$($DIALOG --title "Restore — Path" \
                --inputbox "Path to include (e.g. /etc, /home):" 10 $WT_WIDTH \
                "/" \
                3>&1 1>&2 2>&3) || return

            timestamp=$(date +%Y%m%d-%H%M%S)
            target=$($DIALOG --title "Restore — Target Directory" \
                --inputbox "Directory to restore into:" 10 $WT_WIDTH \
                "/tmp/computile-restore-${timestamp}" \
                3>&1 1>&2 2>&3) || return

            yesno "Confirm Restore" \
                "Restore snapshot ${snapshot_id}\nInclude: ${path}\nTarget: ${target}\n\nProceed?" || return

            local result
            result=$(restic restore --no-lock "$snapshot_id" \
                --target "$target" --include "$path" 2>&1) || true

            msg_scroll "Restore Result" "$result"
            ;;
    esac
}

restore_menu() {
    if ! command -v restic &>/dev/null; then
        msg_box "Restore — Error" "restic is not installed.\nInstall it with: apt-get install restic"
        return
    fi

    local client
    client=$(_restore_select_client) || return

    local vps
    vps=$(_restore_select_vps "$client") || return

    _restore_get_restic_env "$client" "$vps" || return

    local snapshot_id
    snapshot_id=$(_restore_select_snapshot) || return

    _restore_action_menu "$snapshot_id"
}

# ──────────────────────────────────────────────
# Restore test (delegates to external script)
# ──────────────────────────────────────────────
run_restore_test() {
    local restore_test_bin="/usr/local/bin/computile-restore-test"
    if [[ ! -x "$restore_test_bin" ]]; then
        # Try local path (development)
        local script_dir
        script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
        if [[ -x "${script_dir}/restore-test.sh" ]]; then
            restore_test_bin="${script_dir}/restore-test.sh"
        else
            msg_box "Restore Test" "Restore test script not found.\nInstall with: sudo ./setup_gateway.sh --update"
            return
        fi
    fi
    # Run in interactive mode
    "$restore_test_bin" --interactive
}

# ──────────────────────────────────────────────
# Main menu
# ──────────────────────────────────────────────
main_menu() {
    while true; do
        # Quick count for menu title
        local client_count=0
        while IFS= read -r c; do [[ -n "$c" ]] && { ((client_count++)) || true; }; done < <(list_clients)

        local sftp_count=0
        local sftp_procs
        sftp_procs=$(get_sftp_sessions)
        if [[ -n "$sftp_procs" ]]; then sftp_count=$(echo "$sftp_procs" | wc -l); fi

        local gw_version=""
        [[ -f /usr/local/lib/computile-gateway/VERSION ]] && gw_version=$(head -1 /usr/local/lib/computile-gateway/VERSION | tr -d '[:space:]')

        local title="computile-backup Gateway"
        [[ -n "$gw_version" ]] && title+=" v${gw_version}"
        title+=" — ${client_count} clients"
        if [[ $sftp_count -gt 0 ]]; then title+=" — ${sftp_count} active"; fi

        local choice
        choice=$($DIALOG --title "$title" \
            --menu "Select an operation:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
            "overview"   "📊  Client overview (all clients)" \
            "client"     "🔍  Inspect a specific client" \
            "search"     "🔎  Search client by name" \
            "sessions"   "⚡  Active SFTP sessions & locks" \
            "alerts"     "🔔  Stale backup alerts" \
            "sftp-test"  "🔗  Test SFTP setup for a client" \
            "storage"    "💾  Storage breakdown (sizes cached 1h)" \
            "restore"    "♻  Restore files from backup" \
            "restore-test" "🧪  Test restore on a fresh VM" \
            "clearcache" "🗑  Refresh size cache" \
            "health"     "🏥  System health (SMB, SSH, fail2ban)" \
            "tailscale"  "📡  Tailscale peers (online/offline)" \
            "fail2ban"   "🛡  Fail2ban: view/unban IPs" \
            "logs"       "📋  View auth logs" \
            "users"      "👥  User management" \
            "update"     "⬆  Update gateway (git pull + install)" \
            "quit"       "❌  Quit" \
            3>&1 1>&2 2>&3) || break

        case "$choice" in
            overview)   show_overview ;;
            client)     show_client_detail ;;
            search)     search_client ;;
            sessions)   show_active_sessions ;;
            alerts)     show_stale_alerts ;;
            sftp-test)  test_sftp_client ;;
            storage)    show_storage ;;
            restore)    restore_menu ;;
            restore-test) run_restore_test ;;
            clearcache) _clear_size_cache ;;
            health)     show_system_health ;;
            tailscale)  show_tailscale_peers ;;
            fail2ban)   manage_fail2ban ;;
            logs)       show_auth_logs ;;
            users)      manage_users ;;
            update)     self_update ;;
            quit|"")    break ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Monitor & alert (--monitor)
# ──────────────────────────────────────────────
# Runs all health checks, collects alerts, and sends notifications
# via healthcheck URL and/or webhook. Designed for cron.
monitor_and_alert() {

    local -a alerts=()  # "severity|message" pairs
    local now
    now=$(date +%s)

    # --- Check 1: SMB mount ---
    if ! mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        alerts+=("critical|Storage mount ${BACKUP_BASE} is down")
    else
        # --- Check 2: Disk space ---
        local disk_pct
        disk_pct=$(df "$BACKUP_BASE" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}') || true
        if [[ -n "$disk_pct" ]]; then
            if [[ $disk_pct -ge $DISK_CRITICAL_PERCENT ]]; then
                alerts+=("critical|Disk usage at ${disk_pct}% on ${BACKUP_BASE}")
            elif [[ $disk_pct -ge $DISK_WARN_PERCENT ]]; then
                alerts+=("warning|Disk usage at ${disk_pct}% on ${BACKUP_BASE}")
            fi
        fi
    fi

    # --- Check 3: SSH service ---
    if ! systemctl is-active sshd &>/dev/null && ! systemctl is-active ssh &>/dev/null; then
        alerts+=("critical|SSH service is not running")
    fi

    # --- Check 4: fail2ban ---
    if command -v fail2ban-client &>/dev/null; then
        if ! systemctl is-active fail2ban &>/dev/null; then
            alerts+=("warning|fail2ban is not running")
        fi
    fi

    # --- Check 5: Stale backups (per-VPS) ---
    local stale_secs=$(( STALE_THRESHOLD_DAYS * 86400 ))
    local critical_secs=$(( stale_secs * 3 ))

    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        local data_dir="${BACKUP_BASE}/${client}/data"

        if [[ ! -d "$data_dir" ]]; then
            alerts+=("warning|${display}: data directory missing")
            continue
        fi

        # Check per-VPS freshness
        local has_vps=false
        for vps_dir in "$data_dir"/*/; do
            [[ -d "$vps_dir" ]] || continue
            local vps_name
            vps_name=$(basename "$vps_dir")
            [[ "$vps_name" == "_meta" ]] && continue

            has_vps=true
            local vps_epoch=0

            # Check snapshots/ and locks/ mtimes for this VPS
            for marker in "$vps_dir/snapshots" "$vps_dir/locks"; do
                if [[ -d "$marker" ]]; then
                    local mtime
                    mtime=$(stat -c '%Y' "$marker" 2>/dev/null) || continue
                    if [[ $mtime -gt $vps_epoch ]]; then
                        vps_epoch=$mtime
                    fi
                fi
            done

            # Fallback to the VPS directory mtime itself
            if [[ $vps_epoch -eq 0 ]]; then
                vps_epoch=$(stat -c '%Y' "$vps_dir" 2>/dev/null || echo "0")
            fi

            if [[ -z "$vps_epoch" ]] || [[ "$vps_epoch" == "0" ]]; then
                alerts+=("warning|${display}/${vps_name}: never backed up")
                continue
            fi

            local age_secs=$(( now - vps_epoch ))
            local age_days=$(( age_secs / 86400 ))

            if [[ $age_secs -gt $critical_secs ]]; then
                alerts+=("critical|${display}/${vps_name}: last backup ${age_days}d ago (critical)")
            elif [[ $age_secs -gt $stale_secs ]]; then
                alerts+=("warning|${display}/${vps_name}: last backup ${age_days}d ago (stale)")
            fi
        done

        if [[ "$has_vps" == "false" ]]; then
            alerts+=("warning|${display}: never backed up")
        fi
    done < <(list_clients)

    # --- Check 6: Stale restic locks ---
    local auto_unlock_secs=$(( MONITOR_AUTO_UNLOCK_HOURS * 3600 ))
    if mountpoint -q "$BACKUP_BASE" 2>/dev/null; then
        while IFS= read -r client; do
            [[ -z "$client" ]] && continue
            local data_dir="${BACKUP_BASE}/${client}/data"
            [[ -d "$data_dir" ]] || continue

            for vps_dir in "$data_dir"/*/; do
                [[ -d "$vps_dir" ]] || continue
                local lock_dir="${vps_dir}locks"
                [[ -d "$lock_dir" ]] || continue

                for lock_file in "$lock_dir"/*; do
                    [[ -f "$lock_file" ]] || continue
                    local lock_age
                    lock_age=$(( now - $(stat -c '%Y' "$lock_file" 2>/dev/null || echo "$now") ))
                    if [[ $lock_age -gt 3600 ]]; then
                        local lock_hours=$(( lock_age / 3600 ))
                        local vps_name
                        vps_name=$(basename "$(dirname "$lock_dir")")

                        # Auto-remove if enabled and lock exceeds threshold
                        if [[ "${MONITOR_AUTO_UNLOCK:-no}" == "yes" ]] && [[ $lock_age -gt $auto_unlock_secs ]]; then
                            if rm -f "$lock_file" 2>/dev/null; then
                                alerts+=("warning|${client#backup-}/${vps_name}: stale lock removed (was ${lock_hours}h old)")
                            else
                                alerts+=("warning|${client#backup-}/${vps_name}: stale lock (${lock_hours}h old, auto-remove failed)")
                            fi
                        else
                            alerts+=("warning|${client#backup-}/${vps_name}: stale lock (${lock_hours}h old)")
                        fi
                    fi
                done
            done
        done < <(list_clients)
    fi

    # --- Check 7: NTP sync ---
    if command -v timedatectl &>/dev/null; then
        local ntp_sync
        ntp_sync=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null) || true
        if [[ "$ntp_sync" == "no" ]]; then
            alerts+=("warning|System clock not synchronized (NTP)")
        fi
    fi

    # --- Check 8: Security updates ---
    if command -v apt &>/dev/null; then
        local sec_count
        sec_count=$(apt list --upgradable 2>/dev/null | grep -c -i security) || true
        if [[ -n "$sec_count" ]] && [[ "$sec_count" -gt 0 ]]; then
            alerts+=("warning|${sec_count} security update(s) available")
        fi
    fi

    # --- Check 9: Restic integrity check ---
    if [[ "${MONITOR_RESTIC_CHECK:-no}" == "yes" ]]; then
        while IFS= read -r client; do
            [[ -z "$client" ]] && continue
            local display="${client#backup-}"
            local data_dir="${BACKUP_BASE}/${client}/data"
            local meta_dir="${BACKUP_BASE}/${client}/_meta"
            [[ -d "$data_dir" ]] || continue

            # Find the first VPS repo
            local repo_path=""
            for vps_dir in "$data_dir"/*/; do
                [[ -d "$vps_dir" ]] || continue
                local vps_name
                vps_name=$(basename "$vps_dir")
                [[ "$vps_name" == "_meta" ]] && continue
                if [[ -f "$vps_dir/config" ]]; then
                    repo_path="$vps_dir"
                    break
                fi
            done
            [[ -n "$repo_path" ]] || continue

            # Find the password file
            local password_file=""
            if [[ -f "${meta_dir}/restic-password" ]]; then
                password_file="${meta_dir}/restic-password"
            elif [[ -f "${BACKUP_BASE}/${client}/restic-password" ]]; then
                password_file="${BACKUP_BASE}/${client}/restic-password"
            fi
            [[ -n "$password_file" ]] || continue

            # Run restic check with timeout
            local check_output
            if ! check_output=$(RESTIC_REPOSITORY="$repo_path" RESTIC_PASSWORD_FILE="$password_file" \
                    timeout 120 restic check --no-lock --quiet 2>&1); then
                alerts+=("warning|${display}: restic integrity check failed")
            fi
        done < <(list_clients)
    fi

    # --- Determine overall status ---
    local status="ok"
    local critical_count=0
    local warning_count=0

    for alert in "${alerts[@]+"${alerts[@]}"}"; do
        case "${alert%%|*}" in
            critical) ((critical_count++)) || true ;;
            warning)  ((warning_count++)) || true ;;
        esac
    done

    if [[ $critical_count -gt 0 ]]; then
        status="critical"
    elif [[ $warning_count -gt 0 ]]; then
        status="warning"
    fi

    # --- Anti-flapping: fingerprint-based deduplication ---
    local state_dir="/var/lib/computile-gateway"
    local state_file="${state_dir}/monitor-state"
    local fingerprint
    if [[ ${#alerts[@]} -gt 0 ]]; then
        fingerprint=$(printf '%s\n' "${alerts[@]}" | sort | md5sum | awk '{print $1}')
    else
        fingerprint="ok"
    fi

    local prev_fingerprint=""
    if [[ -f "$state_file" ]]; then
        prev_fingerprint=$(head -1 "$state_file" 2>/dev/null) || true
    fi

    local alerts_changed=true
    if [[ "$fingerprint" == "$prev_fingerprint" ]]; then
        alerts_changed=false
    fi

    # Persist new fingerprint (best-effort)
    mkdir -p "$state_dir" 2>/dev/null || true
    echo "$fingerprint" > "$state_file" 2>/dev/null || true

    # --- Build summary ---
    local summary=""
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    if [[ ${#alerts[@]} -eq 0 ]]; then
        summary="All checks passed on ${hostname}"
        echo "[OK] ${summary}"
    else
        summary="${critical_count} critical, ${warning_count} warning on ${hostname}"
        for alert in "${alerts[@]}"; do
            local severity="${alert%%|*}"
            local message="${alert#*|}"
            local tag
            tag=$(echo "$severity" | tr '[:lower:]' '[:upper:]')
            echo "[${tag}] ${message}"
        done
        echo "---"
        echo "Summary: ${summary}"
    fi

    # --- Send healthcheck ping ---
    if [[ -n "$GATEWAY_HEALTHCHECK_URL" ]]; then
        local hc_url="$GATEWAY_HEALTHCHECK_URL"
        if [[ "$status" != "ok" ]]; then
            hc_url="${hc_url}/fail"
        fi
        curl -fsS --max-time 10 --retry 3 \
            -X POST --data-raw "${summary}" \
            "$hc_url" >/dev/null 2>&1 || \
            echo "[WARN] Healthcheck ping failed" >&2
    fi

    # --- Send webhook (only when alert set changes) ---
    if [[ -n "$GATEWAY_WEBHOOK_URL" ]] && [[ "$alerts_changed" == "true" ]]; then
        # Build JSON payload
        local alerts_json="["
        local first=true
        for alert in "${alerts[@]+"${alerts[@]}"}"; do
            local severity="${alert%%|*}"
            local message="${alert#*|}"
            # Escape quotes in message
            message="${message//\"/\\\"}"
            if ! $first; then alerts_json+=","; fi
            alerts_json+="{\"severity\":\"${severity}\",\"message\":\"${message}\"}"
            first=false
        done
        alerts_json+="]"

        local payload
        payload=$(cat <<PEOF
{"status":"${status}","hostname":"${hostname}","alerts":${alerts_json},"summary":"${summary//\"/\\\"}","timestamp":"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"}
PEOF
        )

        # Build curl headers
        local -a curl_headers=()
        curl_headers+=("-H" "Content-Type: application/json")
        for hdr in "${GATEWAY_WEBHOOK_HEADERS[@]+"${GATEWAY_WEBHOOK_HEADERS[@]}"}"; do
            [[ -n "$hdr" ]] && curl_headers+=("-H" "$hdr")
        done

        curl -fsS --max-time 10 --retry 3 \
            "${curl_headers[@]}" \
            -X POST --data-raw "$payload" \
            "$GATEWAY_WEBHOOK_URL" >/dev/null 2>&1 || \
            echo "[WARN] Webhook notification failed" >&2
    elif [[ -n "$GATEWAY_WEBHOOK_URL" ]] && [[ "$alerts_changed" == "false" ]]; then
        echo "[INFO] Alert set unchanged — notifications suppressed"
    fi

    # Exit code: 0 = ok, 1 = warnings, 2 = critical
    if [[ $critical_count -gt 0 ]]; then
        return 2
    elif [[ $warning_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────
# Test notifications (--test-notifications)
# ──────────────────────────────────────────────
test_notifications() {
    _load_gateway_config

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local any_configured=false

    # Test healthcheck ping
    if [[ -n "$GATEWAY_HEALTHCHECK_URL" ]]; then
        any_configured=true
        echo "Testing healthcheck ping: ${GATEWAY_HEALTHCHECK_URL}"
        if curl -fsS --max-time 10 \
                -X POST --data-raw "test" \
                "$GATEWAY_HEALTHCHECK_URL" >/dev/null 2>&1; then
            echo "  [OK] Healthcheck ping succeeded"
        else
            echo "  [FAIL] Healthcheck ping failed"
        fi
    fi

    # Test webhook
    if [[ -n "$GATEWAY_WEBHOOK_URL" ]]; then
        any_configured=true
        echo "Testing webhook: ${GATEWAY_WEBHOOK_URL}"

        local payload
        payload=$(cat <<PEOF
{"status":"test","hostname":"${hostname}","alerts":[{"severity":"info","message":"Test notification from computile-gateway-manager"}],"summary":"This is a test notification"}
PEOF
        )

        local -a curl_headers=()
        curl_headers+=("-H" "Content-Type: application/json")
        for hdr in "${GATEWAY_WEBHOOK_HEADERS[@]+"${GATEWAY_WEBHOOK_HEADERS[@]}"}"; do
            [[ -n "$hdr" ]] && curl_headers+=("-H" "$hdr")
        done

        if curl -fsS --max-time 10 \
                "${curl_headers[@]}" \
                -X POST --data-raw "$payload" \
                "$GATEWAY_WEBHOOK_URL" >/dev/null 2>&1; then
            echo "  [OK] Webhook notification succeeded"
        else
            echo "  [FAIL] Webhook notification failed"
        fi
    fi

    if [[ "$any_configured" == "false" ]]; then
        echo "No notification channels configured."
        echo "Set GATEWAY_HEALTHCHECK_URL and/or GATEWAY_WEBHOOK_URL in ${GATEWAY_CONFIG}"
    fi
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
    --report)
        # Full health report (text or JSON)
        generate_report "${2:-text}"
        exit 0
        ;;
    --report-json)
        generate_report "json"
        exit 0
        ;;
    --monitor)
        # Run all health checks and send notifications
        monitor_and_alert
        exit $?
        ;;
    --test-notifications)
        # Send test notifications to configured channels
        test_notifications
        exit 0
        ;;
    --help|-h)
        cat <<'HELP'
computile-gateway-manager — TUI manager for the backup gateway

Usage:
  sudo computile-gateway-manager                 # Interactive TUI
  sudo computile-gateway-manager --monitor              # Run health checks + send alerts (for cron)
  sudo computile-gateway-manager --check-alerts         # Print stale backup alerts (for cron)
  sudo computile-gateway-manager --report               # Full health report (text)
  sudo computile-gateway-manager --report-json          # Full health report (JSON)
  sudo computile-gateway-manager --test-notifications   # Send test notification to all channels

Interactive features:
  - Client overview: all clients, snapshot counts, last activity
  - Per-client detail: VPS directories, storage breakdown, recovery metadata
  - Client search by name
  - Active SFTP sessions, restic locks, stale lock removal
  - Stale backup alerting (configurable threshold)
  - SFTP connectivity test per client
  - Storage analysis per client (cached 1h)
  - System health: SMB mount, SSH, fail2ban, Tailscale
  - Tailscale peers overview (online/offline status)
  - Fail2ban management: view, unban IP, unban all
  - User management: create, remove, view/add/remove SSH keys
  - Auth log viewer

Non-interactive modes:
  --monitor         Run all health checks, send healthcheck ping + webhook on problems
                    Config: /etc/computile-backup/gateway.conf
                    Checks: SMB mount, disk space, SSH, fail2ban, stale backups (per-VPS),
                            stuck locks, NTP sync, security updates, restic integrity
                    Exit codes: 0=ok, 1=warning, 2=critical
  --test-notifications  Send a test notification to all configured channels
  --check-alerts    Prints alerts for stale/missing backups, exits 1 if any
  --report          Full health report (text format, to stdout)
  --report-json     Full health report (JSON format)

Examples:
  # Health monitoring every 15 min with healthcheck.io + webhook
  */15 * * * * /usr/local/bin/computile-gateway-manager --monitor 2>&1 | logger -t computile-gw
  # Simple alert check with email
  0 8 * * * /usr/local/bin/computile-gateway-manager --check-alerts || mail -s "Backup alerts" admin@example.com
  # JSON report for monitoring integration
  computile-gateway-manager --report-json | curl -X POST -d @- https://monitoring.example.com/api/gateway
HELP
        exit 0
        ;;
    --version)
        echo "computile-gateway-manager v$(cat /usr/local/lib/computile-gateway/VERSION 2>/dev/null || echo 'dev')"
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
