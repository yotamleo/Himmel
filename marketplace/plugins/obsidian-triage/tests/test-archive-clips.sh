#!/usr/bin/env bash
# Invariant + functional tests for /archive-clips (Stage 4, LUNA-55).
#
# Structural: the runbook declares the right tools/gates and the
# inbox-internal exclusions (_synthesis/_done/_deferred) are present in
# ALL FOUR pipeline runbooks.
# Functional: the eligibility gate, the boundary-safe link-rewrite, and
# the scan exclusion behave correctly on a temp vault.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CMD="$PLUGIN_DIR/commands/archive-clips.md"
CMDS="$PLUGIN_DIR/commands"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

echo "Test 1: archive-clips.md exists"
[ -r "$CMD" ] && exists=yes || exists=no
assert "$CMD exists" "yes" "$exists"
[ "$exists" = "no" ] && { echo "Results: $pass passed, $fail failed"; exit 1; }

echo "Test 2: frontmatter allowed-tools includes Edit + Write + Bash (move + rewrite need them)"
fm=$(awk '/^---$/{c++; next} c==1' "$CMD")
for tool in Edit Write Bash; do
    if printf '%s\n' "$fm" | grep -qE "^allowed-tools:.*\b$tool\b"; then found=yes; else found=no; fi
    assert "allowed-tools includes $tool" "yes" "$found"
done

echo "Test 3: dry-run hard gate + violation abort"
if grep -qE "DRY_RUN=1" "$CMD" && grep -qF "DRY-RUN CONTRACT VIOLATION" "$CMD"; then dry=yes; else dry=no; fi
assert "dry-run hard gate present" "yes" "$dry"

echo "Test 4: HIMMEL-128 — no headless claude invocation pattern"
# headless-claude-ok: the regex below is the detection pattern the test searches FOR; not an invocation
if grep -qE '^[^#>]*Bash:[[:space:]]*claude[[:space:]]+(-p|--print|--bg)' "$CMD"; then viol=yes; else viol=no; fi
assert "no Bash: claude invocation" "no" "$viol"

echo "Test 5: headless refusal (exit 3) + lockfile"
if grep -qE "CLAUDECODE_HEADLESS" "$CMD" && grep -qE "exit 3" "$CMD"; then hr=yes; else hr=no; fi
assert "headless refusal present" "yes" "$hr"
if grep -qF ".archive.lock" "$CMD"; then lk=yes; else lk=no; fi
assert "lockfile .archive.lock present" "yes" "$lk"

echo "Test 6: logging glyphs (✓ ⊘ ✗) present"
for g in "✓" "⊘" "✗"; do
    if grep -qF "$g" "$CMD"; then f=yes; else f=no; fi
    assert "glyph $g documented" "yes" "$f"
done

echo "Test 7: eligibility gate names all three conditions"
for cond in "harvested_at" "processed" "_synthesis"; do
    if grep -qF "$cond" "$CMD"; then f=yes; else f=no; fi
    assert "eligibility references $cond" "yes" "$f"
done

echo "Test 8: dedup by harvest_url_canonical documented"
if grep -qF "harvest_url_canonical" "$CMD"; then f=yes; else f=no; fi
assert "dedup uses harvest_url_canonical" "yes" "$f"

echo "Test 9: inbox exclusions present in ALL FOUR runbooks"
# harvest/triage/synthesize/archive must each exclude _synthesis, _done, _deferred.
for rb in harvest-clips.md triage-clips.md synthesize-clips.md archive-clips.md; do
    f="$CMDS/$rb"
    for excl in "_synthesis" "_done" "_deferred"; do
        if grep -qF "$excl" "$f"; then found=yes; else found=no; fi
        assert "$rb references exclusion $excl" "yes" "$found"
    done
    # The actual find flags must be present (not just prose mentions).
    if grep -qE "\-not -path '\*/_done/\*'" "$f"; then found=yes; else found=no; fi
    assert "$rb scan uses -not -path '*/_done/*'" "yes" "$found"
done

echo "Test 10: FUNCTIONAL — LITERAL boundary-safe link-rewrite on a REALISTIC clip id (metachars)"
# Regression guard for the C1 finding: a regex rewrite (sed -E) silently fails on clip ids
# containing + ( . space etc. The runbook mandates LITERAL replacement (Edit / bash ${//}).
# This test exercises the literal approach on a real-shaped id and asserts the verify is
# boundary-complete (all three of ]] | # forms), matching Phase 4 steps 5-6.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
OLD='@karpathy – 2026-05-25T031232+0200'        # real clip id: en-dash, space, + (regex metachar)
NEW="_done/2026-05/$OLD"
SIB="$OLD-extra"                                  # prefix-sibling that must NOT be touched
{
  printf -- '- plain [[Clippings/%s]]\n'        "$OLD"
  printf -- '- alias [[Clippings/%s|My Clip]]\n' "$OLD"
  printf -- '- heading [[Clippings/%s#Section]]\n' "$OLD"
  printf -- '- backref (from [[Clippings/%s]])\n' "$OLD"
  printf -- '- sibling [[Clippings/%s]]\n'       "$SIB"
} > "$tmp/note.md"

# Runbook Phase 4 step 5 — LITERAL replacement of the 3 boundary forms. bash ${//} is a
# fixed-string substitution (no regex), so the + and space in the id are handled correctly.
content="$(cat "$tmp/note.md")"
content="${content//"[[Clippings/$OLD]]"/"[[Clippings/$NEW]]"}"
content="${content//"[[Clippings/$OLD|"/"[[Clippings/$NEW|"}"
content="${content//"[[Clippings/$OLD#"/"[[Clippings/$NEW#"}"
printf '%s\n' "$content" > "$tmp/note.out"

# all 4 OLD occurrences rewritten despite the + and space in the id
rewritten=$(grep -cF "[[Clippings/$NEW" "$tmp/note.out")
assert "4 metachar-id links rewritten literally" "4" "$rewritten"
# prefix-sibling must NOT be clobbered
if grep -qF "[[Clippings/$SIB]]" "$tmp/note.out"; then fb=intact; else fb=clobbered; fi
assert "prefix-sibling link NOT clobbered" "intact" "$fb"
# alias + heading tails preserved
if grep -qF "[[Clippings/$NEW|My Clip]]" "$tmp/note.out"; then al=yes; else al=no; fi
assert "alias tail preserved on rewrite" "yes" "$al"
if grep -qF "[[Clippings/$NEW#Section]]" "$tmp/note.out"; then hd=yes; else hd=no; fi
assert "heading tail preserved on rewrite" "yes" "$hd"
# Phase 4 step-6 verify — LITERAL grep -F across all 3 OLD boundary forms = zero stale
stale=$(grep -cF -e "[[Clippings/$OLD]]" -e "[[Clippings/$OLD|" -e "[[Clippings/$OLD#" "$tmp/note.out")
assert "zero stale OLD links remain (literal boundary-complete verify)" "0" "$stale"

echo "Test 11: FUNCTIONAL — scan excludes _done/_synthesis/_deferred, keeps top-level AND subfolder clips"
tmp2="$(mktemp -d)"; trap 'rm -rf "$tmp" "$tmp2"' EXIT
mkdir -p "$tmp2/Clippings/_done/2026-05" "$tmp2/Clippings/_synthesis" "$tmp2/Clippings/2026-05"
printf -- '---\ntype: tweet\nharvested_at: 2026-05-29\nprocessed: true\n---\nbody\n' > "$tmp2/Clippings/real.md"
printf -- '---\ntype: tweet\nharvested_at: 2026-05-15\nprocessed: true\n---\nsub\n'  > "$tmp2/Clippings/2026-05/subclip.md"
printf -- '---\ntype: tweet\nharvested_at: 2026-05-01\nprocessed: true\n---\nold\n'  > "$tmp2/Clippings/_done/2026-05/archived.md"
printf -- '---\ntype: synthesis\n---\nproposal\n'                                    > "$tmp2/Clippings/_synthesis/concept.md"
printf -- '---\ntype: pipeline-deferred\n---\nbacklog\n'                             > "$tmp2/Clippings/_deferred.md"
scan="$(find "$tmp2/Clippings" -maxdepth 3 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md')"
if printf '%s\n' "$scan" | grep -qF "/real.md"; then f=yes; else f=no; fi
assert "scan keeps top-level inbox clip real.md" "yes" "$f"
if printf '%s\n' "$scan" | grep -qF "/2026-05/subclip.md"; then f=yes; else f=no; fi
assert "scan keeps subfolder clip 2026-05/subclip.md (maxdepth reaches it)" "yes" "$f"
for bad in "_done" "_synthesis" "_deferred.md"; do
    if printf '%s\n' "$scan" | grep -qF "$bad"; then f=leaked; else f=excluded; fi
    assert "scan excludes $bad" "excluded" "$f"
done

echo "Test 12: FUNCTIONAL — dedup canonical-URL index normalizes quotes (I3)"
# A quoted harvest_url_canonical in _done must match an unquoted value on an eligible clip,
# per the runbook's normalize (strip surrounding quotes on BOTH sides before comparing).
tmp3="$(mktemp -d)"; trap 'rm -rf "$tmp" "$tmp2" "$tmp3"' EXIT
mkdir -p "$tmp3/Clippings/_done/2026-05"
printf -- '---\nharvest_url_canonical: "https://x.com/a/status/1"\n---\nold\n' > "$tmp3/Clippings/_done/2026-05/done1.md"
grep -rhoE '^harvest_url_canonical:[[:space:]]*\S.*' "$tmp3/Clippings/_done/" 2>/dev/null \
  | sed -E 's/^harvest_url_canonical:[[:space:]]*//; s/^"//; s/"$//' | sort -u > "$tmp3/done-urls.txt"
elig_url="https://x.com/a/status/1"   # eligible clip's value, unquoted
if grep -qxF "$elig_url" "$tmp3/done-urls.txt"; then dq=match; else dq=miss; fi
assert "quoted _done url normalizes to match unquoted eligible url" "match" "$dq"

echo "Test 13: FUNCTIONAL — clip's OWN self-ref remaps to _done on graduation (LUNA-60)"
# Regression guard. /triage-clips Phase 6 appends a `## Promotion candidate` section to every
# clip it marks processed:true; its bi-temporal-anchor bullet carries a backticked example
# wikilink `[[Clippings/<OLD>]]` (NOT a frontmatter field — see triage-clips.md:166). The fixture
# string below is a paraphrase stand-in for that bullet, not derived from the live triage template.
# Archive Phase 4 step-3 grep (whole vault) matches that wikilink, so it returns the clip itself.
# If the self-ref is NOT remapped at the clip's NEW path after the move, the step-6 whole-vault
# verify counts the surviving self-ref as a stale link and falsely reverts. This simulates the fix:
# move the clip, then apply the literal rewrite to the moved clip at its dest path.
tmp4="$(mktemp -d)"; trap 'rm -rf "$tmp" "$tmp2" "$tmp3" "$tmp4"' EXIT
OLD4='@karpathy – 2026-05-25T031232+0200'      # real clip id with metachars
NEW4="_done/2026-05/$OLD4"
mkdir -p "$tmp4/Clippings/_done/2026-05" "$tmp4/30-Resources/Tech"
# the clip carries its own triage-Phase-6 self-ref in a Promotion candidate section
make_selfref_clip() {  # $1 = dest .md path
  {
    printf -- '---\ntype: tweet\nharvested_at: 2026-05-25\nprocessed: true\n---\n'
    printf -- 'body\n\n## Promotion candidate\n'
    # shellcheck disable=SC2016  # backtick text is literal markdown, not a command substitution
    printf -- '- **Bi-temporal anchor:** carry `derived_from: [[Clippings/%s]]` and fresh date.\n' "$OLD4"
  } > "$1"
}
# Phase 4 steps 4-5 simulation: move clip, then literal-rewrite each given file at its path.
# Asserts the move landed before rewriting (guards an unchecked-mv silent failure).
graduate() {  # $@ = files to rewrite (must include the moved clip's NEW path)
  mv "$tmp4/Clippings/$OLD4.md" "$tmp4/Clippings/$NEW4.md"
  [ -f "$tmp4/Clippings/$NEW4.md" ] && moved=yes || moved=no
  assert "moved clip exists at dest after mv (pre-rewrite guard)" "yes" "$moved"
  for f in "$@"; do
    [ -s "$f" ] || { assert "rewrite target $f non-empty" "yes" "no"; continue; }
    c="$(cat "$f")"
    c="${c//"[[Clippings/$OLD4]]"/"[[Clippings/$NEW4]]"}"
    c="${c//"[[Clippings/$OLD4|"/"[[Clippings/$NEW4|"}"
    c="${c//"[[Clippings/$OLD4#"/"[[Clippings/$NEW4#"}"
    printf '%s\n' "$c" > "$f"
  done
}
verify_clean() {  # whole-vault literal verify across all three boundary forms
  grep -rlF -e "[[Clippings/$OLD4]]" -e "[[Clippings/$OLD4|" -e "[[Clippings/$OLD4#" "$tmp4" --include='*.md' 2>/dev/null | wc -l | tr -d ' '
}

# --- Case A: clip self-ref + an external inbound note (the ordinary case) ---
make_selfref_clip "$tmp4/Clippings/$OLD4.md"
printf -- '- see [[Clippings/%s]]\n' "$OLD4" > "$tmp4/30-Resources/Tech/note.md"
hits_before=$(grep -rlF -e "[[Clippings/$OLD4]]" -e "[[Clippings/$OLD4|" -e "[[Clippings/$OLD4#" "$tmp4" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
assert "A: step-3 grep sees clip self-ref + inbound note (2 files)" "2" "$hits_before"
graduate "$tmp4/30-Resources/Tech/note.md" "$tmp4/Clippings/$NEW4.md"
if grep -qF "[[Clippings/$NEW4]]" "$tmp4/Clippings/$NEW4.md"; then sr=remapped; else sr=stale; fi
assert "A: moved clip self-ref remapped to _done path" "remapped" "$sr"
assert "A: zero stale OLD links after self-ref remap (no false revert)" "0" "$(verify_clean)"

# --- Case B: clip self-ref is the ONLY inbound link (no external note). This is the purest
# form of the LUNA-60 bug — the moved clip is the sole step-3 hit. Guards a future refactor
# that might skip the rewrite loop when there are no EXTERNAL inbound notes. ---
rm -f "$tmp4/30-Resources/Tech/note.md" "$tmp4/Clippings/$NEW4.md"
make_selfref_clip "$tmp4/Clippings/$OLD4.md"
hits_b=$(grep -rlF -e "[[Clippings/$OLD4]]" -e "[[Clippings/$OLD4|" -e "[[Clippings/$OLD4#" "$tmp4" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
assert "B: step-3 grep sees only the clip itself (1 file)" "1" "$hits_b"
graduate "$tmp4/Clippings/$NEW4.md"
assert "B: zero stale OLD links (self-ref-only graduates cleanly)" "0" "$(verify_clean)"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
