#!/usr/bin/env bash
# docker.sh — Docker container detection and inspection
# Part of computile-backup-agent

[[ -n "${_DOCKER_SH_LOADED:-}" ]] && return 0
_DOCKER_SH_LOADED=1

# ──────────────────────────────────────────────
# Container discovery
# ──────────────────────────────────────────────

# List all running containers as JSON (one per line)
list_running_containers() {
    docker ps --no-trunc --format '{{.ID}}' 2>/dev/null
}

# Get a container's image name (without tag)
get_container_image() {
    local container_id="$1"
    docker inspect --format '{{.Config.Image}}' "$container_id" 2>/dev/null | cut -d: -f1
}

# Get a container's name
get_container_name() {
    local container_id="$1"
    docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||'
}

# Get an environment variable from a container
get_container_env() {
    local container_id="$1"
    local var_name="$2"
    docker inspect --format "{{range .Config.Env}}{{println .}}{{end}}" "$container_id" 2>/dev/null \
        | grep "^${var_name}=" \
        | head -1 \
        | cut -d= -f2-
}

# Get container labels as key=value lines
get_container_labels() {
    local container_id="$1"
    docker inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println ""}}{{end}}' "$container_id" 2>/dev/null
}

# ──────────────────────────────────────────────
# Database container detection
# ──────────────────────────────────────────────

# Known DB image patterns
readonly MYSQL_IMAGE_PATTERNS="mysql mariadb"
readonly POSTGRES_IMAGE_PATTERNS="postgres postgresql"
readonly REDIS_IMAGE_PATTERNS="redis"

# Check if image matches a DB type
_image_matches() {
    local image="$1"
    shift
    local patterns=("$@")
    local image_lower
    image_lower=$(echo "$image" | tr '[:upper:]' '[:lower:]')

    for pattern in "${patterns[@]}"; do
        if [[ "$image_lower" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

detect_db_type() {
    local image="$1"
    # shellcheck disable=SC2086
    if _image_matches "$image" $MYSQL_IMAGE_PATTERNS; then
        echo "mysql"
    elif _image_matches "$image" $POSTGRES_IMAGE_PATTERNS; then
        echo "postgres"
    elif _image_matches "$image" $REDIS_IMAGE_PATTERNS; then
        echo "redis"
    else
        echo ""
    fi
}

# Discover all running DB containers
# Output: lines of "container_id|container_name|db_type|image"
discover_db_containers() {
    local containers
    containers=$(list_running_containers) || return 0

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue

        local image name db_type
        image=$(get_container_image "$cid")
        name=$(get_container_name "$cid")
        db_type=$(detect_db_type "$image")

        if [[ -n "$db_type" ]]; then
            echo "${cid}|${name}|${db_type}|${image}"
        fi
    done <<< "$containers"
}

# ──────────────────────────────────────────────
# MySQL/MariaDB credential extraction
# ──────────────────────────────────────────────

# Try to extract MySQL root password from container environment
get_mysql_password() {
    local container_id="$1"

    # Try common env vars in order of preference
    local env_vars=(
        "MYSQL_ROOT_PASSWORD"
        "MARIADB_ROOT_PASSWORD"
        "MYSQL_PASSWORD"
        "MARIADB_PASSWORD"
    )

    for var in "${env_vars[@]}"; do
        local val
        val=$(get_container_env "$container_id" "$var")
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    done

    return 1
}

get_mysql_user() {
    local container_id="$1"

    # Check if a non-root user is configured
    local user
    user=$(get_container_env "$container_id" "MYSQL_USER")
    if [[ -z "$user" ]]; then
        user=$(get_container_env "$container_id" "MARIADB_USER")
    fi

    # If a root password is set, prefer root
    if get_container_env "$container_id" "MYSQL_ROOT_PASSWORD" &>/dev/null || \
       get_container_env "$container_id" "MARIADB_ROOT_PASSWORD" &>/dev/null; then
        echo "root"
        return 0
    fi

    if [[ -n "$user" ]]; then
        echo "$user"
        return 0
    fi

    echo "root"
}

# ──────────────────────────────────────────────
# PostgreSQL credential extraction
# ──────────────────────────────────────────────

get_postgres_user() {
    local container_id="$1"
    local user
    user=$(get_container_env "$container_id" "POSTGRES_USER")
    echo "${user:-postgres}"
}

get_postgres_databases() {
    local container_id="$1"
    local user
    user=$(get_postgres_user "$container_id")

    # List non-template databases
    docker exec "$container_id" \
        psql -U "$user" -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres';" \
        2>/dev/null | grep -v '^$'
}

# ──────────────────────────────────────────────
# Manual container configuration
# ──────────────────────────────────────────────

# Parse manual DB entries from config
# Format: MANUAL_DBS array with entries like:
#   "container_name|db_type|user|password|databases"
parse_manual_db_entry() {
    local entry="$1"
    local IFS='|'
    read -r container_name db_type db_user db_password db_databases <<< "$entry"
    echo "CONTAINER=$container_name"
    echo "DB_TYPE=$db_type"
    echo "DB_USER=$db_user"
    echo "DB_PASSWORD=$db_password"
    echo "DB_DATABASES=$db_databases"
}

# Resolve a container name/pattern to a running container ID
resolve_container() {
    local name_or_id="$1"

    # Try exact match first
    local cid
    cid=$(docker ps -q --filter "name=^/${name_or_id}$" 2>/dev/null | head -1)

    if [[ -z "$cid" ]]; then
        # Try partial match
        cid=$(docker ps -q --filter "name=${name_or_id}" 2>/dev/null | head -1)
    fi

    if [[ -z "$cid" ]]; then
        # Try as container ID
        if docker inspect "$name_or_id" &>/dev/null; then
            cid="$name_or_id"
        fi
    fi

    echo "$cid"
}

# Execute a command inside a container
docker_exec() {
    local container_id="$1"; shift
    docker exec "$container_id" "$@"
}
