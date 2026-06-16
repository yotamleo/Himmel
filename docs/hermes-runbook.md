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
- provider: gemini
  model: gemini-flash-latest
```

| # | Route | Provider name | Model | Key (env name in hermes `.env`) | Why this position |
|---|-------|---------------|-------|--------------------------------|-------------------|
| 1 (primary) | NVIDIA NIM | `nvidia` (built-in; aliases `nim`, `nemotron`) | `nvidia/nemotron-3-ultra-550b-a55b` | `NVIDIA_API_KEY` | Free NIM credits; current Nemotron Ultra flagship. NIM model ids ARE vendor-prefixed — `hermes doctor`'s "vendor-prefixed slug" warning is a false-positive heuristic here. |
| 2 | OpenRouter | `openrouter` (built-in) | `nvidia/nemotron-3-ultra-550b-a55b:free` | `OPENROUTER_API_KEY` | Same model via a different aggregator — NIM quota/outage fallback keeps behavior comparable. |
| 3 | Gemini API | `gemini` (built-in; reads `GOOGLE_API_KEY` or `GEMINI_API_KEY`) | `gemini-flash-latest` (rolling alias) | `GOOGLE_API_KEY` | Key exists but is scarce (already showed a 429 in `hermes auth list`) — deliberately last. |

Not wired, with reasons (recorded so a rebuild doesn't "fix" them):

- **DeepSeek** — planned in HIMMEL-278 but no `DEEPSEEK_API_KEY` on the
  machine yet. Add `- provider: deepseek` + model when a key lands.
- **Ollama local** — Ollama is not installed on this machine (PATH stub
  only). If installed later: provider `custom` with
  `base_url: http://localhost:11434/v1`, no key.
- **gemini-cli / OAuth routes** — VOIDED by operator (HIMMEL-277);
  do not re-add.

`providers: {}` stays empty on purpose: all three routes are built-in
provider names, so endpoint + key-env resolution comes from hermes's
internal registry; a `providers:` entry is only needed for custom
endpoints or per-provider timeout overrides.

Fallback semantics (hermes docs `fallback-providers.md`): entries tried
in list order on 429-after-retries / 5xx-after-retries / immediate
401/403/404; fallback is per-turn — the primary is retried on each new
user message.

## Verify after a rebuild (zero inference cost)

```
hermes fallback list   # chain resolves: nvidia primary + 2 fallbacks
hermes auth list       # one credential per provider, sourced from env
hermes doctor          # API Connectivity: ✓ OpenRouter ✓ NVIDIA NIM ✓ gemini
```

Then one paid-nothing smoke: `hermes --cli -z "Reply with exactly: OK"`
(NIM free credits). The hermes gateway (Telegram bot) reads config at
start — restart it (`hermes gateway restart`, when no session is
running) to pick up route changes.

Wiring verified 2026-06-12: all three connectivity probes green;
config backup at `config.yaml.bak.20260612_overnight`.
