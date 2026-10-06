#!/usr/bin/env python3
"""scripts/eval/lane-quality/lq_stats.py - lane-quality statistics (HIMMEL-4648).

Called by run.sh; no model call, stdlib only.

  lq_stats.py summary <runs.jsonl>...
      Markdown table per lane, model and task: the mean and a bootstrap 95% CI
      of the acceptance fraction and of each judge criterion over the task's
      repeats, plus how many rows have no judge score (counted, not dropped).
  lq_stats.py calibration [--judge2-label L] [--json] [--no-ledger] <run-dir>...
      How far the judge can be trusted. Judge vs hidden acceptance: AUC and
      point-biserial r of each criterion against accept_ok, with bootstrap 95%
      CIs. Judge vs judge: with --judge2-label, quadratic weighted kappa per
      criterion against the stored second-judge results
      (<stem>.judge2.<label>.json, written by `run.sh calibration`). Appends one
      `lane-quality-calibration` row to the eval-runs ledger unless --no-ledger;
      --json prints that row instead of the report.
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))
import eval_runs  # noqa: E402

CRITERIA = eval_runs.LQ_CRITERIA
SCALE = (1, 5)  # judge-schema.json bounds


def read_rows(path):
    with open(path, encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


def stem(row):
    r = row.get("rep") or 1
    return "%s.r%d" % (row["task"], r) if r > 1 else row["task"]


def auc(scores, labels):
    """Mann-Whitney AUC: P(score of a positive > score of a negative), ties
    count half. None when either class is empty."""
    pos = [s for s, l in zip(scores, labels) if l]
    neg = [s for s, l in zip(scores, labels) if not l]
    if not pos or not neg:
        return None
    wins = sum(1.0 if p > n else 0.5 if p == n else 0.0 for p in pos for n in neg)
    return wins / (len(pos) * len(neg))


def point_biserial(scores, labels):
    """Pearson r between a score and a 0/1 label. None when either is constant."""
    n = len(scores)
    if n < 2:
        return None
    ys = [1.0 if l else 0.0 for l in labels]
    ms, my = sum(scores) / n, sum(ys) / n
    cov = sum((s - ms) * (y - my) for s, y in zip(scores, ys))
    vs = sum((s - ms) ** 2 for s in scores)
    vy = sum((y - my) ** 2 for y in ys)
    if vs == 0 or vy == 0:
        return None
    return cov / math.sqrt(vs * vy)


def weighted_kappa(a, b, lo=SCALE[0], hi=SCALE[1]):
    """Quadratic weighted Cohen's kappa of two raters on the integer scale
    lo..hi. None with no pairs, or when chance disagreement is zero (both
    raters gave one and the same score throughout)."""
    if not a or len(a) != len(b):
        return None
    k = hi - lo + 1
    n = len(a)
    obs = [[0] * k for _ in range(k)]
    for x, y in zip(a, b):
        obs[int(x) - lo][int(y) - lo] += 1
    ra = [sum(r) for r in obs]
    cb = [sum(obs[i][j] for i in range(k)) for j in range(k)]
    w = [[(i - j) ** 2 / (k - 1) ** 2 for j in range(k)] for i in range(k)]
    wo = sum(w[i][j] * obs[i][j] for i in range(k) for j in range(k))
    we = sum(w[i][j] * ra[i] * cb[j] / n for i in range(k) for j in range(k))
    if we == 0:
        return None
    return 1 - wo / we


def _cell(s):
    if s["mean"] is None:
        return "–"
    if s["ci"] is None:
        return "%.2f" % s["mean"]
    return "%.2f [%.2f, %.2f]" % (s["mean"], s["ci"]["lo"], s["ci"]["hi"])


def cmd_summary(paths):
    rows = [r for p in paths for r in read_rows(p)]
    groups = {}
    for r in rows:
        model = r.get("model") or "?"
        if r.get("effort"):
            model += " (%s)" % r["effort"]
        groups.setdefault((r.get("lane") or "?", model), []).append(r)
    print("Per task over its repeats: mean [bootstrap 95% CI]; no CI below 2 repeats. "
          "Judge means leave out the rows counted under `judge missing`.")
    print()
    print("| lane | model | task | n | accept | correctness | scope | tests | honesty | judge missing |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for (lane, model), rs in sorted(groups.items()):
        for tid, s in eval_runs.lane_quality_stats(rs).items():
            cells = [_cell(s["accept_frac"])] + [_cell(s["judge_" + c]) for c in CRITERIA]
            print("| %s | %s | %s | %d | %s | %d |" % (lane, model, tid, s["n"], " | ".join(cells), s["judge_missing"]))
    return 0


def _judge2_scores(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        return None
    s = d.get("structured_output") if isinstance(d, dict) else None
    if s is None and isinstance(d, dict) and isinstance(d.get("result"), str):
        try:
            s = json.loads(d["result"])
        except ValueError:
            s = None
    return s if isinstance(s, dict) else None


def calibration_row(dirs, judge2_label=None):
    rows = []
    for d in dirs:
        for r in read_rows(os.path.join(d, "runs.jsonl")):
            r["_dir"] = d
            rows.append(r)
    judged = [r for r in rows if isinstance(r.get("judge"), dict)]
    paired = [r for r in judged if isinstance(r.get("accept_ok"), bool)]
    metrics = {
        "n_rows": float(len(rows)),
        "judge_missing": float(len(rows) - len(judged)),
        "accept_missing": float(sum(1 for r in judged if not isinstance(r.get("accept_ok"), bool))),
    }
    ci = {}
    for c in CRITERIA:
        pairs = [(r["judge"][c], r["accept_ok"]) for r in paired if eval_runs._num(r["judge"].get(c))]
        xs, ys = [p[0] for p in pairs], [p[1] for p in pairs]
        for name, f in (("auc_", auc), ("pb_", point_biserial)):
            metrics[name + c] = f(xs, ys)
            b = eval_runs.bootstrap_ci(pairs, stat=lambda ps, f=f: f([p[0] for p in ps], [p[1] for p in ps]))
            if b and metrics[name + c] is not None:
                ci[name + c] = {"lo": b["lo"], "hi": b["hi"]}
    n_kappa = 0
    for c in CRITERIA:
        metrics["kappa_" + c] = None
    if judge2_label:
        second = {}
        for r in judged:
            s = _judge2_scores(os.path.join(r["_dir"], "%s.judge2.%s.json" % (stem(r), judge2_label)))
            if s is not None:
                second[id(r)] = s
        metrics["judge2_missing"] = float(len(judged) - len(second))
        both = [r for r in judged if id(r) in second]
        n_kappa = len(both)
        for c in CRITERIA:
            ab = [(r["judge"][c], second[id(r)][c]) for r in both
                  if eval_runs._num(r["judge"].get(c)) and eval_runs._num(second[id(r)].get(c))]
            metrics["kappa_" + c] = weighted_kappa([x for x, _ in ab], [y for _, y in ab])
    metrics["n_kappa"] = float(n_kappa)
    judge_models = sorted({r.get("judge_model") for r in judged if r.get("judge_model")})
    config = {
        "judge_models": judge_models,
        "judge2": judge2_label,
        "runs": sorted({r.get("run_id") or "?" for r in rows}),
    }
    return eval_runs.make_row(
        "lane-quality-calibration", "scripts/eval/lane-quality/run.sh", config, metrics, n=len(paired),
        model=None, lane=None, ci=ci, ci_level=0.95 if ci else None,
        ci_method="bootstrap-percentile" if ci else None,
        artifact=None, meta={"run_dirs": [os.path.abspath(d) for d in dirs]})


def _fmt(x):
    return "–" if x is None else "%.3f" % x


def cmd_calibration(args):
    row = calibration_row(args.dirs, args.judge2_label)
    if not args.no_ledger:
        eval_runs.append_safe(row, who="lane-quality calibration")
    if args.json:
        print(json.dumps(row))
        return 0
    m, ci = row["metrics"], row["ci"]
    print("Judge vs hidden acceptance (n=%d judged rows with an acceptance result; %d rows with no judge score)"
          % (row["n"], int(m["judge_missing"])))
    print()
    print("| criterion | AUC [95%% CI] | point-biserial r [95%% CI] | weighted kappa vs %s |" % (args.judge2_label or "–"))
    print("|---|---|---|---|")
    for c in CRITERIA:
        cell = []
        for k in ("auc_" + c, "pb_" + c):
            b = ci.get(k)
            cell.append(_fmt(m[k]) + (" [%.3f, %.3f]" % (b["lo"], b["hi"]) if b else ""))
        print("| %s | %s | %s | %s |" % (c, cell[0], cell[1], _fmt(m["kappa_" + c])))
    if args.judge2_label:
        print()
        print("Second judge: %d rows rescored, %d without a stored result." % (int(m["n_kappa"]), int(m["judge2_missing"])))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="lq_stats.py", description="lane-quality statistics (HIMMEL-4648)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summary")
    s.add_argument("files", nargs="+")
    c = sub.add_parser("calibration")
    c.add_argument("dirs", nargs="+")
    c.add_argument("--judge2-label")
    c.add_argument("--json", action="store_true")
    c.add_argument("--no-ledger", action="store_true")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "summary":
            return cmd_summary(args.files)
        return cmd_calibration(args)
    except (OSError, ValueError, KeyError) as e:
        print("lq_stats: %s" % e, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
