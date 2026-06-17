# Bitbucket CLI test fixtures

Recorded/representative Bitbucket Cloud REST v2 response shapes, captured against
the live API during preflight (PF-0…PF-4, 2026-06-16) and the Phase-1 live smoke
(`../live-smoke.sh`). Values are **sanitized** — no real account IDs, UUIDs, or
tokens. They document the contracts the CLI parses; the offline unit tests
(`src/*.test.ts`) use representative inline bodies matching these shapes.

| Fixture | Endpoint | Source | Verified signal |
|---|---|---|---|
| `user.json` | `GET /2.0/user` | PF-1 | `nickname` **+** `account_id` **+** `uuid` all present → user-slug fallback chain fully backed (spec §5.4). |
| `repo.json` | `GET /2.0/repositories/{ws}/{repo}` | live smoke | `full_name` + `mainbranch.name` → `default_branch`. |
| `pr-create.json` | `POST .../pullrequests` | live smoke | created PR: `id`, `state`, `source.branch.name`, `links.html.href`. |
| `pr-list-merged.json` | `GET .../pullrequests?q=state="MERGED"` | live smoke | paginated `values[]`; `next` absent on the last page. |
| `merge-conflict.json` | `POST .../pullrequests/{id}/merge` → **400** | PF-2 | the definitive conflict signal — atomic, nothing merged (spec §5.1). |
| `issues-disabled.json` | `POST .../issues` → **404** | PF-3 | tracker-off degrades gracefully, not an error (spec §5.2, Phase 2). |
