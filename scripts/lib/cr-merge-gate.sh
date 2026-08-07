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
#   Deny on:
#     - an unresolved PR review thread whose first comment is by coderabbitai
#     - a CodeRabbit commit status on the head SHA that is pending/failure/error
#     - NO CodeRabbit status on the head SHA at all ("absent")
#     - the latest bot REVIEW is anchored to a commit other than the head SHA
#       ("stale" — HIMMEL-1181, B2: a concluded STATUS does not mean a new
#       review OBJECT was posted; see cr-review-freshness.sh) or the review
#       window is indeterminate ("paged", >100 reviews with no bot match)
#   That last one is a deliberate break from the old "deny ONLY on positive
#   evidence" stance (HIMMEL-1072, operator call 2026-07-16): an unreviewed head
#   reading as green is what merged #1243 with 6 unresolved threads. Absence of a
#   review is now positive evidence of an unreviewed head, not a pass. A repo with
#   no CodeRabbit is detected automatically and gets a NO-OP gate (HIMMEL-1125,
#   scripts/lib/cr-available.sh) — before that probe existed, such a repo blocked
#   on EVERY merge until the adopter discovered CR_PROFILE=none.
#   INFRASTRUCTURE failures (gh missing, API error, no PR, parse failure) still
#   fail OPEN (rc 0/3) with a "cr-merge-gate: degraded (...) - failing open" note
#   — a broken query is not evidence of anything.
#   CR_MERGE_GATE_OK=1 or CR_PROFILE=none skip the gate entirely (rc 0).
#
#   The HIMMEL-980 zombie override is GONE: it keyed off a CodeRabbit check-run
#   that does not exist, so it had never run. Reviving it on the status would mean
#   waving through a >90m pending review on age alone — the same "uncertainty
#   reads as green" bug in a new coat. A genuinely stuck review blocks; use
#   CR_MERGE_GATE_OK=1. CR_ZOMBIE_CHECKRUN_MINS is therefore no longer read.
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`;
# does not toggle set -e. bash 3.2-safe. Each `jq` command substitution is
# made set -e-safe with a trailing `|| true` inside the subshell so that a
# caller running `set -e` (pr-merge.sh) does not abort on a jq parse failure
# (a parse failure is a normal fail-open input here, not a hard error).
# HIMMEL-936.

_cmg_degrade() { echo "cr-merge-gate: degraded ($*) - failing open" >&2; }

# The ONE reader for CodeRabbit's verdict (HIMMEL-1072). Sourced relative to this
# file so a hook can source this gate from any cwd.
# shellcheck source=scripts/lib/cr-signal.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-signal.sh"

# The ONE reader for "is the latest bot REVIEW OBJECT anchored to the head
# SHA?" (HIMMEL-1181, B2) — independent of the status verdict above and the
# body-findings reader below; see cr-review-freshness.sh header.
# shellcheck source=scripts/lib/cr-review-freshness.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-review-freshness.sh"

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

# The CR-ledger evidence reader (HIMMEL-1465): tells the skipped arm below
# whether a CLEAN critic panel carried the gate at the head, so a rate-limited
# CodeRabbit App need not block a direct `gh pr merge` when the panel reviewed.
# shellcheck source=scripts/lib/cr-ledger-evidence.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cr-ledger-evidence.sh"

# _cmg_canon_nwo <value> — canonical lowercase "owner/name", rc 1 if <value> is
# not one — as canonical "HOST/OWNER/NAME", host included. Two spellings would
# otherwise smuggle a merge past the gate (coderabbit-9), because anything that
# fails to compare equal to the local repo is treated as a foreign target and
# NOT gated:
#   - CASE: GitHub owner/name is case-insensitive, so `--repo O/R` is the SAME
#     repo as origin `o/r`. A bare string compare called it foreign.
#   - HOST: `gh` accepts `[HOST/]OWNER/REPO`, so `--repo github.com/o/r` is also
#     the same repo; the 3-segment form was being binned as malformed.
# The host is CARRIED, not dropped (coderabbit-11): `github.com/o/r` and
# `ghe.corp/o/r` are DIFFERENT repos that share an owner/name, and dropping the
# host made them compare equal — applying the local github availability answer to
# a GHE target. A bare `owner/repo` has no host, so it defaults to github.com
# (gh's own default host), which is what makes the common `--repo o/r` still
# match a `github.com/...` origin.
# Returns its answer in $_CMG_CANON rather than on stdout, and compares with a
# scoped `nocasematch` instead of lowercasing through `tr`. That is a
# PERFORMANCE contract, not a style choice: this gate runs in a PreToolUse hook
# on every `gh pr merge`, and on Git Bash a single fork costs ~1s. The first
# draft (`$(printf ... | tr ...)` twice per call) added ~3s to every merge and
# pushed the test suite past a 150s timeout. Parameter expansion forks nothing.
# (bash 3.2 has no ${v,,}, so nocasematch is the portable way to compare.)
_cmg_canon_nwo() {
    local v="${1:-}" host="github.com"
    _CMG_CANON=""
    case "$v" in
        ''|*[!A-Za-z0-9._/-]*) return 1 ;;      # empty or malformed charset
        */*/*/*) return 1 ;;                    # too many segments to be a repo spec
        */*/*) host=${v%%/*}; v=${v#*/} ;;      # HOST/OWNER/REPO -> host + OWNER/REPO
    esac
    case "$v" in
        /*|*/) return 1 ;;                      # leading/trailing slash
        */*) ;;                                 # OWNER/NAME — the only accepted shape
        *) return 1 ;;
    esac
    _CMG_CANON="$host/$v"
    return 0
}

# _cmg_nwo_eq <a> <b> — rc 0 iff both name the same repo, case-insensitively
# (GitHub owner/name is case-insensitive). nocasematch is saved and restored: a
# sourced lib must not leave shell options changed under its caller.
_cmg_nwo_eq() {
    local rc=0 had=0
    shopt -q nocasematch && had=1
    shopt -s nocasematch
    [[ "$1" == "$2" ]] || rc=1
    [ "$had" -eq 1 ] || shopt -u nocasematch
    return "$rc"
}

# _cmg_local_nwo — this clone's own <host>/<owner>/<name>, from origin. Empty
# when there is no origin or it is unparseable. Handles both URL shapes:
#   https://github.com/OWNER/NAME(.git)   git@github.com:OWNER/NAME(.git)
# The HOST is kept (coderabbit-11): _cmg_canon_nwo compares host + owner/name, so
# stripping it here would let a GHE origin be mistaken for its github.com
# namesake. The output feeds straight back into _cmg_canon_nwo (a HOST/OWNER/NAME
# is its 3-segment case), so both sides are canonicalized the same way.
_cmg_local_nwo() {
    local url rest host_nwo host path
    url=$(git config --get remote.origin.url 2>/dev/null) || return 1
    [ -n "$url" ] || return 1
    rest=${url%.git}
    case "$url" in
        # Strip userinfo in BOTH shapes (coderabbit-15): an `ssh://git@github.com/
        # o/r` origin otherwise yields `git@github.com/...`, whose `@` fails the
        # canon charset check, so the LOCAL clone becomes unidentifiable and every
        # `--repo` on it is waved through as foreign — a bypass on any ssh origin.
        *://*) host_nwo=${rest#*://}; host_nwo=${host_nwo#*@} ;; # scheme://[user@]host/owner/name
        *:*)   rest=${rest#*@};       host_nwo=${rest/://} ;;   # scp: [user@]host:owner/name -> host/owner/name
        *) return 1 ;;
    esac
    # Strip an optional :PORT off the HOST segment (CodeRabbit port-normalization
    # finding, PR #1470): a scheme-style origin with an explicit port —
    # `ssh://git@ghe.example.com:2222/o/r` or an https origin on a custom port —
    # leaves ":2222" glued onto host_nwo's host segment, and _cmg_canon_nwo's
    # charset check rejects ':'. That makes the LOCAL clone unidentifiable, so a
    # matching `--repo ghe.example.com/o/r` reads as foreign and the gate is
    # silently skipped. Applied AFTER the case above, on the already-split
    # host_nwo, so it is safe for BOTH branches: the scp branch's host_nwo can
    # never contain ':' here (an scp URL's one colon is the host/path separator,
    # already consumed by the `${rest/://}` substitution above), so this is a
    # no-op for it — only the scheme-style branch can carry a port.
    host=${host_nwo%%/*}
    path=${host_nwo#*/}
    host=${host%%:*}
    host_nwo="$host/$path"
    # host/owner/name (exactly three segments); reject anything else.
    case "$host_nwo" in
        */*/*/*|/*|*/) return 1 ;;
        */*/*) printf '%s\n' "$host_nwo" ;;
        *) return 1 ;;
    esac
}

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

    # 1) CodeRabbit's verdict on the head SHA (HIMMEL-1072).
    #
    # This runs BEFORE the thread query, and the order is load-bearing
    # (coderabbit-10). Threads-first loses a race: snapshot threads (clean at
    # T0) -> CodeRabbit posts its findings at T0.5 and flips its status to
    # success at T1 -> read the verdict (success) -> the gate passes over
    # threads it never saw. Reading the verdict first inverts that: once the
    # status says success CodeRabbit has CONCLUDED, so the thread set is final
    # and the query below sees all of it. Same principle as check-ci's
    # post-watch re-verification (codex-adv 980-r2) — establish that the
    # reviewer is done, THEN snapshot what it said.
    #
    # This block used to read `select(.name=="CodeRabbit")` over `.check_runs[]`
    # — which matched NOTHING, on every PR, since the day it shipped: CodeRabbit
    # publishes a commit STATUS, not a check-run (verified on 5 consecutive PRs;
    # see scripts/lib/cr-signal.sh). So this gate had never once blocked on an
    # in-flight review, and the HIMMEL-980 zombie override below it was
    # unreachable. The fixtures mocked CodeRabbit as a check-run, so the suite
    # confirmed the wrong shape rather than catching it.
    #
    # It now reads the real signal, identity-matched on creator.id, and treats
    # ABSENT as a blocker: "CodeRabbit has said nothing about this SHA" is the
    # exact state that let #1243 merge with 6 unresolved threads (HIMMEL-1072).
    # Absence of evidence is not evidence of a pass.
    # A FAILED status query must not return early (codex-1): doing so would skip
    # the thread query below and fail open over positive unresolved-thread
    # evidence the independent GraphQL call would have caught — and a transient
    # 503 on this endpoint is real (observed live 2026-07-17). So a degraded
    # verdict is REMEMBERED, not acted on: the threads are still read, positive
    # evidence still blocks, and the fail-open only happens at the end when
    # nothing blocked. Ordering is preserved for every non-degraded path.
    local cr_state cr_degraded=0
    cr_state=$(cr_signal_state "$owner" "$name" "$head") || cr_degraded=1
    if [ "$cr_degraded" -eq 0 ]; then
        case "$cr_state" in
            success)
                : ;; # concluded — the thread set below is now final
            pending)
                echo "BLOCK: CodeRabbit is still reviewing head $head of PR #$num (status=pending). Wait for it, then re-check threads. Bypass: CR_MERGE_GATE_OK=1."
                return 2 ;;
            failure|error)
                echo "BLOCK: CodeRabbit reported '$cr_state' on head $head of PR #$num — its review did not complete. Re-trigger it, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
            absent)
                echo "BLOCK: CodeRabbit has not reviewed head $head of PR #$num (no status on this SHA) — an unreviewed head must not merge (HIMMEL-1072). Wait for the review; if this repo has no CodeRabbit, set CR_PROFILE=none. Bypass: CR_MERGE_GATE_OK=1."
                return 2 ;;
            paged)
                # Indeterminate, not absent (coderabbit-2): page one was full and
                # held no CodeRabbit status, so its verdict may be on an unread page.
                # BLOCKS rather than degrades — a degrade fails OPEN, and "we could
                # not see the review" must never merge. Same stance as the >100
                # thread page-cap below.
                echo "BLOCK: head $head of PR #$num has more commit statuses than one API page (100) and none of them is CodeRabbit's — cannot certify the review. Check manually, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
            skipped)
                # HIMMEL-1317/1354: CodeRabbit posted success but SAID it did
                # not review — either auto-reviews are disabled, or the review
                # is rate limited. A declined review must not merge, for the
                # same reason `absent` must not. Wording aligned with
                # check-ci.sh's twin arm so both gates agree.
                #
                # HIMMEL-1465: ONLY the rate-limited decline is panel-carriable.
                # When the description is the rate-limit shape, a CLEAN critic
                # panel at this head carries the gate (operator standing rule) —
                # the same ledger evidence clear-cr-marker.sh gates 3-4 read,
                # evaluated by cr_ledger_carries_gate. A carried panel does NOT
                # merge here outright: it falls through to the thread + body
                # gates below exactly like a `success`, so "0 unresolved threads"
                # still binds. A rate-limited App with no clean panel, or any
                # other skip wording, keeps the BLOCK. Evidence is required for
                # the exception, so a description/ledger we cannot read falls
                # back to the block (the default for `skipped`), not a fail-open
                # allow.
                local rl_desc rl_low rl_panel
                rl_desc=$(cr_signal_description "$owner" "$name" "$head" 2>/dev/null || true)
                rl_low=$(printf '%s' "$rl_desc" | tr '[:upper:]' '[:lower:]')
                case "$rl_low" in
                    *rate?limit*|*ratelimit*) : ;;  # only rate-limit is panel-carriable
                    *)
                        echo "BLOCK: CodeRabbit SKIPPED the review on head $head of PR #$num — it posted success, but its description does not say the review completed. A DECLINED review is not a clean one. Known causes: automatic reviews are disabled on this repo (trigger one with a '@coderabbitai review' comment, wait for it to conclude, then re-check), or CodeRabbit is RATE LIMITED (HIMMEL-1354 — wait for the limit to reset; do NOT re-trigger in a loop). If this repo has no CodeRabbit, set CR_PROFILE=none. Bypass: CR_MERGE_GATE_OK=1."
                        return 2 ;;
                esac
                if rl_panel=$(cr_ledger_carries_gate "$head"); then
                    echo "ALLOW-note: CodeRabbit is rate-limited on head $head of PR #$num but the critic panel carries the gate ($rl_panel); the thread + body gates below still apply (HIMMEL-1465)." >&2
                    # fall through to the thread + body gates (like a `success`)
                else
                    echo "BLOCK: CodeRabbit is rate-limited on head $head of PR #$num and the critic panel did NOT carry the gate at this head (ledger: $rl_panel) — a rate-limited App with no clean panel is not a clean one. Wait for the App's limit to reset, or run /pr-check on this HEAD so a panel reviews it. Bypass: CR_MERGE_GATE_OK=1."
                    return 2
                fi
                ;;
            *)
                # Fail CLOSED on an unrecognised state. This case had no
                # catch-all, so a state cr-signal.sh learns to emit LATER would
                # fall straight through to the merge path — fail-open by
                # omission, which is the same class of bug as the `skipped` hole
                # above (an unhandled signal read as consent). check-ci's twin
                # case already had this arm; this brings the two gates back into
                # agreement, which is the whole point of a single reader.
                echo "BLOCK: unrecognized CodeRabbit state '$cr_state' on head $head of PR #$num — cannot certify the review. Check manually, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
        esac
    fi

    # 1.5) Review freshness (HIMMEL-1181, B2 / PR #1273): the status above
    # says the bot CONCLUDED on this head; this says the review OBJECT is
    # anchored to it. Those are different claims — CodeRabbit can conclude an
    # incremental status without posting a new review object at all — and
    # auto-resolved threads on a moved head make "zero unresolved" below
    # meaningless without this anchor check. Same remembered-degrade pattern
    # as `cr_degraded` above: an infra failure here is not evidence, so it is
    # remembered and only fails OPEN at the very end, after every independent
    # positive-evidence check (threads, body findings) has had its say.
    local fr_state fr_degraded=0
    fr_state=$(cr_review_freshness "$owner" "$name" "$num" "$head") || fr_degraded=1
    if [ "$fr_degraded" -eq 0 ]; then
        case "${fr_state%% *}" in
            stale)
                echo "BLOCK: the latest bot review on PR #$num is anchored to ${fr_state##* }, not head $head — this head was never re-reviewed (auto-resolved threads mask it). Wait for a fresh review, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
            paged)
                echo "BLOCK: PR #$num has more reviews than one query window (100) and none of the newest 100 is the bot's — cannot certify review freshness. Check manually, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
            none|fresh) : ;;   # none = adopter self-skip (no bot review yet); fresh = anchored, proceed
            *)
                echo "BLOCK: unrecognized review-freshness state '${fr_state%% *}' on head $head of PR #$num — cannot certify the review anchor. Check manually, or bypass with CR_MERGE_GATE_OK=1."
                return 2 ;;
        esac
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
    local body_line body_rc outside nitpick body_degraded=0 body_nitpick=0 tok
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
            outside=""; nitpick=""
            for tok in $body_line; do
                case "$tok" in
                    outside=*) outside=${tok#outside=} ;;
                    nitpick=*) nitpick=${tok#nitpick=} ;;
                esac
            done
            # Validate EACH field independently, NOT the concatenation (CR #1297):
            # an empty/missing `outside` masked by the joined string (nitpick=5 ->
            # "5" passes the all-digits test) would let `[ "$outside" -gt 0 ]` below
            # error on the empty value, read as false, and the outside-diff gate
            # fail OPEN. Per-field guards fail closed (degraded) — mirrors the same
            # fix in check-ci.sh's cr_body_gate.
            _body_bad=0
            for _v in "$outside" "$nitpick"; do
                case "$_v" in
                    ''|*[!0-9]*) _body_bad=1 ;;
                esac
            done
            if [ "$_body_bad" -eq 1 ]; then
                body_degraded=1
            elif [ "$outside" -gt 0 ]; then
                echo "BLOCK: CodeRabbit's review body reports $outside outside-diff-range finding(s) on head $head of PR #$num — these carry no thread to resolve. Fix + address them, or bypass with CR_MERGE_GATE_OK=1 in the launching shell if already adjudicated."
                return 2
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
    # degraded, THIS is where we fail open (codex-1 / HIMMEL-1126) — only
    # after the independent evidence above had its say. A broken query is not
    # evidence; unresolved threads and outside-diff findings are. Freshness
    # (fr_degraded) is intentionally NOT folded into this same early return
    # (HIMMEL-1181): it is an independent reader from the body-findings one
    # (see cr-review-freshness.sh header), so its own infra failure must not
    # suppress a body_nitpick note the OTHER reader already read validly —
    # checked separately below, after the note.
    if [ "$cr_degraded" -eq 1 ] || [ "$body_degraded" -eq 1 ]; then
        [ "$cr_degraded" -eq 1 ] && _cmg_degrade "CodeRabbit status query failed"
        [ "$body_degraded" -eq 1 ] && _cmg_degrade "cr-body-findings query/parse failed"
        [ "$fr_degraded" -eq 1 ] && _cmg_degrade "review-freshness query failed"
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

    if [ "$fr_degraded" -eq 1 ]; then
        _cmg_degrade "review-freshness query failed"
        return 0
    fi

    return 0
}
