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
        log_error "No valid backup paths found"
        return 1
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
