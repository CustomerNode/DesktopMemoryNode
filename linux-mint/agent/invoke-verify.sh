#!/usr/bin/env bash
# Run restic check (structural integrity) against the repo.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

READ_DATA=0
READ_DATA_SUBSET=""
for a in "$@"; do
    case "$a" in
        --read-data) READ_DATA=1 ;;
        --read-data-subset=*) READ_DATA_SUBSET="${a#--read-data-subset=}" ;;
    esac
done

dmn_assert_ready

trap 'dmn_release_lock verify' EXIT
dmn_acquire_lock verify

dmn_log verify INFO "Verify starting (read-data=$READ_DATA, subset=$READ_DATA_SUBSET)"

restic_args=(check)
(( READ_DATA )) && restic_args+=(--read-data)
[[ -n "$READ_DATA_SUBSET" ]] && restic_args+=("--read-data-subset=$READ_DATA_SUBSET")

set +e
dmn_restic "${restic_args[@]}" 2>&1 | tee -a "${DMN_LOG_DIR}/verify-$(date +%F).log"
ec=${PIPESTATUS[0]}
set -e

if (( ec == 0 )); then
    dmn_log verify INFO "Verify OK"
    dmn_state_set LastVerifyAt "$(date --iso-8601=seconds)" LastVerifyOk "true"
else
    dmn_log verify ERROR "Verify FAILED (exit $ec)"
    dmn_state_set LastVerifyAt "$(date --iso-8601=seconds)" LastVerifyOk "false"
    dmn_notify "Repo verify FAILED" "Restic integrity check failed. $(dmn_support_line)" critical
    exit 1
fi
