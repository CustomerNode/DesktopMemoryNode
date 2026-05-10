# Architecture

How DesktopMemoryNode is wired together, and why the decisions were made the
way they were.

## Goals (in priority order)

1. **You can recover.** Backups are useless if you can't restore from them.
   Every part of the system is designed so that you can verify, today, that
   you can get your files back tomorrow.
2. **The NAS owner can't read your files.** Encryption is client-side. The
   NAS sees ciphertext only. The encryption password lives on your machine
   and (ideally) in your password manager -- nowhere else.
3. **Non-technical users can use it.** The tray app is the interface. Plain
   language. No jargon. All technical features hidden behind "Advanced".
4. **Multiple machines coexist on one NAS account** without stepping on each
   other.
5. **Set it and forget it.** After install, daily backups, weekly verifies,
   and monthly restore tests run on their own. Notifications surface only
   when something needs attention.

## Components

```
+-------------------------------+
|   Your machine (Win/Linux)    |
|                               |
|   +-----------------------+   |       Encrypted snapshots (SMB on Win,
|   |   Tray app / Widget   |   |       SFTP on Linux)
|   |  (Windows only Phase 3)|  |  ----------------------------->
|   +----------+------------+   |                                +-----------+
|              |                |                                | Memorybox |
|   +----------+------------+   |  <-----------------------------|  (NAS)    |
|   |  Backup runner        |   |       Restore (only to a       |           |
|   |  Forget runner        |   |       scratch dir, never       | dmn-foo/  |
|   |  Verify runner        |   |       in-place over /)         | dmn-bar/  |
|   |  Test-restore runner  |   |                                +-----------+
|   +----------+------------+   |
|              |                |
|   +----------+------------+   |
|   |  restic 0.18+         |   |
|   +-----------------------+   |
|                               |
|   Local state:                |
|     ~/.config/dmn/  (linux)   |
|     %LOCALAPPDATA%\           |
|       DesktopMemoryNode\      |
|     enc_pswd env var          |
+-------------------------------+
```

### restic

The actual backup engine. We chose restic because:

- Client-side AES-256 encryption (key never leaves the machine)
- Content-addressed deduplication (small daily snapshots)
- Snapshots are first-class -- forget/prune work on them
- Native SFTP backend works for Linux against the Synology
- Native local-path backend works for Windows over a mapped SMB share
- Single static binary, available via `winget` and `apt`
- Mature, well-audited, well-documented

### Per-node partitioning

Storage convention on the NAS:

```
\\<host>\home\dmn-<nodename>\restic-repo\
```

- Each machine has a unique `MEMORYBOX_NODE_NAME` (validated as
  `^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$`).
- `Test-MemoryboxNodeNameAvailable` checks for collisions on the NAS at setup
  time and refuses to register a name that's already taken (unless `-Reuse`
  is passed -- e.g. you're reinstalling on the same machine).

This means a household with multiple machines can share one NAS account
without configuration headaches. Each machine has its own restic repo,
its own retention, its own encryption key (or a shared one -- your choice).

### Retention: always 4 distinct snapshots

Stock restic retention (`--keep-daily 7 --keep-weekly 4 --keep-monthly 12`)
*collapses* when the same snapshot satisfies multiple buckets. That can
silently leave you with fewer snapshots than you expected.

Our policy explicitly picks four distinct snapshots:

1. **Newest scheduled** ("today")
2. **Newest scheduled at least 7 days older than #1** ("week")
3. **Newest scheduled at least 30 days older than #2** ("month")
4. **Newest manual** -- the most recent one you triggered from the widget

Anything else is forgotten. Implementation: `windows/agent/Invoke-Forget.ps1`
and `linux-mint/agent/invoke-forget.sh`.

### Verification

Two automated checks run on a schedule:

- **Weekly: `restic check`** -- verifies the structural integrity of the repo
  (indexes, packs, tree references). Catches NAS-side bit rot, interrupted
  writes, and similar.
- **Monthly: test-restore round-trip** -- restores a small file from the
  newest snapshot to a scratch directory under `%TEMP%`, hashes it, and
  compares against the original on disk if it still exists. Confirms that
  the encryption key still decrypts and that the data round-trips
  byte-for-byte.

The widget exposes test-restore as an on-demand action so the user can
verify any time -- and crucially, the widget's version requires the user
to **type the password fresh**, proving they still know it (not just that
the machine has it).

### Notifications

`Send-MemoryboxToast` uses BurntToast's `Reminder` scenario with a Dismiss
button -- toasts stay on screen until clicked. Failure toasts always
include a "contact tech support" line built from `DMN_TECH_NAME` and
`DMN_TECH_CONTACT`, so the recipient knows who to call without thinking.

If BurntToast isn't installed yet, falls back to `NotifyIcon` balloons
(15s auto-dismiss). Phase 4 setup installs BurntToast as a one-time step.

## Configuration

Two layers:

### Connection / identity (required)

User-scope env vars. See [`shared/CONFIG.md`](../shared/CONFIG.md):

- `MEMORYBOX_HOST`, `MEMORYBOX_PORT`, `MEMORYBOX_USER`, `MEMORYBOX_PASSWORD`
- `MEMORYBOX_NODE_NAME`
- `enc_pswd` (the encryption key)

### Display / personalization (optional)

User-scope env vars:

- `DMN_DISPLAY_NAME` -- greeting name in the tray
- `DMN_TECH_NAME` -- tech support person
- `DMN_TECH_CONTACT` -- tech support email/phone

All optional. UI degrades gracefully when missing.

### Local state

- `%LOCALAPPDATA%\DesktopMemoryNode\` (Windows) / `~/.config/dmn/` +
  `~/.local/state/dmn/` (Linux)
- `targets.json` -- include/exclude paths
- `state.json` -- last backup/verify/restore timestamps + outcomes
- `logs/<kind>-YYYY-MM-DD.log` -- per-day rotated logs
- `locks/<kind>.lock` -- file locks preventing concurrent runs

### Why env vars and not a config file?

The connection details and the encryption key are sensitive. They should
not live in any file in the repo. Env vars at User scope are:

- Stored in the Windows registry (HKCU) or in `~/.config/dmn/env` on Linux
  (mode 600)
- Per-user, no admin needed
- Inherited by every process the user starts -- so scheduled tasks work
  without any extra plumbing
- Easy to update (one PowerShell call or text-editor edit)
- Easy to NOT commit by accident (no file means no risk)

## Single source of truth: the icon

The Memory Box icon is generated once by `windows/tray/Install-Tray.ps1`
into `%LOCALAPPDATA%\DesktopMemoryNode\Memory-Box.ico` (multi-size:
16/24/32/48/64/128/256 PNG-encoded). Both the desktop/Start Menu shortcuts
and the tray app load it from there. Change the design in one place and
re-run Install-Tray; the whole UI picks up the change.

## What we explicitly didn't build

- **Offsite copy** (e.g. NAS → S3 / B2 / Azure). The threat model (see
  [`security.md`](security.md)) deliberately doesn't cover house-fire
  scenarios. Easy to add later by syncing the restic repo to a cloud
  bucket weekly.
- **Cross-platform GUI parity.** The tray widget is Windows-only. Linux
  Mint relies on `notify-send` for failure surfacing and bash CLI for
  on-demand actions. A GTK port would be a fine future contribution.
- **Multi-user-on-one-machine.** Each user has their own state directory
  and env vars; multi-user is implicitly supported but isn't really
  designed for or tested.
- **Auto-update.** The agent doesn't update itself. `git pull` in the
  repo + re-run `setup-node` is the upgrade path. Intentional -- backup
  software that auto-updates itself is more dangerous than helpful.
