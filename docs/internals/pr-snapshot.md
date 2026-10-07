# Shared PR snapshots

`scripts/lib/gh-pr-snapshot.sh` (HIMMEL-4858) is the read-only, cache-backed PR-facts entry point for console gates. It does not grant GO or replace the fresh merge-time checks.

```bash
bash scripts/lib/gh-pr-snapshot.sh owner/repo 60 77 88
```

Arguments are the repository, TTL in seconds (`0` forces refresh), and one or more positive PR numbers. Successful stdout is a JSON array in requested order. Each member includes `number`, `headRefOid`, `mergeStateStatus`, `reviewDecision`, `statusCheckRollup`, `commits`, `body`, and `reviewThreads`; PR display metadata is also available. Commits carry `parents.totalCount`. CheckRun rows expose `workflowName`, preserving ready-check's check identity grouping. Any unreadable member fails the entire batch with nonzero exit and no partial stdout.

## Cache and freshness

- `GH_PR_SNAPSHOT_CACHE_DIR` defaults to `$HOME/.himmel/state/pr-snapshot`. `GH_CMD` selects the gh binary for offline tests; `GH_HOST` separates API hosts in the cache key.
- Each entry is tagged with repository/host, PR number, observed head SHA and fetch time. Writes are private and atomic (temporary file then rename).
- REST `pulls/<number>` head reads bracket every response, including cache hits. A changed or unreadable head refuses the old snapshot. A cache hit also requires valid data, the same head and age in `[0, TTL)`; future-dated entries are misses.
- A repository-scoped atomic mkdir serializes fetches/cache writes. Contention fails closed rather than bypassing the lock. Exit/signal traps clean it up. If a process is killed with SIGKILL, an operator must confirm the recorded PID is no longer running before removing the abandoned lock. No age-based lock stealing occurs.
- A TTL hit can contain earlier CI/review/body state **at the same head**, for at most the TTL. This is not a fresh approval or a merge authorization.

## Query cost and pagination

All misses in a batch share one aliased GraphQL query. Commits, check contexts and review threads follow continuation pages independently, with head binding, cursor-cycle detection and a 50-page ceiling. Pagination is never silently truncated; an incomplete/unreadable connection fails closed.

A settled, one-page ready-check uses **2 GraphQL calls instead of 7**: repository resolution and the snapshot. Files remain a paginated REST read, and freshness checks use REST. Cache hits use only repository resolution in GraphQL. Existing UNKNOWN merge-state retries force fresh snapshots; retries and continuation pages necessarily add calls.

`ready-check.sh --only 7` retains its body-only lint path, without requiring unrelated CI/commit/thread data. The full ready-check consumes the shared snapshot for checks 1, 2, 3, 5, 6 and 7. An unreadable snapshot fails all those checks. CR-ledger check 4 remains local.

Tick and board migration is the separately tracked HIMMEL-4889 slice: their open/recent-merged/epic discovery queries and historical leg PR-state lookups need a shared or REST-backed discovery strategy. `merge-on-green.sh`, `go.sh`, `console-wait.sh`, `gh-ci-cache.sh`, and `check-ci-watch.sh` are unchanged.

## Offline verification

```bash
bash scripts/quiet-run.sh suite -- bash scripts/lib/test-gh-pr-snapshot.sh
bash scripts/quiet-run.sh suite -- bash scripts/handover/console-kit/test-ready-check.sh
```

The shim counts calls without live GitHub access. Coverage includes batching, TTL hits, moved heads, a push during a fetch, unreadable/partial/malformed snapshots, workflow identity, continuation threads and cycling cursors. The ready-check suite keeps the existing verdict cases and checks the query budget and failure of every snapshot-dependent gate.
