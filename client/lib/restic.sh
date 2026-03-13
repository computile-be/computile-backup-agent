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

    # Build exclude options
    local exclude_opts=()
    if [[ -n "${EXCLUDE_FILE:-}" ]] && [[ -f "$EXCLUDE_FILE" ]]; then
        exclude_opts+=("--exclude-file" "$EXCLUDE_FILE")
    fi

    # Common exclusions
    exclude_opts+=("--exclude-caches")

    log_info "Starting restic backup"
    log_info "  Paths: ${backup_paths[*]}"
    log_info "  Tags: client:${CLIENT_ID} host:${HOST_ID} env:${ENVIRONMENT:-prod} role:${ROLE:-server}"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "[DRY RUN] Would run: restic backup ${backup_paths[*]}"
        return 0
    fi

    local output
    local rc=0
    output=$(restic backup \
        "${tags[@]}" \
        "${exclude_opts[@]}" \
        --verbose \
        "${backup_paths[@]}" 2>&1) || rc=$?

    # Log output
    while IFS= read -r line; do
        if [[ $rc -ne 0 ]]; then
            log_error "  restic: $line"
        else
            log_info "  restic: $line"
        fi
    done <<< "$output"

    if [[ $rc -ne 0 ]]; then
        log_error "Restic backup failed (exit code $rc)"
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

    log_info "Applying retention policy: ${keep_daily}d / ${keep_weekly}w / ${keep_monthly}m"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "[DRY RUN] Would run: restic forget --prune --keep-daily=$keep_daily --keep-weekly=$keep_weekly --keep-monthly=$keep_monthly"
        return 0
    fi

    local output
    local rc=0
    output=$(restic forget --prune \
        --keep-daily="$keep_daily" \
        --keep-weekly="$keep_weekly" \
        --keep-monthly="$keep_monthly" \
        --tag "host:${HOST_ID}" \
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
