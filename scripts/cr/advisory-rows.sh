#!/usr/bin/env bash
# advisory-rows.sh — enumerate advisory critic rows for the minerva panel lanes.
#
# Prefer FREE rows (a cost-free cross-model second opinion); if the registry has
# NO free rows, fall back to PAID rows rather than an empty panel (HIMMEL-1221
# G3 — an empty advisory panel silently degrades minerva to claude-only, losing
# the whole point of the cross-model lane; the paid spend is worth it when free
# is unavailable). The Claude critic remains the GATE; this panel stays advisory.
#
# Prints "slug<TAB>model" per selected row (nothing when the registry is empty
# or unreadable — the caller treats an empty enumeration as a no-op panel).
# Arg 1: path to a critics registry JSON (default: the sibling critics.json).
#
# Deliberately reads the UNIVERSAL critics.json, not the operator's local overlay
# — the advisory panel must be adopter-neutral and reproducible, independent of
# one account's exhausted-quota drops or per-account model swaps. That asymmetry
# from the CR panel (which is the operator's own gate and honors their overlay)
# is intentional. Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REG="${1:-$SCRIPT_DIR/critics.json}"

REG="$REG" node -e '
  const fs = require("fs");
  let panel = [];
  try { panel = JSON.parse(fs.readFileSync(process.env.REG, "utf8")).panel || []; }
  catch (e) { panel = []; }
  const rows = panel.filter(r => r && typeof r === "object");
  const free = rows.filter(r => r.tier === "free");
  const chosen = free.length ? free : rows.filter(r => r.tier === "paid");
  const out = chosen.filter(r => r.slug && r.model).map(r => r.slug + "\t" + r.model).join("\n");
  // Trailing newline when non-empty so naive line-readers never drop the last
  // row (matches the per-row newline of the console.log enumeration this replaces).
  process.stdout.write(out ? out + "\n" : "");
'
