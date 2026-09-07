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
