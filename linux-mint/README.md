# linux-mint/

Linux Mint full-system backup & restore.

**Scope:** complete system images suitable for bare-metal restore — bootloader,
partitions, installed packages, user data. Engine TBD (Timeshift snapshots,
Clonezilla images, or a custom block/filesystem-level pipeline).

## Planned contents

- `agent/` — backup runner (systemd timer or cron)
- `config/` — what to include/exclude, schedule, retention
- `restore/` — bare-metal restore tooling (live USB boot + pull from memorybox)
- `install.sh` — install + systemd unit registration
