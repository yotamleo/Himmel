#!/usr/bin/env bash
# Fixture-gated acceptance test for the daily-timeline integration (LUNA-90).
#
# The `## Clip pipeline` section in 50-Journal/Daily/<date>.md is a *state
# recount*: `tools/daily-timeline.mjs --vault V --date D` recomputes all four
# metrics (captured → inbox / reviewed → evidence by kind / promoted → subjects
# / densified subjects) from vault state + the synthesize ledger and upserts a
# SINGLE section. Because it recounts from state, it is idempotent by
# construction — re-running the SAME day UPDATES the one section and never
# appends a second or double-counts (handover HARD GUARDRAIL #1).
#
# Contract under test:
#   - exactly one `## Clip pipeline` section, four metric lines.
#   - correct captured/reviewed(by-kind)/promoted/densified counts + [[subject]]
#     backrefs, anchored to the target date only (other dates excluded).
#   - a second same-day run is byte-identical (no duplicate, no double-count).
#   - pre-existing daily-note content (`## Actions from clips`, journal) preserved.
#   - CRLF notes keep CRLF.
#   - a missing daily note is a no-op (exit 0, no phantom file).

set -u -o pipefail

# Pin a fixed UTC+2 zone so the ledger UTC→local-date conversion (localDateOf)
# is deterministic regardless of the runner's machine timezone. Etc/GMT-2 is a
# fixed (no-DST) UTC+2 offset — note the IANA sign inversion.
export TZ='Etc/GMT-2'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/daily-timeline.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

D="2026-06-28"
OTHER="2026-06-20"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/.obsidian"
mkdir -p "$tmp/Clippings/_evidence"
mkdir -p "$tmp/50-Journal/Daily"
mkdir -p "$tmp/30-Resources/Concepts"
mkdir -p "$tmp/60-Maps"

# ── captured: clips with date_clipped == D (regardless of current folder) ─────
cap_clip() { # name date
    cat > "$tmp/Clippings/$1" <<EOF
---
title: "cap $1"
date_clipped: $2
type: article
---
body
EOF
}
cap_clip cap-a.md "$D"
cap_clip cap-b.md "$D"
cap_clip cap-old.md "$OTHER"   # other day → not counted

# ── reviewed: clips in _evidence/ with triaged_at == D, by evidence_kind ──────
ev_clip() { # name triaged_at kind1 [kind2]
    local name="$1" tdate="$2"; shift 2
    {
        echo "---"
        echo "title: \"ev $name\""
        echo "processed: true"
        echo "triaged_at: $tdate"
        echo "evidence_kind:"
        for k in "$@"; do echo "  - $k"; done
        echo "---"
        echo "body"
    } > "$tmp/Clippings/_evidence/$name"
}
ev_clip ev1.md "$D" concepts
ev_clip ev2.md "$D" concepts tools
ev_clip ev3.md "$D" tools
ev_clip ev-old.md "$OTHER" concepts   # other day → not counted

# ── promoted / densified: from the synthesize-stubs ledger (ts date) ─────────
# The recount is STATE-based: a ledger subject is listed only if its page exists
# on disk (so a created-then-reverted stub never dangles). Create the pages the
# ledger references.
printf -- '---\nstatus: stub\n---\n# Context Windows\n' > "$tmp/30-Resources/Concepts/Context-Windows.md"
printf -- '---\nstatus: stub\n---\n# Agent Loops\n'     > "$tmp/30-Resources/Concepts/Agent-Loops.md"
printf -- '---\ntype: moc\n---\n# RAG MOC\n'            > "$tmp/60-Maps/RAG-MOC.md"
LED="$tmp/.synthesize-stubs.ledger.jsonl"
cat > "$LED" <<EOF
{"ts":"${D}T01:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Context-Windows.md","concept_key":"context-windows"}
{"ts":"${D}T02:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Agent-Loops.md","concept_key":"agent-loops"}
{"ts":"${D}T03:00:00.000Z","action":"densify","subject":"60-Maps/RAG-MOC.md","concept_key":"rag"}
{"ts":"${OTHER}T01:00:00.000Z","action":"stub-create","subject":"30-Resources/Concepts/Old-Thing.md","concept_key":"old"}
EOF

# ── the daily note (pre-existing content must survive) ────────────────────────
DAILY="$tmp/50-Journal/Daily/$D.md"
cat > "$DAILY" <<'EOF'
---
type: daily
date: 2026-06-28
---

# 2026-06-28

## Actions from clips

- [ ] follow up on context windows (from [[Clippings/cap-a]])

## Journal

Morning thoughts that must not be touched.
EOF

# ── Run 1 ─────────────────────────────────────────────────────────────────────
echo "Test 1: first run writes a single ## Clip pipeline section"
node "$TOOL" --vault "$tmp" --date "$D" >/dev/null 2>&1
n_sections=$(grep -c '^## Clip pipeline$' "$DAILY")
assert "exactly one '## Clip pipeline' heading" "1" "$n_sections"

echo "Test 2: captured count (date_clipped == D) = 2"
cap_line=$(grep -F 'Captured → inbox:' "$DAILY")
if printf '%s' "$cap_line" | grep -qE '\*\* 2$'; then f=yes; else f=no; fi
assert "captured line shows 2 (cap-a, cap-b; cap-old excluded)  [$cap_line]" "yes" "$f"

echo "Test 3: reviewed total = 3 with by-kind breakdown"
rev_line=$(grep -F 'Reviewed → evidence:' "$DAILY")
if printf '%s' "$rev_line" | grep -qE '\*\* 3'; then f=yes; else f=no; fi
assert "reviewed total = 3 (ev1/ev2/ev3; ev-old excluded)  [$rev_line]" "yes" "$f"
if printf '%s' "$rev_line" | grep -q 'concepts 2'; then f=yes; else f=no; fi
assert "reviewed by-kind shows 'concepts 2'" "yes" "$f"
if printf '%s' "$rev_line" | grep -q 'tools 2'; then f=yes; else f=no; fi
assert "reviewed by-kind shows 'tools 2'" "yes" "$f"

echo "Test 4: promoted lists today's stub-create subjects as backrefs"
prom_line=$(grep -F 'Promoted → subjects:' "$DAILY")
if printf '%s' "$prom_line" | grep -qF '[[30-Resources/Concepts/Context-Windows]]'; then f=yes; else f=no; fi
assert "promoted line backrefs Context-Windows" "yes" "$f"
if printf '%s' "$prom_line" | grep -qF '[[30-Resources/Concepts/Agent-Loops]]'; then f=yes; else f=no; fi
assert "promoted line backrefs Agent-Loops" "yes" "$f"
if printf '%s' "$prom_line" | grep -qF 'Old-Thing'; then f=leaked; else f=excluded; fi
assert "promoted excludes other-day Old-Thing" "excluded" "$f"

echo "Test 5: densified lists today's densify subjects"
dens_line=$(grep -F 'Densified subjects:' "$DAILY")
if printf '%s' "$dens_line" | grep -qF '[[60-Maps/RAG-MOC]]'; then f=yes; else f=no; fi
assert "densified line backrefs RAG-MOC" "yes" "$f"

echo "Test 6: pre-existing content preserved"
if grep -qF 'Morning thoughts that must not be touched.' "$DAILY"; then f=yes; else f=no; fi
assert "journal line preserved" "yes" "$f"
if grep -qF '(from [[Clippings/cap-a]])' "$DAILY"; then f=yes; else f=no; fi
assert "Actions-from-clips line preserved" "yes" "$f"

# ── Run 2 — idempotent (byte-identical) ──────────────────────────────────────
echo "Test 7: second same-day run is byte-identical (no duplicate, no double-count)"
sha1=$(sha256sum "$DAILY" | cut -d' ' -f1)
node "$TOOL" --vault "$tmp" --date "$D" >/dev/null 2>&1
sha2=$(sha256sum "$DAILY" | cut -d' ' -f1)
assert "daily note unchanged on re-run" "$sha1" "$sha2"
n_sections=$(grep -c '^## Clip pipeline$' "$DAILY")
assert "still exactly one '## Clip pipeline' after re-run" "1" "$n_sections"

# ── Refresh — new evidence today bumps the count, section refreshed in place ──
echo "Test 8: a new same-day reviewed clip refreshes the count (still one section)"
ev_clip ev4.md "$D" patterns
node "$TOOL" --vault "$tmp" --date "$D" >/dev/null 2>&1
n_sections=$(grep -c '^## Clip pipeline$' "$DAILY")
assert "still one section after state change" "1" "$n_sections"
rev_line=$(grep -F 'Reviewed → evidence:' "$DAILY")
if printf '%s' "$rev_line" | grep -qE '\*\* 4'; then f=yes; else f=no; fi
assert "reviewed total refreshed to 4  [$rev_line]" "yes" "$f"

# ── CRLF preservation ────────────────────────────────────────────────────────
echo "Test 9: CRLF daily note keeps CRLF line endings"
CRLF_D="2026-06-29"
CRLF_DAILY="$tmp/50-Journal/Daily/$CRLF_D.md"
printf -- '---\r\ntype: daily\r\n---\r\n\r\n# %s\r\n\r\n## Journal\r\n\r\nkeep me\r\n' "$CRLF_D" > "$CRLF_DAILY"
node "$TOOL" --vault "$tmp" --date "$CRLF_D" >/dev/null 2>&1
if grep -qU $'\r' "$CRLF_DAILY"; then f=yes; else f=no; fi
assert "CRLF endings preserved after upsert" "yes" "$f"
if grep -c '^## Clip pipeline' "$CRLF_DAILY" >/dev/null && [ "$(grep -c 'Clip pipeline' "$CRLF_DAILY")" = "1" ]; then f=yes; else f=no; fi
assert "CRLF note got exactly one pipeline section" "yes" "$f"

# ── Missing daily note → no-op, no phantom ───────────────────────────────────
echo "Test 10: missing daily note is a no-op (exit 0, no phantom file)"
node "$TOOL" --vault "$tmp" --date "2030-01-01" >/dev/null 2>&1
rc=$?
assert "exit 0 on missing daily note" "0" "$rc"
if [ -f "$tmp/50-Journal/Daily/2030-01-01.md" ]; then f=created; else f=absent; fi
assert "no phantom daily note created" "absent" "$f"

# ── State-truth: a reverted stub (page gone) drops from the recount ──────────
echo "Test 11: a created-then-reverted stub (page deleted) is NOT listed (no dangling backref)"
rm -f "$tmp/30-Resources/Concepts/Agent-Loops.md"   # simulate synthesize-stubs --revert
node "$TOOL" --vault "$tmp" --date "$D" >/dev/null 2>&1
prom_line=$(grep -F 'Promoted → subjects:' "$DAILY")
if printf '%s' "$prom_line" | grep -qF '[[30-Resources/Concepts/Agent-Loops]]'; then f=dangling; else f=dropped; fi
assert "reverted subject dropped from Promoted line" "dropped" "$f"
if printf '%s' "$prom_line" | grep -qF '[[30-Resources/Concepts/Context-Windows]]'; then f=yes; else f=no; fi
assert "surviving subject still listed" "yes" "$f"

# ── Cross-folder captured: a clip captured today but already moved to _evidence ─
echo "Test 12: captured counts a date_clipped==D clip that moved into _evidence/"
cat > "$tmp/Clippings/_evidence/cap-moved.md" <<EOF
---
title: "captured then reviewed same day"
date_clipped: $D
triaged_at: $OTHER
type: article
---
body
EOF
node "$TOOL" --vault "$tmp" --date "$D" >/dev/null 2>&1
cap_line=$(grep -F 'Captured → inbox:' "$DAILY")
if printf '%s' "$cap_line" | grep -qE '\*\* 3$'; then f=yes; else f=no; fi
assert "captured now 3 (cap-a, cap-b, cap-moved in _evidence)  [$cap_line]" "yes" "$f"

# ── Timezone boundary: ledger UTC ts maps to the operator's LOCAL day ────────
# Under TZ=Etc/GMT-2 (UTC+2), a promotion logged at 23:30 UTC on 06-30 happened
# at 01:30 LOCAL on 07-01 — it must land in the 07-01 daily note (the operator's
# wall-clock day), NOT the 06-30 UTC note. Regression for the off-by-one a naive
# ts.slice(0,10) caused (found in live staging).
echo "Test 13: ledger UTC ts is bucketed by LOCAL day, not UTC day"
BD="2026-07-01"; BUTC="2026-06-30"
printf -- '---\nstatus: stub\n---\n# Boundary Subject\n' > "$tmp/30-Resources/Concepts/Boundary-Subject.md"
printf '%s\n' "{\"ts\":\"${BUTC}T23:30:00.000Z\",\"action\":\"stub-create\",\"subject\":\"30-Resources/Concepts/Boundary-Subject.md\",\"concept_key\":\"boundary\"}" >> "$LED"
printf -- '---\ntype: daily\ndate: %s\n---\n\n# %s\n' "$BD" "$BD"     > "$tmp/50-Journal/Daily/$BD.md"
printf -- '---\ntype: daily\ndate: %s\n---\n\n# %s\n' "$BUTC" "$BUTC" > "$tmp/50-Journal/Daily/$BUTC.md"
node "$TOOL" --vault "$tmp" --date "$BD"   >/dev/null 2>&1
node "$TOOL" --vault "$tmp" --date "$BUTC" >/dev/null 2>&1
if grep -F 'Promoted → subjects:' "$tmp/50-Journal/Daily/$BD.md" | grep -qF '[[30-Resources/Concepts/Boundary-Subject]]'; then f=yes; else f=no; fi
assert "promotion lands in the LOCAL-day note ($BD)" "yes" "$f"
if grep -F 'Promoted → subjects:' "$tmp/50-Journal/Daily/$BUTC.md" | grep -qF 'Boundary-Subject'; then f=leaked; else f=excluded; fi
assert "promotion does NOT appear in the UTC-day note ($BUTC)" "excluded" "$f"

# ── Structural: runbooks invoke the tool ─────────────────────────────────────
echo "Test 14: triage + synthesize runbooks wire daily-timeline.mjs"
if grep -qF 'tools/daily-timeline.mjs' "$PLUGIN_DIR/commands/triage-clips.md"; then f=yes; else f=no; fi
assert "triage-clips.md invokes daily-timeline.mjs" "yes" "$f"
if grep -qF 'tools/daily-timeline.mjs' "$PLUGIN_DIR/commands/synthesize-stubs.md"; then f=yes; else f=no; fi
assert "synthesize-stubs.md invokes daily-timeline.mjs" "yes" "$f"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
