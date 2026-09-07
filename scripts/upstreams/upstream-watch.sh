#!/usr/bin/env bash
# upstream-watch.sh — daily, delta-gated, zero-token-on-no-delta scan of
# himmel's open upstream PRs/issues (HIMMEL-2367).
#
# WHY: a resident interactive claude session used to poll these every 20
# minutes, burning tokens on a mostly-unchanged inventory. Operator ruling
# 2026-09-01: "we should monitor it daily not as a puller and with tokens" —
# this replaces that poller with bash + gh + jq + node. It NEVER calls claude.
#
# Builds the inventory of open PRs/issues authored by the operator across
# every tracked repo (excluding the operator's OWN repos), enriches each item
# (comments, reviews, CI conclusion at the item's CURRENT head SHA, mergeable
# state), diffs it against the previous run's snapshot, and — only when
# something actually changed — writes a dated report under the handover root
# (bucketed <user>/<repo>/specs/reports, resolved via the handover registry —
# see docs/internals/upstream-watch.md) and sends one Telegram line. A no-delta
# run touches nothing but the state file and costs zero tokens (it is pure
# shell; nothing here invokes claude).
#
# Usage: bash scripts/upstreams/upstream-watch.sh   (no args)
#
# Exit codes:
#   0   ran clean, no delta
#   10  ran clean, delta found (report written + telegram sent, best-effort)
#   2   instrument failure: gh auth/rate-limit/parse failure on any gh call,
#       the "0 items now vs >0 last-seen" positive-control refusal (do NOT
#       read that as "everything closed" — presume the instrument broke), a
#       required render field (title/url) resolving null/empty, or a broken
#       handover_root / report-bucket-resolution / report-write on a run
#       that DOES have a delta to report (state is left UNTOUCHED in every
#       one of those last cases — the inventory itself was fine, only the
#       reporting step failed, and leaving state alone means the same delta
#       is retried next run instead of being permanently marked "seen" with
#       no report ever written for it)
#
# Test seams (used by test-upstream-watch.sh):
#   UPSTREAM_WATCH_GH           gh binary override (default: gh)
#   UPSTREAM_WATCH_ME           skip `gh api user`; use this login directly
#   UPSTREAM_WATCH_STATE_DIR    overrides the whole .himmel/upstream-watch dir
#   UPSTREAM_WATCH_HIMMEL_ROOT  overrides the resolved primary checkout, used
#                                for the Telegram .env lookup AND (HIMMEL-2426)
#                                as the path matched against the handover
#                                registry to resolve the report bucket
#                                (mirrors drift-fix-cadence.sh's
#                                resolve_himmel_root; not part of the original
#                                spec but required for a test run to never
#                                reach a real .env or registry)
#   HANDOVER_DIR                 (existing convention) where the delta report
#                                is written; see scripts/lib/handover-path.sh
#   HANDOVER_REGISTRY            (existing convention, see
#                                scripts/handover/resolve-active-item.sh)
#                                registry.json used to resolve the report's
#                                <user>/<repo-bucket> segment; default
#                                ~/.claude/handover/registry.json
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/cadence-format.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cadence-format.sh"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh"
# shellcheck source=../lib/user-slug.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/user-slug.sh"

command -v jq >/dev/null 2>&1 || {
    echo "ERR upstream-watch: jq is required but not on PATH" >&2
    exit 2
}
command -v tr >/dev/null 2>&1 || {
    echo "ERR upstream-watch: tr is required but not on PATH" >&2
    exit 2
}
command -v node >/dev/null 2>&1 || {
    echo "ERR upstream-watch: node is required but not on PATH" >&2
    exit 2
}

# jq shim — strip CR from every jq invocation in this script (HIMMEL-2407).
#
# The native Windows jq (winget jqlang.jq, and the msys/choco builds) writes
# stdout in TEXT mode: `jq -rn '"abc"'` emits `abc\r\n`, not `abc\n`. Command
# substitution strips the trailing NEWLINE only, so EVERY value this script
# captured from jq carried a trailing \r — and a \r is invisible in every
# diagnostic that prints it. That is what produced the 21 rows of
# `- [owner/repo#N](null) — null` in the first scheduled report: the keys read
# out of the delta were `owner/repo#N\r`, so `.[$k]` matched nothing and both
# the title and url lookups answered null. The report bytes carry the proof
# (`…graphify#2984\r](null)`). `head_sha` was poisoned the same way and went
# into a check-runs URL.
#
# Fixing it at the ~15 capture sites would leave the next one to rediscover
# this; fixing it here covers every present and future jq call in one place.
# On Linux/macOS jq already emits LF and `tr -d '\r'` is a no-op. `command jq`
# is what stops this recursing. Exit status still propagates: `set -o pipefail`
# is on, and tr always exits 0, so the pipeline's status is jq's — `jq -e`
# checks keep working.
jq() { command jq "$@" | tr -d '\r'; }

GH_BIN="${UPSTREAM_WATCH_GH:-gh}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/upstream-watch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="${UPSTREAM_WATCH_STATE_DIR:-$(cadence_user_home)/.himmel/upstream-watch}"
STATE_FILE="$STATE_DIR/last_seen.json"

# resolve_himmel_root — same approach as drift-fix-cadence.sh: --git-common-dir
# resolves to the PRIMARY checkout even from a linked worktree, so the .env
# lookup below (Telegram creds) never misses just because this ran from a
# feature worktree. UPSTREAM_WATCH_HIMMEL_ROOT is the hermetic test seam — it
# keeps a test run from ever reaching the operator's real .env.
resolve_himmel_root() {
    if [ -n "${UPSTREAM_WATCH_HIMMEL_ROOT:-}" ]; then
        printf '%s' "$UPSTREAM_WATCH_HIMMEL_ROOT"
        return 0
    fi
    local common_dir
    command -v git >/dev/null 2>&1 || return 1
    common_dir="$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null)" || return 1
    [ -n "$common_dir" ] || return 1
    case "$common_dir" in
        /*|[A-Za-z]:[/\\]*) : ;;
        *) common_dir="$SCRIPT_DIR/$common_dir" ;;
    esac
    (cd "$(dirname "$common_dir")" 2>/dev/null && pwd)
}

# --- identity ---------------------------------------------------------------
if [ -n "${UPSTREAM_WATCH_ME:-}" ]; then
    ME="$UPSTREAM_WATCH_ME"
else
    if ! ME=$("$GH_BIN" api user --jq .login 2>"$TMP/me.err") || [ -z "$ME" ]; then
        echo "ERR upstream-watch: could not resolve identity via 'gh api user' — never guessing:" >&2
        cat "$TMP/me.err" >&2 2>/dev/null || true
        exit 2
    fi
fi

# --- inventory ---------------------------------------------------------------
# run_gh_search <prs|issues> — one gh search call, validated as a JSON array.
# `gh search issues` already excludes PRs by default (confirmed via
# `gh search issues --help`) — no extra flag needed.
run_gh_search() {
    local kind="$1" out err
    err="$TMP/search-$kind.err"
    if ! out=$("$GH_BIN" search "$kind" --author "$ME" --state open \
            --json repository,number,title,url,updatedAt,state --limit 1000 2>"$err"); then
        echo "ERR upstream-watch: gh search $kind failed — instrument failure:" >&2
        cat "$err" >&2
        exit 2
    fi
    if ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "ERR upstream-watch: gh search $kind did not return a JSON array — instrument failure" >&2
        exit 2
    fi
    printf '%s' "$out"
}

PRS_RAW="$(run_gh_search prs)"
ISSUES_RAW="$(run_gh_search issues)"

# Own-repo exclusion (ticket rule) + tag each item with its kind.
PRS_FILTERED=$(printf '%s' "$PRS_RAW" | jq --arg me "$ME" \
    '[.[] | select(.repository.nameWithOwner | startswith($me + "/") | not) | . + {kind:"pr"}]')
ISSUES_FILTERED=$(printf '%s' "$ISSUES_RAW" | jq --arg me "$ME" \
    '[.[] | select(.repository.nameWithOwner | startswith($me + "/") | not) | . + {kind:"issue"}]')
INVENTORY=$(jq -n --argjson a "$PRS_FILTERED" --argjson b "$ISSUES_FILTERED" '$a + $b')
COUNT=$(printf '%s' "$INVENTORY" | jq 'length')

# --- previous state -----------------------------------------------------------
OLD_ITEMS="{}"
OLD_COUNT=0
if [ -f "$STATE_FILE" ]; then
    OLD_RAW="$(cat "$STATE_FILE" 2>/dev/null || true)"
    if [ -n "$OLD_RAW" ] && printf '%s' "$OLD_RAW" | jq -e . >/dev/null 2>&1; then
        OLD_ITEMS=$(printf '%s' "$OLD_RAW" | jq '.items // {}')
        OLD_COUNT=$(printf '%s' "$OLD_ITEMS" | jq 'length')
    else
        echo "WARN upstream-watch: existing state file at $STATE_FILE is not valid JSON — treating as absent" >&2
    fi
fi

# Positive control (instrument rule): 0 items now against >0 last-seen is
# presumed instrument failure (auth broke, rate-limited, wrong account) —
# never "everything got closed" all at once. Refuse before spending any of
# the per-item enrichment calls below, and never touch the state file.
if [ "$COUNT" -eq 0 ] && [ "$OLD_COUNT" -gt 0 ]; then
    echo "ERR upstream-watch: instrument failure suspected — gh reports 0 open items but the last-seen state ($STATE_FILE) recorded $OLD_COUNT. Refusing to treat this as 'everything closed'; check gh auth / rate limits / the active account. State file left untouched." >&2
    exit 2
fi

# --- per-item enrichment -------------------------------------------------------
CURRENT_JSONL="$TMP/current.jsonl"
: > "$CURRENT_JSONL"

# aggregate check-runs into one ci_conclusion string, per the method the Leg F
# upstream-sweep report used: read at the PR's CURRENT head SHA, never a
# possibly-stale rollup field.
ci_conclusion_from_runs() {
    jq -s -r '
        if length == 0 then "none"
        elif any(.[]; .conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "cancelled" or .conclusion == "action_required" or .conclusion == "startup_failure") then "failure"
        elif any(.[]; .status != "completed") then "pending"
        else "success"
        end'
}

# last_comment_fields <json-with-.comments> — echoes "author\tat" for the most
# recent comment NOT authored by $ME (empty/empty if none).
last_comment_fields() {
    jq -r --arg me "$ME" '
        ([.comments[]? | select((.author.login // "") != $me)] | sort_by(.createdAt) | last)
        | if . == null then "\t" else "\(.author.login)\t\(.createdAt)" end'
}

while IFS= read -r item; do
    kind=$(printf '%s' "$item" | jq -r '.kind')
    nwo=$(printf '%s' "$item" | jq -r '.repository.nameWithOwner')
    num=$(printf '%s' "$item" | jq -r '.number')
    key="$nwo#$num"

    if [ "$kind" = "pr" ]; then
        if ! pr_json=$("$GH_BIN" pr view "$num" --repo "$nwo" \
                --json headRefOid,mergeable,mergeStateStatus,reviews,comments,state,updatedAt,title,url 2>"$TMP/pv.err") \
           || ! printf '%s' "$pr_json" | jq -e . >/dev/null 2>&1; then
            echo "ERR upstream-watch: gh pr view $nwo $num failed — instrument failure:" >&2
            cat "$TMP/pv.err" >&2 2>/dev/null || true
            exit 2
        fi
        head_sha=$(printf '%s' "$pr_json" | jq -r '.headRefOid')
        if ! ci_raw=$("$GH_BIN" api --paginate "repos/$nwo/commits/$head_sha/check-runs" \
                --jq '.check_runs[] | {name, status, conclusion}' 2>"$TMP/ci.err"); then
            echo "ERR upstream-watch: gh api check-runs for $nwo@$head_sha failed — instrument failure:" >&2
            cat "$TMP/ci.err" >&2 2>/dev/null || true
            exit 2
        fi
        ci_conclusion=$(printf '%s' "$ci_raw" | ci_conclusion_from_runs)

        last_comment=$(printf '%s' "$pr_json" | last_comment_fields)
        last_comment_author="${last_comment%%$'\t'*}"
        last_comment_at="${last_comment#*$'\t'}"

        new_item=$(printf '%s' "$pr_json" | jq \
            --arg lca "$last_comment_author" --arg lcat "$last_comment_at" \
            --arg ci "$ci_conclusion" '{
                kind: "pr",
                state: .state,
                comments_count: (.comments | length),
                last_comment_author: $lca,
                last_comment_at: $lcat,
                reviews_count: (.reviews | length),
                ci_head_sha: .headRefOid,
                ci_conclusion: $ci,
                mergeable: .mergeable,
                merge_state_status: .mergeStateStatus,
                updated_at: .updatedAt,
                url: .url,
                title: .title
            }')
    else
        if ! issue_json=$("$GH_BIN" issue view "$num" --repo "$nwo" \
                --json comments,state,updatedAt,closedAt,title,url 2>"$TMP/iv.err") \
           || ! printf '%s' "$issue_json" | jq -e . >/dev/null 2>&1; then
            echo "ERR upstream-watch: gh issue view $nwo $num failed — instrument failure:" >&2
            cat "$TMP/iv.err" >&2 2>/dev/null || true
            exit 2
        fi
        last_comment=$(printf '%s' "$issue_json" | last_comment_fields)
        last_comment_author="${last_comment%%$'\t'*}"
        last_comment_at="${last_comment#*$'\t'}"

        new_item=$(printf '%s' "$issue_json" | jq \
            --arg lca "$last_comment_author" --arg lcat "$last_comment_at" '{
                kind: "issue",
                state: .state,
                comments_count: (.comments | length),
                last_comment_author: $lca,
                last_comment_at: $lcat,
                reviews_count: null,
                ci_head_sha: null,
                ci_conclusion: null,
                mergeable: null,
                merge_state_status: null,
                updated_at: .updatedAt,
                url: .url,
                title: .title
            }')
    fi

    jq -n --arg key "$key" --argjson item "$new_item" '{key:$key, item:$item}' >> "$CURRENT_JSONL"
done < <(printf '%s' "$INVENTORY" | jq -c '.[]')

if [ -s "$CURRENT_JSONL" ]; then
    CURRENT_SNAPSHOT=$(jq -s 'map({(.key): .item}) | add' "$CURRENT_JSONL")
else
    CURRENT_SNAPSHOT="{}"
fi

# --- delta detection -----------------------------------------------------------
DELTA_INFO=$(jq -n --argjson cur "$CURRENT_SNAPSHOT" --argjson old "$OLD_ITEMS" '
    ($cur | keys) as $curkeys
    | ($old | keys) as $oldkeys
    | {
        new: [$curkeys[] as $k | select($old | has($k) | not) | $k],
        vanished: [$oldkeys[] as $k | select($cur | has($k) | not) | $k],
        changed: [$curkeys[] as $k | select($old | has($k))
            | select(
                $cur[$k].comments_count != $old[$k].comments_count or
                $cur[$k].reviews_count != $old[$k].reviews_count or
                $cur[$k].ci_conclusion != $old[$k].ci_conclusion or
                $cur[$k].mergeable != $old[$k].mergeable or
                $cur[$k].merge_state_status != $old[$k].merge_state_status or
                $cur[$k].state != $old[$k].state
              )
            | $k]
    }')

NEW_KEYS=$(printf '%s' "$DELTA_INFO" | jq -r '.new[]')
CHANGED_KEYS=$(printf '%s' "$DELTA_INFO" | jq -r '.changed[]')
VANISHED_KEYS=$(printf '%s' "$DELTA_INFO" | jq -r '.vanished[]')
NEW_COUNT=$(printf '%s' "$DELTA_INFO" | jq '.new | length')
CHANGED_COUNT=$(printf '%s' "$DELTA_INFO" | jq '.changed | length')
VANISHED_COUNT=$(printf '%s' "$DELTA_INFO" | jq '.vanished | length')
DELTA_COUNT=$((NEW_COUNT + CHANGED_COUNT + VANISHED_COUNT))

# One more gh call per vanished item (kind taken from the OLD state) to name
# its final disposition. Best-effort: the item already left the open-search
# results, so a failed disposition lookup here reports "unknown" rather than
# aborting a run whose inventory was otherwise fine.
VANISHED_JSONL="$TMP/vanished.jsonl"
: > "$VANISHED_JSONL"
while IFS= read -r vkey; do
    [ -n "$vkey" ] || continue
    vkind=$(printf '%s' "$OLD_ITEMS" | jq -r --arg k "$vkey" '.[$k].kind')
    nwo="${vkey%#*}"
    num="${vkey##*#}"
    disp_state="UNKNOWN"
    disp_merged=""
    if [ "$vkind" = "pr" ]; then
        if disp_json=$("$GH_BIN" pr view "$num" --repo "$nwo" --json state,mergedAt,closedAt 2>"$TMP/dv.err"); then
            disp_state=$(printf '%s' "$disp_json" | jq -r '.state // "UNKNOWN"')
            disp_merged=$(printf '%s' "$disp_json" | jq -r '.mergedAt // ""')
        fi
    else
        # issues have no mergedAt field (gh issue view --json rejects it) —
        # closed/state alone is enough to label a vanished issue.
        if disp_json=$("$GH_BIN" issue view "$num" --repo "$nwo" --json state,closedAt 2>"$TMP/dv.err"); then
            disp_state=$(printf '%s' "$disp_json" | jq -r '.state // "UNKNOWN"')
        fi
    fi
    if [ -n "$disp_merged" ] || [ "$disp_state" = "MERGED" ]; then
        label="merged"
    elif [ "$disp_state" = "CLOSED" ]; then
        label="closed"
    else
        label="left the open list (state: $disp_state)"
    fi
    jq -n --arg key "$vkey" --arg label "$label" '{key:$key, label:$label}' >> "$VANISHED_JSONL"
done <<< "$VANISHED_KEYS"

# --- state write (atomic) -------------------------------------------------------
write_state() {
    mkdir -p "$STATE_DIR"
    local tmp gen
    gen="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp=$(mktemp "$STATE_DIR/.last_seen.json.XXXXXX")
    jq -n --arg gen "$gen" --argjson items "$CURRENT_SNAPSHOT" '{generated_at:$gen, items:$items}' > "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# require_field <value> <label> -- guard against ever rendering a null/empty
# REQUIRED field again (HIMMEL-2407: the jq() CRLF shim above fixes the
# CAUSE; this is the belt to that suspenders — a required render field that
# still comes back null/empty makes build_report fail outright instead of
# printing `(null)`). A jq lookup miss answers the literal string "null"; a
# genuinely absent/empty value answers "".
require_field() {
    local val="$1" label="$2"
    if [ -z "$val" ] || [ "$val" = "null" ]; then
        echo "ERR upstream-watch: required field '$label' is null/empty while building the report — refusing to render a broken row" >&2
        return 1
    fi
    return 0
}

# --- report ----------------------------------------------------------------------
build_report() {
    local report_file="$1"
    # Validate every CURRENT_SNAPSHOT item's required render fields ONCE, up
    # front -- covers every section below (New/Changed) that sources
    # title/url from CURRENT_SNAPSHOT. The Closed/merged section sources
    # from OLD_ITEMS instead and validates itself, below.
    local _rf_k
    while IFS= read -r _rf_k; do
        [ -n "$_rf_k" ] || continue
        local _rf_t _rf_u
        _rf_t=$(printf '%s' "$CURRENT_SNAPSHOT" | jq -r --arg k "$_rf_k" '.[$k].title')
        _rf_u=$(printf '%s' "$CURRENT_SNAPSHOT" | jq -r --arg k "$_rf_k" '.[$k].url')
        require_field "$_rf_t" "title ($_rf_k)"
        require_field "$_rf_u" "url ($_rf_k)"
    done < <(printf '%s' "$CURRENT_SNAPSHOT" | jq -r 'keys[]')
    {
        echo "# Upstream watch — $(date -u +%Y-%m-%d)"
        echo ""
        echo "New: $NEW_COUNT, Changed: $CHANGED_COUNT, Closed/merged: $VANISHED_COUNT — total delta: $DELTA_COUNT"
        if [ "$NEW_COUNT" -gt 0 ]; then
            echo ""
            echo "## New"
            while IFS= read -r k; do
                [ -n "$k" ] || continue
                local t u
                t=$(printf '%s' "$CURRENT_SNAPSHOT" | jq -r --arg k "$k" '.[$k].title')
                u=$(printf '%s' "$CURRENT_SNAPSHOT" | jq -r --arg k "$k" '.[$k].url')
                echo "- [$k]($u) — $t"
            done <<< "$NEW_KEYS"
        fi
        if [ "$CHANGED_COUNT" -gt 0 ]; then
            echo ""
            echo "## Changed"
            while IFS= read -r k; do
                [ -n "$k" ] || continue
                local old_item new_item t u old_c new_c diffc lca old_r new_r old_ci new_ci old_mg new_mg old_ms new_ms old_st new_st
                old_item=$(printf '%s' "$OLD_ITEMS" | jq -c --arg k "$k" '.[$k]')
                new_item=$(printf '%s' "$CURRENT_SNAPSHOT" | jq -c --arg k "$k" '.[$k]')
                t=$(printf '%s' "$new_item" | jq -r '.title')
                u=$(printf '%s' "$new_item" | jq -r '.url')
                echo "- [$k]($u) — $t"
                old_c=$(printf '%s' "$old_item" | jq -r '.comments_count')
                new_c=$(printf '%s' "$new_item" | jq -r '.comments_count')
                if [ "$old_c" != "$new_c" ]; then
                    diffc=$((new_c - old_c))
                    lca=$(printf '%s' "$new_item" | jq -r '.last_comment_author')
                    if [ "$diffc" -gt 0 ] && [ -n "$lca" ]; then
                        echo "  - comments +$diffc (last by $lca)"
                    else
                        echo "  - comments: $old_c -> $new_c"
                    fi
                fi
                old_r=$(printf '%s' "$old_item" | jq -r '.reviews_count')
                new_r=$(printf '%s' "$new_item" | jq -r '.reviews_count')
                [ "$old_r" != "$new_r" ] && echo "  - reviews: $old_r -> $new_r"
                old_ci=$(printf '%s' "$old_item" | jq -r '.ci_conclusion')
                new_ci=$(printf '%s' "$new_item" | jq -r '.ci_conclusion')
                [ "$old_ci" != "$new_ci" ] && echo "  - CI: $old_ci -> $new_ci"
                old_mg=$(printf '%s' "$old_item" | jq -r '.mergeable')
                new_mg=$(printf '%s' "$new_item" | jq -r '.mergeable')
                [ "$old_mg" != "$new_mg" ] && echo "  - mergeable: $old_mg -> $new_mg"
                old_ms=$(printf '%s' "$old_item" | jq -r '.merge_state_status')
                new_ms=$(printf '%s' "$new_item" | jq -r '.merge_state_status')
                [ "$old_ms" != "$new_ms" ] && echo "  - merge status: $old_ms -> $new_ms"
                old_st=$(printf '%s' "$old_item" | jq -r '.state')
                new_st=$(printf '%s' "$new_item" | jq -r '.state')
                [ "$old_st" != "$new_st" ] && echo "  - state: $old_st -> $new_st"
            done <<< "$CHANGED_KEYS"
        fi
        if [ "$VANISHED_COUNT" -gt 0 ]; then
            echo ""
            echo "## Closed / merged"
            while IFS= read -r k; do
                [ -n "$k" ] || continue
                local t u label
                t=$(printf '%s' "$OLD_ITEMS" | jq -r --arg k "$k" '.[$k].title')
                u=$(printf '%s' "$OLD_ITEMS" | jq -r --arg k "$k" '.[$k].url')
                require_field "$t" "title ($k, closed/merged)"
                require_field "$u" "url ($k, closed/merged)"
                label=$(jq -r --arg k "$k" 'select(.key == $k) | .label' "$VANISHED_JSONL" | head -1)
                echo "- [$k]($u) — $t ($label)"
            done <<< "$VANISHED_KEYS"
        fi
    } > "$report_file"
}

# send_telegram <report-path> <delta-count> — sanctioned relay pattern
# (scripts/hooks/jira-nudge-on-end.sh relay_nudge). Best-effort: any curl
# failure is swallowed; this function always returns 0.
send_telegram() {
    local report_path="$1" count="$2" root msg
    root=$(resolve_himmel_root) || return 0
    load_dotenv --root "$root" TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    msg="upstream-watch: ${count} delta item(s) today — see ${report_path}"
    curl -sS -m 10 -o /dev/null \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${msg}" \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" >/dev/null 2>&1 || true
    return 0
}

# --- exit path -------------------------------------------------------------------
if [ "$DELTA_COUNT" -eq 0 ]; then
    write_state
    exit 0
fi

if ! REPORT_ROOT=$(handover_root 2>"$TMP/hr.err"); then
    echo "ERR upstream-watch: handover_root failed — delta WAS found ($DELTA_COUNT item(s)) but the report cannot be written. State left untouched so this delta is retried next run:" >&2
    cat "$TMP/hr.err" >&2
    exit 2
fi

# --- resolve the report bucket (<user>/<repo-bucket>) --------------------------
# handover_root is single-root BY DESIGN (its own header says the bucket
# layer is applied by callers, on top of the resolved root) -- every other
# report writer lands at <handover-root>/<user>/<repo-bucket>/specs/reports,
# so this resolves the same way: registry + user slug. Mirrors the REVERSE
# lookup arm-resume.sh already does for its own HIMMEL-2147 fallback
# (scripts/handover/arm-resume.sh ~L2295, bucket -> path); this is the
# forward direction (path -> bucket).
HIMMEL_ROOT_FOR_BUCKET="$(resolve_himmel_root)" || HIMMEL_ROOT_FOR_BUCKET=""
REGISTRY_FILE="${HANDOVER_REGISTRY:-$(cadence_user_home)/.claude/handover/registry.json}"

if [ -z "$HIMMEL_ROOT_FOR_BUCKET" ]; then
    echo "ERR upstream-watch: could not resolve this checkout's root — delta WAS found ($DELTA_COUNT item(s)) but the report bucket cannot be resolved. State left untouched so this delta is retried next run." >&2
    exit 2
fi
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "ERR upstream-watch: handover registry not found at $REGISTRY_FILE — delta WAS found ($DELTA_COUNT item(s)) but the report bucket cannot be resolved. Set HANDOVER_REGISTRY, or register this checkout via /handover register. State left untouched so this delta is retried next run." >&2
    exit 2
fi

# Path matching is the trap: the registry stores Windows-style lowercase
# paths (c:/users/...) while resolve_himmel_root under Git Bash returns
# /c/Users/... -- so on WINDOWS normalize both sides (backslash -> /, strip
# trailing slash, fold a leading MSYS /c/ to c:/, then lowercase) before
# comparing. Case folding and the drive-letter fold are deliberately Windows-
# ONLY: Linux and macOS filesystems are case-sensitive, and folding there
# would match two genuinely different checkouts that differ only by case.
reg_rc=0
# shellcheck disable=SC2016  # the node program is single-quoted ON PURPOSE:
# its $ and ` characters belong to JavaScript (regex anchors, template
# syntax) and must reach node unexpanded. The two values the program needs
# are handed to it through the REG/HROOT environment, never interpolated.
REG_MATCH=$(REG="$REGISTRY_FILE" HROOT="$HIMMEL_ROOT_FOR_BUCKET" node -e '
    const fs = require("fs"), e = process.env;
    let j;
    try { j = JSON.parse(fs.readFileSync(e.REG, "utf8")); }
    catch (err) { console.error("registry parse error: " + err.message); process.exit(2); }
    // Case folding and the MSYS drive-letter fold are WINDOWS-ONLY. NTFS is
    // case-insensitive and the registry stores these paths lowercased, so
    // Windows needs both. Linux and macOS filesystems are case-SENSITIVE:
    // folding there would let ~/work/Himmel and ~/work/himmel -- two genuinely
    // different checkouts -- match the same registry entry and route the
    // report to the wrong bucket. The `/c/...` -> `c:/...` rewrite is likewise
    // an MSYS artifact; on Linux a real top-level `/c/` directory must stay a
    // path, not become a drive letter.
    //
    // KNOWN LIMIT: process.platform is a proxy for FS case-sensitivity, not a
    // measurement of it. A default APFS/HFS+ macOS volume IS case-insensitive
    // (and a macOS volume can be formatted case-sensitive, and a Linux box can
    // mount a case-insensitive one), so a registry path differing only in case
    // is rejected there rather than matched. Refusing is the fail-closed
    // direction -- the run exits 2 with the state untouched and no report is
    // misfiled -- and folding case unconditionally is what caused the bug this
    // gate replaced. Doing it properly means comparing the two paths by
    // identity (stat dev+ino) rather than by string; tracked as HIMMEL-2449.
    const isWin = process.platform === "win32";
    function norm(p) {
        if (!p) return "";
        let s = String(p).replace(/\\/g, "/").replace(/\/+$/, "");
        if (isWin) {
            const m = s.match(/^\/([A-Za-z])\/(.*)$/);
            if (m) s = m[1] + ":/" + m[2];
            s = s.toLowerCase();
        }
        return s;
    }
    const target = norm(e.HROOT);
    const repos = (j && j.repos) || {};
    for (const k of Object.keys(repos)) {
        const entry = repos[k];
        // A null or non-object entry is MALFORMED STRUCTURE, not a non-match.
        // Dereferencing it threw an uncaught TypeError (rc=1), which the shell
        // below reports as "no handover registry entry matches this checkout"
        // -- an instrument failure wearing a benign verdict, the same
        // misdiagnosis class this whole change exists to remove. Report it as
        // the validation error it is (rc=2).
        if (!entry || typeof entry !== "object") {
            // Keep this program free of the single-quote character: the whole
            // node -e body is one SINGLE-quoted shell word, so a literal one
            // closes it and the shell then eats the surrounding double quotes.
            // This exact line first shipped quoting the key by hand and reached
            // the operator as "registry entry  + k +  is not an object" -- the
            // key gone, the concatenation printed as text. JSON.stringify adds
            // the quotes on the JavaScript side, where the shell cannot reach.
            console.error("registry entry " + JSON.stringify(k) + " is not an object");
            process.exit(2);
        }
        const p = norm(entry.path);
        if (p && p === target) {
            const bucket = entry.bucket_name || k;
            process.stdout.write((entry.user || "") + "\t" + bucket);
            process.exit(0);
        }
    }
    process.exit(1);
' 2>"$TMP/reg.err") || reg_rc=$?

if [ "$reg_rc" -eq 2 ]; then
    echo "ERR upstream-watch: handover registry at $REGISTRY_FILE is not valid JSON, or an entry in it is malformed — delta WAS found ($DELTA_COUNT item(s)) but the report bucket cannot be resolved. State left untouched so this delta is retried next run:" >&2
    cat "$TMP/reg.err" >&2 2>/dev/null || true
    exit 2
fi
if [ "$reg_rc" -ne 0 ] || [ -z "$REG_MATCH" ]; then
    echo "ERR upstream-watch: no handover registry entry in $REGISTRY_FILE matches this checkout ($HIMMEL_ROOT_FOR_BUCKET) — delta WAS found ($DELTA_COUNT item(s)) but the report bucket cannot be resolved. Register this checkout (/handover register) or set HANDOVER_REGISTRY. State left untouched so this delta is retried next run." >&2
    exit 2
fi

REPORT_USER="${REG_MATCH%%$'\t'*}"
REPORT_BUCKET="${REG_MATCH#*$'\t'}"
if [ -z "$REPORT_USER" ]; then
    if ! REPORT_USER=$(user_slug); then
        echo "ERR upstream-watch: registry entry for this checkout has no 'user' field, and user_slug could not resolve one either (set USER_SLUG or 'git config user.name') — delta WAS found ($DELTA_COUNT item(s)) but the report bucket cannot be resolved. State left untouched so this delta is retried next run." >&2
        exit 2
    fi
fi

# REPORT_USER/REPORT_BUCKET came out of the handover registry (or, for
# REPORT_USER, the user_slug fallback above) and are about to become path
# components under REPORT_ROOT. Neither is validated by the node lookup
# above, so a registry 'user' or 'bucket_name' of ".." or containing a
# separator would walk REPORT_DIR outside REPORT_ROOT. Reject anything that
# is not a single safe path component -- same fail-closed contract as the
# bucket-resolution errors above: state is left untouched so this delta is
# retried next run.
case "$REPORT_USER" in
    ''|.|..|*/*|*"\\"*)
        echo "ERR upstream-watch: registry field 'user' (REPORT_USER) resolved to an unsafe path component ('$REPORT_USER') from $REGISTRY_FILE — delta WAS found ($DELTA_COUNT item(s)) but the report bucket cannot be resolved. State left untouched so this delta is retried next run." >&2
        exit 2
        ;;
esac
case "$REPORT_BUCKET" in
    ''|.|..|*/*|*"\\"*)
        echo "ERR upstream-watch: registry field 'bucket_name' (REPORT_BUCKET) resolved to an unsafe path component ('$REPORT_BUCKET') from $REGISTRY_FILE — delta WAS found ($DELTA_COUNT item(s)) but the report bucket cannot be resolved. State left untouched so this delta is retried next run." >&2
        exit 2
        ;;
esac

REPORT_DIR="$REPORT_ROOT/$REPORT_USER/$REPORT_BUCKET/specs/reports"
REPORT_FILE="$REPORT_DIR/upstream-watch-$(date -u +%Y-%m-%d).md"
mkdir_rc=0
mkdir -p "$REPORT_DIR" 2>"$TMP/mkdir.err" || mkdir_rc=$?
build_rc=0
if [ "$mkdir_rc" -eq 0 ]; then
    # set +e/set -e bracket, NOT `subshell || build_rc=$?` (codex-1, round 4):
    # bash's -e suspension for a command whose exit status is being TESTED
    # (the non-last operand of `||`, an `if` condition, `!`) propagates INTO
    # any subshell that command forks — an explicit `set -e` inside that
    # subshell has NO effect there, because the suppression is a shell-
    # internal "ignore -e" state, not the errexit shopt itself (BashFAQ 105).
    # So `( set -e; build_report ... ) || build_rc=$?` still swallowed an
    # internal jq failure, same bug as the `if ! build_report` shape this
    # replaced. The only way -e actually fires inside the subshell is to run
    # it as a bare, UNTESTED statement — which means the OUTER shell's own
    # errexit must be off first, or a failure here would abort the whole
    # script here instead of reaching the graceful ERR handling below.
    set +e
    ( set -e; build_report "$REPORT_FILE" )
    build_rc=$?
    set -e
fi
if [ "$mkdir_rc" -ne 0 ] || [ "$build_rc" -ne 0 ]; then
    echo "ERR upstream-watch: could not write the delta report to $REPORT_FILE — delta WAS found ($DELTA_COUNT item(s)). State left untouched so this delta is retried next run:" >&2
    cat "$TMP/mkdir.err" >&2 2>/dev/null || true
    exit 2
fi

write_state
send_telegram "$REPORT_FILE" "$DELTA_COUNT"
exit 10
