---
description: Print the delegation/critic/bulk lanes actually available on THIS machine (availability-aware).
---

Run `node scripts/lanes/resolve.mjs` from the repo root and present the output verbatim as the set of lanes available for delegation on this machine. Do NOT route work to any lane not listed. The invariant routing policy (delegate down, escalate up, name the model on every dispatch, raise effort before tier) is unchanged and lives in CLAUDE.md.

When the work has an effort-assess record (`himmel-ops:effort-assess`), also run `node scripts/lanes/effort-route.mjs <record.json>` and show its `advisory` line: the recommended `LEG_EFFORT`, whether an independent review is wanted, or plan-first/split when sigma is too wide. It recommends effort only, never a tier; Opus/Fable still need the Tier line (HIMMEL-3997). Thresholds: `scripts/lanes/effort-routing.json`.
