# Cloud hooks: proposal (HIMMEL-4206)

**Status: PROPOSAL. Nothing here is built.** No hook and no `.claude/settings.json`
line changed. The operator picks; a build is a separate PR (and one that edits
`.claude/settings.json` is on `scripts/ci/ci-trust-paths.txt`, so it needs a
trust-reviewed console GO).

**Update 2026-10-05.** Two of the unknowns below are settled. The HIMMEL-4273
probe showed plugin hooks DO load when the environment's setup script installs the
plugins (`--with-plugins`), and that repo hooks fire with the cloud clone counted
as a primary checkout; see
[`cloud-brief-template.md`](../handover/cloud-brief-template.md#plugin-hooks-in-the-cloud-probed-2026-10-04-himmel-4273).
The table "Plugin hooks: does NOT load" therefore holds only for a plugin-free
environment. The [user-level tool audit](#user-level-tool-audit-himmel-4206-slice-2)
at the end replaces "What fails open or closed" with measured behaviour.

## The problem

A `claude --cloud` session loads the clone's `.claude/settings.json` hooks (single-repo
session) but **not plugins and not `~/.claude`**. Our guards come from two places, so
a cloud session runs about half of them and nothing says which half.

## Where each hook comes from

**Repo `.claude/settings.json`: loads in the cloud.**

| Event | Hooks |
|---|---|
| PreToolUse Bash | one `--chain`: auto-approve-safe-bash, check-cr-marker-on-pr-create, block-jira-compound-write, block-tail-pipe-on-gates, block-read-secrets, read-clamp, block-destructive-commands, block-git-stash, block-bare-qmd-query, block-rogue-claude-schedule, block-chokepoint-env-prefix, require-quiet-run, block-edit-live-settings, block-write-into-main-checkout, guard-relay-writes, guard-pr-check-literal |
| PreToolUse other | PowerShell chain; Read/Grep (read-secrets, read-clamp); Edit/Write chain (block-edit-on-main, block-edit-live-settings, guard-memory-capture, guard-relay-writes); orchestrator-inline-guard; block-leg-askuserquestion; guard-leg-wakeup; guard-agent-model; block-backend-tier (Atlassian MCP); auto-arm-on-cap; shadow-ledger pre; session-run-hook subagent-start; graphify hook-guard; block-subagent-park |
| PostToolUse | auto-arm-on-subagent-cap, trigger-cr-on-pr-create, trigger-cr-on-push, detect-dirty-primary, shadow-ledger post, check-hook-file-parse, claudex-inbox-hook |
| SessionStart / Stop / other | check-update-available, inject-initiative, qmd-staleness-notice, graphify-freshness-advisory, memory-index-state-notice, claudex-inbox-sessionstart, console-compact-reinject, shadow-ledger heartbeat, session-run-hook; Stop: speak-reply, stop-console-idle-guard; PreCompact, PermissionDenied, PermissionRequest, Notification, SessionEnd |

**Plugin `hooks/hooks.json`: does NOT load in the cloud.**

| Plugin | Hooks | Matters in the cloud? |
|---|---|---|
| himmel-ops | block-docker-privesc | **Yes**: docker is preinstalled and the session is root |
| himmel-ops | block-merged-pr-commit | **Yes**: stops a commit onto an already-merged PR branch |
| himmel-ops | block-unresolved-cr-merge | Marginal: the brief forbids merging, this is the backstop |
| himmel-ops | block-glm-external-writes, block-lesson-enforcement-writes | No: both fire only under a local env flag (`HIMMEL_GLM_WORKER`, `HIMMEL_LESSON_LOOP`) |
| himmel-ops | block-graphify-egress, block-rogue-codex-wsl, block-rogue-codex-exec | No: no graphify, no codex in the cloud |
| himmel-ops | guard-implementor-dispatch, guard-console-dispatch, guard-subagent-model | No: dispatch policy for consoles and legs |
| himmel-ops | inject-where-are-we, inject-doc-freshness, inject-worktree-nudge, record-hook-integrity, record-primary-baseline, refresh-where-are-we-on-end, jira-nudge-on-end, telegram-session-end, telegram-notification, inject-minerva-critic | No: local operator conveniences |
| lean-skills | note-superpowers-prefix | No |
| qmd | ensure-qmd-daemon | No: no qmd in the cloud (operator OPEN item) |

So only **three** plugin hooks carry guard value for a cloud brief. The rest are
local ergonomics.

## What fails open or closed in the cloud

Reasoned from `run-hook-with-bash.js` and the scripts, **not observed**: nobody has
run a cloud session with these hooks live and read the result.

- **Plugin hooks use `--optional`**, and a missing script means "skip". They are absent
  as a group, so the cloud fails **open** on all of them, silently.
- **Repo hooks that read user-level state fail open** (a hook error that is not exit 2
  does not block): `shadow-ledger` writes under `~/.claude/himmel/trust`,
  `session-run-hook` needs bun, the graphify guard is `command -v graphify … ; exit 0`,
  `inject-initiative` / `qmd-staleness` / `graphify-freshness` / `memory-index-state`
  read `~/.himmel` and luna paths that are absent. Absent state reads as "nothing to say".
- **Repo hooks that can fail closed**: `block-edit-on-main` and the pre-commit
  `check-worktree-isolation` deny edits and commits in a PRIMARY checkout (a `.git`
  directory, not a linked worktree), and a cloud clone is exactly that. The cloud pilots
  (#1703, #1706) edited and committed fine, so either those hooks did not load, did not
  deny, or the clone is not a primary checkout. **We do not know which.**
  That is the single most useful thing to measure.
- `block-write-into-main-checkout`, `guard-pr-check-literal` and
  `auto-approve-safe-bash` resolve `HIMMEL_REPO` / the anchor checkout. Unset in the
  cloud, they degrade to their no-anchor branch; behaviour is unverified.

## Options

**(a) Setup script writes a VM-local `~/.claude/settings.json`** pointing at the
clone's `scripts/hooks/*`. Undocumented, and the docs say `~/.claude` is not loaded in
cloud sessions. It can only work if the session reads the file the setup script wrote
inside the VM. Cheap to test, unsafe to rely on: a silent no-load looks identical to
a guarded session. It would also have to rebuild the plugin hooks' `${CLAUDE_PLUGIN_ROOT}`
runner paths by hand.

**(b) Mirror the plugin hooks into the repo `.claude/settings.json`**, gated on
`CLAUDE_CODE_REMOTE`. Documented route (repo settings load). A settings.json hook has
no conditional field, so the gate lives in the command
(`[ "${CLAUDE_CODE_REMOTE:-}" = true ] && exec …`), which keeps local sessions
unchanged and avoids double-firing next to the plugin copy. Cost: a second copy of each
hook's wiring to keep in step with the plugin, and an edit to a trust-path file.
Mirror only the three that matter, not all twenty.

**(c) Repo SessionStart guard-presence check.** A `CLAUDE_CODE_REMOTE`-only hook that
verifies the expected guard set is wired (the scripts exist, the runner resolves) and,
on a miss, prints a loud warning into the session context. A SessionStart hook cannot
halt a session (exit 2 only surfaces stderr), so this makes an absent guard visible; it
does not stop anything. It also prints one line naming which guards are live, which
answers the unknown above for free. It does not add a guard.
Cost: one new hook script plus one `.claude/settings.json` stanza.

## Recommendation: (c) first, then (b) for three hooks; (a) as an experiment only

1. **(c)** now. It is the only option that turns "we do not know what runs" into an
   observed answer, and it is repo-only and documented. Its first cloud run settles the
   `block-edit-on-main` question above.
2. **(b)**, narrowed to `block-docker-privesc`, `block-merged-pr-commit` and
   `block-unresolved-cr-merge`, once (c) confirms repo hooks do load and run there.
   Skip it if (c) shows they do not load at all; then no repo-side fix helps and the
   shepherd's review is the only gate.
3. **(a)** only as a one-session probe via `setup-env.sh`, never as the mechanism:
   a mechanism that fails silently is the failure (c) exists to prevent.
4. Whatever is chosen, the local shepherd stays mandatory (`/pr-check`, CR gate, merge).
   A cloud session ships a PR and stops; hooks narrow what it can break on the way.

## Decision wanted from the operator

Build (c)? Mirror (b) for the three hooks after (c) reports? Both are separate PRs
and need your OK because each edits `.claude/settings.json`.

## User-level tool audit (HIMMEL-4206 slice 2)

Every hook script wired in `.claude/settings.json` was grepped for user-level state:
`~/.himmel`, `~/.claude/himmel`, the handover root, `HIMMEL_REPO`, qmd, graphify, luna,
bun, the Jira dist. Each one that matched was then run in a **local cloud-like
simulation** on 2026-10-05: a fresh `git clone --depth 1` (a primary checkout, like
the cloud clone), `env -i PATH=/usr/bin:/bin HOME=<empty dir> CLAUDE_CODE_REMOTE=true
CLAUDE_PROJECT_DIR=<clone>`, so qmd, graphify, `HIMMEL_REPO`, `HANDOVER_DIR` and all
home state were absent. Each hook got a benign Bash payload, and each guard also got a
payload it must refuse.

**Observed in two real cloud sessions on 2026-10-06** (probe P1, HIMMEL-4429;
reports are HIMMEL-4206 comments 34054 and 34055, from an environment built by the
`docs/setup/cloud-environment.md` recipe). Both sessions ran all 25 wired hooks
directly under `CLAUDE_CODE_REMOTE=true` with a benign Bash payload: every one
exited rc 0 with no stderr, the slowest in 136 ms (`block-write-into-main-checkout`).
`shadow-ledger` (node) and `session-run-hook` (bun) also exited rc 0. qmd, graphify
and konsole are absent there; tmux, `at`, node 22, bun 1.3, jq 1.7, shellcheck 0.9.0
and pre-commit 4.6.2 are present. In the Bash tool's shell, `HIMMEL_REPO` and
`HANDOVER_DIR` are unset and `CLAUDE_PROJECT_DIR` is empty, but the hook chains still
resolve `$CLAUDE_PROJECT_DIR`. No SessionStart hook printed anything at startup,
which matches the silent fail-open rows below. The table keeps the simulation's
columns. The **Cloud verdict** column now records what the cloud showed; a row marked
*simulation only* was not exercised by a guard call in the cloud.

| Hook | Reaches for | Benign call | Guard call | Cloud verdict |
|---|---|---|---|---|
| block-destructive-commands, block-git-stash | (graphify in a comment only) | rc 0 | `git reset --hard HEAD` / `git stash`: rc 2, denied | **Guard holds, observed**: both denied in the cloud; `git status` / `git log` allowed |
| block-edit-on-main | primary-checkout test | rc 0 | Write in the clone: rc 2, denied | **Fails closed by design, observed**: the cloud clone (`/home/user/Himmel`) is a primary checkout on a `claude/…` branch, so every in-clone Write is denied; work in a worktree (template step 3). A Write outside the clone was allowed |
| block-write-into-main-checkout | anchor / primary | rc 0 | `git checkout -b` in the clone: rc 2, denied | **Fails closed by design** (same remedy); benign call rc 0 in the cloud, guard call *simulation only* |
| block-edit-live-settings | primary `.claude/` | rc 0 | Write `.claude/settings.json`: rc 2, denied | **Guard holds**; benign call rc 0 in the cloud, guard call *simulation only* |
| block-read-secrets, require-quiet-run, block-chokepoint-env-prefix | none | rc 0 | a read of the dotenv file, a bare suite, a seam prefix: rc 2, denied | **Guard holds**. Observed: `require-quiet-run` allowed the `quiet-run` suite call (rc 0, all checks passed). `block-chokepoint-env-prefix` also refused, in both sessions, a heredoc that wrote and ran a read-only probe script (`f="scripts/hooks/$h.sh"`, no seam variable): a false positive, HIMMEL-4572 |
| guard-pr-check-literal | `HIMMEL_REPO` (45 refs) | rc 0 | relative `scripts/cr/pr-check-context.sh`: rc 2, "HIMMEL_REPO is unset" | **Fails closed**: a cloud session cannot run `/pr-check`; intended, the shepherd runs it. `HIMMEL_REPO` confirmed unset in the cloud; guard call *simulation only* |
| block-bare-qmd-query | qmd | rc 0 | bare `qmd query`: rc 2 even with qmd absent | **Guard holds** (denies a command that would fail anyway) |
| auto-approve-safe-bash | `HANDOVER_DIR`, `HIMMEL_REPO`, Jira dist | allow for `true`, 10 ms | n/a | **Fail open, correct**: anchor-dependent branches simply do not match |
| block-backend-tier | Jira dist | rc 0 | n/a | **Inert**: its matcher is the local plugin's `mcp__plugin_atlassian_atlassian__*`; the cloud connector's tool name differs (still unconfirmed: the Atlassian connector was switched off in both probe chats at start-up, so its tool names never loaded), and the CLI has no credentials there, so the MCP is the right route |
| block-jira-compound-write | Jira dist | rc 0 | n/a | **Inert**: no authenticated CLI in the cloud |
| auto-arm-on-cap, auto-arm-on-subagent-cap, console-compact-reinject, console-precompact-snapshot, stop-console-idle-guard, guard-relay-writes | handover root | rc 0, silent, 2-72 ms | n/a | **Fail open, correct**: no handover root means no console or relay state to act on |
| inject-initiative | `HIMMEL_REPO` | rc 0, silent | n/a | Fail open, correct (no initiative in the cloud) |
| qmd-staleness-notice | qmd, its cache under `/tmp/claude` | rc 0, silent with a fresh cache dir | n/a | Fail open, correct. Locally it served this station's cached notice from the shared `/tmp/claude`; the cloud VM's `/tmp` starts empty |
| graphify-freshness-advisory, graphify inline guard (`command -v graphify … ; exit 0`) | graphify | rc 0, silent | n/a | Fail open, correct |
| check-update-available, detect-dirty-primary, memory-index-state-notice, claudex-inbox-sessionstart, guard-memory-capture, block-rogue-claude-schedule | `~/.claude/himmel`, luna, memory dir | rc 0, silent | n/a | Fail open, correct |
| log-classifier-denial, shadow-ledger, session-run-hook (bun), stop-queue | `~/.himmel`, `~/.claude/himmel/trust` | rc 0; wrote `~/.himmel/session-runs.jsonl`, `~/.himmel/state/classifier-denials.jsonl`, `~/.claude/himmel/trust/ledger.jsonl` | n/a | **Fail open, harmless**: telemetry lands in the VM's own home and is discarded with it |

**Result.** No wired hook crashed or hung, every guard that should deny still denied,
and every hook that reaches for absent user-level state went silent with rc 0. Two
fail closed in the cloud by design (edit-on-main, write-into-main-checkout: the
worktree step answers both), and one fails closed on purpose (`guard-pr-check-literal`:
the shepherd owns `/pr-check`). The real cloud run (HIMMEL-4429) contradicts no row:
no hook crashed, hung or wrote stderr, and every guard it exercised denied. Its one
wrong refusal is the `block-chokepoint-env-prefix` heredoc false positive, filed as
HIMMEL-4572 (v1.0.2, label cloud). It is not cloud-specific, and the Write-then-run
shape the probe brief prescribes avoids it.
