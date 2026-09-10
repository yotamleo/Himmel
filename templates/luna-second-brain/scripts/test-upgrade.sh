#!/usr/bin/env bash
# Tests for templates/luna-second-brain/scripts/upgrade.sh (HIMMEL-389).
# Content-preserving vault/template upgrade. Each case builds a throwaway
# template + vault fixture under a temp dir and runs upgrade.sh against them
# with explicit --template-dir / --vault-dir so nothing touches a real vault.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UPGRADE="$HERE/upgrade.sh"

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

# The engine's real deps are a WORKING python + git + a SHA-256 tool (NOT node
# — it is never invoked; the prior node gate was vestigial). A working python
# means one whose stdout actually runs: on Windows `python3` is the Microsoft
# Store stub (on PATH but emits nothing), so gate on real output, not
# `command -v`.
PY=""
SHA256=()
_resolve_py() {
    for c in python3 python py; do
        command -v "$c" >/dev/null 2>&1 && [ "$("$c" -c 'print(1)' 2>/dev/null)" = "1" ] && { PY="$c"; return 0; }
    done
    return 1
}
_resolve_py || { echo "SKIP all — no working python (python3/python/py) on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP all — git not on PATH"; exit 0; }
if command -v sha256sum >/dev/null 2>&1; then
    SHA256=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
    SHA256=(shasum -a 256)
else
    echo "SKIP all — no SHA-256 tool (sha256sum/shasum) on PATH"
    exit 0
fi

TMP=$(mktemp -d -t luna-upgrade.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

sha_of() { if [ -f "$1" ]; then "${SHA256[@]}" "$1" | cut -d' ' -f1; else echo MISSING; fi; }

# Build a minimal but representative template fixture at $1 with version $2.
make_template() {
    local d="$1" ver="$2"
    mkdir -p "$d/marketplace/.claude-plugin" "$d/scripts/hooks" "$d/.obsidian/plugins/calendar" "$d/_Templates" "$d/docs" "$d/50-Journal"
    printf '{"metadata":{"version":"%s"}}\n' "$ver" > "$d/marketplace/.claude-plugin/marketplace.json"
    printf '# Operating Manual\n\nline-a\nline-b\nline-c\n' > "$d/_CLAUDE.md"
    printf '#!/usr/bin/env bash\necho "template commit-msg vTEMPLATE"\n' > "$d/scripts/hooks/check-commit-msg.sh"
    printf '%s\n' '["dataview","calendar","new"]' > "$d/.obsidian/community-plugins.json"
    printf '{"weekStart":"locale","wordsPerDot":250}\n' > "$d/.obsidian/plugins/calendar/data.json"
    printf 'CALENDAR-MAIN-JS-TEMPLATE\n' > "$d/.obsidian/plugins/calendar/main.js"
    printf '# Optional plugins\n\n| Plugin | License |\n| --- | --- |\n| Charts | AGPL |\n' > "$d/.obsidian/PLUGINS-SETUP.md"
    printf '# Daily Note Template\n{{date}}\n' > "$d/_Templates/Daily-Note.md"
    printf '.env\n.env.*\n' > "$d/.gitignore"
    printf 'DEFAULT_X=1\n' > "$d/.env.example"
    printf '# Vault README vTEMPLATE\n' > "$d/README.md"
    printf '# template doc\n' > "$d/docs/guide.md"
}

# Stamp a vault as version $2 (skip if $2 is empty = pre-versioning).
stamp_vault() {
    local d="$1" ver="$2"
    [ -z "$ver" ] && return 0
    printf '{"template":"luna-second-brain","version":"%s","upgraded_at":"2026-01-01T00:00:00Z"}\n' "$ver" > "$d/.vault-template.json"
}

run_upgrade() { bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" "$@"; }

# ---------------------------------------------------------------------------
# T1: version equal => no-op exit 0; vault behind => runs (exit 0, mutates).
T="$TMP/t1-tmpl"; V="$TMP/t1-vault"; make_template "$T" "1.0.0"; mkdir -p "$V"; stamp_vault "$V" "1.0.0"
out=$(run_upgrade --yes 2>&1); rc=$?
assert_eq "T1 equal-version rc" "0" "$rc"
case "$out" in *already*current*) pass "T1 equal-version reports already-current" ;; *) fail "T1 equal-version reports already-current" "got: $out" ;; esac

T="$TMP/t1b-tmpl"; V="$TMP/t1b-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/scripts/hooks"; stamp_vault "$V" "0.9.0"
printf 'STALE\n' > "$V/scripts/hooks/check-commit-msg.sh"
run_upgrade --yes >/dev/null 2>&1; rc=$?
assert_eq "T1b behind-version rc" "0" "$rc"
assert_eq "T1b behind-version ran (hook updated)" "$(sha_of "$T/scripts/hooks/check-commit-msg.sh")" "$(sha_of "$V/scripts/hooks/check-commit-msg.sh")"

# ---------------------------------------------------------------------------
# T2: overwrite-safe — a user-diverged template-owned script is restored.
T="$TMP/t2-tmpl"; V="$TMP/t2-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/scripts/hooks"; stamp_vault "$V" "0.1.0"
printf '#!/usr/bin/env bash\necho "USER HACKED THIS"\n' > "$V/scripts/hooks/check-commit-msg.sh"
run_upgrade --yes >/dev/null 2>&1
assert_eq "T2 diverged script restored to template" "$(sha_of "$T/scripts/hooks/check-commit-msg.sh")" "$(sha_of "$V/scripts/hooks/check-commit-msg.sh")"

# ---------------------------------------------------------------------------
# T3: community-plugins.json add-only merge — never drop a user-added id.
T="$TMP/t3-tmpl"; V="$TMP/t3-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.obsidian"; stamp_vault "$V" "0.1.0"
printf '%s\n' '["dataview","calendar","user-added"]' > "$V/.obsidian/community-plugins.json"
run_upgrade --yes >/dev/null 2>&1
merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json")
assert_eq "T3 merge keeps user-added + adds new" "calendar,dataview,new,user-added" "$merged"

# ---------------------------------------------------------------------------
# T4: data.json skip-if-exists — user-tuned plugin data is untouched.
T="$TMP/t4-tmpl"; V="$TMP/t4-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.obsidian/plugins/calendar"; stamp_vault "$V" "0.1.0"
printf '{"weekStart":"monday","wordsPerDot":999}\n' > "$V/.obsidian/plugins/calendar/data.json"
before=$(sha_of "$V/.obsidian/plugins/calendar/data.json")
run_upgrade --yes >/dev/null 2>&1
assert_eq "T4 existing data.json untouched" "$before" "$(sha_of "$V/.obsidian/plugins/calendar/data.json")"

# ---------------------------------------------------------------------------
# T5: _CLAUDE.md clean 3-way merge (non-overlapping edits) => replaced, no sidecar.
T="$TMP/t5-tmpl"; V="$TMP/t5-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.vault-template.base"; stamp_vault "$V" "0.1.0"
# base = pristine template _CLAUDE.md
cp "$T/_CLAUDE.md" "$V/.vault-template.base/_CLAUDE.md"
# ours = base + an edit at the END (non-overlapping with template's edit at the TOP)
printf '# Operating Manual\n\nline-a\nline-b\nline-c\nVAULT-ADDED-TAIL\n' > "$V/_CLAUDE.md"
# theirs = base + an edit at the TOP
printf '# Operating Manual v2\n\nline-a\nline-b\nline-c\n' > "$T/_CLAUDE.md"
run_upgrade --yes >/dev/null 2>&1
merged="$V/_CLAUDE.md"
if grep -q 'VAULT-ADDED-TAIL' "$merged" && grep -q 'Operating Manual v2' "$merged"; then pass "T5 clean merge keeps both edits"; else fail "T5 clean merge keeps both edits" "got: $(cat "$merged")"; fi
if [ ! -f "$V/_CLAUDE.md.template-merge" ]; then pass "T5 no conflict sidecar on clean merge"; else fail "T5 no conflict sidecar on clean merge" "sidecar present"; fi
# base snapshot is advanced to the new template _CLAUDE.md so the NEXT run's
# 3-way has a real ancestor (not the ours-wins fallback).
assert_eq "T5 base snapshot advanced to theirs" "$(sha_of "$T/_CLAUDE.md")" "$(sha_of "$V/.vault-template.base/_CLAUDE.md")"

# ---------------------------------------------------------------------------
# T6: _CLAUDE.md conflict (overlapping edits) => original untouched + sidecar + alert.
T="$TMP/t6-tmpl"; V="$TMP/t6-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.vault-template.base"; stamp_vault "$V" "0.1.0"
cp "$T/_CLAUDE.md" "$V/.vault-template.base/_CLAUDE.md"
# ours and theirs edit the SAME line differently => conflict
printf '# Operating Manual OURS\n\nline-a\nline-b\nline-c\n' > "$V/_CLAUDE.md"
printf '# Operating Manual THEIRS\n\nline-a\nline-b\nline-c\n' > "$T/_CLAUDE.md"
ours_before=$(sha_of "$V/_CLAUDE.md")
out=$(run_upgrade --yes 2>&1); rc=$?
assert_eq "T6 conflict leaves _CLAUDE.md untouched" "$ours_before" "$(sha_of "$V/_CLAUDE.md")"
if [ -f "$V/_CLAUDE.md.template-merge" ]; then pass "T6 conflict writes sidecar"; else fail "T6 conflict writes sidecar" "no sidecar"; fi
case "$out" in *_CLAUDE.md.template-merge*|*conflict*|*CONFLICT*) pass "T6 conflict alerts loudly" ;; *) fail "T6 conflict alerts loudly" "got: $out" ;; esac
# A conflicted run must NOT advance the version stamp (else the conflict is
# silently masked on the next run) and must exit non-zero.
if [ "$rc" -ne 0 ]; then pass "T6 conflict exits non-zero"; else fail "T6 conflict exits non-zero" "rc=0"; fi
got_ver=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T6 conflict does not advance the stamp" "0.1.0" "$got_ver"

# ---------------------------------------------------------------------------
# T7: PLUGINS-SETUP.md reprint fires when the manual-install table changed.
T="$TMP/t7-tmpl"; V="$TMP/t7-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.obsidian"; stamp_vault "$V" "0.1.0"
printf '# Optional plugins\n\n| Plugin | License |\n| --- | --- |\n| OldPlugin | MIT |\n' > "$V/.obsidian/PLUGINS-SETUP.md"
out=$(run_upgrade --yes 2>&1)
# Match the reprint block's unique banner, NOT just the basename (which also
# appears in the WRITE plan line) — so the test fails if the reprint is dropped.
case "$out" in *"manual-install table"*) pass "T7 reprints PLUGINS-SETUP when changed" ;; *) fail "T7 reprints PLUGINS-SETUP when changed" "got: $out" ;; esac

# ---------------------------------------------------------------------------
# T8: idempotency — second run reports already-current.
T="$TMP/t8-tmpl"; V="$TMP/t8-vault"; make_template "$T" "1.0.0"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
run_upgrade --yes >/dev/null 2>&1
out=$(run_upgrade --yes 2>&1); rc=$?
assert_eq "T8 second-run rc" "0" "$rc"
case "$out" in *already*current*) pass "T8 second run is a no-op" ;; *) fail "T8 second run is a no-op" "got: $out" ;; esac

# ---------------------------------------------------------------------------
# T9: --dry-run mutates nothing.
T="$TMP/t9-tmpl"; V="$TMP/t9-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/scripts/hooks"; stamp_vault "$V" "0.1.0"
printf 'STALE\n' > "$V/scripts/hooks/check-commit-msg.sh"
before=$(find "$V" -type f -exec "${SHA256[@]}" {} \; | sort)
run_upgrade --dry-run >/dev/null 2>&1; rc=$?
after=$(find "$V" -type f -exec "${SHA256[@]}" {} \; | sort)
assert_eq "T9 dry-run rc" "0" "$rc"
assert_eq "T9 dry-run made zero changes" "$before" "$after"

# ---------------------------------------------------------------------------
# T10: pre-versioning vault (no stamp) => full pass + stamp written at end.
T="$TMP/t10-tmpl"; V="$TMP/t10-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/scripts/hooks"
printf 'STALE\n' > "$V/scripts/hooks/check-commit-msg.sh"
[ ! -f "$V/.vault-template.json" ] || rm -f "$V/.vault-template.json"
run_upgrade --yes >/dev/null 2>&1; rc=$?
assert_eq "T10 pre-versioning rc" "0" "$rc"
if [ -f "$V/.vault-template.json" ]; then pass "T10 stamp written at end"; else fail "T10 stamp written at end" "no stamp"; fi
got_ver=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T10 stamp records template version" "1.0.0" "$got_ver"

# ---------------------------------------------------------------------------
# T12: NEVER-TOUCH invariant (fast unit) — user content is left byte-identical.
# Covers both never-enumerated paths (a note the template doesn't ship) and
# skip-classed files the template DOES ship (index.md, 50-Journal/_index.md).
T="$TMP/t12-tmpl"; V="$TMP/t12-vault"; make_template "$T" "1.0.0"
mkdir -p "$T/50-Journal" "$V/50-Journal/Daily" "$V/scripts/hooks"; stamp_vault "$V" "0.1.0"
# Template SHIPS these skip-classed scaffold files; the vault has user-edited them.
printf '# Vault Index (template ships this; skip-classed)\n' > "$T/index.md"
printf '# Journal index template\n' > "$T/50-Journal/_index.md"
printf '# MY EDITED INDEX — keep me\n' > "$V/index.md"
printf '# MY EDITED JOURNAL INDEX\n' > "$V/50-Journal/_index.md"
# Pure user content the template never ships at all.
printf 'my private daily note body\n' > "$V/50-Journal/Daily/2026-06-19.md"
printf 'SECRET=should-never-be-touched\n' > "$V/.env"
# Give it a real reason to run (a diverged owned file).
printf 'STALE\n' > "$V/scripts/hooks/check-commit-msg.sh"
ut_before=$( { sha_of "$V/index.md"; sha_of "$V/50-Journal/_index.md"; sha_of "$V/50-Journal/Daily/2026-06-19.md"; sha_of "$V/.env"; } )
run_upgrade --yes >/dev/null 2>&1
ut_after=$( { sha_of "$V/index.md"; sha_of "$V/50-Journal/_index.md"; sha_of "$V/50-Journal/Daily/2026-06-19.md"; sha_of "$V/.env"; } )
assert_eq "T12 user content (shipped-skip + never-shipped + .env) untouched" "$ut_before" "$ut_after"
assert_eq "T12 the run still applied the owned file" "$(sha_of "$T/scripts/hooks/check-commit-msg.sh")" "$(sha_of "$V/scripts/hooks/check-commit-msg.sh")"

# ---------------------------------------------------------------------------
# T13: vault AHEAD of template => no-op (downgrade protection), zero mutations.
T="$TMP/t13-tmpl"; V="$TMP/t13-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/scripts/hooks"; stamp_vault "$V" "2.0.0"
printf 'STALE\n' > "$V/scripts/hooks/check-commit-msg.sh"
before=$(find "$V" -type f -exec "${SHA256[@]}" {} \; | sort)
out=$(run_upgrade --yes 2>&1); rc=$?
after=$(find "$V" -type f -exec "${SHA256[@]}" {} \; | sort)
assert_eq "T13 vault-ahead rc" "0" "$rc"
case "$out" in *already*current*) pass "T13 vault-ahead reports already-current" ;; *) fail "T13 vault-ahead reports already-current" "got: $out" ;; esac
assert_eq "T13 vault-ahead made zero changes" "$before" "$after"

# ---------------------------------------------------------------------------
# T14: a malformed (non-array) community-plugins.json is left UNTOUCHED + warns,
# never coerced to a template-only list (would destroy the user's plugin set).
T="$TMP/t14-tmpl"; V="$TMP/t14-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.obsidian"; stamp_vault "$V" "0.1.0"
printf '%s\n' '{"corrupt":"not an array"}' > "$V/.obsidian/community-plugins.json"
cp_before=$(sha_of "$V/.obsidian/community-plugins.json")
out=$(run_upgrade --yes 2>&1)
assert_eq "T14 malformed community-plugins untouched" "$cp_before" "$(sha_of "$V/.obsidian/community-plugins.json")"
case "$out" in *"not a JSON array"*|*"unreadable"*) pass "T14 malformed community-plugins warns" ;; *) fail "T14 malformed community-plugins warns" "got: $out" ;; esac

# ---------------------------------------------------------------------------
# T15: a write failure is fail-closed — refuse the stamp + exit non-zero, so a
# partial upgrade re-runs instead of being masked "current". Forced portably by
# making a target's parent a regular FILE (mkdir/cp under it fails).
T="$TMP/t15-tmpl"; V="$TMP/t15-vault"; make_template "$T" "1.0.0"
mkdir -p "$T/scripts/extra" "$V/scripts" "$V/.obsidian"; stamp_vault "$V" "0.1.0"
printf '#!/usr/bin/env bash\necho extra\n' > "$T/scripts/extra/tool.sh"
printf '%s\n' '["dataview"]' > "$V/.obsidian/community-plugins.json"
printf 'I AM A FILE NOT A DIR\n' > "$V/scripts/extra"   # blocks the write of scripts/extra/tool.sh
out=$(run_upgrade --yes 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then pass "T15 write-failure exits non-zero"; else fail "T15 write-failure exits non-zero" "rc=0"; fi
case "$out" in *"NOT writing the version stamp"*) pass "T15 write-failure refuses the stamp" ;; *) fail "T15 write-failure refuses the stamp" "got: $out" ;; esac
got_ver=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T15 write-failure does not advance stamp" "0.1.0" "$got_ver"

# ---------------------------------------------------------------------------
# T16: resolver — generic known-path discovery (HIMMEL-389 Phase 2). With
# --template-dir AND $HIMMEL_DIR unset and no himmel sibling, the resolver finds
# the template via a generic $HOME-relative candidate path. Simulate by pointing
# $HOME at a temp tree that holds github/himmel/templates/luna-second-brain.
T16HOME="$TMP/t16-home"; T="$T16HOME/github/himmel/templates/luna-second-brain"; make_template "$T" "1.0.0"
V="$TMP/t16-vault"; mkdir -p "$V/scripts/hooks"; stamp_vault "$V" "0.1.0"
printf 'STALE\n' > "$V/scripts/hooks/check-commit-msg.sh"
out=$(env -u HIMMEL_DIR HOME="$T16HOME" bash "$UPGRADE" --vault-dir "$V" --dry-run 2>&1); rc=$?
assert_eq "T16 candidate-path rc" "0" "$rc"
case "$out" in *"t16-home/github/himmel/templates/luna-second-brain"*) pass "T16 resolves via generic candidate path" ;; *) fail "T16 resolves via generic candidate path" "got: $out" ;; esac
# A SINGLE clone must never false-warn. On a case-insensitive FS (Windows/macOS)
# the `himmel` and `Himmel` candidate spellings BOTH resolve to this one dir, so
# this case exercises the device:inode dedup branch (same key => no warn).
case "$out" in *"multiple himmel checkouts"*) fail "T16 single clone: no false multi-checkout warn" "warned: $out" ;; *) pass "T16 single clone: no false multi-checkout warn (dedup branch)" ;; esac

# ---------------------------------------------------------------------------
# T17: resolver — explicit config ALWAYS wins over the candidate paths.
#   (a) $HIMMEL_DIR beats a candidate-path template.
#   (b) --template-dir beats both $HIMMEL_DIR and the candidate.
T17HOME="$TMP/t17-home"; CAND="$T17HOME/github/himmel/templates/luna-second-brain"; make_template "$CAND" "9.9.9"
HD="$TMP/t17-hd"; make_template "$HD/templates/luna-second-brain" "2.0.0"
TDARG="$TMP/t17-td"; make_template "$TDARG" "3.0.0"
V="$TMP/t17-vault"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
out=$(HOME="$T17HOME" HIMMEL_DIR="$HD" bash "$UPGRADE" --vault-dir "$V" --dry-run 2>&1)
case "$out" in *"t17-hd/templates/luna-second-brain"*) pass "T17a HIMMEL_DIR wins over candidate path" ;; *) fail "T17a HIMMEL_DIR wins over candidate path" "got: $out" ;; esac
case "$out" in *"t17-home/github/himmel"*) fail "T17a HIMMEL_DIR wins over candidate path" "candidate leaked: $out" ;; *) pass "T17a candidate path not used when HIMMEL_DIR set" ;; esac
out=$(HOME="$T17HOME" HIMMEL_DIR="$HD" bash "$UPGRADE" --template-dir "$TDARG" --vault-dir "$V" --dry-run 2>&1)
case "$out" in *"t17-td"*) pass "T17b --template-dir wins over HIMMEL_DIR + candidate" ;; *) fail "T17b --template-dir wins over HIMMEL_DIR + candidate" "got: $out" ;; esac

# ---------------------------------------------------------------------------
# T18: resolver — clear error + hint when nothing resolves (no --template-dir,
# $HIMMEL_DIR unset, $HOME has no candidate, vault has no himmel sibling).
V="$TMP/t18-iso/vault"; mkdir -p "$V"
out=$(env -u HIMMEL_DIR HOME="$TMP/t18-emptyhome" bash "$UPGRADE" --vault-dir "$V" --dry-run 2>&1); rc=$?
assert_eq "T18 no-resolve rc" "2" "$rc"
case "$out" in *"set HIMMEL_DIR"*) pass "T18 prints the set-HIMMEL_DIR hint" ;; *) fail "T18 prints the set-HIMMEL_DIR hint" "got: $out" ;; esac

# ---------------------------------------------------------------------------
# T19: resolver — TWO physically-distinct candidate checkouts under $HOME warn
# and resolve to the FIRST in loop order (github/himmel before Documents/...).
# Guards the silent dual-clone auto-pick (HIMMEL-389 Phase 2 CR).
T19HOME="$TMP/t19-home"
make_template "$T19HOME/github/himmel/templates/luna-second-brain" "1.1.1"
make_template "$T19HOME/Documents/github/himmel/templates/luna-second-brain" "2.2.2"
V="$TMP/t19-vault"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
out=$(env -u HIMMEL_DIR HOME="$T19HOME" bash "$UPGRADE" --vault-dir "$V" --dry-run 2>&1); rc=$?
assert_eq "T19 multi-checkout rc" "0" "$rc"
case "$out" in *"multiple himmel checkouts"*) pass "T19 warns on multiple distinct checkouts" ;; *) fail "T19 warns on multiple distinct checkouts" "got: $out" ;; esac
case "$out" in *"(v1.1.1)"*) pass "T19 resolves to first candidate (github/himmel, v1.1.1)" ;; *) fail "T19 resolves to first candidate (github/himmel, v1.1.1)" "got: $out" ;; esac
case "$out" in *"(v2.2.2)"*) fail "T19 must not pick the later Documents candidate" "v2.2.2 leaked: $out" ;; *) pass "T19 does not pick the later Documents candidate" ;; esac

# ---------------------------------------------------------------------------
# T20: resolver — a candidate dir WITHOUT marketplace.json is a decoy: skip it
# and resolve a later valid candidate instead of selecting-then-aborting. One
# valid candidate => no multi-checkout warning.
T20HOME="$TMP/t20-home"
mkdir -p "$T20HOME/github/himmel/templates/luna-second-brain"   # decoy: dir, no marketplace.json
make_template "$T20HOME/Documents/github/himmel/templates/luna-second-brain" "3.3.3"
V="$TMP/t20-vault"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
out=$(env -u HIMMEL_DIR HOME="$T20HOME" bash "$UPGRADE" --vault-dir "$V" --dry-run 2>&1); rc=$?
assert_eq "T20 decoy-skip rc" "0" "$rc"
case "$out" in *"(v3.3.3)"*) pass "T20 skips the decoy and resolves the valid candidate" ;; *) fail "T20 skips the decoy and resolves the valid candidate" "got: $out" ;; esac
case "$out" in *"multiple himmel checkouts"*) fail "T20 must not warn (only one valid)" "warned: $out" ;; *) pass "T20 no false multi-checkout warn with a decoy present" ;; esac

# ---------------------------------------------------------------------------
# T21: sibling scan — a decoy sibling (dir, no marketplace.json) is SKIPPED and a
# later valid sibling resolves; one valid => no warning (HIMMEL-420 — the sibling
# surface now matches the $HOME-candidate surface). Forces the sibling path with
# $HIMMEL_DIR unset + a $HOME holding no candidate, and the vault under $base.
T21BASE="$TMP/t21-base"
mkdir -p "$T21BASE/himmel/templates/luna-second-brain"   # decoy sibling: no marketplace.json
make_template "$T21BASE/ztools-himmel/templates/luna-second-brain" "4.4.4"
V="$T21BASE/vault"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
out=$(env -u HIMMEL_DIR HOME="$TMP/t21-emptyhome" bash "$UPGRADE" --vault-dir "$V" --dry-run 2>&1); rc=$?
assert_eq "T21 sibling decoy-skip rc" "0" "$rc"
case "$out" in *"(v4.4.4)"*) pass "T21 sibling scan skips the decoy and resolves the valid sibling" ;; *) fail "T21 sibling scan skips the decoy and resolves the valid sibling" "got: $out" ;; esac
case "$out" in *"multiple himmel checkouts"*) fail "T21 sibling must not warn (only one valid)" "warned: $out" ;; *) pass "T21 sibling no false multi-checkout warn with a decoy present" ;; esac

# ---------------------------------------------------------------------------
# T22: sibling scan — TWO physically-distinct valid sibling checkouts warn and
# resolve to the explicit `himmel` first (HIMMEL-420).
T22BASE="$TMP/t22-base"
make_template "$T22BASE/himmel/templates/luna-second-brain" "5.5.5"
make_template "$T22BASE/zzz-himmel/templates/luna-second-brain" "6.6.6"
V="$T22BASE/vault"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
out=$(env -u HIMMEL_DIR HOME="$TMP/t22-emptyhome" bash "$UPGRADE" --vault-dir "$V" --dry-run 2>&1); rc=$?
assert_eq "T22 sibling multi rc" "0" "$rc"
case "$out" in *"multiple himmel checkouts"*) pass "T22 sibling scan warns on multiple distinct checkouts" ;; *) fail "T22 sibling scan warns on multiple distinct checkouts" "got: $out" ;; esac
case "$out" in *"(v5.5.5)"*) pass "T22 sibling resolves to explicit 'himmel' first" ;; *) fail "T22 sibling resolves to explicit 'himmel' first" "got: $out" ;; esac
case "$out" in *"(v6.6.6)"*) fail "T22 must not pick the later glob match zzz-himmel" "v6.6.6 leaked: $out" ;; *) pass "T22 sibling does not pick the later glob match" ;; esac

# ---------------------------------------------------------------------------
# T23: --check on a BEHIND vault prints the upgrade-available nudge, exits 0, and
# mutates nothing (HIMMEL-423 Phase 3).
T="$TMP/t23-tmpl"; V="$TMP/t23-vault"; make_template "$T" "2.0.0"; mkdir -p "$V/scripts/hooks"; stamp_vault "$V" "1.0.0"
printf 'STALE\n' > "$V/scripts/hooks/check-commit-msg.sh"
before=$(find "$V" -type f -exec "${SHA256[@]}" {} \; | sort)
out=$(run_upgrade --check 2>&1); rc=$?
after=$(find "$V" -type f -exec "${SHA256[@]}" {} \; | sort)
assert_eq "T23 --check behind rc" "0" "$rc"
case "$out" in *"template v2.0.0 available"*) pass "T23 --check prints the upgrade-available nudge" ;; *) fail "T23 --check prints the upgrade-available nudge" "got: $out" ;; esac
assert_eq "T23 --check made zero changes" "$before" "$after"
# --check is a single-line nudge: it must NOT print the upgrade banner/plan.
case "$out" in *"==> luna-second-brain upgrade"*) fail "T23 --check must not print the upgrade banner" "got: $out" ;; *) pass "T23 --check emits no upgrade banner/plan" ;; esac

# ---------------------------------------------------------------------------
# T24: --check on a CURRENT vault prints the already-current line, exits 0.
T="$TMP/t24-tmpl"; V="$TMP/t24-vault"; make_template "$T" "1.0.0"; mkdir -p "$V"; stamp_vault "$V" "1.0.0"
out=$(run_upgrade --check 2>&1); rc=$?
assert_eq "T24 --check current rc" "0" "$rc"
case "$out" in *"vault is current (v1.0.0)"*) pass "T24 --check reports current" ;; *) fail "T24 --check reports current" "got: $out" ;; esac

# ---------------------------------------------------------------------------
# T25: --check on an UN-STAMPED (pre-versioning) vault — the most likely first-run
# state — treats it as v0.0.0 and reports the upgrade as available, exit 0.
T="$TMP/t25-tmpl"; V="$TMP/t25-vault"; make_template "$T" "1.0.0"; mkdir -p "$V"
out=$(run_upgrade --check 2>&1); rc=$?
assert_eq "T25 --check un-stamped rc" "0" "$rc"
case "$out" in *"(vault is v0.0.0)"*) pass "T25 --check treats un-stamped vault as v0.0.0 (available)" ;; *) fail "T25 --check treats un-stamped vault as v0.0.0 (available)" "got: $out" ;; esac

# ---------------------------------------------------------------------------
# T11: ACCEPTANCE — run against a COPY of the real luna vault, never the live one.
LUNA="$HOME/Documents/luna"
if [ -d "$LUNA" ] && [ -d "$LUNA/50-Journal" ]; then
    VC="$TMP/luna-copy"
    cp -r "$LUNA" "$VC" 2>/dev/null
    # Remove any nested .git to keep the copy a plain dir (avoid worktree confusion).
    rm -rf "$VC/.git"
    REALTMPL="$(cd "$HERE/.." && pwd)"   # this template's own root (scripts/..)
    journal_before=$(find "$VC/50-Journal" -type f -exec "${SHA256[@]}" {} \; 2>/dev/null | sort)
    claude_before=$(sha_of "$VC/_CLAUDE.md")
    claude_title_before=$(head -n 1 "$VC/_CLAUDE.md")
    bash "$UPGRADE" --template-dir "$REALTMPL" --vault-dir "$VC" --yes >/dev/null 2>&1; rc=$?
    journal_after=$(find "$VC/50-Journal" -type f -exec "${SHA256[@]}" {} \; 2>/dev/null | sort)
    assert_eq "T11 acceptance rc" "0" "$rc"
    assert_eq "T11 journal bodies unchanged" "$journal_before" "$journal_after"
    # _CLAUDE.md contract depends on whether the vault carries a base snapshot
    # (HIMMEL-1750): with NO base, ours wins and the file must be byte-stable;
    # WITH a base, a legitimate template delta MAY merge in — byte-equality
    # would then fail on every template _CLAUDE.md change (hit live when the
    # Retrieval Routing section shipped). In that state assert what actually
    # matters: the merge completed without conflict markers and the vault's
    # user content (the vault-specific title line) survived.
    if [ -f "$VC/.vault-template.base/_CLAUDE.md" ]; then
        if grep -q '^<<<<<<<' "$VC/_CLAUDE.md"; then
            fail "T11 _CLAUDE.md merged without conflict markers" "conflict markers present"
        else
            pass "T11 _CLAUDE.md merged without conflict markers"
        fi
        # Full-line equality, not substring (CR codex r5): a modified first
        # line CONTAINING the old title as a fragment must fail.
        if [ "$(head -n 1 "$VC/_CLAUDE.md")" = "$claude_title_before" ]; then
            pass "T11 _CLAUDE.md user content survived the merge (title line intact)"
        else
            fail "T11 _CLAUDE.md user content survived the merge (title line intact)" "title line changed"
        fi
    else
        assert_eq "T11 _CLAUDE.md user content unchanged (no base => ours wins)" "$claude_before" "$(sha_of "$VC/_CLAUDE.md")"
    fi
    if [ -f "$VC/.vault-template.json" ]; then pass "T11 stamp written on real-vault copy"; else fail "T11 stamp written on real-vault copy" "no stamp"; fi
    assert_eq "T11 template-owned setup.sh updated to template" "$(sha_of "$REALTMPL/scripts/setup.sh")" "$(sha_of "$VC/scripts/setup.sh")"
else
    echo "SKIP T11 acceptance — no real luna vault at $LUNA"
fi

# ---------------------------------------------------------------------------
# T26 (HIMMEL-521): the REAL template's two version sources must agree.
# upgrade.sh reads marketplace.json metadata.version (the authoritative version
# for the upgrade comparison + the written stamp); setup.sh seeds a freshly
# scaffolded vault from .vault-template.json. If the two drift, /luna-upgrade
# reports "already current" for already-stamped vaults even when template
# content shipped — exactly the HIMMEL-501 regression (it bumped only the seed,
# stranding the 501+460 template changes). Guard so the anchors can never
# silently diverge again.
REALTMPL="$(cd "$HERE/.." && pwd)"
mkt_ver=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["metadata"]["version"])' "$REALTMPL/marketplace/.claude-plugin/marketplace.json" 2>/dev/null)
seed_ver=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REALTMPL/.vault-template.json" 2>/dev/null)
# Non-empty guard: a read failure (renamed key/path) would leave both empty and
# make a naked assert_eq "" "" pass green — defeating the guard. Fail loud instead.
if [ -z "$mkt_ver" ] || [ -z "$seed_ver" ]; then
    fail "T26 marketplace.json metadata.version == .vault-template.json version (no drift)" "could not read a version (marketplace='$mkt_ver' seed='$seed_ver')"
else
    assert_eq "T26 marketplace.json metadata.version == .vault-template.json version (no drift)" "$mkt_ver" "$seed_ver"
fi

# ---------------------------------------------------------------------------
# T27 (HIMMEL-1366): a _CLAUDE.md conflict with 2+ HUNKS must still be
# classified as a conflict, not an error. git merge-file's exit code is the
# NUMBER of conflict hunks (0 = clean, 1..127 = N-hunk conflict, >=128 = a real
# error). The old code only treated rc==1 as a conflict, so any multi-hunk
# conflict (rc>=2) fell through to the error branch: no sidecar written, the
# error message pointed at a file that was never created, and the operator had
# nothing to resolve. The divergences here are WELL-SEPARATED (10 identical
# lines between each) so git emits separate hunks (rc=5, not rc=1) — without
# that spacing git coalesces them into one hunk and this silently degrades into
# the single-hunk case T6 already covers.
T="$TMP/t27-tmpl"; V="$TMP/t27-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.vault-template.base"; stamp_vault "$V" "0.1.0"
gen_claude() {  # $1 = per-marker prefix (BASE/OURS/THEIRS); 5 divergent lines, 10 common apart
    local pfx="$1"
    local i
    printf '# Operating Manual\n'
    for i in 1 2 3 4 5; do
        printf 'c1\nc2\nc3\nc4\nc5\nc6\nc7\nc8\nc9\nc10\n'   # 10 lines identical in all three
        printf '%s-marker-%s\n' "$pfx" "$i"                   # the line both sides edit differently
    done
}
gen_claude BASE   > "$V/.vault-template.base/_CLAUDE.md"
gen_claude OURS   > "$V/_CLAUDE.md"
gen_claude THEIRS > "$T/_CLAUDE.md"
ours_before=$(sha_of "$V/_CLAUDE.md")
out=$(run_upgrade --yes 2>&1); rc=$?
# (a) classified as a conflict, NOT an error. The conflict branch writes the
#     sidecar and plans "(CONFLICT — ...)" ; the error branch writes no sidecar
#     and plans "(ERROR — git merge-file failed)". Either alone discriminates.
if [ -f "$V/_CLAUDE.md.template-merge" ]; then pass "T27 multi-hunk classified as conflict (sidecar written)"; else fail "T27 multi-hunk classified as conflict (sidecar written)" "no sidecar — fell into the error branch (HIMMEL-1366)"; fi
case "$out" in *"ERROR — git merge-file failed"*) fail "T27 multi-hunk not classified as error" "error plan hit: $out" ;; *) pass "T27 multi-hunk not classified as error" ;; esac
# (b) the sidecar actually holds the conflicted 3-way merge (>=2 conflict markers).
if [ -f "$V/_CLAUDE.md.template-merge" ]; then markers=$(grep -c '<<<<<<<' "$V/_CLAUDE.md.template-merge"); else markers=0; fi
if [ "$markers" -ge 2 ]; then pass "T27 sidecar holds $markers conflict hunks"; else fail "T27 sidecar holds 2+ conflict hunks" "markers=$markers"; fi
# (c) the vault's _CLAUDE.md is left byte-identical.
assert_eq "T27 multi-hunk leaves _CLAUDE.md untouched" "$ours_before" "$(sha_of "$V/_CLAUDE.md")"
# (d) the version stamp is NOT advanced (so a re-run re-surfaces the conflict).
got_ver=$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T27 multi-hunk does not advance the stamp" "0.1.0" "$got_ver"
# A conflict must also exit non-zero.
if [ "$rc" -ne 0 ]; then pass "T27 multi-hunk conflict exits non-zero"; else fail "T27 multi-hunk conflict exits non-zero" "rc=0"; fi

# ---------------------------------------------------------------------------
# T28 (HIMMEL-525): bundled plugin assets (main.js, manifest.json, styles.css
# under .obsidian/plugins/*/) are FIRST-POPULATION ONLY (skipexists), never
# overwrite. A vault whose installed plugin is NEWER than the template bundle
# must NOT be downgraded (live incident: obsidian-local-rest-api 4.1.3 -> 4.0.1,
# qmd-as-md-obsidian 0.4.3 -> 0.3.4). data.json is already skipexists (T4); the
# three asset files now match it.
#   (a) downgrade protection — a newer installed plugin is left byte-identical.
#   (b) first-population — an ABSENT plugin is still seeded from the bundle.
T="$TMP/t28-tmpl"; V="$TMP/t28-vault"; make_template "$T" "1.0.0"
mkdir -p "$V/.obsidian/plugins/obsidian-local-rest-api"; stamp_vault "$V" "0.1.0"
# Template BUNDLES the plugin at an OLDER version (4.0.1).
mkdir -p "$T/.obsidian/plugins/obsidian-local-rest-api"
printf '{"id":"obsidian-local-rest-api","version":"4.0.1"}\n' > "$T/.obsidian/plugins/obsidian-local-rest-api/manifest.json"
printf 'TEMPLATE-MAIN-JS-4.0.1\n'                              > "$T/.obsidian/plugins/obsidian-local-rest-api/main.js"
printf 'TEMPLATE-STYLES-4.0.1\n'                               > "$T/.obsidian/plugins/obsidian-local-rest-api/styles.css"
# Vault has the SAME plugin at a NEWER version (4.1.3) the adopter self-updated to.
printf '{"id":"obsidian-local-rest-api","version":"4.1.3"}\n' > "$V/.obsidian/plugins/obsidian-local-rest-api/manifest.json"
printf 'VAULT-MAIN-JS-4.1.3\n'                                 > "$V/.obsidian/plugins/obsidian-local-rest-api/main.js"
printf 'VAULT-STYLES-4.1.3\n'                                  > "$V/.obsidian/plugins/obsidian-local-rest-api/styles.css"
m_before=$(sha_of "$V/.obsidian/plugins/obsidian-local-rest-api/manifest.json")
j_before=$(sha_of "$V/.obsidian/plugins/obsidian-local-rest-api/main.js")
s_before=$(sha_of "$V/.obsidian/plugins/obsidian-local-rest-api/styles.css")
run_upgrade --yes >/dev/null 2>&1
assert_eq "T28 newer manifest.json NOT downgraded" "$m_before" "$(sha_of "$V/.obsidian/plugins/obsidian-local-rest-api/manifest.json")"
assert_eq "T28 newer main.js NOT downgraded"       "$j_before" "$(sha_of "$V/.obsidian/plugins/obsidian-local-rest-api/main.js")"
assert_eq "T28 newer styles.css NOT downgraded"    "$s_before" "$(sha_of "$V/.obsidian/plugins/obsidian-local-rest-api/styles.css")"
# (b) first-population: a fresh vault with the plugin ABSENT must still be seeded.
# NOTE: run_upgrade() closes over $V, so call upgrade.sh directly for the $V2
# vault (same pattern T11/T16 use for a non-default vault dir).
V2="$TMP/t28-vault-fp"; mkdir -p "$V2"; stamp_vault "$V2" "0.1.0"
# Precondition (CR): the fixture must actually be plugin-absent, or (b) stops
# covering first-population without failing.
test ! -e "$V2/.obsidian/plugins/obsidian-local-rest-api"
bash "$UPGRADE" --template-dir "$T" --vault-dir "$V2" --yes >/dev/null 2>&1
assert_eq "T28 first-population seeds absent manifest.json" "$(sha_of "$T/.obsidian/plugins/obsidian-local-rest-api/manifest.json")" "$(sha_of "$V2/.obsidian/plugins/obsidian-local-rest-api/manifest.json")"
assert_eq "T28 first-population seeds absent main.js"       "$(sha_of "$T/.obsidian/plugins/obsidian-local-rest-api/main.js")"       "$(sha_of "$V2/.obsidian/plugins/obsidian-local-rest-api/main.js")"
assert_eq "T28 first-population seeds absent styles.css"    "$(sha_of "$T/.obsidian/plugins/obsidian-local-rest-api/styles.css")"    "$(sha_of "$V2/.obsidian/plugins/obsidian-local-rest-api/styles.css")"

# ---------------------------------------------------------------------------
# T29 (HIMMEL-2886): a template-owned "overwrite"-class file the vault
# COMMITTED a local edit to since its last stamped upgrade must not be
# silently clobbered — the actual incident (luna-upgrade-all apply on
# ~/Documents/luna, 2026-09-09) had a CLEAN git status (the edit was
# committed), so a dirty-tree check alone can't catch it; the fixture
# reproduces that shape (git-tracked, clean, edit committed after the stamp).
T="$TMP/t29-tmpl"; V="$TMP/t29-vault"
make_template "$T" "0.9.0"
printf 'gitleaks-content-v1\n' > "$T/.gitleaks.toml"
mkdir -p "$V"; cp -r "$T/." "$V/"; rm -f "$V/marketplace/.claude-plugin/marketplace.json"
stamp_vault "$V" "0.9.0"
git -C "$V" init -q
git -C "$V" config user.email "test@example.com"
git -C "$V" config user.name "Test"
git -C "$V" add -A
git -C "$V" commit -q -m "initial stamp 0.9.0"; t29_commit1_rc=$?
assert_eq "T29 setup: initial commit landed" "0" "$t29_commit1_rc"
# The vault-local edit, COMMITTED (git status is clean afterwards) — matches
# the real incident, not an uncommitted-dirty-tree case (already guarded
# elsewhere).
printf 'gitleaks-content-v1\nlocal-allowlist-line\n' > "$V/.gitleaks.toml"
git -C "$V" add -A
git -C "$V" commit -q -m "add local allowlist line"; t29_commit2_rc=$?
assert_eq "T29 setup: local-edit commit landed" "0" "$t29_commit2_rc"
assert_eq "T29 setup: working tree is clean (matches the incident's shape, not a dirty-tree case)" "" "$(git -C "$V" status --porcelain)"
# Bump the template so an upgrade is available, and change its .gitleaks.toml
# too (a genuine incoming template change, not just a version bump).
printf '{"metadata":{"version":"1.0.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf 'gitleaks-content-v2\n' > "$T/.gitleaks.toml"

t29_pre_sha=$(sha_of "$V/.gitleaks.toml")
t29_dry=$(bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --dry-run 2>&1)
case "$t29_dry" in
    *"LOCAL-EDIT"*".gitleaks.toml"*) pass "T29 dry-run surfaces LOCAL-EDIT for .gitleaks.toml" ;;
    *) fail "T29 dry-run surfaces LOCAL-EDIT for .gitleaks.toml" "got: $t29_dry" ;;
esac
case "$t29_dry" in
    *"local edits withheld (not overwritten): .gitleaks.toml"*) pass "T29 dry-run prints local-edits-withheld line" ;;
    *) fail "T29 dry-run prints local-edits-withheld line" "got: $t29_dry" ;;
esac

t29_out=$(bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --backup-dir "$TMP/t29-backup" --yes 2>&1)
t29_rc=$?
assert_eq "T29 apply does NOT overwrite the locally-edited file" "$t29_pre_sha" "$(sha_of "$V/.gitleaks.toml")"
case "$t29_out" in
    *"local edits withheld (not overwritten): .gitleaks.toml (backup: $TMP/t29-backup/.gitleaks.toml)"*)
        pass "T29 apply names the backup path" ;;
    *) fail "T29 apply names the backup path" "got: $t29_out" ;;
esac
if [ "$t29_rc" -ne 0 ]; then
    pass "T29 apply exits non-zero (not a clean upgrade)"
else
    fail "T29 apply exits non-zero (not a clean upgrade)" "rc=0, out: $t29_out"
fi
t29_stamp=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T29 stamp NOT advanced while a local edit is withheld" "0.9.0" "$t29_stamp"


# ---------------------------------------------------------------------------
# T30 (HIMMEL-2903): the local-edit baseline is a per-file content SNAPSHOT
# recorded in the stamp, not the vault's git history — so an edit committed in
# the SAME commit that advances the stamp (a batching autosync, exactly what
# the luna github-sync plugin does every 10 min) is still caught. The git path
# structurally cannot see this case: that commit IS the baseline it reads, and
# it already contains the edit.
T="$TMP/t30-tmpl"; V="$TMP/t30-vault"
make_template "$T" "0.9.0"
printf 'gitleaks-content-v1\n' > "$T/.gitleaks.toml"
mkdir -p "$V"; cp -r "$T/." "$V/"; rm -f "$V/marketplace/.claude-plugin/marketplace.json"
stamp_vault "$V" "0.1.0"
git -C "$V" init -q
git -C "$V" config user.email "test@example.com"
git -C "$V" config user.name "Test"
git -C "$V" add -A
git -C "$V" commit -q -m "initial"
# Upgrade #1 brings the vault to 0.9.0 AND records the content snapshot.
bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes >/dev/null 2>&1
t30_snap=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("files",{}).get(".gitleaks.toml",""))' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T30 stamp records a content snapshot for .gitleaks.toml" "sha256:$(sha_of "$V/.gitleaks.toml")" "$t30_snap"
# The POISONING commit: the vault-local edit and the advanced stamp land in ONE
# commit, so the commit the git path resolves as the baseline already carries
# the edit.
printf 'gitleaks-content-v1\nlocal-allowlist-line\n' > "$V/.gitleaks.toml"
git -C "$V" add -A
git -C "$V" commit -q -m "autosync: local allowlist line + stamp 0.9.0"
t30_stamp_commit=$(git -C "$V" log -1 --format=%H -- .vault-template.json)
git -C "$V" show "$t30_stamp_commit:./.gitleaks.toml" > "$TMP/t30-git-baseline" 2>/dev/null
assert_eq "T30 setup: the git baseline is poisoned (it already carries the edit)" "$(sha_of "$V/.gitleaks.toml")" "$(sha_of "$TMP/t30-git-baseline")"
# A newer template that changes the same file.
printf '{"metadata":{"version":"1.0.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf 'gitleaks-content-v2\n' > "$T/.gitleaks.toml"
t30_pre_sha=$(sha_of "$V/.gitleaks.toml")
t30_dry=$(bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --dry-run 2>&1)
case "$t30_dry" in
    *"local edits withheld (not overwritten): .gitleaks.toml"*"[baseline: snapshot]"*)
        pass "T30 dry-run withholds .gitleaks.toml naming the snapshot provenance" ;;
    *) fail "T30 dry-run withholds .gitleaks.toml naming the snapshot provenance" "got: $t30_dry" ;;
esac
# A file whose content still MATCHES its snapshot is not a local edit — the
# snapshot must not withhold every differing file indiscriminately.
case "$t30_dry" in
    *"withheld (not overwritten): marketplace/.claude-plugin/marketplace.json"*)
        fail "T30 dry-run still WRITES an unedited snapshot-matching file" "marketplace.json was withheld" ;;
    *"WRITE        marketplace/.claude-plugin/marketplace.json"*)
        pass "T30 dry-run still WRITES an unedited snapshot-matching file" ;;
    *) fail "T30 dry-run still WRITES an unedited snapshot-matching file" "got: $t30_dry" ;;
esac
bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes >/dev/null 2>&1; t30_rc=$?
assert_eq "T30 apply does NOT overwrite the edit the git baseline cannot see" "$t30_pre_sha" "$(sha_of "$V/.gitleaks.toml")"
if [ "$t30_rc" -ne 0 ]; then pass "T30 apply exits non-zero (not a clean upgrade)"; else fail "T30 apply exits non-zero (not a clean upgrade)" "rc=0"; fi

# ---------------------------------------------------------------------------
# T31 (HIMMEL-2903): an OPERATIONAL `git log` failure (shallow clone, corrupt
# index, permission error) must fail CLOSED, like the cat-file/show steps
# already do — not be read as "no baseline" and fall through to the pre-2886
# silent overwrite. Simulated with a PATH stub `git` that fails ONLY for `log`.
T="$TMP/t31-tmpl"; V="$TMP/t31-vault"
make_template "$T" "0.9.0"
printf 'gitleaks-content-v1\n' > "$T/.gitleaks.toml"
mkdir -p "$V"; cp -r "$T/." "$V/"; rm -f "$V/marketplace/.claude-plugin/marketplace.json"
# A PRE-snapshot stamp (3 keys, no "files") — the git path is the only baseline.
stamp_vault "$V" "0.9.0"
git -C "$V" init -q
git -C "$V" config user.email "test@example.com"
git -C "$V" config user.name "Test"
git -C "$V" add -A
git -C "$V" commit -q -m "initial stamp 0.9.0"
printf 'gitleaks-content-v1\nlocal-allowlist-line\n' > "$V/.gitleaks.toml"
git -C "$V" add -A
git -C "$V" commit -q -m "local edit after the stamp"
printf '{"metadata":{"version":"1.0.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf 'gitleaks-content-v2\n' > "$T/.gitleaks.toml"
t31_stub="$TMP/t31-stub"; mkdir -p "$t31_stub"
t31_real_git="$(command -v git)"
# shellcheck disable=SC2016  # the single-quoted lines are the STUB's source, not this shell's
{
    echo '#!/usr/bin/env bash'
    echo 'for a in "$@"; do'
    echo '    if [ "$a" = "log" ]; then echo "fatal: simulated git log failure" >&2; exit 128; fi'
    echo 'done'
    printf 'exec "%s" "$@"\n' "$t31_real_git"
} > "$t31_stub/git"
chmod +x "$t31_stub/git"
# The stub must actually do what the case claims: fail for `log`, pass every
# other subcommand through (a stub that broke ALL of git would "pass" this case
# for the wrong reason).
t31_log_rc=$(PATH="$t31_stub:$PATH" git -C "$V" log -1 --format=%H >/dev/null 2>&1; echo $?)
assert_eq "T31 setup: the stub makes git log fail operationally" "128" "$t31_log_rc"
assert_eq "T31 setup: the stub passes other subcommands through" "true" "$(PATH="$t31_stub:$PATH" git -C "$V" rev-parse --is-inside-work-tree 2>/dev/null)"
t31_pre_sha=$(sha_of "$V/.gitleaks.toml")
t31_out=$(PATH="$t31_stub:$PATH" bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes 2>&1); t31_rc=$?
assert_eq "T31 a failing git log withholds the write (fails closed)" "$t31_pre_sha" "$(sha_of "$V/.gitleaks.toml")"
case "$t31_out" in
    *"could not determine the upgrade baseline (git log failed) — withholding .gitleaks.toml as a precaution"*)
        pass "T31 names the failed baseline in the withheld line" ;;
    *) fail "T31 names the failed baseline in the withheld line" "got: $t31_out" ;;
esac
if [ "$t31_rc" -ne 0 ]; then pass "T31 apply exits non-zero (not a clean upgrade)"; else fail "T31 apply exits non-zero (not a clean upgrade)" "rc=0"; fi

# ---------------------------------------------------------------------------
# T32 (HIMMEL-2903): the fail-closed git-log gate must NOT fire on a vault whose
# repo simply has no commits yet — `git log` exits 128 there too ("does not have
# any commits yet"), but that is a legitimately absent baseline, not an
# operational failure. A blanket rc!=0 check would withhold every file on the
# first upgrade of a freshly `git init`-ed vault.
T="$TMP/t32-tmpl"; V="$TMP/t32-vault"
make_template "$T" "1.0.0"
printf 'gitleaks-content-v2\n' > "$T/.gitleaks.toml"
mkdir -p "$V"; cp -r "$T/." "$V/"
printf 'gitleaks-content-v1\n' > "$V/.gitleaks.toml"
stamp_vault "$V" "0.9.0"
git -C "$V" init -q
git -C "$V" config user.email "test@example.com"
git -C "$V" config user.name "Test"
if git -C "$V" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    fail "T32 setup: the vault repo has no commits yet" "HEAD resolves"
else
    pass "T32 setup: the vault repo has no commits yet"
fi
bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes >/dev/null 2>&1; t32_rc=$?
assert_eq "T32 first upgrade of a commitless vault still writes the template file" "$(sha_of "$T/.gitleaks.toml")" "$(sha_of "$V/.gitleaks.toml")"
assert_eq "T32 first upgrade of a commitless vault exits 0" "0" "$t32_rc"

# ---------------------------------------------------------------------------
# T33 (HIMMEL-2903, CR round 1 codex-1): the HEAD gate must read the EXACT rc.
# `rev-parse --verify -q HEAD` exits 1 for "HEAD names no commit" (T32's
# legitimately absent baseline) but 128 for an operational refs failure — an
# unreadable refs backend, say. Collapsing the two lets a refs-layer error
# masquerade as a fresh vault and fail OPEN, the same hole the git-log gate
# closes one step down. Simulated with a PATH stub `git` that fails ONLY for
# `rev-parse --verify` (so `--is-inside-work-tree` still succeeds and the
# block is actually entered).
T="$TMP/t33-tmpl"; V="$TMP/t33-vault"
make_template "$T" "0.9.0"
printf 'gitleaks-content-v1\n' > "$T/.gitleaks.toml"
mkdir -p "$V"; cp -r "$T/." "$V/"; rm -f "$V/marketplace/.claude-plugin/marketplace.json"
stamp_vault "$V" "0.9.0"
git -C "$V" init -q
git -C "$V" config user.email "test@example.com"
git -C "$V" config user.name "Test"
git -C "$V" add -A
git -C "$V" commit -q -m "initial stamp 0.9.0"
printf 'gitleaks-content-v1\nlocal-allowlist-line\n' > "$V/.gitleaks.toml"
git -C "$V" add -A
git -C "$V" commit -q -m "local edit after the stamp"
printf '{"metadata":{"version":"1.0.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf 'gitleaks-content-v2\n' > "$T/.gitleaks.toml"
t33_stub="$TMP/t33-stub"; mkdir -p "$t33_stub"
t33_real_git="$(command -v git)"
# shellcheck disable=SC2016  # the single-quoted lines are the STUB's source, not this shell's
{
    echo '#!/usr/bin/env bash'
    echo 'saw_rp=0; saw_verify=0'
    echo 'for a in "$@"; do'
    echo '    [ "$a" = "rev-parse" ] && saw_rp=1'
    echo '    [ "$a" = "--verify" ] && saw_verify=1'
    echo 'done'
    echo 'if [ "$saw_rp" = 1 ] && [ "$saw_verify" = 1 ]; then echo "fatal: simulated refs failure" >&2; exit 128; fi'
    printf 'exec "%s" "$@"\n' "$t33_real_git"
} > "$t33_stub/git"
chmod +x "$t33_stub/git"
# The stub must fail rev-parse --verify with 128 (NOT 1 — a 1 would be the
# legitimate no-commit answer and would prove nothing) and leave the
# work-tree probe working, or the case passes for the wrong reason.
t33_verify_rc=$(PATH="$t33_stub:$PATH" git -C "$V" rev-parse --verify -q HEAD >/dev/null 2>&1; echo $?)
assert_eq "T33 setup: the stub fails rev-parse --verify with 128, not 1" "128" "$t33_verify_rc"
assert_eq "T33 setup: the stub leaves --is-inside-work-tree working" "true" "$(PATH="$t33_stub:$PATH" git -C "$V" rev-parse --is-inside-work-tree 2>/dev/null)"
t33_pre_sha=$(sha_of "$V/.gitleaks.toml")
t33_out=$(PATH="$t33_stub:$PATH" bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes 2>&1); t33_rc=$?
assert_eq "T33 an operational rev-parse failure withholds the write (fails closed)" "$t33_pre_sha" "$(sha_of "$V/.gitleaks.toml")"
case "$t33_out" in
    *"could not determine the upgrade baseline (git rev-parse failed) — withholding .gitleaks.toml as a precaution"*)
        pass "T33 names rev-parse (not git log) as the failed baseline step" ;;
    *) fail "T33 names rev-parse (not git log) as the failed baseline step" "got: $t33_out" ;;
esac
if [ "$t33_rc" -ne 0 ]; then pass "T33 apply exits non-zero (not a clean upgrade)"; else fail "T33 apply exits non-zero (not a clean upgrade)" "rc=0"; fi

# ---------------------------------------------------------------------------
# T34 (HIMMEL-2903, CR round 1 codex-2): a snapshot scratch file that cannot be
# created must ABORT before the first write. The stamp is rewritten wholesale,
# so proceeding would strip the `files` map the vault already has — silently
# demoting it back to the poisonable git baseline. Simulated by pointing TMPDIR
# at a path that is not a directory, which is what makes mktemp fail.
T="$TMP/t34-tmpl"; V="$TMP/t34-vault"
make_template "$T" "0.9.0"
printf 'gitleaks-content-v1\n' > "$T/.gitleaks.toml"
mkdir -p "$V"; cp -r "$T/." "$V/"
stamp_vault "$V" "0.1.0"
# A first upgrade under the current template records the snapshot to protect.
bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes >/dev/null 2>&1
t34_files_before=$("$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("files",{})))' "$V/.vault-template.json" 2>/dev/null)
if [ "${t34_files_before:-0}" -gt 0 ]; then
    pass "T34 setup: the vault carries a content snapshot to protect"
else
    fail "T34 setup: the vault carries a content snapshot to protect" "files keys=$t34_files_before"
fi
t34_stamp_before=$(sha_of "$V/.vault-template.json")
printf '{"metadata":{"version":"1.0.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf 'gitleaks-content-v2\n' > "$T/.gitleaks.toml"
t34_notdir="$TMP/t34-not-a-dir"; printf 'x\n' > "$t34_notdir"
# Precondition: mktemp really does fail under this TMPDIR (otherwise the case
# would "pass" without ever exercising the abort).
t34_mktemp_rc=$(TMPDIR="$t34_notdir" mktemp >/dev/null 2>&1; echo $?)
if [ "$t34_mktemp_rc" -ne 0 ]; then pass "T34 setup: mktemp fails under the broken TMPDIR"; else fail "T34 setup: mktemp fails under the broken TMPDIR" "rc=0"; fi
t34_gitleaks_before=$(sha_of "$V/.gitleaks.toml")
t34_out=$(TMPDIR="$t34_notdir" bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes 2>&1); t34_rc=$?
assert_eq "T34 a failed snapshot scratch file aborts rather than writing" "$t34_gitleaks_before" "$(sha_of "$V/.gitleaks.toml")"
assert_eq "T34 the existing stamp (and its snapshot) is left intact" "$t34_stamp_before" "$(sha_of "$V/.vault-template.json")"
assert_eq "T34 the abort exits 2" "2" "$t34_rc"
case "$t34_out" in
    *"aborting before any change"*) pass "T34 says it aborted before changing anything" ;;
    *) fail "T34 says it aborted before changing anything" "got: $t34_out" ;;
esac


# ---------------------------------------------------------------------------
# T35/T36 (HIMMEL-2903, CR round 2): snapshot persistence must fail CLOSED on
# BOTH sides of the scratch file. The stamp is rewritten wholesale, so a run
# that records the snapshot only partially (append fails) or cannot read it
# back (read fails) would replace a complete baseline with a partial or absent
# one — the poisoned-baseline hole reopened from the other end.
#
# Isolating that needs a failure that touches ONLY the snapshot scratch file:
# a blanket read-only TMPDIR breaks the file writes and the _CLAUDE.md 3-way
# too, so the run fails for an unrelated reason and the case proves nothing.
# Hence a PATH stub `mktemp` that recognises the snapshot's OWN template
# (`luna-upgrade-snapshot.XXXXXX`) and hands back a file with a hostile mode,
# passing every other mktemp call through untouched.
#
# mk_mktemp_stub <dir> <mode> — a stub that chmods only the snapshot file.
mk_mktemp_stub() {
    local dir="$1" mode="$2" real; real="$(command -v mktemp)"
    mkdir -p "$dir"
    # shellcheck disable=SC2016  # the single-quoted lines are the STUB's source, not this shell's
    {
        echo '#!/usr/bin/env bash'
        printf 'real=%s\n' "$real"
        printf 'mode=%s\n' "$mode"
        echo 'for a in "$@"; do'
        echo '    if [ "$a" = "luna-upgrade-snapshot.XXXXXX" ]; then'
        echo '        f="$("$real" "$@")" || exit $?'
        echo '        chmod "$mode" "$f" || exit 1'
        printf '%s\n' '        printf "%s\\n" "$f"'
        echo '        exit 0'
        echo '    fi'
        echo 'done'
        echo 'exec "$real" "$@"'
    } > "$dir/mktemp"
    chmod +x "$dir/mktemp"
}

# t35_fixture <tmpl> <vault> — a vault already carrying a complete snapshot,
# plus a newer template that changes one overwrite-class file.
t35_fixture() {
    local t="$1" v="$2"
    make_template "$t" "0.9.0"
    printf 'gitleaks-content-v1\n' > "$t/.gitleaks.toml"
    mkdir -p "$v"; cp -r "$t/." "$v/"
    stamp_vault "$v" "0.1.0"
    bash "$UPGRADE" --template-dir "$t" --vault-dir "$v" --yes >/dev/null 2>&1
    printf '{"metadata":{"version":"1.0.0"}}\n' > "$t/marketplace/.claude-plugin/marketplace.json"
    printf 'gitleaks-content-v2\n' > "$t/.gitleaks.toml"
}

snap_keys() { "$PY" -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("files",{})))' "$1" 2>/dev/null; }

# --- T35: the APPEND half. A read-only scratch file (0444) means every
# record_snapshot row is dropped; the run must refuse to stamp.
T="$TMP/t35-tmpl"; V="$TMP/t35-vault"
t35_fixture "$T" "$V"
t35_keys_before=$(snap_keys "$V/.vault-template.json")
if [ "${t35_keys_before:-0}" -gt 0 ]; then pass "T35 setup: the vault carries a complete content snapshot"; else fail "T35 setup: the vault carries a complete content snapshot" "keys=$t35_keys_before"; fi
t35_stamp_before=$(sha_of "$V/.vault-template.json")
t35_stub="$TMP/t35-stub"; mk_mktemp_stub "$t35_stub" 0444
# Precondition: the stub really does hand back an unappendable snapshot file,
# and really does pass a NON-snapshot mktemp through writable (or the case
# would be the blanket-failure control it exists to replace).
t35_probe=$(PATH="$t35_stub:$PATH" mktemp -t luna-upgrade-snapshot.XXXXXX)
if printf 'x\n' >> "$t35_probe" 2>/dev/null; then fail "T35 setup: the stub's snapshot file rejects appends" "append succeeded"; else pass "T35 setup: the stub's snapshot file rejects appends"; fi
t35_other=$(PATH="$t35_stub:$PATH" mktemp)
if printf 'x\n' >> "$t35_other" 2>/dev/null; then pass "T35 setup: the stub passes other mktemp calls through writable"; else fail "T35 setup: the stub passes other mktemp calls through writable" "append failed"; fi
t35_out=$(PATH="$t35_stub:$PATH" bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes 2>&1); t35_rc=$?
assert_eq "T35 an unrecordable snapshot leaves the stamp byte-identical" "$t35_stamp_before" "$(sha_of "$V/.vault-template.json")"
assert_eq "T35 the existing snapshot survives intact" "$t35_keys_before" "$(snap_keys "$V/.vault-template.json")"
if [ "$t35_rc" -ne 0 ]; then pass "T35 exits non-zero rather than stamping"; else fail "T35 exits non-zero rather than stamping" "rc=0, out: $t35_out"; fi

# --- T36: the READ half. A write-only scratch file (0200) records fine but
# cannot be read back at stamp time; the stamp must not be written without it.
T="$TMP/t36-tmpl"; V="$TMP/t36-vault"
t35_fixture "$T" "$V"
t36_keys_before=$(snap_keys "$V/.vault-template.json")
t36_stamp_before=$(sha_of "$V/.vault-template.json")
t36_stub="$TMP/t36-stub"; mk_mktemp_stub "$t36_stub" 0200
t36_probe=$(PATH="$t36_stub:$PATH" mktemp -t luna-upgrade-snapshot.XXXXXX)
if printf 'x\n' >> "$t36_probe" 2>/dev/null; then pass "T36 setup: the stub's snapshot file accepts appends"; else fail "T36 setup: the stub's snapshot file accepts appends" "append failed"; fi
if cat "$t36_probe" >/dev/null 2>&1; then fail "T36 setup: the stub's snapshot file rejects reads" "read succeeded"; else pass "T36 setup: the stub's snapshot file rejects reads"; fi
t36_out=$(PATH="$t36_stub:$PATH" bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes 2>&1); t36_rc=$?
assert_eq "T36 an unreadable snapshot leaves the stamp byte-identical" "$t36_stamp_before" "$(sha_of "$V/.vault-template.json")"
assert_eq "T36 the existing snapshot survives intact" "$t36_keys_before" "$(snap_keys "$V/.vault-template.json")"
if [ "$t36_rc" -ne 0 ]; then pass "T36 exits non-zero rather than stamping"; else fail "T36 exits non-zero rather than stamping" "rc=0, out: $t36_out"; fi
echo
if [ "$FAILED" -eq 0 ]; then echo "All upgrade tests passed."; else echo "$FAILED test(s) failed."; exit 1; fi
