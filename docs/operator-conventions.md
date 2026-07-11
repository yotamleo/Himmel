# Operator working-conventions — reference

Durable himmel operator working-conventions, consolidated into one
versioned, reviewable place. This is the **HIMMEL-179 retro sharp #5**
consolidation: these habits were calibrated through repeated sessions but
lived only as per-user auto-memory `feedback_*` notes — volatile, not in
the repo, not reviewable, and gone the moment a memory prune runs. Pulling
them into the tree makes them survive a prune and lets them be reviewed
like any other doc.

Scope discipline (per the convention captured below in *Memory & CLAUDE.md
hygiene*): the hard, frame-shaping rules already live structurally in
[`CLAUDE.md`](../CLAUDE.md) and [`docs/internals/`](internals/). This doc
does **not** restate them — for anything with a canonical home it LINKS
(one line) and only INLINES the working-habits that have no other
checked-in home today. If an entry here ever earns structural enforcement
(a hook / gate / classifier), delete it here and point at the structure
instead.

## Jira CLI habits

These are invocation habits, not the op↔MCP policy. The "prefer plugin
over MCP" rule and the per-op mapping are canonical — see the
[Jira rule in `CLAUDE.md`](../CLAUDE.md#jira--prefer-plugin-over-mcp) and
[`docs/internals/jira-plugin.md`](internals/jira-plugin.md). Homeless
habits inlined:

- **Invoke by ABSOLUTE path** — `node <repo-root>/scripts/jira/dist/index.js …`, never relative `node scripts/jira/dist/index.js` from a worktree. `dist/` is an untracked build artifact that exists only in the main repo root; a worktree has none → `Cannot find module` / `MODULE_NOT_FOUND`.
- **Verify every write.** `create` echoes `Created HIMMEL-N`; `transition` echoes `HIMMEL-N → <Status>`; `comment` echoes `Comment added to HIMMEL-N`. Capture stdout and assert the line is present — silent failures (e.g. missing `dist/`) look identical to success in the transcript otherwise.
- **Don't pass `--project` / don't export `JIRA_*` from the repo root.** The CLI calls `loadEnv()` and reads the repo-root `.env` itself (via `??=`, never clobbering an already-set var). Shell env is irrelevant. Pass `--project` only for a one-off cross-project call.
- **Exact surface (guessing wrong burns turns):** verbs are `get`, `create`, `list`, `transition`, `transitions`, `comment`, `attach`, `edit`, `move`, `projects`, `project-create`, `link`. There is **no `search` verb and no `--jql`/`--labels`/`--summary`**. Title is `--title`; a multi-line description goes to a temp file + `--desc-file` (keeps the command single-line so the auto-approve hook matches).
- **File deferred items as real tickets too — and file them the moment they surface.** Every work item — including DEFERRED / "Won't Do" / timeboxed eval items — gets a real Jira running number (`HIMMEL-N` / `LUNA-N`), never an internal `#N` placeholder, and never parked in a handover/response as "could file later": anything not in Jira falls out of the where-are-we ledger + morning-report surfaces and is silently lost. File in the same turn the item is identified; batch-file when several surface at once; proposals that need operator triage are still filed (as To Do), not held. File-then-close beats file-never-and-forget.
- **Ad-hoc harness work gets a ticket too.** When a session turns into real implementation work (new scripts/logic, a multi-file change, a PR) — even one that surfaces mid-session from tooling friction, not planned feature work — file the ticket **before the first commit** and put `[HIMMEL-N]` in the commit subjects + PR. Conventional commits make the ticket *optional*, so "just a quick fix" silently ships ticketless; don't let it. Trivial conversational/single-line tweaks still don't need one (same judgement bar as feature work).
- **Project-boundary heuristic.** HIMMEL = himmel-repo infra (CLAUDE.md, hooks, gates, jira plugin, marketplace plugin code). LUNA = luna-vault content + clipper-pipeline calibration (code in `marketplace/plugins/obsidian-triage/` but functionally serves LUNA). When unsure, file where the DoD lands (where the change gets written), not where the code lives. Misfiled → use `jira move <KEY> --to-project <TARGET> --dry-run` (close source + recreate target + copy comments), never manual close+recreate.

## Git / CI attestation markers

All canonically documented — these are the structural gates. Linked, not restated:

- Attestation trailers (`Platforms tested: <os>`, `Security reviewed: <token>`) belong in the **first** commit after genuinely testing + reviewing — see the [Git-workflow rule in `CLAUDE.md`](../CLAUDE.md#git-workflow) and [`docs/internals/enforcement.md`](internals/enforcement.md). Recovery when a gate fails: [`docs/internals/stuck-playbook.md`](internals/stuck-playbook.md).
- Headless-claude ban + the `# headless-claude-ok:` marker → [HIMMEL-128 billing in `CLAUDE.md`](../CLAUDE.md#claude-invocation-billing-himmel-128) and [`docs/internals/enforcement.md`](internals/enforcement.md#claude-invocation-billing-himmel-128). The bounded-run primitive (`claude "<prompt>" < /dev/null`, no `-p`, stays on Max quota) is the sanctioned programmatic invocation.
- Operator habits with no structural home, inlined:
  - **`-F` first-commit beats `--amend --trailer`** for attestation. Write the whole message (body + trailing `Platforms tested:` / `Security reviewed:` lines) to a temp file and `git commit -F <file>` — `git --trailer "K: v"` can append a stray trailing `:` that breaks the end-anchored security regex. Verify with `git log -1 --format=%B | tail`.
  - **`gh pr merge` right after a push returns "not mergeable"** (`mergeStateStatus: UNKNOWN`) — GitHub hasn't computed mergeability for the new head SHA yet. Poll `gh pr view <N> --json mergeable` until non-`UNKNOWN`, or wait ~8s, then retry.
  - **Run a merge from the parent repo, not inside the worktree.** `--delete-branch` checks out `main` locally and the parent worktree already holds it. After merge, `git worktree remove <path>` + `git branch -D <branch>` in the parent. A worktree pruned with untracked `node_modules` leaves a deregistered on-disk dir — harmless, leave it.
  - **The CR marker is rewritten on EVERY push** (`check-cr-before-push.sh` writes `.git/cr-pending/<branch>` per non-docs push). Clear it AFTER the final push, immediately before `gh pr create`, or a follow-up commit re-creates it and re-blocks.
  - **Never hardcode/assume a PR number.** GitHub PR/issue numbers are ONE shared sequence; the operator or a parallel session can open a PR between your `create` and `merge`, so `last_number + 1` is not reliably yours (a `gh pr create` returning #501 then `gh pr merge 500` once merged a *different* parallel PR by mistake). Capture the number from the `gh pr create` output (or URL) and merge THAT exact number, or merge by branch (`gh pr merge <branch>`); verify with `gh pr view <n> --json headRefName`.
  - **Stage explicit paths — never `git add -A` / `git add .`.** Concurrent sessions sharing the repo tree (and build steps run with the wrong package manager) drop untracked artifacts that `-A` sweeps into the commit (e.g. an npm `package-lock.json` left inside a bun package — not gitignored). Stage the named paths you changed, eyeball `git status --short`, reject anything you didn't author. Structural backstop: the `check-artifact-leakage.sh` pre-commit hook blocks newly-added node_modules / OS junk / wrong-PM lockfiles; this habit is the residual for what a hook can't infer (hand-written-file leakage).
  - **Stale-base worktree: rebase onto `origin/main`, never `git reset --soft <local-main>`.** When a worktree branch has 0 commits and `main` advanced past its creation base (concurrent merges), `reset --soft` moves the branch ref forward but leaves the OLD files in the index → the commit **silently reverts** every change main gained since. Before the first commit, get even with the remote: `git fetch && git rebase origin/main` (or, with uncommitted work, `git stash push -u` → `git merge --ff-only main` → `git stash pop`). Then verify `git diff --name-only origin/main HEAD` shows ONLY your scope.
  - **CR sizing (HIMMEL-299, refined 2026-06-13):** **NEVER zero CR.** Even a docs/trivial PR gets, at minimum, ONE **docs-audit** subagent — a `pr-review-toolkit(-himmel)` `code-reviewer` scoped to a docs charter: (1) factual accuracy of every repo claim (hooks/gates/flags/paths/commands) checked against the actual code/config; (2) dead links resolve; (3) no stale file/flag/ticket references; (4) example blocks have correct paths + flags + syntax; (5) internal consistency. Out of scope: prose-style nitpicks. (`CLAUDE.md` changes → the `/claude-md-audit` lane.) Substantial docs/runbook PRs → 2 reviewers in parallel; real production-logic PRs → the full multi-agent set earns its keep (cross-file contract bugs the per-unit reviews structurally can't see). **Cost ladder, cheapest → most-expensive: docs-audit subagent → `/pr-check` → heavy CR (6 reviewers) → `/code-review ultra`.** `ultra` is the MOST expensive tier — MORE than heavy CR — so it is the top/last-resort escalation for the biggest/riskiest PRs, reached AFTER heavy CR, never as a cheaper first reach (HIMMEL-299 eval: ultra ADOPT, but billed + operator-triggered — the agent cannot launch it). Budget ~2 fix→re-CR rounds for a fresh tool. Any solo/holistic pass uses `pr-review-toolkit(-himmel)` `code-reviewer`; `caveman:cavecrew-reviewer` is a heavy-CR sixth opinion only, never the sole reviewer (HIMMEL-299: 2 false Criticals solo vs clean toolkit round).

## Cross-platform & testing

Standing engineering requirements for anything himmel ships — not per-task:

- **All code supports Windows + macOS + Linux.** Shell scripts must be **bash 3.2-safe** (macOS ships bash 3.2 — no `mapfile`, associative arrays, `${var^^}`, GNU-only `sed -i`/`date` flags) and shellcheck-clean. Hooks that run in a **PowerShell context** (e.g. SessionEnd) need a `.ps1` twin changed in **lockstep** with the `.sh`. Handle portable paths/env (`HOME` vs `USERPROFILE`/`LOCALAPPDATA`, forward-slash normalization, never hardcode `/tmp` vs `%TEMP%`). Test on the platforms the diff touches and attest (`Platforms tested: <os>` pre-push gate); when you can only test one, say so. A single-platform script breaks adopters silently.
- **Tests must be hermetic — never touch the operator's real data.** For any tool that reads/mutates real user state (vaults, `~/.claude`, registries, backups, dotfiles): redirect `HOME` to a temp dir on EVERY engine invocation and pass explicit temp `--roots` / `--registry` so no default scan reaches real dirs; no real-path literals in tests. Assert positively in two directions — artifacts landed in the temp `HOME`, AND a snapshot check that the real `~/.claude/…` gained nothing (not a no-op "if real dir exists" scan, not a drift-prone hardcoded allowlist). Force failure paths with portable injections (parent-is-a-file to break `mkdir -p`/`cp`), not `chmod` (cosmetic on NTFS).

## Upstream & fork contributions

Habits for anything that leaves this repo toward an upstream/external project:

- **Adapt upstream PRs first.** For any fix targeting a dependency we vendor or fork, FIRST scan the upstream repo's open PRs (`gh pr list --repo <upstream>`) for an existing PR that solves it, and adapt/cherry-pick that instead of authoring fresh. Community PRs are often already reviewed/verified on the exact platform, and staying close to the upstream original keeps the fork rebaseable — adapted commits drop cleanly when upstream merges. Note the upstream PR# in the commit/ticket so a drop-on-upstream-merge sweep can find it.
- **Timebox + soak before filing anything upstream.** Filing an issue or PR to an external repo is GATED on real usage first proving: (a) we correctly understand the problem, (b) our own workaround is genuinely insufficient, (c) we observed improvement + actual usage justifying the ask. Never file on sight — a drafted upstream issue gets concrete soak criteria plus a revisit timebox tied to that tool's own adoption gate ([`docs/tool-adoption/rubric.md`](tool-adoption/rubric.md)); if the pain doesn't recur within the window, close won't-file. Dogfood-first applied outbound — and a soaked issue carrying usage evidence is a stronger issue anyway.

## Autonomy & arming

Canonical arming mechanics live in [`docs/internals/handover-system.md`](internals/handover-system.md); homeless habits inlined:

- **Chain ASAP — never park an arm hours out, never pause idle at a decision the model could make.** At a natural completion / context-saturation point, arm + chain the next session (ticket-named, cold-start-complete handover) instead of stopping: idle quota that isn't spent before its window resets simply evaporates. "The handover is written" is not the finish line — exhaust the planned queue in-session while budget remains, then re-arm for the SOONEST slot after true wrap (minutes out, not hours). If an arm exists and work continues past its slot, move/replace it BEFORE the fire time (double-fire risk — HIMMEL-856). Only truly pause when the next step needs an operator decision that can't be pre-teed.

## Permissions & bash command shape

Canonical — linked, not restated:

- Permission prompt/hang on a Bash command comes from the static matcher bailing on `$var`/`$(…)`/backticks/compound operators (it never reads the allow-list), NOT a missing allow rule. Fix is structural (the `auto-approve-safe-bash.sh` hook), not wider allow rules. Prefer literal single commands. See the [Bash-command-shape rule in `CLAUDE.md`](../CLAUDE.md#bash-command-shape-himmel-203), [`docs/internals/enforcement.md`](internals/enforcement.md), and [`docs/internals/stuck-playbook.md`](internals/stuck-playbook.md).
- The auto-mode classifier is a semantic layer on top of the allow-list (self-merge-to-main, attestation-amend, Jira writes under a workflow that didn't NAME Jira). Symptom→action recovery lives in [`docs/internals/stuck-playbook.md`](internals/stuck-playbook.md) — surfaced load-on-trigger by the `himmel-ops:stuck-playbook` skill.

## Memory & CLAUDE.md hygiene

These shape what goes WHERE — the layer-selection discipline. The frame is canonical (HIMMEL-177 / HIMMEL-195 in [`CLAUDE.md`](../CLAUDE.md#operator-conventions-calibrated-through-repeated-sessions) + worked examples in [`docs/internals/enforcement.md`](internals/enforcement.md#operator-conventions--worked-examples)). Inlined habits:

- **No operational "when stuck" rules in `CLAUDE.md`.** It is loaded every session and is prunable under context pressure, so detail Claude needs *when stuck* may be gone exactly when needed; it is also per-user/per-repo. Put operational guidance in a repo-distributed load-on-trigger skill / `docs/internals/` playbook, or fix it structurally in code (then there's no rule to maintain). This very doc is the application of that principle.
- **Verify universal-quantifier claims before writing them.** Don't write "each/every X has Y" in `CLAUDE.md` without running the count first (`ls X | wc` vs `ls test-X | wc`). If not 1:1, write "Most X have Y — add one for new X". A false universal misleads every future session. Pair a correctness reviewer with the CLAUDE.md best-practice audit on CLAUDE.md PRs — they catch different misses.
- **Generic example names in public-facing docs.** In docs / command examples / templates that ship publicly, use generic placeholders (`work-vault`, `my-vault`, `project-x`), not real personal vault/project names — a real name leaks personal context with no added illustrative value. Pick generic names at **authoring time**, not just at propagation time (cheaper than catching it in a publish-time grep); flag any real personal name found in a propagation diff.
- **Internal specs/plans/decision records are work artifacts, not reference docs.** Design docs, implementation plans, and decision records belong in your state repo (per the [Luna-area docs convention in `CLAUDE.md`](../CLAUDE.md#luna-area-docs-convention-himmel-138-locked-2026-05-25)), never in a code repo's `docs/` (operator-facing reference + OSS-public only) — they're work artifacts and some carry private context. The cross-repo source of truth is the **handover skill** (loaded in any repo), because a project-scoped `CLAUDE.md` is only loaded when cwd is in that repo, but specs get produced while working in other repos too.
- **Auto-memory confidence/staleness frontmatter (HIMMEL-257).** Files under `~/.claude/projects/<project>/memory/` carry optional top-level frontmatter fields: `confidence: high|medium|low` (`high` = operator-stated rule or behavior verified live; `medium` = point-in-time observation that can drift; `low` = known to conflict with current state — re-check before acting), `verified: YYYY-MM-DD` (last date the claim was checked against reality), and `supersedes: <memory-name>` (this memory replaces that one). The rule: **when a memory is recalled and found stale, re-check and update `verified:` (correcting the content), or delete it** — never act on a stale claim silently. Semantic memory without staleness marking structurally forgets wrong. The `MEMORY.md` index format is unchanged: one line per memory, no metadata there.

## Telegram bridge

- **Forward every block to Telegram, don't terminal-report.** When this session is the active bridge owner, relay every permission denial / classifier block / clarifying question to the operator's chat and wait — the operator is watching Telegram, not the terminal. In auto mode a classifier denial returns as a tool error so Claude keeps control and CAN relay; a true interactive permission *prompt* blocks the harness and relay only works reliably in auto mode. (Homeless operator habit — inlined.)
- Bridge architecture, the single-poller constraint, the `telegram-himmel@himmel` fork, and the ops runbook are canonical in [`docs/internals/telegram-bridge.md`](internals/telegram-bridge.md).

## Luna / clips

- **Clips are pointers, not self-contained notes.** Anything touching `~/Documents/luna/Clippings/` or the `obsidian-triage` plugin: assume a clip is a POINTER to a source URL (tweet/thread/article/video/repo); the body is just intro text, the signal is at the URL. Never propose an `obsidian-triage` feature that reads only the clip body — the harvest layer is the real input, and harvest comes before triage. (Homeless operator habit — inlined.)

## Excluded by design

Not operator working-conventions (left in per-user auto-memory only):
identity / bare path references (repo + vault paths), project-status notes
(license & visibility, clipper-pipeline design, tool-adoption framework —
the last already has a home at
[`docs/tool-adoption/rubric.md`](tool-adoption/rubric.md)), and the
qmd bun-install Windows hotfix (already a structural fix in
`scripts/lib/qmd-bin.sh`, tracked by HIMMEL-163).
