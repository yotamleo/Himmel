# API credit lane (HIMMEL-4904, HIMMEL-4985)

Billing counterpart to the `claude -p` rule in
[enforcement.md](enforcement.md#claude-invocation-billing-himmel-128). The lane
spends a Console organization's API credit, not the subscription bank. It is
**OFF by default** and has exactly one entry point:
`scripts/api-lane/claude-api.sh`.

## Which auth wins (answered from the docs, 2026-10-08)

On a subscription-logged-in station, an `ANTHROPIC_API_KEY` in the environment
of `claude -p` **wins**, and the Console org that owns the key is billed. In `-p`
mode "the key is always used when present"; there is no approval prompt. Order,
first present wins: cloud-provider flags (`CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY`),
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `apiKeyHelper`,
`CLAUDE_CODE_OAUTH_TOKEN`, profile/federation, subscription OAuth.
Not proven without a live call: promotional-grant-first debit and the exact
stop point of `--max-budget-usd`. A live proof needs the console's GO.

## What the launcher enforces

| Rule | Where |
|---|---|
| `HIMMEL_API_LANE=on`, `HIMMEL_API_ACCOUNT=A\|B`, key present (never printed) | `claude-api.sh` |
| `HIMMEL_API_KEY_ID` must equal the roster `key_id` of that account | `claude-api.sh`, `roster.mjs` |
| Conflicting provider flags / `ANTHROPIC_AUTH_TOKEN` / openrouter or claudex lane: refuse | `claude-api.sh` |
| `-p` only; caller flags are an allowlist (`-p`, `--model`, `--permission-mode`, `--max-budget-usd`, `--output-format json`, `--effort`), so no `--bg`, `--cloud`, `--daemon`, bypass or skip-permissions; `--model` and `--effort` values must not start with a dash; `--permission-mode` is one of `default`, `plan`, `acceptEdits`, `dontAsk`, `auto` (exact case, never the bypass mode); explicit `--permission-mode`, `--model`, `--max-budget-usd` | `claude-api.sh` |
| Bank gate is the API credit row only (`CADENCE_BANK_LANE=api`, opt-in via `HIMMEL_API_LANE=on`); the native bank is never read, so an exhausted native bank does not block and a funded one does not rescue an empty API account | `bank-preflight.sh` |
| Reserve the full budget first; settle only on a verified result with `total_cost_usd`, else mark `unknown` and keep the reservation | `api-credit-state.mjs`, `outcome.mjs` |
| No automatic A/B rotation and no subscription fallback: a refusal is final | `claude-api.sh` |
| Child env: OAuth, profile and federation vars removed, `ANTHROPIC_BASE_URL` pinned to `https://api.anthropic.com`, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` (not verified live) | `claude-api.sh` |
| Non-API children run through `strip-env.sh -- <cmd>`, which drops the key and every `HIMMEL_API_*` selector | `strip-env.sh` |
| Secret-free launch record (account, org, key id, cycle, model, budget, snapshot source, outcome, cost) appended to `launches.jsonl` beside the ledger | `claude-api.sh` |

## Credit config

`~/.himmel/state/api-credit/config.json` (outside the repo, never committed):

```json
{ "version": 1, "ledger_path": "/home/<user>/.himmel/state/api-credit/ledger.json",
  "accounts": { "A": { "organization_id": "...", "cycle_id": "...", "cap_usd": "5.00", "key_id": "..." } } }
```

`ledger_path` is required, absolute and pinned: `HIMMEL_API_CREDIT_STATE` may
only restate it, and the config location comes from the account home, not
`$HOME`. Two sentinels (`<ledger>.initialized` and one beside the config) make
deleting the ledger refuse instead of resetting spent credit. `key_id` is a
non-secret label chosen by the operator; the key itself is only ever in the
launching shell's `ANTHROPIC_API_KEY`.

## Proposed CLAUDE.md line (for the operator or console to apply)

> API credit lane: `scripts/api-lane/claude-api.sh` is the only API-key launch
> path, OFF unless `HIMMEL_API_LANE=on`. Never export `ANTHROPIC_API_KEY` into a
> general shell; non-API children go through `scripts/api-lane/strip-env.sh`.
> Detail: [`docs/internals/api-credit-lane.md`](docs/internals/api-credit-lane.md).

## Deferred

Wiring `strip-env.sh` into the lane launchers (`claude-lane.sh`, `lanes.json`)
and a `backends.json` row are outside this PR's write scope and need a console
ruling. Until then `claude-headless.sh` already strips `ANTHROPIC_*` for native
children.
