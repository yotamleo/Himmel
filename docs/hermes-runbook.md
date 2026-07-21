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
| **`himmel_agent` main tier** | A full-control orchestrator (Codex / GPT-5.5) carrying `parity_guard` instead of the junior fence — does real engineering / research / vault work. | **Alpha - guard parity now tests green; still treat as experimental until more live mileage.** |

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

The full-control orchestrator tier is **experimental** — its `parity_guard`
tests green for the guard-parity set, but it still has less live mileage than
the Claude/himmel path. It is not required for the CR-critic or junior tiers. If you want it,
provision the additive profile per [Profiles](#profiles-your-default--himmels-himmel_agent-main-tier-himmel-557)
below.

## Install layout (Windows)

- Install root: `%LOCALAPPDATA%\hermes\` — config.yaml, SOUL.md,
  `agent-hooks/luna_vault_guard.py` (fail-closed vault write fence),
  `.env` (API keys), venv at `hermes-agent\venv\Scripts\hermes`.
- Hermes reads its OWN `.env` (`%LOCALAPPDATA%\hermes\.env`) — shell
  env and himmel's repo-root `.env` are irrelevant to it.

## Profiles: your `default` + himmel's `himmel_agent` main tier (HIMMEL-557)

> **Alpha.** The `himmel_agent` main tier is **experimental**. Its
> `parity_guard` now tests green for the guard-parity set in
> [`docs/internals/lane-parity.md`](internals/lane-parity.md), but it still has
> less live mileage than the Claude/himmel path. The working, production hermes
> lanes today are the **CR critic** and **junior** tiers (top of this doc). Use
> `himmel_agent` knowingly.

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
# provision (or refresh) the himmel_agent profile AND wire parity_guard into
# EVERY hermes profile by default (universal guard, HIMMEL-744) — additive,
# idempotent, non-clobbering (swaps a luna_vault_guard, or ADDS the guard where
# a profile has none, preserving any other hooks it carries):
bash scripts/hermes/install-himmel-profile.sh
# narrow the universal pass to named profiles only:
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

## Free-tier SOUL tuning (559)

Himmel ships one tuned free-tier identity as an **opt-in asset**:
[`scripts/hermes/assets/free-tier.SOUL.md`](../scripts/hermes/assets/free-tier.SOUL.md).
It is tuned for the open-model free anchor (read live from
`scripts/cr/critics.json` — the anchor model drifts as free quotas
exhaust; do not hardcode it here) — rigid JSON / format-obedience
scaffolding, a declared `Context budget:` line, and fewer hedges. Open models
drift from the output contract and over-report, so the free SOUL compensates
where the premium GPT-anatomy prompt would instead rely on contradiction
resolution. It is **identity-only** — project specifics stay in each context's
`AGENTS.md` / `CLAUDE.md` / vault `_CLAUDE.md`, never in the SOUL.

**How you apply it (operator action, not himmel's):** copy the asset into the
`SOUL.md` of your **existing read-only junior profile** (the `default` /
`luna_vault_guard` profile from the tier-coupling section above):

```bash
# <home> = your hermes config home (this machine: %LOCALAPPDATA%\hermes)
cp scripts/hermes/assets/free-tier.SOUL.md <home>/profiles/<your-junior-profile>/SOUL.md
hermes gateway restart   # pick up the new identity, when no session is running
```

Himmel **never** overwrites your `default` profile SOUL for you, and this path
ships **no `install-himmel-profile.sh` edit**. The provisioner knows
`wire_parity_guard set` / `ensure` / `swap` — all of which wire the
write-allowed `parity_guard`; it has no supported way to wire a READ-ONLY
`luna_vault_guard` fence onto a fresh profile (and `luna_vault_guard` is a
hermes-side artifact himmel does not ship), so a himmel-created `--free-tier`
profile could not be safely fenced.
Applying the tuned SOUL to your **existing** read-only junior keeps the
tier-coupling invariant intact — free model stays read-only — without himmel
wiring a fence it cannot ship.

The **premium half** of 559 is the `himmel_agent` SOUL
([`scripts/hermes/assets/himmel-agent.SOUL.md`](../scripts/hermes/assets/himmel-agent.SOUL.md)),
which carries the GPT-anatomy markers: an explicit **Precedence ladder** +
`<spec>` tags. The free SOUL deliberately carries the JSON-obedience markers
instead (`Context budget:` + a fenced format-contract block) — the two differ
on those named markers by design, asserted by
[`scripts/hermes/test-soul-markers.sh`](../scripts/hermes/test-soul-markers.sh)
(T11).

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

### Context-window budgeting for multi-model lanes (2026-07-07)

Do **not** assume a model slug's marketing maximum applies on every backend.
Hermes budgets against the **provider-enforced** context window, and that value
can differ for the same slug across providers. Upstream issue
[`NousResearch/hermes-agent#27918`](https://github.com/NousResearch/hermes-agent/issues/27918)
closed the Codex/GPT-5.5 "should be 1M" report as **not a bug**: live
`openai-codex` reports and enforces `gpt-5.5` at `272000` tokens, while direct
OpenAI API `gpt-5.5` can resolve around `1050000`. Pinning Codex to 1M would
over-budget prompts that the Codex backend rejects.

Operational rule: every lane that can be triggered as its own model/provider
must carry its own verified maximum context window, not inherit the parent
lane's expectation.

- `himmel_agent` main tier: `openai-codex` + `gpt-5.5` is currently a **272K
  Codex window**. This is expected even though the direct OpenAI API slug is
  larger.
- GLM / Z.ai lanes: request the explicit long-context model id
  `glm-5.2[1m]` on Claude Code-compatible launchers. Bare `glm-5.2` can run
  capped below the advertised maximum, so it is not the desired full-control
  lane.
- Hermes `/model` and delegation switches recalculate context for the new
  provider/model. A top-level `model.context_length` override applies to that
  profile's active model; it is not a generic guarantee for aliases or sibling
  external launchers. For custom endpoints that need explicit per-model windows,
  prefer `custom_providers[].models.<model>.context_length` in Hermes config.

Verification snippets (zero/near-zero inference):

```bash
hermes --profile himmel_agent profile show himmel_agent
"<hermes-venv-python>" - <<'PY'
from agent.model_metadata import get_model_context_length
print(get_model_context_length('gpt-5.5', provider='openai-codex',
    base_url='https://chatgpt.com/backend-api/codex', api_key=''))
print(get_model_context_length('glm-5.2[1m]', provider='custom',
    base_url='https://api.z.ai/api/anthropic', api_key=''))
PY
```

If a context number changes, update this runbook and any lane launcher/config
that budgets or summarizes context. Do not "fix" a lower provider-enforced
window by hardcoding a larger one unless a live request proves the larger window
is accepted on that exact backend.

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

## Alibaba (Model Studio) free lane — activation + wiring (2026-07-06)

A free **parallel** implementation/critic lane on Alibaba Cloud Model Studio
(international, Singapore `ap-southeast-1`) running qwen models over the
OpenAI-compatible endpoint. Codex stays hermes's **main/default** provider —
this lane never replaces it; it adds free capacity alongside. The free tier
is a PAYG 90-day trial with **per-model** free quotas (not every model gets
1M tokens), so enable **stop-on-exhaust** when you activate.

### Activation (console-side, one-time)

A `403 AccessDenied.Unpurchased` from the API means **the Model Studio
service has not been activated** — not an identity, key, URL, or region
problem. Fix it in the Singapore-pinned console
(`https://modelstudio.console.alibabacloud.com/ap-southeast-1`):

1. Accept the service agreement — this auto-activates the service **and**
   grants the 90-day free quota (Singapore only).
2. Batch-enable the models you alias below.
3. Set **stop-on-exhaust** on each.

After that, the **same key + URL** that returned 403 returns HTTP 200.

### Provider (hermes built-in)

hermes ships an `alibaba-coding-plan` provider — no new provider code needed.
Key env vars (read in order): `ALIBABA_CODING_PLAN_API_KEY`, then
`DASHSCOPE_API_KEY`; base override: `ALIBABA_CODING_PLAN_BASE_URL` (set in
`%LOCALAPPDATA%/hermes/.env`).

> **Workspace-endpoint caveat.** The provider's built-in default base
> `https://coding-intl.dashscope.aliyuncs.com/v1` does **not** work with a
> workspace MaaS key (401). Only the **workspace** endpoint works, and it
> **must** include the `/compatible-mode/v1` path:
> `https://ws-<your-workspace-id>.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1`.
> The China-region `dashscope.aliyuncs.com` endpoint 401s on an international
> key.

### Routing (`model_aliases` is the lever)

hermes's `-z` one-shot path **auto-detects** the provider from `-m` and
**overrides** the config default; a bare model name like `qwen3-coder-plus`
is **not** auto-detected and would fall through to the default (codex) and
fail. There is **no** provider-qualified `-m` syntax. `model_aliases:` in
`%LOCALAPPDATA%/hermes/config.yaml` is checked **first**, before auto-detect
— so wire aliases as a **top-level** block (do **not** touch
`model.default` / `model.provider`):

```yaml
model_aliases:
  qwen3-coder-plus:
    model: qwen3-coder-plus
    provider: alibaba-coding-plan
    base_url: https://ws-<your-workspace-id>.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1
```

Add one alias per tier you want reachable. Claude-tier parity map:

| Claude tier | qwen model |
|-------------|------------|
| haiku | `qwen-flash` |
| sonnet | `qwen-plus` |
| opus | `qwen3-max` / `qwen3.7-max` |
| thinking / fable | `qwq-plus` / `qwen3-235b-a22b-thinking` |
| CR critic | anchor row in `scripts/cr/critics.json` (per-account quota state — e.g. exhausted models swapped out — lives in the gitignored `scripts/cr/critics.local.json` overlay, HIMMEL-727) |

### Validate THROUGH hermes

Don't just probe the raw endpoint — run a one-shot through hermes so the
alias + provider resolution is exercised end to end:

```bash
bash scripts/hermes/invoke.sh --model qwen3-coder-plus "say PONG"
```

Expect `PONG`. If it errors on codex, the alias didn't take — check the block
is top-level and the key is in `.env`. Do **not** use the `-p` profile route:
one-shot auto-detect on `-m` re-overrides a profile's provider.

### Consumers

The CR panel's free critic is anchored via this lane to the model in
the registry's anchor row (HIMMEL-725 introduced the lane). The shipped
`scripts/cr/critics.json` carries UNIVERSAL defaults; when YOUR account's
free quotas exhaust, record the swap in the gitignored
`scripts/cr/critics.local.json` overlay (auto-picked-up, HIMMEL-727) —
do not edit the shipped registry for account state (HIMMEL-838 did, reverted).
Free-quota exhaustion is why a quota guard is tracked
separately — it needs a dynamic API pull (console screenshots are not
automatable).

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
