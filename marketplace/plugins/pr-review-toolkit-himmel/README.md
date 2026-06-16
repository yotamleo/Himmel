# pr-review-toolkit-himmel — minimal fork of `pr-review-toolkit`

## Why this fork exists

HIMMEL-178 — Two CR-reviewer hallucinations during HIMMEL-141 work
(a fabricated `>:` typo + a nonexistent variable substitution).
Noise at current review volume; correctness risk at overnight-mode
scale (~6 reviewers/PR × 50-60 dispatches/session). The fix is a
**verify-before-critical sub-rule** added to the reviewer's prompt:
before reporting any Critical finding, the agent must grep the diff
for the cited line/token. If not present verbatim, downgrade or drop.

This rule needs to live IN the reviewer prompt (structural per the
"structural > instructional" Operator convention), not as CLAUDE.md
guidance (which drifts). The upstream pr-review-toolkit is vendored
to `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/pr-review-toolkit/`
— editing it directly is overwritten on plugin update.

This fork is the minimal vendoring to land the rule structurally.

## Scope

**Vendored agents:** `agents/code-reviewer.md` only (with the
verify-rule patch).

**NOT vendored:** `silent-failure-hunter`, `comment-analyzer`,
`pr-test-analyzer`, `type-design-analyzer`, `code-simplifier`,
`commands/review-pr.md`.

Rationale: the two HIMMEL-141 incidents fired in `code-reviewer`'s
domain. The other 5 agents fire less commonly; vendoring all 6 would
compound the fork-watch burden 6× for what is currently a 1-agent
problem. If the other agents start fabricating Criticals too,
escalate per the "structural > instructional" rule (HIMMEL-195) —
extend the fork.

## How to use

When dispatching the code reviewer in himmel CR runs, use:

```
pr-review-toolkit-himmel:code-reviewer
```

instead of `pr-review-toolkit:code-reviewer`. The `/pr-check` slash
command at `.claude/commands/pr-check.md` is the canonical caller —
it dispatches `pr-review-toolkit-himmel:code-reviewer` for the
code-review role and `pr-review-toolkit:*` for the other 5 roles.

Direct callers (manual `Agent` tool calls outside `/pr-check`)
should follow the same pattern.

## Upstream watch protocol

**Drift detection is now automated** (HIMMEL-322): `bash scripts/check-plugin-drift.sh`
fetches upstream `code-reviewer.md` via `gh api` and compares its sha256 to the
`upstream_sha256` recorded in this plugin's `UPSTREAM_PIN`. A mismatch means
upstream changed — follow the re-sync steps below, then update `UPSTREAM_PIN`.
Run it on demand or arm it on a cadence; it covers every himmel fork + SHA-pin.

When drift is flagged (or quarterly, every 90 days, as a backstop):

1. Diff against upstream:
   ```bash
   diff -u "$HOME/.claude/plugins/marketplaces/claude-plugins-official/plugins/pr-review-toolkit/agents/code-reviewer.md" \
           marketplace/plugins/pr-review-toolkit-himmel/agents/code-reviewer.md
   ```
2. If the upstream `code-reviewer.md` has changed:
   - Re-apply the verify-rule patch on top of the new upstream
     content (the patch is a single `## Verify-before-critical
     (HIMMEL-178)` section appended near the end).
   - Run the fixture test (`tests/fixtures/cr-verify-before-critical/README.md`)
     to confirm the rule still fires.
   - Update `Vendored from` date below.
3. If upstream is unchanged, no action.

**Last upstream sync:** 2026-05-28 (initial fork).
**Upstream baseline:** pinned by sha256 in `UPSTREAM_PIN` as of 2026-06-16 (HIMMEL-322) — `scripts/check-plugin-drift.sh` watches it.

## Files

- `.claude-plugin/plugin.json` — plugin manifest (name: `pr-review-toolkit-himmel`).
- `agents/code-reviewer.md` — vendored + patched. Diff vs upstream: one appended `## Verify-before-critical (HIMMEL-178)` section.
- `LICENSE` — Apache-2.0 from upstream (carried forward).
- `README.md` — this file.

## License

Apache-2.0 (carried forward from upstream `pr-review-toolkit`).
See `LICENSE` for the full text. The verify-before-critical patch
in `agents/code-reviewer.md` is added by yotamleo under the same
license.
