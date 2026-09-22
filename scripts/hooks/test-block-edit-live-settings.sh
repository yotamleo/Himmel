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

# bash_rc_of CWD COMMAND [EXTRA_ENV...] — {tool_name: Bash, tool_input:
# {command: COMMAND, cwd: CWD}} on stdin, run the hook, echo its exit code.
# CWD is REQUIRED (not optional) from HIMMEL-1525 v2 onward: the unified
# Bash/PowerShell arm's live-vs-worktree decision is a function of the
# invoking cwd (resolve_repo_context), not of the mentioned path's own repo
# the way check_target's target-anchored walk is — an omitted cwd would
# silently resolve against wherever this test script happens to run instead
# of the sandbox fixture, making the assertion depend on the caller's own
# checkout layout rather than the fixture.
bash_rc_of() {
    local cwd="$1" cmd="$2"
    shift 2
    jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
        '{tool_name: "Bash", tool_input: {command: $cmd, cwd: $cwd}}' \
        | env "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# Second worktree fixture (HIMMEL-1525 v2), OUTSIDE the primary's own
# directory tree. The existing worktree above is nested under
# .claude/worktrees/ (needed for test 7's traversal-into-primary case); a v2
# cwd-based test needs a worktree whose own absolute path does NOT contain
# the primary's, so an absolute-path assertion can't pass by coincidence.
git -C "$SANDBOX/primary" worktree add -q "$SANDBOX/wt2" -b feat/wt2 >/dev/null 2>&1
mkdir -p "$SANDBOX/wt2/.claude"
printf '{}\n' > "$SANDBOX/wt2/.claude/settings.json"
PRIMARY="$SANDBOX/primary"
WT2="$SANDBOX/wt2"

# 9: Bash `>` redirect into the primary checkout's settings.json (relative,
# cwd=PRIMARY) -> DENY.
assert_rc "9 bash > redirect into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo pwned > .claude/settings.json")"

# 10: Bash `>>` append into the primary checkout's settings.json -> DENY.
assert_rc "10 bash >> append into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo pwned >> .claude/settings.json")"

# 11: Bash redirect into a WORKTREE's own settings.json (relative, cwd=WT2)
# -> ALLOW. This is the console NO-GO's false-positive fix: a relative
# mention while cwd is a linked worktree names that worktree's OWN copy.
assert_rc "11 bash redirect into worktree settings.json allows" 0 \
    "$(bash_rc_of "$WT2" "echo pwned > .claude/settings.json")"

# 12: Bash redirect into a non-settings path (cwd=PRIMARY) -> ALLOW.
assert_rc "12 bash redirect into non-settings path allows" 0 \
    "$(bash_rc_of "$PRIMARY" "echo hi > notes.txt")"

# 13: a settings.json mention with no redirect at all, piped through a
# read-only-looking command (cwd=PRIMARY) -> DENY. v1 failed this OPEN
# (fail-open on an unparseable case); v2's ONE fail-closed rule denies any
# live mention that isn't a bare allowlisted read (a `|` metachar disallows
# `is_readonly_allowlisted` even though the first token is `echo`) —
# documented behaviour change, not a bypass: bypass is
# `EDIT_LIVE_SETTINGS_OK=1` or an actually-bare allowlisted read (test 34).
assert_rc "13 bash mentions settings.json through a pipe denies (fail-closed, v2)" 2 \
    "$(bash_rc_of "$PRIMARY" "echo 'do not touch .claude/settings.json' | cat")"

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
# settings.json, run from an UNRELATED worktree cwd (WT2) -> DENY. Proves
# the absolute-path-into-primary match works on its own text, independent of
# is_primary_cwd, and needs no quote-stripping (v2 substring-matches the
# whole command text, quotes and all).
assert_rc "15 quoted bash redirect into primary settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "echo pwned > \"$PRIMARY/.claude/settings.json\"")"

# 16: a Bash redirect target spelled with a LITERAL (unexpanded) $HOME, run
# from a cwd that is neither the primary nor a worktree of it -> DENY.
# Proves the $HOME match is independent of is_primary_cwd.
assert_rc "16 bash redirect using literal \$HOME denies" 2 \
    "$(bash_rc_of "$SANDBOX" "echo pwned > \$HOME/.claude/settings.json" HOME="$FAKEHOME")"

# 17: a quoted Bash redirect target containing an internal SPACE, run with
# cwd AT that own space-bearing primary -> DENY. A live path legitimately
# contains a space on Windows (a drive path with a space in a user profile
# directory name); v2's plain substring match needs no special-casing for
# this at all.
SPACE_PRIMARY="$SANDBOX/pri mary"
mkrepo "$SPACE_PRIMARY"
mkdir -p "$SPACE_PRIMARY/.claude"
printf '{}\n' > "$SPACE_PRIMARY/.claude/settings.json"
assert_rc "17 quoted bash redirect with internal space denies" 2 \
    "$(bash_rc_of "$SPACE_PRIMARY" "echo pwned > \"$SPACE_PRIMARY/.claude/settings.json\"")"

# 18: alternate-case basename + parent (.CLAUDE/SETTINGS.JSON) into the
# primary checkout -> DENY. Regression case: NTFS/APFS are case-insensitive
# by default, so this names the SAME live file there; a case-sensitive
# `case` match let it walk straight past the guard.
assert_rc "18 alternate-case basename+parent denies" 2 \
    "$(rc_of "$SANDBOX/primary/.CLAUDE/SETTINGS.JSON" Edit file_path)"

# 19: a Bash redirect to an alternate-case path (SETTINGS.JSON), from WT2 ->
# DENY. Regression case: the prefilter's own case-fold (`cmd_lc`) must catch
# an uppercase command before the substring match runs.
assert_rc "19 bash redirect to alternate-case path denies" 2 \
    "$(bash_rc_of "$WT2" "echo pwned > $PRIMARY/.CLAUDE/SETTINGS.JSON")"

# 20: a Bash redirect target spelled with the BRACED \${HOME} form, run from
# a LINKED WORKTREE cwd (WT2, git-dir != git-common-dir) -> DENY. Regression
# case: only the bare/prefix `$HOME` spelling was checked before round 3;
# `${HOME}` fell through unmatched — mentions_primary_or_home explicitly
# checks the `${home}/.claude/` literal form.
assert_rc "20 bash redirect using \${HOME} from a worktree cwd denies" 2 \
    "$(bash_rc_of "$WT2" "echo pwned > \${HOME}/.claude/settings.json" HOME="$FAKEHOME")"

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
    "$(bash_rc_of "$PRIMARY" "echo pwned > \"$FAKEHOME\"/.claude/settings.json" HOME="$FAKEHOME")"

# 23/24: a path containing a literal APOSTROPHE that is part of the path
# itself, not shell quoting (`C:\Users\O'Brien\...`, a real Windows
# username shape) -> DENY, both unquoted and fully-quoted. cwd is the
# apostrophe-bearing primary itself so is_primary_cwd triggers regardless of
# how the mentioned path is spelled.
APOS_PRIMARY="$SANDBOX/O'Brien"
mkrepo "$APOS_PRIMARY"
mkdir -p "$APOS_PRIMARY/.claude"
printf '{}\n' > "$APOS_PRIMARY/.claude/settings.json"
assert_rc "23 bash redirect with literal apostrophe (unquoted) denies" 2 \
    "$(bash_rc_of "$APOS_PRIMARY" "echo pwned > $APOS_PRIMARY/.claude/settings.json")"
assert_rc "24 bash redirect with literal apostrophe (quoted) denies" 2 \
    "$(bash_rc_of "$APOS_PRIMARY" "echo pwned > \"$APOS_PRIMARY/.claude/settings.json\"")"

# powershell_rc_of CWD COMMAND [EXTRA_ENV...] — {tool_name: PowerShell,
# tool_input: {command: COMMAND, cwd: CWD}} on stdin, run the hook, echo its
# exit code. CWD is required for the same reason as bash_rc_of above.
powershell_rc_of() {
    local cwd="$1" cmd="$2"
    shift 2
    jq -n --arg cmd "$cmd" --arg cwd "$cwd" \
        '{tool_name: "PowerShell", tool_input: {command: $cmd, cwd: $cwd}}' \
        | env "$@" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# 25-33 (v2, console NO-GO redesign): the unified textual arm's critical
# bypasses, all from cwd=PRIMARY -> DENY. None of these are per-verb
# argument extraction any more — dir_dest is a whole-command textual match
# on a write verb/flag plus a `.claude` path component; mentions_settings is
# a whole-command substring match with no bare-allowlisted-read exemption
# once chaining/eval/subshell is present.
assert_rc "25 bash cp chained with && into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cp /tmp/x.json .claude/settings.json && echo done")"
assert_rc "26 bash cp into primary .claude/ dir denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cp /tmp/x.json .claude/")"
assert_rc "27 bash cp -t primary .claude/ dir denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cp -t .claude/ /tmp/x.json")"
assert_rc "28 bash sed -Ei on primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "sed -Ei 's/a/a/' .claude/settings.json")"
assert_rc "29 bash subshell cp into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "(cp /tmp/x.json .claude/settings.json)")"
assert_rc "30 bash backslash-escaped cp into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "\\cp /tmp/x.json .claude/settings.json")"
assert_rc "31 bash xargs cp into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo .claude/settings.json | xargs -I{} cp /tmp/x.json {}")"
assert_rc "32 bash command-substitution cp into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "x=\$(cp /tmp/x.json .claude/settings.json)")"
assert_rc "33 bash install into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "install /tmp/x.json .claude/settings.json")"

# 34 (v2): an absolute-path cp into the primary's settings.json, run from an
# unrelated worktree cwd (WT2) -> DENY. Proves the absolute-path-into-primary
# substring match fires independent of is_primary_cwd.
assert_rc "34 bash absolute-path cp into primary settings.json from WT2 denies" 2 \
    "$(bash_rc_of "$WT2" "cp /tmp/x.json $PRIMARY/.claude/settings.json")"

# 35: PowerShell Set-Content on the primary's settings.json, cwd=PRIMARY ->
# DENY. Proves the PowerShell arm shares the same unified textual logic.
assert_rc "35 powershell Set-Content on primary settings.json denies" 2 \
    "$(powershell_rc_of "$PRIMARY" "Set-Content -Path .claude/settings.json -Value x")"

# 36-41: controls that must stay ALLOW from cwd=PRIMARY — ordinary reads (this
# arm targets WRITE-shaped commands only; diagnosing the primary's settings.json
# by reading it is normal and must keep working), plus commands that don't
# mention a live settings file or a .claude/ dir-dest at all.
assert_rc "36 bash cat of primary settings.json allows" 0 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json")"
assert_rc "37 bash grep of primary settings.json allows" 0 \
    "$(bash_rc_of "$PRIMARY" "grep x .claude/settings.json")"
assert_rc "38 bash jq of primary settings.json allows" 0 \
    "$(bash_rc_of "$PRIMARY" "jq . .claude/settings.json")"
assert_rc "39 bash git diff of primary settings.json allows" 0 \
    "$(bash_rc_of "$PRIMARY" "git diff .claude/settings.json")"
assert_rc "40 bash node -e with no settings mention allows" 0 \
    "$(bash_rc_of "$PRIMARY" "node -e \"console.log(1)\"")"
assert_rc "41 bash redirect+node with no settings mention allows" 0 \
    "$(bash_rc_of "$PRIMARY" "jq . x.json > /tmp/o && node -e 1")"

# 42-47: controls that must stay ALLOW from cwd=WT2 — a worktree's own
# settings.json is not "live", so every verb (write, read, or PowerShell)
# stays open there, INCLUDING a deliberate-tightening case at 47.
assert_rc "42 bash echo-redirect write into worktree settings.json allows" 0 \
    "$(bash_rc_of "$WT2" "echo x > .claude/settings.json")"
assert_rc "43 bash cp of worktree settings.json as source allows" 0 \
    "$(bash_rc_of "$WT2" "cp .claude/settings.json /tmp/x")"
assert_rc "44 bash tee-read of worktree settings.json allows" 0 \
    "$(bash_rc_of "$WT2" "tee /tmp/log < .claude/settings.json")"
assert_rc "45 bash node -e writeFileSync into worktree settings.json allows" 0 \
    "$(bash_rc_of "$WT2" "node -e \"require('fs').writeFileSync('.claude/settings.json','{}')\"")"
assert_rc "46 bash sed -i on worktree settings.json allows" 0 \
    "$(bash_rc_of "$WT2" "sed -i 's/a/a/' .claude/settings.json")"
assert_rc "47 powershell Set-Content on worktree settings.json allows" 0 \
    "$(powershell_rc_of "$WT2" "Set-Content -Path .claude/settings.json -Value x")"

# 48 (v2 CR round 2, codex-1): `git diff --output=<file>` writes the diff to
# a file instead of stdout, so the read-only allowlist must not wave it
# through despite the allowlisted "diff" verb -> DENY.
assert_rc "48 bash git diff --output into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "git diff --output=.claude/settings.json")"

# 49 (v2 CR round 2, codex-2): an absolute path to a WORKTREE's own
# settings.json, nested (as worktrees usually are) under $HOME, must not be
# mistaken for the live $HOME/.claude/ config just because $HOME is a
# leading substring of the path -> ALLOW.
assert_rc "49 bash absolute-path cp into worktree's own settings.json allows" 0 \
    "$(bash_rc_of "$WT2" "cp /tmp/x.json $WT2/.claude/settings.json" HOME="$SANDBOX")"

# 50 (v2 CR round 2, codex-3): a QUOTED unexpanded \$HOME (`"\$HOME"/.claude/...`)
# must still be caught — the literal-pattern match must not require \$HOME
# and /.claude/ to be adjacent with no quote character between them -> DENY.
assert_rc "50 bash redirect using quoted literal \$HOME denies" 2 \
    "$(bash_rc_of "$SANDBOX" "echo pwned > \"\$HOME\"/.claude/settings.json" HOME="$FAKEHOME")"

# 51 (v2 CR round 2, codex-4): an absolute-path cp binary (`/bin/cp`) has no
# whitespace/`;`/`&`/`|` boundary before "cp", which must not let it evade
# the write-verb regex the way a bare `cp` would be caught -> DENY.
assert_rc "51 bash absolute-path /bin/cp into primary .claude/ dir denies" 2 \
    "$(bash_rc_of "$PRIMARY" "/bin/cp -r /tmp/payload/. .claude/")"

# Clean up worktree registrations before removing the sandbox (avoids
# dangling `git worktree` admin records under SANDBOX/primary).
git -C "$SANDBOX/primary" worktree remove --force "$SANDBOX/primary/.claude/worktrees/feat+x" 2>/dev/null || true
git -C "$SANDBOX/primary" worktree remove --force "$WT2" 2>/dev/null || true
rm -rf "$SANDBOX" 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
