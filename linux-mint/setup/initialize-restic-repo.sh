#!/usr/bin/env bash
# Initialize (or verify) this node's encrypted restic repo on the memorybox via SFTP.
#
# Idempotent. If the repo already exists at sftp:user@host:dmn-<node>/restic-repo
# AND the configured enc_pswd unlocks it, this is a no-op.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/memorybox.sh
source "$HERE/../lib/memorybox.sh"

dmn_load_env

missing=$(dmn_missing_vars)
if [[ -n "$missing" ]]; then
    echo "ERROR: missing env var(s): ${missing//$'\n'/, }" >&2
    echo "Run setup/set-memorybox-vars.sh first." >&2
    exit 1
fi

repo_url=$(dmn_repo_url)
echo "Node : $MEMORYBOX_NODE_NAME"
echo "Repo : $repo_url"
echo

# Probe whether the repo exists by trying to list snapshots. Exit 0 = exists+unlocks.
if dmn_restic snapshots --no-lock --quiet >/dev/null 2>&1; then
    echo "Repo already exists and unlocks with enc_pswd. Nothing to do."
    exit 0
fi

# Try to init. restic init creates the parent dir on the SFTP target if it doesn't exist.
echo "Initializing new encrypted repo..."
dmn_restic init
echo
echo "Repo initialized successfully."
echo "REMINDER: enc_pswd is the encryption key. If you lose it, your backups are unrecoverable."
