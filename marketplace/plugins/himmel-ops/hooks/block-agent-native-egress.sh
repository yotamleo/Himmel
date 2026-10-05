#!/usr/bin/env bash
# block-agent-native-egress.sh — PreToolUse(mcp__*agent-native*) egress fence
# (HIMMEL-4328).
#
# builder-visual@himmel (design profile, HIMMEL-4326) registers the hosted
# OAuth MCP `agent-native-dispatch`, which sends every tool argument to
# Builder.io. scripts/guardrails/egress-matrix.json holds the cell this hook
# enforces: salus x builder-io x * = hard deny. The hook refuses an
# agent-native MCP call when the session is in salus or the payload names
# salus content.
#
# Why a plugin-shipped hook, not a scripts/hooks/ one wired in
# .claude/settings.json: a design leg on salus runs with CLAUDE_PROJECT_DIR =
# the salus checkout. Project settings and the plugin's
# $CLAUDE_PROJECT_DIR/scripts/hooks/... entries (--optional) never fire
# there. A hook under ${CLAUDE_PLUGIN_ROOT} fires in every repo, because
# himmel-ops is in every profile's floor. For the same reason it cannot read the
# matrix at runtime (a salus session has no himmel checkout). It is
# self-contained, and test-egress-matrix.mjs pins the matrix row.
#
# Salus signals (ANY one denies):
#   1. the tool payload (tool_input, re-serialized by jq) contains "salus"
#   2. the cwd path contains "salus"
#   3. the cwd's git toplevel, git common dir, or any remote URL contains "salus"
#   4. a `.salus` marker at the cwd, the git common dir's parent, or any ancestor
#   5. the cwd sits under, or the payload contains, a root listed in
#      ~/.config/claude-glm/phi-roots or ~/.config/claude-glm/egress-denylist
#      (the same lists graphify-fence.sh reads), or a path-like payload token
#      resolves (through symlinks, relative to the cwd) under such a root.
#      A listed root of "/" covers everything; a list read error denies.
# All matching is case-insensitive. Signals 2, 4 and 5 test BOTH the cwd as
# given and its canonical (symlink-resolved) form, and signal 5 also
# canonicalizes each listed root, so a symlink in cannot dodge them.
# ponytail: substring match on "salus" over-blocks (a design prompt that merely
# mentions the word, a himmel worktree slug containing it). That is the safe
# direction, and the recovery is to reword. Upgrade path: a corpus classifier
# shared with graphify-fence.sh, if the false positives show up in practice.
# ponytail: the cwd comes from the hook payload (falling back to the hook's
# $PWD). A session that cd's out of salus and then pastes PHI that names no
# salus path and no listed root is not caught. No path-keyed guard can see
# content without a path. Upgrade path: a content classifier (the HIMMEL-1522
# voice-audio residual is the same class).
# ponytail: git signals trust the repo's own metadata. A salus clone renamed,
# with its remote renamed and no .salus marker or phi-roots entry, is not
# recognised. Upgrade path: ship a `.salus` marker in the salus repo itself.
# No env var can loosen the verdict (EGRESS_HOOK_BUDGET_S only shortens the
# time budget, for the test suite). GIT_DIR / GIT_WORK_TREE /
# GIT_COMMON_DIR are unset so an inherited value cannot redirect the git probes.
#
# Fail closed (security fence) for everything this script decides: jq missing
# or malformed JSON that names agent-native denies, git missing denies, an
# unreadable list denies, and a payload too big to inspect inside the 15 s
# hook timeout denies (a timed-out hook is ALLOWED by the harness).
# ponytail: the launcher is NOT fail-closed. hooks.json runs this through
# run-node.sh, and when run-node.sh finds no node it logs one breadcrumb to
# himmel-node.log and exits 0 (deliberately fail-open, harness-wide, for
# every plugin hook), so this hook never runs and the call is allowed.
# Upgrade path: HIMMEL-4463.
# No bypass: the matrix cell is hard. To run this design work, use the local
# design skills, which keep content on the machine.
#
# Hook contract (PreToolUse): JSON on stdin; exit 0 allows, exit 2 blocks
# (stderr reaches Claude). bash 3.2-safe.
set -uo pipefail
t0=$SECONDS

_lc() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }

# Canonical (symlink-resolved) form of a directory; empty when it is not one.
# cd -P / pwd -P in a subshell: bash 3.2-safe, no realpath dependency.
_canon() { (cd -P -- "$1" 2>/dev/null && pwd -P) || true; }

deny() {
    {
        echo "block-agent-native-egress: refusing a hosted agent-native (Builder.io) MCP call: $1."
        echo "Tool arguments to this MCP leave the machine for Builder.io, and salus/PHI content never may"
        echo "(egress-matrix.json: salus x builder-io = hard deny, HIMMEL-4328)."
        echo "Do this work without the hosted MCP: use the local design skills (frontend-design,"
        echo "plannotator html-*, impeccable), which keep the content on this machine. There is no bypass."
    } >&2
    exit 2
}

input=$(cat)

# Unparseable input: fail closed only when it names agent-native.
_raw_decide() {
    case "$(_lc "$1")" in
        *agent-native*|*agent_native*) deny "the hook input could not be parsed (jq missing or malformed JSON)" ;;
        *) exit 0 ;;
    esac
}

command -v jq >/dev/null 2>&1 || _raw_decide "$input"
printf '%s' "$input" | jq empty >/dev/null 2>&1 || _raw_decide "$input"

tool_lc=$(_lc "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)")
case "$tool_lc" in
    mcp__*agent-native*|mcp__*agent_native*) ;;
    *) exit 0 ;;
esac

command -v git >/dev/null 2>&1 || deny "git is not on PATH, so the session repo cannot be checked"

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
cwd_lc=$(_lc "$cwd")
cwd_real=$(_canon "$cwd")
real_lc=$(_lc "$cwd_real")
args_lc=$(_lc "$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)")

# 1. payload names salus
case "$args_lc" in *salus*) deny "the tool payload names salus" ;; esac

# 2. cwd path names salus
case "$cwd_lc" in *salus*) deny "the session cwd ($cwd) is a salus path" ;; esac
case "$real_lc" in *salus*) deny "the session cwd ($cwd) resolves to a salus path ($cwd_real)" ;; esac

# 3. git toplevel / common dir / remotes
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
common=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null || true)
case "$common" in
    ""|/*) ;;
    *) common="$cwd/$common" ;;
esac
remotes=$(git -C "$cwd" remote -v 2>/dev/null || true)
case "$(_lc "$top")" in *salus*) deny "the session repo ($top) is salus" ;; esac
case "$(_lc "$common")" in *salus*) deny "the session repo's git dir ($common) is salus" ;; esac
case "$(_lc "$remotes")" in *salus*) deny "the session repo has a salus remote" ;; esac

# 4. .salus marker at the cwd / main repo or any ancestor
_salus_marked() {
    local d="$1" prev="x"
    [ -d "$d" ] || d="${d%/*}"
    d="${d%/}"
    # Trimming the last component of "/a" leaves "", and "/.salus" is then the
    # root's own marker, so the walk probes it before it stops.
    while [ "$d" != "$prev" ]; do
        if [ -e "$d/.salus" ]; then return 0; fi
        prev="$d"
        d="${d%/*}"
    done
    return 1
}
_salus_marked "$cwd" && deny "a .salus marker covers the session cwd ($cwd)"
if [ -n "$cwd_real" ]; then
    _salus_marked "$cwd_real" && deny "a .salus marker covers the session cwd ($cwd -> $cwd_real)"
fi
if [ -n "$common" ]; then
    _salus_marked "${common%/}/.." && deny "a .salus marker covers the session repo ($common)"
fi

# 5a. phi-roots / egress-denylist roots: read the lists and run the token-free
# checks (cwd and payload text against each root) BEFORE any per-token work,
# so these denials cost the same whatever the payload size (J1878).
phi_roots=""   # newline-separated lowercase roots, raw and canonical forms
if [ -n "${HOME:-}" ]; then
    for name in phi-roots egress-denylist; do
        list="$HOME/.config/claude-glm/$name"
        # A dangling symlink is an unreadable list, not an absent one.
        if [ -L "$list" ] && [ ! -e "$list" ]; then deny "the PHI root list $list is a dangling symlink (unreadable)"; fi
        [ -e "$list" ] || continue
        { [ -f "$list" ] && [ -r "$list" ]; } || deny "the PHI root list $list is unreadable"
        # Slurp first so a read error after the readability check fails closed.
        roots=$(cat -- "$list") || deny "the PHI root list $list could not be read"
        while IFS= read -r root || [ -n "$root" ]; do
            root="${root%$'\r'}"
            root="${root#"${root%%[![:space:]]*}"}"
            root="${root%"${root##*[![:space:]]}"}"
            case "$root" in ""|\#*) continue ;; esac
            case "$root" in *[!/]*) ;; *) deny "the PHI root list $list lists /, which covers every path" ;; esac
            root="${root%/}"
            # Compare raw and canonical forms both ways: either match denies.
            root_real=$(_canon "$root")
            for r in "$root" "$root_real"; do
                r_lc=$(_lc "${r%/}")
                [ -n "$r_lc" ] || continue
                for c in "$cwd_lc" "$real_lc"; do
                    [ -n "$c" ] || continue
                    case "$c/" in "$r_lc/"*) deny "the session cwd is under the PHI root $root ($name)" ;; esac
                done
                case "$args_lc" in *"$r_lc"*) deny "the tool payload names the PHI root $root ($name)" ;; esac
                phi_roots="$phi_roots$r_lc
"
            done
        done <<< "$roots"
    done
fi

# 5b. Path-like payload tokens (anything with a "/"), resolved against the
# cwd, cut to their deepest existing directory and canonicalized, so a
# symlink alias into a PHI root (or a salus tree) is seen by its real path.
# Bounded so the hook always decides well inside its 15 s harness timeout (a
# timed-out hook is ALLOWED by the harness, i.e. fails open):
#   - payload text over payload_budget bytes: deny (cannot inspect it all);
#   - more than path_cap path-like tokens: deny;
#   - a token's length alone never denies (base64, data: URIs, minified JS and
#     long URLs are long and are not paths into a root): every token takes the
#     forward walk, so an alias padded with ./ components trips walk_cap and
#     denies, while a blob stops at its first missing component and is allowed;
#   - past hook_budget wall-clock seconds (10 s, inside the 15 s harness
#     timeout): deny; EGRESS_HOOK_BUDGET_S can only LOWER it (test seam). The
#     budget bounds accumulated slowness across steps, NOT a single hung
#     resolve (see the ponytail below);
#   - a failure to canonicalize an existing path or leaf symlink, or to
#     extract the payload text: deny;
#   - a walk over walk_cap path components: deny;
#   - at most strip_cap quote/bracket/punctuation characters are stripped
#     from each end of a token.
# The walk goes FORWARD from / and stops at the first missing component, so
# it costs the existing depth, not the token length. A component over NAME_MAX
# (255) cannot exist, so the walk looks for each "/" in a bounded prefix and
# stops there; it never runs pattern expansion over a huge component.
# ponytail: tokens are split on whitespace only, so a path containing spaces,
# glued inside a word, or wrapped in more than strip_cap punctuation
# characters is not resolved. Upgrade path: HIMMEL-4463 (content classifier).
# ponytail: the budget is checked between steps, so one syscall hung in a
# dead NFS/FUSE mount is not preempted (the harness timeout then allows).
# Upgrade path: HIMMEL-4463 (a watchdog process).
payload_budget=262144
path_cap=256
walk_cap=128
strip_cap=8
hook_budget=10
case "${EGRESS_HOOK_BUDGET_S:-}" in
    ""|*[!0-9]*) ;;
    *) [ "$EGRESS_HOOK_BUDGET_S" -lt "$hook_budget" ] && hook_budget=$EGRESS_HOOK_BUDGET_S ;;
esac

_over_budget() {
    [ $((SECONDS - t0)) -lt "$hook_budget" ] \
        || deny "the path checks ran past the $hook_budget s wall-clock budget; cannot inspect all of the payload"
}

# Canonical form of the symlink $1 (its chain followed, parents resolved);
# empty when it cannot be resolved. readlink without -f: bash 3.2 / BSD safe.
_resolve_leaf() {
    local p="$1" hops=0 t dir
    while [ -L "$p" ]; do
        hops=$((hops + 1))
        [ "$hops" -le 40 ] || return 0
        t=$(readlink -- "$p") || return 0
        case "$t" in /*) p="$t" ;; *) p="${p%/*}/$t" ;; esac
    done
    # A target that is itself a directory (or ends in ..) is normalized whole.
    if [ -d "$p" ]; then _canon "$p"; return; fi
    dir="${p%/*}"
    dir=$(_canon "${dir:-/}")
    [ -n "$dir" ] && printf '%s/%s' "${dir%/}" "${p##*/}"
}

# Deepest existing directory on absolute path $1. Returns 2 past walk_cap.
_deepest_dir() {
    local rest="${1#/}" acc="/" comp head k=0
    while [ -n "$rest" ]; do
        k=$((k + 1))
        [ "$k" -le "$walk_cap" ] || return 2
        _over_budget
        # Pattern expansion (%%, #) on a huge component with no "/" is
        # superlinear and cannot be interrupted (a 262 KB run takes ~20 s, past
        # the harness timeout). A component over NAME_MAX (255) cannot exist, so
        # look for the "/" only in a bounded prefix and stop the walk at one.
        head="${rest:0:256}"
        case "$head" in
            */*) comp="${head%%/*}"; rest="${rest:$((${#comp} + 1))}" ;;
            *)
                [ "${#rest}" -le 255 ] || break
                comp="$rest"; rest=""
                ;;
        esac
        [ -n "$comp" ] || continue
        if [ -d "${acc%/}/$comp" ]; then acc="${acc%/}/$comp"; else break; fi
    done
    printf '%s' "$acc"
}

payload_text=$(printf '%s' "$input" | jq -r '[.tool_input // {} | .. | strings] | join("\n")' 2>/dev/null) \
    || deny "the payload text could not be extracted (jq failed), so it cannot be inspected"
payload_bytes=$(printf '%s' "$payload_text" | wc -c | tr -d ' ')
[ "${payload_bytes:-0}" -le "$payload_budget" ] \
    || deny "the tool payload is $payload_bytes bytes, over the $payload_budget-byte inspection budget; cannot inspect all of it"
n=0
set -f
for tok in $payload_text; do
    case "$tok" in */*) ;; *) continue ;; esac
    n=$((n + 1))
    [ "$n" -le "$path_cap" ] || deny "the tool payload has more than $path_cap path-like tokens; cannot inspect all"
    _over_budget
    # Strip at most strip_cap wrapping characters per side: each strip copies
    # the token, so an unbounded loop is quadratic on a punctuation run.
    k=0
    while [ "$k" -lt "$strip_cap" ]; do
        case "$tok" in \"*|\'*|\`*|\(*|\<*|\[*) tok="${tok#?}" ;; *) break ;; esac
        k=$((k + 1))
    done
    k=0
    while [ "$k" -lt "$strip_cap" ]; do
        case "$tok" in *\"|*\'|*\`|*\)|*\>|*\]|*,|*.|*\;|*:) tok="${tok%?}" ;; *) break ;; esac
        k=$((k + 1))
    done
    case "$tok" in
        \~/*) p="${HOME:-}/${tok#\~/}" ;;
        /*) p="$tok" ;;
        *) p="$cwd/$tok" ;;
    esac
    case "$p" in /*) ;; *) continue ;; esac
    leaf=""
    if [ -L "$p" ]; then
        # The walk below canonicalizes only directories; a leaf symlink to a
        # file is resolved here.
        leaf=$(_resolve_leaf "$p")
        [ -n "$leaf" ] || deny "the tool payload path $tok is a symlink that cannot be resolved"
    fi
    p=$(_deepest_dir "$p") || deny "a tool payload path has more than $walk_cap components or ran past the time budget; cannot inspect it"
    d=$(_canon "$p")
    # _deepest_dir returned an existing directory, so a failed canonicalization
    # (a mode-000 alias target, a dead mount) is not "no path": deny.
    [ -n "$d" ] || deny "the tool payload path $tok names an existing directory that cannot be canonicalized"
    for c in "$d" "$leaf"; do
        [ -n "$c" ] || continue
        c_lc=$(_lc "$c")
        case "$c_lc" in *salus*) deny "the tool payload path $tok resolves to a salus path ($c)" ;; esac
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            case "$c_lc/" in "$r/"*) deny "the tool payload path $tok resolves under the PHI root $r" ;; esac
        done <<< "$phi_roots"
    done
done
set +f
# The last token's resolution is not followed by another per-token check.
_over_budget

exit 0
