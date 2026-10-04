"""Render bench JSONL rows (no bodies) as a per-category markdown table."""
import json
import statistics
import sys
from collections import defaultdict


def load(paths):
    rows = []
    for p in paths:
        with open(p, encoding="utf-8") as fh:
            rows += [json.loads(ln) for ln in fh if ln.strip()]
    return rows


def render(rows):
    groups = defaultdict(list)
    for r in rows:
        groups[(r["category"], r["provider"])].append(r)
    out = ["| category | provider | n | success | title | phrase | boilerplate (median) | length (median) | latency s (median) | credits | other |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for (cat, prov) in sorted(groups):
        g = groups[(cat, prov)]
        ran = [r for r in g if r["status"] in ("ok", "error")]
        n = len(ran)

        def pct(k):
            return "%d%%" % round(100 * sum(1 for r in ran if r.get(k)) / n) if n else "-"

        def med(k):
            return round(statistics.median(r[k] for r in ran), 2) if n else "-"

        other = ", ".join("%d %s" % (sum(1 for r in g if r["status"] == s), s)
                          for s in ("needs-auth", "skipped-cap") if any(r["status"] == s for r in g)) or "-"
        out.append("| %s | %s | %d | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            cat, prov, n, pct("success"), pct("title_match"), pct("phrase_hit"),
            med("boilerplate_ratio"), med("length"), med("latency_s"),
            sum(r.get("credits", 0) for r in g), other))
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    sys.stdout.write(render(load(sys.argv[1:])))
