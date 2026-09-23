# Headless modes: `claude -p` vs `claude --bg` vs headed (HIMMEL-3410)

Two headless invocation shapes exist in this repo, plus the headed (konsole
+ TTY) shape legs still default to. They are not interchangeable — each
suits a different failure mode, and collapsing everything onto one of them
either burns bank on a session nobody watches or blocks a script waiting on
a TTY that never attaches. This doc picks the mode per job; the billing
facts themselves (same bank, no separate bucket) live in
[`enforcement.md` "Claude invocation billing"](enforcement.md#claude-invocation-billing-himmel-128)
and are not restated here.

## Decision table

| Job shape | Mode | Why |
|---|---|---|
| One-shot scripted call, output parsed as JSON, a cron/pipeline step, a CI-adjacent check | `claude -p` | Exits when the turn budget or the prompt is exhausted; nothing is left running to confirm, track or clean up later. |
| A long-lived leg session that needs cross-session `SendMessage`, survives operator idle time, or must show up in `claude agents --json` / the fleet UI | `claude --bg` | `-p` has no inbox and no idle-survival story — it is a single invocation, not a session. |
| Anything that genuinely needs a live TTY (an interactive prompt, a console session an operator is watching) | headed (konsole) | A session launched without a TTY exits at the first idle cross-session message ([`headed-arm-leg.sh` HIMMEL-3403 docstring](../../scripts/handover/console-kit/headed-arm-leg.sh) — see the `--headless` comment block); headed is the only shape where that isn't a problem because a human is attached. |

## `claude -p`

**Chokepoint:** every scripted `-p` dispatch in this repo is meant to go
through `scripts/lib/claude-headless.sh` ("the P1 chokepoint wrapper for
`claude -p` dispatch", HIMMEL-2178) rather than shelling out to `claude -p`
directly — one invocation site to audit instead of many
(`scripts/lib/claude-headless.sh:1-20`).

- **Env inheritance:** runs as a normal child process of the calling shell —
  it inherits that shell's environment the ordinary way. No daemon, no
  per-session settings-file merge.
- **Permission mode:** `--permission-mode` is a required flag on the wrapper
  (`claude-headless.sh:100`) and `bypassPermissions` is refused outright
  (`claude-headless.sh:100`, `die "--permission-mode bypassPermissions is
  refused"`); a direct (non-wrapper) `-p` call site declares it explicitly
  the same way, per the `no-headless-claude` gate below.
- **Billing:** same 5-hour/weekly bank as interactive use — see
  [enforcement.md](enforcement.md#claude-invocation-billing-himmel-128).
  `claude-headless.sh` calls `scripts/lib/bank-preflight.sh` before
  dispatching and refuses on a non-`PROCEED` verdict
  (`claude-headless.sh:299-300`).
- **Confirm / dedup:** the wrapper never trusts `rc` — a denied tool call can
  still exit 0 (`claude-headless.sh:11-13`), so the verdict comes from the
  caller-declared `--artifact` path checked for a *fresh* mtime after exit
  (`claude-headless.sh:311-340`, the `artifact_mtime` staleness comparison).
  Concurrency is capped by `HIMMEL_DISPATCH_MAX_CONCURRENT` (default 3) and
  every dispatch is recorded as a row in a file-per-session registry at
  `$HOME/.himmel/registry/live/<id>.json` (`claude-headless.sh:346-364`,
  header comment "Registry:" at line ~19).
- **Fleet UI:** `fleet.mjs` models one row per *leg* — a handover doc, a
  queue lock, a session name (`console-kit/fleet.mjs:1-5, 427-444`). A `-p`
  dispatch has none of those; it is a short-lived subprocess the wrapper
  itself tracks via the registry above, not a fleet row. **Unverified**:
  this is inferred from fleet.mjs's field model, not from an explicit
  "`-p` dispatches are excluded" statement in the source.

## `claude --bg`

Added by HIMMEL-3403 as `headed-arm-leg.sh --headless` (or `LEG_HEADLESS=1`
in the launching shell; the flag wins) — same profile injection, model and
`--autocompact 200000` pin as a headed leg, but no konsole
(`headed-arm-leg.sh:40-45` docstring).

- **Env inheritance:** the background session runs under the `claude`
  daemon and inherits *the daemon's* environment, not the launching shell's
  (`headed-arm-leg.sh:388-390`). `headed-arm.sh`'s `headless_launch` compensates
  by writing every leg-shaped env var into the per-leg `settings.json`
  `.env` block before launch (`headed-arm.sh:1008-1062`), forcing
  `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` (`headed-arm.sh:1017`), and
  refusing to launch blind if it can't read the daemon's own `/proc/<pid>/environ`
  (`headed-arm.sh:1037-1049`). `--headless` therefore requires a profile —
  `--no-profile` is refused (`headed-arm-leg.sh:396`) — and is native-lane
  only (`headed-arm-leg.sh:401`).
- **Permission mode:** declared explicitly as `--permission-mode auto`
  (`headed-arm.sh:574`), matching what a headed leg runs under by default
  (comment at `headed-arm.sh:570-573`), never `bypassPermissions`.
- **Billing:** same bank as `-p` and headed — HIMMEL-3410's own ticket body
  and [enforcement.md](enforcement.md#claude-invocation-billing-himmel-128)
  agree there is no separate bucket. The call site carries its own
  `# headless-claude-ok: HIMMEL-3403 console-armed leg; headed-arm-leg.sh ran
  the bank/fleet preflight` marker (`headed-arm.sh:573`).
- **Confirm / dedup:** after launch, `headed-arm.sh` polls
  `$CLAUDE_CLI agents --json` for up to 20s (100 × 0.2s) waiting for the new
  session name to appear, and fails closed with `UNCONFIRMED` (exit 7) if it
  never does (`headed-arm.sh:1071-1079`) — exit 0 from the launch call alone
  is not treated as proof the session exists. On success it writes a launch
  log line `headless=1 pid=... session-id=... short-id=... settings=... argv=...`
  (`headed-arm.sh:1084-1091`) that both the console and the fleet UI read.
  Ending one: `kill <pid>` (the `pid=` in that log line, or from
  `claude agents --json`), then `claude rm <short-id>`
  (`headed-arm-leg.sh:44-45`).
- **Fleet UI:** `fleet.mjs` derives `mode = 'headless'` from any of: the
  agents census showing the session running, the launch log's `headless=1`,
  or the process argv containing `--bg`/`--background`
  (`console-kit/fleet.mjs:437-444`), and renders it in the per-leg row
  (`console-kit/fleet.mjs:605`). Built by the sibling ticket HIMMEL-3404
  specifically because headless legs have no konsole window for an operator
  to see (`fleet.mjs:3-5`).

## Headed (konsole)

The default leg shape today: `headed-arm-leg.sh` (no `--headless`) opens a
konsole and runs `claude` interactively inside it, same profile/model/
autocompact pin, same bank/fleet preflight. It is the only mode where a
missing TTY is not a failure mode, because a human (or an attached terminal)
is what the session waits on. Billing and permission-mode requirements are
identical to `--bg` — see the citations above; the difference is entirely in
how the process is launched (konsole vs `--bg`), not in what it costs or
what it's allowed to do.

## Audit: existing `# headless-claude-ok:` sites

Full marker inventory: `git grep -n 'headless-claude-ok:'`. Call sites are
grouped below; markers that are documentation/prohibition notes or test
fixtures (no actual invocation) are not call sites and are omitted from the
"real invocation" table. No call site is changed by this PR — misfits are
flagged only.

### Real invocation sites

| Site | Mode | Job shape | Fit |
|---|---|---|---|
| `scripts/lib/claude-headless.sh:372` (the chokepoint's own `CMD=(... -p ...)`) | `-p` | The one shared dispatch primitive every other `-p` call site below routes through | Fits |
| `scripts/cr/claude-floor-review.sh:189` (via `claude-headless.sh`) | `-p`, `--permission-mode acceptEdits` | CR floor reviewer — one scoped worker call, opt-in fallback when every non-Claude critic is exhausted | Fits |
| `scripts/cr/hermes-critic.sh:333` | `-p`, `--permission-mode plan --max-turns 1` | CR critic pass — one scoped review call | Fits |
| `.claude/commands/plugin-eval.md:63` | `-p` | On-demand `claude plugin eval` run, bank-preflighted | Fits |
| `scripts/codex/hook-smoke-demo.sh:428` | `-p` | Hook-chain smoke demo, bank-gated, one read-only turn | Fits |
| `scripts/lanes/profile-context-probe.mjs:222` | `-p --max-turns 1 --permission-mode dontAsk` | One-shot profile measurement probe | Fits |
| `scripts/probes/claude-p/*.sh` (HIMMEL-2179, ~20 sites) | `-p` | Probes exercising specific `-p` behaviors, named for the mode they test | Fits (probes for `-p` are `-p` calls by construction) |
| `docs/internals/token-economy-bench.md:94` | `-p` (bench recipe) | Operator-run bench recipe in a quiet window | Fits |
| `scripts/graphify/refresh-graph-map.sh:63,393,2106` | Not controlled by these scripts — they configure graphify's `claude-cli` backend, which is graphify's own upstream dispatch code, not a `claude -p`/`--bg` flag visible in this repo | Graphify's intentional CLI dispatch (documented, not this repo's call site) | Out of scope — external tool |
| `scripts/handover/headed-arm.sh:573` | `--bg --permission-mode auto` | Console-armed leg (HIMMEL-3403) | Fits |

No misfits found: every direct `-p` site in this repo is a one-shot,
bank-preflighted, artifact-checked scripted/CI-shaped call, and the one
`--bg` site is the long-lived, fleet-visible leg launcher — exactly the
split this doc's decision table describes.

### Non-invocation markers (excluded above)

Documentation/prohibition notes that mention the ban without invoking
`claude`: `marketplace/plugins/obsidian-triage/commands/{archive-clips,deepen-subject,harvest-clips,migrate-clip-lifecycle,synthesize-stubs}.md`,
`marketplace/plugins/obsidian-triage/skills/{grow-feed-log,telegram-clip}/SKILL.md`,
`marketplace/plugins/obsidian-triage/tests/{test-archive-clips,test-harvest-clips}.sh`
(detection-pattern comments, not invocations), `scripts/guardrails/lint-fail-open.sh:53`
and `scripts/hooks/block-tail-pipe-on-gates.sh:83` (convention references),
and the gate's own source/tests
(`scripts/hooks/check-no-headless-claude.sh`, `scripts/hooks/test-check-no-headless-claude.sh`,
`scripts/handover/console-kit/test-fleet.sh:126`).
