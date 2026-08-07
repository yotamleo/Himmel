# himmel observability Phase A

Phase A is a local, passive Prometheus/Grafana stack for the Windows host. The
flow exporter is a tiny Bun HTTP server bound to `127.0.0.1:9877`; Prometheus
scrapes it every 60s and also scrapes `windows_exporter` on `127.0.0.1:9182`.

## Passivity invariant

The exporter is a pure reader. It never writes ledgers, never mutates the vault,
never starts or kills processes, and never enforces quota or flow policy. Missing
data stays missing: metric families are omitted when their substrate is absent.
The only explicit zero for a silent configured flow is
`flow_run_in_flight{flow} 0`.

The session substrate (HIMMEL-1052) keeps that boundary intact: the ledger is
written by a separate hook-side script (`session-run-hook.ts`) riding existing
hook chokepoints, and the exporter only reads it. `GET /sessions.json` is a
second read shape, not a second responsibility.

Flow outcome counters are folded from the sliding 14 day ledger window at scrape
time, reading both `flow-runs.jsonl` and `flow-runs.jsonl.1`. The
`flow_run_outcome_total` family keeps the counter name and type the ratified
design (§3) pins, but its values are WINDOW-FOLDED: they decrease when rows age
past 14 days, which Prometheus reads as a counter reset — `rate()`/`increase()`
then briefly overcount around a slide. For the war-room panels (7d ranges over
a 14d window, low row churn) that artifact is small and accepted; if it ever
misleads, the fix is in-process monotonic accumulation in the collector child
(HIMMEL-924), not a family rename here.

Unpaired `start` rows older than a flow deadline are exported as inferred
`stalled` outcomes. The flow-run ledger itself never contains `stalled`.

## Configuration

Default config path:

```text
~/.himmel/observability.json
```

Override:

```text
HIMMEL_OBSERVABILITY_CONFIG=/path/to/observability.json
```

Shape:

```json
{
  "flows": [
    {
      "name": "pipeline-harvest",
      "cadence_seconds": 86400,
      "stall_deadline_seconds": 7200
    }
  ],
  "expected_tasks": [
    "himmel-pipeline-harvest"
  ],
  "vault_path": "C:/Users/you/Documents/luna",
  "host_detectors_ttl_seconds": 60,
  "sessions": {
    "stale_after_seconds": 900
  },
  "quota_sources": {
    "claude_cache_path": "/tmp/claude/statusline-usage-cache.json",
    "codex_sessions_dir": "C:/Users/you/.codex/sessions",
    "glm_ledger_path": "C:/Users/you/.himmel/quota-gauge.jsonl"
  }
}
```

Rules:

- `stall_deadline_seconds` wins when present.
- Otherwise the stall deadline is `2 * cadence_seconds`.
- Unknown flows seen only in the ledger default to a 6 hour stall deadline.
- Missing config is valid; the exporter still serves metrics derivable from
  ledgers alone.
- `expected_tasks` is Windows-only. Non-Windows platforms omit the scheduled
  task family and add a comment in `/metrics`.
- `vault_path` is optional. Without it, Luna backlog metrics are omitted.
- `host_detectors_ttl_seconds` controls the Windows host detector cache. It
  defaults to 60 seconds.
- `sessions.stale_after_seconds` is the transcript-inactivity threshold that
  flips a live session to dead (HIMMEL-1052). It defaults to 900.
- `quota_sources` is optional; every key has a derived default (claude:
  `$CLAUDE_USAGE_CACHE`, else `<tmp>/claude/statusline-usage-cache.json`;
  codex: `~/.codex/sessions`; glm: the quota-gauge ledger path).

## Metrics

Flow metrics are derived from `~/.himmel/flow-runs.jsonl` unless
`HIMMEL_FLOW_RUNS_LEDGER` overrides the path.

Daily clip-source fetch health is read passively from
`~/.himmel/fetch-health.json` unless `HIMMEL_FETCH_HEALTH_STATE` overrides the
path. The no-LLM probe runner writes one exact status per source:
`ok`, `auth-or-cookie-expired`, `blocked-or-rate-limited`, or `transport-fail`.
The exporter exposes:

- `clip_fetch_source_status{source,status}` — one-hot current classification.
- `clip_fetch_source_last_success_timestamp{source}` — epoch seconds of the
  latest successful known-good probe, preserved across later failures.

A missing state file omits both families. Malformed state also fails soft: the
scrape remains available and includes a `# clip_fetch_source_* omitted: ...`
comment. Probe response bodies and credential values are never exported.

Lane quota gauges (`lane_quota_used_pct{lane,bank,window}`, HIMMEL-1000) read
real bank sources via `scripts/observability/quota-sources.ts`: the claude
bank from the statusline usage cache (5h + weekly windows), the codex bank
from the newest `~/.codex/sessions` rollout `rate_limits` row (weekly;
`used_percent` is emitted verbatim — live-verified USED semantics), and the
glm bank from the quota-gauge ledger (`~/.himmel/quota-gauge.jsonl`, or
`HIMMEL_QUOTA_GAUGE_LEDGER`). Each `scripts/lanes/lanes.json` lane that
declares `quota.bank` emits one series per live window of its bank; every
reading is gated on a live `resets_at`/`reset_at` (an expired window is
omitted, never re-emitted). Lanes without a machine-readable quota source —
and banks with no live reading — appear as explicit
`# lane_quota_used_pct omitted: ...` comments instead of fabricated values.

Scheduled task and Luna backlog walks are cached for 60s. The flow ledger fold
runs on every scrape so in-flight age and stall inference are fresh.

Host detector metrics are collected by
`scripts/observability/host-detectors.ps1`, which takes one `Win32_Process`
snapshot and emits JSON for the exporter. The detector is report-only: it does
not write state and does not control processes. On non-Windows hosts, or when
PowerShell collection fails, these families are omitted and `/metrics` includes
an explanatory `# agent_tree_*/orphan_* omitted: ...` comment.

- `agent_tree_rss_bytes{class="..."}` - working-set bytes summed by process
  tree class (`claude`, `codex-app-server`, `codex-exec`, `hermes-gateway`,
  `telegram-bridge`, `mcp-standalone`, `other`).
- `agent_tree_process_count{class="..."}` - process count for the same tree
  classes.
- `orphan_process_count{class="..."}` - report-only orphan-shaped process count
  by detector class (`codex-fleet`, `codex-exec-registry`,
  `hermes-gateway-orphan`, `codex-app-server-orphan`,
  `mcp-dead-parent-unattributed`).

`luna_git_unpushed_commits`/`luna_git_uncommitted_files` (HIMMEL-1199) are a
local-refs-only divergence read of the `vault_path` git clone, cached for 60s
alongside the Luna backlog walk:

- `luna_git_unpushed_commits` - `git rev-list --count @{u}..HEAD`. Omitted
  (no sample, not a fabricated `0`) when the branch has no upstream
  configured. This is the exact signal for the HIMMEL-1199 incident: an
  auto-sync push silently blocked by a gitleaks false positive, so
  auto-committed commits piled up unpushed with zero visible signal. No
  fetch is ever run — a true "behind" count needs a fetch, which would
  violate the passivity invariant above, so it is intentionally not
  implemented.
- `luna_git_uncommitted_files` - line count of `git status --porcelain`;
  catches a commit-gate block, complementing the push-gate signal.

Any git error, missing repo, or timeout omits the whole family with an
explanatory `# luna_git_* omitted: ...` comment, same fail-soft contract as
the scheduled-task and host-detector families.

## Live sessions and subagents (HIMMEL-1052)

Three session populations exist in this harness, with three different owners:

1. **Pipeline-cadence legs** (harvest/synthesize/health/armed-resume/vitals) —
   `flow-runs.jsonl`, the Flows row above (HIMMEL-919/921).
2. **Dispatched lane workers** (GLM/claudex) — their own per-session
   `meta.json`/`outbox.jsonl` under the bridge root.
3. **Interactive/foreground Claude Code sessions and the Task-tool subagents
   fanned out inside them** — this section. Nothing tracked these before: a
   host-detector `class="claude"` reading is a *sum* over every process wearing
   that class and cannot say how many distinct sessions are alive, which have
   subagents under them, or which one died three hours ago instead of
   finishing.

### The ledger

```text
~/.himmel/session-runs.jsonl            (override: HIMMEL_SESSION_RUNS_LEDGER)
```

Same shape discipline as `flow-runs.jsonl`: append-only JSONL, a fixed field
list in a fixed order, rotation at 10MB into `.jsonl.1` (both files are read).
Written by `session-run-hook.ts` (below); read by the exporter. Four row kinds:

| kind / ev | fields |
|---|---|
| `session` / `start` | `v`, `kind`, `ev`, `session_id`, `cwd`, `transcript_path`, `host`, `started_at`, `pid` |
| `session` / `end` | `v`, `kind`, `ev`, `session_id`, `ended_at`, `reason` |
| `subagent` / `start` | `v`, `kind`, `ev`, `subagent_id`, `parent_session_id`, `subagent_type`, `description`, `started_at` |
| `subagent` / `end` | `v`, `kind`, `ev`, `subagent_id`, `parent_session_id`, `ended_at`, `outcome` |

- `reason` is normalized into a closed enum: `clear`, `logout`,
  `prompt_input_exit`, `other`. Anything else becomes `other` — it is a
  Prometheus label downstream, and an open label is a cardinality explosion.
- `outcome` is `success` / `error` / `unknown`, classified coarsely from the
  Agent tool response (an `is_error` flag). Unclassifiable is `unknown`, never
  an assumed success.
- `subagent_id` is the payload's native `tool_use_id` when present — the exact
  correlator shared by the Pre and Post hook events. Without it, the writer
  falls back to a 12-hex sha256 of `session_id` + `tool_input`, which pairs
  deterministically but collides for two identical dispatches from one session
  (the live *count* stays right; only per-instance identity blurs).
- `pid` is best-effort and nullable: a SessionStart hook is a grandchild of the
  Claude Code process and is not handed its parent's pid. Nothing depends on it.
- `description` is truncated to 200 characters — the ledger wants a handle, not
  a copy of every dispatch brief.

### Wiring the writer

`session-run-hook.ts` is a pure writer: it appends one line and exits. It is
fail-open on every path (exit 0, empty stdout, no `permissionDecision`), so a
telemetry gap can never block or slow the tool call it rides on. Four hook
entries, all additive to chokepoints that already exist:

```jsonc
// SessionStart array (.claude/settings.json)
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" session-start"
// SessionEnd array
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" session-end"
// PreToolUse, matcher "Agent"
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" subagent-start"
// PostToolUse, matcher "Agent"
"bun \"$CLAUDE_PROJECT_DIR/scripts/observability/session-run-hook.ts\" subagent-end"
```

Until those entries are wired, the ledger stays empty, every session family is
omitted, and `session_runs_ledger_rows` reads 0 — the exporter degrades to
silent, never to a fabricated reading.

### Liveness: transcript mtime, not wall clock

**The record that never gets written is the important one.** SessionEnd is a
graceful-exit hook: a crash, an OOM, a SIGKILL, or a wedged session the
operator eventually closes the window on emits `session_start` and *no*
`session_end`, ever. A purely start/end-paired ledger cannot express that, and
only recording clean completions would be useless.

The flow fold's rule (unpaired start past `cadence*2` = stalled) does not
transfer: an interactive session has no cadence and can legitimately sit idle
waiting on the operator — thinking, on a permission prompt, at lunch. Wall
clock alone cannot tell that from a crash. The transcript file can: it advances
exactly while, and only while, the session is doing something, independent of
whether any hook fires cleanly at exit.

- unpaired start, transcript mtime **fresh** → `running`
- unpaired start, transcript mtime **stale** → `dead`
- start with a matching end row → `ended`, tagged by `reason`

Freshness defaults to 15 minutes and is operator-tunable:

```json
{ "sessions": { "stale_after_seconds": 900 } }
```

Too short flags a thinking session as dead; too long delays real-crash
detection. A transcript that cannot be read at all is not evidence of life —
the session's own age is measured against the same threshold instead, so a
session whose transcript never appeared ages into `dead` rather than counting
as live forever.

### Metric families

Aggregated only. `session_id` and `subagent_id` are unique per occurrence and
unbounded over time, so they are **never** Prometheus labels.

- `session_active_total{host}` — sessions running per the rule above.
- `session_dead_total{host}` — crashed/orphaned/wedged sessions. The number
  that should alarm.
- `session_end_outcome_total{reason}` — graceful exits in the sliding 14d
  window (same window-fold caveat as `flow_run_outcome_total`).
- `subagent_active_total{host,subagent_type}` — subagents with an unpaired
  start row **under a still-running parent**. The parent qualifier is
  deliberate: a subagent whose parent crashed can never emit its end row, and
  an unqualified reading would pin phantom subagents live for the whole window.
  `host` is joined through the parent session's start row; the subagent rows
  carry no host of their own.
- `subagent_outcome_total{subagent_type,outcome}` — subagent completions in
  the window.
- `session_runs_ledger_rows` — parsed rows in the window, exporter self-health
  parity with `flow_exporter_ledger_rows`.

Hosts observed in the window keep a zeroed sample, so a dead-session alert
stays evaluable after the last live session on that host goes away. Label
values that originate in hook payloads (a hostname, a `subagent_type`) are
stripped of control characters and bounded at 64 chars before rendering —
`escLabel` does not escape carriage returns, which would otherwise inject a new
exposition line.

### Per-session detail: `GET /sessions.json`

The exporter serves the per-session view the metric families deliberately
cannot carry:

```text
http://127.0.0.1:9877/sessions.json
```

```json
{
  "v": 1,
  "generated_at": "2026-08-07T09:00:00.000Z",
  "stale_after_seconds": 900,
  "ledger_rows": 42,
  "sessions": [
    {
      "session_id": "a1b2c3d4-...",
      "cwd": "C:\\Users\\you\\Documents\\github\\himmel",
      "host": "OVERLORD8",
      "started_at": "2026-08-07T06:00:03Z",
      "status": "running",
      "end_reason": null,
      "age_seconds": 10797,
      "last_activity_seconds": 42,
      "subagents_started": 3,
      "subagents_active": 1
    }
  ]
}
```

Same passive read, same ledger, same liveness rule — one reader, so the table
and the gauges can never disagree. `last_activity_seconds` is `null` when the
transcript is unreadable, never 0. To render this as a Grafana table, add an
Infinity/JSON datasource pointed at that URL; the dashboard ships the stat
tiles (Prometheus-backed) plus a text panel naming this endpoint.

## Install on Windows

From a PowerShell session in the repo:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/observability/install-stack.ps1
```

By default the four exporter tasks run as Interactive logon tasks, which pop a
console window per process in your session. To run them hidden (S4U, session 0,
no windows), pass `-Hidden` — this registers an S4U principal and **requires an
elevated PowerShell**:

```powershell
# from an Administrator PowerShell
powershell -ExecutionPolicy Bypass -File scripts/observability/install-stack.ps1 -Hidden
```

Without `-Hidden`, a fresh install stays elevation-free and windowed. That
stops being true once any of the four exporter tasks is already registered
S4U from an earlier `-Hidden` run: touching it again — even to flip it back
to windowed — needs elevation too, the same as registering S4U in the first
place, since rolling it back means re-registering that same S4U XML. The
installer checks every exporter task it's about to touch for an existing S4U
principal up front, before any downloads, and refuses with a clear message
if the shell isn't elevated, rather than stopping a running S4U task and
then failing Access Denied mid-registration or mid-rollback.

Re-running the script (with or without `-Hidden`) against tasks previously
registered the other way flips them immediately — the installer stops any running
instance of each exporter task and waits for it to exit before swapping the
task definition, since `Register-ScheduledTask -Force` alone only replaces
the definition and leaves an already-running process alone. Either direction
is a plain re-run (no separate uninstall step needed). The stop is
fail-closed — a stop failure or 30s stop-timeout aborts the run before
touching the task definition, rather than risking two instances fighting
over the same window/session/port. Before replacing an existing exporter
task, the installer exports its current definition; if a later step in the
same run fails — a sibling task's registration throws, or the replacement
registers but never actually starts (`Register-ScheduledTask -Force`
overwrites the definition unconditionally, so a bare restart would just
retry the new, possibly-broken one) — it restores that saved definition
and, only if that task was running before this run (StartAfterRestore),
starts it again and confirms it reaches Running, so an aborted run doesn't leave
a previously-working exporter offline running a broken replacement. The
final "Scheduled tasks" listing reports each exporter's actual state
(`started`, `RESTORED`, `RECOVERED`, `INDETERMINATE`, `REMOVED`, or `NOT
STARTED`/live state as appropriate) —
registration succeeding doesn't guarantee the process launched; S4U in
particular can fail on missing "Log on as a batch job" rights or
EFS/network access under the S4U token.

The exit code's contract: **0 only when every exporter the run touched is
verifiably running under the definition this run requested.** A `RESTORED`
task counts as a failure even though the stack stayed up — the stack being
alive is not the same as the requested `-Hidden` flip having actually
applied, and the script must not report success over a flip that silently
didn't happen. Non-zero covers: any exporter not verifiably running (fresh
install or otherwise), any exporter restored to its previous definition
instead of the requested one, and a run that aborted partway through. Check
the warnings and the final listing for which. (`-Hidden` is an interim
measure; the durable single-service, cross-platform replacement is tracked
in HIMMEL-1425. The `luna-sync-alert` interval task is unaffected.)

"Verifiably running" is checked twice, not once: a task that enters Running
and then dies during its own init (a port conflict, an S4U resource-access
failure that only bites once the process tries to use something) is
re-sampled after a short stability window before being trusted, and every
exporter the run believes it started is re-checked once more in a final
sweep after the whole batch finishes, since a later exporter's startup can
still take an earlier one down. Every scheduled-task lookup across all three
verification sites (the stop-confirmation poll, the start-confirmation poll,
and the final sweep) distinguishes a task genuinely not existing/not running
from the lookup itself failing (an RPC/Task Scheduler hiccup) — the former is
a real answer; the latter isn't, and is never silently read as one. During
the two polls that means "not yet confirmed, keep polling" rather than an
immediate false conclusion; the final sweep has no poll to fall back into (a
single, one-shot re-check), so a failed lookup there is reported as
`INDETERMINATE` instead — loud, and counted toward a non-zero exit, rather
than triggering a rollback of a task that may well be perfectly healthy.

The final sweep's Running check also confirms the task's registered
principal matches the one THIS run requested, not just that it's Running —
two installs running against the same tasks in opposite modes at once could
otherwise cross-confirm each other's flip as this run's own success. Running
under the wrong principal is treated as not (yet) started rather than
silently trusted. True cross-process serialization (so two installs can't
interleave against the same tasks at all) is deferred to the supervisor,
HIMMEL-1425 — running two installs against the same stack concurrently is
still not supported, this just stops one from mis-reporting success over it.

Restoring a saved definition follows that exact same stop-first discipline,
not just the initial registration: if the current replacement instance is
actually live when a restore runs, it is stopped and confirmed stopped
before the old definition is swapped back in, never swapped in underneath a
still-running process. And a restore is never partial across a batch — if
any exporter isn't verifiably running by the time the run finishes, the
whole batch is treated as failed and every pre-existing exporter this run
touched rolls back uniformly to its prior definition, including one that had
already reached Running under the newly-requested definition moments
earlier — whether the trigger was a literal exception (a sibling's
registration throwing) or just one exporter individually never reaching
Running (the common async-S4U case, which doesn't throw at all). The
alternative — a mixed stack where some exporters keep the requested
definition and others get rolled back — would silently contradict the "an
aborted run guarantees no regression" story above.

A stop can also succeed for real while its own confirmation can't — the
polls that would confirm it hit their own lookup failures for the whole
30-second window, not because the process is genuinely stuck. That still
aborts (the definition is never swapped in underneath an unconfirmed
instance), but the task's actual state is re-checked once more before the
run gives up on it: if a fresh lookup now confirms it's stopped, restarting
it under its own untouched definition is the entire recovery (nothing was
ever replaced, so there's nothing to restore) — reported as `RECOVERED`. If
even that retry can't tell, it's reported loudly as `INDETERMINATE` rather
than silently left out of every rollback set — check Task Scheduler
manually in that case.

Rollback symmetry covers both directions a task can enter this run:
pre-existing exporters roll back to their saved XML (started only if they
were running before); an exporter this run created from scratch has no
prior definition to fall back to, so on an aborted batch it is stopped (if
running) and unregistered instead — removed, not left behind registered (and
possibly running under -Hidden/S4U) while its pre-existing siblings revert
to their old, Interactive definitions. The final listing reports this
explicitly as `REMOVED`.

The script installs or verifies Prometheus, Grafana OSS, `windows_exporter`, and
Bun, copies `prometheus.yml` under `%LOCALAPPDATA%\himmel\observability`, and
registers user-level logon scheduled tasks:

- `himmel-observability-prometheus`
- `himmel-observability-grafana`
- `himmel-observability-windows-exporter`
- `himmel-observability-flow-exporter`
- `himmel-observability-luna-sync-alert` (every 10 minutes — see Alerting below)

URLs after the tasks are running:

- Prometheus: `http://127.0.0.1:9090`
- Grafana: `http://127.0.0.1:3000`
- Flow exporter: `http://127.0.0.1:9877/metrics`
- windows_exporter: `http://127.0.0.1:9182/metrics`

Import `dashboards/war-room-system.json` into Grafana. As of HIMMEL-924 the
`${DS_PROMETHEUS}` variable auto-binds to the provisioned Prometheus
datasource (`provisioning/datasources/prometheus.yaml`, fixed `uid:
prometheus`) — no manual bind step.

## Alerting (HIMMEL-1199 — a boundary change)

The flow exporter above stays a pure Prometheus reader — no alerting lives
inside `flow-exporter.ts` or its request path. `luna-sync-alert.ts` is a
**separate, small scheduled checker**, registered as its own task
(`himmel-observability-luna-sync-alert`, every 10 minutes) by
`install-stack.ps1`. It reuses the exact same git read the exporter uses
(`runGitDivergence`, imported from `flow-exporter.ts`, so the two never drift
on what "unpushed" means) and sends a Telegram message via
`scripts/telegram/telegram-api.ts`'s `sendMessage` when the luna vault clone
has unpushed commits — debounced by a tiny state file
(`~/.himmel/luna-sync-alert-state.json`): immediate on the rising edge,
re-alerting only after a cooldown (default 6h) while the condition persists.
It reads the bot token the same way the bridge does
(`~/.claude/channels/telegram/.env`'s `TELEGRAM_BOT_TOKEN`) and the chat_id
from the bridge's own allowlist (`access.json`'s `allowFrom[0]`, override via
`LUNA_SYNC_ALERT_CHAT_ID`). It never runs `git fetch`, same passivity
invariant as the exporter.

## Alert rules + Telegram delivery (HIMMEL-924)

Design doc: `observability-live-system-check.md` §5. Same passivity
invariant as everything above — no alerting logic lives inside
`flow-exporter.ts` or its request path. The rules themselves live in two
places that must be kept in sync (grep both for a rule name before changing
one):

- `alerts.rules.yml` — Prometheus-native rule-file format, the source of
  truth for every expression, loaded via `prometheus.yml`'s `rule_files` so
  Prometheus's own `/rules`/`/alerts` UI shows them and
  `promtool test rules alerts.rules.test.yml` unit-tests them against
  recorded series. **No Alertmanager is installed in this stack**, so
  nothing here is ever delivered from Prometheus's side — purely
  self-visibility + testability.
- `provisioning/alerting/rules.yaml` — the same 9 rules re-implemented in
  Grafana's file-provisioning dialect (query `data` + a `__expr__` threshold
  condition; structurally different from Prometheus's `expr:`/`for:` rule
  format, so it can't just include the file above). **This is what actually
  evaluates and delivers to Telegram** — RATIFIED F3.

`install-stack.ps1` copies `provisioning/` into
`%LOCALAPPDATA%\himmel\observability\grafana-provisioning` and points
Grafana's `[paths] provisioning` at it, alongside the datasource
(`provisioning/datasources/prometheus.yaml`, fixed `uid: prometheus`) and
the notification policy (`provisioning/alerting/policies.yaml`, one flat
route to the Telegram contact point).

### Failure-mode coverage

Every HIMMEL-918 failure mode maps to a rule whose evaluation does not
depend on the failing component itself (the design's acceptance test, §5):

| HIMMEL-918 mode | Rule(s) | Depends on the failing component? |
|---|---|---|
| 600s background-wait truncation | `HimmelFlowRunTruncated` (+ `HimmelFlowLastSuccessAgeExceeded` backstop) | No — reads the ledger's end row, written by the wrapper, not the model |
| Permission-prompt stall / SIGKILL, no exit code | `HimmelFlowRunStalled` | No — exporter-inferred from an unpaired start row past deadline |
| Transient CLI/API death | `HimmelFlowRunError` (or `HimmelFlowRunStalled` if it never writes an end row) | No |
| 4-day silently-disabled scheduled task | `HimmelScheduledTaskDisabled` + `HimmelFlowLastSuccessAgeExceeded` | No — `Get-ScheduledTask`, independent of the flow itself |
| The exporter/collector itself dying | `HimmelWatcherDown` (`up == 0`) | No — Prometheus's own scrape health, not the exporter's output |

Two more rules extend coverage past the 918 postmortem: `HimmelAgentTreeRamRunaway`
and `HimmelOrphanProcesses` (host-level, design §4) and
`HimmelLunaInboxBacklogRising` (pipeline-level, design §3).

### Delivery choice — F3, reusing the bridge's bot token

The design offers two sanctioned options: a separate Grafana-only bot
token, or proving sendMessage-only calls on the existing token can't
collide with the bridge's poller. This ships with the **second** option —
`contact-points.yaml` interpolates `$GRAFANA_TELEGRAM_BOT_TOKEN`/
`$GRAFANA_TELEGRAM_CHAT_ID` from the Grafana process's environment, and
`install-stack.ps1` seeds both (non-fatally, never overwriting an
operator-set value) from the exact same sources `luna-sync-alert.ts` above
already reads: `~/.claude/channels/telegram/.env`'s `TELEGRAM_BOT_TOKEN` and
`access.json`'s `allowFrom[0]`.

Evidence: Telegram's "one poller per bot token" constraint is specific to
long-polling (`getUpdates`) and webhook registration — `sendMessage` has no
exclusivity semantics and any number of processes may call it concurrently
on the same token. `luna-sync-alert.ts` has shipped exactly this
reuse-for-sendMessage-only pattern since HIMMEL-1199 without incident.
Verified live for this ticket: a Grafana 13.1.0 instance was started
against this exact `provisioning/` tree with a fake token/chat_id in its
environment; `starting to provision alerting` / `finished to provision
alerting` logged with no error, and the provisioning API confirmed all 9
rules, the datasource, the contact point (token redacted, present), and the
notification policy loaded correctly. No real Telegram send was exercised
(fake token) — that step is for the operator to confirm on first real run.
An operator who prefers a separate bot can set both env vars to a different
token/chat before running the installer; a pre-set value is left alone.

### Fixed-field content only

Every rule's `summary` annotation renders only `$labels`/`$value` —
`flow`/`task`/`class`/`stage`/`job`/`outcome`, all exporter-derived from
`observability.json` config or fixed enums, plus numeric values. None of
these can carry ledger `note` free text; `flow-exporter.ts` never turns
`note` into a label or annotation value anywhere in the exporter (design
§6.6's injection-carry guard).

### Tuning

- `HimmelAgentTreeRamRunaway`'s 6 GiB threshold and
  `HimmelLunaInboxBacklogRising`'s 3-day/1h grace are literal defaults in
  both rule files — no per-class RAM threshold config surface exists yet in
  `observability.json`/`flow-exporter.ts` (that's host-detector config
  plumbing, out of this ticket's scope). Edit both files together.
- `HimmelOrphanProcesses` only watches `codex-fleet`/`codex-exec-registry`
  (the design's literal default). `mcp-dead-parent-unattributed` and the
  gateway/app-server orphan classes stay dashboard-visible, unalerted.
- `HimmelFlowLastSuccessAgeExceeded` needs a flow's `cadence_seconds`
  declared in `observability.json` (`flow_cadence_seconds{flow}`,
  HIMMEL-924) — a flow with no declared cadence never fires it, matching
  the "dark tile, not a fabricated healthy/unhealthy state" rule for
  uninstrumented flows (design §1.3).

### Deliberately not here

- Loki or log ingestion, and the two §7 log-based rules (error burst, log
  silence) that depend on it — Loki/Alloy are HIMMEL-927's build, not yet
  shipped.
- A second delivery channel split by `severity` (`page` vs `warn`) — one
  flat policy today; the labels are there if an operator wants to add a
  nested route later.
- A `session_dead_total > 0` rule — the HIMMEL-1052 session families landed
  with the alert deliberately left to this rule set; placing it is a small
  follow-up on top of the 9 rules above.
- In-loop subagent *step* counting. The session substrate gives
  start/running/end + outcome, not "3rd of 5 planned steps": there is no
  existing signal for that, and producing one would need subagents to
  self-report over an outbox-style progress channel.
- Reconciling the `armed-resume` double coverage — the scheduler's own
  `flow-runs.jsonl` row and this ledger's `session_start` row for the same
  launch are genuinely different moments (arm event vs. process lifecycle)
  and both are kept.
- Docker, brew, apt, or other Phase B packaging.
