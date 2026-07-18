#!/usr/bin/env bash
# WS5 Task 5 invariants test (HIMMEL-654). Assertion-only: greps the
# integrated WS5 branch diff (git diff <base>...HEAD) for the four locks that
# make lane parity durable without growing always-on surface or root-doctrine
# bloat.
#
#   T12 no-bloat     -- root CLAUDE.md gains no rule block (<=1 line each way).
#   T13 no-always-on -- no new SessionStart/PreToolUse hook registration in
#                       .claude/settings.json or any */hooks.json, and no
#                       unbounded-loop / background-service / JS-timer marker
#                       in the SHIPPED source the diff adds (test fixtures are
#                       excluded: a harness loop is not runtime surface).
#   T14 locks        -- no per-token-lane wiring in shipped source; the
#                       gemini/copilot/cursor index rows stay deferred.
#                       (The former T14(a) claude-codex-launcher prohibition
#                       was retired 2026-07-13, HIMMEL-979.)
#   T15 x-platform   -- every NEW scripts/**/*.sh ships a .ps1 twin OR carries
#                       a documented platform-guard marker in its header.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + grep over the branch diff; NOT ported to native PowerShell. A
# test harness needs no .ps1 twin (project convention: a documented platform
# guard suffices for a test fixture).
#
# Usage:
#   bash scripts/parity/test-ws5-invariants.sh [--base <ref>]
#     --base <ref>   diff base (defaults to origin/main); HEAD is the tip.
#
# Exit codes: 0 = PASS, 1 = FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE="origin/main"

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            if [ $# -lt 2 ]; then
                echo "FAIL: --base requires a ref argument" >&2
                exit 1
            fi
            BASE="$2"
            shift 2
            ;;
        *)
            echo "FAIL: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

cd "$REPO" || { echo "FAIL: cannot cd to repo root $REPO" >&2; exit 1; }

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    # CI checkouts (shallow / single-ref) may lack origin/main -- fall back to
    # a local main; with NO resolvable base there is no diff to scope the
    # invariants over, so SKIP (exit 0), matching the harness skip convention.
    # An EXPLICIT --base that does not resolve still FAILS (caller error).
    if [ "$BASE" = "origin/main" ] && git rev-parse --verify --quiet main >/dev/null; then
        echo "note: origin/main does not resolve; falling back to local main"
        BASE=main
    elif [ "$BASE" = "origin/main" ]; then
        echo "SKIP: no resolvable diff base (origin/main and main both absent -- shallow CI checkout?); nothing to scope"
        exit 0
    else
        echo "FAIL: diff base ref does not resolve: $BASE" >&2
        exit 1
    fi
fi

FAIL=0
SHIPPED="$(mktemp)"
trap 'rm -f "$SHIPPED"' EXIT

# Corpus of ADDED lines from SHIPPED source (every changed file whose basename
# does NOT start with "test-"). Test fixtures are excluded because they
# legitimately describe the very concepts they assert; the always-on and
# per-token-lane invariants are about production runtime + docs, not harness
# comments. (This also keeps the test from flagging its own assertion text.)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    case "$base" in test-*) continue ;; esac
    git diff "$BASE...HEAD" -- "$f" | grep '^+' | grep -v '^+++'
done < <(git diff "$BASE...HEAD" --name-only) > "$SHIPPED"

# ----------------------------------------------------------------------------
# T12 -- no-bloat (AC6): root CLAUDE.md gains no rule block (<=1 line / way).
# ----------------------------------------------------------------------------
claude_ns="$(git diff "$BASE...HEAD" --numstat -- CLAUDE.md | head -n 1)"
claude_add=0
claude_del=0
if [ -n "$claude_ns" ]; then
    claude_add="$(printf '%s' "$claude_ns" | awk '{print $1}')"
    claude_del="$(printf '%s' "$claude_ns" | awk '{print $2}')"
    case "$claude_add" in '' | *[!0-9]*) claude_add=0 ;; esac
    case "$claude_del" in '' | *[!0-9]*) claude_del=0 ;; esac
fi
if [ "$claude_add" -le 1 ] && [ "$claude_del" -le 1 ]; then
    echo "PASS T12 no-bloat: root CLAUDE.md add=${claude_add} del=${claude_del} (<=1 each)."
else
    echo "FAIL T12 no-bloat: root CLAUDE.md add=${claude_add} del=${claude_del} -- a rule block was added." >&2
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------------
# T13 -- no new always-on surface (AC7).
# (a) no new SessionStart/PreToolUse registration in the hook-reg files;
# (b) no unbounded-loop / background-service / JS-timer marker in shipped src.
# ----------------------------------------------------------------------------
# (a) hook-registration files only: .claude/settings.json + any */hooks.json.
t13a_hit=0
while IFS= read -r hf; do
    [ -n "$hf" ] || continue
    if git diff "$BASE...HEAD" -- "$hf" | grep '^+' | grep -v '^+++' \
        | grep -E '(SessionStart|PreToolUse)' >/dev/null; then
        t13a_hit=1
        echo "FAIL T13(a): new SessionStart/PreToolUse registration in $hf" >&2
    fi
done < <(git diff "$BASE...HEAD" --name-only \
    | grep -E '(^|/)hooks\.json$|^\.claude/settings\.json$' || true)

# (b) shipped-source loop / service / timer markers.
t13b_hit=0
if grep -Ei 'while[[:space:]]+true|setInterval|daemon' "$SHIPPED" >/dev/null; then
    t13b_hit=1
    echo "FAIL T13(b): unbounded-loop / background-service / JS-timer marker in shipped source." >&2
fi

if [ "$t13a_hit" -eq 0 ] && [ "$t13b_hit" -eq 0 ]; then
    echo "PASS T13 no-always-on: no new hook registration; no loop/service/timer in shipped source."
else
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------------
# T14 -- locks (AC8).
# (a) RETIRED 2026-07-13 (operator decision, HIMMEL-979): the D9 no-claude-codex
#     lock was superseded -- the claude-codex lane (scripts/claude-codex{,.ps1})
#     ships with native guard posture (Claude Code IS the harness, same column
#     as claude-glm). See docs/internals/lane-parity.md "claude-codex lock".
# (b) no per-token-lane wiring in shipped source;
# (c) gemini/copilot/cursor index rows stay deferred.
# ----------------------------------------------------------------------------
t14b_hit=0
if grep -Ei 'token-lane' "$SHIPPED" >/dev/null; then
    t14b_hit=1
    echo "FAIL T14(b): per-token-lane wiring in shipped source." >&2
fi

t14c_hit=0
PARITY_DOC="docs/internals/lane-parity.md"
if [ ! -f "$PARITY_DOC" ]; then
    t14c_hit=1
    echo "FAIL T14(c): lane-parity index doc missing ($PARITY_DOC)." >&2
else
    # Every gemini/copilot/cursor TABLE row must carry the 'deferred' token.
    bad_rows="$(grep -Ei '^\|.*gemini|^\|.*copilot|^\|.*cursor' "$PARITY_DOC" \
        | grep -Eiv 'deferred' || true)"
    if [ -n "$bad_rows" ]; then
        t14c_hit=1
        echo "FAIL T14(c): gemini/copilot/cursor row(s) not deferred:" >&2
        printf '%s\n' "$bad_rows" >&2
    fi
    if ! grep -Eiq '^\|.*(gemini|copilot|cursor).*deferred' "$PARITY_DOC"; then
        t14c_hit=1
        echo "FAIL T14(c): no deferred gemini/copilot/cursor row in $PARITY_DOC." >&2
    fi
fi

if [ "$t14b_hit" -eq 0 ] && [ "$t14c_hit" -eq 0 ]; then
    echo "PASS T14 locks: no per-token-lane wiring; gemini/copilot/cursor deferred. (T14(a) claude-codex lock retired, HIMMEL-979.)"
else
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------------
# T15 -- cross-platform (AC9): every NEW scripts/**/*.sh ships a .ps1 twin OR
# a documented platform-guard marker in its header.
# ----------------------------------------------------------------------------
t15_fail=0
t15_n=0
while IFS= read -r sh_path; do
    [ -n "$sh_path" ] || continue
    t15_n=$((t15_n + 1))
    twin="${sh_path%.sh}.ps1"
    if [ -f "$twin" ]; then
        echo "ok T15: $sh_path -> .ps1 twin present ($twin)."
        continue
    fi
    if head -n 60 "$sh_path" | grep -Ei 'platform guard|gitbash|git bash' >/dev/null; then
        echo "ok T15: $sh_path -> documented platform-guard marker."
        continue
    fi
    echo "FAIL T15: $sh_path has neither a .ps1 twin nor a platform-guard marker." >&2
    t15_fail=1
done < <(git diff "$BASE...HEAD" --diff-filter=A --name-only -- 'scripts/' \
    | grep -E '\.sh$' || true)

if [ "$t15_n" -eq 0 ]; then
    echo "PASS T15 x-platform: no new scripts/**/*.sh in the diff (vacuous)."
elif [ "$t15_fail" -eq 0 ]; then
    echo "PASS T15 x-platform: all ${t15_n} new scripts/**/*.sh have a twin or guard."
else
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------------
# Verdict
# ----------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: WS5 invariants test failed ($FAIL section(s))." >&2
    exit 1
fi
echo "PASS: WS5 invariants test (T12 no-bloat, T13 no-always-on, T14 locks, T15 x-platform)."
exit 0
