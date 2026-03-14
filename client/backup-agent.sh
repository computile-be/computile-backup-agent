#!/usr/bin/env bash
# ================================================================
# computile-backup-agent — Multi-client backup agent for Linux VPS
#
# Usage:
#   computile-backup [--config FILE] [--init] [--dry-run] [--verbose]
#
# https://github.com/computile/computile-backup-agent
# ================================================================
set -euo pipefail

readonly DEFAULT_CONFIG="/etc/computile-backup/backup-agent.conf"

# ──────────────────────────────────────────────
# Determine script directory and load libraries
# ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# When installed, libs are in /usr/local/lib/computile-backup/
# When running from source, libs are in ./lib/
if [[ -d "/usr/local/lib/computile-backup" ]]; then
    LIB_DIR="/usr/local/lib/computile-backup"
else
    LIB_DIR="${SCRIPT_DIR}/lib"
fi

# Read version from VERSION file (installed alongside libs)
if [[ -f "${LIB_DIR}/VERSION" ]]; then
    readonly AGENT_VERSION="$(head -1 "${LIB_DIR}/VERSION" | tr -d '[:space:]')"
elif [[ -f "${SCRIPT_DIR}/../VERSION" ]]; then
    readonly AGENT_VERSION="$(head -1 "${SCRIPT_DIR}/../VERSION" | tr -d '[:space:]')"
else
    readonly AGENT_VERSION="unknown"
fi

for lib in common docker database notify restic; do
    # shellcheck source=/dev/null
    source "${LIB_DIR}/${lib}.sh" || {
        echo "[FATAL] Failed to load library: ${lib}.sh" >&2
        exit 1
    }
done

# ──────────────────────────────────────────────
# CLI argument parsing
# ──────────────────────────────────────────────
CONFIG_FILE="$DEFAULT_CONFIG"
DO_INIT=false
FORCE_DRY_RUN=false
FORCE_VERBOSE=false

DO_STATUS=false
DO_CHECK=false
CHECK_JSON=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config|-c)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --init)
            DO_INIT=true
            shift
            ;;
        --dry-run)
            FORCE_DRY_RUN=true
            shift
            ;;
        --verbose|-v)
            FORCE_VERBOSE=true
            shift
            ;;
        --status)
            DO_STATUS=true
            shift
            ;;
        --check)
            DO_CHECK=true
            shift
            ;;
        --json)
            CHECK_JSON=true
            shift
            ;;
        --version)
            echo "computile-backup-agent ${AGENT_VERSION}"
            exit 0
            ;;
        --help|-h)
            cat <<'HELP'
computile-backup-agent — Multi-client backup agent for Linux VPS

Usage:
  computile-backup [OPTIONS]

Options:
  --config, -c FILE   Path to config file (default: /etc/computile-backup/backup-agent.conf)
  --init              Initialize the restic repository if it doesn't exist
  --dry-run           Simulate backup without making changes
  --verbose, -v       Enable verbose output
  --status            Output JSON status (for monitoring/fleet tracking)
  --check             Run health check (text output by default)
  --json              Use JSON output (with --check)
  --version           Show version
  --help, -h          Show this help

Examples:
  computile-backup                          # Run with default config
  computile-backup --config /path/to/conf   # Run with custom config
  computile-backup --init                   # Initialize repo and run backup
  computile-backup --dry-run --verbose      # Test run with debug output
  computile-backup --status                 # JSON status for monitoring
  computile-backup --check                  # Health check (text)
  computile-backup --check --json           # Health check (JSON)
HELP
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage information" >&2
            exit 1
            ;;
    esac
done

# ──────────────────────────────────────────────
# Status output (JSON for monitoring/fleet)
# ──────────────────────────────────────────────
show_status_json() {
    # Load config without logging noise
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo '{"error":"config not found"}' >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" 2>/dev/null

    _setup_restic_env 2>/dev/null || true

    # Last backup from systemd
    local last_exit=""
    local last_timestamp=""
    last_exit=$(systemctl show computile-backup.service --property=ExecMainStatus 2>/dev/null | cut -d= -f2) || true
    last_timestamp=$(systemctl show computile-backup.service --property=ExecMainStartTimestamp 2>/dev/null | cut -d= -f2-) || true

    # Timer
    local timer_active="false"
    systemctl is-active computile-backup.timer &>/dev/null && timer_active="true"
    local next_run=""
    next_run=$(systemctl show computile-backup.timer --property=NextElapseUSecRealtime 2>/dev/null | cut -d= -f2) || true

    # Snapshot count & latest
    local snap_count=""
    local latest_snap_time=""
    local latest_snap_size=""
    if command -v jq &>/dev/null; then
        local snaps_json
        snaps_json=$(restic snapshots --json 2>/dev/null) || true
        if [[ -n "$snaps_json" ]]; then
            snap_count=$(echo "$snaps_json" | jq 'length' 2>/dev/null) || true
            latest_snap_time=$(echo "$snaps_json" | jq -r '.[-1].time // empty' 2>/dev/null) || true
        fi

        local stats_json
        stats_json=$(restic stats --json --mode restore-size latest 2>/dev/null) || true
        if [[ -n "$stats_json" ]]; then
            latest_snap_size=$(echo "$stats_json" | jq -r '.total_size // empty' 2>/dev/null) || true
        fi
    fi

    # Disk space
    local disk_avail_mb=""
    if [[ -d "${BACKUP_ROOT:-/var/backups/computile}" ]]; then
        disk_avail_mb=$(df -k "${BACKUP_ROOT}" 2>/dev/null | awk 'NR==2 {print int($4/1024)}') || true
    fi

    # Output JSON (using printf to avoid jq dependency for output)
    cat <<JEOF
{
  "agent_version": "${AGENT_VERSION}",
  "client_id": "${CLIENT_ID:-}",
  "host_id": "${HOST_ID:-}",
  "environment": "${ENVIRONMENT:-}",
  "role": "${ROLE:-}",
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "timer_active": ${timer_active},
  "next_run": "${next_run:-}",
  "last_backup": {
    "exit_code": ${last_exit:-null},
    "timestamp": "${last_timestamp:-}"
  },
  "repository": {
    "snapshot_count": ${snap_count:-null},
    "latest_snapshot_time": "${latest_snap_time:-}",
    "latest_snapshot_size_bytes": ${latest_snap_size:-null}
  },
  "disk_available_mb": ${disk_avail_mb:-null}
}
JEOF
}

# ──────────────────────────────────────────────
# Health check mode
# ──────────────────────────────────────────────
run_health_check() {
    local issues=()
    local critical=false

    # --- Timer active ---
    local timer_active="false"
    if systemctl is-active computile-backup.timer &>/dev/null; then
        timer_active="true"
    else
        issues+=("timer is not active")
        critical=true
    fi

    # --- Last backup exit code ---
    local last_exit=""
    last_exit=$(systemctl show computile-backup.service --property=ExecMainStatus 2>/dev/null | cut -d= -f2) || true
    if [[ -n "$last_exit" ]] && [[ "$last_exit" != "0" ]]; then
        issues+=("last backup exited with code ${last_exit}")
    fi

    # --- Last backup age ---
    local last_timestamp=""
    local last_age_hours=""
    last_timestamp=$(systemctl show computile-backup.service --property=ExecMainStartTimestamp 2>/dev/null | cut -d= -f2-) || true
    last_timestamp=$(echo "$last_timestamp" | sed 's/^ *//')
    if [[ -n "$last_timestamp" ]] && [[ "$last_timestamp" != "" ]]; then
        local last_epoch
        last_epoch=$(date -d "$last_timestamp" '+%s' 2>/dev/null) || true
        if [[ -n "$last_epoch" ]]; then
            local now_epoch
            now_epoch=$(date '+%s')
            last_age_hours=$(( (now_epoch - last_epoch) / 3600 ))
            if [[ $last_age_hours -gt 48 ]]; then
                issues+=("last backup is ${last_age_hours}h old (>48h)")
            fi
        fi
    fi

    # --- Disk space ---
    local backup_root="${BACKUP_ROOT:-/var/backups/computile}"
    local disk_avail_mb=""
    if [[ -d "$backup_root" ]]; then
        disk_avail_mb=$(df -k "$backup_root" 2>/dev/null | awk 'NR==2 {print int($4/1024)}') || true
        if [[ -n "$disk_avail_mb" ]] && [[ "$disk_avail_mb" -lt 500 ]] 2>/dev/null; then
            issues+=("low disk space: ${disk_avail_mb} MB free (<500 MB)")
        fi
    fi

    # --- SFTP connectivity ---
    local sftp_reachable="false"
    if [[ -n "${RESTIC_REPOSITORY:-}" ]] && [[ -n "${RESTIC_PASSWORD_FILE:-}" ]]; then
        _setup_restic_env 2>/dev/null || true
        if restic snapshots --json --last --quiet 2>/dev/null >/dev/null; then
            sftp_reachable="true"
        else
            issues+=("SFTP repository unreachable")
            critical=true
        fi
    else
        issues+=("restic config not loaded, skipped SFTP check")
    fi

    # --- Determine status ---
    local status="ok"
    local exit_code=0
    if $critical; then
        status="critical"
        exit_code=2
    elif [[ ${#issues[@]} -gt 0 ]]; then
        status="degraded"
        exit_code=1
    fi

    # --- Output ---
    if $CHECK_JSON; then
        # Build JSON issues array
        local issues_json="[]"
        if [[ ${#issues[@]} -gt 0 ]]; then
            issues_json="["
            local first=true
            for issue in "${issues[@]}"; do
                if $first; then
                    first=false
                else
                    issues_json+=","
                fi
                # Escape double quotes in issue text
                local escaped="${issue//\"/\\\"}"
                issues_json+="\"${escaped}\""
            done
            issues_json+="]"
        fi

        cat <<JEOF
{
  "status": "${status}",
  "agent_version": "${AGENT_VERSION}",
  "timer_active": ${timer_active},
  "last_backup_exit_code": ${last_exit:-null},
  "last_backup_age_hours": ${last_age_hours:-null},
  "disk_available_mb": ${disk_avail_mb:-null},
  "sftp_reachable": ${sftp_reachable},
  "issues": ${issues_json},
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
JEOF
    else
        echo "computile-backup health check (v${AGENT_VERSION})"
        echo "----------------------------------------"
        printf "  Timer active:    %s\n" "$timer_active"
        printf "  Last exit code:  %s\n" "${last_exit:-N/A}"
        printf "  Last backup age: %s\n" "${last_age_hours:+${last_age_hours}h}"
        printf "  Disk free:       %s\n" "${disk_avail_mb:+${disk_avail_mb} MB}"
        printf "  SFTP reachable:  %s\n" "$sftp_reachable"
        printf "  Agent version:   %s\n" "$AGENT_VERSION"
        echo "----------------------------------------"
        if [[ ${#issues[@]} -eq 0 ]]; then
            echo "All checks passed."
        else
            echo "Issues (${status}):"
            for issue in "${issues[@]}"; do
                echo "  - ${issue}"
            done
        fi
    fi

    return "$exit_code"
}

# ──────────────────────────────────────────────
# Main backup procedure
# ──────────────────────────────────────────────
main() {
    # Handle --check before full initialization
    if $DO_CHECK; then
        # Load config silently for SFTP check
        if [[ -f "$CONFIG_FILE" ]]; then
            # shellcheck source=/dev/null
            source "$CONFIG_FILE" 2>/dev/null || true
        fi
        run_health_check
        exit $?
    fi

    # Handle --status before full initialization
    if $DO_STATUS; then
        show_status_json
        exit 0
    fi

    # Load configuration
    load_config "$CONFIG_FILE"

    # Apply CLI overrides
    if $FORCE_DRY_RUN; then DRY_RUN="yes"; fi
    if $FORCE_VERBOSE; then VERBOSE="yes"; fi

    # Start
    start_timer
    log_section "computile-backup-agent v${AGENT_VERSION}"
    log_info "Client: ${CLIENT_ID} | Host: ${HOST_ID} | Env: ${ENVIRONMENT}"
    log_info "Repository: ${RESTIC_REPOSITORY}"

    if [[ "${DRY_RUN}" == "yes" ]]; then
        log_info "*** DRY RUN MODE — no changes will be made ***"
    fi

    # Acquire lock
    acquire_lock
    trap 'release_lock' EXIT INT TERM

    # Check prerequisites
    log_section "Checking prerequisites"
    check_prerequisites

    # Check disk space on backup root
    check_disk_space "$BACKUP_ROOT" "${DUMP_MIN_SPACE_MB:-500}" || \
        log_warn "Low disk space — backup may fail if dumps are large"

    # Setup email if needed
    setup_msmtp_if_needed

    # Initialize repository if requested
    if $DO_INIT; then
        log_section "Initializing restic repository"
        restic_init_repo || die "Failed to initialize restic repository"
    fi

    # Pre-check: verify SFTP connectivity before doing expensive dumps
    log_section "Pre-flight checks"
    if ! restic_check_connectivity; then
        notify_failure "connectivity" "Cannot reach restic repository via SFTP"
        healthcheck_ping "fail" "Cannot reach restic repository via SFTP"
        die "Repository not reachable — aborting before database dumps"
    fi

    # Phase 1: Cleanup old dumps (before new dumps to free disk space)
    log_section "Phase 1: Cleanup old dumps"
    cleanup_old_dumps

    # Phase 2: Database dumps
    local db_errors=0
    if [[ "${DOCKER_ENABLED:-yes}" == "yes" ]] || [[ "${HOST_DB_ENABLED:-no}" == "yes" ]]; then
        log_section "Phase 2: Database dumps"
        run_all_dumps || db_errors=$?

        if [[ $db_errors -gt 0 ]]; then
            log_error "Some database dumps failed"
            # Continue with backup — partial dumps are better than no backup
        fi
    else
        log_info "No database sources configured, skipping dumps"
    fi

    # Phase 3: Restic backup
    log_section "Phase 3: Restic backup"
    if ! restic_backup; then
        notify_failure "restic backup" "Restic backup command failed"
        healthcheck_ping "fail" "Restic backup command failed"
        die "Restic backup failed"
    fi

    # Phase 4: Retention policy
    log_section "Phase 4: Retention policy"
    if ! restic_forget_prune; then
        log_warn "Retention policy failed — backup data is safe but old snapshots may not be pruned"
    fi

    # Phase 5: Verification
    log_section "Phase 5: Verification"
    if ! restic_verify; then
        log_warn "Post-backup verification reported issues"
    fi

    # Final report
    log_section "Backup complete"
    local elapsed
    elapsed=$(get_elapsed)
    log_info "Duration: $elapsed"

    # Snapshot stats
    restic_report_stats 2>/dev/null || true

    # Sync recovery metadata to gateway (password, config, SSH key)
    sync_meta_to_gateway || true

    if has_errors; then
        log_warn "Completed with errors:"
        get_error_summary | while IFS= read -r err; do
            log_warn "  - $err"
        done
        notify_failure "partial" "Backup completed with some errors. See log for details."
        healthcheck_ping "fail"
    else
        log_info "All operations completed successfully"
        local snapshot_info
        snapshot_info=$(restic_latest_snapshot_info 2>/dev/null || echo "N/A")
        notify_success "$snapshot_info"
        healthcheck_ping "success"
    fi
}

# ──────────────────────────────────────────────
# Run
# ──────────────────────────────────────────────
main "$@"
