#!/usr/bin/env bash
# test-reconcile-enabled-plugins.sh — hermetic tests for the lean plugin-set
# reconciler (HIMMEL-1032). No global state: every case builds its own fixture
# template + settings.json in a temp dir and drives the real script with
# --settings/--template. No plugin is installed, no ~/.claude touched.
#
# reconcile-enabled-plugins.ps1 carries the same WHITELIST + local-override
# logic — that twin is NOT covered here; keep both in lockstep (sanity-check
# with `pwsh reconcile-enabled-plugins.ps1 -DryRun -Settings <fixture>`).
#
# Covers:
#   1. Drift force-off       — a template-`false` plugin left `true` -> `false`.
#   2. Template-`true` kept   — a floor plugin stays enabled.
#   3. Whitelist catch-all    — a live-enabled spec ABSENT from the template
#                               (ad-hoc /plugin drift) -> forced `false`.
#   4. Local `true` override  — settings.local.json keeps an off-template plugin.
#   5. Local `false` override — settings.local.json disables a floor plugin.
#   6. Idempotent             — a second run reports no drift + no write.
#   7. --dry-run              — reports the plan, writes nothing.
#   8. Invalid settings JSON  — exits non-zero, leaves the file untouched.
#   9. Missing settings file  — exits 0 (nothing to reconcile).
#  10. HIMMEL-2324            — a link pre-planted at the OLD predictable temp
#                               path ("$SETTINGS.reconcile.tmp") is not written
#                               through; the patch still lands via mktemp.
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# plant_attack_link <path-to-plant> <target-file> — simulates an attacker with
# write access to the settings dir pre-planting something at a PREDICTABLE
# temp path before the script runs (HIMMEL-2324). Prefers a real symlink (it
# proves both attack vectors: content written through it, AND `mv` replacing
# the destination with the symlink itself) but falls back to a hardlink (still
# proves the write-through vector) when a symlink can't be created — this
# Windows sandbox has no Developer Mode/admin, so `ln -s` here silently copies
# instead of linking (`[ -L ]` catches that) and `New-Item -ItemType
# SymbolicLink` refuses with "Administrator privilege required".
# file_id <path> — portable inode identity (GNU `stat -c`, falling back to
# BSD/macOS `stat -f`; CodeRabbit round 4, anchored here). The GNU-only form
# is only reached on the hardlink fallback (real symlinks already return
# earlier on macOS/Linux), but the caller HARD-FAILS when it can't verify a
# link, so a BSD host reaching this path would abort loudly rather than lose
# coverage silently — still worth making portable. Empty output (both
# variants fail) preserves the existing empty-result-still-aborts fallback.
file_id() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null || true
}
plant_attack_link() {
  local link="$1" target="$2" li ti
  rm -f "$link"
  if ln -s "$target" "$link" 2>/dev/null && [ -L "$link" ]; then return 0; fi
  rm -f "$link"
  if command -v cygpath >/dev/null 2>&1; then
    MSYS_NO_PATHCONV=1 cmd.exe /c mklink /H "$(cygpath -w "$link")" "$(cygpath -w "$target")" >/dev/null 2>&1 || true
    li="$(file_id "$link")"; ti="$(file_id "$target")"
    if [ -n "$li" ] && [ "$li" = "$ti" ]; then return 0; fi
    rm -f "$link"
  fi
  ln "$target" "$link" 2>/dev/null || true
  li="$(file_id "$link")"; ti="$(file_id "$target")"
  if [ -n "$li" ] && [ "$li" = "$ti" ]; then return 0; fi
  # CR round 2 (codex-1): a security test that cannot tell "attack blocked"
  # from "attack never attempted" is worse than no test. Hard-fail here — the
  # chokepoint every caller routes through — instead of returning quietly: if
  # none of the three methods actually planted a link (verified as a real
  # symlink, or the same inode as the target for a hardlink), no caller can
  # proceed unplanted, regardless of whether it checks this function's status.
  echo "FATAL: plant_attack_link: could not plant an attack link at '$link' -- cannot exercise the HIMMEL-2324 case in this environment" >&2
  exit 1
}

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/reconcile-enabled-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Byte-exact "untouched" snapshot/compare — `$(cat)` strips trailing newlines,
# so an EOF-only rewrite would slip past a string compare; cmp is byte-accurate.
snapshot() { cp "$1" "$1.snap"; }
unchanged() { cmp -s "$1" "$1.snap"; }

# A fixed fixture template: floor = keep@mkt (true); demote@mkt (false).
tmpl="$tmp/settings-template.json"
cat > "$tmpl" <<'JSON'
{ "enabledPlugins": { "keep@mkt": true, "demote@mkt": false } }
JSON

# jq helper: value of a key in an enabledPlugins file ("absent" if missing).
# NOT `// "absent"` — jq's `//` treats a literal `false` as empty and would
# report a disabled plugin as absent; test membership explicitly instead.
val() { jq -r --arg k "$2" 'if (.enabledPlugins | has($k)) then (.enabledPlugins[$k] | tostring) else "absent" end' "$1"; }

# ── 1 + 2 + 3: whitelist force-off, floor kept, unknown caught ───────────────
s="$tmp/settings.json"
cat > "$s" <<'JSON'
{ "other": 1, "enabledPlugins": { "keep@mkt": true, "demote@mkt": true, "adhoc@mkt": true } }
JSON
bash "$script" --settings "$s" --template "$tmpl" >/dev/null
[ "$(val "$s" keep@mkt)"   = "true"  ] || fail "template-true 'keep' should stay true"
[ "$(val "$s" demote@mkt)" = "false" ] || fail "template-false 'demote' should be forced false"
[ "$(val "$s" adhoc@mkt)"  = "false" ] || fail "unknown live-enabled 'adhoc' should be forced false (whitelist)"
[ "$(jq -r '.other' "$s")" = "1" ] || fail "reconcile must not disturb other settings keys"
echo "ok: whitelist — floor kept, template-false + unknown forced off, other keys intact"

# ── 6: idempotent — second run makes no change ───────────────────────────────
before=$(cat "$s")
out=$(bash "$script" --settings "$s" --template "$tmpl")
[ "$(cat "$s")" = "$before" ] || fail "second run must not mutate the file"
grepq "$out" "no drift" || fail "second run should report 'no drift'"
echo "ok: idempotent — re-run is a no-op reporting no drift"

# ── 4 + 5: settings.local.json overrides win both ways ───────────────────────
s2="$tmp/settings.json"   # reuse dir; write a sibling local file
rm -f "$s2"; cat > "$s2" <<'JSON'
{ "enabledPlugins": { "keep@mkt": true, "demote@mkt": true } }
JSON
cat > "$tmp/settings.local.json" <<'JSON'
{ "enabledPlugins": { "adhoc@mkt": true, "keep@mkt": false } }
JSON
bash "$script" --settings "$s2" --template "$tmpl" >/dev/null
[ "$(val "$s2" adhoc@mkt)" = "true"  ] || fail "local 'true' override should keep off-template plugin enabled"
[ "$(val "$s2" keep@mkt)"  = "false" ] || fail "local 'false' override should disable a floor plugin"
[ "$(val "$s2" demote@mkt)" = "false" ] || fail "template-false still forced off under local overrides"
rm -f "$tmp/settings.local.json"
echo "ok: settings.local.json overrides win in both directions"

# ── 4b: invalid settings.local.json fails loud (never silently drops override) ─
s2b="$tmp/settings.json"; rm -f "$s2b"
cat > "$s2b" <<'JSON'
{ "enabledPlugins": { "keep@mkt": true, "demote@mkt": true } }
JSON
printf '{ bad json' > "$tmp/settings.local.json"; snapshot "$s2b"
rc=0; out=$(bash "$script" --settings "$s2b" --template "$tmpl" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "invalid settings.local.json should exit non-zero (override must not be silently dropped)"
# Assert the SPECIFIC diagnostic, not just a non-zero exit — otherwise any
# unrelated failure would satisfy this case.
grepq "$out" -i "not valid JSON" || fail "invalid local should report a 'not valid JSON' diagnostic (got: $out)"
unchanged "$s2b" || fail "settings.json must be untouched when local override is invalid"
rm -f "$tmp/settings.local.json"
echo "ok: invalid settings.local.json fails loud, base settings untouched"

# ── 4c: settings.local.json is refused as a reconcile TARGET (never rewrite the
#        protected override input) — via --settings AND via --scope local ──────
rc=0; out=$(bash "$script" --settings "$tmp/settings.local.json" --template "$tmpl" 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "targeting settings.local.json should exit 2 (protected override input), got $rc"
grepq "$out" -i "protected override" || fail "refusal should name the protected override input"
rc=0; bash "$script" --scope local --template "$tmpl" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "--scope local should be rejected (exit 2), got $rc"
# Case variant (Windows FS is case-insensitive) must also be refused.
rc=0; bash "$script" --settings "$tmp/SETTINGS.LOCAL.JSON" --template "$tmpl" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "SETTINGS.LOCAL.JSON (case variant) should be refused (exit 2), got $rc"
echo "ok: settings.local.json refused as target (case-insensitive); --scope local rejected"

# ── 4d: parseable local with a NON-OBJECT enabledPlugins is refused ──────────
s4d="$tmp/settings.json"; rm -f "$s4d"
cat > "$s4d" <<'JSON'
{ "enabledPlugins": { "keep@mkt": true } }
JSON
printf '{ "enabledPlugins": "not-an-object" }' > "$tmp/settings.local.json"; snapshot "$s4d"
rc=0; out=$(bash "$script" --settings "$s4d" --template "$tmpl" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "non-object local enabledPlugins should exit non-zero"
grepq "$out" -i "non-object" || fail "should report a non-object enabledPlugins diagnostic (got: $out)"
unchanged "$s4d" || fail "settings.json untouched when local shape is invalid"
rm -f "$tmp/settings.local.json"
echo "ok: non-object settings.local.json enabledPlugins refused"

# ── 4e: a NON-OBJECT live enabledPlugins is refused ──────────────────────────
s4e="$tmp/settings.json"; rm -f "$s4e"
printf '{ "enabledPlugins": ["a","b"] }' > "$s4e"
rc=0; out=$(bash "$script" --settings "$s4e" --template "$tmpl" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "non-object live enabledPlugins should exit non-zero"
grepq "$out" -i "non-object" || fail "should report a non-object diagnostic for live settings (got: $out)"
echo "ok: non-object live enabledPlugins refused"

# ── 4f: key-order-insensitive "unchanged" — a map already at the floor but with
#        keys in a different order than the template emits must NOT be rewritten
#        (a plain string compare would see a spurious change). ────────────────
s4f="$tmp/settings.json"; rm -f "$s4f"
printf '{ "enabledPlugins": { "demote@mkt": false, "keep@mkt": true } }' > "$s4f"
snapshot "$s4f"
out=$(bash "$script" --settings "$s4f" --template "$tmpl")
grepq "$out" -i "unchanged" || fail "reordered-but-equal map should report unchanged (got: $out)"
unchanged "$s4f" || fail "reordered-but-equal map must not be rewritten"
echo "ok: key-order-insensitive unchanged detection"

# ── 4g: a NON-BOOLEAN enabledPlugins value (string "false") is refused ───────
s4g="$tmp/settings.json"; rm -f "$s4g"
printf '{ "enabledPlugins": { "keep@mkt": "false" } }' > "$s4g"; snapshot "$s4g"
rc=0; out=$(bash "$script" --settings "$s4g" --template "$tmpl" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "non-boolean enabledPlugins value should exit non-zero"
grepq "$out" -i "not a boolean" || fail "should report a non-boolean value diagnostic (got: $out)"
unchanged "$s4g" || fail "settings.json must be untouched when a value is non-boolean"
echo "ok: non-boolean enabledPlugins value refused (settings untouched)"

# ── 7: --dry-run writes nothing ──────────────────────────────────────────────
s3="$tmp/settings.json"; rm -f "$s3"
cat > "$s3" <<'JSON'
{ "enabledPlugins": { "demote@mkt": true } }
JSON
snapshot "$s3"
out=$(bash "$script" --dry-run --settings "$s3" --template "$tmpl")
unchanged "$s3" || fail "--dry-run must not write"
grepq "$out" "DRY:" || fail "--dry-run should print a DRY line"
echo "ok: --dry-run reports the plan, writes nothing"

# ── 8: invalid settings JSON exits non-zero, file untouched ──────────────────
s4="$tmp/settings.json"; printf '{ not json' > "$s4"; snapshot "$s4"
rc=0; bash "$script" --settings "$s4" --template "$tmpl" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "invalid settings JSON should exit non-zero"
unchanged "$s4" || fail "invalid settings file must be left untouched"
echo "ok: invalid settings JSON — non-zero exit, file untouched"

# ── 9: missing settings file exits 0 ─────────────────────────────────────────
rc=0; out=$(bash "$script" --settings "$tmp/nope.json" --template "$tmpl" 2>&1) || rc=$?
[ "$rc" -eq 0 ] || fail "missing settings file should exit 0 (nothing to reconcile), got $rc"
grepq "$out" -i "nothing to reconcile" || fail "missing file should say nothing to reconcile"
echo "ok: missing settings file — exit 0, nothing to reconcile"

# ── 10: HIMMEL-2324 — link pre-planted at the OLD predictable temp path ──────
s10="$tmp/settings.json"; rm -f "$s10"
cat > "$s10" <<'JSON'
{ "enabledPlugins": { "keep@mkt": true, "demote@mkt": true } }
JSON
canary10="$tmp/canary10.txt"
printf 'CANARY-UNCHANGED\n' > "$canary10"
plant_attack_link "$s10.reconcile.tmp" "$canary10"
bash "$script" --settings "$s10" --template "$tmpl" >/dev/null
[ "$(cat "$canary10")" = "CANARY-UNCHANGED" ] || fail "HIMMEL-2324: write landed through the predictable temp path onto the canary file"
[ -f "$s10" ] || fail "HIMMEL-2324: settings.json missing after reconcile"
[ ! -L "$s10" ] || fail "HIMMEL-2324: settings.json ended up as a symlink"
[ "$(val "$s10" demote@mkt)" = "false" ] || fail "HIMMEL-2324: intended patch (demote->false) did not land"
[ "$(val "$s10" keep@mkt)"   = "true"  ] || fail "HIMMEL-2324: intended patch (keep stays true) did not land"
echo "ok: HIMMEL-2324 — pre-planted link at the predictable temp path is not written through"

echo "PASS"
