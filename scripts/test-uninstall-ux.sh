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

# ── P1 — the PowerShell twin carries the same split ────────────────────────
if grep -q 'PurgeState' "$SCRIPTS/uninstall.ps1"; then pass "P1 uninstall.ps1 has -PurgeState"
else fail "P1 uninstall.ps1 lacks -PurgeState"; fi

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
