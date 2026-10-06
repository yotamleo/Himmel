#!/usr/bin/env bash
# HIMMEL-4675: source-level per-clip partials are a deferred, NON-blocking
# class. The retry count lives on the clip (frontmatter), so it survives the
# daily G-5 state rotation; after DEFER_ATTENTION_AFTER retries a clip moves to
# the needs-attention bucket of the pending report and is no longer retried.
# Blocking classes (failed, and the runbook-level stale-read / rate-limited /
# catastrophic) keep the run from writing .harvest.done.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/../tools/harvest-clip-body-batch.py"
hc="$here/../commands/harvest-clips.md"
tmp="$(mktemp -d)" || exit 1; trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/t.py" <<'PY'
import importlib.util, subprocess, sys
from pathlib import Path

tool, tmp = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("harvest_batch", tool)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-10-06"
fails = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)
        if detail:
            print(detail)


def clip(name, source, body="short.\n", extra=""):
    p = tmp / name
    p.write_text(f"---\ntype: article\nsource: {source}\n{extra}---\n{body}", encoding="utf-8")
    return p


def fm(p):
    return mod.parse_frontmatter(p.read_text(encoding="utf-8"))[0]


check("attention threshold is 5", mod.DEFER_ATTENTION_AFTER == 5)

# Class: thin-body skeleton -> deferred, count on the clip.
p = clip("thin.md", "https://example.com/post")
g, msg, _ = mod.process_clip(p, dry_run=False)
check("thin-body is a deferred partial", g == "~" and "deferred 1/5" in msg, msg)
check("thin-body count on frontmatter", fm(p).get("harvest_defer_count") == "1", p.read_text())

# Class: enricher-gap -> deferred.
p = clip("gap.md", "https://www.tiktok.com/@a/video/1")
g, msg, _ = mod.process_clip(p, dry_run=False)
check("enricher-gap is a deferred partial", g == "~" and "deferred 1/5" in msg
      and fm(p).get("harvest_enricher_gap"), msg)

# Class: IG media-pending -> deferred.
p = clip("ig.md", "https://www.instagram.com/reel/DEF4675/")
g, msg, _ = mod.process_clip(p, dry_run=False)
check("ig media-pending is a deferred partial", g == "~" and "deferred 1/5" in msg
      and fm(p).get("ig_media_pending") == "true", msg)


class Chain:
    def __init__(self, remaining, exc=None):
        self.remaining, self.exc, self.last_backend = remaining, exc, None

    def scrape(self, url):
        raise self.exc


# Class: firecrawl fetch failed (source-level) -> deferred, counted.
p = clip("fc-fail.md", "https://example.org/a")
g, msg, _ = mod.process_clip(p, dry_run=False, firecrawl=Chain(3, RuntimeError("boom")), url_rules=mod.UrlRules())
check("firecrawl fetch failed is deferred + counted", g == "~"
      and fm(p).get("harvest_defer_count") == "1", msg + "\n" + p.read_text())

# Class: firecrawl budget exhausted (run-level) -> deferred, NOT counted.
p = clip("fc-budget.md", "https://example.org/b")
g, msg, _ = mod.process_clip(p, dry_run=False, firecrawl=Chain(0), url_rules=mod.UrlRules())
check("budget exhausted is deferred, not counted", g == "~"
      and "harvest_defer_count" not in fm(p), msg + "\n" + p.read_text())

# Dry-run never bumps the count.
p = clip("dry.md", "https://example.com/dry")
mod.process_clip(p, dry_run=True)
check("dry-run does not bump", "harvest_defer_count" not in p.read_text())

# The count accumulates across runs and the 5th defer moves the clip to
# needs-attention; the body is never touched.
p = clip("five.md", "https://example.com/five", body="short.\n")
for _ in range(5):
    g, msg, _ = mod.process_clip(p, dry_run=False)
f = fm(p)
check("5th defer -> needs-attention", f.get("harvest_defer_count") == "5"
      and f.get("harvest_needs_attention") == "true" and "needs-attention" in msg, msg + "\n" + p.read_text())
check("body untouched after 5 defers", p.read_text().endswith("---\nshort.\n"))
before = p.read_text()
g, msg, _ = mod.process_clip(p, dry_run=False)
check("needs-attention clip is skipped, not retried", g == "o" and "needs-attention" in msg
      and p.read_text() == before, msg)

# Batch level: deferred-only run exits 0, prints the deferred count and writes
# the pending report; a needs-attention clip is listed, never dropped.
v = tmp / "vault"
(v / "Clippings").mkdir(parents=True)
(v / "Clippings/a-thin.md").write_text("---\ntype: article\nsource: https://example.com/x\n---\nshort.\n")
(v / "Clippings/b-ig.md").write_text("---\ntype: instagram\nsource: https://www.instagram.com/p/BIG1/\n---\nshort.\n")
(v / "Clippings/c-stuck.md").write_text(
    "---\ntype: article\nsource: https://example.com/s\nharvest_status: partial\n"
    "harvest_defer_count: 5\nharvest_needs_attention: true\n---\nshort.\n")
r = subprocess.run([sys.executable, tool, str(v)], capture_output=True, text=True)
check("deferred-only batch exits 0", r.returncode == 0, r.stdout + r.stderr)
check("summary counts deferred + needs-attention",
      "harvest-clip-body-batch: 2 deferred (non-blocking), 1 needs-attention" in r.stdout, r.stdout)
rep = v / ".harvest-pending.md"
text = rep.read_text() if rep.exists() else ""
check("pending report lists deferred clips", "[[Clippings/a-thin]]" in text and "[[Clippings/b-ig]]" in text, text)
na = text.split("## Needs attention", 1)
check("pending report has needs-attention bucket", len(na) == 2 and "[[Clippings/c-stuck]]" in na[1], text)

# Blocking class: failed -> exit 4.
(v / "Clippings/d-bad.md").write_text("---\ntype: article\nsource: not a url\n---\nshort.\n")
r = subprocess.run([sys.executable, tool, str(v)], capture_output=True, text=True)
check("failed clip blocks (exit 4)", r.returncode == 4, r.stdout + r.stderr)

# Dry-run writes no report.
v2 = tmp / "vault2"
(v2 / "Clippings").mkdir(parents=True)
(v2 / "Clippings/a.md").write_text("---\ntype: article\nsource: https://example.com/x\n---\nshort.\n")
subprocess.run([sys.executable, tool, str(v2), "--dry-run"], capture_output=True, text=True)
check("dry-run writes no pending report", not (v2 / ".harvest-pending.md").exists())

sys.exit(1 if fails else 0)
PY
python3 "$tmp/t.py" "$tool" "$tmp"

# Runbook contract: the class table, and G-8 writes the marker when every
# partial is deferred-class.
table=$(awk '/^### Partial classes/{p=1;next} /^### /{if(p) exit} p' "$hc")
for row in "thin-body" "enricher-gap" "ig_media_pending" "x_media_pending" "firecrawl" \
           "stale-read" "rate-limited" "failed" "catastrophic" "needs-attention" \
           "harvest_defer_count" ".harvest-pending.md"; do
    printf '%s' "$table" | grep -qF -- "$row" || { echo "FAIL: class table lacks $row"; exit 1; }
done
for cls in "stale-read" "rate-limited" "catastrophic"; do
    printf '%s' "$table" | grep -F -- "$cls" | grep -qi "block" \
        || { echo "FAIL: class table does not mark $cls as blocking"; exit 1; }
done
g8=$(awk '/^### G-8/{p=1;next} /^### /{if(p) exit} p' "$hc")
printf '%s' "$g8" | grep -qi "deferred" || { echo "FAIL: G-8 does not admit deferred partials"; exit 1; }
echo "HARVEST-DEFERRED PASS"
