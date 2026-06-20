# Hermes junior tier — provider-route runbook (HIMMEL-278)

Hermes (NousResearch hermes-agent) runs as himmel's junior tier for
chore-shaped work (vault inbox capture, summaries, note-taking) on free
inference — see the registry row in
[`docs/tool-adoption/registry.md`](tool-adoption/registry.md) (HIMMEL-272
rubric) for the adoption rationale, trust posture, and write fence.

This runbook captures the provider wiring (config lives OUTSIDE this
repo) so a machine rebuild can reproduce it.

## Install layout (Windows)

- Install root: `%LOCALAPPDATA%\hermes\` — config.yaml, SOUL.md,
  `agent-hooks/luna_vault_guard.py` (fail-closed vault write fence),
  `.env` (API keys), venv at `hermes-agent\venv\Scripts\hermes`.
- Hermes reads its OWN `.env` (`%LOCALAPPDATA%\hermes\.env`) — shell
  env and himmel's repo-root `.env` are irrelevant to it.

## Keeping it updated (HIMMEL-426)

`hermes-agent` is an **editable git checkout** (`pip install -e`) of
`NousResearch/hermes-agent` living at `<install-root>/hermes-agent`, so a
himmel `git pull` never updates it. `/himmel-update` (and `/himmel-update-all`)
now pulls that checkout and re-runs the editable install as one of its steps;
`/himmel-update --check` reports whether a hermes update is available without
applying it. The step resolves the install root from `HERMES_HOME` (else
`%LOCALAPPDATA%\hermes`) and operates on its `hermes-agent/` subdir; it skips
cleanly and never fails the himmel update when hermes isn't installed. After an
update, **restart the hermes gateway** (`hermes gateway restart`, when no
session is running) to pick up changes.

## Provider routes (wired 2026-06-12, HIMMEL-278)

Routing policy per the ticket: free routes first, fail-open down the
chain with a visible note. The gemini-cli / Google-OAuth subscription
route was **VOIDED by the operator** (HIMMEL-277 spike follow-up) —
API-key routes only.

The live `config.yaml` block:

```yaml
model:
  default: nvidia/nemotron-3-ultra-550b-a55b
  provider: nvidia
  base_url: https://integrate.api.nvidia.com/v1
providers: {}
fallback_providers:
- provider: openrouter
  model: nvidia/nemotron-3-ultra-550b-a55b:free
```

> **2026-06-19 — gemini route removed.** The AI Studio API project behind
> `GEMINI_API_KEY`/`GOOGLE_API_KEY` was suspended by Google (Gemini API ToS /
> Prohibited Use Policy). The `gemini`/`gemini-flash-latest` fallback was
> dropped from the live config; chain is now NIM primary → OpenRouter only.
> Re-add only with a fresh, working Gemini API key (paid project — the free
> tier is unavailable in the EEA).

| # | Route | Provider name | Model | Key (env name in hermes `.env`) | Why this position |
|---|-------|---------------|-------|--------------------------------|-------------------|
| 1 (primary) | NVIDIA NIM | `nvidia` (built-in; aliases `nim`, `nemotron`) | `nvidia/nemotron-3-ultra-550b-a55b` | `NVIDIA_API_KEY` | Free NIM credits; current Nemotron Ultra flagship. NIM model ids ARE vendor-prefixed — `hermes doctor`'s "vendor-prefixed slug" warning is a false-positive heuristic here. |
| 2 | OpenRouter | `openrouter` (built-in) | `nvidia/nemotron-3-ultra-550b-a55b:free` | `OPENROUTER_API_KEY` | Same model via a different aggregator — NIM quota/outage fallback keeps behavior comparable. |
| ~~3~~ | ~~Gemini API~~ | `gemini` (built-in; reads `GOOGLE_API_KEY` or `GEMINI_API_KEY`) | `gemini-flash-latest` (rolling alias) | `GOOGLE_API_KEY` | **REMOVED 2026-06-19** — AI Studio project suspended (see note above). Was deliberately last (scarce key, 429s). |

Not wired, with reasons (recorded so a rebuild doesn't "fix" them):

- **DeepSeek** — planned in HIMMEL-278 but no `DEEPSEEK_API_KEY` on the
  machine yet. Add `- provider: deepseek` + model when a key lands.
- **Ollama local** — Ollama is not installed on this machine (PATH stub
  only). If installed later: provider `custom` with
  `base_url: http://localhost:11434/v1`, no key.
- **gemini-cli / OAuth routes** — VOIDED by operator (HIMMEL-277);
  do not re-add.

`providers: {}` stays empty on purpose: both routes are built-in
provider names, so endpoint + key-env resolution comes from hermes's
internal registry; a `providers:` entry is only needed for custom
endpoints or per-provider timeout overrides.

Fallback semantics (hermes docs `fallback-providers.md`): entries tried
in list order on 429-after-retries / 5xx-after-retries / immediate
401/403/404; fallback is per-turn — the primary is retried on each new
user message.

## Verify after a rebuild (zero inference cost)

```
hermes fallback list   # chain resolves: nvidia primary + 1 fallback
hermes auth list       # one credential per provider, sourced from env
hermes doctor          # API Connectivity: ✓ OpenRouter ✓ NVIDIA NIM
```

Then one paid-nothing smoke: `hermes --cli -z "Reply with exactly: OK"`
(NIM free credits). The hermes gateway (Telegram bot) reads config at
start — restart it (`hermes gateway restart`, when no session is
running) to pick up route changes.

## Recover a broken venv pip ("No module named pip")

uv-created venvs (the default hermes install uses `uv venv`) ship **without
pip**, so the editable refresh — and any manual `pip install -e .` — fails
with `No module named pip`. `/himmel-update` now bootstraps pip
automatically (`ensurepip`) before the refresh; to repair by hand (older
checkout, or the gateway is misbehaving after a pull):

```
# <venv-py> = …/hermes/hermes-agent/venv/Scripts/python.exe  (Windows)
#             …/hermes/hermes-agent/venv/bin/python           (macOS/Linux)
"<venv-py>" -m ensurepip --upgrade      # restore pip into the venv
cd …/hermes/hermes-agent
"<venv-py>" -m pip install -e .          # editable reinstall (picks up pulled code)
hermes gateway restart                   # restart the gateway to load the changes
```

Wiring verified 2026-06-12: all connectivity probes green (3 routes at the
time; gemini route removed 2026-06-19 — see note above, now 2);
config backup at `config.yaml.bak.20260612_overnight`.
