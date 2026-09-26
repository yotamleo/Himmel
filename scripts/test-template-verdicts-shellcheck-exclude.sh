#!/usr/bin/env bash
# HIMMEL-3702: the luna template's shellcheck pre-commit hook must exclude
# handovers/**/verdicts/ (a console judge's probe/cases scripts, evidence its
# verdict rests on — not shipped code) the same way it already excludes
# handovers/**/specs/(console-kit-*|reports/*-artifacts)/, while a normal
# scripts/*.sh path is still linted.
#
# Extracts the shellcheck hook's `exclude` regex FROM the template's own
# .pre-commit-config.yaml (never hand-copied) and runs it through
# pre-commit's OWN filter_by_include_exclude() (pre_commit.commands.run), so
# this exercises pre-commit's real re.search() matching semantics rather than
# a hand-rolled regex engine.
#
# Skips (SKIP verdict, never a silent pass) if python3, PyYAML, or the
# pre_commit package are not importable.
#
# Usage: bash scripts/test-template-verdicts-shellcheck-exclude.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/templates/luna-second-brain/.pre-commit-config.yaml"

if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP - python3 not on PATH"
    exit 0
fi

OUT="$(python3 - "$CFG" <<'PYEOF'
import sys

try:
    import yaml
except ImportError:
    print("SKIP - PyYAML not importable")
    sys.exit(0)

try:
    from pre_commit.commands.run import filter_by_include_exclude
except ImportError:
    print("SKIP - pre_commit package not importable")
    sys.exit(0)

cfg_path = sys.argv[1]
with open(cfg_path, encoding="utf-8") as fh:
    cfg = yaml.safe_load(fh)

hook = None
for repo in cfg.get("repos", []):
    if "shellcheck-py" in repo.get("repo", ""):
        for h in repo.get("hooks", []):
            if h.get("id") == "shellcheck":
                hook = h
if hook is None:
    print("FAIL - no shellcheck-py/shellcheck hook found in the template .pre-commit-config.yaml")
    sys.exit(1)

# pre-commit's own schema default when `exclude` is absent: matches nothing.
exclude = hook.get("exclude", "^$")

VERDICT_PATH = "handovers/x/verdicts/J1/cases.sh"
NORMAL_PATH = "scripts/normal.sh"

fails = 0

kept = list(filter_by_include_exclude([VERDICT_PATH], "", exclude))
if kept == []:
    print(f"ok - {VERDICT_PATH} is excluded from shellcheck")
else:
    print(f"FAIL - {VERDICT_PATH} is NOT excluded from shellcheck (kept={kept})")
    fails += 1

kept = list(filter_by_include_exclude([NORMAL_PATH], "", exclude))
if kept == [NORMAL_PATH]:
    print(f"ok - {NORMAL_PATH} is still linted by shellcheck (control)")
else:
    print(f"FAIL - {NORMAL_PATH} was wrongly excluded from shellcheck (control broken, kept={kept})")
    fails += 1

sys.exit(1 if fails else 0)
PYEOF
)"
rc=$?
echo "$OUT"
echo "----"
if [ "$rc" -eq 0 ]; then
    echo "PASS: template-verdicts-shellcheck-exclude ($0)"
else
    echo "FAIL: template-verdicts-shellcheck-exclude ($0)" >&2
fi
exit "$rc"
