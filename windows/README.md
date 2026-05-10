# windows/

Windows file-system backup agent.

**Scope:** file & directory backups (not full system images). Targets common
data locations (user profile dirs, project folders, configs) and uploads
snapshots to the cloud memorybox.

## Planned contents

- `agent/` — backup runner (scheduled or on-demand)
- `config/` — what to back up, exclusion rules, schedule
- `restore/` — file-level restore CLI
- `install.ps1` — install + scheduled-task registration
