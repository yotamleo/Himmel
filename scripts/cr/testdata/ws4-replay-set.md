# WS4 perspective-diversity replay set (HIMMEL-414 Task 6)

Fixed set of ≥5 merged-PR head SHAs replayed through the critic panel TWICE
(perspectives OFF vs ON) for the D2 paired-arms measurement. Same diffs on both
arms so diff difficulty is a constant across arms (WS2's same-task protocol).
Mixed sizes + domains so the measurement is not skewed by one change shape.

Replay a diff with: `git diff <sha>~1..<sha> | CRITIC_PANEL_TIERS="$WS4_PAIR_TIERS" [CRITIC_PERSPECTIVES=0] critic-panel.sh`

| # | head SHA | size | domain | PR | why chosen |
|---|----------|------|--------|----|-----------|
| 1 | `d46c2131` | small (2 files, ~55 lines) | shell (statusline timeout fix) | #919 | small surgical shell fix — low finding density, control case |
| 2 | `19fd399f` | small (3 files, ~11 lines) | shell + json (CR registry swap) | #897 | tiny config/registry change — CR-domain, near-empty review expected |
| 3 | `11001254` | medium (4 files, ~327 lines) | docs (orchestration ADR + doctrine) | #912 | docs-heavy — tests the panel on prose, not code |
| 4 | `64678252` | medium (7 files, ~410 lines) | node/mjs + json (lane registry) | #910 | mid-size logic change — the typical review target |
| 5 | `551f90e3` | large (25 files, ~2566 lines) | node/py (ci-orch pure core) | #911 | large multi-file change — stresses truncation + high finding density |

Every SHA verified resolvable (`git cat-file -e <sha>`) on 2026-07-06.

## Measurement status

The mechanism (perspective plumbing, Task 5) ships with perspectives **OFF by
default** (charters written + field support built, but NOT wired into the
default critics.json rows). Default = the spec's revert/safe state.

The full paired-arms measurement (both arms × 5 diffs = 10 panel runs, ≥10
manual adjudication passes) is the ADOPT gate: perspectives are wired into the
default rows ONLY if the on-arm's adjudicated-agreed count is ≥20% higher AND
per-critic disproved% worsens ≤5 points (spec D2). Until that measurement runs,
default stays perspectives-off. See the WS4 ticket for the recorded verdict.
