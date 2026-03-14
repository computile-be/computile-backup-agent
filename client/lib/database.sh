#!/usr/bin/env bash
# database.sh — Database dump logic (MySQL/MariaDB, PostgreSQL, Redis)
# Part of computile-backup-agent

[[ -n "${_DATABASE_SH_LOADED:-}" ]] && return 0
_DATABASE_SH_LOADED=1

# ──────────────────────────────────────────────
# Dump directory setup
# ──────────────────────────────────────────────
DB_DUMP_DIR=""

setup_dump_dirs() {
    DB_DUMP_DIR="${BACKUP_ROOT}/db"
    mkdir -p "${DB_DUMP_DIR}/mysql" "${DB_DUMP_DIR}/postgres" "${DB_DUMP_DIR}/redis"
    log_info "Database dump directory: $DB_DUMP_DIR"

    # Check available disk space (minimum 500MB for dumps)
    if ! check_disk_space "$DB_DUMP_DIR" "${DUMP_MIN_SPACE_MB:-500}"; then
        log_error "Insufficient disk space for database dumps"
        return 1
    fi
}

get_dump_dir() {
    echo "$DB_DUMP_DIR"
}

# ──────────────────────────────────────────────
# Timestamp for dump filenames
# ──────────────────────────────────────────────
_dump_timestamp() {
    date '+%Y-%m-%dT%H-%M-%S'
}

# ──────────────────────────────────────────────
# MySQL / MariaDB dumps
# ──────────────────────────────────────────────
dump_mysql() {
    local container_id="$1"
    local container_name="$2"
    local db_user="${3:-}"
    local db_password="${4:-}"
    local db_names="${5:-}"  # comma-separated, empty = all

    if [[ "${MYSQL_DUMP_ENABLED:-yes}" != "yes" ]]; then
        log_debug "MySQL dumps disabled, skipping $container_name"
        return 0
    fi

    log_info "Dumping MySQL/MariaDB from container: $container_name"

    # Detect client binaries (MariaDB 11+ dropped mysql/mysqldump symlinks)
    local mysql_bin="mysql"
    local mysqldump_bin="mysqldump"
    if docker exec "$container_id" which mariadb &>/dev/null; then
        mysql_bin="mariadb"
    fi
    if docker exec "$container_id" which mariadb-dump &>/dev/null; then
        mysqldump_bin="mariadb-dump"
    fi
    log_debug "Using client binaries: $mysql_bin / $mysqldump_bin"

    # Auto-detect credentials if not provided
    if [[ -z "$db_user" ]]; then
        db_user=$(get_mysql_user "$container_id")
    fi
    if [[ -z "$db_password" ]]; then
        db_password=$(get_mysql_password "$container_id") || true
    fi

    # Build auth args (use MYSQL_PWD env var to avoid password in process list)
    local docker_env_args=()
    if [[ -n "$db_password" ]]; then
        docker_env_args+=("-e" "MYSQL_PWD=${db_password}")
    fi

    # Determine databases to dump
    local databases=()
    if [[ -n "$db_names" ]]; then
        IFS=',' read -ra databases <<< "$db_names"
    else
        # List all databases, excluding system ones
        local db_list
        db_list=$(docker exec ${docker_env_args[@]+"${docker_env_args[@]}"} "$container_id" \
            "$mysql_bin" -u "$db_user" -N -e "SHOW DATABASES;" 2>/dev/null \
            | grep -Ev '^(information_schema|performance_schema|mysql|sys)$') || {
            log_error "Failed to list databases in container $container_name"
            return 1
        }
        while IFS= read -r db; do
            [[ -n "$db" ]] && databases+=("$db")
        done <<< "$db_list"
    fi

    if [[ ${#databases[@]} -eq 0 ]]; then
        log_warn "No databases found to dump in $container_name"
        return 0
    fi

    local ts
    ts=$(_dump_timestamp)
    local errors=0

    for db in "${databases[@]}"; do
        local safe_name
        safe_name=$(sanitize_filename "${container_name}_${db}")
        local dump_file="${DB_DUMP_DIR}/mysql/${safe_name}_${ts}.sql.gz"
        log_info "  Dumping database: $db → $(basename "$dump_file")"

        if [[ "${DRY_RUN:-no}" == "yes" ]]; then
            log_info "  [DRY RUN] Would dump $db from $container_name"
            continue
        fi

        if docker exec ${docker_env_args[@]+"${docker_env_args[@]}"} "$container_id" \
            "$mysqldump_bin" -u "$db_user" \
            --single-transaction \
            --routines \
            --triggers \
            --events \
            "$db" 2>/dev/null \
            | gzip > "$dump_file"; then

            # Verify dump is not empty (gzip creates the file even if mysqldump fails)
            if [[ ! -s "$dump_file" ]]; then
                log_error "  Dump file is empty: $db from $container_name"
                rm -f "$dump_file"
                ((errors++))
                continue
            fi

            local size
            size=$(du -h "$dump_file" | cut -f1)
            log_info "  Dump complete: $db ($size)"
        else
            log_error "  Failed to dump database: $db from $container_name"
            rm -f "$dump_file"
            ((errors++))
        fi
    done

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# ──────────────────────────────────────────────
# PostgreSQL dumps
# ──────────────────────────────────────────────
dump_postgres() {
    local container_id="$1"
    local container_name="$2"
    local db_user="${3:-}"
    local db_password="${4:-}"
    local db_names="${5:-}"  # comma-separated, empty = auto-detect

    if [[ "${POSTGRES_DUMP_ENABLED:-yes}" != "yes" ]]; then
        log_debug "PostgreSQL dumps disabled, skipping $container_name"
        return 0
    fi

    log_info "Dumping PostgreSQL from container: $container_name"

    # Auto-detect user if not provided
    if [[ -z "$db_user" ]]; then
        db_user=$(get_postgres_user "$container_id")
    fi

    # Determine databases to dump
    local databases=()
    if [[ -n "$db_names" ]]; then
        IFS=',' read -ra databases <<< "$db_names"
    else
        local db_list
        db_list=$(get_postgres_databases "$container_id") || {
            log_error "Failed to list databases in container $container_name"
            return 1
        }
        while IFS= read -r db; do
            [[ -n "$db" ]] && databases+=("$db")
        done <<< "$db_list"
    fi

    if [[ ${#databases[@]} -eq 0 ]]; then
        log_warn "No databases found to dump in $container_name"
        return 0
    fi

    local ts
    ts=$(_dump_timestamp)
    local errors=0

    for db in "${databases[@]}"; do
        local safe_name
        safe_name=$(sanitize_filename "${container_name}_${db}")
        local dump_file="${DB_DUMP_DIR}/postgres/${safe_name}_${ts}.sql.gz"
        log_info "  Dumping database: $db → $(basename "$dump_file")"

        if [[ "${DRY_RUN:-no}" == "yes" ]]; then
            log_info "  [DRY RUN] Would dump $db from $container_name"
            continue
        fi

        if docker exec "$container_id" \
            pg_dump -U "$db_user" "$db" 2>/dev/null \
            | gzip > "$dump_file"; then

            # Verify dump is not empty (gzip creates the file even if pg_dump fails)
            if [[ ! -s "$dump_file" ]]; then
                log_error "  Dump file is empty: $db from $container_name"
                rm -f "$dump_file"
                ((errors++))
                continue
            fi

            local size
            size=$(du -h "$dump_file" | cut -f1)
            log_info "  Dump complete: $db ($size)"
        else
            log_error "  Failed to dump database: $db from $container_name"
            rm -f "$dump_file"
            ((errors++))
        fi
    done

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# ──────────────────────────────────────────────
# Redis snapshots
# ──────────────────────────────────────────────
dump_redis() {
    local container_id="$1"
    local container_name="$2"

    if [[ "${REDIS_SNAPSHOT_ENABLED:-no}" != "yes" ]]; then
        log_debug "Redis snapshots disabled, skipping $container_name"
        return 0
    fi

    log_info "Snapshotting Redis from container: $container_name"

    if [[ "${DRY_RUN:-no}" == "yes" ]]; then
        log_info "  [DRY RUN] Would snapshot Redis from $container_name"
        return 0
    fi

    # Trigger BGSAVE
    log_info "  Triggering BGSAVE..."
    if ! docker exec "$container_id" redis-cli BGSAVE 2>/dev/null; then
        log_error "  Failed to trigger BGSAVE in $container_name"
        return 1
    fi

    # Wait for BGSAVE to complete (max 60 seconds)
    local waited=0
    while [[ $waited -lt 60 ]]; do
        local lastsave_status
        lastsave_status=$(docker exec "$container_id" redis-cli LASTSAVE 2>/dev/null) || break
        local bgsave_status
        bgsave_status=$(docker exec "$container_id" redis-cli INFO persistence 2>/dev/null \
            | grep "rdb_bgsave_in_progress" | cut -d: -f2 | tr -d '\r')

        if [[ "$bgsave_status" == "0" ]]; then
            break
        fi
        sleep 2
        ((waited += 2))
    done

    if [[ $waited -ge 60 ]]; then
        log_warn "  BGSAVE did not complete within 60s for $container_name"
    fi

    # Find and copy the dump.rdb file
    local rdb_path
    rdb_path=$(docker exec "$container_id" redis-cli CONFIG GET dir 2>/dev/null | tail -1 | tr -d '\r')
    local rdb_file="${rdb_path:-/data}/dump.rdb"

    local ts
    ts=$(_dump_timestamp)
    local safe_name
    safe_name=$(sanitize_filename "$container_name")
    local dump_file="${DB_DUMP_DIR}/redis/${safe_name}_${ts}.rdb"

    if docker cp "${container_id}:${rdb_file}" "$dump_file" 2>/dev/null; then
        local size
        size=$(du -h "$dump_file" | cut -f1)
        log_info "  Redis snapshot complete: $(basename "$dump_file") ($size)"
    else
        log_error "  Failed to copy Redis dump from $container_name"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────
# Host-level MySQL / MariaDB dumps (non-Docker)
# ──────────────────────────────────────────────
dump_mysql_host() {
    local db_user="${1:-root}"
    local db_password="${2:-}"
    local db_names="${3:-}"  # comma-separated, empty = all

    if [[ "${MYSQL_DUMP_ENABLED:-yes}" != "yes" ]]; then
        log_debug "MySQL dumps disabled, skipping host databases"
        return 0
    fi

    # Detect client binaries
    local mysql_bin="mysql"
    local mysqldump_bin="mysqldump"
    if command -v mariadb &>/dev/null; then
        mysql_bin="mariadb"
    fi
    if command -v mariadb-dump &>/dev/null; then
        mysqldump_bin="mariadb-dump"
    fi

    if ! command -v "$mysqldump_bin" &>/dev/null; then
        log_debug "No mysqldump/mariadb-dump binary found on host, skipping"
        return 0
    fi

    log_info "Dumping MySQL/MariaDB from host"

    # Set password via env var to avoid process list exposure
    local env_prefix=()
    if [[ -n "$db_password" ]]; then
        env_prefix=("env" "MYSQL_PWD=${db_password}")
    fi

    # Determine databases to dump
    local databases=()
    if [[ -n "$db_names" ]]; then
        IFS=',' read -ra databases <<< "$db_names"
    else
        local db_list
        db_list=$("${env_prefix[@]}" "$mysql_bin" -u "$db_user" -N -e "SHOW DATABASES;" 2>/dev/null \
            | grep -Ev '^(information_schema|performance_schema|mysql|sys)$') || {
            log_error "Failed to list host MySQL databases"
            return 1
        }
        while IFS= read -r db; do
            [[ -n "$db" ]] && databases+=("$db")
        done <<< "$db_list"
    fi

    if [[ ${#databases[@]} -eq 0 ]]; then
        log_warn "No host MySQL databases found to dump"
        return 0
    fi

    local ts
    ts=$(_dump_timestamp)
    local errors=0

    for db in "${databases[@]}"; do
        local safe_db
        safe_db=$(sanitize_filename "$db")
        local dump_file="${DB_DUMP_DIR}/mysql/host_${safe_db}_${ts}.sql.gz"
        log_info "  Dumping database: $db → $(basename "$dump_file")"

        if [[ "${DRY_RUN:-no}" == "yes" ]]; then
            log_info "  [DRY RUN] Would dump host database $db"
            continue
        fi

        if "${env_prefix[@]}" "$mysqldump_bin" -u "$db_user" \
            --single-transaction \
            --routines \
            --triggers \
            --events \
            "$db" 2>/dev/null \
            | gzip > "$dump_file"; then

            if [[ ! -s "$dump_file" ]]; then
                log_error "  Dump file is empty: $db (host)"
                rm -f "$dump_file"
                ((errors++))
                continue
            fi

            local size
            size=$(du -h "$dump_file" | cut -f1)
            log_info "  Dump complete: $db ($size)"
        else
            log_error "  Failed to dump host database: $db"
            rm -f "$dump_file"
            ((errors++))
        fi
    done

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# ──────────────────────────────────────────────
# Host-level PostgreSQL dumps (non-Docker)
# ──────────────────────────────────────────────
dump_postgres_host() {
    local db_user="${1:-postgres}"
    local db_names="${2:-}"  # comma-separated, empty = all

    if [[ "${POSTGRES_DUMP_ENABLED:-yes}" != "yes" ]]; then
        log_debug "PostgreSQL dumps disabled, skipping host databases"
        return 0
    fi

    if ! command -v pg_dump &>/dev/null; then
        log_debug "No pg_dump binary found on host, skipping"
        return 0
    fi

    log_info "Dumping PostgreSQL from host"

    # Determine databases to dump
    local databases=()
    if [[ -n "$db_names" ]]; then
        IFS=',' read -ra databases <<< "$db_names"
    else
        local db_list
        db_list=$(sudo -u "$db_user" psql -t -A \
            -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" \
            2>/dev/null | grep -v '^$') || {
            log_error "Failed to list host PostgreSQL databases"
            return 1
        }
        while IFS= read -r db; do
            [[ -n "$db" ]] && databases+=("$db")
        done <<< "$db_list"
    fi

    if [[ ${#databases[@]} -eq 0 ]]; then
        log_warn "No host PostgreSQL databases found to dump"
        return 0
    fi

    local ts
    ts=$(_dump_timestamp)
    local errors=0

    for db in "${databases[@]}"; do
        local safe_db
        safe_db=$(sanitize_filename "$db")
        local dump_file="${DB_DUMP_DIR}/postgres/host_${safe_db}_${ts}.sql.gz"
        log_info "  Dumping database: $db → $(basename "$dump_file")"

        if [[ "${DRY_RUN:-no}" == "yes" ]]; then
            log_info "  [DRY RUN] Would dump host database $db"
            continue
        fi

        if sudo -u "$db_user" pg_dump "$db" 2>/dev/null \
            | gzip > "$dump_file"; then

            if [[ ! -s "$dump_file" ]]; then
                log_error "  Dump file is empty: $db (host)"
                rm -f "$dump_file"
                ((errors++))
                continue
            fi

            local size
            size=$(du -h "$dump_file" | cut -f1)
            log_info "  Dump complete: $db ($size)"
        else
            log_error "  Failed to dump host database: $db"
            rm -f "$dump_file"
            ((errors++))
        fi
    done

    [[ $errors -gt 0 ]] && return 1
    return 0
}

# ──────────────────────────────────────────────
# Main dump orchestrator
# ──────────────────────────────────────────────
run_all_dumps() {
    setup_dump_dirs

    local total_errors=0

    # Auto-discovery mode (Docker containers)
    if [[ "${DOCKER_DB_AUTO_DISCOVERY:-yes}" == "yes" ]] && [[ "${DOCKER_ENABLED:-yes}" == "yes" ]]; then
        log_section "Auto-discovering database containers"

        local discovered
        discovered=$(discover_db_containers) || true

        if [[ -z "$discovered" ]]; then
            log_info "No database containers discovered"
        else
            while IFS='|' read -r cid cname db_type image; do
                [[ -z "$cid" ]] && continue
                log_info "Found $db_type container: $cname ($image)"

                case "$db_type" in
                    mysql)
                        dump_mysql "$cid" "$cname" "" "" "" || ((total_errors++)) || true
                        ;;
                    postgres)
                        dump_postgres "$cid" "$cname" "" "" "" || ((total_errors++)) || true
                        ;;
                    redis)
                        dump_redis "$cid" "$cname" || ((total_errors++)) || true
                        ;;
                esac
            done <<< "$discovered"
        fi
    fi

    # Manual mode: process MANUAL_DBS array if defined
    if [[ -n "${MANUAL_DBS+x}" ]] && [[ ${#MANUAL_DBS[@]} -gt 0 ]]; then
        log_section "Processing manually configured databases"

        for entry in "${MANUAL_DBS[@]}"; do
            local CONTAINER DB_TYPE DB_USER DB_PASSWORD DB_DATABASES
            IFS='|' read -r CONTAINER DB_TYPE DB_USER DB_PASSWORD DB_DATABASES <<< "$entry"

            local cid
            cid=$(resolve_container "$CONTAINER")
            if [[ -z "$cid" ]]; then
                log_error "Manual DB container not found: $CONTAINER"
                ((total_errors++))
                continue
            fi

            local cname
            cname=$(get_container_name "$cid")
            log_info "Manual entry: $cname (type: $DB_TYPE)"

            case "$DB_TYPE" in
                mysql|mariadb)
                    dump_mysql "$cid" "$cname" "$DB_USER" "$DB_PASSWORD" "$DB_DATABASES" \
                        || ((total_errors++)) || true
                    ;;
                postgres|postgresql)
                    dump_postgres "$cid" "$cname" "$DB_USER" "$DB_PASSWORD" "$DB_DATABASES" \
                        || ((total_errors++)) || true
                    ;;
                redis)
                    dump_redis "$cid" "$cname" || ((total_errors++)) || true
                    ;;
                *)
                    log_error "Unknown DB type: $DB_TYPE for container $CONTAINER"
                    ((total_errors++))
                    ;;
            esac
        done
    fi

    # Host-level database dumps (Forge, bare metal, etc.)
    if [[ "${HOST_DB_ENABLED:-no}" == "yes" ]]; then
        log_section "Dumping host-level databases"

        if [[ "${MYSQL_DUMP_ENABLED:-yes}" == "yes" ]]; then
            local host_mysql_user="${HOST_MYSQL_USER:-root}"
            local host_mysql_password=""
            if [[ -n "${HOST_MYSQL_PASS_FILE:-}" ]] && [[ -f "$HOST_MYSQL_PASS_FILE" ]]; then
                host_mysql_password=$(read_secret_file "$HOST_MYSQL_PASS_FILE")
            fi
            dump_mysql_host "$host_mysql_user" "$host_mysql_password" "${HOST_MYSQL_DATABASES:-}" \
                || ((total_errors++)) || true
        fi

        if [[ "${POSTGRES_DUMP_ENABLED:-yes}" == "yes" ]]; then
            dump_postgres_host "${HOST_POSTGRES_USER:-postgres}" "${HOST_POSTGRES_DATABASES:-}" \
                || ((total_errors++)) || true
        fi
    fi

    # Report
    if [[ $total_errors -gt 0 ]]; then
        log_error "Database dumps completed with $total_errors error(s)"
        return 1
    else
        log_info "Database dumps completed successfully"
        return 0
    fi
}

# ──────────────────────────────────────────────
# Cleanup old dumps (keep only current session)
# ──────────────────────────────────────────────
cleanup_old_dumps() {
    local max_age_days="${DUMP_CLEANUP_DAYS:-3}"

    if [[ -d "$DB_DUMP_DIR" ]]; then
        log_info "Cleaning up dumps older than ${max_age_days} days"
        find "$DB_DUMP_DIR" -type f \( -name "*.sql.gz" -o -name "*.rdb" \) \
            -mtime +"$max_age_days" -delete 2>/dev/null || true
    fi
}
