#!/usr/bin/env bash
# Retention: always keep 4 distinct snapshots per node.
#   1. Newest scheduled                          (today)
#   2. Newest scheduled >= 7d older than #1      (~1 week ago)
#   3. Newest scheduled >= 30d older than #2     (~1 month ago)
#   4. Newest manual                             (widget-triggered)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

DRY_RUN=0
NO_PRUNE=0
for a in "$@"; do
    case "$a" in
        --dry-run)  DRY_RUN=1 ;;
        --no-prune) NO_PRUNE=1 ;;
    esac
done

dmn_assert_ready

trap 'dmn_release_lock forget' EXIT
dmn_acquire_lock forget

dmn_log forget INFO "Forget starting (target: 4 distinct slots; prune=$([[ $NO_PRUNE -eq 1 ]] && echo false || echo true))"

# Helper: query snapshots filtered by tag, return JSON array sorted newest-first.
get_snapshots() {
    local tag="$1"
    local out
    if [[ -n "$tag" ]]; then
        out=$(dmn_restic snapshots --json --tag "$tag" 2>/dev/null || echo '[]')
    else
        out=$(dmn_restic snapshots --json 2>/dev/null || echo '[]')
    fi
    [[ -z "$out" || "$out" == "null" ]] && out='[]'
    echo "$out" | jq 'sort_by(.time) | reverse'
}

scheduled=$(get_snapshots scheduled)
manual=$(get_snapshots manual)
all=$(get_snapshots "")

keep_ids=()

# Slot 1: newest scheduled
slot1_id=$(echo "$scheduled" | jq -r '.[0].id // empty')
slot1_time=$(echo "$scheduled" | jq -r '.[0].time // empty')
[[ -n "$slot1_id" ]] && keep_ids+=("$slot1_id")

# Slot 2: newest scheduled >= 7 days older than slot1
slot2_id=""
if [[ -n "$slot1_time" ]]; then
    cutoff=$(date -u -d "$slot1_time -7 days" --iso-8601=seconds 2>/dev/null || echo "")
    if [[ -n "$cutoff" ]]; then
        slot2_id=$(echo "$scheduled" | jq -r --arg c "$cutoff" '[.[] | select(.time <= $c)] | .[0].id // empty')
        slot2_time=$(echo "$scheduled" | jq -r --arg c "$cutoff" '[.[] | select(.time <= $c)] | .[0].time // empty')
        [[ -n "$slot2_id" ]] && keep_ids+=("$slot2_id")
    fi
fi

# Slot 3: newest scheduled >= 30 days older than slot2
if [[ -n "${slot2_time:-}" ]]; then
    cutoff=$(date -u -d "$slot2_time -30 days" --iso-8601=seconds 2>/dev/null || echo "")
    if [[ -n "$cutoff" ]]; then
        slot3_id=$(echo "$scheduled" | jq -r --arg c "$cutoff" '[.[] | select(.time <= $c)] | .[0].id // empty')
        [[ -n "$slot3_id" ]] && keep_ids+=("$slot3_id")
    fi
fi

# Slot 4: newest manual
slot4_id=$(echo "$manual" | jq -r '.[0].id // empty')
[[ -n "$slot4_id" ]] && keep_ids+=("$slot4_id")

dmn_log forget INFO "Keeping: ${keep_ids[*]:-<none>}"

# Find what to forget: every snapshot id NOT in keep_ids
keep_filter=$(printf '"%s",' "${keep_ids[@]}" | sed 's/,$//')
if [[ -z "$keep_filter" ]]; then keep_filter='""'; fi
forget_ids=()
while IFS= read -r id; do forget_ids+=("$id"); done < <(echo "$all" | jq -r --argjson keep "[$keep_filter]" '.[] | select(.id as $i | ($keep | index($i)) | not) | .id')

if (( ${#forget_ids[@]} == 0 )); then
    dmn_log forget INFO "Nothing to forget."
    exit 0
fi

dmn_log forget INFO "Forgetting ${#forget_ids[@]} snapshot(s)"
restic_args=(forget "${forget_ids[@]}")
(( DRY_RUN )) && restic_args+=(--dry-run)
(( NO_PRUNE )) || restic_args+=(--prune)

set +e
dmn_restic "${restic_args[@]}" 2>&1 | tee -a "${DMN_LOG_DIR}/forget-$(date +%F).log"
ec=${PIPESTATUS[0]}
set -e

if (( ec != 0 )); then
    dmn_log forget ERROR "restic forget failed (exit $ec)"
    dmn_notify "Retention FAILED" "Could not prune old snapshots (exit $ec). $(dmn_support_line)" critical
    exit 1
fi

dmn_log forget INFO "Forget OK (kept ${#keep_ids[@]}, forgot ${#forget_ids[@]})"
