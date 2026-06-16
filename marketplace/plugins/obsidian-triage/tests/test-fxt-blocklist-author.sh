#!/usr/bin/env bash
# Regression: frontmatter-only enrich of a NON-thin @ tweet whose `author:` heads
# a YAML block-list must PRESERVE the author list (not delete the key and orphan
# its `  - "@handle"` items into invalid YAML). Surfaced by the live backfill:
# 31 such clips failed `yaml parse; reverted` because author/title (now in
# FM_KEYS) were deleted on the undefined-marker path.
set -euo pipefail
cd "$(dirname "$0")/.."

pass=0; fail=0
ck() { if eval "$2"; then echo "  PASS  $1"; pass=$((pass+1)); else echo "  FAIL  $1"; fail=$((fail+1)); fi; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/Clippings"

# A real @ tweet: block-list author, populated ## The Idea (NOT thin), processed,
# no enriched_at. fxtwitter enrich should be frontmatter-only here.
cat > "$tmp/Clippings/@PawelHuryn – 2026-06-12T014700+0200.md" <<'EOF'
---
title: "Claude Fable 5: The Ultimate Guide"
author:
  - "@PawelHuryn"
source: "https://x.com/PawelHuryn/status/2064979937543549362"
date_clipped: 2026-06-12
type: "tweet"
tags:
  - claude-code
processed: true
triaged_at: 2026-06-13
---
# Tweet by @PawelHuryn

## The Idea

Fable 5 is the first model that made me feel audited. Real body content here.

## Source
[View on X](https://x.com/PawelHuryn/status/2064979937543549362)
EOF

cat > "$tmp/fxt.json" <<'EOF'
{"code":200,"tweet":{"text":"Fable 5 is the first model that made me feel audited.","author":{"screen_name":"PawelHuryn","name":"Pawel Huryn"},"is_note_tweet":true,"likes":5,"views":50}}
EOF

clip="$tmp/Clippings/@PawelHuryn – 2026-06-12T014700+0200.md"
FXT_FIXTURE="$tmp/fxt.json" node tools/fxtwitter-enrich.mjs --vault "$tmp" >"$tmp/out.txt" 2>&1

ck "enrich did NOT fail/revert" "! grep -q 'yaml parse; reverted' \"$tmp/out.txt\""
ck "enriched_at marker added" "grep -q '^enriched_at:' \"$clip\""
ck "author: key still present" "grep -q '^author:' \"$clip\""
ck "author block-list item preserved" "grep -q '^  - \"@PawelHuryn\"' \"$clip\""
ck "## The Idea body untouched" "grep -q 'Real body content here' \"$clip\""
# Frontmatter parses as YAML with author still a list
if node -e '
  const fs=require("fs"); const yaml=require("js-yaml");
  const t=fs.readFileSync(process.argv[1],"utf8").replace(/\r\n/g,"\n");
  const fm=t.slice(4, t.indexOf("\n---\n",4));
  const d=yaml.load(fm);
  if(!Array.isArray(d.author)||d.author[0]!=="@PawelHuryn"){console.error("author not a list:",JSON.stringify(d.author));process.exit(1)}
  if(!d.enriched_at){console.error("no enriched_at");process.exit(1)}
' "$clip"; then
  echo "  PASS  frontmatter parses; author is a list incl @PawelHuryn"; pass=$((pass+1))
else
  echo "  FAIL  frontmatter parses; author is a list incl @PawelHuryn"; fail=$((fail+1))
fi

echo ""
echo "test-fxt-blocklist-author: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && echo "test-fxt-blocklist-author OK" || exit 1
