#!/usr/bin/env bash
# One-shot batch-create of 18 LUNA tickets for the clipper pipeline plan.
# Source: yotam_docs/handovers/yotam/cross/clipper-pipeline-plan-2026-05-26.md.
#
# PROVENANCE RECORD — DO NOT RE-RUN.
# This script ALREADY ran on 2026-05-26 and created the LUNA-3 clipper-pipeline
# tickets (LUNA-8/10/11/21/... — see the plan + the summary it printed). It is
# kept in the tree as the record of HOW those tickets were generated, not as a
# maintained tool. It is NOT idempotent: re-running creates a fresh DUPLICATE of
# every ticket. If you need to (re)generate tickets, make a new dated script or
# add a skip-if-exists guard first.
set -e

cd "$(dirname "$0")/../.."

mkfile=$(mktemp)

# Invoke the jira CLI as node + path (the global `jira` shim points at an
# unrelated package). Wrapped in a function so word-splitting is correct.
JIRA_run() {
  node scripts/jira/dist/index.js "$@"
}

create() {
  local type="$1" title="$2" desc="$3"
  local out key
  out=$(JIRA_run create --project LUNA --type "$type" --title "$title" --desc "$desc" 2>&1) || true
  echo "--- $title ---"
  echo "$out"
  key=$(printf '%s' "$out" | grep -oE 'LUNA-[0-9]+' | head -1)
  echo "$key | $type | $title" >> "$mkfile"
}

read -r -d '' D1 <<'EOF' || true
Add 4th branch to /triage-clips Phase 3 YAML conversion handling bare `tags:` (YAML null, no `[]`). All 245 real clips trip this shape; current spec covers only flow-empty / flow-list / block-list. Surgical ~30min.

DoD:
- 4th branch in plugins/obsidian-triage/commands/triage-clips.md handles bare tags → emit block-list of inferred tags
- New fixture tests/fixtures/clips/bare-tags.md matching real Tweet template output shape
- bash plugins/obsidian-triage/tests/test-triage-invariants.sh returns 0
- PR review-clean + merged

Plan: clipper-pipeline-plan-2026-05-26.md § Chunk 1, § BUG 1.
Deps: none. First chunk; unblocks calibration.
EOF

read -r -d '' D2 <<'EOF' || true
Move .claude/commands/luna-ingest.md content to skill location so Skill tool can dispatch it from inside /harvest-clips runbook. Required because HIMMEL-128 forbids headless claude invocations (would route to separate Agent SDK billing bucket on Max-X5).

Skill path likely plugins/obsidian-triage/skills/luna-ingest/SKILL.md OR new top-level skill. Preserve /luna-ingest <url> at user prompt (skills are user-invokable).

DoD:
- Skill exists at chosen path; passes superpowers:writing-skills checklist
- .claude/commands/luna-ingest.md removed or thinned to wrapper
- Skill tool invocation skill:"obsidian-triage:luna-ingest" works inside runbook (smoke test)
- All existing /luna-ingest tests still pass

Fallback if blocked: Option B inline /luna-ingest logic into /harvest-clips github branch.

Plan: § Chunk 2, §13.
Deps: none. Critical-path unblock for github dispatch.
EOF

read -r -d '' D3 <<'EOF' || true
New /harvest-clips command. Stage 1 of 4-stage pipeline. 6-type dispatch via Skill tool ONLY (no headless claude / no Anthropic API per HIMMEL-128).

Dispatch table:
- tweet → claude-obsidian:x-read (Grok Live Search)
- youtube → claude-obsidian:youtube
- research/article github URL → obsidian-triage:luna-ingest (post-LUNA-21 skill form)
- research/article non-github → obsidian:defuddle + claude-obsidian:research-deep
- reddit → obsidian:defuddle
- newsletter → obsidian:defuddle + claude-obsidian:research

Absorbs MUST-ADD gaps (§12.1):
- G-1 privacy URL gate (deny *.internal/localhost/RFC1918 + .harvest-allow override)
- G-2 vault-sync race lockfile + obsidian-github-sync state check
- G-3 anti-clobber post-write invariant (exactly 1 new "## Harvested content" section)
- G-5 .harvest-run-state.jsonl resume contract (per-clip retry_count, gave_up)
- G-6 env pre-flight (XAI_API_KEY, PERPLEXITY_API_KEY) + headless refusal (CLAUDECODE_HEADLESS=1)

DoD:
- All 6 dispatch branches + --dry-run + --limit N
- 2-3 fixture clips per type (with bare-tags shape from LUNA-8)
- G-gate smoke tests
- /harvest-clips --dry-run --limit 5 ~/Documents/luna reports plan without writing

Plan: § Chunk 3, §2.1, §13.
Deps: LUNA-21 (for github skill invocation).
EOF

read -r -d '' D4 <<'EOF' || true
plugins/obsidian-triage/lib/ — three shared libs sourced by /harvest-clips + /triage-clips + /post-analyze-clips:
- url-canonical.sh per §4.1 (x.com / youtube / github / generic-UTM-stripping rules)
- log.sh per G-7 — log_ok / log_skip / log_fail with jq-parseable format
- frontmatter conventions: harvested_at, harvest_skill, harvest_url_canonical, harvest_status, harvest_dedup_target

DoD:
- 3 libs land with smoke tests
- LUNA-10 refactored to source the libs (no duplicated logic)
- Logging across commands grep-able + jq-able after shim

Plan: § Chunk 4, §4.1, §12.2 G-7.
Deps: LUNA-10 (consumer).
EOF

read -r -d '' D5 <<'EOF' || true
150 of 245 clips are tweets with @handle authors; Luna 20-Areas/<full-name>.md convention has no anchor. Phase 6 cross-suggest fails at scale.

Decide one of:
- (a) Adopt 20-Areas/People/@<handle>.md convention in luna _CLAUDE.md Naming + propagate to Phase 6 lookup
- (c) Drop cross-suggest for tweets; rely on Pattern 4 (folder pressure) at synth when count >= 3

DoD:
- Decision documented in plan + luna _CLAUDE.md
- Phase 6 emits valid cross-suggest OR explicit no-author comment for tweets

Plan: § Chunk 5, § BUG 2.
Deps: LUNA-8. Parallelizable w/ LUNA-10/11/21.
EOF

read -r -d '' D6 <<'EOF' || true
Luna PR-lane change to luna repo (NOT himmel).

Updates:
- Folder Map: add Clippings/ — "Web Clipper landings; processed by /harvest-clips + /triage-clips; clips are pointers to harvested sources, NOT self-contained notes; never auto-promote"
- Auto-Save Rules: add "clips are harvest references; promotion is explicit; run /triage-clips weekly minimum, never auto"
- Frontmatter Requirements: spec new type "clipping" with harvest_* fields

DoD: PR merged in luna repo.
Success criteria: future-Claude reading luna _CLAUDE.md understands harvest model in <30s.

Plan: § Chunk 6, LUNA-3 DoD item 3 (open since pre-2026-05-26).
Deps: LUNA-8. Parallelizable. luna PR-lane (chore/vault prefix).
EOF

read -r -d '' D7 <<'EOF' || true
First end-to-end calibration on 5 real clips. Execute §6 overnight runbook (10 phases + pre-flight gates + block criteria).

Pre-flight:
- luna repo clean (or only Clippings/ untracked)
- >=5 unprocessed clips
- gh api rate_limit OK
- >=500 MB disk free
- No persistent harvest_status: partial from last 24h

Block-points within runbook:
- After harvest --dry-run (operator review)
- After triage --dry-run (operator review)
- Before committing migrated clips

DoD: next-session-5.md written with cycle-1 outcomes + threshold-tuning recommendations.
Success criteria: 5/5 clips processed end-to-end with operator-verified output quality.

Replan triggers (§17): operator rejects >=3/5 outputs OR cost >$5 OR skill output structurally surprising.

Plan: § Chunk 8, §6, §17.
Deps: LUNA-8 + LUNA-10 + LUNA-11 + LUNA-21 minimum.
EOF

read -r -d '' D8 <<'EOF' || true
Stage 3 extension. Existing 4 patterns (concept / author / tag / folder-pressure) unchanged. Add:

- Pattern 5: URL-canonical dedup cluster. Multiple clips with same harvest_url_canonical → propose single canonical 30-Resources/<slug>.md
- Pattern 6: acted-vs-unacted ratio. acted = (items checked in daily notes) / total. <0.2 over 30d → archival; >=0.7 → promotion

Also absorbs G-4 (daily-note overload): cap 20 action items/day; overflow → 50-Journal/Daily/<TODAY>-clip-actions-spill.md.

DoD + success:
- /synthesize-clips --dry-run after Chunk 8 produces >=1 Pattern-5 proposal (empirically verifiable)
- Daily-note cap configurable via --daily-action-cap N (default 20)

Plan: § Chunk 9, §2.3, §12.1 G-4.
Deps: LUNA-11.
EOF

read -r -d '' D9 <<'EOF' || true
Major extension to /harvest-clips. Only start AFTER Chunk 8 calibration passes.

Scope:
- Recursive fan-out crawl: depth=1, --max-fanout 100, --max-sub-artifacts 20
- Repos-from-tweets: post-/x-read scan finds github URLs → dispatch /luna-ingest
- Articles-from-tweets: post-/x-read scan finds non-github URLs → dispatch /research-deep
- Cross-type chaining + parent-backref frontmatter (harvest_parent, harvest_depth)
- Add 5th verdict fork-enhance to /luna-ingest (LUNA-4 statusline-pattern; vendor fork with attribution banner)
- § Community-action subsection per non-skip verdict (attribution + upstream PR + divergence + star/watch)
- Collection-repo sub-pattern (§14.4): README has >=5 sub-artifacts → verdict per sub-artifact
- G-9 wayback fallback on dead URLs

DoD + success:
- /harvest-clips on wshobson/agents clip produces synthesis with sub-artifact verdicts + community-action + fan-out backrefs
- Fan-out budget enforced
- Wayback fallback succeeds on >=30% of dead-URL test fixtures

Plan: § Chunk 10, §3, §5, §14, §12.2 G-9.
Deps: LUNA-10 + LUNA-11 + LUNA-16 (calibration pass).
EOF

read -r -d '' D10 <<'EOF' || true
/synthesize-clips gains per-window meta-page generation. A window is a contiguous range of triaged_at dates. Default 7-day window via --window-days N.

Per-window output Clippings/_synthesis/window-<WINDOW_END>-<N>-clips.md:
- Body: TL;DR of operator interests across window; top-3 concept clusters; top-3 authors; promotion candidates
- Frontmatter: window_start, window_end, clip_count, concept_clusters, top_authors, dominant_types, harvest_health (% successful)

Window pages link to per-pattern synth pages (meta-index).

DoD: against 2026-05-25 batch produces ONE window page summarizing 245-clip session interest themes.

Plan: § Chunk 11, §2.3.
Deps: LUNA-12.
EOF

read -r -d '' D11 <<'EOF' || true
Stage 4 of 4-stage pipeline. Closes feedback loop — without this, pipeline never learns from runs.

Generates 5 reports per run:
- Harvest-health: % ok / partial / failed by skill; timeout + rate-limit incidence; cost per clip
- Triage-quality: tag precision; Phase 4 wikilink click-through proxy; Phase 6 promotion-target acceptance
- Synth-decision tracking: per synth page → accepted (_done/) | rejected (deleted) | pending
- Fan-out ROI: per depth-1 fan-out → did it produce action items / promotions / community-action?
- Action-item completion: % checked within 30d

Output:
- Clippings/_post-analyze/<WINDOW_END>-report.md
- Clippings/_post-analyze/<WINDOW_END>-recommendations.md

Includes § Meta-relevant clips (§22.4): clips tagged scraping/crawler/content-extraction/playwright/defuddle.

Read-only over vault except report files.

DoD: against Chunk 8 + 15 data → report identifies >=1 actionable threshold-tuning recommendation.

Plan: § Chunk 13, §2 Stage 4, §22.4.
Deps: LUNA-12 + LUNA-15.
EOF

read -r -d '' D12 <<'EOF' || true
Append-only log of operator-accepted/rejected synth proposals. Powers LUNA-17 synth-decision tracking.

Detection: file-watcher OR polled scan of Clippings/_synthesis/ — page moved to _done/ → decision: accepted; deleted → decision: rejected.

Storage per OQ-9. Default proposed: out-of-vault under yotam_docs/state/luna/decisions.jsonl. Alt: in-vault Clippings/_post-analyze/decisions.jsonl.

DoD + success: moving a synth page writes a decision line within 1s.

Plan: § Chunk 14, OQ-9.
Deps: LUNA-17.
EOF

read -r -d '' D13 <<'EOF' || true
Optional split from LUNA-12. May fold there.

Daily note overload mitigation (G-4): cap 20 action items appended to one day; overflow → 50-Journal/Daily/<TODAY>-clip-actions-spill.md. Configurable via --daily-action-cap N.

DoD: at 30 candidate action items → 20 in daily note + 10 in spill + main note links spill.

Plan: § Chunk 9, §12.1 G-4.
Deps: LUNA-10. Lands in /triage-clips runbook.
EOF

read -r -d '' D14 <<'EOF' || true
Per-run rollback patch + --revert-last-run flag with dry-run preview. Operator confidence + autonomous-run safety.

Mechanism:
- HARVEST writes <vault>/.harvest-run-rollback-<RUNID>.patch (git diff-format reversal) alongside G-5 state file
- /harvest-clips --revert-last-run reads most recent rollback patch
- git apply -R --check first (preview) → git apply -R if --confirm
- Refuses if any clip touched by run has been edited since (SHA check vs G-5)

DoD + success: revert against smoke test run cleanly restores pre-run state.

Plan: § Chunk 12, §12.2 G-8.
Deps: LUNA-10. Independent of Phase 4.
EOF

read -r -d '' D15 <<'EOF' || true
CONDITIONAL v1 — G-10 promoted from DEFER per §18.

Without this calibration cycle N looks fine; cycle N+1 looks fine; cycle N+M reveals quality silently sank.

Mechanism:
- On Chunk 8 first calibration: capture literal output of /x-read, /youtube, /research-deep, defuddle on 1 fixture URL each
- Store at plugins/obsidian-triage/tests/fixtures/golden-outputs/<skill>-<sha>.md
- LUNA-17 diffs current output vs golden each cycle
- Diff >20% line-distance → schema-drift warning in /post-analyze report

DoD: golden fixtures captured; LUNA-17 emits warning when test diff exceeds threshold.

Plan: § Chunk 17, §18.
Deps: LUNA-17.
EOF

read -r -d '' D16 <<'EOF' || true
CONDITIONAL — sub-task of LUNA-16 calibration.

Operator framing 2026-05-26: "we need to ingest because the contract will change."

Sample 20 clips by type during Chunk 8. For each clip rate per-rung sufficiency (rung 0 = clip body as-shipped, rung 1 = skill, etc — §22 ladder).

Output: clipper-capture-eval.md summarizing per-type rung-0 sufficiency %.

Decision feeds:
- LUNA-37 if any type has <30% rung-0 sufficiency
- LUNA-38 if >=15% of clips exhaust rungs 1-6

DoD: eval report committed; LUNA-37/38 filing decisions documented.

Plan: § Chunk 8 sub, §22.
Deps: LUNA-16.
EOF

read -r -d '' D17 <<'EOF' || true
CONDITIONAL — re-capture cycle. File only if LUNA-36 flags type with <30% rung-0 sufficiency.

Action:
- Revise affected templates in luna _Templates/Web-Clipper/ to capture more {{content}} + additional Web Clipper vars
- Operator re-pastes (or re-imports JSON) into extension
- Commit revisions to luna repo

DoD: revised templates merged; clip-test of one route per revised template confirms richer capture.

Plan: § Chunk 6 ladder rung 6, §22.5.
Deps: LUNA-36 findings.
EOF

read -r -d '' D18 <<'EOF' || true
CONDITIONAL v2 — file only when calibration cycle 2 + LUNA-17 cycle-2 report shows >=15% of clips with harvest_status: rung_3_exhausted_still_insufficient AND >=50% structurally JS-SPA / paywalled.

Mechanism: headless Chrome dispatch (Playwright or CDP) for clips exhausting rungs 1-6. Cost cap + bot-detection backoff (CAPTCHA → halt + flag, do not retry).

Per HIMMEL-128: scrape → defuddle → feed into Skill-tool reasoning loop. Never call Anthropic API directly.

Barriers (§22.3):
- Cost (~$0.10/page Lambda or ~30s local CPU; 245 clips ~$25 or ~2h)
- Bot-detection arms race
- No-API constraint (workaround via Skill-tool)

DoD: rung-7 dispatches succeed on JS-SPA fixture URLs; cost cap enforced; failures flagged not silently retried.

Plan: § Chunk-conditional, §22.3.
Deps: LUNA-16 + LUNA-17 cycle-2 report.
EOF

create "Task"  "obsidian-triage Phase 3: bare-tags YAML branch (LUNA-3 Chunk 1)"                              "$D1"
create "Task"  "/luna-ingest slash-cmd to skill conversion (HIMMEL-128 unblock) (LUNA-3 Chunk 2)"             "$D2"
create "Story" "obsidian-triage: /harvest-clips MVP Stage 1 dispatch (LUNA-3 Chunk 3)"                        "$D3"
create "Task"  "obsidian-triage: shared libs url-canonical log frontmatter (LUNA-3 Chunk 4)"                  "$D4"
create "Task"  "obsidian-triage Phase 6: @handle author convention (LUNA-3 Chunk 5)"                          "$D5"
create "Task"  "luna _CLAUDE.md: Folder Map + Auto-Save Rules + harvest_* frontmatter (LUNA-3 Chunk 6)"       "$D6"
create "Task"  "obsidian-triage: calibration cycle 1 overnight runbook (LUNA-3 Chunk 8)"                      "$D7"
create "Story" "obsidian-triage: /synthesize-clips Pattern 5+6 + daily-note cap (LUNA-3 Chunk 9)"             "$D8"
create "Story" "obsidian-triage: recursive fan-out + fork-enhance + collection-repo + wayback (LUNA-3 Chunk 10)" "$D9"
create "Story" "obsidian-triage: window synthesis per-window meta-pages (LUNA-3 Chunk 11)"                    "$D10"
create "Story" "obsidian-triage: /post-analyze-clips Stage 4 (LUNA-3 Chunk 13)"                               "$D11"
create "Task"  "obsidian-triage: decision-tracking feedback loop (LUNA-3 Chunk 14)"                           "$D12"
create "Task"  "obsidian-triage: daily-note action-item cap + spill file (LUNA-3 Chunk 9 sub)"                "$D13"
create "Task"  "obsidian-triage: /harvest-clips --revert-last-run rollback (LUNA-3 Chunk 12)"                 "$D14"
create "Task"  "obsidian-triage: skill-output schema drift detection golden fixtures (LUNA-3 Chunk 17 conditional)" "$D15"
create "Task"  "obsidian-triage: Web Clipper content-capture completeness eval (Chunk 8 sub conditional)"     "$D16"
create "Task"  "LUNA-2 template revision based on calibration findings (conditional on LUNA-36)"              "$D17"
create "Story" "obsidian-triage: browser automation rung-7 Playwright/CDP (conditional on Chunk 15)"          "$D18"

echo
echo "=== SUMMARY (ticket | type | title) ==="
cat "$mkfile"
rm -f "$mkfile"
