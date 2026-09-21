# Install provenance ledger (HIMMEL-3332)

Every himmel writer that installs something onto a machine records what it did
in one append-only ledger, so an uninstall can later remove exactly what himmel
added and nothing the operator owned before. This page is the format reference
for the helpers that write it. The helpers ship in three dialects that emit
**byte-identical rows**:

| Dialect | File | Used by |
|---|---|---|
| bash | `scripts/lib/provenance.sh` | shell writers (`source` it) |
| node | `scripts/himmelctl/lib/provenance.js` | `himmelctl` writers (`require` it, or run it as a CLI) |
| PowerShell | `scripts/lib/provenance.ps1` | `.ps1` writers (dot-source it) |

Tests: `scripts/lib/test-provenance.sh` (bash, plus a pwsh block that skips
with a named SKIP when `pwsh` is absent) and
`scripts/himmelctl/test/test-provenance-js.sh` (node, plus the bash-vs-node
byte-identity cross-check).

## Where it lives

```text
${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/provenance.jsonl              # the ledger, mode 0600
${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/provenance-backups/<iid>/     # pre-state copies, mode 0700
```

One JSON object per line, appended with a single write (the PowerShell dialect
holds the ledger open exclusively while it appends, retrying if another writer
has it). A reader must skip a
line that does not parse: a crash can leave a torn last line, and the writers
close it with a newline before the next append so it costs one row, not two.

## Sessions and rows

A **session** is one install (or uninstall) run, identified by an `iid`
(`<UTC yyyymmddThhmmssZ>-<6 hex>`). `prov_begin` opens it and exports
`HIMMEL_PROVENANCE_IID`, so every child process a writer spawns appends into
the same session. A writer that finds no session open records a one-row session
of its own (`install-begin`, the row, `install-end ok`).

| `op` | Row | Keys, in order |
|---|---|---|
| `install-begin` | session start | `t iid op himmel_root himmel_head version argv home claude_config_dir target platform writer` |
| `install-end` | session end | `t iid op status failed_step` (`status`: `ok` / `failed` / `partial`) |
| artifact ops | one artifact | `t iid op kind path unit scope class <extra fields> pre post writer manifest_row` |

Absent keys are omitted from an artifact row. `path` is absolute, with the
parent chain resolved (a symlink basename is kept as the link) and forward
slashes on Windows; `-` means "no path" (registrations).

Vocabularies (a value outside them is a usage error):

- `op`: `create replace insert append register link noop`
- `kind`: `file tree json-key json-elem block line plugin marketplace job unit shim symlink git-hook mcp collection tool`
- `scope`: `user project clone machine`
- `class`: `code state keep`

## Pre- and post-state

`pre` is `{"state":"absent"}`, or `{"state":"present", <body>, "backup":"<abs path>|null"}`.
`post` is the body alone. The body depends on what was hashed:

| Source | Body |
|---|---|
| a file (`--pre-file` / `--post-file`) | `{"sha","size","mode"}` (`mode` is a four-digit octal string) |
| a value of kind `json-key` / `json-elem` | `{"sha"}` of `jq -cS` of the value |
| a value of any other kind | `{"value": <canonical JSON>}` (a registration has no bytes) |
| text (`--pre-text` / `--post-text`) | `{"sha"}` of the exact bytes |

Canonical bytes per kind: file/tree = the file's bytes; json-key/json-elem =
`jq -cS` of the value; block = the bytes from the BEGIN through the END marker
line; line = the line without its terminator.

`--backup` copies the pre-state into `provenance-backups/<iid>/<seq>-<basename>`
(`<seq>` is a three-digit counter): the file itself for `--pre-file` (mode kept),
`.prior.json` for `--pre-json` (canonical, no trailing newline), `.prior.txt` for
`--pre-text`. The backup's sha256 always equals `pre.sha`. The sequence number
is reserved with an exclusive create, so concurrent writers sharing one `iid`
never collide on a name.

## Calling contract

```bash
. scripts/lib/provenance.sh
prov_begin --writer adopt.sh -- "$@"
# ... backup the old bytes to $snap, do the atomic write ...
prov_record replace file "$dest" --pre-file "$snap" --backup --post-file "$dest" \
    --scope project --class code --row adopter-scripts
prov_end ok
```

- Call `prov_record` **after** the writer's own atomic write succeeded and
  **before** it prints its success line. `--pre-file` names a file holding the
  *pre* bytes (the original, or the writer's snapshot of it), never the
  already-overwritten destination.
- `--field KEY=JSON` (repeatable) adds writer-specific keys such as
  `container_created`, `file_created`, `preexisted`, `elem_sha`. The keys named
  in the table above are reserved. A repeated key keeps its first position and
  takes its last value.
- **Dry runs** (`DRY_RUN=1`, `--dry-run`, `-DryRun`) write nothing and print
  `DRY: record <op> <kind> <path>`; `begin`/`end` stay silent.
- **Failures**: usage errors are rc 2 (bash/node CLI) and I/O or missing-tool
  failures rc 1, with `provenance: <why>` on stderr. The PowerShell functions
  throw the same message. Whether a failed record is fatal is the caller's call.
- `prov_end` closes only a session **this process opened**; a child that merely
  inherited `HIMMEL_PROVENANCE_IID` is a silent no-op, and a failed append leaves
  the session open so the call can be retried. (The node CLI is one process per
  call, so `begin` **prints the session id** for the caller to export as
  `HIMMEL_PROVENANCE_IID`, and `end` closes the exported session
  unconditionally.)
- A session id names a backup directory, so `--backup` refuses (rc 1) an `iid`
  that is not one safe path segment (`[A-Za-z0-9._-]+`, not `.` or `..`).
- Every JSON value (`--pre-json`, `--post-json`, `--field`) must be exactly one
  JSON document; an empty value or `1 2` is refused (rc 1 / rc 2 for `--field`).

Test seams: `HIMMEL_PROVENANCE_NOW` fixes `t`; `prov_begin --iid` fixes the
session id; `HIMMEL_PROVENANCE_DIR` relocates the ledger. Every test runs under a
scratch `HOME` and never touches the real `~/.himmel`.

## Known limits

- No jq on `PATH`: the node and PowerShell dialects fall back to a pure-language
  canonicaliser that diverges from `jq -cS` on non-canonical number literals
  (`1.0`, `1E+2`, integers past 2^53) and non-BMP key order. Every install host
  already requires jq, so this is a fallback, not a supported mode.
- The PowerShell dialect could not be executed where it was written; it is held
  to the same rows by construction and by the pwsh-gated test block. On Windows
  it omits `mode` and does not resolve symlinked parents or 8.3 short names.
- Backup cleanup at `install-end` and the reader that consumes the ledger belong
  to the uninstall slices; these helpers only write.
