#!/usr/bin/env bash
# scripts/fixture-blind.sh - fixture: has no real reference anywhere in
# tracked non-fixture content. A mention living inside a nested fixtures/
# directory (simulating this scorecard kit's own fixtures/dead-parts/ tree,
# which the real 7-day run's own repo tree also contains) must not count as
# a real reference (codex-1 fixture-blind-spot fix: the git-grep reference
# search used to have no fixtures/ exclusion, unlike entry discovery).
echo fixture-blind
