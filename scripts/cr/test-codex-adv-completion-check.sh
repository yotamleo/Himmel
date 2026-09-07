#!/usr/bin/env bash
# scripts/cr/test-codex-adv-completion-check.sh -- TDD tests for
# codex-adv-completion-check.sh (HIMMEL-1420). Bash 3.2 safe.
# shellcheck disable=SC2015  # A && B || C intentional in the final assert
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CAC="$HERE/codex-adv-completion-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

# run <rc> <stdout_text> <stderr_text> -> full CLI stdout (status=/err_tail= lines)
run_cli() {
    _rc="$1"; _out_text="${2:-}"; _err_text="${3:-}"
    _outf="$tmp/out"; _errf="$tmp/err"
    printf '%s' "$_out_text" > "$_outf"
    printf '%s' "$_err_text" > "$_errf"
    bash "$CAC" "$_rc" "$_outf" "$_errf"
}

status_of() { run_cli "$1" "${2:-}" "${3:-}" | sed -n 's/^status=//p'; }
tail_of()   { run_cli "$1" "${2:-}" "${3:-}" | sed -n 's/^err_tail=//p'; }
rc_of()     { run_cli "$1" "${2:-}" "${3:-}" >/dev/null 2>&1; echo $?; }

# ── the actual HIMMEL-1420 bug: rc=0 + empty stdout MUST NOT read as clean ──
check "1: rc=0, empty stdout -> unavailable (the silent-death shape)" \
    "$(status_of 0 '' '')" "unavailable"
check "2: rc=0, empty stdout -> CLI exit 1" "$(rc_of 0 '' '')" "1"

# ── CR round 3 [codex-adv-r2-2] (reproduced): heading + Verdict: ALONE is not
#    completion evidence — the renderer writes Verdict BEFORE the required
#    summary + findings-indicator, so a stdout truncated right after Verdict:
#    (findings lost) must still classify unavailable, not ok. ─────────────────
check "3: rc=0, truncated immediately after Verdict: (no summary/findings-indicator) -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: approve, no findings' '')" "unavailable"
check "4: rc=0, truncated immediately after Verdict: -> CLI exit 1" \
    "$(rc_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: approve, no findings' '')" "1"

# ── genuine findings: rc=0, full companion-shaped structure (heading, Target,
#    Verdict, summary, Findings: header + a well-formed bullet) -> ok. Findings
#    captured verbatim by the CALLER (this script only classifies; the harvest
#    fence reads stdout). ────────────────────────────────────────────────────
check "5: rc=0 with Verdict + a real Findings: section -> ok" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

Found a SQL injection risk in the query builder.

Findings:
- [high] SQL injection in query builder (src/db.js:42)
  Untrusted input concatenated directly into the query string.' '')" "ok"

# ── rc=0, stdout present but NO Verdict marker -> unavailable (truncated /
#    partial output, not just wholly empty) ─────────────────────────────────
check "6: rc=0, non-empty stdout with NO Verdict marker -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review
' '')" "unavailable"

# ── CR round 1 [codex-1] (HIMMEL-1420): a stray Verdict: line with the
#    heading itself truncated away is the SAME partial-write silent-death
#    shape as check 6, just cut at a different point — BOTH markers are
#    required, not "Verdict:" alone. ────────────────────────────────────────
check "6b: rc=0, stdout has ONLY a Verdict line (heading truncated away) -> unavailable" \
    "$(status_of 0 'Verdict: approve, no findings' '')" "unavailable"
check "6c: rc=0, truncated-only-verdict -> CLI exit 1" \
    "$(rc_of 0 'Verdict: approve, no findings' '')" "1"

# ── non-zero rc is unavailable regardless of stdout content (even if a
#    Verdict line somehow leaked through) ──────────────────────────────────
check "7: rc=1 -> unavailable even with stdout content" \
    "$(status_of 1 'Verdict: approve' '')" "unavailable"
check "8: rc=124 (timeout) -> unavailable" "$(status_of 124 '' '')" "unavailable"

# ── err_tail diagnostic: last non-blank .err line, never flips status ──────
check "9: err_tail captures last non-blank stderr line" \
    "$(tail_of 0 '' 'starting review
Turn completion inferred
')" "Turn completion inferred"
check "10: 'Turn completion inferred' present but Verdict: still missing -> status stays unavailable" \
    "$(status_of 0 '' 'starting review
Turn completion inferred')" "unavailable"
check "11: no stderr content -> err_tail is (none)" "$(tail_of 0 '' '')" "(none)"
check "12: whitespace-only stderr -> err_tail is (none)" "$(tail_of 0 '' '
   ')" "(none)"

# ── usage errors ────────────────────────────────────────────────────────────
usage_rc=0
bash "$CAC" >/dev/null 2>&1 || usage_rc=$?
check "13: no args -> usage exit 2" "$usage_rc" "2"

# ── sourcing is side-effect-free (no `set -e`/`set -u` leak into the caller,
#    mirrors failure-classify.sh's own contract) ────────────────────────────
(
    set +e
    # shellcheck source=scripts/cr/codex-adv-completion-check.sh
    # shellcheck disable=SC1091
    . "$CAC"
    false  # would abort a script under -e; must NOT here
    echo "survived"
) > "$tmp/source_result"
check "14: sourcing does not leak errexit" "$(cat "$tmp/source_result")" "survived"

(
    set +u
    # shellcheck source=scripts/cr/codex-adv-completion-check.sh
    # shellcheck disable=SC1091
    . "$CAC"
    # shellcheck disable=SC2154
    : "$DELIBERATELY_UNSET_VAR"
    echo "survived"
) > "$tmp/source_result2" 2>/dev/null
check "15: sourcing does not leak nounset" "$(cat "$tmp/source_result2")" "survived"

# ── sourced function form: caller can inspect CODEX_ADV_STATUS directly ────
(
    # shellcheck source=scripts/cr/codex-adv-completion-check.sh
    # shellcheck disable=SC1091
    . "$CAC"
    printf '%s' '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: approve

Nothing of concern in this diff.

No material findings.' > "$tmp/sf_out"
    printf '' > "$tmp/sf_err"
    if classify_codex_adv_completion 0 "$tmp/sf_out" "$tmp/sf_err"; then
        echo "$CODEX_ADV_STATUS"
    else
        echo "unexpected-failure"
    fi
) > "$tmp/sourced_result"
check "16: sourced classify_codex_adv_completion sets CODEX_ADV_STATUS=ok" \
    "$(cat "$tmp/sourced_result")" "ok"

# ── CR round 2 [codex-adv-1] (HIMMEL-1420): the companion's own parse-error /
#    validation-error banner renders reuse the SAME "# Codex Adversarial
#    Review" heading under rc=0, and can embed the model's raw malformed
#    output verbatim — which can coincidentally contain "Verdict:" as prose.
#    Fixtures below are shaped exactly like the real companion source
#    (scripts/lib/render.mjs renderReviewResult on openai-codex 1.0.5). ─────

# 17: parse-error banner (Codex's response failed to parse as JSON at all),
# with the raw text echoed inside a ```text fence containing a coincidental
# "Verdict:"-shaped line -> unavailable, not ok.
check "17: rc=0, parse-error banner with a coincidental Verdict: in the raw-output fence -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Codex did not return valid structured JSON.

- Parse error: Unexpected token I in JSON at position 0

Raw final message:

```text
I think the verdict here is:
Verdict: needs-attention because of a hardcoded secret
```' '')" "unavailable"

# 18: validation-error banner (Codex returned JSON, but not shaped like the
# review schema) -> unavailable.
check "18: rc=0, validation-error banner -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Codex returned JSON with an unexpected review shape.

- Validation error: Missing string verdict.' '')" "unavailable"

# 19: a "Verdict: " line exists ONLY after a ```text raw-output fence, never
# at its required line-4 position -> unavailable. Under the CR round 4
# line-walk this is caught by the position-4 check itself (line 4 here is a
# blank line, not "Verdict: ..."), superseding the old separate fence-
# exclusion defense — the walk never even reaches the fenced content.
check "19: rc=0, Verdict: line present ONLY after a raw-output fence (no banner phrase) -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Some non-banner preamble with no verdict of its own.

```text
Verdict: this line is inside the fenced raw blob, not the header
```' '')" "unavailable"

# 20: the REAL companion success shape (heading, Target:, Verdict:, summary,
# findings — matching scripts/lib/render.mjs's actual field order) still
# classifies ok; the structural tightening must not regress the genuine case.
check "20: rc=0, full genuine companion-shaped output (heading/Target/Verdict/summary) -> ok" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

Found a SQL injection risk in the query builder.

Findings:
- [high] SQL injection in query builder (src/db.js:42)
  Untrusted input concatenated directly into the query string.' '')" "ok"

# 21: heading present but NOT opening the document (e.g. leading blank/noise
# before it) -> unavailable — the heading must be document structure (line 1
# exactly), not merely present somewhere in the output.
check "21: rc=0, heading NOT on line 1 -> unavailable" \
    "$(status_of 0 '
# Codex Adversarial Review

Verdict: approve, no findings' '')" "unavailable"

# ── CR round 3 [codex-adv-r2-1] (reproduced): a genuinely SUCCESSFUL review
#    whose summary or a finding body legitimately QUOTES one of the two
#    banner phrases (very plausible for a review discussing this sentinel)
#    must NOT be discarded by a free-substring banner search. Position-
#    anchoring (line 3 / line 4 only) is the fix under test here — this
#    fixture's line 3 is "Target: ..." and line 4 is "Verdict: ...", so
#    neither banner-position check fires, regardless of what the summary or
#    finding body quote further down the document. ─────────────────────────
check "22: rc=0, summary AND a finding body each quote a banner phrase -> still ok" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

This sentinel must reject a run whose stdout reads "Codex did not return valid structured JSON." only at its real structural position, not as a free substring.

Findings:
- [medium] Docstring imprecision in the harvest fence (scripts/cr/codex-adv-completion-check.sh:10)
  The header comment should also cover the case where a validator quotes "Codex returned JSON with an unexpected review shape." while explaining the fix, so a reader is not confused about which check fires.' '')" "ok"

# ── CR round 3 [codex-adv-r2-2] (reproduced): truncation landing right after
#    the "Findings:" header — the header alone is not the section; without at
#    least one well-formed bullet line, this is the same lost-findings shape
#    as check 3, just cut one line later. ───────────────────────────────────
check "23: rc=0, truncated immediately after the Findings: header (no bullet lines) -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

Found a SQL injection risk in the query builder.

Findings:' '')" "unavailable"

# 24: a complete approve verdict with NO findings — the genuinely terminal
# section for this shape ("No material findings.") is present, so this must
# classify ok even though it never emits a "Findings:" header or a Next
# steps:/Reasoning: section at all (both are conditional per the real
# renderer — see the header comment above). CLI-level counterpart to check 16
# (which exercises the sourced-function interface with the same shape).
check "24: rc=0, complete approve with no findings (terminal indicator present) -> ok" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: approve

Nothing of concern in this diff.

No material findings.' '')" "ok"

# ── CR round 4 ([codex-r3-1] Important, reproduced): checks 5/16/24's
#    findings-indicator was a REGION search over the header text — a summary
#    that QUOTES "No material findings." or "Findings:" verbatim as one of
#    its own lines (very plausible for a review discussing this sentinel)
#    could satisfy it even on a genuinely truncated run. The line-walk fix:
#    the marker is checked ONLY at the single line immediately after the
#    summary's OWN blank-line terminator; a quoted marker line inside the
#    summary (not itself followed+preceded by hitting that exact state
#    transition with nothing else going on) is just more summary content
#    that keeps the walk in the "summary" state — it can never masquerade as
#    the real, renderer-emitted marker. Both fixtures below are genuinely
#    truncated: no real terminator+marker ever follows the quoted line. ────
check "25: rc=0, summary quotes 'No material findings.' verbatim, then truncated -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

Overall assessment:
No material findings.' '')" "unavailable"
check "26: rc=0, summary quotes 'Findings:' verbatim, then truncated -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

The report structure typically looks like this:
Findings:' '')" "unavailable"

# ── CR round 4 ([glm-r3-3] sug, reproduced): the bullet check previously
#    scanned the WHOLE header region — a finding-shaped line inside the
#    summary's own prose could satisfy it even when the real Findings:
#    section (confirmed present) never got any actual bullets before
#    truncation. Under the line-walk, bullet-scanning only ever starts AFTER
#    the walk has independently confirmed the REAL "Findings:" line at its
#    position — a bullet-shaped line encountered while still in the
#    "summary" state is never evaluated against the bullet pattern at all. ─
check "27: rc=0, summary contains a finding-shaped bullet, real Findings: section truncated -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

Note: a well-formed finding line looks like this: - [high] Example finding (file.js:10) — but nothing like that was found in this diff.

Findings:' '')" "unavailable"

# ── CR round 4 micro-round ([codex-r4-1] sug, reproduced): line 3 previously
#    accepted ANY non-banner text — the renderer always emits "Target: ..."
#    there, so garbage at that position is not a genuine render even though
#    the rest of the document looks otherwise valid. ───────────────────────
check "28: rc=0, otherwise-valid-looking doc but line 3 is garbage, not Target: -> unavailable" \
    "$(status_of 0 '# Codex Adversarial Review

This is not a Target line at all.
Verdict: approve

Nothing of concern.

No material findings.' '')" "unavailable"

# ── CR round 5 [codex-adv-r4-1] (AGREED, KNOWN RESIDUAL — documented, not
#    "fixed"; see the script's header comment for the full investigation).
#    data.summary is inserted VERBATIM by the renderer and may embed its own
#    newlines, so a model's summary can contain an internal blank-line-
#    separated segment reading exactly like the real marker — here
#    "Assessment:\n\nNo material findings." as ONE summary string — and a
#    genuine truncation landing exactly at that internal boundary is
#    structurally indistinguishable from a real completion using stdout
#    alone. Investigated closing this via the companion .err log (the
#    DIRECTION given in round 5): ruled out — "Turn completion inferred" is
#    emitted ONLY on the companion's inferred/fallback completion path
#    (codex.mjs scheduleInferredCompletion), never on the primary
#    `turn/completed` path (which emits a DIFFERENT, status-dependent line
#    instead, including for non-success statuses) — no literal string in
#    companion 1.0.5 is unconditionally emitted across every completion path,
#    so requiring one would false-negative the common case rather than close
#    this gap safely. This fixture documents TODAY's actual (imperfect, but
#    honestly known) behavior: still ok, not unavailable. Upstream ask (an
#    unconditional end-of-render sentinel from the companion) is noted for a
#    ticket, not implemented here. ────────────────────────────────────────
check "29: rc=0, EXPECTED RESIDUAL — summary embeds the marker as an internal blank-line segment, truncated exactly there -> ok (documented gap, not closed)" \
    "$(status_of 0 '# Codex Adversarial Review

Target: origin/main...HEAD
Verdict: needs-attention

Assessment:

No material findings.' '')" "ok"

# ── HIMMEL-2056: the run-codex-adversarial.sh dormant skip (HIMMEL-1957,
#    CODEX_ADV_OK unset) writes exactly this one-line sentinel to stdout
#    instead of a genuine review render. It must classify as its OWN outcome
#    (absent) — never the HIMMEL-1420 silent-death "unavailable" class — so
#    the harvest fence records no ledger row and takes no retry for it. ─────
check "30: rc=0, dormant sentinel -> absent (not unavailable)" \
    "$(status_of 0 'codex-adv: dormant (HIMMEL-1957)' '')" "absent"
check "31: rc=0, dormant sentinel -> CLI exit 3" "$(rc_of 0 'codex-adv: dormant (HIMMEL-1957)' '')" "3"

# ── the sentinel is recognized only as the WHOLE stdout content — a genuine
#    completion can never take this shape (it always opens with the heading),
#    so this is safe without needing position-anchoring like the other
#    markers, but confirm a near-miss (trailing content) still falls through
#    to the ordinary line-walk and classifies unavailable. ──────────────────
check "32: rc=0, dormant-looking line plus trailing content -> unavailable, not absent" \
    "$(status_of 0 'codex-adv: dormant (HIMMEL-1957)
extra line' '')" "unavailable"

# ── critic-panel [codex-1] (CR round on HIMMEL-2056, reproduced): `$( )`
#    strips ALL trailing newlines, so comparing only `$(cat file)` to the
#    sentinel would ALSO match a malformed file carrying extra trailing
#    blank lines after it — a genuine dormant write is always exactly one
#    line, so this must classify unavailable (via the line-walk), not
#    absent. The line-count guard closes it. ─────────────────────────────
check "33: rc=0, sentinel plus trailing blank lines -> unavailable, not absent" \
    "$(status_of 0 'codex-adv: dormant (HIMMEL-1957)

' '')" "unavailable"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
