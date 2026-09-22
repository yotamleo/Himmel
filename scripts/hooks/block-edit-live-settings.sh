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
# Bash/PowerShell arm (HIMMEL-2360 retask, rewritten HIMMEL-1525 retask 2):
# the replaced permission rules also covered Bash redirect targets, so a
# bare `Edit`/`Write`/etc. arm alone would silently reopen
# `echo x > <primary>/.claude/settings.json`.
#
# v1 of this arm extracted a "destination argument" per verb (redirect
# target, cp/mv's last arg, tee/sed -i's write args, a node -e/python3 -c
# fail-closed carve-out). Console adversarial review (NO-GO on PR #1115)
# found per-verb argument extraction cannot be made complete: trailing
# `;`/`&`/`#`/`2>&1`/`| cat`/`> /dev/null`, a directory destination
# (`cp x .claude/`, `-t .claude/`), combined short flags (`sed -Ei`),
# subshells/aliasing/indirection (`(cp …)`, `\cp`, `/bin/cp`, `xargs cp`,
# `bash -c '…'`, `eval`, `$(cp …)`, a for-loop) and other interpreters
# (`node -p`) all defeated the per-verb scan on the very verbs it claimed to
# cover — while ALSO false-positive-denying a worktree's own interpreter
# writes and read-only pipelines (`tee /tmp/log < .claude/settings.json`)
# because the target was never resolved against cwd.
#
# v2 (this version) drops per-verb argument extraction entirely and asks
# only two questions of the WHOLE command text, case-insensitively:
#   1. Does it mention a live settings file at all (substring match on
#      `settings.json` / `settings.local.json` — any prefix, quoting, or
#      trailing chaining/redirection, none of which changes whether the
#      file is NAMED)? If so, deny — UNLESS the command is one of a short
#      read-only allowlist (cat/head/tail/less/grep/rg/jq without a
#      redirect or `-i`/diff/wc/git diff|show|log|status|blame) with no
#      chaining or redirection metacharacter anywhere (so a trailing
#      `&& rm -rf /` can't ride in on an allowlisted first verb).
#   2. Does it target the primary's `.claude/` DIRECTORY itself as a
#      destination (cp/mv/install/rsync/ln/dd/tee, or a
#      `-t`/`--target-directory` flag) without necessarily naming
#      settings.json in the text (`cp x .claude/`)?
# Either question denies ONLY when the mention resolves to a LIVE file: cwd
# is itself the primary checkout, or the command text contains the primary
# checkout's own absolute path or $HOME's (resolved once via
# git-common-dir/canon(), not re-parsed per candidate). A RELATIVE mention
# while cwd is a linked worktree names that worktree's OWN settings.json —
# allowed for every verb, matching a Write/Edit to the same path (fixes the
# false positives above). This is deliberately MORE conservative than v1 in
# one direction: a benign `cp <primary settings.json> /tmp/x` (reading, not
# overwriting) is now denied too, since verb/argument-position is no longer
# parsed — bypass: `EDIT_LIVE_SETTINGS_OK=1`, or use an allowlisted reader.
#
# ponytail: a variable-built path (`f="$HOME/.claude/settings.json"; cat
# "$f"`), a glob (`cat .cla*/settings.json`), a symlink staged to alias the
# file, or an absolute path into a SECOND clone of this repo elsewhere on
# disk (not this session's own primary) get no special handling here — none
# are text-matchable without a shell parser, and the Claude permission
# matcher (`permissions.deny` patterns), not this hook, is the right layer
# for that residual.
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

# resolve_repo_context — sets is_primary_cwd (1 if $cwd's repo has
# git-dir == git-common-dir), primary_root_lc (the primary checkout's own
# absolute path, lowercased — dirname of git-common-dir, which for BOTH a
# primary cwd and a linked-worktree cwd resolves to the SAME primary
# directory) and home_root_lc (canon($HOME), lowercased). Empty on failure —
# callers must guard on non-empty before using either as a case pattern (an
# empty quoted pattern segment inside `*"$var"*` matches everything).
resolve_repo_context() {
    is_primary_cwd=0
    primary_root_lc=""
    own_root_lc=""
    home_root_lc=""
    local _d _prev repo_anchor="" raw_git_dir raw_git_common
    local abs_git_dir abs_git_common git_dir_real git_common_real primary_root home_real
    _d="$cwd"; _prev=""
    while [ "$_d" != "$_prev" ]; do
        if [ -e "$_d/.git" ]; then repo_anchor="$_d"; break; fi
        _prev="$_d"
        _d=$(dirname "$_d") || _d="$_prev"
    done
    if [ -n "$repo_anchor" ]; then
        raw_git_dir=$(git -C "$repo_anchor" rev-parse --git-dir 2>/dev/null) || raw_git_dir=""
        raw_git_common=$(git -C "$repo_anchor" rev-parse --git-common-dir 2>/dev/null) || raw_git_common=""
        if [ -n "$raw_git_dir" ] && [ -n "$raw_git_common" ]; then
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
            if [ -n "$git_dir_real" ] && [ -n "$git_common_real" ]; then
                [ "$git_dir_real" = "$git_common_real" ] && is_primary_cwd=1
                primary_root=$(dirname "$git_common_real")
                primary_root_lc=$(printf '%s' "$primary_root" | tr '[:upper:]' '[:lower:]' | tr -d "\"'")
                own_root_lc=$(canon "$repo_anchor" | tr '[:upper:]' '[:lower:]' | tr -d "\"'") || own_root_lc=""
            fi
        fi
    fi
    if [ -n "${HOME:-}" ]; then
        home_real=$(canon "$HOME") || home_real=""
        if [ -n "$home_real" ]; then
            home_real="${home_real%/}"
            # Quote-stripped like the command text in mentions_primary_or_home,
            # or an apostrophe in the root itself never matches (HIMMEL-3468).
            home_root_lc=$(printf '%s' "$home_real" | tr '[:upper:]' '[:lower:]' | tr -d "\"'")
        fi
    fi
}

# mentions_primary_or_home CMD_LC — true when the command text contains the
# resolved primary checkout's own path, the resolved $HOME, or an
# unexpanded $HOME/~ literal immediately before .claude — i.e. the mention
# is NOT just a bare relative spelling of the current worktree's own copy.
mentions_primary_or_home() {
    local c="$1" c_noquotes
    # A quoted `"/resolved/path"/.claude/` interposes a quote character
    # between the resolved absolute path and its `.claude` suffix, which a
    # literal substring match can't span — strip quote characters once up
    # front so every match below sees the path as one contiguous string
    # regardless of quoting (matches the $HOME-literal handling further down).
    c_noquotes=$(printf '%s' "$c" | tr -d "\"'")
    # A linked worktree nested under the primary (`<primary>/.claude/
    # worktrees/<wt>`) contains the primary root in its own absolute path, so
    # its OWN settings write matched below (HIMMEL-3468 codex-1). Blank out
    # this worktree's own root first — never when `..` appears anywhere, since
    # `<wt>/../../settings.json` climbs back into the primary.
    if [ "$is_primary_cwd" = "0" ] && [ -n "$own_root_lc" ]; then
        case "$c_noquotes" in
            *..*) ;;
            *) c_noquotes=${c_noquotes//"$own_root_lc"/} ;;
        esac
    fi
    if [ -n "$primary_root_lc" ]; then
        case "$c_noquotes" in *"$primary_root_lc"*) return 0 ;; esac
    fi
    # Only the resolved $HOME's OWN .claude counts as live — matching
    # home_root_lc as a bare substring anywhere also matched an unrelated
    # absolute path merely nested under $HOME (e.g. a worktree's own path),
    # over-denying that worktree's legitimate writes to its own settings.
    if [ -n "$home_root_lc" ]; then
        case "$c_noquotes" in *"$home_root_lc/.claude"*) return 0 ;; esac
    fi
    # shellcheck disable=SC2016 # literal unexpanded $home/${home} text, not expansion
    case "$c_noquotes" in
        *'~/.claude/'*|*'$home/.claude/'*|*'${home}/.claude/'*) return 0 ;;
    esac
    # A relative parent-directory traversal landing directly on `.claude/`
    # (`../.claude/…`, any number of `../` segments) climbs OUT of the
    # current worktree — the worktree-relative exemption only covers this
    # worktree's own copy, which never needs `..` to name it, and in the
    # real `<repo>/.claude/worktrees/<name>` layout this is exactly the
    # shape that reaches the primary checkout's own `.claude/`.
    case "$c_noquotes" in *'../.claude/'*) return 0 ;; esac
    return 1
}

# is_readonly_allowlisted CMD_LC — the rule 1 exception: a short list of
# read-only programs, invoked alone (no chaining/redirection metacharacter
# anywhere, so a trailing `&& rm -rf /` can't ride in on an allowlisted
# first verb).
is_readonly_allowlisted() {
    local c="$1" first second
    # shellcheck disable=SC2016 # literal metacharacter text, not expansion
    case "$c" in
        *';'*|*'&'*|*'|'*|*'`'*|*'$('*|*'<('*|*'>'*|*tee*) return 1 ;;
    esac
    first=$(printf '%s' "$c" | awk '{print $1}')
    case "$first" in
        cat|head|tail|grep|rg|diff|wc) return 0 ;;
        less)
            # less -o/-O (case already folded by cmd_lc) or --log-file logs
            # the input stream to a file — a write, despite the read-only verb.
            case "$c" in *' -o'*|*'--log-file'*) return 1 ;; esac
            return 0
            ;;
        jq)
            case "$c" in *' -i'*|*'--in-place'*) return 1 ;; esac
            return 0
            ;;
        git)
            second=$(printf '%s' "$c" | awk '{print $2}')
            case "$second" in diff|show|log|status|blame) ;; *) return 1 ;; esac
            # --output/--output=<file> redirects these read-only subcommands'
            # output to a file — writing, not reading, despite the verb.
            case "$c" in *'--output'*) return 1 ;; esac
            return 0
            ;;
        *) return 1 ;;
    esac
}

# mentions_dot_claude_dir_dest CMD_LC — the command names a `.claude`
# directory as a path component, independent of whether it also spells out
# settings.json — rule 2 catches `cp x .claude/` / `cp -t .claude/ x`,
# where the destination basename is never "settings.json" in the text.
mentions_dot_claude_dir_dest() {
    local out
    # Trailing boundary includes a quote character: a quoted destination
    # with no trailing slash (`cp -r x/. ".claude"`) puts the closing quote
    # immediately after `.claude`, which the boundary class must accept too.
    out=$(printf '%s' "$1" | grep -E '(^|[^a-z0-9_])\.claude([/[:space:];&|"'"'"']|$)') || true
    [ -n "$out" ]
}

# has_write_verb_or_target_flag CMD_LC — a copy/move/link-shaped verb, or a
# `-t`/`--target-directory` flag (rule 2's verb list).
#
# The word boundary on both sides is the COMPLEMENT of a word character, not
# a list of shell metacharacters (HIMMEL-3468): an enumerated class missed
# `(`, `\`, `"` and `'` in turn, and whatever it omits next is the next
# bypass. Any non-word character before the verb now counts, at the cost of
# over-matching a word that merely ends a token (`-cp`, `x.tee`) — which only
# denies when a `.claude` destination is named too, i.e. fail-closed.
has_write_verb_or_target_flag() {
    local out
    out=$(printf '%s' "$1" | grep -E '(^|[^a-z0-9_])(cp|mv|install|rsync|ln|dd|tee)([^a-z0-9_]|$)') || true
    [ -n "$out" ] && return 0
    out=$(printf '%s' "$1" | grep -E '(^|[^a-z0-9_-])(-t|--target-directory)([^a-z0-9_-]|$)') || true
    [ -n "$out" ] && return 0
    return 1
}

# changes_directory CMD_LC — a cd/pushd/popd word anywhere in the command,
# with the same complement-of-a-word-character boundary as the verb list.
# ponytail: other cwd-moving spellings (`env -C`, `env --chdir`, a relative
# `find … -exec`) are not matched — the documented variable/glob residual.
changes_directory() {
    local out
    out=$(printf '%s' "$1" | grep -E '(^|[^a-z0-9_])(cd|pushd|popd)([^a-z0-9_]|$)') || true
    [ -n "$out" ]
}

input=$(cat)
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)

cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
[ -n "$cwd" ] || cwd="$PWD"

if [ "$tool_name" = "Bash" ] || [ "$tool_name" = "PowerShell" ]; then
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    cmd_lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
    # The shell drops quotes and escapes inside a word (`c\p`, `c""p` and
    # `settings.js\on` all name what they spell without them), so every
    # match below runs on the text with those characters removed
    # (HIMMEL-3468). Removing characters never removes a chaining or
    # redirection metacharacter, so the read-only allowlist only gets
    # stricter. PowerShell's escape is the backtick, and there `\` is a path
    # separator: fold it to `/` to match the forward-slash roots (codex-3).
    # ponytail: only the separator is folded — a POSIX-mount spelling
    # (`/c/Users/...`) of a drive-letter root is still not matched.
    if [ "$tool_name" = "PowerShell" ]; then
        cmd_lc=$(printf '%s' "$cmd_lc" | tr "\\\\" '/' | tr -d "\"'\`")
    else
        cmd_lc=$(printf '%s' "$cmd_lc" | tr -d "\"'\\\\")
    fi

    mentions_settings=0
    case "$cmd_lc" in
        *settings.json*|*settings.local.json*) mentions_settings=1 ;;
    esac

    dir_dest=0
    if mentions_dot_claude_dir_dest "$cmd_lc" && has_write_verb_or_target_flag "$cmd_lc"; then
        dir_dest=1
    fi

    if [ "$mentions_settings" = "0" ] && [ "$dir_dest" = "0" ]; then
        exit 0
    fi

    resolve_repo_context

    live=0
    if [ "$is_primary_cwd" = "1" ]; then
        live=1
    elif changes_directory "$cmd_lc"; then
        # The worktree-relative exemption is judged against the PreToolUse
        # cwd; a cd/pushd/popd in the same command moves the real target
        # (`cd ../../.. && echo x > .claude/settings.json` lands on the
        # primary), so the exemption no longer applies. Blunt on purpose: a
        # harmless cd is denied too (HIMMEL-3468, accepted false deny).
        live=1
    elif mentions_primary_or_home "$cmd_lc"; then
        live=1
    elif [ -z "$primary_root_lc" ] && [ -z "$home_root_lc" ]; then
        # Neither root resolved (no git repo upward from cwd, and $HOME is
        # unset or unresolvable) — the live-vs-worktree question cannot be
        # answered at all, so it is not answered "not live". Fail closed.
        live=1
    fi

    if [ "$live" = "0" ]; then
        exit 0
    fi

    if [ "$mentions_settings" = "1" ] && is_readonly_allowlisted "$cmd_lc"; then
        exit 0
    fi

    if [ "${EDIT_LIVE_SETTINGS_OK:-0}" = "1" ]; then
        exit 0
    fi

    if [ "$mentions_settings" = "1" ]; then
        deny_message "a $tool_name command" "$cmd" "the command text names a live settings.json/settings.local.json (worktree-relative spellings of the worktree's OWN copy are exempt; this one resolves to the primary checkout or \$HOME)"
    else
        deny_message "a $tool_name command" "$cmd" "the command targets the primary checkout's .claude/ directory itself (cp/mv/install/rsync/ln/dd/tee, or a -t/--target-directory destination)"
    fi
    exit 2
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
