## Results

| run_id | task | cell | rep | verdict | out_of_scope | tokens_in | tokens_out | cost_usd | duration_ms | effort |
|---|---|---|---|---|---|---|---|---|---|---|
| T1-haiku-1 | T1 | haiku | 1 | fail | 0 | - | - | - | 50 | low |
| T1-haiku-2 | T1 | haiku | 2 | fail | 0 | - | - | - | 55 | low |
| T1-luna-1 | T1 | luna | 1 | pass | 0 | - | - | - | 100 | high |
| T1-luna-2 | T1 | luna | 2 | pass | 0 | - | - | - | 110 | high |
| T10-haiku-1 | T10 | haiku | 1 | pass | 0 | - | - | - | 40 | low |
| T10-haiku-2 | T10 | haiku | 2 | error-harness-final | 0 | - | - | - | - | low |
| T10-luna-1 | T10 | luna | 1 | fail | 0 | - | - | - | 300 | high |
| T10-luna-2 | T10 | luna | 2 | fail | 0 | - | - | - | 310 | high |
| T7-haiku-1 | T7 | haiku | 1 | pass | 0 | 120 | 340 | 0.0018 | 60 | low |
| T7-haiku-2 | T7 | haiku | 2 | pass | 0 | - | - | - | 65 | low |
| T7-luna-1 | T7 | luna | 1 | pass | 0 | 24500 | 950 | 0.0060 | 200 | high |
| T7-luna-2 | T7 | luna | 2 | fail | 0 | - | - | - | 210 | high |

## Summary (split by profile, T1 separate)

### haiku

- code (excl. T1): 100% (2/2)
- haiku-native: 100% (1/1)
- T1 (fixture-scale sweep, own row): 0% (0/2)
- nondeterminism (tasks where reps disagreed): 0
- harness-error count: 1

### luna

- code (excl. T1): 50% (1/2)
- haiku-native: 0% (0/2)
- T1 (fixture-scale sweep, own row): 100% (2/2)
- nondeterminism (tasks where reps disagreed): 1
- harness-error count: 0

## Threats to validity

Reproduced from spec §2.4 (residual confound table), §3.3.1 (axis
comparability), and §4.4 (fixture-scale claim limit) — HIMMEL-1723.

| | Haiku cell | luna cell |
|---|---|---|
| Dispatch | Agent tool, in-session subagent | scripts/claude-codex child process |
| Harness | parent session's | full Claude Code session (own system prompt, hooks, skills) |
| Startup | ~none | proxy preflight + hook/skill load |
| Bank | Claude 5h/weekly | codex weekly |

Not comparable across cells: input/output/cache token counts (different
tokenizers + different harness overhead), wall-clock (startup asymmetry).
The dollar figure is a caveated sanity axis only, never the verdict.

Fixture-scale claim limit (spec §4.4): results at fixture scale do not
license any claim about 500+-site sweeps. T1 (~200 sites) is reported in its
own row above; the rest of the `code` tasks are ~10-file scale.
