#!/usr/bin/env bash
# scripts/ci/test-ci-push-concurrency.sh -- regression suite for the top-level
# `concurrency:` block of .github/workflows/ci.yml (HIMMEL-3217 push-to-main,
# HIMMEL-3226 per-PR).
#
# Three run classes get three DISJOINT groups: a newer push to main cancels the
# superseded push-to-main run (they piled the Actions queue up to 5+ on
# 2026-09-19); a newer push to a PR cancels that PR's superseded run (one group
# per PR number, so two PRs never touch each other); schedule / dispatch runs
# keep a unique per-run group and are never cancelled. Pure text assertions over
# the workflow file (trailing YAML comments stripped, so a comment cannot satisfy
# a policy check); the group expression is then EVALUATED for sample events to
# prove the disjointness, and where PyYAML is importable the parsed values are
# asserted too. No network.
#
# Usage: bash scripts/ci/test-ci-push-concurrency.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# The workflow-level block: a column-0 `concurrency:` up to the next column-0 key.
# (The bun-suites job's concurrency is indented, so column 0 is unambiguous.)
block="$(awk '/^concurrency:/ {f=1; print; next} f && /^[^ #]/ {f=0} f' "$CI_YML" | sed 's/[[:space:]][[:space:]]*#.*$//')"

if [ -n "$block" ]; then ok "ci.yml has a workflow-level concurrency: block"
else bad "ci.yml has no workflow-level concurrency: block"; fi

group="$(sed -n 's/^  group:[[:space:]]*//p' <<< "$block")"
cancel="$(sed -n 's/^  cancel-in-progress:[[:space:]]*//p' <<< "$block")"

# A pull_request run groups on its PR number (so a leg's newer push meets its own
# older run, and nothing else)...
case "$group" in
  *"github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number)"*)
    ok "pull_request runs are grouped per PR number" ;;
  *) bad "pull_request runs are not grouped per PR number; group='$group'" ;;
esac
# ...push runs share one group per ref (so a newer main push meets the older run)...
case "$group" in
  *"github.event_name == 'push' && github.ref"*) ok "push runs are grouped by github.ref" ;;
  *) bad "push runs are not grouped by github.ref; group='$group'" ;;
esac
# ...and every other event gets a unique group, so nothing else ever queues or
# cancels (a shared group would cancel the nightly or a dispatch verification).
case "$group" in
  *"|| github.run_id"*) ok "other runs fall back to a unique group (run_id)" ;;
  *) bad "other runs do not get a unique group; group='$group'" ;;
esac
# cancel-in-progress is scoped to exactly the two grouped events: a bare `true`
# would cancel schedule/dispatch runs too if their group were ever widened.
if [ "$cancel" = "\${{ github.event_name == 'push' || github.event_name == 'pull_request' }}" ]; then
  ok "cancel-in-progress is scoped to push and pull_request events"
else
  bad "cancel-in-progress is not scoped to push and pull_request events; got '$cancel'"
fi

# The group key includes github.ref, so branches stay isolated from each other
# even if the trigger widens; but widening it would make every branch push start
# cancelling its own predecessor, so the comments/docs claim "push means main"
# only holds while the trigger stays restricted to main.
push_branches="$(awk '/^  push:/ {f=1; next} f && /branches:/ {print; exit} f && /^  [a-z_]+:/ {exit}' "$CI_YML" | sed 's/[[:space:]][[:space:]]*#.*$//')"
if [ "${push_branches#*'branches: [main]'}" != "$push_branches" ]; then
  ok "push trigger is restricted to branches: [main]"
else
  bad "push trigger is not restricted to branches: [main]"
fi

# Behavioural check: evaluate the group and cancel-in-progress expressions for
# sample events (GitHub's `&&` / `||` return their operand, like Python's
# and / or) and assert the three classes never share a group.
if python3 - "$group" "$cancel" <<'PY'
import re, sys
from types import SimpleNamespace as NS

def evaluate(expr, ctx):
    m = re.fullmatch(r"(.*?)\$\{\{\s*(.*?)\s*\}\}", expr.strip())
    prefix, inner = (m.group(1), m.group(2)) if m else ("", expr)
    inner = re.sub(r"format\('([^']*)\{0\}',\s*([^)]*)\)", r"('\1' + str(\2))", inner)
    inner = inner.replace("&&", " and ").replace("||", " or ")
    return prefix + str(eval(inner, {"__builtins__": {}, "str": str}, ctx)) if m else str(eval(inner, {"__builtins__": {}}, ctx))

def ctx(event, run_id, ref="refs/heads/x", pr=None):
    return {"github": NS(event_name=event, run_id=run_id, ref=ref,
                         event=NS(pull_request=NS(number=pr)))}

group, cancel = sys.argv[1], sys.argv[2]
runs = {
    "pr5-a":    ctx("pull_request", 1001, ref="refs/pull/5/merge", pr=5),
    "pr5-b":    ctx("pull_request", 1002, ref="refs/pull/5/merge", pr=5),
    "pr6":      ctx("pull_request", 1003, ref="refs/pull/6/merge", pr=6),
    "main-a":   ctx("push", 1004, ref="refs/heads/main"),
    "main-b":   ctx("push", 1005, ref="refs/heads/main"),
    "nightly":  ctx("schedule", 5, ref="refs/heads/main"),
    "dispatch": ctx("workflow_dispatch", 1006, ref="refs/heads/main"),
}
try:
    g = {k: evaluate(group, c) for k, c in runs.items()}
    c = {k: evaluate(cancel, x) for k, x in runs.items()}
except Exception as e:  # a group that does not evaluate cannot be disjoint
    print(f"FAIL - group/cancel expression does not evaluate: {e!r}")
    sys.exit(1)

errs = []
if g["pr5-a"] != g["pr5-b"]: errs.append("two runs of one PR do not share a group")
if g["pr5-a"] == g["pr6"]: errs.append("two PRs share a group")
if g["main-a"] != g["main-b"]: errs.append("two main pushes do not share a group")
if g["main-a"] in (g["pr5-a"], g["pr6"]): errs.append("a main push shares a group with a PR")
if len({g["nightly"], g["dispatch"], g["pr5-a"], g["pr6"], g["main-a"]}) != 5:
    errs.append("nightly/dispatch group collides with another class")
for k in ("pr5-a", "pr6", "main-a"):
    if c[k] != "True": errs.append(f"{k} does not cancel in progress (got {c[k]})")
for k in ("nightly", "dispatch"):
    if c[k] != "False": errs.append(f"{k} cancels in progress (got {c[k]})")
if errs:
    print("FAIL - " + "; ".join(errs) + f"; groups={g}")
    sys.exit(1)
print(f"ok - PR / main-push / nightly+dispatch groups are disjoint and cancel as intended; groups={g}")
PY
then :; else bad "resolved-group disjointness check failed (see output above)"; fi

# Parsed assertion: the text checks above are comment-stripped but still lexical.
# PyYAML is not guaranteed on every runner (the nightly adds windows/macOS), so
# this runs only where importable and reports a skip otherwise.
if python3 -c 'import yaml' >/dev/null 2>&1; then
  parsed="$(python3 - "$CI_YML" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
c = d.get("concurrency") or {}
on = d.get("on", d.get(True)) or {}
print(c.get("group"))
print(c.get("cancel-in-progress"))
print((on.get("push") or {}).get("branches"))
PY
)"
  want="ci-\${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number) || github.event_name == 'push' && github.ref || github.run_id }}
\${{ github.event_name == 'push' || github.event_name == 'pull_request' }}
['main']"
  if [ "$parsed" = "$want" ]; then ok "parsed YAML: group, cancel-in-progress and push branches match"
  else bad "parsed YAML mismatch; got: $parsed"; fi
else
  echo "skip - PyYAML not importable; parsed-YAML assertion not run"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
