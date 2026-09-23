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

# The prose spells the count out ("eight cadences", "eight rows"): derive the
# word from the registry too, so every count the page displays is checked.
case "$n_cad" in
  1) n_word=one ;; 2) n_word=two ;; 3) n_word=three ;; 4) n_word=four ;; 5) n_word=five ;;
  6) n_word=six ;; 7) n_word=seven ;; 8) n_word=eight ;; 9) n_word=nine ;; 10) n_word=ten ;;
  11) n_word=eleven ;; 12) n_word=twelve ;; *) n_word="" ;;
esac
if [ -z "$n_word" ]; then
  bad "registry has $n_cad cadences; extend the number-word table in this suite"
elif grep -q -F "pick which of the $n_word <b>cadences</b>" "$PAGE" && grep -q -F "— $n_word rows:" "$PAGE"; then
  ok "spelled-out cadence counts on the page ($n_word) = registry rows ($n_cad)"
else
  bad "the page's prose cadence counts ('pick which of the N cadences', 'N rows:') must read '$n_word' (registry has $n_cad)"
fi

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
skip_hooks_hit="$(printf '%s' "$text" | grep -o -E 'skip-hooks.{0,120}adopt\.sh')"
if [ -n "$skip_hooks_hit" ]; then
  ok "--skip-hooks is attributed to scripts/adopt.sh"
else
  bad "--skip-hooks is an adopt.sh flag; himmelctl install rejects unknown flags, page must say where it lives"
fi

if grep -q -E '<b>lane</b>|Parallel lanes' "$PAGE"; then
  bad "Level 7 defines 'lane' as a work session; docs/glossary.md calls that a leg" "$(grep -n -E '<b>lane</b>|Parallel lanes' "$PAGE" | head -3)"
else
  ok "Level 7 uses the glossary's 'leg' for a work session"
fi

# ponytail: the wizard's questions are asked by an imperative flow in
# scripts/himmelctl/bin.js (no question table to count), so the expected 7 /
# 22 / 15 are pinned here from the verified read, not derived. The pin fails
# on removal or a changed number, but a wizard that gains a question still
# needs this line and the page updated by hand.
if grep -q -i -E 'up to eighteen|up to eleven' "$PAGE"; then
  bad "question counts are stale (7 always + up to 15 conditional = 22)" "$(grep -n -i -E 'up to eighteen|up to eleven' "$PAGE" | head -2)"
elif grep -q -F 'Seven questions are always asked, and up to twenty-two in total' "$PAGE" \
     && grep -q -F 'up to fifteen more' "$PAGE"; then
  ok "wizard question counts on the page are seven always / twenty-two total / fifteen conditional"
else
  bad "the page must state the wizard question counts (seven always, up to twenty-two in total, up to fifteen conditional)"
fi

# adopt.sh's install_precommit_hooks runs for every profile (HIMMEL-2441), so the
# git gates are no longer roadmap; a "Gates for every profile" roadmap chip or
# panel would contradict the page's own "wired by the install" sentence.
gates_roadmap='rm-gates|Gates for every profile|roadmap gates item|arrive with the developer setup'
if grep -q -i -E "$gates_roadmap" "$PAGE"; then
  bad "the commit/push gates install for every profile (adopt.sh install_precommit_hooks); the page still lists them as roadmap" "$(grep -n -i -E "$gates_roadmap" "$PAGE" | head -3)"
else
  ok "the git gates are not listed as roadmap work"
fi

# HIMMEL-3329: an uninstall leaves a few settings.json keys behind on purpose (the
# claude CLI's empty enabledPlugins / extraKnownMarketplaces objects, an empty hooks
# object, and the HUD gate key when no install record says himmel wrote it). The
# "Removed" list says only himmel's own wiring goes, so the "Kept on purpose" list
# must name each one — a reader cannot otherwise tell it is himmel's.
kept="$(sed -n '/<h4>Kept on purpose<\/h4>/,/<\/ul>/p' "$PAGE" | tr '\n' ' ' | sed -E 's/<[^>]*>//g; s/[[:space:]]+/ /g')"
kept_missing=""
for key in CLAUDE_HUD_ALLOW_EXTRA_CMD enabledPlugins extraKnownMarketplaces 'hooks'; do
  grep -q -F -- "$key" <<< "$kept" || kept_missing="$kept_missing $key"
done
if [ -z "$kept_missing" ]; then
  ok "the Kept-on-purpose list names the settings.json residue an uninstall leaves"
else
  bad "the Kept-on-purpose list must name the settings.json residue (HIMMEL-3329)" "missing:$kept_missing"
fi

# HIMMEL-3332 slice 3: qmd is ledger-decided (kept by default; --purge-state
# removes only units this install's own record shows it created), and the
# plugin-cache stub patch is a separate, permanent keep that is never
# reverted even under --purge-state. Both must be named where a reader
# would look: the Kept-on-purpose list and the qmd detail panel.
if grep -q -F -- '--purge-state' <<< "$kept" && grep -q -i -F 'qmd fork checkout' <<< "$kept"; then
  ok "the Kept-on-purpose list states qmd's ledger-decided default-keep / --purge-state rule"
else
  bad "the Kept-on-purpose list must state qmd is kept by default and removed only under --purge-state for units this install created"
fi
if grep -q -i -F 'stub' <<< "$kept" && grep -q -F -- '--purge-state' <<< "$kept"; then
  ok "the Kept-on-purpose list names the qmd plugin-cache stub patch as a permanent keep"
else
  bad "the Kept-on-purpose list must name the qmd plugin-cache stub patch as never reverted"
fi

qmd_panel="$(sed -n "/^    'qmd': { t:/,/' },\$/p" "$PAGE" | tr '\n' ' ' | sed -E 's/<[^>]*>//g; s/[[:space:]]+/ /g')"
if grep -q -F -- '--purge-state' <<< "$qmd_panel"; then
  ok "the qmd detail panel states the --purge-state keep/remove rule"
else
  bad "the qmd detail panel must state the --purge-state keep/remove rule"
fi

# --- 4. FRESH-USER (HIMMEL-2476) -----------------------------------------------

# The three first questions (what is this / what will it do to my machine /
# how do I undo it) must be answered before the reader meets the first
# command that actually invokes the installer -- otherwise a fresh reader can
# copy-paste an install before they know how to undo it. It is not enough to
# check that the install command comes after the Question 3 HEADING: it must
# come after the undo guidance is fully stated, and it must still be part of
# Question 3's own answer (not have drifted into a later section). Find the
# line where the "undo" answer div actually closes by depth-counting <div>
# tags from its opening tag, then require the install command to fall on or
# before that close (inside Question 3) and after the div opened (after the
# undo guidance).
q3_line="$(grep -n -F 'qno">Question 3' "$PAGE" | head -1 | cut -d: -f1)"
q3_end_line="$(awk '
  /id="undo"/ { instart=1 }
  instart {
    line=$0
    opens = gsub(/<div /,"<div ", line)
    closes = gsub(/<\/div>/,"<\/div>", line)
    depth += opens - closes
    if (depth <= 0) { print NR; exit }
  }
' "$PAGE")"
install_cmd_line="$(grep -n -E 'adopt\.sh --profile|himmelctl/bin\.js install' "$PAGE" | head -1 | cut -d: -f1)"
if [ -n "$q3_line" ] && [ -n "$q3_end_line" ] && [ -n "$install_cmd_line" ] && [ "$install_cmd_line" -gt "$q3_line" ] && [ "$install_cmd_line" -le "$q3_end_line" ]; then
  ok "the three first questions are answered above the first install command, which stays inside question 3"
else
  bad "an install command appears before question 3 (undo) is fully answered, or outside its answer" "question3=line $q3_line, question3 answer ends=line $q3_end_line, first install command=line $install_cmd_line"
fi

# No internal ticket key in reader-facing prose. A code comment
# (<!-- ... -->) or a data attribute is fine; strip both before checking, as
# the LINKS section above already strips markup for its own checks. A greedy
# same-line sed match (`<!--.*-->`) can span two separate comments on one
# line and eat the visible text between them, and it cannot see a comment
# that spans multiple lines at all; use a non-greedy, whole-file match
# instead so each comment is removed independently.
reader_text="$(perl -0777 -pe 's/<!--.*?-->//gs' "$PAGE" | sed -E 's/<[a-zA-Z][^>]*>//g')"
ticket_hits="$(printf '%s' "$reader_text" | grep -o -E 'HIMMEL-[0-9]+' | sort -u | tr '\n' ' ')"
if [ -z "$ticket_hits" ]; then
  ok "no internal ticket key in reader-facing text"
else
  bad "internal ticket key(s) in reader-facing text" "$ticket_hits"
fi

echo
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
