# claude-hud — vendored fork (himmel)

This directory is a **vendored copy** of a fork of
[`jarrodwatts/claude-hud`](https://github.com/jarrodwatts/claude-hud) (MIT),
used by himmel as the statusline **renderer** (HIMMEL-718). himmel wires it as a
single `node` process — `node <this-dir>/dist/index.js` — replacing the legacy
vendored bash statusline (supersedes HIMMEL-331 + the 2026-05-16 cache patch).

Upstream `LICENSE` is retained verbatim. This is **not** a source of upstream
contributions; it exists so himmel controls the pin and can carry a small delta.

## Pin record (machine-readable — do not hand-edit the hash)

```
fork_repo:            https://github.com/yotamleo/claude-hud   # public fork (HIMMEL-718)
upstream_repo:        https://github.com/jarrodwatts/claude-hud
pinned_commit:        b83b44593af24de1db6183788a51d08715501c02  # v0.3.0
pinned_upstream_tree: 01ab034ddfef4d21233c91c73218b36d4a064fe7  # git tree of pinned_commit (provenance)
vendored_tree_hash:   c28202262c9f8129486300020b5f2a42d8361f31e8c61dda628c7f7c03b50cce  # sha256 over VENDORED.manifest
vendored_at:          2026-07-06
```

`pinned_commit` still points at the upstream base `b83b445`; the vendored tree now
carries himmel's Phase-3.3 fork delta (see **Fork delta** below), so
`vendored_tree_hash` reflects that delta. Pushing the delta to `fork_repo` and
bumping `pinned_commit` to the fork commit is a pending follow-up (the drift guard
gates on `vendored_tree_hash`, not `pinned_commit`, so the vendored tree stays
self-consistent meanwhile). Re-run
`scripts/statusline/check-hud-drift.sh --write` after any further re-vendor.

## Drift guard

`scripts/statusline/check-hud-drift.sh` (pre-commit, himmel-dev-only via
`.himmel-dev` — a no-op in non-contributor checkouts) recomputes a hash over
the **upstream-derived** files in this directory and fails if it diverges
from `vendored_tree_hash` without a pin bump.

**himmel-owned files (excluded from the drift hash — keep in sync with
`OWNED_RE` in both check-hud-drift twins):**
- `VENDORED.md` (this file — edit freely)
- `VENDORED.manifest` (machine-written by `--write`: the per-file hash list
  the aggregate is computed over; excluded because it cannot hash itself —
  never hand-edit)
- `.gitignore` (upstream's file + an appended himmel block re-including
  `dist/`; upstream's own `dist/` ignore would make `git add` silently skip
  the committed runtime we wire)
- `config/**` (himmel's `himmel-config.json`, added in Phase 3)

Everything else here (incl. upstream `README.md`) is **upstream-derived** and
protected: editing it without bumping the pin trips the guard.

> **Deviation from plan (2026-07-06, documented):** the plan listed `README.md`
> as himmel-owned. We instead keep upstream `README.md` faithful (it carries the
> hud config-options docs Phase 3.1 references) and put the himmel fork-delta
> here in `VENDORED.md`. This keeps the vendored tree an exact upstream copy and
> makes the drift guard protect *more* upstream files, not fewer.

## Fork delta

- **Landed (Phase 3.3, HIMMEL-718, `extra-cmd`=B — see the plan §Decisions):** a
  generic `customLineCommand` capability. When `display.customLineCommand` is set
  AND the ACE gate `CLAUDE_HUD_ALLOW_EXTRA_CMD` is enabled, the renderer runs that
  command once per render: it pipes the session stdin JSON to the command's stdin,
  runs it in the session CWD, bounds it by a timeout (3s) + output cap (10KB / 10
  lines), sanitizes each line, and appends the command's **multiline** stdout as
  additional HUD lines. Files: new `src/custom-line-cmd.ts` (+ built `dist/`);
  wiring in `src/config.ts`, `src/index.ts`, `src/types.ts`,
  `src/render/index.ts`; tests in `tests/custom-line-cmd.test.js`. himmel's own
  render logic (the where-are-we composer) stays in himmel `scripts/`, **not** in
  this fork — this fork carries only the generic capability.

- **Landed (HIMMEL-865, 2026-07-10):** carried two upstream open PRs verbatim
  ahead of merge — jarrodwatts/claude-hud#650 (display correctness: effort
  suffix on the model instead of the routed provider; `showDuration`/
  `showConfigCounts` become explicit opt-in `=== true`; unique debug
  namespaces for `config-reader`/`session-line`) and #646 (transcript
  assistant-usage dedup by global `message.id` Set instead of the
  adjacent-tuple heuristic — catches non-consecutive dual-logged usage
  entries). Files: `src/config-reader.ts`, `src/render/lines/environment.ts`,
  `src/render/lines/project.ts`, `src/render/model-display.ts`,
  `src/render/session-line.ts`, `src/transcript.ts`, `tests/core.test.js`
  (+ rebuilt `dist/`). Drop these hunks on the next upstream pin bump if the
  PRs have merged.

- **Landed (HIMMEL-865 CR-round salvage, 2026-07-11):** himmel-authored
  hardening from the win2 offload CR round (salvaged from
  `fix/himmel-865-claude-hud-upstream-adopt` @ `878d5ae`): a clarifying
  comment in `src/transcript.ts` documenting the id-less dedup fallback
  (entries without a `message.id` are not deduplicated — accumulated as-is)
  plus three covering tests — no-id duplicate accumulation
  (`tests/core.test.js`) and `showDuration`/`showConfigCounts`
  unset-means-off opt-in defaults (`tests/render.test.js`) (+ rebuilt
  `dist/`). himmel-authored (not upstream-carried); keep across pin bumps
  until upstream grows equivalent coverage.
