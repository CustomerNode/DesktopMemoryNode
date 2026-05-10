#!/usr/bin/env bash
# Daily/manual backup runner (Linux Mint -- full system to memorybox over SFTP).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

TAG=scheduled
QUIET_ON_SUCCESS=0
DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --tag=*)         TAG="${a#--tag=}" ;;
        --tag)           shift; TAG="$1" ;;
        --quiet-on-success) QUIET_ON_SUCCESS=1 ;;
        --dry-run)       DRY_RUN=1 ;;
        *) ;;
    esac
done

dmn_assert_ready

trap 'dmn_release_lock backup' EXIT
dmn_acquire_lock backup

started=$(date +%s)
dmn_log backup INFO "Backup starting (tag=$TAG, node=$MEMORYBOX_NODE_NAME)"

targets_json=$(dmn_get_targets)
includes=()
while IFS= read -r p; do includes+=("$p"); done < <(echo "$targets_json" | jq -r '.include[]')
excludes=()
while IFS= read -r p; do excludes+=("$p"); done < <(echo "$targets_json" | jq -r '.exclude[]')

if (( ${#includes[@]} == 0 )); then
    dmn_log backup ERROR "No backup targets configured."
    dmn_notify "Backup FAILED" "No backup targets configured. $(dmn_support_line)" critical
    exit 1
fi

dmn_log backup INFO "Include: ${includes[*]}"
dmn_log backup INFO "Exclude: ${excludes[*]}"

restic_args=(backup --tag "$TAG")
(( DRY_RUN )) && restic_args+=(--dry-run)
for e in "${excludes[@]}"; do restic_args+=(--exclude "$e"); done
restic_args+=("${includes[@]}")

dmn_log backup INFO "restic ${restic_args[*]}"
logfile="${DMN_LOG_DIR}/backup-$(date +%F).log"

set +e
dmn_restic "${restic_args[@]}" 2>&1 | tee -a "$logfile"
exit_code=${PIPESTATUS[0]}
set -e

elapsed=$(( $(date +%s) - started ))

if (( exit_code == 0 )); then
    dmn_log backup INFO "Backup OK (${elapsed}s)"
    dmn_state_set LastBackupAt "$(date --iso-8601=seconds)" LastBackupOk "true" LastBackupError ""
    if (( ! QUIET_ON_SUCCESS )); then
        dmn_notify "Backup complete" "Files saved to your Memory Box in ${elapsed}s." normal
    fi
elif (( exit_code == 3 )); then
    # restic exit 3 = some files were skipped but the snapshot succeeded
    dmn_log backup WARN "Backup completed with warnings (some files skipped)"
    dmn_state_set LastBackupAt "$(date --iso-8601=seconds)" LastBackupOk "true" LastBackupError "exit 3 -- some files skipped"
    if (( ! QUIET_ON_SUCCESS )); then
        dmn_notify "Backup complete (warnings)" "Some files were skipped. Check the log." normal
    fi
else
    dmn_log backup ERROR "Backup FAILED (exit $exit_code)"
    dmn_state_set LastBackupAt "$(date --iso-8601=seconds)" LastBackupOk "false" LastBackupError "exit $exit_code"
    dmn_notify "Backup FAILED" "Backup did not complete (exit $exit_code). $(dmn_support_line)" critical
    exit 1
fi
