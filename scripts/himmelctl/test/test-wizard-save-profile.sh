#!/usr/bin/env bash
# test-wizard-save-profile.sh — hermetic tests for HIMMEL-2348 deliverable 1
# ("save-your-profile"): at the end of a SUCCESSFUL, non-dry-run install or
# ensure converge, offer to save the answered profile as a NAMED, reusable
# file under HIMMELCTL_PROFILES_DIR that `--from-profile` can replay on
# another machine. A new suite (not folded into test-wizard-luna-sections.sh,
# which already runs 375-619s against the 600s runner cap) per the ticket.
#
# Conventions borrowed from sibling suites: test-wizard-questions.sh's
# interactive-install stdin-driving harness (its case5), test-wizard-adopter-
# profile.sh's make_fixture() no-op-adopt.sh stub, and test-wizard-ensure.sh's
# single-red-item manifest + stub-primitive fixture for a real (non-dry-run)
# converge.
#
# STAGGERED STDIN, why: this wizard's question engine (askQuestions' own
# readline instance) and every later confirm (askConfirmSafe/askLineSafe, each
# its OWN fresh readline over the same process.stdin) all attach to the SAME
# underlying stream. Empirically (probed against this exact bin.js code),
# when more than one line is already sitting in that stream's read buffer the
# moment a readline instance attaches, it can silently consume ALL of them
# even though only one is asked for — a line intended for a LATER prompt
# (e.g. this ticket's save-name prompt) gets swallowed by an EARLIER one
# (askQuestions, or the "Proceed?" confirm) and is gone, never reaching the
# prompt it was meant to answer. Delivering each answer as its own write with
# a short pause after it (stage(), below) keeps each prompt's line out of the
# stream until that prompt's OWN readline instance is the one attached and
# waiting, avoiding the swallow. This is why several cases below pipe from a
# `(stage ...; stage ...)` subshell instead of a plain heredoc — a heredoc
# hands the whole answer set to the child as one already-available blob, RIGHT
# BACK into the swallow case.
#
# Covers:
#   1. interactive install, save accepted -> the saved file exists and is
#      BYTE-IDENTICAL to the cache install-profile.json.
#   2. save declined (empty answer) -> no file written, install still exits 0.
#   3. --dry-run -> no prompt, no file (dry-run's zero-mutation guarantee).
#   4. --from-profile (non-interactive) -> no prompt, no hang, no file.
#   5. a FAILED install (adopt.sh exits 1) -> no save prompt, no file.
#   6. name validation, NEGATIVE CONTROL: a name containing '..'/a path
#      separator writes NOTHING outside the profiles dir — the traversal
#      target is asserted absent.
#   7. `ensure` after a real (non-dry-run) converge -> the same offer fires;
#      --yes and --dry-run both suppress it (no prompt, no file).
#   8. HIMMEL-2348 CR finding 1: an existing REGULAR file at the destination,
#      overwrite confirmed -> it gets overwritten (the 'wx'-then-EEXIST-then-
#      'w' fallback path this finding rewrote wasn't exercised by any case
#      above — case 1 always writes into an empty profiles dir).
#   9. HIMMEL-2348 CR finding 1: a SYMLINK at the destination, overwrite
#      confirmed -> refused (never written through), the symlink's target is
#      left untouched. Probed and SKIPPED with a clear message if this box
#      can't create filesystem symlinks (observed on at least one dev box:
#      Git Bash's own `ln -s` silently copies instead of linking, and Node's
#      fs.symlinkSync fails EPERM without elevated privilege/Developer
#      Mode) — never faked against a same-named regular file instead.
#  10. HIMMEL-2348 CR round 2 findings 1/2/3: the save now writes via a
#      temp-file-in-the-same-dir + renameSync, so a failure DURING that
#      write must leave a pre-existing destination file completely
#      unchanged (the whole point of not truncating `dest` in place). A
#      Node --require preload (same technique as test-wizard-adopter-
#      profile.sh's caseAB) monkey-patches fs.writeFileSync to throw only
#      for the temp file this save creates, leaving every other write in
#      the process alone; the save must WARN, never change the install's
#      exit code, and the old content at `dest` must survive byte-for-byte.
#  11. Same finding, the OTHER failure point: the temp WRITE succeeds and
#      renameSync (temp -> dest) is the thing that throws. That is the only
#      path where offerSaveProfile's `finally { if (tmpCreated) unlinkSync
#      (tmpDest) }` cleanup does anything — case 10's fixture never creates
#      the temp file, so it can't reach it. Same --require technique, this
#      time patching fs.renameSync to throw only for this save's own temp
#      path; asserts the leftover temp is cleaned up (none matching
#      `.*.tmp`/`*.tmp` survive), a "could not save profile" warning
#      prints with no success line, install exit code stays 0, and a
#      pre-existing destination file survives byte-for-byte.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (see sibling suites' identical helper: printf/echo into `grep -q`
# under `set -o pipefail` can report a SUCCESSFUL match as a failed pipeline).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

node_bin=$(command -v node)

# _TIMEOUT_BIN -- GNU `timeout` is absent on a stock macOS (homebrew coreutils
# installs it as `gtimeout`). Resolve once (same pattern as
# scripts/hooks/test-crlf-boundary.sh): bound the hang-prone cases below when
# a timeout binary is present, run unbounded and say so when neither is --
# the bound is a safety net, not the thing under test.
_TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  _TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  _TIMEOUT_BIN="gtimeout"
else
  echo "test-wizard-save-profile.sh: no 'timeout'/'gtimeout' found -- hang protection disabled for this run" >&2
fi

export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-save-profile.XXXXXX") || fail "mktemp -d failed"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# Isolate HIMMELCTL_BIN_DIR for the whole suite (a non-dry-run install reaches
# applyHimmelctlPathShim, whose default binDir is the operator's REAL
# ~/.local/bin on POSIX) — mirrors every sibling suite that runs a real
# install.
HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

# build_path <stub_dir> <present_tools...> -- <absent_tools...> — copied from
# test-wizard-questions.sh/test-wizard-adopter-profile.sh.
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

# make_fixture <dir> [adopt_rc] — a throwaway HIMMELCTL_REPO_ROOT with a
# no-op (or, given a nonzero adopt_rc, a FAILING) adopt.sh — same shape as
# test-wizard-adopter-profile.sh's make_fixture(), narrowed to just what
# runPlan's main (non-T5b) path shells out to for profile=starter/vault=none.
make_fixture() {
  local _d="$1" _rc="${2:-0}"
  mkdir -p "$_d/scripts"
  printf '#!/usr/bin/env bash\nexit %s\n' "$_rc" > "$_d/scripts/adopt.sh"
  chmod +x "$_d/scripts/adopt.sh"
}

# stage <line> — write one line to stdout, then pause briefly. Used inside a
# `( stage a; stage b; ... ) | wizard ...` pipeline so each answer lands in
# process.stdin only once the readline instance meant to consume it is the
# one actually attached (see the file-header note on the swallow bug).
stage() {
  printf '%s\n' "$1"
  sleep 0.5
}

# The 7 base wizard answers (profile/scope/vault/handover/pluginSet/lanes/
# alwaysOn) that produce a starter/project/vault=none/inline/lean/no-lanes/
# no-alwaysOn profile — verbatim the same sequence test-wizard-questions.sh's
# case5 uses (proven to ask exactly 7 questions, no more).
BASE_ANSWERS=(starter project none inline lean none no)

# ── Case 1: interactive install, save accepted -> byte-identical file ───────
c1="$work/case1"; mkdir -p "$c1"
p1=$(build_path "$c1" bash jq python3 npm --)
h1="$work/h1"; mkdir -p "$h1"
cache1_posix="$work/case1-cache"; mkdir -p "$cache1_posix"
cache1_node=$(winpath "$cache1_posix")
profiles1_posix="$work/case1-profiles"
profiles1_node=$(winpath "$profiles1_posix")
fixture1="$work/case1-fixture"; make_fixture "$fixture1"
set +e
out1=$(
  ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
    stage y
    stage myprofile
  ) | PATH="$p1" HOME="$h1" USERPROFILE="$(winpath "$h1")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache1_node" HIMMEL_LUNA_CONFIG_PATH="$cache1_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles1_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture1")" \
      "$node_bin" "$wizard" install 2>&1
)
rc1=$?
set -e
[ "$rc1" -eq 0 ] || fail "case1: interactive install should succeed (got rc=$rc1): $out1"
grepq "$out1" 'save this install profile' || fail "case1: expected the save-offer prompt (got: $out1)"
cachefile1="$cache1_posix/install-profile.json"
[ -f "$cachefile1" ] || fail "case1: cache file should be written (expected $cachefile1)"
savedfile1="$profiles1_posix/myprofile.install-profile.json"
[ -f "$savedfile1" ] || fail "case1: saved profile should exist at $savedfile1 (out: $out1)"
cmp -s "$cachefile1" "$savedfile1" || fail "case1: saved profile must be BYTE-IDENTICAL to the cache
cache: <$(cat "$cachefile1")>
saved: <$(cat "$savedfile1")>"
grepq "$out1" "saved profile to" || fail "case1: expected a confirmation line naming the saved path (got: $out1)"
echo "ok: case1 interactive install + accepted save writes a byte-identical named profile"

# ── Case 2: save declined (empty answer) -> no file, install still exits 0 ──
c2="$work/case2"; mkdir -p "$c2"
p2=$(build_path "$c2" bash jq python3 npm --)
h2="$work/h2"; mkdir -p "$h2"
cache2_posix="$work/case2-cache"; mkdir -p "$cache2_posix"
cache2_node=$(winpath "$cache2_posix")
profiles2_posix="$work/case2-profiles"
profiles2_node=$(winpath "$profiles2_posix")
fixture2="$work/case2-fixture"; make_fixture "$fixture2"
set +e
out2=$(
  ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
    stage y
    stage ""
  ) | PATH="$p2" HOME="$h2" USERPROFILE="$(winpath "$h2")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache2_node" HIMMEL_LUNA_CONFIG_PATH="$cache2_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles2_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture2")" \
      "$node_bin" "$wizard" install 2>&1
)
rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "case2: declining the save should still exit 0 (got rc=$rc2): $out2"
[ ! -d "$profiles2_posix" ] || [ -z "$(ls -A "$profiles2_posix" 2>/dev/null)" ] \
  || fail "case2: no profile file should have been written on decline (found: $(ls -A "$profiles2_posix"))"
echo "ok: case2 an empty answer declines the save; install still exits 0; nothing written"

# ── Case 3: --dry-run -> no prompt, no file (zero mutations) ────────────────
c3="$work/case3"; mkdir -p "$c3"
p3=$(build_path "$c3" bash jq python3 npm --)
h3="$work/h3"; mkdir -p "$h3"
cache3_posix="$work/case3-cache"; mkdir -p "$cache3_posix"
cache3_node=$(winpath "$cache3_posix")
profiles3_posix="$work/case3-profiles"
profiles3_node=$(winpath "$profiles3_posix")
fixture3="$work/case3-fixture"; make_fixture "$fixture3"
set +e
out3=$(PATH="$p3" HOME="$h3" USERPROFILE="$(winpath "$h3")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache3_node" HIMMEL_LUNA_CONFIG_PATH="$cache3_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles3_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture3")" \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT
starter
project
none
inline
lean
none
no
INPUT
); rc3=$?
set -e
[ "$rc3" -eq 0 ] || fail "case3: --dry-run install should succeed (got rc=$rc3): $out3"
[ ! -f "$cache3_posix/install-profile.json" ] || fail "case3: --dry-run must not write the cache either"
grepq "$out3" 'save this install profile' && fail "case3: --dry-run must NEVER offer to save (got: $out3)"
[ ! -d "$profiles3_posix" ] || [ -z "$(ls -A "$profiles3_posix" 2>/dev/null)" ] \
  || fail "case3: --dry-run must write nothing under the profiles dir (found: $(ls -A "$profiles3_posix"))"
echo "ok: case3 --dry-run never offers to save and writes nothing"

# ── Case 4: --from-profile (non-interactive) -> no prompt, no hang, no file ─
c4="$work/case4"; mkdir -p "$c4"
p4=$(build_path "$c4" bash jq python3 npm --)
h4="$work/h4"; mkdir -p "$h4"
cache4_posix="$work/case4-cache"; mkdir -p "$cache4_posix"
cache4_node=$(winpath "$cache4_posix")
profiles4_posix="$work/case4-profiles"
profiles4_node=$(winpath "$profiles4_posix")
fixture4="$work/case4-fixture"; make_fixture "$fixture4"
# A minimal, hand-authored valid v1 profile (loadProfile's legacy branch —
# role required, no schemaVersion) — avoids depending on case1's output so
# this case stands alone.
profile4="$work/case4-profile.json"
cat > "$profile4" <<'JSON'
{"role":"adopter","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
set +e
# shellcheck disable=SC2086  # intentional word-split: absent -> no extra token
out4=$(PATH="$p4" HOME="$h4" USERPROFILE="$(winpath "$h4")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_CACHE_DIR="$cache4_node" HIMMEL_LUNA_CONFIG_PATH="$cache4_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles4_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture4")" \
      ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} "$node_bin" "$wizard" install --from-profile "$(winpath "$profile4")" </dev/null 2>&1
); rc4=$?
set -e
[ "$rc4" -eq 0 ] || fail "case4: --from-profile install should succeed (got rc=$rc4): $out4"
grepq "$out4" 'save this install profile' && fail "case4: --from-profile must NEVER prompt (got: $out4)"
[ ! -d "$profiles4_posix" ] || [ -z "$(ls -A "$profiles4_posix" 2>/dev/null)" ] \
  || fail "case4: --from-profile must write nothing under the profiles dir (found: $(ls -A "$profiles4_posix"))"
echo "ok: case4 --from-profile never prompts, never hangs, writes nothing under the profiles dir"

# ── Case 5: a FAILED install -> no save prompt, no file ─────────────────────
c5="$work/case5"; mkdir -p "$c5"
p5=$(build_path "$c5" bash jq python3 npm --)
h5="$work/h5"; mkdir -p "$h5"
cache5_posix="$work/case5-cache"; mkdir -p "$cache5_posix"
cache5_node=$(winpath "$cache5_posix")
profiles5_posix="$work/case5-profiles"
profiles5_node=$(winpath "$profiles5_posix")
fixture5="$work/case5-fixture"; make_fixture "$fixture5" 1  # adopt.sh exits 1
set +e
out5=$(
  ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
    stage y
  ) | PATH="$p5" HOME="$h5" USERPROFILE="$(winpath "$h5")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache5_node" HIMMEL_LUNA_CONFIG_PATH="$cache5_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles5_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture5")" \
      "$node_bin" "$wizard" install 2>&1
)
rc5=$?
set -e
[ "$rc5" -ne 0 ] || fail "case5: a failing adopt.sh should make install fail (got rc=$rc5): $out5"
grepq "$out5" 'save this install profile' && fail "case5: a FAILED install must never offer to save (got: $out5)"
[ ! -d "$profiles5_posix" ] || [ -z "$(ls -A "$profiles5_posix" 2>/dev/null)" ] \
  || fail "case5: a failed install must write nothing under the profiles dir (found: $(ls -A "$profiles5_posix"))"
echo "ok: case5 a failed install never offers to save and writes nothing"

# ── Case 6: name validation NEGATIVE CONTROL — a traversal name writes
# NOTHING outside the profiles dir ───────────────────────────────────────────
c6="$work/case6"; mkdir -p "$c6"
p6=$(build_path "$c6" bash jq python3 npm --)
h6="$work/h6"; mkdir -p "$h6"
cache6_posix="$work/case6-cache"; mkdir -p "$cache6_posix"
cache6_node=$(winpath "$cache6_posix")
profiles6_posix="$work/case6-profiles-dir/nested"; mkdir -p "$profiles6_posix"
profiles6_node=$(winpath "$profiles6_posix")
fixture6="$work/case6-fixture"; make_fixture "$fixture6"
set +e
out6=$(
  ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
    stage y
    stage "../evil"
  ) | PATH="$p6" HOME="$h6" USERPROFILE="$(winpath "$h6")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache6_node" HIMMEL_LUNA_CONFIG_PATH="$cache6_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles6_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture6")" \
      "$node_bin" "$wizard" install 2>&1
)
rc6=$?
set -e
[ "$rc6" -eq 0 ] || fail "case6: install itself should still succeed despite an invalid save name (got rc=$rc6): $out6"
grepq "$out6" -i 'invalid profile name' || fail "case6: expected an invalid-name warning (got: $out6)"
traversal_target="$work/case6-profiles-dir/evil.install-profile.json"
[ ! -f "$traversal_target" ] || fail "case6: a '../evil' name must NOT escape the profiles dir — found $traversal_target"
[ -z "$(ls -A "$profiles6_posix" 2>/dev/null)" ] \
  || fail "case6: nothing should have been written inside the profiles dir either (found: $(ls -A "$profiles6_posix"))"
echo "ok: case6 a traversal name ('../evil') writes nothing anywhere — negative control holds"

# ── Case 7: ensure after a real converge -> same offer; --yes/--dry-run
# suppress it (no prompt, no file) ───────────────────────────────────────────
# A minimal manifest with ONE red item carrying a runnable install
# descriptor, converged by a stub primitive — same shape as
# test-wizard-ensure.sh's repoD fixture (case d/g there).
repo7="$work/repo7"; mkdir -p "$repo7/scripts/install" "$repo7/scripts/lib"
cat > "$repo7/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "red-item",
      "kind": "wiring",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "red.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repo7/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > red.marker
exit 0
SH

# write_cache7 <cache_dir> — a minimal valid v2 profile, in the EXACT byte
# shape serialize()+'\n' (JSON.stringify(_, null, 2), one trailing newline)
# would produce for it — loadProfile() returns a v2 object UNCHANGED (no
# v1->v2 migration in the way, unlike a legacy v1 cache), so this makes the
# case7a byte-identity check between this file and the saved profile actually
# meaningful. (A single-line-JSON fixture would carry the same DATA but never
# the same BYTES as serialize()'s pretty-printed output — that mismatch is a
# wrong fixture shape, not a code bug.)
write_cache7() {
  mkdir -p "$1"
  cat > "$1/install-profile.json" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "devOverlay": false,
  "scope": "project",
  "vault": {
    "mode": "none",
    "path": ""
  },
  "handover": {
    "mode": "inline",
    "path": ""
  },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
}

# 7a: interactive converge + save accepted -> byte-identical file
#
# RETRY, why: unlike the install cases above (whose question-engine starts
# reading stdin almost immediately), `ensure` does real synchronous work
# (loadManifest, statusReport, probes, and — after 'y' — a SYNCHRONOUS
# spawnSync of the converge primitive) between each readline instance it
# attaches. A fixed sleep long enough to always outlast that work on a
# quiet machine can still occasionally lose the race under load (this was
# observed directly: 1.5s/1.5s passed several runs, then failed one under
# load) — a machine-load-dependent race, not a code defect (every case
# above, and 7a's own prompt text, prove the feature itself works). Retry a
# few times with a fresh target/cache/profiles dir each time (reusing one
# would find the item already converged on a retry and skip straight past
# the very prompt under test) rather than chase an ever-larger fixed delay.
run_case7a_attempt() {
  local _n="$1"
  local _target="$work/target7a-$_n"; mkdir -p "$_target"
  local _cache="$work/cache7a-$_n"; write_cache7 "$_cache"
  local _profiles_posix="$work/profiles7a-$_n"
  local _profiles_node; _profiles_node=$(winpath "$_profiles_posix")
  set +e
  CASE7A_OUT=$(
    ( sleep 1.5
      printf 'y\n'
      sleep 1.5
      printf 'ensured\n'
    ) | ( cd "$_target" && HIMMELCTL_REPO_ROOT="$(winpath "$repo7")" HIMMELCTL_CACHE_DIR="$(winpath "$_cache")" \
          HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_cache")-luna-config.json" HOME="$work/home7a-$_n" USERPROFILE="$(winpath "$work/home7a-$_n")" \
          HIMMELCTL_PROFILES_DIR="$_profiles_node" HIMMELCTL_INTERACTIVE=1 \
          "$node_bin" "$wizard" ensure 2>&1 )
  )
  CASE7A_RC=$?
  set -e
  CASE7A_CACHE="$_cache/install-profile.json"
  CASE7A_SAVED="$_profiles_posix/ensured.install-profile.json"
}

case7a_ok=""
for attempt in 1 2 3; do
  run_case7a_attempt "$attempt"
  if [ "$CASE7A_RC" -eq 0 ] && grepq "$CASE7A_OUT" 'save this install profile' && [ -f "$CASE7A_SAVED" ]; then
    case7a_ok=1
    if [ "$attempt" -gt 1 ]; then
      # Audible, not just a bare "ok:" — a worsening race must be visible
      # before it hits 3/3, and the note names the observed cause so this
      # doesn't read as a flaky product bug: Node readline can swallow
      # buffered stdin lines meant for a LATER prompt when a fresh readline
      # interface attaches (see the file-header STAGGERED STDIN note) — a
      # harness/platform race under load, not a product defect.
      echo "NOTE: case7a needed attempt $attempt/3 to pass — this is the documented readline stdin-swallow race (see file header), not a product defect; investigate only if attempt 3 starts failing too" >&2
    fi
    break
  fi
done
[ -n "$case7a_ok" ] || fail "case7a: interactive converge + save did not complete in 3 attempts (last rc=$CASE7A_RC): $CASE7A_OUT"
grepq "$CASE7A_OUT" 'ensure complete' || fail "case7a: expected a real converge to have happened (got: $CASE7A_OUT)"
cmp -s "$CASE7A_CACHE" "$CASE7A_SAVED" \
  || fail "case7a: saved profile must be byte-identical to the ensure-loaded cache"
echo "ok: case7a ensure offers to save after a real converge; byte-identical file"

# 7b: --yes suppresses the offer entirely (non-interactive consent given,
# no prompt, no file, no hang)
target7b="$work/target7b"; mkdir -p "$target7b"
cache7b="$work/cache7b"; write_cache7 "$cache7b"
profiles7b_posix="$work/profiles7b"
profiles7b_node=$(winpath "$profiles7b_posix")
set +e
# shellcheck disable=SC2086  # intentional word-split: absent -> no extra token
out7b=$( cd "$target7b" && HIMMELCTL_REPO_ROOT="$(winpath "$repo7")" HIMMELCTL_CACHE_DIR="$(winpath "$cache7b")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache7b")-luna-config.json" HOME="$work/home7b" USERPROFILE="$(winpath "$work/home7b")" \
      HIMMELCTL_PROFILES_DIR="$profiles7b_node" HIMMELCTL_INTERACTIVE=0 \
      ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} "$node_bin" "$wizard" ensure --yes </dev/null 2>&1 ); rc7b=$?
set -e
[ "$rc7b" -eq 0 ] || fail "case7b: --yes converge should succeed (got rc=$rc7b): $out7b"
grepq "$out7b" 'save this install profile' && fail "case7b: --yes must suppress the save offer (got: $out7b)"
[ ! -d "$profiles7b_posix" ] || [ -z "$(ls -A "$profiles7b_posix" 2>/dev/null)" ] \
  || fail "case7b: --yes must write nothing under the profiles dir (found: $(ls -A "$profiles7b_posix"))"
echo "ok: case7b ensure --yes suppresses the save offer; no prompt, no file, no hang"

# 7c: --dry-run suppresses the offer entirely (zero mutation)
target7c="$work/target7c"; mkdir -p "$target7c"
cache7c="$work/cache7c"; write_cache7 "$cache7c"
profiles7c_posix="$work/profiles7c"
profiles7c_node=$(winpath "$profiles7c_posix")
set +e
# shellcheck disable=SC2086  # intentional word-split: absent -> no extra token
out7c=$( cd "$target7c" && HIMMELCTL_REPO_ROOT="$(winpath "$repo7")" HIMMELCTL_CACHE_DIR="$(winpath "$cache7c")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache7c")-luna-config.json" HOME="$work/home7c" USERPROFILE="$(winpath "$work/home7c")" \
      HIMMELCTL_PROFILES_DIR="$profiles7c_node" HIMMELCTL_INTERACTIVE=1 \
      ${_TIMEOUT_BIN:+$_TIMEOUT_BIN 20} "$node_bin" "$wizard" ensure --dry-run </dev/null 2>&1 ); rc7c=$?
set -e
[ "$rc7c" -eq 0 ] || fail "case7c: --dry-run should succeed (got rc=$rc7c): $out7c"
grepq "$out7c" 'save this install profile' && fail "case7c: --dry-run must suppress the save offer (got: $out7c)"
[ ! -f "$cache7c/state.json" ] || fail "case7c: --dry-run must make zero mutations (state.json written)"
[ ! -d "$profiles7c_posix" ] || [ -z "$(ls -A "$profiles7c_posix" 2>/dev/null)" ] \
  || fail "case7c: --dry-run must write nothing under the profiles dir (found: $(ls -A "$profiles7c_posix"))"
echo "ok: case7c ensure --dry-run suppresses the save offer; zero mutation"

# ── Case 8: an existing REGULAR file at the destination, overwrite confirmed
# -> gets overwritten (the EEXIST->prompt->'w' fallback path) ──────────────
c8="$work/case8"; mkdir -p "$c8"
p8=$(build_path "$c8" bash jq python3 npm --)
h8="$work/h8"; mkdir -p "$h8"
cache8_posix="$work/case8-cache"; mkdir -p "$cache8_posix"
cache8_node=$(winpath "$cache8_posix")
profiles8_posix="$work/case8-profiles"; mkdir -p "$profiles8_posix"
profiles8_node=$(winpath "$profiles8_posix")
fixture8="$work/case8-fixture"; make_fixture "$fixture8"
dest8="$profiles8_posix/existing.install-profile.json"
printf 'OLD-CONTENT-PLACEHOLDER' > "$dest8"
set +e
out8=$(
  ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
    stage y
    stage existing
    sleep 1.5
    stage y
  ) | PATH="$p8" HOME="$h8" USERPROFILE="$(winpath "$h8")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache8_node" HIMMEL_LUNA_CONFIG_PATH="$cache8_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles8_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture8")" \
      "$node_bin" "$wizard" install 2>&1
)
rc8=$?
set -e
[ "$rc8" -eq 0 ] || fail "case8: install should succeed after a confirmed overwrite (got rc=$rc8): $out8"
grepq "$out8" -i 'already exists' || fail "case8: expected the overwrite prompt (got: $out8)"
grepq "$out8" 'saved profile to' || fail "case8: expected a confirmation line naming the saved path (got: $out8)"
cmp -s "$cache8_posix/install-profile.json" "$dest8" \
  || fail "case8: a confirmed overwrite must replace the old content with the byte-identical cache profile"
echo "ok: case8 an existing regular file at the destination is overwritten once the operator confirms"

# ── Case 9: a SYMLINK at the destination is refused, never written through ──
symlink_probe="$work/symlink-probe"; mkdir -p "$symlink_probe"
printf probe > "$symlink_probe/target.txt"
symlink_ok=1
node -e '
  const fs = require("fs");
  try {
    fs.symlinkSync(process.argv[1], process.argv[2], "file");
    if (!fs.lstatSync(process.argv[2]).isSymbolicLink()) process.exit(1);
  } catch (e) { process.exit(1); }
' "$symlink_probe/target.txt" "$symlink_probe/link.txt" || symlink_ok=0

if [ "$symlink_ok" -ne 1 ]; then
  echo "SKIP: case9 — this box cannot create filesystem symlinks (probed via Node fs.symlinkSync; a plain \`ln -s\` can silently copy instead of linking here) — symlink-refusal behavior not exercised" >&2
else
  c9="$work/case9"; mkdir -p "$c9"
  p9=$(build_path "$c9" bash jq python3 npm --)
  h9="$work/h9"; mkdir -p "$h9"
  cache9_posix="$work/case9-cache"; mkdir -p "$cache9_posix"
  cache9_node=$(winpath "$cache9_posix")
  profiles9_posix="$work/case9-profiles"; mkdir -p "$profiles9_posix"
  profiles9_node=$(winpath "$profiles9_posix")
  fixture9="$work/case9-fixture"; make_fixture "$fixture9"
  outside9="$work/case9-outside.json"
  printf 'do-not-overwrite' > "$outside9"
  dest9="$profiles9_posix/symtarget.install-profile.json"
  node -e 'require("fs").symlinkSync(process.argv[1], process.argv[2], "file")' "$outside9" "$dest9"
  set +e
  out9=$(
    ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
      stage y
      stage symtarget
      sleep 1.5
      stage y
    ) | PATH="$p9" HOME="$h9" USERPROFILE="$(winpath "$h9")" HIMMELCTL_INTERACTIVE=1 \
        HIMMELCTL_CACHE_DIR="$cache9_node" HIMMEL_LUNA_CONFIG_PATH="$cache9_node-luna-config.json" \
        HIMMELCTL_PROFILES_DIR="$profiles9_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture9")" \
        "$node_bin" "$wizard" install 2>&1
  )
  rc9=$?
  set -e
  [ "$rc9" -eq 0 ] || fail "case9: install itself should still succeed despite a refused symlink overwrite (got rc=$rc9): $out9"
  grepq "$out9" -i 'symlink' || fail "case9: expected a symlink-refusal warning (got: $out9)"
  content9=$(cat "$outside9")
  [ "$content9" = "do-not-overwrite" ] || fail "case9: the symlink's TARGET must be untouched — a write-through would have clobbered it (got: $content9)"
  node -e '
    const fs = require("fs");
    if (!fs.lstatSync(process.argv[1]).isSymbolicLink()) { console.error("dest is no longer a symlink"); process.exit(1); }
  ' "$dest9" || fail "case9: the destination symlink itself must be left alone (not replaced with a regular file)"
  echo "ok: case9 a symlink at the save destination is refused, never written through; its target is untouched"
fi

# ── Case 10: HIMMEL-2348 CR round 2 findings 1/2/3 — a write failure during
# the temp-file-then-rename save leaves the pre-existing destination file
# completely unchanged ───────────────────────────────────────────────────────
c10="$work/case10"; mkdir -p "$c10"
p10=$(build_path "$c10" bash jq python3 npm --)
h10="$work/h10"; mkdir -p "$h10"
cache10_posix="$work/case10-cache"; mkdir -p "$cache10_posix"
cache10_node=$(winpath "$cache10_posix")
profiles10_posix="$work/case10-profiles"; mkdir -p "$profiles10_posix"
profiles10_node=$(winpath "$profiles10_posix")
fixture10="$work/case10-fixture"; make_fixture "$fixture10"
dest10="$profiles10_posix/existing.install-profile.json"
printf 'OLD-CONTENT-PLACEHOLDER' > "$dest10"

# denyTmp10.js — monkey-patches fs.writeFileSync to throw ONLY for a path
# that (a) lives inside the profiles dir under test and (b) ends in '.tmp'
# (offerSaveProfile's temp-file naming) — every other write in the process
# (the cache install-profile.json, etc.) is left alone.
denyTmp10="$work/deny-profile-save-tmp.js"
cat > "$denyTmp10" <<'JS'
const fs = require('fs');
const path = require('path');
const realWriteFileSync = fs.writeFileSync;
fs.writeFileSync = function (p, ...rest) {
  const dir = process.env.DENY_PROFILE_SAVE_TMP_DIR;
  if (dir && typeof p === 'string' && String(p).endsWith('.tmp')
      && path.resolve(path.dirname(p)) === path.resolve(dir)) {
    const err = new Error('simulated disk-full during profile save');
    err.code = 'ENOSPC';
    throw err;
  }
  return realWriteFileSync.call(fs, p, ...rest);
};
require('module').syncBuiltinESMExports();
JS

set +e
out10=$(
  ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
    stage y
    stage existing
    sleep 1.5
    stage y
  ) | PATH="$p10" HOME="$h10" USERPROFILE="$(winpath "$h10")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache10_node" HIMMEL_LUNA_CONFIG_PATH="$cache10_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles10_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture10")" \
      DENY_PROFILE_SAVE_TMP_DIR="$profiles10_node" \
      NODE_OPTIONS="--require=$(winpath "$denyTmp10")" \
      "$node_bin" "$wizard" install 2>&1
)
rc10=$?
set -e
[ "$rc10" -eq 0 ] || fail "case10: a failed profile save must NOT change the install's own exit code (got rc=$rc10): $out10"
grepq "$out10" -i 'could not save profile' || fail "case10: expected a save-failure warning (got: $out10)"
grepq "$out10" 'saved profile to' && fail "case10: a failed save must never print a success confirmation (got: $out10)"
content10=$(cat "$dest10")
[ "$content10" = "OLD-CONTENT-PLACEHOLDER" ] || fail "case10: the pre-existing destination file must survive a failed save UNCHANGED (got: $content10)"
# Bash-native glob (portable — no GNU `find -maxdepth`): nullglob so a no-match
# expands to zero array elements instead of a literal unmatched pattern, AND
# dotglob because offerSaveProfile's tmpDest is dot-prefixed
# (`.${name}.install-profile.json.<pid>-<ts>-<rand>.tmp`, bin.js:1962) — bare
# `*` never matches a leading dot, so without dotglob this assertion could
# never see the very file it exists to catch.
shopt -s nullglob dotglob
leftover10=("$profiles10_posix"/*.tmp)
shopt -u nullglob dotglob
[ "${#leftover10[@]}" -eq 0 ] || fail "case10: a failed save must not litter the profiles dir with a temp file (found: ${leftover10[*]})"
echo "ok: case10 a write failure during the temp-file-then-rename save leaves the pre-existing destination file byte-unchanged, warns, and does not touch the install's exit code"

# ── Case 11: HIMMEL-2348 CR round 2 finding — a RENAME failure (temp write
# succeeds, renameSync throws) must still clean up the leftover temp file.
# This is the only path that exercises offerSaveProfile's
# `finally { if (tmpCreated) unlinkSync(tmpDest) }` cleanup: case 10's write
# failure never sets tmpCreated, so its finally branch is a no-op there. ──
c11="$work/case11"; mkdir -p "$c11"
p11=$(build_path "$c11" bash jq python3 npm --)
h11="$work/h11"; mkdir -p "$h11"
cache11_posix="$work/case11-cache"; mkdir -p "$cache11_posix"
cache11_node=$(winpath "$cache11_posix")
profiles11_posix="$work/case11-profiles"; mkdir -p "$profiles11_posix"
profiles11_node=$(winpath "$profiles11_posix")
fixture11="$work/case11-fixture"; make_fixture "$fixture11"
dest11="$profiles11_posix/existing.install-profile.json"
printf 'OLD-CONTENT-PLACEHOLDER' > "$dest11"

# denyRename11.js — monkey-patches fs.renameSync to throw ONLY when the
# source path (a) lives inside the profiles dir under test and (b) ends in
# '.tmp' (offerSaveProfile's temp-file naming) — every other renameSync
# call in the process is left alone. Unlike case10's writeFileSync patch,
# this lets the temp file actually get CREATED (tmpCreated becomes true)
# before the failure hits, which is the only way to reach the unlinkSync
# cleanup in offerSaveProfile's `finally` block.
denyRename11="$work/deny-profile-save-rename.js"
cat > "$denyRename11" <<'JS'
const fs = require('fs');
const path = require('path');
const realRenameSync = fs.renameSync;
fs.renameSync = function (oldPath, newPath) {
  const dir = process.env.DENY_PROFILE_SAVE_RENAME_DIR;
  if (dir && typeof oldPath === 'string' && String(oldPath).endsWith('.tmp')
      && path.resolve(path.dirname(oldPath)) === path.resolve(dir)) {
    const err = new Error('simulated rename failure during profile save');
    err.code = 'EPERM';
    throw err;
  }
  return realRenameSync.call(fs, oldPath, newPath);
};
require('module').syncBuiltinESMExports();
JS

set +e
out11=$(
  ( for a in "${BASE_ANSWERS[@]}"; do stage "$a"; done
    stage y
    stage existing
    sleep 1.5
    stage y
  ) | PATH="$p11" HOME="$h11" USERPROFILE="$(winpath "$h11")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache11_node" HIMMEL_LUNA_CONFIG_PATH="$cache11_node-luna-config.json" \
      HIMMELCTL_PROFILES_DIR="$profiles11_node" HIMMELCTL_REPO_ROOT="$(winpath "$fixture11")" \
      DENY_PROFILE_SAVE_RENAME_DIR="$profiles11_node" \
      NODE_OPTIONS="--require=$(winpath "$denyRename11")" \
      "$node_bin" "$wizard" install 2>&1
)
rc11=$?
set -e
[ "$rc11" -eq 0 ] || fail "case11: a failed profile save must NOT change the install's own exit code (got rc=$rc11): $out11"
grepq "$out11" -i 'could not save profile' || fail "case11: expected a save-failure warning (got: $out11)"
grepq "$out11" 'saved profile to' && fail "case11: a failed save must never print a success confirmation (got: $out11)"
content11=$(cat "$dest11")
[ "$content11" = "OLD-CONTENT-PLACEHOLDER" ] || fail "case11: the pre-existing destination file must survive a failed rename UNCHANGED (got: $content11)"
# Same nullglob+dotglob technique as case10 -- the leftover temp (if the
# cleanup were broken) is dot-prefixed, so a bare '*' glob without dotglob
# would be blind to it.
shopt -s nullglob dotglob
leftover11=("$profiles11_posix"/*.tmp)
shopt -u nullglob dotglob
[ "${#leftover11[@]}" -eq 0 ] || fail "case11: a failed rename must not litter the profiles dir with a temp file (found: ${leftover11[*]})"
echo "ok: case11 a rename failure during the temp-file-then-rename save cleans up the leftover temp file, leaves the pre-existing destination byte-unchanged, warns, and does not touch the install's exit code"

echo "PASS"
