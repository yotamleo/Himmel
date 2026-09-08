#!/usr/bin/env bash
# Invariant tests for /triage-clips.
#
# Scope: validates the bash-checkable invariants the command must hold,
# without invoking the LLM agent itself. The agent's behavior is tested
# during calibration on real clips — these are the structural guards
# that should hold for any future agent implementation:
#
#   1. Scan helper correctly partitions files by `processed: true` line.
#   2. Frontmatter mutation contract: appending `processed: true` after
#      existing keys + block-list values lands at zero-indent (NOT
#      inside any list).
#   3. Dedup-by-backreference helper: detects whether a clip's Phase-5
#      backref is already present in a daily-note simulation.
#   4. Multi-line `tags:` block-list fixture is recognized by the scan.
#
# Portable bash. Verified on Git Bash for Windows (the `grep -L` and
# `grep -q` exit-code quirks are worked around explicitly below).

# NOTE: do NOT use `set -e`. `grep -L` returns nonzero on Git Bash
# (Windows) even when files print. We use explicit assert() instead.
# `set -o pipefail` IS safe — it catches LHS pipeline failures that
# `set -e` alone would also catch, without the grep-exit-code issue.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="${SCRIPT_DIR}/fixtures/clips"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Pre-flight: fixtures dir exists and is non-empty.
if [ ! -d "$FIXTURES" ]; then
    echo "PRE-FLIGHT FAIL: fixtures dir missing: $FIXTURES"
    exit 1
fi
if [ -z "$(ls -A "$FIXTURES"/*.md 2>/dev/null)" ]; then
    echo "PRE-FLIGHT FAIL: no *.md fixtures in $FIXTURES"
    exit 1
fi

# Count files that LACK a given pattern. Portable wrapper around grep -L
# whose exit code differs across grep builds (Git Bash returns 1 even
# when files are listed, GNU returns 0). Distinguishes:
#   rc=0  match found        → file HAS pattern, don't count
#   rc=1  no match           → file LACKS pattern, count it
#   rc=2  file error / other → bail out with a clear error
count_files_without_pattern() {
    local pattern="$1"
    shift
    local n=0
    local rc
    for f in "$@"; do
        if [ ! -r "$f" ]; then
            echo "  ERROR  count_files_without_pattern: unreadable file: $f" >&2
            return 2
        fi
        grep -q "$pattern" "$f"
        rc=$?
        case "$rc" in
            0) ;;            # match — file has pattern
            1) n=$((n+1)) ;; # no match — file lacks pattern
            *)
                echo "  ERROR  grep rc=$rc on: $f" >&2
                return 2
                ;;
        esac
    done
    echo "$n"
}

assert() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

# Set up: copy fixtures to a temp Clippings/ folder so we don't
# mutate the committed fixtures.
mkdir -p "$TMP/Clippings"
cp "$FIXTURES"/*.md "$TMP/Clippings/"

# Count via find (shellcheck SC2012: prefer find over ls for non-alphanumeric filenames)
fixture_count=$(find "$TMP/Clippings" -maxdepth 1 -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' ')

echo "Test 1: fresh fixtures (no processed marker) are all selected"
count=$(count_files_without_pattern "^processed: true$" "$TMP/Clippings/"*.md)
assert "all fixtures unprocessed (expected $fixture_count)" "$fixture_count" "$count"

echo "Test 2: mark one flow-style-tags fixture as processed (Phase 7 simulation)"
target="$TMP/Clippings/Sample tweet by jane.md"
[ -r "$target" ] || { echo "PRE-FLIGHT FAIL: target fixture missing: $target"; exit 1; }
# Insert `processed: true` + `triaged_at:` into frontmatter before the closing ---
# This mirrors the documented Phase 7 placement contract.
python3 - "$target" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
parts = text.split('---\n', 2)
if len(parts) < 3:
    sys.exit("frontmatter parse error in fixture")
fm = parts[1]
body = parts[2]
fm = fm.rstrip() + "\nprocessed: true\ntriaged_at: 2026-05-25\n"
p.write_text(f"---\n{fm}---\n{body}", encoding='utf-8')
PY
py_rc=$?
if [ "$py_rc" -ne 0 ]; then
    echo "  FAIL  Phase 7 simulation Python heredoc crashed (rc=$py_rc) — fixture may be partially written"
    fail=$((fail+1))
    echo "Skipping remaining Phase-7 simulation tests (1 abort)."
    echo ""
    echo "Results: $pass passed, $fail failed"
    exit 1
fi

# Verify file is still readable + non-empty before grepping.
if [ ! -r "$target" ] || [ ! -s "$target" ]; then
    echo "  FAIL  fixture file missing or empty after mutation: $target"
    fail=$((fail+1))
    echo "Results: $pass passed, $fail failed"
    exit 1
fi

count=$(count_files_without_pattern "^processed: true$" "$TMP/Clippings/"*.md)
expected_remaining=$((fixture_count - 1))
assert "$expected_remaining fixtures remain unprocessed after marking 1" "$expected_remaining" "$count"

echo "Test 3: frontmatter structure intact after mutation"
head -1 "$target" | grep -q "^---$" && fm_open=ok || fm_open=missing
assert "frontmatter open delimiter intact" "ok" "$fm_open"

# Body sections present (fixture-agnostic — count any `## ` heading).
heading_count=$(grep -c "^## " "$target" 2>/dev/null || true)
[ -z "$heading_count" ] && heading_count=0
[ "$heading_count" -ge 1 ] && body_intact=ok || body_intact=missing
assert "at least one body heading present after mutation" "ok" "$body_intact"

# processed: true present exactly once.
processed_count=$(grep -c "^processed: true$" "$target" 2>/dev/null || true)
[ -z "$processed_count" ] && processed_count=0
assert "processed:true appears exactly once" "1" "$processed_count"

# Phase 7 placement contract: processed:true MUST be at zero indent
# (not inside a list).
python3 - "$target" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
parts = text.split('---\n', 2)
if len(parts) < 3:
    sys.exit("frontmatter unparseable after mutation")
fm = parts[1]
lines = fm.splitlines()
found = False
for line in lines:
    if line.startswith("processed: true"):
        found = True
        break
    if line.startswith("  - processed"):
        sys.exit("PLACEMENT BUG: processed:true landed inside a list item")
if not found:
    sys.exit("processed: true not found at zero indent in frontmatter")
PY
py_rc=$?
if [ "$py_rc" -eq 0 ]; then
    echo "  PASS  processed:true at zero indent (NOT inside any list)"
    pass=$((pass+1))
else
    echo "  FAIL  Phase 7 placement contract violated (Python check rc=$py_rc)"
    fail=$((fail+1))
fi

echo "Test 4: scan re-decision after marking — idempotency hook"
if grep -q "^processed: true$" "$target"; then
    skip_decision=skip
else
    skip_decision=process
fi
assert "scan decides to skip already-marked clip" "skip" "$skip_decision"

echo "Test 5: block-style tags fixture is unprocessed and detectable"
block_target="$TMP/Clippings/Sample reddit with block tags.md"
if [ -r "$block_target" ]; then
    if grep -q "^processed: true$" "$block_target"; then
        block_decision=already_processed
    else
        block_decision=unprocessed
    fi
    assert "block-style-tags fixture starts unprocessed" "unprocessed" "$block_decision"

    # Confirm fixture has the expected block-style tags structure
    # (covers the audit gap: Phase 3 must handle this shape correctly).
    has_block_tags=no
    if grep -q "^tags:$" "$block_target" && grep -q "^  - learning$" "$block_target"; then
        has_block_tags=yes
    fi
    assert "block-style-tags fixture has the expected YAML shape" "yes" "$has_block_tags"
else
    echo "  WARN  block-style fixture missing — skipping Test 5"
fi

echo "Test 6: bare-tags fixture (YAML null) — Branch 3 vs Branch 4 disambiguation (LUNA-8)"
# Real-world shape from LUNA-2 Web Clipper templates: bare `tags:` with
# no value — YAML null. Phase 3 must handle this as Branch 4 (null) and
# distinguish it from Branch 3 (block-list, where `tags:` is followed by
# `  - item` lines). Both share the same first-line regex
# `^tags:[[:space:]]*$` and can only be told apart by look-ahead at the
# next non-blank line. Present in 100% of the 245-clip corpus.
bare_target="$TMP/Clippings/bare-tags.md"
if [ -r "$bare_target" ]; then
    if grep -q "^processed: true$" "$bare_target"; then
        bare_decision=already_processed
    else
        bare_decision=unprocessed
    fi
    assert "bare-tags fixture starts unprocessed" "unprocessed" "$bare_decision"

    # First-line regex: matches both Branch 3 and Branch 4 (this is by design;
    # disambiguation lives in the next-line look-ahead below).
    has_bare_tags=no
    if grep -qE "^tags:[[:space:]]*$" "$bare_target" \
       && ! grep -qE "^tags:[[:space:]]*\[\]" "$bare_target"; then
        has_bare_tags=yes
    fi
    assert "bare-tags fixture matches the first-line null-tags regex" "yes" "$has_bare_tags"

    # Branch 3 vs Branch 4 disambiguation: line AFTER `tags:` is the signal.
    # Use awk to grab the line immediately following the `tags:` match.
    bare_next="$(awk '/^tags:[[:space:]]*$/ {getline; print; exit}' "$bare_target")"
    if printf '%s' "$bare_next" | grep -qE "^  - "; then
        bare_branch=branch3_block
    else
        bare_branch=branch4_null
    fi
    assert "bare-tags fixture routes to Branch 4 (null) via next-line look-ahead" "branch4_null" "$bare_branch"

    # Block-style fixture: SAME first-line regex matches, but next line IS
    # `  - learning`, so it must route to Branch 3 instead.
    block_lookahead="$TMP/Clippings/Sample reddit with block tags.md"
    if [ -r "$block_lookahead" ]; then
        block_next="$(awk '/^tags:[[:space:]]*$/ {getline; print; exit}' "$block_lookahead")"
        if printf '%s' "$block_next" | grep -qE "^  - "; then
            block_branch=branch3_block
        else
            block_branch=branch4_null
        fi
        assert "block-style fixture routes to Branch 3 (block-list) via next-line look-ahead" "branch3_block" "$block_branch"
    fi

    # Negative-check: flow-empty fixture (`tags: []`) must NOT match the
    # first-line null-tags regex — Branch 1 owns it.
    flow_target="$TMP/Clippings/Sample tweet by jane.md"
    if [ -r "$flow_target" ]; then
        flow_misroute=no
        if grep -qE "^tags:[[:space:]]*$" "$flow_target" \
           && ! grep -qE "^tags:[[:space:]]*\[\]" "$flow_target"; then
            flow_misroute=yes
        fi
        assert "flow-empty fixture does NOT match bare-tags first-line regex (no misroute)" "no" "$flow_misroute"
    fi
else
    echo "  FAIL  bare-tags fixture missing — LUNA-8 fix not exercised"
    fail=$((fail+1))
fi

echo "Test 7: dedup-by-backreference helper (Phase 5 idempotency simulation)"
# Simulate a daily note that already contains a backref to the tweet
# clip — Phase 5 must skip re-appending.
daily="$TMP/daily-2026-05-25.md"
{
    echo "---"
    echo "date: 2026-05-25"
    echo "type: daily"
    echo "---"
    echo ""
    echo "# 2026-05-25"
    echo ""
    echo "## Actions from clips"
    echo "- [ ] Find the original paper Jane references (from [[Clippings/Sample tweet by jane]])"
} > "$daily"

# Phase 5 dedup check: grep for the exact backref pattern.
backref="(from [[Clippings/Sample tweet by jane]])"
if grep -qF "$backref" "$daily"; then
    dedup_decision=skip
else
    dedup_decision=append
fi
assert "dedup-by-backreference detects existing backref → skip append" "skip" "$dedup_decision"

# Inverse: a different clip's backref → not in daily → should append.
backref_other="(from [[Clippings/Sample reddit with block tags]])"
if grep -qF "$backref_other" "$daily"; then
    dedup_decision_other=skip
else
    dedup_decision_other=append
fi
assert "dedup correctly distinguishes different-clip backrefs → append" "append" "$dedup_decision_other"

echo "Test 8: Phase-8 debt drain predicate (HIMMEL-1713)"
# Debt is RECORDED, never inferred: Phase 7 writes evidence_pending: true in
# the same edit as processed: true; Phase 8 deletes it only after the six-form
# verify returns zero. The drain greps the marker across the inbox top level
# AND _evidence/ (mv carries frontmatter, so a post-move interruption stays
# visible), skips active ig_media_pending holds, and never touches a clip
# WITHOUT the marker — legacy processed clips, including ones /archive-clips
# dedup-parked in the inbox for operator review, are structurally out of the
# drain's reach (the round-4a regression).
mkdir -p "$TMP/drain/Clippings/_evidence"

make_clip() {
    # $1 = path, $2 = extra frontmatter lines (may be empty)
    {
        echo "---"
        echo "title: fixture"
        echo "type: instagram"
        echo "processed: true"
        [ -n "$2" ] && printf '%s\n' "$2"
        echo "---"
        echo ""
        echo "body"
    } > "$1"
}

drainable() {
    # Mirrors the drain: marker present (in the inbox at the SAME -maxdepth 2
    # the unprocessed scan uses, OR in _evidence/) AND no active
    # ig_media_pending hold. ARG_MAX-safe find|xargs form — shell globs over a
    # real _evidence/ (1284+ files) exceed the argument list. Read the printed
    # lines, never the pipeline's exit status: xargs returns 123 whenever a
    # grep batch has no match. The marker pattern is anchored at BOTH ends,
    # like the ^processed:…$ filter it partners.
    local f="$1"
    { find "$TMP/drain/Clippings" -maxdepth 2 -type f -name '*.md' \
        -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
        -not -path '*/_evidence/*' -print0
      find "$TMP/drain/Clippings/_evidence" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null
    } | xargs -0 grep -l "^evidence_pending:[[:space:]]*true[[:space:]]*$" /dev/null \
      | grep -qxF "$f" \
      || return 1
    # The grep is only a candidate prefilter — it scans the whole file, and clip
    # bodies are external content. Confirm against the leading --- block.
    fm_true "$f" processed && fm_true "$f" evidence_pending \
      && ! fm_true "$f" ig_media_pending
}

fm_true() {
    # True iff <key>: true is a real frontmatter key inside a COMPLETE leading
    # --- block, never body/code text. The block must close: an unterminated
    # one is all body, so matching in it would reopen the hole this shuts.
    # Delimiters are matched tolerantly (/^---[[:space:]]*$/), never by string
    # equality: a CRLF clip leaves \r on the line, and an equality test would
    # read every CRLF clip as having no frontmatter -> unprocessed forever.
    awk -v k="$2" '
      NR==1 { if ($0 !~ /^---[[:space:]]*$/) { bad=1; exit } ; next }
      $0 ~ /^---[[:space:]]*$/ { closed=1; exit }
      $0 ~ "^" k ":[[:space:]]*true[[:space:]]*$" { found=1 }
      END { exit (found && closed && !bad) ? 0 : 1 }
    ' "$1"
}

make_clip "$TMP/drain/Clippings/pending-inbox.md" "evidence_pending: true"
make_clip "$TMP/drain/Clippings/_evidence/pending-moved.md" "evidence_pending: true"
make_clip "$TMP/drain/Clippings/pending-held.md" "evidence_pending: true
ig_media_pending: true"
make_clip "$TMP/drain/Clippings/legacy-no-marker.md" ""
# glm-2 regression: Phase 7 marks date-subfolder clips too (the unprocessed
# scan is -maxdepth 2 and documents Clippings/2026-05/foo.md by name). A
# -maxdepth 1 drain left one interrupted mid-Phase-8 marked forever and
# invisible to BOTH scans — the debt scan must not see a narrower slice of the
# vault than the scan that creates the debt.
mkdir -p "$TMP/drain/Clippings/2026-05"
make_clip "$TMP/drain/Clippings/2026-05/pending-subfolder.md" "evidence_pending: true"
# codex-1 regression: the marker pattern must be anchored at BOTH ends. An
# unterminated ^evidence_pending:…true also matches a true-ish scalar, and a
# false hit resumes Phase 8 on a clip that owes nothing.
make_clip "$TMP/drain/Clippings/truthy-not-true.md" "evidence_pending: true-ish"
# codex-adv-2 regression: the marker is a FRONTMATTER key. Clip bodies are
# harvested from external pages, so a column-zero body line — or a fenced code
# block quoting this very runbook — must never read as debt. It is not a
# miscount: the drain would move and rewrite an untriaged clip, and since the
# commit point deletes a frontmatter key it could never clear a body line, so
# the false debt would recur on every nightly run forever.
{
    echo "---"
    echo "title: body-forged"
    echo "type: instagram"
    echo "processed: true"
    echo "---"
    echo ""
    echo "The runbook says to write:"
    echo ""
    echo '```yaml'
    echo "evidence_pending: true"
    echo '```'
} > "$TMP/drain/Clippings/body-forged-marker.md"
# Second lock: a clip that was never processed cannot owe a Phase 8, even if
# something put the marker in its frontmatter.
{
    echo "---"
    echo "title: marked-but-unprocessed"
    echo "type: instagram"
    echo "evidence_pending: true"
    echo "---"
    echo ""
    echo "body"
} > "$TMP/drain/Clippings/marked-unprocessed.md"
# codex-adv-5 regression: a truncated / sync-corrupted clip that opens with ---
# and never closes it has no frontmatter at all, only body. Matching inside it
# would reopen the body-text hole through the back door.
{
    echo "---"
    echo "title: truncated"
    echo "processed: true"
    echo "evidence_pending: true"
    echo ""
    echo "body with no closing delimiter"
} > "$TMP/drain/Clippings/unterminated-frontmatter.md"

if drainable "$TMP/drain/Clippings/pending-inbox.md"; then r1=drained; else r1=skipped; fi
assert "marker clip in inbox (hold cleared or pre-move interruption) IS drained" "drained" "$r1"

if drainable "$TMP/drain/Clippings/_evidence/pending-moved.md"; then r2=drained; else r2=skipped; fi
assert "marker clip already in _evidence/ (interrupted after mv) IS resumed" "drained" "$r2"

if drainable "$TMP/drain/Clippings/pending-held.md"; then r3=drained; else r3=skipped; fi
assert "marker clip with active ig_media_pending hold is NOT drained" "skipped" "$r3"

# 4a regression test: processed:true but NO marker. On the location-based
# predicate this was byte-identical to a stall and got eaten — including clips
# /archive-clips deliberately left in the inbox after a dedup-skip. The
# marker-driven drain must never touch it.
if drainable "$TMP/drain/Clippings/legacy-no-marker.md"; then r4=drained; else r4=skipped; fi
assert "processed clip WITHOUT the marker (legacy / dedup-parked) is NOT drained" "skipped" "$r4"

if drainable "$TMP/drain/Clippings/2026-05/pending-subfolder.md"; then r5=drained; else r5=skipped; fi
assert "marker clip in a date SUBFOLDER IS drained (maxdepth parity with the unprocessed scan)" "drained" "$r5"

if drainable "$TMP/drain/Clippings/truthy-not-true.md"; then r6=drained; else r6=skipped; fi
assert "true-ish marker value is NOT drained (pattern anchored at both ends)" "skipped" "$r6"

if drainable "$TMP/drain/Clippings/body-forged-marker.md"; then r7=drained; else r7=skipped; fi
assert "BODY-text marker (untrusted clip content) is NOT drained (frontmatter-scoped)" "skipped" "$r7"

if drainable "$TMP/drain/Clippings/marked-unprocessed.md"; then r8=drained; else r8=skipped; fi
assert "marked but NOT processed is NOT drained (a clip that never ran Phases 1-7 owes nothing)" "skipped" "$r8"

if drainable "$TMP/drain/Clippings/unterminated-frontmatter.md"; then r9=drained; else r9=skipped; fi
assert "unterminated frontmatter is NOT drained (no closing --- means no frontmatter)" "skipped" "$r9"

echo "Test 9: Phase-8 flat-pool collision guard (HIMMEL-1713)"
# The evidence pool is FLAT while the inbox is not, so 2026-05/foo.md and a
# top-level foo.md both target _evidence/foo.md. A bare mv destroys whichever
# landed first. The guard must move only into a free destination, and must
# still treat "already at the destination" (a resumed move) as a no-op.
mkdir -p "$TMP/coll/Clippings/_evidence" "$TMP/coll/Clippings/2026-05"
guarded_move() {  # $1 = the clip being operated on (always exists), $2 = dest
    # Order matters: -ef FIRST. The earlier form asked `[ -e dest ]` first and
    # compared dest against a reconstructed PRE-MOVE path, which after a
    # resumed move no longer exists — so -ef was false and a correct resume
    # was reported as a collision. Anchor on the clip's real current path.
    #
    # The claim is ln+rm, NOT test-then-mv: link() is atomic and fails when the
    # destination exists, so two overlapping runs cannot both believe the name
    # is free and have the second destroy the first clip's evidence.
    # Same inode covers TWO states: already-at-destination (no-op) and an
    # interrupted ln that left BOTH names on one inode (must unlink the
    # source). Treating them alike would clear the debt with the clip still
    # sitting in the inbox.
    if [ "$1" -ef "$2" ]; then
        if [ "$1" = "$2" ]; then echo "same-file"; return 0; fi
        # -ef follows symlinks, so same-inode does NOT prove "two hard links":
        # it is equally true for a symlinked destination or a symlinked parent
        # directory, where the inode has only ONE entry and unlinking the
        # source destroys the data. nlink alone is not enough either
        # (HIMMEL-1713 codex-2 round 3): it counts every directory entry on
        # $1's inode system-wide, not specifically $2, so an unrelated hard
        # link elsewhere could read nlink>=2 while $2 is still just a
        # symlink — require $2 itself NOT be a symlink before trusting it.
        if [ "$(nlink_of "$1")" -ge 2 ] 2>/dev/null && [ ! -L "$2" ]; then
            rm -f "$1"
            if [ -e "$1" ] || [ ! -f "$2" ]; then echo "alias-stuck"; else echo "alias-cleared"; fi
        else
            echo "alias-stuck"
        fi
        return 0
    fi
    if ln "$1" "$2" 2>/dev/null; then
        rm -f "$1"
        if [ -e "$1" ]; then echo "alias-stuck"; else echo "moved"; fi
    elif [ -e "$2" ] || [ -L "$2" ]; then
        # -L too: a dangling symlink occupies the name but fails -e.
        echo "collision"
    else
        # ln failed with a FREE destination => no hard-link support on this
        # filesystem (exFAT, network/sync mounts). The runbook degrades to
        # mv -n and verifies the POSTCONDITION rather than trusting the exit
        # status (HIMMEL-1713 codex-1 round 2 — see the direct assertions in
        # Test 9g); this mirror must match or it asserts behaviour the
        # runbook forbids.
        mv -n "$1" "$2" 2>/dev/null
        if [ -e "$1" ]; then
            if [ -e "$2" ]; then echo "collision"; else echo "move-failed"; fi
        else
            echo "moved-degraded"
        fi
    fi
}

nlink_of() { stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null; }
printf 'first\n'  > "$TMP/coll/Clippings/_evidence/dup.md"
printf 'second\n' > "$TMP/coll/Clippings/2026-05/dup.md"
res=$(guarded_move "$TMP/coll/Clippings/2026-05/dup.md" "$TMP/coll/Clippings/_evidence/dup.md")
assert "colliding basename is REFUSED, not moved" "collision" "$res"
assert "existing evidence note survives the refused move" "first" "$(cat "$TMP/coll/Clippings/_evidence/dup.md")"
assert "refused source stays put for the operator" "second" "$(cat "$TMP/coll/Clippings/2026-05/dup.md")"

printf 'fresh\n' > "$TMP/coll/Clippings/free.md"
res=$(guarded_move "$TMP/coll/Clippings/free.md" "$TMP/coll/Clippings/_evidence/free.md")
assert "free destination still moves normally" "moved" "$res"

# The REAL resumed-move shape, which the earlier version of this test missed:
# a prior attempt already moved the clip, so the pre-move inbox path is GONE
# and only the clip at _evidence/ exists. Passing dest as both operands (what
# this test used to do) dodges the bug entirely — it can only ever compare a
# path to itself. Drive it the way the drain does: hand it the marked file the
# drain actually found.
printf 'resumed\n' > "$TMP/coll/Clippings/_evidence/resumed.md"
[ -e "$TMP/coll/Clippings/resumed.md" ] && rm -f "$TMP/coll/Clippings/resumed.md"
found_clip="$TMP/coll/Clippings/_evidence/resumed.md"
res=$(guarded_move "$found_clip" "$TMP/coll/Clippings/_evidence/resumed.md")
assert "resumed move (pre-move path gone, clip already at dest) is a no-op, NOT a collision" "same-file" "$res"
assert "resumed clip content is untouched by the no-op" "resumed" "$(cat "$TMP/coll/Clippings/_evidence/resumed.md")"

echo "Test 8b: the UNPROCESSED scan is frontmatter-scoped too (HIMMEL-1713)"
# A whole-file grep for ^processed:true lets untrusted body text permanently
# suppress a clip's triage: it is excluded from the scan on EVERY run (the body
# never changes), and since Phase 7 never runs it never gets evidence_pending
# either, so no debt line ever names it. Both scans use fm_true, or neither is
# safe — an earlier revision argued a false skip here was self-correcting,
# which is exactly the wrong call.
mkdir -p "$TMP/unproc/Clippings"
{
    echo "---"; echo "title: genuinely processed"; echo "processed: true"; echo "---"; echo "body"
} > "$TMP/unproc/Clippings/real-processed.md"
{
    echo "---"; echo "title: body forged"; echo "---"; echo ""
    echo "The runbook writes:"; echo '```yaml'; echo "processed: true"; echo '```'
} > "$TMP/unproc/Clippings/body-forged.md"
{
    echo "---"; echo "title: fresh"; echo "---"; echo "body"
} > "$TMP/unproc/Clippings/fresh.md"
unprocessed=$(find "$TMP/unproc/Clippings" -maxdepth 2 -type f -name '*.md' -print0 \
  | while IFS= read -r -d '' f; do fm_true "$f" processed || printf '%s\n' "$f"; done | sort)
assert "genuinely processed clip is excluded from the unprocessed scan" "" \
  "$(printf '%s\n' "$unprocessed" | grep -F 'real-processed.md' || true)"
assert "BODY-forged processed marker does NOT suppress triage (still scanned)" "yes" \
  "$(printf '%s\n' "$unprocessed" | grep -qF 'body-forged.md' && echo yes || echo no)"
assert "an ordinary fresh clip is still scanned" "yes" \
  "$(printf '%s\n' "$unprocessed" | grep -qF 'fresh.md' && echo yes || echo no)"

echo "Test 8c: CRLF clips are read correctly (HIMMEL-1713)"
# A vault synced from Windows has CRLF clips. Where awk leaves the \r on the
# line, matching the delimiter by string equality ($0 == "---") sees "---\r",
# decides the clip has no frontmatter, and reports EVERY CRLF clip unprocessed
# on every run — re-triaging it nightly forever. The predicate this replaced
# was [[:space:]]-tolerant, so an equality test would be a regression.
#
# PLATFORM CAVEAT — do not read a pass here as proof on Windows. gawk's Windows
# build opens files in TEXT mode and translates CRLF->LF, so $0 is already
# "---" and BOTH the tolerant and the equality form pass on Git Bash (verified:
# gawk 5.4.0 reports length($0)==3 for a "---\r\n" line). On Linux, where no
# translation happens, only the tolerant form passes. This fixture therefore
# guards the Linux/CI path and is a no-op assertion on this host.
mkdir -p "$TMP/crlf/Clippings"
printf -- '---\r\ntitle: crlf processed\r\nprocessed: true\r\nevidence_pending: true\r\n---\r\nbody\r\n' \
  > "$TMP/crlf/Clippings/crlf-processed.md"
printf -- '---\r\ntitle: crlf fresh\r\n---\r\nbody\r\n' \
  > "$TMP/crlf/Clippings/crlf-fresh.md"
assert "CRLF clip's processed marker IS read (not re-triaged forever)" "yes" \
  "$(fm_true "$TMP/crlf/Clippings/crlf-processed.md" processed && echo yes || echo no)"
assert "CRLF clip's evidence_pending marker IS read" "yes" \
  "$(fm_true "$TMP/crlf/Clippings/crlf-processed.md" evidence_pending && echo yes || echo no)"
assert "CRLF clip without the marker still reads unprocessed" "no" \
  "$(fm_true "$TMP/crlf/Clippings/crlf-fresh.md" processed && echo yes || echo no)"

echo "Test 8d: the .md ambiguity guard is SYMMETRIC (HIMMEL-1713)"
# [[Clippings/foo.md]] is at once the plain link of a clip named foo.md (file
# foo.md.md) and the .md form of a clip named foo. Testing only "does <OLD> end
# in .md" catches one direction and leaves the other fully reachable: clip foo
# would rewrite the sibling's own link as its own.
mkdir -p "$TMP/ambig/Clippings"
printf -- 'body\n' > "$TMP/ambig/Clippings/foo.md"       # clip id "foo"
printf -- 'body\n' > "$TMP/ambig/Clippings/foo.md.md"    # clip id "foo.md"
printf -- 'body\n' > "$TMP/ambig/Clippings/lone.md.md"   # clip id "lone.md", NO colliding "lone" sibling
# HIMMEL-1713 codex-2: the "ends in .md" branch must verify the ACTUAL
# colliding sibling exists, not refuse on the string shape alone — otherwise
# a legitimate "lone.md.md" clip with no "lone" sibling is blocked forever.
ambiguous() {  # $1 = clip identifier, $2 = clippings dir
    case "$1" in
        *.md) [ -e "$2/${1%.md}.md" ] ;;     # this clip IS the foo.md one — only ambiguous if "foo" also exists
        *) [ -e "$2/$1.md.md" ] ;;           # a sibling claims [[Clippings/$1.md]]
    esac
}
assert "clip whose id ends in .md IS refused when the colliding foo sibling exists" "yes" \
  "$(ambiguous "foo.md" "$TMP/ambig/Clippings" && echo yes || echo no)"
assert "clip 'foo' is ALSO refused when sibling foo.md exists (other direction)" "yes" \
  "$(ambiguous "foo" "$TMP/ambig/Clippings" && echo yes || echo no)"
assert "a clip ending in .md with NO colliding sibling is NOT refused (HIMMEL-1713 codex-2)" "no" \
  "$(ambiguous "lone.md" "$TMP/ambig/Clippings" && echo yes || echo no)"
assert "an ordinary clip with no colliding sibling is NOT refused" "no" \
  "$(ambiguous "ordinary" "$TMP/ambig/Clippings" && echo yes || echo no)"

echo "Test 9b: empty-vault drain does not fall back to stdin (HIMMEL-1713)"
# With no marked clips both finds print nothing and GNU xargs still runs grep
# once with zero file operands — grep then reads STDIN. Without a permanent
# operand that either hangs or emits a bogus "(standard input)" candidate the
# drain would treat as debt. The /dev/null operand is what prevents it.
mkdir -p "$TMP/emptyvault/Clippings/_evidence"
empty_out=$({ find "$TMP/emptyvault/Clippings" -maxdepth 2 -type f -name '*.md' \
    -not -path '*/_synthesis/*' -not -path '*/_done/*' -not -name '_deferred.md' \
    -not -path '*/_evidence/*' -print0
  find "$TMP/emptyvault/Clippings/_evidence" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null
} | xargs -0 grep -l "^evidence_pending:[[:space:]]*true[[:space:]]*$" /dev/null < /dev/null 2>&1)
assert "empty vault yields no candidates and no (standard input) line" "" "$empty_out"

echo "Test 9c: a RENAMED collided clip is swept under BOTH identifiers (HIMMEL-1713)"
# The collision remedy tells the operator to rename the source clip. If the
# drain then took the clip's CURRENT path as <OLD>, inbound links still using
# the recorded evidence_origin would never be enumerated, the verify would
# report clean, and the commit point would delete both markers — links dangling
# with a clean log. evidence_origin is authoritative wherever the clip sits.
mkdir -p "$TMP/rename/Clippings" "$TMP/rename/notes"
ORIG="old-name"; RENAMED="new-name"
{
    echo "---"; echo "title: renamed"; echo "processed: true"
    echo "evidence_pending: true"; echo "evidence_origin: '$ORIG'"; echo "---"; echo "body"
} > "$TMP/rename/Clippings/$RENAMED.md"
printf -- '- see [[Clippings/%s]] and [[Clippings/%s]]\n' "$ORIG" "$RENAMED" > "$TMP/rename/notes/inbound.md"
recorded_origin=$(awk -F"'" '/^evidence_origin:/{print $2; exit}' "$TMP/rename/Clippings/$RENAMED.md")
assert "recorded origin survives the rename" "$ORIG" "$recorded_origin"
# Sweeping only the current path leaves the recorded-origin link behind.
only_current=$(grep -cF "[[Clippings/$ORIG]]" "$TMP/rename/notes/inbound.md")
assert "a current-path-only sweep would strand the origin link" "1" "$only_current"
# Both identifiers enumerated = both links found.
both=$(grep -oF -e "[[Clippings/$ORIG]]" -e "[[Clippings/$RENAMED]]" "$TMP/rename/notes/inbound.md" | wc -l | tr -d ' ')
assert "sweeping BOTH identifiers enumerates both inbound links" "2" "$both"

echo "Test 9d: an interrupted-after-move resume CONVERGES (HIMMEL-1713)"
# The primary case the whole resume mechanism exists for. After the mv the
# clip's own path relative to Clippings/ IS <NEW> (_evidence/foo), so if the
# identifier set admitted "current path when it differs from origin", the
# rewrite would be a no-op and the verify would then search for
# [[Clippings/_evidence/foo]] — exactly what correctly-rewritten links and the
# clip's own self-ref look like. Verify could never reach zero, the marker
# would never clear, and every nightly drain would fail identically. The set
# must be evidence_origin ALONE once the clip is at the destination, and <NEW>
# must never be a member.
mkdir -p "$TMP/resume/Clippings/_evidence" "$TMP/resume/notes"
R_ORIG="foo"; R_NEW="_evidence/foo"
{
    echo "---"; echo "title: interrupted after mv"; echo "processed: true"
    echo "evidence_pending: true"; echo "evidence_origin: '$R_ORIG'"; echo "---"
    echo "body"
    echo "- self [[Clippings/$R_NEW]]"          # self-ref already remapped by the interrupted attempt
} > "$TMP/resume/Clippings/_evidence/foo.md"
printf -- '- done [[Clippings/%s]]\n- todo [[Clippings/%s]]\n' "$R_NEW" "$R_ORIG" \
  > "$TMP/resume/notes/inbound.md"

# Build the OLD set with the runbook's actual rule rather than restating the
# expected answer. The earlier version of this test assigned old_set="$R_ORIG"
# and then asserted old_set == "$R_ORIG" — comparing a hardcoded value to
# itself, so it exercised none of the construction logic it claimed to cover.
build_old_set() {  # $1 = clip current path, $2 = evidence_origin, $3 = dest, $4 = Clippings root
    local set="" cur
    [ -n "$2" ] && set="$2"                       # recorded origin is authoritative
    if [ "$1" != "$3" ]; then                     # still in the inbox
        cur="${1#"$4"/}"; cur="${cur%.md}"
        [ "$cur" != "$2" ] && set="${set:+$set }$cur"
    fi
    if [ -z "$set" ]; then cur="${1#"$4"/}"; set="${cur%.md}"; fi  # legacy: no origin
    printf '%s\n' "$set"
}
CLIP_ROOT="$TMP/resume/Clippings"
old_set=$(build_old_set "$CLIP_ROOT/_evidence/foo.md" "$R_ORIG" "$CLIP_ROOT/_evidence/foo.md" "$CLIP_ROOT")
assert "clip AT destination -> OLD set is evidence_origin alone" "$R_ORIG" "$old_set"
assert "<NEW> is NOT a member of the OLD set" "no" \
  "$(printf '%s\n' "$old_set" | tr ' ' '\n' | grep -qxF "$R_NEW" && echo yes || echo no)"
# The other two states the rule distinguishes, so the branch actually matters:
renamed_set=$(build_old_set "$CLIP_ROOT/bar.md" "$R_ORIG" "$CLIP_ROOT/_evidence/foo.md" "$CLIP_ROOT")
assert "renamed inbox clip -> BOTH recorded origin and current identifier" "foo bar" "$renamed_set"
legacy_set=$(build_old_set "$CLIP_ROOT/baz.md" "" "$CLIP_ROOT/_evidence/baz.md" "$CLIP_ROOT")
assert "legacy clip with no recorded origin -> current identifier alone" "baz" "$legacy_set"

# Rewrite the remaining origin-form link, then verify across the OLD set only.
c="$(cat "$TMP/resume/notes/inbound.md")"
c="${c//"[[Clippings/$R_ORIG]]"/"[[Clippings/$R_NEW]]"}"
printf '%s\n' "$c" > "$TMP/resume/notes/inbound.md"
stale=$(grep -rlF -e "[[Clippings/$R_ORIG]]" -e "[[Clippings/$R_ORIG|" -e "[[Clippings/$R_ORIG#" \
  -e "[[Clippings/$R_ORIG.md]]" -e "[[Clippings/$R_ORIG.md|" -e "[[Clippings/$R_ORIG.md#" \
  "$TMP/resume" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
assert "verify over the OLD set returns ZERO -> debt can clear (resume converges)" "0" "$stale"
# The counter-case: had <NEW> been admitted, the verify would still find hits.
would_hang=$(grep -rlF -e "[[Clippings/$R_NEW]]" "$TMP/resume" --include='*.md' 2>/dev/null | wc -l | tr -d ' ')
assert "admitting <NEW> would have found live links forever (non-convergence)" "2" "$would_hang"

echo "Test 9e: the destination claim is atomic no-clobber (HIMMEL-1713)"
# A test-then-mv is check-then-act: two overlapping runs can both see a free
# destination and both move, the second destroying the first clip's evidence.
# link() is atomic and REFUSES an existing destination, so the check and the
# claim are one operation. Assert the refusal directly rather than trusting the
# guard's branch order.
mkdir -p "$TMP/atomic/_evidence"
printf 'incumbent\n' > "$TMP/atomic/_evidence/x.md"
printf 'challenger\n' > "$TMP/atomic/challenger.md"
if ln "$TMP/atomic/challenger.md" "$TMP/atomic/_evidence/x.md" 2>/dev/null; then r=linked; else r=refused; fi
assert "ln REFUSES an occupied destination (atomic no-clobber)" "refused" "$r"
assert "incumbent evidence survives the refusal" "incumbent" "$(cat "$TMP/atomic/_evidence/x.md")"
assert "challenger still exists after the refusal" "challenger" "$(cat "$TMP/atomic/challenger.md")"
# And the free-destination path still claims successfully.
if ln "$TMP/atomic/challenger.md" "$TMP/atomic/_evidence/y.md" 2>/dev/null; then r=linked; else r=refused; fi
assert "ln SUCCEEDS when the destination name is free" "linked" "$r"
rm -f "$TMP/atomic/challenger.md"
assert "content is reachable at the destination after dropping the source name" "challenger" \
  "$(cat "$TMP/atomic/_evidence/y.md")"

echo "Test 9f: an interrupted ln leaves TWO names — the alias must be unlinked (HIMMEL-1713)"
# ln+rm is atomic per-claim but NOT atomic as a pair. Killed in between, the
# clip exists in the inbox AND in _evidence/ as one inode. -ef is then true, so
# a plain no-op branch would skip the stale alias, rewrite links, and clear
# evidence_pending with the clip still in the inbox — where /archive-clips can
# later graduate it into _done/, leaving two lifecycle states sharing an inode.
mkdir -p "$TMP/interrupted/Clippings/_evidence"
printf 'payload\n' > "$TMP/interrupted/Clippings/half.md"
ln "$TMP/interrupted/Clippings/half.md" "$TMP/interrupted/Clippings/_evidence/half.md"
# Precondition: this is exactly the interrupted state — same inode, two paths.
assert "precondition: both names exist on one inode" "yes" \
  "$([ "$TMP/interrupted/Clippings/half.md" -ef "$TMP/interrupted/Clippings/_evidence/half.md" ] && echo yes || echo no)"
res=$(guarded_move "$TMP/interrupted/Clippings/half.md" "$TMP/interrupted/Clippings/_evidence/half.md")
assert "interrupted ln is recognised and the inbox alias unlinked" "alias-cleared" "$res"
assert "inbox alias is gone" "no" \
  "$([ -e "$TMP/interrupted/Clippings/half.md" ] && echo yes || echo no)"
assert "evidence copy survives with its content" "payload" \
  "$(cat "$TMP/interrupted/Clippings/_evidence/half.md")"
# And the genuine no-op (drain found the clip already AT the destination, one
# name only) must still be a no-op, not an unlink.
res=$(guarded_move "$TMP/interrupted/Clippings/_evidence/half.md" "$TMP/interrupted/Clippings/_evidence/half.md")
assert "already-at-destination single name is still a plain no-op" "same-file" "$res"
assert "the no-op did not delete the clip" "payload" \
  "$(cat "$TMP/interrupted/Clippings/_evidence/half.md")"

echo "Test 9h: a SYMLINKED destination must not be unlinked as a stale alias (HIMMEL-1713)"
# -ef compares stat(), which follows symlinks, so it is true when the
# destination is a symlink to the inbox file — not only when an interrupted ln
# made two hard links. Unlinking the source there deletes the sole REAL
# directory entry and leaves the destination dangling: data loss dressed up as
# recovery. Skips loudly where the host cannot create symlinks (Windows without
# developer mode), rather than passing vacuously.
mkdir -p "$TMP/symlink/Clippings/_evidence"
printf 'realdata\n' > "$TMP/symlink/Clippings/s.md"
ln -s "$TMP/symlink/Clippings/s.md" "$TMP/symlink/Clippings/_evidence/s.md" 2>/dev/null || true
# Check the ARTIFACT, not ln's exit code: MSYS/Git-Bash without winsymlinks
# reports success and silently writes a COPY, which is a different inode and so
# would not exercise this case at all. A vacuous pass here would be worse than
# a skip — it would claim coverage of the exact data-loss path it missed.
if [ -L "$TMP/symlink/Clippings/_evidence/s.md" ] \
   && [ "$TMP/symlink/Clippings/s.md" -ef "$TMP/symlink/Clippings/_evidence/s.md" ]; then
    res=$(guarded_move "$TMP/symlink/Clippings/s.md" "$TMP/symlink/Clippings/_evidence/s.md")
    assert "symlinked destination is REFUSED, not treated as a stale hard link" "alias-stuck" "$res"
    assert "the real file still exists (no data loss)" "realdata" \
      "$(cat "$TMP/symlink/Clippings/s.md")"
else
    echo "  SKIP  host produced a copy, not a symlink (MSYS without winsymlinks) — symlink-alias case not exercised here; it is covered on Linux/macOS CI"
fi

echo "Test 9i: nlink>=2 alone does NOT prove dest is one of the hard links (HIMMEL-1713 codex-2 round 3)"
# nlink counts every directory entry on the clip's inode SYSTEM-WIDE, not
# specifically dest. If dest is a symlink to clip (not a real second hard
# link) while clip separately carries an UNRELATED hard link elsewhere, the
# old `nlink>=2` test alone would misread that as "clip and dest are the two
# expected hardlinks" and unlink the clip's sole real entry, leaving the
# symlink destination dangling. The fix requires dest itself NOT be a
# symlink before trusting the count. Skips loudly where the host cannot
# create symlinks, same guard as Test 9h.
mkdir -p "$TMP/symlink2/Clippings/_evidence"
printf 'realdata2\n' > "$TMP/symlink2/Clippings/s2.md"
ln "$TMP/symlink2/Clippings/s2.md" "$TMP/symlink2/Clippings/unrelated-hardlink.md" 2>/dev/null || true
ln -s "$TMP/symlink2/Clippings/s2.md" "$TMP/symlink2/Clippings/_evidence/s2.md" 2>/dev/null || true
if [ -L "$TMP/symlink2/Clippings/_evidence/s2.md" ] \
   && [ "$TMP/symlink2/Clippings/s2.md" -ef "$TMP/symlink2/Clippings/_evidence/s2.md" ] \
   && [ "$TMP/symlink2/Clippings/s2.md" -ef "$TMP/symlink2/Clippings/unrelated-hardlink.md" ]; then
    precondition_nlink="$(nlink_of "$TMP/symlink2/Clippings/s2.md")"
    assert "precondition: unrelated hard link raises nlink to >=2" "yes" \
      "$([ "$precondition_nlink" -ge 2 ] 2>/dev/null && echo yes || echo no)"
    res=$(guarded_move "$TMP/symlink2/Clippings/s2.md" "$TMP/symlink2/Clippings/_evidence/s2.md")
    assert "symlink dest + unrelated hardlink is REFUSED, not treated as the expected pair" "alias-stuck" "$res"
    assert "the real file still exists (no data loss)" "realdata2" \
      "$(cat "$TMP/symlink2/Clippings/s2.md")"
    assert "the unrelated hard link is untouched" "realdata2" \
      "$(cat "$TMP/symlink2/Clippings/unrelated-hardlink.md")"
else
    echo "  SKIP  host could not construct the symlink+hardlink precondition (MSYS without winsymlinks, or no hard-link support) — covered on Linux/macOS CI"
fi

echo "Test 9g: a filesystem without hard links degrades, it does NOT false-collide (HIMMEL-1713)"
# exFAT, FAT32, many network shares and several cloud-sync mounts reject
# link(). Reading every ln failure as "destination taken" would turn every clip
# on such a vault into a permanent false collision. The destination must be
# examined only AFTER ln fails: exists => real collision; free => the
# filesystem cannot hard-link, so degrade to mv. Simulated with an ln stub,
# since the suite cannot mount an exFAT volume.
claim_nolink() {  # $1 = clip, $2 = dest; ln always fails, as on exFAT
    if [ "$1" -ef "$2" ]; then echo "same-file"; return 0; fi
    if false; then :                      # stands in for a failing `ln`
    elif [ -e "$2" ]; then echo "collision"; return 0
    else
        # -n (no-clobber, HIMMEL-1713 codex-1): mirrors the runbook's fix — a
        # concurrent claim landing between this function's own free-check
        # above and the mv call must be refused, not silently overwritten.
        # Verify the POSTCONDITION, never the exit status: GNU coreutils
        # `mv -n` exits 0 even when it silently skipped a no-clobber refusal
        # (proven by the direct assertions below) — trusting rc=0 would read
        # a skipped, still-in-place clip as moved.
        mv -n "$1" "$2" 2>/dev/null
        if [ -e "$1" ]; then
            if [ -e "$2" ]; then echo "collision"; else echo "move-failed"; fi
        else
            echo "moved-degraded"
        fi
    fi
}
mkdir -p "$TMP/nolink/Clippings/_evidence"
printf 'clipdata\n' > "$TMP/nolink/Clippings/a.md"
res=$(claim_nolink "$TMP/nolink/Clippings/a.md" "$TMP/nolink/Clippings/_evidence/a.md")
assert "no-hardlink FS with a FREE destination degrades to mv, not a collision" "moved-degraded" "$res"
assert "the clip actually arrived at the destination" "clipdata" \
  "$(cat "$TMP/nolink/Clippings/_evidence/a.md")"
assert "the inbox copy is gone after the degraded move" "no" \
  "$([ -e "$TMP/nolink/Clippings/a.md" ] && echo yes || echo no)"
# A genuine collision must STILL be reported as one on the same filesystem.
printf 'incumbent\n' > "$TMP/nolink/Clippings/_evidence/b.md"
printf 'challenger\n' > "$TMP/nolink/Clippings/b.md"
res=$(claim_nolink "$TMP/nolink/Clippings/b.md" "$TMP/nolink/Clippings/_evidence/b.md")
assert "no-hardlink FS still reports a REAL collision correctly" "collision" "$res"
assert "incumbent survives the real collision" "incumbent" \
  "$(cat "$TMP/nolink/Clippings/_evidence/b.md")"
# Exercise `mv -n` itself directly (not the outer `[ -e ]` guard) — proves the
# no-clobber semantic the fix actually relies on: a destination that appears
# between a free-check and the mv call must not be silently overwritten.
# codex-1 regression, discovered running this suite: GNU coreutils `mv -n`
# EXITS 0 even when it silently skips a no-clobber refusal — an exit-status
# check alone would misread a skipped move as successful (worse than the bare
# `mv` this replaces: the clip would be left in the inbox while the runbook
# proceeds as though it reached $dest). The postcondition — is the SOURCE
# still there — is the only reliable signal, which is why the runbook checks
# `[ -e "$clip" ]` after the call rather than the call's own exit status.
printf 'raced-incumbent\n' > "$TMP/nolink/Clippings/_evidence/c.md"
printf 'raced-challenger\n' > "$TMP/nolink/Clippings/c.md"
if mv -n "$TMP/nolink/Clippings/c.md" "$TMP/nolink/Clippings/_evidence/c.md" 2>/dev/null; then mv_n_rc=0; else mv_n_rc=1; fi
if [ -e "$TMP/nolink/Clippings/c.md" ]; then srcstate=intact; else srcstate=moved; fi
assert "mv -n's exit status alone is NOT reliable evidence a no-clobber refusal happened (documents the codex-1 discovery)" "0" "$mv_n_rc"
assert "mv -n's postcondition (source still present) correctly shows the refusal" "intact" "$srcstate"
assert "mv -n leaves the racing incumbent's content intact" "raced-incumbent" \
  "$(cat "$TMP/nolink/Clippings/_evidence/c.md")"
assert "mv -n leaves the challenger source untouched after refusing" "raced-challenger" \
  "$(cat "$TMP/nolink/Clippings/c.md")"

echo "Test 10: evidence_origin is a QUOTED, round-tripped YAML scalar (HIMMEL-1713)"
# Clip ids are filenames: they open with @ (YAML-reserved) and contain ' #'
# (comment start). A bare scalar either fails parse-before-write and blocks
# Phase 8 forever, or parses WRONG and truncates the path the drain relies on.
CMD="$(cd "$(dirname "$0")/.." && pwd)/commands/triage-clips.md"
grep -q "evidence_origin: '<OLD>'" "$CMD" \
  && r=ok || r=missing
assert "runbook emits evidence_origin single-quoted" "ok" "$r"
grep -qi "doubled" "$CMD" && r=ok || r=missing
assert "runbook requires internal quotes to be doubled" "ok" "$r"
grep -qi "byte for" "$CMD" && r=ok || r=missing
assert "runbook requires a round-trip equality assert on the written value" "ok" "$r"
# Prove the failure modes are real on the SAME js-yaml the tools use, so the
# rule is anchored to behaviour and not just to prose. It lives in the plugin's
# own tools/node_modules (untracked install), so resolve via NODE_PATH; a
# checkout without it degrades to SKIP rather than a false pass.
TOOLS_MODULES="$(cd "$(dirname "$0")/.." && pwd)/tools/node_modules"
if command -v node >/dev/null 2>&1 && [ -d "$TOOLS_MODULES/js-yaml" ]; then
    bare=$(NODE_PATH="$TOOLS_MODULES" node -e 'const y=require("js-yaml");try{const d=y.load("evidence_origin: @karpathy x\n");console.log("parsed:"+JSON.stringify(d.evidence_origin))}catch(e){console.log("rejected")}' 2>/dev/null || echo "error")
    assert "bare @-prefixed scalar is REJECTED by js-yaml (why quoting is mandatory)" "rejected" "$bare"

    comment=$(NODE_PATH="$TOOLS_MODULES" node -e 'const y=require("js-yaml");try{console.log(y.load("evidence_origin: foo #topic\n").evidence_origin)}catch(e){console.log("rejected")}' 2>/dev/null || echo "error")
    assert "bare ' #' silently truncates to a comment (the corruption case)" "foo" "$comment"

    quoted=$(NODE_PATH="$TOOLS_MODULES" node -e 'const y=require("js-yaml");console.log(y.load("evidence_origin: '"'"'@karpathy 2026-05 #t'"'"'\n").evidence_origin)' 2>/dev/null || echo "error")
    assert "single-quoted scalar round-trips BOTH hostile chars intact" "@karpathy 2026-05 #t" "$quoted"
else
    echo "  SKIP  js-yaml not installed under tools/ — behavioural YAML asserts skipped"
fi

echo ""
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
