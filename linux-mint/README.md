# linux-mint/

Linux Mint node: full-system backup to the cloud memorybox via SFTP.

## Layout

```
linux-mint/
├── lib/
│   └── memorybox.sh           # shared helpers (sourced by other scripts)
├── setup/
│   ├── set-memorybox-vars.sh  # write ~/.config/dmn/env
│   ├── install-restic.sh      # apt install restic + jq + libnotify-bin
│   ├── initialize-restic-repo.sh  # init encrypted repo on the NAS over SFTP
│   ├── install-schedule.sh    # install systemd USER timers (no root)
│   ├── test-setup.sh          # preflight diagnostic
│   └── setup-node.sh          # orchestrator (runs the above in order)
├── agent/
│   ├── invoke-backup.sh       # daily/manual backup of /
│   ├── invoke-forget.sh       # retention: always 4 distinct snapshots
│   ├── invoke-verify.sh       # restic check (structural integrity)
│   └── invoke-test-restore.sh # round-trip test (scratch dir only)
└── restore/
    └── restore-file.sh        # file-level restore CLI
```

## Setup walkthrough

Linux Mint 21+ (Ubuntu 22.04 base). Everything runs as your user; the only
sudo step is `apt-get install`.

### Prerequisites

- The memorybox connection details (host/IP, port, username, password)
- SSH/SFTP enabled for your account on the box (Synology DSM: Control Panel ->
  Terminal & SNMP -> Enable SSH, plus add your user to the `administrators`
  group OR explicitly grant SSH per-user via DSM 7+ Application Privileges)
- The encryption password (`enc_pswd`) -- if reusing an existing repo, this
  must match the one set on the original node, otherwise pick a new one for
  this node's first init

### Step 1 -- Clone the repo

```bash
sudo apt-get install -y git
git clone https://github.com/CustomerNode/DesktopMemoryNode.git ~/dmn
cd ~/dmn/linux-mint/setup
chmod +x ../**/*.sh
```

### Step 2 -- Run the orchestrator

```bash
./setup-node.sh
```

This installs dependencies (with sudo for apt), prompts for the env vars,
initializes the encrypted repo on the NAS, registers systemd user timers,
and runs the preflight diagnostic.

### Step 3 -- Verify

```bash
./test-setup.sh
```

You should see all green `[OK]` lines. To check timer status:

```bash
systemctl --user list-timers dmn-*
journalctl --user -u dmn-backup -n 50
```

## Backup targets

Default is full system (`/`) with sensible excludes for caches, runtime, swap,
and per-user `.cache` / Trash / snap / steam directories. See
`lib/memorybox.sh` -> `dmn_default_targets`. To customize, write your own
`~/.config/dmn/targets.json` matching the same JSON shape.

## Personalization

Same as Windows -- optional User-scope env vars in `~/.config/dmn/env`:
`DMN_DISPLAY_NAME`, `DMN_TECH_NAME`, `DMN_TECH_CONTACT`. See
[`shared/CONFIG.md`](../shared/CONFIG.md).

## Restore

Two scenarios: file-level (something got deleted) and bare-metal (the disk
died, restoring to a fresh install). See
[`docs/runbooks/restore-linux.md`](../docs/runbooks/restore-linux.md).
