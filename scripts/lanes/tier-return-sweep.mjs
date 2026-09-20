#!/usr/bin/env node
// scripts/lanes/tier-return-sweep.mjs - RETIRED (HIMMEL-3269; was the P0.3
// Tier-return counter, HIMMEL-2977 G10).
//
// It counted subagent transcripts ending in a `> **Tier-return:** <reason>`
// marker and printed `<model> <returned>/<dispatched>`. Nothing ever instructed
// a child to emit that marker: leg-preface.md is read by headed top-level legs,
// and this sweep only counted `subagents/` transcripts, so the two never met.
// `sonnet 0/77` was the arithmetic of an unemitted marker, not evidence that no
// Sonnet child escalated - a gate that could not fail. A counter wired to
// nothing is worse than no counter, so it is retired rather than left printing.
//
// The replacement signal is observed, not declared: a Sonnet subagent whose task
// was re-dispatched to a higher tier. That is a HIMMEL-2976 gate concern; see
// docs/internals/lane-calibration.md, "Tier-return marker (retired)".
//
// Platform guard: no .ps1 twin, by design. Node 18+, same on every platform.
console.error(
  'tier-return-sweep: RETIRED (HIMMEL-3269). No child was ever instructed to emit the ' +
    '`> **Tier-return:**` marker, so this counter read 0 whatever the escalation rate; it prints no counts. ' +
    'Measure escalation as an observed re-dispatch to a higher tier instead (HIMMEL-2976).',
);
process.exit(1);
