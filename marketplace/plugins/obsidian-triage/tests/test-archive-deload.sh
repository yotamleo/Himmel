#!/usr/bin/env bash
# Confirming test for LUNA-85: archive de-loaded as the drainer.
#
# Proves de-loaded default behavior after Phase 1:
# - structural: runbook prose states the reframed role
# - functional: eligibility scan never enumerates _evidence/
# - functional: a default run graduates 0 (synthesis-cited evidence clip stays in _evidence/)
#
# This is the key regression guard for plan-critic BLOCKER #1
# ("archive scoops fresh _evidence/ into _done/"): it proves archive
# leaves a processed, synthesis-cited _evidence/ clip alone.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CMD="$PLUGIN_DIR/commands/archive-clips.md"

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

# ── Structural: runbook prose reflects the de-loaded role ─────────────────────

echo "Test 1: runbook states inbox drains at triage (not archive)"
if grep -qF "drains at TRIAGE" "$CMD"; then f=yes; else f=no; fi
assert "archive-clips.md states inbox drains at triage" "yes" "$f"

echo "Test 2: runbook states graduation is optional terminal housekeeping"
if grep -qF "optional terminal housekeeping" "$CMD"; then f=yes; else f=no; fi
assert "archive-clips.md states graduation is optional terminal housekeeping" "yes" "$f"

echo "Test 3: runbook states archive is not the inbox drainer"
if grep -qF "not the inbox drainer" "$CMD"; then f=yes; else f=no; fi
assert "archive-clips.md states it is not the inbox drainer" "yes" "$f"

echo "Test 4: runbook explicitly states archive never reads _evidence/"
if grep -qF "never reads" "$CMD"; then f=yes; else f=no; fi
assert "archive-clips.md explicitly says never reads _evidence/" "yes" "$f"

echo "Test 5: _evidence/ exclusion present in archive eligibility scan command"
if grep -qF -- "-not -path '*/_evidence/*'" "$CMD"; then f=yes; else f=no; fi
assert "archive scan command contains _evidence/ exclusion" "yes" "$f"

echo "Test 6: runbook notes deferred Phase-2 opt-in (promoted_to: field)"
if grep -qF "promoted_to:" "$CMD"; then f=yes; else f=no; fi
assert "archive-clips.md notes deferred Phase-2 opt-in via promoted_to:" "yes" "$f"

# ── Functional: post-Phase-1 temp vault ────────────────────────────────────────
# Vault state: processed clips are in _evidence/ (LUNA-84 moved them there);
# only unprocessed stragglers remain at the top-level inbox.

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/Clippings/_evidence"
mkdir -p "$tmp/Clippings/_done/2026-05"
mkdir -p "$tmp/Clippings/_synthesis"

# Top-level unprocessed clip — inbox straggler (no processed:true)
printf -- '---\ntype: tweet\nharvested_at: 2026-06-01\n---\nnot yet processed\n' \
  > "$tmp/Clippings/new1.md"

# Processed, synthesis-cited clip that LUNA-84 already moved to _evidence/
printf -- '---\ntype: tweet\nharvested_at: 2026-05-25\nprocessed: true\nharvest_url_canonical: https://x.com/a/status/1\n---\nevidence body\n' \
  > "$tmp/Clippings/_evidence/ev1.md"

# Synthesis page that cites the evidence clip (by its _evidence/ path)
printf -- '---\ntype: synthesis\n---\n[[Clippings/_evidence/ev1]]\n' \
  > "$tmp/Clippings/_synthesis/s1.md"

# Pre-existing archived clip in _done/
printf -- '---\ntype: tweet\nharvested_at: 2026-05-01\nprocessed: true\n---\nold done\n' \
  > "$tmp/Clippings/_done/2026-05/old.md"

# _deferred.md
printf -- '---\ntype: pipeline-deferred\n---\nbacklog\n' \
  > "$tmp/Clippings/_deferred.md"

# ── Run the archive canonical scan (EXACT flag string from the runbook) ────────

scan_out="$(find "$tmp/Clippings" -maxdepth 3 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
  -not -path '*/_evidence/*' -print0 | tr '\0' '\n')"

echo "Test 7: eligibility scan excludes _evidence/ paths"
if printf '%s\n' "$scan_out" | grep -qF "/_evidence/"; then f=leaked; else f=excluded; fi
assert "eligibility scan excludes _evidence/ paths" "excluded" "$f"

echo "Test 8: eligibility scan sees top-level unprocessed clip (new1.md)"
if printf '%s\n' "$scan_out" | grep -qF "/new1.md"; then f=yes; else f=no; fi
assert "eligibility scan sees top-level new1.md" "yes" "$f"

# Test 9 is three sub-checks (one per inbox-internal name), not a single assert.
echo "Test 9: eligibility scan excludes _done/, _synthesis/, _deferred.md (3 sub-checks)"
for bad in "_done" "_synthesis" "_deferred.md"; do
    if printf '%s\n' "$scan_out" | grep -qF "$bad"; then f=leaked; else f=excluded; fi
    assert "scan excludes $bad" "excluded" "$f"
done

echo "Test 10: ev1.md (processed + synthesis-cited) is NOT in the scan set"
# ev1.md is eligible by the 3 criteria, but _evidence/ guard keeps it invisible.
# Even though the synthesis page cites it, archive cannot see it to graduate it.
if printf '%s\n' "$scan_out" | grep -qF "_evidence/ev1.md"; then f=visible; else f=excluded; fi
assert "ev1.md excluded from scan despite being processed+cited" "excluded" "$f"

echo "Test 11: new1.md in scan set lacks processed:true (cannot be eligible)"
if grep -qE '^processed:[[:space:]]*true' "$tmp/Clippings/new1.md"; then has_proc=yes; else has_proc=no; fi
assert "new1.md lacks processed:true (ineligible straggler)" "no" "$has_proc"

echo "Test 12: default run graduates 0 — no clip in the scan set meets all 3 criteria"
# Compute archive eligibility (harvested_at + processed:true + synthesis-cited)
# over the SCAN SET (which excludes _evidence/).
# Expected: zero clips qualify.
eligible_count=0
while IFS= read -r clip; do
    [ -z "$clip" ] && continue
    # Condition 1: harvested_at
    grep -qE '^harvested_at:[[:space:]]*\S' "$clip" || continue
    # Condition 2: processed:true
    grep -qE '^processed:[[:space:]]*true[[:space:]]*$' "$clip" || continue
    # Condition 3: in synthesis refs (Phase 1 index)
    synth_refs="$(grep -rhoE '\[\[Clippings/[^]|#]+' "$tmp/Clippings/_synthesis/" 2>/dev/null \
      | sed -E 's/^\[\[Clippings\///' | sort -u)"
    base_no_ext="$(basename "$clip" .md)"
    rel_no_ext="${clip#"$tmp/Clippings/"}"
    rel_no_ext="${rel_no_ext%.md}"
    if printf '%s\n' "$synth_refs" | grep -qxF "$rel_no_ext" 2>/dev/null; then :; \
    elif printf '%s\n' "$synth_refs" | grep -qxF "$base_no_ext" 2>/dev/null; then :; \
    else continue; fi
    eligible_count=$((eligible_count+1))
done <<EOF
$(find "$tmp/Clippings" -maxdepth 3 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
  -not -path '*/_evidence/*')
EOF
assert "default run graduates 0 (no eligible clip in scan set)" "0" "$eligible_count"

echo "Test 13: synthesis-cited _evidence/ev1.md stays in _evidence/ (placement check; T12 is the BLOCKER-#1 graduation guard)"
# Companion to T12: confirms the _evidence/ clip is physically left in place
# (not relocated into _done/). T12 is the authoritative "graduates 0" guard.
[ -f "$tmp/Clippings/_evidence/ev1.md" ] && still_there=yes || still_there=no
assert "_evidence/ev1.md remains in _evidence/" "yes" "$still_there"

if find "$tmp/Clippings/_done" -name "ev1.md" 2>/dev/null | grep -q .; then in_done=yes; else in_done=no; fi
assert "_evidence/ev1.md NOT found in _done/ (archive did not scoop it)" "no" "$in_done"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
