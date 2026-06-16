# scripts/handover — handover shell tooling

Loads only when working in this subtree. Holds dev conventions for the
handover scripts; the full system design lives in the reference doc below.

## Hard rule (drift-prone)
Scripts MUST source `scripts/lib/handover-path.sh` and call `handover_root`
to resolve the handover directory. **Never hardcode `./handovers/`** — the
single-root resolver + `HANDOVER_DIR` bridge depend on it.

## Conventions
- Personal handover state is centralized in your handover state repo
  (configured via `/handover-setup` / `$HANDOVER_DIR`); himmel
  `handovers/` is a stub. Don't write durable state into himmel.
- The live source of truth is the v2 handover skill +
  `~/.claude/handover/registry.json` — change it via `/handover`, never by
  editing docs or the registry by hand.
- Branch naming: `handover/<TICKET>-<slug>` (auto-commit + PR-open + flush).
- Most scripts have a paired `test-*.sh` — run it after edits; add one
  when you write a new script.

## Reference
- Full system + user-slug resolution:
  [`docs/internals/handover-system.md`](../../docs/internals/handover-system.md).
