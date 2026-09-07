# Operator profile: the TBD delta

HIMMEL-2307. The v2 install-profile schema (`scripts/install/
capture-operator-profile.mjs`) captures what the wizard's questions *can*
express today. This document lists what the operator's reference machine
actually **runs** that no wizard question can currently produce — the gap
between "a fresh adopter install" and "the operator's own machine." Each row
is one item from a live delta capture on that machine; regenerate the
evidence with:

```bash
node scripts/install/capture-operator-profile.mjs --delta-out /tmp/operator-delta.json
```

Classification values: `covered-by-wizard` (the wizard already asks this —
listed here only if it was worth double-checking), `ticketed: HIMMEL-NNNN`
(a filed ticket already scopes closing this gap), `NOT-TICKETED` (no ticket
covers it yet — flagged for the parent to file).

| # | Item | Captured how | Wizard coverage today | Classification |
|---|------|--------------|------------------------|-----------------|
| 1 | Armed cadences beyond the pipeline family (graphmap, qmd, drift-fix, codex-sweep, ggs, repo-sync) | `schtasks`/cron enumeration matched against 7 known cadence-id task groups (`delta.cadences.taskDetail`) | The wizard's luna-cadence question is binary off/on and only speaks to the pipeline family; it cannot select or report the other six | ticketed: HIMMEL-2302 |
| 2 | Scheduled tasks that exist but aren't in any of the 7 cadence ids (`HIMMEL-BootPreflight`, `HIMMEL-ForkResync` when armed) | Membership check against a known-extra-tasks list, same scheduler enumeration as #1 (`delta.cadences.extraArmedTasks`) | None — these tasks aren't offered, selected, or even named anywhere in the wizard | ticketed: HIMMEL-2325 (BootPreflight as a per-item armable step — extend-comment filed); HIMMEL-ForkResync is the drift-fix cadence family (HIMMEL-2302 registry enumeration) |
| 3 | Observability registry stack (`~/.himmel/observability.json` — `flows[]`, `expected_tasks[]`, `expected_disabled_tasks[]`) | Direct read of `$HIMMEL_OBSERVABILITY_CONFIG` or the default path (`delta.observability`) | None — this registry is written by cadence *register* actions as a side effect; the wizard never surfaces or reconciles it | ticketed: HIMMEL-2326 |
| 4 | Bridge persistence artifact detail (the actual `HimmelTelegramBridge` scheduled task / `telegram-bridge.service` unit, beyond the yes/no `installPersistence` answer) | Scheduler/systemd-unit presence check (`profile.bridge.installPersistence`, `delta.cadences.extraArmedTasks`) | The wizard asks a one-time consent to install persistence; it never re-verifies the artifact is still there on a later run | ticketed: HIMMEL-2328 |
| 5 | Guardrail env posture — which SESSION-ONLY bypass/threshold vars (`EDIT_ON_MAIN_OK`, `AUTO_ARM_THRESHOLD`, ...) are set in the invoking shell | Presence check (boolean only, never the value) against the names documented in `.env.example`'s SESSION-ONLY section (`delta.envKeys.guardrailEnvPosture`) | None, and inherently shell-dependent (a launch-time export, not a durable answer) — noted explicitly as such | ticketed: HIMMEL-2331 |
| 6 | Codex/hermes profile *install completion* (auth provisioned, model pulled) beyond the lane opt-in consent | Indirect — the live lane probe (`delta.lanes.liveLaneIds` containing `codex-exec`/`hermes-oneshot`) confirms the CLI is reachable, not that setup finished | `--with-codex`/`--with-hermes` record the opt-in *consent*; nothing tracks whether the follow-on install script (`install-himmel-codex.*`, `install-himmel-profile.*`) actually completed | ticketed: HIMMEL-2328 |
| 7 | Handover registry entries — repo names + count in `~/.claude/handover/registry.json` (never paths) | Direct read (`delta.handover.registryEntryNames`, `registryEntryCount`) | The wizard can point `HANDOVER_DIR` at an external repo, but registering/initializing it in the v2 handover skill's own registry is a separate manual step (`/handover-setup`) | ticketed: HIMMEL-2299 |
| 8 | HUD config (`claude-hud.json` presence, its top-level key names, whether `statusLine.command` references it) | Existence + `settings.json` substring check (`delta.hud`) | None — HUD setup isn't part of the wizard at all | ticketed: HIMMEL-2329 |
| 9 | Repo-root `.env` key NAMES beyond the generated secrets-manifest block (dozens of personal/operator-only keys — home-network, VM, GGS/HA integrations, etc.) | Diff of the primary checkout's `.env` key names against `.env.example`'s generated block + SESSION-ONLY names (`delta.envKeys.keysBeyondGeneratedBlock`) | The wizard's secrets walk only walks the generated manifest; it has no concept of a key beyond that set | ticketed: HIMMEL-2305 |
| 10 | Lane readiness gates (`passesRequired` probation counters) and the full dormant-lane roster (opt-in env names) | Direct read of `scripts/lanes/lanes.json`'s `readiness`/`dormant` fields (`delta.lanes.readinessGates`, `dormantLanes`) | The wizard offers only the 4 wizard-askable lane ids (`ollama-local`, `copilot-cli`, `codex-exec`, `hermes-oneshot`); it never surfaces readiness-gate progress or the dormant-lane roster (`glm`, `claudex`, `codex-wsl`, `openrouter-claude`) | ticketed: HIMMEL-2330 |
| 11 | Plugin drift from the lean floor (`enabledBeyondTemplate` / `templateTrueButDisabled`) | Effective `enabledPlugins` (settings.json layered under settings.local.json) diffed against `docs/setup/settings-template.json` (`delta.plugins`) | `pluginSet` is fixed to `"lean"` (HIMMEL-2304); nothing re-verifies the LIVE enabled set still matches the floor after an ad hoc `/plugin` toggle | ticketed: HIMMEL-2328 |
| 12 | `alwaysOn` inference gap — the capture INFERS `alwaysOn` from armed cadences/bridge persistence (`delta.alwaysOnInferred: true`); it is never an asked-and-recorded answer at capture time | Heuristic over the same cadence/bridge data as #1/#4 | The adopter wizard flow does ask an explicit always-on question, but nothing reconciles that stored answer against what's actually armed on a later run | ticketed: HIMMEL-2325 (reconcile via its per-item probes — extend-comment filed) |

## Regeneration

This document is hand-written frame + generated-content rows; when the delta
shape changes materially, re-run the command above, diff it against the
table, and update rows by hand (there is no automated doc generator for this
file — it is meant to be read and judged, not templated).
