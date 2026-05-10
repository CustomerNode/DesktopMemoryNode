# DesktopMemoryNode

Cross-platform desktop backup node: encrypted file-level backups on Windows,
full-system backup & restore on Linux Mint, syncing to a cloud **memorybox**
(Synology NAS).

> **Status:** Phase 0 complete (scaffolding + reusable Windows setup).
> Backup engine, scheduling, widget, and notifications are upcoming.

## Scope

| Platform     | Backup type                    | Restore                          |
|--------------|--------------------------------|----------------------------------|
| Windows      | File / directory backups       | File-level restore               |
| Linux Mint   | Full system image              | Full system restore (bare-metal) |

Backups are **client-side encrypted** (the NAS only sees ciphertext), with
**point-in-time snapshots** (yesterday, last week, last month) and
**automatic retention** so old snapshots are pruned.

## Repository layout

```
DesktopMemoryNode/
├── windows/        # Windows file-system backup agent
│   ├── lib/        # Reusable PowerShell module (Memorybox.psm1)
│   ├── setup/      # Install / config scripts
│   ├── agent/      # (Phase 1) Backup runner
│   ├── tray/       # (Phase 3) System tray widget
│   └── restore/    # (Phase 2) File-level restore
├── linux-mint/     # (Phase 5) Linux Mint full-system backup & restore
├── shared/         # Cross-platform config conventions
└── docs/           # Architecture notes, runbooks
```

## Quick start (Windows)

See [`windows/README.md`](windows/README.md) for the detailed setup walkthrough.
Short version:

```powershell
git clone https://github.com/CustomerNode/DesktopMemoryNode.git
cd DesktopMemoryNode\windows\setup
# One-time per user: allow PowerShell scripts to run
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
.\Setup-Node.ps1
```

## Concepts

- **Memorybox** — the cloud destination that stores backup snapshots. Currently
  a Synology NAS reachable on the LAN. Connection details live in
  `MEMORYBOX_*` user environment variables (see [`shared/CONFIG.md`](shared/CONFIG.md)).
- **Node** — a single desktop participating in backups. Each node owns its
  own restic repo, encryption key, schedule, and credentials.
- **Snapshot** — a point-in-time encrypted backup uploaded to the memorybox.
  Created by [restic](https://restic.net).

## Roadmap

The project builds in phases. Each phase ends with something useful on its own.

### Phase 0 — Scaffolding ✅
- Repo layout, READMEs, `.gitignore`
- Reusable PowerShell module (`windows/lib/Memorybox.psm1`)
- Setup scripts: env vars, install restic, preflight diagnostic, orchestrator
- Shared config conventions (`shared/CONFIG.md`)

### Phase 1 — Backup engine end-to-end
- Initialize encrypted restic repo on the NAS
- Configurable backup targets (paths in / paths excluded), set during setup
- Scheduled daily backup via Windows Task Scheduler
- Retention policy: keep 7 daily, 4 weekly, 12 monthly snapshots
- Per-run logging with rotation
- Lock file to prevent concurrent runs
- One restic repo per node

### Phase 2 — Verification & restore
- Weekly `restic check` (integrity verification)
- Monthly automated test-restore (round-trip check that decryption works)
- File-level restore CLI
- Restore runbook (`docs/runbooks/restore-windows.md`) — what to do if the desktop dies

### Phase 3 — System tray widget
PowerShell + WinForms tray icon. Right-click menu:
- **Status** — last backup, next scheduled, repo size, last verify, last test-restore
- **Snapshot now** — on-demand backup
- **Test restore** — pick a snapshot, enter encryption password, restore one file to scratch, verify decryption + integrity, report
- **Edit memorybox config** — update HOST / PORT / USER / PASSWORD from the widget
- **Open NAS in browser**
- **View log**

### Phase 4 — Notifications
- Windows toast notifications (via BurntToast) for backup success / failure
- Failure toasts identify "tech support: Sam" so the user knows who to contact
- Optional channels (push to phone via Pushover/ntfy, email, Discord/Slack webhook) — add later if desired

### Phase 5 — Linux Mint
- Full-system backup engine (candidate: restic on `/` with excludes, or Clonezilla for bare-metal)
- Bare-metal restore tooling (live USB + pull from memorybox)
- systemd timer for scheduling
- Equivalent setup scripts under `linux-mint/setup/`

## License

See [LICENSE](LICENSE).
