#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell.
#
# Deterministic destructive-command floor shared by Claude and Codex lanes
# (HIMMEL-754). Ports the TERMINAL_DESTRUCTIVE command classes from
# scripts/hermes/assets/parity_guard.py: catastrophic/shared-machine/
# irreversible terminal shapes only. Routine git/gh/mv/cp, non-recursive rm,
# curl without remote-exec pipe, and normal git status/commit/push are allowed.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow
#   2 - block; stderr is shown to the model/user
#
# Bypass: set DESTRUCTIVE_OK=1 in the shell that launched the agent. Session-
# sticky; restart without it to re-enable the guard.
set -euo pipefail

# Security hook: any unexpected top-level failure must deny, not fail open as a
# plain rc=1 hook error.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if [ "${DESTRUCTIVE_OK:-0}" = "1" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-destructive-commands: jq not on PATH - refusing to evaluate; install jq" >&2
    exit 2
fi

# HIMMEL-2123: bash builtin `read` instead of `$(cat)` drops one spawn per
# call. The three separate `printf '%s' "$input" | jq ...` pipelines below
# (validate, extract tool_name, extract command — six forks: printf+jq
# each) are collapsed into ONE jq call via `<<<` (no printf fork) that
# validates AND extracts both fields together: a malformed/non-parseable
# payload makes the whole call fail exactly like the old standalone
# `jq -e .` did, so the fail-closed branch is unchanged. Windows jq.exe
# writes CRLF, so the embedded "\n" field separator can arrive as "\r\n" —
# strip the stray CR off $tool (same shape as require-quiet-run.sh,
# HIMMEL-2060, and block-tail-pipe-on-gates.sh).
input=""
IFS= read -r -d '' input 2>/dev/null || true
# HIMMEL-2123 RETASK R2123A: empty/whitespace-only stdin must fail CLOSED,
# same as the old `printf | jq -e .` did on it (jq -e on "" is a parse
# error -> exit 2). `read -d ''` on EOF leaves $input empty with no error
# to catch (`|| true` swallows its own rc), and `jq <<<""` on blank input
# emits zero values with zero errors, so the `if ! result=$(...)` guard
# below never fires -> silent fail-OPEN on a security fence. Catch it here,
# before jq ever runs (no spawn).
case "$input" in
    *[![:space:]]*) ;;
    *) echo "block-destructive-commands: empty/blank stdin - failing closed" >&2; exit 2 ;;
esac
# `if ! result=$(...); then` (not a bare assignment) so a failing jq does not
# trip `set -e` before the fail-closed branch below can run.
#
# The filter reproduces the old two-step semantics in one jq call:
#   * top-level null/false, or genuinely unparsable JSON, both make jq exit
#     non-zero (via `error(...)` for the former, a parse failure for the
#     latter) -- same "malformed/truncated" fail-closed as the old
#     standalone `jq -e .` validation.
#   * anything else (object/array/string/number/true) proceeds to field
#     access; `try ... catch empty` swallows the "cannot index" runtime
#     error a non-object top-level value throws there, same as the old
#     per-field `|| true` fallbacks -- both land on empty tool/cmd, which
#     falls through to allow below exactly as before.
#   * RETASK R2123A (independent review, HIMMEL-2123): a NON-STRING but
#     present `command`/`cmd` (e.g. `"command":["rm -rf /"]`) made jq's `+`
#     a type error ("string and array cannot be added") -- a DIFFERENT
#     failure than "cannot index", still swallowed by the same
#     `catch empty`, silently blanking tool AND cmd and falling through to
#     ALLOW. First fix attempt used `|tostring` on both operands, but that
#     renders arrays/objects as COMPACT json ("["x"]"), while old's
#     `jq -r` rendered them PRETTY-PRINTED across multiple lines -- and
#     those embedded newlines, folded to `;` by cmd_lc below, accidentally
#     created a command-position separator right before the quoted command
#     text that let the destructive-command match still fire. `tostring`
#     does not reproduce that accidental multi-line shape, so it is NOT a
#     reliable substitute (verified: an array command stayed allowed with
#     `tostring`, still blocked on old). Chasing byte-parity with jq's
#     pretty-printer is not worth it for a shape no real harness payload
#     produces (`tool_input.command` is always a string): explicitly ERROR
#     -- and thus fail CLOSED via the same branch below -- when `command`/
#     `cmd` IS present and its type is not "string" or "null". This is
#     MORE conservative than old's incidental behavior, not merely
#     equivalent to it, which is the correct direction for a security
#     fence on an input shape that should never occur.
if ! result=$(jq -r 'if (. == null or . == false) then error("bad-shape") else ((try (.tool_input.command // .tool_input.cmd) catch null) as $c | if ($c != null and ($c|type) != "string") then error("non-string-command") else (((try (.tool_name) catch null) // "" | tostring) + "\n" + ($c // "")) end) end' <<<"$input" 2>/dev/null); then
    echo "block-destructive-commands: malformed/truncated JSON on stdin - failing closed" >&2
    exit 2
fi
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
case "$tool" in
    Bash|PowerShell|"") ;;
    *) exit 0 ;;
esac

[ -z "$cmd" ] && exit 0

# parity_guard.norm() lower-cases before applying TERMINAL_DESTRUCTIVE. Newlines
# separate shell commands, so preserve them as semicolon boundaries. HIMMEL-2123:
# one `tr` call (a single SET1/SET2 char-class mapping covers both the case fold
# and the newline/CR fold) instead of two chained `tr` invocations — same output,
# one fewer fork. `printf` (not `<<<`) is kept deliberately: many patterns below
# anchor on `$` (end-of-string), and a herestring's synthetic trailing newline
# would fold to an extra trailing ';' that a `$`-anchored pattern does not expect.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')

# contains ERE -> true iff $cmd_lc matches ERE.
#
# HIMMEL-1741: this was `printf '%s' "$cmd_lc" | grep -Eq "$1"` — a fork PAIR
# (subshell + grep) per call, and the deny floor below calls it 18 times, so
# every Bash/PowerShell tool call paid 36 process spawns. On Windows with
# Defender real-time scanning a spawn costs ~667 ms (~10x a normal Git-Bash
# spawn), which made this single function ~24 s of the ~66 s PreToolUse chain
# and shrank a 45-minute worker budget to ~20 tool calls.
#
# `[[ =~ ]]` is the same POSIX ERE, evaluated in-process with zero spawns, and
# every pattern below is passed through UNCHANGED. Two invariants make the
# substitution exact:
#   * the pattern MUST be held in a variable and left UNQUOTED on the right of
#     `=~` — a quoted pattern is matched as a literal string in bash >= 3.2;
#   * `cmd_lc` is a single line by construction (the `tr` above folds newlines
#     and CRs to ';'), so grep's line-oriented `^`/`$` and bash's
#     whole-string `^`/`$` mean the same thing here.
# Both forms return 0 match / 1 no-match / 2 bad-pattern, so callers are
# unchanged. Equivalence is pinned per-rule in the paired test suite.
contains() {
    local re="$1"
    [[ $cmd_lc =~ $re ]]
}

deny() {
    echo "block-destructive-commands: destructive command refused ($1)" >&2
    exit 2
}

# Sanctioned CLIProxyAPI proxy lifecycle (HIMMEL-1451): bouncing the proxy
# needs process termination (taskkill / Stop-Process / schtasks /end), all of
# which the deny floor below refuses at command position. The SAFE path is the
# cli-proxy-lane.ps1 -Restart/-Stop verb, which does that termination INTERNALLY
# -- this hook only ever sees the command the agent hands the shell, never a
# script's internals. Permit EXACTLY these literal invocation shapes: a `case`
# on the WHOLE lowercased command with QUOTED (non-glob) alternatives, so the
# match is anchored end-to-end with no wildcards -- a near-miss (a different
# script path, an appended destructive command, or a direct taskkill) does NOT
# inherit a free pass and still hits the deny floor below. powershell and pwsh
# both carry the script (HIMMEL-1432 dual-shell convention). r3 documented the
# combined -Install -Restart [-Force] one-shot pin-roll (.EXAMPLE); r4 added it
# here so the sanctioned forms enumerated below match the documented lifecycle
# (HIMMEL-1451 r4 / glm-4).
#
# codex-1 (CR r4) -- why this carve-out carries NO cwd/repo-root anchor. The
# sanctioned path is RELATIVE, so a roamed shell CWD could in principle resolve
# it to an impostor `scripts/setup/cli-proxy-lane.ps1`. But anchoring THIS
# carve-out cannot close that vector, because the deny floor below INDEPENDENTLY
# allows `powershell/pwsh -NoProfile -File <any relative script>`: no deny rule
# matches (the CMDPOS grammar only arms `-c` as a launcher wrapper, not `-File`,
# and -restart/-stop/-install/-force are not destructive primitives at command
# position). An escaped/impostor relative invocation that does NOT match this
# exact case therefore still passes the floor (rc=0 -- verified empirically: a
# `./`-prefixed path, a `../` escape, and a `cd x; ...` prefix all return rc=0).
# The relative-resolution vector is a FLOOR-LEVEL residual (script-internals
# unseen -- the documented no-general-parser gap, HIMMEL-912 class), not a hole
# this carve-out opens or can close; narrowing the carve-out's text would only
# hide the blessing while the floor keeps allowing the impostor. The carve-out's
# real job is forward-compat stability + explicit blessing of the sanctioned
# shapes (so a future floor rule that DOES match -File/-restart cannot silently
# break the documented lifecycle) -- not gatekeeping the relative path. Closing
# the residual belongs to a HIMMEL-912 floor follow-up, out of scope for r4.
case "$cmd_lc" in
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart -force'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop -force'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart'|\
    'powershell -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -restart -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -stop -force'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart'|\
    'pwsh -noprofile -file scripts/setup/cli-proxy-lane.ps1 -install -restart -force')
        exit 0
        ;;
esac

# Binary boundary helpers are inlined in the patterns below. Every binary atom
# that parity_guard names tolerates an optional .exe suffix for the Windows lane.
# Bare-name atoms (format/schtasks/taskkill/shutdown/icacls classes) anchor to
# COMMAND POSITION - start of command or right after a separator, tolerating
# whitespace, env-var assignment prefixes, and (HIMMEL-851 CR r1) a BOUNDED set
# of launcher wrappers - sudo, env, cmd [/switches] /c, powershell/pwsh
# [-flags] -c/-command - plus
# one optional quote before the atom (a quoted word in command position still
# executes) and (CR r2) a bounded EXECUTABLE-PATH prefix - optional Windows
# drive + path segments ending in "/" or "\" - so /sbin/<name>, ./<name>, and
# drive-qualified <name>.exe forms (quoted or not) are refused like the bare
# name. The exe-path prefix also applies before each WRAPPER token (CR r4),
# so /usr/bin/env <name>, /usr/bin/sudo <name>, and a path-qualified
# cmd.exe /c are refused like the bare-wrapper forms. sudo/env tolerate their
# own flag runs (CR r6: sudo -n, env -i), each flag may optionally consume one
# following non-dash value token (CR r7: sudo -u root, env -u PATH - generic,
# no per-option table; over-consumes at worst one benign token, never a
# bypass), and env also tolerates assignment arguments (env -i foo=bar
# shutdown). The bare word inside an argument
# (git log --pretty=format:, grep -rn format src/, echo shutdown) still does
# not match, and the atoms' trailing boundary keeps format-table-style
# basenames allowed. Deliberately NOT a general shell parser - the RESIDUAL
# documented gap is QUOTED-PAYLOAD wrappers (bash -c "<verb> ...", sh -c,
# xargs / nohup chains), out of scope per the ticket's no-general-parser rule.
# This bounded grammar is intentionally NOT an arms race: further wrapper
# permutations belong to the HIMMEL-912 shared-tokenizer follow-up, and this
# CC-hook + the auto-mode classifier remain the outer defense layers. Mirrors
# parity_guard.py's _CMDPOS_DESTRUCTIVE (shared contract).
# Assignment VALUE is quote-aware (CR r5): FOO='a b' / FOO="a b" would
# otherwise break prefix consumption at the space and drop the verb out of
# command position. Factored into ASSIGN so the env-prefix (CR r6) reuses it.
#
# HIMMEL-1180: EXEPFX/ASSIGN/CMDPOS themselves now live in
# scripts/guardrails/lib.sh's guard_cmdpos_grammar() — shared with
# block-graphify-egress.sh, which anchors its own atom to command position
# with this same wrapper/assignment tolerance instead of a second hand-rolled
# copy. See that function's docstring for the grammar description; this
# file's history above (CR r1-r7) is the derivation record for it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "block-destructive-commands: cannot source guardrails/lib.sh — refusing to evaluate" >&2
    exit 2
fi
guard_cmdpos_grammar
# Separator before the flag tolerates a real space OR a lowercased ${IFS}
# token (a common word-split bypass), and the flag itself tolerates one
# leading quote char - both `-rf` and `"-rf"`/`'-rf'` trip it (HIMMEL-851 U2/U3).
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?([^[:alnum:]_.-][^|;&]*)?([[:space:]]|\$\{ifs\})['\''"]?-[[:alnum:]_]*r'; then
    deny "recursive rm"
fi
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?([^[:alnum:]_.-]|$)[^|;&]*--recursive([^[:alnum:]_-]|$)'; then
    deny "recursive rm"
fi
# Backslash-newline continuation: newlines are already folded to ';' above, so
# `rm \<newline>-rf` becomes `rm \;-rf` here - the literal backslash before the
# folded separator is the tell (HIMMEL-851 U3). `;+` (not a single `;`): on
# Windows, jq's text-mode stdout turns the JSON-decoded `\n` into `\r\n`, so
# ONE real newline folds to TWO semicolons here - tolerate either.
if contains '(^|[^[:alnum:]_.-])rm(\.exe)?[[:space:]]*\\[[:space:]]*;+[[:space:]]*-[[:alnum:]_]*r'; then
    deny "recursive rm (line continuation)"
fi
# /s is bound to the switch (space/another switch/end), not a path prefix -
# `rd /scripts` must not false-trip on the "/s" substring (HIMMEL-851 U1).
if contains '(^|[^[:alnum:]_.-])(del|erase|rd|rmdir)(\.exe)?([^[:alnum:]_.-]|$)[^|;&]*/s([^[:alnum:]_.-]|$)'; then
    deny "recursive Windows delete"
fi
# mkfs keeps no trailing boundary (parity: \bmkfs) so mkfs.ext4 still matches.
if contains "${CMDPOS}"'((format|diskpart|bcdedit)(\.exe)?([^[:alnum:]_.-]|$)|mkfs)'; then
    deny "disk/boot mutation"
fi
if contains '(^|[^[:alnum:]_.-])cipher(\.exe)?[[:space:]]+/w'; then
    deny "disk wipe"
fi
# Verb split (HIMMEL-1141): schtasks /query is read-only (the diagnostic the
# clip-pipe cadence investigation was blocked from running), so only the
# mutating verbs are refused — /query and help/no-verb forms stay allowed.
# Mirrors parity_guard.py's schtasks line (lockstep, HIMMEL-754).
if contains "${CMDPOS}"'schtasks(\.exe)?[[:space:]]+(/create|/change|/delete|/end|/run|/config)([^[:alnum:]_.-]|$)'; then
    deny "scheduled-task mutation"
fi
# HIMMEL-1821: the same CAPABILITY is reachable without schtasks.exe - the
# PowerShell ScheduledTasks module drives the Task Scheduler COM API directly,
# so guarding one spelling guards nothing. Recognise the invoked-program token
# (the HIMMEL-1746 lesson). The HIMMEL-1141 read/write split is preserved by
# omission: get-scheduledtask / get-scheduledtaskinfo / export-scheduledtask
# are NOT in the verb list and stay allowed as diagnostics. The trailing
# boundary keeps the object-BUILDER cmdlets allowed - new-scheduledtask and
# new-scheduledtasktrigger/-action/-principal/-settingsset only construct an
# in-memory definition; the register/set that consumes it is what mutates, and
# that is refused here. `pwsh -Command "Register-ScheduledTask ..."` is covered
# by CMDPOS's powershell/pwsh -c wrapper + optional-quote tolerance, and the
# module-qualified form (`ScheduledTasks\Register-ScheduledTask`) by CMDPOS's
# executable-path prefix - both pinned in the suite (CR r1). The second
# `contains` adds a script-block anchor `{` on top of CMDPOS, so
# `ForEach-Object { Register-ScheduledTask ... }` is refused (CR r8). It is a
# LOCAL widening on purpose: `{` cannot go into the SHARED CMDPOS without
# refusing `jq '{format: .x}'`, but no jq/JSON key is spelled
# `<verb>-scheduledtask`, so here it costs nothing.
# Mirrors parity_guard.py's ScheduledTasks line (lockstep, HIMMEL-754).
SCHEDVERBS='(register|unregister|set|start|stop|disable|enable)-scheduledtask([^[:alnum:]_.-]|$)'
if contains "${CMDPOS}${SCHEDVERBS}" \
    || contains '(^|[{])[[:space:]]*["'\'']?'"${SCHEDVERBS}"; then
    deny "scheduled-task mutation"
fi
# Raw COM route: New-Object -ComObject Schedule.Service. Anchored to the
# -ComObject ARGUMENT rather than command position, because the idiomatic form
# is an assignment (`$svc = New-Object -ComObject Schedule.Service`) that no
# command-position anchor sees. PowerShell resolves unambiguous parameter
# PREFIXES, and New-Object has no other -c* parameter, so `-c` / `-com` /
# `-comobj` all bind to -ComObject: the flag is matched as `-c<word>` rather
# than the full spelling (CR r1). That prefix alone is far too loose, so it is
# scoped to a preceding `new-object` on the SAME command (the separator class
# stops the run at |;&) - otherwise `grep -c Schedule.Service docs/` would be
# denied (CR r2). `new-object` itself takes the usual command-position anchor
# WIDENED by `=`, because the idiomatic PowerShell form is an assignment
# (`$svc = New-Object ...`) that the shared CMDPOS assignment prefix does not
# recognise; that keeps `grep -n "New-Object -ComObject Schedule.Service" f`
# allowed, which someone editing THIS file will type (CR r3). CR r7 tuned both
# ends of that anchor: a quote may NOT sit between the anchor and `new-object`
# (`$s = "New-Object -ComObject Schedule.Service"` is a string assignment, not
# an invocation), while the progid tolerates leading `(`/quotes so the
# parenthesised expression form `-ComObject ('Schedule.Service')` is refused.
#
# RESIDUAL (HIMMEL-1821 CR r3/r4) - these defeat the scheduled-task rules
# exactly as they already defeat every other atom in this file, measured, not
# assumed: `ForEach-Object { schtasks /create ... }`, `ForEach-Object
# { shutdown ... }` and `x=schtasks; $x /create` are all rc=0 today. They are
# the shared no-general-parser limit, NOT something these rules introduced:
#   * brace script blocks, for the SHARED atoms only - the two scheduled-task
#     rules above now carry a local `{` anchor (CR r8), but `{` cannot go into
#     the shared CMDPOS without refusing `jq '{format: .x}'` and
#     `jq '{shutdown: 1}'`, so `ForEach-Object { schtasks /create }` and
#     `{ shutdown }` stay allowed exactly as they were before this change.
#   * string indirection - `$p = "Schedule.Service"; New-Object -ComObject $p`.
#   * backtick line continuation inside a single command.
#   * the reflective progid route - `[Activator]::CreateInstance(
#     [Type]::GetTypeFromProgID("Schedule.Service"))`. A literal-spelling match
#     for it was tried and REMOVED (CR r5): one variable assignment defeats it,
#     so it only ever caught the naive form, while denying a plain
#     `grep 'GetTypeFromProgID("Schedule.Service")' docs/` - a false positive
#     bought nothing.
# A tokenizer closes these, a wider regex does not: HIMMEL-912. The auto-mode
# classifier and parity_guard remain the outer layers.
if contains '(^|[|;&(={`])[[:space:]]*new-object[^|;&]*-c[[:alnum:]]*[[:space:]]*[:=]?[[:space:]]*[("'\'']*schedule\.service([^[:alnum:]_.-]|$)'; then
    deny "scheduled-task mutation (com)"
fi
if contains "${CMDPOS}"'(taskkill|stop-process|pskill)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "process termination"
fi
if contains '(^|[^[:alnum:]_.-])kill(\.exe)?[[:space:]]+-9'; then
    deny "process termination"
fi
if contains "${CMDPOS}"'(shutdown|reboot|logoff)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "system shutdown"
fi
if contains '(^|[^[:alnum:]_.-])reg(\.exe)?[[:space:]]+(add|delete)([[:space:]]|$)'; then
    deny "registry mutation"
fi
if contains "${CMDPOS}"'(icacls|takeown)(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "permission mutation"
fi
# HIMMEL-2054: resolve the repo's default branch (main/master, occasionally
# something else) so the lease carve-out below can tell an explicit non-default
# branch from a protected one. Empty output on any failure (no origin,
# detached, not a repo) -- the caller always keeps main/master as a floor.
git_default_branch() {
    local ref
    ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) || return 1
    # HIMMEL-2054 CR round 3 (panel, codex-1): strip the fixed prefix, not
    # everything up to the LAST slash -- a default branch containing its own
    # slash (e.g. `release/stable`) was reduced to just `stable`, so the
    # actual default never matched $protected.
    printf '%s' "${ref#refs/remotes/origin/}" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# True (rc 0) iff push_seg's (single ;/|/&-delimited, already-lowercased)
# explicit push target is protected -- main/master, the resolved default
# branch, or no explicit branch at all (ambiguous -> treated as protected,
# i.e. refused). This is the deny-side twin of auto-approve-safe-bash.sh's
# git_push_force_with_lease_is_safe (HIMMEL-212): that grants the identical
# shape at the allow layer; this only needs to agree on when NOT to deny.
git_push_lease_targets_protected() {
    local seg="$1" tok branch db protected=' main master '
    if db=$(git_default_branch) && [ -n "$db" ]; then
        protected="$protected$db "
    fi
    local -a toks positional=()
    # shellcheck disable=SC2206 # intentional whitespace split, single segment by construction
    toks=($seg)
    # HIMMEL-2054 CR: a handful of push flags take their value as a SEPARATE
    # token (`-o ci.skip`, `--repo origin`) rather than glued (`-o=ci.skip`
    # doesn't exist, but `--repo=origin` does) -- an un-skipped value token
    # doesn't start with `-` and would misparse as the remote/branch
    # positional, shifting the count and letting an ambiguous push (no real
    # explicit branch) read as having one. Skip exactly the next token after
    # any of these known value-taking flags.
    local skip_next=0
    for tok in "${toks[@]}"; do
        if [ "$skip_next" -eq 1 ]; then
            skip_next=0
            continue
        fi
        case "$tok" in
            -o|--push-option|--repo|--receive-pack|--exec|--recurse-submodules)
                # HIMMEL-2054 CR round 8 (panel, codex-2): `--sign` (an
                # abbreviation of `--signed[=<mode>]`) does NOT belong here --
                # verified empirically that git parses `--signed`'s value ONLY
                # via an attached `=`, never as a separate following token
                # (an OPTIONAL-value long option, unlike the required-value
                # ones above). Treating it as value-taking swallowed the NEXT
                # real positional (remote/branch), shifting the count.
                skip_next=1 ;;
            -*) ;;                       # flag, not a positional (remote/branch)
            *)
                # HIMMEL-2054 CR round 5 (panel, codex-1): `toks=($seg)` word-
                # splits but does NOT quote-remove -- a real shell WOULD strip
                # matching quotes before git ever sees the argument (`'main'`
                # pushes to main), but here the quote characters stay literal
                # data and never string-match $protected. Strip one matching
                # pair of outer quotes so the comparison sees what git would.
                if [ "${#tok}" -ge 2 ]; then
                    case "$tok" in
                        '"'*'"') tok="${tok%\"}"; tok="${tok#\"}" ;;
                        "'"*"'") tok="${tok%\'}"; tok="${tok#\'}" ;;
                    esac
                fi
                positional+=("$tok") ;;
        esac
    done
    [ "${#positional[@]}" -lt 2 ] && return 0   # no explicit branch -> ambiguous
    # HIMMEL-2054 CR (panel, codex-2): git_default_branch() only resolves
    # origin's default -- a lease push to any OTHER remote could force-update
    # that remote's own (differently named, unresolved-here) default branch
    # without ever matching $protected. Scope the carve-out to origin, the
    # only remote this hook can reason about; any other remote is protected.
    case "${positional[0]}" in
        origin) ;;
        *) return 0 ;;
    esac
    for tok in "${positional[@]:1}"; do
        branch="${tok##*:}"              # refspec dst (src:dst), or the bare token
        branch="${branch#+}"
        branch="${branch#refs/heads/}"
        case "$branch" in
            '') return 0 ;;              # HIMMEL-2054 CR round 4 (panel,
                                          # codex-1): the special bare `:` (or
                                          # `+:`) "matching" refspec strips to
                                          # an empty branch -- it can force-
                                          # update any locally-matching remote
                                          # branch, including main. Ambiguous
                                          # -> protected.
            head|'@'|'@'*) return 0 ;;   # HIMMEL-2054 CR (panel, codex-1;
                                          # round 6 codex-2): HEAD, and its `@`
                                          # shorthand (`@{...}` forms too), are
                                          # symbolic refs for whatever is
                                          # currently checked out -- this hook
                                          # only inspects the command STRING, so
                                          # it cannot statically know whether
                                          # that resolves to main; ambiguous ->
                                          # protected, same as no explicit
                                          # branch at all.
        esac
        case "$branch" in
            *'$'*|*'`'*) return 0 ;;     # HIMMEL-2054 CR round 6 (panel,
                                          # codex-1): a shell variable or
                                          # command-substitution branch
                                          # argument (`origin "$branch"`,
                                          # `` origin `cmd` ``) has a runtime
                                          # value this hook -- which only
                                          # inspects the command STRING, never
                                          # executes it -- cannot resolve.
                                          # Ambiguous -> protected.
            *'*'*) return 0 ;;           # HIMMEL-2054 CR: a wildcard refspec dst
                                          # (refs/heads/*:refs/heads/*) can match
                                          # main/master -- treat as protected.
        esac
        case "$protected" in
            *" $branch "*) return 0 ;;
        esac
    done
    return 1
}

# True (rc 0) iff any pushed refspec after the remote carries a leading `+` --
# git's OWN unconditional force marker for that one ref, independent of any
# --force/--force-with-lease flag entirely (HIMMEL-2054 CR round 7, panel
# codex-1; verified empirically: `git push origin +main` force-updates main
# with NO force flag anywhere in the command, so neither bare_force_re nor
# lease_re below ever fire for it -- a complete, flagless bypass otherwise).
# Also closes a lease scoped to one ref (`--force-with-lease=main`) pairing
# with a DIFFERENT `+`-prefixed refspec that the scoped lease never covers.
# Always treated like a bare force -- denied regardless of which branch it
# targets, since a `+` refspec carries no server-side safety check at all.
git_push_has_plus_refspec() {
    local seg="$1" tok
    local -a toks positional=()
    # shellcheck disable=SC2206 # intentional whitespace split, single segment by construction
    toks=($seg)
    local skip_next=0
    for tok in "${toks[@]}"; do
        if [ "$skip_next" -eq 1 ]; then
            skip_next=0
            continue
        fi
        case "$tok" in
            -o|--push-option|--repo|--receive-pack|--exec|--recurse-submodules)
                # HIMMEL-2054 CR round 8 (panel, codex-2): `--sign` (an
                # abbreviation of `--signed[=<mode>]`) does NOT belong here --
                # verified empirically that git parses `--signed`'s value ONLY
                # via an attached `=`, never as a separate following token
                # (an OPTIONAL-value long option, unlike the required-value
                # ones above). Treating it as value-taking swallowed the NEXT
                # real positional (remote/branch), shifting the count.
                skip_next=1 ;;
            -*) ;;
            *)
                if [ "${#tok}" -ge 2 ]; then
                    case "$tok" in
                        '"'*'"') tok="${tok%\"}"; tok="${tok#\"}" ;;
                        "'"*"'") tok="${tok%\'}"; tok="${tok#\'}" ;;
                    esac
                fi
                positional+=("$tok") ;;
        esac
    done
    [ "${#positional[@]}" -lt 2 ] && return 1   # no explicit refspec to check
    for tok in "${positional[@]:1}"; do
        case "$tok" in
            '+'*) return 0 ;;
        esac
    done
    return 1
}

if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+push([^[:alnum:]_.-]|$)'; then
    # HIMMEL-2054: walk each ;/|/&-delimited segment independently (cmd_lc
    # already folds newlines/CRs to ';', see line 48) so a force push chained
    # after a benign one can't hide behind the first "git push" match.
    push_line_re='(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+push(.*)$'
    # HIMMEL-2054 CR (panel, codex-3, pre-existing on main): a standalone
    # `-f` matched, but a clustered short-flag bundle like `-vf`/`-fv` did
    # not -- the space+dash+letters+f+letters form below catches `-f`
    # anywhere in such a bundle (a false-positive on a made-up flag just
    # denies harder, the safe direction for this hook). round-3 (panel,
    # codex-4): the bundle can also carry digits (git push's real `-4`/`-6`
    # short flags), e.g. `-4f`. round-4 (panel, codex-3): a plain alnum class
    # ALSO matched `-o`'s attached VALUE (`-ofoo` is `-o` with value "foo",
    # not a force flag) -- git push's real clusterable single-char BOOLEAN
    # flags are just n/u/q/v/4/6 plus f itself; `-o` takes an argument, so
    # anything after it is opaque, not more flags. Scoped the bundle class to
    # that known set instead of any letter/digit.
    bare_force_re='(--force([^[:alnum:]_-]|$)|[[:space:]]-[nuqv46]*f[nuqv46]*([^[:alnum:]_-]|$))'
    # HIMMEL-2054 CR round 3 (panel, codex-3): git accepts any unambiguous
    # abbreviation of a long option, and `--force-w` is the shortest one
    # that resolves ONLY to --force-with-lease (shorter prefixes are either
    # ambiguous with --force-if-includes, or exact-match plain --force) --
    # verified empirically against real git push. Matching just the literal
    # full flag name let `--force-with-l`/`--force-w` etc slip past BOTH
    # regexes untouched, a full undetected bypass. `[a-z-]*` covers any
    # actual prefix of "ith-lease"; overmatching here just denies a
    # malformed flag git itself would refuse anyway.
    lease_re='--force-w[a-z-]*(=[^[:space:]]*)?([^[:alnum:]_-]|$)'
    # HIMMEL-2054 CR: git_default_branch() resolves the CURRENT process cwd,
    # not any directory a `cd` earlier in this same command line would select
    # -- the hook never executes the command, it only inspects the string. A
    # `cd`-then-push chain could therefore force-update another repo's real
    # default branch under a non-main/master name that never gets protected.
    # A `cd` anywhere in the command disables the branch-aware carve-out
    # entirely for it (falls through to the always-safe deny below) rather
    # than trying to track which directory the push actually runs in.
    cd_chained=0
    contains '(^|[^[:alnum:]_.-])cd([^[:alnum:]_.-]|$)' && cd_chained=1
    while IFS= read -r seg; do
        [[ $seg =~ $push_line_re ]] || continue
        push_seg="${BASH_REMATCH[3]}"
        # HIMMEL-2054 CR round 7: a `+`-prefixed refspec is checked ALONGSIDE
        # bare_force_re, not only inside the lease_re branch below -- a
        # scoped lease (`--force-with-lease=main`) still matches lease_re
        # while leaving a DIFFERENT `+`-prefixed refspec in the same push
        # completely unprotected; checking it only inside that branch would
        # never see it once lease_re had already claimed the segment.
        if [[ $push_seg =~ $bare_force_re ]] || git_push_has_plus_refspec "$push_seg"; then
            deny "force push"
        elif [[ $push_seg =~ $lease_re ]]; then
            # HIMMEL-212/2054: a lease-protected force push to an explicit,
            # non-default branch is safe (git refuses if the remote tip
            # moved) -- refuse only main/master/default-branch, an
            # ambiguous (no explicit branch) target, or a chained `cd`.
            if [ "$cd_chained" -eq 1 ] || git_push_lease_targets_protected "$push_seg"; then
                deny "force push"
            fi
        fi
    done <<< "${cmd_lc//[;|&]/$'\n'}"
fi
if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+reset[[:space:]]+--hard([^[:alnum:]_-]|$)'; then
    deny "git reset --hard"
fi
if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+clean[[:space:]]+-[[:alnum:]_]*f'; then
    deny "git clean -f"
fi
if contains '(^|[^[:alnum:]_.-])git(\.exe)?[[:space:]]+filter-branch([^[:alnum:]_-]|$)'; then
    deny "git filter-branch"
fi
if contains '(^|[^[:alnum:]_.-])curl(\.exe)?[^|;&]*\|[[:space:]]*(ba)?sh(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "remote exec pipe"
fi
if contains '(^|[^[:alnum:]_.-])wget(\.exe)?[^|;&]*\|[[:space:]]*(ba)?sh(\.exe)?([^[:alnum:]_.-]|$)'; then
    deny "remote exec pipe"
fi

exit 0
