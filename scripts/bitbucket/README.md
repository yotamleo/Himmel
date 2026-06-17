# bitbucket-cli — himmel Bitbucket Cloud CLI

The transport layer for himmel's Bitbucket Cloud forge support (HIMMEL-325/326).
Mirrors `scripts/jira/`: a small `commander` CLI over a thin client, invoked **by
absolute path** as `node scripts/bitbucket/dist/index.js <op>`. It wraps the
`@coderabbitai/bitbucket` SDK (an `openapi-fetch` typed client generated from
Bitbucket's OpenAPI spec) and emits JSON on stdout — the `gh --json` analogue the
shell + plugin forge backends parse.

## Build

`dist/` is gitignored (build artifact). After cloning or editing `src/`:

```bash
cd scripts/bitbucket && npm install && npm run build   # tsc → dist/
npm test                                                # vitest (offline)
```

Callers invoke the built `dist/index.js` from the **primary checkout** (a worktree
has no `dist/` — same constraint as the Jira CLI).

## Auth

Reads `BITBUCKET_EMAIL` + `BITBUCKET_API_TOKEN` from the repo-root `.env`
(auto-loaded, CRLF-safe). The token must be an Atlassian API token created
**"with scopes"** with the **Bitbucket** app selected — the Jira token does NOT
work for Bitbucket (verified 401; scoped tokens are per-app).

## Verbs

| Verb | Endpoint |
|---|---|
| `auth status` | `GET /2.0/user` (exit 0 = authenticated) |
| `user [--slug]` | `GET /2.0/user` (`--slug` = nickname → account_id → uuid) |
| `repo view` | `GET /2.0/repositories/{ws}/{repo}` → workspace, repo_slug, full_name, default_branch |
| `repo get [--repo ws/repo]` | `GET .../{ws}/{repo}` + README (luna-ingest source fetch) → name, description, language, default_branch, url, updated_on, is_private, readme |
| `pr create` | `POST .../pullrequests` |
| `pr edit <id>` | `PUT .../pullrequests/{id}` (API requires `--title`) |
| `pr merge <id>` | `POST .../{id}/merge` (squash with `--squash`, else merge_commit; **exit 2 on 400 conflict**) |
| `pr list` | `GET .../pullrequests?q=state="..."` (paginated) |
| `pr get <id> [--repo ws/repo]` | `GET .../pullrequests/{id}` (luna-ingest PR detail) → title, state, description, author, source/destination branch |
| `pr comments <id>` | `GET .../{id}/comments` (paginated) → `{ threads, truncated, pages }`; `threads` = top-level inline comments, `truncated` flags a page-cap hit |
| `pr reply <id> <parentId>` | `POST .../{id}/comments` with `parent.id` (`--body` / `--body-file`) |
| `pr resolve <id> <commentId>` | `POST .../{id}/comments/{cid}/resolve` |
| `issue create` | `POST .../issues` (issue tracker disabled → **exit 3**) |
| `issue get <id> [--repo ws/repo]` | `GET .../issues/{id}` (luna-ingest issue detail; tracker disabled / gone → **exit 3**) |

Workspace/repo are derived from the `origin` remote (override with
`BITBUCKET_WORKSPACE` + `BITBUCKET_REPO_SLUG`); the read verbs (`repo get` /
`pr get` / `issue get`, HIMMEL-329) also accept `--repo <ws>/<repo>` to target an
arbitrary URL-named repo (the luna-ingest ingestion path). himmel never lists
workspaces (CHANGE-2770). A live smoke test lives in `tests/live-smoke.sh`
(creds-gated, manual, not CI).
