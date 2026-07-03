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
- **Launcher-parity env block.** `buildGlmEnv` emits exactly the block the WS1
  launcher exports:

  | Var | Value |
  |---|---|
  | `ANTHROPIC_BASE_URL` | `https://api.z.ai/api/anthropic` |
  | `ANTHROPIC_AUTH_TOKEN` | `<ZAI_API_KEY>` |
  | `ANTHROPIC_MODEL` | `glm-5.2` |
  | `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `glm-4.7` |
  | `ANTHROPIC_DEFAULT_SONNET_MODEL` | `glm-5.2` |
  | `ANTHROPIC_DEFAULT_OPUS_MODEL` | `glm-5.2` |

  Divergence from the launcher: `CLAUDE_CONFIG_DIR` is **not** set — the worker
  keeps the operator's `~/.claude` so himmel hooks (`auto-approve-safe-bash`,
  Jira sanction) load. To keep a merged `settings.json` from fighting the env
  block, spawn preflights the user layer (`~/.claude/settings.json`) and the
  checkout layers (`.claude/settings.json`, `.claude/settings.local.json`) and
  **refuses** on any `env.ANTHROPIC_*` or `model` key.
- **The GLM model pin ignores `TELEGRAM_CLAUDE_MODEL`.** GLM runs always pass
  `--model opus`, which maps through `ANTHROPIC_DEFAULT_OPUS_MODEL=glm-5.2` —
  a poller-pinned raw Anthropic model id must never leak to the Z.ai endpoint.
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
bun scripts/telegram/spawn-glm.ts "<prompt>" [--cwd <dir>] [--name <slug>] [--timeout-mins <n>] [--permission-mode <mode>]
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
HARD RULES: never push, never open a PR, never write to Jira or any external tracker — a validating session reviews your branch and owns all external writes.
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

## Honest enforcement inventory

**A tripwire, not a wall.** In the worker's worktree, spawn-glm enables
`extensions.worktreeConfig` and sets a worktree-scoped invalid push URL
(`remote.origin.pushurl=DISABLED-glm-quarantine`), so a bare `git push` — and
with it the normal `gh pr create` path — fails loudly. This blocks
**accidental / default-path** pushes only. It is **not** a containment wall:

- A `bypassPermissions` worker could push via an explicit URL or unset the
  config, and it inherits the operator's git credentials via the shared
  `~/.claude`.
- Jira and other external writes are **prompt-forbidden only** (the worker
  contract above), not mechanically blocked.

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
