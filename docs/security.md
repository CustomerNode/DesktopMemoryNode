# Security model

What DesktopMemoryNode protects you against, and what it doesn't.

## Threat model -- in scope

| Threat | Defense |
|---|---|
| Local disk failure | Daily off-machine backups to the NAS |
| Stolen / dead machine | Same. Restore from any new machine using the encryption password. |
| **Ransomware on the desktop** | Snapshot retention (4 distinct snapshots; today / week / month / manual). The retention policy keeps an old snapshot intact even if today's gets encrypted by ransomware. |
| Bit rot on the NAS | Weekly `restic check`; you'll get a notification if the repo corrupts. |
| The NAS owner reading your files | **Client-side AES-256 encryption.** The NAS sees ciphertext only. The encryption key (`enc_pswd`) lives in your User-scope env on your machine; it's never written to the repo and never sent to the NAS. |
| Disk theft of the NAS itself | Same -- ciphertext only on disk. |
| Accidental file deletion | Restore from any of the 4 snapshots via `Restore-File.ps1` / `restore-file.sh`. |
| Forgetting whether the password works | Monthly automated test-restore + on-demand "Test restore" button in the tray that prompts for the password fresh. |

## Threat model -- out of scope

| Threat | Why not covered, and what you could add |
|---|---|
| House fire, lightning, flood | Single-NAS = single point of failure. Easy upgrade: rclone-sync the restic repo to S3/B2 weekly. |
| Sophisticated targeted attacker on your machine | If they get root/admin while you're logged in, they can read `enc_pswd` from the registry. Mitigation: use a hardware key + DPAPI for the env var (not implemented). |
| Account compromise on the NAS | If someone steals your `MEMORYBOX_PASSWORD` they can DELETE your repo. They still can't decrypt it without `enc_pswd`. Mitigation: snapshot-protect the share on DSM (immutable backups feature). |
| Encryption key loss | **No recovery.** If you lose `enc_pswd` AND your password manager AND every offline copy, the data is gone. By design -- this is the same property that protects you from the NAS owner. |
| Tampering with the agent code | If an attacker can edit the .ps1 files in the repo, they can substitute their own backup destination or skip encryption. Mitigation: run from a read-only directory + verify SHA256 on every launch (not implemented). |

## Why the encryption key is an env var

Three options were considered:

1. **Env var** (chosen). Stored in HKCU on Windows (`[Environment]::Set...('enc_pswd', ..., 'User')`) or in `~/.config/dmn/env` mode 600 on Linux. Inherited by every process the user starts -- so scheduled tasks "just work" without any extra plumbing. Easy to rotate. Easy to NOT commit (no file = no risk).
2. **DPAPI-encrypted blob on disk.** More secure (encrypted with the user's Windows credentials), but adds a dependency on Windows DPAPI and complicates Linux. Worth doing if/when this matures past personal use.
3. **Prompt every backup.** Maximum security but breaks unattended scheduled backups -- a non-starter for the core use case.

We picked (1) because it's the right tradeoff for the threat model: an
attacker with HKCU access has already escalated past "ordinary computer use"
and the additional protection of (2) is marginal. The user typing the
password every backup (3) doesn't fit a Mom-friendly "set it and forget it"
product.

## What you should do as the operator

- **Save `enc_pswd` to your password manager.** This is the one secret you
  can't recover. Both the original and at least one backup machine should
  use the same value (and you should have it in 1Password / Bitwarden /
  paper in a safe).
- **Rotate the NAS password (`MEMORYBOX_PASSWORD`) periodically.** It's a
  separate credential and only controls write/read access to the encrypted
  blobs.
- **Patch your NAS.** Synology DSM gets regular security updates. Auto-
  installing them in DSM Control Panel is a one-time toggle.
- **Don't share the same `MEMORYBOX_USER` across people.** Give each family
  member their own DSM account. Each user picks their own node name(s).
