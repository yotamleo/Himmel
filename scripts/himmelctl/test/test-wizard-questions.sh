#!/usr/bin/env bash
# test-wizard-questions.sh — hermetic tests for the himmelctl install wizard's
# question engine (HIMMEL-887 T2) + answer schema/cache (T3). Mirrors
# test-wizard-preflight.sh conventions: a stub PATH built via
# scripts/lib/hermetic-path.sh, a fake HOME, node launched by absolute path so
# the wizard's tool detection sees ONLY the stub dir.
#
# HIMMEL-2308: the old role fork (adopter|contributor, detected from a git
# origin + .himmel-dev marker) is GONE. Every install now walks the SAME
# question set, first asking `profile` (starter|luna|operator|custom, a
# numbered menu with per-option help text) instead of `role`. A profile only
# SEEDS the default answer at each later question (PROFILE_PRESETS in
# bin.js) — it never skips one. `devOverlay` (the old contributor-dev
# behavior) is no longer a question at all; it is set only by the
# --contribute CLI flag (covered here + test-wizard-derive.sh for the
# checkout-validity + derivation side).
#
# Covers (T2):
#   1. starter-profile stdin sequence -> 7 main questions (profile+scope+
#      vault+handover+pluginSet, then the HIMMEL-862 adopter-profile pair
#      lanes+alwaysOn) + the answer summary with profile=starter,
#      devOverlay=false, and no luna/secretsWalk/bridge keys (vault=none
#      never unlocks them).
#   2. profile preset seeding: luna seeds vault=default-template (unlocking
#      the cascading second-brain questions), operator seeds the richest
#      defaults (vault=existing, handover=external, alwaysOn=yes, cadence=on,
#      bridge=on) while EVERY question is still asked, and custom keeps
#      today's plain defaults (vault=none, handover=inline, alwaysOn=no).
#      Verified via the printed `(default: X)` headers with stdin closed
#      right after the profile answer — every later ask() then returns ''
#      (closed-stdin default acceptance), so the WHOLE chain still asks and
#      answers with defaults, proving nothing is silently skipped.
#   3. invalid profile answer -> the question repeats once, then accepts.
#   4. non-interactive without --from-profile -> refuses (non-zero +
#      message), no hang, and the question engine never starts.
#   7. --contribute sets devOverlay=true without ever asking a question, and
#      does not change the number of questions asked.
#   8. --default-scope user changes only the scope question's default;
#      accepting it still prints the plan normally and preserves confirmation.
# Covers (T3):
#   5. interactive run writes the v2 (schemaVersion:2, profile/devOverlay)
#      cache; --from-profile on it reproduces the same answer JSON with ZERO
#      prompts.
#   6. --from-profile on a v2 cache missing `profile` -> non-zero + message,
#      no hang (rc=2 via the strict schema validator); an unknown
#      schemaVersion value fails loud the same way.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# node is launched by absolute path so a stub-only PATH can be hermetic without
# making node itself unlaunchable.
node_bin=$(command -v node)

export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# HIMMEL-1446 r3: a non-dry-run install (case5 --from-profile) reaches
# applyHimmelctlPathShim(), whose default binDir is the operator's REAL
# ~/.local/bin (win32 ignores HOME entirely). Isolate binDir for the WHOLE
# suite so no case touches the real bin dir — mirrors test-wizard-update.sh /
# test-wizard-uninstall.sh. winpath'd so win32 node resolves it cleanly.
HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

# build_path <stub_dir> <present_tools...> -- <absent_tools...>
# (Copied from test-wizard-preflight.sh: link the named present tools off the
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

# Count main (enum) question headers in a captured output blob. Path sub-
# prompts carry no '[' so they are excluded.
count_questions() { printf '%s' "$1" | grep -cE '^\? .*\[' || true; }

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf-into-`grep -q` is a trap under this file's `set -o pipefail`:
# grep -q exits the instant it matches, printf then takes SIGPIPE writing the
# remainder, and pipefail reports the PIPELINE as failed — so a SUCCESSFUL match
# returns non-zero whenever the match lands early in a large input (the outcome
# depends on how far down the match sits). A here-string is not a pipeline, so
# the status is grep's own verdict alone. (grep -c, as in count_questions above,
# is unaffected: it reads all input before printing, so it never exits early and
# the producer never takes SIGPIPE.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# ── Case 1: starter profile -> 7 questions + summary profile=starter ─────────
stub1="$work/case1"; mkdir -p "$stub1"
c1path=$(build_path "$stub1" bash jq python3 npm -- )
h1="$work/h1"; mkdir -p "$h1"
set +e
out=$(PATH="$c1path" HOME="$h1" USERPROFILE="$(winpath "$h1")" HIMMELCTL_CACHE_DIR="$(winpath "$h1.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h1.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
starter
project
none
inline
lean

no
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case1: starter-profile run should succeed (got rc=$rc)"
qs=$(count_questions "$out")
[ "$qs" -eq 7 ] \
  || fail "case1: starter profile + vault=none should ask 7 main questions (got $qs): $out"
grepq "$out" '"schemaVersion": 2' \
  || fail "case1: cache/summary should carry schemaVersion 2 (got: $out)"
grepq "$out" '"profile": "starter"' \
  || fail "case1: summary should show profile=starter (got: $out)"
grepq "$out" '"devOverlay": false' \
  || fail "case1: summary should show devOverlay=false (--contribute not passed) (got: $out)"
grepq "$out" '"role"' \
  && fail "case1: v2 answers must never carry a role field (got: $out)"
grepq "$out" '? scope \[' \
  || fail "case1: scope should be asked (universal now) (got: $out)"
grepq "$out" '"luna"' \
  && fail "case1: vault=none must not unlock/fabricate a luna section (got: $out)"
grepq "$out" '"bridge"' \
  && fail "case1: vault=none must not unlock/fabricate a bridge section (got: $out)"
# HIMMEL-2303: the CR-floor disclosure prints AT the lanes decision point —
# before the lanes prompt, every run, regardless of the eventual answer
# (case1 accepts the (empty, HIMMEL-2352) lanes default, still no codex/hermes
# opt-in).
grepq "$out" 'CR_REQUIRE_CROSS_MODEL cannot be satisfied' \
  || fail "case1: the lanes question should disclose the CR-floor consequence (got: $out)"
disclosure_before_prompt=$(printf '%s' "$out" | awk '
  /Claude-only, and CR_REQUIRE_CROSS_MODEL/ { seen = 1 }
  /^\? lanes \[/ { print (seen ? "yes" : "no"); exit }
')
[ "$disclosure_before_prompt" = "yes" ] \
  || fail "case1: the CR-floor disclosure must print BEFORE the lanes prompt, not after (got: $out)"
echo "ok: case1 starter profile -> 7 questions + summary profile=starter/devOverlay=false, no fabricated luna/bridge; CR-floor disclosure prints before lanes"

# ── Case 2: profile preset seeding (luna/operator/custom) ──────────────────
# Every later question is still asked (confirmed via headers) — the preset
# only changes the DEFAULT shown. Feeding just the profile answer and closing
# stdin immediately makes every subsequent ask() resolve to '' (closed-stdin
# default acceptance, makeAsk()'s own contract), so the whole remaining chain
# walks through on defaults without needing a hand-counted stdin sequence.
stub2="$work/case2"; mkdir -p "$stub2"
c2path=$(build_path "$stub2" bash jq python3 npm -- )
h2="$work/h2"; mkdir -p "$h2"
set +e
outLuna=$(PATH="$c2path" HOME="$h2" USERPROFILE="$(winpath "$h2")" HIMMELCTL_CACHE_DIR="$(winpath "$h2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<< "luna"); rcLuna=$?
set -e
[ "$rcLuna" -eq 0 ] || fail "case2(luna): should succeed (got rc=$rcLuna): $outLuna"
grepq "$outLuna" -F '? vault [none|default-template|existing] (default: default-template)' \
  || fail "case2(luna): the luna preset should seed vault default=default-template (got: $outLuna)"
grepq "$outLuna" -F '? cadences —' \
  || fail "case2(luna): seeding a vault should unlock the cascading second-brain questions (got: $outLuna)"
grepq "$outLuna" '"profile": "luna"' \
  || fail "case2(luna): summary should record profile=luna (got: $outLuna)"

stub2b="$work/case2b"; mkdir -p "$stub2b"
c2bpath=$(build_path "$stub2b" bash jq python3 npm -- )
h2b="$work/h2b"; mkdir -p "$h2b"
set +e
outOp=$(PATH="$c2bpath" HOME="$h2b" USERPROFILE="$(winpath "$h2b")" HIMMELCTL_CACHE_DIR="$(winpath "$h2b.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h2b.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<< "operator"); rcOp=$?
set -e
[ "$rcOp" -eq 0 ] || fail "case2(operator): should succeed (got rc=$rcOp): $outOp"
grepq "$outOp" -F '? vault [none|default-template|existing] (default: existing)' \
  || fail "case2(operator): should seed vault default=existing (got: $outOp)"
grepq "$outOp" -F '? handover [inline|external] (default: external)' \
  || fail "case2(operator): should seed handover default=external (got: $outOp)"
grepq "$outOp" -F '(default: yes)' \
  || fail "case2(operator): should seed alwaysOn default=yes (got: $outOp)"
grepq "$outOp" -F '? cadences — recurring scheduled jobs to arm now [pipeline,qmd,graphmap|none] (default: pipeline,qmd,graphmap)' \
  || fail "case2(operator): should seed cadences default=pipeline,qmd,graphmap (got: $outOp)"
grepq "$outOp" -F '? configure the telegram bridge (voice/text ingestion)? [off|on] (default: on)' \
  || fail "case2(operator): should seed bridge default=on (got: $outOp)"
# HIMMEL-2346: the operator preset seeds whisperModel=ggml-large-v3-turbo.bin
# (HIMMEL-2307 capture: that's what the maintainer machine actually runs) —
# PROFILE_PRESETS carried NO whisper field at all before this fix, so the
# question fell through to the schema default 'small' regardless of profile.
grepq "$outOp" -F '? whisper model [tiny|base|small|medium|large-v3|large-v3-turbo|custom] (default: large-v3-turbo)' \
  || fail "case2(operator): should seed whisper model default=large-v3-turbo (got: $outOp)"
# Every has-it-or-not question is STILL ASKED under operator — seeding never
# skips a question (locked spec). Substring checks (not the line-anchored
# count_questions helper): once stdin closes early, makeAsk()'s closed-stdin
# fast path skips its usual separating newline, so later question headers can
# land glued onto the previous prompt's "> " rather than at column 0 — a
# formatting quirk of this deliberately-early-EOF technique, not a sign the
# question was skipped (the printed answer JSON above already proves each of
# these was actually asked and answered).
#
# The bridge-persistence consent prompt ("install bridge persistence now") is
# the one EXCEPTION to "every question is still asked": bin.js only asks it
# when adopterProfileLib.bridgePersistenceArtifact() names an installer for
# THIS platform (win32 scheduled task / linux systemd unit); on any other
# platform (e.g. macOS) it prints a skip notice instead (see bin.js
# askQuestions()'s bridge subwalk). Ask the SAME shared function bin.js
# consults, rather than reimplementing the platform mapping here, so this
# stays correct if that mapping ever changes.
adopter_profile_lib_w="$(winpath "$repo_root/scripts/himmelctl/lib/adopter-profile.js")"
bridge_persist_artifact=$("$node_bin" -e "process.stdout.write(require('$adopter_profile_lib_w').bridgePersistenceArtifact() || '')")
_needles=('? vault path' '? handover path' '? pluginSet' '? lanes' \
          'always-on machine' '? cadences —' \
          'Protected Health Information' \
          "personal/medical vault this machine's agents must never send" \
          'walk through luna secrets' \
          'configure the telegram bridge' '? bridge .env path' \
          '? whisper CLI path' '? whisper model [')
# HIMMEL-2346: '? whisper model filename' (the old free-text prompt) is now
# CONDITIONAL — only reached if the operator picks the 'custom' menu entry,
# which closed-stdin default-acceptance never does (the seeded default here
# is large-v3-turbo, an enum pick, not custom) — so it is deliberately absent
# from the unconditional needle list above, unlike every other question here.
if [ -n "$bridge_persist_artifact" ]; then
  _needles+=('install bridge persistence now')
fi
for _needle in "${_needles[@]}"; do
  grepq "$outOp" -F "$_needle" \
    || fail "case2(operator): operator must still ask every question, not skip '$_needle' (got: $outOp)"
done
if [ -z "$bridge_persist_artifact" ]; then
  grepq "$outOp" -F 'has no installer for platform' \
    || fail "case2(operator): a platform with no bridge-persistence installer should print the skip notice instead of asking (got: $outOp)"
  grepq "$outOp" -F 'install bridge persistence now' \
    && fail "case2(operator): a platform with no bridge-persistence installer must NOT ask the consent prompt (got: $outOp)"
fi

stub2c="$work/case2c"; mkdir -p "$stub2c"
c2cpath=$(build_path "$stub2c" bash jq python3 npm -- )
h2c="$work/h2c"; mkdir -p "$h2c"
set +e
outCustom=$(PATH="$c2cpath" HOME="$h2c" USERPROFILE="$(winpath "$h2c")" HIMMELCTL_CACHE_DIR="$(winpath "$h2c.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h2c.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<< "custom"); rcCustom=$?
set -e
[ "$rcCustom" -eq 0 ] || fail "case2(custom): should succeed (got rc=$rcCustom): $outCustom"
grepq "$outCustom" -F '? vault [none|default-template|existing] (default: none)' \
  || fail "case2(custom): custom keeps today's plain vault default=none, no seeding (got: $outCustom)"
grepq "$outCustom" -F '? handover [inline|external] (default: inline)' \
  || fail "case2(custom): custom keeps the plain handover default=inline (got: $outCustom)"
echo "ok: case2 profile presets seed defaults (luna/operator) without ever skipping a question; custom keeps plain defaults"

# ── Case 3: invalid profile answer -> question repeats once then accepts ────
stub3="$work/case3"; mkdir -p "$stub3"
c3path=$(build_path "$stub3" bash jq python3 npm -- )
h3="$work/h3"; mkdir -p "$h3"
set +e
out=$(PATH="$c3path" HOME="$h3" USERPROFILE="$(winpath "$h3")" HIMMELCTL_CACHE_DIR="$(winpath "$h3.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h3.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
bogus
starter
project
none
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case3: invalid-then-valid run should succeed (got rc=$rc)"
reprompts=$(printf '%s' "$out" | grep -cE '^\? profile \[' || true)
[ "$reprompts" -eq 2 ] \
  || fail "case3: profile header should appear twice (invalid then accept) (got $reprompts): $out"
echo "ok: case3 invalid enum -> profile re-prompted once then accepted"

# ── Case 4: non-interactive without --from-profile -> refuse, no hang ─────────
stub4="$work/case4"; mkdir -p "$stub4"
c4path=$(build_path "$stub4" bash jq python3 npm -- )
h4="$work/h4"; mkdir -p "$h4"
set +e
out=$(PATH="$c4path" HOME="$h4" USERPROFILE="$(winpath "$h4")" HIMMELCTL_CACHE_DIR="$(winpath "$h4.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h4.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "case4: non-interactive no-profile should exit non-zero (got $rc)"
grepq "$out" 'requires --from-profile' \
  || fail "case4: should print a --from-profile hint (got: $out)"
grepq "$out" -E '^\? ' \
  && fail "case4: non-interactive refuse must NOT start the question engine (got: $out)"
echo "ok: case4 non-interactive no profile -> refuse + message, no hang, no question printed"

# ── Case 5: interactive writes cache; --from-profile round-trips, zero prompts ─
# Under Git Bash, HOME does NOT propagate into node.exe children, so the cache
# dir is redirected via HIMMELCTL_CACHE_DIR (Windows-shaped for node); a POSIX
# alias of the same dir is kept for bash file ops.
stub5="$work/case5"; mkdir -p "$stub5"
c5path=$(build_path "$stub5" bash jq python3 npm -- )
h5="$work/h5"; mkdir -p "$h5"
cache5_posix="$work/case5-cache"; mkdir -p "$cache5_posix"
cache5_node=$(winpath "$cache5_posix")
set +e
out=$(PATH="$c5path" HOME="$h5" USERPROFILE="$(winpath "$h5")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache5_node" HIMMEL_LUNA_CONFIG_PATH="$cache5_node-luna-config.json" \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
starter
project
none
inline
lean
none
no
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case5: interactive run should succeed (got rc=$rc)"
cachefile="$cache5_posix/install-profile.json"
[ -f "$cachefile" ] || fail "case5: cache file should be written (expected $cachefile)"
cache_body=$(cat "$cachefile")
# v2 Draft-A schema sanity on the written cache.
grepq "$cache_body" '"schemaVersion": 2' \
  || fail "case5: cache should record schemaVersion 2 (got: $cache_body)"
grepq "$cache_body" '"profile": "starter"' \
  || fail "case5: cache should record profile=starter (got: $cache_body)"
grepq "$cache_body" '"devOverlay": false' \
  || fail "case5: cache should record devOverlay=false (got: $cache_body)"
# HIMMEL-2348: `tier` was a write-only placeholder no reader ever consumed.
# Assert its ABSENCE so a future edit cannot silently reintroduce an unread
# field into every profile this wizard writes.
if grepq "$cache_body" '"tier"'; then
  fail "case5: cache must NOT carry the dropped tier placeholder (got: $cache_body)"
fi
grepq "$cache_body" '"lanes": \[\]' \
  || fail "case5: cache should record the answered empty lane set (got: $cache_body)"
grepq "$cache_body" '"alwaysOn": false' \
  || fail "case5: cache should record the answered alwaysOn=no (got: $cache_body)"
# Now replay the cache non-interactively: ZERO prompts + byte-stable JSON.
# Non-interactive --from-profile (T4) skips the confirm and shells out for
# real, so HIMMELCTL_REPO_ROOT is pointed at a throwaway fixture carrying a
# harmless no-op adopt.sh stub — keeps this replay hermetic (no real adopt.sh
# execution against the checkout) without changing what's being asserted here
# (the --from-profile round-trip, not T4 derivation — that's covered by
# test-wizard-derive.sh).
fixture5="$work/case5-fixture"; mkdir -p "$fixture5/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture5/scripts/adopt.sh"
chmod +x "$fixture5/scripts/adopt.sh"
set +e
out_b=$(PATH="$c5path" HOME="$h5" USERPROFILE="$(winpath "$h5")" HIMMELCTL_CACHE_DIR="$(winpath "$h5.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h5.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
        HIMMELCTL_REPO_ROOT="$(winpath "$fixture5")" \
        "$node_bin" "$wizard" install --from-profile "$(winpath "$cachefile")" \
        </dev/null 2>&1); rc_b=$?
set -e
[ "$rc_b" -eq 0 ] || fail "case5: --from-profile should succeed (got rc=$rc_b): $out_b"
prompts=$(printf '%s' "$out_b" | grep -cE '^\? ' || true)
[ "$prompts" -eq 0 ] \
  || fail "case5: --from-profile must ask ZERO questions (got $prompts): $out_b"
# Extract the JSON block node printed: from the first '{' line to the first
# bare '}' line (the top-level close — nested closes are indented, e.g.
# `  },`, so they don't match). T4 prints a `derived: ...` line right after
# the JSON, which a to-end-of-output extraction would now swallow.
json_b=$(printf '%s' "$out_b" | sed -n '/^{/,/^}/p')
[ "$json_b" = "$cache_body" ] \
  || fail "case5: --from-profile should reproduce the cache byte-stable
got:      <$json_b>
expected: <$cache_body>"
echo "ok: case5 interactive writes v2 cache; --from-profile round-trips byte-stable, zero prompts"

# ── Case 6: --from-profile on a v2 cache missing `profile`/bad schemaVersion ─
stub6="$work/case6"; mkdir -p "$stub6"
c6path=$(build_path "$stub6" bash jq python3 npm -- )
h6="$work/h6"; mkdir -p "$h6"
bad="$work/bad-profile.json"
# Valid JSON, valid v2 shape otherwise, but NO `profile` field.
cat > "$bad" <<JSON
{"schemaVersion":2,"devOverlay":false,"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"alwaysOn":false}
JSON
set +e
out=$(PATH="$c6path" HOME="$h6" USERPROFILE="$(winpath "$h6")" HIMMELCTL_CACHE_DIR="$(winpath "$h6.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h6.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$bad")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "case6: missing-profile v2 cache should exit non-zero (got $rc)"
grepq "$out" -i "field 'profile'" \
  || fail "case6: should name the missing profile field (got: $out)"
# No hang: it returned (we reached here). And it must not have started prompting.
grepq "$out" -E '^\? ' \
  && fail "case6: missing-profile cache must NOT start the question engine (got: $out)"
echo "ok: case6a --from-profile missing profile -> non-zero + message, no hang"

badVer="$work/bad-schemaversion.json"
cat > "$badVer" <<JSON
{"schemaVersion":3,"profile":"custom","devOverlay":false,"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"alwaysOn":false}
JSON
set +e
outVer=$(PATH="$c6path" HOME="$h6" USERPROFILE="$(winpath "$h6")" HIMMELCTL_CACHE_DIR="$(winpath "$h6.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h6.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$badVer")" \
      </dev/null 2>&1); rcVer=$?
set -e
[ "$rcVer" -ne 0 ] || fail "case6b: unknown schemaVersion should exit non-zero (got $rcVer)"
grepq "$outVer" -i "field 'schemaVersion'" \
  || fail "case6b: should name the bad schemaVersion field (got: $outVer)"
echo "ok: case6b --from-profile with an unknown schemaVersion -> non-zero + message naming the field"

# HIMMEL-2308/HIMMEL-2304: a v2 profile with pluginSet=full must fail loud
# (exit 2, naming the field) rather than validate and silently no-op the
# plugin step. Only the LEGACY (no-schemaVersion) branch keeps accepting
# 'full', as the migration path for a pre-2304 cache.
fullV2="$work/v2-pluginset-full.json"
cat > "$fullV2" <<JSON
{"schemaVersion":2,"profile":"custom","devOverlay":false,"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"full","lanes":[],"alwaysOn":false}
JSON
set +e
outFullV2=$(PATH="$c6path" HOME="$h6" USERPROFILE="$(winpath "$h6")" HIMMELCTL_CACHE_DIR="$(winpath "$h6.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h6.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$fullV2")" \
      </dev/null 2>&1); rcFullV2=$?
set -e
[ "$rcFullV2" -eq 2 ] || fail "case6c: v2 profile with pluginSet=full should exit 2 (got $rcFullV2): $outFullV2"
grepq "$outFullV2" -i "field 'pluginSet'" \
  || fail "case6c: should name the pluginSet field (got: $outFullV2)"
echo "ok: case6c --from-profile v2 with pluginSet=full -> exit 2 + message naming pluginSet"

# Fixture repo root shared by case6d/e below — every --from-profile
# invocation here gets it, even the exit-2 ones, so a future validator
# regression that lets one of these fall through to the derived adopt.sh
# shell-out hits a harmless stub instead of the real checkout. The
# codex-sweep-cadence.sh stub is needed by case6d-asymmetry, which actually
# arms the cadence (a rc=127 missing-script arm failure would fail the whole
# install run, masking the validation assertion being made there).
fixture6d="$work/case6d-fixture"; mkdir -p "$fixture6d/scripts/cleanup"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture6d/scripts/adopt.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture6d/scripts/cleanup/codex-sweep-cadence.sh"
chmod +x "$fixture6d/scripts/adopt.sh" "$fixture6d/scripts/cleanup/codex-sweep-cadence.sh"

# HIMMEL-2302 CR round 1 Fix 1: a `requires:'vault'` cadence (pipeline/qmd/
# graphmap) armed while vault.mode='none' validates the two fields
# independently, then breaks/no-ops at arm time -- the validates-then-breaks
# class this wizard forbids. loadProfile must now cross-validate and fail
# loud (exit 2, naming the cadence id and the vault requirement) BEFORE any
# side effect.
vaultCadence="$work/vault-cadence-conflict.json"
cat > "$vaultCadence" <<JSON
{"schemaVersion":2,"profile":"custom","devOverlay":false,"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false,"cadences":{"pipeline":"armed"}}
JSON
set +e
outVaultCadence=$(PATH="$c6path" HOME="$h6" USERPROFILE="$(winpath "$h6")" HIMMELCTL_CACHE_DIR="$(winpath "$h6.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h6.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixture6d")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$vaultCadence")" \
      </dev/null 2>&1); rcVaultCadence=$?
set -e
[ "$rcVaultCadence" -eq 2 ] || fail "case6d: vault=none + cadences.pipeline=armed should exit 2 (got $rcVaultCadence): $outVaultCadence"
grepq "$outVaultCadence" -F -- 'pipeline' \
  || fail "case6d: should name the offending cadence id 'pipeline' (got: $outVaultCadence)"
grepq "$outVaultCadence" -i "vault" \
  || fail "case6d: should name the unmet vault requirement (got: $outVaultCadence)"
echo "ok: case6d --from-profile with a requires:vault cadence armed while vault.mode=none -> exit 2 naming the cadence and vault"

# HIMMEL-2302 CR round 1 Fix 1 (documented asymmetry, pinned so it is never
# "fixed" into symmetry): a `requires:'lane:codex'` cadence (codex-sweep) is
# NOT gated on whether 'codex' is actually in `lanes` -- naming it armed in a
# hand-reviewed profile IS the consent, same principle as the existing lanes
# comment above. vault.mode=none + cadences.codex-sweep=armed with codex
# absent from lanes must VALIDATE (not exit 2) here; the end-to-end arm is
# covered by test-wizard-cadence-per-unit.sh (needs a fixture repo/script).
codexCadence="$work/codex-cadence-no-lane.json"
cat > "$codexCadence" <<JSON
{"schemaVersion":2,"profile":"custom","devOverlay":false,"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false,"cadences":{"codex-sweep":"armed"}}
JSON
set +e
outCodexCadence=$(PATH="$c6path" HOME="$h6" USERPROFILE="$(winpath "$h6")" HIMMELCTL_CACHE_DIR="$(winpath "$h6.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h6.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixture6d")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$codexCadence")" \
      </dev/null 2>&1); rcCodexCadence=$?
set -e
[ "$rcCodexCadence" -eq 0 ] \
  || fail "case6d-asymmetry: vault=none + cadences.codex-sweep=armed with no codex lane should VALIDATE (exit 0) — requires:lane:codex is a consent surface, not enforced (got $rcCodexCadence): $outCodexCadence"
echo "ok: case6d-asymmetry --from-profile with a requires:lane:codex cadence armed and codex absent from lanes VALIDATES (documented consent asymmetry, not a bug)"

# HIMMEL-2302 CR round 1 Fix 3: the wizard never writes an empty top-level
# `cadences: {}` -- resolveCadenceDispositions() treats ANY present
# `cadences` section as authoritative, so a hand-authored `{}` would silently
# suppress a legacy `luna.cadenceEnabled` answer with nothing actually named.
# Must fail loud, naming the field.
emptyCadences="$work/empty-cadences.json"
cat > "$emptyCadences" <<JSON
{"schemaVersion":2,"profile":"custom","devOverlay":false,"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false,"cadences":{}}
JSON
set +e
outEmptyCadences=$(PATH="$c6path" HOME="$h6" USERPROFILE="$(winpath "$h6")" HIMMELCTL_CACHE_DIR="$(winpath "$h6.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h6.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixture6d")" \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$emptyCadences")" \
      </dev/null 2>&1); rcEmptyCadences=$?
set -e
[ "$rcEmptyCadences" -eq 2 ] || fail "case6e: an empty cadences:{} should exit 2 (got $rcEmptyCadences): $outEmptyCadences"
grepq "$outEmptyCadences" -F -- "field 'cadences'" \
  || fail "case6e: should name the 'cadences' field (got: $outEmptyCadences)"
echo "ok: case6e --from-profile with an empty cadences:{} -> exit 2 naming the field"

# ── Case 7 (HIMMEL-2308): --contribute sets devOverlay without a question ───
stub7="$work/case7"; mkdir -p "$stub7"
c7path=$(build_path "$stub7" bash jq python3 npm -- )
h7="$work/h7"; mkdir -p "$h7"
set +e
out=$(PATH="$c7path" HOME="$h7" USERPROFILE="$(winpath "$h7")" HIMMELCTL_CACHE_DIR="$(winpath "$h7.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h7.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --contribute 2>&1 <<INPUT
starter
project
none
inline
lean
none
no
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case7: --contribute run should succeed (got rc=$rc): $out"
qs=$(count_questions "$out")
[ "$qs" -eq 7 ] \
  || fail "case7: --contribute must not change the question count (got $qs): $out"
grepq "$out" '"devOverlay": true' \
  || fail "case7: --contribute should record devOverlay=true (got: $out)"
grepq "$out" -iE '\? .*contribut' \
  && fail "case7: devOverlay must NEVER be its own question (got: $out)"
echo "ok: case7 --contribute sets devOverlay=true without asking a question or changing the question count"

# ── Case 8: explicit user-scope hint changes the confirmable default only ────
stub8="$work/case8"; mkdir -p "$stub8"
c8path=$(build_path "$stub8" bash jq python3 npm -- )
h8="$work/h8"; mkdir -p "$h8"
set +e
out=$(PATH="$c8path" HOME="$h8" USERPROFILE="$(winpath "$h8")" HIMMELCTL_CACHE_DIR="$(winpath "$h8.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h8.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run --default-scope user 2>&1 <<INPUT
starter

none
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case8: user-scope hint run should succeed (got rc=$rc): $out"
grepq "$out" -F '? scope [project|user] (default: user)' \
  || fail "case8: scope question should display user as its default (got: $out)"
grepq "$out" '"scope": "user"' \
  || fail "case8: accepting the scope default should record user (got: $out)"
grepq "$out" -E 'derived:.*adopt\.sh --profile core --scope user$' \
  || fail "case8: accepted hint should derive the normal user-scope plan (got: $out)"
echo "ok: case8 --default-scope user -> confirmable scope default=user + normal derived plan"

# ── Case 9 (HIMMEL-2288): numbered option selection ────────────────────────
# Every enum question prints a numbered 1..n menu with the recommended default
# marked; the operator may answer with either the number OR the literal
# option word. To actually PROVE numeric input is parsed (rather than every
# answer coincidentally landing on its own default), this case picks the
# NON-default option by number for lanes and always-on, and asserts the
# recorded answers reflect the non-default choice.
stub9="$work/case9"; mkdir -p "$stub9"
c9path=$(build_path "$stub9" bash jq python3 npm -- )
h9="$work/h9"; mkdir -p "$h9"
set +e
out=$(PATH="$c9path" HOME="$h9" USERPROFILE="$(winpath "$h9")" HIMMELCTL_CACHE_DIR="$(winpath "$h9.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h9.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
1
1
1
1
1
2
1
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case9: numbered-answer run should succeed (got rc=$rc): $out"
grepq "$out" '"profile": "starter"' \
  || fail "case9: answering '1' for profile should record starter (got: $out)"
grepq "$out" '"pluginSet": "lean"' \
  || fail "case9: answering '1' for pluginSet (its only option) should record lean (got: $out)"
grepq "$out" '"hermes"' \
  || fail "case9: answering '2' for lanes (codex|hermes, default none) should record hermes (got: $out)"
grepq "$out" '"codex"' \
  && fail "case9: answering '2' for lanes should select ONLY hermes, not codex nor the empty default — proves the digit was parsed, not defaulted (got: $out)"
grepq "$out" '"alwaysOn": true' \
  || fail "case9: answering '1' for always-on (yes|no, default no) should record the NON-default true — proves the digit was parsed, not defaulted (got: $out)"
grepq "$out" -F '  1) starter (recommended — press Enter) —' \
  || fail "case9: the profile prompt must print a numbered menu with the default marked + help text (got: $out)"
grepq "$out" -F '  2) luna —' \
  || fail "case9: the profile prompt must list every option by number with help text (got: $out)"
echo "ok: case9 numbered option selection parses digits (proven via non-default picks) and prints the help menu"

# ── Case 10 (HIMMEL-2288): consent/PHI prompts keep explicit wording ───────
# The PHI declaration and the two "consented, --dry-run shows it" mutation
# consent prompts (disarm cadence, bridge persistence install) must NEVER
# become a numbered menu — a source-level check rather than a live fixture,
# since exercising them interactively needs a full vault!=none + bridge=on
# question chain that adds no coverage beyond this direct assertion.
wizard_src=$(cat "$wizard")
grepq "$wizard_src" -F -- '? does this vault handle Protected Health Information (PHI)? [yes|no] (default: no)\n> ' \
  || fail "case10: the PHI declaration prompt must keep its exact explicit yes/no wording, never a numbered menu"
# HIMMEL-2347: the two new personal/medical-vault prompts (yes/no declaration
# + the .salus-marker consent) are the SAME consent-grade class as the PHI
# declaration above — both must be askEnum() calls with explicit wording, not
# askNumberedEnum().
grepq "$wizard_src" -F -- "? do you keep a personal/medical vault this machine's agents must never send to cloud backends? [yes|no] (default: no)\\n> " \
  || fail "case10: the personal/medical vault declaration prompt must keep its exact explicit yes/no wording, never a numbered menu"
grepq "$wizard_src" -F -- 'now (marks this vault PHI to every local guard that checks it; consented, --dry-run shows it) [yes|no] (default: no)\n> ' \
  || fail "case10: the .salus-marker consent prompt must keep its exact explicit yes/no wording, never a numbered menu"
# HIMMEL-2302: the prompt now names the declined units dynamically
# (`${declinedIds.join(', ')}`), so the exact-string check becomes two
# substring checks bracketing the interpolation — still proving the SAME
# explicit yes/no wording, never a numbered menu. Deliberately
# single-quoted: a literal `${declinedIds.join(` template-literal fragment
# searched for in bin.js's own SOURCE TEXT, not a shell expansion.
# shellcheck disable=SC2016
grepq "$wizard_src" -F -- '`? disarm any existing cadence jobs now for: ${declinedIds.join(' \
  || fail "case10: the disarm-cadence consent prompt must keep its exact prefix wording, never a numbered menu"
grepq "$wizard_src" -F -- "(each unit's own disarm subcommand; consented, --dry-run shows it) [yes|no] (default: no)\\n> " \
  || fail "case10: the disarm-cadence consent prompt must keep its exact suffix wording, never a numbered menu"
# Deliberately single-quoted: this is a literal ${persistArtifact} template
# placeholder searched for in bin.js's own SOURCE TEXT, not a shell expansion.
# shellcheck disable=SC2016
grepq "$wizard_src" -F -- 'install bridge persistence now (${persistArtifact}; consented, --dry-run shows it) [yes|no] (default: no)\n> ' \
  || fail "case10: the bridge-persistence consent prompt must keep its exact explicit yes/no wording, never a numbered menu"
# CR round 1 [codex-1]: numeric-index acceptance used to live in askEnum()
# itself, shared by every caller — including the three consent/PHI prompts
# above, so a bare "1"/"2" silently satisfied a PHI declaration or a
# machine-mutation consent that was supposed to require typed yes/no. Prove
# structurally that askEnum() (the function those three call, unlike the
# numbered questions which now call the separate askNumberedEnum()) carries
# no digit-parsing logic: extract just its own function body and assert it
# has no [0-9] branch.
ask_enum_body=$(awk '/^async function askEnum\(/{f=1} f{print; if (/^}/) exit}' "$wizard")
[ -n "$ask_enum_body" ] \
  || fail "case10: could not locate askEnum()'s function body in bin.js — has it been renamed?"
grepq "$ask_enum_body" '\[0-9\]' \
  && fail "case10: askEnum() must NOT accept a bare numeric index — that would let a digit silently satisfy a consent/PHI prompt (got: $ask_enum_body)"
echo "ok: case10 PHI/consent prompts are untouched by the numbered-menu conversion, and askEnum() itself accepts no bare digit"

# ── Case 11 (HIMMEL-2304): pluginSet=full is DROPPED from the wizard ───────
# The pluginSet question stays (so every existing stdin sequence answering
# 'lean' keeps working — case1 above proves that), but 'full' is no longer a
# valid answer: typing it re-prompts exactly like any other invalid enum
# value (askEnum's existing re-prompt loop, unchanged), and the printed menu
# offers only the single 'lean' option.
stub11="$work/case11"; mkdir -p "$stub11"
c11path=$(build_path "$stub11" bash jq python3 npm -- )
h11="$work/h11"; mkdir -p "$h11"
set +e
out=$(PATH="$c11path" HOME="$h11" USERPROFILE="$(winpath "$h11")" HIMMELCTL_CACHE_DIR="$(winpath "$h11.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h11.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
starter
project
none
inline
full
lean

no
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case11: run answering 'full' then 'lean' should succeed (got rc=$rc): $out"
grepq "$out" '"pluginSet": "lean"' \
  || fail "case11: the retry ('lean') should be the recorded answer (got: $out)"
grepq "$out" '"pluginSet": "full"' \
  && fail "case11: 'full' must never be recorded — it is not a valid answer anymore (got: $out)"
grepq "$out" -F '  1) lean (recommended — press Enter)' \
  || fail "case11: the pluginSet menu must offer lean (got: $out)"
grepq "$out" -F '  2) full' \
  && fail "case11: the pluginSet menu must never list full as option 2 (got: $out)"
echo "ok: case11 pluginSet=full is rejected (re-prompts) and never offered in the menu; lean is the only path"

# ── Case 12 (HIMMEL-2346): whisper model numbered enum + custom escape hatch ──
# The whisper-model question used to be free text with a default nobody could
# evaluate without asking someone "what is the big one?" (the operator
# complaint this ticket fixes). Now a numbered menu of the standard
# whisper.cpp ggml models, plus a 'custom' branch that falls through to a
# free-text ask for any other filename — same shape as vaultMode='existing'/
# handoverMode='external' already trigger a follow-up free-text question
# above, not a new escape hatch bolted onto askNumberedEnum() itself.
#
# Every sub-case walks profile=custom through the full bridge=on chain (the
# shortest path that reaches the whisper-model question): scope/vault/
# handover/pluginSet/lanes/alwaysOn/cadences/disarm-consent/PHI/HIMMEL-2347's
# personal-vault question/secretsWalk all take their printed default (blank
# line), lanes/cadences answer 'none' explicitly (both accept it), bridge
# answers 'on', envPath/whisperCli take their defaults, then the whisper-model
# answer + (case14 only) its custom filename sub-answer, then the
# bridge-persistence consent takes its default.
whisper_case_input() {
  # $1 = whisper-model answer, $2 = optional custom-filename sub-answer
  # HIMMEL-2347: one extra blank line vs. before — the new personal/medical
  # vault question sits between PHI and secretsWalk, defaults 'no' on blank,
  # so no follow-up path/marker sub-answers are ever reached here.
  printf 'custom\n\ndefault-template\n\n\n\nnone\n\nnone\n\n\n\n\non\n\n\n%s\n' "$1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2"; fi
  printf '\n'
}

# Case 12: selecting a numbered option yields the bare filename, not a path
# and not the bare short name ('large-v3-turbo').
stub12="$work/case12"; mkdir -p "$stub12"
c12path=$(build_path "$stub12" bash jq python3 npm -- )
h12="$work/h12"; mkdir -p "$h12"
set +e
out12=$(PATH="$c12path" HOME="$h12" USERPROFILE="$(winpath "$h12")" HIMMELCTL_CACHE_DIR="$(winpath "$h12.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h12.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<< "$(whisper_case_input 6)"); rc12=$?
set -e
[ "$rc12" -eq 0 ] || fail "case12: numbered-pick run should succeed (got rc=$rc12): $out12"
grepq "$out12" -F '"whisperModel": "ggml-large-v3-turbo.bin"' \
  || fail "case12: picking option 6 (large-v3-turbo) should record the bare filename ggml-large-v3-turbo.bin (got: $out12)"
grepq "$out12" -F '"whisperModel": "large-v3-turbo"' \
  && fail "case12: must never record the bare short name instead of the ggml-*.bin filename (got: $out12)"
echo "ok: case12 selecting a numbered whisper-model option records the bare filename"

# Case 13: the 'custom' branch still accepts an arbitrary filename.
stub13="$work/case13"; mkdir -p "$stub13"
c13path=$(build_path "$stub13" bash jq python3 npm -- )
h13="$work/h13"; mkdir -p "$h13"
set +e
out13=$(PATH="$c13path" HOME="$h13" USERPROFILE="$(winpath "$h13")" HIMMELCTL_CACHE_DIR="$(winpath "$h13.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h13.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<< "$(whisper_case_input custom my-finetune.bin)"); rc13=$?
set -e
[ "$rc13" -eq 0 ] || fail "case13: custom-branch run should succeed (got rc=$rc13): $out13"
grepq "$out13" -F '? whisper model filename (default: ggml-small.bin)' \
  || fail "case13: picking 'custom' should fall through to the free-text prompt (got: $out13)"
grepq "$out13" -F '"whisperModel": "my-finetune.bin"' \
  || fail "case13: the custom branch should record whatever arbitrary filename was typed (got: $out13)"
echo "ok: case13 the 'custom' menu entry still accepts an arbitrary filename"

# Case 14: pressing Enter takes the default — profile=custom keeps the plain
# schema default (ggml-small.bin), proving the operator preset's new seed
# (case2 above) did NOT change the other presets.
stub14="$work/case14"; mkdir -p "$stub14"
c14path=$(build_path "$stub14" bash jq python3 npm -- )
h14="$work/h14"; mkdir -p "$h14"
set +e
out14=$(PATH="$c14path" HOME="$h14" USERPROFILE="$(winpath "$h14")" HIMMELCTL_CACHE_DIR="$(winpath "$h14.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h14.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<< "$(whisper_case_input '')"); rc14=$?
set -e
[ "$rc14" -eq 0 ] || fail "case14: default-accept run should succeed (got rc=$rc14): $out14"
grepq "$out14" -F '? whisper model [tiny|base|small|medium|large-v3|large-v3-turbo|custom] (default: small)' \
  || fail "case14: profile=custom should show the plain default=small, unlike operator's seeded large-v3-turbo (got: $out14)"
grepq "$out14" -F '"whisperModel": "ggml-small.bin"' \
  || fail "case14: pressing Enter should record the default bare filename ggml-small.bin (got: $out14)"
echo "ok: case14 pressing Enter accepts the whisper-model default; non-operator presets are unchanged"

echo "PASS"
