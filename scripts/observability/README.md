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
  "vault_path": "C:/Users/you/Documents/luna"
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

## Metrics

Flow metrics are derived from `~/.himmel/flow-runs.jsonl` unless
`HIMMEL_FLOW_RUNS_LEDGER` overrides the path.

Quota metrics are re-exported through `scripts/telegram/quota-gauge.ts` from
`~/.himmel/quota-gauge.jsonl` unless `HIMMEL_QUOTA_GAUGE_LEDGER` overrides the
path. Lane budget metadata from `scripts/lanes/lanes.json` may appear as
registry labels, such as `posture="conserve"`, when present.

Scheduled task and Luna backlog walks are cached for 60s. The flow ledger fold
runs on every scrape so in-flight age and stall inference are fresh.

## Install on Windows

From a PowerShell session in the repo:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/observability/install-stack.ps1
```

The script installs or verifies Prometheus, Grafana OSS, `windows_exporter`, and
Bun, copies `prometheus.yml` under `%LOCALAPPDATA%\himmel\observability`, and
registers user-level logon scheduled tasks:

- `himmel-observability-prometheus`
- `himmel-observability-grafana`
- `himmel-observability-windows-exporter`
- `himmel-observability-flow-exporter`

URLs after the tasks are running:

- Prometheus: `http://127.0.0.1:9090`
- Grafana: `http://127.0.0.1:3000`
- Flow exporter: `http://127.0.0.1:9877/metrics`
- windows_exporter: `http://127.0.0.1:9182/metrics`

Import `dashboards/war-room-system.json` into Grafana and bind the
`${DS_PROMETHEUS}` variable to the local Prometheus datasource.

## Deliberately not here

- RAM process trees, orphan attribution, and per-subtree memory panels:
  HIMMEL-924.
- Alert rules and Telegram alerting.
- Loki or log ingestion.
- Docker, brew, apt, or other Phase B packaging.
