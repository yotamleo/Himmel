# Stuck playbook — operational escape-hatches (HIMMEL-211)

Load-on-trigger reference for the moments Claude gets *stuck* on himmel's own
guardrails: an auto-mode write was denied, a Bash command fell through to the
classifier, a permission prompt denied a command, or a pre-push gate failed.
These are **operational/recovery** rules — they used to live in the root
`CLAUDE.md` but were migrated here (HIMMEL-211) because they are not session-time frame-shaping:
they only matter at the moment of the symptom, and paying for them on every
session is the bloat the [4 CLAUDE.md rules](#why-this-is-a-playbook-not-a-claudemd-rule)
warn against. The `himmel-ops:stuck-playbook` skill surfaces this file when the
stuck condition is detected; it carries zero always-on token cost otherwise.

**First principle (HIMMEL-195): prefer a structural fix over a workaround.** If a
shape keeps getting blocked, the fix is usually a hook/CLI change (a new
`auto-approve-safe-bash` case, a CLI flag), not a cleverer command that dodges
the classifier. The cases below are the residual judgment calls after the
structural fixes are exhausted. **Never reshape a command to dodge a guardrail —
if a write is denied after following this playbook, defer to the operator.**

---

## Symptom: a Bash command is stopped by a permission prompt (HIMMEL-203)

Claude Code's native permission matcher **bails out and PROMPTS** on any command
containing variable expansion (`$t`), command substitution `$(…)`, backticks, or
compound operators — it never reads the allow-list. Interactively that prompt
renders and waits. Headless/auto it does **not** hang: an undocumented ~3 s stdin
watchdog ("no stdin data received in 3s, proceeding without it") drops the
session to non-interactive, and a prompt that cannot render resolves as a **DENY
at rc=0** — the session continues (`subtype:success`, `is_error:false`) with the
action silently not performed. 4/4 live probes (HIMMEL-1969, 2026-08-22) denied
that way, across three shapes: `-p --permission-mode manual`, `-p
--permission-mode auto`, and a bare `claude "<prompt>"` with no `-p` on a
never-delivering stdin pipe (the arm-resume/schtasks shape). The silent no-op —
not a hang — is the failure mode to design for: verify the ARTIFACT, never the
return code (the HIMMEL-1869 artifact-check rule).

The `auto-approve-safe-bash` PreToolUse hook auto-grants read-only/inspection
commands plus the allow-listed Jira CLI (incl. such loops/pipes with `$var` that
defeat the native matcher) as the structural fix. It deliberately does **not**
cover other writes, interpreters (`sed`/`awk`/bare `node`/…), or `git`/`gh`
write subcommands.

**What to do:** for anything the hook doesn't grant, prefer **literal single
commands** (no `$var` / `$(…)` / loops) so the allow-list can match. If a write
genuinely needs them and prompts, **that prompt is correct** — defer to the
operator, don't reshape to dodge it.

---

## Symptom: a leg needs a tracked file back at HEAD and `git checkout -- <path>` is denied (HIMMEL-2934)

Every TDD RED control needs a way to restore a dirtied tracked file to HEAD
before implementing, but `Bash(git checkout -- *)` is a `deny` entry in
`.claude/settings.json` (a deny beats any allow, so an allow rule cannot fix
this) and `git restore` matches no rule at all, so it falls to the classifier
and resolves as a silent headless DENY (HIMMEL-203). N158 and N159 each lost
several turns to this on 2026-09-12.

**What to do:** `bash scripts/git/restore-to-head.sh <path> [<path>...]` —
one literal command, no `cd`/`$()`/compound operators. It refuses globs,
untracked paths, directories, and paths outside the current worktree, and it
saves the outgoing content for every dirty path — a plain copy, not a diff —
to a fresh `${TMPDIR:-/tmp}/restore-to-head.XXXXXX/` directory before
restoring. To recover, use the run directory and file number recorded in MANIFEST:

Regular file: `rm -f <path> && cp -p <RUN_DIR>/<n>.worktree <path>`
Symlink: `cp -RPp <RUN_DIR>/<n>.worktree <path>`
Staged content: run from the repository root, replacing the three placeholders
below (path is root-relative). Read the saved mode and blob ID, recreating the
blob from the backup if it is no longer in the object database:

```bash
path='<path>'
run_dir='<RUN_DIR>'
n=<n>
read -r mode sha stage saved_path < "$run_dir/$n.index-mode" &&
{ git cat-file -e "$sha" 2>/dev/null || sha=$(git hash-object -w --no-filters "$run_dir/$n.index"); } &&
case "$mode" in
    100644|100755)
        rm -f -- "$path" && cp -p -- "$run_dir/$n.index" "$path" &&
        chmod -- "${mode#100}" "$path" ;;
    120000) : ;;
esac &&
git update-index --add --cacheinfo "$mode,$sha,$path"
```

Regular entries (100644/100755) recover worktree bytes and permissions too.
Symlink entries (120000) recover only the index; the worktree stays unchanged.
Do not copy a symlink's target-text blob into the worktree or run git add after
this recipe: that would replace the recovered index type with the worktree type.

Never try bare `git checkout -- <path>` or `git restore` yourself to work around this.

---

## Symptom: a Jira write fell through to the classifier and was DENIED (HIMMEL-205 / 203)

In auto-mode the `auto-approve-safe-bash` hook grants the Jira CLI wholesale —
reads AND writes (`transition`/`comment`/`edit`) — so ticket writes run
unattended (operator-trusted; HIMMEL-205). The catch is command **SHAPE**, not
the write itself: the hook auto-approves only when every segment of a compound
command resolves to a recognised-safe binary.

- `cd … && node …/jira …` **works** (`cd`/`pushd`/`popd` are in the safe-set).
- A command-substitution (`$(…)`) or an unrecognised leading binary makes the
  **whole** command fall through to the auto-mode classifier, which **DENIES**
  external-system writes.

**What to do:** prefer a literal `node …/jira …` (bare or `cd`-prefixed). If a
Jira write still falls through and is denied, that is a **command-shape problem**
— defer to the operator, do **not** reshape to dodge the classifier. See
[`overnight-mode.md`](../handover/overnight-mode.md) § Auto-mode classifier &
attestation. Multi-line bodies: use `--comment-file <path>` / `--desc-file
<path>` so the shell command stays single-line (HIMMEL-209).

---

## Symptom: a pre-push gate failed on a missing attestation trailer

Pre-push gates need attestation trailers (`Platforms tested: <os>` on
shell/script diffs; `Security reviewed: <token>` on non-docs code).

**The rule is to put them in the FIRST commit** after genuinely testing +
reviewing — never a reactive `git commit --amend` after a push fails. In
auto-mode the amend is flagged as gate-circumvention and **HARD-blocked
(uncleable)**.

**What to do if the branch is already pushed without the trailer:** add the
trailer to the **PR body** instead of amending. See
[`overnight-mode.md`](../handover/overnight-mode.md) § Auto-mode classifier &
attestation.

**What to do if the FIRST commit carries a trailer whose token doesn't
conform** — a genuine `Security reviewed:` line whose text doesn't start with
`manual` / `claude-code-security-review` / `pr-review-toolkit` / `ad-hoc`
(`scripts/hooks/check-security-reviewed.sh`'s `TOKEN_RE`, HIMMEL-1681): the
sanctioned recovery is a **follow-up commit** carrying a conforming trailer
line — never `git commit --amend`, never a `git commit-tree` rebuild of the
first commit; both are classifier-vetoed (HIMMEL-2982).

---

## Symptom: a PR merge was blocked (`--admin` / approval gate) (HIMMEL-224)

Overnight Phase 9 used to merge with `gh pr merge --squash --admin`. `--admin`
exists to **bypass branch protection** — but this repo has none (the protection
API returns 403 on a free private repo; PR `reviewDecision` is empty). So
`--admin` bypasses nothing useful, yet the auto-mode classifier reads it as
"bypassing the approval gate = destructive op outside the worktree" and
**HARD-vetoes** it. That stalled the HIMMEL-221 run outright and forced an
explicit in-session authorization on HIMMEL-222.

**What to do:**

1. **Merge plain.** `gh pr merge <N> --squash` (no `--admin`). With no branch
   protection this just works — verified on PR #225. The `scripts/handover/
   pr-merge.sh` helper already does plain-first.
2. **`--admin` is a fallback for REAL branch protection only.** If (and only if)
   the plain merge fails because the repo actually has protection, set
   `GH_ADMIN_MERGE_OK=1` in the **launching** shell (`GH_ADMIN_MERGE_OK=1 claude`
   — a per-call prefix does not reach the hook) and re-run; `pr-merge.sh` then
   retries with `--admin`.
3. **If still blocked, defer to the operator** as a one-action handover ("merge
   PR #N"). Do **NOT** retry the merge via a different command path — the
   classifier flags that as evasion and hardens the block (HIMMEL-195 first
   principle: structural fix over workaround — here the structural fix is
   *not emitting `--admin`*, already shipped in `pr-merge.sh` + overnight-mode
   Phase 9).

The model-based classifier is an Anthropic layer; it cannot be made to read a
repo authorization file. The durable fix is to never emit an unnecessary
`--admin` so the veto never fires.

---

## Symptom: `/worktree` refuses the branch, or a stale worktree lingers

`scripts/clean-garden.sh` (behind `/worktree`, `/clean`, `/clean_garden`) is the
one script behind all three. Two refusals surprise people:

- **"PR already MERGED"** — `/worktree` refuses to re-create a worktree on a
  branch whose PR is merged, because the usual cause is a stale resume that
  would re-open closed work. Deliberate reuse (rare — e.g. a follow-up that must
  keep the branch name) bypasses with the session env var
  `REUSE_MERGED_BRANCH_OK=1`, set in the LAUNCHING shell like every other hook
  bypass. Prefer a fresh `type/slug` branch first; the bypass is the exception.
- **Lingering merged-PR worktrees** — `/himmel-doctor` check **C7** flags them
  read-only and points at `/clean`. There is no `--fix` for C7 by design:
  pruning a worktree can discard uncommitted work, so it stays an explicit
  `/clean` run.

**Superseded commands** (do not use; they still exist in older transcripts and
handovers): `/new-worktree` → `/worktree`, `/clean_gone` → `/clean`. The branch
name must be `type/slug` with type in `feat|fix|chore|docs|refactor|test`.

---

## Symptom: `git commit`/`git push` to main is refused even with `--no-verify` (HIMMEL-2095)

A `reference-transaction` hook (`scripts/hooks/check-main-ref-transaction.sh`,
installed by `scripts/hooks/install-main-ref-transaction.sh`) refuses any
update to `refs/heads/main` whose new commit is not already an ancestor of
`refs/remotes/origin/main`. It exists because `d05ef8ca` (and three earlier
instances) landed directly on private main via `git commit --no-verify` then
`git push --no-verify` — that skips pre-commit, commit-msg AND pre-push
wholesale, so no hook staged in those events could refuse it.
`reference-transaction` is **not** one of the stages `--no-verify` disables,
so `--no-verify` no longer works for this class of bypass. The refusal looks
like:

```text
⛔ check-main-ref-transaction: refusing to update refs/heads/main -- the new
commit is NOT already an ancestor of refs/remotes/origin/main:
  refs/heads/main: <old-oid> -> <new-oid>
...
fatal: in 'prepared' phase, update aborted by the reference-transaction hook
```

**What to do:** make the commit on a `type/slug` branch and open a PR instead:

```bash
/worktree fix/<slug>                # or feat|chore|docs|refactor|test
cd .claude/worktrees/<branch-name>   # commit there
```

Fast-forwards to already-published history (`git pull --ff-only`, `git fetch`
+ `git merge --ff-only`, `git reset --hard origin/main`) are unaffected — only
a genuinely NEW local commit on main is refused.

**Sanctioned one-off escape (leaves a trail):** `MAIN_REF_TRANSACTION_OK=1`,
set as a per-command prefix (this hook is a direct child of `git
commit`/`git push`, so — unlike `EDIT_ON_MAIN_OK` — a per-call prefix DOES
reach it):

```bash
MAIN_REF_TRANSACTION_OK=1 git commit --no-verify -m "..."
```

Using it appends one line to `<git-common-dir>/main-ref-overrides.log`
(shared by every linked worktree) and prints a warning to stderr — use it
deliberately, not to dodge the guard routinely. A repo that commits straight
to main by design (a personal vault, a state repo) opts out permanently the
same way as every other main-branch guard: `touch <repo-root>/.single-writer`.

---

## Symptom: every Write/Edit under `/tmp` is refused with "cannot determine branch for '/tmp'" (HIMMEL-2739)

`block-edit-on-main` walks UP from the edited path looking for a `.git` to
determine the current branch; a stray `.git` anywhere in an **ancestor** of
that path — not the file being edited — makes it treat that ancestor as a
repo root. Incident 2026-09-07: a subagent's fixture work ran `git init`
relative to an inherited (unset/broken) cwd and it landed at `/tmp`, leaving
an EMPTY `/tmp/.git` behind. Every session's scratchpad, commit-message file,
and temp fixture on the station then failed closed with:

```text
cannot determine branch for '/tmp' - refusing to evaluate
```

`himmel-doctor`'s **C36-stray-tmp-git** check (HIMMEL-2739) catches this now
— WARN naming the exact `rmdir` remedy when the stray `.git` is empty, or
naming it and stopping (never deleting content) when it is not.

**What to do:** diagnose by walking up from the target path looking for any
`.git`:

```bash
d=<path-being-edited>; while [ "$d" != / ]; do [ -e "$d/.git" ] && echo "$d/.git"; d=$(dirname "$d"); done
```

If the found `.git` is **empty**, `rmdir` it. If it is **not empty**, stop
and name it — do not delete its contents. Never `git init` relative to an
inherited cwd for a fixture repo; create fixture repos under a `mktemp -d`
you own and `git init` only on that absolute path you just created.

---

## Symptom: an ad-hoc Bash line containing the literal word "enable" is refused in a worktree-pinned session (HIMMEL-2739)

Once a session is pinned to a worktree (`EnterWorktree`), the harness's own
worktree-isolation guard refuses non-trivial Bash commands whose text
contains the literal substring `enable` — confirmed independent of `git`
involvement (a plain `grep -rn "enable" ...` is refused the same way a `git
grep -n "enable" ...` is; a bare `echo enable-test` is not). This is a
harness-level guard, not a `scripts/hooks/*.sh` script — `git grep -n
"enable" scripts/hooks/*.sh` finds no himmel-authored match for it.

**What to do:** this playbook's own first-principle rule applies as-is here —
do NOT reshape the command text to dodge the scan. Rephrase the task to avoid
needing the literal word in a non-trivial command where possible (e.g. a
narrower search that doesn't need to name it), or defer to the operator. Two
refusals of the same literal shape is this playbook's own trigger — don't
keep retrying it verbatim. If this guard is genuinely over-broad (it matches
on innocuous read-only commands with no connection to enabling/disabling a
guardrail), that is a structural bug in the harness worth reporting, not a
standing workaround to normalize.

---

## Symptom: every `git` call is refused — "runs rtk with a git command among its operands" — for the rest of one leg's session (HIMMEL-3283)

A worktree-pinned leg that has been running `git` normally can reach a state
where its `git` Bash calls are refused. Observed 2026-09-20, leg N198
(HIMMEL-3279). The text as recorded — both `...` are elisions in the record (the
full message was not preserved), and the worktree path is the leg's own:

```text
This session is isolated in the worktree .../fix+himmel-3279-durable-launch-context, but this command runs rtk with a git command among its operands: what runs it, and from which directory or root, cannot be read here ... Refusing to run it
```

String-match on `runs rtk with a git command among its operands`. `git grep`
finds no himmel-authored match for this text, so it is not one of
`scripts/hooks/*.sh`; the component that emits it is not identified.
Observed refused: `git diff -U0 <file>`, `git diff -U0 -- <file>` and a bare
`git status --short`. Earlier in the same session `git grep` and `git log` ran
fine — **partial function is not evidence against this symptom**: a leg where
`git log` works while `git status` / `diff` / `commit` are refused has it.

**Why it is possible (not why it fires).** The rtk PreToolUse hook rewrites
`git …` to `rtk git …`, and a classifier cannot establish the executable behind
`rtk git`. `scripts/hooks/rtk-hook-guard.sh` suppresses that rewrite (HIMMEL-2953)
only in the claudex lane, so a native leg gets `rtk git` forwarded. That makes
the refusal possible; it does not say why it fires in one native session and not
another.

**It is session-scoped — established by elimination, not by diagnosis.** Two
controls, the second the strong one:

- N197b ran a bare `git status --short` at rc=0 in a *different* worktree and
  branch, and went on to commit, push and open PR #986. (N197 had committed
  `4b27fcf73fe6f31654f596f8ee70488243f62f28` the same hour, same station,
  same profile.)
- N198b ran bare `git` (`status`, `log`, `merge-base`, `commit`, `push`) at rc=0
  in the **same worktree, on the same branch, with the same uncommitted tree**
  where N198 was refused everything, and shipped that tree to PR #987 without
  touching the implementation.

Holding worktree, branch, tree state, profile, station and launcher constant and
varying only the session rules all of those out and leaves the session. It does
**not** identify what in the session. One candidate — the auto-mode classifier
reads the session narrative, and N198's had dwelt on launch-record directories
and cache roots, the vocabulary the refusal cites ("from which directory or
root") — leads only because the alternatives are gone; it has had no positive
test. Do not act on it as if it were the cause.

**It is rare.** On 2026-09-20 one session was refused against four other native
legs running `git` unrefused (N197, N197b, N198b, N200) — a day's sample, not a
rate. A leg that hits it has hit something uncommon, not a routine gate; the
cause is not identified, so do not spend the session diagnosing your own conduct.

**What to do — the leg:**

- Stop at the **first** refusal carrying this text. Unlike the entries above, do
  not wait for a second: N198 tried three spellings and none cleared it, and
  nothing shows a spelling can.
- This playbook's first-principle rule applies as-is: do NOT reshape the
  command, and do not hunt for a spelling, a wrapper or another tool that slips
  the same operation past the scan. That is not a recovery and must not become a
  standing recipe.
- `BLOCKED` to the console by `SendMessage` (it needs no git). The work is
  safe **only** on disk in the worktree — uncommitted, unpushed, held nowhere
  else — so touch nothing further and do not prune or remove the worktree.
- **Preserve what the diff cannot carry** in that message *before* you wrap:
  the decisions and why, the alternatives you rejected, each suite run with its
  count and any pasted RED, claims you have not verified, the ship steps still
  owed, your worktree path, branch and base sha, and your queue-lock doc and
  release token (in backticks). Your own handover doc is under your lock, so the
  console cannot write there — the message is the channel.

**What to do — the console:**

- **Never run the leg's refused git command on its behalf.** That is permission
  laundering, exactly as for `[Out-of-Place Publication]` above.
- Write the leg's message to a **console-owned** file in the state repo (the
  N198 record, `HIMMEL-3279-N198-BLOCKED-state-2026-09-20.md`, is the shape) so
  the reasoning survives the leg's transcript.
- Recover by **re-dispatching a fresh leg onto the identical worktree**: same
  path, branch and base, the state file in its brief. Release the stale lock
  with the leg's token first, and close the stuck leg's window (it still holds a
  fleet slot). The fresh leg faces the same guards, so this is a re-dispatch,
  not a dodge — a new session is the one thing that varied in the controls. It
  has been exercised end to end: N198 → N198b → PR #987. Have the fresh leg
  re-run the verification it will attest to; the prior leg's greens are a report,
  not evidence in the new session.
- **If a fresh leg on the same worktree is refused with the same text, the
  session-scoped reading is wrong** — that is structural. Stop, note it on
  HIMMEL-3283, and take it to the operator.

**Not settled:** whether the HIMMEL-2953 suppression should extend beyond the
claudex lane (deferred — see the `rtk-hook-guard.sh` header), and whether a
blocked ship tail has a recovery cheaper than a full re-dispatch. Both stay open
on HIMMEL-3283.

---

## Symptom: a late fix after `pre-commit run` gets gated against stale (pre-edit) content

Plain `pre-commit run <hook>` (no `--all-files`, no `--files`) stashes
**every unstaged file in the repo**, not just the ones it is linting, and
lints the **staged index** — full detail:
[`environment-gotchas.md`](environment-gotchas.md#pre-commit-run-stashes-all-unstaged-files-repo-wide-not-just-the-linted-ones).
A fix made after a gate run but before re-staging is invisible to the next
plain `pre-commit run` — it re-tests the stale staged blob and reports
against pre-edit content. `pre-commit run --all-files` does **not** stash —
it reads the working tree directly, so this staleness trap does not apply to
it.

**What to do:** with plain `pre-commit run`, `git add` the fixed path(s)
again before re-running the gate. Run `git status --short` first if fixing
several files, to confirm every edit you expect is actually staged before
the re-run.

---

## Symptom: a new test suite's one-line invocation is refused as a recursive-delete deny (HIMMEL-2898)

A one-line `bash <suite> … | grep … | tail` can get refused even though the
line names no delete flag of its own: many suites' standard cleanup trap
(`rm -rf "$TMPDIR"` or similar) lives in the suite's own source, and something
reads that trap text when the suite is unfamiliar and the invocation is
compound (piped/redirected). Confirmed once (HIMMEL-2898 item 4, N125's
`test-finding-reraise.sh`); the same suite ran clean when invoked through
`quiet-run.sh`. **Since HIMMEL-2834 (#744) this can no longer be
`block-destructive-commands.sh` itself** — that hook anchors its recursive-rm
checks on command position over the actual command string and never reads a
grep pattern or a heredoc BODY, so it cannot see into a suite's own source at
all; this symptom now names the auto-mode classifier (HIMMEL-2798 class), not
this hook. Tell them apart by the deny text: `recursive rm` (or another
short, self-named reason) is this hook, deterministic; text quoting script
content, or the literal `Stage 2 classifier error`, is the classifier.

**What to do:** run every suite — new or old — only through `bash
scripts/quiet-run.sh <name> -- bash <suite>` as **one literal command**, never
a hand-rolled compound. This is already the sanctioned shape in every leg
brief.

---

## Symptom: a message or log bullet quoting a guarded flag is refused by `block-destructive-commands`

`inbox-send.sh <session> '<text>'` and a `printf`-built log bullet are Bash
commands like any other, so `block-destructive-commands` inspects the **whole
command string**, including a quoted TEXT argument — not just the binary
being invoked. Quoting a guarded flag (e.g. naming the force-push flag, or
echoing a suite's `rm -rf` cleanup line) gets refused even though the flag
never runs. Confirmed twice (HIMMEL-2898 item 5): a leg's `inbox-send.sh`
call and a console's `printf` log bullet, both denied for quoting text only.

**What to do:** write the text with the **Write tool** first, then pass it by
path — `inbox-send.sh <session> --file <path>` for a message, `cat >>` from a
Write-tool file for a doc/log bullet — never inline a guarded spelling into a
Bash argv. Treat `--file` as the **default** for any `inbox-send.sh` message
longer than one line or quoting any command, not a fallback for when the bare
form fails.

---

## Symptom: an outward-facing command (`gh pr create` / `gh pr comment` / `git push`) is denied with `Stage 2 classifier error` (HIMMEL-3020)

`Stage 2 classifier error - blocking based on stage 1 assessment (usually
transient — retrying often succeeds)` reads like a plain retry hint, but a
verbatim retry sent back-to-back is itself a signal the classifier weighs — a
denied call reads as the user having declined it, not as noise to resend
unchanged — and an outward-facing publish step sits in the strictest bucket,
so an identical immediate retry can escalate rather than clear (see the
`[Out-of-Place Publication]` row below). This sharpens the two-refusal rule
above for publish steps specifically: the first denial is not free to retry
unconditionally, even once.

This is not the shape-evasion the playbook's opening principle forbids. That
principle is about disguising the SAME content from the classifier by
reshaping the command around it — the content here is unchanged (the PR/
comment/push body is not edited to read differently); only the delay and the
intervening read change, and those exist to remove the one signal this row
documents (an *immediate, back-to-back, identical* resubmission), not to hide
anything from the check. It is also not open-ended: exactly one retry is
permitted, a second denial escalates to the operator rather than trying a
third shape — the escape valve the opening principle itself names as correct
once a denial persists.

**What to do:** do **not** retry the identical command back-to-back. End the
turn, or do one unrelated read, then retry **ONCE**, delayed, with the same
head:
- `gh pr create` / `gh pr comment` — pass the body via `--body-file` instead
  of inline, so the retry is not byte-identical to the denied call. Better
  still, first choice before any retry: publish with
  `bash scripts/lanes/leg-pr-open.sh <title-file> <body-file>` (HIMMEL-3031,
  ruling H2 / HIMMEL-3026) — the body never enters the command at all, so
  there is nothing in the invocation for the classifier to react to.
- `git push` — there is no body flag to vary; the delay and the intervening
  read are themselves what makes the retry non-identical (a different point
  in time, not a reshaped invocation), so retry the exact same `git push`
  command once, not a contrived alternate spelling.

A second denial of **any** wording, on any of these, → stop, `BLOCKED` to the
console with the exact denial text; the console never runs the denied command
itself (permission laundering) — it routes it to the operator's own shell or
the leg's window via `!`.

---

## Symptom: `[Out-of-Place Publication]` denial on a publish step (HIMMEL-3020)

The escalated form of the row above: a harder denial that follows an
identical, immediate retry of a `Stage 2 classifier error` denial on an
outward-facing command. The PR/comment/push body itself may be entirely clean
(no private paths, tokens, or session ids) — the trigger is the **retry
pattern**, not the content.

**What to do:** unlike the row above, this string earns **no retry at all** —
whether you are seeing it after your own delayed retry (the usual path) or as
the very first denial on this attempt. Stop immediately: `BLOCKED` to the
console with the exact denial text; the console never runs the denied command
itself (permission laundering) — it routes it to the operator's own shell or
the leg's window via `!`.

---

## Symptom: a leg's `queue-lock.sh release` is denied `[Merge Without Review]` right after its merge (HIMMEL-3131)

`HANDOVER_DIR=<root> bash scripts/handover/queue-lock.sh release <doc> <token>`
acquired the lock at session start, but the same shape is denied after the
leg's GO'd merge landed. The command is not a merge — it writes one lock dir
under the handover root and touches no git ref — but the auto-mode classifier
reads the session narrative (a merge just happened), not only the payload.

**What to do:**
- `auto-approve-safe-bash` now approves exactly this shape (any of
  acquire / release / heartbeat / status, absolute doc under `HANDOVER_DIR`,
  literal args) **when it is the whole command**. A denial therefore means the
  spelling drifted: a compound (`&&` / `;` / a pipe in or out), an env prefix
  other than `HANDOVER_DIR=`, a `$VAR` in an argument, or a relative doc path —
  or, for the relative `scripts/handover/queue-lock.sh` form, a session cwd that
  is not the root of a real checkout (a sub-directory or a lookalike dir: run it
  from the worktree root). Re-issue the one bare literal — do not add a second spelling.
- Still denied (or a permission prompt) → **stop and escalate**: `BLOCKED` to the
  console with the doc path and your release token. The console releases with
  your token as ordinary lock administration. **Never** reshape the command,
  touch the lock file directly, or force-release yourself.
- **Verify with `status`, not the return code:** `release` succeeds silently
  (no output, rc 0). `bash scripts/handover/queue-lock.sh status <doc>` must
  report the lock free.

---

## Why this is a playbook, not a `CLAUDE.md` rule

Root `CLAUDE.md` is **state, not a prompt** — frame-shaping invariants only, paid
for on every session. Operational/troubleshooting rules (the above) are
prunable, per-user, and only relevant at the moment of the symptom, so they live
load-on-trigger here instead (decision locked: memory
`feedback_no_operational_rules_in_claudemd`; layer-selection HIMMEL-177;
structural>instructional HIMMEL-195). The 9-author convergence behind "short
CLAUDE.md beats long" is synthesized in the luna vault at
`Clippings/synthesis/2026-05-26-concept-claude-md-patterns.md`.
