# Daily loop walkthrough

> **Prerequisites:**
> 1. himmel installed and configured on your machine — see
>    [docs/setup/new-machine.md](setup/new-machine.md) (or
>    [docs/setup/use-on-your-project.md](setup/use-on-your-project.md) if you're
>    adopting the portable core in your own repo).
> 2. **An active Claude Code session in the repo root** — run `claude` in your
>    terminal (or use your IDE's Claude extension). Need
>    [Claude Code](https://claude.com/claude-code) first?
>    `curl -fsSL https://claude.ai/install.sh | bash` (Linux/macOS) /
>    `irm https://claude.ai/install.ps1 | iex` (Windows). Every hook behaviour
>    below fires *inside* a session; the steps assume you are already in one.

This page walks one complete loop — a toy change from worktree creation
to handover — explaining every hook and gate you will hit along the way.
By the end you will have run the real workflow on a real branch.

---

## Toy change used throughout

We will add a single line to `docs/contributing.md`. Docs-only change, no
shell scripts touched. That simplifies the attestation story; the
differences for code or script changes are called out inline.

---

## 1. First touch on main — the block-edit-on-main surprise

Before you create a worktree, try editing a file in the primary checkout
(i.e., while Claude's working directory is the repo root with `HEAD ==
main`). Claude will attempt the edit and immediately hit:

```
⛔ block-edit-on-main: refusing to edit `docs/contributing.md` from PRIMARY worktree while HEAD == main.
(resolved path: /abs/path/docs/contributing.md)

Feature work must go in a worktree per CLAUDE.md. To start one:

    /clean_garden feat/<scope>          # prune merged worktrees + create new
    cd .claude/worktrees/feat+<scope>   # switch in the existing shell

Or to bypass for an emergency hotfix, set EDIT_ON_MAIN_OK=1 in the shell
that launched Claude Code (the hook reads its environment, so per-edit
prefix syntax cannot work — Claude Code cannot inject env vars into a
hook process). Example:

    EDIT_ON_MAIN_OK=1 claude

The bypass lasts for the entire Claude Code session (it's session-sticky,
not per-edit). Restart Claude without the env var to re-enable the guard.

Or temporarily comment out the hook stanza in .claude/settings.json.
```

This is a **PreToolUse hook** (`scripts/hooks/block-edit-on-main.sh`) that
fires on every Edit/Write/MultiEdit tool call. It exits 2 so Claude sees
the error and the edit never happens. The message tells you exactly what
to do: create a worktree first.

**The bypass** (`EDIT_ON_MAIN_OK=1`) must be set in the shell that
launched `claude`, not as a per-command prefix — a per-call prefix cannot
reach the hook process. Bypass is intentionally session-sticky so you
cannot accidentally toggle it per-edit.

---

## 2. Create a worktree

```
/worktree docs/himmel-289-daily-loop
```

`/worktree` is a thin alias for `/clean_garden --no-prune`. It creates
`.claude/worktrees/docs+himmel-289-daily-loop/` and checks out a new
branch `docs/himmel-289-daily-loop`. Branch names must be `type/slug`
where type is one of `feat|fix|chore|docs|refactor|test`.

You now have an isolated copy of the repo. Claude's file operations in
this session target the worktree path, not the primary checkout — the
`block-edit-on-main` hook will no longer fire.

To prune old merged-PR worktrees at the same time, use `/clean_garden
docs/himmel-289-daily-loop` (runs prune then create). To only prune
without creating a new one, use `/clean`.

---

## 3. Make the change

Edit `docs/contributing.md` inside the worktree. For this walkthrough,
add one line:

```markdown
<!-- toy change for daily-loop walkthrough -->
```

Nothing fires at edit time for file writes inside a worktree. The hooks
that run at edit time only block edits on main.

---

## 4. Commit

```
git add docs/contributing.md
git commit -m "docs: [HIMMEL-289] toy change for daily-loop walkthrough"
```

The **commit-msg gate** (`check-commit-msg.sh`) runs and validates:

```
Pattern:  type[(scope)][!]: [HIMMEL-N ]message
Types:    feat fix chore docs refactor test style perf ci build revert
```

If you get the format wrong you see:

```
COMMIT REJECTED: message does not match conventional commit format.

  Required:  type(scope): message
  Optional:  type(scope): HIMMEL-N message

  Types: feat fix chore docs refactor test style perf ci build revert

  Examples:
    feat(auth): add JWT validation
    fix(api): HIMMEL-23 correct status code on 404
    chore: update dependencies

  Got: my bad message
```

Fix the message and commit again. Once the format is valid the commit
succeeds and pre-commit runs the standard linters (trailing-whitespace,
end-of-file-fixer, check-yaml, check-json, shellcheck, gitleaks).

### Attestation trailers — when they are required

Trailers go in the **commit body** (blank line after the subject), not in
the subject line. They are required only in certain circumstances:

| Change type | Trailer required |
|---|---|
| Touches `*.sh`, `*.bash`, `*.ps1`, `scripts/**`, `**/bin/*` | `Platforms tested: <os>` |
| Touches any non-docs code (non-`*.md`/`*.txt`/`docs/`/`handovers/`) | `Security reviewed: <token>` |
| Docs-only (`*.md`, `*.txt`, `docs/**`, `handovers/**`) | _neither required_ |

Our toy change is docs-only — no trailers needed. For a change that DOES
require them, the full commit looks like:

```
fix(scripts): HIMMEL-42 correct bash exit code

Platforms tested: linux, windows
Security reviewed: manual

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
```

Trailers go in the **first commit** after genuinely testing and reviewing
— not in a reactive amend. If you forget, add a **new commit** that only
adds the trailer (amending is hard-blocked in auto-mode). Details:
[docs/internals/stuck-playbook.md](internals/stuck-playbook.md).

Recognised platform tokens: `linux windows macos ubuntu debian fedora
arch mac darwin wsl posix gitbash git-bash powershell pwsh`.

Recognised security-review tokens: `manual claude-code-security-review
pr-review-toolkit ad-hoc`.

---

## 5. Push

```
git push -u origin docs/himmel-289-daily-loop
```

Several **pre-push gates** run in sequence:

| Gate | What it checks |
|---|---|
| `no-push-to-main` | Blocks pushes directly to `main`. |
| `npm-audit` / `npm-licenses` / `npm-audit-signatures` | npm dependency hygiene on changed packages. |
| `code-review-before-push` | Writes a CR marker (see below). |
| `platforms-tested` | Shell/script changes need `Platforms tested:` attestation. |
| `security-reviewed` | Non-docs changes need `Security reviewed:` attestation. |
| `pr-mergeable-gate` / `no-force-push` | Branch not conflicting, no force-push. |

For our docs-only change, `platforms-tested` and `security-reviewed` skip
themselves (docs-only fast-path). The important gate is
`code-review-before-push`.

### The CR marker flow

On push, `check-cr-before-push.sh` writes a marker file at
`.git/cr-pending/docs/himmel-289-daily-loop`. It does NOT run a review;
it just flags that a review is owed. You see:

```
→ code-review: docs-audit marker written for docs/himmel-289-daily-loop (HEAD=abc1234). Run /pr-check (docs-audit lane: one code-reviewer with the docs charter) before opening the PR — docs are never zero-CR (HIMMEL-303).
```

(Our toy change edits `docs/contributing.md`, a reviewable doc, so it gets a
`docs-audit`-lane marker. A code diff would get a `full`-lane marker instead;
a handover-state-only diff gets none.) Push succeeds either way — the marker
is advisory at push time and becomes a hard block at PR creation time.

> **Docs-only path (HIMMEL-299/303):** Reviewable docs (`docs/`, repo
> `*.md`/`*.txt`) are **never zero-CR**. The `code-review-before-push` gate
> writes a **`docs-audit` marker** for them (HIMMEL-303), so `gh pr create`
> is blocked until `/pr-check` clears it — same hard gate as code, but a
> lighter lane: `/pr-check` reads the marker's `docs-audit` lane and runs ONE
> `pr-review-toolkit:code-reviewer` with the docs charter (repo-claim accuracy
> — hooks/gates/flags/paths/commands vs the actual code — dead links, stale
> file/flag/ticket refs, example correctness, internal consistency; not prose
> nitpicks; `CLAUDE.md` → `/claude-md-audit`) instead of the 6-reviewer set.
> **Handover state stays exempt:** `handovers/` diffs (and handover/* state
> commits) get NO marker — personal auto-committed state, not reviewable docs.

---

## 6. Run /pr-check

A marker was written (reviewable docs → `docs-audit` lane; code → `full`
lane), so run:

```
/pr-check
```

`/pr-check` reads the marker's lane: a `full`-lane marker runs the multi-agent
review; a `docs-audit`-lane marker (our toy docs change) runs ONE
`pr-review-toolkit:code-reviewer` with the docs charter. Either way, when the
review passes `/pr-check` deletes the marker file. If findings are critical,
address them before continuing.

While the marker exists, `gh pr create` is blocked by the
`check-cr-marker-on-pr-create` PreToolUse hook:

```
CR review pending for docs/himmel-289-daily-loop (HEAD=abc1234). Run /pr-check (or /pr-review-toolkit:review-pr) first. After review passes, marker auto-clears.
```

You cannot open a PR until the marker is cleared by a passing review.

---

## 7. Open the PR

Once the marker is cleared (a marker is only ever skipped for a handover-only change):

```
gh pr create --title "docs: [HIMMEL-289] toy change for daily-loop walkthrough" \
  --body "Toy change per daily-loop walkthrough."
```

PRs require **≥1 approval** before merge. Request a reviewer or wait for
the approval in the normal GitHub flow.

---

## 8. Merge

After approval:

```
gh pr merge --squash
```

The branch is squash-merged into main. The worktree is now stale.

---

## 9. Clean up with /clean

```
/clean
```

`/clean` is a thin alias for `/clean_garden --prune-only`. It identifies
worktrees whose branch has a merged PR and removes them. The worktree at
`.claude/worktrees/docs+himmel-289-daily-loop/` disappears.

---

## 10. Handover

At session end (or when switching context), snapshot your in-progress
state:

```
/handover
```

The handover skill writes a structured summary of what was done, what is
in-flight, and what the next session should pick up. State is stored in
your handover state repo (not in himmel's `handovers/` stub). To resume in
a future session, use `/handover-resume-armed` or browse the handover
registry via `/handover repos`.

Full handover internals:
[docs/internals/handover-system.md](internals/handover-system.md).

---

## Summary — the full sequence

```
/worktree docs/<slug>           # 1. create worktree
# edit files                    # 2. make the change
git add …                       # 3. stage
git commit -m "type: message"   # 4. commit (commit-msg gate fires)
git push -u origin <branch>     # 5. push (pre-push gates fire)
/pr-check                       # 6. if marker was written: run review
gh pr create …                  # 7. open PR
# get approval, merge           # 8. merge
/clean                          # 9. prune merged worktree
/handover                       # 10. snapshot session state
```

---

## Hook and gate reference

| Hook / gate | Stage | What it does |
|---|---|---|
| `block-edit-on-main` | PreToolUse (Edit/Write) | Blocks edits in primary worktree while on main |
| `check-cr-marker-on-pr-create` | PreToolUse (Bash) | Blocks `gh pr create` while a CR marker exists |
| `conventional-commit-msg` | commit-msg | Validates `type[(scope)]: [HIMMEL-N ]message` |
| `code-review-before-push` | pre-push | Writes CR marker for non-docs changes |
| `platforms-tested` | pre-push | Requires `Platforms tested:` trailer on shell/script diffs |
| `security-reviewed` | pre-push | Requires `Security reviewed:` trailer on non-docs code |
| `no-push-to-main` | pre-push | Blocks direct pushes to main |

Full enforcement detail: [docs/internals/enforcement.md](internals/enforcement.md).
Recovery when stuck: [docs/internals/stuck-playbook.md](internals/stuck-playbook.md).
