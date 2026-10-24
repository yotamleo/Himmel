# Renamed identifiers (HIMMEL-5689): old names, new names, where they are used

**This page is temporary.** It exists for the HIMMEL-5689 rename and is deleted with the removal step
(HIMMEL-6647) once `git grep` finds none of the old names below outside this page, the changelog and
the handover records (`handovers/`, which keep the history and are never rewritten).

**This migration is a known breaking change** (operator ruling 2026-10-24). From here on a rename PR
leaves no read-both alias, no wrapper at the old path and no alias-pin test. A script, an `.env` file,
a shell alias or a habit that uses an old name below must move to the new name when the rename PR for
its family lands. The release changelog (HIMMEL-7006) names the breaking change. The plan's rules
and the family map live in [the glossary](../glossary.md#identifier-renames).

**Four slices merged before the ruling, with aliases.** V3 (HIMMEL-6638), V1 (HIMMEL-6639), V2
(HIMMEL-6640) and V5 (HIMMEL-6641) are Done, and V4a-1 (#3608, HIMMEL-6642 still open) is merged.
They renamed their names but kept the old ones working: a forwarder or redirect at each old path,
a `/console` and `/overnight-shift` command alias, and read-both env names through
`scripts/lib/env-alias.sh`. Column At head says how far each family got. HIMMEL-6647 owns the
leftovers of every Done family (and of V4a-1 once HIMMEL-6642 lands): delete the forwarders and
aliases, move every old-name caller, and rename the names those slices missed.

Measured at `c47a157eedd196e75fc6331c1dd4d5a8cb21a9fe` over tracked files with `git grep -n -I -o -P`, excluding `docs/glossary.md`,
`docs/migration/`, `handovers/` and `CHANGELOG.md`. Line numbers move as other PRs merge, so every
rename PR re-runs the pattern of its names (column Pattern) before it starts and treats this page as a
map, not a diff. Lower-case script-local names (`bank_pct`, `leg_doc`) are not inventoried:
the rename PR that touches a file renames its local names with it.

**Row grain.** One row per old name and file; the Lines column lists every matching line of that file
(`file:line` for each hit is the file plus one number). Class: `code`, `test`, `fixture` (frozen
recorded data: the glossary's do-not-rename list keeps `*/fixtures/**`, so a rename PR leaves these
alone unless a test needs the new name), `docs`, `config`.

**At head.** For each distinct old string the new name is looked up (the registry
`scripts/lib/rename-aliases.tsv` first, then the family's rule). "New name live k/n" counts the old
strings whose new name already appears as a whole name in a tracked file name or in code, tests or
config (not markdown), outside the registry, its pin test and fixtures.
A name the registry marks pending-N2892 has no ruled new name yet.

**Owner.** The ticket that owns the family; for a Done slice, HIMMEL-6647 (console ruling 2026-10-24). <!-- old-term-ok: this page inventories the old names -->

## Old names

| # | Family | Slice | Old name | New name | Kind | Owner | At head | Hits (lines / files) | Pattern (`git grep -n -I -P`) | Note |
|---|---|---|---|---|---|---|---|---|---|---|
| N01 | F1c | V5 | `CONSOLE_* (operator-typed and script-local)` | `CHIEF_*` | env var | HIMMEL-6647 (V5 HIMMEL-6641 Done) | new name live 59/60 | 314 / 49 | `(?<![A-Za-z0-9_])CONSOLE_(?!(?:KIT_FIXTURE\|ROLE\|VERB)(?![A-Z0-9_]))[A-Z0-9_]+` | HIMMEL_CONSOLE_* (OD-1) and the registry keeps CONSOLE_KIT_FIXTURE, CONSOLE_ROLE, CONSOLE_VERB are excluded; CONSOLE_WAIT_BANK goes to CHIEF_WAIT_USAGE and CONSOLE_WAIT_LEG_EVENT to CHIEF_WAIT_WORKER_EVENT |
| N02 | F2 | V4a | `HIMMEL_LEG_*` | `HIMMEL_WORKER_SESSION_*` | env var | HIMMEL-6642 / HIMMEL-7139 | new name live 8/9 | 136 / 33 | `HIMMEL_LEG_[A-Z0-9_]+` | never HIMMEL_WORKER_* (live security marker) |
| N03 | F2 | V4a | `HIMMEL_LEAN_LEG` | `HIMMEL_LEAN_WORKER_SESSION` | env var | HIMMEL-6642 / HIMMEL-7139 | new name live 1/1 | 55 / 16 | `HIMMEL_LEAN_LEG` |  |
| N04 | F2 | V4a | `LEG_*` | `WORKER_SESSION_*` | env var | HIMMEL-6642 / HIMMEL-7139 | new name live 85/94 | 497 / 60 | `(?<![A-Za-z0-9_])LEG_[A-Z0-9_]+` | LEG_SESSION_ID goes to WORKER_SESSION_ID; LEG_DIGEST_CHAIN_SLACK_MIN: the registry says WORKER_SESSION_DIGEST_CHAIN_SLACK_MIN, plan row 67 says WORKER_DIGEST_SLACK_MIN (the rename PR settles it) |
| N05 | F2 | V4a | `HEADED_ARM_LEG_*` | `HEADED_ARM_WORKER_*` | env var | HIMMEL-6642 / HIMMEL-7139 | new name live 15/17 | 68 / 9 | `HEADED_ARM_LEG[A-Z0-9_]*` |  |
| N06 | F2 | V4a | `profile ids leg-impl, leg-bus, leg-vm` | `worker-impl, worker-bus, worker-vm` | flag value | HIMMEL-6642 | new name live 3/3 | 391 / 60 | `(?<![A-Za-z0-9-])leg-(impl\|bus\|vm)(?![A-Za-z0-9-])` |  |
| N07 | F3 | V1 | `CADENCE_BANK_*` | `CADENCE_USAGE_*` | env var | HIMMEL-6647 (V1 HIMMEL-6639 Done) | new name live 13/13; 1 without a ruled name | 334 / 69 | `(?<![A-Za-z0-9_])CADENCE_BANK[A-Z0-9_]*` | the bare CADENCE_BANK has no ruled name (registry: pending-N2892); the registry's new name for CADENCE_BANK_LEG, CADENCE_USAGE_LEG, still holds LEG | <!-- old-term-ok: this page inventories the old names -->
| N08 | F3 | V1 | `BANK_LIFT_*` | `USAGE_LIFT_*` | env var | HIMMEL-6647 (V1 HIMMEL-6639 Done) | new name live 6/6 | 39 / 10 | `(?<![A-Za-z0-9_])BANK_LIFT_[A-Z0-9_]*` |  |
| N09 | F3 | V1 | `CODEX_BANK_*` | `CODEX_USAGE_*` | env var | HIMMEL-6647 (V1 HIMMEL-6639 Done) | new name live 7/7; 3 without a ruled name | 114 / 18 | `(?<![A-Za-z0-9_])CODEX_BANK_[A-Z0-9_]*` |  |
| N10 | F3 | V1 | `CLAUDEX_BANK_*` | `CLAUDEX_USAGE_*` | env var | HIMMEL-6647 (V1 HIMMEL-6639 Done) | new name live 3/4 | 36 / 8 | `(?<![A-Za-z0-9_])CLAUDEX_BANK_[A-Z0-9_]*` |  |
| N11 | F3 | V1 | `PARKED-BANK` | `PARKED-USAGE` | id (marker token) | HIMMEL-6647 (V1 HIMMEL-6639 Done) | new name live 1/1 | 61 / 29 | `PARKED-BANK` | marker token the tick parses; written handover docs also carry it |
| N12 | F4 | V1 | `bank-preflight.sh, bank-lift.sh (+ bank-lift.json), bank-monitor.sh, bank-attribution.sh, bank-status*, codex-bank-probe.ts` | `usage-preflight.sh, usage-lift.sh (+ usage-lift.json), usage-monitor.sh, usage-attribution.sh, usage-status*, codex-usage-probe.ts` | script/file name, command | HIMMEL-6647 (V1 HIMMEL-6639 Done) | new name live 12/37; 32 without a ruled name | 794 / 230 | `(?<![A-Za-z0-9-])[a-z-]*bank-(?:preflight\|lift\|monitor\|attribution\|status\|probe)(?:[A-Za-z0-9-]\|\.(?=[A-Za-z0-9]))*` | a longer name that only contains one of these (`test-bank-preflight.sh`, `block-bank-lift-writes.sh`) has no ruled name unless its usage- twin exists |
| N13 | F5 | V2 | `clear-cr-marker.sh and cr-*.sh` | `clear-review-marker.sh, review-*.sh, coderabbit-*.sh (per the registry)` | script/file name | HIMMEL-6647 (V2 HIMMEL-6640 Done) | new name live 9/9; 14 without a ruled name | 474 / 128 | `(?<![A-Za-z0-9-])(clear-)?cr-[a-z0-9-]+\.sh` | the registry names nine; every other cr-*.sh has no ruled name (see unruled file names). `scripts/cr/cr-trigger-ledger.sh` is the CI-release ledger, not the CodeRabbit one, so the registry's `cr-trigger-ledger.sh` row (the `scripts/lib/` alias) does not apply to it. AMBIGUOUS: the pattern can catch a third-party cr-*.sh; read each hit |
| N14 | F5 | V2 | `CR_MARKER*, CLEAR_CR_MARKER_*, SETUP_CR_MARKER` | `REVIEW_MARKER*, CLEAR_REVIEW_MARKER_*, SETUP_REVIEW_MARKER` | env var | HIMMEL-6647 (V2 HIMMEL-6640 Done) | new name live 3/4 | 17 / 7 | `(?<![A-Za-z0-9_])[A-Z_]*CR_MARKER[A-Z0-9_]*` | SETUP_CR_MARKER is a test-local name; the <git-dir>/cr-pending/ dir keeps its name (OD-3) |
| N15 | F6 | V4b | `headed-arm-leg.sh` | `headed-arm-worker.sh` | script/file name | HIMMEL-6643 | new name live 1/2; 2 without a ruled name | 360 / 140 | `(?<![A-Za-z0-9-])[a-z-]*headed-arm-leg[a-z-]*\.sh` |  |
| N16 | F7 | V4b | `leg-identity, leg-doc-lock, leg-event, leg-jira-status, leg-pretrust, leg-transcripts, leg-graph (.sh)` | `worker-identity, worker-doc-lock, worker-event, worker-jira-status, worker-pretrust, worker-transcripts, worker-graph` | script/file name | HIMMEL-6643 | new name live 0/7; 7 without a ruled name | 268 / 107 | `(?<![A-Za-z0-9-])[a-z-]*leg-(?:identity\|doc-lock\|event\|jira-status\|pretrust\|transcripts\|graph)[a-z-]*\.sh` | only the seven helpers plan row 28-36 names; every other leg-*.sh is N42 |
| N17 | F7 | V4b | `leg-digest*` | `worker-digest*` | script/file name, directory | HIMMEL-6643 (dir: HIMMEL-6646) | new name live 0/3 | 130 / 55 | `leg-digest[a-z-]*` |  |
| N18 | F7 | V4b | `close-wrapped-leg.sh` | `close-wrapped-worker.sh` | script/file name | HIMMEL-6643 | new name live 0/1; 1 without a ruled name | 113 / 60 | `(?<![A-Za-z0-9-])[a-z-]*close-wrapped-leg[a-z-]*\.sh` | the CLOSE_WRAPPED_LEG_* env names are in N38 |
| N19 | F8 | M | `console-kit (directory)` | `chief-kit` | directory | HIMMEL-6646 | new name live 0/1 | 1462 / 388 | `console-kit` | largest blast radius; rename last. The plan's symlink at the old path is dropped by the no-alias ruling |
| N20 | F8 | T | `leg-preface*.md` | `worker-preface*.md` | file name | HIMMEL-6644 | new name live 0/5 | 180 / 48 | `leg-preface[a-z-]*(?:\.md)?` |  |
| N21 | F8 | T | `console-template.md` | `chief-template.md` | file name | HIMMEL-6644 | new name live 0/1 | 79 / 39 | `(?<![a-z-])console-template\.md` | console-handoff-template.md has no ruled name (unruled file names) |
| N22 | F8 | T | `leg-brief-template.md` | `worker-brief-template.md` | file name | HIMMEL-6644 | new name live 0/1 | 28 / 23 | `leg-brief-template\.md` |  |
| N23 | F9 | V5 | `/console` | `/chief` | command | HIMMEL-6647 (V5 HIMMEL-6641 Done) | new name live 1/1 | 132 / 34 | `(?<![A-Za-z0-9_/.-])/console(?![A-Za-z0-9_/-])` | /supervisor-session stays a permanent alias of /chief (OD-6) |
| N24 | F9 | V5 | `console.sh` | `chief.sh` | script/file name | HIMMEL-6647 (V5 HIMMEL-6641 Done) | new name live 1/1 | 152 / 63 | `(?<![A-Za-z0-9_-])console\.sh` |  |
| N25 | F9 | V5 | `console-context.sh` | `chief-context.sh` | script/file name | HIMMEL-6647 (V5 HIMMEL-6641 Done) | new name live 1/1 | 8 / 3 | `console-context\.sh` |  |
| N26 | F9 | V5 | `skill himmel-ops:console` | `himmel-ops:chief` | skill id | HIMMEL-6647 (V5 HIMMEL-6641 Done) | new name live 0/1 | 1 / 1 | `himmel-ops:console(?![A-Za-z0-9_-])` | himmel-ops:supervisor-session stays, like /supervisor-session (OD-6) |
| N27 | F9 | V5 | `agents console-judge, console-judge-ro` | `judge, judge-ro` | id (agent) | HIMMEL-6647 (V5 HIMMEL-6641 Done) | new name live 2/2 | 81 / 36 | `console-judge(-ro)?` | never chief-judge* | <!-- old-term-ok: this page inventories the old names -->
| N28 | F10 | V3 | `overnight-shift` | `afk-shift` | command, directory | HIMMEL-6647 (V3 HIMMEL-6638 Done) | new name live 1/1 | 9 / 7 | `overnight-shift` |  |
| N29 | F10 | V3 | `overnight-mode.md` | `afk-mode.md` | file name | HIMMEL-6647 (V3 HIMMEL-6638 Done) | new name live 1/1 | 5 / 4 | `overnight-mode\.md` |  |
| N30 | F10 | V3 | `OVERNIGHT_*, OVERNIGHT, HIMMEL_OVERNIGHT, HIMMEL_INITIATIVE_OVERNIGHT, IL_OVERNIGHT_ALL` | `AFK_*, AFK, HIMMEL_AFK, HIMMEL_INITIATIVE_AFK, IL_AFK_ALL` | env var | HIMMEL-6647 (V3 HIMMEL-6638 Done) | new name live 11/13 | 106 / 31 | `(?<![A-Za-z0-9_])[A-Z0-9_]*OVERNIGHT[A-Z0-9_]*` |  |
| N31 | F11 | - | `watchdog (auto-arm hooks only)` | `auto-relaunch in prose; ids deferred` | word in ids and prose | none (deferred) | deferred | 287 / 75 | `watchdog` | AMBIGUOUS and DEFERRED: the glossary scopes the rename to the auto-arm hooks and names no new id; a wall-clock killer is a run timeout. Per-hit read before any rename |
| N32 | F13 | V2 | `class-sweep, missing-class-sweep` | `variant-sweep, missing-variant-sweep` | id (exit reason), message text | HIMMEL-6647 (V2 HIMMEL-6640 Done) | new name live 2/2 | 35 / 12 | `(missing-)?class-sweep` | the SWEEP ledger keyword is unchanged |
| N33 | F14 | D | `speed bump` | `soft block` | message text | HIMMEL-6645 | new name live 1/1 | 12 / 9 | `speed bump` | text only; tests may grep it |
| N34 | F16 | T | `tick fields legs=, legset=, bank=` | `workers=, workerset=, usage=` | id (tick field) | HIMMEL-6644 | new name live 2/3 | 203 / 42 | `(?<![A-Za-z_])(legs\|legset\|bank)=` | AMBIGUOUS: also matches shell variables named bank or legs; tails= and parked= keep their names | <!-- old-term-ok: this page inventories the old names -->
| N35 | F17 | V4a | `hooks block-leg-askuserquestion.sh, guard-leg-wakeup.sh` | `block-worker-askuserquestion.sh, guard-worker-wakeup.sh` | script/file name (hook) | HIMMEL-7139 (settings switch), then HIMMEL-6647 (forwarders) | new name live 4/4 | 29 / 18 | `(?<![A-Za-z0-9-])[a-z-]*(block-leg-askuserquestion\|guard-leg-wakeup)\.sh` | registered in .claude/settings.json: operator edit |
| N36 | F17 | V5 | `hooks console-compact-reinject.sh, guard-console-foreground.sh` | `chief-compact-reinject.sh, guard-chief-foreground.sh` | script/file name (hook) | HIMMEL-6647 (V5 HIMMEL-6641 Done) | new name live 0/2; 2 without a ruled name | 39 / 23 | `(?<![A-Za-z0-9-])[a-z-]*(console-compact-reinject\|guard-console-foreground)\.sh` | registered in .claude/settings.json: operator edit |
| N37 | F3 | V1 | `other upper-case names holding BANK (script-local and test names)` | `BANK to USAGE in place (plan row 66); exact rows per the registry` | env var, script-local name | HIMMEL-6647 (V1 HIMMEL-6639 Done) | new name live 8/10; 36 without a ruled name | 494 / 94 | `(?<![A-Za-z_-])(?!(?:CADENCE\|CODEX\|CLAUDEX)_BANK\|BANK_LIFT_)(?:[A-Z_][A-Z0-9_]*)?BANK[A-Z0-9_]*` | registry rows with a concrete new name (HIMMEL_STOP_GUARD_BANK_PREFLIGHT, BANK_STATE_FILE, BANK_CACHE_FILE, BANK_SAMPLES_FILE, IMPL_GUARD_BANK_*, BOARD_BANK_LIFT) take it; the rest read pending-N2892 and take BANK to USAGE in place | <!-- old-term-ok: this page inventories the old names -->
| N38 | F2 | V4a | `upper-case names with LEG inside (CLOSE_WRAPPED_LEG_*, RUN_LEG_*, ARM_SPLIT_LEG_*, M_LEG_*, ...)` | `pending-N2892: no ruled name` | env var, script-local name | HIMMEL-7139 | new name live 1/1; 35 without a ruled name | 169 / 27 | `(?<![A-Za-z0-9_-])(?!HIMMEL_LEG_\|HIMMEL_LEAN_LEG\|HEADED_ARM_LEG\|HIMMEL_CONSOLE\|CADENCE_USAGE_LEG\|(?:CADENCE\|CODEX\|CLAUDEX)_BANK_)(?:[A-Z_][A-Z0-9_]*)?[A-Z0-9]_LEG(?:_[A-Z0-9_]*)?(?![A-Za-z0-9_])` | plan row 66 renames script-local names in place in the owning slice; the registry has no new name yet |
| N39 | F1c | V5 | `upper-case names with CONSOLE inside (BREAK_GLASS_CONSOLE_CMD, ...)` | `pending-N2892: no ruled name` | env var, script-local name | HIMMEL-6647 (V5 HIMMEL-6641 Done) | no ruled name for 11 | 48 / 18 | `(?<![A-Za-z0-9_-])(?!HIMMEL_CONSOLE)(?:[A-Z_][A-Z0-9_]*)?[A-Z0-9]_CONSOLE(?:_[A-Z0-9_]*)?(?![A-Za-z0-9_])` | HIMMEL_CONSOLE and HIMMEL_CONSOLE_* are kept (OD-1) |
| N40 | F8 | M | `directories docs/handover/console-sections/, docs/handover/leg-sections/` | `chief-sections/, worker-sections/` | directory | HIMMEL-6646 | new name live 0/2 | 93 / 40 | `(console\|leg)-sections` | plan row 60 |
| N41 | F10 | M | `directories scripts/console/, scripts/handover/console/, scripts/overnight/` | `scripts/chief/, scripts/handover/chief/, scripts/afk/` | directory | HIMMEL-6646 | new name live 0/3 | 151 / 62 | `scripts/(?:handover/)?console/\|scripts/overnight/` | plan row 61; scripts/eval/leg-digest/ is in N17 |
| N42 | F7 | - | `other leg-*.sh scripts (leg-burn, leg-pr-open, leg-resume-brief, leg-timeline, ...)` | `needs a ruling` | script/file name | none (not in the approved table) | no ruled name for 34 | 400 / 140 | `(?<![A-Za-z0-9-])[a-z-]*leg-(?!identity\|doc-lock\|event\|jira-status\|pretrust\|transcripts\|graph\|digest\|preface\|brief\|sections)[a-z0-9-]+\.sh` | not in the approved rename table; a rename needs a ruling. The `leg-burn:` PR-body line is kept (plan do-not-rename list) |
| N43 | F9 | - | `other console-* scripts (console-wait.sh, console-budget.sh, guard-console-dispatch.sh, ...)` | `needs a ruling` | script/file name | none (not in the approved table) | no ruled name for 47 | 495 / 137 | `(?<![A-Za-z0-9-])[a-z-]*console-(?!context\.sh\|compact-reinject\|foreground\|kit\|template\|sections\|judge)[a-z0-9-]+\.(?:sh\|ts\|py\|mjs\|md)` | not in the approved rename table; a rename needs a ruling |

Total: 43 old-name entries, 8899 matching lines (a line that matches two entries counts in each).
N01 to N36 keep the numbers of the first draft; N37 to N43 were missing from it.

## Rename families and the order of the rename PRs

One PR per row. A rename PR changes the writer, every reader and every test of its names in the same
PR, so no name is ever read under one spelling and written under the other. Each PR re-runs its
patterns, renames the code, the tests and the docs that name it, and ends with `git grep` of its old
names returning only this page, the changelog and the handover records. Names that live in
`.claude/settings.json` (hook registrations, allow rules) need an operator edit and go in the PR body
as a paste.

| Order | PR | Names | Owner | Files to rename or edit (top paths by hit count) |
|---|---|---|---|---|
| 1a | afk leftovers: drop the overnight aliases | N28, N29, N30 | HIMMEL-6647 | `scripts/lib/test-rename-aliases.sh` (16); `scripts/lib/rename-aliases.tsv` (14); `scripts/hooks/test-inject-initiative.sh` (8); `docs/configuration.md` (6); `marketplace/plugins/himmel-ops/scripts/test-autonomy-mode.sh` (6); `scripts/hooks/test-jira-nudge-on-end.sh` (5) |
| 1b | usage leftovers: drop the bank forwarders and read-both names | N07, N08, N09, N10, N11, N12, N37 | HIMMEL-6647 | `scripts/lib/test-bank-preflight.sh` (147); `scripts/lib/rename-aliases.tsv` (87); `scripts/hooks/test-block-bank-lift-writes.sh` (83); `scripts/lib/test-bank-monitor.sh` (75); `scripts/lib/usage-preflight.sh` (72); `scripts/lanes/tests/bank-status.test.mjs` (64) | <!-- old-term-ok: this page inventories the old names -->
| 1c | review leftovers: drop the cr forwarders and read-both names | N13, N14, N32 | HIMMEL-6647 | `scripts/hooks/test-guard-pr-check-literal.sh` (83); `scripts/lib/test-rename-aliases.sh` (22); `scripts/cr/cr-round-metrics.sh` (20); `scripts/lanes/tests/settings-allow.test.mjs` (17); `scripts/cr/test-clear-cr-marker.sh` (16); `scripts/hooks/test-block-tail-pipe-on-gates.sh` (15) |
| 1d | chief leftovers: drop the console aliases, rename the names V5 missed | N01, N23, N24, N25, N26, N27, N36, N39 | HIMMEL-6647 | `scripts/lib/test-rename-aliases.sh` (69); `scripts/lib/rename-aliases.tsv` (65); `scripts/handover/console/test-console.sh` (52); `scripts/telegram/console-route.test.ts` (39); `scripts/handover/console-kit/test-headed-arm-leg.sh` (29); `scripts/handover/console-kit/console-wait.sh` (27) | <!-- old-term-ok: this page inventories the old names -->
| 2 | worker env and ids (V4a-2) | N02, N03, N04, N05, N06, N35, N38 | HIMMEL-7139 (HIMMEL-6642 closes with it); then HIMMEL-6647 drops the V4a-1 twins and hook forwarders | `scripts/handover/console-kit/test-headed-arm-leg.sh` (200); `scripts/lib/rename-aliases.tsv` (142); `scripts/handover/console-kit/headed-arm-leg.sh` (137); `scripts/lib/test-rename-aliases.sh` (116); `scripts/lanes/tests/plugin-profiles.test.mjs` (67); `scripts/hooks/test-guard-leg-context-handoff.sh` (48) |
| 3 | worker scripts (V4b) | N15, N16, N17, N18 | HIMMEL-6643 | `scripts/handover/console-kit/test-headed-arm-leg.sh` (27); `scripts/handover/console-kit/headed-arm-leg.sh` (21); `scripts/handover/console-kit/close-wrapped-leg.sh` (20); `scripts/handover/console-kit/leg-digest-step.sh` (20); `docs/internals/lane-calibration.md` (18); `scripts/ci/suite-durations.tsv` (14) |
| 4 | templates, prefaces and tick fields (T) | N20, N21, N22, N34 | HIMMEL-6644 | `scripts/handover/console-kit/test-tick.sh` (83); `scripts/testing/documented-commands.tsv` (42); `scripts/handover/test-succession-docs.sh` (30); `scripts/handover/console-kit/test-headed-arm-leg.sh` (23); `scripts/handover/console-kit/tick.sh` (17); `scripts/handover/console-kit/test-console-wait.sh` (17) |
| 5 | docs prose and message text (D) | N33 | HIMMEL-6645 | `scripts/handover/test-retask-doc-bus.sh` (2); `scripts/hooks/guard-bus-store.sh` (2); `scripts/hooks/test-guard-bus-store.sh` (2); `docs/internals/egress-matrix.md` (1); `docs/internals/enforcement.md` (1); `docs/internals/retask-channel.md` (1) |
| 6 | directory moves (M) | N19, N40, N41 | HIMMEL-6646 | `scripts/ci/suite-tiers.tsv` (84); `scripts/ci/suite-durations.tsv` (74); `scripts/hooks/test-block-chokepoint-env-prefix.sh` (65); `scripts/hooks/test-guard-pr-check-literal.sh` (56); `scripts/lint/swallowed-errors-baseline.txt` (49); `docs/guide/dev-graph/graph.json` (44) |
| 7 | removal (X) | none | HIMMEL-6647 | `scripts/lib/env-alias.sh`, `scripts/lib/env_alias.py` and their tests; `scripts/lib/rename-aliases.tsv`, `scripts/lib/test-rename-aliases.sh`; the registry lookup in `scripts/docs/check-old-terms.sh`; this page |

Notes on the order:
1. The Done families' leftovers go first (1a to 1d, HIMMEL-6647). Their new names already work, so
   each PR only moves the remaining old-name callers to the new name and then deletes the forwarder,
   alias or read-both line; nothing waits on another slice. Within a family the caller moves and the
   forwarder deletion are one PR: deleting `bank-preflight.sh` first would break every CR script and
   the console kit that still call it. <!-- old-term-ok: this page inventories the old names -->
2. 1a to 1d touch disjoint names and can run in any order; afk first because it is the smallest.
   1d also renames the names V5 missed (N36's two hooks, which need the settings paste, and N39).
3. V4a-2 (2) before the worker scripts (3): the scripts read the env names, so renaming the env first
   keeps each PR's breakage to one kind. The V4a-1 twins (`leg_env_twin` in `headed-arm-leg.sh`) and
   the N35 hook forwarders go once HIMMEL-7139 has switched `.claude/settings.json` to the new hook paths.
   The security markers (`HIMMEL_WORKER`, `HIMMEL_CONSOLE_*`) are not renamed.
4. Templates, prefaces and tick fields (4) after the scripts that read them (`headed-arm-worker.sh`
   reads the preface); `tick.sh` and `console-wait.sh` change the tick fields in the same PR.
5. Directory moves (6) after HIMMEL-6296 and after every open console-kit PR merges: the path-keyed
   files (`ci-trust-paths.txt`, `.pre-commit-config.yaml`, `suite-durations.tsv`,
   `shell-lint-baseline.tsv`, the dev graph, `site/allowlist.txt`) move in the same PR. No symlink
   stays at the old path.
6. The removal step (7) is last: `alias_env`, `env_alias_permit` and `alias_env_cap` keep callers
   until 1a to 1d and the V4a-1 twins are gone, and the old-term lint reads the registry until then.
7. `watchdog` (N31) is in no PR: its rename is deferred until the glossary names an id.

## Kept names and names with no identifier

| Name | Why not in the tables above |
|---|---|
| `HIMMEL_CONSOLE_*` identity markers (F1, F1b) | Kept by OD-1 (2026-10-20); the glossary lists them under Do not rename. If the breaking-change ruling reverses OD-1, they are a new family (V5-ID) and need this inventory re-run. |
| `HIMMEL_WORKER` | Live security marker; a worker does not carry it. |
| `CONSOLE_KIT_FIXTURE`, `CONSOLE_ROLE`, `CONSOLE_VERB`, `GIT_SEQUENCE_EDITOR` | The registry marks them keep: another sense (a fixture switch, a retired test variable, the Telegram `/consoles` verb, git's own variable). |
| `/supervisor-session`, `himmel-ops:supervisor-session` | Permanent aliases of `/chief` (OD-6). |
| The initiative chain: `scripts/lib/initiative-legs.sh`, the plugin's `scripts/legs.sh` wrapper, `resolve_legs` and their tests | The auto-ship step sense of leg, not the fleet sense (the glossary's Do not rename list). | <!-- old-term-ok: this page inventories the old names -->
| The `<git-dir>/cr-pending/` dir | Kept by OD-3. |
| F15 (`chain`, `wave`, `ticket sequence`, `batch`) | Glossary and prose only; no fleet-sense identifier exists (`WAVE` and `FIRST_WAVE` are a lint word and a comment). |
| F12 (`chokepoint-*`) | On hold; docs-only per the glossary. |
| The plain-name table's prose terms (review-owed marker, finding status, variant sweep, off switch, warn-only, usage-cap auto-relaunch, soft block, revision, token, scheduled launch, shift handoff) | Prose, not identifiers; HIMMEL-6645 owns them. |

## Forwarders and aliases at old paths (HIMMEL-6647)

Tracked files at the same sha whose own name carries an old name and whose first lines say they
forward, alias or redirect to the new name. Each is deleted by its family's leftover PR, after the
last caller moves.

| Path |
|---|
| `.claude/commands/console.md` |
| `.claude/commands/overnight-shift.md` |
| `docs/handover/overnight-mode.md` |
| `marketplace/plugins/himmel-ops/commands/console.md` |
| `scripts/cr/clear-cr-marker.sh` |
| `scripts/handover/console/console.sh` |
| `scripts/hooks/block-leg-askuserquestion.sh` |
| `scripts/hooks/guard-leg-wakeup.sh` |
| `scripts/lanes/bank-status.ts` |
| `scripts/lanes/codex-bank-probe.ts` |
| `scripts/lib/bank-attribution.sh` |
| `scripts/lib/bank-lift.sh` |
| `scripts/lib/bank-monitor.sh` |
| `scripts/lib/bank-preflight.sh` |
| `scripts/lib/console-context.sh` |
| `scripts/lib/cr-available.sh` |
| `scripts/lib/cr-body-findings.sh` |
| `scripts/lib/cr-default-base.sh` |
| `scripts/lib/cr-high-risk-diff.sh` |
| `scripts/lib/cr-ledger-evidence.sh` |
| `scripts/lib/cr-merge-gate.sh` |
| `scripts/lib/cr-signal.sh` |
| `scripts/lib/cr-trigger-ledger.sh` |

## Hits per old name

### N01 `CONSOLE_* (operator-typed and script-local)` to `CHIEF_*`

Family F1c, slice V5; env var; owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 314 lines in 49 files; new name live 59/60. HIMMEL_CONSOLE_* (OD-1) and the registry keeps CONSOLE_KIT_FIXTURE, CONSOLE_ROLE, CONSOLE_VERB are excluded; CONSOLE_WAIT_BANK goes to CHIEF_WAIT_USAGE and CONSOLE_WAIT_LEG_EVENT to CHIEF_WAIT_WORKER_EVENT.

Distinct matched strings (60): `CONSOLE_ARM_FOREGROUND` to `CHIEF_ARM_FOREGROUND` (live), `CONSOLE_BUCKET` to `CHIEF_BUCKET` (live), `CONSOLE_BUS_CLI` to `CHIEF_BUS_CLI` (live), `CONSOLE_BUS_PREDECESSOR` to `CHIEF_BUS_PREDECESSOR` (live), `CONSOLE_BUS_PROFILES_MJS` to `CHIEF_BUS_PROFILES_MJS` (live), `CONSOLE_CACHE_READ_BUDGET_M` to `CHIEF_CACHE_READ_BUDGET_M` (live), `CONSOLE_CONTEXT` to `CHIEF_CONTEXT` (live), `CONSOLE_CONTEXT_` to `CHIEF_CONTEXT_` (live), `CONSOLE_CONTEXT_RECORD_DIR` to `CHIEF_CONTEXT_RECORD_DIR` (live), `CONSOLE_CONTEXT_RESOLVED_MODE` to `CHIEF_CONTEXT_RESOLVED_MODE` (live), `CONSOLE_CONTEXT_RESOLVED_SOURCE` to `CHIEF_CONTEXT_RESOLVED_SOURCE` (live), `CONSOLE_DISPATCH_DISABLE` to `CHIEF_DISPATCH_DISABLE` (live), `CONSOLE_DISPATCH_LOG` to `CHIEF_DISPATCH_LOG` (live), `CONSOLE_DISPATCH_OK` to `CHIEF_DISPATCH_OK` (live), `CONSOLE_DISPATCH_TRANSCRIPT_HEAD_LINES` to `CHIEF_DISPATCH_TRANSCRIPT_HEAD_LINES` (live), `CONSOLE_DOC` to `CHIEF_DOC` (live), `CONSOLE_ENV` to `CHIEF_ENV` (live), `CONSOLE_FG_LIST` to `CHIEF_FG_LIST` (live), `CONSOLE_FG_OK` to `CHIEF_FG_OK` (live), `CONSOLE_FILL_PERCENT` to `CHIEF_FILL_PERCENT` (live), `CONSOLE_FLAG` to `CHIEF_FLAG` (live), `CONSOLE_HEADED_ARM` to `CHIEF_HEADED_ARM` (live), `CONSOLE_LAUNCH_ENV` to `CHIEF_LAUNCH_ENV` (live), `CONSOLE_MODE` to `CHIEF_MODE` (live), `CONSOLE_MODEL` to `CHIEF_MODEL` (live), `CONSOLE_NAME` to `CHIEF_NAME` (live), `CONSOLE_NEW_KNOB` to `CHIEF_NEW_KNOB`, `CONSOLE_PAYLOAD` to `CHIEF_PAYLOAD` (live), `CONSOLE_PAYLOAD_ACTIVE` to `CHIEF_PAYLOAD_ACTIVE` (live), `CONSOLE_PRECOMPACT_DOC` to `CHIEF_PRECOMPACT_DOC` (live), `CONSOLE_PRECOMPACT_WORKDIR` to `CHIEF_PRECOMPACT_WORKDIR` (live), `CONSOLE_SESSION_NAME` to `CHIEF_SESSION_NAME` (live), `CONSOLE_TEMPLATE_DIR` to `CHIEF_TEMPLATE_DIR` (live), `CONSOLE_TRANSCRIPT` to `CHIEF_TRANSCRIPT` (live), `CONSOLE_TURN_BUDGET` to `CHIEF_TURN_BUDGET` (live), `CONSOLE_WAIT` to `CHIEF_WAIT` (live), `CONSOLE_WAIT_BANK` to `CHIEF_WAIT_USAGE` (live), `CONSOLE_WAIT_BUDGET` to `CHIEF_WAIT_BUDGET` (live), `CONSOLE_WAIT_BUDGET_TIMEOUT` to `CHIEF_WAIT_BUDGET_TIMEOUT` (live), `CONSOLE_WAIT_CLOSE` to `CHIEF_WAIT_CLOSE` (live), `CONSOLE_WAIT_CLOSE_HANGS` to `CHIEF_WAIT_CLOSE_HANGS` (live), `CONSOLE_WAIT_CLOSE_TIMEOUT` to `CHIEF_WAIT_CLOSE_TIMEOUT` (live), `CONSOLE_WAIT_DISPATCH` to `CHIEF_WAIT_DISPATCH` (live), `CONSOLE_WAIT_DISPATCH_TIMEOUT` to `CHIEF_WAIT_DISPATCH_TIMEOUT` (live), `CONSOLE_WAIT_FAIL_WAKE` to `CHIEF_WAIT_FAIL_WAKE` (live), `CONSOLE_WAIT_HANDOVER_MIN` to `CHIEF_WAIT_HANDOVER_MIN` (live), `CONSOLE_WAIT_INTERVAL` to `CHIEF_WAIT_INTERVAL` (live), `CONSOLE_WAIT_LEG_EVENT` to `CHIEF_WAIT_WORKER_EVENT` (live), `CONSOLE_WAIT_LOCK_STATUS` to `CHIEF_WAIT_LOCK_STATUS` (live), `CONSOLE_WAIT_PAGE_CMD` to `CHIEF_WAIT_PAGE_CMD` (live), `CONSOLE_WAIT_PAGE_TIMEOUT` to `CHIEF_WAIT_PAGE_TIMEOUT` (live), `CONSOLE_WAIT_POLL_SEC` to `CHIEF_WAIT_POLL_SEC` (live), `CONSOLE_WAIT_RELAY` to `CHIEF_WAIT_RELAY` (live), `CONSOLE_WAIT_SUCCESSION_SEC` to `CHIEF_WAIT_SUCCESSION_SEC` (live), `CONSOLE_WAIT_TICK` to `CHIEF_WAIT_TICK` (live), `CONSOLE_WAIT_TICK_TIMEOUT` to `CHIEF_WAIT_TICK_TIMEOUT` (live), `CONSOLE_WAIT_TRACKER` to `CHIEF_WAIT_TRACKER` (live), `CONSOLE_WAIT_TRACKER_STALE_MIN` to `CHIEF_WAIT_TRACKER_STALE_MIN` (live), `CONSOLE_WAIT_UNOWNED_REWAKE_MIN` to `CHIEF_WAIT_UNOWNED_REWAKE_MIN` (live), `CONSOLE_WORK_DIR` to `CHIEF_WORK_DIR` (live) <!-- old-term-ok: this page inventories the old names -->

| File | Class | Lines |
|---|---|---|
| `.claude/commands/chief.md` | docs | 32 |
| `docs/handover/console-sections/monitors.md` | docs | 75 |
| `docs/handover/console-template.md` | docs | 237 |
| `docs/handover/relay-brief-template.md` | docs | 62 |
| `docs/handover/running-a-console.md` | docs | 99, 470 |
| `docs/internals/enforcement.md` | docs | 3886, 3889, 3910, 5078 |
| `docs/internals/lane-calibration.md` | docs | 601, 635, 755, 790, 792 |
| `docs/setup/new-machine.md` | docs | 608 |
| `marketplace/plugins/himmel-ops/commands/chief.md` | docs | 94 |
| `scripts/docs/test-check-old-terms.sh` | test | 56 |
| `scripts/handover/arm-resume.sh` | code | 579, 580, 581 |
| `scripts/handover/console-kit/console-budget.sh` | code | 6, 35, 36 |
| `scripts/handover/console-kit/console-wait.sh` | code | 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253 |
| `scripts/handover/console-kit/cr-disposition.sh` | code | 110 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-2973.md` | fixture | 26, 27 |
| `scripts/handover/console-kit/go.sh` | code | 406 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 1165, 1177, 2278, 2280 |
| `scripts/handover/console-kit/test-console-budget.sh` | test | 22, 57, 58, 59, 72, 73 |
| `scripts/handover/console-kit/test-console-wait-b.sh` | test | 8, 21 |
| `scripts/handover/console-kit/test-console-wait-pool.sh` | test | 10, 19 |
| `scripts/handover/console-kit/test-console-wait-r0.sh` | test | 33 |
| `scripts/handover/console-kit/test-console-wait.sh` | test | 8, 18, 215, 220, 223 |
| `scripts/handover/console-kit/test-cr-disposition.sh` | test | 21, 123 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 177 |
| `scripts/handover/console-kit/test-go.sh` | test | 9, 24, 122, 132, 134, 143, 154, 613 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 236, 460, 462, 464, 465, 466, 467, 545, 549, 1011, 1014, 1017, 1018, 2972, 3016 |
| `scripts/handover/console-kit/test-inbox-send.sh` | test | 155, 156, 159, 161 |
| `scripts/handover/console-kit/test-ready-go.sh` | test | 21 |
| `scripts/handover/console-kit/test-tick-deadwin.sh` | test | 146, 147 |
| `scripts/handover/console-kit/test-tick-nolive.sh` | test | 172, 173 |
| `scripts/handover/console/console-bus-exec.sh` | code | 27 |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` | test | 71 |
| `scripts/handover/console/test-console.sh` | test | 207, 238, 854, 874, 930, 955, 1000, 1035, 1050, 1097, 1112, 1641, 1647, 1651, 1678, 1682, 1684, 1698 |
| `scripts/handover/headed-arm.sh` | code | 314, 316, 317 |
| `scripts/handover/test-arm-resume-context.sh` | test | 344, 348, 350 |
| `scripts/handover/test-headed-arm.sh` | test | 319, 322, 325, 326, 331, 334, 335, 339, 404, 422, 464, 488, 498 |
| `scripts/handover/test-merge-fork-pr.sh` | test | 19 |
| `scripts/himmelctl/lib/bypass-flags.json` | config | 57, 65, 85, 90, 93, 98 |
| `scripts/hooks/guard-console-dispatch.sh` | code | 86, 106, 131, 196, 288 |
| `scripts/hooks/guard-console-foreground.sh` | code | 28, 31, 43, 69, 122 |
| `scripts/hooks/guard-relay-writes.sh` | code | 37, 275 |
| `scripts/hooks/test-guard-console-dispatch.sh` | test | 187, 320, 321, 322, 325, 326, 329, 331, 341, 342, 344, 345, 357, 358 |
| `scripts/hooks/test-guard-console-foreground.sh` | test | 173, 177, 178, 179, 180, 183, 184, 191, 192, 193, 194 |
| `scripts/hooks/test-guard-relay-writes.sh` | test | 142, 150 |
| `scripts/lib/chief-context.sh` | code | 123 |
| `scripts/lib/override-env.sh` | code | 41, 45, 50 |
| `scripts/lib/rename-aliases.tsv` | config | 32, 33, 34, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 146, 147, 148, 149, 150, 151, 152, 153, 155, 156, 157, 158, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174, 175, 176, 177, 178, 179, 180, 181, 182, 183, 184 |
| `scripts/lib/test-rename-aliases.sh` | test | 34, 35, 36, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 409, 410, 411, 413, 414, 416, 417 |
| `scripts/telegram/console-route.test.ts` | test | 411 |

### N02 `HIMMEL_LEG_*` to `HIMMEL_WORKER_SESSION_*`

Family F2, slice V4a; env var; owner HIMMEL-6642 / HIMMEL-7139; 136 lines in 33 files; new name live 8/9. never HIMMEL_WORKER_* (live security marker).

Distinct matched strings (9): `HIMMEL_LEG_AUTOCOMPACT` to `HIMMEL_WORKER_SESSION_AUTOCOMPACT` (live), `HIMMEL_LEG_CACHE_KEEPALIVE_SECS` to `HIMMEL_WORKER_SESSION_CACHE_KEEPALIVE_SECS`, `HIMMEL_LEG_CONTEXT_MODE` to `HIMMEL_WORKER_SESSION_CONTEXT_MODE` (live), `HIMMEL_LEG_CONTEXT_SHARE` to `HIMMEL_WORKER_SESSION_CONTEXT_SHARE` (live), `HIMMEL_LEG_DOC` to `HIMMEL_WORKER_SESSION_DOC` (live), `HIMMEL_LEG_FAILURES_LEDGER` to `HIMMEL_WORKER_SESSION_FAILURES_LEDGER` (live), `HIMMEL_LEG_ID` to `HIMMEL_WORKER_SESSION_ID` (live), `HIMMEL_LEG_MEMORY_MAX` to `HIMMEL_WORKER_SESSION_MEMORY_MAX` (live), `HIMMEL_LEG_PROFILE` to `HIMMEL_WORKER_SESSION_PROFILE` (live) <!-- old-term-ok: this page inventories the old names -->

| File | Class | Lines |
|---|---|---|
| `docs/internals/enforcement.md` | docs | 4048, 4064 |
| `docs/internals/leg-context-guard.md` | docs | 35, 39 |
| `scripts/config-ui/tests/tool-health.test.ts` | test | 34, 142, 173, 178 |
| `scripts/eval/leg-digest/leg_ledger.py` | code | 11, 67 |
| `scripts/eval/leg-digest/test-leg-ledger.sh` | test | 24, 182 |
| `scripts/eval/leg-digest/tool-health.mjs` | code | 29 |
| `scripts/eval/session-retro.py` | code | 6, 30 |
| `scripts/eval/test-session-retro.sh` | test | 72 |
| `scripts/handover/console-kit/board.mjs` | code | 710, 739 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 298, 299, 306, 387, 388, 389, 1255, 1266, 1548, 1552, 1554, 1556, 1559, 1560, 2223, 2278, 2281 |
| `scripts/handover/console-kit/test-board.sh` | test | 39, 817 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 26, 49, 51, 54, 75 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 132 |
| `scripts/handover/console-kit/test-tick.sh` | test | 214, 2360, 2369, 2385, 2387, 2391, 2598, 2609, 2614 |
| `scripts/handover/console-kit/tick.sh` | code | 121, 1807 |
| `scripts/handover/console/test-console.sh` | test | 1855, 1876, 1923, 1924, 1925, 1948, 1949 |
| `scripts/handover/merge-on-green.sh` | code | 337 |
| `scripts/handover/test-merge-on-green-jira-end-state.sh` | test | 26 |
| `scripts/handover/test-merge-on-green.sh` | test | 23 |
| `scripts/hooks/guard-leg-cache-ttl.sh` | code | 30, 124 |
| `scripts/hooks/guard-leg-context-handoff.sh` | code | 16, 41, 43, 123, 128, 197, 423 |
| `scripts/hooks/test-crlf-boundary.sh` | test | 854, 857 |
| `scripts/hooks/test-guard-leg-cache-ttl.sh` | test | 145, 146, 147, 149 |
| `scripts/hooks/test-guard-leg-context-handoff.sh` | test | 24, 25, 50, 122, 123, 132, 133, 134, 135, 136, 182, 190, 195, 203, 208, 213, 418, 428, 505, 506, 507, 510, 511, 525, 526, 527, 528, 530, 532, 533, 534, 535 |
| `scripts/jira/src/commands/release.test.ts` | test | 198 |
| `scripts/lanes/leg-burn.sh` | code | 86 |
| `scripts/lanes/leg-pr-open.sh` | code | 134 |
| `scripts/lanes/test-leg-pr-open.sh` | test | 342 |
| `scripts/lanes/tests/test-leg-burn.sh` | test | 45 |
| `scripts/lib/chief-context.sh` | code | 218, 220, 240 |
| `scripts/lib/rename-aliases.tsv` | config | 35, 208, 209, 210, 211, 212, 213, 214 |
| `scripts/lib/test-override-env.sh` | test | 254 |
| `scripts/lib/test-rename-aliases.sh` | test | 430, 431, 432, 433, 434, 468, 469, 470 |

### N03 `HIMMEL_LEAN_LEG` to `HIMMEL_LEAN_WORKER_SESSION`

Family F2, slice V4a; env var; owner HIMMEL-6642 / HIMMEL-7139; 55 lines in 16 files; new name live 1/1.

Distinct matched strings (1): `HIMMEL_LEAN_LEG` to `HIMMEL_LEAN_WORKER_SESSION` (live)

| File | Class | Lines |
|---|---|---|
| `docs/handover/running-a-console.md` | docs | 203 |
| `docs/internals/lane-calibration.md` | docs | 157 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 153, 308, 2174, 2320 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 23 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 65, 130, 236, 769, 1145, 1414, 1418, 1430, 1669, 2880, 3192, 3201 |
| `scripts/handover/console/test-console.sh` | test | 1879, 1922 |
| `scripts/hooks/graphify-freshness-advisory.sh` | code | 39, 47 |
| `scripts/hooks/inject-where-are-we.sh` | code | 42, 50 |
| `scripts/hooks/qmd-staleness-notice.sh` | code | 41, 49 |
| `scripts/hooks/test-graphify-freshness-advisory.sh` | test | 5, 9, 38, 46, 149, 150, 154, 155, 184 |
| `scripts/hooks/test-inject-where-are-we.sh` | test | 15, 19, 98, 106, 301, 305, 316, 319 |
| `scripts/hooks/test-qmd-staleness-notice.sh` | test | 19, 23, 131, 135, 174, 177, 180 |
| `scripts/lib/chief-context.sh` | code | 244 |
| `scripts/lib/rename-aliases.tsv` | config | 37 |
| `scripts/lib/test-override-env.sh` | test | 253 |
| `scripts/lib/test-rename-aliases.sh` | test | 38 |

### N04 `LEG_*` to `WORKER_SESSION_*`

Family F2, slice V4a; env var; owner HIMMEL-6642 / HIMMEL-7139; 497 lines in 60 files; new name live 85/94. LEG_SESSION_ID goes to WORKER_SESSION_ID; LEG_DIGEST_CHAIN_SLACK_MIN: the registry says WORKER_SESSION_DIGEST_CHAIN_SLACK_MIN, plan row 67 says WORKER_DIGEST_SLACK_MIN (the rename PR settles it).

Distinct matched strings (94): `LEG_ALLOW` to `WORKER_SESSION_ALLOW` (live), `LEG_API_LANE` to `WORKER_SESSION_API_LANE` (live), `LEG_AUTOCOMPACT_AB` to `WORKER_SESSION_AUTOCOMPACT_AB` (live), `LEG_BURN` to `WORKER_SESSION_BURN` (live), `LEG_BURN_BIN` to `WORKER_SESSION_BURN_BIN` (live), `LEG_BURN_HERE` to `WORKER_SESSION_BURN_HERE` (live), `LEG_BURN_PROJECTS_DIR` to `WORKER_SESSION_BURN_PROJECTS_DIR` (live), `LEG_BURN_RAW` to `WORKER_SESSION_BURN_RAW` (live), `LEG_BURN_W_` to `WORKER_SESSION_BURN_W_` (live), `LEG_BURN_W_CACHE_CREATE` to `WORKER_SESSION_BURN_W_CACHE_CREATE` (live), `LEG_BURN_W_CACHE_READ` to `WORKER_SESSION_BURN_W_CACHE_READ` (live), `LEG_BURN_W_INPUT` to `WORKER_SESSION_BURN_W_INPUT` (live), `LEG_BURN_W_OUTPUT` to `WORKER_SESSION_BURN_W_OUTPUT` (live), `LEG_BUS_PAIR` to `WORKER_SESSION_BUS_PAIR` (live), `LEG_CALLS` to `WORKER_SESSION_CALLS` (live), `LEG_CLAUDE_BIN` to `WORKER_SESSION_CLAUDE_BIN` (live), `LEG_CONFIG_DIR` to `WORKER_SESSION_CONFIG_DIR` (live), `LEG_CONTEXT` to `WORKER_SESSION_CONTEXT` (live), `LEG_CONTEXT_HANDOFF_OK` to `WORKER_SESSION_CONTEXT_HANDOFF_OK` (live), `LEG_COST_LEDGER` to `WORKER_SESSION_COST_LEDGER` (live), `LEG_DIGEST_BIN` to `WORKER_SESSION_DIGEST_BIN` (live), `LEG_DIGEST_CHAIN_SLACK_MIN` to `WORKER_SESSION_DIGEST_CHAIN_SLACK_MIN` (live), `LEG_DIGEST_SETTLE_MAX` to `WORKER_SESSION_DIGEST_SETTLE_MAX` (live), `LEG_DIGEST_SETTLE_QUIET` to `WORKER_SESSION_DIGEST_SETTLE_QUIET` (live), `LEG_DIGEST_STATE_DIR` to `WORKER_SESSION_DIGEST_STATE_DIR` (live), `LEG_DIGEST_STEP_BIN` to `WORKER_SESSION_DIGEST_STEP_BIN` (live), `LEG_DIGEST_TIMEOUT` to `WORKER_SESSION_DIGEST_TIMEOUT` (live), `LEG_DOC` to `WORKER_SESSION_DOC` (live), `LEG_DOC_AFTER_DRYRUN` to `WORKER_SESSION_DOC_AFTER_DRYRUN` (live), `LEG_DOC_BEFORE_DRYRUN` to `WORKER_SESSION_DOC_BEFORE_DRYRUN` (live), `LEG_DONE_MARKER` to `WORKER_SESSION_DONE_MARKER` (live), `LEG_DRIFT` to `WORKER_SESSION_DRIFT` (live), `LEG_EFFORT` to `WORKER_SESSION_EFFORT` (live), `LEG_ENV_SCRUB` to `WORKER_SESSION_ENV_SCRUB` (live), `LEG_EXPLORATION_FLAG_TOKENS` to `WORKER_SESSION_EXPLORATION_FLAG_TOKENS` (live), `LEG_FAILED_MARKER` to `WORKER_SESSION_FAILED_MARKER` (live), `LEG_HEADLESS` to `WORKER_SESSION_HEADLESS` (live), `LEG_IDENTITY` to `WORKER_SESSION_IDENTITY` (live), `LEG_JIRA_CLI` to `WORKER_SESSION_JIRA_CLI` (live), `LEG_JIRA_STATUS` to `WORKER_SESSION_JIRA_STATUS` (live), `LEG_LABEL_CLASS` to `WORKER_SESSION_LABEL_CLASS` (live), `LEG_LANE` to `WORKER_SESSION_LANE` (live), `LEG_LIST` to `WORKER_SESSION_LIST` (live), `LEG_LOCKDIR` to `WORKER_SESSION_LOCKDIR`, `LEG_LOG` to `WORKER_SESSION_LOG` (live), `LEG_MEMORY_MAX` to `WORKER_SESSION_MEMORY_MAX` (live), `LEG_MODE` to `WORKER_SESSION_MODE`, `LEG_NAME` to `WORKER_SESSION_NAME` (live), `LEG_OPERATOR_SPLIT_RE` to `WORKER_SESSION_OPERATOR_SPLIT_RE` (live), `LEG_ORDER` to `WORKER_SESSION_ORDER` (live), `LEG_PAYLOAD` to `WORKER_SESSION_PAYLOAD`, `LEG_PID` to `WORKER_SESSION_PID`, `LEG_PIDS` to `WORKER_SESSION_PIDS` (live), `LEG_PREFACE` to `WORKER_SESSION_PREFACE` (live), `LEG_PRETRUST_CONFIG` to `WORKER_SESSION_PRETRUST_CONFIG` (live), `LEG_PRETRUST_HOME` to `WORKER_SESSION_PRETRUST_HOME` (live), `LEG_PRETRUST_KEY` to `WORKER_SESSION_PRETRUST_KEY` (live), `LEG_PRETRUST_LOCK_TRIES` to `WORKER_SESSION_PRETRUST_LOCK_TRIES` (live), `LEG_PROBE_UNREGISTERED` to `WORKER_SESSION_PROBE_UNREGISTERED`, `LEG_PROFILE` to `WORKER_SESSION_PROFILE` (live), `LEG_PROFILES` to `WORKER_SESSION_PROFILES` (live), `LEG_PROFILE_` to `WORKER_SESSION_PROFILE_` (live), `LEG_PROFILE_MCP_CONFIG` to `WORKER_SESSION_PROFILE_MCP_CONFIG` (live), `LEG_PROFILE_NO_SETTING_SOURCES` to `WORKER_SESSION_PROFILE_NO_SETTING_SOURCES` (live), `LEG_PROFILE_PREFACE` to `WORKER_SESSION_PROFILE_PREFACE` (live), `LEG_PROFILE_SETTINGS` to `WORKER_SESSION_PROFILE_SETTINGS` (live), `LEG_RE` to `WORKER_SESSION_RE` (live), `LEG_RELEASE_TOKEN` to `WORKER_SESSION_RELEASE_TOKEN`, `LEG_REPO` to `WORKER_SESSION_REPO` (live), `LEG_REPO_MAP` to `WORKER_SESSION_REPO_MAP` (live), `LEG_REPO_MAP_TIMEOUT` to `WORKER_SESSION_REPO_MAP_TIMEOUT` (live), `LEG_REPO_MAP_TOKENS` to `WORKER_SESSION_REPO_MAP_TOKENS` (live), `LEG_RESYNC` to `WORKER_SESSION_RESYNC` (live), `LEG_SANCTIONED` to `WORKER_SESSION_SANCTIONED` (live), `LEG_SCOPE` to `WORKER_SESSION_SCOPE` (live), `LEG_SCOPE_WARN` to `WORKER_SESSION_SCOPE_WARN` (live), `LEG_SCRATCH_OK` to `WORKER_SESSION_SCRATCH_OK` (live), `LEG_SESSION_ID` to `WORKER_SESSION_ID` (live), `LEG_SH` to `WORKER_SESSION_SH` (live), `LEG_SHIM` to `WORKER_SESSION_SHIM` (live), `LEG_SKIPPED_MARKER` to `WORKER_SESSION_SKIPPED_MARKER` (live), `LEG_SNAP_ONLY` to `WORKER_SESSION_SNAP_ONLY`, `LEG_STALE_MARK` to `WORKER_SESSION_STALE_MARK` (live), `LEG_STATUSES` to `WORKER_SESSION_STATUSES` (live), `LEG_SUPPRESS_CR_TRIGGER` to `WORKER_SESSION_SUPPRESS_CR_TRIGGER` (live), `LEG_SYSTEMD_RUN` to `WORKER_SESSION_SYSTEMD_RUN` (live), `LEG_TIMELINE_CHAIN_LEDGER` to `WORKER_SESSION_TIMELINE_CHAIN_LEDGER` (live), `LEG_TIMELINE_CR_LEDGER` to `WORKER_SESSION_TIMELINE_CR_LEDGER` (live), `LEG_TIMELINE_WORKER_CLAUDEX` to `WORKER_SESSION_TIMELINE_WORKER_CLAUDEX` (live), `LEG_TIMELINE_WORKER_GLM` to `WORKER_SESSION_TIMELINE_WORKER_GLM` (live), `LEG_TIMEOUT` to `WORKER_SESSION_TIMEOUT` (live), `LEG_TRANSCRIPT` to `WORKER_SESSION_TRANSCRIPT`, `LEG_TURN_CAP` to `WORKER_SESSION_TURN_CAP` (live), `LEG_UNSTAGED_ROW` to `WORKER_SESSION_UNSTAGED_ROW` <!-- old-term-ok: this page inventories the old names -->

| File | Class | Lines |
|---|---|---|
| `docs/internals/enforcement.md` | docs | 4101 |
| `docs/internals/leg-context-guard.md` | docs | 217 |
| `scripts/check-ci.sh` | code | 1291 |
| `scripts/ci/test-run-shell-tests.sh` | test | 2918, 2925, 2927 |
| `scripts/claude-openrouter` | code | 328, 331, 419, 458 |
| `scripts/config-ui/agui/lane.ts` | code | 3, 13, 21, 22 |
| `scripts/config-ui/tests/agui-lane.test.ts` | test | 16, 17, 18, 19, 20 |
| `scripts/docs/test-check-old-terms.sh` | test | 51, 52, 86, 107, 110, 122, 135, 149, 158, 193, 196, 201, 203 |
| `scripts/eval/autocompact-ab.py` | code | 35, 36, 37, 38 |
| `scripts/eval/context-replay.py` | code | 19, 20, 21, 22 |
| `scripts/eval/handover-cost.py` | code | 50, 51, 52, 53 |
| `scripts/eval/leg-digest/leg-digest.ts` | code | 26 |
| `scripts/eval/leg-digest/leg_ledger.py` | code | 288, 496 |
| `scripts/eval/leg-digest/test-leg-ledger.sh` | test | 186 |
| `scripts/handover/arm-resume.sh` | code | 798, 801, 803, 6246 |
| `scripts/handover/console-kit/append-results.sh` | code | 194 |
| `scripts/handover/console-kit/board.mjs` | code | 642, 676, 679 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 435 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-2053-N2702-hermes-cr-gate-parity-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6476-N2804-leg-api-lane-switch-2026-10-19.md` | fixture | 7 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 94, 97, 171, 300, 301, 302, 303, 304, 305, 307, 379, 380, 381, 382, 383, 517, 842, 843, 1103, 1118, 1119, 1121, 1186, 1187, 1194, 1196, 1200, 1201, 1203, 1227, 1229, 1233, 1235, 1252, 1256, 1269, 1272, 1274, 1278, 1288, 1404, 1405, 1422, 1431, 1677, 1680, 1748, 1964, 2156, 2160, 2161, 2164, 2178, 2190, 2200, 2208, 2209, 2211, 2212, 2292, 2312, 2320, 2321, 2353, 2354, 2357, 2366, 2367, 2370, 2384, 2386, 2393, 2394, 2395, 2396, 2402, 2406, 2407, 2408, 2411, 2491, 2600, 2620 |
| `scripts/handover/console-kit/leg-digest-step.sh` | code | 52, 139, 177, 178, 180, 284 |
| `scripts/handover/console-kit/leg-jira-status.sh` | code | 85 |
| `scripts/handover/console-kit/leg-pretrust.sh` | code | 42, 83, 84, 133 |
| `scripts/handover/console-kit/status-drift.sh` | code | 129 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 8, 22, 23, 24, 25, 30, 63, 78, 95, 96, 99, 100, 102, 103, 105 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 130, 132, 3224, 3241, 4476, 4481, 4484, 4492 |
| `scripts/handover/console-kit/tick.sh` | code | 1830, 2106 |
| `scripts/handover/console/test-console.sh` | test | 1854, 1857, 1877, 1878, 1881, 1886, 1900, 1901, 1926, 1927, 1928, 1929, 1930, 1931, 1932, 1944, 1945 |
| `scripts/handover/headed-arm.sh` | code | 689, 730, 1029 |
| `scripts/handover/leg-timeline.sh` | code | 66, 67, 68, 80 |
| `scripts/handover/test-arm-resume-seam-scrub.sh` | test | 4, 77, 85, 86, 104, 112, 114, 125, 131 |
| `scripts/handover/test-merge-on-green-jira-end-state.sh` | test | 26 |
| `scripts/himmelctl/lib/bypass-flags.json` | config | 300, 305, 458 |
| `scripts/hooks/guard-leg-context-handoff.sh` | code | 101, 119, 424 |
| `scripts/hooks/test-bus-deliver-hook.sh` | test | 97 |
| `scripts/hooks/test-check-cr-best-effort.sh` | test | 61 |
| `scripts/hooks/test-graphify-freshness-advisory.sh` | test | 9 |
| `scripts/hooks/test-guard-console-dispatch.sh` | test | 86, 87, 212, 221 |
| `scripts/hooks/test-guard-leg-cache-ttl.sh` | test | 43, 44, 49, 58, 68 |
| `scripts/hooks/test-guard-leg-context-handoff.sh` | test | 43, 44, 47, 50, 88, 117, 124, 150, 156, 164, 165, 166, 167, 173, 416, 544 |
| `scripts/hooks/test-guard-relay-writes.sh` | test | 114, 133 |
| `scripts/hooks/test-inject-where-are-we.sh` | test | 19 |
| `scripts/hooks/test-qmd-staleness-notice.sh` | test | 23 |
| `scripts/hooks/test-stop-console-idle-guard.sh` | test | 71, 85, 112, 155, 228, 232, 233, 235, 236, 271, 288, 300, 304, 306, 310, 313, 320, 325, 402, 405 |
| `scripts/lanes/leg-burn.sh` | code | 100, 114 |
| `scripts/lanes/leg-claude-launcher.sh` | code | 69, 70, 71, 72, 73, 85, 110, 119, 128, 139, 141 |
| `scripts/lanes/leg-pr-open.sh` | code | 277 |
| `scripts/lanes/lib/burn-weights.sh` | code | 9, 10, 11, 12 |
| `scripts/lanes/lib/leg-cost-row.sh` | code | 55, 79 |
| `scripts/lib/chief-context.sh` | code | 224, 230, 232, 234, 236, 238, 242, 246, 261, 267, 269, 271, 273, 275, 277 |
| `scripts/lib/override-env.sh` | code | 45 |
| `scripts/lib/rename-aliases.tsv` | config | 36, 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255, 256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301, 302, 303, 304, 305, 306, 307, 308, 309, 310 |
| `scripts/lib/test-bank-preflight.sh` | test | 715, 733 |
| `scripts/lib/test-override-env.sh` | test | 255 |
| `scripts/lib/test-rename-aliases.sh` | test | 37, 435, 436, 437, 438, 439, 440, 441, 442, 471, 472, 473, 474, 475, 476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486, 487, 488, 489, 490, 491, 492, 493, 494, 495, 496, 497, 498, 499, 500, 501, 502, 503, 504, 505, 506, 507, 508, 509, 510, 511, 512, 513, 514, 515, 516, 517, 518, 519, 520, 521, 522, 523, 524, 525, 526, 527, 528, 529, 530, 531, 532, 533, 534, 535, 536, 537, 538, 539, 540, 541, 542, 543, 544, 545, 546, 547, 548, 549, 550, 551, 552 |
| `scripts/lib/ticket-status.sh` | code | 101 |
| `scripts/lib/usage-preflight.sh` | code | 82, 208 |
| `scripts/telegram/test-break-glass.sh` | test | 79 |
| `scripts/test-claude-openrouter.sh` | test | 38 |

### N05 `HEADED_ARM_LEG_*` to `HEADED_ARM_WORKER_*`

Family F2, slice V4a; env var; owner HIMMEL-6642 / HIMMEL-7139; 68 lines in 9 files; new name live 15/17.

Distinct matched strings (17): `HEADED_ARM_LEG` to `HEADED_ARM_WORKER`, `HEADED_ARM_LEG_` to `HEADED_ARM_WORKER_` (live), `HEADED_ARM_LEG_BRAND_NEW` to `HEADED_ARM_WORKER_BRAND_NEW`, `HEADED_ARM_LEG_CLAUDEX_BIN` to `HEADED_ARM_WORKER_CLAUDEX_BIN` (live), `HEADED_ARM_LEG_CLAUDE_BIN` to `HEADED_ARM_WORKER_CLAUDE_BIN` (live), `HEADED_ARM_LEG_DEEPSEEK_BIN` to `HEADED_ARM_WORKER_DEEPSEEK_BIN` (live), `HEADED_ARM_LEG_LANES_JSON` to `HEADED_ARM_WORKER_LANES_JSON` (live), `HEADED_ARM_LEG_OPENROUTER_BIN` to `HEADED_ARM_WORKER_OPENROUTER_BIN` (live), `HEADED_ARM_LEG_PREFACE` to `HEADED_ARM_WORKER_PREFACE` (live), `HEADED_ARM_LEG_PREFLIGHT` to `HEADED_ARM_WORKER_PREFLIGHT` (live), `HEADED_ARM_LEG_PROFILES` to `HEADED_ARM_WORKER_PROFILES` (live), `HEADED_ARM_LEG_REPO_MAP` to `HEADED_ARM_WORKER_REPO_MAP` (live), `HEADED_ARM_LEG_SHIM` to `HEADED_ARM_WORKER_SHIM` (live), `HEADED_ARM_LEG_SYSTEMD_RUN` to `HEADED_ARM_WORKER_SYSTEMD_RUN` (live), `HEADED_ARM_LEG_TARGET` to `HEADED_ARM_WORKER_TARGET` (live), `HEADED_ARM_LEG_VMS_JSON` to `HEADED_ARM_WORKER_VMS_JSON` (live), `HEADED_ARM_LEG_WAKER` to `HEADED_ARM_WORKER_WAKER` (live) <!-- old-term-ok: this page inventories the old names -->

| File | Class | Lines |
|---|---|---|
| `scripts/chokepoints.json` | config | 30 |
| `scripts/docs/test-check-old-terms.sh` | test | 55 |
| `scripts/eval/lane-quality/pilot-4869/sandbox.sh` | code | 216 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 549, 550, 553, 554, 561, 649, 652, 655, 799, 902, 1080, 1287, 1288, 1290, 1292, 1627, 1745, 1746, 1756, 1767, 1769, 1771, 1773, 2199, 2238, 2385, 2425, 2627 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 20, 31, 32, 113 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 132 |
| `scripts/handover/headed-arm.sh` | code | 345, 353 |
| `scripts/lib/rename-aliases.tsv` | config | 48, 193, 194, 195, 196, 197, 198, 199, 200, 201, 202, 203, 204, 205, 206 |
| `scripts/lib/test-rename-aliases.sh` | test | 48, 454, 455, 456, 457, 458, 459, 460, 461, 462, 463, 464, 465, 466, 467 |

### N06 `profile ids leg-impl, leg-bus, leg-vm` to `worker-impl, worker-bus, worker-vm`

Family F2, slice V4a; flag value; owner HIMMEL-6642; 391 lines in 60 files; new name live 3/3.

Distinct matched strings (3): `leg-bus` to `worker-bus` (live), `leg-impl` to `worker-impl` (live), `leg-vm` to `worker-vm` (live)

| File | Class | Lines |
|---|---|---|
| `.agents/skills/pr-check/SKILL.md` | docs | 318 |
| `docs/handover/console-template.md` | docs | 149 |
| `docs/handover/running-a-console.md` | docs | 164, 200 |
| `docs/himmel-bus.md` | docs | 63 |
| `docs/internals/lane-calibration.md` | docs | 90, 91, 96, 102, 122, 123, 126, 146, 149, 654, 664, 957, 962, 1004 |
| `docs/release/v1.1.2-notes.md` | docs | 74 |
| `docs/setup/settings-template.json` | docs | 140 |
| `docs/tooling-catalog.md` | docs | 794, 795, 1230 |
| `marketplace/plugins/himmel-bus/README.md` | docs | 58, 72 |
| `scripts/ci/check-run-timelines/testdata/sweep-6122/run-39029239710.json` | config | 1 |
| `scripts/ci/check-run-timelines/testdata/sweep-6122/run-39032362864.json` | config | 1 |
| `scripts/ci/test-escape-report-fixtures/pr-HIMMEL-6957.json` | test | 1 |
| `scripts/config-ui/tests/tool-health.test.ts` | test | 209, 212, 218, 219, 220, 224, 226, 248, 252, 261, 270 |
| `scripts/cr/pr-check-ref/00-preamble.md` | docs | 19 |
| `scripts/eval/graphify-ab/test-graphify-ab.sh` | test | 25, 26, 43, 98 |
| `scripts/eval/leg-digest/fixtures/profiles/eval-runs.jsonl` | fixture | 1, 2 |
| `scripts/eval/leg-digest/fixtures/profiles/listing.json` | fixture | 1 |
| `scripts/eval/leg-digest/test-leg-digest.sh` | test | 212, 224, 225, 226, 227, 228, 229 |
| `scripts/eval/leg-digest/test-leg-ledger.sh` | test | 194, 195, 203, 208 |
| `scripts/handover/arm-resume.sh` | code | 401 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-2928.md` | fixture | 29 |
| `scripts/handover/console-kit/gen-briefs.py` | code | 415 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 166, 732, 786, 790, 800 |
| `scripts/handover/console-kit/test-brief-lint.sh` | test | 106, 112, 114, 116, 119, 121, 137, 140, 143, 161 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | test | 763, 780, 984, 987 |
| `scripts/handover/console-kit/test-gen-briefs.sh` | test | 86, 107, 233, 255, 274 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 13, 87, 90 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 119, 120, 370, 683, 684, 685, 686, 687, 688, 698, 700, 719, 720, 721, 723, 724, 725, 811, 812, 813, 869, 1143, 1146, 1147, 1148, 1149, 1150, 1170, 1208, 1314, 1423, 1465, 1509, 1567, 1605, 1621, 1638, 1655, 1677, 1681, 1683, 1691, 1700, 1701, 1702, 1703, 1704, 1705, 1706, 1809, 1835, 1853, 1873, 1894, 1913, 1930, 1954, 1975, 1976, 1979, 1994, 1995, 2010, 2012, 2014, 2040, 2197, 2301, 2309, 2313, 2317, 2322, 2327, 2331, 2341, 2348, 2354, 2360, 2366, 2372, 2381, 2390, 2397, 2403, 2407, 2436, 2458, 2508, 2533, 2651, 2654, 2664, 2665, 2667, 2668, 2669, 2671, 2695, 2704, 2713, 2718, 2791, 2796, 2799, 2800, 2801, 2840, 2885, 2989, 3035, 3042, 3050, 3058, 3065, 3073, 3082, 3103, 3108, 3112, 3170, 3188, 3190, 3193, 3206, 3222, 3239, 3250, 3269, 3275, 3542, 3577, 4577, 4625, 4638, 4648, 4654, 4662, 4663, 4664, 4666, 4667, 4668, 4669 |
| `scripts/handover/console/test-console.sh` | test | 1876 |
| `scripts/handover/hop.sh` | code | 198, 209 |
| `scripts/handover/test-arm-resume-profile.sh` | test | 61, 67, 81, 101 |
| `scripts/handover/test-headed-arm.sh` | test | 422 |
| `scripts/handover/test-hop.sh` | test | 64, 80 |
| `scripts/hooks/read-clamp.sh` | code | 5, 16 |
| `scripts/hooks/test-graphify-freshness-advisory.sh` | test | 6 |
| `scripts/hooks/test-inject-where-are-we.sh` | test | 16 |
| `scripts/hooks/test-qmd-staleness-notice.sh` | test | 20 |
| `scripts/lanes/bench/scorecard/agg-postpin.sh` | code | 21, 125 |
| `scripts/lanes/bench/scorecard/fixtures/cohort-nscheme/cache/launch-logs/HIMMEL-9101-N901-fixture-single.log` | fixture | 1 |
| `scripts/lanes/bench/scorecard/fixtures/cohort-nscheme/cache/launch-logs/HIMMEL-9102-N902-fixture-agree.log` | fixture | 1, 2 |
| `scripts/lanes/bench/scorecard/fixtures/cohort-nscheme/cache/launch-logs/HIMMEL-9103-N903-fixture-ambiguous.log` | fixture | 1 |
| `scripts/lanes/bench/scorecard/fixtures/cohort-substring/launch-logs/HIMMEL-9007-fixture-legN907-2026-09-06.log` | fixture | 1 |
| `scripts/lanes/bench/scorecard/fixtures/cohort/launch-logs/HIMMEL-9004-fixture-legN904-2026-09-06.log` | fixture | 1 |
| `scripts/lanes/bench/scorecard/test-scorecard.sh` | test | 53, 61, 62, 66, 67, 72, 73, 79, 80, 81, 92, 101, 106 |
| `scripts/lanes/lane-canary.sh` | code | 140 |
| `scripts/lanes/plugin-profiles.json` | config | 4, 50, 150, 279, 309, 322, 326, 334, 339, 351, 421 |
| `scripts/lanes/plugin-profiles.mjs` | code | 79, 87, 266, 267, 470 |
| `scripts/lanes/role-profile.sh` | code | 9, 26 |
| `scripts/lanes/role-requires.mjs` | code | 29, 30, 32 |
| `scripts/lanes/test-leg-pr-open.sh` | test | 338, 351 |
| `scripts/lanes/tests/fixtures/profile-manifests.json` | fixture | 145, 154, 163 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 31, 99, 162, 163, 297, 307, 610, 631, 900, 905, 1079, 1087, 1091, 1103, 1106, 1115, 1308, 1348, 1366, 1418, 1425, 1429, 1437, 1526, 1532, 1533, 1580, 1593, 1623, 1640, 1647, 1653, 1729, 1733, 1739, 1740, 1741, 1742, 1844, 1845, 1846, 1882, 1889, 1890, 1895, 1899, 1917, 1926, 1946, 1966, 1976, 1978, 1979, 1980, 1981, 1982, 1986, 1987, 2006, 2008, 2014, 2039, 2052, 2055, 2112, 2129, 2132 |
| `scripts/lanes/tests/profile-context-ceiling.test.mjs` | test | 16, 44, 45, 47, 49, 53, 60, 65, 79, 86, 95 |
| `scripts/lanes/tests/profile-context-probe.test.mjs` | test | 578, 584, 586, 592, 593 |
| `scripts/lanes/tests/profile-lists.test.mjs` | test | 47 |
| `scripts/lanes/tests/pstack-plugin.test.mjs` | test | 36 |
| `scripts/lanes/tests/test-leg-burn.sh` | test | 82, 83, 84, 86, 87, 88, 89 |
| `scripts/telegram/break-glass.sh` | code | 392 |
| `scripts/testing/test-fakekey-claude-startup.sh` | test | 69, 99 |
| `scripts/vm/launch-guest.sh` | code | 5 |

### N07 `CADENCE_BANK_*` to `CADENCE_USAGE_*`

Family F3, slice V1; env var; owner HIMMEL-6647 (V1 HIMMEL-6639 Done); 334 lines in 69 files; new name live 13/13; 1 without a ruled name. the bare CADENCE_BANK has no ruled name (registry: pending-N2892); the registry's new name for CADENCE_BANK_LEG, CADENCE_USAGE_LEG, still holds LEG. <!-- old-term-ok: this page inventories the old names -->

Distinct matched strings (14): `CADENCE_BANK` (no ruled name), `CADENCE_BANK_` to `CADENCE_USAGE_` (live), `CADENCE_BANK_CACHE` to `CADENCE_USAGE_CACHE` (live), `CADENCE_BANK_CALLER_PID` to `CADENCE_USAGE_CALLER_PID` (live), `CADENCE_BANK_CODEX_TIMEOUT` to `CADENCE_USAGE_CODEX_TIMEOUT` (live), `CADENCE_BANK_LANE` to `CADENCE_USAGE_LANE` (live), `CADENCE_BANK_LAUNCH` to `CADENCE_USAGE_LAUNCH` (live), `CADENCE_BANK_LEDGER` to `CADENCE_USAGE_LEDGER` (live), `CADENCE_BANK_LEG` to `CADENCE_USAGE_LEG` (live), `CADENCE_BANK_MAX_AGE` to `CADENCE_USAGE_MAX_AGE` (live), `CADENCE_BANK_MAX_PCT` to `CADENCE_USAGE_MAX_PCT` (live), `CADENCE_BANK_PRODUCER` to `CADENCE_USAGE_PRODUCER` (live), `CADENCE_BANK_SKIP_REFRESH` to `CADENCE_USAGE_SKIP_REFRESH` (live), `CADENCE_BANK_STATUS_CMD` to `CADENCE_USAGE_STATUS_CMD` (live)

| File | Class | Lines |
|---|---|---|
| `scripts/api-lane/bulk-call.test.mjs` | test | 71, 72, 73 |
| `scripts/api-lane/claude-api.test.mjs` | test | 76, 77, 78, 211, 657 |
| `scripts/api-lane/judge-call.test.mjs` | test | 74, 75, 76 |
| `scripts/codex/test-hook-smoke-demo.sh` | test | 179, 180, 181, 182 |
| `scripts/config-ui/README.md` | docs | 57 |
| `scripts/config-ui/actions.ts` | code | 44, 77 |
| `scripts/config-ui/health-sources.ts` | code | 25 |
| `scripts/config-ui/quota-sources.ts` | code | 56, 57 |
| `scripts/config-ui/tests/bank-route.test.ts` | test | 28, 29, 62, 121 |
| `scripts/config-ui/tests/e2e/agui-fixtures.ts` | test | 121 |
| `scripts/config-ui/tests/e2e/fixtures.ts` | test | 131 |
| `scripts/config-ui/tests/health-route.test.ts` | test | 48, 52, 56, 60 |
| `scripts/cr/test-claude-floor-review.sh` | test | 34 |
| `scripts/cr/test-critic-first-pass-claude.sh` | test | 29 |
| `scripts/cr/test-hermes-critic.sh` | test | 173, 174, 261 |
| `scripts/graphify/test-refresh-graph-map-resume.sh` | test | 27, 28 |
| `scripts/graphify/test-refresh-graph-map.sh` | test | 44, 45, 3038, 3401, 3402, 4214, 4217, 4218 |
| `scripts/handover/arm-resume.sh` | code | 1365 |
| `scripts/handover/console-kit/console-wait.sh` | code | 388 |
| `scripts/handover/console-kit/handoff-facts.sh` | code | 67 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 636, 1674, 1678, 1681 |
| `scripts/handover/console-kit/test-console-kit-e2e.sh` | test | 68, 69 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 159, 160 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 22 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 130, 236, 291, 990, 1108, 1113, 1116, 1118, 1121, 1156, 1164, 1188, 1357, 1360 |
| `scripts/handover/console-kit/test-tick.sh` | test | 175, 2283, 2285, 2287 |
| `scripts/handover/console-kit/tick.sh` | code | 2103, 2106 |
| `scripts/handover/test-arm-resume-at-pty.sh` | test | 29 |
| `scripts/handover/test-arm-resume-bank-refresh.sh` | test | 15, 134, 135, 136, 137 |
| `scripts/handover/test-arm-resume-base.sh` | test | 40 |
| `scripts/handover/test-arm-resume-cron.sh` | test | 104 |
| `scripts/handover/test-arm-resume-identity.sh` | test | 93, 136 |
| `scripts/handover/test-arm-resume-long-gap.sh` | test | 38 |
| `scripts/handover/test-arm-resume-profile.sh` | test | 18 |
| `scripts/handover/test-arm-resume-proxy.sh` | test | 43 |
| `scripts/handover/test-arm-resume-queue-lock.sh` | test | 42, 80 |
| `scripts/handover/test-arm-resume-seam-scrub.sh` | test | 27 |
| `scripts/handover/test-arm-resume-source-key.sh` | test | 35, 78 |
| `scripts/handover/test-arm-resume.sh` | test | 261, 268, 270, 6625 |
| `scripts/handover/test-worker-lifecycle.sh` | test | 53, 132 |
| `scripts/hooks/auto-arm-on-cap.sh` | code | 664, 674 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel3148.sh` | fixture | 176 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel4567.sh` | fixture | 180 |
| `scripts/hooks/guard-implementor-dispatch.sh` | code | 753, 766, 768 |
| `scripts/hooks/test-auto-arm-on-cap.sh` | test | 1146, 1202, 1206, 1207, 1208 |
| `scripts/hooks/test-guard-implementor-dispatch.sh` | test | 285, 740, 914, 915, 917, 918, 945, 954, 956, 957, 958, 959, 961 |
| `scripts/lib/api-credit-state.test.mjs` | test | 59, 60, 61, 62, 73, 74, 75, 76, 84, 93, 335, 336, 337, 389 |
| `scripts/lib/chief-context.sh` | code | 226 |
| `scripts/lib/claude-headless.sh` | code | 73, 595 |
| `scripts/lib/rename-aliases.tsv` | config | 27, 41, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107 |
| `scripts/lib/test-bank-preflight-admit-gate.sh` | test | 366, 367, 437, 438, 439, 682, 683, 707, 708 |
| `scripts/lib/test-bank-preflight-dead-owner.sh` | test | 36 |
| `scripts/lib/test-bank-preflight-dotenv-root.sh` | test | 58, 59 |
| `scripts/lib/test-bank-preflight-fleet.sh` | test | 72, 81, 82, 101, 103, 123, 176, 179, 180, 196, 199, 220, 255, 288, 308, 322, 323, 352, 367, 389, 531, 559, 571, 706, 714, 730, 745, 748, 756, 759, 772 |
| `scripts/lib/test-bank-preflight-openrouter.sh` | test | 26, 38 |
| `scripts/lib/test-bank-preflight.sh` | test | 9, 11, 12, 54, 55, 82, 84, 86, 89, 92, 97, 105, 106, 193, 194, 204, 205, 235, 236, 244, 245, 302, 306, 313, 325, 326, 327, 473, 474, 475, 534, 539, 552, 554, 564, 565, 566, 588, 591, 594, 605, 606, 607, 608, 613, 621, 622, 623, 666, 673, 690, 691, 692, 708, 709, 710, 715, 716, 717, 720, 730, 780, 781, 796, 889, 890, 891, 893, 1033, 1034, 1035, 1040, 1047, 1051, 1052, 1053, 1054, 1055, 1057, 1059, 1060, 1061, 1068, 1072, 1075, 1078 |
| `scripts/lib/test-claude-headless-live.sh` | test | 20 |
| `scripts/lib/test-claude-headless-trap.sh` | test | 89, 90, 91 |
| `scripts/lib/test-claude-headless.sh` | test | 13, 32, 36, 37, 38 |
| `scripts/lib/test-fleet-reservation-key.sh` | test | 57, 58, 59 |
| `scripts/lib/test-override-env.sh` | test | 257 |
| `scripts/lib/test-rename-aliases.sh` | test | 33, 41, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148 |
| `scripts/lib/usage-lift.sh` | code | 56 |
| `scripts/lib/usage-preflight.sh` | code | 41, 49, 51 |
| `scripts/luna/test-pipeline-cadence.sh` | test | 153, 154, 155 |
| `scripts/statusline/test-usage-cache-contract.sh` | test | 19, 226, 236, 252, 304 |
| `scripts/statusline/test-usage-cache-producer.sh` | test | 331, 332 |
| `scripts/test-himmel-doctor.sh` | test | 4198, 4201, 4206 |
| `scripts/testing/test-claude-mock-turn.sh` | test | 215, 216 |

### N08 `BANK_LIFT_*` to `USAGE_LIFT_*`

Family F3, slice V1; env var; owner HIMMEL-6647 (V1 HIMMEL-6639 Done); 39 lines in 10 files; new name live 6/6.

Distinct matched strings (6): `BANK_LIFT_` to `USAGE_LIFT_` (live), `BANK_LIFT_BIN` to `USAGE_LIFT_BIN` (live), `BANK_LIFT_FILE` to `USAGE_LIFT_FILE` (live), `BANK_LIFT_REASON` to `USAGE_LIFT_REASON` (live), `BANK_LIFT_STANDING` to `USAGE_LIFT_STANDING` (live), `BANK_LIFT_STUB_OUT` to `USAGE_LIFT_STUB_OUT` (live)

| File | Class | Lines |
|---|---|---|
| `docs/internals/enforcement.md` | docs | 2410 |
| `scripts/chokepoints.json` | config | 21, 24 |
| `scripts/hooks/test-auto-arm-on-cap.sh` | test | 1146 |
| `scripts/hooks/test-block-chokepoint-env-prefix.sh` | test | 116, 118 |
| `scripts/lib/bank-lift.sh` | code | 5, 23, 25 |
| `scripts/lib/rename-aliases.tsv` | config | 42, 74, 75, 76, 77, 78 |
| `scripts/lib/test-bank-preflight.sh` | test | 30, 934, 936, 953, 954, 957, 962, 965, 972, 974, 976, 977, 980, 981 |
| `scripts/lib/test-rename-aliases.sh` | test | 42, 112, 113, 114, 115, 116 |
| `scripts/lib/usage-lift.sh` | code | 19, 29 |
| `scripts/test-himmel-doctor.sh` | test | 75, 4206 |

### N09 `CODEX_BANK_*` to `CODEX_USAGE_*`

Family F3, slice V1; env var; owner HIMMEL-6647 (V1 HIMMEL-6639 Done); 114 lines in 18 files; new name live 7/7; 3 without a ruled name.

Distinct matched strings (10): `CODEX_BANK_` to `CODEX_USAGE_` (live), `CODEX_BANK_CACHE` to `CODEX_USAGE_CACHE` (live), `CODEX_BANK_CACHE_TTL_DEFAULT_SECONDS` (no ruled name), `CODEX_BANK_CACHE_TTL_SECONDS` to `CODEX_USAGE_CACHE_TTL_SECONDS` (live), `CODEX_BANK_PROBE_CMD` to `CODEX_USAGE_PROBE_CMD` (live), `CODEX_BANK_PROBE_REMEDY` (no ruled name), `CODEX_BANK_PROBE_TIMEOUT_MS` to `CODEX_USAGE_PROBE_TIMEOUT_MS` (live), `CODEX_BANK_REFRESH_BACKOFF_MS` to `CODEX_USAGE_REFRESH_BACKOFF_MS` (live), `CODEX_BANK_REFRESH_BOX_MS` to `CODEX_USAGE_REFRESH_BOX_MS` (live), `CODEX_BANK_TTL_DEFAULT_SECONDS` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `scripts/config-ui/README.md` | docs | 58 |
| `scripts/config-ui/agui/fleet.ts` | code | 313, 316 |
| `scripts/config-ui/quota-sources.ts` | code | 71, 72 |
| `scripts/config-ui/tests/agui-fleet.test.ts` | test | 395, 399, 408, 417 |
| `scripts/config-ui/tests/bank-route.test.ts` | test | 25, 26, 27, 57, 120, 121 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 3216 |
| `scripts/himmel-doctor.sh` | code | 4051, 4052 |
| `scripts/lanes/bank-status-core.mjs` | code | 6, 58 |
| `scripts/lanes/codex-usage-probe.ts` | code | 37, 38, 39, 42 |
| `scripts/lanes/tests/bank-status.test.mjs` | test | 110, 122, 160, 185, 205, 391, 409, 424, 442, 472, 542, 566, 571, 576, 583, 591, 599, 600, 602, 612, 617, 630, 646, 647, 648, 657, 659 |
| `scripts/lanes/tests/bench-run-batch.test.mjs` | test | 52, 147, 182, 188 |
| `scripts/lanes/tests/codex-bank-probe.test.mjs` | test | 4, 15, 178, 186, 253, 259, 271, 286, 298, 299, 313, 314, 349, 350, 353 |
| `scripts/lanes/usage-status.ts` | code | 25, 26, 75, 91, 96, 98, 153, 155, 163, 220, 227 |
| `scripts/lib/rename-aliases.tsv` | config | 43, 117, 118, 119, 120, 121, 122, 123, 124, 125 |
| `scripts/lib/test-rename-aliases.sh` | test | 43, 149, 150, 151, 152, 153, 154 |
| `scripts/telegram/spawn-claudex.test.ts` | test | 1138, 1140, 1143, 1144 |
| `scripts/telegram/spawn-claudex.ts` | code | 51, 448, 451, 462, 470, 480, 515 |
| `scripts/test-himmel-doctor.sh` | test | 211, 6564, 6578, 6587, 6590 |

### N10 `CLAUDEX_BANK_*` to `CLAUDEX_USAGE_*`

Family F3, slice V1; env var; owner HIMMEL-6647 (V1 HIMMEL-6639 Done); 36 lines in 8 files; new name live 3/4.

Distinct matched strings (4): `CLAUDEX_BANK_` to `CLAUDEX_USAGE_`, `CLAUDEX_BANK_OK` to `CLAUDEX_USAGE_OK` (live), `CLAUDEX_BANK_REFUSE_PCT` to `CLAUDEX_USAGE_REFUSE_PCT` (live), `CLAUDEX_BANK_WARN_PCT` to `CLAUDEX_USAGE_WARN_PCT` (live)

| File | Class | Lines |
|---|---|---|
| `.env.example` | config | 521 |
| `docs/configuration.md` | docs | 786 |
| `scripts/lanes/funded-max-pct.mjs` | code | 27, 32 |
| `scripts/lanes/tests/funded-max-pct.test.mjs` | test | 44, 47, 49, 51, 52, 57, 58, 59, 72, 75 |
| `scripts/lib/rename-aliases.tsv` | config | 28, 29, 30, 44 |
| `scripts/lib/test-rename-aliases.sh` | test | 44, 132, 133, 134 |
| `scripts/telegram/spawn-claudex.test.ts` | test | 1147, 1150, 1151, 1152, 1153, 1154, 1159, 1161, 1162, 1163 |
| `scripts/telegram/spawn-claudex.ts` | code | 491, 494, 498, 500 |

### N11 `PARKED-BANK` to `PARKED-USAGE`

Family F3, slice V1; id (marker token); owner HIMMEL-6647 (V1 HIMMEL-6639 Done); 61 lines in 29 files; new name live 1/1. marker token the tick parses; written handover docs also carry it.

Distinct matched strings (1): `PARKED-BANK` to `PARKED-USAGE` (live)

| File | Class | Lines |
|---|---|---|
| `docs/guide/dev-graph/graph.json` | docs | 1943 |
| `docs/handover/leg-preface.md` | docs | 29 |
| `marketplace/plugins/himmel-bus/lib/agui.mjs` | code | 13 |
| `marketplace/plugins/himmel-bus/tests/test-agui.mjs` | test | 144 |
| `scripts/config-ui/agui-web/src/Fleet.tsx` | code | 42 |
| `scripts/config-ui/roadmap.ts` | code | 17 |
| `scripts/config-ui/tests/roadmap.test.ts` | test | 149 |
| `scripts/handover/console-kit/append-results.sh` | code | 83, 85, 113 |
| `scripts/handover/console-kit/board.mjs` | code | 439 |
| `scripts/handover/console-kit/console-wait.sh` | code | 921 |
| `scripts/handover/console-kit/fixtures/doc-reader-agreement/gen.py` | fixture | 28, 154, 155, 191 |
| `scripts/handover/console-kit/next-dispatchable.sh` | code | 137 |
| `scripts/handover/console-kit/test-append-results.sh` | test | 103, 106, 107, 108, 154 |
| `scripts/handover/console-kit/test-board.sh` | test | 281 |
| `scripts/handover/console-kit/test-tick.sh` | test | 1681 |
| `scripts/handover/console-kit/tracker.py` | code | 84 |
| `scripts/handover/console-kit/version-status-audit.sh` | code | 103 |
| `scripts/lib/env-alias.sh` | code | 35 |
| `scripts/lib/fixtures/status-marker-rows.tsv` | fixture | 15, 17, 19, 31, 33 |
| `scripts/lib/leg-tail-status.sh` | code | 13, 44 |
| `scripts/lib/rename-aliases.tsv` | config | 38 |
| `scripts/lib/status-marker.mjs` | code | 6, 8, 14, 19, 23 |
| `scripts/lib/status-marker.sh` | code | 3, 7, 10, 20, 23, 30 |
| `scripts/lib/status-marker.test.mjs` | test | 46, 48, 55 |
| `scripts/lib/status_marker.py` | code | 8, 9, 19, 29, 33 |
| `scripts/lib/test-rename-aliases.sh` | test | 39 |
| `scripts/lib/test-status-marker.sh` | test | 65, 68 |
| `scripts/lib/test-status_marker.py` | test | 67, 69, 73 |
| `scripts/lib/ticket-status.sh` | code | 265 |

### N12 `bank-preflight.sh, bank-lift.sh (+ bank-lift.json), bank-monitor.sh, bank-attribution.sh, bank-status*, codex-bank-probe.ts` to `usage-preflight.sh, usage-lift.sh (+ usage-lift.json), usage-monitor.sh, usage-attribution.sh, usage-status*, codex-usage-probe.ts`

Family F4, slice V1; script/file name, command; owner HIMMEL-6647 (V1 HIMMEL-6639 Done); 794 lines in 230 files; new name live 12/37; 32 without a ruled name. a longer name that only contains one of these (`test-bank-preflight.sh`, `block-bank-lift-writes.sh`) has no ruled name unless its usage- twin exists.

Distinct matched strings (69): `-bank-preflight` (no ruled name), `bank-attribution` to `usage-attribution`, `bank-attribution.XXXXXX` to `usage-attribution.XXXXXX`, `bank-attribution.sh` to `usage-attribution.sh` (live), `bank-lift` to `usage-lift` (live), `bank-lift-show.txt` to `usage-lift-show.txt`, `bank-lift-write` to `usage-lift-write`, `bank-lift.js` to `usage-lift.js`, `bank-lift.json` to `usage-lift.json` (live), `bank-lift.json.bak` to `usage-lift.json.bak` (live), `bank-lift.sh` to `usage-lift.sh` (live), `bank-monitor` to `usage-monitor`, `bank-monitor-test.XXXXXX` to `usage-monitor-test.XXXXXX`, `bank-monitor.sh` to `usage-monitor.sh` (live), `bank-monitor.state` to `usage-monitor.state`, `bank-preflight` to `usage-preflight` (live), `bank-preflight-admit-gate.XXXXXX` to `usage-preflight-admit-gate.XXXXXX`, `bank-preflight-dotenv-root.XXXXXX` to `usage-preflight-dotenv-root.XXXXXX`, `bank-preflight-fleet.XXXXXX` to `usage-preflight-fleet.XXXXXX`, `bank-preflight-refusal` to `usage-preflight-refusal`, `bank-preflight-stub.sh` to `usage-preflight-stub.sh`, `bank-preflight.XXXXXX` to `usage-preflight.XXXXXX`, `bank-preflight.md` to `usage-preflight.md`, `bank-preflight.sh` to `usage-preflight.sh` (live), `bank-preflighted` to `usage-preflighted`, `bank-preflights` to `usage-preflights`, `bank-status` to `usage-status` (live), `bank-status-core` to `usage-status-core`, `bank-status-core.mjs` to `usage-status-core.mjs`, `bank-status.sh` to `usage-status.sh`, `bank-status.test.mjs` to `usage-status.test.mjs`, `bank-status.ts` to `usage-status.ts` (live), `block-bank-lift-writes` (no ruled name), `block-bank-lift-writes.sh` (no ruled name), `codex-bank-probe` to `codex-usage-probe` (live), `codex-bank-probe-core.mjs` to `codex-usage-probe-core.mjs`, `codex-bank-probe-ok-` to `codex-usage-probe-ok-`, `codex-bank-probe-to-` to `codex-usage-probe-to-`, `codex-bank-probe.test.mjs` to `codex-usage-probe.test.mjs`, `codex-bank-probe.ts` to `codex-usage-probe.ts` (live), `data-bank-lift` (no ruled name), `himmel-bank-monitor-` (no ruled name), `himmel-bank-status.XXXXXX` (no ruled name), `himmel-codex-bank-probe` (no ruled name), `nbank-lift` (no ruled name), `skipped-bank-preflight.sh` (no ruled name), `test-bank-attribution-2.XXXXXX` (no ruled name), `test-bank-attribution-3.XXXXXX` (no ruled name), `test-bank-attribution-4.XXXXXX` (no ruled name), `test-bank-attribution-5.XXXXXX` (no ruled name), `test-bank-attribution-bad.XXXXXX` (no ruled name), `test-bank-attribution-top-neg.XXXXXX` (no ruled name), `test-bank-attribution.XXXXXX` (no ruled name), `test-bank-attribution.sh` (no ruled name), `test-bank-lift.sh` (no ruled name), `test-bank-monitor.sh` (no ruled name), `test-bank-preflight` (no ruled name), `test-bank-preflight-admit-gate.sh` (no ruled name), `test-bank-preflight-dead-owner` (no ruled name), `test-bank-preflight-dead-owner.sh` (no ruled name), `test-bank-preflight-dotenv-root.sh` (no ruled name), `test-bank-preflight-fleet.sh` (no ruled name), `test-bank-preflight-openrouter` (no ruled name), `test-bank-preflight-openrouter.sh` (no ruled name), `test-bank-preflight.sh` (no ruled name), `test-block-bank-lift-writes.sh` (no ruled name), `uuid-bank-monitor-DIFFERENT` (no ruled name), `uuid-bank-monitor-test` (no ruled name), `uuid-bank-preflight-test` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.agents/skills/pr-check/SKILL.md` | docs | 187, 188, 189 |
| `.claude/commands/handover-arm-resume.md` | docs | 23 |
| `.claude/commands/plugin-eval.md` | docs | 2, 21, 63 |
| `.claude/settings.json` | config | 89, 227, 257 |
| `.codex/hooks.json` | config | 9, 29 |
| `.env.example` | config | 486, 523, 525 |
| `AGENTS.md` | docs | 98 |
| `CLAUDE.md` | docs | 31 |
| `docs/adoption-trail.html` | docs | 820 |
| `docs/cadences.md` | docs | 59 |
| `docs/commands-catalog.md` | docs | 252 |
| `docs/configuration.md` | docs | 786 |
| `docs/handover/console-sections/monitors.md` | docs | 62 |
| `docs/handover/console-sections/release-manager.md` | docs | 14, 29 |
| `docs/handover/console-sections/waiter.md` | docs | 40 |
| `docs/handover/running-a-console.md` | docs | 585 |
| `docs/hermes-runbook.md` | docs | 11, 203 |
| `docs/internals/claude-md-detail.md` | docs | 33 |
| `docs/internals/egress-matrix.md` | docs | 126 |
| `docs/internals/enforcement.md` | docs | 2400, 2403, 2410, 2417, 2422, 2424, 2428, 2445, 2446, 2450, 2451, 2453, 2455, 2458, 2468, 2474, 2564, 2585, 2591, 2595, 2596, 2597, 2598, 2607, 2612, 2614, 2618, 3802, 4899, 4906, 5727, 5739, 5768, 5782, 5789 |
| `docs/internals/harness-compat.md` | docs | 99 |
| `docs/internals/headless-modes.md` | docs | 38 |
| `docs/internals/lane-calibration.md` | docs | 35, 374, 547, 827, 873, 874, 1022, 1087 |
| `docs/internals/testing.md` | docs | 488 |
| `docs/internals/usage-records.md` | docs | 11, 92 |
| `docs/release/v1.1.2-notes.md` | docs | 32 |
| `docs/tooling-catalog.md` | docs | 1142, 1197, 1626, 1644 |
| `marketplace/plugins/himmel-ops/hooks/run-hook-with-bash.js` | code | 328, 329 |
| `marketplace/plugins/qmd/evals/collections-scoping/prompt.md` | docs | 7 |
| `marketplace/plugins/qmd/evals/mocks/qmd/query.md` | docs | 5 |
| `scripts/adopt.sh` | code | 225 |
| `scripts/api-lane/claude-api.sh` | code | 143 |
| `scripts/api-lane/claude-api.test.mjs` | test | 42 |
| `scripts/chokepoints.json` | config | 23 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 141, 142 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 64, 132 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 65, 114 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 40, 182 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 477, 478, 479, 480, 481, 482 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 55 |
| `scripts/ci/suite-durations.tsv` | config | 564, 756, 757, 758, 759, 760, 761, 762, 763 |
| `scripts/ci/suite-tiers.tsv` | config | 565, 757, 758, 759, 760, 761, 762, 763, 764 |
| `scripts/ci/test-os-verify-workflow.sh` | test | 275 |
| `scripts/ci/test-run-shell-tests.sh` | test | 2564 |
| `scripts/ci/tmp-sweep.sh` | code | 171, 172 |
| `scripts/claude-codex` | code | 898, 899 |
| `scripts/cleanup/steering-cull-cadence.sh` | code | 40, 43, 118, 123 |
| `scripts/cleanup/test-steering-cull-cadence.sh` | test | 95 |
| `scripts/config-ui/README.md` | docs | 40, 52 |
| `scripts/config-ui/agui/lane.ts` | code | 8 |
| `scripts/config-ui/health-sources.ts` | code | 4, 37, 46 |
| `scripts/config-ui/public/health.js` | code | 87, 88, 110, 158 |
| `scripts/config-ui/quota-sources.ts` | code | 2, 3, 8, 82 |
| `scripts/config-ui/server.ts` | code | 486 |
| `scripts/config-ui/tests/bank-route.test.ts` | test | 1 |
| `scripts/config-ui/tests/e2e/config-ui.e2e.ts` | test | 321 |
| `scripts/cr/claude-floor-review.sh` | code | 2 |
| `scripts/cr/critic-first-pass.sh` | code | 2 |
| `scripts/cr/critics.json` | config | 2 |
| `scripts/cr/hermes-critic.sh` | code | 2, 42 |
| `scripts/cr/impacted-suites.sh` | code | 651 |
| `scripts/cr/pr-check-context.sh` | code | 742, 743, 800, 827 |
| `scripts/cr/pr-check-ref/10-step0.md` | docs | 23, 24, 25 |
| `scripts/cr/pr-check-ref/32-step3-reviewers.md` | docs | 11 |
| `scripts/cr/test-claude-floor-review.sh` | test | 24 |
| `scripts/cr/test-cr-guarded-closure.sh` | test | 115 |
| `scripts/cr/test-critic-first-pass-claude.sh` | test | 18 |
| `scripts/cr/test-hermes-critic.sh` | test | 155, 160 |
| `scripts/cr/test-impacted-suites.sh` | test | 761 |
| `scripts/cr/test-pr-check-context.sh` | test | 383, 2020, 2021, 2022, 2365 |
| `scripts/cr/test-pr-check-pair.sh` | test | 169, 170, 171, 233, 255, 442, 929 |
| `scripts/eval/friction/friction.py` | code | 70, 220 |
| `scripts/eval/graphify-ab/run.sh` | code | 14, 121, 135 |
| `scripts/eval/graphify-ab/test-graphify-ab.sh` | test | 4, 81 |
| `scripts/eval/lane-quality/pilot-4869/test-pilot.sh` | test | 65 |
| `scripts/eval/lane-quality/run.sh` | code | 232, 319, 633 |
| `scripts/eval/lane-quality/test-lane-quality.sh` | test | 115 |
| `scripts/eval/mcp-tasks-probe/probe.sh` | code | 19 |
| `scripts/eval/retrieval-eval/answer-ab.py` | code | 31, 131, 141 |
| `scripts/eval/retrieval-eval/questions.jsonl` | code | 18 |
| `scripts/eval/retrieval-eval/test-answer-ab.sh` | test | 96 |
| `scripts/eval/review-panel/README.md` | docs | 25 |
| `scripts/graphify/refresh-graph-map.sh` | code | 2262, 2283 |
| `scripts/graphify/semantic-update.sh` | code | 15, 26, 78, 362, 368 |
| `scripts/graphify/test-quality-sample.sh` | test | 92 |
| `scripts/graphify/test-refresh-graph-map-lock.sh` | test | 27 |
| `scripts/graphify/test-refresh-graph-map.sh` | test | 39 |
| `scripts/graphify/test-semantic-update.sh` | test | 5, 88, 338, 345, 423 |
| `scripts/guardrails/lint-fail-open.sh` | code | 508 |
| `scripts/handover/arm-resume.sh` | code | 1244, 1350, 1367 |
| `scripts/handover/console-kit/board.mjs` | code | 577, 590, 594 |
| `scripts/handover/console-kit/console-wait.sh` | code | 21, 128, 380 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-1625.md` | fixture | 20 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5497.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5779.md` | fixture | 29 |
| `scripts/handover/console-kit/fleet.mjs` | code | 428 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 69, 70, 636, 640, 1673, 2419, 2425, 2441, 2444, 2468 |
| `scripts/handover/console-kit/ready-check.sh` | code | 433 |
| `scripts/handover/console-kit/test-action-zero.sh` | test | 3 |
| `scripts/handover/console-kit/test-board.sh` | test | 915, 919, 923, 927, 931, 935, 937, 938, 939, 940, 941, 942, 943, 945, 947, 949, 951, 952, 954 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 171 |
| `scripts/handover/console-kit/test-fleet.sh` | test | 6, 179, 180 |
| `scripts/handover/console-kit/test-handoff-facts.sh` | test | 61 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 38, 40, 46, 49, 161, 275, 277, 295, 297, 2413 |
| `scripts/handover/console-kit/test-ready-check.sh` | test | 1084 |
| `scripts/handover/console-kit/test-tick-busedge.sh` | test | 47 |
| `scripts/handover/console-kit/test-tick-deadwin.sh` | test | 49 |
| `scripts/handover/console-kit/test-tick-holds.sh` | test | 53 |
| `scripts/handover/console-kit/test-tick-nolive.sh` | test | 49 |
| `scripts/handover/console-kit/test-tick.sh` | test | 451, 1074, 1084, 1086, 1087, 1088, 1089, 1090, 1101, 2272, 2275, 2278, 2280, 2287, 2291 |
| `scripts/handover/console-kit/tick.sh` | code | 2101, 2110, 2138 |
| `scripts/handover/console/chief.sh` | code | 97 |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` | test | 30 |
| `scripts/handover/console/test-console.sh` | test | 67, 1805 |
| `scripts/handover/headed-arm.sh` | code | 242 |
| `scripts/handover/hop.sh` | code | 82 |
| `scripts/handover/leg-timeline.sh` | code | 63 |
| `scripts/handover/test-arm-resume-at-pty.sh` | test | 28 |
| `scripts/handover/test-arm-resume-bank-refresh.sh` | test | 7, 139 |
| `scripts/handover/test-arm-resume-base.sh` | test | 39 |
| `scripts/handover/test-arm-resume-cron.sh` | test | 102, 621, 626 |
| `scripts/handover/test-arm-resume-identity.sh` | test | 79, 86, 92, 135, 862, 950 |
| `scripts/handover/test-arm-resume-long-gap.sh` | test | 26, 37 |
| `scripts/handover/test-arm-resume-proxy.sh` | test | 42 |
| `scripts/handover/test-arm-resume-queue-lock.sh` | test | 30, 41, 79 |
| `scripts/handover/test-arm-resume-source-key.sh` | test | 21, 28, 34, 77 |
| `scripts/handover/test-arm-resume.sh` | test | 258, 1553, 6624, 6634, 6637 |
| `scripts/handover/test-hop.sh` | test | 188 |
| `scripts/handover/test-leg-timeline.sh` | test | 416 |
| `scripts/handover/test-worker-lifecycle.sh` | test | 39, 46, 52, 131 |
| `scripts/himmel-doctor.sh` | code | 4046, 4047, 4054, 4072, 4078 |
| `scripts/himmelctl/test/test-wizard-config.sh` | test | 71, 467 |
| `scripts/hooks/auto-arm-on-cap.sh` | code | 661 |
| `scripts/hooks/block-bank-lift-writes.sh` | code | 5, 16, 44, 64, 66, 91, 195, 252 |
| `scripts/hooks/block-himmel-config-writes.sh` | code | 14, 127 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel3148.sh` | fixture | 54, 59, 67, 78, 178, 182, 183 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel4567.sh` | fixture | 58, 63, 71, 82, 182, 186, 187 |
| `scripts/hooks/guard-implementor-dispatch.sh` | code | 413, 446, 450, 464, 491, 493 |
| `scripts/hooks/run-hook-with-bash.js` | code | 328, 329 |
| `scripts/hooks/run-hook-with-bash.test.mjs` | test | 611 |
| `scripts/hooks/stop-console-idle-guard.sh` | code | 189, 193, 194 |
| `scripts/hooks/test-block-bank-lift-writes.sh` | test | 2, 3, 5, 22, 29, 32, 34, 36, 37, 66, 68, 82, 99, 100, 129, 130, 131, 132, 134, 135, 136, 137, 138, 139, 140, 141, 142, 144, 147, 154, 156, 157, 160, 161, 162, 163, 164, 181, 182, 186, 203, 215, 222, 223, 254, 255, 256, 258, 259, 260, 263, 265, 266, 268, 282, 283, 284, 289, 290, 291, 293, 296, 299, 300, 301, 302, 303, 305, 306, 307, 308, 309, 324, 325, 326, 327, 335, 336, 337, 338, 408, 409 |
| `scripts/hooks/test-block-chokepoint-env-prefix.sh` | test | 115, 116, 1480, 1483 |
| `scripts/hooks/test-block-read-secrets.sh` | test | 1153 |
| `scripts/hooks/test-crlf-boundary.sh` | test | 151, 152, 153, 177, 178 |
| `scripts/hooks/test-escape-class-corpus.sh` | test | 49 |
| `scripts/hooks/test-guard-implementor-dispatch.sh` | test | 48, 53, 60, 156 |
| `scripts/hooks/test-hook-construct-scaling.sh` | test | 57 |
| `scripts/hooks/test-stop-console-idle-guard.sh` | test | 92, 173 |
| `scripts/hooks/wire-hook-bash.mjs` | code | 79, 81, 127 |
| `scripts/jira/src/commands/release.ts` | code | 1, 245, 247 |
| `scripts/lanes/bank-status-core.mjs` | code | 4, 31 |
| `scripts/lanes/bank-status.ts` | code | 5 |
| `scripts/lanes/bench/bank-snapshot-core.mjs` | code | 4, 6, 7, 9, 16 |
| `scripts/lanes/bench/bank-snapshot.sh` | code | 18 |
| `scripts/lanes/bench/scorecard/fixtures/tool-usage/basic/leg-a.jsonl` | fixture | 3, 4 |
| `scripts/lanes/bench/scorecard/fixtures/tool-usage/chained/leg-a.jsonl` | fixture | 1 |
| `scripts/lanes/bench/scorecard/fixtures/tool-usage/partial-write/session-a.jsonl` | fixture | 1 |
| `scripts/lanes/bench/scorecard/test-tool-usage.sh` | test | 53, 187, 252 |
| `scripts/lanes/codex-bank-probe.ts` | code | 5 |
| `scripts/lanes/codex-usage-probe.ts` | code | 11, 16, 33, 73, 146, 181 |
| `scripts/lanes/funded-max-pct.mjs` | code | 3, 7 |
| `scripts/lanes/lane-readiness.mjs` | code | 5, 20 |
| `scripts/lanes/profile-context-probe.mjs` | code | 21, 548, 550, 552 |
| `scripts/lanes/resolve.mjs` | code | 11 |
| `scripts/lanes/tests/bank-status.test.mjs` | test | 15, 98, 117, 146, 167, 216, 377, 398, 417, 431, 496, 519, 563, 571, 589, 595, 605, 608, 622, 639, 651, 657 |
| `scripts/lanes/tests/bench-run-batch.test.mjs` | test | 28, 147 |
| `scripts/lanes/tests/codex-bank-probe.test.mjs` | test | 1, 5, 6, 14, 15, 22, 242, 276, 305, 341 |
| `scripts/lanes/tests/fixtures/codex-appserver-stub.mjs` | fixture | 2 |
| `scripts/lanes/tests/funded-max-pct.test.mjs` | test | 6, 10 |
| `scripts/lanes/tests/kill-tree.test.mjs` | test | 135 |
| `scripts/lanes/tests/resolve.test.mjs` | test | 721 |
| `scripts/lanes/tests/settings-allow.test.mjs` | test | 180 |
| `scripts/lanes/usage-status.ts` | code | 27, 80, 90, 149, 292 |
| `scripts/lib/bank-attribution.sh` | code | 4, 11 |
| `scripts/lib/bank-lift.sh` | code | 10 |
| `scripts/lib/bank-monitor.sh` | code | 4, 11 |
| `scripts/lib/bank-preflight.sh` | code | 5, 17, 20, 22 |
| `scripts/lib/cadence-format.sh` | code | 121 |
| `scripts/lib/claude-headless.sh` | code | 549, 567, 713, 767 |
| `scripts/lib/fleet-reservation-key.sh` | code | 3 |
| `scripts/lib/fleet-slots-shield.sh` | code | 5, 19, 32 |
| `scripts/lib/fleet-wrapped.sh` | code | 3 |
| `scripts/lib/kill-tree.mjs` | code | 5, 46, 107 |
| `scripts/lib/llm-backend.sh` | code | 9, 12 |
| `scripts/lib/qmd-key-probe.sh` | code | 10 |
| `scripts/lib/rename-aliases.tsv` | config | 334, 335, 336, 337, 338, 339, 341 |
| `scripts/lib/test-bank-attribution.sh` | test | 2, 28, 144, 191, 207, 222, 236, 264 |
| `scripts/lib/test-bank-monitor.sh` | test | 2, 13, 43, 172, 175, 307, 310 |
| `scripts/lib/test-bank-preflight-admit-gate.sh` | test | 2, 29, 377 |
| `scripts/lib/test-bank-preflight-dead-owner.sh` | test | 126 |
| `scripts/lib/test-bank-preflight-dotenv-root.sh` | test | 2, 3, 7, 22 |
| `scripts/lib/test-bank-preflight-fleet.sh` | test | 2, 27, 47, 293 |
| `scripts/lib/test-bank-preflight-openrouter.sh` | test | 3, 39 |
| `scripts/lib/test-bank-preflight.sh` | test | 2, 7, 31, 601, 626, 638, 727, 728, 736, 737, 927, 929, 940, 958, 961, 969, 971, 973, 974, 976, 980 |
| `scripts/lib/test-chokepoint-seam-guard.sh` | test | 304 |
| `scripts/lib/test-claude-headless-live.sh` | test | 7 |
| `scripts/lib/test-claude-headless-trap.sh` | test | 45, 165 |
| `scripts/lib/test-claude-headless.sh` | test | 4, 15, 30, 31, 39, 173, 174, 175, 502, 560 |
| `scripts/lib/test-fleet-reservation-key.sh` | test | 8, 64, 65, 66 |
| `scripts/lib/test-fleet-slots-shield.sh` | test | 33, 39 |
| `scripts/lib/test-rename-aliases.sh` | test | 118, 119, 179, 180, 181, 182, 183, 205, 224, 225, 226, 227, 228 |
| `scripts/lib/usage-attribution.sh` | code | 76, 111, 277, 292 |
| `scripts/lib/usage-lift.sh` | code | 9, 20, 22, 32, 128, 161 |
| `scripts/lib/usage-monitor.sh` | code | 49, 51 |
| `scripts/lib/usage-preflight.sh` | code | 23, 127, 402, 405, 577, 645, 745, 746, 753, 757, 792, 806, 810, 940, 944, 951, 959, 965, 968, 972, 976, 978, 982, 990, 992, 996, 1058, 1068, 1074, 1095, 1100, 1113, 1167, 1170, 1200, 1204, 1208, 1214, 1215, 1223, 1227, 1228, 1257, 1261, 1272, 1277, 1282, 1286, 1290, 1328, 1352 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 489, 490, 575, 745, 746 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 172 |
| `scripts/luna/graphmap-cadence.sh` | code | 20 |
| `scripts/luna/pipeline-cadence.sh` | code | 1307 |
| `scripts/luna/synth-input-check.sh` | code | 10 |
| `scripts/luna/test-graphmap-cadence.sh` | test | 612, 672, 674 |
| `scripts/luna/test-pipeline-cadence.sh` | test | 741, 749, 1480 |
| `scripts/luna/test-synth-input-check.sh` | test | 3 |
| `scripts/probes/claude-p/07-settings-overlay-hooks.sh` | code | 102 |
| `scripts/probes/claude-p/RESULTS-3e.md` | docs | 4 |
| `scripts/probes/claude-p/RESULTS.md` | docs | 46 |
| `scripts/statusline/test-usage-cache-contract.sh` | test | 221, 231 |
| `scripts/statusline/test-usage-cache-producer.sh` | test | 320, 563, 566 |
| `scripts/telegram/console-heartbeat-watch.ts` | code | 45 |
| `scripts/telegram/run.ts` | code | 272 |
| `scripts/telegram/spawn-claudex.ts` | code | 51 |
| `scripts/test-adopt.sh` | test | 1330, 1362, 1364 |
| `scripts/test-himmel-doctor.sh` | test | 4204, 4205, 4207 |
| `scripts/testing/documented-commands.tsv` | config | 9, 44, 71 |
| `scripts/testing/test-claude-mock-turn.sh` | test | 176, 186, 210, 220, 222 |
| `scripts/usage/test-usage.sh` | test | 67 |
| `scripts/usage/usage-compute.sh` | code | 120, 123 |
| `scripts/vm/replay-poc-check.sh` | code | 19, 69 |
| `site/src/trail/levels.json` | config | 193 |

### N13 `clear-cr-marker.sh and cr-*.sh` to `clear-review-marker.sh, review-*.sh, coderabbit-*.sh (per the registry)`

Family F5, slice V2; script/file name; owner HIMMEL-6647 (V2 HIMMEL-6640 Done); 474 lines in 128 files; new name live 9/9; 14 without a ruled name. the registry names nine; every other cr-*.sh has no ruled name (see unruled file names). `scripts/cr/cr-trigger-ledger.sh` is the CI-release ledger, not the CodeRabbit one, so the registry's `cr-trigger-ledger.sh` row (the `scripts/lib/` alias) does not apply to it. AMBIGUOUS: the pattern can catch a third-party cr-*.sh; read each hit.

Distinct matched strings (23): `clear-cr-marker.sh` to `clear-review-marker.sh` (live), `cr-available.sh` to `coderabbit-available.sh` (live), `cr-body-findings.sh` to `coderabbit-body-findings.sh` (live), `cr-context.sh` (no ruled name), `cr-default-base.sh` to `review-default-base.sh` (live), `cr-disposition.sh` (no ruled name), `cr-first-measure.sh` (no ruled name), `cr-first-release.sh` (no ruled name), `cr-high-risk-diff.sh` to `review-high-risk-diff.sh` (live), `cr-ledger-evidence.sh` to `review-ledger-evidence.sh` (live), `cr-marker.sh` (no ruled name), `cr-merge-gate.sh` to `review-merge-gate.sh` (live), `cr-merge.sh` (no ruled name), `cr-pending-audit.sh` (no ruled name), `cr-reset.sh` (no ruled name), `cr-review-freshness.sh` (no ruled name), `cr-round-metrics.sh` (no ruled name), `cr-rounds.sh` (no ruled name), `cr-scores.sh` (no ruled name), `cr-signal.sh` to `coderabbit-signal.sh` (live), `cr-trigger-ledger.sh` to `coderabbit-trigger-ledger.sh` (live), `cr-tune.sh` (no ruled name), `cr-two.sh` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.agents/skills/cr-scores/SKILL.md` | docs | 10 |
| `.agents/skills/pr-check/SKILL.md` | docs | 22, 39, 554, 607, 627, 632 |
| `.claude/commands/cr-scores.md` | docs | 5 |
| `.claude/commands/cr-tune.md` | docs | 7, 8, 13 |
| `.claude/commands/pr-check.md` | docs | 42 |
| `.claude/settings.json` | config | 98 |
| `docs/architecture.md` | docs | 63 |
| `docs/configuration.md` | docs | 368, 605, 607, 697 |
| `docs/daily-loop.md` | docs | 322 |
| `docs/evals/review-panel.md` | docs | 215 |
| `docs/guide/dev-graph/graph.json` | docs | 931, 1180 |
| `docs/guide/loops-and-graphs.html` | docs | 419 |
| `docs/handover/afk-mode.md` | docs | 415, 416 |
| `docs/handover/console-sections/judge.md` | docs | 56, 59 |
| `docs/handover/judge-brief-template.md` | docs | 314 |
| `docs/handover/leg-brief-template.md` | docs | 192 |
| `docs/handover/leg-preface.md` | docs | 118 |
| `docs/internals/config-layers.md` | docs | 43, 62 |
| `docs/internals/enforcement.md` | docs | 1156, 1206, 1279, 1314, 1351, 1353, 1445, 1448, 2648 |
| `docs/internals/harness-compat.md` | docs | 891, 930, 1111 |
| `docs/internals/hermes-guardrail-parity.md` | docs | 80 |
| `docs/internals/testing.md` | docs | 181 |
| `docs/internals/validation-gates.md` | docs | 156 |
| `docs/operator-conventions.md` | docs | 47, 48 |
| `docs/tooling-catalog.md` | docs | 2048 |
| `marketplace/plugins/himmel-ops/skills/minerva/SKILL.md` | docs | 242, 268 |
| `plugins/himmel-gh/lib/thread-resolve-action-cli.mjs` | code | 180 |
| `scripts/adopt.sh` | code | 184, 186, 233, 234 |
| `scripts/check-ci.sh` | code | 726, 733 |
| `scripts/chokepoints.json` | config | 5 |
| `scripts/ci/cr-first-measure.sh` | code | 2, 26, 27, 39 |
| `scripts/ci/test-cr-first-measure.sh` | test | 2, 9 |
| `scripts/cr/anchor-handoff.sh` | code | 281 |
| `scripts/cr/clear-cr-marker.sh` | code | 17, 20, 22 |
| `scripts/cr/clear-review-marker.sh` | code | 1376 |
| `scripts/cr/cr-pending-audit.sh` | code | 2, 26 |
| `scripts/cr/cr-reset.sh` | code | 2, 24 |
| `scripts/cr/cr-round-metrics.sh` | code | 2, 3, 9, 44, 45, 46, 47, 49, 50, 53, 60, 68, 70, 75, 84, 86, 116, 119, 202, 233 |
| `scripts/cr/cr-scores.sh` | code | 2, 3, 4, 35, 36, 37, 44 |
| `scripts/cr/cr-trigger-ledger.sh` | code | 2, 5, 7, 11, 12, 13, 14, 17, 62, 76, 97, 111 |
| `scripts/cr/cr-tune.sh` | code | 3, 9, 19, 20, 22, 44 |
| `scripts/cr/critic-panel.sh` | code | 2260 |
| `scripts/cr/known-findings.sh` | code | 453 |
| `scripts/cr/ledger-append.sh` | code | 22, 461, 463, 1312 |
| `scripts/cr/pr-check-ref/00-preamble.md` | docs | 5 |
| `scripts/cr/pr-check-ref/20-step2-lanes.md` | docs | 17, 23, 37 |
| `scripts/cr/pr-check-ref/30-step3-panel.md` | docs | 51, 58 |
| `scripts/cr/pr-check-ref/31-step3-adjudicate.md` | docs | 5, 74 |
| `scripts/cr/pr-check-ref/32-step3-reviewers.md` | docs | 7, 9, 10, 26 |
| `scripts/cr/pr-check-ref/40-step4-crosscheck.md` | docs | 36 |
| `scripts/cr/pr-check-ref/45-step4.5-ledger.md` | docs | 129, 248 |
| `scripts/cr/pr-check-ref/48-step4.8-threads.md` | docs | 28 |
| `scripts/cr/pr-check-ref/50-step5-decision.md` | docs | 9, 57, 63 |
| `scripts/cr/test-anchor-handoff.sh` | test | 61, 64, 81, 341 |
| `scripts/cr/test-clear-cr-marker.sh` | test | 96, 97, 468, 473, 474, 476 |
| `scripts/cr/test-cr-pending-audit.sh` | test | 3, 14, 225 |
| `scripts/cr/test-cr-round-metrics.sh` | test | 3, 7 |
| `scripts/cr/test-cr-scores.sh` | test | 14, 345 |
| `scripts/cr/test-cr-tune.sh` | test | 3, 15 |
| `scripts/cr/test-pr-check-run.sh` | test | 55, 56 |
| `scripts/cr/write-verdicts.sh` | code | 270, 273 |
| `scripts/eval/cr-ledger/cr_ledger_eval.py` | code | 6 |
| `scripts/eval/guard-corpus/test-guard-corpus.sh` | test | 457, 458 |
| `scripts/eval/leg-digest/fixtures/bash-errors.jsonl` | fixture | 32 |
| `scripts/guardrails/git-env-baseline.txt` | config | 16, 17, 18 |
| `scripts/handover/console-kit/cr-disposition.sh` | code | 2, 12, 15, 41, 42, 215 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6419-N2801-critic-cost-measure-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-1179.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-2035.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-3832.md` | fixture | 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5779.md` | fixture | 26, 28, 29 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5856.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6303.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6419.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6462.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6475.md` | fixture | 29 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6490.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/pr-files.tsv` | fixture | 2, 9, 32 |
| `scripts/handover/console-kit/gen-briefs.py` | code | 350 |
| `scripts/handover/console-kit/go.sh` | code | 86, 330, 335, 337 |
| `scripts/handover/console-kit/grant-round.sh` | code | 23 |
| `scripts/handover/console-kit/ready-check.sh` | code | 30, 195, 198 |
| `scripts/handover/console-kit/test-cr-disposition.sh` | test | 4, 19 |
| `scripts/handover/console-kit/test-go.sh` | test | 254 |
| `scripts/handover/console-kit/test-ready-check.sh` | test | 2152, 2154 |
| `scripts/handover/console-kit/testlib-ready-pass.sh` | code | 21 |
| `scripts/handover/console-kit/tick.sh` | code | 241, 1937, 1939 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc127-fix.sh` | fixture | 77, 190, 192, 194, 562, 586, 589, 592 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc4-fix.sh` | fixture | 78, 191, 193, 195, 571, 595, 598, 601 |
| `scripts/handover/resume-context.sh` | code | 32, 33 |
| `scripts/handover/test-merge-on-green.sh` | test | 271 |
| `scripts/hooks/block-tail-pipe-on-gates.sh` | code | 8, 55, 1309 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/allow-fp-echo-compound.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-fix.sh` | fixture | 139 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3573.sh` | fixture | 152 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3585.sh` | fixture | 152 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3910.sh` | fixture | 152 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-pin.sh` | fixture | 153 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-rc127-fix.sh` | fixture | 160 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-rc4-fix.sh` | fixture | 161 |
| `scripts/hooks/guard-pr-check-literal.sh` | code | 69 |
| `scripts/hooks/lib-cmdpos-clean.sh` | code | 33 |
| `scripts/hooks/test-block-chokepoint-env-prefix.sh` | test | 1262, 1263 |
| `scripts/hooks/test-block-tail-pipe-on-gates.sh` | test | 60, 77, 81, 88, 134, 151, 162, 178, 417, 424, 486, 926, 929, 944, 946 |
| `scripts/hooks/test-block-unresolved-cr-merge.sh` | test | 788, 888, 917, 986, 1044, 1110, 1145, 1184, 1253, 1303, 1358 |
| `scripts/hooks/test-guard-pr-check-literal.sh` | test | 51, 52, 224, 225, 226, 227, 500, 526, 528, 559, 581, 582, 583, 584, 634, 726, 727, 729, 730, 731, 732, 733, 735, 736, 737, 738, 762, 1535, 1536, 1537, 1538, 1539, 1540, 1541, 1542, 1543, 1563, 1565, 1619, 1622, 2473, 2474, 2475, 2476, 2477, 2478, 2483, 2484, 2485, 2486, 2487, 2488, 2489, 2490, 2491, 2499, 2500, 2501, 2502, 2503, 2504, 2505, 2506, 2507, 2508, 2509, 2510, 2511, 2512, 2513, 2514, 2515, 2516, 2517, 2518, 2523, 2524, 2525, 2526, 2527, 2528, 2529, 2530 |
| `scripts/hooks/test-require-quiet-run.sh` | test | 525, 527 |
| `scripts/lanes/plugin-profiles.json` | config | 4, 12, 24 |
| `scripts/lanes/plugin-profiles.mjs` | code | 36 |
| `scripts/lanes/tests/gate-allow-hook-survival.test.mjs` | test | 6, 54, 55, 56, 57, 59, 60, 61, 62, 88, 89 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 46, 70, 1460, 1466, 1492 |
| `scripts/lanes/tests/settings-allow.test.mjs` | test | 31, 33, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 120, 121, 141, 228, 235 |
| `scripts/lib/cr-first-release.sh` | code | 2, 30, 43, 49, 53, 405, 408 |
| `scripts/lib/rename-aliases.tsv` | config | 340, 346, 347, 348, 349, 350, 351, 352, 353 |
| `scripts/lib/review-merge-gate.sh` | code | 498 |
| `scripts/lib/test-cr-first-release.sh` | test | 3, 82, 340, 430, 446, 452, 455, 459 |
| `scripts/lib/test-cr-high-risk-diff.sh` | test | 92, 142, 143 |
| `scripts/lib/test-cr-merge-gate.sh` | test | 481, 602 |
| `scripts/lib/test-rename-aliases.sh` | test | 232, 246, 249, 251, 252, 253, 254, 255, 256, 258, 262, 263, 264, 265, 266, 267, 268, 269 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 28, 29, 30, 31, 32, 33 |
| `scripts/lint/test-check-swallowed-errors.sh` | test | 5 |
| `scripts/telegram/README.md` | docs | 95 |
| `scripts/telegram/break-glass.sh` | code | 29, 54, 401 |
| `scripts/telegram/round-guard.test.ts` | test | 162 |
| `scripts/telegram/round-guard.ts` | code | 116, 130, 162 |
| `scripts/telegram/test-break-glass.sh` | test | 3, 14, 453, 481 |
| `scripts/test-adopt.sh` | test | 1384, 1393, 1406, 1407, 1408, 1409 |
| `scripts/testing/documented-commands.tsv` | config | 33, 35, 56, 57 |

### N14 `CR_MARKER*, CLEAR_CR_MARKER_*, SETUP_CR_MARKER` to `REVIEW_MARKER*, CLEAR_REVIEW_MARKER_*, SETUP_REVIEW_MARKER`

Family F5, slice V2; env var; owner HIMMEL-6647 (V2 HIMMEL-6640 Done); 17 lines in 7 files; new name live 3/4. SETUP_CR_MARKER is a test-local name; the <git-dir>/cr-pending/ dir keeps its name (OD-3).

Distinct matched strings (4): `CLEAR_CR_MARKER_BUDGET_WAIT` to `CLEAR_REVIEW_MARKER_BUDGET_WAIT` (live), `CR_MARKER_` to `REVIEW_MARKER_` (live), `CR_MARKER_LOCK_WAIT_SECONDS` to `REVIEW_MARKER_LOCK_WAIT_SECONDS` (live), `SETUP_CR_MARKER` to `SETUP_REVIEW_MARKER`

| File | Class | Lines |
|---|---|---|
| `scripts/cr/clear-review-marker.sh` | code | 155, 156 |
| `scripts/cr/test-clear-cr-marker.sh` | test | 2285, 2287, 3554, 3559 |
| `scripts/handover/test-pr-merge.sh` | test | 244, 250, 498 |
| `scripts/hooks/check-cr-before-push.sh` | code | 858, 859 |
| `scripts/hooks/test-check-cr-before-push.sh` | test | 1226, 1228 |
| `scripts/lib/rename-aliases.tsv` | config | 31, 45 |
| `scripts/lib/test-rename-aliases.sh` | test | 45, 231 |

### N15 `headed-arm-leg.sh` to `headed-arm-worker.sh`

Family F6, slice V4b; script/file name; owner HIMMEL-6643; 360 lines in 140 files; new name live 1/2; 2 without a ruled name.

Distinct matched strings (4): `headed-arm-leg-cwd.sh` to `headed-arm-worker-cwd.sh`, `headed-arm-leg.sh` to `headed-arm-worker.sh` (live), `test-headed-arm-leg-worker-env.sh` (no ruled name), `test-headed-arm-leg.sh` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.claude/agents/judge.md` | docs | 3 |
| `.claude/settings.json` | config | 75 |
| `docs/guide/dev-graph/graph.json` | docs | 173, 176, 786, 803, 820, 837, 854 |
| `docs/handover/console-sections/monitors.md` | docs | 49 |
| `docs/handover/console-template.md` | docs | 149 |
| `docs/handover/consult-preface.md` | docs | 4, 10 |
| `docs/handover/judge-brief-template.md` | docs | 4, 6, 39, 73, 81, 82, 123, 401, 402, 404 |
| `docs/handover/judge-preface.md` | docs | 5, 19, 84 |
| `docs/handover/leg-brief-template.md` | docs | 7, 21, 25, 36, 73, 219, 220, 225, 273 |
| `docs/handover/leg-preface-claudex.md` | docs | 3 |
| `docs/handover/leg-preface-openrouter.md` | docs | 3 |
| `docs/handover/leg-preface.md` | docs | 5 |
| `docs/handover/relay-brief-template.md` | docs | 5 |
| `docs/handover/rm-brief-template.md` | docs | 9 |
| `docs/handover/rm-preface.md` | docs | 4 |
| `docs/handover/running-a-console.md` | docs | 134, 164, 186, 223, 227, 285, 315, 426 |
| `docs/internals/console-ops-lane.md` | docs | 17 |
| `docs/internals/enforcement.md` | docs | 3275, 3994, 4041, 4049, 4065, 4128, 4186, 5090, 5099, 5670, 5676, 5759 |
| `docs/internals/headless-modes.md` | docs | 18, 58, 61, 65, 71, 72, 87, 98, 108 |
| `docs/internals/known-findings.md` | docs | 238, 239 |
| `docs/internals/lane-calibration.md` | docs | 28, 84, 91, 486, 489, 491, 495, 501, 622, 768, 778, 783, 832, 862, 870, 945, 958, 1149 |
| `docs/internals/leg-context-guard.md` | docs | 29, 30, 85 |
| `docs/internals/stuck-playbook.md` | docs | 510, 665 |
| `marketplace/plugins/himmel-ops/hooks/guard-judge-writes.sh` | code | 6, 17, 41, 206 |
| `marketplace/plugins/himmel-ops/hooks/guard-rm-writes.sh` | code | 13, 24 |
| `scripts/chokepoints.json` | config | 29 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 60 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 125 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 36 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 171 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 221 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 34 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 32 |
| `scripts/ci/fixtures/tier-replay/manifests/39400326799.txt` | fixture | 2 |
| `scripts/ci/suite-durations.tsv` | config | 379, 380 |
| `scripts/ci/suite-tiers.tsv` | config | 369, 370 |
| `scripts/ci/test-pr-plan.sh` | test | 190 |
| `scripts/ci/test-run-shell-tests.sh` | test | 2496 |
| `scripts/claude-codex` | code | 898 |
| `scripts/config-ui/tests/agui-fleet.test.ts` | test | 262 |
| `scripts/config-ui/tests/agui-lane.test.ts` | test | 24 |
| `scripts/docs/test-dev-graph.sh` | test | 17 |
| `scripts/eval/console-load-inventory.py` | code | 38 |
| `scripts/eval/lane-quality/pilot-4869/pilot.sh` | code | 239 |
| `scripts/eval/lane-quality/pilot-4869/sandbox.sh` | code | 33 |
| `scripts/graphify/anchor-seeds.py` | code | 12 |
| `scripts/graphify/repo-map.py` | code | 8 |
| `scripts/graphify/test-anchor-seeds.sh` | test | 146, 153 |
| `scripts/graphify/test-semantic-seeds.sh` | test | 201, 202, 219, 221 |
| `scripts/handover/arm-resume.sh` | code | 790, 794, 803, 2766 |
| `scripts/handover/console-kit/ack-denial.sh` | code | 13 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 41, 94 |
| `scripts/handover/console-kit/console-wait.sh` | code | 138 |
| `scripts/handover/console-kit/denial-ack-lib.sh` | code | 4 |
| `scripts/handover/console-kit/denied-launch-alert.sh` | code | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-4999-N2802-vault-gitleaks-token-grammar-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6476-N2804-leg-api-lane-switch-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6118.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6119.md` | fixture | 24, 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6476.md` | fixture | 24, 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/pr-files.tsv` | fixture | 16, 17 |
| `scripts/handover/console-kit/gen-briefs.py` | code | 26, 29, 84, 119, 165, 220, 382, 384, 399, 416, 501 |
| `scripts/handover/console-kit/gen-judge-brief.py` | code | 227 |
| `scripts/handover/console-kit/go.sh` | code | 4, 96 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 2, 19, 22, 23, 27, 30, 217, 220, 232, 1157, 1270, 1320, 1414 |
| `scripts/handover/console-kit/inbox-send.sh` | code | 51 |
| `scripts/handover/console-kit/leg-digest-step.sh` | code | 15, 212 |
| `scripts/handover/console-kit/leg-doc-lock.sh` | code | 6 |
| `scripts/handover/console-kit/smoke-consult-sandbox.sh` | code | 4, 8, 94 |
| `scripts/handover/console-kit/test-brief-lint.sh` | test | 2, 5, 14, 21, 27 |
| `scripts/handover/console-kit/test-denied-launch-alert.sh` | test | 46, 62, 68, 73, 90, 107 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 31 |
| `scripts/handover/console-kit/test-gen-briefs.sh` | test | 86, 87, 107, 222, 233, 234, 268, 272, 274, 275 |
| `scripts/handover/console-kit/test-gen-judge-brief.sh` | test | 74, 77 |
| `scripts/handover/console-kit/test-go.sh` | test | 2 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 2, 19 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 3, 4, 47, 118, 157, 161, 290, 295, 761, 1070, 2097, 2443, 3379, 3388, 3389, 3393, 3402, 3418, 3429, 3490, 3526, 4000, 4016, 4137, 4139, 4767, 4770 |
| `scripts/handover/console-kit/test-leg-doc-lock.sh` | test | 36 |
| `scripts/handover/console-kit/test-leg-pretrust.sh` | test | 2 |
| `scripts/handover/console-kit/test-tick.sh` | test | 1118, 1205 |
| `scripts/handover/console-kit/tick.sh` | code | 2384 |
| `scripts/handover/console/chief.sh` | code | 305, 367 |
| `scripts/handover/console/test-console.sh` | test | 1832, 1909, 1911, 1914, 1917, 1920, 1921, 1936 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc127-fix.sh` | fixture | 138, 518 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc4-fix.sh` | fixture | 139, 519 |
| `scripts/handover/headed-arm.sh` | code | 259, 347, 461, 515, 566, 598, 672, 690, 1443, 1526 |
| `scripts/handover/merge-on-green.sh` | code | 225, 950 |
| `scripts/handover/test-headed-arm.sh` | test | 37, 58, 456, 2205, 2244 |
| `scripts/handover/test-leg-handoff-threshold-docs.sh` | test | 5, 13 |
| `scripts/handover/test-ship-jira-transition-docs.sh` | test | 112 |
| `scripts/hooks/block-unresolved-cr-merge.sh` | code | 14 |
| `scripts/hooks/block-worker-askuserquestion.sh` | code | 4 |
| `scripts/hooks/console-compact-reinject.sh` | code | 9, 41 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3573.sh` | fixture | 14 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3585.sh` | fixture | 14 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3910.sh` | fixture | 14 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-pin.sh` | fixture | 23 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-rc127-fix.sh` | fixture | 22 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-rc4-fix.sh` | fixture | 23 |
| `scripts/hooks/graphify-freshness-advisory.sh` | code | 38 |
| `scripts/hooks/guard-judge-writes.sh` | code | 6, 17, 41, 206 |
| `scripts/hooks/guard-leg-cache-ttl.sh` | code | 2, 17 |
| `scripts/hooks/guard-leg-context-handoff.sh` | code | 12, 18 |
| `scripts/hooks/guard-relay-writes.sh` | code | 8, 18 |
| `scripts/hooks/guard-rm-writes.sh` | code | 13, 24 |
| `scripts/hooks/guard-worker-wakeup.sh` | code | 4 |
| `scripts/hooks/inject-where-are-we.sh` | code | 41 |
| `scripts/hooks/qmd-staleness-notice.sh` | code | 40 |
| `scripts/hooks/read-clamp.sh` | code | 13 |
| `scripts/hooks/test-console-compact-reinject.sh` | test | 208 |
| `scripts/hooks/test-guard-judge-writes.sh` | test | 3, 14, 34 |
| `scripts/hooks/test-guard-rm-writes.sh` | test | 5, 13 |
| `scripts/hooks/test-guard-worker-wakeup.sh` | test | 3 |
| `scripts/hooks/test-qmd-staleness-notice.sh` | test | 174 |
| `scripts/hooks/wire-hook-bash.mjs` | code | 224 |
| `scripts/lanes/bench/scorecard/agg-postpin.sh` | code | 30 |
| `scripts/lanes/consult-env.sh` | code | 7 |
| `scripts/lanes/effort-route.mjs` | code | 4 |
| `scripts/lanes/lane-canary.sh` | code | 4, 62 |
| `scripts/lanes/leg-claude-launcher-consult.sh` | code | 16 |
| `scripts/lanes/leg-claude-launcher.sh` | code | 37, 54, 58, 82, 137 |
| `scripts/lanes/plugin-profiles.json` | config | 168, 313, 326, 339, 421, 431 |
| `scripts/lanes/profile-settings.sh` | code | 5, 8 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 1321, 1336, 1752 |
| `scripts/lanes/tests/profile-context-ceiling.test.mjs` | test | 36 |
| `scripts/lib/chief-context.sh` | code | 188, 195 |
| `scripts/lib/clean-sandbox.sh` | code | 33 |
| `scripts/lib/coderabbit-trigger-ledger.sh` | code | 76 |
| `scripts/lib/go-gate.sh` | code | 21 |
| `scripts/lib/override-env.sh` | code | 10 |
| `scripts/lib/test-leg-identity.sh` | test | 5 |
| `scripts/lib/usage-preflight.sh` | code | 22, 74, 194 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 325 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 94 |
| `scripts/telegram/break-glass.sh` | code | 380 |
| `scripts/telegram/round-guard.ts` | code | 293 |
| `scripts/test-uninstall.sh` | test | 1249, 1272, 1275 |
| `scripts/testing/test-mock-consult-sandbox.sh` | test | 10, 52, 59, 80 |
| `scripts/testing/unwired-hooks-allowlist.txt` | config | 33 |
| `scripts/uninstall.sh` | code | 3732 |

### N16 `leg-identity, leg-doc-lock, leg-event, leg-jira-status, leg-pretrust, leg-transcripts, leg-graph (.sh)` to `worker-identity, worker-doc-lock, worker-event, worker-jira-status, worker-pretrust, worker-transcripts, worker-graph`

Family F7, slice V4b; script/file name; owner HIMMEL-6643; 268 lines in 107 files; new name live 0/7; 7 without a ruled name. only the seven helpers plan row 28-36 names; every other leg-*.sh is N42.

Distinct matched strings (14): `leg-doc-lock.sh` to `worker-doc-lock.sh`, `leg-event.sh` to `worker-event.sh`, `leg-graph.sh` to `worker-graph.sh`, `leg-identity.sh` to `worker-identity.sh`, `leg-jira-status.sh` to `worker-jira-status.sh`, `leg-pretrust.sh` to `worker-pretrust.sh`, `leg-transcripts.sh` to `worker-transcripts.sh`, `test-leg-doc-lock.sh` (no ruled name), `test-leg-event.sh` (no ruled name), `test-leg-graph-rationale.sh` (no ruled name), `test-leg-graph.sh` (no ruled name), `test-leg-identity.sh` (no ruled name), `test-leg-jira-status.sh` (no ruled name), `test-leg-pretrust.sh` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `docs/guide/dev-graph/graph.json` | docs | 672, 1334, 1351, 1367 |
| `docs/handover/console-sections/waiter.md` | docs | 103 |
| `docs/handover/console-sections/wrapping.md` | docs | 9, 11, 17 |
| `docs/handover/console-template.md` | docs | 192 |
| `docs/handover/judge-brief-template.md` | docs | 401 |
| `docs/handover/leg-brief-template.md` | docs | 11, 219 |
| `docs/handover/leg-preface.md` | docs | 80 |
| `docs/handover/running-a-console.md` | docs | 295 |
| `docs/internals/console-ops-lane.md` | docs | 12, 38 |
| `docs/internals/leg-context-guard.md` | docs | 99 |
| `docs/setup/new-machine.md` | docs | 1779 |
| `scripts/check-ci.sh` | code | 1299 |
| `scripts/ci/check-run-timelines/testdata/sweep-6122/run-39032362864.json` | config | 1 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 62, 63, 64 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 7, 53, 97 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 7, 101 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 58, 125 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 521 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 26, 37, 38, 67 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 35, 56 |
| `scripts/ci/run-shell-tests.sh` | code | 944 |
| `scripts/ci/suite-durations.tsv` | config | 332, 333, 389, 390, 391, 392, 812 |
| `scripts/ci/suite-tiers.tsv` | config | 313, 314, 380, 381, 382, 383, 815 |
| `scripts/ci/test-run-shell-tests.sh` | test | 807, 2498 |
| `scripts/cr/impacted-suites.sh` | code | 1103 |
| `scripts/cr/pr-check-context.sh` | code | 782, 787, 812, 814, 845, 847 |
| `scripts/cr/test-impacted-suites.sh` | test | 923, 929, 931, 940 |
| `scripts/docs/test-dev-graph.sh` | test | 22 |
| `scripts/eval/autocompact-ab.py` | code | 10, 150, 157 |
| `scripts/eval/console-load-inventory.py` | code | 234 |
| `scripts/eval/graphify-ab/run.sh` | code | 7, 33, 132 |
| `scripts/eval/graphify-ab/test-graphify-ab.sh` | test | 39, 86, 102, 103, 104 |
| `scripts/eval/lane-quality/pilot-4869/sandbox.sh` | code | 295 |
| `scripts/eval/retrieval-eval/questions.jsonl` | code | 42, 47 |
| `scripts/eval/retrieval-eval/retrieval-eval.py` | code | 24, 342 |
| `scripts/eval/retrieval-eval/test-retrieval-eval.sh` | test | 358, 390 |
| `scripts/graphify/anchor-seeds.py` | code | 6 |
| `scripts/graphify/leg-graph.sh` | code | 2, 10, 36, 44, 153 |
| `scripts/graphify/semantic-seeds.py` | code | 6 |
| `scripts/graphify/test-anchor-seeds.sh` | test | 4, 9, 108 |
| `scripts/graphify/test-leg-graph-rationale.sh` | test | 2, 9 |
| `scripts/graphify/test-leg-graph.sh` | test | 2, 8, 109, 121 |
| `scripts/graphify/test-semantic-seeds.sh` | test | 5, 9, 79 |
| `scripts/guardrails/test-settings-waiter-allow.sh` | test | 100 |
| `scripts/handover/arm-resume.sh` | code | 4604 |
| `scripts/handover/breadcrumb.sh` | code | 253 |
| `scripts/handover/console-kit/append-results.sh` | code | 163, 168, 169, 187, 197 |
| `scripts/handover/console-kit/board.mjs` | code | 136, 197, 202, 455 |
| `scripts/handover/console-kit/brief-lint.sh` | code | 63, 64 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 36, 189, 191, 192, 201, 203, 204, 211, 279 |
| `scripts/handover/console-kit/console-wait.sh` | code | 48, 843, 853 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5592.md` | fixture | 27, 28, 29 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6056.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6140.md` | fixture | 24 |
| `scripts/handover/console-kit/fleet-manifest.sh` | code | 24, 51, 52 |
| `scripts/handover/console-kit/fleet.mjs` | code | 115, 203 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 807, 814, 815, 2482, 2486, 2487, 2566, 2571 |
| `scripts/handover/console-kit/inbox-send.sh` | code | 201, 205, 206 |
| `scripts/handover/console-kit/leg-digest-step.sh` | code | 20, 89, 91, 95, 97 |
| `scripts/handover/console-kit/leg-doc-lock.sh` | code | 2 |
| `scripts/handover/console-kit/leg-event.sh` | code | 2, 7, 49 |
| `scripts/handover/console-kit/leg-jira-status.sh` | code | 2, 9, 10, 33, 34 |
| `scripts/handover/console-kit/leg-pretrust.sh` | code | 2, 33 |
| `scripts/handover/console-kit/leg-transcripts.sh` | code | 2 |
| `scripts/handover/console-kit/live-state.sh` | code | 17, 188, 189 |
| `scripts/handover/console-kit/ops-run.sh` | code | 46 |
| `scripts/handover/console-kit/pr-stall.sh` | code | 36, 54, 55 |
| `scripts/handover/console-kit/relay-batch.sh` | code | 59, 60 |
| `scripts/handover/console-kit/residual-lines.sh` | code | 3 |
| `scripts/handover/console-kit/status-drift.sh` | code | 97, 237, 281 |
| `scripts/handover/console-kit/status-sweep.sh` | code | 15, 249, 264 |
| `scripts/handover/console-kit/test-append-results.sh` | test | 260 |
| `scripts/handover/console-kit/test-console-wait-r0.sh` | test | 4, 24, 62, 82 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 28, 30 |
| `scripts/handover/console-kit/test-fleet.sh` | test | 9 |
| `scripts/handover/console-kit/test-leg-doc-lock.sh` | test | 3, 19, 37, 109, 151, 154 |
| `scripts/handover/console-kit/test-leg-event.sh` | test | 2, 24 |
| `scripts/handover/console-kit/test-leg-jira-status.sh` | test | 3, 4, 20 |
| `scripts/handover/console-kit/test-leg-pretrust.sh` | test | 3, 27, 199, 307, 308 |
| `scripts/handover/console-kit/test-ops-run.sh` | test | 32, 66 |
| `scripts/handover/console-kit/test-status-drift.sh` | test | 2, 18 |
| `scripts/handover/console-kit/tick.sh` | code | 38, 39, 395, 883, 960 |
| `scripts/handover/console-kit/ticket-hold.sh` | code | 19 |
| `scripts/handover/merge-on-green.sh` | code | 604 |
| `scripts/handover/test-merge-on-green-jira-end-state.sh` | test | 123, 177 |
| `scripts/handover/test-merge-on-green.sh` | test | 265 |
| `scripts/hooks/block-graphify-egress.sh` | code | 284 |
| `scripts/hooks/guard-console-foreground.sh` | code | 120 |
| `scripts/hooks/retrieval-nudge.sh` | code | 4, 17, 81 |
| `scripts/hooks/test-block-graphify-egress.sh` | test | 477, 478 |
| `scripts/hooks/test-guard-judge-writes.sh` | test | 108 |
| `scripts/hooks/test-guard-rm-writes.sh` | test | 92 |
| `scripts/hooks/test-retrieval-nudge.sh` | test | 43, 57 |
| `scripts/lanes/bench/scorecard/leg-relaunch.sh` | code | 73, 80, 82 |
| `scripts/lanes/bench/scorecard/lib/scorecard-lib.sh` | code | 13, 21, 22, 71 |
| `scripts/lanes/bench/scorecard/test-agg-burn.sh` | test | 14, 245 |
| `scripts/lanes/bench/scorecard/test-leg-relaunch.sh` | test | 18, 123 |
| `scripts/lanes/bench/scorecard/test-scorecard.sh` | test | 190 |
| `scripts/lanes/leg-pr-open.sh` | code | 282 |
| `scripts/lanes/lib/leg-cost-row.sh` | code | 25, 26 |
| `scripts/lib/graphify-bin.sh` | code | 21 |
| `scripts/lib/leg-identity.sh` | code | 2 |
| `scripts/lib/test-leg-identity.sh` | test | 2, 11, 12 |
| `scripts/lib/ticket-status.sh` | code | 4 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 248, 319, 320, 321 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 101, 102, 103, 104, 105, 106 |
| `scripts/testing/documented-commands.tsv` | config | 47, 48, 49, 76 |

### N17 `leg-digest*` to `worker-digest*`

Family F7, slice V4b; script/file name, directory; owner HIMMEL-6643 (dir: HIMMEL-6646); 130 lines in 55 files; new name live 0/3.

Distinct matched strings (3): `leg-digest` to `worker-digest`, `leg-digest-step` to `worker-digest-step`, `leg-digest-test` to `worker-digest-test`

| File | Class | Lines |
|---|---|---|
| `docs/cadences.md` | docs | 58 |
| `docs/handover/console-sections/wrapping.md` | docs | 49, 64 |
| `docs/internals/egress-matrix.md` | docs | 284 |
| `docs/tool-adoption/per-profile-tool-evals.md` | docs | 7, 11, 22 |
| `docs/tool-adoption/pstack-integration.md` | docs | 18 |
| `scripts/ci/fixtures/tier-replay/manifests/39389464966.txt` | fixture | 23 |
| `scripts/ci/fixtures/tier-replay/manifests/39390916544.txt` | fixture | 15 |
| `scripts/ci/fixtures/tier-replay/manifests/39393086896.txt` | fixture | 20 |
| `scripts/ci/fixtures/tier-replay/manifests/39394784725.txt` | fixture | 15 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 23 |
| `scripts/ci/fixtures/tier-replay/manifests/39449037336.txt` | fixture | 59 |
| `scripts/ci/suite-durations.tsv` | config | 290, 291, 292, 293 |
| `scripts/ci/suite-tiers.tsv` | config | 270, 271, 272, 273 |
| `scripts/ci/test-os-verify-workflow.sh` | test | 264, 265, 266 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard1.txt` | test | 19 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard2.txt` | test | 19 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard3.txt` | test | 19 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard4.txt` | test | 19 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard5.txt` | test | 19, 34 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard6.txt` | test | 19 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard7.txt` | test | 19 |
| `scripts/ci/test-shard-manifest-verify-fixtures/manifest-shard8.txt` | test | 19 |
| `scripts/config-ui/health-sources.ts` | code | 9 |
| `scripts/config-ui/tests/tool-health.test.ts` | test | 30, 74 |
| `scripts/eval/README.md` | docs | 152, 286, 288, 294, 295, 318, 319, 346, 367, 375, 384, 385, 386 |
| `scripts/eval/fixtures/session-retro-ledger.jsonl` | fixture | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 |
| `scripts/eval/leg-digest/denial-exceptions.txt` | config | 3 |
| `scripts/eval/leg-digest/failure-review-cadence.sh` | code | 130 |
| `scripts/eval/leg-digest/failure_review.py` | code | 2 |
| `scripts/eval/leg-digest/failure_router.py` | code | 2, 69 |
| `scripts/eval/leg-digest/leg-digest.ts` | code | 1, 3, 141 |
| `scripts/eval/leg-digest/leg_ledger.py` | code | 2, 4, 43, 65, 94, 490 |
| `scripts/eval/leg-digest/test-failure-review.sh` | test | 3, 89 |
| `scripts/eval/leg-digest/test-failure-router.sh` | test | 2, 101, 177, 446 |
| `scripts/eval/leg-digest/test-leg-digest.sh` | test | 2, 16, 19, 245 |
| `scripts/eval/leg-digest/test-leg-ledger.sh` | test | 2, 15, 44 |
| `scripts/eval/session-retro.py` | code | 5 |
| `scripts/eval/test-eval-feedback.sh` | test | 12 |
| `scripts/guardrails/egress-matrix.json` | config | 24 |
| `scripts/handover/console-kit/board.mjs` | code | 65, 669, 676 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 52, 280, 431, 435 |
| `scripts/handover/console-kit/leg-digest-step.sh` | code | 2, 4, 5, 8, 13, 41, 51, 52, 57, 58, 180 |
| `scripts/handover/console-kit/leg-transcripts.sh` | code | 4 |
| `scripts/handover/console-kit/test-board.sh` | test | 727 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | test | 904, 905, 910 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 43 |
| `scripts/handover/console-kit/test-tick.sh` | test | 218 |
| `scripts/handover/console-kit/tick.sh` | code | 117, 1829, 1830 |
| `scripts/handover/generate-morning-briefing.sh` | code | 490 |
| `scripts/hooks/test-log-classifier-denial.sh` | test | 358, 365 |
| `scripts/lanes/tests/profile-context-probe.test.mjs` | test | 544 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 318 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 100 |
| `scripts/observability/exit-codes.json` | config | 3 |
| `scripts/observability/ledgers.json` | config | 167, 180, 218, 219, 231 |

### N18 `close-wrapped-leg.sh` to `close-wrapped-worker.sh`

Family F7, slice V4b; script/file name; owner HIMMEL-6643; 113 lines in 60 files; new name live 0/1; 1 without a ruled name. the CLOSE_WRAPPED_LEG_* env names are in N38.

Distinct matched strings (2): `close-wrapped-leg.sh` to `close-wrapped-worker.sh`, `test-close-wrapped-leg.sh` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.claude/settings.json` | config | 78 |
| `docs/guide/dev-graph/graph.json` | docs | 720 |
| `docs/handover/console-sections/successor-start.md` | docs | 19 |
| `docs/handover/console-sections/wrapping.md` | docs | 33, 36 |
| `docs/handover/console-template.md` | docs | 195 |
| `docs/handover/leg-preface.md` | docs | 165 |
| `docs/handover/running-a-console.md` | docs | 285, 517 |
| `docs/internals/console-ops-lane.md` | docs | 13, 36 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 51 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 146 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 125 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 7 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 215 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 27 |
| `scripts/ci/run-shell-tests.sh` | code | 822 |
| `scripts/ci/suite-durations.tsv` | config | 361 |
| `scripts/ci/suite-tiers.tsv` | config | 347 |
| `scripts/ci/test-os-verify-workflow.sh` | test | 268 |
| `scripts/ci/test-run-shell-tests.sh` | test | 2491 |
| `scripts/docs/test-dev-graph.sh` | test | 23 |
| `scripts/eval/console-load-inventory.py` | code | 21, 36, 157, 242 |
| `scripts/eval/test-console-load-inventory.sh` | test | 7, 27, 41 |
| `scripts/handover/console-kit/append-results.sh` | code | 6 |
| `scripts/handover/console-kit/board.mjs` | code | 467, 470, 636 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 2, 10, 11, 105, 146 |
| `scripts/handover/console-kit/console-wait.sh` | code | 39, 801, 802, 809 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5592.md` | fixture | 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6118.md` | fixture | 24 |
| `scripts/handover/console-kit/leg-digest-step.sh` | code | 10, 14 |
| `scripts/handover/console-kit/leg-event.sh` | code | 16, 44, 126 |
| `scripts/handover/console-kit/leg-transcripts.sh` | code | 3, 10, 15 |
| `scripts/handover/console-kit/long-running.txt` | config | 9 |
| `scripts/handover/console-kit/ops-run.sh` | code | 46 |
| `scripts/handover/console-kit/relay-batch.sh` | code | 65 |
| `scripts/handover/console-kit/test-append-results.sh` | test | 6, 12, 83 |
| `scripts/handover/console-kit/test-board.sh` | test | 414 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | test | 2, 3, 36, 231 |
| `scripts/handover/console-kit/test-console-kit-e2e.sh` | test | 3, 5, 12, 125, 183, 189, 201, 211, 216 |
| `scripts/handover/console-kit/test-console-wait-b.sh` | test | 473 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 3, 15, 71, 108, 275 |
| `scripts/handover/console-kit/test-leg-event.sh` | test | 17 |
| `scripts/handover/console-kit/test-live-subagents.sh` | test | 4 |
| `scripts/handover/console-kit/test-wrap-merged.sh` | test | 5, 221 |
| `scripts/handover/console-kit/tick.sh` | code | 408, 2060 |
| `scripts/handover/console-kit/wrap-merged.sh` | code | 15, 58, 122 |
| `scripts/handover/console/chief.sh` | code | 389 |
| `scripts/handover/test-leg-handoff-threshold-docs.sh` | test | 72 |
| `scripts/hooks/end-session-wiki.sh` | code | 73, 157, 269, 370 |
| `scripts/hooks/test-end-session-wiki.sh` | test | 878 |
| `scripts/hooks/test-guard-console-foreground.sh` | test | 89, 208 |
| `scripts/lanes/lane-canary.sh` | code | 18, 63, 68 |
| `scripts/lanes/leg-cost-report.sh` | code | 7 |
| `scripts/lanes/lib/leg-cost-row.sh` | code | 4 |
| `scripts/lib/leg-tail-status.sh` | code | 4, 6 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 323 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 84, 85 |
| `scripts/telegram/README.md` | docs | 96 |
| `scripts/telegram/break-glass.sh` | code | 31, 421 |
| `scripts/telegram/test-break-glass.sh` | test | 7, 303 |
| `scripts/testing/documented-commands.tsv` | config | 77 |

### N19 `console-kit (directory)` to `chief-kit`

Family F8, slice M; directory; owner HIMMEL-6646; 1462 lines in 388 files; new name live 0/1. largest blast radius; rename last. The plan's symlink at the old path is dropped by the no-alias ruling.

Distinct matched strings (1): `console-kit` to `chief-kit`

| File | Class | Lines |
|---|---|---|
| `.claude/agents/judge-ro.md` | docs | 84 |
| `.claude/agents/judge.md` | docs | 84 |
| `.claude/settings.json` | config | 63, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 82, 83, 84, 85, 86, 102, 117 |
| `.github/workflows/pages.yml` | config | 14 |
| `docs/guide/dev-graph/graph.json` | docs | 88, 110, 132, 154, 176, 386, 496, 518, 540, 562, 584, 672, 694, 716, 720, 746, 770, 786, 803, 820, 837, 854, 870, 1000, 1101, 1117, 1133, 1149, 1166, 1183, 1200, 1217, 1234, 1334, 1351, 1367, 1416, 1854, 1889, 1907 |
| `docs/handover/afk-mode.md` | docs | 250 |
| `docs/handover/cloud-brief-template.md` | docs | 29, 253 |
| `docs/handover/console-sections/board-tracker.md` | docs | 134 |
| `docs/handover/console-sections/judge.md` | docs | 14, 21, 48, 59 |
| `docs/handover/console-sections/live-state.md` | docs | 93 |
| `docs/handover/console-sections/merges.md` | docs | 36, 46, 64, 86, 99 |
| `docs/handover/console-sections/monitors.md` | docs | 49 |
| `docs/handover/console-sections/refused-shapes.md` | docs | 9 |
| `docs/handover/console-sections/successor-start.md` | docs | 19 |
| `docs/handover/console-sections/waiter.md` | docs | 11, 18, 120, 121 |
| `docs/handover/console-sections/wrapping.md` | docs | 17, 19, 21, 33, 36, 49, 64 |
| `docs/handover/console-template.md` | docs | 75, 170, 172, 192, 195, 256 |
| `docs/handover/consult-preface.md` | docs | 4, 28 |
| `docs/handover/judge-brief-template.md` | docs | 6, 374, 378 |
| `docs/handover/judge-preface.md` | docs | 5 |
| `docs/handover/lane-canary-brief-template.md` | docs | 17, 18 |
| `docs/handover/leg-brief-template.md` | docs | 7, 37, 139, 221 |
| `docs/handover/leg-preface-claudex.md` | docs | 71 |
| `docs/handover/leg-preface.md` | docs | 5, 31, 82, 129 |
| `docs/handover/leg-sections/succession.md` | docs | 89 |
| `docs/handover/relay-brief-template.md` | docs | 68 |
| `docs/handover/rm-preface.md` | docs | 4, 70 |
| `docs/handover/running-a-console.md` | docs | 121, 135, 164, 242, 246, 282, 285, 295, 296, 297, 328, 370, 394, 406, 424, 446, 490, 516, 623, 624, 625, 626 |
| `docs/handover/verdict-template.md` | docs | 19 |
| `docs/internals/config-layers.md` | docs | 18 |
| `docs/internals/console-ops-lane.md` | docs | 24, 83 |
| `docs/internals/enforcement.md` | docs | 1374, 2748, 3275, 3289, 3305, 3899, 3904, 3994, 4942, 4954, 5071, 5670, 5674 |
| `docs/internals/handover-token-grammar.md` | docs | 40, 41, 52, 60 |
| `docs/internals/headless-modes.md` | docs | 18, 50, 102, 103 |
| `docs/internals/himmel-bus-a2a.md` | docs | 27 |
| `docs/internals/lane-calibration.md` | docs | 486, 490, 494, 767, 768, 777, 832, 935 |
| `docs/internals/leg-context-guard.md` | docs | 29, 30 |
| `docs/internals/macos-local-lane.md` | docs | 79 |
| `docs/internals/pr-snapshot.md` | docs | 33 |
| `docs/internals/retask-channel.md` | docs | 154, 188, 230, 352 |
| `docs/internals/ship-tail-model-free.md` | docs | 10, 11 |
| `docs/internals/stuck-playbook.md` | docs | 225, 669, 780, 790 |
| `docs/internals/validation-gates.md` | docs | 287 |
| `docs/jira-projects.md` | docs | 32 |
| `docs/release/changelog-shape.md` | docs | 25 |
| `docs/release/v1.1.2-notes.md` | docs | 92 |
| `docs/release/versioning-scheme.md` | docs | 37 |
| `docs/setup/cloud-environment.md` | docs | 208 |
| `docs/telegram-bridge.md` | docs | 89 |
| `docs/ui.md` | docs | 14, 15 |
| `marketplace/plugins/himmel-bus/bin/bus` | code | 29 |
| `marketplace/plugins/himmel-bus/lib/a2a.mjs` | code | 6 |
| `marketplace/plugins/himmel-bus/lib/agui.mjs` | code | 7 |
| `marketplace/plugins/himmel-bus/tests/test-agui.mjs` | test | 74, 76 |
| `marketplace/plugins/himmel-bus/tests/test-cli.sh` | test | 15 |
| `marketplace/plugins/himmel-ops/hooks/guard-judge-writes.sh` | code | 24, 134 |
| `marketplace/plugins/himmel-ops/hooks/guard-rm-writes.sh` | code | 40, 391 |
| `scripts/api-lane/judge-call.sh` | code | 134 |
| `scripts/check-ci.sh` | code | 1299 |
| `scripts/chokepoints.json` | config | 11, 29, 38, 41 |
| `scripts/ci/check-run-timelines/testdata/sweep-6122/run-39032362864.json` | config | 1 |
| `scripts/ci/ci-trust-paths.txt` | config | 6, 25, 51, 52 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 5, 6, 7, 8, 27, 28, 52, 53, 77, 78, 96, 97, 98, 124, 125, 126, 146, 172, 173, 174 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 6, 7, 8, 34, 35, 36, 56, 57, 58, 59, 101, 102, 125, 168, 169, 170, 171, 172 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 7, 29, 30, 31, 56, 57, 58, 81, 102, 103, 124, 125, 126, 127, 128, 148, 149, 169, 170, 171, 172 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 212, 213, 214, 215, 216, 217, 218, 219, 220, 221, 222, 223, 224, 225, 226, 227 |
| `scripts/ci/fixtures/tier-replay/catches.tsv` | fixture | 47, 58 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 10, 11, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44 |
| `scripts/ci/fixtures/tier-replay/manifests/39389928341.txt` | fixture | 7, 8, 12 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 7, 8, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44 |
| `scripts/ci/fixtures/tier-replay/manifests/39400326799.txt` | fixture | 2 |
| `scripts/ci/fixtures/tier-replay/manifests/39417925754.txt` | fixture | 14 |
| `scripts/ci/fixtures/tier-replay/manifests/39448373163.txt` | fixture | 8 |
| `scripts/ci/fixtures/tier-replay/manifests/39449037336.txt` | fixture | 68, 69, 70 |
| `scripts/ci/macos-poc-suites.txt` | config | 62, 64, 65, 66, 67, 68 |
| `scripts/ci/pr-job-gates.txt` | config | 37 |
| `scripts/ci/run-shell-tests.sh` | code | 810, 811, 812, 813, 814, 815, 816, 817, 818, 819, 821, 822, 823, 824, 825, 944 |
| `scripts/ci/suite-durations.tsv` | config | 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414, 415, 416, 417, 418, 419, 420 |
| `scripts/ci/suite-tiers.tsv` | config | 340, 341, 342, 343, 344, 345, 346, 347, 348, 349, 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366, 367, 368, 369, 370, 371, 372, 373, 374, 375, 376, 377, 378, 379, 380, 381, 382, 383, 384, 385, 386, 387, 388, 389, 390, 391, 392, 393, 394, 395, 396, 397, 398, 399, 400, 401, 402, 403, 404, 405, 406, 407, 408, 409, 410, 411, 412, 413, 414 |
| `scripts/ci/test-billed-optin.sh` | test | 234 |
| `scripts/ci/test-check-run-timelines.sh` | test | 169 |
| `scripts/ci/test-impacted-selection.sh` | test | 386 |
| `scripts/ci/test-os-verify-workflow.sh` | test | 267, 268, 269, 270 |
| `scripts/ci/test-run-shell-tests.sh` | test | 807, 2490, 2491, 2492, 2493, 2494, 2495, 2496, 2497, 2498, 2499, 2500, 2501, 2502 |
| `scripts/ci/workflow-red-issue.sh` | code | 94 |
| `scripts/codex/test-codex-hook-parity.sh` | test | 176 |
| `scripts/config-ui/agui/board.ts` | code | 13 |
| `scripts/config-ui/agui/fleet.ts` | code | 152 |
| `scripts/config-ui/legs.sh` | code | 38 |
| `scripts/config-ui/roadmap.ts` | code | 3 |
| `scripts/config-ui/server.ts` | code | 536 |
| `scripts/config-ui/tests/test-legs.sh` | test | 10, 21, 24 |
| `scripts/cr/anchor-handoff.sh` | code | 15, 29, 48, 275 |
| `scripts/cr/class-recurrence.sh` | code | 58 |
| `scripts/cr/known-findings.json` | config | 929, 932, 935 |
| `scripts/cr/live-gate-e2e.sh` | code | 64 |
| `scripts/cr/pr-check-context.sh` | code | 782, 786, 787, 788, 812, 814, 815, 845, 847, 848 |
| `scripts/cr/pr-check-ref/30-step3-panel.md` | docs | 40 |
| `scripts/cr/pr-check-ref/32-step3-reviewers.md` | docs | 26 |
| `scripts/cr/review-round.sh` | code | 10, 147, 562, 740, 872, 1228, 1237 |
| `scripts/cr/test-anchor-handoff.sh` | test | 7, 150, 159, 161, 162, 169, 171, 173, 289, 301, 307, 308, 311, 341 |
| `scripts/cr/test-cr-guarded-closure.sh` | test | 116, 249 |
| `scripts/cr/test-impacted-suites.sh` | test | 929, 931, 932, 940, 946 |
| `scripts/cr/test-pr-check-rounds.sh` | test | 1649, 1653, 1654, 1685, 1778, 1818, 1910, 2263, 2279, 3040, 3082 |
| `scripts/cr/test-pr-check-run.sh` | test | 285, 291, 294, 298 |
| `scripts/cr/test-ship-tail-model-free.sh` | test | 16, 17, 65 |
| `scripts/eval/friction/friction.py` | code | 196 |
| `scripts/eval/graphify-ab/tasks.json` | config | 19 |
| `scripts/eval/graphify-ab/truth.py` | code | 62, 64 |
| `scripts/eval/lane-quality/pilot-4869/pilot.sh` | code | 239 |
| `scripts/eval/lane-quality/pilot-4869/sandbox.sh` | code | 295 |
| `scripts/eval/leg-digest/failure-route-notify.sh` | code | 52 |
| `scripts/eval/leg-digest/fixtures/exit-codes.jsonl` | fixture | 14, 16 |
| `scripts/eval/retrieval-eval/questions.jsonl` | code | 11, 31, 74 |
| `scripts/eval/session-retro.py` | code | 5 |
| `scripts/eval/test-console-load-inventory.sh` | test | 27, 46 |
| `scripts/graphify/test-anchor-seeds.sh` | test | 28, 29, 79, 80, 88, 136, 153, 176 |
| `scripts/graphify/test-semantic-seeds.sh` | test | 38, 201, 202 |
| `scripts/guardrails/git-env-baseline.txt` | config | 35, 127, 128, 129, 142 |
| `scripts/guardrails/test-settings-waiter-allow.sh` | test | 65, 70, 76, 100, 101, 103, 104, 106, 107, 109 |
| `scripts/handover/arm-resume.sh` | code | 4604 |
| `scripts/handover/breadcrumb.sh` | code | 253 |
| `scripts/handover/console-kit/ack-denial.sh` | code | 34 |
| `scripts/handover/console-kit/append-results.sh` | code | 2, 168 |
| `scripts/handover/console-kit/board.mjs` | code | 1175 |
| `scripts/handover/console-kit/brief-lint.sh` | code | 2 |
| `scripts/handover/console-kit/bucket-gitleaks.sh` | code | 6 |
| `scripts/handover/console-kit/cancel-runs.sh` | code | 2 |
| `scripts/handover/console-kit/ci-guardrail.sh` | code | 2 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 2, 201, 204 |
| `scripts/handover/console-kit/compacted-check.sh` | code | 2 |
| `scripts/handover/console-kit/cr-disposition.sh` | code | 2 |
| `scripts/handover/console-kit/cut-tag.sh` | code | 2 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-4999-N2802-vault-gitleaks-token-grammar-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6377-N2799-cr-loop-critical-disposition-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6416-N2786-transition-stamps-version-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6476-N2804-leg-api-lane-switch-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6478-N2806-dispatcher-false-collisions-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6479-N2789-behind-main-merge-spelling-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6483-N2791-tracker-lean-sector-parity-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-3832.md` | fixture | 24, 26, 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5217.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5511.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5592.md` | fixture | 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5641.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5689.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5826.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5843.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5856.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5941.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5966.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5973.md` | fixture | 24, 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5977.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5993.md` | fixture | 24, 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6015.md` | fixture | 20, 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6104.md` | fixture | 7, 24, 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6111.md` | fixture | 7, 24, 25, 26, 28 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6114.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6115.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6118.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6119.md` | fixture | 24, 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6120.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6127.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6132.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6266.md` | fixture | 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6303.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6358.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6371.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6381.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6416.md` | fixture | 25, 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6441.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6445.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6461.md` | fixture | 24, 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6462.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6476.md` | fixture | 24, 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6478.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6479.md` | fixture | 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6483.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6484.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6485.md` | fixture | 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6487.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/pr-files.tsv` | fixture | 9, 10, 11, 12, 13, 14, 16, 17, 26, 27, 28, 29, 44, 45, 49, 50 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/prs.tsv` | fixture | 3, 5, 11 |
| `scripts/handover/console-kit/fixtures/doc-reader-agreement/gen.py` | fixture | 173 |
| `scripts/handover/console-kit/focus-chains-links.sh` | code | 2 |
| `scripts/handover/console-kit/focus-refresh.sh` | code | 2 |
| `scripts/handover/console-kit/gen-briefs.py` | code | 384, 416, 546 |
| `scripts/handover/console-kit/go.sh` | code | 2, 89, 113 |
| `scripts/handover/console-kit/grant-round.sh` | code | 3 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 2, 220, 912, 932, 1452, 1843, 2112, 2486 |
| `scripts/handover/console-kit/himmel-gate.sh` | code | 2, 5, 28, 53, 86 |
| `scripts/handover/console-kit/ice-followups.sh` | code | 2 |
| `scripts/handover/console-kit/inbox-send.sh` | code | 46, 205 |
| `scripts/handover/console-kit/launch-cloud.sh` | code | 6 |
| `scripts/handover/console-kit/leg-digest-step.sh` | code | 2, 95 |
| `scripts/handover/console-kit/leg-event.sh` | code | 2, 41 |
| `scripts/handover/console-kit/leg-jira-status.sh` | code | 2 |
| `scripts/handover/console-kit/leg-transcripts.sh` | code | 2 |
| `scripts/handover/console-kit/live-state.sh` | code | 188 |
| `scripts/handover/console-kit/live-subagents.sh` | code | 2 |
| `scripts/handover/console-kit/next-dispatchable.sh` | code | 337 |
| `scripts/handover/console-kit/ops-run.sh` | code | 2 |
| `scripts/handover/console-kit/ready-check.sh` | code | 2 |
| `scripts/handover/console-kit/ready-go.sh` | code | 2 |
| `scripts/handover/console-kit/residual-lines.sh` | code | 2 |
| `scripts/handover/console-kit/run-suite.sh` | code | 9, 10, 11 |
| `scripts/handover/console-kit/shepherd.sh` | code | 2 |
| `scripts/handover/console-kit/smoke-consult-sandbox.sh` | code | 22, 129 |
| `scripts/handover/console-kit/station-sync.sh` | code | 2 |
| `scripts/handover/console-kit/status-drift.sh` | code | 2, 88, 96, 237, 258, 281 |
| `scripts/handover/console-kit/status-sweep.sh` | code | 2 |
| `scripts/handover/console-kit/succession-tracker.sh` | code | 165 |
| `scripts/handover/console-kit/test-ack-denial.sh` | test | 7 |
| `scripts/handover/console-kit/test-action-zero.sh` | test | 8 |
| `scripts/handover/console-kit/test-append-results.sh` | test | 3, 259, 260, 275, 281, 288 |
| `scripts/handover/console-kit/test-brief-lint.sh` | test | 3 |
| `scripts/handover/console-kit/test-cancel-runs.sh` | test | 8, 220, 221, 223 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | test | 2 |
| `scripts/handover/console-kit/test-compacted-check.sh` | test | 3 |
| `scripts/handover/console-kit/test-console-budget.sh` | test | 3 |
| `scripts/handover/console-kit/test-console-kit-e2e.sh` | test | 2, 29, 224 |
| `scripts/handover/console-kit/test-console-wait-b.sh` | test | 18 |
| `scripts/handover/console-kit/test-console-wait-pool.sh` | test | 16 |
| `scripts/handover/console-kit/test-console-wait-r0.sh` | test | 30 |
| `scripts/handover/console-kit/test-console-wait.sh` | test | 15 |
| `scripts/handover/console-kit/test-cr-disposition.sh` | test | 3, 47 |
| `scripts/handover/console-kit/test-cut-tag.sh` | test | 2 |
| `scripts/handover/console-kit/test-denied-launch-alert.sh` | test | 7, 46, 62, 68, 73, 90, 107 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 2, 4, 63, 148 |
| `scripts/handover/console-kit/test-fleet-manifest.sh` | test | 3 |
| `scripts/handover/console-kit/test-focus-chains-links.sh` | test | 10 |
| `scripts/handover/console-kit/test-gen-briefs.sh` | test | 11, 107, 117 |
| `scripts/handover/console-kit/test-gen-judge-brief.sh` | test | 10 |
| `scripts/handover/console-kit/test-gh-read.sh` | test | 91, 105, 110, 124, 125 |
| `scripts/handover/console-kit/test-go.sh` | test | 3, 65, 219, 227, 234, 237, 240, 250, 252, 253, 254, 263, 270, 278 |
| `scripts/handover/console-kit/test-grant-round.sh` | test | 5 |
| `scripts/handover/console-kit/test-handoff-facts.sh` | test | 8 |
| `scripts/handover/console-kit/test-handover-token-grammar.sh` | test | 15 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 3, 1733, 2496, 3384, 3387, 3388, 3389, 3393, 3402, 3418, 3490, 3847, 3916, 3954, 3977 |
| `scripts/handover/console-kit/test-himmel-gate.sh` | test | 2, 37, 39, 48, 58, 112 |
| `scripts/handover/console-kit/test-inbox-audit.sh` | test | 9 |
| `scripts/handover/console-kit/test-inbox-follow.sh` | test | 11 |
| `scripts/handover/console-kit/test-inbox-send.sh` | test | 8 |
| `scripts/handover/console-kit/test-json-writers-final-newline.sh` | test | 2, 11 |
| `scripts/handover/console-kit/test-judge-ladder.sh` | test | 7 |
| `scripts/handover/console-kit/test-launch-cloud.sh` | test | 9 |
| `scripts/handover/console-kit/test-leg-doc-lock.sh` | test | 3, 37, 109 |
| `scripts/handover/console-kit/test-leg-event.sh` | test | 2 |
| `scripts/handover/console-kit/test-leg-jira-status.sh` | test | 3 |
| `scripts/handover/console-kit/test-leg-pretrust.sh` | test | 3 |
| `scripts/handover/console-kit/test-live-state.sh` | test | 3, 146, 152, 160 |
| `scripts/handover/console-kit/test-live-subagents.sh` | test | 2 |
| `scripts/handover/console-kit/test-next-dispatchable.sh` | test | 9, 42, 81, 328, 329, 330, 604, 621, 627, 651 |
| `scripts/handover/console-kit/test-ops-run.sh` | test | 2, 4 |
| `scripts/handover/console-kit/test-orphan-loops.sh` | test | 65, 67, 68 |
| `scripts/handover/console-kit/test-pr-stall.sh` | test | 9 |
| `scripts/handover/console-kit/test-priority-prune.sh` | test | 8 |
| `scripts/handover/console-kit/test-ready-check.sh` | test | 2, 1090, 1091, 1107, 1756, 2152 |
| `scripts/handover/console-kit/test-ready-go.sh` | test | 3, 38 |
| `scripts/handover/console-kit/test-relay-batch.sh` | test | 8 |
| `scripts/handover/console-kit/test-run-suite.sh` | test | 9 |
| `scripts/handover/console-kit/test-shepherd.sh` | test | 6 |
| `scripts/handover/console-kit/test-station-sync.sh` | test | 2 |
| `scripts/handover/console-kit/test-status-drift.sh` | test | 3 |
| `scripts/handover/console-kit/test-stuck-scan.sh` | test | 6 |
| `scripts/handover/console-kit/test-succession-tracker.sh` | test | 10, 127 |
| `scripts/handover/console-kit/test-tick.sh` | test | 563, 1004, 2542, 2544, 2547 |
| `scripts/handover/console-kit/test-vault-status.sh` | test | 7 |
| `scripts/handover/console-kit/test-verdict-go.sh` | test | 3 |
| `scripts/handover/console-kit/test-verdict-retention.sh` | test | 3 |
| `scripts/handover/console-kit/test-version-status-audit.sh` | test | 8 |
| `scripts/handover/console-kit/test-vm-runner.sh` | test | 12, 357 |
| `scripts/handover/console-kit/test-wrap-merged.sh` | test | 3, 219, 221, 222, 223 |
| `scripts/handover/console-kit/test-write-verdict.sh` | test | 5, 258, 265, 278 |
| `scripts/handover/console-kit/testlib-ready-pass.sh` | code | 3 |
| `scripts/handover/console-kit/tick.sh` | code | 26, 52 |
| `scripts/handover/console-kit/ticket-hold.sh` | code | 2 |
| `scripts/handover/console-kit/verdict-go.sh` | code | 2, 75 |
| `scripts/handover/console-kit/verdict-retention.sh` | code | 2 |
| `scripts/handover/console-kit/vm-runner.sh` | code | 43, 342 |
| `scripts/handover/console-kit/wrap-merged.sh` | code | 2, 45 |
| `scripts/handover/console-kit/write-verdict.sh` | code | 2, 324 |
| `scripts/handover/console/chief.sh` | code | 365, 481, 496, 504, 519, 1294, 1967 |
| `scripts/handover/console/test-console.sh` | test | 1575, 1914, 1920, 2100, 2859, 2955 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc127-fix.sh` | fixture | 138, 142, 520 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc4-fix.sh` | fixture | 139, 143, 521 |
| `scripts/handover/headed-arm.sh` | code | 1443 |
| `scripts/handover/merge-on-green.sh` | code | 151, 179, 225, 230, 604, 922, 946, 952, 1062, 2216, 2217 |
| `scripts/handover/test-handover-root-dotenv.sh` | test | 67, 94, 97 |
| `scripts/handover/test-headed-arm.sh` | test | 37, 58, 2205, 2244 |
| `scripts/handover/test-merge-fork-pr.sh` | test | 4, 17, 283, 284, 290 |
| `scripts/handover/test-merge-on-green-jira-end-state.sh` | test | 123, 177 |
| `scripts/handover/test-merge-on-green.sh` | test | 68, 258, 259, 265, 3029, 3050, 3051, 4679, 4680, 4709 |
| `scripts/handover/test-queue-lock.sh` | test | 26 |
| `scripts/handover/wrap-subtree-check.sh` | code | 50 |
| `scripts/himmel-doctor.sh` | code | 3769, 3775, 3787, 3792, 4241, 4443, 4458, 4459 |
| `scripts/hooks/block-chokepoint-env-prefix.sh` | code | 310 |
| `scripts/hooks/block-read-secrets.sh` | code | 987, 1021 |
| `scripts/hooks/block-unresolved-cr-merge.sh` | code | 16 |
| `scripts/hooks/block-worker-askuserquestion.sh` | code | 4 |
| `scripts/hooks/claudex-inbox-hook.sh` | code | 14 |
| `scripts/hooks/console-precompact-snapshot.sh` | code | 4 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/allow-fp-commit-message.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/allow-gate-cd-and.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/allow-gate-compound.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/allow-gate-help-head.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/allow-gate-redirect.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/allow-gate-var-arg.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/deny-catch-go-tail.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/deny-gate-closed-stdout-pipe.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/deny-gate-later-separator.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/deny-gate-relative-dirty.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/deny-gate-repoint-export.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/deny-gate-repoint-prefix.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/guard-pr-check-literal-cmdpos/deny-gate-stdout-to-stderr-pipe.cmd` | fixture | 1 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3573.sh` | fixture | 16 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3585.sh` | fixture | 16 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-himmel-3910.sh` | fixture | 16 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-pin.sh` | fixture | 25 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-rc127-fix.sh` | fixture | 24 |
| `scripts/hooks/fixtures/red-control/block-unresolved-cr-merge.pre-rc4-fix.sh` | fixture | 25 |
| `scripts/hooks/guard-console-foreground.sh` | code | 3, 12, 69, 107, 118, 120, 126 |
| `scripts/hooks/guard-judge-writes.sh` | code | 24, 134 |
| `scripts/hooks/guard-leg-context-handoff.sh` | code | 184, 422, 426, 433 |
| `scripts/hooks/guard-pr-check-literal.sh` | code | 81, 91, 92, 93, 117, 144, 147, 149, 152, 154, 157, 749, 1607, 1973, 2498, 2504, 2609, 2615, 2688, 2689 |
| `scripts/hooks/guard-relay-writes.sh` | code | 18 |
| `scripts/hooks/guard-rm-writes.sh` | code | 40, 391 |
| `scripts/hooks/guard-worker-wakeup.sh` | code | 4 |
| `scripts/hooks/lib-cmdpos-clean.sh` | code | 11, 37, 38, 39, 42, 78 |
| `scripts/hooks/notify-console-on-prompt.sh` | code | 22, 52 |
| `scripts/hooks/permission-allow-gate-shapes.sh` | code | 24 |
| `scripts/hooks/test-block-bank-lift-writes.sh` | test | 302 |
| `scripts/hooks/test-block-chokepoint-env-prefix.sh` | test | 1033, 1043, 1107, 1122, 1123, 1130, 1267, 1268, 1269, 1272, 1273, 1274, 1277, 1279, 1282, 1283, 1284, 1285, 1286, 1291, 1292, 1293, 1297, 1299, 1300, 1301, 1302, 1303, 1306, 1307, 1308, 1309, 1310, 1311, 1313, 1314, 1315, 1316, 1317, 1318, 1319, 1320, 1321, 1322, 1329, 1330, 1333, 1376, 1377, 1378, 1379, 1430, 1431, 1432, 1433, 1434, 1435, 1441, 1443, 1452, 1616, 1661, 1674, 2502, 2514 |
| `scripts/hooks/test-block-read-secrets.sh` | test | 1252, 1257 |
| `scripts/hooks/test-console-precompact-snapshot.sh` | test | 15 |
| `scripts/hooks/test-crlf-boundary.sh` | test | 830, 833 |
| `scripts/hooks/test-guard-console-foreground.sh` | test | 9, 60, 89, 91, 93, 95, 101, 110, 202 |
| `scripts/hooks/test-guard-judge-writes.sh` | test | 103, 108, 111, 141 |
| `scripts/hooks/test-guard-leg-context-handoff.sh` | test | 225, 227, 233, 235, 237, 238, 242, 244, 246, 248, 254, 256, 258, 260, 262, 391, 394, 404, 469 |
| `scripts/hooks/test-guard-pr-check-literal.sh` | test | 40, 61, 63, 64, 65, 66, 251, 256, 258, 263, 265, 266, 278, 280, 287, 295, 296, 297, 298, 299, 302, 305, 306, 307, 309, 310, 311, 314, 315, 316, 318, 319, 346, 418, 501, 585, 586, 587, 588, 728, 771, 777, 839, 1562, 1589, 1621, 1654, 2209, 2347, 2349, 2378, 2383, 2427, 2431, 2462, 2546 |
| `scripts/hooks/test-guard-relay-writes.sh` | test | 138, 139 |
| `scripts/hooks/test-guard-rm-writes.sh` | test | 92, 99, 102, 126 |
| `scripts/hooks/test-log-classifier-denial.sh` | test | 365 |
| `scripts/hooks/test-notify-console-on-prompt.sh` | test | 8, 24, 27 |
| `scripts/hooks/test-permission-allow-gate-shapes.sh` | test | 9, 66, 67, 83 |
| `scripts/lanes/bench/scorecard/agg-postpin.sh` | code | 30 |
| `scripts/lanes/lane-canary.sh` | code | 35 |
| `scripts/lanes/leg-pr-open.sh` | code | 282 |
| `scripts/lanes/plugin-profiles.json` | config | 10, 29, 40 |
| `scripts/lanes/plugin-profiles.mjs` | code | 38, 49 |
| `scripts/lanes/test-lane-canary.sh` | test | 85 |
| `scripts/lanes/tests/cloud-route.test.mjs` | test | 355 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 44, 79, 183, 1482 |
| `scripts/lanes/tests/profile-context-ceiling.test.mjs` | test | 36 |
| `scripts/lanes/tests/settings-allow.test.mjs` | test | 177, 236, 237, 238, 239, 240 |
| `scripts/lib/chief-context.sh` | code | 188 |
| `scripts/lib/coderabbit-trigger-ledger.sh` | code | 76 |
| `scripts/lib/cr-first-release.sh` | code | 54 |
| `scripts/lib/fixtures/cr-body/pr-2549-nitpick-colon.body.txt` | fixture | 90, 91 |
| `scripts/lib/fleet-wrapped.sh` | code | 84 |
| `scripts/lib/gap-audit.sh` | code | 95, 105 |
| `scripts/lib/override-env.sh` | code | 10 |
| `scripts/lib/test-chokepoint-seam-guard.sh` | test | 250 |
| `scripts/lib/test-go-gate.sh` | test | 7, 30, 154, 155, 588, 663 |
| `scripts/lib/ticket-status.sh` | code | 4, 30 |
| `scripts/lint/flag-parity-baseline.tsv` | config | 5, 6, 9 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 309, 310, 311, 312, 313, 314, 315, 316, 317, 318, 319, 320, 321, 322, 323, 324, 325, 326, 327, 328, 329, 330, 331, 332 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128 |
| `scripts/lint/test-shell-lint.sh` | test | 1558 |
| `scripts/macos/test-macos-lane.sh` | test | 89, 92 |
| `scripts/observability/exit-codes.json` | config | 24, 32 |
| `scripts/observability/ledgers.json` | config | 89, 232 |
| `scripts/observability/suite-flake-summary.sh` | code | 4 |
| `scripts/overnight/morning-report.sh` | code | 406 |
| `scripts/parity/test-t13b-daemon-prose.sh` | test | 333 |
| `scripts/telegram/break-glass.sh` | code | 31, 380, 421 |
| `scripts/telegram/console-heartbeat-watch.ts` | code | 3 |
| `scripts/telegram/console-route.test.ts` | test | 410 |
| `scripts/telegram/console-route.ts` | code | 86 |
| `scripts/test-template-verdicts-shellcheck-exclude.sh` | test | 5 |
| `scripts/test-uninstall.sh` | test | 1263, 1269, 1271, 1272, 1275 |
| `scripts/testing/documented-commands.tsv` | config | 38, 39, 51, 60, 66, 67, 74, 75, 76, 77, 79 |
| `scripts/testing/test-mock-consult-sandbox.sh` | test | 80 |
| `scripts/vm/ci-runner/himmel-ci-runner@.service` | code | 3 |
| `templates/luna-second-brain/.pre-commit-config.yaml` | config | 57 |
| `templates/luna-second-brain/CHANGELOG.md` | docs | 195, 555, 556 |
| `templates/luna-second-brain/scripts/test-vault-git.sh` | test | 300, 301, 304, 308, 313, 314, 315, 326 |

### N20 `leg-preface*.md` to `worker-preface*.md`

Family F8, slice T; file name; owner HIMMEL-6644; 180 lines in 48 files; new name live 0/5.

Distinct matched strings (5): `leg-preface` to `worker-preface`, `leg-preface-` to `worker-preface-`, `leg-preface-claudex.md` to `worker-preface-claudex.md`, `leg-preface-openrouter.md` to `worker-preface-openrouter.md`, `leg-preface.md` to `worker-preface.md`

| File | Class | Lines |
|---|---|---|
| `docs/guide/dev-graph/graph.json` | docs | 220, 242, 452, 474, 1930 |
| `docs/handover/console-template.md` | docs | 65 |
| `docs/handover/judge-brief-template.md` | docs | 12 |
| `docs/handover/lane-canary-brief-template.md` | docs | 14 |
| `docs/handover/leg-brief-template.md` | docs | 20, 35, 39, 140, 143 |
| `docs/handover/leg-sections/ci-red.md` | docs | 3 |
| `docs/handover/leg-sections/consult.md` | docs | 3 |
| `docs/handover/leg-sections/context-guard.md` | docs | 3 |
| `docs/handover/leg-sections/shell-and-tests.md` | docs | 3 |
| `docs/handover/leg-sections/succession.md` | docs | 3 |
| `docs/handover/running-a-console.md` | docs | 202, 334 |
| `docs/internals/context-architecture.md` | docs | 156 |
| `docs/internals/enforcement.md` | docs | 4014, 5669 |
| `docs/internals/lane-calibration.md` | docs | 164, 818, 934 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 6, 7 |
| `scripts/cr/test-pr-check-rounds.sh` | test | 380 |
| `scripts/docs/test-dev-graph.sh` | test | 17 |
| `scripts/eval/qmd-quality/fixtures/golden-vocabulary.jsonl` | fixture | 3, 4 |
| `scripts/eval/qmd-quality/golden/himmel.jsonl` | code | 34, 35, 50, 51 |
| `scripts/eval/retrieval-eval/questions.jsonl` | code | 2, 5, 6, 9, 23, 26, 27, 35, 44, 74 |
| `scripts/graphify/test-semantic-seeds.sh` | test | 203, 204 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5966.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6358.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/doc-reader-agreement/gen.py` | fixture | 17 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 116, 136, 138, 139, 635, 782, 1773, 2160, 2198, 2208, 2498 |
| `scripts/handover/console-kit/relay-batch.sh` | code | 10 |
| `scripts/handover/console-kit/test-gen-briefs.sh` | test | 79, 431, 437, 438, 439 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 1322, 1441, 1468, 1470, 1472, 1475, 1476, 1524, 1589, 1590, 1591, 1608, 1625, 1642, 2044, 2048, 2049, 2080, 3196, 3570, 3573, 3601, 4417 |
| `scripts/handover/console-kit/test-tick.sh` | test | 892, 1651, 1658, 1663 |
| `scripts/handover/console-kit/tick.sh` | code | 193, 1033 |
| `scripts/handover/console/test-console.sh` | test | 317 |
| `scripts/handover/merge-forward-check.sh` | code | 333 |
| `scripts/handover/test-friction-gate-docs.sh` | test | 2, 19, 20 |
| `scripts/handover/test-leg-handoff-threshold-docs.sh` | test | 25 |
| `scripts/handover/test-ruling-bullet-docs.sh` | test | 16, 41 |
| `scripts/handover/test-ship-jira-transition-docs.sh` | test | 22, 26, 51, 53, 66, 112, 114 |
| `scripts/handover/test-succession-docs.sh` | test | 20, 59, 63, 68, 69, 71, 72, 74, 76, 77, 78, 79, 80, 83, 85, 90, 95, 97, 98, 108, 110, 279, 373 |
| `scripts/handover/test-thread-resolve-docs.sh` | test | 20, 48, 50 |
| `scripts/handover/test-wrap-subtree-check.sh` | test | 536, 543 |
| `scripts/hooks/guard-worker-wakeup.sh` | code | 8 |
| `scripts/hooks/initiative-runbook.md` | docs | 77 |
| `scripts/lanes/bench/scorecard/memory-traps.json` | config | 10 |
| `scripts/lanes/leg-claude-launcher.sh` | code | 40 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 2067 |
| `scripts/lib/leg-tail-status.sh` | code | 11 |
| `scripts/lint/check-rule-tags.sh` | code | 19, 40 |
| `scripts/testing/documented-commands.tsv` | config | 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66 |
| `scripts/testing/test-documented-commands.sh` | test | 73, 74, 75 |

### N21 `console-template.md` to `chief-template.md`

Family F8, slice T; file name; owner HIMMEL-6644; 79 lines in 39 files; new name live 0/1. console-handoff-template.md has no ruled name (unruled file names).

Distinct matched strings (1): `console-template.md` to `chief-template.md`

| File | Class | Lines |
|---|---|---|
| `.claude/commands/chief.md` | docs | 21 |
| `docs/handover/console-sections/board-tracker.md` | docs | 3 |
| `docs/handover/console-sections/judge.md` | docs | 3 |
| `docs/handover/console-sections/live-state.md` | docs | 3 |
| `docs/handover/console-sections/merges.md` | docs | 3 |
| `docs/handover/console-sections/monitors.md` | docs | 3 |
| `docs/handover/console-sections/refused-shapes.md` | docs | 3 |
| `docs/handover/console-sections/release-manager.md` | docs | 3 |
| `docs/handover/console-sections/successor-start.md` | docs | 3 |
| `docs/handover/console-sections/waiter.md` | docs | 3 |
| `docs/handover/console-sections/weekly-duty.md` | docs | 3 |
| `docs/handover/console-sections/wrapping.md` | docs | 3 |
| `docs/handover/running-a-console.md` | docs | 53, 661 |
| `docs/internals/context-architecture.md` | docs | 157 |
| `marketplace/plugins/himmel-ops/commands/chief.md` | docs | 84 |
| `scripts/eval/qmd-quality/golden/himmel.jsonl` | code | 33, 69 |
| `scripts/guardrails/test-settings-waiter-allow.sh` | test | 2, 20, 67 |
| `scripts/handover/console-kit/action-zero.sh` | code | 3 |
| `scripts/handover/console-kit/append-results.sh` | code | 72 |
| `scripts/handover/console-kit/board.mjs` | code | 31 |
| `scripts/handover/console-kit/compacted-check.sh` | code | 17, 29 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5592.md` | fixture | 25, 29 |
| `scripts/handover/console-kit/live-state.sh` | code | 15 |
| `scripts/handover/console-kit/test-append-results.sh` | test | 126 |
| `scripts/handover/console-kit/test-board.sh` | test | 1332, 1347, 1349 |
| `scripts/handover/console-kit/test-gen-briefs.sh` | test | 431 |
| `scripts/handover/console-kit/test-tick.sh` | test | 998, 1226, 1451, 1500, 1506 |
| `scripts/handover/console/chief.sh` | code | 1292 |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` | test | 75 |
| `scripts/handover/console/test-console.sh` | test | 181, 190, 191, 445, 467, 783, 813, 1796, 2105 |
| `scripts/handover/test-ship-jira-transition-docs.sh` | test | 24, 86 |
| `scripts/handover/test-succession-docs.sh` | test | 22, 163, 209, 210, 211, 253, 304 |
| `scripts/handover/test-thread-resolve-docs.sh` | test | 22 |
| `scripts/lib/leg-identity.sh` | code | 14 |
| `scripts/lint/check-rule-tags.sh` | code | 20, 40 |
| `scripts/lint/flag-parity-baseline.tsv` | config | 6 |
| `scripts/telegram/console-route.ts` | code | 12 |
| `scripts/testing/documented-commands.tsv` | config | 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79 |
| `scripts/testing/test-documented-commands.sh` | test | 77 |

### N22 `leg-brief-template.md` to `worker-brief-template.md`

Family F8, slice T; file name; owner HIMMEL-6644; 28 lines in 23 files; new name live 0/1.

Distinct matched strings (1): `leg-brief-template.md` to `worker-brief-template.md`

| File | Class | Lines |
|---|---|---|
| `docs/handover/cloud-brief-template.md` | docs | 10 |
| `docs/handover/console-template.md` | docs | 145 |
| `docs/handover/judge-brief-template.md` | docs | 16 |
| `docs/handover/running-a-console.md` | docs | 161, 663 |
| `docs/internals/retask-channel.md` | docs | 175 |
| `scripts/eval/qmd-quality/golden/himmel.jsonl` | code | 48 |
| `scripts/graphify/fixtures/rationale-graph.json` | fixture | 11 |
| `scripts/handover/console-kit/brief-lint.sh` | code | 66 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6479-N2789-behind-main-merge-spelling-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6479.md` | fixture | 26, 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/pr-files.tsv` | fixture | 43 |
| `scripts/handover/console-kit/gen-briefs.py` | code | 40 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 817 |
| `scripts/handover/console-kit/test-brief-lint.sh` | test | 156 |
| `scripts/handover/console-kit/test-tick.sh` | test | 1204 |
| `scripts/handover/console-kit/tick.sh` | code | 398 |
| `scripts/handover/console/test-console.sh` | test | 469 |
| `scripts/handover/test-friction-gate-docs.sh` | test | 21 |
| `scripts/handover/test-leg-handoff-threshold-docs.sh` | test | 26 |
| `scripts/handover/test-ship-jira-transition-docs.sh` | test | 23, 78 |
| `scripts/handover/test-wrap-subtree-check.sh` | test | 536, 543 |
| `scripts/lib/leg-identity.sh` | code | 11, 98 |
| `scripts/lib/test-leg-identity.sh` | test | 5 |

### N23 `/console` to `/chief`

Family F9, slice V5; command; owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 132 lines in 34 files; new name live 1/1. /supervisor-session stays a permanent alias of /chief (OD-6).

Distinct matched strings (1): `/console` to `/chief` (live)

| File | Class | Lines |
|---|---|---|
| `.claude/commands/console.md` | docs | 7 |
| `docs/README.md` | docs | 48 |
| `docs/commands-catalog.md` | docs | 45, 147 |
| `docs/guide/installer-journey.html` | docs | 402, 655 |
| `docs/handover/console-sections/monitors.md` | docs | 65 |
| `docs/handover/console-template.md` | docs | 51, 53, 83, 228 |
| `docs/handover/running-a-console.md` | docs | 9, 35, 44, 45, 46, 47, 124, 462 |
| `docs/internals/claude-md-detail.md` | docs | 162 |
| `docs/internals/enforcement.md` | docs | 4907 |
| `docs/release/v1.1.2-notes.md` | docs | 98, 99 |
| `docs/telegram-bridge.md` | docs | 67, 70, 75, 80, 94, 113, 137, 146, 177, 178 |
| `marketplace/plugins/domain-modeling/skills/domain-modeling/GLOSSARY-FORMAT.md` | docs | 28 |
| `marketplace/plugins/himmel-bus/tests/test-identity.mjs` | test | 253, 267, 293, 303 |
| `marketplace/plugins/himmel-ops/scripts/test-console-cmd-resolution.sh` | test | 3 |
| `scripts/config-ui/tests/agui-fleet.test.ts` | test | 228 |
| `scripts/handover/console-kit/console-wait.sh` | code | 16 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-2973.md` | fixture | 25 |
| `scripts/handover/console-kit/test-tick.sh` | test | 1543, 1544, 1546, 1547 |
| `scripts/handover/console/chief.sh` | code | 31, 135, 155, 360, 690, 724 |
| `scripts/handover/console/test-console.sh` | test | 214, 217, 1795, 1798, 1799, 1952 |
| `scripts/handover/test-arm-resume-profile.sh` | test | 73 |
| `scripts/handover/test-hop.sh` | test | 62 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel3148.sh` | fixture | 21, 213 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel4567.sh` | fixture | 12, 226 |
| `scripts/hooks/stop-console-idle-guard.sh` | code | 12, 299 |
| `scripts/hooks/test-stop-console-idle-guard.sh` | test | 146 |
| `scripts/jira/src/commands/version-freeze.test.ts` | test | 275, 403, 442 |
| `scripts/jira/src/release/engine.test.ts` | test | 573 |
| `scripts/lanes/test-profile-settings.sh` | test | 49 |
| `scripts/telegram/console-route.test.ts` | test | 53, 65, 175, 239, 242, 248, 251, 256, 262, 284, 285, 296, 297, 298, 300, 301, 302, 305, 307, 318, 332, 334, 339, 342, 353, 368, 371, 383, 394, 418, 438, 553, 555, 564, 580, 590, 602, 608 |
| `scripts/telegram/console-route.ts` | code | 13, 14, 174, 241 |
| `scripts/telegram/poller.test.ts` | test | 3770, 3772 |
| `scripts/telegram/router.test.ts` | test | 98, 99, 102, 103, 104, 109, 111, 112, 113, 116, 117, 119, 124 |
| `scripts/telegram/router.ts` | code | 74, 82, 90 |

### N24 `console.sh` to `chief.sh`

Family F9, slice V5; script/file name; owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 152 lines in 63 files; new name live 1/1.

Distinct matched strings (1): `console.sh` to `chief.sh` (live)

| File | Class | Lines |
|---|---|---|
| `.claude/settings.json` | config | 68 |
| `docs/handover/console-handoff-template.md` | docs | 48 |
| `docs/handover/console-sections/board-tracker.md` | docs | 21 |
| `docs/handover/console-sections/live-state.md` | docs | 11, 68, 70, 86, 126 |
| `docs/handover/running-a-console.md` | docs | 514 |
| `docs/internals/jira-plugin.md` | docs | 334 |
| `docs/internals/retask-channel.md` | docs | 188, 302 |
| `marketplace/plugins/himmel-ops/commands/chief.md` | docs | 11, 12, 53, 61, 62, 107 |
| `marketplace/plugins/himmel-ops/scripts/test-console-cmd-resolution.sh` | test | 7, 8, 52, 53, 72, 75, 80, 86, 95, 106 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 9 |
| `scripts/config-ui/agui/fleet.ts` | code | 90 |
| `scripts/eval/fixtures/handover-cost/console-p.jsonl` | fixture | 3, 4, 8, 9 |
| `scripts/eval/handover-cost.py` | code | 16, 20, 27, 220 |
| `scripts/eval/test-handover-cost.sh` | test | 66, 102, 107, 115, 119 |
| `scripts/handover/arm-resume.sh` | code | 1035, 2694, 2697 |
| `scripts/handover/console-kit/action-zero.sh` | code | 31 |
| `scripts/handover/console-kit/board.mjs` | code | 316 |
| `scripts/handover/console-kit/console-wait.sh` | code | 191, 1038, 1064 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-4999-N2802-vault-gitleaks-token-grammar-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-2973.md` | fixture | 28 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5966.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6116.md` | fixture | 20, 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6127.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/doc-reader-agreement/gen.py` | fixture | 5 |
| `scripts/handover/console-kit/gen-briefs.py` | code | 55, 125 |
| `scripts/handover/console-kit/handoff-facts.sh` | code | 6 |
| `scripts/handover/console-kit/inbox-audit.sh` | code | 16 |
| `scripts/handover/console-kit/inbox-send.sh` | code | 272, 273 |
| `scripts/handover/console-kit/launch-cloud.sh` | code | 12 |
| `scripts/handover/console-kit/priority-prune.sh` | code | 19 |
| `scripts/handover/console-kit/test-board.sh` | test | 887 |
| `scripts/handover/console-kit/test-console-wait.sh` | test | 185 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 6, 170, 181, 183, 184 |
| `scripts/handover/console-kit/test-handoff-facts.sh` | test | 3 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 31, 450, 3560 |
| `scripts/handover/console-kit/test-live-subagents.sh` | test | 4, 108 |
| `scripts/handover/console-kit/test-tick.sh` | test | 495, 1397 |
| `scripts/handover/console-kit/tick.sh` | code | 1353, 1664 |
| `scripts/handover/console/console-bus-exec.sh` | code | 4 |
| `scripts/handover/console/console.sh` | code | 4, 11 |
| `scripts/handover/console/record-launch.sh` | code | 4 |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` | test | 6, 9, 17, 74, 91, 92 |
| `scripts/handover/console/test-console.sh` | test | 3, 8, 13, 14, 17, 18, 46, 59, 100, 113, 465, 670, 806, 901, 1018, 1173, 1705, 1713, 1804, 1834, 2052, 2088, 2090, 2184, 2227, 2229, 2242, 2246 |
| `scripts/handover/headed-arm.sh` | code | 531, 672 |
| `scripts/handover/test-arm-resume-tier.sh` | test | 313 |
| `scripts/handover/test-queue-lock.sh` | test | 26 |
| `scripts/handover/test-succession-docs.sh` | test | 253 |
| `scripts/hooks/console-precompact-snapshot.sh` | code | 44 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel3148.sh` | fixture | 38 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel4567.sh` | fixture | 42 |
| `scripts/hooks/stop-console-idle-guard.sh` | code | 45, 231 |
| `scripts/hooks/test-stop-console-idle-guard.sh` | test | 61 |
| `scripts/lanes/plugin-profiles.json` | config | 440, 443 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 1762, 1764, 1765 |
| `scripts/lib/chief-context.sh` | code | 9, 126, 193, 194 |
| `scripts/lib/claude-version.sh` | code | 7 |
| `scripts/lib/go-gate.sh` | code | 186, 205 |
| `scripts/lib/rename-aliases.tsv` | config | 345 |
| `scripts/lib/test-leg-identity.sh` | test | 5 |
| `scripts/lib/test-rename-aliases.sh` | test | 315, 324 |
| `scripts/telegram/README.md` | docs | 97 |
| `scripts/telegram/break-glass.sh` | code | 34 |
| `scripts/telegram/test-break-glass.sh` | test | 7, 323 |

### N25 `console-context.sh` to `chief-context.sh`

Family F9, slice V5; script/file name; owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 8 lines in 3 files; new name live 1/1.

Distinct matched strings (1): `console-context.sh` to `chief-context.sh` (live)

| File | Class | Lines |
|---|---|---|
| `scripts/handover/console-kit/fixtures/dispatcher-replay/pr-files.tsv` | fixture | 18 |
| `scripts/lib/rename-aliases.tsv` | config | 342 |
| `scripts/lib/test-rename-aliases.sh` | test | 314, 330, 333, 334, 335, 337 |

### N26 `skill himmel-ops:console` to `himmel-ops:chief`

Family F9, slice V5; skill id; owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 1 lines in 1 files; new name live 0/1. himmel-ops:supervisor-session stays, like /supervisor-session (OD-6).

Distinct matched strings (1): `himmel-ops:console` to `himmel-ops:chief`

| File | Class | Lines |
|---|---|---|
| `marketplace/plugins/himmel-ops/commands/console.md` | docs | 7 |

### N27 `agents console-judge, console-judge-ro` to `judge, judge-ro`

Family F9, slice V5; id (agent); owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 81 lines in 36 files; new name live 2/2. never chief-judge*. <!-- old-term-ok: this page inventories the old names -->

Distinct matched strings (2): `console-judge` to `judge` (live), `console-judge-ro` to `judge-ro` (live)

| File | Class | Lines |
|---|---|---|
| `docs/internals/lane-calibration.md` | docs | 667 |
| `docs/release/v1.1.2-notes.md` | docs | 49 |
| `scripts/ci/test-escape-report-fixtures/jira-bugs.tsv` | test | 12 |
| `scripts/ci/test-escape-report-fixtures/pr-HIMMEL-6957.json` | test | 1 |
| `scripts/ci/test-escape-report.sh` | test | 98 |
| `scripts/config-ui/agui-web/src/fixture.json` | config | 21, 29, 32, 46 |
| `scripts/config-ui/tests/tool-health.test.ts` | test | 224, 226, 242 |
| `scripts/cr/known-findings.json` | config | 308, 358 |
| `scripts/eval/graphify-ab/test-graphify-ab.sh` | test | 25, 43, 98 |
| `scripts/eval/judge-cache-row.sh` | code | 12 |
| `scripts/eval/leg-digest/leg-digest.ts` | code | 43 |
| `scripts/eval/test-judge-cache-row.sh` | test | 33, 36 |
| `scripts/guardrails/agent-model-policy.json` | config | 7, 14 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 187, 464, 470, 472, 475, 501 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | test | 1174, 1188, 1200 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 14, 735, 753, 808, 813, 820, 863, 2677, 2678, 2747, 3809 |
| `scripts/handover/console-kit/test-live-subagents.sh` | test | 38, 63 |
| `scripts/handover/console-kit/test-write-verdict.sh` | test | 6 |
| `scripts/handover/console-kit/write-verdict.sh` | code | 3 |
| `scripts/hooks/guard-agent-model.sh` | code | 4 |
| `scripts/hooks/guard-console-dispatch.sh` | code | 46, 150, 161 |
| `scripts/hooks/guard-implementor-dispatch.sh` | code | 160 |
| `scripts/hooks/test-guard-subagent-model.sh` | test | 139, 140 |
| `scripts/hooks/wire-hook-bash.mjs` | code | 148 |
| `scripts/jira/reconcile-lib.test.mjs` | test | 30 |
| `scripts/lanes/plugin-profiles.json` | config | 150, 420 |
| `scripts/lanes/plugin-profiles.mjs` | code | 578 |
| `scripts/lanes/role-requires.mjs` | code | 37 |
| `scripts/lanes/tests/fixtures/profile-manifests.json` | fixture | 239 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 1319, 1324, 1325, 1328, 1329, 1330, 1331, 1332, 2040, 2047, 2104 |
| `scripts/lanes/tests/profile-lists.test.mjs` | test | 52, 88 |
| `scripts/lanes/tests/pstack-plugin.test.mjs` | test | 36 |
| `scripts/lib/rename-aliases.tsv` | config | 343, 344 |
| `scripts/lib/test-rename-aliases.sh` | test | 563, 564 |
| `scripts/test-tmp-reap.sh` | test | 336 |
| `scripts/tmp-reap.sh` | code | 213 |

### N28 `overnight-shift` to `afk-shift`

Family F10, slice V3; command, directory; owner HIMMEL-6647 (V3 HIMMEL-6638 Done); 9 lines in 7 files; new name live 1/1.

Distinct matched strings (1): `overnight-shift` to `afk-shift` (live)

| File | Class | Lines |
|---|---|---|
| `.claude/commands/overnight-shift.md` | docs | 7 |
| `docs/commands-catalog.md` | docs | 166 |
| `scripts/cr/pr-check-context.sh` | code | 134 |
| `scripts/cr/pr-check-ref/31-step3-adjudicate.md` | docs | 17 |
| `scripts/cr/test-pr-check-context.sh` | test | 1004, 1382 |
| `scripts/lib/rename-aliases.tsv` | config | 355 |
| `scripts/lib/test-rename-aliases.sh` | test | 99, 175 |

### N29 `overnight-mode.md` to `afk-mode.md`

Family F10, slice V3; file name; owner HIMMEL-6647 (V3 HIMMEL-6638 Done); 5 lines in 4 files; new name live 1/1.

Distinct matched strings (1): `overnight-mode.md` to `afk-mode.md` (live)

| File | Class | Lines |
|---|---|---|
| `scripts/hooks/test-block-tail-pipe-on-gates.sh` | test | 1066 |
| `scripts/lanes/tests/cloud-route.test.mjs` | test | 355 |
| `scripts/lib/rename-aliases.tsv` | config | 354 |
| `scripts/lib/test-rename-aliases.sh` | test | 98, 176 |

### N30 `OVERNIGHT_*, OVERNIGHT, HIMMEL_OVERNIGHT, HIMMEL_INITIATIVE_OVERNIGHT, IL_OVERNIGHT_ALL` to `AFK_*, AFK, HIMMEL_AFK, HIMMEL_INITIATIVE_AFK, IL_AFK_ALL`

Family F10, slice V3; env var; owner HIMMEL-6647 (V3 HIMMEL-6638 Done); 106 lines in 31 files; new name live 11/13.

Distinct matched strings (13): `HIMMEL_INITIATIVE_OVERNIGHT` to `HIMMEL_INITIATIVE_AFK` (live), `HIMMEL_OVERNIGHT` to `HIMMEL_AFK` (live), `IL_OVERNIGHT_ALL` to `IL_AFK_ALL`, `OVERNIGHT` to `AFK` (live), `OVERNIGHT_` to `AFK_` (live), `OVERNIGHT_DOC` to `AFK_DOC` (live), `OVERNIGHT_FOO` to `AFK_FOO`, `OVERNIGHT_LIMIT` to `AFK_LIMIT` (live), `OVERNIGHT_PRIORITY` to `AFK_PRIORITY` (live), `OVERNIGHT_PROJECT` to `AFK_PROJECT` (live), `OVERNIGHT_STATUS` to `AFK_STATUS` (live), `OVERNIGHT_STOP_DIR` to `AFK_STOP_DIR` (live), `_OVERNIGHT` to `_AFK` (live) <!-- old-term-ok: this page inventories the old names -->

| File | Class | Lines |
|---|---|---|
| `.env.example` | config | 177, 178, 179, 356 |
| `docs/configuration.md` | docs | 527, 532, 711, 737, 738, 739 |
| `docs/getting-started.md` | docs | 330, 331 |
| `docs/internals/config-layers.md` | docs | 73 |
| `marketplace/plugins/himmel-ops/README.md` | docs | 95 |
| `marketplace/plugins/himmel-ops/scripts/autonomy-mode.sh` | code | 4, 8 |
| `marketplace/plugins/himmel-ops/scripts/test-autonomy-mode.sh` | test | 8, 17, 18, 19, 20, 21 |
| `marketplace/plugins/himmel-ops/scripts/test-legs.sh` | test | 21 |
| `scripts/codex/hook-smoke-demo.sh` | code | 195, 204, 205 |
| `scripts/docs/check-old-terms.sh` | code | 24, 150 |
| `scripts/docs/test-check-old-terms.sh` | test | 54 |
| `scripts/hooks/initiative-runbook.md` | docs | 3, 103 |
| `scripts/hooks/inject-initiative.sh` | code | 20, 23, 24, 100 |
| `scripts/hooks/jira-nudge-on-end.sh` | code | 130 |
| `scripts/hooks/test-codex-sessionstart-hooks.sh` | test | 65, 66, 69 |
| `scripts/hooks/test-codex-stop-hooks.sh` | test | 113 |
| `scripts/hooks/test-inject-initiative.sh` | test | 289, 290, 299, 301, 302, 305, 306, 427 |
| `scripts/hooks/test-jira-nudge-on-end.sh` | test | 131, 247, 292, 312, 336 |
| `scripts/lib/initiative-legs.sh` | code | 21, 23, 71, 76 |
| `scripts/lib/load-dotenv.sh` | code | 317 |
| `scripts/lib/rename-aliases.tsv` | config | 3, 25, 26, 40, 217, 318, 319, 320, 321, 322, 323, 324 |
| `scripts/lib/test-initiative-legs.sh` | test | 38, 41, 42, 43 |
| `scripts/lib/test-rename-aliases.sh` | test | 31, 32, 40, 90, 91, 92, 93, 94, 95, 96, 97, 108 |
| `scripts/overnight/build-plan.sh` | code | 32, 33, 34, 35, 66 |
| `scripts/overnight/stop-marker.sh` | code | 29, 47 |
| `scripts/overnight/test-build-plan.sh` | test | 189, 191, 192, 194 |
| `scripts/overnight/test-stop-marker.sh` | test | 137, 139 |
| `scripts/telegram/glm-env.test.ts` | test | 133, 134 |
| `scripts/telegram/glm-env.ts` | code | 126, 127 |
| `scripts/telegram/spawn-glm.ts` | code | 1710 |
| `scripts/test-adopt.sh` | test | 90, 93 |

### N31 `watchdog (auto-arm hooks only)` to `auto-relaunch in prose; ids deferred`

Family F11, slice -; word in ids and prose; owner none (deferred); 287 lines in 75 files; deferred. AMBIGUOUS and DEFERRED: the glossary scopes the rename to the auto-arm hooks and names no new id; a wall-clock killer is a run timeout. Per-hit read before any rename.

Distinct matched strings (1): `watchdog` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.agents/skills/handover-arm-resume/SKILL.md` | docs | 27 |
| `.claude/commands/handover-arm-resume.md` | docs | 9, 14 |
| `.env.example` | config | 343, 478, 479, 496, 508 |
| `docs/configuration.md` | docs | 74, 142, 365, 378, 752, 753, 760, 763, 765, 771, 877, 882, 978 |
| `docs/hermes-runbook.md` | docs | 81 |
| `docs/internals/enforcement.md` | docs | 609, 628, 4315, 4364, 4377, 5101 |
| `docs/internals/harness-compat.md` | docs | 599, 603, 637 |
| `docs/internals/hermes-guardrail-parity.md` | docs | 114 |
| `docs/internals/lane-parity.md` | docs | 84 |
| `docs/internals/script-runtime-practices.md` | docs | 154 |
| `docs/internals/stuck-playbook.md` | docs | 32 |
| `docs/internals/testing.md` | docs | 350 |
| `docs/internals/worker-spawn-matrix.md` | docs | 91, 152 |
| `docs/setup/new-machine.md` | docs | 386, 1221 |
| `docs/tooling-catalog.md` | docs | 2029 |
| `marketplace/plugins/himmel-ops/hooks/block-agent-native-egress.sh` | code | 219 |
| `marketplace/plugins/lean-skills/skills/brainstorming/scripts/server.cjs` | code | 558 |
| `marketplace/plugins/lean-skills/skills/brainstorming/scripts/start-server.sh` | code | 164 |
| `marketplace/plugins/obsidian-triage/tests/test-repo-security-scan.sh` | test | 281, 305 |
| `marketplace/plugins/telegram-himmel/server.ts` | code | 693 |
| `scripts/api-lane/claude-api.sh` | code | 209, 231, 267 |
| `scripts/check-plugin-drift.sh` | code | 792, 795, 827, 830, 834, 835, 838 |
| `scripts/ci/check-run-timelines/testdata/sweep-6122/run-39029239710.json` | config | 1 |
| `scripts/ci/orphan-census.sh` | code | 4 |
| `scripts/ci/run-shell-tests.sh` | code | 381, 473, 3543, 4420, 4426, 4431, 4436, 4472, 4490, 4491, 4504, 4509, 4602, 4604, 4612, 4648, 4653, 4934 |
| `scripts/ci/test-run-shell-tests-timing.sh` | test | 3, 5, 38, 44, 149 |
| `scripts/ci/test-run-shell-tests.sh` | test | 443, 444, 2967, 2968 |
| `scripts/ci/test-suite-concurrency.sh` | test | 832, 2692, 2695 |
| `scripts/ci/tmp-sweep.sh` | code | 7 |
| `scripts/codex/dispatch-codex-exec.sh` | code | 91, 92, 255, 266, 937, 939, 941, 944, 953, 957, 964, 968, 971, 995, 1000, 1038, 1044, 1046, 1067 |
| `scripts/codex/test-dispatch-codex-exec.sh` | test | 458, 588, 599, 601, 617, 647, 648, 650, 661, 663, 666, 688, 764, 836, 928, 948 |
| `scripts/cr/critic-panel.sh` | code | 1855 |
| `scripts/cr/known-findings.json` | config | 542 |
| `scripts/cr/test-install-cr-gate.sh` | test | 52, 53 |
| `scripts/graphify/test-refresh-graph-map.sh` | test | 2308 |
| `scripts/handover/arm-resume.sh` | code | 13, 32, 468, 1174, 3795, 3796, 3819 |
| `scripts/handover/console-kit/test-console-wait.sh` | test | 12 |
| `scripts/handover/resume-slot.sh` | code | 37, 64, 85, 134 |
| `scripts/handover/test-arm-resume.sh` | test | 1231, 1915, 2555, 2556, 2558, 5478 |
| `scripts/hermes/assets/parity_guard.py` | code | 41 |
| `scripts/hermes/invoke.sh` | code | 26, 40, 50, 55, 284, 288, 290, 305, 313, 428, 467 |
| `scripts/hermes/test-invoke.sh` | test | 147, 179, 192, 193, 194, 195 |
| `scripts/himmelctl/test/test-wizard-preflight.sh` | test | 225, 265, 271 |
| `scripts/hooks/auto-arm-on-cap.sh` | code | 79, 133, 147, 156, 157, 172, 200, 631, 639, 649, 702, 760, 767, 934 |
| `scripts/hooks/auto-arm-on-subagent-cap.sh` | code | 67, 168, 283 |
| `scripts/hooks/block-rogue-codex-exec.sh` | code | 7, 8, 29, 54 |
| `scripts/hooks/guard-agent-model.sh` | code | 32 |
| `scripts/hooks/refresh-statusline-caches-periodic.sh` | code | 30 |
| `scripts/hooks/test-auto-arm-on-cap.sh` | test | 1048, 1118 |
| `scripts/hooks/test-block-unresolved-cr-merge.sh` | test | 767 |
| `scripts/hooks/test-escape-class-corpus.sh` | test | 172 |
| `scripts/hooks/test-quota-gauge-claude-writer.sh` | test | 9, 16, 30, 185, 188, 200, 212 |
| `scripts/hooks/test-quota-gauge-ledger.sh` | test | 38 |
| `scripts/lanes/await-glm-worker.sh` | code | 125, 164, 193, 217, 266 |
| `scripts/lanes/stop-worker.sh` | code | 14, 15 |
| `scripts/lanes/tests/test-await-liveness.sh` | test | 6, 84, 237 |
| `scripts/lib/py-armor.sh` | code | 31 |
| `scripts/lib/qmd-bounded.sh` | code | 27, 28, 58, 67, 70, 82, 109, 117 |
| `scripts/lib/resolve-hermes-py.sh` | code | 43 |
| `scripts/lib/scheduler-backend.sh` | code | 3 |
| `scripts/lib/telemetry.sh` | code | 19 |
| `scripts/lib/test-bank-preflight.sh` | test | 216, 219, 230, 255, 256, 258, 259 |
| `scripts/lib/test-qmd-bounded.sh` | test | 132, 155, 172 |
| `scripts/parity/test-t13b-relocation.sh` | test | 6 |
| `scripts/statusline/test-usage-cache-contract.sh` | test | 35 |
| `scripts/telegram/README.md` | docs | 620, 627 |
| `scripts/telegram/poller.test.ts` | test | 299, 2760, 2786, 2798 |
| `scripts/telegram/poller.ts` | code | 803, 805, 939, 947, 1045, 2066, 2515 |
| `scripts/telegram/quota-gauge-passivity.test.ts` | test | 26 |
| `scripts/telegram/run.ts` | code | 294 |
| `scripts/telegram/spawn-claudex.test.ts` | test | 2145, 2159, 2163, 2182, 2196, 2251, 2272, 2298 |
| `scripts/telegram/spawn-claudex.ts` | code | 820, 1104, 1110, 1116, 1125, 1175, 1181 |
| `scripts/telegram/spawn-glm.test.ts` | test | 1364, 1372, 1396, 1430, 1460, 1485 |
| `scripts/telegram/spawn-glm.ts` | code | 176, 1206, 1271, 1272, 1291, 1322, 1329, 1409, 1955 |
| `scripts/test-check-plugin-drift.sh` | test | 1070, 1072, 1119, 1120 |

### N32 `class-sweep, missing-class-sweep` to `variant-sweep, missing-variant-sweep`

Family F13, slice V2; id (exit reason), message text; owner HIMMEL-6647 (V2 HIMMEL-6640 Done); 35 lines in 12 files; new name live 2/2. the SWEEP ledger keyword is unchanged.

Distinct matched strings (2): `class-sweep` to `variant-sweep` (live), `missing-class-sweep` to `missing-variant-sweep` (live)

| File | Class | Lines |
|---|---|---|
| `docs/internals/lane-calibration.md` | docs | 264, 295, 302 |
| `scripts/api-lane/bulk-call.sh` | code | 3, 195 |
| `scripts/cr/clear-review-marker.sh` | code | 70, 545, 1421, 1443, 1444 |
| `scripts/cr/test-clear-cr-marker.sh` | test | 301, 302, 303, 2678, 2817, 2819 |
| `scripts/cr/test-write-verdicts.sh` | test | 200, 207, 220, 240, 244 |
| `scripts/cr/write-verdicts.sh` | code | 65, 166 |
| `scripts/eval/lane-quality/tasks/class-sweep/accept.sh` | code | 2 |
| `scripts/eval/lane-quality/test-lane-quality.sh` | test | 41, 74, 180, 224, 231, 243 |
| `scripts/eval/leg-digest/fixtures/bash-errors.jsonl` | fixture | 33 |
| `scripts/lib/rename-aliases.tsv` | config | 39 |
| `scripts/lib/test-rename-aliases.sh` | test | 294, 305 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 216 |

### N33 `speed bump` to `soft block`

Family F14, slice D; message text; owner HIMMEL-6645; 12 lines in 9 files; new name live 1/1. text only; tests may grep it.

Distinct matched strings (1): `speed bump` to `soft block` (live)

| File | Class | Lines |
|---|---|---|
| `docs/internals/egress-matrix.md` | docs | 255 |
| `docs/internals/enforcement.md` | docs | 5853 |
| `docs/internals/retask-channel.md` | docs | 379 |
| `scripts/handover/test-retask-doc-bus.sh` | test | 5, 40 |
| `scripts/himmelctl/lib/bypass-flags.json` | config | 25 |
| `scripts/hooks/guard-bus-store.sh` | code | 43, 371 |
| `scripts/hooks/run-hook-with-bash.test.mjs` | test | 2551 |
| `scripts/hooks/test-block-himmel-config-writes.sh` | test | 3 |
| `scripts/hooks/test-guard-bus-store.sh` | test | 3, 351 |

### N34 `tick fields legs=, legset=, bank=` to `workers=, workerset=, usage=`

Family F16, slice T; id (tick field); owner HIMMEL-6644; 203 lines in 42 files; new name live 2/3. AMBIGUOUS: also matches shell variables named bank or legs; tails= and parked= keep their names. <!-- old-term-ok: this page inventories the old names -->

Distinct matched strings (3): `bank=` to `usage=` (live), `legs=` to `workers=` (live), `legset=` to `workerset=`

| File | Class | Lines |
|---|---|---|
| `docs/handover/console-sections/live-state.md` | docs | 33 |
| `docs/handover/console-sections/monitors.md` | docs | 61 |
| `docs/handover/console-sections/waiter.md` | docs | 15, 31, 36, 73, 76, 90 |
| `docs/handover/running-a-console.md` | docs | 270 |
| `docs/internals/enforcement.md` | docs | 4929 |
| `docs/internals/lane-calibration.md` | docs | 38 |
| `scripts/codex/hook-smoke-demo.sh` | code | 436 |
| `scripts/cr/hermes-critic.sh` | code | 313 |
| `scripts/eval/handover-cost.py` | code | 34, 213, 225 |
| `scripts/eval/leg-digest/failure_review.py` | code | 69 |
| `scripts/eval/leg-digest/failure_router.py` | code | 90, 464, 498 |
| `scripts/eval/leg-digest/leg_ledger.py` | code | 551 |
| `scripts/eval/leg-digest/test-failure-router.sh` | test | 401 |
| `scripts/eval/leg-digest/test-leg-ledger.sh` | test | 119, 175 |
| `scripts/eval/test-handover-cost.sh` | test | 32, 41, 67, 82 |
| `scripts/eval/test-weekly-rollup.sh` | test | 213 |
| `scripts/eval/weekly-rollup.py` | code | 334 |
| `scripts/handover/console-kit/board.mjs` | code | 198, 663 |
| `scripts/handover/console-kit/console-wait.sh` | code | 20, 86, 88, 370, 411, 450, 940, 1152 |
| `scripts/handover/console-kit/gen-briefs.py` | code | 475 |
| `scripts/handover/console-kit/leg-event.sh` | code | 103, 108 |
| `scripts/handover/console-kit/test-board.sh` | test | 67, 708, 721, 1042 |
| `scripts/handover/console-kit/test-compacted-check.sh` | test | 41 |
| `scripts/handover/console-kit/test-console-wait-b.sh` | test | 86, 138, 160, 172, 211, 235, 240, 270, 282, 294, 374, 799 |
| `scripts/handover/console-kit/test-console-wait-pool.sh` | test | 41 |
| `scripts/handover/console-kit/test-console-wait-r0.sh` | test | 90, 176, 214, 237, 252, 266, 286, 297 |
| `scripts/handover/console-kit/test-console-wait.sh` | test | 82, 123, 142, 176, 177, 234, 256, 318, 329, 532, 544, 604, 649, 684, 701, 729, 764 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 13, 81, 83, 84, 155 |
| `scripts/handover/console-kit/test-handoff-facts.sh` | test | 72 |
| `scripts/handover/console-kit/test-tick-deadwin.sh` | test | 150 |
| `scripts/handover/console-kit/test-tick-holds.sh` | test | 77, 79 |
| `scripts/handover/console-kit/test-tick-nolive.sh` | test | 4, 72, 75, 165, 176 |
| `scripts/handover/console-kit/test-tick.sh` | test | 436, 446, 447, 448, 479, 559, 561, 562, 571, 573, 574, 578, 581, 583, 602, 606, 607, 610, 613, 633, 634, 640, 645, 648, 652, 855, 865, 867, 868, 871, 874, 967, 969, 1015, 1028, 1208, 1223, 1244, 1251, 1299, 1336, 1345, 1371, 1409, 1490, 1541, 1542, 1556, 1558, 1579, 1581, 1595, 1604, 1606, 1611, 1614, 1717, 1720, 1725, 1729, 1730, 1756, 1812, 1834, 1842, 1856, 1867, 1871, 2283, 2285, 2287, 2641, 2651 |
| `scripts/handover/console-kit/tick.sh` | code | 62, 151, 156, 169, 176, 575, 829, 979, 1127, 1129, 1132, 1759, 2104, 2108 |
| `scripts/handover/console-kit/tracker.py` | code | 1075 |
| `scripts/hooks/console-precompact-snapshot.sh` | code | 21, 150 |
| `scripts/hooks/test-console-precompact-snapshot.sh` | test | 84, 126, 144 |
| `scripts/lib/leg-identity.sh` | code | 6 |
| `scripts/observability/flow-exporter.test.ts` | test | 943, 944, 945, 946, 970, 971 |
| `scripts/observability/test-suite-flake-summary.sh` | test | 101 |
| `scripts/plugin-eval-preflight.sh` | code | 14 |
| `scripts/telegram/break-glass.sh` | code | 167 |

### N35 `hooks block-leg-askuserquestion.sh, guard-leg-wakeup.sh` to `block-worker-askuserquestion.sh, guard-worker-wakeup.sh`

Family F17, slice V4a; script/file name (hook); owner HIMMEL-7139 (settings switch), then HIMMEL-6647 (forwarders); 29 lines in 18 files; new name live 4/4. registered in .claude/settings.json: operator edit.

Distinct matched strings (4): `block-leg-askuserquestion.sh` to `block-worker-askuserquestion.sh` (live), `guard-leg-wakeup.sh` to `guard-worker-wakeup.sh` (live), `test-block-leg-askuserquestion.sh` to `test-block-worker-askuserquestion.sh` (live), `test-guard-leg-wakeup.sh` to `test-guard-worker-wakeup.sh` (live)

| File | Class | Lines |
|---|---|---|
| `.claude/settings.json` | config | 277, 287 |
| `docs/handover/running-a-console.md` | docs | 224 |
| `docs/internals/enforcement.md` | docs | 3990, 4009, 4134, 4162 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 346, 419 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 61 |
| `scripts/cloud/parity-probe.sh` | code | 125, 126 |
| `scripts/hooks/block-leg-askuserquestion.sh` | code | 2 |
| `scripts/hooks/block-worker-askuserquestion.sh` | code | 20 |
| `scripts/hooks/guard-agent-model.sh` | code | 32, 46 |
| `scripts/hooks/guard-bus-store.sh` | code | 94 |
| `scripts/hooks/guard-leg-context-handoff.sh` | code | 110 |
| `scripts/hooks/guard-leg-wakeup.sh` | code | 2 |
| `scripts/hooks/guard-worker-wakeup.sh` | code | 20 |
| `scripts/hooks/read-clamp.sh` | code | 36 |
| `scripts/hooks/test-block-worker-askuserquestion.sh` | test | 7, 80 |
| `scripts/hooks/test-guard-worker-wakeup.sh` | test | 9, 105 |
| `scripts/hooks/wire-hook-bash.mjs` | code | 142, 146 |
| `scripts/testing/unwired-hooks-allowlist.txt` | config | 26, 27 |

### N36 `hooks console-compact-reinject.sh, guard-console-foreground.sh` to `chief-compact-reinject.sh, guard-chief-foreground.sh`

Family F17, slice V5; script/file name (hook); owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 39 lines in 23 files; new name live 0/2; 2 without a ruled name. registered in .claude/settings.json: operator edit.

Distinct matched strings (4): `console-compact-reinject.sh` to `chief-compact-reinject.sh`, `guard-console-foreground.sh` to `guard-chief-foreground.sh`, `test-console-compact-reinject.sh` (no ruled name), `test-guard-console-foreground.sh` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.claude/settings.json` | config | 516 |
| `docs/handover/running-a-console.md` | docs | 57 |
| `docs/internals/console-ops-lane.md` | docs | 76 |
| `docs/internals/enforcement.md` | docs | 3897, 3913 |
| `marketplace/plugins/himmel-ops/hooks/hooks.json` | config | 119 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 408 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 58, 59 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 51 |
| `scripts/ci/suite-durations.tsv` | config | 654, 669 |
| `scripts/ci/suite-tiers.tsv` | config | 654, 669 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5973.md` | fixture | 24, 28 |
| `scripts/handover/console-kit/long-running.txt` | config | 2 |
| `scripts/handover/test-handover-root-dotenv.sh` | test | 95, 108 |
| `scripts/himmelctl/lib/bypass-flags.json` | config | 63, 65, 95, 97 |
| `scripts/hooks/console-compact-reinject.sh` | code | 2 |
| `scripts/hooks/console-precompact-snapshot.sh` | code | 7, 47 |
| `scripts/hooks/guard-console-foreground.sh` | code | 2, 62 |
| `scripts/hooks/test-console-compact-reinject.sh` | test | 2, 14 |
| `scripts/hooks/test-crlf-boundary.sh` | test | 826 |
| `scripts/hooks/test-guard-console-foreground.sh` | test | 2, 4, 8 |
| `scripts/hooks/wire-hook-bash.mjs` | code | 227 |
| `scripts/hooks/wire-plugin-hook-bash.mjs` | code | 45 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 275, 288, 289 |

### N37 `other upper-case names holding BANK (script-local and test names)` to `BANK to USAGE in place (plan row 66); exact rows per the registry`

Family F3, slice V1; env var, script-local name; owner HIMMEL-6647 (V1 HIMMEL-6639 Done); 494 lines in 94 files; new name live 8/10; 36 without a ruled name. registry rows with a concrete new name (HIMMEL_STOP_GUARD_BANK_PREFLIGHT, BANK_STATE_FILE, BANK_CACHE_FILE, BANK_SAMPLES_FILE, IMPL_GUARD_BANK_*, BOARD_BANK_LIFT) take it; the rest read pending-N2892 and take BANK to USAGE in place. <!-- old-term-ok: this page inventories the old names -->

Distinct matched strings (46): `ACTION_ZERO_BANK` (no ruled name), `ACTION_ZERO_BANK_TIMEOUT` (no ruled name), `ARM_BANK_PREFLIGHT` (no ruled name), `BANK` (no ruled name), `BANK_AFTER_RC` (no ruled name), `BANK_ATTRIBUTION_SCRIPT` (no ruled name), `BANK_BEFORE_RC` (no ruled name), `BANK_BOTH_SPENT_CMD` (no ruled name), `BANK_CACHE` (no ruled name), `BANK_CACHE_FILE` to `USAGE_MONITOR_CACHE_FILE` (live), `BANK_CHECK_EVERY` (no ruled name), `BANK_CLAUDEX_SPENT_CMD` (no ruled name), `BANK_CLAUDEX_UNKNOWN_CMD` (no ruled name), `BANK_FUNDED_CMD` (no ruled name), `BANK_GARBAGE_CMD` (no ruled name), `BANK_HANG_CMD` (no ruled name), `BANK_IDS` (no ruled name), `BANK_LINE` (no ruled name), `BANK_NOW_EPOCH` (no ruled name), `BANK_NOW_HM` (no ruled name), `BANK_PREFLIGHT` (no ruled name), `BANK_PREFLIGHT_SH` (no ruled name), `BANK_PRODUCER_LOG` (no ruled name), `BANK_SAMPLES_FILE` to `USAGE_MONITOR_SAMPLES_FILE` (live), `BANK_STATE_FILE` to `USAGE_MONITOR_STATE_FILE` (live), `BANK_STATUS` (no ruled name), `BANK_STUB_ROW_FILE` (no ruled name), `BANK_VERDICT` (no ruled name), `BOARD_BANK_LIFT` to `BOARD_USAGE_LIFT` (live), `BREAK_GLASS_BANK_CMD` (no ruled name), `CONSOLE_WAIT_BANK` to `CHIEF_WAIT_USAGE` (live), `FAKE_REPO_NO_BANK` (no ruled name), `FLEET_BANK` (no ruled name), `HANDOFF_FACTS_BANK` (no ruled name), `HIMMEL_CODEX_BANK_START` (no ruled name), `HIMMEL_STOP_GUARD_BANK_PREFLIGHT` to `HIMMEL_STOP_GUARD_USAGE_PREFLIGHT` (live), `IMPL_GUARD_BANK_BUDGET_SECS` to `IMPL_GUARD_USAGE_BUDGET_SECS` (live), `IMPL_GUARD_BANK_STATUS_CMD` to `IMPL_GUARD_USAGE_STATUS_CMD` (live), `LANE_BANK_GATE` (no ruled name), `NEW_BANK_THING` to `NEW_USAGE_THING`, `OTHER_BANK_FUNDED_MAX_PCT` (no ruled name), `PIPELINE_BANK` (no ruled name), `SKIPPED_BANK_PREFLIGHT` (no ruled name), `STUB_BANK_ROW` (no ruled name), `TICK_BANK_CACHE_FILE` (no ruled name), `_ARM_BANK_PREFLIGHT` to `_ARM_USAGE_PREFLIGHT` <!-- old-term-ok: this page inventories the old names -->

| File | Class | Lines |
|---|---|---|
| `docs/adoption-trail.html` | docs | 822 |
| `docs/guide/dev-graph/graph.json` | docs | 787 |
| `docs/handover/console-handoff-template.md` | docs | 7 |
| `docs/handover/console-sections/main-red.md` | docs | 36 |
| `docs/handover/running-a-console.md` | docs | 570, 580 |
| `docs/hermes-runbook.md` | docs | 203 |
| `docs/internals/enforcement.md` | docs | 4911 |
| `docs/internals/harness-compat.md` | docs | 99 |
| `docs/internals/lane-calibration.md` | docs | 37 |
| `scripts/api-lane/claude-api.sh` | code | 144, 147, 148 |
| `scripts/claude-codex` | code | 900 |
| `scripts/codex/hook-smoke-demo.sh` | code | 421, 435, 436, 469 |
| `scripts/codex/test-hook-smoke-demo.sh` | test | 176 |
| `scripts/config-ui/agui/lane.ts` | code | 53, 67, 71 |
| `scripts/config-ui/tests/agui-fleet.test.ts` | test | 419 |
| `scripts/config-ui/tests/agui-lane.test.ts` | test | 48, 49 |
| `scripts/cr/hermes-critic.sh` | code | 310 |
| `scripts/cr/test-hermes-critic.sh` | test | 158, 161 |
| `scripts/docs/check-old-terms.sh` | code | 24, 150 |
| `scripts/docs/test-check-old-terms.sh` | test | 53 |
| `scripts/eval/graphify-ab/run.sh` | code | 24, 120 |
| `scripts/eval/graphify-ab/test-graphify-ab.sh` | test | 51, 67, 72, 78 |
| `scripts/eval/lane-quality/run.sh` | code | 153 |
| `scripts/eval/retrieval-eval/answer-ab.py` | code | 38, 117 |
| `scripts/eval/retrieval-eval/test-answer-ab.sh` | test | 66, 97 |
| `scripts/graphify/refresh-graph-map.sh` | code | 2264 |
| `scripts/graphify/test-refresh-graph-map-lock.sh` | test | 28 |
| `scripts/graphify/test-refresh-graph-map.sh` | test | 42 |
| `scripts/handover/arm-resume.sh` | code | 1306, 1333, 1334, 1357, 1365 |
| `scripts/handover/console-kit/action-zero.sh` | code | 12, 38, 39, 70, 93, 94 |
| `scripts/handover/console-kit/board.mjs` | code | 589, 592 |
| `scripts/handover/console-kit/console-wait.sh` | code | 231, 393 |
| `scripts/handover/console-kit/fleet.mjs` | code | 112, 373 |
| `scripts/handover/console-kit/handoff-facts.sh` | code | 23, 64, 65 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 636, 645, 656, 1681, 2424, 2425, 2426, 2442 |
| `scripts/handover/console-kit/test-action-zero.sh` | test | 4, 27, 30, 71, 74 |
| `scripts/handover/console-kit/test-board.sh` | test | 938, 944, 945, 946, 947 |
| `scripts/handover/console-kit/test-console-kit-e2e.sh` | test | 68 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 159, 176 |
| `scripts/handover/console-kit/test-fleet.sh` | test | 7, 220, 308, 426 |
| `scripts/handover/console-kit/test-handoff-facts.sh` | test | 60, 61, 66 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 289, 297, 303, 304, 1075, 2468 |
| `scripts/handover/console-kit/test-tick-busedge.sh` | test | 56 |
| `scripts/handover/console-kit/test-tick-deadwin.sh` | test | 60, 146 |
| `scripts/handover/console-kit/test-tick-holds.sh` | test | 62 |
| `scripts/handover/console-kit/test-tick-nolive.sh` | test | 58, 172 |
| `scripts/handover/console-kit/test-tick.sh` | test | 159, 205, 477, 2285 |
| `scripts/handover/console-kit/tick.sh` | code | 1735, 2107 |
| `scripts/handover/console/chief.sh` | code | 1983 |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` | test | 32 |
| `scripts/handover/console/test-console.sh` | test | 69, 1574, 2859, 2864 |
| `scripts/handover/test-arm-resume-bank-refresh.sh` | test | 13 |
| `scripts/handover/test-arm-resume.sh` | test | 266, 267, 270, 1556, 1560, 6633, 6636, 6638 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel3148.sh` | fixture | 77, 78, 176 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel4567.sh` | fixture | 81, 82, 180 |
| `scripts/hooks/guard-implementor-dispatch.sh` | code | 48, 49, 442, 443 |
| `scripts/hooks/stop-console-idle-guard.sh` | code | 84, 85, 86, 187 |
| `scripts/hooks/test-block-bank-lift-writes.sh` | test | 152 |
| `scripts/hooks/test-guard-implementor-dispatch.sh` | test | 56, 57, 58, 59, 60, 61, 62, 63, 156, 164, 165, 166, 167, 168, 169, 285, 1102, 1111, 1116, 1122, 1130, 1136, 1142, 1147, 1152, 1203 |
| `scripts/hooks/test-stop-console-idle-guard.sh` | test | 180, 186, 245, 350 |
| `scripts/lanes/bench/run-batch.sh` | code | 81, 98, 200 |
| `scripts/lanes/funded-max-pct.mjs` | code | 42, 47 |
| `scripts/lanes/lane-readiness.mjs` | code | 5 |
| `scripts/lanes/resolve.mjs` | code | 154 |
| `scripts/lanes/tests/bank-status.test.mjs` | test | 19, 104, 120, 153, 178, 384, 403, 422, 436, 466, 512, 533, 555, 632, 634 |
| `scripts/lanes/tests/codex-bank-probe.test.mjs` | test | 19, 251, 257, 269, 296 |
| `scripts/lanes/usage-status.ts` | code | 63, 272 |
| `scripts/lib/api-credit-state.mjs` | code | 74, 157, 254, 360, 363, 413, 491, 568, 589, 597, 604 |
| `scripts/lib/api-credit-state.test.mjs` | test | 14, 57, 71, 110, 111, 113, 114, 115, 116, 117, 118, 119, 120, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 145, 149, 181, 188, 190, 205, 210, 225, 226, 239, 254, 255, 260, 268, 276, 282, 301, 309, 314, 333, 479, 487, 516, 576 |
| `scripts/lib/claude-headless.sh` | code | 595, 596 |
| `scripts/lib/rename-aliases.tsv` | config | 3, 55, 56, 57, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 161, 187, 189, 191, 207, 215, 218, 219, 220, 317, 325, 330, 331, 332 |
| `scripts/lib/test-bank-attribution.sh` | test | 23, 26 |
| `scripts/lib/test-bank-monitor.sh` | test | 26, 32, 33, 34, 52, 53, 56, 63, 69, 83, 85, 86, 88, 99, 106, 111, 112, 114, 116, 117, 120, 124, 125, 128, 136, 142, 144, 152, 155, 157, 158, 162, 165, 166, 169, 171, 184, 185, 189, 220, 228, 229, 230, 232, 233, 235, 237, 239, 241, 245, 249, 252, 253, 254, 258, 266, 267, 271, 287, 288, 289, 291, 292, 294, 295, 297, 300, 303 |
| `scripts/lib/test-bank-preflight-fleet.sh` | test | 69 |
| `scripts/lib/test-bank-preflight-openrouter.sh` | test | 35, 37 |
| `scripts/lib/test-bank-preflight.sh` | test | 75, 77, 79, 81, 83, 85, 87, 91, 98, 109, 141, 142, 143, 149, 157, 164, 176, 181, 184, 188, 206, 209, 797, 1058, 1060, 1062 |
| `scripts/lib/test-claude-headless-live.sh` | test | 20, 21, 22 |
| `scripts/lib/test-claude-headless-trap.sh` | test | 86, 87, 89, 167 |
| `scripts/lib/test-claude-headless.sh` | test | 33, 34, 36, 167 |
| `scripts/lib/test-rename-aliases.sh` | test | 117, 128, 135, 136, 137, 155, 156, 157, 374 |
| `scripts/lib/usage-monitor.sh` | code | 17, 18, 19, 21, 22, 25, 41, 42, 53, 55, 56, 257 |
| `scripts/lib/usage-preflight.sh` | code | 9, 91, 1145, 1147, 1148, 1168, 1214, 1215, 1219, 1227, 1228, 1242, 1257, 1261, 1272, 1277, 1282, 1287 |
| `scripts/luna/pipeline-cadence.sh` | code | 119, 122, 706, 708, 710, 714, 1295, 1306, 1307, 1828, 2070 |
| `scripts/luna/test-pipeline-cadence.sh` | test | 150 |
| `scripts/observability/quota-sources.ts` | code | 11, 12, 237 |
| `scripts/probes/claude-p/07-settings-overlay-hooks.sh` | code | 43, 44, 45, 46 |
| `scripts/probes/claude-p/run-all.sh` | code | 21, 22, 23, 67, 68, 69 |
| `scripts/statusline/test-usage-cache-contract.sh` | test | 54, 253, 297, 305 |
| `scripts/telegram/break-glass.sh` | code | 64, 167 |
| `scripts/telegram/console-route.test.ts` | test | 411 |
| `scripts/telegram/test-break-glass.sh` | test | 84, 104 |
| `scripts/usage/test-usage.sh` | test | 11, 62 |
| `scripts/usage/usage-compute.sh` | code | 30, 123 |
| `site/src/trail/levels.json` | config | 195 |

### N38 `upper-case names with LEG inside (CLOSE_WRAPPED_LEG_*, RUN_LEG_*, ARM_SPLIT_LEG_*, M_LEG_*, ...)` to `pending-N2892: no ruled name`

Family F2, slice V4a; env var, script-local name; owner HIMMEL-7139; 169 lines in 27 files; new name live 1/1; 35 without a ruled name. plan row 66 renames script-local names in place in the owning slice; the registry has no new name yet.

Distinct matched strings (36): `ARM_SPLIT_LEG_OK` (no ruled name), `ARM_SPLIT_LEG_WINDOW_SEC` (no ruled name), `BREAK_GLASS_LEG_CMD` (no ruled name), `BROKEN_GOGATE_LEG_ERR` (no ruled name), `BROKEN_GOGATE_LEG_OUT` (no ruled name), `CLOSE_WRAPPED_LEG_` (no ruled name), `CLOSE_WRAPPED_LEG_CUSTOMTITLE_HEAD` (no ruled name), `CLOSE_WRAPPED_LEG_DIGEST_TIMEOUT` (no ruled name), `CLOSE_WRAPPED_LEG_MTIME_DAYS` (no ruled name), `CLOSE_WRAPPED_LEG_PROJECTS_DIR` (no ruled name), `CLOSE_WRAPPED_LEG_PRUNE_RETRIES` (no ruled name), `CLOSE_WRAPPED_LEG_PRUNE_WAIT` (no ruled name), `CLOSE_WRAPPED_LEG_REAP_WAIT` (no ruled name), `CLOSE_WRAPPED_LEG_SESSIONS_DIR` (no ruled name), `CMDLINE_LEG` (no ruled name), `CMDLINE_LEG_LEAK` (no ruled name), `CONSOLE_WAIT_LEG_EVENT` to `CHIEF_WAIT_WORKER_EVENT` (live), `EXPECT_LEG` (no ruled name), `EXPECT_LEG_B` (no ruled name), `EXTERNAL_LEG_DOC` (no ruled name), `HANDOVER_LEG_SPLIT_OK` (no ruled name), `MODEL_FLAG_BY_LEG` (no ruled name), `M_LEG_C` (no ruled name), `M_LEG_D` (no ruled name), `M_LEG_E1` (no ruled name), `M_LEG_E2` (no ruled name), `M_LEG_F` (no ruled name), `N_LEG` (no ruled name), `RCS_LEG` (no ruled name), `REQUEST_STATE_ONLY_LEG_PACING_MS` (no ruled name), `RUN_LEG_ARGS` (no ruled name), `RUN_LEG_DEFAULT_ARGS` (no ruled name), `RUN_LEG_WRAP` (no ruled name), `SOLE_LEG` (no ruled name), `T_LEG` (no ruled name), `_ARM_FLEET_RESERVED_LEG` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `docs/handover/console-sections/wrapping.md` | docs | 52 |
| `scripts/handover/arm-resume.sh` | code | 231, 1253, 1262, 1376, 4032, 4045, 4048, 4078, 4131 |
| `scripts/handover/auto-commit.sh` | code | 39, 52, 96, 519, 529, 608, 616 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 53, 266, 277, 283, 319, 412, 435, 453, 462 |
| `scripts/handover/console-kit/console-wait.sh` | code | 232 |
| `scripts/handover/console-kit/test-cancel-runs.sh` | test | 111, 121, 206, 211 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | test | 44, 226, 240, 245, 457, 678, 706, 735, 736, 1239 |
| `scripts/handover/console-kit/test-console-kit-e2e.sh` | test | 78, 79 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 66, 166, 188, 192 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 365, 368, 370, 374, 386, 902, 926, 950, 959, 1006, 1014, 2630, 2644, 2730, 2737, 2744, 2766, 2780, 2796, 2810, 2815, 2828, 2840, 2856, 3608, 3687, 3744, 3803, 3868, 3912, 4450, 4526, 4532, 4714, 4731 |
| `scripts/handover/test-arm-resume-bank-refresh.sh` | test | 54 |
| `scripts/handover/test-arm-resume-identity.sh` | test | 904, 910, 916, 929, 935, 940 |
| `scripts/handover/test-arm-resume-queue-lock.sh` | test | 86 |
| `scripts/handover/test-arm-resume.sh` | test | 5973, 6004, 6007 |
| `scripts/handover/test-auto-commit.sh` | test | 554, 556 |
| `scripts/handover/test-queue-lock.sh` | test | 2467, 2468, 2469, 2470, 2471, 2513, 2519, 2525, 2531, 2534, 2537, 2559, 2560, 2561, 2562, 2565, 2577, 2579, 2581 |
| `scripts/himmelctl/lib/cadence-emit.js` | code | 44, 91, 104 |
| `scripts/hooks/test-block-chokepoint-env-prefix.sh` | test | 1109 |
| `scripts/hooks/test-block-unresolved-cr-merge.sh` | test | 1210, 1211, 1214, 1216, 1219 |
| `scripts/hooks/test-console-compact-reinject.sh` | test | 217, 218, 221, 232, 233, 235 |
| `scripts/hooks/test-guard-relay-writes.sh` | test | 117, 137 |
| `scripts/lanes/bench/scorecard/test-scorecard.sh` | test | 199, 201, 206 |
| `scripts/lib/rename-aliases.tsv` | config | 58, 59, 93, 94, 95, 108, 109, 110, 111, 112, 113, 114, 115, 116, 172, 185, 186, 192, 312, 313, 314, 315, 316, 326, 327, 328, 329 |
| `scripts/lib/test-rename-aliases.sh` | test | 385 |
| `scripts/telegram/break-glass.sh` | code | 64, 380 |
| `scripts/telegram/test-break-glass.sh` | test | 234, 286, 289 |
| `templates/luna-second-brain/.obsidian/plugins/obsidian-local-rest-api/main.js` | code | 80405, 89148 |

### N39 `upper-case names with CONSOLE inside (BREAK_GLASS_CONSOLE_CMD, ...)` to `pending-N2892: no ruled name`

Family F1c, slice V5; env var, script-local name; owner HIMMEL-6647 (V5 HIMMEL-6641 Done); 48 lines in 18 files; no ruled name for 11. HIMMEL_CONSOLE and HIMMEL_CONSOLE_* are kept (OD-1).

Distinct matched strings (11): `BREAK_GLASS_CONSOLE_CMD` (no ruled name), `BUS_CONSOLE` (no ruled name), `CACHE_HEALTH_CONSOLE` (no ruled name), `CMDLINE_CONSOLE` (no ruled name), `HO_2192_CONSOLE` (no ruled name), `MISSION_THEN_CONSOLE_MENTION_TRANSCRIPT` (no ruled name), `N_CONSOLE` (no ruled name), `PILOT_CONSOLE` (no ruled name), `PRIOR_CONSOLE` (no ruled name), `RCS_CONSOLE` (no ruled name), `RO_CONSOLE` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `scripts/config-ui/tests/agui-fleet-fixture.ts` | test | 12, 15 |
| `scripts/config-ui/tests/agui-fleet.test.ts` | test | 9, 316 |
| `scripts/config-ui/tests/e2e/agui.e2e.ts` | test | 5, 316 |
| `scripts/eval/cache-health-cadence.sh` | code | 71, 101 |
| `scripts/eval/lane-quality/pilot-4869/pilot.sh` | code | 220, 239 |
| `scripts/eval/lane-quality/pilot-4869/test-pilot.sh` | test | 100 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 1525, 2591, 2598, 2620 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 65, 188, 192 |
| `scripts/handover/console-kit/test-inbox-audit.sh` | test | 40, 41, 46 |
| `scripts/handover/console-kit/test-inbox-send.sh` | test | 143, 144, 147, 156, 176, 187, 288, 324 |
| `scripts/handover/test-arm-resume.sh` | test | 6259, 6260, 6261 |
| `scripts/hooks/test-console-compact-reinject.sh` | test | 245, 246, 251 |
| `scripts/hooks/test-guard-console-dispatch.sh` | test | 135, 136, 206 |
| `scripts/lanes/bench/scorecard/test-scorecard.sh` | test | 202, 204 |
| `scripts/lib/rename-aliases.tsv` | config | 92, 311 |
| `scripts/lib/test-cr-first-release.sh` | test | 418, 420, 422 |
| `scripts/telegram/break-glass.sh` | code | 64, 444 |
| `scripts/telegram/test-break-glass.sh` | test | 321 |

### N40 `directories docs/handover/console-sections/, docs/handover/leg-sections/` to `chief-sections/, worker-sections/`

Family F8, slice M; directory; owner HIMMEL-6646; 93 lines in 40 files; new name live 0/2. plan row 60.

Distinct matched strings (2): `console-sections` to `chief-sections`, `leg-sections` to `worker-sections`

| File | Class | Lines |
|---|---|---|
| `docs/handover/console-sections/live-state.md` | docs | 82 |
| `docs/handover/console-sections/monitors.md` | docs | 63 |
| `docs/handover/console-template.md` | docs | 6, 65, 71, 81, 97, 102, 133, 186, 197, 210, 217, 219, 222 |
| `docs/handover/leg-brief-template.md` | docs | 178 |
| `docs/handover/leg-preface-claudex.md` | docs | 60 |
| `docs/handover/leg-preface.md` | docs | 8, 63, 93, 103, 112, 135, 180 |
| `docs/handover/rm-brief-template.md` | docs | 6 |
| `docs/internals/ci-merge-flow.md` | docs | 7, 95 |
| `docs/internals/prompt-cache.md` | docs | 211 |
| `docs/internals/retask-channel.md` | docs | 204 |
| `docs/internals/stuck-playbook.md` | docs | 536 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 8 |
| `scripts/ci/fixtures/tier-replay/manifests/39389928341.txt` | fixture | 6 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 6 |
| `scripts/eval/qmd-quality/fixtures/golden-vocabulary.jsonl` | fixture | 11, 12 |
| `scripts/eval/qmd-quality/golden/himmel.jsonl` | code | 36, 37, 38, 39, 40, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 193 |
| `scripts/eval/retrieval-eval/questions.jsonl` | code | 9, 14, 17, 31, 53, 67 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6377-N2799-cr-loop-critical-disposition-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6483-N2791-tracker-lean-sector-parity-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5966.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6104.md` | fixture | 25 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6111.md` | fixture | 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6114.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6127.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6303.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6377.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/pr-files.tsv` | fixture | 7, 25 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 2141 |
| `scripts/handover/console-kit/test-board.sh` | test | 1331 |
| `scripts/handover/console-kit/test-gen-briefs.sh` | test | 429 |
| `scripts/handover/console-kit/test-gen-judge-brief.sh` | test | 140 |
| `scripts/handover/console-kit/test-tick.sh` | test | 1403 |
| `scripts/handover/console-kit/tick.sh` | code | 318, 2549, 2565, 2568 |
| `scripts/handover/test-bus-idle-waker.sh` | test | 310 |
| `scripts/handover/test-ruling-bullet-docs.sh` | test | 41, 74 |
| `scripts/handover/test-succession-docs.sh` | test | 60, 62, 63, 87, 178, 359 |
| `scripts/handover/test-thread-resolve-docs.sh` | test | 21, 23, 57 |
| `scripts/hooks/guard-leg-cache-ttl.sh` | code | 128 |
| `scripts/hooks/test-guard-leg-cache-ttl.sh` | test | 127, 128 |
| `scripts/lint/flag-parity-baseline.tsv` | config | 5 |

### N41 `directories scripts/console/, scripts/handover/console/, scripts/overnight/` to `scripts/chief/, scripts/handover/chief/, scripts/afk/`

Family F10, slice M; directory; owner HIMMEL-6646; 151 lines in 62 files; new name live 0/3. plan row 61; scripts/eval/leg-digest/ is in N17.

Distinct matched strings (3): `scripts/console/` to `scripts/chief/`, `scripts/handover/console/` to `scripts/handover/chief/`, `scripts/overnight/` to `scripts/afk/`

| File | Class | Lines |
|---|---|---|
| `.claude/commands/afk-shift.md` | docs | 17, 53, 107, 168, 179, 200, 255, 257, 314, 315, 316 |
| `.claude/commands/chief.md` | docs | 17 |
| `.claude/commands/console.md` | docs | 10 |
| `.claude/commands/morning-report.md` | docs | 27 |
| `.claude/commands/stop.md` | docs | 17, 19, 27, 28, 48, 59, 65 |
| `.claude/commands/supervisor-session.md` | docs | 10 |
| `.claude/settings.json` | config | 68, 69 |
| `docs/configuration.md` | docs | 738, 739 |
| `docs/guide/dev-graph/graph.json` | docs | 66, 742, 1383, 1400 |
| `docs/handover/afk-mode.md` | docs | 76, 308, 357 |
| `docs/handover/console-template.md` | docs | 251 |
| `docs/internals/enforcement.md` | docs | 3583 |
| `docs/orchestration-patterns.md` | docs | 30, 31, 90, 145 |
| `docs/setup/install.md` | docs | 369 |
| `docs/tooling-catalog.md` | docs | 1502 |
| `marketplace/plugins/himmel-ops/commands/chief.md` | docs | 24, 27, 29, 32, 70, 71, 75, 78 |
| `marketplace/plugins/himmel-ops/scripts/test-console-cmd-resolution.sh` | test | 38, 45, 50, 67, 81 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 27, 71 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 9, 49 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 103, 143 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 2, 59 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 138, 139, 228, 616, 617, 618, 619, 620 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 45 |
| `scripts/ci/fixtures/tier-replay/manifests/39388914470.txt` | fixture | 18 |
| `scripts/ci/fixtures/tier-replay/manifests/39390916544.txt` | fixture | 6, 18 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 9, 10, 45, 60 |
| `scripts/ci/macos-poc-suites.txt` | config | 132 |
| `scripts/ci/suite-durations.tsv` | config | 224, 225, 421, 937, 938, 939, 940, 941 |
| `scripts/ci/suite-tiers.tsv` | config | 197, 198, 415, 416, 943, 944, 945, 946, 947 |
| `scripts/ci/test-impacted-selection.sh` | test | 387 |
| `scripts/ci/test-run-shell-tests.sh` | test | 2469, 2503 |
| `scripts/console/base-status.sh` | code | 2, 49 |
| `scripts/console/sweep-cr-threads.sh` | code | 2, 16, 17 |
| `scripts/console/test-base-status.sh` | test | 2, 565 |
| `scripts/console/test-sweep-cr-threads.sh` | test | 2 |
| `scripts/handover/arm-resume.sh` | code | 241, 444 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-2973.md` | fixture | 28 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5966.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6116.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6127.md` | fixture | 24 |
| `scripts/handover/console-kit/inbox-send.sh` | code | 272 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 178 |
| `scripts/handover/console/chief.sh` | code | 2 |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` | test | 3, 67, 81 |
| `scripts/handover/console/test-console.sh` | test | 3, 94, 1821 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc127-fix.sh` | fixture | 1080 |
| `scripts/handover/fixtures/red-control/merge-on-green.pre-rc4-fix.sh` | fixture | 1089 |
| `scripts/handover/merge-on-green.sh` | code | 2063 |
| `scripts/handover/test-arm-resume-base.sh` | test | 7 |
| `scripts/lib/handover-path.sh` | code | 33 |
| `scripts/lib/test-rename-aliases.sh` | test | 344 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 333, 334, 335, 908, 909, 910, 911, 912, 913, 914, 915, 916 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 129 |
| `scripts/overnight/build-plan.sh` | code | 210 |
| `scripts/overnight/morning-report.sh` | code | 227 |
| `scripts/overnight/self-heal.sh` | code | 14 |
| `scripts/overnight/test-build-plan.sh` | test | 2 |
| `scripts/overnight/test-morning-report.sh` | test | 2, 557 |
| `scripts/overnight/test-self-heal.sh` | test | 2 |
| `scripts/overnight/test-stop-marker.sh` | test | 2 |
| `scripts/telegram/break-glass.sh` | code | 444 |
| `scripts/testing/documented-commands.tsv` | config | 78 |

### N42 `other leg-*.sh scripts (leg-burn, leg-pr-open, leg-resume-brief, leg-timeline, ...)` to `needs a ruling`

Family F7, slice -; script/file name; owner none (not in the approved table); 400 lines in 140 files; no ruled name for 34. not in the approved rename table; a rename needs a ruling. The `leg-burn:` PR-body line is kept (plan do-not-rename list).

Distinct matched strings (34): `block-leg-askuserquestion.sh` (no ruled name), `guard-leg-cache-ttl.sh` (no ruled name), `guard-leg-context-handoff-v2.sh` (no ruled name), `guard-leg-context-handoff.sh` (no ruled name), `guard-leg-wakeup.sh` (no ruled name), `headed-arm-leg-cwd.sh` (no ruled name), `leg-battery.sh` (no ruled name), `leg-burn-broken.sh` (no ruled name), `leg-burn.sh` (no ruled name), `leg-claude-launcher-consult.sh` (no ruled name), `leg-claude-launcher.sh` (no ruled name), `leg-cost-report.sh` (no ruled name), `leg-cost-row.sh` (no ruled name), `leg-over-by-day.sh` (no ruled name), `leg-path.sh` (no ruled name), `leg-pr-open.sh` (no ruled name), `leg-relaunch.sh` (no ruled name), `leg-resume-brief.sh` (no ruled name), `leg-tail-status.sh` (no ruled name), `leg-timeline.sh` (no ruled name), `test-block-leg-askuserquestion.sh` (no ruled name), `test-guard-leg-cache-ttl.sh` (no ruled name), `test-guard-leg-context-handoff.sh` (no ruled name), `test-guard-leg-wakeup.sh` (no ruled name), `test-headed-arm-leg-worker-env.sh` (no ruled name), `test-leg-burn.sh` (no ruled name), `test-leg-cost-report.sh` (no ruled name), `test-leg-handoff-threshold-docs.sh` (no ruled name), `test-leg-ledger.sh` (no ruled name), `test-leg-over-by-day.sh` (no ruled name), `test-leg-pr-open.sh` (no ruled name), `test-leg-relaunch.sh` (no ruled name), `test-leg-resume-brief.sh` (no ruled name), `test-leg-timeline.sh` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.claude/settings.json` | config | 87, 88, 277, 287, 347, 495 |
| `.codex/hooks.json` | config | 59 |
| `.github/workflows/pr-title-lint.yml` | config | 14, 32 |
| `docs/handover/afk-mode.md` | docs | 197 |
| `docs/handover/leg-brief-template.md` | docs | 160, 161, 231 |
| `docs/handover/leg-preface.md` | docs | 98, 116 |
| `docs/handover/leg-sections/cache-keepalive.md` | docs | 3 |
| `docs/handover/leg-sections/context-guard.md` | docs | 6 |
| `docs/handover/leg-sections/shell-and-tests.md` | docs | 58 |
| `docs/handover/running-a-console.md` | docs | 224 |
| `docs/internals/enforcement.md` | docs | 3990, 4009, 4038, 4105, 4134, 4162 |
| `docs/internals/handover-system.md` | docs | 96, 304, 321 |
| `docs/internals/hermes-guardrail-parity.md` | docs | 140 |
| `docs/internals/lane-calibration.md` | docs | 99, 161, 808 |
| `docs/internals/leg-context-guard.md` | docs | 3 |
| `docs/internals/prompt-cache.md` | docs | 207 |
| `docs/internals/stuck-playbook.md` | docs | 634, 762, 764, 771 |
| `docs/tooling-catalog.md` | docs | 617, 619, 631 |
| `marketplace/plugins/handover/templates/epic-next-session.md` | docs | 56 |
| `marketplace/plugins/handover/templates/standalone-next-session.md` | docs | 40 |
| `marketplace/plugins/handover/templates/task-next-session.md` | docs | 69 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 129 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 82 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 64 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 111 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 252, 253, 346, 419, 466, 467, 472, 475 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 50, 61 |
| `scripts/ci/macos-poc-suites.txt` | config | 73 |
| `scripts/ci/suite-durations.tsv` | config | 293, 379, 457, 458, 459, 674, 738, 739, 748, 749, 753 |
| `scripts/ci/suite-tiers.tsv` | config | 273, 370, 455, 456, 457, 674, 675, 739, 740, 749, 750, 754 |
| `scripts/ci/test-pr-title-lint-trigger.sh` | test | 75 |
| `scripts/ci/test-run-shell-tests.sh` | test | 2553 |
| `scripts/cloud/parity-probe.sh` | code | 125, 126 |
| `scripts/codex/test-dispatch-codex-exec.sh` | test | 1291, 1338, 1345 |
| `scripts/config-ui/agui/lane.ts` | code | 58 |
| `scripts/config-ui/fleet.sh` | code | 26, 27 |
| `scripts/config-ui/legs.sh` | code | 22, 23 |
| `scripts/config-ui/tests/test-legs.sh` | test | 23, 37, 38 |
| `scripts/cr/impacted-suites.sh` | code | 1050 |
| `scripts/cr/pr-check-context.sh` | code | 765, 770, 771, 772, 773, 782, 811, 844 |
| `scripts/cr/test-impacted-suites.sh` | test | 795, 924, 928, 929, 937, 939, 968 |
| `scripts/eval/leg-digest/test-leg-ledger.sh` | test | 2 |
| `scripts/eval/retrieval-eval/questions.jsonl` | code | 29, 53, 67 |
| `scripts/eval/retrieval-eval/retrieval-eval.py` | code | 170 |
| `scripts/graphify/test-anchor-seeds.sh` | test | 34, 35 |
| `scripts/guardrails/git-env-baseline.txt` | config | 39, 40, 119, 135 |
| `scripts/handover/compound-extract.sh` | code | 8, 30, 31 |
| `scripts/handover/console-kit/append-results.sh` | code | 7 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | code | 176, 178, 179, 252, 368, 369 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-2928.md` | fixture | 26, 27, 29 |
| `scripts/handover/console-kit/fixtures/doc-reader-agreement/gen.py` | fixture | 17 |
| `scripts/handover/console-kit/handoff-facts.sh` | code | 33, 34 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 23, 134, 1235, 1236, 1271, 1272, 1538, 1746, 1754, 2144, 2171, 2199 |
| `scripts/handover/console-kit/relay-batch.sh` | code | 61, 62 |
| `scripts/handover/console-kit/smoke-consult-sandbox.sh` | code | 7, 60 |
| `scripts/handover/console-kit/test-append-results.sh` | test | 23, 88 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | test | 457, 743, 799, 935 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 4, 32, 103 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | test | 2 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | test | 1349, 1369, 1378, 1428, 1547, 1548, 1551, 1668, 2095, 3954, 3983, 3985, 3987, 4075, 4489, 4492, 4628, 4640 |
| `scripts/handover/console-kit/test-tick.sh` | test | 86, 88, 180, 841 |
| `scripts/handover/console-kit/tick.sh` | code | 321, 410, 411, 642, 2384, 2392, 2401 |
| `scripts/handover/console-kit/tracker.py` | code | 117 |
| `scripts/handover/console/chief.sh` | code | 62, 63 |
| `scripts/handover/console/test-console.sh` | test | 1884 |
| `scripts/handover/headed-arm.sh` | code | 576 |
| `scripts/handover/leg-resume-brief.sh` | code | 2, 36, 63, 359 |
| `scripts/handover/leg-timeline.sh` | code | 2, 18, 30 |
| `scripts/handover/librarian.sh` | code | 8, 43, 44 |
| `scripts/handover/merge-on-green.sh` | code | 1631 |
| `scripts/handover/test-bus-idle-waker.sh` | test | 206, 221, 226, 231, 278, 285 |
| `scripts/handover/test-handover-root-dotenv.sh` | test | 59 |
| `scripts/handover/test-leg-handoff-threshold-docs.sh` | test | 2 |
| `scripts/handover/test-leg-resume-brief.sh` | test | 2, 19, 81, 115 |
| `scripts/handover/test-leg-timeline.sh` | test | 2, 4, 25, 115, 415, 431 |
| `scripts/handover/test-merge-on-green.sh` | test | 1569, 1596 |
| `scripts/handover/test-template-operator-gated-clause.sh` | test | 40 |
| `scripts/hermes/parity-measure.py` | code | 37 |
| `scripts/himmelctl/lib/bypass-flags.json` | config | 302, 456 |
| `scripts/hooks/bench-hook-stack.test.mjs` | test | 382 |
| `scripts/hooks/block-leg-askuserquestion.sh` | code | 2 |
| `scripts/hooks/block-worker-askuserquestion.sh` | code | 20 |
| `scripts/hooks/guard-agent-model.sh` | code | 32, 46 |
| `scripts/hooks/guard-bus-store.sh` | code | 94 |
| `scripts/hooks/guard-leg-cache-ttl.sh` | code | 2 |
| `scripts/hooks/guard-leg-context-handoff.sh` | code | 2, 110, 321, 322 |
| `scripts/hooks/guard-leg-wakeup.sh` | code | 2 |
| `scripts/hooks/guard-worker-wakeup.sh` | code | 20 |
| `scripts/hooks/read-clamp.sh` | code | 36 |
| `scripts/hooks/test-block-worker-askuserquestion.sh` | test | 7, 80 |
| `scripts/hooks/test-escape-class-corpus.sh` | test | 174 |
| `scripts/hooks/test-guard-judge-writes.sh` | test | 101 |
| `scripts/hooks/test-guard-leg-cache-ttl.sh` | test | 2, 19, 113, 114 |
| `scripts/hooks/test-guard-leg-context-handoff.sh` | test | 2, 14 |
| `scripts/hooks/test-guard-rm-writes.sh` | test | 97 |
| `scripts/hooks/test-guard-worker-wakeup.sh` | test | 9, 105 |
| `scripts/hooks/wire-hook-bash.mjs` | code | 142, 146, 164 |
| `scripts/jira/reconcile-lib.test.mjs` | test | 41 |
| `scripts/lanes/bench/scorecard/agg-burn.sh` | code | 12, 43, 51, 139, 154 |
| `scripts/lanes/bench/scorecard/agg-postpin.sh` | code | 90, 97, 213 |
| `scripts/lanes/bench/scorecard/extra-metrics.sh` | code | 54 |
| `scripts/lanes/bench/scorecard/ledger-metrics.sh` | code | 38 |
| `scripts/lanes/bench/scorecard/leg-over-by-day.sh` | code | 2, 7, 14, 17, 32, 38, 110 |
| `scripts/lanes/bench/scorecard/leg-relaunch.sh` | code | 2, 7, 16, 19, 57 |
| `scripts/lanes/bench/scorecard/lib/scorecard-lib.sh` | code | 16, 17 |
| `scripts/lanes/bench/scorecard/ready-go-latency.sh` | code | 60 |
| `scripts/lanes/bench/scorecard/test-agg-burn.sh` | test | 17, 21, 115, 120, 121, 140, 147 |
| `scripts/lanes/bench/scorecard/test-leg-over-by-day.sh` | test | 2, 3, 7, 18, 25, 139, 144, 145, 170, 173 |
| `scripts/lanes/bench/scorecard/test-leg-relaunch.sh` | test | 2, 3, 5, 26, 153, 175, 178 |
| `scripts/lanes/bench/scorecard/test-scorecard.sh` | test | 217, 228 |
| `scripts/lanes/consult-env.sh` | code | 8, 9 |
| `scripts/lanes/leg-burn.sh` | code | 2, 11, 12, 13, 82 |
| `scripts/lanes/leg-claude-launcher-consult.sh` | code | 2, 3, 40 |
| `scripts/lanes/leg-claude-launcher.sh` | code | 2, 79 |
| `scripts/lanes/leg-cost-report.sh` | code | 2, 4, 22, 24, 26, 33, 34 |
| `scripts/lanes/leg-pr-open.sh` | code | 2, 17, 44, 100, 139, 140, 146, 148, 160, 161 |
| `scripts/lanes/lib/burn-weights.sh` | code | 3, 8 |
| `scripts/lanes/lib/leg-cost-row.sh` | code | 2, 15, 79 |
| `scripts/lanes/plugin-profiles.mjs` | code | 644, 650 |
| `scripts/lanes/srt-poc/README.md` | docs | 59 |
| `scripts/lanes/srt-poc/leg-battery.sh` | code | 3 |
| `scripts/lanes/srt-poc/recorded/vm-run-impl.txt` | config | 7 |
| `scripts/lanes/srt-poc/recorded/vm-run-research.txt` | config | 7 |
| `scripts/lanes/srt-poc/run-poc.sh` | code | 5, 10, 59 |
| `scripts/lanes/test-leg-cost-report.sh` | test | 2, 8, 53, 54 |
| `scripts/lanes/test-leg-pr-open.sh` | test | 2, 3, 13, 69, 253, 288, 309 |
| `scripts/lanes/tests/plugin-profiles.test.mjs` | test | 1468, 1471, 1495 |
| `scripts/lanes/tests/settings-allow.test.mjs` | test | 178, 179 |
| `scripts/lanes/tests/test-leg-burn.sh` | test | 2, 29, 34, 132 |
| `scripts/lib/check-pr-title.sh` | code | 7, 15 |
| `scripts/lib/fixtures/status-marker-rows.tsv` | fixture | 14 |
| `scripts/lib/fleet-wrapped.sh` | code | 26 |
| `scripts/lib/leg-tail-status.sh` | code | 2 |
| `scripts/lib/status-marker.sh` | code | 12 |
| `scripts/lib/test-bank-preflight-fleet.sh` | test | 618 |
| `scripts/lib/test-cadence-format.sh` | test | 420, 422 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 695, 696, 701 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 137, 138, 139, 295 |
| `scripts/testing/documented-commands.tsv` | config | 54 |
| `scripts/testing/unwired-hooks-allowlist.txt` | config | 26, 27, 33 |

### N43 `other console-* scripts (console-wait.sh, console-budget.sh, guard-console-dispatch.sh, ...)` to `needs a ruling`

Family F9, slice -; script/file name; owner none (not in the approved table); 495 lines in 137 files; no ruled name for 47. not in the approved rename table; a rename needs a ruling.

Distinct matched strings (47): `console-2026-10-01.md` (no ruled name), `console-2026-10-31.md` (no ruled name), `console-budget.sh` (no ruled name), `console-bus-exec-gone.sh` (no ruled name), `console-bus-exec.sh` (no ruled name), `console-c.md` (no ruled name), `console-census.sh` (no ruled name), `console-decisions-2026-09-20.md` (no ruled name), `console-decisions-2026-09-21.md` (no ruled name), `console-decisions-2026-10-19.md` (no ruled name), `console-decisions-2026-10-20.md` (no ruled name), `console-doc-bold.md` (no ruled name), `console-doc.md` (no ruled name), `console-doc11.md` (no ruled name), `console-doc2.md` (no ruled name), `console-guide.md` (no ruled name), `console-handoff-template.md` (no ruled name), `console-heartbeat-watch.ts` (no ruled name), `console-himmel.md` (no ruled name), `console-load-inventory.py` (no ruled name), `console-m.md` (no ruled name), `console-ops-lane.md` (no ruled name), `console-precompact-snapshot.sh` (no ruled name), `console-project.md` (no ruled name), `console-rd-none.md` (no ruled name), `console-rd.md` (no ruled name), `console-relay.sh` (no ruled name), `console-route.ts` (no ruled name), `console-s.md` (no ruled name), `console-wait.sh` (no ruled name), `guard-console-dispatch.sh` (no ruled name), `notify-console-on-prompt.sh` (no ruled name), `other-console-wait.sh` (no ruled name), `stop-console-idle-guard.sh` (no ruled name), `test-a-console-doc.sh` (no ruled name), `test-console-budget.sh` (no ruled name), `test-console-cmd-resolution.sh` (no ruled name), `test-console-handoff-roundtrip.sh` (no ruled name), `test-console-load-inventory.sh` (no ruled name), `test-console-precompact-snapshot.sh` (no ruled name), `test-console-wait-b.sh` (no ruled name), `test-console-wait-pool.sh` (no ruled name), `test-console-wait-r0.sh` (no ruled name), `test-console-wait.sh` (no ruled name), `test-guard-console-dispatch.sh` (no ruled name), `test-notify-console-on-prompt.sh` (no ruled name), `test-stop-console-idle-guard.sh` (no ruled name)

| File | Class | Lines |
|---|---|---|
| `.agents/skills/pr-check/SKILL.md` | docs | 187, 188, 189 |
| `.claude/settings.json` | config | 72, 490, 554, 638 |
| `docs/guide/dev-graph/graph.json` | docs | 85, 88, 770, 1416, 1907 |
| `docs/handover/console-handoff-template.md` | docs | 18 |
| `docs/handover/console-sections/board-tracker.md` | docs | 125 |
| `docs/handover/console-sections/live-state.md` | docs | 102 |
| `docs/handover/console-sections/monitors.md` | docs | 22, 30, 42, 54, 72 |
| `docs/handover/console-sections/waiter.md` | docs | 8, 11, 120, 121, 123, 128 |
| `docs/handover/console-template.md` | docs | 72, 75, 91 |
| `docs/handover/relay-brief-template.md` | docs | 73 |
| `docs/handover/running-a-console.md` | docs | 121, 128, 241, 299, 643, 662 |
| `docs/internals/enforcement.md` | docs | 616, 635, 3845, 3895, 3913, 4883, 4912, 4914, 4953, 5059, 5072, 5076, 5098 |
| `docs/internals/lane-calibration.md` | docs | 374 |
| `docs/internals/pr-snapshot.md` | docs | 27 |
| `docs/telegram-bridge.md` | docs | 89, 100 |
| `marketplace/plugins/himmel-ops/hooks/hooks.json` | config | 104 |
| `marketplace/plugins/himmel-ops/scripts/test-console-cmd-resolution.sh` | test | 3 |
| `scripts/ci/fixtures/ledger-drift/matching-ledger.tsv` | fixture | 53, 54, 55 |
| `scripts/ci/fixtures/ledger-drift/run-39886837066.log` | fixture | 5, 27, 173 |
| `scripts/ci/fixtures/ledger-drift/run-39918454994.log` | fixture | 57, 169, 170 |
| `scripts/ci/fixtures/ledger-drift/run-39927689757.log` | fixture | 57, 81, 102 |
| `scripts/ci/fixtures/ledger-drift/stale-ledger.tsv` | fixture | 35, 217, 409, 417, 448 |
| `scripts/ci/fixtures/tier-replay/manifests/39386231515.txt` | fixture | 30, 63 |
| `scripts/ci/fixtures/tier-replay/manifests/39390916544.txt` | fixture | 6, 18 |
| `scripts/ci/fixtures/tier-replay/manifests/39397364398.txt` | fixture | 11, 29, 53 |
| `scripts/ci/run-shell-tests.sh` | code | 810, 811, 812, 813, 814, 815, 817, 818, 819, 825 |
| `scripts/ci/suite-durations.tsv` | config | 52, 308, 363, 365, 366, 367, 368, 655, 668, 698, 717 |
| `scripts/ci/suite-tiers.tsv` | config | 19, 288, 349, 351, 352, 353, 354, 415, 655, 668, 699, 718 |
| `scripts/ci/test-run-shell-tests-live-state.sh` | test | 62, 154 |
| `scripts/ci/test-run-shell-tests.sh` | test | 2493, 2494 |
| `scripts/codex/test-codex-hook-parity.sh` | test | 171 |
| `scripts/cr/anchor-handoff.sh` | code | 48 |
| `scripts/cr/pr-check-context.sh` | code | 749, 804, 805, 833, 834 |
| `scripts/cr/pr-check-ref/10-step0.md` | docs | 23, 24, 25 |
| `scripts/cr/test-anchor-handoff.sh` | test | 341 |
| `scripts/cr/test-cr-guarded-closure.sh` | test | 283, 286 |
| `scripts/cr/test-pr-check-context.sh` | test | 383, 2020, 2021, 2022, 2365 |
| `scripts/cr/test-pr-check-pair.sh` | test | 169, 170, 171, 237, 260, 930 |
| `scripts/docs/test-check-old-terms.sh` | test | 92 |
| `scripts/docs/test-dev-graph.sh` | test | 16, 351 |
| `scripts/eval/console-load-inventory.py` | code | 2, 9, 37 |
| `scripts/eval/fixtures/handover-cost/console-s.jsonl` | fixture | 5 |
| `scripts/eval/qmd-quality/golden/himmel.jsonl` | code | 68, 69 |
| `scripts/eval/retrieval-eval/questions.jsonl` | code | 31 |
| `scripts/eval/test-console-load-inventory.sh` | test | 2, 14 |
| `scripts/graphify/test-anchor-seeds.sh` | test | 146, 160 |
| `scripts/guardrails/test-settings-waiter-allow.sh` | test | 65, 67, 76, 101, 102, 103, 104, 105, 106, 107, 108, 109 |
| `scripts/handover/arm-resume.sh` | code | 2692 |
| `scripts/handover/console-kit/ack-denial.sh` | code | 12 |
| `scripts/handover/console-kit/compacted-check.sh` | code | 4 |
| `scripts/handover/console-kit/console-budget.sh` | code | 2, 11, 47 |
| `scripts/handover/console-kit/console-wait.sh` | code | 2, 4, 72, 135, 256, 595, 728, 734, 997 |
| `scripts/handover/console-kit/denial-ack-lib.sh` | code | 2, 9, 17 |
| `scripts/handover/console-kit/denied-launch-alert.sh` | code | 32 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/legs/HIMMEL-6478-N2806-dispatcher-false-collisions-2026-10-19.md` | fixture | 3 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5511.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5592.md` | fixture | 24, 28 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5966.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-5973.md` | fixture | 25, 26 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6114.md` | fixture | 24 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6461.md` | fixture | 26, 27 |
| `scripts/handover/console-kit/fixtures/dispatcher-replay/mirror/HIMMEL/HIMMEL-6478.md` | fixture | 25 |
| `scripts/handover/console-kit/fleet-manifest.sh` | code | 3 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | code | 906 |
| `scripts/handover/console-kit/inbox-follow.sh` | code | 22 |
| `scripts/handover/console-kit/long-running.txt` | config | 3, 14 |
| `scripts/handover/console-kit/next-dispatchable.sh` | code | 4 |
| `scripts/handover/console-kit/ops-run.sh` | code | 4 |
| `scripts/handover/console-kit/orphan-loops.sh` | code | 100 |
| `scripts/handover/console-kit/pr-stall.sh` | code | 47 |
| `scripts/handover/console-kit/test-board.sh` | test | 303, 304, 312, 313, 319, 666, 668, 1022, 1047, 1103, 1121, 1150, 1250 |
| `scripts/handover/console-kit/test-compacted-check.sh` | test | 6 |
| `scripts/handover/console-kit/test-console-budget.sh` | test | 3, 17 |
| `scripts/handover/console-kit/test-console-wait-b.sh` | test | 2, 12, 16, 18, 21, 119, 242, 285, 372, 648, 789, 854 |
| `scripts/handover/console-kit/test-console-wait-pool.sh` | test | 2, 13, 16, 19 |
| `scripts/handover/console-kit/test-console-wait-r0.sh` | test | 2, 27, 30, 33 |
| `scripts/handover/console-kit/test-console-wait.sh` | test | 2, 13, 15, 18, 509, 689, 752, 805 |
| `scripts/handover/console-kit/test-doc-reader-agreement.sh` | test | 41 |
| `scripts/handover/console-kit/test-inbox-follow.sh` | test | 170 |
| `scripts/handover/console-kit/test-next-dispatchable.sh` | test | 354, 363, 364, 406, 482, 484 |
| `scripts/handover/console-kit/test-orphan-loops.sh` | test | 50, 51, 52, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 101, 102, 109, 111 |
| `scripts/handover/console-kit/test-tick-deadwin.sh` | test | 5, 14 |
| `scripts/handover/console-kit/test-tick-nolive.sh` | test | 4, 14 |
| `scripts/handover/console-kit/test-tick.sh` | test | 500, 501, 503, 507, 508, 1406, 1517, 1527, 3032 |
| `scripts/handover/console-kit/test-tracker.sh` | test | 932 |
| `scripts/handover/console-kit/tick.sh` | code | 92, 99, 148, 155, 218, 221, 231, 236, 245, 1800, 1848, 1948, 2136, 2293, 2325, 2351, 2482 |
| `scripts/handover/console-kit/vault-status.sh` | code | 3 |
| `scripts/handover/console/chief.sh` | code | 51, 122, 265, 395, 433, 988, 995, 997, 1293, 2045 |
| `scripts/handover/console/console-bus-exec.sh` | code | 2 |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` | test | 3 |
| `scripts/handover/console/test-console.sh` | test | 150, 281, 468, 784, 796, 2106, 2438, 2441, 2442, 2445, 2456, 2458, 2463, 2475, 2476, 2481, 2490, 2493, 2504, 2507, 2517, 2520, 2529, 2531, 2538, 2542, 2730, 2748, 2749, 2752, 2753, 2756, 2757, 2760, 2761, 2831, 2844, 2922, 2923 |
| `scripts/handover/headed-arm.sh` | code | 529 |
| `scripts/handover/test-arm-resume.sh` | test | 6088 |
| `scripts/handover/test-handover-root-dotenv.sh` | test | 96, 109 |
| `scripts/handover/test-merge-on-green.sh` | test | 3585, 3590 |
| `scripts/handover/test-succession-docs.sh` | test | 24, 254, 338 |
| `scripts/himmelctl/lib/bypass-flags.json` | config | 55, 57, 87, 89 |
| `scripts/hooks/block-worker-askuserquestion.sh` | code | 31 |
| `scripts/hooks/console-precompact-snapshot.sh` | code | 2 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel3148.sh` | fixture | 9, 11 |
| `scripts/hooks/fixtures/red-control/stop-console-idle-guard.pre-himmel4567.sh` | fixture | 2 |
| `scripts/hooks/guard-console-dispatch.sh` | code | 2 |
| `scripts/hooks/guard-console-foreground.sh` | code | 23, 96, 119 |
| `scripts/hooks/guard-leg-cache-ttl.sh` | code | 22 |
| `scripts/hooks/guard-pr-check-literal.sh` | code | 82, 93, 157, 2615, 2689 |
| `scripts/hooks/lib-cmdpos-clean.sh` | code | 39 |
| `scripts/hooks/notify-console-on-prompt.sh` | code | 2 |
| `scripts/hooks/stop-console-idle-guard.sh` | code | 2, 28, 227, 297 |
| `scripts/hooks/stop-queue.test.mjs` | test | 442, 450 |
| `scripts/hooks/test-console-precompact-snapshot.sh` | test | 2, 14 |
| `scripts/hooks/test-guard-console-dispatch.sh` | test | 2, 4, 12, 252, 363 |
| `scripts/hooks/test-guard-console-foreground.sh` | test | 123, 124 |
| `scripts/hooks/test-guard-pr-check-literal.sh` | test | 66, 311, 314, 315, 316, 317, 318, 319 |
| `scripts/hooks/test-notify-console-on-prompt.sh` | test | 3, 12, 25, 26 |
| `scripts/hooks/test-stop-console-idle-guard.sh` | test | 2, 35, 93, 116, 134, 135, 137, 211, 218, 315, 316, 399, 400 |
| `scripts/hooks/wire-plugin-hook-bash.mjs` | code | 43 |
| `scripts/lanes/bench/scorecard/test-scorecard.sh` | test | 251, 268, 276, 283, 300, 303, 309, 310, 318, 320, 327, 329, 335, 338, 345, 348 |
| `scripts/lib/check-ci-watch.sh` | code | 11 |
| `scripts/lib/fixtures/cr-body/pr-2549-nitpick-colon.body.txt` | fixture | 94, 95 |
| `scripts/lib/merge-block-alert.sh` | code | 10, 65, 129, 192 |
| `scripts/lib/test-merge-block-alert.sh` | test | 146 |
| `scripts/lib/usage-monitor.sh` | code | 11 |
| `scripts/lint/flag-parity-baseline.tsv` | config | 5, 6 |
| `scripts/lint/shell-lint-baseline.tsv` | config | 309, 310, 334, 562 |
| `scripts/lint/swallowed-errors-baseline.txt` | config | 87, 276, 286, 287, 327, 328, 329, 348 |
| `scripts/lint/test-check-swallowed-errors.sh` | test | 5 |
| `scripts/luna/cadence-alert.sh` | code | 17 |
| `scripts/luna/vault-stall-alert.sh` | code | 9 |
| `scripts/telegram/break-glass.sh` | code | 173 |
| `scripts/telegram/console-census.sh` | code | 2, 3 |
| `scripts/telegram/console-heartbeat-watch.ts` | code | 1, 2, 3, 13, 42, 62, 64, 97, 118 |
| `scripts/telegram/console-route.test.ts` | test | 410, 473, 484 |
| `scripts/telegram/console-route.ts` | code | 56, 255, 273 |
| `scripts/telegram/poller.ts` | code | 2479 |
| `scripts/telegram/router.ts` | code | 78 |
| `scripts/telegram/test-break-glass.sh` | test | 121, 133 |
| `scripts/testing/documented-commands.tsv` | config | 9, 74 |

## Files whose own name carries an old name

Tracked paths at the same sha, fixtures excluded. The forwarders above are not listed: they are deleted, not renamed.

**Ruled.** The approved rename table gives the new file name.

| Old path | New file name | Entry |
|---|---|---|
| `docs/handover/console-template.md` | `chief-template.md` | N21 |
| `docs/handover/leg-brief-template.md` | `worker-brief-template.md` | N22 |
| `docs/handover/leg-preface-claudex.md` | `worker-preface-claudex.md` | N20 |
| `docs/handover/leg-preface-openrouter.md` | `worker-preface-openrouter.md` | N20 |
| `docs/handover/leg-preface.md` | `worker-preface.md` | N20 |
| `scripts/eval/leg-digest/leg-digest.ts` | `worker-digest.ts` | N17 |
| `scripts/eval/leg-digest/test-leg-digest.sh` | `test-worker-digest.sh` | N17 |
| `scripts/graphify/leg-graph.sh` | `worker-graph.sh` | N16 |
| `scripts/handover/console-kit/close-wrapped-leg.sh` | `close-wrapped-worker.sh` | N18 |
| `scripts/handover/console-kit/headed-arm-leg.sh` | `headed-arm-worker.sh` | N15 |
| `scripts/handover/console-kit/leg-digest-step.sh` | `worker-digest-step.sh` | N17 |
| `scripts/handover/console-kit/leg-doc-lock.sh` | `worker-doc-lock.sh` | N16 |
| `scripts/handover/console-kit/leg-event.sh` | `worker-event.sh` | N16 |
| `scripts/handover/console-kit/leg-jira-status.sh` | `worker-jira-status.sh` | N16 |
| `scripts/handover/console-kit/leg-pretrust.sh` | `worker-pretrust.sh` | N16 |
| `scripts/handover/console-kit/leg-transcripts.sh` | `worker-transcripts.sh` | N16 |
| `scripts/hooks/console-compact-reinject.sh` | `chief-compact-reinject.sh` | N36 |
| `scripts/hooks/guard-console-foreground.sh` | `guard-chief-foreground.sh` | N36 |
| `scripts/lanes/bank-status-core.mjs` | `usage-status-core.mjs` | N12 |
| `scripts/lanes/codex-bank-probe-core.mjs` | `codex-usage-probe-core.mjs` | N12 |
| `scripts/lanes/tests/bank-status.test.mjs` | `usage-status.test.mjs` | N12 |
| `scripts/lanes/tests/codex-bank-probe.test.mjs` | `codex-usage-probe.test.mjs` | N12 |
| `scripts/lib/leg-identity.sh` | `worker-identity.sh` | N16 |

**Tests of a ruled script.** The table names the script, not its test. The test is expected to follow
its script (`test-` plus the new name) in the same rename PR; the rename PR confirms it.

| Old path | Expected new name | Entry |
|---|---|---|
| `scripts/graphify/test-leg-graph-rationale.sh` | `test-worker-graph-rationale.sh` | N16 |
| `scripts/graphify/test-leg-graph.sh` | `test-worker-graph.sh` | N16 |
| `scripts/handover/console-kit/test-close-wrapped-leg.sh` | `test-close-wrapped-worker.sh` | N18 |
| `scripts/handover/console-kit/test-headed-arm-leg-worker-env.sh` | `test-headed-arm-worker-worker-env.sh` | N15 |
| `scripts/handover/console-kit/test-headed-arm-leg.sh` | `test-headed-arm-worker.sh` | N15 |
| `scripts/handover/console-kit/test-leg-doc-lock.sh` | `test-worker-doc-lock.sh` | N16 |
| `scripts/handover/console-kit/test-leg-event.sh` | `test-worker-event.sh` | N16 |
| `scripts/handover/console-kit/test-leg-jira-status.sh` | `test-worker-jira-status.sh` | N16 |
| `scripts/handover/console-kit/test-leg-pretrust.sh` | `test-worker-pretrust.sh` | N16 |
| `scripts/handover/console/test-console.sh` | `test-chief.sh` | N24 |
| `scripts/hooks/test-console-compact-reinject.sh` | `test-chief-compact-reinject.sh` | N36 |
| `scripts/hooks/test-guard-console-foreground.sh` | `test-guard-chief-foreground.sh` | N36 |
| `scripts/lib/test-bank-attribution.sh` | `test-usage-attribution.sh` | N12 |
| `scripts/lib/test-bank-monitor.sh` | `test-usage-monitor.sh` | N12 |
| `scripts/lib/test-bank-preflight-admit-gate.sh` | `test-usage-preflight-admit-gate.sh` | N12 |
| `scripts/lib/test-bank-preflight-dead-owner.sh` | `test-usage-preflight-dead-owner.sh` | N12 |
| `scripts/lib/test-bank-preflight-dotenv-root.sh` | `test-usage-preflight-dotenv-root.sh` | N12 |
| `scripts/lib/test-bank-preflight-fleet.sh` | `test-usage-preflight-fleet.sh` | N12 |
| `scripts/lib/test-bank-preflight-openrouter.sh` | `test-usage-preflight-openrouter.sh` | N12 |
| `scripts/lib/test-bank-preflight.sh` | `test-usage-preflight.sh` | N12 |
| `scripts/lib/test-leg-identity.sh` | `test-worker-identity.sh` | N16 |

**Not in the approved rename table; a rename needs a ruling.** These names carry an old word but no
row of the approved table names them, so this page proposes no new name. They go to the operator with
the table.

| Path |
|---|
| `.claude/commands/cr-learnings-refresh.md` |
| `.claude/commands/cr-scores.md` |
| `.claude/commands/cr-tune.md` |
| `docs/handover/console-handoff-template.md` |
| `docs/handover/running-a-console.md` |
| `docs/internals/console-ops-lane.md` |
| `docs/internals/leg-context-guard.md` |
| `marketplace/plugins/himmel-ops/scripts/test-console-cmd-resolution.sh` |
| `scripts/ci/cr-first-measure.sh` |
| `scripts/config-ui/legs.sh` |
| `scripts/config-ui/tests/agui-console-pages.test.ts` |
| `scripts/config-ui/tests/bank-route.test.ts` |
| `scripts/config-ui/tests/test-legs.sh` |
| `scripts/cr/cr-pending-audit.sh` |
| `scripts/cr/cr-reset.sh` |
| `scripts/cr/cr-round-metrics.sh` |
| `scripts/cr/cr-scores.sh` |
| `scripts/cr/cr-trigger-ledger.sh` |
| `scripts/cr/cr-tune.sh` |
| `scripts/eval/console-load-inventory.py` |
| `scripts/eval/leg-digest/leg_ledger.py` |
| `scripts/eval/leg-digest/test-leg-ledger.sh` |
| `scripts/eval/sandbox-poc/settings.leg-sandbox.json` |
| `scripts/eval/test-console-load-inventory.sh` |
| `scripts/handover/console-kit/console-budget.sh` |
| `scripts/handover/console-kit/console-wait.sh` |
| `scripts/handover/console-kit/cr-disposition.sh` |
| `scripts/handover/console-kit/test-console-budget.sh` |
| `scripts/handover/console-kit/test-console-kit-e2e.sh` |
| `scripts/handover/console-kit/test-console-wait-b.sh` |
| `scripts/handover/console-kit/test-console-wait-pool.sh` |
| `scripts/handover/console-kit/test-console-wait-r0.sh` |
| `scripts/handover/console-kit/test-console-wait.sh` |
| `scripts/handover/console/console-bus-exec.sh` |
| `scripts/handover/console/test-console-handoff-roundtrip.sh` |
| `scripts/handover/leg-resume-brief.sh` |
| `scripts/handover/leg-timeline.sh` |
| `scripts/handover/test-arm-resume-bank-refresh.sh` |
| `scripts/handover/test-leg-handoff-threshold-docs.sh` |
| `scripts/handover/test-leg-resume-brief.sh` |
| `scripts/handover/test-leg-timeline.sh` |
| `scripts/hooks/block-bank-lift-writes.sh` |
| `scripts/hooks/console-precompact-snapshot.sh` |
| `scripts/hooks/guard-console-dispatch.sh` |
| `scripts/hooks/guard-leg-cache-ttl.sh` |
| `scripts/hooks/guard-leg-context-handoff.sh` |
| `scripts/hooks/notify-console-on-prompt.sh` |
| `scripts/hooks/stop-console-idle-guard.sh` |
| `scripts/hooks/test-block-bank-lift-writes.sh` |
| `scripts/hooks/test-console-precompact-snapshot.sh` |
| `scripts/hooks/test-guard-console-dispatch.sh` |
| `scripts/hooks/test-guard-leg-cache-ttl.sh` |
| `scripts/hooks/test-guard-leg-context-handoff.sh` |
| `scripts/hooks/test-notify-console-on-prompt.sh` |
| `scripts/hooks/test-stop-console-idle-guard.sh` |
| `scripts/lanes/bench/bank-snapshot-core.mjs` |
| `scripts/lanes/bench/bank-snapshot.sh` |
| `scripts/lanes/bench/scorecard/leg-over-by-day.sh` |
| `scripts/lanes/bench/scorecard/leg-relaunch.sh` |
| `scripts/lanes/bench/scorecard/test-leg-over-by-day.sh` |
| `scripts/lanes/bench/scorecard/test-leg-relaunch.sh` |
| `scripts/lanes/leg-burn.sh` |
| `scripts/lanes/leg-claude-launcher-consult.sh` |
| `scripts/lanes/leg-claude-launcher.sh` |
| `scripts/lanes/leg-cost-report.sh` |
| `scripts/lanes/leg-pr-open.sh` |
| `scripts/lanes/lib/leg-cost-row.sh` |
| `scripts/lanes/srt-poc/leg-battery.sh` |
| `scripts/lanes/test-leg-cost-report.sh` |
| `scripts/lanes/test-leg-pr-open.sh` |
| `scripts/lanes/tests/bench-bank-snapshot.test.mjs` |
| `scripts/lanes/tests/test-leg-burn.sh` |
| `scripts/lib/cr-first-release.sh` |
| `scripts/lib/leg-tail-status.sh` |
| `scripts/probes/claude-p/06-bank-delta.sh` |
| `scripts/telegram/console-census.sh` |
| `scripts/telegram/console-heartbeat-watch.test.ts` |
| `scripts/telegram/console-heartbeat-watch.ts` |
| `scripts/telegram/console-route.test.ts` |
| `scripts/telegram/console-route.ts` |

| Directory | Tracked files | Entry | Owner |
|---|---|---|---|
| `scripts/handover/console-kit/` | 387 | N19 | HIMMEL-6646 |
| `docs/handover/console-sections/` | 12 | N40 | HIMMEL-6646 |
| `docs/handover/leg-sections/` | 6 | N40 | HIMMEL-6646 |
| `scripts/console/` | 4 | N41 | HIMMEL-6646 |
| `scripts/handover/console/` | 6 | N41 | HIMMEL-6646 |
| `scripts/overnight/` | 10 | N41 | HIMMEL-6646 |
| `scripts/eval/leg-digest/` | 25 | N17 | HIMMEL-6646 |
