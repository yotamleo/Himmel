# orchestration-patterns — D3 run log

Companion to `docs/orchestration-patterns.md`. Records the SC4 proof-run of the
`adversarial-verify` saved workflow (`.claude/workflows/adversarial-verify.js`).

## 2026-07-05 — SC4 proof-run (GA Workflow mechanism)

- **Diff ref:** WS3 worktree branch `docs/himmel-654-ws3-orchestration` vs main.
- **Mechanism:** launched via the GA Workflow tool (`scriptPath` → the committed
  saved-workflow file); ran the `Review` → `Verify` pipeline end-to-end.
- **Agents:** 6 total (2 review dimensions: correctness + silent-failure; verify
  fan-out over findings), 0 errors, 0 skipped.
- **Tokens:** ~407,814 subagent tokens. **Wall-clock:** ~584 s (~9.7 min).
- **Verdicts:** 1 finding confirmed (verify agent could not refute):
  `.claude/workflows/adversarial-verify.js:23` — `review?.findings ?? []`
  coalesces a crashed/malformed reviewer into an empty findings array, so a
  reviewer failure is indistinguishable from a clean review (a silent-failure).
  **Accepted as a known limitation of this thin proof artifact** (the script is
  the critic-hardened plan's verbatim demo, not production CR infra; the `?.`
  degrade-to-empty is deliberate demo robustness). Not rewritten — recorded here
  transparently, per the doctrine's own no-silent-failure invariant (§5).

- **⚠ Availability caveat (operator-relevant):** launching the Workflow tool
  triggered an interactive **dynamic-workflow approval prompt**. In an
  unattended autonomous/overnight session this **HANGS** until an operator
  approves (observed this run). Until a `Workflow` allow-rule lands in
  `.claude/settings.json`, the run-leg of SC4 must be treated as
  operator-attended only — the file-leg (committing the workflow) stays
  unconditional. See memory `feedback_workflow_tool_hangs_autonomous_approval`.
