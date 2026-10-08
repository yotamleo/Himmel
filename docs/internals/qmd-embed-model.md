# qmd embed model — a per-machine option (HIMMEL-4232)

qmd embeds documents with **embeddinggemma-300M** by default. **Qwen3-Embedding-0.6B**
retrieves better on our golden set (HIMMEL-4184), but it is about twice the size and
needs a GPU to build a whole index in reasonable time. So the model is a
**per-machine option**: gemma stays the default, and a machine opts into Qwen with
`scripts/luna/qmd-embed-model.sh`.

| Model | URI | Dimensions |
|---|---|---|
| gemma (default) | `hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf` | 768 |
| qwen | `hf:Qwen/Qwen3-Embedding-0.6B-GGUF/Qwen3-Embedding-0.6B-Q8_0.gguf` | 1024 |

## The trap: a model that does not match the index

qmd records the model **per vector** (`content_vectors.model`) and the vector
dimension **per index** (`vectors_vec`, `float[N]`). Its search path never checks
which model made a vector. So when the configured model differs from the index's:

- with a different dimension (gemma 768 to Qwen 1024), embedding fails with
  "Embedding dimension mismatch", and vector queries error;
- with the same dimension, vector search **silently returns garbage**: the query
  is embedded in one space and compared with vectors from another.

Three checks catch this. Each one compares the configured model with every model
in the index, whatever the dimensions:

| Where | On a mismatch |
|---|---|
| `qmd-embed-model.sh check` | exit 3, with the configured model, the index's models, the dimension and the fix |
| `qmd-reindex.sh` (and so the qmd cadence) | refuses before `qmd update` (exit 7); an unreadable index only WARNs |
| `himmel-doctor` row `C49-qmd-embed-model` | WARN |

## Capability classes

`qmd-embed-model.sh capability` classifies the host. Only Qwen is gated; gemma
is allowed everywhere.

| Class | Rule | What the host can do with Qwen |
|---|---|---|
| `build` | NVIDIA GPU with at least 4 GiB of VRAM, or Apple Silicon | embed a whole corpus (about 2 h for ours on an RTX 4090) |
| `query` | no such GPU, at least 4 GiB of RAM | embed one short query per search on CPU, so it can search a Qwen index shipped to it, but should not build one |
| `none` | under 4 GiB of RAM | nothing; `set qwen` refuses without `--force` |

The gate only runs in `set`. `reembed`, `swap`, `qmd-reindex.sh`, the cadence and
the doctor never call it, so an incremental `qmd embed` (new and changed
documents only) keeps working on a `query`-class host.

### Measured cost (HIMMEL-4232, 2026-10-04)

These are CPU-only figures (`QMD_FORCE_CPU=1`). They come from a 32-thread x86 host
under load (load average about 22, nice 19). Queries are synthetic, and the
document chunks are about 900 tokens.

| Model | Query embed p50 / p90 | Document chunks per minute | Peak RSS |
|---|---|---|---|
| embeddinggemma-300M | 12 / 18 ms | about 370 | 2.8 GB |
| Qwen3-Embedding-0.6B | 59 / 65 ms | about 67 | 4.2 GB |

On an RTX 4090, a full build of about 140k chunks ran at roughly 1,300 to 2,000
chunks per minute for either model, at nice 19. The bottleneck was the host side,
not the GPU. A query-class host can afford Qwen's per-query cost. At its CPU rate,
a daily delta of a few hundred chunks takes minutes, but a full corpus takes days.

### Measured quality (HIMMEL-4184 harness, 38-query golden set)

The table compares Qwen against gemma on the same four-collection corpus. It
gives MRR, with hit@1 and hit@5 in brackets. Unscoped means a search over every
collection; scoped means a search limited to the golden collections.

| Mode | gemma unscoped | Qwen unscoped | gemma scoped | Qwen scoped |
|---|---|---|---|---|
| vec | 0.256 (0.18 / 0.34) | 0.515 (0.42 / 0.66) | 0.432 (0.32 / 0.61) | 0.726 (0.63 / 0.84) |
| hybrid | 0.575 (0.37 / 0.87) | 0.701 (0.58 / 0.87) | 0.831 (0.76 / 0.89) | 0.894 (0.84 / 0.95) |
| hybrid + rerank | 0.526 (0.37 / 0.79) | 0.712 (0.58 / 0.92) | 0.820 (0.76 / 0.89) | 0.891 (0.84 / 0.95) |

Lexical search scores the same under both models: 0.588 unscoped, 0.781 scoped.
Qwen wins every vector-bearing cell. The reranker lowers gemma's unscoped score,
and it is neutral (±0.01 MRR) under Qwen. It adds about 2.2 s at p50 unscoped,
and the HIMMEL-4216 rerank timeout never fired.

## Switching a machine (copy, then swap)

Never re-embed the live index in place: `qmd embed --force` drops every vector
first, so search is broken for the whole embed (hours). Build a copy instead,
then swap it in. `reembed` consistently backs up the whole local index with\nSQLite's `.backup`; receiver-only `--collections` filtering was retired with\nthe ship transport (HIMMEL-4896).

```bash
# 0. Is this host build-capable?
bash scripts/luna/qmd-embed-model.sh capability

# 1. Build a re-embedded COPY beside the live index. The live index and the
#    config are not touched; the embed runs with a scratch config dir.
bash scripts/luna/qmd-embed-model.sh reembed --model qwen

# 2. Stop the qmd daemon (the swap refuses while one runs), then swap.
qmd mcp stop
bash scripts/luna/qmd-embed-model.sh swap --copy ~/.cache/qmd/index.reembed-qwen.sqlite

# 3. Verify.
bash scripts/luna/qmd-embed-model.sh check
```

`swap` refuses unless the copy sits in the same directory as the live index, holds
exactly one model, no qmd daemon, update or embed is running, and no write-ahead log is pending. It
keeps the old index as `index.sqlite.pre-swap-<timestamp>` and the old config as
`index.yml.pre-swap-<timestamp>`, and prints the rollback commands if its
post-swap check fails. Delete the `.pre-swap-` files once you are satisfied.

Switching back to gemma is the same procedure with `--model gemma`.

`set gemma|qwen` alone only writes `models.embed` into `~/.config/qmd/index.yml`.
It refuses when the index holds another model, because the result would be a
mismatch; `--force` overrides the guard, leaving the index mismatched until a
matching re-embedded copy is swapped in.

## Egress

Qwen embeds locally, like gemma: the egress matrix
(`scripts/guardrails/egress-matrix.json`) classes it as provider `local-ollama`,
purpose `embedding`. That is allowed for the luna and handover-state data
classes and conditional (per-run opt-in) for salus, exactly as for gemma. No new
transport is involved.
