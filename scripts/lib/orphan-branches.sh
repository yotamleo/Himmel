#!/usr/bin/env bash
# orphan-branches.sh — detect pushed branches with no PR + report chain health.
# (HIMMEL-1325 chunk C — the lean-invoke branch→PR orphan guard.)
#
# THE INVARIANT (the durable signal, not session liveness):
#   Every branch on origin must have a PR. A branch WITH a PR survives its
#   session; one WITHOUT one depends on a process staying alive. A resident
#   claude.exe is not evidence work is progressing, and an exited session is
#   not evidence work finished — so this keys off branch+PR pairing, never
#   process liveness.
#
# HOW IT AVOIDS THE FALSE-POSITIVE TRAP (HIMMEL-1325): a global
#   `gh pr list --state all --limit 1000` is TRUNCATED past ~999 refs, so a
#   "is my branch in that list" membership test flags every older branch as
#   orphaned — 81 false positives on 2026-07-28. This lib NEVER issues a
#   headless `gh pr list`: it queries PER-BRANCH (`gh pr list --head <branch>`),
#   scoped to one branch so it is bounded and never truncated by the global
#   cap. Candidates are narrowed locally first (pure git) by a date window +
#   protected-name exclude + count cap, and EVERY bound is stated in the output
#   (silent truncation reads as "covered everything" — the exact failure this
#   guard exists to fix). After a SQUASH merge the source branch still reads
#   ahead of main, so `ahead=N` is NOT used as an unmerged signal — PR STATE
#   (none/open/merged) is the signal, queried per-branch.
#
# CHAIN HEALTH — five states, the furthest stage a branch reached:
#   pushed     on origin, NO pr  (the orphan — the failure class)        [WARN]
#   pr         open pr, ci not green                                        [info]
#   ci-green   open pr, all checks passing                                  [info]
#   merged     merged pr (propagation not confirmed)                       [info]
#   propagated merged pr whose squash commit reached the public clone       [info]
#   (closed — a branch whose only pr was closed-unmerged; abandoned work,
#    reported as a truncated chain, never an orphan.)
# A branch still on origin is by definition not fully shipped: the merge flow
# deletes the source branch on success, so `propagated` self-removes. A scan of
# current origin branches therefore surfaces the TRUNCATED chains.
#
# Sourced by check_c17 (scripts/himmel-doctor.sh); also directly runnable for
# an ad-hoc scan (`bash scripts/lib/orphan-branches.sh`).
#
# Seams (test overrides — same shape as scripts/lib/branch-shipped.sh):
#   FORGE=github              bypass origin detection (forge seam)
#   GH_CMD=<path>             override the `gh` binary for the per-branch pr query
#   OB_CI_CMD=<path>          override `gh pr checks` (ci enrichment; defaults to gh)
#   ORPHAN_BRANCH_DAYS=N      date window in days (default 30)
#   ORPHAN_BRANCH_MAX=N       cap on branches scanned (default 50)
#   ORPHAN_BRANCH_IGNORE=     space-separated glob patterns to always skip
#   ORPHAN_BRANCH_TIMEOUT=N   per-call gh timeout seconds (default 15)
#   ORPHAN_BRANCH_FETCH=1     `git fetch origin` before scanning (default off)
#   ORPHAN_PUBLIC_CLONE=<dir> public clone dir (propagated state; maintainer only)
#   OB_PRIMARY=<dir>          primary repo dir (dual-mode run only)
#
# DO NOT add set -e / set -euo pipefail at file scope — this is a sourced
# library; that would leak into the sourcing shell. Guard internally.

_OB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/forge.sh
# shellcheck disable=SC1091
. "$_OB_LIB_DIR/forge.sh"

_ob_timeout_cmd() {
    if command -v timeout >/dev/null 2>&1; then printf 'timeout'
    elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'; fi
}

# _ob_bounded <secs> <outfile> <primary> <cmd...> — portable per-call timeout for
# hosts with NO `timeout`/`gtimeout` (stock macOS ships bash 3.2 + BSD coreutils,
# no GNU timeout). Runs <cmd> from <primary>, stdout to <outfile> + stderr
# discarded (same capture shape as the `timeout` branch), bounded to <secs>
# wall-clock. Returns the child's exit status on normal completion, or 124 on
# timeout (GNU `timeout`'s convention — both call sites already map any non-zero
# rc to uncertain/pending, so 124 lands correctly and consistently with the
# timeout-binary path).
#
# Why this exists (HIMMEL-1325): _ob_timeout_cmd returns empty when no timeout
# binary is present, and without this fallback _ob_gh_list / _ob_ci_state run `gh`
# UNBOUNDED — a hung call hangs the whole scan with no ceiling, on a lib whose
# whole point is to be bounded by ORPHAN_BRANCH_TIMEOUT.
#
# Design notes:
#   * Whole body runs in a `set +m` subshell so the background `&` never emits
#     `[n] PID` / `Done` job-control noise, even if the sourcing shell is
#     interactive; `set +m` is scoped to the subshell and never touches the
#     caller. (Every real call site is a non-interactive script, where job
#     control is already off — this is belt-and-suspenders.)
#   * `exec` replaces the launcher subshell with <cmd>, so $! is <cmd>'s own PID
#     and SIGTERM hits it directly. gh is a single binary with no child tree, so
#     this leaves nothing orphaned. (A command that itself spawns long-lived
#     children could orphan those — best-effort, the same limitation GNU
#     `timeout` has without a process-group kill, which its own `-k` does not
#     widen; not a concern for the gh callee here.)
#   * Output to a FILE, not $( ): a surviving process cannot hold a command
#     substitution's pipe open (the same reason _ob_gh_list uses mktemp).
#   * Bash 3.2-safe: no `wait -n` (4.3+), no mapfile (4.0+), no coproc. Polls
#     with `kill -0` (non-blocking liveness) at 1s granularity, so the bound is
#     <secs> rounded up by at most ~1s — the same budget the `timeout` path uses.
_ob_bounded() {
    local secs="$1" outfile="$2" primary="$3"; shift 3
    (
        set +m
        ( cd "$primary" && exec "$@" ) >"$outfile" 2>/dev/null &
        local pid=$! rc="" i=0
        while [ "$i" -lt "$secs" ]; do
            # SIGZERO liveness check: succeeds only while the child lives, so this
            # never blocks on a running child.
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" 2>/dev/null; rc=$?        # reap + capture real status
                break
            fi
            sleep 1
            i=$((i + 1))
        done
        if [ -z "$rc" ]; then
            # Loop exhausted => child outlived the budget. Kill + reap (no zombie,
            # no lingering proc); SIGKILL escalation if SIGTERM is ignored. If it
            # died during the final sleep, kill -0 fails and we skip to the reap,
            # still reported as a timeout — it did not finish inside the window.
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null
                sleep 1
                kill -9 "$pid" 2>/dev/null
            fi
            wait "$pid" 2>/dev/null
            rc=124
        fi
        exit "$rc"
    )
}

# Is the forge github? (gh orphan scan is a github concern; bitbucket uses a
# different flow — see himmel-doctor C4.) Sourced forge_detect honors FORGE.
_ob_forge_ok() {
    local f
    f="$(cd "$1" 2>/dev/null && forge_detect 2>/dev/null)" || return 1
    [ "$f" = github ]
}

_ob_fetch() {
    local tcmd; tcmd="$(_ob_timeout_cmd)"
    if [ -n "$tcmd" ]; then
        "$tcmd" 60 git -C "$1" fetch origin --prune >/dev/null 2>&1
    else
        # Same bound as the `timeout` path above. This else-branch previously ran
        # the fetch UNBOUNDED, which is the third instance of the defect fixed at
        # _ob_gh_list and _ob_ci_state — a network fetch is the likeliest of the
        # three to hang, so leaving it out would have shipped a bounded-scan
        # guarantee with a hole in it.
        _ob_bounded 60 /dev/null "$1" git fetch origin --prune
    fi
}

# _ob_gh_list <primary_dir> <branch> — query THIS branch's PRs from the target
# repo (per-branch, never global). Sets globals _ob_out (tsv rows) and _ob_rc
# (0 = query succeeded).
#   rc 0 + empty   -> 0 PRs. Confirmed by a SECOND query before it is reported
#                     as an orphan — an empty rc=0 response is also what a
#                     transient forge hiccup looks like (see orphan_branch_scan).
#   rc != 0        -> forge unreachable (uncertain — never a false orphan)
_ob_gh_list() {
    local primary="$1" branch="$2" secs="${ORPHAN_BRANCH_TIMEOUT:-15}" tcmd tmp
    tcmd="$(_ob_timeout_cmd)"
    # Capture to a FILE, not a command substitution. `timeout` signals only the
    # direct child, so a surviving GRANDCHILD keeps the substitution's pipe open
    # and `$( … )` blocks for the grandchild's full lifetime — the timeout then
    # bounds nothing (observed on Git Bash / Windows: a 1s timeout took 39s).
    # Reading a regular file cannot block that way, so the bound actually holds.
    # mktemp, NOT a predictable "$$-$RANDOM" path: this file is opened with `>`,
    # so a guessable name in a shared /tmp lets an attacker pre-plant a symlink
    # and clobber any file the running user can write (codex-1).
    tmp=$(mktemp -t ob-gh.XXXXXX) || { _ob_out=""; _ob_rc=1; return 0; }
    # The query is ALWAYS scoped with --head <branch> — a headless `gh pr list`
    # is the truncation root cause (see file header). T14 STATIC asserts this.
    if [ -n "$tcmd" ]; then
        (cd "$primary" && "$tcmd" -k 2 "$secs" "${GH_CMD:-gh}" pr list --head "$branch" \
            --state all --limit 100 --json number,state,mergeCommit \
            --jq '.[] | [.number, .state, (.mergeCommit.oid // "-")] | @tsv') \
            >"$tmp" 2>/dev/null
        _ob_rc=$?
    else
        # No `timeout` binary (stock macOS / minimal containers): the portable
        # _ob_bounded runner enforces the same ORPHAN_BRANCH_TIMEOUT budget so a
        # hung gh cannot hang the scan unbounded (HIMMEL-1325).
        _ob_bounded "$secs" "$tmp" "$primary" "${GH_CMD:-gh}" pr list --head "$branch" \
            --state all --limit 100 --json number,state,mergeCommit \
            --jq '.[] | [.number, .state, (.mergeCommit.oid // "-")] | @tsv'
        _ob_rc=$?
    fi
    _ob_out="$(cat "$tmp" 2>/dev/null)"
    rm -f "$tmp"
}

# _ob_ci_state <primary_dir> <pr_number> -> echoes green|none|pending|failed
# (best-effort; never affects the orphan/merged determination — only enriches
# an open-pr branch). gh documents rc=8 for pending checks. rc=1 is AMBIGUOUS:
# `gh pr checks` exits 1 for BOTH a genuinely red check AND "no checks reported"
# (cli/cli#9390, #9682, #7401 — upstream has repeatedly declined to change it),
# and Actions is OFF on this private repo, so "no checks" is the COMMON case. rc=1
# is therefore resolved by INSPECTING the captured output, not the exit code alone:
# empty/whitespace-only output, or gh's "no checks" message, => none; any
# check-row content => failed. Other non-zero exits stay pending (conservative).
_ob_ci_state() {
    local primary="$1" num="$2" secs="${ORPHAN_BRANCH_TIMEOUT:-15}" tcmd out rc tmp
    tcmd="$(_ob_timeout_cmd)"
    # Same grandchild-holds-the-pipe reason as _ob_gh_list: capture to a file.
    # mktemp for the same symlink-clobbering reason as _ob_gh_list (codex-1).
    tmp=$(mktemp -t ob-ci.XXXXXX) || { printf 'pending'; return; }
    if [ -n "$tcmd" ]; then
        (cd "$primary" && "$tcmd" -k 2 "$secs" "${OB_CI_CMD:-${GH_CMD:-gh}}" pr checks "$num") >"$tmp" 2>/dev/null; rc=$?
    else
        # Same portable bound as _ob_gh_list when no `timeout` binary exists (HIMMEL-1325).
        _ob_bounded "$secs" "$tmp" "$primary" "${OB_CI_CMD:-${GH_CMD:-gh}}" pr checks "$num"; rc=$?
    fi
    out="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
    if [ "$rc" -eq 8 ]; then printf 'pending'; return; fi
    if [ "$rc" -eq 1 ]; then
        # Resolve the rc=1 ambiguity by OUTPUT, not exit code alone (see header).
        # gh's no-checks message goes to stderr (captured to /dev/null), so the
        # common no-checks case leaves $out empty/whitespace-only => none. The
        # literal "no checks" message is matched too, for gh builds that print it
        # to stdout (anchored to a line start so a check whose NAME contains those
        # words is not misread). Anything else is a real checks table => failed.
        if [ -z "${out//[[:space:]]/}" ]; then printf 'none'; return; fi
        if printf '%s\n' "$out" | grep -qiE '^[[:space:]]*no checks'; then printf 'none'; return; fi
        printf 'failed'; return
    fi
    if [ "$rc" -ne 0 ]; then printf 'pending'; return; fi
    if [ -z "$out" ]; then printf 'none'; return; fi
    printf 'green'
}

# _ob_is_propagated <merge_oid> <public_clone> -> rc 0 if the squash commit is
# present in the public clone's object db. Conservative: squash→squash rewrites
# the SHA, so this resolves `propagated` only when the commit was copied
# verbatim; otherwise the branch stays `merged` (repo-level propagation truth
# is owned by himmel-doctor C10 / propagation-drift, not re-derived here).
_ob_is_propagated() {
    local oid="$1" pub="$2"
    [ -n "$oid" ] && [ "$oid" != "-" ] && [ -n "$pub" ] && [ -d "$pub" ] \
        && git -C "$pub" cat-file -e "$oid" >/dev/null 2>&1
}

# _ob_is_ignored <name> -> rc 0 if the branch should be skipped.
_ob_is_ignored() {
    local n="$1" pat
    case "$n" in
        ""|main|master|HEAD|dev|develop) return 0 ;;
    esac
    [ -n "$_ob_default" ] && [ "$n" = "$_ob_default" ] && return 0
    for pat in $_ob_ignore_globs; do          # intentional unquote: word-split globs
        # shellcheck disable=SC2254  # $pat MUST glob here — these are user-supplied
        # patterns (e.g. 'renovate/*'); quoting would match them literally.
        case "$n" in $pat) return 0 ;; esac
    done
    return 1
}

# _ob_classify <primary_dir> <branch> — consumes _ob_out/_ob_rc, prints one result line.
_ob_classify() {
    local primary="$1" branch="$2"
    if [ "$_ob_rc" -ne 0 ]; then
        printf 'uncertain: %s (forge unreachable)\n' "$branch"; return
    fi
    local has_any=0 merged_oid="" open_num="" has_closed=0 num state oid
    while IFS="$(printf '\t')" read -r num state oid; do
        [ -n "$num" ] || continue
        has_any=1
        case "$state" in
            MERGED) [ -n "$merged_oid" ] || merged_oid="${oid:--}" ;;
            OPEN)   open_num="$num" ;;
            CLOSED) has_closed=1 ;;
        esac
    done <<EOF
$_ob_out
EOF
    if [ "$has_any" -eq 0 ]; then
        printf 'ORPHAN %s\n' "$branch"; return
    fi
    if [ -n "$merged_oid" ]; then
        if _ob_is_propagated "$merged_oid" "$_ob_public"; then
            printf 'chain: propagated %s\n' "$branch"
        else
            printf 'chain: merged %s\n' "$branch"
        fi
        return
    fi
    if [ -n "$open_num" ]; then
        local ci; ci="$(_ob_ci_state "$primary" "$open_num")"
        if [ "$ci" = green ]; then
            printf 'chain: ci-green %s (pr #%s)\n' "$branch" "$open_num"
        else
            printf 'chain: pr %s (pr #%s, ci=%s)\n' "$branch" "$open_num" "$ci"
        fi
        return
    fi
    if [ "$has_closed" -eq 1 ]; then
        printf 'chain: closed %s\n' "$branch"; return
    fi
    printf 'uncertain: %s (unrecognized pr states)\n' "$branch"
}

# orphan_branch_scan <primary_dir> — print the scan report to stdout.
# Always returns 0 once a scan ran (callers parse stdout). Never a false orphan
# on forge outage (those print `uncertain:`).
orphan_branch_scan() {
    local primary="${1:-${OB_PRIMARY:-}}"
    [ -n "$primary" ] || primary="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$primary" ] || [ ! -d "$primary" ]; then
        echo "orphan-branches: no git repo to scan (skipped)"
        return 0
    fi
    if ! _ob_forge_ok "$primary"; then
        echo "orphan-branches: skipped (forge not github; gh orphan scan is a github concern)"
        return 0
    fi

    # Base-10 force: a leading-zero value (e.g. "08") is parsed as OCTAL in the
    # $(( )) cutoff below ("value too great for base" -> scan aborts; verified on
    # 2026-07-28). Same $((10#$var)) idiom as scripts/check-ci.sh. `max` needs
    # none: it is only ever used in a [ -ge ] test (decimal), never in $(( ))
    # (HIMMEL-1325). The cutoff re-applies 10# as defense-in-depth at the one
    # arithmetic site the value actually reaches.
    local days="${ORPHAN_BRANCH_DAYS:-30}"
    days=$((10#$days))
    local max="${ORPHAN_BRANCH_MAX:-50}"
    _ob_public="${ORPHAN_PUBLIC_CLONE:-}"
    _ob_default="$(git -C "$primary" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
    _ob_ignore_globs="${ORPHAN_BRANCH_IGNORE:-}"

    local fetched="no"
    if [ "${ORPHAN_BRANCH_FETCH:-0}" = "1" ]; then
        _ob_fetch "$primary" && fetched="yes"
    fi

    # Narrow the candidate set LOCALLY first (pure git) so the per-branch gh
    # call count stays small (a per-branch loop over ALL remote branches times
    # out past ~2 min). Date window keeps it to recent activity; every bound is
    # stated in the header below.
    #
    # The ref list is sorted NEWEST-FIRST (`--sort=-committerdate`) because the
    # `max` cap truncates it. git's default order is by REFNAME, so an
    # alphabetical cap would silently drop the most recently pushed branches —
    # precisely the ones most likely to be live orphans, and the exact class this
    # guard exists to catch (codex-2).
    local cutoff now
    now="$(date +%s)"
    cutoff=$(( now - 10#$days * 86400 ))
    local candidates=() name cdate n=0
    while IFS=' ' read -r name cdate; do
        [ -n "$name" ] || continue
        case "$name" in origin/*) name="${name#origin/}" ;; *) continue ;; esac
        _ob_is_ignored "$name" && continue
        # empty/non-numeric committerdate -> include (fail-safe toward scanning)
        case "$cdate" in ''|*[!0-9]*) cdate="$cutoff" ;; esac
        [ "$cdate" -ge "$cutoff" ] || continue
        candidates+=("$name")
        n=$((n + 1))
        [ "$n" -ge "$max" ] && break
    done <<EOF
$(git -C "$primary" for-each-ref --sort=-committerdate --format='%(refname:short) %(committerdate:unix)' refs/remotes/origin/ 2>/dev/null)
EOF

    local ig="main|master|HEAD|dev|develop"
    [ -n "$_ob_default" ] && ig="$ig|$_ob_default"
    [ -n "$_ob_ignore_globs" ] && ig="$ig $_ob_ignore_globs"
    printf "orphan-branches: scanning %d candidate(s) window=%dd max=%d per-branch-limit=100 ignore='%s' fetch=%s\n" \
        "${#candidates[@]}" "$days" "$max" "$ig" "$fetched"

    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "orphan-branches: no candidate remote branches in window (refs as of last fetch; set ORPHAN_BRANCH_FETCH=1 to refresh)"
        return 0
    fi

    local b
    for b in "${candidates[@]}"; do
        _ob_gh_list "$primary" "$b"
        # CONFIRM an empty result before it becomes an ORPHAN claim. rc=0 with
        # no rows is the orphan signal, but it is ALSO what a transient forge
        # hiccup looks like: on 2026-07-28 `gh pr list --head` returned rc=0 and
        # empty for fix/himmel-1315-revert-duplicate-switch, whose PR #1442 was
        # in fact MERGED — a re-query returned it. That is a false ORPHAN from
        # the very call this guard treats as authoritative, so query twice and
        # only claim ORPHAN when both agree. A noisy guard gets ignored, which
        # is how this failure class survived unnoticed in the first place.
        if [ "$_ob_rc" -eq 0 ] && [ -z "$_ob_out" ]; then
            _ob_gh_list "$primary" "$b"
        fi
        _ob_classify "$primary" "$b"
    done
    return 0
}

# ── dual-mode: run directly for an ad-hoc scan ────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    _ob_primary="${OB_PRIMARY:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
    _ob_report="$(orphan_branch_scan "$_ob_primary" 2>&1)"
    printf '%s\n' "$_ob_report"
    if printf '%s\n' "$_ob_report" | grep -q '^ORPHAN '; then exit 1; fi
    exit 0
fi
