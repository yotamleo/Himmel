#!/usr/bin/env bash
# PreToolUse hook for Edit/Write/MultiEdit/NotebookEdit, plus Bash and
# PowerShell write-path arms.
#
# Denies writing to a LIVE settings.json/settings.local.json — the operator's
# actual $HOME/.claude/ user-scope config, or the PRIMARY checkout's
# .claude/settings*.json (a change there only takes effect after PR review,
# merge, and the operator's next launch) — while ALLOWING the identical edit
# inside a linked git worktree, where landing a settings change is the
# legitimate mechanism (HIMMEL-2360).
#
# Replaces two now-removed `permissions.deny` rules
# (`Edit(**/.claude/settings.json)`, `Edit(**/.claude/settings.local.json)`)
# that were too broad: they also blocked a leg from editing the WORKTREE COPY
# of settings.json, which is harmless — a worktree edit has no effect until
# it rides that leg's PR through review and merge.
#
# Deny requires ALL of:
#   1. basename is settings.json or settings.local.json
#   2. immediate parent dir is named .claude
#   3. EITHER under $HOME/.claude/ (user-scope live config)
#      OR the target's repo is a PRIMARY checkout: `git rev-parse --git-dir`
#      and `--git-common-dir`, both resolved to absolute paths, are EQUAL.
# A linked worktree has git-dir != git-common-dir -> ALLOW.
#
# Deliberately NOT the cheaper `.git`-is-a-directory-vs-file proxy that
# block-edit-on-main.sh uses: that proxy would ALLOW a SUBMODULE's
# settings.json too (a submodule's `.git` is also a FILE, same shape as a
# linked worktree's). A submodule is a real checkout, not disposable
# work-in-progress — its settings.json should stay protected. The
# git-dir/git-common-dir comparison denies it correctly; do not "simplify"
# this back to the .git file/dir proxy.
#
# A second full clone of the repo elsewhere on disk also has
# git-dir == git-common-dir and is therefore DENIED too — intended: this
# hook protects by REPO LAYOUT (primary checkout vs. linked worktree), not by
# a specific machine path.
#
# Known limitation, deliberately not chased (HIMMEL-2360 CR round 4,
# codex-1): canon() follows symlinks (both `realpath -m` and
# `pathlib.resolve()` dereference existing symlink components), so if
# `.claude/settings.json` is ITSELF a symlink to a differently-named/located
# file, the basename/parent check runs against the SYMLINK'S TARGET, not
# "settings.json"/".claude" — a bypass. Out of scope for this arm's actual
# threat model: mediating CLAUDE's own tool calls against a live config file,
# not defending against an attacker who can already plant an arbitrary
# symlink inside the checkout, which is filesystem write access at least as
# strong as editing settings.json directly. Consistent with the existing
# "not a complete write fence" scope (below) — Copy-Item/Move-Item/New-Item
# under PowerShell aren't covered (see the PowerShell arm below).
#
# Bash arm (HIMMEL-2360 retask, extended HIMMEL-1525): the replaced
# permission rules also covered Bash redirect targets ("Bash redirect
# targets are checked against Edit rules"), so a bare `Edit`/`Write`/etc. arm
# alone would silently reopen `echo x > <primary>/.claude/settings.json`.
# When tool_name=Bash, extract `>`/`>>` redirect targets, plus `cp`/`mv`
# destination arguments and `tee`/`sed -i` write arguments, from
# tool_input.command with a plain-text scan — NOT a shell parser — and run
# each candidate through the same predicate. This arm is the OPPOSITE
# failure direction from the edit-tool arms: it fails OPEN. An unparseable
# command, an ambiguous/quoted redirect, or anything else that goes sideways
# here just allows, matching the `require-quiet-run.sh` "workflow nudge"
# posture in scripts/hooks/CLAUDE.md ("fail open on their own infrastructure
# errors") rather than the always-active security-fence posture the
# edit-tool arms use. A shell parser that failed CLOSED here would deny
# arbitrary unrelated Bash calls whenever the redirect shape it could not
# read happened to mention "settings.json" in unrelated text.
#
# HIMMEL-1525 fail-closed carve-out: `node -e`/`python3 -c` are the one
# EXCEPTION to this arm's fail-open posture. Their write happens inside an
# eval string, not a discrete shell argument this scan can extract, so once
# the cheap prefilter has already confirmed the command names a live
# settings file, the arm denies unconditionally rather than guess at (and
# likely miss) the real target. A `node -e`/`python3 -c` invocation that
# never mentions a settings file is unaffected (the prefilter exits 0 before
# this check runs).
#
# Known limitation, deliberately not chased (HIMMEL-2360 CR round 5,
# codex-1): a RELATIVE redirect target is always resolved against the
# session's own cwd (tool_input.cwd), never against a `cd` earlier in the
# SAME command string — `cd <primary> && echo x > .claude/settings.json`
# from a non-primary cwd resolves the relative target against the ORIGINAL
# cwd, not the post-`cd` one, and can under-match. Tracking `cd` requires
# actually parsing shell control flow (`&&`/`;`/newline separators,
# subshells, `cd -`, a variable target) — exactly the "not a shell parser"
# line this arm already draws for quoting and redirection. An ordinary
# ABSOLUTE target (the common, and the only fully-covered, shape) is
# unaffected: it never touches $cwd at all.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 — allow
#   2 — block; stderr is shown to Claude and the user
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# python3 hang armor (HIMMEL-249): the Windows Store python3 stub can wedge
# (ignores SIGTERM, orphan child holds the $() pipe) — and a hung PreToolUse
# hook hangs the whole session. canon()'s python fallbacks go through this.
# Sourced GUARDED: under set -e an unguarded failed source exits rc=1, and
# PreToolUse only blocks on exit 2 — a missing lib would fail this security
# hook OPEN. Fail CLOSED instead (matches the capability checks below).
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/py-armor.sh" ] && . "$SCRIPT_DIR/../lib/py-armor.sh"; } 2>/dev/null; then
    echo "block-edit-live-settings: cannot source py-armor.sh — refusing to evaluate" >&2
    exit 2
fi

# --- Capability checks (fail CLOSED on missing deps; security boundary) ---
if ! command -v jq >/dev/null 2>&1; then
    echo "block-edit-live-settings: jq not on PATH — refusing to evaluate; install jq or comment the hook in .claude/settings.json" >&2
    exit 2
fi
if ! command -v git >/dev/null 2>&1; then
    echo "block-edit-live-settings: git not on PATH — refusing to evaluate; install git or comment the hook in .claude/settings.json" >&2
    exit 2
fi

# Pick a canonicaliser. GNU realpath -m is preferred (handles non-existent
# paths). BSD realpath on macOS does NOT support -m, so fall back to python
# (pathlib resolves traversal + symlinks AND emits POSIX forward slashes for
# self-consistency with the realpath-m branch). Fail CLOSED if neither is
# available — see block-edit-on-main.sh's twin comment for why (a missing
# canonicaliser would re-open the `worktrees/../foo.sh` bypass).
#
# CANON_FORCE env var (test-only) overrides probe.
CANON_MODE=""
if [ -n "${CANON_FORCE:-}" ]; then
    CANON_MODE="$CANON_FORCE"
else
    probe=$(realpath -m /nonexistent-canon-probe 2>/dev/null || true)
    if [ "$probe" = "/nonexistent-canon-probe" ]; then
        CANON_MODE="realpath-m"
    elif command -v python3 >/dev/null 2>&1; then
        CANON_MODE="python3"
    elif command -v python >/dev/null 2>&1; then
        CANON_MODE="python"
    else
        echo "block-edit-live-settings: needs GNU realpath -m or python (3.x) — refusing to evaluate; install GNU coreutils (macOS: brew install coreutils && add gnubin to PATH) or comment the hook" >&2
        exit 2
    fi
fi

# normalize_drive_form PATH — Windows/Git-Bash only: unify backslashes to
# forward slashes, and a single-letter POSIX mount (Git-Bash's own /c/...
# translation of a drive letter) to the SAME drive-letter form (C:/...) used
# by this git build's own absolute-path output and by Windows-native callers
# (Claude Code's JSON, most likely). Without this, two strings naming the
# IDENTICAL file compare unequal by pure text — `realpath -m` does NOT
# cross-translate between the two representations (verified empirically:
# `realpath -m /c/Users/x` stays `/c/Users/x`, never `C:/Users/x`). This is
# the mechanism behind "$HOME comparison must be canonicalised the same way
# as the target" — $HOME is POSIX-mount form by default in Git-Bash while a
# target path from Claude Code is Windows-drive form, so without this they
# would never match. A generic multi-segment mount (not a single drive
# letter) is left untouched — out of scope; no such mount is expected for a
# real project path or $HOME.
normalize_drive_form() {
    local p="${1//\\//}"
    case "$p" in
        /[A-Za-z]/*)
            local letter="${p:1:1}"
            letter=$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')
            p="${letter}:${p:2}"
            ;;
        [a-z]:/*)
            # Already drive form but a lowercase letter (Windows hands the
            # same file back interchangeably as c:/... or C:/...) — upper-
            # case it so it compares equal to the /[A-Za-z]/* branch's output.
            local letter="${p:0:1}"
            letter=$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')
            p="${letter}${p:1}"
            ;;
    esac
    printf '%s\n' "$p"
}

canon() {
    # Canonicalise a path. Returns empty on failure; caller MUST decide how
    # to treat empty (edit-tool arm fails closed on it, Bash arm skips the
    # target and keeps scanning). See block-edit-on-main.sh's twin for the
    # py_armor_capture rationale (HIMMEL-249).
    local p; p=$(normalize_drive_form "$1")
    case "$CANON_MODE" in
        realpath-m)
            realpath -m "$p" 2>/dev/null
            ;;
        python3)
            py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$p" 2>/dev/null || return 1
            printf '%s\n' "$PY_ARMOR_OUT"
            ;;
        python)
            PY_ARMOR_BIN=python py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False).as_posix())' "$p" 2>/dev/null || return 1
            printf '%s\n' "$PY_ARMOR_OUT"
            ;;
        *)
            return 1
            ;;
    esac
}

# check_target RAW_TARGET — resolve RAW_TARGET (joined onto $cwd if relative)
# and test it against the deny predicate. Prints exactly one of:
#   "deny <reason>: <canonicalised path>"
#   "allow"
#   "unknown"                      (canonicalisation failed)
# Never exits — callers decide fail-open vs fail-closed on "unknown".
check_target() {
    local raw="$1" t real base parent parent_base
    t="$raw"
    case "$t" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) : ;;   # already absolute (POSIX or Windows drive form)
        *) t="$cwd/$t" ;;
    esac

    real=""; real=$(canon "$t") || real=""
    if [ -z "$real" ]; then
        echo "unknown"
        return
    fi

    # Case-FOLDED basename/parent match (HIMMEL-2360 CR round 2): NTFS and
    # APFS/HFS+ are case-insensitive by default, so `.CLAUDE/SETTINGS.JSON`
    # and `.claude/settings.json` name the SAME live file there — a
    # case-sensitive `case` match would let alternate casing walk straight
    # past this security fence. Fold both sides to lowercase before
    # comparing; per scripts/hooks/CLAUDE.md a security fence prefers a
    # false positive (denying an unrelated same-name-different-case file on
    # a case-SENSITIVE filesystem, vanishingly unlikely for this basename)
    # over a false negative (missing the real bypass).
    base=$(basename "$real")
    base_lc=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    case "$base_lc" in
        settings.json|settings.local.json) : ;;
        *) echo "allow"; return ;;
    esac

    parent=$(dirname "$real")
    parent_base=$(basename "$parent")
    parent_base_lc=$(printf '%s' "$parent_base" | tr '[:upper:]' '[:lower:]')
    if [ "$parent_base_lc" != ".claude" ]; then
        echo "allow"; return
    fi

    # User-scope live config: $HOME/.claude/settings*.json. Case-FOLDED
    # (HIMMEL-2360 CR round 4): this compares the FULL parent PATH, not just
    # its basename, so round 2's basename/parent-basename fold does not
    # cover it — `$HOME/.CLAUDE/settings.json` (already past the folded
    # parent_base_lc gate above) still failed THIS case-sensitive equality
    # and fell through to allow on a non-repo, non-worktree cwd.
    if [ -n "${HOME:-}" ]; then
        local home_real=""
        home_real=$(canon "$HOME") || home_real=""
        if [ -n "$home_real" ]; then
            home_real="${home_real%/}"
            local parent_lc home_real_lc
            parent_lc=$(printf '%s' "$parent" | tr '[:upper:]' '[:lower:]')
            home_real_lc=$(printf '%s' "$home_real" | tr '[:upper:]' '[:lower:]')
            if [ "$parent_lc" = "$home_real_lc/.claude" ]; then
                echo "deny user-scope live config (\$HOME/.claude): $real"
                return
            fi
        fi
    fi

    # Primary-checkout live config: git-dir == git-common-dir (both resolved
    # to absolute paths). A linked worktree's git-dir lives under the
    # primary's .git/worktrees/<name> and so differs from git-common-dir ->
    # not denied here. A repo that isn't found at all is simply not a
    # primary checkout -> falls through to "allow" below; this is not a
    # capability failure, so it does not fail closed.
    #
    # `git -C <dir>` requires <dir> to literally exist on disk — but $parent
    # may not (a Write into a not-yet-created subdir, or a canonicalised
    # traversal that lands on a hypothetical nested path). Walk up from
    # $parent to the nearest ancestor that actually has a `.git` entry
    # (mirrors block-edit-on-main.sh's own ancestor walk) and anchor the git
    # calls there instead — that directory is guaranteed to exist.
    local _d="$parent" _prev="" repo_anchor=""
    while [ "$_d" != "$_prev" ]; do
        if [ -e "$_d/.git" ]; then repo_anchor="$_d"; break; fi
        _prev="$_d"
        _d=$(dirname "$_d") || _d="$_prev"
    done

    if [ -n "$repo_anchor" ]; then
        local raw_git_dir="" raw_git_common=""
        raw_git_dir=$(git -C "$repo_anchor" rev-parse --git-dir 2>/dev/null) || raw_git_dir=""
        raw_git_common=$(git -C "$repo_anchor" rev-parse --git-common-dir 2>/dev/null) || raw_git_common=""
        if [ -n "$raw_git_dir" ] && [ -n "$raw_git_common" ]; then
            local abs_git_dir abs_git_common git_dir_real="" git_common_real=""
            case "$raw_git_dir" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs_git_dir="$raw_git_dir" ;;
                *) abs_git_dir="$repo_anchor/$raw_git_dir" ;;
            esac
            case "$raw_git_common" in
                /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs_git_common="$raw_git_common" ;;
                *) abs_git_common="$repo_anchor/$raw_git_common" ;;
            esac
            git_dir_real=$(canon "$abs_git_dir") || git_dir_real=""
            git_common_real=$(canon "$abs_git_common") || git_common_real=""
            if [ -n "$git_dir_real" ] && [ -n "$git_common_real" ] && [ "$git_dir_real" = "$git_common_real" ]; then
                echo "deny primary checkout (git-dir == git-common-dir): $real"
                return
            fi
        fi
    fi

    echo "allow"
}

deny_message() { # deny_message TOOL_LABEL ORIGINAL_TARGET REASON
    cat >&2 <<EOF
⛔ block-edit-live-settings: refusing $1 on \`$2\` — $3.

This is a LIVE settings file: user-scope (\$HOME/.claude/) or the PRIMARY
checkout's .claude/ — a change there takes effect immediately, unreviewed.

Edit the copy inside a worktree instead and let it ride that leg's PR
through review and merge (it only takes effect after the operator's next
launch):

    cd .claude/worktrees/<your-leg>
    # edit .claude/settings.json there

Bypass (single-run, set in the LAUNCHING shell — a per-call prefix cannot
reach the hook process):

    EDIT_LIVE_SETTINGS_OK=1 claude

Or temporarily comment out the hook stanza in .claude/settings.json.
EOF
}

# scan_and_deny_matches TOOL_LABEL — reads newline-separated raw candidate
# targets on stdin (each still possibly quote-wrapped, exactly as extracted
# by a plain-text scan), and for the first one that resolves (via
# check_target) to a live settings file, denies with TOOL_LABEL in the
# message and exits 2 (or allows via EDIT_LIVE_SETTINGS_OK). Returns
# normally once every candidate has been checked and none denied — shared by
# the Bash and PowerShell arms below so the dequote/HOME-expand/check_target
# pipeline exists in exactly one place (HIMMEL-1525).
scan_and_deny_matches() {
    local tool_label="$1" tok t result Q
    while IFS= read -r tok || [ -n "$tok" ]; do
        [ -n "$tok" ] || continue
        t="$tok"
        while [ "${t:0:1}" = ">" ] || [ "${t:0:1}" = "|" ]; do t="${t#?}"; done
        while [ "${t:0:1}" = " " ] || [ "${t:0:1}" = "$(printf '\t')" ]; do t="${t#?}"; done
        [ -n "$t" ] || continue
        Q="\"'"
        t=$(printf '%s' "$t" | sed -E "s/^[$Q]+//; s/[$Q]+\$//; s#/[$Q]+#/#g; s#[$Q]+/#/#g")
        [ -n "$t" ] || continue
        # shellcheck disable=SC2088,SC2016
        case "$t" in
            '~') t="${HOME:-}" ;;
            '~/'*) t="${HOME:-}/${t:2}" ;;
            '$HOME') t="${HOME:-}" ;;
            '$HOME/'*) t="${HOME:-}/${t:6}" ;;
            '${HOME}') t="${HOME:-}" ;;
            '${HOME}/'*) t="${HOME:-}/${t:8}" ;;
        esac
        [ -n "$t" ] || continue
        result=$(check_target "$t")
        case "$result" in
            deny\ *)
                if [ "${EDIT_LIVE_SETTINGS_OK:-0}" = "1" ]; then
                    exit 0
                fi
                deny_message "$tool_label" "$t" "${result#deny }"
                exit 2
                ;;
            *) : ;;   # allow or unknown -> fail OPEN, keep scanning other targets
        esac
    done
}

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] || cwd="$PWD"

if [ "$tool_name" = "Bash" ]; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

    # Cheap prefilter — no git, no canon, on the common path: bail unless the
    # raw command text even mentions a settings basename. Case-FOLDED
    # (HIMMEL-2360 CR round 3): this gate runs BEFORE check_target's own
    # case-fold, so a case-sensitive match here would exit early on
    # `SETTINGS.JSON` and never even reach the (already case-insensitive)
    # scan below — the same case-insensitive-filesystem bypass, one layer
    # earlier.
    cmd_lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
    case "$cmd_lc" in
        *settings.json*|*settings.local.json*) : ;;
        *) exit 0 ;;
    esac

    # Plain-text scan for `>`/`>>` redirect targets. Deliberately not a shell
    # parser: escaped forms and non-redirect mentions (a pipeline with no `>`
    # at all, the basename inside a string) simply produce no match here and
    # fall through to the trailing `exit 0` — this arm's fail-open posture
    # (see header). A quoted target (`"..."` or `'...'`) is matched as ONE
    # span — INCLUDING any spaces inside the quotes — rather than stopping at
    # the first whitespace: a live settings path legitimately contains a
    # space on Windows (a `C:\Users\Jane Doe\...` profile), and the old  # leak-allow: home-path doc example
    # whitespace-terminated regex silently truncated + allowed those.
    #
    # Known limitation, deliberately not chased (HIMMEL-2360 CR round 5,
    # codex-3, Important not Critical — a FALSE-POSITIVE direction, not a
    # bypass): this scan cannot tell a real redirect `>` from one that
    # merely appears inside an ordinary quoted ARGUMENT, e.g.
    # `grep "note: > settings.json is protected" file.txt` — no `>` is
    # actually redirecting there, but the scan still extracts a candidate
    # and can over-deny. Distinguishing the two needs a quote-aware
    # character-by-character scan (full shell tokenising), the exact
    # "not a shell parser" line this arm draws elsewhere. Lower priority
    # than the earlier fixes above: worst case is an annoying denial with a
    # documented bypass (`EDIT_LIVE_SETTINGS_OK=1`), not a silent bypass of
    # the guard itself.
    #
    # Quote-stripping note (HIMMEL-2360 CR round 5, codex-2 regression fix):
    # scan_and_deny_matches strips quote characters only at a DELIMITER
    # position — token start/end, or immediately touching a `/` — rather
    # than every quote character. Round 4's blanket `tr -d` also deleted an
    # apostrophe that is part of the PATH ITSELF, not shell quoting
    # (`C:/Users/O'Brien/.claude/...`, a real Windows username shape),
    # corrupting a legitimate target into one that no longer canonicalises to
    # the same file the $HOME comparison expects — a false ALLOW. A quote
    # next to `/` still catches concatenated quoting (`"$HOME"/.claude/...`
    # — the closing `"` sits immediately before the `/`), but a quote sitting
    # between two ordinary characters mid-segment (O'Brien) is left alone.
    matches=$(printf '%s' "$cmd" | grep -oE ">>?[[:space:]]*(\"[^\"]*\"|'[^']*'|[^[:space:];&|<>]+)" 2>/dev/null || true)

    # cp/mv/tee/sed -i destination scan (HIMMEL-1525): a plain-text,
    # whole-command scan in the same "not a shell parser" spirit as the
    # redirect scan above — command chaining (`cp a b && rm c`) is not
    # decomposed into segments, matching the existing $cwd/`cd`-tracking
    # limitation documented in this file's header. `cp`/`mv` write to their
    # LAST argument (source args are read-only, e.g. `cp settings.json
    # /tmp/x` must stay ALLOW — only the destination is checked); `tee`
    # writes to every non-flag argument; `sed -i` writes to every non-flag
    # argument AFTER the first (which is the script/expression, not a file).
    cp_mv_rest=$(printf '%s' "$cmd" | grep -oE '(^|[;&|[:space:]])(cp|mv)[[:space:]]+.+' 2>/dev/null || true)
    cp_mv_dest=$(printf '%s' "$cp_mv_rest" | grep -oE '("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)[[:space:]]*$' 2>/dev/null || true)

    tee_seg=$(printf '%s' "$cmd" | grep -oE '(^|[;&|[:space:]])tee[[:space:]]+.+' 2>/dev/null || true)
    tee_rest=$(printf '%s' "$tee_seg" | sed -E 's/^[;&|[:space:]]*tee[[:space:]]+//')
    tee_dest=$(printf '%s' "$tee_rest" | grep -oE '("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)' 2>/dev/null | grep -vE '^-' || true)

    sed_matches=""
    sed_seg=$(printf '%s' "$cmd" | grep -oE '(^|[;&|[:space:]])sed[[:space:]]+.+' 2>/dev/null || true)
    case "$sed_seg" in
        *' -i'*|*'-i.'*|*'--in-place'*)
            sed_rest=$(printf '%s' "$sed_seg" | sed -E 's/^[;&|[:space:]]*sed[[:space:]]+//')
            sed_tokens=$(printf '%s' "$sed_rest" | grep -oE '("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)' 2>/dev/null | grep -vE '^-' || true)
            sed_matches=$(printf '%s' "$sed_tokens" | tail -n +2)
            ;;
    esac

    # node -e / python3 -c fail-closed carve-out (HIMMEL-1525, console-agreed
    # deviation from this arm's usual fail-open posture): the write actually
    # happens inside an eval string, not a discrete shell argument this scan
    # can extract — so once the cheap prefilter above has already confirmed
    # the command names a live settings file, deny unconditionally rather
    # than guess at a target. A bare `node -e "console.log(...)"` with no
    # settings mention never reaches this arm at all (prefilter exits 0
    # first), so this only fires on a command that already names the file.
    case "$cmd_lc" in
        *node*-e\ *|*node*-e\"*|*node*-e\'*|*node*--eval*|*python*-c\ *|*python*-c\"*|*python*-c\'*)
            if [ "${EDIT_LIVE_SETTINGS_OK:-0}" = "1" ]; then
                exit 0
            fi
            deny_message "a Bash eval (node -e / python -c)" "$cmd" "the command names a live settings file and its actual write target cannot be reliably parsed out of an eval string"
            exit 2
            ;;
    esac

    matches=$(printf '%s\n%s\n%s\n%s\n' "$matches" "$cp_mv_dest" "$tee_dest" "$sed_matches" | grep -v '^$' || true)
    printf '%s\n' "$matches" | scan_and_deny_matches "a Bash write (redirect/cp/mv/tee/sed -i)"

    exit 0
fi

if [ "$tool_name" = "PowerShell" ]; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    cmd_lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
    case "$cmd_lc" in
        *settings.json*|*settings.local.json*) : ;;
        *) exit 0 ;;
    esac

    # >/>>/>| redirect targets — same plain-text scan as the Bash arm above.
    matches=$(printf '%s' "$cmd" | grep -oE '>{1,2}\|?[[:space:]]*("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|<>]+)' 2>/dev/null || true)

    # Set-Content/Add-Content/Out-File: -Path/-FilePath VALUE, or the first
    # positional argument when the param name is omitted (PowerShell binds
    # either form). Copy-Item/Move-Item/New-Item are NOT covered here —
    # known limitation, mirrors this file's own "not a complete write fence"
    # scope note for cp/mv/tee/sed-i above; HIMMEL-1525 named Set-Content and
    # redirect specifically.
    cmdlet_rest=$(printf '%s' "$cmd" | grep -oiE '(set-content|add-content|out-file)[[:space:]]+.+' 2>/dev/null || true)
    if [ -n "$cmdlet_rest" ]; then
        path_arg=$(printf '%s' "$cmdlet_rest" | grep -oiE -- '-(path|filepath)[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)' 2>/dev/null | grep -oE '("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)$' || true)
        if [ -z "$path_arg" ]; then
            # Strip the leading verb token (cmdlet_rest starts with it,
            # matched case-insensitively by the grep -oi above) by position
            # rather than by re-matching its spelling — sed's case-
            # insensitive `s///I` flag is a GNU extension BSD/macOS sed lacks.
            rest_after_verb="${cmdlet_rest#* }"
            path_arg=$(printf '%s' "$rest_after_verb" | grep -oE '("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|]+)' 2>/dev/null | grep -vE '^-' | head -n1 || true)
        fi
        [ -z "$path_arg" ] || matches=$(printf '%s\n%s\n' "$matches" "$path_arg")
    fi

    printf '%s\n' "$matches" | scan_and_deny_matches "a PowerShell write (redirect/Set-Content/Add-Content/Out-File)"

    exit 0
fi

# Edit/Write/MultiEdit/NotebookEdit arm. MultiEdit's exact tool_input schema
# is not documented (it does carry file_path in every observed shape, but
# read it defensively rather than assuming) — file_path/notebook_path/path
# cover every known and plausible field name; a target this can't find
# simply falls through to allow, same as an unresolvable target already did
# under the removed permission rules.
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty' 2>/dev/null || true)
[ -n "$target" ] || exit 0

result=$(check_target "$target")
case "$result" in
    deny\ *)
        if [ "${EDIT_LIVE_SETTINGS_OK:-0}" = "1" ]; then
            exit 0
        fi
        deny_message "$tool_name" "$target" "${result#deny }"
        exit 2
        ;;
    unknown)
        # Fail CLOSED — an unresolvable target would otherwise prefix-match
        # nothing and exit 0, re-opening the `worktrees/../foo.sh` traversal
        # bypass (mirrors block-edit-on-main.sh's canon-failure handling).
        echo "block-edit-live-settings: canonicalisation failed for '$target' — refusing to evaluate" >&2
        exit 2
        ;;
    *)
        exit 0
        ;;
esac
