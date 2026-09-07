#!/usr/bin/env bash
# reference-transaction hook logic: refuse a NEW local commit landing on
# refs/heads/main whenever origin/main does not already contain it
# (HIMMEL-2095).
#
# WHY: d05ef8ca (and 913073df, 378c21f9, 310646da before it) landed directly
# on private main via `git commit --no-verify` followed by `git push
# --no-verify`. That skips pre-commit, commit-msg AND pre-push wholesale, so
# no hook staged in any of those events can refuse it -- check-worktree-
# isolation.sh, check-graph-artifact-branch.sh, check-commit-msg.sh and
# check-push-target.sh all fire correctly and were verified working, but
# never RUN. Server-side branch protection is unavailable on this repo (a
# private repo on a GitHub Free plan refuses both the branch-protection and
# ruleset APIs with "Upgrade to GitHub Pro").
#
# A `reference-transaction` hook is the one lever git itself does not let
# --no-verify skip: it fires on every ref update, in the "prepared" phase
# BEFORE the transaction actually lands, and a nonzero exit there aborts the
# whole transaction with the ref left unmoved.
#
# THE RULE: refuse an update to refs/heads/main whose NEW oid is not already
# an ancestor of refs/remotes/origin/main. That forbids CREATING local
# commits on main (an ordinary commit, a merge, a rebase, a `reset --hard` to
# unpublished history) while still allowing fast-forwards to already-
# published history (`git pull --ff-only`, `git fetch` + `merge --ff-only`,
# `git reset --hard origin/main`). Only refs/heads/main is in scope --
# refs/remotes/*, refs/stash, and every other local branch are ignored
# entirely; this is not a general commit gate.
#
# Invocation: `check-main-ref-transaction.sh <phase>`, with the transaction's
# ref lines on STDIN as `<old-oid> <new-oid> <refname>` (one per line --
# git's reference-transaction contract can carry several refs in one
# transaction, and git supplies this same per-ref line stream for the
# "committed"/"aborted" notification phases too, not just "prepared"). This
# script acts ONLY on phase "prepared" -- there is nothing left to prevent
# once "committed"/"aborted" fires -- but it must still DRAIN every line git
# writes for those phases before returning (panel round 8, codex-1: the
# install-main-ref-transaction.sh shim's own fail-open branch was fixed for
# exactly this in round 5 and this script's early exit was the other half
# of the same contract, left un-fixed). Exiting without draining leaves git
# writing into a pipe nobody is reading; once the kernel buffer fills, git
# sees a broken pipe -- possible AFTER refs have already moved for a
# "committed" notification, which is a worse failure than a slow hook.
# During "prepared", read EVERY line before deciding -- never return
# out of the loop early, or git can see EPIPE on the write side.
#
# Fail-open vs fail-closed (deliberate -- read before "fixing"): if
# refs/remotes/origin/main does not resolve AT ALL (a fresh clone mid-setup,
# a repo using a differently-named remote), `--is-ancestor` fails for every
# oid, and a naive implementation would then refuse EVERY update to main,
# bricking the repo. That is NOT this bug's class -- there is no published
# main for a `--no-verify` commit to bypass -- so this hook ALLOWS with a
# warning to stderr instead. If refs/remotes/origin/main DOES resolve and the
# new oid is not its ancestor, that IS this bug's class: refuse.
#
# PLATFORM GUARD (no .ps1 twin -- this note is that decision, not a
# placeholder for one): this script is plain POSIX shell with no
# Linux/macOS-only constructs, so it runs correctly under Git Bash on
# Windows the same as anywhere else -- there is nothing here a PowerShell
# rewrite would do differently, which is why no `.ps1` twin exists. What is
# NOT yet true on Windows: (1) install-main-ref-transaction.sh (this
# script's own installer) is never called from `setup-hooks.ps1`, so a
# Windows station currently ships this file with no guard actually wired up
# to run it at all -- tracked as HIMMEL-2638, a real, open gap, not a
# hypothetical one; (2) the git behaviour this script depends on -- that
# `reference-transaction` delivers its full ref-line stream on stdin the
# same way across platforms, including through Git Bash's own process
# model -- is UNVERIFIED on Windows, tracked as HIMMEL-2643. If a `.ps1`
# twin is ever written, it needs to independently confirm both of those
# before this note can shrink to "resolved".
#
# .single-writer opt-out: honoured exactly like block-edit-on-main.sh /
# main_checkout_verdict (scripts/guardrails/lib.sh) -- a repo-root
# `.single-writer` file (local, gitignored, never committed) marks a repo
# that commits straight to main by design (personal vaults, state repos);
# such a repo is allowed unconditionally, before any origin/main or
# ancestor check even runs. The repo root/common-dir here are resolved via
# AMBIENT `git rev-parse` (no `-C`, no deriving a path from this script's own
# location) -- empirically, git invokes a reference-transaction hook with cwd
# already set to the toplevel of the repo/worktree whose transaction is
# firing (confirmed for both a primary checkout and a linked worktree,
# HIMMEL-2095 investigation), and `--git-common-dir` correctly resolves to
# the SHARED primary .git even when cwd is a linked worktree. Anchoring to
# this script's own installed path would instead resolve whatever repo the
# TRACKED COPY happens to live in (wrong whenever the hook is exercised
# against a different repo than the one the script ships in, e.g. this
# suite's throwaway sandboxes) -- ambient resolution is correct in both
# production and test.
#
# Escape hatch (HIMMEL-2095 retask): removing the operator's `--no-verify`
# door without leaving a sanctioned one just pushes them to a worse one (a
# raw `core.hooksPath` override, or editing this file). MAIN_REF_TRANSACTION_OK=1
# is that sanctioned door. Named after THIS hook (not reused from
# EDIT_ON_MAIN_OK, which gates a different thing -- editing files on main,
# a Claude-side PreToolUse hook whose bypass MUST be a launching-shell env
# var because a per-call prefix never reaches that hook process). This hook
# runs as a direct child of `git commit`/`git push` itself, so a plain
# per-command prefix (`MAIN_REF_TRANSACTION_OK=1 git commit --no-verify ...`)
# already reaches it via ordinary environment inheritance -- no launching-
# shell requirement here. Using the escape appends one line to
# `<git-common-dir>/main-ref-overrides.log` (shared by every linked
# worktree) and prints a loud warning to stderr. The log append itself must
# NEVER abort the transaction: if it cannot be written (e.g. permissions),
# warn on stderr and still allow -- the escape hatch must not become a new
# way to brick the repo.
#
# NOT skippable with --no-verify: reference-transaction is not one of the
# hook types git's --no-verify flag disables (only pre-commit, commit-msg,
# and, for a push, pre-push are). That is the entire point of using it here.
#
# Exit codes: 0 = allow every ref in the transaction, 1 = refuse (at least
# one ref in the transaction failed the check and was not overridden).
set -u

phase="${1:-}"
# Drain stdin before returning for the non-"prepared" phases (see the
# header note above) -- mirrors the shim's own fail-open drain in
# install-main-ref-transaction.sh.
[ "$phase" = "prepared" ] || { cat >/dev/null; exit 0; }

# is_zero_oid OID -- true when OID is made up entirely of '0' characters
# (git's null-oid marker for a ref create/delete endpoint). Length-agnostic
# so this works for both sha1 (40 hex) and sha256 (64 hex) repos.
is_zero_oid() {
    case "$1" in
        *[!0]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Ambient repo root -- see the header note above for why this is NOT derived
# from this script's own path. Fails closed (repo_root empty) if the cwd
# somehow is not inside a work tree at all; that only matters for the
# .single-writer / log-path lookups below -- the ancestor check itself uses
# bare `git` commands and needs no path.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""

single_writer=0
[ -n "$repo_root" ] && [ -f "$repo_root/.single-writer" ] && single_writer=1

origin_main_resolved=1
git rev-parse --verify -q refs/remotes/origin/main >/dev/null 2>&1 || origin_main_resolved=0

# git-common-dir for the override log -- shared by every linked worktree.
# Same relative/absolute normalisation as install-cr-pre-push-legacy.sh.
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || common_dir=""
case "$common_dir" in
    /*|[A-Za-z]:[/\\]*) ;;
    "") ;;
    *) common_dir="${repo_root:-.}/$common_dir" ;;
esac
override_log="${common_dir:+$common_dir/main-ref-overrides.log}"

log_override() {
    # log_override OLD NEW REFNAME -- append one override line; never fatal.
    [ -n "$override_log" ] || {
        echo "check-main-ref-transaction: cannot resolve git-common-dir -- override NOT logged" >&2
        return 0
    }
    local old="$1" new="$2" refname="$3" subject ts
    subject=$(git log -1 --format=%s "$new" 2>/dev/null) || subject=""
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts="unknown-time"
    if ! printf 'ts=%s ref=%s old=%s new=%s subject=%q user=%s var=MAIN_REF_TRANSACTION_OK=%s\n' \
        "$ts" "$refname" "$old" "$new" "$subject" "${USER:-unknown}" "${MAIN_REF_TRANSACTION_OK:-}" \
        >> "$override_log" 2>/dev/null
    then
        echo "check-main-ref-transaction: could not write $override_log -- override NOT logged (allowing anyway)" >&2
    fi
}

refuse=0
messages=""

while IFS=' ' read -r old new refname || [ -n "${old-}${new-}${refname-}" ]; do
    old="${old%$'\r'}"; new="${new%$'\r'}"; refname="${refname%$'\r'}"
    [ -n "${refname:-}" ] || continue
    [ "$refname" = "refs/heads/main" ] || continue
    [ -n "${new:-}" ] || continue
    is_zero_oid "$new" && continue          # deletion -- a different class of gate owns this

    if [ "$single_writer" -eq 1 ]; then
        continue                            # opt-in single-writer repo: allow unconditionally
    fi

    if [ "$origin_main_resolved" -eq 0 ]; then
        echo "check-main-ref-transaction: refs/remotes/origin/main not found -- allowing update to $refname ($old -> $new) unconditionally (no published main exists yet for a local commit to have bypassed, so there is nothing for this guard to catch)" >&2
        continue
    fi

    if git merge-base --is-ancestor "$new" refs/remotes/origin/main 2>/dev/null; then
        continue                            # fast-forward to already-published history: OK
    fi

    if [ "${MAIN_REF_TRANSACTION_OK:-0}" = "1" ]; then
        echo "check-main-ref-transaction: MAIN_REF_TRANSACTION_OK=1 -- ALLOWING an otherwise-refused update to $refname ($old -> $new). Logged to ${override_log:-<unresolved>}." >&2
        log_override "$old" "$new" "$refname"
        continue
    fi

    refuse=1
    messages="${messages}  $refname: $old -> $new"$'\n'
done

[ "$refuse" -eq 1 ] || exit 0

cat >&2 <<EOF
⛔ check-main-ref-transaction: refusing to update refs/heads/main -- the new
commit is NOT already an ancestor of refs/remotes/origin/main:
$messages
This guard enforces: main may only move to a commit that is ALREADY
published in refs/remotes/origin/main (a squash-merged PR pulled/fetched
in, or an older commit main is being rewound to -- both are ancestors of
origin/main, so both are allowed). Creating a NEW local commit directly on
main -- by \`git commit\`, \`git merge\`, \`git rebase\`, or \`git reset
--hard\` to an unpublished oid -- is refused, even with --no-verify
(reference-transaction is not one of the hook stages --no-verify skips).

To proceed:
    /worktree fix/<slug>                # or feat|chore|docs|refactor|test
    cd .claude/worktrees/<branch-name>   # make the commit there, open a PR

One-off escape (writes a trail to <git-common-dir>/main-ref-overrides.log):
    MAIN_REF_TRANSACTION_OK=1 git commit ...   # or: ... git push ...

Single-writer repos (vaults/state repos that commit straight to main by
design) can opt out permanently:
    touch "${repo_root:-<repo-root>}/.single-writer"
EOF
exit 1
