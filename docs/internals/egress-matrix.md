# Data-egress matrix (HIMMEL-766)

**Source of truth: [`scripts/guardrails/egress-matrix.json`](../../scripts/guardrails/egress-matrix.json).**
One owned corpus × provider × purpose policy that every egress-enforcing
surface reads, replacing per-tool hard-coded policy. It exists because four
ad-hoc egress decisions (ollama-only → DeepSeek override → GLM-Clippings
exception → Alibaba embeddings) accumulated across four documents with no
single owner, producing a live contradiction (the HIMMEL-621/622 fence as
specced denied Alibaba for luna content; HIMMEL-765 sends luna content to
Alibaba for embeddings).

## Semantics

- **Evaluation:** first-match-wins over `rules`, `*` wildcards, then
  `default` (which is `deny` — fail-closed).
- **Verdicts:** `allow` · `allow+log` (must append a ledger line) ·
  `conditional` (allow only while the rule's `condition` holds) · `deny` ·
  `pending-operator` (**evaluates as deny**; a named operator decision flips
  the cell via a one-line PR on the JSON).
- **Reference implementation:** the `evaluate()` function in
  [`scripts/guardrails/test-egress-matrix.mjs`](../../scripts/guardrails/test-egress-matrix.mjs)
  — consumers in other languages copy those semantics.
- **Load-bearing nuance:** embedding, rerank, and vision-embedding send FULL
  content (text or images) to the provider. An "embedding lane" is content
  egress, not metadata egress, and is gated accordingly.
- **enrichment (HIMMEL-833)** is content egress like extraction — full note
  bodies leave the machine, plus the vault-wide top-200 tag vocabulary (tag
  names only, derived from all vault markdown) sent with each request as the
  allowed-tags list; its `luna-personal × deepseek` cell was **ratified
  2026-07-10** (operator, HIMMEL-833): `allow+log` (the ledger obligation
  survives ratification — never plain `allow`).
- **`luna-personal × zai-glm × extraction`** was **ratified 2026-07-17**
  (operator, HIMMEL-1122): `allow+log`. **This WIDENS the permitted provider
  set** — full luna non-Clippings note bodies may now leave the machine to a
  second, additional vendor (Z.ai) that could not receive them before. What it
  does *not* change is the corpus, purpose, region (CN), or content scope: those
  are identical to the 2026-07-05 DeepSeek extraction override it sits beside, so
  the *kind* of exposure is unchanged even though the *number of vendors holding
  it* goes from one to two. Both facts matter to a privacy review; neither
  cancels the other. Ratified because a measured
  A/B on an identical corpus put glm-5.2 ahead of the incumbent on every axis
  (link recall 63–79% vs DeepSeek's 26%, file coverage 100% vs 95%) at
  flat-rate Coding-Plan cost, against $3.14 per full-vault DeepSeek run — the
  vault was paying for the weaker backend purely because the matrix had no GLM
  cell. Scope is deliberately narrow:
  - `luna-personal × zai-glm × inference` stays **deny** — extraction only.
  - `salus × * × *` stays **deny, hard** — untouched, and no override can flip it.
  - **Not a default.** `refresh-graph-map.sh` keeps `BACKEND=claude-cli`
    (HIMMEL-1049, the claude-only adopter story). GLM is a per-run opt-in for an
    operator who has a Coding Plan; an adopter without one is never expected to
    have it.

## Corpus resolution (shared primitives, not new ones)

Corpus membership resolves through the SAME primitives the live guards
already use: `.salus` root markers and the
`~/.config/claude-glm/{phi-roots,egress-denylist}` list files
(`scripts/telegram/glm-guard.ts`, `scripts/hermes/assets/parity_guard.py`),
plus vault/state roots from env or config — never hardcoded absolute paths.
The matrix defines *policy*; membership resolution stays with the guards.

## Staged-copy corpus declaration (`.graphify-corpus`, HIMMEL-778)

The 621/622 plan runs extraction on scratchpad **copies** of corpus content,
never live vaults — but a copy classifies as nothing, so an undeclared copy is
denied unconditionally. A `.graphify-corpus` marker file at or above the target
declares the copy's **origin** corpus: its first line, trimmed, must be one of
`salus` · `luna-personal` · `luna-clippings` · `handover-state` · `himmel-code`
(anything else, or an unreadable marker, is a fail-closed **deny**). Precedence
is strict: `.salus`/PHI roots and the real luna/handover/himmel roots BOTH beat
the marker (a marker inside a real vault can never relax classification); the
marker is consulted **only** for otherwise-unclassifiable paths. Because a copy
is origin-blind, mis-declaration is possible and accepted — the load-bearing PHI
guard stays `parity_guard` / the file-tool fence, not this command-text guard.
As a backstop, any marker-derived invocation **always** appends a ledger line
on every allow-family verdict (`allow` / `allow+log` / `conditional` — a deny
already blocks the egress), carrying `"declared":true`, even on a plain `allow`
cell, so a mis-declared marker cannot also dodge the audit trail. The marker is
consulted **only when a luna root is configured** (`LUNA_VAULT` /
`LUNA_VAULT_PATH` non-empty): the real-root-beats-marker guarantee depends on
the fence seeing the real roots, so with no luna root the marker is inert and
staged copies stay unclassifiable → deny. `graphify-fence.sh` also normalizes
MSYS-form paths (`/c/…` → `c:/…`) for its **lexical** root comparisons (the
filesystem marker walks use the original path form) so Windows Git-Bash
candidates and the Bash tool's always-MSYS `$PWD` match the drive-lettered
corpus roots.

### `.graphify-backend` file-declared backend (HIMMEL-881)

`graphify update` (and other LLM-free subcommands) take no `--backend` on the
CLI, so a non-himmel corpus needs a declared provider from elsewhere to
satisfy the fence's no-backend policy. `GRAPHIFY_DECLARED_BACKEND` (HIMMEL-779)
covers this, but it is launching-shell-only by design — a per-call `VAR=x`
prefix or an in-session `export` never reaches the PreToolUse hook process —
so an in-session or headless `graphify update` run could never satisfy it
without a session restart. A `.graphify-backend` file in the **exact same
directory** as the `.graphify-corpus` marker (not any other ancestor
directory) is a second, per-run way to supply the same declaration:
single-line, trimmed, non-empty, safe-charset (`[A-Za-z0-9._-]+`) backend
name; empty, multiline, unreadable, or invalid content is a fail-closed
**deny**, same as an invalid `.graphify-corpus` marker. Precedence:
`GRAPHIFY_DECLARED_BACKEND` wins when set; the file is consulted only when the
env var is unset. Scoped identically to the env var (LLM-free subcommand +
non-himmel corpus only). The file's value flows through the same matrix eval
as a real `--backend` token — not a bypass — and any declared-backend
substitution (env or file) **always** leaves a ledger line on every
allow-family verdict — even a plain `allow` matrix cell on a real
(non-marker) root — carrying a `declared_backend_source` field (`"env"` or
`"file"`) so audits can tell the two paths apart and no declaration-reached
run goes unrecorded. **All-dirs-must-agree:**
when one invocation carries multiple marker-derived targets, every
`.graphify-corpus` marker directory is consulted (not only the
rank-winning target's — equal-rank argument ordering must not pick which
declaration gets read): each dir must carry a valid `.graphify-backend` and
all files must declare the same value; a missing, unreadable, or invalid
file in any dir, or two differing values, is a fail-closed **deny**
regardless of argument order. **Staged-only:** file declarations are honored
only when *every* classified target in the invocation is a marker-declared
staged copy — any target that classifies via a real configured root disables
the file path outright (a staged copy's declaration must not vouch for a
real vault path listed beside it); mixed staged+real invocations need
`--backend` or the launching-shell env var.

## Consumers

| Surface | What it reads |
|---|---|
| `scripts/guardrails/graphify-fence.sh` (HIMMEL-621 Phase G-F) | maps graphify `--backend` → provider, target path → corpus, purpose = `extraction`; verdict via `scripts/guardrails/egress-matrix-eval.mjs` (the reference semantics as a CLI); wired as the narrow `block-graphify-egress` PreToolUse hook |
| `parity_guard.py` PHI/egress fence (HIMMEL-695) | the `salus` row (hard deny) — already enforced; the matrix documents the policy it implements |
| `glm-guard.ts` | same `salus`/denylist row |
| HIMMEL-765 embedding/rerank pilot client | the `alibaba` × `embedding`/`rerank`/`vision-embedding` cells (all five currently `pending-operator` = deny) |

## Invariants (enforced by the test)

- `default` is `deny`; salus × any-cloud × anything is a **hard** deny with
  no recordable override; google-gemini is denied everywhere (keys stay
  unset); `pending-operator` cells evaluate as deny; the DeepSeek override
  covers **extraction only**; no bulk pipelines over handover-state.
- Run: `node scripts/guardrails/test-egress-matrix.mjs`.

## Changing the matrix

Every change is a PR through the normal CR flow — the matrix is
enforcement-path configuration. In particular the planned self-evolving
loop (HIMMEL-767 family) is structurally denied writes here: a widened cell
must always be a human-merged diff. Flipping a `pending-operator` cell:
change its `verdict` (typically to `allow+log`), delete `decision_needed`,
note the operator decision + date in `why`, update the test's expectations,
and cite the ratifying ticket in the commit.

## Open operator decisions carried in the matrix

- **HIMMEL-765 (Alibaba embedding/rerank):** five `pending-operator` cells
  — `luna-clippings` × embedding/rerank/vision-embedding (recommended first
  pilot corpus: clipped public web content, lowest sensitivity) and
  `luna-personal` × embedding/rerank (the contradiction cell from the
  2026-07-08 Fable design review; personal-content egress to a new provider
  is an operator call). Until flipped, the 765 pilot is gated.
