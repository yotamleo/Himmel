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

## Corpus resolution (shared primitives, not new ones)

Corpus membership resolves through the SAME primitives the live guards
already use: `.salus` root markers and the
`~/.config/claude-glm/{phi-roots,egress-denylist}` list files
(`scripts/telegram/glm-guard.ts`, `scripts/hermes/assets/parity_guard.py`),
plus vault/state roots from env or config — never hardcoded absolute paths.
The matrix defines *policy*; membership resolution stays with the guards.

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
