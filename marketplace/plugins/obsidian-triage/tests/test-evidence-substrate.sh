#!/usr/bin/env bash
# Invariant + functional tests for the _evidence/ scan guard (LUNA-83).
#
# Structural: verify -not -path '*/_evidence/*' IS present in
# harvest/triage/archive runbooks and ABSENT from synthesize-clips.md.
# Functional: build a temp vault and assert the find patterns behave
# exactly as the runbooks specify.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CMDS="$PLUGIN_DIR/commands"

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

# ── Structural: _evidence/ guard present in harvest/triage/archive ──────────

echo "Test 1: -not -path '*/_evidence/*' in harvest-clips.md"
if grep -qF -- "-not -path '*/_evidence/*'" "$CMDS/harvest-clips.md"; then f=yes; else f=no; fi
assert "harvest-clips.md has _evidence/ scan guard" "yes" "$f"

echo "Test 2: -not -path '*/_evidence/*' in triage-clips.md"
if grep -qF -- "-not -path '*/_evidence/*'" "$CMDS/triage-clips.md"; then f=yes; else f=no; fi
assert "triage-clips.md has _evidence/ scan guard" "yes" "$f"

echo "Test 3: -not -path '*/_evidence/*' in archive-clips.md"
if grep -qF -- "-not -path '*/_evidence/*'" "$CMDS/archive-clips.md"; then f=yes; else f=no; fi
assert "archive-clips.md has _evidence/ scan guard" "yes" "$f"

echo "Test 4: -not -path '*/_evidence/*' ABSENT from synthesize-clips.md (synthesize sees _evidence/)"
if grep -qF -- "-not -path '*/_evidence/*'" "$CMDS/synthesize-clips.md"; then f=present; else f=absent; fi
assert "synthesize-clips.md does NOT have _evidence/ guard (correct)" "absent" "$f"

# ── Structural: prose note about _evidence/ present in guarded runbooks ──────

echo "Test 5: _evidence/ prose note in harvest-clips.md"
if grep -qF "_evidence/" "$CMDS/harvest-clips.md"; then f=yes; else f=no; fi
assert "harvest-clips.md mentions _evidence/ in prose" "yes" "$f"

echo "Test 6: _evidence/ prose note in triage-clips.md"
if grep -qF "_evidence/" "$CMDS/triage-clips.md"; then f=yes; else f=no; fi
assert "triage-clips.md mentions _evidence/ in prose" "yes" "$f"

echo "Test 7: _evidence/ prose note in archive-clips.md"
if grep -qF "_evidence/" "$CMDS/archive-clips.md"; then f=yes; else f=no; fi
assert "archive-clips.md mentions _evidence/ in prose" "yes" "$f"

# ── Functional: temp vault with all folder types ──────────────────────────────

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/Clippings/_evidence/_rejected"
mkdir -p "$tmp/Clippings/_done/2026-05"
mkdir -p "$tmp/Clippings/_synthesis"

printf -- '---\ntype: article\n---\nreal clip\n'      > "$tmp/Clippings/real.md"
printf -- '---\ntype: article\n---\nevidence clip\n'  > "$tmp/Clippings/_evidence/ev1.md"
printf -- '---\ntype: article\n---\nrejected\n'       > "$tmp/Clippings/_evidence/_rejected/rej.md"
printf -- '---\ntype: article\n---\ndone clip\n'      > "$tmp/Clippings/_done/2026-05/old.md"
printf -- '---\ntype: synthesis\n---\nproposal\n'     > "$tmp/Clippings/_synthesis/c.md"
printf -- '---\ntype: pipeline-deferred\n---\nlog\n'  > "$tmp/Clippings/_deferred.md"

echo "Test 8: harvest/triage scan (maxdepth 2) excludes _evidence/, _done/, _synthesis/, _deferred.md; keeps real.md"
# This is the EXACT flag string from harvest-clips.md and triage-clips.md
harvest_scan="$(find "$tmp/Clippings" -maxdepth 2 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
  -not -path '*/_evidence/*')"

if printf '%s\n' "$harvest_scan" | grep -qF "/real.md"; then f=yes; else f=no; fi
assert "harvest/triage scan keeps real.md" "yes" "$f"

if printf '%s\n' "$harvest_scan" | grep -qF "/_evidence/"; then f=leaked; else f=excluded; fi
assert "harvest/triage scan excludes _evidence/" "excluded" "$f"

if printf '%s\n' "$harvest_scan" | grep -qF "/_done/"; then f=leaked; else f=excluded; fi
assert "harvest/triage scan excludes _done/" "excluded" "$f"

if printf '%s\n' "$harvest_scan" | grep -qF "/_synthesis/"; then f=leaked; else f=excluded; fi
assert "harvest/triage scan excludes _synthesis/" "excluded" "$f"

if printf '%s\n' "$harvest_scan" | grep -qF "_deferred.md"; then f=leaked; else f=excluded; fi
assert "harvest/triage scan excludes _deferred.md" "excluded" "$f"

echo "Test 9: archive scan (maxdepth 3) excludes _evidence/ (incl. _rejected/); keeps real.md"
# This is the EXACT flag string from archive-clips.md
archive_scan="$(find "$tmp/Clippings" -maxdepth 3 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
  -not -path '*/_evidence/*')"

if printf '%s\n' "$archive_scan" | grep -qF "/real.md"; then f=yes; else f=no; fi
assert "archive scan keeps real.md" "yes" "$f"

if printf '%s\n' "$archive_scan" | grep -qF "/_evidence/ev1.md"; then f=leaked; else f=excluded; fi
assert "archive scan excludes _evidence/ev1.md" "excluded" "$f"

if printf '%s\n' "$archive_scan" | grep -qF "/_rejected/"; then f=leaked; else f=excluded; fi
assert "archive scan excludes _evidence/_rejected/ (subdir)" "excluded" "$f"

echo "Test 10: synthesize-style scan (maxdepth 3, NO _evidence/ guard) DOES include ev1.md"
# synthesize deliberately keeps visibility into _evidence/
synth_scan="$(find "$tmp/Clippings" -maxdepth 3 -type f -name '*.md' \
  -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md')"

if printf '%s\n' "$synth_scan" | grep -qF "/_evidence/ev1.md"; then f=visible; else f=missing; fi
assert "synthesize scan includes _evidence/ev1.md (intentionally)" "visible" "$f"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -gt 0 ] && exit 1 || exit 0
