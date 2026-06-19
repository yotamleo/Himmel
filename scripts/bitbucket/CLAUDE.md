# scripts/bitbucket — Bitbucket Cloud CLI source

Loads only when working in this subtree. The forge-seam design lives in the
state-repo handover specs (`…/himmel/specs/design/`, HIMMEL-409); the shell
dispatch seam is `scripts/lib/forge*.sh`.

## What this is
The himmel `bitbucket` CLI — the transport for Bitbucket Cloud forge support.
Run from repo root as `node scripts/bitbucket/dist/index.js <op>`. ESM
(`"type": "module"`), `commander` arg-parsing, one file per verb group in
`src/commands/`. Wraps `@coderabbitai/bitbucket` (openapi-fetch typed client).

## Editing conventions
- **`dist/` is gitignored — not committed.** After editing `src/`, run
  `npm run build` (`tsc`) or the `dist/index.js` callers run stale code.
- Tests are colocated `*.test.ts`; run `npm run test` (vitest). They mock global
  `fetch` (openapi-fetch uses it) — no live network in CI.
- `tests/live-smoke.sh` is the creds-gated live test (`BITBUCKET_SMOKE_WS=<ws>`);
  it creates + **deletes** a throwaway repo. Manual, never CI.
- Conflict signal (spec §5.1): `pr merge` exits **2** on a 400 merge conflict
  (atomic — nothing merged), distinct from exit 1 (other failure).
- Identity (spec §5.4): user-slug = nickname → account_id → uuid; never empty.
