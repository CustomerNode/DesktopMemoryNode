# Shared configuration conventions

These conventions apply to **every** DesktopMemoryNode node, regardless of OS.
Both the Windows and Linux Mint agents read the same environment variables so
that setup is portable.

## Environment variables

| Variable              | Purpose                                  | Example                  | Sensitive |
|-----------------------|------------------------------------------|--------------------------|-----------|
| `MEMORYBOX_HOST`      | IP or hostname of the cloud memorybox    | `192.168.1.100`           | no        |
| `MEMORYBOX_PORT`      | Port of the box's primary admin endpoint | `5000`                   | no        |
| `MEMORYBOX_USER`      | Username for the node's NAS account      | `donc`                   | no        |
| `MEMORYBOX_PASSWORD`  | Password for that account                | -                        | **yes**   |

### Scope
- Always **user-scoped**, never machine-scoped. Setup never requires admin.
- On Windows: `[Environment]::SetEnvironmentVariable(..., "User")` (registry-backed)
- On Linux: `~/.config/desktop-memorynode/env` sourced by the agent (TBD)

### Sensitive handling
- The password is the only sensitive variable. Setup scripts MUST read it
  through a hidden prompt (no echo) and MUST NOT log it.
- Never store the password in repository files, scripts, or documentation.
- Never include it in command-line arguments visible to other users via
  process listing.

## Future variables (not yet wired)

| Variable                | Purpose                                          |
|-------------------------|--------------------------------------------------|
| `RESTIC_REPOSITORY`     | Path/URL of the restic repo                      |
| `RESTIC_PASSWORD_FILE`  | Path to a file containing the restic encryption key (separate from MEMORYBOX_PASSWORD) |

The restic encryption key is **separate** from the NAS account password by design:
losing one should not compromise the other, and the NAS admin (e.g. dad) should
not be able to decrypt this node's backups.
