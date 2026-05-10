#!/usr/bin/env bash
# Install restic + jq + libnotify-bin on Linux Mint (apt). Idempotent.

set -euo pipefail

need=()
command -v restic       >/dev/null 2>&1 || need+=(restic)
command -v jq           >/dev/null 2>&1 || need+=(jq)
command -v notify-send  >/dev/null 2>&1 || need+=(libnotify-bin)
command -v flock        >/dev/null 2>&1 || need+=(util-linux)

if (( ${#need[@]} == 0 )); then
    echo "All dependencies already installed."
    restic version
    exit 0
fi

echo "Installing: ${need[*]}"
sudo apt-get update
sudo apt-get install -y "${need[@]}"

restic version
