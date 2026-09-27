#!/usr/bin/env bash
# scripts/guardrails/lesson-write-fence.sh - structural write-fence over
# enforcement-path files, for the lesson-loop (HIMMEL-767 deliverable 3).
#
# WHY: the self-evolving loop (lessons -> tickets/draft-PRs) is PROPOSE-ONLY.
# It must never be able to widen or disable the guards that would otherwise
# catch a bad proposal (guardrails/hooks/settings/pre-commit/CLAUDE.md/...).
# This fence is defense-in-depth UNDER the CR/operator-merge primary gate,
# not a replacement for it: a determined bypass via an out-of-charter shape
# (see below) is still caught by CR + operator review before merge.
#
# Two modes:
#
#   check <path>...   (CLI mode, for the future lesson-loop dispatcher and
#                       for tests). Evaluates ALWAYS - no env gate, the
#                       caller explicitly asked. Prints one line per path:
#                         deny\t<class>\t<path>
#                         allow\t-\t<path>
#                       Exit 2 if any path denies, 0 if all allow. Any error
#                       (unreadable/malformed policy, no jq, no paths given)
#                       is itself a deny-shaped exit 2 with a reason on
#                       stderr.
#
#   hook mode (default): PreToolUse JSON on stdin.
#     1. `[ "${HIMMEL_LESSON_LOOP:-0}" = "1" ] || exit 0` - inert otherwise
#        (zero always-on cost, HIMMEL-177). The thin hook
#        (block-lesson-enforcement-writes.sh) also fast-exits on this; the
#        double-gate is deliberate so this fence stays safe under direct
#        invocation too.
#     2. Once active: strict. No jq on PATH, or malformed JSON on stdin ->
#        DENY (the loop is fully automated; there is no human to mis-serve
#        by fail-closing here).
#     3. Edit|Write|NotebookEdit|MultiEdit: classify `.tool_input.file_path`
#        and `.tool_input.notebook_path` (MultiEdit carries one top-level
#        file_path). Any deny-list hit -> exit 2, stderr names the class +
#        why + the propose-only recovery (file a ticket / draft-PR body
#        proposing the change; enforcement edits are operator-lane).
#     3b. apply_patch (HIMMEL-2170, Codex's create/edit envelope - it has no
#        Edit/Write/NotebookEdit/MultiEdit tool at all): no `.tool_input.
#        file_path` either - every target lives inside `*** Add File:`/
#        `*** Update File:`/`*** Delete File:` lines in `.tool_input.command`
#        instead. Every such target is extracted and classified through the
#        SAME `classify_target` as step 3; any deny-list hit on ANY target
#        denies the whole call. A command carrying NONE of these lines
#        (malformed/unparseable patch text) is itself a DENY under
#        HIMMEL_LESSON_LOOP=1 - fail-closed, matching every other malformed-
#        input case in this file (see point 2 above).
#     4. Bash|PowerShell: round-4 REWRITE - an ARCHITECTURE INVERSION, not
#        another shape patch. Rounds 1-3b each closed one more per-verb
#        write-shape gap on a DENY-LIST of known writers (glued redirects,
#        `-tDIR` attached, PowerShell built-in aliases, `ln -sf`,
#        `truncate`, `mkdir`, ...) - a known convergence signature: every
#        adversarial CR round finds a NEW write shape the deny-list misses,
#        because enumerating "every way to write a file" is an open set.
#        Round 4 inverts to a READ-ONLY ALLOW-LIST instead: a small closed
#        set of command-position verbs PROVEN to only read are exempt from
#        operand checking; every OTHER verb - known writer, unknown
#        mutator, or a future tool this fence has never heard of - has ALL
#        its operands scanned as write-target candidates. This closes the
#        deny-list treadmill structurally: `ln`, `truncate`, `mkdir`, and
#        any verb not yet invented are covered for free, because the rule
#        is "not proven safe" rather than "known unsafe".
#          a. REDIRECT TARGETS ALWAYS DENY, position/verb-independent
#             (`_scan_redirects`, no exemption even for an allow-listed
#             verb: `cat file > scripts/hooks/a.sh` still writes). Every
#             token is checked for an operator ANYWHERE inside it, not just
#             a leading position, because this fence's word-splitter (like
#             graphify-fence's) only splits on whitespace - a real shell's
#             own `>`/`<` metacharacter-splitting never happens here, so
#             `echo x>scripts/hooks/a.sh` arrives as ONE token
#             (`x>scripts/hooks/a.sh`) and the target must be extracted from
#             inside it. Covers the standalone forms (`>`, `>>`, `<`, a lone
#             `N>`/`N>>` for ANY number of digits N - round 5, was
#             single-digit only) and any GLUED form (`word>file`, `word>>file`,
#             `N>file`, `>file`, `>>file`) alongside `dd`'s `of=TARGET`
#             convention (same position/verb-independent treatment - an
#             unambiguous key, and `dd` is not allow-listed either way).
#             `>|` (noclobber-override) and `>&` (both-streams-to-a-FILE) are
#             normalized to a plain `> ` in `evaluate_command`, BEFORE the
#             `;`/`|`/`&` clause split, so their target lands in this same
#             scan instead of being stranded across the split (round 6 -
#             see `evaluate_command`'s own header comment for the mechanics).
#             ACCEPTED: `<` (a READ) denies exactly like `>` here - this
#             fence cannot tell redirect direction apart from a bare
#             operator any more reliably than it tells shell dialects apart;
#             over-blocking a rare `cmd < enforcement-file` shape is the
#             accepted safe-direction cost, consistent with every other
#             over-deny already accepted in this file.
#          b. Resolve the command-position VERB, after skipping leading
#             `VAR=val` assignments (any letter-case, `[A-Za-z_]
#             [A-Za-z0-9_]*=`, round 5) and the common wrappers `command`/
#             `exec`/`builtin`/`nohup`/`time`/`nice` (transparent) and
#             `env`/`sudo`/`timeout` (consume their own flags/duration
#             first) - `_clause_head_idx`, adapted from graphify-fence.sh's
#             wrapper walk (HIMMEL-621). Wrappers may chain. `git commit`
#             names no target file at the git-hook-routing layer but IS a
#             candidate here (see `c.` below - `commit` is not a read verb).
#             As of round 5, `_check_git_hook_routing` (see the PLUS section
#             below) resolves its own git-clause head through this same
#             function, so `command git ...`/`env git ...`/`sudo git ...`/
#             `timeout N git ...` are recognized as git clauses instead of
#             bypassing hook-routing detection because the wrapper token sat
#             in position 0.
#          c. PROVEN-READ-ONLY allow-list (`_verb_is_read_only`) - exempt
#             from operand checking entirely: `cat`/`bat`/`tac`/`nl`/`less`/
#             `more`/`head`/`tail`/`grep`/`egrep`/`fgrep`/`rg`/`ripgrep`/
#             `ag`/`ls`/`dir`/`tree`/`wc`/`diff`/`cmp`/`comm`/`stat`/`file`/
#             `md5sum`/`sha1sum`/`sha256sum`/`shasum`/`cksum`/`cut`/`sort`/
#             `uniq`/`od`/`xxd`/`hexdump`/`column`/`jq`/`yq`/`true`/`:`/
#             `test`/`[`/`echo`/`printf`/the PowerShell readers `Get-Content`
#             (`gc`/`type`)/`Get-ChildItem` (`gci`)/`Select-String` (`sls`)/
#             `Measure-Object`/`Format-*`/`Write-Output`/`Write-Host`, and
#             `awk` (its own internal `> file` inside a program string is a
#             pre-existing accepted gap, and a REAL shell redirect around it
#             is still caught by `a.` regardless of `awk`'s allow-listing).
#             Four things are CLAUSE-CONDITIONAL rather than static
#             membership: `sed` (exempt unless `-i`/`-i<suffix>` is present
#             anywhere in the clause - plain `sed` never writes its input),
#             `find` (exempt unless `-delete`/`-exec`/`-execdir` is present -
#             those turn a traversal into a mutator; `find ... -exec rm {}
#             \;`'s DEFERRED argument is still not statically fenceable,
#             same class of gap as `xargs`), `git` (exempt only for
#             `status`/`log`/`diff`/`show`/`cat-file`/`rev-parse`/
#             `ls-files`/`blame`, or `config` carrying `--get`/`--get-all` -
#             `_git_is_read_only`; every other git verb, including bare
#             `add`/`rm`/`commit`/`config` writes, is a candidate), and the
#             interpreters `node`/`python`/`python3`/`bash`/`sh`/`pwsh`/
#             `bun`/`deno` (round 5, `_interpreter_is_read_only`) - exempt
#             ONLY when executing a SCRIPT FILE, i.e. no inline-eval flag is
#             present (consistent with the already-allowed `bash
#             scripts/hooks/test-x.sh`); an inline-eval flag - node/bun/deno
#             `-e`/`--eval`, python `-c`, bash/sh `-c`, pwsh
#             `-Command`/`-c`/`-EncodedCommand` - makes the interpreter NOT
#             exempt, and `process_clause_for_write` runs
#             `_clause_has_enforcement_signal` over the clause's RAW text
#             (not the split token array - an eval string's target lives
#             inside a quoted argument, not a bare operand token) and denies
#             on a hit (`python -c "open('scripts/hooks/x.sh','w')..."`,
#             `node -e "fs.writeFileSync('scripts/guardrails/x.sh',...)"`),
#             allows otherwise (`python -c "print(1)"`). ACCEPTED: the
#             substring scan is coarse - a target path built by STRING
#             CONCATENATION inside the eval never appears as a literal
#             substring and is not caught (same class of gap as `git
#             apply`/`patch`'s diff-body target); a handful of allow-listed
#             readers also accept their OWN rarely-used write flag (`sort -o
#             FILE`, GNU `awk -i inplace`) - invisible to operand scanning
#             once the verb itself is exempt.
#          d. Everything else (`_operand_targets`): EVERY non-redirect
#             operand of a non-exempt verb is a write-target candidate,
#             scanned uniformly - no more per-verb source/target carve-outs
#             (this DROPS the old `cp`-source read exemption: `cp
#             scripts/guardrails/lib.sh /tmp/x` now denies on the source
#             too, since `cp` itself is not proven read-only; safe-direction
#             regression, not a bug - use `cat`/`grep` to inspect an
#             enforcement file instead of `cp`-ing it out). Bare relative
#             operands are candidates too regardless of `is_path_like` (the
#             verb's own grammar already says it is a file operand - round 2
#             fix, unchanged). A dash-prefixed token contributes only its
#             INLINE value: PowerShell/long-option `-Path:X`/`-Path=X`/
#             `--target-directory=X` (`_ps_inline_value`, first `:`/`=`
#             after the leading dash) and the `cp`/`install` GLUED short
#             flag `-tDIR` (no separator - GNU grammar, round 4). The SPACE
#             forms (`-t DIR`, `--target-directory DIR`, `-Path VALUE`, ...)
#             need no special handling: the un-dashed value token gets
#             classified on its own next iteration regardless of which flag
#             preceded it - this is what makes `Copy-Item`'s free-form
#             argument order, and `Copy-Item`'s SOURCE, land the same way
#             `mv`'s source does, without a PowerShell-specific dispatch.
#             `-Value`/`-Value:x`/`-Value=x` (any case, space form skips its
#             value token too) are skipped everywhere, not just for three
#             named PowerShell cmdlets (round-3b's fix, generalized): that
#             parameter name conventionally holds literal CONTENT being
#             written, not a target - `Set-Content /tmp/ok.txt -Value
#             scripts/hooks/a.sh` still writes only `/tmp/ok.txt`. `-Value`
#             can still SMUGGLE a path-shaped string as content, but content
#             is not a write target, so no classification is needed there.
#             A read-shaped command (verb on the allow-list) touching an
#             enforcement path is otherwise ALLOWED (the loop may read the
#             gates it learns from) - this is the property the whole
#             inversion exists to preserve.
#        PLUS one non-file shape, unconditional regardless of the above: any
#        `git`/`git.exe` clause carrying a
#        hook-routing config key - `core.hooksPath` (bare `git config
#        core.hooksPath X`, `git config --unset core.hooksPath`, or
#        attached `git -c core.hooksPath=X <anything>`) or
#        `include.path`/`includeif.*` (same three forms - `git config --add
#        include.path X`, `git config --unset include.path`, `git -c
#        include.path=X <anything>`, or an `includeif.<condition>.path`
#        key) - denies (exit 2), since any of these can disable or reroute
#        every pre-commit/pre-push gate without writing any deny-listed
#        file (an included config file can itself set `core.hooksPath`). A
#        real `--get`/`--get-all` token anywhere in the clause is a read
#        carve-out and is allowed. Every token in the clause is passed
#        through `_strip_wrap` before this match (round-3b CR fix): a
#        quoted key - `git -c 'core.hooksPath=X' commit`,
#        `git config "core.hooksPath" X` - would otherwise arrive as one
#        token still carrying its surrounding quote chars and never match
#        the bare key; the `--get`/`--get-all` carve-out check is stripped
#        the same way.
#        PLUS one more non-file shape, round 7: process substitution
#        (`>(...)`/`<(...)`) with a PROVEN-READ-ONLY outer verb previously
#        slipped past the whole model - `echo x > >(tee scripts/hooks/a.sh)`
#        and `cat foo > >(tee scripts/hooks/a.sh)` both allowed, because the
#        outer verb (`echo`/`cat`) hits the `4.c` read-only short-circuit and
#        returns allow before the inner `tee` (a REAL write, once bash
#        actually runs the substitution) is ever examined; the redirect scan
#        (`4.a`) only classifies the token immediately after the `>`, which
#        is the procsub opener itself (`>(tee`), not the writer buried inside
#        it. `_clause_has_procsub` scans every token of the clause for a
#        bare `>(` or `<(` substring; if found, `_clause_has_enforcement_signal`
#        (the same coarse substring scan round 5 added for interpreter
#        inline-eval, `4.c` above) runs over the clause's RAW text and denies
#        on a hit - UNCONDITIONALLY, before the verb is even resolved, so no
#        outer-verb exemption (read-only allow-list OR interpreter) can short
#        -circuit past it. No hit -> allow (`echo x > >(tee /tmp/ok.txt)`).
#        ACCEPTED: same coarse-scan posture as `4.c`'s inline-eval check - a
#        target path built by STRING CONCATENATION inside the procsub is not
#        a literal substring and is not caught; and a clause carrying an
#        INPUT procsub of an enforcement path (`diff <(cat
#        scripts/guardrails/lib.sh) ...`) denies too under this same
#        substring scan even though that procsub only reads - safe-direction
#        over-block, consistent with `4.a`'s `<` treatment.
#     5. Any other tool -> exit 0.
#
# ACCEPTED out-of-charter limitations (the CR/operator-merge gate is the
# load-bearing backstop for these, same posture as the sibling fences):
#   - `git apply` / `patch`: the target path lives inside the diff BODY, not
#     as a command token - not statically detectable.
#   - inline interpreter writers (`python -c "..."`, `node -e "..."`): round
#     5 (`_clause_has_enforcement_signal`, see `4.c` above) denies these when
#     the eval string contains an enforcement-path signal as a literal
#     substring, but a target path assembled via STRING CONCATENATION inside
#     the eval (`'scripts/' + 'hooks/' + name`, `os.path.join(...)`) never
#     appears as one contiguous substring and is not caught - the target is
#     inside a quoted/computed string, not a bare token, so this remains an
#     accepted residual gap, narrower than before round 5 but not closed.
#   - process substitution (`>(...)`/`<(...)`) is COVERED as of round 7 (see
#     the `PLUS` section after `4.`'s git hook-routing shape-deny above) via
#     the same coarse `_clause_has_enforcement_signal` substring scan as the
#     interpreter inline-eval check, and carries the identical residual: a
#     target path built by STRING CONCATENATION inside the procsub
#     (`'scripts/' + 'hooks/' + name`) never appears as one literal
#     substring and is not caught - same class of gap as the inline-eval
#     residual immediately above.
#   - a handful of allow-listed readers accept their OWN rarely-used write
#     flag (`sort -o FILE`, GNU `awk -i inplace`, `awk`'s internal
#     `> file` inside a program string): invisible to operand scanning once
#     the verb itself is exempt (see `4.c`). A REAL shell redirect wrapped
#     around any of these (`awk '...' file > scripts/hooks/a.sh`) is still
#     caught by the position/verb-independent redirect scan (`4.a`).
#   - wrapper / quoting displacement: `_clause_head_idx` (`4.b`) now handles
#     the common wrappers (`exec`/`command`/`builtin`/`nohup`/`time`/`nice`/
#     `env`/`sudo`/`timeout`, chainable), closing the gap for those - the
#     remaining gap is a write verb reached through an UNRECOGNIZED wrapper
#     or a user-defined shell alias/function, which shares the command-text
#     scanning limits documented on block-terminal-write-fence.sh. (PowerShell
#     BUILT-IN aliases - `sc`/`ac`/`ni`/`ri`/`del`/`erase`/`rd`/`copy`/`cpi`/
#     `move`/`mi`/`ren`/`rni` - need no special handling at all any more:
#     none of them is on the round-4 read-only allow-list, so they fall
#     through to the same all-operand scan as their full cmdlet names for
#     free - the inversion's whole point.)
#   - `find ... -exec CMD {} \;` / `find ... | xargs CMD`: the DEFERRED
#     command's own arguments are materialised at runtime, not statically
#     detectable from the `find`/`xargs` clause's own tokens (same class of
#     gap as `git apply`/`patch`, above) - `find` losing its read-only
#     exemption on `-exec`/`-delete`/`-execdir` (`4.c`) only covers `find`'s
#     OWN direct mutation, not an exec'd command's.
#   - `<` (input redirection) denies like `>` (`4.a`) even though nothing is
#     written - the redirect scan cannot distinguish direction any more
#     reliably than it distinguishes shell dialects; accepted over-block.
#   - Hook-routing git config handling (`core.hooksPath`, `include.path`,
#     `includeif.*`) is SHAPE-detected (git/git.exe command-position token
#     + a matching config-key token), not file-detected - a value spread
#     across an unusual quoting form could evade the scan. (A single layer
#     of surrounding quotes on the key token IS stripped before matching,
#     round-3b; a wrapper ahead of the git token - `command`/`env`/`sudo`/
#     `timeout`/... - is resolved via `_clause_head_idx`, round 5, closing
#     that half of the gap - see `4.` above; multi-layer or otherwise
#     unusual quoting, or a wrapper this fence does not recognize, remains a
#     gap.)
#
# Cross-drive fail-closed (HIMMEL-845): a Windows drive-RELATIVE `X:tail` token
# resolves against Windows' PER-DRIVE current directory for X, not the process
# cwd, so HIMMEL-808's cwd anchor is exact only when the cwd is itself on drive
# X. `classify_target` now consults `_cross_drive_relative` FIRST and classifies
# the token as a `cross-drive` DENY unless its drive letter is provably the
# cwd's. Same-drive `X:tail` anchors exactly as before; drive-ROOTED `X:/tail`
# is cwd-independent and untouched. Maintained in lockstep with the twin in
# graphify-fence.sh.
#
# Path normalization: `_abs` / `_normalize` / `_lc` are the graphify-fence.sh
# helpers (`_abs` gains an explicit cwd-override 2nd arg here, since a hook
# payload's cwd - `.tool_input.cwd // .cwd // $PWD` - is not always the
# process's real $PWD). Prefix entries match against the REPO-RELATIVE path,
# where "repo" is resolved via the NEAREST EXISTING ANCESTOR directory
# (walk up from the candidate's parent until a directory exists, then
# `git -C <dir> rev-parse --show-toplevel`) - so a brand-new nested path
# whose immediate parent doesn't exist yet still resolves correctly. Unlike
# graphify-fence's marker stat-walks, this fence has no on-disk marker
# lookup, so the ancestor walk + git call both run against the LEXICALLY
# NORMALIZED form (not the raw candidate) - this is what makes a `..`
# traversal resolve to its collapsed target without requiring the
# intermediate (traversed-through) directory to actually exist.
#
# Shell options: `set -uo pipefail; set -f` (graphify-fence's model, not
# block-terminal-write-fence's `set -e`). `set -f` is load-bearing: without
# it a glob in a write-shape token (`rm scripts/hooks/*.sh`) would
# pathname-expand during this script's own word-split, before
# classification ever sees the literal token.
#
# Fail-closed clamp: an EXIT trap converts any abnormal exit (rc not in
# {0,2}) into exit 2. In hook mode it is armed ONLY once past the env gate
# (an inactive session must never be blocked by a bug in this fence). check
# mode bypasses the env gate entirely and therefore arms the clamp itself,
# first thing after mode detection, so its own errors also land as exit 2.
#
# Env override for tests: LESSON_FENCE_POLICY (policy path; default
# <script-dir>/enforcement-paths.json).
#
# Exit codes: 0 = allow; 2 = deny (stderr carries the reason; check mode
# also writes a per-path verdict to stdout).
set -uo pipefail
set -f  # no pathname expansion when we word-split a command / a path

deny() { # <reason>
    echo "lesson-write-fence: DENY $1" >&2
    exit 2
}

# shellcheck disable=SC2329,SC2317 # invoked indirectly via `trap ... EXIT`
_on_exit() {
    local rc=$?
    case "$rc" in
        0|2) exit "$rc" ;;
        *)   echo "lesson-write-fence: DENY abnormal exit (rc=$rc); fail-closed" >&2; exit 2 ;;
    esac
}

_init_paths() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    POLICY="${LESSON_FENCE_POLICY:-$SCRIPT_DIR/enforcement-paths.json}"
    # HIMMEL-2610: guard_is_long_abbrev (GNU getopt_long-style unambiguous
    # long-option abbreviation matching, the same rule HIMMEL-2592 used in
    # block-write-into-main-checkout.sh) is shared via lib.sh rather than
    # forked, so _clause_head_idx's wrapper arms below can recognize an
    # abbreviated `env --u`/`timeout --k`/`sudo --u` the same as the full
    # spelling. Fail-closed like every other lib.sh sourcing site.
    # shellcheck source=./lib.sh
    # shellcheck disable=SC1091
    if ! { [ -r "$SCRIPT_DIR/lib.sh" ] && . "$SCRIPT_DIR/lib.sh"; } 2>/dev/null; then
        deny "cannot source guardrails/lib.sh — refusing to evaluate (fail-closed)"
    fi
}

_require_jq() {
    command -v jq >/dev/null 2>&1 || deny "jq not found on PATH; cannot evaluate (fail-closed)"
}

# --- path helpers (copied/adapted from graphify-fence.sh, bash 3.2-safe) ---

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _strip_wrap <token> -> strip one layer of surrounding quotes/backticks (the
# tokeniser is quote-naive; a path token may arrive as `"path` or `path"`).
_strip_wrap() {
    local p="$1"
    p="${p%\"}"; p="${p#\"}"
    p="${p%\'}"; p="${p#\'}"
    p="${p%\`}"; p="${p#\`}"
    printf '%s' "$p"
}

# _abs <path> [cwd] -> absolute path (expanduser + anchor a relative path to
# the given cwd, default $PWD). One-arg form matches graphify-fence's _abs
# exactly; the optional 2nd arg is this fence's own addition so a hook
# payload's `.tool_input.cwd` can anchor a relative candidate.
_abs() {
    local p; p="$(_strip_wrap "$1")"
    local base="${2:-$PWD}"
    # Backslashes -> forward slashes BEFORE the absolute/relative split
    # (HIMMEL-808): on POSIX a backslash-form target ('\tmp\x' or 'C:\x')
    # matches neither /* nor [A-Za-z]:* below, gets anchored to cwd, and
    # normalizes to a non-enforcement path -> allow. Windows-payload parity
    # on every host; fail-closed for the rare POSIX filename containing a
    # literal backslash (_normalize already collapses them the same way).
    p="${p//\\//}"
    # shellcheck disable=SC2088 # the "~/" is a literal case-pattern, not an expansion
    case "$p" in
        "~")   p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    case "$p" in
        /*)          : ;;             # POSIX absolute
        [A-Za-z]:/*) : ;;             # Windows drive-ROOTED absolute (C:/...)
        [A-Za-z]:*)  p="$base/${p#?:}" ;;
                     # Windows drive-RELATIVE (C:foo = foo relative to the
                     # cwd on drive C). Codex-adv HIMMEL-808: the old
                     # [A-Za-z]:* arm classified this absolute, and
                     # _normalize mangled it into a synthetic non-repo path
                     # -> allow. Anchor to the payload cwd instead — exact
                     # when cwd is on that drive (the attack shape), and a
                     # fail-closed lexical approximation otherwise.
                     # HIMMEL-845: that "approximation" was NOT fail-closed - a
                     # CROSS-drive token anchored here normalized outside the
                     # repo and ALLOWED. This arm is now only ever reached for a
                     # token whose drive is PROVEN to be the cwd's drive (where
                     # the anchor is exact); `classify_target` rejects the
                     # cross-drive case up front via _cross_drive_relative.
        *)           p="$base/$p" ;;  # relative -> anchor to base
    esac
    printf '%s' "$p"
}

# _normalize <abs-path> -> lexically normalized, forward-slashed (collapse
# `.` / `..` segments; translate MSYS `/c/...` -> `c:/...`). Lexical only -
# no symlink resolution, no filesystem access.
_normalize() {
    local p="$1"
    p="${p//\\//}"   # backslashes -> forward slashes (Windows paths)
    case "$p" in
        /[A-Za-z]/*) p="${p:1:1}:/${p:3}" ;;
        /[A-Za-z])   p="${p:1:1}:/" ;;
    esac
    local prefix=""
    case "$p" in
        [A-Za-z]:/*) prefix="${p%%:*}:"; p="${p#[A-Za-z]:}" ;;
    esac
    local seg result="" oldIFS="$IFS"
    IFS='/'
    # shellcheck disable=SC2086 # intentional split on '/'
    set -- $p
    IFS="$oldIFS"
    for seg in "$@"; do
        case "$seg" in
            ''|.) : ;;
            ..)   result="${result%/*}" ;;
            *)    result="$result/$seg" ;;
        esac
    done
    printf '%s%s' "$prefix" "${result:-/}"
}

# _drive_of <path> -> echoes the LOWER-CASE drive letter of a path that is (or
# lexically normalizes to) drive-rooted (`C:/x`, MSYS `/c/x`), or "" when the
# path carries no determinable drive (a genuine POSIX root, or an MSYS MOUNT
# form like `/tmp/...` whose backing drive is not lexically derivable).
# Parity twin of graphify-fence.sh's _drive_of.
_drive_of() {
    local p; p="$(_normalize "$1")"
    case "$p" in
        [A-Za-z]:/*) _lc "${p%%:*}" ;;
        *)           printf '' ;;
    esac
}

# _cross_drive_relative <token> <base> -> 0 (CROSS-DRIVE, caller must fail
# closed) iff <token> is a Windows DRIVE-RELATIVE token (`X:tail`, a drive
# letter + colon with NO slash after it) that cannot be PROVEN to resolve
# against <base>. Parity twin of graphify-fence.sh's _cross_drive_relative -
# keep the two in lockstep.
#
# HIMMEL-845 (LIVE FAIL-OPEN, found empirically during the HIMMEL-809 CR):
# HIMMEL-808 closed the drive-relative hole by ANCHORING `X:tail` to the payload
# cwd (`_abs`'s `[A-Za-z]:*` arm). That anchor is exact ONLY when the cwd is
# itself on drive X. Windows keeps a SEPARATE current directory PER DRIVE (the
# hidden `=C:`/`=D:` environment variables), so `D:tail` from a process whose
# cwd is on C: resolves against D:'s own per-drive cwd - a directory this fence
# never sees. Anchoring it to the C: cwd produced a synthetic path that
# normalized to a non-enforcement location -> ALLOW, while the REAL target could
# be an enforcement-path file.
#
# Fail CLOSED rather than resolve: reading the per-drive cwd is not portable,
# not available to a bash 3.2 fence, and is exactly the kind of ambiguous
# evidence a guardrail must deny on. Three cases:
#   token drive == base drive  -> NOT cross-drive; `_abs`'s anchor is exact
#                                 (the process cwd IS that drive's cwd).
#   token drive != base drive  -> cross-drive; deny.
#   base drive undeterminable  -> cross-drive; deny. The fence cannot prove the
#                                 same-drive case, and "unprovable" is a deny
#                                 for a guardrail.
# ACCEPTED collateral (same safe-direction posture as `<`-denies-like-`>` and
# every other over-block in this file): on a genuine POSIX host `X:tail` is a
# plain relative FILENAME and anchoring it to the cwd is correct, but the base
# there carries no drive letter so it lands in the third case and denies. A
# single-letter-plus-colon operand is vanishingly rare, the deny is loud, and
# the recovery is one absolute path; the other misread is a silent
# enforcement-path write. A drive-ROOTED token (`C:/x`) is cwd-INDEPENDENT and
# is never cross-drive.
_cross_drive_relative() {
    local t tdrive bdrive
    t="$(_strip_wrap "${1:-}")"
    t="${t//\\//}"
    case "$t" in
        [A-Za-z]:/*) return 1 ;;   # drive-ROOTED absolute - cwd-independent
        [A-Za-z]:*)  : ;;          # drive-RELATIVE - the shape at issue
        *)           return 1 ;;
    esac
    tdrive="$(_lc "${t%%:*}")"
    bdrive="$(_drive_of "${2:-}")"
    [ -n "$bdrive" ] || return 0
    [ "$tdrive" = "$bdrive" ] && return 1
    return 0
}

# is_path_like <stripped-token> -> 0 if the token looks like a filesystem
# path (NOT a URL). Verbatim from graphify-fence.sh. No write-target scan
# position in this fence gates on it any more (round-3 CR fix - a bare
# word IS a candidate in a known write-target position; see the `4.`
# header note) - kept as a filter for a future scan of tokens whose role
# is NOT yet known.
# shellcheck disable=SC2329,SC2317 # currently unreferenced here; see comment above
is_path_like() {
    local t="$1"
    case "$t" in
        *://*) return 1 ;;
    esac
    case "$t" in
        */*|*\\*)     return 0 ;;
        "."|"..")     return 0 ;;
        [A-Za-z]:*)   return 0 ;;
        *.md|*.markdown|*.json|*.txt|*.py|*.js|*.ts|*.sh|*.html|*.htm|*.csv|*.yaml|*.yml|*.toml|*.rs|*.go|*.java|*.rb|*.c|*.h|*.cpp)
                      return 0 ;;
    esac
    return 1
}

# _nearest_toplevel <normalized-abs-path> -> echoes the git toplevel of the
# NEAREST EXISTING ANCESTOR directory (walk up from the path's parent until
# a directory exists, then resolve ITS toplevel once). Echoes "" if no
# ancestor exists or that ancestor is not inside a git repo.
_nearest_toplevel() {
    local p="$1" d prev=""
    d="${p%/*}"
    [ "$d" = "$p" ] && d=""
    while [ -n "$d" ] && [ "$d" != "$prev" ]; do
        if [ -d "$d" ]; then
            git -C "$d" rev-parse --show-toplevel 2>/dev/null
            return
        fi
        prev="$d"
        case "$d" in
            */*) d="${d%/*}" ;;
            *)   d="" ;;
        esac
    done
    printf ''
}

# --- policy -----------------------------------------------------------------

ENTRY_MATCH=(); ENTRY_VALUE=(); ENTRY_VALUE_LC=(); ENTRY_CLASS=(); ENTRY_WHY=(); ENTRY_COUNT=0

# Judge J1298E C1 (Critical, main DENY -> effective head ALLOW via timeout):
# every per-clause scan loop below (classify_target's basename/prefix loops,
# _clause_has_enforcement_signal's raw/normalized loops) used to lower each
# ENTRY_VALUE with a fresh `_lc` call - a `printf | tr` FORK - on every
# clause, so the fork cost scaled with ENTRY_COUNT * clauses-in-command
# instead of ENTRY_COUNT alone. A padded command with hundreds of cheap
# env/sudo clauses (`sudo true x; ` xK) drove that product past the 15s
# PreToolUse hook timeout, which fails OPEN. Fix: lower every ENTRY_VALUE
# ONCE here, at policy-load time, into ENTRY_VALUE_LC - every per-clause
# loop below reads the cached value instead of re-forking.
_cache_entry_value_lc() {
    ENTRY_VALUE_LC=()
    local i=0
    while [ "$i" -lt "$ENTRY_COUNT" ]; do
        ENTRY_VALUE_LC+=("$(_lc "${ENTRY_VALUE[$i]}")")
        i=$((i+1))
    done
}

load_policy() {
    _require_jq
    if [ ! -f "$POLICY" ] || [ ! -r "$POLICY" ]; then
        deny "enforcement-paths policy not found or unreadable: $POLICY (fail-closed)"
    fi
    if ! jq -e '.entries | type == "array"' "$POLICY" >/dev/null 2>&1; then
        deny "enforcement-paths policy is malformed or missing .entries: $POLICY (fail-closed)"
    fi
    ENTRY_MATCH=(); ENTRY_VALUE=(); ENTRY_CLASS=(); ENTRY_WHY=()
    local m v c w
    while IFS=$'\t' read -r m v c w; do
        ENTRY_MATCH+=("$m"); ENTRY_VALUE+=("$v"); ENTRY_CLASS+=("$c"); ENTRY_WHY+=("$w")
    done < <(jq -r '.entries[] | [.match, .value, .class, .why] | @tsv' "$POLICY" 2>/dev/null)
    ENTRY_COUNT=${#ENTRY_MATCH[@]}
    [ "$ENTRY_COUNT" -gt 0 ] || deny "enforcement-paths policy has zero entries (fail-closed): $POLICY"
    _cache_entry_value_lc
}

# classify_target <raw-path> [cwd] -> return 0 (DENY, sets _MATCH_CLASS /
# _MATCH_WHY) or 1 (allow / no match).
classify_target() {
    local raw="$1" cwd="${2:-$PWD}"
    local ap ap_lc base_lc i v_lc
    # HIMMEL-845, FIRST (before _abs ever anchors): a drive-RELATIVE `X:tail`
    # token whose drive is not provably the cwd's drive resolves against
    # Windows' per-drive cwd for X, which this fence cannot see. _abs would
    # anchor it to the payload cwd and hand back a synthetic path that
    # normalizes outside the repo -> allow (fail-open). Classify it as a DENY
    # instead - a return-0 hit rather than a bare `deny` call, so `check` mode
    # still prints its per-path verdict line and keeps scanning the rest of the
    # argument list. See _cross_drive_relative.
    if _cross_drive_relative "$raw" "$cwd"; then
        _MATCH_CLASS="cross-drive"
        _MATCH_WHY="drive-relative path resolves against Windows' per-drive current directory, which this fence cannot read; use an absolute path"
        return 0
    fi
    ap="$(_normalize "$(_abs "$raw" "$cwd")")"
    ap_lc="$(_lc "$ap")"
    base_lc="$(_lc "${ap##*/}")"

    i=0
    while [ "$i" -lt "$ENTRY_COUNT" ]; do
        if [ "${ENTRY_MATCH[$i]}" = "basename" ]; then
            v_lc="${ENTRY_VALUE_LC[$i]}"
            if [ "$base_lc" = "$v_lc" ]; then
                _MATCH_CLASS="${ENTRY_CLASS[$i]}"; _MATCH_WHY="${ENTRY_WHY[$i]}"
                return 0
            fi
        fi
        i=$((i+1))
    done

    local toplevel topnorm_lc relpath
    toplevel="$(_nearest_toplevel "$ap")"
    if [ -n "$toplevel" ]; then
        topnorm_lc="$(_lc "$(_normalize "$toplevel")")"
        topnorm_lc="${topnorm_lc%/}"
        case "$ap_lc" in
            "$topnorm_lc"/*)
                relpath="${ap_lc#"$topnorm_lc"/}"
                i=0
                while [ "$i" -lt "$ENTRY_COUNT" ]; do
                    if [ "${ENTRY_MATCH[$i]}" = "prefix" ]; then
                        v_lc="${ENTRY_VALUE_LC[$i]}"
                        case "$v_lc" in
                            */)
                                case "$relpath/" in
                                    "$v_lc"*)
                                        _MATCH_CLASS="${ENTRY_CLASS[$i]}"; _MATCH_WHY="${ENTRY_WHY[$i]}"
                                        return 0 ;;
                                esac
                                ;;
                            *)
                                if [ "$relpath" = "$v_lc" ]; then
                                    _MATCH_CLASS="${ENTRY_CLASS[$i]}"; _MATCH_WHY="${ENTRY_WHY[$i]}"  # fail-open-ok: this *) arm discriminates entry SHAPE (exact path vs the */ dir-prefix alternative), not an unclassified input — the entry table row is the classification and it matched exactly under the = guard above
                                    return 0
                                fi
                                ;;
                        esac
                    fi
                    i=$((i+1))
                done
                ;;
        esac
    fi
    return 1
}

_deny_enforcement() { # <path>
    deny "enforcement-path write refused: class=$_MATCH_CLASS ($_MATCH_WHY). This surface is propose-only: file a ticket or describe the change in a draft-PR body; enforcement-path edits are operator-lane. path=$1"
}

# _check_target <raw-token> <cwd> -> denies (exit 2) on a classified hit,
# otherwise returns 0 (allow). Every caller here is a write-target SCAN
# POSITION for a known verb - the verb's own grammar already says the
# token is a file operand, so this does NOT gate on is_path_like (a bare
# relative word with no slash/extension, e.g. `hooks`, is still a
# candidate; see the `4.` header note).
_check_target() {
    local raw="$1" cwd="$2" st
    st="$(_strip_wrap "$raw")"
    [ -n "$st" ] || return 0
    if classify_target "$st" "$cwd"; then
        _deny_enforcement "$st"
    fi
    return 0
}

# _redirect_target_in_token <token> -> echoes the target substring after the
# FIRST unquoted redirection operator found ANYWHERE inside the token (not
# just at its start), or returns 1 with no output if the token carries no
# such operator. This closes the glued-redirect gap (round 4): this fence's
# word-splitter (like graphify-fence's) only splits on whitespace, so a real
# shell's own `>`/`<` metacharacter-splitting never happens here -
# `echo x>scripts/hooks/a.sh` arrives as ONE token (`x>scripts/hooks/a.sh`),
# not the three words a real shell lexer would produce. Checking `*>>*`
# before `*>*` matters: on a `>>` token the `>*` pattern would otherwise
# strip only the first `>`, leaving a stray leading `>` glued onto the
# target and breaking the match. The word BEFORE the operator (an fd
# number, or an ordinary word like `x` above) is not examined - it is not a
# path candidate, and losing it has no bearing on the target half returned
# here.
_redirect_target_in_token() {
    local t="$1"
    case "$t" in
        *'>>'*) printf '%s' "${t#*>>}"; return 0 ;;
        *'>'*)  printf '%s' "${t#*>}";  return 0 ;;
        *'<'*)  printf '%s' "${t#*<}";  return 0 ;;
    esac
    return 1
}

# _is_all_digits <str> -> 0 iff str is non-empty and every character is 0-9.
_is_all_digits() {
    local s="$1"
    [ -n "$s" ] || return 1
    case "$s" in *[!0-9]*) return 1 ;; esac
    return 0
}

# _is_standalone_fd_redirect <token> -> 0 iff the token IS EXACTLY an
# fd-prefixed redirect operator with nothing glued after it (`N>`/`N>>` for
# ANY number of digits N - `5>`, `10>`, `123>>`, ...), i.e. the standalone
# form whose target is the NEXT token. Round-5 CR fix (panel codex-1,
# CRITICAL): the standalone-token case in `_scan_redirects` previously
# matched fd prefixes via the glob char class `[0-9]`, which matches exactly
# ONE character, so a realistic multi-digit fd (`10>`, well past the
# standard 0/1/2) fell through to the glued-token fallback
# (`_redirect_target_in_token`), which extracts an EMPTY target for a token
# with nothing after its own operator - silently dropping the actual target
# (the NEXT token) from consideration entirely, so `cat file 10>
# scripts/hooks/a.sh` (a read-only-exempt verb, which returns before ever
# reaching the generic operand scan) let the redirect target through
# unclassified.
_is_standalone_fd_redirect() {
    local t="$1" body
    case "$t" in
        *'>>') body="${t%>>}" ;;
        *'>')  body="${t%>}" ;;
        *)     return 1 ;;
    esac
    _is_all_digits "$body"
}

# _scan_redirects <cwd> <tok...> -> checks every REDIRECT target in the
# clause against policy and DENIES on a hit - unconditionally, with NO verb
# exemption (a redirect always touches a real file regardless of which
# command sits in front of it: `cat file > scripts/hooks/a.sh` still writes
# even though `cat` itself is proven read-only, below). Handles the
# standalone form (bare `>`/`>>`/`<`, or a lone fd-prefixed `N>`/`N>>` for
# ANY number of digits N, round-5 fix - see `_is_standalone_fd_redirect` -
# target is the NEXT token) and the glued form (operator embedded inside a
# token, target is that token's own suffix - see _redirect_target_in_token).
# Also treats `dd`'s `of=TARGET` convention the same way (position/verb-
# independent, an unambiguous key, and dd is not on the read-only allow-list
# either way - see the `4.` header note). Populates the global REDIR_SKIP
# array (index -> 1) for every token consumed as pure redirect/`of=` syntax,
# so _operand_targets does not re-examine it as an ordinary positional
# operand under the verb-based rule.
# ACCEPTED limitation: `<` (input redirection, a READ) is treated the same
# as `>`/`>>` here - denying `cmd < scripts/hooks/a.sh` even though nothing
# is written - because this fence cannot tell redirect direction apart from
# a bare operator any more reliably than it can tell shell dialects apart;
# see the header's over-blocking-is-safe posture.
# J1298F-followup (found while verifying codex-1): this runs FIRST in
# process_clause_for_write, unconditionally, on the full token array, calling
# `_is_standalone_fd_redirect`/`_redirect_target_in_token` per token with no
# deadline check at all - timing-verified as the ACTUAL dominant cost for a
# K=20000 padding-token clause (~24s alone, dwarfing every fork-eliminated
# loop below it) even after `_clause_head_idx`/`_check_git_hook_routing` were
# fixed. Same class as J1298F C1/codex-1: an unbounded per-token loop with no
# deadline check outruns the 15s hook timeout. Now checks the deadline every
# iteration like the other per-token loops in this file.
REDIR_SKIP=()
_scan_redirects() {
    local cwd="$1"; shift
    local -a tok=("$@")
    local n=${#tok[@]} i=0 t tgt
    REDIR_SKIP=()
    while [ "$i" -lt "$n" ]; do
        if [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ]; then
            deny "command evaluation exceeded the fail-closed time budget (${MAX_EVAL_SECONDS}s); denying the remainder outright (fail-closed)"
        fi
        t="${tok[$i]}"
        case "$t" in
            '>'|'>>'|'<')
                REDIR_SKIP[i]=1
                i=$((i+1))
                if [ "$i" -lt "$n" ]; then
                    _check_target "${tok[$i]}" "$cwd"
                    REDIR_SKIP[i]=1
                fi
                ;;
            of=*)
                REDIR_SKIP[i]=1
                tgt="${t#of=}"
                [ -n "$tgt" ] && _check_target "$tgt" "$cwd"
                ;;
            *)
                if _is_standalone_fd_redirect "$t"; then
                    REDIR_SKIP[i]=1
                    i=$((i+1))
                    if [ "$i" -lt "$n" ]; then
                        _check_target "${tok[$i]}" "$cwd"
                        REDIR_SKIP[i]=1
                    fi
                elif tgt="$(_redirect_target_in_token "$t")"; then
                    REDIR_SKIP[i]=1
                    [ -n "$tgt" ] && _check_target "$tgt" "$cwd"
                fi
                ;;
        esac
        i=$((i+1))
    done
}

# _clause_head_idx <tok...> -> echoes the index of the command-position
# verb, after skipping leading `VAR=val` assignments and the common
# transparent/argument-eating command wrappers (round 4, adapted from
# graphify-fence.sh's classify_clause wrapper walk, HIMMEL-621, trimmed to
# the wrappers this fence's own accepted-limitations list calls out):
# `command`/`exec`/`builtin`/`nohup`/`time`/`nice` consume no args of their
# own; `env`/`sudo`/`timeout` consume their OWN flags (and, for `timeout`,
# its DURATION positional) before the real command. Wrappers may chain
# (`sudo timeout 30 rm ...`). This only affects which token NAMES the verb
# for the allow-list check below - a wrapper itself is never proven
# read-only, so `sudo cat file` still resolves to verb=`cat` and is
# correctly exempted, while `sudo rm scripts/hooks/a.sh` resolves to
# verb=`rm`, not on the allow-list, and its operand still denies. A wrapper
# reached through an unrecognized name, or a user-defined alias/function, is
# an accepted gap - see the header's ACCEPTED-limitations list. The
# assignment pattern (`[A-Za-z_][A-Za-z0-9_]*=`) is checked here against the
# already-lowered `s`, so uppercase/mixed-case names (`FOO=1 cat ...`)
# matched even before round 5 - the round-5 fix (panel codex-2) widens the
# character class anyway, as a defensive/self-documenting POSIX env-var-name
# grammar (letter/underscore then word chars), not a case-insensitivity fix
# that was already covered by the pre-lowering.
#
# HIMMEL-3757: `_bundle_value_at_end` and the case-sensitive short-option
# matching it supported (HIMMEL-3658/HIMMEL-3659) were reverted from the
# `env`/`sudo` arms below after judge J1298C found the replacement letter
# sets opened 12 NEW main-DENY -> head-ALLOW gaps (`env -c`/`-U`, `sudo
# -d`/`-G`/`-H`/`-P`, each + `cat`). Head-index accuracy for these wrappers
# is tracked as HIMMEL-3757, scoped so any future fix there can only ADD
# denials relative to main.
#
# J1298F-followup (codex-1, Important -> agreed): this used to fork
# `_strip_wrap`+`_lc` per token in every loop below, exactly the shape J1298F
# C1 fixed in `_env_split_string_used`/`_wrapper_is_env_or_sudo` - timing-
# verified 56s/233s for K=8000/20000 padding tokens with no wrapper needed
# (this outer loop matches `nice` cheaply and runs unconditionally), both far
# past the 15s hook timeout with zero deadline check anywhere in this
# function. Now indexes the global `LC_TOK` array instead of forking, exactly
# like `_env_split_string_used`/`_wrapper_is_env_or_sudo` - the CALLER must
# have already run `_lc_all` on this SAME token array first (an internal
# `_lc_all` call here would double the cost instead of eliminating it: this
# function always runs inside a `$(...)` command substitution, so a caller
# who has not pre-populated `LC_TOK` gets stale/empty data, not a crash -
# both current callers populate it immediately before calling this). Checks
# the deadline every iteration of every loop below; a caller retrieving
# `head_idx` back from the subshell re-checks `$SECONDS` itself immediately
# afterward (real process, `deny` works there) since `deny`'s `exit` inside
# this subshelled function would only end the subshell, not the command.
_clause_head_idx() {
    local -a tok=("$@")
    local n=${#tok[@]} i=0 s w
    while [ "$i" -lt "$n" ]; do
        [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ] && break
        s="${LC_TOK[$i]}"
        s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; s="${s%\`}"; s="${s#\`}"
        case "$s" in
            [A-Za-z_][A-Za-z0-9_]*=*)
                i=$((i+1)); continue ;;
            command|exec|builtin|nohup|time|nice)
                i=$((i+1)); continue ;;
            env)
                i=$((i+1))
                # HIMMEL-2610: `--u`/`--uns`/... are unambiguous GNU
                # abbreviations of env's only value-taking long option,
                # --unset (empirically verified: `env --u FOO true` behaves
                # identically to `env --unset FOO true`). The old literal
                # `--unset` match missed every shorter spelling, under-
                # consuming by one token and misaligning the walk onto
                # --unset's VALUE as the resolved verb - if that value is
                # crafted to name a proven-read-only verb (e.g. `cat`), the
                # real wrapped write command was never scanned at all.
                # HIMMEL-3757: this arm's short-option matching was made
                # case-sensitive (HIMMEL-3658) to recognize `-a`/`--argv0` as
                # value-taking, but judge J1298C found the replacement letter
                # set opened 2 NEW main-DENY -> head-ALLOW gaps (`-c`, `-U`)
                # that main's case-insensitive match had covered by accident.
                # Reverted to main's exact case-insensitive matching; env -a
                # and this arm's other head-index gaps are tracked as
                # HIMMEL-3757 (ADD-only denials from here). The separate flat
                # `-S`/`--split-string` deny below (`_env_split_string_used`)
                # is untouched by this revert.
                while [ "$i" -lt "$n" ]; do
                    [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ] && break
                    w="${LC_TOK[$i]}"
                    w="${w%\"}"; w="${w#\"}"; w="${w%\'}"; w="${w#\'}"; w="${w%\`}"; w="${w#\`}"
                    case "$w" in
                        -u|-c)                    i=$((i+2)) ;;
                        [A-Za-z_][A-Za-z0-9_]*=*) i=$((i+1)) ;;
                        --*)
                            if guard_is_long_abbrev "unset" "$w" || guard_is_long_abbrev "chdir" "$w" \
                                || guard_is_long_abbrev "argv0" "$w"; then
                                if [ "$GUARD_LOPT_HAS_EQ" = 1 ]; then i=$((i+1)); else i=$((i+2)); fi
                            else
                                i=$((i+1))
                            fi ;;
                        -*)                       i=$((i+1)) ;;
                        *)                        break ;;
                    esac
                done
                continue ;;
            timeout)
                i=$((i+1))
                # HIMMEL-2610: same shape as env's --unset above - --k/--s
                # are unambiguous abbreviations of --kill-after/--signal
                # (empirically verified: `timeout --k 5 10 true` behaves
                # identically to `timeout --kill-after 5 10 true`).
                while [ "$i" -lt "$n" ]; do
                    [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ] && break
                    w="${LC_TOK[$i]}"
                    w="${w%\"}"; w="${w#\"}"; w="${w%\'}"; w="${w#\'}"; w="${w%\`}"; w="${w#\`}"
                    case "$w" in
                        -k|-s)                    i=$((i+2)) ;;
                        --*)
                            if guard_is_long_abbrev "kill-after" "$w" || guard_is_long_abbrev "signal" "$w"; then
                                if [ "$GUARD_LOPT_HAS_EQ" = 1 ]; then i=$((i+1)); else i=$((i+2)); fi
                            else
                                i=$((i+1))
                            fi ;;
                        -*)                       i=$((i+1)) ;;
                        *)                        break ;;
                    esac
                done
                [ "$i" -lt "$n" ] && i=$((i+1))
                continue ;;
            sudo)
                i=$((i+1))
                # HIMMEL-2610: this arm's short flags never had a matching
                # long-option literal at all (not even the full spelling),
                # the same under-consumption shape as env/timeout above -
                # `sudo --user cat cp x scripts/hooks/a.sh` fell through to
                # the generic bare-flag branch, one token short, and
                # resolved verb=`cat` (allow-listed) instead of `cp`. Long
                # names per `sudo --help` on this station (-r/-t are
                # SELinux-only and not compiled into this build, so those two
                # are taken from upstream sudo.ws docs, unverified locally).
                # HIMMEL-3757: this arm's short-option matching was made
                # case-sensitive (HIMMEL-3659) to stop folding no-arg -H/-P
                # onto value-taking -h/-p, but judge J1298C found the
                # replacement letter set opened 4 NEW main-DENY ->
                # head-ALLOW gaps (`-d`, `-G`, `-H`, `-P`). Reverted to
                # main's exact case-insensitive matching; sudo -H/-P and this
                # arm's other head-index gaps are tracked as HIMMEL-3757
                # (ADD-only denials from here).
                while [ "$i" -lt "$n" ]; do
                    [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ] && break
                    w="${LC_TOK[$i]}"
                    w="${w%\"}"; w="${w#\"}"; w="${w%\'}"; w="${w#\'}"; w="${w%\`}"; w="${w#\`}"
                    case "$w" in
                        -u|-g|-U|-p|-C|-r|-t|-h|-d) i=$((i+2)) ;;
                        --)                       i=$((i+1)); break ;;
                        --*)
                            if guard_is_long_abbrev "user" "$w" || guard_is_long_abbrev "group" "$w" \
                                || guard_is_long_abbrev "other-user" "$w" || guard_is_long_abbrev "prompt" "$w" \
                                || guard_is_long_abbrev "close-from" "$w" || guard_is_long_abbrev "role" "$w" \
                                || guard_is_long_abbrev "type" "$w" || guard_is_long_abbrev "host" "$w" \
                                || guard_is_long_abbrev "chdir" "$w"; then
                                if [ "$GUARD_LOPT_HAS_EQ" = 1 ]; then i=$((i+1)); else i=$((i+2)); fi
                            else
                                i=$((i+1))
                            fi ;;
                        [A-Za-z_][A-Za-z0-9_]*=*) i=$((i+1)) ;;
                        -*)                       i=$((i+1)) ;;
                        *)                        break ;;
                    esac
                done
                continue ;;
        esac
        break
    done
    printf '%s' "$i"
}

# _ps_inline_value <dash-token> -> prints the value half of a PowerShell
# inline named-parameter token (`-Path:VALUE`, `-FilePath=VALUE`): the
# substring after the FIRST `:` or `=` found past the leading dash. Prints
# nothing if the token carries no such separator (a plain flag, or a
# space-separated `-Path VALUE` form the caller handles as two tokens).
_ps_inline_value() {
    local t="$1" len i c
    len=${#t}
    i=1  # skip the leading '-' (possibly '--')
    while [ "$i" -lt "$len" ]; do
        c="${t:$i:1}"
        case "$c" in
            :|=) printf '%s' "${t:$((i+1))}"; return 0 ;;
        esac
        i=$((i+1))
    done
    printf ''
}

# _git_is_read_only <verb-onward-tok...> -> 0 iff tok[0] is `git` and its
# subcommand (tok[1]) is one of the PROVEN read-only ones (`status`/`log`/
# `diff`/`show`/`cat-file`/`rev-parse`/`ls-files`/`blame`), or is `config`
# AND the clause carries a `--get`/`--get-all` token (the same read
# carve-out `_check_git_hook_routing` already applies). Every git verb NOT
# on this list (`add`/`rm`/`commit`/bare `config`/...) is treated as a
# potential writer under the generic operand rule below. Does not duplicate
# the hook-routing check: `_check_git_hook_routing` runs unconditionally per
# clause (see evaluate_command) regardless of this function's verdict, so
# `core.hooksPath`/`include.path` still deny even under an otherwise
# read-shaped git invocation that happens to also carry a routing key.
_git_is_read_only() {
    local -a tok=("$@")
    local n=${#tok[@]} sub i t_lc
    [ "$n" -ge 2 ] || return 1
    sub="$(_lc "$(_strip_wrap "${tok[1]}")")"
    case "$sub" in
        status|log|diff|show|cat-file|rev-parse|ls-files|blame)
            return 0 ;;
        config)
            i=0
            while [ "$i" -lt "$n" ]; do
                t_lc="$(_lc "$(_strip_wrap "${tok[$i]}")")"
                case "$t_lc" in --get|--get-all) return 0 ;; esac
                i=$((i+1))
            done
            return 1 ;;
    esac
    return 1
}

# _interpreter_is_read_only <verb_lc> <verb-onward-tok...> -> 0 iff NONE of
# the clause's tokens is an inline-eval flag for that interpreter family -
# i.e. the interpreter is executing a SCRIPT FILE (the pre-existing exempt
# case, e.g. `bash scripts/hooks/test-x.sh`), not evaluating an inline
# string. Round-5 CR fix (codex-adv-1, HIGH): before this fix these
# interpreters were UNCONDITIONAL allow-list members in `_verb_is_read_only`
# ("running a script is a read of it"), which also silently exempted their
# OWN inline-eval forms (`python -c "..."`, `node -e "..."`, `bash -c
# "..."`, `pwsh -Command "..."`) - a write hidden inside a quoted argument
# is invisible to `_operand_targets`' token-shaped scan regardless (the
# token is code + quoting, not a clean path), so exempting the clause
# outright meant NO check ever ran on it. An inline-eval flag now makes the
# interpreter NOT exempt (return 1); the caller (`process_clause_for_write`)
# does not fall through to the generic per-token operand scan for these
# verbs either (it would not catch the target, for the same quoting reason)
# - it instead runs `_clause_has_enforcement_signal` over the RAW clause
# text and denies on a hit, allows otherwise.
#
# _normalize_scan_text <raw-text> -> squeezes repeated `/` down to one,
# drops `/./ ` segments, collapses `seg/../` hops, and strips quote/backslash
# characters - the raw-TEXT counterpart to `_normalize`'s path-SEGMENT
# collapsing, for callers (below) that substring-scan whole clause text
# rather than resolve a single path.
# Judge J1298R N1 (Critical): the collapse above stopped at `//` and `/./ `
# and never stripped backslashes, so `env -S 'tee scripts/x/../hooks/a.sh'`,
# a backslash-escaped `scripts/\hooks/a.sh`, and the same `../` hop against
# `.claude/settings.json` all evaded the scan.
# Judge J1298O C1 (Critical, NEW ALLOW vs main): `_clause_has_enforcement_signal`
# matched the literal substring only, so a policy value written with a
# single slash (`scripts/hooks/`) missed the identical write spelled
# `scripts//hooks/a.sh` or `scripts/./hooks/a.sh` - GNU coreutils resolve
# both exactly as the plain path, so the fence must scan as if normalized
# too. Text-level only (no filesystem access, no anchoring) since the
# caller has no single resolved path to normalize.
# /pr-check critic panel (codex-1, this branch): the `seg/../` loop below
# used to walk left-to-right and, on hitting an unresolvable leading `..`
# (no real parent segment to consume), `break` out of the WHOLE loop rather
# than skip just that one hop - so `env -S 'tee /../../../tmp/f
# scripts/ci/../hooks/a.sh'` left the later, independently-resolvable
# `scripts/ci/../hooks/` hop uncollapsed and the raw-text scan missed the
# `scripts/hooks/` prefix entirely. Fixed: an unresolvable hop is moved,
# uncollapsed, into `out` and the loop continues scanning the remainder for
# further `/../` occurrences instead of abandoning the pass.
_normalize_scan_text() {
    local t="$1" before after seg out
    t="${t//\'/}"; t="${t//\"/}"; t="${t//\`/}"; t="${t//\\/}"
    while case "$t" in *//*) true ;; *) false ;; esac; do
        t="${t//\/\//\/}"
    done
    while case "$t" in *"/./"*) true ;; *) false ;; esac; do
        t="${t//\/.\//\/}"
    done
    out=''
    while case "$t" in */../*) true ;; *) false ;; esac; do
        before="${t%%/../*}"
        after="${t#*/../}"
        case "$before" in
            */*) seg="${before##*/}" ;;
            *)   seg="$before" ;;
        esac
        case "$seg" in
            ..|'')
                out="$out$before/../"
                t="$after"
                continue
                ;;
        esac
        case "$before" in
            */*) before="${before%/*}" ;;
            *)   before="" ;;
        esac
        if [ -n "$before" ]; then
            t="$before/$after"
        else
            t="$after"
        fi
    done
    printf '%s' "$out$t"
}
_interpreter_is_read_only() {
    local verb="$1"; shift
    local -a tok=("$@")
    local n=${#tok[@]} i=1 t_lc
    while [ "$i" -lt "$n" ]; do
        t_lc="$(_lc "${tok[$i]}")"
        case "$verb" in
            node|bun|deno)
                case "$t_lc" in -e|--eval) return 1 ;; esac ;;
            python|python3)
                case "$t_lc" in -c) return 1 ;; esac ;;
            bash|sh)
                case "$t_lc" in -c) return 1 ;; esac ;;
            pwsh)
                case "$t_lc" in -command|-c|-encodedcommand) return 1 ;; esac ;;
        esac
        i=$((i+1))
    done
    return 0
}

# _clause_has_enforcement_signal <raw-clause-text> -> 0 iff the raw clause
# text contains, as a plain case-insensitive SUBSTRING, any policy prefix
# value or basename value from the loaded policy (`ENTRY_MATCH`/
# `ENTRY_VALUE`, populated by `load_policy`). Used ONLY for the interpreter
# inline-eval deny check above: an eval string's write target lives inside a
# quoted argument, not a bare token, so it cannot be resolved/normalized as
# a path the way `classify_target` does for a real operand - a coarse
# substring scan over the whole clause is the safe-direction fallback.
# ACCEPTED residual (documented, not fixed): a target path built by STRING
# CONCATENATION inside the eval (e.g. `'scripts/' + 'hooks/' + 'x.sh'`, or
# `os.path.join('scripts','hooks','x.sh')`) never appears as a literal
# substring and is not caught here - the same class of "not statically
# parseable" gap as `git apply`/`patch`'s diff-body target and `find
# -exec`/`xargs`'s deferred arguments, called out in the header's ACCEPTED
# section.
# Judge J1298A C1 (Critical, NEW ALLOW vs main): checking the NORMALIZED
# text alone is lossy - the `seg/../` collapse in `_normalize_scan_text`
# deletes a policy signal that the raw text still carries verbatim (e.g.
# `scripts/hooks/../` collapses to `scripts/`, erasing the `scripts/hooks/`
# substring), while runtime string-slicing/parameter-expansion
# (`${x%../}a.sh`, `d[:14]+'a.sh'`) reconstructs the real write target from
# exactly that raw text. Fix: scan is a UNION, never a replacement - deny if
# either the raw text (main's original check, unchanged) OR the normalized
# text matches a policy value. Normalization can then only ADD denies
# (catching `//`/`/./ ` spelling variants) and never remove one.
# Judge J1298D C1 (Critical, main DENY -> effective head ALLOW via timeout):
# the union above used to compute norm_lc UNCONDITIONALLY, before ever
# trying the raw match, and `_normalize_scan_text`'s `seg/../` collapse is
# quadratic in the number of `/../` hops (scratch/timing.sh: ~13.4s at
# 16000 hops, ~19.5-20.5s at 20000, vs ~100ms on main) - past this fence's
# 15s PreToolUse hook timeout, which fails OPEN (a timed-out command hook
# does not block the tool call). A deny-worthy clause padded with enough
# `a/../` hops could outrun the clock and run unblocked. Fix: (1) try the
# raw match first and return immediately on a hit, so a clause main already
# denies via raw text never reaches normalization at all; (2) bound
# normalization itself - a clause whose raw text is longer than
# MAX_NORMALIZE_LEN skips normalization and denies outright (fail CLOSED),
# since every caller of this function (procsub, env/sudo wrapper,
# inline-eval - `process_clause_for_write`) has already decided the clause
# is one of the unanalysable shapes this scan exists to catch in the first
# place, so treating "too long to normalize safely" the same as "found a
# signal" adds no new main-ALLOW->head-DENY risk in the wrong direction.
# MAX_NORMALIZE_LEN=4096 keeps the worst case (~800 `/../` hops) at roughly
# 100ms per scratch/timing.sh's N=1000 row, far under the timeout, while a
# genuine attack clause (tens of KB) is denied in O(1) before the quadratic
# loop ever runs.
MAX_NORMALIZE_LEN=4096
_clause_has_enforcement_signal() {
    local raw="$1" raw_lc norm_lc
    raw_lc="$(_lc "$raw")"
    local i v_lc
    i=0
    while [ "$i" -lt "$ENTRY_COUNT" ]; do
        v_lc="${ENTRY_VALUE_LC[$i]}"
        case "$raw_lc" in
            *"$v_lc"*) return 0 ;;
        esac
        i=$((i+1))
    done
    if [ "${#raw}" -gt "$MAX_NORMALIZE_LEN" ]; then
        return 0
    fi
    norm_lc="$(_lc "$(_normalize_scan_text "$raw")")"
    i=0
    while [ "$i" -lt "$ENTRY_COUNT" ]; do
        v_lc="${ENTRY_VALUE_LC[$i]}"
        case "$norm_lc" in
            *"$v_lc"*) return 0 ;;
        esac
        i=$((i+1))
    done
    return 1
}

# _deny_inline_eval <raw-clause-text> -> denies (exit 2): an interpreter
# inline-eval clause (`python -c`/`node -e`/`bash -c`/`pwsh -Command`/...)
# whose eval string names an enforcement-path signal.
_deny_inline_eval() {
    deny "interpreter inline-eval write refused: the clause names an enforcement-path signal (guardrails/hooks/settings/pre-commit/gitleaks/codex/backends/lessons/CLAUDE.md/AGENTS.md/hooks.json/parity_guard.py/glm-guard.ts/phi-egress-guard.ts). This surface is propose-only: file a ticket or describe the change in a draft-PR body; enforcement-path edits are operator-lane. clause=$1"
}

# _clause_has_procsub <tok...> -> 0 iff any token in the clause contains a
# bare `>(` or `<(` - a process-substitution opener. Round 7 (see the `PLUS`
# section after `4.`'s git hook-routing shape-deny, header): a
# proven-read-only OUTER verb (`echo`/`cat`/`diff`/...) previously let a
# writer hidden inside `>(...)` slip through, because the read-only
# short-circuit (`4.c`) returns allow before any operand - including the
# procsub token - is ever inspected, and the redirect scan (`4.a`) only
# classifies the token immediately after `>`/`<`, which is the procsub
# opener itself, not the writer buried inside it. This is a coarse SHAPE
# check only (a token containing the two-character substring), not a parse
# of the substituted command - `process_clause_for_write` pairs a hit here
# with `_clause_has_enforcement_signal` over the clause's raw text.
_clause_has_procsub() {
    local t
    for t in "$@"; do
        case "$t" in
            *'>('*|*'<('*) return 0 ;;
        esac
    done
    return 1
}

# _deny_procsub <raw-clause-text> -> denies (exit 2): a process-substitution
# clause (`>(...)`/`<(...)`) whose raw text names an enforcement-path
# signal.
_deny_procsub() {
    deny "process-substitution write refused: the clause names an enforcement-path signal (guardrails/hooks/settings/pre-commit/gitleaks/codex/backends/lessons/CLAUDE.md/AGENTS.md/hooks.json/parity_guard.py/glm-guard.ts/phi-egress-guard.ts). This surface is propose-only: file a ticket or describe the change in a draft-PR body; enforcement-path edits are operator-lane. clause=$1"
}

# _deny_env_split_string <raw-clause-text> -> denies (exit 2), UNCONDITIONALLY,
# any clause where `_env_split_string_used` fires - no enforcement-path-signal
# match required. /pr-check critic panel (codex-1, this round): `-S`'s value is
# CODE env itself word-splits and executes, not a clean operand - when that
# value lands as a SINGLE token (a quoted argument, e.g. `env -S 'cp y a.sh'`),
# `_clause_head_idx`'s old value-skip treatment of `-S` consumed the whole
# thing as one opaque "value" and left NOTHING for `_operand_targets` to scan,
# so a cwd-relative or textually-signal-free write ALLOWed outright - the
# raw-text scan this branch used to gate on cannot see a cwd-relative target
# either, so gating the deny on it left exactly that gap open. Per console
# ruling (three rounds of patching this same parser found a Critical each
# time): treat ANY genuine `env -S`/`--split-string` use as UNANALYSABLE and
# fail closed, full stop - `_clause_head_idx` no longer tries to skip past
# `-S`'s value at all (see the `env)` arm above), and this deny no longer
# requires a policy-signal match. A benign `env -S 'echo hi'` now denies too;
# that trade-off is accepted (env -S is rare in agent commands, and failing
# closed on an unanalysable wrapper is this fence's house style already -
# see `_deny_inline_eval`/`_deny_procsub`/`_deny_wrapper_enforcement_signal`).
_deny_env_split_string() {
    deny "env -S/--split-string write refused: env's split-string value hides the real command from the lesson-write fence - it is a shell-like command line env parses and executes itself, not a plain operand this fence can classify. Run the wrapped command directly instead of through env -S/--split-string. clause=$1"
}

# _lc_all <tok...> -> sets the global array LC_TOK to the case-lowered form
# of each token, in ONE fork total no matter how many tokens - J1298F C1
# (Critical): `_env_split_string_used`/`_wrapper_is_env_or_sudo` used to fork
# `_lc`+`_strip_wrap` (a `$(...)` subshell each, `_lc` forking `tr` on top)
# for EVERY token of EVERY clause, so a single padded clause (K tokens)
# forked ~2-3x K processes, outrunning the 15s hook budget on inputs main
# denied in seconds (the between-clause `MAX_EVAL_SECONDS` check cannot reach
# inside a clause). Newline is a safe batch separator here: clause tokens
# always arrive whitespace-free (`evaluate_command`'s `set -- $clause`
# IFS-word-splits them, which forbids an embedded newline in any one token),
# so this can never miscount tokens against attacker-controlled input.
# `process_clause_for_write` calls this ONCE per clause; the two functions
# below then index LC_TOK instead of forking per token.
_lc_all() {
    LC_TOK=()
    [ "$#" -gt 0 ] || return 0
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        LC_TOK+=("$line")
    done <<< "$(printf '%s\n' "$@" | tr '[:upper:]' '[:lower:]')"
}

# _env_split_string_used <tok...> -> 0 iff some token's basename is `env`
# (bare `env` or a path ending in `/env`, e.g. `/usr/bin/env`) and any LATER
# token anywhere in the clause is a short-option cluster containing `S`
# (`-S`, glued `-Stee...`, bundled `-uS`/`-iS'...'` - GNU env accepts all
# these spellings identically) or a long-option abbreviation of
# `--split-string`. Console ruling (pr-check round 4, codex-1 Critical):
# the prior version walked only tok[0..head_idx-1], the wrapper-prefix range
# `_clause_head_idx` resolves - for a NESTED wrapper (`env env -S '...'`)
# that walk resolves the FIRST `env`'s option region and treats the SECOND
# `env` token as the already-resolved verb, so the real `-S` sitting past it
# was never inspected and the clause fell through to `_operand_targets`
# unguarded. Fourth Critical in a row against hop/walk-based detection of
# this flag (J1298A -> J1298B -> pr-check-round-3's codex-1 -> this one) -
# per ruling, this is no longer a wrapper walk at all: it is a flat,
# unconditional scan of every token in the clause, with no head_idx bound,
# no hop count and no per-option value-skip logic (dropping the old
# `-a`/`-u`/`-C` value-skip and `--unset`/`--chdir`/`--argv0` handling
# entirely - there is nothing left to skip past when the scan does not care
# which option position anything occupies). Accepted false-denies (Minor,
# pinned in tests): a later, unrelated flag on a DIFFERENT verb in the same
# clause that happens to spell an `-S`-shaped token (e.g. `env FOO=bar grep
# -S x`) now also denies, coarser than the walk it replaces - accepted for
# the same reason `_deny_env_split_string`'s own trade-off note gives.
# J1298F C1 (Critical, TIMING-VERIFIED: main DENY -> effective head ALLOW via
# a >15s hook timeout): this used to fork `_strip_wrap`+`_lc` (a `$(...)`
# subshell each, `_lc` forking `tr` on top of that) for EVERY token, and the
# whole-command deadline (`MAX_EVAL_SECONDS`, below `evaluate_command`) only
# checks BETWEEN clauses - so a single padded clause (K tokens, no wrapper
# needed at all: this runs unconditionally on every clause) forked ~2-3x K
# processes with the deadline never able to reach it. Now reads the global
# `LC_TOK` array `_lc_all` (see its own comment) computed ONCE per clause by
# the caller - zero forks in this loop - and checks the deadline itself every
# iteration ($SECONDS is a bash builtin, no fork), so an oversized single
# clause fails closed instead of outrunning the between-clause check.
_env_split_string_used() {
    local -a t=("$@")
    local n=${#t[@]} i=0 s w seen_env=0
    while [ "$i" -lt "$n" ]; do
        s="${t[$i]}"
        s="${s%\"}"; s="${s#\"}"; s="${s%\'}"; s="${s#\'}"; s="${s%\`}"; s="${s#\`}"
        w="${LC_TOK[$i]}"
        w="${w%\"}"; w="${w#\"}"; w="${w%\'}"; w="${w#\'}"; w="${w%\`}"; w="${w#\`}"
        if [ "$seen_env" = 1 ]; then
            case "$s" in
                -*S*) return 0 ;;
            esac
            case "$w" in
                --split-string|--split-string=*) return 0 ;;
                --*) guard_is_long_abbrev "split-string" "$w" && return 0 ;;
            esac
        fi
        case "$w" in
            env|*/env) seen_env=1 ;;
        esac
        if [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ]; then
            deny "command evaluation exceeded the fail-closed time budget (${MAX_EVAL_SECONDS}s); denying the remainder outright (fail-closed)"
        fi
        i=$((i+1))
    done
    return 1
}

# _deny_wrapper_enforcement_signal <raw-clause-text> -> denies (exit 2): an
# env/sudo-headed clause whose raw text names an enforcement-path signal. Same
# rationale as `_deny_env_split_string`/`_deny_procsub`/`_deny_inline_eval`.
_deny_wrapper_enforcement_signal() {
    deny "env/sudo-wrapped write refused: the clause names an enforcement-path signal (guardrails/hooks/settings/pre-commit/gitleaks/codex/backends/lessons/CLAUDE.md/AGENTS.md/hooks.json/parity_guard.py/glm-guard.ts/phi-egress-guard.ts). This surface is propose-only: file a ticket or describe the change in a draft-PR body; enforcement-path edits are operator-lane. clause=$1"
}

# _wrapper_is_env_or_sudo <head_idx> <tok...> -> 0 iff any token in
# tok[0..head_idx-1] (the wrapper-prefix range `_clause_head_idx` walks) is,
# once stripped and lowered, exactly `env` or `sudo`.
# Judge J1298R (Critical, ruling item 1): every prior fix in this file
# (round after round of HIMMEL-2610/HIMMEL-3632/HIMMEL-3658/HIMMEL-3659/
# J1298O) patched `_clause_head_idx`'s env/sudo option-cluster walk to
# resolve one more bundled/glued/case-folded shape correctly - a losing
# enumeration game, since a NEW option-cluster shape (N2: `-Sp`/`-Np`/`-Su`/
# `-SD`/`-NC`; N3: glued bundled `-iS'...'`) always resolves the walk to
# *some* verb, correct or not, and the option tables must never grow again
# (ruling item 2). This check does not try to resolve the wrapper's options
# at all: it fires on the mere PRESENCE of `env`/`sudo` anywhere in the
# wrapper range, independent of whether the cluster walk parsed the rest
# correctly, and pairs with `_clause_has_enforcement_signal`'s raw-text scan
# below exactly like `_env_split_string_used` does - no parse result can
# turn a hit here into an ALLOW. Accepted cost (ruling item 1, pinned in
# tests): a READ through env/sudo of a path matching a policy signal (e.g.
# `sudo cat scripts/hooks/a.sh`) now DENIES even though `cat` is proven
# read-only and the cluster walk resolves it correctly - stricter than main,
# deliberately. A false-positive match (some OTHER wrapper's own option
# VALUE token happens to spell "sudo" or "env" literally, e.g. `sudo -u
# sudo cat ...`) only routes the clause to the raw-text scan unnecessarily -
# never a new gap, the same false-positive-is-safe reasoning already used
# for `_env_split_string_used` above.
# J1298F C1: same fork-elimination and in-loop deadline as
# `_env_split_string_used` above (see its comment) - reads global `LC_TOK`
# instead of forking `_lc`/`_strip_wrap` per token.
_wrapper_is_env_or_sudo() {
    local head_idx="$1"; shift
    local -a t=("$@")
    local n=${#t[@]} i=0 w
    [ "$head_idx" -le "$n" ] || head_idx="$n"
    while [ "$i" -lt "$head_idx" ]; do
        w="${LC_TOK[$i]}"
        w="${w%\"}"; w="${w#\"}"; w="${w%\'}"; w="${w#\'}"; w="${w%\`}"; w="${w#\`}"
        case "$w" in
            env|sudo) return 0 ;;
        esac
        if [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ]; then
            deny "command evaluation exceeded the fail-closed time budget (${MAX_EVAL_SECONDS}s); denying the remainder outright (fail-closed)"
        fi
        i=$((i+1))
    done
    return 1
}

# _verb_is_read_only <verb_lc> <verb-onward-tok...> -> 0 iff the
# command-position verb is on the round-4 PROVEN-READ-ONLY allow-list (see
# the `4.` header section for the full list + rationale per entry) - the
# INVERSION at the center of this fence's Bash/PowerShell model: everything
# NOT on this list is a potential writer, so its operands get checked
# (`_operand_targets`) instead of enumerating every writer verb by name.
# Three entries are clause-conditional rather than static membership: `sed`
# (exempt unless `-i`/`-i<suffix>` is present - `sed` without `-i` never
# writes its input file), `find` (exempt unless `-delete`/`-exec`/
# `-execdir` is present - those turn a pure traversal into a mutator), and
# `git` (delegated to _git_is_read_only, above). The interpreters
# (`node`/`python`/`python3`/`bash`/`sh`/`pwsh`/`bun`/`deno`) are NOT static
# members of this function's allow-list as of round 5 (codex-adv-1) - they
# are clause-conditional too, via `_interpreter_is_read_only`, because a
# bare binary membership test cannot tell "executing a script FILE" (a
# read) apart from "evaluating an inline string" (which can write via a
# target hidden inside a quoted argument, invisible to operand scanning).
# `process_clause_for_write` calls `_interpreter_is_read_only` directly for
# these verbs before ever reaching this function, so it is never invoked
# for them in practice; the exemption logic still lives with its siblings
# (`_git_is_read_only`, the inline `sed`/`find` checks) rather than folded
# into this function's own case statement, since its outcome (deny vs
# allow) isn't a plain exempt/not-exempt binary - see the header's `4.c`.
_verb_is_read_only() {
    local verb="$1"; shift
    local -a tok=("$@")
    local n=${#tok[@]} i t_lc

    case "$verb" in
        cat|bat|tac|nl|less|more|head|tail|grep|egrep|fgrep|rg|ripgrep|ag|ls|dir|tree|wc|diff|cmp|comm|stat|file|md5sum|sha1sum|sha256sum|shasum|cksum|awk|cut|sort|uniq|od|xxd|hexdump|column|jq|yq|echo|printf|true|:|test|\[|get-content|gc|type|get-childitem|gci|select-string|sls|measure-object|write-output|write-host|format-*)
            return 0 ;;
        sed)
            i=0
            while [ "$i" -lt "$n" ]; do
                case "${tok[$i]}" in -i|-i.*|-i[a-zA-Z0-9]*) return 1 ;; esac
                i=$((i+1))
            done
            return 0 ;;
        find)
            i=0
            while [ "$i" -lt "$n" ]; do
                t_lc="$(_lc "${tok[$i]}")"
                case "$t_lc" in -delete|-exec|-execdir) return 1 ;; esac
                i=$((i+1))
            done
            return 0 ;;
        git)
            _git_is_read_only "${tok[@]}" && return 0
            return 1 ;;
        *)
            return 1 ;;
    esac
}

# _operand_targets <start-idx> <cwd> <tok...> -> classifies every operand of
# a NON-exempt (potential-writer) clause from <start-idx> onward - the
# round-4 replacement for the old per-verb classify_all_after/
# classify_last_after/classify_target_dir_flag/classify_ps_writer/
# classify_ps_content_writer quartet: since the verb itself already failed
# the read-only check, EVERY operand it touches is a write-target
# candidate, scanned uniformly instead of re-deriving which argument
# positions a given verb writes to. Skips any index already consumed by
# _scan_redirects (REDIR_SKIP). A plain non-dash token is a candidate as-is
# (bare words included, no is_path_like gate - unchanged from round 2/3). A
# dash-prefixed token contributes its INLINE value only, via two forms: the
# PowerShell/long-option `-Path:X`/`-Path=X`/`--target-directory=X`
# convention (`_ps_inline_value`), and the cp/install GLUED short flag
# `-tDIR` (no separator at all - GNU cp/install's own grammar, kept from
# round 2/12 alongside the SPACE form `-t DIR`, which needs no special
# handling here because the un-dashed value token gets classified on its own
# next iteration regardless of which flag preceded it). `-Value`/
# `-Value:x`/`-Value=x` (case-insensitive, space form skips the following
# value token too) are skipped outright everywhere, not just for the three
# named PowerShell content-writer cmdlets (round-3b's fix, generalized):
# that parameter name conventionally holds literal CONTENT being written,
# not a target, and misreading it denies a perfectly safe write whose real
# target is some other non-enforcement file.
_operand_targets() {
    local start="$1" cwd="$2"; shift 2
    local -a tok=("$@")
    local n=${#tok[@]} i="$start" t t_lc val
    while [ "$i" -lt "$n" ]; do
        if [ -z "${REDIR_SKIP[$i]:-}" ]; then
            t="${tok[$i]}"
            t_lc="$(_lc "$t")"
            case "$t_lc" in
                -value)             i=$((i+2)); continue ;;
                -value:*|-value=*)  i=$((i+1)); continue ;;
            esac
            case "$t" in
                -t[!:=]*)
                    _check_target "${t#-t}" "$cwd" ;;
                -*)
                    val="$(_ps_inline_value "$t")"
                    [ -n "$val" ] && _check_target "$val" "$cwd" ;;
                *)
                    _check_target "$t" "$cwd" ;;
            esac
        fi
        i=$((i+1))
    done
}

# process_clause_for_write <cwd> <clause-raw> <tok...> -> the round-4
# INVERTED Bash/PowerShell classifier for one already-split clause. See the
# `4.` header section for the full model; in short: (1) redirect/`of=`
# targets always deny, verb-independent (_scan_redirects); (1b) round 7 - if
# ANY token carries a process-substitution opener (`>(`/`<(`), the coarse
# `_clause_has_enforcement_signal` scan runs over the raw clause text and
# denies on a hit, UNCONDITIONALLY, before the verb is even resolved - this
# must run before step (4)'s read-only-verb short-circuit, since that is
# exactly the shape that let a writer hidden inside `>(...)` slip past a
# proven-read-only outer verb (`echo`/`cat`); (2) resolve the command-position
# verb, after wrapper stripping (_clause_head_idx); (2a) J1298R - if the
# wrapper-prefix range names `env`/`sudo` at all, ANYWHERE, the same
# `_clause_has_enforcement_signal` raw-text scan runs and denies on a hit,
# UNCONDITIONALLY, regardless of whether the option-cluster walk resolved
# the rest of the wrapper correctly (_wrapper_is_env_or_sudo) - a miss falls
# through unchanged; (2b) console-authorized redesign (three straight rounds
# of Criticals against this same `env -S` parser) - if the wrapper-prefix
# range names env's OWN `-S`/`--split-string` at all, in ANY spelling
# (`_env_split_string_used`), this denies UNCONDITIONALLY and unguarded by any
# raw-text signal match, before the resolved "verb" (which would be `-S`'s
# value, not a real command) is ever checked: `-S`'s value is a shell-like
# command line env itself word-splits and executes, not a clean operand this
# fence can classify, so it is treated as categorically unanalysable rather
# than re-parsed - the accepted trade-off is that a benign `env -S 'echo hi'`
# now denies too (env -S is rare in agent commands, and failing closed on an
# unanalysable wrapper is this fence's house style already, same as
# `_deny_procsub`/`_deny_inline_eval` above); (3)
# if that verb is an interpreter, delegate to `_interpreter_is_read_only` +
# `_clause_has_enforcement_signal` (round 5 - see those functions); (4) if
# that verb is otherwise proven read-only, allow outright - its operands are
# reads; (5) otherwise scan every operand as a write-target candidate
# (_operand_targets). <clause-raw> is the clause's own pre-tokenization text
# (round 5 addition), needed by steps (1b), (2a), (2b) and (3) - a
# process-substitution, split-string or inline-eval writer's target is not a
# clean token, so those steps scan the raw text instead of the split
# <tok...> array.
process_clause_for_write() {
    local cwd="$1" clause_raw="$2"; shift 2
    local -a tok=("$@")
    local n=${#tok[@]}
    [ "$n" -gt 0 ] || return 0

    _scan_redirects "$cwd" "${tok[@]}"

    if _clause_has_procsub "${tok[@]}"; then
        _clause_has_enforcement_signal "$clause_raw" && _deny_procsub "$clause_raw"
        return 0
    fi

    # J1298F C1: lower every token ONCE per clause (one fork total via
    # _lc_all), not once per token per check below - see _lc_all's comment.
    _lc_all "${tok[@]}"

    local head_idx; head_idx="$(_clause_head_idx "${tok[@]}")"

    # J1298R ruling item 1: this check is UNCONDITIONAL - it runs whether or
    # not the option-cluster walk above resolved the wrapper correctly, and a
    # miss falls through unchanged to the existing checks below (ruling item
    # 2: the parser stays an ADDITIONAL deny path, never grown further).
    if _wrapper_is_env_or_sudo "$head_idx" "${tok[@]}"; then
        _clause_has_enforcement_signal "$clause_raw" && _deny_wrapper_enforcement_signal "$clause_raw"
    fi

    # Console-authorized redesign (pr-check round 3, codex-1 Critical; round 4,
    # codex-1 Critical on the nested-wrapper gap): a genuine `env -S`/
    # `--split-string` clause denies UNCONDITIONALLY here, not gated on
    # `_clause_has_enforcement_signal`'s raw-text scan and not bounded by
    # `head_idx`/the wrapper walk - `_env_split_string_used` now scans every
    # token in the clause flatly, so a nested wrapper (`env env -S '...'`)
    # cannot place the flag outside the range this check inspects. Treat the
    # whole clause as unanalysable and stop here.
    if _env_split_string_used "${tok[@]}"; then
        _deny_env_split_string "$clause_raw"
    fi

    [ "$head_idx" -lt "$n" ] || return 0

    local -a vtok=()
    local i="$head_idx"
    while [ "$i" -lt "$n" ]; do
        vtok+=("${tok[$i]}")
        i=$((i+1))
    done
    local verb_lc; verb_lc="$(_lc "$(_strip_wrap "${vtok[0]}")")"

    case "$verb_lc" in
        node|bun|deno|python|python3|bash|sh|pwsh)
            _interpreter_is_read_only "$verb_lc" "${vtok[@]}" && return 0
            _clause_has_enforcement_signal "$clause_raw" && _deny_inline_eval "$clause_raw"
            return 0
            ;;
    esac

    _verb_is_read_only "$verb_lc" "${vtok[@]}" && return 0

    _operand_targets $((head_idx+1)) "$cwd" "${tok[@]}"
    return 0
}

# _check_git_hook_routing <clause> -> denies (exit 2) iff the clause's
# command-position token is git/git.exe AND it carries a hook-routing
# config key - `core.hooksPath` (bare `git config core.hooksPath X`, `git
# config --unset core.hooksPath`, or attached `git -c core.hooksPath=X
# <anything>`, the one-shot override) OR `include.path`/`includeif.*`
# (same three forms; an included config file can itself set
# core.hooksPath, so it is the same class of bypass). A real
# `--get`/`--get-all` token anywhere in the clause is a read carve-out and
# is allowed. (Named `_check_git_hook_routing`, not `..._hookspath`, now
# that it covers include-based routing too.) Every token is passed through
# `_strip_wrap` before matching (round-3b CR fix): the tokeniser is
# quote-naive, so a quoted key - `git -c 'core.hooksPath=X' commit` or
# `git config "core.hooksPath" X` - arrives as a single token still
# carrying its surrounding quote chars; without stripping them first the
# case match against the bare key never fires. Applies to the
# `--get`/`--get-all` carve-out check too, for the same reason. Round-5 CR
# fix (codex-adv-2): the git-identification step now resolves the clause
# HEAD via `_clause_head_idx` (the same wrapper-skipping walk
# `process_clause_for_write` uses) instead of checking `tok[0]` directly, so
# `command git -c core.hooksPath=X commit`, `env git config --add
# include.path X`, `sudo git ...`, and `timeout 9 git ...` are still
# recognized as git clauses instead of bypassing this check entirely because
# the wrapper token sat in position 0. The key/`--get` scan itself now also
# starts from the git token onward (not from index 0), so a coincidental
# wrapper flag can never masquerade as the routing key or the `--get`
# carve-out.
_check_git_hook_routing() {
    local clause="$1"
    local -a tok
    # shellcheck disable=SC2086 # intentional word split for tokenisation
    set -- $clause
    tok=("$@")
    local n=${#tok[@]}
    [ "$n" -gt 0 ] || return 0

    # J1298F-followup (codex-1): this runs unconditionally on every clause,
    # BEFORE process_clause_for_write's own `_lc_all` call - populate LC_TOK
    # here too (one fork total for this call, not per-token) so both
    # `_clause_head_idx` and the per-token loop below stay fork-free and
    # deadline-checked in the real process (this function is never itself
    # invoked via `$(...)`, so `deny` here works).
    _lc_all "${tok[@]}"
    local head_idx; head_idx="$(_clause_head_idx "${tok[@]}")"
    if [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ]; then
        deny "command evaluation exceeded the fail-closed time budget (${MAX_EVAL_SECONDS}s); denying the remainder outright (fail-closed)"
    fi
    [ "$head_idx" -lt "$n" ] || return 0

    case "$(_lc "$(_strip_wrap "${tok[$head_idx]}")")" in
        git|git.exe|*/git|*/git.exe) : ;;
        *) return 0 ;;
    esac

    local i="$head_idx" t_lc has_routing=0 has_get=0
    while [ "$i" -lt "$n" ]; do
        if [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ]; then
            deny "command evaluation exceeded the fail-closed time budget (${MAX_EVAL_SECONDS}s); denying the remainder outright (fail-closed)"
        fi
        t_lc="${LC_TOK[$i]}"
        t_lc="${t_lc%\"}"; t_lc="${t_lc#\"}"; t_lc="${t_lc%\'}"; t_lc="${t_lc#\'}"; t_lc="${t_lc%\`}"; t_lc="${t_lc#\`}"
        case "$t_lc" in
            core.hookspath|core.hookspath=*) has_routing=1 ;;
            include.path|include.path=*)     has_routing=1 ;;
            includeif|includeif.*)           has_routing=1 ;;
            --get|--get-all)                 has_get=1 ;;
        esac
        i=$((i+1))
    done
    [ "$has_routing" = 1 ] || return 0
    [ "$has_get" = 1 ] && return 0

    deny "git hook-routing config (core.hooksPath/include.path/includeif) can disable or reroute every pre-commit/pre-push gate (fail-closed): $clause"
}

# evaluate_command <command-string> <cwd> -> split into clauses on ; | & and
# newline (over-splitting is safe: classification only ever tightens toward
# deny on a spurious extra token, never loosens); evaluate each clause.
# Round-6 CR fix: `>|` (noclobber-override write) and `>&` (redirect both
# streams to a FILE) each carry a `;|&` split metachar as their SECOND
# character, so splitting on that metachar first stranded the `>` at the end
# of clause 1 (no target, since the target sat on the far side of the split)
# and made the redirect's TARGET look like the HEAD/verb of clause 2 - a
# position `_operand_targets` never scans for that clause (it only scans
# operands AFTER the verb) - so the redirect target went unclassified
# (`echo x >| scripts/hooks/a.sh` / `echo x >& scripts/hooks/a.sh` both
# allowed). Normalizing these two operators to a plain `> ` BEFORE the
# `;|&` split keeps the target attached to a `>` in the SAME clause, so
# `_scan_redirects` classifies it exactly like any other `>` redirect.
# Order matters: this must run before the `|`/`&` substitutions below. A
# real fd-dup (`2>&1`, `>&2`) is unaffected in the safe direction: `2>&1`
# becomes `2> 1` and `>&2` becomes `> 2`, whose "targets" (`1`/`2`) are
# non-enforcement paths and still allow. `&>|`/`&>>` (all three metachars)
# reduce to the existing `&>` handling: `&>|` -> `&> ` after this step, then
# the `&` split below produces the same clause shape `&>` already denies.
#
# Judge J1298E C1 (Critical, main DENY -> effective head ALLOW via timeout):
# the per-entry-fork fix above (`ENTRY_VALUE_LC`) removes the QUADRATIC-ish
# blowup for a large ENTRY_COUNT, but the per-clause scan cost (still real,
# still nonzero: option-cluster walks, wrapper/verb classification, operand
# scans) is multiplied by the NUMBER of clauses a padded command can carry
# (`sudo true x; ` xK), and that product is unbounded by anything in this
# loop - main pays the same per-clause cost via its own inline-eval scan, so
# this is a pre-existing class this fence widens, not a new one (per the
# judge's own timing table). A whole-command wall-clock deadline closes
# BOTH: any command whose clause-by-clause evaluation is still running past
# MAX_EVAL_SECONDS is denied outright, fail-closed, well under this fence's
# 15s PreToolUse hook timeout (which fails OPEN on a real timeout) - a
# padded command that would otherwise race the clock now loses the race on
# the safe side. `$SECONDS` is a bash builtin (no fork), reset to 0 at
# process start, so reading it here costs nothing extra per clause.
MAX_EVAL_SECONDS=8
evaluate_command() {
    local cmd="$1" cwd="$2" tmp clause
    # J1298F M2: bash IMPORTS $SECONDS from the environment (`env
    # SECONDS=-100000 bash -c 'echo $SECONDS'` prints -100000), so a caller
    # that exports SECONDS before invoking this hook could otherwise stall
    # the deadline arbitrarily. Reset it here, unconditionally, so the
    # budget always counts from this function's own start.
    SECONDS=0
    tmp="$cmd"
    tmp="${tmp//>|/> }"
    tmp="${tmp//>&/> }"
    tmp="${tmp//;/$'\n'}"
    tmp="${tmp//|/$'\n'}"
    tmp="${tmp//&/$'\n'}"
    while IFS= read -r clause || [ -n "$clause" ]; do
        [ -n "$clause" ] || continue
        if [ "$SECONDS" -ge "$MAX_EVAL_SECONDS" ]; then
            deny "command evaluation exceeded the fail-closed time budget (${MAX_EVAL_SECONDS}s); denying the remainder outright (fail-closed)"
        fi
        _check_git_hook_routing "$clause"
        # shellcheck disable=SC2086 # intentional word split for tokenisation
        set -- $clause
        [ "$#" -gt 0 ] || continue
        process_clause_for_write "$cwd" "$clause" "$@"
    done <<< "$tmp"
}

# --- mode dispatch -----------------------------------------------------------

if [ "${1:-}" = "check" ]; then
    trap _on_exit EXIT
    _init_paths
    shift
    [ "$#" -gt 0 ] || deny "check mode requires at least one path argument"
    load_policy
    any_deny=0
    for p in "$@"; do
        if classify_target "$p" "$PWD"; then
            printf 'deny\t%s\t%s\n' "$_MATCH_CLASS" "$p"
            any_deny=1
        else
            printf 'allow\t-\t%s\n' "$p"
        fi
    done
    if [ "$any_deny" = 1 ]; then exit 2; fi
    exit 0
fi

# hook mode: inert unless the lesson loop is active.
if [ "${HIMMEL_LESSON_LOOP:-0}" != "1" ]; then
    exit 0
fi

trap _on_exit EXIT
_init_paths
_require_jq

input="$(cat)"
if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
    deny "malformed JSON payload on stdin (fail-closed)"
fi

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"

case "$tool_name" in
    Edit|Write|NotebookEdit|MultiEdit)
        load_policy
        cwd="$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null)"
        [ -n "$cwd" ] || cwd="$PWD"
        fp="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
        np="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // empty' 2>/dev/null)"
        for p in "$fp" "$np"; do
            [ -n "$p" ] || continue
            if classify_target "$p" "$cwd"; then
                _deny_enforcement "$p"
            fi
        done
        exit 0
        ;;
    apply_patch)
        # Codex's create/edit envelope (HIMMEL-2170): no tool_input.file_path
        # at all — every target lives inside "*** Add/Update/Delete File:"
        # lines in tool_input.command instead (see harness-compat.md's
        # empirical event/tool-name matrix). Extract every such target and
        # classify EACH one through the SAME classify_target used above; any
        # fenced target denies the whole call. Unlike the Edit/Write branch
        # (which silently skips an empty file_path), a command from which NO
        # target can be extracted at all is treated as malformed and denies
        # under HIMMEL_LESSON_LOOP=1 — fail-closed, matching this fence's own
        # convention for every other unparseable/ambiguous input (malformed
        # JSON on stdin, a missing policy, jq absent, ...; see the header).
        load_policy
        cwd="$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null)"
        [ -n "$cwd" ] || cwd="$PWD"
        cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        targets=""
        _ap_prev=""
        while IFS= read -r ap_line || [ -n "$ap_line" ]; do
            # Strip a trailing CR: on this platform `jq -r` CRLF-converts
            # embedded newlines in its output, and command substitution only
            # strips the FINAL trailing newline group, not internal ones - so
            # a multi-line `cmd` (apply_patch's patch text always is) arrives
            # here with a stray `\r` glued onto every line but the last. An
            # EXACT-match policy entry (`.claude/settings.json`) would
            # silently mismatch on that trailing byte and fail OPEN; a
            # directory-prefix entry happens to be immune (its glob has a
            # trailing `*`), which is what let this hide in this ticket's own
            # multi-target test before the malformed-command target line was
            # checked against an exact-match entry.
            ap_line="${ap_line%$'\r'}"
            case "$ap_line" in
                '*** Add File: '*)    targets="${targets}${ap_line#'*** Add File: '}"$'\n'; _ap_prev="" ;;
                '*** Update File: '*) targets="${targets}${ap_line#'*** Update File: '}"$'\n'; _ap_prev="update" ;;
                '*** Delete File: '*) targets="${targets}${ap_line#'*** Delete File: '}"$'\n'; _ap_prev="" ;;
                # HIMMEL-2170 CR round 1: a rename/move destination. Per the
                # official apply_patch grammar (verified against
                # codex-rs/apply-patch/src/parser.rs,
                # openai/codex@18b9e7fd9e3f6670cc4f300338e44050b2c301e4 -
                # `MOVE_TO_MARKER = "*** Move to: "`, grammar comment
                # `update_hunk: "*** Update File: " filename LF change_move?
                # change?` / `change_move: "*** Move to: " filename LF`),
                # this line is OPTIONAL and immediately follows an
                # `*** Update File:` line. Without this arm, an Update on an
                # ALLOWED source could move it onto a FENCED destination path
                # that is never classified.
                #
                # CodeRabbit round (HIMMEL-2170): the grammar makes Move-to
                # valid ONLY immediately after an Update File line - a
                # standalone/misplaced Move-to (no Update immediately before
                # it) is not a real target at all, it is malformed patch
                # syntax. Treating it as a target anyway let an invalid patch
                # be silently ALLOWED whenever that stray path happened to be
                # non-fenced. `_ap_prev` tracks the immediately-preceding
                # marker; anything other than "update" here routes to the
                # SAME malformed-command deny every other unparseable
                # apply_patch hits (fail-closed, immediate - not merely
                # dropped, so one bad Move-to line denies the whole call even
                # if other lines in the same patch extracted valid targets).
                '*** Move to: '*)
                    [ "$_ap_prev" = "update" ] || \
                        deny "apply_patch Move-to line not immediately preceded by an Update File line (malformed patch text; fail-closed)"
                    targets="${targets}${ap_line#'*** Move to: '}"$'\n'
                    _ap_prev="" ;;
                *) _ap_prev="" ;;
            esac
        done <<< "$cmd"
        [ -n "$(printf '%s' "$targets" | tr -d '[:space:]')" ] || \
            deny "apply_patch command carries no Add/Update/Delete File target (malformed/unparseable patch text; fail-closed)"
        while IFS= read -r p || [ -n "$p" ]; do
            [ -n "$p" ] || continue
            if classify_target "$p" "$cwd"; then
                _deny_enforcement "$p"
            fi
        done <<< "$targets"
        exit 0
        ;;
    Bash|PowerShell)
        load_policy
        cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
        [ -n "$cmd" ] || exit 0
        cwd="$(printf '%s' "$input" | jq -r '.tool_input.cwd // .cwd // empty' 2>/dev/null)"
        [ -n "$cwd" ] || cwd="$PWD"
        evaluate_command "$cmd" "$cwd"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
