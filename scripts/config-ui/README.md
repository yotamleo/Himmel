# config-ui

`himmelctl ui` serves the config console on `127.0.0.1` (Bun, loopback only,
per-launch token). Operator-only: it refuses to start inside a Claude session
(HIMMEL-4350).

## Health page (HIMMEL-4405, `#/health`)

Read-only: every value is rendered from its owner and nothing is re-measured.
`GET /api/health` (token-gated, GET only) runs three sources in parallel; each
answers `ok`, `absent` or `error` on its own, so one missing source never blanks
the page.

| Section | Source | `No data` means |
|---|---|---|
| Is himmel healthy? | the doctor feed's fail/warn rows plus firing Prometheus alerts | feed still running → `No data`; no Prometheus → `alerts not checked` and `monitoring tier not running` (it never raises the verdict) |
| What is broken | feed rows with health `fail` or `warn`, worst first, plus firing alerts | feed still running |
| Scheduled jobs | feed rows with `source: cadence` | no cadence rows declared |
| Legs and the usage bank | bank: the newest row with bank numbers in the last 64 KiB of `$CADENCE_BANK_LEDGER` (default `~/.himmel/cadence-ledger.jsonl`), never a fresh `bank-preflight`; legs: `legs.sh` (newest `*.fleet.json` under the handover root, status from `leg_tail_status`) | no ledger row with bank numbers; no handover root or fleet manifest |
| Search and graph freshness | feed rows with `bundle: search` (doctor owns qmd freshness) | doctor reports no search rows |

Verdict: any `fail` row or a firing `severity="page"` alert → **Act now**; any
`warn` row or any firing alert → **Needs a look**; else **All clear**.
Monitoring URLs are loopback-only (`HIMMEL_PROMETHEUS_URL`, default
`http://127.0.0.1:9090`; flow exporter port `HIMMEL_FLOW_EXPORTER_PORT`, default
9877); a non-loopback URL is refused.

## Agent run view (AG-UI, HIMMEL-4480)

`agui-web/` is a React page that renders an agent run streamed as AG-UI events:
assistant text, tool-call cards, a run strip of parallel calls over time, and
the review panel driven by `STATE_SNAPSHOT` / `STATE_DELTA`. It reads
`/api/agui/<run>` (one constant, `AGUI_URL` in `agui-web/src/stream.ts`) with
the session token from `#t=<token>&run=<id>`; with no `run` it replays the
recorded fixture `agui-web/src/fixture.json`, so it previews without a server.

```bash
cd scripts/config-ui/agui-web
bun install
bun run build   # → agui-web/dist/ (untracked)
```

`GET /api/agui/<run>` (token-gated, GET only, `agui/sse.ts`) serves that
stream. `<run>` must be a lowercase session UUID (else `400`); it names exactly
one `~/.claude/projects/<slug>/<run>.jsonl` whose real path stays under
`~/.claude/projects` (none `404`, more than one `409`; a symlink that leaves the
tree does not count). The response is `text/event-stream`, one
`data: <json>` frame per AG-UI event (the `@ag-ui/encoder` wire format,
hand-encoded: config-ui takes no dependency for it). It maps the file from the
start, then polls for appends every 500 ms, and ends when the client goes away,
2 minutes after the file stops growing with no run open, or after 4 hours. A
`: keepalive` comment every 15 s holds a quiet stream past Bun's idle cut.
Payload fields (deltas, results, errors, state) pass the same redactor as the
feed; the id fields are left intact. Serving the built page from config-ui and
printing its `#t=<token>&run=<id>` URL is PR4's.

The view logic is a pure reducer (`agui-web/src/reducer.ts`) with no runtime
imports, so its suite runs in CI without an install.

## Tests

- Unit and server suites: `bun test scripts/config-ui --dots` (CI-gated).
- Browser e2e (HIMMEL-4400): `scripts/config-ui/tests/e2e/`, Playwright pinned
  to 1.63.0 (Chromium build 1243). **Opt-in, not in CI**: a runner has no
  cached Chromium, and fetching one on every PR would make a download outage
  red-flake the fleet. Run it where `~/.cache/ms-playwright` already holds
  build 1243:

  ```bash
  cd scripts/config-ui/tests/e2e
  bun install
  bunx playwright test
  ```

  Each test boots its own real `himmelctl ui --port 0` against a fixture feed
  (stub via `CONFIG_UI_HIMMELCTL`; the live station feed never runs). The
  bundle order comes from `scripts/himmelctl/lib/feed-bundles.json`.
  `E2E_BREAK=order` feeds a mis-ordered bundle list: the suite must go red.

## Manual pass (the same 7 items)

From your own terminal (not inside Claude):

```bash
node scripts/himmelctl/bin.js ui --port 0
```

Open the printed URL, `http://127.0.0.1:<port>/#t=<64 hex>` (the token rides
the fragment). The first report can take a couple of minutes.

- [ ] 1. Controls and Inventory render as bundles in table order (Search & graph … Install & toolchain).
- [ ] 2. A bundle with no fail or warn row is collapsed; one with a fail or warn row opens by default.
- [ ] 3. Each header shows its headline health plus only the non-zero counts (Bypass flags reads `48 off`).
- [ ] 4. "Show only problems" hides healthy rows; header counts read `n of N`.
- [ ] 5. Searching `C45` opens Search & graph with the hit row; clearing restores the default state.
- [ ] 6. Tab to a header; Enter or Space toggles it; focus stays on that header after the repaint.
- [ ] 7. Unsorted is absent with 0 unmapped rows; when one exists it is always open and last.
- [ ] Header: above the page, one line shows `himmel <version> · <describe>`, the 12-char commit, the served checkout and the feed time; a feed without `himmel` reads `version unknown (feed has no himmel identity)`.
- [ ] Page links: the rail lists the pages (Config and Health), the current one is highlighted, and the address bar reads `#/config` (the token never stays in the URL).
- [ ] Safety: click a toggle: only a dry-run plan appears; confirm stays disabled until you type the target; cancel clears it.
