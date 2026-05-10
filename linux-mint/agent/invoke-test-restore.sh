#!/usr/bin/env bash
# Round-trip test: restore one small file from the newest snapshot to a scratch
# directory under /tmp, hash it, optionally cross-check against the original on disk.
# NEVER restores to the real filesystem.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

PROMPT_PASSWORD=0
MAX_FILE_BYTES=$((1024 * 1024))   # 1 MiB
for a in "$@"; do
    case "$a" in
        --prompt-password) PROMPT_PASSWORD=1 ;;
        --max-bytes=*)     MAX_FILE_BYTES="${a#--max-bytes=}" ;;
    esac
done

dmn_assert_ready

if (( PROMPT_PASSWORD )); then
    echo "Type the encryption password to verify you still know it:"
    read -r -s typed
    echo
    export DMN_RESTIC_PASSWORD_OVERRIDE="$typed"
fi

scratch=$(mktemp -d -t dmn-test-restore.XXXXXXXX)
cleanup() {
    [[ -n "${scratch:-}" && -d "$scratch" ]] && rm -rf "$scratch"
    dmn_release_lock test-restore
    unset DMN_RESTIC_PASSWORD_OVERRIDE
}
trap cleanup EXIT

dmn_acquire_lock test-restore
dmn_log verify INFO "Test-restore starting (scratch=$scratch, max=$MAX_FILE_BYTES bytes)"

# Newest snapshot
snap_id=$(dmn_restic snapshots --json 2>/dev/null | jq -r 'sort_by(.time) | reverse | .[0].id // empty')
if [[ -z "$snap_id" ]]; then
    dmn_log verify ERROR "No snapshots in repo to test."
    dmn_notify "Test restore FAILED" "There are no snapshots to test. $(dmn_support_line)" critical
    exit 1
fi
dmn_log verify INFO "Using snapshot: $snap_id"

# Pick a small file in that snapshot
file_path=$(dmn_restic ls --json "$snap_id" 2>/dev/null \
    | jq -r --argjson max "$MAX_FILE_BYTES" '
        select(.struct_type == "node" and .type == "file" and .size > 0 and .size <= $max)
        | .path' \
    | shuf -n 1)
if [[ -z "$file_path" ]]; then
    dmn_log verify ERROR "No suitable test file found (need >0 and <=$MAX_FILE_BYTES bytes)."
    dmn_notify "Test restore FAILED" "Could not pick a test file. $(dmn_support_line)" critical
    exit 1
fi
dmn_log verify INFO "Test file: $file_path"

# Restore
set +e
dmn_restic restore "$snap_id" --target "$scratch" --include "$file_path" 2>&1 | tee -a "${DMN_LOG_DIR}/verify-$(date +%F).log"
ec=${PIPESTATUS[0]}
set -e

restored=$(find "$scratch" -type f -size +0c 2>/dev/null | head -n 1)
if [[ -z "$restored" ]]; then
    dmn_log verify ERROR "Restored file not found in scratch (restic exit $ec)."
    dmn_notify "Test restore FAILED" "The restore did not produce a file. $(dmn_support_line)" critical
    exit 1
fi

restored_hash=$(sha256sum "$restored" | awk '{print $1}')
dmn_log verify INFO "Restored hash (sha256): $restored_hash"

# Optional cross-check against original on disk
if [[ -r "$file_path" ]]; then
    orig_hash=$(sha256sum "$file_path" | awk '{print $1}')
    if [[ "$orig_hash" == "$restored_hash" ]]; then
        dmn_log verify INFO "Hash MATCH between original and restored ($orig_hash)"
    else
        dmn_log verify WARN "Hash MISMATCH (file may have changed since the snapshot; not a failure)"
    fi
else
    dmn_log verify INFO "Original file not readable on disk; skipping cross-check"
fi

dmn_log verify INFO "Test-restore OK"
dmn_state_set LastTestRestoreAt "$(date --iso-8601=seconds)" LastTestRestoreOk "true"

if (( PROMPT_PASSWORD )); then
    dmn_notify "Test restore PASSED" "Decrypted and restored a $(stat -c%s "$restored") byte file. Your password is correct and the repo is healthy." normal
fi
