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

# Bash 3.2 scans quotes even inside a quoted heredoc nested in $(...). The
# structural fallback covers the command-substitution/heredoc form used here,
# including a newline between the substitution opener and the command.
check_nested_heredoc_quotes() {
    "$PY" - "$1" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
# Group 1 captures the '-' of a <<- opener, or is None (not merely empty)
# for plain <<. Bash strips leading TABS from a <<- terminator line only;
# a plain << terminator must stay at column zero. (?(1)\t*) applies that
# asymmetry: tabs before the terminator are permitted only when group 1
# actually matched '-' (HIMMEL-2956).
pattern = re.compile(r"\$\([^)]*?<<(-)?\s*'([A-Za-z_][A-Za-z_0-9]*)'[^\n]*\n(.*?)^(?(1)\t*)\2[ \t]*$", re.M | re.S)
failed = False
for match in pattern.finditer(text):
    body = match.group(3)
    for quote in ("'", "`"):
        if body.count(quote) % 2:
            line = text.count("\n", 0, match.start()) + 1
            print("%s:%s: unbalanced %r in nested heredoc" % (sys.argv[1], line, quote))
            failed = True
sys.exit(1 if failed else 0)
PY
}

cat > "$TMP/bash32-repro.sh" <<'REPRO'
#!/usr/bin/env bash
M="$(python3 - 2>/dev/null <<'PY'
# this script's own writer
PY
)"
echo "tail (paren)"
REPRO
check_nested_heredoc_quotes "$UPGRADE"; rc=$?
assert_eq "T0 upgrade nested heredocs have balanced quotes" "0" "$rc"
check_nested_heredoc_quotes "$TMP/bash32-repro.sh"; rc=$?
assert_eq "T0 structural RED control rejects reporter repro" "1" "$rc"
"$PY" - "$TMP" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
repro = (root / "bash32-repro.sh").read_text(encoding="utf-8")
(root / "bash32-fixed.sh").write_text(repro.replace("script's", "script"), encoding="utf-8")
(root / "bash32-backtick.sh").write_text(repro.replace("script's", "script`s"), encoding="utf-8")
(root / "bash32-multiline.sh").write_text(repro.replace("$(python3", "$(\npython3"), encoding="utf-8")
# <<- opener with a TAB-indented terminator: bash strips the leading tab,
# so this is a real, unbalanced heredoc (HIMMEL-2956 negative control).
tab_repro = repro.replace("<<'PY'", "<<-'PY'")
tab_repro = tab_repro.replace("\n# this script's own writer\n", "\n\t# this script's own writer\n")
tab_repro = tab_repro.replace("\nPY\n", "\n\tPY\n")
(root / "bash32-tab-repro.sh").write_text(tab_repro, encoding="utf-8")
# Same <<- + tab-terminator shape, but balanced — proves the fix matches
# the tab terminator without spuriously flagging it every time.
(root / "bash32-tab-fixed.sh").write_text(tab_repro.replace("script's", "script"), encoding="utf-8")
# Plain << (no dash) with a TAB-indented "PY" line before the real,
# column-zero terminator: bash never strips tabs for a plain heredoc, so
# that tab-indented line is body text, not a terminator. The checker must
# keep scanning past it to the real terminator and still catch the
# unmatched apostrophe in the body (HIMMEL-2956 positive control).
notab_guard = repro.replace(
    "<<'PY'\n# this script's own writer\n",
    "<<'PY'\n\tPY\n# this script's own writer\n",
)
(root / "bash32-notab-guard.sh").write_text(notab_guard, encoding="utf-8")
PY
check_nested_heredoc_quotes "$TMP/bash32-fixed.sh"; rc=$?
assert_eq "T0 structural control accepts repaired repro" "0" "$rc"
for fixture in backtick multiline; do
    check_nested_heredoc_quotes "$TMP/bash32-$fixture.sh"; rc=$?
    assert_eq "T0 structural RED control rejects $fixture repro" "1" "$rc"
done

# HIMMEL-2956: <<- permits a TAB-indented terminator; plain << does not.
check_nested_heredoc_quotes "$TMP/bash32-tab-repro.sh"; rc=$?
assert_eq "T0 structural RED control rejects tab-indented <<- terminator repro" "1" "$rc"
check_nested_heredoc_quotes "$TMP/bash32-tab-fixed.sh"; rc=$?
assert_eq "T0 structural control accepts balanced <<- tab-terminator repro" "0" "$rc"
check_nested_heredoc_quotes "$TMP/bash32-notab-guard.sh"; rc=$?
assert_eq "T0 structural control still requires column-zero terminator for plain << (tab line is not a terminator)" "1" "$rc"

bash32="${BASH32:-}"
if [ -z "$bash32" ]; then
    for candidate in bash-3.2 bash32 bash3.2 bash /bin/bash; do
        if command -v "$candidate" >/dev/null 2>&1; then
            case "$("$candidate" --version 2>/dev/null)" in
                *'version 3.2.'*) bash32="$candidate"; break ;;
            esac
        fi
    done
fi
if [ -n "$bash32" ]; then
    # The version variables must expand in the candidate interpreter.
    # shellcheck disable=SC2016
    if [ "$("$bash32" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')" = "3.2" ]; then
        "$bash32" -n "$UPGRADE"; rc=$?
        assert_eq "T0 real bash 3.2 parses upgrade" "0" "$rc"
        "$bash32" -n "$TMP/bash32-repro.sh" 2>/dev/null; rc=$?
        assert_eq "T0 real bash 3.2 rejects reporter repro" "2" "$rc"
    else
        fail "T0 bash 3.2 interpreter" "$bash32 is not bash 3.2"
    fi
else
    echo "SKIP T0 real bash 3.2 — not available; structural gate ran"
fi

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
# T11: ACCEPTANCE — upgrade a HERMETIC vault built from this template's own tree.
# It used to copy the operator's live vault ($HOME/Documents/luna), which is
# coupled to live state: any locally edited template-owned file is withheld and
# upgrade.sh exits 1 BY DESIGN (red on the operator's box), while on CI the
# vault is absent so the case self-skipped and the red never showed (HIMMEL-3171).
# The fixture is an older-stamped copy of the real template + journal content, so
# it exercises the real template tree on every host.
REALTMPL="$(cd "$HERE/.." && pwd)"   # this template's own root (scripts/..)
VC="$TMP/luna-fixture"
mkdir -p "$VC"
(cd "$REALTMPL" && tar -cf - .) | (cd "$VC" && tar -xf -)
rm -rf "$VC/.git"
stamp_vault "$VC" "0.0.1"                           # behind the template, no files map
printf '# stale setup\n' > "$VC/scripts/setup.sh"   # a template-owned file the upgrade must refresh
mkdir -p "$VC/50-Journal/Daily" "$VC/.vault-template.base"
printf '# Journal entry\n\nmy private notes\n' > "$VC/50-Journal/Daily/2026-01-01.md"
printf '# Journal entry two\n\nmore private notes\n' > "$VC/50-Journal/Daily/2026-01-02.md"
# Base snapshot = the template's _CLAUDE.md minus its last line (the template
# delta the upgrade merges in); the vault = base with a customised title line.
sed '$d' "$REALTMPL/_CLAUDE.md" > "$VC/.vault-template.base/_CLAUDE.md"
{ printf '# My Own Vault Title\n'; tail -n +2 "$VC/.vault-template.base/_CLAUDE.md"; } > "$VC/_CLAUDE.md"
journal_before=$(find "$VC/50-Journal" -type f -exec "${SHA256[@]}" {} \; 2>/dev/null | sort)
claude_title_before=$(head -n 1 "$VC/_CLAUDE.md")
bash "$UPGRADE" --template-dir "$REALTMPL" --vault-dir "$VC" --yes >/dev/null 2>&1; rc=$?
journal_after=$(find "$VC/50-Journal" -type f -exec "${SHA256[@]}" {} \; 2>/dev/null | sort)
assert_eq "T11 acceptance rc" "0" "$rc"
assert_eq "T11 journal bodies unchanged" "$journal_before" "$journal_after"
# _CLAUDE.md contract (HIMMEL-1750): the vault carries a base snapshot, so a
# legitimate template delta MAY merge in — byte-equality would fail on every
# template _CLAUDE.md change (hit live when the Retrieval Routing section
# shipped). Assert what actually matters: the merge completed without conflict
# markers and the vault's user content (the vault-specific title line) survived.
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
if [ -f "$VC/.vault-template.json" ]; then pass "T11 stamp written on fixture vault"; else fail "T11 stamp written on fixture vault" "no stamp"; fi
assert_eq "T11 template-owned setup.sh updated to template" "$(sha_of "$REALTMPL/scripts/setup.sh")" "$(sha_of "$VC/scripts/setup.sh")"
# T11 control (the branch the live-vault copy used to hit by accident): a
# template-owned file the operator edited AFTER that upgrade is withheld and the
# run exits non-zero. The first upgrade above recorded the content snapshot; a
# newer template that changes the same file then meets the local edit.
T11NEW="$TMP/luna-fixture-newer"
mkdir -p "$T11NEW"
(cd "$REALTMPL" && tar -cf - .) | (cd "$T11NEW" && tar -xf -)
printf '{"metadata":{"version":"999.0.0"}}\n' > "$T11NEW/marketplace/.claude-plugin/marketplace.json"
printf 'gitleaks-incoming-template-change\n' > "$T11NEW/.gitleaks.toml"
printf '# operator local edit\n' > "$VC/.gitleaks.toml"
t11_edit_sha=$(sha_of "$VC/.gitleaks.toml")
t11_out=$(bash "$UPGRADE" --template-dir "$T11NEW" --vault-dir "$VC" --backup-dir "$TMP/t11-backup" --yes 2>&1); t11_rc=$?
if [ "$t11_rc" -ne 0 ]; then pass "T11 control: a locally edited template-owned file exits non-zero"; else fail "T11 control: a locally edited template-owned file exits non-zero" "rc=0, out: $t11_out"; fi
case "$t11_out" in
    *"local edits withheld (not overwritten): "*".gitleaks.toml"*) pass "T11 control: the edited file is named as withheld" ;;
    *) fail "T11 control: the edited file is named as withheld" "got: $t11_out" ;;
esac
assert_eq "T11 control: the edited file is left untouched" "$t11_edit_sha" "$(sha_of "$VC/.gitleaks.toml")"

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

# ---------------------------------------------------------------------------
# T37 (HIMMEL-2918, round-3 pair item 1): a stamp whose `files` value is
# present but unusable (a string, not a dict) must fail CLOSED, not be read
# as an empty map — which would silently revert to the git fallback, exactly
# the scenario T30 exists to close. Same poisoning as T30 (the local edit and
# the stamp advance land in ONE commit, so the git baseline the fallback would
# read already carries the edit and cannot see it as a divergence): if the
# malformed `files` value were misread as "nothing to withhold", the poisoned
# git baseline would let the edit through.
T="$TMP/t37-tmpl"; V="$TMP/t37-vault"
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
t37_snap_before=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("files",{}).get(".gitleaks.toml",""))' "$V/.vault-template.json" 2>/dev/null)
if [ -n "$t37_snap_before" ]; then pass "T37 setup: the vault carries a content snapshot to corrupt"; else fail "T37 setup: the vault carries a content snapshot to corrupt" "empty"; fi
# The POISONING commit: the vault-local edit and the advanced stamp land in
# ONE commit, so the commit the git path resolves as the baseline already
# carries the edit.
printf 'gitleaks-content-v1\nlocal-allowlist-line\n' > "$V/.gitleaks.toml"
git -C "$V" add -A
git -C "$V" commit -q -m "autosync: local allowlist line + stamp 0.9.0"
t37_stamp_commit=$(git -C "$V" log -1 --format=%H -- .vault-template.json)
git -C "$V" show "$t37_stamp_commit:./.gitleaks.toml" > "$TMP/t37-git-baseline" 2>/dev/null
assert_eq "T37 setup: the git baseline is poisoned (it already carries the edit)" "$(sha_of "$V/.gitleaks.toml")" "$(sha_of "$TMP/t37-git-baseline")"
# Corrupt the stamp's `files` value in place: present, but not a dict.
"$PY" - "$V/.vault-template.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["files"] = "not-a-dict"
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh)
PY
# A newer template that changes the same file.
printf '{"metadata":{"version":"1.0.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf 'gitleaks-content-v2\n' > "$T/.gitleaks.toml"
t37_pre_sha=$(sha_of "$V/.gitleaks.toml")
t37_out=$(bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes 2>&1); t37_rc=$?
assert_eq "T37 a malformed files map withholds the write (fails closed)" "$t37_pre_sha" "$(sha_of "$V/.gitleaks.toml")"
case "$t37_out" in
    *"could not determine the upgrade baseline (snapshot unreadable) — withholding .gitleaks.toml as a precaution"*)
        pass "T37 names the unreadable snapshot in the withheld line" ;;
    *) fail "T37 names the unreadable snapshot in the withheld line" "got: $t37_out" ;;
esac
if [ "$t37_rc" -ne 0 ]; then pass "T37 apply exits non-zero (not a clean upgrade)"; else fail "T37 apply exits non-zero (not a clean upgrade)" "rc=0"; fi

# ---------------------------------------------------------------------------
# T37b (HIMMEL-2918): the one LEGITIMATE empty map — a legacy stamp with no
# `files` key at all (predates the snapshot) — must still fall back to the
# git baseline exactly as before this ticket. T37 above proves the failure
# cases now withhold; this proves the fix didn't also break the one case that
# is supposed to fall through.
T="$TMP/t37b-tmpl"; V="$TMP/t37b-vault"
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
t37b_dry=$(bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --dry-run 2>&1)
case "$t37b_dry" in
    *"local edits withheld (not overwritten): .gitleaks.toml"*"[baseline: git]"*)
        pass "T37b a legacy stamp (no files key) still falls back to the git baseline" ;;
    *) fail "T37b a legacy stamp (no files key) still falls back to the git baseline" "got: $t37b_dry" ;;
esac

# ---------------------------------------------------------------------------
# T38 (HIMMEL-2918, round-3 pair item 2): record_snapshot must fail CLOSED on
# an empty digest, not just on the literal "MISSING". A sha256sum failure mid-
# run still leaves `cut` exiting 0 on no input, so sha_of returns "" — the
# row for that file would be appended anyway and silently dropped later by
# the stamp writer's `if tab and rel and sha`, leaving an incomplete map under
# a clean rc.
#
# A stub that fails EVERY sha256sum call against the target file is too
# blunt: sha_of(dst) is also called earlier, by the plan/execute diff check
# and by has_local_edit's snapshot-baseline comparison — breaking those turns
# an empty digest into a false LOCAL-EDIT withhold, which also exits non-zero
# and would make this case pass for the wrong reason (the vacuous-control
# trap HIMMEL-2903 was already caught in once). A normal run calls sha256sum
# on the target file exactly 5 times — the diff check + the snapshot compare,
# once each in the plan pass and again in the execute pass, then record_snapshot's
# own capture last — so the stub only fails the 5th call, passing the first 4
# through to the real sha256sum.
T="$TMP/t38-tmpl"; V="$TMP/t38-vault"
t35_fixture "$T" "$V"
t38_keys_before=$(snap_keys "$V/.vault-template.json")
if [ "${t38_keys_before:-0}" -gt 0 ]; then pass "T38 setup: the vault carries a complete content snapshot"; else fail "T38 setup: the vault carries a complete content snapshot" "keys=$t38_keys_before"; fi
t38_stamp_before=$(sha_of "$V/.vault-template.json")
t38_target="$V/.gitleaks.toml"
t38_stub="$TMP/t38-stub"; mkdir -p "$t38_stub"
t38_real_sha256sum="$(command -v sha256sum)"
t38_count_file="$TMP/t38-count"; : > "$t38_count_file"
# shellcheck disable=SC2016  # the single-quoted lines are the STUB's source, not this shell's
{
    echo '#!/usr/bin/env bash'
    printf 'target=%s\n' "$t38_target"
    printf 'countfile=%s\n' "$t38_count_file"
    echo 'match=0'
    echo 'for a in "$@"; do [ "$a" = "$target" ] && match=1; done'
    echo 'if [ "$match" = 1 ]; then'
    printf '%s\n' '    printf "x\n" >> "$countfile"'
    echo '    n=$(wc -l < "$countfile")'
    echo '    if [ "$n" -ge 5 ]; then echo "sha256sum: simulated read failure" >&2; exit 1; fi'
    echo 'fi'
    printf 'exec "%s" "$@"\n' "$t38_real_sha256sum"
} > "$t38_stub/sha256sum"
chmod +x "$t38_stub/sha256sum"
# Precondition: the stub really does pass a NON-target file through untouched
# (or the case proves nothing).
t38_other=$(PATH="$t38_stub:$PATH" sha256sum "$T/.gitleaks.toml" 2>/dev/null | cut -d' ' -f1)
if [ -n "$t38_other" ]; then pass "T38 setup: the stub passes other files through"; else fail "T38 setup: the stub passes other files through" "empty"; fi
t38_out=$(PATH="$t38_stub:$PATH" bash "$UPGRADE" --template-dir "$T" --vault-dir "$V" --yes 2>&1); t38_rc=$?
t38_calls=$(wc -l < "$t38_count_file")
assert_eq "T38 setup: the target file's sha256sum was called exactly 5 times, and the 5th failed" "5" "$t38_calls"
assert_eq "T38 the pre-existing stamp is left byte-identical" "$t38_stamp_before" "$(sha_of "$V/.vault-template.json")"
assert_eq "T38 the pre-existing snapshot map is untouched" "$t38_keys_before" "$(snap_keys "$V/.vault-template.json")"
if [ "$t38_rc" -ne 0 ]; then pass "T38 exits non-zero rather than stamping an incomplete snapshot"; else fail "T38 exits non-zero rather than stamping an incomplete snapshot" "rc=0, out: $t38_out"; fi
case "$t38_out" in
    *"could not record the content snapshot for .gitleaks.toml"*)
        pass "T38 warns about the unrecordable digest" ;;
    *) fail "T38 warns about the unrecordable digest" "got: $t38_out" ;;
esac

# ---------------------------------------------------------------------------
# T39-T43 (HIMMEL-3066): the optional github-sync plugin. Vendored under
# optional/plugins/github-sync/ (NOT .obsidian/plugins/), installed into the
# vault only when --with-github-sync/LUNA_WITH_GITHUB_SYNC is set OR the
# vault already has it — never on flag-alone, never dropped once present.
add_optional_github_sync() {
    local d="$1"
    mkdir -p "$d/optional/plugins/github-sync"
    printf '{"id":"github-sync","name":"GitHub Sync","version":"1.0.7"}\n' > "$d/optional/plugins/github-sync/manifest.json"
    printf 'GITHUB-SYNC-MAIN-JS-TEMPLATE\n' > "$d/optional/plugins/github-sync/main.js"
    printf '{"remoteURL":"","gitLocation":""}\n' > "$d/optional/plugins/github-sync/data.json"
    printf '.gh-sync {}\n' > "$d/optional/plugins/github-sync/styles.css"
    printf 'MIT License\n\nGITHUB-SYNC-LICENSE-FIXTURE\n' > "$d/optional/plugins/github-sync/LICENSE"
}

# T39: no flag, no env, fresh vault => github-sync NOT installed at all.
T="$TMP/t39-tmpl"; V="$TMP/t39-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
run_upgrade --yes >/dev/null 2>&1
if [ ! -e "$V/.obsidian/plugins/github-sync" ]; then pass "T39 no-flag fresh vault: github-sync directory not created"; else fail "T39 no-flag fresh vault: github-sync directory not created" "exists"; fi
merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json")
case ",$merged," in *,github-sync,*) fail "T39 no-flag fresh vault: community-plugins.json excludes github-sync" "got: $merged" ;; *) pass "T39 no-flag fresh vault: community-plugins.json excludes github-sync" ;; esac

# T40: --with-github-sync on a fresh vault => plugin assets written + id merged in.
T="$TMP/t40-tmpl"; V="$TMP/t40-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
run_upgrade --yes --with-github-sync >/dev/null 2>&1
assert_eq "T40 --with-github-sync writes manifest.json" "$(sha_of "$T/optional/plugins/github-sync/manifest.json")" "$(sha_of "$V/.obsidian/plugins/github-sync/manifest.json")"
assert_eq "T40 --with-github-sync writes main.js" "$(sha_of "$T/optional/plugins/github-sync/main.js")" "$(sha_of "$V/.obsidian/plugins/github-sync/main.js")"
assert_eq "T40 --with-github-sync writes data.json" "$(sha_of "$T/optional/plugins/github-sync/data.json")" "$(sha_of "$V/.obsidian/plugins/github-sync/data.json")"
merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json")
case ",$merged," in *,github-sync,*) pass "T40 --with-github-sync adds github-sync to community-plugins.json" ;; *) fail "T40 --with-github-sync adds github-sync to community-plugins.json" "got: $merged" ;; esac

# T41: env twin LUNA_WITH_GITHUB_SYNC=1 behaves the same as the flag.
T="$TMP/t41-tmpl"; V="$TMP/t41-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
LUNA_WITH_GITHUB_SYNC=1 run_upgrade --yes >/dev/null 2>&1
assert_eq "T41 env twin writes manifest.json" "$(sha_of "$T/optional/plugins/github-sync/manifest.json")" "$(sha_of "$V/.obsidian/plugins/github-sync/manifest.json")"

# T42: a vault that ALREADY has github-sync installed, upgraded with NO flag,
# keeps it — data.json (holds git credentials) stays byte-identical, and a
# differing vendored main.js in the template is NOT clobbered onto it
# (same skipexists discipline every other bundled plugin's assets already get).
T="$TMP/t42-tmpl"; V="$TMP/t42-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V/.obsidian/plugins/github-sync"; stamp_vault "$V" "0.1.0"
printf '{"remoteURL":"git@github.com:example/real-vault.git","gitLocation":"/real/path"}\n' > "$V/.obsidian/plugins/github-sync/data.json"
printf 'REAL-INSTALLED-MAIN-JS-DIFFERENT-FROM-TEMPLATE\n' > "$V/.obsidian/plugins/github-sync/main.js"
printf '{"id":"github-sync","name":"GitHub Sync","version":"1.0.7"}\n' > "$V/.obsidian/plugins/github-sync/manifest.json"
printf '%s\n' '["dataview","calendar","new","github-sync"]' > "$V/.obsidian/community-plugins.json"
t42_data_before=$(sha_of "$V/.obsidian/plugins/github-sync/data.json")
t42_mainjs_before=$(sha_of "$V/.obsidian/plugins/github-sync/main.js")
run_upgrade --yes >/dev/null 2>&1
assert_eq "T42 already-installed, no flag: data.json stays byte-identical" "$t42_data_before" "$(sha_of "$V/.obsidian/plugins/github-sync/data.json")"
assert_eq "T42 already-installed, no flag: main.js stays byte-identical (skipexists)" "$t42_mainjs_before" "$(sha_of "$V/.obsidian/plugins/github-sync/main.js")"
if [ -f "$V/.obsidian/plugins/github-sync/manifest.json" ]; then pass "T42 already-installed, no flag: plugin stays installed"; else fail "T42 already-installed, no flag: plugin stays installed" "manifest.json missing"; fi
merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json")
case ",$merged," in *,github-sync,*) pass "T42 already-installed, no flag: community-plugins.json still lists github-sync" ;; *) fail "T42 already-installed, no flag: community-plugins.json still lists github-sync" "got: $merged" ;; esac

# T43: --dry-run with --with-github-sync on a fresh vault plans the install
# but makes zero filesystem changes.
T="$TMP/t43-tmpl"; V="$TMP/t43-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
out=$(run_upgrade --with-github-sync --dry-run 2>&1)
case "$out" in *"WRITE-NEW    .obsidian/plugins/github-sync/manifest.json"*) pass "T43 dry-run plans github-sync install" ;; *) fail "T43 dry-run plans github-sync install" "got: $out" ;; esac
if [ ! -e "$V/.obsidian/plugins/github-sync" ]; then pass "T43 dry-run makes zero changes"; else fail "T43 dry-run makes zero changes" "directory created"; fi

# T44: a vault with github-sync INSTALLED but DISABLED (manifest.json present,
# id absent from community-plugins.json — how Obsidian disables a plugin
# without uninstalling it) upgraded with NO flag must NOT re-enable it: the
# eligibility check is "present AND enabled", not manifest.json alone.
T="$TMP/t44-tmpl"; V="$TMP/t44-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V/.obsidian/plugins/github-sync"; stamp_vault "$V" "0.1.0"
printf '{"remoteURL":"git@github.com:example/real-vault.git","gitLocation":"/real/path"}\n' > "$V/.obsidian/plugins/github-sync/data.json"
printf '{"id":"github-sync","name":"GitHub Sync","version":"1.0.7"}\n' > "$V/.obsidian/plugins/github-sync/manifest.json"
printf '%s\n' '["dataview","calendar","new"]' > "$V/.obsidian/community-plugins.json"
run_upgrade --yes >/dev/null 2>&1
merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json")
case ",$merged," in *,github-sync,*) fail "T44 disabled + no flag: community-plugins.json stays without github-sync" "got: $merged" ;; *) pass "T44 disabled + no flag: community-plugins.json stays without github-sync" ;; esac

# T45 (critic panel finding, HIMMEL-3066): a fresh --with-github-sync install
# must carry the vendored LICENSE alongside the plugin assets. Every OTHER
# bundled plugin's LICENSE reaches a vault via the initial template checkout;
# github-sync has no such path any more (it moved out of the git-tracked
# .obsidian/ tree so it stops shipping by default) — this copy loop is now
# its only distribution mechanism.
T="$TMP/t45-tmpl"; V="$TMP/t45-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
run_upgrade --yes --with-github-sync >/dev/null 2>&1
assert_eq "T45 --with-github-sync writes LICENSE" "$(sha_of "$T/optional/plugins/github-sync/LICENSE")" "$(sha_of "$V/.obsidian/plugins/github-sync/LICENSE")"

# ---------------------------------------------------------------------------
# T46-T48 (HIMMEL-3094): when the github-sync community-plugins source cannot
# be prepared (mktemp fails, or the merge step fails), the run must WARN and
# keep merging from the template's own list — not repoint CP_MERGE_SRC at a
# missing/empty file and silently skip the whole plugin merge.
t46_realpy=$(command -v "$PY")
t46_realmktemp=$(command -v mktemp)
t46_bin="$TMP/t46-bin"; t47_bin="$TMP/t47-bin"; mkdir -p "$t46_bin" "$t47_bin"
# mktemp stub: fails ONLY for the github-sync scratch file, real mktemp otherwise.
printf '#!/bin/sh\ncase "$*" in *luna-upgrade-gh-sync-cp*) exit 1 ;; esac\nexec "%s" "$@"\n' "$t46_realmktemp" > "$t46_bin/mktemp"
# python3 stub: fails ONLY for the github-sync merge script (read from stdin,
# recognised by its json.dump(tmpl, fh)); `-c` probes and every other script
# pass straight through to the real interpreter.
# shellcheck disable=SC2016  # the stub's own $1/$in/$@ must stay literal
printf '#!/bin/sh\ncase "$1" in -c) exec "%s" "$@" ;; esac\nin="$(cat)"\ncase "$in" in *"json.dump(tmpl, fh)"*) exit 1 ;; esac\nprintf "%%s\\n" "$in" | exec "%s" "$@"\n' "$t46_realpy" "$t46_realpy" > "$t47_bin/python3"
chmod +x "$t46_bin/mktemp" "$t47_bin/python3"
# Preconditions: each stub really does fail where it should, and passes elsewhere.
t46_pre=$(PATH="$t46_bin:$PATH" mktemp "$TMP/luna-upgrade-gh-sync-cp.XXXXXX" >/dev/null 2>&1; echo $?)
assert_eq "T46 setup: mktemp stub fails for the github-sync scratch file" "1" "$t46_pre"
t46_pre=$(PATH="$t46_bin:$PATH" mktemp "$TMP/other.XXXXXX" >/dev/null 2>&1; echo $?)
assert_eq "T46 setup: mktemp stub passes through for other files" "0" "$t46_pre"
t46_pre=$(printf 'json.dump(tmpl, fh)\n' | PATH="$t47_bin:$PATH" python3 - >/dev/null 2>&1; echo $?)
assert_eq "T46 setup: python3 stub fails for the github-sync merge script" "1" "$t46_pre"
t46_pre=$(printf 'print(7)\n' | PATH="$t47_bin:$PATH" python3 - 2>/dev/null)
assert_eq "T46 setup: python3 stub passes through other scripts" "7" "$t46_pre"

t46_check() {   # $1 label prefix, $2 output of the run; asserts on $V
    local merged
    case "$2" in
        *"WARNING — could not prepare the github-sync plugin enablement"*) pass "$1 warns that github-sync enablement could not be prepared" ;;
        *) fail "$1 warns that github-sync enablement could not be prepared" "got: $2" ;;
    esac
    merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json" 2>/dev/null)
    assert_eq "$1 still merges the template's own plugin list" "calendar,dataview,new" "$merged"
}

# T46: the scratch file cannot be created.
T="$TMP/t46-tmpl"; V="$TMP/t46-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
t46_out=$(PATH="$t46_bin:$PATH" run_upgrade --yes --with-github-sync 2>&1)
t46_check "T46 mktemp fails:" "$t46_out"

# T47: the scratch file exists but the merge step fails.
T="$TMP/t47-tmpl"; V="$TMP/t47-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
t47_out=$(PATH="$t47_bin:$PATH" run_upgrade --yes --with-github-sync 2>&1)
t46_check "T47 merge step fails:" "$t47_out"

# T48 (control): the normal path is unchanged — no warning, and the prepared
# temp file carries github-sync into community-plugins.json.
T="$TMP/t48-tmpl"; V="$TMP/t48-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
t48_out=$(run_upgrade --yes --with-github-sync 2>&1)
case "$t48_out" in
    *"could not prepare the github-sync plugin enablement"*) fail "T48 normal path: no github-sync warning" "got: $t48_out" ;;
    *) pass "T48 normal path: no github-sync warning" ;;
esac
merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json")
assert_eq "T48 normal path: community-plugins.json includes github-sync" "calendar,dataview,github-sync,new" "$merged"

# T49: a template community-plugins.json that is not a JSON array must not be
# laundered into a list by the github-sync preparation (list({"a":1}) == ["a"]);
# it warns and keeps the template source, so github-sync is not injected.
T="$TMP/t49-tmpl"; V="$TMP/t49-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
printf '%s\n' '{"calendar":true}' > "$T/.obsidian/community-plugins.json"
t49_out=$(run_upgrade --yes --with-github-sync 2>&1)
case "$t49_out" in
    *"WARNING — could not prepare the github-sync plugin enablement"*) pass "T49 non-array template: warns that github-sync enablement could not be prepared" ;;
    *) fail "T49 non-array template: warns that github-sync enablement could not be prepared" "got: $t49_out" ;;
esac
case "$(cat "$V/.obsidian/community-plugins.json" 2>/dev/null)" in
    *github-sync*) fail "T49 non-array template: github-sync is not injected" "got: $(cat "$V/.obsidian/community-plugins.json")" ;;
    *) pass "T49 non-array template: github-sync is not injected" ;;
esac

# T50-T52 (HIMMEL-3189): the add-only plugin merge must validate ITS OWN source.
# A non-array template community-plugins.json ({"calendar":true}) used to be
# iterated as its KEYS and written into the vault as ["calendar"], with the run
# exiting 0. Now the merge warns and leaves the vault's file untouched; the run
# still exits 0 (like the vault-side non-array guard: one bad plugin list must
# not block the rest of the upgrade — the warning is the signal).
# T50: the vault already has a plugin list — it must stay byte-identical.
T="$TMP/t50-tmpl"; V="$TMP/t50-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.obsidian"; stamp_vault "$V" "0.1.0"
printf '%s\n' '["dataview"]' > "$V/.obsidian/community-plugins.json"
printf '%s\n' '{"calendar":true}' > "$T/.obsidian/community-plugins.json"
t50_pre_sha=$(sha_of "$V/.obsidian/community-plugins.json")
t50_out=$(run_upgrade --yes 2>&1); t50_rc=$?
assert_eq "T50 non-array template: vault plugin list untouched" "$t50_pre_sha" "$(sha_of "$V/.obsidian/community-plugins.json")"
assert_eq "T50 non-array template: run still exits 0 (warn-and-continue)" "0" "$t50_rc"
case "$t50_out" in
    *"template plugin list "*"is not a JSON array; leaving the vault's list untouched"*) pass "T50 non-array template: warns that the template plugin list is not an array" ;;
    *) fail "T50 non-array template: warns that the template plugin list is not an array" "got: $t50_out" ;;
esac
# T51: the vault has NO plugin list yet — none must be created from the bad source.
T="$TMP/t51-tmpl"; V="$TMP/t51-vault"; make_template "$T" "1.0.0"; add_optional_github_sync "$T"; mkdir -p "$V"; stamp_vault "$V" "0.1.0"
printf '%s\n' '{"calendar":true}' > "$T/.obsidian/community-plugins.json"
run_upgrade --yes --with-github-sync >/dev/null 2>&1
if [ -e "$V/.obsidian/community-plugins.json" ]; then
    fail "T51 non-array template: no plugin list is created in a vault that lacks one" "got: $(cat "$V/.obsidian/community-plugins.json")"
else
    pass "T51 non-array template: no plugin list is created in a vault that lacks one"
fi
# T52 (control): a normal list template still merges add-only into the vault's list.
T="$TMP/t52-tmpl"; V="$TMP/t52-vault"; make_template "$T" "1.0.0"; mkdir -p "$V/.obsidian"; stamp_vault "$V" "0.1.0"
printf '%s\n' '["dataview"]' > "$V/.obsidian/community-plugins.json"
run_upgrade --yes >/dev/null 2>&1
merged=$("$PY" -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$V/.obsidian/community-plugins.json" 2>/dev/null)
assert_eq "T52 list template: still merges add-only" "calendar,dataview,new" "$merged"

# ---------------------------------------------------------------------------
# T53-T58 (HIMMEL-3037): Obsidian rewrites its own .obsidian/*.json on every
# settings touch — without the template's trailing newline, and re-indented —
# so a template-owned file with NO semantic difference read as a local edit on
# every upgrade after the first launch, and the stamp was refused for good.
# Template-vs-vault comparison now ignores a trailing-newline-only difference
# and (jq present) normalises JSON. First-run helper: upgrade a stamped vault
# so it carries the stamp's content snapshot, then bump the template.
t53_seed() {   # $1 case tag; leaves $T/$V set, vault upgraded once, template bumped
    T="$TMP/$1-tmpl"; V="$TMP/$1-vault"
    make_template "$T" "1.0.0"
    printf '{"promptDelete":false,"alwaysUpdateLinks":true}\n' > "$T/.obsidian/app.json"
    mkdir -p "$V"; stamp_vault "$V" "0.1.0"
    run_upgrade --yes >/dev/null 2>&1
    printf '{"metadata":{"version":"1.0.1"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
}
t53_stamp_version() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$V/.vault-template.json" 2>/dev/null; }

# T53: the reported case — the vault's app.json is the template minus its final
# newline. No LOCAL-EDIT, the run succeeds, the stamp advances.
t53_seed t53
printf '{"promptDelete":false,"alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
t53_out=$(run_upgrade --yes 2>&1); t53_rc=$?
assert_eq "T53 trailing-newline-only .obsidian/app.json: run exits 0" "0" "$t53_rc"
case "$t53_out" in
    *LOCAL-EDIT*|*"local edits withheld"*) fail "T53 trailing-newline-only .obsidian/app.json is not a local edit" "got: $t53_out" ;;
    *) pass "T53 trailing-newline-only .obsidian/app.json is not a local edit" ;;
esac
assert_eq "T53 stamp advances to the template version" "1.0.1" "$(t53_stamp_version)"
if [ "$(cat "$V/.obsidian/app.json")" = '{"promptDelete":false,"alwaysUpdateLinks":true}' ]; then
    pass "T53 the vault's Obsidian-written file is left as Obsidian wrote it"
else
    fail "T53 the vault's Obsidian-written file is left as Obsidian wrote it" "got: $(cat "$V/.obsidian/app.json")"
fi

# T54: a REAL difference must still be withheld (the equivalence must not be
# broader than newline/JSON formatting) — and the stamp must still be refused.
t53_seed t54
printf '{"promptDelete":true,"alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
t54_out=$(run_upgrade --yes 2>&1); t54_rc=$?
if [ "$t54_rc" -ne 0 ]; then pass "T54 a real value change in app.json still exits non-zero"; else fail "T54 a real value change in app.json still exits non-zero" "rc=0, out: $t54_out"; fi
case "$t54_out" in
    *"local edits withheld (not overwritten): .obsidian/app.json"*) pass "T54 a real value change in app.json is still withheld" ;;
    *) fail "T54 a real value change in app.json is still withheld" "got: $t54_out" ;;
esac
assert_eq "T54 stamp NOT advanced (still the first upgrade's)" "1.0.0" "$(t53_stamp_version)"

# T55: a difference of MORE than one trailing newline is not a
# trailing-newline-only difference (non-JSON file: pure byte rule).
t53_seed t55
printf 'DEFAULT_X=1\n\n\n' > "$V/.env.example"
t55_dry=$(run_upgrade --dry-run 2>&1)
case "$t55_dry" in
    *"LOCAL-EDIT"*".env.example"*|*"WRITE"*".env.example"*) pass "T55 extra blank lines at EOF are still a difference (not ignored)" ;;
    *) fail "T55 extra blank lines at EOF are still a difference (not ignored)" "got: $t55_dry" ;;
esac

# T56: with jq, re-indented / re-keyed JSON with the same content is no local edit.
if jq -n . >/dev/null 2>&1; then
    t53_seed t56
    printf '{\n\t"alwaysUpdateLinks": true,\n\t"promptDelete": false\n}' > "$V/.obsidian/app.json"
    t56_out=$(run_upgrade --yes 2>&1); t56_rc=$?
    assert_eq "T56 re-indented/re-ordered .obsidian/app.json (same JSON): run exits 0" "0" "$t56_rc"
    case "$t56_out" in
        *LOCAL-EDIT*|*"local edits withheld"*) fail "T56 same-JSON app.json is not a local edit" "got: $t56_out" ;;
        *) pass "T56 same-JSON app.json is not a local edit" ;;
    esac
    assert_eq "T56 stamp advances" "1.0.1" "$(t53_stamp_version)"
else
    echo "SKIP T56 — no working jq on PATH"
fi

# T57: no working jq => the newline rule still applies, a JSON-formatting-only
# difference is (conservatively) a local edit, and the run says why. A jq stub
# that exits non-zero stands in for a missing/broken jq.
t57_bin="$TMP/t57-bin"; mkdir -p "$t57_bin"
printf '#!/bin/sh\nexit 127\n' > "$t57_bin/jq"; chmod +x "$t57_bin/jq"
t53_seed t57
printf '{"promptDelete":false,"alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
t57_out=$(PATH="$t57_bin:$PATH" run_upgrade --yes 2>&1); t57_rc=$?
if [ "$t57_rc" -eq 0 ]; then pass "T57 no jq: the trailing-newline-only case still exits 0"; else fail "T57 no jq: the trailing-newline-only case still exits 0" "rc=$t57_rc, out: $t57_out"; fi
t53_seed t57b
printf '{\n"promptDelete": false,\n"alwaysUpdateLinks": true\n}' > "$V/.obsidian/app.json"
t57b_out=$(PATH="$t57_bin:$PATH" run_upgrade --yes 2>&1); t57b_rc=$?
if [ "$t57b_rc" -ne 0 ]; then pass "T57 no jq: JSON-formatting-only difference falls back to the byte rule (withheld)"; else fail "T57 no jq: JSON-formatting-only difference falls back to the byte rule (withheld)" "rc=0, out: $t57b_out"; fi
case "$t57b_out" in
    *"jq"*"trailing-newline"*) pass "T57 no jq: the run notes the reduced comparison" ;;
    *) fail "T57 no jq: the run notes the reduced comparison" "got: $t57b_out" ;;
esac

# T58: the git baseline path (a vault stamped before the snapshot existed) uses
# the same equivalence: the vault only lost the newline of a file the TEMPLATE
# has since really changed => not a local edit, the template copy is taken.
T="$TMP/t58-tmpl"; V="$TMP/t58-vault"
make_template "$T" "0.9.0"
printf '{"promptDelete":false}\n' > "$T/.obsidian/app.json"
mkdir -p "$V"; cp -r "$T/." "$V/"; rm -f "$V/marketplace/.claude-plugin/marketplace.json"
stamp_vault "$V" "0.9.0"
git -C "$V" init -q
git -C "$V" config user.email "test@example.com"
git -C "$V" config user.name "Test"
git -C "$V" add -A
git -C "$V" commit -q -m "stamp 0.9.0"
printf '{"promptDelete":false}' > "$V/.obsidian/app.json"
git -C "$V" add -A
git -C "$V" commit -q -m "Obsidian rewrote app.json without the final newline"
printf '{"metadata":{"version":"1.0.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf '{"promptDelete":true}\n' > "$T/.obsidian/app.json"
t58_out=$(run_upgrade --yes 2>&1); t58_rc=$?
if [ "$t58_rc" -eq 0 ]; then pass "T58 git baseline: newline-only vault drift + a real template change exits 0"; else fail "T58 git baseline: newline-only vault drift + a real template change exits 0" "rc=$t58_rc, out: $t58_out"; fi
assert_eq "T58 git baseline: the template's new app.json was written" "$(sha_of "$T/.obsidian/app.json")" "$(sha_of "$V/.obsidian/app.json")"

# T62 (HIMMEL-3037, CodeRabbit round on #888): the SNAPSHOT baseline is a hash,
# so a vault that a prior upgrade snapshotted, Obsidian then re-serialised, and
# the template then REALLY changed read as a local edit before the formatting-
# tolerant git compare was ever reached. On a snapshot mismatch the git baseline
# now answers too — but only a VERIFIED one: the content at STAMP_COMMIT must
# hash to the snapshot (else a local edit committed in the stamp commit itself
# would be trusted, the HIMMEL-2903 poison).
t62_seed() {   # $1 case tag; git vault upgraded once + committed; template then changes app.json
    T="$TMP/$1-tmpl"; V="$TMP/$1-vault"
    make_template "$T" "1.0.0"
    printf '{"promptDelete":false,"alwaysUpdateLinks":true}\n' > "$T/.obsidian/app.json"
    mkdir -p "$V"; stamp_vault "$V" "0.1.0"
    git -C "$V" init -q
    git -C "$V" config user.email "test@example.com"
    git -C "$V" config user.name "Test"
    git -C "$V" add -A
    git -C "$V" commit -q --no-verify -m "seed"
    run_upgrade --yes >/dev/null 2>&1
    git -C "$V" add -A
    git -C "$V" commit -q --no-verify -m "upgrade 1.0.0"
    printf '{"metadata":{"version":"1.0.1"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
    printf '{"promptDelete":true,"alwaysUpdateLinks":true}\n' > "$T/.obsidian/app.json"
}
t62_expect_taken() {   # $1 label; vault must have taken the template's app.json and stamped 1.0.1
    assert_eq "$1: run exits 0" "0" "$t62_rc"
    assert_eq "$1: the template's new app.json was written" "$(sha_of "$T/.obsidian/app.json")" "$(sha_of "$V/.obsidian/app.json")"
    assert_eq "$1: stamp advances" "1.0.1" "$(t53_stamp_version)"
}
t62_expect_withheld() {   # $1 label
    assert_eq "$1: run exits 3 (NEEDS-RECONCILE)" "3" "$t62_rc"
    case "$t62_out" in
        *"local edits withheld (not overwritten): .obsidian/app.json"*) pass "$1: app.json is withheld as a local edit" ;;
        *) fail "$1: app.json is withheld as a local edit" "got: $t62_out" ;;
    esac
    assert_eq "$1: stamp NOT advanced" "1.0.0" "$(t53_stamp_version)"
}

# T62a: newline-only Obsidian rewrite of an already-snapshotted, stamp-committed
# file + a later real template change => not a local edit, template taken.
t62_seed t62a
printf '{"promptDelete":false,"alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
t62_out=$(run_upgrade --yes 2>&1); t62_rc=$?
t62_expect_taken "T62a newline-only rewrite + later template change"
# T62b: same with re-indented / re-keyed JSON (needs jq).
if jq -n . >/dev/null 2>&1; then
    t62_seed t62b
    printf '{\n\t"alwaysUpdateLinks": true,\n\t"promptDelete": false\n}' > "$V/.obsidian/app.json"
    t62_out=$(run_upgrade --yes 2>&1); t62_rc=$?
    t62_expect_taken "T62b re-indented rewrite + later template change"
else
    echo "SKIP T62b — no working jq on PATH"
fi
# T62c control: a REAL local edit on top of the snapshot is still withheld.
t62_seed t62c
printf '{"promptDelete":"edited-by-hand","alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
t62_out=$(run_upgrade --yes 2>&1); t62_rc=$?
t62_expect_withheld "T62c real local edit over a snapshot"
# T62d control: snapshot-only vault (no git baseline at all) stays fail-closed.
t53_seed t62d
printf '{"promptDelete":false,"alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
printf '{"promptDelete":true,"alwaysUpdateLinks":true}\n' > "$T/.obsidian/app.json"
t62_out=$(run_upgrade --yes 2>&1); t62_rc=$?
t62_expect_withheld "T62d snapshot-only vault, no git baseline"
# T62e control: a local edit COMMITTED IN the stamp commit itself (the 2903
# poison) — the git baseline no longer hashes to the snapshot, so it is not
# trusted and the file stays withheld.
t62_seed t62e
printf '{"promptDelete":"poisoned","alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
git -C "$V" add -A
git -C "$V" commit -q --no-verify -m "autosync: edit + stamp in one commit"
printf '{"template":"luna-second-brain","version":"1.0.0","upgraded_at":"2026-01-02T00:00:00Z","files":%s}\n' "$("$PY" -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("files",{})))' "$V/.vault-template.json")" > "$V/.vault-template.json"
git -C "$V" add -A
git -C "$V" commit -q --no-verify -m "stamp re-touched"
t62_out=$(run_upgrade --yes 2>&1); t62_rc=$?
t62_expect_withheld "T62e local edit committed alongside the stamp"

# ---------------------------------------------------------------------------
# T59-T60 (HIMMEL-3037): a run whose ONLY non-success is withheld local edits
# (no write failure, no snapshot failure, no _CLAUDE.md conflict) is not a
# failure — it exits a distinct rc 3 and prints a stable NEEDS-RECONCILE line
# (stdout, last line), while the stamp is still NOT written so the vault keeps
# being offered the upgrade. Anything else stays rc 1.
# T59: local edit only.
t53_seed t59
printf '{"promptDelete":true,"alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
t59_pre_sha=$(sha_of "$V/.obsidian/app.json")
t59_out=$(run_upgrade --yes 2>/dev/null); t59_rc=$?
assert_eq "T59 withheld-local-edits-only run exits 3" "3" "$t59_rc"
case "$t59_out" in
    *"upgrade: NEEDS-RECONCILE — 1 local edit(s) withheld, version stamp NOT written"*) pass "T59 stdout carries the stable NEEDS-RECONCILE line" ;;
    *) fail "T59 stdout carries the stable NEEDS-RECONCILE line" "got: $t59_out" ;;
esac
t59_last=$(printf '%s\n' "$t59_out" | tail -n 1)
case "$t59_last" in
    "upgrade: NEEDS-RECONCILE"*) pass "T59 the NEEDS-RECONCILE line is the LAST stdout line (callers show it as the detail)" ;;
    *) fail "T59 the NEEDS-RECONCILE line is the LAST stdout line (callers show it as the detail)" "last: $t59_last" ;;
esac
assert_eq "T59 the withheld file is untouched" "$t59_pre_sha" "$(sha_of "$V/.obsidian/app.json")"
assert_eq "T59 stamp NOT advanced" "1.0.0" "$(t53_stamp_version)"
t59_check=$(run_upgrade --check 2>&1)
case "$t59_check" in
    *"template v1.0.1 available (vault is v1.0.0)"*) pass "T59 --check afterwards still reports the template update as available" ;;
    *) fail "T59 --check afterwards still reports the template update as available" "got: $t59_check" ;;
esac
# T60: a real failure alongside the withheld edit stays rc 1, and is NOT
# relabelled NEEDS-RECONCILE (a _CLAUDE.md conflict needs a human first).
t53_seed t60
printf '{"promptDelete":true,"alwaysUpdateLinks":true}' > "$V/.obsidian/app.json"
mkdir -p "$V/.vault-template.base"; cp "$T/_CLAUDE.md" "$V/.vault-template.base/_CLAUDE.md"
printf '# Operating Manual OURS\n\nline-a\nline-b\nline-c\n' > "$V/_CLAUDE.md"
printf '# Operating Manual THEIRS\n\nline-a\nline-b\nline-c\n' > "$T/_CLAUDE.md"
t60_out=$(run_upgrade --yes 2>&1); t60_rc=$?
assert_eq "T60 local edit + _CLAUDE.md conflict stays rc 1" "1" "$t60_rc"
case "$t60_out" in
    *NEEDS-RECONCILE*) fail "T60 a mixed failure is not labelled NEEDS-RECONCILE" "got: $t60_out" ;;
    *) pass "T60 a mixed failure is not labelled NEEDS-RECONCILE" ;;
esac
# T61: a report-class file that really differs still prints its plan row in
# the same 13-column layout as the other actions (the content_equiv rewrite of
# that branch must not shift the column).
t53_seed t61
mkdir -p "$T/_Templates" "$V/_Templates"
printf 'template body\n' > "$T/_Templates/daily.md"
printf 'vault body\n' > "$V/_Templates/daily.md"
t61_out=$(run_upgrade --dry-run 2>&1)
case "$t61_out" in
    *"REPORT       _Templates/daily.md (template changed"*) pass "T61 REPORT plan row keeps its column alignment" ;;
    *) fail "T61 REPORT plan row keeps its column alignment" "got: $t61_out" ;;
esac

# ---------------------------------------------------------------------------
# T63 (HIMMEL-3206): a vault owner lands by hand the SAME fix the template later
# ships (the HIMMEL-3003 case) — .gitleaks.toml / .gitignore then differ from
# the template only in comments, ordering and spacing. That is CONVERGED, not a
# local edit: the template copy is taken and the stamp advances. Anything not
# PROVABLY the same stays withheld (rc 3): .gitleaks.toml is the secret
# scanner's own config, and .gitignore order is semantic once a `!` exists.
t63_gl1() { cat > "$1" <<'EOF'
title = "vault gitleaks"

[extend]
useDefault = true

[allowlist]
description = "shipped allowlist"
regexes = ['''sk-test-[0-9]+''']
EOF
}
t63_gl2() { cat > "$1" <<'EOF'
# shipped by the template
title = "vault gitleaks"

[extend]
useDefault = true

[[rules]]
id = "rule-a"
regex = '''AAA[0-9]+'''

[[rules]]
id = "rule-b"
regex = '''BBB[0-9]+'''

[allowlist]
description = "shipped allowlist"
regexes = ['''sk-test-[0-9]+''', '''ghp_EXAMPLE''']
paths = ['''graphify-out/.*''']
stopwords = ["example"]
EOF
}
# The vault owner's hand-landed copy of gl2: rules + array entries reordered,
# different comments and blank lines, otherwise the same structure.
t63_gl2_hand() { cat > "$1" <<'EOF'
title = "vault gitleaks"
[extend]
useDefault = true   # keep the shipped rules

# hand-landed: the HIMMEL-3003 fix
[[rules]]
id = "rule-b"
regex = '''BBB[0-9]+'''
[[rules]]
id = "rule-a"
regex = '''AAA[0-9]+'''

[allowlist]
description = "shipped allowlist"
stopwords = ["example"]
paths = ['''graphify-out/.*''']
regexes = ['''ghp_EXAMPLE''', '''sk-test-[0-9]+''']
EOF
}
t63_gi1() { printf '.env\n.env.*\n' > "$1"; }
t63_gi2() { printf '.env\n.env.*\n# graphify output\ngraphify-out/\n*.cache\n' > "$1"; }
t63_gi2_hand() { printf '# my own block\n*.cache\n\ngraphify-out/   \n.env.*\n.env\n' > "$1"; }
t63_seed() {   # $1 case tag; vault upgraded once with the v1 files, then template -> 1.0.1 with the v2 files
    T="$TMP/$1-tmpl"; V="$TMP/$1-vault"
    make_template "$T" "1.0.0"
    t63_gl1 "$T/.gitleaks.toml"; t63_gi1 "$T/.gitignore"
    mkdir -p "$V"; stamp_vault "$V" "0.1.0"
    run_upgrade --yes >/dev/null 2>&1
    printf '{"metadata":{"version":"1.0.1"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
    t63_gl2 "$T/.gitleaks.toml"; t63_gi2 "$T/.gitignore"
}
t63_expect_taken() {   # $1 label $2 file(s)...: vault holds the template's copy, run exits 0, stamp advances
    local lbl="$1" f; shift
    assert_eq "$lbl: run exits 0" "0" "$t63_rc"
    for f in "$@"; do assert_eq "$lbl: $f is the template copy" "$(sha_of "$T/$f")" "$(sha_of "$V/$f")"; done
    assert_eq "$lbl: stamp advances" "1.0.1" "$(t53_stamp_version)"
    case "$t63_out" in
        *"local edits withheld"*) fail "$lbl: nothing is withheld" "got: $t63_out" ;;
        *) pass "$lbl: nothing is withheld" ;;
    esac
}
t63_expect_withheld() {   # $1 label $2 file: vault copy untouched (sha $3), rc 3, stamp not advanced
    assert_eq "$1: run exits 3 (NEEDS-RECONCILE)" "3" "$t63_rc"
    case "$t63_out" in
        *"local edits withheld (not overwritten): $2"*) pass "$1: $2 is withheld as a local edit" ;;
        *) fail "$1: $2 is withheld as a local edit" "got: $t63_out" ;;
    esac
    assert_eq "$1: the vault copy is untouched" "$3" "$(sha_of "$V/$2")"
    assert_eq "$1: stamp NOT advanced" "1.0.0" "$(t53_stamp_version)"
}

# T63a: the ticket's two observed cases together — comment/order-only drift in
# BOTH files converges: template copies written, no rc 3, stamp advances.
t63_seed t63a
t63_gl2_hand "$V/.gitleaks.toml"; t63_gi2_hand "$V/.gitignore"
t63_out=$(run_upgrade --yes 2>&1); t63_rc=$?
t63_expect_taken "T63a converged .gitleaks.toml + .gitignore" .gitleaks.toml .gitignore
# T63b: the dry-run plan names the row as converged, not as a LOCAL-EDIT.
t63_seed t63b
t63_gl2_hand "$V/.gitleaks.toml"; t63_gi2_hand "$V/.gitignore"
t63_out=$(run_upgrade --dry-run 2>&1)
case "$t63_out" in
    *"WRITE        .gitleaks.toml (converged"*"WRITE        .gitignore (converged"*|*"WRITE        .gitignore (converged"*"WRITE        .gitleaks.toml (converged"*) pass "T63b plan rows say converged" ;;
    *) fail "T63b plan rows say converged" "got: $t63_out" ;;
esac
case "$t63_out" in
    *LOCAL-EDIT*) fail "T63b no LOCAL-EDIT row" "got: $t63_out" ;;
    *) pass "T63b no LOCAL-EDIT row" ;;
esac

# --- controls: each stays withheld (over-forgiveness) before AND after ---
t63_control_gl() {   # $1 tag, $2 sed expression applied to the hand-landed copy
    t63_seed "$1"
    t63_gl2_hand "$V/.gitleaks.toml"
    sed -i.bak "$2" "$V/.gitleaks.toml" && rm -f "$V/.gitleaks.toml.bak"
    t63_pre=$(sha_of "$V/.gitleaks.toml")
    t63_out=$(run_upgrade --yes 2>&1); t63_rc=$?
}
# T63c: an EXTRA allowlist regex (wider allowlist) is not converged.
t63_control_gl t63c "s#^regexes = .*#regexes = ['''ghp_EXAMPLE''', '''sk-test-[0-9]+''', '''extra''']#"
t63_expect_withheld "T63c extra allowlist regex" .gitleaks.toml "$t63_pre"
# T63d: one allowlist regex MISSING (narrower allowlist) is not converged.
t63_control_gl t63d "s#^regexes = .*#regexes = ['''sk-test-[0-9]+''']#"
t63_expect_withheld "T63d dropped allowlist regex" .gitleaks.toml "$t63_pre"
# T63e: a changed RULE regex is not converged.
t63_control_gl t63e "s#AAA\\[0-9\\]+#AAA[0-9]*#"
t63_expect_withheld "T63e changed rule regex" .gitleaks.toml "$t63_pre"
# T63f: same regexes but one MORE stopword — every key counts, not just regexes.
t63_control_gl t63f 's#^stopwords = .*#stopwords = ["example", "more"]#'
t63_expect_withheld "T63f extra stopword" .gitleaks.toml "$t63_pre"
# T63g: same regexes but one MORE path entry.
t63_control_gl t63g "s#^paths = .*#paths = ['''graphify-out/.*''', '''extra-dir/.*''']#"
t63_expect_withheld "T63g extra path" .gitleaks.toml "$t63_pre"
# T63h: a TOML parse error on the vault side is not converged (fail closed).
t63_control_gl t63h 's#^title = .*#title = #'
t63_expect_withheld "T63h TOML parse error" .gitleaks.toml "$t63_pre"
# T63i: no tomllib (python < 3.11) => withheld, one stderr note. Simulated with
# a python3 shim that fails only the `import tomllib` probe.
t63_seed t63i
t63_gl2_hand "$V/.gitleaks.toml"
t63_pre=$(sha_of "$V/.gitleaks.toml")
t63_shim="$TMP/t63i-shim"; mkdir -p "$t63_shim"
t63_real_py="$(command -v python3 || command -v python)"
printf '#!/bin/sh\ncase "$*" in *tomllib*) exit 1 ;; esac\nexec "%s" "$@"\n' "$t63_real_py" > "$t63_shim/python3"
chmod +x "$t63_shim/python3"
t63_out=$(PATH="$t63_shim:$PATH" run_upgrade --yes 2>&1); t63_rc=$?
t63_expect_withheld "T63i no tomllib" .gitleaks.toml "$t63_pre"
case "$t63_out" in
    *"tomllib"*) pass "T63i the missing parser is named in a note" ;;
    *) fail "T63i the missing parser is named in a note" "got: $t63_out" ;;
esac
# T63j: .gitignore with a NEGATION — reordered lines are semantic, withheld.
t63_seed t63j
printf '.env\n*.cache\n!keep.cache\ngraphify-out/\n' > "$T/.gitignore"
printf '.env\ngraphify-out/\n!keep.cache\n*.cache\n' > "$V/.gitignore"
t63_pre=$(sha_of "$V/.gitignore")
t63_out=$(run_upgrade --yes 2>&1); t63_rc=$?
t63_expect_withheld "T63j reordered .gitignore with a ! line" .gitignore "$t63_pre"
# T63k: .gitignore with one EXTRA pattern is not converged.
t63_seed t63k
t63_gi2_hand "$V/.gitignore"; printf 'secret.txt\n' >> "$V/.gitignore"
t63_pre=$(sha_of "$V/.gitignore")
t63_out=$(run_upgrade --yes 2>&1); t63_rc=$?
t63_expect_withheld "T63k extra .gitignore pattern" .gitignore "$t63_pre"
# T63l: leading whitespace is part of a gitignore pattern (" graphify-out/" does
# not match graphify-out/) — not converged.
t63_seed t63l
t63_gi2_hand "$V/.gitignore"; sed -i.bak 's#^graphify-out/ *$# graphify-out/#' "$V/.gitignore" && rm -f "$V/.gitignore.bak"
t63_pre=$(sha_of "$V/.gitignore")
t63_out=$(run_upgrade --yes 2>&1); t63_rc=$?
t63_expect_withheld "T63l leading-space pattern" .gitignore "$t63_pre"

# ---------------------------------------------------------------------------
# T64 (HIMMEL-3406): a file that differs from the template ONLY in line
# ending (CRLF vs LF — an operator's editor, or a Windows checkout, re-saving
# a template-owned file with no content change) reads as identical, not as a
# local edit: no WRITE, no LOCAL-EDIT, the run completes and the stamp
# advances.
T="$TMP/t64-tmpl"; V="$TMP/t64-vault"
make_template "$T" "1.0.0"
mkdir -p "$V"; cp -r "$T/." "$V/"
stamp_vault "$V" "0.9.0"
printf 'DEFAULT_X=1\r\n' > "$V/.env.example"
t64_pre=$(sha_of "$V/.env.example")
t64_dry=$(run_upgrade --dry-run 2>&1)
case "$t64_dry" in
    *"LOCAL-EDIT"*".env.example"*) fail "T64 EOL-only CRLF/LF is not a local edit" "got: $t64_dry" ;;
    *) pass "T64 EOL-only CRLF/LF is not a local edit" ;;
esac
case "$t64_dry" in
    *"WRITE        .env.example"*) fail "T64 EOL-only CRLF/LF file is not rewritten (reads as identical)" "got: $t64_dry" ;;
    *) pass "T64 EOL-only CRLF/LF file is not rewritten (reads as identical)" ;;
esac
run_upgrade --yes >/dev/null 2>&1; t64_rc=$?
assert_eq "T64 apply exits 0 (nothing withheld)" "0" "$t64_rc"
assert_eq "T64 apply leaves the CRLF file's bytes untouched" "$t64_pre" "$(sha_of "$V/.env.example")"
assert_eq "T64 stamp advances" "1.0.0" "$(t53_stamp_version)"

# ---------------------------------------------------------------------------
# T65-T68 (HIMMEL-3406): keep-mine. A genuine (non-EOL) local edit is
# withheld by default; --keep advances the stamp and records the decision
# against the template content it was made against; a later run that finds
# the template UNCHANGED for that file does not re-prompt; a later run where
# the template DOES change that file again re-surfaces it (the control).
T="$TMP/t65-tmpl"; V="$TMP/t65-vault"
make_template "$T" "1.0.0"
printf '# template doc v1\n' > "$T/docs/guide.md"
mkdir -p "$V"; cp -r "$T/." "$V/"
stamp_vault "$V" "0.1.0"
run_upgrade --yes >/dev/null 2>&1   # establish the stamp + content-snapshot baseline at 1.0.0
t65_snap=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("files",{}).get("docs/guide.md",""))' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T65 setup: stamp records a content snapshot for docs/guide.md" "sha256:$(sha_of "$V/docs/guide.md")" "$t65_snap"

# T65: a genuine local edit (real content, not EOL-only).
printf '# template doc v1\nmy own local note\n' > "$V/docs/guide.md"
t65_pre=$(sha_of "$V/docs/guide.md")
printf '{"metadata":{"version":"1.1.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf '# template doc v2\n' > "$T/docs/guide.md"
t65_dry=$(run_upgrade --dry-run 2>&1)
case "$t65_dry" in
    *"LOCAL-EDIT"*"docs/guide.md"*) pass "T65 dry-run surfaces LOCAL-EDIT for docs/guide.md (no --keep)" ;;
    *) fail "T65 dry-run surfaces LOCAL-EDIT for docs/guide.md (no --keep)" "got: $t65_dry" ;;
esac
run_upgrade --yes >/dev/null 2>&1; t65_rc=$?
assert_eq "T65 apply does NOT overwrite the local edit (default, no --keep)" "$t65_pre" "$(sha_of "$V/docs/guide.md")"
assert_eq "T65 apply exits 3 (NEEDS-RECONCILE)" "3" "$t65_rc"
assert_eq "T65 stamp NOT advanced" "1.0.0" "$(t53_stamp_version)"

# T66: re-run WITH --keep — advances the stamp and records the decision
# (the template sha the keep was made against).
t66_out=$(run_upgrade --yes --keep docs/guide.md 2>&1); t66_rc=$?
case "$t66_out" in
    *"KEEP-MINE"*"docs/guide.md"*) pass "T66 plan names docs/guide.md as kept" ;;
    *) fail "T66 plan names docs/guide.md as kept" "got: $t66_out" ;;
esac
assert_eq "T66 apply with --keep exits 0" "0" "$t66_rc"
assert_eq "T66 apply with --keep leaves the vault's content untouched" "$t65_pre" "$(sha_of "$V/docs/guide.md")"
assert_eq "T66 stamp advances" "1.1.0" "$(t53_stamp_version)"
t66_kept=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("kept",{}).get("docs/guide.md",""))' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T66 stamp records the keep-mine decision (template sha at decision time)" "sha256:$(sha_of "$T/docs/guide.md")" "$t66_kept"

# T67: a second upgrade, template UNCHANGED for this file — must NOT re-prompt.
printf '{"metadata":{"version":"1.2.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
t67_dry=$(run_upgrade --dry-run 2>&1)
case "$t67_dry" in
    *"LOCAL-EDIT"*"docs/guide.md"*) fail "T67 kept file is NOT re-surfaced when the template hasn't changed it" "got: $t67_dry" ;;
    *) pass "T67 kept file is NOT re-surfaced when the template hasn't changed it" ;;
esac
run_upgrade --yes >/dev/null 2>&1; t67_rc=$?
assert_eq "T67 apply exits 0 (no re-prompt)" "0" "$t67_rc"
assert_eq "T67 apply leaves the kept file's content untouched" "$t65_pre" "$(sha_of "$V/docs/guide.md")"
assert_eq "T67 stamp advances" "1.2.0" "$(t53_stamp_version)"
t67_kept=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("kept",{}).get("docs/guide.md",""))' "$V/.vault-template.json" 2>/dev/null)
assert_eq "T67 the keep-mine decision persists across a no-op re-prompt run" "sha256:$(sha_of "$T/docs/guide.md")" "$t67_kept"

# T68 (the required negative control): a third upgrade where the template
# CHANGES the SAME file again — the kept file DOES re-surface as withheld.
printf '{"metadata":{"version":"1.3.0"}}\n' > "$T/marketplace/.claude-plugin/marketplace.json"
printf '# template doc v3\n' > "$T/docs/guide.md"
t68_dry=$(run_upgrade --dry-run 2>&1)
case "$t68_dry" in
    *"LOCAL-EDIT"*"docs/guide.md"*) pass "T68 a later template change to the kept file re-surfaces it (negative control)" ;;
    *) fail "T68 a later template change to the kept file re-surfaces it (negative control)" "got: $t68_dry" ;;
esac
run_upgrade --yes >/dev/null 2>&1; t68_rc=$?
assert_eq "T68 apply does NOT overwrite (re-surfaced local edit)" "$t65_pre" "$(sha_of "$V/docs/guide.md")"
assert_eq "T68 apply exits 3 (NEEDS-RECONCILE)" "3" "$t68_rc"
assert_eq "T68 stamp NOT advanced" "1.2.0" "$(t53_stamp_version)"

echo
if [ "$FAILED" -eq 0 ]; then echo "All upgrade tests passed."; else echo "$FAILED test(s) failed."; exit 1; fi
