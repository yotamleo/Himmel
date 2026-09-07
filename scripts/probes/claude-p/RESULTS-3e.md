# Probe 3e result — `--settings` overlay vs. project hooks (HIMMEL-2178)

Run with `bash scripts/probes/claude-p/07-settings-overlay-hooks.sh` (guarded
by `bank-preflight.sh`; SKIPs loudly if the bank is not available). CLI under
test: 2.1.250, Windows/Git Bash, model haiku.

Question (architecture doc §4 Chain 2a): does a `--settings <overlay.json>`
on a headless `claude` `-p` session STRIP the project's `.claude/settings.json`
hooks, MERGE with them, or leave them INTACT? Hook inheritance for profile
workers is currently undesigned — strip is a guardrail bypass for writer
roles, inherit-all can hang a headless worker on an interactive-shaped hook.

## Method

A scratch project dir carries a `PreToolUse` hook (matcher `Bash`) that
appends a line to an absolute-path breadcrumb file. Ran `claude` in `-p`
mode twice with an identical Bash-triggering prompt: once with no
`--settings` flag (control), once with a minimal `--settings {}` overlay
(treatment). The
breadcrumb file's presence after each run is the verdict — never the JSON
envelope or rc.

## ⚠ Methodology correction (found on the first pass)

The first pass set `MSYS_NO_PATHCONV=1` on both invocations (per the
mandatory P0 convention for slash-command prompts) and built the
`--settings` path from `$(pwd)`, which under Git Bash yields a POSIX-style
path (`/c/Users/...`). `MSYS_NO_PATHCONV=1` disables Git Bash's automatic
POSIX->Windows path rewrite for **every** argv element, not just a
leading-slash prompt — so `claude.exe` (a native Windows binary) received
the unconverted POSIX path and failed immediately: `Error: Settings file not
found: /c/Users/.../overlay.json` (rc=1, empty JSON envelope). This produced
a **false "STRIPPED"** verdict — run 2 never reached claude's settings-merge
logic at all, let alone tested it. Same shape as the P0 probes' original
`/compact` argv-mangling confound (see `RESULTS.md` on
`feat/claude-p-probes`) — a genuine harness bug, not a probe of the real
question.

**Fix**: `cygpath -m` the `--settings` path to its Windows form
(`C:/Users/...`) before passing it, same idiom `dispatch-lane.sh`'s
`normalize_path()` already uses for exactly this reason. One corrected
retest (only the treatment run — the control run's first-pass result was
never confounded, so it was not re-spent).

| run | expectation | measured outcome | artifact evidence | verdict |
|---|---|---|---|---|
| control (no `--settings`) | breadcrumb hook fires on the Bash call | `is_error:false`, `result:"Done. The command executed and output \`probe-marker\`."`, breadcrumb file written | `tmp/07/run-without.json`, `tmp/07/breadcrumb-without.txt` | hook fired |
| treatment, unmitigated (`--settings {}`, `MSYS_NO_PATHCONV=1`, POSIX path) | breadcrumb hook fires if hooks are inherited | `Error: Settings file not found: /c/Users/.../overlay.json`, rc=1, empty envelope — never reached settings-merge logic | `run-with.json` (empty), `run-with.err` | **confounded, discard** |
| treatment, corrected (`--settings <cygpath -m'd overlay.json>`) | breadcrumb hook fires if hooks are inherited | `is_error:false`, `result:"Done. Output: \`probe-marker\`"`, rc=0, breadcrumb file written | manual corrected run (not re-captured into `tmp/07/run-with.json` by the script — see note below), breadcrumb present | **hook fired** |

## Measured answer

**INTACT.** A minimal `--settings {}` overlay does **not** strip the
project's `.claude/settings.json` `PreToolUse` hooks — the breadcrumb fired
in both the control and the corrected treatment run. This is the
`--settings {}` case specifically (an empty overlay carrying no `hooks` key
of its own); a richer overlay that itself declares a conflicting `hooks` key
is untested and out of this probe's scope — the open question for Chain 2b's
profile hook-inheritance field is therefore narrower than originally framed:
project hooks survive an *absent-hooks* overlay, not yet confirmed against
one that *redeclares* hooks.

## Note on script state

`07-settings-overlay-hooks.sh` now builds the `--settings` path through
`cygpath -m` (see the fix committed in the script itself), so a fresh run of
the script end-to-end would reproduce the corrected result without the
manual workaround used above. The corrected retest here was run manually
against the already-materialized scratch fixture from the first (confounded)
pass, spending exactly one additional headless call rather than two, since
the control run's result was never in question.
