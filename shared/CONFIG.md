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
| `MEMORYBOX_NODE_NAME` | Unique name for this node (slug)         | `kitchen`                | no        |

### Node naming

Every node that backs up to the memorybox must have a unique `MEMORYBOX_NODE_NAME`.
This name is used to partition each node's backups into its own area on the NAS,
so multiple machines can share the same NAS account without conflicts.

**Format:** lowercase letters, digits, and hyphens. 1–32 chars. Must not start
or end with a hyphen. Regex: `^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$`.

**Examples:** `kitchen`, `office`, `laptop`, `studio-mac`.

**Storage convention:** each node's restic repo lives at
`\\<MEMORYBOX_HOST>\home\dmn-<MEMORYBOX_NODE_NAME>\` on Windows, or
`smb://<MEMORYBOX_HOST>/home/dmn-<MEMORYBOX_NODE_NAME>/` semantically.

**Conflict checking:** setup refuses to register a node name that already has
a `dmn-<name>` directory on the NAS unless `-Reuse` is passed (e.g., reinstalling
on the same machine after wipe).

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
