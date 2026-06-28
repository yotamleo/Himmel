# Hermes — tiers, install, config & provider runbook (HIMMEL-278, HIMMEL-557)

Hermes ([NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent))
is a self-hosted, terminal-native AI agent with its own provider chain, profiles,
memory, and pre-tool guards. himmel drives it in **three tiers** (config lives
OUTSIDE this repo, so hermes is part of himmel even when a checkout doesn't show
it):

| Tier | What it does | Status |
|------|--------------|--------|
| **CR critic** | Independent model-family reviewer over a branch diff, wired into `/pr-check` (`scripts/cr/hermes-critic.sh` + `critic-first-pass.sh` → `scripts/hermes/invoke.sh`). Free panel default `nemotron-3-nano`; paid escalation `codex`/`gpt-5.5`. Fail-closed verdict, fail-open transport. | **Working — the production hermes lane today.** |
| **Junior** | Chore-shaped work (vault inbox capture, summaries, note-taking) on free inference, behind a read-only `luna_vault_guard` write fence. | **Working.** |
| **`himmel_agent` main tier** | A full-control orchestrator (Codex / GPT-5.5) carrying `parity_guard` instead of the junior fence — does real engineering / research / vault work. | **Alpha — guard parity is not complete; treat as experimental.** |

See the registry row in [`docs/tool-adoption/registry.md`](tool-adoption/registry.md)
(HIMMEL-272 rubric) for the adoption rationale and trust posture. The rest of this
runbook is the install + configure + provider-wiring reference — config lives
OUTSIDE this repo, so a machine rebuild reproduces it from here.

## Quick start: install & configure (new user)

himmel ships **no base-hermes installer** and never writes your hermes identity
(`SOUL.md`, `config.yaml`, `.env`, profiles). You install and configure hermes
itself with hermes's own tooling; himmel only adds the optional `himmel_agent`
profile on top. Four steps — steps 1–3 give you the working CR-critic and junior
tiers; step 4 is the alpha main tier.

### 1. Install hermes (upstream)

Use the official installer
([quickstart](https://hermes-agent.nousresearch.com/docs/getting-started/quickstart)):

```bash
# Linux / macOS / WSL2 / Termux:
curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
source ~/.bashrc            # or ~/.zshrc — reload PATH
```

```powershell
# Windows (PowerShell):
iex (irm https://hermes-agent.nousresearch.com/install.ps1)
```

This installs a `hermes` CLI and a config home (upstream default `~/.hermes/`;
this machine uses `%LOCALAPPDATA%\hermes` — see [Install layout](#install-layout-windows)
below). Hermes requires a model with **≥64K context**.

### 2. Configure hermes (provider + keys)

Hermes keeps **secrets in `<home>/.env`, everything else in `<home>/config.yaml`**
([config docs](https://hermes-agent.nousresearch.com/docs/user-guide/configuration));
`hermes config set KEY VAL` auto-routes (API keys → `.env`, the rest →
`config.yaml`). Pick one path:

```bash
hermes setup --portal       # fastest: one OAuth → Nous provider + Tool Gateway
hermes model                # or: interactive provider/model picker
# or wire a key + model by hand (secrets land in .env automatically):
hermes config set OPENROUTER_API_KEY sk-or-...
hermes config set model.default <provider/model>
```

The `model:` block in `config.yaml` is `{default, provider, base_url}`, with an
ordered `fallback_providers:` list for resilience — himmel's live chain and
fallback policy are in [Provider routes](#provider-routes-wired-2026-06-12-himmel-278)
below. For himmel's **CR paid-escalation** lane (`codex` / `gpt-5.5`), log in to
Codex once:

```bash
hermes auth                 # choose Codex (ChatGPT) — saved to <home>/auth.json
```

Verify with `hermes doctor` (provider connectivity) and `hermes config check`
(missing settings after an upgrade).

### 3. Point himmel at your hermes

himmel's hermes scripts resolve the install **and default to Windows paths**, so
on macOS/Linux (or any non-default location) export both vars in the shell that
launches Claude:

- **`HERMES_HOME`** — install root; used by `/himmel-update` and the profile
  provisioner. Fallback: `%LOCALAPPDATA%\hermes` → `~/.local/share/hermes`.
- **`HERMES_PY`** — the venv python; used by the CR lane (`scripts/hermes/invoke.sh`).
  Fallback: `<home>/hermes-agent/venv/{Scripts/python.exe,bin/python}`.

```bash
export HERMES_HOME="$HOME/.hermes"
export HERMES_PY="$HERMES_HOME/hermes-agent/venv/bin/python"
```

Smoke-test the CR chokepoint (spends your provider's free credits, not paid
budget):

```bash
bash scripts/hermes/invoke.sh "Reply with exactly: OK"
```

A clean `OK` means `/pr-check`'s hermes critic is wired. That is the whole
working setup — the CR-critic and junior tiers need nothing further.

### 4. (Optional, alpha) add the `himmel_agent` main tier

The full-control orchestrator tier is **experimental** — its guard parity isn't
complete. It is not required for the CR-critic or junior tiers. If you want it,
provision the additive profile per [Profiles](#profiles-your-default--himmels-himmel_agent-main-tier-himmel-557)
below.

## Install layout (Windows)

- Install root: `%LOCALAPPDATA%\hermes\` — config.yaml, SOUL.md,
  `agent-hooks/luna_vault_guard.py` (fail-closed vault write fence),
  `.env` (API keys), venv at `hermes-agent\venv\Scripts\hermes`.
- Hermes reads its OWN `.env` (`%LOCALAPPDATA%\hermes\.env`) — shell
  env and himmel's repo-root `.env` are irrelevant to it.

## Profiles: your `default` + himmel's `himmel_agent` main tier (HIMMEL-557)

> **Alpha.** The `himmel_agent` main tier is **experimental** — its
> `parity_guard` is not yet at full parity with what Claude/himmel enforce, so
> running a free-tier-capable agent with write/git/PR control still carries
> risk. The working, production hermes lanes today are the **CR critic** and
> **junior** tiers (top of this doc). Use `himmel_agent` only knowingly.

Hermes supports named **profiles** (`hermes profile create|list|use|show`), each
an isolated workspace at `<home>/profiles/<name>/` with its own `SOUL.md`,
`config.yaml`, `.env`, memories, and hooks. himmel uses this to add a capable
main tier **without touching your existing setup**:

- **`default`** (and any profile you already have) — **yours, never touched.**
  himmel ships **no** `SOUL.md` and has **no** hermes installer; it never
  creates, writes, or overwrites your `SOUL.md`, `config.yaml`, profiles, or
  `.env`. A fresh hermes with no `SOUL.md` uses hermes's own built-in identity.
- **`himmel_agent`** — an **additive** profile provisioned on demand by
  `scripts/hermes/install-himmel-profile.sh` (Windows: `.ps1`). It is himmel's
  main-tier orchestrator (Codex / GPT-5.5): a generalist that does real
  engineering, research, vault, and writing work — the "main puller" when
  Claude capacity is scarce. It carries `agent-hooks/parity_guard.py` instead
  of the junior `luna_vault_guard.py`: the write/repo fence and routine
  git/gh/rm blocks are dropped, but the secret-read fence, self-protection (it
  can't rewrite its own guard/config/SOUL), and catastrophic-shell blocks
  (`rm -rf`, force-push, scheduler/disk mutation, `curl|sh`) stay — parity with
  what Claude/himmel themselves enforce.

```
# provision (or refresh) the himmel_agent profile — additive, idempotent:
bash scripts/hermes/install-himmel-profile.sh
# also point selected/all OTHER profiles at parity_guard (swap-only,
# non-destructive — a profile with no luna_vault_guard hook is left untouched):
bash scripts/hermes/install-himmel-profile.sh --parity-guard=all
bash scripts/hermes/install-himmel-profile.sh --parity-guard=default,research
```

The provisioner clones your `default` (for working keys), then overwrites only
the new profile's `SOUL.md` (himmel owns that one) and wires its hook. After
running it, `hermes gateway restart` and approve the new hook once. Reach the
profile with `hermes profile use himmel_agent` (or the generated wrapper).
`SOUL.md` is identity only — project specifics (repo conventions, vault rules)
stay in each context's `AGENTS.md` / `CLAUDE.md` / vault `_CLAUDE.md`.

**Tier coupling — capability follows the model, not the other way round.**
A weaker free-tier model holding the full `parity_guard` (write code, run git,
open PRs) is risky, and the pre-tool guard can't tell at call time which model
will answer. So couple them structurally instead:

- The **`himmel_agent`** (full control) runs on the **trusted premium model
  only** (Codex / GPT-5.5) with **no free fallback** (`fallback_providers: []`).
  If the premium model is rate-limited, the main tier simply pauses — it does
  not degrade into a powerful agent backed by a free model.
- The **free tier lives on the read-only junior** (your `default` /
  `luna_vault_guard` profile) on a free model (e.g. OpenRouter
  `nvidia/nemotron-3-ultra-550b-a55b:free`, which draws no paid budget). It runs
  **in parallel** — always-available, low-stakes capacity — so when the premium
  model is down you still have a safe agent, just not a writing one.

In short: fall back to free **only** by also dropping to read-only; never pair a
free model with write/git/PR control.

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

> **SUPERSEDED 2026-06-24 — the live route is now Codex / `gpt-5.5` via the
> `openai-codex` provider** (all profiles), not the NVIDIA/OpenRouter chain
> documented below. The Nemotron block is kept for history; a full re-doc of
> the current routing is tracked. Verify the live model with
> `hermes profile list` (Model column) or `hermes model`.

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
