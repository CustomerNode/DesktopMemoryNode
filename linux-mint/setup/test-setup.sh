#!/usr/bin/env bash
# Preflight diagnostic. Exits 0 if everything is green, 1 otherwise.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

dmn_load_env

failures=0
check() {
    local label="$1"; local ok="$2"; local detail="${3:-}"
    if [[ "$ok" == "1" ]]; then
        printf '\033[32m[OK]   \033[0m%s' "$label"
    else
        printf '\033[31m[FAIL] \033[0m%s' "$label"
        failures=$((failures + 1))
    fi
    [[ -n "$detail" ]] && printf '  -- %s' "$detail"
    echo
}

echo
echo "DesktopMemoryNode preflight (Linux Mint)"
echo "========================================"

# 1. Required env vars
missing=$(dmn_missing_vars)
if [[ -z "$missing" ]]; then
    check "All required env vars set" 1 "host=$MEMORYBOX_HOST node=$MEMORYBOX_NODE_NAME"
else
    check "All required env vars set" 0 "missing: ${missing//$'\n'/, }"
    echo
    echo "Run setup/set-memorybox-vars.sh, then re-run this." >&2
    exit 1
fi

# 2. Tools
for cmd in restic jq notify-send flock ssh; do
    if command -v "$cmd" >/dev/null 2>&1; then check "tool: $cmd" 1; else check "tool: $cmd" 0 "not installed (run install-restic.sh)"; fi
done

# 3. Network: ping the host
if ping -c 1 -W 2 "$MEMORYBOX_HOST" >/dev/null 2>&1; then
    check "ICMP reach $MEMORYBOX_HOST" 1
else
    check "ICMP reach $MEMORYBOX_HOST" 0
fi

# 4. SSH connectivity (SFTP backend uses SSH)
if timeout 5 bash -c "</dev/tcp/$MEMORYBOX_HOST/22" 2>/dev/null; then
    check "TCP reach $MEMORYBOX_HOST:22 (SSH/SFTP)" 1
else
    check "TCP reach $MEMORYBOX_HOST:22 (SSH/SFTP)" 0 "ask the box admin to enable SSH for $MEMORYBOX_USER"
fi

# 5. Restic repo unlocks
if dmn_restic snapshots --no-lock --quiet >/dev/null 2>&1; then
    check "restic repo unlocks with enc_pswd" 1 "$(dmn_repo_url)"
else
    check "restic repo unlocks with enc_pswd" 0 "either not initialized or wrong password (run initialize-restic-repo.sh)"
fi

# 6. systemd user timers
if systemctl --user list-timers dmn-* >/dev/null 2>&1; then
    timers=$(systemctl --user list-timers --no-pager dmn-* 2>/dev/null | grep -c '^dmn-' || true)
    if (( timers > 0 )); then check "systemd user timers ($timers)" 1
    else                       check "systemd user timers" 0 "none (run install-schedule.sh)"
    fi
fi

# 7. Last backup state
last=$(dmn_state_get LastBackupAt)
if [[ -n "$last" ]]; then
    echo "[INFO] Last backup: $last (ok=$(dmn_state_get LastBackupOk))"
else
    echo "[INFO] No backups have run yet"
fi

echo
if (( failures == 0 )); then
    echo "All checks passed."
    exit 0
else
    echo "$failures check(s) failed."
    exit 1
fi
