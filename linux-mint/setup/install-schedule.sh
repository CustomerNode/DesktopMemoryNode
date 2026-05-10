#!/usr/bin/env bash
# Installs systemd USER timers + services for the DesktopMemoryNode agent.
# No root required. Files land under ~/.config/systemd/user/.
#
# Schedule:
#   dmn-backup       daily 02:00
#   dmn-forget       weekly Sunday 03:00
#   dmn-verify       weekly Sunday 04:00
#   dmn-test-restore monthly (every 30 days) 05:00
#
# Use --remove to disable + delete.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
AGENT_DIR="$REPO_ROOT/linux-mint/agent"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

UNITS=(dmn-backup dmn-forget dmn-verify dmn-test-restore)

if [[ "${1:-}" == "--remove" ]]; then
    for u in "${UNITS[@]}"; do
        systemctl --user disable --now "$u.timer" 2>/dev/null || true
        rm -f "$UNIT_DIR/$u.service" "$UNIT_DIR/$u.timer"
    done
    systemctl --user daemon-reload || true
    echo "Removed all dmn-* user timers."
    exit 0
fi

mkdir -p "$UNIT_DIR"

write_unit() {
    local name="$1"; local script="$2"; local desc="$3"; local oncalendar="$4"; local script_args="${5:-}"

    cat > "$UNIT_DIR/$name.service" <<EOF
[Unit]
Description=$desc

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $script $script_args
EOF

    cat > "$UNIT_DIR/$name.timer" <<EOF
[Unit]
Description=Schedule for $desc

[Timer]
OnCalendar=$oncalendar
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF
}

write_unit dmn-backup       "$AGENT_DIR/invoke-backup.sh"       "Memory Box: daily backup"           "*-*-* 02:00:00" "--quiet-on-success"
write_unit dmn-forget       "$AGENT_DIR/invoke-forget.sh"       "Memory Box: weekly retention prune" "Sun *-*-* 03:00:00"
write_unit dmn-verify       "$AGENT_DIR/invoke-verify.sh"       "Memory Box: weekly integrity check" "Sun *-*-* 04:00:00"
write_unit dmn-test-restore "$AGENT_DIR/invoke-test-restore.sh" "Memory Box: monthly restore round-trip test" "*-*-01 05:00:00"

systemctl --user daemon-reload
for u in "${UNITS[@]}"; do
    systemctl --user enable --now "$u.timer"
done

echo
echo "Installed timers:"
systemctl --user list-timers --no-pager dmn-*
