# The himmel UI surfaces

Audience: newcomer who has installed himmel, and contributor. Owner: HIMMEL-6836 (this page).

himmel has no hosted UI. Three surfaces exist, all local, and each is started by a
command you run yourself. Only the config UI can change anything on your machine. Settings switches show a dry-run and ask
for a confirm, and a typed value is saved on request. A Kanban drop and a theme select on the Roadmap
write to Jira at once, with no confirm. The other two surfaces only display. If a user asks "the himmel UI",
they almost always mean the first one.

| Surface | What it is | Start it | Needs |
|---|---|---|---|
| Config console | One local web app: Settings, Setup, Health, Tool health, Fleet, Roadmap pages and the AG-UI run view | `node scripts/himmelctl/bin.js ui` | `bun`, a terminal outside Claude | <!-- old-term-ok: console is renamed in slice V5 -->
| Console board | One generated HTML page: the fleet, each worker session's phase, what needs the supervisor session | `node scripts/handover/console-kit/board.mjs --doc <console doc> --changed` | a running himmel supervisor session |
| Roadmap tracker | One generated HTML page: release panels and a kanban by version | `python3 scripts/handover/console-kit/tracker.py --plan-dir <dir> --out <file>` | `python3`, the Jira mirror |

## The config console (`himmelctl ui`)

Serves on `127.0.0.1` only (loopback), behind a per-launch token. It reads the
same data as `himmelctl report --json`. Health, Tool health, Fleet, Workflow and the
inventory only display. What can change something is on Settings, Setup and the Roadmap and
Kanban boards; the table after the switches maps every action to its route. A switch shows its
dry-run first, then, once confirmed, runs the `himmelctl` command printed under it and writes:

| Switch | What it writes | Takes effect |
|---|---|---|
| Plugin set, a plugin | the plugin's enabled state at user scope, through `himmelctl profile`, which runs `claude plugin enable` or `disable` | next Claude launch |
| Review by a second model | the local lane overlay `lanes.local.json`, through `himmelctl config set lanes.<id>` | next time work is handed to a lane |
| Auto-ship steps | `HIMMEL_INITIATIVE` in the `.env` of the himmel download, through `himmelctl config set initiative.<step>` | next Claude launch |
| Scheduled jobs | the job's crontab entry, through its `*-cadence.sh arm` or `disarm` | at the next scheduled run |
| Commit rules (Setup) | `TRACKER` and `TICKET_ID_REQUIRED` in `~/.himmel/himmel.conf`, through `himmelctl config set commit.<key>` | your next commit |
| Fleet cap (Settings) | the one `HIMMEL_FLEET_CAP` line in the `.env` of the himmel download, a whole number from 1 to 50 (default 4); a `HIMMEL_FLEET_CAP` exported in the shell that launches a worker wins over the `.env` line for that launch, and the page shows a notice while the shell that started the UI sets one | the next worker launch |
| VM mode (Settings) | the `vm` section of the himmel config file in `~/.himmel`: `local`, `remote` (ssh target, port, identity) or `none`; validated before the write | the next VM proof run |
| Review gate (Settings) | the per-machine overlay `critics.local.json` only, through `POST /api/review-gate`: each reviewer's `mode`, `required` and on/off (`drop`). The shared `scripts/cr/critics.json` is never written | the next review round |

The Review gate card lists the reviewers in the order they run, says in plain words what `hard` and `best-effort`
mean, marks the recommended value, and states the ruled rate-limit behaviour: with CodeRabbit on best-effort (the default), rate limited or absent is a
note and the gate continues, it never waits; a reviewer set to `hard` holds the merge when it is rate limited or unavailable. The timeout, parallelism, tier and profile settings
(`CRITIC_TIMEOUT_SECS`, `CRITIC_PARALLEL`, `CRITIC_PANEL_TIERS`, `CR_PROFILE`, `CR_REQUIRE_CROSS_MODEL`,
`CR_FLOOR_FALLBACK`) are shown with their current value and default, and are set in `.env` or the launching shell.

The Setup page also saves or removes a file-stored secret (a password field; the value goes to the
secret store only and is never shown, logged or returned), and a save is refused while the page runs
as the always-on service (open `himmelctl ui` instead). Each secret form shows an example value under it (a shape, never a working value).

The Setup page also has a CodeRabbit step. It says what CodeRabbit is, that it is an optional add-on (himmel
works without it), and the steps to install the GitHub App on the repo and arm the gates
(`git config --local himmel.coderabbit true`). The installed check runs `gh pr list` over the last 10 PRs and looks
for a `CodeRabbit` check: seen is `installed`; not seen is `not detected` (a new install, a repo with no PRs or skipped
reviews look the same); no `gh`, no sign-in or no remote is `not checked`. Both of those show a manual confirm. The check only reads; it never installs or arms anything.

The Roadmap and Kanban boards also write to Jira: dragging a card to another column
transitions the ticket, and a card's theme select sets its single `theme-<slug>` label. Both go
through `POST /api/roadmap/write` and the Jira CLI; a refusal leaves the card where it was.

Session switches and Your install answers are shown, never written:
session switches are set when you start Claude.

Every write is a `POST` behind the per-launch token, a same-origin check and a JSON-only body.
This is the full set, each mapped to the code that handles it:

| Action | Route | Handled in |
|---|---|---|
| Dry-run a switch, then run it after confirm | `/api/preview`, `/api/run` | `previewRoute` and `runRoute` in `scripts/config-ui/server.ts` |
| Save or remove a file-stored secret | `/api/setup/secret` | `setupSecretRoute` in `scripts/config-ui/server.ts` |
| Review gate reviewers | `/api/review-gate` | `scripts/config-ui/review-gate.ts` |
| Fleet cap | `/api/fleet-cap` | `scripts/config-ui/fleet-cap.ts` |
| VM mode | `/api/vm` | `scripts/config-ui/vm-config.ts` |
| Kanban move, card theme | `/api/roadmap/write` | `roadmapWriteRoute` in `scripts/config-ui/server.ts` |

```bash
node scripts/himmelctl/bin.js ui              # prints ONE URL carrying the token
node scripts/himmelctl/bin.js ui --port 0     # pick a free port
node scripts/himmelctl/bin.js ui --agui latest   # URL of the newest session's run page
node scripts/himmelctl/bin.js ui --agui <session-id>
```

- **Install hands off to the Setup page.** Run `himmelctl install` in your terminal
  first ([install.md](setup/install.md)); when it finishes it prints
  `Finish setup in the UI: http://127.0.0.1:<port>/#t=<token>&page=setup`. It reuses the always-on
  UI or an earlier install's UI when one is running, and otherwise starts a token-bound one that
  stops after 30 minutes idle and can save secrets. The Setup page edits an install that exists;
  it does not run one. With no browser (an SSH session, or Linux with no display) install asks for
  the secrets in the terminal instead.
- **Link forms.** `himmelctl config` prints the Configure link, `http://127.0.0.1:47391/#t=<token>&page=config`,
  when the always-on service is installed (47391 is the service's default port; `--port N` changes it),
  and otherwise says how to start the UI; it never opens a browser. An ad-hoc `himmelctl ui` picks a free
  port, so its link changes each launch. Every link carries `#t=<token>`; without it the page is refused.
- **Run it yourself, from a terminal outside Claude.** It refuses to start
  inside a Claude session; an agent cannot open it for you. The server runs in
  the foreground and exits on Ctrl-C or after 30 minutes idle.
- **The token** rides the URL fragment (`#t=<hex>`), so it is never sent in a
  request line. Open the printed URL as is; a new launch means a new token.
- **Always on.** `himmelctl ui --service install` installs `himmel-ui.service`, a systemd
  user unit that serves the same pages on a fixed `127.0.0.1` port (47391, or `--port N`)
  with no idle exit, restarts on failure and rebuilds `agui-web/dist` at start when its
  sources are newer. The token is a mode-600 file, `~/.himmel/state/ui-token`, created once,
  so the URL survives restarts: `--service url` prints the bookmark, `status` and
  `uninstall` do what they say (uninstall also deletes the token file). It needs
  `HANDOVER_DIR` in the shell that runs `install`. The board on the Fleet page is read from
  `<console doc>.board.json`, which every `board.mjs` render rewrites beside the doc, and
  reaches the page within about 5 s; with no such file the server builds it as before.
- **Pages** (the left rail): `#/config` (Settings: seven groups of what you can
  change, each row with its command, when it takes effect and a Learn more link
  to the docs site; then triage of failing items and the inventory of install
  items, doctor checks, scheduled jobs, lanes, flags and secrets by presence;
  Roadmap and Kanban only appear when the UI can read a tracker), `#/setup`
  (which secrets are set, never their values; a file-stored secret can be saved or
  removed here; the always-on service refuses a save until the UI login ships, so use an
  ad-hoc `himmelctl ui` for secrets; plus the commit rules, tracker and ticket-id-required, each with a
  dry-run before it changes), `#/health` (one verdict:
  All clear / Needs a look / Act now; a Trends section with Velocity, Cost and Health
  cards from the weekly roll-up, see below), `#/toolhealth` (tool-call failure and
  denial rates by model and lane), `#/roadmap` (releases, drift, sync and
  librarian, live from the Jira mirror; click a version for its kanban at
  `#/roadmap/<version>`), `#/kanban` (one board across all versions, Done
  hideable), `#/workflow` (the development graph and its guided walkthroughs,
  the same graph as the docs page), and **Fleet** at `/agui/`.
- **Fleet and run view (AG-UI).** `/agui/` lists every live Claude session
  with its ticket, PR and state; clicking one opens its run page: assistant
  text, tool-call cards, subagents, failures. The page needs a one-time build
  (`cd scripts/config-ui/agui-web && bun install && bun run build`); without it
  `himmelctl ui` prints the config page instead.
- **Console board on the Fleet page.** Start `himmelctl ui` with `HANDOVER_DIR` set and open
  `/agui/#t=<token>&console=<console doc name>`. The page then shows the supervisor
  session's board (the `board.mjs --json` output, served read-only and redacted at the
  token-gated `GET /api/agui/board?console=<name>`; built from the board JSON file when present, else cached 30 s). **Fleet** tab: verb-led
  rows for what needs you, and on each running row its goal, six stage dots (dispatch,
  live, PR, ready, go, merged) and a state chip. **Trends** tab (`&tab=trends`): four cards
  (Fleet velocity, Fleet health, Tool health, Roadmap reality), each with a recommendation
  line and a colour legend; a milestone is a Jira fixVersion, console cost sits beside
  fleet cost, and Tool health carries the console-succession row. A card opens its table in
  the side drawer. Clicking a stage dot opens that leg's drill-in in the drawer (run header,
  stage strip, transcript, the needs-you finding with its exact `go.sh` command). Keys: left
  and right move between stages, up and down between legs, Backspace goes back, Esc closes.
  Deep link: `&k=s.<leg>.<stage>`. `GET /api/agui/brief?leg=<doc name>` returns that
  leg's handover doc as redacted text. Both routes look a doc up by name under
  `HANDOVER_DIR`, never by a path from the request.
- **Weekly roll-up trends.** The Health page's Trends section and the top of the Fleet page's
  Trends tab show three cards: Velocity (merges), Cost (cost per ticket) and Health (red-main
  incidents). Each has a sparkline by finished week, the change against the previous week and
  the previous version, and one plain sentence such as "Faster than last week and costlier
  than last version". The server serves the roll-up read-only at `GET /api/rollup` from
  `~/.himmel/state/rollup/weekly.jsonl` (`WEEKLY_ROLLUP_FILE` overrides), written by
  `python3 scripts/eval/weekly-rollup.py write`; the browser recomputes nothing, and without
  the file the section says "no data yet".

Full reference, endpoints and environment overrides:
[scripts/config-ui/README.md](../scripts/config-ui/README.md).

## The console board and roadmap tracker

Both belong to the himmel **supervisor session**, the long-running session that
dispatches and watches worker sessions ([glossary](glossary.md)). They are static HTML
files, which the supervisor session renders from its own state and republishes as
artifacts; neither runs a server.

- **Board** (`board.mjs`): fleet size against the cap, each worker session's phase from
  LIVE to WRAPPED, what needs the supervisor session, epic progress and open decisions.
  `--changed` prints `CHANGED <path>` or `UNCHANGED <path>`.
- **Tracker** (`tracker.py`): release panels and a kanban by Jira version and
  theme. Run `node scripts/jira/dist/index.js mirror` first; without a mirror
  it has nothing to show. The same view also lives live at `#/roadmap` in the
  config console.

Both are Linux-only supervisor session tooling; an install without a supervisor session does not
have them in use.

## Entry pages: audience and owner

Each of the ten user entry pages names who it is for and who owns its rewrite. The evidence is the
HIMMEL-6743 design review, section "Ten user-page recommendations" (the cited line range is the part
of the page the review read).

| Page | Audience | Owner | Evidence in the review |
|---|---|---|---|
| `README.md` | newcomer | HIMMEL-7211 | `README.md:5-19,33-62,75-89` |
| `docs/why-himmel.md` | newcomer | HIMMEL-7211 | `docs/why-himmel.md:15-48` |
| `docs/getting-started.md` | newcomer | HIMMEL-7211 | `docs/getting-started.md:27-73` |
| `docs/setup/install.md` | newcomer | HIMMEL-7212 | `docs/setup/install.md:1-89,227-232` |
| `docs/adoption-trail.html` | newcomer | HIMMEL-6290 | `docs/adoption-trail.html`, frames F2 to F8 |
| `docs/daily-loop.md` | contributor | HIMMEL-7213 | `docs/daily-loop.md:3-28,32-97` |
| `docs/configuration.md` | contributor | HIMMEL-7212 | `docs/configuration.md:9-79` |
| `docs/commands-catalog.md` | contributor | HIMMEL-7213 | `docs/commands-catalog.md:3-70,80-105` |
| `docs/setup/updating.md` | newcomer | HIMMEL-7212 | `docs/setup/updating.md:3-25,27-100` |
| `docs/ui.md` | newcomer and contributor | HIMMEL-6836 | `docs/ui.md:3-16,25-45` |

## Keeping this page current

Adding a user-facing page or verb means updating this page, `llms.txt` and the
v1 release checklist step.
`bash scripts/docs/test-check-llms-links.sh` fails when a page id in
`scripts/config-ui/public/nav.js` is missing here.
