#!/usr/bin/env bash
# shellcheck disable=SC2016  # the bash -c bodies expand in the child, on purpose
# HIMMEL-3415: uninstall.sh's RUNTIME real-home refusal — a fence-lifted
# (HIMMEL_UNINSTALL_REAL_HOME=1) wet run whose $HOME claims to be scratch but
# RESOLVES into the real home (a symlink portal, a nested .claude portal, an
# override target aimed into the real .claude) is refused rc=3 before any step.
#
# NO row here resolves, links to or runs against the operator's real home. The
# "real home" every portal points at is a FAKE under this suite's $TMP, named
# to uninstall.sh through the additive HIMMEL_UNINSTALL_TEST_REAL_HOME seam
# (it ADDS a protected home; the passwd home stays protected regardless). Each
# refusal row asserts the fake's sentinels survive.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CLI="$HERE/uninstall.sh"
FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-realhome.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

REAL_HOME="$HOME"
case "$REAL_HOME" in
    "$TMP"|"$TMP"/*) echo "FAIL the operator's real \$HOME resolved under this suite's \$TMP — refusing to proceed"; exit 1 ;;
esac
unset HIMMEL_UNINSTALL_REAL_HOME HIMMEL_UNINSTALL_TEST_REAL_HOME \
    TELEGRAM_CHANNEL_DIR BRIDGE_ROOT HIMMEL_USER_SETTINGS HIMMELCTL_CACHE_DIR \
    HIMMEL_PROVENANCE_DIR HIMMELCTL_SYSTEMD_USER_UNIT_DIR
export HOME="$TMP/suitehome"
mkdir -p "$HOME" "$TMP/cwd"

# shellcheck disable=SC2317,SC2329  # invoked indirectly by link_hermetic_tool
fail() { echo "FAIL $*"; FAILED=$((FAILED + 1)); }
pass() { echo "PASS $*"; }
HBIN="$TMP/hbin"
mkdir -p "$HBIN"
# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$HERE/lib/hermetic-path.sh"
for _t in bash env sed grep awk tr sort head tail cut wc cat ls rm cp mv ln mkdir chmod \
          basename dirname readlink mktemp uname date id find xargs jq node; do
    link_hermetic_tool "$_t" "$HBIN"
done
# shellcheck source=lib/host-caps.sh
# shellcheck disable=SC1091
. "$HERE/lib/host-caps.sh"
if ! host_isolated_bash_boots; then
    host_skip "uninstall.sh cases need a bash that starts under the hermetic PATH"
    exit 0
fi

# mk_fake <dir> — a fake "real home" carrying sentinels in every place a wet
# uninstall would remove (the cache, state dirs) or rewrite (settings).
mk_fake() {
    mkdir -p "$1/.claude/himmel" "$1/.claude/channels/telegram" "$1/.claude/handover/bridge" "$1/.himmel"
    printf 'sentinel\n' > "$1/.claude/himmel/sentinel"
    printf 'sentinel\n' > "$1/.claude/channels/telegram/sentinel"
    printf 'sentinel\n' > "$1/.claude/handover/bridge/sentinel"
    printf '{"sentinel":true}\n' > "$1/.claude/settings.json"
    printf 'sentinel\n' > "$1/.himmel/sentinel"
}
fake_intact() {
    [ -f "$1/.claude/himmel/sentinel" ] && [ -f "$1/.claude/channels/telegram/sentinel" ] \
        && [ -f "$1/.claude/handover/bridge/sentinel" ] && [ -f "$1/.himmel/sentinel" ] \
        && grep -q sentinel "$1/.claude/settings.json"
}
FAKE="$TMP/fakereal"
mk_fake "$FAKE"

FLAGS=(--purge-state --yes --skip-tasks --skip-plugins --skip-hooks)
# (scratch HOME prefix) run_wet [VAR=val ...] — a fence-lifted wet run against the
# HOME given on the call (always a literal "$TMP/..." spelling, so the static
# caller guard scripts/test-uninstall-real-home-callers.sh can trace it), cwd in scratch, the
# seam naming $FAKE. Output in $out, rc in $rc.
run_wet() {
    out=$(cd "$TMP/cwd" && env PATH="$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
        HIMMEL_UNINSTALL_TEST_REAL_HOME="$FAKE" "$@" \
        bash "$CLI" "${FLAGS[@]}" </dev/null 2>&1); rc=$?
}
expect_refused() {  # <label> <check-name> [fake real home, default $FAKE]
    local _f="${3:-$FAKE}"
    if [ "$rc" -eq 3 ]; then pass "$1: rc=3"; else fail "$1: expected rc=3, got $rc — $out"; fi
    case "$out" in
        *"real-home check ($2)"*) pass "$1: names check ($2)" ;;
        *) fail "$1: stderr does not name check ($2) — $out" ;;
    esac
    case "$out" in *"Uninstall complete."*) fail "$1: claimed completion" ;; esac
    if fake_intact "$_f"; then pass "$1: fake real home untouched"; else fail "$1: fake real home was modified"; mk_fake "$_f"; fi
}
# mk_scratch <dir> — a genuine scratch HOME carrying a himmel cache to remove.
mk_scratch() { rm -rf "$1"; mkdir -p "$1/.claude/himmel"; printf 'x\n' > "$1/.claude/himmel/install-profile.json"; }

# (a) portal: $HOME is a symlink to the real home.
mkdir -p "$TMP/a"
ln -s "$FAKE" "$TMP/a/home"
HOME="$TMP/a/home" run_wet
expect_refused "(a) HOME symlink portal" a

# (a2) another spelling of the real home itself is NOT the lexical
# pass-through (only trailing slashes are trimmed) and resolves into it.
HOME="$FAKE/." run_wet
expect_refused "(a2) \$R/. spelling for HOME" a
HOME="$TMP/./fakereal" run_wet
expect_refused "(a3) \$TMP/./fakereal spelling for HOME" a

# (b) nested portal: $HOME is scratch, $HOME/.claude links to the real .claude.
mkdir -p "$TMP/b/home"
ln -s "$FAKE/.claude" "$TMP/b/home/.claude"
HOME="$TMP/b/home" run_wet
expect_refused "(b) nested .claude portal" b

# (c) an override target aimed into the real .claude with a scratch HOME.
mkdir -p "$TMP/c/home"
HOME="$TMP/c/home" run_wet HIMMELCTL_CACHE_DIR="$FAKE/.claude/himmel"
expect_refused "(c) HIMMELCTL_CACHE_DIR override into the real .claude" c
HOME="$TMP/c/home" run_wet HIMMEL_PROVENANCE_DIR="$FAKE/.himmel"
expect_refused "(c2) HIMMEL_PROVENANCE_DIR override into the real home" c

# (c3) a deeper portal: a real scratch .claude whose himmel/ links to the real one.
mkdir -p "$TMP/c3/home/.claude"
ln -s "$FAKE/.claude/himmel" "$TMP/c3/home/.claude/himmel"
HOME="$TMP/c3/home" run_wet
expect_refused "(c3) \$HOME/.claude/himmel portal" c

# (c4) $HOME is an ANCESTOR of the real home: an override target inside the
# real .claude is also under $HOME, which must not exempt it.
HOME="$TMP" run_wet HIMMELCTL_CACHE_DIR="$FAKE/.claude/himmel"
expect_refused "(c4) HOME an ancestor of the real home, override into the real .claude" c

# (b2)/(c5) the real home's own .claude and .himmel are symlinks OUT of it
# (a dotfiles layout): a scratch HOME whose .claude or .himmel points at the
# same physical directory is refused although nothing resolves under $FAKE3.
mk_fake "$TMP/ext3"
FAKE3="$TMP/fake3"
mkdir -p "$FAKE3"
ln -s "$TMP/ext3/.claude" "$FAKE3/.claude"
ln -s "$TMP/ext3/.himmel" "$FAKE3/.himmel"
mkdir -p "$TMP/b2/home"
ln -s "$TMP/ext3/.claude" "$TMP/b2/home/.claude"
HOME="$TMP/b2/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$FAKE3"
expect_refused "(b2) scratch .claude links to the real .claude's physical dir" b "$FAKE3"
mkdir -p "$TMP/c5/home/.claude"
ln -s "$TMP/ext3/.himmel" "$TMP/c5/home/.himmel"
HOME="$TMP/c5/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$FAKE3"
expect_refused "(c5) scratch .himmel links to the real .himmel's physical dir" c "$FAKE3"

# (c6)-(c9) targets that do not derive from $HOME: repo-rooted rows (the hooks
# dir, project settings), an absolute manifest path, and a core.hooksPath —
# each aimed into the fake real home while $HOME is a genuine scratch dir.
mkdir -p "$FAKE/repo/.git/hooks" "$FAKE/repo/.claude"
printf 'sentinel\n' > "$FAKE/repo/.git/hooks/pre-commit"
printf '{"sentinel":true}\n' > "$FAKE/repo/.claude/settings.json"
repo_intact() { [ -f "$FAKE/repo/.git/hooks/pre-commit" ] && grep -q sentinel "$FAKE/repo/.claude/settings.json"; }
mk_scratch "$TMP/c6/home"
HOME="$TMP/c6/home" run_wet HIMMEL_UNINSTALL_REPO_ROOT="$FAKE/repo"
expect_refused "(c6) HIMMEL_UNINSTALL_REPO_ROOT inside the real home" c
if repo_intact; then pass "(c6) real-home repo untouched"; else fail "(c6) real-home repo was modified"; fi
mk_scratch "$TMP/c7/home"
out=$(cd "$FAKE/repo" && env HOME="$TMP/c7/home" PATH="$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
    HIMMEL_UNINSTALL_TEST_REAL_HOME="$FAKE" bash "$CLI" "${FLAGS[@]}" </dev/null 2>&1); rc=$?
expect_refused "(c7) cwd is a repo inside the real home" c
if repo_intact; then pass "(c7) real-home repo untouched"; else fail "(c7) real-home repo was modified"; fi
awk -F'\t' -v OFS='\t' -v p="$FAKE/.claude/himmel" '$1=="himmelctl-cache"{$6=p}1' \
    "$HERE/install/uninstall-manifest.tsv" > "$TMP/c8-manifest.tsv"
mk_scratch "$TMP/c8/home"
HOME="$TMP/c8/home" run_wet HIMMEL_UNINSTALL_MANIFEST="$TMP/c8-manifest.tsv"
expect_refused "(c8) absolute manifest row inside the real home" c
if command -v git >/dev/null 2>&1; then
    GBIN="$TMP/gbin"
    mkdir -p "$GBIN" "$FAKE/hooks" "$TMP/c9/repo"
    link_hermetic_tool git "$GBIN"
    printf 'sentinel\n' > "$FAKE/hooks/pre-commit"
    git -C "$TMP/c9/repo" init -q && git -C "$TMP/c9/repo" config core.hooksPath "$FAKE/hooks"
    mk_scratch "$TMP/c9/home"
    HOME="$TMP/c9/home" run_wet HIMMEL_UNINSTALL_REPO_ROOT="$TMP/c9/repo" PATH="$GBIN:$HBIN"
    expect_refused "(c9) core.hooksPath inside the real home" c
    if [ -f "$FAKE/hooks/pre-commit" ]; then pass "(c9) real-home hooks dir untouched"; else fail "(c9) real-home hooks dir was modified"; fi
else
    pass "(c9) skipped: no git on this host"
fi

# (a4) $HOME is a symlink into a SUBDIRECTORY of the real home: physical and
# lexical HOME differ and the physical one is inside a protected root. (A
# lexical HOME under the real home is a scratch dir by design and passes.)
mkdir -p "$FAKE/Documents/.claude/himmel" "$TMP/a4"
printf 'sentinel\n' > "$FAKE/Documents/.claude/himmel/sentinel"
ln -s "$FAKE/Documents" "$TMP/a4/home"
HOME="$TMP/a4/home" run_wet
expect_refused "(a4) HOME symlinks into a real-home subdirectory" a
if [ -f "$FAKE/Documents/.claude/himmel/sentinel" ]; then pass "(a4) real-home subdirectory untouched"; else fail "(a4) real-home subdirectory was modified"; fi

# (d) HOME unset / empty lives in scripts/test-uninstall-ux.sh: that check
# fires before the fence, and a file that drops HOME may not lift the fence
# (the static caller guard, scripts/test-uninstall-real-home-callers.sh).

# (s) the seam cannot disable or widen the check. Empty = only the passwd home
# is protected, so a genuine scratch HOME proceeds as today. `/` protects the
# root: an override target outside $HOME is refused (check c), a
# self-contained scratch HOME still proceeds, and the passwd home stays listed.
mk_scratch "$TMP/s/home"
out=$(cd "$TMP/cwd" && env HOME="$TMP/s/home" PATH="$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
    HIMMEL_UNINSTALL_TEST_REAL_HOME= bash "$CLI" "${FLAGS[@]}" </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/s/home/.claude/himmel" ]; then
    pass "(s) empty seam: a genuine scratch HOME proceeds as today"
else
    fail "(s) empty seam: expected rc=0 + cache removed, got rc=$rc — $out"
fi
mk_scratch "$TMP/s/home"
mkdir -p "$TMP/s/outside-cache"
out=$(cd "$TMP/cwd" && env HOME="$TMP/s/home" PATH="$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
    HIMMEL_UNINSTALL_TEST_REAL_HOME=/ HIMMELCTL_CACHE_DIR="$TMP/s/outside-cache" \
    bash "$CLI" "${FLAGS[@]}" </dev/null 2>&1); rc=$?
if [ "$rc" -eq 3 ] && [ -e "$TMP/s/home/.claude/himmel" ] && [ -d "$TMP/s/outside-cache" ]; then
    pass "(s2) seam=/ refuses an override target outside \$HOME (check c), removes nothing"
else
    fail "(s2) seam=/ + outside override: expected rc=3 + nothing removed, got rc=$rc — $out"
fi
# Self-contained includes the cwd: its repo-rooted targets (hooks dir, project
# settings) sit outside $HOME otherwise, and seam=/ refuses those (check c).
out=$(cd "$TMP/s/home" && env HOME="$TMP/s/home" PATH="$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
    HIMMEL_UNINSTALL_TEST_REAL_HOME=/ bash "$CLI" "${FLAGS[@]}" </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/s/home/.claude/himmel" ]; then
    pass "(s3) seam=/ does not disable anything: a self-contained scratch HOME proceeds"
else
    fail "(s3) seam=/ + self-contained scratch HOME: expected rc=0, got rc=$rc — $out"
fi
for _seam in "" "/"; do
    _pw=$(env HOME="$TMP/suitehome" PATH="$HBIN" bash -c '. "$1" --source-only && real_home_resolve' _ "$CLI" 2>&1)
    _rh=$(env HOME="$TMP/suitehome" PATH="$HBIN" HIMMEL_UNINSTALL_TEST_REAL_HOME="$_seam" bash -c \
        '. "$1" --source-only && real_home_protected_homes' _ "$CLI" 2>&1)
    if [ -n "$_pw" ] && grep -qxF "$_pw" <<< "$_rh"; then
        pass "(s4) seam='$_seam' keeps the passwd home protected"
    else
        fail "(s4) seam='$_seam' dropped the passwd home '$_pw' — $_rh"
    fi
done

# (e) control: a genuine scratch HOME with the fence lifted proceeds exactly
# as today — rc=0, its cache removed, the fake untouched.
mk_scratch "$TMP/e/home"
HOME="$TMP/e/home" run_wet
if [ "$rc" -eq 0 ]; then pass "(e) scratch HOME control: rc=0"; else fail "(e) scratch HOME control: expected rc=0, got $rc — $out"; fi
if [ -e "$TMP/e/home/.claude/himmel" ]; then fail "(e) scratch cache survived"; else pass "(e) scratch cache removed"; fi
if fake_intact "$FAKE"; then pass "(e) fake real home untouched"; else fail "(e) fake real home was modified"; fi

# (f) control: a HOME that IS the protected home, spelled exactly (a declared
# real-home run — the operator's shell, the wizard's spawn) passes through to
# the existing fence unchanged.
FAKE2="$TMP/fakereal2"
mk_fake "$FAKE2"
out=$(cd "$TMP/cwd" && env HOME="$FAKE2" PATH="$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
    HIMMEL_UNINSTALL_TEST_REAL_HOME="$FAKE2" bash "$CLI" "${FLAGS[@]}" </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$FAKE2/.claude/himmel" ]; then
    pass "(f) declared run (HOME is $FAKE2) passes through (rc=0, cache removed)"
else
    fail "(f) declared run (HOME is $FAKE2): expected rc=0 + cache removed, got rc=$rc — $out"
fi

# (r) the resolver: sourced, it finds the passwd home without $HOME and keeps
# it protected even when the seam is set. Read-only: prints paths, runs nothing.
_rh=$(env HOME="$TMP/suitehome" PATH="$HBIN" HIMMEL_UNINSTALL_TEST_REAL_HOME="$FAKE" bash -c \
    '. "$1" --source-only && real_home_protected_homes' _ "$CLI" 2>&1)
case "$_rh" in
    *"$FAKE"*) pass "(r) seam home is listed as protected" ;;
    *) fail "(r) seam home missing from protected homes — $_rh" ;;
esac
_pw=$(env HOME="$TMP/suitehome" PATH="$HBIN" bash -c '. "$1" --source-only && real_home_resolve' _ "$CLI" 2>&1)
if [ -n "$_pw" ] && [ "$_pw" != "$TMP/suitehome" ] && grep -qxF "$_pw" <<< "$_rh"; then
    pass "(r) passwd home resolved independently of \$HOME and still protected with the seam set"
else
    fail "(r) passwd home '$_pw' not resolved, taken from \$HOME, or dropped when the seam is set — $_rh"
fi

# (u) an unresolvable passwd home fails CLOSED. A stub `id` ahead of $HBIN
# (which has no getent/dscl fallback) answers (u1) a name outside
# [A-Za-z0-9._-] carrying a command substitution whose body is a builtin redirect
# (no PATH lookup, so it would fire if evaluated) — refused, never eval'd —
# (u2) an unknown user, whose `~name` stays literal — unresolved — and (u3) an
# all-digit name, which must never reach the `~` expansion.
UBIN="$TMP/ubin"
mkdir -p "$UBIN" "$TMP/u/home"
for _case in u1 u2 u3; do
    case "$_case" in
        u1) _name="x\$(: >$TMP/pwned)" ;;
        u2) _name="himmel_no_such_user_3415" ;;
        *) _name="0" ;;  # all digits: ~0 would expand from the dirstack ($PWD)
    esac
    printf '%s\n' "$_name" > "$UBIN/id.name"
    cat > "$UBIN/id" <<EOF
#!/bin/sh
case "\$1" in -un) cat "$UBIN/id.name" ;; -u) echo 4294967294 ;; *) echo 0 ;; esac
EOF
    chmod +x "$UBIN/id"
    _r=$(env HOME="$TMP/u/home" PATH="$UBIN:$HBIN" bash -c '. "$1" --source-only && real_home_resolve' _ "$CLI" 2>/dev/null); _rrc=$?
    if [ "$_rrc" -ne 0 ] && [ -z "$_r" ]; then pass "($_case) resolver reports unresolved"; else fail "($_case) resolver returned rc=$_rrc '$_r'"; fi
    out=$(cd "$TMP/cwd" && env HOME="$TMP/u/home" PATH="$UBIN:$HBIN" HIMMEL_UNINSTALL_REAL_HOME=1 \
        bash "$CLI" "${FLAGS[@]}" </dev/null 2>&1); rc=$?
    expect_refused "($_case) unresolvable passwd home" unresolved
done
if [ -e "$TMP/pwned" ]; then fail "(u1) the id -un answer was evaluated"; else pass "(u1) the id -un answer was never evaluated"; fi

if [ "$FAILED" -gt 0 ]; then echo "FAILED: $FAILED"; exit 1; fi
echo "ALL PASS"
