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
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/reconcile-enabled-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "PASS (skipped)"; exit 0; }

fail() { echo "FAIL: $1" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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
printf '%s' "$out" | grep -q "no drift" || fail "second run should report 'no drift'"
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
printf '{ bad json' > "$tmp/settings.local.json"; snap=$(cat "$s2b")
set +e; out=$(bash "$script" --settings "$s2b" --template "$tmpl" 2>&1); rc=$?; set -e
[ "$rc" -ne 0 ] || fail "invalid settings.local.json should exit non-zero (override must not be silently dropped)"
# Assert the SPECIFIC diagnostic, not just a non-zero exit — otherwise any
# unrelated failure would satisfy this case.
printf '%s' "$out" | grep -qi "not valid JSON" || fail "invalid local should report a 'not valid JSON' diagnostic (got: $out)"
[ "$(cat "$s2b")" = "$snap" ] || fail "settings.json must be untouched when local override is invalid"
rm -f "$tmp/settings.local.json"
echo "ok: invalid settings.local.json fails loud, base settings untouched"

# ── 7: --dry-run writes nothing ──────────────────────────────────────────────
s3="$tmp/settings.json"; rm -f "$s3"
cat > "$s3" <<'JSON'
{ "enabledPlugins": { "demote@mkt": true } }
JSON
snap=$(cat "$s3")
out=$(bash "$script" --dry-run --settings "$s3" --template "$tmpl")
[ "$(cat "$s3")" = "$snap" ] || fail "--dry-run must not write"
printf '%s' "$out" | grep -q "DRY:" || fail "--dry-run should print a DRY line"
echo "ok: --dry-run reports the plan, writes nothing"

# ── 8: invalid settings JSON exits non-zero, file untouched ──────────────────
s4="$tmp/settings.json"; printf '{ not json' > "$s4"; snap=$(cat "$s4")
set +e; bash "$script" --settings "$s4" --template "$tmpl" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] || fail "invalid settings JSON should exit non-zero"
[ "$(cat "$s4")" = "$snap" ] || fail "invalid settings file must be left untouched"
echo "ok: invalid settings JSON — non-zero exit, file untouched"

# ── 9: missing settings file exits 0 ─────────────────────────────────────────
set +e; out=$(bash "$script" --settings "$tmp/nope.json" --template "$tmpl" 2>&1); rc=$?; set -e
[ "$rc" -eq 0 ] || fail "missing settings file should exit 0 (nothing to reconcile), got $rc"
printf '%s' "$out" | grep -qi "nothing to reconcile" || fail "missing file should say nothing to reconcile"
echo "ok: missing settings file — exit 0, nothing to reconcile"

echo "PASS"
