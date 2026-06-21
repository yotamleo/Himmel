#!/usr/bin/env bash
# Tests for scripts/luna-upgrade-all.sh (HIMMEL-462).
# Multi-vault luna template upgrade sweep.
# Each case builds throwaway fixtures under a temp dir and runs the engine
# with explicit --template-dir and --roots so nothing touches a real vault.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/luna-upgrade-all.sh"
REAL_UPGRADE="$HERE/../templates/luna-second-brain/scripts/upgrade.sh"

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

# Tool guard — skip if any required tool is absent
command -v python3 >/dev/null 2>&1 || { echo "SKIP all — python3 not on PATH"; exit 0; }
command -v git >/dev/null 2>&1     || { echo "SKIP all — git not on PATH"; exit 0; }
command -v sha256sum >/dev/null 2>&1 || { echo "SKIP all — sha256sum not on PATH"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Every engine invocation gets a hermetic HOME so registry + future backup dirs
# never leak into the real system.
THOME="$TMP/home"
mkdir -p "$THOME"

sha_of() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else echo MISSING; fi; }

# ---------------------------------------------------------------------------
# make_template <dir> <ver>
# Build a minimal but representative template fixture. Mirrors test-upgrade.sh's
# make_template shape so fixtures exercise the same upgrade.sh paths.
make_template() {
    local d="$1" ver="$2"
    mkdir -p "$d/marketplace/.claude-plugin" \
             "$d/scripts/hooks" \
             "$d/.obsidian/plugins/calendar" \
             "$d/_Templates" \
             "$d/docs"
    printf '{"metadata":{"version":"%s"}}\n' "$ver" \
        > "$d/marketplace/.claude-plugin/marketplace.json"
    printf '# Operating Manual\n\nline-a\nline-b\nline-c\n' > "$d/_CLAUDE.md"
    printf '#!/usr/bin/env bash\necho "template hook vTEMPLATE"\n' \
        > "$d/scripts/hooks/check-commit-msg.sh"
    printf '%s\n' '["dataview","calendar","new"]' \
        > "$d/.obsidian/community-plugins.json"
    printf '{"weekStart":"locale","wordsPerDot":250}\n' \
        > "$d/.obsidian/plugins/calendar/data.json"
    printf 'CALENDAR-MAIN-JS-TEMPLATE\n' \
        > "$d/.obsidian/plugins/calendar/main.js"
    printf '# Optional plugins\n\n| Plugin | License |\n| --- | --- |\n| Charts | AGPL |\n' \
        > "$d/.obsidian/PLUGINS-SETUP.md"
    printf '# Daily Note Template\n{{date}}\n' > "$d/_Templates/Daily-Note.md"
    printf '.env\n.env.*\n' > "$d/.gitignore"
    printf 'DEFAULT_X=1\n' > "$d/.env.example"
    printf '# Vault README vTEMPLATE\n' > "$d/README.md"
    printf '# template doc\n' > "$d/docs/guide.md"
    # Copy the real upgrade.sh into the fixture so luna-upgrade-all.sh can
    # shell out to it with --template-dir pointing at this fixture.
    mkdir -p "$d/scripts"
    cp "$REAL_UPGRADE" "$d/scripts/upgrade.sh"
}

# ---------------------------------------------------------------------------
# stamp_vault <dir> <ver>: write .vault-template.json at version ver.
stamp_vault() {
    local d="$1" ver="$2"
    printf '{"template":"luna-second-brain","version":"%s","upgraded_at":"2026-01-01T00:00:00Z"}\n' \
        "$ver" > "$d/.vault-template.json"
}

# ---------------------------------------------------------------------------
# make_luna_vault <dir> <ver-or-empty>: scaffold from a template copy + optional stamp.
# Copies the template structure into the vault dir and optionally stamps it.
make_luna_vault() {
    local d="$1" ver="$2" tmpl="$3"
    mkdir -p "$d"
    cp -r "$tmpl/." "$d/"
    # Remove marketplace.json from the vault (not a vault-resident file in the
    # same sense; upgrade.sh manages it via WRITE class, but the vault shouldn't
    # start with it looking like a template — keep the .obsidian scaffold though)
    if [ -n "$ver" ]; then
        stamp_vault "$d" "$ver"
    else
        rm -f "$d/.vault-template.json"
    fi
}

# ---------------------------------------------------------------------------
# make_unstamped_vault <dir>: .obsidian/ present, _CLAUDE.md, no stamp.
make_unstamped_vault() {
    local d="$1"
    mkdir -p "$d/.obsidian"
    printf '# My vault\n' > "$d/_CLAUDE.md"
}

# ---------------------------------------------------------------------------
# make_foreign_vault <dir>: only .obsidian/, no _CLAUDE.md, no stamp.
make_foreign_vault() {
    local d="$1"
    mkdir -p "$d/.obsidian"
}

# ---------------------------------------------------------------------------
# make_conflict_vault <vaultdir> <templatedir>:
# Build a vault that will produce a MERGE-3WAY CONFLICT on _CLAUDE.md.
# CRITICAL: must seed .vault-template.base/_CLAUDE.md = pristine template _CLAUDE.md
# then diverge both ours and theirs on the SAME line.
make_conflict_vault() {
    local d="$1" tmpl="$2"
    mkdir -p "$d/.vault-template.base"
    # (a) Scaffold vault strictly behind and stamp it
    make_luna_vault "$d" "0.9.0" "$tmpl"
    # (b) Write base snapshot = pristine template _CLAUDE.md
    cp "$tmpl/_CLAUDE.md" "$d/.vault-template.base/_CLAUDE.md"
    # (c) Overwrite vault _CLAUDE.md editing line 1 OUR way
    printf '# Operating Manual OURS\n\nline-a\nline-b\nline-c\n' > "$d/_CLAUDE.md"
    # (d) Edit template _CLAUDE.md THEIR way (same line 1) + bump template version
    printf '# Operating Manual THEIRS\n\nline-a\nline-b\nline-c\n' > "$tmpl/_CLAUDE.md"
    printf '{"metadata":{"version":"1.0.0"}}\n' \
        > "$tmpl/marketplace/.claude-plugin/marketplace.json"
}

# ---------------------------------------------------------------------------
# git_init_dirty <dir>: git init, commit, then touch a file (dirty state).
git_init_dirty() {
    local d="$1"
    git -C "$d" init -q
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" add -A
    git -C "$d" commit -q -m "initial"
    # Make it dirty
    printf 'DIRTY-CONTENT\n' > "$d/dirty-file.txt"
}

# ---------------------------------------------------------------------------
# run_engine: always sets HOME=$THOME and passes --template-dir
run_engine() {
    HOME="$THOME" bash "$ENGINE" "$@"
}

# ===========================================================================
# Task 2 tests — engine skeleton
# ===========================================================================

# T-help: --help exits 0
out=$(run_engine --help 2>&1); rc=$?
assert_eq "T-help exit 0" "0" "$rc"
case "$out" in *"sweep"*) pass "T-help contains sweep usage" ;; *) fail "T-help contains sweep usage" "got: $out" ;; esac

# T-unknown-sub: unknown subcommand exits 2
out=$(run_engine unknown-subcommand --template-dir /nonexistent 2>&1); rc=$?
assert_eq "T-unknown-sub exits 2" "2" "$rc"

# T-bad-template-dir: valid subcommand + bad --template-dir exits 2 with helpful message (I1)
T_BAD_TMPL_ROOTS="$TMP/t-bad-tmpl-roots"; mkdir -p "$T_BAD_TMPL_ROOTS"
out=$(run_engine sweep --template-dir /nonexistent/not-a-template --roots "$T_BAD_TMPL_ROOTS" 2>&1); rc=$?
assert_eq "T-bad-template-dir exits 2" "2" "$rc"
case "$out" in
    *"template"*|*"marketplace"*|*"luna-second-brain"*)
        pass "T-bad-template-dir mentions missing template/marketplace" ;;
    *) fail "T-bad-template-dir mentions missing template/marketplace" "got: $out" ;;
esac

# T-no-template: no template resolvable exits 2 with message
V_EMPTY="$TMP/t-empty-vault"; mkdir -p "$V_EMPTY"
out=$(HOME="$TMP/emptyhome" bash "$ENGINE" \
    sweep --roots "$TMP/no-roots-here" 2>&1); rc=$?
assert_eq "T-no-template exits 2" "2" "$rc"
case "$out" in *"could not locate"*|*"HIMMEL_DIR"*|*"template"*) pass "T-no-template prints helpful message" ;; *) fail "T-no-template prints helpful message" "got: $out" ;; esac

# T-with-template: with --template-dir pointing to a valid template, sweep on empty roots exits 0
T_BASE="$TMP/t-base-tmpl"
make_template "$T_BASE" "1.0.0"
EMPTY_ROOTS="$TMP/empty-roots"
mkdir -p "$EMPTY_ROOTS"
out=$(run_engine sweep --template-dir "$T_BASE" --roots "$EMPTY_ROOTS" 2>&1); rc=$?
assert_eq "T-with-template empty-roots exits 0" "0" "$rc"

# ===========================================================================
# Task 3 tests — discovery + classification
# ===========================================================================

# Build a fixture set:
#   - roots/luna-family: luna-family vault in roots
#   - roots/unstamped: unstamped vault in roots
#   - roots/foreign: foreign vault (only .obsidian, no CLAUDE) in roots
#   - registry-only luna vault outside roots

T_DISC="$TMP/disc-tmpl"; make_template "$T_DISC" "1.0.0"
DISC_ROOTS="$TMP/disc-roots"; mkdir -p "$DISC_ROOTS"

# In-roots vaults
LF_VAULT="$DISC_ROOTS/luna-family"
make_luna_vault "$LF_VAULT" "1.0.0" "$T_DISC"   # already-current

UNS_VAULT="$DISC_ROOTS/unstamped-vault"
make_unstamped_vault "$UNS_VAULT"

FOR_VAULT="$DISC_ROOTS/foreign-vault"
make_foreign_vault "$FOR_VAULT"

# Registry-only vault (outside roots)
REG_VAULT="$TMP/registry-only"
make_luna_vault "$REG_VAULT" "1.0.0" "$T_DISC"

# Write registry JSON
DISC_REG="$TMP/disc-reg.json"
printf '{"vaults":{"reg-vault":"%s"}}\n' "$REG_VAULT" > "$DISC_REG"

# classify_vault tests via the sweep --porcelain output
disc_out=$(run_engine sweep --porcelain \
    --template-dir "$T_DISC" \
    --roots "$DISC_ROOTS" \
    --registry "$DISC_REG" 2>&1)

# luna-family should appear
case "$disc_out" in *"$LF_VAULT"*) pass "T-disc luna-family appears in sweep" ;; *) fail "T-disc luna-family appears in sweep" "got: $disc_out" ;; esac
# unstamped should appear
case "$disc_out" in *"$UNS_VAULT"*) pass "T-disc unstamped appears in sweep" ;; *) fail "T-disc unstamped appears in sweep" "got: $disc_out" ;; esac
# registry-only vault should appear
case "$disc_out" in *"$REG_VAULT"*) pass "T-disc registry-only vault appears in sweep" ;; *) fail "T-disc registry-only vault appears in sweep" "got: $disc_out" ;; esac

# foreign vault (.obsidian only, no template) — classify_vault returns unstamped
# (it has .obsidian but no stamp). It should be in results.
case "$disc_out" in *"$FOR_VAULT"*) pass "T-disc foreign-vault (.obsidian only) appears as unstamped" ;; *) fail "T-disc foreign-vault (.obsidian only) appears as unstamped" "got: $disc_out" ;; esac

# luna-family classified correctly (state column = already-current, not unstamped)
lf_line=$(printf '%s\n' "$disc_out" | grep "$LF_VAULT" | head -1)
case "$lf_line" in
    already-current*|*"already-current"*) pass "T-disc luna-family classified as already-current" ;;
    *) fail "T-disc luna-family classified as already-current" "got: $lf_line" ;;
esac

# unstamped classified correctly
uns_line=$(printf '%s\n' "$disc_out" | grep "$UNS_VAULT" | head -1)
case "$uns_line" in
    unstamped*) pass "T-disc unstamped classified correctly" ;;
    *) fail "T-disc unstamped classified correctly" "got: $uns_line" ;;
esac

# Dedup test — add the same vault to registry AND roots; should appear once
DEDUP_ROOT="$TMP/dedup-roots"; mkdir -p "$DEDUP_ROOT"
DEDUP_VAULT="$DEDUP_ROOT/dedup-vault"
make_luna_vault "$DEDUP_VAULT" "1.0.0" "$T_DISC"
DEDUP_REG="$TMP/dedup-reg.json"
printf '{"vaults":{"dup":"%s"}}\n' "$DEDUP_VAULT" > "$DEDUP_REG"
dedup_out=$(run_engine sweep --porcelain \
    --template-dir "$T_DISC" \
    --roots "$DEDUP_ROOT" \
    --registry "$DEDUP_REG" 2>&1)
dedup_count=$(printf '%s\n' "$dedup_out" | grep -c "$DEDUP_VAULT" || true)
assert_eq "T-disc dedup: vault in both sources appears once" "1" "$dedup_count"

# ===========================================================================
# Task 4 tests — sweep table + --porcelain TSV
# ===========================================================================

T_SW="$TMP/sw-tmpl"; make_template "$T_SW" "1.0.0"
SW_ROOTS="$TMP/sw-roots"; mkdir -p "$SW_ROOTS"

# 1. already-current vault (stamp == template version)
SW_CURR="$SW_ROOTS/current-vault"
make_luna_vault "$SW_CURR" "1.0.0" "$T_SW"

# 2. behind-clean vault (stamp < template) — use a fresh template copy so
#    files differ from vault's stale copies
SW_BEHIND="$SW_ROOTS/behind-vault"
mkdir -p "$SW_BEHIND"
make_luna_vault "$SW_BEHIND" "0.9.0" "$T_SW"
# Make a file actually differ so the plan has ≥1 line
printf 'STALE HOOK\n' > "$SW_BEHIND/scripts/hooks/check-commit-msg.sh"

# 3. conflict vault — uses its own template (T_SW_CONF) so the template
#    _CLAUDE.md diverges from the vault's base. Tested separately with T_SW_CONF.
T_SW_CONF="$TMP/sw-conf-tmpl"; make_template "$T_SW_CONF" "0.9.0"
SW_CONF_ROOTS="$TMP/sw-conf-roots"; mkdir -p "$SW_CONF_ROOTS"
SW_CONF="$SW_CONF_ROOTS/conflict-vault"
make_conflict_vault "$SW_CONF" "$T_SW_CONF"
# T_SW_CONF now has: _CLAUDE.md="THEIRS", version=1.0.0
# SW_CONF has: .vault-template.base/_CLAUDE.md=original, _CLAUDE.md="OURS", stamp=0.9.0
SW_CONF_REG="$TMP/sw-conf-reg.json"
printf '{"vaults":{}}\n' > "$SW_CONF_REG"

# 4. unstamped vault
SW_UNS="$SW_ROOTS/unstamped-vault"
make_unstamped_vault "$SW_UNS"

# 5. git-dirty behind-clean vault
SW_DIRTY="$SW_ROOTS/dirty-vault"
mkdir -p "$SW_DIRTY"
make_luna_vault "$SW_DIRTY" "0.9.0" "$T_SW"
printf 'STALE HOOK\n' > "$SW_DIRTY/scripts/hooks/check-commit-msg.sh"
git_init_dirty "$SW_DIRTY"

# 6. vault with SPACE in path (tests banner version parse)
SW_SPACE_DIR="$TMP/sw space roots"; mkdir -p "$SW_SPACE_DIR"
SW_SPACE="$SW_SPACE_DIR/space vault"
mkdir -p "$SW_SPACE"
make_luna_vault "$SW_SPACE" "0.9.0" "$T_SW"
printf 'STALE HOOK\n' > "$SW_SPACE/scripts/hooks/check-commit-msg.sh"
# Include the space vault in roots as well
SW_MULTI_ROOTS="$SW_ROOTS,$SW_SPACE_DIR"

SW_REG="$TMP/sw-reg.json"
printf '{"vaults":{}}\n' > "$SW_REG"

sw_out=$(run_engine sweep --porcelain \
    --template-dir "$T_SW" \
    --roots "$SW_MULTI_ROOTS" \
    --registry "$SW_REG" 2>&1)

# already-current
curr_line=$(printf '%s\n' "$sw_out" | grep "$SW_CURR" | head -1)
case "$curr_line" in
    already-current*) pass "T-sw already-current state" ;;
    *) fail "T-sw already-current state" "got: $curr_line" ;;
esac

# behind-clean: state=clean-upgrade, from=0.9.0, to=1.0.0
behind_line=$(printf '%s\n' "$sw_out" | grep "$SW_BEHIND" | head -1)
case "$behind_line" in
    clean-upgrade*) pass "T-sw clean-upgrade state for behind vault" ;;
    *) fail "T-sw clean-upgrade state for behind vault" "got: $behind_line" ;;
esac
# Extract from and to columns (TSV: state\tfrom\tto\tdirty\tpath)
behind_from=$(printf '%s\n' "$behind_line" | cut -f2)
behind_to=$(printf '%s\n' "$behind_line" | cut -f3)
assert_eq "T-sw behind-clean from version" "0.9.0" "$behind_from"
assert_eq "T-sw behind-clean to version" "1.0.0" "$behind_to"

# Verify ≥1 plan line was actually present (not a no-op masquerade)
# We need to run dry-run separately for this
behind_dry=$(HOME="$THOME" bash "$T_SW/scripts/upgrade.sh" \
    --template-dir "$T_SW" --vault-dir "$SW_BEHIND" --dry-run 2>&1)
if printf '%s\n' "$behind_dry" | grep -qE '^ +(WRITE|MERGE-JSON|MERGE-3WAY)'; then
    pass "T-sw behind-clean has ≥1 plan line in dry-run"
else
    fail "T-sw behind-clean has ≥1 plan line in dry-run" "no plan lines in: $behind_dry"
fi

# conflict vault — tested with its own template (T_SW_CONF) so theirs diverges
conf_sw_out=$(run_engine sweep --porcelain \
    --template-dir "$T_SW_CONF" \
    --roots "$SW_CONF_ROOTS" \
    --registry "$SW_CONF_REG" 2>&1)
conf_line=$(printf '%s\n' "$conf_sw_out" | grep "$SW_CONF" | head -1)
case "$conf_line" in
    conflict*) pass "T-sw conflict state for conflict vault" ;;
    *) fail "T-sw conflict state for conflict vault" "got: $conf_line (full: $conf_sw_out)" ;;
esac

# unstamped
uns_line=$(printf '%s\n' "$sw_out" | grep "$SW_UNS" | head -1)
case "$uns_line" in
    unstamped*) pass "T-sw unstamped state" ;;
    *) fail "T-sw unstamped state" "got: $uns_line" ;;
esac
# unstamped has empty version cols
uns_from=$(printf '%s\n' "$uns_line" | cut -f2)
uns_to=$(printf '%s\n' "$uns_line" | cut -f3)
assert_eq "T-sw unstamped from is empty" "" "$uns_from"
assert_eq "T-sw unstamped to is empty" "" "$uns_to"

# git-dirty behind-clean: dirty=true
dirty_line=$(printf '%s\n' "$sw_out" | grep "$SW_DIRTY" | head -1)
case "$dirty_line" in
    clean-upgrade*) pass "T-sw dirty vault still shows clean-upgrade (sweep advisory only)" ;;
    *) fail "T-sw dirty vault still shows clean-upgrade" "got: $dirty_line" ;;
esac
dirty_col=$(printf '%s\n' "$dirty_line" | cut -f4)
assert_eq "T-sw dirty vault dirty=true" "true" "$dirty_col"

# space-in-path vault: must appear + have correct from/to parse
space_line=$(printf '%s\n' "$sw_out" | grep "space vault" | head -1)
case "$space_line" in
    clean-upgrade*) pass "T-sw space-in-path vault detected as clean-upgrade" ;;
    *) fail "T-sw space-in-path vault detected as clean-upgrade" "got: $space_line" ;;
esac
space_from=$(printf '%s\n' "$space_line" | cut -f2)
space_to=$(printf '%s\n' "$space_line" | cut -f3)
assert_eq "T-sw space-path from version" "0.9.0" "$space_from"
assert_eq "T-sw space-path to version" "1.0.0" "$space_to"

# Best-effort (I4): a vault whose dry-run exits ≥2 must emit state=error and the
# sweep must continue to process later vaults.
#
# Recipe: build a genuine luna-family vault (valid .vault-template.json with
# template=luna-second-brain) so classify_vault returns luna-family and the
# sweep calls upgrade.sh for it. Use an error-template whose upgrade.sh is a
# stub that unconditionally exits 2 — this guarantees dry_rc≥2 and exercises
# the error→continue path in cmd_sweep.
#
# The sweep for this test uses its own roots dir containing:
#   - SW_CORRUPT (luna-family, upgrade.sh exits 2) → must get state=error
#   - SW_CORRUPT_AFTER (luna-family, healthy) → must still appear (continuation)
T_SW_ERR="$TMP/sw-err-tmpl"
mkdir -p "$T_SW_ERR/marketplace/.claude-plugin" \
         "$T_SW_ERR/scripts"
# Valid marketplace.json so resolve_template accepts this dir
printf '{"metadata":{"version":"1.0.0"}}\n' \
    > "$T_SW_ERR/marketplace/.claude-plugin/marketplace.json"
# Stub upgrade.sh that always exits 2 (simulates a real upgrade engine failure)
printf '#!/usr/bin/env bash\necho "upgrade: simulated error" >&2\nexit 2\n' \
    > "$T_SW_ERR/scripts/upgrade.sh"
chmod +x "$T_SW_ERR/scripts/upgrade.sh"

SW_ERR_ROOTS="$TMP/sw-err-roots"; mkdir -p "$SW_ERR_ROOTS"
SW_CORRUPT="$SW_ERR_ROOTS/corrupt-vault"
mkdir -p "$SW_CORRUPT"
stamp_vault "$SW_CORRUPT" "0.9.0"    # luna-family: classify_vault returns luna-family
mkdir -p "$SW_CORRUPT/.obsidian"      # also has .obsidian (not required, defensive)

SW_CORRUPT_AFTER="$SW_ERR_ROOTS/after-vault"
make_luna_vault "$SW_CORRUPT_AFTER" "0.9.0" "$T_SW"
printf 'STALE HOOK\n' > "$SW_CORRUPT_AFTER/scripts/hooks/check-commit-msg.sh"

SW_ERR_REG="$TMP/sw-err-reg.json"
printf '{"vaults":{}}\n' > "$SW_ERR_REG"

corrupt_out=$(run_engine sweep --porcelain \
    --template-dir "$T_SW_ERR" \
    --roots "$SW_ERR_ROOTS" \
    --registry "$SW_ERR_REG" 2>&1)

# SW_CORRUPT must appear with state=error
corrupt_line=$(printf '%s\n' "$corrupt_out" | grep "$SW_CORRUPT$" | head -1)
case "$corrupt_line" in
    error*) pass "T-sw best-effort: corrupt vault gets state=error" ;;
    *) fail "T-sw best-effort: corrupt vault gets state=error" "got: $corrupt_line (full: $corrupt_out)" ;;
esac

# SW_CORRUPT_AFTER (the later vault) must still appear — proves continuation
case "$corrupt_out" in
    *"$SW_CORRUPT_AFTER"*) pass "T-sw best-effort: later vault appears after error vault" ;;
    *) fail "T-sw best-effort: later vault appears after error vault" "corrupt_out had no expected later vault; got: $corrupt_out" ;;
esac

# ===========================================================================
# Human table (non-porcelain) smoke test
# ===========================================================================
human_out=$(run_engine sweep \
    --template-dir "$T_SW" \
    --roots "$SW_ROOTS" \
    --registry "$SW_REG" 2>&1)
case "$human_out" in
    *"STATE"*"VAULT"*) pass "T-sw human table has header" ;;
    *) fail "T-sw human table has header" "got: $human_out" ;;
esac

# ===========================================================================
# Task 5 tests — backup_vault helper
# ===========================================================================

# Capture real HOME at suite start for the safety assertion (I1 fix: HIMMEL-462).
# Snapshot which subdirs ALREADY EXIST before we run anything; we'll compare
# at suite end so we don't rely on a hardcoded slug allowlist that can drift.
REAL_HOME_BACKUP_DIR="$HOME/.claude/luna-upgrade-backups"
_real_home_pre_slugs=""
if [ -d "$REAL_HOME_BACKUP_DIR" ]; then
    _real_home_pre_slugs="$(ls -1 "$REAL_HOME_BACKUP_DIR" 2>/dev/null || true)"
fi

# T5-a: backup with community-plugins.json and .vault-template.base/ ABSENT
T5_TMPL="$TMP/t5-tmpl"; make_template "$T5_TMPL" "1.0.0"
T5_VAULT="$TMP/t5-vault"
make_luna_vault "$T5_VAULT" "0.9.0" "$T5_TMPL"
# Add a scripts/x file to vault for "existing" class test
mkdir -p "$T5_VAULT/scripts"
printf 'echo x\n' > "$T5_VAULT/scripts/x"
# Ensure community-plugins.json is absent
rm -f "$T5_VAULT/.obsidian/community-plugins.json"
# Ensure .vault-template.base/ is absent
rm -rf "$T5_VAULT/.vault-template.base"

# Call backup_vault directly through the engine by running apply and checking
# the backup created. We use a wrapper: run apply and capture the BACKUP line.
t5_apply_out=$(run_engine apply --template-dir "$T5_TMPL" --vault "$T5_VAULT" 2>&1) || true
t5_backup_dest=$(printf '%s\n' "$t5_apply_out" | grep '^BACKUP	' | head -1 | cut -f2)

if [ -n "$t5_backup_dest" ] && [ -d "$t5_backup_dest" ]; then
    pass "T5-a: backup dir created"
else
    fail "T5-a: backup dir created" "apply out: $t5_apply_out"
fi

if [ -f "$t5_backup_dest/manifest.tsv" ]; then
    pass "T5-a: manifest.tsv exists"

    t5_manifest=$(cat "$t5_backup_dest/manifest.tsv")

    # community-plugins.json is ABSENT -> should be 'new'
    if printf '%s\n' "$t5_manifest" | grep -q "^new	.obsidian/community-plugins.json"; then
        pass "T5-a: absent community-plugins.json recorded as new"
    else
        fail "T5-a: absent community-plugins.json recorded as new" "manifest: $t5_manifest"
    fi

    # .vault-template.base is ABSENT -> should be 'new'
    if printf '%s\n' "$t5_manifest" | grep -q "^new	.vault-template.base$"; then
        pass "T5-a: absent .vault-template.base recorded as new"
    else
        fail "T5-a: absent .vault-template.base recorded as new" "manifest: $t5_manifest"
    fi

    # REPORT lines should NOT appear
    if printf '%s\n' "$t5_manifest" | grep -q "^existing	_Templates/"; then
        fail "T5-a: REPORT lines excluded from manifest" "manifest has _Templates/ entry"
    elif printf '%s\n' "$t5_manifest" | grep -q "^new	_Templates/"; then
        fail "T5-a: REPORT lines excluded from manifest" "manifest has _Templates/ entry"
    else
        pass "T5-a: REPORT lines excluded from manifest"
    fi

    # .vault-template.json should appear as existing (it was stamped)
    if printf '%s\n' "$t5_manifest" | grep -q "^existing	.vault-template.json"; then
        pass "T5-a: .vault-template.json recorded as existing"
    else
        fail "T5-a: .vault-template.json recorded as existing" "manifest: $t5_manifest"
    fi
else
    fail "T5-a: manifest.tsv exists" "no manifest at: $t5_backup_dest"
fi

# T5-b: backup with .vault-template.base/_CLAUDE.md PRESENT pre-backup
T5B_TMPL="$TMP/t5b-tmpl"; make_template "$T5B_TMPL" "1.0.0"
T5B_VAULT="$TMP/t5b-vault"
make_luna_vault "$T5B_VAULT" "0.9.0" "$T5B_TMPL"
# Seed .vault-template.base/_CLAUDE.md
mkdir -p "$T5B_VAULT/.vault-template.base"
printf '# Operating Manual BASE\n' > "$T5B_VAULT/.vault-template.base/_CLAUDE.md"

t5b_apply_out=$(run_engine apply --template-dir "$T5B_TMPL" --vault "$T5B_VAULT" 2>&1) || true
t5b_backup_dest=$(printf '%s\n' "$t5b_apply_out" | grep '^BACKUP	' | head -1 | cut -f2)

if [ -n "$t5b_backup_dest" ] && [ -d "$t5b_backup_dest" ]; then
    t5b_manifest=$(cat "$t5b_backup_dest/manifest.tsv" 2>/dev/null || true)

    # .vault-template.base should be existing
    if printf '%s\n' "$t5b_manifest" | grep -q "^existing	.vault-template.base$"; then
        pass "T5-b: present .vault-template.base recorded as existing"
    else
        fail "T5-b: present .vault-template.base recorded as existing" "manifest: $t5b_manifest"
    fi

    # The file INSIDE .vault-template.base should have a byte copy
    if [ -f "$t5b_backup_dest/.vault-template.base/_CLAUDE.md" ]; then
        pass "T5-b: .vault-template.base/_CLAUDE.md has byte copy in backup"
    else
        fail "T5-b: .vault-template.base/_CLAUDE.md has byte copy in backup" "not found at $t5b_backup_dest/.vault-template.base/_CLAUDE.md"
    fi

    # The file entry should appear in manifest as existing
    if printf '%s\n' "$t5b_manifest" | grep -q "^existing	.vault-template.base/_CLAUDE.md"; then
        pass "T5-b: .vault-template.base/_CLAUDE.md in manifest as existing"
    else
        fail "T5-b: .vault-template.base/_CLAUDE.md in manifest as existing" "manifest: $t5b_manifest"
    fi
else
    fail "T5-b: backup dir created" "apply out: $t5b_apply_out"
fi

# T5-c: slug sanitization on path with spaces
T5C_TMPL="$TMP/t5c-tmpl"; make_template "$T5C_TMPL" "1.0.0"
T5C_SPACE_PARENT="$TMP/t5c space parent"; mkdir -p "$T5C_SPACE_PARENT"
T5C_VAULT="$T5C_SPACE_PARENT/my vault"
make_luna_vault "$T5C_VAULT" "0.9.0" "$T5C_TMPL"
printf 'STALE\n' > "$T5C_VAULT/scripts/hooks/check-commit-msg.sh"

t5c_out=$(run_engine apply --template-dir "$T5C_TMPL" --vault "$T5C_VAULT" 2>&1) || true
t5c_backup=$(printf '%s\n' "$t5c_out" | grep '^BACKUP	' | head -1 | cut -f2)
if [ -n "$t5c_backup" ] && [ -d "$t5c_backup" ]; then
    # Slug dir name should not contain spaces
    t5c_slug_dir="$(dirname "$t5c_backup")"
    t5c_slug_name="$(basename "$t5c_slug_dir")"
    case "$t5c_slug_name" in
        *" "*) fail "T5-c: slug has no spaces" "slug: $t5c_slug_name" ;;
        *)     pass "T5-c: slug sanitization (spaces->_)" ;;
    esac
else
    fail "T5-c: backup created for vault with spaces in path" "out: $t5c_out"
fi

# ===========================================================================
# Task 6 tests — apply subcommand
# ===========================================================================

# T6-a: behind-clean vault -> OK exit 0, backup+manifest, stamp==template
T6_TMPL="$TMP/t6-tmpl"; make_template "$T6_TMPL" "1.0.0"
T6_VAULT="$TMP/t6-vault"
make_luna_vault "$T6_VAULT" "0.9.0" "$T6_TMPL"
# Make a file differ so dry-run has ≥1 plan line
printf 'STALE HOOK\n' > "$T6_VAULT/scripts/hooks/check-commit-msg.sh"

# Assert dry-run has ≥1 plan line first (anti-no-op-masquerade)
t6_dry=$(HOME="$THOME" bash "$T6_TMPL/scripts/upgrade.sh" \
    --template-dir "$T6_TMPL" --vault-dir "$T6_VAULT" --dry-run 2>&1)
if printf '%s\n' "$t6_dry" | grep -qE '^ +(WRITE|MERGE-JSON|MERGE-3WAY)'; then
    pass "T6-a: behind-clean dry-run has ≥1 plan line"
else
    fail "T6-a: behind-clean dry-run has ≥1 plan line" "dry-run: $t6_dry"
fi

t6_out=$(run_engine apply --template-dir "$T6_TMPL" --vault "$T6_VAULT" 2>&1)
t6_rc=$?
assert_eq "T6-a: apply exits 0 for behind-clean" "0" "$t6_rc"
if printf '%s\n' "$t6_out" | grep -q "^OK	"; then
    pass "T6-a: apply emits OK line"
else
    fail "T6-a: apply emits OK line" "got: $t6_out"
fi

t6_backup=$(printf '%s\n' "$t6_out" | grep '^BACKUP	' | cut -f2)
if [ -n "$t6_backup" ] && [ -d "$t6_backup" ]; then
    pass "T6-a: backup dir exists"
    if [ -f "$t6_backup/manifest.tsv" ]; then
        pass "T6-a: manifest.tsv exists"
    else
        fail "T6-a: manifest.tsv exists" "not found"
    fi
else
    fail "T6-a: backup dir exists" "BACKUP line: '$t6_backup'"
fi

t6_stamp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' \
    "$T6_VAULT/.vault-template.json" 2>/dev/null)
assert_eq "T6-a: stamp == template version after apply" "1.0.0" "$t6_stamp"

# T6-b + T6-e: CONFLICT vs PARTIAL (isolated assertion block)
# T6-b: conflict vault -> CONFLICT exit 1, sidecar present, backup retained
T6B_TMPL="$TMP/t6b-tmpl"; make_template "$T6B_TMPL" "0.9.0"
T6B_VAULT="$TMP/t6b-vault"
make_conflict_vault "$T6B_VAULT" "$T6B_TMPL"
# T6B_TMPL now has version=1.0.0, _CLAUDE.md=THEIRS

t6b_rc=0
t6b_out=$(run_engine apply --template-dir "$T6B_TMPL" --vault "$T6B_VAULT" 2>&1) || t6b_rc=$?
assert_eq "T6-b: CONFLICT apply exits 1" "1" "$t6b_rc"

if printf '%s\n' "$t6b_out" | grep -q "^CONFLICT	"; then
    pass "T6-b: apply emits CONFLICT line"
else
    fail "T6-b: apply emits CONFLICT line" "got: $t6b_out"
fi

if [ -f "$T6B_VAULT/_CLAUDE.md.template-merge" ]; then
    pass "T6-b: sidecar _CLAUDE.md.template-merge present"
else
    fail "T6-b: sidecar _CLAUDE.md.template-merge present" "not found"
fi

t6b_backup=$(printf '%s\n' "$t6b_out" | grep '^BACKUP	' | cut -f2)
if [ -n "$t6b_backup" ] && [ -d "$t6b_backup" ]; then
    pass "T6-b: backup retained after CONFLICT"
else
    fail "T6-b: backup retained after CONFLICT" "BACKUP line: '$t6b_backup'"
fi

# T6-e: write-failure fixture (PARTIAL exit 1, NO sidecar)
# Template ships scripts/extra/tool.sh; vault has scripts/extra as a regular FILE
T6E_TMPL="$TMP/t6e-tmpl"; make_template "$T6E_TMPL" "1.0.0"
# Add scripts/extra/tool.sh to template
mkdir -p "$T6E_TMPL/scripts/extra"
printf '#!/usr/bin/env bash\necho "extra tool"\n' > "$T6E_TMPL/scripts/extra/tool.sh"

T6E_VAULT="$TMP/t6e-vault"
make_luna_vault "$T6E_VAULT" "0.9.0" "$T6E_TMPL"
# Remove the scripts/extra dir from vault and replace with a regular FILE (write-failure trap)
rm -rf "$T6E_VAULT/scripts/extra"
printf 'I AM A FILE NOT A DIR\n' > "$T6E_VAULT/scripts/extra"
# No _CLAUDE.md divergence: vault's _CLAUDE.md matches template line-for-line
# (both were seeded from same make_template base), so no conflict sidecar.
# Copy template _CLAUDE.md to vault to ensure clean merge
cp "$T6E_TMPL/_CLAUDE.md" "$T6E_VAULT/_CLAUDE.md"

t6e_rc=0
t6e_out=$(run_engine apply --template-dir "$T6E_TMPL" --vault "$T6E_VAULT" 2>&1) || t6e_rc=$?

# CONFLICT-vs-PARTIAL isolation block
assert_eq "T6-e: PARTIAL apply exits 1" "1" "$t6e_rc"
if printf '%s\n' "$t6e_out" | grep -q "^PARTIAL	"; then
    pass "T6-e: apply emits PARTIAL line (not CONFLICT)"
else
    fail "T6-e: apply emits PARTIAL line (not CONFLICT)" "got: $t6e_out"
fi
if [ -f "$T6E_VAULT/_CLAUDE.md.template-merge" ]; then
    fail "T6-e: PARTIAL has NO sidecar" "sidecar found (should not exist for write-failure)"
else
    pass "T6-e: PARTIAL has NO sidecar"
fi

# T6-c: dirty git vault -> SKIPPED-DIRTY exit 3, NO backup
T6C_TMPL="$TMP/t6c-tmpl"; make_template "$T6C_TMPL" "1.0.0"
T6C_VAULT="$TMP/t6c-vault"
make_luna_vault "$T6C_VAULT" "0.9.0" "$T6C_TMPL"
git_init_dirty "$T6C_VAULT"

t6c_rc=0
t6c_out=$(run_engine apply --template-dir "$T6C_TMPL" --vault "$T6C_VAULT" 2>&1) || t6c_rc=$?
assert_eq "T6-c: dirty git exits 3" "3" "$t6c_rc"
if printf '%s\n' "$t6c_out" | grep -q "^SKIPPED-DIRTY	"; then
    pass "T6-c: apply emits SKIPPED-DIRTY"
else
    fail "T6-c: apply emits SKIPPED-DIRTY" "got: $t6c_out"
fi
# No backup created for dirty vault
if printf '%s\n' "$t6c_out" | grep -q "^BACKUP	"; then
    fail "T6-c: no backup created for dirty vault" "BACKUP line found: $t6c_out"
else
    pass "T6-c: no backup created for dirty vault"
fi

# T6-d: unstamped vault -> exit 2 without --force-unstamped
T6D_VAULT="$TMP/t6d-vault"
make_unstamped_vault "$T6D_VAULT"
T6D_TMPL="$TMP/t6d-tmpl"; make_template "$T6D_TMPL" "1.0.0"

t6d_rc=0
run_engine apply --template-dir "$T6D_TMPL" --vault "$T6D_VAULT" >/dev/null 2>&1 || t6d_rc=$?
assert_eq "T6-d: unstamped exits 2 without --force-unstamped" "2" "$t6d_rc"

# With --force-unstamped + _CLAUDE.md present -> proceeds (exits 0 for clean)
t6d_force_rc=0
t6d_force_out=$(run_engine apply --template-dir "$T6D_TMPL" --vault "$T6D_VAULT" \
    --force-unstamped 2>&1) || t6d_force_rc=$?
# Should exit 0 (clean) or 1 (partial/conflict) — NOT 2 or 3
if [ "$t6d_force_rc" -le 1 ]; then
    pass "T6-d: unstamped + --force-unstamped proceeds (exits 0 or 1)"
else
    fail "T6-d: unstamped + --force-unstamped proceeds" "rc=$t6d_force_rc, out: $t6d_force_out"
fi

# ===========================================================================
# Task 7 tests — restore subcommand
# ===========================================================================

# T7-a: apply->restore round-trip (sha-identical restore)
T7_TMPL="$TMP/t7-tmpl"; make_template "$T7_TMPL" "1.0.0"
T7_VAULT="$TMP/t7-vault"
make_luna_vault "$T7_VAULT" "0.9.0" "$T7_TMPL"
# Make a file differ so apply has something to do
printf 'STALE HOOK\n' > "$T7_VAULT/scripts/hooks/check-commit-msg.sh"

# Capture pre-apply shas of representative files + stamp
t7_pre_hook_sha=$(sha_of "$T7_VAULT/scripts/hooks/check-commit-msg.sh")
t7_pre_stamp_sha=$(sha_of "$T7_VAULT/.vault-template.json")

t7_apply_rc=0
run_engine apply --template-dir "$T7_TMPL" --vault "$T7_VAULT" >/dev/null 2>&1 || t7_apply_rc=$?
assert_eq "T7-a: apply exits 0" "0" "$t7_apply_rc"
# Restore
t7_restore_out=$(run_engine restore --template-dir "$T7_TMPL" --vault "$T7_VAULT" 2>&1)
t7_restore_rc=$?
assert_eq "T7-a: restore exits 0" "0" "$t7_restore_rc"

if printf '%s\n' "$t7_restore_out" | grep -q "^RESTORED	"; then
    pass "T7-a: restore emits RESTORED line"
else
    fail "T7-a: restore emits RESTORED line" "got: $t7_restore_out"
fi

# Verify sha matches pre-apply
t7_post_hook_sha=$(sha_of "$T7_VAULT/scripts/hooks/check-commit-msg.sh")
assert_eq "T7-a: hook file sha matches pre-apply after restore" "$t7_pre_hook_sha" "$t7_post_hook_sha"

t7_post_stamp_sha=$(sha_of "$T7_VAULT/.vault-template.json")
assert_eq "T7-a: stamp sha matches pre-apply after restore" "$t7_pre_stamp_sha" "$t7_post_stamp_sha"

# T7-b: absent-base case — no pre-apply .vault-template.base/
# T7_VAULT above had no base dir; verify it's absent after restore
if [ -d "$T7_VAULT/.vault-template.base" ]; then
    fail "T7-b: .vault-template.base absent again after restore" "dir exists"
else
    pass "T7-b: .vault-template.base absent after restore (was new, deleted on restore)"
fi

# T7-c: absent community-plugins.json — verify absent after restore
# We need a fixture where community-plugins.json was removed pre-apply
T7C_TMPL="$TMP/t7c-tmpl"; make_template "$T7C_TMPL" "1.0.0"
T7C_VAULT="$TMP/t7c-vault"
make_luna_vault "$T7C_VAULT" "0.9.0" "$T7C_TMPL"
rm -f "$T7C_VAULT/.obsidian/community-plugins.json"
printf 'STALE\n' > "$T7C_VAULT/scripts/hooks/check-commit-msg.sh"

run_engine apply --template-dir "$T7C_TMPL" --vault "$T7C_VAULT" >/dev/null 2>&1
# Restore
run_engine restore --template-dir "$T7C_TMPL" --vault "$T7C_VAULT" >/dev/null 2>&1 || true
if [ -f "$T7C_VAULT/.obsidian/community-plugins.json" ]; then
    fail "T7-c: community-plugins.json absent after restore (was new)" "file exists"
else
    pass "T7-c: community-plugins.json absent after restore (was new, deleted)"
fi

# T7-d: PRESENT-base content round-trip (load-bearing)
T7D_TMPL="$TMP/t7d-tmpl"; make_template "$T7D_TMPL" "1.0.0"
T7D_VAULT="$TMP/t7d-vault"
make_luna_vault "$T7D_VAULT" "0.9.0" "$T7D_TMPL"
# Seed .vault-template.base/_CLAUDE.md with known content BEFORE apply
mkdir -p "$T7D_VAULT/.vault-template.base"
printf '# Base content BEFORE apply\n' > "$T7D_VAULT/.vault-template.base/_CLAUDE.md"
t7d_pre_base_sha=$(sha_of "$T7D_VAULT/.vault-template.base/_CLAUDE.md")
# Make script differ so apply actually runs
printf 'STALE\n' > "$T7D_VAULT/scripts/hooks/check-commit-msg.sh"

t7d_apply_rc=0
run_engine apply --template-dir "$T7D_TMPL" --vault "$T7D_VAULT" >/dev/null 2>&1 || t7d_apply_rc=$?
assert_eq "T7-d: apply exits 0" "0" "$t7d_apply_rc"

# Restore
run_engine restore --template-dir "$T7D_TMPL" --vault "$T7D_VAULT" >/dev/null 2>&1 || true

t7d_post_base_sha=$(sha_of "$T7D_VAULT/.vault-template.base/_CLAUDE.md")
assert_eq "T7-d: base file sha == PRE-apply after restore" "$t7d_pre_base_sha" "$t7d_post_base_sha"

# T7-e: vault-mismatch refusal
# Two vaults with the SAME basename but different parents (same slug in backup dir):
# Apply to vault A creates $slug/<ts>/ where slug = "myvault".
# Restore --vault vaultB --from <ts> should find the dir (same slug) but refuse
# because manifest vault= is vault A, not vault B.
T7E_TMPL="$TMP/t7e-tmpl"; make_template "$T7E_TMPL" "1.0.0"
T7E_PARENT_A="$TMP/t7e-parent-a"; mkdir -p "$T7E_PARENT_A"
T7E_PARENT_B="$TMP/t7e-parent-b"; mkdir -p "$T7E_PARENT_B"
T7E_VAULT_A="$T7E_PARENT_A/myvault"
T7E_VAULT_B="$T7E_PARENT_B/myvault"
make_luna_vault "$T7E_VAULT_A" "0.9.0" "$T7E_TMPL"
make_luna_vault "$T7E_VAULT_B" "0.9.0" "$T7E_TMPL"
printf 'STALE\n' > "$T7E_VAULT_A/scripts/hooks/check-commit-msg.sh"

# Apply to vault A (creates backup under slug 'myvault')
t7e_apply_out=$(run_engine apply --template-dir "$T7E_TMPL" --vault "$T7E_VAULT_A" 2>&1) || true
t7e_backup=$(printf '%s\n' "$t7e_apply_out" | grep '^BACKUP	' | cut -f2)
if [ -z "$t7e_backup" ]; then
    fail "T7-e: backup created for vault A" "apply out: $t7e_apply_out"
fi

# Try to restore with --vault pointing to vault B using vault A's --from ts.
# Vault B has the same slug ('myvault') so the path exists, but the manifest
# vault= is vault A's canonical path -> guard should refuse (exit 2).
t7e_ts=$(basename "$t7e_backup")
t7e_mismatch_rc=0
t7e_mismatch_out=$(run_engine restore --vault "$T7E_VAULT_B" --from "$t7e_ts" \
    --template-dir "$T7E_TMPL" 2>&1) || t7e_mismatch_rc=$?
assert_eq "T7-e: restore mismatch exits 2" "2" "$t7e_mismatch_rc"
case "$t7e_mismatch_out" in
    *"mismatch"*|*"vault"*) pass "T7-e: restore mismatch prints error about mismatch" ;;
    *) fail "T7-e: restore mismatch prints error about mismatch" "got: $t7e_mismatch_out" ;;
esac

# T7-f: --list lists only matching backups
# vault A has a backup, vault B (same slug, different parent) should show 0
t7f_list_out=$(run_engine restore --vault "$T7E_VAULT_A" --list \
    --template-dir "$T7E_TMPL" 2>&1)
t7f_rc=$?
assert_eq "T7-f: --list exits 0" "0" "$t7f_rc"
case "$t7f_list_out" in
    *"$t7e_ts"*) pass "T7-f: --list shows vault A backup" ;;
    *) fail "T7-f: --list shows vault A backup" "got: $t7f_list_out" ;;
esac

# --list for vault B should show none (same slug dir, different canonical vault)
t7f_list_b=$(run_engine restore --vault "$T7E_VAULT_B" --list \
    --template-dir "$T7E_TMPL" 2>&1)
case "$t7f_list_b" in
    *"$t7e_ts"*) fail "T7-f: --list for vault B does NOT show vault A backup" "got: $t7f_list_b" ;;
    *) pass "T7-f: --list for vault B does not show vault A backup" ;;
esac

# ===========================================================================
# Task 8 — Idempotent-recovery test (NON-git fixture)
# ===========================================================================

T8_TMPL="$TMP/t8-tmpl"; make_template "$T8_TMPL" "0.9.0"
T8_VAULT="$TMP/t8-vault"
make_conflict_vault "$T8_VAULT" "$T8_TMPL"
# T8_TMPL now has version=1.0.0, _CLAUDE.md=THEIRS

# First apply -> CONFLICT
t8_apply1_rc=0
t8_apply1_out=$(run_engine apply --template-dir "$T8_TMPL" --vault "$T8_VAULT" 2>&1) || t8_apply1_rc=$?
assert_eq "T8: first apply exits 1 (CONFLICT)" "1" "$t8_apply1_rc"
if printf '%s\n' "$t8_apply1_out" | grep -q "^CONFLICT	"; then
    pass "T8: first apply emits CONFLICT"
else
    fail "T8: first apply emits CONFLICT" "got: $t8_apply1_out"
fi
t8_backup1=$(printf '%s\n' "$t8_apply1_out" | grep '^BACKUP	' | cut -f2)

# Hand-resolve: write _CLAUDE.md = theirs (the template version), delete sidecar
cp "$T8_TMPL/_CLAUDE.md" "$T8_VAULT/_CLAUDE.md"
rm -f "$T8_VAULT/_CLAUDE.md.template-merge"

# Second apply -> OK exit 0 + stamp == template
t8_apply2_out=$(run_engine apply --template-dir "$T8_TMPL" --vault "$T8_VAULT" 2>&1)
t8_apply2_rc=$?
assert_eq "T8: second apply exits 0 (OK)" "0" "$t8_apply2_rc"
if printf '%s\n' "$t8_apply2_out" | grep -q "^OK	"; then
    pass "T8: second apply emits OK"
else
    fail "T8: second apply emits OK" "got: $t8_apply2_out"
fi
t8_backup2=$(printf '%s\n' "$t8_apply2_out" | grep '^BACKUP	' | cut -f2)

t8_stamp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' \
    "$T8_VAULT/.vault-template.json" 2>/dev/null || true)
assert_eq "T8: stamp == template version after second apply" "1.0.0" "$t8_stamp"

# Exactly TWO distinct backup dirs created for this vault (one per apply)
t8_slug=$(basename "$T8_VAULT" | sed 's/[^A-Za-z0-9._-]/_/g')
t8_backup_base="${THOME}/.claude/luna-upgrade-backups/$t8_slug"

if [ -n "$t8_backup1" ] && [ -n "$t8_backup2" ] && [ "$t8_backup1" != "$t8_backup2" ]; then
    pass "T8: two distinct backup dirs created"
else
    fail "T8: two distinct backup dirs created" "backup1=$t8_backup1 backup2=$t8_backup2"
fi

# Count total backup dirs under the slug (must be exactly 2)
t8_backup_count=0
for bdir in "${t8_backup_base}"/*/; do
    [ -d "$bdir" ] && t8_backup_count=$((t8_backup_count + 1))
done
assert_eq "T8: exactly 2 backup dirs exist for this vault's slug" "2" "$t8_backup_count"

# T8-uniquifier: deterministically prove the same-second -2 suffix fires.
#
# Strategy: use the LUNA_UPGRADE_BACKUP_TS env var (testability hook added to
# backup_vault) to pin the timestamp, then:
#   1. Pre-create <base>/<slug>/<fixed-ts>/ so the slot is already occupied.
#   2. Run apply with that same fixed ts → backup_vault sees the collision and
#      must produce <base>/<slug>/<fixed-ts>-2/.
# This is fully deterministic — no race against the system clock.
T8_COLL_TMPL="$TMP/t8-coll-tmpl"; make_template "$T8_COLL_TMPL" "1.0.0"
T8_COLL_VAULT="$TMP/t8-coll-vault"
make_luna_vault "$T8_COLL_VAULT" "0.9.0" "$T8_COLL_TMPL"
printf 'STALE HOOK\n' > "$T8_COLL_VAULT/scripts/hooks/check-commit-msg.sh"

T8_COLL_SLUG="$(basename "$T8_COLL_VAULT" | sed 's/[^A-Za-z0-9._-]/_/g')"
T8_COLL_BASE="${THOME}/.claude/luna-upgrade-backups/${T8_COLL_SLUG}"
T8_FIXED_TS="20260101T000000Z"
T8_FIRST_DEST="${T8_COLL_BASE}/${T8_FIXED_TS}"
T8_SECOND_DEST="${T8_FIRST_DEST}-2"

# Pre-create the primary slot so the next apply is forced to use the -2 suffix.
mkdir -p "$T8_FIRST_DEST"

t8_coll_out=$(LUNA_UPGRADE_BACKUP_TS="$T8_FIXED_TS" run_engine apply \
    --template-dir "$T8_COLL_TMPL" --vault "$T8_COLL_VAULT" 2>&1) || true
t8_coll_backup=$(printf '%s\n' "$t8_coll_out" | grep '^BACKUP	' | head -1 | cut -f2)

# The backup dest must end in -2 (uniquifier suffix)
if [ "$(basename "$t8_coll_backup")" = "${T8_FIXED_TS}-2" ] && [ -d "$T8_SECOND_DEST" ]; then
    pass "T8-uniquifier: -2 suffix created on same-ts collision"
else
    fail "T8-uniquifier: -2 suffix created on same-ts collision" \
        "expected $T8_SECOND_DEST; backup line: '$t8_coll_backup'"
fi

# restore with no --from selects the SECOND (newest-matching) backup
# Capture pre-second-apply state of a modified file to know what "second" backup has
# (Before second apply, we hand-resolved _CLAUDE.md to theirs — after second apply it's also theirs;
#  the stamp is the key: first backup has 0.9.0, second backup has the just-applied version)
# After second apply, the stamp is 1.0.0. Second backup captured pre-second-apply state.
# First backup captured pre-first-apply state (stamp=0.9.0).
# So restore (selects second backup = newest) should give us pre-second-apply stamp.
t8_restore_rc=0
run_engine restore --vault "$T8_VAULT" --template-dir "$T8_TMPL" >/dev/null 2>&1 || t8_restore_rc=$?
assert_eq "T8: restore exits 0" "0" "$t8_restore_rc"

# The restored state should be from the SECOND backup (pre-second-apply).
# After first apply (conflict): stamp was NOT written (engine exits 1 on conflict).
# After restore of second backup: stamp should be whatever was pre-second-apply.
# Pre-second-apply: stamp still 0.9.0 (first apply failed to stamp).
t8_restored_stamp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' \
    "$T8_VAULT/.vault-template.json" 2>/dev/null || true)
assert_eq "T8: restore selects newest backup (pre-second-apply stamp = 0.9.0)" "0.9.0" "$t8_restored_stamp"

# ===========================================================================
# C1 regression guard: manifest header parse must survive a 't' in the vault path.
# BSD sed treated [^\t] as "not backslash or t", silently truncating /tmp/... paths.
# This test would have failed under the old sed-based parser on BSD/macOS.
# ===========================================================================
C1_TMPL="$TMP/c1-tmpl"; make_template "$C1_TMPL" "1.0.0"
# Vault path deliberately contains 't' characters at multiple positions.
# /tmp/ prefix + "test-vault-with-t" = dense 't' coverage.
C1_PARENT="$TMP/tmp"; mkdir -p "$C1_PARENT"
C1_VAULT="$C1_PARENT/test-vault-with-t"
make_luna_vault "$C1_VAULT" "0.9.0" "$C1_TMPL"

c1_apply_out=$(run_engine apply --template-dir "$C1_TMPL" --vault "$C1_VAULT" 2>&1) || true
c1_backup_dest=$(printf '%s\n' "$c1_apply_out" | grep '^BACKUP	' | head -1 | cut -f2)

if [ -n "$c1_backup_dest" ] && [ -f "$c1_backup_dest/manifest.tsv" ]; then
    c1_hdr=$(head -1 "$c1_backup_dest/manifest.tsv")
    # The parsed vault= field must equal the full path — not truncated at 't'
    case "$c1_hdr" in
        "# vault=${C1_VAULT}"*)
            pass "C1-t-in-path: manifest header vault field not truncated at 't'"
            ;;
        *)
            fail "C1-t-in-path: manifest header vault field not truncated at 't'" \
                "header='$c1_hdr' expected vault='$C1_VAULT'"
            ;;
    esac

    # Also exercise restore --list to exercise parse_manifest_field()
    c1_list_out=$(run_engine restore --vault "$C1_VAULT" --template-dir "$C1_TMPL" --list 2>&1) || true
    case "$c1_list_out" in
        *"$C1_VAULT"*|*"test-vault-with-t"*) ;;  # found vault-related output — skip, list shows ts
        *)  ;;  # --list shows ts->version columns, not vault; success if it exits 0
    esac
    c1_list_rc=0
    run_engine restore --vault "$C1_VAULT" --template-dir "$C1_TMPL" --list >/dev/null 2>&1 || c1_list_rc=$?
    assert_eq "C1-t-in-path: restore --list exits 0 (vault with 't' found)" "0" "$c1_list_rc"
else
    fail "C1-t-in-path: apply produced backup for vault path with 't'" \
        "apply out: $c1_apply_out"
fi

# ===========================================================================
# Safety assertion: no files leaked to real HOME's backup dir
# ===========================================================================
# --- Positive assertion: backups MUST have landed under THOME, not real HOME ---
# If the HOME redirect didn't take effect, none of the apply runs would have
# written backups under THOME at all.  Assert at least one backup dir exists.
thome_backup_base="${THOME}/.claude/luna-upgrade-backups"
if [ -d "$thome_backup_base" ]; then
    _thome_count=0
    for _tbd in "$thome_backup_base"/*/; do
        [ -d "$_tbd" ] && _thome_count=$((_thome_count + 1))
    done
    if [ "$_thome_count" -gt 0 ]; then
        pass "SAFETY: backups landed under hermetic THOME ($thome_backup_base; count=$_thome_count)"
    else
        fail "SAFETY: backups landed under hermetic THOME" \
            "dir exists but is empty — HOME redirect may not have taken effect"
    fi
else
    fail "SAFETY: backups landed under hermetic THOME" \
        "no backup dir at $thome_backup_base — HOME redirect did not take effect"
fi

# --- Negative assertion: real HOME must not have gained new backup slugs ---
# Compare post-suite snapshot against the pre-suite snapshot captured at suite start.
# This does not rely on a hardcoded slug list that can drift.
if [ -d "$REAL_HOME_BACKUP_DIR" ]; then
    _new_slugs=""
    for _post_slug in "$REAL_HOME_BACKUP_DIR"/*/; do
        [ -d "$_post_slug" ] || continue
        _ps_name="$(basename "$_post_slug")"
        # Check if this slug was in the pre-suite snapshot (newline-separated string).
        # Use printf+grep so there's no glob expansion in the pattern.
        if printf '%s\n' "$_real_home_pre_slugs" | grep -qxF "$_ps_name"; then
            : # pre-existed — OK
        else
            _new_slugs="${_new_slugs:+$_new_slugs }$_ps_name"
            echo "SAFETY FAIL: backup slug appeared in real HOME during suite: $REAL_HOME_BACKUP_DIR/$_ps_name" >&2
        fi
    done
    if [ -z "$_new_slugs" ]; then
        pass "SAFETY: real HOME backup dir gained no new slugs during suite"
    else
        fail "SAFETY: real HOME backup dir gained no new slugs during suite" \
            "new: $_new_slugs"
    fi
else
    pass "SAFETY: real HOME backup dir does not exist (nothing could have leaked)"
fi

# ===========================================================================
# C1 failure-injection: backup blocked by pre-existing file at dest parent path.
# Pre-create $THOME/.claude/luna-upgrade-backups/<slug> as a REGULAR FILE so
# that mkdir -p "$dest" under it fails on every platform.
# Assert: apply exits non-zero, NO upgrade ran (vault stamp UNCHANGED), no BACKUP/OK line.
# ===========================================================================

C1_INJ_TMPL="$TMP/c1-inj-tmpl"; make_template "$C1_INJ_TMPL" "1.0.0"
C1_INJ_VAULT="$TMP/c1-inj-vault"
make_luna_vault "$C1_INJ_VAULT" "0.9.0" "$C1_INJ_TMPL"
printf 'STALE HOOK\n' > "$C1_INJ_VAULT/scripts/hooks/check-commit-msg.sh"

# Capture pre-apply stamp version
c1_inj_pre_stamp=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' \
    "$C1_INJ_VAULT/.vault-template.json" 2>/dev/null || true)

# Block the backup dir: pre-create the slug path as a regular FILE
c1_inj_slug="$(basename "$C1_INJ_VAULT" | sed 's/[^A-Za-z0-9._-]/_/g')"
c1_inj_block_parent="${THOME}/.claude/luna-upgrade-backups"
mkdir -p "$c1_inj_block_parent"
# Write a regular file at the slug path so mkdir -p <slug>/<ts>/ fails
printf 'BLOCKING FILE\n' > "$c1_inj_block_parent/$c1_inj_slug"

c1_inj_rc=0
c1_inj_out=$(run_engine apply --template-dir "$C1_INJ_TMPL" --vault "$C1_INJ_VAULT" 2>&1) \
    || c1_inj_rc=$?

# Apply must exit non-zero
if [ "$c1_inj_rc" -ne 0 ]; then
    pass "C1-injection: apply exits non-zero when backup fails"
else
    fail "C1-injection: apply exits non-zero when backup fails" \
        "rc=0; out: $c1_inj_out"
fi

# No OK or BACKUP success line
if printf '%s\n' "$c1_inj_out" | grep -q "^OK	"; then
    fail "C1-injection: no OK line emitted when backup fails" "got: $c1_inj_out"
else
    pass "C1-injection: no OK line emitted when backup fails"
fi

# Vault stamp MUST be unchanged (no upgrade ran)
c1_inj_post_stamp=$(python3 -c \
    'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' \
    "$C1_INJ_VAULT/.vault-template.json" 2>/dev/null || true)
assert_eq "C1-injection: vault stamp unchanged after backup failure" \
    "$c1_inj_pre_stamp" "$c1_inj_post_stamp"

# No false BACKUP line
if printf '%s\n' "$c1_inj_out" | grep -q "^BACKUP	"; then
    fail "C1-injection: no false BACKUP line when backup fails" "got: $c1_inj_out"
else
    pass "C1-injection: no false BACKUP line when backup fails"
fi

# Remove the blocking file so the slug dir can be created by later tests with same slug
# (cleanup: turn it back into a dir for any follow-up)
rm -f "$c1_inj_block_parent/$c1_inj_slug"

# ===========================================================================
# C3 failure-injection: restore with a missing existing-class backup file.
# After a successful apply+backup, DELETE one 'existing' file from the backup dir,
# then run restore. Assert: exits non-zero, no RESTORED line, WARNING printed.
# ===========================================================================

C3_INJ_TMPL="$TMP/c3-inj-tmpl"; make_template "$C3_INJ_TMPL" "1.0.0"
C3_INJ_VAULT="$TMP/c3-inj-vault"
make_luna_vault "$C3_INJ_VAULT" "0.9.0" "$C3_INJ_TMPL"
printf 'STALE HOOK\n' > "$C3_INJ_VAULT/scripts/hooks/check-commit-msg.sh"

# Apply to create a backup
c3_apply_rc=0
c3_apply_out=$(run_engine apply --template-dir "$C3_INJ_TMPL" --vault "$C3_INJ_VAULT" 2>&1) \
    || c3_apply_rc=$?
assert_eq "C3-injection: apply succeeds (setup)" "0" "$c3_apply_rc"

c3_backup_dest=$(printf '%s\n' "$c3_apply_out" | grep '^BACKUP	' | head -1 | cut -f2)
if [ -z "$c3_backup_dest" ] || [ ! -d "$c3_backup_dest" ]; then
    fail "C3-injection: backup dir created (setup)" "apply out: $c3_apply_out"
fi

# Find an 'existing' entry in the manifest and delete it from the backup dir
c3_existing_rel=$(grep "^existing	" "$c3_backup_dest/manifest.tsv" | grep -v "^existing	.vault-template.base$" | head -1 | cut -f2)
if [ -n "$c3_existing_rel" ] && [ -f "$c3_backup_dest/$c3_existing_rel" ]; then
    rm -f "$c3_backup_dest/$c3_existing_rel"
    pass "C3-injection: deleted existing-class file from backup (setup): $c3_existing_rel"
else
    fail "C3-injection: found deletable existing-class file in backup (setup)" \
        "existing_rel='$c3_existing_rel'; backup: $c3_backup_dest"
fi

# Now run restore — should fail because the backup source is missing
c3_restore_rc=0
c3_restore_out=$(run_engine restore --template-dir "$C3_INJ_TMPL" --vault "$C3_INJ_VAULT" 2>&1) \
    || c3_restore_rc=$?

# Must exit non-zero
if [ "$c3_restore_rc" -ne 0 ]; then
    pass "C3-injection: restore exits non-zero on missing backup source"
else
    fail "C3-injection: restore exits non-zero on missing backup source" \
        "rc=0; out: $c3_restore_out"
fi

# Must NOT print RESTORED
if printf '%s\n' "$c3_restore_out" | grep -q "^RESTORED	"; then
    fail "C3-injection: no false RESTORED line on missing backup source" \
        "got: $c3_restore_out"
else
    pass "C3-injection: no false RESTORED line on missing backup source"
fi

# Must print a WARNING about the missing source
case "$c3_restore_out" in
    *"WARNING"*|*"missing"*|*"backup source"*)
        pass "C3-injection: WARNING about missing source printed" ;;
    *)
        fail "C3-injection: WARNING about missing source printed" \
            "got: $c3_restore_out" ;;
esac

# ===========================================================================
# I4: best-effort sweep continuation — after-error vault has a concrete state field
# (strengthens the existing continuation test to verify the field, not just presence).
# ===========================================================================

# The after-vault uses T_SW (the real template), so it gets a real dry-run result.
# We already ran corrupt_out above; re-check the after-vault line has a non-empty state col.
after_vault_line=$(printf '%s\n' "$corrupt_out" | grep "$SW_CORRUPT_AFTER" | head -1)
after_state=$(printf '%s\n' "$after_vault_line" | cut -f1)
if [ -n "$after_state" ]; then
    pass "I4: after-error vault has non-empty state field in sweep output (state='$after_state')"
else
    fail "I4: after-error vault has non-empty state field in sweep output" \
        "line: $after_vault_line"
fi

# ===========================================================================
# I2: malformed registry JSON → warning on stderr + roots-scan vaults still found.
# ===========================================================================

I2_TMPL="$TMP/i2-tmpl"; make_template "$I2_TMPL" "1.0.0"
I2_ROOTS="$TMP/i2-roots"; mkdir -p "$I2_ROOTS"
I2_VAULT="$I2_ROOTS/i2-vault"
make_luna_vault "$I2_VAULT" "1.0.0" "$I2_TMPL"

# Malformed JSON that python3 json.load will reject
I2_REG="$TMP/i2-malformed-reg.json"
printf 'NOT VALID JSON { broken\n' > "$I2_REG"

i2_out=$(run_engine sweep --porcelain \
    --template-dir "$I2_TMPL" \
    --roots "$I2_ROOTS" \
    --registry "$I2_REG" 2>&1)
i2_rc=$?

# Sweep must exit 0 (warning only, not fatal)
assert_eq "I2-malformed-registry: sweep exits 0" "0" "$i2_rc"

# Must print a WARNING mentioning the registry path
case "$i2_out" in
    *"WARNING"*|*"registry"*|*"could not parse"*)
        pass "I2-malformed-registry: WARNING printed for bad registry" ;;
    *)
        fail "I2-malformed-registry: WARNING printed for bad registry" "got: $i2_out" ;;
esac

# Roots-scan vault must still be discovered despite registry failure
case "$i2_out" in
    *"$I2_VAULT"*)
        pass "I2-malformed-registry: roots-scan vault still discovered after registry warning" ;;
    *)
        fail "I2-malformed-registry: roots-scan vault still discovered after registry warning" \
            "got: $i2_out" ;;
esac

# ===========================================================================
# I3: all-errored sweep warning.
# Use the existing SW_ERR_ROOTS fixture (SW_CORRUPT only; remove SW_CORRUPT_AFTER
# by running sweep on a roots dir that has ONLY the error vault — so sweep_luna_count
# == sweep_error_count == 1 and the warning fires).
# ===========================================================================

# Build a roots dir with exactly one luna-family vault whose upgrade.sh always exits 2.
I3_ERR_ROOTS="$TMP/i3-err-roots"; mkdir -p "$I3_ERR_ROOTS"
I3_CORRUPT="$I3_ERR_ROOTS/only-corrupt-vault"
mkdir -p "$I3_CORRUPT"
stamp_vault "$I3_CORRUPT" "0.9.0"
mkdir -p "$I3_CORRUPT/.obsidian"

I3_REG="$TMP/i3-err-reg.json"
printf '{"vaults":{}}\n' > "$I3_REG"

# T_SW_ERR has a stub upgrade.sh that always exits 2 — reuse it.
i3_out=$(run_engine sweep --porcelain \
    --template-dir "$T_SW_ERR" \
    --roots "$I3_ERR_ROOTS" \
    --registry "$I3_REG" 2>&1)
i3_rc=$?

# Sweep must exit 0 (advisory only)
assert_eq "I3-all-errored: sweep exits 0" "0" "$i3_rc"

# Warning must appear on stderr (captured via 2>&1)
case "$i3_out" in
    *"WARNING"*"all"*"error"*|*"WARNING"*"returned error"*)
        pass "I3-all-errored: all-errored warning printed" ;;
    *)
        fail "I3-all-errored: all-errored warning printed" "got: $i3_out" ;;
esac

# The corrupt vault itself must still appear in porcelain output with state=error
i3_corrupt_line=$(printf '%s\n' "$i3_out" | grep "$I3_CORRUPT" | head -1)
case "$i3_corrupt_line" in
    error*) pass "I3-all-errored: corrupt vault line has state=error" ;;
    *) fail "I3-all-errored: corrupt vault line has state=error" "got: $i3_corrupt_line" ;;
esac

# ===========================================================================
echo
if [ "$FAILED" -eq 0 ]; then
    echo "All luna-upgrade-all tests passed."
else
    echo "$FAILED test(s) failed."
    exit 1
fi
