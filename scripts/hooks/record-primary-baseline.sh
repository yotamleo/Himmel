#!/usr/bin/env bash
# SessionStart hook (HIMMEL-2526). Records the PRIMARY checkout's tracked
# `git status --porcelain` output at session start, keyed by this session's
# session_id, so detect-dirty-primary.sh (its PostToolUse companion) can
# later notice a write that landed there through a route
# block-edit-on-main.sh never sees — a Bash-mediated write (`cat >`, `sed -i`,
# a python heredoc) rather than an Edit/Write/MultiEdit/NotebookEdit tool
# call. The motivating incident: a dispatched subagent wrote four files into
# the primary checkout via Bash while it was on main, and nothing noticed
# for 18 minutes.
#
# Platform guard: POSIX bash 3.2+, incl. Git Bash on Windows. No .ps1 twin —
# same project convention as record-hook-integrity.sh, this hook's sibling
# (see scripts/parity/test-ws5-invariants.sh T15): nothing here touches a
# Windows-only API.
#
# Modelled closely on record-hook-integrity.sh (HIMMEL-1666) — same
# conventions: `set -uo pipefail`, best-effort/advisory (every early exit is
# `exit 0` writing nothing), `CLAUDE_PROJECT_DIR` required, `jq`/`git`
# capability checks, `payload="$(cat)"`, session_id pulled from `.session_id`
# with the same shape guard BEFORE it ever reaches a filesystem path.
#
# DIFFERENCE FROM record-hook-integrity.sh's pin file: this baseline is
# rewritten DURING the session by detect-dirty-primary.sh every time it
# reports a new dirty path (so the same path is reported once, not on every
# subsequent Bash call) — it is intentionally NOT chmod 0400. The integrity
# pin is a write-once-per-session record; this baseline is a live cursor. The
# two files also live in SEPARATE directories on purpose
# (HIMMEL_PRIMARY_BASELINE_DIR vs HIMMEL_HOOK_INTEGRITY_DIR) — this hook must
# never write into the integrity pin directory, which a separate ticket
# (HIMMEL-2528) owns exclusively.
set -uo pipefail

CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
[ -n "$CLAUDE_PROJECT_DIR" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || exit 0
# session_id is used below to build a filesystem path
# ($out_dir/$session_id.primary-baseline) and comes straight off stdin JSON
# with no shape guarantee from this hook's own contract. Restrict it to the
# token shape a real session id actually is (alnum/hyphen/underscore) before
# it ever reaches a path — same guard as record-hook-integrity.sh, same
# reasoning.
case "$session_id" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null || exit 0

primary="$(primary_checkout_root "$CLAUDE_PROJECT_DIR" 2>/dev/null)" || exit 0
[ -n "$primary" ] || exit 0

# A failed status invocation is never interpreted — no output is not "clean".
# If the call fails, write nothing and exit 0; this hook has no once-per-
# session failure log of its own (the detector owns that half — it is the
# one whose silence would otherwise hide a real dirty write).
status_out="$(git --no-optional-locks -C "$primary" status --porcelain -uno 2>/dev/null)"
rc=$?
[ "$rc" -eq 0 ] || exit 0

out_dir="${HIMMEL_PRIMARY_BASELINE_DIR:-$HOME/.claude/himmel/primary-baseline}"
mkdir -p "$out_dir" 2>/dev/null || exit 0

# codex-9 (HIMMEL-2526): the temp file must be created INSIDE out_dir (not
# ${TMPDIR:-/tmp}) — `mv` is only atomic WITHIN one filesystem, and
# ${TMPDIR:-/tmp} vs $out_dir (under $HOME by default) can be, and often are,
# different filesystems, in which case `mv` silently falls back to
# copy+unlink and a concurrent reader could see a partial file — exactly the
# guarantee this comment claims.
tmp="$(mktemp "$out_dir/.primary-baseline.XXXXXX" 2>/dev/null)" || exit 0
trap 'rm -f "$tmp"' EXIT
printf '%s' "$status_out" > "$tmp" 2>/dev/null || exit 0

# Write via temp file + mv so a reader (detect-dirty-primary.sh, possibly
# running concurrently in another PostToolUse invocation) never sees a
# partial file.
dest="$out_dir/$session_id.primary-baseline"
mv -f "$tmp" "$dest" 2>/dev/null || exit 0
exit 0
