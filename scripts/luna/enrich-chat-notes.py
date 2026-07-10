#!/usr/bin/env python3
"""enrich-chat-notes — DeepSeek enrichment pass over enriched:false chat-import notes.

HIMMEL-833. Sibling of fold-chat-history.py (HIMMEL-832). Per note: one
DeepSeek call (up to 2 attempts on invalid response shape) (summary +
vocab-constrained tags); each request also carries the vault-wide top-200
tag vocabulary (tag names only, from all vault markdown) alongside the note
payload as the allowed-tags list. Related Notes are computed LOCALLY by tag
overlap (zero egress). Egress is gated by the egress matrix (purpose:
enrichment) and ledgered per run.

This tool is luna-personal-only by design: the corpus in the gate query and
ledger is PINNED (not resolved from --vault), and --vault is allow-listed to
the configured LUNA_VAULT/LUNA_VAULT_PATH root (Clippings/ excluded).
Classification mirrors the egress guards (graphify-fence.sh classify()):
a .salus marker and the phi-roots/egress-denylist config roots are refused
(fail-closed on an unreadable guard config), and only a vault at/under the
configured luna root classifies as luna-personal — so the pinned corpus
literal is truthful even before the gate/ledger run.

Usage:
  python scripts/luna/enrich-chat-notes.py --vault <vault-dir> [--limit N] [--dry-run]
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):  # Windows cp1252 trap
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

MODEL = "deepseek-chat"
VOCAB_TOP = 200
RELATED_MIN_SHARED = 2
RELATED_MAX = 5
PEAK_HOURS_UTC = (1, 2, 3, 6, 7, 8, 9)
API_URL = "https://api.deepseek.com/chat/completions"
SKIP_DIRS = {".obsidian", ".trash", ".git", "graphify-out", "_assets", "assets"}


def split_frontmatter(text):
    """(fm_lines, body) or None when no closed frontmatter block."""
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            return lines[1:i], "\n".join(lines[i + 1:])
    return None


def fm_value(fm_lines, key):
    prefix = key + ":"
    for ln in fm_lines:
        if ln.startswith(prefix):
            return ln[len(prefix):].strip()
    return None


def parse_flow_tags(raw):
    """Flow-style '[a, b]' -> list. Anything else -> None (out of contract)."""
    raw = raw.strip()
    if not (raw.startswith("[") and raw.endswith("]")):
        return None
    inner = raw[1:-1].strip()
    if not inner:
        return []
    return [t.strip().strip('"').strip("'") for t in inner.split(",") if t.strip()]


def scan_candidates(vault, limit):
    """Sorted enriched:false notes under <vault>/chats/, assets dirs skipped."""
    chats = vault / "chats"
    out = []
    if not chats.is_dir():
        return out
    for p in sorted(chats.rglob("*.md")):
        rel_dirs = p.relative_to(chats).parts[:-1]
        if any(d in ("assets", "_assets") for d in rel_dirs):
            continue
        try:
            parts = split_frontmatter(p.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError):
            continue
        if parts and fm_value(parts[0], "enriched") == "false":
            out.append(p)
            if limit is not None and len(out) >= limit:
                break
    return out


def build_payload(text):
    """Body text for the API: frontmatter stripped, asset pointers dropped.

    Full body is sent (no truncation) per operator directive HIMMEL-833:
    truncation risks losing context for summary/tag inference. An
    over-context-window note fails the API call and is skipped via the
    existing per-note failure path."""
    parts = split_frontmatter(text)
    body = parts[1] if parts else text
    kept = [ln for ln in body.split("\n")
            if not ln.lstrip().startswith(("![[", "[image:", "[audio:"))]
    return "\n".join(kept).strip()


def note_title(text, fallback):
    parts = split_frontmatter(text)
    body = parts[1] if parts else text
    for ln in body.split("\n"):
        if ln.startswith("# "):
            return ln[2:].strip()
    return fallback


def scan_vault_index(vault):
    """(vocab top-VOCAB_TOP by frequency then name, {path: (stem, tags set)})."""
    counts = {}
    index = {}
    for p in sorted(vault.rglob("*.md")):
        rel_dirs = p.relative_to(vault).parts[:-1]
        if any(d in SKIP_DIRS for d in rel_dirs):
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        tags = []
        parts = split_frontmatter(text)
        if parts:
            raw = fm_value(parts[0], "tags")
            if raw is not None:
                tags = parse_flow_tags(raw) or []
        for t in tags:
            counts[t] = counts.get(t, 0) + 1
        index[p] = (p.stem, set(tags))
    vocab = [t for t, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
    return vocab[:VOCAB_TOP], index


def generic_tags(vault):
    """Tags too generic to score relatedness: chat-import + provider dir names."""
    g = {"chat-import"}
    chats = vault / "chats"
    if chats.is_dir():
        g |= {d.name for d in chats.iterdir() if d.is_dir()}
    return g


def related_notes(note_path, tags, index, generic):
    """<=RELATED_MAX stems sharing >=RELATED_MIN_SHARED non-generic tags."""
    generic_lc = {g.lower() for g in generic}
    want = {t.lower() for t in tags} - generic_lc
    scored = []
    for p, (stem, ptags) in index.items():
        if p == note_path:
            continue
        shared = len(want & ({t.lower() for t in ptags} - generic_lc))
        if shared >= RELATED_MIN_SHARED:
            scored.append((-shared, str(p), stem))
    scored.sort()
    return [stem for _, _, stem in scored[:RELATED_MAX]]


def salus_marked(root):
    """True if a `.salus` marker sits at root or any ancestor (PHI vault)."""
    d = root.resolve()
    for cand in (d, *d.parents):
        if (cand / ".salus").exists():
            return True
    return False


PHI_LIST_NAMES = ("phi-roots", "egress-denylist")


def _is_under(p, root):
    """Windows-safe containment: case-normalized resolved-path comparison."""
    try:
        a = os.path.normcase(str(Path(p).resolve()))
        b = os.path.normcase(str(Path(root).resolve()))
    except OSError:
        return False
    b = b.rstrip("/\\")
    return a == b or a.startswith(b + os.sep) or a.startswith(b + "/")


def classify_vault(vault):
    """Allow-list corpus classification of --vault, mirroring the egress
    guards' classify() precedence (graphify-fence.sh): .salus marker ->
    refuse; phi-roots / egress-denylist config lists (unreadable = fail
    closed) -> refuse; then ONLY a vault at/under the configured
    LUNA_VAULT / LUNA_VAULT_PATH root (excluding Clippings/) classifies
    as luna-personal. Everything else is refused.
    Returns ("luna-personal", "") or ("", reason)."""
    root = vault.resolve()
    if salus_marked(root):
        return "", ".salus-marked vault (PHI)"
    cfg = Path(os.environ.get("CLAUDE_GLM_CONFIG_DIR")
               or (Path.home() / ".config" / "claude-glm"))
    for name in PHI_LIST_NAMES:
        lf = cfg / name
        if lf.exists():
            if not lf.is_file():
                return "", f"unreadable guard config {name} (fail closed)"
            try:
                lines = lf.read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeDecodeError):
                return "", f"unreadable guard config {name} (fail closed)"
            for line in lines:
                r = line.strip().rstrip("/\\")
                if r and _is_under(root, r):
                    return "", f"protected root ({name})"
    luna = os.environ.get("LUNA_VAULT") or os.environ.get("LUNA_VAULT_PATH")
    if not luna:
        return "", "LUNA_VAULT/LUNA_VAULT_PATH not set (fail closed)"
    if not _is_under(root, luna):
        return "", "vault is not the configured luna root"
    if _is_under(root, Path(luna) / "Clippings"):
        return "", "luna-clippings is not luna-personal"
    return "luna-personal", ""


def primary_root(script_dir):
    """Primary checkout root (worktrees lack .env, like the jira dist/).

    Egress policy is deliberately read from this PRIMARY root, not the
    worktree: a worktree cannot self-approve egress by editing its local
    matrix copy, so a pre-merge worktree run sees the old matrix and fails
    closed (default deny)."""
    try:
        out = subprocess.run(
            ["git", "-C", str(script_dir), "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=15)
        if out.returncode == 0 and out.stdout.strip():
            gd = Path(out.stdout.strip())
            if not gd.is_absolute():  # git may print a relative '.git'
                gd = (script_dir / gd).resolve()
            return gd.parent
    except (OSError, subprocess.SubprocessError):
        pass
    return script_dir.parent.parent


def resolve_api_key(script_dir):
    """Env DEEPSEEK_API_KEY wins; else the PRIMARY checkout's .env.
    Never resolves from the process CWD (HIMMEL-460 trap)."""
    key = os.environ.get("DEEPSEEK_API_KEY")
    if key:
        return key
    envf = primary_root(script_dir) / ".env"
    if not envf.is_file():
        return None
    for ln in envf.read_text(encoding="utf-8").splitlines():
        ln = ln.strip()
        if ln.startswith("DEEPSEEK_API_KEY="):
            val = ln.split("=", 1)[1].strip().strip('"').strip("'")
            return val or None
    return None


def _run_gate_eval(repo_root):
    """(returncode, stdout, stderr) of the matrix eval. Seam for tests."""
    helper = repo_root / "scripts" / "guardrails" / "egress-matrix-eval.mjs"
    out = subprocess.run(
        ["node", str(helper), "luna-personal", "deepseek", "enrichment"],
        capture_output=True, text=True, timeout=30)
    return out.returncode, out.stdout, out.stderr


def egress_gate(repo_root):
    """(verdict, note). ('error', msg) on subprocess failure/nonzero exit."""
    try:
        rc, stdout, stderr = _run_gate_eval(repo_root)
    except (OSError, subprocess.SubprocessError) as e:
        return ("error", str(e))
    if rc != 0:
        return ("error", (stderr or stdout).strip())
    verdict, _, note = stdout.strip().split("\n")[0].partition("\t")
    return (verdict, note)


def ledger_append(chats_root, count, vocab_count):
    """One JSONL audit line BEFORE first egress. False = caller must refuse.

    `count` = notes egressed this run; `vocab_count` = number of vault-wide
    tag names carried with each request (the allowed-tags vocabulary)."""
    path = Path(os.environ.get("GRAPHIFY_LEDGER")
                or Path.home() / ".claude" / "graphify-egress.jsonl")
    rec = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "path": str(chats_root),
        "corpus": "luna-personal",
        "provider": "deepseek",
        "purpose": "enrichment",
        "verdict": "allow+log",
        "tool": "enrich-chat-notes",
        "notes": count,
        "vocab_tags": vocab_count,
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError as e:
        print(f"enrich-chat-notes: ledger append error: {e}", file=sys.stderr)
        return False
    return True


def offpeak_warn():
    hour = datetime.now(timezone.utc).hour
    if hour in PEAK_HOURS_UTC:
        nxt = next(h % 24 for h in range(hour + 1, hour + 25)
                   if h % 24 not in PEAK_HOURS_UTC)
        print(f"enrich-chat-notes: WARN inside DeepSeek peak window (2x); "
              f"off-peak resumes {nxt:02d}:00 UTC. Advisory.", file=sys.stderr)


SYSTEM_PROMPT = (
    "You summarize chat conversations for a personal knowledge vault. "
    'Reply with JSON only: {"summary": "1-2 sentence English summary", '
    '"tags": [3 to 8 tags chosen STRICTLY from the provided vocabulary]}')


def _http_post(api_key, body):
    req = urllib.request.Request(
        API_URL,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + api_key},
        method="POST")
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def call_deepseek(api_key, title, payload, vocab, post=None):
    """One enrichment call. Sends the note payload plus the vault-wide tag
    vocabulary (`vocab`, tag names only — the allowed-tags list) to the
    provider; returns the model's parsed JSON dict. Raises
    urllib.error.*/OSError/ValueError/KeyError/TypeError/IndexError on
    failure (TypeError/IndexError cover malformed response shapes such as an
    empty choices list or a null content)."""
    post = post or _http_post
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content":
                "Vocabulary: " + ", ".join(vocab)
                + "\n\nTitle: " + title + "\n\nTranscript:\n" + payload},
        ],
        "response_format": {"type": "json_object"},
        "temperature": 0.2,
        "max_tokens": 500,
    }
    data = None
    for attempt in range(3):
        try:
            data = post(api_key, body)
            break
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < 2:
                time.sleep(2 ** attempt * 2)
                continue
            raise
        except (urllib.error.URLError, TimeoutError, OSError):
            if attempt < 2:
                time.sleep(2 ** attempt * 2)
                continue
            raise
    return json.loads(data["choices"][0]["message"]["content"])


def validate_result(raw, vocab):
    """{'summary','tags'} with vocab-filtered tags, or None on bad shape."""
    if not isinstance(raw, dict):
        return None
    summary, tags = raw.get("summary"), raw.get("tags")
    if not isinstance(summary, str) or not summary.strip():
        return None
    if not isinstance(tags, list):
        return None
    by_lower = {}
    for v in vocab:
        by_lower.setdefault(v.lower(), v)
    seen, kept = set(), []
    for t in tags:
        if not isinstance(t, str):
            continue
        k = t.strip().lower()
        if k in by_lower and k not in seen:
            seen.add(k)
            kept.append(by_lower[k])
    if not kept:
        return None  # every model tag failed the vocab filter: no enrichment
    return {"summary": " ".join(summary.split()), "tags": kept[:8]}


def yaml_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def enrich_note_text(text, summary, new_tags, related, today, model=MODEL):
    """(new_text, None) on success, or (None, reason) when out of the
    frontmatter contract — reason is one of "unclosed-frontmatter",
    "no-tags-key", "block-style-tags", "no-enriched-key"."""
    parts = split_frontmatter(text)
    if not parts:
        return None, "unclosed-frontmatter"
    fm, body = parts
    raw_tags = fm_value(fm, "tags")
    if raw_tags is None:
        return None, "no-tags-key"  # contract: exactly what fold-chat-history emits (tags: always present)
    existing = parse_flow_tags(raw_tags)
    if existing is None:
        return None, "block-style-tags"  # skip rather than risk corruption
    merged = list(existing or [])
    lower = {t.lower() for t in merged}
    for t in new_tags:
        if t.lower() not in lower:
            lower.add(t.lower())
            merged.append(t)
    out, flipped = [], False
    for ln in fm:
        if ln.startswith("tags:"):
            out.append("tags: [" + ", ".join(merged) + "]")
        elif ln.startswith("enriched:"):
            out.append("enriched: true")
            flipped = True
        else:
            out.append(ln)
    if not flipped:
        return None, "no-enriched-key"
    out.append("summary: " + yaml_quote(" ".join(summary.split())))
    out.append("enriched_at: " + today)
    out.append("enriched_model: " + model)
    new_body = body
    if related and "\n## Related Notes" not in "\n" + body:
        new_body = (body.rstrip("\n") + "\n\n## Related Notes\n\n"
                    + "\n".join("- [[" + r + "]]" for r in related) + "\n")
    return "\n".join(["---"] + out + ["---"]) + "\n" + new_body, None


def write_atomic(path, text):
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="DeepSeek enrichment pass over enriched:false chat-import notes (HIMMEL-833)")
    ap.add_argument("--vault", required=True, help="vault root (contains chats/)")
    ap.add_argument("--limit", type=int, default=None, help="max notes this run")
    ap.add_argument("--dry-run", action="store_true",
                    help="list candidates + payload sizes; no egress, no writes")
    args = ap.parse_args(argv)
    vault = Path(args.vault)
    if not (vault / "chats").is_dir():
        print(f"enrich-chat-notes: no chats/ under {vault}", file=sys.stderr)
        return 2
    corpus, why = classify_vault(vault)
    if corpus != "luna-personal":
        print(f"enrich-chat-notes: REFUSE — {why}; this tool is "
              "luna-personal-only", file=sys.stderr)
        return 2

    candidates = scan_candidates(vault, args.limit)
    if args.dry_run:
        vocab, _ = scan_vault_index(vault)
        print(f"DRY RUN: {len(candidates)} candidate notes; vocab {len(vocab)} tags")
        for p in candidates:
            payload = build_payload(p.read_text(encoding="utf-8"))
            print(f"  {p.relative_to(vault)}  ({len(payload)} chars)")
        return 0
    if not candidates:
        print("enrich-chat-notes: nothing to do (0 enriched:false notes)")
        return 0

    script_dir = Path(__file__).resolve().parent
    root = primary_root(script_dir)
    # Policy is read from the PRIMARY checkout, not this worktree: a worktree
    # cannot self-approve egress by editing its local matrix copy, so a
    # pre-merge worktree run sees the old matrix and fails closed (default deny).
    verdict, vnote = egress_gate(root)
    if verdict != "allow+log":
        # plain allow is a misconfiguration for enrichment: the ledger
        # obligation is part of the ratified deal (spec: never unaudited)
        print(f"enrich-chat-notes: REFUSE egress (verdict={verdict}: {vnote})",
              file=sys.stderr)
        return 2
    key = resolve_api_key(script_dir)
    if not key:
        print("enrich-chat-notes: DEEPSEEK_API_KEY not set (env or primary .env)",
              file=sys.stderr)
        return 2
    offpeak_warn()
    vocab, index = scan_vault_index(vault)
    gset = generic_tags(vault)
    if not ledger_append(vault / "chats", len(candidates), len(vocab)):
        print("enrich-chat-notes: ledger append failed; refusing to egress",
              file=sys.stderr)
        return 2

    today = f"{datetime.now(timezone.utc):%Y-%m-%d}"
    done = failed = 0
    for p in candidates:
        text = p.read_text(encoding="utf-8")
        payload = build_payload(text)
        title = note_title(text, p.stem)
        result = None
        last_exc = None
        for _ in range(2):  # one extra attempt on unparseable/invalid shape
            try:
                raw = call_deepseek(key, title, payload, vocab)
            except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
                    OSError, ValueError, KeyError, TypeError, IndexError) as e:
                last_exc = e
                continue
            last_exc = None
            result = validate_result(raw, vocab)
            if result:
                break
        if not result:
            failed += 1
            if last_exc is not None:
                print(f"enrich-chat-notes: SKIP (api/shape failure: "
                      f"{type(last_exc).__name__}: {last_exc}) {p.name}",
                      file=sys.stderr)
            else:
                print(f"enrich-chat-notes: SKIP (invalid response shape) {p.name}",
                      file=sys.stderr)
            continue
        related = related_notes(p, result["tags"], index, gset)
        new_text, reason = enrich_note_text(text, result["summary"], result["tags"],
                                            related, today)
        if new_text is None:
            failed += 1
            print(f"enrich-chat-notes: SKIP (frontmatter out of contract: {reason}) {p.name}",
                  file=sys.stderr)
            continue
        write_atomic(p, new_text)
        # later notes in THIS run see this note's fresh tags (spec: in-run index)
        merged = set(parse_flow_tags(
            fm_value(split_frontmatter(new_text)[0], "tags")) or [])
        index[p] = (p.stem, merged)
        done += 1
        print(f"enrich-chat-notes: enriched {p.relative_to(vault)}")
    remaining = len(scan_candidates(vault, None))
    print(f"enrich-chat-notes: done={done} failed={failed} remaining={remaining}")
    if done == 0 and failed > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
