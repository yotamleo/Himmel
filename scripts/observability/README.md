# himmel observability Phase A

Phase A is a local, passive Prometheus/Grafana stack for the Windows host. The
flow exporter is a tiny Bun HTTP server bound to `127.0.0.1:9877`; Prometheus
scrapes it every 60s and also scrapes `windows_exporter` on `127.0.0.1:9182`.

## Passivity invariant

The exporter is a pure reader. It never writes ledgers, never mutates the vault,
never starts or kills processes, and never enforces quota or flow policy. Missing
data stays missing: metric families are omitted when their substrate is absent,
with two explicit-zero exceptions so a quiet, healthy state renders Normal in
Grafana rather than NoData: `flow_run_in_flight{flow} 0` for a silent
configured flow, and `hook_chain_budget_events_recent{action} 0`
(HIMMEL-2478/2480) when no hook-chain skip log is found anywhere.

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

Unpaired `start` rows older than a flow deadline are split by liveness
(HIMMEL-2211): a row whose pid is confirmed dead on this host is exported as
`abandoned` — real hygiene information, but nothing is hung and no human can
act, so it must not page; every other expired row (pid alive, unprobeable, no
pid, or minted on another host) is exported as `stalled`. The flow-run ledger
itself never contains `stalled` or `abandoned`.

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
  "expected_disabled_tasks": [],
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
- `expected_disabled_tasks` (HIMMEL-2075) allowlists tasks in `expected_tasks`
  that are intentionally disabled right now — `HimmelScheduledTaskDisabled`
  skips them via `scheduled_task_expected_disabled{task}`. A task stays in
  `expected_tasks` for `scheduled_task_exists`/`enabled` coverage; this list
  only exempts the disabled-state alert.
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

Per-session tool-call health (HIMMEL-1462) is read from
`~/.himmel/tool-call-census.jsonl` unless `HIMMEL_TOOL_CENSUS` overrides the
path. `scripts/observability/tool-call-census.sh` writes that file by folding
Claude Code session transcripts; the exporter never runs it. Rows whose
`ended_at` falls outside a trailing 24h window are ignored, and a row with no
parseable `ended_at` is dropped rather than dated to now. The exporter
exposes:

- `himmel_tool_calls_total{tool,project}` — tool calls in the window. MCP
  tools appear under their namespaced name (`mcp__qmd__query`), so per-server
  volume needs no second collector.
- `himmel_tool_errors_total{tool,project}` — errored tool results for the same
  tools. An explicit `0` means the tool ran cleanly, never that the census is
  absent.
- `himmel_tool_denials_total{class,project}` — guardrail denials by class: the
  hook name for a `PreToolUse:… hook error:` result, plus
  `auto-mode-classifier`, `user-rejected`, and `hook-unclassified` for a
  denial whose reason carries no nameable token.

Like `flow_run_outcome_total`, these three are WINDOW-FOLDED counters: values
drop as sessions age out of the 24h window, which Prometheus reads as a
counter reset. A missing census file omits all three families; an unparseable
row is skipped with a `# himmel_tool_* partial: ...` comment rather than
costing the family.

Hook-chain budget pressure (HIMMEL-2478/2480) is read from
`.claude/logs/hook-chain-skips.jsonl`. By default the exporter folds the
primary checkout's own log together with every worktree's log
(`.claude/worktrees/*/.claude/logs/hook-chain-skips.jsonl`, summing per-action
counts across all of them) — a worktree session writes to its OWN
`.claude/logs`, invisible to the primary checkout's log otherwise (HIMMEL-2478
CR finding 1). `RUN_HOOK_CHAIN_SKIP_LOG` overrides this to mean exactly one
file — the same override `scripts/hooks/run-hook-with-bash.js`'s own writer
honors, so it is the shared escape hatch for pointing both the writer and the
reader at one log when they run from different roots. Each row records one
hook-chain member that blew its time budget: `action` is `skip` (the guard
silently did not evaluate the tool call) or `deny` (the tool call was refused
fail-closed). The exporter folds rows whose `ts` falls in the trailing
10-minute window (a row more than 5 minutes in the future is dropped as clock
jitter, same grace as the tool census) into:

- `hook_chain_budget_events_recent{action}` — a GAUGE, deliberately NOT a
  window-folded counter: a folded counter reads its own window slide as a
  reset, which is how `increase()` invents phantom spikes. Once at least one
  log in the fold was readable, both actions (`skip`, `deny`) are emitted, `0`
  included, so a quiet box renders Normal rather than NoData; when every log
  that exists failed to read, neither series is emitted at all, and the two
  Grafana rules reading this metric use `noDataState: NoData` for exactly that
  case (HIMMEL-2478/2480).

No log found anywhere emits both actions at `0` plus a
`# hook_chain_budget_events_recent: skip log absent, reporting 0` comment.
That is a limitation, not proof of a healthy fleet: `run-hook-with-bash.js`'s
`logChainSkip` swallows every write error by design (logging must never be
able to gate a tool call), so a writer that could never create the file in the
first place looks identical on disk to a checkout that has simply never
starved a chain member. HIMMEL-2488 tracks the writer-health beacon that would
close that gap. A log that exists but cannot be read omits the whole family
with a `# hook_chain_budget_events_recent omitted: ...` comment — a fault
worth alerting on, which is why the Grafana rules do not treat that absence
as healthy — unless at least one OTHER log in the fold was readable, in which
case its counts still render and a
`# hook_chain_budget_events_recent partial: ...` comment names how many logs
were unreadable; an unparseable row inside a readable log is skipped with its
own `# hook_chain_budget_events_recent partial: ...` comment rather than
costing the family, same fail-soft contract as the tool census.

- `hook_chain_skip_log_unreadable` — a GAUGE, always emitted, `0` when
  healthy (HIMMEL-2478/2480 CR follow-up: a `#` scrape comment is not
  alertable, so the two failure classes above used to have no real series a
  rule could fire on). Counts, at scrape time, each path that exists but
  could not be read, plus `1` if `.claude/worktrees` exists but could not be
  enumerated — an absent worktrees directory (an adopter with none) and an
  absent log both contribute `0`. A non-zero value means
  `hook_chain_budget_events_recent` may be under-counting and the budget
  alerts cannot be trusted while it is set.

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
Written by `session-run-hook.ts` (below); read by the exporter. Four row kinds,
schema `v: 2` since HIMMEL-2022:

| kind / ev | fields |
|---|---|
| `session` / `start` | `v`, `kind`, `ev`, `session_id`, `cwd`, `transcript_path`, `host`, `started_at`, `pid`, `source`, `permission_mode` |
| `session` / `end` | `v`, `kind`, `ev`, `session_id`, `ended_at`, `reason`, `permission_mode`, `model`, `effort`, `duration_s`, `tool_calls`, `tool_call_errors`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `context_tokens` |
| `subagent` / `start` | `v`, `kind`, `ev`, `subagent_id`, `parent_session_id`, `subagent_type`, `description`, `started_at` |
| `subagent` / `end` | `v`, `kind`, `ev`, `subagent_id`, `parent_session_id`, `ended_at`, `outcome` |

`v: 2` only ADDS fields, so v1 rows written before 2026-08-16 stay readable and
the exporter accepts both versions. Everything new on the end row is DERIVED
and nullable — one bounded pass over the session transcript at teardown, never
a guess:

- `model` / `effort` — last assistant turn's `message.model` and top-level
  `effort` (a payload field of the same name wins if a future harness build
  starts carrying one). The SessionEnd payload carries neither today.
- `input_tokens` / `output_tokens` / `cache_read_tokens` — SUMMED across the
  session's assistant turns (consumption).
- `context_tokens` — NOT a sum: the LAST turn's `input + cache_read +
  cache_creation`, i.e. how full the context window was at teardown.
- `tool_calls` / `tool_call_errors` — `tool_use` blocks and `tool_result`
  blocks with `is_error: true`. Subagent (`isSidechain`) records live in the
  same transcript, so these are whole-session totals including fan-out.
- `duration_s` — first to last transcript record the pass parses (first model
  turn to last), not the true SessionStart instant, which the transcript does
  not record. Join the start row if that gap matters.
- `source` (start) — `startup` / `resume` / `clear` / `compact`, straight off
  the payload; it separates a real start from a re-entry into the same id.

Cost, measured 2026-08-22: 196 ms end-to-end (bun startup included) on the
largest transcript in the live corpus, 69 MB; ~95 ms on a typical one. The
SessionEnd hook timeout stays at 10 s — a 50x margin. Reads above
`TRANSCRIPT_MAX_BYTES` (200 MB) are skipped rather than attempted.

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

### When the writer fails: `session-runs.errors.log`

```text
~/.himmel/session-runs.errors.log       (override: HIMMEL_SESSION_RUNS_ERROR_LOG)
```

Fail-open used to mean fail-SILENT, and that cost five days. Between
2026-08-16 and 2026-08-22 the hook exited 0 on every invocation and wrote
nothing: `main()` was a floating `main().catch().finally()` around
`await Bun.stdin.text()`, and under Bun 1.4.0 a pending stdin read does not ref
the event loop, so Bun drained it and exited before stdin was ever consumed.
Nothing anywhere recorded a problem. The stdin read is synchronous now
(`readFileSync(0)`), which cannot lose that race — and every swallowed failure
leaves one bounded line here first:

```text
2026-08-22T04:52:10.539Z session-start SyntaxError: JSON Parse error: Unexpected identifier "not"
2026-08-22T04:52:10.770Z session-end Error: EISDIR: illegal operation on a directory, read
```

One line per failure, message capped at 500 chars and flattened to a single
line, the file capped at 256 KB (past that, new lines are dropped rather than
rotated — this is a breadcrumb trail, not a second ledger). The logger itself
cannot throw, and the hook still exits 0. An unreadable transcript costs the
enriched fields, not the row: the v2 end row lands with nulls.

If the ledger ever goes quiet again, this file is the first place to look —
and if it is empty while the ledger is stale, the hook is not being invoked at
all (check the four `.claude/settings.json` entries and that `bun` is on the
hook's PATH).

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
- `session_dead_total{host}` — crashed/orphaned/wedged sessions. HIMMEL-2075:
  only counts a dead session for `SESSION_DEAD_ALERT_TTL_SECONDS` (24h) after
  it went dead, so `HimmelSessionDead` fires for recent deaths, not the whole
  14d ledger backlog — the dashboard-facing `/sessions.json` status stays
  `dead` for the full window regardless. HIMMEL-2149: `HimmelSessionDead` is
  `severity: warn`, not `page` — the himmel end-row hook is already on the
  HIMMEL-2004 detach/enqueue path, yet ghost sessions (transcript idle,
  no end row) still occur, traced to HIMMEL-2148's SessionEnd envelope
  cancellation upstream of this repo's hooks; neither pid (never populated
  in a SessionStart hook payload) nor the transcript carries a crash-vs-
  clean-exit signal this exporter can honestly act on. Severity alone does
  NOT reduce Telegram noise under the flat notification policy (every
  severity shared one repeat_interval) — `provisioning/alerting/policies.yaml`
  now carries a nested `severity = warn` route dropping the repeat interval
  to 168h (7d) instead of the page-level 12h, so warn alerts still deliver,
  just far less often. Revisit once HIMMEL-2148 lands.
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

### Sweeper-status extension (LUNA-131 — a second, independent trigger)

The headless vault sweeper (`vault-autosync.ps1 -Sweep`) writes a heartbeat,
`<StateDir>\status.json` (default `~/.himmel/luna-sync/status.json`, override
via `HIMMEL_LUNA_SWEEPER_STATUS`), on **every tick**. `luna-sync-alert.ts`
reads and `JSON.parse`s that file in `main()` (never inside `checkLunaSync`,
which stays fs/network-free by design) and passes the parsed value — or
`null` on a missing/unparseable file — into `checkLunaSync` as a
`sweeperStatus` opt. The pure, exported `evaluateSweeperStatus(status, nowMs)`
turns it into a `red | yellow | green` level plus a reason:

- **RED** if any of: the status file is missing/unparseable or its `ts` is
  more than 30 min old (`sweeper-dead` — the sweeper itself is not running);
  `last_clean_ts` is more than 60 min old (`stale`);
  `consecutive_pull_skips >= 12` (`pull-backlog`);
  `consecutive_push_failures >= 6` (`push-blocked`); or `alarm_class` is one
  of `auth`, `plugin-resurrected`, `wrong-remote` (reported as that class).
- **YELLOW** if not RED and `last_alarm_ts` falls within the last 24h.
  YELLOW never wakes the operator on its own — it is only appended as a note
  to an alert that RED (or a genuine git divergence) is already sending.
- **GREEN** otherwise. A GREEN sweeper reading never resets the git-divergence
  debounce state on its own — GREEN is not evidence about the git tree; only
  a genuinely-clean git tree does that (and not when the sweeper itself is RED).

This is a **second, independent trigger** on the same alert: a RED sweeper
reading fires even on an otherwise git-clean vault (the swallow regression
the existing `clean` early-returns would otherwise cause), and a genuine git
divergence still fires regardless of sweeper level, exactly as before. Same
rising-edge + 6h cooldown debounce; same Telegram delivery path.

**Detection-latency budget: ≤90 min** from outage onset to operator
notification. Achieved: ≤70 min for a stalled sync (60 min `stale` threshold
+ ≤10 min poll granularity), and ≤40 min for a dead sweeper (30 min
`sweeper-dead` threshold + ≤10 min poll granularity).

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
- `provisioning/alerting/rules.yaml` — the same 17 rules re-implemented in
  Grafana's file-provisioning dialect (query `data` + a `__expr__` threshold
  condition; structurally different from Prometheus's `expr:`/`for:` rule
  format, so it can't just include the file above). **This is what actually
  evaluates and delivers to Telegram** — RATIFIED F3.

`install-stack.ps1` copies `provisioning/` into
`%LOCALAPPDATA%\himmel\observability\grafana-provisioning` and points
Grafana's `[paths] provisioning` at it, alongside the datasource
(`provisioning/datasources/prometheus.yaml`, fixed `uid: prometheus`) and
the notification policy (`provisioning/alerting/policies.yaml`) — the
default route (12h repeat) to the Telegram contact point, plus (HIMMEL-2149)
a nested `severity = warn` route on the SAME contact point at a 168h (7d)
repeat, so a warn-severity alert still delivers but far less often than a
page.

**`noDataState` policy (HIMMEL-2478/2480, corrected after a measured
false-alert bug):** the criterion is what the query returns in the HEALTHY
case, not whether `refId A` happens to be a bare selector. `NoData` is
correct only when the healthy query still returns a PRESENT series valued 0
— so an EMPTY result means the series' absence IS the alarm. When `refId A`
instead embeds a comparison, that comparison is a PromQL filter, so the
healthy case returns an empty vector — `NoData` there turns "healthy" into a
firing `DatasourceNoData` alert. 9 of the original 14 rules had exactly that shape;
measured live, Grafana reported `grafana_alerting_alerts{state="nodata"} 9`
against `{state="alerting"} 0` while sending ~125 Telegram messages/day for
~2/day of genuine alerts. Those 9 (`HimmelFlowLastSuccessAgeExceeded`,
`HimmelScheduledTaskDisabled`, `HimmelWatcherDown`, `HimmelKernelPoolCritical`,
`HimmelAgentTreeRamRunaway`, `HimmelLunaInboxBacklogRising`,
`HimmelKernelPoolHigh`, `HimmelKernelPoolLeakRate`, `HimmelCommitPressure`) now
use `noDataState: OK`. `HimmelFlowStalled` keeps `KeepLast` (HIMMEL-2211, see
its comment in `rules.yaml`); the remaining 7 (`HimmelFlowRunTruncated`,
`HimmelFlowRunError`, `HimmelOrphanProcesses`, `HimmelSessionDead`, and the
three hook-chain rules — `HimmelHookChainBudgetPressure`,
`HimmelHookChainBudgetDenials`, `HimmelHookChainLogUnreadable`) keep the
`NoData` default — for the hook-chain rules, refId A IS a bare metric
selector, unlike the 9 OK rules, but their series genuinely goes absent when
`hookChainMetrics`/`defaultHookChainSkipLogPaths` (flow-exporter.ts) fails to
read the skip log (or enumerate the worktrees directory, for
`HimmelHookChainLogUnreadable`), and that absence is a fault worth alerting on
(HIMMEL-2478/2480), not a healthy filter match. Full
per-rule reasoning + the code smell that flags a rule needing `OK`
(`refId B`'s `gt -1` evaluator) lives in `rules.yaml`'s header comment —
this table is the enforced expectation in
`test-promtool-validation.sh`.

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
| 2026-09-03 spawn-storm hang (HIMMEL-2478) | `HimmelHookChainBudgetPressure` + `HimmelHookChainBudgetDenials` + `HimmelHookChainLogUnreadable` | No — reads the skip log `scripts/hooks/run-hook-with-bash.js` writes when a chain member blows its time budget, independent of the starved member itself; `HimmelHookChainLogUnreadable` covers the reader's own read/enumeration failures, which would otherwise degrade the first two silently |

Four more rules extend coverage past the 918 postmortem: `HimmelAgentTreeRamRunaway`
and `HimmelOrphanProcesses` (host-level, design §4), `HimmelLunaInboxBacklogRising`
(pipeline-level, design §3), and `HimmelSessionDead` (session-level, HIMMEL-1052/1635).
Four more again cover kernel pool and commit pressure — see below.

### Kernel pool + commit pressure (HIMMEL-1604)

OVERLORD8 has two reboot-only kernel-pinned leak families — File (nonpaged) and
Token (paged) — that grow in proportion to file-handle churn (HIMMEL-1166 /
HIMMEL-1993). Two long diagnostic sessions (2026-07-20, 2026-08-06) were spent on
them because nothing watched the metrics windows_exporter's `memory` collector was
already scraping. These four rules close that gap using only already-scraped
series — the per-tag `File`/`Toke` breakdown needs the poolmon textfile exporter
tracked in HIMMEL-1166 and is deliberately NOT here.

| Rule | Expression shape | Threshold | `for` | Severity |
|---|---|---|---|---|
| `HimmelKernelPoolHigh` | nonpaged + paged pool bytes | > 12 GiB | 15m | warn |
| `HimmelKernelPoolCritical` | nonpaged + paged pool bytes | > 18 GiB | 5m | page |
| `HimmelKernelPoolLeakRate` | `deriv(… [1h:5m]) * 3600` | > 1 GiB/h | 1h | warn |
| `HimmelCommitPressure` | committed / commit_limit | > 0.85 | 15m | warn |

Calibration evidence (2026-08-20/23 measurements on OVERLORD8): quiet post-boot
steady state ~1.9–2 GiB pool total; 44 min after a reboot 6.1 GiB (2.05 nonpaged /
4.08 paged); pre-reboot peak ~21 GiB (11.8 paged / 9.3 nonpaged); slope +0.13 GiB/h
quiet vs +1.2 GiB/h under a 6-worker swarm. 12 GiB sits above every observed healthy
value and well below the peak; 18 GiB is the "take the reboot now" band.

`HimmelKernelPoolLeakRate` is the rule that earns its keep. Both incidents were slow
accumulations, and a level-only alert fires long after the leaking process has
exited — by then the pool is kernel-pinned, only a reboot reclaims it, and the
evidence needed to attribute it is gone. `deriv()` over a subquery rather than
`rate()`/`increase()` because pool bytes are a **gauge** that legitimately falls;
`rate()` would read every reclaim as a counter reset.

Both rule files carry the same four expressions byte-identically — the promtool
suite (`alerts.rules.test.yml`) asserts each against a healthy post-boot fixture
(all four silent) and against the recorded episode-2 known-bad sample (all three
level/ratio rules firing), plus a synthetic +1.5 GiB/h climb that never reaches any
level threshold, where the slope rule is the only thing that fires.

### Delivery choice — seed from himmel's own `.env`, HIMMEL-2209

`contact-points.yaml` interpolates `$GRAFANA_TELEGRAM_BOT_TOKEN`/
`$GRAFANA_TELEGRAM_CHAT_ID` from the Grafana process's environment.
`install-stack.ps1` seeds both at User scope from himmel's own repo-root
`.env` ONLY, non-fatally, and never overwriting an operator-already-set
value. If either key is absent (or empty) in `.env`, the installer warns
loudly and leaves that var unset — there is no fallback to any other
source. (An earlier revision of this seeding step reused the Telegram
bridge's `.env`/`access.json` instead, which silently misrouted ops alerts
to the shared luna bot / the operator's personal DM; that design is
retired.)

An operator who wants a specific bot/chat sets `GRAFANA_TELEGRAM_BOT_TOKEN`
and `GRAFANA_TELEGRAM_CHAT_ID` in himmel's `.env` (see `.env.example`)
before running the installer; a value already set at User scope is left
alone either way.

### Fixed-field content only

Every rule's `summary` annotation renders only `$labels`/`$value` —
`flow`/`task`/`class`/`stage`/`job`/`outcome`, all exporter-derived from
`observability.json` config or fixed enums, plus numeric values. None of
these can carry ledger `note` free text; `flow-exporter.ts` never turns
`note` into a label or annotation value anywhere in the exporter (design
§6.6's injection-carry guard).

### Tuning

- `HimmelAgentTreeRamRunaway` (HIMMEL-2075) scales a 6 GiB base by
  `subagent_active_total`: +1 GiB per active subagent above 2, station-wide
  (`scalar(sum(...))`), so ordinary overnight-swarm fanout doesn't page on
  the flat default. Still no per-class config surface — both literals (base,
  per-subagent step) are literal defaults in both rule files; edit together.
  HIMMEL-2149: the expression also excludes `class="other"` —
  `host-detectors.ps1`'s catch-all for every process NOT descended from a
  recognized agent root (the rest of the desktop), which otherwise dwarfs
  the swarm-scaled threshold on a normal desktop. Still emitted on the
  `agent_tree_rss_bytes` series for the dashboard, just excluded from this
  alert.
- `HimmelFlowRunStalled`'s alerting bucket
  (`flow_run_outcome_total{outcome="stalled"}`) is capped at
  `FLOW_STALLED_ALERT_TTL_SECONDS` (24h, HIMMEL-2149) measured from when a
  row became stalled — same shape as `SESSION_DEAD_ALERT_TTL_SECONDS` above.
  Without it a single killed worker paged on the alert's 12h interval for up
  to 14 days as its ghost start row aged through the ledger window.
  HIMMEL-2211: that killed-worker case is now caught upstream — a row whose
  pid is confirmed dead on its own host is exported as `abandoned`, not
  `stalled`, so it never reaches this bucket at all. What remains (`stalled`,
  a live/unprobeable/foreign-host pid) still needs damping against a flapping
  series, which is why the alert also carries `for: 10m` (damps a transient
  count) and `keep_firing_for: 30m` (rides out a scrape gap without
  resolving) — safe only because `prometheus.yml`'s `scrape_timeout: 30s`
  first stopped the exporter's ~6.6s-avg/~9.9s-peak render from blowing
  Prometheus's 10s default and staling the series 51x/day. That flap alone
  produced 53 pages in one night for zero real incidents.
- `HimmelLunaInboxBacklogRising`'s 3-day/1h grace is a literal default in
  both rule files — no config surface exists yet in
  `observability.json`/`flow-exporter.ts`. Edit both files together.
- The four HIMMEL-1604 pool/commit thresholds (12 GiB, 18 GiB, 1 GiB/h, 0.85)
  are literal defaults in both rule files, same convention as
  `HimmelAgentTreeRamRunaway` — there is no config surface, tune by editing the
  expression in `alerts.rules.yml` AND its Grafana twin together, then re-running
  the promtool suite.
- `HimmelOrphanProcesses` only watches `codex-fleet`/`codex-exec-registry`
  (the design's literal default). `mcp-dead-parent-unattributed` and the
  gateway/app-server orphan classes stay dashboard-visible, unalerted.
- `HimmelFlowLastSuccessAgeExceeded` needs a flow's `cadence_seconds`
  declared in `observability.json` (`flow_cadence_seconds{flow}`,
  HIMMEL-924) — a flow with no declared cadence is excluded from the `on
  (flow)` join and never fires. If every flow lacks a declared cadence the
  whole query is empty; that resolves as `noDataState: OK` (see the
  `noDataState` policy above), not a fabricated healthy/unhealthy state.

### Deliberately not here

- Loki or log ingestion, and the two §7 log-based rules (error burst, log
  silence) that depend on it — Loki/Alloy are HIMMEL-927's build, not yet
  shipped.
- A second delivery channel split by `severity` (`page` vs `warn`) — one
  flat policy today; the labels are there if an operator wants to add a
  nested route later.
- In-loop subagent *step* counting. The session substrate gives
  start/running/end + outcome, not "3rd of 5 planned steps": there is no
  existing signal for that, and producing one would need subagents to
  self-report over an outbox-style progress channel.
- Reconciling the `armed-resume` double coverage — the scheduler's own
  `flow-runs.jsonl` row and this ledger's `session_start` row for the same
  launch are genuinely different moments (arm event vs. process lifecycle)
  and both are kept.
- Docker, brew, apt, or other Phase B packaging.
