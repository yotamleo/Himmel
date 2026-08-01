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
- `quota_sources` is optional; every key has a derived default (claude:
  `$CLAUDE_USAGE_CACHE`, else `<tmp>/claude/statusline-usage-cache.json`;
  codex: `~/.codex/sessions`; glm: the quota-gauge ledger path).

## Metrics

Flow metrics are derived from `~/.himmel/flow-runs.jsonl` unless
`HIMMEL_FLOW_RUNS_LEDGER` overrides the path.

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

Import `dashboards/war-room-system.json` into Grafana and bind the
`${DS_PROMETHEUS}` variable to the local Prometheus datasource.

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

## Deliberately not here

- Alert rules and Telegram alerting for the wider stack (flows, quota,
  scheduled tasks, host) — `luna-sync-alert.ts` above is the one narrow
  exception, and it is deliberately outside the exporter's passivity
  boundary, not a precedent for adding more alerting inside it.
- Loki or log ingestion.
- Docker, brew, apt, or other Phase B packaging.
