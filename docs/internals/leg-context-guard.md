# Leg context guard

`scripts/hooks/guard-leg-context-handoff.sh` (HIMMEL-4569, HIMMEL-4710) is the
one reference for what the leg context guard does, when it runs, and how a leg
gets past it. The hook header carries the same facts for whoever edits the code.
Hook wiring and the enforcement matrix are in
[`enforcement.md`](enforcement.md#guard-leg-context-handoffsh--console-spawned-leg-context-hand-off-himmel-4569).

## Purpose

A console-spawned leg auto-compacts at its `--autocompact` ceiling. Compaction
is a backstop and not data loss: 309 of 349 compacted legs still reached
`WRAPPED` (HIMMEL-4089). The guard is there for one job. When a launch wants
uncommitted work pushed **before** that lossy summary, the guard makes the leg
checkpoint, or hand off to a successor, first.

## Off by default

The operator ruled on 2026-10-07 (HIMMEL-4710) that the guard is
**off by default**. A leg launched without a mode never sees it: the hook exits 0 with no
output for every PreToolUse call and every PreCompact, at any fill. Legs
auto-compact anyway, and an always-on guard stopped every opus leg at 13 % fill.

## Turning it on

Pass the mode at launch:

```bash
bash scripts/handover/console-kit/headed-arm-leg.sh --context-guard compact …
bash scripts/handover/console-kit/headed-arm-leg.sh --context-guard handoff …
```

- `--context-guard none` is the default and turns the guard off.
- If no flag is given, a `HIMMEL_LEG_CONTEXT_MODE` in the launching shell is
  used. When both are present, the flag wins.
- The launcher refuses any other value with exit 2.
- The launcher exports the mode only when one is set. The `--dry-run` report
  prints `HIMMEL_LEG_CONTEXT_MODE=<unset>` when the guard is off.

The hook reads the mode only from its own process env, which is fixed at launch.
A leg cannot turn the guard on, off or across modes mid-session: an `export` or
a per-call prefix never reaches a hook process. At the hook, an unset, empty or
`none` mode means off. Any other unknown value is treated as `compact` and
prints one stderr line, because someone asked for the guard.

## The threshold

The threshold is **75 % of the leg's autocompact ceiling**, not 75 % of the
model window.

- **Ceiling.** The ceiling is resolved in this order:
  1. `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, when it is numeric (it outranks the
     flag).
  2. `HIMMEL_LEG_AUTOCOMPACT`, which is the launcher's resolved
     `--autocompact`. Unset means the 200000 pin, and `auto` means the window.

  The result is clamped to the window.
- **Threshold % of the window.** It is `ceil(share × ceiling / window)`.
- **Share.** The share is `HIMMEL_LEG_CONTEXT_SHARE`, from the launch env only.
  Any value other than 1-100 gives 75.

A worked example: an opus leg pinned at `--autocompact 200000` reports a
1000000-token window. Its ceiling is 20 % fill, and 75 % of it is **150000
tokens, which is 15 % fill**.

**Why 75 %.** Compactions have been observed firing from **157k** of a 200k
ceiling (HIMMEL-4089: 157k-176k over 349 compactions). At 75 %, the leg has
7000 tokens (3.5 pp of the ceiling) before the earliest compaction to commit,
push and write the CHECKPOINT bullet.

The deny must land before the earliest compaction. A higher share, such as
85 % (170000), would let a compaction fire first and then be refused blind. The
earlier 65 % (130000) left 27000 tokens of room but stopped every opus leg at
13 % fill. If a leg needs more headroom than 7000 tokens, raise the launcher
ceiling; that is an operator decision.

## The autocompact A/B arm (HIMMEL-5193)

The 200000 ceiling is the default for every leg. A measured A/B against 400000
is opt-in and audited:

- **Launch.** `LEG_AUTOCOMPACT_AB=400000` (only `200000` or `400000`; anything
  else refuses) on `headed-arm-leg.sh`, with the brief line
  `> **Context:** ab-400k — operator-ruling: HIMMEL-5193`. It needs the standard
  context and is refused with `LEG_CONTEXT=1m`. `200000` is the control arm and
  needs no line. `gen-briefs.py` writes both from a per-leg `ab_arm`
  (`200k` | `400k`) key.
- **Threshold.** The launcher exports `HIMMEL_LEG_AUTOCOMPACT=400000`, so the
  guard's 75 % share is 300000 tokens (30 % of a 1000000 window).
- **Record.** The arm goes in the launch log (`ab_arm=`), the arm log line and
  the fleet-manifest entry (`arm`).
- **Report.** `python3 -I scripts/eval/autocompact-ab.py --manifest <fleet.json>`
  prints, per wrapped leg, compactions with the token level at each, handoffs,
  the cache_read / cache_create / uncached split, price-weighted cost,
  wall-clock, PR outcome and mean output tokens per turn, then a per-arm table.
  The arm is the manifest record only (the brief line alone is not evidence);
  one row per `TICKET-N<k>` (`scripts/lib/leg-identity.sh`): a RESUME successor
  folds into its parent's row, the leg is wrapped when the last doc of the
  chain is, and every transcript is counted once. A chain whose listed docs
  carry different manifest arms is `unproven` and left out of the summary. A
  leg with no matching transcript is counted as `unmeasured` and left out of
  the arm means.

## Past the threshold

Past the threshold the hook denies every call except the hand-off calls. These
are allowed:

- A Write, Edit or MultiEdit of a `*-RESUME.md`.
- `SendMessage`, `ListAgents`, `ToolSearch` and `TaskStop`.
- A bare `bash …/append-results.sh`, `queue-lock.sh release`,
  `wrap-subtree-check.sh` or `context-fill.sh`.
- A bare `git [-C <dir>] add|commit|push|status|rev-parse`.
- A bare `cd [<dir>]`.

"Bare" means one command: no newline, no unclosed quote, no `$'…'` quote, no
backtick or `$(`
outside single quotes, and no `&`, `|`, `;`, `<`, `>`, `(` or `)` outside any
quotes. Quoted text keeps them inert, so a bullet or commit message may say
`a; b` inside quotes. Put backticks in single quotes: inside double quotes they
run a command and are refused.

The deny names:

- the mode;
- the fill;
- the threshold and its basis;
- the exact unlock steps;
- the one-line commit form;
- the BLOCKED route.

**The one-line commit form.** A newline in a Bash command is denied, so a
multi-line `git commit -m` cannot run. Use `-m` paragraphs and `--trailer`
instead:

```bash
git commit -m "<subject>" -m "<body>" --trailer "Platforms tested: <os>" --trailer "Security reviewed: <token> - <what>"
```

## Every unlock

| Unlock | Mode | What it frees |
|---|---|---|
| `LIVE — CHECKPOINT <full sha of HEAD> pushed` | compact | everything, while that sha is HEAD and HEAD equals its upstream |
| `LIVE — CHECKPOINT <full sha of HEAD> clean` | compact | everything, while that sha is HEAD, `git status --porcelain` is empty, and nothing is unpushed (HEAD equals its upstream, or HEAD is in `origin/main`) |
| a `*-RESUME.md` beside the leg doc | handoff | everything (the leg then stops) |
| last marker `WRAPPED` | both | everything |
| last marker `BLOCKED` | both | **only the hand-off calls and reads** (Read, Grep, Glob) |

Notes on each unlock:

- **CHECKPOINT bullets.** Write them with `append-results.sh`. Only the newest
  CHECKPOINT bullet counts.
- **The clean form.** It covers a leg with nothing to push: an empty push would
  otherwise leave the pushed form unprovable (N1386).
- **The RESUME doc.** It must carry the leg doc's id (`N1364`, `N1364b` …) with
  any one-letter suffix. It must also have been modified after the session's
  first turn, so an older link of the same chain never counts.
- **BLOCKED.** A `BLOCKED` is a hand-off to the console, not an unlock. N1383
  wrote `BLOCKED` and then kept editing. A leg that cannot commit or push
  should `SendMessage` its console, append a `BLOCKED` bullet and stop.
  While `BLOCKED` is the last marker, an earlier CHECKPOINT or a RESUME doc
  does not reopen ordinary work either. They still let an auto-compaction
  through, because the state is saved.

## The two modes

- **`compact`.** Commit the WIP in the one-line form, `git push`, then append
  `LIVE — CHECKPOINT <full sha of HEAD> pushed` (or `… clean` when there is
  nothing to push). Then carry on. The session compacts at its ceiling. After
  the compaction, re-read the leg preface and the handover doc.
- **`handoff`.** Write `…legN<n>b-…-RESUME.md`, message the console, and stop. A
  successor resumes from that doc.

## PreCompact

The hook is also wired as a PreCompact hook:

- A `manual` `/compact` always passes.
- Below the threshold, an `auto` compaction passes.
- Past the threshold, an `auto` compaction is refused (`{"decision":"block"}`,
  exit 2) until one of these holds:
  - a CHECKPOINT unlock;
  - a RESUME unlock;
  - a last marker of `WRAPPED`.

  A last marker of `BLOCKED` is not an unlock by itself. It lets the
  compaction pass only alongside a CHECKPOINT or RESUME unlock.

Claude Code does not document what follows a refused auto-compaction. This is
why the threshold sits below the earliest observed compaction and the refusal
is only the second line of defence. HIMMEL-4710 item 7 tracks measuring it on a
VM leg.

## Fail-open, scope and bypass

- **Fail-open.** The hook fails open, with one stderr line, on every
  infrastructure gap:
  - fill UNKNOWN or STALE;
  - no transcript;
  - leg doc not found;
  - no `jq`;
  - input that does not parse.

  A false block strands a leg that nobody watches.
- **Scope.** The hook acts only on a console-spawned leg: `HIMMEL_CONSOLE_LEG=1`
  plus a non-empty `HIMMEL_CONSOLE_NAME`. In-process subagents (a non-empty
  `agent_id`) are exempt.
- **Codex.** Codex wires the hook for PreToolUse only. Codex has no PreCompact
  event, and its transcripts carry no claude-hud snapshot, so the hook fails
  open there.
- **Bypass.** Set `LEG_CONTEXT_HANDOFF_OK=1` in the launching shell. A per-call
  prefix does not reach the hook.
