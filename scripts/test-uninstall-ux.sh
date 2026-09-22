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
    # HIMMEL-3332 S11: the shipped file has 9 columns; the 9th (record) names the
    # provenance-ledger kinds install writes for the row, drawn from provenance.sh's
    # own vocabulary, or 'none'. (The reader still accepts the 8-column form — M2/L1.)
    m1_kinds=$(sed -n 's/^_PROV_KINDS="\(.*\)"$/\1/p' "$SCRIPTS/lib/provenance.sh")
    [ -n "$m1_kinds" ] || { fail "M1 could not read _PROV_KINDS from provenance.sh"; m1_ok=0; }
    while IFS=$'\t' read -r id class surface kind env path step what record extra; do
        case "$id" in ''|'#'*) continue ;; esac
        [ -z "$extra" ] || { fail "M1 $id: more than 9 columns"; m1_ok=0; }
        [ -n "$record" ] || { fail "M1 $id: fewer than 9 columns"; m1_ok=0; }
        if [ "$record" = none ]; then :
        else
            case ",$record," in *,,*) fail "M1 $id: record '$record' has an empty kind"; m1_ok=0 ;; esac
            for m1_k in $(printf '%s' "$record" | tr ',' ' '); do
                case " $m1_kinds " in *" $m1_k "*) ;; *) fail "M1 $id: record kind '$m1_k' not in provenance.sh's vocabulary"; m1_ok=0 ;; esac
            done
        fi
        case "$record" in *none*) [ "$record" = none ] || { fail "M1 $id: 'none' must stand alone in record"; m1_ok=0; } ;; esac
        case "$class" in code|state|keep) ;; *) fail "M1 $id: bad class '$class'"; m1_ok=0 ;; esac
        case "$kind" in dir|settings|githooks|process|jobs|plugins|marketplaces|file) ;; *) fail "M1 $id: bad kind '$kind'"; m1_ok=0 ;; esac
        case "$step" in [1-8]|-) ;; *) fail "M1 $id: bad step '$step'"; m1_ok=0 ;; esac
        [ "$class" = keep ] && [ "$step" != - ] && { fail "M1 $id: a keep row has a step"; m1_ok=0; }
        [ "$class" != keep ] && [ "$step" = - ] && { fail "M1 $id: a non-keep row has no step"; m1_ok=0; }
        case " $m1_ids " in *" $id "*) fail "M1 duplicate id $id"; m1_ok=0 ;; esac
        m1_ids="$m1_ids $id"
        _unused="$surface$env$path$what"
    done < "$MANIFEST"
    [ "$m1_ok" -eq 1 ] && pass "M1 manifest rows well-formed"
fi
# The rows S11 adds: class, kind, env, step and record are the contract S6/S8 read.
# m1_col <id> <field-no> — one column of one row.
m1_col() { awk -F'\t' -v id="$1" -v n="$2" '$1==id{print $n}' "$MANIFEST"; }
m1_want() { # <id> <class> <kind> <env> <step> <record>
    m1_got="$(m1_col "$1" 2)/$(m1_col "$1" 4)/$(m1_col "$1" 5)/$(m1_col "$1" 7)/$(m1_col "$1" 9)"
    if [ "$m1_got" = "$2/$3/$4/$5/$6" ]; then pass "M1 row $1 is $2/$3/$4/step $5/record $6"
    else fail "M1 row $1: got '$m1_got', want '$2/$3/$4/$5/$6'"; fi
}
m1_want provenance-ledger state file HIMMEL_PROVENANCE_DIR 8 file
m1_want cadence-jobs code jobs - 3 job
m1_want bridge-unit code file - 1 unit,file
m1_want third-party-caches keep file - - none
m1_want phi-roots code file - 6 line
m1_want graphify-wiring code file - 6 mcp,json-elem,symlink
m1_want qmd-fork code file - 8 symlink,file,collection
m1_want adopter-scripts keep dir - - file
case "$(m1_col adopter-scripts 8)" in *"code for recorded files; unrecorded copies kept"*) pass "M1 adopter-scripts reason names recorded vs unrecorded copies" ;; *) fail "M1 adopter-scripts reason text not updated" ;; esac
case "$(m1_col third-party-caches 8)" in *HIMMEL-3330*) pass "M1 third-party-caches cites HIMMEL-3330" ;; *) fail "M1 third-party-caches does not cite HIMMEL-3330" ;; esac
case "$(m1_col qmd-fork 8)" in *HIMMEL-3311*) pass "M1 qmd-fork cites HIMMEL-3311" ;; *) fail "M1 qmd-fork does not cite HIMMEL-3311" ;; esac
m1_steps=$(grep -v '^#' "$MANIFEST" 2>/dev/null | awk -F'\t' '$2!="keep"{print $7}' | LC_ALL=C sort -u | tr '\n' ' ')
if [ "$m1_steps" = "1 2 3 4 5 6 7 8 " ]; then pass "M1 every uninstall step 1-8 is covered by a manifest row"
else fail "M1 manifest covers steps '$m1_steps', expected 1..8"; fi

# ── W1 — S11 writer-presence: every recorded row has a writer, or a named gap ──
# A row's `record` column (M1) says install WRITES that ledger kind for it; W1
# checks that a writer actually exists, so the column cannot drift into
# documentation of something no code does. For each row with record != none,
# either a colon-separated list of source files that contain a
# provenance-writing call, or PENDING(<slice/ticket/reason>) when no writer
# was found anywhere in the tree (a real gap, not this row's to fix).
# ponytail: the file check greps for ANY provenance-writing call in the named
# file, not a call that specifically emits THIS row's kind — a file wired for
# an unrelated row would false-pass. Tightening this to a per-kind/per-row
# match would mean parsing bash and JS call sites structurally; out of scope
# for a regression guard whose job is to catch a row losing its writer
# entirely (the file deleted, renamed, or never grep-matching again).
w1_map_ids=""
w1_writer() { # <id> <PENDING(...)|file[:file...]>
    w1_map_ids="$w1_map_ids $1"
    case "$2" in
        PENDING\(*\))
            pass "W1 $1: no writer found — $2"
            ;;
        *)
            w1_ok=1
            for w1_f in $(printf '%s' "$2" | tr ':' ' '); do
                if [ ! -f "$ROOT/$w1_f" ]; then
                    fail "W1 $1: writer file missing: $w1_f"; w1_ok=0; continue
                fi
                if ! grep -q "prov_record\|prov_note\|provRecord\|provBefore\|provenance\.jsonl" "$ROOT/$w1_f"; then
                    fail "W1 $1: $w1_f has no provenance-writing call"; w1_ok=0
                fi
            done
            [ "$w1_ok" -eq 1 ] && pass "W1 $1: recorded by $2"
            ;;
    esac
}
w1_writer bridge-unit scripts/himmelctl/lib/bridge-persistence.js
w1_writer telegram-channel "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer telegram-bridge "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer scheduled-jobs "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer cadence-jobs "PENDING(HIMMEL-3332 S8)"
w1_writer plugins scripts/machine-setup/install-plugins.sh
w1_writer git-hooks "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer git-hook-backups "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer user-settings scripts/lib/wire-statusline.sh:scripts/lib/wire-handover-dir.sh:scripts/lib/wire-himmel-repo.sh:scripts/lib/wire-luna-vault.sh:scripts/lib/wire-pretooluse-hooks.sh
w1_writer project-settings scripts/lib/wire-statusline.sh:scripts/lib/wire-handover-dir.sh:scripts/lib/wire-himmel-repo.sh:scripts/lib/wire-luna-vault.sh:scripts/lib/wire-pretooluse-hooks.sh
w1_writer user-claude-md "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer user-agents-md "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer hud-config scripts/lib/wire-statusline.sh
w1_writer phi-roots scripts/himmelctl/bin.js
w1_writer graphify-wiring "PENDING(design doc D5 — separate ticket, not yet filed)"
w1_writer marketplaces scripts/machine-setup/install-plugins.sh
w1_writer himmelctl-cache scripts/himmelctl/bin.js
w1_writer qmd-fork "PENDING(no writer found; gap predates S6, unfiled)"
w1_writer provenance-ledger scripts/lib/provenance.sh
w1_writer workspace-trust scripts/himmelctl/bin.js
w1_writer adopter-scripts scripts/adopt.sh
w1_writer himmel-clone scripts/himmelctl/bin.js
# Coverage: a manifest row added later with record != none and no w1_writer
# call above must fail here, not pass silently by never being checked.
w1_missing=""
while IFS=$'\t' read -r w1_id _ _ _ _ _ _ _ w1_record w1_extra; do
    case "$w1_id" in ''|'#'*) continue ;; esac
    [ "$w1_record" = none ] && continue
    case " $w1_map_ids " in *" $w1_id "*) ;; *) w1_missing="$w1_missing $w1_id" ;; esac
    _unused="$w1_extra"
done < "$MANIFEST"
if [ -z "$w1_missing" ]; then pass "W1 every recorded manifest row has a writer-presence entry"
else fail "W1 rows with no writer-presence entry:$w1_missing"; fi

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
assert_has "S1 positive read-back of the user settings" "verified: no himmel wiring left in $FX_HOME/.claude/settings.json" "$out"
assert_has "S1 positive read-back of the project settings" "verified: no himmel wiring left in $FX_PROJ/.claude/settings.json" "$out"
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

# ── L2 — the reader takes an 8- OR 9-column row (HIMMEL-3332 S11), never a 10th ─
# 8 = the pre-record layout (older fixtures), 9 = the shipped layout with `record`.
fixture l2
awk -F'\t' -v OFS='\t' '/^#/||NF==0{print;next}{NF=8;print}' "$MANIFEST" > "$FX/cols8-manifest.tsv"
sed -e $'s/^himmelctl-cache\\(.*\\)$/himmelctl-cache\\1\\textra/' "$MANIFEST" > "$FX/cols10-manifest.tsv"
for l2_case in "cols8:0" "cols10:2"; do
    l2_key="${l2_case%%:*}"; l2_want="${l2_case#*:}"
    out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/$l2_key-manifest.tsv" \
        bash "$CLI" --dry-run </dev/null 2>&1); rc=$?
    assert_rc "L2 $l2_key manifest" "$l2_want" "$rc"
done
assert_has "L2 a 10-column row names the column rule" "8 or 9 tab-separated columns" "$out"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" bash "$CLI" --dry-run </dev/null 2>&1); rc=$?
assert_rc "L2 the shipped 9-column manifest loads" 0 "$rc"

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

# ── P2 — CodeRabbit round: a skipped purge is an INCOMPLETE step (ps1) ─────
# Source-level (no pwsh here): the -PurgeState + bridge-maybe-running branch
# must record an incomplete step, or the run ends "Uninstall complete." with
# the bot token still on disk. The suite's own cache redirect is asserted too.
# shellcheck disable=SC2016 # the PowerShell $-variables are literal grep patterns
if grep -Fq "\$StepsIncomplete.Add('[2/7] telegram pairing + bridge state" "$SCRIPTS/uninstall.ps1"; then pass "P2 uninstall.ps1 records a skipped purge as an incomplete step"
else fail "P2 uninstall.ps1 skips the purge without recording an incomplete step"; fi
# shellcheck disable=SC2016 # the PowerShell $-variables are literal grep patterns
if grep -Fq '$SavedCacheDir = $env:HIMMELCTL_CACHE_DIR' "$SCRIPTS/test-uninstall.ps1" \
    && grep -Fq "\$env:HIMMELCTL_CACHE_DIR = Join-Path \$Tmp 'cache-default'" "$SCRIPTS/test-uninstall.ps1" \
    && grep -Fq '$env:HIMMELCTL_CACHE_DIR = $SavedCacheDir' "$SCRIPTS/test-uninstall.ps1"; then
    pass "P2 test-uninstall.ps1 redirects the cache dir under \$Tmp and restores the operator's value"
else fail "P2 test-uninstall.ps1 lets the wet default runs inherit the operator's HIMMELCTL_CACHE_DIR"; fi

# ── P3 — the ps1 suite expects the new incomplete-purge exit (tests 8 + 9) ──
# A -PurgeState run that skips the purge because the bridge may still be
# running now exits 2 with an INCOMPLETE summary; the suite must say so, not
# assert the old exit 0. Source-level (no pwsh here); the nightly is the proof.
# shellcheck disable=SC2016 # the PowerShell $-variables are literal grep patterns
if grep -Fq "Assert-Rc 'kill-failure run is INCOMPLETE (exit 2)' 2 \$script:Rc" "$SCRIPTS/test-uninstall.ps1" \
    && grep -Fq "Assert-Rc 'bun-missing run is INCOMPLETE (exit 2)' 2 \$script:Rc" "$SCRIPTS/test-uninstall.ps1"; then
    pass "P3 test-uninstall.ps1 tests 8 + 9 expect exit 2 for a skipped purge"
else fail "P3 test-uninstall.ps1 still asserts exit 0 for a purge skipped under a possibly-running bridge"; fi
if [ "$(grep -Fc '[2/7] telegram pairing + bridge state: not purged' "$SCRIPTS/test-uninstall.ps1")" -ge 2 ] \
    && [ "$(grep -Fc 'Uninstall INCOMPLETE' "$SCRIPTS/test-uninstall.ps1")" -ge 2 ]; then
    pass "P3 test-uninstall.ps1 tests 8 + 9 assert the not-purged and INCOMPLETE lines"
else fail "P3 test-uninstall.ps1 tests 8 + 9 do not assert the not-purged / INCOMPLETE output"; fi
if ! grep -Fq "Assert-Rc 'kill-failure run still exits 0'" "$SCRIPTS/test-uninstall.ps1" \
    && ! grep -Fq "Assert-Rc 'bun-missing run still exits 0'" "$SCRIPTS/test-uninstall.ps1"; then
    pass "P3 the stale 'still exits 0' assertions are gone"
else fail "P3 test-uninstall.ps1 keeps a stale 'still exits 0' assertion for tests 8/9"; fi

# ── L2 — the loader checks each required row's structural contract ─────────
# Kind/step each valid on their own is not enough: a cache row of path '-' and
# step '-' targets the literal '-' and reports the real cache absent.
fixture l2
sed -e $'s/\t{HOME}\\/.claude\\/himmel\t8\t/\t-\t-\t/' "$MANIFEST" > "$FX/l2-nopath-manifest.tsv"
sed -e $'s/^user-settings\tcode\tclaude-settings\tsettings/user-settings\tcode\tclaude-settings\tdir/' "$MANIFEST" > "$FX/l2-kind-manifest.tsv"
sed -e $'s/^scheduled-jobs\tcode\tscheduler\tjobs\t-\t-\t3/scheduled-jobs\tcode\tscheduler\tjobs\t-\t-\t-/' "$MANIFEST" > "$FX/l2-step-manifest.tsv"
sed -e $'s/\tHIMMELCTL_CACHE_DIR\t/\tBAD-NAME\t/' "$MANIFEST" > "$FX/l2-env-manifest.tsv"
for l2_case in "nopath:row 'himmelctl-cache' violates its contract" \
    "kind:row 'user-settings' violates its contract" \
    "step:row 'scheduled-jobs' violates its contract" \
    "env:row 'himmelctl-cache' has env 'BAD-NAME'"; do
    l2_key="${l2_case%%:*}"; l2_want="${l2_case#*:}"
    out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$FX/l2-$l2_key-manifest.tsv" \
        bash "$CLI" --yes --skip-tasks --skip-plugins </dev/null 2>&1); rc=$?
    assert_rc "L2 $l2_key: contract violation refused" 2 "$rc"
    assert_has "L2 $l2_key: names the defect" "$l2_want" "$out"
done
assert_exists "L2 nothing removed on refusal" "$FX_HOME/.claude/himmel/install-profile.json"

# ── R2 — read-back covers statusLine and env, not only hooks ───────────────
# Every unwire helper is a no-op (rc=0). The settings hold a himmel statusLine
# and the three himmel env keys but no hook: the read-back must still refuse
# (HIMMEL-3332 S6: via the always-checked env.HIMMEL_REPO/LUNA_VAULT_PATH
# rows -- statusLine and env.HANDOVER_DIR are two of the six overwrite-prone
# rows and, with no ledger here, are KEPT rather than attempted).
fixture r2
R2REPO="$FX/repo"
mkdir -p "$R2REPO/scripts/lib" "$R2REPO/scripts/machine-setup"
cp "$SCRIPTS"/lib/unwire-*.sh "$R2REPO/scripts/lib/"
for r2_h in statusline himmel-repo luna-vault handover-dir pretooluse-hooks; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$R2REPO/scripts/lib/unwire-$r2_h.sh"
done
R2_JSON='{"statusLine":{"type":"command","command":"bash /x/scripts/where-are-we/statusline.sh"},"env":{"HIMMEL_REPO":"/x","LUNA_VAULT_PATH":"/v","HANDOVER_DIR":"/h","CLAUDE_HUD_ALLOW_EXTRA_CMD":"1"}}'
printf '%s\n' "$R2_JSON" > "$FX_HOME/.claude/settings.json"
printf '{}\n' > "$FX_PROJ/.claude/settings.json"
out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_REPO_ROOT="$R2REPO" \
    bash "$CLI" --yes --skip-tasks --skip-plugins --skip-hooks </dev/null 2>&1); rc=$?
assert_rc "R2 no-op unwire leaving statusLine + env fails the uninstall" 2 "$rc"
# HIMMEL-3332 S6: with no ledger for this $HOME, statusLine and
# env.HANDOVER_DIR are two of the six overwrite-prone rows -- they are KEPT
# on purpose (masked out of the read-back) rather than attempted and then
# caught still-wired; the no-op helper still leaves env.HIMMEL_REPO
# (untouched by the six-row protection) genuinely wired, which is what
# still fails this run.
assert_has "R2 names the leftover statusLine as kept (no ledger)" "kept (no ledger): statusLine" "$out"
assert_has "R2 names the leftover env.HIMMEL_REPO" "STILL WIRED: env.HIMMEL_REPO" "$out"
assert_has "R2 names the leftover env.HANDOVER_DIR as kept (no ledger)" "kept (no ledger): env.HANDOVER_DIR" "$out"
assert_not_has "R2 the intentionally retained env key is not flagged" "CLAUDE_HUD_ALLOW_EXTRA_CMD" "$out"
assert_not_has "R2 never claims completion" "Uninstall complete." "$out"
# Control: the real (non-no-op) helpers clear env.HIMMEL_REPO/LUNA_VAULT_PATH;
# with no ledger, statusLine/env.HANDOVER_DIR are still kept on purpose, the
# retained key survives either way, and the run still completes rc=0.
fixture r2b
printf '%s\n' "$R2_JSON" > "$FX_HOME/.claude/settings.json"
printf '{}\n' > "$FX_PROJ/.claude/settings.json"
run_uninstall --yes --skip-tasks --skip-plugins --skip-hooks
assert_rc "R2 control: real helpers clear env.HIMMEL_REPO/LUNA_VAULT_PATH" 0 "$rc"
assert_has "R2 control: verified line printed" "verified: no himmel wiring left in $FX_HOME/.claude/settings.json" "$out"
assert_has "R2 control: the retained env key survives" "CLAUDE_HUD_ALLOW_EXTRA_CMD" "$(cat "$FX_HOME/.claude/settings.json")"

# ── K6 — the step-8 PLAN says what step 8 does, per the cache row's class ───
fixture k6
sed -e $'s/^himmelctl-cache\tcode/himmelctl-cache\tkeep/' "$MANIFEST" > "$FX/k6-keep.tsv"
sed -e $'s/^himmelctl-cache\tcode/himmelctl-cache\tstate/' "$MANIFEST" > "$FX/k6-state.tsv"
k6_run() { # <manifest> <args...>
    k6_m="$1"; shift
    out=$(cd "$FX_PROJ" && HOME="$FX_HOME" PATH="$STUB:$HBIN" HIMMEL_UNINSTALL_MANIFEST="$k6_m" \
        bash "$CLI" --dry-run --skip-tasks --skip-plugins "$@" </dev/null 2>&1); rc=$?
    k6_plan=$(printf '%s\n' "$out" | sed -n '/^This will:/,/^Footprint/p')
}
k6_run "$FX/k6-keep.tsv"
assert_rc "K6 dry-run with the cache row re-classed keep" 0 "$rc"
assert_not_has "K6 keep: the plan does not announce cache removal" "REMOVE the himmelctl cache" "$k6_plan"
assert_has "K6 keep: the plan says keep by manifest class" "8. keep the himmelctl cache + state (manifest class keep)" "$k6_plan"
k6_run "$FX/k6-state.tsv"
assert_not_has "K6 state without --purge-state: the plan does not announce removal" "REMOVE the himmelctl cache" "$k6_plan"
assert_has "K6 state without --purge-state: the plan says keep" "8. keep the himmelctl cache + state (manifest class state)" "$k6_plan"
k6_run "$FX/k6-state.tsv" --purge-state
assert_has "K6 state with --purge-state: the plan removes" "8. REMOVE the himmelctl cache + state" "$k6_plan"
k6_run "$MANIFEST"
assert_has "K6 control: the shipped code-class cache row is removed" "8. REMOVE the himmelctl cache + state" "$k6_plan"

# ── K7 — the step-2 PLAN, without --purge-state, says per row what step 2 does ─
# A row re-classed keep is never touched, so the plan must not tell the operator
# that --purge-state would remove it (the old else-branch did, for both rows).
sed -e $'s/^telegram-channel\tstate/telegram-channel\tkeep/' "$MANIFEST" > "$FX/k7-mixed.tsv"
sed -e $'s/^telegram-channel\tstate/telegram-channel\tkeep/' \
    -e $'s/^telegram-bridge\tstate/telegram-bridge\tkeep/' "$MANIFEST" > "$FX/k7-keep.tsv"
k6_run "$FX/k7-mixed.tsv"
assert_rc "K7 dry-run with the channel row re-classed keep" 0 "$rc"
assert_has "K7 mixed: the keep row is named as never touched" "keep   $FX_HOME/.claude/channels/telegram (manifest class keep)" "$k6_plan"
assert_has "K7 mixed: the state row is named as removed by --purge-state" "keep   $FX_HOME/.claude/handover/bridge (manifest class state; --purge-state removes it)" "$k6_plan"
assert_not_has "K7 mixed: no blanket claim that --purge-state removes both" "pass --purge-state to remove it" "$k6_plan"
k6_run "$FX/k7-keep.tsv"
assert_has "K7 both keep: the channel row says keep by class" "keep   $FX_HOME/.claude/channels/telegram (manifest class keep)" "$k6_plan"
assert_has "K7 both keep: the bridge row says keep by class" "keep   $FX_HOME/.claude/handover/bridge (manifest class keep)" "$k6_plan"
assert_not_has "K7 both keep: --purge-state is not offered as a way to remove them" "pass --purge-state to remove it" "$k6_plan"
k6_run "$MANIFEST"
assert_has "K7 control: the shipped state rows still offer --purge-state" "2. KEEP telegram pairing + bridge state (pass --purge-state to remove it):" "$k6_plan"

# ── DOC2 — a guarded --purge-state is documented as conditional ────────────
if [ "$(grep -c 'still running' "$ROOT/docs/setup/updating.md")" -ge 2 ]; then pass "DOC2 updating.md qualifies --purge-state at both sites"
else fail "DOC2 updating.md does not qualify --purge-state with the running-supervisor guard at both sites"; fi
if grep -q 'still running' "$ROOT/docs/setup/install.md"; then pass "DOC2 install.md qualifies --purge-state"
else fail "DOC2 install.md does not qualify --purge-state with the running-supervisor guard"; fi

# ── DOC — the install doc and the README link the command ──────────────────
if grep -Eq 'himmelctl.*uninstall.*--dry-run|uninstall --dry-run' "$ROOT/docs/setup/install.md"; then pass "DOC install.md documents uninstall --dry-run"
else fail "DOC install.md does not document uninstall --dry-run"; fi
if grep -q 'purge-state' "$ROOT/docs/setup/install.md"; then pass "DOC install.md documents --purge-state"
else fail "DOC install.md does not document --purge-state"; fi
if grep -Eq 'uninstall --dry-run' "$ROOT/README.md"; then pass "DOC README links the dry-run uninstall"
else fail "DOC README does not mention uninstall --dry-run"; fi

# HIMMEL-3415: an unset or empty $HOME is refused (rc=3) before anything else,
# dry-run included — every {HOME} target would otherwise be root-relative.
# Kept here, not in test-uninstall-real-home-runtime.sh: this suite never lifts
# the wet-run fence, and a file that drops HOME may not (the static caller guard).
out=$(env -u HOME bash "$CLI" --dry-run </dev/null 2>&1); rc=$?
assert_rc "HOME unset is refused" 3 "$rc"
assert_has "HOME unset names the check" "real-home check (HOME-unset)" "$out"
out=$(env HOME= bash "$CLI" --dry-run </dev/null 2>&1); rc=$?
assert_rc "HOME empty is refused" 3 "$rc"
assert_has "HOME empty names the check" "real-home check (HOME-unset)" "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then echo "test-uninstall-ux: all passed"; exit 0; fi
echo "test-uninstall-ux: $FAILED failed"
exit 1
