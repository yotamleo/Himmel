#!/usr/bin/env bash
# test-wizard-derive.sh — hermetic tests for the himmelctl install wizard's
# derivation + shell-out (HIMMEL-887 T4), vault-profile mapping (T5a), and
# handover/pluginSet consumption (T4.5). Mirrors test-wizard-preflight.sh /
# test-wizard-questions.sh conventions: a stub PATH via
# scripts/lib/hermetic-path.sh, a fake HOME, node launched by absolute path.
#
# Shell-out cases point HIMMELCTL_REPO_ROOT (a seam of the same class as
# HIMMELCTL_CACHE_DIR) at a throwaway fixture carrying no-op
# adopt.sh/setup.sh/wire-luna-vault.sh/luna-upgrade-all.sh stubs, so a real
# install (plugin installs, hook wiring, vault scaffolding) is never
# triggered against the real machine. The flag-assertion guard (case A) is
# the one case that deliberately reads the REAL scripts.
#
# Covers (T4):
#   A. flag-assertion guard: every flag the wizard can derive for adopt.sh /
#      wire-luna-vault.sh / luna-upgrade-all.sh is present in their own
#      --help/usage surfaces (script-flag drift guard), and bin.js's source
#      never contains the --force-unstamped literal.
#   B. adopter + vault=none --dry-run -> `adopt.sh --profile core --scope
#      project`, no --luna-target.
#   E. contributor --dry-run -> the platform-appropriate launcher (setup.sh /
#      setup.ps1 on win32), never adopt.sh.
#   F. interactive confirm decline ("n") -> adopt.sh NOT invoked, rc=0, no
#      uninstall footer.
#   G. interactive confirm accept (blank Enter = the [Y/n] default) -> adopt.sh
#      invoked with the exact expected argv, uninstall footer printed.
#   H. non-interactive --from-profile automation -> the confirm is skipped
#      entirely (no "Proceed?" text) and adopt.sh still runs.
#   O. closed stdin (no answer) at the main-path confirm -> declines safely
#      (CR r1 FIX 8 companion coverage), adopt.sh never invoked.
#   P. a FAILED install shell-out (adopt.sh exits 1) -> rc propagated, no
#      uninstall footer.
# Covers (T5a):
#   C. adopter + vault=default-template --dry-run -> `--profile all
#      --luna-target <path>`, and neither luna-upgrade-all.sh nor
#      wire-luna-vault.sh appears anywhere in the derived plan.
# Covers (T5b):
#   D. adopter + vault=existing, UNSTAMPED -> O1-deferral refusal message,
#      non-zero (non-dry-run) / 0 (dry-run), zero shell-outs, nothing derived.
#   L. adopter + vault=existing, STAMPED --dry-run -> the exact two-command
#      plan (wire-luna-vault.sh THEN luna-upgrade-all.sh apply --vault),
#      never --force-unstamped, nothing executed.
#   M. STAMPED, interactive accept -> wire then apply invoked in order, the
#      apply BACKUP line surfaced verbatim, uninstall footer printed.
#   N. STAMPED, interactive decline -> neither script invoked, no footer.
#   Q. CR r1 FIX 5: STAMPED existing-vault honors handover.mode=external
#      exactly like the main path (dry-run DRY-line preview + real handover
#      write on accept) — previously dropped. A legacy pluginSet=full profile
#      no-ops on this branch too (HIMMEL-2304).
# Covers (T4.5):
#   I. HIMMEL-2304: pluginSet=full is a legacy-accepted --from-profile value
#      whose documented per-plugin ENABLE step no-ops exactly like lean now.
#      RP (CR round 3 [codex-1]): the HIMMEL-2033 retired-plugin-removal
#      offer is NOT tied to that enable step and still fires for a legacy
#      full profile, decoupled from it — a machine previously provisioned
#      with full is exactly the population most likely to still carry the
#      retired plugin.
#   J. handover.mode=external writes HANDOVER_DIR + prints the one summary
#      line; handover.mode=inline is a no-op (no .env write, no line).
#   K. --dry-run never mutates anything (combined legacy-full/external/
#      default-template plan): no adopt.sh call, no claude call, no .env
#      write, no plugin DRY line — only the HANDOVER_DIR preview line.
#   R. CR r1 FIX 3: a FAILED handover write aborts fail-closed BEFORE the
#      core install shell-out (adopt.sh never invoked).
#   S. HIMMEL-2304: there is no plugin-enable step left to fail — a legacy
#      pluginSet=full profile against a `claude` stub that always exits 1
#      still succeeds (rc=0), because `claude` is never invoked at all.
#   T. CR r5: --from-profile validates the FULL schema before ANY side
#      effect — a truncated profile (missing scope), a bogus vault.mode,
#      and handover.mode=external without a path each hard-error rc=2
#      naming the bad field, with ZERO shell-outs (no adopt.sh/setup.sh
#      stub invoked). Valid replays (every other case here) stay green.

set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# HIMMEL-1446 r3: a non-dry-run install (the stamped accept cases, e.g. caseM)
# reaches applyHimmelctlPathShim(), whose default binDir is the operator's REAL
# ~/.local/bin (win32 ignores HOME entirely). Isolate binDir for the WHOLE
# suite so no case touches the real bin dir — mirrors test-wizard-update.sh /
# test-wizard-uninstall.sh. winpath'd so win32 node resolves it cleanly.
HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

# build_path <stub_dir> <present_tools...> -- <absent_tools...>
# (Copied from the sibling suites: link the named present tools off the
# CURRENT PATH into <stub_dir>, then echo a PATH with the stub prepended and
# the named absent tools scrubbed.)
build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  for _t in "${_present[@]}"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

# write_cache <path> <role> <scope> <vault-mode> <vault-path> <handover-mode>
#             <handover-path> <plugin-set> — a minimal valid Draft-A profile.
write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
}

# build_fixture <dir> — a throwaway HIMMELCTL_REPO_ROOT target: no-op
# adopt.sh/setup.sh/setup.ps1/wire-luna-vault.sh/luna-upgrade-all.sh stubs
# (each logs its argv to <dir>/*-calls.log) plus a real copy of
# scripts/handover/set-handover-dir.sh (self-contained — no further sourcing —
# so the T4.5 handover-write case exercises the actual production script
# against a fixture path, not a reimplementation). The luna-upgrade-all.sh
# stub also echoes a BACKUP line (mirrors cmd_apply's real output) so the T5b
# "surface the BACKUP line" behavior is exercised without a real apply.
build_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/handover" "$_d/scripts/lib" "$_d/scripts/machine-setup"
  cp "$repo_root/scripts/machine-setup/full-plugin-enable.json" "$_d/scripts/machine-setup/full-plugin-enable.json"
  cat > "$_d/scripts/adopt.sh" <<STUB
#!/usr/bin/env bash
printf 'adopt.sh: %s\n' "\$*" >> "$_d/adopt-calls.log"
exit 0
STUB
  chmod +x "$_d/scripts/adopt.sh"
  cat > "$_d/scripts/setup.sh" <<STUB
#!/usr/bin/env bash
printf 'setup.sh: %s\n' "\$*" >> "$_d/setup-calls.log"
exit 0
STUB
  chmod +x "$_d/scripts/setup.sh"
  cat > "$_d/scripts/setup.ps1" <<'STUB'
Write-Host "setup.ps1 stub"
exit 0
STUB
  cp "$repo_root/scripts/handover/set-handover-dir.sh" "$_d/scripts/handover/set-handover-dir.sh"
  chmod +x "$_d/scripts/handover/set-handover-dir.sh"
  cat > "$_d/scripts/lib/wire-luna-vault.sh" <<STUB
#!/usr/bin/env bash
printf 'wire-luna-vault.sh: %s\n' "\$*" >> "$_d/wire-luna-vault-calls.log"
exit 0
STUB
  chmod +x "$_d/scripts/lib/wire-luna-vault.sh"
  cat > "$_d/scripts/luna-upgrade-all.sh" <<STUB
#!/usr/bin/env bash
printf 'luna-upgrade-all.sh: %s\n' "\$*" >> "$_d/luna-upgrade-all-calls.log"
printf 'BACKUP\t/fake/backup/path\n'
exit 0
STUB
  chmod +x "$_d/scripts/luna-upgrade-all.sh"
}

# stamp_vault <dir> — write a STAMPED .vault-template.json (the same signal
# scripts/luna-upgrade-all.sh's classify_vault() treats as "luna-family").
stamp_vault() {
  mkdir -p "$1"
  printf '{"template":"luna-second-brain"}' > "$1/.vault-template.json"
}

# ── Case A: flag-assertion guard — script-flag drift ───────────────────────
adopt_help=$(bash "$repo_root/scripts/adopt.sh" --help 2>&1)
setup_help=$(bash "$repo_root/scripts/setup.sh" --help 2>&1)
for f in '--profile' '--scope' '--luna-target'; do
  grepq "$adopt_help" -F -- "$f" \
    || fail "flag-assertion: adopt.sh --help is missing derivable flag '$f' (script-flag drift)"
done
grepq "$setup_help" 'Usage' \
  || fail "flag-assertion: setup.sh --help did not produce a usage line"
# T5b: wire-luna-vault.sh takes 2 positional args (settings, vault) — no
# --help support, so its own usage line (printed on arg-count mismatch)
# is the script-drift signal.
wire_usage=$(bash "$repo_root/scripts/lib/wire-luna-vault.sh" 2>&1 || true)
grepq "$wire_usage" -F 'vault-path' \
  || fail "flag-assertion: wire-luna-vault.sh's usage line no longer mentions vault-path (script-flag drift)"
# T5b: luna-upgrade-all.sh apply --vault must still be its documented surface,
# and --force-unstamped must never be something the wizard derives.
lua_help=$(bash "$repo_root/scripts/luna-upgrade-all.sh" --help 2>&1)
grepq "$lua_help" -F -- '--vault' \
  || fail "flag-assertion: luna-upgrade-all.sh --help is missing derivable flag '--vault' (script-flag drift)"
grepq "$lua_help" -F 'apply' \
  || fail "flag-assertion: luna-upgrade-all.sh --help no longer documents the apply subcommand (script-flag drift)"
grep -q -- '--force-unstamped' "$wizard" \
  && fail "flag-assertion: bin.js must NEVER derive --force-unstamped for T5b (found the literal in source)"
echo "ok: caseA flag-assertion guard -- adopt.sh/wire-luna-vault.sh/luna-upgrade-all.sh usage surfaces carry every flag the wizard can derive, and never --force-unstamped"

# ── Case B: adopter + vault=none --dry-run -> core, no --luna-target ───────
stubB="$work/caseB"; mkdir -p "$stubB"
cB=$(build_path "$stubB" bash git jq python3 npm -- )
hB="$work/hB"; mkdir -p "$hB"
cacheB="$work/caseB-profile.json"
write_cache "$cacheB" adopter project none "" inline "" lean
set +e
out=$(PATH="$cB" HOME="$hB" USERPROFILE="$(winpath "$hB")" HIMMELCTL_CACHE_DIR="$(winpath "$hB.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hB.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheB")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseB: dry-run should succeed (got rc=$rc): $out"
grepq "$out" -E 'derived:.*adopt\.sh --profile core --scope project$' \
  || fail "caseB: expected 'adopt.sh --profile core --scope project' (got: $out)"
grepq "$out" -- '--luna-target' \
  && fail "caseB: vault=none must not derive --luna-target (got: $out)"
echo "ok: caseB adopter + vault=none -> --profile core --scope project, no --luna-target"

# ── Case C: adopter + vault=default-template -> all + --luna-target ────────
stubC="$work/caseC"; mkdir -p "$stubC"
cC=$(build_path "$stubC" bash git jq python3 npm -- )
hC="$work/hC"; mkdir -p "$hC"
lunaC="$work/caseC-luna"
cacheC="$work/caseC-profile.json"
write_cache "$cacheC" adopter project default-template "$(winpath "$lunaC")" inline "" lean
set +e
out=$(PATH="$cC" HOME="$hC" USERPROFILE="$(winpath "$hC")" HIMMELCTL_CACHE_DIR="$(winpath "$hC.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hC.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheC")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseC: dry-run should succeed (got rc=$rc): $out"
grepq "$out" -E 'derived:.*adopt\.sh --profile all --scope project --luna-target' \
  || fail "caseC: expected '--profile all --scope project --luna-target ...' (got: $out)"
grepq "$out" 'caseC-luna' \
  || fail "caseC: derived --luna-target should carry the vault path (got: $out)"
grepq "$out" -i 'luna-upgrade-all\.sh' \
  && fail "caseC: default-template must NOT call luna-upgrade-all.sh (got: $out)"
grepq "$out" -i 'wire-luna-vault\.sh' \
  && fail "caseC: default-template must NOT call wire-luna-vault.sh (got: $out)"
echo "ok: caseC adopter + vault=default-template -> --profile all --luna-target, no luna-upgrade-all/wire-luna-vault"

# ── Case D: adopter + vault=existing, UNSTAMPED -> refuse, zero shell-outs ──
stubD="$work/caseD"; mkdir -p "$stubD"
cD=$(build_path "$stubD" bash git jq python3 npm -- )
hD="$work/hD"; mkdir -p "$hD"
fixtureD="$work/caseD-fixture"; build_fixture "$fixtureD"
cacheD="$work/caseD-profile.json"
write_cache "$cacheD" adopter project existing "$(winpath "$work/caseD-vault")" inline "" lean
set +e
out=$(PATH="$cD" HOME="$hD" USERPROFILE="$(winpath "$hD")" HIMMELCTL_CACHE_DIR="$(winpath "$hD.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hD.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheD")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseD: vault=existing unstamped (non-dry-run) should exit non-zero (got rc=$rc): $out"
grepq "$out" -i 'deferred' \
  || fail "caseD: expected the O1-deferral refusal message (got: $out)"
grepq "$out" '^derived:' \
  && fail "caseD: vault=existing unstamped must derive nothing (got: $out)"
[ -f "$fixtureD/wire-luna-vault-calls.log" ] \
  && fail "caseD: unstamped must NOT invoke wire-luna-vault.sh (got: $(cat "$fixtureD/wire-luna-vault-calls.log"))"
[ -f "$fixtureD/luna-upgrade-all-calls.log" ] \
  && fail "caseD: unstamped must NOT invoke luna-upgrade-all.sh (got: $(cat "$fixtureD/luna-upgrade-all-calls.log"))"
set +e
out2=$(PATH="$cD" HOME="$hD" USERPROFILE="$(winpath "$hD")" HIMMELCTL_CACHE_DIR="$(winpath "$hD.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hD.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
       HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
       "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheD")" \
       </dev/null 2>&1); rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "caseD: vault=existing unstamped --dry-run should exit 0 (got rc=$rc2): $out2"
echo "ok: caseD adopter + vault=existing UNSTAMPED -> deferral refusal, zero shell-outs, non-zero (non-dry-run)/0 (dry-run)"

# ── Case L: adopter + vault=existing, STAMPED --dry-run -> exact 2-cmd plan ─
stubL="$work/caseL"; mkdir -p "$stubL"
cL=$(build_path "$stubL" bash git jq python3 npm -- )
hL="$work/hL"; mkdir -p "$hL"
fixtureL="$work/caseL-fixture"; build_fixture "$fixtureL"
vaultL="$work/caseL-vault"; stamp_vault "$vaultL"
cacheL="$work/caseL-profile.json"
write_cache "$cacheL" adopter user existing "$(winpath "$vaultL")" inline "" lean
set +e
out=$(PATH="$cL" HOME="$hL" USERPROFILE="$(winpath "$hL")" HIMMELCTL_CACHE_DIR="$(winpath "$hL.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hL.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureL")" \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheL")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseL: stamped dry-run should exit 0 (got rc=$rc): $out"
# HIMMEL-2460: vault.mode=existing was a parallel re-implementation of the
# main install path that never reached deriveCommand()/adopt.sh at all — the
# derived plan carried ONLY the wire/apply pair. adopt.sh must now derive
# exactly like every other vault mode (profile=core: existing never implies
# default-template's --luna-target), with wire/apply layered on top as an
# ADDITIONAL step, BEFORE either of them.
grepq "$out" -E 'derived:.*adopt\.sh --profile core --scope user$' \
  || fail "caseL (HIMMEL-2460): expected a derived 'adopt.sh --profile core --scope user' line — vault.mode=existing must still run the core installer (got: $out)"
grepq "$out" -E 'derived:.*wire-luna-vault\.sh' \
  || fail "caseL: expected a derived wire-luna-vault.sh line (got: $out)"
grepq "$out" -E 'derived:.*luna-upgrade-all\.sh apply --vault' \
  || fail "caseL: expected a derived 'luna-upgrade-all.sh apply --vault' line (got: $out)"
adopt_line=$(printf '%s' "$out" | grep -n 'adopt\.sh --profile' | head -1 | cut -d: -f1)
wire_line=$(printf '%s' "$out" | grep -n 'wire-luna-vault\.sh' | head -1 | cut -d: -f1)
apply_line=$(printf '%s' "$out" | grep -n 'luna-upgrade-all\.sh apply' | head -1 | cut -d: -f1)
[ "$adopt_line" -lt "$wire_line" ] \
  || fail "caseL (HIMMEL-2460): adopt.sh must be derived BEFORE wire-luna-vault.sh — it is the core install, wire/apply are additional (got: $out)"
[ "$wire_line" -lt "$apply_line" ] \
  || fail "caseL: wire-luna-vault.sh must be derived BEFORE luna-upgrade-all.sh apply (got: $out)"
grepq "$out" -- '--force-unstamped' \
  && fail "caseL: stamped plan must never carry --force-unstamped (got: $out)"
[ -f "$fixtureL/wire-luna-vault-calls.log" ] \
  && fail "caseL: --dry-run must NOT execute wire-luna-vault.sh (got: $(cat "$fixtureL/wire-luna-vault-calls.log"))"
[ -f "$fixtureL/luna-upgrade-all-calls.log" ] \
  && fail "caseL: --dry-run must NOT execute luna-upgrade-all.sh (got: $(cat "$fixtureL/luna-upgrade-all-calls.log"))"
[ -f "$fixtureL/adopt-calls.log" ] \
  && fail "caseL: --dry-run must NOT execute adopt.sh (got: $(cat "$fixtureL/adopt-calls.log"))"
# HIMMEL-2460: the epilogue must name the command that actually installs
# himmel (adopt.sh) — not luna-upgrade-all.sh's apply command, which only
# upgrades the vault.
grepq "$out" -E -- '— would run .*adopt\.sh --profile core --scope user' \
  || fail "caseL (HIMMEL-2460): epilogue must preview adopt.sh as the installer command (got: $out)"
grepq "$out" -E -- '— would run .*luna-upgrade-all\.sh' \
  && fail "caseL (HIMMEL-2460): epilogue must NOT name luna-upgrade-all.sh as the installer command (got: $out)"
echo "ok: caseL stamped existing-vault --dry-run -> adopt.sh derived first, then wire/apply as an additional step, no --force-unstamped, nothing executed, epilogue names adopt.sh"

# ── Case M: stamped, interactive confirm accept -> wire runs, then apply ───
stubM="$work/caseM"; mkdir -p "$stubM"
cM=$(build_path "$stubM" bash git jq python3 npm -- )
hM="$work/hM"; mkdir -p "$hM"
fixtureM="$work/caseM-fixture"; build_fixture "$fixtureM"
vaultM="$work/caseM-vault"; stamp_vault "$vaultM"
cacheM="$work/caseM-profile.json"
write_cache "$cacheM" adopter user existing "$(winpath "$vaultM")" inline "" lean
set +e
out=$(PATH="$cM" HOME="$hM" USERPROFILE="$(winpath "$hM")" HIMMELCTL_CACHE_DIR="$(winpath "$hM.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hM.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureM")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheM")" \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseM: stamped accept should exit 0 (got rc=$rc): $out"
# HIMMEL-2460: adopt.sh must actually run for vault.mode=existing (the bug:
# it was structurally unreachable — this branch returned before
# deriveCommand()/adopt.sh's shell-out ever ran).
[ -f "$fixtureM/adopt-calls.log" ] \
  || fail "caseM (HIMMEL-2460): accept should invoke adopt.sh -- the core install must not be skipped for vault.mode=existing"
grep -q -- '--profile core --scope user' "$fixtureM/adopt-calls.log" \
  || fail "caseM (HIMMEL-2460): adopt.sh should have been called with --profile core --scope user (got: $(cat "$fixtureM/adopt-calls.log"))"
[ -f "$fixtureM/wire-luna-vault-calls.log" ] \
  || fail "caseM: accept should invoke wire-luna-vault.sh"
[ -f "$fixtureM/luna-upgrade-all-calls.log" ] \
  || fail "caseM: accept should invoke luna-upgrade-all.sh"
grep -q -- 'apply --vault' "$fixtureM/luna-upgrade-all-calls.log" \
  || fail "caseM: luna-upgrade-all.sh should be called with apply --vault (got: $(cat "$fixtureM/luna-upgrade-all-calls.log"))"
# Path separators differ (backslash on win32-node vs the forward-slash $hM),
# so match on the unique temp-dir basename rather than the full literal path.
grep -q 'hM' "$fixtureM/wire-luna-vault-calls.log" \
  || fail "caseM: user-scope wire-luna-vault.sh should target the FAKE HOME's settings.json, not the real one (got: $(cat "$fixtureM/wire-luna-vault-calls.log"))"
grepq "$out" -F 'BACKUP' \
  || fail "caseM: expected the apply BACKUP line to be surfaced verbatim (got: $out)"
grepq "$out" -F 'To uninstall later: node scripts/himmelctl/bin.js uninstall' \
  || fail "caseM: expected the uninstall footer after a successful stamped install (got: $out)"
# HIMMEL-2460 (second defect): the epilogue must name the command that
# actually installed himmel (adopt.sh), not luna-upgrade-all.sh's apply
# command (which only upgrades the vault, layered on top).
grepq "$out" -E -- 'via .*adopt\.sh --profile core --scope user' \
  || fail "caseM (HIMMEL-2460): epilogue must credit adopt.sh as the command that installed himmel (got: $out)"
grepq "$out" -E -- 'via .*luna-upgrade-all\.sh' \
  && fail "caseM (HIMMEL-2460): epilogue must NOT credit luna-upgrade-all.sh as the install command (got: $out)"
echo "ok: caseM stamped existing-vault accept -> adopt.sh then wire then apply invoked, BACKUP surfaced, uninstall footer printed, epilogue names adopt.sh"

# ── Case N: stamped, interactive confirm decline -> neither script runs ────
stubN="$work/caseN"; mkdir -p "$stubN"
cN=$(build_path "$stubN" bash git jq python3 npm -- )
hN="$work/hN"; mkdir -p "$hN"
fixtureN="$work/caseN-fixture"; build_fixture "$fixtureN"
vaultN="$work/caseN-vault"; stamp_vault "$vaultN"
cacheN="$work/caseN-profile.json"
write_cache "$cacheN" adopter user existing "$(winpath "$vaultN")" inline "" lean
set +e
out=$(PATH="$cN" HOME="$hN" USERPROFILE="$(winpath "$hN")" HIMMELCTL_CACHE_DIR="$(winpath "$hN.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hN.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureN")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheN")" \
      <<<"n" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseN: stamped decline should exit 0 (got rc=$rc): $out"
grepq "$out" 'declined; nothing run' \
  || fail "caseN: expected the decline message (got: $out)"
[ -f "$fixtureN/adopt-calls.log" ] \
  && fail "caseN (HIMMEL-2460): declining must NOT invoke adopt.sh"
[ -f "$fixtureN/wire-luna-vault-calls.log" ] \
  && fail "caseN: declining must NOT invoke wire-luna-vault.sh"
[ -f "$fixtureN/luna-upgrade-all-calls.log" ] \
  && fail "caseN: declining must NOT invoke luna-upgrade-all.sh"
grepq "$out" -F 'To uninstall later' \
  && fail "caseN: declining must NOT print the uninstall footer (got: $out)"
echo "ok: caseN stamped existing-vault decline -> no script invoked (adopt.sh included), no footer, rc=0"

# ── Case Q: T5b STAMPED honors handover parity with the main path; a legacy ─
# pluginSet=full profile no-ops there too (HIMMEL-2304).
# (CR r1 FIX 5: this branch previously returned after wire+apply without ever
# running writeHandoverDir(), and its dry-run preview never emitted a DRY
# line for the handover answer.)
stubQ="$work/caseQ"; mkdir -p "$stubQ"
cQ=$(build_path "$stubQ" bash git jq python3 npm -- )
cat > "$stubQ/claude" <<STUB
#!/usr/bin/env bash
printf 'claude: %s\n' "\$*" >> "$stubQ/claude-calls.log"
exit 0
STUB
chmod +x "$stubQ/claude"
hQ="$work/hQ"; mkdir -p "$hQ"
fixtureQ="$work/caseQ-fixture"; build_fixture "$fixtureQ"
vaultQ="$work/caseQ-vault"; stamp_vault "$vaultQ"
handoverTargetQ="$work/caseQ-handover-target"
cacheQ="$work/caseQ-profile.json"
write_cache "$cacheQ" adopter user existing "$(winpath "$vaultQ")" external "$(winpath "$handoverTargetQ")" full

set +e
outDry=$(PATH="$cQ" HOME="$hQ" USERPROFILE="$(winpath "$hQ")" HIMMELCTL_CACHE_DIR="$(winpath "$hQ.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hQ.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureQ")" \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheQ")" \
      </dev/null 2>&1); rcDry=$?
set -e
[ "$rcDry" -eq 0 ] || fail "caseQ(dry): should exit 0 (got rc=$rcDry): $outDry"
grepq "$outDry" '^DRY: HANDOVER_DIR ->' \
  || fail "caseQ(dry): expected a DRY HANDOVER_DIR preview line on the T5b branch (got: $outDry)"
grepq "$outDry" 'claude plugin' \
  && fail "caseQ(dry): a legacy pluginSet=full profile must NOT preview any plugin-enable DRY line (got: $outDry)"

set +e
out=$(PATH="$cQ" HOME="$hQ" USERPROFILE="$(winpath "$hQ")" HIMMELCTL_CACHE_DIR="$(winpath "$hQ.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hQ.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureQ")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheQ")" \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseQ: accept should exit 0 (got rc=$rc): $out"
[ -f "$fixtureQ/adopt-calls.log" ] \
  || fail "caseQ (HIMMEL-2460): expected adopt.sh to run -- the core install must not be skipped for vault.mode=existing"
[ -f "$fixtureQ/.env" ] \
  || fail "caseQ: expected the T5b branch to write HANDOVER_DIR (.env missing)"
grep -qE 'HANDOVER_DIR=.*caseQ-handover-target' "$fixtureQ/.env" \
  || fail "caseQ: expected HANDOVER_DIR= in .env pointing at the target (got: $(cat "$fixtureQ/.env"))"
[ -f "$fixtureQ/wire-luna-vault-calls.log" ] \
  || fail "caseQ: expected wire-luna-vault.sh to still run"
[ -f "$fixtureQ/luna-upgrade-all-calls.log" ] \
  || fail "caseQ: expected luna-upgrade-all.sh to still run"
[ -f "$stubQ/claude-calls.log" ] \
  && fail "caseQ: a legacy pluginSet=full profile must NOT trigger any claude call on the T5b branch (got: $(cat "$stubQ/claude-calls.log"))"
grepq "$out" -F 'To uninstall later' \
  || fail "caseQ: expected the uninstall footer after a successful T5b install"
echo "ok: caseQ T5b existing-vault STAMPED honors handover.mode=external (dry-run DRY preview + real write on accept); a legacy pluginSet=full no-ops there too"

# ── Case E (HIMMEL-2308): a legacy contributor cache migrates to devOverlay ─
# =true — deriveCommand ALWAYS derives adopt.sh now (ONE execution engine);
# the old contributor role's setup.sh/setup.ps1 is layered on TOP as the dev
# overlay's OWN additional command, never a substitute for adopt.sh.
# HIMMEL-2126: win32 launches the overlay's setup.ps1 through
# resolvePowershell(), which PREFERS pwsh over PowerShell 5.1 — so pwsh is
# scrubbed from PATH here (this box's own pwsh must not leak in) to pin the
# loud-fallback branch; caseE2 below covers the pwsh-preferred branch with
# pwsh injected instead.
stubE="$work/caseE"; mkdir -p "$stubE"
cE=$(build_path "$stubE" bash git jq python3 npm -- pwsh)
hE="$work/hE"; mkdir -p "$hE"
cacheE="$work/caseE-profile.json"
write_cache "$cacheE" contributor user none "" inline "" lean
set +e
out=$(PATH="$cE" HOME="$hE" USERPROFILE="$(winpath "$hE")" HIMMELCTL_CACHE_DIR="$(winpath "$hE.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hE.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheE")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseE: dry-run should succeed (got rc=$rc): $out"
grepq "$out" -E 'derived:.*adopt\.sh --profile core --scope user$' \
  || fail "caseE: a migrated legacy contributor cache (devOverlay=true) must still derive adopt.sh as the primary command (got: $out)"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    grepq "$out" -iE 'derived \(dev overlay\):.*powershell' \
      || fail "caseE(win32): expected a PowerShell 5.1 fallback overlay line (pwsh scrubbed) (got: $out)"
    grepq "$out" -F -- '-ExecutionPolicy Bypass -File' \
      || fail "caseE(win32): expected -ExecutionPolicy Bypass -File (got: $out)"
    grepq "$out" -F -- 'setup.ps1' \
      || fail "caseE(win32): expected setup.ps1 (got: $out)"
    ;;
  *)
    grepq "$out" -E 'derived \(dev overlay\):.*bash .*setup\.sh$' \
      || fail "caseE(posix): expected an overlay 'bash .../setup.sh' line (got: $out)"
    ;;
esac
echo "ok: caseE a migrated legacy contributor cache (devOverlay=true) derives adopt.sh AS the primary command plus the setup.sh/ps1 overlay"

# ── Case E2 (HIMMEL-2126): the dev overlay on win32 prefers pwsh when
# it is resolvable — a stub pwsh is injected onto PATH (posix is a no-op:
# caseE already covers it, and there is no pwsh/powershell branch there).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    stubE2="$work/caseE2"; mkdir -p "$stubE2"
    cE2=$(build_path "$stubE2" bash git jq python3 npm pwsh -- )
    hE2="$work/hE2"; mkdir -p "$hE2"
    cacheE2="$work/caseE2-profile.json"
    write_cache "$cacheE2" contributor user none "" inline "" lean
    set +e
    outE2=$(PATH="$cE2" HOME="$hE2" USERPROFILE="$(winpath "$hE2")" HIMMELCTL_CACHE_DIR="$(winpath "$hE2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hE2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
          "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheE2")" \
          </dev/null 2>&1); rcE2=$?
    set -e
    [ "$rcE2" -eq 0 ] || fail "caseE2: dry-run should succeed (got rc=$rcE2): $outE2"
    grepq "$outE2" -F -- 'derived (dev overlay):' \
      || fail "caseE2(win32): expected the overlay derived-line marker (got: $outE2)"
    grepq "$outE2" -F -- 'pwsh' \
      || fail "caseE2(win32): expected pwsh to be preferred when resolvable (got: $outE2)"
    grepq "$outE2" -F -- '-ExecutionPolicy Bypass -File' \
      || fail "caseE2(win32): expected -ExecutionPolicy Bypass -File (got: $outE2)"
    grepq "$outE2" -F -- 'setup.ps1' \
      || fail "caseE2(win32): expected setup.ps1 (got: $outE2)"
    echo "ok: caseE2 dev overlay on win32 -> pwsh preferred over PowerShell 5.1 when resolvable"
    ;;
  *) echo "ok: caseE2 -> (skipped: posix has no pwsh/powershell branch, covered by caseE)" ;;
esac

# ── Case F: interactive confirm decline -> adopt.sh NOT invoked ────────────
stubF="$work/caseF"; mkdir -p "$stubF"
cF=$(build_path "$stubF" bash git jq python3 npm -- )
hF="$work/hF"; mkdir -p "$hF"
fixtureF="$work/caseF-fixture"; build_fixture "$fixtureF"
cacheF="$work/caseF-profile.json"
write_cache "$cacheF" adopter project none "" inline "" lean
set +e
out=$(PATH="$cF" HOME="$hF" USERPROFILE="$(winpath "$hF")" HIMMELCTL_CACHE_DIR="$(winpath "$hF.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hF.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheF")" \
      <<<"n" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: decline should exit 0 (got rc=$rc): $out"
grepq "$out" 'Proceed? \[Y/n\]' \
  || fail "caseF: expected the confirm prompt to be shown (got: $out)"
grepq "$out" 'declined; nothing run' \
  || fail "caseF: expected the decline message (got: $out)"
[ -f "$fixtureF/adopt-calls.log" ] \
  && fail "caseF: declining must NOT invoke adopt.sh (got: $(cat "$fixtureF/adopt-calls.log"))"
grepq "$out" -F 'To uninstall later' \
  && fail "caseF: declining must NOT print the uninstall footer (got: $out)"
echo "ok: caseF interactive confirm decline -> adopt.sh not invoked, no footer, rc=0"

# ── Case G: interactive confirm accept (blank Enter = the Y default) ───────
stubG="$work/caseG"; mkdir -p "$stubG"
cG=$(build_path "$stubG" bash git jq python3 npm -- )
hG="$work/hG"; mkdir -p "$hG"
fixtureG="$work/caseG-fixture"; build_fixture "$fixtureG"
cacheG="$work/caseG-profile.json"
write_cache "$cacheG" adopter project none "" inline "" lean
set +e
out=$(PATH="$cG" HOME="$hG" USERPROFILE="$(winpath "$hG")" HIMMELCTL_CACHE_DIR="$(winpath "$hG.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hG.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureG")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheG")" \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseG: accept should exit 0 (got rc=$rc): $out"
[ -f "$fixtureG/adopt-calls.log" ] \
  || fail "caseG: a blank-Enter accept should invoke adopt.sh (no adopt-calls.log; out: $out)"
grep -q -- '--profile core --scope project' "$fixtureG/adopt-calls.log" \
  || fail "caseG: adopt.sh should have been called with --profile core --scope project (got: $(cat "$fixtureG/adopt-calls.log"))"
grepq "$out" -F 'To uninstall later: node scripts/himmelctl/bin.js uninstall' \
  || fail "caseG: expected the uninstall footer after a successful install (got: $out)"
echo "ok: caseG interactive confirm accept (blank Enter) -> adopt.sh invoked with the exact derived argv, footer printed"

# ── Case P: a FAILED install shell-out (adopt.sh exits 1) -> no footer ──────
stubP="$work/caseP"; mkdir -p "$stubP"
cP=$(build_path "$stubP" bash git jq python3 npm -- )
hP="$work/hP"; mkdir -p "$hP"
fixtureP="$work/caseP-fixture"; build_fixture "$fixtureP"
cat > "$fixtureP/scripts/adopt.sh" <<STUB
#!/usr/bin/env bash
printf 'adopt.sh: %s\n' "\$*" >> "$fixtureP/adopt-calls.log"
exit 1
STUB
chmod +x "$fixtureP/scripts/adopt.sh"
cacheP="$work/caseP-profile.json"
write_cache "$cacheP" adopter project none "" inline "" lean
set +e
out=$(PATH="$cP" HOME="$hP" USERPROFILE="$(winpath "$hP")" HIMMELCTL_CACHE_DIR="$(winpath "$hP.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hP.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureP")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheP")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "caseP: a failed adopt.sh should propagate rc=1 (got rc=$rc): $out"
[ -f "$fixtureP/adopt-calls.log" ] \
  || fail "caseP: adopt.sh should still have been invoked"
grepq "$out" -F 'To uninstall later' \
  && fail "caseP: a failed install must NOT print the uninstall footer (got: $out)"
echo "ok: caseP failed install shell-out (rc=1) -> rc propagated, no uninstall footer"

# ── Case H: non-interactive --from-profile automation skips the confirm ────
stubH="$work/caseH"; mkdir -p "$stubH"
cH=$(build_path "$stubH" bash git jq python3 npm -- )
hH="$work/hH"; mkdir -p "$hH"
fixtureH="$work/caseH-fixture"; build_fixture "$fixtureH"
cacheH="$work/caseH-profile.json"
write_cache "$cacheH" adopter project none "" inline "" lean
set +e
out=$(PATH="$cH" HOME="$hH" USERPROFILE="$(winpath "$hH")" HIMMELCTL_CACHE_DIR="$(winpath "$hH.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hH.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureH")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheH")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseH: non-interactive automation should exit 0 (got rc=$rc): $out"
grepq "$out" 'Proceed?' \
  && fail "caseH: non-interactive --from-profile must NOT show the confirm (got: $out)"
[ -f "$fixtureH/adopt-calls.log" ] \
  || fail "caseH: non-interactive --from-profile should auto-proceed and invoke adopt.sh"
echo "ok: caseH non-interactive --from-profile -> confirm skipped, adopt.sh auto-invoked"

# ── Case O: closed stdin (no answer) at the main-path confirm -> declines ───
# (CR r1 FIX 8 companion: exercises the main-path 'Proceed? [Y/n]' confirm,
# already routed through the EOF-safe askConfirmSafe — mirrors
# test-wizard-uninstall.sh Case E for the install flow.)
stubO="$work/caseO"; mkdir -p "$stubO"
cO=$(build_path "$stubO" bash git jq python3 npm -- )
hO="$work/hO"; mkdir -p "$hO"
fixtureO="$work/caseO-fixture"; build_fixture "$fixtureO"
cacheO="$work/caseO-profile.json"
write_cache "$cacheO" adopter project none "" inline "" lean
set +e
out=$(PATH="$cO" HOME="$hO" USERPROFILE="$(winpath "$hO")" HIMMELCTL_CACHE_DIR="$(winpath "$hO.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hO.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureO")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheO")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseO: closed-stdin decline should exit 0 (got rc=$rc): $out"
grepq "$out" 'declined; nothing run' \
  || fail "caseO: expected the decline message on closed stdin (got: $out)"
[ -f "$fixtureO/adopt-calls.log" ] \
  && fail "caseO: a closed stdin at the confirm must NOT invoke adopt.sh (got: $(cat "$fixtureO/adopt-calls.log"))"
echo "ok: caseO closed stdin at 'Proceed? [Y/n]' -> declines safely, adopt.sh never invoked"

# ── Case I (HIMMEL-2304): pluginSet=full's ENABLE step is a legacy-accepted ─
# NO-OP now; lean triggers no plugin step either. Before HIMMEL-2304, a
# `full` profile ran the documented 13-plugin/1-marketplace enable step —
# that "wiring" is what the ticket dropped along with the wizard's 'full'
# choice. 'full' stays a VALID --from-profile value (loadProfile's checkEnum
# still accepts it — an old cached profile must not hard-error) but
# applyPluginStep()'s enable step is now unconditionally a no-op, so a legacy
# 'full' cache's ENABLE behavior replays exactly like 'lean': this fixture
# carries no remove-retired-plugin.sh (build_fixture doesn't copy it), so
# the HIMMEL-2033 offer restored in CR round 3 [codex-1] below also no-ops
# here (see caseRP for the case where the script IS present) — net zero
# `claude` invocations either way.
stubI="$work/caseI"; mkdir -p "$stubI"
cI=$(build_path "$stubI" bash git jq python3 npm -- )
cat > "$stubI/claude" <<STUB
#!/usr/bin/env bash
printf 'claude: %s\n' "\$*" >> "$stubI/claude-calls.log"
exit 0
STUB
chmod +x "$stubI/claude"
hI="$work/hI"; mkdir -p "$hI"
fixtureI="$work/caseI-fixture"; build_fixture "$fixtureI"
cacheIFull="$work/caseI-full-profile.json"
write_cache "$cacheIFull" adopter project none "" inline "" full
set +e
out=$(PATH="$cI" HOME="$hI" USERPROFILE="$(winpath "$hI")" HIMMELCTL_CACHE_DIR="$(winpath "$hI.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hI.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureI")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheIFull")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseI(full): should exit 0 (got rc=$rc): $out"
[ -f "$stubI/claude-calls.log" ] \
  && fail "caseI(full): a legacy pluginSet=full profile must NOT trigger any claude call (got: $(cat "$stubI/claude-calls.log"))"
echo "ok: caseI(full) a legacy pluginSet=full profile validates and no-ops — no plugin-enable step"

# -- Case RP (restored, CR round 3 [codex-1]): pluginSet=full still offers ---
# the SHARED HIMMEL-2033 retired-plugin helper, decoupled from the (removed)
# enable step. A legacy full profile is exactly the population most likely
# to still carry the retired plugin, so applyPluginStep() keeps calling
# offerRetiredPluginRemoval() for that answer alone even though it no longer
# runs the 13-plugin enable step. Plant the REAL helper in the fixture (case
# I above deliberately did not) and assert the wizard invokes it: its
# read-only probes must appear in the claude call log, and with stdin closed
# (non-interactive) it must never reach a removal command.
stubRP="$work/caseRP"; mkdir -p "$stubRP"
cRP=$(build_path "$stubRP" bash git jq python3 npm -- )
cat > "$stubRP/claude" <<STUB
#!/usr/bin/env bash
printf 'claude: %s\n' "\$*" >> "$stubRP/claude-calls.log"
exit 0
STUB
chmod +x "$stubRP/claude"
hRP="$work/hRP"; mkdir -p "$hRP"
fixtureRP="$work/caseRP-fixture"; build_fixture "$fixtureRP"
cp "$repo_root/scripts/machine-setup/remove-retired-plugin.sh" \
   "$fixtureRP/scripts/machine-setup/remove-retired-plugin.sh"
cacheRPFull="$work/caseRP-full-profile.json"
write_cache "$cacheRPFull" adopter project none "" inline "" full
set +e
outRP=$(PATH="$cRP" HOME="$hRP" USERPROFILE="$(winpath "$hRP")" HIMMELCTL_CACHE_DIR="$(winpath "$hRP.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hRP.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
       HIMMEL_UPDATE_CLAUDE_BIN="$stubRP/claude" \
       HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRP")" \
       "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheRPFull")" \
       </dev/null 2>&1); rcRP=$?
set -e
[ "$rcRP" -eq 0 ] || fail "caseRP: should exit 0 (got rc=$rcRP): $outRP"
grep -q 'plugin list' "$stubRP/claude-calls.log" \
  || fail "caseRP: the shared retired-plugin helper was not invoked: $(cat "$stubRP/claude-calls.log")"
grep -q 'plugin uninstall' "$stubRP/claude-calls.log" \
  && fail "caseRP: non-interactive run must never remove: $(cat "$stubRP/claude-calls.log")"
echo "ok: caseRP pluginSet=full -> the shared HIMMEL-2033 helper runs (enable step stays a no-op), read-only when non-interactive"

stubI2="$work/caseI2"; mkdir -p "$stubI2"
cI2=$(build_path "$stubI2" bash git jq python3 npm -- )
cat > "$stubI2/claude" <<STUB
#!/usr/bin/env bash
printf 'claude: %s\n' "\$*" >> "$stubI2/claude-calls.log"
exit 0
STUB
chmod +x "$stubI2/claude"
hI2="$work/hI2"; mkdir -p "$hI2"
fixtureI2="$work/caseI2-fixture"; build_fixture "$fixtureI2"
cacheILean="$work/caseI-lean-profile.json"
write_cache "$cacheILean" adopter project none "" inline "" lean
set +e
out2=$(PATH="$cI2" HOME="$hI2" USERPROFILE="$(winpath "$hI2")" HIMMELCTL_CACHE_DIR="$(winpath "$hI2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hI2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
       HIMMELCTL_REPO_ROOT="$(winpath "$fixtureI2")" \
       "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheILean")" \
       </dev/null 2>&1); rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "caseI(lean): should exit 0 (got rc=$rc2): $out2"
[ -f "$stubI2/claude-calls.log" ] \
  && fail "caseI(lean): pluginSet=lean must NOT invoke claude (got: $(cat "$stubI2/claude-calls.log"))"
echo "ok: caseI(lean) pluginSet=lean -> no plugin-enable step"

# ── Case S (HIMMEL-2304): applyPluginStep() never runs a command, so it can
# never fail either — a `claude` stub that always exits 1 must have zero
# effect on a legacy pluginSet=full install (rc=0, no WARN line, no plugin
# calls at all). Pre-2304 this asserted the OPPOSITE (a failed plugin-enable
# command propagated rc=1 with a WARN summary) — that whole failure surface
# no longer exists once the enable step itself is removed.
stubS="$work/caseS"; mkdir -p "$stubS"
cS=$(build_path "$stubS" bash git jq python3 npm -- )
cat > "$stubS/claude" <<STUB
#!/usr/bin/env bash
printf 'claude: %s\n' "\$*" >> "$stubS/claude-calls.log"
exit 1
STUB
chmod +x "$stubS/claude"
hS="$work/hS"; mkdir -p "$hS"
fixtureS="$work/caseS-fixture"; build_fixture "$fixtureS"
cacheS="$work/caseS-profile.json"
write_cache "$cacheS" adopter project none "" inline "" full
set +e
out=$(PATH="$cS" HOME="$hS" USERPROFILE="$(winpath "$hS")" HIMMELCTL_CACHE_DIR="$(winpath "$hS.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hS.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureS")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheS")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseS: no plugin step means nothing to fail — should exit 0 (got rc=$rc): $out"
grepq "$out" -E 'WARN: [0-9]+ of [0-9]+ plugin command\(s\) failed' \
  && fail "caseS: the plugin-enable WARN line must never print — the step no longer runs (got: $out)"
[ -f "$stubS/claude-calls.log" ] \
  && fail "caseS: a failing claude stub must never even be invoked (got: $(cat "$stubS/claude-calls.log"))"
[ -f "$fixtureS/adopt-calls.log" ] \
  || fail "caseS: the core install should still have run"
grepq "$out" -F 'To uninstall later' \
  || fail "caseS: the uninstall footer should still print after a successful core install"
echo "ok: caseS a legacy pluginSet=full profile never invokes claude, so it can never surface a plugin-enable failure"

# ── Case J: handover.mode=external writes HANDOVER_DIR; inline is a no-op ──
stubJ="$work/caseJ"; mkdir -p "$stubJ"
cJ=$(build_path "$stubJ" bash git jq python3 npm -- )
hJ="$work/hJ"; mkdir -p "$hJ"
fixtureJ="$work/caseJ-fixture"; build_fixture "$fixtureJ"
handoverTargetJ="$work/caseJ-handover-target"
cacheJExt="$work/caseJ-ext-profile.json"
write_cache "$cacheJExt" adopter project none "" external "$(winpath "$handoverTargetJ")" lean
set +e
out=$(PATH="$cJ" HOME="$hJ" USERPROFILE="$(winpath "$hJ")" HIMMELCTL_CACHE_DIR="$(winpath "$hJ.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hJ.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureJ")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheJExt")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseJ(external): should exit 0 (got rc=$rc): $out"
grepq "$out" -E 'HANDOVER_DIR -> .*caseJ-handover-target.*\(written to .*\.env\)' \
  || fail "caseJ(external): expected the ONE HANDOVER_DIR summary line (got: $out)"
[ -f "$fixtureJ/.env" ] \
  || fail "caseJ(external): expected $fixtureJ/.env to be written"
grep -qE 'HANDOVER_DIR=.*caseJ-handover-target' "$fixtureJ/.env" \
  || fail "caseJ(external): expected HANDOVER_DIR= in .env pointing at the target (got: $(cat "$fixtureJ/.env"))"
echo "ok: caseJ(external) handover.mode=external -> HANDOVER_DIR written + ONE summary line"

stubJ2="$work/caseJ2"; mkdir -p "$stubJ2"
cJ2=$(build_path "$stubJ2" bash git jq python3 npm -- )
hJ2="$work/hJ2"; mkdir -p "$hJ2"
fixtureJ2="$work/caseJ2-fixture"; build_fixture "$fixtureJ2"
cacheJInline="$work/caseJ-inline-profile.json"
write_cache "$cacheJInline" adopter project none "" inline "" lean
set +e
out2=$(PATH="$cJ2" HOME="$hJ2" USERPROFILE="$(winpath "$hJ2")" HIMMELCTL_CACHE_DIR="$(winpath "$hJ2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hJ2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
       HIMMELCTL_REPO_ROOT="$(winpath "$fixtureJ2")" \
       "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheJInline")" \
       </dev/null 2>&1); rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "caseJ(inline): should exit 0 (got rc=$rc2): $out2"
grepq "$out2" 'HANDOVER_DIR ->' \
  && fail "caseJ(inline): handover.mode=inline must be a no-op (got: $out2)"
[ -f "$fixtureJ2/.env" ] \
  && fail "caseJ(inline): handover.mode=inline must not write .env (got: $(cat "$fixtureJ2/.env"))"
echo "ok: caseJ(inline) handover.mode=inline -> no-op, no HANDOVER_DIR line, no .env write"

# ── Case R: a FAILED handover write aborts BEFORE the core install (FIX 3) ─
stubR="$work/caseR"; mkdir -p "$stubR"
cR=$(build_path "$stubR" bash git jq python3 npm -- )
hR="$work/hR"; mkdir -p "$hR"
fixtureR="$work/caseR-fixture"; build_fixture "$fixtureR"
cat > "$fixtureR/scripts/handover/set-handover-dir.sh" <<'STUB'
#!/usr/bin/env bash
echo "set-handover-dir.sh: stubbed failure" >&2
exit 1
STUB
chmod +x "$fixtureR/scripts/handover/set-handover-dir.sh"
handoverTargetR="$work/caseR-handover-target"
cacheR="$work/caseR-profile.json"
write_cache "$cacheR" adopter project none "" external "$(winpath "$handoverTargetR")" lean
set +e
out=$(PATH="$cR" HOME="$hR" USERPROFILE="$(winpath "$hR")" HIMMELCTL_CACHE_DIR="$(winpath "$hR.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hR.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureR")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheR")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseR: a failed handover write should abort with non-zero rc (got rc=$rc): $out"
grepq "$out" -i 'failed to write HANDOVER_DIR' \
  || fail "caseR: expected the handover-write failure message (got: $out)"
[ -f "$fixtureR/adopt-calls.log" ] \
  && fail "caseR: a failed handover write must abort BEFORE the core install shell-out (adopt.sh was invoked: $(cat "$fixtureR/adopt-calls.log"))"
echo "ok: caseR a failed handover write aborts fail-closed BEFORE the core install shell-out (rc!=0, adopt.sh never invoked)"

# ── Case T: malformed --from-profile replays -> rc=2, zero shell-outs (r5) ──
stubT="$work/caseT"; mkdir -p "$stubT"
cT=$(build_path "$stubT" bash git jq python3 npm -- )
hT="$work/hT"; mkdir -p "$hT"
fixtureT="$work/caseT-fixture"; build_fixture "$fixtureT"

# T1: truncated profile — object valid JSON but missing `scope` entirely.
badT1="$work/caseT-noscope.json"
cat > "$badT1" <<'JSON'
{"role":"adopter","tier":"standard","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"alwaysOn":false}
JSON
# T2: bogus vault.mode — the old role-only check silently fell back to core.
badT2="$work/caseT-badvault.json"
write_cache "$badT2" adopter project bogus-mode "" inline "" lean
# T3: handover.mode=external with no path.
badT3="$work/caseT-nohandoverpath.json"
write_cache "$badT3" adopter project none "" external "" lean

runT() { # runT <profile> — replay under the stubbed fixture, echo rc
  set +e
  outT=$(PATH="$cT" HOME="$hT" USERPROFILE="$(winpath "$hT")" HIMMELCTL_CACHE_DIR="$(winpath "$hT.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hT.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
        HIMMELCTL_REPO_ROOT="$(winpath "$fixtureT")" \
        "$node_bin" "$wizard" install --from-profile "$(winpath "$1")" \
        </dev/null 2>&1); rcT=$?
  set -e
}

runT "$badT1"
[ "$rcT" -eq 2 ] || fail "caseT(scope): missing scope should hard-error rc=2 (got rc=$rcT): $outT"
grepq "$outT" "field 'scope'" \
  || fail "caseT(scope): expected the error to name field 'scope' (got: $outT)"

runT "$badT2"
[ "$rcT" -eq 2 ] || fail "caseT(vault.mode): bogus vault.mode should hard-error rc=2 (got rc=$rcT): $outT"
grepq "$outT" "field 'vault.mode'" \
  || fail "caseT(vault.mode): expected the error to name field 'vault.mode' (got: $outT)"

runT "$badT3"
[ "$rcT" -eq 2 ] || fail "caseT(handover.path): external without path should hard-error rc=2 (got rc=$rcT): $outT"
grepq "$outT" "field 'handover.path'" \
  || fail "caseT(handover.path): expected the error to name field 'handover.path' (got: $outT)"

[ -f "$fixtureT/adopt-calls.log" ] \
  && fail "caseT: a malformed profile must NEVER shell out (adopt.sh ran: $(cat "$fixtureT/adopt-calls.log"))"
[ -f "$fixtureT/setup-calls.log" ] \
  && fail "caseT: a malformed profile must NEVER shell out (setup.sh ran: $(cat "$fixtureT/setup-calls.log"))"
[ -f "$fixtureT/.env" ] \
  && fail "caseT: a malformed profile must NEVER write .env (got: $(cat "$fixtureT/.env"))"
echo "ok: caseT malformed --from-profile replays (missing scope / bogus vault.mode / external without path) -> rc=2 naming the field, zero shell-outs"

# ── Case K: --dry-run never mutates (combined legacy-full/external/ ─────────
# default-template) — HIMMEL-2304: no DRY plugin-enable line for pluginSet=
# full anymore, since the step it would have previewed no longer exists.
stubK="$work/caseK"; mkdir -p "$stubK"
cK=$(build_path "$stubK" bash git jq python3 npm -- )
cat > "$stubK/claude" <<STUB
#!/usr/bin/env bash
printf 'claude: %s\n' "\$*" >> "$stubK/claude-calls.log"
exit 0
STUB
chmod +x "$stubK/claude"
hK="$work/hK"; mkdir -p "$hK"
fixtureK="$work/caseK-fixture"; build_fixture "$fixtureK"
lunaK="$work/caseK-luna"
handoverTargetK="$work/caseK-handover-target"
cacheK="$work/caseK-profile.json"
write_cache "$cacheK" adopter project default-template "$(winpath "$lunaK")" external "$(winpath "$handoverTargetK")" full
set +e
out=$(PATH="$cK" HOME="$hK" USERPROFILE="$(winpath "$hK")" HIMMELCTL_CACHE_DIR="$(winpath "$hK.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hK.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureK")" \
      "$node_bin" "$wizard" install --dry-run --from-profile "$(winpath "$cacheK")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseK: dry-run should exit 0 (got rc=$rc): $out"
[ -f "$fixtureK/adopt-calls.log" ] \
  && fail "caseK: dry-run must NOT execute adopt.sh (got: $(cat "$fixtureK/adopt-calls.log"))"
[ -f "$stubK/claude-calls.log" ] \
  && fail "caseK: dry-run must NOT invoke claude (got: $(cat "$stubK/claude-calls.log"))"
[ -f "$fixtureK/.env" ] \
  && fail "caseK: dry-run must NOT write .env (got: $(cat "$fixtureK/.env"))"
grepq "$out" '^DRY: HANDOVER_DIR ->' \
  || fail "caseK: expected a DRY HANDOVER_DIR preview line (got: $out)"
grepq "$out" 'claude plugin' \
  && fail "caseK: a legacy pluginSet=full profile must NOT preview any plugin-enable DRY line (got: $out)"
grepq "$out" -E 'derived:.*adopt\.sh --profile all --scope project --luna-target' \
  || fail "caseK: expected the --profile all --luna-target derived line (got: $out)"
echo "ok: caseK --dry-run (legacy full + external + default-template combo) -> zero mutation, no plugin DRY preview"

# ── Case U: EACCES settings pre-check fails friendly before wire/plugin ──────
stubU="$work/caseU"; mkdir -p "$stubU"
cU=$(build_path "$stubU" bash git jq python3 npm -- )
hU="$work/hU"; mkdir -p "$hU/.claude"
settingsU="$hU/.claude/settings.json"; printf '{}\n' > "$settingsU"
fixtureU="$work/caseU-fixture"; build_fixture "$fixtureU"
vaultU="$work/caseU-vault"; stamp_vault "$vaultU"
cacheU="$work/caseU-profile.json"
write_cache "$cacheU" adopter user existing "$(winpath "$vaultU")" inline "" lean
denyU="$work/deny-settings-write.js"
cat > "$denyU" <<'JS'
const fs = require('fs');
const path = require('path');
const realAccessSync = fs.accessSync;
fs.accessSync = function (p, mode) {
  if (path.resolve(String(p)) === path.resolve(process.env.DENY_SETTINGS_PATH)) {
    const err = new Error('simulated permission denied');
    err.code = 'EACCES';
    throw err;
  }
  return realAccessSync.call(fs, p, mode);
};
JS
set +e
out=$(PATH="$cU" HOME="$hU" USERPROFILE="$(winpath "$hU")" HIMMELCTL_CACHE_DIR="$(winpath "$hU.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hU.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureU")" \
      DENY_SETTINGS_PATH="$(winpath "$settingsU")" \
      NODE_OPTIONS="--require=$(winpath "$denyU")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheU")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseU: simulated EACCES should fail before wiring (got rc=0): $out"
grepq "$out" 'target settings.json is not writable' \
  || fail "caseU: expected the friendly settings writability diagnostic (got: $out)"
grepq "$out" 'EACCES' \
  || fail "caseU: expected the EACCES code in the diagnostic (got: $out)"
[ -f "$fixtureU/wire-luna-vault-calls.log" ] \
  && fail "caseU: EACCES pre-check must abort before wire-luna-vault.sh"
[ -f "$fixtureU/luna-upgrade-all-calls.log" ] \
  && fail "caseU: EACCES pre-check must abort before luna-upgrade-all.sh"
echo "ok: caseU simulated settings EACCES -> friendly fail before wire/plugin steps"

# ── Case V (HIMMEL-2308): a v2 devOverlay=true cache runs BOTH commands ──────
# on an APPLIED (non-dry-run) install: adopt.sh first, then the overlay's
# setup.sh, in that order — and if adopt.sh fails the overlay must never run.
stubV="$work/caseV"; mkdir -p "$stubV"
cV=$(build_path "$stubV" bash git jq python3 npm -- )
hV="$work/hV"; mkdir -p "$hV"
fixtureV="$work/caseV-fixture"; build_fixture "$fixtureV"
cacheV="$work/caseV-profile.json"
cat > "$cacheV" <<'JSON'
{"schemaVersion":2,"profile":"custom","devOverlay":true,"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
set +e
out=$(PATH="$cV" HOME="$hV" USERPROFILE="$(winpath "$hV")" HIMMELCTL_CACHE_DIR="$(winpath "$hV.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hV.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureV")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheV")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseV: devOverlay=true applied install should succeed (got rc=$rc): $out"
[ -f "$fixtureV/adopt-calls.log" ] \
  || fail "caseV: adopt.sh should have run (got: $out)"
# build_fixture's setup.ps1 stub (win32) doesn't log calls the way setup.sh
# does — it prints its own sentinel line instead.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    grepq "$out" -F 'setup.ps1 stub' \
      || fail "caseV(win32): the dev overlay's setup.ps1 should ALSO have run (got: $out)"
    ;;
  *)
    [ -f "$fixtureV/setup-calls.log" ] \
      || fail "caseV(posix): the dev overlay's setup.sh should ALSO have run (got: $out)"
    ;;
esac
echo "ok: caseV a v2 devOverlay=true cache runs adopt.sh AND the setup.sh/ps1 overlay on an applied install"

# caseV2: adopt.sh failing must abort BEFORE the overlay ever runs.
stubV2="$work/caseV2"; mkdir -p "$stubV2"
cV2=$(build_path "$stubV2" bash git jq python3 npm -- )
hV2="$work/hV2"; mkdir -p "$hV2"
fixtureV2="$work/caseV2-fixture"; build_fixture "$fixtureV2"
cat > "$fixtureV2/scripts/adopt.sh" <<STUB
#!/usr/bin/env bash
printf 'adopt.sh: %s\n' "\$*" >> "$fixtureV2/adopt-calls.log"
exit 1
STUB
chmod +x "$fixtureV2/scripts/adopt.sh"
set +e
out2=$(PATH="$cV2" HOME="$hV2" USERPROFILE="$(winpath "$hV2")" HIMMELCTL_CACHE_DIR="$(winpath "$hV2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hV2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureV2")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$cacheV")" \
      </dev/null 2>&1); rc2=$?
set -e
[ "$rc2" -eq 1 ] || fail "caseV2: a failed adopt.sh should propagate rc=1 (got rc=$rc2): $out2"
[ -f "$fixtureV2/setup-calls.log" ] \
  && fail "caseV2: a failed adopt.sh must abort BEFORE the dev overlay runs (got: $(cat "$fixtureV2/setup-calls.log"))"
grepq "$out2" -F 'setup.ps1 stub' \
  && fail "caseV2: a failed adopt.sh must abort BEFORE the dev overlay (setup.ps1) runs (got: $out2)"
echo "ok: caseV2 a failed adopt.sh aborts before the dev overlay ever runs"

# ── Case W (HIMMEL-2308): --contribute outside a himmel checkout -> clear ────
# error, nothing shells out. HIMMELCTL_REPO_ROOT points at a fixture that
# carries NEITHER setup.sh nor setup.ps1 — the exact signal contributeCheckoutOk()
# reads — so this is a targeted unit of the "clear error elsewhere" spec line,
# independent of whatever the real host's own himmel checkout looks like.
stubW="$work/caseW"; mkdir -p "$stubW"
cW=$(build_path "$stubW" bash git jq python3 npm -- )
hW="$work/hW"; mkdir -p "$hW"
fixtureW="$work/caseW-fixture"; mkdir -p "$fixtureW/scripts"
# Deliberately no scripts/adopt.sh, no scripts/setup.sh, no scripts/setup.ps1.
set +e
outW=$(PATH="$cW" HOME="$hW" USERPROFILE="$(winpath "$hW")" HIMMELCTL_CACHE_DIR="$(winpath "$hW.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hW.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureW")" \
      "$node_bin" "$wizard" install --dry-run --contribute \
      </dev/null 2>&1); rcW=$?
set -e
[ "$rcW" -ne 0 ] || fail "caseW: --contribute outside a himmel checkout should exit non-zero (got rc=$rcW): $outW"
grepq "$outW" -F -- '--contribute requires a himmel checkout' \
  || fail "caseW: expected the clear checkout-validity error (got: $outW)"
grepq "$outW" -E '^\? ' \
  && fail "caseW: the checkout-validity refusal must happen before any question is asked (got: $outW)"
echo "ok: caseW --contribute outside a himmel checkout -> clear error, nothing runs"

echo "PASS"
