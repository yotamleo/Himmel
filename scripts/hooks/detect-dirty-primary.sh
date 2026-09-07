#!/usr/bin/env bash
# PostToolUse (Bash matcher) hook (HIMMEL-2526). Companion to
# record-primary-baseline.sh: reports, promptly, when the PRIMARY checkout's
# tracked working tree goes dirty in a way block-edit-on-main.sh never sees —
# a Bash-mediated write (`cat >`, `sed -i`, a python heredoc) bypasses the
# Edit/Write/MultiEdit/NotebookEdit matcher that hook is wired on. The
# motivating incident: a dispatched subagent wrote four files into the
# primary checkout via Bash while it was on main, and nothing noticed for 18
# minutes. This hook is the DETECTION half; a sibling script,
# block-write-into-main-checkout.sh, is the PREVENTION half (a destination-
# write fence).
#
# Platform guard: POSIX bash 3.2+, incl. Git Bash on Windows. No .ps1 twin —
# same project convention as record-primary-baseline.sh (see
# scripts/parity/test-ws5-invariants.sh T15): nothing here touches a
# Windows-only API.
#
# DELIBERATELY UNGATED by any worker marker. An earlier draft gated this on
# HIMMEL_WORKER=1; that was withdrawn. HIMMEL_WORKER is exported only by the
# telegram lanes (scripts/telegram/glm-env.ts, scripts/telegram/
# spawn-claudex.ts); scripts/lib/claude-headless.sh never sets it, and an
# Agent-tool subagent inherits the parent's environment. The incident worker
# carried NO marker, so a marker-gated detector would never have fired on the
# very shape it exists to catch.
#
# Cost: `git --no-optional-locks -C <primary> status --porcelain -uno`
# measures single-digit milliseconds on a normal checkout — affordable on
# every Bash PostToolUse. Note the spelling: --no-optional-locks is a GLOBAL
# git option and goes BEFORE the subcommand.
#
# A failed status invocation is never interpreted: no output is not "clean".
# On failure this hook produces no verdict, logs the failure ONCE per session
# (a marker file beside the baseline — never on every call), and exits 0.
#
# Baseline-aware: a file already dirty when the session started is never
# reported. Only lines PRESENT in the current porcelain output and ABSENT
# from the recorded baseline are reported, so a status-code change on an
# already-dirty file (" M" -> "MM") still counts as new — it is a different
# line. On a report, the baseline is rewritten to the CURRENT output, so the
# same new path is reported once, not on every subsequent Bash call for the
# rest of the session; a later, different change is still new relative to
# the rewritten baseline and is still caught.
#
# Exit: 0 nothing to report (including every fail-open path); 2 something
# new is dirty in the primary — message on stderr. This is the PostToolUse
# advisory convention in this repo: the tool already ran, so exit 2 informs
# the model rather than blocking anything — see
# scripts/hooks/check-hook-file-parse.sh.
set -uo pipefail

CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$CLAUDE_PROJECT_DIR" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"
case "$tool" in
    Bash) ;;
    *) exit 0 ;;
esac

session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || exit 0
# Same session_id shape guard as record-primary-baseline.sh, applied BEFORE
# it ever reaches a filesystem path.
case "$session_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

out_dir="${HIMMEL_PRIMARY_BASELINE_DIR:-$HOME/.claude/himmel/primary-baseline}"
baseline_file="$out_dir/$session_id.primary-baseline"
# No baseline file for this session -> exit 0 silently. The recorder is
# advisory and may legitimately have written nothing (missing jq/git, no
# CLAUDE_PROJECT_DIR, a non-git project dir, a malformed session_id, a failed
# git status at session start).
[ -f "$baseline_file" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null || exit 0

primary="$(primary_checkout_root "$CLAUDE_PROJECT_DIR" 2>/dev/null)" || exit 0
[ -n "$primary" ] || exit 0

current_out="$(git --no-optional-locks -C "$primary" status --porcelain -uno 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then
    # Log once per session, not once per call: a marker file beside the
    # baseline. Best-effort — a failed mkdir/touch here still exits 0, since
    # this is the "cannot verify" path, never a verdict.
    mkdir -p "$out_dir" 2>/dev/null || true
    fail_marker="$out_dir/$session_id.status-failed"
    if [ ! -f "$fail_marker" ]; then
        : > "$fail_marker" 2>/dev/null || true
    fi
    exit 0
fi

baseline_out="$(cat "$baseline_file" 2>/dev/null)"

# Lines present in current but absent from baseline, sorted C-locale so a
# status-code-only change on the same path (" M" -> "MM") is a different
# line and is caught (baseline-aware, per the header comment above).
#
# codex-8 (HIMMEL-2526): `comm` itself must run under LC_ALL=C too — both
# inputs are pre-sorted with LC_ALL=C, but `comm` inherits the SESSION
# locale by default and can disagree with that collation order (e.g. a
# case-mixed filename sorts differently under en_US.utf8 than under C),
# emitting a WRONG diff. The `2>/dev/null` below swallows comm's own "not in
# sorted order" diagnostic in that case, so this used to fail silently.
new_lines="$(LC_ALL=C comm -13 \
    <(printf '%s\n' "$baseline_out" | LC_ALL=C sort) \
    <(printf '%s\n' "$current_out" | LC_ALL=C sort) \
    2>/dev/null | sed '/^$/d')"

[ -n "$new_lines" ] || exit 0

# Rewrite the baseline to the CURRENT output BEFORE reporting, so the same
# new path is reported once. Temp file + mv so a concurrent reader never
# sees a partial file.
#
# codex-6 (HIMMEL-2526 CR round 3): the temp file must be created INSIDE
# out_dir, not ${TMPDIR:-/tmp} — identical to the codex-9 fix in this file's
# sibling record-primary-baseline.sh. `mv` is only atomic WITHIN one
# filesystem, and ${TMPDIR:-/tmp} vs $out_dir (under $HOME by default) can be,
# and often are, different filesystems (tmpfs vs btrfs on this station), in
# which case `mv` silently falls back to copy+unlink and a concurrent reader
# could see a partial file — exactly the guarantee the comment above claims.
tmp="$(mktemp "$out_dir/.primary-baseline.XXXXXX" 2>/dev/null)"
if [ -n "$tmp" ]; then
    trap 'rm -f "$tmp"' EXIT
    if printf '%s' "$current_out" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$baseline_file" 2>/dev/null || true
    fi
fi

{
    printf 'detect-dirty-primary: the PRIMARY checkout at %s went dirty during\n' "$primary"
    printf 'this session in a way block-edit-on-main.sh never saw — a Bash-mediated\n'
    printf 'write (cat >, sed -i, a python heredoc) bypasses the Edit/Write/MultiEdit/\n'
    printf 'NotebookEdit matcher that hook is wired on.\n\n'
    printf 'New dirty path(s) since the session baseline:\n'
    printf '%s\n' "$new_lines" | while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '  %s\n' "$line"
    done
    printf '\nThe write belonged in a worktree, not the primary checkout. Check whether\n'
    printf 'a dispatched worker/subagent was handed an absolute PRIMARY-checkout path\n'
    printf 'instead of its own worktree path. HIMMEL-2526.\n'
} >&2
exit 2
