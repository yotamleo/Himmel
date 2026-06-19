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

command -v node >/dev/null 2>&1 || { echo "SKIP all — node not on PATH"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP all — python3 not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP all — git not on PATH"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sha_of() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo MISSING; fi; }

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
merged=$(python3 -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json")
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
got_ver=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$V/.vault-template.json" 2>/dev/null)
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
before=$(find "$V" -type f -exec sha256sum {} \; | sort)
run_upgrade --dry-run >/dev/null 2>&1; rc=$?
after=$(find "$V" -type f -exec sha256sum {} \; | sort)
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
got_ver=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$V/.vault-template.json" 2>/dev/null)
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
before=$(find "$V" -type f -exec sha256sum {} \; | sort)
out=$(run_upgrade --yes 2>&1); rc=$?
after=$(find "$V" -type f -exec sha256sum {} \; | sort)
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
got_ver=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$V/.vault-template.json" 2>/dev/null)
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
# T11: ACCEPTANCE — run against a COPY of the real luna vault, never the live one.
LUNA="$HOME/Documents/luna"
if [ -d "$LUNA" ] && [ -d "$LUNA/50-Journal" ]; then
    VC="$TMP/luna-copy"
    cp -r "$LUNA" "$VC" 2>/dev/null
    # Remove any nested .git to keep the copy a plain dir (avoid worktree confusion).
    rm -rf "$VC/.git"
    REALTMPL="$(cd "$HERE/.." && pwd)"   # this template's own root (scripts/..)
    journal_before=$(find "$VC/50-Journal" -type f -exec sha256sum {} \; 2>/dev/null | sort)
    claude_before=$(sha_of "$VC/_CLAUDE.md")
    bash "$UPGRADE" --template-dir "$REALTMPL" --vault-dir "$VC" --yes >/dev/null 2>&1; rc=$?
    journal_after=$(find "$VC/50-Journal" -type f -exec sha256sum {} \; 2>/dev/null | sort)
    assert_eq "T11 acceptance rc" "0" "$rc"
    assert_eq "T11 journal bodies unchanged" "$journal_before" "$journal_after"
    assert_eq "T11 _CLAUDE.md user content unchanged (no base => ours wins)" "$claude_before" "$(sha_of "$VC/_CLAUDE.md")"
    if [ -f "$VC/.vault-template.json" ]; then pass "T11 stamp written on real-vault copy"; else fail "T11 stamp written on real-vault copy" "no stamp"; fi
    assert_eq "T11 template-owned setup.sh updated to template" "$(sha_of "$REALTMPL/scripts/setup.sh")" "$(sha_of "$VC/scripts/setup.sh")"
else
    echo "SKIP T11 acceptance — no real luna vault at $LUNA"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "All upgrade tests passed."; else echo "$FAILED test(s) failed."; exit 1; fi
