# Sprint-1 re-audit of token/agent tools — 2026-09-30 (HIMMEL-3883)

> Evidence for three registry rows ([`registry.md`](registry.md)). Method:
> [`rubric.md`](rubric.md). Everything was run on scratch clones outside the
> repo and the live `~/.claude`; nothing was installed or enabled.
> Models for every measurement: `claude-sonnet-5-5` via Claude Code 2.1.286.
> Scanner: Hermes `skills_guard` at pin `ec5f441` (`scan_skill`, source
> `community`).

## Candidate selection

The ticket folds four candidates into sprint 1 but budgets two. Picked
**agent-skills** and **Understand-Anything**: each overlaps something himmel
already runs (the lean-skills/superpowers-derived skills; graphify), so a verdict
can be reasoned from a concrete comparison. **archify** (diagram generator) and
**awesome-claude-skills** (a curated list, not a tool) roll to the sprint-2
re-audit item; neither names a himmel problem today.

| Tool | Upstream (2026-09-30) | Licence |
|------|-----------------------|---------|
| caveman | pushed today, 108k stars, 80 open issues | Apache-2.0 |
| agent-skills | pushed 2026-09-26, 100k stars, 58 open issues | MIT |
| Understand-Anything | pushed 2026-09-28, 85k stars, 114 open issues | MIT |

## caveman — KEEP-REMOVED

Re-check of the four questions in the ticket:

1. **Upstream alive?** Yes — the "dead upstream" premise of HIMMEL-2033 no
   longer holds. It now also ships a proxy, MCP and 20 skills.
2. **`skills_guard` trip?** Still trips at `ec5f441`. `caveman-compress` is
   `dangerous` (critical `agent_config_mod`: it writes compressed output over
   `CLAUDE.md`; high `ssh_backdoor` match on an `authorized_keys` string in
   `scripts/compress.py`); `caveman-setup` and `caveman-learn` are `caution`.
   The other 17 skills scan `safe`. The removal reason is unchanged for the
   family as a whole.
3. **Saves tokens?** Marginally, and not reliably. One run per cell, three fixed
   prompts (explanation, diff review in a gate-parsed format, a READY message
   carrying an exact evidence line), `SKILL.md` appended as system prompt:

   | Prompt | Output tokens base → caveman | Cost base → caveman |
   |--------|------------------------------|---------------------|
   | explanation | 1268 → 956 (-25%) | $0.2404 → $0.2477 (+3%) |
   | diff review | 416 → 578 (+39%) | $0.0275 → $0.0297 (+8%) |
   | READY message | 428 → 359 (-16%) | $0.0271 → $0.0269 (-1%) |
   | total | 2112 → 1893 (-10%) | |

   The skill text adds about 2.6k input tokens per call, which cancels the
   output saving in dollars. n=1 per cell, so this shows "no clear win", not a
   measured effect size.
4. **Quality harm?** Format survived, coverage slipped. The gate-shaped lines
   (`FINDING:` format, `READY <pr> <sha> GREEN`) were intact in both modes. On
   the diff review, base returned 7 findings (4 Critical) and caveman 5 (3
   Critical): both found the same core bugs, but caveman dropped the
   `get`-returns-`Entry` Important and a log-level Suggestion and rated the
   `KeyError` Important instead of Critical. One sample each, so this is a
   signal to re-measure, not proof of harm.

Verdict: KEEP-REMOVED. The scan failure is unchanged, the saving is -10% output
at best and net-zero in cost, and ponytail already fills the terse-mode slot
(HIMMEL-2033). Re-open trigger: upstream splits `caveman-compress` out of the
family and the remainder scans `safe` AND a real-workday measure-during shows an
outcome gain, not a token gain (rubric §1).

## agent-skills (addyosmani) — REJECT (no himmel problem)

- **Problem named?** None. Its 25 skills (TDD, debugging, code review, planning,
  git workflow, security) cover the ground the lean-skills and
  superpowers-derived skills already cover, and `test-audit` covers test
  quality. No session pain that they would remove exists to cite (rubric §1).
- **Trust.** Scan: 2 `dangerous` (`browser-testing-with-devtools`,
  `source-driven-development`), both critical `prompt_injection_ignore` hits on
  lines that tell the model *not* to follow injected instructions, i.e. the
  scanner matching defensive prose — false positives, read at the cited lines.
  Also ships hooks (`sdd-cache-*`, `simplify-ignore`) that would sit on the
  PreToolUse path: `source-read-mandatory` if ever revisited. `session-start.sh`
  is documented as not wired by the plugin.
- Licence MIT, upstream active.
- Not measured: there is no claim about tokens or quality to check and no
  problem to baseline against.

Re-open trigger: a recurring session failure that one of its skills addresses
and lean-skills does not.

## Understand-Anything — REJECT (overlaps graphify)

- **Problem named?** None. "Explain codebase structure" is already served by
  graphify (`graphify query` / `explain`), whose graph is built and refreshed
  (`graphify-out/cost.json` records a 502-file, 3.49M-token semantic pass).
  Understand-Anything builds its own `knowledge-graph.json` with LLM file
  analyzers, i.e. a second graph of the same repo at comparable token cost, plus
  a dashboard no himmel workflow consumes.
- **Trust.** Scan: 1 `dangerous` (`understand-knowledge`, critical
  `destructive_root_rm`) — a false positive on a cleanup step whose prose is
  the guard against expanding to `rm -rf /intermediate`; the other 8 skills
  scan `safe` (medium only). `SECURITY.md` states local-only operation.
  Licence MIT, upstream active.
- Not measured, for the same reason as above.

Re-open trigger: graphify is retired or fails a structure question that this
tool's dashboard would answer.

## Carry-forward

Sprint-2 item carries **archify** and **awesome-claude-skills** (evaluate the
skills in the list that fit a named gap, not the list), plus any verdict above
whose model changed since `claude-sonnet-5-5`.
