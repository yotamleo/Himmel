#!/usr/bin/env bash
# cr-merge-gate.sh — shared predicate for the HIMMEL-936 CR merge gate.
#
# cr_merge_gate <pr-selector> [<owner/repo>]
#   rc 0 = allow; rc 2 = block, one-line reason on stdout.
#   rc 3 = allow, but the SELECTOR did not resolve to a PR (gh pr view failed)
#          — callers that extracted the selector heuristically (the PreToolUse
#          hook) should retry once with a better-anchored selector (the cwd
#          branch) so quoted/mis-tokenized selectors cannot dodge the gate
#          (codex-1 / codex-adv-1, HIMMEL-936 CR round). Top-level consumers
#          treat any non-2 rc as allow.
#   HIMMEL-3360 (operator ruling 2026-09-21): CodeRabbit is best effort. Deny
#   only on an unresolved coderabbitai review thread, or an outside-diff body
#   finding with no ledger disposition at this exact head — CodeRabbit's
#   commit-status state (pending/absent/paged/skipped/etc.) prints an
#   advisory NOTE and falls through; it never blocks on its own.
#
#   A repo with no CodeRabbit is detected automatically and gets a NO-OP gate
#   (HIMMEL-1125, scripts/lib/cr-available.sh).
#   INFRASTRUCTURE failures (gh missing, API error, no PR, parse failure) still
#   fail OPEN (rc 0/3) with a "cr-merge-gate: degraded (...) - failing open" note
#   — a broken query is not evidence of anything.
#   CR_MERGE_GATE_OK=1 or CR_PROFILE=none skip the gate entirely (rc 0).
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`;
# does not toggle set -e. bash 3.2-safe. Each `jq` command substitution is
# made set -e-safe with a trailing `|| true` inside the subshell so that a
# caller running `set -e` (pr-merge.sh) does not abort on a jq parse failure
# (a parse failure is a normal fail-open input here, not a hard error).
# HIMMEL-936.

_cmg_degrade() { echo "cr-merge-gate: degraded ($*) - failing open" >&2; }

# _cmg_prior_outside_block — HIMMEL-3360 operator ruling + HIMMEL-3379: the
# PR's real head carries no CodeRabbit review of its own, but prior head(s)
# carry posted outside-diff findings. EVERY such head governs
# (cr_body_prior_outside_heads), each finding dispositioned at the head that
# raised it — a newer prior review must not mask an older head's finding
# (mirrors check-ci's _cr_prior_outside_gate, HIMMEL-3365). Every blocking
# head's reason is printed on stdout; rc 2 if any blocks. Reads
# $owner/$name/$num/$head from the caller (cr_merge_gate), same dynamic-scoping
# convention as every other _cmg_* helper here.
_cmg_prior_outside_block() {
    local heads ph out msg="" rc=0
    heads=$(cr_body_prior_outside_heads "$owner" "$name" "$num" "$head") || heads=""
    if [ -z "$heads" ]; then
        echo "BLOCK: could not resolve which prior heads carry CodeRabbit's outside-diff findings on PR #$num — cannot check for a disposition; re-run."
        return 2
    fi
    while IFS= read -r ph; do
        [ -n "$ph" ] || continue
        if ! out=$(_cmg_outside_block "$ph" ""); then
            rc=2
            msg="${msg:+$msg
}$out"
        fi
    done <<<"$heads"
    [ "$rc" -eq 0 ] || echo "$msg"
    return "$rc"
}

# _cmg_outside_block <gate_head> <expected_count> — HIMMEL-3124/HIMMEL-3360.
# Reads + dispositions the outside-diff findings CodeRabbit posted AT
# <gate_head> — either the PR's real head, or (HIMMEL-3360/3379) a PRIOR head
# _cmg_prior_outside_block walks, when the real head carries no review of its
# own (best effort covers ABSENCE at that head only, never a finding
# CodeRabbit already posted at a prior one). <expected_count> is the
# reader's own header count for a format-drift cross-check; empty skips it
# (the prior-head path's own header-vs-parsed check inside the reader already
# covers it). rc 0 = allow (ALLOW note on stderr); rc 2 = block (BLOCK reason
# already echoed to stdout, same convention as every other block here).
_cmg_outside_block() {
    local gate_head="$1" expected="$2"
    local od_rows od_rc od_id od_file od_line od_n=0 od_ok=0 od_list="" extra="" prefix=""
    od_rows=$(cr_body_outside_findings "$owner" "$name" "$num" "$gate_head")
    od_rc=$?
    case "$od_rc" in
        0) ;;
        2)
            echo "BLOCK: CodeRabbit's review body on head $gate_head of PR #$num lists outside-diff findings the parser cannot fully read (format drift, cannot count) — check the PR body manually, or bypass with CR_MERGE_GATE_OK=1."
            return 2 ;;
        *)
            echo "BLOCK: CodeRabbit's review body reports outside-diff-range finding(s) on head $gate_head of PR #$num but the per-finding read failed — cannot check for a disposition; re-run."
            return 2 ;;
    esac
    if [ "$gate_head" != "$head" ]; then
        extra='   (or: --verdict fixed --reason "fixed in <sha>")'
    fi
    while IFS=$'\t' read -r od_id _ od_file od_line _; do
        [ -n "$od_id" ] || continue
        od_n=$((od_n + 1))
        if [ "$gate_head" != "$head" ]; then
            if cr_ledger_outside_dispositioned "$gate_head" "$od_id" "$od_file" "$od_line" "$head"; then
                od_ok=$((od_ok + 1))
            else
                od_list="$od_list [$od_id $od_file:$od_line]"
            fi
        else
            if cr_ledger_outside_dispositioned "$gate_head" "$od_id" "$od_file" "$od_line"; then
                od_ok=$((od_ok + 1))
            else
                od_list="$od_list [$od_id $od_file:$od_line]"
            fi
        fi
    done <<<"$od_rows"
    if [ -n "$expected" ] && [ "$od_n" -ne "$expected" ]; then
        echo "BLOCK: CodeRabbit's review body on head $gate_head of PR #$num counts $expected outside-diff finding(s) but $od_n parsed out (format drift, cannot count) — check the PR body manually, or bypass with CR_MERGE_GATE_OK=1."
        return 2
    fi
    if [ "$od_ok" -lt "$od_n" ]; then
        if [ "$gate_head" != "$head" ]; then
            prefix="head $head of PR #$num carries no CodeRabbit review (best effort, HIMMEL-3360: nothing waits or re-triggers); a prior review, at head $gate_head, "
        else
            prefix="CodeRabbit's review body "
        fi
        echo "BLOCK: ${prefix}reports $od_n outside-diff-range finding(s) on head $gate_head of PR #$num, $((od_n - od_ok)) not dispositioned:$od_list — these carry no thread to resolve. Fix them, or record an explicit disposition at head $gate_head (ledger-append.sh finding --model coderabbit-outside --verdict deferred --deferred-to <TICKET> --reason <why>; check-ci.sh prints the full recipe), or --verdict fixed --reason \"fixed in <sha>\"; or bypass with CR_MERGE_GATE_OK=1 in the launching shell if already adjudicated.$extra"
        return 2
    fi
    echo "ALLOW: PR #$num — CodeRabbit's review body reports outside-diff dispositioned=$od_ok (each has an explicit ledger disposition at head $gate_head)." >&2
    return 0
}

# The ONE reader for CodeRabbit's verdict (HIMMEL-1072). Sourced relative to this
# file so a hook can source this gate from any cwd.
# shellcheck source=scripts/lib/cr-signal.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-signal.sh"

# The ONE reader for CodeRabbit's review-BODY findings (HIMMEL-1126/1147) —
# outside-diff-range / nitpick / additional comments the thread gate below
# cannot see (S1: no thread, no isResolved, unresolvable by construction).
# shellcheck source=scripts/lib/cr-body-findings.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-body-findings.sh"

# Is CodeRabbit configured here at all (HIMMEL-1125)? Same posture as check-ci:
# this whole gate is CodeRabbit-specific, so on a repo without it the gate is a
# no-op rather than a permanent block on "absent".
# shellcheck source=scripts/lib/cr-available.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-available.sh"

# The CR-ledger evidence reader (HIMMEL-1465): tells the outside-diff body-
# findings gate below (stage 3) whether a given finding carries an explicit
# disposition at this exact head (deferred + tracked ticket, or disproved).
# shellcheck source=scripts/lib/cr-ledger-evidence.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-ledger-evidence.sh"

# _cmg_canon_nwo / _cmg_nwo_eq / _cmg_local_nwo — moved to scripts/lib/nwo.sh
# (HIMMEL-2034) so the CodeRabbit TRIGGER path can reuse the same "is this OUR
# repo?" answer instead of re-deriving origin-URL parsing. Names unchanged.
# shellcheck source=scripts/lib/nwo.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nwo.sh"

cr_merge_gate() {
    [ "${CR_MERGE_GATE_OK:-0}" = "1" ] && return 0

    local sel="${1:-}" repo="${2:-}"

    # Availability gate (HIMMEL-1125). Silent: an adopter without CodeRabbit must
    # not see a CodeRabbit gate announce itself. Subsumes the old
    # `CR_PROFILE=none` early return — cr_app_configured reads that switch first,
    # so an operator who set it sees identical behaviour.
    #
    # cr_app_configured describes THIS clone (a repo-scoped git config), so it
    # may only answer for this clone (codex-adv-2). `gh pr merge 42 --repo
    # other/thing` targets a repo we hold no availability signal for — applying
    # the local answer there would BOTH falsely block (local armed, target has no
    # CodeRabbit) and falsely pass (local disarmed, target uses it). We have no
    # signal, so we do not gate, consistent with the default-disarmed posture.
    # A foreign target is checked BEFORE the local probe so that this costs no
    # gh call in either direction.
    # Only a WELL-FORMED owner/name counts as a foreign target. A mis-tokenized
    # value — `--repo "o/r"` arriving with its quotes, a flag, a fragment — is
    # NOT a foreign repo, and must fall through to the existing rc=3 re-anchor
    # path (HIMMEL-936 codex-1). Short-circuiting on garbage here would mean a
    # quoted --repo SILENTLY DISABLES this gate: a worse bypass than the one the
    # foreign-target check exists to close. Both sides are canonicalized so a
    # mere spelling (case, or a HOST/ prefix) cannot make the local repo look
    # foreign and skip the gate (coderabbit-9).
    if [ -n "$repo" ]; then
        local repo_canon local_canon
        # Not a parseable repo spec -> fall through, so the rc=3 re-anchor path
        # still sees it (that is the malformed-value case above).
        if _cmg_canon_nwo "$repo"; then
            repo_canon="$_CMG_CANON"
            local_canon=""
            if _cmg_canon_nwo "$(_cmg_local_nwo || true)"; then local_canon="$_CMG_CANON"; fi
            if [ -n "$local_canon" ]; then
                _cmg_nwo_eq "$repo_canon" "$local_canon" || return 0
            else
                # Origin didn't parse (no origin remote, a file:// origin, a
                # trailing-slash URL, ...). Arming is a deliberate per-clone
                # act, so an armed-but-unparseable clone is treated as LOCAL
                # (fall through and gate) rather than silently disabled as
                # foreign (HIMMEL-1404 T9). An unarmed clone still exits here
                # via the same cr_app_configured check used below, preserving
                # today's unarmed behaviour.
                cr_app_configured "$PWD" || return 0
            fi
        fi
    fi
    cr_app_configured "$PWD" || return 0
    if [ -z "$sel" ]; then _cmg_degrade "no PR selector"; return 0; fi
    command -v gh >/dev/null 2>&1 || { _cmg_degrade "gh not on PATH"; return 0; }
    command -v jq >/dev/null 2>&1 || { _cmg_degrade "jq not on PATH"; return 0; }

    local meta url num head owner name
    if [ -n "$repo" ]; then
        meta=$(gh pr view "$sel" --repo "$repo" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    else
        meta=$(gh pr view "$sel" --json number,headRefOid,url 2>/dev/null) || { _cmg_degrade "gh pr view failed (selector '$sel' unresolvable)"; return 3; }
    fi
    num=$(printf '%s' "$meta" | jq -r '.number // empty' 2>/dev/null || true)
    head=$(printf '%s' "$meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
    url=$(printf '%s' "$meta" | jq -r '.url // empty' 2>/dev/null || true)
    if [ -z "$num" ] || [ -z "$head" ] || [ -z "$url" ]; then _cmg_degrade "pr metadata incomplete"; return 0; fi
    # url shape: https://github.com/OWNER/NAME/pull/N
    owner=$(printf '%s' "$url" | sed -n 's|^https://[^/]*/\([^/]*\)/.*|\1|p')
    name=$(printf '%s' "$url"  | sed -n 's|^https://[^/]*/[^/]*/\([^/]*\)/.*|\1|p')
    if [ -z "$owner" ] || [ -z "$name" ]; then _cmg_degrade "cannot parse owner/name from $url"; return 0; fi

    # 1) CodeRabbit's verdict on the head SHA is advisory only (HIMMEL-3360,
    # operator ruling 2026-09-21: CodeRabbit is best effort). The read still
    # happens BEFORE the thread query below (coderabbit-10) for the same
    # ordering reason as before: once CodeRabbit has concluded (`success`),
    # the thread set the query below sees is final. Threads-first would lose
    # a race — snapshot threads (clean at T0) -> CodeRabbit posts findings at
    # T0.5 and flips status to success at T1 -> the gate would pass over
    # threads it never saw. Any state other than `success` — pending,
    # failure/error, absent, paged, skipped (rate-limited or auto-reviews
    # disabled), or an unrecognized state — is NEVER gating on its own; it
    # prints one advisory NOTE and falls through to the thread + body-
    # findings gates below, unchanged.
    #
    # A FAILED status query must not return early (codex-1): doing so would
    # skip the thread query below and fail open over positive unresolved-
    # thread evidence the independent GraphQL call would have caught — and a
    # transient 503 on this endpoint is real (observed live 2026-07-17). So a
    # degraded verdict is REMEMBERED, not acted on: the threads are still
    # read, positive evidence still blocks, and the fail-open only happens at
    # the end when nothing blocked.
    local cr_state cr_degraded=0
    cr_state=$(cr_signal_state "$owner" "$name" "$head") || cr_degraded=1
    if [ "$cr_degraded" -eq 0 ] && [ "$cr_state" != "success" ]; then
        echo "NOTE: CodeRabbit $cr_state on head $head of PR #$num — best effort (HIMMEL-3360), not gating; the thread + body-findings gates below still apply."
    fi

    # 2) unresolved coderabbitai review threads — read only now that CodeRabbit
    # has concluded, so the set is complete. Still read when the verdict query
    # degraded (see above): its evidence is independent and blocks on its own.
    local threads unresolved threads_page_complete
    # shellcheck disable=SC2016  # GraphQL variables ($owner/$name/$number) are literal here
    threads=$(gh api graphql \
        -f owner="$owner" -f name="$name" -F number="$num" \
        -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage} nodes{isResolved path line comments(first:1){nodes{author{login}}}}}}}}' \
        2>/dev/null) || { _cmg_degrade "reviewThreads query failed"; return 0; }
    # Page-completeness marker (HIMMEL-980 codex-adv-1): this single-page query
    # is the hook's ONLY thread evidence, so "zero unresolved on page one" is a
    # pass ONLY when page one was the whole story. It now feeds exactly one
    # consumer: the >100-thread BLOCK below (coderabbit-5 — it used to gate the
    # zombie override, which HIMMEL-1072 removed).
    # `== false` on purpose (coderabbit 980-r2): only an EXPLICIT
    # hasNextPage:false proves completeness — a missing/null pageInfo yields
    # "false" here (so an unprovable page blocks). jq's `//` operator cannot
    # express this: `hasNextPage // true` swallows a legitimate false.
    threads_page_complete=$(printf '%s' "$threads" | jq -r \
        '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage == false' \
        2>/dev/null || echo false)
    unresolved=$(printf '%s' "$threads" | jq -r \
        '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i"))] | length' \
        2>/dev/null || true)
    if [ -z "$unresolved" ]; then _cmg_degrade "reviewThreads parse failed"; return 0; fi
    # >100 threads with zero unresolved ON PAGE ONE is not a pass — it is
    # positive evidence of threads this single-page query never counted
    # (coderabbit 980-r3). Unlike an API/parse failure (degrade, fail open),
    # this blocks: the state is knowable, just not from one page. A real PR
    # with 100+ CodeRabbit threads is pathological — check manually or bypass.
    if [ "$unresolved" -eq 0 ] 2>/dev/null && [ "$threads_page_complete" != "true" ]; then
        echo "BLOCK: PR #$num has more review threads than the gate's single page (100) — cannot certify zero unresolved CodeRabbit threads. Check threads manually, or bypass with CR_MERGE_GATE_OK=1."
        return 2
    fi
    if [ "$unresolved" -gt 0 ] 2>/dev/null; then
        # List the offending threads (path:line) so the block is actionable and
        # the bypass is front-and-center (false-block trust erosion mitigation,
        # plan-critic #5).
        local locs
        locs=$(printf '%s' "$threads" | jq -r \
            '[.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | select((.comments.nodes[0].author.login // "") | test("coderabbit"; "i")) | "\(.path // "?"):\(.line // "?")"] | join(", ")' \
            2>/dev/null || true)
        echo "BLOCK: $unresolved unresolved CodeRabbit review thread(s) on PR #$num [$locs]. Fix + RESOLVE each thread (operator rule 2026-07-12), or bypass with CR_MERGE_GATE_OK=1 in the launching shell if already adjudicated."
        return 2
    fi

    # 3) CodeRabbit review-BODY findings (HIMMEL-1126/1147, S1 — see
    # cr-body-findings.sh header): outside-diff-range comments carry NO
    # thread, so every gate above is blind to them by construction. Read only
    # now that CodeRabbit has concluded and the thread set above is final —
    # same ordering rationale as (1)/(2).
    #
    # Fail-open/closed asymmetry is DELIBERATE here (spec §4) — this is a
    # merge HOOK, not the certifier (check-ci fails closed on the same two
    # codes). An INFRASTRUCTURE failure (rc 1: query/parse error) is
    # remembered and only fails OPEN at the very end, mirroring cr_degraded —
    # a broken query is not evidence. An anti-drift CANARY (rc 2: the body
    # SHOWS a section keyword but the count would not parse) is POSITIVE
    # evidence of an unparseable finding and BLOCKS outright, same rank as
    # outside>0 itself. `nitpick` is surfaced on the ALLOW note only
    # (HIMMEL-1147: the failure was invisibility, not permissiveness —
    # blocking Trivial-severity findings tanks the loop).
    local body_line body_rc outside nitpick prior_outside substantive body_degraded=0 body_nitpick=0 tok
    body_line=$(cr_body_findings "$owner" "$name" "$num" "$head")
    body_rc=$?
    case "$body_rc" in
        0)
            # Word-split + anchor on `case`, NOT a `.*key=` sed/grep regex: the
            # reader's line has both `outside=` and `prior_outside=`, and an
            # unanchored `.*outside=` regex greedily matches the LATTER
            # (matched the drift-canary test's own fixture during dev — a
            # real bug this reader-line shape invites). `case` patterns match
            # from the START of the token, so `outside=*` cannot match a
            # token that begins with `prior_outside=`.
            outside=""; nitpick=""; prior_outside=""; substantive=""
            for tok in $body_line; do
                case "$tok" in
                    outside=*) outside=${tok#outside=} ;;
                    nitpick=*) nitpick=${tok#nitpick=} ;;
                    prior_outside=*) prior_outside=${tok#prior_outside=} ;;
                    substantive=*) substantive=${tok#substantive=} ;;
                esac
            done
            # Validate EACH field independently, NOT the concatenation (CR #1297):
            # an empty/missing `outside` masked by the joined string (nitpick=5 ->
            # "5" passes the all-digits test) would let `[ "$outside" -gt 0 ]` below
            # error on the empty value, read as false, and the outside-diff gate
            # fail OPEN. Per-field guards fail closed (degraded) — mirrors the same
            # fix in check-ci.sh's cr_body_gate.
            _body_bad=0
            for _v in "$outside" "$nitpick" "$prior_outside" "$substantive"; do
                case "$_v" in
                    ''|*[!0-9]*) _body_bad=1 ;;
                esac
            done
            if [ "$_body_bad" -eq 1 ]; then
                body_degraded=1
            elif [ "$prior_outside" -gt 0 ] && [ "$substantive" -eq 0 ] && [ "$outside" -eq 0 ]; then
                # HIMMEL-3360 operator ruling (2026-09-21): best effort covers
                # ABSENCE at THIS head only — every prior head's ALREADY-POSTED
                # outside-diff findings still govern the gate, keyed to the
                # head that actually carries them (HIMMEL-3379).
                _cmg_prior_outside_block || return 2
                body_nitpick="$nitpick"
            elif [ "$outside" -gt 0 ]; then
                # HIMMEL-3124: each outside-diff finding may carry an explicit
                # ledger disposition AT THIS EXACT HEAD (deferred + tracked
                # ticket + reason, or disproved + reason) — same reader and rule
                # as check-ci.sh. Anything undispositioned, or a list that cannot
                # be read/trusted, BLOCKS (a known outside>0 is never failed open).
                _cmg_outside_block "$head" "$outside" || return 2
                body_nitpick="$nitpick"
            else
                body_nitpick="$nitpick"
            fi
            ;;
        1)
            body_degraded=1 ;;
        2)
            echo "BLOCK: CodeRabbit's review body on head $head of PR #$num shows a finding the parser cannot count (format drift) — positive evidence of an unparseable finding (HIMMEL-1126). Check the PR body manually, or bypass with CR_MERGE_GATE_OK=1."
            return 2 ;;
        *)
            body_degraded=1 ;;
    esac

    # Nothing blocked. If the verdict query or the body-findings reader
    # degraded, note it (codex-1 / HIMMEL-1126) — a broken query is not
    # evidence; unresolved threads and outside-diff findings are, and both
    # are already checked above.
    if [ "$cr_degraded" -eq 1 ] || [ "$body_degraded" -eq 1 ]; then
        [ "$cr_degraded" -eq 1 ] && _cmg_degrade "CodeRabbit status query failed"
        [ "$body_degraded" -eq 1 ] && _cmg_degrade "cr-body-findings query/parse failed"
        return 0
    fi

    # stderr, not stdout (codex CR round): both hook callers only capture +
    # print `reason=$(cr_merge_gate ...)` when it BLOCKs (rc 2) — an ALLOW-
    # path echo on stdout here would be captured into $reason and then
    # silently dropped on every allow. stderr surfaces it regardless of
    # what the caller does with stdout, same as every _cmg_degrade note above.
    if [ "$body_nitpick" -gt 0 ]; then
        echo "ALLOW: PR #$num — CodeRabbit's review body also reports nitpick=$body_nitpick (non-blocking)." >&2
    fi

    return 0
}
