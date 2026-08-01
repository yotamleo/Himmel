---
description: Publish a freshly-refreshed graphify graph — commits + opens/refreshes a PR against the tracked graphify-out/ artifacts (HIMMEL-1129).
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

`--dry-run` implies `--no-fetch` (no git/gh calls at all, network included).
