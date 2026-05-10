#!/usr/bin/env bash
# Set the per-user memorybox environment file (~/.config/dmn/env, mode 600).
#
# Usage:
#   ./set-memorybox-vars.sh           # interactive: prompts for any missing values
#   ./set-memorybox-vars.sh --force   # re-prompts for everything
#   ./set-memorybox-vars.sh --show    # prints current state (secrets masked)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

dmn_ensure_dirs

# Load whatever is currently set so we can show / preserve.
dmn_load_env

show_only=0
force=0
for a in "$@"; do
    case "$a" in
        --show)  show_only=1 ;;
        --force) force=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $a" >&2; exit 1 ;;
    esac
done

declare -A LABEL=(
    [MEMORYBOX_HOST]='Backup box host (IP/hostname)'
    [MEMORYBOX_PORT]='Port'
    [MEMORYBOX_USER]='Username on the box'
    [MEMORYBOX_PASSWORD]='Box password'
    [MEMORYBOX_NODE_NAME]='Node name (e.g. living-room, study-laptop)'
    [enc_pswd]='Encryption password (must match the one on the original node)'
)
declare -A SECRET=(
    [MEMORYBOX_PASSWORD]=1
    [enc_pswd]=1
)
ORDER=(MEMORYBOX_HOST MEMORYBOX_PORT MEMORYBOX_USER MEMORYBOX_PASSWORD MEMORYBOX_NODE_NAME enc_pswd)

if (( show_only )); then
    echo
    echo "Current memorybox env (from $DMN_ENV_FILE):"
    for k in "${ORDER[@]}"; do
        v="${!k:-}"
        if [[ -z "$v" ]]; then printf '  %-22s = <not set>\n' "$k"
        elif [[ -n "${SECRET[$k]:-}" ]]; then printf '  %-22s = <set>\n' "$k"
        else                                  printf '  %-22s = %s\n' "$k" "$v"
        fi
    done
    echo
    exit 0
fi

declare -A NEW
for k in "${ORDER[@]}"; do
    current="${!k:-}"
    if (( force )) || [[ -z "$current" ]]; then
        prompt="${LABEL[$k]}: "
        if [[ -n "${SECRET[$k]:-}" ]]; then
            read -r -s -p "$prompt" v; echo
        else
            read -r -p "$prompt" v
        fi
        if [[ -z "$v" ]]; then
            echo "  (empty -- skipping)"
            continue
        fi
        NEW[$k]="$v"
    else
        echo "  $k: already set, skipping (use --force to overwrite)"
        NEW[$k]="$current"
    fi
done

# Write the env file (mode 600)
umask 077
{
    echo "# DesktopMemoryNode env -- set by $(basename "$0") on $(date --iso-8601=seconds)"
    echo "# This file contains secrets. chmod 600."
    for k in "${ORDER[@]}"; do
        v="${NEW[$k]:-${!k:-}}"
        if [[ -n "$v" ]]; then
            # Single-quote, escape any single quotes inside the value
            esc="${v//\'/\'\\\'\'}"
            echo "export ${k}='${esc}'"
        fi
    done
} > "$DMN_ENV_FILE"
chmod 600 "$DMN_ENV_FILE"

echo
echo "Wrote $DMN_ENV_FILE."
echo "Open a new shell (or 'source $DMN_ENV_FILE') for changes to take effect."
