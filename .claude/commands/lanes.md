---
description: Print the delegation/critic/bulk lanes actually available on THIS machine (HIMMEL-689 — availability-aware, derived from scripts/lanes/lanes.json + machine state; the invariant delegation policy stays in CLAUDE.md).
---

Run `node scripts/lanes/resolve.mjs` from the repo root and present the output verbatim as the set of lanes available for delegation on this machine. Do NOT route work to any lane not listed. The invariant routing policy (delegate down, escalate up, name the model on every dispatch, raise effort before tier) is unchanged and lives in CLAUDE.md.
