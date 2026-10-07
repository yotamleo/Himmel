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
#     `config`/`remote` writes, `branch -u|--unset-upstream|-M|-C|-f`,
#     `checkout -B`/`switch -C` onto main|master, and `update-ref`/
#     `symbolic-ref` on refs/heads/main|master land in the primary's SHARED
#     $GIT_COMMON_DIR. HIMMEL-3407 closes this for exactly those shapes by
#     also checking the target's owning primary checkout
#     (_bwimc_git_check_common_owner) — narrowed to exempt config/remote
#     shapes that do NOT touch the shared repo config at all
#     (--global/--system/--worktree, an -f/--file path outside any repo,
#     remote update/prune/show). Still unmodelled: `tag`/`reflog
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
#     the suite's MIRROR rows. Not modelled: `$'...'` ANSI-C quoting.
#   - Command substitutions (HIMMEL-3622; this bullet used to claim their
#     bodies were scanned as ordinary text, which was false inside a
#     double-quoted span — the scanner treats the whole span as inert, so
#     `x="$(echo hi > P/f)"` wrote into the primary unseen). Now
#     `_bwimc_subst_split` extracts every `$(...)`/backtick body (nested ones
#     by recursion; single-quoted text excluded) and the REDIRECT/tee arm (a)
#     scans each as its own command, right after its clause and from that
#     clause's cwd. Not covered: the verb arms (cp/mv/rm/
#     touch/sed/ln/git) still do not look inside a substitution body, and
#     `$((...))` is treated as arithmetic, never a substitution.
#   - Interpreter bodies: heredoc payloads and `python3 -c '...'` (or any
#     other non-shell `-c`) are NOT parsed for writes — heredoc bodies are
#     blanked before scanning specifically so a `>` inside one (`if a > b:`)
#     cannot produce a phantom target; the PostToolUse dirty-checkout
#     detector (HIMMEL-2526 W3) covers what an interpreter body actually
#     wrote. `eval "..."` and `bash -c`/`sh -c`/`zsh -c "..."` bodies ARE now
#     scanned (HIMMEL-3648, `_bwimc_check_interp_body`) — coarsely: the body
#     is word-split, not clause-parsed, and every non-flag token is run
#     through the same destination check as every other arm, so a dynamic
#     ($VAR, `cmd`) token inside one is the same unresolved-token residual
#     _bwimc_check_target already accepts everywhere else.
#   - HIMMEL-4138: where bash and zsh read a command differently, the hook
#     fails closed instead of picking one reading. (1) A comment (`#` at a
#     word start) can hide a quote from one reading and not the other, so
#     every phase runs twice: once on the text as written and once with its
#     comments stripped (`_bwimc_strip_comments`). It denies if EITHER
#     reading writes into the primary. (2) A `$'…'` span bash and zsh decode
#     differently is denied outright as `shell-ambiguous`: `$$'…\…'` (zsh
#     reads ANSI-C after the second `$`, bash does not), `\x{H}` (bash 5.3
#     decodes it, older bash and zsh do not), and a NUL escape that ends a
#     name before the word does (`_bwimc_ambig_check`). (3) A shell or eval
#     behind a wrapper (`nice`, `timeout 5`, `env FOO=1`, `command eval`,
#     `flock L -c`, ...) has its body scanned like a plain `bash -c` (the
#     `wrap` kind of `_bwimc_check_interp_body`). Known residuals:
#     `script -c` and `env -S` bodies; a `case` item `)` inside `$(…)`.
#     HIMMEL-4143/4145: extra readings (mode 1) carry a newline inside a
#     quoted span as \006, so it does not split a clause, on text whose
#     heredoc bodies inside a dq-quoted `$(…)` are blanked too. The raw
#     readings (mode 0) still run: their line split resyncs the quote scan
#     after a body the blanker cannot parse, so the extra readings only ADD
#     denials. HIMMEL-4153: leading assignment words are skipped before the
#     verb arms read the command word. HIMMEL-4213: so are a leading `{`,
#     `!`, reserved word, `time` and wrapper command (`nice -n 5 touch`,
#     `sudo -u u touch`; `_bwimc_strip_prefix`).
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
#   - A `cd`/`pushd` earlier in the command DOES move the resolution base for
#     arms (a) (redirect/tee) and (b)/(e) (sed/cp/mv/rm/touch/ln/git-commit/
#     install/rsync/dd/eval-bash-c) now (HIMMEL-3648 corrects the bullet this
#     used to be: `_bwimc_ecwd_track` re-tracks it per clause, and
#     `_bwimc_cd_guard` denies a RELATIVE write candidate outright once a
#     `cd`/`pushd` target could not be resolved statically or a `popd` left it
#     unknown). `_bwimc_ecwd_track` has NO model of a nonexistent cd/pushd
#     target, `||`/`&&` short-circuiting, a subshell, a pipeline, a background
#     `&`, an if/while body that never runs, or a `$(...)` command
#     substitution — every one of those can leave the tracked cwd pointing
#     somewhere the cd never actually took the shell (HIMMEL-3648 CR round 9,
#     judge J1307O C1). Rather than model each shape, `_bwimc_cd_guard` closes
#     the gap structurally: whenever the tracked cwd has diverged from the
#     real payload cwd at all, the write candidate is ALSO checked against the
#     real payload cwd, and denied if THAT resolves inside the primary — so
#     cd tracking can only ADD denies relative to a payload-cwd-only check,
#     never remove one, regardless of how wrong its own clause-connective
#     modelling turns out to be (the "strict superset rule"; one documented,
#     deliberate exception: a genuine, unconditional `cd <worktree> &&
#     <relative write>` issued from a primary cwd also denies under this rule,
#     even though it is runtime-safe — the rule does not distinguish "safe"
#     divergence from "unsafe" divergence). The fallback re-checks only the
#     raw operand, so the cp/mv/ln destination-TYPE decisions (dest is a dir
#     vs an entry, entry vs follow) and the `<dest>/<basename(src)>` child
#     check (incl. `-t`) get the same rule separately: each destination block
#     runs against the tracked cwd and, when it diverged, again against the
#     real cwd, denying if either pass denies (judge J1307A F1, closing the
#     HIMMEL-3726 regression). Arm (g) (git subcommands) keeps
#     its own separate, pre-existing `_bwimc_git_clause` tracking, unaffected
#     by this. Not modelled: an absolute or dynamic write candidate is checked
#     against the tracked cwd exactly like before, and a `cd` performed by an
#     EARLIER, separate command (a prior Bash call in the same session) is
#     still invisible — this hook only ever sees one command at a time.
#     Documented bypass: EDIT_ON_MAIN_OK=1 in the LAUNCHING shell.
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
#
# HIMMEL-4010: an UNQUOTED `'` right after an active `$` opens an ANSI-C
# `$'…'` span (_BWIMC_Q = A), where `\` DOES escape — `$'\''` is one complete
# string holding a quote. Read as a plain single-quoted span, its middle `'`
# closed it and the last one opened a span that hid the rest of the command
# (`echo $'\'' > <primary>/f`). _BWIMC_DL is 1 when the previous character was
# an active `$` (not the second `$` of `$$`, the PID); a caller that jumps over a substitution body clears it.
# ponytail: a backslash-newline between `$` and `'` (`$\<LF>'…'`, one ANSI-C
# string to Bash) clears _BWIMC_DL, so it scans as a plain quote; carry the
# state across the continuation (HIMMEL-4133).
_BWIMC_NL=$'\n'
_BWIMC_NLENC=0

_bwimc_scan_init() {
    _BWIMC_Q=""
    _BWIMC_ESC=0
    _BWIMC_ACT=0
    _BWIMC_DL=0
}

_bwimc_scan_step() {
    local c="$1" dl="$_BWIMC_DL"
    _BWIMC_DL=0
    if [ "$_BWIMC_ESC" = 1 ]; then
        _BWIMC_ESC=0
        _BWIMC_ACT=0
        return 0
    fi
    if [ -n "$_BWIMC_Q" ]; then
        if [ "$_BWIMC_Q" != "'" ] && [ "$c" = "\\" ]; then
            _BWIMC_ESC=1
        elif [ "$_BWIMC_Q" = A ]; then
            [ "$c" != "'" ] || _BWIMC_Q=""
        elif [ "$c" = "$_BWIMC_Q" ]; then
            _BWIMC_Q=""
        fi
        _BWIMC_ACT=0
        return 0
    fi
    case "$c" in
        \\) _BWIMC_ESC=1; _BWIMC_ACT=0 ;;
        "'") if [ "$dl" = 1 ]; then _BWIMC_Q=A; else _BWIMC_Q="'"; fi; _BWIMC_ACT=0 ;;
        '"') _BWIMC_Q="$c"; _BWIMC_ACT=0 ;;
        # `$$` is the PID expansion: its second `$` opens nothing
        '$') _BWIMC_ACT=1; [ "$dl" = 1 ] || _BWIMC_DL=1 ;;
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
#
# HIMMEL-4145: with a second argument `nest`, a `$(` inside a double-quoted
# span opens CODE again (bash reads `"$(cat <<'EOF' … EOF )"` as a command
# substitution whose heredoc body is literal), so a `<<` there is an opener
# and its body is blanked — an apostrophe in a commit message can no longer
# open a phantom quote that swallows a later `; touch P/f`. The caller runs
# it as an EXTRA reading beside the flat one, so it can only add denials.
# Anything the nested walk cannot follow with confidence (a comment,
# backtick, `${`, a case/esac word or an unbalanced paren inside the substitution,
# or an opener left unresolved) makes it print the flat reading instead.
# ponytail: a case/esac, comment, backtick or `${` inside that `$(…)` falls
# back to the flat reading, so a body apostrophe there still hides a later
# write as before; count case arms the way _bwimc_subst_paren_end does if a
# real command hits it (HIMMEL-4145).
_bwimc_blank_heredocs() {
    local text="$1" nest="${2:-}"
    local nl=0 unsure=0 ncode=""
    local -a pd=()
    local out="" line
    local active=0 dashmode=0 term="" pend_term="" pend_dash=0
    local i len c prev rest check tab
    local arith_pfx arith_open arith_close arith_scan
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
            if [ -n "$nest" ] && [ "$_BWIMC_Q" = '"' ] && [ "$_BWIMC_ESC" = 0 ] && [ "$c" = '$' ] \
               && [ "${line:$((i+1)):1}" = '(' ] && [ "${line:$((i+2)):1}" != '(' ]; then
                nl=$((nl+1)); pd[nl]=1; _BWIMC_Q=""; _BWIMC_DL=0
                prev='('; i=$((i+2)); continue
            fi
            _bwimc_scan_step "$c"
            [ "$nl" -eq 0 ] || ncode="${ncode}${c}"
            if [ "$nl" -gt 0 ] && [ "$_BWIMC_ACT" = 1 ]; then
                case "$c" in
                    '#'|'`') unsure=1 ;;
                    '(') pd[nl]=$((pd[nl]+1)) ;;
                    ')')
                        pd[nl]=$((pd[nl]-1))
                        if [ "${pd[nl]}" -eq 0 ]; then
                            nl=$((nl-1)); _BWIMC_Q='"'; prev="$c"; i=$((i+1)); continue
                        fi ;;
                esac
            fi
            if [ "$_BWIMC_ACT" = 1 ]; then
                case "$c" in
                    '#')
                        case "$prev" in
                            ''|' '|"$tab"|';'|'&'|'|'|'('|')') break ;;
                        esac
                        ;;
                    '<')
                        if [ "$active" = 0 ] && [ -z "$pend_term" ] && [ "$prev" != '<' ] \
                           && [ "${line:$((i+1)):1}" = '<' ] && [ "${line:$((i+2)):1}" != '<' ]; then
                            # J1285R Minor: `<<` inside an unclosed `((`/`$((`
                            # arithmetic context on this line (`$((1 << n))`,
                            # `(( x = y << z ))`) is a left-shift operator, not
                            # a heredoc opener. Count literal `((`/`))` pairs
                            # in the prefix up to here; an odd (unbalanced,
                            # open) depth means we are still inside one.
                            arith_pfx="${line:0:$i}"
                            arith_open=0; arith_scan="$arith_pfx"
                            while [[ "$arith_scan" == *'(('* ]]; do
                                arith_scan="${arith_scan#*((}"
                                arith_open=$((arith_open+1))
                            done
                            arith_close=0; arith_scan="$arith_pfx"
                            while [[ "$arith_scan" == *'))'* ]]; do
                                arith_scan="${arith_scan#*))}"
                                arith_close=$((arith_close+1))
                            done
                            if [ "$arith_open" -gt "$arith_close" ]; then
                                : # inside arithmetic context — not an opener
                            else
                            rest="${line:$((i+2))}"
                            if [[ "$rest" =~ ^(-)?[[:space:]]*(\"([A-Za-z_][A-Za-z0-9_]*)\"|\'([A-Za-z_][A-Za-z0-9_]*)\'|([A-Za-z_][A-Za-z0-9_]*)) ]]; then
                                term="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
                                if [ -n "${BASH_REMATCH[1]}" ]; then dashmode=1; else dashmode=0; fi
                                active=1
                            fi
                            fi
                        fi
                        ;;
                esac
            fi
            prev="$c"
            i=$((i+1))
        done
        # HIMMEL-2645: an opener that ITSELF ends in a line continuation
        # (`cat <<EOF \` then a newline) is not yet a complete command line —
        # bash joins the next physical line onto it before the command ends,
        # so a real redirect there (`> <primary>/f`) is still COMMAND text,
        # not heredoc body. Defer: un-set `active` and remember the matched
        # term/dashmode in `pend_term`/`pend_dash` instead of letting the
        # very next line be read as body.
        if [ "$active" = 1 ] && [ "$_BWIMC_ESC" = 1 ]; then
            pend_term="$term"
            pend_dash="$dashmode"
            active=0
        elif [ -n "$pend_term" ] && [ "$_BWIMC_ESC" != 1 ]; then
            # The continuation just ended (this line, itself scanned as
            # ordinary command text above, has no trailing backslash): the
            # deferred opener now takes effect and body-blanking starts on
            # the NEXT line. A line that ALSO ends in `\` (chained
            # continuation) falls through here unchanged and stays pending.
            active=1
            term="$pend_term"
            dashmode="$pend_dash"
            pend_term=""
        fi
        # Step the line's own newline through the scanner: a trailing
        # backslash is line continuation, and consuming the newline here is
        # what stops the NEXT line's first character being read as escaped.
        [ "$active" = 1 ] || _bwimc_scan_step "$_BWIMC_NL"
        [ "$nl" -eq 0 ] || ncode="${ncode}"$'\n'
        out="${out}${line}"$'\n'
    done <<< "$text"
    if [ -n "$nest" ]; then
        # shellcheck disable=SC2016  # literal `${` is the glob pattern
        case "$ncode" in *'${'*) unsure=1 ;; esac
        # HIMMEL-4177: case/esac as WORDS only, so `showcase` keeps this reading
        [[ ! "$ncode" =~ (^|[^A-Za-z0-9_])(case|esac)([^A-Za-z0-9_]|$) ]] || unsure=1
        if [ "$unsure" = 1 ] || [ "$nl" -ne 0 ] || [ "$active" = 1 ] || [ -n "$pend_term" ]; then
            _bwimc_blank_heredocs "$text"
            return
        fi
    fi
    # HIMMEL-3621: a heredoc opener whose terminator was never matched
    # (`active=1` at end of input) or whose opener continuation never
    # resolved (`pend_term` still set) means every line since the opener was
    # blindly blanked on a guess that never panned out — a real write after
    # it would be silently hidden. Fail CLOSED instead of returning $out.
    if [ "$active" = 1 ] || [ -n "$pend_term" ]; then
        _bwimc_deny "unresolved-heredoc" "<<${term:-$pend_term} (terminator not found)" "" ""
    fi
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
#
# HIMMEL-3685: ALLOWLIST for trusting a cd. The tracker trusts a cd/pushd/popd
# only as a plain simple command that starts the text or follows `;`, `&&` or a
# newline, in a command that contains none of: a standalone reserved word (`!`
# time coproc if then elif else fi while until for select case esac do done
# function `{` `}` `[[` `]]`), a parenthesis, a single `&` (anything but `&&`
# or a redirect), or a single `|`. Anything else makes the modelled cwd
# UNRESOLVED for the rest of the command (fail closed): _bwimc_text_untrusted
# prescans the whole text and, when it fires, EVERY clause is emitted with a
# leading $_BWIMC_PIPE sentinel byte; every consumer strips it with
# _bwimc_clause_unpipe and passes the flag to _bwimc_ecwd_track. A `||` is not
# itself a disqualifier (`cd W || exit; echo x > a.txt` stays trusted), but a
# clause reached after one is untrusted: the taint turns on there and is sticky.
# Accepted over-deny: any cd after a `||`, any `$(...)`, `echo done`.
# The splitter runs in a process substitution, so the taint travels in the
# line itself, never in a global the caller reads.
# \002, not \001: \001 is _bwimc_subst_split's stub marker, counted per clause.
_BWIMC_PIPE=$'\002'
_bwimc_sp_pipe=0
_bwimc_text_untrusted() {
    local text="$1" i=0 c w="" wq=0 prevact="" nx act
    local len=${#text}
    _bwimc_scan_init
    while [ "$i" -lt "$len" ]; do
        c="${text:$i:1}"
        _bwimc_scan_step "$c"
        act="$_BWIMC_ACT"
        if [ "$act" = 1 ]; then
            case "$c" in
                '('|')') return 0 ;;
                '&')
                    nx="${text:$((i+1)):1}"
                    case "$prevact$nx" in
                        '>'*|'<'*|*'>'|'&'*|*'&') ;;
                        *) return 0 ;;
                    esac
                    ;;
                '|')
                    nx="${text:$((i+1)):1}"
                    if [ "$prevact" != '>' ] && [ "$prevact" != '|' ] && [ "$nx" != '|' ]; then return 0; fi
                    ;;
            esac
            case "$c" in
                [[:space:]]|';'|'&'|'|'|"$_BWIMC_NL")
                    if [ "$wq" = 0 ]; then
                        case "$w" in
                            '!'|time|coproc|if|then|elif|else|"fi"|while|until|for|select|"case"|"esac"|do|"done"|function|'{'|'}'|'[['|']]') return 0 ;;
                        esac
                    fi
                    w=""; wq=0
                    ;;
                *) w="${w}${c}" ;;
            esac
            prevact="$c"
        else
            wq=1; prevact=""
        fi
        i=$((i+1))
    done
    if [ "$wq" = 0 ]; then
        case "$w" in
            '!'|time|coproc|if|then|elif|else|"fi"|while|until|for|select|"case"|"esac"|do|"done"|function|'{'|'}'|'[['|']]') return 0 ;;
        esac
    fi
    return 1
}
_bwimc_split_emit() {
    if [ "$_bwimc_sp_pipe" = 1 ] && [ -n "${1//[[:space:]]/}" ]; then
        printf '%s%s\n' "$_BWIMC_PIPE" "$1"
    else
        printf '%s\n' "$1"
    fi
}
# _bwimc_clause_unpipe VARNAME — strips the sentinel from the clause held in
# VARNAME and sets _bwimc_clause_piped to 1 or 0.
# _bwimc_is_colon CLAUSE — true for a bare `:` clause (a no-op, and what
# _bwimc_flat_mask leaves), which every per-clause arm skips without its
# subshells: nothing in it can write, change the cwd or carry git state.
_bwimc_is_colon() {
    local v="${1#"$_BWIMC_PIPE"}"
    v="${v//[[:space:]]/}"
    [ "$v" = ':' ]
}
_bwimc_clause_unpipe() {
    local _v="${!1}"
    case "$_v" in
        "$_BWIMC_PIPE"*) _bwimc_clause_piped=1; printf -v "$1" '%s' "${_v#"$_BWIMC_PIPE"}" ;;
        *) _bwimc_clause_piped=0 ;;
    esac
}
# _bwimc_arith_end TEXT I — TEXT[I] is the first `(` of `$((`. Succeeds, with
# _BWIMC_AE at the closing `))`'s second `)`, only for PLAIN arithmetic: the
# paren that drops the depth back to 1 is immediately followed by `)`, and
# the span carries no quote, backslash, backtick, `$(`, stub, newline or
# `;&|` — anything else returns 1 and the caller keeps today's break, so
# `$((touch P/f) )` and `$((echo a); touch P/f)` still split (HIMMEL-4153).
_bwimc_arith_end() {
    local t="$1" j=$(($2 + 2)) d=2 n=${#1} ch
    while [ "$j" -lt "$n" ]; do
        ch="${t:$j:1}"
        case "$ch" in
            '(') [ "${t:$((j-1)):1}" != '$' ] || return 1; d=$((d+1)) ;;
            ')')
                d=$((d-1))
                if [ "$d" -eq 1 ]; then
                    [ "${t:$((j+1)):1}" = ')' ] || return 1
                    _BWIMC_AE=$((j+1)); return 0
                fi ;;
            "'"|'"'|\\|'`'|';'|'&'|'|'|$'\001'|$'\005'|$'\n') return 1 ;;
        esac
        j=$((j+1))
    done
    return 1
}
# _bwimc_strip_assign TEXT — sets _BWIMC_SA to TEXT with its leading
# assignment words removed (HIMMEL-4153), so the verb arms' `^verb` anchors
# see the command word: `x=1 touch P/f`, `a[1<<2]=1 touch P/f`,
# `x=$(echo hi) touch P/f` and `x="a b" touch P/f` all reach the touch arm.
# A word counts as an assignment only when it starts NAME[…]?+?= with NAME
# `[A-Za-z_][A-Za-z0-9_]*`; its value runs to the first ACTIVE blank outside
# (), {}, [] and backticks. Stops at the first word that is not one. A word
# that only LOOKS like an assignment changes nothing the shell would not
# also read as one, and an unstripped prefix is today's behaviour.
_bwimc_strip_assign() {
    local t="$1" n=${#1} i=0 j c d bt st pd
    _BWIMC_SA="$t"
    while :; do
        while [ "$i" -lt "$n" ] && { [ "${t:$i:1}" = ' ' ] || [ "${t:$i:1}" = $'\t' ]; }; do i=$((i+1)); done
        j=$i
        case "${t:$j:1}" in [A-Za-z_]) ;; *) return 0 ;; esac
        while [ "$j" -lt "$n" ]; do case "${t:$j:1}" in [A-Za-z0-9_]) j=$((j+1)) ;; *) break ;; esac; done
        if [ "${t:$j:1}" = '[' ]; then
            d=0
            while [ "$j" -lt "$n" ]; do
                c="${t:$j:1}"
                case "$c" in '[') d=$((d+1)) ;; ']') d=$((d-1)) ;; "'"|'"'|\\|'`'|$'\n') return 0 ;; esac
                j=$((j+1))
                [ "$d" -gt 0 ] || break
            done
            [ "$d" -eq 0 ] || return 0
        fi
        [ "${t:$j:1}" != '+' ] || j=$((j+1))
        [ "${t:$j:1}" = '=' ] || return 0
        # Only `(` (array, `$(`, `$((`) and `${` nest in a value; a bare `[`
        # or `{` is a literal (`x=[ touch P/f` runs touch). `st` is the
        # stack of expected closers, so `}` cannot close a `$(`.
        j=$((j+1)); st=""; bt=0; pd=0
        _bwimc_scan_init
        while [ "$j" -lt "$n" ]; do
            c="${t:$j:1}"
            _bwimc_scan_step "$c"
            if [ "$_BWIMC_ACT" = 1 ]; then
                case "$c" in
                    ' '|$'\t') [ -n "$st" ] || [ "$bt" = 1 ] || break ;;
                    '(') st=")$st" ;;
                    '{') [ "$pd" = 0 ] || st="}$st" ;;
                    ')'|'}') [ "${st:0:1}" != "$c" ] || st="${st:1}" ;;
                    '`') bt=$((1 - bt)) ;;
                esac
                # `$$` is the PID: its second `$` opens nothing
                if [ "$c" = '$' ] && [ "$pd" = 0 ]; then pd=1; else pd=0; fi
            else
                pd=0
            fi
            j=$((j+1))
        done
        # an unterminated quote or nesting: leave the text as it was
        if [ -n "$_BWIMC_Q" ] || [ -n "$st" ] || [ "$bt" = 1 ]; then return 0; fi
        i=$j
        _BWIMC_SA="${t:$i}"
    done
}
# _bwimc_assign_flat TEXT — HIMMEL-4198/4174. Sets _BWIMC_AF to TEXT with
# every balanced `$((…))` span and every `NAME=(…)`/`NAME+=(…)` array value
# replaced by `0`, and every backslash-newline joined, outside single quotes.
# The splitter breaks at a `$((` that is not plain arithmetic (so
# `$((echo a); touch P/f)` still splits) and at an array `(`, which hides the
# verb after `x=$((1|2))` or `x=(a b)`. The caller adds the result as an EXTRA
# reading beside the unflattened one, so it can only add denials: the spans'
# own contents are still read where they were. An unclosed span leaves TEXT
# unchanged (no extra reading, today's behaviour).
# HIMMEL-4228: a `${…}` or `$[…]` span holding a separator (`|;&()<>` or a
# newline) becomes `$_`, which stays a dynamic word, so `x=${y:-a|b} touch
# P/f` shows its verb and `cp a ${HOME}/x` is not re-read as a cwd path. A
# bash 5.3 `${ cmd; }`/`${| cmd; }` becomes `$( cmd; )`, so its body is read
# as a command. An unclosed one with a separator after it denies.
_BWIMC_BSNL=$'\\\n'
# _bwimc_brace_end TEXT START OPEN — sets _BWIMC_PEND to the index of the `}`
# (OPEN `{`) or `]` (OPEN `[`) closing the span whose body begins at START;
# a `$(…)` is skipped whole. Like bash, a `$[` counts active nested `[`, a
# `${` only active nested `${` (a bare `{` does not nest: `${y:-a{|b}` ends at
# its first `}`). TEXT length when it never closes. Clobbers the shared
# scanner state — callers save/restore it.
_bwimc_brace_end() {
    local text="$1" j="$2" len=${#1} op="$3" cl=']' d=1 ch sq se sa
    [ "$op" != '{' ] || cl='}'
    _bwimc_scan_init
    while [ "$j" -lt "$len" ]; do
        ch="${text:$j:1}"
        if [ "$ch" = '$' ] && [ "${text:$((j+1)):1}" = '(' ] && [ "$_BWIMC_ESC" != 1 ] \
           && [ "$_BWIMC_Q" != "'" ] && [ "$_BWIMC_Q" != A ]; then
            sq="$_BWIMC_Q"; se="$_BWIMC_ESC"; sa="$_BWIMC_ACT"
            _bwimc_subst_paren_end "$text" $((j+2))
            _BWIMC_Q="$sq"; _BWIMC_ESC="$se"; _BWIMC_ACT="$sa"; _BWIMC_DL=0
            j=$((_BWIMC_PEND+1)); continue
        fi
        _bwimc_scan_step "$ch"
        if [ "$_BWIMC_ACT" = 1 ]; then
            case "$ch" in
                "$cl") d=$((d-1)); [ "$d" -gt 0 ] || break ;;
                '[') [ "$op" != '[' ] || d=$((d+1)) ;;
                '$')
                    if [ "$op" = '{' ] && [ "$_BWIMC_DL" = 1 ] && [ "${text:$((j+1)):1}" = '{' ]; then
                        _bwimc_scan_step '{'; d=$((d+1)); j=$((j+2)); continue
                    fi ;;
            esac
        fi
        j=$((j+1))
    done
    _BWIMC_PEND=$j
}
_bwimc_assign_flat() {
    local t="$1" n=${#1} i=0 c o="" sq se sa st
    _BWIMC_AF="$t"; _BWIMC_AF_CLEAN=1
    # shellcheck disable=SC2016  # literal `$((` is the glob pattern
    case "$t" in *'$(('*|*'=('*|*'${'*|*'$['*|*"$_BWIMC_BSNL"*) ;; *) return 0 ;; esac
    _bwimc_scan_init
    while [ "$i" -lt "$n" ]; do
        c="${t:$i:1}"
        if [ "$_BWIMC_ESC" != 1 ] && [ "$_BWIMC_Q" != "'" ] && [ "$_BWIMC_Q" != A ]; then
            if [ "$c" = "\\" ] && [ "${t:$((i+1)):1}" = "$_BWIMC_NL" ]; then
                _BWIMC_AF_CLEAN=0; i=$((i+2)); continue
            fi
            st=-1
            if [ "$c" = '$' ] && [ "${t:$((i+1)):2}" = '((' ]; then
                st=$((i+2))
            elif [ "$c" = '(' ] && [ -z "$_BWIMC_Q" ] && [ "${o:$((${#o}-1))}" = '=' ] \
                 && [[ "${o:$((${#o} > 64 ? ${#o} - 64 : 0))}" =~ (^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*\+?=$ ]]; then
                st=$((i+1))
            fi
            if [ "$st" -ge 0 ]; then
                sq="$_BWIMC_Q"; se="$_BWIMC_ESC"; sa="$_BWIMC_ACT"
                _bwimc_subst_paren_end "$t" "$st"
                _BWIMC_Q="$sq"; _BWIMC_ESC="$se"; _BWIMC_ACT="$sa"; _BWIMC_DL=0
                [ "$_BWIMC_PEND" -lt "$n" ] || return 0
                _BWIMC_AF_CLEAN=0; o="${o}0"; i=$((_BWIMC_PEND+1)); continue
            fi
            if [ "$c" = '$' ] && [ "$_BWIMC_DL" != 1 ] && { [ "${t:$((i+1)):1}" = '{' ] || [ "${t:$((i+1)):1}" = '[' ]; }; then
                sq="$_BWIMC_Q"; se="$_BWIMC_ESC"; sa="$_BWIMC_ACT"
                _bwimc_brace_end "$t" $((i+2)) "${t:$((i+1)):1}"
                _BWIMC_Q="$sq"; _BWIMC_ESC="$se"; _BWIMC_ACT="$sa"; _BWIMC_DL=0
                if [ "$_BWIMC_PEND" -lt "$n" ] && [ "$sq" = '"' ] \
                   && case "${t:$i:$((_BWIMC_PEND - i + 1))}" in *[\'\"\`]*) true ;; *) false ;; esac; then
                    # a `${` inside "…" holding a quote: _bwimc_brace_end scans it
                    # from the unquoted state, so its end may be wrong. Fail closed:
                    # no flattening, the span reads as written (HIMMEL-4228)
                    _BWIMC_AF_CLEAN=0
                elif [ "$_BWIMC_PEND" -lt "$n" ]; then
                    # a bash 5.3 `${ cmd; }`/`${| cmd; }` runs its body: read it as `$(…)`
                    # shellcheck disable=SC2016
                    case "${t:$i:3}" in
                        '${ '|'${'$'\t'|'${'"$_BWIMC_NL"|'${|')
                            st=$((i+2)); [ "${t:$st:1}" != '|' ] || st=$((st+1))
                            _BWIMC_AF_CLEAN=0
                            o="${o}\$(${t:$st:$((_BWIMC_PEND - st))})"; i=$((_BWIMC_PEND+1)); continue ;;
                    esac
                    case "${t:$i:$((_BWIMC_PEND - i + 1))}" in
                        *[\|\;\&\(\)\<\>]*|*"$_BWIMC_NL"*)
                            # a quote, paren, `#` or backslash inside can scan differently
                            # in the unflattened reading: no masking (_bwimc_flat_mask)
                            case "${t:$i:$((_BWIMC_PEND - i + 1))}" in
                                *[\'\"\\\(\)\#\`]*|*"$_BWIMC_NL"*) _BWIMC_AF_CLEAN=0 ;;
                            esac
                            o="${o}\$_"; i=$((_BWIMC_PEND+1)); continue ;;
                    esac
                else
                    _BWIMC_AF_CLEAN=0
                    # unclosed with a separator after it: no reading of the rest
                    # is safe, fail closed (bash cannot parse it either). Not in
                    # a comment — the comment-free reading gets its own pass.
                    case "${t:$i}" in
                        *[\|\;\&\(\)\<\>]*|*"$_BWIMC_NL"*)
                            _bwimc_strip_comments "$t"
                            [ "$_BWIMC_NC" != "$t" ] || _bwimc_deny "unclosed-expansion" "${t:$i:40}" "" ""
                            _BWIMC_Q="$sq"; _BWIMC_ESC="$se"; _BWIMC_ACT="$sa"; _BWIMC_DL=0 ;;
                    esac
                fi
            fi
        fi
        _bwimc_scan_step "$c"
        o="$o$c"; i=$((i+1))
    done
    _BWIMC_AF="$o"
}
# _bwimc_flat_mask ORIG — HIMMEL-4213 (latency): the flattened reading
# (_BWIMC_AF) is scanned in full a second time, which doubled the hook's cost.
# When every change was a quote-, paren-, `#`- and backslash-free `${…}`/`$[…]`
# span (_BWIMC_AF_CLEAN) and ORIG has no `#`, `<<`, backtick, cd, pushd or popd,
# every plain-word command (letters, digits, `_./:,+@%-` only, no reserved
# word or shell-state builtin, and `git` only as `git [-C DIR|--no-pager|-P]
# <read-only subcommand>`, which sets no git-arm state) between two active
# separators scans with the same quote, comment, heredoc, cwd and git state
# in both readings — the unflattened reading already read it. Such a command
# becomes `:` in _BWIMC_AF (skipped by every arm: _bwimc_is_colon); every
# other command, separator and redirect stays as it was.
_BWIMC_FM_RE='^[[:space:]]*[A-Za-z0-9_./:,+@%-]+([[:space:]]+[A-Za-z0-9_./:,+@%-]+)*[[:space:]]*$'
_BWIMC_FM_RW=' if then else elif fi do done case esac while until for select function in coproc export unset declare typeset readonly local alias unalias set shopt source . eval exec builtin enable hash trap '
_BWIMC_FM_GITRO=' log status diff show rev-parse ls-files describe blame shortlog cat-file rev-list '
_bwimc_flat_mask() {
    local t="$_BWIMC_AF" n=${#_BWIMC_AF} i=0 c o="" seg="" prev="" w sl keep g
    [ "$_BWIMC_AF_CLEAN" = 1 ] || return 0
    _tolower_ascii "$1"
    # shellcheck disable=SC2016
    case "$_TOLOWER_OUT" in *'#'*|*'<<'*|*'`'*|*cd*|*pushd*|*popd*) return 0 ;; esac
    _bwimc_scan_init
    while [ "$i" -le "$n" ]; do
        c="${t:$i:1}"
        if [ "$i" -lt "$n" ]; then
            _bwimc_scan_step "$c"
            if [ "$_BWIMC_ACT" != 1 ] || [ -n "$_BWIMC_Q" ]; then
                seg="$seg$c"; i=$((i+1)); continue
            fi
            case "$c$prev" in
                ';'*|'&'[!\<\>]|'&'|'|'[!\>]|'|'|"$_BWIMC_NL"*) ;;
                *) [[ "$c" =~ [[:space:]] ]] || prev="$c"; seg="$seg$c"; i=$((i+1)); continue ;;
            esac
        fi
        # end of a command: mask it when plain
        keep=1
        if [[ "$seg" =~ $_BWIMC_FM_RE ]]; then
            _tolower_ascii "$seg"; sl="$_TOLOWER_OUT"; keep=0
            g=0
            case "$sl" in *git*) g=1 ;; esac
            for w in $sl; do
                case "$_BWIMC_FM_RW" in *" $w "*) keep=1 ;; esac
            done
            if [ "$g" = 1 ]; then
                # the git words as written: `-C DIR` is not `-c NAME`
                for w in $seg; do
                    case "$g" in
                        1) _tolower_ascii "$w"; [ "$_TOLOWER_OUT" = git ] && g=2 || keep=1 ;;
                        2) case "$w" in
                               -C) g=3 ;;
                               --no-pager|-P|-p) ;;
                               *) case "$_BWIMC_FM_GITRO" in *" $w "*) g=4 ;; *) keep=1 ;; esac ;;
                           esac ;;
                        3) g=2 ;;
                    esac
                done
            fi
            [ "$g" = 0 ] || [ "$g" = 4 ] || keep=1
        fi
        if [ "$keep" = 1 ]; then o="$o$seg"; else o="$o :"; fi
        o="$o$c"; seg=""; prev="$c"; i=$((i+1))
    done
    _BWIMC_AF="$o"
}
# _bwimc_strip_prefix CLAUSE — HIMMEL-4213. Sets _BWIMC_SP0 to CLAUSE with
# its leading assignment words removed (_bwimc_strip_assign), and _BWIMC_SP to CLAUSE
# with its leading run of assignment words, `{`, `!`, if/then/elif/else/
# while/until/do, `time [-p]` and wrapper commands (command, exec, nice,
# nohup, env, timeout, sudo, stdbuf) with their options removed, so the verb
# arms read the command word behind them: `{ touch P/f`, `! x=1 touch P/f`,
# `nice -n 5 touch P/f`. A wrapper name matches in any case (a
# case-insensitive filesystem), its options as written. No verb arm matches a clause that starts with
# one of these words, so the stripped text can only add denials. An option a
# wrapper is not known to take hides where the command word starts: fail
# closed by reading from the first later word a verb arm matches
# (`sudo -Z v touch P/f` reads `touch P/f`); chrt, taskset and ionice always
# read that way. `command -v`, `env -S`, `sudo -l`
# and the like stop the strip there (nothing runs, or today's residual).
# `env -C DIR`/`--chdir`, `sudo -D DIR`/`--chdir` run the command in DIR: the
# operand lands in _BWIMC_SPDIR for the verb loop to model (_bwimc_chdir_model);
# `sudo -i`/`--login`, a second chdir, or an unknown wrapper option record `$`
# (dir unknown, fail closed). No other stripped wrapper changes directory.
# HIMMEL-4329: a wrapper name matches on its basename (`/usr/bin/env`,
# `nice.exe`). `chroot [opts] DIR` and `sudo -R DIR`/`--chroot` change the
# root: DIR lands in _BWIMC_SPROOT for the verb loop (_bwimc_root_model), and
# chroot also chdirs to the new `/`.
_BWIMC_ARMVERB_RE='^([^[:space:]]*/)?(sed|eval|bash|sh|zsh|dash|ksh|install|rsync|dd|cp|mv|rm|touch|ln|git)(\.exe)?$'
# _bwimc_sp_word — trims _BWIMC_SPT's leading blanks; _BWIMC_SPW = its first
# shell word as written ('..', "..", $'..' and backslash honoured, so
# `exec -a "two words" touch` is three words before `touch`), _BWIMC_SPU = that
# word with its quotes removed (a $'..' holding a backslash reads `$`,
# unknown). A quote left open sets _BWIMC_SPBAD (fail closed in the caller).
_bwimc_sp_word() {
    _BWIMC_SPT="${_BWIMC_SPT#"${_BWIMC_SPT%%[![:space:]]*}"}"
    _BWIMC_SPW="${_BWIMC_SPT%%[[:space:]]*}"
    _BWIMC_SPU="$_BWIMC_SPW"
    case "$_BWIMC_SPW" in *[\'\"\\]*) ;; *) return 0 ;; esac
    local t="$_BWIMC_SPT" n=${#_BWIMC_SPT} i=0 j c u="" q
    while [ "$i" -lt "$n" ]; do
        c="${t:$i:1}"
        case "$c" in
            [[:space:]]) break ;;
            \\) u="$u${t:$((i+1)):1}"; i=$((i+2)); continue ;;
            \')
                q="${t:$((i+1))}"
                case "$q" in *\'*) ;; *) _BWIMC_SPBAD=1; i=$n; break ;; esac
                q="${q%%\'*}"; u="$u$q"; i=$((i+2+${#q})); continue ;;
            \"|\$)
                if [ "$c" = '$' ]; then
                    [ "${t:$((i+1)):1}" = "'" ] || { u="$u$c"; i=$((i+1)); continue; }
                    i=$((i+1)); q="'"
                else
                    q='"'
                fi
                j=$((i+1))
                while [ "$j" -lt "$n" ]; do
                    c="${t:$j:1}"
                    if [ "$c" = "\\" ]; then
                        if [ "$q" = "'" ]; then u="$u\$"; else u="$u${t:$((j+1)):1}"; fi
                        j=$((j+2)); continue
                    fi
                    [ "$c" != "$q" ] || break
                    u="$u$c"; j=$((j+1))
                done
                if [ "$j" -ge "$n" ]; then _BWIMC_SPBAD=1; i=$n; break; fi
                i=$((j+1)); continue ;;
        esac
        u="$u$c"; i=$((i+1))
    done
    _BWIMC_SPW="${t:0:$i}"; _BWIMC_SPU="$u"
}
# _bwimc_sp_dir WORD — records a wrapper's chdir operand in _BWIMC_SPDIR; a
# second one reads as unknown (`$`).
_bwimc_sp_dir() {
    if [ -z "$_BWIMC_SPDIR" ]; then _BWIMC_SPDIR="$1"; else _BWIMC_SPDIR='$'; fi
}
# _bwimc_sp_root WORD — HIMMEL-4329: records a chroot's new root (`chroot
# DIR`, `sudo -R DIR`) in _BWIMC_SPROOT; a second one reads as unknown (`$`).
_bwimc_sp_root() {
    if [ -z "$_BWIMC_SPROOT" ]; then _BWIMC_SPROOT="$1"; else _BWIMC_SPROOT='$'; fi
}
# _bwimc_sp_opts SHORTVAL SHORTFLAG SHORTSTOP LONGVAL LONGFLAG LONGSTOP
# [DIRSHORT DIRLONG DYNSHORT DYNLONG ROOTSHORT ROOTLONG] — eats the options after a wrapper word from _BWIMC_SPT,
# recording the DIRSHORT/DIRLONG value (`env -C`, `sudo -D`) via
# _bwimc_sp_dir and the ROOTSHORT/ROOTLONG value (`sudo -R`) via _bwimc_sp_root;
# a DYNSHORT/DYNLONG flag (`sudo -i`) records `$`. Returns 0 at the command word, 1 at a stop option (left in
# place), 2 at an unknown option.
_bwimc_sp_opts() {
    local w wr nm k ch
    while :; do
        # w: the word unquoted (matched); wr: as written (its length is sliced)
        _bwimc_sp_word; w="$_BWIMC_SPU"; wr="$_BWIMC_SPW"
        case "$w" in
            --) _BWIMC_SPT="${_BWIMC_SPT:${#wr}}"; return 0 ;;
            --*)
                nm="${w#--}"; nm="${nm%%=*}"
                case " $6 " in *" $nm "*) return 1 ;; esac
                case " $5 " in
                    *" $nm "*)
                        [ "$nm" != "${10:-}" ] || _bwimc_sp_dir '$'
                        _BWIMC_SPT="${_BWIMC_SPT:${#wr}}"; continue ;;
                esac
                case " $4 " in *" $nm "*) ;; *) return 2 ;; esac
                _BWIMC_SPT="${_BWIMC_SPT:${#wr}}"
                case "$w" in
                    *=*) [ "$nm" != "${8:-}" ] || _bwimc_sp_dir "${w#*=}"
                         [ "$nm" != "${12:-}" ] || _bwimc_sp_root "${w#*=}" ;;
                    *) _bwimc_sp_word; _BWIMC_SPT="${_BWIMC_SPT:${#_BWIMC_SPW}}"
                       [ "$nm" != "${8:-}" ] || _bwimc_sp_dir "$_BWIMC_SPU"
                       [ "$nm" != "${12:-}" ] || _bwimc_sp_root "$_BWIMC_SPU" ;;
                esac
                ;;
            -?*)
                k=1
                while [ "$k" -lt "${#w}" ]; do
                    ch="${w:$k:1}"
                    case "$3" in *"$ch"*) return 1 ;; esac
                    case "$1" in
                        *"$ch"*)
                            if [ "$((k+1))" -eq "${#w}" ]; then
                                _BWIMC_SPT="${_BWIMC_SPT:${#wr}}"; _bwimc_sp_word; wr="$_BWIMC_SPW"
                                [ "$ch" != "${7:-}" ] || _bwimc_sp_dir "$_BWIMC_SPU"
                                [ "$ch" != "${11:-}" ] || _bwimc_sp_root "$_BWIMC_SPU"
                            else
                                [ "$ch" != "${7:-}" ] || _bwimc_sp_dir "${w:$((k+1))}"
                                [ "$ch" != "${11:-}" ] || _bwimc_sp_root "${w:$((k+1))}"
                            fi
                            break ;;
                    esac
                    case "$2" in *"$ch"*) ;; *) return 2 ;; esac
                    [ "$ch" != "${9:-}" ] || _bwimc_sp_dir '$'
                    k=$((k+1))
                done
                _BWIMC_SPT="${_BWIMC_SPT:${#wr}}"
                ;;
            *) return 0 ;;
        esac
    done
}
_bwimc_strip_prefix() {
    local n=${#1} w wl r
    _bwimc_strip_assign "$1"
    _BWIMC_SPT="$_BWIMC_SA"; _BWIMC_SP0="$_BWIMC_SA"; _BWIMC_SPDIR=''; _BWIMC_SPROOT=''; _BWIMC_SPBAD=0
    while :; do
        _bwimc_sp_word; w="$_BWIMC_SPW"
        # a quoted command name still runs (`"sudo"`); a quoted keyword is no keyword.
        # HIMMEL-4329: a wrapper matches on its basename, `.exe` dropped
        # (`/usr/bin/nice`, `nice.exe`), as _bwimc_check_interp_body does
        _tolower_ascii "${_BWIMC_SPU##*/}"; wl="${_TOLOWER_OUT%.exe}"
        r=0
        case "$w" in
            '{'|'!'|if|then|elif|else|while|until|do)
                _BWIMC_SPT="${_BWIMC_SPT:${#w}}"
                _bwimc_strip_assign "$_BWIMC_SPT"; _BWIMC_SPT="$_BWIMC_SA"; continue ;;
            time)
                _BWIMC_SPT="${_BWIMC_SPT:4}"; _bwimc_sp_word
                # bash's `time [-p] [--]`: one -p, then an optional `--`
                case "$_BWIMC_SPW" in -p) _BWIMC_SPT="${_BWIMC_SPT:2}"; _bwimc_sp_word ;; esac
                case "$_BWIMC_SPW" in --) _BWIMC_SPT="${_BWIMC_SPT:2}" ;; esac
                _bwimc_strip_assign "$_BWIMC_SPT"; _BWIMC_SPT="$_BWIMC_SA"; continue ;;
        esac
        case "$wl" in
            command) _BWIMC_SPT="${_BWIMC_SPT:${#w}}"; _bwimc_sp_opts '' p vV '' '' '' || r=$? ;;
            exec) _BWIMC_SPT="${_BWIMC_SPT:${#w}}"; _bwimc_sp_opts a cl '' '' '' '' || r=$? ;;
            nohup) _BWIMC_SPT="${_BWIMC_SPT:${#w}}"; _bwimc_sp_opts '' '' '' '' '' 'help version' || r=$? ;;
            # option + operand grammar not modeled: read from the first verb word
            chrt|taskset|ionice) _BWIMC_SPT="${_BWIMC_SPT:${#w}}"; r=2 ;;
            nice)
                _BWIMC_SPT="${_BWIMC_SPT:${#w}}"; _bwimc_sp_word
                case "$_BWIMC_SPW" in -[0-9]*|--[0-9]*) _BWIMC_SPT="${_BWIMC_SPT:${#_BWIMC_SPW}}" ;; esac
                _bwimc_sp_opts n '' '' adjustment '' 'help version' || r=$? ;;
            timeout)
                _BWIMC_SPT="${_BWIMC_SPT:${#w}}"
                _bwimc_sp_opts ks fpv '' 'kill-after signal' 'foreground preserve-status verbose' 'help version' || r=$?
                # the DURATION operand
                if [ "$r" = 0 ]; then _bwimc_sp_word; _BWIMC_SPT="${_BWIMC_SPT:${#_BWIMC_SPW}}"; fi ;;
            stdbuf) _BWIMC_SPT="${_BWIMC_SPT:${#w}}"; _bwimc_sp_opts ioe '' '' 'input output error' '' 'help version' || r=$? ;;
            env|sudo)
                _BWIMC_SPT="${_BWIMC_SPT:${#w}}"
                while :; do
                    if [ "$wl" = env ]; then
                        _bwimc_sp_opts uCa i0v S 'unset chdir argv0' 'ignore-environment null debug block-signal default-signal ignore-signal list-signal-handling' 'split-string help version' C chdir || r=$?
                    else
                        _bwimc_sp_opts ugpChDrRtTU AbEHiKknPSsB lVve 'user group host prompt close-from chdir role type command-timeout other-user chroot' 'askpass background preserve-env set-home login non-interactive preserve-groups stdin shell reset-timestamp bell' 'list version validate remove-timestamp edit help' D chdir i login R chroot || r=$?
                    fi
                    [ "$r" = 0 ] || break
                    _bwimc_sp_word
                    case "$_BWIMC_SPU" in
                        -) _BWIMC_SPT="${_BWIMC_SPT:${#_BWIMC_SPW}}" ;;
                        [A-Za-z_]*=*) _BWIMC_SPT="${_BWIMC_SPT:${#_BWIMC_SPW}}" ;;
                        *) break ;;
                    esac
                done ;;
            # HIMMEL-4329: `chroot [opts] NEWROOT cmd` runs cmd from NEWROOT's
            # `/` (`--skip-chdir`: the dir is unknown)
            chroot)
                _BWIMC_SPT="${_BWIMC_SPT:${#w}}"
                _bwimc_sp_opts '' '' '' 'groups userspec' 'skip-chdir' 'help version' '' '' '' skip-chdir || r=$?
                if [ "$r" = 0 ]; then
                    _bwimc_sp_word; _BWIMC_SPT="${_BWIMC_SPT:${#_BWIMC_SPW}}"
                    _bwimc_sp_root "$_BWIMC_SPU"; _bwimc_sp_dir /
                fi ;;
            *) break ;;
        esac
        if [ "$_BWIMC_SPBAD" = 1 ]; then
            break
        elif [ "$r" = 1 ]; then
            break
        elif [ "$r" = 2 ]; then
            # an unknown env/sudo/chroot option may be a chdir: the dir is
            # unknown; an unknown sudo/chroot one may be a new root (HIMMEL-4329)
            case "$wl" in env|sudo|chroot) _bwimc_sp_dir '$' ;; esac
            case "$wl" in sudo|chroot) _bwimc_sp_root '$' ;; esac
            # fail closed: the first later word a verb arm matches (none: as is)
            w="$_BWIMC_SPT"
            while _bwimc_sp_word; [ -n "$_BWIMC_SPW" ]; do
                _tolower_ascii "$_BWIMC_SPU"
                [[ "$_TOLOWER_OUT" =~ $_BWIMC_ARMVERB_RE ]] && break
                _BWIMC_SPT="${_BWIMC_SPT:${#_BWIMC_SPW}}"
            done
            [ -n "$_BWIMC_SPW" ] || _BWIMC_SPT="$w"
            break
        fi
    done
    if [ "$_BWIMC_SPBAD" = 1 ]; then
        # a quote left open: the word bounds are unknown. Fail closed: read
        # from the first blank-split word (quotes dropped) a verb arm matches.
        _BWIMC_SPT="$_BWIMC_SP0"
        while :; do
            _BWIMC_SPT="${_BWIMC_SPT#"${_BWIMC_SPT%%[![:space:]]*}"}"
            w="${_BWIMC_SPT%%[[:space:]]*}"
            [ -n "$w" ] || { _BWIMC_SPT="$_BWIMC_SP0"; break; }
            wl="${w//[\'\"\\]/}"; wl="${wl#\$}"
            _tolower_ascii "$wl"
            [[ "$_TOLOWER_OUT" =~ $_BWIMC_ARMVERB_RE ]] && break
            _BWIMC_SPT="${_BWIMC_SPT:${#w}}"
        done
    fi
    _BWIMC_SP="${1:$((n - ${#_BWIMC_SPT}))}"
}
# _bwimc_split_clauses TEXT [skel] — with `skel` (TEXT is a _bwimc_subst_split
# skeleton), the `(` of a `$(` STUB is not a break, so a target built from a
# substitution (`f$(date)`) stays one token (HIMMEL-4010).
_bwimc_split_clauses() {
    local text="$1" skel="${2:-}"
    local i=0 len=${#text} c clause="" prevact=""
    _bwimc_sp_pipe=0
    ! _bwimc_text_untrusted "$text" || _bwimc_sp_pipe=1
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
                        _bwimc_split_emit "$clause"; _bwimc_sp_pipe=1
                        clause=""
                    fi
                    ;;
                ';'|'&'|"$_BWIMC_NL") _bwimc_split_emit "$clause"; clause="" ;;
                '(')
                    if [ -n "$skel" ] && [ "$prevact" = '$' ] && { [ "${text:$((i+1)):1}" = $'\001' ] || [ "${text:$((i+1)):1}" = $'\005' ]; }; then
                        clause="${clause}${c}"
                    elif [ "$prevact" = '$' ] && [ "${text:$((i+1)):1}" = '(' ] && _bwimc_arith_end "$text" "$i"; then
                        # HIMMEL-4153: a plain `$((…))` is arithmetic, not a
                        # subshell — keep it in the clause so `x=$((1<<2))
                        # touch P/f` stays ONE clause with its verb.
                        clause="${clause}${text:$i:$((_BWIMC_AE - i + 1))}"
                        i=$((_BWIMC_AE + 1)); prevact=')'; continue
                    else
                        _bwimc_split_emit "$clause"; clause=""
                    fi
                    ;;
                *) clause="${clause}${c}" ;;
            esac
        elif [ "$c" = "$_BWIMC_NL" ] && [ -n "$_BWIMC_Q" ] && [ "$_BWIMC_NLENC" = 1 ]; then
            # HIMMEL-4143: a newline inside a quoted span is part of the
            # word, not a clause break — carry it as \006 so the clause
            # stays one line in transport (`echo 'a⏎' > P/f` keeps its
            # redirect). Only in a mode-1 reading (_BWIMC_NLENC=1).
            clause="${clause}"$'\006'
        else
            clause="${clause}${c}"
        fi
        # `prevact` is the previous ACTIVE character, so an escaped or quoted
        # `>` cannot make the following `|` look like a clobber operator.
        if [ "$_BWIMC_ACT" = 1 ]; then prevact="$c"; else prevact=""; fi
        i=$((i+1))
    done
    _bwimc_split_emit "$clause"
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
    local t="${1//$'\006'/$'\n'}"
    local Q="\"'"
    # HIMMEL-4010: an ANSI-C `$'…'` span names the path its decoded text spells
    # (`> $'<primary>/f'`); undecoded, its `$` made the target look dynamic.
    # A real \016 is doubled either way, so _bwimc_unsent cannot misread it.
    case "$t" in
        *"\$'"*) t=$(_bwimc_ansic_spans "$t") ;;
        *$'\016'*) t="${t//$'\016'/$'\016\016'}" ;;
    esac
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
    # ponytail: edge whitespace and newlines in a real name (a symlink `f ` or
    # `nl<LF>` into the primary) are lost here and in $(…) captures, so the
    # write is checked under the wrong name; carry them as sentinels (HIMMEL-4129).
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] || return 1
    # HIMMEL-4359: once the command assigns HOME itself, the hook's own HOME
    # no longer names what ~ / $HOME expand to — unresolvable, like a cd.
    # shellcheck disable=SC2088,SC2016
    [ "${_bwimc_home_taint:-0}" = 1 ] && case "$t" in
        '~'|'~/'*|'$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*) return 1 ;;
    esac
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
    _bwimc_unsent "$t"
}

# _bwimc_unsent TEXT — HIMMEL-4010: the literal chars _bwimc_ansic_spans
# parked as \016+letter sentinels (and \016\016 for a real \016), restored.
_bwimc_unsent() {
    local t="$1" o="" k=0 c
    case "$t" in *$'\016'*) : ;; *) printf '%s' "$t"; return 0 ;; esac
    while [ "$k" -lt "${#t}" ]; do
        c="${t:$k:1}"
        if [ "$c" = $'\016' ]; then
            k=$((k+1))
            case "${t:$k:1}" in
                d) c='$' ;; b) c='`' ;; q) c='"' ;; a) c="'" ;;
                e) c="\\" ;; s) c='*' ;; m) c='?' ;; l) c='[' ;;
                $'\016') c=$'\016' ;;
                *) c=$'\016'"${t:$k:1}" ;;
            esac
        fi
        o="$o$c"; k=$((k+1))
    done
    printf '%s' "$o"
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
    _bwimc_unsent "$head"
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
#   _BWIMC_OPT_RMDEST 1 when `--remove-destination` (or an abbreviation) was
#                     seen. cp-only (HIMMEL-2679): it has no short form, so it
#                     is caught only here, not in the bundled-short-option
#                     loop below.
#   _BWIMC_OPT_FORCE  1 when `-f` / `--force` (or an abbreviation of the
#                     latter) was seen. HIMMEL-2679: on cp, a FOLLOW-mode
#                     write that fails on the referent's permissions falls
#                     back to unlinking the destination ENTRY (ground-truthed
#                     against real GNU coreutils) — the same entry-replacing
#                     effect as `--remove-destination`, just conditional on a
#                     permission failure rather than unconditional.
_bwimc_opt_scan() {
    local tok="$1" fl fc
    _BWIMC_OPT_TDIR=""
    _BWIMC_OPT_TWANT=0
    _BWIMC_OPT_BIGT=0
    _BWIMC_OPT_SMALLN=0
    _BWIMC_OPT_RMDEST=0
    _BWIMC_OPT_FORCE=0
    case "$tok" in
        --*)
            if _bwimc_is_long_abbrev "no-target-directory" "$tok"; then
                _BWIMC_OPT_BIGT=1
            elif _bwimc_is_long_abbrev "no-dereference" "$tok"; then
                _BWIMC_OPT_SMALLN=1
            elif _bwimc_is_long_abbrev "remove-destination" "$tok"; then
                _BWIMC_OPT_RMDEST=1
            elif _bwimc_is_long_abbrev "force" "$tok"; then
                _BWIMC_OPT_FORCE=1
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
            f) _BWIMC_OPT_FORCE=1 ;;
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
        unresolved-heredoc) why="a heredoc opener's terminator was never found in the command (failing closed — text after it cannot be safely classified)" ;;
        home-reassigned) why="the command assigns HOME itself, so this ~ / \$HOME target cannot be resolved (failing closed, HIMMEL-4359)" ;;
        unresolved-cd) why="a cd/pushd target in this command could not be resolved (failing closed — a later relative write cannot be classified against an unknown cwd, HIMMEL-3648)" ;;
        marker-byte) why="the command carries a raw control byte (0x01-0x06 or 0x0e) the scanner uses as an internal marker, so its targets cannot be classified (failing closed; spell the byte as \$'\\xNN' instead)" ;;
        shell-ambiguous) why="bash and zsh (or bash versions) read a \$'…' span in it differently, so its target cannot be classified (failing closed, HIMMEL-4138)" ;;
        unclosed-expansion) why="a \${…} or \$[…] span never closes and a separator follows it, so the command after it cannot be read (failing closed)" ;;
        unresolved-chroot) why="it runs behind a chroot (chroot DIR, sudo -R/--chroot) whose new root could not be resolved, so its targets cannot be classified (failing closed, HIMMEL-4329)" ;;
        chroot-git) why="it runs a git write behind a chroot (chroot DIR, sudo -R/--chroot) other than /: its -C, --git-dir, --work-tree and GIT_* paths are not mapped into the new root, so its repo cannot be classified (failing closed, HIMMEL-4329)" ;;
        unsafe-interp-body) why="an eval/bash -c/sh -c/zsh -c argument contains a write-shaped token whose target cannot be proven to stay outside the primary (failing closed, HIMMEL-3648)" ;;
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
        case "$kind" in
            unresolved-cd|unresolved-heredoc|marker-byte|shell-ambiguous|unclosed-expansion|unresolved-git-target)
                # A shape refusal (HIMMEL-4815): the target was unreadable, not proven primary.
                echo "    Retry (shape, not destination): one write per Bash call, an absolute"
                echo "    worktree path as the target, no cd/heredoc/\$(…)/\$VAR — body via a file." ;;
        esac
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
#
# HIMMEL-4329: behind a chroot (_bwimc_chroot, set per clause by
# _bwimc_root_model) the write lands inside ROOT. Every reading is checked
# (deny-only): the host reading as before; ROOT itself, so a root that IS the
# primary or lies inside it denies any write whatever the target; ROOT + ABS
# lexically; and ROOT + ABS resolved the way the jail resolves it
# (_bwimc_jail_canon: an absolute symlink restarts at ROOT, `..` stops at
# ROOT), so a root that is an ANCESTOR of the primary cannot reach it through
# a link the host would resolve elsewhere (`chroot ~/github touch /lnk/f`,
# lnk -> /himmel). An unknown root fails closed.
# ponytail: a chroot into an UNRELATED root allows. That is safe on the
# filesystem alone, since in-jail resolution never leaves ROOT, but a bind
# mount or mount namespace can expose the primary inside an unrelated jail,
# and this host-side check cannot see it (chroot also needs CAP_SYS_CHROOT,
# which an agent session rarely has); upgrade path = fail closed on any write
# behind a chroot, or read /proc/self/mountinfo for mounts under ROOT.
_bwimc_check_abs() {
    local abs="$1" raw="$2" mode="${3:-follow}"
    local lc canon root="${_bwimc_chroot:-}" jc
    if [ -n "$root" ]; then
        [ "$root" != '$' ] || _bwimc_deny "unresolved-chroot" "$raw" "$abs" ""
        case "$abs" in
            /*) _bwimc_chroot=""
                _bwimc_check_abs "$root" "$raw" follow
                _bwimc_check_abs "${root%/}$abs" "$raw" "$mode"
                jc=$(_bwimc_jail_canon "${root%/}" "$abs") || _bwimc_deny "unresolved-chroot" "$raw" "$abs" ""
                _bwimc_check_abs "${root%/}$jc" "$raw" "$mode"
                _bwimc_chroot="$root" ;;
        esac
    fi
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
# HIMMEL-4010: a write operand built from a command substitution never
# resolves statically, so every arm that falls back here (cp/mv/ln/install
# destinations, mv sources) hands it to _bwimc_check_target's stub model.
_bwimc_check_glob_operand() {
    local raw="$1" cwd="$2" pfx abs
    case "$raw" in *$'\005'*|*$'\001'*) _bwimc_check_target "$raw" "$cwd"; return 0 ;; esac
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
#
# HIMMEL-4010: a target built from a command substitution (a _bwimc_subst_split
# stub) is not dropped either. A leading `$(pwd)`/backtick-pwd stub (\005) is
# the cwd, so it becomes `.` when a `/`, a `"/`, or the token end (quoted or
# not) follows it; a pwd stub anywhere else is just another stub.
# Any other stub's output is unknown, so the token's static prefix decides:
# the directory it names (`P/n$(date)` = P/, `f$(date)` = the cwd) is checked
# as a write-through directory, like a glob's prefix.
# ponytail: a target that STARTS with a non-pwd substitution (`"$(mktemp)"`)
# or a `$VAR`, or whose substitution output climbs out with `..` or names a
# symlink (`/tmp/x$(pwd)/f`), is checked only as far as its static prefix —
# the same dynamic-operand residual as `$VAR` (HIMMEL-2526 §2);
# revisit only with a real expansion model.
_bwimc_check_target() {
    local raw="$1" cwd="$2" mode="${3:-follow}" abs eff pfx h lq="" rest
    case "$raw" in
        *$'\005'*|*$'\001'*)
            # Only a LEADING pwd stub is the cwd (`/tmp/x$(pwd)/f` is not
            # `/tmp/x./f`), and only when `/`, `"/`, a closing `"` or the
            # token end follows it: `"$(pwd)"n` continues into a sibling name.
            # Everything else falls to the static-prefix rule below.
            case "$raw" in '"'*) lq='"'; rest="${raw#\"}" ;; *) rest="$raw" ;; esac
            # shellcheck disable=SC2016  # literal `$(`, not an expansion
            case "$rest" in
                '$('$'\005'')'*) rest="${rest#'$('$'\005'')'}" ;;
                '`'$'\005''`'*) rest="${rest#'`'$'\005''`'}" ;;
                *) rest=$'\001' ;;
            esac
            case "$rest" in
                ''|/*|'"'|'"/'*) raw="$lq.$rest" ;;
            esac
            case "$raw" in
                *$'\005'*|*$'\001'*)
                    # shellcheck disable=SC2016
                    h="${raw%%'$('[$'\001'$'\005']*}"
                    h="${h%%'`'[$'\001'$'\005']*}"
                    pfx=$(_bwimc_expand_token_raw "$h") || return 0
                    case "$pfx" in *'$'*|*'`'*) return 0 ;; esac
                    case "$pfx" in
                        */*) pfx="${pfx%/*}/" ;;
                        *) pfx="./" ;;
                    esac
                    pfx=$(_bwimc_unsent "$pfx")
                    _bwimc_cd_guard "$pfx"
                    case "$pfx" in
                        /*|[A-Za-z]:/*|[A-Za-z]:\\*) abs="$pfx" ;;
                        *) abs="${cwd%/}/$pfx" ;;
                    esac
                    _bwimc_check_abs "$abs" "$raw" follow
                    return 0
                    ;;
            esac
            _bwimc_cd_guard "$raw" "$mode"
            ;;
    esac
    if ! abs=$(_bwimc_resolve_abs "$raw" "$cwd"); then
        _bwimc_check_glob_operand "$raw" "$cwd"
        return 0
    fi
    eff=$(_bwimc_mode_for_operand "$raw" "$mode")
    _bwimc_check_abs "$abs" "$raw" "$eff"
}

# HIMMEL-3648: forward declaration — _bwimc_ecwd_track below (used by arm (a),
# which runs as top-level script code before _bwimc_unq's canonical
# definition is reached further down) needs _bwimc_unq/_bwimc_ansic already
# defined. Redefined identically at their original location later in the
# file for arm (g)/(b)/(e); a bash function redefinition is a plain
# overwrite, so this is not a behavior change, only an ordering fix.
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

# _bwimc_ansic_spans TOKEN — HIMMEL-4010: TOKEN with each `$'…'` span replaced
# by the text it decodes to; everything else is left as it is. Only an
# UNQUOTED `$'` opens a span: inside "…" or '…' the `$'` is literal text.
_bwimc_ansic_spans() {
    local t="$1" o="" c k=0 q s="" n
    while [ "$k" -lt "${#t}" ]; do
        c="${t:$k:1}"
        # a real \016 is the sentinel escape, so it is doubled (_bwimc_unsent)
        [ "$c" = $'\016' ] && c=$'\016\016'
        if [ "$s" = "'" ]; then
            [ "$c" = "'" ] && s=""
            o="$o$c"; k=$((k+1)); continue
        fi
        if [ "$c" = "\\" ]; then
            n="${t:$((k+1)):1}"
            [ "$n" = $'\016' ] && n=$'\016\016'
            o="$o$c$n"; k=$((k+2)); continue
        fi
        if [ "$c" = '"' ]; then
            if [ "$s" = '"' ]; then s=""; else s='"'; fi
            o="$o$c"; k=$((k+1)); continue
        fi
        if [ -z "$s" ] && [ "$c" = "'" ]; then
            s="'"; o="$o$c"; k=$((k+1)); continue
        fi
        # `$$` is the PID expansion, so a `'` after it is a plain quote
        if [ -z "$s" ] && [ "$c" = '$' ] && [ "${t:$((k+1)):1}" = '$' ]; then
            o="$o\$\$"; k=$((k+2)); continue
        fi
        if [ -z "$s" ] && [ "$c" = '$' ] && [ "${t:$((k+1)):1}" = "'" ]; then
            k=$((k+2)); q=""
            while [ "$k" -lt "${#t}" ] && [ "${t:$k:1}" != "'" ]; do
                if [ "${t:$k:1}" = "\\" ]; then q="$q\\"; k=$((k+1)); fi
                q="$q${t:$k:1}"; k=$((k+1))
            done
            k=$((k+1))
            # decoded text is LITERAL: a `$`, backtick, quote, `\` or glob
            # char in it names itself, so it rides as a \016+letter sentinel
            # (a real \016 as \016\016) past the quote strip and the dynamic
            # check; _bwimc_unsent puts the real char back before the path is
            # resolved
            q=$(_bwimc_ansic "$q")
            q="${q//$'\016'/$'\016\016'}"
            q="${q//'$'/$'\016'd}"; q="${q//'`'/$'\016'b}"
            q="${q//'"'/$'\016'q}"; q="${q//\'/$'\016'a}"
            q="${q//\\/$'\016'e}"; q="${q//'*'/$'\016's}"
            q="${q//'?'/$'\016'm}"; q="${q//'['/$'\016'l}"
            o="$o$q"
            continue
        fi
        o="$o$c"; k=$((k+1))
    done
    printf '%s' "$o"
}

_bwimc_unq() {
    local t="$1" o="" c k=0 q
    # HIMMEL-4143: a newline inside a quoted span travels as \006 in clause
    # transport (_bwimc_split_clauses); the word itself carries the newline.
    t="${t//$'\006'/$'\n'}"
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

# HIMMEL-3648: shared cd/pushd/popd cwd-tracking for arm (a) and arm (b)/(e)
# — the git-arm's cd/pushd/popd tracking (_bwimc_git_clause below) never
# reaches these two arms, so a `cd <primary> && echo x > a.txt` left every
# LATER relative write destination in the same command resolving against the
# session cwd instead of the cd's target. Modelled on _bwimc_git_clause's own
# cd handling, simplified: no alt-cwd fallback, no GIT_* env. Each arm resets
# _bwimc_ecwd/_bwimc_ecwd_unres to _bwimc_cwd/0 at the top of its OWN loop —
# both arms scan the identical clause sequence in the identical order, so
# independent, per-arm tracking reproduces the same result as one shared
# pass. Called as a plain statement once per clause, BEFORE that clause's own
# scan runs — never via `$(…)`, which would discard the global updates in a
# subshell.
# _bwimc_chdir_model RAW — HIMMEL-4213: a wrapper chdir operand (`env -C RAW`)
# moves _bwimc_ecwd like a `cd RAW` would. A non-literal operand (`$`, a
# backtick, a glob, a backslash, an odd quote) or one that does not resolve
# marks the cwd unresolved, so a relative write target behind it denies.
_bwimc_chdir_model() {
    local raw="$1" carg r q="${1//[!\"]/}" a="${1//[!\']/}"
    case "$raw" in
        ''|*'$'*|*'`'*|*[*?[]*|*\\*) _bwimc_ecwd_unres=1; return 0 ;;
    esac
    if [ $(( ${#q} % 2 )) = 1 ] || [ $(( ${#a} % 2 )) = 1 ]; then _bwimc_ecwd_unres=1; return 0; fi
    carg=$(_bwimc_unq "$raw")
    case "$carg" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
        *) [ "$_bwimc_ecwd_unres" = 0 ] || return 0 ;;
    esac
    if r=$(_bwimc_resolve_abs "$carg" "$_bwimc_ecwd"); then
        _bwimc_ecwd="$r"; _bwimc_ecwd_unres=0
    else
        _bwimc_ecwd_unres=1
    fi
}
# _bwimc_root_model RAW — HIMMEL-4329: a chroot's new root (`chroot RAW`,
# `sudo -R RAW`) for _bwimc_check_abs. Sets _bwimc_chroot to RAW resolved
# against the cwd and canonicalised (a root that is a symlink into the primary
# must not pass as its /tmp spelling), to "" for `/`, and to `$` (unknown, fail
# closed) for a non-literal RAW, one that does not resolve, or a relative RAW
# beside another wrapper chdir (which dir it is relative to is ambiguous).
# Only the verb-loop targets (_bwimc_check_abs) read the root: a `tee` behind
# a chroot is read by the verb loop's tee arm, and a git behind one fails
# closed in _bwimc_git_clause's jail mode (CR codex-2). A redirect behind a
# chroot (`chroot R echo x > /f`) is opened by the host shell, so arm (a)
# rightly reads it on the host. An abbreviated `--chr=DIR` is an unknown
# option, so it already fails closed.
_bwimc_root_model() {
    local raw="$1" r
    _bwimc_chroot='$'
    case "$raw" in *'$'*|*'`'*|*[*?[]*|*\\*) return 0 ;; esac
    case "$raw" in
        /*) ;;
        *) [ "$_bwimc_ecwd_unres" = 0 ] && { [ -z "$_BWIMC_SPDIR" ] || [ "$_BWIMC_SPDIR" = / ]; } || return 0 ;;
    esac
    r=$(_bwimc_resolve_abs "$raw" "$_bwimc_ecwd") || return 0
    r=$(guard_canon_path "$r" 2>/dev/null) || return 0
    case "$r" in
        /) _bwimc_chroot="" ;;
        /*) _bwimc_chroot="$r" ;;
    esac
}
# _bwimc_jail_canon ROOT ABS — HIMMEL-4329: prints ABS resolved the way a
# process chrooted at ROOT (canonical, no trailing /) resolves it: `.` drops,
# `..` stops at the jail's `/`, an absolute symlink target restarts at the
# jail's `/`, a relative one resolves from its own dir. Every symlink is
# followed, the last one included; more than 40 links fails (rc 1).
_bwimc_jail_canon() {
    local root="$1" rest="$2" cur="" comp l hops=0
    while [ -n "$rest" ]; do
        case "$rest" in
            */*) comp="${rest%%/*}"; rest="${rest#*/}" ;;
            *) comp="$rest"; rest="" ;;
        esac
        case "$comp" in
            ''|.) continue ;;
            ..) cur="${cur%/*}"; continue ;;
        esac
        if [ -L "$root$cur/$comp" ]; then
            hops=$((hops+1)); [ "$hops" -le 40 ] || return 1
            l=$(readlink "$root$cur/$comp") || return 1
            case "$l" in /*) cur="" ;; esac
            rest="$l/$rest"
        else
            cur="$cur/$comp"
        fi
    done
    printf '%s\n' "${cur:-/}"
}
_bwimc_ecwd_track() {
    local toks=() t tu i n r carg cabs craw piped="${2:-0}" j cmdi
    while IFS= read -r t; do toks+=("$t"); done < <(_bwimc_tokenize "$1")
    n=${#toks[@]}
    # HIMMEL-3685: a cd/pushd/popd that is not the clause's first command word
    # (past plain assignments) is not a plain simple cd: mark the cwd unresolved
    # below. Accepted over-deny: any clause that merely names cd as an argument.
    i=0
    while [ "$i" -lt "$n" ]; do
        case "$(_bwimc_unq "${toks[$i]}")" in
            "{"|"!"|"("|""|if|then|else|elif|do|while|until|builtin) i=$((i+1)) ;;
            *) break ;;
        esac
    done
    [ "$i" -lt "$n" ] || return 0
    tu=$(_bwimc_unq "${toks[$i]}")
    cmdi=$i
    case "$tu" in
        cd|pushd)
            i=$((i+1))
            while [ "$i" -lt "$n" ]; do
                case "$(_bwimc_unq "${toks[$i]}")" in
                    -L|-P|-e|-@) i=$((i+1)) ;;
                    --) i=$((i+1)); break ;;
                    *) break ;;
                esac
            done
            if [ "$i" -ge "$n" ]; then
                # HIMMEL-3648 (CR #1307): a bare `pushd` swaps the top two
                # stack entries — but ONLY if the stack already has a second
                # entry from an earlier `pushd <dir>` in this same command.
                # With no prior push, bash errors and leaves cwd UNCHANGED
                # (verified: `cd /tmp; pushd` -> "no other directory", cwd
                # stays /tmp) — a guaranteed no-op, not an unmodelled dynamic
                # cd, so leave _bwimc_ecwd/_bwimc_ecwd_unres untouched in that
                # case rather than guessing HOME or failing closed.
                if [ "$tu" = cd ]; then
                    [ -n "${HOME:-}" ] && [ "${_bwimc_home_taint:-0}" = 0 ] && { _bwimc_ecwd="$HOME"; _bwimc_ecwd_unres=0; } || _bwimc_ecwd_unres=1
                elif [ "$_bwimc_ecwd_pushn" -ge 1 ]; then
                    _bwimc_ecwd_unres=1
                fi
            elif [ "$(_bwimc_unq "${toks[$i]}")" = "-" ]; then
                _bwimc_ecwd_unres=1
            else
                craw="${toks[$i]}"
                # shellcheck disable=SC2016
                case "$craw" in
                    *'`'*|*'$('*)
                        # HIMMEL-3648 (CR #1307): a command-substitution
                        # cd/pushd target is dynamic, but _bwimc_unq strips
                        # backticks unconditionally — checking the target
                        # AFTER _bwimc_unq (as below) would see a laundered
                        # literal instead of failing closed. Check the RAW
                        # token instead.
                        [ "$tu" = pushd ] && _bwimc_ecwd_pushn=$((_bwimc_ecwd_pushn+1))
                        _bwimc_ecwd_unres=1
                        ;;
                    +[0-9]*|-[0-9]*)
                        if [ "$tu" = pushd ]; then
                            # HIMMEL-3648 (CR #1307): `pushd +N`/`-N` rotates
                            # the directory stack this hook does not track —
                            # fail closed rather than resolve "+N"/"-N" as a
                            # literal relative path fragment. Not a push of a
                            # new dir onto the stack, so _bwimc_ecwd_pushn is
                            # left unchanged.
                            _bwimc_ecwd_unres=1
                        else
                            carg=$(_bwimc_unq "$craw")
                            if r=$(_bwimc_resolve_abs "$carg" "$_bwimc_ecwd"); then
                                _bwimc_ecwd="$r"; _bwimc_ecwd_unres=0
                            else
                                _bwimc_ecwd_unres=1
                            fi
                        fi
                        ;;
                    *)
                        carg=$(_bwimc_unq "$craw")
                        case "$carg" in
                            /*|[A-Za-z]:/*|[A-Za-z]:\\*) cabs=1 ;;
                            *) cabs=0 ;;
                        esac
                        # HIMMEL-3648 (codex-1): a stale _bwimc_ecwd (left
                        # behind by an earlier popd, `cd -`, or unresolvable
                        # cd — none of which update it) must not be silently
                        # trusted again by a later RELATIVE cd/pushd
                        # resolving against it — that would clear
                        # _bwimc_ecwd_unres against the WRONG base. Only an
                        # ABSOLUTE target is base-independent and may clear
                        # the flag once it was already set.
                        [ "$tu" = pushd ] && _bwimc_ecwd_pushn=$((_bwimc_ecwd_pushn+1))
                        if [ "$cabs" = 0 ] && [ "$_bwimc_ecwd_unres" = 1 ]; then
                            :
                        elif r=$(_bwimc_resolve_abs "$carg" "$_bwimc_ecwd"); then
                            _bwimc_ecwd="$r"; _bwimc_ecwd_unres=0
                        else
                            _bwimc_ecwd_unres=1
                        fi
                        ;;
                esac
            fi
            ;;
        popd) _bwimc_ecwd_unres=1 ;;
    esac
    # HIMMEL-3685: a cd/pushd/popd reached across a `|`/`||` boundary may not
    # have run (or ran in a pipeline subshell) — whatever it modelled, the
    # real cwd is unknown, so fail closed like an unresolvable cd.
    case "$tu" in
        cd|pushd|popd) [ "$piped" = 1 ] && _bwimc_ecwd_unres=1 ;;
    esac
    for ((j = 0; j < n; j++)); do
        [ "$j" = "$cmdi" ] && continue
        case "$(_bwimc_unq "${toks[$j]}")" in
            cd|pushd|popd) _bwimc_ecwd_unres=1 ;;
        esac
    done
    return 0
}

# Denies a RELATIVE, non-dynamic write candidate once a cd/pushd earlier in
# this same command left the modelled cwd unresolved (HIMMEL-3648) — an
# absolute or dynamic ($/backtick) candidate is untouched: those already
# resolve (or fail open on themselves alone) regardless of cwd.
#
# HIMMEL-3648 (J1307O C1): _bwimc_ecwd_track has no model of a cd/pushd
# target that doesn't exist, ||/&&-short-circuiting, a subshell, a
# pipeline, a background &, an if/while body that never runs, or a $(...)
# command substitution — every one of those can leave _bwimc_ecwd pointing
# somewhere the cd never actually took the shell, while the REAL cwd stays
# wherever it started (often the primary). Modelling every one of those
# shapes correctly is out of scope for this fix; instead, once the tracked
# cwd has diverged from the real payload cwd at all, ALSO check this same
# candidate against the real payload cwd and deny if THAT resolves inside
# the primary — cd tracking may only ADD denies relative to a
# payload-cwd-only check, never remove one, regardless of how wrong its
# own clause-connective modelling turns out to be. _bwimc_check_target
# itself calls _bwimc_deny (which exits) on a DENY verdict, so this runs
# before the call site's own _bwimc_ecwd-based check ever gets a chance to
# allow.
#
# HIMMEL-3648 (CR #1307 round 10 codex-1): every call site used to pass only
# the candidate token — never its own operation mode (entry/follow) — so
# this fallback defaulted to "follow" regardless of what the caller actually
# needed. For an `rm` operand (entry semantics: unlink acts on the directory
# ENTRY, never the referent) that meant a primary-checkout symlink whose
# ENTRY sits inside the primary but whose REFERENT resolves outside it
# passed this fallback check unnoticed — deleting the entry is a write into
# the primary the fallback was supposed to catch. Fixed by threading the
# caller's own mode through as $2: the fallback must run byte-for-byte the
# same check main runs — same mode, same semantics — not a guessed default.
# Callers that never write through their own operand at all (a `cp` source,
# for instance — cp never checks its source as a destination) pass nothing
# and get the harmless "follow" default, since main never contradicts it.
#
# HIMMEL-4253: an unquoted leading `~` or `~/` is not relative either — bash
# expands it to $HOME whatever the cwd, so it is base-independent like an
# absolute path, and the call site's own check still resolves it (via
# _bwimc_expand_token) and denies a target inside the primary. Only those two
# spellings, and only with an ABSOLUTE HOME (a relative HOME makes ~ follow the
# cd again): `~user`, `~+`, `~-` and a quoted `"~"`
# stay relative here and keep failing closed behind an unresolved cd.
# ponytail: an `=`-value `~/` (`--opt=~/x`, or `of=~/x` under zsh) stays
# literal in the shell but is read as $HOME here, the reading
# _bwimc_expand_token already gives it; revisit if a literal `~` directory
# ever appears inside a checkout.
_bwimc_cd_guard() {
    # HIMMEL-4359: after an in-command HOME assignment a ~ / $HOME write
    # target resolves against a HOME this hook cannot see — fail closed.
    # A cp SOURCE passes here too, as behind a cd: its basename names the
    # child the copy writes, and `cp -r ~ d/` takes that name from HOME.
    # shellcheck disable=SC2088,SC2016
    [ "${_bwimc_home_taint:-0}" = 1 ] && case "${1#[\"\']}" in
        '~'|'~/'*|'$HOME'|'$HOME'[!A-Za-z0-9_]*|'${HOME}'*)
            _bwimc_deny "home-reassigned" "$1" "" "" ;;
    esac
    # shellcheck disable=SC2088
    case "$1" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*|*'$'*|*'`'*) return 0 ;;
        '~'|'~/'*) case "${HOME:-}" in
            /*|[A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;;
        esac ;;
    esac
    [ "$_bwimc_ecwd_unres" = 1 ] && _bwimc_deny "unresolved-cd" "$1" "" ""
    [ "$_bwimc_ecwd" != "$_bwimc_cwd" ] && _bwimc_check_target "$1" "$_bwimc_cwd" "${2:-follow}"
    return 0
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

# _bwimc_ansic_ambig SPAN NEXT — HIMMEL-4138. SPAN is the raw text of one
# `$'…'` span, NEXT the character after its closing quote. Denies when the
# shells decode it differently in a way that can move a path:
#   - `\x{` + hex digit: bash 5.3 decodes `\x{2f}` as `/`, bash <= 5.2 keeps
#     `\x{` literal and zsh reads a NUL;
#   - a NUL escape (`\0`, `\x00`, `\x` with no digits in zsh, `\u0000`,
#     `\c@`): bash drops the rest of the SPAN, zsh the rest of the WORD, and
#     the scan reads a literal char. Only a NUL that ends the span AND the word
#     (`read -d $'\0'`, `IFS=$'\0'`) reads the same in all three, so it stays.
_bwimc_ansic_ambig() {
    local s="$1" nx="$2" k=0 d h nul
    while [ "$k" -lt "${#s}" ]; do
        if [ "${s:$k:1}" != "\\" ]; then k=$((k+1)); continue; fi
        d="${s:$((k+1)):1}"; k=$((k+2)); nul=0
        case "$d" in
            x)
                if [ "${s:$k:1}" = '{' ]; then
                    case "${s:$((k+1)):1}" in
                        [0-9A-Fa-f]) _bwimc_deny "shell-ambiguous" "\$'$s'" "(\\x{…} decodes three ways)" "" ;;
                    esac
                    nul=1
                else
                    h=""
                    while [ "${#h}" -lt 2 ]; do
                        case "${s:$k:1}" in [0-9A-Fa-f]) h="$h${s:$k:1}"; k=$((k+1)) ;; *) break ;; esac
                    done
                    case "$h" in ''|0|00) nul=1 ;; esac
                fi ;;
            u|U)
                h=""
                while [ "${#h}" -lt "$([ "$d" = u ] && echo 4 || echo 8)" ]; do
                    case "${s:$k:1}" in [0-9A-Fa-f]) h="$h${s:$k:1}"; k=$((k+1)) ;; *) break ;; esac
                done
                case "$h" in ''|*[!0]*) [ -n "$h" ] || nul=1 ;; *) nul=1 ;; esac ;;
            [0-7])
                h="$d"
                while [ "${#h}" -lt 3 ]; do
                    case "${s:$k:1}" in [0-7]) h="$h${s:$k:1}"; k=$((k+1)) ;; *) break ;; esac
                done
                # The byte wraps mod 256, so `\400` is a NUL as well as `\0`.
                [ $((8#$h & 255)) = 0 ] && nul=1 ;;
            # bash masks the control char to 5 bits: `\c@`, `\c`` and `\c ` are all NUL.
            c) case "${s:$k:1}" in '@'|'`'|' ') nul=1 ;; esac; k=$((k+1)) ;;
        esac
        [ "$nul" = 1 ] || continue
        if [ "$k" -lt "${#s}" ]; then
            _bwimc_deny "shell-ambiguous" "\$'$s'" "(a NUL escape inside the span ends the name early)" ""
        fi
        case "$nx" in
            ''|' '|$'\t'|$'\n'|';'|'&'|'|'|'('|')'|'<'|'>') : ;;
            *) _bwimc_deny "shell-ambiguous" "\$'$s'$nx" "(a NUL escape ends the name before the word does)" "" ;;
        esac
    done
}

# _bwimc_ambig_check TEXT — HIMMEL-4138. Walks TEXT as one command (the same
# quote/escape scanner every arm uses) and denies at each unquoted `'` that
# follows a run of active `$` when bash and zsh read the span after it
# differently. An even run (`$$'…'`) is the PID then a plain quote to bash, an
# ANSI-C span to zsh: the readings differ exactly when the span holds a `\`.
# An odd run is ANSI-C to both and goes to _bwimc_ansic_ambig. Callers run it
# on every command text: arm (a) per (sub)command body, and every
# eval/`sh -c` body.
_bwimc_ambig_check() {
    local t="$1" k=0 n c run=0 j s _BWIMC_Q _BWIMC_ESC _BWIMC_ACT _BWIMC_DL
    case "$t" in *"\$'"*) : ;; *) return 0 ;; esac
    n=${#t}
    _bwimc_scan_init
    while [ "$k" -lt "$n" ]; do
        c="${t:$k:1}"
        if [ "$c" = "'" ] && [ "$run" -gt 0 ] && [ -z "$_BWIMC_Q" ] && [ "$_BWIMC_ESC" = 0 ]; then
            j=$((k+1)); s=""
            while [ "$j" -lt "$n" ] && [ "${t:$j:1}" != "'" ]; do
                if [ "${t:$j:1}" = "\\" ]; then s="$s${t:$j:2}"; j=$((j+2)); else s="$s${t:$j:1}"; j=$((j+1)); fi
            done
            if [ $((run % 2)) = 0 ]; then
                case "$s" in
                    *\\*) _bwimc_deny "shell-ambiguous" "\$\$'$s'" "(\$\$' is a plain quote to bash, ANSI-C to zsh)" "" ;;
                esac
            else
                _bwimc_ansic_ambig "$s" "${t:$((j+1)):1}"
            fi
        fi
        _bwimc_scan_step "$c"
        if [ "$c" = '$' ] && [ "$_BWIMC_ACT" = 1 ]; then run=$((run+1)); else run=0; fi
        k=$((k+1))
    done
}

# _bwimc_strip_comments TEXT — HIMMEL-4138. Sets _BWIMC_NC to TEXT with every
# shell comment removed (from an unquoted `#` at the start of a word to the end
# of its line), the second reading the scan below runs. The scanner itself
# does not know comments, so a quote inside one (`$(echo hi # it's⏎)`) opened
# a span that hid every later command. This is the bash/zsh `-c` reading:
# a comment starts after start, blank, newline, `;&|()<>`, a `$(` or a
# backtick, never mid-word, never inside `${…}`, `$((…))`, quotes, or right
# after the `)`/backtick that closes a substitution (`$(true)#a` is a word).
# Only ever an EXTRA reading: the unstripped text is still scanned, so a
# misread here can add a deny, never remove one.
# ponytail: a `case` item's `)` inside `$(…)` closes the body early here, so a
# comment after it stays unstripped (the old reading), HIMMEL-4138.
_bwimc_strip_comments() {
    local t="$1" o="" k=0 n c nx st="C" top prev="" run=0
    local hdok=1 hd=() hdd=() hdk=() hi j w q1 q2 dash body line chk found
    local hdre="^(\"[A-Za-z_][A-Za-z0-9_]*\"|'[A-Za-z_][A-Za-z0-9_]*'|[A-Za-z_][A-Za-z0-9_]*)\$"
    _BWIMC_NC="$t"
    case "$t" in
        \#*|*[[:space:]\;\&\|\(\)\<\>\`]\#*) : ;;
        *) return 0 ;;
    esac
    # `((x<<2))` and `$[x<<2]` shift, they open no heredoc: with either in the
    # text no body is copied through (every line stays strippable).
    # shellcheck disable=SC2016  # literal `$[` is the glob pattern
    if [[ "$t" =~ (^|[^$])\(\( ]]; then hdok=0; fi
    case "$t" in *'$['*) hdok=0 ;; esac
    n=${#t}
    while [ "$k" -lt "$n" ]; do
        c="${t:$k:1}"; top="${st:$((${#st}-1)):1}"
        case "$top" in
            S) o="$o$c"; k=$((k+1)); [ "$c" = "'" ] && st="${st%?}"; prev=w; continue ;;
            A)
                if [ "$c" = "\\" ]; then o="$o${t:$k:2}"; k=$((k+2)); continue; fi
                o="$o$c"; k=$((k+1)); [ "$c" = "'" ] && st="${st%?}"; prev=w; continue ;;
        esac
        if [ "$c" = "\\" ]; then o="$o${t:$k:2}"; k=$((k+2)); prev=w; run=0; continue; fi
        if [ "$top" = D ]; then
            case "$c" in '"'|'$'|'`') : ;; *) o="$o$c"; k=$((k+1)); continue ;; esac
        fi
        nx="${t:$((k+1)):1}"
        case "$c" in
            '$')
                if [ "$nx" = '(' ] && [ "${t:$((k+2)):1}" = '(' ]; then
                    st="${st}RR"; o="$o\$(("; k=$((k+3)); prev=w; run=0; continue
                elif [ "$nx" = '(' ]; then
                    st="${st}c"; o="$o\$("; k=$((k+2)); prev='('; run=0; continue
                elif [ "$nx" = '{' ]; then
                    st="${st}P"; o="$o\${"; k=$((k+2)); prev=w; run=0; continue
                fi
                o="$o$c"; k=$((k+1)); prev=w; run=$((run+1)); continue ;;
            '`')
                if [ "$top" = B ]; then st="${st%?}"; prev=w; else st="${st}B"; prev=''; fi
                o="$o$c"; k=$((k+1)); run=0; continue ;;
            '"')
                if [ "$top" = D ]; then st="${st%?}"; else st="${st}D"; fi
                o="$o$c"; k=$((k+1)); prev=w; run=0; continue ;;
            "'")
                if [ $((run % 2)) = 1 ]; then st="${st}A"; else st="${st}S"; fi
                o="$o$c"; k=$((k+1)); prev=w; run=0; continue ;;
        esac
        run=0
        case "$top" in
            P)
                case "$c" in '{') st="${st}P" ;; '}') st="${st%?}" ;; esac
                o="$o$c"; k=$((k+1)); prev=w; continue ;;
            R)
                case "$c" in '(') st="${st}R" ;; ')') st="${st%?}" ;; esac
                o="$o$c"; k=$((k+1)); prev=w; continue ;;
        esac
        case "$c" in
            '#')
                case "$prev" in
                    ''|' '|$'\t'|$'\n'|';'|'&'|'|'|'('|')'|'<'|'>')
                        while [ "$k" -lt "$n" ] && [ "${t:$k:1}" != $'\n' ]; do k=$((k+1)); done
                        continue ;;
                esac
                prev=w ;;
            '(') st="${st}p"; prev='(' ;;
            ')')
                case "$top" in
                    c) st="${st%?}"; prev=w ;;
                    p) st="${st%?}"; prev=')' ;;
                    *) prev=')' ;;
                esac ;;
            '<')
                # A heredoc opener: its body is literal text, not comments, so
                # it is never stripped. Without this a `#` in a commit
                # message inside `"$(cat <<'EOF'…)"` made a second reading of
                # the whole command (twice the scan time for nothing).
                if [ "$hdok" = 1 ] && [ "$nx" = '<' ] && [ "${t:$((k+2)):1}" != '<' ] && [ "${t:$((k-1)):1}" != '<' ]; then
                    j=$((k+2)); dash=0
                    [ "${t:$j:1}" = '-' ] && { dash=1; j=$((j+1)); }
                    while [ "${t:$j:1}" = ' ' ] || [ "${t:$j:1}" = $'\t' ]; do j=$((j+1)); done
                    w=""
                    while [ "$j" -lt "$n" ]; do
                        case "${t:$j:1}" in [[:space:]]|';'|'&'|'|'|'('|')'|'<'|'>') break ;; esac
                        w="$w${t:$j:1}"; j=$((j+1))
                    done
                    q1="${w//[!\']/}"; q2="${w//[!\"]/}"
                    if [ $(( ${#q1} % 2 )) = 0 ] && [ $(( ${#q2} % 2 )) = 0 ] && [ -n "${w//[\'\"\\]/}" ]; then
                        hd+=("${w//[\'\"\\]/}"); hdd+=("$dash")
                        if [[ "$w" =~ $hdre ]]; then hdk+=(1); else hdk+=(0); fi
                        o="$o${t:$k:$((j-k))}"; k=$j; prev=w; continue
                    fi
                fi
                prev="$c" ;;
            $'\n')
                prev="$c"
                if [ "${#hd[@]}" -gt 0 ]; then
                    # Copy each pending body through its terminator line. A
                    # terminator never found copies nothing: the lines are
                    # then stripped as commands, an extra reading only.
                    # A delimiter _bwimc_blank_heredocs cannot parse (`<<\E`,
                    # `<<$E`, `<<'#'`) left its body unblanked in the first
                    # reading, so a quote there could open a span over a later
                    # write: that body is dropped here, terminator kept
                    # (J1672). A plain one is copied, so this reading stays
                    # identical to the first and is skipped.
                    j=$((k+1)); body=""; found=1
                    for hi in "${!hd[@]}"; do
                        found=0
                        while [ "$j" -lt "$n" ]; do
                            line="${t:$j}"; line="${line%%$'\n'*}"
                            j=$((j+${#line}+1))
                            chk="$line"
                            if [ "${hdd[$hi]}" = 1 ]; then while [ "${chk:0:1}" = $'\t' ]; do chk="${chk#?}"; done; fi
                            [ "$chk" = "${hd[$hi]}" ] && { body="$body$line"$'\n'; found=1; break; }
                            [ "${hdk[$hi]}" = 1 ] && body="$body$line"$'\n'
                        done
                        [ "$found" = 1 ] || break
                    done
                    hd=(); hdd=(); hdk=()
                    if [ "$found" = 1 ]; then
                        [ "$j" -le "$n" ] || { body="${body%?}"; j=$n; }
                        o="$o$c$body"; k=$j; continue
                    fi
                fi ;;
            ' '|$'\t'|';'|'&'|'|'|'>') prev="$c" ;;
            *) prev=w ;;
        esac
        o="$o$c"; k=$((k+1))
    done
    _BWIMC_NC="$o"
}

# --------------------------------------------------------------- scan

_bwimc_cwd=$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null || true)
[ -n "$_bwimc_cwd" ] || _bwimc_cwd="$PWD"

# HIMMEL-4010: the scan parks stubs, clause brackets and decoded chars as
# \001-\005 and \016 markers, so a command carrying one of those raw bytes
# cannot be classified (a symlink named with one reads as another name).
case "$cmd" in
    *[$'\001'$'\002'$'\003'$'\004'$'\005'$'\006'$'\016']*)
        _bwimc_deny "marker-byte" "(raw control byte in command)" "" "" ;;
esac

# HIMMEL-4359: a HOME assignment anywhere in the command (`HOME=x`, a prefix
# `HOME=x cmd`, export/declare/typeset/local/readonly, `env [-i] HOME=x`, and
# a quoted or escaped name those builtins still read as HOME) taints every ~ /
# $HOME expansion: _bwimc_expand_token_raw stops resolving them and
# _bwimc_cd_guard denies them as write targets. Order-blind on purpose — a
# write before the assignment is over-denied, never under-denied.
_bwimc_home_taint=0
_bwimc_home_re='(^|[^A-Za-z0-9_$])HOME[+]?='
if [[ "$cmd" =~ $_bwimc_home_re ]]; then
    _bwimc_home_taint=1
else
    case "$cmd" in
        *OME*|*"\$'"*) [[ "$(_bwimc_unq "$cmd")" =~ $_bwimc_home_re ]] && _bwimc_home_taint=1 ;;
    esac
fi

_bwimc_hb=$(_bwimc_blank_heredocs "$cmd")

# HIMMEL-4138: a comment can hide a quote from the scanner, which knows no
# comments. Every arm below runs once on the text as written and once more
# with its comments removed when that differs, so a command denies when
# EITHER reading writes into the primary.
_bwimc_strip_comments "$_bwimc_hb"
_bwimc_readings=("$_bwimc_hb"); _bwimc_rmodes=(0)
[ "$_BWIMC_NC" = "$_bwimc_hb" ] || { _bwimc_readings+=("$_BWIMC_NC"); _bwimc_rmodes+=(0); }
# HIMMEL-4145/4143: the readings above keep the raw newline transport (mode
# 0) exactly as before. Two more run in mode 1, where a newline inside a
# quoted span travels as \006 (_bwimc_split_clauses), on text whose heredoc
# bodies inside a double-quoted `$(…)` are also blanked — so neither a body
# apostrophe nor a quoted newline can hide a write. They only ADD readings:
# the raw split still resynchronises the quote scan line by line where a
# body the flat blanker cannot parse (`<<\E`) leaves a stray quote open.
# ponytail: a long quoted multi-line span is one long clause here, so a
# multi-line single-quoted message costs about 2x the char scan of base (no
# size gate: padding past one would reopen HIMMEL-4143), perf fix HIMMEL-4164.
_bwimc_hbn=$(_bwimc_blank_heredocs "$cmd" nest)
case "$_bwimc_hbn" in
    *"$_BWIMC_NL"*)
        _bwimc_readings+=("$_bwimc_hbn"); _bwimc_rmodes+=(1)
        _bwimc_strip_comments "$_bwimc_hbn"
        [ "$_BWIMC_NC" = "$_bwimc_hbn" ] || { _bwimc_readings+=("$_BWIMC_NC"); _bwimc_rmodes+=(1); } ;;
esac

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

# _bwimc_is_shc_cflag TOKEN — HIMMEL-3648 (codex-3). True iff TOKEN is a
# single-dash, all-letters short-option cluster containing `c` (bash/sh/zsh's
# own getopt-style combined short flags: `-c`, `-ce`, `-ec`, `-xc`, …) — real
# shells accept the string-to-run argument right after such a cluster exactly
# as they do after a bare `-c`. Excludes any `--long-option` (second char is
# `-`, never a letter) so `--rcfile` is never mistaken for this.
_bwimc_is_shc_cflag() {
    case "$1" in
        --*) return 1 ;;
        -*) ;;
        *) return 1 ;;
    esac
    local rest="${1#-}"
    [ -n "$rest" ] || return 1
    case "$rest" in
        *[!a-zA-Z]*) return 1 ;;
    esac
    case "$rest" in
        *c*) return 0 ;;
    esac
    return 1
}

# _bwimc_check_interp_body CLAUSE_SP KIND — HIMMEL-3648. `eval "BODY"` /
# `bash -c "BODY"` / `sh -c "BODY"` / `zsh -c "BODY"` hide a write-shaped
# command inside a STRING argument the arms above never look at. Per the
# ticket: do not re-parse BODY as a command (clause-split it, walk verb
# arms) — just word-split it with the existing tokenizer and run every
# resulting non-operator token through the same destination check every
# other arm uses. A token that resolves inside the primary denies; every
# other token (verbs, flags, benign operands, sources) resolves elsewhere
# and is silently ignored, exactly like today's read-only cp/mv sources.
# This is deliberately coarse — it does not know which token is a
# "destination" — but the ticket's own words are "prefer fail-closed over
# modelling", and a check that ALSO looks at a benign source token can only
# ever ADD a false-positive deny on an already-primary path, never miss a
# real write into it.
# ponytail: a dynamic token ($VAR, `cmd`) inside BODY does not resolve and
# is not further modelled — same residual _bwimc_check_target already
# accepts for every other arm (HIMMEL-3648).
_bwimc_check_interp_body() {
    local kind="$2" toks=() t t2 n i j0 cidx body="" _bwimc_ibody_clause="" _bwimc_ib_text="" _bwimc_ib_texts=() \
        _bwimc_ibody_clause_sp="" _bwimc_ibc_toks=() _bwimc_ibc_n=0 _bwimc_m="" _bwimc_ib_cw=0 _bwimc_ib_ro=0 \
        _bwimc_ibody_saved_ecwd="" _bwimc_ibody_saved_unres=""
    toks=()
    while IFS= read -r t; do toks+=("$t"); done < <(_bwimc_tokenize "$1")
    n=${#toks[@]}
    # HIMMEL-4138: KIND `wrap` — the shell or eval sits behind a wrapper
    # (`nice`, `timeout 5`, `env FOO=1`, `FOO=1`, `sudo -n`, `xargs`, …), so
    # find the first token that IS one (unquoted, any path, any case, `.exe`)
    # and read the body after it. `su`/`runuser`/`flock` run their `-c`
    # string through a shell too. No such token: nothing to scan.
    j0=1
    if [ "$kind" = wrap ]; then
        # HIMMEL-4476: a grep (leading assignments and keywords skipped) runs
        # no command, so an `eval`/`sh` word after it is a pattern or a file
        # operand, not a shell: `grep -n 'eval' <primary>/x` read the path as
        # an eval body. Its redirects are the outer arms' job. ugrep's
        # --filter runs commands and --save-config writes a file in the cwd,
        # so any `--fil…`/`--sa…` option, or a substitution, keeps the scan.
        i=0
        while [ "$i" -lt "$n" ]; do
            case "${toks[$i]}" in
                [A-Za-z_]*=*|'!'|if|then|elif|else|while|until|do|'{') i=$((i+1)) ;;
                *) break ;;
            esac
        done
        if [ "$i" -lt "$n" ]; then
            t=$(_bwimc_unq "${toks[$i]}"); t="${t##*/}"
            _tolower_ascii "$t"; t="${_TOLOWER_OUT%.exe}"
            case "$t" in
                grep|egrep|fgrep)
                    # Quotes and backslashes are dropped first, so a quoted
                    # or split '--save-config' still reads as the option.
                    t="${1//[\'\"\\]/}"
                    # shellcheck disable=SC2016  # literal `$(` is the glob pattern
                    case "$1" in
                        *'`'*|*'$('*|*'<('*|*'>('*) ;;
                        *) case "$t" in
                               *--[Ff][Ii][Ll]*|*--[Ss][Aa]*) ;;
                               *) return 0 ;;
                           esac ;;
                    esac ;;
            esac
        fi
        kind=""; i=0
        while [ "$i" -lt "$n" ]; do
            t=$(_bwimc_unq "${toks[$i]}"); t="${t##*/}"
            _tolower_ascii "$t"; t="${_TOLOWER_OUT%.exe}"
            case "$t" in
                eval) kind="eval"; break ;;
                bash|sh|zsh|dash|ksh|su|runuser|flock) kind=shc; break ;;
            esac
            i=$((i+1))
        done
        [ -n "$kind" ] || return 0
        j0=$((i+1))
    fi
    if [ "$kind" = eval ]; then
        i=$j0
        while [ "$i" -lt "$n" ]; do
            [ -n "$body" ] && body="$body "
            body="$body$(_bwimc_unq "${toks[$i]}")"
            i=$((i+1))
        done
    else
        cidx=-1
        i=$j0
        while [ "$i" -lt "$n" ]; do
            _bwimc_is_shc_cflag "$(_bwimc_unq "${toks[$i]}")" && { cidx=$((i+1)); break; }
            i=$((i+1))
        done
        [ "$cidx" -ge 0 ] && [ "$cidx" -lt "$n" ] && body=$(_bwimc_unq "${toks[$cidx]}")
    fi
    [ -n "$body" ] || return 0
    _bwimc_ambig_check "$body"
    case "$body" in
        *'>'*) : ;;
        *) case "$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')" in
               *cp*|*mv*|*rm*|*touch*|*ln*|*tee*|*sed*|*install*|*rsync*|*dd*|*cd*|*pushd*|*git*|*commit*) : ;;
               *) return 0 ;;
           esac ;;
    esac
    # HIMMEL-3648 round 4 (codex-1): the round-3 fix tracked cwd across the
    # WHOLE body first and only then checked every token/`git … commit`
    # against that final cwd — correct for a body that never cd's again
    # after its last write, wrong otherwise: `bash -c 'cd <primary>; echo x
    # > a.txt; cd <wt>'` tracked to <wt> (the body's END state) and checked
    # "a.txt" against <wt>, allowing a real write into <primary>. A write (or
    # a `git … commit`) must be checked against the cwd AS OF THAT POINT in
    # the body, not wherever the body cd's to afterwards. Fix: track AND
    # check PER CLAUSE, in order, exactly like the main outer loop already
    # does for the top-level command (line ~1663 tracks, line ~3706 checks
    # git-commit, both inside the SAME per-clause iteration) — do not
    # re-derive body-wide flags/tokens first and check them once the cwd has
    # moved on. Save/restore both globals so this stays scoped to THIS
    # interp body and never leaks to a sibling outer clause.
    _bwimc_ibody_saved_ecwd="$_bwimc_ecwd"
    _bwimc_ibody_saved_unres="$_bwimc_ecwd_unres"
    _bwimc_ibody_saved_pushn="$_bwimc_ecwd_pushn"
    # HIMMEL-4138: the body once as written, once with its comments removed.
    _bwimc_strip_comments "$body"
    _bwimc_ib_texts=("$body")
    [ "$_BWIMC_NC" = "$body" ] || _bwimc_ib_texts+=("$_BWIMC_NC")
    for _bwimc_ib_text in "${_bwimc_ib_texts[@]}"; do
    _bwimc_ecwd="$_bwimc_ibody_saved_ecwd"
    _bwimc_ecwd_unres="$_bwimc_ibody_saved_unres"
    _bwimc_ecwd_pushn="$_bwimc_ibody_saved_pushn"
    while IFS= read -r _bwimc_ibody_clause; do
        [ -n "$(printf '%s' "$_bwimc_ibody_clause" | tr -d '[:space:]')" ] || continue
        _bwimc_clause_unpipe _bwimc_ibody_clause
        _bwimc_ibody_clause_sp=$(_bwimc_space_before_redirects "$_bwimc_ibody_clause")
        _bwimc_ecwd_track "$_bwimc_ibody_clause_sp" "$_bwimc_clause_piped"
        if _bwimc_m=$(printf '%s' "$_bwimc_ibody_clause_sp" | tr '[:upper:]' '[:lower:]' | grep -E '^[[:space:]]*git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit([[:space:]]|$)') && [ -n "$_bwimc_m" ]; then
            _bwimc_git_commit_target "$_bwimc_ibody_clause_sp" "$_bwimc_ecwd"
            if [ "$_BWIMC_GIT_TARGET_UNRESOLVED" = 1 ]; then
                _bwimc_deny "unresolved-git-target" "$1" "$_BWIMC_GIT_TARGET_DIR" ""
            fi
            if [ "$_bwimc_sourced" = 1 ]; then
                _bwimc_cwd_check_sourced "$_BWIMC_GIT_TARGET_DIR"
            else
                _bwimc_cwd_check_direct "$_BWIMC_GIT_TARGET_DIR"
            fi
        fi
        _bwimc_ibc_toks=()
        while IFS= read -r t; do _bwimc_ibc_toks+=("$t"); done < <(_bwimc_tokenize "$_bwimc_ibody_clause_sp")
        _bwimc_ibc_n=${#_bwimc_ibc_toks[@]}
        # HIMMEL-4476: from the primary cwd every bare word resolves into it,
        # so a loop keyword (`until`, `do`) or the operand of a command that
        # writes no file (`sleep 0.1`, `[ -e x ]`) denied. Leading reserved
        # words are skipped; for a read-only command word (raw, unquoted) in
        # a clause with no substitution only redirects are checked. Every
        # other clause keeps the coarse every-token check.
        _bwimc_ib_cw=0; _bwimc_ib_ro=0
        while [ "$_bwimc_ib_cw" -lt "$_bwimc_ibc_n" ]; do
            case "${_bwimc_ibc_toks[$_bwimc_ib_cw]}" in
                '!'|'{'|'}'|if|then|elif|else|fi|while|until|do|done) _bwimc_ib_cw=$((_bwimc_ib_cw+1)) ;;
                *) break ;;
            esac
        done
        if [ "$_bwimc_ib_cw" -lt "$_bwimc_ibc_n" ]; then
            case "${_bwimc_ibc_toks[$_bwimc_ib_cw]}" in
                sleep|test|'['|'[['|true|false|:|echo|printf)
                    # shellcheck disable=SC2016  # literal `$(` is the glob pattern
                    case "$_bwimc_ibody_clause_sp" in
                        *'`'*|*'$('*|*'<('*|*'>('*) ;;
                        *) _bwimc_ib_ro=1 ;;
                    esac ;;
            esac
        fi
        i=0
        while [ "$i" -lt "$_bwimc_ibc_n" ]; do
            t="${_bwimc_ibc_toks[$i]}"
            if _bwimc_redirect_op_of "$t"; then
                # HIMMEL-3648 (codex-1): an attached target (`>/primary/f`, one
                # token) was ignored — this loop unconditionally advanced to the
                # NEXT token and checked THAT, the same false-negative shape the
                # main clause loop's own _bwimc_op_rest handling (line ~1693)
                # exists to close. Mirrors that idiom, including the write-only
                # gate so a read redirect stays allowed.
                if [ -n "$_bwimc_op_rest" ]; then
                    case "$_bwimc_op_rest" in
                        '&'*) : ;;
                        *) [ "$_bwimc_op_write" = 1 ] && { _bwimc_cd_guard "$_bwimc_op_rest"; _bwimc_check_target "$_bwimc_op_rest" "$_bwimc_ecwd"; } ;;
                    esac
                    i=$((i+1))
                else
                    i=$((i+1))
                    if [ "$i" -lt "$_bwimc_ibc_n" ]; then
                        t2="${_bwimc_ibc_toks[$i]}"
                        case "$t2" in
                            '&'*) : ;;
                            *) [ "$_bwimc_op_write" = 1 ] && { _bwimc_cd_guard "$t2"; _bwimc_check_target "$t2" "$_bwimc_ecwd"; } ;;
                        esac
                    fi
                    i=$((i+1))
                fi
                continue
            fi
            if [ "$i" -lt "$_bwimc_ib_cw" ] || [ "$_bwimc_ib_ro" = 1 ]; then
                i=$((i+1)); continue
            fi
            case "$t" in
                -*)
                    # HIMMEL-3648 (CodeRabbit #1307 thread, "Heavy lift"
                    # finding, partial fix): a long option's value is
                    # ATTACHED with `=` (`--target-directory=PATH`) and is
                    # itself a write destination — the bare `-*` skip
                    # dropped it unchecked. Same coarse `=`-value check as
                    # the non-flag branch below, just not excluded by the
                    # leading `-`.
                    case "$t" in
                        *=*) _bwimc_cd_guard "${t#*=}"; _bwimc_check_target "${t#*=}" "$_bwimc_ecwd" ;;
                    esac
                    ;;
                *)
                    _bwimc_cd_guard "$t"; _bwimc_check_target "$t" "$_bwimc_ecwd"
                    # HIMMEL-3648 (CR #1307): a bare key=value token inside a
                    # body — dd's `of=PATH` above all — is a write
                    # destination this generic non-flag-token check never
                    # isolates on its own, since the whole "of=PATH" string
                    # never resolves as PATH itself. Also check the value
                    # after the first `=`, same coarse tolerance the rest of
                    # this scan already accepts for a benign source token.
                    case "$t" in
                        *=*) _bwimc_cd_guard "${t#*=}"; _bwimc_check_target "${t#*=}" "$_bwimc_ecwd" ;;
                    esac
                    ;;
            esac
            i=$((i+1))
        done
    done < <(_bwimc_split_clauses "$_bwimc_ib_text")
    done
    _bwimc_ecwd="$_bwimc_ibody_saved_ecwd"
    _bwimc_ecwd_unres="$_bwimc_ibody_saved_unres"
    _bwimc_ecwd_pushn="$_bwimc_ibody_saved_pushn"
}

# _bwimc_subst_paren_end TEXT START — HIMMEL-3622. Sets _BWIMC_PEND to the index
# of the `)` that closes a `$(` whose body begins at START (TEXT length when it
# never closes, so an unterminated body is scanned to the end, never dropped).
# The body is a fresh command context: a fresh scanner state, so only ACTIVE
# parens count (a `)` inside quotes is text); a nested `$(...)` (recursively)
# or backtick span is skipped whole, quoted or not. A `case` item's `)` is not a terminator: active `case`/`esac` words
# are counted and a `)` inside an open `case` is skipped (an argument spelled
# `case` over-extends the body to the end of TEXT, which only over-scans).
# Clobbers the shared scanner state — callers save/restore it.
_bwimc_subst_paren_end() {
    local text="$1" j="$2" len=${#1} depth=1 ch w="" cs=0 bd=0 sq se sa
    _bwimc_scan_init
    while [ "$j" -lt "$len" ]; do
        ch="${text:$j:1}"
        # A nested substitution is parsed on its own, in or out of double
        # quotes: its body has a quote state of its own, so the flat scan here
        # would pair the quotes inside it wrongly and end THIS body early.
        if [ "$_BWIMC_ESC" != 1 ] && [ "$_BWIMC_Q" != "'" ] && [ "$_BWIMC_Q" != A ]; then
            if [ "$ch" = '$' ] && [ "${text:$((j+1)):1}" = '(' ] && [ "${text:$((j+2)):1}" != '(' ]; then
                sq="$_BWIMC_Q"; se="$_BWIMC_ESC"; sa="$_BWIMC_ACT"
                _bwimc_subst_paren_end "$text" $((j+2))
                _BWIMC_Q="$sq"; _BWIMC_ESC="$se"; _BWIMC_ACT="$sa"; _BWIMC_DL=0
                j=$((_BWIMC_PEND+1)); w=""
                continue
            elif [ "$ch" = '`' ]; then
                j=$((j+1))
                while [ "$j" -lt "$len" ] && [ "${text:$j:1}" != '`' ]; do
                    [ "${text:$j:1}" = "\\" ] && j=$((j+1))
                    j=$((j+1))
                done
                j=$((j+1)); w=""; _BWIMC_DL=0
                continue
            fi
            # A `)` inside a `${...}` expansion (`${y:-)}`, `${y#)}`) is text,
            # not the closer: count the braces and ignore parens while open.
            if [ "$ch" = '$' ] && [ "${text:$((j+1)):1}" = '{' ]; then
                bd=$((bd+1))
            elif [ "$ch" = '}' ] && [ "$bd" -gt 0 ]; then
                bd=$((bd-1))
            fi
        fi
        _bwimc_scan_step "$ch"
        if [ "$_BWIMC_ACT" = 1 ]; then
            case "$ch" in
                [A-Za-z0-9_]) w="$w$ch"; j=$((j+1)); continue ;;
            esac
            case "$w" in
                'case') cs=$((cs+1)) ;;
                'esac') [ "$cs" -gt 0 ] && cs=$((cs-1)) ;;
            esac
            w=""
            case "$ch" in
                '(') [ "$bd" -gt 0 ] || depth=$((depth+1)) ;;
                ')') [ "$cs" -gt 0 ] || [ "$bd" -gt 0 ] || { depth=$((depth-1)); [ "$depth" -gt 0 ] || break; } ;;
            esac
        fi
        j=$((j+1))
    done
    [ "$j" -le "$len" ] || j=$len
    _BWIMC_PEND=$j
}

# _bwimc_subst_split TEXT — HIMMEL-3622. Splits TEXT into a SKELETON and the
# bodies of its TOP-LEVEL command substitutions, `$(...)` and backtick alike:
# _BWIMC_SKEL is TEXT with each substitution body replaced by one \001 byte
# (`$(\001)`, backtick-\001-backtick), and _BWIMC_BODIES lists the bodies in
# order. A substitution runs as its own command even inside a double-quoted
# span, where the shared scanner marks every character inert — so a redirect in
# `x="$(echo hi > P/f)"` was invisible to the redirect arm. Only a SINGLE-quoted
# span or an escaped `$`/backtick is literal text. Each body is found with its
# own fresh scan (so quotes inside it do not confuse the outer walk) and the
# outer walk jumps over it; a nested body is reached when the caller splits the
# body it got. The skeleton, not TEXT, is what gets cut into clauses: a quote
# nested inside a double-quoted substitution pairs differently from the way the
# scanner reads it, so clause-splitting raw TEXT tore such a body apart.
# `$((` is arithmetic, not a substitution. Callers run this on the
# heredoc-BLANKED text, so `git commit -m "$(cat <<'EOF' … EOF)"` yields only
# `cat <<'EOF'` plus blank lines: message text never becomes a phantom target.
_bwimc_subst_split() {
    # \001 is the stub marker, so a real one in the input would be counted as a
    # stub and consume a body in the wrong clause; bash treats it as a plain
    # word byte, so `_` keeps every word and path boundary intact.
    local text="${1//$'\001'/_}" i=0 len c q e body sq se sa j end m
    text="${text//$'\005'/_}"
    len=${#text}
    _BWIMC_SKEL=""; _BWIMC_BODIES=()
    _bwimc_scan_init
    while [ "$i" -lt "$len" ]; do
        c="${text:$i:1}"; q="$_BWIMC_Q"; e="$_BWIMC_ESC"
        body=""; end=-1
        if [ "$e" != 1 ] && [ "$q" != "'" ] && [ "$q" != A ]; then
            if [ "$c" = '`' ]; then
                j=$((i+1))
                while [ "$j" -lt "$len" ] && [ "${text:$j:1}" != '`' ]; do
                    [ "${text:$j:1}" = "\\" ] && j=$((j+1))
                    j=$((j+1))
                done
                [ "$j" -le "$len" ] || j=$len
                # Bash drops the backslash before `$`, a backtick and `\` (and
                # before `"` inside double quotes) in ONE left-to-right pass;
                # a `\$(` left escaped would hide a nested body from the recursion.
                sa="${text:$((i+1)):$((j-i-1))}"; body=""; se=0
                while [ "$se" -lt "${#sa}" ]; do
                    sq="${sa:$se:1}"
                    if [ "$sq" = "\\" ]; then
                        case "${sa:$((se+1)):1}" in
                            '$'|'`'|"\\") se=$((se+1)) ;;
                            '"') [ "$q" = '"' ] && se=$((se+1)) ;;
                        esac
                        sq="${sa:$se:1}"
                    fi
                    body="$body$sq"; se=$((se+1))
                done
                end=$j
            elif [ "$c" = '$' ] && [ "${text:$((i+1)):1}" = '(' ] && [ "${text:$((i+2)):1}" != '(' ]; then
                sq="$_BWIMC_Q"; se="$_BWIMC_ESC"; sa="$_BWIMC_ACT"
                _bwimc_subst_paren_end "$text" $((i+2))
                _BWIMC_Q="$sq"; _BWIMC_ESC="$se"; _BWIMC_ACT="$sa"
                end=$_BWIMC_PEND
                body="${text:$((i+2)):$((end-i-2))}"
            fi
        fi
        if [ "$end" -ge 0 ]; then
            # HIMMEL-4010: a bare `pwd` body writes nothing and expands to the
            # cwd, so it gets a stub of its own (\005) that _bwimc_check_target
            # reads as the cwd, and no body to scan.
            sq="${body#"${body%%[![:space:]]*}"}"
            sq="${sq%"${sq##*[![:space:]]}"}"
            case "$sq" in
                pwd|'pwd -P'|'pwd -L') m=$'\005' ;;
                *) m=$'\001'; _BWIMC_BODIES+=("$body") ;;
            esac
            if [ "$c" = '`' ]; then
                _BWIMC_SKEL="$_BWIMC_SKEL"'`'"$m"'`'
            else
                # shellcheck disable=SC2016  # literal `$(`, not an expansion
                _BWIMC_SKEL="$_BWIMC_SKEL"'$('"$m"')'
            fi
            i=$((end+1)); _BWIMC_DL=0
            continue
        fi
        _BWIMC_SKEL="$_BWIMC_SKEL$c"
        _bwimc_scan_step "$c"
        i=$((i+1))
    done
}

# _bwimc_redir_scan_text TEXT — arm (a), the redirect/tee per-clause walk, as a
# function so it can recurse (HIMMEL-3622). After each clause is walked, the
# command substitutions inside THAT clause are scanned as their own commands,
# from the cwd state the clause left and with that state restored after, so a
# body's `cd` never leaks out and a body sees the `cd` that preceded it.
_bwimc_redir_scan_text() {
local _bwimc_rclause _bwimc_rclause_sp _bwimc_rtoks _bwimc_t _bwimc_rn _bwimc_teecmd \
    _bwimc_pfx _bwimc_pflag _bwimc_ri _bwimc_teecollect _bwimc_tee_dd _bwimc_rt \
    _bwimc_rt2 _bwimc_skel _bwimc_sbodies _bwimc_sbi _bwimc_stubs _bwimc_sn \
    _bwimc_sb_ecwd _bwimc_sb_unres _bwimc_sb_pushn \
    _bwimc_pre_ecwd _bwimc_pre_unres _bwimc_pre_pushn _bwimc_rclause_piped
_bwimc_skel="$1"; _bwimc_sbodies=(); _bwimc_sbi=0
_bwimc_ambig_check "$1"
# shellcheck disable=SC2016  # literal `$(` is the glob pattern, not an expansion
case "$1" in
    *'$('*|*'`'*)
        _bwimc_subst_split "$1"
        _bwimc_skel="$_BWIMC_SKEL"
        for _bwimc_sn in ${_BWIMC_BODIES[@]+"${!_BWIMC_BODIES[@]}"}; do
            _bwimc_sbodies+=("${_BWIMC_BODIES[$_bwimc_sn]}")
        done
        ;;
esac
while IFS= read -r _bwimc_rclause; do
    ! _bwimc_is_colon "$_bwimc_rclause" || continue
    [ -n "$(printf '%s' "$_bwimc_rclause" | tr -d '[:space:]')" ] || continue
    _bwimc_clause_unpipe _bwimc_rclause
    _bwimc_rclause_piped="$_bwimc_clause_piped"
    _bwimc_rclause_sp=$(_bwimc_space_before_redirects "$_bwimc_rclause")
    # A body expands BEFORE its own clause runs, so it is judged at the cwd the
    # clause STARTS in, not the one the clause (a `cd` it carries) leaves.
    _bwimc_pre_ecwd="$_bwimc_ecwd"; _bwimc_pre_unres="$_bwimc_ecwd_unres"; _bwimc_pre_pushn="$_bwimc_ecwd_pushn"
    _bwimc_ecwd_track "$_bwimc_rclause_sp" "$_bwimc_rclause_piped"
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
                    *) [ "$_bwimc_op_write" = 1 ] && { _bwimc_cd_guard "$_bwimc_op_rest"; _bwimc_check_target "$_bwimc_op_rest" "$_bwimc_ecwd"; } ;;
                esac
            else
                _bwimc_ri=$((_bwimc_ri+1))
                if [ "$_bwimc_ri" -lt "$_bwimc_rn" ]; then
                    _bwimc_rt2="${_bwimc_rtoks[$_bwimc_ri]}"
                    case "$_bwimc_rt2" in
                        '&'*) : ;;  # fd-dup (2> &1 — no file target)
                        *) [ "$_bwimc_op_write" = 1 ] && { _bwimc_cd_guard "$_bwimc_rt2"; _bwimc_check_target "$_bwimc_rt2" "$_bwimc_ecwd"; } ;;
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
                    _bwimc_cd_guard "$_bwimc_rt"
                    _bwimc_check_target "$_bwimc_rt" "$_bwimc_ecwd"
                elif [ "$_bwimc_rt" = "--" ]; then
                    _bwimc_tee_dd=1
                else
                    case "$_bwimc_rt" in
                        -*) : ;;
                        *) _bwimc_cd_guard "$_bwimc_rt"; _bwimc_check_target "$_bwimc_rt" "$_bwimc_ecwd" ;;
                    esac
                fi
            fi
            _bwimc_ri=$((_bwimc_ri+1))
        fi
    done
    # The bodies of THIS clause's stubs, in order, each as a command of its own.
    _bwimc_stubs="${_bwimc_rclause//[!$'\001']/}"
    _bwimc_sn=${#_bwimc_stubs}
    while [ "$_bwimc_sn" -gt 0 ] && [ "$_bwimc_sbi" -lt "${#_bwimc_sbodies[@]}" ]; do
        _bwimc_sb_ecwd="$_bwimc_ecwd"; _bwimc_sb_unres="$_bwimc_ecwd_unres"; _bwimc_sb_pushn="$_bwimc_ecwd_pushn"
        _bwimc_ecwd="$_bwimc_pre_ecwd"; _bwimc_ecwd_unres="$_bwimc_pre_unres"; _bwimc_ecwd_pushn="$_bwimc_pre_pushn"
        _bwimc_redir_scan_text "${_bwimc_sbodies[$_bwimc_sbi]}"
        _bwimc_ecwd="$_bwimc_sb_ecwd"; _bwimc_ecwd_unres="$_bwimc_sb_unres"; _bwimc_ecwd_pushn="$_bwimc_sb_pushn"
        _bwimc_sbi=$((_bwimc_sbi+1)); _bwimc_sn=$((_bwimc_sn-1))
    done
done < <(_bwimc_split_clauses "$_bwimc_skel" skel)
}
# HIMMEL-4198/4174: each reading again with `$((…))`/array values flattened
# and continuations joined, so the verb after `x=$((1|2))` or `x=(a b)` shows.
for _bwimc_afi in "${!_bwimc_readings[@]}"; do
    _bwimc_assign_flat "${_bwimc_readings[$_bwimc_afi]}"
    _bwimc_flat_mask "${_bwimc_readings[$_bwimc_afi]}"
    [ "$_BWIMC_AF" = "${_bwimc_readings[$_bwimc_afi]}" ] \
        || { _bwimc_readings+=("$_BWIMC_AF"); _bwimc_rmodes+=("${_bwimc_rmodes[$_bwimc_afi]}"); }
done
_BWIMC_WRAP_RE='(^|[[:space:]/])(bash|sh|zsh|dash|ksh|su|runuser|flock|eval)(\.exe)?([[:space:]]|$)'
for _bwimc_ri in "${!_bwimc_readings[@]}"; do
_bwimc_hb="${_bwimc_readings[$_bwimc_ri]}"
_BWIMC_NLENC="${_bwimc_rmodes[$_bwimc_ri]}"
_bwimc_ecwd="$_bwimc_cwd"
_bwimc_ecwd_unres=0
_bwimc_ecwd_pushn=0
_bwimc_redir_scan_text "$_bwimc_hb"

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
# ALLOWS, even though a `config`/`remote` write, `branch -u|--unset-upstream|
# -M|-C|-f` onto main|master, `checkout -B`/`switch -C` onto main|master, or
# `update-ref`/`symbolic-ref` on refs/heads/main|master lands in the
# worktree's SHARED $GIT_COMMON_DIR, which the PRIMARY checkout also reads.
# For exactly those subcommands/flags, the target's OWNING primary checkout
# (`primary_checkout_root`; a no-op for an ordinary non-worktree repo) is
# checked too (`_bwimc_git_check_common_owner`) — so a leg cwd'd into its own
# worktree can no longer repoint the primary's upstream/HEAD-tracked refs by
# omitting `-C <primary>`. Narrowed the other way (adversarial review round
# 1): `config --global/--system/--worktree` write a DIFFERENT file, not the
# shared repo config, and are exempt; `config -f/--file <path>` is checked
# against the resolved path itself (the ordinary file-target check), not the
# repo root, so a path outside any repo is exempt too; `remote update/prune/
# show` are fetch-shaped and exempt (`get-url` never reaches here — already
# read-shaped); the branch flags above trigger ONLY with an EXPLICIT
# main/master operand (round 2 — `-u origin/x` with no branch name given
# targets the CURRENT branch, never main in a linked worktree, matching the
# already-allowed `push -u`). `update-ref`/`symbolic-ref -m <reason>` now consumes the
# reason value instead of misreading it as the ref-name positional, and
# `--stdin` (refs arrive on stdin, invisible to this scanner) is denied
# outright rather than silently passed.
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
# displaced behind a wrapper _bwimc_strip_prefix does not model (setsid,
# watch, parallel, `find -exec`; HIMMEL-4365 covers the modelled ones and
# xargs, see _bwimc_git_wrapped) or inside an interpreter body is missed, the
# same residual as every other arm. A `cd` inside a conditional (`false && cd <primary>`) is assumed
# to have run, and a write is ALSO checked from every cwd a cd left, so
# `false && cd <leg>; git merge x` from the primary is still caught; the cost
# is that `cd <leg> && git merge x` typed from the primary is denied too.
# Shared-ref writes from the leg's own worktree (no -C) are checked against
# the common dir's owning primary for `config`/`remote`/`branch
# -u|--unset-upstream|-M|-C|-f`/`checkout -B`/`switch -C`/`update-ref`/
# `symbolic-ref` on refs/heads/main|master (HIMMEL-3407, above); `tag`,
# `reflog expire|delete`, and any other branch create/delete/plain-rename are
# still reachable that way — narrower residual, same ticket. `git -c alias.x=…` and repo-level
# hooks are code execution in the leg's own process, not a primary-state
# write, and are out of scope. `worktree move|remove` of the primary is left
# to git itself, which refuses to move or remove a main working tree.
# HIMMEL-4504: a read aimed at the primary that RUNS A PROGRAM there (a -c /
# --config-env key off a safe allowlist, a pager, --exec-path=, --ext-diff /
# --textconv, `grep -O`, a GIT_PAGER/GIT_EXTERNAL_DIFF/GIT_EXEC_PATH-style
# env) loses the read relief; `worktree move|add` get their destination's
# file verdict. ponytail: a program named by config set in an EARLIER
# command (~/.gitconfig, the primary's own config) or reached via a foreign
# --git-dir is not seen, and plain `git diff` runs diff.external by default;
# revisit if a config-provenance check lands (HIMMEL-4504 follow-up).
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
    # HIMMEL-4143: a newline inside a quoted span travels as \006 in clause
    # transport (_bwimc_split_clauses); the word itself carries the newline.
    t="${t//$'\006'/$'\n'}"
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

# HIMMEL-4504: a read-shaped git clause can still RUN A PROGRAM — a pager, an
# external diff or textconv driver, an fsmonitor, a credential helper, a git
# found via --exec-path — and that program runs with the target repo as its
# cwd, so aimed at the primary it can write there. Such a clause loses the
# read relief and gets the ordinary repo-root verdict.
# _bwimc_pager_ok VALUE — rc 0 for a pager value that runs nothing arbitrary.
_bwimc_pager_ok() {
    case "$1" in ""|cat|less|more|"less -R"|"less -FRX") return 0 ;; esac
    return 1
}

# _bwimc_cfg_safe KEY[=VALUE] [noval] — rc 0 when a -c / --config-env override
# cannot make git run a program. An ALLOWLIST: an unknown key fails closed.
# `noval` (--config-env) means the value comes from the environment, unseen.
_bwimc_cfg_safe() {
    local v=""
    case "$1" in *=*) v="${1#*=}" ;; esac
    [ "${2:-}" != noval ] || v='$'
    _tolower_ascii "${1%%=*}"
    case "$_TOLOWER_OUT" in
        color.*|column.*|advice.*|pretty.*|format.pretty|safe.directory|\
        user.name|user.email|core.quotepath|core.abbrev|init.defaultbranch|\
        i18n.logoutputencoding|log.date|log.decorate|log.abbrevcommit|log.follow|\
        log.showroot|log.mailmap|diff.renames|diff.renamelimit|diff.noprefix|\
        diff.mnemonicprefix|diff.algorithm|diff.context|diff.interhunkcontext|\
        diff.indentheuristic|diff.colormoved|diff.colormovedws|diff.statgraphwidth|\
        diff.relative|diff.suppressblankempty|grep.linenumber|grep.column|\
        grep.patterntype|grep.extendedregexp|grep.fullname|status.short|\
        status.branch|status.showuntrackedfiles|status.relativepaths|\
        status.aheadbehind|status.renames|gc.auto|maintenance.auto)
            return 0 ;;
        core.pager) _bwimc_pager_ok "$v"; return ;;
        pager.*)
            case "$v" in true|false|yes|no|on|off|0|1) return 0 ;; esac
            _bwimc_pager_ok "$v"; return ;;
    esac
    return 1
}

# _bwimc_env_prog NAME=VALUE — rc 0 when an env assignment can make a
# read-shaped git clause run a program (a blocklist: env is open-ended).
_bwimc_env_prog() {
    local v
    v=$(_bwimc_unq "${1#*=}")
    case "${1%%=*}" in
        GIT_PAGER|PAGER) ! _bwimc_pager_ok "$v"; return ;;
        GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM) [ "$v" != /dev/null ]; return ;;
        GIT_CONFIG_KEY_*) ! _bwimc_cfg_safe "$v" noval; return ;;
        # the ext:: transport runs its URL as a command once allowed
        GIT_ALLOW_PROTOCOL) case "$v" in *ext*) return 0 ;; esac; return 1 ;;
        # HOME / XDG_CONFIG_HOME pick another global config, like
        # GIT_CONFIG_GLOBAL (core.fsmonitor, core.pager, …). Also the class
        # that makes git or a child (ssh, less, /bin/sh, the loader) run code:
        # SSH_ASKPASS*, LESSOPEN/LESSCLOSE, LD_*, BASH_ENV/ENV, PATH.
        GIT_EXTERNAL_DIFF|GIT_EXEC_PATH|GIT_CONFIG_PARAMETERS|GIT_SSH|\
        GIT_SSH_COMMAND|GIT_ASKPASS|GIT_PROXY_COMMAND|HOME|XDG_CONFIG_HOME|\
        SSH_ASKPASS|SSH_ASKPASS_REQUIRE|LESSOPEN|LESSCLOSE|LD_PRELOAD|\
        LD_AUDIT|LD_LIBRARY_PATH|BASH_ENV|ENV|PATH) return 0 ;;
    esac
    return 1
}

# _bwimc_git_args_prog SUB ARG... — rc 0 when the subcommand's own options run
# a program: --ext-diff / --textconv (a configured diff driver), `cat-file
# --filters` (smudge filters), `grep -O` / --open-files-in-pager[=<cmd>],
# `ls-remote --upload-pack` / its hidden `--exec` (run locally for a local
# repository), and an `ext::` repository operand. cat-file, grep and
# ls-remote use parse-options, so their long options also match in any unique
# abbreviation (`--filt`, `--text` on cat-file, `--textc` on grep, where
# `--text` alone is -a; `--u=`, `--exe=` on ls-remote), and -O in a short
# cluster (probed on git 2.56: it runs without a tty).
_bwimc_git_args_prog() {
    local sub="$1" a ci; shift
    for a in "$@"; do
        case "$sub:$a" in ls-remote:ext::*|fetch:ext::*|pull:ext::*) return 0 ;; esac
        case "$a" in
            --) [ "$sub" = ls-remote ] || return 1; continue ;;
            --ext-diff|--textconv) return 0 ;;
        esac
        case "$sub:$a" in
            ls-remote:--*)
                { _bwimc_long_is "$a" upload-pack 1 || _bwimc_long_is "$a" exec 3; } && return 0 ;;
            cat-file:--*)
                { _bwimc_long_is "$a" filters 2 || _bwimc_long_is "$a" textconv 1; } && return 0 ;;
            grep:--*)
                { _bwimc_long_is "$a" open-files-in-pager 2 || _bwimc_long_is "$a" textconv 5; } && return 0 ;;
            grep:-*)
                ci=1
                while [ "$ci" -lt "${#a}" ]; do
                    case "${a:$ci:1}" in
                        O) return 0 ;;
                        [efABCm]) break ;;
                    esac
                    ci=$((ci+1))
                done ;;
        esac
    done
    return 1
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

# _bwimc_tar_clause_ok CLAUSE — HIMMEL-4476. rc 0 only for a plain
# `tar -x … -C /tmp/<dir>` extract, read fail-closed: the command word is
# tar/bsdtar/gtar, every option is from a short list (no member operands, no
# exec or file-list options, no -P), the archive is stdin, and every -C /
# --directory is an absolute /tmp path with no `..`, quote or expansion,
# given before anything else is extracted. Anything else returns 1.
_bwimc_tar_clause_ok() {
    local toks=() t n i=1 x=0 c=0 w="" p r
    while IFS= read -r t; do toks+=("$t"); done < <(_bwimc_tokenize "$1")
    n=${#toks[@]}
    [ "$n" -gt 1 ] || return 1
    case "${toks[0]}" in tar|bsdtar|gtar|/usr/bin/tar|/bin/tar|/usr/bin/bsdtar) ;; *) return 1 ;; esac
    while [ "$i" -lt "$n" ]; do
        t="${toks[$i]}"
        if [ "$w" = dir ]; then
            case "$t" in
                /tmp/*) ;;
                *) return 1 ;;
            esac
            case "$t" in
                *[!A-Za-z0-9_./+@%,:-]*|*/../*|*/..|*/./*|*/.) return 1 ;;
            esac
            # A symlink on the way may lead anywhere: resolve the deepest
            # existing ancestor and require it to stay under /tmp.
            p="$t"
            while [ -n "$p" ] && [ ! -d "$p" ]; do p="${p%/*}"; done
            r=$(cd -P -- "${p:-/}" 2>/dev/null && pwd -P) || return 1
            case "$r" in /tmp|/tmp/*|/private/tmp|/private/tmp/*) ;; *) return 1 ;; esac
            c=1; w=""; i=$((i+1)); continue
        fi
        if [ "$w" = file ]; then
            [ "$t" = - ] || return 1
            w=""; i=$((i+1)); continue
        fi
        case "$t" in
            -C|--directory) w=dir ;;
            -C*) toks[i]="${t#-C}"; w=dir; continue ;;
            --directory=*) toks[i]="${t#--directory=}"; w=dir; continue ;;
            -f|--file) w="file" ;;
            --file=-) ;;
            -x|--extract|--get) x=1 ;;
            -v|--verbose|-z|--gzip|--gunzip|-j|--bzip2|-J|--xz|--zstd|-p|\
            --preserve-permissions|-o|--no-same-owner|--no-same-permissions|\
            -k|--keep-old-files|--skip-old-files|-m|--touch) ;;
            --strip-components=[0-9]|--strip-components=[0-9][0-9]) ;;
            -[xvzjJpokm]*)
                case "$t" in -*x*) x=1 ;; esac
                case "$t" in
                    -*f) case "${t%f}" in *[!-xvzjJpokm]*) return 1 ;; esac; w="file" ;;
                    *[!-xvzjJpokm]*) return 1 ;;
                esac ;;
            *) return 1 ;;
        esac
        i=$((i+1))
    done
    [ -z "$w" ] && [ "$x" = 1 ] && [ "$c" = 1 ]
}

# _bwimc_xtract_ok TEXT — HIMMEL-4476. rc 0 when nothing in TEXT can turn a
# `git archive` stream or file into writes: with a pipe, every clause is a
# `git …` or one _bwimc_tar_clause_ok accepts; without one, no clause names an
# extractor, interpreter, shell, xargs or file copier unless that accepts
# it; no substitution, no PATH/TAR_OPTIONS/alias/
# function that could change what `tar` runs, and no TAR_OPTIONS in the
# hook's own environment. Fail-closed: any doubt is rc 1.
_BWIMC_XTRACT_RE='(^|[^[:alnum:]_.-])(tar|bsdtar|gtar|star|cpio|bsdcpio|pax|unzip|funzip|bsdunzip|7z|7za|7zr|ar|unar|atool|jar|busybox|toybox|python[0-9.]*|perl|ruby|node|php|xargs|bash|sh|zsh|dash|ksh|fish|eval|source|exec|ln|link|cp|mv|rsync|install)(\.exe)?([^[:alnum:]_-]|$)'
_bwimc_xtract_ok() {
    local cl lc lead t pipe
    [ -z "${TAR_OPTIONS:-}" ] || return 1
    # shellcheck disable=SC2016  # literal `$(` is the glob pattern
    case "$1" in
        *'$('*|*'`'*|*'<('*|*'>('*|*PATH=*|*TAR_OPTIONS*|*alias*|*hash*|*enable*|*'()'*|*function*) return 1 ;;
    esac
    # A pipe (quote-blind) may feed the stream to anything that writes what
    # it reads (patch, xargs, a shell): then every clause must be a plain
    # `git …` or an accepted tar extract.
    pipe=0
    t="${1//||/}"
    case "$t" in *'|'*) pipe=1 ;; esac
    while IFS= read -r cl; do
        cl="${cl#"$_BWIMC_PIPE"}"
        lead="${cl#"${cl%%[![:space:]]*}"}"
        [ -n "$lead" ] || continue
        ! _bwimc_is_colon "$cl" || continue
        if [ "$pipe" = 1 ]; then
            case "$lead" in git|git[[:space:]]*) continue ;; esac
            _bwimc_tar_clause_ok "$cl" || return 1
            continue
        fi
        case "$lead" in .|'. '*|.$'\t'*) return 1 ;; esac
        _tolower_ascii "$cl"; lc="$_TOLOWER_OUT"
        if [[ "$lc" =~ $_BWIMC_XTRACT_RE ]]; then
            _bwimc_tar_clause_ok "$cl" || return 1
        fi
    done < <(_bwimc_split_clauses "$1")
    return 0
}

_bwimc_git_sub_is_read() {
    local sub="$1"; shift
    local a npos=0 first="" second="" ff=0 skipval=0
    case "$sub" in
        # HIMMEL-4476: archive writes only its --output (checked by the
        # caller) or stdout, unless --exec/--remote runs a command or the
        # stream reaches something that can write it out (_bwimc_xtract_ok).
        # Only the built-in tar format: any other, zip included (probed on
        # git 2.56), runs a configured tar.<format>.command. Without
        # --format, --output picks the format from its extension, so that
        # must be .tar.
        archive)
            local fmt="" out=""
            for a in "$@"; do
                case "$skipval" in
                    f) fmt="$a"; skipval=0; continue ;;
                    o) out="$a"; skipval=0; continue ;;
                esac
                _bwimc_long_is "$a" exec 1 && return 1
                _bwimc_long_is "$a" remote 1 && return 1
                if _bwimc_long_is "$a" format 1; then
                    case "$a" in *=*) fmt="${a#*=}" ;; *) skipval=f ;; esac
                    continue
                fi
                if _bwimc_long_is "$a" output 1; then
                    case "$a" in *=*) out="${a#*=}" ;; *) skipval=o ;; esac
                    continue
                fi
                case "$a" in
                    --*) ;;
                    -o) skipval=o ;;
                    -*o*) return 1 ;;
                esac
            done
            [ "$skipval" = 0 ] || return 1
            if [ -n "$fmt" ]; then
                [ "$fmt" = tar ] || return 1
            elif [ -n "$out" ]; then
                case "$out" in *.tar) ;; *) return 1 ;; esac
            fi
            [ "${_bwimc_g_xtract_ok:-0}" = 1 ]; return ;;
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
# writes, `branch -u|--unset-upstream|-f`, and `update-ref`/`symbolic-ref` on
# refs/heads/main|master land in $GIT_COMMON_DIR, which is SHARED by every
# worktree of one repository. Run from a LINKED worktree's own cwd (no `-C`),
# DIR is the worktree itself — repo_root_for_path resolves to the worktree's
# OWN root, a legitimate feature checkout, so _bwimc_git_check_path on DIR
# alone ALLOWS even though the file these subcommands actually write
# ($GIT_COMMON_DIR/config, or a shared ref) lives in the PRIMARY's git
# directory. primary_checkout_root resolves that owning checkout — for an
# ordinary, non-worktree repo it is a no-op (returns the same root, git-dir ==
# common-dir there), so calling this unconditionally never changes the
# verdict for a plain checkout; it only adds a second, correct target for a
# linked worktree.
#
# DIR is resolved to its REPO ROOT (guard_canon_path + repo_root_for_path,
# the exact walk _bwimc_git_check_path already does) BEFORE calling
# primary_checkout_root, rather than handed to it raw: primary_checkout_root
# runs `git -C DIR …`, which requires DIR to be an EXISTING DIRECTORY, but a
# `--git-dir=<worktree>/.git` target is exactly that worktree's `.git`
# FILE (git itself follows the gitfile redirection there — verified: `git
# --git-dir=<wt>/.git status` succeeds against a linked worktree) — handing
# the file straight to `git -C` fails ("cannot change to … Not a directory"),
# which would silently skip this whole check for that one spelling. The repo
# ROOT above the `.git` entry is always a real, `-C`-able directory by
# construction (repo_root_for_path only returns a directory it saw `-e
# "$d/.git"` under), so resolving it first closes that gap.
_bwimc_git_check_common_owner() {
    local dir="$1" label="$2" canon root owner
    canon=$(guard_canon_path "$dir" 2>/dev/null) || return 0
    root=$(repo_root_for_path "$canon" 2>/dev/null) || return 0
    [ -n "$root" ] || return 0
    owner=$(primary_checkout_root "$root" 2>/dev/null) || return 0
    [ -n "$owner" ] || return 0
    _bwimc_git_check_path "$owner" "$label"
}

# _bwimc_git_wrapped CLAUSE CWD UNRES GITENV — HIMMEL-4365. The prefix loop in
# _bwimc_git_clause models env/command/exec/nohup/time only, so a git behind
# any other wrapper (`timeout 60 git -C <primary> reset --hard`, `nice`,
# `stdbuf`, `ionice`, `sudo`, `xargs`) never reached the subcommand check.
# _bwimc_strip_prefix (the verb arms' wrapper model) finds the command word
# past them; when that word is git, or `xargs … git`, the clause is re-read
# from the git word, the leading assignments kept. What the stripped wrappers
# do to git's environment is not modelled, so the re-read clause's cwd fails
# closed (a write then denies `unresolved-git-target`) when they carry a
# GIT_* word, an `env` while a GIT_* value is exported (GITENV), a chdir that
# does not resolve, or an `xargs -I/-i/--replace` string that appears in the
# git words (the target or subcommand may come from stdin); `xargs git` with
# no subcommand fails closed the same way.
# ponytail: wrappers _bwimc_strip_prefix does not model (setsid after another
# wrapper — _bwimc_git_clause reads only a leading one —, watch, parallel,
# `find -exec`) still hide a git; upgrade path: a wrapper added there is
# covered here for free.
_bwimc_git_wrapped() {
    local wsp wsp0 wdir apfx strip wu=0 t wl k xt=() xi=0 xg="" xa=0 xr="" xj=0
    [ "${_bwimc_g_wrap:-0}" = 0 ] || return 0
    _bwimc_strip_prefix "$1"
    wsp="$_BWIMC_SP"; wsp0="$_BWIMC_SP0"; wdir="$_BWIMC_SPDIR"
    while IFS= read -r t; do xt+=("$t"); done < <(_bwimc_tokenize "$wsp")
    [ "${#xt[@]}" -gt 0 ] || return 0
    t=$(_bwimc_unq "${xt[0]}"); t="${t##*/}"; _tolower_ascii "$t"; wl="${_TOLOWER_OUT%.exe}"
    case "$wl" in
        git) [ "$wsp" != "$wsp0" ] || return 0 ;;
        xargs)
            k=1
            while [ "$k" -lt "${#xt[@]}" ]; do
                t=$(_bwimc_unq "${xt[$k]}")
                case "$t" in
                    -I) k=$((k+1)); xr=$(_bwimc_unq "${xt[$k]:-}"); k=$((k+1)); continue ;;
                    -I*) xr="${t#-I}" ;;
                    -i|--replace) xr="{}" ;;
                    -i*) xr="${t#-i}" ;;
                    --replace=*) xr="${t#--replace=}" ;;
                esac
                t="${t##*/}"; _tolower_ascii "$t"
                if [ "${_TOLOWER_OUT%.exe}" = git ]; then xi=$k; break; fi
                k=$((k+1))
            done
            [ "$xi" -gt 0 ] || return 0
            # The replacement string matters where it picks the target: a
            # global option or its operand, the subcommand, or --output and
            # its operand, attached or the next word (k=4). Past a bare `--`
            # or `--end-of-options` (k=5) no word, stdin's included, is read
            # as an option (a pathspec, or a revision). Elsewhere
            # in the subcommand's arguments (or appended, with no -I
            # string) stdin words may be options: xj.
            k=0
            while [ "$xi" -lt "${#xt[@]}" ]; do
                t="${xt[$xi]}"
                if [ "$k" = 5 ]; then :
                elif [ "$k" != 2 ] || [ "${t#--output}" != "$t" ]; then
                    case "$t" in *"${xr:-$'\n'}"*) xa=1 ;; esac
                elif [ -n "$xr" ]; then
                    case "$t" in *"$xr"*) xj=1 ;; esac
                fi
                if [ "$k" = 0 ]; then k=1
                elif [ "$k" = 1 ]; then
                    case "$(_bwimc_unq "$t")" in
                        -C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix) k=3 ;;
                        -*) ;;
                        *) k=2 ;;
                    esac
                elif [ "$k" = 3 ]; then k=1
                elif [ "$k" = 4 ]; then k=2
                elif [ "$k" = 5 ]; then :
                elif [ "$(_bwimc_unq "$t")" = --output ]; then k=4
                elif [ "$(_bwimc_unq "$t")" = -- ] || [ "$(_bwimc_unq "$t")" = --end-of-options ]; then
                    # ...unless the word before may be an option taking it as
                    # its operand (`--grep --`).
                    case "$(_bwimc_unq "${xt[$((xi-1))]}")" in -*=*|[!-]*) k=5 ;; esac
                fi
                xg="$xg$t "; xi=$((xi+1))
            done
            # Without -I/-i/--replace, xargs appends stdin words to git.
            [ -n "$xr" ] || [ "$k" = 5 ] || xj=1 ;;
        *) return 0 ;;
    esac
    apfx="${1:0:$((${#1} - ${#wsp0}))}"
    strip="${wsp0:0:$((${#wsp0} - ${#wsp}))}"
    case "$strip" in *GIT_*) wu=1 ;; esac
    # HIMMEL-4504 J1950 (B1): a program env before the wrappers ($5, from the
    # caller's prefix loop) or among them (`nice env GIT_PAGER=x git`) voids
    # the re-read clause's read relief. An `env -i`/`sudo` that would drop it
    # is not modelled (fail closed).
    local wprog="${5:-0}"
    while IFS= read -r t; do
        t=$(_bwimc_unq "$t")
        case "$t" in [A-Za-z_]*=*) ! _bwimc_env_prog "$t" || wprog=1 ;; esac
    done < <(_bwimc_tokenize "$strip")
    if [ -n "$4" ]; then
        case " $strip " in *[[:space:]/]env[[:space:]]*) wu=1 ;; esac
    fi
    [ "$3" = 1 ] && wu=1
    [ "$xa" = 1 ] && wu=1
    if [ -n "$wdir" ]; then
        if t=$(_bwimc_resolve_abs "$wdir" "$2"); then set -- "$1" "$t" "$3" "$4"; else wu=1; fi
    fi
    local saved_cwd="$_bwimc_gcwd" saved_unres="$_bwimc_gcwd_unres"
    _bwimc_gcwd="$2"; _bwimc_gcwd_unres="$wu"
    _bwimc_g_wrap=1; [ -z "$xg" ] || _bwimc_g_xargs=1; _bwimc_g_xinj="$xj"; _bwimc_g_wprog="$wprog"
    # The space keeps the last kept assignment off the git word (J1950: `X=1
    # nice git …` re-read as one word `X=1git`, hiding the git clause).
    if [ -n "$xg" ]; then _bwimc_git_clause "$apfx $xg"; else _bwimc_git_clause "$apfx $wsp"; fi
    _bwimc_g_wrap=0; _bwimc_g_xargs=0; _bwimc_g_xinj=0; _bwimc_g_wprog=0
    _bwimc_gcwd="$saved_cwd"; _bwimc_gcwd_unres="$saved_unres"
}

# _bwimc_git_clause CLAUSE_SP — per-clause state machine for arm (g). Reads
# and updates the command-wide _bwimc_gcwd / _bwimc_gcwd_unres /
# _bwimc_genv_* globals; must be called as a plain statement (never `$(…)`).
_bwimc_git_clause() {
    local toks=() t tu i n start v r
    local dir gitdir="" wtree="" idx="" unres=0 sub="" args=()
    local e_dir="$_bwimc_genv_dir" e_wt="$_bwimc_genv_wt" e_idx="$_bwimc_genv_idx"
    local e_cfgglobal="$_bwimc_genv_cfgglobal" e_cfgsystem="$_bwimc_genv_cfgsystem"
    local cfg="$_bwimc_genv_cfg"
    local cwd="$_bwimc_gcwd"
    local progrun="$_bwimc_genv_prog"
    # HIMMEL-4329 CR codex-2: a git behind a chroot (`chroot P git -C / add .`,
    # `sudo -R P git …`) runs inside the new root, and none of git's paths
    # are mapped into it, so the prefix loop below cannot see it at all. A
    # root other than `/` (unresolved included) reads the clause behind the
    # wrappers in jail mode: a git write there fails closed (chroot-git); a
    # read still passes. Only this arm calls itself, before the verb loop
    # reads the _BWIMC_SP* globals.
    if [ "$_bwimc_g_jail" = 0 ]; then
        _bwimc_strip_prefix "$1"
        if [ -n "$_BWIMC_SPROOT" ]; then
            local jroot='$' jsp="$_BWIMC_SP"
            case "$_BWIMC_SPROOT" in
                *'$'*|*'`'*|*[*?[]*|*\\*) ;;
                *)
                    case "$_BWIMC_SPROOT:$_bwimc_gcwd_unres" in /*|*:0)
                        r=$(_bwimc_resolve_abs "$_BWIMC_SPROOT" "$cwd") && r=$(guard_canon_path "$r" 2>/dev/null) && jroot="$r" ;;
                    esac ;;
            esac
            if [ "$jroot" != / ]; then
                _bwimc_g_jail=1
                _bwimc_git_clause "$jsp"
                _bwimc_g_jail=0
                return 0
            fi
        fi
    fi
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
                case "$(_bwimc_unq "${toks[$i]}")" in
                    -L|-P|-e|-@) i=$((i+1)) ;;
                    --) i=$((i+1)); break ;;
                    *) break ;;
                esac
            done
            if [ "$i" -ge "$n" ]; then
                [ -n "${HOME:-}" ] && [ "${_bwimc_home_taint:-0}" = 0 ] && { _bwimc_gcwd="$HOME"; _bwimc_gcwd_unres=0; } || _bwimc_gcwd_unres=1
            elif [ "$(_bwimc_unq "${toks[$i]}")" = "-" ]; then
                _bwimc_gcwd_unres=1
            elif r=$(_bwimc_resolve_abs "${toks[$i]}" "$cwd"); then
                _bwimc_gcwd="$r"; _bwimc_gcwd_unres=0
            else
                _bwimc_gcwd_unres=1
            fi
            return 0 ;;
        popd) _bwimc_gcwd_unres=1; return 0 ;;
        # HIMMEL-4504 J1950: `declare -x` / `typeset -x` / `readonly -x` export
        # like `export`; without -x the value may be exported later (`set -a`
        # earlier, `export NAME` after), so every spelling counts (fail closed).
        export|unset|declare|typeset|readonly)
            local op="$tu"
            i=$((i+1))
            while [ "$i" -lt "$n" ]; do
                t=$(_bwimc_unq "${toks[$i]}")
                if [ "$op" = unset ]; then
                    case "$t" in
                        GIT_DIR) _bwimc_genv_dir="" ;;
                        GIT_WORK_TREE) _bwimc_genv_wt="" ;;
                        GIT_INDEX_FILE) _bwimc_genv_idx="" ;;
                        GIT_CONFIG_GLOBAL) _bwimc_genv_cfgglobal="" ;;
                        GIT_CONFIG_SYSTEM) _bwimc_genv_cfgsystem="" ;;
                    esac
                else
                    case "${toks[$i]}" in [A-Za-z_]*=*) ! _bwimc_env_prog "${toks[$i]}" || _bwimc_genv_prog=1 ;; esac
                    case "${toks[$i]}" in
                        GIT_DIR=*) _bwimc_genv_dir="${toks[$i]#GIT_DIR=}" ;;
                        GIT_WORK_TREE=*) _bwimc_genv_wt="${toks[$i]#GIT_WORK_TREE=}" ;;
                        GIT_INDEX_FILE=*) _bwimc_genv_idx="${toks[$i]#GIT_INDEX_FILE=}" ;;
                        GIT_CONFIG_GLOBAL=*)
                            _bwimc_genv_cfgglobal="${toks[$i]#GIT_CONFIG_GLOBAL=}"; _bwimc_genv_cfg=1 ;;
                        GIT_CONFIG_SYSTEM=*)
                            _bwimc_genv_cfgsystem="${toks[$i]#GIT_CONFIG_SYSTEM=}"; _bwimc_genv_cfg=1 ;;
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
    # and the transparent `command`/`exec`/`nohup`/`time`/`setsid` words.
    # `asg` stays 1 while every word is an assignment.
    local asg=1
    [ "$_bwimc_g_wprog" = 0 ] || progrun=1
    while [ "$i" -lt "$n" ]; do
        t="${toks[$i]}"
        case "$t" in [A-Za-z_]*=*) ! _bwimc_env_prog "$t" || progrun=1 ;; *) asg=0 ;; esac
        case "$t" in
            GIT_DIR=*) e_dir="${t#GIT_DIR=}" ;;
            GIT_WORK_TREE=*) e_wt="${t#GIT_WORK_TREE=}" ;;
            GIT_INDEX_FILE=*) e_idx="${t#GIT_INDEX_FILE=}" ;;
            GIT_CONFIG_GLOBAL=*) e_cfgglobal="${t#GIT_CONFIG_GLOBAL=}"; cfg=1 ;;
            GIT_CONFIG_SYSTEM=*) e_cfgsystem="${t#GIT_CONFIG_SYSTEM=}"; cfg=1 ;;
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
                            case "$t" in [A-Za-z_]*=*) ! _bwimc_env_prog "$t" || progrun=1 ;; esac
                            case "$t" in
                                -|-i|--ignore-environment)
                                    e_dir=""; e_wt=""; e_idx=""; e_cfgglobal=""; e_cfgsystem=""; cfg=0; progrun=0 ;;
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
                                            i) e_dir=""; e_wt=""; e_idx=""; e_cfgglobal=""; e_cfgsystem=""; progrun=0 ;;
                                            u|C|a|S) eopt="$ch"; eval_="${t:$((ci+1))}"; break ;;
                                        esac
                                        ci=$((ci+1))
                                    done ;;
                                GIT_DIR=*) e_dir="${t#GIT_DIR=}" ;;
                                GIT_WORK_TREE=*) e_wt="${t#GIT_WORK_TREE=}" ;;
                                GIT_INDEX_FILE=*) e_idx="${t#GIT_INDEX_FILE=}" ;;
                                GIT_CONFIG_GLOBAL=*) e_cfgglobal="${t#GIT_CONFIG_GLOBAL=}"; cfg=1 ;;
                                GIT_CONFIG_SYSTEM=*) e_cfgsystem="${t#GIT_CONFIG_SYSTEM=}"; cfg=1 ;;
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
                                       GIT_CONFIG_GLOBAL) e_cfgglobal="" ;;
                                       GIT_CONFIG_SYSTEM) e_cfgsystem="" ;;
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
                    # setsid takes only flags (-c -f -w and long forms).
                    setsid)
                        while [ $((i+1)) -lt "$n" ]; do
                            case "$(_bwimc_unq "${toks[$((i+1))]}")" in -*) i=$((i+1)) ;; *) break ;; esac
                        done ;;
                    *) break ;;
                esac
                ;;
        esac
        i=$((i+1))
    done
    if [ "$i" -ge "$n" ]; then
        # HIMMEL-4504 J1950 (B2/T5): a statement of bare assignments may be
        # exported (`set -a` before, `export NAME` after, or already in the
        # session), so it holds for the rest of the command like `export`.
        if [ "$asg" = 1 ]; then
            _bwimc_genv_dir="$e_dir"; _bwimc_genv_wt="$e_wt"; _bwimc_genv_idx="$e_idx"
            _bwimc_genv_cfgglobal="$e_cfgglobal"; _bwimc_genv_cfgsystem="$e_cfgsystem"
            [ "$cfg" = 0 ] || _bwimc_genv_cfg=1
            [ "$progrun" = 0 ] || _bwimc_genv_prog=1
        fi
        return 0
    fi
    tu=$(_bwimc_unq "${toks[$i]}")
    case "${tu##*/}" in
        git|git.exe|GIT|GIT.EXE|Git.exe) ;;
        *) _bwimc_git_wrapped "$1" "$_bwimc_gcwd" "$_bwimc_gcwd_unres" "$e_dir$e_wt$e_idx" "$progrun"; return 0 ;;
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
            -c|--config-env)
                cfg=1; i=$((i+1)); v=$(_bwimc_unq "${toks[$i]:-}"); _bwimc_cfg_key "$v"
                if [ "$t" = -c ]; then _bwimc_cfg_safe "$v" || progrun=1; else _bwimc_cfg_safe "$v" noval || progrun=1; fi ;;
            --config-env=*) cfg=1; _bwimc_cfg_key "${t#--config-env=}"; _bwimc_cfg_safe "${t#--config-env=}" noval || progrun=1 ;;
            -c*) cfg=1; _bwimc_cfg_key "${t#-c}"; _bwimc_cfg_safe "${t#-c}" || progrun=1 ;;
            --exec-path=*) progrun=1 ;;
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
        [ "$_bwimc_g_jail" = 0 ] || _bwimc_deny "chroot-git" "$1" "$dir" ""
        _BWIMC_GIT_SUB=push
        [ "$_bwimc_gcwd_unres" = 1 ] && unres=1
        if [ "${#args[@]}" -gt 0 ]; then
            _bwimc_git_push "$1" "$dir" "$unres" "${args[@]}"
        fi
        _BWIMC_GIT_SUB=""
        _bwimc_git_alts "$1"
        return 0
    fi

    # HIMMEL-4365: `xargs git` with no subcommand reads it, and any global
    # option, from stdin.
    if [ "${_bwimc_g_xargs:-0}" = 1 ] && [ -z "$sub" ]; then
        _BWIMC_GIT_SUB="(xargs stdin)"
        _bwimc_deny "unresolved-git-target" "$1" "$dir" ""
    fi
    # HIMMEL-4365: xargs puts stdin words among the subcommand's arguments
    # (no -I string, or the string sits there), so an option such as
    # `--output=<primary>/x` can turn a read into a write anywhere. Only
    # subcommands with no option that writes a file keep the normal check:
    # the index/work-tree writers (whose resolved repo is checked below) and
    # a few plain reads. grep is not one (-O runs a command), nor rev-list,
    # which takes --output.
    if [ "${_bwimc_g_xinj:-0}" = 1 ]; then
        case "$sub" in
            add|stage|rm|checkout|restore|merge-base|ls-tree|ls-files|rev-parse|cat-file|status) ;;
            *) _BWIMC_GIT_SUB="$sub (xargs args)"
               _bwimc_deny "unresolved-git-target" "$1" "$dir" "" ;;
        esac
    fi
    # HIMMEL-4365: `--output <file>` (the diff/log/show family) writes FILE,
    # so a read subcommand can still overwrite a primary file (`git -C
    # <primary> diff --output=.claude/settings.json`). A relative FILE is
    # resolved from the -C dir and, when a --work-tree/GIT_WORK_TREE is set
    # (git then runs from the work tree's top), from that too; each is
    # checked like any other write operand. The clause itself stays a read.
    # HIMMEL-4518: the same holds for `archive -o <f>`, `format-patch -o
    # <dir>` / `--output-directory[=]<dir>` (-o also ends a bundled cluster
    # such as `-ko <dir>`, the rest being its operand) and the `bundle create
    # <file>` operand, whose repo check alone passes from a leg cwd.
    local ow=0 of="" owt="${wtree:-$e_wt}" bc=0
    for v in ${args[@]+"${args[@]}"}; do
        if [ "$ow" = 1 ]; then
            of="$v"; ow=0
        else
            # HIMMEL-4476: archive takes an abbreviated --output too (`--out=`).
            if [ "$sub" = archive ] && _bwimc_long_is "$v" output 1; then
                case "$v" in *=*) v="--output=${v#*=}" ;; *) v=--output ;; esac
            fi
            case "$v" in
                # `bundle create -- <file>`: the file still follows `--`.
                --) [ "$sub:$bc" = bundle:1 ] || break; ow=1; continue ;;
                --output) ow=1; continue ;;
                --output=*) of="${v#--output=}" ;;
                *)
                    case "$sub:$v" in
                        format-patch:--output-directory) ow=1; continue ;;
                        format-patch:--output-directory=*) of="${v#*=}" ;;
                        archive:-o|format-patch:-o) ow=1; continue ;;
                        archive:-o*|format-patch:-o*) of="${v#-o}" ;;
                        archive:-[!-]*o*|format-patch:-[!-]*o*)
                            of="${v#*o}"
                            [ -n "$of" ] || { ow=1; continue; } ;;
                        bundle:create) [ "$bc" != 0 ] || bc=1; continue ;;
                        bundle:-*) continue ;;
                        bundle:*) [ "$bc" = 1 ] || continue; of="$v"; bc=2 ;;
                        *) continue ;;
                    esac ;;
            esac
        fi
        _BWIMC_GIT_SUB="$sub --output"
        [ "$_bwimc_g_jail" = 0 ] || _bwimc_deny "chroot-git" "$1" "$dir" ""
        case "$of" in
            /*|'~'*|'$'*) ;;
            *) [ "$unres" = 0 ] || _bwimc_deny "unresolved-git-target" "$1" "$dir" ""
               if [ -n "$owt" ]; then
                   r=$(_bwimc_resolve_abs "$owt" "$dir") || _bwimc_deny "unresolved-git-target" "$owt" "$dir" ""
                   _bwimc_check_target "$of" "$r"
               fi ;;
        esac
        _bwimc_check_target "$of" "$dir"
        _BWIMC_GIT_SUB=""
    done

    # HIMMEL-4504: `worktree move <wt> <dst>` / `worktree add <path>` create a
    # checkout AT the destination, so it gets the file verdict like --output
    # (a gitignored or handovers/ path inside the primary stays allowed, as
    # for every file-operand arm). A sub-option that runs a program (see
    # _bwimc_git_args_prog) voids the read relief below.
    if [ "$sub" = worktree ]; then
        local wt_op="" wt_dst="" wt_n=0 wt_skip=0 wt_eoo=0
        for v in ${args[@]+"${args[@]}"}; do
            if [ "$wt_skip" = 1 ]; then wt_skip=0; continue; fi
            # J1950 (B3): after `--` every word is positional (`add -d --
            # -evil` creates <dir>/-evil).
            if [ "$wt_eoo" = 0 ]; then
                case "$v" in
                    --) [ -z "$wt_op" ] || wt_eoo=1; continue ;;
                    --reason) wt_skip=1; continue ;;
                    # -b/-B take the NEXT word when they end a cluster (`-fb y`);
                    # after flag letters they carry a value attached (`-btopicb`).
                    --*) continue ;;
                    -*)
                        if [[ ! "$v" =~ ^-[fdq]*[bB]. ]]; then
                            case "$v" in *[bB]) wt_skip=1 ;; esac
                        fi
                        continue ;;
                esac
            fi
            if [ -z "$wt_op" ]; then wt_op="$v"; continue; fi
            wt_n=$((wt_n+1))
            case "$wt_op:$wt_n" in add:1|move:2) wt_dst="$v" ;; esac
        done
        if [ -n "$wt_dst" ]; then
            case "$wt_op" in
                add|move)
                    _BWIMC_GIT_SUB="worktree $wt_op"
                    [ "$_bwimc_g_jail" = 0 ] || _bwimc_deny "chroot-git" "$1" "$dir" ""
                    case "$wt_dst" in
                        /*|'~'*|'$'*) ;;
                        *) [ "$unres" = 0 ] || _bwimc_deny "unresolved-git-target" "$1" "$dir" "" ;;
                    esac
                    _bwimc_check_target "$wt_dst" "$dir"
                    _BWIMC_GIT_SUB="" ;;
            esac
        fi
    fi
    if [ "$progrun" = 0 ] && [ "${#args[@]}" -gt 0 ] && _bwimc_git_args_prog "$sub" "${args[@]}"; then
        progrun=1
    fi

    # A config override (-c, --config-env, GIT_CONFIG*) can repoint the
    # remote or refspec pull/fetch act on, so it voids their carve-out.
    # A config override can also set tar.<format>.command, which archive runs.
    case "$cfg:$sub" in
        1:pull|1:fetch|1:archive) ;;
        *)
            if [ "${#args[@]}" -gt 0 ]; then
                [ "$progrun" = 0 ] && _bwimc_git_sub_is_read "$sub" "${args[@]}" && return 0
            else
                [ "$progrun" = 0 ] && _bwimc_git_sub_is_read "$sub" && return 0
            fi ;;
    esac
    [ "$_bwimc_g_jail" = 0 ] || _bwimc_deny "chroot-git" "$1" "$dir" ""

    _BWIMC_GIT_SUB="$sub"
    [ "$progrun" = 0 ] || _BWIMC_GIT_SUB="$sub (runs a program: a -c/--config-env key off the safe list, a pager, --exec-path, --ext-diff/--textconv, --upload-pack, an ext:: URL or a program env such as GIT_EXTERNAL_DIFF/HOME, in any earlier statement; HIMMEL-4504)"
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
    # HIMMEL-3407: config/remote writes, branch -u|--unset-upstream|-M|-C|-f,
    # checkout -B/switch -C onto main|master, and update-ref/symbolic-ref on
    # refs/heads/main|master ALSO get checked against the target's owning
    # PRIMARY checkout (see _bwimc_git_check_common_owner) — closing the gap
    # where the target IS a linked worktree, whose own repo root looks like
    # an ordinary feature checkout and allows, while the subcommand actually
    # writes the shared $GIT_COMMON_DIR the worktree and its primary both
    # point at.
    case "$sub" in
        config)
            # Adversarial review round 1: config's TARGET file is not always
            # the shared repo config. --global/--system/--worktree name a
            # DIFFERENT file entirely (worktree-local under
            # extensions.worktreeConfig), so they are exempt outright.
            # -f/--file redirects to an ARBITRARY path, which may or may not
            # be inside the common dir — resolve it and run it through the
            # ordinary file-target check (_bwimc_git_check_path), the same
            # one --git-dir/--work-tree already use, so `--file
            # <primary>/.git/config` still denies while `--file /tmp/x/cfg`
            # does not. --blob/--type/--default/--comment also take a value
            # and must be consumed (skipped) so their value can never be
            # misread as one of the flags above.
            #
            # Adversarial review round 2:
            #   N1 (bypass) — a glued `-f<path>` (no space) is a real git
            #     invocation and was not recognised as the file flag at all,
            #     so its value was never checked. `-f?*` now captures the
            #     attached form the same way `-f`/`--file`'s separate-token
            #     value already was.
            #   N2 (fail-open) — when _bwimc_resolve_abs fails (a dynamic
            #     `-f "$X"` target), the old code did nothing at all. Every
            #     other arm in this file denies an unresolved git target
            #     (`unresolved-git-target`); this one now does too.
            #
            # HIMMEL-3565 (residuals 1 + 3): GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM
            # set as an env prefix, `env VAR=…`, or `export` REPOINT what file
            # --global/--system actually write, so the exemption above is
            # unsound when either is present. Their VALUE is resolved and
            # run through the same `_bwimc_resolve_abs` + `_bwimc_git_check_path`
            # pair `-f/--file` already uses (not a coarse substring scan of the
            # clause text, and not the target's cwd-derived owner either —
            # both missed the actual file the flag writes to), and carried
            # across clauses via `e_cfgglobal`/`e_cfgsystem` the same way arm
            # (g) already carries GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE.
            local cfg_scope="" cfg_file="" cfg_want=0
            for v in ${args[@]+"${args[@]}"}; do
                if [ "$cfg_want" != 0 ]; then
                    [ "$cfg_want" = 1 ] && cfg_file="$v"
                    cfg_want=0
                    continue
                fi
                case "$v" in
                    --global|--system|--worktree) cfg_scope="$v" ;;
                    -f|--file) cfg_want=1 ;;
                    -f?*) cfg_file="${v#-f}" ;;
                    --file=*) cfg_file="${v#--file=}" ;;
                    --blob|--type|--default|--comment) cfg_want=2 ;;
                esac
            done
            case "$cfg_scope" in
                --global)
                    if [ -n "$e_cfgglobal" ]; then
                        r=$(_bwimc_resolve_abs "$e_cfgglobal" "$dir") || _bwimc_deny "unresolved-git-target" "$e_cfgglobal" "$dir" ""
                        _bwimc_git_check_path "$r" "config --global (GIT_CONFIG_GLOBAL) $e_cfgglobal"
                    fi ;;
                --system)
                    if [ -n "$e_cfgsystem" ]; then
                        r=$(_bwimc_resolve_abs "$e_cfgsystem" "$dir") || _bwimc_deny "unresolved-git-target" "$e_cfgsystem" "$dir" ""
                        _bwimc_git_check_path "$r" "config --system (GIT_CONFIG_SYSTEM) $e_cfgsystem"
                    fi ;;
                --worktree) : ;;
                "")
                    if [ -n "$cfg_file" ]; then
                        r=$(_bwimc_resolve_abs "$cfg_file" "$dir") || _bwimc_deny "unresolved-git-target" "$cfg_file" "$dir" ""
                        _bwimc_git_check_path "$r" "config --file $cfg_file"
                    else
                        _bwimc_git_check_common_owner "$gtarget" "config clause $1"
                    fi ;;
            esac
            ;;
        remote)
            # Adversarial review round 1: `update`/`prune`/`show` are
            # fetch-shaped (network/refresh operations, like the pull/fetch
            # carve-out above) — they do not repoint remote.*.url or any
            # other config key the ticket cares about. `get-url` never
            # reaches here at all (already read-shaped in
            # _bwimc_git_sub_is_read). Everything else (add/set-url/rename/
            # remove/set-head/…) still checks.
            local remote_first=""
            for v in ${args[@]+"${args[@]}"}; do
                case "$v" in -*) ;; *) remote_first="$v"; break ;; esac
            done
            case "$remote_first" in
                update|prune|show) : ;;
                *) _bwimc_git_check_common_owner "$gtarget" "remote clause $1" ;;
            esac
            ;;
        branch)
            # Adversarial review round 2 (N4, false deny): -u/--set-upstream*
            # implicitly targets the CURRENT branch when no branch-name
            # operand is given — from a linked worktree that is always the
            # leg's OWN feature branch (git refuses to check main out in two
            # worktrees at once), never main, so `branch -u origin/x` and
            # `branch -f other start` are ordinary and must allow, matching
            # `push -u`. N5: `--forc` (an unambiguous abbreviation of
            # --force, which real git accepts) is matched via
            # _bwimc_is_long_abbrev, the same helper the option-value arms
            # above already use for exactly this purpose.
            #
            # HIMMEL-3565 (residual 2): "any operand is main/master" false-denied
            # `branch -f <new> main` (main is the START-POINT) and
            # `branch -C main <new>` (main is the SOURCE), and separately
            # false-DENIED `branch -u main` by reading -u's own mandatory
            # VALUE as if it were a branch-name operand. Real git's target
            # operand differs by flag family:
            #   - upstream family (-u/--set-upstream-to[=…]/--set-upstream/
            #     --unset-upstream): `branch -u <upstream> [<branchname>]` —
            #     the separate-token form of -u/--set-upstream-to consumes
            #     the NEXT token as its mandatory value (never a target), and
            #     the target is the LAST branch-name operand if any is given,
            #     else the implicit current branch (never main, per N4 above).
            #   - move/copy family (-M/-C, or bare -m/-c/--move/--copy when
            #     combined with a force flag): `branch (-m|-M) [<old>] <new>`
            #     — <old> is only ever READ, so the target is always the LAST
            #     positional.
            #   - otherwise (plain -f/--force): `branch -f <name> [<start>]`
            #     — <start> is only ever READ, so the target is the FIRST
            #     positional.
            # (git branch -D main is inert from a linked worktree — git
            # itself refuses to delete a branch checked out in another
            # worktree — and is deliberately not modelled here; see the
            # pinning test row. ponytail: static text scanning cannot special-
            # case every branch/git version's exact flag-value shape, revisit
            # if HIMMEL-3546's shared tokenizer lands and can replace this
            # scan outright.)
            # HIMMEL-3565 round-3 CR (B1, B2): a move (-m/-M/--move) DELETES
            # its source ref (real git moves refs/heads/<old> to
            # refs/heads/<new>, repointing HEAD if <old> was checked out
            # elsewhere) — unlike copy, <old> is a write target too, and
            # unlike -M, bare -m is a real rename whenever <new> does not
            # already exist, so it belongs in br_danger even without -f.
            # Track br_move separately from br_movecopy so the SOURCE check
            # below applies only to move, never to copy (copy's <old> really
            # is read-only). A bundled short cluster (-fu/-qu/-vu) hides -u
            # the same way -M/-C hide inside -*[MC]* already handled below —
            # -u still consumes the NEXT token as its mandatory value (never
            # a branch-name operand) once found anywhere in the cluster.
            local br_danger=0 br_upstream=0 br_movecopy=0 br_move=0 br_want_val=0
            local br_first="" br_last="" br_target
            for v in ${args[@]+"${args[@]}"}; do
                if [ "$br_want_val" = 1 ]; then
                    br_want_val=0
                    continue
                fi
                case "$v" in
                    -u|--set-upstream-to)
                        br_danger=1; br_upstream=1; br_want_val=1 ;;
                    -u?*)
                        br_danger=1; br_upstream=1 ;;
                    --set-upstream-to=*|--set-upstream|--unset-upstream)
                        br_danger=1; br_upstream=1 ;;
                    -M|--move)
                        br_danger=1; br_movecopy=1; br_move=1 ;;
                    -C|--copy)
                        br_danger=1; br_movecopy=1 ;;
                    -m)
                        br_danger=1; br_movecopy=1; br_move=1 ;;
                    -c)
                        br_movecopy=1 ;;
                    --*)
                        _bwimc_is_long_abbrev "force" "$v" && br_danger=1 ;;
                    -*)
                        _bwimc_short_has "$v" ufmMC && br_danger=1
                        case "$v" in *[mM]*) br_movecopy=1; br_move=1 ;; esac
                        case "$v" in *[cC]*) br_movecopy=1 ;; esac
                        case "$v" in
                            *u) br_danger=1; br_upstream=1; br_want_val=1 ;;
                            *u*) br_danger=1; br_upstream=1 ;;
                        esac ;;
                    *)
                        [ -n "$br_first" ] || br_first="$v"
                        br_last="$v" ;;
                esac
            done
            if [ "$br_upstream" = 1 ] || [ "$br_movecopy" = 1 ]; then
                br_target="$br_last"
            else
                br_target="$br_first"
            fi
            case "$br_target" in
                main|master)
                    [ "$br_danger" = 1 ] && _bwimc_git_check_common_owner "$gtarget" "branch clause $1" ;;
            esac
            if [ "$br_move" = 1 ] && [ "$br_danger" = 1 ]; then
                case "$br_first" in
                    main|master)
                        _bwimc_git_check_common_owner "$gtarget" "branch clause $1 (move source)" ;;
                esac
            fi
            ;;
        update-ref|symbolic-ref)
            # Adversarial review round 1 (HIGH, bypass): the old loop skipped
            # every `-`-prefixed token but not the VALUE a value-taking flag
            # consumes, so `update-ref -m msg refs/heads/main HEAD` read "msg"
            # as if it were the ref-name positional and stopped there,
            # allowing it — `-m <reason>` is the one value-taking flag either
            # subcommand has (mirrors _bwimc_git_sub_is_read's own symbolic-ref
            # skipval). `--stdin` (with or without `-z`) reads its ref updates
            # from STDIN, which this command-text scanner cannot see at all —
            # fail closed on it unconditionally rather than silently allow.
            local gref_want=""
            for v in ${args[@]+"${args[@]}"}; do
                if [ -n "$gref_want" ]; then
                    gref_want=""
                    continue
                fi
                case "$v" in
                    --stdin)
                        _bwimc_git_check_common_owner "$gtarget" "$sub --stdin clause $1"
                        break ;;
                    -m) gref_want=1 ;;
                    -*) ;;
                    refs/heads/main|refs/heads/master)
                        _bwimc_git_check_common_owner "$gtarget" "$sub clause $1"
                        break ;;
                    *) break ;;
                esac
            done
            ;;
        checkout|switch)
            # Adversarial review round 1 (LOW): `checkout -B <name>` /
            # `switch -C <name>` force-create-or-RESET <name> to the given
            # (or current) start-point — the same "move an existing ref"
            # class as `branch -M`/`-C` above, just spelled through a
            # different verb. Only the value-taking flag itself is modelled
            # (bare `-B`/`-C` and an attached `-Bmain`/`-Cmain`), not a
            # bundled cluster with other short flags before it (e.g. `-fB
            # main`) — the same not-a-shell-parser residual as every other
            # arm in this file; --ignore-other-worktrees and similar bare
            # flags are simply skipped over.
            #
            # Adversarial review round 2 (N5): switch's LONG form of -C is
            # --force-create (not modelled before), and a BUNDLED short
            # cluster (`checkout -fB main`) was missed entirely since the
            # old scan only matched a token whose FIRST characters were the
            # flag. The cluster is now scanned for the flag letter anywhere
            # after a leading dash, mirroring _bwimc_opt_scan's own -t
            # handling: everything in the SAME token after that letter is
            # its attached value, or — nothing follows — the NEXT token is.
            local gco_flag gco_want=0 gco_rest
            case "$sub" in checkout) gco_flag=B ;; *) gco_flag=C ;; esac
            for v in ${args[@]+"${args[@]}"}; do
                if [ "$gco_want" = 1 ]; then
                    case "$v" in
                        refs/heads/main|refs/heads/master|main|master)
                            _bwimc_git_check_common_owner "$gtarget" "$sub -$gco_flag clause $1" ;;
                    esac
                    gco_want=0
                    continue
                fi
                case "$v" in
                    --force-create=*)
                        case "${v#--force-create=}" in
                            refs/heads/main|refs/heads/master|main|master)
                                _bwimc_git_check_common_owner "$gtarget" "$sub --force-create clause $1" ;;
                        esac ;;
                    --force-create) gco_want=1 ;;
                    --*) ;;
                    -*"$gco_flag"*)
                        gco_rest="${v#*"$gco_flag"}"
                        if [ -n "$gco_rest" ]; then
                            case "$gco_rest" in
                                refs/heads/main|refs/heads/master|main|master)
                                    _bwimc_git_check_common_owner "$gtarget" "$sub -$gco_flag clause $1" ;;
                            esac
                        else
                            gco_want=1
                        fi ;;
                esac
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
# _bwimc_verb_clauses TEXT — HIMMEL-4010. The clauses of TEXT's substitution
# skeleton, each one preceded by the clauses of its own substitution bodies
# (recursively), bracketed by _BWIMC_SUBOPEN / _BWIMC_SUBCLOSE lines. A body
# inside a double-quoted span or backticks never reached the verb arms
# (`x="$(cp a <primary>/f)"`). A body expands before its clause runs, so it is
# emitted first, and the brackets let the loop restore the cwd a body's own
# `cd` changed. A real \003 in the input becomes `_`, so it cannot forge one.
_BWIMC_SUBOPEN=$'\003+'
_BWIMC_SUBCLOSE=$'\003-'
_bwimc_verb_clauses() {
    local text="${1//$'\003'/_}" line n bi=0 bodies=() k
    # shellcheck disable=SC2016  # literal `$(` is the glob pattern
    case "$text" in
        *'$('*|*'`'*) ;;
        *) _bwimc_split_clauses "$text"; return 0 ;;
    esac
    _bwimc_subst_split "$text"
    local skel="$_BWIMC_SKEL"
    for k in ${_BWIMC_BODIES[@]+"${!_BWIMC_BODIES[@]}"}; do
        bodies+=("${_BWIMC_BODIES[$k]}")
    done
    while IFS= read -r line; do
        n="${line//[!$'\001']/}"; n=${#n}
        while [ "$n" -gt 0 ] && [ "$bi" -lt "${#bodies[@]}" ]; do
            printf '%s\n' "$_BWIMC_SUBOPEN"
            _bwimc_verb_clauses "${bodies[$bi]}"
            printf '%s\n' "$_BWIMC_SUBCLOSE"
            bi=$((bi+1)); n=$((n-1))
        done
        printf '%s\n' "$line"
    done < <(_bwimc_split_clauses "$skel" skel)
}

_bwimc_ghb=$(_bwimc_join_continuations "$_bwimc_hb")
_bwimc_gcwd="$_bwimc_cwd"
_bwimc_gcwd_unres=0
_bwimc_gcwd_alts=""
_bwimc_galt_mode=""
_bwimc_genv_dir=""
_bwimc_genv_wt=""
_bwimc_genv_idx=""
_bwimc_genv_cfgglobal=""
_bwimc_genv_cfgsystem=""
_bwimc_genv_cfg=0
_bwimc_genv_prog=0
_bwimc_g_repoint=0
_bwimc_g_netop=0
_bwimc_g_jail=0
_bwimc_g_wrap=0
_bwimc_g_wprog=0
_bwimc_g_xargs=0
_bwimc_g_xinj=0
_bwimc_g_xtract_ok=0
case "$_bwimc_ghb" in
    *archive*) ! _bwimc_xtract_ok "$_bwimc_ghb" || _bwimc_g_xtract_ok=1 ;;
esac
while IFS= read -r _bwimc_clause; do
    [ -n "$(printf '%s' "$_bwimc_clause" | tr -d '[:space:]')" ] || continue
    # HIMMEL-4010: substitution bodies arrive as their own clauses; the
    # brackets only matter to the (b)/(e) cwd tracker, and this arm keeps
    # every cwd it has seen anyway, so a body's cd can only add denies.
    case "$_bwimc_clause" in "$_BWIMC_SUBOPEN"|"$_BWIMC_SUBCLOSE") continue ;; esac
    ! _bwimc_is_colon "$_bwimc_clause" || continue
    # HIMMEL-3685: this arm's own tracker already keeps every cwd a cd left
    # behind (_bwimc_gcwd_alts), so a `|`/`||`-reached cd needs no extra flag.
    _bwimc_clause_unpipe _bwimc_clause
    # A backtick substitution's body is its own command (`$(` is already a
    # clause break). Split quote-blind: a literal backtick inside quotes only
    # yields an extra fragment to classify (toward MORE denies, never fewer).
    _bwimc_gclause=$(_bwimc_space_before_redirects "$_bwimc_clause")
    while IFS= read -r _bwimc_gfrag; do
        _bwimc_git_clause "$_bwimc_gfrag"
    done < <(printf '%s\n' "${_bwimc_gclause//\`/$'\n'}")
done < <(_bwimc_verb_clauses "$_bwimc_ghb")

# ---- (b)/(e) per-clause verb scan, command-position anchored ----

_bwimc_ecwd="$_bwimc_cwd"
_bwimc_ecwd_unres=0
_bwimc_ecwd_pushn=0
_bwimc_spd_on=0
_bwimc_sub_ecwd=(); _bwimc_sub_unres=(); _bwimc_sub_pushn=(); _bwimc_sub_d=0
while IFS= read -r _bwimc_clause; do
    # HIMMEL-4329: a chroot root holds for its own clause only
    _bwimc_chroot=""
    # HIMMEL-4213: a wrapper chdir (`env -C DIR`) moved the cwd for its own
    # clause only — restore the cwd the clause before it left
    if [ "$_bwimc_spd_on" = 1 ]; then
        _bwimc_ecwd="$_bwimc_spd_ecwd"; _bwimc_ecwd_unres="$_bwimc_spd_unres"; _bwimc_spd_on=0
    fi
    case "$_bwimc_clause" in
        "$_BWIMC_SUBOPEN")
            _bwimc_sub_ecwd[_bwimc_sub_d]="$_bwimc_ecwd"
            _bwimc_sub_unres[_bwimc_sub_d]="$_bwimc_ecwd_unres"
            _bwimc_sub_pushn[_bwimc_sub_d]="$_bwimc_ecwd_pushn"
            _bwimc_sub_d=$((_bwimc_sub_d+1))
            continue ;;
        "$_BWIMC_SUBCLOSE")
            if [ "$_bwimc_sub_d" -gt 0 ]; then
                _bwimc_sub_d=$((_bwimc_sub_d-1))
                _bwimc_ecwd="${_bwimc_sub_ecwd[_bwimc_sub_d]}"
                _bwimc_ecwd_unres="${_bwimc_sub_unres[_bwimc_sub_d]}"
                _bwimc_ecwd_pushn="${_bwimc_sub_pushn[_bwimc_sub_d]}"
            fi
            continue ;;
    esac
    ! _bwimc_is_colon "$_bwimc_clause" || continue
    [ -n "$(printf '%s' "$_bwimc_clause" | tr -d '[:space:]')" ] || continue
    _bwimc_clause_unpipe _bwimc_clause
    _tolower_ascii "$_bwimc_clause"
    _bwimc_clause_lc="$_TOLOWER_OUT"
    _bwimc_interp_seen=0
    # HIMMEL-2592: the verb arms tokenize the SAME pre-spaced text arm (a)
    # does, so all arms share ONE tokenization and a redirect operator is a
    # token of its own everywhere. Recorded consequence: `cp src >/primary/f`
    # no longer resolves `>/primary/f` as a cp DESTINATION — arm (a) resolves
    # the real redirect target instead, so the coverage is relocated, not
    # lost (probe row: adjudicate6 1d / the cp-redirect row in the suite).
    _bwimc_clause_sp=$(_bwimc_space_before_redirects "$_bwimc_clause")
    # HIMMEL-3648: track cd/pushd/popd BEFORE this clause's own verb scan —
    # a bare `cd <dir>` clause matches none of the verb regexes below, so
    # this never diverts the elif chain; it only updates _bwimc_ecwd for
    # THIS and every LATER clause in the command.
    _bwimc_ecwd_track "$_bwimc_clause_sp" "$_bwimc_clause_piped"
    # HIMMEL-4153: the verb arms read the command word AFTER any leading
    # assignment words (ecwd tracking above keeps the whole clause — it
    # already treats an assignment prefix as unresolved). HIMMEL-4213: and
    # after a leading `{`, `!`, reserved word, `time` or wrapper command —
    # the wrapper check after the chain keeps the assignment-only reading.
    _bwimc_strip_prefix "$_bwimc_clause"
    if [ "$_BWIMC_SP0" != "$_bwimc_clause" ]; then
        _bwimc_clause_lc="${_bwimc_clause_lc:$((${#_bwimc_clause} - ${#_BWIMC_SP0}))}"
        _bwimc_clause_sp=$(_bwimc_space_before_redirects "$_BWIMC_SP0")
    fi
    _bwimc_wrap_lc="$_bwimc_clause_lc"; _bwimc_wrap_sp="$_bwimc_clause_sp"
    # HIMMEL-4329: a chroot root, read against the cwd before its own chdir
    [ -z "$_BWIMC_SPROOT" ] || _bwimc_root_model "$_BWIMC_SPROOT"
    if [ -n "$_BWIMC_SPDIR" ]; then
        _bwimc_spd_ecwd="$_bwimc_ecwd"; _bwimc_spd_unres="$_bwimc_ecwd_unres"; _bwimc_spd_on=1
        _bwimc_chdir_model "$_BWIMC_SPDIR"
    fi
    if [ "$_BWIMC_SP" != "$_BWIMC_SP0" ]; then
        _bwimc_clause_lc="${_bwimc_clause_lc:$((${#_BWIMC_SP0} - ${#_BWIMC_SP}))}"
        _bwimc_clause_sp=$(_bwimc_space_before_redirects "$_BWIMC_SP")
    fi

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
                    # HIMMEL-2656: an ABBREVIATED `--expression`/`--file`
                    # (`--expr=...`, `--exp foo.sed`) fell through this case
                    # entirely — matched neither the exact-name case above nor
                    # follow-symlinks/in-place below — so `_bwimc_saw_ef`
                    # stayed 0 and the real trailing file operand was
                    # mistaken for the implicit sed program (measured: the
                    # target file was skipped and could be rewritten
                    # unchecked). Same prefix helper as follow-symlinks/
                    # in-place below; the attached (`=value`) vs separate
                    # (next token) forms mirror the exact-match case's
                    # `_bwimc_i+1` vs `_bwimc_i+2` split.
                    if _bwimc_is_long_abbrev "expression" "$_bwimc_t" || _bwimc_is_long_abbrev "file" "$_bwimc_t"; then
                        _bwimc_saw_ef=1
                        case "$_bwimc_t" in
                            *=*) : ;;
                            *) _bwimc_i=$((_bwimc_i+1)) ;;
                        esac
                    elif _bwimc_is_long_abbrev "follow-symlinks" "$_bwimc_t"; then
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
                _bwimc_cd_guard "${_bwimc_bare[$_bwimc_k]}" "$_bwimc_sed_mode"
                _bwimc_check_target "${_bwimc_bare[$_bwimc_k]}" "$_bwimc_ecwd" "$_bwimc_sed_mode"
                _bwimc_k=$((_bwimc_k+1))
            done
        fi

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*eval([[:space:]]|$)') && [ -n "$_bwimc_m" ]; then
        _bwimc_interp_seen=1
        _bwimc_check_interp_body "$_bwimc_clause_sp" eval

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*([^[:space:]]*/)?(bash|sh|zsh|dash|ksh)(\.exe)?([[:space:]]+[^[:space:]]+)*[[:space:]]+-[a-z]*c[a-z]*([[:space:]]|$)') && [ -n "$_bwimc_m" ]; then
        # HIMMEL-3648 (CR #1307): allow an optional path prefix (`/bin/sh`,
        # `./bash`, …) before the shell name — an anchor on the bare name
        # only let a path-qualified invocation bypass body scanning entirely.
        # HIMMEL-3648 (codex-3): loosened from a literal `-c` to any
        # single-dash all-letters cluster containing `c` (`-ce`, `-ec`, …) —
        # real bash/sh/zsh getopt-style combined short flags a literal `-c`
        # match let straight through. Deliberately over-inclusive: the
        # precise check (and the actual body lookup) is
        # _bwimc_is_shc_cflag inside _bwimc_check_interp_body; a prefilter
        # false-positive here only means a harmless extra scan.
        # HIMMEL-3648 (round 10 codex-2): the middle group used to require
        # each intervening token to itself start with `-` (a flag), so a
        # flag that takes its own separate argument (`bash -o pipefail -c
        # '…'`) broke the chain — "pipefail" isn't `-`-prefixed, so the
        # match failed at the shell name and the whole body scan was
        # skipped. Widened to accept ANY intervening token, flag or not;
        # _bwimc_is_shc_cflag still does the precise per-token check, so
        # this stays a coarse, over-inclusive prefilter only.
        _bwimc_interp_seen=1
        _bwimc_check_interp_body "$_bwimc_clause_sp" shc

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*(install|rsync)(\.exe)?[[:space:]]+') && [ -n "$_bwimc_m" ]; then
        # HIMMEL-3648: install/rsync — the LAST non-option operand is the
        # write destination (install: `SOURCE... DEST` or, with -t/
        # --target-directory, `SOURCE... -t DIR`; rsync: `SRC... DEST`).
        # install's `-t DIR` / `-tDIR` / `--target-directory[=]DIR` share cp's
        # option NAME per the ticket, but are parsed with a dedicated,
        # minimal scan below rather than the shared `_bwimc_opt_scan` — that
        # scanner's bare `-t` means "value follows" for cp/mv, but rsync's own
        # `-t` (`--times`, no value) is unrelated, so reusing it here would
        # misread a bundled/bare rsync `-t` as consuming the next token.
        # rsync's other SEPARATED-value options (--exclude PATTERN, -e CMD,
        # --temp-dir DIR, ...) are now skipped below the same way, closing
        # the gap a round-f688778c critic found live (HIMMEL-3648, codex-3):
        # `rsync SRC /primary/dest --exclude pattern` used to let `pattern`
        # fall through as the "last operand", masking the real destination.
        # ponytail: only the SEPARATED form of those options is modelled — a
        # bundled/immediate-joined short-opt value (`-eCMD`) is not, and
        # falls through to the generic operand scan below. Escalate only if
        # a real gap surfaces (HIMMEL-3648).
        _bwimc_verb=$(printf '%s' "$_bwimc_clause_lc" | sed -E 's/^[[:space:]]*(install|rsync).*/\1/')
        _bwimc_toks=()
        while IFS= read -r _bwimc_t; do _bwimc_toks+=("$_bwimc_t"); done < <(_bwimc_tokenize "$_bwimc_clause_sp")
        _bwimc_ops=()
        _bwimc_tdir_raw=""
        _bwimc_dd=0
        _bwimc_install_dmode=0
        _bwimc_ntoks=${#_bwimc_toks[@]}
        _bwimc_i=1
        while [ "$_bwimc_i" -lt "$_bwimc_ntoks" ]; do
            _bwimc_t="${_bwimc_toks[$_bwimc_i]}"
            if _bwimc_redirect_op_of "$_bwimc_t"; then
                _bwimc_i=$(_bwimc_skip_redirect_at "$_bwimc_i")
                continue
            fi
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
            if [ "$_bwimc_verb" = "install" ]; then
                case "$_bwimc_t" in
                    -t?*)
                        _bwimc_tdir_raw="${_bwimc_t#-t}"
                        _bwimc_i=$((_bwimc_i+1))
                        continue
                        ;;
                    -t|--target-directory)
                        _bwimc_i=$(_bwimc_next_optval_idx "$_bwimc_i")
                        [ "$_bwimc_i" -lt "$_bwimc_ntoks" ] && _bwimc_tdir_raw="${_bwimc_toks[$_bwimc_i]}"
                        _bwimc_i=$((_bwimc_i+1))
                        continue
                        ;;
                    --target-directory=*)
                        _bwimc_tdir_raw="${_bwimc_t#--target-directory=}"
                        _bwimc_i=$((_bwimc_i+1))
                        continue
                        ;;
                    # HIMMEL-3648 (codex-2): `-d`/`--directory` puts install
                    # in directory-creation mode, where EVERY operand (not
                    # just the last) is itself a destination directory to
                    # create — the generic `-*` skip below silently dropped
                    # `-d`'s single operand from _bwimc_ops entirely,
                    # leaving neither branch of the resolution below able to
                    # fire.
                    # ponytail: only the bare `-d`/`--directory` spelling is
                    # modelled, not a bundled short-opt form (`-vd`) —
                    # escalate only if a real gap surfaces (HIMMEL-3648).
                    -d|--directory)
                        _bwimc_install_dmode=1
                        _bwimc_i=$((_bwimc_i+1))
                        continue
                        ;;
                    # HIMMEL-3648 (CR #1307): install's other SEPARATED
                    # mandatory-value options were not skipped, so — exactly
                    # like the rsync gap below — the value token fell through
                    # to the generic operand scan and could become the
                    # misread "last operand": `install SRC /primary/dest -m
                    # 755` picked up "755" as the destination, masking the
                    # real one.
                    -m|--mode|-o|--owner|-g|--group|-S|--suffix|--strip-program)
                        _bwimc_i=$(_bwimc_next_optval_idx "$_bwimc_i")
                        _bwimc_i=$((_bwimc_i+1))
                        continue
                        ;;
                esac
            fi
            # HIMMEL-3648 (codex-3, round f688778c): rsync's other
            # value-taking options were previously left un-skipped (see the
            # ponytail note above), so an option's VALUE fell through to the
            # generic `-*) : ;;` / bare-word split below and was picked up as
            # if it were a real operand — `rsync SRC /primary/dest --exclude
            # pattern` misread `pattern` as the LAST operand, masking the
            # true destination. Skip each one's separated value exactly like
            # install's -t/--target-directory above, so only real operands
            # ever reach _bwimc_ops.
            # HIMMEL-3648 (CR #1307): -T/--temp-dir's short form, -B
            # (--block-size), -M (--remote-option) and --suffix were missing
            # from this list — the same "value falls through as a bogus
            # operand" gap the comment above already covers for the rest.
            if [ "$_bwimc_verb" = "rsync" ]; then
                case "$_bwimc_t" in
                    -e|-f|--filter|--exclude|--exclude-from|--include|--include-from|--files-from|--temp-dir|-T|--backup-dir|--link-dest|--compare-dest|--copy-dest|--partial-dir|--log-file|--log-file-format|--out-format|--password-file|--bwlimit|--timeout|--contimeout|--port|--address|--sockopts|--usermap|--groupmap|--chown|--rsync-path|--rsh|--protocol|--checksum-seed|--max-size|--min-size|--modify-window|--skip-compress|--chmod|-B|--block-size|-M|--remote-option|--suffix|--max-delete|--iconv|--compress-level|--checksum-choice|--write-batch|--only-write-batch|--read-batch|--stop-after)
                        _bwimc_i=$(_bwimc_next_optval_idx "$_bwimc_i")
                        _bwimc_i=$((_bwimc_i+1))
                        continue
                        ;;
                esac
            fi
            case "$_bwimc_t" in
                -*) : ;;
                *) _bwimc_ops+=("$_bwimc_t") ;;
            esac
            _bwimc_i=$((_bwimc_i+1))
        done
        if [ -n "$_bwimc_tdir_raw" ]; then
            _bwimc_cd_guard "$_bwimc_tdir_raw"
            _bwimc_check_target "$_bwimc_tdir_raw" "$_bwimc_ecwd"
        elif [ "$_bwimc_install_dmode" = 1 ]; then
            _bwimc_k=0
            while [ "$_bwimc_k" -lt "${#_bwimc_ops[@]}" ]; do
                _bwimc_cd_guard "${_bwimc_ops[$_bwimc_k]}"
                _bwimc_check_target "${_bwimc_ops[$_bwimc_k]}" "$_bwimc_ecwd"
                _bwimc_k=$((_bwimc_k+1))
            done
        elif [ "${#_bwimc_ops[@]}" -ge 2 ]; then
            _bwimc_dest_raw="${_bwimc_ops[$((${#_bwimc_ops[@]}-1))]}"
            # HIMMEL-3648 (CodeRabbit #1307): a REMOTE rsync destination
            # (`user@host:/path`, `rsync://host/mod`) never writes into the
            # LOCAL primary checkout — resolving it as a local path (as the
            # generic destination check below does) can only mis-DENY it,
            # never mis-allow a real local write, but it is a genuine
            # functional-correctness bug CodeRabbit flagged, so skip the
            # local resolution for it. A bare drive letter (`C:/path`) is
            # excluded from the "has a colon" test so it is not misread as
            # a remote host.
            _bwimc_dest_remote=0
            case "$_bwimc_dest_raw" in
                [A-Za-z]:[/\\]*) ;;
                rsync://*) _bwimc_dest_remote=1 ;;
                *) case "${_bwimc_dest_raw%%/*}" in *:*) _bwimc_dest_remote=1 ;; esac ;;
            esac
            if [ "$_bwimc_dest_remote" = 0 ]; then
                _bwimc_cd_guard "$_bwimc_dest_raw"
                _bwimc_check_target "$_bwimc_dest_raw" "$_bwimc_ecwd"
            fi
        fi

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*dd(\.exe)?([[:space:]]|$)') && [ -n "$_bwimc_m" ]; then
        # HIMMEL-3648: dd's `of=PATH` key=value token is its write
        # destination; dd itself never takes it as two separate tokens.
        _bwimc_toks=()
        while IFS= read -r _bwimc_t; do _bwimc_toks+=("$_bwimc_t"); done < <(_bwimc_tokenize "$_bwimc_clause_sp")
        _bwimc_ntoks=${#_bwimc_toks[@]}
        _bwimc_i=1
        while [ "$_bwimc_i" -lt "$_bwimc_ntoks" ]; do
            _bwimc_t="${_bwimc_toks[$_bwimc_i]}"
            if _bwimc_redirect_op_of "$_bwimc_t"; then
                _bwimc_i=$(_bwimc_skip_redirect_at "$_bwimc_i")
                continue
            fi
            case "$_bwimc_t" in
                of=*)
                    _bwimc_ddof_raw="${_bwimc_t#of=}"
                    _bwimc_cd_guard "$_bwimc_ddof_raw"
                    _bwimc_check_target "$_bwimc_ddof_raw" "$_bwimc_ecwd"
                    ;;
            esac
            _bwimc_i=$((_bwimc_i+1))
        done

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
        # HIMMEL-2679: `--remove-destination` (cp only) unlinks the
        # destination ENTRY and creates a fresh regular file in its place,
        # rather than writing through a symlink referent. Ground-truthed
        # against GNU cp 9.11 at `<primary>/link -> <worktree>/file`: both
        # the direct-destination form and the directory-destination
        # (child-of-`-t`/positional-dir) form replace the ENTRY, so both
        # `_bwimc_dest_mode` and `_bwimc_child_mode` below need it.
        _bwimc_rmdest=0
        _bwimc_force=0
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
                    # HIMMEL-2679/J1285R: `-f`/`--force` is NOT the same as
                    # `--remove-destination`. `cp -f` does not unlink first —
                    # it opens the destination and FOLLOWS a symlink referent,
                    # falling back to unlink-and-recreate (ENTRY) only when
                    # that open fails on permissions (ground-truthed against
                    # real GNU coreutils 9.11). So the referent is the NORMAL
                    # write target and must be checked FOLLOW as well as
                    # ENTRY — `_bwimc_force` gets its own flag and is checked
                    # in `both` mode below, never folded into `_bwimc_rmdest`
                    # (which stays ENTRY-only, correct for the unconditional
                    # unlink `--remove-destination` performs).
                    [ "$_BWIMC_OPT_RMDEST" = 1 ] && _bwimc_rmdest=1
                    [ "$_BWIMC_OPT_FORCE" = 1 ] && _bwimc_force=1
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
        # `--remove-destination`'s unlink-fallback trigger and `-f`/`--force`
        # are cp-only: mv already replaces the entry unconditionally via
        # rename(2), so `-f`/`--force` there changes only the overwrite
        # PROMPT, never the mode.
        [ "$_bwimc_verb" = "cp" ] || _bwimc_rmdest=0
        [ "$_bwimc_verb" = "cp" ] || _bwimc_force=0
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
        # HIMMEL-2679: `cp --remove-destination` unlinks the child entry and
        # recreates it, the same as mv's rename(2) — ground-truthed at
        # `<dir>/link -> <worktree>/file`: the child became a REGULAR file.
        [ "$_bwimc_rmdest" = 1 ] && _bwimc_child_mode=entry
        # HIMMEL-2679/J1285R: `-f`/`--force` (without `--remove-destination`)
        # normally still writes THROUGH the child symlink referent (FOLLOW),
        # falling back to ENTRY only on a permission failure — check both.
        [ "$_bwimc_rmdest" = 0 ] && [ "$_bwimc_force" = 1 ] && _bwimc_child_mode=both
        # HIMMEL-3648 (round 10 codex-1): mv's SOURCE main check below uses
        # ENTRY (rename(2) moves the entry, never writes through it); cp
        # never checks its source as a destination at all, so "follow" here
        # is an inert default the main check never contradicts. Computed
        # once, shared by both the -t/--target-directory branch and the
        # positional branch below, and threaded into _bwimc_cd_guard so its
        # fallback matches the SAME mode the main check uses.
        _bwimc_src_cdmode=follow
        [ "$_bwimc_verb" = "mv" ] && _bwimc_src_cdmode=entry
        if [ -n "$_bwimc_tdir_raw" ]; then
            # -t/--target-directory mode: EVERY remaining operand is a
            # SOURCE; the sink for each is <target-dir>/<basename(source)>.
            # `-t`/`--target-directory` name the destination MORE explicitly
            # than the positional form, so it never depends on source parsing.
            # HIMMEL-3648 (J1307A F1, closes the HIMMEL-3726 regression): the
            # destination TYPE is resolved against the tracked cwd and, when a pipe,
            # subshell or `||` cd made it diverge, again against the real cwd.
            # _bwimc_check_abs exits on the first deny, so a deny from EITHER
            # resolution denies (union) - the fence may only ADD denies over main.
            _bwimc_dpass=0
            for _bwimc_dbase in "$_bwimc_ecwd" "$_bwimc_cwd"; do
                _bwimc_dpass=$((_bwimc_dpass+1))
                if [ "$_bwimc_dpass" = 2 ] && [ "$_bwimc_cwd" = "$_bwimc_ecwd" ]; then break; fi
                _bwimc_cd_guard "$_bwimc_tdir_raw"
                _bwimc_dest_abs=$(_bwimc_resolve_abs "$_bwimc_tdir_raw" "$_bwimc_dbase") || _bwimc_dest_abs=""
                if [ -n "$_bwimc_dest_abs" ]; then
                    _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_tdir_raw" follow
                else
                    _bwimc_check_glob_operand "$_bwimc_tdir_raw" "$_bwimc_dbase"
                fi
                _bwimc_j=0
                while [ "$_bwimc_j" -lt "${#_bwimc_ops[@]}" ]; do
                    _bwimc_src_raw="${_bwimc_ops[$_bwimc_j]}"
                    _bwimc_cd_guard "$_bwimc_src_raw" "$_bwimc_src_cdmode"
                    _bwimc_src_abs=$(_bwimc_resolve_abs "$_bwimc_src_raw" "$_bwimc_ecwd") || _bwimc_src_abs=""
                    # mv SOURCE: checked whether or not the DESTINATION resolved
                    # (round-5 hoist), with ENTRY semantics — rename(2) moves the
                    # directory entry, it never writes through the link.
                    if [ "$_bwimc_verb" = "mv" ]; then
                        if [ -n "$_bwimc_src_abs" ]; then
                            _bwimc_check_abs "$_bwimc_src_abs" "$_bwimc_src_raw" \
                                "$(_bwimc_mode_for_operand "$_bwimc_src_raw" entry)"
                        else
                            _bwimc_check_glob_operand "$_bwimc_src_raw" "$_bwimc_ecwd"
                        fi
                    fi
                    if [ -n "$_bwimc_src_abs" ] && [ -n "$_bwimc_dest_abs" ]; then
                        _bwimc_base="${_bwimc_src_abs##*/}"
                        _bwimc_check_abs "${_bwimc_dest_abs%/}/$_bwimc_base" "$_bwimc_tdir_raw" "$_bwimc_child_mode"
                    fi
                    _bwimc_j=$((_bwimc_j+1))
                done
            done
        else
            _bwimc_n=${#_bwimc_ops[@]}
            if [ "$_bwimc_n" -ge 2 ]; then
                _bwimc_dest_raw="${_bwimc_ops[$((_bwimc_n-1))]}"
                # HIMMEL-3648 (J1307A F1, closes the HIMMEL-3726 regression): the
                # destination TYPE is resolved against the tracked cwd and, when a pipe,
                # subshell or `||` cd made it diverge, again against the real cwd.
                # _bwimc_check_abs exits on the first deny, so a deny from EITHER
                # resolution denies (union) - the fence may only ADD denies over main.
                _bwimc_dpass=0
                for _bwimc_dbase in "$_bwimc_ecwd" "$_bwimc_cwd"; do
                    _bwimc_dpass=$((_bwimc_dpass+1))
                    if [ "$_bwimc_dpass" = 2 ] && [ "$_bwimc_cwd" = "$_bwimc_ecwd" ]; then break; fi
                    _bwimc_dest_abs=$(_bwimc_resolve_abs "$_bwimc_dest_raw" "$_bwimc_dbase") || _bwimc_dest_abs=""
                    _bwimc_dest_is_dir=0
                    _bwimc_dest_mode=follow
                    if [ -n "$_bwimc_dest_abs" ]; then
                        if [ "$_bwimc_nodrf" = 1 ]; then
                            # mv -T: the destination is the ENTRY, never a
                            # directory written through (see the -T note above).
                            _bwimc_dest_mode=$(_bwimc_mode_for_operand "$_bwimc_dest_raw" entry)
                        else
                            [ -d "$_bwimc_dest_abs" ] && _bwimc_dest_is_dir=1
                            if [ "$_bwimc_dest_is_dir" = 0 ] && { [ "$_bwimc_verb" = "mv" ] || [ "$_bwimc_rmdest" = 1 ]; }; then
                                # rename(2) replaces the ENTRY, so a destination
                                # that is a symlink to a NON-directory is written
                                # AT, not through (codex-2, ground-truthed).
                                # `cp --remove-destination` unlinks+recreates the
                                # same way (HIMMEL-2679, ground-truthed).
                                _bwimc_dest_mode=$(_bwimc_mode_for_operand "$_bwimc_dest_raw" entry)
                            elif [ "$_bwimc_dest_is_dir" = 0 ] && [ "$_bwimc_force" = 1 ]; then
                                # HIMMEL-2679/J1285R: `-f`/`--force` normally
                                # writes THROUGH the referent (FOLLOW) and falls
                                # back to unlink+recreate (ENTRY) only when that
                                # open fails on permissions — check both, never
                                # ENTRY-only (that missed the real write target).
                                _bwimc_dest_mode=$(_bwimc_mode_for_operand "$_bwimc_dest_raw" both)
                            fi
                        fi
                        _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_dest_raw" "$_bwimc_dest_mode"
                    else
                        _bwimc_check_glob_operand "$_bwimc_dest_raw" "$_bwimc_dbase"
                    fi
                    # HIMMEL-3648 (round 13, J1307Q): threaded AFTER $_bwimc_dest_mode
                    # is fully known (entry/both for a symlink-entry destination,
                    # follow for a directory or an unresolved operand) so the
                    # cd-divergence fallback runs the SAME mode the checks above
                    # just used — a hardcoded "follow" default here missed the
                    # ENTRY-mode DENY on a primary-tracked symlink destination
                    # once cd-tracking had diverged from the real cwd.
                    _bwimc_cd_guard "$_bwimc_dest_raw" "$_bwimc_dest_mode"
                    _bwimc_j=0
                    while [ "$_bwimc_j" -lt "$((_bwimc_n-1))" ]; do
                        _bwimc_src_raw="${_bwimc_ops[$_bwimc_j]}"
                        _bwimc_cd_guard "$_bwimc_src_raw" "$_bwimc_src_cdmode"
                        _bwimc_src_abs=$(_bwimc_resolve_abs "$_bwimc_src_raw" "$_bwimc_ecwd") || _bwimc_src_abs=""
                        if [ "$_bwimc_verb" = "mv" ]; then
                            if [ -n "$_bwimc_src_abs" ]; then
                                _bwimc_check_abs "$_bwimc_src_abs" "$_bwimc_src_raw" \
                                    "$(_bwimc_mode_for_operand "$_bwimc_src_raw" entry)"
                            else
                                _bwimc_check_glob_operand "$_bwimc_src_raw" "$_bwimc_ecwd"
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
                # HIMMEL-3648 (round 10 codex-1): pass rm/touch's own mode
                # through so the cd-divergence fallback in _bwimc_cd_guard
                # runs the same entry-vs-follow check the line below does.
                _bwimc_cd_guard "$_bwimc_t" "$_bwimc_mode"
                _bwimc_check_target "$_bwimc_t" "$_bwimc_ecwd" "$_bwimc_mode"
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
                *) _bwimc_cd_guard "$_bwimc_t" "$_bwimc_mode"; _bwimc_check_target "$_bwimc_t" "$_bwimc_ecwd" "$_bwimc_mode" ;;
            esac
            _bwimc_i=$((_bwimc_i+1))
        done

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*([^[:space:]]*/)?tee(\.exe)?[[:space:]]+') && [ -n "$_bwimc_m" ]; then
        # HIMMEL-4329 CR codex-2: arm (a) reads `tee` on the host only and
        # only behind its own short wrapper list, so `chroot P tee /f`,
        # `sudo -R P tee /f`, `nice tee`, `timeout 5 tee` and `/usr/bin/tee`
        # wrote into the primary unseen. Here tee is read behind every
        # stripped wrapper, its FILE operands (FOLLOW) through
        # _bwimc_check_target, which maps them into a chroot root. Arm (a)
        # still runs, so this can only add denials. tee takes no option with
        # a separate value; `--` ends option parsing.
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
            if [ "$_bwimc_dd" = 0 ] && [ "$_bwimc_t" = "--" ]; then
                _bwimc_dd=1
            elif [ "$_bwimc_dd" = 1 ]; then
                _bwimc_cd_guard "$_bwimc_t"; _bwimc_check_target "$_bwimc_t" "$_bwimc_ecwd"
            else
                case "$_bwimc_t" in
                    -*) : ;;
                    *) _bwimc_cd_guard "$_bwimc_t"; _bwimc_check_target "$_bwimc_t" "$_bwimc_ecwd" ;;
                esac
            fi
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
            _bwimc_ln_isdir0=$_bwimc_ln_isdir
            # HIMMEL-3648 (J1307A F1, closes the HIMMEL-3726 regression): the
            # destination TYPE is resolved against the tracked cwd and, when a pipe,
            # subshell or `||` cd made it diverge, again against the real cwd.
            # _bwimc_check_abs exits on the first deny, so a deny from EITHER
            # resolution denies (union) - the fence may only ADD denies over main.
            # _bwimc_ln_isdir is re-seeded each pass: -t presets it to 1.
            _bwimc_dpass=0
            for _bwimc_dbase in "$_bwimc_ecwd" "$_bwimc_cwd"; do
                _bwimc_dpass=$((_bwimc_dpass+1))
                if [ "$_bwimc_dpass" = 2 ] && [ "$_bwimc_cwd" = "$_bwimc_ecwd" ]; then break; fi
                _bwimc_ln_isdir=$_bwimc_ln_isdir0
                _bwimc_dest_abs=$(_bwimc_resolve_abs "$_bwimc_dest_raw" "$_bwimc_dbase") || _bwimc_dest_abs=""
                if [ -z "$_bwimc_dest_abs" ]; then
                    _bwimc_cd_guard "$_bwimc_dest_raw"
                    _bwimc_check_glob_operand "$_bwimc_dest_raw" "$_bwimc_dbase"
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
                        # HIMMEL-3648 (round 10 codex-1): _bwimc_cd_guard moved
                        # here, after $_bwimc_ln_isdir is known, so its fallback
                        # runs the SAME mode ("follow") the check two lines below
                        # uses — calling it before this branch was decided meant
                        # guessing.
                        _bwimc_cd_guard "$_bwimc_dest_raw" follow
                        # Check the directory itself UNCONDITIONALLY (so an
                        # all-unresolvable source list cannot skip it), then the
                        # entry each source creates inside it.
                        _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_dest_raw" follow
                        _bwimc_j=0
                        while [ "$_bwimc_j" -lt "$_bwimc_nsrc" ]; do
                            _bwimc_src_abs=$(_bwimc_resolve_abs "${_bwimc_ops[$_bwimc_j]}" "$_bwimc_ecwd") || _bwimc_src_abs=""
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
                        # HIMMEL-3648 (round 10 codex-1): same reasoning as the
                        # directory branch above — the fallback must match this
                        # branch's own ENTRY mode, not a guessed "follow".
                        _bwimc_cd_guard "$_bwimc_dest_raw" "$(_bwimc_mode_for_operand "$_bwimc_dest_raw" entry)"
                        _bwimc_check_abs "$_bwimc_dest_abs" "$_bwimc_dest_raw" \
                            "$(_bwimc_mode_for_operand "$_bwimc_dest_raw" entry)"
                    fi
                fi
            done
        fi
        # DOCUMENTED GAP: the one-operand form (`ln -s <target>`, which links
        # into the CWD under basename(target)) is not modelled — it is the
        # `cd`/cwd-predicate class this script deliberately leaves alone.

    elif _bwimc_m=$(printf '%s' "$_bwimc_clause_lc" | grep -E '^[[:space:]]*git(\.exe)?([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]]+)?)*[[:space:]]+commit([[:space:]]|$)') && [ -n "$_bwimc_m" ]; then
        _bwimc_git_commit_target "$_bwimc_clause_sp" "$_bwimc_ecwd"
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
        # HIMMEL-3648 (J1307P): this arm used to check only the TRACKED cwd
        # (_bwimc_ecwd), with no union fallback to the real payload cwd the
        # way _bwimc_cd_guard already gives every write-target arm — so a
        # `cd`/pushd whose tracked target diverges from where the shell
        # really is (nonexistent target, `||`/`|` short-circuit, etc., the
        # same C1 class round 9 fixed for write-target resolution) let a
        # write-on-main through once the tracker's cd moved _bwimc_ecwd off
        # main. Checking the real cwd too makes this a strict superset: a
        # divergence can only ADD a deny, never remove one.
        _bwimc_cwd_check_sourced "$_bwimc_ecwd"
        _bwimc_cwd_check_sourced "$_bwimc_cwd"
    fi
    # HIMMEL-4138: a shell or eval behind a wrapper (`nice bash -c`,
    # `timeout 5 sh -c`, `env FOO=1 bash -c`, `command eval`, `flock L -c`)
    # matched none of the anchored arms above, so its body went unscanned.
    # Checked after the chain, never instead of an arm, so it cannot take a
    # clause away from one; a shell word inside a quoted argument is not a
    # token of its own and finds nothing. The prefilter reads the clause
    # with quotes, backslashes and `$` removed, so `'bash'`, `ba''sh`,
    # `b\ash`, `$'bash'` and `$"bash"` reach the token scan, which unquotes
    # (and ANSI-C decodes) each word itself. An escape inside `$'…'` can spell
    # any name (`$'\x62ash'`), so a clause with one always takes the scan.
    _bwimc_wq="${_bwimc_wrap_lc//[\$\'\"\\]/}"
    if [ "$_bwimc_interp_seen" = 0 ] && { [[ "$_bwimc_wq" =~ $_BWIMC_WRAP_RE ]] || [[ "$_bwimc_wrap_lc" == *"\$'"* ]]; }; then
        _bwimc_check_interp_body "$_bwimc_wrap_sp" wrap
    fi
done < <(_bwimc_verb_clauses "$_bwimc_hb")
_bwimc_chroot=""
done  # HIMMEL-4138 readings

if [ "$_bwimc_sourced" = 1 ]; then
    return 0
else
    exit 0
fi
