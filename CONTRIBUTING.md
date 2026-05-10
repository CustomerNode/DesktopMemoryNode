# Contributing

DesktopMemoryNode started as a Mother's Day gift built across one long
session. It's a polished personal project, not a community-managed product.
PRs are welcome anyway; here's how the codebase is organized so you can
move fast.

## Structure

```
windows/
├── lib/Memorybox.psm1        # Reusable PowerShell module -- everything else imports it
├── setup/                    # One-time installers / configurators (idempotent)
├── agent/                    # Backup, forget, verify, test-restore runners
├── restore/                  # File-level restore CLI
├── tray/                     # System tray widget (BackupTray.ps1) + installer
└── tests/                    # Pester unit tests + tray-logic integration tests

linux-mint/                   # bash equivalents of the above (no tray yet)

docs/
├── architecture.md           # Why decisions were made
├── security.md               # Threat model
└── runbooks/
    ├── restore-windows.md
    ├── restore-linux.md
    └── second-node.md
```

## Conventions

- **Env vars** -- All configuration lives in user-scope env vars
  (`MEMORYBOX_*`, `enc_pswd`, `DMN_*`). No config files in the repo.
  See [`shared/CONFIG.md`](shared/CONFIG.md).
- **Per-node partitioning** -- Storage on the NAS is namespaced by
  `dmn-<MEMORYBOX_NODE_NAME>/`. Multiple machines coexist without colliding.
- **Encryption key never in repo** -- `enc_pswd` is read at runtime and
  never logged or persisted to a file under version control.
- **Logging** -- Per-day rotated logs at `%LOCALAPPDATA%\DesktopMemoryNode\logs\`
  (Windows) or `~/.local/state/dmn/logs/` (Linux). Use `Write-DmnLog` /
  `dmn_log` from the lib module so format is consistent.
- **Locks** -- All long-running agent operations use named file locks
  (`Lock-NodeOperation` / `dmn_acquire_lock`) to prevent concurrent runs.
- **Idempotency** -- Setup scripts are safe to re-run. Initialize-ResticRepo
  detects an existing repo + verifies the password unlocks it before
  no-op'ing. Install-Schedule re-registers existing tasks instead of
  failing. This matters because users will run setup-node twice.
- **State updates atomic** -- `Set-NodeState` writes to a tmp file and
  renames; never directly to `state.json`.

## Adding a new agent script (Windows)

1. Drop `windows/agent/Invoke-MyThing.ps1`. Top boilerplate:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $here    = Split-Path -Parent $MyInvocation.MyCommand.Path
   $libPath = Join-Path $here '..\lib\Memorybox.psm1'
   Import-Module $libPath -Force

   $lock = $null
   try {
       Assert-MemoryboxReady
       Connect-MemoryboxSmb
       $lock = Lock-NodeOperation -Name 'mything'
       Write-DmnLog "Mything starting" -Kind 'mything'

       # ... your logic, using Invoke-Restic for restic calls

       Write-DmnLog "Mything OK" -Kind 'mything'
   } catch {
       $err = $_.Exception.Message
       Write-DmnLog "Mything FAILED: $err" -Kind 'mything' -Level ERROR
       Send-MemoryboxToast -Title "Mything FAILED" -Body "$err  $(Get-DmnSupportLine)" -Level Error
       exit 1
   } finally {
       if ($lock) { Unlock-NodeOperation -Handle $lock -Name 'mything' }
   }
   ```

2. Optionally schedule it: edit `windows/setup/Install-Schedule.ps1` and add
   a `New-TaskDefinition` entry pointing at your script.

## Tests

Two suites:

- **Pester unit tests** (`windows/tests/Memorybox.Tests.ps1`) -- pure
  function-level tests, no NAS, no restic. Run via `windows/tests/Run-Tests.ps1`.
- **Tray logic integration tests** (`windows/tests/Test-TrayLogic.ps1`) --
  exercises the live NAS + restic + the tray's actual click-handler logic
  (without showing forms). Includes a smoke test that launches via the VBS
  shortcut and verifies the window title. Run via
  `powershell -ExecutionPolicy Bypass -File windows\tests\Test-TrayLogic.ps1`.

Both should pass before merging changes that touch
`windows/lib/Memorybox.psm1` or `windows/tray/BackupTray.ps1`.

## Linux side

Bash scripts live under `linux-mint/`. Lint with `bash -n`. There's no
shellcheck enforcement yet but they pass shellcheck at warning level. No
tray app on Linux (PRs welcome -- a GTK or libadwaita port would be a
nice contribution).

## Style

- PowerShell: comment-based help on every public function. Approved verbs
  (Get/Set/New/Lock/Unlock/...). UTF-8-with-BOM encoding for `.ps1` files
  (PS 5.1 reads ANSI by default; em-dashes and other non-ASCII break parsing
  without the BOM). ASCII-safe alternatives (`--` instead of `--`) are
  preferred to avoid the issue entirely.
- Bash: `set -euo pipefail` at the top, `set -o pipefail` in sourced libs.
  Quote variables. Use `[[` instead of `[`.
- Markdown: ATX-style headers, no trailing whitespace, ASCII (no en/em dashes).

## License

MIT. Contributions are licensed under the same.
