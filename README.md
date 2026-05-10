# DesktopMemoryNode

Cross-platform desktop backup node: file-level backups on Windows, full system
backup & restore on Linux Mint, syncing to a cloud **memorybox**.

> **Status:** scaffolding. Backup engine, cloud target, and scheduling are not yet implemented.

## Scope

| Platform     | Backup type                    | Restore                      |
|--------------|--------------------------------|------------------------------|
| Windows      | File / directory backups       | File-level restore           |
| Linux Mint   | Full system image              | Full system restore (bare-metal) |

## Repository layout

```
DesktopMemoryNode/
├── windows/        # Windows file-system backup agent + configs
├── linux-mint/     # Linux Mint full-system backup & restore
├── shared/         # Cross-platform pieces: cloud target client, manifest format, common config
└── docs/           # Design notes, architecture decisions, runbooks
```

## Concepts

- **Memorybox** — the cloud destination that stores backup snapshots. Provider and protocol TBD (candidates: S3-compatible, Backblaze B2, rclone-fronted target).
- **Node** — a single desktop participating in backups. Each node owns its own local config, schedule, and credentials.
- **Snapshot** — a point-in-time backup uploaded to the memorybox. Format TBD.

## Roadmap

- [ ] Decide cloud memorybox provider and on-wire format
- [ ] Choose backup engines (e.g. restic for Windows files; Timeshift / Clonezilla / `dd`+pipe for Linux Mint full-system)
- [ ] Define snapshot manifest schema (what was backed up, when, from where, integrity hashes)
- [ ] Windows agent: scheduled file backup → memorybox
- [ ] Linux Mint agent: scheduled full-system backup → memorybox
- [ ] Restore tooling: file-level (Windows) and bare-metal (Linux Mint)
- [ ] Encryption-at-rest, key management, recovery procedure

## License

See [LICENSE](LICENSE).
