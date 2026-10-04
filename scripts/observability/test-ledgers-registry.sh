#!/usr/bin/env bash
# Lint for scripts/observability/ledgers.json — the ledger registry (HIMMEL-4290).
#
# Keeps the registry current, structurally rather than by prose:
#   1. ledgers.json parses and every row carries every required field.
#   2. Row ids and default paths are unique.
#   3. Each row's writer and every reader exist in the repo and actually
#      reference the ledger (its default basename or its override env var) —
#      a stale row (renamed writer, dropped reader) fails here.
#   4. Completeness: every ~/.himmel ledger path a tracked non-test script
#      spells out is registered — a NEW ledger cannot land without a row.
#   5. Envelope: a row that is not grandfathered must list the minimum
#      envelope v, ts, host, source, kind.
# Read-only: touches no live ledger.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIR/../.." && pwd)"
REGISTRY="$DIR/ledgers.json"

command -v python3 >/dev/null 2>&1 || { echo "SKIP test-ledgers-registry (python3 not on PATH)"; exit 0; }

if [ ! -f "$REGISTRY" ]; then
  echo "FAIL: registry missing at $REGISTRY"
  echo "FAIL test-ledgers-registry"
  exit 1
fi

REPO="$REPO" REGISTRY="$REGISTRY" python3 - <<'PYEOF'
import json, os, re, subprocess, sys

repo, registry = os.environ["REPO"], os.environ["REGISTRY"]
fails = []

try:
    doc = json.load(open(registry, encoding="utf-8"))
except Exception as e:
    print(f"FAIL: ledgers.json does not parse: {e}")
    print("FAIL test-ledgers-registry")
    sys.exit(1)

REQUIRED = ["id", "default_path", "override_env", "writer", "readers", "format",
            "rotation", "retention", "schema_version", "envelope", "grandfathered"]
MIN_ENVELOPE = {"v", "ts", "host", "source", "kind"}

rows = doc.get("ledgers")
if not isinstance(rows, list) or not rows:
    print("FAIL: ledgers.json has no non-empty 'ledgers' array")
    print("FAIL test-ledgers-registry")
    sys.exit(1)


def mentions(rel, needles):
    p = os.path.join(repo, rel)
    if not os.path.isfile(p):
        return None
    text = open(p, encoding="utf-8", errors="replace").read()
    return any(n and n in text for n in needles)


ids, paths = set(), set()
for i, r in enumerate(rows):
    tag = r.get("id", f"row[{i}]")
    missing = [k for k in REQUIRED if k not in r]
    if missing:
        fails.append(f"{tag}: missing field(s) {missing}")
        continue
    if r["id"] in ids:
        fails.append(f"{tag}: duplicate id")
    ids.add(r["id"])
    if r["default_path"] in paths:
        fails.append(f"{tag}: duplicate default_path {r['default_path']}")
    paths.add(r["default_path"])
    if not isinstance(r["readers"], list) or not isinstance(r["envelope"], list):
        fails.append(f"{tag}: readers and envelope must be arrays")
        continue
    needles = [os.path.basename(r["default_path"]), r["override_env"]]
    # A reader may resolve the path through the writer module's own helper
    # (flow-exporter.ts imports ledgerPath from ../telegram/flow-run-ledger).
    writer_import = "/" + os.path.splitext(os.path.basename(r["writer"]))[0] + '"'
    for role, rel in [("writer", r["writer"])] + [("reader", x) for x in r["readers"]]:
        hit = mentions(rel, needles + ([writer_import] if role == "reader" else []))
        if hit is None:
            fails.append(f"{tag}: {role} {rel} does not exist")
        elif not hit:
            fails.append(f"{tag}: {role} {rel} references neither {needles[0]} nor {needles[1]}")
    if not r["grandfathered"]:
        lacking = MIN_ENVELOPE - set(r["envelope"])
        if lacking:
            fails.append(f"{tag}: new (non-grandfathered) ledger lacks envelope field(s) {sorted(lacking)}")

# Completeness: every ~/.himmel ledger literal in tracked non-test scripts is registered.
registered = {os.path.basename(p) for p in paths}
tracked = subprocess.run(["git", "-C", repo, "ls-files", "scripts"],
                         capture_output=True, text=True).stdout.split("\n")
pat = re.compile(r"\.himmel/(?:state/)?([A-Za-z0-9_-]+\.(?:jsonl|log))")
for rel in tracked:
    base = os.path.basename(rel)
    if not rel or base.startswith("test-") or ".test." in base or "/tests/" in rel:
        continue
    if not re.search(r"\.(sh|ts|mjs|js|py|ps1)$", base):
        continue
    try:
        text = open(os.path.join(repo, rel), encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for m in sorted(set(pat.findall(text))):
        if m not in registered:
            fails.append(f"unregistered ledger {m} (spelled in {rel}) — add a row to ledgers.json")

for f in fails:
    print(f"FAIL: {f}")
if fails:
    print("FAIL test-ledgers-registry")
    sys.exit(1)
print(f"PASS test-ledgers-registry ({len(rows)} ledgers)")
PYEOF
