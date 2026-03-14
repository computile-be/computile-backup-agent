#!/usr/bin/env bash
# ================================================================
# computile-backup — Restore Test Tool
#
# Orchestrates a full backup restore on a fresh VM to validate
# that backups are functional end-to-end.
#
# Runs from the gateway, connects to target VM via SSH/Tailscale,
# restores files, platform (Coolify), databases, and verifies.
#
# Usage:
#   sudo computile-restore-test --interactive
#   sudo computile-restore-test --client X --vps Y --target Z
# ================================================================
set -euo pipefail

# ──────────────────────────────────────────────
# Constants & defaults
# ──────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
BACKUP_BASE="/srv/backups"
readonly GATEWAY_CONFIG="/etc/computile-backup/gateway.conf"
readonly DEFAULT_REPORT_DIR="/var/log/computile-backup"

# Parameters (set via CLI or TUI)
CLIENT=""
VPS=""
TARGET=""
SNAPSHOT_ID=""
SSH_USER="root"
SSH_PORT=22
INTERACTIVE=false
SKIP_DB_RESTORE=false
SKIP_CLEANUP=false
DRY_RUN=false
REPORT_DIR="$DEFAULT_REPORT_DIR"

# Runtime state
TEMP_RESTORE_DIR=""
REPORT_FILE=""
REPORT_BUFFER=""
START_TIME=""
ROLE=""
RESTIC_REPOSITORY=""
RESTIC_PASSWORD_FILE=""

# Report counters
COUNT_OK=0
COUNT_KO=0
COUNT_WARN=0
COUNT_SKIP=0

# TUI
DIALOG=""
WT_HEIGHT=36
WT_WIDTH=90
WT_LIST_HEIGHT=20

# ──────────────────────────────────────────────
# Gateway config loading
# ──────────────────────────────────────────────
_load_gateway_config() {
    if [[ -f "$GATEWAY_CONFIG" ]]; then
        # shellcheck source=/dev/null
        source "$GATEWAY_CONFIG" 2>/dev/null || true
    fi
}

# ──────────────────────────────────────────────
# Logging
# ──────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $*"
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }

log_section() {
    echo ""
    echo "══════════════════════════════════════════"
    echo "  $1"
    echo "══════════════════════════════════════════"
    echo ""
}

die() {
    log_error "$@"
    exit 1
}

# ──────────────────────────────────────────────
# Report helpers
# ──────────────────────────────────────────────
report_phase() {
    REPORT_BUFFER+=$'\n'"PHASE $1: $2"$'\n'
}

report_ok() {
    REPORT_BUFFER+="  [OK]   $1"$'\n'
    ((COUNT_OK++)) || true
    log_info "[OK] $1"
}

report_ko() {
    REPORT_BUFFER+="  [KO]   $1"$'\n'
    ((COUNT_KO++)) || true
    log_error "[KO] $1"
}

report_warn() {
    REPORT_BUFFER+="  [WARN] $1"$'\n'
    ((COUNT_WARN++)) || true
    log_warn "[WARN] $1"
}

report_skip() {
    REPORT_BUFFER+="  [SKIP] $1"$'\n'
    ((COUNT_SKIP++)) || true
    log_info "[SKIP] $1"
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

_format_duration() {
    local secs=$1
    local mins=$((secs / 60))
    local remaining_secs=$((secs % 60))
    if [[ $mins -gt 0 ]]; then
        printf "%dm %02ds" "$mins" "$remaining_secs"
    else
        printf "%ds" "$remaining_secs"
    fi
}

report_generate() {
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local duration_str
    duration_str=$(_format_duration "$duration")
    local now
    now=$(date '+%Y-%m-%d %H:%M:%S')

    # Determine snapshot display
    local snap_display="$SNAPSHOT_ID"

    # Status line
    local status="OK"
    if [[ $COUNT_KO -gt 0 && $COUNT_OK -gt 0 ]]; then
        status="PARTIAL ($COUNT_KO failure(s))"
    elif [[ $COUNT_KO -gt 0 ]]; then
        status="FAILED"
    fi

    local report=""
    report+="========================================"$'\n'
    report+="COMPUTILE RESTORE TEST REPORT"$'\n'
    report+="========================================"$'\n'
    report+="Date:       $now"$'\n'
    report+="Client:     $CLIENT"$'\n'
    report+="VPS:        $VPS"$'\n'
    report+="Snapshot:   $snap_display"$'\n'
    report+="Target:     $TARGET"$'\n'
    report+="Role:       ${ROLE:-unknown}"$'\n'
    report+="Duration:   $duration_str"$'\n'
    report+="----------------------------------------"$'\n'
    report+="$REPORT_BUFFER"
    report+="----------------------------------------"$'\n'
    report+="SUMMARY: $COUNT_OK OK / $COUNT_KO KO / $COUNT_WARN WARN / $COUNT_SKIP SKIP"$'\n'
    report+="STATUS: $status"$'\n'
    report+="========================================"$'\n'

    # Save to file
    mkdir -p "$REPORT_DIR"
    local ts_file
    ts_file=$(date '+%Y%m%d-%H%M%S')
    REPORT_FILE="${REPORT_DIR}/restore-test-${CLIENT}-${VPS}-${ts_file}.log"
    echo "$report" > "$REPORT_FILE"

    echo ""
    echo "$report"
    echo ""
    log_info "Report saved to: $REPORT_FILE"
}

# ──────────────────────────────────────────────
# SSH helpers
# ──────────────────────────────────────────────
_ssh_target() {
    ssh -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=30 \
        -o BatchMode=yes \
        -p "$SSH_PORT" \
        "${SSH_USER}@${TARGET}" "$@"
}

_ssh_target_interactive() {
    # For commands that need a TTY (apt prompts, etc.)
    ssh -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=30 \
        -p "$SSH_PORT" \
        -t \
        "${SSH_USER}@${TARGET}" "$@"
}

_scp_to_target() {
    local src="$1"
    local dest="$2"
    scp -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=30 \
        -P "$SSH_PORT" \
        "$src" "${SSH_USER}@${TARGET}:${dest}"
}

# ──────────────────────────────────────────────
# TUI helpers (for --interactive mode)
# ──────────────────────────────────────────────
_detect_tui() {
    if command -v whiptail &>/dev/null; then
        DIALOG="whiptail"
    elif command -v dialog &>/dev/null; then
        DIALOG="dialog"
    fi

    # Adjust dimensions to terminal
    local lines cols
    lines=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)
    WT_HEIGHT=$((lines - 4))
    WT_WIDTH=$((cols - 10))
    [[ $WT_HEIGHT -gt 40 ]] && WT_HEIGHT=40
    [[ $WT_WIDTH -gt 100 ]] && WT_WIDTH=100
    [[ $WT_HEIGHT -lt 20 ]] && WT_HEIGHT=20
    [[ $WT_WIDTH -lt 60 ]] && WT_WIDTH=60
    WT_LIST_HEIGHT=$((WT_HEIGHT - 8))
}

_msg_box() {
    $DIALOG --title "$1" --msgbox "$2" $WT_HEIGHT $WT_WIDTH
}

_yesno() {
    $DIALOG --title "$1" --yesno "$2" 10 $WT_WIDTH
}

_list_clients() {
    for dir in "${BACKUP_BASE}"/backup-*/; do
        [[ -d "$dir" ]] || continue
        basename "$dir"
    done
}

_tui_select_client() {
    local clients=()
    while IFS= read -r client; do
        [[ -z "$client" ]] && continue
        local display="${client#backup-}"
        clients+=("$display" "$display")
    done < <(_list_clients)

    if [[ ${#clients[@]} -eq 0 ]]; then
        _msg_box "Restore Test" "No backup clients found."
        return 1
    fi

    local choice
    choice=$($DIALOG --title "Restore Test — Select Client" \
        --menu "Choose a client:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${clients[@]}" \
        3>&1 1>&2 2>&3) || return 1

    echo "$choice"
}

_tui_select_vps() {
    local client="$1"
    local data_dir="${BACKUP_BASE}/backup-${client}/data"
    if [[ ! -d "$data_dir" ]]; then
        _msg_box "Restore Test" "No data directory found for client '${client}'."
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
        _msg_box "Restore Test" "No VPS repositories found for client '${client}'."
        return 1
    fi

    local choice
    choice=$($DIALOG --title "Restore Test — Select VPS" \
        --menu "Choose a VPS repository:" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "${entries[@]}" \
        3>&1 1>&2 2>&3) || return 1

    echo "$choice"
}

_tui_select_snapshot() {
    local snap_items=()

    if command -v jq &>/dev/null; then
        local json
        json=$(restic snapshots --json --no-lock 2>/dev/null) || {
            _msg_box "Restore Test — Error" "Failed to list snapshots from repository."
            return 1
        }

        local count
        count=$(echo "$json" | jq 'length')
        if [[ "$count" -eq 0 || "$count" == "null" ]]; then
            _msg_box "Restore Test" "No snapshots found in this repository."
            return 1
        fi

        while IFS=$'\t' read -r sid stime shost; do
            snap_items+=("$sid" "${stime}  ${shost}")
        done < <(echo "$json" | jq -r '.[] | [.short_id, (.time | split(".")[0] | gsub("T";" ")), .hostname] | @tsv')
    else
        local text_output
        text_output=$(restic snapshots --no-lock --compact 2>/dev/null) || {
            _msg_box "Restore Test — Error" "Failed to list snapshots from repository."
            return 1
        }

        while IFS= read -r line; do
            local sid
            sid=$(echo "$line" | awk '{print $1}')
            if [[ "$sid" =~ ^[0-9a-f]{8}$ ]]; then
                local rest
                rest=$(echo "$line" | sed "s/^${sid}[[:space:]]*//" | sed 's/[[:space:]]*$//')
                snap_items+=("$sid" "$rest")
            fi
        done <<< "$text_output"

        if [[ ${#snap_items[@]} -eq 0 ]]; then
            _msg_box "Restore Test" "No snapshots found in this repository."
            return 1
        fi
    fi

    local choice
    choice=$($DIALOG --title "Restore Test — Select Snapshot" \
        --menu "Choose a snapshot (or 'latest'):" $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "latest" "Most recent snapshot" \
        "${snap_items[@]}" \
        3>&1 1>&2 2>&3) || return 1

    echo "$choice"
}

_tui_input_target() {
    local target
    target=$($DIALOG --title "Restore Test — Target VM" \
        --inputbox "Enter the target VM hostname or Tailscale IP:" \
        10 $WT_WIDTH "" \
        3>&1 1>&2 2>&3) || return 1

    echo "$target"
}

_tui_input_ssh_user() {
    local user
    user=$($DIALOG --title "Restore Test — SSH User" \
        --inputbox "SSH user on the target VM:" \
        10 $WT_WIDTH "$SSH_USER" \
        3>&1 1>&2 2>&3) || return 1

    echo "$user"
}

_tui_ssh_key_check() {
    # Find the gateway's SSH public key
    local pub_key=""
    local key_file=""
    for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/id_ecdsa.pub; do
        if [[ -f "$f" ]]; then
            pub_key=$(cat "$f")
            key_file="$f"
            break
        fi
    done

    if [[ -z "$pub_key" ]]; then
        if _yesno "Restore Test — SSH Key" \
            "No SSH public key found on this gateway.\n\nGenerate one now? (ed25519, no passphrase)"; then
            log_info "Generating SSH key..."
            ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N "" -C "computile-gateway-restore" >/dev/null 2>&1
            pub_key=$(cat /root/.ssh/id_ed25519.pub)
            key_file="/root/.ssh/id_ed25519.pub"
            log_info "SSH key generated: $key_file"
        else
            return 1
        fi
    fi

    # Show key info
    local fingerprint
    fingerprint=$(ssh-keygen -lf "$key_file" 2>/dev/null | awk '{print $1, $2, $NF}') || fingerprint="N/A"
    log_info "Gateway SSH key: $key_file"
    log_info "  Fingerprint: $fingerprint"

    # Check if key is already authorized on target
    log_info "Testing SSH connection to ${SSH_USER}@${TARGET}:${SSH_PORT}..."
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
        -p "$SSH_PORT" "${SSH_USER}@${TARGET}" "echo ok" &>/dev/null; then
        log_info "  -> SSH key already authorized on ${SSH_USER}@${TARGET}"
        _msg_box "Restore Test — SSH Key" \
            "SSH key already authorized on ${SSH_USER}@${TARGET}.\n\nKey: ${key_file}\nFingerprint: ${fingerprint}\n\nConnection test: OK"
        return 0
    fi
    log_info "  -> SSH key NOT yet authorized on target"

    # Offer to push key automatically via password
    local choice
    choice=$($DIALOG --title "Restore Test — SSH Key Setup" \
        --menu "SSH key not yet authorized on ${SSH_USER}@${TARGET}.\n\nGateway key: ${key_file}\nFingerprint: ${fingerprint}\n\nHow do you want to set it up?" \
        $WT_HEIGHT $WT_WIDTH $WT_LIST_HEIGHT \
        "password"  "Enter password to copy key automatically" \
        "manual"    "I'll add the key manually" \
        3>&1 1>&2 2>&3) || return 1

    case "$choice" in
        password)
            _push_ssh_key_via_password "$key_file" "$fingerprint"
            ;;
        manual)
            local msg="Add this public key to ${SSH_USER}@${TARGET}:\n\n"
            msg+="Key: ${key_file}\n"
            msg+="Fingerprint: ${fingerprint}\n\n"
            msg+="${pub_key}\n\n"
            msg+="On the target VM, run:\n"
            msg+="  mkdir -p ~/.ssh && echo '${pub_key}' >> ~/.ssh/authorized_keys\n\n"
            msg+="Have you added this key?"

            if ! _yesno "Restore Test — Manual Key Setup" "$msg"; then
                return 1
            fi
            # Verify it works now
            log_info "Verifying SSH connection after manual key setup..."
            if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
                -p "$SSH_PORT" "${SSH_USER}@${TARGET}" "echo ok" &>/dev/null; then
                log_info "  -> Connection verified OK"
                _msg_box "Restore Test" "SSH key verified! Connection to ${SSH_USER}@${TARGET} is working."
            else
                log_error "  -> Connection FAILED after manual key setup"
                _msg_box "Restore Test" "SSH connection still failing. Check the key and try again."
                return 1
            fi
            ;;
    esac
}

_push_ssh_key_via_password() {
    local key_file="$1"
    local fingerprint="$2"

    # Check if sshpass is available, install if needed
    if ! command -v sshpass &>/dev/null; then
        log_info "Installing sshpass..."
        if ! apt-get install -y -qq sshpass &>/dev/null; then
            log_error "Failed to install sshpass"
            _msg_box "Restore Test" "Failed to install sshpass.\nInstall manually: apt install sshpass"
            return 1
        fi
        log_info "  sshpass installed"
    fi

    local password
    password=$($DIALOG --title "Restore Test — SSH Password" \
        --passwordbox "Enter SSH password for ${SSH_USER}@${TARGET}:" \
        10 $WT_WIDTH \
        3>&1 1>&2 2>&3) || return 1

    if [[ -z "$password" ]]; then
        _msg_box "Restore Test" "No password entered."
        return 1
    fi

    # Push key using ssh-copy-id (with 10s timeout)
    log_info "Copying SSH key to ${SSH_USER}@${TARGET}:${SSH_PORT} (timeout: 10s)..."
    local output
    local copy_rc=0
    output=$(timeout 10 sshpass -p "$password" ssh-copy-id \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=5 \
        -p "$SSH_PORT" \
        -i "$key_file" \
        "${SSH_USER}@${TARGET}" 2>&1) || copy_rc=$?

    if [[ $copy_rc -eq 0 ]]; then
        log_info "  -> ssh-copy-id succeeded"
        # Verify the connection actually works
        log_info "Verifying SSH connection with key authentication..."
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
            -p "$SSH_PORT" "${SSH_USER}@${TARGET}" "echo ok" &>/dev/null; then
            log_info "  -> Connection verified OK"
            log_info "SSH key deployment complete:"
            log_info "  Target:      ${SSH_USER}@${TARGET}:${SSH_PORT}"
            log_info "  Key:         ${key_file}"
            log_info "  Fingerprint: ${fingerprint}"
            log_info "  Status:      OK"
            _msg_box "Restore Test — SSH Key Deployed" \
                "SSH key successfully copied and verified!\n\nTarget: ${SSH_USER}@${TARGET}\nKey: ${key_file}\nFingerprint: ${fingerprint}\n\nConnection test: OK"
            return 0
        else
            log_error "  -> Connection FAILED after ssh-copy-id"
            _msg_box "Restore Test — Warning" \
                "ssh-copy-id succeeded but connection test failed.\nCheck the target's SSH configuration."
            return 1
        fi
    fi

    # ssh-copy-id failed — fallback to manual instructions
    if [[ $copy_rc -eq 124 ]]; then
        log_warn "  -> ssh-copy-id timed out after 10s"
    else
        log_error "  -> ssh-copy-id failed (exit code: $copy_rc)"
        [[ -n "$output" ]] && log_error "  Output: ${output}"
    fi

    local pub_key
    pub_key=$(cat "${key_file}")

    local fail_reason="Timed out after 10 seconds"
    [[ $copy_rc -ne 124 ]] && fail_reason="Error: ${output}"

    local msg="Automatic key copy failed.\n${fail_reason}\n\n"
    msg+="Please add this key manually on ${SSH_USER}@${TARGET}:\n\n"
    msg+="Key: ${key_file}\n"
    msg+="Fingerprint: ${fingerprint}\n\n"
    msg+="${pub_key}\n\n"
    msg+="On the target, run:\n"
    msg+="  mkdir -p ~/.ssh && chmod 700 ~/.ssh\n"
    msg+="  echo '${pub_key}' >> ~/.ssh/authorized_keys\n"
    msg+="  chmod 600 ~/.ssh/authorized_keys\n\n"
    msg+="Press OK once done."

    _msg_box "Restore Test — Manual Fallback" "$msg"

    # Verify after manual setup
    log_info "Verifying SSH connection after manual key setup..."
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes \
        -p "$SSH_PORT" "${SSH_USER}@${TARGET}" "echo ok" &>/dev/null; then
        log_info "  -> Connection verified OK"
        _msg_box "Restore Test" "SSH key verified! Connection to ${SSH_USER}@${TARGET} is working."
        return 0
    else
        log_error "  -> Connection still FAILED"
        _msg_box "Restore Test" "SSH connection still failing.\nCheck the key, user, and target SSH config."
        return 1
    fi
}

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────
show_usage() {
    cat <<'USAGE'
Usage: computile-restore-test [OPTIONS]

Orchestrates a full backup restore test on a fresh VM.

Required (non-interactive mode):
  --client CLIENT        Client name (without backup- prefix)
  --vps VPS              VPS hostname/ID
  --target HOST          Target VM Tailscale hostname or IP

Optional:
  --snapshot ID          Snapshot ID (default: latest)
  --interactive          Use TUI (whiptail) for selection
  --ssh-user USER        SSH user on target (default: root)
  --ssh-port PORT        SSH port on target (default: 22)
  --skip-db-restore      Skip database restoration phase
  --skip-cleanup         Do not clean up temp files
  --report-dir DIR       Report output directory (default: /var/log/computile-backup/)
  --dry-run              Show what would be done without executing
  --help                 Show this help

Examples:
  # Interactive mode (TUI selection)
  sudo computile-restore-test --interactive

  # Non-interactive (for scripting/CI)
  sudo computile-restore-test --client mycompany --vps vps-prod-01 --target test-vm.tail1234.ts.net

  # Test specific snapshot
  sudo computile-restore-test --client mycompany --vps vps-prod-01 --target test-vm --snapshot a1b2c3d4
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --client)       CLIENT="$2"; shift 2 ;;
            --vps)          VPS="$2"; shift 2 ;;
            --target)       TARGET="$2"; shift 2 ;;
            --snapshot)     SNAPSHOT_ID="$2"; shift 2 ;;
            --interactive)  INTERACTIVE=true; shift ;;
            --ssh-user)     SSH_USER="$2"; shift 2 ;;
            --ssh-port)     SSH_PORT="$2"; shift 2 ;;
            --skip-db-restore) SKIP_DB_RESTORE=true; shift ;;
            --skip-cleanup) SKIP_CLEANUP=true; shift ;;
            --report-dir)   REPORT_DIR="$2"; shift 2 ;;
            --dry-run)      DRY_RUN=true; shift ;;
            --help|-h)      show_usage; exit 0 ;;
            *)              die "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Phase 0: Selection & configuration
# ──────────────────────────────────────────────
phase0_select() {
    log_section "PHASE 0: Selection & Configuration"

    if [[ "$INTERACTIVE" == true ]]; then
        _detect_tui
        if [[ -z "$DIALOG" ]]; then
            die "Interactive mode requires whiptail or dialog. Install with: apt install whiptail"
        fi

        CLIENT=$(_tui_select_client) || exit 1
        VPS=$(_tui_select_vps "$CLIENT") || exit 1

        # Set restic env before snapshot selection
        _setup_restic_env

        SNAPSHOT_ID=$(_tui_select_snapshot) || exit 1
        TARGET=$(_tui_input_target) || exit 1
        SSH_USER=$(_tui_input_ssh_user) || exit 1

        # Show SSH key and ask user to confirm it's on the target
        _tui_ssh_key_check || exit 1
    fi

    # Validate required parameters
    [[ -z "$CLIENT" ]] && die "Missing --client. Use --help for usage."
    [[ -z "$VPS" ]]    && die "Missing --vps. Use --help for usage."
    [[ -z "$TARGET" ]] && die "Missing --target. Use --help for usage."

    # Default snapshot to latest
    [[ -z "$SNAPSHOT_ID" ]] && SNAPSHOT_ID="latest"

    # Set up restic env (may already be set in interactive mode)
    log_info "Setting up restic environment..."
    _setup_restic_env

    # Detect role from backup config
    log_info "Detecting VPS role..."
    _detect_role

    log_info "Configuration:"
    log_info "  Client:   $CLIENT"
    log_info "  VPS:      $VPS"
    log_info "  Snapshot: $SNAPSHOT_ID"
    log_info "  Target:   $TARGET"
    log_info "  Role:     ${ROLE:-unknown}"
    log_info "  SSH:      ${SSH_USER}@${TARGET}:${SSH_PORT}"
}

_setup_restic_env() {
    RESTIC_REPOSITORY="${BACKUP_BASE}/backup-${CLIENT}/data/${VPS}"
    export RESTIC_REPOSITORY

    if [[ ! -d "$RESTIC_REPOSITORY" ]]; then
        die "Restic repository not found: $RESTIC_REPOSITORY"
    fi

    local pw_file="${BACKUP_BASE}/backup-${CLIENT}/data/_meta/${VPS}/restic-password"
    if [[ ! -f "$pw_file" ]]; then
        die "Password file not found: $pw_file"
    fi

    RESTIC_PASSWORD_FILE="$pw_file"
    export RESTIC_PASSWORD_FILE
}

_detect_role() {
    local config_file="${BACKUP_BASE}/backup-${CLIENT}/data/_meta/${VPS}/backup-agent.conf"
    if [[ -f "$config_file" ]]; then
        ROLE=$(grep -E '^ROLE=' "$config_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)
    fi

    # Fallback: check if /data/coolify exists in snapshot (can be slow)
    if [[ -z "$ROLE" ]]; then
        log_info "  No ROLE in config, checking snapshot for Coolify (may take a moment)..."
        if restic ls --no-lock "$SNAPSHOT_ID" /data/coolify 2>/dev/null | head -1 | grep -q '/data/coolify'; then
            ROLE="coolify"
        fi
    fi

    ROLE="${ROLE:-unknown}"
}

# ──────────────────────────────────────────────
# Phase 1: Pre-flight checks
# ──────────────────────────────────────────────
phase1_preflight() {
    log_section "PHASE 1: Pre-flight Checks"
    report_phase "1" "PRE-FLIGHT"

    # Check SSH connectivity
    log_info "Testing SSH connectivity to ${TARGET}..."
    if $DRY_RUN; then
        report_ok "SSH connectivity (dry-run)"
    elif _ssh_target "echo ok" &>/dev/null; then
        report_ok "SSH connectivity"
    else
        report_ko "SSH connectivity to ${SSH_USER}@${TARGET}:${SSH_PORT}"
        die "Cannot connect to target VM. Aborting."
    fi

    # Check target OS
    if ! $DRY_RUN; then
        local os_info
        os_info=$(_ssh_target "cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|ID)='" || true)
        local os_id
        os_id=$(echo "$os_info" | grep '^ID=' | cut -d= -f2 | tr -d '"')
        local os_pretty
        os_pretty=$(echo "$os_info" | grep '^PRETTY_NAME=' | cut -d= -f2 | tr -d '"')

        if [[ "$os_id" == "debian" || "$os_id" == "ubuntu" ]]; then
            report_ok "OS: ${os_pretty:-$os_id}"
        else
            report_warn "OS: ${os_pretty:-$os_id} (expected Debian/Ubuntu)"
        fi
    else
        report_ok "OS check (dry-run)"
    fi

    # Check disk space on target
    if ! $DRY_RUN; then
        local avail_kb
        avail_kb=$(_ssh_target "df / --output=avail 2>/dev/null | tail -1 | tr -d ' '" || echo "0")
        if [[ "$avail_kb" =~ ^[0-9]+$ ]]; then
            local avail_gb=$((avail_kb / 1048576))
            if [[ $avail_gb -ge 10 ]]; then
                report_ok "Disk space: ${avail_gb} GB available"
            elif [[ $avail_gb -ge 5 ]]; then
                report_warn "Disk space: ${avail_gb} GB available (low)"
            else
                report_ko "Disk space: ${avail_gb} GB available (minimum 5 GB required)"
                die "Insufficient disk space on target. Aborting."
            fi
        else
            report_warn "Could not determine disk space on target"
        fi
    else
        report_ok "Disk space check (dry-run)"
    fi

    # Check if Coolify already installed on target
    if ! $DRY_RUN && [[ "$ROLE" == "coolify" ]]; then
        if _ssh_target "test -d /data/coolify" 2>/dev/null; then
            report_warn "Coolify already present on target (will be overwritten)"
        fi
    fi

    # Verify restic repo and snapshot
    log_info "Verifying restic repository..."
    if restic snapshots --no-lock "$SNAPSHOT_ID" &>/dev/null; then
        report_ok "Restic snapshot '$SNAPSHOT_ID' accessible"
    else
        report_ko "Restic snapshot '$SNAPSHOT_ID' not found"
        die "Cannot access snapshot. Aborting."
    fi
}

# ──────────────────────────────────────────────
# Phase 2: Restore files
# ──────────────────────────────────────────────
phase2_restore_files() {
    log_section "PHASE 2: File Restore"
    report_phase "2" "FILE RESTORE"

    # Create temp directory on gateway
    TEMP_RESTORE_DIR=$(mktemp -d /tmp/computile-restore-test-XXXXXX) || die "Failed to create temp directory"
    log_info "Temp restore directory: $TEMP_RESTORE_DIR"

    if $DRY_RUN; then
        report_ok "Restic restore to $TEMP_RESTORE_DIR (dry-run)"
        report_ok "Rsync to target (dry-run)"
        return 0
    fi

    # Restore from restic locally
    log_info "Restoring snapshot '$SNAPSHOT_ID' to local temp directory..."
    local restore_start
    restore_start=$(date +%s)

    if restic restore --no-lock "$SNAPSHOT_ID" --target "$TEMP_RESTORE_DIR" 2>&1; then
        local restore_end
        restore_end=$(date +%s)
        local restore_duration=$((restore_end - restore_start))

        # Calculate restored size
        local restored_bytes
        restored_bytes=$(du -sb "$TEMP_RESTORE_DIR" 2>/dev/null | awk '{print $1}')
        local restored_human
        restored_human=$(_human_size "${restored_bytes:-0}")
        report_ok "Restic restore: ${restored_human} extracted ($(_format_duration $restore_duration))"
    else
        report_ko "Restic restore failed"
        return 1
    fi

    # Install prerequisites on target
    log_info "Installing prerequisites on target..."
    if _ssh_target "DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq rsync gzip curl" &>/dev/null; then
        report_ok "Target prerequisites installed"
    else
        report_warn "Could not install prerequisites (may already be present)"
    fi

    # Rsync to target
    log_info "Transferring files to target..."
    local rsync_start
    rsync_start=$(date +%s)

    if rsync -az --info=progress2 \
        -e "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -p ${SSH_PORT}" \
        "${TEMP_RESTORE_DIR}/" "${SSH_USER}@${TARGET}:/" 2>&1; then

        local rsync_end
        rsync_end=$(date +%s)
        local rsync_duration=$((rsync_end - rsync_start))
        report_ok "Rsync to target ($(_format_duration $rsync_duration))"
    else
        report_ko "Rsync to target failed"
        return 1
    fi
}

# ──────────────────────────────────────────────
# Phase 3: Platform restore (Coolify)
# ──────────────────────────────────────────────
phase3_platform() {
    log_section "PHASE 3: Platform Restore"
    report_phase "3" "PLATFORM"

    if [[ "$ROLE" != "coolify" ]]; then
        report_skip "Not a Coolify VPS (role: ${ROLE})"
        return 0
    fi

    if $DRY_RUN; then
        report_ok "Coolify install (dry-run)"
        report_ok "Coolify restore (dry-run)"
        return 0
    fi

    # Step 1: Install Coolify on target
    log_info "Installing Coolify on target..."
    if _ssh_target "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash" 2>&1; then
        report_ok "Coolify installed on target"
    else
        report_ko "Coolify installation failed"
        return 1
    fi

    # Step 2: Save new APP_KEY
    log_info "Saving new APP_KEY..."
    local new_app_key
    new_app_key=$(_ssh_target "grep '^APP_KEY=' /data/coolify/source/.env 2>/dev/null | cut -d= -f2" || true)
    if [[ -z "$new_app_key" ]]; then
        report_warn "Could not read new APP_KEY"
    fi

    # Step 3: Stop Coolify containers
    log_info "Stopping Coolify containers..."
    _ssh_target "docker stop coolify coolify-redis coolify-realtime coolify-proxy coolify-db 2>/dev/null || true"
    report_ok "Coolify containers stopped"

    # Step 4: Restore /data/coolify files
    # Files were already rsynced in Phase 2, but we need to fix permissions
    log_info "Restoring Coolify SSH keys and fixing permissions..."
    local restored_coolify="${TEMP_RESTORE_DIR}/data/coolify"

    if [[ -d "$restored_coolify" ]]; then
        # Rsync the backed-up coolify data (overwrite the fresh install)
        rsync -az \
            -e "ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -p ${SSH_PORT}" \
            "${restored_coolify}/" "${SSH_USER}@${TARGET}:/data/coolify/" 2>&1

        # Fix SSH key permissions
        _ssh_target "
            if [[ -d /data/coolify/ssh/keys ]]; then
                chown -R root:root /data/coolify/ssh/keys/
                chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
            fi
        "

        local key_count
        key_count=$(_ssh_target "ls /data/coolify/ssh/keys/ 2>/dev/null | wc -l" || echo "0")
        report_ok "Coolify data restored (${key_count} SSH keys)"
    else
        report_warn "No /data/coolify found in backup"
    fi

    # Step 5: Configure APP_PREVIOUS_KEYS
    log_info "Configuring APP_PREVIOUS_KEYS..."
    local old_app_key
    if [[ -f "${restored_coolify}/source/.env" ]]; then
        old_app_key=$(grep '^APP_KEY=' "${restored_coolify}/source/.env" 2>/dev/null | cut -d= -f2 || true)
    fi

    if [[ -n "$old_app_key" && -n "$new_app_key" && "$old_app_key" != "$new_app_key" ]]; then
        _ssh_target "
            # Remove any existing APP_PREVIOUS_KEYS line
            sed -i '/^APP_PREVIOUS_KEYS=/d' /data/coolify/source/.env
            # Add the old key
            echo 'APP_PREVIOUS_KEYS=${old_app_key}' >> /data/coolify/source/.env
        "
        report_ok "APP_PREVIOUS_KEYS configured"
    elif [[ "$old_app_key" == "$new_app_key" ]]; then
        report_ok "APP_KEY unchanged (no APP_PREVIOUS_KEYS needed)"
    else
        report_warn "Could not configure APP_PREVIOUS_KEYS (missing keys)"
    fi

    # Step 6: Restart Coolify
    log_info "Restarting Coolify..."
    if _ssh_target "curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash" 2>&1; then
        report_ok "Coolify restarted"
    else
        report_ko "Coolify restart failed"
    fi

    # Wait for Coolify to be ready
    log_info "Waiting for Coolify containers to start..."
    local waited=0
    while [[ $waited -lt 60 ]]; do
        if _ssh_target "docker ps --filter name=coolify --format '{{.Names}}' 2>/dev/null | grep -q '^coolify$'"; then
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done

    if [[ $waited -ge 60 ]]; then
        report_warn "Coolify containers slow to start (waited 60s)"
    fi
}

# ──────────────────────────────────────────────
# Phase 4: Database restoration
# ──────────────────────────────────────────────
phase4_databases() {
    log_section "PHASE 4: Database Restore"
    report_phase "4" "DATABASES"

    if $SKIP_DB_RESTORE; then
        report_skip "Database restore skipped (--skip-db-restore)"
        return 0
    fi

    if $DRY_RUN; then
        report_ok "Database restore (dry-run)"
        return 0
    fi

    local dump_base="${TEMP_RESTORE_DIR}/var/backups/computile/db"

    if [[ ! -d "$dump_base" ]]; then
        report_skip "No database dumps found in snapshot"
        return 0
    fi

    # Restore MySQL/MariaDB dumps
    _restore_mysql_dumps "$dump_base/mysql"

    # Restore PostgreSQL dumps
    _restore_postgres_dumps "$dump_base/postgres"

    # Restore Redis dumps
    _restore_redis_dumps "$dump_base/redis"
}

_wait_for_container() {
    local container="$1"
    local timeout="${2:-120}"
    local waited=0

    while [[ $waited -lt $timeout ]]; do
        local status
        status=$(_ssh_target "docker ps --filter name='^${container}$' --format '{{.Status}}'" 2>/dev/null || true)
        if [[ "$status" == *"Up"* ]]; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

_parse_dump_filename() {
    # Input: filename like "container_db_2026-03-13T02-15-00.sql.gz"
    # Output: container_name and db_name on separate lines
    local filename="$1"

    # Strip extension (.sql.gz or .rdb)
    local base="${filename%.sql.gz}"
    base="${base%.rdb}"

    # Strip timestamp (_YYYY-MM-DDTHH-MM-SS)
    base=$(echo "$base" | sed 's/_[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}-[0-9]\{2\}-[0-9]\{2\}$//')

    # For host-level dumps: starts with "host_"
    if [[ "$base" == host_* ]]; then
        echo "host"
        echo "${base#host_}"
        return
    fi

    # Split on last underscore: container_db
    local container="${base%_*}"
    local db="${base##*_}"

    # If no underscore found, use full base as container
    if [[ "$container" == "$base" ]]; then
        echo "$base"
        echo ""
    else
        echo "$container"
        echo "$db"
    fi
}

_restore_mysql_dumps() {
    local mysql_dir="$1"
    [[ -d "$mysql_dir" ]] || return 0

    local dumps=()
    while IFS= read -r -d '' f; do
        dumps+=("$f")
    done < <(find "$mysql_dir" -name '*.sql.gz' -print0 2>/dev/null)

    if [[ ${#dumps[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Found ${#dumps[@]} MySQL dump(s)"

    for dump in "${dumps[@]}"; do
        local filename
        filename=$(basename "$dump")
        local dump_size
        dump_size=$(stat -c%s "$dump" 2>/dev/null || echo 0)
        local size_human
        size_human=$(_human_size "$dump_size")

        local parsed
        parsed=$(_parse_dump_filename "$filename")
        local container
        container=$(echo "$parsed" | head -1)
        local db
        db=$(echo "$parsed" | tail -1)

        log_info "Restoring MySQL: ${container}/${db} (${size_human})..."

        # Find matching MySQL container on target
        local target_container=""
        if [[ "$container" != "host" ]]; then
            target_container=$(_ssh_target "docker ps --format '{{.Names}}' 2>/dev/null | grep -i '${container}' | head -1" || true)
        fi

        if [[ -z "$target_container" ]]; then
            # Try to find any MySQL container
            target_container=$(_ssh_target "docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep -iE 'mysql|mariadb' | head -1 | cut -f1" || true)
        fi

        if [[ -z "$target_container" ]]; then
            report_warn "${container}/${db} (mysql, ${size_human}): no MySQL container found on target"
            continue
        fi

        # Wait for container
        if ! _wait_for_container "$target_container" 60; then
            report_ko "${container}/${db} (mysql, ${size_human}): container not ready"
            continue
        fi

        # Transfer and import
        local remote_tmp="/tmp/restore-dump-${filename}"
        _scp_to_target "$dump" "$remote_tmp"

        # Extract MySQL password from container env
        local mysql_pass
        mysql_pass=$(_ssh_target "docker exec ${target_container} env 2>/dev/null | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -1 | cut -d= -f2" || true)

        local pass_arg=""
        [[ -n "$mysql_pass" ]] && pass_arg="-p${mysql_pass}"

        if _ssh_target "gunzip -c '${remote_tmp}' | docker exec -i '${target_container}' mysql -u root ${pass_arg} '${db}'" 2>&1; then
            report_ok "${container}/${db} (mysql, ${size_human})"
        else
            report_ko "${container}/${db} (mysql, ${size_human}): import failed"
        fi

        _ssh_target "rm -f '${remote_tmp}'" 2>/dev/null || true
    done
}

_restore_postgres_dumps() {
    local pg_dir="$1"
    [[ -d "$pg_dir" ]] || return 0

    local dumps=()
    while IFS= read -r -d '' f; do
        dumps+=("$f")
    done < <(find "$pg_dir" -name '*.sql.gz' -print0 2>/dev/null)

    if [[ ${#dumps[@]} -eq 0 ]]; then
        return 0
    fi

    log_info "Found ${#dumps[@]} PostgreSQL dump(s)"

    for dump in "${dumps[@]}"; do
        local filename
        filename=$(basename "$dump")
        local dump_size
        dump_size=$(stat -c%s "$dump" 2>/dev/null || echo 0)
        local size_human
        size_human=$(_human_size "$dump_size")

        local parsed
        parsed=$(_parse_dump_filename "$filename")
        local container
        container=$(echo "$parsed" | head -1)
        local db
        db=$(echo "$parsed" | tail -1)

        log_info "Restoring PostgreSQL: ${container}/${db} (${size_human})..."

        # Find matching PostgreSQL container on target
        local target_container=""
        if [[ "$container" != "host" ]]; then
            target_container=$(_ssh_target "docker ps --format '{{.Names}}' 2>/dev/null | grep -i '${container}' | head -1" || true)
        fi

        if [[ -z "$target_container" ]]; then
            target_container=$(_ssh_target "docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep -iE 'postgres' | head -1 | cut -f1" || true)
        fi

        if [[ -z "$target_container" ]]; then
            report_warn "${container}/${db} (postgres, ${size_human}): no PostgreSQL container found on target"
            continue
        fi

        if ! _wait_for_container "$target_container" 60; then
            report_ko "${container}/${db} (postgres, ${size_human}): container not ready"
            continue
        fi

        # Transfer and import
        local remote_tmp="/tmp/restore-dump-${filename}"
        _scp_to_target "$dump" "$remote_tmp"

        # Determine postgres user
        local pg_user
        pg_user=$(_ssh_target "docker exec ${target_container} env 2>/dev/null | grep '^POSTGRES_USER=' | cut -d= -f2" || true)
        pg_user="${pg_user:-postgres}"

        if _ssh_target "gunzip -c '${remote_tmp}' | docker exec -i '${target_container}' psql -U '${pg_user}' -d '${db}'" 2>&1; then
            report_ok "${container}/${db} (postgres, ${size_human})"
        else
            report_ko "${container}/${db} (postgres, ${size_human}): import failed"
        fi

        _ssh_target "rm -f '${remote_tmp}'" 2>/dev/null || true
    done
}

_restore_redis_dumps() {
    local redis_dir="$1"
    [[ -d "$redis_dir" ]] || return 0

    local dumps=()
    while IFS= read -r -d '' f; do
        dumps+=("$f")
    done < <(find "$redis_dir" -name '*.rdb' -print0 2>/dev/null)

    if [[ ${#dumps[@]} -eq 0 ]]; then
        report_skip "Redis (no dumps found)"
        return 0
    fi

    log_info "Found ${#dumps[@]} Redis dump(s)"

    for dump in "${dumps[@]}"; do
        local filename
        filename=$(basename "$dump")
        local dump_size
        dump_size=$(stat -c%s "$dump" 2>/dev/null || echo 0)
        local size_human
        size_human=$(_human_size "$dump_size")

        local parsed
        parsed=$(_parse_dump_filename "$filename")
        local container
        container=$(echo "$parsed" | head -1)

        log_info "Restoring Redis: ${container} (${size_human})..."

        local target_container=""
        target_container=$(_ssh_target "docker ps --format '{{.Names}}' 2>/dev/null | grep -i '${container}' | head -1" || true)

        if [[ -z "$target_container" ]]; then
            target_container=$(_ssh_target "docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep -iE 'redis' | head -1 | cut -f1" || true)
        fi

        if [[ -z "$target_container" ]]; then
            report_warn "${container} (redis, ${size_human}): no Redis container found on target"
            continue
        fi

        if ! _wait_for_container "$target_container" 60; then
            report_ko "${container} (redis, ${size_human}): container not ready"
            continue
        fi

        # Transfer RDB file and copy into container
        local remote_tmp="/tmp/restore-dump-${filename}"
        _scp_to_target "$dump" "$remote_tmp"

        if _ssh_target "
            docker exec '${target_container}' redis-cli SHUTDOWN NOSAVE 2>/dev/null || true
            sleep 2
            docker cp '${remote_tmp}' '${target_container}:/data/dump.rdb'
            docker start '${target_container}' 2>/dev/null || true
        " 2>&1; then
            report_ok "${container} (redis, ${size_human})"
        else
            report_ko "${container} (redis, ${size_human}): restore failed"
        fi

        _ssh_target "rm -f '${remote_tmp}'" 2>/dev/null || true
    done
}

# ──────────────────────────────────────────────
# Phase 5: Verification & reporting
# ──────────────────────────────────────────────
phase5_verify() {
    log_section "PHASE 5: Verification"
    report_phase "5" "VERIFICATION"

    if $DRY_RUN; then
        report_ok "All verifications (dry-run)"
        return 0
    fi

    # Check Docker
    if _ssh_target "docker info" &>/dev/null; then
        report_ok "Docker running"
    else
        report_ko "Docker not running"
        return 0  # No point checking containers if Docker is down
    fi

    # Coolify-specific checks
    if [[ "$ROLE" == "coolify" ]]; then
        _verify_coolify
    fi

    # Database connectivity checks
    _verify_db_connections

    # Discover and check deployed applications
    _verify_applications
}

_verify_coolify() {
    # Check Coolify core containers
    local coolify_containers=("coolify" "coolify-db" "coolify-redis" "coolify-realtime" "coolify-proxy")

    for cname in "${coolify_containers[@]}"; do
        local status
        status=$(_ssh_target "docker ps --filter name='^${cname}$' --format '{{.Status}}'" 2>/dev/null || true)
        if [[ "$status" == *"Up"* ]]; then
            report_ok "${cname}: UP"
        else
            report_ko "${cname}: DOWN"
        fi
    done

    # Check Coolify dashboard HTTP
    log_info "Checking Coolify dashboard..."
    local http_code
    http_code=$(_ssh_target "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://localhost:8000" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
        report_ok "Coolify dashboard: HTTP ${http_code}"
    elif [[ "$http_code" == "000" ]]; then
        report_ko "Coolify dashboard: not responding"
    else
        report_warn "Coolify dashboard: HTTP ${http_code}"
    fi
}

_verify_db_connections() {
    # Find running database containers and test connections
    local db_containers
    db_containers=$(_ssh_target "docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null" || true)

    if [[ -z "$db_containers" ]]; then
        return 0
    fi

    # Test PostgreSQL containers
    while IFS=$'\t' read -r name image; do
        if [[ "$image" == *postgres* ]]; then
            local pg_user
            pg_user=$(_ssh_target "docker exec ${name} env 2>/dev/null | grep '^POSTGRES_USER=' | cut -d= -f2" || echo "postgres")
            pg_user="${pg_user:-postgres}"

            if _ssh_target "docker exec ${name} psql -U '${pg_user}' -c '\\l'" &>/dev/null; then
                report_ok "PostgreSQL connection (${name})"
            else
                report_ko "PostgreSQL connection (${name})"
            fi
        fi
    done <<< "$db_containers"

    # Test MySQL containers
    while IFS=$'\t' read -r name image; do
        if [[ "$image" == *mysql* || "$image" == *mariadb* ]]; then
            local mysql_pass
            mysql_pass=$(_ssh_target "docker exec ${name} env 2>/dev/null | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -1 | cut -d= -f2" || true)

            local pass_arg=""
            [[ -n "$mysql_pass" ]] && pass_arg="-p${mysql_pass}"

            if _ssh_target "docker exec ${name} mysql -u root ${pass_arg} -e 'SELECT 1'" &>/dev/null; then
                report_ok "MySQL connection (${name})"
            else
                report_ko "MySQL connection (${name})"
            fi
        fi
    done <<< "$db_containers"
}

_verify_applications() {
    log_info "Discovering deployed applications..."

    # Try to find Coolify-managed containers
    local app_containers
    app_containers=$(_ssh_target "docker ps --filter 'label=coolify.managed=true' --format '{{.Names}}\t{{.Ports}}'" 2>/dev/null || true)

    if [[ -z "$app_containers" ]]; then
        # Fallback: look for non-system containers
        app_containers=$(_ssh_target "docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -vE '^(coolify|coolify-db|coolify-redis|coolify-realtime|coolify-proxy)\b'" || true)
    fi

    if [[ -z "$app_containers" ]]; then
        report_skip "No application containers found"
        return 0
    fi

    while IFS=$'\t' read -r name ports; do
        [[ -z "$name" ]] && continue

        # Extract HTTP port from ports string (e.g., "0.0.0.0:3000->3000/tcp")
        local http_port=""
        if [[ "$ports" =~ 0\.0\.0\.0:([0-9]+)-\> ]]; then
            http_port="${BASH_REMATCH[1]}"
        fi

        if [[ -n "$http_port" ]]; then
            local code
            code=$(_ssh_target "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:${http_port}" 2>/dev/null || echo "000")

            if [[ "$code" =~ ^(200|301|302|304)$ ]]; then
                report_ok "App '${name}': HTTP ${code} (port ${http_port})"
            elif [[ "$code" == "000" ]]; then
                report_ko "App '${name}': not responding (port ${http_port})"
            else
                report_warn "App '${name}': HTTP ${code} (port ${http_port})"
            fi
        else
            # No exposed port — just check container is running
            local status
            status=$(_ssh_target "docker ps --filter name='^${name}$' --format '{{.Status}}'" 2>/dev/null || true)
            if [[ "$status" == *"Up"* ]]; then
                report_ok "App '${name}': container UP (no HTTP port exposed)"
            else
                report_ko "App '${name}': container DOWN"
            fi
        fi
    done <<< "$app_containers"
}

# ──────────────────────────────────────────────
# Phase 6: Cleanup
# ──────────────────────────────────────────────
phase6_cleanup() {
    log_section "PHASE 6: Cleanup"

    if [[ -n "$TEMP_RESTORE_DIR" && -d "$TEMP_RESTORE_DIR" ]]; then
        if $SKIP_CLEANUP; then
            log_info "Temp directory preserved: $TEMP_RESTORE_DIR"
        else
            log_info "Cleaning up temp directory: $TEMP_RESTORE_DIR"
            rm -rf "$TEMP_RESTORE_DIR"
        fi
    fi

    # In interactive mode, offer to clean up the target
    if [[ "$INTERACTIVE" == true && "$DRY_RUN" != true ]]; then
        if _yesno "Cleanup" "Do you want to clean up temp files on the target VM?"; then
            _ssh_target "rm -rf /tmp/restore-dump-* /tmp/computile-restore-*" 2>/dev/null || true
            log_info "Target temp files cleaned"
        fi
    fi
}

cleanup_on_exit() {
    # Always clean up temp dir on gateway (unless --skip-cleanup)
    if [[ -n "$TEMP_RESTORE_DIR" && -d "$TEMP_RESTORE_DIR" && "$SKIP_CLEANUP" != true ]]; then
        rm -rf "$TEMP_RESTORE_DIR"
    fi
}

# ──────────────────────────────────────────────
# Main orchestrator
# ──────────────────────────────────────────────
main() {
    # Must be root
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (sudo)"
    fi

    # Check dependencies
    for cmd in restic rsync ssh scp; do
        if ! command -v "$cmd" &>/dev/null; then
            die "Required command not found: $cmd"
        fi
    done

    # Load gateway config
    _load_gateway_config

    # Parse arguments
    parse_args "$@"

    # Setup cleanup trap
    trap cleanup_on_exit EXIT

    START_TIME=$(date +%s)

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║   COMPUTILE RESTORE TEST                 ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    # Phase 0: Selection
    phase0_select

    # Confirm in interactive mode
    if [[ "$INTERACTIVE" == true ]]; then
        local confirm_msg="Restore test configuration:\n\n"
        confirm_msg+="Client:   ${CLIENT}\n"
        confirm_msg+="VPS:      ${VPS}\n"
        confirm_msg+="Snapshot: ${SNAPSHOT_ID}\n"
        confirm_msg+="Target:   ${TARGET}\n"
        confirm_msg+="Role:     ${ROLE}\n\n"
        confirm_msg+="This will restore backup data to the target VM.\n"
        confirm_msg+="Continue?"

        if ! _yesno "Confirm Restore Test" "$confirm_msg"; then
            log_info "Cancelled by user."
            exit 0
        fi
    fi

    # Phase 1: Pre-flight
    phase1_preflight

    # Phase 2: Restore files
    if ! phase2_restore_files; then
        log_error "File restore failed. Generating partial report."
        report_generate
        exit 1
    fi

    # Phase 3: Platform
    phase3_platform || true

    # Phase 4: Databases
    phase4_databases || true

    # Phase 5: Verify
    phase5_verify || true

    # Phase 6: Cleanup
    phase6_cleanup

    # Generate report
    report_generate

    # Show report in TUI if interactive
    if [[ "$INTERACTIVE" == true && -n "$DIALOG" && -f "$REPORT_FILE" ]]; then
        local report_content
        report_content=$(cat "$REPORT_FILE")
        local tmpfile
        tmpfile=$(mktemp)
        echo "$report_content" > "$tmpfile"
        $DIALOG --title "Restore Test Report" --textbox "$tmpfile" $WT_HEIGHT $WT_WIDTH
        rm -f "$tmpfile"
    fi

    # Exit with appropriate code
    if [[ $COUNT_KO -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
