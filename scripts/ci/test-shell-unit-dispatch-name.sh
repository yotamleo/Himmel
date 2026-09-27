#!/usr/bin/env bash
# scripts/ci/test-shell-unit-dispatch-name.sh -- regression suite for
# HIMMEL-3788: a manual `workflow_dispatch` run of ci.yml with force_all_os
# must never produce a check-run named like the PR's own required
# `shell-unit (ubuntu-latest)` check. Before the fix, the `shell-unit`
# aggregating job had no `name:` override, so GitHub derived the check-run
# name purely from the job id + matrix value -- identical for every trigger
# event. A force_all_os dispatch on a PR branch posts that same-named check
# at the PR head, and its "macOS nightly jobs must have passed" step fails
# whenever any macOS shard is red (the normal state), shadowing the PR's own
# green pull_request-triggered run. Pure text + evaluated-expression
# assertions over the workflow file; no network.
#
# Usage: bash scripts/ci/test-shell-unit-dispatch-name.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# The `shell-unit:` job block: from its column-2 key line up to the next
# column-2 key (comments stripped so a comment can't satisfy a check).
block="$(awk '/^  shell-unit:$/ {f=1; next} f && /^  [a-zA-Z_-]+:/ {f=0} f' "$CI_YML" | sed 's/[[:space:]][[:space:]]*#.*$//')"

if [ -n "$block" ]; then ok "ci.yml has a shell-unit: job block"
else bad "ci.yml has no shell-unit: job block"; fi

name_expr="$(sed -n 's/^    name:[[:space:]]*//p' <<< "$block")"

if [ -n "$name_expr" ]; then
  ok "shell-unit job declares an explicit name: override"
else
  bad "shell-unit job has no name: override -- its check-run name is the bare job id + matrix value, identical across every trigger event"
fi

# Behavioural check: evaluate the name expression for the four trigger events
# this workflow handles and assert the dispatch-with-force_all_os name never
# collides with the pull_request/push/schedule name (the PR's required check).
if [ -n "$name_expr" ] && python3 - "$name_expr" <<'PY'
import re, sys
from types import SimpleNamespace as NS

def evaluate(expr, ctx):
    # Literal text around a ${{ }} block (e.g. the space before "(matrix.os)")
    # must survive recursion verbatim -- only the ${{ }} delimiters themselves
    # get whitespace-trimmed, never the surrounding prefix/rest text.
    m = re.fullmatch(r"(.*?)\$\{\{\s*(.*?)\s*\}\}(.*)", expr, re.DOTALL)
    if not m:
        return expr
    prefix, inner, rest = m.groups()
    inner = inner.replace("&&", " and ").replace("||", " or ")
    val = eval(inner, {"__builtins__": {}}, ctx)
    tail = evaluate(rest, ctx) if rest else ""
    return prefix + str(val) + tail

expr = sys.argv[1].strip()
events = {
    "pull_request": NS(event_name="pull_request"),
    "push":         NS(event_name="push"),
    "schedule":     NS(event_name="schedule"),
    "dispatch":     NS(event_name="workflow_dispatch"),
}
try:
    names = {k: evaluate(expr, {"github": v, "matrix": NS(os="ubuntu-latest")}) for k, v in events.items()}
except Exception as e:
    print(f"FAIL - name: expression does not evaluate: {e!r}")
    sys.exit(1)

REQUIRED_CHECK_NAME = "shell-unit (ubuntu-latest)"

errs = []
if names["dispatch"] == names["pull_request"]:
    errs.append("workflow_dispatch resolves to the SAME check-run name as pull_request -- a force_all_os dispatch shadows the PR's required check")
if names["pull_request"] != names["push"] or names["pull_request"] != names["schedule"]:
    errs.append("pull_request/push/schedule do not share one name -- the required-check name must stay stable across those events")
if names["pull_request"] != REQUIRED_CHECK_NAME:
    errs.append(f"pull_request no longer resolves to the branch protection required check {REQUIRED_CHECK_NAME!r} -- got {names['pull_request']!r}")
if errs:
    print("FAIL - " + "; ".join(errs) + f"; names={names}")
    sys.exit(1)
print(f"ok - workflow_dispatch's check-run name is distinct from the PR's required check; names={names}")
PY
then :; else bad "resolved shell-unit name does not keep workflow_dispatch distinct from pull_request/push/schedule (see output above)"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
