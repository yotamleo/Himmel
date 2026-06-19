# Enforcement layers — reference

> Extracted from `CLAUDE.md` per HIMMEL-164 (state-not-prompt slimming).
> CLAUDE.md keeps a session-time summary; the full reference lives here.
> Source of truth for what actually runs: `.pre-commit-config.yaml` and
> `.claude/settings.json`.

## Pre-commit Enforcement

Source of truth: `.pre-commit-config.yaml`. Smoke tests for each Claude
hook live alongside it as `scripts/hooks/test-<hook>.sh` — run after
any hook edit before pushing.

Stages currently wired:

- **Format/lint (pre-commit):** trailing-whitespace, end-of-file-fixer,
  check-yaml, check-json, shellcheck.
- **Secrets (pre-commit):** gitleaks.
- **Branch hygiene (pre-commit):** worktree-isolation (blocks commit when
  branch == main), merged-branch check (warns on commits to already-merged
  branches).
- **MCP plugin enforcement (pre-commit):** mcp-plugin-refs (blocks commits
  referencing Atlassian MCP Jira tools that have a himmel-jira plugin
  equivalent — see `block-mcp-when-plugin-exists.sh` below).
- **Headless-claude gate (pre-commit):** no-headless-claude (blocks new
  `claude -p` / `claude --print` / `claude --bg` introductions unless
  the call has a `# headless-claude-ok: <reason>` marker on the same or
  preceding line — see "Claude invocation billing" below).
- **Dependency integrity (pre-commit):** npm lockfile-integrity,
  uv-lock-integrity, pip-hashes (requirements*.txt must use --generate-hashes).
- **Commit-msg:** conventional-commit-msg (validates conventional format +
  optional HIMMEL-N).
- **Pre-push:** no-push-to-main, npm-audit (high+), npm-licenses (allowlist),
  npm-audit-signatures, code-review-before-push (multi-agent CR via
  pr-review-toolkit), platforms-tested (cross-platform attestation for
  shell/script changes — see below), security-reviewed (security-review
  attestation for non-docs code changes; HIMMEL-176, see
  `docs/security-review.md`).

### Portable export — `.pre-commit-hooks.yaml` (HIMMEL-214)

Worktree isolation was structurally enforced only in himmel; other repos
the operator works in (notably luna) relied on prose. `.pre-commit-hooks.yaml`
at the repo root exports two gates other repos opt into via pre-commit's
remote-repo mechanism (`repo: https://github.com/yotamleo/Himmel` +
pinned `rev:`):

- **`pr-lane-isolation`** (`check-pr-lane-isolation.sh`) — path-scoped:
  blocks commits on `main` that touch files matched by the CONSUMING
  repo's `files:` regex. Built for two-lane repos like luna (PR lane =
  structural paths via PR; plugin lane = vault content straight to main).
  Without a `files:` filter it matches everything (degrades to full
  isolation, with offending paths listed).
- **`worktree-isolation`** (`check-worktree-isolation.sh`) — himmel-grade:
  blocks EVERY commit on `main`.

Both are `language: script` so they run from pre-commit's clone of himmel
and can source `scripts/guardrails/lib.sh`. Bypass for a deliberate
exception: `SKIP=<hook-id> git commit …` (pre-commit native), i.e.
`SKIP=pr-lane-isolation` or `SKIP=worktree-isolation`.
Consumer snippet + luna's concrete PR-lane regex:
[`docs/luna/pr-lane-guard.md`](../luna/pr-lane-guard.md).

## Claude UserPromptSubmit Hooks

One hook wired in `.claude/settings.json` fires when the operator
submits a prompt, before Claude processes it.

### `improve-on-submit.sh` — /improve auto-trigger (HIMMEL-127)

Default: OFF. When `IMPROVE_ON_SUBMIT=1` is set in the launching
shell, every prompt the operator submits gets context injected
suggesting Claude run `/improve` on it first to refine before
responding. Drains stdin gracefully; never blocks a prompt.

Truthy values: `1`, `true`, `TRUE`, `on`, `ON`, `yes`, `YES`. All
other values (including unset, `0`, `false`) leave it off.

Companion artifacts:
- `.claude/commands/improve.md` — manual `/improve <draft>` slash command.
- `scripts/improve/save-artifact.sh` — disk-write helper. Resolves
  `<HANDOVER_DIR>/.improve/` (Mode B) or `<repo>/.improve/` (Mode A).
- `scripts/improve/test-save-artifact.sh` + `scripts/hooks/test-improve-on-submit.sh` — smoke tests.

**Sensitivity note:** disk artifacts under `.improve/` contain the
operator's original draft + refined prompt verbatim. If a draft
includes credentials, API keys, or sensitive context, those land on
disk. Mode A artifacts are gitignored (`/.improve/` in `.gitignore`);
Mode B writes to `<state-repo>` which is also private. Treat the
`.improve/` directory as sensitive regardless — do not commit it,
do not copy it off-disk without redacting first.

v1 ships env-gated only. v2 (future child ticket) will
add length/keyword-based auto-firing — prompts >100 chars OR matching
exploratory keywords ('help', 'how', 'should I') auto-fire without
the env var.

## Claude PreToolUse Hooks

Six hooks wired in `.claude/settings.json` fire BEFORE Claude executes
tool calls. Five BLOCK risky operations; one (`auto-approve-safe-bash`)
GRANTS permission for safe ones so they don't hang.

**Bypass convention (applies to the four DENY hooks):** session-sticky
env vars must be set in the shell that LAUNCHED Claude Code
(`EDIT_ON_MAIN_OK=1 claude`). Claude cannot inject env vars into hook
processes, so per-call prefix syntax does not work. Bypass lasts until
the Claude process exits — restart without the var to re-enable.
Alternative: comment the hook stanza in `.claude/settings.json`.
(`auto-approve-safe-bash` has no bypass — it only ever grants; to disable
it, comment its stanza.)

### `auto-approve-safe-bash.sh` — pre-Bash auto-approve gateway (HIMMEL-203)

Fires on Bash. Returns a `permissionDecision:"allow"` for read-only /
inspection commands so they run without a prompt — INCLUDING ones wrapped
in loops/pipes with `$var` expansion, which Claude Code's native matcher
refuses to match against the allow-list ("Contains simple_expansion") and
which therefore HANG then abort in headless/auto. The matcher bails BEFORE
reading the allow-list, so widening allow rules cannot fix this; a hook
that reads the literal command and decides itself is the structural fix
(HIMMEL-195 escalation: instructional command-shape rule → structural hook).

**Inverted contract vs the block-* hooks:**
- NEVER blocks, NEVER denies. Worst case it stays silent → command falls
  through to the normal permission flow. It FAILS OPEN (missing jq,
  unparseable input, anything-not-provably-safe → silent `exit 0`).
- Only ever EMITS "allow". The destructive deny-list + the block-* deny
  hooks remain the hard backstop: per CC docs a deny rule and an exit-2
  hook WIN over a hook "allow", so approving `cat *`/`grep *` here cannot
  defeat `block-read-secrets` (it exits 2 on a secret read; that wins).

**Auto-approved iff ALL hold:** no command/process substitution
(`$(` `` ` `` `<(` `>(`); no interpreter shell-out tell (`system(`
`popen(` `exec(`); no output redirect to a real file (only `>/dev/null`
and fd-dups tolerated); and every sub-command (split on `| && || ;`)
resolves — after skipping shell keywords, redirects, leading `VAR=val` —
to a binary in the read-only safe set, or `git`/`gh` read-subcommand, or
the dogfooded Jira CLI (`node …/scripts/jira/dist/index.js …`). Variable
expansion in ARGUMENTS is fine (binary is still a literal); a variable
AS the binary (`$cmd …`) falls through. Writes, interpreters (awk/sed
shell-out), and `git`/`gh` write subcommands deliberately fall through —
with ONE exception: a `git push --force-with-lease` on a NON-main branch is
granted (HIMMEL-212), since the blanket `git push --force*` deny used to block
even the safe lease form. Bare `git push --force` / `-f`, and any lease push
that names main as the target or runs from the `main` branch, are NOT granted
(they stay deny-listed / fall through; `check-no-force-push.sh` hard-refuses
force-to-main as the ref-level backstop).
Spec: `scripts/hooks/test-auto-approve-safe-bash.sh`.

### `block-edit-on-main.sh` — pre-edit guard

Fires on Edit/Write/MultiEdit/NotebookEdit. Refuses any edit targeting
the primary worktree while HEAD == main. Paths are canonicalised via
`realpath -m` first, so `..` traversal and symlink tricks cannot
bypass. `handovers/**` is exempt. Bypass: `EDIT_ON_MAIN_OK=1`. Per-repo opt-out:
place a local `.single-writer` file at the repo root (gitignored via global
excludes — never committed, so clones stay protected by default); the hook
allows all on-main edits in that repo and skips the block entirely. Anchored
to the edited file's repo (`repo_real`), so a marker in a parent repo cannot
leak the opt-out onto a nested repo.

Dependencies: `jq` plus either GNU `realpath -m` (Linux native; Git
Bash on Windows includes it) or `python3` (macOS default — uses
`pathlib.Path.resolve(strict=False)` for cross-platform canonicalisation).
macOS operators who want unprefixed `realpath`:
`brew install coreutils && export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"`
(brew installs as `grealpath`; gnubin PATH exposes it as plain `realpath`).

### `block-read-secrets.sh` — pre-read guard

Fires on Bash/PowerShell/Read/Grep. Refuses any tool call that would
print or grep the contents of a secret file (`.env`, `.env.*`,
`.envrc`, `id_rsa`, `id_ed25519`, `*.pem`, `*.key`, `*.p12`, `*.pfx`,
`credentials.json`, `secrets.y[a]ml`). Bypass: `READ_SECRETS_OK=1`.

**Intentionally NOT blocked:**
- Interactive editors (`vim`, `nano`, `vi`, `nvim`, `emacs`, `view`) —
  they never surface file content to Claude as a tool result.
- Write-only ops (`echo >`, `tee`, `mv`, `cp`).
- In-place rewrites: `sed -i …`, `sed -i.bak …`, `sed --in-place …`,
  `awk -i inplace …`, `awk --in-place …`. These rewrite the file
  without piping content to stdout, so .env rotation/edit keeps working.

`sed` and `awk` WITHOUT `-i`/`--in-place` ARE blocked, because they
print file contents to stdout (`awk '{print}' .env`, `sed s/X/Y/ .env`).
Prefer asking the operator to echo specific values via the `!` prefix
instead of bypassing.

### `block-mcp-when-plugin-exists.sh` — pre-MCP-call guard

Fires on `mcp__plugin_atlassian_atlassian__*` tool calls. Refuses the
9 Atlassian Jira MCP tools that have a himmel-jira plugin equivalent
(`getJiraIssue`, `searchJiraIssuesUsingJql`, `createJiraIssue`,
`editJiraIssue`, `addCommentToJiraIssue`, `getTransitionsForJiraIssue`,
`transitionJiraIssue`, `getVisibleJiraProjects`, `createIssueLink`).
Refusal stderr embeds
the exact replacement `node scripts/jira/dist/index.js …` command, so
Claude can switch in one step rather than re-deriving the syntax from
the mapping table. All other Atlassian MCP tools — Confluence,
`lookupJiraAccountId`, custom-field metadata, link types, worklog,
`fetch`, `search` etc. — pass through unblocked. Bypass: `MCP_JIRA_OK=1`.

Pairs with the pre-commit `mcp-plugin-refs` gate, which catches the
same names in *committed* source files as defense-in-depth if this
PreToolUse hook is bypassed or disabled.

### `auto-arm-on-cap.sh` — usage-cap watchdog (HIMMEL-220)

Fires on every tool call (matcher `*`), throttled to one real check per
`AUTO_ARM_CHECK_INTERVAL` (default 60s; the fast path costs one
`stat()`). Reads the claude-statusline usage cache
(`/tmp/claude/statusline-usage-cache.json`, the same source
`resume-slot.sh` / `cap-reset-time.sh` consume). When any window's
utilization crosses `AUTO_ARM_THRESHOLD` (default 90%):

1. writes a mechanical status snapshot into the handover root
   (`scripts/lib/handover-path.sh` resolution; falls back to the state
   dir when the root is unresolvable OR unwritable — the arm matters
   more than the snapshot's address). The snapshot name is stable per
   cap-window+session, so retries overwrite in place (no file spam),
2. arms a resume via `arm-resume.sh --time smart --handover <snapshot>`
   (rc=3 "already armed" counts as success — dedup with any
   operator-armed or supervisor-armed job),
3. blocks the in-flight tool call ONCE (exit 2) so the model is told to
   write a full handover and wind down. The fired marker is keyed per
   cap window AND per session (from the PreToolUse `session_id`), so
   every concurrent session gets its own one-shot notice while the
   scheduler still holds exactly one job.

This hook is a WATCHDOG, not a guard — it inverts the directory's
fail-closed convention, with a two-grade failure policy:
- **Absence of signal** (missing/unparseable cache, stale cache *below
  the escalation bound*, schema drift where no window carries a numeric
  utilization, below threshold, throttled, already fired, already
  escalated for this wedge+session) → quiet exit 0 — EXCEPT when the
  escalated marker is the shared `nosession` key (session_id was
  unavailable): that dedup skip exits 1 with a visible shared-notice
  warn instead of 0, so a harness regression that loses session_id
  cannot silently suppress sibling wind-downs. A cache with NO
  parseable utilization is treated as unusable, never coerced to
  "0%, all fine". Staleness is NOT quiet indefinitely (HIMMEL-275): a
  cache frozen past `AUTO_ARM_STALE_ESCALATE_AGE` (default 1800s),
  observed across `AUTO_ARM_STALE_MIN_CHECKS` (default 3) consecutive
  real checks of a live session, escalates — a one-shot exit-2 block
  keyed per wedge-mtime AND per session (each concurrent/subsequent
  session gets its own wind-down notice) plus a safety arm at the stale
  cache's `five_hour` `resets_at` when 2min–24h out, else now+5h. The
  arm uses an explicit HH:MM, never `--time smart` (smart re-reads the
  same wedged cache and fail-closes — detect and recover would die
  together). The arm stays globally deduped via arm-resume rc=3; if
  the one-shot marker itself cannot be persisted, the block downgrades
  to a repeating visible exit-1 warn rather than block-looping.
- **Watchdog malfunction** (python3 missing/crashed/hung, unwritable
  state dir, snapshot unwritable everywhere, arm-resume missing or
  failing) → exit 1: non-blocking, but stderr SURFACES to the user. A
  broken watchdog must be seen, not whisper into a discarded stream.
  The hang armor (the Windows Store python stub was observed wedging
  live, and a hung PreToolUse hook hangs the whole session) is
  three-layered: GNU `timeout -k 5 10` around every python call (the
  wedged stub IGNORES SIGTERM — plain `timeout` waited forever),
  python stdout redirected to a FILE instead of `$(...)` (the stub's
  orphan child inherits the pipe handle and keeps `$()` waiting on EOF
  even after the kill), and a bounded `read -t 5` for the stdin
  payload.

Arm failures leave no fired marker (next interval retries) and after
`AUTO_ARM_MAX_ARM_FAILURES` (default 3) consecutive failures the hook
escalates to the one-shot exit-2 block anyway — "the safety net is
TORN, arm manually" — because a watchdog that sees the cliff must bark
even when its own legs are broken.

This is the *detect* half of HIMMEL-122 (the arm half is
`arm-resume.sh`). Boundary vs the HIMMEL-207 supervisor: the supervisor
parks the OWNER relaunch; this hook arms a WORK-session resume — both
funnel through the `HIMMEL-Resume-*` scheduler dedup.
Kill switch: `AUTO_ARM_DISABLE=1` in the launching shell.
Operational dependency: the statusline usage cache is only fresh while
the yotamleo/claude-statusline statusline is rendering — and on this
setup the statusline's stdin-rates path never rewrites the cache during
a live session, so the cache freezes at session start (observed
2026-06-10/11; the freeze is structural, the NORM on long sessions, not
a freak failure). The hook therefore does NOT quietly stand down on a
stale cache: past the escalation bound it safety-arms and blocks once
per session (the HIMMEL-275 path above). Expect the "STATUSLINE
WEDGED" block routinely on long sessions until the upstream statusline
fix lands.
Spec: `scripts/hooks/test-auto-arm-on-cap.sh` (paired smoke suite).

**Wiring (two layers, both shipped):**
1. **Project-level** — the `matcher: "*"` PreToolUse stanza in this repo's
   `.claude/settings.json` (operator-authorized 2026-06-10; the agent
   cannot self-add such a stanza — auto-mode classifies it as
   self-modification absent explicit operator specification).
2. **User-level (all repos)** — `scripts/machine-setup/win11.ps1` +
   `ubuntu.sh` register the hook in `~/.claude/settings.json` with an
   absolute himmel path (idempotent, prompt-gated, mirrors the
   end-session-wiki registration). The hook resolves its lib +
   arm-resume relative to its own location, so it works from any
   project's session — luna and <state-repo> sessions get cap protection
   too. NOTE: with both layers active, himmel sessions run the hook
   twice per tool call — harmless (the throttle marker is shared, so
   the second invocation is a single stat() no-op).

## Claude PostToolUse Hooks

One hook wired in `.claude/settings.json` fires AFTER a tool call completes.

### `auto-arm-on-subagent-cap.sh` — subagent-result cap watchdog (HIMMEL-276)

Closes the detection gap left by `auto-arm-on-cap.sh`: when the cap hits
MID-AGENT-WAVE, the main-loop's own tool calls keep succeeding (so the
PreToolUse hook never fires) while subagents return
`"You have hit your session limit"` as their tool RESULT text. The usage
cache (frozen at session start on this setup) also reads low, so both
existing detection paths miss the cap entirely — the session wakes up with
no armed resume and no handover.

**Detection sentinels** (case-insensitive substring match on the raw Agent
tool result text):
- `"you have hit your session limit"` — primary subagent cap string
- `"usage limit reached"` — alternate Claude cap phrasing

**On detection:** same arm + one-shot-block contract as `auto-arm-on-cap.sh`:
writes a mechanical status snapshot (via the handover-path resolver), calls
`arm-resume.sh --time smart --handover <snapshot>`, exits 2 (one-shot block
per session — the model is told: resume armed, write a handover now). The
session dedup uses a `sub-<sid>` marker key distinct from the PreToolUse
hook's markers, so both hooks can independently fire in the same session
without marker collision.

**Failure contract:** same WATCHDOG semantics as `auto-arm-on-cap.sh`
(fail-open — no bug in this hook may block tool calls):
- exit 0 → quiet pass (disabled, non-Agent tool, no sentinel, already fired).
- exit 1 → surfaced MALFUNCTION (missing arm bin, snapshot unwritable, py-armor
  missing, arm failed). Non-blocking.
- exit 2 → one-shot block; stderr to model.

**Kill switches:** `AUTO_ARM_DISABLE=1` (shared) or `AUTO_ARM_SUBAGENT_DISABLE=1`
(hook-only). Both must be set in the LAUNCHING shell.

Spec: `scripts/hooks/test-auto-arm-on-subagent-cap.sh` (paired smoke suite).

**Wiring:** `matcher: "Agent"` PostToolUse stanza in `.claude/settings.json`.

### `rtk-hook-guard.sh` — rtk rewrite wrapper (HIMMEL-241)

Not an enforcement hook — a fail-OPEN wrapper around the user-level
`rtk hook claude` PreToolUse rewriter (registered by `rtk init -g` in
`~/.claude/settings.json`). rtk rewrites bare `find …` commands to
`rtk find …`, but `rtk find` rejects compound predicates/actions at
runtime (`-not`, `-exec`, `-o`, `-a`, `-delete`, `!`, `\(…\)`) and
silently ignores `-prune` — which broke every LUNA runbook clip scan
(`find … -not -path '*/_synthesis/*' …`). The guard delegates to rtk,
extracts the rewritten command VALUE from rtk's JSON output (jq, with a
grep+sed fallback anchored on the `rtk find` value when jq is missing
or fails — HIMMEL-264), and suppresses ONLY a `rtk find` rewrite whose
command carries one of those tokens (empty hook output → the original
`find` runs unmodified through the normal permission flow). Simple
finds and all other commands keep rtk's rewrite verbatim — zero token
regression. Failure contract: rtk missing, crashing, or silent → exit 0
with empty output (rtk is an optimizer, never worth blocking a tool
call over); extraction failure on output that still contains an
`rtk find` rewrite → suppressed (an unscannable rewrite is never
forwarded — forwarding it would resurrect the original bug); extraction
failure on non-find output → forwarded verbatim (nothing the guard
screens).

**Wiring:** `docs/setup/settings-template.json` registers the guard
(`<himmel-path>` placeholder, resolved by the setup scripts), and
`scripts/machine-setup/win11.ps1` + `ubuntu.sh` swap every bare
`rtk hook claude` command in `~/.claude/settings.json` for
`bash "<himmel>/scripts/hooks/rtk-hook-guard.sh"` on each run — a
re-run of `rtk init -g` after a swap re-adds a raw entry, so the swap
is not gated on the guard already being present (HIMMEL-264).
Spec: `scripts/hooks/test-rtk-hook-guard.sh` (25 asserts; token set
verified against rtk 0.40.0). The ubuntu.sh swap/patch jq filters have
their own fixture spec, `scripts/machine-setup/test-ubuntu-settings-jq.sh`
(22 asserts, drift-guarded mirrors; the win11.ps1 PowerShell twin is
manually verified only).

**Standalone reconcile (HIMMEL-399).** The inline swap above only runs
inside full machine-setup, which invokes `rtk init -g` exactly once. When
an operator runs `rtk init -g` on its own it can stack duplicate bare
entries, and the swap by itself never collapses the result (guard + a
freshly re-added bare entry, swapped again, = two guard entries).
`scripts/lib/reconcile-rtk-hook.sh <settings-json> <himmel-path>` is the
on-demand reconcile: swap every bare `rtk hook claude` entry to the guard
AND collapse to exactly ONE guard entry, idempotently (spec:
`scripts/hooks/test-reconcile-rtk-hook.sh`, 16 asserts). Reconcile **user
scope only** — `rtk init -g` is global and the guard is an absolute path,
so a project-scope copy would only double-fire the hook. Expected
side effect: rtk identifies its own hook by the `rtk hook claude`
signature, which the guard wrapper replaces, so `rtk init --show` reports
`Hook: not found` and rewritten commands print a `[rtk] /!\ No hook
installed` banner to stderr — benign noise (the guard is installed and rewriting
works), with no rtk flag to quiet it. Do not "resolve" it by re-running
`rtk init -g`; that just re-adds the bare entry the reconcile removes.

### `check-platforms-tested.sh` — pre-push gate (`.pre-commit-config.yaml`)

Not a Claude PreToolUse hook — runs from the pre-commit framework at
`git push` time. Blocks pushes when the diff vs main touches any
cross-platform-sensitive path (`*.sh`, `*.bash`, `*.zsh`, `*.ps1`,
`*.psm1`, `*.psd1`, `*.cmd`, `*.bat`, anything under `scripts/`, or
`**/bin/*`) and no `Platforms tested:` line is present in a commit
body OR the open PR description.

The line must name at least one recognised token (case-insensitive):
`linux`, `windows`, `macos`, `mac`, `darwin`, `ubuntu`, `debian`,
`fedora`, `arch`, `wsl`, `posix`, `gitbash`, `git-bash`, `powershell`,
`pwsh`. Empty (`Platforms tested:`) and unrecognised
(`Platforms tested: yes`) values do NOT satisfy the gate.

Self-attestation only — the hook does not verify the claim, but the
gate forces the operator to think about Linux/macOS-vs-Windows before
push, which is where bugs like missing `shell:true`, `$Args` collision,
BOM mojibake, and `python` vs `python3` keep slipping through CR.
Bypass: `PLATFORMS_TESTED_OK=1 git push ...` or include
`[skip platforms-check]` in any commit message in the push range.

## Guardrails (`scripts/guardrails/`)

Shared shell library of git-state predicates consumed by THREE layers:
pre-commit hooks, Claude PreToolUse hooks, and himmel-gh slash commands.
Adding a new predicate to `scripts/guardrails/lib.sh` lights up across
all three call sites at once.

### Predicates (`lib.sh`)

- `is_on_main [DIR]` — current branch is `main`.
- `is_main_ref REF` — ref is `refs/heads/main` (for pre-push stdin contract).
- `is_dirty [DIR]` — worktree has any staged/unstaged/untracked changes.
- `is_merged_into_main [DIR]` — branch is merged via direct OR squash
  (cherry-pick equivalence via patch-id).
- `is_behind_origin_main [DIR]` — `origin/main` has commits not in HEAD.

Each returns 0 (true) / 1 (false). Internal errors return 2 — callers
MUST treat 2 as fail-closed. The `if predicate` form silently collapses
rc=1 and rc=2 into one branch and fails OPEN on errors; use the
`guard_call` helper exported from `lib.sh` (or `pred_check` inside
`guard-gh.sh`) for `if`-style consumption, or branch explicitly on `$?`
when finer control is needed.

### himmel-gh dispatcher (`guard-gh.sh`)

Consumed by `/gh-pr-create` and `/gh-pr-merge`. Verb/state matrix:

| Verb              | State                       | Action          | Override                         |
|-------------------|-----------------------------|-----------------|----------------------------------|
| `pr-create`       | HEAD == main                | refuse (rc=2)   | none                             |
| `pr-create`       | dirty worktree              | warn (rc=1)     | `--allow-dirty` flag             |
| `pr-create`       | branch merged into main     | refuse (rc=2)   | `--allow-merged-base` flag       |
| `pr-merge --admin`| any                         | refuse (rc=2)   | session env `GH_ADMIN_MERGE_OK=1`|

`rc=0` proceed, `rc=1` proceed-with-warning, `rc=2` refuse. Per the
bypass convention above, `GH_ADMIN_MERGE_OK=1` must be set in the shell
that LAUNCHED Claude — per-call prefix does not work because Claude
cannot inject env vars into hook processes.

The `--allow-*` flags are CONSUMED by the guard (stripped from argv
before forwarding to `gh`). `--admin` is INSPECTED but forwarded.

### Smoke tests

- `bash scripts/guardrails/test-lib.sh` — predicate behavior.
- `bash scripts/guardrails/test-guard-gh.sh` — dispatcher matrix.

Run after any edit to `lib.sh` or `guard-gh.sh` before pushing.

## Claude invocation billing (HIMMEL-128)

From **2026-06-15** onward, Anthropic splits headless Claude Code
invocations (`claude -p`, `claude --print`, `claude --bg`, Agent SDK)
onto a separate monthly Agent SDK credit bucket on Max subscriptions.
Interactive `claude "$prompt"` calls (no flag) stay on the regular
Max quota.

**Rule for scripts in this repo:** prefer interactive invocation —
arm-resume + similar cron/at/schtasks-spawned shells already use the
interactive form and are safe under the new billing. New `claude -p`
calls would silently start eating a separate credit bucket from
2026-06-15 onward.

The `no-headless-claude` pre-commit hook
(`scripts/hooks/check-no-headless-claude.sh`) enforces this. It
flags new `claude -p` / `--print` / `--bg` introductions unless an
opt-in marker is present:

```bash
# headless-claude-ok: <one-line reason>
claude --print "$prompt"
```

Same-line trailing comment works too. Exempt paths (no check):
`docs/`, `handovers/`, `.agents/` (vendored), `.claude/commands/*.md`
(slash-command docs), `CLAUDE.md`.

Refs: https://code.claude.com/docs/en/headless.md +
https://code.claude.com/docs/en/authentication.md.

## Operator conventions — worked examples

> The two operator conventions (layer-selection HIMMEL-177 +
> structural>instructional HIMMEL-195) keep their *directives* in
> `CLAUDE.md`. The illustrative examples live here.

### Layer-selection examples (HIMMEL-177)

The full rationale: **default to lean-invoke** because it keeps the cost
on the operator's side (one slash command when needed), which is the right
side — the operator knows when a rule applies; Claude does not. Adding
always-on rules without a trigger creates `default-rule` drift: CLAUDE.md
grows, operator + Claude both stop reading it carefully, rules silently
lose authority.

Examples per layer:
- **Safety-critical → `default-hook`** (the cost of forgetting to invoke
  manually is bigger than the cost of always running): `block-edit-on-main`,
  `block-read-secrets`, `no-headless-claude`, `gitleaks`.
- **Frame-shaping → `default-rule`** (changes how Claude reads the *entire*
  task): "PRs require approval", conventional commits, "prefer plugin over MCP".
- **High frequency × low marginal cost → `default-rule + installed skill`**:
  `/handover`, `/clean`, `/worktree`.
- **Eval-shaped → `defer`**: timeboxed ticket, close Won't Do on expiry. See
  the `feedback_jira_running_numbers` auto-memory for the anti-zombie protocol.

### Structural-escalation examples (HIMMEL-195)

Each was instructional first, escalated to structural after drift:

- **MCP-jira drift** — CLAUDE.md "prefer plugin" → auto-memory
  `feedback_jira_plugin_over_mcp` → auto-memory `feedback_jira_plugin_strict`
  (after second drift) → PreToolUse hook `block-mcp-when-plugin-exists.sh` +
  pre-commit `mcp-plugin-refs` gate (structural-pair — defense in depth).
- **Headless-claude billing (HIMMEL-128)** — CLAUDE.md "Claude invocation
  billing" section → pre-commit hook `check-no-headless-claude.sh` (after
  recognising the 2026-06-15 billing-split was an irreversible enforcement
  deadline, not a recommendation).
- **Edit-on-main** — operator preference → PreToolUse hook
  `block-edit-on-main.sh` (convention was clear, slip was cheap; the hook
  removes the slip surface entirely).
- **Secrets reads** — operator preference → PreToolUse hook
  `block-read-secrets.sh` (same pattern; the cost of one slip is bigger than
  the cost of the gate).

The rule: track the **drift count** per instructional rule. First drift is
signal; **second** drift is a structural escalation due — don't wait for the
third, by then the rule has lost authority and Claude is rationalising
bypasses. `default-rule` is fine as the FIRST layer; its next layer after
drift is structural, not "stronger CLAUDE.md prose." Prose does not enforce.
