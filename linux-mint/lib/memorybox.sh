#!/usr/bin/env bash
# memorybox.sh -- shared helpers for the DesktopMemoryNode Linux Mint agent.
#
# Source this file from any agent/setup script:
#   source "$(dirname "$0")/../lib/memorybox.sh"
#
# Connection details and the encryption password come from per-user env vars
# stored in ~/.config/dmn/env (chmod 600). See shared/CONFIG.md for the names.

# -------------------------------------------------------------------------------------
# Strict mode (callers should also set their own; this is defensive)
# -------------------------------------------------------------------------------------
set -o pipefail

# -------------------------------------------------------------------------------------
# Paths
# -------------------------------------------------------------------------------------
DMN_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dmn"
DMN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dmn"
DMN_ENV_FILE="${DMN_CONFIG_DIR}/env"
DMN_TARGETS_FILE="${DMN_CONFIG_DIR}/targets.json"
DMN_STATE_FILE="${DMN_STATE_DIR}/state.json"
DMN_LOG_DIR="${DMN_STATE_DIR}/logs"
DMN_LOCK_DIR="${DMN_STATE_DIR}/locks"

dmn_ensure_dirs() {
    install -d -m 700 "$DMN_CONFIG_DIR" "$DMN_STATE_DIR" "$DMN_LOG_DIR" "$DMN_LOCK_DIR"
}

# -------------------------------------------------------------------------------------
# Env loading
# -------------------------------------------------------------------------------------
dmn_load_env() {
    if [[ -r "$DMN_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        set -a; source "$DMN_ENV_FILE"; set +a
    fi
}

DMN_REQUIRED_VARS=(
    MEMORYBOX_HOST
    MEMORYBOX_PORT
    MEMORYBOX_USER
    MEMORYBOX_PASSWORD
    MEMORYBOX_NODE_NAME
    enc_pswd
)

dmn_missing_vars() {
    local missing=()
    for v in "${DMN_REQUIRED_VARS[@]}"; do
        if [[ -z "${!v:-}" ]]; then missing+=("$v"); fi
    done
    printf '%s\n' "${missing[@]}"
}

dmn_assert_ready() {
    dmn_load_env
    local missing
    missing=$(dmn_missing_vars)
    if [[ -n "$missing" ]]; then
        local msg="Missing required env var(s): ${missing//$'\n'/, }. $(dmn_support_line)"
        dmn_notify "Memory Box: configuration error" "$msg" critical
        echo "ERROR: $msg" >&2
        return 1
    fi
}

# -------------------------------------------------------------------------------------
# Display / personalization
# -------------------------------------------------------------------------------------
dmn_display_name() { echo "${DMN_DISPLAY_NAME:-}"; }
dmn_tech_name()    { echo "${DMN_TECH_NAME:-tech support}"; }
dmn_tech_contact() { echo "${DMN_TECH_CONTACT:-}"; }

dmn_support_line() {
    local name contact
    name=$(dmn_tech_name)
    contact=$(dmn_tech_contact)
    if [[ -n "$contact" ]]; then
        echo "Need help? Contact $name at $contact."
    else
        echo "Need help? Contact $name."
    fi
}

# -------------------------------------------------------------------------------------
# Restic repo path / wrapper
# -------------------------------------------------------------------------------------
dmn_repo_url() {
    # SFTP path -- relative to the user's home on the NAS (Synology: /volume1/homes/$USER/)
    echo "sftp:${MEMORYBOX_USER}@${MEMORYBOX_HOST}:dmn-${MEMORYBOX_NODE_NAME}/restic-repo"
}

dmn_restic() {
    # Wraps restic with RESTIC_REPOSITORY and RESTIC_PASSWORD pre-populated.
    # Caller passes restic args as positional args.
    dmn_assert_ready || return 1
    RESTIC_REPOSITORY="$(dmn_repo_url)" \
    RESTIC_PASSWORD="${DMN_RESTIC_PASSWORD_OVERRIDE:-$enc_pswd}" \
        restic "$@"
}

# -------------------------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------------------------
dmn_log() {
    local kind="${1:-backup}"; shift || true
    local level="${1:-INFO}"; shift || true
    local msg="$*"
    local ts logfile
    ts=$(date --iso-8601=seconds)
    logfile="${DMN_LOG_DIR}/${kind}-$(date +%F).log"
    dmn_ensure_dirs
    printf '%s %-5s %s\n' "$ts" "$level" "$msg" | tee -a "$logfile"
}

# -------------------------------------------------------------------------------------
# Locking
# -------------------------------------------------------------------------------------
dmn_lock_path() { echo "${DMN_LOCK_DIR}/${1:-backup}.lock"; }

dmn_acquire_lock() {
    local name="${1:-backup}"
    local lockfile
    lockfile=$(dmn_lock_path "$name")
    dmn_ensure_dirs
    exec {DMN_LOCK_FD}>"$lockfile"
    if ! flock -n "$DMN_LOCK_FD"; then
        echo "ERROR: another '$name' run is in progress (lock at $lockfile)" >&2
        return 1
    fi
    echo "pid=$$ at=$(date --iso-8601=seconds)" > "$lockfile"
    export DMN_LOCK_FD
}

dmn_release_lock() {
    local name="${1:-backup}"
    if [[ -n "${DMN_LOCK_FD:-}" ]]; then
        flock -u "$DMN_LOCK_FD" 2>/dev/null || true
        eval "exec ${DMN_LOCK_FD}>&-"
        unset DMN_LOCK_FD
    fi
    rm -f "$(dmn_lock_path "$name")"
}

# -------------------------------------------------------------------------------------
# Notification (notify-send for desktop toasts; falls back to wall)
# -------------------------------------------------------------------------------------
dmn_notify() {
    local title="$1"; local body="$2"; local urgency="${3:-normal}"
    if [[ "$title" != *"Memory Box"* ]]; then title="Memory Box: $title"; fi
    if command -v notify-send >/dev/null 2>&1; then
        # -t 0 = persist until dismissed (most desktops honor this)
        notify-send --urgency="$urgency" --expire-time=0 "$title" "$body" || true
    else
        # Fallback: log to stderr
        echo "[notify] $title -- $body" >&2
    fi
}

# -------------------------------------------------------------------------------------
# State (state.json) -- jq-based read/merge
# -------------------------------------------------------------------------------------
dmn_state_get() {
    local key="$1"
    if [[ -r "$DMN_STATE_FILE" ]]; then
        jq -r --arg k "$key" '.[$k] // ""' "$DMN_STATE_FILE" 2>/dev/null || echo ""
    fi
}

dmn_state_set() {
    # Usage: dmn_state_set key1 val1 key2 val2 ...
    dmn_ensure_dirs
    local tmp
    tmp=$(mktemp)
    local current="{}"
    if [[ -r "$DMN_STATE_FILE" ]]; then current=$(cat "$DMN_STATE_FILE"); fi
    local jq_args=()
    local jq_filter='.'
    while [[ $# -ge 2 ]]; do
        local k="$1" v="$2"
        jq_args+=(--arg "k$#" "$k" --arg "v$#" "$v")
        jq_filter="$jq_filter | .[\$k$#] = \$v$#"
        shift 2
    done
    echo "$current" | jq "${jq_args[@]}" "$jq_filter" > "$tmp"
    mv "$tmp" "$DMN_STATE_FILE"
}

# -------------------------------------------------------------------------------------
# Backup targets
# -------------------------------------------------------------------------------------
dmn_default_targets() {
    cat <<'JSON'
{
  "include": ["/"],
  "exclude": [
    "/dev/*",
    "/proc/*",
    "/sys/*",
    "/run/*",
    "/tmp/*",
    "/mnt/*",
    "/media/*",
    "/lost+found",
    "/var/cache/*",
    "/var/tmp/*",
    "/var/log/journal/*",
    "/swapfile",
    "/swap.img",
    "/home/*/.cache/*",
    "/home/*/.local/share/Trash/*",
    "/home/*/snap",
    "/home/*/.steam"
  ]
}
JSON
}

dmn_get_targets() {
    if [[ -r "$DMN_TARGETS_FILE" ]]; then cat "$DMN_TARGETS_FILE"
    else                                  dmn_default_targets
    fi
}
