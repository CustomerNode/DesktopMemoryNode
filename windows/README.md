# windows/

Windows node: file-system backups to the cloud memorybox.

## Layout

```
windows/
├── lib/
│   └── Memorybox.psm1            # reusable PowerShell module
├── setup/
│   ├── Set-MemoryboxVars.ps1     # interactive env-var setup
│   ├── Install-Restic.ps1        # winget install + verify
│   ├── Test-Setup.ps1            # diagnostic preflight
│   └── Setup-Node.ps1            # orchestrator (runs the above in order)
└── README.md                     # this file
```

## Setup process for a new Windows node

Follow these steps on each new Windows machine you want to back up. Everything
runs in user scope — **no admin required**.

### Prerequisites
- Windows 10/11 with PowerShell 5.1+ (built in)
- `winget` (built into Windows 11; on Windows 10 install "App Installer" from the Microsoft Store)
- The memorybox connection details: host/IP, port, username, password
- Network reachability to the memorybox

### Step 1 — Clone this repo

```powershell
git clone https://github.com/CustomerNode/DesktopMemoryNode.git
cd DesktopMemoryNode\windows\setup
```

If you don't have git: `winget install --id Git.Git -e`.

### Step 2 — Run the orchestrator

```powershell
.\Setup-Node.ps1
```

This runs three steps in order:

1. **`Set-MemoryboxVars.ps1`** — prompts for `MEMORYBOX_HOST`, `MEMORYBOX_PORT`,
   `MEMORYBOX_USER`, `MEMORYBOX_PASSWORD`. Skips anything that's already set
   (use `-Force` to re-prompt). The password input is hidden.
2. **`Install-Restic.ps1`** — installs the restic backup engine via winget. No-op
   if already installed.
3. **`Test-Setup.ps1`** — preflight diagnostic. Checks env vars, ICMP, TCP, HTTP,
   DSM API auth, SMB shares, restic install. Prints a pass/fail checklist.

If any check in step 3 fails, the script exits with a non-zero code and tells
you what to fix. Re-run `Setup-Node.ps1` after fixing.

### Step 3 — Open a fresh terminal

The newly-set env vars and `restic` PATH entry only take effect in **child
processes started after** they were set. Close this terminal and open a new
one before continuing.

### Verify

```powershell
.\Test-Setup.ps1
```

You should see all green `[OK]` lines.

## Running individual scripts

Each setup script can be run on its own — they're idempotent.

| Script                    | When to run                                   |
|---------------------------|-----------------------------------------------|
| `Set-MemoryboxVars.ps1`   | Update connection details (e.g. password change) |
| `Set-MemoryboxVars.ps1 -Show` | Show current values without changing anything (password masked) |
| `Set-MemoryboxVars.ps1 -Force` | Re-prompt for everything                  |
| `Install-Restic.ps1`      | Re-check / repair restic install              |
| `Test-Setup.ps1`          | Diagnose connectivity issues anytime          |
| `Setup-Node.ps1`          | New machine, or re-run after major changes    |

## Using the module from your own scripts

```powershell
Import-Module .\lib\Memorybox.psm1

$cfg = Get-MemoryboxConfig                 # non-secret config
$cred = Get-MemoryboxCredential            # PSCredential for cmdlets that need -Credential
$conn = Test-MemoryboxConnection           # ICMP/TCP/HTTP probe object
$auth = Test-MemoryboxAuth                 # DSM API auth check
Connect-MemoryboxSmb                       # establish SMB session with stored creds
$shares = Get-MemoryboxShares              # list accessible shares
```

## Planned (not yet implemented)

- `restic-repo/` — repo init script + canonical paths on the NAS
- `agent/` — backup runner (scheduled task)
- `restore/` — file-level restore CLI
