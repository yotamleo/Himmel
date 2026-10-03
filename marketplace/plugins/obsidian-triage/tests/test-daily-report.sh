#!/usr/bin/env bash
# Fixture-vault acceptance test for the daily report (HIMMEL-4182).
#
# `tools/daily-timeline.mjs --vault V --date D` also upserts a `## Daily report`
# section into the day note: that day's triaged sources grouped by
# evidence_kind (title, link, one-line why, video line), a ranked list of
# deterministic suggested actions (each citing its clips, carrying a stable
# `act:<id>` marker), and a carry-over of earlier unacted actions with their
# age. `[x]` = done, `[-]` = dismissed. A day with no intake writes a
# "No intake" line. A missing day note is created from the vault template.
#
# Contract under test:
#   - a day with 3 clips: sources (grouped, why line, video line), >=1 action
#     citing a clip, carry-over of the prior day's unchecked action with age.
#   - done / dismissed / ticked-anywhere actions are NOT carried over.
#   - re-run is byte-identical; a tick on today's report survives a re-run.
#   - a no-intake day writes the line, and creates the missing note.
#   - everything outside the section is byte-identical.

set -u -o pipefail

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
has() { # desc file fixed-string
    if grep -qF -- "$3" "$2"; then assert "$1" yes yes; else assert "$1" yes no; fi
}
lacks() { # desc file fixed-string
    if grep -qF -- "$3" "$2"; then assert "$1" absent present; else assert "$1" absent absent; fi
}

D="2026-06-28"
P="2026-06-27"
PP="2026-06-26"
N="2026-06-29"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
V="$tmp/vault"
mkdir -p "$V/Clippings/_evidence" "$V/50-Journal/Daily" "$V/60-Maps" "$V/_Templates"

cat > "$V/_Templates/Daily-Note.md" <<'EOF'
---
date: {{date}}
tags: [journal/daily]
---

# {{date}}

## Focus
Top 3 things for today:
EOF

cat > "$V/60-Maps/Claude-Code-MOC.md" <<'EOF'
---
type: moc
tags:
  - claude-code
  - moc
---
# Claude Code MOC
EOF

# Clip A — concept, tag matches the MOC → fold into it.
cat > "$V/Clippings/_evidence/clip-a.md" <<EOF
---
title: "Context budgets for agents"
source: https://x.com/someone/status/1
type: tweet
tags:
  - claude-code
processed: true
triaged_at: $D
evidence_kind:
  - concepts
tweet_stats: { replies: 1, retweets: 2, quotes: 0, likes: 500, views: 9000 }
---

# tweet

https://x.com/someone/status/1

## The Idea
<!-- enriched -->

Agents need explicit context budgets. Everything else follows from that.
EOF

# Clip B — a github repo → evaluate the tool.
cat > "$V/Clippings/_evidence/clip-b.md" <<EOF
---
title: "nvidia/openshell"
source: https://github.com/nvidia/openshell
type: research
processed: true
triaged_at: $D
evidence_kind:
  - tools
---

A sandboxed shell for agents, with policy files.
EOF

# Clip C — a video with transcript metadata, no fold target.
cat > "$V/Clippings/_evidence/clip-c.md" <<EOF
---
title: "Talk on eval design"
source: https://x.com/other/status/2
type: tweet
processed: true
triaged_at: $D
evidence_kind:
  - patterns
media_video_duration_s: 754
media_transcript_coverage: 92
media_transcript_source: auto-subs
---

## The Idea

Eval design is the bottleneck for agent work. A long second sentence.
EOF

# Clip from another day — not a source for D.
cat > "$V/Clippings/_evidence/clip-old.md" <<EOF
---
title: "Old clip"
triaged_at: $P
evidence_kind:
  - concepts
---
old body
EOF

# Prior-day reports: one open, one done, one dismissed, one ticked earlier.
cat > "$V/50-Journal/Daily/$PP.md" <<EOF
# $PP

## Daily report

### Suggested actions

- [ ] Fold [[Clippings/x]] into [[60-Maps/Old-MOC]] <!-- act:aaaa1111 since:$PP -->
- [x] Evaluate tool [[Clippings/y]] <!-- act:dddd4444 since:$PP -->
EOF
cat > "$V/50-Journal/Daily/$P.md" <<EOF
# $P

## Daily report

### Suggested actions

- [x] Archive [[Clippings/z]] <!-- act:bbbb2222 since:$P -->
- [-] File a ticket in himmel for [[Clippings/w]] <!-- act:cccc3333 since:$P -->

### Carried over

- [ ] (1d) Fold [[Clippings/x]] into [[60-Maps/Old-MOC]] <!-- act:aaaa1111 since:$PP -->
- [ ] (1d) Evaluate tool [[Clippings/y]] <!-- act:dddd4444 since:$PP -->
EOF

DAILY="$V/50-Journal/Daily/$D.md"
cat > "$DAILY" <<EOF
---
type: daily
---

# $D

## Journal

Morning thoughts that must not be touched.
EOF

echo "Test 1: a day with 3 clips gets one ## Daily report section"
node "$TOOL" --vault "$V" --date "$D" >/dev/null 2>&1
assert "tool exits 0" "0" "$?"
assert "exactly one '## Daily report' heading" "1" "$(grep -c '^## Daily report$' "$DAILY")"
has "journal preserved" "$DAILY" "Morning thoughts that must not be touched."
has "clip pipeline section still written" "$DAILY" "## Clip pipeline"

echo "Test 2: sources grouped by evidence_kind, with links and why lines"
has "sources count line" "$DAILY" "### Sources (3)"
has "concepts group" "$DAILY" "**concepts**"
has "tools group" "$DAILY" "**tools**"
has "clip A link + title" "$DAILY" "[[Clippings/_evidence/clip-a|Context budgets for agents]]"
has "clip A why = first sentence of The Idea" "$DAILY" "— Agents need explicit context budgets."
lacks "why stops at the first sentence" "$DAILY" "Everything else follows"
has "clip B why = first prose line" "$DAILY" "— A sandboxed shell for agents, with policy files."
lacks "other-day clip excluded" "$DAILY" "clip-old"

echo "Test 3: video line only for the clip carrying media keys"
has "video line for clip C" "$DAILY" "video 12:34 · transcript 92% (auto-subs)"
assert "exactly one video line" "1" "$(grep -c 'video [0-9]' "$DAILY")"

echo "Test 4: ranked suggested actions cite their clips"
has "suggested actions heading" "$DAILY" "### Suggested actions"
fold=$(grep -F 'Fold [[Clippings/_evidence/clip-a' "$DAILY")
if printf '%s' "$fold" | grep -qF 'into [[60-Maps/Claude-Code-MOC]]'; then f=yes; else f=no; fi
assert "fold action targets the tag-matched MOC  [$fold]" "yes" "$f"
if printf '%s' "$fold" | grep -qE '^- \[ \] .*<!-- act:[0-9a-f]{8} since:2026-06-28 -->$'; then f=yes; else f=no; fi
assert "fold action is an unchecked item with act marker" "yes" "$f"
has "evaluate-tool action for the github clip, with rubric link" "$DAILY" "Evaluate tool [[Clippings/_evidence/clip-b|nvidia/openshell]]"
has "rubric link" "$DAILY" "docs/tool-adoption/rubric.md"
has "no-target clip gets an archive action" "$DAILY" "Archive [[Clippings/_evidence/clip-c|Talk on eval design]]"
first=$(sed -n '/^### Suggested actions$/,/^### /p' "$DAILY" | grep -m1 '^- \[')
if printf '%s' "$first" | grep -qF 'Archive'; then f=archive-first; else f=ok; fi
assert "archive ranks below fold/evaluate" "ok" "$f"

echo "Test 5: carry-over"
has "carried-over heading" "$DAILY" "### Carried over"
carry=$(grep -F 'act:aaaa1111' "$DAILY")
if printf '%s' "$carry" | grep -qF -- '- [ ] (2d) Fold [[Clippings/x]] into [[60-Maps/Old-MOC]] <!-- act:aaaa1111 since:2026-06-26 -->'; then f=yes; else f=no; fi
assert "open prior action carried with age 2d  [$carry]" "yes" "$f"
lacks "done action not carried" "$DAILY" "act:bbbb2222"
lacks "dismissed action not carried" "$DAILY" "act:cccc3333"
lacks "action ticked in an older note not carried" "$DAILY" "act:dddd4444"

echo "Test 6: re-run is byte-identical; a tick on today's report survives"
sha1=$(sha256sum "$DAILY" | cut -d' ' -f1)
node "$TOOL" --vault "$V" --date "$D" >/dev/null 2>&1
assert "byte-identical re-run" "$sha1" "$(sha256sum "$DAILY" | cut -d' ' -f1)"
sed -i 's/^- \[ \] Fold \[\[Clippings\/_evidence\/clip-a/- [x] Fold [[Clippings\/_evidence\/clip-a/' "$DAILY"
sed -i 's/^- \[ \] Archive \[\[Clippings\/_evidence\/clip-c/- [-] Archive [[Clippings\/_evidence\/clip-c/' "$DAILY"
node "$TOOL" --vault "$V" --date "$D" >/dev/null 2>&1
has "done tick survives the re-run" "$DAILY" "- [x] Fold [[Clippings/_evidence/clip-a"
has "dismissed mark survives the re-run" "$DAILY" "- [-] Archive [[Clippings/_evidence/clip-c"

echo "Test 7: no-intake day creates the missing note, writes the line, carries open items"
ND="$V/50-Journal/Daily/$N.md"
node "$TOOL" --vault "$V" --date "$N" >/dev/null 2>&1
assert "tool exits 0" "0" "$?"
if [ -f "$ND" ]; then f=created; else f=missing; fi
assert "missing day note created" "created" "$f"
has "created from the vault template" "$ND" "## Focus"
has "template date filled in" "$ND" "# $N"
has "no-intake line" "$ND" "- No intake on $N."
has "evaluate action from D carried (1d)" "$ND" "(1d) Evaluate tool [[Clippings/_evidence/clip-b"
has "aaaa1111 still carried, age 3d" "$ND" "(3d) Fold [[Clippings/x]]"
lacks "done fold action not carried" "$ND" "clip-a"
lacks "dismissed archive action not carried" "$ND" "clip-c"
assert "one Daily report section" "1" "$(grep -c '^## Daily report$' "$ND")"

echo "Test 8: a CRLF day note keeps CRLF"
C="2026-06-30"
printf -- '---\r\ntype: daily\r\n---\r\n\r\n# %s\r\n\r\nkeep me\r\n' "$C" > "$V/50-Journal/Daily/$C.md"
node "$TOOL" --vault "$V" --date "$C" >/dev/null 2>&1
lf_only=$(grep -cv $'\r$' "$V/50-Journal/Daily/$C.md")
assert "no bare-LF lines in the CRLF note" "0" "$lf_only"

echo "Test 9: long titles are shortened and a busy fold action caps its cited links"
B="2026-07-05"
long="$(printf 'word%.0s ' $(seq 1 30))"
for i in 1 2 3 4; do
    cat > "$V/Clippings/_evidence/busy-$i.md" <<EOF
---
title: "busy $i $long"
tags:
  - claude-code
triaged_at: $B
evidence_kind:
  - concepts
---
Busy clip number $i.
EOF
done
node "$TOOL" --vault "$V" --date "$B" >/dev/null 2>&1
BD="$V/50-Journal/Daily/$B.md"
fold=$(grep -F 'into [[60-Maps/Claude-Code-MOC]]' "$BD")
if printf '%s' "$fold" | grep -qF 'and 1 more into'; then f=yes; else f=no; fi
assert "fold over 4 clips names 3 and says 'and 1 more'" "yes" "$f"
assert "fold line cites exactly 3 links" "3" "$(printf '%s' "$fold" | grep -o '\[\[Clippings' | wc -l | tr -d ' ')"
has "long title shortened with an ellipsis" "$BD" "|busy 1 word word"
if grep -qE '\|busy 1 [^]]{78,}\]\]' "$BD"; then f=long; else f=short; fi
assert "displayed title is at most 80 chars" "short" "$f"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
