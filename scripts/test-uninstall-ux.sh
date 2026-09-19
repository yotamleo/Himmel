#!/usr/bin/env bash
# HIMMEL-3058: uninstall UX contract — path manifest the uninstaller reads,
# `himmelctl uninstall --dry-run` that touches nothing (byte-identical tree),
# the code-vs-state split (--purge-state), printed changes, and a positive
# read-back of hook removal. Every case runs against a throwaway HOME under
# $TMP — never the operator's (HIMMEL-2502/2505). scripts/test-uninstall.sh
# stays the executor's regression suite; this one owns the UX contract.
set -uo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTS/.." && pwd)"
CLI="$SCRIPTS/uninstall.sh"
BIN_JS="$SCRIPTS/himmelctl/bin.js"
MANIFEST="$SCRIPTS/install/uninstall-manifest.tsv"

# The uninstaller reads path overrides from the environment; an operator's own
# (e.g. TELEGRAM_CHANNEL_DIR pointing at the live channel) must never steer a
# fixture run at a real directory (HIMMEL-2502 class). Cases that want an
# override set it per command.
unset TELEGRAM_CHANNEL_DIR BRIDGE_ROOT HIMMEL_USER_SETTINGS HIMMELCTL_CACHE_DIR \
      HIMMEL_UNINSTALL_MANIFEST HIMMEL_UNINSTALL_REPO_ROOT HIMMEL_UNINSTALL_REAL_HOME

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $*"; FAILED=$((FAILED + 1)); }
assert_rc() {
    if [ "$3" = "$2" ]; then pass "$1 (rc=$3)"; else fail "$1 — expected rc=$2, got rc=$3"; fi
}
assert_has() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 — output missing: $2" ;; esac
}
assert_not_has() {
    case "$3" in *"$2"*) fail "$1 — output unexpectedly contains: $2" ;; *) pass "$1" ;; esac
}
assert_exists() { if [ -e "$2" ]; then pass "$1"; else fail "$1 — missing: $2"; fi; }
assert_absent() { if [ ! -e "$2" ] && [ ! -L "$2" ]; then pass "$1"; else fail "$1 — still present: $2"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-ux.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
[ -n "$TMP" ] && [ -d "$TMP" ] || exit 1
trap 'rm -rf "$TMP"' EXIT

# Hermetic PATH (same recipe as test-uninstall.sh): no real claude/pre-commit/
# bun/crontab/schtasks/systemctl can be reached.
HBIN="$TMP/hbin"
mkdir -p "$HBIN"
# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$SCRIPTS/lib/hermetic-path.sh"
for _t in bash env sed grep awk tr sort head tail cut wc cat ls rm cp mv ln mkdir chmod \
          basename dirname readlink mktemp uname date id find xargs jq node git cksum diff; do
    link_hermetic_tool "$_t" "$HBIN"
done
# shellcheck source=lib/host-caps.sh
# shellcheck disable=SC1091
. "$SCRIPTS/lib/host-caps.sh"
if ! host_isolated_bash_boots; then
    host_skip "uninstall UX cases need a bash that starts under the hermetic PATH"
    exit "$((FAILED > 0 ? 1 : 0))"
fi

# A claude stub that answers the read-only listings with "nothing installed"
# and logs every call, so a dry-run that mutated plugins would show up.
STUB="$TMP/stub"
mkdir -p "$STUB"
export CLAUDE_CALL_LOG="$TMP/claude-calls.log"
cat > "$STUB/claude" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
case "$*" in
    'plugin list --json'|'plugin marketplace list --json') echo '[]' ;;
    *) exit 2 ;;
esac
STUB_EOF
chmod 755 "$STUB/claude"

HOOK_PRE='bash /fixture/himmel/scripts/hooks/block-edit-on-main.sh'
HOOK_SS='bash /fixture/himmel/scripts/hooks/inject-initiative.sh'
HOOK_FOREIGN='/opt/mine/keep-me.sh'
SETTINGS_JSON='{"env":{"HIMMEL_REPO":"/fixture/himmel","LUNA_VAULT_PATH":"/fixture/luna","KEEP":"yes"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"'"$HOOK_PRE"'"},{"type":"command","command":"'"$HOOK_FOREIGN"'"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"'"$HOOK_SS"'"}]}]}}'

# fixture <name> — a fresh HOME + project repo holding every surface the
# manifest lists. Sets FX_HOME FX_PROJ and the state paths.
fixture() {
    FX="$TMP/fx-$1"
    FX_HOME="$FX/home"
    FX_PROJ="$FX/proj"
    rm -rf "$FX"
    mkdir -p "$FX_HOME/.claude/channels/telegram" "$FX_HOME/.claude/handover/bridge/sessions/S1" \
        "$FX_HOME/.claude/himmel" "$FX_PROJ/.claude"
    printf 'TELEGRAM_BOT_TOKEN=123:abc\n' > "$FX_HOME/.claude/channels/telegram/.env"
    printf '{"allowFrom":["42"]}\n' > "$FX_HOME/.claude/channels/telegram/access.json"
    printf 'x\n' > "$FX_HOME/.claude/handover/bridge/sessions/S1/inbox.jsonl"
    printf '{"scope":"user"}\n' > "$FX_HOME/.claude/himmel/install-profile.json"
    printf '%s\n' "$SETTINGS_JSON" > "$FX_HOME/.claude/settings.json"
    printf '%s\n' "$SETTINGS_JSON" > "$FX_PROJ/.claude/settings.json"
    git -C "$FX_PROJ" init -q 2>/dev/null
    mkdir -p "$FX_PROJ/.git/hooks"   # a git with no template dir (CI) creates none
    printf '#!/usr/bin/env bash\n# HIMMEL-2771: native invariant gate; lint hooks require pre-commit.\nexit 0\n' \
        > "$FX_PROJ/.git/hooks/pre-commit"
    chmod 755 "$FX_PROJ/.git/hooks/pre-commit"
    : > "$CLAUDE_CALL_LOG"
}

# snap <root...> — names + content checksums, so "byte-identical" is checkable.
snap() {
    find "$@" 2>/dev/null | LC_ALL=C sort
    find "$@" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
}

# run_uninstall <args...> — the executor, from the fixture project.
run_uninstall() {
    out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" \
        bash "$CLI" "$@" </dev/null 2>&1); rc=$?
}

# ── M1 — the manifest is well-formed and every row maps to a real step ─────
if [ ! -f "$MANIFEST" ]; then
    fail "M1 manifest missing: $MANIFEST"
    m1_ok=0
else
    m1_ok=1
    m1_ids=""
    while IFS=$'\t' read -r id class surface kind env path step what extra; do
        case "$id" in ''|'#'*) continue ;; esac
        [ -z "$extra" ] || { fail "M1 $id: more than 8 columns"; m1_ok=0; }
        [ -n "$what" ] || { fail "M1 $id: fewer than 8 columns"; m1_ok=0; }
        case "$class" in code|state|keep) ;; *) fail "M1 $id: bad class '$class'"; m1_ok=0 ;; esac
        case "$kind" in dir|settings|githooks|process|jobs|plugins|marketplaces|file) ;; *) fail "M1 $id: bad kind '$kind'"; m1_ok=0 ;; esac
        case "$step" in [1-8]|-) ;; *) fail "M1 $id: bad step '$step'"; m1_ok=0 ;; esac
        [ "$class" = keep ] && [ "$step" != - ] && { fail "M1 $id: a keep row has a step"; m1_ok=0; }
        [ "$class" != keep ] && [ "$step" = - ] && { fail "M1 $id: a non-keep row has no step"; m1_ok=0; }
        case " $m1_ids " in *" $id "*) fail "M1 duplicate id $id"; m1_ok=0 ;; esac
        m1_ids="$m1_ids $id"
        _unused="$surface$env$path"
    done < "$MANIFEST"
    [ "$m1_ok" -eq 1 ] && pass "M1 manifest rows well-formed"
fi
m1_steps=$(grep -v '^#' "$MANIFEST" 2>/dev/null | awk -F'\t' '$2!="keep"{print $7}' | LC_ALL=C sort -u | tr '\n' ' ')
if [ "$m1_steps" = "1 2 3 4 5 6 7 8 " ]; then pass "M1 every uninstall step 1-8 is covered by a manifest row"
else fail "M1 manifest covers steps '$m1_steps', expected 1..8"; fi

# ── M2 — the uninstaller READS the manifest (a fixture manifest re-points it)
fixture m2
ALT="$FX/alt-channel"
mkdir -p "$ALT"
printf 'x\n' > "$ALT/access.json"
{
    grep -v '^telegram-channel' "$MANIFEST"
    printf 'telegram-channel\tstate\ttelegram-bridge\tdir\t-\t%s\t2\trelocated for the M2 fixture\n' "$ALT"
} > "$FX/alt-manifest.tsv"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/alt-manifest.tsv" \
    bash "$CLI" --dry-run --purge-state --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "M2 dry-run with a fixture manifest" 0 "$rc"
assert_has "M2 the manifest's path is the one targeted" "DRY: rm -rf -- $ALT" "$out"
assert_not_has "M2 the built-in default path is NOT re-derived" "channels/telegram" "$out"

# ── D1 — himmelctl uninstall --dry-run lists everything, changes nothing ───
fixture d1
before="$FX/before.txt"; after="$FX/after.txt"
snap "$FX_HOME" "$FX_PROJ" > "$before"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" USERPROFILE="$FX_HOME" PATH="$STUB:$HBIN" \
    node "$BIN_JS" uninstall --dry-run </dev/null 2>&1); rc=$?
snap "$FX_HOME" "$FX_PROJ" > "$after"
assert_rc "D1 himmelctl uninstall --dry-run" 0 "$rc"
if cmp -s "$before" "$after"; then pass "D1 filesystem byte-identical across the dry-run"
else fail "D1 the dry-run changed the filesystem"; diff "$before" "$after" | head -10; fi
if grep -Eq 'uninstall|remove' "$CLAUDE_CALL_LOG"; then fail "D1 dry-run issued a mutating claude call: $(cat "$CLAUDE_CALL_LOG")"
else pass "D1 dry-run issued only read-only claude calls"; fi
assert_has "D1 lists the telegram channel path" "$FX_HOME/.claude/channels/telegram" "$out"
assert_has "D1 lists the bridge path" "$FX_HOME/.claude/handover/bridge" "$out"
assert_has "D1 lists the cache path" "$FX_HOME/.claude/himmel" "$out"
assert_has "D1 lists the user settings file" "$FX_HOME/.claude/settings.json" "$out"
assert_has "D1 lists the project settings file" "$FX_PROJ/.claude/settings.json" "$out"
assert_has "D1 lists the git hooks it would remove" "$FX_PROJ/.git/hooks/pre-commit" "$out"
assert_has "D1 lists each himmel hook command it would unwire" "$HOOK_PRE" "$out"
assert_has "D1 lists the SessionStart hook too" "$HOOK_SS" "$out"
assert_has "D1 lists the settings keys it would remove" "env.HIMMEL_REPO" "$out"
assert_not_has "D1 never lists a foreign hook as removed" "$HOOK_FOREIGN" "$out"
assert_has "D1 says it is a dry run" "dry-run" "$out"

# ── S1 — DEFAULT uninstall removes himmel's code, keeps operator state ─────
fixture s1
run_uninstall --yes --skip-tasks --skip-plugins
assert_rc "S1 default uninstall" 0 "$rc"
assert_exists "S1 telegram pairing kept by default" "$FX_HOME/.claude/channels/telegram/access.json"
assert_exists "S1 bridge state kept by default" "$FX_HOME/.claude/handover/bridge/sessions/S1/inbox.jsonl"
assert_absent "S1 himmelctl cache removed (himmel's own code/cache)" "$FX_HOME/.claude/himmel"
assert_absent "S1 native git hook removed" "$FX_PROJ/.git/hooks/pre-commit"
assert_not_has "S1 user settings: no himmel hook left" "block-edit-on-main" "$(cat "$FX_HOME/.claude/settings.json")"
assert_has "S1 user settings: foreign hook survives" "$HOOK_FOREIGN" "$(cat "$FX_HOME/.claude/settings.json")"
assert_has "S1 user settings: foreign env key survives" '"KEEP"' "$(cat "$FX_HOME/.claude/settings.json")"
assert_has "S1 prints the exact hook line it removed" "$HOOK_PRE" "$out"
assert_has "S1 positive read-back of the user settings" "verified: no himmel hook wired in $FX_HOME/.claude/settings.json" "$out"
assert_has "S1 positive read-back of the project settings" "verified: no himmel hook wired in $FX_PROJ/.claude/settings.json" "$out"
assert_has "S1 footprint marks state as kept" "KEEP" "$out"
assert_has "S1 footprint names the purge flag" "--purge-state" "$out"

# ── S2 — --purge-state ALSO removes operator state (distinct outcome) ──────
fixture s2
run_uninstall --yes --skip-tasks --skip-plugins --purge-state
assert_rc "S2 --purge-state uninstall" 0 "$rc"
assert_absent "S2 telegram pairing removed" "$FX_HOME/.claude/channels/telegram"
assert_absent "S2 bridge state removed" "$FX_HOME/.claude/handover/bridge"
assert_absent "S2 himmelctl cache removed" "$FX_HOME/.claude/himmel"
assert_not_has "S2 no himmel hook left in user settings" "inject-initiative" "$(cat "$FX_HOME/.claude/settings.json")"

# ── S3 — --purge-state and --keep-telegram-state contradict: refused ───────
fixture s3
run_uninstall --yes --skip-tasks --skip-plugins --purge-state --keep-telegram-state
assert_rc "S3 contradictory flags refused" 2 "$rc"
assert_exists "S3 nothing removed on refusal" "$FX_HOME/.claude/channels/telegram/access.json"

# ── K1 — deletion honours the manifest CLASS, not only the printed footprint ─
# A manifest that re-classes himmelctl-cache as keep and telegram-channel as
# keep must leave BOTH on disk, even with --purge-state (the footprint must not
# say KEEP while the step deletes).
fixture k1
sed -e $'s/^himmelctl-cache\tcode/himmelctl-cache\tkeep/' \
    -e $'s/^telegram-channel\tstate/telegram-channel\tkeep/' "$MANIFEST" > "$FX/keep-manifest.tsv"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/keep-manifest.tsv" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --purge-state </dev/null 2>&1); rc=$?
assert_rc "K1 uninstall with a re-classed manifest" 0 "$rc"
assert_exists "K1 himmelctl-cache class=keep is not deleted" "$FX_HOME/.claude/himmel/install-profile.json"
assert_exists "K1 telegram-channel class=keep survives --purge-state" "$FX_HOME/.claude/channels/telegram/access.json"
assert_absent "K1 telegram-bridge (still state) IS purged" "$FX_HOME/.claude/handover/bridge"
# …and the reverse: a code row re-classed as state is kept without --purge-state.
fixture k2
sed -e $'s/^himmelctl-cache\tcode/himmelctl-cache\tstate/' "$MANIFEST" > "$FX/state-manifest.tsv"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/state-manifest.tsv" \
    bash "$CLI" --yes --skip-tasks --skip-plugins </dev/null 2>&1); rc=$?
assert_rc "K2 uninstall with the cache re-classed as state" 0 "$rc"
assert_exists "K2 himmelctl-cache class=state is kept by default" "$FX_HOME/.claude/himmel/install-profile.json"

# ── K3 — EVERY step honours its row's class, not just steps 2 and 8 ─────────
# Re-class the seven non-directory rows as keep: no step may act on them (no
# --skip-* here, so only the manifest class can hold them back), each says so,
# and the code row still removed (himmelctl-cache) proves the run was live.
fixture k3
sed -e $'s/^bridge-process\tcode/bridge-process\tkeep/' \
    -e $'s/^scheduled-jobs\tcode/scheduled-jobs\tkeep/' \
    -e $'s/^plugins\tcode/plugins\tkeep/' \
    -e $'s/^git-hooks\tcode/git-hooks\tkeep/' \
    -e $'s/^user-settings\tcode/user-settings\tkeep/' \
    -e $'s/^project-settings\tcode/project-settings\tkeep/' \
    -e $'s/^marketplaces\tcode/marketplaces\tkeep/' "$MANIFEST" > "$FX/k3-manifest.tsv"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/k3-manifest.tsv" \
    bash "$CLI" --yes --purge-state </dev/null 2>&1); rc=$?
assert_rc "K3 uninstall with every step row re-classed keep" 0 "$rc"
assert_has "K3 step 1 keeps the bridge running" "kept (manifest class keep): bridge left running" "$out"
assert_has "K3 step 6 keeps the user settings" "kept (manifest class keep): $FX_HOME/.claude/settings.json" "$out"
assert_has "K3 step 6 keeps the project settings" "project settings: kept (manifest class keep): $FX_PROJ/.claude/settings.json" "$out"
k3_kept=$(printf '%s\n' "$out" | grep -c 'kept (manifest class keep)')
if [ "$k3_kept" -eq 7 ]; then pass "K3 exactly the seven re-classed steps report kept (manifest class keep)"
else fail "K3 expected 7 'kept (manifest class keep)' lines, got $k3_kept"; fi
assert_has "K3 user settings: himmel hook still wired" "$HOOK_PRE" "$(cat "$FX_HOME/.claude/settings.json")"
assert_has "K3 project settings: himmel hook still wired" "$HOOK_PRE" "$(cat "$FX_PROJ/.claude/settings.json")"
assert_exists "K3 git-hooks class=keep leaves the native hook" "$FX_PROJ/.git/hooks/pre-commit"
if [ -s "$CLAUDE_CALL_LOG" ]; then fail "K3 plugins/marketplaces class=keep still called claude: $(cat "$CLAUDE_CALL_LOG")"
else pass "K3 plugins/marketplaces class=keep made no claude call"; fi
assert_absent "K3 the still-code cache row was removed (the run was live)" "$FX_HOME/.claude/himmel"

# ── K4 — the step-2 PLAN says what the step does, per row class ────────────
# A state row re-classed keep must not be announced as REMOVE under
# --purge-state: the plan, the footprint and the step all read the same class.
fixture k4
sed -e $'s/^telegram-channel\tstate/telegram-channel\tkeep/' "$MANIFEST" > "$FX/k4-mixed.tsv"
sed -e $'s/^telegram-channel\tstate/telegram-channel\tkeep/' \
    -e $'s/^telegram-bridge\tstate/telegram-bridge\tkeep/' "$MANIFEST" > "$FX/k4-both.tsv"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/k4-mixed.tsv" \
    bash "$CLI" --dry-run --purge-state --skip-tasks --skip-plugins </dev/null 2>&1); rc=$?
assert_rc "K4 dry-run with one state row re-classed keep" 0 "$rc"
k4_plan=$(printf '%s\n' "$out" | sed -n '/^This will:/,/^Footprint/p')
assert_not_has "K4 mixed: the plan does not announce both rows as removed" "REMOVE telegram pairing + bridge state" "$k4_plan"
assert_has "K4 mixed: the plan keeps the re-classed channel" "keep   $FX_HOME/.claude/channels/telegram" "$k4_plan"
assert_has "K4 mixed: the plan still removes the bridge state" "REMOVE $FX_HOME/.claude/handover/bridge" "$k4_plan"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/k4-both.tsv" \
    bash "$CLI" --dry-run --purge-state --skip-tasks --skip-plugins </dev/null 2>&1); rc=$?
assert_rc "K4 dry-run with both state rows re-classed keep" 0 "$rc"
k4_plan=$(printf '%s\n' "$out" | sed -n '/^This will:/,/^Footprint/p')
assert_not_has "K4 both: the plan does not announce removal" "REMOVE telegram pairing" "$k4_plan"
assert_has "K4 both: the plan says keep by manifest class" "keep telegram pairing + bridge state (manifest class keep)" "$k4_plan"

# ── K5 — a kept-running bridge must not have its state deleted under it ─────
fixture k5
k5_man="$FX/k5-manifest.tsv"
sed -e $'s/^bridge-process\tcode/bridge-process\tkeep/' "$MANIFEST" > "$k5_man"
printf '99999\n' > "$FX_HOME/.claude/handover/bridge/supervisor.pid"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$k5_man" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --purge-state </dev/null 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then pass "K5 kept-running bridge + --purge-state is refused (rc=$rc)"
else fail "K5 expected a non-zero rc, got 0"; fi
assert_has "K5 names why" "kept running but its state" "$out"
assert_exists "K5 the running bridge's state is not deleted" "$FX_HOME/.claude/handover/bridge/supervisor.pid"
assert_not_has "K5 never claims completion" "Uninstall complete." "$out"
# Controls: without --purge-state the state is kept, so nothing conflicts; with
# no supervisor.pid there is no live bridge to protect.
fixture k5b
printf '99999\n' > "$FX_HOME/.claude/handover/bridge/supervisor.pid"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$k5_man" \
    bash "$CLI" --yes --skip-tasks --skip-plugins </dev/null 2>&1); rc=$?
assert_rc "K5 control: kept bridge, state kept (no --purge-state)" 0 "$rc"
assert_exists "K5 control: state still there" "$FX_HOME/.claude/handover/bridge/supervisor.pid"
fixture k5c
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$k5_man" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --purge-state </dev/null 2>&1); rc=$?
assert_rc "K5 control: kept bridge, no supervisor.pid, --purge-state" 0 "$rc"
assert_absent "K5 control: state purged when no live bridge exists" "$FX_HOME/.claude/handover/bridge"

# ── L1 — a malformed manifest fails closed (rc=2) with a named ERROR ────────
fixture l1
{ cat "$MANIFEST"; grep '^himmelctl-cache' "$MANIFEST"; } > "$FX/dup-manifest.tsv"
sed -e $'s/^himmelctl-cache\tcode\thimmelctl\tdir/himmelctl-cache\tcode\thimmelctl\tbogus/' "$MANIFEST" > "$FX/kind-manifest.tsv"
sed -e $'s/\t8\thimmelctl install-profile/\t9\thimmelctl install-profile/' "$MANIFEST" > "$FX/step-manifest.tsv"
for l1_case in "dup:duplicate manifest id 'himmelctl-cache'" "kind:has kind 'bogus'" "step:has step '9'"; do
    l1_key="${l1_case%%:*}"; l1_want="${l1_case#*:}"
    out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/$l1_key-manifest.tsv" \
        bash "$CLI" --dry-run </dev/null 2>&1); rc=$?
    assert_rc "L1 $l1_key: malformed manifest refused" 2 "$rc"
    assert_has "L1 $l1_key: names the defect" "$l1_want" "$out"
done
assert_exists "L1 nothing removed on refusal" "$FX_HOME/.claude/himmel/install-profile.json"

# ── F1 — the footprint reflects --skip-* (a skipped code row is not REMOVE) ──
fixture f1
run_uninstall --dry-run --skip-tasks --skip-plugins --skip-hooks --skip-settings
assert_rc "F1 dry-run with every --skip-*" 0 "$rc"
f1_fp=$(printf '%s\n' "$out" | sed -n '/^Footprint/,/^$/p')
assert_not_has "F1 skipped user-settings row is not REMOVE" "REMOVE  $FX_HOME/.claude/settings.json" "$f1_fp"
assert_not_has "F1 skipped git-hooks row is not REMOVE" "REMOVE  $FX_PROJ/.git/hooks" "$f1_fp"
assert_has "F1 skipped rows read SKIP" "SKIP" "$f1_fp"
assert_has "F1 the un-skipped cache row is still REMOVE" "REMOVE  $FX_HOME/.claude/himmel" "$f1_fp"

# ── R1 — read-back is independent of the unwire helper's own rc ────────────
# A helper that exits 0 without removing anything must FAIL the uninstall.
fixture r1
FIXREPO="$FX/repo"
mkdir -p "$FIXREPO/scripts/lib" "$FIXREPO/scripts/machine-setup"
cp "$SCRIPTS"/lib/unwire-*.sh "$FIXREPO/scripts/lib/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXREPO/scripts/lib/unwire-pretooluse-hooks.sh"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$FIXREPO" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "R1 a no-op unwire (helper rc=0) fails the uninstall" 2 "$rc"
assert_has "R1 names the hook that is still wired" "still wired" "$out"
assert_not_has "R1 never claims completion" "Uninstall complete." "$out"

# ── H1 — himmelctl passes --purge-state and --dry-run to the executor ──────
# The stub is an extensionless bash script; on Windows himmelctl runs
# uninstall.ps1 instead, so this case cannot execute there. Covered on Windows
# by scripts/himmelctl/test/test-wizard-uninstall.sh (caseB) and the nightly.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "SKIP H1 himmelctl -> uninstall.sh plumbing (Windows Git Bash: himmelctl execs uninstall.ps1; covered by test-wizard-uninstall.sh caseB)"
        H1_SKIP=1 ;;
    *) H1_SKIP=0 ;;
esac
if [ "$H1_SKIP" -eq 0 ]; then
fixture h1
HREPO="$FX/hrepo"
mkdir -p "$HREPO/scripts"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/uninstall-args.log"\nexit 0\n' "$FX" > "$HREPO/scripts/uninstall.sh"
chmod 755 "$HREPO/scripts/uninstall.sh"
himmelctl_stub() {
    out=$(cd "$FX_PROJ" && HOME="$FX_HOME" USERPROFILE="$FX_HOME" PATH="$STUB:$HBIN" HIMMELCTL_REPO_ROOT="$HREPO" \
        HIMMELCTL_BIN_DIR="$FX/bin" node "$BIN_JS" uninstall "$@" </dev/null 2>&1); rc=$?
}
: > "$FX/uninstall-args.log"
himmelctl_stub --yes
assert_rc "H1 himmelctl uninstall --yes" 0 "$rc"
assert_not_has "H1 default run does not pass --purge-state" "purge-state" "$(cat "$FX/uninstall-args.log")"
: > "$FX/uninstall-args.log"
himmelctl_stub --yes --purge-state
assert_rc "H1 himmelctl uninstall --yes --purge-state" 0 "$rc"
assert_has "H1 --purge-state reaches the executor" "--purge-state" "$(cat "$FX/uninstall-args.log")"
: > "$FX/uninstall-args.log"
himmelctl_stub --dry-run --purge-state
assert_rc "H1 himmelctl uninstall --dry-run --purge-state" 0 "$rc"
h1_args=$(cat "$FX/uninstall-args.log")
assert_has "H1 dry-run runs the executor's own --dry-run" "--dry-run" "$h1_args"
assert_has "H1 dry-run carries --purge-state" "--purge-state" "$h1_args"
assert_not_has "H1 dry-run never passes --yes" "--yes" "$h1_args"
fi

# ── P1 — the PowerShell twin carries the same split ────────────────────────
# pwsh is not available on every runner, so this is a source-level check of the
# contract: the switch exists, contradicts -KeepTelegramState, and step 2 is
# gated on the derived $RemoveState. Execution proof is the nightly.
if grep -q 'PurgeState' "$SCRIPTS/uninstall.ps1"; then pass "P1 uninstall.ps1 has -PurgeState"
else fail "P1 uninstall.ps1 lacks -PurgeState"; fi
# shellcheck disable=SC2016 # the PowerShell $-variables are literal grep patterns
if grep -Fq '$RemoveState = $PurgeState -and (-not $KeepTelegramState)' "$SCRIPTS/uninstall.ps1"; then pass "P1 uninstall.ps1 derives RemoveState from -PurgeState"
else fail "P1 uninstall.ps1 does not derive RemoveState from -PurgeState"; fi
# shellcheck disable=SC2016 # the PowerShell $-variables are literal grep patterns
if grep -Fq 'if (-not $RemoveState) {' "$SCRIPTS/uninstall.ps1"; then pass "P1 uninstall.ps1 step 2 is gated on RemoveState"
else fail "P1 uninstall.ps1 step 2 is not gated on RemoveState"; fi

# ── DOC — the install doc and the README link the command ──────────────────
if grep -Eq 'himmelctl.*uninstall.*--dry-run|uninstall --dry-run' "$ROOT/docs/setup/install.md"; then pass "DOC install.md documents uninstall --dry-run"
else fail "DOC install.md does not document uninstall --dry-run"; fi
if grep -q 'purge-state' "$ROOT/docs/setup/install.md"; then pass "DOC install.md documents --purge-state"
else fail "DOC install.md does not document --purge-state"; fi
if grep -Eq 'uninstall --dry-run' "$ROOT/README.md"; then pass "DOC README links the dry-run uninstall"
else fail "DOC README does not mention uninstall --dry-run"; fi

echo ""
if [ "$FAILED" -eq 0 ]; then echo "test-uninstall-ux: all passed"; exit 0; fi
echo "test-uninstall-ux: $FAILED failed"
exit 1
