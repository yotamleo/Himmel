#!/usr/bin/env bash
# Hermetic tests for the cross-platform descendant-walk logic added to
# reap-mcp-fleet.sh by HIMMEL-840 (_reap_descendants - the bash twin of
# reap-mcp-fleet.ps1's Get-DescendantPids, unit-tested in
# test-reap-mcp-fleet.ps1). No real process table is touched: this file
# sources reap-mcp-fleet.sh (the sourcing guard skips production code, only
# defining functions - same seam shared-branch-lock.sh uses) and feeds
# _reap_descendants a synthetic proc-table fixture.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

# shellcheck source=scripts/codex/reap-mcp-fleet.sh
. "$SCRIPT_DIR/reap-mcp-fleet.sh"

# --- Test 1: codex-exec CLI sandbox fleet (dead registered root) found via --
# the descendant walk; a live-claude MCP fleet (same table, same process
# shapes) is spared because it is not a descendant of the dead root.
TABLE_SANDBOX="500 1 100
501 500 110
502 501 111
503 502 112
700 1 50
701 700 200
702 700 201"
# pid 500 (the dead codex-exec root) is deliberately ABSENT from the table -
# only its still-live descendants (501/502/503) appear, exactly like the
# real incident: codex.exe already exited, its MCP-fleet children did not.

got="$(_reap_descendants "$TABLE_SANDBOX" 500 | sort -n | tr '\n' ',')"
want="501,502,503,"
if [ "$got" = "$want" ]; then
  pass "sandbox fleet {501,502,503} found via descendant walk (got=$got)"
else
  fail "sandbox fleet mismatch: got=$got want=$want"
fi

case ",$got" in
  *",701,"*) fail "live-claude MCP 701 wrongly reaped (not a descendant of 500)" ;;
  *) pass "live-claude MCP 701 spared" ;;
esac
case ",$got" in
  *",702,"*) fail "live-claude MCP 702 wrongly reaped (same process shape as 501, still not a descendant)" ;;
  *) pass "live-claude MCP 702 spared" ;;
esac
case ",$got" in
  *",500,"*) fail "dead root pid 500 itself must not be returned (only its descendants)" ;;
  *) pass "dead root pid 500 itself not returned" ;;
esac

# --- Test 2: pid-reuse guard (started-at >= table's start-epoch column) -----
TABLE_REUSE="510 1 100
511 510 50"
# pid 511's own start-epoch (50) predates the job's started-at (200) - it
# belongs to whatever unrelated process reused pid 510's slot, not our job.
guarded="$(_reap_descendants "$TABLE_REUSE" 510 200 | tr '\n' ',')"
if [ -z "$guarded" ]; then
  pass "pid-reuse guard excludes a descendant that predates started-at"
else
  fail "pid-reuse guard did not exclude: $guarded"
fi
unguarded="$(_reap_descendants "$TABLE_REUSE" 510 | tr '\n' ',')"
if [ "$unguarded" = "511," ]; then
  pass "without started-at the same descendant IS found"
else
  fail "unguarded walk mismatch: got=$unguarded want=511,"
fi

# --- Test 3: empty/absent-root inputs do not error -------------------------
empty_out="$(_reap_descendants "" 999 || true)"
if [ -z "$empty_out" ]; then
  pass "empty proc table -> no descendants"
else
  fail "empty proc table produced output: $empty_out"
fi
none_out="$(_reap_descendants "$TABLE_SANDBOX" 999999 || true)"
if [ -z "$none_out" ]; then
  pass "root pid with no children in the table -> no descendants"
else
  fail "no-children root produced output: $none_out"
fi

# --- Test 4: malformed argv - missing option value fails fast, no hang ------
# (HIMMEL-840 Fix 2: `shift 2` under `set -u` without `-e` was a no-op when
# only one arg remained, spinning the option-parsing `while` loop forever -
# confirmed rc=124 under `timeout` before the fix. Invokes the real script as
# a subprocess, wrapped in `timeout`, so a regression here would show up as
# rc=124 rather than hanging the whole test run.)
out="$(timeout 5 bash "$SCRIPT_DIR/reap-mcp-fleet.sh" --root-pid 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
  pass "missing --root-pid value fails fast (rc=$rc, not a hang)"
else
  fail "missing --root-pid value: rc=$rc (want nonzero and not 124) out=$out"
fi
case "$out" in
  *"missing value for --root-pid"*) pass "missing --root-pid value names the flag" ;;
  *) fail "missing --root-pid value message: $out" ;;
esac

out="$(timeout 5 bash "$SCRIPT_DIR/reap-mcp-fleet.sh" --root-pid 123 --started-at 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
  pass "missing --started-at value fails fast (rc=$rc, not a hang)"
else
  fail "missing --started-at value: rc=$rc (want nonzero and not 124) out=$out"
fi
case "$out" in
  *"missing value for --started-at"*) pass "missing --started-at value names the flag" ;;
  *) fail "missing --started-at value message: $out" ;;
esac

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"
  exit 1
fi
echo "ALL PASS"
