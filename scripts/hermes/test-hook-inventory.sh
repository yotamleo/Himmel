#!/usr/bin/env bash
# Hook inventory assertion for the Hermes himmel_agent profile (HIMMEL-2021).
#
# The installer owns himmel_agent's whole `hooks:` block, so the block IS the
# inventory: a dropped hook type is invisible everywhere else. Two invocations
# are asserted, both the ones install-himmel-profile.sh can make:
#
#   A) the full shape a fresh install produces — pre_tool_call -> parity_guard
#      AND the end-side on_session_finalize chain;
#   B) the degraded shape (no node / no himmel checkout) — guard only, and in
#      particular NO half-written end block.
#
# on_session_finalize, never on_session_end: finalize is the once-per-identity
# teardown, on_session_end is turn-scoped and would relay on every turn.
#
# Run with: bash scripts/hermes/test-hook-inventory.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WIRE="$SCRIPT_DIR/assets/wire_parity_guard.py"
GUARD="$SCRIPT_DIR/assets/parity_guard.py"

PY="$(command -v python3 || command -v python)" || {
    echo "SKIP: test-hook-inventory.sh needs python3/python on PATH."
    exit 0
}

[ -f "$WIRE" ] || { echo "FAIL: wire_parity_guard asset absent: $WIRE" >&2; exit 1; }
[ -f "$GUARD" ] || { echo "FAIL: parity_guard asset absent: $GUARD" >&2; exit 1; }

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/himmel-hermes-hook-inventory.XXXXXX")" || {
    echo "FAIL: could not create temp dir" >&2
    exit 1
}
trap 'rm -rf "$tmpdir"' EXIT

echo "== himmel_agent hook inventory =="

# wire <case-name> <config> [extra args...] — run the same `set` invocation the
# installer uses; a non-zero exit is a hard failure, never a skipped case.
wire() {
    local name="$1" cfg="$2"; shift 2
    printf 'profile: himmel_agent\n' > "$cfg"
    if ! "$PY" "$WIRE" set "$cfg" "$GUARD" "$PY" "$@" > "$tmpdir/wire-$name.out" 2>&1; then
        echo "FAIL: wire_parity_guard.py set failed ($name)" >&2
        cat "$tmpdir/wire-$name.out" >&2
        exit 1
    fi
}

wire full "$tmpdir/full.yaml" "$(command -v node || echo node)" "$REPO_ROOT"
wire guardonly "$tmpdir/guardonly.yaml"

"$PY" - "$tmpdir/full.yaml" "$tmpdir/guardonly.yaml" <<'PY'
import re
import sys


def read_hooks(cfg):
    """Parse the top-level `hooks:` block into {event: [command, ...]}."""
    with open(cfg, "r", encoding="utf-8") as f:
        lines = f.readlines()
    hooks, in_hooks, event = {}, False, None
    for line in lines:
        if line.startswith("hooks:") and not line[:1].isspace():
            in_hooks, event = True, None
            continue
        if not in_hooks:
            continue
        if line.strip() and not line[:1].isspace():
            break
        match = re.match(r"^  ([A-Za-z_]+):\s*$", line)
        if match:
            event = match.group(1)
            hooks.setdefault(event, [])
            continue
        # `command:` may be the first key of a list item (`- command: ...`) or a
        # later key of one (`    command: ...`); both are the same entry field.
        stripped = line.lstrip()
        if stripped.startswith("- "):
            stripped = stripped[2:]
        if event and stripped.startswith("command:"):
            hooks.setdefault(event, []).append(
                stripped.split("command:", 1)[1].strip().strip("'"))
    return hooks


def scripts_in(command):
    """Every script basename a command names, in order."""
    return [m.rsplit("/", 1)[-1] for m in
            re.findall(r'[^"\s]+\.(?:py|js|sh)', command.replace("\\", "/"))]


fails = []


def check(label, actual, expected):
    if actual == expected:
        print(f"  ok: {label} -> {actual}")
    else:
        fails.append(f"{label} expected {expected} got {actual}")


# --- A) full install: guard + end chain -------------------------------------
full = read_hooks(sys.argv[1])
check("full: hook events", sorted(full), ["on_session_finalize", "pre_tool_call"])
check("full: pre_tool_call scripts",
      [scripts_in(c) for c in full.get("pre_tool_call", [])],
      [["parity_guard.py"]])
# ONE entry, not one per member: the chain is what keeps a hermes teardown to a
# single node launch (HIMMEL-2002/2003). Two entries here would be a regression
# even though the same hooks run.
check("full: on_session_finalize scripts",
      [scripts_in(c) for c in full.get("on_session_finalize", [])],
      [["run-hook-with-bash.js",
        "refresh-where-are-we-on-end.sh",
        "telegram-session-end.sh"]])
end_cmd = (full.get("on_session_finalize") or [""])[0]
check("full: end chain is advisory (--chain --lifecycle)",
      "--chain --lifecycle" in end_cmd, True)

# --- B) degraded install: guard only, no partial end block ------------------
guardonly = read_hooks(sys.argv[2])
check("guard-only: hook events", sorted(guardonly), ["pre_tool_call"])
check("guard-only: pre_tool_call scripts",
      [scripts_in(c) for c in guardonly.get("pre_tool_call", [])],
      [["parity_guard.py"]])

for line in fails:
    print(f"  FAIL: {line}", file=sys.stderr)
if fails:
    print(f"FAIL: {len(fails)} hook inventory assertion(s) failed", file=sys.stderr)
    sys.exit(1)
print("PASS: hermes hook inventory matches expected list")
PY
inv_rc=$?

# --- C) registry conformance (HIMMEL-2637) -----------------------------------
# The hook matcher is fullmatch-ed against the tool name, and pre_tool_call is
# the ONLY blocking event: a registered tool the matcher does not cover never
# reaches parity_guard.py at all. test-parity-guard.sh proves the guard DENIES
# correctly when invoked; this proves the matcher DELIVERS. The registry is read
# statically from the installed hermes source (never imported — importing it
# would initialise tools that hold live credentials); when no install is present
# the fixture controls below still run, and the installed scan is reported SKIP.
REGISTRY_SRC="${HERMES_AGENT_SRC:-${HERMES_HOME:-$HOME/.hermes}/hermes-agent}"

mkdir -p "$tmpdir/fixture-good/tools" "$tmpdir/fixture-new/tools"
cat > "$tmpdir/fixture-good/tools/a.py" <<'EOF'
registry.register(
    name="terminal",
    toolset="terminal",
)
registry.register(
    name="execute_code",
    toolset="code",
)
EOF
cat > "$tmpdir/fixture-new/tools/b.py" <<'EOF'
registry.register(
    name="zz_tool_added_by_a_hermes_upgrade",
    toolset="new",
)
EOF

HERMES_HOME="$tmpdir/hermes-home" "$PY" - "$tmpdir/full.yaml" "$GUARD" \
    "$REGISTRY_SRC" "$tmpdir/fixture-good" "$tmpdir/fixture-new" <<'PY'
import glob
import importlib.util
import os
import re
import sys

cfg, guard_path, installed, fixture_good, fixture_new = sys.argv[1:6]

# The matcher exactly as hermes would read it out of the wired config.
matcher = None
for line in open(cfg, encoding="utf-8"):
    m = re.match(r"^\s*-?\s*matcher:\s*(.*?)\s*$", line)
    if m:
        matcher = m.group(1)
        break

spec = importlib.util.spec_from_file_location("parity_guard_under_test", guard_path)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def registry_names(src):
    """Tool names declared by tools/*.py: registry.register(name=...) plus the
    schema `"name": ...` form the table-driven modules use."""
    names = set()
    for path in glob.glob(os.path.join(src, "tools", "*.py")):
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        names.update(re.findall(
            r'registry\.register\(\s*name\s*=\s*"([a-z][a-z0-9_]*)"', text))
        names.update(re.findall(r'"name":\s*"([a-z][a-z0-9_]*)"', text))
    return names


def fullmatches(pattern, name):
    """hermes' matches_tool: fullmatch, literal equality if it will not compile."""
    try:
        return re.compile(pattern).fullmatch(name) is not None
    except re.error:
        return name == pattern


def problems(names, pattern, classify):
    out = []
    for name in sorted(names):
        if not fullmatches(pattern, name):
            out.append(f"{name}: matcher does not deliver it to the guard")
        elif classify(name) is None:
            out.append(f"{name}: delivered but not classified by parity_guard "
                       "(the guard fails it closed)")
    return out


fails = []


def check(label, actual, expected):
    if actual == expected:
        print(f"  ok: {label}")
    else:
        fails.append(f"{label}: expected {expected!r} got {actual!r}")


# The matcher this fix replaced. It stays here as the RED control: the checker
# must flag every tool it never delivered.
OLD = ("write_file|patch|read_file|search_files|terminal|"
       "delete_file|remove_file|move_file|rename_file|mcp__.*")
old_bad = problems({"execute_code", "delegate_task", "skill_manage",
                    "browser_navigate", "terminal"}, OLD, guard.classify_tool)
check("control: pre-fix matcher leaves execute_code undelivered",
      any(p.startswith("execute_code:") and "matcher" in p for p in old_bad), True)
check("control: pre-fix matcher leaves skill_manage undelivered",
      any(p.startswith("skill_manage:") and "matcher" in p for p in old_bad), True)
check("control: pre-fix matcher still delivers terminal",
      any(p.startswith("terminal:") for p in old_bad), False)

check("wired matcher was parsed", bool(matcher), True)
for dead in ("delete_file", "remove_file", "move_file", "rename_file"):
    check(f"wired matcher carries no dead term {dead}",
          dead in (matcher or ""), False)

# A tool a hermes upgrade adds must FAIL the check until the guard classifies it.
new_bad = problems(registry_names(fixture_new), matcher or "", guard.classify_tool)
check("control: an unclassified new registry tool is flagged",
      [p.split(":")[0] for p in new_bad], ["zz_tool_added_by_a_hermes_upgrade"])
good = problems(registry_names(fixture_good), matcher or "", guard.classify_tool)
check("fixture registry (terminal, execute_code) fully covered", good, [])

# The installed registry: report every gap, not just the first.
if os.path.isdir(os.path.join(installed, "tools")):
    names = registry_names(installed)
    check(f"installed registry sane ({len(names)} tools found)", len(names) > 20, True)
    real = problems(names, matcher or "", guard.classify_tool)
    check(f"installed hermes registry ({installed}) fully covered", real, [])
else:
    print(f"  skip: no installed hermes source at {installed} "
          "(set HERMES_AGENT_SRC); fixture controls above still enforce")

for line in fails:
    print(f"  FAIL: {line}", file=sys.stderr)
if fails:
    print(f"FAIL: {len(fails)} registry conformance assertion(s) failed", file=sys.stderr)
    sys.exit(1)
print("PASS: every registered tool reaches, and is classified by, parity_guard")
PY
conf_rc=$?
[ "$inv_rc" -eq 0 ] && [ "$conf_rc" -eq 0 ]
