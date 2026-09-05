#!/usr/bin/env bash
# test-wizard-guardrail-consent.sh — hermetic tests for the HIMMEL-2176
# ask-first gate: `himmelctl ensure` can now actually WIRE
# guardrail-block-global (install-engine.js's 'guardrail-block-global' wire
# target, dispatching to guardrail-block.mjs's own `install` verb), but the
# round-3 ruling forbids ever doing so without an explicit, RECORDED
# consent — that item writes the OPERATOR'S GLOBAL ~/.claude/settings.json,
# outside the blast radius of the ordinary per-run --yes consent.
#
# Unlike sibling test-wizard-ensure*.sh suites, this one drives bin.js
# against the REAL scripts/install/manifest.json and the REAL
# scripts/hooks/guardrail-block.mjs (not a synthetic fixture) — the
# ask-first gate IS the behavior under test, and guardrail-block.mjs's own
# install/status contract is exactly what it gates, so faking either would
# test the fake, not the gate. Every case still stays fully hermetic:
# CLAUDE_USER_SETTINGS points every guardrail-block.mjs invocation (probe
# AND install) at a THROWAWAY settings.json — the operator's real
# ~/.claude/settings.json is NEVER read or written by this suite — and
# HIMMELCTL_CACHE_DIR points install-profile.json/state.json at a throwaway
# dir. `--items guardrail-block-global` scopes every ensure run to just this
# one manifest item, so no other real machine state (qmd, hermes, plugins,
# ...) is ever probed.
#
# Covers:
#   a. no recorded consent + non-interactive (even WITH --yes) -> the item
#      is NEVER installed (settings.json stays absent), ensure still exits
#      0 (nothing else to converge), and the output says so honestly
#      ("no recorded consent yet ... staying manual") with the direct-fix
#      command named. THE anti-silent-force-install case.
#   b. recorded consent 'yes' (pre-seeded state.json) + non-interactive +
#      --yes -> installs for real: guardrail-block.mjs actually runs,
#      settings.json ends up wired (verified via guardrail-block.mjs status
#      --json reading mode=global), exit 0.
#   c. recorded consent 'no' (pre-seeded) + non-interactive + --yes ->
#      stays unconverged, settings.json stays absent/unwired, exit 0 (no
#      nag — the operator already decided).
#   d. interactive, no recorded consent, answer 'y' (blank accepts the
#      recommended default) -> prompts ONCE for this item specifically,
#      records consent=yes in state.json, and (fed `--yes` to skip the
#      separate general consolidated offer) installs for real.
#   e. interactive, no recorded consent, answer 'n' -> records consent=no,
#      does NOT install, settings.json stays absent.
#   f. --dry-run + no recorded consent -> never prompts (dry-run must not
#      block on stdin), prints the honest "staying manual" advisory (not
#      the DRY: plan line — nothing was consented to), zero mutation of
#      BOTH settings.json and state.json.
#   g. --dry-run + recorded consent 'yes' (pre-seeded) -> the plan SURFACES
#      the step (a `DRY: <node> .../guardrail-block.mjs install ...` line),
#      zero mutation.

set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

# Hermeticity: guardrail-block.mjs's trust anchor defaults to HIMMEL_REPO
# when set (see its own resolveAnchor()) — an inherited HIMMEL_REPO from the
# LAUNCHING shell (e.g. an operator's dev environment pointing it at a
# primary checkout while this suite runs from a worktree) would bake a
# WRONG anchor path into every hook this suite installs, permanently
# mismatching the worktree's own self-checkout anchor and forcing every
# post-install probe to 'degraded' regardless of anything this gate does
# right. Force self-checkout (empty is falsy in guardrail-block.mjs's own
# `if (envRepo)` check) so every case in this file resolves its anchor from
# wherever THIS checkout's guardrail-block.mjs actually lives.
export HIMMEL_REPO=""

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-guardrail-consent.XXXXXX") || fail "mktemp -d failed"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# write_cache <cache_dir> — a minimal valid Draft-A install-profile.json,
# scope:"user" (guardrail-block-global's ONLY scope — see manifest.json).
write_cache() {
  mkdir -p "$1"
  cat > "$1/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"user","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
}

# write_state <cache_dir> <consent|""> — a state.json carrying ONLY the
# guardrail-block-global override this gate reads/writes. Empty consent ->
# overrides:{} (never asked) — used to prove the gate DERIVES a fresh entry
# just as well as reading a pre-existing one.
write_state() {
  local dir="$1" consent="$2"
  mkdir -p "$dir"
  if [ -n "$consent" ]; then
    jq -n --arg c "$consent" '{schemaVersion:1,harness:"claude",targets:{user:{profile:"core",scope:"user",items:{"guardrail-block-global":{enabled:true,overrides:{consent:$c}}},lastEnsured:null}}}' > "$dir/state.json"
  else
    jq -n '{schemaVersion:1,harness:"claude",targets:{user:{profile:"core",scope:"user",items:{"guardrail-block-global":{enabled:true,overrides:{}}},lastEnsured:null}}}' > "$dir/state.json"
  fi
}

# guardrail_mode <settings_json_path> — 'global'/'project'/'absent' (no file)
# via the REAL guardrail-block.mjs `status --json`.
guardrail_mode() {
  local settings="$1"
  [ -f "$settings" ] || { echo absent; return; }
  CLAUDE_USER_SETTINGS="$(winpath "$settings")" "$node_bin" "$repo_root/scripts/hooks/guardrail-block.mjs" status --json 2>/dev/null | jq -r '.mode // "unknown"'
}

# ── case a: no recorded consent + non-interactive (even with --yes) -> NEVER installs ─
casea_dir="$work/case-a"; write_cache "$casea_dir/cache"
settingsA="$casea_dir/settings.json"
out=$(CLAUDE_USER_SETTINGS="$(winpath "$settingsA")" HIMMELCTL_CACHE_DIR="$(winpath "$casea_dir/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$casea_dir/cache")-luna-config.json" \
      HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" ensure --items guardrail-block-global --yes </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "case a: non-interactive no-consent run should still exit 0 (nothing else to converge) (got rc=$rc): $out"
[ ! -f "$settingsA" ] || fail "case a: settings.json must NOT have been written (anti-silent-force-install) — $(cat "$settingsA" 2>/dev/null)"
grepq "$out" 'no recorded consent yet' || fail "case a: output should say no recorded consent yet (got: $out)"
grepq "$out" 'staying manual' || fail "case a: output should say it is staying manual (got: $out)"
grepq "$out" -F 'guardrail-block.mjs install --node' || fail "case a: output should name the direct-fix command (got: $out)"
echo "ok: case a — no recorded consent + non-interactive (even with --yes) never installs; surfaced honestly"

# ── case b: recorded consent 'yes' + non-interactive + --yes -> installs for real ─
caseb_dir="$work/case-b"; write_cache "$caseb_dir/cache"; write_state "$caseb_dir/cache" yes
settingsB="$caseb_dir/settings.json"
out=$(CLAUDE_USER_SETTINGS="$(winpath "$settingsB")" HIMMELCTL_CACHE_DIR="$(winpath "$caseb_dir/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$caseb_dir/cache")-luna-config.json" \
      HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" ensure --items guardrail-block-global --yes </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "case b: recorded-yes run should converge and exit 0 (got rc=$rc): $out"
[ "$(guardrail_mode "$settingsB")" = global ] || fail "case b: settings.json should now read mode=global (got: $(cat "$settingsB" 2>/dev/null))"
echo "ok: case b — recorded consent 'yes' converges for real (settings.json wired)"

# ── case c: recorded consent 'no' + non-interactive + --yes -> stays unconverged, no nag ─
casec_dir="$work/case-c"; write_cache "$casec_dir/cache"; write_state "$casec_dir/cache" no
settingsC="$casec_dir/settings.json"
out=$(CLAUDE_USER_SETTINGS="$(winpath "$settingsC")" HIMMELCTL_CACHE_DIR="$(winpath "$casec_dir/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$casec_dir/cache")-luna-config.json" \
      HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" ensure --items guardrail-block-global --yes </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "case c: recorded-no run should exit 0 (nothing to converge) (got rc=$rc): $out"
[ ! -f "$settingsC" ] || fail "case c: settings.json must stay absent after a recorded decline — $(cat "$settingsC" 2>/dev/null)"
grepq "$out" 'no recorded consent yet' && fail "case c: a recorded decline must NOT re-surface the no-recorded-consent advisory (got: $out)"
echo "ok: case c — recorded consent 'no' stays unconverged, no repeated nagging"

# ── case d: interactive, no recorded consent, answer 'y' -> records + installs ─
cased_dir="$work/case-d"; write_cache "$cased_dir/cache"
settingsD="$cased_dir/settings.json"
out=$(CLAUDE_USER_SETTINGS="$(winpath "$settingsD")" HIMMELCTL_CACHE_DIR="$(winpath "$cased_dir/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cased_dir/cache")-luna-config.json" \
      HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" ensure --items guardrail-block-global --yes <<<"y" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "case d: interactive accept should converge and exit 0 (got rc=$rc): $out"
grepq "$out" 'Recommended: yes' || fail "case d: should print the recommended-default prompt (got: $out)"
grepq "$out" 'recorded guardrail-block-global consent = yes' || fail "case d: should confirm what was recorded (got: $out)"
[ "$(guardrail_mode "$settingsD")" = global ] || fail "case d: settings.json should now read mode=global (got: $(cat "$settingsD" 2>/dev/null))"
consentD=$(jq -r '.targets.user.items["guardrail-block-global"].overrides.consent' "$cased_dir/cache/state.json")
[ "$consentD" = yes ] || fail "case d: state.json should persist consent=yes (got: $consentD)"
echo "ok: case d — interactive accept (recommended default) records consent + installs"

# ── case e: interactive, no recorded consent, answer 'n' -> records decline, no install ─
casee_dir="$work/case-e"; write_cache "$casee_dir/cache"
settingsE="$casee_dir/settings.json"
out=$(CLAUDE_USER_SETTINGS="$(winpath "$settingsE")" HIMMELCTL_CACHE_DIR="$(winpath "$casee_dir/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$casee_dir/cache")-luna-config.json" \
      HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" ensure --items guardrail-block-global <<<"n" 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "case e: interactive decline should still exit 0 (nothing to converge) (got rc=$rc): $out"
[ ! -f "$settingsE" ] || fail "case e: settings.json must NOT be written after an interactive decline — $(cat "$settingsE" 2>/dev/null)"
consentE=$(jq -r '.targets.user.items["guardrail-block-global"].overrides.consent' "$casee_dir/cache/state.json")
[ "$consentE" = no ] || fail "case e: state.json should persist consent=no (got: $consentE)"
echo "ok: case e — interactive decline records consent=no, never installs"

# ── case f: --dry-run + no recorded consent -> never asks, honest advisory, zero mutation ─
casef_dir="$work/case-f"; write_cache "$casef_dir/cache"
settingsF="$casef_dir/settings.json"
out=$(CLAUDE_USER_SETTINGS="$(winpath "$settingsF")" HIMMELCTL_CACHE_DIR="$(winpath "$casef_dir/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$casef_dir/cache")-luna-config.json" \
      HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" ensure --items guardrail-block-global --dry-run </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "case f: dry-run with no consent should exit 0 (got rc=$rc): $out"
[ ! -f "$settingsF" ] || fail "case f: dry-run must never write settings.json"
[ ! -f "$casef_dir/cache/state.json" ] || fail "case f: dry-run must never write state.json either (zero mutation)"
grepq "$out" 'no recorded consent yet' || fail "case f: dry-run should still surface the gap honestly (got: $out)"
if grepq "$out" -F 'DRY:' && grepq "$out" -F 'guardrail-block.mjs install'; then
  fail "case f: dry-run must NOT fabricate an install step for an unconsented item (got: $out)"
fi
echo "ok: case f — dry-run with no recorded consent never asks, never mutates, surfaces the gap"

# ── case g: --dry-run + recorded consent 'yes' -> the plan SURFACES the step ─
caseg_dir="$work/case-g"; write_cache "$caseg_dir/cache"; write_state "$caseg_dir/cache" yes
settingsG="$caseg_dir/settings.json"
out=$(CLAUDE_USER_SETTINGS="$(winpath "$settingsG")" HIMMELCTL_CACHE_DIR="$(winpath "$caseg_dir/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$caseg_dir/cache")-luna-config.json" \
      HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" ensure --items guardrail-block-global --dry-run </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "case g: dry-run with recorded consent should exit 0 (got rc=$rc): $out"
[ ! -f "$settingsG" ] || fail "case g: dry-run must never write settings.json even when consented"
grepq "$out" -F 'DRY:' || fail "case g: dry-run plan should print a DRY: line (got: $out)"
grepq "$out" -F 'guardrail-block.mjs' || fail "case g: dry-run plan should name guardrail-block.mjs (got: $out)"
grepq "$out" -F 'install' || fail "case g: dry-run plan should show the install verb (got: $out)"
echo "ok: case g — dry-run with recorded consent surfaces the actual plan step"

echo "PASS"
