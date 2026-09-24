#!/usr/bin/env bash
# Shared DESTINATION-based write fence for Bash/PowerShell-mediated writes into
# a PRIMARY checkout (HIMMEL-2526).
#
# WHY: block-edit-on-main.sh is wired ONLY on the Edit|Write|MultiEdit|
# NotebookEdit matcher, so a Bash-mediated write (`cat >`, `sed -i`, `tee`, a
# python heredoc, `cp`/`mv`/`rm`/`touch`, `git commit`) bypasses it entirely —
# a dispatched subagent wrote four files into the PRIMARY checkout while it
# was on main this way, and the fence never saw them (18 minutes invisible).
# This script closes that gap by resolving the TARGET PATH a Bash/PowerShell
# command would write to and refusing it when that path lands inside a
# protected checkout (main/master, or the PRIMARY checkout on a feature
# branch) — regardless of which tool carried the write.
#
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+. No `.ps1` twin —
# this script is invoked BY bash (`bash <this>` from run-hook-with-bash.js, or
# sourced from block-terminal-write-fence.sh, both of which already resolve a
# bash interpreter on every platform including Windows).
#
# Two entry modes — BOTH are real and BOTH are tested:
#   1. SOURCED by block-terminal-write-fence.sh (the codex lane). The parent
#      has already drained stdin into $input, extracted $cmd (case-preserved)
#      and $cmd_lc, sourced guardrails/lib.sh, and set `set -euo pipefail` +
#      the errexit->exit-2 clamp trap — all of which stay in effect here
#      (shell options and traps are process-wide, not per-sourced-file). A
#      DENY here is `exit 2`, which ends the parent (the correct DENY for the
#      codex adapter). Every ALLOW path returns (falls through) rather than
#      `exit 0`, which would end the parent early and skip its own trailing
#      logic.
#   2. DIRECT-EXEC by the Claude Bash PreToolUse chain. The launcher runs
#      `bash <this>` with the raw JSON hook payload on stdin (see
#      marketplace/plugins/himmel-ops/hooks/run-hook-with-bash.js:
#      `spawnSync(bash, [member], {input, ...})`). This mode reads stdin
#      itself and sets its OWN $input/$cmd, jq/git capability checks, and
#      errexit clamp. THIS BRANCH IS THE WHOLE POINT: without it, the
#      Claude wiring would run with an empty $cmd and allow every call — a
#      silent fail-OPEN on the exact incident lane this ticket exists to
#      close.
#
# CODEX-LANE PARITY (RETASK, no behaviour change in this PR): the git-commit
# and PowerShell-writer (Set-Content/Out-File/Add-Content) arms have NO
# extractable destination — they are a CWD predicate, not a target. The
# codex/sourced lane's contract for that predicate is HIMMEL-745's
# `is_on_main` (byte-identical port of block-terminal-write-fence.sh's old
# inline class-(b) block: deny only when the cwd's repo is on main/master,
# fail OPEN on a feature branch OR an unreadable branch, honouring a
# `.single-writer` repo-root marker). Tightening that to the destination-based
# main+primary-feature rule is a SEPARATE, deliberate change the design owner
# ruled out of this PR — so the direct-exec/Claude lane uses
# `main_checkout_verdict` on the cwd (the tighter rule, matching every other
# arm in this script) while the sourced/codex lane keeps `is_on_main` exactly
# as before. Every OTHER arm (redirect/tee/sed -i/cp/mv/rm/touch/ln) is
# DESTINATION-based in BOTH modes — that dual contract is the actual point of
# HIMMEL-2526 and is unaffected by the codex-parity carve-out above.
#
# Fail-open / fail-closed posture:
#   - Destination resolution (guard_canon_path failure, main_checkout_verdict
#     rc=3 "cannot evaluate") fails CLOSED — this is a security fence.
#   - A DYNAMIC target (still contains $ or a backtick after expansion) fails
#     OPEN on THAT candidate only — scanning continues on every other
#     candidate in the same command. A GLOB target does NOT simply fail open:
#     its longest glob-free directory prefix is checked instead (HIMMEL-2592
#     rule B), so `rm <worktree>/dirlink/*` cannot hide a write that
#     traverses a link into the primary.
#   - The codex-lane cwd predicate (git commit / PS writers) fails OPEN on a
#     feature branch or an unreadable branch, matching HIMMEL-745 exactly
#     (see CODEX-LANE PARITY above).
#   - Capability checks (jq, git, guardrails/lib.sh) fail CLOSED in
#     direct-exec mode.
#
# Token classes (HIMMEL-2592). Every walk in this file — the heredoc-opener
# walk, the clause splitter, the redirect pre-pass, the tokenizer — now
# agrees on what a token IS, and NO loop may consume a token outside its own
# class:
#   redirect-op  `[fd]>`/`>>` with the optional clobber `|` — recognised by
#                _bwimc_redirect_op_of and handled ONLY by the redirect walk.
#                Every operand loop (tee, rm, touch, ln, sed -i, cp/mv) tests
#                for it BEFORE treating a token as a filename and hands it on.
#   static-path  resolves cleanly — checked, INDEPENDENTLY of whether any
#                sibling operand resolved (see the cp/mv arm's INDEPENDENCE
#                note; this is the invariant three earlier hoist-fixes left
#                unstated).
#   glob         still carries `*`/`?`/`[` after expansion — its longest
#                glob-free directory prefix is checked with FOLLOW semantics
#                in WRITE roles; it never suppresses a sibling's check.
#   dynamic      still carries `$`/backtick — fails OPEN on ITSELF ALONE.
#   heredoc-op   an unquoted, non-comment `<<`/`<<-` that is not part of `<<<`.
# Path resolution is chosen by the OPERATION, not by the path: see the MODE
# note on _bwimc_check_abs and the operand-shape override in
# _bwimc_mode_for_operand.
#
# Known limitations:
#   - Arm (g) (HIMMEL-3401, git subcommands that rewrite a protected
#     checkout — see its own header for the allowlist + the pull/fetch
#     carve-out) targets the repo a git command is AIMED at, which for a
#     write run from a LINKED worktree's own cwd (no -C) is the worktree's
#     OWN root — a legitimate feature checkout that allows, even though
#     `config`/`remote` writes, `branch -u|-f`, and `update-ref`/
#     `symbolic-ref` on refs/heads/main|master land in the primary's SHARED
#     $GIT_COMMON_DIR. HIMMEL-3407 closes this for exactly those shapes by
#     also checking the target's owning primary checkout
#     (_bwimc_git_check_common_owner). Still unmodelled: `tag`/`reflog
#     expire|delete` writes and any other branch create/delete/rename from a
#     linked worktree's own cwd, and a remote repoint made by an earlier,
#     separate command (see the arm's own header, below).
#   - Command-text scanning, not a shell parser. A verb displaced from
#     command position (env-prefix, sudo/xargs/timeout wrappers) is missed,
#     same residual as block-terminal-write-fence.sh's class (a). The `tee`
#     arm is the one exception — it carries a CLOSED prefix-skip list (see
#     codex-2 below).
#   - Quote AND escape state are modelled, by ONE shared scanner
#     (_bwimc_scan_init/_bwimc_scan_step) that all four quote-aware passes
#     call — see its own header. `\` escapes the next character when
#     UNQUOTED and inside a DOUBLE-quoted span; inside a SINGLE-quoted span
#     a backslash is LITERAL and does not prevent the closing quote, because
#     bash has no escape there. That asymmetry is deliberate and is pinned by
#     the suite's MIRROR rows. Not modelled: `$'...'` ANSI-C quoting, and
#     `$(...)`/backtick nesting — a command substitution's body is scanned as
#     ordinary text, so a redirect inside one is seen (fails toward MORE
#     candidates, never fewer).
#   - Interpreter bodies (heredoc payloads, `python3 -c '...'`) are NOT parsed
#     for writes — heredoc bodies are blanked before scanning specifically so
#     a `>` inside one (`if a > b:`) cannot produce a phantom target; the
#     PostToolUse dirty-checkout detector (HIMMEL-2526 W3) covers what an
#     interpreter body actually wrote.
#   - `-T`/`--no-target-directory` IS modelled now (RETASK correction,
#     HIMMEL-2592 round 6 codex-2 — this bullet used to say the opposite):
#     for `mv` it forces the destination to plain ENTRY resolution instead
#     of directory-follow (`_bwimc_nodrf`, bundled forms like `-fT`
#     included), and for `ln` the same flag — alongside `-n`/
#     `--no-dereference` — does the same (`_bwimc_ln_nodrf`). For `cp`
#     specifically it is deliberately NOT applied: real `cp -T` against a
#     directory-shaped destination REFUSES (rc=1) and writes nothing, so
#     treating it as a mode-flip would be a pure false positive — pinned by
#     the suite's own control rows (55f/55g). What remains genuinely out of
#     scope is the one-operand `ln -s <target>` form (which links into the
#     CWD under basename(target)) — a cwd-predicate shape, the line this
#     script deliberately does not cross.
#   - A `cp` SOURCE is a READ role and is never checked; only `mv` SOURCES
#     (rename(2) removes the entry) are.
#   - `is_temp_or_devnull`'s `*/tmp/*` pattern exempts ANY repo-internal
#     `tmp/` directory, not only the filesystem `/tmp` — accepted, documented,
#     unchanged here (inherited from block-terminal-write-fence.sh).
#   - A `cd` earlier in the command does not move the resolution base: every
#     relative target resolves against the TOOL PAYLOAD cwd, never a `cd` the
#     command text itself performs (`cd <worktree> && echo x > y` issued from
#     a session whose payload cwd is the primary on main still denies — the
#     `cd` is not modelled). Correct-by-policy (the session cwd belongs in the
#     worktree, not the command text) and unchanged from the old codex-lane
#     class (b), which never modelled `cd` either — but it IS new behaviour on
#     the Claude lane, which had no class (b) at all before this PR. Not
#     something this script should try to fix: modelling `cd` is the
#     shell-parser line it correctly refuses to cross. Documented bypass:
#     EDIT_ON_MAIN_OK=1 in the LAUNCHING shell.
#
# Exit codes: 0/return allow (see mode note above); 2 block. Bash 3.2-safe.

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    _bwimc_sourced=1
else
    _bwimc_sourced=0
fi

if [ "$_bwimc_sourced" = 0 ]; then
    set -euo pipefail
    # shellcheck disable=SC2154
    trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

    _bwimc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if ! command -v jq >/dev/null 2>&1; then
        echo "block-write-into-main-checkout: jq not on PATH — refusing to evaluate; install jq" >&2
        exit 2
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "block-write-into-main-checkout: git not on PATH — refusing to evaluate; install git" >&2
        exit 2
    fi
    # shellcheck source=../guardrails/lib.sh
    # shellcheck disable=SC1091
    if ! { [ -r "$_bwimc_dir/../guardrails/lib.sh" ] && . "$_bwimc_dir/../guardrails/lib.sh"; } 2>/dev/null; then
        echo "block-write-into-main-checkout: cannot source guardrails/lib.sh — refusing to evaluate" >&2
        exit 2
    fi

    # Unparseable, empty or tool-less input fails CLOSED: this is a security
    # fence, and a payload it cannot read is not evidence the call is safe.
    input=$(cat)
    if ! tool=$(printf '%s' "$input" | jq -er 'if type == "object" then (.tool_name // "") | strings else error end' 2>/dev/null) \
        || [ -z "$tool" ]; then
        echo "block-write-into-main-checkout: malformed hook input (not a JSON object with a tool_name) — refusing" >&2
        exit 2
    fi
    case "$tool" in
        Bash|PowerShell) ;;
        *) exit 0 ;;
    esac
    cmd=$(printf '%s' "$input" | jq -r '(.tool_input.command // empty) | strings' 2>/dev/null || true)
    if [ -z "$cmd" ]; then
        echo "block-write-into-main-checkout: $tool input carries no tool_input.command — refusing" >&2
        exit 2
    fi
fi

# is_temp_or_devnull: reuse the parent's copy when sourced (block-terminal-
# write-fence.sh keeps this function defined — see this PR's Deliverable 2),
# define our own byte-identical copy otherwise so direct-exec mode is
# self-sufficient. `declare -f` guard avoids clobbering an already-sourced
# definition.
if ! declare -f is_temp_or_devnull >/dev/null 2>&1; then
is_temp_or_devnull() {
    # shellcheck disable=SC2016
    case "$1" in
        /dev/null|/dev/null/*) return 0 ;;
        /tmp|/tmp/*|*/tmp/*|*/temp/*) return 0 ;;
        *appdata/local/temp*) return 0 ;;
        '$tmp'*|'$temp'*|'%temp%'*|'%tmp%'*) return 0 ;;
        *) return 1 ;;
    esac
}
fi

# --------------------------------------------------------------- utilities

# ---- the ONE quote/escape scanner (HIMMEL-2592 CR codex-1) ----
#
# This file has four passes that each need to know what a character MEANS:
# heredoc-opener detection, clause splitting, tokenizing, and the redirect
# pre-spacing. Every one of them used to carry its OWN hand-written quote
# walk, and every one of them modelled quote state but NOT escape state — so
# `\"` read as CLOSING a double-quoted span in all four. That is one class,
# not four bugs, and it produced fail-OPENs in three of the four passes (a
# real redirect hidden because the walk thought it was still inside a quote)
# and false positives in the other direction. Fixing one pass and leaving
# three would repeat exactly the mistake this ticket exists to end.
#
# So: ONE scanner, called by all four. Each pass still emits its own
# characters — the scanner only answers the single shared question, "is this
# character syntactically ACTIVE (unquoted and not escaped), or is it inert
# literal text?"
#
# State lives in globals because bash 3.2 has no namerefs:
#   _BWIMC_Q    the currently open quote character, "" when unquoted
#   _BWIMC_ESC  1 when the PREVIOUS character was an escaping backslash
#   _BWIMC_ACT  set by every step: 1 = this character is syntactically ACTIVE
#
# The escape rule is ASYMMETRIC, and the asymmetry is load-bearing:
#   - UNQUOTED and inside a DOUBLE-quoted span, `\` escapes the next
#     character, so `\"` neither opens nor closes a span. Handling the
#     UNQUOTED case is not cosmetic: `echo \"> <primary>/f` is a REAL write,
#     and a walk that lets that `"` open a span sees the `>` as quoted and
#     misses the redirect entirely.
#   - Inside a SINGLE-quoted span bash has NO escape at all, so `'x\'` is a
#     COMPLETE string and the closing `'` really does close it. A naive
#     symmetric fix believes the span is still open, hides everything after
#     it, and invents a fail-open that does not exist today. The MIRROR rows
#     in the suite are the regression guard on precisely this.
#
# Backslash before a newline is line continuation and is consumed the same
# way, which is why callers step the newline through the scanner too.
_BWIMC_NL=$'\n'

_bwimc_scan_init() {
    _BWIMC_Q=""
    _BWIMC_ESC=0
    _BWIMC_ACT=0
}

_bwimc_scan_step() {
    local c="$1"
    if [ "$_BWIMC_ESC" = 1 ]; then
        _BWIMC_ESC=0
        _BWIMC_ACT=0
        return 0
    fi
    if [ -n "$_BWIMC_Q" ]; then
        if [ "$_BWIMC_Q" = '"' ] && [ "$c" = "\\" ]; then
            _BWIMC_ESC=1
        elif [ "$c" = "$_BWIMC_Q" ]; then
            _BWIMC_Q=""
        fi
        _BWIMC_ACT=0
        return 0
    fi
    case "$c" in
        \\) _BWIMC_ESC=1; _BWIMC_ACT=0 ;;
        "'"|'"') _BWIMC_Q="$c"; _BWIMC_ACT=0 ;;
        *) _BWIMC_ACT=1 ;;
    esac
    return 0
}

# Blank heredoc bodies line-by-line, keeping every OTHER line (including the
# opener and terminator lines) byte-identical, so a `>` inside a heredoc body
# (`if a > b:`) never reaches the redirect scan. Recognises `<<`/`<<-`
# optionally quoted. Bash 3.2-safe ([[ =~ ]] + BASH_REMATCH is bash 3.0+).
#
# HIMMEL-2591/2592: opener detection is a CHARACTER-LEVEL, quote- and
# comment-aware walk, in the same style as _bwimc_split_clauses — NOT a
# per-line regex over raw text, and NOT a call to _bwimc_tokenize. Blanking
# deliberately runs BEFORE tokenizing (so a heredoc body cannot confuse the
# tokenizer), so calling the tokenizer here would be circular; the walk
# breaks that circularity by carrying its own quote state. Two rules make it
# sound:
#   - Quote state is carried ACROSS lines but is FROZEN while `active=1` —
#     a heredoc BODY is literal text and its quote characters are not shell
#     quotes. This is exactly what made a per-line notion unsound.
#   - An unquoted `#` at a word boundary ends the line for opener purposes
#     and contributes no quote state.
# An opener is an unquoted `<<`/`<<-` NOT preceded by `<` and NOT followed by
# `<`. Both exclusions are load-bearing:
#   - the "not followed by `<`" / "not preceded by `<`" pair is the
#     structural replacement for codex-3's (HIMMEL-2526 CR round 4)
#     `(^|[^\<])` anchor: bash's `[[ =~ ]]` tries every start position, so on
#     `cat <<<EOF` the old regex could match beginning at the SECOND `<` and
#     blank every following line — including a real write — until a line
#     equal to "EOF" appeared.
#   - the quote/comment rules are HIMMEL-2591: `echo '<<EOF'`, `echo "<<EOF"`
#     and `# <<EOF` all used to start blanking, ERASING a real write on a
#     following line (a fail-OPEN produced by ordinary text, not a crafted
#     payload).
# Load-bearing control in both directions: a GENUINE heredoc must still blank
# its body — that is what stops a `>` in heredoc TEXT reading as a redirect.
#
# Backslash escaping inside quoted spans is not modelled, the same documented
# residual _bwimc_split_clauses/_bwimc_tokenize carry. Its failure direction
# here is a MISSED blanking (a phantom target from heredoc text), i.e. a
# false positive, never a bypass.
_bwimc_blank_heredocs() {
    local text="$1"
    local out="" line
    local active=0 dashmode=0 term=""
    local i len c prev rest check tab
    tab=$(printf '\t')
    # Quote/escape state is carried ACROSS lines (the scanner is initialised
    # once, here) but is FROZEN while a heredoc body is active — the body-line
    # branch below `continue`s without stepping the scanner, because a heredoc
    # body is literal text whose quotes are not shell quotes.
    _bwimc_scan_init
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$active" = 1 ]; then
            check="$line"
            if [ "$dashmode" = 1 ]; then
                while [ "${check:0:1}" = "$tab" ]; do check="${check#?}"; done
            fi
            if [ "$check" = "$term" ]; then
                active=0
                out="${out}${line}"$'\n'
            else
                out="${out}"$'\n'
            fi
            continue
        fi
        i=0; len=${#line}; prev=""
        while [ "$i" -lt "$len" ]; do
            c="${line:$i:1}"
            _bwimc_scan_step "$c"
            if [ "$_BWIMC_ACT" = 1 ]; then
                case "$c" in
                    '#')
                        case "$prev" in
                            ''|' '|"$tab"|';'|'&'|'|'|'('|')') break ;;
                        esac
                        ;;
                    '<')
                        if [ "$active" = 0 ] && [ "$prev" != '<' ] \
                           && [ "${line:$((i+1)):1}" = '<' ] && [ "${line:$((i+2)):1}" != '<' ]; then
                            rest="${line:$((i+2))}"
                            if [[ "$rest" =~ ^(-)?[[:space:]]*(\"([A-Za-z_][A-Za-z0-9_]*)\"|\'([A-Za-z_][A-Za-z0-9_]*)\'|([A-Za-z_][A-Za-z0-9_]*)) ]]; then
                                term="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
                                if [ -n "${BASH_REMATCH[1]}" ]; then dashmode=1; else dashmode=0; fi
                                active=1
                            fi
                        fi
                        ;;
                esac
            fi
            prev="$c"
            i=$((i+1))
        done
        # Step the line's own newline through the scanner: a trailing
        # backslash is line continuation, and consuming the newline here is
        # what stops the NEXT line's first character being read as escaped.
        [ "$active" = 1 ] || _bwimc_scan_step "$_BWIMC_NL"
        out="${out}${line}"$'\n'
    done <<< "$text"
    printf '%s' "$out"
}

# Split TEXT into clauses at top-level (unquoted) occurrences of ; & | ( and
# newline — the same boundary set as the (^|[;&|(]) command-position anchor
# used throughout this codebase's guardrails. One clause per output line.
# Quote-aware (a quote char only toggles when it matches the CURRENTLY open
# quote type, so a `'` inside a `"..."` span stays literal and vice versa).
#
# HIMMEL-2592: an unquoted `|` IMMEDIATELY preceded by an unquoted `>` is part
# of the CLOBBER redirect operator `>|`, not a clause boundary. Without this
# rule `echo x >| <primary>/f` split into `echo x >` + `<primary>/f`, and the
# redirect target was lost entirely — a silent fail-OPEN produced by a token
# one walk classified as an operator and another as a boundary. `||` and `|&`
# are untouched: in both the character before the `|` is `|` or the `|` is
# followed by `&`, never a bare `>`.
_bwimc_split_clauses() {
    local text="$1"
    local i=0 len=${#text} c clause="" prevact=""
    _bwimc_scan_init
    while [ "$i" -lt "$len" ]; do
        c="${text:$i:1}"
        _bwimc_scan_step "$c"
        if [ "$_BWIMC_ACT" = 1 ]; then
            case "$c" in
                '|')
                    if [ "$prevact" = '>' ]; then
                        clause="${clause}${c}"
                    else
                        printf '%s\n' "$clause"; clause=""
                    fi
                    ;;
                ';'|'&'|'('|"$_BWIMC_NL") printf '%s\n' "$clause"; clause="" ;;
                *) clause="${clause}${c}" ;;
            esac
        else
            clause="${clause}${c}"
        fi
        # `prevact` is the previous ACTIVE character, so an escaped or quoted
        # `>` cannot make the following `|` look like a clobber operator.
        if [ "$_BWIMC_ACT" = 1 ]; then prevact="$c"; else prevact=""; fi
        i=$((i+1))
    done
    printf '%s\n' "$clause"
}

# Tokenize a clause into whitespace-separated words, quote-aware (a whole
# quoted span — including its quote chars — is one token's worth of text so
# a spaced path like "my file.txt" survives as one token). One token per
# output line.
_bwimc_tokenize() {
    local text="$1"
    local i=0 len=${#text} c tok="" have=0
    _bwimc_scan_init
    while [ "$i" -lt "$len" ]; do
        c="${text:$i:1}"
        _bwimc_scan_step "$c"
        if [ "$_BWIMC_ACT" = 1 ]; then
            case "$c" in
                [[:space:]])
                    if [ "$have" = 1 ]; then printf '%s\n' "$tok"; tok=""; have=0; fi
                    ;;
                *) tok="${tok}${c}"; have=1 ;;
            esac
        else
            tok="${tok}${c}"; have=1
        fi
        i=$((i+1))
    done
    [ "$have" = 1 ] && printf '%s\n' "$tok"
    return 0
}

# codex-1 (HIMMEL-2526): a redirect operator ATTACHED to the preceding token
# (`echo x>/primary/f`, no space) tokenizes as ONE word — _bwimc_tokenize
# splits on whitespace only — so _bwimc_redirect_op_of (anchored on the
# TOKEN START) never matches and the target is missed entirely. Insert
# exactly one space immediately before an unquoted `>` whenever it is not
# already preceded by whitespace or by another `>` (so `>>` stays glued
# together as a single operator), giving the operator its own token before
# _bwimc_tokenize ever sees the clause. Quote-aware in the same style as
# _bwimc_split_clauses/_bwimc_tokenize — a `>` inside a quoted span is left
# completely untouched (codex-3's `echo 'text > "x"'` must keep ALLOWing).
#
# HIMMEL-2592: applied by EVERY arm now — (a) and the verb arms (b)/(e) — so
# all of them share ONE tokenization and a redirect operator is always a
# token of its own. `>` is left untouched when already preceded by
# whitespace, so the clobber form survives as one token (`>|/p/f`) for
# _bwimc_redirect_op_of to split.
#
# HIMMEL-2592 round 6 codex-1: `<` (input redirection) gets the SAME
# treatment as `>`, for the SAME reason — an attached form (`-t</dev/null`)
# tokenizes as one word otherwise, and _bwimc_redirect_op_of never gets a
# chance to recognise it. Measured against real cp: `-t</dev/null DIR src`
# and `-t < /dev/null DIR src` both copy into DIR exactly like the bare `-t
# DIR src` form — the shell strips the redirect before cp ever sees it,
# attached or spaced. `<` never doubles as an operator of its own the way
# `>>` does — `<<` is a HEREDOC marker (a different construct entirely, with
# a multi-line body, handled elsewhere in this file) — so `<<`/`<<<` are
# left GLUED here (same "prev matches the same char" rule that keeps `>>`
# together), never split into a bogus `<` + `<...`.
#
# HIMMEL-2592 round 9 codex-1/codex-2 (console-mandated STRUCTURAL fix,
# replacing rounds 6-8's sentinel-and-skip patchwork): a bare fd-NUMBER word
# glued directly to the operator (`2>foo`) is now kept in the SAME token as
# the operator — never split at all — exactly what _bwimc_redirect_op_of's
# own regex (`^([0-9]*|\&)(\>\>?)...`) was written to consume. No code
# anywhere reads the fd NUMBER for write-target purposes (verified: only
# _bwimc_op_rest, the text AFTER the operator, is ever used) so this needs
# no downstream tagging, skipping, or stripping — the rule "a bare fd
# number is never an operand" is enforced HERE, once, by never producing
# such a token, rather than at every site that might otherwise see one.
# Three rounds of point fixes (a sentinel byte, a next-token skip, a
# write-vs-read output) each closed one shape and left another — LEADING
# and MID positions were tested, TRAILING was not, and a synthesised digit
# is an ordinary operand everywhere except the one site taught to discard
# it. This is why a digit run is tracked (`_bwimc_word_alldigit`) rather
# than a single lookback character: `file2>foo` must NOT glue — "2" there
# is the tail of a real word, not a standalone fd selector, and real bash
# only treats a WHOLLY-numeric preceding word as an fd number. Getting that
# distinction wrong the other way (gluing `file2>foo` into one token) would
# leave it unrecognised by _bwimc_redirect_op_of entirely (its regex is
# anchored at the token START) — a fail-open in the opposite direction.
#
# HIMMEL-2592 round 10 codex-2: `<>` (bash's READ-WRITE redirect — opens for
# both, CREATES the target if missing) is kept glued into ONE token with NO
# exception, regardless of what precedes it or the digit-word tracking
# below — measured: `cat < > file` (a space between `<` and `>`) is a bash
# SYNTAX ERROR, so there is no legitimate spaced form to preserve, unlike
# `2>foo` vs `2 > foo` where both are real and must tokenize differently.
# Splitting `<>` (round 9's own `<`-is-a-read fix did exactly this,
# incidentally) demoted the write half to a bogus, unchecked `<`-prefixed
# input target — `cat <>@P@/new.txt` created a file in the primary and was
# allowed.
#
# HIMMEL-2592 round 10 codex-1: the `<>` glue decision above must ask the
# shared quote/escape scanner whether the PREVIOUS character was itself
# syntactically active — not the raw previous character — exactly the
# `prevact` idiom _bwimc_split_clauses already uses for its own `>` before a
# clobber `|` (that comment: "so an escaped or quoted `>` cannot make the
# following `|` look like a clobber operator"). Using raw `prev` glued
# `echo x \<>@P@/g.txt` (an ESCAPED `<` — bash puts a literal `<` in the
# word, then an UNESCAPED `>` starts a real redirect) into one bogus token,
# which _bwimc_redirect_op_of then ignored entirely: the write vanished.
# Main has no `<` handling at all, never welds anything, and so denies this
# shape correctly by not being clever — our own `<>` glue made it WORSE
# than main. This is the SAME arbiter (_bwimc_scan_step's _BWIMC_ACT) every
# other quote-aware pass already consults; there is no second escape check
# added here, only a second use of the one that exists.
_bwimc_space_before_redirects() {
    local text="$1"
    local out="" i=0 len=${#text} c prev="" prevact="" boundary=0
    local _bwimc_word_alldigit=1
    _bwimc_scan_init
    while [ "$i" -lt "$len" ]; do
        c="${text:$i:1}"
        _bwimc_scan_step "$c"
        if [ "$_BWIMC_ACT" = 1 ] && [ "$c" = '>' ] && [ "$prevact" = '<' ]; then
            out="${out}${c}"
        elif [ "$_BWIMC_ACT" = 1 ] && { [ "$c" = '>' ] || [ "$c" = '<' ]; } \
             && [ "$prevact" = "$c" ]; then
            # A REPEATED ACTIVE operator (`>>`, `<<`) is ONE operator — keep it
            # glued. Round 11 codex-1: this arm must ask `prevact`, not raw
            # `prev`, for exactly the reason the `<>` arm above already does.
            # On raw `prev`, an ESCAPED `>` glued the following REAL `>` to
            # itself: `echo \>>@P@/g.txt` (bash: a literal `>` in the word,
            # then a genuine output redirect) became the single token
            # `\>>@P@/g.txt`, which _bwimc_redirect_op_of does not recognise
            # as a redirect at all — so the primary write vanished and was
            # ALLOWED. An inactive character is not part of an operator, so
            # the active `>` after it must be SPACED OFF, not welded on.
            out="${out}${c}"
        elif [ "$_BWIMC_ACT" = 1 ] && { [ "$c" = '>' ] || [ "$c" = '<' ]; }; then
            # Round 12 audit site B: only ACTIVE whitespace is a word
            # boundary. An ESCAPED or QUOTED space is a literal space INSIDE
            # the word — `echo x\ >@P@/p.txt` is the single word `x ` followed
            # by a REAL output redirect — so reading raw `prev` here said
            # "already spaced", glued the `>` on, and the redirect matcher
            # never saw it: a PLAIN `>` write into the primary was ALLOWED.
            # Start-of-text still asks raw `prev`, and correctly: that arm is
            # about there being no previous character at all, not about
            # whether one was syntactically active.
            boundary=0
            case "$prev" in '') boundary=1 ;; esac
            case "$prevact" in [[:space:]]) boundary=1 ;; esac
            if [ "$boundary" = 1 ] || [ "$_bwimc_word_alldigit" = 1 ]; then
                out="${out}${c}"
            else
                out="${out} ${c}"
            fi
        else
            out="${out}${c}"
        fi
        # Round 12 codex-1 (gate panel): the fd-digit run is a property of
        # the current WORD, so only an ACTIVE character can end or extend it.
        # An inactive one — an escaped space, a quoted digit — is ordinary
        # word text: `echo foo\ 2>@P@/m.txt` is the word `foo 2` then a real
        # redirect, and resetting the run on that literal space kept `2>`
        # glued to it so the anchored matcher missed the write. A QUOTED
        # digit is covered by the same rule and needs no case of its own:
        # `echo "2">@P@/f` is not an fd redirect to bash either.
        if [ "$_BWIMC_ACT" = 1 ]; then
            case "$c" in
                [[:space:]]) _bwimc_word_alldigit=1 ;;
                [0-9]) : ;;
                *) _bwimc_word_alldigit=0 ;;
            esac
        else
            _bwimc_word_alldigit=0
        fi
        prev="$c"
        if [ "$_BWIMC_ACT" = 1 ]; then prevact="$c"; else prevact=""; fi
        i=$((i+1))
    done
    printf '%s' "$out"
}

# Expand a raw candidate token: strip quote chars ONLY at a delimiter position
# (token start/end, or touching a `/`) and expand ~ / ~/ / $HOME / ${HOME}
# prefixes — ported from block-edit-live-settings.sh:369-417 (read + copied,
# not re-derived) so a real path like /home/O'Brien/x keeps its apostrophe.
# After expansion, a token still carrying $, `, *, ?, or [ is DYNAMIC/
# unparseable — fail OPEN on that one candidate (prints nothing, rc 1).
#
# _bwimc_expand_token_raw does the quote-stripping/`~`/`$HOME` expansion WITHOUT
# the dynamic/glob rejection, so _bwimc_glob_prefix below can look at the
# expanded text of a glob token. _bwimc_expand_token is that plus the
# rejection, and is what every ordinary candidate path still calls.
_bwimc_expand_token_raw() {
    local t="$1"
    local Q="\"'"
    t=$(printf '%s' "$t" | sed -E "s/^[$Q]+//; s/[$Q]+\$//; s#/[$Q]+#/#g; s#[$Q]+/#/#g")
    # Trim leading/trailing whitespace and drop a WHITESPACE-ONLY candidate
    # here, before the emptiness check below. Pass A's quoted-operand regex
    # can hand back a lone quoted SPACE straddling two unrelated arguments
    # (`echo "a >" "target"` — the quoted span between the `>` and the next
    # argument is `" "`); without this trim that resolves to `<cwd>/ `, a
    # bogus path that can still walk up to a real repo root and produce a
    # false DENY on an ordinary command. Fail OPEN on this one candidate
    # (return 1), matching every other unparseable-candidate path here —
    # scanning continues on every other candidate in the same command.
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] || return 1
    # shellcheck disable=SC2088,SC2016
    case "$t" in
        '~') t="${HOME:-}" ;;
        '~/'*) t="${HOME:-}/${t:2}" ;;
        '$HOME') t="${HOME:-}" ;;
        '$HOME/'*) t="${HOME:-}/${t:6}" ;;
        '${HOME}') t="${HOME:-}" ;;
        '${HOME}/'*) t="${HOME:-}/${t:8}" ;;
    esac
    [ -n "$t" ] || return 1
    printf '%s' "$t"
}

_bwimc_expand_token() {
    local t
    t=$(_bwimc_expand_token_raw "$1") || return 1
    case "$t" in
        *'$'*|*'`'*|*'*'*|*'?'*|*'['*) return 1 ;;
    esac
    printf '%s' "$t"
}

# _bwimc_glob_prefix RAW — HIMMEL-2592 RETASK rule B. A `glob` operand is not
# a token this extractor may silently DROP: `rm <worktree>/dirlink/*` is
# unresolvable as a whole, yet its directory part traverses `dirlink` and can
# land inside the primary. Echo the operand's LONGEST GLOB-FREE DIRECTORY
# PREFIX (everything up to the last `/` before the first `*`/`?`/`[`, with a
# glob-only token yielding `./` = the cwd), which the caller then checks with
# FOLLOW semantics as a write-through directory. Returns 1 (nothing to check)
# for a token that is not a glob at all, or that is DYNAMIC — a `$VAR`/backtick
# operand still fails open on ITSELF only, per the ratified HIMMEL-2526 §2
# spec. Deliberately NOT "deny any operand containing a glob".
_bwimc_glob_prefix() {
    local t head
    t=$(_bwimc_expand_token_raw "$1") || return 1
    case "$t" in
        *'$'*|*'`'*) return 1 ;;
    esac
    case "$t" in
        *'*'*|*'?'*|*'['*) : ;;
        *) return 1 ;;
    esac
    head="${t%%[*?[]*}"
    case "$head" in
        */*) head="${head%/*}/" ;;
        *) head="./" ;;
    esac
    printf '%s' "$head"
}

# Resolve a raw candidate token to an absolute path against CWD (the TOOL
# PAYLOAD cwd — never the hook process's own $PWD).
_bwimc_resolve_abs() {
    local raw="$1" cwd="$2" expanded
    expanded=$(_bwimc_expand_token "$raw") || return 1
    case "$expanded" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) printf '%s' "$expanded" ;;
        *) printf '%s' "${cwd%/}/$expanded" ;;
    esac
}

# _bwimc_long_opt_name TOKEN — splits a long-option token into its name and
# any attached `=VALUE`. Sets _BWIMC_LOPT_NAME (the part after `--`, before
# any `=`) and _BWIMC_LOPT_VAL (the part after `=`, "" if there was none).
_bwimc_long_opt_name() {
    local tok="$1" rest
    rest="${tok#--}"
    case "$rest" in
        *=*) _BWIMC_LOPT_NAME="${rest%%=*}"; _BWIMC_LOPT_VAL="${rest#*=}" ;;
        *)   _BWIMC_LOPT_NAME="$rest"; _BWIMC_LOPT_VAL="" ;;
    esac
}

# _bwimc_is_long_abbrev FULL TOKEN — HIMMEL-2592 round 5. True iff TOKEN is
# `--P` or `--P=V` where P is a non-empty, case-sensitive PREFIX of FULL (the
# option's full name, no leading `--`). This mirrors how GNU getopt_long
# resolves an unambiguous long-option ABBREVIATION (`--targ` for
# `--target-directory`, `--follow` for `--follow-symlinks`) — enumerating
# spellings cannot cover an abbreviation axis, since it is infinite; matching
# the same RULE getopt_long uses is what makes a further-shortened spelling a
# non-event instead of a sixth special case.
#
# Direction matters: this tests "TOKEN's name is a prefix of FULL", never the
# reverse and never a substring match — `cp --recursive` and `sed -i --posix`
# must not resolve as an abbreviation of anything checked here, because
# neither "recursive" nor "posix" is a PREFIX of any full option name this
# fence cares about (quoting `$_BWIMC_LOPT_NAME` in the case pattern below
# also keeps a glob-metacharacter token, e.g. `--*`, from being interpreted
# as a wildcard).
#
# AMBIGUITY IS THE SAFE DIRECTION (documented, not modelled): a real
# abbreviation genuinely shared by two options (`--no` prefixes both
# `--no-target-directory` and `--no-dereference`; `--f` prefixes both
# `--file` and `--follow-symlinks`) makes GNU refuse it outright — the real
# command fails at the OS level and never writes. This helper does not model
# that refusal: called against one FULL name at a time, it may claim such a
# token for whichever option happens to be checked first. That is harmless,
# but state the reason precisely, because the obvious phrasing is slightly
# too strong. It is NOT that claiming an ambiguous token can only ever add a
# deny: claiming `target-directory` consumes the NEXT token as a DESTINATION,
# so a following operand could be checked in FOLLOW where its own verb would
# have used ENTRY, and that is the weaker of the two checks. The reason it
# cannot matter is upstream of the verdict — GNU refuses the ambiguous
# abbreviation, the command never runs, and NOTHING IS WRITTEN EITHER WAY.
# Whatever this helper decides about such a token describes a command with no
# effect. It is not asked to be more precise than that.
_bwimc_is_long_abbrev() {
    local full="$1" tok="$2"
    _bwimc_long_opt_name "$tok"
    [ -n "$_BWIMC_LOPT_NAME" ] || return 1
    case "$full" in
        "$_BWIMC_LOPT_NAME"*) return 0 ;;
        *) return 1 ;;
    esac
}

# _bwimc_opt_scan TOKEN — the ONE option splitter, shared by every verb arm
# that cares about a semantics-changing flag (HIMMEL-2592 CR round 2). It
# expands BUNDLED short options, because `mv -fT`, `cp -rT`, `ln -sfn` and
# `rm -rf` are all ordinary shapes and a matcher that only recognises a
# standalone `-T` silently misses every bundled form. Every LONG spelling is
# matched via _bwimc_is_long_abbrev (HIMMEL-2592 round 5), so an abbreviation
# of any of them is not a spelling this scanner has to separately enumerate.
#
# It REPORTS what it saw and lets each arm apply its own semantics, because
# the same letter does not mean the same thing to every verb — `-n` is
# `--no-dereference` for `ln` but `--no-clobber` for `cp`/`mv`, and treating
# them alike would false-deny `mv -n` (ground-truthed: it writes THROUGH).
#   _BWIMC_OPT_TDIR   attached `-t` value ("" when none)
#   _BWIMC_OPT_TWANT  1 when a bare `-t` needs the NEXT token as its value
#   _BWIMC_OPT_BIGT   1 when `-T` / `--no-target-directory` (or an
#                     abbreviation of the latter) was seen
#   _BWIMC_OPT_SMALLN 1 when `-n` / `--no-dereference` (or an abbreviation)
#                     was seen
_bwimc_opt_scan() {
    local tok="$1" fl fc
    _BWIMC_OPT_TDIR=""
    _BWIMC_OPT_TWANT=0
    _BWIMC_OPT_BIGT=0
    _BWIMC_OPT_SMALLN=0
    case "$tok" in
        --*)
            if _bwimc_is_long_abbrev "no-target-directory" "$tok"; then
                _BWIMC_OPT_BIGT=1
            elif _bwimc_is_long_abbrev "no-dereference" "$tok"; then
                _BWIMC_OPT_SMALLN=1
            elif _bwimc_is_long_abbrev "target-directory" "$tok"; then
                # HIMMEL-2592 CR round 4, codex-2: the SEPARATED long form
                # takes its value from the NEXT token, exactly like a bare
                # `-t`. Handling only `-t DIR`, `-tDIR` and
                # `--target-directory=DIR` left `--target-directory DIR`
                # unparsed, so the directory fell through as a SOURCE
                # operand and the real destination was never checked —
                # `cp`/`ln -s` in that form created a file inside the
                # primary and were ALLOWED (both verified by running them).
                if [ -n "$_BWIMC_LOPT_VAL" ]; then
                    _BWIMC_OPT_TDIR="$_BWIMC_LOPT_VAL"
                else
                    _BWIMC_OPT_TWANT=1
                fi
            fi
            return 0
            ;;
        -?*) : ;;
        *) return 0 ;;
    esac
    fl="${tok#-}"
    while [ -n "$fl" ]; do
        fc="${fl:0:1}"
        fl="${fl:1}"
        case "$fc" in
            T) _BWIMC_OPT_BIGT=1 ;;
            n) _BWIMC_OPT_SMALLN=1 ;;
            t)
                # `-t` takes a VALUE, so it consumes the rest of the token
                # (`-sft/dir`) or the next one (`-sft /dir`) and ENDS the
                # bundle. Without that stop, a directory value containing
                # `n` or `T` (`-t/home/Tmp`) would be misread as a flag.
                if [ -n "$fl" ]; then _BWIMC_OPT_TDIR="$fl"; else _BWIMC_OPT_TWANT=1; fi
                fl=""
                ;;
        esac
    done
    return 0
}

# _bwimc_mode_for_operand RAW DEFAULT-MODE — HIMMEL-2592 RETASK rule A.
# ENTRY resolution (don't dereference the final-component symlink) is only
# correct when the symlink IS the final path component with NOTHING after it.
# Anything after the link in the RAW token traverses it, so the operation is
# FOLLOW:
#   - a trailing `/`, `/.` or `/..`     — `rm -r <wt>/dirlink/` deletes the
#     REFERENT's contents through the link (verified against the real `rm`),
#     so entry-only resolution there would be a NEW fail-open;
#   - a `/name` or a glob after the link — the final component is then `name`
#     (or the glob prefix), and ancestor canonicalisation already follows the
#     link, so nothing special is needed for those.
# Only the first group needs an explicit override, which is what this does.
_bwimc_mode_for_operand() {
    local raw="$1" mode="$2" t
    if [ "$mode" = entry ]; then
        t="${raw%\"}"; t="${t%\'}"
        case "$t" in
            */|*/.|*/..|.|..) mode="follow" ;;
        esac
    fi
    printf '%s' "$mode"
}

_bwimc_deny() {
    local kind="$1" raw="$2" resolved="$3" repo_root="$4"
    local why=""
    case "$kind" in
        main) why="its repo is on main/master" ;;
        primary-feature) why="its repo is the PRIMARY checkout on a feature branch" ;;
        unreadable) why="its repo's branch state could not be read (failing closed)" ;;
        cannot-canonicalise) why="the target path could not be canonicalised (failing closed)" ;;
        unresolved-git-target) why="a git -C/--git-dir/--work-tree/GIT_* env or cd target could not be resolved (failing closed)" ;;
        repointed-remote) why="it runs a remote operation in a command that repoints a remote (a -c remote/url/protocol/core.sshCommand key, a GIT_CONFIG_COUNT/PARAMETERS/KEY_* env, or git remote add|set-url), which can reach the primary under an innocent name (failing closed)" ;;
    esac
    {
        echo "⛔ block-write-into-main-checkout: refusing a write-shaped command — $why."
        echo "    (command: $cmd)"
        echo "    (target token: $raw)"
        echo "    (resolved target: $resolved)"
        [ -n "$repo_root" ] && echo "    (repo: $repo_root)"
        if [ -n "${_BWIMC_GIT_SUB:-}" ]; then
            echo "    (git subcommand: $_BWIMC_GIT_SUB — rewrites a protected checkout's tree, index, HEAD,"
            echo "     refs or config; HIMMEL-3401. Allowed there: read-only git, fetch <remote>,"
            echo "     pull --ff-only [<remote> [main|master]].)"
        fi
        echo ""
        echo "    Feature work belongs in a worktree per CLAUDE.md, not a write into the"
        echo "    PRIMARY checkout from a Bash/PowerShell-mediated command (HIMMEL-2526) —"
        echo "    the destination-based twin of block-edit-on-main.sh, covering the"
        echo "    redirect/tee/sed -i/cp/mv/rm/touch/ln/git-commit surface that guard,"
        echo "    wired only on Edit|Write|MultiEdit|NotebookEdit, cannot see."
        echo "      - run the command from a type/slug worktree, or"
        if [ -n "$repo_root" ]; then
            echo "      - touch \"$repo_root/.single-writer\" if this repo commits to main by design, or"
        fi
        echo "      - set EDIT_ON_MAIN_OK=1 in the LAUNCHING shell (a per-call prefix cannot"
        echo "        reach a hook process)."
    } >&2
    exit 2
}

# Ask main_checkout_verdict about an ALREADY-CANONICAL path and deny on any
# non-allow verdict. An EMPTY canon means canonicalisation failed (including
# HIMMEL-2597's symlink-hop-cap exhaustion, which returns 1) — fail CLOSED.
_bwimc_check_canon() {
    local canon="$1" raw="$2" abs="$3"
    if [ -z "$canon" ]; then
        _bwimc_deny "cannot-canonicalise" "$raw" "$abs" ""
    fi
    local repo_root vrc
    # codex-2 (HIMMEL-2526): `vrc` MUST be initialised and the command
    # substitution's failure captured with `||`, not a bare trailing `$?` —
    # under `set -e`, a standalone `repo_root=$(cmd)` assignment whose `cmd`
    # exits non-zero fires errexit BEFORE the next statement (`vrc=$?`) ever
    # runs. The EXIT trap still converts that to exit 2 (fail-closed), but
    # every branch below became dead code: a silent rc=2 with no message.
    vrc=0
    repo_root=$(main_checkout_verdict "$canon" 2>/dev/null) || vrc=$?
    case "$vrc" in
        0) return 0 ;;
        1|2)
            # HIMMEL-2946: the deny text below (and _bwimc_cwd_check_sourced's
            # own copy) recommends `touch "$repo_root/.single-writer"` as the
            # opt-out for a repo that commits to main by design — but creating
            # that exact marker IS itself a write on main/primary-feature, so
            # unexempted it refused its own remedy. Exempt ONLY the exact
            # root-level basename; a subdirectory entry or a near-miss name
            # (.single-writer.bak, .single-writerx) still denies.
            if [ -n "$repo_root" ] && [ "$canon" = "$repo_root/.single-writer" ]; then
                return 0
            fi
            if [ "$vrc" = 1 ]; then
                _bwimc_deny "main" "$raw" "$canon" "$repo_root"
            else
                _bwimc_deny "primary-feature" "$raw" "$canon" "$repo_root"
            fi
            ;;
        *) _bwimc_deny "unreadable" "$raw" "$canon" "$repo_root" ;;
    esac
}

# Destination-based check on an already-resolved ABSOLUTE path (case
# preserved). Skips /tmp-ish targets via is_temp_or_devnull (given a
# lowercased copy), then canonicalises + asks main_checkout_verdict. Denies
# (exit 2) on 1/2/3; returns 0 (keep scanning) on 0 or a dropped/unreadable
# candidate that fails open by contract elsewhere.
#
# MODE (HIMMEL-2592, acceptance criterion 2): path resolution is chosen by the
# OPERATION, not by the path.
#   follow — dereference a final-component symlink (the default). Correct for
#            anything writing THROUGH an existing link: a redirect target, a
#            `tee` operand, `touch`, a `cp`/`mv` DESTINATION.
#   entry  — resolve ancestors physically but keep the directory ENTRY itself
#            (guard_canon_path_nofollow). Correct for `rm` (unlinks the entry,
#            never touches the referent), a `mv` SOURCE (rename(2) moves the
#            entry) and an `ln` target (creates an entry).
#   both   — check the referent AND the entry. HIMMEL-2592 round 4: `sed -i`
#            used to route here on the theory that GNU sed's default ENTRY
#            replacement and `--follow-symlinks`' FOLLOW write-through made
#            `both` a safe superset for every `sed -i` invocation. Measured
#            against GNU sed 4.10, that combined claim was wrong: the DEFAULT
#            form is pure entry semantics (referent untouched) and
#            `--follow-symlinks` is pure follow semantics (referent
#            written) — `both` was correct for NEITHER, and denied the
#            default form's write even though it never touches the primary
#            (a false positive). `sed -i` is now flag-driven between `entry`
#            and `follow` (see the sed arm below) and has no remaining
#            caller of `both` here. `both` stays as a documented mode in the
#            contract — the suite may still exercise it directly — rather
#            than being deleted for lack of a current caller.
_bwimc_check_abs() {
    local abs="$1" raw="$2" mode="${3:-follow}"
    local lc canon
    _tolower_ascii "$abs"
    lc="$_TOLOWER_OUT"
    is_temp_or_devnull "$lc" && return 0
    case "$mode" in
        entry|both)
            canon=$(guard_canon_path_nofollow "$abs" 2>/dev/null) || canon=""
            _bwimc_check_canon "$canon" "$raw" "$abs"
            ;;
    esac
    case "$mode" in
        follow|both)
            canon=$(guard_canon_path "$abs" 2>/dev/null) || canon=""
            _bwimc_check_canon "$canon" "$raw" "$abs"
            ;;
    esac
    return 0
}

# _bwimc_check_glob_operand RAW CWD — HIMMEL-2592 RETASK rule B, applied ONLY
# by callers whose operand role WRITES (rm operands, mv SOURCES, cp/mv
# DESTINATIONS, tee targets, redirect targets). A READ role (a `cp` SOURCE)
# must never route through here — `cp <primary>/*.txt <worktree>/` only reads
# the primary and must keep ALLOWing.
_bwimc_check_glob_operand() {
    local raw="$1" cwd="$2" pfx abs
    pfx=$(_bwimc_glob_prefix "$raw") || return 0
    case "$pfx" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs="$pfx" ;;
        *) abs="${cwd%/}/$pfx" ;;
    esac
    _bwimc_check_abs "$abs" "$raw" follow
}

# Destination-based check on a RAW token that still needs expansion +
# resolution against cwd. MODE is the OPERATION's default resolution (see
# _bwimc_check_abs); the operand's own shape can force FOLLOW
# (_bwimc_mode_for_operand). A token that does not resolve statically is not
# dropped silently: a glob falls back to its glob-free prefix, a dynamic
# operand still fails open on itself alone.
_bwimc_check_target() {
    local raw="$1" cwd="$2" mode="${3:-follow}" abs eff
    if ! abs=$(_bwimc_resolve_abs "$raw" "$cwd"); then
        _bwimc_check_glob_operand "$raw" "$cwd"
        return 0
    fi
    eff=$(_bwimc_mode_for_operand "$raw" "$mode")
    _bwimc_check_abs "$abs" "$raw" "$eff"
}

# _bwimc_git_commit_target CLAUSE_SP CWD — HIMMEL-2884: `git … commit` is a
# CWD predicate (see CODEX-LANE PARITY below), but `-C <path>` (repeatable —
# each relative value resolves against the PREVIOUS one, git's own
# semantics) and `--git-dir=<p>`/`--git-dir <p>` redirect the commit at a
# DIFFERENT directory than the session cwd. Walks the tokens between `git`
# and `commit` collecting those and echoes the effective directory the
# commit actually addresses. An unresolvable value (dynamic/glob/empty)
# fails CLOSED to CWD and sets _BWIMC_GIT_TARGET_UNRESOLVED=1 so the caller
# can note it in the deny text.
# Two passes, per git's own semantics (git(1) / codex CR round 1, HIMMEL-2884):
# pass 1 resolves every `-C` cumulatively to a single final base directory;
# pass 2 resolves the LAST `--git-dir` against that FINAL base, regardless of
# where it appears relative to a `-C` on the command line (`git
# --git-dir=a.git -C c status` == `--git-dir=c/a.git status`).
# A standalone `--work-tree=<p>`/`--work-tree <p>` (no `--git-dir`) is
# deliberately NOT modelled as redirecting the target: real git still
# discovers the repository by walking up from cwd in that case — HEAD moves
# in whatever repo cwd resolves to, and `--work-tree` only supplies
# working-tree file content there (verified against real git, codex CR
# round 2, HIMMEL-2884). Only when `--git-dir` is ALSO given does
# `--work-tree` matter at all, and even then `--git-dir` alone determines the
# repository the commit updates, so it always wins.
# Not modelled (deliberately, per the ticket): GIT_DIR/GIT_WORK_TREE env,
# `git -c key=val` (an inert option-with-value the outer regex already
# tolerates), any verb but `commit`.
# Sets globals _BWIMC_GIT_TARGET_DIR and _BWIMC_GIT_TARGET_UNRESOLVED instead
# of echoing — must be called as a plain statement, never via `$(...)`, since
# a command-substitution subshell would discard both globals on exit.
_bwimc_git_commit_target() {
    local clause_sp="$1" cwd="$2"
    local toks=() t tl v r i n dir="$cwd" gitdir_raw=""
    _BWIMC_GIT_TARGET_UNRESOLVED=0
    while IFS= read -r t; do toks+=("$t"); done < <(_bwimc_tokenize "$clause_sp")
    n=${#toks[@]}
    i=1
    while [ "$i" -lt "$n" ]; do
        t="${toks[$i]}"
        _tolower_ascii "$t"
        tl="$_TOLOWER_OUT"
        [ "$tl" = "commit" ] && break
        if [ "$t" = "-C" ]; then
            i=$((i+1)); v="${toks[$i]:-}"
            r=$(_bwimc_resolve_abs "$v" "$dir") && dir="$r" || _BWIMC_GIT_TARGET_UNRESOLVED=1
        # HIMMEL-2949: `--work-tree <p>` (two tokens) must skip its own
        # operand too, exactly like `-C` above — otherwise an operand that
        # happens to equal the literal string "commit" trips the break check
        # one token early and a LATER -C is silently never seen. A standalone
        # --work-tree does not redirect the target itself (see the design
        # note above this function), so only the operand is skipped here.
        elif [ "$t" = "--work-tree" ]; then
            i=$((i+1))
        fi
        i=$((i+1))
    done
    i=1
    while [ "$i" -lt "$n" ]; do
        t="${toks[$i]}"
        _tolower_ascii "$t"
        tl="$_TOLOWER_OUT"
        [ "$tl" = "commit" ] && break
        case "$t" in
            # codex-2 round 4 (HIMMEL-2884): this loop must also skip `-C`'s
            # own operand, exactly like the first loop does — otherwise an
            # operand that happens to equal the literal string "commit" trips
            # the break check above one token early and a LATER --git-dir is
            # silently never seen.
            -C) i=$((i+1)) ;;
            # HIMMEL-2949: same masking risk from `--work-tree`'s own operand.
            --work-tree) i=$((i+1)) ;;
            --git-dir=*) gitdir_raw="${t#--git-dir=}" ;;
            --git-dir) i=$((i+1)); gitdir_raw="${toks[$i]:-}" ;;
        esac
        i=$((i+1))
    done
    if [ -n "$gitdir_raw" ]; then
        r=$(_bwimc_resolve_abs "$gitdir_raw" "$dir") && case "$r" in
            */.git) dir="${r%/.git}" ;;
            *) dir="$r" ;;
        esac || _BWIMC_GIT_TARGET_UNRESOLVED=1
    fi
    [ "$_BWIMC_GIT_TARGET_UNRESOLVED" = 1 ] && dir="$cwd"
    _BWIMC_GIT_TARGET_DIR="$dir"
}

# CODEX-LANE PARITY: byte-identical port of block-terminal-write-fence.sh's
# old inline class-(b) cwd check (its lines 201-229) for the git-commit / PS-
# writer arms. Deny ONLY when the cwd's repo is on main/master; fail OPEN on
# a feature branch or an unreadable branch; honour a repo-root .single-writer
# marker. See this file's CODEX-LANE PARITY header note for why this stays
# separate from the tighter main_checkout_verdict rule used elsewhere.
_bwimc_cwd_check_sourced() {
    local cwd="$1"
    command -v git >/dev/null 2>&1 || return 0
    local branch_rc=0
    is_on_main "$cwd" || branch_rc=$?
    if [ "$branch_rc" -eq 0 ]; then
        local repo_root
        repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
        if [ -z "$repo_root" ] || [ ! -f "$repo_root/.single-writer" ]; then
            {
                echo "⛔ block-terminal-write-fence: refusing a write-shaped terminal command —"
                echo "    the effective repo is checked out on its default branch (main/master)."
                echo "    (command: $cmd)"
                echo "    (cwd: $cwd)"
                echo ""
                echo "    Feature work belongs in a worktree per CLAUDE.md, not on the primary"
                echo "    main checkout (write-on-main class, HIMMEL-745). To proceed:"
                echo "      - run the command from a type/slug worktree, or"
                echo "      - touch \"$repo_root/.single-writer\" if this repo commits to main by design."
            } >&2
            exit 2
        fi
    fi
}

# DIRECT-EXEC (Claude Bash) cwd predicate for `git commit`: the tighter
# main_checkout_verdict rule (main OR primary-feature both deny) — the actual
# HIMMEL-2526 rule, applied here because PowerShell never reaches this mode
# (the Claude wiring adds this script to the Bash matcher only).
_bwimc_cwd_check_direct() {
    _bwimc_check_abs "$1" "cwd:$1 (git commit)"
}

# --------------------------------------------------------------- scan

_bwimc_cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
[ -n "$_bwimc_cwd" ] || _bwimc_cwd="$PWD"

_bwimc_hb=$(_bwimc_blank_heredocs "$cmd")

# ---- (a) redirect / tee, per-clause quote-aware token walk ----
#
# codex-3 (HIMMEL-2526): the OLD implementation ran two whole-command regex
# passes directly over the raw command text (Pass A: a QUOTED operand
# directly after a real operator; Pass B: an UNQUOTED operand after blanking
# every quoted span). Pass A's regex had no concept of quote STATE — a `>`
# sitting INSIDE an unrelated single-quoted argument
# (`echo 'text > "x"'`, no real redirection at all) could still match,
# extracting a phantom target purely because a quoted span happened to
# follow it in the raw text.
#
# codex-4 (HIMMEL-2526): the old Pass B tee scan captured only ONE operand;
# `tee` writes to every file operand it is given.
#
# Fix: tokenize each clause with the already quote-aware `_bwimc_tokenize`
# (a whole quoted span — including any `>` inside it — is ALWAYS one token,
# so it is only ever examined as an operator candidate when a `>` is
# genuinely the first character of a top-level, unquoted token) and walk the
# tokens looking for a redirect operator (optionally fd-prefixed: `>`, `>>`,
# `2>`, `&>`, ... — `2>&1`/`>&2` are recognised and excluded, no file target)
# or `tee` (which then checks every following non-flag token in the clause).
_bwimc_redirect_op_of() {
    # Sets _bwimc_op_rest (may be empty) and _bwimc_op_write (1 output,
    # 0 input), and returns 0 iff TOK starts with a redirect operator;
    # caller resolves the actual target (attached in _bwimc_op_rest, or the
    # NEXT token when it is empty).
    #
    # TWO DISTINCT QUESTIONS (HIMMEL-2592 round 8, panel-mandated split):
    # "is this token a redirect operator, so an operand walk should skip it
    # and its target" is TRUE for input and output alike, and is what every
    # verb arm's operand loop and _bwimc_next_optval_idx need — they only
    # ever SKIP, never inspect direction, and that half of round 6 was
    # correct. "is this token's target a WRITE destination" is TRUE only for
    # output forms and FALSE for input (`<`, `N<`) — conflating the two
    # (round 6 added `<` to this SAME predicate with no direction output)
    # made `cat < <primary>/file`, a pure READ that touches nothing, read as
    # a write and get denied. _bwimc_op_write is how a caller tells them
    # apart; only the (a) redirect-target scan below needs to.
    #
    # HIMMEL-2592: the optional `|` after `>`/`>>` is the CLOBBER form `>|`
    # (paired with _bwimc_split_clauses' rule that such a `|` is not a clause
    # boundary). This predicate is also the single arbiter every operand loop
    # below consults BEFORE treating a token as a filename, so a redirect
    # operator can never be consumed as an operand by the tee/rm/touch/ln/
    # sed -i/cp/mv arms.
    case "$1" in
        *'>'*) : ;;
        *'<'*) : ;;
        *) return 1 ;;
    esac
    if [[ "$1" =~ ^([0-9]*|\&)(\>\>?)(\|?)(.*)$ ]]; then
        _bwimc_op_rest="${BASH_REMATCH[4]}"
        _bwimc_op_write=1
        return 0
    fi
    # HIMMEL-2592 round 6 codex-1: input redirection `<`, added alongside
    # `>` above — same shell-strips-it-before-the-real-command-runs
    # mechanism, ground-truthed against real cp (see
    # _bwimc_space_before_redirects' header). `<` never doubles as its own
    # operator (`<<` is a HEREDOC marker, an unrelated construct) and never
    # takes `>|`'s clobber modifier, so it is its own branch rather than
    # folded into the `>` alternation above — a token containing `<<` is
    # explicitly excluded and left to this file's separate heredoc handling.
    case "$1" in
        *'<<'*) return 1 ;;
    esac
    # HIMMEL-2592 round 10 codex-2: `<>` (optionally fd-prefixed, `N<>`) is
    # bash's READ-WRITE redirect — it opens for BOTH and CREATES the target
    # if missing (ground-truthed: `cat <>newfile` really creates an empty
    # file; `3<>newfile` does too). Checked BEFORE the plain `<` branch
    # below: that branch's regex is `^([0-9]*)(\<)(.*)$`, so on a token like
    # "<>/p/f" it would otherwise capture ">/p/f" as if it were an ordinary
    # (bogus, `>`-prefixed) input target — the write half swallowed by the
    # read half, exactly the round 9 regression this closes. `<>` has no
    # spaced-apart form for the OPERATOR itself — `cat < > file` is a bash
    # SYNTAX ERROR (measured) — so it is always one glued unit by
    # construction; _bwimc_space_before_redirects keeps `<`+`>` glued
    # when adjacent for exactly this reason (see its header). A space is
    # allowed BEFORE the target (`cat <> file` — ground-truthed, works),
    # which is why _bwimc_op_rest can still be empty here, same as every
    # other operator's separate-token-target case.
    if [[ "$1" =~ ^([0-9]*)(\<\>)(.*)$ ]]; then
        _bwimc_op_rest="${BASH_REMATCH[3]}"
        _bwimc_op_write=1
        return 0
    fi
    if [[ "$1" =~ ^([0-9]*)(\<)(.*)$ ]]; then
        _bwimc_op_rest="${BASH_REMATCH[3]}"
        _bwimc_op_write=0
        return 0
    fi
    return 1
}

# _bwimc_skip_redirect_at IDX — shared by the VERB operand loops (b)/(e).
# Those arms have no redirect walk of their own; arm (a) above already scans
# every clause for redirect targets, so a verb loop must neither resolve a
# redirect operator as a filename nor stop collecting at one (bash allows a
# redirect anywhere in a simple command: `rm >log a b` still removes a and b).
# Echoes the index of the next token to examine, skipping the operator and —
# when the target is a SEPARATE token — that token too. Call it only right
# after _bwimc_redirect_op_of matched the token at IDX (it reads the
# _bwimc_op_rest that call set).
_bwimc_skip_redirect_at() {
    local idx="$1"
    idx=$((idx+1))
    [ -n "$_bwimc_op_rest" ] || idx=$((idx+1))
    printf '%s' "$idx"
}

# _bwimc_next_optval_idx IDX — HIMMEL-2592 round 6 codex-1. Finds the index
# of the REAL next option VALUE after position IDX, for every SEPARATED
# option form that unconditionally reads "the next raw token" as its value
# (`-t DIR`, `--target-directory DIR`, and any abbreviation of the latter —
# all of them funnel through _BWIMC_OPT_TWANT). The shell strips a
# redirection BEFORE the real command ever runs, so `-t > /dev/null DIR` is,
# to cp, `-t DIR` — measured via a real snapshot diff: the write lands in
# DIR, not in whatever raw token happened to sit next to `-t`. Reuses the
# file's ONE redirect arbiter (_bwimc_redirect_op_of / _bwimc_skip_redirect_at)
# rather than a second, subtly different recogniser.
#
# HIMMEL-2592 round 9: this function used to ALSO special-case a bare digit
# token immediately before a redirect token (the fd-number
# _bwimc_space_before_redirects used to split off). That split no longer
# happens — a bare fd number now stays glued to its operator in ONE token
# (see that function's header) — so _bwimc_redirect_op_of alone recognises
# `2>/dev/null` as a single unit and this function needs no digit-specific
# branch at all. A synthesised fd token was never an operand anywhere by
# construction now, not by three rounds of per-site skip/tag/discard logic.
#
# Operates on the caller's _bwimc_toks/_bwimc_ntoks — cp/mv and ln both
# already tokenize their clause into those same two global names.
_bwimc_next_optval_idx() {
    local idx=$(( $1 + 1 ))
    while [ "$idx" -lt "$_bwimc_ntoks" ] && _bwimc_redirect_op_of "${_bwimc_toks[$idx]}"; do
        idx=$(_bwimc_skip_redirect_at "$idx")
    done
    printf '%s' "$idx"
}

while IFS= read -r _bwimc_rclause; do
    [ -n "$(printf '%s' "$_bwimc_rclause" | tr -d '[:space:]')" ] || continue
    _bwimc_rclause_sp=$(_bwimc_space_before_redirects "$_bwimc_rclause")
    _bwimc_rtoks=()
    while IFS= read -r _bwimc_t; do _bwimc_rtoks+=("$_bwimc_t"); done < <(_bwimc_tokenize "$_bwimc_rclause_sp")
    _bwimc_rn=${#_bwimc_rtoks[@]}
    # codex-2 (HIMMEL-2526 CR round 4, retasked): anchor `tee` to COMMAND
    # POSITION, but "command position" must mean "the first token that is
    # not a command PREFIX" — not literally index 0. The original
    # unanchored match (any token equal to "tee") was over-broad (the real
    # finding — it let `echo tee README.md` scan "README.md" as a write
    # destination), but it was ALSO incidentally the only thing catching
    # `sudo tee f` / `FOO=1 tee f` / `env tee f`. Anchoring to index 0 threw
    # that coverage away as a silent regression. Fix: walk forward from the
    # clause start skipping (a) environment-assignment tokens (`VAR=value`)
    # and (b) a CLOSED, explicit set of transparent wrapper words — do not
    # generalise this into a heuristic. `sudo`'s `-u`/`--user` also consumes
    # a separate value token (`sudo -u someone tee f`); any other wrapper's
    # flags are skipped but assumed not to take a separate value (env -i,
    # nohup, time, stdbuf -oL — none of the flags used in practice split
    # their value into its own token the way `sudo -u NAME` does). This is
    # deliberately narrower than a general "skip any prefix" rule: the
    # verb-scan arms below (cp/mv/rm/touch/sed) do NOT get this treatment —
    # they already accept the same prefix-blind gap as a documented,
    # pre-existing limitation (see this file's header), so extending it
    # there is new scope, not a regression fix. tee is different because
    # THIS round's own fix is what took its prefix coverage away.
    _bwimc_teecmd=0
    while [ "$_bwimc_teecmd" -lt "$_bwimc_rn" ]; do
        _bwimc_pfx="${_bwimc_rtoks[$_bwimc_teecmd]}"
        if [[ "$_bwimc_pfx" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            _bwimc_teecmd=$((_bwimc_teecmd+1))
            continue
        fi
        case "$_bwimc_pfx" in
            sudo|env|command|nohup|time|stdbuf)
                _bwimc_teecmd=$((_bwimc_teecmd+1))
                while [ "$_bwimc_teecmd" -lt "$_bwimc_rn" ]; do
                    _bwimc_pflag="${_bwimc_rtoks[$_bwimc_teecmd]}"
                    case "$_bwimc_pflag" in
                        -*)
                            _bwimc_teecmd=$((_bwimc_teecmd+1))
                            if [ "$_bwimc_pfx" = "sudo" ] && { [ "$_bwimc_pflag" = "-u" ] || [ "$_bwimc_pflag" = "--user" ]; }; then
                                _bwimc_teecmd=$((_bwimc_teecmd+1))
                            fi
                            ;;
                        *) break ;;
                    esac
                done
                continue
                ;;
            *) break ;;
        esac
    done
    _bwimc_ri=0
    # Per-clause: tee operand collection never leaks across a clause boundary.
    _bwimc_teecollect=0
    _bwimc_tee_dd=0
    while [ "$_bwimc_ri" -lt "$_bwimc_rn" ]; do
        _bwimc_rt="${_bwimc_rtoks[$_bwimc_ri]}"
        if [ "$_bwimc_ri" = "$_bwimc_teecmd" ] && [ "$_bwimc_rt" = "tee" ]; then
            # HIMMEL-2592 CR round 2, codex-1: tee operand collection is a
            # STATE that persists to the end of the clause, not a nested loop.
            # A nested loop has to decide what to do at a redirect operator,
            # and BOTH obvious answers are wrong:
            #   - consume it as a filename  -> `tee /dev/null >/primary/f`
            #     allowed, and `tee /dev/null > /dev/null` false-denied on
            #     the phantom path `<cwd>/>`;
            #   - break out of collection   -> every tee operand AFTER the
            #     redirect is silently dropped, and
            #     `tee /dev/null > /dev/null <primary>/f` is a REAL primary
            #     write (verified by running it) that the fence allowed.
            # Setting a flag instead means the ONE redirect arm below keeps
            # handling — and CHECKING — the redirect target, while operand
            # collection simply resumes after it. That is why this is not a
            # call to _bwimc_skip_redirect_at: the verb arms use that helper
            # because they have no redirect walk of their own, whereas here
            # skipping would throw the target away instead of checking it.
            _bwimc_teecollect=1
            _bwimc_ri=$((_bwimc_ri+1))
            continue
        fi
        if _bwimc_redirect_op_of "$_bwimc_rt"; then
            # HIMMEL-2592 round 8 codex-1: only an OUTPUT redirect's target
            # is a write to check — an input redirect (`<`, `N<`) is a READ
            # that touches nothing (`cat < <primary>/file` must ALLOW).
            # _bwimc_op_write (set by _bwimc_redirect_op_of itself) gates
            # ONLY the check call — the operator AND its target token (when
            # separate) are consumed from the walk EITHER way, same as
            # before: an unconsumed input-redirect target would fall through
            # to the tee-operand branch below and get misread as something
            # tee WRITES, the same false-positive shape one level down.
            if [ -n "$_bwimc_op_rest" ]; then
                case "$_bwimc_op_rest" in
                    '&'*) : ;;  # fd-dup (2>&1, >&2 attached) — no file target
                    *) [ "$_bwimc_op_write" = 1 ] && _bwimc_check_target "$_bwimc_op_rest" "$_bwimc_cwd" ;;
                esac
            else
                _bwimc_ri=$((_bwimc_ri+1))
                if [ "$_bwimc_ri" -lt "$_bwimc_rn" ]; then
                    _bwimc_rt2="${_bwimc_rtoks[$_bwimc_ri]}"
                    case "$_bwimc_rt2" in
                        '&'*) : ;;  # fd-dup (2> &1 — no file target)
                        *) [ "$_bwimc_op_write" = 1 ] && _bwimc_check_target "$_bwimc_rt2" "$_bwimc_cwd" ;;
                    esac
                fi
            fi
            _bwimc_ri=$((_bwimc_ri+1))
        else
            # Not a redirect operator: a tee FILE OPERAND when collection is
            # active — including one that appears AFTER a redirect, which
            # `tee` writes exactly the same way.
            if [ "$_bwimc_teecollect" = 1 ]; then
                # HIMMEL-2592 round 5 codex-1: `--` ends OPTION parsing (see
                # the sed/cp/ln arms' identical comment). `tee -- -o` writes
                # to a file literally named `-o`; without this, `-*` below
                # eats it as a flag and the fence never checks it.
                if [ "$_bwimc_tee_dd" = 1 ]; then
                    _bwimc_check_target "$_bwimc_rt" "$_bwimc_cwd"
                elif [ "$_bwimc_rt" = "--" ]; then
                    _bwimc_tee_dd=1
                else
                    case "$_bwimc_rt" in
                        -*) : ;;
                        *) _bwimc_check_target "$_bwimc_rt" "$_bwimc_cwd" ;;
                    esac
                fi
            fi
            _bwimc_ri=$((_bwimc_ri+1))
        fi
    done
done < <(_bwimc_split_clauses "$_bwimc_hb")

# ---- (g) HIMMEL-3401: git commands that rewrite a PROTECTED checkout ----
#
# WHY: every arm above resolves a FILE operand. A git subcommand writes the
# working tree, index, HEAD, refs or config of whatever repository it is
# aimed at without naming a single file — `git -C <primary> checkout
# <leg-branch> -- f`, `restore --source=…`, `merge`, `pull . <leg>`,
# `read-tree -u -m` — so a worktree-pinned leg could rewrite the PRIMARY
# checkout (the trust anchor: /pr-check hand-off, HIMMEL-3383's byte compare
# and the live hooks all run from it) and every guard returned rc 0.
#
# RULE: an ALLOWLIST, not a denylist. A git clause whose subcommand is
# read-only (below) is never examined. Every OTHER subcommand — the write set
# the ticket names, plus anything unknown, aliases included (`git co`), since
# an alias can expand to any write — has its target resolved and checked with
# the same main_checkout_verdict every other arm uses, applied to the target's
# REPO ROOT (not the -C directory: `-C <primary>/handovers` or `-C
# <primary>/<ignored-dir>` still rewrites the whole primary, while the verdict
# exempts those paths as FILES).
#
# TARGETS: the repository (cumulative -C from the effective cwd, then
# --git-dir / GIT_DIR resolved against the final -C dir, per git(1)), plus
# the work tree (--work-tree / GIT_WORK_TREE) and GIT_INDEX_FILE when given —
# `--work-tree=<primary>` from a leg's own repo writes the primary's files
# even though HEAD moves in the leg's repo. The effective cwd MODELS `cd` /
# `pushd` / `env -C` for THIS arm only (the file-operand arms still resolve
# against the payload cwd, per the header's Known limitations): `cd
# <primary> && git checkout <sha>` is one of the ticket's shapes. A `cd` or
# env value that does not resolve statically (`cd "$X"`, `cd -`, `popd`)
# fails CLOSED for a write-shaped git clause after it, like an unresolved -C.
# Env assignments are read from the clause prefix (`GIT_DIR=… git`, `env
# GIT_DIR=… git`) and from an earlier `export` in the same command.
#
# COMMON-DIR OWNER (HIMMEL-3407): the TARGETS above are resolved to their own
# repo root, which for a LINKED worktree's own cwd (no -C/--git-dir pointed
# elsewhere) is the worktree itself — a legitimate feature checkout that
# ALLOWS, even though a `config`/`remote` write, `branch -u|-f`, or
# `update-ref`/`symbolic-ref` on refs/heads/main|master lands in the
# worktree's SHARED $GIT_COMMON_DIR, which the PRIMARY checkout also reads.
# For exactly those subcommands/flags, the target's OWNING primary checkout
# (`primary_checkout_root`; a no-op for an ordinary non-worktree repo) is
# checked too (`_bwimc_git_check_common_owner`) — so a leg cwd'd into its own
# worktree can no longer repoint the primary's upstream/HEAD-tracked refs by
# omitting `-C <primary>`.
#
# CARVE-OUT (the console's wrap flow, `git -C <primary> pull --ff-only` +
# `fetch`), shape-bounded so it cannot be steered at a leg's commits:
#   pull  — read only with `--ff-only`, flags from a closed list (no
#           --rebase/--autostash), and operands: none (the configured
#           upstream), `<remote>`, or `<remote> main|master`, where <remote>
#           is a bare remote NAME (not `.`, a path or a URL).
#           `pull --ff-only . <leg>` and `pull --ff-only origin <leg-branch>`
#           fast-forward the anchor onto leg commits, so both deny.
#   fetch — read unless -u/--update-head-ok, --upload-pack, --refmap, a
#           non-name repository (`.`, a path, a URL) or a `<src>:<dst>`
#           refspec (which could repoint refs/remotes/origin/main).
# The configured upstream is itself protected: `branch -u/--set-upstream-to`,
# `config` writes and `remote add|set-url|…` are write-shaped here, so the
# console's bare `pull --ff-only` cannot be redirected first.
#
# Mode parity: destination-based in BOTH lanes (main_checkout_verdict), like
# every file-operand arm — EXCEPT `commit` on the sourced/codex lane, which
# keeps HIMMEL-745's is_on_main predicate (CODEX-LANE PARITY, header) and now
# gets the modelled target instead of the payload cwd.
#
# Bypass: EDIT_ON_MAIN_OK=1 in the launching shell, or a repo-root
# `.single-writer` (both honoured inside main_checkout_verdict).
#
# ponytail: command-text scanning, not a shell parser — a git invocation
# displaced behind a wrapper this arm does not strip (sudo, xargs, timeout,
# `sh -c '…'`, an interpreter body) is missed, the same residual as every
# other arm. A `cd` inside a conditional (`false && cd <primary>`) is assumed
# to have run, and a write is ALSO checked from every cwd a cd left, so
# `false && cd <leg>; git merge x` from the primary is still caught; the cost
# is that `cd <leg> && git merge x` typed from the primary is denied too.
# Shared-ref writes from the leg's own worktree (no -C) are checked against
# the common dir's owning primary for `config`/`remote`/`branch -u|-f`/
# `update-ref`/`symbolic-ref` on refs/heads/main|master (HIMMEL-3407, above);
# `tag`, `reflog expire|delete`, and any other branch create/delete/rename are
# still reachable that way — narrower residual, same ticket. `git -c alias.x=…` and repo-level
# hooks are code execution in the leg's own process, not a primary-state
# write, and are out of scope. `worktree move|remove` of the primary is left
# to git itself, which refuses to move or remove a main working tree.
# `git clone`/`init` into a path INSIDE the primary from a leg cwd is not
# modelled. `push` is write-shaped only by DESTINATION: a local path, `.`, a
# `file://` URL or a `--repo=` path that resolves into the primary is denied,
# and so is any `--receive-pack`/`--exec` (it names a program run on the
# receiving side, e.g. `receive.denyCurrentBranch=updateInstead`). A remote
# NAME or a network URL passes; a remote name whose configured URL points at
# the primary is not resolved. A repoint made in the SAME command (-c key,
# GIT_CONFIG_COUNT/PARAMETERS/KEY_* env, `git remote add|set-url`) is
# denied by key name; one made by an earlier, separate command is not seen
# (HIMMEL-3407).

# _bwimc_ansic BODY — the text bash's $'BODY' yields. A code point that is
# NUL or non-ASCII, and a \c control letter, become `?`: none spells a word
# this hook matches. An unknown escape drops its backslash (bash keeps it),
# which only over-classifies.
_bwimc_ansic() {
    local s="$1" o="" c k=0 h v m
    while [ "$k" -lt "${#s}" ]; do
        c="${s:$k:1}"; k=$((k+1))
        if [ "$c" != "\\" ]; then o="$o$c"; continue; fi
        c="${s:$k:1}"; k=$((k+1))
        case "$c" in
            a) v=7 ;; b) v=8 ;; e|E) v=27 ;; f) v=12 ;; n) v=10 ;;
            r) v=13 ;; t) v=9 ;; v) v=11 ;;
            x|u|U)
                case "$c" in x) m=2 ;; u) m=4 ;; *) m=8 ;; esac
                h=""
                while [ "${#h}" -lt "$m" ]; do
                    case "${s:$k:1}" in
                        [0-9A-Fa-f]) h="$h${s:$k:1}"; k=$((k+1)) ;;
                        *) break ;;
                    esac
                done
                if [ -z "$h" ]; then o="$o$c"; continue; fi
                v=$((16#$h)) ;;
            [0-7])
                h="$c"
                while [ "${#h}" -lt 3 ]; do
                    case "${s:$k:1}" in
                        [0-7]) h="$h${s:$k:1}"; k=$((k+1)) ;;
                        *) break ;;
                    esac
                done
                v=$((8#$h)) ;;
            c) k=$((k+1)); o="$o?"; continue ;;
            *) o="$o$c"; continue ;;
        esac
        if [ "$v" -eq 0 ] || [ "$v" -ge 128 ]; then o="$o?"; continue; fi
        # shellcheck disable=SC2059  # the format IS the octal escape
        o="$o$(printf "\\$(printf '%03o' "$v")")"
    done
    printf '%s' "$o"
}

# Quotes are dropped and backslash escapes undone (`\git`, `gi\t`, `\-C`, and
# a backslash-newline line continuation joined), so an escaped spelling
# matches the word the shell runs. ANSI-C `$'…'` is decoded and locale
# `$"…"` read as `"…"` first (`$'\x67it'` runs git). Quote-blind: a backslash
# the shell would keep inside quotes is dropped too, which only
# over-classifies.
_bwimc_unq() {
    local t="$1" o="" c k=0 q
    case "$t" in
        *\$\'*|*\$\"*)
            while [ "$k" -lt "${#t}" ]; do
                c="${t:$k:1}"
                if [ "$c" = '$' ] && [ "${t:$((k+1)):1}" = "'" ]; then
                    k=$((k+2)); q=""
                    while [ "$k" -lt "${#t}" ] && [ "${t:$k:1}" != "'" ]; do
                        if [ "${t:$k:1}" = "\\" ]; then q="$q\\"; k=$((k+1)); fi
                        q="$q${t:$k:1}"; k=$((k+1))
                    done
                    k=$((k+1))
                    o="$o$(_bwimc_ansic "$q")"
                    continue
                fi
                if [ "$c" = '$' ] && [ "${t:$((k+1)):1}" = '"' ]; then k=$((k+1)); continue; fi
                o="$o$c"; k=$((k+1))
            done
            t="$o"; o=""; k=0 ;;
    esac
    t="${t//\"/}"
    t="${t//\'/}"
    t="${t//\`/}"
    case "$t" in
        *\\*)
            t="${t//\\$'\n'/}"
            while [ "$k" -lt "${#t}" ]; do
                c="${t:$k:1}"
                if [ "$c" = "\\" ]; then k=$((k+1)); c="${t:$k:1}"; fi
                o="$o$c"; k=$((k+1))
            done
            t="$o" ;;
    esac
    printf '%s' "$t"
}

# _bwimc_git_push CLAUSE DIR UNRES ARG... — `push` writes only the repository
# it pushes TO, so its destination (not the -C dir) gets the repo-root
# verdict: `.`, a path, a file:// URL, or a bare name that is an existing
# directory. A network URL or scp-like host:path, and a remote name, pass.
# --receive-pack/--exec pick the program run on the receiving side (with
# `receive.denyCurrentBranch=updateInstead` that rewrites a checked-out
# tree), and a `<transport>::` helper runs a command: both fail closed.
_bwimc_git_push() {
    local clause="$1" dir="$2" unres="$3" a want="" d p r dests=() npos=0 ddash=0
    shift 3
    # parse_options permutes, so an option AFTER the destination still counts:
    # scan every argument, and take only the first positional as the repo.
    for a in "$@"; do
        if [ -n "$want" ]; then
            [ "$want" = repo ] && dests+=("$a")
            want=""; continue
        fi
        if [ "$ddash" = 1 ]; then
            [ "$npos" = 0 ] && dests+=("$a")
            npos=$((npos+1)); continue
        fi
        case "$a" in
            --) ddash=1 ;;
            --*)
                if _bwimc_long_is "$a" receive-pack 3 || _bwimc_long_is "$a" exec 2; then
                    _bwimc_deny "unresolved-git-target" "$clause" "$dir" ""
                elif _bwimc_long_is "$a" repo 3; then
                    case "$a" in *=*) dests+=("${a#*=}") ;; *) want=repo ;; esac
                elif _bwimc_long_is "$a" push-option 2; then
                    case "$a" in *=*) ;; *) want=skip ;; esac
                fi ;;
            -o) want=skip ;;
            -*) ;;
            *) [ "$npos" = 0 ] && dests+=("$a"); npos=$((npos+1)) ;;
        esac
    done
    [ "${#dests[@]}" -gt 0 ] || return 0
    for d in "${dests[@]}"; do
        p=""
        case "$d" in
            file://*) p="${d#file://}" ;;
            *::*) _bwimc_deny "unresolved-git-target" "$d" "$dir" "" ;;
            *://*) ;;
            [A-Za-z]:[/\\]*) p="$d" ;;
            *)
                case "${d%%/*}" in
                    *:*) ;;
                    *)
                        if ! _bwimc_remote_name_ok "$d" || [ -d "$dir/$d" ]; then p="$d"; fi ;;
                esac ;;
        esac
        [ -n "$p" ] || continue
        case "$p" in
            /*|[A-Za-z]:*) ;;
            *) [ "$unres" = 1 ] && _bwimc_deny "unresolved-git-target" "$d" "$dir" "" ;;
        esac
        r=$(_bwimc_resolve_abs "$p" "$dir") || _bwimc_deny "unresolved-git-target" "$d" "$dir" ""
        _bwimc_git_check_path "$r" "push destination $d"
    done
}

# _bwimc_long_is ARG NAME MIN — rc 0 when ARG is `--<p>` or `--<p>=…` with <p>
# a prefix of NAME at least MIN long. parse_options takes any unambiguous
# abbreviation (`--receive-p=`, `--refm`), so a deny list keyed on the full
# spelling alone is bypassable. An ambiguous prefix makes git itself refuse,
# so matching it too only over-classifies.
_bwimc_long_is() {
    local p="${1#--}"
    case "$1" in --?*) ;; *) return 1 ;; esac
    p="${p%%=*}"
    [ "${#p}" -ge "$3" ] || return 1
    case "$2" in "$p"*) return 0 ;; esac
    return 1
}

# _bwimc_cfg_key KEY[=VALUE] — flag a config key that repoints where a remote
# operation connects or what it runs there. Judged by name: the value is
# never resolved.
_bwimc_cfg_key() {
    _tolower_ascii "${1%%=*}"
    case "$_TOLOWER_OUT" in
        remote.*.url|remote.*.pushurl|remote.*.receivepack|remote.*.uploadpack|\
        remote.*.vcs|url.*.insteadof|url.*.pushinsteadof|core.sshcommand|protocol.*)
            _bwimc_g_repoint=1 ;;
    esac
}

# A bare remote NAME — not `.`/`..`, a path or a URL.
_bwimc_remote_name_ok() {
    case "$1" in
        ""|.*|*/*|*:*|*\\*) return 1 ;;
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

# _bwimc_git_sub_is_read SUB ARG... — 0 = read-only (skip the clause),
# 1 = write-shaped (check its targets). Args are unquoted, redirects removed.
# _bwimc_short_has ARG LETTERS — rc 0 when ARG is a short-option cluster
# (`-qd`, `-uorigin/x`; never `--long`) carrying any of LETTERS. Letters of an
# attached value count too; that only over-classifies toward a write.
_bwimc_short_has() {
    case "$1" in --*|-) return 1 ;; -*) ;; *) return 1 ;; esac
    local ci=1
    while [ "$ci" -lt "${#1}" ]; do
        case "$2" in *"${1:$ci:1}"*) return 0 ;; esac
        ci=$((ci+1))
    done
    return 1
}

_bwimc_git_sub_is_read() {
    local sub="$1"; shift
    local a npos=0 first="" second="" ff=0 skipval=0
    case "$sub" in
        ""|status|log|diff|show|rev-parse|rev-list|ls-files|ls-tree|ls-remote|\
        cat-file|blame|annotate|grep|describe|shortlog|whatchanged|for-each-ref|\
        merge-base|name-rev|show-ref|show-branch|cherry|range-diff|diff-tree|\
        diff-files|diff-index|var|version|help|check-ignore|check-attr|\
        check-mailmap|check-ref-format|count-objects|fsck|verify-commit|\
        verify-tag|worktree|gc|prune|repack|pack-refs|\
        maintenance|commit-graph|multi-pack-index)
            return 0 ;;
        stash)
            case "${1:-}" in list|show) return 0 ;; esac
            return 1 ;;
        reflog)
            case "${1:-}" in expire|delete|drop|write) return 1 ;; esac
            return 0 ;;
        tag)
            for a in "$@"; do
                case "$a" in
                    -l|--list|--list=*|-v|--verify|--contains*|--no-contains*|\
                    --points-at*|--merged*|--no-merged*) return 0 ;;
                    --*) ;;
                    -*) _bwimc_short_has "$a" lv && return 0 ;;
                    *) npos=$((npos+1)) ;;
                esac
            done
            [ "$npos" = 0 ]; return ;;
        submodule)
            case "${1:-}" in status|summary) return 0 ;; esac
            return 1 ;;
        bisect)
            case "${1:-}" in log|view|visualize) return 0 ;; esac
            return 1 ;;
        notes)
            case "${1:-}" in list|show) return 0 ;; esac
            return 1 ;;
        remote)
            for a in "$@"; do
                case "$a" in
                    -v|--verbose) ;;
                    show|get-url) return 0 ;;
                    *) return 1 ;;
                esac
            done
            return 0 ;;
        branch)
            for a in "$@"; do
                case "$a" in
                    -u|--set-upstream-to|--set-upstream-to=*|--set-upstream|--unset-upstream|\
                    -t|--track|--track=*|-f|--force|-m|-M|--move|-c|-C|--copy|--edit-description|\
                    -d|-D|--delete)
                        return 1 ;;
                    -l|--list|--show-current|--contains*|--no-contains*|--points-at*|--merged*|--no-merged*)
                        return 0 ;;
                    --*) ;;
                    -*) _bwimc_short_has "$a" utfmMcCdD && return 1 ;;
                    *) npos=$((npos+1)) ;;
                esac
            done
            [ "$npos" = 0 ]; return ;;
        symbolic-ref)
            for a in "$@"; do
                if [ "$skipval" = 1 ]; then skipval=0; continue; fi
                _bwimc_short_has "$a" d && return 1
                case "$a" in
                    -d|--delete) return 1 ;;
                    -m) skipval=1 ;;
                    -*) ;;
                    *) npos=$((npos+1)) ;;
                esac
            done
            [ "$npos" -le 1 ]; return ;;
        config)
            case "${1:-}" in
                get|list) return 0 ;;
                set|unset|rename-section|remove-section|edit) return 1 ;;
            esac
            for a in "$@"; do
                if [ "$skipval" = 1 ]; then skipval=0; continue; fi
                _bwimc_short_has "$a" e && return 1
                case "$a" in
                    --get|--get-all|--get-regexp|--get-urlmatch|--get-color|--get-colorbool|-l|--list)
                        return 0 ;;
                    --add|--unset|--unset-all|--replace-all|--rename-section|--remove-section|-e|--edit)
                        return 1 ;;
                    -f|--file|--blob|--type|--default|--comment) skipval=1 ;;
                    -*) ;;
                    *) npos=$((npos+1)) ;;
                esac
            done
            [ "$npos" -le 1 ]; return ;;
        fetch)
            for a in "$@"; do
                case "$a" in
                    -u) return 1 ;;
                    --*)
                        _bwimc_long_is "$a" update-head-ok 2 && return 1
                        _bwimc_long_is "$a" upload-pack 2 && return 1
                        _bwimc_long_is "$a" refmap 3 && return 1
                        ;;
                    -*) _bwimc_short_has "$a" u && return 1 ;;
                    *)
                        npos=$((npos+1))
                        if [ "$npos" = 1 ]; then
                            _bwimc_remote_name_ok "$a" || return 1
                        else
                            case "$a" in *:*) return 1 ;; esac
                        fi
                        ;;
                esac
            done
            return 0 ;;
        pull)
            for a in "$@"; do
                case "$a" in
                    --ff-only) ff=1 ;;
                    -q|--quiet|-v|--verbose|--prune|--no-rebase|--tags|--no-tags|\
                    --stat|--no-stat|-n|--progress|--no-progress) ;;
                    -*) return 1 ;;
                    *)
                        npos=$((npos+1))
                        case "$npos" in
                            1) first="$a" ;;
                            2) second="$a" ;;
                            *) return 1 ;;
                        esac
                        ;;
                esac
            done
            [ "$ff" = 1 ] || return 1
            if [ -n "$first" ]; then
                _bwimc_remote_name_ok "$first" || return 1
            fi
            case "$second" in ""|main|master) return 0 ;; esac
            return 1 ;;
    esac
    return 1
}

# _bwimc_git_check_path PATH LABEL — the repo-ROOT verdict for one target.
_bwimc_git_check_path() {
    local path="$1" label="$2" canon root
    canon=$(guard_canon_path "$path" 2>/dev/null) || canon=""
    if [ -z "$canon" ]; then
        _bwimc_deny "cannot-canonicalise" "$label" "$path" ""
    fi
    root=$(repo_root_for_path "$canon" 2>/dev/null) || return 0
    [ -n "$root" ] || return 0
    if [ "$_bwimc_sourced" = 1 ] && [ "$_BWIMC_GIT_SUB" = commit ]; then
        _bwimc_cwd_check_sourced "$root"
    else
        _bwimc_check_canon "$root" "$label" "$path"
    fi
}

# _bwimc_git_check_common_owner DIR LABEL — HIMMEL-3407. `config`/`remote`
# writes, `branch -u|-f`, and `update-ref`/`symbolic-ref` on
# refs/heads/main|master land in $GIT_COMMON_DIR, which is SHARED by every
# worktree of one repository. Run from a LINKED worktree's own cwd (no `-C`),
# DIR is the worktree itself — repo_root_for_path resolves to the worktree's
# OWN root, a legitimate feature checkout, so _bwimc_git_check_path on DIR
# alone ALLOWS even though the file these subcommands actually write
# ($GIT_COMMON_DIR/config, or a shared ref) lives in the PRIMARY's git
# directory. primary_checkout_root(DIR) resolves that owning checkout — for
# an ordinary, non-worktree repo it is a no-op (returns DIR's own root, git-dir
# == common-dir there), so calling this unconditionally never changes the
# verdict for a plain checkout; it only adds a second, correct target for a
# linked worktree.
_bwimc_git_check_common_owner() {
    local dir="$1" label="$2" owner
    owner=$(primary_checkout_root "$dir" 2>/dev/null) || return 0
    [ -n "$owner" ] || return 0
    _bwimc_git_check_path "$owner" "$label"
}

# _bwimc_git_clause CLAUSE_SP — per-clause state machine for arm (g). Reads
# and updates the command-wide _bwimc_gcwd / _bwimc_gcwd_unres /
# _bwimc_genv_* globals; must be called as a plain statement (never `$(…)`).
_bwimc_git_clause() {
    local toks=() t tu i n start v r
    local dir gitdir="" wtree="" idx="" unres=0 sub="" args=()
    local e_dir="$_bwimc_genv_dir" e_wt="$_bwimc_genv_wt" e_idx="$_bwimc_genv_idx"
    local cfg="$_bwimc_genv_cfg"
    local cwd="$_bwimc_gcwd"
    while IFS= read -r t; do toks+=("$t"); done < <(_bwimc_tokenize "$1")
    n=${#toks[@]}
    # Grouping punctuation and compound-command keywords the clause splitter
    # leaves attached (`if cd <p>; then git merge x; fi`).
    i=0
    while [ "$i" -lt "$n" ]; do
        case "$(_bwimc_unq "${toks[$i]}")" in
            "{"|"!"|"("|""|if|then|else|elif|do|while|until|builtin) i=$((i+1)) ;;
            *) break ;;
        esac
    done
    if [ "$n" -gt 0 ]; then
        t="${toks[$((n-1))]}"
        case "$t" in
            "}"|")") n=$((n-1)) ;;
            *")") toks[n-1]="${t%)}" ;;
        esac
    fi
    [ "$i" -lt "$n" ] || return 0
    tu=$(_bwimc_unq "${toks[$i]}")

    # cd / pushd / popd: move the modelled cwd for later clauses. The cwd it
    # leaves is kept as an alternative: the cd may not have run (`false && cd
    # <leg>; git merge x`) or may have failed, and a write is checked from each.
    case "$tu" in
        cd|pushd|popd)
            [ "$_bwimc_gcwd_unres" = 1 ] || _bwimc_gcwd_alts="$_bwimc_gcwd_alts$_bwimc_gcwd"$'\n' ;;
    esac
    case "$tu" in
        cd|pushd)
            i=$((i+1))
            while [ "$i" -lt "$n" ]; do
                case "$(_bwimc_unq "${toks[$i]}")" in -L|-P|-e|-@) i=$((i+1)) ;; *) break ;; esac
            done
            if [ "$i" -ge "$n" ]; then
                [ -n "${HOME:-}" ] && { _bwimc_gcwd="$HOME"; _bwimc_gcwd_unres=0; } || _bwimc_gcwd_unres=1
            elif [ "$(_bwimc_unq "${toks[$i]}")" = "-" ]; then
                _bwimc_gcwd_unres=1
            elif r=$(_bwimc_resolve_abs "${toks[$i]}" "$cwd"); then
                _bwimc_gcwd="$r"; _bwimc_gcwd_unres=0
            else
                _bwimc_gcwd_unres=1
            fi
            return 0 ;;
        popd) _bwimc_gcwd_unres=1; return 0 ;;
        export|unset)
            local op="$tu"
            i=$((i+1))
            while [ "$i" -lt "$n" ]; do
                t=$(_bwimc_unq "${toks[$i]}")
                if [ "$op" = unset ]; then
                    case "$t" in
                        GIT_DIR) _bwimc_genv_dir="" ;;
                        GIT_WORK_TREE) _bwimc_genv_wt="" ;;
                        GIT_INDEX_FILE) _bwimc_genv_idx="" ;;
                    esac
                else
                    case "${toks[$i]}" in
                        GIT_DIR=*) _bwimc_genv_dir="${toks[$i]#GIT_DIR=}" ;;
                        GIT_WORK_TREE=*) _bwimc_genv_wt="${toks[$i]#GIT_WORK_TREE=}" ;;
                        GIT_INDEX_FILE=*) _bwimc_genv_idx="${toks[$i]#GIT_INDEX_FILE=}" ;;
                        GIT_CONFIG_COUNT*|GIT_CONFIG_PARAMETERS*|GIT_CONFIG_KEY_*)
                            _bwimc_genv_cfg=1; _bwimc_g_repoint=1 ;;
                        GIT_CONFIG*) _bwimc_genv_cfg=1 ;;
                    esac
                fi
                i=$((i+1))
            done
            return 0 ;;
    esac

    # Prefix: VAR=value assignments, `env [-i] [-u N] [-C DIR] [VAR=v]…`,
    # and the transparent `command`/`exec`/`nohup`/`time` words.
    while [ "$i" -lt "$n" ]; do
        t="${toks[$i]}"
        case "$t" in
            GIT_DIR=*) e_dir="${t#GIT_DIR=}" ;;
            GIT_WORK_TREE=*) e_wt="${t#GIT_WORK_TREE=}" ;;
            GIT_INDEX_FILE=*) e_idx="${t#GIT_INDEX_FILE=}" ;;
            GIT_CONFIG_COUNT=*|GIT_CONFIG_PARAMETERS=*|GIT_CONFIG_KEY_*=*) cfg=1; _bwimc_g_repoint=1 ;;
            GIT_CONFIG*=*) cfg=1 ;;
            [A-Za-z_]*=*) ;;
            *)
                case "$(_bwimc_unq "$t")" in
                    env)
                        i=$((i+1))
                        # -i / `-` and -u NAME drop the modelled GIT_* values
                        # (a stale GIT_DIR would point the check at the leg
                        # while git runs on the -C dir); -a/-u/-C take an
                        # operand, attached or not, in any short cluster; -S
                        # re-splits a string we do not re-parse, so a git
                        # inside it fails closed.
                        while [ "$i" -lt "$n" ]; do
                            t=$(_bwimc_unq "${toks[$i]}")
                            local eopt="" eval_="" ci ch
                            case "$t" in
                                -|-i|--ignore-environment) e_dir=""; e_wt=""; e_idx=""; cfg=0 ;;
                                --unset=*) eopt=u; eval_="${t#--unset=}" ;;
                                --unset) eopt=u ;;
                                --chdir=*) eopt=C; eval_="${t#--chdir=}" ;;
                                --chdir) eopt=C ;;
                                --argv0=*) ;;
                                --argv0) i=$((i+1)) ;;
                                --split-string=*) eopt=S; eval_="${t#--split-string=}" ;;
                                --split-string) eopt=S ;;
                                --*) ;;
                                -?*)
                                    ci=1
                                    while [ "$ci" -lt "${#t}" ]; do
                                        ch="${t:$ci:1}"
                                        case "$ch" in
                                            i) e_dir=""; e_wt=""; e_idx="" ;;
                                            u|C|a|S) eopt="$ch"; eval_="${t:$((ci+1))}"; break ;;
                                        esac
                                        ci=$((ci+1))
                                    done ;;
                                GIT_DIR=*) e_dir="${t#GIT_DIR=}" ;;
                                GIT_WORK_TREE=*) e_wt="${t#GIT_WORK_TREE=}" ;;
                                GIT_INDEX_FILE=*) e_idx="${t#GIT_INDEX_FILE=}" ;;
                                GIT_CONFIG_COUNT=*|GIT_CONFIG_PARAMETERS=*|GIT_CONFIG_KEY_*=*)
                                    cfg=1; _bwimc_g_repoint=1 ;;
                                GIT_CONFIG*=*) cfg=1 ;;
                                [A-Za-z_]*=*) ;;
                                *) break ;;
                            esac
                            if [ -n "$eopt" ] && [ -z "$eval_" ]; then
                                i=$((i+1)); eval_=$(_bwimc_unq "${toks[$i]:-}")
                            fi
                            case "$eopt" in
                                u) case "$eval_" in
                                       GIT_DIR) e_dir="" ;;
                                       GIT_WORK_TREE) e_wt="" ;;
                                       GIT_INDEX_FILE) e_idx="" ;;
                                   esac ;;
                                C) if r=$(_bwimc_resolve_abs "$eval_" "$cwd"); then cwd="$r"; else unres=1; fi ;;
                                S) case "$eval_" in
                                       *git*) _bwimc_deny "unresolved-git-target" "$1" "$cwd" "" ;;
                                   esac ;;
                            esac
                            i=$((i+1))
                        done
                        continue ;;
                    command|exec|nohup|time) ;;
                    *) break ;;
                esac
                ;;
        esac
        i=$((i+1))
    done
    [ "$i" -lt "$n" ] || return 0
    tu=$(_bwimc_unq "${toks[$i]}")
    case "${tu##*/}" in
        git|git.exe|GIT|GIT.EXE|Git.exe) ;;
        *) return 0 ;;
    esac
    start=$((i+1))

    # Global options, then the subcommand. Pass 1: cumulative -C.
    dir="$cwd"
    [ "$_bwimc_gcwd_unres" = 1 ] && unres=1
    i=$start
    while [ "$i" -lt "$n" ]; do
        t=$(_bwimc_unq "${toks[$i]}")
        case "$t" in
            -C)
                i=$((i+1))
                if r=$(_bwimc_resolve_abs "${toks[$i]:-}" "$dir"); then dir="$r"; else unres=1; fi ;;
            -c|--config-env) cfg=1; i=$((i+1)); _bwimc_cfg_key "$(_bwimc_unq "${toks[$i]:-}")" ;;
            --config-env=*) cfg=1; _bwimc_cfg_key "${t#--config-env=}" ;;
            -c*) cfg=1; _bwimc_cfg_key "${t#-c}" ;;
            --git-dir|--work-tree|--namespace|--super-prefix) i=$((i+1)) ;;
            -*) ;;
            *) break ;;
        esac
        i=$((i+1))
    done
    # Pass 2: --git-dir / --work-tree (resolved against the FINAL -C dir).
    i=$start
    while [ "$i" -lt "$n" ]; do
        t=$(_bwimc_unq "${toks[$i]}")
        case "$t" in
            -C|-c|--namespace|--config-env|--super-prefix) i=$((i+1)) ;;
            --git-dir=*) gitdir="${toks[$i]#*=}" ;;
            --git-dir) i=$((i+1)); gitdir="${toks[$i]:-}" ;;
            --work-tree=*) wtree="${toks[$i]#*=}" ;;
            --work-tree) i=$((i+1)); wtree="${toks[$i]:-}" ;;
            -*) ;;
            *) sub="$t"; break ;;
        esac
        i=$((i+1))
    done
    i=$((i+1))
    while [ "$i" -lt "$n" ]; do
        t="${toks[$i]}"
        if _bwimc_redirect_op_of "$t"; then
            [ -n "$_bwimc_op_rest" ] || i=$((i+1))
        else
            args+=("$(_bwimc_unq "$t")")
        fi
        i=$((i+1))
    done

    # C1-a: a remote op in a command that also repoints a remote may reach the
    # primary under a name that looks like any other remote. Order-free: the
    # repoint and the op may sit in either clause.
    case "$sub" in
        remote)
            v=""
            for t in ${args[@]+"${args[@]}"}; do
                case "$t" in -*) ;; *) v="$t"; break ;; esac
            done
            case "$v" in add|set-url) _bwimc_g_repoint=1 ;; *) _bwimc_g_netop=1 ;; esac ;;
        push|fetch|pull|ls-remote) _bwimc_g_netop=1 ;;
    esac
    if [ "$_bwimc_g_repoint" = 1 ] && [ "$_bwimc_g_netop" = 1 ]; then
        _BWIMC_GIT_SUB="$sub"
        _bwimc_deny "repointed-remote" "$1" "$dir" ""
    fi

    if [ "$sub" = push ]; then
        _BWIMC_GIT_SUB=push
        [ "$_bwimc_gcwd_unres" = 1 ] && unres=1
        if [ "${#args[@]}" -gt 0 ]; then
            _bwimc_git_push "$1" "$dir" "$unres" "${args[@]}"
        fi
        _BWIMC_GIT_SUB=""
        _bwimc_git_alts "$1"
        return 0
    fi

    # A config override (-c, --config-env, GIT_CONFIG*) can repoint the
    # remote or refspec pull/fetch act on, so it voids their carve-out.
    case "$cfg:$sub" in
        1:pull|1:fetch) ;;
        *)
            if [ "${#args[@]}" -gt 0 ]; then
                _bwimc_git_sub_is_read "$sub" "${args[@]}" && return 0
            else
                _bwimc_git_sub_is_read "$sub" && return 0
            fi ;;
    esac

    _BWIMC_GIT_SUB="$sub"
    [ -n "$gitdir" ] || gitdir="$e_dir"
    [ -n "$wtree" ] || wtree="$e_wt"
    idx="$e_idx"
    if [ "$unres" = 1 ]; then
        _bwimc_deny "unresolved-git-target" "$1" "$dir" ""
    fi
    local gtarget
    if [ -n "$gitdir" ]; then
        r=$(_bwimc_resolve_abs "$gitdir" "$dir") || _bwimc_deny "unresolved-git-target" "$gitdir" "$dir" ""
        _bwimc_git_check_path "$r" "git-dir $gitdir"
        gtarget="$r"
    else
        _bwimc_git_check_path "$dir" "repo $dir"
        gtarget="$dir"
    fi
    # HIMMEL-3407: config/remote writes, branch -u|-f, and update-ref/
    # symbolic-ref on refs/heads/main|master ALSO get checked against the
    # target's owning PRIMARY checkout (see _bwimc_git_check_common_owner) —
    # closing the gap where the target IS a linked worktree, whose own repo
    # root looks like an ordinary feature checkout and allows, while the
    # subcommand actually writes the shared $GIT_COMMON_DIR the worktree and
    # its primary both point at.
    case "$sub" in
        config|remote)
            _bwimc_git_check_common_owner "$gtarget" "$sub clause $1"
            ;;
        branch)
            for v in ${args[@]+"${args[@]}"}; do
                case "$v" in
                    -u|--set-upstream-to|--set-upstream-to=*|--set-upstream|-f|--force)
                        _bwimc_git_check_common_owner "$gtarget" "branch clause $1"
                        break ;;
                    --*) ;;
                    -*)
                        if _bwimc_short_has "$v" uf; then
                            _bwimc_git_check_common_owner "$gtarget" "branch clause $1"
                            break
                        fi ;;
                esac
            done
            ;;
        update-ref|symbolic-ref)
            for v in ${args[@]+"${args[@]}"}; do
                case "$v" in
                    -*) continue ;;
                esac
                case "$v" in
                    refs/heads/main|refs/heads/master)
                        _bwimc_git_check_common_owner "$gtarget" "$sub clause $1" ;;
                esac
                break
            done
            ;;
    esac
    if [ -n "$wtree" ]; then
        r=$(_bwimc_resolve_abs "$wtree" "$dir") || _bwimc_deny "unresolved-git-target" "$wtree" "$dir" ""
        _bwimc_git_check_path "$r" "work-tree $wtree"
    fi
    if [ -n "$idx" ]; then
        r=$(_bwimc_resolve_abs "$idx" "$dir") || _bwimc_deny "unresolved-git-target" "$idx" "$dir" ""
        _bwimc_git_check_path "$r" "index-file $idx"
    fi
    _BWIMC_GIT_SUB=""
    _bwimc_git_alts "$1"
}

# _bwimc_git_alts CLAUSE — re-check a write clause from every cwd an earlier
# `cd` left behind (the cd may not have run).
_bwimc_git_alts() {
    if [ -z "$_bwimc_galt_mode" ] && [ -n "$_bwimc_gcwd_alts" ]; then
        local saved_cwd="$_bwimc_gcwd" saved_unres="$_bwimc_gcwd_unres" alt
        _bwimc_galt_mode=1
        while IFS= read -r alt; do
            [ -n "$alt" ] || continue
            _bwimc_gcwd="$alt"; _bwimc_gcwd_unres=0
            _bwimc_git_clause "$1"
        done <<< "$_bwimc_gcwd_alts"
        _bwimc_gcwd="$saved_cwd"; _bwimc_gcwd_unres="$saved_unres"
        _bwimc_galt_mode=""
    fi
}

_BWIMC_GIT_SUB=""
# A backslash-newline is a line continuation, so `git \<NL>-C <P> …` is ONE
# command. The clause split and the `read` loops below break on every newline,
# so join continuations first. The walk steps over escape pairs, so `\\<NL>`
# (an escaped backslash, then a real newline) still ends the clause.
_bwimc_join_continuations() {
    local t="$1" o="" c n k=0
    case "$t" in *\\*) ;; *) printf '%s' "$t"; return 0 ;; esac
    while [ "$k" -lt "${#t}" ]; do
        c="${t:$k:1}"
        if [ "$c" = "\\" ]; then
            n="${t:$((k+1)):1}"
            k=$((k+2))
            [ "$n" = "$_BWIMC_NL" ] && continue
            o="$o$c$n"
            continue
        fi
        o="$o$c"; k=$((k+1))
    done
    printf '%s' "$o"
}
_bwimc_ghb=$(_bwimc_join_continuations "$_bwimc_hb")
_bwimc_gcwd="$_bwimc_cwd"
_bwimc_gcwd_unres=0
_bwimc_gcwd_alts=""
_bwimc_galt_mode=""
_bwimc_genv_dir=""
_bwimc_genv_wt=""
_bwimc_genv_idx=""
_bwimc_genv_cfg=0
_bwimc_g_repoint=0
_bwimc_g_netop=0
while IFS= read -r _bwimc_clause; do
    [ -n "$(printf '%s' "$_bwimc_clause" | tr -d '[:space:]')" ] || continue
    # A backtick substitution's body is its own command (`$(` is already a
    # clause break). Split quote-blind: a literal backtick inside quotes only
    # yields an extra fragment to classify (toward MORE denies, never fewer).
    _bwimc_gclause=$(_bwimc_space_before_redirects "$_bwimc_clause")
    while IFS= read -r _bwimc_gfrag; do
        _bwimc_git_clause "$_bwimc_gfrag"
    done < <(printf '%s\n' "${_bwimc_gclause//\`/$'\n'}")
done < <(_bwimc_split_clauses "$_bwimc_ghb")

# ---- (b)/(e) per-clause verb scan, command-position anchored ----

while IFS= read -r _bwimc_clause; do
    [ -n "$(printf '%s' "$_bwimc_clause" | tr -d '[:space:]')" ] || continue
    _tolower_ascii "$_bwimc_clause"
    _bwimc_clause_lc="$_TOLOWER_OUT"
    # HIMMEL-2592: the verb arms tokenize the SAME pre-spaced text arm (a)
    # does, so all arms share ONE tokenization and a redirect operator is a
    # token of its own everywhere. Recorded consequence: `cp src >/primary/f`
    # no longer resolves `>/primary/f` as a cp DESTINATION — arm (a) resolves
    # the real redirect target instead, so the coverage is relocated, not
    # lost (probe row: adjudicate6 1d / the cp-redirect row in the suite).
    _bwimc_clause_sp=$(_bwimc_space_before_redirects "$_bwimc_clause")

    # HIMMEL-1430: `grep -E` + capture instead of `grep -q` here and at every
    # verb-scan arm below — under pipefail a multi-line, >64KiB clause can
    # SIGPIPE the producer mid-match and flip the pipeline's exit status,
    # which would fail this fence OPEN on the exact class it exists to catch.
    if _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*sed(\.exe)?[[:space:]]+') && [ -n "$_bwimc_m" ]; then
        # HIMMEL-2592 round 9 codex-3: this used to be
        # `sed(\.exe)?[[:space:]]+.*-i` — an UNANCHORED substring search over
        # the WHOLE clause text, which matched the `-i` inside a PATH
        # (`test-ws5-invariants.sh` contains "-i") and denied a pure read.
        # Confirmed present on `main` before this branch (pre-existing, not
        # introduced here). The arm below already tokenizes and walks its
        # options correctly; the entry test now just recognises the VERB
        # (`sed`, same one-word anchor cp/mv/rm/touch/ln use) and lets the
        # SAME token walk decide in-place-ness via _bwimc_saw_inplace,
        # gating the whole check on it below — a plain `sed -n`/`sed -e`
        # read now walks its tokens, finds no in-place indicator, and
        # checks nothing, exactly like it already fell through to nothing
        # when the old regex (correctly) didn't match at all.
        #
        # sed -i: FILE operands only — the program (unless -e/-f seen) and any
        # -e/-f VALUE are never targets.
        _bwimc_toks=()
        while IFS= read -r _bwimc_t; do _bwimc_toks+=("$_bwimc_t"); done < <(_bwimc_tokenize "$_bwimc_clause_sp")
        _bwimc_n=${#_bwimc_toks[@]}
        _bwimc_saw_ef=0
        _bwimc_saw_follow_symlinks=0
        _bwimc_saw_inplace=0
        _bwimc_bare=()
        _bwimc_dd=0
        _bwimc_i=1
        while [ "$_bwimc_i" -lt "$_bwimc_n" ]; do
            _bwimc_t="${_bwimc_toks[$_bwimc_i]}"
            if _bwimc_redirect_op_of "$_bwimc_t"; then
                _bwimc_i=$(_bwimc_skip_redirect_at "$_bwimc_i")
                continue
            fi
            # HIMMEL-2592 round 5 codex-1: `--` ends OPTION parsing — every
            # token after it is a plain OPERAND, even one shaped like a flag
            # (`sed -i -- -e` really edits a file literally named `-e`). A
            # scanner with no `--` concept keeps reading such a token as
            # `-e`/`--follow-symlinks`/etc, which either eats the REAL next
            # operand as that option's value or silently mis-resolves the
            # mode — this is the FAIL-OPEN the round-5 panel found (on
            # cp/mv/ln; the same gap exists in every arm that classifies a
            # `-*` token, this one included). `--` itself is CONSUMED here,
            # never added as an operand.
            if [ "$_bwimc_dd" = 1 ]; then
                _bwimc_bare+=("$_bwimc_t")
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            if [ "$_bwimc_t" = "--" ]; then
                _bwimc_dd=1
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            case "$_bwimc_t" in
                -e|--expression|-f|--file)
                    _bwimc_saw_ef=1
                    _bwimc_i=$((_bwimc_i+2))
                    continue
                    ;;
                # codex-5 (HIMMEL-2526): the ATTACHED forms (`-e's/a/b/'`,
                # `-fscript.sed`, `--expression=...`, `--file=...`, no space
                # before the program/file) also carry an inline sed program —
                # without recognising these too, `_bwimc_saw_ef` stays 0 and
                # the REAL trailing file operand gets mistaken for "the
                # program" and skipped from the file check below (`-i` itself
                # already takes its own optional attached suffix, `-i.bak`,
                # which the generic `-*` catch-all below already handles).
                -e?*|--expression=*|-f?*|--file=*)
                    _bwimc_saw_ef=1
                    _bwimc_i=$((_bwimc_i+1))
                    continue
                    ;;
                # HIMMEL-2592 §2 (round 4/5): `--follow-symlinks` flips GNU
                # sed -i's resolution mode from ENTRY (default) to FOLLOW —
                # detected in this same option-scanning loop (the one arbiter
                # that already skips redirect operators correctly), not via a
                # separate grep over the raw clause. Matched via the shared
                # _bwimc_is_long_abbrev prefix test (round 5) so an
                # abbreviation (`--follow-sym`, `--follow`) is not a second
                # spelling to enumerate.
                #
                # HIMMEL-2592 round 9 codex-3: `--follow-symlinks` alone,
                # with no `-i`/`--in-place` anywhere, does NOT write
                # (measured against real GNU sed: it prints to stdout, the
                # file is untouched) — so it must NOT set _bwimc_saw_inplace
                # itself; it only records the MODE for when in-place turns
                # out to be active some other way. `--in-place`/
                # `--in-place=SUFFIX`, and any unambiguous ABBREVIATION of
                # it (`--in-pl`, `--in-p`, even bare `--in` — all confirmed
                # against real sed), IS the in-place indicator and is
                # matched via the SAME prefix helper.
                --*)
                    if _bwimc_is_long_abbrev "follow-symlinks" "$_bwimc_t"; then
                        _bwimc_saw_follow_symlinks=1
                    elif _bwimc_is_long_abbrev "in-place" "$_bwimc_t"; then
                        _bwimc_saw_inplace=1
                    fi
                    _bwimc_i=$((_bwimc_i+1))
                    continue
                    ;;
                -*)
                    # HIMMEL-2592 round 9 codex-3 / round 10 codex-1: a
                    # SHORT-option BUNDLE is scanned character by character,
                    # mirroring GNU sed's own bundling rule rather than a
                    # cleverer regex (which would just be wrong on the next
                    # filename). `e`/`f`/`l` are the only OTHER short
                    # options that consume a value; hitting one of them
                    # FIRST means everything after it in THIS token is that
                    # option's value, not a further flag: `-en` is `-e`
                    # with value "n", never in-place, and a LATER `i` in the
                    # same bundle would just be part of that value. Hitting
                    # `i` first means in-place regardless of what follows
                    # (`-nie` -> `-n` then `-i` with backup suffix "e",
                    # ground-truthed: it wrote "f.txte", not a separate
                    # `-e`) — the round-8 panel's own bundled example.
                    #
                    # HIMMEL-2592 round 10 codex-1: `e`/`f` inside a bundle
                    # MUST set _bwimc_saw_ef, exactly like the standalone
                    # `-e`/`-f` forms already do — this round-9 code hit
                    # `e`/`f` and just `break`, so `_bwimc_saw_ef` stayed 0
                    # for `-nes/xxx/yyy/`, and the sole remaining bare token
                    # (the REAL file) was then treated as the IMPLICIT
                    # program and never checked (measured: it emptied the
                    # primary file). Ground-truthed against real GNU sed
                    # before encoding: `-nes/x/y/` attaches the program to
                    # `-e` in the SAME token (no separate value needed);
                    # `-ne 's/x/y/p'` and `-nf script.sed` (bare `e`/`f` at
                    # the END of the bundle, nothing left) take the NEXT
                    # token as their value, same as standalone `-e VALUE`/
                    # `-f VALUE`; `-nfscript.sed` attaches like `-e` does.
                    _bwimc_sed_bundle="${_bwimc_t#-}"
                    while [ -n "$_bwimc_sed_bundle" ]; do
                        case "${_bwimc_sed_bundle:0:1}" in
                            i) _bwimc_saw_inplace=1; break ;;
                            e|f)
                                _bwimc_saw_ef=1
                                _bwimc_sed_bundle="${_bwimc_sed_bundle:1}"
                                # Nothing left in THIS token after e/f -> the
                                # value is the SEPARATE next token; consume
                                # it too (mirrors the standalone `-e|-f`
                                # case's `_bwimc_i+2`, split across this
                                # extra +1 and the unconditional +1 below).
                                [ -z "$_bwimc_sed_bundle" ] && _bwimc_i=$((_bwimc_i+1))
                                break
                                ;;
                            l) break ;;
                        esac
                        _bwimc_sed_bundle="${_bwimc_sed_bundle:1}"
                    done
                    _bwimc_i=$((_bwimc_i+1))
                    continue
                    ;;
                *)
                    _bwimc_bare+=("$_bwimc_t")
                    _bwimc_i=$((_bwimc_i+1))
                    ;;
            esac
        done
        # HIMMEL-2592 round 9 codex-3: NOTHING to check when in-place mode
        # was never seen — a plain `sed -n`/`sed -e` read prints to stdout
        # and touches no file it names (measured against real GNU sed). The
        # entry test above now matches every `sed` invocation, not just
        # in-place ones, precisely so this decision lives HERE, in the same
        # token walk that already parses -e/-f/--follow-symlinks correctly,
        # instead of in a second, separately-maintained regex.
        if [ "$_bwimc_saw_inplace" = 1 ]; then
            _bwimc_start=0
            if [ "$_bwimc_saw_ef" = 0 ] && [ "${#_bwimc_bare[@]}" -ge 1 ]; then
                _bwimc_start=1
            fi
            # HIMMEL-2592 §2 (round 4): resolution mode is chosen by the
            # OPERATION, not the path. GNU sed -i's default replaces the
            # directory ENTRY (`entry`); `--follow-symlinks` writes THROUGH
            # the link (`follow`). Measured with GNU sed 4.10: the default
            # form leaves the referent untouched and replaces the
            # worktree's own entry; `--follow-symlinks` writes the referent
            # and leaves the entry a symlink. `both` is a superset of
            # neither — it is a FALSE POSITIVE on the default form (denies
            # a write that never touches the primary) — so sed never uses
            # `both`.
            _bwimc_sed_mode=entry
            [ "$_bwimc_saw_follow_symlinks" = 1 ] && _bwimc_sed_mode=follow
            _bwimc_k=$_bwimc_start
            while [ "$_bwimc_k" -lt "${#_bwimc_bare[@]}" ]; do
                _bwimc_check_target "${_bwimc_bare[$_bwimc_k]}" "$_bwimc_cwd" "$_bwimc_sed_mode"
                _bwimc_k=$((_bwimc_k+1))
            done
        fi

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*(cp|mv)(\.exe)?[[:space:]]+') && [ -n "$_bwimc_m" ]; then
        _bwimc_verb=$(printf '%s' "$_bwimc_clause_lc" | sed -E 's/^[[:space:]]*(cp|mv).*/\1/')
        _bwimc_toks=()
        while IFS= read -r _bwimc_t; do _bwimc_toks+=("$_bwimc_t"); done < <(_bwimc_tokenize "$_bwimc_clause_sp")
        _bwimc_ops=()
        # codex-6 (HIMMEL-2526): `-t <dir>` / `-t<dir>` / `--target-directory=
        # <dir>` (same option on cp AND mv) name the destination EXPLICITLY —
        # without recognising them, the old code both (a) discarded a
        # SEPARATED `-t`'s value as if it were a generic flag argument, and
        # (b) fell back to "the LAST operand is the destination", silently
        # treating an unrelated trailing argument as the sink while the real
        # (primary-checkout) destination went unchecked entirely. `-T`/
        # `--no-target-directory` (forces the last operand to a non-directory
        # destination even if it exists as a dir) is NOT handled — left as a
        # documented gap, not cheap to fold in here.
        _bwimc_tdir_raw=""
        # HIMMEL-2592 CR round 2 (twin 2): `-T`/`--no-target-directory` makes
        # the destination a plain ENTRY instead of a directory written
        # THROUGH — for `mv` ONLY. Ground truth at
        # `<primary>/dirlink-out -> <worktree>/somedir`: `mv` and `mv -n`
        # write through (allow), `mv -T` and bundled `mv -fT` REPLACE the
        # entry inside the primary (deny), while `cp -T` and `cp -rT` REFUSE
        # (rc=1) and write nothing — so adding a `cp -T` deny "to match" mv
        # would be a pure false positive. `-n` is `--no-clobber` here, NOT
        # `--no-dereference`, which is why _bwimc_opt_scan reports the two
        # separately and this arm consults only the `-T` one.
        _bwimc_nodrf=0
        _bwimc_dd=0
        _bwimc_ntoks=${#_bwimc_toks[@]}
        _bwimc_i=1
        while [ "$_bwimc_i" -lt "$_bwimc_ntoks" ]; do
            _bwimc_t="${_bwimc_toks[$_bwimc_i]}"
            if _bwimc_redirect_op_of "$_bwimc_t"; then
                _bwimc_i=$(_bwimc_skip_redirect_at "$_bwimc_i")
                continue
            fi
            # HIMMEL-2592 round 5 codex-1: `--` ends OPTION parsing (see the
            # sed arm's identical comment for the full finding). `cp --targ
            # DIR -- src dest` must still resolve `--targ DIR` as the
            # destination — `--` only takes effect for tokens AFTER it, so
            # this check runs each iteration, not once before the loop.
            if [ "$_bwimc_dd" = 1 ]; then
                _bwimc_ops+=("$_bwimc_t")
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            if [ "$_bwimc_t" = "--" ]; then
                _bwimc_dd=1
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            case "$_bwimc_t" in
                -*)
                    _bwimc_opt_scan "$_bwimc_t"
                    [ -n "$_BWIMC_OPT_TDIR" ] && _bwimc_tdir_raw="$_BWIMC_OPT_TDIR"
                    [ "$_BWIMC_OPT_BIGT" = 1 ] && _bwimc_nodrf=1
                    if [ "$_BWIMC_OPT_TWANT" = 1 ]; then
                        # HIMMEL-2592 round 6 codex-1: the value is the next
                        # REAL token, skipping any redirection (and its
                        # target) the shell would strip before this command
                        # ever runs — see _bwimc_next_optval_idx's header.
                        _bwimc_i=$(_bwimc_next_optval_idx "$_bwimc_i")
                        [ "$_bwimc_i" -lt "$_bwimc_ntoks" ] && _bwimc_tdir_raw="${_bwimc_toks[$_bwimc_i]}"
                    fi
                    ;;
                *) _bwimc_ops+=("$_bwimc_t") ;;
            esac
            _bwimc_i=$((_bwimc_i+1))
        done
        # `-T` only changes DESTINATION semantics for mv; cp writes nothing.
        [ "$_bwimc_verb" = "mv" ] || _bwimc_nodrf=0
        # INDEPENDENCE (HIMMEL-2592, acceptance criterion 1): operands are
        # COLLECTED with their roles above, then EVERY statically-resolvable
        # one is checked below — never nested inside a sibling's resolution
        # guard. Three earlier rounds each fixed one instance of that nesting
        # by hoisting one check (round 3: the positional destination inside
        # the per-source loop; round 4: the identical defect in the `-t`
        # branch; round 5: the `mv` SOURCE inside the destination guard). The
        # invariant none of them stated, and the reason a fourth hoist would
        # not have prevented a fifth: an operand that cannot be resolved
        # fails open on ITSELF ALONE and never suppresses a sibling's check.
        # DESTINATION resolution is verb- AND type-dependent (HIMMEL-2592 CR
        # round 3, codex-2). Every line below was established by RUNNING the
        # real command against `<x>/link -> <y>/file`, not by reasoning:
        #   destination resolves to a DIRECTORY  -> FOLLOW  (both verbs move/
        #                                           copy INTO it)
        #   mv onto a symlink to a NON-directory -> ENTRY   (rename(2) does
        #                                           NOT follow; it REPLACES
        #                                           the link)
        #   cp onto a symlink to a NON-directory -> FOLLOW  (cp writes
        #                                           THROUGH into the referent)
        #   mv/cp with -T                        -> ENTRY   (see the -T note)
        # `_bwimc_child_mode` is the twin of that rule for the CHILD entry
        # created inside a destination DIRECTORY, and it splits the same way:
        # `mv src <dir>/` REPLACES `<dir>/basename` even when that child is a
        # symlink, while `cp src <dir>/` writes THROUGH it. Both verified.
        # `ln` gets ENTRY for the same reason (round 3, codex-3).
        _bwimc_child_mode=follow
        [ "$_bwimc_verb" = "mv" ] && _bwimc_child_mode=entry
        if [ -n "$_bwimc_tdir_raw" ]; then
            # -t/--target-directory mode: EVERY remaining operand is a
            # SOURCE; the sink for each is <target-dir>/<basename(source)>.
            # `-t`/`--target-directory` name the destination MORE explicitly
            # than the positional form, so it never depends on source parsing.
            _bwimc_dest_abs=$(_bwimc_resolve_abs "$_bwimc_tdir_raw" "$_bwimc_cwd") || _bwimc_dest_abs=""
            if [ -n "$_bwimc_dest_abs" ]; then
                _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_tdir_raw" follow
            else
                _bwimc_check_glob_operand "$_bwimc_tdir_raw" "$_bwimc_cwd"
            fi
            _bwimc_j=0
            while [ "$_bwimc_j" -lt "${#_bwimc_ops[@]}" ]; do
                _bwimc_src_raw="${_bwimc_ops[$_bwimc_j]}"
                _bwimc_src_abs=$(_bwimc_resolve_abs "$_bwimc_src_raw" "$_bwimc_cwd") || _bwimc_src_abs=""
                # mv SOURCE: checked whether or not the DESTINATION resolved
                # (round-5 hoist), with ENTRY semantics — rename(2) moves the
                # directory entry, it never writes through the link.
                if [ "$_bwimc_verb" = "mv" ]; then
                    if [ -n "$_bwimc_src_abs" ]; then
                        _bwimc_check_abs "$_bwimc_src_abs" "$_bwimc_src_raw" \
                            "$(_bwimc_mode_for_operand "$_bwimc_src_raw" entry)"
                    else
                        _bwimc_check_glob_operand "$_bwimc_src_raw" "$_bwimc_cwd"
                    fi
                fi
                if [ -n "$_bwimc_src_abs" ] && [ -n "$_bwimc_dest_abs" ]; then
                    _bwimc_base="${_bwimc_src_abs##*/}"
                    _bwimc_check_abs "${_bwimc_dest_abs%/}/$_bwimc_base" "$_bwimc_tdir_raw" "$_bwimc_child_mode"
                fi
                _bwimc_j=$((_bwimc_j+1))
            done
        else
            _bwimc_n=${#_bwimc_ops[@]}
            if [ "$_bwimc_n" -ge 2 ]; then
                _bwimc_dest_raw="${_bwimc_ops[$((_bwimc_n-1))]}"
                _bwimc_dest_abs=$(_bwimc_resolve_abs "$_bwimc_dest_raw" "$_bwimc_cwd") || _bwimc_dest_abs=""
                _bwimc_dest_is_dir=0
                _bwimc_dest_mode=follow
                if [ -n "$_bwimc_dest_abs" ]; then
                    if [ "$_bwimc_nodrf" = 1 ]; then
                        # mv -T: the destination is the ENTRY, never a
                        # directory written through (see the -T note above).
                        _bwimc_dest_mode=$(_bwimc_mode_for_operand "$_bwimc_dest_raw" entry)
                    else
                        [ -d "$_bwimc_dest_abs" ] && _bwimc_dest_is_dir=1
                        if [ "$_bwimc_dest_is_dir" = 0 ] && [ "$_bwimc_verb" = "mv" ]; then
                            # rename(2) replaces the ENTRY, so a destination
                            # that is a symlink to a NON-directory is written
                            # AT, not through (codex-2, ground-truthed).
                            _bwimc_dest_mode=$(_bwimc_mode_for_operand "$_bwimc_dest_raw" entry)
                        fi
                    fi
                    _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_dest_raw" "$_bwimc_dest_mode"
                else
                    _bwimc_check_glob_operand "$_bwimc_dest_raw" "$_bwimc_cwd"
                fi
                _bwimc_j=0
                while [ "$_bwimc_j" -lt "$((_bwimc_n-1))" ]; do
                    _bwimc_src_raw="${_bwimc_ops[$_bwimc_j]}"
                    _bwimc_src_abs=$(_bwimc_resolve_abs "$_bwimc_src_raw" "$_bwimc_cwd") || _bwimc_src_abs=""
                    if [ "$_bwimc_verb" = "mv" ]; then
                        if [ -n "$_bwimc_src_abs" ]; then
                            _bwimc_check_abs "$_bwimc_src_abs" "$_bwimc_src_raw" \
                                "$(_bwimc_mode_for_operand "$_bwimc_src_raw" entry)"
                        else
                            _bwimc_check_glob_operand "$_bwimc_src_raw" "$_bwimc_cwd"
                        fi
                    fi
                    if [ -n "$_bwimc_src_abs" ] && [ -n "$_bwimc_dest_abs" ] && [ "$_bwimc_nodrf" = 0 ]; then
                        if [ "$_bwimc_dest_is_dir" = 1 ]; then
                            _bwimc_base="${_bwimc_src_abs##*/}"
                            _bwimc_check_abs "${_bwimc_dest_abs%/}/$_bwimc_base" "$_bwimc_dest_raw" "$_bwimc_child_mode"
                        else
                            _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_dest_raw" "$_bwimc_dest_mode"
                        fi
                    fi
                    _bwimc_j=$((_bwimc_j+1))
                done
            fi
        fi

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*(rm|touch)(\.exe)?[[:space:]]+') && [ -n "$_bwimc_m" ]; then
        # rm  -> ENTRY  (unlink removes the directory entry; the referent of a
        #                symlink operand is never touched)
        # touch -> FOLLOW (creates or timestamps the REFERENT)
        # _bwimc_mode_for_operand still forces FOLLOW for an `rm` operand that
        # has anything after the link (`<wt>/dirlink/`, `<wt>/dirlink/.`),
        # because `rm -r` there deletes through the link.
        _bwimc_verb=$(printf '%s' "$_bwimc_clause_lc" | sed -E 's/^[[:space:]]*(rm|touch).*/\1/')
        _bwimc_mode=follow
        [ "$_bwimc_verb" = "rm" ] && _bwimc_mode=entry
        _bwimc_toks=()
        while IFS= read -r _bwimc_t; do _bwimc_toks+=("$_bwimc_t"); done < <(_bwimc_tokenize "$_bwimc_clause_sp")
        _bwimc_dd=0
        _bwimc_i=1
        while [ "$_bwimc_i" -lt "${#_bwimc_toks[@]}" ]; do
            _bwimc_t="${_bwimc_toks[$_bwimc_i]}"
            if _bwimc_redirect_op_of "$_bwimc_t"; then
                _bwimc_i=$(_bwimc_skip_redirect_at "$_bwimc_i")
                continue
            fi
            # HIMMEL-2592 round 5 codex-1: `--` ends OPTION parsing (see the
            # sed arm's identical comment). `rm -- -f` removes a file
            # literally named `-f`; without this, `-*` below eats it as a
            # flag and the fence never checks it.
            if [ "$_bwimc_dd" = 1 ]; then
                _bwimc_check_target "$_bwimc_t" "$_bwimc_cwd" "$_bwimc_mode"
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            if [ "$_bwimc_t" = "--" ]; then
                _bwimc_dd=1
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            case "$_bwimc_t" in
                -*) : ;;
                *) _bwimc_check_target "$_bwimc_t" "$_bwimc_cwd" "$_bwimc_mode" ;;
            esac
            _bwimc_i=$((_bwimc_i+1))
        done

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*ln(\.exe)?[[:space:]]+') && [ -n "$_bwimc_m" ]; then
        # `ln`/`ln -s` CREATES a directory entry (HIMMEL-2592 §2) — the fence
        # had no `ln` arm at all, so `ln -s x <primary>/link` wrote into a
        # protected checkout unseen. Only the LINK NAME is a write; the link
        # TARGET is never touched (it need not even exist), so sources are
        # not checked, exactly as for a `cp` source.
        _bwimc_toks=()
        while IFS= read -r _bwimc_t; do _bwimc_toks+=("$_bwimc_t"); done < <(_bwimc_tokenize "$_bwimc_clause_sp")
        _bwimc_ops=()
        _bwimc_tdir_raw=""
        # HIMMEL-2592 CR round 2, codex-2: `-n`/`--no-dereference` and
        # `-T`/`--no-target-directory` exist precisely to DISABLE the
        # dereference that makes a directory destination FOLLOW. Under either
        # one, `ln` REPLACES a symlink-to-directory destination as a plain
        # ENTRY — verified by running it: at `<primary>/dirlink-out ->
        # <worktree>/somedir`, plain `ln -sf` writes THROUGH into the
        # worktree (allow) while `ln -sfn` and `ln -sfT` replace the entry
        # INSIDE the primary (deny). The finding's own examples are BUNDLED
        # short flags, so the scan below walks a bundle character by
        # character; matching only a standalone `-n` would not close it.
        _bwimc_ln_nodrf=0
        _bwimc_dd=0
        _bwimc_ntoks=${#_bwimc_toks[@]}
        _bwimc_i=1
        while [ "$_bwimc_i" -lt "$_bwimc_ntoks" ]; do
            _bwimc_t="${_bwimc_toks[$_bwimc_i]}"
            if _bwimc_redirect_op_of "$_bwimc_t"; then
                _bwimc_i=$(_bwimc_skip_redirect_at "$_bwimc_i")
                continue
            fi
            # HIMMEL-2592 round 5 codex-1 (THE panel finding): `--` ends
            # OPTION parsing — `ln -s -- -n <wt>/dirlink` creates a link
            # literally NAMED `-n`; without this, `-n` below is read as
            # `--no-dereference`, the destination check is skipped entirely,
            # and the link lands inside whatever `<wt>/dirlink` resolves to
            # (here: the primary). Ground-truthed via a real snapshot diff.
            if [ "$_bwimc_dd" = 1 ]; then
                _bwimc_ops+=("$_bwimc_t")
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            if [ "$_bwimc_t" = "--" ]; then
                _bwimc_dd=1
                _bwimc_i=$((_bwimc_i+1))
                continue
            fi
            case "$_bwimc_t" in
                -*)
                    _bwimc_opt_scan "$_bwimc_t"
                    [ -n "$_BWIMC_OPT_TDIR" ] && _bwimc_tdir_raw="$_BWIMC_OPT_TDIR"
                    # ln is the verb where BOTH letters mean "do not
                    # dereference the destination": `-n`/`--no-dereference`
                    # and `-T`/`--no-target-directory`. (For cp/mv, `-n` is
                    # `--no-clobber` instead — hence the shared splitter
                    # reports the two separately.)
                    if [ "$_BWIMC_OPT_BIGT" = 1 ] || [ "$_BWIMC_OPT_SMALLN" = 1 ]; then
                        _bwimc_ln_nodrf=1
                    fi
                    if [ "$_BWIMC_OPT_TWANT" = 1 ]; then
                        # HIMMEL-2592 round 6 codex-1: the value is the next
                        # REAL token, skipping any redirection (and its
                        # target) the shell would strip before this command
                        # ever runs — see _bwimc_next_optval_idx's header.
                        _bwimc_i=$(_bwimc_next_optval_idx "$_bwimc_i")
                        [ "$_bwimc_i" -lt "$_bwimc_ntoks" ] && _bwimc_tdir_raw="${_bwimc_toks[$_bwimc_i]}"
                    fi
                    ;;
                *) _bwimc_ops+=("$_bwimc_t") ;;
            esac
            _bwimc_i=$((_bwimc_i+1))
        done
        # ENTRY vs FOLLOW for an `ln` destination (HIMMEL-2592 CR codex-2, a
        # REFINEMENT of the §2.1 rule rather than an exception to it): ENTRY
        # is right when the destination IS the entry being created, but a
        # destination that RESOLVES TO A DIRECTORY is written THROUGH —
        # `ln -s src <dir>` creates `<dir>/basename(src)`. That is the same
        # shape as a `cp`/`mv` destination directory, which is already
        # FOLLOW. Verified against the real `ln`: with
        # `<wt>/dirlink -> <primary>/somedir`, `ln -s src <wt>/dirlink`
        # actually creates `<primary>/somedir/src`, i.e. it writes INTO the
        # primary — entry-only resolution there was a fail-OPEN.
        # `-t`/`--target-directory` names a directory explicitly, so it is
        # always FOLLOW, even when the directory does not exist yet.
        _bwimc_n=${#_bwimc_ops[@]}
        _bwimc_dest_raw=""
        _bwimc_ln_isdir=0
        _bwimc_nsrc=0
        if [ -n "$_bwimc_tdir_raw" ]; then
            _bwimc_dest_raw="$_bwimc_tdir_raw"
            _bwimc_ln_isdir=1
            _bwimc_nsrc=$_bwimc_n
        elif [ "$_bwimc_n" -ge 2 ]; then
            _bwimc_dest_raw="${_bwimc_ops[$((_bwimc_n-1))]}"
            _bwimc_nsrc=$((_bwimc_n-1))
        fi
        if [ -n "$_bwimc_dest_raw" ]; then
            _bwimc_dest_abs=$(_bwimc_resolve_abs "$_bwimc_dest_raw" "$_bwimc_cwd") || _bwimc_dest_abs=""
            if [ -z "$_bwimc_dest_abs" ]; then
                _bwimc_check_glob_operand "$_bwimc_dest_raw" "$_bwimc_cwd"
            else
                # `-n`/`-T` turn the destination back into a plain ENTRY even
                # when it resolves to a directory (codex-2). `-t` names a
                # directory explicitly and stays FOLLOW; real `ln` rejects
                # `-t` together with `-T`, so no write happens in that
                # combination and either verdict is safe.
                if [ "$_bwimc_ln_nodrf" = 1 ] && [ -z "$_bwimc_tdir_raw" ]; then
                    _bwimc_ln_isdir=0
                elif [ -d "$_bwimc_dest_abs" ]; then
                    _bwimc_ln_isdir=1
                fi
                if [ "$_bwimc_ln_isdir" = 1 ]; then
                    # Check the directory itself UNCONDITIONALLY (so an
                    # all-unresolvable source list cannot skip it), then the
                    # entry each source creates inside it.
                    _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_dest_raw" follow
                    _bwimc_j=0
                    while [ "$_bwimc_j" -lt "$_bwimc_nsrc" ]; do
                        _bwimc_src_abs=$(_bwimc_resolve_abs "${_bwimc_ops[$_bwimc_j]}" "$_bwimc_cwd") || _bwimc_src_abs=""
                        if [ -n "$_bwimc_src_abs" ]; then
                            _bwimc_base="${_bwimc_src_abs##*/}"
                            # codex-3: `ln` REPLACES the child entry; it does
                            # not write through it. Ground-truthed — the
                            # primary file behind a worktree-local child link
                            # is untouched, so FOLLOW here was a false
                            # positive. The DIRECTORY itself stays FOLLOW,
                            # which is what still catches a dirlink pointing
                            # into the primary (round 1, codex-2).
                            _bwimc_check_abs "${_bwimc_dest_abs%/}/$_bwimc_base" "$_bwimc_dest_raw" entry
                        fi
                        _bwimc_j=$((_bwimc_j+1))
                    done
                else
                    _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_dest_raw" \
                        "$(_bwimc_mode_for_operand "$_bwimc_dest_raw" entry)"
                fi
            fi
        fi
        # DOCUMENTED GAP: the one-operand form (`ln -s <target>`, which links
        # into the CWD under basename(target)) is not modelled — it is the
        # `cd`/cwd-predicate class this script deliberately leaves alone.

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit([[:space:]]|$)') && [ -n "$_bwimc_m" ]; then
        _bwimc_git_commit_target "$_bwimc_clause_sp" "$_bwimc_cwd"
        if [ "$_BWIMC_GIT_TARGET_UNRESOLVED" = 1 ]; then
            # HIMMEL-2884 codex-2: an unresolved -C/--git-dir/--work-tree value
            # must deny outright, not fall back to checking the command's cwd
            # — the cwd's own permission says nothing about where the
            # unresolved value actually points, so falling back false-ALLOWed
            # from any allowed cwd regardless of the real (unverifiable) target.
            _bwimc_deny "unresolved-git-target" "$_bwimc_clause_sp" "$_BWIMC_GIT_TARGET_DIR" ""
        fi
        if [ "$_bwimc_sourced" = 1 ]; then
            _bwimc_cwd_check_sourced "$_BWIMC_GIT_TARGET_DIR"
        else
            _bwimc_cwd_check_direct "$_BWIMC_GIT_TARGET_DIR"
        fi

    elif [ "$_bwimc_sourced" = 1 ] && _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*(set-content|out-file|add-content)([[:space:]]|$)') && [ -n "$_bwimc_m" ]; then
        # PowerShell writers: sourced/codex lane only (see CODEX-LANE PARITY
        # header note) — PowerShell never reaches direct-exec (Claude wires
        # this script on the "Bash" matcher only).
        _bwimc_cwd_check_sourced "$_bwimc_cwd"
    fi
done < <(_bwimc_split_clauses "$_bwimc_hb")

if [ "$_bwimc_sourced" = 1 ]; then
    return 0
else
    exit 0
fi
