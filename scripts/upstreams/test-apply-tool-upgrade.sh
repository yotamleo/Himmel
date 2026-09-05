#!/usr/bin/env bash
# scripts/upstreams/test-apply-tool-upgrade.sh — hermetic suite for the
# mode:probe installed-tool upgrader (HIMMEL-1323).
#
# Fully offline: every case builds a throwaway repo root under a temp dir
# containing a synthetic scripts/upstreams.json plus a bin/ of fake tools
# (bash scripts driven by a state/ dir), and points the script at it via
# DRIFT_REGISTRY / DRIFT_REPO_ROOT / a PATH prepend. No network, no real
# package manager, no real installed tool is ever touched.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UPGRADE="$SCRIPT_DIR/apply-tool-upgrade.sh"

fails=0
pass() { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; fails=$((fails + 1)); }

# assert_rc <expected-rc> <label> -- <command...>
assert_rc() {
  local want="$1" label="$2"; shift 3
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass "$label (rc=$rc)"
  else
    fail "$label — expected rc=$want got rc=$rc; output: $out"
  fi
}

assert_contains() {
  local hay="$1" needle="$2" label="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label — '$needle' not found in: $hay" ;;
  esac
}

assert_version() {
  local file="$1" want="$2" label="$3"
  local got
  got=$(cat "$file" 2>/dev/null)
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label — expected '$want' got '$got'"
  fi
}

assert_file_has() {
  local path="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — '$needle' not in $path"
  fi
}

# ---------------------------------------------------------------------------
# fixture: one repo root with every registry entry the suite needs, plus a
# bin/ of tiny fake tools driven entirely by a state/ dir of version files.
#
#   bin/verprobe <key>   -- prints "<key> version <contents of state/<key>.version>"
#                           (or errors if that file is absent), simulating a
#                           real CLI's `--version` output.
#   bin/bump <key> <val> -- overwrites state/<key>.version, simulating an
#                           upgrade that moves (or fails to move) the version.
#   bin/recorder ...     -- writes every argv element it received, one per
#                           line, to state/recorded.txt — used to prove argv
#                           elements arrive literal, never shell-interpreted.
#
# Echoes the root path.
# ---------------------------------------------------------------------------
make_fixture() {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/scripts" "$root/bin" "$root/state"

  cat > "$root/bin/verprobe" <<'SH'
#!/usr/bin/env bash
key="$1"
state_dir="$(cd "$(dirname "$0")/.." && pwd)/state"
f="$state_dir/$key.version"
if [ -f "$f" ]; then
  printf '%s version %s\n' "$key" "$(cat "$f")"
else
  echo "$key: not found" >&2
  exit 1
fi
SH
  chmod +x "$root/bin/verprobe"

  cat > "$root/bin/bump" <<'SH'
#!/usr/bin/env bash
# args: <key> <new-value> -- overwrites state/<key>.version
state_dir="$(cd "$(dirname "$0")/.." && pwd)/state"
printf '%s' "$2" > "$state_dir/$1.version"
SH
  chmod +x "$root/bin/bump"

  cat > "$root/bin/recorder" <<'SH'
#!/usr/bin/env bash
# records every argv element it received, one per line, for inspection.
state_dir="$(cd "$(dirname "$0")/.." && pwd)/state"
: > "$state_dir/recorded.txt"
for a in "$@"; do
  printf '%s\n' "$a" >> "$state_dir/recorded.txt"
done
SH
  chmod +x "$root/bin/recorder"

  printf '%s' "1.0.0" > "$root/state/success.version"
  printf '%s' "1.0.0" > "$root/state/unchanged.version"
  printf '%s' "1.5.0" > "$root/state/backwards.version"
  printf '%s' "1.0.0" > "$root/state/noversion.version"
  printf '%s' "1.0.0" > "$root/state/metachar.version"
  printf '%s' "3.0.0" > "$root/state/manual.version"
  printf '%s' "1.0.0" > "$root/state/dryrun.version"

  cat > "$root/scripts/upstreams.json" <<'JSON'
{
  "_comment": "fixture",
  "entries": [
    {
      "name": "success",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe success",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": { "command": ["bash", "bin/bump", "success", "1.1.0"], "unattended": true }
    },
    {
      "name": "unchanged",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe unchanged",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": { "command": ["bash", "bin/bump", "unchanged", "1.0.0"], "unattended": true }
    },
    {
      "name": "backwards",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe backwards",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": { "command": ["bash", "bin/bump", "backwards", "1.4.0"], "unattended": true }
    },
    {
      "name": "noversion",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe noversion",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": { "command": ["bash", "bin/bump", "noversion", "not-a-version"], "unattended": true }
    },
    {
      "name": "metachar",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe metachar",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": {
        "command": ["bash", "bin/recorder", "plain", "unsafe; touch pwned_marker; echo owned", "$(echo evil)", "`echo backticks`"],
        "unattended": true
      }
    },
    {
      "name": "manual",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe manual",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": { "command": ["bash", "bin/bump", "manual", "3.1.0"], "unattended": false }
    },
    {
      "name": "dryrun",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe dryrun",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": { "command": ["bash", "bin/bump", "dryrun", "9.9.9"], "unattended": true }
    },
    {
      "name": "noupgrade",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "verprobe noupgrade",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+"
    },
    {
      "name": "basedtool",
      "kind": "tag_release",
      "mode": "base",
      "synced_base": "1.0.0"
    },
    {
      "name": "notinstalled",
      "kind": "tag_release",
      "mode": "probe",
      "version_command": "ghosttool --version",
      "version_regex": "[0-9]+\\.[0-9]+\\.[0-9]+",
      "upgrade": { "command": ["true"], "unattended": true }
    }
  ]
}
JSON

  printf '%s' "$root"
}

# run_upgrade <root> <args...> -- invokes the script under test against the
# fixture, with the fixture's bin/ prepended (never replacing) PATH.
run_upgrade() {
  local root="$1"; shift
  env PATH="$root/bin:$PATH" DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" "$@"
}

echo "[test-apply-tool-upgrade] usage + arg validation"
assert_rc 2 "no args is a usage error" -- bash "$UPGRADE"
root=$(make_fixture)
assert_rc 2 "unknown flag rejected" -- env PATH="$root/bin:$PATH" DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" success --bogus
assert_rc 2 "extra positional rejected" -- env PATH="$root/bin:$PATH" DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" success extra
assert_rc 2 "unknown entry name rejected" -- env PATH="$root/bin:$PATH" DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" nosuchentry123
rm -rf "$root"

echo "[test-apply-tool-upgrade] missing / malformed registry"
assert_rc 2 "absent registry is rc=2" -- env DRIFT_REPO_ROOT=/nonexistent DRIFT_REGISTRY=/nonexistent/upstreams.json bash "$UPGRADE" success
root=$(make_fixture)
printf '%s' '{ not json' > "$root/scripts/upstreams.json"
assert_rc 2 "unparseable registry is rc=2" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" success
rm -rf "$root"

echo "[test-apply-tool-upgrade] wrong kind+mode is rc=2"
root=$(make_fixture)
assert_rc 2 "mode:base entry rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" basedtool
rm -rf "$root"

echo "[test-apply-tool-upgrade] no upgrade block is SKIP, not an error"
root=$(make_fixture)
out=$(run_upgrade "$root" noupgrade 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then pass "no upgrade block is rc=3 (SKIP)"; else fail "no upgrade block — expected rc=3 got $rc: $out"; fi
assert_contains "$out" "SKIP noupgrade" "prints a SKIP line naming the entry"
rm -rf "$root"

echo "[test-apply-tool-upgrade] tool not installed is rc=2 (this upgrades, not bootstraps)"
root=$(make_fixture)
assert_rc 2 "not-on-PATH tool is rc=2" -- env PATH="$root/bin:$PATH" DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" notinstalled
rm -rf "$root"

echo "[test-apply-tool-upgrade] --dry-run runs nothing and exits 0"
root=$(make_fixture)
out=$(run_upgrade "$root" dryrun --dry-run 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run exits 0"; else fail "dry-run exits 0 — got rc=$rc: $out"; fi
assert_contains "$out" "DRY dryrun 1.0.0 -> (upgrade not run)" "prints the DRY line"
assert_version "$root/state/dryrun.version" "1.0.0" "dry-run left the version untouched"
rm -rf "$root"

echo "[test-apply-tool-upgrade] policy gate: --unattended refuses a non-unattended entry"
root=$(make_fixture)
out=$(run_upgrade "$root" manual --unattended 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then pass "unattended:false + --unattended is rc=3 (SKIP)"; else fail "unattended:false + --unattended — expected rc=3 got $rc: $out"; fi
assert_contains "$out" "SKIP manual" "prints a SKIP line naming the entry"
assert_version "$root/state/manual.version" "3.0.0" "the upgrade command did NOT run under the gate"
echo "[test-apply-tool-upgrade] policy gate: the same entry WITHOUT --unattended proceeds"
out=$(run_upgrade "$root" manual 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "unattended:false without --unattended proceeds (rc=0)"; else fail "unattended:false without --unattended — expected rc=0 got $rc: $out"; fi
assert_version "$root/state/manual.version" "3.1.0" "the upgrade command DID run without the gate"
rm -rf "$root"

echo "[test-apply-tool-upgrade] re-probe verdict beats the exit code"
root=$(make_fixture)
out=$(run_upgrade "$root" success 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "version strictly advanced is rc=0"; else fail "success case — expected rc=0 got $rc: $out"; fi
assert_contains "$out" "UPGRADE success 1.0.0 -> 1.1.0" "prints the machine UPGRADE line"

# An unchanged version means different things depending on whether a TARGET was
# supplied, and the script must not guess. Both directions are asserted here:
# this exact ambiguity shipped as a bug — the first real run against rtk called
# "already the newest release" a FAILURE (rc 4), which would have cried wolf on
# every healthy nightly.
out=$(run_upgrade "$root" unchanged 1.1.0 2>&1); rc=$?
if [ "$rc" -eq 4 ]; then
  pass "unchanged version WITH a target it did not reach is rc=4"
else
  fail "unchanged+target case — expected rc=4 got $rc: $out"
fi
assert_contains "$out" "target was 1.1.0" "names the target it failed to reach"

out=$(run_upgrade "$root" unchanged 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then
  pass "unchanged version with NO target is rc=1 (nothing to do), not a failure"
else
  fail "unchanged, no target — expected rc=1 got $rc: $out"
fi
assert_contains "$out" "Pass the" "says the no-change claim is unverified without a target"

# Already at/past the target: refuse to even run the upgrade command.
printf '%s' "2.0.0" > "$root/state/unchanged.version"
out=$(run_upgrade "$root" unchanged 1.9.0 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then
  pass "already past the target is rc=1"
else
  fail "already-past-target — expected rc=1 got $rc: $out"
fi
assert_contains "$out" "already" "says it is already there"
printf '%s' "1.0.0" > "$root/state/unchanged.version"

out=$(run_upgrade "$root" backwards 2>&1); rc=$?
if [ "$rc" -eq 4 ]; then pass "version going backwards is rc=4"; else fail "backwards case — expected rc=4 got $rc: $out"; fi
assert_contains "$out" "went BACKWARDS" "prints the backwards diagnosis"

out=$(run_upgrade "$root" noversion 2>&1); rc=$?
if [ "$rc" -eq 4 ]; then pass "no parseable version after the upgrade is rc=4"; else fail "noversion case — expected rc=4 got $rc: $out"; fi
rm -rf "$root"

echo "[test-apply-tool-upgrade] upgrade.command is never shell-interpreted"
root=$(make_fixture)
run_upgrade "$root" metachar >/dev/null 2>&1
recorded="$root/state/recorded.txt"
assert_file_has "$recorded" 'unsafe; touch pwned_marker; echo owned' "the ';'-bearing argv element arrived as one literal argument"
# shellcheck disable=SC2016  # literal, unexpanded: that the value did NOT expand is the assertion
assert_file_has "$recorded" '$(echo evil)' "the \$(...) argv element arrived literal, unexpanded"
# shellcheck disable=SC2016  # literal, unexpanded: that the value did NOT expand is the assertion
assert_file_has "$recorded" '`echo backticks`' "the backtick argv element arrived literal, unexpanded"
if [ -f "$root/pwned_marker" ]; then fail "the embedded ';' command actually ran (pwned_marker exists)"; else pass "the embedded ';' command did NOT run (no pwned_marker)"; fi
rm -rf "$root"

echo "[test-apply-tool-upgrade] upgrade.command must be a non-empty array of strings"
root=$(make_fixture)
python3 - "$root" <<'PY'
import json, sys
p = sys.argv[1] + "/scripts/upstreams.json"
d = json.load(open(p))
for e in d["entries"]:
    if e["name"] == "success":
        e["upgrade"]["command"] = "bash bin/bump success 1.1.0"
json.dump(d, open(p, "w"), indent=2)
PY
assert_rc 2 "string upgrade.command (not an array) rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" success
rm -rf "$root"

root=$(make_fixture)
python3 - "$root" <<'PY'
import json, sys
p = sys.argv[1] + "/scripts/upstreams.json"
d = json.load(open(p))
for e in d["entries"]:
    if e["name"] == "success":
        e["upgrade"]["command"] = []
json.dump(d, open(p, "w"), indent=2)
PY
assert_rc 2 "empty-array upgrade.command rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" success
rm -rf "$root"

root=$(make_fixture)
python3 - "$root" <<'PY'
import json, sys
p = sys.argv[1] + "/scripts/upstreams.json"
d = json.load(open(p))
for e in d["entries"]:
    if e["name"] == "success":
        e["upgrade"]["command"] = ["bash", "bin/bump", 1]
json.dump(d, open(p, "w"), indent=2)
PY
assert_rc 2 "non-string element in upgrade.command rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$UPGRADE" success
rm -rf "$root"

echo "[test-apply-tool-upgrade] the REAL registry: graphify is wrong mode for this script"
REAL_ROOT=$(cd "$SCRIPT_DIR/.." && cd .. && pwd)
if [ -f "$REAL_ROOT/scripts/upstreams.json" ]; then
  # --dry-run only, never a real upgrade; refused before any tool is probed or
  # executed (kind/mode is checked before version_command is ever read), so
  # this never touches the real toolchain. Deliberately NOT asserting on rtk's
  # upgrade.unattended here: that's a live operator policy flag (this repo's
  # own upstreams.json note records it flipping true<->false), so pinning an
  # expected rc on it would make this suite flaky against unrelated registry
  # edits. graphify's kind/mode is a schema fact, not a policy call.
  out=$(DRIFT_REPO_ROOT="$REAL_ROOT" bash "$UPGRADE" graphify --dry-run 2>&1); rc=$?
  if [ "$rc" -eq 2 ]; then pass "graphify (mode:base) is rc=2 (wrong kind+mode)"; else fail "graphify — expected rc=2 got $rc: $out"; fi
else
  echo "  skip — live registry not found at $REAL_ROOT/scripts/upstreams.json"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "[test-apply-tool-upgrade] all checks passed"
  exit 0
fi
echo "[test-apply-tool-upgrade] $fails check(s) FAILED"
exit 1
