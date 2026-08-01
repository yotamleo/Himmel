#!/usr/bin/env bash
# scripts/cr/codex-adv-completion-check.sh — HIMMEL-1420
#
# Single tested source of truth for "did the step-3.1 codex adversarial-review
# harvest (.claude/commands/pr-check.md) see a GENUINE completion, or a silent
# death?" Observed 4x in leg 15 under the HIMMEL-1407 background-launch
# pattern: the codex-companion node process exits rc=0 with EMPTY stdout and a
# truncated companion .err — no final verdict ever emitted. The old harvest
# fence read rc=0 alone as success (`codex_findings=$(cat "$codex_out")`), so
# step 4.5 recorded `avail --model codex-adv --status ok` for a review that
# never actually ran (proven: the HIMMEL-1416 retry on the same diff came back
# needs-attention with two [high] findings — the rc=0/empty run was not clean,
# it was dead).
#
# A GENUINELY completed run always emits BOTH "# Codex Adversarial Review"
# AND a "Verdict:" line on stdout (operator observation, HIMMEL-1420). rc=0
# WITHOUT both markers is NOT sufficient evidence of a clean pass — it must be
# treated as UNAVAILABLE (a MISSING signal), never as clean-of-findings.
# Requiring BOTH (not just "Verdict:" alone, CR round 1 [codex-1]) matters: a
# stdout truncated to just a stray "Verdict:" line — with the heading itself
# cut off — would otherwise read as complete when it is exactly the kind of
# partial-write silent-death shape this check exists to catch.
#
# BOTH markers alone is still not enough (CR round 2 [codex-adv-1], confirmed
# against the actual companion source, scripts/lib/render.mjs
# renderReviewResult): when Codex's raw response fails to parse as the
# expected structured JSON, OR parses but fails shape validation, the
# companion renders a FAILURE banner ("Codex did not return valid structured
# JSON." / "Codex returned JSON with an unexpected review shape.") under the
# EXACT SAME "# Codex Adversarial Review" heading, with process exit 0 — and
# both banners can embed the model's raw malformed output VERBATIM inside a
# ```text fence. A Markdown-instead-of-JSON model response that happens to
# contain the literal substring "Verdict:" as prose then false-greens under a
# naive "both markers present anywhere" check.
#
# CR round 3 [codex-adv-r2-1] (reproduced): a naive FREE-SUBSTRING search for
# the two banner phrases has its own false-negative — the phrases are plain
# English and a genuinely SUCCESSFUL review's summary or finding body can
# legitimately quote them (very likely in a review discussing THIS sentinel),
# discarding a real review. Fix: the banners are recognized only at their
# EXACT structural position in the renderer's own line array — line 3 for the
# parse-error banner, line 4 for the validation-error banner (verified against
# renderReviewResult's literal `lines = [...]` construction) — never as a
# substring over reviewer-controlled content anywhere in the document.
#
# CR round 3 [codex-adv-r2-2] (reproduced): heading + Verdict: alone is STILL
# not sufficient — a stdout truncated immediately after the Verdict: line
# (findings lost) passed. The originally-proposed fix ("require the stable
# terminal section every completed render ends with, e.g. Next steps:") does
# NOT hold against the real source: both `Next steps:` (only when
# `next_steps.length > 0`) and `Reasoning:` (only when a non-empty
# reasoningSummary array is supplied) are CONDITIONAL — routinely absent on a
# genuine approve-with-no-suggestions review, so requiring either would
# false-negative the common case. The renderer's real invariant is narrower:
# `data.summary` is REQUIRED non-empty (enforced by validateReviewResultShape)
# and is unconditionally followed by EXACTLY ONE of two fixed lines — "No
# material findings." (zero findings) or "Findings:" (one or more) — this is
# the one branch point the source code genuinely always resolves.
#
# CR round 4 ([codex-r3-1] Important, [glm-r3-2]/[glm-r3-3] sug, all
# reproduced, one theme): checks 3-5 above were each REGION searches — "does
# this marker appear anywhere in the header region" — over TEXT THE REVIEWER
# CONTROLS (the summary, finding bodies). A summary that QUOTES "No material
# findings." or "Findings:" verbatim (plausible in a review discussing this
# very sentinel) could satisfy check 5 even on a genuinely truncated run; a
# finding-shaped line inside the summary could satisfy the bullet check too.
# `grep -qx 'No material findings.'` also had a bare regex metachar (the
# unescaped `.`, harmless here since `.` still matches a literal `.`, but
# sloppy and a real risk if the string ever changes to contain another
# metachar) — the whole class closes at once by not using region-grep at all.
#
# THE FIX: a single-pass, forward-only LINE-WALK matching the renderer's
# literal emission order (verified line-by-line against the same `lines =
# [...]` array): heading@1, blank@2, Target@3 (or the parse-error banner),
# Verdict@4 (or the validation-error banner), blank@5, then the SUMMARY block
# (one or more non-blank lines — `data.summary.trim()` is required non-empty,
# so line 6 itself can never be blank), terminated by the renderer's own
# blank-line separator — and the marker is checked ONLY at the line
# IMMEDIATELY after that terminator, never searched for anywhere else. A
# quoted marker phrase INSIDE the summary block is just more summary content
# to this walk (it only exits the summary state on a blank line), so it can
# never be mistaken for the real, renderer-emitted marker; a bullet-shaped
# line inside the summary is likewise never bullet-scanned, because that scan
# only starts once the walk has independently confirmed the REAL "Findings:"
# line at its position. One state-machine pass replaces every prior grep.
#
# So a genuine completion requires ALL of, walked in this exact order:
#   1. Heading opens the document (line 1).
#   2. Line 2 is blank.
#   3. Line 3 is not the parse-error banner (exact match), and DOES start
#      with "Target: " (CR round 4 [codex-r4-1] — the renderer always emits
#      this line; garbage/truncated content there is not a genuine render).
#   4. Line 4 is not the validation-error banner (exact match), and DOES
#      start with "Verdict: ".
#   5. Line 5 is blank.
#   6. One or more non-blank summary lines, ending at a blank line.
#   7. The line right after that blank is EXACTLY "No material findings."
#      (ok, zero findings) or EXACTLY "Findings:" (continue to 8).
#   8. At least one subsequent line matches the well-formed bullet shape
#      `- [<severity>] <title> (<file>)`.
# Any deviation — wrong content at a fixed position, EOF before the walk
# reaches step 7/8 — is unavailable. No stray text anywhere else in the
# document (inside the summary, inside a finding body, inside an echoed raw
# blob on a rejected banner path) is ever consulted a second time.
#
# KNOWN RESIDUAL LIMITATION (CR round 5 [codex-adv-r4-1], AGREED — verified,
# not fixed; see DIRECTION below for why). `data.summary` is inserted
# VERBATIM by the renderer (only `.trim()`'d at its outer boundary — no
# internal escaping or delimiting), and JS array elements may embed their own
# newlines, so a model's summary can itself contain a blank-line-separated
# segment reading exactly like one of the two marker lines — e.g. summary =
# "Assessment:\n\nNo material findings." — followed by a genuine truncation
# landing exactly at that internal boundary. This walk cannot distinguish
# that shape from a real renderer-emitted marker from stdout structure alone:
# it is a genuine ambiguity in the companion's own output FORMAT (no
# unambiguous delimiter separates renderer-authored structure from
# model-authored prose in the flattened text), not a flaw in the walk's
# implementation. `scripts/cr/test-codex-adv-completion-check.sh` documents
# this as an EXPECTED RESIDUAL fixture (still classifies ok) rather than
# silently ignoring it.
#
# DIRECTION INVESTIGATED (CR round 5): could the companion .err log — which
# IS a channel the reviewed model's prose cannot forge — supply an
# independent, unconditional "render actually finished" conjunct? Checked
# against the real companion source (openai-codex 1.0.5,
# ~/.claude/plugins/cache/openai-codex/codex/1.0.5/scripts/lib/codex.mjs):
# NO — ruled out. `completeTurn()` has three call sites. Two (codex.mjs:552,
# on the `turn/completed` notification; :603, an immediate-response edge
# case) are the PRIMARY/explicit paths and do NOT pass `{inferred: true}`,
# so they never emit "Turn completion inferred…" at all — instead the
# `turn/completed` path (:547-552, the realistic common case) emits a
# DIFFERENT progress line, `Turn ${status}.` (e.g. "Turn completed." — but
# also "Turn failed."/"Turn cancelled." for a NON-success status, via the
# exact same code path, so broadening the match to accept any `Turn …` line
# would itself accept non-clean outcomes). Only the THIRD call site
# (codex.mjs:391, via `scheduleInferredCompletion`, a 250ms-timer fallback
# used when NO explicit `turn/completed` notification ever arrives despite a
# final answer already being seen) passes `{inferred: true}` and emits "Turn
# completion inferred after the main thread finished and subagent work
# drained." — CONDITIONAL on that one fallback path, not unconditional
# across completions. (The wiring itself is sound — `createProgressReporter`
# in lib/tracked-jobs.mjs does write these lines to `process.stderr`, and our
# `--wait`, non-`--json` invocation passes `stderr: true` via
# runForegroundCommand, so they DO land in the captured `.err` file when they
# fire — the problem is only that no single one of them fires on every clean
# completion.) No literal string in 1.0.5 is a safe required conjunct;
# upgrading err_tail to REQUIRED as directed would false-negative the
# majority of genuine completions (which take the `turn/completed` path and
# never say "inferred" at all). Upstream ask for a ticket: the companion
# should emit ONE version-stable, unconditional "review render complete"
# sentinel — on every completion path, ideally on a channel/position a
# model's own prose cannot reach — that a harness could safely conjunct
# against; today's `.err` diagnostics don't provide that. If a future
# companion version adds such a signal, this contract should be tightened to
# require it (documented escape hatch — the day that happens, verify the
# exact wording against the new source before wiring it in, exactly as this
# investigation did for 1.0.5; never encode a guess).
#
# Exposes classify_codex_adv_completion <rc> [stdout_file] [stderr_file],
# which sets (and echoes, in CLI form) two lines:
#   status=ok|unavailable
#   err_tail=<last non-blank line of stderr_file, or (none)>
#
# err_tail is DIAGNOSTIC ONLY (HIMMEL-1420 point 2; CONFIRMED still-diagnostic
# by the round-5 investigation above) — it never flips status. A companion
# .err whose last line matches "Turn completion inferred" means the process
# took the inferred-completion fallback path and believes it finished; that
# is still recorded as `unavailable` when the stdout walk fails, because the
# harvest's CONTRACT is the stdout structure, not the companion's internal
# belief. Its ABSENCE proves nothing either way — the common `turn/completed`
# path never emits this exact line at all — so treat a MATCH as a useful
# positive hint for a human debugging a specific run, and a non-match as
# uninformative, never as evidence of death.
#
# Functions only when sourced — no side effect (mirrors failure-classify.sh).
# The CLI form below is BASH_SOURCE-guarded so it also runs standalone:
#   bash codex-adv-completion-check.sh <rc> [stdout_file] [stderr_file]
# Exit (CLI form): 0 = ok, 1 = unavailable, 2 = usage error.
# bash 3.2-safe. Deliberately NO top-level `set` when sourced (matches
# failure-classify.sh's contract — a sourced file must not mutate the
# caller's shell options); the CLI form sets its own options.

# ---------------------------------------------------------------------------
# classify_codex_adv_completion <rc> [stdout_file] [stderr_file]
# Sets CODEX_ADV_STATUS (ok|unavailable) and CODEX_ADV_ERR_TAIL. Returns 0 for
# ok, 1 for unavailable.
# ---------------------------------------------------------------------------
classify_codex_adv_completion() {
    _cac_rc="${1:-1}"
    _cac_out="${2:-}"
    _cac_err="${3:-}"

    CODEX_ADV_ERR_TAIL="(none)"
    if [ -n "$_cac_err" ] && [ -f "$_cac_err" ]; then
        _cac_tail="$(grep -v '^[[:space:]]*$' "$_cac_err" 2>/dev/null | tail -n 1)"
        [ -n "$_cac_tail" ] && CODEX_ADV_ERR_TAIL="$_cac_tail"
    fi

    CODEX_ADV_STATUS="unavailable"
    case "$_cac_rc" in
        0)
            if [ -n "$_cac_out" ] && [ -f "$_cac_out" ]; then
                # Single forward-only line-walk (CR round 4) — see the header
                # comment above for the full 8-step contract this encodes.
                # `sub(/\r$/, "", line)` defensively normalizes a stray CR
                # (CRLF) so an exact-equality check can't miss on that alone.
                _cac_status=$(awk '
                    BEGIN { state = "heading"; summary_seen = 0; done = 0 }
                    {
                        line = $0
                        sub(/\r$/, "", line)

                        if (state == "heading") {
                            if (line != "# Codex Adversarial Review") { print "unavailable"; done = 1; exit }
                            state = "line2"; next
                        }
                        if (state == "line2") {
                            if (line != "") { print "unavailable"; done = 1; exit }
                            state = "line3"; next
                        }
                        if (state == "line3") {
                            if (line == "Codex did not return valid structured JSON.") { print "unavailable"; done = 1; exit }
                            if (substr(line, 1, 8) != "Target: ") { print "unavailable"; done = 1; exit }
                            state = "line4"; next
                        }
                        if (state == "line4") {
                            if (line == "Codex returned JSON with an unexpected review shape.") { print "unavailable"; done = 1; exit }
                            if (substr(line, 1, 9) != "Verdict: ") { print "unavailable"; done = 1; exit }
                            state = "line5"; next
                        }
                        if (state == "line5") {
                            if (line != "") { print "unavailable"; done = 1; exit }
                            state = "summary"; next
                        }
                        if (state == "summary") {
                            if (line == "") {
                                if (summary_seen == 1) { state = "marker"; next }
                                print "unavailable"; done = 1; exit
                            }
                            summary_seen = 1; next
                        }
                        if (state == "marker") {
                            if (line == "No material findings.") { print "ok"; done = 1; exit }
                            if (line == "Findings:") { state = "bullets"; next }
                            print "unavailable"; done = 1; exit
                        }
                        if (state == "bullets") {
                            if (line ~ /^- \[.*\] .* \(.*\)$/) { print "ok"; done = 1; exit }
                            next
                        }
                    }
                    END { if (!done) print "unavailable" }
                ' "$_cac_out" 2>/dev/null)
                [ "$_cac_status" = "ok" ] && CODEX_ADV_STATUS="ok"
            fi
            ;;
        *) : ;;  # any non-zero rc is unavailable regardless of stdout content
    esac

    [ "$CODEX_ADV_STATUS" = "ok" ] && return 0
    return 1
}

# CLI form (not sourced): classify_codex_adv_completion <rc> [stdout_file] [stderr_file].
if [ "${BASH_SOURCE[0]:-}" = "${0}" ]; then
    set -uo pipefail
    [ $# -ge 1 ] || { echo "usage: codex-adv-completion-check.sh <rc> [stdout_file] [stderr_file]" >&2; exit 2; }
    classify_codex_adv_completion "$1" "${2:-}" "${3:-}"
    _cac_result=$?
    printf 'status=%s\n' "$CODEX_ADV_STATUS"
    printf 'err_tail=%s\n' "$CODEX_ADV_ERR_TAIL"
    exit "$_cac_result"
fi
