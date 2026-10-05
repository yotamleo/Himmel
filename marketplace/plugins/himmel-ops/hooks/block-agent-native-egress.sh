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
# No env var is consulted for the verdict. GIT_DIR / GIT_WORK_TREE /
# GIT_COMMON_DIR are unset so an inherited value cannot redirect the git probes.
#
# Fail closed (security fence): jq missing or malformed JSON that names
# agent-native denies, git missing denies, an unreadable list denies.
# No bypass: the matrix cell is hard. To run this design work, use the local
# design skills, which keep content on the machine.
#
# Hook contract (PreToolUse): JSON on stdin; exit 0 allows, exit 2 blocks
# (stderr reaches Claude). bash 3.2-safe.
set -uo pipefail

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
    local d="$1" prev=""
    [ -d "$d" ] || d="${d%/*}"
    while [ -n "$d" ] && [ "$d" != "$prev" ]; do
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

# Path-like payload tokens (anything with a "/"), resolved against the cwd,
# walked up to their deepest existing directory and canonicalized, so a
# symlink alias into a PHI root (or a salus tree) is seen by its real path.
# More than path_cap path-like tokens fails closed: past the cap not every
# path could be inspected.
# ponytail: tokens are split on whitespace only, so a path containing spaces
# or glued inside a word is not resolved. Upgrade path: HIMMEL-4463
# (content classifier).
path_cap=256
payload_dirs=""
payload_text=$(printf '%s' "$input" | jq -r '[.tool_input // {} | .. | strings] | join("\n")' 2>/dev/null) || payload_text=""
n=0
set -f
for tok in $payload_text; do
    case "$tok" in */*) ;; *) continue ;; esac
    n=$((n + 1))
    [ "$n" -le "$path_cap" ] || deny "the tool payload has more than $path_cap path-like tokens; cannot inspect all"
    while :; do
        case "$tok" in \"*|\'*|\`*|\(*|\<*|\[*) tok="${tok#?}" ;; *) break ;; esac
    done
    while :; do
        case "$tok" in *\"|*\'|*\`|*\)|*\>|*\]|*,|*.|*\;|*:) tok="${tok%?}" ;; *) break ;; esac
    done
    case "$tok" in
        \~/*) p="${HOME:-}/${tok#\~/}" ;;
        /*) p="$tok" ;;
        *) p="$cwd/$tok" ;;
    esac
    while [ -n "$p" ] && [ ! -d "$p" ]; do
        case "$p" in */*) p="${p%/*}" ;; *) p="" ;; esac
    done
    [ -n "$p" ] || continue
    d=$(_canon "$p")
    [ -n "$d" ] || continue
    d_lc=$(_lc "$d")
    case "$d_lc" in *salus*) deny "the tool payload path $tok resolves to a salus path ($d)" ;; esac
    payload_dirs="$payload_dirs$d_lc
"
done
set +f

# 5. phi-roots / egress-denylist roots
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
                case "
$payload_dirs" in *"
$r_lc
"*|*"
$r_lc/"*) deny "a tool payload path resolves under the PHI root $root ($name)" ;; esac
            done
        done <<< "$roots"
    done
fi

exit 0
