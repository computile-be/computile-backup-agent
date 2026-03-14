#!/usr/bin/env bash
# restic.sh — Restic backup operations
# Part of computile-backup-agent

[[ -n "${_RESTIC_SH_LOADED:-}" ]] && return 0
_RESTIC_SH_LOADED=1

# ──────────────────────────────────────────────
# Restic environment
# ──────────────────────────────────────────────
_setup_restic_env() {
    export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set}"
    export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE not set}"

    # Optional: cache directory
    if [[ -n "${RESTIC_CACHE_DIR:-}" ]]; then
        mkdir -p "$RESTIC_CACHE_DIR" 2>/dev/null || true
        export RESTIC_CACHE_DIR
    fi
}

# ──────────────────────────────────────────────
# Auto-exclude DB container bind mounts
# ──────────────────────────────────────────────
# DB data directories are backed up via logical dumps (mysqldump, pg_dump).
# Raw data files (InnoDB tablespaces, WAL segments) are redundant and unsafe
# to back up with restic (no locking = potentially corrupt on restore).
# This function detects bind-mounted data dirs from running DB containers
# and adds --exclude flags for each.
_exclude_db_bind_mounts() {
    local -n _opts=$1  # nameref to exclude_opts array

    local discovered
    discovered=$(discover_db_containers 2>/dev/null) || return 0
    [[ -z "$discovered" ]] && return 0

    while IFS='|' read -r cid cname db_type image; do
        [[ -z "$cid" ]] && continue

        # Get bind mounts (Type=bind only, not named volumes)
        local mounts
        mounts=$(docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}{{"\n"}}{{end}}{{end}}' "$cid" 2>/dev/null) || continue

        while IFS= read -r mount_src; do
            [[ -z "$mount_src" ]] && continue

            # Only exclude if path looks like a DB data directory
            # (contains data, db, mysql, postgres, redis, etc.)
            local mount_lower
            mount_lower=$(echo "$mount_src" | tr '[:upper:]' '[:lower:]')

            local should_exclude=false
            case "$db_type" in
                mysql)
                    # MySQL/MariaDB default data dirs and common mount patterns
                    if [[ "$mount_lower" == */mysql* ]] || \
                       [[ "$mount_lower" == */mariadb* ]] || \
                       [[ "$mount_lower" == */data ]] || \
                       [[ "$mount_lower" == */db-data ]] || \
                       [[ "$mount_lower" == */database* ]]; then
                        should_exclude=true
                    fi
                    ;;
                postgres)
                    if [[ "$mount_lower" == */postgres* ]] || \
                       [[ "$mount_lower" == */pgdata* ]] || \
                       [[ "$mount_lower" == */pg_data* ]] || \
                       [[ "$mount_lower" == */data ]] || \
                       [[ "$mount_lower" == */db-data ]] || \
                       [[ "$mount_lower" == */database* ]]; then
                        should_exclude=true
                    fi
                    ;;
                redis)
                    if [[ "$mount_lower" == */redis* ]] || \
                       [[ "$mount_lower" == */data ]] || \
                       [[ "$mount_lower" == */db-data ]]; then
                        should_exclude=true
                    fi
                    ;;
            esac

            if $should_exclude; then
                log_info "Auto-excluding DB bind mount: $mount_src ($cname/$db_type)"
                _opts+=("--exclude" "$mount_src")
            fi
        done <<< "$mounts"
    done <<< "$discovered"
}

# ──────────────────────────────────────────────
# Repository management
# ──────────────────────────────────────────────
restic_repo_exists() {
    _setup_restic_env
    restic snapshots --json --last 2>/dev/null | head -c 1 | grep -q '\[' 2>/dev/null
}

restic_init_repo() {
    _setup_restic_env
    log_info "Initializing restic repository: $RESTIC_REPOSITORY"

    if restic_repo_exists; then
        log_info "Repository already initialized"
        return 0
    fi

    if restic init 2>&1 | while IFS= read -r line; do log_info "  restic: $line"; done; then
        log_info "Repository initialized successfully"
        return 0
    else
        log_error "Failed to initialize restic repository"
        return 1
    fi
}

# ──────────────────────────────────────────────
# Connectivity pre-check
# ──────────────────────────────────────────────
restic_check_connectivity() {
    _setup_restic_env

    log_info "Checking repository connectivity..."

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "[DRY RUN] Would check repository connectivity"
        return 0
    fi

    # Try to list snapshots — this validates SFTP connectivity, auth, and repo access
    if restic snapshots --json --last --quiet 2>/dev/null >/dev/null; then
        log_info "Repository is reachable"
        return 0
    fi

    log_error "Cannot reach restic repository: $RESTIC_REPOSITORY"
    log_error "Check SFTP connectivity, Tailscale status, and SSH keys"
    return 1
}

# ──────────────────────────────────────────────
# Backup
# ──────────────────────────────────────────────
restic_backup() {
    _setup_restic_env

    # Check repository is accessible
    if ! restic_repo_exists; then
        log_error "Restic repository is not accessible or not initialized: $RESTIC_REPOSITORY"
        log_error "Run with --init flag to initialize, or initialize manually with: restic init"
        return 1
    fi

    # Build backup paths
    local backup_paths=()

    # Include configured paths
    if [[ -n "${INCLUDE_PATHS+x}" ]] && [[ ${#INCLUDE_PATHS[@]} -gt 0 ]]; then
        for path in "${INCLUDE_PATHS[@]}"; do
            if [[ -e "$path" ]]; then
                backup_paths+=("$path")
            else
                log_warn "Include path does not exist, skipping: $path"
            fi
        done
    fi

    # Include DB dump directory
    if [[ -d "${DB_DUMP_DIR:-}" ]]; then
        backup_paths+=("$DB_DUMP_DIR")
    fi

    if [[ ${#backup_paths[@]} -eq 0 ]]; then
        log_error "No valid backup paths found — all INCLUDE_PATHS are missing and no database dumps exist"
        return 1
    fi

    # Warn if only dump directory exists (no filesystem paths)
    local has_non_dump_paths=false
    for p in "${backup_paths[@]}"; do
        [[ "$p" != "${DB_DUMP_DIR:-}" ]] && has_non_dump_paths=true
    done
    if ! $has_non_dump_paths; then
        log_warn "No filesystem paths to backup — only database dumps will be included. Check INCLUDE_PATHS in config."
    fi

    # Build tags
    local tags=()
    tags+=("--tag" "client:${CLIENT_ID}")
    tags+=("--tag" "host:${HOST_ID}")
    tags+=("--tag" "env:${ENVIRONMENT:-prod}")
    tags+=("--tag" "role:${ROLE:-server}")
    tags+=("--tag" "agent:v${AGENT_VERSION:-unknown}")

    # Build exclude options
    local exclude_opts=()
    if [[ -n "${EXCLUDE_FILE:-}" ]] && [[ -f "$EXCLUDE_FILE" ]]; then
        exclude_opts+=("--exclude-file" "$EXCLUDE_FILE")
    fi

    # Common exclusions
    exclude_opts+=("--exclude-caches")

    # Auto-exclude bind-mounted database data directories
    # DB files are backed up via logical dumps (mysqldump/pg_dump), so raw data
    # files are both redundant and potentially inconsistent if copied by restic.
    if [[ "${DOCKER_ENABLED:-yes}" == "yes" ]] && command -v docker &>/dev/null; then
        _exclude_db_bind_mounts exclude_opts
    fi

    # Bandwidth limit
    local bw_opts=()
    if [[ -n "${RESTIC_UPLOAD_LIMIT_KB:-}" ]] && [[ "$RESTIC_UPLOAD_LIMIT_KB" -gt 0 ]] 2>/dev/null; then
        bw_opts+=("--limit-upload" "$RESTIC_UPLOAD_LIMIT_KB")
        log_info "  Upload limit: ${RESTIC_UPLOAD_LIMIT_KB} KB/s"
    fi

    log_info "Starting restic backup"
    log_info "  Paths: ${backup_paths[*]}"
    log_info "  Tags: client:${CLIENT_ID} host:${HOST_ID} env:${ENVIRONMENT:-prod} role:${ROLE:-server}"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "[DRY RUN] Would run: restic backup ${backup_paths[*]}"
        return 0
    fi

    # Retry logic for transient SFTP failures
    local max_retries="${RESTIC_RETRY_COUNT:-2}"
    local attempt=0
    local rc=0

    while [[ $attempt -le $max_retries ]]; do
        if [[ $attempt -gt 0 ]]; then
            local wait_secs=$(( attempt * 30 ))
            log_warn "Retrying restic backup in ${wait_secs}s (attempt $((attempt + 1))/$((max_retries + 1)))..."
            sleep "$wait_secs"
        fi

        rc=0

        # Stream output in real-time (progress bar visible) and capture for logging
        if [[ -n "${LOG_FILE:-}" ]]; then
            restic backup \
                --host "${HOST_ID}" \
                "${tags[@]}" \
                "${exclude_opts[@]}" \
                "${bw_opts[@]}" \
                --verbose \
                "${backup_paths[@]}" 2>&1 | tee -a "$LOG_FILE" || rc=${PIPESTATUS[0]}
        else
            restic backup \
                --host "${HOST_ID}" \
                "${tags[@]}" \
                "${exclude_opts[@]}" \
                "${bw_opts[@]}" \
                --verbose \
                "${backup_paths[@]}" || rc=$?
        fi

        if [[ $rc -eq 0 ]]; then
            break
        fi

        ((attempt++))
    done

    if [[ $rc -ne 0 ]]; then
        log_error "Restic backup failed after $((max_retries + 1)) attempts (exit code $rc)"
        return $rc
    fi

    log_info "Restic backup completed successfully"
    return 0
}

# ──────────────────────────────────────────────
# Retention policy
# ──────────────────────────────────────────────
restic_forget_prune() {
    _setup_restic_env

    local keep_daily="${RETENTION_KEEP_DAILY:-7}"
    local keep_weekly="${RETENTION_KEEP_WEEKLY:-4}"
    local keep_monthly="${RETENTION_KEEP_MONTHLY:-6}"
    local keep_yearly="${RETENTION_KEEP_YEARLY:-2}"

    log_info "Applying retention policy: ${keep_daily}d / ${keep_weekly}w / ${keep_monthly}m / ${keep_yearly}y"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "[DRY RUN] Would run: restic forget --prune --keep-daily=$keep_daily --keep-weekly=$keep_weekly --keep-monthly=$keep_monthly --keep-yearly=$keep_yearly"
        return 0
    fi

    local output
    local rc=0
    output=$(restic forget --prune \
        --host "${HOST_ID}" \
        --keep-daily="$keep_daily" \
        --keep-weekly="$keep_weekly" \
        --keep-monthly="$keep_monthly" \
        --keep-yearly="$keep_yearly" \
        --group-by "host,tags" \
        2>&1) || rc=$?

    while IFS= read -r line; do
        log_debug "  restic forget: $line"
    done <<< "$output"

    if [[ $rc -ne 0 ]]; then
        log_error "Retention policy application failed (exit code $rc)"
        return $rc
    fi

    log_info "Retention policy applied successfully"
    return 0
}

# ──────────────────────────────────────────────
# Verification
# ──────────────────────────────────────────────
restic_verify() {
    _setup_restic_env

    if [[ "${VERIFY_AFTER_BACKUP:-yes}" != "yes" ]]; then
        log_debug "Post-backup verification disabled"
        return 0
    fi

    log_info "Verifying latest snapshot"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "[DRY RUN] Would verify latest snapshot"
        return 0
    fi

    # Quick verification: list the latest snapshot
    local latest
    latest=$(restic snapshots --json --last 2>/dev/null) || {
        log_error "Failed to list snapshots for verification"
        return 1
    }

    if [[ -z "$latest" ]] || [[ "$latest" == "[]" ]] || [[ "$latest" == "null" ]]; then
        log_error "No snapshots found after backup — this should not happen"
        return 1
    fi

    log_info "Latest snapshot verified"

    # Optionally run a lightweight check
    if [[ "${VERIFY_CHECK_DATA:-no}" == "yes" ]]; then
        log_info "Running restic check (read-data-subset=1%)..."
        local output
        local rc=0
        output=$(restic check --read-data-subset='1%' 2>&1) || rc=$?

        while IFS= read -r line; do
            log_debug "  restic check: $line"
        done <<< "$output"

        if [[ $rc -ne 0 ]]; then
            log_warn "Restic check reported issues (exit code $rc)"
            return $rc
        fi

        log_info "Restic check passed"
    fi

    return 0
}

# ──────────────────────────────────────────────
# Snapshot listing (for reports)
# ──────────────────────────────────────────────
restic_latest_snapshot_info() {
    _setup_restic_env
    restic snapshots --last --compact 2>/dev/null || echo "Unable to retrieve snapshot info"
}

# Report stats from the latest snapshot
restic_report_stats() {
    _setup_restic_env

    local stats_output
    stats_output=$(restic stats --json --mode restore-size latest 2>/dev/null) || return 0

    if command -v jq &>/dev/null && [[ -n "$stats_output" ]]; then
        local total_size
        total_size=$(echo "$stats_output" | jq -r '.total_size // 0')
        local total_count
        total_count=$(echo "$stats_output" | jq -r '.total_file_count // 0')

        # Human-readable size
        local human_size
        if [[ $total_size -gt $((1024*1024*1024)) ]]; then
            human_size="$(( total_size / 1024 / 1024 / 1024 )) GB"
        elif [[ $total_size -gt $((1024*1024)) ]]; then
            human_size="$(( total_size / 1024 / 1024 )) MB"
        else
            human_size="$(( total_size / 1024 )) KB"
        fi

        log_info "Snapshot stats: ${total_count} files, ${human_size} (restore size)"
    fi
}

# ──────────────────────────────────────────────
# Sync critical config to gateway (_meta directory)
# ──────────────────────────────────────────────
# Uploads restic password, agent config, and SSH key to a _meta/
# directory on the gateway. This ensures disaster recovery is
# possible even if the VPS is completely lost.
sync_meta_to_gateway() {
    # Parse SFTP target from RESTIC_REPOSITORY
    # Format: sftp:user@host:/path/to/repo
    local repo="${RESTIC_REPOSITORY:-}"
    if [[ ! "$repo" =~ ^sftp:([^:]+):(.+)$ ]]; then
        log_debug "Repository is not SFTP-based, skipping meta sync"
        return 0
    fi

    local sftp_target="${BASH_REMATCH[1]}"
    local repo_path="${BASH_REMATCH[2]}"
    # _meta lives one level up from the restic repo (alongside VPS dirs)
    local meta_path
    meta_path=$(dirname "$repo_path")/_meta/${HOST_ID}

    log_info "Syncing recovery metadata to gateway..."
    log_debug "  Target: ${sftp_target}:${meta_path}"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "[DRY RUN] Would sync meta to ${sftp_target}:${meta_path}"
        return 0
    fi

    # Build SFTP batch commands
    local batch_file
    batch_file=$(mktemp) || { log_error "Failed to create temp file for SFTP batch"; return 1; }
    trap "rm -f '$batch_file'" RETURN

    # Create directory structure
    echo "-mkdir $(dirname "$repo_path")/_meta" >> "$batch_file"
    echo "-mkdir ${meta_path}" >> "$batch_file"

    # Track what we're uploading
    local file_count=0

    # Upload restic password (critical — without this, backups are unrecoverable)
    if [[ -f "${RESTIC_PASSWORD_FILE:-}" ]]; then
        echo "put ${RESTIC_PASSWORD_FILE} ${meta_path}/restic-password" >> "$batch_file"
        ((file_count++)) || true
    else
        log_warn "  Restic password file not found: ${RESTIC_PASSWORD_FILE:-<not set>}"
    fi

    # Upload agent config (useful for re-deployment)
    local config_file="${CONFIG_FILE:-/etc/computile-backup/backup-agent.conf}"
    if [[ -f "$config_file" ]]; then
        echo "put ${config_file} ${meta_path}/backup-agent.conf" >> "$batch_file"
        ((file_count++)) || true
    else
        log_debug "  Config file not found: ${config_file}"
    fi

    # Upload SSH public key (useful for re-authorizing a rebuilt VPS)
    local key_found=false
    for key_path in /root/.ssh/backup_ed25519.pub /etc/computile-backup/ssh/id_ed25519.pub; do
        if [[ -f "$key_path" ]]; then
            echo "put ${key_path} ${meta_path}/ssh-public-key.pub" >> "$batch_file"
            ((file_count++)) || true
            key_found=true
            break
        fi
    done
    if ! $key_found; then
        log_debug "  No SSH public key found for meta sync"
    fi

    if [[ $file_count -eq 0 ]]; then
        log_warn "No recovery metadata files found to sync"
        return 0
    fi

    # Execute SFTP batch (best-effort: don't fail the backup if this fails)
    local sftp_output
    local sftp_rc=0
    sftp_output=$(sftp -o ConnectTimeout=10 -o BatchMode=yes -b "$batch_file" "${sftp_target}" 2>&1) || sftp_rc=$?

    if [[ $sftp_rc -eq 0 ]]; then
        log_info "Recovery metadata synced to gateway (_meta/${HOST_ID}/): ${file_count} file(s)"
    else
        log_warn "Failed to sync metadata to gateway (exit code ${sftp_rc})"
        # Log SFTP errors for diagnosis
        while IFS= read -r line; do
            [[ -n "$line" ]] && log_warn "  sftp: $line"
        done <<< "$sftp_output"
    fi
}

# ──────────────────────────────────────────────
# Healthcheck ping (healthchecks.io, Uptime Kuma, etc.)
# ──────────────────────────────────────────────
healthcheck_ping() {
    local status="${1:-success}"  # success or fail
    local message="${2:-}"        # optional summary message

    if [[ -z "${HEALTHCHECK_URL:-}" ]]; then
        return 0
    fi

    local url="$HEALTHCHECK_URL"
    if [[ "$status" == "fail" ]]; then
        url="${url}/fail"
    fi

    log_debug "Pinging healthcheck: $url"

    # Build a summary body for services that support it (healthchecks.io, etc.)
    local body=""
    body+="Host:     ${HOST_ID:-unknown}"$'\n'
    body+="Client:   ${CLIENT_ID:-unknown}"$'\n'
    body+="Env:      ${ENVIRONMENT:-unknown}"$'\n'
    body+="Agent:    v${AGENT_VERSION:-unknown}"$'\n'
    body+="Duration: $(get_elapsed 2>/dev/null || echo 'N/A')"$'\n'

    # Add snapshot stats if available (restic env already set by backup phases)
    if [[ "$status" == "success" ]] && [[ -n "${RESTIC_REPOSITORY:-}" ]]; then
        local stats_json
        stats_json=$(restic stats --json --mode restore-size latest 2>/dev/null) || true
        if [[ -n "$stats_json" ]] && command -v jq &>/dev/null; then
            local total_size total_count human_size
            total_size=$(echo "$stats_json" | jq -r '.total_size // 0')
            total_count=$(echo "$stats_json" | jq -r '.total_file_count // 0')
            if [[ $total_size -gt $((1024*1024*1024)) ]]; then
                human_size="$(( total_size / 1024 / 1024 / 1024 )) GB"
            elif [[ $total_size -gt $((1024*1024)) ]]; then
                human_size="$(( total_size / 1024 / 1024 )) MB"
            else
                human_size="$(( total_size / 1024 )) KB"
            fi
            body+="Size:     ${human_size} (${total_count} files)"$'\n'
        fi

        local snap_count
        snap_count=$(restic snapshots --json 2>/dev/null | jq 'length' 2>/dev/null) || true
        if [[ -n "$snap_count" ]]; then
            body+="Snaps:    ${snap_count} total"$'\n'
        fi
    fi

    # Add error details on failure
    if [[ "$status" == "fail" ]] && [[ -n "$message" ]]; then
        body+=$'\n'"Errors:"$'\n'"${message}"$'\n'
    elif [[ "$status" == "fail" ]]; then
        local errors
        errors=$(get_error_summary 2>/dev/null) || true
        if [[ -n "$errors" ]]; then
            body+=$'\n'"Errors:"$'\n'"${errors}"$'\n'
        fi
    fi

    # Best-effort POST with body: don't fail the backup if the ping fails
    curl -fsS --max-time 10 --retry 3 -X POST --data-raw "$body" "$url" >/dev/null 2>&1 || \
        log_warn "Healthcheck ping failed (non-critical)"
}
