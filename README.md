# DesktopMemoryNode

> Encrypted, scheduled, self-verifying desktop backups to a home NAS. Built as a
> Mother's Day gift; designed for non-technical users with all the dev tools
> tucked behind an "Advanced" submenu.

**Status:** All five phases complete. Tested live against a Synology NAS.

---

## What it does

- **Encrypts your files locally** before they ever leave the machine. The NAS
  only ever sees ciphertext. Lose the password and even the NAS owner can't
  recover the data.
- **Saves automatically** every day at 02:00, with a **system tray app** for
  on-demand snapshots, status, and one-click restore-tests.
- **Always keeps exactly 4 distinct snapshots** per machine: today, ~1 week ago,
  ~1 month ago, and the most recent on-demand "save now". Overlap doesn't
  collapse the count.
- **Verifies itself.** Weekly integrity check (`restic check`). Monthly
  test-restore round-trip (decrypt one file, hash-check). Both feed into a
  status dashboard so you can tell at a glance whether things are healthy.
- **Toasts on failure** so you (or whoever's tech support) hears about it.
  Sticky notifications via BurntToast -- they stay on screen until dismissed.
- **Same conventions on Linux Mint** as on Windows -- one repo, two platform
  agents, identical retention policy.

## Quick install

| Platform | One-liner |
|---|---|
| **Windows** | `git clone https://github.com/CustomerNode/DesktopMemoryNode && cd DesktopMemoryNode\windows\setup && Set-ExecutionPolicy -Scope CurrentUser RemoteSigned && .\Setup-Node.ps1` |
| **Linux Mint** | `git clone https://github.com/CustomerNode/DesktopMemoryNode ~/dmn && cd ~/dmn/linux-mint/setup && chmod +x ../**/*.sh && ./setup-node.sh` |

The orchestrator handles everything: env vars, restic install, encrypted repo
init on the NAS, scheduled tasks/timers, tray app, preflight checklist.

See [`windows/README.md`](windows/README.md) and
[`linux-mint/README.md`](linux-mint/README.md) for detailed walkthroughs.

## Architecture

See [`docs/architecture.md`](docs/architecture.md) for the full picture.
Short version:

```
   +-----------------+         encrypted snapshot
   |   Your machine  |  ----------------------------->   +---------------+
   |  (Win or Linux) |                                   |  Memory Box   |
   |                 |                                   |  (Synology)   |
   |  restic agent   |  <-----------------------------   |               |
   |  + tray widget  |       restore (only to a          |  dmn-<node>/  |
   +-----------------+        scratch dir, never                          |
            |                  in-place over /)                           |
            |                                            +---------------+
            |
       state.json
       targets.json
       enc_pswd (env var)
```

- **Each machine has a unique node name** (e.g. `kitchen`, `office-laptop`).
  Storage is partitioned at `\\<host>\home\dmn-<nodename>\` so multiple
  machines coexist on the same NAS account without colliding.
- **Encryption key is the `enc_pswd` env var** (User scope). Never stored in
  the repo. Lose it and the backups are unrecoverable -- by design. See
  [`docs/security.md`](docs/security.md) for the full threat model.
- **Restic** does the heavy lifting (encryption, dedup, snapshots). All the
  scripts here are wrappers that bake in the conventions: per-node repos,
  4-snapshot retention, scheduling, status, toasts, verify, test-restore.

## Repository layout

```
DesktopMemoryNode/
├── README.md                    # This file
├── shared/
│   └── CONFIG.md                # Env-var convention used by all platform agents
├── docs/
│   ├── architecture.md          # Data flow, threat model, why decisions were made
│   └── runbooks/
│       ├── restore-windows.md   # File-level + bare-metal recovery (Windows)
│       ├── restore-linux.md     # File-level + bare-metal recovery (Linux Mint)
│       └── second-node.md       # Onboarding a new machine in <5 minutes
├── windows/
│   ├── lib/Memorybox.psm1       # Reusable PowerShell module
│   ├── setup/                   # One-time setup scripts (idempotent)
│   ├── agent/                   # Backup, forget, verify, test-restore runners
│   ├── restore/                 # File-level restore CLI
│   ├── tray/                    # System tray widget + installer
│   └── tests/                   # Pester v5 unit tests
└── linux-mint/
    ├── lib/memorybox.sh         # Shared bash helpers
    ├── setup/                   # Setup orchestrator + per-step scripts
    ├── agent/                   # Backup, forget, verify, test-restore
    └── restore/                 # File-level restore CLI
```

## Personalization

Three optional User-scope env vars control the user-facing wording:

| Variable | Example | Purpose |
|---|---|---|
| `DMN_DISPLAY_NAME` | `Mom` | Greeting on this machine |
| `DMN_TECH_NAME` | `Sam` | Person to contact when something needs attention |
| `DMN_TECH_CONTACT` | `sam@example.com` | Phone or email; appears in error toasts and form footers |

Empty values degrade gracefully (generic "Memory Box" wording, "tech support"
in place of a name).

## Roadmap recap

| Phase | What it shipped |
|---|---|
| 0 | Reusable PowerShell module, env-var setup, install-restic, preflight diagnostic, orchestrator |
| 1 | Encrypted restic repo init, configurable backup targets, scheduled daily backup, retention (4 distinct snapshots), per-run logging, lock file |
| 2 | Weekly integrity check (`restic check`), monthly test-restore round-trip, file-level restore CLI, restore runbook |
| 3 | System tray widget -- status dashboard with action buttons, snapshot browser with file tree, on-demand actions, advanced submenu for tech tools |
| 4 | BurntToast install, sticky toast notifications (`Reminder` scenario, stays until dismissed) for backup/verify/restore success and failure |
| 5 | Linux Mint port -- bash equivalents of all the above, systemd user timers, full-system backup with sensible default excludes |
| 6 | Pester v5 unit test suite (41 tests, all passing) |
| 7 | Documentation polish |

## License

MIT. See [LICENSE](LICENSE).
