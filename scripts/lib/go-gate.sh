#!/usr/bin/env bash
# go-gate.sh — shared predicates for the HIMMEL-2919 console-GO merge gate.
#
# Extracted (HIMMEL-3142) so merge-on-green.sh and block-unresolved-cr-merge.sh
# enforce the exact same rule instead of drifting. Before this, only
# merge-on-green.sh consulted `.locks/go/` — a console-spawned leg that ran
# `gh pr merge` directly never consulted it at all, so the console's GO was
# advisory on that path (PR #798 merged with no GO file anywhere).
#
# console_leg() (HIMMEL-3149) closes the outer half: the test for whether the
# caller's session IS a console-spawned leg (HIMMEL_CONSOLE_LEG truthy) was
# hand-copied at merge-on-green.sh's _truthy(), block-unresolved-cr-merge.sh's
# gate 3, and go.sh's own inline check — byte-identical today, but nothing
# kept them that way. go_gate() below is reached only once console_leg() has
# already said yes; call console_leg() first — go_gate() does not re-check it.
#
# Both functions: sourceable from hooks and scripts, `return`-only (never
# `exit`), no `set -e` toggling. bash 3.2-safe.

# console_leg — rc 0 iff HIMMEL_CONSOLE_LEG is truthy (this process IS a
# console-spawned leg, exported by headed-arm-leg.sh). Same five falsy
# spellings every call site used before HIMMEL-3149, case-insensitive,
# whitespace-stripped: empty, 0, false, off, no — anything else is truthy.
console_leg() {
    case "$(printf '%s' "${HIMMEL_CONSOLE_LEG:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) return 1 ;;
        *) return 0 ;;
    esac
}

# go_gate <pr-num> <head-sha> <go-root> <nwo>
#   Pure: no gh call, no fs write — only a read under <go-root>/.locks/go/.
#   Callers resolve <pr-num>/<head-sha>, <go-root> (go_resolve_root()) and
#   <nwo> (HIMMEL-3578: owner/repo, so a GO minted for one repo's PR #N at a
#   given sha never validates for another repo's PR #N at the same sha)
#   themselves. A fresh gh query INSIDE this function would let the GO check
#   drift from the exact head the caller already certified — for
#   merge-on-green.sh that is the sha check-ci just certified and
#   --match-head-commit pins on the merge below — which is the TOCTOU this
#   gate exists to prevent, not a convenience worth adding.
#
#   rc 0 = the GO file <go-root>/.locks/go/<pr-num>.<head-sha> exists,
#          carries the line `head=<head-sha>` exactly, AND carries a
#          `mac=` line equal to go_mac <pr-num> <head-sha> <nwo> (HIMMEL-3543,
#          HIMMEL-3578) — the merge is bound, and bound by the console that
#          holds the GO key, to this exact repo.
#   rc 2 = refused; one-line reason on stdout naming the exact GO path, so the
#          leg (or the operator reading its output) can tell which condition
#          failed — no go-root, no file, a file for a different (stale) head,
#          no key to verify with, or a missing/invalid mac — never a generic
#          "not allowed".
go_gate() {
    local reason="" rc=0
    reason=$(_go_gate_verify "$@") || rc=$?
    # A refusal passes its reason and exit code through unchanged.
    [ "$rc" -eq 0 ] || [ -z "$reason" ] || printf '%s\n' "$reason"
    return "$rc"
}

# _go_gate_verify <pr-num> <head-sha> <go-root> <nwo> — go_gate's body. rc 0
# prints the verified trust id (empty for an ordinary GO); rc 2 prints the
# refusal. The GO file is read ONCE and head=, trust-reviewed= and mac= are all
# parsed from that one copy: a verifier that re-read it could check the mac on
# one file and take the trust id from another swapped in between (judge NO-GO
# on PR 1479). go_trust_gate takes the id from here, never from the file.
_go_gate_verify() {
    local pr_num="$1" head_sha="$2" go_root="$3" nwo="$4"
    local go_file="${go_root:-<unresolved handover root>}/.locks/go/$pr_num.$head_sha"
    local body="" want="" got="" trust=""
    if [ -n "$go_root" ]; then body=$(cat "$go_file" 2>/dev/null) || body=""; fi
    if [ -z "$go_root" ] || ! grep -qxF "head=$head_sha" <<< "$body"; then
        printf 'PR #%s at %s has no console GO (%s) — this is a console-spawned leg; send READY to your console and wait for GO; a GO for an older head is stale, never reuse it.\n' "$pr_num" "$head_sha" "$go_file"
        return 2
    fi
    # HIMMEL-3895: a trust-reviewed GO signs its reviewer id too (go_mac's 4th
    # arg), so verify whichever form the file carries — a trust line added to an
    # ordinary GO, or edited in a trust GO, verifies as neither.
    trust=$(printf '%s\n' "$body" | sed -n 's/^trust-reviewed=//p' | head -n 1)
    if ! want=$(go_mac "$pr_num" "$head_sha" "$nwo" "$trust"); then
        printf 'PR #%s at %s: cannot verify the console GO (%s) — no readable GO key at %s, or openssl is missing; send BLOCKED to your console (the console re-runs go.sh, which mints the key).\n' "$pr_num" "$head_sha" "$go_file" "$(go_key_file)"
        return 2
    fi
    got=$(printf '%s\n' "$body" | sed -n 's/^mac=//p' | head -n 1)
    if [ -z "$got" ] || [ "$got" != "$want" ]; then
        printf 'PR #%s at %s: the GO file (%s) has no/invalid mac — not written by the console'"'"'s go.sh (or written before HIMMEL-3543); send BLOCKED to your console: the console re-runs go.sh %s %s.\n' "$pr_num" "$head_sha" "$go_file" "$pr_num" "$head_sha"
        return 2
    fi
    printf '%s\n' "$trust"
}

# go_trust_id_ok <id> — rc 0 iff <id> is a well-formed trust-reviewer id:
# 1-128 of [A-Za-z0-9._:-]. Shared by go.sh (what it will sign) and
# go_trust_gate (what it will accept), so the two cannot drift.
go_trust_id_ok() {
    case "$1" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
    [ "${#1}" -le 128 ]
}

# go_trust_gate <pr-num> <head-sha> <go-root> <nwo> — HIMMEL-3895. rc 0 iff
# go_gate passes AND the GO is trust-reviewed (a well-formed trust-reviewed=
# id, covered by the verified mac); the id on stdout. rc 2 = refused, the
# reason on stdout. A merge touching a trust path (scripts/ci/ci-trust-paths.txt)
# needs this, for a console leg and the operator path alike.
go_trust_gate() {
    local pr_num="$1" head_sha="$2" go_root="$3" nwo="$4" reason="" trust=""
    local go_file="${go_root:-<unresolved handover root>}/.locks/go/$pr_num.$head_sha"
    if ! trust=$(_go_gate_verify "$pr_num" "$head_sha" "$go_root" "$nwo"); then
        reason=$trust
        printf '%s\n' "${reason:-PR #$pr_num at $head_sha: no valid console GO ($go_file)}"
        return 2
    fi
    if ! go_trust_id_ok "$trust"; then
        printf 'PR #%s at %s touches a CI trust path, and its GO (%s) is not trust-reviewed — an independent judge must review the trust-path change; send READY to your console, which grants it with go.sh --trust-reviewed <reviewer-id> %s %s.\n' "$pr_num" "$head_sha" "$go_file" "$pr_num" "$head_sha"
        return 2
    fi
    printf '%s\n' "$trust"
}

# go_verdict_scope <anchor> — HIMMEL-4589. The `<user>/<bucket>` a trust verdict
# for the repo at <anchor> may live under: <user> = user_slug (USER_SLUG from the
# env, else the anchor's .env, else the forge login), <bucket> = the slugified
# basename of the anchor's PRIMARY checkout (the parent of its git-common-dir, so
# a linked worktree names its repo, not its own directory) — the same bucket
# convention console.sh derives. Both must be a plain path segment
# ([A-Za-z0-9][A-Za-z0-9._-]*, no `..`); anything unresolved prints nothing and
# returns 1 (fail closed — never a glob over every bucket). Read-only.
go_verdict_scope() (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES
    local here slug common reponame bucket seg
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
    # shellcheck source=scripts/lib/load-dotenv.sh
    # shellcheck disable=SC1091
    . "$here/load-dotenv.sh" 2>/dev/null || exit 1
    # shellcheck source=scripts/lib/user-slug.sh
    # shellcheck disable=SC1091
    . "$here/user-slug.sh" 2>/dev/null || exit 1
    load_dotenv --root "$1" USER_SLUG >/dev/null 2>&1 || true
    slug=$(user_slug 2>/dev/null) || exit 1
    common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 1
    reponame=$(basename "$(dirname "$common")")
    bucket=$(printf '%s' "$reponame" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
    for seg in "$slug" "$bucket"; do
        case "$seg" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*|*..*) exit 1 ;; esac
    done
    printf '%s/%s' "$slug" "$bucket"
)

# go_trust_verdict <go-root> <qid> <head-sha> <anchor> <pr> — HIMMEL-3832. Before
# go.sh signs a trust-reviewed GO, the judge it names must have ruled GO on that
# exact head. The verdict line is the first non-blank line under the `## Verdict`
# heading (docs/handover/verdict-template.md), and it parses only as exactly
#     **GO** for head `<40-hex sha>`   or   **NO-GO** for head `<40-hex sha>`
# (one trailing full stop allowed). rc 0 iff <qid> is a path segment
# ([A-Za-z0-9][A-Za-z0-9._-]*, so never `..` or a `/`), and across every *.md
# in <go-root>/<user>/<bucket>/verdicts/<qid>/ — ONLY the scope go_verdict_scope
# resolves for <anchor> (HIMMEL-4589: another user's or repo's verdict dir, which
# a judge there can write for any qid, never counts; an unresolved scope refuses)
# — no file is unparsed, none is NO-GO for <head-sha>, and at least one is GO for
# <head-sha>. A verdict for another head is ignored (an earlier round). Fail
# closed: a GO naming no head, trailing text, or no verdict line refuses. rc 2 =
# refused, the reason on stdout. Read-only.
# HIMMEL-4928: a GO for <head-sha> also names its PR. write-verdict.sh writes
# `pr: <n>` as the second line after the verdict line (the line review-round.sh
# does not read), and the GO counts only when <n> equals <pr>: two PRs on one
# head are told apart, and a verdict file with no pr: line (written before this
# field existed) refuses, to be rewritten with write-verdict.sh --pr. A NO-GO
# vetoes whatever PR it names (it only narrows). An empty <pr> refuses.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
go_trust_verdict() {
    local root="$1" qid="$2" sha="$3" anchor="${4:-}" pr="${5:-}" f line word head go=0 scope vpr name snap
    case "$qid" in
        [A-Za-z0-9]*) ;;
        *) qid="" ;;
    esac
    case "$qid" in *[!A-Za-z0-9._-]*) qid="" ;; esac
    if [ -z "$qid" ]; then
        printf 'the trust id '"'"'%s'"'"' is not a judge qid ([A-Za-z0-9][A-Za-z0-9._-]*), so it names no verdicts/<qid>/ directory — pass the qid of the judge that ruled GO on this head.\n' "$2"
        return 2
    fi
    if [ -z "$anchor" ] || ! scope=$(go_verdict_scope "$anchor"); then
        printf 'cannot resolve this repo'"'"'s <user>/<bucket> verdict scope (USER_SLUG, or the primary checkout of '"'"'%s'"'"') — refusing rather than read every bucket'"'"'s verdicts/%s/.\n' "$anchor" "$qid"
        return 2
    fi
    case "$pr" in
        ''|0*|*[!0-9]*)
            printf 'no PR number was given (got '"'"'%s'"'"'), so no verdict can be matched to a PR.\n' "$pr"
            return 2 ;;
    esac
    for f in "$root/$scope/verdicts/$qid"/*.md; do
        [ -f "$f" ] || continue
        # HIMMEL-4984: one read; the mac, the scope check and every field come from it.
        go_verdict_snapshot "$f" || continue
        snap=$GO_VERDICT_SNAP
        line=$(printf '%s' "$snap" | tr -d '\r' | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF { print; exit }')
        word=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `[0-9a-f]{40}`\.?$/\1/p')
        head=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\2/p')
        if [ -z "$word" ] || [ -z "$head" ]; then
            printf 'the verdict in %s does not parse (first line under ## Verdict: '"'"'%s'"'"'; expected **GO** for head `<sha>`) — refusing rather than guess.\n' "$f" "$line"
            return 2
        fi
        [ "$head" = "$sha" ] || continue
        if [ "$word" != "GO" ]; then
            printf 'the verdict in %s is NO-GO for head %s.\n' "$f" "$sha"
            return 2
        fi
        # HIMMEL-4984: a GO counts only when write-verdict.sh signed it, and a
        # post-cap scope record (delta-scope:) is round-admission evidence,
        # never merge trust.
        name=${f##*/}; name=${name%.md}
        if ! go_verdict_mac_ok_text "$snap" "$scope" "$qid" "$name"; then
            printf 'the verdict in %s carries no valid mac (HIMMEL-4984) — only a record written by write-verdict.sh counts; the judge rewrites it.\n' "$f"
            return 2
        fi
        if printf '%s' "$snap" | grep -qE '^delta-(scope|from): '; then
            printf 'the verdict in %s is a post-cap scope record (delta-scope:/delta-from:), not merge trust (HIMMEL-4984) — pass the qid of a judge that ruled GO on the PR itself.\n' "$f"
            return 2
        fi
        vpr=$(printf '%s' "$snap" | tr -d '\r' | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF && !n { n = NR + 2; next } n && NR == n { print; exit }' \
            | sed -nE 's/^pr: ([1-9][0-9]*)$/\1/p')
        if [ -z "$vpr" ]; then
            printf 'the verdict in %s names no PR (no pr: line after the verdict line) — the judge rewrites it with write-verdict.sh --pr %s.\n' "$f" "$pr"
            return 2
        fi
        if [ "$vpr" != "$pr" ]; then
            printf 'the verdict in %s names PR #%s, not PR #%s.\n' "$f" "$vpr" "$pr"
            return 2
        fi
        go=1
    done
    if [ "$go" -ne 1 ]; then
        printf 'no verdict under %s/%s/verdicts/%s/ rules **GO** for head `%s` — the judge writes that verdict before a trust-reviewed GO.\n' "$root" "$scope" "$qid" "$sha"
        return 2
    fi
}

# trust_path_check <nwo> <pr-num> <head-sha> <default-branch> <anchor> —
# HIMMEL-3910. Does PR <pr-num> touch a CI trust path? Moved out of
# merge-on-green.sh (HIMMEL-3895) so block-unresolved-cr-merge.sh asks the
# exact same question: a direct `gh pr merge` used to pass a trust-path PR on
# an ordinary GO. Every fail-closed case below is merge-on-green's, unchanged.
#   - The list comes from the DEFAULT branch through the API, never the PR head,
#     a worktree or a local ref (all branch-controlled), so a PR editing it is
#     judged by the list it would replace. Unreadable, empty or invalid →
#     refuse. A 404 refuses unless the anchor's origin URL positively names a
#     different github.com repo, where it means the gate is not adopted there;
#     an unresolvable identity refuses.
#   - The file list is the REST listing, paginated (renames' old names
#     included), and must account for every one of the PR's changed_files (the
#     endpoint stops at 3000), with the PR head re-read on both sides of it
#     equal to <head-sha>.
#   - On a match, <anchor> must contain origin's HEAD: a stale anchor runs a
#     stale gate.
# rc 0 prints one line: `none`, `not-adopted`, or `hit <first matching path>`.
# rc 2 prints `<phase> <reason>` (phase: tmp, list, files or anchor) — refused.
# gh is ${GH:-gh}. The body is a subshell, so its temp-file trap, its helper
# and its `exit`s never reach the sourcing caller.
trust_path_check() (
    tp_nwo=$1 tp_pr=$2 tp_sha=$3 tp_branch=$4 anchor=$5 gh_bin=${GH:-gh}
    # HIMMEL-3570 scrub: `git -C "$anchor"` below must read the anchor, not an
    # inherited GIT_DIR. Subshell body, so the caller's env is untouched.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    refuse() { printf '%s %s\n' "$1" "$2"; exit 2; }
    # other_repo — rc 0 only when the anchor's origin POSITIVELY names a
    # github.com repo other than $tp_nwo. An unreadable origin, an SSH host alias
    # or any non-github.com URL cannot prove the PR is on another repo, so it
    # is not "other" and a 404 refuses (fail closed). So can a non-canonical
    # $tp_nwo (a `github.com/o/r` spelling that itself 404s): only a bare
    # owner/name is ever compared.
    other_repo() {
        local url
        case "$tp_nwo" in ''|*/*/*|*[!A-Za-z0-9._/-]*) return 1 ;; */*) ;; *) return 1 ;; esac
        url=$(git -C "$anchor" config --get remote.origin.url 2>/dev/null) || return 1
        url=${url%/}; url=${url%.git}
        case "$url" in
            https://github.com/*) url=${url#https://github.com/} ;;
            ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
            git@github.com:*) url=${url#git@github.com:} ;;
            *) return 1 ;;
        esac
        case "$url" in ''|*/*/*|*[!A-Za-z0-9._/-]*) return 1 ;; */*) ;; *) return 1 ;; esac
        [ "$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$tp_nwo" | tr '[:upper:]' '[:lower:]')" ]
    }
    tmp=$(mktemp "${TMPDIR:-/tmp}/mog-trust.XXXXXX") || refuse tmp "cannot create a temp file"
    trap 'rm -f "$tmp"' EXIT
    rc=0
    raw=$("$gh_bin" api "repos/$tp_nwo/contents/scripts/ci/ci-trust-paths.txt?ref=$tp_branch" \
        -H 'Accept: application/vnd.github.raw' 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$raw" in
            *"HTTP 404"*)
                other_repo || refuse list "scripts/ci/ci-trust-paths.txt is missing on $tp_nwo@$tp_branch, and the harness anchor's origin does not prove it is another repo"
                printf 'not-adopted\n'
                exit 0 ;;
            *) refuse list "cannot read scripts/ci/ci-trust-paths.txt from $tp_nwo@$tp_branch (gh exit $rc)" ;;
        esac
    fi
    # Strip \r and surrounding blanks first: a pattern carrying either matches
    # no path, and an unmatched pattern fails open.
    printf '%s\n' "$raw" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -Ev '^(#|$)' > "$tmp"
    [ -s "$tmp" ] || refuse list "scripts/ci/ci-trust-paths.txt on $tp_branch has no patterns"
    grep -E -f "$tmp" </dev/null >/dev/null 2>&1
    [ "$?" -eq 2 ] && refuse list "scripts/ci/ci-trust-paths.txt on $tp_branch has an invalid pattern"
    pr_jq='"\(.head.sha)|\(.changed_files)"'
    meta=$("$gh_bin" api "repos/$tp_nwo/pulls/$tp_pr" --jq "$pr_jq" 2>/dev/null) \
        || refuse files "cannot read PR #$tp_pr's head and changed-file count"
    [ "${meta%%|*}" = "$tp_sha" ] || refuse files "PR #$tp_pr's head is ${meta%%|*}, not the certified $tp_sha"
    count=${meta#*|}
    case "$count" in ''|*[!0-9]*) refuse files "PR #$tp_pr's changed-file count is unreadable" ;; esac
    files=$("$gh_bin" api "repos/$tp_nwo/pulls/$tp_pr/files" --paginate \
        --jq '.[] | [.filename, (.previous_filename // "")] | @tsv' 2>/dev/null) \
        || refuse files "cannot list PR #$tp_pr's changed files"
    listed=0
    [ -n "$files" ] && listed=$(printf '%s\n' "$files" | wc -l | tr -d ' ')
    [ "$listed" -eq "$count" ] \
        || refuse files "listed $listed of PR #$tp_pr's $count changed files (the listing stops at 3000)"
    meta=$("$gh_bin" api "repos/$tp_nwo/pulls/$tp_pr" --jq "$pr_jq" 2>/dev/null) || meta=""
    [ "${meta%%|*}" = "$tp_sha" ] || refuse files "PR #$tp_pr's head moved while its files were listed"
    hit=$(printf '%s\n' "$files" | tr '\t' '\n' | grep -v '^$' | grep -E -f "$tmp" | head -n 1)
    if [ -z "$hit" ]; then
        printf 'none\n'
        exit 0
    fi
    tip=$(unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES
        GIT_TERMINAL_PROMPT=0 git -C "$anchor" ls-remote origin HEAD 2>/dev/null | awk 'NR==1{print $1}')
    if [ -z "$tip" ] || ! (unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES
            git -C "$anchor" merge-base --is-ancestor "$tip" HEAD 2>/dev/null); then
        refuse anchor "PR #$tp_pr touches trust path $hit and the anchor $anchor is behind origin (or origin is unreadable) — pull the primary checkout, then re-run"
    fi
    printf 'hit %s\n' "$hit"
)

# --- HIMMEL-3543/HIMMEL-3578: GO authentication ------------------------------
# A GO used to be the mere existence of a file with a head= line, so any
# process able to write the handover root (a console-spawned leg included)
# could forge its own. go.sh now signs "himmel-go-v2|<nwo>|<pr>|<sha>" with
# HMAC-SHA256 under a key only go.sh mints (the console's zero-`!` path: it
# creates the key on first use, mode 0600); go_gate verifies the mac and never
# creates a key. The key's *.key name puts it under block-read-secrets (a
# leg's cat/Read/Grep of it is hook-denied), and it sits outside every leg's
# additionalDirectories grant.
# ponytail: same-uid ceiling — legs run as the console's Unix user, so a leg
# that deliberately evades can still (1) write a helper script that reads the
# key indirectly, (2) run go.sh under `env -u HIMMEL_CONSOLE_LEG`, (3) re-point
# the verifier with a HOME= prefix, (4) overwrite the key (no hook denies a
# Write to ~/.config/himmel/go-hmac.key), or (5) plant a key before the
# console's first GO (go.sh only tests -e, not owner or mode) — each a
# deliberate evasion the classifier sees, not an accidental two-line write,
# upgrade path: a separate-uid or OS-keyring signer (HIMMEL-3578).

# go_key_file — path of the console's GO signing key.
go_key_file() {
    printf '%s/.config/himmel/go-hmac.key\n' "${HOME:-}"
}

# go_mac <pr-num> <head-sha> <nwo> — HMAC-SHA256(key,
# "himmel-go-v2|<nwo>|<pr>|<sha>") as 64 lowercase hex on stdout. rc 1 (nothing
# printed) when HOME is unset, <nwo> is empty (HIMMEL-3578: a mac with no repo
# bound would validate against any repo — fail closed instead), the key is
# missing/unreadable/not 64 hex, or openssl is absent. The key is read with the
# `read` builtin and reaches openssl on stdin only — never argv, where any
# user's `ps` could see it. HMAC is built by hand (RFC 2104) because openssl's
# own HMAC takes its key on argv. The v1→v2 domain-tag bump means a GO minted
# before HIMMEL-3578 fails this verification by construction — it must be
# re-minted once. HIMMEL-3895: an optional 4th arg <trust-id> switches to the
# separate domain tag "himmel-go-trust-v1|<nwo>|<pr>|<sha>|<trust-id>", so a
# trust-reviewed mac never verifies as an ordinary one, nor the reverse.
go_mac() {
    local nwo="$3"
    [ -n "$nwo" ] || return 1
    if [ -n "${4:-}" ]; then
        go_msg_mac himmel-go-trust-v1 "$nwo|$1|$2|$4"
    else
        go_msg_mac himmel-go-v2 "$nwo|$1|$2"
    fi
}

# go_msg_mac <domain> <msg> — HIMMEL-4984: HMAC-SHA256(key, "<domain>|<msg>") as
# 64 lowercase hex on stdout, the body go_mac signs with. The domain tag keeps
# every use apart: himmel-go-v2 / himmel-go-trust-v1 are go_mac's, and
# himmel-verdict-v1 signs a write-verdict.sh record, so a verdict mac is never
# valid as a GO mac or the reverse. rc 1 (nothing printed) on an empty domain or
# message, no HOME, or the key missing/unreadable/not 64 hex, or no openssl.
go_msg_mac() {
    local key="" kfile i b hx ipad="" opad="" inner="" msg
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
    msg="$1|$2"
    [ -n "${HOME:-}" ] || return 1
    kfile=$(go_key_file)
    [ -f "$kfile" ] && [ -r "$kfile" ] || return 1
    IFS= read -r key < "$kfile" || [ -n "$key" ] || return 1
    case "$key" in ''|*[!0123456789abcdef]*) return 1 ;; esac
    [ "${#key}" -eq 64 ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1
    # Zero-pad the 32-byte key to SHA-256's 64-byte block, then XOR each byte
    # with the inner (0x36) and outer (0x5c) pads, as printf \x escapes.
    key="${key}$(printf '%064d' 0)"
    i=0
    while [ "$i" -lt 128 ]; do
        b=$((16#${key:$i:2}))
        printf -v hx '\\x%02x' $((b ^ 0x36)); ipad="$ipad$hx"
        printf -v hx '\\x%02x' $((b ^ 0x5c)); opad="$opad$hx"
        i=$((i + 2))
    done
    # shellcheck disable=SC2059  # the format IS the \x-escaped pad bytes
    inner=$({ printf "$ipad"; printf '%s' "$msg"; } \
        | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')
    [ "${#inner}" -eq 64 ] || return 1
    inner=$(printf '%s' "$inner" | sed 's/../\\x&/g')
    # shellcheck disable=SC2059  # as above: \x-escaped digest bytes
    inner=$({ printf "$opad"; printf "$inner"; } \
        | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')
    [ "${#inner}" -eq 64 ] || return 1
    printf '%s\n' "$inner"
}

# --- HIMMEL-4984: verdict records are signed with the GO key ------------------
# write-verdict.sh ends every record with `mac: <64 hex>`: go_msg_mac under the
# himmel-verdict-v1 domain over "<user>/<bucket>|<qid>|<name>|<sha256 of every
# byte above the mac line>". The record's own path (scope, qid, name) is in the
# message, so a record copied to another qid, name or repo bucket fails, and the
# body hash covers the verdict, head, pr, branch, class, layer-decision and every
# evidence byte. Consumers (review-round.sh's scope and NO-GO paths,
# go_trust_verdict) verify with go_verdict_mac_ok; a record without a valid mac
# buys nothing.
# ponytail: same-uid ceiling - the key sits in the operator's HOME like the GO
# key, so a same-uid process that reads it can sign; the upgrade path is a
# separate-uid or keyring signer (HIMMEL-3578).

# _go_sha256 — sha256 of stdin as 64 lowercase hex.
_go_sha256() {
    local h
    h=$({ sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || openssl dgst -sha256 -r 2>/dev/null; } | awk '{print $1}') || return 1
    case "$h" in ''|*[!0123456789abcdef]*) return 1 ;; esac
    [ "${#h}" -eq 64 ] || return 1
    printf '%s\n' "$h"
}

# go_verdict_mac <scope> <qid> <name> — the mac for the record body on stdin.
go_verdict_mac() {
    local hash
    hash=$(_go_sha256) || return 1
    go_msg_mac himmel-verdict-v1 "$1|$2|$3|$hash"
}

# go_verdict_mac_ok <file> <scope> <qid> <name> — rc 0 iff the file's last line is
# `mac: <64 hex>` and equals the mac of every line above it.
go_verdict_mac_ok() {
    go_verdict_snapshot "$1" || return 1
    go_verdict_mac_ok_text "$GO_VERDICT_SNAP" "$2" "$3" "$4"
}

# go_verdict_snapshot <file> — HIMMEL-4984: read the record's bytes ONCE into
# GO_VERDICT_SNAP (a trailing sentinel keeps the final newline). A caller
# verifies the mac and parses its fields from this one copy, so a rewrite
# between the two reads cannot make a verified mac vouch for different bytes.
go_verdict_snapshot() {
    GO_VERDICT_SNAP=$(cat "$1" 2>/dev/null; printf x) || return 1
    GO_VERDICT_SNAP=${GO_VERDICT_SNAP%x}
    [ -n "$GO_VERDICT_SNAP" ]
}

# go_verdict_mac_ok_text <snapshot> <scope> <qid> <name> — go_verdict_mac_ok over
# bytes already read.
go_verdict_mac_ok_text() {
    local got want
    got=$(printf '%s' "$1" | tail -n 1 | tr -d '\r')
    case "$got" in 'mac: '*) got=${got#mac: } ;; *) return 1 ;; esac
    case "$got" in ''|*[!0123456789abcdef]*) return 1 ;; esac
    [ "${#got}" -eq 64 ] || return 1
    want=$(printf '%s' "$1" | sed '$d' | go_verdict_mac "$2" "$3" "$4") || return 1
    [ -n "$want" ] && [ "$got" = "$want" ]
}

# --- HIMMEL-3572 row 1: one root for the GO writer and the gate --------------
# go.sh and merge-on-green.sh run in different processes (the console, the
# leg) whose HANDOVER_DIR can disagree: a console armed with a clean env had
# none, fell back to the harness repo's inline handovers/ stub, and wrote an
# rc=0 GO the leg's gate (reading the .env-configured root) never saw. Both
# sides resolve through go_resolve_root so an env that is empty OR names the
# harness repo's own stub yields the root the anchor's .env configures.

# _go_in_harness <path> <anchor> — rc 0 iff <path> lies inside the anchor's
# own git repository (any worktree of it): the harness's inline stub.
# HIMMEL-3570: an inherited GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR/GIT_INDEX_FILE
# overrides `-C`, so a caller's env — not the path we were given — would pick
# the repo rev-parse answers about, which is exactly the GO root this
# function decides. HIMMEL-3572 round 2: GIT_CEILING_DIRECTORIES joins the
# scrub too — exporting it at the repo's top directory stops `-C` from
# discovering ANY repo above it, flipping this rc 0 -> 1 (reproduced: the
# HIMMEL-3572 split-root shape). unset scrubs each call's own subshell only,
# so a sourcing caller's env is never mutated.
_go_in_harness() {
    local a b
    a=$(
        unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES
        git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
    ) || return 1
    b=$(
        unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CEILING_DIRECTORIES
        git -C "$2" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
    ) || return 1
    [ -n "$a" ] && [ "$a" = "$b" ]
}

# go_resolve_root <anchor> — print the GO root, rc 0; rc 2 when unresolvable.
# Requires handover_root (scripts/lib/handover-path.sh) already in scope.
#   1. a live HANDOVER_DIR outside the harness repo  → it (explicit, unchanged)
#   2. else the anchor's .env HANDOVER_DIR           → it (must be a directory;
#      a configured root that is gone fails rc 2 — never a stub fallback)
#   3. else handover_root as before (Mode A: the inline default is the root)
go_resolve_root() {
    local anchor="$1" live="${HANDOVER_DIR:-}" cfg=""
    if [ -n "$live" ] && ! _go_in_harness "$live" "$anchor"; then
        handover_root
        return
    fi
    cfg=$(
        unset HANDOVER_DIR
        # shellcheck source=scripts/lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$anchor/scripts/lib/load-dotenv.sh" >/dev/null 2>&1 || exit 0
        load_dotenv --root "$(_load_dotenv_primary_for "$anchor" 2>/dev/null)" HANDOVER_DIR >/dev/null 2>&1
        printf '%s' "${HANDOVER_DIR:-}"
    )
    if [ -n "$cfg" ]; then
        ( HANDOVER_DIR="$cfg"; handover_root )
        return
    fi
    handover_root
}
