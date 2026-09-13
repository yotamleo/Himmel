#!/usr/bin/env python3
# harden-graph.py -- HIMMEL-2983: idempotent post-update step that bridges
# doc-extracted concept nodes whose label literally names a code file to that
# file's AST node (relation "references"), and adds allowlisted subprocess-exec
# code-fact edges (relation "calls"). Operates only on <out>/graph.json;
# stdlib only -- never imports the `graphify` package (not importable from
# system python3; see refresh-graph-map.sh's own venv note).
#
# Matching rule (never guessed): a doc node's label must be EXACTLY a code-file
# token optionally followed by " script"/" file"/" router"/" module" -- full
# path match against an AST file node's source_file first, then a basename
# match ONLY if it is unique across AST file nodes; an ambiguous basename
# (two+ files sharing it) is skipped and counted, never resolved by guessing.
import argparse
import json
import os
import re
import sys
from collections import defaultdict

CODE_EXT = r"[\w./-]+\.(?:mjs|js|ts|sh|py|json|yaml|yml|ps1|toml)\b"
GHOST_LABEL_RE = re.compile(r"(" + CODE_EXT + r")(?: script| file| router| module)?")
DOC_SUFFIXES = (".md", ".txt", ".png", ".yaml", ".yml")


def edge_list_key(graph):
    return "links" if "links" in graph else "edges"


def is_ast_file_node(node):
    sf = node.get("source_file") or ""
    return (
        node.get("file_type") == "code"
        and node.get("source_location") == "L1"
        and node.get("label") == os.path.basename(sf)
    )


def build_ast_index(nodes):
    by_path = {}
    by_base = defaultdict(list)
    for node_id, node in nodes.items():
        if not is_ast_file_node(node):
            continue
        sf = node.get("source_file") or ""
        by_path[sf] = node_id
        by_base[os.path.basename(sf)].append(node_id)
    return by_path, by_base


def strip_leading_dot_slash(path):
    # str.lstrip("./") strips a CHARACTER CLASS, not the literal prefix -- it
    # would mangle ".config/tool.sh" into "config/tool.sh" (codex-1, HIMMEL-2983
    # round 2). Only a literal leading "./" is ever meant to be dropped here.
    return path[2:] if path.startswith("./") else path


def resolve_code_file(token, by_path, by_base):
    """(node_id, ambiguous) for a code-file token: full path -> unique basename -> ambiguous (skip, counted)."""
    token = strip_leading_dot_slash(token)
    if token in by_path:
        return by_path[token], False
    candidates = by_base.get(os.path.basename(token), [])
    if len(candidates) == 1:
        return candidates[0], False
    if len(candidates) > 1:
        return None, True
    return None, False


def find_ghost_bridges(nodes, by_path, by_base):
    bridges = []
    skipped_ambiguous = 0
    for doc_id, node in nodes.items():
        sf = node.get("source_file") or ""
        if not sf.endswith(DOC_SUFFIXES):
            continue
        m = GHOST_LABEL_RE.fullmatch(node.get("label") or "")
        if not m:
            continue
        target_id, ambiguous = resolve_code_file(m.group(1), by_path, by_base)
        if ambiguous:
            skipped_ambiguous += 1
            continue
        if target_id is None or target_id == doc_id:
            continue
        bridges.append(
            {
                "source": doc_id,
                "target": target_id,
                "relation": "references",
                "confidence": "EXTRACTED",
                "confidence_score": 1.0,
                "source_file": sf,
                "source_location": None,
                "weight": 1.0,
                "hardened": "doc-label-names-code-file",
            }
        )
    return bridges, skipped_ambiguous


def load_allowlist(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def find_code_facts(by_path, allowlist):
    # Allowlist entries carry a full path the operator curated -- unlike a doc
    # ghost's bare-basename label, there is no ambiguity to resolve here, so
    # this requires an EXACT source_file match and never falls back to
    # resolve_code_file's basename heuristic (a corpus missing the allowlisted
    # file but containing an unrelated same-named one would otherwise get a
    # false, confidence-1.0 "calls" edge).
    facts = []
    for entry in allowlist:
        src_id = by_path.get(strip_leading_dot_slash(entry["source_file"]))
        tgt_id = by_path.get(strip_leading_dot_slash(entry["target_file"]))
        if src_id is None or tgt_id is None:
            continue
        facts.append(
            {
                "source": src_id,
                "target": tgt_id,
                "relation": entry.get("relation", "calls"),
                "confidence": "EXTRACTED",
                "confidence_score": 1.0,
                "source_file": entry["source_file"],
                "source_location": entry.get("source_location"),
                "weight": 1.0,
                "hardened": "subprocess-exec",
            }
        )
    return facts


def append_cost_note(out_dir, summary):
    cost_path = os.path.join(out_dir, "cost.json")
    if not os.path.exists(cost_path):
        return
    try:
        with open(cost_path, "r", encoding="utf-8") as f:
            cost = json.load(f)
    except (OSError, ValueError):
        return
    runs = cost.get("runs")
    if not runs:
        return
    prior = runs[-1].get("note") or ""
    runs[-1]["note"] = f"{prior}; {summary}" if prior else summary
    tmp_path = cost_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(cost, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, cost_path)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="graphify-out directory containing graph.json")
    ap.add_argument("--allowlist", default=None, help="defaults to harden-allowlist.json next to this script")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    graph_path = os.path.join(args.out, "graph.json")
    try:
        with open(graph_path, "r", encoding="utf-8") as f:
            graph = json.load(f)
    except (OSError, ValueError) as exc:
        print(f"harden-graph: cannot read {graph_path}: {exc}", file=sys.stderr)
        return 1

    nodes = {n["id"]: n for n in graph.get("nodes", [])}
    ekey = edge_list_key(graph)
    edges = graph.get(ekey, [])

    by_path, by_base = build_ast_index(nodes)
    bridges, skipped_ambiguous = find_ghost_bridges(nodes, by_path, by_base)

    allowlist_path = args.allowlist or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "harden-allowlist.json"
    )
    facts = find_code_facts(by_path, load_allowlist(allowlist_path))

    # graph.json is "directed": false, "multigraph": false -- (u, v) and (v, u)
    # are the SAME edge, so dedup keys must be order-independent (codex-2,
    # HIMMEL-2983 round 1) or a pre-existing reverse-order edge between the
    # same two nodes would not be recognized as a duplicate.
    existing_pairs = {frozenset((e.get("source"), e.get("target"))) for e in edges}
    seen = set()
    new_edges = []
    for e in bridges + facts:
        pair = frozenset((e["source"], e["target"]))
        if pair in existing_pairs or pair in seen:
            continue
        if e["source"] not in nodes or e["target"] not in nodes:
            continue
        seen.add(pair)
        new_edges.append(e)

    bridge_count = sum(1 for e in new_edges if e["hardened"] == "doc-label-names-code-file")
    fact_count = sum(1 for e in new_edges if e["hardened"] == "subprocess-exec")
    unchanged = 0 if new_edges else 1
    summary = (
        f"harden-graph: bridges={bridge_count} code-facts={fact_count} "
        f"skipped-ambiguous={skipped_ambiguous} unchanged={unchanged}"
    )
    print(summary)

    if not new_edges or args.dry_run:
        return 0

    graph[ekey] = edges + new_edges
    tmp_path = graph_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(graph, f)
    os.replace(tmp_path, graph_path)
    append_cost_note(args.out, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
