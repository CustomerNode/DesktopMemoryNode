#!/usr/bin/env bash
# File-level restore CLI. Destination is REQUIRED -- never restores in-place.
#
# Usage:
#   ./restore-file.sh --list
#   ./restore-file.sh --latest --dest /tmp/restore-staging
#   ./restore-file.sh --latest --dest /tmp/restore --include /home/me/Documents/report.docx
#   ./restore-file.sh --snapshot 61df23cb --dest /tmp/restore --prompt-password

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

LIST=0
LATEST=0
SNAP_ID=""
DEST=""
INCLUDES=()
PROMPT_PASSWORD=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)             LIST=1 ;;
        --latest)           LATEST=1 ;;
        --snapshot)         SNAP_ID="$2"; shift ;;
        --snapshot=*)       SNAP_ID="${1#--snapshot=}" ;;
        --dest)             DEST="$2"; shift ;;
        --dest=*)           DEST="${1#--dest=}" ;;
        --include)          INCLUDES+=("$2"); shift ;;
        --include=*)        INCLUDES+=("${1#--include=}") ;;
        --prompt-password)  PROMPT_PASSWORD=1 ;;
        -h|--help)
            sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

dmn_assert_ready

if (( PROMPT_PASSWORD )); then
    echo "Type the encryption password:"
    read -r -s typed
    echo
    export DMN_RESTIC_PASSWORD_OVERRIDE="$typed"
fi

echo
echo "Available snapshots:"
dmn_restic snapshots
echo

if (( LIST )); then exit 0; fi

if [[ -z "$DEST" ]]; then
    echo "ERROR: --dest is required (refusing to restore without an explicit destination)" >&2
    exit 1
fi

# Pick snapshot
if (( LATEST )); then
    SNAP_ID=$(dmn_restic snapshots --json | jq -r 'sort_by(.time) | reverse | .[0].id // empty')
elif [[ -z "$SNAP_ID" ]]; then
    read -r -p "Snapshot ID (short ID from the list above): " SNAP_ID
fi

if [[ -z "$SNAP_ID" ]]; then
    echo "ERROR: no snapshot picked" >&2; exit 1
fi

mkdir -p "$DEST"

restic_args=(restore "$SNAP_ID" --target "$DEST")
for p in "${INCLUDES[@]}"; do restic_args+=(--include "$p"); done

echo "Restoring snapshot $SNAP_ID to $DEST"
[[ ${#INCLUDES[@]} -gt 0 ]] && echo "Include filters: ${INCLUDES[*]}"
dmn_restic "${restic_args[@]}"
echo
echo "Done. Top-level contents of $DEST:"
ls -lh "$DEST" | head -20
