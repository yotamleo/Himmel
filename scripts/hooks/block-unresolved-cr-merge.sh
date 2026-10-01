#!/usr/bin/env bash
# PreToolUse hook: block-unresolved-cr-merge.sh
#
# Blocks `gh pr merge` on FOUR independent gates, run in order:
#   1. CR gate (HIMMEL-936): unresolved CodeRabbit review threads or a
#      CodeRabbit check-run still running on the head SHA (except a proven old
#      zombie backed by success status + zero unresolved threads, HIMMEL-980;
#      operator rule 2026-07-11: never merge over unresolved CodeRabbit remarks).
#   2. CI-green gate (HIMMEL-1043): the PR's head SHA must have green overall
#      CI — no failing/pending check-run, no failing/pending combined status.
#      This repo has NO branch protection, so GitHub will not otherwise block a
#      merge over red/pending CI (operator rule: "ready to merge" requires green).
#   3. Console-GO gate (HIMMEL-2919/HIMMEL-3142): when this is a console-spawned
#      leg (HIMMEL_CONSOLE_LEG truthy, exported by headed-arm-leg.sh), the PR's
#      head SHA must have a matching GO file under the handover root's
#      `.locks/go/` (console-kit/go.sh writes it — "the file IS the GO"). Before
#      this gate existed, a leg merging via `gh pr merge` directly (instead of
#      merge-on-green.sh) never consulted `.locks/go/` at all, so the GO was
#      advisory rather than binding on that path (PR #798). No bypass env var —
#      same as merge-on-green.sh's own console-GO gate, which this one shares
#      its predicate with (scripts/lib/go-gate.sh) so the two cannot drift.
#      Untouched for a non-leg session (HIMMEL_CONSOLE_LEG unset/falsy skips it
#      whole).
#   4. CI trust-path gate (HIMMEL-3910): for EVERY session, a PR touching a CI
#      trust path (scripts/ci/ci-trust-paths.txt on the default branch) needs a
#      trust-reviewed console GO (go.sh --trust-reviewed) and a merge pinned
#      to its head — merge-on-green.sh's rule (HIMMEL-3895), asked through the
#      same trust_path_check in scripts/lib/go-gate.sh. Fails closed.
# Sibling of check-cr-marker-on-pr-create.sh / block-merged-pr-commit.sh.
#
# Exit: 0 allow (incl. every fail-open path), 2 block (stderr shown to model).
# HIMMEL-3915: the PR lookup itself (bounded `gh pr view`) fails CLOSED on a
# real merge; the CR/CI gates' own API errors stay fail-open (HIMMEL-936).
# Bypass: CR_MERGE_GATE_OK=1 and/or CI_MERGE_GATE_OK=1 in the LAUNCHING shell
# (each gates its own check independently). CR_PROFILE=none skips the CR gate.
# The console-GO and trust-path gates have no bypass (see gates 3 and 4 above).
set -uo pipefail
# NOT set -e: fail-open hook, must never abort on a sub-call's rc 1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The CR-gate bypasses (CR_MERGE_GATE_OK=1 / CR_PROFILE=none) are handled
# INSIDE cr_merge_gate (self-bypass → rc 0), NOT with an early exit here — an
# early `exit 0` would also skip the independent CI-green gate below, letting a
# red/pending-CI merge through whenever a CR bypass is set (CodeRabbit, #1230).
# The CI gate has its OWN bypass (CI_MERGE_GATE_OK=1) inside ci_green_gate. So
# both gates are always reached; each self-bypasses its own check.
command -v jq >/dev/null 2>&1 || exit 0   # cannot parse stdin: fail open

payload=$(cat) || exit 0

# Fast path: skip the jq spawn unless the raw payload could contain a merge.
# Deliberately LOOSE (`merge` anywhere, not the exact phrase): a double-spaced
# `gh  pr  merge` must NOT dodge the gate via the fast path (plan-critic #2);
# non-merge commands mentioning "merge" fall through to the cheap regex below.
case "$payload" in
    # A JSON backslash may split the word (`mer\ge`): let jq and the normalized
    # detector below decide instead of skipping.
    # HIMMEL-3929: so may an expansion (`m${X}erge`, a backtick pair).
    # A glob word can spell the verb (`m?rge`).
    *merge*|*\\*|*\'*|*\$*|*\`*|*\**|*\?*|*\[*) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
cmd=$(printf '%s' "$cmd" | tr -d '\r')
[ -z "$cmd" ] && exit 0

_deny() { echo "block-unresolved-cr-merge: $1" >&2; exit 2; }

# HIMMEL-3918: ONE structural rule instead of a grammar. Every parse rule this
# hook grew for a chained, redirected, prefixed or quoted merge (HIMMEL-3915,
# then more /pr-check rounds of the same class) became a hook-vs-bash
# disagreement and so a bypass. A command that names `gh pr merge` must BE a
# single plain command whose RAW text is only [A-Za-z0-9], space and _ . / : = - ,
# - no quote of any kind, $, backslash, #, newline or metacharacter - and whose
# first word is literally `gh` (which also covers every env/command/exec/nohup/
# time/NAME=value prefix and cd/pushd/popd). With no quotes the tokenizer below
# needs no quote-stripping, so the hook and bash always read the same words.
# Accepted over-denies (HIMMEL-3917 precedent): ANY text mention of `gh pr
# merge` that is not a plain merge (`git commit -m "gh pr merge"`, `echo gh pr
# merge`), a custom --subject/--body (use scripts/handover/merge-on-green.sh),
# and a path-qualified `/usr/bin/gh`.
# HIMMEL-3929: the detector is DENY-LEANING instead of a text regexp for one
# spelling. It fires on a `gh` word (command position, or after a wrapper/
# separator, or a /path/to/gh) followed anywhere by `merge` in a NORMALIZED
# copy of the text (backslash-newline pairs removed, then every backslash,
# quote, $, brace and backtick, newlines to spaces: bash joins `gh pr mer\<nl>ge`
# and reads `mer''ge`, `{merge,8}`, `${IFS}` and an empty backtick pair as
# `merge`). A second copy has `${..}`/`$(..)` dropped first (`m${X}erge`). Once
# it fires, the raw-char allowlist below refuses every expansion spelling and the
# command must parse as exactly `gh [-R v]* pr [-R v]* merge <closed tokens>`:
# `gh api .../merge`, `gh alias set mm "pr merge"`, `bash -c`, `eval`, a prefix or
# any other flag placement DENIES. No per-spelling grammar to drift.
_norm() {
    printf '%s' "$1" | sed -e ':a' -e '$!N' -e '$!ba' -e 's/\\\n//g' -e 's/\\//g' -e "s/['\"\$\`{}]//g" | tr '\n' ' '
}
# The ONE dequote every added rule shares: strip quotes AND backslashes from the
# word stream (`"gh"`, `\gh`, `g\h`, `"m?rge"` all become the bare word).
_dq() { tr -d "'\"\\\\"; }
# Monotone versus main: main's own detector runs byte for byte and every rule
# below only ADDS a deny, so nothing main denied can pass (judge r1, C1).
merge_re='gh[[:space:]]+pr[[:space:]]+merge'
cmd_old=$(printf '%s' "$cmd" | sed -e ':a' -e '$!N' -e '$!ba' -e 's/\\\n//g' -e 's/\\//g' -e "s/['\"\$]//g" | tr '\n' ' ')
fires=0
printf '%s' "$cmd_old" | grep -E "$merge_re" >/dev/null && fires=1
cmd_norm=$(_norm "$cmd")
cmd_sq=$(_norm "$(printf '%s' "$cmd" | sed -e 's/\$[{(][^})]*[})]//g')")
# Whole-command substring rule, ignoring segmentation: the GraphQL mutation name is
# never legitimate in a read, so `mergepullrequest` anywhere (dequoted, lowercased)
# denies, whatever `(` or `;` splits around it.
printf '%s' "$cmd_norm" | tr '[:upper:]' '[:lower:]' | grep -q 'mergepullrequest' && fires=1
# Rule A, per segment: gh, then only flags (-R/--repo take a value) and ONE `pr`,
# then a `merge` word; or `gh api` / `gh alias` followed by a merge-ish word
# (`.../pulls/8/merge`, `mutation{mergePullRequest`, `alias set mm pr merge`).
# `gh pr view`, `gh pr list --search "merge conflict"`, `gh pr diff | grep merge`
# never reach a merge word here.
for _n in "$cmd_norm" "$cmd_sq"; do
    # shellcheck disable=SC2020 # four separators each map to a newline, by design
    printf '%s' "$_n" | tr ';&|(' '\n\n\n\n' | awk '{ g = 0; pr = 0; skip = 0; api = 0; al = 0
        for (i = 1; i <= NF; i++) { w = $i
            if (!g) { if (w == "gh" || w ~ "/gh$") g = 1; continue }
            if (skip) { skip = 0; continue }
            if (w ~ "^-") { if (w == "-R" || w == "--repo") skip = 1; if ((api || al) && w ~ "merge") f = 1; continue }
            if (pr && w ~ "^merge([^A-Za-z0-9]|$|PullRequest)") f = 1
            if (api || al) { if (w ~ "merge") f = 1; continue }
            if (w == "pr") { pr = 1; continue }
            if (pr) { g = 0; pr = 0; continue }
            if (w ~ "^merge([^A-Za-z0-9]|$|PullRequest)") f = 1
            if (w == "api") api = 1; else if (w == "alias") al = 1; else g = 0 } }
        END { exit !f }' && fires=1
done
# Expansion-built verbs, scoped to a segment that has a gh word, a `$`/backtick
# AND a merge-ish word (a literal merge word in any copy, or a word whose literal
# residue is letters of `merge`: `m${X:-er}ge`, `$'m\x65rge'`). A non-merge gh
# command (`gh pr view "$PR"`) never fires.
if [ "$fires" = "0" ]; then
    # shellcheck disable=SC2020,SC2016 # five separators map to newlines; the sed pattern is literal
    printf '%s' "$cmd" | sed -e ':a' -e '$!N' -e '$!ba' -e 's/\\\n//g' -e 's/\$(/$ /g' | tr ';&|(\n' '\n\n\n\n\n' \
        | awk -v q="'" 'function res(w,  t) { t = w; gsub("[$]" q, "", t)
                gsub(/\\x[0-9a-fA-F]+|\\u[0-9a-fA-F]+|\\[0-7]+/, "", t)
                gsub(/[$][{][^}]*[}]/, "", t); gsub(/[$][A-Za-z_][A-Za-z0-9_]*/, "", t)
                gsub("[$`{}\\\\\"" q "]", "", t); return t }
            { g = 0; d = 0; m = 0
            for (i = 1; i <= NF; i++) { w = $i; s = w; gsub("[\"" q "]", "", s)
                if (s == "gh" || s ~ "/gh$") g = 1
                if (w ~ /[$`]/) d = 1
                t1 = w; gsub("[$`{}\\\\\"" q "]", "", t1)
                t2 = w; gsub(/[$][{][^}]*[}]/, " ", t2); gsub("[$`{}\\\\\"" q "]", " ", t2)
                n = split(t2, a, " "); for (j = 1; j <= n; j++) if (a[j] == "gh" || a[j] ~ "/gh$") g = 1
                r = res(w)
                if (t1 ~ "(^|[^A-Za-z0-9])merge([^A-Za-z0-9]|$|PullRequest)" || t2 ~ "(^|[^A-Za-z0-9])merge([^A-Za-z0-9]|$|PullRequest)" \
                    || t1 ~ "mergePullRequest" || (length(r) >= 3 && r ~ /^m?e?r?g?e?$/)) m = 1 }
            if (g && d && m) f = 1 }
            END { exit !f }' && fires=1
fi
# A word that only GLOBS to `merge` (`m?rge`, `[m]erge`, a bare `*`) hides the verb
# from every text copy: a segment with a gh word, a `pr` word and such a word fires
# (quoted spans are dropped first; `ls *` has no gh+pr precondition).
if [ "$fires" = "0" ]; then
    # shellcheck disable=SC2020 # five separators each map to a newline, by design
    printf '%s' "$cmd" | tr ';&|(\n' '\n\n\n\n\n' | _dq \
        | awk '{ g = 0; p = 0; s = 0
            for (i = 1; i <= NF; i++) { w = $i
                if (w == "gh" || w ~ "/gh$") g = 1
                if (w == "pr") p = 1
                if (w ~ "[*?[]") { re = w; gsub(/\[[!^]/, "[^", re); gsub(/[.]/, "[.]", re); gsub(/[*]/, ".*", re); gsub(/[?]/, ".", re)
                    if ("merge" ~ ("^" re "$")) s = 1 } }
            if (g && p && s) f = 1 }
            END { exit !f }' 2>/dev/null && fires=1
fi
# Positional rules for a SINGLE shell-computed word (judge r2): (R1) a literal gh
# word, then an expansion or substitution in the subcommand position or, after
# `pr`, in the verb position (`gh pr "$M" 1`, `gh $A 42`, `gh "$@" 42`); (R2) a
# segment with any non-plain word (rule D's allowlist, so assignments and wrappers
# such as `command "$G"`, `env "$G"`, `X=1 "$G"` count) before an `api` word, then a
# merge-ish word or a PUT with a pulls/ path (`"$G" api -X PUT repos/o/r/pulls/1/merge`).
# `gh pr view "$PR"` never reaches an expansion in those positions. Both words
# computed, or a computed merge path (`gh api -X PUT "$U"`) stays the HIMMEL-3945
# residual.
if [ "$fires" = "0" ]; then
    # shellcheck disable=SC2020,SC2016 # five separators map to newlines; the sed pattern is literal
    printf '%s' "$cmd" | sed -e ':a' -e '$!N' -e '$!ba' -e 's/\\\n//g' -e 's/\$(/$ /g' | tr ';&|(\n' '\n\n\n\n\n' | _dq \
        | awk '{ g = 0; pr = 0; skip = 0; api = 0; put = 0; pul = 0; bad = 0
            for (i = 1; i <= NF; i++) { w = $i; s = w
                if (bad && !api && s == "api") { api = 1; continue }
                if (api) { if (s == "PUT") put = 1; if (s ~ "pulls/") pul = 1
                    if (s ~ "merge" || (put && pul)) f = 1 }
                if (s !~ "^[A-Za-z0-9_./+=-]+$") bad = 1
                if (!g) { if (s == "gh" || s ~ "/gh$") g = 1; continue }
                if (skip) { skip = 0; continue }
                if (s ~ "^-") { if (s == "-R" || s == "--repo") skip = 1; continue }
                if (w ~ /[$`]/) { f = 1; continue }
                if (s == "pr") { pr = 1; continue }
                g = 0 } }
            END { exit !f }' 2>/dev/null && fires=1
fi
# The mirror case: in a segment with a `pr` word then a merge word, EVERY word
# up to the merge word must be plain (`^[A-Za-z0-9_./+=-]+$`, quote chars and
# backslashes ignored); a computed, globbed or wrapper-hidden word (`$'\x67\x68'
# pr merge`, `${G} pr merge`, `"$G" pr me\rge`) fires. An allowlist, so no
# spelling needs listing.
if [ "$fires" = "0" ] && printf '%s\n%s' "$cmd_norm" "$cmd_sq" | grep -qE '(^|[^A-Za-z0-9])merge([^A-Za-z0-9]|$|PullRequest)'; then
    # shellcheck disable=SC2020 # five separators each map to a newline, by design
    printf '%s' "$cmd" | sed -e ':a' -e '$!N' -e '$!ba' -e 's/\\\n//g' -e 's/\\//g' | tr ';&|(\n' '\n\n\n\n\n' | _dq \
        | awk '{ pr = 0; bad = 0
            for (i = 1; i <= NF; i++) { w = $i
                if (w ~ "^[A-Za-z0-9_./+=-]+$") {
                    if (w == "pr") pr = 1
                    else if (w == "merge" && pr && bad) f = 1
                } else { bad = 1
                    if (pr && w ~ "(^|[^A-Za-z0-9])merge([^A-Za-z0-9]|$)") f = 1 } } }
            END { exit !f }' && fires=1
fi
# ponytail: both the program word AND the verb shell-computed (or `bash -c` fed
# from a variable holding both) stay undetectable by text, structural backstop
# is a gh- or credential-level merge gate (HIMMEL-3945).
[ "$fires" = "1" ] || exit 0
case "$cmd" in
    *[!A-Za-z0-9\ _./:=,-]*) plain=0 ;;
    *) plain=1 ;;
esac
set -f
# shellcheck disable=SC2086
set -- $cmd
set +f
if [ "$plain" != "1" ] || [ "${1-}" != "gh" ]; then
    _deny "gh pr merge must be a single plain command with no quoting (only letters, digits, space and _ . / : = - , are allowed; no chaining, redirects, pipes, substitution, prefixes or quotes) — refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh for a custom subject/body. (For help run: gh help pr merge)"
fi

# Extract the selector + --repo + head pin; selector = first non-flag token
# after the `merge` verb.
sel=""; repo=""; match_head=""
# `gh help pr merge` (the deny text's own pointer) only prints help.
[ "$*" = "gh help pr merge" ] && exit 0
# HIMMEL-3929: up to the verb the ONLY tokens are `gh`, -R/--repo <v> (before or
# after `pr`) and one `pr`; the repo found here is the gated repo exactly like one
# after the verb. Anything else (api, alias, a wrapper word, another flag) denies.
shift
seen_pr=0; seen_merge=0
while [ "$#" -gt 0 ] && [ "$seen_merge" = "0" ]; do
    case "$1" in
        --repo=*) repo="${1#--repo=}" ;;
        --repo|-R)
            [ "$#" -ge 2 ] || _deny "gh pr merge: -R/--repo needs a value — refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
            repo="$2"; shift ;;
        pr) [ "$seen_pr" = "0" ] || _deny "gh pr merge: a second 'pr' word — the command must be exactly gh [-R <v>] pr [-R <v>] merge <args>: refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
            seen_pr=1 ;;
        merge) [ "$seen_pr" = "1" ] || _deny "gh: 'merge' before 'pr' — the command must be exactly gh [-R <v>] pr [-R <v>] merge <args>: refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
            seen_merge=1 ;;
        *) _deny "a command naming a merge must be exactly gh [-R <v>] pr [-R <v>] merge <args> (gh api, gh alias, wrappers and other flag placements are refused); got '$1' — refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)" ;;
    esac
    shift
done
[ "$seen_merge" = "1" ] || _deny "a command naming a merge must be exactly gh [-R <v>] pr [-R <v>] merge <args>; no merge verb found — refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo=*) repo="${1#--repo=}" ;;
        --repo|-R) if [ "$#" -ge 2 ]; then repo="$2"; shift; fi ;;
        # --match-head-commit is captured (not just consumed) so gate 3 can
        # verify a leg's merge pins the head its GO was bound to (HIMMEL-3142
        # CR round). Both spellings: the space form below, and =-form here.
        --match-head-commit=*) match_head="${1#--match-head-commit=}" ;;
        --match-head-commit)
            if [ "$#" -ge 2 ]; then match_head="$2"; shift; fi ;;
        # Closed token set (judge r3): the hook and gh must read the SAME words,
        # and gh's pflag groups short flags (`-dt 5` = `-d -t 5`) and lets a
        # value flag swallow the next word, so anything outside this set denies.
        -s|--squash|-m|--merge|-r|--rebase|-d|--delete-branch|--disable-auto) ;;
        -*) _deny "gh pr merge accepts only -s -m -r -d --squash --merge --rebase --delete-branch --disable-auto, -R/--repo <v> and --match-head-commit <v>; got '$1' (grouped or attached flags, -b/-t/-F/-A and unknown flags are refused): gh pr merge must be a single plain command — refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh for a custom subject/body. (For help run: gh help pr merge)" ;;
        *)
            if [ -n "$sel" ]; then
                _deny "gh pr merge takes at most one selector; got a second positional '$1': gh pr merge must be a single plain command — refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
            fi
            sel="$1" ;;
    esac
    shift
done

# No --help/-h carve-out (HIMMEL-3915): every spelling of it was a new bypass
# (escaped spaces, $'..' quoting, delimiters). A help-flagged merge is gated like
# any other; the deny text points at `gh help pr merge`, which is not a merge.

# Strip surrounding quotes the tokenizer preserved: `gh pr merge "42"` must
# not hand the literal `"42"` to gh (codex-adv-1 — quoted selector dodged the
# gate via the pr-view fail-open).
sel="${sel#\"}"; sel="${sel%\"}"; sel="${sel#\'}"; sel="${sel%\'}"
repo="${repo#\"}"; repo="${repo%\"}"; repo="${repo#\'}"; repo="${repo%\'}"
match_head="${match_head#\"}"; match_head="${match_head%\"}"
match_head="${match_head#\'}"; match_head="${match_head%\'}"

# The cwd branch — fallback anchor when no/bad selector was extracted.
cwd_branch=""
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    cwd_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
fi

# No explicit selector: gh infers the current branch; do the same.
[ -z "$sel" ] && sel="$cwd_branch"
[ -z "$sel" ] && exit 0   # cannot resolve target: fail open

# ── Resolve the PR (number + head, shared by gates 3 and 4) — FIRST, before any
# gate, and BOUNDED. HIMMEL-3915: on a real merge command an UNRESOLVED lookup
# (selector AND cwd-branch re-anchor) fails CLOSED for every session. It used to
# exit 0 after the CR/CI gates, so a transient gh/auth error let a trust-path PR
# through with no GO; and an unbounded `gh pr view` hang (here or in the gates'
# own lookups) exhausted the hook budget, which Claude Code reads as non-blocking.
# The HIMMEL-936 api-error-fails-open contract now covers only the CR/CI gates'
# own API reads, after this lookup has already succeeded. Each lookup is
# bounded (10s); a timeout reads as unresolved.
# _gate4_bounded <secs> <outfile> <cmd...> — run <cmd> with stdout to
# <outfile> (stderr to $_gate4_err when set, else discarded), killed after <secs>; rc is the command's, or 124 on timeout. Bash
# native (no timeout binary) so it bounds a shell function the same way on
# every platform.
# ponytail: kill -9 reaches the backgrounded subshell, not an in-flight gh it
# spawned (orphaned, it finishes on its own), upgrade path: a process-group
# kill if an orphaned gh is ever seen outliving its hook.
_gate4_bounded() {
    local secs=$1 out=$2 pid ticks=0
    shift 2
    "$@" >"$out" 2>"${_gate4_err:-/dev/null}" &
    pid=$!
    while [ "$ticks" -lt $((secs * 5)) ] && kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        ticks=$((ticks + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
}
go_tmp=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-view.XXXXXX" 2>/dev/null) || go_tmp=""
gh_t0=$SECONDS
# HIMMEL-3918 (I1): ONE 45s budget for the whole hook (Claude Code kills it at
# 60s and reads that as non-blocking). _budget_left <cap> prints min(cap, left).
_budget_left() {
    local left=$((45 - (SECONDS - gh_t0)))
    [ "$left" -gt "$1" ] && left=$1
    [ "$left" -lt 0 ] && left=0
    echo "$left"
}
gh_to_flag=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-timeout.XXXXXX" 2>/dev/null) || gh_to_flag=""
trap 'rm -f "$go_tmp" "$gh_to_flag" "${trust_tmp:-}"' EXIT
# HIMMEL-3918 (3): every gh call the sourced gate libraries make (cr-merge-gate,
# ci-green-gate and the cr-signal / cr-body-findings helpers they call) goes
# through this shadow function, bounded (10s) like the lookup above. The libs
# fail OPEN on a gh error (HIMMEL-936), and an unbounded hang would run out the
# hook budget, which Claude Code reads as non-blocking - so a timeout is recorded
# in $gh_to_flag and the hook DENIES after each gate call (_gh_timed_out). Set in
# the hook, not the libs: it also bounds the transitive calls, and the libs'
# other callers (check-ci, pr-merge.sh) keep their own behaviour.
gh() {
    local out errf rc=0 cap _gate4_err
    # One timeout already means deny: skip later calls so a run of hung gh calls
    # cannot each spend another 10s of the hook budget before the deny.
    if [ -n "$gh_to_flag" ] && [ -s "$gh_to_flag" ]; then return 124; fi
    # One shared budget (_budget_left) across every gh call in the hook: each
    # call is capped to what remains, and none starts once it is spent, so the
    # hook always denies before Claude Code's 60s timeout (non-blocking).
    cap=$(_budget_left 10)
    if [ "$cap" -le 0 ]; then
        [ -n "$gh_to_flag" ] && echo 1 >"$gh_to_flag"
        return 124
    fi
    out=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-gh.XXXXXX" 2>/dev/null) || out=""
    errf=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-ghe.XXXXXX" 2>/dev/null) || errf=""
    if [ -z "$out" ] || [ -z "$errf" ]; then
        rm -f "$out" "$errf"
        [ -n "$gh_to_flag" ] && echo 1 >"$gh_to_flag"
        return 124   # cannot bound the call: read as a timeout (deny)
    fi
    # stderr is replayed: trust_path_check tells a 404 from an outage by it.
    _gate4_err=$errf
    _gate4_bounded "$cap" "$out" command gh "$@" || rc=$?
    if [ "$rc" = "124" ] && [ -n "$gh_to_flag" ]; then echo 1 >"$gh_to_flag"; fi
    cat "$out" 2>/dev/null
    cat "$errf" >&2 2>/dev/null
    rm -f "$out" "$errf"
    return "$rc"
}
_gh_timed_out() { [ -z "$gh_to_flag" ] || [ -s "$gh_to_flag" ]; }
# _go_view <selector> [repo] — sets go_meta ("" on any failure or timeout).
_go_view() {
    go_meta=""
    [ -n "$go_tmp" ] || return 1
    if [ -n "${2:-}" ]; then
        _gate4_bounded 10 "$go_tmp" gh pr view "$1" --repo "$2" --json number,headRefOid,url || return 1
    else
        _gate4_bounded 10 "$go_tmp" gh pr view "$1" --json number,headRefOid,url || return 1
    fi
    go_meta=$(cat "$go_tmp" 2>/dev/null) || go_meta=""
}
# HIMMEL-2141: bind the PR number to ITS repo before anything resolves it. The
# effective repo is the explicit -R/--repo, else the repo of the payload cwd (the
# directory `gh pr merge` will run in); the project repo is the one this hook runs
# in. A selector is only meaningful inside one repo, so when the two differ the
# lookups below would read the project repo's PR of the same number: refuse, as
# merge-on-green.sh's same-repo guard does. An unresolvable repo refuses too.
# CR_MERGE_GATE_OK=1 (the documented bypass) merges the other repo on purpose; the
# lookups then carry its name explicitly instead of resolving it from a cwd.
_nwo_key() {
    local n=${1#https://}
    n=${n#http://}; n=${n%/}; n=${n%.git}
    n=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')
    # A HOST/OWNER/REPO spelling keeps any host other than github.com, so another
    # host's o/r never compares equal to this repo's o/r.
    case "$n" in
        github.com/*/*) n=${n#*/} ;;
    esac
    printf '%s' "$n"
}
proj_nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || proj_nwo=""
eff_nwo=$repo
if [ -z "$eff_nwo" ] && [ -n "$cwd" ]; then
    eff_nwo=$(cd "$cwd" 2>/dev/null && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || eff_nwo=""
    [ -n "$eff_nwo" ] || _deny "cannot resolve this repo's owner/name (the merge's working directory '$cwd') — refusing (GATE INTEGRITY: PR #$sel must be read in the repo it belongs to). Pass -R <owner>/<name>, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
fi
if [ -n "$eff_nwo" ]; then
    [ -n "$proj_nwo" ] || _deny "cannot resolve this repo's owner/name to bind PR #$sel — refusing (GATE INTEGRITY). Use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
    if [ "$(_nwo_key "$eff_nwo")" != "$(_nwo_key "$proj_nwo")" ]; then
        if [ "${CR_MERGE_GATE_OK:-}" = "1" ]; then
            [ -n "$repo" ] || repo=$eff_nwo
        else
            _deny "this merge targets $eff_nwo, not the project repo ($proj_nwo) — PR #$sel would be read from the wrong repo — refusing (GATE INTEGRITY). Run scripts/handover/merge-on-green.sh from that repo's own checkout, or set CR_MERGE_GATE_OK=1 in the LAUNCHING shell to merge it deliberately. (For help run: gh help pr merge)"
        fi
    fi
fi
_gh_timed_out && _deny "a gh call binding PR #$sel to its repo timed out (10s bound) or could not be bounded — refusing (GATE INTEGRITY). Retry, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
_go_view "$sel" "$repo" || go_meta=""
go_num=$(printf '%s' "$go_meta" | jq -r '.number // empty' 2>/dev/null || true)
go_sha=$(printf '%s' "$go_meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
if { [ -z "$go_num" ] || [ -z "$go_sha" ]; } && [ -n "$cwd_branch" ] && { [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; }; then
    _go_view "$cwd_branch" "" || go_meta=""
    go_num=$(printf '%s' "$go_meta" | jq -r '.number // empty' 2>/dev/null || true)
    go_sha=$(printf '%s' "$go_meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
fi
if [ -z "$go_num" ] || [ -z "$go_sha" ]; then
    echo "block-unresolved-cr-merge: cannot resolve the PR for '$sel' (gh pr view failed or timed out) — refusing (GATE INTEGRITY: the CR, CI, leg-GO and trust-path gates need the PR number and head). Retry the merge, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)" >&2
    exit 2
fi

# HIMMEL-3918 (4): a gate library that will not load DENIES on a real merge (it
# used to `|| exit 0`, so a missing/unreadable/truncated lib silently dropped the
# CR and CI gates). Readability first, per scripts/hooks/CLAUDE.md: on bash 3.2 a
# failed `.` exits the shell regardless of an `||` guard.
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/cr-merge-gate.sh" ] && . "$SCRIPT_DIR/../lib/cr-merge-gate.sh"; } 2>/dev/null \
        || ! declare -F cr_merge_gate >/dev/null 2>&1; then
    _deny "cannot load scripts/lib/cr-merge-gate.sh — refusing (the CR gate must fail closed, not silently no-op)"
fi

reason=""
rc=0
reason=$(cr_merge_gate "$sel" "$repo") || rc=$?
if [ "$rc" = "3" ] && [ -n "$cwd_branch" ]; then
    # The extracted token did not resolve to a PR (a value-taking flag's
    # argument or leftover quoting mistaken for the selector — codex-1).
    # Re-anchor to the cwd branch IN THE CWD REPO (drop the extracted repo:
    # it may itself be a quote placeholder — coderabbit app round) so
    # ordinary CLI syntax cannot dodge the gate; if this ALSO fails to
    # resolve, the gate stays fail-open. Guard against re-running the
    # identical lookup (same branch, no repo override).
    if [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; then
        rc=0
        reason=$(cr_merge_gate "$cwd_branch" "") || rc=$?
    fi
fi
_gh_timed_out && _deny "a gh call in the CR gate timed out (10s bound) or could not be bounded — refusing (GATE INTEGRITY: a hung read must not read as an allow). Retry, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
if [ "$rc" = "2" ]; then
    echo "block-unresolved-cr-merge: $reason (For help run: gh help pr merge)" >&2
    exit 2
fi

# ── CI-green merge gate (HIMMEL-1043) — runs SECOND, after the CR gate ──
# Same extracted selector ($sel)/$repo + rc=3 re-anchor pattern as the CR gate
# above; the CI gate is independent (its own bypass CI_MERGE_GATE_OK=1) and
# never coupled to CR_PROFILE. A guard bug must NEVER block a legit merge, so
# every unresolvable/degraded path fails open (rc 0/3) inside ci_green_gate.
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/ci-green-gate.sh" ] && . "$SCRIPT_DIR/../lib/ci-green-gate.sh"; } 2>/dev/null \
        || ! declare -F ci_green_gate >/dev/null 2>&1; then
    _deny "cannot load scripts/lib/ci-green-gate.sh — refusing (the CI gate must fail closed, not silently no-op)"
fi

ci_reason=""
ci_rc=0
ci_reason=$(ci_green_gate "$sel" "$repo") || ci_rc=$?
if [ "$ci_rc" = "3" ] && [ -n "$cwd_branch" ]; then
    # Mirror the CR gate's re-anchor: the extracted token did not resolve to a
    # PR, so retry once on the cwd branch (in the cwd repo) so ordinary CLI
    # syntax cannot dodge the gate; if this also fails, ci_green_gate fails open.
    if [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; then
        ci_rc=0
        ci_reason=$(ci_green_gate "$cwd_branch" "") || ci_rc=$?
    fi
fi
_gh_timed_out && _deny "a gh call in the CI gate timed out (10s bound) or could not be bounded — refusing (GATE INTEGRITY: a hung read must not read as an allow). Retry, or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
if [ "$ci_rc" = "2" ]; then
    echo "block-red-ci-merge: $ci_reason" >&2
    exit 2
fi

# ── Console-GO merge gate (HIMMEL-2919/HIMMEL-3142) — runs THIRD, after CR
# and CI — see the header comment for gate 3. Only binds a console-spawned leg
# (console_leg truthy, scripts/lib/go-gate.sh — HIMMEL-3149); a non-leg
# session (HIMMEL_CONSOLE_LEG unset/empty, by far the common case) never
# reaches the `. go-gate.sh` below, so gate 3 never turns a broken library
# into a blocker for sessions it was never meant to bind. (Gate 4, the
# trust-path gate at the end, does load go-gate.sh for EVERY session — see
# there, HIMMEL-3910.)
#
# console_leg lives in scripts/lib/go-gate.sh beside go_gate() itself, shared
# with merge-on-green.sh's own console-GO gate and go.sh's own refusal, so
# none of the three can drift on "is this a leg". The five-spelling
# interpretation (empty/0/false/off/no, case-insensitive, whitespace-stripped)
# is console_leg's alone — this outer check is only "is the var non-empty at
# all", cheap enough not to duplicate that logic, so an explicitly-set falsy
# value (e.g. HIMMEL_CONSOLE_LEG=0) still sources go-gate.sh and gets the
# real, shared interpretation.
is_leg=1
if [ -n "${HIMMEL_CONSOLE_LEG:-}" ]; then
    # Drop any go_gate/console_leg already in scope first (a PATH executable
    # or an inherited `export -f` would otherwise survive the source below
    # undetected) so only the file's own definitions can satisfy the
    # declare -F checks below.
    unset -f go_gate console_leg go_mac go_key_file go_resolve_root _go_in_harness 2>/dev/null || true
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if ! . "$SCRIPT_DIR/../lib/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1; then
        echo "block-unresolved-cr-merge: cannot load scripts/lib/go-gate.sh — refusing (the console-leg marker check must fail closed, not silently no-op)" >&2
        exit 2
    fi
    console_leg || is_leg=0
else
    is_leg=0
fi

# PR number + head-sha (shared by gates 3 and 4) were resolved up front
# (HIMMEL-3915, see "Resolve the PR" above).
go_url=$(printf '%s' "$go_meta" | jq -r '.url // empty' 2>/dev/null || true)

# HIMMEL-3578: the GO mac binds the repo, and gate 4 reads the trust list from
# it, so resolve nwo the same way merge-on-green.sh does — from an explicit
# --repo/-R on the merge command itself when given (already extracted into
# $repo above), else the current checkout. `gh repo view` is timeout-bounded:
# this hook runs on a budget, and a hang here must read as a refusal, never
# as an allow.
# HIMMEL-3578 (round 2): resolve the GNU-semantics `timeout` through the
# shared resolver, which also tries `gtimeout` — a bare `timeout` check alone
# left every merge refused on stock macOS (no coreutils). Gate 4 bounds its
# own calls with it too.
# shellcheck disable=SC1091
# shellcheck source=../lib/timeout-bin.sh
# HIMMEL-3929: a missing/unreadable timeout-bin.sh DENIES (readability first, as
# for the libraries above) instead of running on with no resolver.
if ! { [ -r "$SCRIPT_DIR/../lib/timeout-bin.sh" ] && . "$SCRIPT_DIR/../lib/timeout-bin.sh"; } 2>/dev/null; then
    _deny "cannot load scripts/lib/timeout-bin.sh — refusing (the bounded gate calls must fail closed, not silently lose their timeout resolver)"
fi
go_nwo="$repo"
# HIMMEL-3918 (I1): through the shadow gh (10s cap, shared hook budget), never
# the real gh - a hang here must read as a refusal, not run out the hook budget.
if [ -z "$go_nwo" ]; then
    go_nwo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || go_nwo=""
fi
if [ -z "$go_nwo" ]; then
    echo "block-unresolved-cr-merge: cannot resolve this repo's owner/name for PR #$go_num — refusing (GATE INTEGRITY: the GO mac binds the repo, and the trust-path gate reads its list from it). Pass --repo <owner>/<name>, or run from a checkout gh can resolve." >&2
    exit 2
fi

# HIMMEL-3910 (judge round): gates 3 and 4 use the PR's CANONICAL owner/name,
# read from the url of the PR gh resolved — never the --repo text as typed.
# gh accepts `-R github.com/o/r` (HOST/OWNER/REPO); fed verbatim to the trust
# list read, that spelling 404s, and a 404 reads as "another repo"
# (not-adopted), so a trust-path PR merged with no trust-reviewed GO. The
# typed or resolved nwo must name the same repo as the PR url (host and .git
# dropped, case-insensitive); anything else is refused, never guessed.
go_canon=""
case "$go_url" in
    https://*/*/*/pull/*)
        go_canon=${go_url#https://*/}
        go_canon=${go_canon%/pull/*} ;;
esac
case "$go_canon" in
    */*/*|/*|*/|*[!A-Za-z0-9._/-]*) go_canon="" ;;
    */*) ;;
    *) go_canon="" ;;
esac
if [ -z "$go_canon" ]; then
    echo "block-unresolved-cr-merge: cannot read PR #$go_num's owner/name from its url ('$go_url') — refusing (GATE INTEGRITY: the GO mac and the trust-path gate bind the canonical repo)." >&2
    exit 2
fi
go_typed=${go_nwo#https://}
go_typed=${go_typed#http://}
go_typed=${go_typed%/}
go_typed=${go_typed%.git}
case "$go_typed" in */*/*) go_typed=${go_typed#*/} ;; esac
if [ "$(printf '%s' "$go_typed" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$go_canon" | tr '[:upper:]' '[:lower:]')" ]; then
    echo "block-unresolved-cr-merge: '$go_nwo' does not name the repo PR #$go_num resolved on ($go_canon) — refusing (GATE INTEGRITY). Pass --repo $go_canon." >&2
    exit 2
fi
go_nwo=$go_canon

if [ "$is_leg" -eq 1 ]; then
    go_root=""
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    # HIMMEL-3573 row 1: go_resolve_root is the same resolver go.sh writes
    # through, so a leg running `gh pr merge` directly with no HANDOVER_DIR in
    # its own env still lands on the anchor's .env-configured root, the one a
    # valid console GO was actually written under — a plain handover_root()
    # here fell back to the harness repo's inline stub instead and falsely
    # refused a valid GO.
    if . "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null && declare -F go_resolve_root >/dev/null 2>&1; then
        go_root=$(go_resolve_root "$SCRIPT_DIR/../.." 2>/dev/null) || go_root=""
    fi
    # go-gate.sh is already sourced above (console_leg check) — only confirm
    # go_gate and go_mac are defined (a truncated file could define
    # console_leg but not the rest).
    if ! declare -F go_gate >/dev/null 2>&1 || ! declare -F go_mac >/dev/null 2>&1; then
        echo "block-unresolved-cr-merge: scripts/lib/go-gate.sh sourced but go_gate is not defined (truncated file?) — refusing (a console-spawned leg's GO gate must fail closed, not silently no-op)" >&2
        exit 2
    fi
    go_reason=""
    go_rc=0
    go_reason=$(go_gate "$go_num" "$go_sha" "$go_root" "$go_nwo") || go_rc=$?
    if [ "$go_rc" -ne 0 ]; then
        if [ -z "$go_reason" ]; then
            go_reason="go_gate for PR #$go_num at $go_sha returned an unexpected exit code ($go_rc) — this is a console-spawned leg; send READY to your console and wait for GO"
        fi
        echo "block-unresolved-cr-merge: $go_reason" >&2
        exit 2
    fi

    # A confirmed GO is bound to $go_sha, but that is THIS hook's own
    # `gh pr view` read, not a property of the merge command that
    # follows — a separate `gh pr merge` invocation can land a different
    # commit unless it pins one itself (coderabbit CR round). Only this
    # half is fail-closed (GATE INTEGRITY, same boundary as the GO-file
    # check above): the resolution above still fails OPEN on an
    # unresolvable selector like its siblings, but once a GO is
    # confirmed valid, an unpinned or mismatched merge command must
    # never pass.
    if [ -z "$match_head" ]; then
        echo "block-unresolved-cr-merge: a console-spawned leg's merge must pin --match-head-commit $go_sha (the head the GO for PR #$go_num was bound to) — none was given" >&2
        exit 2
    fi
    if [ "$match_head" != "$go_sha" ]; then
        echo "block-unresolved-cr-merge: --match-head-commit $match_head does not match the GO-bound head $go_sha for PR #$go_num — refusing" >&2
        exit 2
    fi
fi

# ── Trust-path gate (HIMMEL-3910) — runs FOURTH, for EVERY session. A PR
# touching a CI trust path (scripts/ci/ci-trust-paths.txt) needs a
# trust-reviewed console GO, pinned to its head. merge-on-green.sh has asked
# this since HIMMEL-3895; a direct `gh pr merge` used to pass the same PR on an
# ordinary GO (a leg) or on none (the operator). The question itself is
# trust_path_check in scripts/lib/go-gate.sh, shared with merge-on-green.sh so
# the two entry points cannot drift. Unlike gate 3 this binds the operator too,
# exactly as merge-on-green.sh does for every caller: go.sh --trust-reviewed is
# the operator's route through it. Every failure below refuses — a trust check
# that cannot run must never read as "no trust path".
gate4_refuse() {
    echo "block-unresolved-cr-merge: $1" >&2
    exit 2
}
# Drop every go-gate name already in scope (a leg sourced the file for gate 3;
# an inherited `export -f` would otherwise survive) so only the anchor file's
# own definitions can satisfy the declare -F checks.
unset -f trust_path_check go_trust_gate go_trust_id_ok go_gate _go_gate_verify console_leg go_mac go_key_file go_resolve_root _go_in_harness 2>/dev/null || true
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/go-gate.sh" ] && . "$SCRIPT_DIR/../lib/go-gate.sh"; } 2>/dev/null \
        || ! declare -F trust_path_check >/dev/null 2>&1 || ! declare -F go_trust_gate >/dev/null 2>&1; then
    gate4_refuse "cannot load trust_path_check and go_trust_gate from scripts/lib/go-gate.sh — refusing (the CI trust-path gate must fail closed, not silently no-op)"
fi
trust_anchor=$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P) || trust_anchor=""
[ -n "$trust_anchor" ] || gate4_refuse "cannot resolve the harness anchor for the CI trust-path check of PR #$go_num — refusing"
trust_tmp=$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-trust.XXXXXX" 2>/dev/null) \
    || gate4_refuse "cannot create a temp file for the CI trust-path check of PR #$go_num — refusing"
_gate4_bounded 10 "$trust_tmp" gh repo view "$go_nwo" --json defaultBranchRef --jq '.defaultBranchRef.name // ""' || true
trust_branch=$(cat "$trust_tmp" 2>/dev/null) || trust_branch=""
[ -n "$trust_branch" ] \
    || gate4_refuse "cannot read $go_nwo's default branch for the CI trust-path check of PR #$go_num — refusing"
trust_rc=0
trust_secs=$(_budget_left 30)
[ "$trust_secs" -gt 0 ] || gate4_refuse "the hook budget is spent before the CI trust-path check of PR #$go_num — refusing"
_gate4_bounded "$trust_secs" "$trust_tmp" trust_path_check "$go_nwo" "$go_num" "$go_sha" "$trust_branch" "$trust_anchor" || trust_rc=$?
trust_out=$(cat "$trust_tmp" 2>/dev/null) || trust_out=""
if [ "$trust_rc" -eq 124 ]; then
    gate4_refuse "the CI trust-path check of PR #$go_num timed out — refusing"
fi
if [ "$trust_rc" -ne 0 ]; then
    gate4_refuse "CI trust-path check refused PR #$go_num (${trust_out:-trust_path_check exited $trust_rc with no reason})"
fi
case "$trust_out" in
    none|not-adopted) ;;
    "hit "?*)
        trust_hit=${trust_out#hit }
        trust_root=""
        # shellcheck source=scripts/lib/handover-path.sh
        # shellcheck disable=SC1091
        if . "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null && declare -F go_resolve_root >/dev/null 2>&1; then
            trust_root=$(go_resolve_root "$SCRIPT_DIR/../.." 2>/dev/null) || trust_root=""
        fi
        trust_id=$(go_trust_gate "$go_num" "$go_sha" "$trust_root" "$go_nwo") \
            || gate4_refuse "PR #$go_num touches CI trust path $trust_hit and needs a trust-reviewed GO: ${trust_id:-go_trust_gate refused with no reason}"
        # The trust GO is bound to $go_sha — the merge command must pin it, for
        # the operator as for a leg (same reason as gate 3's pin).
        if [ "$match_head" != "$go_sha" ]; then
            gate4_refuse "PR #$go_num touches CI trust path $trust_hit — the merge must pin --match-head-commit $go_sha (the head its trust-reviewed GO $trust_id is bound to); got '${match_head:-none}'"
        fi
        ;;
    *) gate4_refuse "CI trust-path check gave an unrecognised answer for PR #$go_num — refusing" ;;
esac
# HIMMEL-3918 (5) — runs LAST, so each gate keeps its own reason: head TOCTOU. Every gate read the PR at $go_sha, but a
# bare `gh pr merge 42` merges whatever head the PR has at merge time - a push in
# that window lands unreviewed code past the gates. Gates 3 and 4 already demanded
# the pin when they applied; it is now required of EVERY direct merge, and it must
# equal the head this hook read (gh then aborts if the head moved).
# merge-on-green.sh pins the head itself in its own gh subprocess and never
# reaches this hook, so it is unaffected.
if [ -z "$match_head" ]; then
    _deny "a direct gh pr merge must pin --match-head-commit $go_sha (the head the gates just read for PR #$go_num) — none was given; without it a push after the gates lands unreviewed. Or use scripts/handover/merge-on-green.sh. (For help run: gh help pr merge)"
fi
if [ "$match_head" != "$go_sha" ]; then
    _deny "--match-head-commit $match_head does not equal the head $go_sha the gates read for PR #$go_num — refusing. Pin the full 40-char head. (For help run: gh help pr merge)"
fi

exit 0
