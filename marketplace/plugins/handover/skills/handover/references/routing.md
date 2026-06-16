# Target Repo Resolution — Full Algorithm

Reference for SKILL.md "Target Repo Resolution" section. Load only when the resolution rules in SKILL.md don't yield an unambiguous repo, or when implementing init/register.

## Resolution chain

1. **CWD match (primary).**
2. **Conversation alias (fallback).**
3. **Prompt user (ambiguity/none).**

No session cache. Resolution runs every invocation. Cheap (one git command + one JSON read).

## Step 1 — CWD match

Goal: detect when the operator is working inside a registered repo (or any of its worktrees) and route there.

```bash
git -C "<cwd>" rev-parse --path-format=absolute --git-common-dir
```

- Returns absolute path to the common `.git` directory regardless of whether `<cwd>` is in a regular checkout or a linked worktree.
- Regular checkout: `/abs/path/to/repo/.git` → parent = repo root.
- Linked worktree: `/abs/path/to/main-repo/.git` (worktrees share the common dir) → parent = main repo root.
- Take **parent of `--git-common-dir`** to reach the main checkout root.

**Why `--path-format=absolute`:** without it, regular checkouts return literal `.git` (relative). Taking parent of `.git` yields `.`, not the repo root, and registry comparison silently fails. The `--path-format=absolute` flag forces the absolute form. Requires git ≥2.31 (March 2021).

### Canonicalisation

Apply to both the resolved cwd-root and each registry `path` **before comparing**:

| Step | Rule |
|---|---|
| Drive letter | Lowercase (`C:` → `c:`). Windows-only. |
| Separator | All `\` → `/` |
| `$HOME` | Expand `~` and `$HOME` to absolute |
| Trailing slash | Strip (`c:/foo/` → `c:/foo`) |
| Case-fold path body | Do not. Filesystem may be case-sensitive (WSL/Linux). Only normalise drive letter on Windows. |

Compare normalised strings byte-for-byte.

### Submodules

If the cwd is inside a submodule, `--show-superproject-working-tree` returns the superproject root. **v1 does not auto-recurse to superproject.** Treat submodule as its own repo for resolution; register it explicitly if needed.

## Step 2 — Conversation alias match

Only runs when step 1 produces no match.

1. Look at the most recent 3 user turns (the system reminder, current message, and immediate prior message).
2. For each registered repo, check if any of its `aliases` or `keywords` appears as a case-insensitive substring in any of those turns.
3. Count matches:
   - **Exactly one repo has matches** → use it.
   - **Multiple repos have matches** → ambiguous, go to step 3.
   - **No repo has any match** → go to step 3.

Aliases are short, repo-specific tokens (`himmel`, `luna`). Keywords are broader topic hints (`vault`, `e2e`, `tests`) used to disambiguate cross-cutting requests.

## Step 3 — Prompt

When step 1 and step 2 fail:

- Render an `AskUserQuestion` with options = registered repos (up to 4; if more than 4, include top by usage + "Other").
- Header label: short repo name. Description: registered path.
- The choice is **not cached** — repeated invocations re-prompt. Reason: routing errors are silent and expensive; cheap prompts beat sticky misroutes.

If the registry is empty, the response is:

```
No repos registered. Run /handover init <name> to bootstrap a new repo,
or /handover register to adopt an existing handovers/ tree.
```

## Read-only relaxation

`handover-resume`, `repos list`, `repos where`, and `update-status` (regen-only) may skip step 3 when the user's intent is clearly aimed at a specific repo (e.g., they typed `handover-resume #41 in himmel`). The relaxation applies only when an alias is present in the **current turn** (not historical turns).

## Worktree paths in the registry

A registered `path` always points to the **main checkout root** (parent of `--git-common-dir` of the cwd at registration time). Worktrees are never stored in the registry. The worktree gate (see SKILL.md) handles per-item worktrees against the registered main checkout.

If init is run from inside a worktree, the resolved main-checkout-root is stored — worktrees may come and go without rotting the registry.

## Cross-repo writes

When the resolved target repo differs from `parent(--git-common-dir)` of the cwd (e.g., user is in `luna` but typing about `himmel`), no extra restriction applies in v1. The worktree gate enforces "not on main" against the **target repo**, not cwd. The operator may need to navigate to the target repo's worktree manually if they want to commit the resulting state changes from a more convenient terminal.

## Atomic registry writes

`~/.claude/handover/registry.json` is read on every command, written by `init` / `register` / `repos add` / `repos remove`. Write protocol:

1. Read current file (if exists). If JSON parse fails, refuse and report — never silently overwrite.
2. Produce updated structure in memory.
3. Write to `~/.claude/handover/.registry.json.tmp.<pid>` (same volume, same dir).
4. Validate that the tmp file is valid JSON by re-reading it.
5. Atomic rename to `registry.json`.
6. On any step's failure: delete tmp, leave original intact, surface error to user.

Cross-volume rename is not atomic on Windows. Refuse to operate if `~/.claude/` and the tmp file end up on different volumes (should never happen with the same-dir convention above; only fails if `~` itself is unusual).

## Error surfaces

| Situation | Behaviour |
|---|---|
| `~/.claude/handover/registry.json` missing | Treat as empty `{"repos": {}}`. `init` creates it. |
| Registry JSON malformed | Refuse all commands. Tell user: "registry corrupt at `<path>`; back it up and re-register repos." |
| Step 1 yields a path not in registry | Step 2 takes over. Do not auto-register. |
| Registered path no longer exists on disk | Warn on first read; do not auto-remove. Operator runs `/handover repos remove <name>`. |

## v2 — Numeric ID scan across both namespaces

`handover-resume <X>` and any internal item lookup MUST scan both namespaces:

1. If `<X>` is `HIMMEL-K` form (or any `<project>-K` form) → scan `epics/<X>-*/`, `epics/*/tasks/<X>-*/`, `standalones/<X>-*/`. Single namespace.
2. If `<X>` is bare numeric `15` → scan BOTH:
   - Jira-keyed: `<repo-jira-project>-15-*/`
   - Legacy: `#15-*/`
3. Multi-match → No-ID picker, augmented with bucket + priority + status per option.
4. No-match → return "No item with ID `<X>` found in <repo-name>."

Numeric never spans repos. Target-repo resolution runs first; lookup is scoped to one repo.
