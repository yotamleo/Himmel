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
  equivalent — see `block-backend-tier.sh` below).
- **Headless-claude gate (pre-commit):** no-headless-claude (blocks new
  `claude -p` / `claude --print` / `claude --bg` introductions unless
  the call has a `# headless-claude-ok: <reason>` marker on the same or
  preceding line — see "Claude invocation billing" below).
- **Dependency integrity (pre-commit):** npm lockfile-integrity,
  uv-lock-integrity, pip-hashes (requirements*.txt must use --generate-hashes).
- **Commit-msg:** conventional-commit-msg (validates conventional format +
  optional HIMMEL-N).
- **Doc-guard (pre-commit + pre-push, himmel-dev only):** check-doc-guard
  (blocks ADDING a command/skill file without a matching update to
  `docs/commands-catalog.md`; gated behind `.himmel-dev` marker so adopters
  are never affected — see `check-doc-guard.sh` below).
- **AGENTS.md-fresh (pre-commit, himmel-dev only):** check-agents-md-fresh
  (blocks committing a stale `AGENTS.md` when `CLAUDE.md` / `AGENTS.md` /
  `scripts/agents-md/*` is staged; `AGENTS.md` is generated from `CLAUDE.md` by
  `scripts/agents-md/generate.mjs` so the two never drift, HIMMEL-471; gated
  behind `.himmel-dev`; bypass `AGENTS_MD_OK=1`).
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

Seven hooks wired in `.claude/settings.json` fire BEFORE Claude executes
tool calls. Six BLOCK risky operations; one (`auto-approve-safe-bash`)
GRANTS permission for safe ones so they don't hang. An eighth and ninth
block hook, `block-docker-privesc.sh` (HIMMEL-441) and
`block-merged-pr-commit.sh` (HIMMEL-512), are shipped via the **himmel-ops
plugin `hooks.json`** rather than `.claude/settings.json` (so they can be
agent-installed without a settings self-mod veto — same delivery path as
`inject-minerva-critic.sh`); both are live only after `/himmel-update`
(marketplace re-sync) + a fresh session.

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

Fires on Edit/Write/MultiEdit/NotebookEdit. Refuses any edit targeting the
**primary checkout** of a repo — forcing all feature work into a worktree.
Two block cases: (1) the repo is on `main`/`master` (the original case), and
(2) **HIMMEL-507** — the repo is on a feature branch but the edit lands in the
primary checkout rather than a linked worktree. The structural signal for
"primary checkout vs worktree" is the `.git` entry: a normal checkout has a
`.git` **directory**, a linked worktree (and a submodule) has a `.git`
**file**. So an edit inside a `.claude/worktrees/…` linked worktree on a
feature branch is always allowed — that is where feature work belongs — while
the *same* feature branch checked out in the primary tree is blocked. This
closes the gap where an autonomous session did feature work on a PR branch in
the primary checkout instead of isolating it in a worktree. Paths are
canonicalised via `realpath -m` first, so `..` traversal and symlink tricks
cannot bypass. `handovers/**` is exempt. Bypass: `EDIT_ON_MAIN_OK=1` (covers
both block cases). Per-repo opt-out: place a local `.single-writer` file at the
repo root (gitignored via global excludes — never committed, so clones stay
protected by default); the hook then allows edits in that repo (both cases) and
skips the block entirely. Anchored to the edited file's repo (`repo_real`), so
a marker in a parent repo cannot leak the opt-out onto a nested repo.

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

### `block-rogue-claude-schedule.sh` — raw scheduler-arm guard (HIMMEL-647)

Fires on Bash/PowerShell. Refuses a tool call that registers an OS scheduler
job which launches claude **without** routing through the sanctioned arming
tools (`arm-resume.sh`, `pipeline-cadence.sh`, `schedule-resume.sh`). Blocks
when the command BOTH (a) registers a job — `schtasks /create`,
`Register-ScheduledTask`/`Register-ScheduledJob`, a `crontab` write, or
`at <timespec>` — AND (b)
launches the claude executable (`claude.exe`/`.cmd`/`.ps1`, a `/claude` or
`\claude` binary path, or a bare `claude "<prompt>"`). Bypass:
`ROGUE_SCHEDULE_OK=1`.

Why: a hand-rolled `schtasks /create … /tr <bat>` whose `.bat` is just
`"claude.exe" "load <handover> …"` (no `cd /d`, no Start In) fires with the
scheduler's default cwd `C:\Windows\System32`, so the relaunch runs OUTSIDE the
repo — a stray `~/.claude/projects/C--Windows-System32` project gets registered,
`block-edit-on-main` can't find `.git`, relative handover paths break, and the
autonomous run is wasted. `arm-resume.sh` already emits the
`cd /d "$RESUME_CWD" || exit /b 1` guard, pre-trusts the cwd (HIMMEL-386),
dedups and self-cleans; this guard forces scheduled claude relaunches back
through it.

**Known limitation (accepted):** only catches a rogue arm that writes the
launcher AND registers it in ONE tool call (the HIMMEL-647 incident shape). A
split across two calls — write the `.bat` in call 1, `schtasks /create
/tr that.bat` in call 2 — carries no `claude` token on the register call and
is not caught. Targets the accidental shape, not a determined bypass.

### `block-docker-privesc.sh` — root-equivalent container guard (HIMMEL-441)

Fires on Bash/PowerShell. Membership in the `docker` group is
root-equivalent: an agent in it can start a container as root and bind-mount
any host path writable, bypassing file permissions, `block-read-secrets`,
AND `block-edit-on-main` (the motivating case wrote `/etc` as root via
`docker run -v /etc:/host-etc:rw … install …`). Blocks `docker`/`podman`
`run|exec|create` (and `docker cp`) when it detects:

- **Secret-bearing bind-mount — any mode (`:ro` or `:rw`):** `/`, `/etc`,
  `/root`, the docker socket, `$HOME` itself, `$HOME` dotdirs
  (`.ssh .aws .gnupg .kube .docker .config`), and the Windows home tree
  `C:\Users\<user>`. `/home` is NOT a blanket prefix — `$HOME/Documents/proj`
  is allowed.
- **System-integrity bind-mount — writable only:** `/usr /bin /sbin /lib
  /lib64 /boot /var /sys /proc /dev` (read-only mounts leak no secret;
  a small read-only allowlist under `/etc` — `localtime`, `timezone`,
  `resolv.conf`, `hosts`, `ssl/certs`, `ca-certificates` — is carved out).
- **Privilege flags:** `--privileged`, `--pid=host`/`--pid host`,
  `--user 0|root` / `-u 0|0:* ` / `-u0` / `--user=0|root`, `--cap-add` of a
  root-equivalent cap (`SYS_ADMIN SYS_PTRACE DAC_OVERRIDE DAC_READ_SEARCH ALL`),
  `--device` of a host block device, `--volumes-from`.

Host paths are normalised first (expand `~`/`$HOME`; `$PWD`/relative →
project-local/allowed; Windows `\`→`/` with drive-colon-aware `-v` splitting;
collapse `/./`, `/../`, `//`, trailing `/`). Bypass: `DOCKER_PRIVESC_OK=1`.
Accepted limitations (header): `docker exec` into an already-privileged
container, `--volumes-from` re-mounts, env-substituted paths it cannot
resolve, `/proc/self/root`/symlinks, rootless podman (treated the same), and
a container COMMAND arg that literally equals a privesc flag (rare FP → use
the bypass). Spec: `scripts/hooks/test-block-docker-privesc.sh`.

### `block-merged-pr-commit.sh` — merged-PR branch commit guard (HIMMEL-512)

Fires on Bash/PowerShell. Blocks a `git commit` whose target branch has an
already-MERGED pull request on the forge. The signal is
`forge_pr_has_merged <branch>` from `scripts/lib/branch-shipped.sh` (via
`forge.sh`), which calls `gh pr list --state merged --head <branch>` and
returns a merge count.

**Fail-OPEN posture (hygiene guard, not a security boundary):** every
uncertain path exits 0 and lets the commit proceed — missing `jq`, unreadable
stdin, non-literal `cd` / `-C` arguments, detached HEAD, forge unreachable,
timeout (default 10 s), non-numeric payload. Only a positively confirmed
merged-branch commit triggers a block. The guard warns to stderr on
forge-unreachable paths so the uncertainty is visible without blocking.

**Bypass:** `MERGED_PR_COMMIT_OK=1` set in the shell that LAUNCHED Claude
(`MERGED_PR_COMMIT_OK=1 claude`) — follows the same session-sticky convention
as the other block-* hooks.

**Delivery:** shipped via the **himmel-ops plugin `hooks.json`** (same
exec-if-exists `$CLAUDE_PROJECT_DIR` pattern as `block-docker-privesc`);
live only after `/himmel-update` (marketplace re-sync) + a fresh session.

Paired artifacts: `scripts/lib/branch-shipped.sh` (predicate),
`scripts/hooks/test-block-merged-pr-commit.sh` (smoke suite).

### `block-lesson-enforcement-writes.sh` — lesson-loop write-fence (HIMMEL-767)

Fires on `Edit|Write|MultiEdit|NotebookEdit|Bash|PowerShell`, but only when
`HIMMEL_LESSON_LOOP=1` is set — the self-evolving lessons→tickets/draft-PR
loop is PROPOSE-ONLY, and this hook is the delivery surface that
structurally denies it enforcement-path writes: the agent file-tool surface
(`Edit`/`Write`/`MultiEdit`/`NotebookEdit` `file_path`/`notebook_path`,
exhaustive — the exact path is always in hand) plus the Bash/PowerShell
`command` surface, which as of **round 4 (HIMMEL-767) inverted from a
deny-list of write-shaped verbs to an allow-list of proven readers** —
rounds 1–3b kept enumerating one more write shape per adversarial-CR round
(glued redirects, attached `-t`, PowerShell aliases) with no sign of
convergence, so round 4 flips the default: a closed set of command-position
verbs PROVEN read-only (`cat`/`grep`/`ls`/`diff`/`wc`/`sed` without `-i`/
`find` without `-delete`/`-exec`/git read-verbs/script-executing
interpreters/PowerShell readers like `Get-Content`/`Select-String`/...) is
exempt from operand checking; every OTHER verb — `ln`, `truncate`, `mkdir`,
any PowerShell writer or its built-in alias, or a tool this fence has never
heard of — has every operand scanned as a write-target candidate, so new
write shapes no longer need individual enumeration. Two mechanisms sit
outside the verb check: redirect targets (`>`/`>>`/glued forms/`dd`'s
`of=`) always deny regardless of verb, and the git hook-routing shape-deny
(`core.hooksPath`/`include.path`/`includeif.*`, any of `git config`/`git
config --unset`/`git -c key=...`, each token stripped of one layer of
quoting before matching) runs unconditionally per clause. One deliberate
behavior change: the old `cp`-source read carve-out is gone — `cp` is not
proven read-only, so its source operand is a candidate too now (use
`cat`/`grep` to inspect an enforcement file instead of `cp`-ing it out).
**Round 5 (HIMMEL-767) closed four finite gaps in the round-4 model:**
(1) the interpreters are no longer unconditionally exempt — an inline-eval
flag (node/bun/deno `-e`/`--eval`, python `-c`, bash/sh `-c`, pwsh
`-Command`/`-c`/`-EncodedCommand`) makes the interpreter NOT exempt, and
the clause's raw text is scanned for an enforcement-path signal instead
(`python -c "open('scripts/hooks/x.sh','w')"` now denies; `python -c
"print(1)"` still allows; executing a script FILE — `bash
scripts/hooks/test-x.sh` — is still exempt); (2) the git hook-routing
shape-deny now resolves its git-clause head through the same
wrapper-skipping walk the general classifier uses, closing `command git -c
core.hooksPath=X commit`/`env git config --add include.path X`/`sudo
git ...`/`timeout N git ...`; (3) the standalone fd-prefixed redirect form
(`N>`/`N>>`) now accepts any number of digits, not just one; (4) the
leading `VAR=val` assignment skip accepts any letter-case, not just
lowercase. Full model + per-entry rationale:
[`docs/internals/lesson-provenance.md`](lesson-provenance.md#write-fence-deliverable-3).
Bare relative operands remain candidates regardless of `is_path_like`
(round 2, unchanged), anchored to the payload cwd. Every other session
exits before any parse — zero always-on cost (HIMMEL-177).

**Fail-CLOSED once active (deliberately, not the NARROW fallback some
sibling fences use):** with `HIMMEL_LESSON_LOOP=1` set, a missing `jq`,
malformed stdin JSON, or a missing fence sibling
(`scripts/guardrails/lesson-write-fence.sh`) all DENY — a fully-automated
loop worker has no human to mis-serve by refusing. Delegates to
`scripts/guardrails/lesson-write-fence.sh`, which classifies against the
deny-list policy `scripts/guardrails/enforcement-paths.json`; both the
posture and the deny-list classes are documented in
[`docs/internals/lesson-provenance.md`](lesson-provenance.md#write-fence-deliverable-3).

**Delivery:** shipped via the **himmel-ops plugin `hooks.json`** (same
exec-if-exists `$CLAUDE_PROJECT_DIR` pattern as `block-docker-privesc`);
live only after `/himmel-update` (marketplace re-sync) + a fresh session.
The plugin command itself fails CLOSED (exit 2) if the project hook script
is missing while `HIMMEL_LESSON_LOOP=1` (a stale checkout mid-loop), and
stays a no-op otherwise — round-3 CR fix, HIMMEL-767. The codex-lane
delivery (`.codex/hooks.json` → `run-hook.cmd` → `codex-hook-adapter.sh`)
already failed closed on a missing guardrail script before this fix (its
own precondition check), so it needed no change.

Paired artifacts: `scripts/guardrails/test-lesson-write-fence.sh` (111
checks), `scripts/hooks/test-block-lesson-enforcement-writes.sh` (9 checks).

### `block-glm-external-writes.sh` — GLM-lane external-write deny (HIMMEL-654)

Fires on `Bash|PowerShell|mcp__.*`. The deterministic classifier substitute for
third-party offload lanes, which have no auto-mode classifier and usually run
`--permission-mode bypassPermissions` (GLM workers via `spawn-glm.ts`,
`claude-glm` sessions). Detects the lane by `ANTHROPIC_BASE_URL` containing
`api.z.ai` (set by `glm-env.ts` `buildGlmEnv` / the `scripts/claude-glm{,.ps1}`
launchers, inherited by hook processes); off-lane sessions exit 0 on the first
env check — near-zero overhead, before the jq check.

On-lane it hard-blocks: `git push`, remote-URL rewrites (`git remote set-url`,
`git config …url` — keeps the poisoned-pushurl tripwire un-poisonable), the
`gh` CLI EXCEPT the issue-ops + pr/run-reads carve-out below (`gh pr
create/merge/edit/review/comment/ready`, `gh api`, `gh repo`, … stay blocked —
parent-session actions), network CLIs
(`curl`/`wget`/`Invoke-WebRequest`/`Invoke-RestMethod`/`iwr`/`irm`), and all
`mcp__*` tools except the qmd carve-out below (v1 chores are repo-local; a
blanket deny beats a write-verb list). `git commit`/`add`/`status`/`diff` and
`bun`/`npm install` stay allowed.

**Allowed on-lane (operator policy 2026-07-03 — audited-action carve-out):** the
**Jira CLI** (`scripts/jira/` path or a bare `jira`) — writes are audited in
Jira history and recoverable, so GLM workers may update status/comments and file
followup tickets; **qmd KB reads** (`mcp__plugin_qmd_qmd__*`, allowed before
the blanket `mcp__*` deny); and (HIMMEL-675) **`gh issue <anything>`** (full
issue surface, reads AND writes — cr-deferred followups are gh issues, audited +
recoverable) plus read-only **PR/CI context** (`gh pr view|diff|checks|status|
list`, `gh run view|list|watch`). The gh carve-out counts command-position gh
occurrences vs allowed ones, so a compound smuggling a denied gh past an allowed
one (`gh pr view 1 && gh pr merge 1`) still denies (total > allowed) — it shares
the command-position wrapper gap with the other arms. Atlassian MCP stays
blocked — Jira routing is CLI-first (`block-backend-tier` enforces that in every
session).

**Fail-CLOSED:** missing `jq` on the GLM lane blocks (parity with
`block-rogue-claude-schedule`). Command-position matching (start, or after
`; & | (` — not space/quote) keeps commit-message prose mentioning "git push"
from false-blocking. **Bypass:** `GLM_EXTERNAL_WRITES_OK=1` set in the shell
that spawns the worker (session-sticky).

Known limitations (accidental-shape guard, backstopped by the poisoned pushurl
tripwire + the parent CR gate — the two load-bearing controls): a wrapper that
displaces the command from command position is missed (env-prefixed
`FOO=1 git push`, `sudo`/`xargs`/`timeout`, the dashed `git-push`), and
in-process network is invisible (bun/node `fetch`, including the bun-invoked
telegram bridge send path).

**Delivery:** shipped via the **himmel-ops plugin `hooks.json`** (same
exec-if-exists `$CLAUDE_PROJECT_DIR` pattern as `block-docker-privesc`); live
only after `/himmel-update` (marketplace re-sync) + a fresh session, AND the
checkout workers branch from having pulled the merge. Spec:
`scripts/hooks/test-block-glm-external-writes.sh`.

### `block-backend-tier.sh` — service-agnostic backend-routing guard (HIMMEL-400)

Fires on `mcp__plugin_atlassian_atlassian__*` tool calls (and any other
MCP prefix registered in the registry). Routing is driven by
`scripts/backends.json` — a JSON registry with one entry per service,
each carrying `enabled`, `mcp_prefix`, `cli`, and `chain` fields.

**Default chain: `[cli, api, mcp]`** — the three registered services
(jira, bitbucket, github) all use this default. When a service's chain
ranks `cli` above `mcp`, the hook hard-blocks MCP calls that have a
known CLI equivalent (autogenerated blocked-set: the hook introspects
the CLI's `--list-commands` output and blocks iff the mapped verb is
present, so the blocked-set tracks the CLI without requiring hook edits).
The `api` tier is ADVISORY ONLY — it is a curl/WebFetch, not an
interceptable named tool, so it never triggers a hard block; it only
adds a one-line "prefer raw REST before MCP" note to the refusal message.

**Per-service bypass vars** (set in the shell that LAUNCHED Claude Code):
- `MCP_ALL_OK=1` — global, bypasses every service.
- `MCP_JIRA_OK=1` — Jira only (backward-compat alias).
- `MCP_<SERVICE_UPPER>_OK=1` — generic per-service (e.g. `MCP_GITHUB_OK=1`).

**Registry load order:**
1. `BACKENDS_REGISTRY` env var (test seam — file path).
2. `scripts/backends.json` at the repo root.
3. Code-level defaults baked into the hook (backward compatible — works
   without the JSON file).

Absent or malformed registry → warn to stderr + fall back to code
defaults (fail open on config read, fail closed on jq parse of the hook
INPUT itself).

**`block-mcp-when-plugin-exists.sh`** is now a thin shim that `exec`s
`block-backend-tier.sh` for backward compatibility with machines whose
`settings.json` still references the old filename. The hook in this
repo's `settings.json` was updated to point directly at the new file.

Pairs with the pre-commit `mcp-plugin-refs` gate, which catches the
same Atlassian MCP names in *committed* source files as defense-in-depth
if this PreToolUse hook is bypassed or disabled.

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

### `inject-minerva-critic.sh` — plugin PreToolUse(Skill) critic injector (HIMMEL-429)

The one PreToolUse hook NOT wired in `.claude/settings.json` (so it is not
counted in the "six hooks" above): it ships in the **himmel-ops plugin**
(`marketplace/plugins/himmel-ops/hooks/hooks.json`, `matcher: "Skill"`), so any
himmel-ops install gets it — himmel sessions and external installs alike — with
no repo wiring.

Closes the no-`/minerva` bypass. When `superpowers:brainstorming` or
`superpowers:writing-plans` is invoked by ANY path (auto-trigger, direct
`/skill`, sub-skill handoff) without going through `/minerva`, it injects a
scoped `additionalContext` directive so the model still runs the matching
minerva adversarial critic loop (spec-critic / plan-critic; `himmel-ops:minerva`
Stage 2 / Stage 4 charters). The invoked skill name is read at `tool_input.skill`
(field path confirmed by the HIMMEL-429 spike); per the CC hooks reference a
PreToolUse `additionalContext` is wrapped in a system reminder and inserted next
to the tool result, where the model reads it on the next request.

ADVISORY context, not a permission change — it cannot widen what any hook
allows. **FAIL-OPEN** (unlike the block-* hooks): it only ever exits 0 with
either the injection envelope or empty stdout, so it never blocks a Skill call
on its own error (a PreToolUse exit 2 would block the tool). Kill switch:
`MINERVA_HOOK_DISABLE=1` in the launching shell (bypass convention as above).
Paired smoke test: `hooks/test-inject-minerva-critic.sh`.

## Claude SessionStart Hooks

Wired in the `SessionStart` array of `.claude/settings.json`; fires once when a
session starts. Stdout on exit 0 is injected as additional context.
`check-update-available.sh` (the himmel-update nudge) also runs here. A third
SessionStart hook, `inject-where-are-we.sh` (HIMMEL-516, plugin-delivered via
the himmel-ops `hooks.json`), injects the relevant slice of the where-are-we
ledger; opt-in behind `HIMMEL_WHERE_ARE_WE`, fail-open and advisory.

### `inject-initiative.sh` — opt-in initiative mode (HIMMEL-425)

Default: OFF. When `HIMMEL_INITIATIVE=1` is set in the launching shell, the
session is given a scoped "drive to ship" directive so a normal session
proactively runs the `/pr-check` → open PR → transition ticket → handover
sequence at *natural completion points*, without the operator saying "ship it"
each time. Drains stdin; never blocks session start (always exits 0).

Master switch: `1`, `true`, `on`, `yes`, `all` (case-insensitive) → all four
parts. All falsy / unset values (`0`, `false`, `off`, `no`, empty) leave it
off — a byte-identical no-op, so default behaviour is unchanged.

**Per-part control (mirrors `CRITIC_PANEL_TIERS`):** set `HIMMEL_INITIATIVE`
to a comma-separated subset of the leg vocabulary
`plan,execute,prcheck,pr,ticket,merge,public,handover` (the master switch `all`
enables `prcheck,pr,ticket,handover`) to inject only those steps (e.g.
`HIMMEL_INITIATIVE=prcheck,pr` = run CR + open the PR, but don't auto-transition
the ticket or write the handover). Parsing is case-insensitive and
whitespace-tolerant (`PR, ticket` works); unknown tokens are ignored, and a
value that resolves to no recognized part is treated as off; steps always
render in canonical chain order regardless of input order. The directive
echoes the recognized tokens (`Active steps: …`) so a typo is visible
in-session. No dependency enforcement — a degenerate subset (e.g. `handover`
alone) just narrows the advice; the structural rails still apply, so it
degrades gracefully rather than doing anything unsafe.

The injected text is **advisory context, not a permission change** — it cannot
widen what the hooks allow. The rails still HARD-block: `check-cr-marker-on-pr-
create` gates `gh pr create` until a clean `/pr-check`; attestation trailers
must be in the FIRST commit; reactive `git commit --amend` and self-editing
`.claude/settings.json` to widen rules are still vetoed; **merge stays an
operator action** (the directive explicitly excludes merge).

Companion: `scripts/hooks/test-inject-initiative.sh` (paired smoke suite).
Sits alongside the bypass/opt-in flags (`EDIT_ON_MAIN_OK`, `READ_SECRETS_OK`,
`IMPROVE_ON_SUBMIT`) — all set in the shell that LAUNCHED Claude.

## Claude SessionEnd Hooks

Wired in the `SessionEnd` array of the himmel-ops plugin `hooks.json`
(exec-if-exists); fire once when a session ends. Stdout lands in the session
transcript (not operator-visible live). Coexist with any user-level SessionEnd
hook (e.g. `end-session-wiki`); Claude Code runs all registered SessionEnd
hooks. Alongside `refresh-where-are-we-on-end.sh` (HIMMEL-572):

### `jira-nudge-on-end.sh` — advisory Jira-update nudge (HIMMEL-618)

Default: OFF. When `HIMMEL_JIRA_NUDGE` is truthy (`1`/`true`/`on`/`yes`,
resolved from the launching shell OR the session repo's `.env`), this hook
emits **one** advisory line if a session committed work clearly tied to a Jira
ticket but made **no** Jira mutation that session — so the operator keeps the
tracker in sync. It is **advisory only**: it never performs a Jira write and
never blocks teardown (always exits 0).

Detection (ALL must hold, else silent no-nudge): a parseable transcript
first-timestamp (session-start epoch via `session-transcript.sh`); at least one
in-window commit (`git log --since=@<start>` — read-only sessions never nudge);
`JIRA_PROJECT_KEY` resolvable from the repo `.env`; the branch name OR an
in-window commit subject references `<KEY>-<N>`; and **no** jira-mutation
breadcrumb dated at/after the session start.

The breadcrumb is the "did this session touch Jira" signal: every mutating jira
CLI verb (`transition`, `comment`, `create`, `move`, `edit`, `assign`,
`worklog add`, `link`, `sprint`) calls a shared `writeJiraBreadcrumb()`
(`scripts/jira/src/breadcrumb.ts`) immediately after its mutating request
resolves — NOT gated on the command's exit code, so a mutation that landed
before a later non-fatal failure (e.g. an attachment upload) still counts. The
breadcrumb is a machine-global append-only log at
`~/.claude/jira-breadcrumbs/<repo-key>__<branch>.log` (line `<epoch>\t<TICKET>`),
keyed by the basename of `git remote get-url origin` (stable across worktrees,
so the CLI writer and the hook reader agree). Session-id keying is impossible —
the standalone CLI process never receives the Claude `session_id` — so the hook
matches on `epoch >= session-start`; residual cross-session suppression (two
parallel sessions on one ticket) is an accepted limitation. The reader path
lives in `scripts/lib/jira-breadcrumb.sh`.

Suppressed when the `ticket` initiative leg is active (`HIMMEL_INITIATIVE`
includes `ticket`) — that leg already injects the same reminder at SessionStart,
so this is the second advisory surface for when the leg is OFF, not a structural
backstop. The whole detection body runs **full-body detached** (HIMMEL-661,
same `__himmel_detached` re-exec pattern as `refresh-where-are-we-on-end.sh`):
the parent parks the SessionEnd payload in a temp file and returns in ~0.1s,
so in practice it no longer loses the teardown race ("Hook cancelled") — even
the gate-off path previously cost ~1.7s of process spawns on Windows Git Bash.
Nudge surface: the Telegram relay when configured (`TELEGRAM_BOT_TOKEN` +
`TELEGRAM_CHAT_ID`, or the `JIRA_NUDGE_RELAY_CMD` override) — the only
operator-reaching channel for an unattended session; the stdout print survives
only for direct child-mode invocation (`bash jira-nudge-on-end.sh
__himmel_detached <payload-file>` — tests or a manual debug run reproducing
that contract; a plain manual invocation goes through the detaching parent and
produces no stdout).
Paired hermetic suite: `scripts/hooks/test-jira-nudge-on-end.sh`.

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

### `check-doc-guard.sh` — doc-guard gate (`.pre-commit-config.yaml`, himmel-dev only)

Not a Claude PreToolUse hook — runs from the pre-commit framework at
`git commit` time (pre-commit stage) and at `git push` time (pre-push stage
via `--pre-push`). A `.ps1` twin (`check-doc-guard.ps1`) provides identical
behaviour in PowerShell-context hooks. HIMMEL-454.

**Trigger:** a command or skill file is ADDED (not merely modified) in any of
the watched source paths:
- `.claude/commands/**`
- `marketplace/plugins/*/commands/**`
- `marketplace/plugins/*/skills/**`

…without also touching `docs/commands-catalog.md` in the same change set.
The path → required-doc mapping lives in `scripts/hooks/doc-guard-map.tsv`
so the set of guarded paths can be extended without editing the hook.

**Added-only rationale:** the gate uses `git diff --diff-filter=A` and checks
only newly-added files. Modifications to existing commands/skills are not
gated — catalog decay on edits is acceptable friction; adding a wholly new
command/skill without a catalog entry is the primary gap this closes.

**`.himmel-dev` opt-in scoping:** the gate is himmel-CONTRIBUTOR-only. At the
top of each run the hook calls the `is_himmel_dev_repo` predicate in
`scripts/guardrails/lib.sh`, which returns true iff a `.himmel-dev` marker
file exists at the repo root. When the marker is absent the hook exits 0
immediately — downstream adopters who only run himmel as a harness are never
gated. `.himmel-dev` is gitignored (never committed to the repo), so a fresh
clone has no marker and the gate is inert by default. The
`scripts/himmel-update.sh --plugins-check` run emits a non-fatal
`warn_doc_guard_off` nudge when a himmel-source checkout (detected by the
presence of `scripts/hooks/check-doc-guard.sh`) lacks the marker, prompting
the contributor to create it.

**rc contract:**
- `0` — pass (marker absent, no new source files, or all additions paired
  with a catalog touch).
- `1` — violation: one or more new command/skill files have no corresponding
  `docs/commands-catalog.md` update. The hook prints the offending paths and
  blocks the commit/push.
- `2` — cannot-evaluate (fail-closed): git, awk, or another required tool is
  missing; the change set cannot be parsed. Blocks rather than silently passes.

**Bypass:** `DOC_GUARD_OK=1` set in the shell that LAUNCHED the git command
(`DOC_GUARD_OK=1 git commit …`). Per-call prefix works here because this is a
pre-commit script (not a Claude hook), so the env var is visible to the child
process. Test seam: `DOC_GUARD_FORCE_ERR=1` forces an exit-2 to verify
fail-closed behaviour; `DOC_GUARD_NO_FETCH=1` keeps the pre-push path fully
offline (skips any remote introspection).

**Pre-commit vs pre-push modes:**
- **Pre-commit (default):** inspects the staged set (`git diff --cached
  --diff-filter=A`). Paired doc touch must also be staged in the same commit.
- **Pre-push (`--pre-push` flag):** reads the push range `base...HEAD` and
  checks ALL commits in the range. A command added in commit 1 and the catalog
  updated in commit 3 of the same push PASSES — the gate only requires the pair
  to appear somewhere in the pushed range, not necessarily in the same commit.

Smoke test: `scripts/hooks/test-doc-guard.sh` (+ `.ps1` twin).

### Advisory doc-freshness detector — `doc-freshness.sh` (HIMMEL-587)

Companion to `check-doc-guard.sh` — advisory-only, never blocks. Ships
alongside the blocking gate as the "drift nudge" surface for doc staleness.

**4-column map (`scripts/hooks/doc-guard-map.tsv`):**

The map is now a 4-column TSV (`strength / trigger / path-regex /
`required-doc`); previously it held only two columns (`path-regex` /
`required-doc`):

- **`block` rows** — consumed by `check-doc-guard.sh` (and its `.ps1` twin on Windows) (unchanged behaviour):
  - `block / add / ^\.claude/commands/ / docs/commands-catalog.md`
  - `block / add / ^marketplace/plugins/[^/]+/(commands|skills)/ / docs/commands-catalog.md`
  - `block / add / ^marketplace/plugins/[^/]+/\.claude-plugin/plugin\.json / llms.txt` — new in HIMMEL-587: adding a plugin manifest requires a `llms.txt` update.
- **`advise` rows** — consumed exclusively by `scripts/lib/doc-freshness.sh`:
  - `advise / modify / ^scripts/hooks/ / docs/internals/enforcement.md`
  - `advise / modify / ^scripts/(jira|bitbucket)/ / docs/internals/jira-plugin.md`

**`scripts/lib/doc-freshness.sh` — the advisory detector.** Reads only
`advise` rows; double-filtered for near-zero false positives:
1. **Changelog scoping:** only files touched by a `feat`/`fix` commit in the
   range count as in-scope (chore / docs / refactor commits are excluded).
2. **Doc-presence suppression:** if the required doc itself changed in the
   range it is already updated — the row is silently skipped.

When both filters pass and a matched in-scope file is found, the detector
emits a tab-separated finding line (`source-file TAB required-doc TAB reason`).
It **always exits 0** — a broken advisory must never stall a session.

**Three legs, all gated by `HIMMEL_DOC_FRESHNESS`:**
- **`advise` leg** — `/pr-check` prints findings at review time (pre-push).
- **`session` leg** — `scripts/hooks/inject-doc-freshness.sh` (SessionStart
  hook) injects a `<system-reminder>` block over `origin/main...HEAD` at the
  start of each feature-branch session.
- **`morning` leg** — `generate-morning-briefing.sh` includes a freshness
  section in the daily morning report.

**`HIMMEL_DOC_FRESHNESS` grammar** (default OFF; grammar mirrors `HIMMEL_INITIATIVE`):
- `1` / `all` / `true` / `on` / `yes` — all three legs active.
- Comma-subset e.g. `advise,session` — only those legs; `morning` stays off.
- `0` / `false` / `off` / `no` / unset — all legs off.
- No `gate` leg — the hard blocking gate is `check-doc-guard.sh`, controlled
  by `.himmel-dev` + `DOC_GUARD_OK`.

Read from the himmel clone's `.env` by the `session` and `morning` surfaces
(via `scripts/lib/load-dotenv.sh`); the `advise` leg also reads `.env` at
`/pr-check` call time. A value exported in the launching shell or set in
`~/.claude/settings.json "env" {}` overrides `.env`.

**Bash-only — no `.ps1` twin.** There is no PowerShell execution path for
these three surfaces: `/pr-check` is a Claude slash command running in Bash,
the SessionStart hook is wired via Bash, and `generate-morning-briefing.sh`
is a Bash script.

Smoke tests: `scripts/lib/test-doc-freshness.sh`,
`scripts/hooks/test-inject-doc-freshness.sh`.

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

## Remote auto-actions — Telegram `/arm` (HIMMEL-424)

A sanctioned surface for the operator to trigger a bounded privileged action from
Telegram. Auth model **B2**: the **trusted bridge** (`scripts/telegram/`) parses a
structured command and invokes the action DIRECTLY — the spawned `claude` agent is
**never in the trust path**. So a conversational "resume HIMMEL-x" to the agent does
NOT arm anything; only the bridge-parsed `/arm` does. Auth = **operator-identity**: the
allowlisted operator (sender ∈ global `allowFrom`) sent a non-forwarded, typed `/arm`
in a DM **or an allowlisted group** — never body content an attacker could inject.

**Command:** `/arm <ticket|path> [at HH:MM | auto | smart]` (default `smart`).
A ticket (`^[A-Z][A-Z0-9]+-[0-9]+$`) resolves to a resume handover under
`handover_root` (case-insensitive, `specs/` excluded, `type: handover` preferred,
ambiguity refused — never silently picked); a path must exist and resolve **under**
`handover_root`. The bridge shells `auto-action.sh` → `arm-resume.sh` (per-handover
dedup; no `--force`/`--dedup-any` remotely).

**Activation flag — `TELEGRAM_AUTO_ACTIONS` (default OFF, operator-only).** A per-op
enable-list whose grammar **mirrors `HIMMEL_INITIATIVE`** (so users learn one
convention): unset / `0`/`off`/`no` → no ops (inert; `/arm` is ordinary chat);
`1`/`all`/`on`/`yes` → every op; else a comma-list of op names (case-insensitive,
unknown tokens dropped, pure-typo → off). v1 ships one op (`arm-resume`), so `=1`
and `=arm-resume` are equivalent. The dispatch-table keys (`OPS`/`KNOWN_OPS` in
`auto-action.ts`) are the closed op allow-list, re-asserted in `auto-action.sh`.
Set it in the bridge's launching env + restart the bridge to activate.

**Guards (fail-closed):**
- **Operator-identity** — an auto-command runs only when the SENDER is the allowlisted
  operator (`isAllowed(access, from)` — the global `allowFrom`). This authorizes `/arm`
  from the operator in a DM **or an allowlisted group** (groups carry distinct per-group
  context). A non-operator member of a shared group has a `from` not in `allowFrom`, so
  their `/arm` falls through to ordinary (powerless) chat. The chat is *also* already
  allowlisted upstream by `makeAllow` at ingest, so this is operator-identity on top of
  chat-allowlisting. The reply routes back to the originating chat (group → its own
  `group_<id>` session). (Earlier DM-only restriction relaxed for hardcoded
  operator-only groups; identity check keeps it safe if a third party ever joins.)
- **Typed-only** — a media-caption or voice-transcript `/arm` (`caption: true`) is
  not eligible; only a genuinely typed `m.text` command is.
- **Forward-refuse** — a forwarded `/arm` (any Telegram forward marker) is refused
  and audited (`refused-forwarded`); this kills the prompt-injection vector.
- The arm runs fire-and-forget off the ingest loop (a slow `--time smart` arm can't
  stall polling); the operator reply goes via the chat outbox + flush.

**Audit:** one append-only, sanitized line per attempt (executed OR refused) to
`bridgeRoot()/auto-action-audit.log`:
`<iso-ts> chat=<id> user=<id> fwd=<0|1> op=<op> arg=<arg> resolved=<basename> time=<t> rc=<n> result=<armed|already-armed|ambiguous|refused-forwarded|no-match|error>`.

**Still HARD-blocked (out of scope):** editing `access.json`/`settings.json`,
`--force`/`--dedup-any` arms, merging PRs, ops other than `arm-resume`.

Tests: `scripts/telegram/{router,auto-action,poller}.test.ts` (bun) +
`scripts/telegram/test-auto-action.sh` (privileged-script smoke).

## Claude invocation billing (HIMMEL-128)

From **2026-06-15** onward, Anthropic was to split headless Claude Code
invocations (`claude -p`, `claude --print`, `claude --bg`, Agent SDK)
onto a separate monthly Agent SDK credit bucket on Max subscriptions.
Interactive `claude "$prompt"` calls (no flag) stay on the regular
Max quota.

> **Status (as of 2026-06-21): the 2026-06-15 split is PAUSED.** Anthropic
> did not enforce the headless/interactive billing separation at the
> announced cutover; headless calls currently bill against the regular
> Max quota like interactive ones. The repo's interactive-first preference
> and the `no-headless-claude` gate are **kept in place anyway** — the
> pause is volatile and could re-activate without notice, so the cheapest
> posture is to stay interactive-by-default rather than churn the gate off
> and back on. Treat the rule below as "the policy if/when the split
> returns," not a description of today's billing.

**Rule for scripts in this repo:** prefer interactive invocation —
arm-resume + similar cron/at/schtasks-spawned shells already use the
interactive form and would be safe under the split. New `claude -p`
calls would silently start eating a separate credit bucket if/when the
split returns.

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
  (after second drift) → PreToolUse hook `block-backend-tier.sh` (originally
  `block-mcp-when-plugin-exists.sh`, generalised to registry-driven routing in
  HIMMEL-400) + pre-commit `mcp-plugin-refs` gate (structural-pair — defense
  in depth).
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
