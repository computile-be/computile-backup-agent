#!/usr/bin/env bash
# common.sh — Logging, error handling, utility functions
# Part of computile-backup-agent

# Guard against double-sourcing
[[ -n "${_COMMON_SH_LOADED:-}" ]] && return 0
_COMMON_SH_LOADED=1

# ──────────────────────────────────────────────
# Globals (set after config is loaded)
# ──────────────────────────────────────────────
BACKUP_START_TIME=""
BACKUP_ERRORS=()
BACKUP_WARNINGS=()
TEMP_DIRS_TO_CLEAN=()

# ──────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local msg="[$ts] [$level] $*"

    # Always write to stdout
    echo "$msg"

    # Write to log file if configured
    if [[ -n "${LOG_FILE:-}" ]]; then
        echo "$msg" >> "$LOG_FILE"
    fi
}

log_info()    { _log "INFO"    "$@"; }
log_warn()    { _log "WARN"    "$@"; BACKUP_WARNINGS+=("$*"); }
log_error()   { _log "ERROR"   "$@"; BACKUP_ERRORS+=("$*"); }
log_debug()   {
    if [[ "${VERBOSE:-no}" == "yes" ]]; then
        _log "DEBUG" "$@"
    fi
}
log_section() { _log "INFO" "──── $* ────"; }

# ──────────────────────────────────────────────
# Error handling
# ──────────────────────────────────────────────
die() {
    log_error "$@"
    exit 1
}

# Run a command and log its output; return its exit code
run_cmd() {
    local description="$1"; shift
    log_debug "Running: $*"

    local output
    local rc=0
    output=$("$@" 2>&1) || rc=$?

    if [[ $rc -ne 0 ]]; then
        log_error "$description failed (exit code $rc)"
        if [[ -n "$output" ]]; then
            log_error "Output: $output"
        fi
    else
        if [[ -n "$output" ]] && [[ "${VERBOSE:-no}" == "yes" ]]; then
            log_debug "Output: $output"
        fi
    fi

    return $rc
}

# ──────────────────────────────────────────────
# Temporary directory management
# ──────────────────────────────────────────────
create_temp_dir() {
    local name="${1:-backup}"
    local dir="${BACKUP_ROOT:?BACKUP_ROOT not set}/tmp/${name}"
    mkdir -p "$dir"
    TEMP_DIRS_TO_CLEAN+=("$dir")
    echo "$dir"
}

cleanup_temp_dirs() {
    for dir in "${TEMP_DIRS_TO_CLEAN[@]}"; do
        if [[ -d "$dir" ]]; then
            log_debug "Cleaning up temp dir: $dir"
            rm -rf "$dir"
        fi
    done
    TEMP_DIRS_TO_CLEAN=()
}

# ──────────────────────────────────────────────
# Backup state
# ──────────────────────────────────────────────
start_timer() {
    BACKUP_START_TIME=$(date +%s)
}

get_elapsed() {
    local now
    now=$(date +%s)
    local elapsed=$(( now - BACKUP_START_TIME ))
    printf '%dm%02ds' $((elapsed / 60)) $((elapsed % 60))
}

has_errors() {
    [[ ${#BACKUP_ERRORS[@]} -gt 0 ]]
}

get_error_summary() {
    local IFS=$'\n'
    echo "${BACKUP_ERRORS[*]}"
}

get_warning_summary() {
    local IFS=$'\n'
    echo "${BACKUP_WARNINGS[*]}"
}

# ──────────────────────────────────────────────
# Config helpers
# ──────────────────────────────────────────────
load_config() {
    local config_file="$1"

    if [[ ! -f "$config_file" ]]; then
        die "Configuration file not found: $config_file"
    fi

    # shellcheck source=/dev/null
    source "$config_file"

    # Validate required fields
    local required_vars=(
        CLIENT_ID HOST_ID
        RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
        BACKUP_ROOT LOG_FILE
    )
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            die "Required config variable not set: $var"
        fi
    done

    # Set defaults for optional fields
    RETENTION_KEEP_DAILY="${RETENTION_KEEP_DAILY:-7}"
    RETENTION_KEEP_WEEKLY="${RETENTION_KEEP_WEEKLY:-4}"
    RETENTION_KEEP_MONTHLY="${RETENTION_KEEP_MONTHLY:-6}"
    DOCKER_ENABLED="${DOCKER_ENABLED:-yes}"
    DOCKER_DB_AUTO_DISCOVERY="${DOCKER_DB_AUTO_DISCOVERY:-yes}"
    MYSQL_DUMP_ENABLED="${MYSQL_DUMP_ENABLED:-yes}"
    POSTGRES_DUMP_ENABLED="${POSTGRES_DUMP_ENABLED:-yes}"
    REDIS_SNAPSHOT_ENABLED="${REDIS_SNAPSHOT_ENABLED:-no}"
    EMAIL_ENABLED="${EMAIL_ENABLED:-no}"
    EMAIL_ON_SUCCESS="${EMAIL_ON_SUCCESS:-no}"
    VERBOSE="${VERBOSE:-no}"
    DRY_RUN="${DRY_RUN:-no}"
    VERIFY_AFTER_BACKUP="${VERIFY_AFTER_BACKUP:-yes}"
    ENVIRONMENT="${ENVIRONMENT:-prod}"
    ROLE="${ROLE:-server}"

    # Ensure directories exist
    mkdir -p "$BACKUP_ROOT" "$(dirname "$LOG_FILE")"
}

# Read the first line of a file (for password files)
read_secret_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        die "Secret file not found: $file"
    fi
    head -n 1 "$file"
}

# ──────────────────────────────────────────────
# Lockfile
# ──────────────────────────────────────────────
LOCKFILE="/var/run/computile-backup.lock"

acquire_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        local pid
        pid=$(cat "$LOCKFILE" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            die "Another backup is already running (PID $pid)"
        fi
        log_warn "Stale lockfile found, removing"
        rm -f "$LOCKFILE"
    fi
    echo $$ > "$LOCKFILE"
}

release_lock() {
    rm -f "$LOCKFILE"
}

# ──────────────────────────────────────────────
# Prerequisite checks
# ──────────────────────────────────────────────
check_prerequisites() {
    local missing=()

    if ! command -v restic &>/dev/null; then
        missing+=("restic")
    fi

    if [[ "${DOCKER_ENABLED:-yes}" == "yes" ]] && ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi

    if [[ "${EMAIL_ENABLED:-no}" == "yes" ]] && ! command -v msmtp &>/dev/null; then
        missing+=("msmtp")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi

    # Check restic password file
    if [[ ! -f "${RESTIC_PASSWORD_FILE:-}" ]]; then
        die "Restic password file not found: ${RESTIC_PASSWORD_FILE:-<not set>}"
    fi
}
