# Ship tail is model-free (HIMMEL-3608)

## Ruling

The deterministic ship tail — the scripts that drive a PR from CI-green to
merged, with no judgment call left in them — contains no `claude -p` /
`claude --print` / `claude --bg` invocation:

- `scripts/handover/merge-on-green.sh`
- `scripts/handover/console-kit/ready-check.sh`
- `scripts/handover/console-kit/tick.sh`
- `scripts/check-ci.sh`

Verified by grepping all four for the pattern
`(^|[^A-Za-z0-9_-])claude[[:space:]]+(-p|--print|--bg)($|[^A-Za-z0-9_-])`
(the same pattern `scripts/hooks/check-no-headless-claude.sh` uses) against
main at `92ee89588` (2026-09-26): zero matches.

## Scope: hermes-critic.sh is excluded, not missed

`scripts/cr/hermes-critic.sh:343` calls `claude -p --output-format json
--permission-mode plan ...`. This is the nearest headless call to the ship
tail, but it IS the CR review itself — the step where a model judges the
diff. "Model-free" describes the mechanical tail that acts on a review's
verdict (merge, ready-check, CI polling), not the review that produces the
verdict. Out of scope for this ruling by definition: a review needs
judgment.

## Regression guard

`scripts/cr/test-ship-tail-model-free.sh` names the four files above and
asserts none of them contain a headless call, independent of
`scripts/hooks/check-no-headless-claude.sh`'s general billing gate. The two
overlap in mechanism (same detection pattern) but not in purpose: the billing
gate is opt-in-markable (`# headless-claude-ok: <reason>`) and covers every
staged file; this test has no opt-in escape, because the ship tail staying
model-free is a purity invariant, not a billing decision. A future PR that
adds a headless call to any of the four named files fails this test even if
it correctly carries a `headless-claude-ok` marker for the billing gate.
