# Onboarding a second machine

Once one machine is running DesktopMemoryNode, adding another one is fast.
Both machines back up to the same NAS account but live in separate
directories (`dmn-kitchen/`, `dmn-laptop/`, etc.) so they can't step on each
other's snapshots or retention.

This runbook is < 5 minutes start to finish.

## Prerequisites on the new machine

| Item | How |
|---|---|
| The memorybox connection details | Same host/port/user/password as the first node |
| A NEW node name | e.g. `laptop`, `office`, `studio-mac`. Lowercase + hyphens only. Setup will refuse a name that's already in use. |
| The encryption password | **The same `enc_pswd` as the first node** if you want to reuse the existing repo (and share retention/dedup), OR a fresh one if you want this node to have its own independent encrypted repo |

## Windows

```powershell
# 1. Clone
git clone https://github.com/CustomerNode/DesktopMemoryNode.git $env:USERPROFILE\repos\DesktopMemoryNode
cd $env:USERPROFILE\repos\DesktopMemoryNode

# 2. Allow PowerShell scripts (one-time per user)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

# 3. Set the encryption password BEFORE running setup so the orchestrator
#    can initialize the repo non-interactively.
[Environment]::SetEnvironmentVariable('enc_pswd', '<the same password as your other node, or a new one>', 'User')

# 4. Optional personalization
[Environment]::SetEnvironmentVariable('DMN_DISPLAY_NAME', 'Mom',  'User')
[Environment]::SetEnvironmentVariable('DMN_TECH_NAME',    'Sam', 'User')
[Environment]::SetEnvironmentVariable('DMN_TECH_CONTACT', 'sam@example.com', 'User')

# 5. Open a fresh PowerShell so the env vars apply, then run the orchestrator
.\windows\setup\Setup-Node.ps1
```

The orchestrator will:
1. Prompt you for the connection details (host, port, NAS user, NAS password, node name)
2. Refuse the node name if it collides with an existing one on the NAS
3. Install restic + BurntToast
4. Init the encrypted repo at `\\<host>\home\dmn-<newname>\restic-repo\`
5. Save default backup targets (your user-profile folders)
6. Register the four scheduled tasks (Backup, Forget, Verify, TestRestore)
7. Install the tray app + the desktop / Start Menu / Startup shortcuts
8. Run the preflight diagnostic and report pass / fail

After setup, the tray icon appears next to your clock and the first scheduled
backup runs at 02:00 the next morning. To run one immediately:

```powershell
.\windows\agent\Invoke-Backup.ps1 -Tag manual
```

## Linux Mint

```bash
# 1. Clone
sudo apt-get install -y git
git clone https://github.com/CustomerNode/DesktopMemoryNode.git ~/dmn

# 2. Run the orchestrator -- it'll prompt for everything, including enc_pswd
cd ~/dmn/linux-mint/setup
chmod +x ../**/*.sh
./setup-node.sh
```

The orchestrator's prompts are interactive, so you'll be asked for the
connection details and the encryption password during setup. After it
finishes, daily backups run via systemd user timers.

## Verifying it worked

On either OS, after setup:

- `Test-Setup.ps1` (Windows) / `test-setup.sh` (Linux) -- preflight, all green
- The tray icon (Windows) -- left-click should open the dashboard
- `Invoke-TestRestore.ps1 -PromptPassword` (Windows) /
  `invoke-test-restore.sh --prompt-password` (Linux) -- should show "Test passed"

## What if I picked the wrong node name?

```powershell
# Windows
.\windows\setup\Set-MemoryboxVars.ps1 -Force   # re-prompts for everything
.\windows\setup\Initialize-ResticRepo.ps1      # creates a fresh repo at the new path
```

The OLD `dmn-<oldname>/` directory on the NAS is left alone -- delete it
manually (DSM File Station) if you don't want it.
