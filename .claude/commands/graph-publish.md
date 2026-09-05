---
description: Publish a freshly-refreshed graphify graph — commit and open/refresh a PR against tracked graphify-out/ artifacts.
argument-hint: [--dry-run] [--base <branch>] [--no-fetch]
---

Publishes a locally-refreshed `graphify-out/graph.json` (+ `GRAPH_REPORT.md`)
by opening or refreshing a PR — the operator-invoked step HIMMEL-1123's
tracked graph needed and never got. Refuses cleanly when there is nothing
newer than the shipped (committed) graph to publish, and refuses if the
working tree has uncommitted changes outside the two graph paths.

Run this AFTER regenerating the graph locally (e.g. via
`scripts/graphify/refresh-graph-map.sh`), from the repo whose graph you
want to ship. Does not run on any cadence/hook — lean-invoke only.

**The PR it opens is machine-generated and will never get a CodeRabbit App
review** (HIMMEL-2278). Do not post a review-trigger comment on it and do not
park on the CR gate — `check-ci.sh` classifies the PR from its diff shape (every
changed path is a tracked `graphify-out/` artifact) and treats the absent App review as
expected. Checks-green and unresolved-thread gating still apply, so a clean
`check-ci.sh` run is still the merge bar.

Run:

```bash
bash scripts/graphify/graph-publish.sh $ARGUMENTS
```

Common invocations:
- `/graph-publish` — publish the current graph (open or refresh its PR).
- `/graph-publish --dry-run` — preview what would happen without any git/gh calls.
- `/graph-publish --base develop` — target a non-default base branch.

Environment:
- `GH_CMD=<cmd>` — override the gh binary (tests use a fake).
- `GRAPH_PUBLISH_BASE=<ref>` — default base branch. Default: `main`.

Exit codes:
- `0` published — commit pushed AND the PR was opened/refreshed
- `1` usage error
- `2` required tool missing (git or gh)
- `3` no local graphify-out/graph.json on disk
- `4` this repo doesn't track graphify-out/graph.json (HIMMEL-1123 not applied here)
- `5` nothing newer to publish (local graph == shipped graph)
- `6` working tree has uncommitted changes outside graphify-out/{graph.json,GRAPH_REPORT.md}
- `7` cannot resolve a base ref
- `8` checkout/commit/push failed
- `9` pushed, but the PR step did NOT complete (forge undetectable, or `gh pr create`/`gh pr edit` failed) — branch is pushed; open the PR manually
- `10` graphify-out/manifest.json is missing — refresh-graph-map.sh's transaction marker is absent, so graph.json/GRAPH_REPORT.md may be an inconsistent pair; re-run refresh-graph-map.sh first
- `11` graphify-out/GRAPH_REPORT.md is missing while graph.json is present — refresh-graph-map.sh always promotes both together, so this is anomalous (report deleted after a completed refresh?); restore GRAPH_REPORT.md or re-run refresh-graph-map.sh, then retry

`--dry-run` implies `--no-fetch` (no git/gh calls at all, network included).
