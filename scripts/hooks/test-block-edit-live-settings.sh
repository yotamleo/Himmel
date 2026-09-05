#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-edit-live-settings.sh (HIMMEL-2360).
#
# Usage: bash scripts/hooks/test-block-edit-live-settings.sh
#
# Builds real throwaway git fixtures under a sandbox (a primary checkout with
# a linked worktree) rather than asserting against the live himmel checkout,
# so the test is hermetic and does not depend on this machine's layout.
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-edit-live-settings.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/block-edit-live-settings.XXXXXX") || {
    echo "FATAL: mktemp -d failed" >&2
    exit 1
}
# Windows/Git-Bash: mktemp's /tmp/... is a compound MSYS mount (aliases into
# AppData\Local\Temp), a different representation than the C:/... drive form
# a real Windows-native caller (Claude Code's JSON) would send. The hook
# normalises the simple single-letter-mount case ($HOME's /c/... form) but
# not this compound one — so pin the sandbox to its drive-letter form up
# front (cygpath understands the actual mount table) to keep every fixture
# path built from $SANDBOX below in ONE consistent representation, matching
# what the hook will see in production. No-op (and harmless) off Windows.
if command -v cygpath >/dev/null 2>&1; then
    SANDBOX=$(cygpath -m "$SANDBOX")
fi

# rc_of FILE TOOL_NAME FIELD [EXTRA_ENV...] — build {tool_name, tool_input:
# {FIELD: FILE}} on stdin, run the hook, echo its exit code. Extra `KEY=VAL`
# env assignments (EDIT_LIVE_SETTINGS_OK, HOME, ...) may follow.
rc_of() {
    local file="$1" tool="$2" field="$3"
    shift 3
    jq -n --arg tool "$tool" --arg field "$field" --arg file "$file" \
        '{tool_name: $tool, tool_input: {($field): $file}}' \
        | env "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

mkrepo() { # $1=path — init + one commit so `git rev-parse` has a real HEAD.
    mkdir -p "$1"
    git -C "$1" init -q
    git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

# Primary checkout fixture, with a linked worktree under it.
mkrepo "$SANDBOX/primary"
mkdir -p "$SANDBOX/primary/.claude"
printf '{}\n' > "$SANDBOX/primary/.claude/settings.json"
printf '{}\n' > "$SANDBOX/primary/.claude/settings.local.json"
printf '# readme\n' > "$SANDBOX/primary/README.md"

git -C "$SANDBOX/primary" worktree add -q "$SANDBOX/primary/.claude/worktrees/feat+x" -b feat/x >/dev/null 2>&1
mkdir -p "$SANDBOX/primary/.claude/worktrees/feat+x/.claude"
printf '{}\n' > "$SANDBOX/primary/.claude/worktrees/feat+x/.claude/settings.json"

# Fake $HOME fixture for the user-scope case — never touch the real $HOME.
FAKEHOME="$SANDBOX/fakehome"
mkdir -p "$FAKEHOME/.claude"
printf '{}\n' > "$FAKEHOME/.claude/settings.json"

# 1: primary checkout settings.json -> DENY
assert_rc "1 primary settings.json denies" 2 \
    "$(rc_of "$SANDBOX/primary/.claude/settings.json" Edit file_path)"

# 2: primary checkout settings.local.json -> DENY
assert_rc "2 primary settings.local.json denies" 2 \
    "$(rc_of "$SANDBOX/primary/.claude/settings.local.json" Edit file_path)"

# 3: $HOME/.claude/settings.json (user-scope live config) -> DENY
assert_rc "3 user-scope \$HOME/.claude/settings.json denies" 2 \
    "$(rc_of "$FAKEHOME/.claude/settings.json" Edit file_path HOME="$FAKEHOME")"

# 4: worktree copy of settings.json -> ALLOW
assert_rc "4 worktree settings.json allows" 0 \
    "$(rc_of "$SANDBOX/primary/.claude/worktrees/feat+x/.claude/settings.json" Edit file_path)"

# 5: non-settings file in the primary checkout -> ALLOW (proves this hook is
# not a blanket primary-checkout block; block-edit-on-main.sh owns that).
assert_rc "5 non-settings file in primary allows" 0 \
    "$(rc_of "$SANDBOX/primary/README.md" Edit file_path)"

# 6: tool parity — Write, MultiEdit, NotebookEdit all deny the same target.
assert_rc "6a Write on primary settings.json denies" 2 \
    "$(rc_of "$SANDBOX/primary/.claude/settings.json" Write file_path)"
assert_rc "6b MultiEdit on primary settings.json denies" 2 \
    "$(rc_of "$SANDBOX/primary/.claude/settings.json" MultiEdit file_path)"
assert_rc "6c NotebookEdit on primary settings.json denies" 2 \
    "$(rc_of "$SANDBOX/primary/.claude/settings.json" NotebookEdit notebook_path)"

# 7: traversal (worktrees/../.claude/settings.json) canonicalises back into
# the primary checkout -> DENY.
assert_rc "7 traversal into primary settings.json denies" 2 \
    "$(rc_of "$SANDBOX/primary/.claude/worktrees/../.claude/settings.json" Edit file_path)"

# 8: bypass env var -> ALLOW.
assert_rc "8 EDIT_LIVE_SETTINGS_OK=1 bypass allows" 0 \
    "$(rc_of "$SANDBOX/primary/.claude/settings.json" Edit file_path EDIT_LIVE_SETTINGS_OK=1)"

# bash_rc_of COMMAND [EXTRA_ENV...] — {tool_name: Bash, tool_input: {command:
# COMMAND}} on stdin, run the hook, echo its exit code.
bash_rc_of() {
    local cmd="$1"
    shift
    jq -n --arg cmd "$cmd" '{tool_name: "Bash", tool_input: {command: $cmd}}' \
        | env "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# 9: Bash `>` redirect into the primary checkout's settings.json -> DENY.
assert_rc "9 bash > redirect into primary settings.json denies" 2 \
    "$(bash_rc_of "echo pwned > $SANDBOX/primary/.claude/settings.json")"

# 10: Bash `>>` append into the primary checkout's settings.json -> DENY.
assert_rc "10 bash >> append into primary settings.json denies" 2 \
    "$(bash_rc_of "echo pwned >> $SANDBOX/primary/.claude/settings.json")"

# 11: Bash redirect into the WORKTREE copy of settings.json -> ALLOW.
assert_rc "11 bash redirect into worktree settings.json allows" 0 \
    "$(bash_rc_of "echo pwned > $SANDBOX/primary/.claude/worktrees/feat+x/.claude/settings.json")"

# 12: Bash redirect into a non-settings path -> ALLOW.
assert_rc "12 bash redirect into non-settings path allows" 0 \
    "$(bash_rc_of "echo hi > $SANDBOX/primary/notes.txt")"

# 13: fail-open proof — command mentions a settings basename but has no real
# `>`/`>>` redirect at all (the basename only appears in ordinary text piped
# through a pipeline) -> ALLOW, proving the ambiguous/unparseable case fails
# OPEN rather than closed.
assert_rc "13 bash mentions settings.json with no redirect allows (fail-open)" 0 \
    "$(bash_rc_of "echo 'do not touch .claude/settings.json' | cat")"

# 14: $HOME/.claude/settings.json rendered with a LOWERCASE drive letter
# (Windows hands the same file back interchangeably as `c:/...` or
# `C:/...`) -> DENY. Regression case for normalize_drive_form()'s
# drive-letter-case fix. Needs cygpath to render $HOME in drive-letter form
# at all; substitute the equivalent primary-checkout case elsewhere.
if command -v cygpath >/dev/null 2>&1; then
    FAKEHOME_DRIVE=$(cygpath -m "$FAKEHOME")
    FAKEHOME_LOWER="$(printf '%s' "${FAKEHOME_DRIVE:0:1}" | tr '[:upper:]' '[:lower:]')${FAKEHOME_DRIVE:1}"
    assert_rc "14 user-scope \$HOME lowercase drive letter denies" 2 \
        "$(rc_of "$FAKEHOME_LOWER/.claude/settings.json" Edit file_path HOME="$FAKEHOME")"
else
    echo "SKIP 14 drive-letter-case (\$HOME) — no cygpath on this platform; substituting primary-checkout equivalent"
    assert_rc "14 primary checkout equivalent (no drive-letter platform)" 2 \
        "$(rc_of "$SANDBOX/primary/.claude/settings.json" Edit file_path)"
fi

# 15: a QUOTED Bash redirect target into the primary checkout's
# settings.json -> DENY. Regression case: the extracted token used to keep
# its literal quote characters (`> "path"` -> token `"path"`), so
# `basename` never matched `settings.json` and the guard silently allowed
# it — the single most common way to quote a redirect target defeated the
# whole arm. `strip_quotes`-equivalent unwrapping in the Bash arm fixes this.
assert_rc "15 quoted bash redirect into primary settings.json denies" 2 \
    "$(bash_rc_of "echo pwned > \"$SANDBOX/primary/.claude/settings.json\"")"

# 16: a Bash redirect target spelled with a LITERAL (unexpanded) $HOME ->
# DENY. Regression case: the plain-text scan never expands shell variables,
# so `$HOME` used to canonicalise to a nonsense path under $cwd whose
# PARENT never matched the real $HOME/.claude — silently missing the
# user-scope deny for the exact spelling this arm exists to catch.
assert_rc "16 bash redirect using literal \$HOME denies" 2 \
    "$(bash_rc_of "echo pwned > \$HOME/.claude/settings.json" HOME="$FAKEHOME")"

# 17: a quoted Bash redirect target containing an internal SPACE -> DENY.
# Regression case: the old regex stopped matching at the first whitespace
# even inside quotes, truncating the token before it could canonicalise to
# settings.json at all — a live path legitimately contains a space on
# Windows (a `C:\Users\Jane Doe\...` profile).
SPACE_PRIMARY="$SANDBOX/pri mary"
mkrepo "$SPACE_PRIMARY"
mkdir -p "$SPACE_PRIMARY/.claude"
printf '{}\n' > "$SPACE_PRIMARY/.claude/settings.json"
assert_rc "17 quoted bash redirect with internal space denies" 2 \
    "$(bash_rc_of "echo pwned > \"$SPACE_PRIMARY/.claude/settings.json\"")"

# 18: alternate-case basename + parent (.CLAUDE/SETTINGS.JSON) into the
# primary checkout -> DENY. Regression case: NTFS/APFS are case-insensitive
# by default, so this names the SAME live file there; a case-sensitive
# `case` match let it walk straight past the guard.
assert_rc "18 alternate-case basename+parent denies" 2 \
    "$(rc_of "$SANDBOX/primary/.CLAUDE/SETTINGS.JSON" Edit file_path)"

# 19: a Bash redirect to an alternate-case path (SETTINGS.JSON) -> DENY.
# Regression case: the prefilter's own case-sensitive
# `case "$cmd" in *settings.json*)` used to exit early on an uppercase
# command and never reach the (already case-folded) scan below it at all.
assert_rc "19 bash redirect to alternate-case path denies" 2 \
    "$(bash_rc_of "echo pwned > $SANDBOX/primary/.CLAUDE/SETTINGS.JSON")"

# 20: a Bash redirect target spelled with the BRACED \${HOME} form, run
# from a LINKED WORKTREE cwd (no ancestor-.git-walk rescue possible there:
# git-dir != git-common-dir) -> DENY. Regression case: only the bare/prefix
# `$HOME` spelling was expanded before round 3; `${HOME}` fell through
# unexpanded, and unlike the bare form there is no coincidental rescue when
# cwd is a worktree.
assert_rc "20 bash redirect using \${HOME} from a worktree cwd denies" 2 \
    "$(cd "$SANDBOX/primary/.claude/worktrees/feat+x" && bash_rc_of "echo pwned > \${HOME}/.claude/settings.json" HOME="$FAKEHOME")"

# 21: user-scope \$HOME/.CLAUDE (alt-case PARENT) -> DENY. Regression case:
# round 2's basename/parent-basename fold only gated ENTRY into the deeper
# checks; the separate $HOME comparison below it compared the full parent
# PATH case-sensitively and still fell through on an alt-case parent.
assert_rc "21 user-scope \$HOME/.CLAUDE (alt-case parent) denies" 2 \
    "$(rc_of "$FAKEHOME/.CLAUDE/settings.json" Edit file_path HOME="$FAKEHOME")"

# 22: a Bash redirect target using CONCATENATED quoting — `"$path"/rest`,
# where only the first segment is quoted (valid, common shell idiom) -> DENY.
# Regression case: the old strip-only-if-fully-wrapped logic left the
# leading quote character attached, corrupting the PARENT path segment two
# levels up even though the basename still happened to read
# "settings.json".
assert_rc "22 bash redirect with concatenated quote denies" 2 \
    "$(bash_rc_of "echo pwned > \"$FAKEHOME\"/.claude/settings.json" HOME="$FAKEHOME")"

# 23/24: a path containing a literal APOSTROPHE that is part of the path
# itself, not shell quoting (`C:\Users\O'Brien\...`, a real Windows
# username shape) -> DENY, both unquoted and fully-quoted. Regression case:
# round 4's blanket `tr -d "\"'"` also deleted this apostrophe, corrupting
# the target into one that no longer canonicalises to the real file — a
# false ALLOW. The round-5 boundary-aware strip must leave a mid-segment
# apostrophe alone.
APOS_PRIMARY="$SANDBOX/O'Brien"
mkrepo "$APOS_PRIMARY"
mkdir -p "$APOS_PRIMARY/.claude"
printf '{}\n' > "$APOS_PRIMARY/.claude/settings.json"
assert_rc "23 bash redirect with literal apostrophe (unquoted) denies" 2 \
    "$(bash_rc_of "echo pwned > $APOS_PRIMARY/.claude/settings.json")"
assert_rc "24 bash redirect with literal apostrophe (quoted) denies" 2 \
    "$(bash_rc_of "echo pwned > \"$APOS_PRIMARY/.claude/settings.json\"")"

# Clean up the worktree registration before removing the sandbox (avoids a
# dangling `git worktree` admin record under SANDBOX/primary).
git -C "$SANDBOX/primary" worktree remove --force "$SANDBOX/primary/.claude/worktrees/feat+x" 2>/dev/null || true
rm -rf "$SANDBOX" 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
