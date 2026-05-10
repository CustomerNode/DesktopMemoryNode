#!/usr/bin/env bash
# End-to-end setup orchestrator for a Linux Mint node. Idempotent.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

step() {
    echo
    echo "===== Step $1: $2 ====="
}

step 1 "Install dependencies (restic, jq, libnotify-bin, util-linux)"
"$HERE/install-restic.sh"

step 2 "Set memorybox env vars"
"$HERE/set-memorybox-vars.sh"

step 3 "Initialize encrypted restic repo"
# Source the env file so this shell has the vars
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/dmn/env"
[[ -r "$ENV_FILE" ]] && { set -a; . "$ENV_FILE"; set +a; }
"$HERE/initialize-restic-repo.sh"

step 4 "Install systemd user timers"
"$HERE/install-schedule.sh"

step 5 "Preflight checks"
"$HERE/test-setup.sh"

echo
echo "Setup complete."
echo "  - Daily backup runs at 02:00 (next: systemctl --user list-timers dmn-*)."
echo "  - To run a backup right now: linux-mint/agent/invoke-backup.sh --tag manual"
echo "  - To restore: linux-mint/restore/restore-file.sh --list  (then pick a snapshot)"
