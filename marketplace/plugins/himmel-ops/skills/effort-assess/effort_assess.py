#!/usr/bin/env python3
"""effort-assess (HIMMEL-3995): reference-class effort record for one ticket, or the tail of a version.

  effort_assess.py ticket  --low S --high M --g1 yes|no --deps none|<list> --scope-file F ... --red TEXT
  effort_assess.py version --in records.json

ticket: prints one JSON record (median, sigma, mean, P80 in S-eq and bank, the P30..P70 band, config
version, alternatives, goal, DoD result). A record that fails the estimate DoD still prints, names the
failed items on stderr, and exits 1. version: sums the means of ticket records and prints the
Fenton-Wilkinson P80/P90 with a seeded Monte Carlo cross-check; exits 1 when the two disagree.

Every number lives in effort-model.json (stdlib only, no constant in code). The formulas:
  median = kappa * (floor + sqrt(Seq(lo) * Seq(hi))) * g1_mult (non-trivial G1 only)
  sigma  = (sigma_g1 | sigma_base) + sigma_step * (range steps - 1, floored at 0)
  mean   = median * exp(sigma^2 / 2);  P(q) = median * exp(z_q * sigma)

ponytail: the roadmap placer and checksum (outside this repo) still carry their own copy of these
numbers, so the config is the source of truth only for this skill; HIMMEL-4001 moves them onto it.
"""
import argparse
import json
import math
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CONFIG = os.path.join(HERE, "effort-model.json")


def load_config(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def estimate(cfg, low, high, g1, plan_first):
    """(median S-eq, sigma) or (None, None) when the inputs cannot size the ticket."""
    seq, order = cfg["sizes"], cfg["size_order"]
    if plan_first:
        return seq[plan_first], cfg["sigma_plan_first"]
    if not (low and high):
        return None, None
    # a G1 flag on an XS-ceiling ticket is trivial: no multiplier, base sigma (placer rule)
    g1 = g1 == "yes" and high != "XS"
    median = cfg["kappa"] * (cfg["floor"] + math.sqrt(seq[low] * seq[high])) * (cfg["g1_mult"] if g1 else 1.0)
    extra = max(0, order.index(high) - order.index(low) - 1)
    return median, (cfg["sigma_g1"] if g1 else cfg["sigma_base"]) + cfg["sigma_step"] * extra


def dod(cfg, a, median, sigma):
    """Estimate DoD checklist: {item: passed}. A refused estimate lists every failed item."""
    order, rule = cfg["size_order"], cfg["dod"]
    c = {
        "scope_files": bool(a.scope_file),
        "red": bool((a.red or "").strip()),
        "g1_flag": a.g1 in ("yes", "no"),
        "deps": bool((a.deps or "").strip()),
    }
    if a.plan_first_slice:
        c["plan_first_slice"] = a.plan_first_slice in rule["plan_first_sizes"]
    else:
        ok = bool(a.low and a.high)
        c["range_width"] = ok and order.index(a.high) - order.index(a.low) <= rule["max_range_steps"]
    c["sigma_ceiling"] = sigma is not None and round(sigma, 9) < rule["sigma_ceiling"]
    return c


def ticket(cfg, a):
    for name in ("low", "high", "plan_first_slice"):
        v = getattr(a, name)
        if v and v not in cfg["sizes"]:
            sys.exit("effort-assess: unknown size %r (one of %s)" % (v, ", ".join(cfg["size_order"])))
    if a.low and a.high and cfg["size_order"].index(a.low) > cfg["size_order"].index(a.high):
        sys.exit("effort-assess: --low %s is above --high %s" % (a.low, a.high))
    median, sigma = estimate(cfg, a.low, a.high, a.g1, a.plan_first_slice)
    checks = dod(cfg, a, median, sigma)
    failed = [k for k, v in checks.items() if not v]
    rec = {
        "config_version": cfg["version"],
        "goal": a.goal,
        "alternatives": a.alternative,
        "range": [a.low, a.high],
        "plan_first_slice": a.plan_first_slice,
        "g1": a.g1,
        "deps": a.deps,
        "scope_files": a.scope_file,
        "red": a.red,
        "median_seq": median,
        "sigma": sigma,
        "dod": {"passed": not failed, "failed": failed, "checks": checks},
    }
    if median is not None:
        z, bps = cfg["percentile_z"], cfg["bank_per_seq"]
        rec["mean_seq"] = median * math.exp(sigma * sigma / 2)
        rec["p80_seq"] = median * math.exp(z["p80"] * sigma)
        rec["band_seq"] = {p: median * math.exp(z[p] * sigma) for p in ("p30", "p40", "p50", "p60", "p70")}
        rec["bank"] = {"median": median * bps, "mean": rec["mean_seq"] * bps, "p80": rec["p80_seq"] * bps}
    print(json.dumps(rec, indent=2))
    if failed:
        sys.stderr.write("effort-assess: REFUSED, failed DoD items: %s\n" % ", ".join(failed))
        return 1
    return 0


def percentile(sorted_vals, q):
    return sorted_vals[min(len(sorted_vals) - 1, int(q * len(sorted_vals)))]


def version(cfg, a):
    with open(a.infile, encoding="utf-8") as f:
        rows = json.load(f)
    bps, z = cfg["bank_per_seq"], cfg["percentile_z"]
    tol = cfg["mc_fw_tol"] if a.tol is None else a.tol
    if not rows:
        sys.stderr.write("effort-assess: no ticket records in %s\n" % a.infile)
        return 1
    refused = [i for i, r in enumerate(rows) if r.get("dod", {}).get("passed") is False]
    if refused:
        sys.stderr.write("effort-assess: REFUSED records in version input (index: failed DoD items): %s\n" % "; ".join(
            "%d: %s" % (i, ", ".join(rows[i]["dod"].get("failed", []))) for i in refused))
        return 1
    mean = var = 0.0
    for r in rows:
        m, s = r["median_seq"] * bps, r["sigma"]
        mean += m * math.exp(s * s / 2)
        var += (math.exp(s * s) - 1) * m * m * math.exp(s * s)
    s2 = math.log(1 + var / (mean * mean))  # Fenton-Wilkinson: the sum as one log-normal

    def fw(zq):
        return math.exp(math.log(mean) - s2 / 2 + zq * math.sqrt(s2))

    rng = random.Random(cfg["mc_seed"])
    sums = sorted(sum(r["median_seq"] * bps * math.exp(r["sigma"] * rng.gauss(0, 1)) for r in rows)
                  for _ in range(cfg["mc_draws"]))
    out = {
        "config_version": cfg["version"],
        "tickets": len(rows),
        "mean_bank": mean,
        "fw_p80_bank": fw(z["p80"]),
        "fw_p90_bank": fw(z["p90"]),
        "mc_p80_bank": percentile(sums, 0.8),
        "mc_p90_bank": percentile(sums, 0.9),
        "mc_seed": cfg["mc_seed"],
        "mc_draws": cfg["mc_draws"],
        "tolerance_bank": tol,
        "mean_cap": cfg["mean_cap"],
        "p90_cap": cfg["p90_cap"],
    }
    out["agree"] = abs(out["mc_p90_bank"] - out["fw_p90_bank"]) <= tol
    out["within_caps"] = mean <= cfg["mean_cap"] and out["fw_p90_bank"] <= cfg["p90_cap"]
    print(json.dumps(out, indent=2))
    if not out["agree"]:
        sys.stderr.write("effort-assess: Fenton-Wilkinson and Monte Carlo P90 differ by more than %s bank\n" % tol)
        return 1
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--config", default=DEFAULT_CONFIG)
    sub = p.add_subparsers(dest="mode", required=True)
    t = sub.add_parser("ticket")
    t.add_argument("--low")
    t.add_argument("--high")
    t.add_argument("--g1", choices=["yes", "no"])
    t.add_argument("--deps", help="'none' or a list of deps / single-writer links")
    t.add_argument("--scope-file", action="append", default=[])
    t.add_argument("--red", help="the named RED test or check")
    t.add_argument("--plan-first-slice", help="size of the plan-first slice (XS or S)")
    t.add_argument("--goal")
    t.add_argument("--alternative", action="append", default=[])
    v = sub.add_parser("version")
    v.add_argument("--in", dest="infile", required=True, help="JSON list of ticket records (median_seq, sigma)")
    v.add_argument("--tol", type=float, help="override the config's Monte Carlo vs FW tolerance (bank)")
    a = p.parse_args()
    cfg = load_config(a.config)
    return ticket(cfg, a) if a.mode == "ticket" else version(cfg, a)


if __name__ == "__main__":
    sys.exit(main())
