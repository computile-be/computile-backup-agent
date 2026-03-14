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
SSH_USER="computile-restore"
SSH_PORT=22
INTERACTIVE=false
SKIP_DB_RESTORE=false
SKIP_CLEANUP=false
DRY_RUN=false
START_FROM_PHASE=1
REPORT_DIR="$DEFAULT_REPORT_DIR"

# Runtime state
REPORT_FILE=""
REPORT_BUFFER=""
START_TIME=""
ROLE=""
RESTIC_REPOSITORY=""
RESTIC_PASSWORD_FILE=""
SSH_CONTROL_DIR=""
SSH_CONTROL_SOCKET=""
LOG_FILE=""


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
    REPORT_GENERATED=true

    echo ""
    echo "$report"
    echo ""
    log_info "Report saved to: $REPORT_FILE"
}

# ──────────────────────────────────────────────
# SSH helpers (with ControlMaster for connection reuse)
# ──────────────────────────────────────────────
_ssh_common_opts() {
    local -a opts=(
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=30
        -p "$SSH_PORT"
    )
    if [[ -n "$SSH_CONTROL_SOCKET" ]]; then
        opts+=(-o "ControlMaster=auto" -o "ControlPath=$SSH_CONTROL_SOCKET" -o "ControlPersist=300")
    fi
    echo "${opts[@]}"
}

_setup_ssh_control() {
    SSH_CONTROL_DIR=$(mktemp -d /tmp/computile-ssh-XXXXXX)
    SSH_CONTROL_SOCKET="${SSH_CONTROL_DIR}/ctrl-%r@%h:%p"
    log_info "SSH ControlMaster enabled: $SSH_CONTROL_DIR"
}

_cleanup_ssh_control() {
    if [[ -n "$SSH_CONTROL_SOCKET" ]]; then
        ssh -o "ControlPath=$SSH_CONTROL_SOCKET" -O exit "${SSH_USER}@${TARGET}" 2>/dev/null || true
    fi
    if [[ -n "$SSH_CONTROL_DIR" && -d "$SSH_CONTROL_DIR" ]]; then
        rm -rf "$SSH_CONTROL_DIR"
    fi
}

_ssh_target() {
    # -tt forces pseudo-TTY allocation even when stdin is not a terminal.
    # Required for sudo on targets with Defaults use_pty (Debian 13+).
    # shellcheck disable=SC2046
    ssh $(_ssh_common_opts) \
        -tt -o BatchMode=yes \
        "${SSH_USER}@${TARGET}" "$@"
}

_ssh_target_interactive() {
    # For commands that need a TTY (apt prompts, etc.)
    # shellcheck disable=SC2046
    ssh $(_ssh_common_opts) \
        -t \
        "${SSH_USER}@${TARGET}" "$@"
}

_scp_to_target() {
    local src="$1"
    local dest="$2"
    local -a scp_opts=(
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=30
        -P "$SSH_PORT"
    )
    if [[ -n "$SSH_CONTROL_SOCKET" ]]; then
        scp_opts+=(-o "ControlMaster=auto" -o "ControlPath=$SSH_CONTROL_SOCKET" -o "ControlPersist=300")
    fi
    scp "${scp_opts[@]}" "$src" "${SSH_USER}@${TARGET}:${dest}"
}

_rsync_ssh_cmd() {
    local cmd="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -p ${SSH_PORT}"
    if [[ -n "$SSH_CONTROL_SOCKET" ]]; then
        cmd+=" -o ControlMaster=auto -o ControlPath=${SSH_CONTROL_SOCKET} -o ControlPersist=300"
    fi
    echo "$cmd"
}

# Deploy a path-aware fixup script on the target that re-injects the SSH user
# and restores host keys after rsync/tar overwrites system files.
# The fixup reads /tmp/computile-restore-current-path to determine what was just
# restored, and only modifies system identity files (passwd/shadow/group/PAM)
# when /etc was actually restored — avoiding dangerous sed -i on passwd after
# /home restore which can momentarily remove the SSH user and kill ControlMaster.
# Called inline via --rsync-path wrapper (rsync) or chained after tar (streaming),
# so it runs within the SAME SSH session — no polling, no timing issues.
_deploy_ssh_fixup() {
    local _sudo=""
    [[ "$SSH_USER" != "root" ]] && _sudo="sudo "

    _ssh_target "${_sudo}bash -s" <<'FIXUP_DEPLOY_EOF' 2>/dev/null || {
SAVE_DIR="/tmp/computile-ssh-save"

cat > /tmp/computile-ssh-fixup.sh <<'FIXUP_SCRIPT'
#!/bin/bash
DBG=/tmp/computile-fixup-debug.log
echo "[fixup] START $(date '+%H:%M:%S') pid=$$ uid=$(id -u)" >> "$DBG"
SAVE_DIR="/tmp/computile-ssh-save"
[ ! -d "$SAVE_DIR" ] && { echo "[fixup] no save dir, exit" >> "$DBG"; exit 0; }

USER_LINE=$(cat "$SAVE_DIR/passwd_line" 2>/dev/null)
[ -z "$USER_LINE" ] && { echo "[fixup] no passwd_line, exit" >> "$DBG"; exit 0; }

USERNAME=$(echo "$USER_LINE" | cut -d: -f1)
USER_UID=$(echo "$USER_LINE" | cut -d: -f3)
USER_GID=$(echo "$USER_LINE" | cut -d: -f4)
USER_HOME=$(cat "$SAVE_DIR/home_dir" 2>/dev/null)
RESTORED_PATH=$(cat /tmp/computile-restore-current-path 2>/dev/null || echo "")
echo "[fixup] user=$USERNAME uid=$USER_UID path=$RESTORED_PATH" >> "$DBG"

# ── Layer 1: ALWAYS restore authorized_keys (both locations) ──
# Home-based authorized_keys
mkdir -p "${USER_HOME}/.ssh"
chmod 755 "${USER_HOME}"
chmod 700 "${USER_HOME}/.ssh"
chown "${USER_UID}:${USER_GID}" "${USER_HOME}" "${USER_HOME}/.ssh"
if [ -f "$SAVE_DIR/authorized_keys" ]; then
    cp "$SAVE_DIR/authorized_keys" "${USER_HOME}/.ssh/authorized_keys"
    chmod 600 "${USER_HOME}/.ssh/authorized_keys"
    chown "${USER_UID}:${USER_GID}" "${USER_HOME}/.ssh/authorized_keys"
fi

# System-wide authorized_keys (resilient to /home restore)
if [ -f "$SAVE_DIR/authorized_keys" ]; then
    mkdir -p /etc/ssh/authorized_keys
    chmod 755 /etc/ssh/authorized_keys
    cp "$SAVE_DIR/authorized_keys" "/etc/ssh/authorized_keys/${USERNAME}"
    chmod 644 "/etc/ssh/authorized_keys/${USERNAME}"
fi

# Restore sshd config snippet (AuthorizedKeysFile directive)
if [ -f "$SAVE_DIR/sshd_snippet" ]; then
    mkdir -p /etc/ssh/sshd_config.d
    cp "$SAVE_DIR/sshd_snippet" /etc/ssh/sshd_config.d/99-computile-restore.conf
    chmod 644 /etc/ssh/sshd_config.d/99-computile-restore.conf
fi

# ── Layer 2: system identity fixup (only after /etc restore) ──
# Modifying passwd/shadow/group is only necessary when /etc was overwritten.
# Doing it after /home restore is both unnecessary and dangerous: the sed -i
# momentarily removes the user which can kill active SSH sessions on Debian 13+.
is_etc_restore=false
case "$RESTORED_PATH" in
    /etc|/etc/*) is_etc_restore=true ;;
    /)           is_etc_restore=true ;;  # full dump = everything including /etc
    "")          is_etc_restore=true ;;  # unknown path = full fixup (safety)
esac
echo "[fixup] is_etc_restore=$is_etc_restore (path='$RESTORED_PATH')" >> "$DBG"

if $is_etc_restore; then
    sed -i "/^${USERNAME}:/d" /etc/passwd 2>/dev/null || true
    cat "$SAVE_DIR/passwd_line" >> /etc/passwd

    if [ -f "$SAVE_DIR/shadow_line" ] && [ -s "$SAVE_DIR/shadow_line" ]; then
        sed -i "/^${USERNAME}:/d" /etc/shadow 2>/dev/null || true
        cat "$SAVE_DIR/shadow_line" >> /etc/shadow
    fi

    if [ -f "$SAVE_DIR/group_line" ] && [ -s "$SAVE_DIR/group_line" ]; then
        sed -i "/^${USERNAME}:/d" /etc/group 2>/dev/null || true
        cat "$SAVE_DIR/group_line" >> /etc/group
    fi

    if [ -f "$SAVE_DIR/groups" ]; then
        for g in $(cat "$SAVE_DIR/groups"); do
            grep -q "^${g}:" /etc/group 2>/dev/null && usermod -aG "$g" "$USERNAME" 2>/dev/null || true
        done
    fi

    mkdir -p /etc/sudoers.d 2>/dev/null || true
    _ensure_nopasswd() {
        local u="$1"
        [ -n "$u" ] || return
        grep -q "^${u}:" /etc/passwd 2>/dev/null || return
        echo "${u} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${u}"
        grep -q "Defaults:${u} !use_pty" "/etc/sudoers.d/${u}" 2>/dev/null || \
            echo "Defaults:${u} !use_pty" >> "/etc/sudoers.d/${u}"
        chmod 440 "/etc/sudoers.d/${u}"
    }
    # 1) Restore user (computile-restore)
    if [ -f "$SAVE_DIR/sudoers_file" ]; then
        cp "$SAVE_DIR/sudoers_file" "/etc/sudoers.d/${USERNAME}"
    else
        _ensure_nopasswd "$USERNAME"
    fi
    grep -q "Defaults:${USERNAME} !use_pty" "/etc/sudoers.d/${USERNAME}" 2>/dev/null || \
        echo "Defaults:${USERNAME} !use_pty" >> "/etc/sudoers.d/${USERNAME}"
    chmod 440 "/etc/sudoers.d/${USERNAME}"
    # 2) Any user whose authorized_keys has the gateway key — after /home restore,
    #    the backup's main user (e.g. computile) may have it; sshd can auth as them.
    for ak in /etc/ssh/authorized_keys/* 2>/dev/null; do
        [ -f "$ak" ] || continue
        grep -q "computile-gateway-restore" "$ak" 2>/dev/null || continue
        u=$(basename "$ak")
        [ "$u" = "$USERNAME" ] && continue
        _ensure_nopasswd "$u"
    done
    for home in /root /home/*; do
        [ -d "$home" ] || continue
        [ -f "${home}/.ssh/authorized_keys" ] || continue
        grep -q "computile-gateway-restore" "${home}/.ssh/authorized_keys" 2>/dev/null || continue
        u=$(basename "$home")
        [ "$u" = "$USERNAME" ] || [ "$u" = "root" ] && continue
        _ensure_nopasswd "$u"
    done

    # Restore PAM + nsswitch (critical for SSH session creation)
    if [ -d "$SAVE_DIR/pam" ]; then
        cp "$SAVE_DIR/pam/nsswitch.conf" /etc/nsswitch.conf 2>/dev/null || true
        cp "$SAVE_DIR/pam/shells" /etc/shells 2>/dev/null || true
        cp "$SAVE_DIR/pam/login.defs" /etc/login.defs 2>/dev/null || true
        if [ -d "$SAVE_DIR/pam/pam.d" ]; then
            cp -a "$SAVE_DIR/pam/pam.d"/* /etc/pam.d/ 2>/dev/null || true
        fi
    fi

    # Restore SSH host keys + sshd config, but only reload sshd if keys actually changed.
    # Unnecessary reloads kill the SSH ControlMaster on some systems (Debian 13+).
    if [ -d "$SAVE_DIR/ssh" ]; then
        keys_changed=false
        for saved_key in "$SAVE_DIR"/ssh/ssh_host_*; do
            [ -f "$saved_key" ] || continue
            current_key="/etc/ssh/$(basename "$saved_key")"
            if ! cmp -s "$saved_key" "$current_key" 2>/dev/null; then
                keys_changed=true
                break
            fi
        done
        if ! cmp -s "$SAVE_DIR/ssh/sshd_config" /etc/ssh/sshd_config 2>/dev/null; then
            keys_changed=true
        fi

        cp "$SAVE_DIR"/ssh/ssh_host_* /etc/ssh/ 2>/dev/null || true
        cp "$SAVE_DIR/ssh/sshd_config" /etc/ssh/sshd_config 2>/dev/null || true

        if $keys_changed; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        fi
    fi
else
    # Non-/etc restore: only verify user still exists (append-only, never delete)
    if ! grep -q "^${USERNAME}:" /etc/passwd 2>/dev/null; then
        cat "$SAVE_DIR/passwd_line" >> /etc/passwd
    fi
    if [ -f "$SAVE_DIR/shadow_line" ] && [ -s "$SAVE_DIR/shadow_line" ]; then
        if ! grep -q "^${USERNAME}:" /etc/shadow 2>/dev/null; then
            cat "$SAVE_DIR/shadow_line" >> /etc/shadow
        fi
    fi
    if [ -f "$SAVE_DIR/group_line" ] && [ -s "$SAVE_DIR/group_line" ]; then
        if ! grep -q "^${USERNAME}:" /etc/group 2>/dev/null; then
            cat "$SAVE_DIR/group_line" >> /etc/group
        fi
    fi
fi
echo "[fixup] END $(date '+%H:%M:%S') sudoers_exists=$(ls /etc/sudoers.d/${USERNAME} 2>&1) sudo_test=$(sudo -n -u ${USERNAME} true 2>&1 && echo OK || echo FAIL)" >> "$DBG"
FIXUP_SCRIPT

chmod +x /tmp/computile-ssh-fixup.sh

FIXUP_DEPLOY_EOF
        log_warn "  Could not deploy SSH fixup script"
        return 1
    }
    log_info "  SSH fixup script deployed on target"
}

_cleanup_ssh_fixup() {
    _ssh_target "sudo bash -c '
        rm -rf /tmp/computile-ssh-fixup.sh /tmp/computile-ssh-save /tmp/computile-restore-staging /tmp/computile-restore-current-path
        rm -f /etc/ssh/sshd_config.d/99-computile-restore.conf
        rm -f /etc/ssh/authorized_keys/${SSH_USER:-computile-restore}
        rmdir /etc/ssh/authorized_keys 2>/dev/null
        if sshd -t 2>/dev/null; then
            systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
        fi
    '" 2>/dev/null || true
}

# Set up resilient SSH access: store authorized_keys in a system-wide location
# (/etc/ssh/authorized_keys/%u) that survives /home restore. Also add an sshd
# config snippet so sshd looks in both the standard and system-wide locations.
# Since rsync without --delete never removes files absent from the source,
# both the snippet and the system-wide keys persist through ALL restore phases.
_setup_resilient_ssh() {
    local _sudo=""
    [[ "$SSH_USER" != "root" ]] && _sudo="sudo "

    if _ssh_target "${_sudo}bash -s" <<RESILIENT_EOF 2>/dev/null; then
set -e

# System-wide authorized_keys directory
mkdir -p /etc/ssh/authorized_keys
chmod 755 /etc/ssh/authorized_keys

# Copy current authorized_keys to system-wide location
home=\$(eval echo "~${SSH_USER}")
if [ -f "\${home}/.ssh/authorized_keys" ]; then
    cp "\${home}/.ssh/authorized_keys" "/etc/ssh/authorized_keys/${SSH_USER}"
    chmod 644 "/etc/ssh/authorized_keys/${SSH_USER}"
fi

# sshd config snippet: look in both system-wide and home-based locations
SNIPPET="/etc/ssh/sshd_config.d/99-computile-restore.conf"
mkdir -p /etc/ssh/sshd_config.d
cat > "\$SNIPPET" <<'SSHD_CONF'
# Computile restore-test: resilient authorized_keys location
# Ensures SSH access survives /home and /etc restores
AuthorizedKeysFile /etc/ssh/authorized_keys/%u .ssh/authorized_keys
SSHD_CONF
chmod 644 "\$SNIPPET"

# Validate config before reloading — never break a working sshd
if sshd -t 2>/dev/null; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true
else
    rm -f "\$SNIPPET"
fi
RESILIENT_EOF
        log_info "  Resilient SSH: authorized_keys stored in /etc/ssh/authorized_keys/${SSH_USER}"
        # Verify SSH still works after sshd reload
        if ! _ssh_target true 2>/dev/null; then
            log_warn "  SSH disrupted by sshd reload — reverting resilient config..."
            _ssh_target "${_sudo}rm -f /etc/ssh/sshd_config.d/99-computile-restore.conf; ${_sudo}systemctl reload sshd 2>/dev/null || ${_sudo}systemctl reload ssh 2>/dev/null || true" 2>/dev/null || true
            sleep 2
            return 1
        fi
    else
        log_warn "  Could not set up resilient SSH — continuing with standard authorized_keys"
        return 1
    fi
}

# Set the current restore path on the target so the fixup script knows
# which system files need repair. Called before each rsync/streaming operation.
_set_restore_path() {
    local path="$1"
    local _sudo=""
    [[ "$SSH_USER" != "root" ]] && _sudo="sudo "
    _ssh_target "${_sudo}bash -c 'echo \"$path\" > /tmp/computile-restore-current-path'" 2>/dev/null || true
}



# Stream a path directly from restic to target via SSH (no local disk writes).
# Uses: restic dump --archive tar | ssh tar xf -
# Returns 0 on success, non-zero on failure.
_stream_path_to_target() {
    local path="$1"
    local label="$2"

    log_info "${label} Streaming $path to target (no local writes)..."

    # Tell the target which path is being restored (path-aware fixup)
    _set_restore_path "$path"

    # Build tar exclusions — only Coolify SSH keys (handled in Phase 3)
    # All /etc files are fully restored; the inline fixup re-injects SSH identity after tar
    local tar_excludes=""
    tar_excludes+=" --exclude='data/coolify/ssh/keys'"
    tar_excludes+=" --exclude='data/coolify/ssh/id.*'"

    # Build remote command: tar extract + inline SSH fixup
    # The fixup runs within the SAME SSH session, after tar completes,
    # so it executes before the connection closes — no timing issues
    local _sudo=""
    [[ "$SSH_USER" != "root" ]] && _sudo="sudo "
    local remote_cmd="${_sudo}bash -c 'tar xf - -C / ${tar_excludes}; RC=\$?; chmod 755 / 2>/dev/null || true; /tmp/computile-ssh-fixup.sh 2>/dev/null || true; exit \$RC'"

    # Get target disk usage before streaming (for transferred bytes estimate)
    local before_used_kb
    before_used_kb=$(_ssh_target "df / --output=used 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "0")

    local stream_start
    stream_start=$(date +%s)

    # Stream restic dump directly to target via SSH
    # restic dump outputs tar to stdout, SSH pipes it to remote tar extract
    # Use Compression=no: restic output is already decompressed, SSH compression wastes CPU
    restic dump --archive tar --no-lock "$SNAPSHOT_ID" "$path" 2>/dev/null | \
        ssh $(_ssh_common_opts) -o Compression=no -o BatchMode=yes \
            "${SSH_USER}@${TARGET}" "$remote_cmd" 2>&1 &
    local stream_pid=$!

    # Progress monitor: check remote disk usage every 15s
    local prev_delta_bytes=0
    local prev_elapsed=0
    while kill -0 "$stream_pid" 2>/dev/null; do
        sleep 15
        if ! kill -0 "$stream_pid" 2>/dev/null; then
            break
        fi
        local elapsed=$(( $(date +%s) - stream_start ))
        local cur_used_kb
        cur_used_kb=$(_ssh_target "df / --output=used 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "$before_used_kb")
        local delta_kb=$(( cur_used_kb - before_used_kb ))
        if [[ $delta_kb -lt 0 ]]; then delta_kb=0; fi
        local delta_bytes=$(( delta_kb * 1024 ))
        local pct_str=""
        if [[ $SNAPSHOT_TOTAL_BYTES -gt 0 && $delta_bytes -gt 0 ]]; then
            local pct=$(( (delta_bytes + total_restored_bytes) * 100 / SNAPSHOT_TOTAL_BYTES ))
            [[ $pct -gt 100 ]] && pct=100
            pct_str=" (${pct}% of total)"
        fi
        # Segment speed (last 15s) + average speed
        local speed_str=""
        local seg_seconds=$(( elapsed - prev_elapsed ))
        local seg_bytes=$(( delta_bytes - prev_delta_bytes ))
        if [[ $seg_seconds -gt 0 && $seg_bytes -gt 0 ]]; then
            speed_str=", $(_human_size $(( seg_bytes / seg_seconds )))/s"
        fi
        if [[ $elapsed -gt 0 && $delta_bytes -gt 0 ]]; then
            speed_str+=", avg $(_human_size $(( delta_bytes / elapsed )))/s"
        fi
        log_info "    ~$(_human_size $delta_bytes) written${pct_str}${speed_str}, $(_format_duration $elapsed) elapsed"
        prev_delta_bytes=$delta_bytes
        prev_elapsed=$elapsed
    done

    local stream_rc=0
    wait "$stream_pid" || stream_rc=$?

    local stream_end
    stream_end=$(date +%s)
    local duration=$((stream_end - stream_start))

    if [[ $stream_rc -ne 0 ]]; then
        log_error "  Streaming failed for $path (exit code: $stream_rc)"
        return $stream_rc
    fi

    # Calculate transferred bytes from disk usage delta
    local after_used_kb
    after_used_kb=$(_ssh_target "df / --output=used 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "$before_used_kb")
    local path_bytes=$(( (after_used_kb - before_used_kb) * 1024 ))
    [[ $path_bytes -lt 0 ]] && path_bytes=0
    total_restored_bytes=$((total_restored_bytes + path_bytes))

    local speed="N/A"
    if [[ $duration -gt 0 && $path_bytes -gt 0 ]]; then
        speed="$(_human_size $(( path_bytes / duration )))/s"
    fi
    log_info "  $path done: ~$(_human_size $path_bytes) in $(_format_duration $duration) ($speed)"

    # Verify SSH connectivity — the inline fixup may have restarted sshd,
    # so the ControlMaster may be stale. Re-establish if needed.
    if ! _ssh_target true 2>/dev/null; then
        log_info "  Re-establishing SSH after streaming $path (fixup restarted sshd)..."
        _cleanup_ssh_control
        ssh-keygen -R "$TARGET" 2>/dev/null || true
        ssh-keygen -R "[$TARGET]:$SSH_PORT" 2>/dev/null || true
        local ssh_ok=false
        local wait_secs=3
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            sleep "$wait_secs"
            if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=8 -o BatchMode=yes \
                -p "$SSH_PORT" "${SSH_USER}@${TARGET}" true 2>/dev/null; then
                _setup_ssh_control
                if _ssh_target true 2>/dev/null; then
                    ssh_ok=true
                    break
                fi
                _cleanup_ssh_control
            fi
            [[ $wait_secs -lt 10 ]] && wait_secs=$((wait_secs + 1))
        done
        if ! $ssh_ok; then
            log_error "  SSH connectivity lost after streaming $path"
            report_ko "SSH connectivity lost after streaming $path"
            failed_paths+=("$path")
            return 1
        fi
        log_info "  SSH recovered after streaming $path (attempt $attempt)"
    fi

    # Check target disk space
    local target_avail_kb
    target_avail_kb=$(_ssh_target "df / --output=avail 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "0")
    if [[ "$target_avail_kb" =~ ^[0-9]+$ ]]; then
        local target_avail_gb=$((target_avail_kb / 1048576))
        if [[ $target_avail_gb -lt 2 ]]; then
            log_warn "  Target disk space critically low: ${target_avail_gb} GB remaining"
            report_warn "Target disk space low after $path: ${target_avail_gb} GB remaining"
        fi
    fi

    return 0
}

# Stream entire snapshot to target in a single restic dump (no per-path overhead).
# Each per-path dump has ~15s of tree-walk overhead; a single dump eliminates this.
# Uses: restic dump --archive tar / | ssh tar xf -
_stream_full_to_target() {
    log_info "Streaming full snapshot to target (single dump, no local writes)..."

    # Full dump = all paths at once; set path to "/" so fixup does full repair
    _set_restore_path "/"

    # Build tar exclusions — only Coolify SSH keys (handled in Phase 3)
    local tar_excludes=""
    tar_excludes+=" --exclude='data/coolify/ssh/keys'"
    tar_excludes+=" --exclude='data/coolify/ssh/id.*'"

    # Build remote command: tar extract + inline SSH fixup
    local _sudo=""
    [[ "$SSH_USER" != "root" ]] && _sudo="sudo "
    local remote_cmd="${_sudo}bash -c 'tar xf - -C / ${tar_excludes}; RC=\$?; chmod 755 / 2>/dev/null || true; /tmp/computile-ssh-fixup.sh 2>/dev/null || true; exit \$RC'"

    # Get target disk usage before streaming (for transferred bytes estimate)
    local before_used_kb
    before_used_kb=$(_ssh_target "df / --output=used 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "0")

    local stream_start
    stream_start=$(date +%s)

    # Single restic dump of entire snapshot — avoids repeated tree-walk overhead
    # Compression=no: restic output is already decompressed, SSH compression wastes CPU
    restic dump --archive tar --no-lock "$SNAPSHOT_ID" / 2>/dev/null | \
        ssh $(_ssh_common_opts) -o Compression=no -o BatchMode=yes \
            "${SSH_USER}@${TARGET}" "$remote_cmd" 2>&1 &
    local stream_pid=$!

    # Progress monitor: check remote disk usage every 15s
    local prev_delta_bytes=0
    local prev_elapsed=0
    while kill -0 "$stream_pid" 2>/dev/null; do
        sleep 15
        if ! kill -0 "$stream_pid" 2>/dev/null; then
            break
        fi
        local elapsed=$(( $(date +%s) - stream_start ))
        local cur_used_kb
        cur_used_kb=$(_ssh_target "df / --output=used 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "$before_used_kb")
        local delta_kb=$(( cur_used_kb - before_used_kb ))
        if [[ $delta_kb -lt 0 ]]; then delta_kb=0; fi
        local delta_bytes=$(( delta_kb * 1024 ))
        local pct_str=""
        if [[ $SNAPSHOT_TOTAL_BYTES -gt 0 && $delta_bytes -gt 0 ]]; then
            local pct=$(( delta_bytes * 100 / SNAPSHOT_TOTAL_BYTES ))
            [[ $pct -gt 100 ]] && pct=100
            pct_str=" (${pct}% of total)"
        fi
        # Segment speed (last 15s) + average speed
        local speed_str=""
        local seg_seconds=$(( elapsed - prev_elapsed ))
        local seg_bytes=$(( delta_bytes - prev_delta_bytes ))
        if [[ $seg_seconds -gt 0 && $seg_bytes -gt 0 ]]; then
            speed_str=", $(_human_size $(( seg_bytes / seg_seconds )))/s"
        fi
        if [[ $elapsed -gt 0 && $delta_bytes -gt 0 ]]; then
            speed_str+=", avg $(_human_size $(( delta_bytes / elapsed )))/s"
        fi
        log_info "    ~$(_human_size $delta_bytes) written${pct_str}${speed_str}, $(_format_duration $elapsed) elapsed"
        prev_delta_bytes=$delta_bytes
        prev_elapsed=$elapsed
    done

    local stream_rc=0
    wait "$stream_pid" || stream_rc=$?

    local stream_end
    stream_end=$(date +%s)
    local duration=$((stream_end - stream_start))

    if [[ $stream_rc -ne 0 ]]; then
        log_error "Full snapshot streaming failed (exit code: $stream_rc)"
        return $stream_rc
    fi

    # Calculate transferred bytes from disk usage delta
    local after_used_kb
    after_used_kb=$(_ssh_target "df / --output=used 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "$before_used_kb")
    total_restored_bytes=$(( (after_used_kb - before_used_kb) * 1024 ))
    [[ $total_restored_bytes -lt 0 ]] && total_restored_bytes=0

    local speed="N/A"
    if [[ $duration -gt 0 && $total_restored_bytes -gt 0 ]]; then
        speed="$(_human_size $(( total_restored_bytes / duration )))/s"
    fi
    log_info "Full snapshot done: ~$(_human_size $total_restored_bytes) in $(_format_duration $duration) ($speed)"

    # Verify SSH connectivity — the inline fixup may have restarted sshd
    if ! _ssh_target true 2>/dev/null; then
        log_info "Re-establishing SSH after full snapshot streaming (fixup restarted sshd)..."
        _cleanup_ssh_control
        ssh-keygen -R "$TARGET" 2>/dev/null || true
        ssh-keygen -R "[$TARGET]:$SSH_PORT" 2>/dev/null || true
        local ssh_ok=false
        local wait_secs=3
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            sleep "$wait_secs"
            if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=8 -o BatchMode=yes \
                -p "$SSH_PORT" "${SSH_USER}@${TARGET}" true 2>/dev/null; then
                _setup_ssh_control
                if _ssh_target true 2>/dev/null; then
                    ssh_ok=true
                    break
                fi
                _cleanup_ssh_control
            fi
            [[ $wait_secs -lt 10 ]] && wait_secs=$((wait_secs + 1))
        done
        if ! $ssh_ok; then
            log_error "SSH connectivity lost after full snapshot streaming"
            report_ko "SSH connectivity lost after full snapshot streaming"
            return 1
        fi
        log_info "SSH recovered after full snapshot streaming (attempt $attempt)"
    fi

    # Check target disk space
    local target_avail_kb
    target_avail_kb=$(_ssh_target "df / --output=avail 2>/dev/null | tail -1 | tr -d ' '" 2>/dev/null || echo "0")
    if [[ "$target_avail_kb" =~ ^[0-9]+$ ]]; then
        local target_avail_gb=$((target_avail_kb / 1048576))
        if [[ $target_avail_gb -lt 2 ]]; then
            log_warn "Target disk space critically low: ${target_avail_gb} GB remaining"
            report_warn "Target disk space low after restore: ${target_avail_gb} GB remaining"
        fi
    fi

    return 0
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
        --inputbox "Enter the target VM hostname or Tailscale IP.\n\nIMPORTANT: the target must be tagged 'tag:computile' in Tailscale.\nRun on the target: sudo tailscale set --advertise-tags=tag:computile" \
        14 $WT_WIDTH "" \
        3>&1 1>&2 2>&3) || return 1

    echo "$target"
}

_check_tailscale_connectivity() {
    local target="$1"

    # Check if tailscale is available
    if ! command -v tailscale &>/dev/null; then
        log_warn "tailscale command not found, skipping connectivity check"
        return 0
    fi

    log_info "Checking Tailscale connectivity to ${target}..."
    local ping_output
    if ping_output=$(timeout 5 tailscale ping --c 1 "$target" 2>&1); then
        log_info "  -> Tailscale connectivity OK"
        return 0
    else
        log_error "  -> Tailscale connectivity FAILED"
        log_error "  Output: ${ping_output}"

        # If in TUI mode, show a dialog with details
        if [[ -n "$DIALOG" ]]; then
            local msg="Cannot reach ${target} via Tailscale.\n\n"
            msg+="This could be:\n"
            msg+="  - The target is offline\n"
            msg+="  - Tailscale ACLs block access from this gateway\n"
            msg+="  - The hostname/IP is incorrect\n"
            msg+="  - The target is not tagged 'tag:computile'\n\n"
            if [[ -n "$ping_output" ]]; then
                msg+="Details:\n${ping_output}\n\n"
            fi
            msg+="Ensure the target is tagged correctly:\n"
            msg+="  sudo tailscale set --advertise-tags=tag:computile\n\n"
            msg+="Then check your Tailscale admin console for ACL rules."
            _msg_box "Restore Test — Tailscale Error" "$msg"
        fi
        return 1
    fi
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
  --ssh-user USER        SSH user on target (default: computile-restore)
  --ssh-port PORT        SSH port on target (default: 22)
  --skip-db-restore      Skip database restoration phase
  --skip-cleanup         Do not clean up temp files
  --start-from-phase N   Skip phases before N (2=skip restore, 3=skip restore+platform, etc.)
  --report-dir DIR       Report output directory (default: /var/log/computile-backup/)
  --dry-run              Show what would be done without executing
  --help                 Show this help

Phases:
  1  Pre-flight checks (always runs)
  2  File restore (streaming: restic dump → ssh → tar)
  3  Platform (Coolify install, SSH keys, APP_KEY)
  4  Database restore
  5  Verification
  6  Cleanup

Examples:
  # Interactive mode (TUI selection)
  sudo computile-restore-test --interactive

  # Non-interactive (for scripting/CI)
  sudo computile-restore-test --client mycompany --vps vps-prod-01 --target test-vm.tail1234.ts.net

  # Test specific snapshot
  sudo computile-restore-test --client mycompany --vps vps-prod-01 --target test-vm --snapshot a1b2c3d4

  # Resume from Phase 3 after a successful file restore
  sudo computile-restore-test --client mycompany --vps vps-prod-01 --target test-vm --start-from-phase 3
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
            --start-from-phase) START_FROM_PHASE="$2"; shift 2 ;;
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

        # Verify Tailscale connectivity before going further
        _check_tailscale_connectivity "$TARGET" || exit 1

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
        ROLE=$(grep -E '^ROLE=' "$config_file" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | sed 's/[[:space:]]*#.*//' | xargs || true)
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

    # Check Tailscale connectivity (skip if already checked in interactive phase 0)
    if [[ "$INTERACTIVE" == true ]]; then
        report_ok "Tailscale connectivity to ${TARGET} (checked in phase 0)"
    elif $DRY_RUN; then
        report_ok "Tailscale connectivity (dry-run)"
    elif _check_tailscale_connectivity "$TARGET"; then
        report_ok "Tailscale connectivity to ${TARGET}"
    else
        report_ko "Tailscale connectivity to ${TARGET} — check ACLs or target status"
        die "Cannot reach target via Tailscale. Aborting."
    fi

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

    # Ensure passwordless sudo for SSH_USER (required for all restore operations)
    # Skip when resuming from a later phase — user may have configured target manually
    if ! $DRY_RUN && [[ "$SSH_USER" != "root" ]] && [[ $START_FROM_PHASE -le 1 ]]; then
        log_info "Checking passwordless sudo for ${SSH_USER}..."
        if _ssh_target "sudo -n true" &>/dev/null; then
            report_ok "Passwordless sudo for ${SSH_USER}"
        else
            log_info "  Configuring passwordless sudo for ${SSH_USER}..."
            # Try to set up NOPASSWD via the existing SSH session (user may have
            # password-based sudo or be in a group with partial sudo access)
            if _ssh_target "echo '${SSH_USER} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/${SSH_USER} >/dev/null && sudo chmod 440 /etc/sudoers.d/${SSH_USER}" &>/dev/null; then
                if _ssh_target "sudo -n true" &>/dev/null; then
                    report_ok "Passwordless sudo configured for ${SSH_USER}"
                else
                    report_ko "Passwordless sudo for ${SSH_USER}"
                    die "Cannot configure passwordless sudo. Set it up manually:\n  echo '${SSH_USER} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/${SSH_USER}\n  sudo chmod 440 /etc/sudoers.d/${SSH_USER}"
                fi
            else
                report_ko "Passwordless sudo for ${SSH_USER}"
                die "Cannot configure passwordless sudo. Set it up manually:\n  echo '${SSH_USER} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/${SSH_USER}\n  sudo chmod 440 /etc/sudoers.d/${SSH_USER}"
            fi
        fi
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

    # Check target memory
    if ! $DRY_RUN; then
        local total_mem_kb
        total_mem_kb=$(_ssh_target "grep '^MemTotal:' /proc/meminfo 2>/dev/null | awk '{print \$2}'" || echo "0")
        if [[ "$total_mem_kb" =~ ^[0-9]+$ && "$total_mem_kb" -gt 0 ]]; then
            local total_mem_mb=$((total_mem_kb / 1024))
            local total_mem_gb=$(awk "BEGIN {printf \"%.1f\", ${total_mem_kb}/1048576}")
            if [[ $total_mem_mb -ge 4096 ]]; then
                report_ok "Memory: ${total_mem_gb} GB"
            elif [[ $total_mem_mb -ge 2048 ]]; then
                report_warn "Memory: ${total_mem_gb} GB (recommend 4 GB+ for Coolify restores)"
            else
                report_warn "Memory: ${total_mem_gb} GB (low — may cause OOM or heavy swap during restore)"
            fi
        else
            report_warn "Could not determine target memory"
        fi
    else
        report_ok "Memory check (dry-run)"
    fi

    # Check gateway disk space (for local restore before rsync)
    if ! $DRY_RUN; then
        local gw_avail_kb
        gw_avail_kb=$(df /var/tmp --output=avail 2>/dev/null | tail -1 | tr -d ' ')
        if [[ "$gw_avail_kb" =~ ^[0-9]+$ ]]; then
            local gw_avail_gb=$((gw_avail_kb / 1048576))
            if [[ $gw_avail_gb -ge 5 ]]; then
                report_ok "Gateway disk space: ${gw_avail_gb} GB available on /var/tmp"
            elif [[ $gw_avail_gb -ge 2 ]]; then
                report_warn "Gateway disk space: ${gw_avail_gb} GB available on /var/tmp (low — restore may fail for large paths)"
            else
                report_ko "Gateway disk space: ${gw_avail_gb} GB available on /var/tmp (minimum 2 GB required)"
                die "Insufficient disk space on gateway for restore temp files. Aborting."
            fi
        fi
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

    if $DRY_RUN; then
        report_ok "Streaming restore to target (dry-run)"
        return 0
    fi

    # Verify restic dump support (--archive tar, available since restic 0.10)
    log_info "Verifying restic streaming support..."
    local restic_ver
    restic_ver=$(restic version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' | head -1 || true)
    local restic_major restic_minor
    restic_major=$(echo "$restic_ver" | cut -d. -f1)
    restic_minor=$(echo "$restic_ver" | cut -d. -f2)
    if [[ "${restic_major:-0}" -eq 0 && "${restic_minor:-0}" -lt 10 ]]; then
        die "restic ${restic_ver:-unknown} does not support streaming (dump --archive tar). Requires >= 0.10."
    fi
    log_info "  Streaming mode: restic dump → ssh → tar (no local disk writes)"

    # Install prerequisites on target first (use sudo if not root)
    log_info "Installing prerequisites on target..."
    local _sudo=""
    [[ "$SSH_USER" != "root" ]] && _sudo="sudo"
    local prereqs="gzip curl rsync"
    if _ssh_target "${_sudo} DEBIAN_FRONTEND=noninteractive apt-get update -qq && ${_sudo} apt-get install -y -qq ${prereqs}" &>/dev/null; then
        report_ok "Target prerequisites installed"
    else
        report_warn "Could not install prerequisites (may already be present)"
    fi

    # Get total snapshot size for progress percentage (with timeout to avoid OOM on huge repos)
    SNAPSHOT_TOTAL_BYTES=0
    log_info "Calculating snapshot size (timeout: 10s)..."
    local stats_json
    stats_json=$(timeout 10 restic stats --no-lock "$SNAPSHOT_ID" --json 2>/dev/null) || true
    if [[ -n "$stats_json" ]]; then
        SNAPSHOT_TOTAL_BYTES=$(echo "$stats_json" | grep -oP '"total_size":\s*\K[0-9]+' || echo "0")
        log_info "Snapshot total size: $(_human_size "$SNAPSHOT_TOTAL_BYTES")"
    else
        log_warn "Could not determine snapshot size (restic stats timed out or failed) — progress percentage will not be shown"
    fi

    local restore_start
    restore_start=$(date +%s)
    local total_restored_bytes=0

    # Save SSH user identity from target BEFORE any restore overwrites /etc.
    # The fixup script will re-inject the user + keys + host keys after each rsync/tar.
    log_info "Saving SSH user '${SSH_USER}' identity from target before restore..."
    local _sudo_save=""
    [[ "$SSH_USER" != "root" ]] && _sudo_save="sudo "

    local fixup_ok=false
    if _ssh_target "${_sudo_save}bash -s" <<SAVE_EOF 2>/dev/null; then
set -e
SAVE_DIR="/tmp/computile-ssh-save"
rm -rf "\$SAVE_DIR" && mkdir -p "\$SAVE_DIR/ssh"

# User identity
grep "^${SSH_USER}:" /etc/passwd > "\$SAVE_DIR/passwd_line" || true
grep "^${SSH_USER}:" /etc/shadow > "\$SAVE_DIR/shadow_line" 2>/dev/null || true
grep "^${SSH_USER}:" /etc/group > "\$SAVE_DIR/group_line" 2>/dev/null || true
id -nG "${SSH_USER}" > "\$SAVE_DIR/groups" 2>/dev/null || true

# Sudoers
if [ -f "/etc/sudoers.d/${SSH_USER}" ]; then
    cp "/etc/sudoers.d/${SSH_USER}" "\$SAVE_DIR/sudoers_file"
fi

# Authorized keys
home=\$(eval echo "~${SSH_USER}")
if [ -f "\${home}/.ssh/authorized_keys" ]; then
    cp "\${home}/.ssh/authorized_keys" "\$SAVE_DIR/authorized_keys"
fi
echo "\${home}" > "\$SAVE_DIR/home_dir"

# SSH host keys (preserve sshd identity so gateway can reconnect)
cp /etc/ssh/ssh_host_* "\$SAVE_DIR/ssh/" 2>/dev/null || true
cp /etc/ssh/sshd_config "\$SAVE_DIR/ssh/" 2>/dev/null || true

# PAM + nsswitch (critical for SSH session creation after /etc rsync)
mkdir -p "\$SAVE_DIR/pam"
cp /etc/nsswitch.conf "\$SAVE_DIR/pam/" 2>/dev/null || true
cp /etc/shells "\$SAVE_DIR/pam/" 2>/dev/null || true
cp /etc/login.defs "\$SAVE_DIR/pam/" 2>/dev/null || true
cp -a /etc/pam.d "\$SAVE_DIR/pam/" 2>/dev/null || true

# Save sshd config snippet for AuthorizedKeysFile (created by _setup_resilient_ssh)
if [ -f /etc/ssh/sshd_config.d/99-computile-restore.conf ]; then
    cp /etc/ssh/sshd_config.d/99-computile-restore.conf "\$SAVE_DIR/sshd_snippet"
fi

# Save system-wide authorized_keys if it exists
if [ -f "/etc/ssh/authorized_keys/${SSH_USER}" ]; then
    cp "/etc/ssh/authorized_keys/${SSH_USER}" "\$SAVE_DIR/syswide_authorized_keys"
fi
SAVE_EOF
        log_info "  Saved: user entry, groups, authorized_keys, host keys"

        # Set up resilient SSH: store keys in /etc/ssh/authorized_keys/ (outside /home)
        _setup_resilient_ssh

        # Now save the newly created sshd snippet into the save dir
        _ssh_target "${_sudo_save}bash -c '
            SAVE_DIR=/tmp/computile-ssh-save
            [ -f /etc/ssh/sshd_config.d/99-computile-restore.conf ] && cp /etc/ssh/sshd_config.d/99-computile-restore.conf \$SAVE_DIR/sshd_snippet 2>/dev/null || true
            [ -f /etc/ssh/authorized_keys/${SSH_USER} ] && cp /etc/ssh/authorized_keys/${SSH_USER} \$SAVE_DIR/syswide_authorized_keys 2>/dev/null || true
        '" 2>/dev/null || true

        log_info "  Deploying SSH fixup script on target..."
        _deploy_ssh_fixup
        fixup_ok=true
    else
        log_warn "  Could not save SSH user identity — SSH may break after /etc restore"
    fi

    # ── Try single full dump first (avoids ~15s overhead per path) ──
    log_info "Attempting single full-snapshot streaming dump..."
    if _stream_full_to_target; then
        local restore_end
        restore_end=$(date +%s)
        local restore_duration=$((restore_end - restore_start))
        local total_human
        total_human=$(_human_size "$total_restored_bytes")
        local avg_speed="N/A"
        if [[ $restore_duration -gt 0 && $total_restored_bytes -gt 0 ]]; then
            avg_speed="$(_human_size $(( total_restored_bytes / restore_duration )))/s"
        fi
        log_info "Phase 2 summary: ${total_human} transferred in $(_format_duration $restore_duration), average speed: ${avg_speed}"
        report_ok "Restore complete (streaming, single dump): ~${total_human} in $(_format_duration $restore_duration) (avg ${avg_speed})"
        return 0
    fi
    log_warn "Single full dump failed — falling back to per-path streaming..."

    # ── Per-path streaming fallback ──

    # Get the list of paths in the snapshot
    log_info "Listing paths in snapshot '$SNAPSHOT_ID'..."
    local snapshot_paths
    snapshot_paths=$(restic snapshots --no-lock "$SNAPSHOT_ID" --json 2>/dev/null \
        | grep -oP '"paths":\s*\[\K[^\]]+' \
        | tr ',' '\n' | tr -d '"' | tr -d ' ') || true

    if [[ -z "$snapshot_paths" ]]; then
        # Fallback: try to detect paths from restic ls (top-level dirs)
        log_warn "Could not parse paths from snapshot metadata, using restic ls..."
        snapshot_paths=$(restic ls --no-lock "$SNAPSHOT_ID" / 2>/dev/null \
            | head -20 | grep -E '^/[^/]+$' | sort -u) || true
    fi

    if [[ -z "$snapshot_paths" ]]; then
        log_error "Could not determine snapshot paths"
        report_ko "Could not determine snapshot paths"
        return 1
    fi

    # Deduplicate: if a path is a prefix of another, keep only the parent
    # e.g., /data and /data/coolify → keep only /data
    local dedup_paths=""
    local path
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        local is_subpath=false
        local existing
        while IFS= read -r existing; do
            [[ -z "$existing" ]] && continue
            if [[ "$path" == "$existing"/* ]]; then
                is_subpath=true
                break
            fi
        done <<< "$dedup_paths"
        if ! $is_subpath; then
            # Remove any existing paths that are subpaths of this one
            local new_dedup=""
            while IFS= read -r existing; do
                [[ -z "$existing" ]] && continue
                if [[ "$existing" != "$path"/* ]]; then
                    new_dedup+="${existing}"$'\n'
                fi
            done <<< "$dedup_paths"
            dedup_paths="${new_dedup}${path}"$'\n'
        fi
    done <<< "$snapshot_paths"

    # Convert to array
    local -a paths=()
    while IFS= read -r path; do
        [[ -n "$path" ]] && paths+=("$path")
    done <<< "$dedup_paths"

    local total_paths=${#paths[@]}
    log_info "Snapshot contains $total_paths top-level path(s): ${paths[*]}"

    # Sort paths: /etc second-to-last and /data last.
    # /etc must be restored AFTER /home, /opt, etc. because rsync of /etc replaces
    # PAM, nsswitch, sshd config — which breaks new SSH channels through ControlMaster.
    # By doing /etc near the end, all other paths are already restored when SSH breaks.
    local -a sorted_paths=()
    local data_path=""
    local etc_path=""
    for path in "${paths[@]}"; do
        if [[ "$path" == "/data" || "$path" == "/data/"* ]]; then
            data_path="$path"
        elif [[ "$path" == "/etc" || "$path" == "/etc/"* ]]; then
            etc_path="$path"
        else
            sorted_paths+=("$path")
        fi
    done
    [[ -n "$etc_path" ]] && sorted_paths+=("$etc_path")
    [[ -n "$data_path" ]] && sorted_paths+=("$data_path")
    paths=("${sorted_paths[@]}")
    log_info "Restore order: ${paths[*]}"

    # Stream each path individually
    local path_idx=0
    local failed_paths=()

    for path in "${paths[@]}"; do
        path_idx=$((path_idx + 1))

        _set_restore_path "$path"

        if ! _stream_path_to_target "$path" "[$path_idx/$total_paths]"; then
            failed_paths+=("$path")
        fi

        # After each stream, check if SSH is still alive and re-establish if needed.
        if ! _ssh_target true 2>/dev/null; then
            log_info "SSH broken after $path — re-establishing connection..."
            _cleanup_ssh_control
            ssh-keygen -R "$TARGET" 2>/dev/null || true
            ssh-keygen -R "[$TARGET]:$SSH_PORT" 2>/dev/null || true
            local ssh_ok=false
            local wait_secs=3
            for attempt in 1 2 3 4 5 6 7 8 9 10; do
                sleep "$wait_secs"
                if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=8 -o BatchMode=yes \
                    -p "$SSH_PORT" "${SSH_USER}@${TARGET}" true 2>/dev/null; then
                    _setup_ssh_control
                    if _ssh_target true 2>/dev/null; then
                        ssh_ok=true
                        log_info "SSH re-established after $path (attempt $attempt)"
                        break
                    fi
                    _cleanup_ssh_control
                fi
                [[ $wait_secs -lt 10 ]] && wait_secs=$((wait_secs + 1))
            done
            if ! $ssh_ok; then
                log_error "Could not re-establish SSH after $path — aborting remaining paths"
                break
            fi
        fi
    done

    local restore_end
    restore_end=$(date +%s)
    local restore_duration=$((restore_end - restore_start))
    local total_human
    total_human=$(_human_size "$total_restored_bytes")

    local avg_speed="N/A"
    if [[ $restore_duration -gt 0 && $total_restored_bytes -gt 0 ]]; then
        local bytes_per_sec=$((total_restored_bytes / restore_duration))
        avg_speed="$(_human_size "$bytes_per_sec")/s"
    fi
    log_info "Phase 2 summary: ${total_human} transferred in $(_format_duration $restore_duration), average speed: ${avg_speed}"

    if [[ ${#failed_paths[@]} -eq 0 ]]; then
        report_ok "Restore complete (streaming): ~${total_human} transferred in $(_format_duration $restore_duration) ($total_paths path(s), avg ${avg_speed})"
    else
        report_ko "Restore completed with ${#failed_paths[@]} failure(s): ${failed_paths[*]}"
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

    # Step 1: Save old APP_KEY from the backup (rsync'd to target in Phase 2)
    log_info "Reading old APP_KEY from restored backup..."
    local old_app_key
    old_app_key=$(_ssh_target "grep '^APP_KEY=' /data/coolify/source/.env 2>/dev/null | cut -d= -f2" || true)
    if [[ -n "$old_app_key" ]]; then
        log_info "  Old APP_KEY saved"
    else
        log_warn "  Could not read old APP_KEY from backup"
    fi

    # Step 2: Install Coolify on target (generates new APP_KEY)
    # Must run as root; pipe through sudo bash to ensure elevated privileges.
    # Use bash -e so any failure inside the install script propagates.
    log_info "Installing Coolify on target..."
    local _sudo_coolify=""
    [[ "$SSH_USER" != "root" ]] && _sudo_coolify="sudo "
    if _ssh_target "${_sudo_coolify}bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -e'" 2>&1; then
        report_ok "Coolify installed on target"
    else
        report_ko "Coolify installation failed"
        return 1
    fi

    # Step 3: Save new APP_KEY
    log_info "Reading new APP_KEY..."
    local new_app_key
    new_app_key=$(_ssh_target "grep '^APP_KEY=' /data/coolify/source/.env 2>/dev/null | cut -d= -f2" || true)
    if [[ -z "$new_app_key" ]]; then
        report_warn "Could not read new APP_KEY"
    fi

    # Step 4: Stop Coolify containers
    log_info "Stopping Coolify containers..."
    _ssh_target "${_sudo_coolify}docker stop coolify coolify-redis coolify-realtime coolify-proxy coolify-db 2>/dev/null || true"
    report_ok "Coolify containers stopped"

    # Step 5: Restore Coolify SSH keys (excluded from Phase 2 rsync to protect SSH)
    # Do a targeted restic restore + rsync just for SSH keys
    log_info "Restoring Coolify SSH keys from backup..."
    local ssh_temp
    ssh_temp=$(mktemp -d /var/tmp/computile-coolify-ssh-XXXXXX)

    if restic restore --no-lock "$SNAPSHOT_ID" \
        --target "$ssh_temp" --include "/data/coolify/ssh" \
        >"${ssh_temp}.log" 2>&1; then

        if [[ -d "${ssh_temp}/data/coolify/ssh" ]]; then
            local rsync_rsh
            rsync_rsh=$(_rsync_ssh_cmd)
            rsync -az -e "$rsync_rsh" \
                --rsync-path="${_sudo_coolify}rsync" \
                "${ssh_temp}/data/coolify/ssh/" "${SSH_USER}@${TARGET}:/data/coolify/ssh/" 2>&1

            # Fix SSH key permissions
            _ssh_target "${_sudo_coolify}bash -c '
                if [[ -d /data/coolify/ssh/keys ]]; then
                    chown -R root:root /data/coolify/ssh/keys/
                    chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
                fi
            '"

            local key_count
            key_count=$(_ssh_target "ls /data/coolify/ssh/keys/ 2>/dev/null | wc -l" || echo "0")
            report_ok "Coolify SSH keys restored (${key_count} keys)"
        else
            report_warn "No /data/coolify/ssh found in backup"
        fi
    else
        log_error "  Restic restore of Coolify SSH keys failed"
        report_ko "Coolify SSH keys restore failed"
    fi
    rm -rf "$ssh_temp" "${ssh_temp}.log"

    # Step 6: Configure APP_PREVIOUS_KEYS
    log_info "Configuring APP_PREVIOUS_KEYS..."
    if [[ -n "$old_app_key" && -n "$new_app_key" && "$old_app_key" != "$new_app_key" ]]; then
        _ssh_target "
            sed -i '/^APP_PREVIOUS_KEYS=/d' /data/coolify/source/.env
            echo 'APP_PREVIOUS_KEYS=${old_app_key}' >> /data/coolify/source/.env
        "
        report_ok "APP_PREVIOUS_KEYS configured"
    elif [[ "$old_app_key" == "$new_app_key" ]]; then
        report_ok "APP_KEY unchanged (no APP_PREVIOUS_KEYS needed)"
    else
        report_warn "Could not configure APP_PREVIOUS_KEYS (missing keys)"
    fi

    # Step 7: Restart Coolify
    log_info "Restarting Coolify..."
    if _ssh_target "${_sudo_coolify}bash -c 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -e'" 2>&1; then
        report_ok "Coolify restarted"
    else
        report_ko "Coolify restart failed"
    fi

    # Wait for Coolify to be ready
    log_info "Waiting for Coolify containers to start..."
    local waited=0
    while [[ $waited -lt 60 ]]; do
        if _ssh_target "${_sudo_coolify}docker ps --filter name=coolify --format '{{.Names}}' 2>/dev/null | grep -q '^coolify$'"; then
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

    # DB dumps were rsync'd to target in Phase 2 — operate remotely
    local dump_base="/var/backups/computile/db"

    if ! _ssh_target "test -d '$dump_base'" 2>/dev/null; then
        report_skip "No database dumps found on target"
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
    local mysql_dir="$1"  # remote path on target

    # List dumps on target
    local dump_list
    dump_list=$(_ssh_target "find '$mysql_dir' -name '*.sql.gz' 2>/dev/null") || true
    [[ -z "$dump_list" ]] && return 0

    local dump_count
    dump_count=$(echo "$dump_list" | wc -l)
    log_info "Found ${dump_count} MySQL dump(s) on target"

    while IFS= read -r dump_path; do
        [[ -z "$dump_path" ]] && continue
        local filename
        filename=$(basename "$dump_path")
        local dump_size
        dump_size=$(_ssh_target "stat -c%s '${dump_path}'" 2>/dev/null || echo "0")
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
            target_container=$(_ssh_target "docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep -iE 'mysql|mariadb' | head -1 | cut -f1" || true)
        fi

        if [[ -z "$target_container" ]]; then
            report_warn "${container}/${db} (mysql, ${size_human}): no MySQL container found on target"
            continue
        fi

        if ! _wait_for_container "$target_container" 60; then
            report_ko "${container}/${db} (mysql, ${size_human}): container not ready"
            continue
        fi

        # Extract MySQL password from container env
        local mysql_pass
        mysql_pass=$(_ssh_target "docker exec ${target_container} env 2>/dev/null | grep -E '^(MYSQL_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD)=' | head -1 | cut -d= -f2" || true)

        local pass_arg=""
        [[ -n "$mysql_pass" ]] && pass_arg="-p${mysql_pass}"

        # Import directly from target filesystem (no SCP needed)
        if _ssh_target "gunzip -c '${dump_path}' | docker exec -i '${target_container}' mysql -u root ${pass_arg} '${db}'" 2>&1; then
            report_ok "${container}/${db} (mysql, ${size_human})"
        else
            report_ko "${container}/${db} (mysql, ${size_human}): import failed"
        fi
    done <<< "$dump_list"
}

_restore_postgres_dumps() {
    local pg_dir="$1"  # remote path on target

    local dump_list
    dump_list=$(_ssh_target "find '$pg_dir' -name '*.sql.gz' 2>/dev/null") || true
    [[ -z "$dump_list" ]] && return 0

    local dump_count
    dump_count=$(echo "$dump_list" | wc -l)
    log_info "Found ${dump_count} PostgreSQL dump(s) on target"

    while IFS= read -r dump_path; do
        [[ -z "$dump_path" ]] && continue
        local filename
        filename=$(basename "$dump_path")
        local dump_size
        dump_size=$(_ssh_target "stat -c%s '${dump_path}'" 2>/dev/null || echo "0")
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

        # Determine postgres user
        local pg_user
        pg_user=$(_ssh_target "docker exec ${target_container} env 2>/dev/null | grep '^POSTGRES_USER=' | cut -d= -f2" || true)
        pg_user="${pg_user:-postgres}"

        # Import directly from target filesystem
        if _ssh_target "gunzip -c '${dump_path}' | docker exec -i '${target_container}' psql -U '${pg_user}' -d '${db}'" 2>&1; then
            report_ok "${container}/${db} (postgres, ${size_human})"
        else
            report_ko "${container}/${db} (postgres, ${size_human}): import failed"
        fi
    done <<< "$dump_list"
}

_restore_redis_dumps() {
    local redis_dir="$1"  # remote path on target

    local dump_list
    dump_list=$(_ssh_target "find '$redis_dir' -name '*.rdb' 2>/dev/null") || true
    if [[ -z "$dump_list" ]]; then
        report_skip "Redis (no dumps found)"
        return 0
    fi

    local dump_count
    dump_count=$(echo "$dump_list" | wc -l)
    log_info "Found ${dump_count} Redis dump(s) on target"

    while IFS= read -r dump_path; do
        [[ -z "$dump_path" ]] && continue
        local filename
        filename=$(basename "$dump_path")
        local dump_size
        dump_size=$(_ssh_target "stat -c%s '${dump_path}'" 2>/dev/null || echo "0")
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

        # Import directly from target filesystem
        if _ssh_target "
            docker exec '${target_container}' redis-cli SHUTDOWN NOSAVE 2>/dev/null || true
            sleep 2
            docker cp '${dump_path}' '${target_container}:/data/dump.rdb'
            docker start '${target_container}' 2>/dev/null || true
        " 2>&1; then
            report_ok "${container} (redis, ${size_human})"
        else
            report_ko "${container} (redis, ${size_human}): restore failed"
        fi
    done <<< "$dump_list"
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

    # Check Docker (may need sudo if SSH user is not in docker group)
    local _sudo_v=""
    [[ "$SSH_USER" != "root" ]] && _sudo_v="sudo "
    if _ssh_target "${_sudo_v}docker info" &>/dev/null; then
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
    local _sudo_vc=""
    [[ "$SSH_USER" != "root" ]] && _sudo_vc="sudo "

    # Check Coolify core containers
    local coolify_containers=("coolify" "coolify-db" "coolify-redis" "coolify-realtime" "coolify-proxy")

    for cname in "${coolify_containers[@]}"; do
        local status
        status=$(_ssh_target "${_sudo_vc}docker ps --filter name='^${cname}$' --format '{{.Status}}'" 2>/dev/null || true)
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

    # Remove SSH fixup script and saved identity from target
    _cleanup_ssh_fixup

    # In interactive mode, offer to clean up the target
    if [[ "$INTERACTIVE" == true && "$DRY_RUN" != true ]]; then
        if _yesno "Cleanup" "Do you want to clean up temp files on the target VM?"; then
            _ssh_target "rm -rf /tmp/restore-dump-* /tmp/computile-restore-*" 2>/dev/null || true
            log_info "Target temp files cleaned"
        fi
    fi
}

INTERRUPTED=false
REPORT_GENERATED=false

cleanup_on_exit() {
    local exit_code=$?

    # On interrupt (Ctrl+C), generate partial report — but only if not already generated
    if [[ $INTERRUPTED == true && $REPORT_GENERATED == false ]]; then
        if [[ -n "$START_TIME" && -n "$CLIENT" ]]; then
            echo ""
            log_warn "Restore test interrupted (exit code: $exit_code)"
            report_ko "Test interrupted (signal/error, exit code: $exit_code)"
            report_generate
        fi
    fi

    # Close SSH ControlMaster
    _cleanup_ssh_control
}

_on_interrupt() {
    INTERRUPTED=true
    echo ""
    log_warn "Caught interrupt signal — aborting..."
    exit 130
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

    # Setup cleanup and interrupt traps
    trap cleanup_on_exit EXIT
    trap _on_interrupt INT TERM

    START_TIME=$(date +%s)

    # Set up full session log (all stdout+stderr tee'd to file)
    mkdir -p "$REPORT_DIR"
    LOG_FILE="${REPORT_DIR}/restore-test-session-$(date '+%Y%m%d-%H%M%S').log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    log_info "Full session log: $LOG_FILE"

    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║   COMPUTILE RESTORE TEST                 ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    # Phase 0: Selection
    phase0_select

    # Setup SSH ControlMaster (reuse connections for performance)
    _setup_ssh_control

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

    # Validate --start-from-phase
    if [[ ! "$START_FROM_PHASE" =~ ^[1-6]$ ]]; then
        die "--start-from-phase must be between 1 and 6 (got: $START_FROM_PHASE)"
    fi
    if [[ $START_FROM_PHASE -gt 1 ]]; then
        log_info "Resuming from Phase ${START_FROM_PHASE} (phases 2-$((START_FROM_PHASE - 1)) skipped)"
    fi

    # Phase 1: Pre-flight (always runs — fast and required for SSH/sudo)
    phase1_preflight

    # Phase 2: Restore files
    if [[ $START_FROM_PHASE -le 2 ]]; then
        if ! phase2_restore_files; then
            log_error "File restore failed. Generating partial report."
            report_generate
            exit 1
        fi
    else
        log_section "PHASE 2: File Restore"
        report_phase "2" "FILE RESTORE"
        report_skip "Skipped (--start-from-phase $START_FROM_PHASE)"
    fi

    # Phase 3: Platform
    if [[ $START_FROM_PHASE -le 3 ]]; then
        phase3_platform || true
    else
        log_section "PHASE 3: Platform Restore"
        report_phase "3" "PLATFORM"
        report_skip "Skipped (--start-from-phase $START_FROM_PHASE)"
    fi

    # Phase 4: Databases
    if [[ $START_FROM_PHASE -le 4 ]]; then
        phase4_databases || true
    else
        log_section "PHASE 4: Database Restore"
        report_phase "4" "DATABASES"
        report_skip "Skipped (--start-from-phase $START_FROM_PHASE)"
    fi

    # Phase 5: Verify
    if [[ $START_FROM_PHASE -le 5 ]]; then
        phase5_verify || true
    else
        log_section "PHASE 5: Verification"
        report_phase "5" "VERIFICATION"
        report_skip "Skipped (--start-from-phase $START_FROM_PHASE)"
    fi

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
