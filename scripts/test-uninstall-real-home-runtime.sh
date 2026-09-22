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

# (c10) a DEEPER symlink out of the real home: the real .claude/himmel links
# to an external dir, and a scratch HOME's own .claude/himmel links there too.
mk_fake "$TMP/fake10"
mkdir -p "$TMP/ext10"
mv "$TMP/fake10/.claude/himmel" "$TMP/ext10/himmel"
ln -s "$TMP/ext10/himmel" "$TMP/fake10/.claude/himmel"
mkdir -p "$TMP/c10/home/.claude"
ln -s "$TMP/ext10/himmel" "$TMP/c10/home/.claude/himmel"
HOME="$TMP/c10/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/fake10"
expect_refused "(c10) scratch .claude/himmel links to the real .claude/himmel's external dir" c "$TMP/fake10"

# (c11) the same, one level up and with the row's leaf ABSENT at the real home:
# the real .claude/channels links out and has no telegram/ under it, so the
# deepest EXISTING ancestor is what is protected — a scratch telegram/ linked
# to a sibling inside that external dir is refused.
mk_fake "$TMP/fake11"
mkdir -p "$TMP/ext11/channels/tg2"
printf 'sentinel\n' > "$TMP/ext11/channels/tg2/sentinel"
rm -rf "$TMP/fake11/.claude/channels"
ln -s "$TMP/ext11/channels" "$TMP/fake11/.claude/channels"
mkdir -p "$TMP/c11/home/.claude/channels"
ln -s "$TMP/ext11/channels/tg2" "$TMP/c11/home/.claude/channels/telegram"
HOME="$TMP/c11/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/fake11"
expect_refused "(c11) absent real-home leaf under a linked-out ancestor" c "$FAKE"
if [ -f "$TMP/ext11/channels/tg2/sentinel" ]; then pass "(c11) external dir untouched"; else fail "(c11) external dir was modified"; fi

# (c12)/(c13) an override target that CONTAINS the real home: a recursive
# removal of an ancestor would take the whole real home with it. Each fake
# real home sits alone in its own ancestor dir, so a RED run destroys only it.
mk_fake "$TMP/anc12/real"
mkdir -p "$TMP/c12/home"
HOME="$TMP/c12/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/anc12/real" TELEGRAM_CHANNEL_DIR="$TMP/anc12"
expect_refused "(c12) TELEGRAM_CHANNEL_DIR override is an ancestor of the real home" c "$TMP/anc12/real"
mk_fake "$TMP/anc13/real"
HOME="$TMP/c12/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/anc13/real" HIMMELCTL_CACHE_DIR="$TMP/anc13"
expect_refused "(c13) HIMMELCTL_CACHE_DIR override is an ancestor of the real home" c "$TMP/anc13/real"

# (d1)-(d6) an override SPELLED with a `.`/`..` segment, or relative, is
# refused outright: a `..` behind a component missing at check time (one
# uninstall itself creates later) resolves somewhere else by the time step
# [8/8] removes it. Each fake sits alone in its own dir.
# d1/d5 keep step [4/8] on: its scope-map `mkdir -p "$HIMMEL_CACHE_DIR"` is
# what creates the missing component, so step [8/8] then removes the fake.
# A stub `claude` (on the resolver's $HOME/.local/bin list) lets step [4/8] run.
mk_claude_stub() { mkdir -p "$1/.local/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$1/.local/bin/claude"; chmod +x "$1/.local/bin/claude"; }
mkdir -p "$TMP/d/home"
mk_claude_stub "$TMP/d/home"
FLAGS=(--purge-state --yes --skip-tasks --skip-hooks)
mk_fake "$TMP/d1/real"
HOME="$TMP/d/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/d1/real" HIMMELCTL_CACHE_DIR="$TMP/d1/nonexist/../real"
expect_refused "(d1) HIMMELCTL_CACHE_DIR with .. behind a missing component" c "$TMP/d1/real"
FLAGS=(--purge-state --yes --skip-tasks --skip-plugins --skip-hooks)
mk_fake "$TMP/d2/real"
HOME="$TMP/d/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/d2/real" TELEGRAM_CHANNEL_DIR="$TMP/d2/nonexist/../real"
expect_refused "(d2) TELEGRAM_CHANNEL_DIR with .. behind a missing component" c "$TMP/d2/real"
mk_fake "$TMP/d3/real"
HOME="$TMP/d/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/d3/real" HIMMEL_PROVENANCE_DIR="$TMP/d3/nonexist/../real"
expect_refused "(d3) HIMMEL_PROVENANCE_DIR with .. behind a missing component" c "$TMP/d3/real"
mk_fake "$TMP/d4/real"
HOME="$TMP/d/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/d4/real" TELEGRAM_CHANNEL_DIR="$TMP/d4/no such/../real"
expect_refused "(d4) TELEGRAM_CHANNEL_DIR with a spaced missing component and .." c "$TMP/d4/real"
mk_fake "$TMP/d5/real"
mkdir -p "$TMP/d5/home"
mk_claude_stub "$TMP/d5/home"
FLAGS=(--purge-state --yes --skip-tasks --skip-hooks)
HOME="$TMP/d5/home" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/d5/real" HIMMELCTL_CACHE_DIR="$TMP/d5/home/.cache/pre-commit/../../../real"
expect_refused "(d5) HIMMELCTL_CACHE_DIR through a dir a later step creates" c "$TMP/d5/real"
FLAGS=(--purge-state --yes --skip-tasks --skip-plugins --skip-hooks)
HOME="$TMP/d/home" run_wet HIMMELCTL_CACHE_DIR="rel/cache"
expect_refused "(d6) relative HIMMELCTL_CACHE_DIR" c

# (w1)-(w4) the point-of-use wrapper, armed by hand over --source-only: a path
# that reaches the fake real home only through a symlink that exists at USE
# time is refused rc=3 with the fake intact; a scratch path is removed.
mk_fake "$TMP/w/real"
mkdir -p "$TMP/w/home/junk"
ln -s "$TMP/w/real/.claude" "$TMP/w/home/link"
_wreal=$(cd "$TMP/w/real" && pwd -P)
_whome=$(cd "$TMP/w/home" && pwd -P)
guarded_call() {  # <path|--no-dashdash> — output in $out, rc in $rc
    out=$(env HOME="$TMP/w/home" PATH="$HBIN" bash -c '. "$1" --source-only || exit 9
        RH_ARMED=1; RH_HP="$2"; RH_ROOTS="$3"
        if [ "$4" = --no-dashdash ]; then guarded rm -rf "$2/junk"; else guarded rm -rf -- "$4"; fi' \
        _ "$CLI" "$_whome" "$_wreal" "$1" </dev/null 2>&1); rc=$?
}
guarded_call "$TMP/w/real/.claude/himmel"
expect_refused "(w1) guarded removal inside the real home" c "$TMP/w/real"
guarded_call "$TMP/w/home/link/himmel"
expect_refused "(w2) guarded removal through a symlink into the real home" c "$TMP/w/real"
guarded_call "$TMP/w/home/junk"
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/w/home/junk" ]; then pass "(w3) guarded removal of a scratch path proceeds"; else fail "(w3) scratch removal rc=$rc — $out"; fi
mkdir -p "$TMP/w/home/junk"
guarded_call --no-dashdash
if [ "$rc" -eq 3 ] && [ -e "$TMP/w/home/junk" ]; then pass "(w4) guarded removal without -- is refused"; else fail "(w4) rc=$rc — $out"; fi
# (w5) armed by real_home_check itself, not by hand: the roots it hands the
# wrapper must not refuse a scratch path outside every root (an empty root
# line once matched every absolute path).
mkdir -p "$TMP/w/scratch/junk"
out=$(cd "$TMP/w/scratch" && env HOME="$TMP/w/home" PATH="$HBIN" HIMMEL_UNINSTALL_TEST_REAL_HOME="$TMP/w/real" \
    bash -c '. "$1" --source-only || exit 9
    real_home_check || exit 8
    guarded rm -rf -- "$2"' _ "$CLI" "$TMP/w/scratch/junk" </dev/null 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/w/scratch/junk" ]; then pass "(w5) real_home_check-armed wrapper removes a scratch path"; else fail "(w5) rc=$rc — $out"; fi

# (g1) every removal in uninstall.sh goes through the guarded wrapper: the only
# bare rm left are the mktemp handoff files (EXIT traps, the crontab stderr).
_allowed=$(cat <<'EOF'
trap 'prov_read_cleanup; rm -f "${_ledger_owned:-}"' EXIT
rm -f "$_cron_err"
trap 'prov_read_cleanup; rm -f "${_scope_map:-}" "${_ledger_owned:-}"' EXIT
EOF
)
_rmlines=$(grep -E '(^|[^[:alnum:]_./-])(rm|mv|rmdir|unlink)[[:space:]]' "$CLI" | sed 's/^[[:space:]]*//' | grep -v '^#')
_bare=$(printf '%s\n' "$_rmlines" | grep -vE 'guarded (run )?(rm|mv) ' | grep -vxF "$_allowed")
_nguard=$(printf '%s\n' "$_rmlines" | grep -cE 'guarded (run )?(rm|mv) ')
if [ -z "$_bare" ] && [ "$_nguard" -ge 10 ]; then
    pass "(g1) no removal bypasses the guarded wrapper ($_nguard guarded sites)"
else
    fail "(g1) $_nguard guarded sites; bare removals: $_bare"
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

# (ds) a leading `//` (or `///`) HOME or target: `cd -P && pwd -P` keeps a
# leading `//`, so an unnormalized physical path never matched a root spelled
# `/...` and every check was skipped. The settings step runs (no
# --skip-settings, and no --purge-state, whose own halt would end the run
# first), so the fake's settings.json must stay byte-identical.
# The `//` spellings come from a guarded mktemp (the static caller guard only
# accepts a HOME built from one), and each fake is named to the seam with ONE
# leading slash, so the exact-spelling pass-through never matches.
FLAGS=(--yes --skip-tasks --skip-plugins --skip-hooks)
DSTPL="/$TMP/ds.XXXXXX"
DS=$(mktemp -d "$DSTPL") || exit 1
DS3TPL="//$TMP/ds3.XXXXXX"
DS3=$(mktemp -d "$DS3TPL") || exit 1
mk_fake "${DS#/}/fakereal"
mkdir -p "${DS#/}/fakereal/Documents/.claude/himmel"
printf '{"sentinel":true}\n' > "${DS#/}/fakereal/Documents/.claude/settings.json"
mk_fake "${DS3#//}/fakereal"
# ds_settings <label> <settings.json> — byte-identical to the mk_fake original.
printf '{"sentinel":true}\n' > "$TMP/ds-settings.before"
ds_settings() {
    if cmp -s "$TMP/ds-settings.before" "$2"; then pass "$1: fake settings.json byte-identical"
    else fail "$1: fake settings.json was rewritten"; cp "$TMP/ds-settings.before" "$2"; fi
}
HOME="$DS/fakereal" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="${DS#/}/fakereal"
expect_refused "(ds1) HOME spelled //<fake real home>" a "${DS#/}/fakereal"
ds_settings "(ds1)" "${DS#/}/fakereal/.claude/settings.json"
HOME="$DS/fakereal/Documents" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="${DS#/}/fakereal"
expect_refused "(ds2) HOME spelled //<fake real home>/Documents" a "${DS#/}/fakereal"
ds_settings "(ds2)" "${DS#/}/fakereal/Documents/.claude/settings.json"
HOME="$DS3/fakereal" run_wet HIMMEL_UNINSTALL_TEST_REAL_HOME="${DS3#//}/fakereal"
expect_refused "(ds3) HOME spelled ///<fake real home>" a "${DS3#//}/fakereal"
ds_settings "(ds3)" "${DS3#//}/fakereal/.claude/settings.json"
awk -F'\t' -v OFS='\t' -v p="/$FAKE/.claude/himmel" '$1=="himmelctl-cache"{$6=p}1' \
    "$HERE/install/uninstall-manifest.tsv" > "$TMP/ds4-manifest.tsv"
mk_scratch "$TMP/ds4/home"
HOME="$TMP/ds4/home" run_wet HIMMEL_UNINSTALL_MANIFEST="$TMP/ds4-manifest.tsv"
expect_refused "(ds4) manifest row spelled //<fake real home>/..." c
ds_settings "(ds4)" "$FAKE/.claude/settings.json"
FLAGS=(--purge-state --yes --skip-tasks --skip-plugins --skip-hooks)

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
