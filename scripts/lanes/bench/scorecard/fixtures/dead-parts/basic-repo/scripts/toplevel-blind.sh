#!/usr/bin/env bash
# scripts/toplevel-blind.sh - fixture: has no real reference anywhere in
# tracked non-fixture content. Its only mention lives in a top-level
# fixtures/ directory (fixtures/root-mentions.txt, not nested under
# scripts/), which has no leading slash in git-grep output - a plain
# `/fixtures/` substring exclusion misses it (codex-2 top-level-fixtures fix).
echo toplevel-blind
