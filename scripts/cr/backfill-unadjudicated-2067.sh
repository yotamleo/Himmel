#!/usr/bin/env bash
# scripts/cr/backfill-unadjudicated-2067.sh — one-off HIMMEL-2067 backfill.
#
# Acceptance item (2): mark the pre-gate-4b findings that sit unadjudicated at
# a branch's LATEST head once that branch has already merged — the branch is
# dead, gate 4b did not exist yet when the finding was raised, and no
# operator is ever coming back to adjudicate it. Records verdict=unaddressed
# (superseded by the merge, never reviewed against the gate) — the sanctioned
# vocabulary in ledger-append.sh (agreed|disproved|conflict|unaddressed|
# deferred); "superseded-unreviewed" is the plain-English description of
# that verdict, not a distinct value the ledger stores.
# A still-OPEN branch is deliberately left alone here: its owner adjudicates
# it (or the branch merges and a future run of this recipe catches it).
#
# One-off by design (HIMMEL-2067 acceptance): hardcodes the exact rows found
# by a live query of the production ledger on 2026-08-25, not a general
# tool. Idempotent — ledger-append.sh amend just appends another supersede
# record if re-run, and the LAST amend per key still wins, so a repeat run
# is harmless (verdict stays "unaddressed"), not silently ignored.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER_APPEND="$SCRIPT_DIR/ledger-append.sh"

# branch | head | id | artifact | perspective | merge_sha | pr
rows='
fix/himmel-1647-graph-freshness-build-identity|6f74e370c7b4b301a9212f4562e23d17fe4ba643|codex-1|diff|off|b1c516554287951c2925007e947c3e3fb44595a1|1870
fix/himmel-1391-duplicate-note-detection|20723c2753da38c006c18bea282506e03208ef3f|codex-1|diff|off|7c081183258206ef60003e2ea43b18752c01b576|1878
fix/himmel-1787-pr1680-round4-deferrals|e485b9e926ae5ebfba670e7a03639b1e32af3217|codex-1|diff|off|ffd580376b5854e58616baec13a468fa7b1da3c7|1879
feat/himmel-2035-external-repo-cr-gate|9d3e4c5c9e2f8c59b3569c5ff153048d49416a87|codex-2|diff|off|d9e2c86c34639c55cbe046f2672f28d329df1efd|1886
feat/himmel-2035-external-repo-cr-gate|9d3e4c5c9e2f8c59b3569c5ff153048d49416a87|codex-3|diff|off|d9e2c86c34639c55cbe046f2672f28d329df1efd|1886
docs/himmel-2064-commands-catalog-drift|44b64d06664a474c78d4b9c3fab73d76be183b67|codex-2|diff|off|630ee50ff7b6d6c7f13848865eb30e7342125dc8|1871
docs/himmel-2064-commands-catalog-drift|44b64d06664a474c78d4b9c3fab73d76be183b67|codex-3|diff|off|630ee50ff7b6d6c7f13848865eb30e7342125dc8|1871
feat/himmel-2052-ledger-batch|6262a7e0d6ba3261af3fc31b81ee8e620447ca1c|codex-1|diff|off|6887352a1d9bcdc49748a1dfe110656839db0510|1890
feat/himmel-2052-ledger-batch|6262a7e0d6ba3261af3fc31b81ee8e620447ca1c|codex-2|diff|off|6887352a1d9bcdc49748a1dfe110656839db0510|1890
'

n=0
while IFS='|' read -r branch head id artifact perspective merge_sha pr; do
    [ -n "$branch" ] || continue
    "$LEDGER_APPEND" amend --head "$head" --id "$id" --artifact "$artifact" --perspective "$perspective" \
        --set verdict=unaddressed \
        --reason "HIMMEL-2067 backfill: branch $branch merged as PR #$pr (squash $merge_sha) before gate 4b existed; nobody is coming back to adjudicate a dead branch's raw finding"
    n=$((n + 1))
done <<< "$rows"
echo "backfill-unadjudicated-2067: amended $n finding(s)."
