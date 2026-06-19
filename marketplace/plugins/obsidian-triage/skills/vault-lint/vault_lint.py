#!/usr/bin/env python3
"""vault_lint.py — deterministic, vault-agnostic Obsidian vault linter (HIMMEL-402).
Filesystem-only. stdlib-only. UTF-8 safe. See docs/specs/2026-06-19-vault-lint-design.md."""
from __future__ import annotations
import os, re, sys, json, fnmatch, argparse, datetime

_WIKILINK = re.compile(r"\[\[([^\]\n]+?)\]\]")
_FENCE = re.compile(r"```.*?```", re.DOTALL)
_INLINE = re.compile(r"`[^`\n]*`")

def strip_code(text: str) -> str:
    return _INLINE.sub("", _FENCE.sub("", text))

def link_target(raw: str) -> str:
    return raw.split("|", 1)[0].split("#", 1)[0].split("^", 1)[0].strip()

def extract_links(text: str) -> list:
    return [link_target(m) for m in _WIKILINK.findall(strip_code(text)) if link_target(m)]

DEFAULTS = {
    "report_path": "_lint-report-{date}.md",
    "log_path": None,
    "egress_locked": True,
    "bulk_dirs": ["_raw/**", "_noise/**", "_ocr-tmp*/**"],
    "orphan_exempt": ["_*.md", "sessions/**", "Clippings/**", "Home.md", "index.md"],
    "frontmatter_exempt": ["_*.md", "*CLAUDE.md", "README.md", "index.md"],
    "duplicate_exempt": ["_*.md", "README.md"],
    "link_scan_exclude": ["60-Maps/*lint*", "60-Maps/*broken*", "sessions/**"],
    "known_unbuilt_links": [],
    "stale_task_days": 30,
}

def _posix(p): return p.replace("\\", "/")

def _match(relpath, patterns):
    rp = _posix(relpath); base = rp.rsplit("/", 1)[-1]
    return any(fnmatch.fnmatch(rp, p) or fnmatch.fnmatch(base, p) for p in patterns)

def has_frontmatter(text: str) -> bool:
    s = text.lstrip("﻿")
    return s.startswith("---") and re.search(r"(?m)^---\s*$", s[3:]) is not None

def build_index(root: str, cfg: dict) -> dict:
    notes, by_rel, by_base, on_disk = [], set(), {}, set()
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for fn in sorted(files):
            full = os.path.join(dirpath, fn)
            rel = _posix(os.path.relpath(full, root))
            on_disk.add(rel)
            if not fn.lower().endswith(".md"):
                continue
            by_rel.add(rel)
            by_base.setdefault(fn[:-3], []).append(rel)
            with open(full, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            notes.append({
                "relpath": rel, "basename": fn[:-3], "text": text,
                "fm": has_frontmatter(text),
                "links": extract_links(text),
                "is_data": _match(rel, cfg["link_scan_exclude"]),
            })
    return {"notes": notes, "by_rel": by_rel, "by_base": by_base, "files_on_disk": on_disk}

def resolve(target: str, idx: dict) -> bool:
    t = _posix(target)
    if t in idx["by_rel"] or (t + ".md") in idx["by_rel"]:
        return True
    if t in idx["files_on_disk"]:           # non-.md file that exists → not dead
        return True
    base = t.rsplit("/", 1)[-1]
    if base in idx["by_base"]:               # basename resolves (incl. _done/ relocation)
        return True
    return False

def _bucket(rel):
    rp = _posix(rel); return rp.split("/", 1)[0] if "/" in rp else "(root)"

def lint(root: str, cfg: dict, today: str) -> dict:
    idx = build_index(root, cfg)
    inbound = set()
    for n in idx["notes"]:
        if n["is_data"]:
            continue
        for tgt in n["links"]:
            base = _posix(tgt).rsplit("/", 1)[-1]
            for rel in idx["by_base"].get(base, []):
                inbound.add(rel)
    real, by_design = [], []
    def emit(kind, rel, detail, exempt):
        f = {"kind": kind, "path": rel, "detail": detail, "bucket": _bucket(rel)}
        (by_design if exempt else real).append(f)
    for n in idx["notes"]:
        rel = n["relpath"]
        in_bulk = _match(rel, cfg["bulk_dirs"])
        # dead links (skip data-source files entirely)
        if not n["is_data"]:
            for tgt in dict.fromkeys(n["links"]):
                if tgt in cfg["known_unbuilt_links"]:
                    emit("dead_link", rel, f"[[{tgt}]] (allowlisted)", True); continue
                if not resolve(tgt, idx):
                    emit("dead_link", rel, f"[[{tgt}]]", in_bulk)
        # orphans
        if rel not in inbound:
            exempt = in_bulk or _match(rel, cfg["orphan_exempt"])
            emit("orphan", rel, "no inbound link", exempt)
        # frontmatter
        if not n["fm"]:
            exempt = in_bulk or _match(rel, cfg["frontmatter_exempt"])
            emit("frontmatter", rel, "no YAML frontmatter", exempt)
    # duplicates (same basename in >1 path, excluding bulk)
    for base, rels in idx["by_base"].items():
        live = sorted(r for r in rels if not _match(r, cfg["bulk_dirs"]) and not _match(r, cfg.get("duplicate_exempt", [])))
        if len(live) > 1:
            emit("duplicate", live[0], f"basename '{base}' in: {', '.join(live)}", False)
    summary = {"pages": len(idx["notes"]), "real_count": len(real),
               "by_design_count": len(by_design), "date": today}
    return {"summary": summary, "real": real, "by_design": by_design}

def load_config(root: str, cli_path):
    cfg = dict(DEFAULTS)
    path = cli_path or os.path.join(root, ".vault-lint.json")
    if cli_path and not os.path.isfile(path):
        sys.stderr.write(f"vault-lint: WARNING --config file not found: {path}; using defaults\n")
    if os.path.isfile(path):
        try:
            with open(path, encoding="utf-8") as fh:
                cfg.update(json.load(fh))
        except Exception as e:
            sys.stderr.write(f"vault-lint: WARNING bad config {path}: {e}; using defaults\n")
    return cfg

def render_report(res: dict, cfg: dict) -> str:
    s = res["summary"]; out = []
    out.append("---\ntype: meta\ntitle: \"Lint Report %s\"\nstatus: report\n---\n" % s["date"])
    out.append(f"# Lint Report: {s['date']}\n")
    out.append(f"Read-only pass — **nothing auto-fixed**. Pages scanned: **{s['pages']}**; "
               f"real findings: **{s['real_count']}**; by-design: {s['by_design_count']}.\n")
    out.append("## Real findings\n")
    if res["real"]:
        for f in sorted(res["real"], key=lambda f: (f["kind"], f["path"], f["detail"])):
            out.append(f"- **{f['kind']}** `{f['path']}` — {f['detail']}")
    else:
        out.append("- none 🎉")
    out.append("\n## By design (no action)\n")
    byb = {}
    for f in res["by_design"]:
        byb.setdefault((f["kind"], f["bucket"]), 0)
        byb[(f["kind"], f["bucket"])] += 1
    for (kind, bucket), n in sorted(byb.items()):
        out.append(f"- {kind} in `{bucket}`: {n}")
    return "\n".join(out) + "\n"

def main(argv=None) -> int:
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    ap = argparse.ArgumentParser()
    ap.add_argument("vault"); ap.add_argument("--config")
    ap.add_argument("--json", action="store_true"); ap.add_argument("--no-report", action="store_true")
    a = ap.parse_args(argv)
    if not os.path.isdir(a.vault):
        sys.stderr.write(f"vault-lint: not a directory: {a.vault}\n"); return 2
    cfg = load_config(a.vault, a.config)
    today = datetime.date.today().isoformat()
    res = lint(a.vault, cfg, today)
    if not a.no_report:
        rp = os.path.join(a.vault, cfg["report_path"].replace("{date}", today))
        os.makedirs(os.path.dirname(rp) or ".", exist_ok=True)
        with open(rp, "w", encoding="utf-8") as fh:
            fh.write(render_report(res, cfg))
        res["summary"]["report_written"] = _posix(os.path.relpath(rp, a.vault))
    print(json.dumps(res["summary"], ensure_ascii=False, indent=2) if not a.json
          else json.dumps(res, ensure_ascii=False, indent=2))
    return 0

if __name__ == "__main__":
    sys.exit(main())
