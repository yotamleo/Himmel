# GLM offload loop (HIMMEL-654)

Spawn a GLM-lane Claude worker from the main (Fable) session, inspect its
output through files, validate the diff through the normal CR loop, and only
then push. The worker runs against the Z.ai GLM Anthropic-compatible endpoint —
the same flat-rate Coding-Plan lane the `claude-glm` launcher uses — so it
consumes GLM subscription quota, not Anthropic usage cap.

This is the poller-free offload seam: the Telegram bridge already spawns
unattended Anthropic-lane workers with an inspectable file tree; this spike
grafts the GLM lane onto that path via a standalone CLI
(`scripts/telegram/spawn-glm.ts`) with no poller involvement.

## The lane (facts)

- **Coding-Plan key via `ZAI_API_KEY`.** `scripts/telegram/glm-env.ts` resolves
  the key from `process.env.ZAI_API_KEY` first, else the himmel repo `.env`
  (with one surrounding-quote pair stripped, parity with `claude-glm`). Missing
  key → the env builder throws; spawn refuses (no silent Anthropic fallback).
- **Launcher-parity env block.** `buildGlmEnv` emits the block the WS1
  launcher exports (plus the context-diet keys below):

  | Var | Value |
  |---|---|
  | `ANTHROPIC_BASE_URL` | `https://api.z.ai/api/anthropic` |
  | `ANTHROPIC_AUTH_TOKEN` | `<ZAI_API_KEY>` |
  | `ANTHROPIC_MODEL` | `glm-5.2[1m]` |
  | `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `glm-4.7` |
  | `ANTHROPIC_DEFAULT_SONNET_MODEL` | `glm-5.2[1m]` |
  | `ANTHROPIC_DEFAULT_OPUS_MODEL` | `glm-5.2[1m]` |
  | `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `1000000` |

  Divergence from the launcher: `CLAUDE_CONFIG_DIR` is **not** set — the worker
  keeps the operator's `~/.claude` so himmel hooks (`auto-approve-safe-bash`,
  Jira sanction) load. To keep a merged `settings.json` from fighting the env
  block, spawn preflights the user layer (`~/.claude/settings.json`) and the
  checkout layers (`.claude/settings.json`, `.claude/settings.local.json`) and
  **refuses** on any `env.ANTHROPIC_*` or `model` key.
- **Worker context diet (HIMMEL-654).** `buildGlmEnv` additionally
  force-disables the env-gated session-shaping injections —
  `HIMMEL_INITIATIVE`, `HIMMEL_INITIATIVE_OVERNIGHT`, `HIMMEL_OVERNIGHT`,
  `HIMMEL_WHERE_ARE_WE`, `HIMMEL_DOC_FRESHNESS` all `0`,
  `UPDATE_CHECK_DISABLE=1`. Two prompt-too-long deaths showed the injected
  session-start blocks cost context the GLM lane cannot spare, and none is
  meaningful to an unattended worker. The injector hooks read process-env-first
  (the three with a repo-`.env` fallback use non-clobbering `load_dotenv`, so
  the falsy value survives; `check-update-available` reads process env with no
  `.env` fallback), so the falsy values beat an operator-exported gate.
  PreToolUse guard hooks are unaffected — none of them read these
  session-shaping keys; the interactive `claude-glm` launchers deliberately do
  NOT mirror this.
- **The GLM model pin ignores `TELEGRAM_CLAUDE_MODEL`.** GLM runs always pass
  `--model opus`, which maps through `ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2[1m]` —
  a poller-pinned raw Anthropic model id must never leak to the Z.ai endpoint.
- **1M context + configurable window (HIMMEL-718).** The lane defaults to the
  `[1m]` 1M-context GLM variant and sets `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`
  so Claude Code stops auto-compacting/rejecting at the ~200k default (the
  documented "prompt too long" deaths). `spawn-glm --context big|small` (default
  `big`) picks the preset per dispatch: big = `glm-5.2[1m]` + 1M; small = `glm-5.2`
  + 200k. The interactive `claude-glm{,.ps1}` / `claude-routed{,.ps1}` launchers
  expose the same pair as raw env knobs (`GLM_MODEL` / `GLM_CONTEXT_WINDOW`,
  `ROUTED_MODEL` / `ROUTED_CONTEXT_WINDOW`) — override both together; HAIKU stays
  `glm-4.7` (1M is main-only). The routed pilot is GLM-only loopback so `[1m]`
  passes through; if a future deployment routes to a non-GLM backend, override
  both knobs to match that backend's real window.
- **The "per-token blocked" decision applies to the ROUTER only, not this lane.**
  That decision gates the WS2 OmniRoute router (a proxy may not terminate the
  Coding-Plan key per Z.ai ToS). Direct claude-CLI use of the Coding-Plan key —
  what this loop does — is the same posture as the shipped `claude-glm` launcher
  and is **not** blocked. The framing is "keep working on flat-rate quota",
  never "cheaper per-token".

## The loop: spawn → inspect → validate → push-by-validator

1. **Spawn** — from the main session (or any shell), run the CLI (below). It
   creates a fresh git worktree + `glm/<slug>` branch, guard-checks the
   worktree cwd, and starts an unattended GLM-lane worker on your task.
   Before relying on the deny-hook, confirm it is LIVE: `bash
   scripts/himmel-update.sh --plugins-check` reports the installed plugin has
   the entry, AND the parent checkout has pulled the merge (see Hardening).
2. **Inspect** — via files, no interaction with the worker. While running:
   `meta.json` status + the worker-appended `outbox.jsonl` / `context.md`.
   After exit: those plus `run.log` (stdout/stderr tail, post-exit only —
   `runSession` buffers the stream and resolves at process exit) and the exit
   code. The three printed paths are the inspect contract.
3. **Validate** — the worker's output lands as local commits on the
   `glm/<slug>` branch. The main session reviews the diff through the existing
   CR loop before anything is pushed.
4. **Push by validator** — the push is performed by the operator, or by the
   validating session only under an operator authorization given in that
   session. GLM output is merge-quarantined until the WS4/WS7 gates cover the
   lane; the interim bound is human/Fable CR review of every GLM diff.

## CLI synopsis + three-line output contract

```
bun scripts/telegram/spawn-glm.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--timeout-mins <n>] [--permission-mode <mode>] [--context big|small]
```

- `--cwd <dir>` — worktree parent; **must be a himmel checkout** (v1 scope:
  himmel repo only; a non-himmel cwd exits 2). Defaults to the process cwd.
- `--name <slug>` — session slug; sanitized to `[a-zA-Z0-9-]`. Drives the
  branch (`glm/<slug>`), the worktree (`<cwd>/.claude/worktrees/glm+<slug>`),
  and the session dir name. Defaults to `t<timestamp>`.
- `--timeout-mins <n>` — overrides the inherited 30-min run timeout.
- `--permission-mode <mode>` — passed through to the worker (see below).

**Session dir:** `<BRIDGE_ROOT>/glm-sessions/glm-<slug>-<ts>/`, where
`BRIDGE_ROOT` defaults to `~/.claude/handover/bridge`. This lives **outside**
the poller's `<root>/sessions/` tree, so the live poller never scans, adopts,
or Telegram-flushes it. The dir holds a minimal `meta.json`
(`{status, pid, started_at, exit_code, lane: "glm", task_name}`, transitioned
`running → done|failed|capped|blocked` by spawn-glm) and the spawn-glm-written
`run.log` (the stdout/stderr tail, persisted post-exit — NOT worker-written),
plus the worker-appended `outbox.jsonl` and `context.md`.

On exit the CLI prints exactly three machine-readable lines — the inspect
contract for the caller:

```
session-dir: <abs path to glm-sessions/glm-<slug>-<ts>/>
transcript-dir: <abs path to ~/.claude/projects/<escaped-worktree-path>/>
exit: <code>
```

`transcript-dir:` is keyed by the **escaped worktree cwd** (every
non-alphanumeric char → `-`), not by `--name` — that is where Claude Code
writes the session transcript JSONL, which records the server-reported `model`
field used to prove the run hit the `glm-*` backend.

**Exit codes:** `2` = a usage error (missing prompt, a bad flag — e.g. a
non-positive/non-numeric `--timeout-mins` or a value-taking flag with no value)
or a plan refusal (non-himmel cwd, a settings conflict, **or a missing ZAI key**
caught by the pre-side-effect preflight); `3` = a D2 guard refusal (PHI marker,
phi-root, denylist, or unreadable guard config); `1` = an operational failure
surfaced by `main()`'s catch (e.g. `git worktree add` failed) — one
`spawn-glm: <message>` line, no stack. Otherwise the CLI exits with the worker's
own exit code.

The ZAI key is **preflighted before any side effect** (before `git worktree
add`): a missing key is a clean exit-2 refusal, never a failure *after* the
worktree, branch, and `running` meta already exist (which would orphan them and
leave a stuck `running` meta).

## Worker prompt contract

`composeWorkerPrompt` (in `spawn-glm.ts`) prepends this preamble to every GLM
worker prompt, with the minted session-dir `outbox.jsonl` / `context.md`
absolute paths and the `glm/<slug>` branch substituted in — the caller cannot
know these paths, they are minted at spawn time:

```
You are an unattended GLM-lane worker session (himmel offload spike).
Work ONLY inside your current directory (a dedicated git worktree). Commit your work on the branch <branch> which is already checked out.
HARD RULES: never push, never open a PR — a validating session reviews your branch and owns the git/PR surface. Jira updates (status, comments, followup tickets) ARE allowed via node scripts/jira/dist/index.js (audited + recoverable).
Report progress by APPENDING one JSON line {"text":"<note>"} per update to <sessionDir>/outbox.jsonl. That is the only channel to the operator.
THE TASK: <task>
As your FINAL action, append a one-line summary of what you did to <sessionDir>/context.md, then stop.
```

## Permission guidance

`--permission-mode` is caller-chosen and passed straight through to the worker.

- **`bypassPermissions` — recommended for unattended acceptance.** The worker
  runs with stdin closed (EOF), so it cannot answer an interactive permission
  prompt. `bypassPermissions` lets it do its file-and-commit work without
  stalling. It is defensible here because the worktree push block is mechanical,
  the cwd is guard-checked, and the bridge already runs vault sessions this way.
- **Default (unset) MAY deadlock until the timeout.** With no
  `--permission-mode`, the worker inherits the operator default and, being
  stdin-closed, stalls on the first tool the `auto-approve-safe-bash` hook
  doesn't grant — hanging until the 30-min (or `--timeout-mins`) timeout, which
  then shows as `meta.json` status + `run.log`. That is the caller's tradeoff.

> **Impl-time check (SC6, Task 6 fills):** whether `auto-approve-safe-bash`
> covers the worker's own git ops (`checkout -b` / `add` / `commit`) determines
> whether the default (unset) mode is viable at all or whether the worker
> deadlocks on its first commit. Recorded in the acceptance section below once
> observed.

## Batch fan-out: N independent fixes → N GLM workers (HIMMEL-558)

The single-worker loop above is the primitive; this is the orchestration pattern
for a **multi-fix batch** — several independent, mechanical-to-moderate fixes
that would otherwise run serially on the main (Fable/Claude) thread. Fan them to
the flat-rate GLM lane and keep the main thread on the judgment + git surface
only. (This is distinct from `/overnight-shift`, which fans **Anthropic**
subagents and burns Anthropic quota — this lane is flat-rate GLM.)

**When it applies.** The batch's items must be *independent* (no item needs
another's result) and *mechanical-to-moderate* (a GLM worker can complete each
without cross-item judgment). A tightly-coupled set, or one that needs live
end-to-end verification the main thread must watch (e.g. an A/B against a paid
model), stays on the main thread — split the batch: fan the independent
mechanical items, keep the coupled/verify-heavy ones inline. (Worked
counter-example: HIMMEL-558's three CR fixes looked like a fan-out batch, but
1.1 needed a live codex A/B and 1.2's understanding fed 1.1 — a legitimate
inline exception. The mechanical tail, e.g. the doc-only 1.3, was fan-able.)

**The division of labour (single-writer at the git surface):**

- **GLM workers** (many, parallel) — one `spawn-glm` per fix, each on its own
  `glm/<slug>` worktree+branch. They edit + commit + (optionally) update Jira.
  They **never** push, PR, or merge (the worker prompt contract + tripwire).
- **Main thread** (one writer) — owns everything the workers are fenced from:
  1. **CR** — run the critic panel + reviewers over each worker's `glm/<slug>`
     diff (the parent CR gate is the load-bearing control; §Honest enforcement).
     Fix findings inline or bounce the item back with a follow-up spawn.
  2. **Ship rails** — attestation trailers in the first commit, the pre-push
     CR-marker, `gh pr create` only after a clean `/pr-check`. Workers produce
     branches; the main thread turns each into a shipped PR.
  3. **Fork-mirror** — `scripts/propagate-public.sh prep` per merged fix (code
     only; private paths auto-excluded).
  4. **Ledger recalc** — the CR ledger append (`ledger-append.sh`; the
     `cr-scores.sh` scorecard only *reads* it) runs on the main thread
     (single-writer), guarded by the auto-mode classifier. Never fan a ledger
     write into a worker.

**Fan-out sketch** (one worker per independent fix; inspect by files, gate on
the main thread):

```bash
# main thread: fan the independent items
for slug in fixA fixB fixC; do
  bun scripts/telegram/spawn-glm.ts "$(cat prompts/$slug.md)" \
      --name "$slug" --permission-mode bypassPermissions &
done
wait   # each prints its 3-line inspect contract (session-dir / transcript-dir / exit)

# then, per worker branch, SERIALLY on the main thread (single-writer git surface):
#   1. inspect meta.json + outbox.jsonl + run.log
#   2. review glm/<slug> diff through the CR loop  → fix findings
#   3. attestation-commit → push → /pr-check → gh pr create → merge
#   4. propagate-public prep → operator/validator ships
#   5. CR ledger append (ledger-append.sh, main thread only; cr-scores.sh reads)
```

**Concurrency bound.** Keep the parallel worker count modest — every worker
shares the operator's `~/.claude` and one GLM 5h cycle (§Cap guard); the
preflight usage warn is per-spawn, so a large fan-out can drain the cycle
mid-batch. Prefer off-peak (§Peak-hours) for big batches. The main-thread CR +
ship steps are serial regardless (single-writer), so the worker count is bounded
by GLM quota + review throughput, not by parallel git.

**Merge-quarantine still holds.** No GLM branch merges except via the main
thread's CR gate; the batch pattern does not relax that — it just parallelizes
the *authoring*, not the *shipping*.

## Cap guard (HIMMEL-654)

z.ai bills the GLM lane on a **5-hour usage cycle**: once the cycle's token
quota is spent the endpoint returns HTTP 429 (`Usage limit reached for the past
5 hours`), and every subsequent call 429s until the cycle resets (~5h out).
spawn-glm detects that, labels the run honestly in `meta.json`, and — by
default — arms a resume at the reset so the work continues without an operator
nudge.

**`meta.json` terminal states.** A run settles to exactly one of `done`,
`failed`, `capped`, `blocked`, `timeout` (set by `finalMeta`; precedence
`capped > blocked > timeout > (code===0 ? done : failed)`). A capped run also
carries `timed_out`, and the cap guard adds three fields:

- `cap_window` — `5h` | `long` | `generic` (how `detectGlmCap` classified the tail).
- `resume_at` — ISO timestamp the cap reset was armed at (absent on long-window caps).
- `cap_source` — `monitor-endpoint` | `error-body` | `cycle-floor` (which
  `computeResumeAt` source supplied `resume_at`), or `no-arm-long-window`.

**5h/generic arm vs long-window no-arm.** A `5h` or `generic` cap arms a
resume at the cycle reset. A `long` cap (7-day / weekly / balance / plan-expired)
is labeled but **not** auto-armed — `arm-resume.sh` takes a local `HH:MM` and
resolves only the *next* future occurrence within ~24h, so a reset days or
weeks out can't be expressed by the armer; those need manual recovery after the
documented reset. `computeResumeAt` clamps candidates to `[now+2min, now+24h]`
and falls through monitor → error-body → cycle-floor.

**Flags.** `--arm-on-cap` (default) / `--no-arm-on-cap` controls whether a 5h/
generic cap arms the resume. With `--no-arm-on-cap`, `resume_at` is still
written to `meta.json` (a breadcrumb for manual recovery); only the armer is
skipped.

**Preflight usage warn.** Before spawning, spawn-glm reads the cycle usage from
the (reverse-engineered) monitor endpoint and warns if it is at/above
`GLM_USAGE_WARN_PCT` (default `80`): `WARNING — GLM 5h cycle NN% used … resets
HH:MM local`. It is **warn-only** — a heuristic-threshold refusal would strand
work on a miscount. If the endpoint is unreachable / the schema has drifted /
the key is blank, the warn is the visible-invisible line `usage invisible
(monitor endpoint unavailable)` (HIMMEL-275: invisible usage must be
visible-invisible, never silently absent). `fetchGlmUsage` returns `null` on
any failure and never throws.

**Premise captures.** The endpoint shapes (error envelope, the CLI tail, the
monitor schema) were verified live and promoted to
[`tests/fixtures/glm-cap/README.md`](../tests/fixtures/glm-cap/README.md) — the
verdicts there ground the sentinel substrings and the `percentage`-is-used
polarity.

## Honest enforcement inventory

**A tripwire, not a wall.** In the worker's worktree, spawn-glm enables
`extensions.worktreeConfig` and sets a worktree-scoped invalid push URL
(`remote.origin.pushurl=DISABLED-glm-quarantine`), so a bare `git push` — and
with it the normal `gh pr create` path — fails loudly. This blocks
**accidental / default-path** pushes only. It is **not** a containment wall:

- A `bypassPermissions` worker could push via an explicit URL or unset the
  config, and it inherits the operator's git credentials via the shared
  `~/.claude`.
- Other external writes are **prompt-forbidden only** (the worker contract
  above), not mechanically blocked. (Jira is now operator-*allowed* on-lane —
  audited + recoverable; see the Hardening section.)

**The load-bearing control is the CR gate.** No GLM-produced branch is
pushed or merged except by the validating session after the CR loop. The
interim posture is: *default-push tripwired + prompt-requested +
human/Fable-CR-gated*. The hard per-lane bound arrives with the WS4/WS7 gates.

Side effect, documented: `extensions.worktreeConfig` is a **repo-global** toggle
on himmel's shared `.git/config` (it enables per-worktree config resolution
repo-wide and persists after the worktree is removed). Benign for himmel's
existing worktrees (none carry worktree-scoped config); left permanent.

The D2 egress guards (`glm-guard.ts`) are **dormant-by-construction in v1**:
with the himmel-worktree cwd scope they can realistically fire only if the
himmel tree itself is listed in `~/.config/claude-glm/{phi-roots,egress-denylist}`.
They ship now (fail-closed, no `--force` on this path) because the vault
follow-up is the next step and investigation blocker (b) mandates them on any
env-only spawn path — do not weight them as a live v1 safety control.

## Hardening: the deny-hook (HIMMEL-654 harden-first, HIMMEL-675)

`scripts/hooks/block-glm-external-writes.sh` adds a deterministic in-session
layer — the classifier substitute the GLM lane otherwise lacks (third-party
lanes have no auto-mode classifier, and `bypassPermissions` removes the prompt
layer). It fires on `Bash|PowerShell|mcp__.*`, detects the lane by
`ANTHROPIC_BASE_URL` containing `api.z.ai`, and on-lane hard-blocks `git push`,
remote-URL rewrites, the `gh` CLI EXCEPT the issue-ops + pr/run-reads carve-out
below (`gh pr create/merge/edit/review/comment/ready`, `gh api`, `gh repo`,
`gh release`, `gh gist`, … stay blocked), network CLIs
(`curl`/`wget`/`Invoke-WebRequest`/`Invoke-RestMethod`, plus the `iwr`/`irm`
aliases), and all `mcp__*` tools EXCEPT the qmd KB carve-out.
Off-lane sessions exit immediately.

**Allowed on-lane (operator policy 2026-07-03 — audited-action carve-out):**
the **Jira CLI** (`node scripts/jira/dist/index.js …` or bare `jira`) — writes
are audited in Jira history and recoverable, so GLM workers may update status,
add comments, and file followup tickets; **qmd KB reads**
(`mcp__plugin_qmd_qmd__*`); and (HIMMEL-675) **`gh issue <anything>`** — the
full issue surface, reads AND writes, because cr-deferred followups are gh
issues (audited in GitHub + recoverable) — plus read-only **PR/CI context**
(`gh pr view|diff|checks|status|list`, `gh run view|list|watch`). The gh
carve-out is compound-smuggle-safe: the hook counts command-position gh
occurrences vs allowed ones, so `gh pr view 1 && gh pr merge 1` still denies
(total 2 > allowed 1). Atlassian MCP stays blocked (Jira routing is
CLI-first — `block-backend-tier` enforces that in every session), and the
obsidian-vault MCP stays blocked (vault offload is the v2 follow-up).

**The guard stack is now three layers:**

1. **deny-hook** (this hook) — deterministic, in-session, blocks the write
   shapes above before they run.
2. **poisoned pushurl tripwire** — the worktree-scoped invalid `pushurl` that
   fails a default-path `git push`.
3. **parent-session CR gate** — no GLM branch is pushed/merged except by the
   validating session after the CR loop.

The deny-hook is an accidental-shape guard (like `block-read-secrets`), NOT a
containment wall. **Layers 2 and 3 (tripwire + CR gate) remain the load-bearing
backstops**; the hook is the added deterministic in-session layer, not a
replacement for them.

**When the hook is actually LIVE — BOTH conditions must hold** (merging the PR
is not enough):

1. The **installed** plugin has the new entry — that happens only after
   `/himmel-update` (marketplace re-sync). Verify with
   `bash scripts/himmel-update.sh --plugins-check`.
2. The checkout that `spawn-glm` runs from contains the merged script — workers
   `git worktree add` from the **parent checkout's HEAD** (not "main"), so the
   operator's checkout must have pulled the merge.

**A hooks.json change ships live only with a plugin VERSION BUMP.** The
installed-plugin cache is **version-keyed**
(`~/.claude/plugins/cache/…/himmel-ops/<version>/`), so a same-version
`hooks.json` edit is invisible to `/himmel-update`'s re-sync — the cache never
refreshes and the new/changed hook never reaches workers. #856 added a
`hooks.json` entry without bumping `himmel-ops`'s `version`, which is exactly
why the deny-hook did not go live until the HIMMEL-675 `0.4.0` bump. Bump the
plugin `version` in `.claude-plugin/plugin.json` whenever you change its
`hooks.json`.

Until BOTH hold, the lane is unhardened and the low-blast-radius "chores only"
restriction stays.

**Interactive `claude-glm` caveat:** the hook covers `claude-glm` sessions only
when the cwd is a himmel checkout AND its separate seeded `CLAUDE_CONFIG_DIR`
(`~/.claude-glm`) has been re-seeded post-merge (`claude-glm --reseed` —
`/himmel-update` does not refresh it). With a vault cwd the `[ -f ]` plugin
wrapper no-ops. spawn-glm workers (himmel worktrees, shared `~/.claude`) are the
covered target.

**Bypass:** `GLM_EXTERNAL_WRITES_OK=1` set in the shell that spawns the worker
(session-sticky; a per-call prefix does not reach the hook).

**Known limitations** (tripwire + CR-gate backstopped): a wrapper that displaces
the command from command position is missed — env-prefixed `FOO=1 git push`,
`sudo`/`xargs`/`timeout` wrappers, the dashed `git-push` form, and the
`=`-joined global-flag form `git --git-dir=/x push`; malformed or empty tool
JSON is allowed through (parity with sibling hooks — Claude Code emits valid
JSON); and in-process network is invisible to a command-text hook — bun/node
`fetch`, INCLUDING `bun`-invoking the Telegram bridge send path
(`scripts/telegram/telegram-api.ts` sendMessage, a real external write).

## Escalation channel (HIMMEL-654)

A blocked GLM worker can record a capability request and **degrade gracefully**
instead of retrying into the deny wall; a parent/operator grants a specific,
TTL- and use-bounded command shape; the deny-hook honors that grant on that arm
only. All state is a per-session append-only ledger
`${GLM_SESSION_DIR}/grants.jsonl` (exported into the worker child env by
`spawn-glm`), with three line types:

- **`grant`** — `{type,grant_id,arm,pattern,shape,expires_at,max_uses,granted_by,ts}`.
  `arm ∈ {git-push, git-url, gh, network}`; `pattern` is an anchored ERE the hook
  folds into that arm's allowed count; `shape` (`read`/`write`) is classified from
  the capability.
- **`consumption`** — `{type,grant_id,ts}`, APPENDED by the hook once per honored
  use. The hook never rewrites an existing line; a grant is exhausted when its
  consumption count reaches `max_uses`.
- **`escalation`** — `{type,capability,arm,reason,step,ts}`, appended by the
  worker (to its `outbox.jsonl`) when a step is hard-blocked: it records the
  request, SKIPS the step, continues the rest of the task, and notes the skip in
  its final summary (the record-and-degrade contract, taught in the worker
  preamble).

**Pre-seed (`spawn-glm`):** `--grant '<arm>|<pattern>|<ttl_mins?>|<max_uses?>'`
(repeatable; `ttl` default 60, `uses` default 1) writes grant lines before the
worker starts. `--autonomous` (also implied by `HIMMEL_OVERNIGHT`) applies a
read-only authority gate: a **write**-shaped grant is refused and recorded as a
pending `escalation` (operator adjudication required) rather than granted; a
**read**-shaped grant is written.

**Adjudicate (`adjudicate.ts`, lean-invoke):**
`adjudicate list` surfaces unresolved escalations across all sessions;
`adjudicate grant <sessionDir> --arm <a> --pattern <re> [--ttl m] [--uses n] [--autonomous]`
appends a grant (same authority gate); `adjudicate refuse <sessionDir> <index>`
appends a `refusal` that clears an escalation from `list`. Single-writer: the
parent/operator is the sole adjudicator per session; workers only append
escalation lines.

**Hook mechanics + honest bound.** The deny-hook consults grants only when an
arm exceeds its builtin allowance (a builtin-allowed command takes a fast path
and never reads the ledger). A valid grant's pattern is folded into that ONE
arm's allowed count as a **single alternation** (never a sum — an
overlap-with-a-sibling grant cannot credit a different command), gated by a
strict validity check (arm enum, per-arm deny-shape anchor, no unbounded
`.*`/`.+` prefix) and bounded by TTL (ISO lexicographic expiry) and remaining
uses. Everything is **fail-closed**: an unset/absent ledger, or any malformed /
mis-anchored / expired / exhausted grant line, leaves the arm denying. Like the
deny-hook itself, this is an **accidental-shape guard for a same-user worker**,
not a containment wall — the load-bearing controls remain the poisoned-pushurl
tripwire and the parent CR gate.

## Peak-hours & quota windows (lane scheduling, HIMMEL-654 decision #4)

Time-aware routing facts for the three worker lanes, researched 2026-07-03
(vault-first + official docs; verify the time-boxed items before relying on
them past their dates).

| Lane | Quota model | Window / reset | Peak / degraded hours | Best offload hours | Confidence |
|---|---|---|---|---|---|
| **GLM** (z.ai Coding Plan) | Prompts per **5-hour rolling cycle** (Pro ≈ 400/5h; Lite ≈ 80; Max ≈ 1600) — NOT a daily bank. Advanced models burn quota by a **time-of-day multiplier**. | 5h cycle starts at first prompt. | **14:00–18:00 UTC+8** (= 08:00–12:00 Berlin summer) → **3× quota burn**. Documented effect is COST, not latency. | Outside the peak window; under the off-peak **1× promo (through Sept 2026, then 2×)** it is the cheapest bulk lane in the fleet. | Multiplier: official. Latency-at-peak: unconfirmed. |
| **Claude** (Anthropic Max) | **5-hour rolling window + weekly (`seven_day`) cap**, usage-metered; Opus drains faster. | 5h window from first message; weekly is the harder ceiling. Live counters: `api.anthropic.com/api/oauth/usage` (cached `/tmp/claude/statusline-usage-cache.json`). | **No clock-based peak** — degradation is depletion-based. | Route by counter (`five_hour`/`seven_day` utilization), not clock; arm-resume handles reset boundaries. | High (official mechanics). |
| **Codex** (OpenAI) | Two windows: primary **300 min** + secondary **10080 min (weekly)** — the weekly is the real cap. Separate OpenAI bank (independent of Claude quota). | Rolling windows that fully reset. Local pull: grep `~/.codex/logs_2.sqlite*` for `"secondary"`/`used_percent` (freshest in `-wal`). | **No published clock peak**; OpenAI throttles dynamically under aggregate load. | Route by the weekly `used_percent` counter; primary overflow lane when Claude's weekly cap is spent. | Windows: high. Reset anchor detail: community-sourced. |

Routing rules:

1. **GLM bulk/mechanical chores → off-peak** (avoid 14:00–18:00 UTC+8). The
   3× peak multiplier drains the 5h cycle ~1.5× faster than off-peak 2× — and
   the promo makes off-peak 1×, so schedule big fanout jobs there.
2. **GLM peak is a cost penalty, not a wall** — small urgent GLM jobs are fine
   at peak; only defer bulk work.
3. **Claude and Codex have no clock to schedule against** — treat
   "peak/degraded" as "depletion counter is high" and route by the live
   counters above.
4. **Overflow order when Claude's weekly cap is spent:** Codex first for
   judgment-capable work (independent bank); GLM off-peak for bulk/mechanical
   (capacity lane, not a behavioral equal — keep judgment-heavy work off GLM).
5. **All three 5h windows anchor at first prompt** — start a bulk GLM run
   early enough to finish before the peak window opens, or after it closes.
6. **The GLM peak is z.ai-fixed at UTC+8** — it does not track local DST;
   re-derive the local mapping at DST switches.

## Acceptance runs (2026-07-03, session 9 — both PASS)

- **Step 0 (refusal smoke):** `spawn-glm "noop" --cwd $TEMP` → exit 2,
  `not a himmel checkout` reason line. planSpawn→main wiring proven.
- **SC2 (lane verification), `glm-accept1-1783083791161`:** worker exited 0;
  three-line contract held; transcript JSONL server-reported `"model":"glm-5.2"`
  ONLY (the deterministic lane proof — endpoint-stamped, not a self-report);
  outbox carried the model statement + an accurate 3-bullet token-economy
  summary; `meta.json` transitioned running→done; `run.log` 1.3 KB.
- **SC3 (offload loop), `glm-accept2-1783083993089`:** worker appended the
  acceptance line to its copy of this doc and committed `eb18594b` on
  `glm/accept2` (+2 docs lines, exactly as instructed); a bare `git push
  origin HEAD` from the worker worktree FAILED on the poisoned pushurl
  (tripwire observed); transcript again `glm-5.2` only (24 stamped
  messages); outbox note honest ("Not pushed, no PR, no Jira"). The
  validating session reviewed the diff; push withheld (scratch branch,
  cleaned up post-acceptance).
- **SC6 (auto-approve coverage):** both live runs used
  `--permission-mode bypassPermissions`, so `auto-approve-safe-bash`
  coverage of the worker's git ops was NOT exercised — unknown, not
  proven. Default-mode guidance stands: expect possible deadlock-until-
  timeout on unapproved tools; prefer bypassPermissions for unattended
  runs (tripwire + guard-checked cwd are the compensating controls).
- **Execution-time findings folded back into the code:** settings `model`
  key → warning not refusal (`2135712e`); `.env` resolution falls back to
  the main checkout via `git rev-parse --git-common-dir` when running from
  a worktree (`7a2fbb6e`); `main()` failures now print one clean line.
  Known rough edge (followup): a failed run leaves its `glm/<slug>`
  worktree+branch behind — rerunning the same `--name` needs a manual
  `git worktree remove` + `branch -D` first.
