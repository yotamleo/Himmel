#!/usr/bin/env python3
"""scripts/eval/qmd-quality/ledger-row.py - write one qmd-quality eval-runs row
with bootstrap CIs, per-query cases and the config stamp (HIMMEL-4650).

  ledger-row.py <out-dir> --golden G --modes M [--scope S] [--candidate-limit C]
                [--embed-model E] [--rerank-model R] [--index I] [--run-id ID]
                [--status S] [--meta-json J] [--ledger PATH]

Builds the row with eval_runs.qmd_quality_row (scripts/eval/lib/eval_runs.py),
then fills what that adapter does not: ci / ci_level / ci_method from
<out-dir>/ci.json and cases from <out-dir>/cases.json (both written by
score.ts --ci-out / --cases-out), and stamps meta with the index identity
(sha256 + size of --index) and the rerank model actually used (the default
when QMD_RERANK_MODEL was unset and the modes rerank). A ledger failure warns
and exits 0, as eval_runs.append_safe does: it never changes the eval's result.
Exit: 0 written or warned, 2 refused input.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

DEFAULT_RERANK = "hf:ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/qwen3-reranker-0.6b-q8_0.gguf"
RERANKING = ("hybrid-rerank", "hybrid-hyde", "auto")


def _json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        return None


def build_row(out_dir, golden, modes, scope="all", candidate_limit=40, embed_model=None,
              rerank_model=None, index=None, status="ok", meta=None, run_id=None):
    if not rerank_model and any(m in RERANKING for m in modes.split(",")):
        rerank_model = DEFAULT_RERANK
    row = eval_runs.qmd_quality_row(out_dir, golden, modes, scope, candidate_limit, embed_model,
                                    rerank_model, index, status, meta)
    ci = _json(os.path.join(out_dir, "ci.json"))
    if ci:
        row["ci"] = {k: v for k, v in ci.items() if k in row["metrics"]}
        row["ci_level"] = 0.95
        row["ci_method"] = "bootstrap"
    cases = _json(os.path.join(out_dir, "cases.json"))
    if cases:
        row["cases"] = cases
    if index and os.path.isfile(index):
        row["meta"]["index_sha256"] = eval_runs.file_sha256(index)
        row["meta"]["index_bytes"] = os.path.getsize(index)
    if run_id:
        row["run_id"] = run_id
    return row


def main(argv=None):
    ap = argparse.ArgumentParser(prog="ledger-row.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("out_dir")
    ap.add_argument("--golden", required=True)
    ap.add_argument("--modes", required=True)
    ap.add_argument("--scope", default="all")
    ap.add_argument("--candidate-limit", type=int, default=40)
    ap.add_argument("--embed-model", default="")
    ap.add_argument("--rerank-model", default="")
    ap.add_argument("--index", default="")
    ap.add_argument("--run-id")
    ap.add_argument("--status", default="ok")
    ap.add_argument("--meta-json", default="{}")
    ap.add_argument("--ledger")
    args = ap.parse_args(argv)
    try:
        meta = json.loads(args.meta_json)
        row = build_row(args.out_dir, args.golden, args.modes, args.scope, args.candidate_limit,
                        args.embed_model, args.rerank_model, args.index, args.status, meta, args.run_id)
    except (OSError, ValueError) as e:
        print("ledger-row: refused: %s" % e, file=sys.stderr)
        return 2
    eval_runs.append_safe(row, args.ledger, who="ledger-row")
    return 0


if __name__ == "__main__":
    sys.exit(main())
