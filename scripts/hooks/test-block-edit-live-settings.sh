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
git -C "$SANDBOX/primary" worktree add -q "$SANDBOX/wt2" -b feat/wt2 >/dev/null 2>&1 || {
    echo "FATAL: could not create the wt2 worktree fixture" >&2
    exit 1
}
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
assert_rc "46 bash sed in-place edit of worktree settings.json allows" 0 \
    "$(bash_rc_of "$WT2" "sed -i 's/a/a/' .claude/settings.json")" # gnu-ok: fixture text parsed by the hook, never executed as a shell command
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

# 52 (v2 CR round 3, codex-1): a relative parent-directory traversal
# (`../../../.claude/...`) from a nested worktree climbs out to the primary
# checkout's own `.claude/` without ever spelling out an absolute path or
# `$HOME` -> DENY.
assert_rc "52 bash relative traversal from nested worktree into primary settings.json denies" 2 \
    "$(bash_rc_of "$SANDBOX/primary/.claude/worktrees/feat+x" "echo pwned > ../../../.claude/settings.json")"

# 53 (was a v2 CR round 3 ALLOW control): an unrelated `..` next to the
# worktree's own settings is now an accepted false deny. Any `..` in a
# command that names settings voids the worktree exemption (HIMMEL-3468,
# console ruling on 1146): the hook cannot tell which word the `..` climbs
# from, and `../../settings.json` from a nested worktree is the primary's.
assert_rc "53 accepted false deny: unrelated .. beside the worktree's own settings denies" 2 \
    "$(bash_rc_of "$WT2" "cp ../backup-notes.txt .claude/settings.json")"

# 54 (v2 CR round 3, codex-3): a quoted RESOLVED $HOME path with the closing
# quote landing directly before `/.claude/...` (`"<resolved-home>"/.claude/...`)
# interposes a quote character between home_root_lc and the `/.claude`
# adjacency the round-2 fix (test 49) requires, which a literal substring
# match can't span unless quotes are stripped first. Distinct from test 50
# (a literal unexpanded `$HOME` token, matched separately) and from the
# primary-checkout case (primary_root_lc has no adjacency requirement, so
# quoting it was never a bypass) -> DENY.
assert_rc "54 bash quoted-resolved-\$HOME-path redirect denies" 2 \
    "$(bash_rc_of "$SANDBOX" "echo pwned > \"$FAKEHOME\"/.claude/settings.json" HOME="$FAKEHOME")"

# 55 (v2 CR round 3, codex-4): `less -o <file>` logs its input stream to a
# file — a write, despite `less` being an allowlisted read-only verb -> DENY.
assert_rc "55 bash less -o into primary settings.json denies" 2 \
    "$(bash_rc_of "$PRIMARY" "less -o .claude/settings.json < /tmp/payload")"

# 56 (v2 CR round 3, codex-5): a quoted `.claude` directory destination with
# NO trailing slash (`cp -r x/. ".claude"`) puts the closing quote immediately
# after `.claude`, which the boundary character class must accept too -> DENY.
assert_rc "56 bash quoted dir-dest with no trailing slash denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cp -r /tmp/payload/. \".claude\"")"

# 57 (CodeRabbit, PR #1115 round 3): from a cwd with no git repo anywhere
# upward AND an unresolved $HOME, resolve_repo_context leaves BOTH
# primary_root_lc and home_root_lc empty, so is_primary_cwd stays 0 and
# mentions_primary_or_home can never match either root -> the old code fell
# through to live=0 and ALLOWed. The live-vs-worktree question is simply
# unanswerable here, not answered "not live" -> must fail closed -> DENY.
assert_rc "57 bash mention of settings.json from a non-git cwd with unresolved HOME denies (fail-closed)" 2 \
    "$(bash_rc_of "$SANDBOX" "echo pwned > .claude/settings.json" -u HOME)"

# 58-74 (HIMMEL-3468): the post-#1115 fail-opens, each RED against da43ee9f.
# Every DENY row below has a baseline sibling in rows 9/26/34/B-rows that
# already denied at da43ee9f, so the row proves the prefix/spelling is what
# used to walk past the hook — not that the target was never guarded.
NESTED_WT="$SANDBOX/primary/.claude/worktrees/feat+x"

# 58-61: a cd/pushd earlier in the same command moves the real write target
# away from the PreToolUse cwd the worktree-relative exemption was judged on.
assert_rc "58 cd ../../.. from nested worktree then redirect into settings.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "cd ../../.. && echo x > .claude/settings.json")"
assert_rc "59 cd \"\$HOME\" then redirect into settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "cd \"\$HOME\" && echo x > .claude/settings.json" HOME="$FAKEHOME")"
assert_rc "60 cd ../../.. then cp -r into .claude/ dir denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "cd ../../.. && cp -r payload/. .claude/")"
assert_rc "61 pushd ../../.. then sed -i settings.json denies (verb-agnostic)" 2 \
    "$(bash_rc_of "$NESTED_WT" "pushd ../../.. && sed -i s/a/b/ .claude/settings.json")" # gnu-ok: fixture text parsed by the hook, never executed

# 62-63: a quote character directly before the write verb.
assert_rc "62 bash -c \"cp -r payload .claude/\" from primary denies" 2 \
    "$(bash_rc_of "$PRIMARY" "bash -c \"cp -r /tmp/payload .claude/\"")"
assert_rc "63 bash -c 'cp -r payload \$HOME/.claude/' denies" 2 \
    "$(bash_rc_of "$WT2" "bash -c 'cp -r /tmp/payload \$HOME/.claude/'" HOME="$FAKEHOME")"

# 64-66 (codex-4): `(` or `\` directly before the verb skipped rule 2.
assert_rc "64 subshell (cp -r payload \$HOME/.claude/) denies" 2 \
    "$(bash_rc_of "$WT2" "(cp -r /tmp/payload/. \$HOME/.claude/)" HOME="$FAKEHOME")"
assert_rc "65 backslash \\cp -r payload \$HOME/.claude/ denies" 2 \
    "$(bash_rc_of "$WT2" "\\cp -r /tmp/payload/. \$HOME/.claude/" HOME="$FAKEHOME")"
assert_rc "66 subshell (cp -r payload <primary>/.claude/) denies" 2 \
    "$(bash_rc_of "$WT2" "(cp -r /tmp/payload/. $PRIMARY/.claude/)")"

# 67 (codex-2 round 4): quotes were stripped from the command but not from
# the resolved root, so an apostrophe-bearing $HOME never matched.
assert_rc "67 quoted abs path into an apostrophe-bearing \$HOME denies" 2 \
    "$(bash_rc_of "$WT2" "echo x > '$APOS_PRIMARY'/.claude/settings.json" HOME="$APOS_PRIMARY")"

# 68 (codex-3): a PowerShell backslash spelling of $HOME's settings.json.
FAKEHOME_BS=$(printf '%s' "$FAKEHOME" | tr '/' "\\\\")
assert_rc "68 powershell backslash path into \$HOME settings.json denies" 2 \
    "$(powershell_rc_of "$WT2" "Set-Content -Path $FAKEHOME_BS\\.claude\\settings.json -Value x" HOME="$FAKEHOME")"

# 69 (codex-1, fail-closed over-deny): a nested worktree writing its OWN
# settings.json by absolute path contains the primary root as a substring,
# which must not make it "live" -> ALLOW (DENIED at da43ee9f).
assert_rc "69 nested worktree abs write to its own settings.json allows" 0 \
    "$(bash_rc_of "$NESTED_WT" "echo x > $NESTED_WT/.claude/settings.json")"

# 70-72: accepted false denies, asserted so they are documented behaviour,
# not surprises. A cd anywhere voids the worktree-relative exemption even
# when the cd is harmless (70); a heredoc whose PROSE names settings.json is
# a write (`>>`) whose target the hook does not parse (71, the console's
# FD-2). 72, FD-1's piped form, was a third accepted false deny until the
# per-segment allowlist (HIMMEL-3546): a read piped into another read is a
# chain of read-only segments, and allows.
#
# HIMMEL-3615/J1282O: row 71 briefly ALLOWed (trusting the tokenizer's word
# list to drop a heredoc-body-only mention) across this ticket's first three
# commits, on the theory that a heredoc body is prose/data, not a command
# word. Judge J1282O found that relaxation unsound in three ways at once —
# the tokenizer's heredoc model diverges from real bash's on `<<` inside an
# arithmetic context and on a backslash-newline-joined delimiter (so a real
# top-level write hides inside what the tokenizer thinks is body text), and
# no denylist of heredoc CONSUMERS that read the body as code can ever be
# complete (any stdin reader can turn a body into a write). 28 shapes that
# write, truncate or redirect into a live settings file ALLOWed at that head
# where base correctly denies all of them. Per the console's ruling, heredoc-
# body parsing leaves this hook entirely rather than trying to patch the
# tokenizer or extend the consumer list further: row 71 goes back to being an
# accepted false deny, and mentions_settings is a plain raw-text scan again,
# with no ST_LW rescan overriding it. The 28 shapes are pinned as DENY rows
# below (J1282O-F1 through J1282O-F3).
assert_rc "70 accepted false deny: harmless cd + worktree settings write denies" 2 \
    "$(bash_rc_of "$WT2" "cd . && echo x > .claude/settings.json")"
assert_rc "71 accepted false deny: cat >> other file with settings.json in heredoc prose denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cat >> /tmp/doc.md <<'EOF'
- avoided .claude/settings.json
EOF")"
assert_rc "72 piped grep naming settings.json from primary allows (HIMMEL-3546; was an accepted false deny)" 0 \
    "$(bash_rc_of "$PRIMARY" "grep -rl x scripts .claude/settings.json docs | head")"

# 71d-71g (HIMMEL-3615 ticket rows, user-scope \$HOME): the ticket's own
# repro list, run against \$HOME's live settings.json rather than the
# primary's (36-38 already cover the primary). 71d/71e are read-only
# controls that must ALLOW; 71f/71g are write shapes that must stay DENY.
assert_rc "71d bash grep of \$HOME settings.json allows" 0 \
    "$(bash_rc_of "$SANDBOX" "grep x ~/.claude/settings.json" HOME="$FAKEHOME")"
assert_rc "71e bash jq of \$HOME settings.json allows" 0 \
    "$(bash_rc_of "$SANDBOX" "jq . ~/.claude/settings.json" HOME="$FAKEHOME")"
assert_rc "71f bash python3 open(...,'w') on \$HOME settings.json denies" 2 \
    "$(bash_rc_of "$SANDBOX" "python3 -c \"open('$FAKEHOME/.claude/settings.json','w')\"" HOME="$FAKEHOME")"
assert_rc "71g bash jq redirect into \$HOME settings.json denies" 2 \
    "$(bash_rc_of "$SANDBOX" "jq . ~/.claude/settings.json > ~/.claude/settings.json" HOME="$FAKEHOME")"

# 71h-71j: a heredoc whose CONSUMER runs or parses the body (nested bash,
# git apply, bare patch) rather than reading it as inert prose. These used to
# be caught by a dedicated interpreter/diff-consumer denylist (removed per
# J1282O below); with row 71's relaxation gone, they now DENY the same way
# every other heredoc-body mention does — the raw text still names
# settings.json, and none of these outer verbs is on the read-only
# allowlist. Kept as regression pins for the specific consumer classes two
# earlier /pr-check rounds found bypassing the (now-removed) denylist.
assert_rc "71h heredoc body run by a nested bash writes to settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "bash <<'EOF'
echo x > .claude/settings.json
EOF")"
assert_rc "71i heredoc git-apply patch writing settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "git apply <<'EOF'
diff --git a/.claude/settings.json b/.claude/settings.json
index e69de29..0000000 100644
--- a/.claude/settings.json
+++ b/.claude/settings.json
@@ -0,0 +1 @@
+pwned
EOF")"
assert_rc "71j heredoc bare patch writing settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "patch -p1 <<'EOF'
--- a/.claude/settings.json
+++ b/.claude/settings.json
@@ -0,0 +1 @@
+pwned
EOF")"

# J1282O-F1 (verdict F1, Critical): the tokenizer treats `<<` as a heredoc
# operator even inside an arithmetic context, where bash reads it as a left
# shift — so a real top-level write on the next line used to vanish into what
# the (now-removed) tokenizer-trust mechanism thought was heredoc body.
# mentions_settings is a raw-text scan again, so these deny regardless of how
# the tokenizer parses `<<`.
assert_rc "J1282O-F1a arithmetic \$((1<<2)) then a real write to primary settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo \$((1<<2))
echo x > .claude/settings.json")"
assert_rc "J1282O-F1b arithmetic (( x = 1 << 2 )) then a real write to primary settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "(( x = 1 << 2 ))
echo x > .claude/settings.json")"
assert_rc "J1282O-F1c for ((i=1<<0;...)) then a truncate of primary settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "for ((i=1<<0; i<1; i++)); do :; done
truncate -s0 .claude/settings.json")"
assert_rc "J1282O-F1d arithmetic << then a real write to \$HOME settings.json, denies" 2 \
    "$(bash_rc_of "$SANDBOX" "echo \$((1<<2))
echo x > ~/.claude/settings.json" HOME="$FAKEHOME")"
assert_rc "J1282O-F1e arithmetic << then a real write to the primary's settings.json by absolute path, denies" 2 \
    "$(bash_rc_of "$SANDBOX" "echo \$((1<<2))
echo x > $PRIMARY/.claude/settings.json")"

# J1282O-F2 (verdict F2, Critical): for an unquoted heredoc delimiter, bash
# joins a backslash-newline before matching the delimiter; the tokenizer
# compared raw, unjoined lines, so it kept reading real commands as heredoc
# body past the point bash had already ended the heredoc.
assert_rc "J1282O-F2 backslash-newline-joined heredoc delimiter hides a real write, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cat <<EOF
EO\\
F
echo x > .claude/settings.json
EOF")"

# J1282O-F3 (verdict F3, Critical): the consumer denylist this ticket's first
# two /pr-check rounds built up (interpreters, git apply, patch) is
# structurally incomplete — any program that reads the heredoc body from
# stdin can turn it into a write, so the list can never enumerate all of
# them. Six of these were confirmed to write in real bash by the judge; the
# rest are pinned on the hook's own documented stdin semantics. All 16+6
# stay DENY now that no consumer list decides the outcome at all.
assert_rc "J1282O-F3a xargs truncate reading the target path from a heredoc, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "xargs truncate -s0 <<EOF
.claude/settings.json
EOF")"
assert_rc "J1282O-F3b . /dev/stdin sources a heredoc that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" ". /dev/stdin <<EOF
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3c read -r reads a path from a heredoc, then a write to it, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "read -r f <<EOF
.claude/settings.json
EOF
echo x > \"\$f\"")"
assert_rc "J1282O-F3d awk -f /dev/stdin runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "awk -f /dev/stdin <<EOF
BEGIN { print \"x\" > \".claude/settings.json\" }
EOF")"
assert_rc "J1282O-F3e sed -n -f /dev/stdin with a w command writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "sed -n -f /dev/stdin README.md <<EOF
w .claude/settings.json
EOF")"
assert_rc "J1282O-F3f \$SHELL run against a heredoc that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "\$SHELL <<EOF
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3g source /dev/stdin runs a heredoc that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "source /dev/stdin <<EOF
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3h while read loop truncates every path named in a heredoc, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "while read -r f; do : > \"\$f\"; done <<EOF
.claude/settings.json
EOF")"
assert_rc "J1282O-F3i ed -s runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "ed -s <<EOF
a
echo x > .claude/settings.json
.
w
q
EOF")"
assert_rc "J1282O-F3j ex -s runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "ex -s <<EOF
a
echo x > .claude/settings.json
.
:wq
EOF")"
assert_rc "J1282O-F3k gawk -f /dev/stdin runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "gawk -f /dev/stdin <<EOF
BEGIN { print \"x\" > \".claude/settings.json\" }
EOF")"
assert_rc "J1282O-F3l python3.12 - (versioned name) runs a heredoc that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "python3.12 - <<EOF
open('.claude/settings.json', 'w').write('x')
EOF")"
assert_rc "J1282O-F3m sqlite3 .output redirects a heredoc's query results into settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "sqlite3 <<EOF
.output .claude/settings.json
select 1;
EOF")"
assert_rc "J1282O-F3n make -f - runs a heredoc Makefile that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "make -f - <<EOF
all:
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3o fish runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "fish <<EOF
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3p pwsh -Command - runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "pwsh -Command - <<EOF
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3q bun run - runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "bun run - <<EOF
require('fs').writeFileSync('.claude/settings.json', 'x')
EOF")"
assert_rc "J1282O-F3r git am applies a heredoc mailbox patch writing settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "git am <<EOF
From: a <a@example.com>
Subject: pwned

---
 .claude/settings.json | 1 +
 1 file changed, 1 insertion(+)

diff --git a/.claude/settings.json b/.claude/settings.json
index e69de29..0000000 100644
--- a/.claude/settings.json
+++ b/.claude/settings.json
@@ -0,0 +1 @@
+pwned
EOF")"
assert_rc "J1282O-F3s absolute /usr/lib/git-core/git-apply spelling has no git+apply word pair, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "/usr/lib/git-core/git-apply <<EOF
diff --git a/.claude/settings.json b/.claude/settings.json
index e69de29..0000000 100644
--- a/.claude/settings.json
+++ b/.claude/settings.json
@@ -0,0 +1 @@
+pwned
EOF")"
assert_rc "J1282O-F3t at now schedules a heredoc job that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "at now <<EOF
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3u busybox ash runs a heredoc script that writes settings.json, denies" 2 \
    "$(bash_rc_of "$PRIMARY" "busybox ash <<EOF
echo x > .claude/settings.json
EOF")"
assert_rc "J1282O-F3v xargs truncate reading a \$HOME settings.json path from a heredoc, denies" 2 \
    "$(bash_rc_of "$SANDBOX" "xargs truncate -s0 <<EOF
$FAKEHOME/.claude/settings.json
EOF" HOME="$FAKEHOME")"

# 73-74 controls: FD-1's exact spelling stays a bare allowlisted read, and a
# worktree's own relative write with no cd stays open.
assert_rc "73 bare grep with settings.json as a search path allows (FD-1)" 0 \
    "$(bash_rc_of "$PRIMARY" "grep -rl \"block-edit-live-settings\" scripts .claude/settings.json docs")"
assert_rc "74 worktree relative settings write without cd allows" 0 \
    "$(bash_rc_of "$WT2" "echo x > .claude/settings.json")"

# 75-77: row 69's own-root strip must not open the primary. Regression
# guards (these already denied at da43ee9f): a nested worktree naming the
# PRIMARY's settings (75), climbing back out of its own root with `..` (76,
# which voids the strip), and naming both its own and the primary's (77).
assert_rc "75 nested worktree write to the primary's settings.json still denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "echo x > $PRIMARY/.claude/settings.json")"
assert_rc "76 nested worktree <own-root>/../../settings.json still denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "echo x > $NESTED_WT/../../settings.json")"
assert_rc "77 nested worktree naming its own AND the primary's settings still denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "echo x > $NESTED_WT/.claude/settings.json; echo y > $PRIMARY/.claude/settings.json")"

# 78 control: the verb boundary is the complement of a word character, so a
# verb embedded in a word (`add` holds `dd`) is not a write verb — worktree
# creation from the primary keeps working.
assert_rc "78 git worktree add under .claude/worktrees from primary allows" 0 \
    "$(bash_rc_of "$PRIMARY" "git worktree add .claude/worktrees/y -b y")"

# 79-82: an escape or empty quote INSIDE a word is dropped by the shell
# (`c\p` and `c""p` run cp, `settings.js\on` names settings.json), so the
# text is matched with quotes and backslashes removed — PowerShell's escape
# is the backtick instead.
assert_rc "79 intra-word backslash c\\p -r into \$HOME/.claude/ denies" 2 \
    "$(bash_rc_of "$WT2" "c\\p -r /tmp/payload/. \$HOME/.claude/" HOME="$FAKEHOME")"
assert_rc "80 intra-word empty quotes c\"\"p -r into \$HOME/.claude/ denies" 2 \
    "$(bash_rc_of "$WT2" "c\"\"p -r /tmp/payload/. \$HOME/.claude/" HOME="$FAKEHOME")"
assert_rc "81 intra-word backslash in settings.js\\on from primary denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo x > .claude/settings.js\\on")"
assert_rc "82 powershell backtick in settings.js\`on from primary denies" 2 \
    "$(powershell_rc_of "$PRIMARY" "Set-Content -Path .claude/settings.js\`on -Value x")"

# 83: the own-root strip needs a path boundary. A worktree whose root is a
# string prefix of the primary's (`<sandbox>/prim` vs `<sandbox>/primary`)
# must not blank out the front of the primary's path and hide the match.
PREFIX_WT="$SANDBOX/prim"
git -C "$SANDBOX/primary" worktree add -q "$PREFIX_WT" -b feat/prim >/dev/null 2>&1 || {
    echo "FATAL: could not create the prefix worktree fixture" >&2
    exit 1
}
assert_rc "83 worktree whose root prefixes the primary's still denies the primary's settings" 2 \
    "$(bash_rc_of "$PREFIX_WT" "echo x > $PRIMARY/.claude/settings.json")"

# 84-86: a line continuation (backslash-newline in Bash, backtick-newline in
# PowerShell) vanishes entirely, so a name split across one still spells it.
NL='
'
assert_rc "84 settings.js<backslash-newline>on from primary denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo x > .claude/settings.js\\${NL}on")"
assert_rc "85 c<backslash-newline>p -r into \$HOME/.claude/ denies" 2 \
    "$(bash_rc_of "$WT2" "c\\${NL}p -r /tmp/payload/. \$HOME/.claude/" HOME="$FAKEHOME")"
assert_rc "86 powershell settings.js<backtick-newline>on from primary denies" 2 \
    "$(powershell_rc_of "$PRIMARY" "Set-Content -Path .claude/settings.js\`${NL}on -Value x")"

# 87-91: a relative `..` climb from a worktree cwd. The nested worktree's
# `../../settings.json` IS the primary's live file, whatever the verb, so any
# `..` in a command that names settings voids the worktree exemption.
assert_rc "87 nested worktree echo > ../../settings.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "echo x > ../../settings.json")"
assert_rc "88 nested worktree cp /tmp/x ../../settings.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "cp /tmp/x ../../settings.json")"
assert_rc "89 nested worktree sed -i ../../settings.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "sed -i s/a/b/ ../../settings.json")"
assert_rc "90 nested worktree /proc/self/cwd/../../settings.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "echo x > /proc/self/cwd/../../settings.json")"
assert_rc "91 nested worktree git -C ../../.. checkout -- .claude/settings.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "git -C ../../.. checkout -- .claude/settings.json")"

# 92: a `-C <dir>` word moves the target like a cd does.
assert_rc "92 git -C ~ checkout -- .claude/settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "git -C ~ checkout -- .claude/settings.json" HOME="$FAKEHOME")"

# 93-97: `//` and `/./` name the same path as `/`, so they are collapsed
# before any root is matched.
assert_rc "93 <home>//.claude/settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "echo x > $FAKEHOME//.claude/settings.json" HOME="$FAKEHOME")"
assert_rc "94 \$HOME//.claude/settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "echo x > \$HOME//.claude/settings.json" HOME="$FAKEHOME")"
assert_rc "95 ~/./.claude/settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "echo x > ~/./.claude/settings.json" HOME="$FAKEHOME")"
assert_rc "96 <sandbox>//primary/.claude/settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "echo x > $SANDBOX//primary/.claude/settings.json")"
assert_rc "97 <sandbox>/./primary/.claude/settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "echo x > $SANDBOX/./primary/.claude/settings.json")"

# 98-100: a `~user` home, and `~/.claude` named as a directory with no
# trailing slash.
assert_rc "98 ~user/.claude/settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "echo x > ~someone/.claude/settings.json" HOME="$FAKEHOME")"
assert_rc "99 cp /tmp/x ~/.claude from a worktree denies" 2 \
    "$(bash_rc_of "$WT2" "cp /tmp/settings.json ~/.claude" HOME="$FAKEHOME")"
assert_rc "100 cp /tmp/x ~/.claude from a non-repo cwd denies" 2 \
    "$(bash_rc_of "$SANDBOX" "cp /tmp/settings.json ~/.claude" HOME="$FAKEHOME")"

# 101: a cwd outside any repo has no worktree to exempt, so a relative
# mention resolves to whatever sits there — here $HOME's own settings.
assert_rc "101 relative .claude/settings.json write with cwd=\$HOME denies" 2 \
    "$(bash_rc_of "$FAKEHOME" "echo x > .claude/settings.json" HOME="$FAKEHOME")"

# 102-105 controls: the new rules must not reach these.
assert_rc "102 git -C <primary>/.claude/worktrees/x status allows" 0 \
    "$(bash_rc_of "$WT2" "git -C $PRIMARY/.claude/worktrees/x status")"
assert_rc "103 ls .claude/worktrees from primary allows" 0 \
    "$(bash_rc_of "$PRIMARY" "ls .claude/worktrees")"
assert_rc "104 cp /tmp/x .claude/ from a worktree allows" 0 \
    "$(bash_rc_of "$WT2" "cp /tmp/x .claude/")"
assert_rc "105 grep -C 3 on the worktree's own settings allows" 0 \
    "$(bash_rc_of "$WT2" "grep -C 3 x .claude/settings.json")"

# 106-109: ANSI-C quoting spells any byte, so a `$'` beside a settings or
# claude substring is live, undecoded (console round-2 NO-GO).
assert_rc "106 ANSI-C \$'\\x2e\\x2e' climb from a nested worktree denies" 2 \
    "$(bash_rc_of "$NESTED_WT" 'echo x > $'"'"'\x2e\x2e'"'"'/$'"'"'\x2e\x2e'"'"'/settings.json')"
assert_rc "107 ANSI-C split settings\$'\\x2e'json from primary denies" 2 \
    "$(bash_rc_of "$PRIMARY" 'echo x > .claude/settings$'"'"'\x2e'"'"'json')"
assert_rc "108 ANSI-C split settings name from a worktree denies (accepted false deny)" 2 \
    "$(bash_rc_of "$WT2" 'echo x > .claude/settings$'"'"'\x2e'"'"'json')"
assert_rc "109 ANSI-C with no settings/claude mention allows" 0 \
    "$(bash_rc_of "$WT2" 'printf $'"'"'a\tb\n'"'"' > /tmp/out.json')"
# 110: ANSI-C spelled verb (`$'\x63\x70'` = cp) into the home .claude (CodeRabbit).
# shellcheck disable=SC2016  # $HOME is literal command text for the hook
assert_rc "110 ANSI-C spelled cp into \$HOME/.claude from a worktree denies" 2 \
    "$(bash_rc_of "$WT2" '$'"'"'\x63\x70'"'"' -r /tmp/payload/. "$HOME/.claude/"')"

# 111-114: a line continuation between `$` and `'` (LF and CRLF) still makes
# ANSI-C quoting — bash joins the lines before it reads words (console E NO-GO).
for eol in LF CRLF; do
    if [ "$eol" = LF ]; then cont="\$\\"$'\n'; else cont="\$\\"$'\r\n'; fi
    assert_rc "111/113 continued ANSI-C climb from a nested worktree denies ($eol)" 2 \
        "$(bash_rc_of "$NESTED_WT" "echo x > ${cont}'\\x2e\\x2e'/${cont}'\\x2e\\x2e'/settings.json")"
    # shellcheck disable=SC2016  # $HOME is literal command text for the hook
    assert_rc "112/114 continued ANSI-C cp into \$HOME/.claude denies ($eol)" 2 \
        "$(bash_rc_of "$WT2" "${cont}'\\x63\\x70' -r /tmp/payload/. \"\$HOME/.claude/\"")"
done

# 115: a command mentioning the primary checkout's OWN root path as a bare
# substring, with no .claude reference anywhere, run from an unrelated cwd
# (WT2), and only incidentally "mentioning settings" via an unrelated
# filename -> ALLOW. `stat` (not `jq`/`cat`/etc.) is deliberately NOT on the
# read-only allowlist, so this exercises the live/not-live distinction
# itself rather than being exempted regardless of it. Before the fix,
# primary_root_lc matched as an unconstrained bare substring (unlike
# home_root_lc's existing /.claude adjacency requirement below), so a
# READ-ONLY command on a scratchpad file merely nested under the primary's
# path false-denied (HIMMEL-3465).
assert_rc "115 primary root mention with no .claude reference allows (HIMMEL-3465)" 0 \
    "$(bash_rc_of "$WT2" "stat \"$PRIMARY/scratch/leg-settings.json\"")"

# 116 control: the same primary root, this time immediately followed by
# /.claude/settings.json, still denies — proves 115's fix did not widen the
# genuine live-settings case.
assert_rc "116 primary root immediately followed by /.claude still denies (control)" 2 \
    "$(bash_rc_of "$WT2" "stat \"$PRIMARY/.claude/settings.json\"")"

# 117: `ls -t` (sort-by-time) naming a live .claude dir as a plain listing
# argument, not a copy/move destination -> ALLOW. Before the fix, the
# -t/--target-directory flag check fired standalone regardless of verb, so
# any `-t` anywhere near a .claude mention false-denied (HIMMEL-3465).
assert_rc "117 ls -t on a .claude path allows (HIMMEL-3465)" 0 \
    "$(bash_rc_of "$WT2" "ls -t \$HOME/.claude/handover/bridge/ | head" HOME="$FAKEHOME")"

# 118 control: cp -t into \$HOME/.claude/ still denies — proves 117's fix did
# not widen the genuine copy-into-live-settings-dir case (cp is still one of
# the matched copy/move verbs).
assert_rc "118 cp -t into \$HOME/.claude/ still denies (control)" 2 \
    "$(bash_rc_of "$WT2" "cp -t \$HOME/.claude/ /tmp/payload" HOME="$FAKEHOME")"

# 119: the exact command a console session hit today (2026-09-23) — a
# read-only `jq` query of a generated leg-settings scratchpad file whose
# basename ends in "settings.json" (a bare substring match on
# mentions_settings), from a scratchpad path nested under neither the
# primary's nor $HOME's .claude/ -> ALLOW. Verified against a base-054df92e
# extraction too: this exact command already ALLOWs at base (rc=0, no stash),
# so the hook was never the cause of that refusal — jq without -i/--in-place
# is on the read-only allowlist regardless of the live/not-live question.
assert_rc "119 jq read of a scratchpad .leg-settings.json file allows" 0 \
    "$(bash_rc_of "$PRIMARY" "jq '{add:.permissions.additionalDirectories}' /tmp/claude-1000/somesession/scratchpad/HIMMEL-3514-N424-bridge-hardening.leg-settings.json")"

# 120 control: the same read, this time redirected into the PRIMARY's live
# settings.json (a genuine write) -> DENY — proves 119's exemption only
# covers the read-only verb, not the file itself. (codex-3 panel finding,
# round 5, HIMMEL-3517: the earlier version of this control used `jq -i`,
# which jq does not actually support as a flag — it denied via the hook's
# textual `-i` scan, not because it was a real write, so it never exercised
# an actual write path. Replaced with a genuine `>` redirect, a write shape
# jq truly performs.)
assert_rc "120 jq read redirected into primary settings.json still denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "jq '{add:.permissions.additionalDirectories}' /tmp/claude-1000/somesession/scratchpad/HIMMEL-3514-N424-bridge-hardening.leg-settings.json > .claude/settings.json")"

# 121: the console's OWN verbatim reproduction (K ruling 2026-09-23 on
# K-N431-7980c9b9): a `VAR=path;`-prefixed, `;`-compound, TWO-statement
# read-only `jq` command, from a PRIMARY-checkout cwd. It denied from
# HIMMEL-3465 until HIMMEL-3546: two panel rounds each found a real bypass in
# a TEXT-split per-segment allowlist (an assignment shortcut riding past a
# later write on a newline-embedded segment, then the same class one round
# later), so the split was reverted to "any bare `;` vetoes". The per-segment
# check is now done on tokens (_tok_readonly_ok): a newline is a separator
# like `;`, every segment must be an assignment-only segment or one
# allowlisted read, and an assignment to an exported or sensitive name
# denies — so this harmless chain allows and 122-126 still deny.
assert_rc "121 VAR=path; jq read; jq read (console repro) allows (HIMMEL-3546 per-segment allowlist)" 0 \
    "$(bash_rc_of "$PRIMARY" "SP=/tmp/claude-1000/somesession/scratchpad; jq '.permissions.additionalDirectories' \$SP/HIMMEL-3514-N424-bridge-hardening.leg-settings.json; jq '.permissions.additionalDirectories' \$SP/HIMMEL-3536-N425-step0-remainder.leg-settings.json")"

# 122 control: the same VAR=path;-prefixed shape, this time with a genuine
# WRITE (sed -i) as the chained statement — denies: the sed segment is not a
# read (st_sed_args refuses -i in the read-only allowlist).
assert_rc "122 VAR=path; write-in-place still denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "X=/tmp/claude-1000/somesession/scratchpad; sed -i s/a/b/ \$X/settings.json")" # gnu-ok: fixture text parsed by the hook, never executed

# 123 control: a `;`-joined write with NO leading assignment (`cat x; rm -rf
# ~`-shaped) still denies — every segment is judged, and the second is sed -i.
assert_rc "123 jq read; write-in-place (no assignment) still denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "jq '.permissions.additionalDirectories' /tmp/claude-1000/somesession/scratchpad/HIMMEL-3514-N424-bridge-hardening.leg-settings.json; sed -i s/a/b/ /tmp/claude-1000/somesession/scratchpad/HIMMEL-3514-N424-bridge-hardening.leg-settings.json")" # gnu-ok: fixture text parsed by the hook, never executed

# 124: a `|` INSIDE a quoted jq filter argument (`test("a|b")`) read as a
# real shell pipe once quotes were stripped (HIMMEL-3468's text scan), and the
# command also carried a bare `;`, so it denied twice over. The tokenizer
# keeps the quoted `|` inside its word (HIMMEL-3546), so it allows.
assert_rc "124 VAR=path; jq with a quoted-pipe regex filter allows (HIMMEL-3546 quote-aware)" 0 \
    "$(bash_rc_of "$PRIMARY" "SP=/tmp/claude-1000/somesession/scratchpad; jq '[.permissions.allow[]? | select(test(\"luna|handover\"))]' \$SP/HIMMEL-3514-N424-bridge-hardening.leg-settings.json")"

# 125: PATH-hijack shape (/pr-check critic panel round 1, Critical,
# 2026-09-23) — `PATH=/tmp/evil; cat ~/.claude/settings.json` would run the
# later `cat` under an attacker-controlled PATH if the chain were allowlisted.
# Denies because PATH is a sensitive assignment name (_tok_sensitive_name),
# and an exported one besides.
assert_rc "125 PATH=/tmp/evil; cat live settings.json still denies (HIMMEL-3465)" 2 \
    "$(bash_rc_of "$PRIMARY" "PATH=/tmp/evil; cat \$PRIMARY/.claude/settings.json")"

# 126: newline-in-segment write shape (/pr-check critic panel round 2,
# Critical, 2026-09-23) — a `;`-segment that itself embeds a real newline.
# The tokenizer splits on the newline too, so `sed -i …` is its own segment
# and denies as a write, whatever the assignment before it.
CMD126=$'X=1\nsed -i s/a/b/ .claude/settings.json; jq \'.foo\' .claude/settings.json'
assert_rc "126 newline-in-segment write still denies (HIMMEL-3465)" 2 \
    "$(bash_rc_of "$PRIMARY" "$CMD126")"

# 127-131 (HIMMEL-3499): named residuals from HIMMEL-3468's PR #1146 — extract
# and checkout tools that clobber a live .claude/ without going through the
# cp/mv/install/rsync/ln/dd/tee verb list or naming settings.json in the text.
# Each RED against 6cba9613 (the HIMMEL-3468 merge base for this ticket).
assert_rc "127 git checkout <ref> -- .claude from primary denies (probe 1)" 2 \
    "$(bash_rc_of "$PRIMARY" "git checkout origin/x -- .claude")"
assert_rc "128 tar -x -C .claude from primary denies (probe 2)" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -xf a.tar -C .claude")"
assert_rc "129 unzip -d .claude from primary denies (probe 3)" 2 \
    "$(bash_rc_of "$PRIMARY" "unzip -o a.zip -d .claude")"
assert_rc "130 tar -C \$HOME/.claude from a non-repo cwd denies (probe 4)" 2 \
    "$(bash_rc_of "$SANDBOX" "tar -xf a.tar -C \$HOME/.claude" HOME="$FAKEHOME")"
assert_rc "131 git restore --source=<ref> -- .claude from primary denies (scope companion to probe 1)" 2 \
    "$(bash_rc_of "$PRIMARY" "git restore --source=origin/x -- .claude")"

# 132-135: ordinary worktree git/extract use stays ALLOW. 132 has no .claude
# mention at all (an everyday branch checkout); 133-135 target a WORKTREE'S
# OWN .claude — a bare relative mention with no cd/-C/.. and no primary/$HOME
# prefix, same exemption every other verb already gets.
assert_rc "132 git checkout -b <branch> with no .claude mention allows" 0 \
    "$(bash_rc_of "$PRIMARY" "git checkout -b some-branch")"
assert_rc "133 git checkout HEAD -- .claude from a worktree (own dir) allows" 0 \
    "$(bash_rc_of "$WT2" "git checkout HEAD -- .claude")"
assert_rc "134 unzip -d .claude from a worktree (own dir) allows" 0 \
    "$(bash_rc_of "$WT2" "unzip -o a.zip -d .claude")"
assert_rc "135 git restore --source=HEAD -- .claude from a worktree (own dir) allows" 0 \
    "$(bash_rc_of "$WT2" "git restore --source=HEAD -- .claude")"

# 136: accepted false deny, documented (HIMMEL-3499, same shape as the
# HIMMEL-3468 cd/pushd precedent). tar's OWN directory flag is `-C`, the same
# spelling changes_directory() already treats as "the target may have moved,
# void the worktree-relative exemption" for `git -C`/`env -C`/`make -C`. That
# blunt rule cannot distinguish tar's `-C .claude` (which NAMES its own
# destination, not an unrelated cwd shift) from a genuine directory jump, so
# it denies this worktree's own extraction too. Accepted: matches the
# project's stated preference (fail closed, prefer false positive) and needs
# no new parsing to fix.
assert_rc "136 tar -x -C .claude from a worktree (own dir) denies (accepted false deny)" 2 \
    "$(bash_rc_of "$WT2" "tar -xf a.tar -C .claude")"

# 137-149 (HIMMEL-3499, adversarial panel round on PR #1210): fixes for
# false-denies and false-positives the panel found in the HIMMEL-3499 fix
# itself, verified against the panel's own probe corpus
# (scratchpad/{run.sh,cases,cases2,cases3}.txt) before being written here.

# 137-138: a `.claude/worktrees/<name>` mention is a CONTAINER path, not a
# destination — every linked worktree lives there, so an ordinary
# cross-worktree `-C <other-worktree-path>` reference (a ubiquitous shape:
# `git -C <wt> checkout …`, `tar -C <wt>/vendor -x …`) is NOT "naming
# .claude as a destination", even though the worktree's own path contains
# ".claude" as a substring. Before this fix these false-denied from EVERY
# cwd once "checkout"/"tar" became recognized verbs — a fleet-breaking
# regression (panel finding 1, IMPORTANT).
assert_rc "137 git -C <other-worktree> checkout from an unrelated cwd allows" 0 \
    "$(bash_rc_of "$WT2" "git -C $NESTED_WT checkout -- scripts/x.sh")"
assert_rc "138 tar -xzf into <other-worktree>/vendor from an unrelated cwd allows" 0 \
    "$(bash_rc_of "$WT2" "tar -xzf a.tgz -C $NESTED_WT/vendor")"

# 139-140: gtar/bsdtar are common alternate tar spellings — before this fix
# they denied only by ACCIDENT, via a `.tar`-suffixed archive-filename
# argument matching the bare `tar` word (`a.tar` contains the `tar` word,
# `.tar` boundary and all) — an archive named anything else evaded
# detection entirely (panel residual note). `.tgz` filenames below prove the
# recognition is now robust, not accidental.
assert_rc "139 bsdtar -C \$HOME/.claude (.tgz archive, no accidental match) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "bsdtar -xf a.tgz -C \$HOME/.claude" HOME="$FAKEHOME")"
assert_rc "140 gtar --directory=\$HOME/.claude (.tgz archive, no accidental match) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "gtar -xzf pkg.tgz --directory=\$HOME/.claude" HOME="$FAKEHOME")"

# 141-142: a short flag glued directly to its argument (`-C.claude`,
# `-d.claude`, `-t.claude`) put an alnum character immediately before the
# dot, which the old leading-boundary class rejected — a real bypass (GNU
# tar/unzip/cp all accept the glued form; panel finding 2, IMPORTANT). 142
# is the SAME regex bug predating this PR (`cp -t.claude`), fixed in the
# same pass per the panel's request.
assert_rc "141 tar -xf a.tar -C.claude (glued flag) from primary denies" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -xf a.tar -C.claude")"
assert_rc "142 cp x -t.claude (glued flag, pre-existing bug) from primary denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cp x -t.claude")"

# 143-145: tar's CREATE (-c) and LIST (-t) modes, and unzip's LIST (-l) mode,
# read/archive `.claude`'s CONTENTS — they do not write into it. Before this
# fix the bare verb word matched regardless of mode and false-denied a
# legitimate backup/listing (panel finding 3, MINOR).
assert_rc "143 tar -czf backup.tgz .claude (create mode) from primary allows" 0 \
    "$(bash_rc_of "$PRIMARY" "tar -czf backup.tgz .claude")"
assert_rc "144 tar -tf a.tar .claude/ (list mode) from primary allows" 0 \
    "$(bash_rc_of "$PRIMARY" "tar -tf a.tar .claude/")"
assert_rc "145 unzip -l a.zip .claude/* (list mode) from primary allows" 0 \
    "$(bash_rc_of "$PRIMARY" "unzip -l a.zip .claude/*")"

# 146-148: "checkout"/"restore" are ordinary English words that show up as
# plain filenames or grep search terms with no git verb anywhere — a bare
# bare-word match false-denied a plain read (panel finding 3, MINOR). Requires
# a `git` word co-occurring anywhere in the text (loose, not adjacency) —
# 148 proves this still catches `git checkout` even with another git flag
# (`--work-tree=.`) sitting between "git" and "checkout".
assert_rc "146 cat of a file literally named checkout.md allows" 0 \
    "$(bash_rc_of "$PRIMARY" "cat \$HOME/.claude/commands/checkout.md" HOME="$FAKEHOME")"
assert_rc "147 grep for the word restore (no git verb) allows" 0 \
    "$(bash_rc_of "$PRIMARY" "grep -rn restore \$HOME/.claude/skills" HOME="$FAKEHOME")"
assert_rc "148 git --work-tree=. checkout -- .claude (non-adjacent git flag) still denies" 2 \
    "$(bash_rc_of "$PRIMARY" "git --work-tree=. checkout x -- .claude")"

# 149 control: the four HIMMEL-3499 probes still deny after the redesign —
# regression guard for the fix this panel round revised.
assert_rc "149 git checkout <ref> -- .claude from primary still denies (probe 1 regression guard)" 2 \
    "$(bash_rc_of "$PRIMARY" "git checkout origin/x -- .claude")"

# 150-153 (HIMMEL-3499, fourth panel round on #1210, F1 IMPORTANT): a `..`
# after the `.claude/worktrees/` container-path strip climbs back OUT of the
# worktrees container into the primary's own `.claude` — the strip must not
# apply when `..` appears anywhere, mirroring mentions_primary_or_home()'s
# own-root blanking rule for the identical reason (the hook never resolves
# `..`, so refusing to strip is what keeps the climb visible to the
# existing `..` live-check rule). All 4 gave rc=0 everywhere before this fix.
assert_rc "150 cp -r x/. into <primary>/.claude/worktrees/.. denies" 2 \
    "$(bash_rc_of "$WT2" "cp -r x/. $PRIMARY/.claude/worktrees/..")"
assert_rc "151 rsync -a into <primary>/.claude/worktrees/../ denies" 2 \
    "$(bash_rc_of "$WT2" "rsync -a x/ $PRIMARY/.claude/worktrees/../")"
assert_rc "152 cp -r x/. into relative .claude/worktrees/.. from primary denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cp -r x/. .claude/worktrees/..")"
assert_rc "153 cp -r x/. into <nested-worktree>/../../ denies" 2 \
    "$(bash_rc_of "$WT2" "cp -r x/. $NESTED_WT/../../")"

# 154-158 (HIMMEL-3499, fourth panel round on #1210, F2 MED): the tar/unzip
# mode check is scoped to the shell SEGMENT containing the verb (split on
# `;`, `&`, `|`, `#`) — a chained or commented trailing token used to spoof
# it via a coincidental ` -t`/` -c`/` -l`/` -v` elsewhere in the command. All
# 5 gave rc=0 everywhere before this fix, despite a genuine extraction into
# a live $HOME/.claude target.
assert_rc "154 tar -C \$HOME/.claude then a chained ls -t still denies" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -xzf a.tgz -C \$HOME/.claude; ls -t" HOME="$FAKEHOME")"
assert_rc "155 tar -C \$HOME/.claude then && bash -c true still denies" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -xzf a.tgz -C \$HOME/.claude && bash -c true" HOME="$FAKEHOME")"
assert_rc "156 tar --directory \$HOME/.claude with a trailing # -t comment still denies" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -xzf a.tgz --directory \$HOME/.claude # -t" HOME="$FAKEHOME")"
assert_rc "157 unzip -d \$HOME/.claude then && ls -l still denies" 2 \
    "$(bash_rc_of "$PRIMARY" "unzip -o a.zip -d \$HOME/.claude && ls -l" HOME="$FAKEHOME")"
assert_rc "158 unzip -d \$HOME/.claude with a trailing -x -v still denies" 2 \
    "$(bash_rc_of "$PRIMARY" "unzip -o a.zip -d \$HOME/.claude -x -v" HOME="$FAKEHOME")"

# 159 (HIMMEL-3499, fourth panel round on #1210, F3 LOW): checkout/restore's
# git-co-occurrence check is scoped to the same segment too — "git" in a
# LATER, unrelated chained command must not make an unrelated read look like
# a git-checkout write. Gave rc=2 everywhere before this fix.
assert_rc "159 cat of a checkout.md file, then && git status (unrelated segment), allows" 0 \
    "$(bash_rc_of "$PRIMARY" "cat \$HOME/.claude/checkout.md && git status" HOME="$FAKEHOME")"

# 160-171 (HIMMEL-3564): the tar/unzip/checkout mode checks read ONE segment
# (the first whose text matched the verb), so a later segment escaped them,
# and a quote-stripped text scan read a flag inside a filename. Every segment
# is now judged from quote-aware tokens (HIMMEL-3546). All must deny.
assert_rc "160 tar -tf; then tar -xf -C ~/.claude (second segment) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -tf a.tar; tar -xf a.tar -C ~/.claude" HOME="$FAKEHOME")"
assert_rc "161 unzip -l; then unzip -o -d ~/.claude (second segment) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "unzip -l a.zip; unzip -o a.zip -d ~/.claude" HOME="$FAKEHOME")"
assert_rc "162 echo tar c; then tar -xf -C ~/.claude denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo tar c; tar -xf a.tar -C ~/.claude" HOME="$FAKEHOME")"
assert_rc "163 echo checkout; then git checkout -- .claude denies" 2 \
    "$(bash_rc_of "$PRIMARY" "echo checkout; git checkout x -- .claude")"
assert_rc "164 cat checkout.md; then git checkout -- .claude denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cat checkout.md; git checkout x -- .claude")"
assert_rc "165 tar -xf my--list.tar (flag text inside a filename) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -xf my--list.tar -C ~/.claude" HOME="$FAKEHOME")"
assert_rc "166 tar -xf \"x -t.tar\" (flag text inside a quoted filename) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "tar -xf \"x -t.tar\" -C ~/.claude" HOME="$FAKEHOME")"
assert_rc "167 tar -xf inside \$( ) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "x=\$(tar -xf a.tar -C ~/.claude)" HOME="$FAKEHOME")"
assert_rc "168 tar -xf inside backticks denies" 2 \
    "$(bash_rc_of "$PRIMARY" "x=\`tar -xf a.tar -C ~/.claude\`" HOME="$FAKEHOME")"
assert_rc "169 TAR (upper case) -xzf -C ~/.claude; ls -t denies" 2 \
    "$(bash_rc_of "$PRIMARY" "TAR -xzf a.tgz -C ~/.claude; ls -t" HOME="$FAKEHOME")"
assert_rc "170 find -exec tar -tf, then -exec tar -xf -C ~/.claude (second tar word) denies" 2 \
    "$(bash_rc_of "$PRIMARY" "find . -exec tar -tf {} \\; -exec tar -xf a.tar -C ~/.claude \\;" HOME="$FAKEHOME")"
assert_rc "171 unzip -L (not list mode; case-folded to -l before) -d ~/.claude denies" 2 \
    "$(bash_rc_of "$PRIMARY" "unzip -L a.zip -d ~/.claude" HOME="$FAKEHOME")"

# 172-185 (HIMMEL-3546): the read-only allowlist is judged per segment from
# quote-aware tokens. A metacharacter inside quotes is data; a chain of
# read-only segments allows; every real write, redirect, subshell or
# substitution, and every exec-influencing assignment, still denies.
assert_rc "172 cat live settings | jq (a pipe of read-only segments) allows" 0 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json | jq '.permissions'")"
assert_rc "173 tail | grep | sed s/// (verified inert s command) allows" 0 \
    "$(bash_rc_of "$PRIMARY" "tail -5 .claude/settings.json | grep allow | sed 's/a/b/g'")"
assert_rc "174 jq with a quoted > inside the filter allows" 0 \
    "$(bash_rc_of "$PRIMARY" "jq '.a > 1' .claude/settings.json")"
assert_rc "175 cat live settings 2>&1 | grep (fd dup, no write) allows" 0 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json 2>&1 | grep x")"
assert_rc "176 sed s///w (write flag) in a read-only pipe denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json | sed 's/a/b/w /tmp/x'")"
assert_rc "177 sed e command (executes) denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "sed -n '1e touch x' .claude/settings.json")"
assert_rc "178 LESSOPEN=...; less live settings denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "LESSOPEN='|touch x %s'; less .claude/settings.json")"
assert_rc "179 GIT_PAGER=...; git log live settings denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "GIT_PAGER=x; git log .claude/settings.json")"
assert_rc "180 cat live settings | tee denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json | tee /tmp/x")"
assert_rc "181 jq read with a real > redirect denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "jq '.a' .claude/settings.json > /tmp/out")"
assert_rc "182 cat live settings & (background separator) denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json & sed -i s/a/b/ x")" # gnu-ok: fixture text parsed by the hook, never executed
assert_rc "183 cat; (subshell write) denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json; (sed -i s/a/b/ .claude/settings.json)")" # gnu-ok: fixture text parsed by the hook, never executed
assert_rc "184 cat; X=\$(write) (command substitution) denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "cat .claude/settings.json; X=\$(sed -i s/a/b/ .claude/settings.json)")" # gnu-ok: fixture text parsed by the hook, never executed
assert_rc "185 X=v; less \$X (assigned value reaches a less word) denies (control)" 2 \
    "$(bash_rc_of "$PRIMARY" "X=+!touch; less \$X .claude/settings.json")"

# 186-190 (J1242 finding 1): the tokenizer path must stay bounded. A settings
# write padded to just under the tokenizer's byte cap made the hook fork per
# word and scan every word once per segment; past run-hook-with-bash.js's
# 15 s member timeout the runner SKIPPED it (exit 1, non-blocking) and the
# write went through. 186 is the judge's repro through the real runner, which
# must block (exit 2). 187-190 time the hook alone on the padded shapes: each
# must deny well inside the budget. HIMMEL-3546.
now_ms() { node -e 'process.stdout.write(String(Date.now()))'; }
rep() { local n=$1 out='' i=0; while [ "$i" -lt "$n" ]; do out=$out$2; i=$((i + 1)); done; printf '%s' "$out"; }
pad_to() { # pad_to PREFIX FILLER SUFFIX BYTES — PREFIX FILLER… SUFFIX, about BYTES long
    local n=$(( ($4 - ${#1} - ${#3}) / ${#2} ))
    printf '%s%s%s' "$1" "$(rep "$n" "$2")" "$3"
}
TIMING_BUDGET_MS=5000
if command -v node >/dev/null 2>&1; then
    RUNNER="$(dirname "$HOOK")/run-hook-with-bash.js"
    for sz in 8190 13600; do
        J_CMD=$(pad_to '' 'x=y; ' 'cp /tmp/evil ~/.claude/settings.json' "$sz")
        t0=$(now_ms)
        jq -n --arg cmd "$J_CMD" --arg cwd "$PRIMARY" \
            '{tool_name: "Bash", tool_input: {command: $cmd, cwd: $cwd}}' \
            | env HOME="$FAKEHOME" node "$RUNNER" --chain "$HOOK" >/dev/null 2>&1
        rc=$?
        echo "  186/$sz timing: ${#J_CMD} bytes through the runner, $(( $(now_ms) - t0 )) ms"
        assert_rc "186/$sz padded settings write through run-hook-with-bash --chain is blocked (J1242)" 2 "$rc"
    done
    timed_row() { # timed_row LABEL CMD — the hook alone must deny inside TIMING_BUDGET_MS
        local t0 rc ms
        t0=$(now_ms)
        rc=$(bash_rc_of "$PRIMARY" "$2" HOME="$FAKEHOME")
        ms=$(( $(now_ms) - t0 ))
        echo "  $1 timing: ${#2} bytes, ${ms} ms"
        assert_rc "$1 denies" 2 "$rc"
        if [ "$ms" -lt "$TIMING_BUDGET_MS" ]; then
            echo "PASS $1 within ${TIMING_BUDGET_MS} ms"
        else
            echo "FAIL $1 took ${ms} ms (budget ${TIMING_BUDGET_MS} ms)"
            FAILED=$((FAILED + 1))
        fi
    }
    # Each shape at just under the tokenizer's 8 KiB cap (the tokenized path)
    # and at 16 KiB (over the cap: the older text scan, which must deny too).
    for sz in 8190 16300; do
        timed_row "187/$sz x=y; padding then cp into live settings" \
            "$(pad_to '' 'x=y; ' 'cp /tmp/evil ~/.claude/settings.json' "$sz")"
        timed_row "188/$sz sed -i on live settings + word padding" \
            "$(pad_to 'sed -i s/a/b/ ~/.claude/settings.json ' 'a ' '' "$sz")" # gnu-ok: fixture text parsed by the hook, never executed
        timed_row "189/$sz cat | cat… | tee into live settings" \
            "$(pad_to 'cat ~/.claude/settings.json | ' 'cat | ' 'tee ~/.claude/settings.json' "$sz")"
        timed_row "190/$sz tar list segments then tar extract into .claude" \
            "$(pad_to '' 'tar -tf a.tar -C ~/.claude; ' 'tar -xf a.tar -C ~/.claude' "$sz")"
    done
else
    echo "SKIP 186-190 (node not installed)"
fi

# 191-196 (HIMMEL-3675): a literal `..` inside a benign `<base>..<head>` git
# SHA range must not be treated as directory traversal. Real-world trigger:
# /pr-check step 3.6's canonical `impacted-suites.sh --check <base>..<head>`
# submission, run from inside a linked worktree nested under the primary's
# `.claude/worktrees/<name>`, with a heredoc body listing impacted suites —
# one of which coincidentally contains a write-verb WORD ("install") as part
# of an unrelated filename (test-wizard-install-engine.sh). Two real SHAs
# from the sandbox's own history exercise a genuine-looking range.
SHA_BASE=$(git -C "$SANDBOX/primary" rev-parse HEAD)
git -C "$SANDBOX/primary" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
SHA_HEAD=$(git -C "$SANDBOX/primary" rev-parse HEAD)

HIMMEL_3675_CMD="bash \"$NESTED_WT/scripts/cr/impacted-suites.sh\" --check ${SHA_BASE}..${SHA_HEAD} <<'IMPACTED_EOF'
SUITE scripts/himmelctl/test/test-wizard-install-engine.sh reason
IMPACTED_EOF"

# 191: the exact N558/HIMMEL-3675 shape -> ALLOW (FAILS at base with a false
# DENY: the `..` in the SHA range voids the .claude/worktrees container-path
# strip, compounding with the heredoc body's coincidental "install" match).
assert_rc "191 impacted-suites --check <base>..<head> heredoc from a worktree allows" 0 \
    "$(bash_rc_of "$NESTED_WT" "$HIMMEL_3675_CMD")"

# 192: a plain worktree-relative script run, no heredoc -> ALLOW (already
# passed at base; kept alongside 191 as a non-regression guard).
assert_rc "192 no-heredoc worktree script run allows" 0 \
    "$(bash_rc_of "$NESTED_WT" "bash \"$NESTED_WT/scripts/foo.sh\"")"

# 193-196: controls that must stay DENY at base AND head — the 191/192 fix
# must never let a genuine write into the primary's live .claude/ through.
assert_rc "193 cp into primary settings.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "cp x \"$PRIMARY/.claude/settings.json\"")"
assert_rc "194 tee via worktrees/.. traversal into settings.local.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "tee \"$PRIMARY/.claude/worktrees/../settings.local.json\"")"
assert_rc "195 cp into primary settings.json (double slash) denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "cp x \"$PRIMARY/.claude//settings.json\"")"
assert_rc "196 mv into primary .claude dir denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "mv x \"$PRIMARY/.claude/\"")"

# 197-204 (HIMMEL-3675 judge J1313O NO-GO): has_traversal_dots previously
# required a non-name character on BOTH sides of a literal `..`, so a `..`
# glued to a short option (`-t..`, `-d..`, `-sft..` — a letter immediately to
# its left) was never counted as traversal, letting these writes through to
# a real live settings.json/dir undetected. Two more worktree fixtures:
# HOMEWT sits directly under a fake $HOME, WTDIRECT directly under the
# primary itself (neither nested under .claude/worktrees/). Every row below
# must DENY at head.
git -C "$SANDBOX/primary" worktree add -q "$FAKEHOME/wt" -b feat/homewt >/dev/null 2>&1 || {
    echo "FATAL: could not create the homewt worktree fixture" >&2
    exit 1
}
git -C "$SANDBOX/primary" worktree add -q "$PRIMARY/wtdirect" -b feat/wtdirect >/dev/null 2>&1 || {
    echo "FATAL: could not create the wtdirect worktree fixture" >&2
    exit 1
}
HOMEWT="$FAKEHOME/wt"
WTDIRECT="$PRIMARY/wtdirect"

assert_rc "197 cp -t glued traversal from sibling worktree denies" 2 \
    "$(bash_rc_of "$WT2" "cp -t../primary/.claude settings.json")"
assert_rc "198 cp src -t glued traversal from sibling worktree denies" 2 \
    "$(bash_rc_of "$WT2" "cp settings.json -t../primary/.claude")"
assert_rc "199 mv -t glued traversal from sibling worktree denies" 2 \
    "$(bash_rc_of "$WT2" "mv -t../primary/.claude settings.local.json")"
assert_rc "200 install -t glued traversal from sibling worktree denies" 2 \
    "$(bash_rc_of "$WT2" "install -t../primary/.claude settings.json")"
assert_rc "201 unzip -od glued traversal from sibling worktree denies" 2 \
    "$(bash_rc_of "$WT2" "unzip -od../primary/.claude a.zip")"
assert_rc "202 ln -sft glued traversal from sibling worktree denies" 2 \
    "$(bash_rc_of "$WT2" "ln -sft../primary/.claude /tmp/evil/settings.json")"
assert_rc "203 cp -t glued traversal from a worktree under HOME denies" 2 \
    "$(bash_rc_of "$HOMEWT" "cp -t../.claude settings.json" HOME="$FAKEHOME")"
assert_rc "204 cp -t glued traversal from a worktree directly under primary denies" 2 \
    "$(bash_rc_of "$WTDIRECT" "cp -t../.claude settings.json")"

# 205-211 (HIMMEL-3686, J1313O "Out of scope, noted" follow-ups): a relative
# dir-dest climb, a brace-hidden traversal, and a write through a
# pre-existing symlink all ALLOWed at base (#1313/HIMMEL-3675 left these
# three untouched) and must DENY now.

# 205: `cp -r x/. ../..` from the nested worktree climbs LEXICALLY all the
# way back to the primary's own .claude/ itself — no literal ".claude" or
# "settings" in the text at all, so rule 1/2 never fired at base.
assert_rc "205 cp -r x/. ../.. from nested worktree denies (dir-dest climb)" 2 \
    "$(bash_rc_of "$NESTED_WT" "cp -r x/. ../..")"

# 206 (control): the SAME shape but landing on a SIBLING inside worktrees/
# (../other, not ../..) must stay ALLOW — this is a worktree writing to
# another worktree's own container, not a climb into the primary.
assert_rc "206 cp -r x/. ../other stays inside worktrees/ allows" 0 \
    "$(bash_rc_of "$NESTED_WT" "cp -r x/. ../other")"

# 207 (control): an ordinary same-directory copy inside the worktree, no
# ".." anywhere, must stay ALLOW.
assert_rc "207 cp a b inside worktree allows" 0 \
    "$(bash_rc_of "$NESTED_WT" "cp a b")"

# 208: `tee .{,.}/.{,.}/settings.json` from the nested worktree hides
# `../../settings.json` inside an unexpanded brace group — no literal ".."
# in the text, so has_traversal_dots never fired at base.
assert_rc "208 tee brace-hidden traversal from nested worktree denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "tee .{,.}/.{,.}/settings.json")"

# 209 (control): a brace group with no .claude/settings mention, outside a
# nested worktree, and mkdir isn't in the write-verb list either way —
# must stay ALLOW, unchanged from base.
assert_rc "209 mkdir -p src/{a,b} outside a worktree allows" 0 \
    "$(bash_rc_of "$PRIMARY" "mkdir -p src/{a,b}")"

# 210: a pre-existing symlink at <primary>/.claude/worktrees/x/s resolving
# to the primary's own live settings.json — the destination operand names
# neither "settings.json" nor ".claude" as a container-relative mention
# that survives the worktrees/ strip, so this was a text-only hook's blind
# spot. Built in the scratch SANDBOX only.
mkdir -p "$PRIMARY/.claude/worktrees/x"
ln -s "$PRIMARY/.claude/settings.json" "$PRIMARY/.claude/worktrees/x/s"
assert_rc "210 cp y through a pre-existing symlink to live settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "cp y \"$PRIMARY/.claude/worktrees/x/s\"")"

# 211 (control): writing through an ordinary (non-symlink) worktree file
# that merely happens to exist on disk must stay ALLOW.
printf 'plain\n' > "$PRIMARY/.claude/worktrees/x/plain"
assert_rc "211 cp y into an ordinary existing worktree file allows" 0 \
    "$(bash_rc_of "$WT2" "cp y \"$PRIMARY/.claude/worktrees/x/plain\"")"

# 212: same pre-existing-symlink shape as 210, but the symlink's own path
# contains a space and the command text quotes it. Splitting the
# quote-stripped command on whitespace (the pre-fix implementation) breaks
# the one destination word into two, neither of which names the real
# symlink — a real bypass the codex critic panel caught on this ticket.
ln -s "$PRIMARY/.claude/settings.json" "$PRIMARY/.claude/worktrees/x/s ymlink"
assert_rc "212 cp y through a quoted pre-existing symlink with a space denies" 2 \
    "$(bash_rc_of "$WT2" "cp y \"$PRIMARY/.claude/worktrees/x/s ymlink\"")"

# 213: same shape as 210/212, but the symlink sits on a PARENT DIRECTORY
# rather than being the final destination itself, and the leaf name
# (settings.local.json) does not exist ANYWHERE on disk yet — a genuinely
# new destination, reached through a pre-existing symlinked dir that
# escapes worktrees/ confinement into the primary's own .claude/, with
# neither ".." nor ".claude" anywhere in the command text (codex-2 round-2
# panel finding on this ticket: canon()'s realpath-m/resolve(strict=False)
# already follow symlinks in every EXISTING path component even when the
# final leaf is missing, so gating check_target on the full path's own
# existence — rather than its parent's — missed this).
ln -s "$PRIMARY/.claude" "$NESTED_WT/escape"
assert_rc "213 cp y through a symlinked PARENT dir to a not-yet-existing settings.local.json denies" 2 \
    "$(bash_rc_of "$NESTED_WT" "cp y escape/settings.local.json")"

# 214 (control): the SAME symlinked-parent-dir shape, but the symlink
# target stays INSIDE worktrees/ (a sibling worktree's own container) and
# the leaf name is not a live-settings filename — must stay ALLOW.
mkdir -p "$PRIMARY/.claude/worktrees/sibling"
ln -s "$PRIMARY/.claude/worktrees/sibling" "$NESTED_WT/escape-inside"
assert_rc "214 cp y through a symlinked parent dir staying inside worktrees/ allows" 0 \
    "$(bash_rc_of "$NESTED_WT" "cp y escape-inside/notes.json")"

# 215: a DANGLING symlink — the operand itself is a symlink whose target
# (a live settings.json) does not exist yet — through a separate primary-like
# repo that has never had a settings.json created. `-e` follows symlinks and
# reports false for a dangling one, so the pre-fix code's `[ -e "$wabs" ]`
# gate skipped check_target entirely; the symlink's own name ("dangle-link")
# is not itself a settings-named leaf, so round-2's parent-existence pre
# filter does not catch it either (round-3 codex-1 panel finding).
DANGLE_PRIMARY="$SANDBOX/dangle-primary"
mkrepo "$DANGLE_PRIMARY"
mkdir -p "$DANGLE_PRIMARY/.claude"
ln -s "$DANGLE_PRIMARY/.claude/settings.json" "$WT2/dangle-link"
assert_rc "215 cp y through a dangling symlink to a not-yet-existing settings.json denies" 2 \
    "$(bash_rc_of "$WT2" "cp y dangle-link")"

# 216 (control): the same dangling-symlink shape, but the target's parent
# is not a live .claude at all — must stay ALLOW.
ln -s "$DANGLE_PRIMARY/notes/plan.json" "$WT2/dangle-link-safe"
assert_rc "216 cp y through a dangling symlink to a non-settings path allows" 0 \
    "$(bash_rc_of "$WT2" "cp y dangle-link-safe")"

# 217: HIMMEL-3686 round-5 codex-3 — lex_resolve's `for part in $joined`
# word-split (with IFS=/) is also subject to bash's default pathname (glob)
# expansion, which runs against the HOOK SUBPROCESS'S OWN real cwd —
# unrelated to either BASE or the path being resolved — so a write-
# destination operand containing a glob metacharacter (a legal filename
# character) could silently resolve differently depending on what files
# happen to exist wherever the hook process is invoked from. Force the real
# process cwd to a scratch dir seeded with files that WOULD match the
# operand's glob segment if pathname expansion fired, then confirm
# lex_resolve still returns the untouched literal text.
GLOBTRAP="$SANDBOX/glob-trap-real-cwd"
mkdir -p "$GLOBTRAP/a"
touch "$GLOBTRAP/a/one" "$GLOBTRAP/a/two"
LEX_RESOLVE_SRC="$SANDBOX/lex_resolve_extract.sh"
sed -n '/^lex_resolve() {/,/^}/p' "$HOOK" > "$LEX_RESOLVE_SRC"
LEX_OUT=$(cd "$GLOBTRAP" && bash -c '
    source "$1"
    lex_resolve "/x/y" "../a/*"
' _ "$LEX_RESOLVE_SRC")
if [ "$LEX_OUT" = "/x/a/*" ]; then
    echo "PASS 217 lex_resolve leaves a glob-metacharacter segment untouched regardless of files in the hook process's real cwd (got $LEX_OUT)"
else
    echo "FAIL 217 lex_resolve leaves a glob-metacharacter segment untouched regardless of files in the hook process's real cwd — expected /x/a/*, got $LEX_OUT"
    FAILED=$((FAILED + 1))
fi

# 218: HIMMEL-3686 CodeRabbit (round-6) — the TOK=0 fallback's own
# `for w in $cmd_n; do _check_write_operand "$w"; done` (used whenever the
# tokenizer can't fully vouch for the command text, e.g. a heredoc is
# present) is UNQUOTED, so it is also subject to pathname (glob) expansion
# against the HOOK SUBPROCESS'S OWN real cwd — unrelated to tool_input.cwd.
# A write-destination operand containing a glob metacharacter can therefore
# be silently replaced depending on what files happen to exist wherever the
# hook process is launched from. Build a real symlink into a live settings
# file at a fixed relative path inside a worktree, then run the SAME
# heredoc-bearing (TOK=0) command with that symlink addressed via a glob
# operand from two different real launch cwds: one with no matching decoy,
# one with a same-named decoy that makes the glob expand successfully. The
# verdict must be identical in both cases.
mkdir -p "$WT2/wtlink"
ln -s "$PRIMARY/.claude/settings.json" "$WT2/wtlink/s"
TOK0_GLOB_CMD='cat <<HEREDOC_BODY
x
HEREDOC_BODY
cp y wtlink/*'
TOK0_GLOB_JSON=$(jq -n --arg cmd "$TOK0_GLOB_CMD" --arg cwd "$WT2" \
    '{tool_name: "Bash", tool_input: {command: $cmd, cwd: $cwd}}')
TRAP_EMPTY="$SANDBOX/tok0-glob-trap-empty"
mkdir -p "$TRAP_EMPTY"
TRAP_MATCH="$SANDBOX/tok0-glob-trap-match"
mkdir -p "$TRAP_MATCH/wtlink"
touch "$TRAP_MATCH/wtlink/s"
RC_TRAP_EMPTY=$(cd "$TRAP_EMPTY" && printf '%s' "$TOK0_GLOB_JSON" | bash "$HOOK" >/dev/null 2>&1; echo $?)
RC_TRAP_MATCH=$(cd "$TRAP_MATCH" && printf '%s' "$TOK0_GLOB_JSON" | bash "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$RC_TRAP_EMPTY" = "$RC_TRAP_MATCH" ]; then
    echo "PASS 218 TOK=0 fallback's glob write operand gives the same verdict regardless of a same-named decoy in the hook process's real cwd (rc=$RC_TRAP_EMPTY both)"
else
    echo "FAIL 218 TOK=0 fallback's glob write operand verdict depends on the hook process's real cwd contents — got rc=$RC_TRAP_EMPTY with no decoy, rc=$RC_TRAP_MATCH with a same-named decoy present (should be identical)"
    FAILED=$((FAILED + 1))
fi

# Clean up worktree registrations before removing the sandbox (avoids
# dangling `git worktree` admin records under SANDBOX/primary).
git -C "$SANDBOX/primary" worktree remove --force "$SANDBOX/primary/.claude/worktrees/feat+x" 2>/dev/null || true
git -C "$SANDBOX/primary" worktree remove --force "$WT2" 2>/dev/null || true
git -C "$SANDBOX/primary" worktree remove --force "$SANDBOX/prim" 2>/dev/null || true
git -C "$SANDBOX/primary" worktree remove --force "$HOMEWT" 2>/dev/null || true
git -C "$SANDBOX/primary" worktree remove --force "$WTDIRECT" 2>/dev/null || true
rm -rf "$SANDBOX" 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
