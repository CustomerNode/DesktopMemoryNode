# Restore runbook (Windows)

How to get your files back from the memorybox. Read this when something has gone wrong;
read it once now so you know it exists.

## What you need to have

| Thing | Where it lives |
|---|---|
| The encryption password (`enc_pswd`) | In your password manager — and only there if this disk is dead |
| Memorybox connection details (host, port, username, password) | Same |
| Your **node name** | Pick from the directories at `\\<host>\home\dmn-*\` |
| A working Windows machine | Doesn't have to be the same hardware |
| restic | Will install via winget if missing |

If you have all of the above, full recovery from total data loss is ~10 minutes.

If you've lost the encryption password and don't have it anywhere offline, **stop reading.
The data is unrecoverable.** That's by design — see [`docs/security.md`](../security.md).

## Scenario A: A specific file was deleted or corrupted

You still have a working machine and your DesktopMemoryNode is set up. You just need
one (or a few) files back.

```powershell
cd $env:USERPROFILE\repos\DesktopMemoryNode\windows\restore

# 1. See what snapshots are available
.\Restore-File.ps1 -List -Destination $env:TEMP\dmn-restore

# 2. Restore the file from the latest snapshot to a SAFE location (NOT the original path)
.\Restore-File.ps1 `
    -Latest `
    -Path 'C:\Users\donca\Documents\report.docx' `
    -Destination 'C:\Users\donca\restored'

# 3. Inspect the restored file under C:\Users\donca\restored\
#    Move it to its real home only after you've confirmed it's the right version.
```

The script will NEVER restore over your real filesystem unless you point `-Destination`
there. Always restore to a staging dir first, then move manually.

## Scenario B: Picking from a specific point in time

Say you want yesterday's version, not the latest. List snapshots and pick by ID:

```powershell
.\Restore-File.ps1 -List -Destination $env:TEMP\dmn-restore
# ID        Time                 Tags
# 61df23cb  2026-05-10 11:48:27  manual
# a7e3...   2026-05-09 02:00:00  scheduled
# ...

.\Restore-File.ps1 `
    -SnapshotId a7e3 `
    -Path 'C:\Users\donca\Documents\report.docx' `
    -Destination 'C:\Users\donca\restored-from-yesterday'
```

## Scenario C: This machine is dead. Restoring on a fresh Windows install.

You're on a brand-new machine. The old one is gone. You need everything back.

### 1. Install Git, clone the repo

```powershell
winget install --id Git.Git -e
git clone https://github.com/CustomerNode/DesktopMemoryNode.git $env:USERPROFILE\repos\DesktopMemoryNode
cd $env:USERPROFILE\repos\DesktopMemoryNode
```

### 2. Set the connection vars

You can use the setup script (interactive prompts) **or** set the env vars directly:

```powershell
[Environment]::SetEnvironmentVariable('MEMORYBOX_HOST',      '<NAS IP>',    'User')
[Environment]::SetEnvironmentVariable('MEMORYBOX_PORT',      '5000',        'User')
[Environment]::SetEnvironmentVariable('MEMORYBOX_USER',      '<your user>', 'User')
[Environment]::SetEnvironmentVariable('MEMORYBOX_PASSWORD',  '<NAS pwd>',   'User')
[Environment]::SetEnvironmentVariable('MEMORYBOX_NODE_NAME', 'kitchen',     'User')   # the OLD node's name
[Environment]::SetEnvironmentVariable('enc_pswd',            '<from password manager>', 'User')
```

Open a fresh PowerShell so the env vars apply.

### 3. Install restic

```powershell
.\windows\setup\Install-Restic.ps1
```

### 4. Verify access

```powershell
.\windows\setup\Test-Setup.ps1
```

All checks should be green. The "Restic repo unlocks with $env:enc_pswd" check
confirms the password is correct.

### 5. Restore everything

This pulls the **entire** latest snapshot back to `C:\restore-staging\`:

```powershell
.\windows\restore\Restore-File.ps1 `
    -Latest `
    -Destination C:\restore-staging
```

Then move folders back to where they belong (`Documents`, `Pictures`, etc.).

### 6. (Re)set up scheduled backups

Once you've verified your data, register the schedule on the new machine. If it's the
same machine name as before (i.e. you reused `kitchen`), backups continue against the
existing repo. If you want a new identity, run `Set-MemoryboxVars.ps1 -Force` and pick
a new `MEMORYBOX_NODE_NAME` (this creates a fresh `dmn-<newname>` directory).

```powershell
.\windows\setup\Setup-Node.ps1
```

## What NOT to do

- **Don't restore directly over your live filesystem.** Always restore to a staging dir
  first. The Restore-File script enforces this by requiring an explicit `-Destination`.
- **Don't reuse a node name on multiple active machines.** They'll fight each other's
  retention policies.
- **Don't run `restic forget` by hand** unless you understand the retention model. Use
  `Invoke-Forget.ps1` which knows about the 4-snapshot policy.

## When in doubt

1. Stop. Don't make it worse.
2. Open the latest backup log: `notepad "$env:LOCALAPPDATA\DesktopMemoryNode\logs\backup-YYYY-MM-DD.log"`
3. Run `windows\setup\Test-Setup.ps1` to see what's working.
4. Tray widget → "Test restore" — proves the path from snapshot → decrypted file works
   without touching anything else.
5. Contact your tech support person (the one named in `DMN_TECH_NAME`).
