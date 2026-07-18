#!/usr/bin/env bash
# cr-signal.sh — the ONE reader for "what did CodeRabbit say about this SHA?"
# (HIMMEL-1072 / HIMMEL-1058).
#
# WHY THIS EXISTS — the shape nobody checked:
# CodeRabbit publishes its verdict as a COMMIT STATUS, not a check-run.
# Verified live on 5 consecutive PRs (#1249/#1247/#1246/#1238/#1243):
#
#   gh api repos/OWNER/NAME/commits/<sha>/check-runs -> CodeRabbit count = 0
#   gh api repos/OWNER/NAME/commits/<sha>/statuses   -> CodeRabbit count = 3..5
#
# Every `select(.name=="CodeRabbit")` over `.check_runs[]` therefore matched
# NOTHING: cr-merge-gate's in-flight block and check-ci's zombie override were
# dead code that had never once fired. The test fixtures mocked CodeRabbit as a
# check-run, so the suite stayed green against a shape production never emits.
# `statusCheckRollup` (what `gh pr checks` reads) merges check-runs AND statuses,
# which is why the rollup showed CodeRabbit while the check-runs API did not.
#
# ENDPOINT CHOICE (this is the load-bearing detail):
# HIMMEL-1058 wants the bot matched by IDENTITY, not display name. Only the
# /statuses LIST endpoint carries one:
#   /commits/<sha>/status   (combined) -> creator is NULL. No identity. Unusable.
#   /commits/<sha>/statuses (list)     -> creator{id,login,type}. Usable.
#   statusCheckRollup                  -> StatusContext{context,state}. No identity.
# A commit status has no .app.id/.app.slug (only check-runs do), so the identity
# is the CREATOR: id 136622811 = coderabbitai[bot]. Match on the ID — logins are
# mutable, display names are spoofable.
#
# ORDERING: GitHub returns statuses in reverse-chronological order and CodeRabbit
# posts several per head (queued -> in progress -> completed), so the FIRST match
# is the current verdict — the same one the combined endpoint dedupes to.
#
# cr_signal_state <owner> <name> <sha>
#   stdout: success | pending | failure | error | absent | paged
#           "absent" = CodeRabbit has posted NOTHING for this SHA. It is NOT a
#           pass. Callers gate on it (HIMMEL-1072: absent must never read green).
#           "paged" = page one was FULL and held no CodeRabbit status, so its
#           verdict may sit on an unread page — indeterminate, never "absent".
#           Callers must fail CLOSED on it (coderabbit-2).
#   rc 0 = state determined (incl. "absent"); rc 1 = cannot evaluate (query or
#           parse failure) — the caller decides open/closed, this reader does not.
#
# cr_signal_probe <owner> <name> <sha>
#   Same query, but stdout is "<state> <created_at>" (created_at empty when
#   absent) so a caller can age a stuck `pending` without a second API call.
#   Both values ride stdout on purpose: every caller reads this via `$(...)`,
#   which forks a subshell — a global set inside could never reach them.
#   cr_signal_state is the thin wrapper for callers that only need the state.
#
#   A SHA that does not exist returns `[]` with HTTP 200 on this endpoint, so it
#   is indistinguishable from "no CodeRabbit status" and reports "absent". That
#   conflation is safe in one direction only — every caller fails CLOSED on
#   absent — and callers pass a headRefOid that by construction exists.
#
# Env:
#   CR_BOT_USER_ID     creator.id to trust (default 136622811 = coderabbitai[bot])
#   CR_STATUS_CONTEXT  status context to read (default "CodeRabbit")
#   GH_CMD             gh override (test seam, matches the forge backends)
#
# Sourceable from hooks and scripts: uses only `return`, never `exit`; does not
# toggle set -e. bash 3.2-safe.

_crs_gh() { "${GH_CMD:-gh}" "$@"; }

# The identity, in ONE place. ci-green-gate needs the same pair to EXCLUDE
# CodeRabbit's status from the CI aggregate it owns, so both gates agree on
# what "a CodeRabbit status" is by construction rather than by coincidence.
cr_signal_bot_id()  { printf '%s\n' "${CR_BOT_USER_ID:-136622811}"; }
cr_signal_context() { printf '%s\n' "${CR_STATUS_CONTEXT:-CodeRabbit}"; }

cr_signal_state() {
    local probe
    probe=$(cr_signal_probe "$@") || return 1
    printf '%s\n' "${probe%% *}"
}

cr_signal_probe() {
    local owner="$1" name="$2" sha="$3"
    local uid ctx
    uid=$(cr_signal_bot_id)
    ctx=$(cr_signal_context)

    if [ -z "$owner" ] || [ -z "$name" ] || [ -z "$sha" ]; then return 1; fi
    case "$uid" in ''|*[!0-9]*) return 1 ;; esac

    local json
    json=$(_crs_gh api "repos/$owner/$name/commits/$sha/statuses?per_page=100" 2>/dev/null) || return 1

    # Canary FIRST: a valid payload is a JSON array (possibly empty). An error
    # object or a parse failure yields empty here -> cannot evaluate (rc 1),
    # which is distinct from a well-formed array that simply has no CodeRabbit
    # status in it ("absent"). Collapsing those two would recreate the bug this
    # file exists to kill.
    local kind
    kind=$(printf '%s' "$json" | jq -r 'if type=="array" then "array" else empty end' 2>/dev/null || true)
    [ "$kind" = "array" ] || return 1

    # Identity match on creator.id (+ type Bot), context as the secondary filter.
    # First match wins = newest = current verdict (see ORDERING above).
    local pair state created
    pair=$(printf '%s' "$json" | jq -r --arg ctx "$ctx" --argjson uid "$uid" '
        [ .[]?
          | select(.creator.id == $uid)
          | select(.creator.type == "Bot")
          | select(.context == $ctx)
        ] | first
          | if . == null then "absent " else "\(.state) \(.created_at // "")" end' 2>/dev/null || true)

    state=${pair%% *}
    created=${pair#* }

    # Page-limit guard (coderabbit-2). This endpoint returns EVERY status for the
    # SHA — undeduped — so a repo with many CI contexts each posting several
    # updates can exceed one page (~20 contexts x 6 updates = 120). A "no match"
    # on a FULL page is therefore not proof of absence: CodeRabbit's verdict may
    # sit on page two, and reporting "absent" there would be a false BLOCK that
    # no amount of waiting clears.
    #
    # Only the no-match case is ambiguous. Because the API is newest-first, a
    # match ON page one IS the newest CodeRabbit status by construction — later
    # pages hold only older ones — so a found verdict needs no pagination.
    if [ "$state" = "absent" ]; then
        local count
        count=$(printf '%s' "$json" | jq -r 'length' 2>/dev/null || true)
        case "$count" in
            ''|*[!0-9]*) return 1 ;;
        esac
        if [ "$count" -ge 100 ] 2>/dev/null; then
            printf 'paged \n'
            return 0
        fi
    fi

    case "$state" in
        success|pending|failure|error|absent)
            printf '%s %s\n' "$state" "$created"
            return 0 ;;
        *) return 1 ;;
    esac
}
