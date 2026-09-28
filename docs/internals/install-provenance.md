# Install provenance ledger (HIMMEL-3332)

Every himmel writer that installs something onto a machine records what it did
in one append-only ledger, so an uninstall can later remove exactly what himmel
added and nothing the operator owned before. This page is the format reference
for the helpers that write it. The helpers ship in two dialects that emit
**byte-identical rows**:

| Dialect | File | Used by |
|---|---|---|
| bash | `scripts/lib/provenance.sh` | shell writers (`source` it) |
| node | `scripts/himmelctl/lib/provenance.js` | `himmelctl` writers (`require` it, or run it as a CLI) |

The PowerShell dialect (for `.ps1` writers) is not shipped yet: it needs a
Windows-tested lane and is tracked in HIMMEL-3346.

Tests: `scripts/lib/test-provenance.sh` (bash) and
`scripts/himmelctl/test/test-provenance-js.sh` (node, plus the bash-vs-node
byte-identity cross-check).

## Where it lives

```text
${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/provenance.jsonl              # the ledger, mode 0600
${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/provenance-backups/<iid>/     # pre-state copies, mode 0700
${HIMMEL_PROVENANCE_DIR:-$HOME/.himmel}/retained-<UTC yyyymmddThhmmssZ>/   # `uninstall.sh --purge-state --keep-backups` output; see below
```

One JSON object per line, appended with a single write. A reader must skip a
line that does not parse: a crash can leave a torn last line, and the writers
close it with a newline before the next append so it costs one row, not two.

## Sessions and rows

A **session** is one install (or uninstall) run, identified by an `iid`
(`<UTC yyyymmddThhmmssZ>-<6 hex>`). `prov_begin` opens it and exports
`HIMMEL_PROVENANCE_IID`, so every child process a writer spawns appends into
the same session. A writer that finds no session open records a three-row session
of its own (`install-begin`, the one artifact row, `install-end ok`).

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
  failures rc 1, with `provenance: <why>` on stderr. Whether a failed record is fatal is the caller's call.
- `prov_end` closes only a session **this shell opened**: a child process, or a
  subshell (`( ... )`, `$( ... )`, a pipeline stage) of the opener, that merely
  inherited `HIMMEL_PROVENANCE_IID` is a silent no-op (ownership is the session id
  plus `BASH_SUBSHELL`, the subshell depth at `prov_begin`), and a failed append leaves
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

## Reading verdicts and backup retention (HIMMEL-3787 S2a)

`scripts/lib/provenance-read.sh` folds raw rows into units and derives a
verdict (`prov_read_verdict`) uninstall acts on. Besides the base
`remove ours` / `restore ours` / `keep no-backup` / `keep already-absent` /
`keep user-modified` rows, two more can fire when live content (`L`) differs
from himmel's post-install content (`ours`, `O`):

- `keep already-base` — `L` equals the pre-install backup (`B`) even though it
  differs from `O`: the unit is resolved and its backup may be released.
- `surgical container-children` — for a whole-object `json-key` container unit
  at exactly `/env` or `/hooks`: fires when every governed child unit under it
  is itself clean (removed/restored this run, `keep already-base`, or
  `keep already-absent` with no backup to hold). The container is never
  restored or written whole; only its children are ever touched.

`prov_read_unit_resolved` is the single predicate for "this unit's backup may
be deleted": true for an outcome of `removed`/`restored` this session, or a
verdict of `keep already-base` / `surgical *`. Every other state — including
`keep user-modified` and bare `keep already-absent` — holds its backup, and
`prov_read_prune_backups` / `uninstall.sh --purge-state`'s scan both refuse to
delete a held backup.

`--purge-state --keep-backups` no longer leaves the ledger deleted and
`provenance-backups/` behind as a permanent orphan (J1393A Minor 1): it
retain-moves both the ledger and the backups directory together into one
`retained-<UTC yyyymmddThhmmssZ>/` directory, which is never deleted
automatically. With that flag, a purge with held backups succeeds (nothing is
lost); without it, a held backup still refuses, naming `--keep-backups` as the
way out. The retain is all-or-nothing in order (J1408A F1/F2): the ledger moves
only after the backups directory moved, so a failed backups move leaves both
live; and the `retained-*` mkdir is retried only on a name collision — any other
failure (permission denied, read-only fs) fails at once with the real error.

### TTY `[r]estore` saves the live file first (HIMMEL-3787 S2b)

On a real terminal without `--yes`, a `keep user-modified` unit with a readable
backup offers `[k]eep` (default) or `[r]estore what you had before himmel`. A
restore would overwrite the operator's current bytes, so `uninstall.sh` first
copies the live file to `<path>.himmel-uninstall-backup` and prints that path;
the unit is then restored and recorded `restored`. If the save cannot be made
(an earlier sidecar or a symlink already sits at that path, or the copy fails)
nothing is restored: the unit is recorded `failed` and its backup is kept.
`--yes` never restores. The offer reads the terminal through fd 8, saved at
start-up, because `ledger_apply_unit` runs inside heredoc loops where fd 0 is
not a terminal.

The same save guards `[d]elete`. A `keep user-modified` unit that himmel
created (no readable backup) offers `[k]eep` (default) or `[d]elete anyway`.
`[d]` copies the live file to the same sidecar and prints the path before it
removes anything; if the save cannot be made the file is kept, the unit is
recorded `failed` and the run exits non-zero. `--yes` and non-TTY runs never
reach the prompt, so they never delete.

## Known limits

- No jq on `PATH`: the node dialect falls back to a pure-language
  canonicaliser that diverges from `jq -cS` on non-canonical number literals
  (`1.0`, `1E+2`, integers past 2^53) and non-BMP key order. Every install host
  already requires jq, so this is a fallback, not a supported mode.
- Every row is appended in one `write(2)` (bash: a private temp file copied by
  `dd bs=<row bytes>`; node: one `O_APPEND` write), so a long row cannot
  interleave with a concurrent writer's. That is atomic on a local POSIX
  filesystem; a network one (NFS) does not promise it. Both dialects'
  torn-last-line check can still see a concurrent large append part-written and
  add an empty line after it; a reader skips lines that do not parse.
- A backslash in a path is a separator only on Windows; on POSIX it is a legal
  filename character and is recorded as given.
- The Windows-specific handling in the bash and node dialects (drive roots `C:/`,
  backslash separators, CRLF from `jq.exe`) is tested here only through Linux
  fixtures, not on Windows.
- In the node dialect only "jq is not installed" (`ENOENT`) selects the fallback
  canonicaliser above. Any other failure to run jq (not executable, killed, output
  past the explicit 256 MiB `maxBuffer`) is `provenance: jq failed to run ...`
  (rc 1), and the next call tries jq again.
- A symlink at the ledger file, at `provenance-backups`, or at a session's backup
  directory is refused (rc 1, `provenance: refusing symlink <path>`) before any
  chmod, append or copy, so nothing is written through it into another file. A
  symlinked ledger *directory* (`~/.himmel` itself) is still followed.
- An existing backup directory is not tightened to 0700 (only a newly created one
  is); tracked in HIMMEL-3347.
- Hashing uses `sha256sum`, else `shasum -a 256` (`_prov_sha256`; stock macOS has
  only the latter); the node dialect uses its own `crypto`.
- Backup cleanup at `install-end` and the reader that consumes the ledger belong
  to the uninstall slices; these helpers only write.
