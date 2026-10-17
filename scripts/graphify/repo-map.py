#!/usr/bin/env python3
"""repo-map.py -- a token-capped, Aider-style repo map from graphify's graph.json.

Collapses the graph to files (an edge between nodes of two different files is an
edge between those files), ranks the files with PageRank, and prints the
highest-ranked files with their most-referenced symbols until the token cap.
Legs rarely call the graph tool, so the map is meant to ride the system prompt
at session start (headed-arm-leg.sh, LEG_REPO_MAP=1).

Usage: repo-map.py --graph <graph.json> [--max-tokens 2000] [--exclude archive/]
                   [--order path|rank]

Tokens are estimated as characters / 4, the same estimate the K7 retrieval eval
uses. Exit 0 printed, 2 no graph or unreadable graph. Stdlib only.
"""
import argparse
import json
import re
import sys

# The map rides a system prompt: no graph text may carry terminal or control bytes into it.
CONTROL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
DAMPING = 0.85
ITERATIONS = 50
SYMBOLS_PER_FILE = 5
LABEL_MAX = 40


def pagerank(nodes, edges):
    """edges: {src: {dst: weight}}; returns {node: rank}, dangling mass spread evenly."""
    n = len(nodes)
    rank = dict.fromkeys(nodes, 1.0 / n)
    out_w = {s: sum(d.values()) for s, d in edges.items()}
    for _ in range(ITERATIONS):
        dangling = sum(rank[v] for v in nodes if not out_w.get(v))
        nxt = dict.fromkeys(nodes, (1 - DAMPING) / n + DAMPING * dangling / n)
        for s, dsts in edges.items():
            share = DAMPING * rank[s] / out_w[s]
            for d, w in dsts.items():
                nxt[d] += share * w
        rank = nxt
    return rank


def build(graph, excludes):
    file_of = {}
    label_of = {}
    for node in graph.get("nodes", []):
        path = node.get("source_file")
        if not path or any(path.startswith(e) for e in excludes):
            continue
        file_of[node["id"]] = path
        label_of[node["id"]] = str(node.get("label") or node["id"])
    edges = {}
    refs = []
    for link in graph.get("links", graph.get("edges", [])):
        s, t = link.get("source"), link.get("target")
        fs, ft = file_of.get(s), file_of.get(t)
        if fs is None or ft is None or fs == ft:
            continue
        w = float(link.get("weight") or 1.0)
        edges.setdefault(fs, {}).setdefault(ft, 0.0)
        edges[fs][ft] += w
        refs.append((fs, t, w))
    files = sorted(set(file_of.values()))
    rank = pagerank(files, edges) if files else {}
    # A symbol is worth the rank its referencing files hand it, as in Aider.
    sym = {}
    for fs, t, w in refs:
        sym[t] = sym.get(t, 0.0) + rank[fs] * w
    by_file = {}
    for node_id, score in sym.items():
        by_file.setdefault(file_of[node_id], []).append((score, label_of[node_id]))
    return files, rank, by_file


def line_for(path, symbols):
    top = []
    for _, label in sorted(symbols, key=lambda x: (-x[0], x[1])):
        label = " ".join(CONTROL.sub(" ", label).split())
        # graphify's node for the file itself repeats the path the line already shows.
        if path.endswith(label):
            continue
        if len(label) > LABEL_MAX:
            label = label[: LABEL_MAX - 1] + "…"
        if label not in top:
            top.append(label)
        if len(top) == SYMBOLS_PER_FILE:
            break
    return CONTROL.sub(" ", path) + (": " + ", ".join(top) if top else "")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--graph", required=True)
    ap.add_argument("--max-tokens", type=int, default=2000)
    ap.add_argument("--exclude", action="append", default=None,
                    help="path prefix to leave out (repeatable; default archive/)")
    ap.add_argument("--order", choices=["path", "rank"], default="path")
    a = ap.parse_args()
    try:
        with open(a.graph, encoding="utf-8") as fh:
            graph = json.load(fh)
    except (OSError, ValueError) as exc:
        print("repo-map: no graph at %s (%s)" % (a.graph, exc), file=sys.stderr)
        return 2
    excludes = a.exclude if a.exclude is not None else ["archive/"]
    files, rank, by_file = build(graph, excludes)
    commit = str(graph.get("built_at_commit") or "unknown")[:9]
    header = ("# Repo map (graphify @%s): files by PageRank, top symbols each; cap %d tokens"
              % (commit, a.max_tokens))
    budget = a.max_tokens * 4 - len(header) - 1
    picked = []
    for path in sorted(files, key=lambda f: (-rank[f], f)):
        line = line_for(path, by_file.get(path, []))
        if len(line) + 1 > budget:
            break
        budget -= len(line) + 1
        picked.append((path, line))
    if a.order == "path":
        picked.sort()
    print(header)
    for _, line in picked:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
