#!/usr/bin/env bash
# scripts/ci/test-ci-push-concurrency.sh -- regression suite for the top-level
# `concurrency:` block of .github/workflows/ci.yml (HIMMEL-3217 push-to-main,
# HIMMEL-3226 per-PR).
#
# Two run classes get two DISJOINT groups: a newer push to a PR cancels that
# PR's superseded run (one group per PR number, so two PRs never touch each
# other, HIMMEL-3226); every cron / dispatch run keeps a unique per-run group and
# is never cancelled. HIMMEL-5113 removed the push trigger and with it the shared
# push-to-main group (HIMMEL-3841 slice E): no run is grouped on github.ref.
# Pure text assertions over
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
# ...no run is grouped on a push event or a ref any more (HIMMEL-5113)...
case "$group" in
  *"'push'"*|*"github.ref"*) bad "group still keys on push / github.ref; group='$group'" ;;
  *) ok "group no longer keys on push or github.ref" ;;
esac
# ...and every other event gets a unique group, so nothing else ever queues or
# cancels (a shared group would cancel the nightly or a dispatch verification).
case "$group" in
  *"|| github.run_id"*) ok "other runs fall back to a unique group (run_id)" ;;
  *) bad "other runs do not get a unique group; group='$group'" ;;
esac
# cancel-in-progress is scoped to pull_request alone: a bare `true` would cancel
# a RUNNING main sweep or nightly.
if [ "$cancel" = "\${{ github.event_name == 'pull_request' }}" ]; then
  ok "cancel-in-progress is scoped to pull_request only (sweeps are never cancelled)"
else
  bad "cancel-in-progress is not scoped to pull_request only; got '$cancel'"
fi

# A re-added push trigger would run unique-group (uncancelled, unserialised)
# sweeps on every merge again -- the cost HIMMEL-5113 removed.
if awk '/^on:/ {f=1; next} f && /^[^ #]/ {f=0} f' "$CI_YML" | grep -q '^  push:'; then
  bad "ci.yml has a push: trigger again (HIMMEL-5113 removed it; main runs on cron)"
else
  ok "ci.yml has no push: trigger"
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
    "main-a":   ctx("schedule", 1004, ref="refs/heads/main"),
    "main-b":   ctx("schedule", 1005, ref="refs/heads/main"),
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
if g["main-a"] == g["main-b"]: errs.append("two main cron runs share a group (one would queue behind the other)")
if len({g["nightly"], g["dispatch"], g["pr5-a"], g["pr6"], g["main-a"], g["main-b"]}) != 6:
    errs.append("a cron / dispatch group collides with another class")
for k in ("pr5-a", "pr6"):
    if c[k] != "True": errs.append(f"{k} does not cancel in progress (got {c[k]})")
for k in ("main-a", "main-b", "nightly", "dispatch"):
    if c[k] != "False": errs.append(f"{k} cancels in progress (got {c[k]})")
if errs:
    print("FAIL - " + "; ".join(errs) + f"; groups={g}")
    sys.exit(1)
print(f"ok - PR / main-cron / nightly+dispatch groups are disjoint; only PRs cancel in progress; groups={g}")
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
print("push" in on)
PY
)"
  want="ci-\${{ github.event_name == 'pull_request' && format('pr-{0}', github.event.pull_request.number) || github.run_id }}
\${{ github.event_name == 'pull_request' }}
False"
  if [ "$parsed" = "$want" ]; then ok "parsed YAML: group, cancel-in-progress match and there is no push trigger"
  else bad "parsed YAML mismatch; got: $parsed"; fi
else
  echo "skip - PyYAML not importable; parsed-YAML assertion not run"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
