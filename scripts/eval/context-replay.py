#!/usr/bin/env python3
# scripts/eval/context-replay.py - replay recorded session JSONL at several
# context windows and price each with the burn-weights (HIMMEL-5042).
# Local-only: reads ~/.claude/projects/*himmel*/*.jsonl, runs no inference,
# sends nothing anywhere. Weights mirror scripts/lanes/lib/burn-weights.sh
# (override with the same LEG_BURN_W_* env vars).
#
# Model (ponytail: per-call growth replay, ignores 5m/1h TTL expiry and tool
# result truncation, upgrade path = a real A/B on a held-out week):
#   a session is a sequence of API calls (context C_i, output o_i, growth
#   g_i = C_i - C_{i-1}); recorded compaction resets are unrolled by replacing
#   the reset step's growth with the session median growth. At window W the
#   replay compacts when C + g would exceed W: one summarise call (reads C as
#   cache_read, writes SUMMARY_OUT tokens) then the context restarts at POST
#   tokens, rewritten once as cache_create. mode=handover instead restarts at
#   FLOOR + REBRIEF with HANDOVER_OUT of ceremony output.
import argparse, glob, json, os, statistics, sys, time

W_CR = float(os.environ.get("LEG_BURN_W_CACHE_READ", "0.1"))
W_CC = float(os.environ.get("LEG_BURN_W_CACHE_CREATE", "1.25"))
W_IN = float(os.environ.get("LEG_BURN_W_INPUT", "1"))
W_OUT = float(os.environ.get("LEG_BURN_W_OUTPUT", "5"))

SUMMARY_OUT = 10000   # tokens the summariser writes
HANDOVER_OUT = 15000  # ceremony output of a hand-off
REBRIEF = 20000       # tokens a fresh session reads to resume


def cost(inp, cr, cc, out):
    return inp * W_IN + cr * W_CR + cc * W_CC + out * W_OUT


def load(path):
    """-> dict(name, model, calls=[(ctx, out, inp, cr, cc)], compactions=[meta])"""
    calls = {}
    name = None
    comps = []
    model = None
    first_ts = None
    for line in open(path, errors="replace"):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        t = d.get("type")
        if t in ("custom-title", "agent-name"):
            name = d.get("customTitle") or d.get("agentName") or name
        elif t == "system" and d.get("subtype") == "compact_boundary":
            comps.append(d.get("compactMetadata") or {})
        elif t == "assistant" and not d.get("isSidechain"):
            u = (d.get("message") or {}).get("usage")
            if not u:
                continue
            first_ts = first_ts or d.get("timestamp")
            model = (d.get("message") or {}).get("model") or model
            key = d.get("requestId") or d.get("uuid")
            inp = u.get("input_tokens", 0)
            cr = u.get("cache_read_input_tokens", 0)
            cc = u.get("cache_creation_input_tokens", 0)
            out = u.get("output_tokens", 0)
            prev = calls.get(key)
            if prev is None or out >= prev[1]:
                calls[key] = (inp + cr + cc, out, inp, cr, cc)
    seq = list(calls.values())
    return {"name": name or "", "model": model, "calls": seq, "compactions": comps,
            "ts": first_ts}


def unroll(calls):
    """Growth per call with recorded compaction resets replaced by the median."""
    gs = [calls[i][0] - calls[i - 1][0] for i in range(1, len(calls))]
    pos = [g for g in gs if g > 0]
    med = statistics.median(pos) if pos else 0
    out = []
    for g in gs:
        out.append(med if g < -20000 else max(g, 0))
    return out, med


def replay(calls, window, mode, post, floor):
    """Price the unrolled trajectory under a window. Returns (cost_eq, events)."""
    if not calls:
        return 0.0, 0
    gs, _ = unroll(calls)
    ctx = calls[0][0]
    tot = cost(calls[0][2], calls[0][3], calls[0][4], calls[0][1])
    ev = 0
    for i, g in enumerate(gs, start=1):
        out = calls[i][1]
        if window and ctx + g > window:
            ev += 1
            if mode == "handover":
                tot += cost(0, ctx, 0, HANDOVER_OUT)
                ctx = floor + REBRIEF
            else:
                tot += cost(0, ctx, 0, SUMMARY_OUT)
                ctx = post
            tot += cost(0, 0, ctx, 0)
        tot += cost(0, ctx, g, out)
        ctx += g
    return tot, ev


def classify(name, path):
    n = name.lower()
    if n.endswith("-console") or "console" in n and "nextleg" in n:
        return "console"
    if "-n1" in n or "/worktrees/" in path.replace("--claude-worktrees-", "/worktrees/"):
        return "leg"
    return "other"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--glob", default=os.path.expanduser("~/.claude/projects/*himmel*/*.jsonl"))
    ap.add_argument("--windows", default="1000000,600000,450000,400000,300000,200000,150000")
    ap.add_argument("--min-calls", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    wins = [int(x) for x in a.windows.split(",")]
    cutoff = time.time() - a.days * 86400
    sess = []
    for p in glob.glob(a.glob):
        if os.path.getmtime(p) < cutoff:
            continue
        s = load(p)
        if len(s["calls"]) < a.min_calls:
            continue
        s["path"] = p
        s["kind"] = classify(s["name"], p)
        sess.append(s)
    posts = [c["postTokens"] for s in sess for c in s["compactions"] if c.get("postTokens")]
    post = int(statistics.median(posts)) if posts else 45000
    res = {"post_tokens_median": post, "n_sessions": len(sess), "kinds": {}}
    for kind in ("console", "leg", "other"):
        ss = [s for s in sess if s["kind"] == kind]
        if not ss:
            continue
        floors = [s["calls"][0][0] for s in ss]
        floor = int(statistics.median(floors))
        actual = sum(cost(c[2], c[3], c[4], c[1]) for s in ss for c in s["calls"])
        rec_comp = sum(len(s["compactions"]) for s in ss)
        k = {"sessions": len(ss), "calls": sum(len(s["calls"]) for s in ss),
             "actual_cost_eq": actual, "recorded_compactions": rec_comp,
             "median_floor": floor, "max_ctx_median": int(statistics.median(max(c[0] for c in s["calls"]) for s in ss)),
             "windows": {}}
        for w in wins:
            for mode in ("compact", "handover"):
                t = ev = 0
                for s in ss:
                    c, e = replay(s["calls"], w, mode, post, floor)
                    t += c
                    ev += e
                k["windows"][f"{w}/{mode}"] = {"cost_eq": t, "events": ev}
        inf = sum(replay(s["calls"], 0, "compact", post, floor)[0] for s in ss)
        k["unbounded_cost_eq"] = inf
        res["kinds"][kind] = k
    if a.json:
        print(json.dumps(res, indent=1))
        return
    for kind, k in res["kinds"].items():
        print(f"== {kind}: {k['sessions']} sessions, {k['calls']} calls, floor~{k['median_floor']}, "
              f"recorded compactions {k['recorded_compactions']}, actual cost_eq {k['actual_cost_eq']:.3e}, "
              f"unbounded replay {k['unbounded_cost_eq']:.3e}")
        base = k["unbounded_cost_eq"]
        for key, v in k["windows"].items():
            print(f"  {key:>18}  cost_eq {v['cost_eq']:.3e}  vs unbounded {100*(v['cost_eq']-base)/base:+6.1f}%  events {v['events']}")


if __name__ == "__main__":
    main()
