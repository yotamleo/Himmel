#!/usr/bin/env bash
# Functional tests for tools/triage-mark-processed.py (HIMMEL-4685) — the ONE
# path /triage-clips may use to mark a clip processed (Phase 7) and move it to
# Clippings/_evidence/ (Phase 8). The 2026-10-07 cadence run fanned triage out
# to parallel subagents that marked and moved clips through their own helpers,
# skipping the stale-read SHA check and the ln-based move. These tests pin the
# tool's refusals (no SHA, wrong SHA) and its end state on a hermetic temp
# vault. Fixtures only — never the live vault.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$SCRIPT_DIR/../tools/triage-mark-processed.py"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

sha_of() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
has_line() { if grep -qxF -- "$2" "$1"; then echo yes; else echo no; fi; }

# make_vault <dir>: a vault with a metachar clip id in a date subfolder, an
# inbound daily-note backref (plain + .md forms), a prefix sibling, and the
# Phase-6 self-ref.
ID='@karpathy – 2026-05-25T031232+0200'
make_vault() {
    local v="$1"
    mkdir -p "$v/Clippings/2026-05" "$v/50-Journal/Daily"
    {
        printf -- '---\ntitle: t\ntype: article\nsource: https://example.com/a\ntags:\n  - agents\n---\n'
        printf -- 'body\n\n## Promotion candidate\n'
        # shellcheck disable=SC2016  # backticks are literal markdown
        printf -- '- **Bi-temporal anchor:** carry `derived_from: "[[Clippings/2026-05/%s]]"`\n' "$ID"
    } > "$v/Clippings/2026-05/$ID.md"
    {
        printf -- '---\ndate: 2026-05-25\n---\n\n## Actions from clips\n'
        printf -- '- [ ] do thing (from [[Clippings/2026-05/%s]])\n' "$ID"
        printf -- '- see [[Clippings/2026-05/%s.md|alias]]\n' "$ID"
        printf -- '- sibling [[Clippings/2026-05/%s-extra]]\n' "$ID"
    } > "$v/50-Journal/Daily/2026-05-25.md"
}

if [ ! -f "$TOOL" ]; then
    echo "  FAIL  tool missing: $TOOL (every mark/move must go through it)"
    fail=$((fail+1))
    echo ""
    echo "Results: $pass passed, $fail failed"
    exit 1
fi

echo "Test 1: a move WITHOUT the SHA is refused (the subagent-helper bypass)"
V="$TMP/v1"; make_vault "$V"; CLIP="$V/Clippings/2026-05/$ID.md"
before="$(sha_of "$CLIP")"
python3 "$TOOL" "$V" "$CLIP" >/dev/null 2>&1; rc=$?
assert "no --expect-sha exits 2" "2" "$rc"
assert "clip untouched" "$before" "$(sha_of "$CLIP")"
assert "nothing moved to _evidence/" "no" "$([ -e "$V/Clippings/_evidence/$ID.md" ] && echo yes || echo no)"

echo "Test 2: a malformed SHA is refused"
python3 "$TOOL" "$V" "$CLIP" --expect-sha "not-a-sha" >/dev/null 2>&1; rc=$?
assert "malformed --expect-sha exits 2" "2" "$rc"
assert "clip untouched" "$before" "$(sha_of "$CLIP")"

echo "Test 3: stale read (clip edited after LAST_WRITE_SHA) is refused"
printf 'operator edit\n' >> "$CLIP"
edited="$(sha_of "$CLIP")"
out="$(python3 "$TOOL" "$V" "$CLIP" --expect-sha "$before" 2>&1)"; rc=$?
assert "stale SHA exits 3" "3" "$rc"
case "$out" in *"stale read"*) r=ok ;; *) r="$out" ;; esac
assert "message names the stale read" "ok" "$r"
assert "edited clip not clobbered" "$edited" "$(sha_of "$CLIP")"
assert "no processed marker written" "no" "$(has_line "$CLIP" "processed: true")"
assert "nothing moved to _evidence/" "no" "$([ -e "$V/Clippings/_evidence/$ID.md" ] && echo yes || echo no)"

echo "Test 4: correct SHA marks, moves via link, rewrites links, clears the debt"
V="$TMP/v4"; make_vault "$V"; CLIP="$V/Clippings/2026-05/$ID.md"
out="$(python3 "$TOOL" "$V" "$CLIP" --expect-sha "$(sha_of "$CLIP")" --today 2026-10-07 --summary-basis url-only 2>&1)"; rc=$?
assert "exit 0" "0" "$rc"
DEST="$V/Clippings/_evidence/$ID.md"
assert "source name gone" "no" "$([ -e "$CLIP" ] && echo yes || echo no)"
assert "destination present" "yes" "$([ -f "$DEST" ] && echo yes || echo no)"
assert "single directory entry (no alias left)" "1" "$(stat -c %h "$DEST" 2>/dev/null || stat -f %l "$DEST")"
assert "processed: true" "yes" "$(has_line "$DEST" "processed: true")"
assert "triaged_at" "yes" "$(has_line "$DEST" "triaged_at: 2026-10-07")"
assert "summary_basis: url-only flagged" "yes" "$(has_line "$DEST" "summary_basis: url-only")"
assert "evidence_kind written" "yes" "$(has_line "$DEST" "evidence_kind:")"
assert "evidence_pending cleared at the commit point" "no" "$(grep -q '^evidence_pending:' "$DEST" && echo yes || echo no)"
assert "evidence_origin cleared at the commit point" "no" "$(grep -q '^evidence_origin:' "$DEST" && echo yes || echo no)"
DN="$V/50-Journal/Daily/2026-05-25.md"
assert "plain backref rewritten" "yes" "$(grep -qF "[[Clippings/_evidence/$ID]]" "$DN" && echo yes || echo no)"
assert ".md alias form rewritten" "yes" "$(grep -qF "[[Clippings/_evidence/$ID.md|alias]]" "$DN" && echo yes || echo no)"
assert "prefix sibling untouched" "yes" "$(grep -qF "[[Clippings/2026-05/$ID-extra]]" "$DN" && echo yes || echo no)"
assert "self-ref remapped in the moved clip" "yes" "$(grep -qF "[[Clippings/_evidence/$ID]]" "$DEST" && echo yes || echo no)"
case "$out" in *"3 links rewritten"*) r=ok ;; *) r="$out" ;; esac
assert "reports the rewritten-link count (daily x2 + self-ref)" "ok" "$r"
fm_end=$(awk 'NR>1 && /^---[[:space:]]*$/ {print NR; exit}' "$DEST")
tags_line=$(grep -n '^tags:' "$DEST" | cut -d: -f1)
proc_line=$(grep -n '^processed: true$' "$DEST" | cut -d: -f1)
assert "processed: true lands after the tags block, inside frontmatter" "yes" \
  "$([ "$proc_line" -gt "$tags_line" ] && [ "$proc_line" -lt "$fm_end" ] && echo yes || echo no)"

echo "Test 5: an already-processed clip is refused on the SHA path"
out="$(python3 "$TOOL" "$V" "$DEST" --expect-sha "$(sha_of "$DEST")" 2>&1)"; rc=$?
assert "re-mark exits 4" "4" "$rc"

echo "Test 6: ig_media_pending hold marks but does not move"
V="$TMP/v6"; mkdir -p "$V/Clippings"
printf -- '---\ntitle: r\ntype: instagram\nsource: https://instagram.com/p/x\nig_media_pending: true\n---\nbody\n' > "$V/Clippings/reel.md"
python3 "$TOOL" "$V" "$V/Clippings/reel.md" --expect-sha "$(sha_of "$V/Clippings/reel.md")" >/dev/null 2>&1; rc=$?
assert "held exits 10" "10" "$rc"
assert "stays in inbox" "yes" "$([ -f "$V/Clippings/reel.md" ] && echo yes || echo no)"
assert "marked processed" "yes" "$(has_line "$V/Clippings/reel.md" "processed: true")"
assert "debt recorded" "yes" "$(has_line "$V/Clippings/reel.md" "evidence_pending: true")"

echo "Test 7: --drain refuses a clip that was never processed"
printf -- '---\ntitle: u\ntype: article\nevidence_pending: true\n---\nbody\n' > "$V/Clippings/unproc.md"
python3 "$TOOL" "$V" "$V/Clippings/unproc.md" --drain >/dev/null 2>&1; rc=$?
assert "drain of unprocessed clip exits 4" "4" "$rc"
assert "unprocessed clip not moved" "yes" "$([ -f "$V/Clippings/unproc.md" ] && echo yes || echo no)"

echo "Test 8: --drain completes a held clip once the hold clears"
sed -i.bak '/^ig_media_pending:/d' "$V/Clippings/reel.md" && rm -f "$V/Clippings/reel.md.bak"
python3 "$TOOL" "$V" "$V/Clippings/reel.md" --drain >/dev/null 2>&1; rc=$?
assert "drain exits 0" "0" "$rc"
assert "drained clip in _evidence/" "yes" "$([ -f "$V/Clippings/_evidence/reel.md" ] && echo yes || echo no)"
assert "drained clip debt cleared" "no" "$(grep -q '^evidence_pending:' "$V/Clippings/_evidence/reel.md" && echo yes || echo no)"

echo "Test 9: a collision is reported forward-only, never clobbered"
V="$TMP/v9"; mkdir -p "$V/Clippings/_evidence"
printf 'incumbent\n' > "$V/Clippings/_evidence/dup.md"
printf -- '---\ntitle: d\ntype: article\n---\nbody\n' > "$V/Clippings/dup.md"
out="$(python3 "$TOOL" "$V" "$V/Clippings/dup.md" --expect-sha "$(sha_of "$V/Clippings/dup.md")" 2>&1)"; rc=$?
assert "collision exits 5" "5" "$rc"
assert "incumbent intact" "incumbent" "$(cat "$V/Clippings/_evidence/dup.md")"
assert "challenger still in inbox" "yes" "$([ -f "$V/Clippings/dup.md" ] && echo yes || echo no)"
assert "challenger keeps the debt marker" "yes" "$(has_line "$V/Clippings/dup.md" "evidence_pending: true")"

echo "Test 10: ambiguous .md identifier is refused before any move"
V="$TMP/v10"; mkdir -p "$V/Clippings"
printf -- '---\ntitle: f\ntype: article\n---\nbody\n' > "$V/Clippings/foo.md"
printf -- '---\ntitle: g\ntype: article\n---\nbody\n' > "$V/Clippings/foo.md.md"
python3 "$TOOL" "$V" "$V/Clippings/foo.md" --expect-sha "$(sha_of "$V/Clippings/foo.md")" >/dev/null 2>&1; rc=$?
assert "ambiguity exits 5" "5" "$rc"
assert "ambiguous clip not moved" "yes" "$([ -f "$V/Clippings/foo.md" ] && echo yes || echo no)"

echo "Test 11: --dry-run writes nothing"
V="$TMP/v11"; make_vault "$V"; CLIP="$V/Clippings/2026-05/$ID.md"
before="$(sha_of "$CLIP")"
dn_before="$(sha_of "$V/50-Journal/Daily/2026-05-25.md")"
out="$(python3 "$TOOL" "$V" "$CLIP" --expect-sha "$before" --dry-run 2>&1)"; rc=$?
assert "dry-run exits 0" "0" "$rc"
assert "clip unchanged" "$before" "$(sha_of "$CLIP")"
assert "daily note unchanged" "$dn_before" "$(sha_of "$V/50-Journal/Daily/2026-05-25.md")"
assert "no _evidence/ created" "no" "$([ -e "$V/Clippings/_evidence" ] && echo yes || echo no)"

echo "Test 12: hostile id (quote + ' #') round-trips through evidence_origin"
V="$TMP/v12"; mkdir -p "$V/Clippings/sub" "$V/Notes"
HID="it's a #topic"
printf -- '---\ntitle: h\ntype: article\n---\nbody\n' > "$V/Clippings/sub/$HID.md"
printf -- 'see [[Clippings/sub/%s]]\n' "$HID" > "$V/Notes/n.md"
python3 "$TOOL" "$V" "$V/Clippings/sub/$HID.md" --expect-sha "$(sha_of "$V/Clippings/sub/$HID.md")" >/dev/null 2>&1; rc=$?
assert "hostile id exits 0" "0" "$rc"
assert "hostile-id link rewritten" "yes" "$(grep -qF "[[Clippings/_evidence/$HID]]" "$V/Notes/n.md" && echo yes || echo no)"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
