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
| `himmel-doctor` row `C48-qmd-embed-model` | WARN |

## Capability classes

`qmd-embed-model.sh capability` classifies the host. Only Qwen is gated; gemma
is allowed everywhere.

| Class | Rule | What the host can do with Qwen |
|---|---|---|
| `build` | NVIDIA GPU with at least 4 GiB of VRAM, or Apple Silicon | embed a whole corpus (about 2 h for ours on an RTX 4090) |
| `query` | no such GPU, at least 4 GiB of RAM | embed one short query per search on CPU, so it can search a Qwen index shipped to it, but should not build one |
| `none` | under 4 GiB of RAM | nothing; `set qwen` refuses without `--force` |

## Switching a machine (copy, then swap)

Never re-embed the live index in place: `qmd embed --force` drops every vector
first, so search is broken for the whole embed (hours). Build a copy instead,
then swap it in.

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
exactly one model, no daemon is running, and no write-ahead log is pending. It
keeps the old index as `index.sqlite.pre-swap-<timestamp>` and the old config as
`index.yml.pre-swap-<timestamp>`, and prints the rollback commands if its
post-swap check fails. Delete the `.pre-swap-` files once you are satisfied.

Switching back to gemma is the same procedure with `--model gemma`.

`set gemma|qwen` alone only writes `models.embed` into `~/.config/qmd/index.yml`.
It refuses when the index holds another model, because the result would be a
mismatch; `--force` overrides that for a receiving station (below).

## Shared indexes: ship-index.sh

A station that is too slow to build its own index receives one from a builder
over ssh (`scripts/luna/ship-index.sh`). That transport is unchanged: ssh to the
operator's own hosts only, and only the collections the receiver configures.

The artifact's embed model must equal the receiver's configured model, which
ship-index reads from `qmd status` on the receiver. On a mismatch, or when the
receiver's model cannot be read, the ship refuses before uploading anything
(exit 9) and names the ways out in one line:

- **switch the receiver** to the artifact's model, if it is query-capable (at
  least 4 GiB of RAM): on the receiver, `bash scripts/luna/qmd-embed-model.sh set
  <model> --force`, then ship again;
- **ship lexical-only**: `bash scripts/luna/ship-index.sh --lexical-only` strips
  every vector from the artifact (`prepare-ship-index.mjs --strip-vectors`). The
  receiver gets BM25 search only, until it embeds with its own model or a
  matching index is shipped. It is never silent: the ship says `LEXICAL-ONLY`,
  and the receiver's post-swap verify expects zero vectors.

`prepare-ship-index.mjs` also refuses an artifact whose vectors come from more
than one model.

## Egress

Qwen embeds locally, like gemma: the egress matrix
(`scripts/guardrails/egress-matrix.json`) classes it as provider `local-ollama`,
purpose `embedding`. That is allowed for the luna and handover-state data
classes and conditional (per-run opt-in) for salus, exactly as for gemma. No new
transport is involved.
