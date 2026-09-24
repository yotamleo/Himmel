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
assert_rc "70 accepted false deny: harmless cd + worktree settings write denies" 2 \
    "$(bash_rc_of "$WT2" "cd . && echo x > .claude/settings.json")"
assert_rc "71 accepted false deny: cat >> other file with settings.json in heredoc prose denies" 2 \
    "$(bash_rc_of "$PRIMARY" "cat >> /tmp/doc.md <<'EOF'
- avoided .claude/settings.json
EOF")"
assert_rc "72 piped grep naming settings.json from primary allows (HIMMEL-3546; was an accepted false deny)" 0 \
    "$(bash_rc_of "$PRIMARY" "grep -rl x scripts .claude/settings.json docs | head")"

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

# Clean up worktree registrations before removing the sandbox (avoids
# dangling `git worktree` admin records under SANDBOX/primary).
git -C "$SANDBOX/primary" worktree remove --force "$SANDBOX/primary/.claude/worktrees/feat+x" 2>/dev/null || true
git -C "$SANDBOX/primary" worktree remove --force "$WT2" 2>/dev/null || true
git -C "$SANDBOX/primary" worktree remove --force "$SANDBOX/prim" 2>/dev/null || true
rm -rf "$SANDBOX" 2>/dev/null || true

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
