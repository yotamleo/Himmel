#!/usr/bin/env bash
# scripts/eval/test-context-replay.sh - tests for context-replay.py (HIMMEL-5042).
# Synthetic session: 60 calls, context 50k growing 10k per call, 100 out each.
# Platform guard: POSIX bash + python3; no .ps1 twin (eval tooling, linux only).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/context-replay.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
# check <description> <test-cmd...>: ok when the command succeeds
check() { d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

python3 -I - "$TMP/s.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(60):
        ctx = 50000 + 10000 * i
        cc, cr = (ctx, 0) if i == 0 else (10000, ctx - 10000)
        f.write(json.dumps({"type": "assistant", "requestId": f"r{i}", "message": {"model": "m", "usage": {
            "input_tokens": 0, "cache_read_input_tokens": cr,
            "cache_creation_input_tokens": cc, "output_tokens": 100}}}) + "\n")
PY

run() { python3 -I "$HERE/context-replay.py" --glob "$TMP/*.jsonl" --min-calls 5 --windows "$1" --json; }
field() { python3 -I -c 'import json,sys; d=json.load(sys.stdin)["kinds"]["other"]; print(eval(sys.argv[1]))' "$1"; }

out="$(run 1000000,200000)"
act="$(echo "$out" | field 'd["actual_cost_eq"]')"
unb="$(echo "$out" | field 'd["unbounded_cost_eq"]')"
check "unbounded replay reproduces the recorded cost ($act)" [ "$act" = "$unb" ]

big="$(echo "$out" | field 'd["windows"]["1000000/compact"]["events"]')"
small="$(echo "$out" | field 'd["windows"]["200000/compact"]["events"]')"
check "window above the 640k peak never compacts ($big)" [ "$big" = 0 ]
check "200000 window compacts ($small)" [ "$small" -ge 1 ]

cb="$(echo "$out" | field 'd["windows"]["1000000/compact"]["cost_eq"]')"
cs="$(echo "$out" | field 'd["windows"]["200000/compact"]["cost_eq"]')"
check "tighter window is cheaper on a monotonic session ($cs vs $cb)" \
    python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[2]) < float(sys.argv[1]) else 1)' "$cb" "$cs"

exit "$fail"
