# Restore runbook (Linux Mint)

How to get files back -- from a single deleted file all the way to bare-metal
recovery on a fresh install.

## What you need

| Thing | Where it lives |
|---|---|
| The encryption password (`enc_pswd`) | Your password manager -- the only place if this disk is dead |
| Memorybox connection details | Same |
| Your **node name** | The directory name under `/volume1/homes/$USER/` is `dmn-<nodename>` |
| Linux Mint live USB (for bare metal) | https://linuxmint.com/edition.php?id=315 |

## Scenario A: A specific file was deleted

You still have a working machine with DesktopMemoryNode set up.

```bash
cd ~/dmn/linux-mint/restore

# 1. List snapshots
./restore-file.sh --list

# 2. Restore one file from the latest snapshot to a SAFE staging dir
./restore-file.sh \
    --latest \
    --include /home/$USER/Documents/report.docx \
    --dest /tmp/dmn-restore

# 3. Inspect /tmp/dmn-restore/, copy what you need to its real home
```

`--dest` is required -- the script never restores in-place over your live filesystem.

## Scenario B: A specific point in time

```bash
./restore-file.sh --list
# ID        Time                 Tags
# 61df23cb  2026-05-10 11:48:27  manual
# a7e3...   2026-05-09 02:00:00  scheduled
# ...

./restore-file.sh \
    --snapshot a7e3 \
    --include /home/$USER/Documents/report.docx \
    --dest /tmp/restore-yesterday
```

## Scenario C: Bare-metal restore on a fresh Linux Mint install

You're on a brand-new install. The old machine is gone. You need everything
back.

### 1. Boot the live USB and install Linux Mint normally

Get to a working desktop, get on Wi-Fi, open a terminal.

### 2. Install dependencies + clone the repo

```bash
sudo apt-get update
sudo apt-get install -y git restic jq libnotify-bin
git clone https://github.com/CustomerNode/DesktopMemoryNode.git ~/dmn
cd ~/dmn/linux-mint/setup
chmod +x ../**/*.sh
```

### 3. Set the env vars

You can use the setup script (interactive prompts) -- it'll ask for everything.

```bash
./set-memorybox-vars.sh
```

When it asks for `MEMORYBOX_NODE_NAME`, use the OLD node's name (so you point
at the existing repo). When it asks for `enc_pswd`, use the password you saved
to your password manager.

### 4. Verify access

```bash
./test-setup.sh
```

The "restic repo unlocks with enc_pswd" line confirms you have the right
password and can read the repo. If that fails, fix it before continuing.

### 5. Restore everything to a staging dir

This pulls the entire latest snapshot -- could be many GB:

```bash
mkdir -p ~/restore-staging
~/dmn/linux-mint/restore/restore-file.sh --latest --dest ~/restore-staging
```

### 6. Move folders back

The snapshot was a system backup, so you'll see a tree like:

```
~/restore-staging/
├── etc/
├── home/
├── opt/
├── root/
├── usr/  (mostly excluded by default)
├── var/  (mostly excluded by default)
└── ...
```

For typical recovery you'll mainly want `~/restore-staging/home/<youruser>/`
copied back to `/home/<youruser>/`. **Don't blanket-overwrite system dirs**
-- the new install has its own `/etc`, `/var`, etc. and they should stay
unless you have a specific reason.

```bash
# Example: restore your home directory contents
rsync -a ~/restore-staging/home/$USER/ ~/
```

For specific files only:

```bash
~/dmn/linux-mint/restore/restore-file.sh \
    --latest \
    --include /etc/something \
    --dest ~/restore-staging
```

### 7. (Re)set up scheduled backups

```bash
~/dmn/linux-mint/setup/install-schedule.sh
```

If you reused the old node name, your existing 4-snapshot retention continues
seamlessly. If you want a new identity, re-run `set-memorybox-vars.sh --force`
and pick a new node name (creates a fresh `dmn-<newname>/` on the NAS).

## What NOT to do

- **Don't restore directly over a live `/` filesystem.** Always restore to a
  staging dir, then `rsync` selectively.
- **Don't reuse the same node name on multiple active machines** -- they'll
  fight each other's retention policies.
- **Don't run `restic forget` by hand** unless you understand the retention
  model. Use `agent/invoke-forget.sh`.

## When in doubt

1. Stop. Don't make it worse.
2. Read the latest log: `cat ~/.local/state/dmn/logs/backup-$(date +%F).log`
3. Run `setup/test-setup.sh` to see what's working.
4. Contact tech support (your `DMN_TECH_NAME` -- see `~/.config/dmn/env`).
