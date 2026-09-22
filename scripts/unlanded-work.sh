#!/usr/bin/env bash
# unlanded-work.sh — find local branches ahead of main that never became a PR
# (HIMMEL-2070).
#
# /clean only prunes a worktree whose branch already has a MERGED PR — a
# branch that was squash-merged under a DIFFERENT head (a squash rewrites the
# patch-id), or one that was simply never pushed as a PR at all, is invisible
# to it by design. This script is the missing "which local branch is ahead of
# main with no PR?" scan. Read-only, advisory: it never touches a worktree,
# never deletes a branch, never pushes.
#
#   bash scripts/unlanded-work.sh [--tsv] [--age-hours N] [--no-forge]
#                                  [--class CLASS] [--base REF] [--health]
#                                  [-h|--help]
#
# CLASS is one of ACTIVE | LANDED-ELSEWHERE | STALE | UNLANDED-LIVE.
#
# FAIL-LOUD INVARIANT: when a signal is unavailable or ambiguous, a branch
# must land in the LOUDER class — UNLANDED-LIVE > STALE > LANDED-ELSEWHERE —
# never the quieter one. A forge outage must never turn UNLANDED-LIVE into
# LANDED-ELSEWHERE: the forge-based rules (1/2) are only ever additive
# (evidence for ACTIVE/LANDED-ELSEWHERE), so skipping them on outage just
# falls through to the git-based rules (3-6), which never yield a quieter
# verdict than the git evidence supports. Likewise rule 4 deliberately
# requires BOTH "key on main" AND "delta no longer applies" — key-on-main
# alone is not sufficient, so a ticket with an earlier PARTIAL PR still
# surfaces its unlanded remainder as UNLANDED-LIVE (annotated "partial: ...").
#
# --health (HIMMEL-3405) prints ONLY alarm lines — empty output = healthy:
#   LOST-COMMITS <branch> pr#<n> ahead=<k>   a local or remote branch whose PR is
#       MERGED but whose tip carries <k> commits that are in neither the merged
#       head nor main (a post-merge push that never landed)
#   SWEEP-ERROR <branch> <cause>             this scan could not classify or
#       check a branch (no merge base, git failure, PR listing unavailable...)
# and exits 1 when any line was printed.
#
# Otherwise always exits 0 (advisory/read-only). Exit 2 only on a usage error.
set -uo pipefail

BASE="origin/main"
AGE_THRESHOLD=24
TSV=0
FORGE_ON=1
CLASS_FILTER=""
HEALTH=0

usage() {
    cat <<'EOF'
Usage: unlanded-work.sh [--tsv] [--age-hours N] [--no-forge] [--class CLASS] [--base REF] [--health] [-h|--help]

  --tsv            One row per branch, tab-separated, no header:
                    CLASS  BRANCH  AHEAD  AGE_HOURS  AGED(0|1)  EVIDENCE  WORKTREE_PATH_OR_EMPTY
  --age-hours N    Age threshold in hours for the AGED flag (default 24).
  --no-forge       Skip the gh PR lookup (rules 1/2 never fire; classification
                    falls through to the git-only rules).
  --class CLASS    Only report this class: ACTIVE | LANDED-ELSEWHERE | STALE | UNLANDED-LIVE.
  --base REF       Compare against REF instead of origin/main.
  --health         Print only alarm lines (LOST-COMMITS / SWEEP-ERROR); empty =
                    healthy. Exit 1 when any alarm was printed. Excludes --tsv
                    and --class.
  -h, --help       This message.

Read-only and advisory: always exits 0 unless the command line itself is bad
(exit 2) or --health found an alarm (exit 1). Never touches a worktree, never
deletes a branch.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --tsv) TSV=1; shift ;;
        --age-hours)
            [ $# -ge 2 ] || { echo "unlanded-work: --age-hours requires N" >&2; exit 2; }
            case "$2" in ''|*[!0-9]*) echo "unlanded-work: --age-hours must be a non-negative integer, got '$2'" >&2; exit 2 ;; esac
            AGE_THRESHOLD="$2"; shift 2 ;;
        --no-forge) FORGE_ON=0; shift ;;
        --class)
            [ $# -ge 2 ] || { echo "unlanded-work: --class requires a value" >&2; exit 2; }
            case "$2" in
                ACTIVE|LANDED-ELSEWHERE|STALE|UNLANDED-LIVE) CLASS_FILTER="$2" ;;
                *) echo "unlanded-work: --class must be one of ACTIVE|LANDED-ELSEWHERE|STALE|UNLANDED-LIVE, got '$2'" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --base)
            [ $# -ge 2 ] || { echo "unlanded-work: --base requires a REF" >&2; exit 2; }
            BASE="$2"; shift 2 ;;
        --health) HEALTH=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unlanded-work: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

if [ "$HEALTH" = 1 ] && { [ "$TSV" = 1 ] || [ -n "$CLASS_FILTER" ]; }; then
    echo "unlanded-work: --health cannot be combined with --tsv or --class" >&2
    exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
    echo "unlanded-work: not inside a git repo — nothing to report" >&2
    [ "$HEALTH" = 1 ] && { echo "SWEEP-ERROR (sweep) not inside a git repo — nothing was checked"; exit 1; }
    exit 0
fi
cd "$REPO_ROOT" || exit 0

if ! git rev-parse --verify -q "${BASE}^{commit}" >/dev/null 2>&1; then
    echo "unlanded-work: base ref '$BASE' does not resolve here (fetch it, or pass --base) — nothing to report" >&2
    [ "$HEALTH" = 1 ] && { echo "SWEEP-ERROR (sweep) base ref '$BASE' does not resolve here — nothing was checked"; exit 1; }
    exit 0
fi

# ── shared temp index for the apply-ability probes, cleaned up on exit ──────
idx="$(mktemp)"
rows_file="$(mktemp)"
health_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$idx" "$rows_file" "$health_file" "$err_file"' EXIT
GIT_INDEX_FILE="$idx" git read-tree "$BASE" >/dev/null 2>&1 || true

reverse_applies() { # $1 = delta text
    printf '%s\n' "$1" | GIT_INDEX_FILE="$idx" git apply --cached --check -R - >/dev/null 2>&1
}
forward_applies() { # $1 = delta text
    printf '%s\n' "$1" | GIT_INDEX_FILE="$idx" git apply --cached --check - >/dev/null 2>&1
}

# ── worktree lookup (built once) ─────────────────────────────────────────────
WT_PATHS=(); WT_BRANCHES=()
_wt_path=""; _wt_branch=""
_wt_flush() {
    if [ -n "$_wt_path" ]; then WT_PATHS+=("$_wt_path"); WT_BRANCHES+=("$_wt_branch"); fi
    _wt_path=""; _wt_branch=""
}
while IFS= read -r _line; do
    case "$_line" in
        worktree\ *) _wt_flush; _wt_path="${_line#worktree }" ;;
        branch\ refs/heads/*) _wt_branch="${_line#branch refs/heads/}" ;;
        "") _wt_flush ;;
    esac
done < <(git worktree list --porcelain 2>/dev/null)
_wt_flush

worktree_for_branch() {
    local b="$1" i
    for i in "${!WT_BRANCHES[@]}"; do
        [ "${WT_BRANCHES[$i]}" = "$b" ] && { printf '%s' "${WT_PATHS[$i]}"; return 0; }
    done
    printf ''
}

# ── forge cache: ONE call, timeout-bounded, fail-OPEN ────────────────────────
FORGE_OK=0
FORGE_CACHE=""
if [ "$FORGE_ON" = 1 ] && command -v jq >/dev/null 2>&1; then
    GH_BIN="${GH_CMD:-gh}"
    FORGE_TIMEOUT="${UNLANDED_FORGE_TIMEOUT:-15}"
    tcmd=""
    if command -v timeout >/dev/null 2>&1; then tcmd="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then tcmd="gtimeout"
    fi
    if [ -n "$tcmd" ]; then
        FORGE_CACHE="$("$tcmd" "$FORGE_TIMEOUT" "$GH_BIN" pr list --state all --limit 1000 --json headRefName,number,state,headRefOid,baseRefName 2>/dev/null)"
    else
        FORGE_CACHE="$("$GH_BIN" pr list --state all --limit 1000 --json headRefName,number,state,headRefOid,baseRefName 2>/dev/null)"
    fi
    if printf '%s' "$FORGE_CACHE" | jq -e 'type=="array"' >/dev/null 2>&1; then
        FORGE_OK=1
    else
        FORGE_CACHE=""
    fi
fi

# BASE_BARE: the bare branch name gh's baseRefName field reports (never a
# remote prefix) — strip exactly one leading "<remote>/" segment from BASE
# (codex-4, HIMMEL-2070 CR round 4), but ONLY when BASE is actually a
# remote-tracking ref (codex-3, CR round 5): a bare LOCAL --base can itself
# be a nested branch name containing a slash (e.g. --base release/2.0), and
# blindly stripping up to the first slash would mangle that into "2.0",
# never matching a real merged PR's baseRefName. Confirming refs/remotes/
# first distinguishes "origin/main" (strip "origin/") from "release/2.0"
# (already bare, pass through unchanged).
BASE_BARE="$BASE"
if git rev-parse --verify -q "refs/remotes/${BASE}" >/dev/null 2>&1; then
    case "$BASE" in */*) BASE_BARE="${BASE#*/}" ;; esac
fi

# MERGED_HEADS (HIMMEL-3405): "<headRefOid> <number>" for every MERGED PR into
# BASE whose head commit exists in THIS repo -- the evidence for the tip rule in
# forge_tip_lookup. Built once; a head that was never fetched cannot be compared
# and is left out (the fail-LOUD direction: no evidence, no LANDED).
MERGED_HEADS=""
if [ "$FORGE_OK" = 1 ]; then
    _mh="$(printf '%s' "$FORGE_CACHE" | jq -r --arg base "$BASE_BARE" \
        '.[] | select(.state=="MERGED" and .baseRefName==$base and ((.headRefOid // "") | length) > 0) | "\(.headRefOid) \(.number)"' 2>/dev/null)"
    if [ -n "$_mh" ]; then
        _present="$(printf '%s\n' "$_mh" | cut -d' ' -f1 | git cat-file --batch-check='%(objectname) %(objecttype)' 2>/dev/null | awk '$2=="commit"{print $1}')"
        if [ -n "$_present" ]; then
            MERGED_HEADS="$(printf '%s\n' "$_mh" | awk 'NR==FNR{p[$1]=1;next} ($1 in p)' <(printf '%s\n' "$_present") -)"
        fi
    fi
fi

# forge_tip_lookup <tip-sha> -> "TIPMERGED\t<n>" or empty. A ref whose tip
# EQUALS or is an ANCESTOR of a MERGED PR's final head has no commit of its own
# that the PR did not carry into BASE -- whatever the ref is called. This is what
# classifies a review snapshot (pr<N>, pr<N>tmp, ...) the name-keyed rule below
# can never match (HIMMEL-3405). A tip AHEAD of the head is not an ancestor and
# falls through to the git rules.
forge_tip_lookup() {
    local oid n
    [ -n "$MERGED_HEADS" ] || return 0
    while read -r oid n; do
        [ -n "$oid" ] || continue
        if git merge-base --is-ancestor "$1" "$oid" 2>/dev/null; then
            printf 'TIPMERGED\t%s\n' "$n"
            return 0
        fi
    done <<EOF
$MERGED_HEADS
EOF
}

# forge_lookup <branch> <tip-sha> -> "OPEN\t<n>" or "MERGED\t<n>" (by name) or
# "TIPMERGED\t<n>" (by tip, name-agnostic) or empty (open wins). MERGED requires BOTH the PR's recorded headRefOid to equal the
# branch's CURRENT tip AND its baseRefName to equal BASE_BARE:
#   - tip match: a branch name can be reused/rewound after its PR merged (a
#     mere "this branch name once had a merged PR" is not evidence the
#     CURRENT tip's content shipped — the same trap clean-garden.sh's own
#     PR_HEAD_MATCH check exists to close);
#   - base match: a PR merged into some OTHER branch never necessarily
#     landed on the configured BASE at all.
# Either mismatch falls through to the git-based rules (3-6) instead of a
# forge-asserted LANDED-ELSEWHERE — the FAIL-LOUD direction. OPEN carries
# neither risk (any currently-open PR for this branch name is live
# work-in-progress regardless of its target branch or exact pinned commit),
# so it stays both tip- and base-agnostic.
forge_lookup() {
    [ "$FORGE_OK" = 1 ] || return 0
    local row
    row="$(printf '%s' "$FORGE_CACHE" | jq -r --arg b "$1" --arg tip "$2" --arg base "$BASE_BARE" '
        ( [.[] | select(.headRefName==$b and .state=="OPEN")]   | .[0].number ) as $o
        | ( [.[] | select(.headRefName==$b and .state=="MERGED" and .headRefOid==$tip and .baseRefName==$base)] | .[0].number ) as $m
        | if $o then "OPEN\t\($o)"
          elif $m then "MERGED\t\($m)"
          else empty end' 2>/dev/null)"
    if [ -n "$row" ]; then printf '%s\n' "$row"; return 0; fi
    forge_tip_lookup "$2"
}

# diff_failure_cause <branch> <rc> -- a readable cause for a failed delta, never
# a bare rc (HIMMEL-3405). No merge base is the one known systematic case: a
# branch whose root commit comes from another repo's history (e.g. the archived
# private himmel) has nothing to diff against.
diff_failure_cause() {
    local first
    if ! git merge-base "$BASE" "$1" >/dev/null 2>&1; then
        printf 'no merge base with %s — unrelated history' "$BASE"
        return 0
    fi
    first="$(head -1 "$err_file" 2>/dev/null)"
    printf 'git diff failed (rc=%s)%s' "$2" "${first:+: $first}"
}

now="$(date +%s)"

# ── classify every local branch ahead of BASE ────────────────────────────────
while IFS= read -r branch; do
    [ -n "$branch" ] || continue

    if ! ahead="$(git rev-list --count "${BASE}..${branch}" 2>/dev/null)"; then
        printf 'SWEEP-ERROR %s git rev-list failed against %s — branch not classified\n' "$branch" "$BASE" >> "$health_file"
        continue
    fi
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
    [ "$ahead" -gt 0 ] || continue

    tip="$(git rev-parse "refs/heads/$branch" 2>/dev/null)" || tip=""

    committed="$(git show -s --format=%ct "$branch" 2>/dev/null)" || committed=""
    age_hours=0
    case "$committed" in
        ''|*[!0-9]*) ;;
        *) age_hours=$(( (now - committed) / 3600 )); [ "$age_hours" -ge 0 ] || age_hours=0 ;;
    esac

    key="$(printf '%s' "$branch" | grep -oiE '(himmel|luna|salus)-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')"
    key_sha=""
    if [ -n "$key" ]; then
        # Bracket-anchored, not a bare substring match: this repo's convention
        # (CLAUDE.md) is every landing commit carries "[TICKET-ID]" in its
        # subject. A bare `--grep="$key"` also matches a commit that merely
        # DISCUSSES the ticket in its body (e.g. a triage/CR commit noting
        # "deferred to HIMMEL-1895") without that ticket's work ever landing —
        # a false LANDED-ELSEWHERE, i.e. exactly the quieter-than-true
        # misclassification the FAIL-LOUD invariant forbids. Tightening to the
        # bracket form only ever REDUCES matches relative to the bare form, so
        # it can only push a branch toward the louder class, never the quieter one.
        key_sha="$(git log "$BASE" --grep="\[$key\]" -E --format=%h -1 2>/dev/null)"
    fi

    class=""; evidence=""; aged=0

    forge_row="$(forge_lookup "$branch" "$tip")"
    case "$forge_row" in
        # KNOWN LIMITATION (HIMMEL-2088, deferred from CR round 5, panel
        # finding codex-1): ACTIVE is deliberately tip-agnostic per the
        # ticket's own explicit rule 1 ("forge says an OPEN PR exists for
        # this branch head -> ACTIVE") — it does not check whether local
        # commits made AFTER the PR's last push are reflected in it. Low
        # risk in practice: ACTIVE branches are never offered a drop
        # command by this tool or its callers, so this is a visibility gap,
        # not a data-loss one.
        OPEN*)   class="ACTIVE";           evidence="open PR #${forge_row#OPEN$'\t'}" ;;
        MERGED*) class="LANDED-ELSEWHERE"; evidence="merged PR #${forge_row#MERGED$'\t'}" ;;
        TIPMERGED*) class="LANDED-ELSEWHERE"; evidence="merged PR #${forge_row#TIPMERGED$'\t'} (ref tip is at or behind the PR head)" ;;
    esac

    if [ -z "$class" ]; then
        # Capture the exit code (codex-2, HIMMEL-2070 CR round 4): a FAILED
        # `git diff` also yields empty stdout, which the FAIL-LOUD invariant
        # forbids treating the same as a genuinely empty (already-landed)
        # delta -- that would silently misclassify a branch whose delta
        # simply could not be computed as safe-to-drop. A failure routes to
        # the loudest class instead.
        delta_rc=0
        # --binary (codex-2, HIMMEL-2070 CR round 5): a plain `git diff` on a
        # binary file emits only a "Binary files ... differ" placeholder, not
        # the actual patch data, so `git apply --check` on it fails both
        # probes even for a branch that genuinely, uniquely changed that
        # file -- a false STALE/LANDED-ELSEWHERE for binary-only work. With
        # --binary the delta embeds real (literal/delta) binary patch data
        # apply can act on.
        delta="$(git diff --binary "${BASE}...${branch}" 2>"$err_file")" || delta_rc=$?
        if [ "$delta_rc" -ne 0 ]; then
            class="UNLANDED-LIVE"
            cause="$(diff_failure_cause "$branch" "$delta_rc")"
            evidence="$cause; could not compute a delta"
            printf 'SWEEP-ERROR %s %s\n' "$branch" "$cause" >> "$health_file"
        elif [ -z "$delta" ] || reverse_applies "$delta"; then
            class="LANDED-ELSEWHERE"
            evidence="content already on main"
        elif forward_applies "$delta"; then
            class="UNLANDED-LIVE"
            if [ -n "$key_sha" ]; then
                evidence="partial: $key on main as $key_sha"
            fi
            [ "$age_hours" -gt "$AGE_THRESHOLD" ] && aged=1
        else
            if [ -n "$key_sha" ]; then
                # KNOWN LIMITATION (HIMMEL-2088, deferred from HIMMEL-2070 CR
                # round 1, panel finding codex-2): this trusts ANY commit
                # carrying "[$key]" on main as proof the branch's work landed,
                # even when that commit is only a PARTIAL or unrelated slice
                # of the ticket. Deliberately not tightened here — it is this
                # ticket's own explicitly-specified rule, validated against
                # every required acceptance branch, and the evidence text
                # below names the exact landing commit for operator review
                # before a human runs the printed (never auto-run) drop command.
                class="LANDED-ELSEWHERE"
                evidence="$key landed on main as $key_sha; delta no longer applies"
            else
                class="STALE"
                evidence="delta conflicts with main; no ${key:-ticket} commit on main"
            fi
        fi
    fi

    wt="$(worktree_for_branch "$branch")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$class" "$branch" "$ahead" "$age_hours" "$aged" "$evidence" "$wt" >> "$rows_file"
done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

# ── --health: LOST-COMMITS over local AND remote-tracking branches ───────────
# A branch whose PR MERGED but whose tip carries commits that are in neither the
# merged head nor BASE: work pushed after the merge that never shipped. An open
# PR for the same name = live work, skipped. Only alarms are printed; the class
# tables below are not.
lost_scan() { # $1 label, $2 PR head-branch name, $3 tip
    local label="$1" name="$2" tip="$3" info n oid k d
    local healthy=0 best_k="" best_n="" unknown_n="" base_ahead
    info="$(printf '%s' "$FORGE_CACHE" | jq -r --arg b "$name" --arg base "$BASE_BARE" '
        if any(.[]; .headRefName==$b and .state=="OPEN") then "OPEN"
        else (.[] | select(.headRefName==$b and .state=="MERGED" and .baseRefName==$base)
              | "\(.number) \(.headRefOid // "")") end' 2>/dev/null)" || return 0
    [ -n "$info" ] || return 0
    case "$info" in OPEN*) return 0 ;; esac
    while read -r n oid; do
        [ -n "$n" ] || continue
        if [ "$oid" = "$tip" ]; then healthy=1; break; fi
        if [ -n "$oid" ] && git cat-file -e "${oid}^{commit}" 2>/dev/null; then
            k="$(git rev-list --count "$tip" "^$oid" "^$BASE" 2>/dev/null)" || k=""
            case "$k" in ''|*[!0-9]*) unknown_n="$n"; continue ;; esac
            if [ "$k" -eq 0 ]; then healthy=1; break; fi
            # Commits ahead of the merged head can still be on BASE under other
            # shas (a follow-up squashed/cherry-picked elsewhere): if the delta
            # oid..tip already reverse-applies to BASE, nothing was lost.
            d="$(git diff --binary "$oid" "$tip" 2>/dev/null)" || d="x"
            if [ -z "$d" ] || { [ "$d" != "x" ] && reverse_applies "$d"; }; then healthy=1; break; fi
            if [ -z "$best_k" ] || [ "$k" -lt "$best_k" ]; then best_k="$k"; best_n="$n"; fi
        else
            unknown_n="$n"
        fi
    done <<EOF
$info
EOF
    [ "$healthy" = 1 ] && return 0
    if [ -n "$best_k" ]; then
        printf 'LOST-COMMITS %s pr#%s ahead=%s\n' "$label" "$best_n" "$best_k" >> "$health_file"
    elif [ -n "$unknown_n" ]; then
        base_ahead="$(git rev-list --count "$tip" "^$BASE" 2>/dev/null)" || base_ahead=1
        [ "$base_ahead" = 0 ] && return 0
        printf 'SWEEP-ERROR %s merged PR #%s head is not present locally — cannot tell whether %s commit(s) landed\n' "$label" "$unknown_n" "$base_ahead" >> "$health_file"
    fi
    return 0
}

if [ "$HEALTH" = 1 ]; then
    if [ "$FORGE_ON" = 1 ] && [ "$FORGE_OK" != 1 ]; then
        echo "SWEEP-ERROR (forge) PR listing unavailable (gh failed, timed out or jq missing) — LOST-COMMITS check skipped" >> "$health_file"
    elif [ "$FORGE_OK" = 1 ]; then
        REMOTE_NAME="origin"
        if git rev-parse --verify -q "refs/remotes/${BASE}" >/dev/null 2>&1; then
            case "$BASE" in */*) REMOTE_NAME="${BASE%%/*}" ;; esac
        fi
        while IFS=$'\t' read -r ref tip; do
            [ -n "$ref" ] || continue
            name="${ref#refs/heads/}"
            [ "$name" = "$BASE_BARE" ] && continue
            lost_scan "$name" "$name" "$tip"
        done < <(git for-each-ref --format='%(refname)%09%(objectname)' refs/heads/)
        while IFS=$'\t' read -r ref tip; do
            [ -n "$ref" ] || continue
            name="${ref#refs/remotes/"$REMOTE_NAME"/}"
            case "$name" in HEAD|"$BASE_BARE") continue ;; esac
            # Same name and same tip as a local branch: already judged there.
            [ "$(git rev-parse -q --verify "refs/heads/$name" 2>/dev/null)" = "$tip" ] && continue
            lost_scan "$REMOTE_NAME/$name" "$name" "$tip"
        done < <(git for-each-ref --format='%(refname)%09%(objectname)' "refs/remotes/$REMOTE_NAME/")
    fi
    if [ -s "$health_file" ]; then cat "$health_file"; exit 1; fi
    exit 0
fi

# ── output ────────────────────────────────────────────────────────────────
if [ "$TSV" = 1 ]; then
    if [ -n "$CLASS_FILTER" ]; then
        awk -F'\t' -v c="$CLASS_FILTER" '$1==c' "$rows_file"
    else
        cat "$rows_file"
    fi
    exit 0
fi

n_active=$(awk -F'\t' '$1=="ACTIVE"' "$rows_file" | grep -c . || true)
n_landed=$(awk -F'\t' '$1=="LANDED-ELSEWHERE"' "$rows_file" | grep -c . || true)
n_stale=$(awk -F'\t' '$1=="STALE"' "$rows_file" | grep -c . || true)
n_unlanded=$(awk -F'\t' '$1=="UNLANDED-LIVE"' "$rows_file" | grep -c . || true)
n_aged=$(awk -F'\t' '$1=="UNLANDED-LIVE" && $5=="1"' "$rows_file" | grep -c . || true)

echo "unlanded-work: local branches ahead of $BASE"
echo "  ACTIVE=$n_active  LANDED-ELSEWHERE=$n_landed  STALE=$n_stale  UNLANDED-LIVE=$n_unlanded (aged=$n_aged)"
echo

print_class() {
    local cls="$1" label="$2"
    [ -n "$CLASS_FILTER" ] && [ "$CLASS_FILTER" != "$cls" ] && return 0
    echo "== $label =="
    local hit=0
    while IFS=$'\t' read -r c b ahead age aged ev wt; do
        [ "$c" = "$cls" ] || continue
        hit=1
        local agedtag=""
        [ "$aged" = "1" ] && agedtag=" [AGED]"
        printf '  %s (+%s, age %sh)%s — %s\n' "$b" "$ahead" "$age" "$agedtag" "${ev:-—}"
    done < "$rows_file"
    [ "$hit" = 1 ] || echo "  (none)"
    echo
}

print_class "ACTIVE" "ACTIVE — open PR exists, no action needed"

print_class "LANDED-ELSEWHERE" "LANDED-ELSEWHERE — safe to drop"
if [ -z "$CLASS_FILTER" ] || [ "$CLASS_FILTER" = "LANDED-ELSEWHERE" ]; then
    if [ "$n_landed" -gt 0 ]; then
        echo "  Drop commands:"
        while IFS=$'\t' read -r c b ahead age aged ev wt; do
            [ "$c" = "LANDED-ELSEWHERE" ] || continue
            # printf '%q' (codex-5, HIMMEL-2070 CR round 2), not a double-quoted
            # %s: a git ref name may legally contain "$(...)", backticks, or a
            # literal single/double quote (check-ref-format does not forbid any
            # of them) — a double-quoted value still expands command
            # substitution inside a shell, so a printed command copy-pasted
            # from a maliciously or accidentally named ref could execute
            # injected shell syntax. %q is bash's own shell-safe quoting.
            # No --force (codex-2, HIMMEL-2070 CR round 3): plain `git
            # worktree remove` already refuses when the worktree carries any
            # uncommitted or untracked change, so it is the operator's own
            # natural pause point before anything is discarded. --force
            # bypasses that safety check entirely -- advertising it by
            # default would make a copy-pasted "safe to drop" command able
            # to destroy real uncommitted work sitting in the worktree.
            [ -n "$wt" ] && printf '    git worktree remove %q\n' "$wt"
            printf '    git branch -D %q\n' "$b"
        done < "$rows_file"
        echo
    fi
fi

print_class "STALE" "STALE — review before dropping"
if [ -z "$CLASS_FILTER" ] || [ "$CLASS_FILTER" = "STALE" ]; then
    if [ "$n_stale" -gt 0 ]; then
        echo "  No ready-to-run destructive command here on purpose: a STALE branch"
        echo "  may carry never-landed work that merely no longer applies against main."
        echo
    fi
fi

print_class "UNLANDED-LIVE" "UNLANDED-LIVE — active work, never opened as a PR"

exit 0
