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

readonly AGENT_VERSION="1.0.0"
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
  --version           Show version
  --help, -h          Show this help

Examples:
  computile-backup                          # Run with default config
  computile-backup --config /path/to/conf   # Run with custom config
  computile-backup --init                   # Initialize repo and run backup
  computile-backup --dry-run --verbose      # Test run with debug output
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
# Main backup procedure
# ──────────────────────────────────────────────
main() {
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

    # Phase 1: Database dumps
    local db_errors=0
    if [[ "${DOCKER_ENABLED:-yes}" == "yes" ]] || [[ "${HOST_DB_ENABLED:-no}" == "yes" ]]; then
        log_section "Phase 1: Database dumps"
        run_all_dumps || db_errors=$?

        if [[ $db_errors -gt 0 ]]; then
            log_error "Some database dumps failed ($db_errors errors)"
            # Continue with backup — partial dumps are better than no backup
        fi
    else
        log_info "No database sources configured, skipping dumps"
    fi

    # Phase 2: Restic backup
    log_section "Phase 2: Restic backup"
    if ! restic_backup; then
        notify_failure "restic backup" "Restic backup command failed"
        healthcheck_ping "fail"
        die "Restic backup failed"
    fi

    # Phase 3: Retention policy
    log_section "Phase 3: Retention policy"
    if ! restic_forget_prune; then
        log_warn "Retention policy failed — backup data is safe but old snapshots may not be pruned"
    fi

    # Phase 4: Verification
    log_section "Phase 4: Verification"
    if ! restic_verify; then
        log_warn "Post-backup verification reported issues"
    fi

    # Phase 5: Cleanup old dumps
    log_section "Phase 5: Cleanup"
    cleanup_old_dumps

    # Final report
    log_section "Backup complete"
    local elapsed
    elapsed=$(get_elapsed)
    log_info "Duration: $elapsed"

    # Snapshot stats
    restic_report_stats 2>/dev/null || true

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
