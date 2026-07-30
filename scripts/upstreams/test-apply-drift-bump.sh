#!/usr/bin/env bash
# scripts/upstreams/test-apply-drift-bump.sh — hermetic suite for the
# mechanical upstream pin bumper (HIMMEL-1323).
#
# Fully offline: every case builds a throwaway repo root (registry + a fake pin
# file) under a temp dir and points the script at it via DRIFT_REGISTRY /
# DRIFT_REPO_ROOT. No network, no gh, no git.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUMP="$SCRIPT_DIR/apply-drift-bump.sh"

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

assert_file_has() {
  local path="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    pass "$label"
  else
    fail "$label — '$needle' not in $path"
  fi
}

assert_file_lacks() {
  local path="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$path" 2>/dev/null; then
    fail "$label — '$needle' unexpectedly still in $path"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# fixture: a repo root with a two-entry registry (one auto-bumpable, one not)
# plus the pin file the bumpable entry points at. Echoes the root path.
# ---------------------------------------------------------------------------
make_fixture() {
  local root
  root=$(mktemp -d)
  mkdir -p "$root/scripts/lib"
  cat > "$root/scripts/upstreams.json" <<'JSON'
{
  "_comment": "fixture",
  "entries": [
    {
      "name": "widget",
      "kind": "tag_release",
      "mode": "base",
      "tracked_repo": "acme/widget",
      "synced_base": "1.2.3",
      "version_pin": { "file": "scripts/lib/widget-bin.sh", "template": "WIDGET_VERSION:-{version}" },
      "tier": "A",
      "note": "auto-bumpable fixture entry"
    },
    {
      "name": "forked",
      "kind": "tag_release",
      "mode": "base",
      "tracked_repo": "acme/forked",
      "synced_base": "1.2.3",
      "tier": "B",
      "note": "no version_pin — stands in for qmd"
    },
    {
      "name": "probed",
      "kind": "tag_release",
      "mode": "probe",
      "tracked_repo": "acme/probed",
      "version_command": "probed --version",
      "version_regex": "[0-9]+",
      "tier": "B"
    }
  ]
}
JSON
  cat > "$root/scripts/lib/widget-bin.sh" <<'SH'
# fixture resolver
# The pinned version is overridable via WIDGET_VERSION for testing.
_widget_version() { printf '%s\n' "${WIDGET_VERSION:-1.2.3}"; }
_widget_name() { printf '%s\n' "widgetty"; }
SH
  printf '%s' "$root"
}

run_bump() {
  local root="$1"; shift
  DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" "$@"
}

echo "[test-apply-drift-bump] usage + arg validation"
assert_rc 2 "no args is a usage error" -- bash "$BUMP"
assert_rc 2 "one arg is a usage error" -- bash "$BUMP" widget
root=$(make_fixture)
assert_rc 2 "unknown flag rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4 --nope
assert_rc 2 "extra positional rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4 extra
assert_rc 2 "non-version target rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget "not-a-version"
assert_rc 2 "unknown entry name rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" nosuch 1.2.4
assert_rc 2 "probe-mode entry rejected (no in-repo pin)" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" probed 1.2.4
rm -rf "$root"

echo "[test-apply-drift-bump] missing registry"
assert_rc 2 "absent registry is rc=2" -- env DRIFT_REPO_ROOT=/nonexistent DRIFT_REGISTRY=/nonexistent/upstreams.json bash "$BUMP" widget 1.2.4

echo "[test-apply-drift-bump] happy path"
root=$(make_fixture)
out=$(run_bump "$root" widget 1.2.4 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "bump exits 0"; else fail "bump exits 0 — got rc=$rc: $out"; fi
assert_contains "$out" "BUMP widget 1.2.3 -> 1.2.4" "prints the machine BUMP line"
assert_file_has "$root/scripts/lib/widget-bin.sh" 'WIDGET_VERSION:-1.2.4' "pin literal rewritten"
assert_file_lacks "$root/scripts/lib/widget-bin.sh" 'WIDGET_VERSION:-1.2.3' "old pin literal gone"
assert_file_has "$root/scripts/upstreams.json" '"synced_base": "1.2.4"' "synced_base rewritten"
# The OTHER entry shares the old version — it must not have been touched.
sb_count=$(grep -cF '"synced_base": "1.2.3"' "$root/scripts/upstreams.json")
if [ "$sb_count" -eq 1 ]; then pass "sibling entry sharing the old version untouched"; else fail "sibling entry sharing the old version was modified (1.2.3 count=$sb_count)"; fi
# Non-pin text in the resolver survives.
assert_file_has "$root/scripts/lib/widget-bin.sh" '_widget_name' "unrelated resolver text intact"
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$root/scripts/upstreams.json"; then pass "registry still parses"; else fail "registry no longer parses"; fi
rm -rf "$root"

echo "[test-apply-drift-bump] leading 'v' on the target is accepted"
root=$(make_fixture)
out=$(run_bump "$root" widget v1.3.0 2>&1)
assert_contains "$out" "BUMP widget 1.2.3 -> 1.3.0" "v-prefix normalized"
assert_file_has "$root/scripts/lib/widget-bin.sh" 'WIDGET_VERSION:-1.3.0' "pin written without the v"
rm -rf "$root"

echo "[test-apply-drift-bump] idempotence + downgrade guard"
root=$(make_fixture)
assert_rc 1 "same version is rc=1 (nothing to do)" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.3
assert_rc 2 "downgrade refused" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.2
assert_file_has "$root/scripts/lib/widget-bin.sh" 'WIDGET_VERSION:-1.2.3' "downgrade left the pin alone"
# Re-running the same bump twice is a no-op the second time.
run_bump "$root" widget 1.2.4 >/dev/null 2>&1
assert_rc 1 "second identical bump is rc=1" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4
rm -rf "$root"

echo "[test-apply-drift-bump] --dry-run writes nothing"
root=$(make_fixture)
out=$(run_bump "$root" widget 1.2.4 --dry-run 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "dry-run exits 0"; else fail "dry-run exits 0 — got rc=$rc: $out"; fi
assert_contains "$out" "DRY widget 1.2.3 -> 1.2.4" "dry-run prints the DRY line"
assert_file_has "$root/scripts/lib/widget-bin.sh" 'WIDGET_VERSION:-1.2.3' "dry-run left the pin file alone"
assert_file_has "$root/scripts/upstreams.json" '"synced_base": "1.2.3"' "dry-run left the registry alone"
rm -rf "$root"

echo "[test-apply-drift-bump] entry without version_pin is SKIP, not a silent bump"
root=$(make_fixture)
out=$(run_bump "$root" forked 1.2.4 2>&1); rc=$?
if [ "$rc" -eq 3 ]; then pass "no version_pin is rc=3 (SKIP)"; else fail "no version_pin — expected rc=3 got $rc: $out"; fi
assert_contains "$out" "SKIP forked" "prints a SKIP line naming the entry"
assert_file_has "$root/scripts/upstreams.json" '"synced_base": "1.2.3"' "SKIP left synced_base alone"
rm -rf "$root"

echo "[test-apply-drift-bump] unapplicable pin literal fails loudly, restores both files"
root=$(make_fixture)
# Template no longer matches the resolver: the bump must abort, not half-apply.
python3 - "$root" <<'PY'
import json, sys
p = sys.argv[1] + "/scripts/upstreams.json"
d = json.load(open(p))
d["entries"][0]["version_pin"]["template"] = "NOT_PRESENT:-{version}"
json.dump(d, open(p, "w"), indent=2)
PY
before_pin=$(cat "$root/scripts/lib/widget-bin.sh")
before_reg=$(cat "$root/scripts/upstreams.json")
assert_rc 4 "absent pin literal is rc=4" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4
if [ "$(cat "$root/scripts/lib/widget-bin.sh")" = "$before_pin" ]; then pass "pin file byte-identical after the failure"; else fail "pin file was modified on a failed bump"; fi
if [ "$(cat "$root/scripts/upstreams.json")" = "$before_reg" ]; then pass "registry byte-identical after the failure"; else fail "registry was modified on a failed bump"; fi
rm -rf "$root"

echo "[test-apply-drift-bump] pin write failure restores the pin file too (disk-full)"
root=$(make_fixture)
pin="$root/scripts/lib/widget-bin.sh"
before_pin=$(cat "$pin")
before_reg=$(cat "$root/scripts/upstreams.json")
# Reproduce the truncation window open(p, "w") creates: a sitecustomize on
# PYTHONPATH makes the FIRST write to the pin path truncate-then-raise ENOSPC
# (disk-full), but lets a later restore write through. This is the only hermetic
# way to trigger a write-AFTER-truncation failure on a regular file without a
# full disk; it runs the real bash wrapper + python unchanged. (CR round-9)
scdir=$(mktemp -d)
cat > "$scdir/sitecustomize.py" <<'PY'
import builtins, os
_real_open = builtins.open
_target = os.environ.get("DRIFT_TEST_BREAK_PIN_WRITE", "")
_count = {"n": 0}
class _NoSpace:
    def __init__(self, fh): self._fh = fh
    def write(self, s):
        _count["n"] += 1
        if _count["n"] == 1:            # the bump's new_pin_text write -> fail
            raise OSError(28, "No space left on device (simulated by test)")
        return self._fh.write(s)        # a restore write -> let it through
    def __getattr__(self, n): return getattr(self._fh, n)
    def __enter__(self): return self
    def __exit__(self, *a):
        try: self._fh.close()
        except Exception: pass
def _patched(path, mode="r", *a, **k):
    fh = _real_open(path, mode, *a, **k)
    if _target and "w" in mode and os.path.abspath(path) == os.path.abspath(_target):
        return _NoSpace(fh)
    return fh
builtins.open = _patched
PY
out=$(DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" \
     DRIFT_TEST_BREAK_PIN_WRITE="$pin" PYTHONPATH="$scdir" \
     bash "$BUMP" widget 1.2.4 2>&1); rc=$?
if [ "$rc" -eq 4 ]; then pass "pin write failure is rc=4"; else fail "pin write failure — expected rc=4 got rc=$rc: $out"; fi
if [ "$(cat "$pin")" = "$before_pin" ]; then
  pass "pin file restored to its original content after the failed write"
else
  fail "pin file left truncated/modified after the failed write (invariant 'both files untouched' violated)"
fi
if [ "$(cat "$root/scripts/upstreams.json")" = "$before_reg" ]; then
  pass "registry restored to its original content too"
else
  fail "registry was not restored after the pin write failure"
fi
assert_contains "$out" "both files restored" "failure message states both files were restored"
rm -rf "$root" "$scdir"

echo "[test-apply-drift-bump] ambiguous pin literal is refused"
root=$(make_fixture)
# shellcheck disable=SC2016  # single quotes are the point: this appends a SECOND
# literal copy of the pin template to the fixture, so the bumper must refuse it as
# ambiguous. Expanding it here would defeat the case.
printf '%s\n' '_widget_version_again() { printf "%s\\n" "${WIDGET_VERSION:-1.2.3}"; }' >> "$root/scripts/lib/widget-bin.sh"
assert_rc 4 "two matches is rc=4" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4
assert_file_has "$root/scripts/upstreams.json" '"synced_base": "1.2.3"' "ambiguous match left the registry alone"
rm -rf "$root"

echo "[test-apply-drift-bump] missing pin file is rc=4"
root=$(make_fixture)
rm -f "$root/scripts/lib/widget-bin.sh"
assert_rc 4 "absent pin file is rc=4" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4
rm -rf "$root"

echo "[test-apply-drift-bump] version_pin.file may not escape the repo root"
root=$(make_fixture)
python3 - "$root" <<'PY'
import json, sys
p = sys.argv[1] + "/scripts/upstreams.json"
d = json.load(open(p))
d["entries"][0]["version_pin"]["file"] = "../outside/widget-bin.sh"
json.dump(d, open(p, "w"), indent=2)
PY
assert_rc 2 "'..' in version_pin.file rejected" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4
rm -rf "$root"

echo "[test-apply-drift-bump] malformed registry is rc=2, never a bump"
root=$(make_fixture)
printf '%s' '{ not json' > "$root/scripts/upstreams.json"
assert_rc 2 "unparseable registry is rc=2" -- env DRIFT_REPO_ROOT="$root" DRIFT_REGISTRY="$root/scripts/upstreams.json" bash "$BUMP" widget 1.2.4
rm -rf "$root"

echo "[test-apply-drift-bump] CRLF pin files keep their line endings"
root=$(make_fixture)
python3 - "$root" <<'PY'
import sys
p = sys.argv[1] + "/scripts/lib/widget-bin.sh"
data = open(p, "r", encoding="utf-8", newline="").read().replace("\n", "\r\n")
open(p, "w", encoding="utf-8", newline="").write(data)
PY
run_bump "$root" widget 1.2.4 >/dev/null 2>&1
crlf=$(python3 -c "import sys;d=open(sys.argv[1],'rb').read();print(d.count(b'\r\n'), d.count(b'\n')-d.count(b'\r\n'))" "$root/scripts/lib/widget-bin.sh")
case "$crlf" in
  *" 0") pass "CRLF preserved (no LF-only lines introduced): $crlf" ;;
  *) fail "line endings changed — crlf/lf counts: $crlf" ;;
esac
assert_file_has "$root/scripts/lib/widget-bin.sh" 'WIDGET_VERSION:-1.2.4' "CRLF file still got bumped"
rm -rf "$root"

echo "[test-apply-drift-bump] the REAL registry: graphify is auto-bumpable, qmd is not"
REAL_ROOT=$(cd "$SCRIPT_DIR/.." && cd .. && pwd)
if [ -f "$REAL_ROOT/scripts/upstreams.json" ]; then
  # --dry-run only: never write to the live tree from a test.
  out=$(DRIFT_REPO_ROOT="$REAL_ROOT" bash "$BUMP" graphify 99.99.99 --dry-run 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass "graphify resolves against the live registry (dry-run)"; else fail "graphify dry-run — expected rc=0 got $rc: $out"; fi
  assert_contains "$out" "scripts/lib/graphify-bin.sh" "graphify version_pin points at the real resolver"
  out=$(DRIFT_REPO_ROOT="$REAL_ROOT" bash "$BUMP" qmd 99.99.99 --dry-run 2>&1); rc=$?
  if [ "$rc" -eq 3 ]; then pass "qmd is SKIP (fork SHA pin, not auto-bumpable)"; else fail "qmd — expected rc=3 (SKIP) got $rc: $out"; fi
else
  echo "  skip — live registry not found at $REAL_ROOT/scripts/upstreams.json"
fi

echo ""
if [ "$fails" -eq 0 ]; then
  echo "[test-apply-drift-bump] all checks passed"
  exit 0
fi
echo "[test-apply-drift-bump] $fails check(s) FAILED"
exit 1
