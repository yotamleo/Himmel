#!/usr/bin/env bash
# scripts/handover/console-kit/ready-check.sh — mechanize the console's READY
# verification (HIMMEL-3163, fleet-v1-join design P3). Console A ran this same
# checklist by hand ~12 times on 2026-09-18 with zero variance; the fleet cap
# doubling (4 -> 8) doubles the READYs per hour, so it is worth a script.
#
# Read-only. Prints one line per check, then READY-CHECK PASS|FAIL. It does
# NOT read the three-dot diff — that judgement call stays the console's own,
# and the script says so on its last line.
#
# Usage: ready-check.sh <pr-number> <full-40-hex-head-sha>
#
# Checks:
#   1. gh pr view: headRefOid == <head-sha> (full 40 chars); mergeStateStatus
#      == CLEAN (retries briefly on UNKNOWN — a transient GitHub computation
#      state, not a verdict).
#   2. statusCheckRollup: every check IDENTITY's LATEST run is COMPLETED with
#      conclusion SUCCESS/SKIPPED/NEUTRAL (CheckRun), or state SUCCESS
#      (StatusContext) — a superseded run (e.g. an earlier CANCELLED run
#      before a later SUCCESS) is not judged (HIMMEL-3690). Identity =
#      CheckRun name + workflowName when present, else StatusContext
#      context. Read via --json, never `gh pr checks` text (a green check
#      whose name contains a space mislabels under naive text parsing).
#   3. GraphQL unresolved review threads == 0. Paginated the same way
#      check-ci.sh's review-thread gate is (scripts/check-ci.sh, "Paginate:
#      first:100 alone would let unresolved threads beyond page one slip
#      through") — same query, same cursor/hasNextPage guards, so a >100-
#      thread PR can't silently short-circuit to a false PASS here either.
#   4. CR ledger: <git-common-dir>/cr-critic-scores.jsonl has >=1 row for
#      <head-sha> with status "ok" (the shape `scripts/cr/cr-scores.sh` and
#      friends read — {"kind":"avail","head":...,"status":"ok"}).
#   5. The PR's first commit carries the attestation trailers the pre-push
#      gates require, for the file classes that trip them: `Platforms
#      tested:` when the diff touches scripts/**, *.sh/.bash/.zsh/.ps1/.psm1/
#      .psd1/.cmd/.bat or **/bin/*, `Security reviewed:` when the diff
#      touches anything outside *.md/*.txt/docs/**/handovers/**. Reuses the
#      PLATFORM_RE / ATTEST_RE from scripts/hooks/check-platforms-tested.sh
#      and the TOKEN_RE from scripts/hooks/check-security-reviewed.sh
#      VERBATIM (git grep -n 'Platforms tested' -- scripts) rather than
#      re-deriving the token vocabulary or the file filters — those two
#      files carry the history of why each regex looks the way it does.
#   6. Every commit subject in the PR carries a ticket ID, using the same
#      pattern scripts/hooks/check-commit-msg.sh derives (TICKET_ID_PATTERN,
#      else "${JIRA_PROJECT_KEY}-[0-9]+", else a bare "#123" reference) —
#      except a commit with more than one parent (a real merge, e.g. a leg's
#      `Merge remote-tracking branch 'origin/main' into <branch>`), mirroring
#      scripts/ci/check-commit-range.sh's `git rev-list --no-merges`. Parent
#      count, not subject text, is the exemption signal.
#
# Owner/repo are derived from `gh repo view --json owner,name`, never hard-
# coded (so this runs the same in any clone/fork). It writes nothing — no
# ledger rows, no GO files, no PR comments.
#
# Exit codes:
#   0 — READY-CHECK PASS
#   1 — READY-CHECK FAIL (one or more checks failed)
#   2 — usage, or cannot evaluate (gh/jq missing, repo/PR unreadable)
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as go.sh. No mapfile.
set -u

usage() {
    echo "usage: ready-check.sh <pr-number> <full-40-hex-head-sha>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi
PR="$1"; SHA="$2"

case "$PR" in
    ''|0*|*[!0123456789]*)
        usage
        echo "ready-check: pr-number must be digits without a leading zero (got '$PR')" >&2
        exit 2 ;;
esac
case "$SHA" in
    *[!0123456789abcdef]*) SHA_OK=0 ;;
    *) SHA_OK=1 ;;
esac
if [ "$SHA_OK" -ne 1 ] || [ "${#SHA}" -ne 40 ]; then
    usage
    echo "ready-check: head sha must be the full 40-char lowercase hex sha (got '$SHA')" >&2
    exit 2
fi

GH="${GH_CMD:-gh}"
if ! command -v "$GH" >/dev/null 2>&1; then
    echo "ready-check: gh not found on PATH" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "ready-check: jq not found on PATH" >&2
    exit 2
fi

nwo=$("$GH" repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null)
if [ -z "$nwo" ]; then
    echo "ready-check: cannot resolve owner/repo (gh repo view --json owner,name failed)" >&2
    exit 2
fi
owner="${nwo%%/*}"
repo="${nwo#*/}"

RESULT=0
mark_fail() { RESULT=1; }

# ── 1. head + mergeStateStatus ──────────────────────────────────────────────
attempt=0
head_now=""
mss=""
while [ "$attempt" -lt 5 ]; do
    pv=$("$GH" pr view "$PR" --repo "$nwo" --json headRefOid,mergeStateStatus \
        --jq '"\(.headRefOid) \(.mergeStateStatus)"' 2>/dev/null)
    head_now="${pv%% *}"
    mss="${pv#* }"
    [ "$mss" = "UNKNOWN" ] || break
    attempt=$((attempt + 1))
    sleep 1
done
if [ -z "$pv" ]; then
    echo "[FAIL] 1. gh pr view #$PR --repo $nwo failed — cannot read headRefOid/mergeStateStatus"
    mark_fail
elif [ "$head_now" = "$SHA" ] && [ "$mss" = "CLEAN" ]; then
    echo "[PASS] 1. head=$head_now matches, mergeStateStatus=CLEAN"
else
    echo "[FAIL] 1. head=$head_now (want $SHA), mergeStateStatus=$mss (want CLEAN)"
    mark_fail
fi

# ── 2. statusCheckRollup ─────────────────────────────────────────────────────
rollup=$("$GH" pr view "$PR" --repo "$nwo" --json statusCheckRollup \
    --jq '.statusCheckRollup' 2>/dev/null)
if [ -z "$rollup" ] || [ "$rollup" = "null" ]; then
    echo "[FAIL] 2. statusCheckRollup unreadable (gh pr view --json statusCheckRollup failed)"
    mark_fail
else
    # Judge each check IDENTITY by its LATEST run, not any matching row — a
    # superseded CANCELLED run must not fail a check whose later run at the
    # same head is green (HIMMEL-3690; evidence: PR #1317's pr-title-lint
    # CANCELLED 08:19:58Z then SUCCESS 08:26:47Z). Identity = CheckRun `name`
    # plus `workflowName` when present, else StatusContext `context`. Latest
    # = greatest startedAt/completedAt (CheckRun) or createdAt/startedAt
    # (StatusContext), falling back to the row's array position when neither
    # timestamp is present. A run with no timestamp at all (e.g. QUEUED,
    # not yet started) has no completed/started time to compare, but it can
    # only exist because GitHub created it after every already-timestamped
    # run for that identity — so it always outranks them, never the reverse.
    # An entry with no identifiable name is judged alone — it never merges
    # into another group (fail closed).
    grouped=$(printf '%s' "$rollup" | jq -c '
        def key_of(e):
            if e.name == null then "unk:\(e.idx)"
            elif e.is_checkrun then "cr:\(e.name)\u0001\(e.workflow)"
            else "sc:\(e.name)" end;
        [ to_entries[] |
            .value as $row | .key as $idx |
            ($row | has("conclusion")) as $is_checkrun |
            {
                idx: $idx,
                is_checkrun: $is_checkrun,
                name: (if $is_checkrun then ($row.name // $row.context) else ($row.context // $row.name) end),
                workflow: ($row.workflowName // ""),
                ts: (if $is_checkrun then ($row.startedAt // $row.completedAt // null)
                     else ($row.createdAt // $row.startedAt // null) end),
                ok: (if $is_checkrun then
                        ($row.status == "COMPLETED" and ($row.conclusion == "SUCCESS" or $row.conclusion == "SKIPPED" or $row.conclusion == "NEUTRAL"))
                     else
                        ($row.state == "SUCCESS")
                     end),
                detail: (if $is_checkrun then (($row.status // "?") + "/" + ($row.conclusion // "null"))
                         else ($row.state // "?") end)
            }
        ]
        | map(.key = key_of(.))
        | map(.sort_key = [(.ts == null), (.ts // .idx)])
        | group_by(.key)
        | map(max_by(.sort_key))
        | {total: length, bad: (map(select(.ok | not)) | map("\(.name // "?")=\(.detail)") | join(", "))}
    ' 2>/dev/null)
    total=$(printf '%s' "$grouped" | jq -r '.total // 0' 2>/dev/null)
    bad=$(printf '%s' "$grouped" | jq -r '.bad // empty' 2>/dev/null)
    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    if [ "$total" -eq 0 ]; then
        echo "[FAIL] 2. statusCheckRollup: no checks reported yet (0 entries — CI may not have registered)"
        mark_fail
    elif [ -z "$bad" ]; then
        echo "[PASS] 2. statusCheckRollup: $total/$total checks completed SUCCESS/SKIPPED/NEUTRAL"
    else
        echo "[FAIL] 2. statusCheckRollup: not-green — $bad"
        mark_fail
    fi
fi

# ── 3. unresolved review threads (paginated, mirrors scripts/check-ci.sh) ──
unresolved=0
cursor=""
pages=0
threads_ok=1
while :; do
    pages=$((pages + 1))
    if [ "$pages" -gt 50 ]; then
        echo "[FAIL] 3. review-thread query did not terminate within 50 pages (cursor cycle?)"
        threads_ok=0
        break
    fi
    sent_cursor="$cursor"
    set -- -f o="$owner" -f r="$repo" -F n="$PR"
    [ -n "$cursor" ] && set -- "$@" -f c="$cursor"
    # shellcheck disable=SC2016  # $o/$r/$n/$c are GraphQL variables — literal on purpose
    page=$("$GH" api graphql \
        -f query='query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}' \
        "$@" \
        --jq '.data.repository.pullRequest.reviewThreads | "\([.nodes[] | select(.isResolved | not)] | length) \(.pageInfo.hasNextPage) \(.pageInfo.endCursor)"' 2>/dev/null)
    page_count=${page%% *}
    rest=${page#* }
    has_next=${rest%% *}
    cursor=${rest#* }
    case "$page_count" in
        ''|*[!0-9]*)
            echo "[FAIL] 3. review-thread GraphQL query failed"
            threads_ok=0
            break ;;
    esac
    case "$has_next" in
        true|false) ;;
        *)
            echo "[FAIL] 3. review-thread query returned a malformed page (hasNextPage='$has_next')"
            threads_ok=0
            break ;;
    esac
    if [ "$has_next" = "true" ] && { [ -z "$cursor" ] || [ "$cursor" = "null" ]; }; then
        echo "[FAIL] 3. review-thread query returned a malformed page (hasNextPage=true with no cursor)"
        threads_ok=0
        break
    fi
    if [ "$has_next" = "true" ] && [ "$cursor" = "$sent_cursor" ]; then
        echo "[FAIL] 3. review-thread query returned a malformed page (cursor did not advance)"
        threads_ok=0
        break
    fi
    unresolved=$((unresolved + page_count))
    [ "$has_next" = "true" ] || break
done
if [ "$threads_ok" -eq 1 ]; then
    if [ "$unresolved" -eq 0 ]; then
        echo "[PASS] 3. unresolved review threads = 0"
    else
        echo "[FAIL] 3. unresolved review threads = $unresolved"
        mark_fail
    fi
else
    mark_fail
fi

# ── 4. CR ledger row for this head with status ok ───────────────────────────
common_dir=$(git rev-parse --git-common-dir 2>/dev/null)
if [ -z "$common_dir" ]; then
    echo "[FAIL] 4. cannot resolve git-common-dir (git rev-parse --git-common-dir failed)"
    mark_fail
else
    ledger="$common_dir/cr-critic-scores.jsonl"
    if [ ! -f "$ledger" ]; then
        echo "[FAIL] 4. CR ledger not found at $ledger"
        mark_fail
    else
        # `jq -R 'fromjson?'` parses one JSON value per line and skips a
        # malformed line rather than aborting the whole read (a plain `jq -s`
        # slurp would die on the first bad line in a 7000+ line ledger).
        n=$(jq -R -r --arg h "$SHA" 'fromjson? | select(.head == $h and .status == "ok") | .head' "$ledger" 2>/dev/null | wc -l | tr -d ' ')
        if [ "${n:-0}" -ge 1 ]; then
            echo "[PASS] 4. CR ledger: $n row(s) for $SHA with status=ok"
        else
            echo "[FAIL] 4. CR ledger: no row for $SHA with status=ok ($ledger)"
            mark_fail
        fi
    fi
fi

# ── commits (shared by checks 5 and 6) ──────────────────────────────────────
commits_json=$("$GH" pr view "$PR" --repo "$nwo" --json commits --jq '.commits' 2>/dev/null)
files_json=$("$GH" api --paginate "repos/$owner/$repo/pulls/$PR/files" --jq '.[].filename' 2>/dev/null)

if [ -z "$commits_json" ] || [ "$commits_json" = "null" ]; then
    echo "[FAIL] 5. cannot read PR commits (gh pr view --json commits failed)"
    mark_fail
    echo "[FAIL] 6. cannot read PR commits (gh pr view --json commits failed)"
    mark_fail
else
    # ── 5. first-commit attestation trailers ────────────────────────────────
    # PLATFORM_RE / ATTEST_RE verbatim from scripts/hooks/check-platforms-tested.sh
    PLATFORM_RE='(linux|windows|macos|ubuntu|debian|fedora|arch|mac|darwin|wsl|posix|gitbash|git-bash|powershell|pwsh)'
    ATTEST_RE="^[[:space:]]*Platforms tested:[[:space:]]*${PLATFORM_RE}([^[:alnum:]]|$)"
    # TOKEN_RE verbatim from scripts/hooks/check-security-reviewed.sh
    TOKEN_RE='(manual|claude-code-security-review|pr-review-toolkit|ad-hoc)([[:space:]]|$|[.,;])'
    SEC_RE="^[[:space:]]*Security reviewed:[[:space:]]*${TOKEN_RE}"

    first_msg=$(printf '%s' "$commits_json" | jq -r '.[0].messageHeadline + "\n\n" + (.[0].messageBody // "")' 2>/dev/null)

    if [ -z "$files_json" ]; then
        echo "[FAIL] 5. cannot read PR files (gh api .../pulls/$PR/files failed or returned nothing)"
        mark_fail
    else
        sensitive=$(printf '%s\n' "$files_json" | grep -E '(\.(sh|bash|zsh|ps1|psm1|psd1|cmd|bat)$|^scripts/|(^|/)bin/[^/]+$)' || true)
        non_docs=$(printf '%s\n' "$files_json" | grep -Ev '\.(md|txt)$|^docs/|^handovers/' || true)

        need_plat=0; [ -n "$sensitive" ] && need_plat=1
        need_sec=0; [ -n "$non_docs" ] && need_sec=1

        plat_ok=1; [ "$need_plat" -eq 1 ] && { echo "$first_msg" | grep -qiE "$ATTEST_RE" || plat_ok=0; }
        sec_ok=1; [ "$need_sec" -eq 1 ] && { echo "$first_msg" | grep -qiE "$SEC_RE" || sec_ok=0; }

        if [ "$plat_ok" -eq 1 ] && [ "$sec_ok" -eq 1 ]; then
            echo "[PASS] 5. first commit: Platforms tested (needed=$need_plat), Security reviewed (needed=$need_sec) — attested where needed"
        else
            [ "$plat_ok" -eq 0 ] && echo "[FAIL] 5. first commit missing 'Platforms tested:' (diff touches scripts/shell files)"
            [ "$sec_ok" -eq 0 ] && echo "[FAIL] 5. first commit missing 'Security reviewed:' (diff touches non-docs code)"
            mark_fail
        fi
    fi

    # ── 6. every commit subject carries a ticket ID ─────────────────────────
    # Same config source as check-commit-msg.sh: load TICKET_ID_PATTERN /
    # JIRA_PROJECT_KEY from the primary checkout's .env (live env wins) —
    # without this, a fresh shell with nothing exported always falls through
    # to the bare "#123" pattern and flags every "[HIMMEL-1234]"-style subject.
    RC_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # shellcheck source=../../lib/load-dotenv.sh
    # shellcheck disable=SC1091
    if . "$RC_SCRIPT_DIR/../../lib/load-dotenv.sh" 2>/dev/null; then
        # HIMMEL-3533: pin to this script's OWN checkout, never the caller's
        # CWD repo (load_dotenv with no --root resolves via the process CWD's
        # git repo — see HIMMEL-3532 / bank-preflight.sh for the failure mode).
        load_dotenv --root "$(_load_dotenv_primary_for "$RC_SCRIPT_DIR/../../..")" TICKET_ID_PATTERN JIRA_PROJECT_KEY || true
    fi
    TICKET_PATTERN="${TICKET_ID_PATTERN:-}"
    if [ -z "$TICKET_PATTERN" ] && [ -n "${JIRA_PROJECT_KEY:-}" ]; then
        ESCAPED_KEY=$(printf '%s' "$JIRA_PROJECT_KEY" | sed 's/[.[\*^$]/\\&/g')
        TICKET_PATTERN="${ESCAPED_KEY}-[0-9]+"
    fi
    TICKET_PATTERN="${TICKET_PATTERN:-(^|[^0-9A-Za-z_])#[0-9]+([^0-9A-Za-z_]|$)}"

    # Merge commits (>1 parent) are exempt — same signal check-commit-range.sh
    # uses. `gh pr view --json commits` has no `parents` field, so this is a
    # separate raw GraphQL query keyed on commit oid.
    # shellcheck disable=SC2016  # $o/$r/$n are GraphQL variables — literal on purpose
    merge_oids=$("$GH" api graphql \
        -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){commits(first:100){nodes{commit{oid parents{totalCount}}}}}}}' \
        -f o="$owner" -f r="$repo" -F n="$PR" \
        --jq '.data.repository.pullRequest.commits.nodes[] | select(.commit.parents.totalCount > 1) | .commit.oid' 2>/dev/null)

    missing=$(printf '%s' "$commits_json" | jq -r --arg merges "$merge_oids" '
        ($merges | split("\n") | map(select(length > 0))) as $m
        | .[] | select((.oid // "") as $o | ($m | index($o)) == null)
        | .messageHeadline
    ' 2>/dev/null | grep -vE "$TICKET_PATTERN" || true)
    if [ -z "$missing" ]; then
        echo "[PASS] 6. every commit subject carries a ticket ID"
    else
        echo "[FAIL] 6. commit subject(s) missing a ticket ID: $(printf '%s' "$missing" | tr '\n' ';' | sed 's/;$//')"
        mark_fail
    fi
fi

echo "---"
echo "The three-dot diff read (git diff origin/main...HEAD) stays the console's own judgement — this script does not read it."
if [ "$RESULT" -eq 0 ]; then
    echo "READY-CHECK PASS"
    exit 0
else
    echo "READY-CHECK FAIL"
    exit 1
fi
