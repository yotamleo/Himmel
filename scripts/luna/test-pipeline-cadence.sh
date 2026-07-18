#!/usr/bin/env bash
# Smoke test for scripts/luna/pipeline-cadence.sh (HIMMEL-255 schtasks
# path + HIMMEL-265 cron path + HIMMEL-357 daily harvest+triage leg +
# HIMMEL-362 XML-based schtasks create carrying StartWhenAvailable).
#
# Three cadence tasks are armed: HIMMEL-Pipeline-Harvest (daily 02:00 ->
# /harvest-clips + /triage-clips), HIMMEL-Pipeline-Synthesize (daily 03:00
# -> /synthesize-clips + /archive-clips), HIMMEL-Pipeline-Health (weekly
# Sun 04:00 -> /obsidian-health). Each leg launches with an explicit
# --model pin (harvest/synth=sonnet, health=haiku — HIMMEL-506). The
# harvest leg is exercised alongside synth/health throughout the dry-run
# / arm / shape / status / dedup / force / disarm / rollback tests below.
#
# Strategy: replace the scheduler with a fake — schtasks via the
# PIPELINE_SCHTASKS seam (records /create args + simulates /query and
# /delete from a state dir), crontab via the PIPELINE_CRONTAB seam (a
# state-file crontab that supports -l and - install); point
# PIPELINE_BAT_DIR at a temp dir so the runners (.bat/.sh) are
# inspectable; put a fake `claude` first on PATH. The cron suite runs
# on EVERY platform (the POSIX code path is forced with an OSTYPE
# override, exactly like the old non-Windows-stub test); the schtasks
# suite stays Windows-only (cmd_arm needs cygpath).
#
# Cron suite covers (C*):
#   C1.  status with empty crontab ("no crontab for user") -> not armed.
#   C2.  arm --dry-run prints runner bodies + both entries, touches nothing.
#   C3.  arm installs both marker-tagged entries (00 03 * * 0 /
#        00 04 1 * *) + executable runner .sh files; pre-existing
#        unrelated crontab lines survive.
#   C4.  Runner .sh is interactive-claude shaped: bounded `< /dev/null`,
#        chained synthesize->archive prompt, NO -p/--print/--bg, log
#        rotation + fire stamp.
#   C5.  status after arm -> both ARMED (+ run-log line).
#   C6.  Re-arm without --force -> exit 3 (dedup), nothing duplicated.
#   C7.  Re-arm --force + flag overrides -> entries replaced, unrelated
#        line still intact, still exactly two markers.
#   C8.  disarm removes entries + runners, keeps unrelated lines;
#        second disarm is a no-op (rc 0).
#   C9.  Fail-closed: crontab -l fails (rc 1 + stderr) -> arm/status
#        exit 2; disarm exits 2 and keeps the runners.
#   C9b. Crashed crontab -l (rc=255, EMPTY stderr) is NOT trusted-empty.
#   C10. crontab install failure on fresh arm -> rc 4; no runner promoted
#        to its final path, no staged .tmp litter.
#   C10b. --force re-arm with failing install -> rc 4; OLD runners + OLD
#        entries fully intact (no new-config half-state).
#   C10c. disarm with failing install -> rc 4; entries + runners kept
#        (install-succeeds-BEFORE-rm ordering invariant).
#   C11. Hostile vault dirname + runner dir (& $ space %) land %q/\%-
#        escaped in runner + entry — no fire-time injection.
#   C15. Armed runner .sh EXECUTES end-to-end (recording claude stub,
#        hostile dirnames): log created with stub output + [fired] stamp,
#        prompt arrives as a SINGLE argv, cwd resolves to the vault,
#        second fire rotates .log -> .log.prev, status shows a real
#        mtime (date -r / stat -f fallback, not '?').
#   C12. Validation (shared with the schtasks path) rejects bad input
#        on the cron path too -> rc 1.
#   C13. Unknown platform (OSTYPE=beos) -> exit 2.
#   C14. Dry-run disarm with armed entries prints DRY tail, touches
#        nothing.
#
# schtasks suite covers:
#   1.  Missing/unknown subcommand -> exit 1.
#   2.  Invalid --synth-time / --synth-day / --health-day / vault -> exit 1.
#   3.  status with empty scheduler -> both tasks "not armed".
#   4.  arm --dry-run prints the XML creates (trigger + StartWhenAvailable)
#       + .bat bodies, registers nothing.
#   5.  arm registers all three tasks from XML carrying StartWhenAvailable
#       (HIMMEL-362) at the operator-decision defaults (DAILY 02:00, WEEKLY
#       SUN 03:00, MONTHLY 1 04:00) + writes the .bats.
#   6.  Armed .bats are interactive-claude shaped: bounded `< NUL`,
#       chained synthesize->archive prompt, NO -p/--print/--bg.
#   7.  status after arm -> both ARMED.
#   7b. status surfaces the rotated .log.prev (mtime + last line) next
#       to the current .log.
#   8.  Re-arm without --force -> exit 3 (dedup), nothing duplicated.
#   9.  Re-arm --force + flag overrides -> tasks replaced with overrides.
#   10. disarm removes both tasks + .bats; second disarm is a no-op (rc 0).
#   11. cmd_escape: hostile-but-legal vault dirname (% & ^) lands escaped
#       in the .bat (%%, ^&, ^^) — no fire-time injection.
#   12. Half-arm: last /create (health) fails -> rc 4, harvest + synth
#       rolled back, no task state left.
#   12b. Mid-create (synth) fails -> rc 4, harvest rolled back, health
#        never attempted, no task state left.
#   13. Fail-closed dedup: /query listing fails (rc 1 + stderr) -> arm
#       exits 2 instead of treating the scheduler as empty.
#   14. Disarm under /query failure -> nonzero exit, .bats NOT deleted,
#       manual schtasks /delete escape-hatch hint printed.
#   14b. Crashed /query (rc=255, EMPTY stderr) is NOT trusted not-found:
#        disarm exits 2, .bats kept (only rc=1 may read as "not armed").
#   14c. status under /query failure -> rc 2 (exit-code contract).
#   14d. Dry-run disarm with armed tasks prints a closing DRY summary,
#        deletes nothing.
#   14e. NOT_FOUND_RE alternation 1: rc=1 + "cannot find the file
#        specified" stderr (the fake's default not-found) classifies as
#        trusted not-found.
#   14f. NOT_FOUND_RE alternation 2: rc=1 + 'The specified task name
#        "..." does not exist' stderr classifies as trusted not-found.
#   14g. Silent rc=1 (EMPTY stderr) is NOT trusted not-found: status
#        fail-closes with rc 2 (real schtasks always emits the message).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/pipeline-cadence.sh"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Shared fixtures ------------------------------------------------------------

# Fake claude on PATH (arm resolves it via `command -v claude`).
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/bin/claude"
chmod +x "$TMP_ROOT/bin/claude"
export PATH="$TMP_ROOT/bin:$PATH"

# HIMMEL-386: redirect the workspace-trust pre-seed (cmd_arm / cron_arm now
# pre-trust the vault) at a throwaway config so non-dry-run arm tests never
# mutate the operator's real ~/.claude.json.
export WORKSPACE_TRUST_CONFIG="$TMP_ROOT/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP_ROOT/flow-runs.jsonl"

VAULT="$TMP_ROOT/vault"
mkdir -p "$VAULT"

# Same pattern the no-headless-claude pre-commit gate uses (HIMMEL-128).
HEADLESS_RE='(^|[^A-Za-z0-9_-])claude[[:space:]]+(-p|--print|--bg)($|[^A-Za-z0-9_-])'

# ============================================================================
# xml_escape unit (HIMMEL-362) — the one non-trivial new string transform.
# Pure + platform-agnostic, so it runs on EVERY platform: extract the
# function from the script and call it directly. Pins the &-first ordering
# (escaping & last would double-escape the &lt;/&gt; entities) so a
# BAT_DIR path containing & / < / > yields well-formed task XML.
# ============================================================================
echo "TEST: xml_escape escapes & < > with & ordered first"
xesc=$( { sed -n '/^xml_escape()/,/^}/p' "$SCRIPT"; echo "xml_escape 'a & b < c > d'"; } | bash )
assert_contains "xml_escape produces well-formed entities (& first)" "a &amp; b &lt; c &gt; d" "$xesc"
assert_not_contains "xml_escape leaves no bare ampersand" "a & b" "$xesc"

# ============================================================================
# default_vault unit (HIMMEL-642) — cross-platform default --vault resolution.
# Pure (reads only env + cygpath), so it runs on EVERY platform: extract the
# function from the script and call it under controlled env. Pins: (1)
# LUNA_VAULT_PATH wins; (2) POSIX shape (USERPROFILE unset) is $HOME-based,
# unchanged; (3) on Windows Git-Bash the Windows profile (USERPROFILE via
# cygpath) wins over the MSYS $HOME — the exact failure the bare $HOME default
# hit (vault resolved to /home/<user>/Documents/luna, not the real profile).
# ============================================================================
echo "TEST: default_vault resolves the cross-platform default vault"
# default_vault delegates the home part to resolve_user_home (HIMMEL-645), so
# extract BOTH functions for the standalone call.
DV_SRC="$(sed -n '/^resolve_user_home()/,/^}/p' "$SCRIPT"; sed -n '/^default_vault()/,/^}/p' "$SCRIPT")"
run_dv() { env "$@" bash -c "$DV_SRC"$'\n'"default_vault"; }

# USERPROFILE set too, so this proves LUNA_VAULT_PATH wins even when the
# Windows branch would otherwise fire — platform-independently (on POSIX
# USERPROFILE would otherwise be unset and only the $HOME branch tested).
dv_a=$(run_dv LUNA_VAULT_PATH="/some/explicit/vault" USERPROFILE='C:\Users\x')
assert_contains "default_vault honors LUNA_VAULT_PATH" "/some/explicit/vault" "$dv_a"
assert_not_contains "LUNA_VAULT_PATH used verbatim (no Documents/luna append)" "Documents/luna" "$dv_a"

dv_b=$(run_dv -u LUNA_VAULT_PATH -u USERPROFILE HOME="/posix/home")
assert_contains "default_vault POSIX shape is \$HOME/Documents/luna" "/posix/home/Documents/luna" "$dv_b"

# Last-resort fallback: HOME + USERPROFILE both unset -> /tmp (the documented
# floor). Locks the ${HOME:-${USERPROFILE:-/tmp}} chain against an accidental
# drop of the /tmp guard.
dv_d=$(run_dv -u LUNA_VAULT_PATH -u USERPROFILE -u HOME)
assert_contains "default_vault falls back to /tmp when HOME+USERPROFILE unset" "/tmp/Documents/luna" "$dv_d"

# cygpath present but FAILING on the input -> fall back to the raw USERPROFILE
# (the `cygpath -u … || printf '%s' "$USERPROFILE"` arm). Inject a stub cygpath
# that exits nonzero so this runs platform-independently (the stub IS the only
# cygpath on POSIX, and shadows the real one on Windows).
DV_FAKE_CYGPATH="$TMP_ROOT/fake-cygpath-fail"
mkdir -p "$DV_FAKE_CYGPATH"
printf '#!/usr/bin/env bash\nexit 1\n' > "$DV_FAKE_CYGPATH/cygpath"
chmod +x "$DV_FAKE_CYGPATH/cygpath"
# PATH entries must be POSIX-style for MSYS `command -v` to search them
# ($TMP_ROOT is the cygpath -m mixed C:/ form). On POSIX it's already POSIX.
DV_FAKE_PATH="$DV_FAKE_CYGPATH"
if command -v cygpath >/dev/null 2>&1; then DV_FAKE_PATH="$(cygpath -u "$DV_FAKE_CYGPATH")"; fi
dv_e=$(run_dv -u LUNA_VAULT_PATH -u HOME USERPROFILE='C:\Users\x' PATH="$DV_FAKE_PATH:$PATH")
assert_contains "default_vault falls back to raw USERPROFILE when cygpath -u fails" 'C:\Users\x/Documents/luna' "$dv_e"

if command -v cygpath >/dev/null 2>&1; then
    dv_c=$(run_dv -u LUNA_VAULT_PATH USERPROFILE='C:\Users\testuser' HOME="/home/msysuser")
    assert_contains "default_vault prefers Windows profile over MSYS \$HOME" "$(cygpath -u 'C:\Users\testuser')/Documents/luna" "$dv_c"
    assert_not_contains "default_vault does NOT use the MSYS \$HOME on Windows" "/home/msysuser" "$dv_c"
else
    echo "  SKIP: default_vault Windows-profile case (cygpath absent — POSIX host)"
fi

# ============================================================================
# resolve_user_home unit (HIMMEL-645) — the shared home resolver that ALSO
# backs the BAT_DIR default ($(resolve_user_home)/.claude/pipeline-cadence).
# Pins the same cross-platform contract directly on the helper so a BAT_DIR
# regression (runners landing under the MSYS home on Windows) is caught even
# though BAT_DIR itself is computed at script load.
# ============================================================================
echo "TEST: resolve_user_home resolves the cross-platform user home"
RUH_SRC="$(sed -n '/^resolve_user_home()/,/^}/p' "$SCRIPT")"
run_ruh() { env "$@" bash -c "$RUH_SRC"$'\n'"resolve_user_home"; }

ruh_posix=$(run_ruh -u USERPROFILE HOME="/posix/home")
assert_contains "resolve_user_home POSIX shape is \$HOME" "/posix/home" "$ruh_posix"
assert_not_contains "resolve_user_home returns home only (no Documents append)" "Documents" "$ruh_posix"

ruh_floor=$(run_ruh -u USERPROFILE -u HOME)
assert_contains "resolve_user_home floor is /tmp when HOME+USERPROFILE unset" "/tmp" "$ruh_floor"

if command -v cygpath >/dev/null 2>&1; then
    ruh_win=$(run_ruh USERPROFILE='C:\Users\testuser' HOME="/home/msysuser")
    assert_contains "resolve_user_home prefers Windows profile over MSYS \$HOME" "$(cygpath -u 'C:\Users\testuser')" "$ruh_win"
    assert_not_contains "resolve_user_home does NOT use the MSYS \$HOME on Windows" "/home/msysuser" "$ruh_win"
else
    echo "  SKIP: resolve_user_home Windows-profile case (cygpath absent — POSIX host)"
fi

# ============================================================================
# POSIX (cron) suite — HIMMEL-265. Runs on EVERY platform: the cron code
# path is forced via an OSTYPE override + the PIPELINE_CRONTAB seam.
# ============================================================================

CSTATE="$TMP_ROOT/cron-state"
mkdir -p "$CSTATE"

# Fake crontab: persists the installed tab at $CSTATE/crontab. Mimics
# real crontab signatures: -l with no tab installed prints "no crontab
# for <user>" to stderr + rc=1; `crontab -` installs from stdin.
# Failure-injection seams via marker files (see each test).
FAKE_CRONTAB="$TMP_ROOT/crontab-fake.sh"
cat >"$FAKE_CRONTAB" <<FAKE
#!/usr/bin/env bash
CSTATE="$CSTATE"
FAKE
cat >>"$FAKE_CRONTAB" <<'FAKE'
case "${1:-}" in
    -l)
        # `touch $CSTATE/fail-list`: -l fails like a permission error —
        # rc=1 with stderr that is NOT the no-crontab signature.
        if [ -e "$CSTATE/fail-list" ]; then
            echo "crontab: must be privileged to use -l" >&2
            exit 1
        fi
        # `touch $CSTATE/fail-list-255`: crashed tool — rc=255 with
        # EMPTY stderr. Must NOT be trusted as "empty crontab".
        if [ -e "$CSTATE/fail-list-255" ]; then
            exit 255
        fi
        if [ -f "$CSTATE/crontab" ]; then
            cat "$CSTATE/crontab"
        else
            echo "no crontab for fakeuser" >&2
            exit 1
        fi
        ;;
    -)
        # `touch $CSTATE/fail-write`: install from stdin fails.
        if [ -e "$CSTATE/fail-write" ]; then
            echo "crontab: error writing new crontab" >&2
            exit 1
        fi
        cat > "$CSTATE/crontab"
        ;;
    *)
        echo "crontab-fake: unsupported argv: $*" >&2
        exit 64
        ;;
esac
FAKE
chmod +x "$FAKE_CRONTAB"

CRON_DIR="$TMP_ROOT/cron-runners"

run_cron() {
    env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
        PIPELINE_BAT_DIR="$CRON_DIR" bash "$SCRIPT" "$@"
}

# Test C1: status with no crontab installed ----------------------------------

echo "TEST: cron status with no crontab installed"
out=$(run_cron status)
assert_contains "cron harvest not armed"    "not armed  HIMMEL-Pipeline-Harvest"    "$out"
assert_contains "cron synthesize not armed" "not armed  HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "cron health not armed"     "not armed  HIMMEL-Pipeline-Health"     "$out"

# Test C12: shared validation wired into the cron path -----------------------

echo "TEST: cron arm rejects invalid input (shared validation)"
rc=0; out=$(run_cron arm --vault "$VAULT" --harvest-time 24:61 2>&1) || rc=$?
assert_rc "cron bad --harvest-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --synth-time 25:00 2>&1) || rc=$?
assert_rc "cron bad --synth-time -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --health-day 31 2>&1) || rc=$?
assert_rc "cron bad --health-day (31) -> rc 1" 1 "$rc"
rc=0; out=$(run_cron arm --vault "$VAULT" --ig-limit abc 2>&1) || rc=$?
assert_rc "cron bad --ig-limit (abc) -> rc 1" 1 "$rc"
assert_contains "cron bad --ig-limit message names flag" "--ig-limit must be a non-negative integer" "$out"
# HIMMEL-506: --synth-day removed (synthesize is daily); --health-day is now
# a weekday MON..SUN (a numeric 1-28 is the old monthly semantics, rejected
# with a pointer); model pins must be non-empty.
rc=0; out=$(run_cron arm --vault "$VAULT" --synth-day mon 2>&1) || rc=$?
assert_rc "cron removed --synth-day -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "cron --synth-day message points at daily" "daily now" "$out"
rc=0; out=$(run_cron arm --vault "$VAULT" --health-day 15 2>&1) || rc=$?
assert_rc "cron numeric --health-day (15) -> rc 1 (now weekday)" 1 "$rc"
assert_contains "cron numeric --health-day message points at MON..SUN" "MON..SUN" "$out"
rc=0; out=$(run_cron arm --vault "$VAULT" --health-model "" 2>&1) || rc=$?
assert_rc "cron empty --health-model -> rc 1 (HIMMEL-506)" 1 "$rc"

# Test C2: arm --dry-run touches nothing --------------------------------------

echo "TEST: cron arm --dry-run prints plan, installs nothing"
out=$(run_cron arm --vault "$VAULT" --dry-run)
assert_contains "dry-run daily harvest entry" "00 02 * * *" "$out"
assert_contains "dry-run daily synth entry"   "00 03 * * *" "$out"
assert_contains "dry-run weekly health entry" "00 04 * * 0" "$out"
assert_contains "dry-run harvest marker" "# HIMMEL-Pipeline-Harvest" "$out"
assert_contains "dry-run synth marker"  "# HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "dry-run shows bounded run" "< /dev/null" "$out"
assert_contains "dry-run pre-trusts vault (HIMMEL-386)" "would pre-trust workspace '$VAULT'" "$out"
if [ ! -f "$CSTATE/crontab" ]; then
    pass "dry-run installed no crontab"
else
    fail "dry-run installed a crontab" "$(cat "$CSTATE/crontab")"
fi
if [ ! -d "$CRON_DIR" ]; then
    pass "dry-run wrote no runner .sh"
else
    fail "dry-run wrote runners" "$(ls "$CRON_DIR")"
fi

# Test C3: arm installs marker-tagged entries, preserves unrelated lines ------

echo "TEST: cron arm installs entries with defaults, preserves unrelated lines"
printf '5 5 * * * /usr/bin/true # keep-me\n' > "$CSTATE/crontab"
out=$(run_cron arm --vault "$VAULT")
assert_contains "cron arm banner" "PIPELINE CADENCE ARMED" "$out"
# HIMMEL-386: the real (non-dry-run) arm pre-trusts the vault in the (temp) config.
if command -v node >/dev/null 2>&1; then
    trust=$(WT_F="$WORKSPACE_TRUST_CONFIG" WT_K="$VAULT" node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.env.WT_F,"utf8"));process.stdout.write(String(j.projects&&j.projects[process.env.WT_K]&&j.projects[process.env.WT_K].hasTrustDialogAccepted))}catch(e){process.stdout.write("ERR")}')
    assert_contains "cron arm pre-trusts vault in config" "true" "$trust"
fi
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "daily harvest entry 02:00"  "00 02 * * *" "$tab"
assert_contains "daily synth entry 03:00"    "00 03 * * *" "$tab"
assert_contains "weekly health entry SUN 04:00" "00 04 * * 0" "$tab"
assert_contains "harvest entry marker-tagged" "# HIMMEL-Pipeline-Harvest"     "$tab"
assert_contains "synth entry marker-tagged"  "# HIMMEL-Pipeline-Synthesize" "$tab"
assert_contains "health entry marker-tagged" "# HIMMEL-Pipeline-Health"     "$tab"
assert_contains "harvest entry fires the runner" "pipeline-harvest.sh"    "$tab"
assert_contains "synth entry fires the runner"  "pipeline-synthesize.sh" "$tab"
assert_contains "health entry fires the runner" "pipeline-health.sh"     "$tab"
assert_contains "unrelated entry preserved" "keep-me" "$tab"
if [ -x "$CRON_DIR/pipeline-harvest.sh" ] && [ -x "$CRON_DIR/pipeline-synthesize.sh" ] && [ -x "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files written + executable"
else
    fail "runner .sh files missing or not executable" "$(ls -l "$CRON_DIR" 2>/dev/null || true)"
fi

# Test C4: runner .sh is interactive-claude shaped -----------------------------

echo "TEST: runner .sh is bounded interactive claude (no headless flags)"
harvest_sh=$(cat "$CRON_DIR/pipeline-harvest.sh" 2>/dev/null || echo MISSING)
synth_sh=$(cat "$CRON_DIR/pipeline-synthesize.sh" 2>/dev/null || echo MISSING)
health_sh=$(cat "$CRON_DIR/pipeline-health.sh" 2>/dev/null || echo MISSING)
assert_contains "harvest runner stamps the format version (HIMMEL-588)" "# himmel-cadence-runner-format: 4" "$harvest_sh"
assert_contains "synth runner stamps the format version (HIMMEL-588)"   "# himmel-cadence-runner-format: 4" "$synth_sh"
assert_contains "health runner stamps the format version (HIMMEL-588)"  "# himmel-cadence-runner-format: 4" "$health_sh"
assert_contains "harvest runner cds into vault" "cd $VAULT || exit 1" "$harvest_sh"
assert_contains "harvest runner runs /harvest-clips" "/harvest-clips" "$harvest_sh"
assert_contains "harvest runner chains /triage-clips" "/triage-clips" "$harvest_sh"
# The sh runner embeds the prompt via printf %q, which backslash-escapes
# spaces - strip the escapes before multi-word prompt assertions (HIMMEL-798).
harvest_sh_plain=${harvest_sh//\\/}
assert_contains "harvest runner chains /ig-media-enrich default limit" "/ig-media-enrich --limit 10" "$harvest_sh_plain"
assert_contains "harvest runner fail-opens ig-media-enrich" "must not abort" "$harvest_sh_plain"
assert_contains "harvest runner bounded run"         "< /dev/null"    "$harvest_sh"
assert_contains "synth runner cds into vault" "cd $VAULT || exit 1" "$synth_sh"
assert_contains "synth runner runs /synthesize-clips" "/synthesize-clips" "$synth_sh"
assert_contains "synth runner chains /archive-clips"  "/archive-clips"    "$synth_sh"
assert_contains "synth runner bounded run"            "< /dev/null"       "$synth_sh"
# shellcheck disable=SC2016  # literal $log needles — the runner expands them at fire time
assert_contains "synth runner rotates the log" 'mv -f "$log" "$log.prev"' "$synth_sh"
assert_contains "synth runner stamps every fire" '[fired' "$synth_sh"
# shellcheck disable=SC2016
assert_contains "synth runner captures output to log" '>> "$log" 2>&1' "$synth_sh"
assert_contains "health runner runs /obsidian-health" "/obsidian-health" "$health_sh"
assert_contains "health runner bounded run"           "< /dev/null"      "$health_sh"
for what in harvest synth health; do
    body=$(eval "printf '%s' \"\$${what}_sh\"")
    if printf '%s\n' "$body" | grep -E "$HEADLESS_RE" >/dev/null 2>&1; then
        fail "$what runner is headless-shaped" "$body"
    else
        pass "$what runner has no headless claude flags"
    fi
done

# Test C4c: per-leg --model pins (HIMMEL-506) — every runner carries an
# explicit --model right after the binary so the cadence never inherits the
# operator's saved default tier. Defaults: harvest/synth=sonnet, health=haiku.
echo "TEST: cron runners carry the per-leg --model pin (HIMMEL-506)"
assert_contains "harvest runner pins --model sonnet" "--model sonnet" "$harvest_sh"
assert_contains "synth runner pins --model sonnet"   "--model sonnet" "$synth_sh"
assert_contains "health runner pins --model haiku"    "--model haiku"  "$health_sh"

echo "TEST: cron runners omit the print-only bg-wait ceiling override (HIMMEL-951)"
assert_not_contains "harvest runner omits bg-wait ceiling override" "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$harvest_sh"
assert_not_contains "synth runner omits bg-wait ceiling override"   "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$synth_sh"
assert_not_contains "health runner omits bg-wait ceiling override"  "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$health_sh"

# Test C4b: --settings injection wires the auto-approve hook (HIMMEL-575) -------

echo "TEST: cron runners inject --settings + fragment wires auto-approve hook"
assert_contains "harvest runner injects --settings" "--settings" "$harvest_sh"
assert_contains "synth runner injects --settings"   "--settings" "$synth_sh"
assert_contains "health runner injects --settings"  "--settings" "$health_sh"
assert_contains "harvest runner --settings targets the fragment" "cadence-settings.json" "$harvest_sh"
frag="$CRON_DIR/cadence-settings.json"
if [ -f "$frag" ]; then
    pass "settings fragment written to the runner dir"
else
    fail "settings fragment missing at $frag"
fi
frag_body=$(cat "$frag" 2>/dev/null || echo MISSING)
if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$frag_body" | jq -e '.hooks.PreToolUse[0].matcher == "Bash"' >/dev/null 2>&1; then
        pass "fragment is valid JSON wiring a PreToolUse Bash hook"
    else
        fail "fragment JSON does not wire a PreToolUse Bash hook" "$frag_body"
    fi
    hookcmd=$(printf '%s' "$frag_body" | jq -r '.hooks.PreToolUse[0].hooks[0].command' 2>/dev/null || echo "")
else
    hookcmd="$frag_body"
fi
assert_contains "fragment command references auto-approve-safe-bash" "auto-approve-safe-bash.sh" "$hookcmd"
# The referenced hook must be an ABSOLUTE path that actually exists on disk.
hookpath=$(printf '%s' "$hookcmd" | sed -n 's/^bash //p')
case "$hookpath" in
    /*|?:/*) pass "fragment references the hook by absolute path" ;;
    *)       fail "fragment hook path is not absolute" "$hookpath" ;;
esac
# Resolve to a checkable path (mixed C:/ form maps back through cygpath on Win).
hookpath_check="$hookpath"
if command -v cygpath >/dev/null 2>&1; then hookpath_check=$(cygpath -u "$hookpath" 2>/dev/null || printf '%s' "$hookpath"); fi
if [ -f "$hookpath_check" ]; then
    pass "fragment hook path resolves to a real file"
else
    fail "fragment hook path does not resolve to a file" "$hookpath_check"
fi

# HIMMEL-1036: the fragment force-enables obsidian-triage@himmel so the nightly
# cadence stays live even when the operator disables the plugin interactively.
if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$frag_body" | jq -e '.enabledPlugins["obsidian-triage@himmel"] == true' >/dev/null 2>&1; then
        pass "fragment force-enables obsidian-triage@himmel (HIMMEL-1036)"
    else
        fail "fragment does not force-enable obsidian-triage@himmel" "$frag_body"
    fi
else
    assert_contains "fragment force-enables obsidian-triage (HIMMEL-1036)" "obsidian-triage@himmel" "$frag_body"
fi

# Test C5: status after arm ----------------------------------------------------

echo "TEST: cron status reflects armed entries"
out=$(run_cron status)
assert_contains "cron harvest armed"    "ARMED      HIMMEL-Pipeline-Harvest"    "$out"
assert_contains "cron synthesize armed" "ARMED      HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "cron health armed"     "ARMED      HIMMEL-Pipeline-Health"     "$out"
assert_contains "cron status daily row mentions ig-media-enrich" "/ig-media-enrich" "$out"
assert_contains "cron status surfaces run log state" "run log" "$out"
# HIMMEL-506: status parses the --model pin back out of each runner so an
# armed-but-wrong-model cadence is visible. Scope each pin to its OWN status
# line — harvest and synth are both [model: sonnet], so a whole-output check
# would pass even if one leg's pin were wrong or missing.
harvest_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Harvest')
synth_line=$(printf '%s\n' "$out"   | grep 'HIMMEL-Pipeline-Synthesize')
health_line=$(printf '%s\n' "$out"  | grep 'HIMMEL-Pipeline-Health')
assert_contains "cron harvest status line armed"      "ARMED"           "$harvest_line"
assert_contains "cron harvest status shows model pin" "[model: sonnet]" "$harvest_line"
assert_contains "cron synth status shows model pin"   "[model: sonnet]" "$synth_line"
assert_contains "cron health status shows model pin"  "[model: haiku]"  "$health_line"

# Test C5b: status_log rotated-log message (#299) ------------------------------
# When .log is absent but .log.prev is present (post-rotation window before
# a fresh fire creates the new .log), the message must reflect rotation —
# NOT "absent — task has not fired yet" which is actively misleading.

echo "TEST: status_log shows 'rotated' when .log absent but .log.prev present"
printf 'prev run output\n' > "$CRON_DIR/pipeline-synthesize.log.prev"
rm -f "$CRON_DIR/pipeline-synthesize.log"
out=$(run_cron status)
assert_contains "cron rotated-log message says rotated" "rotated" "$out"
# The synth log line must say "rotated", not "absent — task has not fired yet".
# (The health log legitimately says "absent" since neither .log nor .log.prev
# exist for it — we only check the synth log line here.)
if printf '%s\n' "$out" | grep -F "pipeline-synthesize.log " | grep -qF "absent — task has not fired yet"; then
    fail "cron synth rotated-log must not say 'absent'" "$(printf '%s\n' "$out" | grep -F 'pipeline-synthesize.log ')"
else
    pass "cron synth rotated-log does not say 'absent'"
fi
rm -f "$CRON_DIR/pipeline-synthesize.log.prev"

# Test C5c: a deleted runner file surfaces as [runner missing], NOT plain
# ARMED (HIMMEL-506 CR fix). A scheduler entry whose generated runner file is
# gone fires-and-fails every time — status must distinguish that from the
# intentional pre-HIMMEL-506 no-pin case (which exists on disk and is silent).
# model_suffix is shared by the cron + schtasks status paths, so this covers
# the fix on EVERY platform (the schtasks 9d mirror is Windows-only).

echo "TEST: cron armed task with runner file deleted shows [runner missing]"
cp "$CRON_DIR/pipeline-synthesize.sh" "$CRON_DIR/pipeline-synthesize.sh.bak"
rm -f "$CRON_DIR/pipeline-synthesize.sh"
rc=0; out=$(run_cron status) || rc=$?
assert_rc "cron runner-missing status does not error" 0 "$rc"
synth_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Synthesize')
assert_contains "cron synth runner-missing shows [runner missing]" "[runner missing]" "$synth_line"
assert_not_contains "cron synth runner-missing has no [model:] suffix" "[model:" "$synth_line"
# Other legs untouched — harvest still shows its pin, proving the pinned /
# runner-missing states are distinguished in one status output.
harvest_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Harvest')
assert_contains "cron harvest still pinned while synth runner missing" "[model: sonnet]" "$harvest_line"
mv "$CRON_DIR/pipeline-synthesize.sh.bak" "$CRON_DIR/pipeline-synthesize.sh"

# Test C6: re-arm without --force -> dedup block -------------------------------

echo "TEST: cron re-arm without --force blocked (rc 3)"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron dedup block rc 3" 3 "$rc"
assert_contains "cron dedup message names existing entries" "HIMMEL-Pipeline-Synthesize" "$out"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 3 ]; then
    pass "no duplicate entries after blocked re-arm"
else
    fail "entry count changed on blocked re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C7: re-arm --force with overrides ----------------------------------------

echo "TEST: cron re-arm --force applies flag overrides"
out=$(run_cron arm --vault "$VAULT" --force \
    --harvest-time 01:15 --ig-limit 25 --synth-time 02:30 --health-day wed --health-time 05:00 --harvest-model opus 2>&1)
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
harvest_sh=$(cat "$CRON_DIR/pipeline-harvest.sh" 2>/dev/null || echo MISSING)
assert_contains "cron daily harvest override"                  "15 01 * * *" "$tab"
# %q-escaped prompt: strip backslashes for the multi-word assert (HIMMEL-798).
assert_contains "cron --ig-limit override reaches harvest runner" "/ig-media-enrich --limit 25" "${harvest_sh//\\/}"
assert_contains "cron --harvest-model override reaches runner (HIMMEL-506)" "--model opus" "${harvest_sh//\\/}"
assert_contains "cron daily synth override (time only, daily)" "30 02 * * *" "$tab"
assert_contains "cron weekly health override (WED upcased)"    "00 05 * * 3" "$tab"
assert_contains "unrelated entry survives --force re-arm" "keep-me" "$tab"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 3 ]; then
    pass "still exactly three entries after --force re-arm"
else
    fail "duplicate entries after --force re-arm" "$(cat "$CSTATE/crontab")"
fi

# Test C14: dry-run disarm with armed entries prints DRY tail, touches nothing --

echo "TEST: cron dry-run disarm prints DRY tail, touches nothing"
out=$(run_cron disarm --dry-run)
assert_contains "cron dry disarm lists removals" "would remove crontab entry" "$out"
assert_contains "cron dry disarm closing summary" "no changes made" "$out"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 3 ]; then
    pass "dry-run disarm removed no entries"
else
    fail "dry-run disarm changed crontab state" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "dry-run disarm kept the runner .sh files"
else
    fail "dry-run disarm deleted runner .sh files"
fi

# Test C8: disarm + idempotent second disarm ------------------------------------

echo "TEST: cron disarm removes entries + runners, keeps unrelated lines"
out=$(run_cron disarm)
assert_contains "cron disarm reports" "cadence disarmed" "$out"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_not_contains "cadence entries removed" "HIMMEL-Pipeline-" "$tab"
assert_contains "unrelated entry survives disarm" "keep-me" "$tab"
if [ ! -f "$CRON_DIR/pipeline-harvest.sh" ] && [ ! -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ ! -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files removed"
else
    fail "runner .sh files left after disarm"
fi
if [ ! -f "$CRON_DIR/cadence-settings.json" ]; then
    pass "settings fragment removed on disarm (HIMMEL-575)"
else
    fail "settings fragment left after disarm"
fi
rc=0; out=$(run_cron disarm) || rc=$?
assert_rc "cron second disarm rc 0" 0 "$rc"
assert_contains "cron second disarm is a no-op" "no-op" "$out"

# Test C9: failing crontab -l is fail-CLOSED -------------------------------------

echo "TEST: cron arm/status/disarm with failing crontab -l exit 2"
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron fail-closed arm rc 2" 2 "$rc"
assert_contains "cron arm failure surfaces stderr" "must be privileged" "$out"
assert_contains "fail-closed message carries the empty-crontab remediation hint" "crontab - </dev/null" "$out"
rc=0; out=$(run_cron status 2>&1) || rc=$?
assert_rc "cron fail-closed status rc 2" 2 "$rc"
rm -f "$CSTATE/fail-list"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-list"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron fail-closed disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on failing crontab -l" "no-op" "$out"
if [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files NOT deleted on crontab -l failure"
else
    fail "runner .sh files deleted despite crontab -l failure"
fi
rm -f "$CSTATE/fail-list"
run_cron disarm >/dev/null

# Test C9b: crashed crontab -l (rc=255, EMPTY stderr) is NOT trusted-empty -------

echo "TEST: cron disarm with crashed crontab -l (rc=255, empty stderr) exits 2"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-list-255"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron crashed-list disarm rc 2" 2 "$rc"
assert_not_contains "no false no-op on crashed crontab -l" "no-op" "$out"
if [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files NOT deleted on crashed crontab -l"
else
    fail "runner .sh files deleted despite crashed crontab -l"
fi
rm -f "$CSTATE/fail-list-255"
run_cron disarm >/dev/null

# Test C10: crontab install failure -> rc 4 ---------------------------------------

echo "TEST: cron arm with failing crontab install exits 4"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron install failure rc 4" 4 "$rc"
assert_contains "cron install failure surfaces stderr" "error writing new crontab" "$out"
if ! grep -q 'HIMMEL-Pipeline-' "$CSTATE/crontab" 2>/dev/null; then
    pass "no cadence entries installed on write failure"
else
    fail "cadence entries installed despite write failure" "$(cat "$CSTATE/crontab")"
fi
if [ ! -f "$CRON_DIR/pipeline-harvest.sh" ] && [ ! -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ ! -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "no runner promoted to its final path on write failure"
else
    fail "runner files left despite write failure" "$(ls "$CRON_DIR" 2>/dev/null || true)"
fi
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter on write failure"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
# HIMMEL-575: the settings fragment is staged + promoted on the SAME gate, so a
# failed fresh arm must leave NO orphan cadence-settings.json (and no .tmp).
if [ ! -f "$CRON_DIR/cadence-settings.json" ]; then
    pass "no orphan settings fragment on write failure"
else
    fail "settings fragment orphaned on failed arm" "$(ls "$CRON_DIR")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10b: --force re-arm with failing install leaves NO half-state ------------
# Pins the stage-then-promote fix: cron_arm must NOT overwrite the live
# runners before cron_install succeeds — otherwise a failed install
# leaves the OLD crontab live pointing at NEW-config runners, silently.

echo "TEST: cron --force re-arm with failing install keeps old runners + entries"
out=$(run_cron arm --vault "$VAULT")
VAULT2="$TMP_ROOT/vault2"
mkdir -p "$VAULT2"
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron arm --vault "$VAULT2" --force 2>&1) || rc=$?
assert_rc "cron force re-arm install failure rc 4" 4 "$rc"
synth_sh=$(cat "$CRON_DIR/pipeline-synthesize.sh" 2>/dev/null || echo MISSING)
assert_contains "old runner still points at the old vault" "cd $VAULT || exit 1" "$synth_sh"
assert_not_contains "no new-config runner promoted" "vault2" "$synth_sh"
if ! compgen -G "$CRON_DIR/*.tmp.*" >/dev/null; then
    pass "no staged .tmp runner litter after failed --force re-arm"
else
    fail "staged .tmp runner litter left" "$(ls "$CRON_DIR")"
fi
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 3 ]; then
    pass "old entries still armed after failed --force re-arm"
else
    fail "entry count changed on failed --force re-arm" "$(cat "$CSTATE/crontab")"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C10c: disarm with failing install keeps entries + runners -----------------
# Pins the ordering invariant: cron_install must succeed (exit 4
# otherwise) BEFORE the `rm -f` of the runner files — the entries stay
# live in the old crontab and must keep pointing at existing runners.

echo "TEST: cron disarm with failing crontab install exits 4, keeps entries + runners"
out=$(run_cron arm --vault "$VAULT")
touch "$CSTATE/fail-write"
rc=0; out=$(run_cron disarm 2>&1) || rc=$?
assert_rc "cron disarm install failure rc 4" 4 "$rc"
assert_contains "disarm install failure surfaces stderr" "error writing new crontab" "$out"
if [ "$(grep -c 'HIMMEL-Pipeline-' "$CSTATE/crontab")" -eq 3 ]; then
    pass "entries still in crontab after failed disarm install"
else
    fail "entries lost despite failed disarm install" "$(cat "$CSTATE/crontab")"
fi
if [ -f "$CRON_DIR/pipeline-synthesize.sh" ] && [ -f "$CRON_DIR/pipeline-health.sh" ]; then
    pass "runner .sh files NOT deleted on failed disarm install"
else
    fail "runner .sh files deleted despite failed disarm install"
fi
rm -f "$CSTATE/fail-write"
run_cron disarm >/dev/null

# Test C11: hostile-but-legal vault dirname + runner dir can't inject -------------

echo "TEST: cron entries + runner escape hostile vault/runner paths"
EVIL_VAULT="$TMP_ROOT/va&ult \$X y"
EVIL_DIR="$TMP_ROOT/cr%on rnr"
mkdir -p "$EVIL_VAULT"
out=$(env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$EVIL_DIR" bash "$SCRIPT" arm --vault "$EVIL_VAULT")
synth_sh=$(cat "$EVIL_DIR/pipeline-synthesize.sh" 2>/dev/null || echo MISSING)
assert_contains "ampersand %q-escaped in runner" 'va\&ult' "$synth_sh"
# shellcheck disable=SC2016  # literal \$X needle — asserting the %q escape itself
assert_contains "dollar %q-escaped in runner" '\$X' "$synth_sh"
assert_not_contains "raw &ult survives unescaped" 'va&ult ' "$synth_sh"
tab=$(cat "$CSTATE/crontab" 2>/dev/null || echo MISSING)
assert_contains "percent cron-escaped in entry (\\%)" 'cr\%on' "$tab"
assert_contains "space %q-escaped in entry" 'cr\%on\ rnr' "$tab"
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$EVIL_DIR" bash "$SCRIPT" disarm >/dev/null

# Test C11b: cron_escape rejects control characters (#311) ----------------------
# bash's printf %q emits ANSI-C $'...' quoting for control chars, which
# dash/sh can't parse at cron fire time. Arm with a BAT_DIR containing a
# tab char — cron_escape must reject it with rc=2.

echo "TEST: arm with control char in runner dir is rejected (rc 2)"
CTRL_DIR="$TMP_ROOT/cron-ctrl-$(printf 'a\tb')"
mkdir -p "$CTRL_DIR"
rc=0; out=$(env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$CTRL_DIR" bash "$SCRIPT" arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "cron_escape rejects control char in runner path (rc 2)" 2 "$rc"
assert_contains "cron_escape error mentions control characters" "control characters" "$out"

# Test C15: the emitted runner .sh actually EXECUTES ------------------------------
# Everything above asserts runner TEXT; this arms with a recording
# `claude` stub first on PATH (so its absolute path gets baked into the
# runner) and fires the runner with plain `sh`, locking the fire-time
# behaviour: log creation + [fired] stamp, the whole prompt as ONE argv,
# cwd resolved to the vault, .log -> .log.prev rotation on the second
# fire. Hostile dirnames (& $ space) lock the %q escaping guarantee
# through a real /bin/sh re-parse, not just through grep.

echo "TEST: armed runner .sh executes end-to-end (recording claude stub)"
FIRE_VAULT="$TMP_ROOT/fire va&ult \$Z dir"
FIRE_DIR="$TMP_ROOT/fire rnr"
mkdir -p "$FIRE_VAULT"
REC="$TMP_ROOT/claude-record"
mkdir -p "$TMP_ROOT/bin-rec"
cat >"$TMP_ROOT/bin-rec/claude" <<STUB
#!/usr/bin/env bash
REC="$REC"
STUB
cat >>"$TMP_ROOT/bin-rec/claude" <<'STUB'
{
    echo "argc=$#"
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
    printf 'cwd=%s\n' "$(pwd)"
} > "$REC"
echo "claude-stub-ran"
STUB
chmod +x "$TMP_ROOT/bin-rec/claude"
# PATH entries must be POSIX-form: TMP_ROOT is cygpath -m'd (C:/...) on
# Windows, and the drive colon would split the PATH entry — the stub dir
# would silently never resolve and arm would bake the REAL claude binary
# into the runner (live-hang observed: executing it launched a real
# interactive claude session).
BIN_REC_POSIX="$TMP_ROOT/bin-rec"
if command -v cygpath >/dev/null 2>&1; then BIN_REC_POSIX=$(cygpath -u "$BIN_REC_POSIX"); fi
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$FIRE_DIR" PATH="$BIN_REC_POSIX:$PATH" \
    bash "$SCRIPT" arm --vault "$FIRE_VAULT" >/dev/null
# Fail-fast guard: NEVER execute the runner if it baked anything but the
# stub — a wrong resolution here means running the real claude binary.
if ! grep -q "bin-rec" "$FIRE_DIR/pipeline-synthesize.sh"; then
    fail "runner must reference the claude STUB (refusing to execute real claude)" \
        "baked: $(grep -m1 'claude' "$FIRE_DIR/pipeline-synthesize.sh")"
    rc=99
else
    rc=0; sh "$FIRE_DIR/pipeline-synthesize.sh" || rc=$?
fi
assert_rc "runner fires cleanly under plain sh" 0 "$rc"
log=$(cat "$FIRE_DIR/pipeline-synthesize.log" 2>/dev/null || echo MISSING)
assert_contains "fire log captures claude output" "claude-stub-ran" "$log"
assert_contains "fire log carries the [fired stamp" "[fired" "$log"
recdata=$(cat "$REC" 2>/dev/null || echo MISSING)
# HIMMEL-506/575: the runner injects `--model <pin>` then `--settings
# <fragment>` before the prompt, so claude sees five argv: --model, the
# pinned model, --settings, the fragment path, the prompt.
assert_contains "claude invoked with --model + --settings injection" "argc=5" "$recdata"
assert_contains "model flag passed to claude" "arg=--model" "$recdata"
assert_contains "model value (sonnet) passed to claude" "arg=sonnet" "$recdata"
assert_contains "settings flag passed to claude" "arg=--settings" "$recdata"
assert_contains "settings fragment path passed to claude" "cadence-settings.json" "$recdata"
assert_contains "chained prompt intact as a SINGLE argv" \
    "arg=Run /synthesize-clips to completion, then run /archive-clips." "$recdata"
expected_cwd=$(cd "$FIRE_VAULT" && pwd)
assert_contains "runner cd'd into the (hostile) vault" "cwd=$expected_cwd" "$recdata"
echo "RUN1-SENTINEL" >> "$FIRE_DIR/pipeline-synthesize.log"
sh "$FIRE_DIR/pipeline-synthesize.sh"
prev=$(cat "$FIRE_DIR/pipeline-synthesize.log.prev" 2>/dev/null || echo MISSING)
cur=$(cat "$FIRE_DIR/pipeline-synthesize.log" 2>/dev/null || echo MISSING)
assert_contains "second fire rotated first log to .log.prev" "RUN1-SENTINEL" "$prev"
assert_not_contains "fresh log after rotation" "RUN1-SENTINEL" "$cur"
assert_contains "fresh log captured the second fire" "claude-stub-ran" "$cur"
out=$(env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$FIRE_DIR" bash "$SCRIPT" status)
assert_contains "status surfaces the fired log's last line" "last line:" "$out"
assert_not_contains "status resolves a real mtime (no '?' fallback)" "last write: ?" "$out"
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$FIRE_DIR" bash "$SCRIPT" disarm >/dev/null

# Test C15b: rotation regression — fire with .log ABSENT must not clobber .log.prev
# Pins PR430 CR fix: the old brace-group `{ [ -f "$log" ] && mv; } >> "$log"` form
# opened (created) $log via the redirect BEFORE the [ -f ] test ran, making the
# test always true and clobbering .log.prev with an empty file on the first fire
# of a session whose .log was absent. The fix moves the existence test before any
# redirect that could create $log.

echo "TEST: fire with .log absent does not clobber .log.prev (PR430 CR regression)"
REGR_DIR="$TMP_ROOT/regr-rotation"
mkdir -p "$FIRE_VAULT"
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$REGR_DIR" PATH="$BIN_REC_POSIX:$PATH" \
    bash "$SCRIPT" arm --vault "$FIRE_VAULT" >/dev/null
# Seed .log.prev with sentinel content; leave .log absent — this is the
# exact state that triggered the bug (e.g. a task that has run at least
# once, then the scheduler fired after a manual rm of the current .log or
# on a machine where .log was never created in the current session).
printf 'SENTINEL-PREV-CONTENT\n' > "$REGR_DIR/pipeline-synthesize.log.prev"
rm -f "$REGR_DIR/pipeline-synthesize.log"
sh "$REGR_DIR/pipeline-synthesize.sh" >/dev/null 2>&1 || true
prev_after=$(cat "$REGR_DIR/pipeline-synthesize.log.prev" 2>/dev/null || echo MISSING)
assert_contains "rotation-absent: .log.prev still holds sentinel (not clobbered)" \
    "SENTINEL-PREV-CONTENT" "$prev_after"
if printf '%s' "$prev_after" | grep -q '^$'; then
    fail "rotation-absent: .log.prev is empty — clobber bug reproduced" "$prev_after"
fi
env OSTYPE=linux-gnu PIPELINE_CRONTAB="$FAKE_CRONTAB" \
    PIPELINE_BAT_DIR="$REGR_DIR" bash "$SCRIPT" disarm >/dev/null

# Test C13: unknown platform exits 2 ----------------------------------------------

echo "TEST: unknown platform (OSTYPE=beos) exits 2"
rc=0; out=$(env OSTYPE=beos bash "$SCRIPT" status 2>&1) || rc=$?
assert_rc "unknown platform rc 2" 2 "$rc"
assert_contains "unknown platform message" "unsupported platform" "$out"

# ============================================================================
# schtasks suite — Windows-only (cmd_arm needs cygpath; the cron suite
# above already exercised the POSIX path on this platform).
# ============================================================================

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*) : ;;
    *)
        echo "SKIP: schtasks suite (Windows-only — needs cygpath/schtasks shapes)"
        summary
        ;;
esac

# schtasks fixtures ----------------------------------------------------------

STATE="$TMP_ROOT/state"
mkdir -p "$STATE/tasks"

# Fake schtasks: persists tasks as files under $STATE/tasks/<name>
# (content = the full /create argv, for assertions).
FAKE_SCHTASKS="$TMP_ROOT/schtasks-fake.sh"
cat >"$FAKE_SCHTASKS" <<FAKE
#!/usr/bin/env bash
STATE="$STATE"
FAKE
cat >>"$FAKE_SCHTASKS" <<'FAKE'
tn=""; mode=""; fmt=""; xmlpath=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        /create|/delete|/query) mode="${args[$i]}" ;;
        /tn) i=$((i+1)); tn="${args[$i]}" ;;
        /fo) i=$((i+1)); fmt="${args[$i]}" ;;
        /xml) i=$((i+1)); xmlpath="${args[$i]}" ;;
    esac
    i=$((i+1))
done
case "$mode" in
    /create)
        # Failure-injection seam: `touch $STATE/fail-create-<tn>` makes
        # /create for that task name fail like an access-denied.
        if [ -e "$STATE/fail-create-$tn" ]; then
            echo "ERROR: Access is denied." >&2
            exit 1
        fi
        # HIMMEL-362: real arm now creates from XML (/create /tn X /xml F).
        # Store the XML file's CONTENT under $STATE/tasks/<tn> so assertions
        # can inspect the trigger + StartWhenAvailable + Exec command. The
        # xml path arrives Windows-form (schtasks gets a cygpath -w'd path);
        # convert back to POSIX to read it. Fall back to recording the argv
        # for any non-/xml create (back-compat).
        if [ -n "$xmlpath" ]; then
            xml_posix=$(cygpath -u "$xmlpath" 2>/dev/null || echo "$xmlpath")
            cat "$xml_posix" > "$STATE/tasks/$tn"
        else
            printf '%s\n' "$*" > "$STATE/tasks/$tn"
        fi
        echo "SUCCESS: The scheduled task \"$tn\" has successfully been created."
        ;;
    /delete)
        if [ -f "$STATE/tasks/$tn" ]; then rm -f "$STATE/tasks/$tn"; exit 0; else exit 1; fi
        ;;
    /query)
        # Failure-injection seam: `touch $STATE/fail-query` makes every
        # /query (listing AND /tn) fail like an access-denied — rc=1
        # with a stderr that matches neither the listing path's trusted
        # empty-scheduler signature nor /tn's NOT_FOUND_RE.
        if [ -e "$STATE/fail-query" ]; then
            echo "ERROR: Access is denied." >&2
            exit 1
        fi
        # Crash seam: `touch $STATE/fail-query-255` makes every /query
        # die rc=255 with EMPTY stderr — a crashed tool, which must NOT
        # match the trusted not-found signature (that is rc=1 only).
        if [ -e "$STATE/fail-query-255" ]; then
            exit 255
        fi
        if [ -n "$tn" ]; then
            if [ -f "$STATE/tasks/$tn" ]; then
                printf 'TaskName:      \\%s\nNext Run Time: 6/15/2026 3:00:00 AM\n' "$tn"
                exit 0
            fi
            # Silent seam: `touch $STATE/notfound-silent` makes a
            # missing-task answer rc=1 with EMPTY stderr — the shape
            # query_one used to trust, which must now fail-closed.
            if [ -e "$STATE/notfound-silent" ]; then
                exit 1
            fi
            # Variant seam: `touch $STATE/notfound-stderr-v2` switches
            # the missing-task stderr to the OTHER real schtasks English
            # message — pins NOT_FOUND_RE's second alternation.
            if [ -e "$STATE/notfound-stderr-v2" ]; then
                echo "ERROR: The specified task name \"\\$tn\" does not exist in the system." >&2
                exit 1
            fi
            # Default not-found mirrors real schtasks: rc=1 + the
            # English message on stderr (real schtasks never answers a
            # missing task with a silent rc=1).
            echo "ERROR: The system cannot find the file specified." >&2
            exit 1
        fi
        # full CSV listing
        found=0
        for f in "$STATE/tasks"/*; do
            [ -e "$f" ] || continue
            found=1
            printf '"\\%s","6/15/2026 3:00:00 AM","Ready"\n' "$(basename "$f")"
        done
        [ "$found" -eq 1 ] || exit 1   # real schtasks: rc=1 on empty scheduler
        ;;
    *) exit 1 ;;
esac
FAKE
chmod +x "$FAKE_SCHTASKS"

BAT_DIR="$TMP_ROOT/bats"

run_pc() {
    PIPELINE_SCHTASKS="$FAKE_SCHTASKS" PIPELINE_BAT_DIR="$BAT_DIR" bash "$SCRIPT" "$@"
}

# Test 1: usage errors ------------------------------------------------------

echo "TEST: missing / unknown subcommand rejected"
rc=0; out=$(run_pc 2>&1) || rc=$?
assert_rc "no subcommand -> rc 1" 1 "$rc"
rc=0; out=$(run_pc frobnicate 2>&1) || rc=$?
assert_rc "unknown subcommand -> rc 1" 1 "$rc"

# Test 2: input validation --------------------------------------------------

echo "TEST: invalid inputs rejected"
rc=0; out=$(run_pc arm --vault "$VAULT" --harvest-time 9:00 2>&1) || rc=$?
assert_rc "bad --harvest-time (no leading zero) -> rc 1" 1 "$rc"
rc=0; out=$(run_pc arm --vault "$VAULT" --synth-time 25:00 2>&1) || rc=$?
assert_rc "bad --synth-time -> rc 1" 1 "$rc"
rc=0; out=$(run_pc arm --vault "$VAULT" --synth-day FUNDAY 2>&1) || rc=$?
assert_rc "removed --synth-day -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "--synth-day message points at daily" "daily now" "$out"
rc=0; out=$(run_pc arm --vault "$VAULT" --health-day 31 2>&1) || rc=$?
assert_rc "bad --health-day (31) -> rc 1" 1 "$rc"
# HIMMEL-506: a numeric 1-28 was the OLD monthly semantics — now rejected
# with a pointer to the new weekday meaning (MON..SUN).
rc=0; out=$(run_pc arm --vault "$VAULT" --health-day 15 2>&1) || rc=$?
assert_rc "numeric --health-day (15) -> rc 1 (now weekday)" 1 "$rc"
assert_contains "numeric --health-day message points at MON..SUN" "MON..SUN" "$out"
rc=0; out=$(run_pc arm --vault "$VAULT" --harvest-model "" 2>&1) || rc=$?
assert_rc "empty --harvest-model -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "empty --harvest-model message names the flag + grammar" "--harvest-model must match [A-Za-z0-9][A-Za-z0-9._:-]*" "$out"
# HIMMEL-506 CR fix: a model value carrying " and & (CMD metacharacters)
# must be REJECTED by the grammar gate before it can reach emit_bat's
# raw "%s" interpolation. Names the offending flag + value.
rc=0; out=$(run_pc arm --vault "$VAULT" --harvest-model 'a"&b' 2>&1) || rc=$?
assert_rc "hostile --harvest-model (\" and &) -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "hostile model message names the flag" "--harvest-model" "$out"
assert_contains "hostile model message names the grammar" "[A-Za-z0-9][A-Za-z0-9._:-]*" "$out"
assert_contains "hostile model message echoes the offending value" "a\"&b" "$out"
# Whitespace-only slips the old [ -z ] check; the grammar rejects it.
rc=0; out=$(run_pc arm --vault "$VAULT" --harvest-model " " 2>&1) || rc=$?
assert_rc "whitespace-only --harvest-model -> rc 1 (HIMMEL-506)" 1 "$rc"
assert_contains "whitespace model message names the flag" "--harvest-model" "$out"
rc=0; out=$(run_pc arm --vault "$VAULT" --ig-limit -3 2>&1) || rc=$?
assert_rc "bad --ig-limit (-3) -> rc 1" 1 "$rc"
assert_contains "bad --ig-limit message names flag" "--ig-limit must be a non-negative integer" "$out"
rc=0; out=$(run_pc arm --vault "$TMP_ROOT/does-not-exist" 2>&1) || rc=$?
assert_rc "missing vault dir -> rc 1" 1 "$rc"

# Test 3: status on empty scheduler ----------------------------------------

echo "TEST: status with nothing armed"
out=$(run_pc status)
assert_contains "synthesize not armed" "not armed  HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "health not armed"     "not armed  HIMMEL-Pipeline-Health"     "$out"

# Test 4: arm --dry-run touches nothing -------------------------------------

echo "TEST: arm --dry-run prints plan, registers nothing"
out=$(run_pc arm --vault "$VAULT" --dry-run)
# HIMMEL-362: create is now XML-based; dry-run previews the /xml create line
# + the generated task XML (trigger + StartWhenAvailable).
assert_contains "dry-run daily create"         "/tn HIMMEL-Pipeline-Harvest /xml" "$out"
assert_contains "dry-run daily synth create"   "/tn HIMMEL-Pipeline-Synthesize /xml" "$out"
assert_contains "dry-run weekly health create" "/tn HIMMEL-Pipeline-Health /xml" "$out"
assert_contains "dry-run XML has StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$out"
assert_contains "dry-run XML daily schedule (harvest+synth)" "<ScheduleByDay>" "$out"
assert_contains "dry-run XML weekly health Sunday"          "<Sunday />"      "$out"
assert_not_contains "dry-run XML has no monthly schedule (HIMMEL-506)" "<Day>" "$out"
assert_contains "dry-run shows bounded run" "< NUL" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "dry-run registered no tasks"
else
    fail "dry-run registered tasks" "$(ls "$STATE/tasks")"
fi
if [ ! -d "$BAT_DIR" ]; then
    pass "dry-run wrote no .bat files"
else
    fail "dry-run wrote .bat files" "$(ls "$BAT_DIR")"
fi

# Test 5: arm registers both tasks with operator-decision defaults ----------

echo "TEST: arm registers daily 02:00/03:00 + weekly SUN 04:00"
out=$(run_pc arm --vault "$VAULT")
assert_contains "arm banner" "PIPELINE CADENCE ARMED" "$out"
harvest_args=$(cat "$STATE/tasks/HIMMEL-Pipeline-Harvest" 2>/dev/null || echo MISSING)
synth_args=$(cat "$STATE/tasks/HIMMEL-Pipeline-Synthesize" 2>/dev/null || echo MISSING)
health_args=$(cat "$STATE/tasks/HIMMEL-Pipeline-Health" 2>/dev/null || echo MISSING)
# HIMMEL-362: tasks are created from XML; the fake records the XML content.
assert_contains "daily harvest schedule (XML)" "<ScheduleByDay>"  "$harvest_args"
assert_contains "daily harvest time (XML)"     "T02:00:00"        "$harvest_args"
assert_contains "daily synth schedule (XML)"   "<ScheduleByDay>"  "$synth_args"
assert_contains "daily synth time (XML)"       "T03:00:00"        "$synth_args"
assert_contains "weekly health schedule (XML)" "<Sunday />"       "$health_args"
assert_contains "weekly health time (XML)"     "T04:00:00"        "$health_args"
assert_contains "harvest XML StartWhenAvailable" "<StartWhenAvailable>true</StartWhenAvailable>" "$harvest_args"
assert_contains "synth XML StartWhenAvailable"   "<StartWhenAvailable>true</StartWhenAvailable>" "$synth_args"
assert_contains "health XML StartWhenAvailable"  "<StartWhenAvailable>true</StartWhenAvailable>" "$health_args"
assert_contains "harvest Exec points at runner bat" "pipeline-harvest.bat"  "$harvest_args"
assert_contains "synth Exec points at runner bat"  "pipeline-synthesize.bat" "$synth_args"
assert_contains "health Exec points at runner bat" "pipeline-health.bat"     "$health_args"

# Test 6: .bat runners are interactive-claude shaped ------------------------

echo "TEST: .bat runners are bounded interactive claude (no headless flags)"
harvest_bat=$(cat "$BAT_DIR/pipeline-harvest.bat" 2>/dev/null || echo MISSING)
synth_bat=$(cat "$BAT_DIR/pipeline-synthesize.bat" 2>/dev/null || echo MISSING)
health_bat=$(cat "$BAT_DIR/pipeline-health.bat" 2>/dev/null || echo MISSING)
assert_contains "harvest bat stamps the format version (HIMMEL-588)" "rem himmel-cadence-runner-format: 4" "$harvest_bat"
assert_contains "synth bat stamps the format version (HIMMEL-588)"   "rem himmel-cadence-runner-format: 4" "$synth_bat"
assert_contains "health bat stamps the format version (HIMMEL-588)"  "rem himmel-cadence-runner-format: 4" "$health_bat"
assert_contains "harvest bat cds into vault" 'cd /d "' "$harvest_bat"
assert_contains "harvest bat runs /harvest-clips" "/harvest-clips" "$harvest_bat"
assert_contains "harvest bat chains /triage-clips" "/triage-clips" "$harvest_bat"
assert_contains "harvest bat chains /ig-media-enrich default limit" "/ig-media-enrich --limit 10" "$harvest_bat"
assert_contains "harvest bat fail-opens ig-media-enrich" "must not abort" "$harvest_bat"
assert_contains "harvest bat bounded run"          "< NUL"         "$harvest_bat"
assert_contains "harvest bat appends run log" 'pipeline-harvest.log" 2>&1' "$harvest_bat"
assert_contains "harvest bat rotates the log before firing" 'move /y' "$harvest_bat"
assert_contains "harvest bat stamps every fire" 'echo [fired %DATE% %TIME%]' "$harvest_bat"
assert_contains "synth bat cds into vault" 'cd /d "' "$synth_bat"
assert_contains "synth bat runs /synthesize-clips" "/synthesize-clips" "$synth_bat"
assert_contains "synth bat chains /archive-clips"  "/archive-clips"    "$synth_bat"
assert_contains "synth bat bounded run"            "< NUL"             "$synth_bat"
assert_contains "synth bat appends run log"  'pipeline-synthesize.log" 2>&1' "$synth_bat"
assert_contains "synth bat rotates the log before firing" 'move /y' "$synth_bat"
assert_contains "synth bat stamps every fire" 'echo [fired %DATE% %TIME%]' "$synth_bat"
if printf '%s' "$synth_bat" | grep -E 'cd /d "[^"]*" >> "[^"]*" 2>&1 \|\| exit /b 1' >/dev/null; then
    pass "synth bat cd line redirects into the run log"
else
    fail "synth bat cd line has no log redirect" "$synth_bat"
fi
assert_contains "health bat runs /obsidian-health" "/obsidian-health"  "$health_bat"
assert_contains "health bat bounded run"           "< NUL"             "$health_bat"
assert_contains "health bat appends run log" 'pipeline-health.log" 2>&1'     "$health_bat"
for what in harvest synth health; do
    body=$(eval "printf '%s' \"\$${what}_bat\"")
    if printf '%s\n' "$body" | grep -E "$HEADLESS_RE" >/dev/null 2>&1; then
        fail "$what bat is headless-shaped" "$body"
    else
        pass "$what bat has no headless claude flags"
    fi
done

# Test 6c: per-leg --model pins in the .bat runners (HIMMEL-506) — every
# runner carries `--model "<m>"` right after the binary.
echo "TEST: .bat runners carry the per-leg --model pin (HIMMEL-506)"
assert_contains "harvest bat pins --model sonnet" '--model "sonnet"' "$harvest_bat"
assert_contains "synth bat pins --model sonnet"   '--model "sonnet"' "$synth_bat"
assert_contains "health bat pins --model haiku"    '--model "haiku"'  "$health_bat"

echo "TEST: .bat runners omit the print-only bg-wait ceiling override (HIMMEL-951)"
assert_not_contains "harvest bat omits bg-wait ceiling override" "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$harvest_bat"
assert_not_contains "synth bat omits bg-wait ceiling override"   "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$synth_bat"
assert_not_contains "health bat omits bg-wait ceiling override"  "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS" "$health_bat"

# Test 6b: --settings injection wires the auto-approve hook (HIMMEL-575) ------

echo "TEST: .bat runners inject --settings + fragment wires auto-approve hook"
assert_contains "harvest bat injects --settings" "--settings" "$harvest_bat"
assert_contains "synth bat injects --settings"   "--settings" "$synth_bat"
assert_contains "health bat injects --settings"  "--settings" "$health_bat"
assert_contains "harvest bat --settings targets the fragment" "cadence-settings.json" "$harvest_bat"
wfrag="$BAT_DIR/cadence-settings.json"
if [ -f "$wfrag" ]; then
    pass "settings fragment written to the .bat dir"
else
    fail "settings fragment missing at $wfrag"
fi
wfrag_body=$(cat "$wfrag" 2>/dev/null || echo MISSING)
if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$wfrag_body" | jq -e '.hooks.PreToolUse[0].matcher == "Bash"' >/dev/null 2>&1; then
        pass "fragment is valid JSON wiring a PreToolUse Bash hook"
    else
        fail "fragment JSON does not wire a PreToolUse Bash hook" "$wfrag_body"
    fi
    whookcmd=$(printf '%s' "$wfrag_body" | jq -r '.hooks.PreToolUse[0].hooks[0].command' 2>/dev/null || echo "")
else
    whookcmd="$wfrag_body"
fi
assert_contains "fragment command references auto-approve-safe-bash" "auto-approve-safe-bash.sh" "$whookcmd"
# Path must be JSON-safe (forward slashes, no raw backslashes that break JSON / bash).
case "$whookcmd" in
    *\\*) fail "fragment hook path contains backslashes (not JSON/bash safe)" "$whookcmd" ;;
    *)    pass "fragment hook path is forward-slash (JSON/bash safe)" ;;
esac

# Test 7: status after arm ---------------------------------------------------

echo "TEST: status reflects armed tasks"
out=$(run_pc status)
assert_contains "harvest armed"    "ARMED      HIMMEL-Pipeline-Harvest"    "$out"
assert_contains "synthesize armed" "ARMED      HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "health armed"     "ARMED      HIMMEL-Pipeline-Health"     "$out"
assert_contains "status daily row mentions ig-media-enrich" "/ig-media-enrich" "$out"
assert_contains "status surfaces run log state" "run log" "$out"
# HIMMEL-506: status parses the --model pin back out of each .bat runner.
# Scope each pin to its OWN status line — harvest and synth are both
# [model: sonnet], so a whole-output check would pass even if one leg's pin
# were wrong or missing.
harvest_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Harvest')
synth_line=$(printf '%s\n' "$out"   | grep 'HIMMEL-Pipeline-Synthesize')
health_line=$(printf '%s\n' "$out"  | grep 'HIMMEL-Pipeline-Health')
assert_contains "harvest status line armed"      "ARMED"           "$harvest_line"
assert_contains "harvest status shows model pin" "[model: sonnet]" "$harvest_line"
assert_contains "synth status shows model pin"   "[model: sonnet]" "$synth_line"
assert_contains "health status shows model pin"  "[model: haiku]"  "$health_line"

# Test 7b: status surfaces the rotated .log.prev evidence ---------------------
# Rotation keeps one prior run as .log.prev; right after a fire the
# current .log holds only the fresh run, so the previous run's outcome
# is only visible if status surfaces the .prev file too.

echo "TEST: status surfaces the rotated .log.prev (mtime + last line)"
printf 'old run output\nprev run last line\n'    > "$BAT_DIR/pipeline-synthesize.log.prev"
printf 'current run output\ncurrent last line\n' > "$BAT_DIR/pipeline-synthesize.log"
out=$(run_pc status)
assert_contains "current log surfaced"  "pipeline-synthesize.log (last write:"      "$out"
assert_contains "current log last line" "current last line"                         "$out"
assert_contains "prev log surfaced"     "pipeline-synthesize.log.prev (last write:" "$out"
assert_contains "prev log last line"    "prev run last line"                        "$out"
assert_not_contains "no prev line for never-rotated health log" "pipeline-health.log.prev" "$out"
rm -f "$BAT_DIR/pipeline-synthesize.log" "$BAT_DIR/pipeline-synthesize.log.prev"

# Test 8: re-arm without --force -> dedup block ------------------------------

echo "TEST: re-arm without --force blocked (rc 3)"
rc=0; out=$(run_pc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "dedup block rc 3" 3 "$rc"
assert_contains "dedup message names existing tasks" "HIMMEL-Pipeline-Synthesize" "$out"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 3 ]; then
    pass "no duplicate tasks after blocked re-arm"
else
    fail "task count changed on blocked re-arm" "$(ls "$STATE/tasks")"
fi

# Test 9: re-arm --force with overrides --------------------------------------

echo "TEST: re-arm --force applies flag overrides"
out=$(run_pc arm --vault "$VAULT" --force \
    --harvest-time 01:15 --ig-limit 0 --synth-time 02:30 --health-day wed --health-time 05:00 --harvest-model opus 2>&1)
harvest_args=$(cat "$STATE/tasks/HIMMEL-Pipeline-Harvest" 2>/dev/null || echo MISSING)
synth_args=$(cat "$STATE/tasks/HIMMEL-Pipeline-Synthesize" 2>/dev/null || echo MISSING)
health_args=$(cat "$STATE/tasks/HIMMEL-Pipeline-Health" 2>/dev/null || echo MISSING)
harvest_bat=$(cat "$BAT_DIR/pipeline-harvest.bat" 2>/dev/null || echo MISSING)
assert_contains "daily harvest override (XML time)"       "T01:15:00"   "$harvest_args"
assert_contains "--ig-limit 0 reaches harvest bat"         "/ig-media-enrich --limit 0" "$harvest_bat"
assert_contains "--harvest-model override reaches bat (HIMMEL-506)" '--model "opus"' "$harvest_bat"
assert_contains "daily synth override (daily schedule)"   "<ScheduleByDay>" "$synth_args"
assert_contains "daily synth override (XML time)"         "T02:30:00"   "$synth_args"
assert_contains "weekly health override (WED upcased)"    "<Wednesday />" "$health_args"
assert_contains "weekly health override (XML time)"       "T05:00:00"   "$health_args"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 3 ]; then
    pass "still exactly three tasks after --force re-arm"
else
    fail "duplicate tasks after --force re-arm" "$(ls "$STATE/tasks")"
fi

# Test 9b: --force re-arm model pin round-trips through status (HIMMEL-506).
# status parses the --model token back out of the .bat runner; after a
# --force re-arm with --harvest-model opus, the harvest status line must
# show [model: opus].
echo "TEST: --force re-arm harvest model pin round-trips via status"
out=$(run_pc status)
harvest_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Harvest')
assert_contains "status round-trips --force harvest model pin" "[model: opus]" "$harvest_line"

# Test 9c: pre-HIMMEL-506 runner (no --model token) stays silent in status
# (HIMMEL-506). A v1 runner never carried --model; status must NOT print a
# [model: ...] suffix for it (no "model: unknown", no error). Emulate by
# stripping the --model token the v1 emitter never wrote. disarm (Test 10)
# removes the modified runner right after, so no cleanup needed here.
echo "TEST: v1 runner without --model pin shows no model suffix in status"
sed 's/ --model "[^"]*"//' "$BAT_DIR/pipeline-harvest.bat" > "$BAT_DIR/pipeline-harvest.bat.v1"
mv "$BAT_DIR/pipeline-harvest.bat.v1" "$BAT_DIR/pipeline-harvest.bat"
rc=0; out=$(run_pc status) || rc=$?
assert_rc "v1 runner status does not error" 0 "$rc"
harvest_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Harvest')
assert_not_contains "v1 harvest runner has no [model:] suffix" "[model:" "$harvest_line"
assert_not_contains "v1 runner status has no 'model: unknown'" "model: unknown" "$out"

# Test 9d: a deleted runner file surfaces as [runner missing], NOT plain ARMED
# (HIMMEL-506 CR fix). The schtasks mirror of cron C5c: a scheduler entry whose
# .bat runner is gone fires-and-fails every time, so status must distinguish
# it from the v1 no-pin runner above (9c, which exists on disk and is silent).
# Backs up + restores the runner so Test 10's disarm state is unaffected.
echo "TEST: armed task with .bat runner deleted shows [runner missing]"
cp "$BAT_DIR/pipeline-synthesize.bat" "$BAT_DIR/pipeline-synthesize.bat.bak"
rm -f "$BAT_DIR/pipeline-synthesize.bat"
rc=0; out=$(run_pc status) || rc=$?
assert_rc "runner-missing status does not error" 0 "$rc"
synth_line=$(printf '%s\n' "$out" | grep 'HIMMEL-Pipeline-Synthesize')
assert_contains "synth runner-missing shows [runner missing]" "[runner missing]" "$synth_line"
assert_not_contains "synth runner-missing has no [model:] suffix" "[model:" "$synth_line"
mv "$BAT_DIR/pipeline-synthesize.bat.bak" "$BAT_DIR/pipeline-synthesize.bat"

# Test 10: disarm + idempotent second disarm ---------------------------------

echo "TEST: disarm removes tasks + runners; second disarm is a no-op"
out=$(run_pc disarm)
assert_contains "disarm reports" "cadence disarmed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "all tasks removed"
else
    fail "tasks left after disarm" "$(ls "$STATE/tasks")"
fi
if [ ! -f "$BAT_DIR/pipeline-harvest.bat" ] && [ ! -f "$BAT_DIR/pipeline-synthesize.bat" ] && [ ! -f "$BAT_DIR/pipeline-health.bat" ]; then
    pass ".bat runners removed"
else
    fail ".bat runners left after disarm"
fi
if [ ! -f "$BAT_DIR/cadence-settings.json" ]; then
    pass "settings fragment removed on disarm (HIMMEL-575)"
else
    fail "settings fragment left after disarm"
fi
rc=0; out=$(run_pc disarm) || rc=$?
assert_rc "second disarm rc 0" 0 "$rc"
assert_contains "second disarm is a no-op" "no-op" "$out"

# Test 11: cmd_escape — hostile-but-legal vault dirname can't inject ----------

echo "TEST: vault path with CMD metachars is escaped in the .bat"
EVIL_VAULT="$TMP_ROOT/va&ult %X%^Y"
mkdir -p "$EVIL_VAULT"
out=$(run_pc arm --vault "$EVIL_VAULT")
synth_bat=$(cat "$BAT_DIR/pipeline-synthesize.bat" 2>/dev/null || echo MISSING)
assert_contains "percent doubled (%% in bat)" '%%X%%' "$synth_bat"
assert_contains "ampersand careted (^& in bat)" '^&' "$synth_bat"
assert_contains "caret doubled (^^ in bat)" '^^' "$synth_bat"
assert_not_contains "raw &ult survives unescaped" 'va&ult' "$synth_bat"
# Harvest .bat goes through the same cmd_escape path — assert it too.
harvest_bat=$(cat "$BAT_DIR/pipeline-harvest.bat" 2>/dev/null || echo MISSING)
assert_contains "harvest: percent doubled (%% in bat)" '%%X%%' "$harvest_bat"
assert_contains "harvest: ampersand careted (^& in bat)" '^&' "$harvest_bat"
assert_not_contains "harvest: raw &ult survives unescaped" 'va&ult' "$harvest_bat"
run_pc disarm >/dev/null

# Test 12: half-arm rollback when the SECOND /create fails --------------------

echo "TEST: health /create failure rolls back harvest + synthesize (rc 4)"
touch "$STATE/fail-create-HIMMEL-Pipeline-Health"
rc=0; out=$(run_pc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "half-arm fails rc 4" 4 "$rc"
assert_contains "failure names the health create" "HIMMEL-Pipeline-Health failed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "no task state left after rollback"
else
    fail "task state left after rollback" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-create-HIMMEL-Pipeline-Health"

# Test 12b: middle-create (synthesize) failure rolls back the harvest task
# that DID register; health is never attempted. Pins the harvest-only
# rollback branch.

echo "TEST: synth /create failure rolls back the harvest task (rc 4)"
touch "$STATE/fail-create-HIMMEL-Pipeline-Synthesize"
rc=0; out=$(run_pc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "mid half-arm fails rc 4" 4 "$rc"
assert_contains "failure names the synth create" "HIMMEL-Pipeline-Synthesize failed" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "no task state left after harvest rollback"
else
    fail "task state left after harvest rollback" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-create-HIMMEL-Pipeline-Synthesize"

# Test 13: dedup listing failure is fail-CLOSED (pins the inverted classifier)

echo "TEST: arm with failing /query listing exits 2 (fail-closed dedup)"
touch "$STATE/fail-query"
rc=0; out=$(run_pc arm --vault "$VAULT" 2>&1) || rc=$?
assert_rc "fail-closed dedup rc 2" 2 "$rc"
assert_contains "dedup failure surfaces stderr" "Access is denied" "$out"
if [ -z "$(ls -A "$STATE/tasks" 2>/dev/null)" ]; then
    pass "nothing registered when dedup listing failed"
else
    fail "tasks registered despite failed dedup listing" "$(ls "$STATE/tasks")"
fi
rm -f "$STATE/fail-query"

# Test 14: disarm under query failure must not no-op or delete runners --------

echo "TEST: disarm with failing /query exits nonzero, keeps the .bats"
out=$(run_pc arm --vault "$VAULT")
touch "$STATE/fail-query"
rc=0; out=$(run_pc disarm 2>&1) || rc=$?
assert_rc "disarm query failure rc 2" 2 "$rc"
assert_not_contains "no false no-op on query failure" "no-op" "$out"
# Escape hatch (#285): fail-closed must not be a dead end — a localized
# not-found stderr lands in this same branch, so the error carries the
# manual verify/remove commands.
assert_contains "query failure prints manual delete escape hatch" "schtasks /delete /tn" "$out"
if [ -f "$BAT_DIR/pipeline-synthesize.bat" ] && [ -f "$BAT_DIR/pipeline-health.bat" ]; then
    pass ".bat runners NOT deleted on query failure"
else
    fail ".bat runners deleted despite query failure"
fi
rm -f "$STATE/fail-query"
run_pc disarm >/dev/null

# Test 14b: crashed query (rc=255, EMPTY stderr) is NOT trusted not-found -----
# Pins the trusted-not-found classifier in query_one: only rc=1 may read
# as "not armed"; a crashed schtasks must not make disarm no-op and
# delete the runners.

echo "TEST: disarm with crashed /query (rc=255, empty stderr) exits 2, keeps the .bats"
out=$(run_pc arm --vault "$VAULT")
touch "$STATE/fail-query-255"
rc=0; out=$(run_pc disarm 2>&1) || rc=$?
assert_rc "disarm crashed-query rc 2" 2 "$rc"
assert_not_contains "no false no-op on crashed query" "no-op" "$out"
if [ -f "$BAT_DIR/pipeline-synthesize.bat" ] && [ -f "$BAT_DIR/pipeline-health.bat" ]; then
    pass ".bat runners NOT deleted on crashed query"
else
    fail ".bat runners deleted despite crashed query"
fi
rm -f "$STATE/fail-query-255"

# Test 14c: status propagates query errors as rc=2 (header exit-code contract)

echo "TEST: status with failing /query exits 2"
touch "$STATE/fail-query"
rc=0; out=$(run_pc status 2>&1) || rc=$?
assert_rc "status query failure rc 2" 2 "$rc"
assert_contains "status prints QUERY ERR" "QUERY ERR" "$out"
rm -f "$STATE/fail-query"

# Test 14d: dry-run disarm with armed tasks prints a closing summary,
# deletes nothing.
# ORDER COUPLING with 14b: the two armed tasks asserted below are the
# ones 14b armed and deliberately left in place (its crashed-query
# disarm must NOT delete them, and 14b never disarms afterwards); 14c
# only injects a transient query failure and changes no task state.
# Re-ordering these tests, or adding a disarm to 14b/14c, breaks 14d's
# "would delete" + task-count-2 asserts.

echo "TEST: dry-run disarm prints DRY tail, touches nothing"
out=$(run_pc disarm --dry-run)
assert_contains "dry disarm lists deletions" "would delete" "$out"
assert_contains "dry disarm closing summary" "no changes made" "$out"
if [ "$(find "$STATE/tasks" -mindepth 1 | wc -l)" -eq 3 ]; then
    pass "dry-run disarm deleted no tasks"
else
    fail "dry-run disarm changed task state" "$(ls "$STATE/tasks")"
fi
if [ -f "$BAT_DIR/pipeline-synthesize.bat" ] && [ -f "$BAT_DIR/pipeline-health.bat" ]; then
    pass "dry-run disarm kept the .bat runners"
else
    fail "dry-run disarm deleted .bat runners"
fi
run_pc disarm >/dev/null

# Test 14e: NOT_FOUND_RE alternation 1 — rc=1 + the "cannot find the
# file specified" stderr (the fake's DEFAULT not-found, mirroring real
# schtasks) must classify as trusted not-found.
# Pre-condition: nothing armed (14d's trailing disarm just ran).

echo "TEST: rc=1 + 'cannot find the file' stderr reads as not armed"
rc=0; out=$(run_pc status 2>&1) || rc=$?
assert_rc "status with not-found stderr rc 0" 0 "$rc"
assert_contains "synthesize reads not armed" "not armed  HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "health reads not armed"     "not armed  HIMMEL-Pipeline-Health"     "$out"
assert_not_contains "no QUERY ERR on real not-found stderr" "QUERY ERR" "$out"
rc=0; out=$(run_pc disarm 2>&1) || rc=$?
assert_rc "disarm with not-found stderr rc 0" 0 "$rc"
assert_contains "disarm is a clean no-op" "no-op" "$out"

# Test 14f: NOT_FOUND_RE alternation 2 — rc=1 + the 'specified task name
# "..." does not exist' message (the other real schtasks not-found
# signature) must also classify as trusted not-found.

echo "TEST: rc=1 + 'task name does not exist' stderr reads as not armed"
touch "$STATE/notfound-stderr-v2"
rc=0; out=$(run_pc status 2>&1) || rc=$?
assert_rc "status with task-name not-found stderr rc 0" 0 "$rc"
assert_contains "synthesize reads not armed" "not armed  HIMMEL-Pipeline-Synthesize" "$out"
assert_contains "health reads not armed"     "not armed  HIMMEL-Pipeline-Health"     "$out"
assert_not_contains "no QUERY ERR on task-name not-found stderr" "QUERY ERR" "$out"
rm -f "$STATE/notfound-stderr-v2"

# Test 14g: silent rc=1 (EMPTY stderr) is NOT trusted not-found — real
# schtasks always emits the message on a missing task, so a message-less
# rc=1 is a query failure and must fail-closed (pins the removal of
# query_one's old empty-stderr trust).

echo "TEST: rc=1 + EMPTY stderr fail-closes (status rc 2)"
touch "$STATE/notfound-silent"
rc=0; out=$(run_pc status 2>&1) || rc=$?
assert_rc "status with silent rc=1 exits 2" 2 "$rc"
assert_contains "silent rc=1 prints QUERY ERR" "QUERY ERR" "$out"
# Needle is the status-line shape (two spaces + task prefix): the error
# path legitimately prints "refusing to treat as 'not armed'".
assert_not_contains "silent rc=1 never reads not armed" "not armed  HIMMEL-Pipeline-" "$out"
rm -f "$STATE/notfound-silent"

summary
