---
name: effort-assess
description: Estimate a ticket as a reference-class record (median, sigma, mean, P80, P30..P70 band), with alternatives and a Definition-of-Done refusal; or check a version's tail (P80/P90). PILOT. /effort-assess
---

# effort-assess — an estimate says how sure it is (HIMMEL-3995)

An estimate here is a **log-normal record**, not a number: the median is the
size you would bet on, sigma says how wrong the real cost tends to be, and the
mean (median x exp(sigma^2/2)) is what versions must add up. Formulas and
calibration: HIMMEL-3992 (variant B). Every number lives in
`effort-model.json` beside this file; the script holds formulas only.

**Status: PILOT-MEASURE** (`docs/tool-adoption/rubric.md`, measure-during
protocol). The estimate is recorded at dispatch, the actual comes from the PR
body's `leg-burn: ... cost-eq=`. Adopt only at n >= 60 shipped-ticket pairs AND
two versions shipped under the model; the KPI is outcome per version (within one
bank, no mid-version replan, P90 not exceeded), not a lower fitted sigma. Until
then treat sigma as a floor: the calibration set was 24 merged tickets and
survivorship biases it low.

## When to use

- Sizing a ticket before a leg is dispatched or a roadmap slot is chosen.
- Checking that a version still fits (`version` mode) before adding a ticket.
- Not for: Jira writes, picking a model tier, or a placer re-run (HIMMEL-3997
  routing reads the record; HIMMEL-4001 moves the placer onto the config).

## Run it

```bash
# resolve the skill dir (CLAUDE_PLUGIN_ROOT is empty in a Codex skill shell)
D="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/skills/effort-assess}"
[ -f "$D/effort_assess.py" ] || D="$(git rev-parse --show-toplevel)/marketplace/plugins/himmel-ops/skills/effort-assess"

python3 "$D/effort_assess.py" ticket --low S --high M --g1 no --deps none \
  --scope-file path/a.sh --red "test-x fails before the change" \
  --goal G2 --alternative "keep the midpoint" --alternative "variant A, no floor"
python3 "$D/effort_assess.py" version --in records.json   # JSON list of ticket records
```

## Inputs (ticket mode)

| Flag | Meaning |
|---|---|
| `--low` / `--high` | size range XS..XL |
| `--plan-first-slice` | XS or S slice size instead of a range (sets the median to that slice) |
| `--g1 yes\|no` | the primary goal is G1 (guard/safety work). Must be stated. On an XS ceiling it is trivial |
| `--deps` | `none`, or the deps and single-writer links |
| `--scope-file` (repeatable) | the files the change touches |
| `--red` | the named failing test or check |
| `--goal`, `--alternative` (repeatable) | carried into the record |

## The record

`median_seq`, `sigma`, `mean_seq`, `p80_seq` (S-eq), `bank` (median, mean, P80),
`band_seq` (P30..P70: show humans this, a one-step range behaves like P30..P70,
not P10..P90), `config_version`, `goal`, `alternatives`, and `dod`.
Version mode prints `mean_bank`, Fenton-Wilkinson `fw_p80_bank` / `fw_p90_bank`,
a seeded Monte Carlo `mc_p80_bank` / `mc_p90_bank`, `agree` (P90 within the
configured tolerance) and `within_caps` (mean <= cap and P90 <= cap).

## The DoD refusal

The script exits 1, prints the record with `dod.failed`, and names the failed
items on stderr. **Do not commit or quote a refused estimate; fix the input.**

| Item | Fails when |
|---|---|
| `scope_files` | no `--scope-file` |
| `red` | no named RED |
| `range_width` | range spans more than one size step: split the ticket or go plan-first |
| `g1_flag` | `--g1` not stated |
| `deps` | `--deps` not stated (`none` counts) |
| `plan_first_slice` | the slice is not XS or S |
| `sigma_ceiling` | sigma >= 1.2: no implementation estimate, plan-first or split instead |

## Alternatives considered (so a reviewer can challenge the choice)

1. Keep the midpoint and widen the margin: a fixed margin cannot see a G1-heavy or wide-range version.
2. Variant A, no floor: fits worse (sigma 0.77 vs 0.65), keeps the tickets-per-bank mismatch.
3. PERT / three-point: needs a mode we do not collect; the tail is thinner than observed.
4. Reference-class bootstrap of observed actual/estimate ratios: the target at n >= 60; same interface.
5. Monte Carlo inside first-fit: too slow. Fenton-Wilkinson for the fast check, Monte Carlo as the cross-check.
6. Story points / velocity: no sprints; the bank is the unit.

Prior art: Bernhardsson 2019 (log-normal blowup), reference-class forecasting
(Kahneman and Tversky; Flyvbjerg), the cone of uncertainty (McConnell),
Fenton-Wilkinson 1960 (sums of log-normals).
