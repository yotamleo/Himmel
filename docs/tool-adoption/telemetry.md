# Skill-usage telemetry — measure-during for in-use tools (HIMMEL-236)

> The 0-cost live measurement seam behind the
> [rubric §4](rubric.md#4-measurement-protocol) measure-during protocol.
> For skills/tools **already in the default path** (luna-ingest,
> handover-arm-resume, the jira CLI, the bridge) a before/after baseline
> is impossible — there is no "without" workday to capture. Instead,
> outcome-per-session signals are recorded as a side-effect of real
> sessions and analysed later. Part of the HIMMEL-199 framework; child
> of HIMMEL-167.

## The 0-cost contract (the point — preserve it)

- **No tokens in the hot path.** Records go to disk, never into model
  context. `telemetry_emit` writes nothing to stdout, ever.
- **No network, no LLM invocations, no new MCP servers.** The seam is a
  shell-library append fed by existing harness events.
- **Fail-open.** Telemetry must never break the instrumented skill:
  `telemetry_emit` always returns 0 (safe under `set -e`), and callers
  source the lib with a no-op fallback. A broken seam loses a data
  point, not an arm/ingest/session.

## Record format

One JSONL line appended per emit — in practice one per session per
instrumented skill (an emit sits at a skill's outcome point, which fires
about once a session). Sink:

```
~/.claude/telemetry/skill-usage.jsonl     (override: SKILL_TELEMETRY_DIR)
```

```json
{"v":1,"ts":"2026-06-11T03:14:15Z","session_id":"abc-123","repo":"himmel","skill":"handover-arm-resume","event":"armed","time":"09:30","force":"0"}
```

| Field | Meaning |
|-------|---------|
| `v` | Format version, currently `1`. |
| `ts` | UTC ISO8601 emit time. |
| `session_id` | `$CLAUDE_SESSION_ID` when the launching wrapper/hook exports it; `-` otherwise. |
| `repo` | Basename of the git toplevel the skill ran in; `-` outside a repo. |
| `skill` | The emitting skill/tool (e.g. `handover-arm-resume`). |
| `event` | The outcome signal (e.g. `armed`, `dedup-block`). |
| *extra* | Free-form `key=value` pairs passed to `telemetry_emit`, recorded as string fields. |

The events map onto the rubric's outcome-per-session signals: re-launches
(`armed`), friction/interventions (`dedup-block`, future `*-fail` events),
ticket-shipped and stuck-loop signals as more emitters land. Tokens are
deliberately NOT a field — the KPI is outcome-per-session, never bytes
(rubric §1, the vanity-metric trap).

## Emitting from a skill/script

```bash
# shellcheck source=../lib/telemetry.sh
. "$SCRIPT_DIR/../lib/telemetry.sh" 2>/dev/null || true
command -v telemetry_emit >/dev/null 2>&1 || telemetry_emit() { return 0; }

telemetry_emit <skill> <event> [key=value ...]
```

Place emits at **outcome points** (the success exit, a guardrail block),
not in per-iteration loops — the format is one append per session, not
an event firehose. `--dry-run` paths must NOT emit (touch-nothing
contracts win).

Env knobs: `SKILL_TELEMETRY_DISABLE=1` (kill switch, launching shell),
`SKILL_TELEMETRY_DIR` (sink override — tests use this).

## Current emitters

| Skill | Events | Signal |
|-------|--------|--------|
| `handover-arm-resume` (`scripts/handover/arm-resume.sh`) | `armed`, `dedup-block` | re-launches armed; dedup friction |

## Analysis (later, out of the hot path)

The sink is plain JSONL — slice it offline (jq/python) when a verdict is
due. A retroactive verdict for an in-use tool = read its rows across
real workdays and answer the rubric §4 questions: did sessions ship,
how often did the tool fire, what friction events cluster around it.
The analysis pass is intentionally NOT built here; the seam exists so
the data is already on disk when someone asks.

**Caveat — no rows ≠ no usage.** The seam is fail-open: a persistently
unwritable sink (bad `SKILL_TELEMETRY_DIR`, permissions, full disk) — or
the `SKILL_TELEMETRY_DISABLE=1` kill switch left set in the launching
shell — drops every record silently and is indistinguishable from "the
tool never fired". Before reading an empty/sparse dataset as zero usage
at verdict time: first confirm `SKILL_TELEMETRY_DISABLE` is unset in the
environment you check from (`telemetry_emit` silently no-ops under the
kill switch, so the sink check below would report a broken sink on a
healthy one), then confirm the sink is writable from that same
environment (source the lib, `telemetry_emit sink-check ping`, check a
row landed). Exclude/filter `sink-check` rows when slicing the data at
analysis time — they are probe artifacts, not skill usage.

## Implementation

- Lib: `scripts/lib/telemetry.sh` (+ smoke test `scripts/lib/test-telemetry.sh`).
- Emitter tests: `scripts/handover/test-arm-resume.sh` T21-T24
  (dedup-block emit, dry-run/kill-switch suppression, armed emit,
  create-failure no-emit, caller-side fail-open with an absent/broken lib).
