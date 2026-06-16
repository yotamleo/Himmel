# Handover System — reference

> Extracted from `CLAUDE.md` per HIMMEL-164 (state-not-prompt slimming).
> CLAUDE.md keeps a session-time pointer; the full reference lives here.
> The v2 handover skill
> (`marketplace/plugins/handover/skills/handover/SKILL.md`) +
> `~/.claude/handover/registry.json` are the live source of truth for
> registered repos, paths, and routing — inspect/change via the
> `/handover repos|register|init` slash commands, not by editing docs.

**Post-HIMMEL-124 (2026-05-25):** all personal handover state has been
centralized in your handover state repo (configured via `/handover-setup`
/ `$HANDOVER_DIR`). himmel `handovers/<USER_SLUG>/` is
empty except for a README pointer. Three resolution layers — the v2
handover skill's multi-repo registry (preferred for skills), the
HIMMEL-118 single-root resolver (still wired for scripts), and a
recommended `HANDOVER_DIR` bridge for non-skill consumers.

## v2 multi-repo registry (preferred for skills)

The v2 handover skill (`marketplace/plugins/handover/skills/handover/SKILL.md`)
is the source of truth. Don't duplicate its state here — paths,
registered repos, and routing rules belong in
`~/.claude/handover/registry.json`, not in this doc. Use these
slash commands to inspect or change state:

- `/handover repos` — list currently registered repos + their roles.
- `/handover register` — add a new repo (prompts for path, user slug, aliases).
- `/handover init` — bootstrap the registry on a fresh machine.

**Bucket-name semantic (HIMMEL-147):** each registry entry carries an
optional `bucket_name` field. The HIMMEL-129 bucket-layout resolver
reads this when deciding which `<state-root>/<bucket>/` directory a
repo's handover state lands in. Default: slugified `basename(path)`.
`/handover register` + `/handover repos add` refuse on collision —
two repos resolving to the same `bucket_name` is ambiguous; the
operator must pass `--bucket-name=<unique>` to disambiguate. Existing
entries auto-backfill from `basename(path)` on first read. Fresh-fork
operators (e.g. forks of himmel named `cool-tool`) get the right
bucket out of the box without code edits.

**Branch-prefix semantic (HIMMEL-139):** the registry's `branch_prefix`
field is the **handover-mutation** prefix. It scopes branches created
by `new-epic`, `new-task`, `new-standalone`, `end-session`, and
`update-status` — the operations that mutate `<state-root>/`.
Default: `handover/` (changed from `feat/` as of HIMMEL-139). This
is NOT the general feature-branch prefix used by `/worktree.sh` for
ticket-driven feature development; those follow the `type/slug`
convention enforced by the orchestrator (`feat|fix|chore|docs|refactor|test`).

**Auto-branch + commit + push (HIMMEL-140):**
`scripts/handover/auto-commit.sh` no longer commits on whatever branch
is currently checked out. Each invocation:

1. Reads `branch_prefix` from registry.json for the resolved handover
   repo (default `handover/`).
2. Extracts the first `PROJECT-N` ticket from the commit message and
   derives a slug from the remaining text (lowercase, non-alnum →
   dash, ≤30 chars).
3. Switches to `<branch_prefix><TICKET>-<slug>` (or
   `<branch_prefix>session-YYYY-MM-DD` when no ticket is detected) —
   reusing the branch if it already exists locally or on origin.
4. Stages + commits .md changes there.
5. Auto-pushes (`-u origin <branch>`) for resilience — every commit
   ends up on the remote even if the local clone is later lost.

`HANDOVER_DIRECT_MAIN=1` restores the v1 commit-on-current-branch
behavior (kept as an opt-in feature flag until the branched flow is
fully validated). `--no-push` skips the push step (useful for tests
or offline work). Smoke test:
`bash scripts/handover/test-auto-commit.sh`.

**PR open/update + squash finisher (HIMMEL-141):**
After every push on the branched path, `auto-commit.sh` invokes
`scripts/handover/pr-open.sh` to open (first push) or update (later
pushes) the PR for `<branch_prefix><TICKET>-<slug>`. Body has three
sections: `## Summary` (Jira ticket title when available),
`## Files changed` (auto from `git diff --name-status vs base`),
`## Ticket` (HIMMEL-N link).

PR-create failures are best-effort: the branch is still pushed and
an operator can open the PR manually later. `HANDOVER_PR_AUTO=0`
skips the PR layer entirely (no-op exit 0).

`scripts/handover/pr-merge.sh` fires the merge:
`gh pr merge <N> --squash --admin --delete-branch`. Squash is the
only allowed mode — repo settings forbid merge-commits (operator
confirmed 2026-05-25). The script suppresses the cosmetic
`failed to run git: fatal: 'main' is already used by worktree` error
when the local branch-delete trips on a held worktree (remote PR is
merged either way).

Slash commands: `/handover-pr-open`, `/handover-pr-merge`. Smoke
test: `bash scripts/handover/test-pr-open.sh`.

**Session-end consolidation sweep (HIMMEL-143):**
`scripts/handover/flush.sh` walks every local `handover/*` branch in
the resolved handover repo and reconciles state:

- Unpushed → `git push -u origin <branch>`.
- No open PR → invokes `pr-open.sh`.
- Merged into `origin/main` (squash-detected via `git cherry`) →
  report by default; `--cleanup` deletes the local branch.

Wired into `/context-hop`: `hop.sh` runs flush.sh before writing the
snapshot so cap-resume hand-off cannot leave un-pushed handover state.

Failure modes:
- `gh` missing or unauthenticated → warns + dumps the exact commands
  the operator must run to open each PR. Push step still runs.
- Per-branch errors surface in the table; sweep continues.

Slash command: `/handover-flush` (+ `--dry-run`, `--cleanup`,
`--no-pr-open` flags). Smoke test:
`bash scripts/handover/test-flush.sh` (14/14 pass).

**Pre-push CR runs on `handover/*` branches (HIMMEL-142):**
The `code-review-before-push` pre-commit hook
(`.pre-commit-config.yaml` line 100) has no `handover/*` exclusion
— intentional. Operator decision: CR runs as a sanity audit to catch
accidental code edits sneaking into handover branches. The
docs-only-skip already wired into
`scripts/hooks/check-cr-before-push.sh` (line 61 filters out `.md`
/ `.txt` / `docs/` / `handovers/` paths) gives the right behavior:

- Pure handover state diff (only `.md` / `handovers/*` files) →
  hook prints `docs-only change — skipping marker write`, exits 0.
  No CR gate. Runtime effectively 0s.
- Mixed code + state diff (code creep into a handover branch) →
  CR marker written; operator must run `/pr-check` (or
  `/pr-review-toolkit:review-pr`) before opening the PR.

Smoke test: `bash scripts/hooks/test-check-cr-before-push.sh`
(7/7 pass).

Pre-HIMMEL-124 the skill resolved per-repo state under
`<repo-root>/handovers/<user>/`. Post-HIMMEL-124 the expected target
is the **`<state-repo>`** for any personal state regardless of which repo
triggered the skill. HIMMEL-129 added the bucket layer
(`<state-root>/<repo>/{epics,standalones}/` where `<repo>` ∈
himmel | luna | luna_brain | cross) — SKILL.md resolver auto-detects
the layer when any bucket dir exists under `<state-root>` and falls
back to the flat layout otherwise.

## HIMMEL-118 single-root resolver (still wired for scripts)

`scripts/lib/handover-path.sh` provides a single-root resolver that
shell scripts use when they only know about one root:

- **Mode A — inline (default)**: `HANDOVER_DIR` unset → `<repo>/handovers/`.
  Post-HIMMEL-124 this resolves to a near-empty `himmel/handovers/`
  (just the README stub). Useful only for himmel-scoped legacy code.
- **Mode B — external**: `HANDOVER_DIR` set → that path. **Recommended
  default** post-HIMMEL-124:
  ```bash
  export HANDOVER_DIR="$HOME/Documents/github/<state-repo>/handovers"
  ```

Consumed by `scripts/handover/auto-commit.sh`,
`scripts/handover/arm-resume.sh`, `setup.sh`'s step 6, and
`docs/handover/overnight-mode.md` Phase 1 (plans-root resolution per
HIMMEL-133).

Scripts, commands, and skills must NOT hardcode `./handovers/`.
Source `scripts/lib/handover-path.sh` and call `handover_root`
instead. The resolver fails CLOSED when `HANDOVER_DIR` is set but
points to a missing path. Mode + root are reportable via
`/handover-link` (`status` default, `doctor` exits non-zero on
misconfiguration).

## Migration timeline + open work

- **HIMMEL-13** (done) — initial migration of cross-project subset
  (luna/, manual_notes.md, random_dreams.md) from himmel/handovers/
  → <state-repo>/handovers/.
- **HIMMEL-124** (in progress) — full centralization. 234 files
  migrated from himmel/handovers/<USER_SLUG>/* → <state-repo>/handovers/<USER_SLUG>/
  (PR #138). himmel side reduced to a stub README. **Remaining:**
  registry.json + SKILL.md updates to make <state-repo> the resolved
  default for personal-state ops.
- **HIMMEL-129** (done 2026-05-25) — split flat
  `<state-repo>/handovers/<USER_SLUG>/` layout into `cross/himmel/luna/luna_brain/`
  subfolders. 17 standalones + 15 epics routed by ticket prefix.
  `<state-repo>/README.md` + SKILL.md resolver updated; bucket layer is
  opt-in (activated by presence of any bucket dir under `<state-root>`).

## User-slug resolution (HIMMEL-145)

Handover bucket paths (`<state-root>/<USER_SLUG>/...`), registry.json
`user` field, and a few scratch dirs need the operator's user slug.
Resolved by `scripts/lib/user-slug.sh`:

1. `$USER_SLUG` env var (preferred — explicit operator intent).
2. GitHub username via `gh api user -q .login`, slugified (HIMMEL-297 — the
   slug is the GitHub user id; one network call, gated behind `$USER_SLUG`).
3. `git config user.name` slugified (kebab-case, lowercase, non-alnum
   → dash, ≤30 chars) — offline fallback when gh is absent/unauthenticated.
4. Fail with a hint pointing at `.env.example` + `gh auth` / `git config` setup.

Callers source the lib + call `user_slug` (raw) or `user_slug_verify`
(prints resolved value + source to stderr; used in `setup.sh`'s
step 0.5 to fail loud at install time).

Doc references to operator-specific paths should use the
`{{USER_SLUG}}` placeholder in templates + `<USER_SLUG>` in prose.
`scripts/test-user-slug-resolve.sh` smoke-tests all paths (18/18 pass).

This is the HIMMEL-132 Phase 2 envification. Existing `yotam`-hardcoded
references in journal/docs/* paths are out of scope — sweep deferred
to a follow-up ticket if/when an alternate operator joins.
