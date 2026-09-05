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
- **`gh --json` field-name guard (pre-commit):** gh-json-fields (every
  literal `gh <sub> … --json a,b,c` in staged markdown/shell/ts/js is
  checked against the field list `gh <sub> --json __bogus__` prints —
  offline, no API call). A typo'd field makes `gh` exit 1, which callers
  report as a generic "cannot evaluate", so the guarded path silently
  never runs: that is how `/cr-public`'s HIMMEL-1202 bounded wait shipped
  polling the nonexistent `headRefSha` (HIMMEL-1288). Non-literal
  field lists (`--json "$FIELDS"`) and subcommands with no `--json`
  support are skipped; a missing `gh` skips the gate loudly rather than
  blocking the commit.
- **Headless-claude gate (pre-commit):** no-headless-claude (blocks new
  `claude -p` / `claude --print` / `claude --bg` introductions unless
  the call has a `# headless-claude-ok: <reason>` marker on the same or
  preceding line — see "Claude invocation billing" below).
- **Headless-gemini gate (pre-commit):** no-headless-gemini (mirrors
  no-headless-claude for `gemini -p` / `--prompt` / `--bg`; opt-in marker
  `# headless-gemini-ok: <reason>`; HIMMEL-157).
  Both gates exempt the root `CHANGELOG.md` (`is_exempt()`): it's fully
  generated from immutable commit subjects by `scripts/gen-changelog.sh`,
  so it can only RECORD a headless call, never introduce one, and its own
  opt-in marker can't survive regeneration (HIMMEL-2250). A nested
  `some/dir/CHANGELOG.md` is still checked.
- **Fork/template drift guards (pre-commit):** telegram-fork-drift (flags
  the vendored `telegram-himmel` fork drifting from the
  claude-plugins-official `telegram` version it's pinned to — fail-open if
  upstream isn't installed locally, fail-closed on detected drift; bypass
  `SKIP=telegram-fork-drift`), template-himmel-plugins (every
  locally-vendored `@himmel` marketplace plugin must be enabled in
  `docs/setup/settings-template.json`, the single list `adopt.sh`/
  `install-plugins.sh` installs from — fail-closed on drift), hud-drift
  (himmel-dev only — the vendored `claude-hud` tree must match its recorded
  pin in `marketplace/plugins/claude-hud/VENDORED.md`; bypass
  `HUD_DRIFT_OK=1`; HIMMEL-718).
- **Repo-integrity guards (pre-commit):** hookspath-misconfig (`core.hooksPath`
  must be unset or point inside the repo/`git-common-dir` — catches the
  HIMMEL-45 class of bug where hooks are silently skipped; bypass
  `HOOKSPATH_OK=1`), artifact-leakage (blocks newly-staged generated
  artifacts — `node_modules/`, OS junk files, a wrong-package-manager
  lockfile sitting next to a `bun.lock`; HIMMEL-371),
  graph-artifact-branch (scoped to `graphify-out/` — blocks staged graph
  artifacts unless the branch is `chore/graph-publish-*` or
  `GRAPH_COMMIT_OK=1`; HIMMEL-2167).
- **Settings portability (pre-commit):** settings-portability (a tracked
  `.claude/settings{,.local}.json` or `.codex/hooks.json` may carry no
  absolute user path — `C:/Users/`, `/Users/`, `/home/<name>/` — and no
  `.exe` in a hook `"command"`; a `"Bash(curl.exe:*)"` permissions entry is
  deliberately out of scope, which is why the `.exe` rule matches only
  `"command"` lines). The shape it exists to catch is written by a tool, not
  by hand: `graphify install` rewrites its own hook block in both files with
  a machine-absolute `graphify.EXE` path every time it runs, so a one-off
  cleanup does not hold and this gate is what catches the re-add on the next
  commit that stages either file. Both patterns self-test at startup — a
  regex that silently stopped matching would render as a clean pass on every
  commit (HIMMEL-2156; re-apply recipe in
  [`environment-gotchas.md`](environment-gotchas.md)).
- **Lane-inventory guard (pre-commit, himmel-dev only):**
  lanes-inventory-guard (blocks the lane inventory being re-added to
  CLAUDE.md prose — the inventory lives in `scripts/lanes/lanes.json`,
  queried via `/lanes`; HIMMEL-689).
- **Dependency integrity (pre-commit):** lockfile-integrity (npm + bun —
  every `package.json` under `scripts/` needs a tracked, in-sync sibling
  lockfile; for bun projects bun is resolved by `PATH` → `$BUN_INSTALL/bin`
  → `$HOME/.bun/bin`, because a hook inherits the invoking git's environment
  and never sees the `~/.bashrc` layer bun's installer writes to
  (HIMMEL-2439) — with no bun found the gate refuses only commits that stage
  something under the bun package and skips the rest, and the bun it does
  find must be a RELEASE build: a canary/prerelease bun fails
  `--frozen-lockfile` on a clean lockfile and the gate used to report that as
  bogus lock drift, HIMMEL-2010), uv-lock-integrity, pip-hashes
  (requirements*.txt must use --generate-hashes).
- **CLAUDE.md budget (pre-commit, himmel-dev only):** claude-md-budget
  (CLAUDE.md stays under its always-on byte budget; HIMMEL-2038).
- **Guardrail + fail-open-shape lints (pre-commit):** guardrail-matrices
  (egress + voice-policy invariants; HIMMEL-1522), fail-open-lint
  (fails-open-on-unknown shape lint; HIMMEL-1776).
- **Node-suite drift gates (pre-commit):** hook-lib-node-suites
  (`scripts/hooks` + `scripts/lib` node suites; HIMMEL-1578),
  trust-node-suites (`scripts/trust` node suites; HIMMEL-1589),
  profile-manifest-diff (plugin-profile manifest stays pinned; HIMMEL-2189).
- **Skill/command lints (pre-commit):** skill-description-cap (skill/command
  description stays within 120 chars; HIMMEL-2037), command-positional-args
  (no bare `$<digit>` in a command's fenced code; HIMMEL-2051),
  commands-catalog-drift (`docs/commands-catalog.md` Description column
  matches command frontmatter; HIMMEL-2064).
- **Oxlint ratchets (pre-commit):** oxlint-complexity-ratchet (no NEW
  function above the audited max; HIMMEL-2154),
  oxlint-hardening-zero-violations (bug-class hardening — zero violations;
  HIMMEL-2163).
- **Runtime pin (not a gate — `/himmel-doctor` C20):** the doctor FAILS (exit 1)
  when the running node major ≠ the `.nvmrc` pin, so the drift stops being
  rediscovered per session (HIMMEL-1986 → HIMMEL-2010). Downgraded to a
  non-fatal WARN under `$CI`/`$GITHUB_ACTIONS` and by the bypass
  `NODE_MAJOR_DRIFT_OK=1`. The doctor never edits `.nvmrc` and never switches a
  runtime.
- **Commit-msg / PR traceability (HIMMEL-1483, default-on HIMMEL-2442):**
  conventional-commit-msg validates conventional format and requires a ticket
  matching `TICKET_ID_PATTERN`, else the derived `JIRA_PROJECT_KEY-N` form,
  else `#[0-9]+` — himmel's own `#N` enumeration, which is the ticket system
  for a repo without Jira rather than a relaxed fallback. The ticket half is
  **ON by default**, including for an adopter with no `.env` at all;
  `TICKET_ID_REQUIRED=0` is the explicit opt-out. Merge/revert commits and the configurable comma-list
  `TICKET_ID_EXEMPT_AUTHORS` (default `dependabot[bot],dependabot`) are exempt.
  `propagate-public.sh ship/reship` defaults the same policy ON and checks the PR
  title and/or commit file before any push or PR creation.
  The `.pre-commit-config.yaml` entry must keep `pass_filenames: true` — the
  commit-msg stage's filename argument IS the message file. Handed none, the
  hook falls back to `.git/COMMIT_EDITMSG`; only when that fallback does not
  resolve to a readable file does it fail CLOSED (reject) rather than pass
  (HIMMEL-2461).
- **Doc-guard (pre-commit + pre-push, himmel-dev only):** check-doc-guard
  (blocks ADDING a command/skill file without a matching update to
  `docs/commands-catalog.md`; gated behind `.himmel-dev` marker so adopters
  are never affected — see `check-doc-guard.sh` below).
- **AGENTS.md-fresh (pre-commit, himmel-dev only):** check-agents-md-fresh
  (blocks committing a stale `AGENTS.md` when `CLAUDE.md` / `AGENTS.md` /
  `scripts/agents-md/*` is staged; `AGENTS.md` is generated from `CLAUDE.md` by
  `scripts/agents-md/generate.mjs` so the two never drift, HIMMEL-471; gated
  behind `.himmel-dev`; bypass `AGENTS_MD_OK=1`).
- **Template versioning (pre-commit + pre-push, himmel-dev only):**
  template-version / template-version-push (`check-template-version.sh`,
  `--pre-push` for the push-time twin) — template content change requires a
  `metadata.version` bump; HIMMEL-524.
- **Pre-push:** no-push-to-main, npm-audit (high+), npm-licenses (allowlist),
  npm-audit-signatures (needs npm >= 11 — older npm bundles a registry
  public key that expired 2025-01-29 and fails every package with
  EEXPIREDSIGNATUREKEY; the gate checks the version first and names
  `npm install -g npm@11` rather than surfacing the registry error,
  HIMMEL-2440), code-review-before-push (multi-agent CR via
  pr-review-toolkit), pr-mergeable-gate (refuses to push while the branch's
  open PR is CONFLICTING; bypass `SKIP_PR_MERGEABLE=1`; HIMMEL-136),
  no-force-push (hard-refuses a force-push to `main` with no bypass; warns
  but proceeds on a force-push to any other ref, bypass
  `SKIP_FORCE_PUSH_GATE=1` to silence the warning; HIMMEL-136),
  platforms-tested (cross-platform attestation for
  shell/script changes — see below), security-reviewed (security-review
  attestation for non-docs code changes; HIMMEL-176, see
  `docs/security-review.md`).

### Gates execute working-tree tooling — and the CI backstop (HIMMEL-1305)

**The convention: local gates judge the INDEX but run from the WORKING TREE.**
`check-debrand-coverage.sh` materializes the staged (or `HEAD`) copies of
`CLAUDE.md` and `debrand.json` into a tempdir and validates those — correct
about *what* is being committed. But it executes the generator
(`scripts/agents-md/generate.mjs`) from the working tree, as does every other
gate here with the helper it sources (`scripts/guardrails/lib.sh`) and with the
gate script itself (pre-commit reads it off disk).

So an unstaged edit to that tooling can approve a commit the edit is not part
of: stage a `CLAUDE.md` change that orphans a live debrand rule, separately
(unstaged) weaken the generator's coverage branch, and the gate passes on code
that is not in the resulting commit.

**Decision: keep working-tree execution; add a CI backstop.** Materializing
tooling from the index was considered and rejected — it does not actually close
the hole (the hook script and `lib.sh` are still read from disk, so a real fix
means materializing the *entire* hook chain from the index) and it would make
one gate the odd one out without changing the class. These gates are drift
guards, not a security boundary against local edits: anyone able to edit
`generate.mjs` unstaged can equally edit the gate.

The backstop is the layer that has the property for free. The `doc-invariants`
job in `.github/workflows/ci.yml` runs the SAME gate scripts against a clean
checkout, where committed source and committed tooling are the same tree by
construction. Mirrored there: `check-agents-md-fresh.sh`,
`check-debrand-coverage.sh`, `check-lanes-inventory.sh` — the gates whose
subject is a whole-tree invariant rather than a staged diff. `check-doc-guard.sh`
is deliberately NOT mirrored: it keys on files being *added* in a commit, so it
has nothing to assert about a clean checkout.

**Where that job actually runs — read this before relying on it.** GitHub
Actions is **disabled on the private repo by design** (`gh api
repos/{owner}/{repo}/actions/permissions` → `{"enabled": false}`); the
workflow is listed `active`, but nothing dispatches it and `gh run list` shows
only Dependabot. The deliberate split is **pre-commit locally, Actions on the
public mirror**, where Actions is enabled.

So `doc-invariants` gates the **public** tree after propagation, not the private
PR. On private, the pre-commit gates are the only enforcement — which is exactly
why the working-tree caveat above is a caveat and not a solved problem. The
public run still earns its keep: propagation is a re-projection and therefore an
independent diff surface, so it is where a CLAUDE.md/AGENTS.md/debrand
inconsistency would otherwise land unchecked.

Do not read a green private PR as evidence these gates ran — on private they run
only at commit time, on your machine.

**Three gotchas when adding to that job — all fail SILENTLY GREEN.** A gate that
no-ops is indistinguishable from a gate that passed, so a mistake here does not
break CI; it quietly removes the check.

1. **The `.himmel-dev` marker.** These gates are himmel-dev-only and no-op
   without the gitignored marker (which keeps them off for adopters). CI has no
   marker, so the job creates one first.
2. **The staging step.** These are *pre-commit* hooks — each triggers off
   `git diff --cached` and exits 0 when its inputs are not staged
   (`check-agents-md-fresh.sh` greps the staged names for `CLAUDE.md` /
   `AGENTS.md` / `scripts/agents-md/`; `check-debrand-coverage.sh` computes a
   `relevant` count the same way; `check-lanes-inventory.sh` is a one-line
   `grep -x 'CLAUDE.md' || exit 0`). A CI checkout's index is identical to
   HEAD, so **nothing is staged and all three no-op.** The job runs
   `git checkout --orphan ci-doc-invariants && git add -A` first: against an
   unborn HEAD, `add -A` stages the whole committed tree, so every trigger
   fires against committed bytes.

   The orphan is load-bearing, not stylistic. `git read-tree --empty &&
   git add -A` looks equivalent and is not — re-adding against the *real* HEAD
   rebuilds an index identical to it, leaving `git diff --cached` empty again.
   It appears to work on Windows only because CRLF normalization leaves
   incidental differences; on the ubuntu runner it stages exactly nothing.

   Because the orphan leaves HEAD unborn, **nothing after that step may clone
   the checkout** — cloning an unborn HEAD yields an empty worktree. That is
   why `test-ci-doc-invariants.sh` (which clones) runs *before* it.

3. **Never `grep -q` on the staged list.** Under `set -o pipefail`, `-q` exits
   at the first match and closes the pipe; the writer upstream dies of SIGPIPE
   and the *pipeline* reports 141 even though grep matched, so the trigger reads
   as "not staged" and the gate exits 0. It only bites once the staged list
   outruns the ~64KB pipe buffer — invisible on ordinary commits, and a
   fail-open on exactly the large ones you most want checked. Plain `grep`
   (output to `/dev/null`) drains the stream and is safe. This bit
   `check-agents-md-fresh.sh` and `check-lanes-inventory.sh`; it is also why
   the whole-tree staging above made them *look* broken.

Both are pinned by `scripts/hooks/test-ci-doc-invariants.sh`, which runs
before the staging step. It clones the repo (a fresh clone, not a linked worktree — a
worktree resolves the marker from the primary checkout and would not reproduce
CI), breaks the tree three ways, and asserts each gate blocks **with** the
staging step and is a **false green without it**. That second assertion is the
point: it fails the moment someone simplifies the staging step away.

The first version of this job shipped without the staging step and was caught by
the codex adversarial CR lane, not by CI — the job was green on a tree it had
never looked at. Verifying it by hand had the same blind spot: running the gates
in a clean worktree returns rc=0 whether they checked anything or not.

### Pre-push gate delivery — push from the branch's OWN worktree (HIMMEL-1574 / HIMMEL-1809)

The working-tree caveat above is sharper at **pre-push** time, because the
pusher's working tree and the pushed content are routinely different trees.
pre-commit's pre-push hooks (shellcheck, gitleaks, the attestation gates) lint
the tree at the pusher's cwd, never the commits on the wire — so pushing a
worktree branch from the primary checkout, which sits on `main` by design for
the whole lane workflow, lints **main's** copy of every file the branch touched.
Findings then cite line numbers the branch does not have (unreproducible by
running the linter directly, which is what made HIMMEL-1805 cost a full extra
lane round), and, in the common case, it fails **OPEN**: a branch whose touched
files are clean on `main` passes a gate that never inspected it.
`check-cr-before-push.sh` — the first himmel-owned pre-push stage, reached
through the `pre-push.legacy` shim while git's raw ref stream is still intact —
now refuses that shape before any other work: a push into `refs/heads/<b>` whose
commit is not this worktree's HEAD exits 2 naming both branches. Comparing the
SHA rather than the branch NAME is deliberate — it also catches
`git push origin <sha>:refs/heads/b`, `HEAD~3:refs/heads/b`, and a tag pushed
onto a branch, each of which lints a tree the push does not carry. Detached HEAD
refuses too. Deletes and non-branch destinations are exempt (no working-tree
content is claimed), a DIRTY working tree is a named, still-open ceiling, and
`PUSH_FOREIGN_REF_OK=1` in the LAUNCHING shell is the explicit bypass — it
accepts a gate result computed from the wrong tree. **So: `git -C <worktree>
push …`, not `git push <branch>` from the primary.** Note pre-commit OR-folds
the legacy hook's exit code (`retv | run(...)`) rather than short-circuiting, so
the configured hooks still run and their misattributed output still prints below
the refusal; the push is refused all the same. The shim itself is the delivery
seam and had its own hole: it resolved the gate via `git rev-parse
--show-toplevel`, which from a worktree is the WORKTREE root, so every worktree
ran its own base commit's copy and any pre-push hardening silently skipped
worktrees created before it. It now resolves the primary checkout (first entry
of `git worktree list --porcelain`, falling back to the `--git-common-dir`
parent) and fails closed if no gate is found there. **The shim is a file under
`.git/hooks/`, so it is not delivered by `git pull`** — re-run
`bash scripts/hooks/install-cr-pre-push-legacy.sh` (or `scripts/setup.sh` /
`scripts/setup-hooks.sh`, which call it) once per clone after this change.
Spec: `scripts/hooks/test-install-cr-pre-push-legacy.sh`,
`scripts/hooks/test-check-cr-before-push.sh`.

### Portable export — `.pre-commit-hooks.yaml` (HIMMEL-214)

Worktree isolation was structurally enforced only in himmel; other repos
the operator works in (notably luna) relied on prose. `.pre-commit-hooks.yaml`
at the repo root exports two gates other repos opt into via pre-commit's
remote-repo mechanism (`repo: https://github.com/yotamleo/himmel` +
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

## Prompt-stage Hooks (wired in NEITHER lane)

Covers both prompt-stage events: `UserPromptSubmit` (fires on submit, sees the
raw typed text) and `UserPromptExpansion` (fires when a slash command expands,
can block the expansion, and matches on `command_name`). **Neither event is
wired in either lane today** — the one script written against either ships
unwired, deliberately, because `.claude/settings.json` is operator-only.

**Neither `.claude/settings.json` nor `.codex/hooks.json` has a
`UserPromptSubmit` key** — no hook fires on prompt submit in either lane.
`improve-on-submit.sh` was deleted (HIMMEL-2006) after HIMMEL-708 dropped it
from the Claude settings as a no-op (#899) and HIMMEL-1981 dropped the
leftover Codex copy, which was costing a `pwsh`→`cmd`→`bash` spawn on every
Codex prompt to reach a guaranteed `exit 0`. (`inject-initiative.sh` is a real
Claude-lane hook, but it fires on `SessionStart`, not `UserPromptSubmit` — see
below.)

### `block-pr-check-args.sh` — `/pr-check` no-argument fence (HIMMEL-2306), SHIPPED UNWIRED

The one script in the repo written against a prompt-stage event. It refuses
`/pr-check` carrying any argument, so a stale `/pr-check <repo-path>` cannot
review the CURRENT repo — and clear ITS marker — instead of the one meant.
It fires on **`UserPromptExpansion`**, not `UserPromptSubmit`: that event
carries `command_args` as a first-class field, so the hook reads the argument
the harness already split out rather than parsing raw prompt text.

**CLAUDE LANE ONLY.** `UserPromptExpansion` is a Claude Code harness event.
`.codex/hooks.json` supports only `PreToolUse`, `PostToolUse`, `SessionStart`,
`SessionEnd` and `Stop` — there is **no prompt-stage event in the Codex lane at
all**, so this hook has nothing to attach to there and `/pr-check <path>` stays
silently ignored under Codex even after the Claude side is wired. The Codex
twin says so in its own words rather than inheriting the Claude runbook's
"refused" wording. Closing that half needs a Codex-side event that does not
exist today, or a different mechanism; it is tracked as unfinished, not done.

**It is INERT until an operator wires it** — `.claude/settings.json` is not
agent-writable, and as of this writing neither lane has a
`UserPromptExpansion` key either, so an unwired checkout still silently
ignores arguments:

```json
"UserPromptExpansion": [
  { "matcher": "pr-check",
    "hooks": [ { "type": "command",
                 "command": "bash \"$HIMMEL_REPO/scripts/hooks/block-pr-check-args.sh\"" } ] }
]
```

**Anchored on `HIMMEL_REPO`, deliberately not `CLAUDE_PROJECT_DIR`.** The rest
of the hook stack is wired through `$CLAUDE_PROJECT_DIR` because those hooks
guard work happening *in himmel*. This one does not: `/pr-check`'s supported
foreign-repo lane (HIMMEL-2035) is a session whose cwd IS the repo under
review, so there `CLAUDE_PROJECT_DIR` resolves to the REVIEWED repo — and
wiring a security hook through it would either execute a crafted repo's own
`scripts/hooks/block-pr-check-args.sh` as a hook, or point at a path that does
not exist so the guard silently never fires. `HIMMEL_REPO` arrives from outside
any repo (adopt/setup writes it into settings.json `env`) and a reviewed repo
cannot forge it. Same reasoning as HIMMEL-2226 Finding 1's `<himmel_dir>`
resolution: a guard must not be located by the thing it guards against.

Fails **closed** (security fence, not a workflow nudge): missing `jq`, invalid
JSON, or any unexpected rc exits 2. Wired with its matcher it only ever runs
for `/pr-check`, so that bounds the blast radius to that one command. Bypass:
`PR_CHECK_ARGS_OK=1` in the launching shell.

**Why a hook and not runbook prose:** HIMMEL-2226 tried twice in-prompt and
both were rejected on review. Anything that lets the runbook OBSERVE the
argument has already brought the untrusted value inside the boundary it is
defending — so the refusal has to happen before the prompt is assembled.

**Event-schema note for the next hook author (verified against `claude.exe`
2.1.251, which disagrees with the published docs on two points that each
produce a hook that silently never fires):** the payload fields are
`command_args` and `prompt` — there is no `command_input` and no
`expanded_prompt`; blocking is top-level `{"decision":"block"}` or exit 2,
because `hookSpecificOutput.permissionDecision: "deny"` is **PreToolUse-only**;
and the matcher compares against the bare `command_name` (`pr-check`, no
leading slash).

## Claude PreToolUse Hooks

**15 distinct guardrail scripts** are wired across the PreToolUse matchers in
`.claude/settings.json` (counted once each, regardless of how many `--chain`
matchers a shared guardrail appears under) and fire BEFORE Claude executes
tool calls: `auto-approve-safe-bash.sh`, `check-cr-marker-on-pr-create.sh`,
`block-jira-compound-write.sh`, `block-tail-pipe-on-gates.sh`,
`block-read-secrets.sh`, `block-destructive-commands.sh`,
`block-git-stash.sh`, `block-rogue-claude-schedule.sh`,
`block-chokepoint-env-prefix.sh`, `require-quiet-run.sh`,
`block-edit-on-main.sh`, `guard-memory-capture.sh`,
`orchestrator-inline-guard.sh`, `block-backend-tier.sh`, and
`auto-arm-on-cap.sh`. Thirteen BLOCK risky operations; one
(`auto-approve-safe-bash`) GRANTS permission for safe ones so they don't
hang; one (`auto-arm-on-cap`) is a fail-open watchdog that decides nothing.
Ten FURTHER guards — `block-docker-privesc.sh` (HIMMEL-441),
`block-merged-pr-commit.sh` (HIMMEL-512), `block-unresolved-cr-merge.sh`
(HIMMEL-936), `block-rogue-codex-wsl.sh` (HIMMEL-999),
`block-rogue-codex-exec.sh` (HIMMEL-2023), `guard-implementor-dispatch.sh`
(HIMMEL-920), `guard-console-dispatch.sh` (HIMMEL-2323),
`block-glm-external-writes.sh` (HIMMEL-654),
`block-graphify-egress.sh` (HIMMEL-621/622), and
`block-lesson-enforcement-writes.sh` (HIMMEL-767) — are shipped
via the **himmel-ops plugin `hooks.json`** rather than `.claude/settings.json`
(so they can be agent-installed without a settings self-mod veto — same
delivery path as `inject-minerva-critic.sh`, the plugin's Skill-matcher
critic INJECTOR rather than a guard, see its own section below); all ten
are live only after `/himmel-update` (marketplace re-sync) + a fresh session.
`block-docker-privesc.sh` and `block-merged-pr-commit.sh` fail CLOSED
(security boundaries); `block-rogue-codex-wsl.sh` and its native sibling
`block-rogue-codex-exec.sh` (raw `codex exec` outside
`scripts/codex/dispatch-codex-exec.sh` — no ACL preflight, no model/sandbox
pins, no job registry, and no watchdog, so a wedged raw run is exactly the
HIMMEL-1788 invisible hang; bypass `CODEX_EXEC_RAW_OK=1`) fail CLOSED only for
suspicious-token commands when jq is missing or parsing fails; `block-unresolved-cr-merge.sh` blocks when it can
evaluate but fails OPEN on every API/dependency error (HIMMEL-936 design);
`guard-implementor-dispatch.sh` is a COST guard and fails OPEN (see its own
section below); `guard-console-dispatch.sh` is a WORKFLOW fence and fails
OPEN (see its own section below); `block-glm-external-writes.sh` fails CLOSED on a detected
GLM lane (a missing `jq` blocks rather than allows — see its own section
below); `block-lesson-enforcement-writes.sh` fails CLOSED only once its own
loop seam (`HIMMEL_LESSON_LOOP=1`) is active (see its own section below);
`block-graphify-egress.sh` delegates its verdict to the shared corpus ×
provider × purpose policy rather than duplicating it here — see
[`egress-matrix.md`](egress-matrix.md).

**Bypass convention (applies to every guardrail hook that documents a bypass
env var — not all of them do):** session-sticky
env vars must be set in the shell that LAUNCHED Claude Code
(`EDIT_ON_MAIN_OK=1 claude`). Claude cannot inject env vars into hook
processes, so per-call prefix syntax does not work. Bypass lasts until
the Claude process exits — restart without the var to re-enable.
Alternative: comment the hook stanza in `.claude/settings.json`.
(`auto-approve-safe-bash` has no bypass — it only ever grants; to disable
it, comment its stanza.)

### Hook timeout policy + latency SLO (HIMMEL-1985)

**Every command hook in `.claude/settings.json` and in the himmel-ops plugin
`hooks.json` carries an explicit `timeout`.** An unset command-hook timeout
inherits Claude Code's 600 s default, so a wedged hook stalls the tool call for
ten minutes — and a PreToolUse command hook that times out fails **OPEN**, which
means the guardrail is silently skipped rather than loudly broken. Same hang
class HIMMEL-1982 fixed on the Codex side, pointed at our own stack.

Two tiers, sized from measurement (never guessed — a bound that can fire under
normal suite load is worse than 600 s):

| Tier | Timeout | Membership |
|---|---|---|
| **fast guard / injector** | `15` | nothing slow runs *inside the hook's own runtime*: string analysis, a registry read, at most one `py_armor` leg — **or** an outbound call that is `detach_run`-ed and therefore outside the bound |
| **synchronous external call** | `60` | the hook itself blocks on `gh`, `schtasks`, or ≥2 `py_armor` legs (each capped at `PY_ARMOR_TIMEOUT`, default 10 s) |

Both tiers size a **single** hook. A `--chain` entry (HIMMEL-2002) is bounded as
a unit, so it takes `60` once it has several members regardless of their tier —
the bound has to cover them serially, or the tail of the chain is skipped
fail-open. See the dispatcher section below.

The tier follows what the hook **waits on**, not what it ultimately causes.
`telegram-notification.sh`, `telegram-session-end.sh` and `jira-nudge-on-end.sh`
all reach the network, but every one of them `detach_run`s the `curl` and
returns — measured 176–234 ms — so they belong in the fast tier; bounding them
at 60 s would protect nothing.

60 s members: `block-edit-on-main.sh` (2 `py_armor` legs), `auto-arm-on-cap.sh` /
`auto-arm-on-subagent-cap.sh` (`py_armor` + `arm-resume.sh` → `schtasks`),
`trigger-cr-on-pr-create.sh` / `trigger-cr-on-push.sh` (`gh api --paginate` +
`gh pr comment`), `block-merged-pr-commit.sh` / `block-unresolved-cr-merge.sh`
(gh-backed `branch-shipped.sh` / `cr-merge-gate.sh` / `ci-green-gate.sh`).
Hooks that already carried an operator-chosen bound
(the 10 s ledger legs, the 10–30 s SessionStart injectors, the 10 s Stop hook)
keep it — all measured with ≥8× headroom. The same convention already lives in
`wire-hook-bash.mjs`, which splices new SessionStart siblings at `timeout: 30`.

### Claude PreToolUse dispatcher (HIMMEL-2002)

Twin of the Codex dispatcher (HIMMEL-1989,
[`harness-compat.md`](harness-compat.md)). Claude Code launched one
`node run-hook-with-bash.js <script>` per settings entry, and a Bash tool call
matched 13 of them. `run-hook-with-bash.js --chain a.sh b.sh …` runs the same
guardrails, in the same order, from **one** node process (Bash tool call: 13
matching entries / 11 launcher processes → 4 entries / 2 launchers).
**What drops is the node launches, not the Git Bash ones** — the members stay one
shell each by design (no extra wrapper shell), so the per-Git-Bash pool cost is
unchanged; only the launcher's own process count falls.

- **Matchers are disjoint** — `Bash`, `PowerShell`, `Read|Grep`, the Edit/Write
  family, the atlassian MCP matcher. Two matching blocks would re-multiply the
  launches, so `run-hook-with-bash.test.mjs` asserts pairwise disjointness over
  the literal tools they name (mirroring the parity gate's OVERLAP probe). The
  cost of disjointness is that a guardrail guarding several tools appears in
  several chains — `wire-hook-bash.mjs`'s `EXPECTED_SCRIPT_ORDER` is therefore
  the *flattened* document order, with those repeats, still frozen exactly.
- **Whole-chain validation first.** A missing or duplicated member denies
  outright (exit 2), before any member runs — never a prefix of the chain.
- **First deny wins and short-circuits**: a member's exit 2, or a deny expressed
  as JSON on exit 0, is emitted verbatim and ends the chain. Safe because every
  chained hook is a pure check. Side-effecting hooks **stay out of every chain**,
  so an earlier deny cannot suppress a side effect that used to happen
  unconditionally: `auto-arm-on-cap.sh` on its own `*` entry, and the PostToolUse
  `trigger-cr-on-pr-create.sh` / `trigger-cr-on-push.sh` pair, deliberately left
  as two sibling entries. Chaining that pair reads like one more launch saved,
  but it makes the push-triggered review reachable only if the PR-triggered one
  does not deny first — don't.
  Both post only on a **himmel-armed** repo (HIMMEL-2034, after the pair
  commented `@coderabbitai review` on an upstream PR opened from this machine):
  the PR's `owner/repo` must be this clone's armed origin (`git config --local
  himmel.coderabbit true`, `cr-available.sh`) or be named in `CR_TRIGGER_REPOS`
  (comma-separated `owner/repo` allowlist). Anything else gets a stderr advisory
  and no comment — the sanctioned review path for a foreign diff is the
  hermes/codex critic (`scripts/cr/critic-first-pass.sh`). The guard sits in
  `cr_trigger_post_review` (`scripts/lib/cr-trigger-ledger.sh`), the one seam
  both hooks and the forge seam post through.
- **Our stdout stays one JSON object or empty.** One JSON emitter passes through
  byte-for-byte; two or more merge (`ask` > `allow`, reasons joined with `" | "`,
  `additionalContext`/`systemMessage` with newlines, `continue:false`/`stopReason`
  from any member, any other key dropped with a stderr warning). A member's plain
  stdout goes to **our stderr**, and a non-blocking non-zero rc is carried only
  when no member decided.
- **`timeout` bounds the WHOLE chain, not each member** — a chain is **serial**,
  so the entry's budget is shared by every member. It is therefore sized for the
  chain, never taken as the max of its members: the members' 15 s fast-guard
  bound would become a 15 s budget for all ten of them, and a single slow member
  could burn it before the later security guards ever ran — a PreToolUse timeout
  fails OPEN, so those guards would be silently skipped. The multi-member chains
  sit at `60` for that reason (28× the measured p95, and no added worst-case wall
  clock: the `*`-matcher `auto-arm-on-cap.sh` entry already bounds every tool call
  at 60 s). See the SLO note below.
- **Each member is bounded too, and the bound is budget-aware.** The entry
  timeout alone still lets one hung member spend the whole thing, so the launcher
  gives every member the smaller of the 15 s fast-guard bound and what is left of
  its own 50 s whole-chain budget — floored at 500 ms, so a spent budget clamps
  the tail without starving it to a 0 ms slice (`RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS`
  / `RUN_HOOK_CHAIN_BUDGET_MS` override the first two). The floor is affordable by
  construction: worst case is budget + members × floor, so the 10-member Bash
  chain tops out at 55 s, still inside its 60 s entry. A member that outruns its bound is
  killed, **named on stderr, and skipped** — the chain continues, which is what
  happened before the collapse when Claude Code killed a hung *entry* and its
  siblings ran on. Deliberately not a deny: turning a slow guard into a hard
  block on the tool call is a worse failure than the one being bounded. The
  budget is what keeps the chain inside the entry timeout, so even a pathological
  run ends with the launcher reporting what it dropped rather than being killed
  mid-chain with the tail skipped silently.

**SLO: p95 < 1 s per hook.** Claude Code runs matching *entries* concurrently, so
the stack's cost is roughly the slowest matching entry, not their sum — but a
`--chain` entry runs its own members serially, so that entry's p95 is their sum
(measured 2026-08-22: the 10-member Bash chain 2.1 s p95, the 5-member PowerShell
chain 1.3 s, both `warn:slo`, both far inside their 60 s bound). Measured on
OVERLORD8 (2026-08-21, 5–7 runs each, serial): the ledger legs sit at ~60 ms and
the graphify `hook-guard` binaries at ~150–220 ms, but everything that spawns a
shell is **dominated by Windows process-start and therefore by whatever else the
box is doing** — the heaviest guards (`block-backend-tier.sh`,
`orchestrator-inline-guard.sh`, `auto-arm-on-*`, `guard-memory-capture.sh`) and
the tree-scanning SessionStart injectors (`inject-initiative.sh`,
`inject-where-are-we.sh`, `graphify-freshness-advisory.sh`) measured 0.3–0.9 s
p95 on an idle box, 1.1–1.7 s p95 with a critic panel running alongside, and up
to 2.2 s p95 with several benchmark and panel processes competing at once. Which
hook is slowest changes run to run; the ceiling does not. Under real concurrent
load (19 hooks at once) the ticket's live bench put the whole chain at 595 ms
median / 1.25 s worst. **That ~7× load spread is the whole argument for 15 s
rather than a tight 3–5× p95 bound** — it still leaves ≈7× headroom over the
worst thing ever observed here, and it is 40× better than the 600 s default.

**Per-tool spawn inventory (HIMMEL-2480).** Counted from `.claude/settings.json`
alone (plugin chains from `marketplace/plugins/himmel-ops` and claude-hud add
more on top, and this count excludes them):

| Tool | processes / call | graphify hook-guard's share | after pricing |
|---|---|---|---|
| `Bash` | 31 | 1 (3%) | 30 |
| `Edit` | 16 | 0 | 16 |
| `Read` | 7 | 1 (14%) | 6 |
| `Grep` | 7 | 1 (14%) | 7 |
| `Glob` | 4 | 1 (25%) | 4 |

Counting rule: one process for the entry's top-level interpreter, plus one more
when the command routes through `run-hook-with-bash.js` (the `bash -l` wrapper
then the node runner), plus one per `scripts/hooks/*.sh` chain member the
runner spawns serially. The `Bash` figure is dominated by the 11-member
`--chain` entry (13 processes) — the graphify guard is ~3% there and
irrelevant; it is the **only** extra spawn on `Read` and `Glob`, the
highest-frequency tools, which is why pricing targets those.

The gotcha: **`graphify install` re-adds the stock entries** (matchers
`Bash|Grep` + `Read|Glob`, no timeout, absolute exe path) and upstream exposes
no matcher/timeout knob. himmel never runs that installer itself, but the
operator is told to run it by hand in several places, so re-apply the pricing
afterwards with `bash scripts/lib/graphify-bin.sh price-hooks` (idempotent;
also drops the Codex `hook-check` no-op). Reproduce the counts with
`node scripts/hooks/bench-hook-stack.mjs` for latency and by reading
`.claude/settings.json` for the counts.

The bench spawns hooks through `run-hook-with-bash.js`'s `resolveBash()`, the
same resolver the wired hooks use: on Windows a bare `bash` can be the WSL
launcher or a 0-byte WindowsApps alias, which would time a different shell than
the session actually runs — or hang.

**Re-benchmark** (report-only, exits 0 — advisory, not a gate):

```bash
node scripts/hooks/bench-hook-stack.mjs --runs 7
node scripts/hooks/bench-hook-stack.mjs --runs 7 --settings marketplace/plugins/himmel-ops/hooks/hooks.json
```

It replays each configured hook with a representative **benign** stdin payload
(an `echo`, an empty agent result) — once per matcher alternative, with p50/p95
taken per branch and the **worst** branch reported, so a hook that branches by
tool is sized off its slow path rather than having it averaged away — redirects the
write-through hooks at a scratch dir via their own env knobs
(`HIMMEL_TRUST_LEDGER_DIR`, `HIMMEL_SESSION_RUNS_LEDGER`, `AUTO_ARM_BIN=/bin/true`,
`AUTO_ARM_STATE_DIR`), and hard-**skips** the hooks that emit something
**outbound and irreversible**: `trigger-cr-on-pr-create.sh` /
`trigger-cr-on-push.sh` (their dedup ledger is keyed per head SHA, so a replay
burns a real trigger slot) and `telegram-notification.sh` /
`telegram-session-end.sh` / `jira-nudge-on-end.sh` (a replay sends real
messages). The hook still inherits the caller's real environment, credentials
included — that is deliberate, since a hook stripped of `PATH`/`HOME`/git config
takes an error path in milliseconds and the measurement is a lie. Keeping `SKIP`
correct is **not** left to whoever adds the next hook remembering this benchmark
exists: the suite scans every wired hook's source — comments stripped, following
one hop into the `scripts/lib` helpers it names — for outbound-emission markers
(`api.telegram.org`, the `session-status.ts` relay, `cr-trigger-ledger`,
`gh pr|issue comment`, a `gh api` that names a write method or passes REST
fields, a `gh api graphql` carrying a `mutation`, a `curl` with
`-X POST`/`--data`) and fails if one is missing from `SKIP`. *Reads* are
deliberately not markers — replaying a `gh api` GET is harmless, and
`gh api graphql -f query=…` is a read despite the `-f` (that is simply how
GraphQL variables are passed; `cr-merge-gate.sh`'s reviewThreads query
false-positived on it) — and neither is
bare `gh pr create`, because this repo's hooks **guard** that command rather than
run it, so the string lives in guard prose and heredoc advisories (both
`check-cr-marker-on-pr-create.sh` and `inject-initiative.sh` false-positived on
it). It is a tripwire for the shapes that exist, not a proof of no egress; extend
the list when a new client shows up.

Read the `STATUS` column: `warn:failed` means a run spawn-failed, took a signal
or exited anything other than 0 (continue) / 2 (block) — exit 1 counts as a
failure here, because that is where a missing `jq` or a script bug lands, in a
few ms, and it would otherwise read as the fastest hook in the stack;
`warn:no-timeout` means a
hook is back on the 600 s default; `warn:tight` means its bound is under 3× its
own p95; `warn:slo` means it is over the 1 s per-hook SLO. `slowest_hook_p95_ms`
in the SUMMARY is the max across per-hook p95s, not a percentile across them —
the runner fires matching hooks concurrently, so the slowest matching hook *is*
what the session waits on. Re-run after adding a hook, or when the harness feels
sluggish, and update the tiers above if the shape moved.

The invariant is structurally pinned, not prose-enforced:
`scripts/hooks/bench-hook-stack.test.mjs` asserts that **no** command hook in
either config is left without a timeout and that every bound sits in the policy
band — and the pre-commit gate at `.pre-commit-config.yaml`
(`scripts/hooks + scripts/lib node suites`, HIMMEL-1578) already fires on edits
to both files.

### SessionStart chaining — `--chain --lifecycle` (HIMMEL-2003)

The dispatcher's SessionStart half. Block 1's four advisory injectors
(`check-update-available`, `inject-initiative`, `qmd-staleness-notice`,
`graphify-freshness-advisory`) each ran as its own node launch; `--lifecycle`
(which **requires** `--chain`) collapses them to one entry, one launcher.
SessionStart hooks are advisory — Claude injects plain stdout as context and
there is no permission gate — so the PreToolUse combining rules above are all
wrong here. Instead: member stdout is **concatenated** (newline-joined, document
order), member stderr is forwarded, and the chain **always exits 0**, so one
broken advisory can never silence its siblings or colour a session's startup.
Whole-chain validation still runs first and still fails closed, so a stale
checkout is loud rather than silently degraded. `timeout` becomes a single 60 s
budget for the whole chain instead of four per-hook bounds — 60 s because every
`--chain` entry must outlive the launcher's own worst case (the 50 s
`RUN_HOOK_CHAIN_BUDGET_MS` plus `members x` the 500 ms per-member floor), or
Claude Code SIGKILLs the launcher while it still believes it has time. Asserted
in `run-hook-with-bash.test.mjs`.

**The tradeoff is real.** As four entries the injectors ran *concurrently*
(p95 456 / 1301 / 938 / 1691 ms ⇒ ≈1.7 s wall); serial in one launcher makes it
their sum, ≈4.9 s. Bought: three fewer node launches at every session start.
Live smoke (OVERLORD8, 2026-08-22) measured 4.2 s wall, rc 0, empty stderr.

### `auto-approve-safe-bash.sh` — pre-Bash auto-approve gateway (HIMMEL-203)

Fires on Bash. Returns a `permissionDecision:"allow"` for read-only /
inspection commands so they run without a prompt — INCLUDING ones wrapped
in loops/pipes with `$var` expansion, which Claude Code's native matcher
refuses to match against the allow-list ("Contains simple_expansion") and
which are therefore DENIED at rc=0 in headless/auto — the prompt cannot
render, so it resolves as a silent no-op rather than a hang (HIMMEL-1969
probes, 2026-08-22). The matcher bails BEFORE
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
force-to-main as the ref-level backstop). `block-destructive-commands.sh` now
carries the matching branch-aware carve-out on the deny side (HIMMEL-2054) —
before that fix the deny hook refused every `--force-with-lease` shape
unconditionally, and deny/exit-2 wins over this allow, so the grant described
above was unreachable in practice.
Spec: `scripts/hooks/test-auto-approve-safe-bash.sh`.

### `check-cr-marker-on-pr-create.sh` — CR-marker-pending pre-PR-create guard

Fires on Bash. Blocks `gh pr create` — including one hidden inside `$(…)` or
backticks, matched only at command position (start of string, or right after
a `;`, `&`, `|`, backtick, or `$(` / `(`) — while a CR-pending marker file
exists for the branch. This is a plain regex scan over the extracted command
string, not a real shell parse: it correctly skips a plain string literal or
comment (`echo "gh pr create docs"`, `# TODO: gh pr create`), but a quoted
argument that itself contains one of those separator characters immediately
before the literal text — e.g. `grep -E 'x|gh pr create' file` — CAN still be
false-blocked, since the regex has no notion of quoting. The
marker (`<git-common-dir>/cr-pending/<branch>`) is written by
`check-cr-before-push.sh` on push and cleared through
`scripts/cr/clear-cr-marker.sh` when `/pr-check` runs clean. For an existing PR,
that chokepoint accepts only `check-ci.sh` exit 0. A stale CodeRabbit review
anchor (exit 4) can reach 0 through the existing clean exact-head critic-panel
ledger by DEFAULT now (HIMMEL-2162) — regardless of `scripts/lib/cr-high-risk-diff.sh`'s
classification of the changed-file list; a clean panel that reviewed THIS head
is the same evidence a fresh App review would be, high-risk diff or not. The
interim HIMMEL-1718 knob `CHECK_CI_FRESHNESS_CARRY_HIGH_RISK` is RETIRED — it
only ever gated whether the panel-carry check was reachable, never bypassed the
need for real panel evidence, so making the check unconditional left it with
no remaining job. Fail-closed is unchanged: no panel row at this head still
exits 4. Hooks, settings, guardrails, cadence, merge/CR gate, and pre-commit
surfaces stay blocked on that shape. A carried clear records
`carry=freshness-panel`, stale anchor, responders, and models in
`<git-common-dir>/clear-cr-marker.log` for durable provenance.
**Repo resolution is cwd-first (HIMMEL-2035).** The hook resolves the repo whose
marker it checks in this order: the payload's `.tool_input.cwd`, else `.cwd`,
accepted only when the path exists and is inside a git work tree; else
`$CLAUDE_PROJECT_DIR` under the same two checks; else `warn` + exit 0. Before
2035 it read `$CLAUDE_PROJECT_DIR` unconditionally, which was wrong in two
directions at once — a `gh pr create` in a foreign clone was **un-gated**, and a
himmel branch of the same name **false-blocked** it. Branch resolution is
unchanged: `--head`/`-H` wins (a `gh pr create` invoked from a worktree targets
a branch other than the resolved repo's own current branch — HIMMEL-213), else
the resolved repo's current branch. **Behaviour change for himmel's own
branches:** a PR created from a worktree *without* `--head` now resolves that
worktree's branch, so a real pending marker there now blocks where it
previously sailed through as an accepted missed block. That is a correct
tightening — the marker exists, so the block is true.

If the command carries `--repo <owner>/<name>` naming a different repo than the
resolved repo's `origin`, the marker for the PR's actual target is not locatable
from here: the hook emits one stderr advisory naming both nwos and exits 0
(fail-open). Same path when `origin` is absent or its URL does not parse — an
un-comparable pair must never block. A marker whose recorded SHA no longer
matches HEAD blocks as "stale marker — re-review needed" rather than silently
passing. Fails OPEN on any parse/lookup failure (missing jq/git, no branch
resolved, unreadable marker) — a missed block is cheaper than bricking
`gh pr create` on this hook's own bug.
Spec: `scripts/hooks/test-check-cr-marker-on-pr-create.sh`.

### CR gate outside the himmel checkout (adopters + upstream PRs) — HIMMEL-2035

A branch in **any** git repo an operator works in from a himmel session gets the
same structural CR evidence as a himmel branch. The whole design is one line:

> **cwd selects the repo; the resolved himmel checkout selects the himmel scripts.**

`$CLAUDE_PROJECT_DIR` is not that mechanism: it is unset in a Bash-tool shell
(Claude Code injects it into hook processes only, not into commands a session
or a runbook fence runs), and the worktree-isolation guard refuses outright
any command that references it (HIMMEL-2035, HIMMEL-2226).

The ledger (`ledger-append.sh`), the marker write (`check-cr-before-push.sh`),
the clear (`clear-cr-marker.sh`) and the pending audit (`cr-pending-audit.sh`)
all already resolve their paths from `git rev-parse --git-common-dir` of the
process cwd, so they land in the reviewed repo with no flag. **No `--repo` flag
was added to any of them** — it would be a second resolution source for a datum
git already answers. Regression fences: the foreign-repo cases in
`scripts/cr/test-ledger-append.sh`, `test-clear-cr-marker.sh` and
`test-cr-pending-audit.sh`.

**The one carve-out: `.env` is himmel's, not the target's.** The principle
governs *artifacts*, never *policy config*. `load_dotenv`'s default root also
follows cwd, so making cwd mobile would have made the gate read the **adopter's**
`.env` — silently dropping a `CR_REQUIRE_CROSS_MODEL=true` the operator set to
harden exactly these reviews, a fail-open introduced by the fix. Every
cwd-mobile `load_dotenv` therefore pins
`--root "$(_load_dotenv_primary_for <himmel-root>)"`. The wrapper is mandatory
and a bare `--root "$SCRIPT_DIR/../.."` (the script's own BASH_SOURCE-derived
root) is a trap: `--root` is a **silent no-op** when `<dir>/.env` is missing,
and the gitignored `.env` exists only in the primary checkout — never in a
linked worktree, where all feature work happens, and where the script itself
can just as easily be running from.

**Arming a repo** (lean-invoke; nothing auto-installs into a repo you did not
ask us to touch):

Run from the himmel **primary checkout** — the gate path below is baked in at
install time and must name the primary checkout, never a worktree:

```sh
bash scripts/cr/install-cr-gate.sh --target <path> [--remove] [--status] [--force]
```

It writes the target's **real** `pre-push` slot (not `pre-push.legacy`, which
only a pre-commit install chains) in the target's *effective* hooks dir
(`core.hooksPath` if set, else `<git-common-dir>/hooks`), carrying the owner
marker `# himmel-cr-gate-v1` and himmel's gate path **baked in at install
time**. The baked path names himmel's **primary checkout**, never a worktree —
a worktree path would brick every adopter's push gate the day `/clean_garden`
prunes it, fail-closed but invisibly, in *their* repo. Idempotent
(`installed` / `already-current`); refuses (exit 2, nothing written) on a
non-work-tree, on a foreign `pre-push` without `--force`, and on the himmel
checkout itself. `--status` reports `installed`/`absent`/`foreign`/`stale`
(0/0/1/1); `stale` means the marker is there but the baked path no longer
resolves — the remedy is re-running the installer, and the hook itself prints
it. The installer never runs `git config` on the target.

**Reviewing:** `/pr-check` takes no argument, ever (HIMMEL-2226, operator ruling
2026-08-31) — cwd selects the repo under review, so reviewing another repo means
starting a session whose cwd IS that repo and running a bare `/pr-check` there.
When the cwd is not a himmel checkout, the runbook's 0a-adopter step resolves
the himmel scripts from the `HIMMEL_REPO` anchor — wired into `settings.json`
`env` from a source OUTSIDE the repo under review — never from the reviewed
repo's own files. The baked `# himmel-cr-gate-path:` line the installer above
writes into the target's `pre-push` hook is not a resolution source: a
crafted repo could bake any path it likes into its own hook, so trusting it
back would be arbitrary code execution the moment 0b runs a script from the
resolved root. `pr-check-context.sh` then prints one
`repo=… branch=… base=… head=…` line so the transcript records which repo the
review certifies, and resolves the base from `origin/HEAD` in that repo.
**CodeRabbit runs only on an armed repo** — the same predicate
HIMMEL-2034 scoped the trigger hooks with (`cr_trigger_repo_armed`:
`git config --local himmel.coderabbit true` on a clone whose origin is that nwo,
or the nwo named in `CR_TRIGGER_REPOS`). Unarmed is an advisory
(`coderabbit=unarmed`), never a failure; the critic panel carries the gate.

**Host scope: GitHub only.** `clear-cr-marker.sh`'s post-PR gate requires `gh`
and treats an unreadable PR state as fail-closed, so on a Bitbucket/GitLab/
self-hosted origin gates 1–4 pass and the marker can **never** clear — worse
than no gate. The installer warns (never refuses) on a non-`github.com` origin
so an adopter learns at install time, not at their first blocked PR. Widening
this means a separate ticket against gate 5, not weakening it.

**When `core.hooksPath` points outside the repo.** The installer writes to
git's own effective hooks dir (`rev-parse --git-path hooks`, which honours
every config scope and expands `~`) — but only when that dir lives *inside*
the target repo. When it does not, at **any** scope (a global/system
`core.hooksPath`, or a repo-local one naming a shared or home directory), the
gate is installed into the repo's own `.git/hooks` regardless: writing into a
directory other repos share would arm repos the operator never named and
collide with whatever already owns that slot. The installer then reports which
of two situations it is in, because they differ completely:
- the shared `pre-push` **chains** to the repo hook (tokensave's
  `chain-repo-hook` shim is exactly this) → the gate fires; informational note.
- it does **not** chain → the gate is **installed but inert**, and the warning
  names both remedies the machine's owner runs themselves:
  `git -C <target> config --local core.hooksPath .git/hooks`, or adding a
  chain stanza to the shared hook. `install-cr-gate.sh` never edits git config
  or a machine-wide hook on anyone's behalf.

Known limitations (accepted, both fail-open by design):
- **`--repo <nwo>` divergence** — when `gh pr create --repo other/thing` targets
  a repo other than the resolved repo's origin, the hook advises and exits 0. A
  false block here is unrecoverable for the operator without a bypass.
- **The compound-`cd` shape** — `cd /foreign && gh pr create` in one Bash call
  may carry the pre-`cd` cwd in the payload, leaving that PR un-gated. The marker
  still exists and `cr-pending-audit.sh` still reports it. Parsing `cd` out of the
  command would be a tokenizer, which is explicitly out of this hook's scope.
  `/pr-check` itself no longer carries this exposure at all — HIMMEL-2226
  deleted its `<repo-path>` argument and the `cd` that argument fed, so there
  is no compound `cd` for anything to parse out of it: it takes step 0's cwd
  as-is (`git rev-parse --show-toplevel` of the process's actual working
  directory, not a text-parsed command line), which is unambiguous by
  construction. Only a bare manual `gh pr create` remains exposed to this
  limitation.
- **A throwaway clone's evidence dies with the clone** — the ledger and
  `clear-cr-marker.log` live in the reviewed repo. If durable evidence is needed
  for an upstream PR, put the audit line in the handover.

Spec: `scripts/cr/test-install-cr-gate.sh`, `scripts/cr/test-pr-check-pair.sh`.

### `block-jira-compound-write.sh` — jira write-shape bounce (HIMMEL-1077)

Fires on Bash. Jira CLI writes are sanctioned (HIMMEL-205), but approval is
decided on command SHAPE: wrap a sanctioned `create` in `$(…)`, a heredoc, or
chain it with a segment the gateway above cannot vet, and the gateway stays
silent — the write then falls through to the auto-mode classifier, which judges
it cold and denies it as "[External System Writes] unrequested publishing".
Incident (2026-07-16): two sanctioned creates denied inside a compound chain;
the identical creates as literal single commands auto-approved seconds later.
Root cause = shape, not permission (HIMMEL-203) — so per HIMMEL-195 the fix is
structural, not prose.

This hook turns that opaque denial into a deterministic bounce naming the ONE
sanctioned retry shape: reissue the SAME verb with the SAME arguments as one
literal command, moving any inline BODY to a file written with the Write tool
(verbs that carry no body — `transition`, `assign`, `watch`, … — just get
reissued literally). Naming exactly one shape is deliberate — the same incident
had paced retries across shapes read as "[Auto Mode Bypass]" tool-shopping.

The example names the verb the agent ACTUALLY used, never a substitute: printing
a `create` example for a blocked `assign` invites the retry to file a ticket
instead of assigning. Arguments stay "same as before" apart from what the shape
requires (`--desc-file` for `create`, `--comment-file` for `comment`, a
positional status for `transition`, no `<TICKET>` for `project-create`) — even
spelling out `--type Task` would tell a `--type Bug` retry to file the wrong type.

The named CLI path is the one INVOKED when that is absolute (another checkout may
front a different Jira, so its write must not be redirected here); only a
RELATIVE path resolves to this primary checkout via git-common-dir, because
`dist/` is untracked and the relative form dies `MODULE_NOT_FOUND` from a linked
worktree — a bounce whose "do exactly this" command cannot run would provoke the
very retry-across-shapes it exists to stop.

**Blocks iff BOTH hold:** the command invokes the Jira CLI with a WRITE verb
(`create|comment|transition|edit|link|assign|move|watch|unwatch|attach|
project-create|sprint|worklog add` — the first non-flag token after the CLI,
which must be the script `node` actually runs, in a simple command's command
position, matched against a quote-masked copy so a verb inside quoted DATA never
counts; the list is static rather than introspected because this hook fires on
EVERY Bash call — a missing verb only forfeits the guidance, it can never wrongly
block), AND
`auto-approve-safe-bash.sh` — consulted as a subprocess, so there is ONE safety
model and no forked copy to drift — declines to approve it. Whatever the gateway
approves runs untouched: literal single writes (bare or `cd`-prefixed), and
chains whose every segment the gateway vets, are never bounced. Read verbs are
never bounced. Fails OPEN (missing jq, unparseable input, a gateway that errors)
— a guard that only improves a denial message must never itself brick a write.

**Only PROVABLY UNCONDITIONAL writes are in scope** — the rule the whole design
turns on. The retry guidance is unconditional, so it must never be handed to a
write that might not run: anything after `&&`/`||`, inside an `if`/loop/`case`
body, or in a function definition is left alone, as are shapes the flat scanner
cannot justify a verdict on (multiple heredocs on a line, unparseable delimiters,
whitespace CLI paths, quoted verbs). Every such gap forfeits GUIDANCE only — the
write keeps its pre-HIMMEL-1077 classifier denial. What it must never do is
bounce a command that writes nothing, because the "do exactly this" message would
then order a mutation the command never made. Data that merely LOOKS like a write
is masked accordingly: quoted spans, comments, quoted-delimiter heredoc bodies,
array elements, arithmetic, and `${…}` expansions — while a top-level `$(…)`/backtick
substitution, which really does run, stays visible. The exception is a substitution
nested inside a `${…}` expansion (`${x:-$(cmd)}`): the flat scanner masks the whole
expansion, so that `$(…)` is masked too — a documented MISS (guidance forfeited on
that shape), never a wrong block.
Bypass: `JIRA_COMPOUND_WRITE_OK=1 claude` (launching shell).
Spec: `scripts/hooks/test-block-jira-compound-write.sh` (100 checks).

### `block-tail-pipe-on-gates.sh` — exit-code-swallowing pipeline deny (HIMMEL-1696)

Fires on Bash. Denies a pipeline whose FIRST stage INVOKES an exit-code-critical
himmel gate (`clear-cr-marker.sh`, `run-shell-tests.sh`, `check-ci.sh`,
`merge-on-green.sh`, `pr-merge.sh`, `scripts/*/test-*.sh`) and whose LAST stage
is `tail`/`head` — where `$?` is tail's status, not the gate's. A gate
orchestrator recorded `CLEAR_RC=0` when `clear-cr-marker.sh` had exited 16, so
it believed the CR gate had cleared when it had not. Invocation is decided at
COMMAND POSITION (leading `VAR=` assignments and a bounded launcher set are
stepped over), so `grep -n x scripts/check-ci.sh | tail` — a READ of the gate
script — passes. Intermediate stages are irrelevant; line continuations are
folded first; the correct shape it prescribes is
`<cmd> > <file> 2>&1; echo "RC=$?"; tail -80 <file>` (it also names
`${PIPESTATUS[0]}`). Fails OPEN on anything unevaluable. Bypass: a **same-line**
`# tail-pipe-ok: <reason>` marker (mirrors `# headless-claude-ok:`) — not an env
prefix, which `block-chokepoint-env-prefix.sh` would itself deny.
Spec: `scripts/hooks/test-block-tail-pipe-on-gates.sh`.

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

### `block-edit-live-settings.sh` — live-settings write guard (HIMMEL-2360)

Fires on Edit/Write/MultiEdit/NotebookEdit, plus a Bash arm for `>`/`>>`
redirect targets. Denies a write to a LIVE settings file — basename
`settings.json` or `settings.local.json` with an immediate `.claude` parent —
when EITHER it sits under `$HOME/.claude/` (the operator's user-scope live
config) OR its repo is the PRIMARY checkout: `git rev-parse --git-dir` and
`--git-common-dir`, both resolved to absolute paths, are EQUAL. A linked
worktree's git-dir lives under the primary's `.git/worktrees/<name>` and so
differs from git-common-dir — always allowed there.

**Replaces the two `Edit(**/.claude/settings.json)` /
`Edit(**/.claude/settings.local.json)` `permissions.deny` rules.** A plain
glob-deny rule cannot distinguish the primary checkout from a linked
worktree — gitignore-style glob semantics match at any depth, and the rule
is not scoped to which working directory the session is actually in — so it
also blocked a leg from editing the WORKTREE COPY of settings.json, a
harmless edit that only takes effect after that leg's PR is reviewed, merged,
and the operator relaunches. The discriminator is **git-dir ==
git-common-dir: protection follows repo layout, not machine paths.** A
second full clone of the repo elsewhere on disk has the same layout and is
therefore ALSO denied; a linked worktree is not.

**Workflow implication:** because a leg can now edit its own worktree's
settings.json, a hook-wiring change (the "three places" rule in
`scripts/hooks/CLAUDE.md`: script + `wire-hook-bash.mjs`'s
`EXPECTED_SCRIPT_ORDER` + `.claude/settings.json`) rides the OWNING LEG's own
PR — the operator no longer hand-edits `.claude/settings.json` inside each
leg's worktree for every hook-wiring change.

**Not a complete write fence** — covers the four file-editing tools plus
Bash `>`/`>>` redirect targets only; `sed -i`, `cp`, `tee`, and `mv` are NOT
covered. Bypass: `EDIT_LIVE_SETTINGS_OK=1` (launching shell only, same
convention as `EDIT_ON_MAIN_OK`).

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

**A quoted PATTERN is data, not a read target (HIMMEL-2213).** For the
grep-family (`grep`, `egrep`, `fgrep`, `rg`, `ripgrep`, `ag`) and the
sed/awk-family (`sed`, `awk`, `gawk`, `mawk`, `nawk`), a **quoted**
argument is exempt from the secret-path check in exactly **two positions**:
immediately after the bare command (zero flags in between), or as the value
of `-e`/`--regexp`. So `grep '.env' file.txt` — which searches `file.txt`
*for the text* `.env` — is allowed, while everything that genuinely reads
still blocks: `-f`/`--file`'s value — separate-token or glued — is always
a real file, and a `<`-redirect (`grep 'x' < .env`) is caught independently
of command position by the redirect arm.

The exemption is deliberately **positional** rather than "the first non-flag
argument", because deciding whether a token is a flag's operand or a genuine
pattern needs a per-flag arity table for every tool in both families — an
unbounded enumeration whose gaps are false *negatives*. The cost is an
accepted false positive: a pattern behind any other flag
(`grep -rn '.env' scripts/`, `grep -m 1 '.env' f`) still blocks. That is the
right direction — a false positive costs a cycle, a false negative leaks a
secret — and the denial names the two shapes that pass
(`grep '.env' -rn scripts/`, `grep -e '.env' -rn scripts/`), so the recovery
costs a message rather than a cycle. The tokenizer is quote-naive by design,
so a *multi-word* quoted pattern (`grep 'foo .env' f`) splits before the
quote check and can still false-block; the same recoveries apply.

**A glued option value is scanned too (HIMMEL-2228).** The tokenizer above
only ever matched whole shell words, so `grep --file=.env` and `grep -f.env`
(bundled `-rf.env` too) — which make grep genuinely open and read that file
as its pattern source — matched no secret glob and were allowed: a false
negative. `glued_opt_secret()` now splits a glued token at its first `=` or
`:` (or past a bundled short `f`) and scans the value half, in both the
outer clause and the HIMMEL-440 recursed `bash -c` body; PowerShell's
`-Param:.env` glue is covered by the `:` split.

The glued scan sits outside the positional exemption above, so a glued value
is never exempt — including `--regexp=.env` (whose separate-token form,
`-e '.env'`, IS exempt) and a glob value like `--exclude=*.pem`.
`sed --in-place=.env file.txt` denies the same way — a real in-place
rewrite that leaks nothing, but a glued value can't be told apart from a
genuine read target without per-tool knowledge. As with the 2213 false
positives above, that's the accepted direction, and the denial names both
the tradeoff and the recovery. The one exception is the existing armed state
doing its job: a token already consumed as a preceding `-f`/`-e`'s own value
is skipped (`grep -f --file=.env` opens a file literally named
`--file=.env`, not the secret).

### `guard-memory-capture.sh` — auto-memory capture guard (HIMMEL-570 / HIMMEL-1088)

Fires on Edit/Write/MultiEdit/NotebookEdit, scoped to the Claude Code
auto-memory store (`*/.claude/projects/*/memory/*`). The always-loaded
`MEMORY.md` index is O(themes), not O(facts): it carries one ≤200-char
**routing** line per theme, and the facts live in the theme **topic files** it
names (natively lazy-loaded). This guard enforces only the mechanically-
decidable **form** rules on that index — everything semantic (is this
status-only? does a theme already cover it?) is left to the model + the
`memory-compound` skill.

What it gates, by target:
- **`MEMORY.md`** — (1) any `- ` pointer line >200 **characters** → deny; (2)
  more than ~60 pointer lines → deny (the structural ceiling on `n`, the
  O(facts) backstop); (3) net growth >400B in one write → deny (raises evasion
  friction, does not close it); and it logs a **line-count-delta tripwire** on
  every allowed write. The char rule pins `LC_ALL=C` and then counts characters
  explicitly — it drops UTF-8 continuation bytes (`\200-\277`) before measuring
  length, so the count is exact with no locale and no UTF-8-aware `awk`. (This
  env has no `LANG`/`LC_ALL` by default, which made `awk length()` count bytes,
  not chars: a multibyte routing-line character like an em-dash could
  false-deny a compliant line. Asking for a UTF-8 locale instead would bet on
  one existing — glibc lists `C.utf8`, macOS/BSD have no `C.UTF-8` — and on
  `awk` honouring it, which mawk does not. HIMMEL-2011.) `Edit`/
  `MultiEdit` to `MEMORY.md` are **decidable**: `simulate-memory-edit.js`
  applies the payload's replacement(s) (`MultiEdit`'s `edits[]` sequentially;
  first occurrence unless `replace_all`; an `old_string` not found → allow, the
  Edit tool itself errors on that) against the on-disk file, and the RESULT
  runs through the same three checks as `Write` — one code path, so the rules
  cannot drift between `Write` and `Edit`. `NotebookEdit` is still denied — its
  payload doesn't reveal the resulting content, so the guard forces a
  whole-file `Write` it can inspect.
- **topic files** — the tier-2 landing spot; **unrestricted** (no body cap,
  `Edit` allowed). This is what makes capture always work.
- **`*.bak`** — exempt (compound writes a ~25KB backup by design).

Adopter story is **unconditional**: no vault/qmd predicate. A machine with no
substrate still gets index form-gating (the rules are pure form) and still
captures freely into topic files.

Semantics: **deny = exit 2** with a retry contract on stderr (shown to the
model: "append the durable body to the theme topic file the index routes to,
then retry with a ≤200-char routing line"). Never `ask` — `ask` hangs
unattended sessions. Every deny is logged to `.capture-log.jsonl` (append-only
JSONL: hash + ≤120-char excerpt + target + `lines_delta` + lane), the input to
the decoupled capture audit. The deny-log excerpt reads `.new_string` as well
as `.content`, because the index append fires as an `Edit` (measured in the
Phase-0 spike, HIMMEL-1086) — without the fallback every routine deny would log
empty.

Bypass: `MEMORY_CAPTURE_OK=1` — checked **first**, before any deny branch, and
**restart-only** (set in the launching shell; a per-call prefix does not reach a
running session). **Compound is NOT bypass-exempt** — binding compound's own
output to the 200-char rule is the point (the 2026-07-16 pass emitted a
1,472-char "pointer" line; `*.bak` covers its backup). Optional advisory on
allow via `MEMORY_GUARD_ADVISORY=1` (default off; the spike verified
`additionalContext` reaches the model but arrives *after* the write, so it is a
next-action nudge, not a pre-action steer).

### `block-destructive-commands.sh` — deterministic destructive-command floor (HIMMEL-754)

Fires on Bash/PowerShell. Shared floor with the Codex lane — ports the
`TERMINAL_DESTRUCTIVE` command classes from
`scripts/hermes/assets/parity_guard.py` — blocking catastrophic/
shared-machine/irreversible shapes at COMMAND POSITION regardless of
tool-permission config: recursive `rm` / Windows `del`/`erase`/`rd`/`rmdir`,
disk/boot mutation (`format`/`diskpart`/`bcdedit`/`mkfs`), disk wipe
(`cipher /w`), scheduled-task mutation recognized by CAPABILITY rather than by
spelling (HIMMEL-1821: `schtasks` mutating verbs, the PowerShell
ScheduledTasks module's write cmdlets — `Register-`/`Unregister-`/`Set-`/
`Start-`/`Stop-`/`Disable-`/`Enable-ScheduledTask` — and the
`Schedule.Service` COM object, while the read-only diagnostics `schtasks
/query` + help/no-verb forms, `Get-ScheduledTask`, `Get-ScheduledTaskInfo`,
`Export-ScheduledTask` and the in-memory builder cmdlets
`New-ScheduledTask`/`-Trigger`/`-Action` stay allowed, HIMMEL-1141),
process termination (`taskkill`/`Stop-Process`/
`pskill`/`kill -9`), system shutdown/reboot/logoff, Windows registry
mutation, permission mutation (`icacls`/`takeown`), `git push --force`/`-f`,
`git reset --hard`, `git clean -f`, `git filter-branch`, and remote-exec
pipes (`curl`/`wget … | sh`). `git push --force-with-lease` is branch-aware
(HIMMEL-2054): refused when it targets main/master/the resolved default
branch (`git symbolic-ref refs/remotes/origin/HEAD`, main/master fallback),
names no explicit branch at all (ambiguous → refused), the literal `HEAD`
or its `@`/`@{...}` shorthand (a symbolic ref this hook cannot statically
resolve → ambiguous → refused), a branch argument containing a shell
variable/command-substitution sigil (`$branch`, `` `cmd` `` — this hook only
inspects the command STRING and never executes it, so a runtime value is
unresolvable → ambiguous → refused), a wildcard refspec dst
(`refs/heads/*:refs/heads/*`, which can match
main/master), the bare `:`/`+:` "matching" refspec (empty branch after
parsing — can force-update any locally-matching remote branch, including
main), a remote other than `origin` (the only remote this hook can
resolve a default branch for), or a `cd` chained anywhere in the command
(default-branch resolution is scoped to the hook's own cwd, not wherever a
prior `cd` selected); granted to any other explicit branch or
`<branch>:<branch>` refspec on `origin` — this is the deny-side half
of the `auto-approve-safe-bash.sh` HIMMEL-212 carve-out below, which the
blanket deny used to make unreachable. Branch tokens are quote-stripped (one
matching outer pair of `'…'`/`"…"`) before comparison, so a literally-quoted
branch name — which a real shell strips before git ever sees it — is judged
the same as its unquoted form. Default-branch resolution strips only
the fixed `refs/remotes/origin/` prefix, so a default containing its own
slash (e.g. `release/stable`) still matches. A bare force flag is refused
even clustered inside a short-option bundle of git push's other clusterable
boolean flags (`-vf`, `-fv`, `-4f` — not an attached `-o` push-option value
like `-ofoo`), not just standalone `-f`, and the lease flag is matched from
its shortest unambiguous
git-accepted abbreviation (`--force-w`) through the full spelling, not just
the exact `--force-with-lease` string. A `+`-prefixed refspec (git's own
unconditional force marker for that one ref, e.g. `origin +main`) is denied
like a bare force flag — regardless of which branch it targets, and
regardless of whether `--force`/`--force-with-lease` appears anywhere in the
command at all, since a `+` refspec carries no server-side safety check of
its own; this also covers a lease scoped to one ref (`--force-with-lease=main`)
leaving a *different* `+`-prefixed refspec in the same push unprotected.
Recognizes a bounded set of launcher wrappers
(`sudo`, `env`, `cmd /c`, `powershell`/`pwsh -c`) and an executable-path
prefix, so a wrapped or path-qualified form (`/usr/bin/env rm -rf /`,
`C:\…\format.exe`) is refused like the bare name. Routine git/gh/mv/cp,
non-recursive `rm`, `curl` without a remote-exec pipe, and normal
`git status`/`commit`/`push` are all allowed.

Deliberately NOT a general shell parser: quoted-payload wrappers (`bash -c
"rm -rf /"`, `xargs`, `nohup` chains) are an accepted residual gap — this
hook plus the auto-mode classifier are the outer defense layers, not an
arms race against every wrapper permutation. Fails CLOSED on missing `jq`
or malformed/truncated JSON (a security floor, not a convenience hook — the
EXIT trap also converts any unexpected top-level failure to a block rather
than a fail-open rc=1). Bypass: `DESTRUCTIVE_OK=1` (launching shell,
session-sticky). Spec: `scripts/hooks/test-block-destructive-commands.sh`.

### `check-hook-file-parse.sh` — write-time hook-file parse guard (HIMMEL-2230)

> **WIRED (HIMMEL-2248).** Registered in `.claude/settings.json` and in
> `wire-hook-bash.mjs`'s `EXPECTED_SCRIPT_ORDER`;
> `node scripts/hooks/wire-hook-bash.mjs --check` proves the two agree. It shipped
> INERT under HIMMEL-2230 and was live only once that wiring landed — an
> unregistered hook script does nothing at all.

PostToolUse on `Bash|Edit|Write|MultiEdit|NotebookEdit` — it joins the existing
block with that matcher rather than adding a fourth PostToolUse launch; a `Bash`
tool call writes no file, so the extra arm is a no-op for it. Runs
`scripts/lint/hook-parse-check.sh` — the `[parse]` (`bash -n`) and
`[quote-break]` checks — against a written file whose path is under
`scripts/hooks/` and ends in `.sh`; exits 2 with the finding on stderr,
otherwise 0.

WHY IT IS A WRITE-TIME HOOK and not another commit gate: a file under
`scripts/hooks/` is LIVE the instant it is saved — the next tool call executes
it. The motivating incident put a prose apostrophe inside a single-quoted `awk`
program, which ended the shell string; the hook stopped parsing, exited
non-zero on every invocation, and denied EVERY command fleet-wide, benign ones
included. It never reached a commit, so the pre-commit `shellcheck` gate and
`scripts/lint/shell-lint.sh` were both out of the path by construction —
scanning every reachable revision of that file confirms it (zero committed
revisions ever failed `bash -n`). Commit-time linting cannot catch this class;
only write-time can.

Scope is deliberately narrow — at or below `scripts/hooks/`, ending in `.sh`
(the `case` glob matches a nested subdirectory too, not just a direct child) —
so it stays cheap enough to run on every write. The path test folds `\` to `/`
first — the Windows lane delivers the same file as `scripts\hooks\x.sh` — and
stats the raw path first, falling back to the folded one, so a filename that
legitimately contains a backslash is never rewritten.

FAILS OPEN on everything unevaluable — missing `jq`, unparseable stdin, missing
checker, a path outside scope, a file that is not on disk. That is the opposite
of the `block-*` fences and it is deliberate: this is a hygiene guard, and one
that blocked edits whenever a dependency was absent would be worse than the
problem it solves. Being PostToolUse, exit 2 does not prevent the write that
already happened — it puts the breakage in front of the model while the context
to fix it is still loaded, which is the whole value.

The same two checks also run at commit time through `shell-lint.sh`, which
calls the identical `scripts/lint/hook-parse-check.sh` — one implementation,
two consumers. `shellcheck` reports the class precisely (SC1011) and is in
`.pre-commit-config.yaml`, but it is OPTIONAL and absent on plenty of hosts, and
`shell-lint.sh` degrades to "BOM + errexit checks only" when it is missing;
`[parse]` needs nothing but `bash`. `[quote-break]` additionally covers the
shape `bash -n` cannot see at all: when the stray apostrophe happens to
re-balance the file, it parses cleanly while `awk` receives a TRUNCATED program.

Spec: `scripts/hooks/test-check-hook-file-parse.sh` (positive controls, negative
controls including a healthy-corpus sweep of every `scripts/hooks/*.sh`).

### `block-git-stash.sh` — shared-`refs/stash` guard (HIMMEL-1755)

Fires on Bash/PowerShell. Every worktree of a checkout shares ONE `refs/stash`,
so a stash mutation in one session acts on entries a PARALLEL session owns —
measured twice in a single leg (2026-08-12): a `git stash drop` destroyed
another chain's entry, recovered only because it had been tagged. Refuses the
MUTATIONS at COMMAND POSITION (same grammar as
`block-destructive-commands.sh`, so `git -C <path> stash pop` and
`git --git-dir=<d> stash drop` are caught, while `grep -rn "git stash" src/` is
a read and passes): a bare `git stash` including its option/pathspec forms
(`git stash -u`, `git stash -- <path>` — git treats these as `push`), plus
`push`/`save`/`pop`/`drop`/`clear`/`branch`/`store`, plus the low-level
plumbing equivalents `git update-ref`/`symbolic-ref` against `refs/stash`
directly (HIMMEL-2077). The reads and the
non-destructive verbs stay allowed — `list`, `show`, `apply` (apply leaves the
entry in place for its owner), `create` (prints a dangling commit, writes no
ref) and `--help`. The deny names the sanctioned alternatives: a
`refs/checkpoints/<slug>` snapshot (`checkpointWorktree`, wired into both
spawners), a WIP commit on your own branch, or — for a stash-shaped snapshot —
the race-free `git tag wip-<slug> "$(git stash create)"`, restored with
`git stash apply wip-<slug>`. Both of those are allowed forms, so the escape
hatch is not needed for them; `push` then `tag stash@{0}` is NOT equivalent,
because another session can drop the entry between the two commands.
Deliberately NOT part of the
`parity_guard.py` floor: that ports catastrophic/shared-machine terminal
shapes, and this is fleet policy about one checkout's shared ref namespace.
The brief-level twin is `STASH_BAN_LINE` in the lane worker prompts. Fails
CLOSED on missing `jq` or malformed JSON. Bypass: `GIT_STASH_OK=1` (launching
shell, session-sticky). Spec: `scripts/hooks/test-block-git-stash.sh`.

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

### `block-chokepoint-env-prefix.sh` — sanctioned-chokepoint env-prefix guard (HIMMEL-1746)

Fires on Bash/PowerShell. Denies a per-call env-prefixed invocation of a
REGISTERED sanctioned chokepoint (`scripts/chokepoints.json` — one registry,
one reader) when the assignment names one of THAT chokepoint's own
registered seam variables (test seams / opt-ins, e.g.
`STOP_WORKER_BRIDGE_ROOT_OVERRIDE` on `stop-worker.sh`, `ARMAUTOMERGE` on
`merge-on-green.sh`). The native permission matcher bails on `VAR=` shapes
(HIMMEL-203), so `VAR=x bash scripts/handover/merge-on-green.sh` cannot match
the chokepoint's own standing allow-rule and falls through to classifier
judgment instead — this guard gives that class a structural home. The
scanner positionally SIMULATES the argv each interpreter in the chain
(shell, `env`, `env -S`) really produces, deriving `env`'s option handling
from its actual option grammar rather than an enumerated spelling list
(HIMMEL-1803 rounds 1–6 closed the option-grammar and empty-word gaps that
kept reopening this predicate as a class), so a chokepoint is recognized
ONLY when its registered path is the invoked-program token of a command
segment, and a seam assignment counts ONLY as a leading assignment of that
SAME segment. Fails OPEN on anything unresolvable (missing `jq`,
missing/malformed registry, an internal error) — a belt around chokepoints
whose bare invocations are already governed by allow-rules + the classifier,
never a general env-var ban. Known residual (accepted, unchanged posture,
HIMMEL-912): deliberately case-varied paths/vars, a path assembled from
shell variables, PowerShell-native `$env:` syntax, `sudo`/`xargs`/`find
-exec` wrappers, and string reconstruction deeper than the bounded
`eval`/`bash -c` recursion. Bypass: `ENV_PREFIX_GUARD_OK=1` (launching
shell, session-sticky). Spec: `scripts/hooks/test-block-chokepoint-env-prefix.sh`.

### `require-quiet-run.sh` — bare test-suite bounce (HIMMEL-1952)

Fires on Bash. Denies a bare `bash`/`sh`/direct invocation of a repo shell
test suite (`scripts/**/test-*.sh`, `scripts/ci/run-shell-tests.sh`) at
command position and prints the exact `scripts/quiet-run.sh`-wrapped
replacement command. `scripts/quiet-run.sh` already existed, was cataloged
(`docs/commands-catalog.md`, `/quiet-run`), and CLAUDE.md's Tests section
already explained why quiet reporters are deliberate — none of that prose
produced compliance, so per HIMMEL-195 the fix is deny + name the exact
replacement, the same shape as `block-jira-compound-write.sh` and
`block-graphify-egress.sh`; an advisory `additionalContext` was measured not
to change behaviour. Decided per SEGMENT (split on `;`/`&`/`|`/subshell
delimiters), not per whole command, so a compound that wraps one suite call
in `quiet-run.sh` and runs another bare in a separate segment still bounces
on the unwrapped one. Deliberately narrow scope: only a suite path actually
being EXECUTED counts, never one merely mentioned as an argument to
`cat`/`grep`/etc., and `node --test`/`bun test` are untouched (they already
have their own quiet reporters by convention). Two normalization stages run
BEFORE the segment split so PROSE QUOTING a suite command is not mistaken for
running one (HIMMEL-2322 — it refused a handover-doc write, and the same shape
blocks stuck-playbook recovery notes and `--body-file` PR bodies): heredoc
BODIES are dropped unless the heredoc's own intro line feeds a shell, so
`cat > doc.md <<'EOF'` prose is data while `bash <<'EOF'` and
`cat <<'EOF' | bash` keep full coverage; and separator characters inside
quoted spans are neutralized (single-quoted always, double-quoted only when
free of command substitution), so `echo "…; <suite>"` and a `git commit -m`
body cannot forge a command position while a quoted suite PATH still bounces.
Fails OPEN on anything this
hook cannot evaluate (missing `jq`, unparseable JSON, non-Bash tool) — a
workflow nudge, not a security fence. Bypass: `QUIET_RUN_BYPASS=1`
(launching shell, session-sticky). Spec: `scripts/hooks/test-require-quiet-run.sh`.

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

### `block-unresolved-cr-merge.sh` — CodeRabbit merge-remark gate (HIMMEL-936)

Fires on Bash/PowerShell. Blocks a `gh pr merge` while the target PR has
unresolved CodeRabbit review threads OR CodeRabbit's verdict on the head SHA is
anything other than `success` — including **absent** — structural enforcement of
the operator's "never merge over unresolved CodeRabbit remarks" rule (HIMMEL-195:
structural > instructional). The signal is `cr_merge_gate <pr-selector>
[<owner/repo>]` from `scripts/lib/cr-merge-gate.sh`, which runs a GraphQL
`reviewThreads` query (counts unresolved threads whose first-comment author
matches `coderabbit`, covering both `coderabbitai` and `coderabbitai[bot]`
login forms) and reads CodeRabbit's commit **status** on the head SHA via
`scripts/lib/cr-signal.sh`. The same predicate is
called from `scripts/handover/pr-merge.sh` (GitHub forge only) before its
mergeability poll, so machines without the plugin hook still get the gate on
that path (a block there exits `pr-merge.sh` with code 5, distinct from a
real `gh pr merge` failure's code 4).

**HIMMEL-1072 — CodeRabbit posts a STATUS, not a check-run.** This gate used to
query `check-runs` for `.name=="CodeRabbit"`, which matched **nothing on every
PR since it shipped** (verified on 5 consecutive live PRs: `check-runs` = 0,
`statuses` = 3–5). The in-flight block never fired and the HIMMEL-980 zombie
override beneath it was unreachable; the fixtures mocked a check-run, so the
suite confirmed the wrong shape instead of catching it. `statusCheckRollup`
merges check-runs AND statuses, which is why `gh pr checks` showed CodeRabbit
while the check-runs API did not. The gate now reads the `/statuses` LIST
endpoint (the combined `/status` drops `creator`, and the rollup carries no
identity at all) and matches on **`creator.id`** — HIMMEL-1058's "identity, not
display name". The zombie override is **gone**: reviving it on the status would
wave a >90m pending review through on age alone, which is the same
uncertainty-reads-as-green bug. `CR_ZOMBIE_CHECKRUN_MINS` is no longer read.

**Posture:** deny on unresolved threads, and on a CodeRabbit status that is
`pending`/`failure`/`error`/**absent**. Absent-blocks is a deliberate 2026-07-16
break from the old "positive evidence only" stance: an unreviewed head reading as
green is what merged #1243 with 6 unresolved threads (reverted in #1244).
INFRASTRUCTURE failures still fail OPEN — `gh`/`jq` missing, incomplete PR
metadata, GraphQL/status API error, jq parse failure, and no `gh pr merge` at
command position all exit **0**; an unresolvable selector (`gh pr view` failure)
exits **3** — allow, but re-anchorable, so the PreToolUse hook retries once with
the cwd branch rather than letting a quoted/mis-tokenized selector dodge the gate
(top-level consumers treat any non-2 rc as allow). Each emits a
``cr-merge-gate: degraded (<why>) - failing open`` note to stderr so the
uncertainty is visible without blocking. A broken query is not evidence.
A degraded VERDICT query is the one exception that does not return early: the
thread query still runs and its evidence still blocks, because an unresolved
thread is evidence even when the status endpoint is down (observed live — GitHub
503'd `/commits/<sha>/statuses` on 2026-07-17).

**Review freshness (HIMMEL-1181, B2) — deny on a stale review anchor.**
Between the verdict check and the thread query, the gate also reads
`cr_review_freshness` (`scripts/lib/cr-review-freshness.sh`, GraphQL, one
extra call): is the *latest bot review* anchored to the head SHA, or was it
posted on an OLDER commit? A concluded commit STATUS (the check above) is not
the same claim — CodeRabbit can conclude an incremental run without posting a
new review object at all, leaving the last real review sitting on a stale
commit while GitHub auto-resolves (outdates) its threads on the intervening
commits. That combination reads "0 unresolved threads + status success" —
App-clean — over a head nobody actually reviewed (live instance: PR #1273).
Deny on `stale` (names the stale commit in the block reason) and on `paged`
(>100 reviews on the PR with no bot match in the newest 100 — indeterminate,
not absent). `none` (zero bot reviews on the whole PR) self-skips — absence
of a bot review is not evidence of staleness. `CR_BOT_LOGINS` (default
`coderabbitai`, trailing `[bot]` optional) configures which review-author
logins count as the bot for this gate specifically; it is a SEPARATE identity
mechanism from `CR_BOT_USER_ID` (the status/body readers' REST `creator.id` —
this gate reads GraphQL `author.login` + `author.__typename == "Bot"`
instead, HIMMEL-1058's spoof-resistance stance). An infrastructure failure
(query/parse error) is remembered and only fails OPEN at the very end,
alongside the verdict and body-findings degrades — a broken query is not
evidence.

### CodeRabbit availability — arm it per repo (HIMMEL-1125)

**⚠️ Setup step. On a repo that HAS the CodeRabbit App, run this once:**

```bash
git config --local himmel.coderabbit true
```

**Until you do, the CodeRabbit merge gates are a no-op there.** That is the
deliberate trade-off below — read it before deciding it is a bug.

**Why.** A repo without the CodeRabbit App has NO status on any head, so an
armed gate blocks every merge there *forever*. HIMMEL-1072 shipped exactly that:
the gate was armed by default on repos it could never pass on, and adopters had
to discover `CR_PROFILE=none` to work at all. So the gate is now
**availability-gated** — `scripts/lib/cr-available.sh` answers "is CodeRabbit's
App configured for THIS repo?", and the gate arms only when it says yes.

**The signal is a repo-scoped, NON-VERSIONED git config value** — deliberately
not a committed `.coderabbit.yaml`. A committed file is evidence of a *config*,
never of an *installation*, and it is wrong in both directions:

- **Config without the App** — `.coderabbit.yaml` is tracked, so every clone/fork
  inherits it while inheriting no App installation. This harness ships *by being
  cloned*, so that is the main adopter path: arming on the file would block their
  merges forever. (Found by the codex adversarial pass on the original design.)
- **App without config** — an App on defaults publishes no file, so the gate
  would silently disarm on a repo that really does have CodeRabbit.

A tracked file is also PR-controlled at exactly the moment the gate matters: a
diff that *deleted* it would disarm the requirement reviewing it. `git config
--local` lives in `.git/config` — outside any tree, so it cannot be inherited by
a fork, added or deleted by a PR, or copied around. `--local` and not global:
availability is per-repo, and a `~/.gitconfig` value would arm every repo on the
machine (the same over-reach, one level up).

**The trade-off, stated plainly:** this **reverses the HIMMEL-1072 fail-closed
default**. An operator who never arms a repo silently has no CodeRabbit merge
gate there. That is the accepted cost of never blocking an adopter who has no
CodeRabbit at all (operator call, 2026-07-17), and it is why arming is a
documented setup step rather than inferred.

**Overrides:** `CR_APP=1` arms without the config (shallow CI, or an App on
defaults); `CR_APP=0` disarms without touching the critic profile;
`CR_PROFILE=none` still disarms and outranks both.

**Scope of the disarm** — the part worth being precise about: it turns off only
the **CodeRabbit-specific** requirement (an absent CR verdict stops being a
blocker). The generic unresolved-**review-thread** gate in `check-ci.sh` is NOT
keyed on the probe: it blocks on any reviewer's unresolved thread, human
included, for everyone, and "cannot evaluate" still fails closed for everyone.
Disarming CodeRabbit never turns a real finding green.

**The MACHINE-GENERATED PR class — HIMMEL-2278.** Some PRs never receive an App
review *at all*, so "absent" is their steady state and the armed gate blocks
them forever. Two shapes, both with a precedent PR that ended in a manual
operator merge after a console parked on a review that was never coming:

| Shape | Precedent | Why the App never reviews it |
|---|---|---|
| Bot-authored dependency bump | **#2013** (dependabot) | CodeRabbit does not review bot-authored PRs |
| Pure regenerated-artifact publish | **#2035** (`/graph-publish`) | zero code; a critic panel over a 17 MB regenerated `graph.json` is review theater |

`check-ci.sh`'s `machine_pr_gate` classifies these and sets `MACHINE_PR_CLASS=1`,
which is read by exactly the two `cr_signal_gate` arms that mean *the App said
nothing* — `absent`, and the skip-classified family (`Review rate limited`,
`automatic reviews are disabled`, …). **The class licenses tolerating SILENCE,
and only silence.** Everything else still gates it, unchanged: a `failure` /
`error` App status (rc 1), a `pending` one (rc 2), `cr_body_gate`'s
outside-diff-range body findings, `review_freshness_gate`, the checks-green
watch, the `CHANGES_REQUESTED` blocker, and the paginated unresolved-thread
gate. Non-machine PRs keep today's fail-closed behaviour byte-unchanged.

> The first cut set `CR_ARMED=0` instead — the same thing an operator does by
> hand with `CR_APP=0`. That also silenced `cr_body_gate`, so on the day the App
> *did* review a machine-class PR, its outside-diff-range findings — which carry
> no thread and are therefore invisible to every other gate — would have been
> dropped. `CR_APP=0` remains the right manual escape hatch for a human who has
> looked at the PR; an automatic classifier must be narrower than one.

**Neither arm is a label, a title marker or a body token** — a marker an
arbitrary author can set would be a one-line CR bypass for any code PR, which is
worse than the drift it fixes. Each is derived from something a code PR cannot
cheaply fake:

- **dependabot** — GitHub's own `author.is_bot` *and* a dependabot login. A human
  account cannot set `is_bot`, and cannot open a PR as an App.
- **graph-publish** — the **diff shape**: *every* changed path must be one of the
  two tracked `graphify-out/` artifacts. Not *both present* — when only
  `graph.json` actually changed, the publish PR is a single file and is still in
  the class. A PR carrying any code touches at least one path outside that
  two-element set and is therefore never in the class, whatever it labels or
  titles itself. (`graph-publish.sh` says so in its PR body and posts no
  review-trigger comment on open, but that text is documentation for human
  readers — the gate reads the diff, not the prose.)

Any unreadable, erroring, sentinel-less **or truncated** classifier probe returns
"not the class" and leaves the gates armed: the emitted path count must equal the
count the probe advertised, so a partial file list can never read as a complete
one. The controls live in `scripts/test-check-ci.sh` (cases `2278-c` … `2278-r`):
the artifact pair *plus* one code path still fails closed, a `dependabot` login
without `is_bot` is not the class, a file literally named `*` cannot glob its way
in, a truncated list fails closed — and on a PR that IS in the class, unresolved
threads, a red check, `CHANGES_REQUESTED`, a failed or pending App status, and an
outside-diff body finding all still block.


**Cross-repo:** the probe describes the local clone, so `cr_merge_gate` refuses
to apply the local answer to a foreign `gh pr merge --repo other/thing` target —
it holds no signal for that repo, so it does not gate it. A *malformed* `--repo`
value is not treated as foreign; it falls through to the rc=3 re-anchor path, or
a quoted `--repo` would silently disable the gate.

**Caveat — `CR_PROFILE=none` is overloaded.** It is a critic-panel *profile*
("claude-only review", `.env.example`) AND, since HIMMEL-1072, the CodeRabbit
merge-gate opt-out read here. So choosing claude-only review also silently drops
this gate. HIMMEL-1125 preserves that coupling rather than widening it; `CR_APP`
is the unambiguous availability switch.

**Bypass:** `CR_MERGE_GATE_OK=1` set in the shell that LAUNCHED Claude
(same session-sticky convention as the other block-* hooks). `CR_PROFILE=none`
or `CR_APP=0` skip the gate entirely, and a repo that was never armed
(`git config --local himmel.coderabbit true`) does not gate at all. Precedence,
highest first: `CR_PROFILE=none` → `CR_APP` (`1` arms, `0` disarms) → the
repo-scoped `himmel.coderabbit` config → **default: disarmed**.

**Delivery:** shipped via the **himmel-ops plugin `hooks.json`** (same
exec-if-exists `$CLAUDE_PROJECT_DIR` pattern as `block-docker-privesc` /
`block-merged-pr-commit`); live only after `/himmel-update` (marketplace
re-sync) + a fresh session.

Paired artifacts: `scripts/lib/cr-merge-gate.sh` (predicate),
`scripts/lib/cr-signal.sh` (the ONE reader for CodeRabbit's verdict — shared with
`ci-green-gate.sh` and `check-ci.sh`, so all three agree on the bot's identity by
construction), `scripts/lib/cr-review-freshness.sh` (the ONE reader for review
anchor freshness — shared with `check-ci.sh`, HIMMEL-1181),
`scripts/lib/test-cr-merge-gate.sh` and
`scripts/hooks/test-block-unresolved-cr-merge.sh` (smoke suites).

### CodeRabbit pre-CI path — App-present vs App-absent (HIMMEL-1164)

CodeRabbit has two independent surfaces (also documented at the top of
`scripts/lib/cr-available.sh`), and each covers a *different* adopter:

- **App present (armed via HIMMEL-1125 above)** — reviews the PR in CI, after
  `gh pr create`. That review is what the merge gates above key off of. This is
  the **CI-side** path.
- **App absent** — no App means no CI-side review, ever, on this repo. The
  **sanctioned pre-CI path** is the CodeRabbit CLI wrapper,
  `scripts/cr/coderabbit-review.sh`, run as part of `/pr-check` (step 3.2 phase
  B in `.claude/commands/pr-check.md`) before the PR ever opens.

**`/pr-check` already runs the CLI pass by default, regardless of App
presence** — an App-less repo gets CodeRabbit signal from the CLI leg with no
extra setup. What HIMMEL-1164 adds is *degrading loudly* when that pass is
unavailable too (`coderabbit-review.sh` rc 3 — CLI not on PATH and, on
Windows, WSL not opted into via `CODERABBIT_ALLOW_WSL`): the step reuses
`cr_app_configured` from `scripts/lib/cr-available.sh` (HIMMEL-1125's
availability probe — never a second, invented probe) to tell whether CI will
still catch this PR. When the App **is** armed, the CLI-absent message stays
quiet (CI covers it). When the App is **not** armed, the message escalates to
say the PR is shipping with **no CodeRabbit signal at all**, and points at
installing the CLI or arming the App.

The reverse case — an App-present repo running the CLI pass too — is
intentional duplicate coverage, not a bug; an operator who wants to avoid
spending a second CodeRabbit call against the same rate-limited account sets
`CODERABBIT_CLI_DISABLE=1` (documented in `coderabbit-review.sh`).

### CI-green merge gate (HIMMEL-1043)

Runs on the SAME `gh pr merge` path as the CodeRabbit gate above, one step
after it: blocks the merge while the target PR's **head SHA is not green** —
any **non-CodeRabbit** check-run with a red conclusion (`failure`,
`timed_out`, `cancelled`, `action_required`, `startup_failure`, `stale`) or
still pending (`status != completed`), or a **non-CodeRabbit** commit **status**
(newest per context) of `failure`/`error`/`pending`. It also **fail-CLOSED-blocks**
when the head has **>100 check-runs** (more than the single API page can
certify — a failing/pending run may sit on an unread page 2; same page-limit
stance as `cr-merge-gate`, HIMMEL-980). This repo has **no branch
protection**, so GitHub will not otherwise block a merge over red/pending
CI — this gate is the structural "ready to merge ⇒ green" enforcement
(operator rule 2026-07-15; HIMMEL-195 structural > instructional; the
green-gate HIMMEL-1042's true auto-merge needs). CodeRabbit is excluded here on
purpose — the CR gate above owns it — so this gate never double-blocks nor
false-blocks on a hung CodeRabbit review. **HIMMEL-1072:** that exclusion only
became real then. It was written against CodeRabbit *check-runs*, which
CodeRabbit never posts (it posts a commit **status**), while its real status rode
the *combined* `/status` aggregate straight into this gate's pending block — so
the gate false-blocked on exactly the signal it documented that it ignored. It
now reads the `/statuses` LIST endpoint and excludes CodeRabbit by **creator
identity** (`creator.id`, shared with the CR gate via `cr_signal_bot_id`).

The signal is `ci_green_gate <pr-selector> [<owner/repo>]` from
`scripts/lib/ci-green-gate.sh`. It is wired into **the same
`block-unresolved-cr-merge.sh` PreToolUse hook** (reuses that hook's
adversarially-hardened selector extraction; a block prints
`block-red-ci-merge: …` to stderr and exits 2) AND into
`scripts/handover/pr-merge.sh` before its mergeability poll (a block there
exits `pr-merge.sh` with code **6**, distinct from the CR gate's 5 and a real
merge failure's 4).

**Fail-OPEN posture:** deny ONLY on positive red/pending evidence. `gh`/`jq`
missing, API/parse error, and a genuinely **checkless PR** (zero check-runs AND
zero commit statuses) all exit **0**, and an unresolvable selector (`gh pr view`
failure) exits **3** — allow, but re-anchorable, so the PreToolUse hook retries
once with the cwd branch rather than letting a mis-tokenized selector dodge the
gate (coderabbit-4; top-level consumers treat any non-2 rc as allow). Every
fail-open path emits a ``ci-green-gate: degraded (<why>) - failing open`` stderr
note — never a false block on a repo/branch with no CI.
**Exception (HIMMEL-1072):** the page limits are NOT fail-open — >100 check-runs
or ≥100 commit statuses on the head **block** (rc 2), because a red one may sit
on an unread page and a merge gate must not certify green from a partial view.

**Bypass:** `CI_MERGE_GATE_OK=1` in the LAUNCHING shell (independent of the
CR gate's `CR_MERGE_GATE_OK`; NOT coupled to `CR_PROFILE`).

Paired artifacts: `scripts/lib/ci-green-gate.sh` (predicate),
`scripts/lib/test-ci-green-gate.sh` and the shared
`scripts/hooks/test-block-unresolved-cr-merge.sh` /
`scripts/handover/test-pr-merge.sh` (smoke suites).

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
delivery (`.codex/hooks.json` → `run-hook.{sh,cmd}` → `codex-hook-adapter.sh`)
already failed closed on a missing guardrail script before this fix (its
own precondition check), so it needed no change.

Paired artifacts: `scripts/guardrails/test-lesson-write-fence.sh` (111
checks), `scripts/hooks/test-block-lesson-enforcement-writes.sh` (9 checks).

### `guard-implementor-dispatch.sh` — lane-routing dispatcher guard (HIMMEL-1513; composed with the HIMMEL-920 bank guard)

Fires on `Agent`. Structural enforcement of the second-drift lane-routing
rule: leg 31 routed four implementation workers through ordinary Agent-tool
Claude subagents while the claudex/GLM entry points were available, consuming
the scarce Claude bank and bypassing the flow-run ledger.

**Policy decision: HARD BLOCK, not advisory.** This matches
`block-backend-tier.sh`: after two recorded prose drifts, another warning is
not enforcement. The guard refuses only when it can positively establish BOTH
that the dispatch is implementation-shaped and that a suitable external lane
is currently available. The refusal is one line and names the concrete command
(`bun scripts/telegram/spawn-claudex.ts ...`, falling back to
`spawn-glm.ts`) because the original failure was not knowing the dispatcher
entry point; a bare "use a lane" refusal would reproduce the stall.

**Classification:** the hook reads both Agent `description` and `prompt`.
Direct implementation words (`implement|fix|land`), worktree paths, ticket IDs,
and commit/attestation instructions are signals. Explicit read-only
research/exploration/investigation/review/planning remains allowed, including a
ticket or "how to fix" mention, unless the brief transitions to action (for
example "investigate and then implement") or includes worktree/commit/trailer
instructions. Read-only agent types and the claudex/GLM/Codex lane-wrapper
agents are exempt. This conservative posture is intentional: over-blocking an
orchestrator is worse than missing a cost-routing nudge.

**Availability:** the hook invokes the existing
`scripts/lanes/resolve.mjs --json` resolver, so `lanes.json`, machine probes,
local profile suppression, and `LANES_REGISTRY` test overrides remain the
single source of truth for registry availability. A registry-available lane
must also be RUNNABLE before the guard refuses toward it: `bun` must be on
`PATH` and the lane's `scripts/telegram/spawn-<lane>.ts` dispatcher must exist
on disk. An unrunnable lane is skipped with a warning, so `claudex` is still
preferred and `glm` is still the fallback. No suitable lane, an unrunnable
lane, missing bun/jq/node/resolver, a missing dispatcher script, malformed
hook input, resolver failure, or invalid resolver output all fail OPEN and
allow the Agent dispatch — the orchestrator is never stranded on a command
that cannot execute.

**Retained bank policy (HIMMEL-920):** when no lane is available (registry-
absent or unrunnable), the guard falls through to the pre-existing bank-aware
cost guard instead of allowing unconditionally. `IMPL_GUARD_HARD` (default 80)
refuses an eligible implementor-shaped dispatch outright; `IMPL_GUARD_WARN`
(default 65) attaches a visible advisory instead of blocking. Both require a
fresh `IMPL_GUARD_CACHE_PATH` usage cache (default max age 300s) and a
provably live `five_hour.resets_at` window — a missing/unparseable
`resets_at` downgrades a HARD hit to the WARN advisory, and an expired window
allows outright. See the "bank-aware policy when no lane is available"
section of `test-guard-implementor-dispatch.sh` for the full matrix.

**Audited bypass:** `IMPL_GUARD_OK=1` (deliberate carve-out) or
`IMPL_GUARD_DISABLE=1` (kill switch), set in the LAUNCHING shell and
session-sticky. Every use warns and appends a JSONL audit row to
`~/.claude/lane-routing-guard/overrides.jsonl` (`IMPL_GUARD_LOG` is the test
seam). A per-call env prefix does not reach the hook process.

**Delivery:** shipped via the **himmel-ops plugin `hooks.json`** (matcher
`Agent`, same exec-if-exists `$CLAUDE_PROJECT_DIR` pattern as
`block-docker-privesc`); live only after `/himmel-update` (marketplace
re-sync) + a fresh session.

Spec: `scripts/hooks/test-guard-implementor-dispatch.sh`.

### `guard-console-dispatch.sh` — console/leg dispatch fence (HIMMEL-2323)

Fires on `Agent`. Structural enforcement of standing operator ruling 20:
PR/ticket-shaped work dispatched FROM A CONSOLE session must go to an armed
DETACHED session with a mission doc (`bash scripts/handover/arm-resume.sh`),
never an in-process Agent-tool subagent — those die with the parent, are not
relaunchable, and dump their reports into parent context. This is the
CLAUDE.md "second drift" escalation: the ruling stood verbatim in its own
handover chain and still drifted twice.

**Policy:** deny only when the session is CONSOLE-shaped AND the dispatch's
`description`/`prompt` match markers from at least TWO DISTINCT ship-flow
marker families — `worktree` (`.claude/worktrees`, `clean-garden.sh`,
`git worktree`, `/worktree`, "create a worktree"), `pr-open` (`gh pr create`,
"open a/the PR", `gh pr edit`), `cr-gate` (`/pr-check`, "CR-clean",
`clear-cr-marker`, "CodeRabbit"). A single-family match never denies — that
conjunction is the false-positive budget keeping bounded read-only research
frictionless. `subagent_type: Explore` always allows — the ONLY carve-out.
There is deliberately no prompt-text read-only declaration carve-out: three
CR rounds each added one and each leaked it a different way (a partial-scope
aside, an output-shaped phrase, a mode declaration governing a subordinate
clause rather than the whole dispatch), so it was removed rather than
patched a fourth time. A genuinely read-only dispatch uses `Explore`, or the
audited `CONSOLE_DISPATCH_OK=1` override below.

**Console detection (fail-open — unknown means NOT console):**
`HIMMEL_SESSION_ROLE=console` (case-insensitive; any other non-empty value
decides NOT-console immediately) in the launching shell — the PRIMARY, exact
signal. Failing that, a bounded head-read of `transcript_path`'s first user
turn, scoped to the FIRST handover-doc path named in it (the launch prompt
loads exactly one doc, and it is the first path named — a later mention,
e.g. a mission doc naming the console leg's own doc further down the same
turn, does not count): console-shaped only if that first path's basename
matches `*-console.md`.

**Audited bypass:** `CONSOLE_DISPATCH_OK=1` (deliberate carve-out) or
`CONSOLE_DISPATCH_DISABLE=1` (kill switch), set in the LAUNCHING shell and
session-sticky. Every use warns and appends a JSONL audit row to
`~/.claude/console-dispatch-guard/overrides.jsonl` (`CONSOLE_DISPATCH_LOG` is
the test seam).

**Delivery:** shipped via the **himmel-ops plugin `hooks.json`** (matcher
`Agent`, second entry alongside `guard-implementor-dispatch.sh`); live only
after `/himmel-update` (marketplace re-sync) + a fresh session.

Spec: `scripts/hooks/test-guard-console-dispatch.sh`.

### `block-glm-external-writes.sh` — GLM-lane external-write deny (HIMMEL-654)

Fires on `Bash|PowerShell|mcp__.*`. The deterministic classifier substitute for
third-party offload lanes, which have no auto-mode classifier and usually run
`--permission-mode bypassPermissions` (GLM workers via `spawn-glm.ts`,
`claude-glm` sessions). Detects the lane by `ANTHROPIC_BASE_URL` containing
`api.z.ai` (set by `glm-env.ts` `buildGlmEnv` / the `scripts/claude-glm{,.ps1}`
launchers, inherited by hook processes); off-lane sessions exit 0 on the first
env check — near-zero overhead, before the jq check.

On-lane it hard-blocks: `git push`, remote-URL rewrites (`git remote set-url`,
`git config …url` — a worker repointing a remote is outside its brief), the
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

Known limitations (accidental-shape guard, backstopped by the parent CR gate —
the load-bearing control since HIMMEL-1961 retired the pushurl tripwire that
used to sit beside it): a wrapper that
displaces the command from command position is missed (env-prefixed
`FOO=1 git push`, `sudo`/`xargs`/`timeout`, the dashed `git-push`), and
in-process network is invisible (bun/node `fetch`, including the bun-invoked
telegram bridge send path).

**Delivery:** shipped via the **himmel-ops plugin `hooks.json`** (same
exec-if-exists `$CLAUDE_PROJECT_DIR` pattern as `block-docker-privesc`); live
only after `/himmel-update` (marketplace re-sync) + a fresh session, AND the
checkout workers branch from having pulled the merge. Spec:
`scripts/hooks/test-block-glm-external-writes.sh`.

> **Delivery vs. enablement (HIMMEL-2292).** PR #1992 / HIMMEL-2085 found
> this hook absent from `.claude/settings.json`, `.codex/hooks.json`, and
> `wire-hook-bash.mjs`, and read that as "not wired anywhere" — true only of
> those three files. Delivery via the himmel-ops plugin `hooks.json` above
> predates #1992 and was always correct. The real gap was per-machine
> **enablement**: `himmel-ops@himmel: false` in a machine's live
> `~/.claude/settings.json` (a manual toggle, an older template) leaves this
> hook installed but inert, silently — existence in the plugin's `hooks.json`
> is not the same as being enabled. Closed structurally, not by re-wiring:
> `scripts/install/manifest.json`'s `himmel-ops-plugin` item probes the LIVE
> enabled value (not mere key presence); `docs/setup/settings-template.json`
> (the HIMMEL-1032 reconciler's own whitelist) already flags it `true`; and
> `install-plugins.sh`'s force-enable step — the mechanism `himmelctl
> ensure`/`install` runs for that item — flips a drifted `false` back to
> `true`, additive-only. Re-executing #1992's settings-chain steps was
> explicitly rejected: it would double-invoke this hook, drop its `mcp__.*`
> arm (settings-chain entries are `Bash`/`PowerShell`-only), and a `--chain`
> member cannot carry `--fail-closed-when`.

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

**CLI paths resolve against the PRIMARY checkout, not the invoking one**
(HIMMEL-2237). Every registered `cli` is a path under an untracked `dist/`
build artifact, which git never carries into a linked worktree. Resolving
the existence probe against the invoking checkout therefore made it always
miss in a worktree, fall open, and leave this guard INERT in exactly the
place [`CLAUDE.md`](../../CLAUDE.md) mandates all feature work happens —
armed only on `main`, where nobody is meant to be working. The primary is
derived from the hook's own location: `git worktree list --porcelain` names
it first, with `git rev-parse --path-format=absolute --git-common-dir` as
the fallback. It must be `--git-common-dir`, **not** `--git-dir`, which in
a linked worktree resolves to `.git/worktrees/<name>` (the same subtlety
`scripts/cr/install-cr-gate.sh` solves under HIMMEL-2035). The REGISTRY is
deliberately still read from the invoking checkout — `backends.json` is
tracked, so a branch's own copy is the routing config under test there.

When the primary's CLI is genuinely absent (a fresh clone that never
built), the hook still falls open — that is the real "no plugin equivalent
available" case — but now prints a one-line advisory naming the service,
the path it looked for, and the tool call it let through. An inert guard
that reports nothing is indistinguishable from a working one, which is how
this class went unnoticed in HIMMEL-1773 and HIMMEL-2085 as well.

The regression property in `test-block-backend-tier.sh` §4 is **verdict
equality across checkouts**, not any single verdict: a throwaway repo plus a
linked worktree, a `.gitignore`d relative CLI path standing in for `dist/`,
and the hook copied in so both checkouts run the real script. Those cases
deliberately bypass the `JIRA_CLI`/`CONFLUENCE_CLI` seams — the seams skip
path resolution entirely, which is why no earlier case could have caught
this.

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
Operational dependency: the usage cache is only fresh while the
statusline is rendering. Under claude-hud (HIMMEL-718) the hud
custom-line composer drives the usage-cache producer
(`scripts/statusline/usage-cache-producer.sh`) render-timed but
freshness-gated — it re-forks the producer only when the consumer cache
(`/tmp/claude/statusline-usage-cache.json`, the filename retained from
the claude-statusline lineage; live production is now claude-hud's) is
older than `USAGE_CACHE_TTL` (default 300s), so a live session refreshes
it at most once per TTL instead of freezing at session start. The
session-start freeze that drove HIMMEL-275 — observed 2026-06-10/11
against the *legacy bash bar*, whose stdin-rates path never rewrote the
cache mid-session — no longer occurs on this setup (verified
HIMMEL-1233: cache mtime tracks live renders, utilization signal
current, no spurious "STATUSLINE WEDGED" escalations). The HIMMEL-275
escalation path stays wired as a SAFETY NET: if the producer ever stops
feeding the cache during a live session (hud unwired, composer failing),
past the escalation bound the hook safety-arms and blocks once per
session rather than quietly standing down on a stale cache.
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
counted in the "nine guards" above): it ships in the **himmel-ops plugin**
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
`check-update-available.sh` (the himmel-update nudge) also runs here; its
behind-count is read from the LOCAL remote-tracking refs and the `git fetch`
that refreshes them is DETACHED, so an offline or slow remote can no longer
stall — or time out — session start (HIMMEL-1844; a fresh clone is therefore
silent on its first check, and nudges on the next one). A third
SessionStart hook, `inject-where-are-we.sh` (HIMMEL-516, plugin-delivered via
the himmel-ops `hooks.json`), injects the relevant slice of the where-are-we
ledger; opt-in behind `HIMMEL_WHERE_ARE_WE`, fail-open and advisory.

### `qmd-staleness-notice.sh` — qmd index trust advisory (HIMMEL-1286)

Default: ON, but **silent unless something is wrong**. Runs
`scripts/luna/qmd-staleness.sh --quiet` and prints a `<system-reminder>` only
when the local qmd index is STALE (older than `QMD_STALENESS_MAX_AGE_HOURS`,
default 36h), INCOMPLETE (chunks pending embedding), MISSING a required
collection (opt-in, see below), or UNREADABLE (`qmd status`'s report could not
be parsed — fail-loud, because an unparseable report is not evidence of
health). A fresh index prints nothing at all: every line a SessionStart hook
emits is paid for in every session, and a daily "index is fine" banner is the
always-on noise that trains a reader to skip the block — taking the real
warning with it.

This is the one always-on exception to the HIMMEL-177 lean-invoke default, and
the trigger is the safety-critical row: the failure mode is a session answering
confidently off a stale index, and the session that would remember to run a
manual check is not the session that gets burned. `qmd status` is a local
sqlite read, so the per-session cost is one cheap subprocess.

Never blocks, always exits 0. A station with no qmd installed (guard rc 2) is
silent — adopters who do not use qmd are never nagged about a tool they never
installed. The notice explicitly tells a *receiving* station NOT to reindex:
it embeds ~50x slower than the host, so the fix is a host-side push
(`scripts/luna/ship-index.sh`, armable via `qmd-cadence.sh arm --ship-to`),
never a local rebuild.

**rc 2 is the ONLY silent non-verdict — and only while no qmd policy is
declared.** Everything else that is not a freshness verdict is reported as
**UNVERIFIED**: `qmd status` failing (rc 7 — a corrupt or locked index, a
crashed or wedged qmd), the probe timing out (124/137), and any exit code the
hook does not recognise. Those were all silent once, which recreated the exact
hole this ticket closes one level up — the check quietly stopped checking. "I
could not verify" is a *trust* claim, not a staleness claim, and the advisory
says so explicitly so a reader does not conclude the index is stale when it may
be fine. Setting `QMD_STALENESS_REQUIRE_COLLECTIONS` revokes the rc 2 exemption
for that station: it is an explicit declaration that qmd matters here, so a
vanished qmd is a substrate that disappeared, not an adopter who never
installed one.

The probe is bounded on **both** paths. Where **GNU coreutils** `timeout`
exists it bounds the guard; otherwise the hook runs a foreground poll loop
rather than an unbounded call. The GNU part is load-bearing on Windows:
`command -v timeout` also matches `C:\Windows\System32\timeout.exe`, which is a
*sleep*, not a command runner — invoking it GNU-style fails instantly, and the
hook would read that as the guard's own rc 1 and print a MISCONFIGURED
advisory blaming the operator's env vars while never checking the index.
`qmd-cadence.sh`'s liveness probe carries the same `timeout --version` /
`*oreutils*` discriminator for the same reason. The distinction is not academic: the
SessionStart entry's own timeout bounds the hang by killing the hook *process*,
and the hook prints nothing until the guard returns — so an unbounded fallback
meant a hung qmd took the warning down with it and the session heard silence on
exactly the wedged-index condition. An outer timeout bounds the hang; only an
inner one can report it.

**Required collections (opt-in).** Freshness and completeness are properties
of the documents that *are* indexed, so a station missing an entire collection
scores perfectly on both — the shape measured on an auxiliary workstation
(index fresh, `salus` absent outright). Set
`QMD_STALENESS_REQUIRE_COLLECTIONS` in the launching shell to a comma-separated
list (e.g. `himmel,luna`) and the guard exits 8 with a banner naming every
absent one. Opt-in because the required set is
per-station policy this script cannot infer. A required set that cannot be
checked (no readable `Collections` block) fails closed on rc 6, never 0.

**What the freshness figure actually measures — do not build on it blindly.**
`qmd status`'s `Updated:` is *not* a refresh timestamp. qmd computes it as
`SELECT MAX(modified_at) FROM documents WHERE active = 1`, and `modified_at` is
written from the **source file's** mtime — so it means "the newest document
this index knows about was edited *n* ago". It is a proxy, and an asymmetric
one: a corpus that has simply been quiet reads as old even when the index was
rebuilt minutes ago, and one busy collection can keep the global figure recent
while another collection's new files sit un-indexed. The banner therefore
states the observation and *both* of its readings rather than asserting
staleness — an always-on warning that is wrong daily is one the reader learns
to skip, which would take the real warning with it. The durable
refresh/receipt timestamp that would settle it is **HIMMEL-1307** (it spans
`qmd-reindex.sh` and the receiver leg, so it is not the guard's to invent).
The proxy is still worth having for the case this was built for: a receiving
station whose index stopped arriving while the source corpus kept moving is
exactly what it detects correctly.

**Budget granularity.** `qmd status` reports ages under a day to the hour and
everything above it as whole days (its formatter floors), so `1d ago` denotes
the whole interval [24h, 48h). The guard resolves a floored label to its
**worst case**, so an index at or above 24h is not certifiable under the 36h
default — the practical effect is "warn once the index crosses a day". Reading
the floor instead made the 36h budget behave like a ~48h one and reported a
two-day-old index fresh. Set `QMD_STALENESS_MAX_AGE_HOURS=47` for the literal
one-missed-fire-plus-headroom behaviour.

**The probe runs OUT OF BAND (HIMMEL-1844).** `qmd status` is a cold sqlite read
— 11.5s measured cold against ~1.4s warm — and cold is the normal case at
session start, which made this hook a large slice of the 16% SessionStart
timeout rate. A killed hook prints nothing, so the runs that most needed the
advisory were the ones that lost it. The hook now SERVES its last verdict from
`$QMD_STALENESS_CACHE_DIR/qmd-staleness/qmd-staleness-notice.out` (state dir
default `/tmp/claude`; the hook owns the private subdir under it) —
a `mkdir -p`, a few `stat`s for the trust checks below, and one `cat`, with no
`qmd` anywhere — and when that file is older than
`QMD_STALENESS_CACHE_TTL` (default 3600s) it kicks a DETACHED refresh whose
output becomes the cache the NEXT session start reads. The banner text is
unchanged; it is simply up to one TTL old, which is nothing against a 36h
staleness budget. The deferred verdict surfaces at the next SessionStart —
startup, compact or resume, whichever comes first — so a station with no cache
yet is silent for exactly one session. A changed
`QMD_STALENESS_MAX_AGE_HOURS` / `QMD_STALENESS_REQUIRE_COLLECTIONS` is honoured
by the next refresh, not the next session. `QMD_STALENESS_CACHE_TTL=0` disables
the cache and probes inline (the pre-1844 behaviour, block and all). The cache
is only ever *served* when both it and its directory are regular, non-symlinked,
owned by this user and writable by nobody else — its contents go verbatim into
the session context, so anything else reads as no cache at all and the hook
probes inline instead.

Guard exit codes (`scripts/luna/qmd-staleness.sh`): 0 healthy · 1 usage/config
· 2 qmd not installed · 3 STALE · 4 INCOMPLETE · 5 both · 6 unreadable report ·
7 `qmd status` failed · 8 required collection absent (outranks 3/4/5 in the
exit code; the banner still names every condition). A bad
`QMD_STALENESS_MAX_AGE_HOURS` or `QMD_STALENESS_REQUIRE_COLLECTIONS` surfaces
as a loud MISCONFIGURED banner (rc 1) rather than a check that silently stops
running. Suites: `scripts/luna/test-qmd-staleness.sh` (guard) and
`scripts/hooks/test-qmd-staleness-notice.sh` (the hook's routing table).

### `inject-initiative.sh` — opt-in initiative mode (HIMMEL-425)

Default: OFF. When `HIMMEL_INITIATIVE=1` is set in the launching shell, the
session is given a scoped "drive to ship" directive so a normal session
proactively runs the `/pr-check` → open PR → transition ticket → handover
sequence at *natural completion points*, without the operator saying "ship it"
each time. Drains stdin; never blocks session start (always exits 0).

Since HIMMEL-2036 the injected text is a **~370 B pointer**, not the former
~3.1 KB runbook: it names the active legs, points at
[`scripts/hooks/initiative-runbook.md`](../../scripts/hooks/initiative-runbook.md)
for the step bodies, and keeps the no-merge guard + the no-rail-relaxation
sentence INLINE (a rail is not a lookup). A ≤400 B budget assertion in
`scripts/hooks/test-inject-initiative.sh` holds the line. Measured deltas:
[`docs/token-economy.md`](../token-economy.md#measured-preload-deltas).

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

## Detached end-of-session work — the bounded Stop queue (HIMMEL-2004)

Every end-side hook (`Stop`, `SessionEnd`) returns in milliseconds because none
of them does its work inline: each spawns the real body DETACHED via
`scripts/lib/detach.sh` so it cannot trip the harness teardown budget. That
fixed latency and created the opposite problem — the detached work was
**unbounded**. A fleet of N children ending at once fanned out N independent
trees (bun, git, curl, node), and HIMMEL-1993 measured this box's kernel pool
leaking in proportion to exactly that file-handle churn. Nothing throttled them,
nothing deduped a repeated session, and a session that died mid-flight lost its
work silently. That pool growth is now watched rather than rediscovered by hand:
HIMMEL-1604 added four `Himmel{KernelPool*,CommitPressure}` alert rules over the
already-scraped `windows_memory_pool_*` / commit metrics
(`scripts/observability/README.md#kernel-pool--commit-pressure-himmel-1604`).

`scripts/hooks/stop-queue.mjs` replaces the fan-out with a durable directory
plus ONE worker. Stdlib-only node; no new dependency runs on every session end.

| Subcommand | What it does |
|---|---|
| `enqueue --key NAME [--ttl SECONDS] -- COMMAND…` | writes one entry atomically (tmp file + rename), starts the worker if none is live, exits. Sub-second; nothing runs inline. |
| `work` | takes the singleton lock (`mkdir`), drains entries oldest-first ONE at a time, exits. A second worker refuses to start — that IS the concurrency bound. |
| `status` | report-only census: what is pending, and what the log recorded as run, deduped, expired or abandoned. Never mutates. |

Layout, under `$HIMMEL_STOP_QUEUE_DIR` (default `~/.himmel/stop-queue`, the same
convention as the ci-queue / flow-run ledgers — deliberately NOT in the repo, so
the queue outlives a worktree pruned mid-drain):

```text
entries/<key>.json   one queued job: argv, saved stdin payload, gate env, ttl, cleanup
running/<gen>.json   a job CLAIMED by rename — running, or left by a worker that died
attempts/<gen>.n     the crash counter, kept outside the entry so entries stay write-once
tmp/                 the pre-rename staging file (atomic publish)
worker.lock/pid      the singleton lock; stale when the pid is gone or the heartbeat ages out
queue.jsonl          append-only census log: attempt | enqueued | enqueue-failed | dedup |
                     oversize | ran | timeout | retained | expired | abandoned | dropped |
                     corrupt | detached-fallback
```

**`attempt` (HIMMEL-713)** is logged before anything else in the CLI's `enqueue`
path — before stdin is even read — so a hook the harness cancels mid-enqueue
(the "Hook cancelled" class on a short session) still leaves a trace. An
`attempt` row with no matching `enqueued`/`enqueue-failed` is the observable
signature of a cancelled hook; without it that case was indistinguishable from
a session that never fired the hook at all, the same masking class that cost
the session-runs ledger five silent days (HIMMEL-2022, `session-runs.errors.log`
below). Since the row's `key` is only known after `sanitizeKey` may have
altered it, the `attempt` row instead carries a per-invocation `id` that is
threaded into the matching `enqueued`/`dedup`/`enqueue-failed`/`oversize` row —
that `id`, not `key`, is the correlation field an audit joins on.

Inspect or drain by hand:

```bash
node scripts/hooks/stop-queue.mjs status     # what is queued and what has run
node scripts/hooks/stop-queue.mjs work       # drain now, in the foreground
```

**Dedup** is per (hook, session): the key carries the payload's `session_id`, so
a fleet of N children keeps N entries while one session re-firing REPLACES its
own (newest payload wins — an older one for the same session is stale, not lost
work). With no identifiable session the key gets a unique suffix instead, so two
callers never collapse into one entry.

**Nothing is dropped silently.** An entry past its TTL (default 1 h — it has to
outlast a full backlog, or the queue expires its own tail before the worker
reaches it), one
that has burned its attempt budget, and a malformed one each write a log row
before they are removed. An entry left behind by a session that died is run by
the next worker — it is a file, not a process.

**A job that misses its deadline is stopped as a TREE**, not just at its direct
child (HIMMEL-2028). The jobs here are trees — `node run-hook-with-bash.js` →
`bash <hook>.sh` → `curl` / `bun` / `python` — so signalling only the child left
descendants running outside the concurrency bound and overlapping the job's own
retry, which is precisely the fan-out the queue exists to remove. The worker
holds each job's pid while it runs and hands it to `scripts/lib/kill-tree.mjs`
on expiry (`taskkill /T` on Windows, a process-GROUP signal on POSIX); a reap
that fails says so in the `timeout` log row's `reap_failed` field.

**What goes through it.** The two `.claude/settings.json` end-side hooks are
wired as `stop-queue.mjs enqueue -- <the command they used to run>`, so their
scripts are untouched. The three himmel-ops `SessionEnd` hooks already
full-body-detach themselves, so their seam is that call site: `detach_queued
<key> …` in `scripts/lib/detach.sh` instead of `detach_run`. The worker then
runs each job with `HIMMEL_DETACH_INLINE=1`, which makes every nested
`detach_run` synchronous — without it the queued work would escape the worker
the moment it started and the bound would buy nothing.

**Secrets never reach an entry.** An entry records argv, so `detach_queued` is
used ONLY for the outer self-re-exec (argv = a script path plus a payload file).
The inner relay calls — a `curl` whose URL carries a bot token — stay on plain
`detach_run` and are run inline by the worker. The environment an entry carries
is a prefix allowlist (`HIMMEL_`, `CLAUDE_`, `VOICE_`, `WHERE_ARE_WE_`,
`JIRA_NUDGE_`, `DETACH_`): enough for a job to behave as its OWN session would
rather than as the session that happened to start the worker, never the
session's credentials, which each hook loads from a `.env` inside the job at run
time.

**A job's environment is an allowlist, not "everything minus secrets"**
(HIMMEL-2030). The worker OUTLIVES the session that started it and drains other
sessions' entries, so a name-pattern denylist over its own environment was the
wrong shape: it could only strip credential names someone had written down, and
this box carries names it does not match (`GGS_MQTT_PASS` is neither `PASSWORD`
nor `PASSWD`). A job's environment is now built in three layers:

1. **Allowlist base** — named system/interpreter variables and nothing else: the
   Windows/Git-Bash set (`SystemRoot`, `ComSpec`,
   `PATHEXT`, `MSYSTEM`, `APPDATA`/`LOCALAPPDATA`, the `ProgramFiles` roots …),
   the POSIX set (`SHELL`, `TERM`, `LANG`, the `LC_*` locale set, `TZ`, the
   `XDG_*` base dirs, `USER`) and the version-manager namespaces (`NVM_*`,
   `FNM_*`, `VOLTA_HOME`, `ASDF_*`). Enumerated empirically on Windows Git-Bash
   — every interpreter and every queued end-side hook re-run under a narrowed
   `env -i` — with the cross-platform names justified in the list itself. Every
   name is spelled out: there are **no prefix wildcards**, because a prefix
   inside an allowlist is a denylist by another name (`^XDG_` would also admit
   `XDG_MQTT_PASS`). The list is `ENV_SYSTEM` in `scripts/hooks/stop-queue.mjs`.
2. **The entry's own snapshot**, authoritative over the names it owns — which
   is now that whole system set as well as the gate/path names, because `TZ`,
   `LANG`, `LC_*`, `XDG_*` (where a tool keeps its config, and on Linux its
   credentials) and the version-manager roots are per-SESSION, not machine
   constants. So for an entry that has a snapshot the base ends up **empty**:
   nothing at all crosses from the worker, and every value a job sees came from
   the session that queued it. The allowlist base is what a legacy
   snapshot-less entry (queued before an upgrade, still inside its TTL) falls
   back to rather than starving — and it is exact names only, never the
   snapshot's `HIMMEL_`/`CLAUDE_`/… prefixes: a prefix would admit
   `HIMMEL_MQTT_PASS`, and the worker's own gates are another session's answer.
   That branch owes a pre-snapshot entry enough environment to RUN, nothing more.
3. **The secret-name denylist as a second fence** over the result, which is what
   catches an entry file written by an older version or edited on disk.

An unnamed variable does not cross, whatever it is called — so a credential
under an unguessable name cannot reach another session's job.

**Escape hatches.** `HIMMEL_STOP_QUEUE_OFF=1` makes `detach_queued` fall back to
plain `detach_run` — losing the bound is acceptable, losing the work is not; the
same fallback fires wherever node or the script is absent (an adopter running
these hooks outside this checkout). `HIMMEL_STOP_QUEUE_ENV_EXTRA` is a
comma-separated list of extra variable NAMES a job needs, for a platform this
enumeration never saw — an adopter is never bricked by a missing name. Set it in
the shell that launches Claude; matching is case-insensitive. It widens what the
entry's **snapshot** carries, not what the base inherits, so both the name and
the value come from the session that queued the job — widening the base instead
would hand a job another session's value for a name its own session chose. That
also means a hatched variable's value is written into the entry file: name
platform constants, never a credential (the denylist refuses the obvious shapes,
but the never-enqueue-a-secret rule above still governs). Spec:
`scripts/hooks/stop-queue.test.mjs` plus cases 4–6 of
`scripts/lib/test-detach.sh`.

Codex parity is unchanged: the queue is a wrapper, not a hook, and every wired
command still names the same `.sh`/`.ts` script, so
`scripts/codex/test-codex-hook-parity.sh` sees the same end-side inventory and
the `CLAUDE_END_ONLY` allowlist is untouched.

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

**Five distinct hooks across three matchers** wired in `.claude/settings.json`
fire AFTER a tool call completes: `auto-arm-on-subagent-cap.sh` and
`session-run-hook.ts` (matcher `Agent`), `trigger-cr-on-pr-create.sh` and
`trigger-cr-on-push.sh` (matcher `Bash`), and `shadow-ledger.mjs` (matcher
`Bash|Edit|Write|MultiEdit|NotebookEdit`). `session-run-hook.ts` and
`shadow-ledger.mjs` are the passive observability taps described below, not
enforcement hooks.

### Passive observability taps — `session-run-hook.ts` + `shadow-ledger.mjs`

Both scripts are wired across many hook events — PreToolUse, PostToolUse,
SessionStart, SessionEnd, and (`shadow-ledger.mjs` only) PostToolUseFailure,
PermissionDenied, PermissionRequest, and Notification — but neither is an
enforcement hook: they RECORD and never block. `session-run-hook.ts` appends
one row per session/subagent lifecycle event to the session-runs ledger, the
substrate the observability exporter reads. `shadow-ledger.mjs` is the
blind, hash-chained decision-record tap (HIMMEL-1529): it computes and
flushes its own shadow verdict before the request reaches the permission
layer, then defers, emitting no `permissionDecision`. Both are FAIL-OPEN,
ALWAYS — every failure path exits 0 with empty stdout, and neither may
block, slow, delay, or `ask` on a tool call, because a telemetry gap is
always cheaper than a bricked session. Detail lives in
[`scripts/observability/README.md`](../../scripts/observability/README.md)
and [`../architecture.md`](../architecture.md), not duplicated here.

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

### Advisory RED-control lint — `red-control-lint.sh` (HIMMEL-2544)

**LEAN-INVOKE — run on demand, wired into no hook, gate or CI path.** It
reports mutation controls carrying the silent failure mode the contract in
[`scripts/lib/red-control.sh`](../../scripts/lib/red-control.sh) names: a
`RED confirmed` line whose enclosing conditional tests ONLY an inequality
(`!=`) or a bare file-existence check (`-e`/`-f`), with the mutant's exit
status never compared anywhere in that block. Such a control is satisfied by a
mutant that crashed or emitted nothing — the empty string differs from
everything — so it prints "RED confirmed" while proving nothing.

```bash
bash scripts/lib/red-control-lint.sh              # defaults to scripts/
bash scripts/lib/red-control-lint.sh scripts/cr   # or any file / directory
```

One `<file>:<line> <reason>` line per hit on stdout, a summary on stderr.
**It exits 0 always** — with hits, without hits, and on internal error. That is
deliberate: a nonzero exit is all anyone needs to wire a heuristic text-matcher
into pre-commit or CI by accident, and this is a heuristic — it anchors on the
literal `RED confirmed` convention string, so a control that does not print that
phrase is invisible to it. Report-only, never a gate, by construction.

Its hit list is **empty on main by construction** — every file carrying the
convention string is compliant — so any line it prints is new. That is an
invariant maintained at **review time**, deliberately not gated in CI: T9 of the
smoke test scans the real `scripts/` tree and *reports* any hits into the suite
log, but passes regardless, because failing there would make an advisory tool a
gate through `run-shell-tests.sh` and let one heuristic false positive turn the
whole shell suite red on unrelated work. The deterministic assertion that does
fail on a regression is T8's, over the suite's own fixture tree. Smoke test:
`scripts/lib/test-red-control-lint.sh`.

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

### Fails-open-on-unknown lint (`lint-fail-open.sh`, HIMMEL-1776)

**Convention: every guard classifies its input allow / deny / unknown — and
unknown never silently takes the allow path.** HIMMEL-1776 was filed against
5 confirmed instances of this one rule implemented wrong in one leg. The
lint pins 4 SHAPES (`unreadable-config`, `sentinel-not-denied`,
`pct-unguarded`, `quota-zero`) against 6 pre-fix reconstructions in
`fixtures/fail-open/` — `sentinel-not-denied` (an unresolvable endpoint
taking a sentinel a wildcard matrix cell matched) has 3 code-shape variants
(plain, multiline fallback arm, single-quoted literal), the other three
shapes one apiece (an unreadable denylist reading as empty; a null bank
reading passing a `>=` refuse gate; a malformed transcript resolving at zero
cost). `lint-fail-open.sh` lints the SHAPE over the guard surfaces
(`scripts/guardrails/`, `scripts/hooks/`, lanes preflights + bench,
`spawn-glm.ts`, the launcher family, `refresh-graph-map.sh`): a `-f`-gated
read with no `-r` and no failure handling, a fallback classification
literal with no hard-deny comparison, a `*pct*` threshold compare with no
unknown branch, a money reading coalesced to `0` instead of `?? null`. A
deliberate exception is marked inline — `# fail-open-ok: <reason>` (shell) /
`// fail-open-ok: <reason>` (JS) — the reason is the point, not the marker.
Each detector is proven red against a committed reconstruction of the
pre-fix code it targets (`fixtures/fail-open/`); the suite's final case
re-asserts the whole tree
stays clean, so the NEXT occurrence of this shape — the standing guard, not
a specific numbered instance — cannot merge quietly.

### Smoke tests

- `bash scripts/guardrails/test-lib.sh` — predicate behavior.
- `bash scripts/guardrails/test-guard-gh.sh` — dispatcher matrix.
- `bash scripts/guardrails/test-lint-fail-open.sh` — fails-open lint
  (also discovered by `scripts/ci/run-shell-tests.sh`).

Run after any edit to `lib.sh` or `guard-gh.sh` before pushing.

## `scripts/uninstall.sh` — wet-run REAL_HOME fence (HIMMEL-2505)

Not a hook — a guard the script carries on itself, listed here for the same
reason: it stops a destructive run the hook pipeline never sees (`uninstall.sh`
is invoked directly, not through the Bash-tool matchers). After a 2026-09-03
incident where a mutation-test run executed the script (no `--dry-run`)
against the operator's real `$HOME` and swept `~/.claude`, `~/.ssh`,
`~/.gitconfig`, `~/.codex` and `~/.local`, a WET run now refuses — before the
banner, the confirmation prompt, or any step — whenever `$HOME` carries a
live-operator marker (`~/.claude/.credentials.json`, `~/.claude.json`, an
`~/.ssh/id_*` key, or `~/.gitconfig`), unless `HIMMEL_UNINSTALL_REAL_HOME=1`
is set (the operator's own shell, the himmelctl wizard's confirmed teardown
spawn, or the VM harness — never a test suite, which must point at its own
fixture `$HOME`). `--dry-run` is never fenced; nothing is removed under it.
The refusal:

```
ERROR: refusing a wet uninstall — found <marker>
  This $HOME (...) looks like a live operator profile, not a test
  fixture. A wet uninstall here is refused by default (HIMMEL-2505,
  after the 2026-09-03 incident where a test run swept a real HOME).

  If this really IS the machine to offboard, re-run from your OWN
  shell with: HIMMEL_UNINSTALL_REAL_HOME=1 bash scripts/uninstall.sh ...
  Otherwise, pass --dry-run to preview without touching anything.
```

Same operator ruling: wet/destructive test suites now run only inside a VM,
never against a live station — see [`docs/setup/vms.md`](../setup/vms.md).

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
dedup; no `--force`/`--dedup-any` remotely). An explicit `at HH:MM` rides
`--long-gap` — a HUMAN typing a far time on Telegram IS the explicit choice the
HIMMEL-1475 long-gap guard exists to force (the guard targets the orchestrator
silently defaulting to a far park, not a typed one); `smart`/`auto` keep the bare
call (the guard exempts those sentinels by design).

**Activation flag — `TELEGRAM_AUTO_ACTIONS` (default OFF, operator-only).** A per-op
enable-list whose grammar **mirrors `HIMMEL_INITIATIVE`** (so users learn one
convention): unset / `0`/`off`/`no` → no ops (inert; `/arm` is ordinary chat);
`1`/`all`/`on`/`yes` → every NON-privileged op; else a comma-list of op names
(case-insensitive, unknown tokens dropped, pure-typo → off). v1 shipped one op
(`arm-resume`); v2 (HIMMEL-1213) adds a second, `merge-public`; v3 (HIMMEL-1272)
adds a third, `restart` (the bridge bouncing itself — see below) — each op is its own
independent opt-in token (enabling one does NOT enable the other), and
`merge-public` ships DISABLED by default like every op here — adding its name to the
dispatch table only makes it *recognizable*, never enabled. **`merge-public` is
`EXPLICIT_ONLY` (a privileged public squash-merge): the blanket `=1`/`=all`/`on`/`yes`
aliases do NOT enable it — it requires being NAMED explicitly (`=merge-public` or
`=arm-resume,merge-public`), so an operator already running `=1` for `arm-resume`
cannot silently inherit the merge capability** (HIMMEL-1213 CR). The enable-all
aliases turn on every *non-EXPLICIT_ONLY* known op. The dispatch-table keys
(`OPS`/`KNOWN_OPS` in `auto-action.ts`) are the closed op allow-list, re-asserted in
`auto-action.sh`; `EXPLICIT_ONLY_OPS` is the privileged subset the alias skips.

**Where to set `TELEGRAM_AUTO_ACTIONS` (HIMMEL-1270)** — the flag; `EXPLICIT_ONLY_OPS`
above is a code-defined constant, not an operator setting. Either the bridge's own
`~/.claude/channels/telegram/.env` (the file that already holds
`TELEGRAM_BOT_TOKEN`) or the poller's launching env — a real process env var wins
over the file. Restart the bridge to apply either way. Until HIMMEL-1270 the
poller read this key from `process.env` ONLY while the docs pointed at the file,
so a correctly-edited `.env` enabled nothing and `/mergepub` silently routed as
chat. A configured value that parses to zero ops (e.g. `arm` instead of
`arm-resume`) now logs a startup WARNING naming the unrecognised tokens, so
"I enabled it and nothing happened" is no longer indistinguishable from "it's off".

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
For `merge-public` the SAME log/line shape is reused (`arg`=PR number, `time`=SHA,
`resolved` empty) with additional `result` values: `merged` / `not-green` /
`head-moved` / `no-open-pr`, else `error`. The `result=` label is computed by
`poller.ts`'s **op-aware** `auditResult(op, rc)` (HIMMEL-1213 codex-adv): because
`merge-public` relays `merge-public-on-green.sh`'s own rc space, rc=0 logs as
`merged` (never arm-resume's `armed`) and 12/15/16 as `no-open-pr`/`head-moved`/
`not-green`, so result-keyed forensic queries stay correct for the irreversible
merge outcome.

**`restart` (HIMMEL-1272) — the bridge bouncing ITSELF.** Commands: `/restart`
(rung 1, poller only) and `/restart full` (rung 2, whole bridge). Anchored on the
whole message like the other two, so a stray `/restart` mid-sentence is chat. It
carries the SAME unconditional guards (operator-only sender, typed-not-forwarded,
not a caption) but sits in the ORDINARY tier, **not** `EXPLICIT_ONLY_OPS`: it does
no git write, touches no public repo, persists nothing in the scheduler, and its
worst case is a bridge that comes back up. The obvious abuse is a restart loop, and
the sender is already pinned to the global operator; the supervisor's
`POLLER_MAX_FAILS` breaker is the backstop.

Unlike the other two ops it has NO script — it is executed in-process by
`poller.ts` (`makeRestart`), because rung 1 must exit the caller and rung 2's
relaunch must outlive the processes it kills. `dispatchAutoAction` refuses it
(`SELF_EXECUTED_OPS`) so it can never be laundered into an `auto-action.sh` call.
Rung 1 exits 0 and lets `supervisor.ts` respawn; rung 2 shells
`schtasks /run /tn HimmelTelegramBridge` — the already-registered logon task
(`install-logon-task.ps1`), fired by the scheduler SERVICE so it is detached from
the poller it is about to kill, and so it reads the CURRENT User environment (the
only mechanism that picks up a `SetEnvironmentVariable(…, 'User')` without a
reboot). Non-Windows refuses rung 2 with rc **20** rather than pretending.

The ack is APPENDED to `outbox.jsonl` before firing and is drained by the
*respawned* poller on its next tick — this process never flushes it, because
firing is what kills the transport. Audit labels are `restarting` (accepted +
fired), `restart-unsupported` (rc 20, or a build with no restart dep wired) and
`error` (a non-zero fire rc, which is reported rather than swallowed). An accepted
restart whose fire FAILS therefore writes two lines: `restarting` then `error` —
acceptance and outcome are separate events, since the process expects not to
survive the first. Bootstrap caveat: enabling `restart` requires one manual
restart, because the flag is read at poller startup.

**`merge-public` (HIMMEL-1213) — the Telegram-authorized PUBLIC-repo merge.**
Command: `/mergepub <pr> <sha12>` (`sha12` = the PR's head SHA, ≥12 hex chars, from
the agent's PR-ready report). The 12-hex floor (48 bits, up from 7=28 bits) blunts
a prefix-grinding attack: the agent may push public fix-commits, so a 7-hex prefix
could be ground to a malicious commit sharing the operator-approved prefix and pass
both the SHA gates and `--match-head-commit` (HIMMEL-1213 gate review). Anchored on
the whole message, same as `/arm` — a mid-text or malformed `/mergepub` falls
through to chat, never auto. On a match the bridge shells the new chokepoint
`scripts/merge-public-on-green.sh <pr> <sha>` (stripped child env, no
`TELEGRAM_BOT_TOKEN`) via `auto-action.sh`'s `merge-public` case, which additionally
validates the PR is numeric and the SHA is 12-40 lowercase hex (anchored, rejecting
multi-line values) before shelling out. This is the ONLY way a public squash-merge
gets authorized — no allow-rule for this script or a public `gh pr merge` exists
anywhere, so an agent can reach it only through the broad `Bash(bash scripts/*)`
rule, and the script self-refuses under that path (see gate 7 below). The
chokepoint enforces 7 gates, mirroring `merge-on-green.sh`'s (HIMMEL-1042)
structure but with the binding INVERTED (public-pinned, not private-only) — see
`scripts/merge-public-on-green.sh`'s header for the full exit-code reference:
1. **Repo pin** — the PR's own URL must resolve to `CR_PUBLIC_REPO` (default
   `yotamleo/Himmel`, the same env var `.claude/commands/cr-public.md` uses) —
   never cwd-derived (the script runs from the bridge's private-checkout cwd).
2. **PR OPEN + base = default branch**, re-verified FRESH immediately before
   merging (the HIMMEL-1080 retarget-race lesson, ported verbatim).
3. **Head identity** — the PR's `headRefOid` must prefix-match the
   operator-supplied SHA, checked BOTH up front and at the fresh pre-merge
   re-verify. Mismatch = refuse ("head moved"), never merge.
4. **`check-ci.sh` exit 0** is the only pass (CI green + zero unresolved threads
   + no changes-requested + the HIMMEL-1126 body/outside-diff gate). Since this
   script runs from the private-repo cwd, it invokes `check-ci.sh` with the PR's
   full URL as the selector, never a bare number, so gh resolves the right repo.
5. **Audit preflight + durable MERGING record** before the merge; refuse if the
   sink is unwritable (same fail-closed contract as `merge-on-green.sh`).
6. **`gh pr merge <pr> --squash --admin --repo <repo> --match-head-commit
   <fresh-headRefOid>`**, then poll to confirmed `MERGED` before reporting
   success — a zero `gh` rc means "accepted", never "merged" outright.
7. **`CLAUDECODE` self-refusal** — exits immediately (before any gh call) if the
   `CLAUDECODE` env marker is present; the bridge spawns this script's env
   WITHOUT that marker, so this can only fire on an agent-initiated call.
Deliberately a SEPARATE script from `merge-on-green.sh`, not a shared "which
repo class" switch — the private-only guard there is a safety boundary, and a
flag that inverts a safety boundary is the failure mode this avoids. Supports
`--dry-run` (every gate runs, no merge fires) for manual/terminal shakedown; the
Telegram command grammar has no dry-run variant. Not added to `PRIVATE_PATHS` —
it is propagatable (no operator secrets; the repo name is already public
knowledge) — only the activation flag + `allowFrom` are operator-personal.

**Still HARD-blocked (out of scope):** editing `access.json`/`settings.json`,
`--force`/`--dedup-any` arms, merging PRs *except via the head-SHA-bound
`merge-public` op*, ops other than `arm-resume`/`merge-public`/`restart` (the
closed allow-list is `OPS`/`KNOWN_OPS` in `auto-action.ts` — this line tracks it).

Tests: `scripts/telegram/{router,auto-action,poller}.test.ts` (bun) +
`scripts/telegram/test-auto-action.sh` + `scripts/test-merge-public-on-green.sh`
(privileged-script smoke).

## Claude invocation billing (HIMMEL-128)

Anthropic announced that from **2026-06-15** it would split headless Claude
Code invocations (`claude -p`, `claude --print`, `claude --bg`, Agent SDK)
onto a separate monthly Agent SDK credit bucket on Max subscriptions. The
split was **PAUSED** at the announced cutover, observed **2026-06-21**.

HIMMEL-1748 then measured the actual subscription-authenticated CLI path on
**2026-08-11/12**: `claude -p` draws from the **same** 5-hour/weekly usage
bank as interactive sessions. A 48-chunk luna refresh exhausted that bank
about 2.9 hours in and chunks 27-48 failed. Invocation shape is therefore
not the current cost question; pre-run bank state is.

**Rule for scripts in this repo:** scheduled or unattended sites route
through `scripts/lib/bank-preflight.sh` before spending. Headless calls parse
the result with `--output-format json` rather than sniffing prose and declare
an explicit `--permission-mode` (never `bypassPermissions`). These are
review-enforced conventions, not structural guarantees.

The `no-headless-claude` pre-commit hook
(`scripts/hooks/check-no-headless-claude.sh`) flags new `claude -p` /
`--print` / `--bg` introductions unless an opt-in marker is present:

```bash
# headless-claude-ok: <one-line reason>
claude --print "$prompt"
```

The mechanism verifies marker **presence only**. It does not parse the reason;
any string passes. Its honest purpose is to force a pause and a documented
decision at every new headless introduction; it does not validate the preflight,
JSON-output, or permission-mode conventions. Same-line trailing comments work
too. Exempt paths (no check): `docs/`, `handovers/`, `.agents/` (vendored),
`.claude/commands/*.md` (slash-command docs), `CLAUDE.md`.

**Re-measure recipe:** snapshot the `five_hour` and `seven_day` `utilization`
values, run one known subscription-authenticated `claude -p` job, then snapshot
both values again and compare the deltas.

Refs: HIMMEL-1748; `scripts/graphify/refresh-graph-map.sh`;
`scripts/lib/bank-preflight.sh`;
https://code.claude.com/docs/en/headless.md.

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
