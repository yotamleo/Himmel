#!/usr/bin/env bash
# Suite for docs/adoption-trail.html and the Pages docs that point at it
# (HIMMEL-3225).
#
# The trail is a static page served by GitHub Pages, so nothing else ever loads
# it in CI: a dead href, a detail chip whose panel text was deleted, or a claim
# that drifted from the tree ships silently. Every case here is mechanical and
# derives its expected value from the tree, not from a number typed into the
# test — the cadence count comes from cadence-registry.json, so adding a
# registry row without touching the page fails here.
#
#   1. LINKS    — every relative href/src resolves under docs/; every
#                 data-detail id has a panel entry in the page's D table.
#   2. PAGES    — no "once Pages is enabled" phrasing survives (Pages is live),
#                 and docs/README.md documents how the site is served.
#   3. CURRENCY — claims that were verified against the tree and later drifted:
#                 the cadence count, the lanes menu, the claude-obsidian
#                 provenance, where --skip-hooks lives, and the leg/lane split.
#
# Platform guard (gitbash-only): POSIX bash 3.2+ plus grep/sed/jq, so it runs
# unchanged under Git Bash on Windows. No .ps1 twin needed.
#
# Usage: bash scripts/docs/test-adoption-trail.sh
# Exit:  0 = every case passed, 1 = at least one failed (all are reported).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PAGE="$ROOT/docs/adoption-trail.html"
DOCS_README="$ROOT/docs/README.md"
REGISTRY="$ROOT/scripts/himmelctl/lib/cadence-registry.json"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

[ -f "$PAGE" ] || { echo "FAIL: $PAGE missing" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

# --- 1. LINKS -----------------------------------------------------------------

dead=""
while IFS= read -r ref; do
  case "$ref" in
    http://*|https://*|'#'*|mailto:*|data:*) continue ;;
  esac
  [ -e "$ROOT/docs/${ref%%#*}" ] || dead="$dead $ref"
done < <(grep -o -E '(href|src)="[^"]+"' "$PAGE" | sed -E 's/^(href|src)="//; s/"$//' | sort -u)
if [ -z "$dead" ]; then ok "every relative href/src resolves under docs/"; else bad "dead relative links" "$dead"; fi

undefined=""
while IFS= read -r id; do
  grep -q -E "^[[:space:]]+'$id': \{ t:" "$PAGE" || undefined="$undefined $id"
done < <(grep -o -E 'data-detail="[^"]+"' "$PAGE" | sed -E 's/^data-detail="//; s/"$//' | sort -u)
if [ -z "$undefined" ]; then ok "every data-detail id has a panel entry"; else bad "data-detail ids with no panel entry" "$undefined"; fi

# --- 2. PAGES -----------------------------------------------------------------

stale_pages='once (GitHub )?Pages is enabled|until then, open it from your clone'
for f in "$PAGE" "$DOCS_README"; do
  if grep -q -i -E "$stale_pages" "$f"; then
    bad "not-yet-live Pages phrasing in ${f#"$ROOT"/}" "$(grep -n -i -E "$stale_pages" "$f" | head -3)"
  else
    ok "no not-yet-live Pages phrasing in ${f#"$ROOT"/}"
  fi
done

# shellcheck disable=SC2016  # the backticks are literal markdown in the pattern
if grep -q -E 'http\.server' "$DOCS_README" && grep -q -E '\.nojekyll' "$DOCS_README" \
   && grep -q -F 'branch `main`' "$DOCS_README" && grep -q -F '`/docs`' "$DOCS_README"; then
  ok "docs/README.md documents the Pages source, static serving and local preview"
else
  bad "docs/README.md must name the Pages source (main + /docs), .nojekyll and a local preview (http.server)"
fi

# --- 3. CURRENCY ----------------------------------------------------------------

n_cad="$(jq '.cadences | length' "$REGISTRY")"
chip_n="$(grep -o -E 'Cadences \([0-9]+' "$PAGE" | grep -o -E '[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//')"
if [ "$chip_n" = "$n_cad" ]; then ok "cadence count on the page ($chip_n) = registry rows ($n_cad)"; else bad "cadence count on the page is '$chip_n', registry has $n_cad"; fi

missing=""
for id in $(jq -r '.cadences[].id' "$REGISTRY"); do
  grep -q -E "<b>$id</b>" "$PAGE" || missing="$missing $id"
done
if [ -z "$missing" ]; then ok "every registry cadence is named in the cadences panel"; else bad "registry cadences missing from the page" "$missing"; fi

if grep -q -i -E 'ollama|copilot' "$PAGE"; then
  bad "the wizard's lanes menu is codex + hermes only; page still mentions ollama/copilot" "$(grep -n -i -E 'ollama|copilot' "$PAGE" | head -3)"
else
  ok "page does not offer ollama/copilot as wizard lanes"
fi

if grep -q -E "fork of AgriciDaniel" "$PAGE"; then
  bad "claude-obsidian is upstream-pinned (fork retired), page still says fork"
else
  ok "claude-obsidian is not described as a himmel fork"
fi

text="$(tr '\n' ' ' <"$PAGE" | sed -E 's/<[^>]*>//g; s/[[:space:]]+/ /g')"
if printf '%s' "$text" | grep -q -E 'skip-hooks.{0,120}adopt\.sh'; then
  ok "--skip-hooks is attributed to scripts/adopt.sh"
else
  bad "--skip-hooks is an adopt.sh flag; himmelctl install rejects unknown flags, page must say where it lives"
fi

if grep -q -E '<b>lane</b>|Parallel lanes' "$PAGE"; then
  bad "Level 7 defines 'lane' as a work session; docs/glossary.md calls that a leg" "$(grep -n -E '<b>lane</b>|Parallel lanes' "$PAGE" | head -3)"
else
  ok "Level 7 uses the glossary's 'leg' for a work session"
fi

if grep -q -i -E 'up to eighteen|up to eleven' "$PAGE"; then
  bad "question counts are stale (7 always + up to 15 conditional = 22)" "$(grep -n -i -E 'up to eighteen|up to eleven' "$PAGE" | head -2)"
else
  ok "wizard question counts are not the stale eighteen/eleven"
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
