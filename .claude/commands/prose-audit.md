---
description: Find mechanical prose in commands and skills that should be a script call, ranked by candidate size.
argument-hint: [--flagged-only] [--json]
---

Command and skill files load into context on EVERY invocation. Mechanical
content — deterministic steps, literal bash you read and then retype into Bash
calls, argument-selection rules, parsing grammars — makes the repo pay agent
tokens each run to do what a script does for free and more testably.

Run the measurement:

```bash
bash scripts/measurements/prose-audit.sh $ARGUMENTS
```

`$ARGUMENTS` stays UNQUOTED — repo convention (see `graph-refresh.md`), so
trailing flags parse as flags.

Then judge **only the flagged files**. `~tok` is candidate size (whole-file
tokens, not removable content) — use it only to prioritize which flagged
files to inspect. Classify each one's content into **(a) mechanical**,
**(b) judgment**, **(c) rationale**, and report a table ranked by the
mechanical content you identify as extractable after classification — that
number means savings, `~tok` doesn't. Name the script that absorbs each
finding. The scan has no invocation-frequency data source — weight by
frequency only when the operator states it, marking it `unknown` otherwise;
never invent the multiplier.

Three rules the script cannot enforce:

1. **This finds prose that should become a script CALL — never prose to
   delete.** Shrinking a file by cutting explanation is a failed audit.
2. **Judgment stays.** Deciding whether a finding is real against a diff is the
   reason a gate exists, not overhead.
3. **Rationale stays.** himmel's convention is that prose explains *why* a rule
   exists so it survives; deleting the why is how rules get re-derived wrong.

**Check `scripts/` for an existing script before proposing a new one.** The
central finding of the first audit was that the extraction usually already
exists — `scripts/cr/pr-check-external.sh` already implements `/pr-check` steps
3.0/3.2/4/5/6 in 357 lines of tested shell. "Call the script that already
exists" beats "write a new script"; a second copy of a gate costs more than the
prose does.

Target shapes to measure against:
- `marketplace/plugins/handover/skills/handover/SKILL.md` — a thin router.
- `.claude/commands/pr-check.md` step 4.8 — one paragraph of why, one script call.

Thresholds are tuned guesses, overridable: `PROSE_AUDIT_MIN_BYTES` (6144),
`PROSE_AUDIT_FENCE_RATIO` (15), `PROSE_AUDIT_MAX_SNIPPETS` (3).

Findings are advisory — a successful scan exits 0. Non-zero means the reporter
itself failed. Program of record: HIMMEL-1941.
