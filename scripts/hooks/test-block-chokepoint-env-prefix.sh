#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-chokepoint-env-prefix.sh (HIMMEL-1746:
# deny env-prefixed invocations of the REGISTERED sanctioned chokepoints).
#
# The SHIPPED registry (scripts/chokepoints.json) drives the fixtures: every
# (chokepoint, seam var) pair the registry carries is exercised, so a new
# registry entry is covered by this suite without editing it. No hand-written
# duplicate of the predicate lives here -- that is the drift class
# (PR #1680 / #1691) the registry exists to prevent.
#
# Intended behavior pinned by this suite:
#   - registered chokepoint + registered seam var as a per-call prefix (or an
#     `env` wrapper argument) -> DENY, with the message naming the
#     launching-shell convention;
#   - bare invocation, unregistered script, unregistered var, and a seam var
#     registered for a DIFFERENT chokepoint -> ALLOW (fail-open; the registry
#     is the predicate, not a general env ban).
#
# Usage: bash scripts/hooks/test-block-chokepoint-env-prefix.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed
# bash 3.2-compatible. ASCII only.
set -uo pipefail

# Invoked via `bash` below, never chmod'd: making the hook executable from
# the suite would hide a missing exec-bit/wiring problem and leave file-mode
# changes behind on POSIX checkouts with core.filemode=true (HIMMEL-1761
# class; HIMMEL-1803). git status must be clean after a run.
HOOK="$(cd "$(dirname "$0")" && pwd)/block-chokepoint-env-prefix.sh"
REPO_ROOT=$(cd "$(dirname "$HOOK")/../.." && pwd -P)
REGISTRY="$REPO_ROOT/scripts/chokepoints.json"

FAILED=0
CASES=0

# Registry-driven fixtures (never hand-duplicated above the shipped data).
# tr -d '\r': jq's Windows text-mode stdout emits CRLF; a CR riding the last
# var of an entry would corrupt every command built from it (same trap the
# hook strips at its own read).
reg_entry() {  # reg_entry <basename-suffix> -> prints "path<TAB>var var ..."
    jq -r --arg suf "$1" 'to_entries[] | select(.key | endswith($suf)) | "\(.key)\t\((.value.seam_env_vars // []) | join(" "))"' "$REGISTRY" | tr -d '\r'
}
STOP_WORKER=$(reg_entry "stop-worker.sh" | cut -f1)
STOP_WORKER_VARS=$(reg_entry "stop-worker.sh" | cut -f2)
MERGE_ON_GREEN=$(reg_entry "merge-on-green.sh" | cut -f1)
MERGE_ON_GREEN_VARS=$(reg_entry "merge-on-green.sh" | cut -f2)
SW_VAR=$(printf '%s' "$STOP_WORKER_VARS" | awk '{print $1}')
MOG_VAR=$(printf '%s' "$MERGE_ON_GREEN_VARS" | awk '{print $1}')

# Fail fast if the shipped registry did not yield the fixtures this suite
# names -- silent empties would turn every assert below into noise.
if [ ! -f "$REGISTRY" ] || [ -z "$STOP_WORKER" ] || [ -z "$SW_VAR" ] \
   || [ -z "$MERGE_ON_GREEN" ] || [ -z "$MOG_VAR" ]; then
    echo "FAIL fixture: registry $REGISTRY did not yield stop-worker.sh / merge-on-green.sh entries"
    exit 1
fi

j() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
jp() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# run <json> [ENV=VAL ...] -> runs the hook, sets OUT/ERR/RC.
run() {
    local input="$1"; shift
    local outf errf
    outf=$(mktemp); errf=$(mktemp)
    printf '%s' "$input" | env -u ENV_PREFIX_GUARD_OK -u CHOKEPOINT_REGISTRY "$@" bash "$HOOK" >"$outf" 2>"$errf"
    RC=$?
    OUT=$(cat "$outf"); ERR=$(cat "$errf")
    rm -f "$outf" "$errf"
}

assert_allow() {  # assert_allow <label> <json> [ENV=VAL ...]
    local label="$1"; shift
    run "$@"
    local decision
    decision=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    CASES=$((CASES + 1))
    if [ "$RC" = "0" ] && [ "$decision" != "deny" ]; then
        echo "PASS $label (allowed, untouched)"
    else
        echo "FAIL $label -- expected rc=0 with no deny decision, got rc=$RC decision='$decision'"
        FAILED=$((FAILED + 1))
    fi
}

assert_deny() {  # assert_deny <label> <json>
    local label="$1"; shift
    run "$@"
    local decision
    decision=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    CASES=$((CASES + 1))
    if [ "$RC" = "2" ] && [ "$decision" = "deny" ] \
       && printf '%s' "$ERR" | grep -q "LAUNCHING shell"; then
        echo "PASS $label (denied, message names the launching-shell convention)"
    else
        echo "FAIL $label -- expected rc=2 + permissionDecision=deny + launching-shell message, got rc=$RC decision='$decision'"
        FAILED=$((FAILED + 1))
    fi
}

# --- DENIED: every registered (chokepoint, seam var) pair, straight from the
# shipped registry -- the suite auto-grows with the registry. ---
while IFS=$'\t' read -r reg_path reg_vars; do
    [ -n "$reg_path" ] || continue
    # shellcheck disable=SC2086 # space-joined registry list is split intentionally
    for reg_var in $reg_vars; do
        assert_deny "registry pair ${reg_var}= on $reg_path" "$(j "${reg_var}=1 bash $reg_path --list")"
    done
done < <(jq -r 'to_entries[] | "\(.key)\t\((.value.seam_env_vars // []) | join(" "))"' "$REGISTRY" | tr -d '\r')

# --- DENIED: the named ticket shapes + wrapper/compound variants ---
assert_deny "env wrapper on $MERGE_ON_GREEN"            "$(j "env ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "env -u PATH wrapper (flag consumes value)" "$(j "env -u PATH ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "path-qualified /usr/bin/env wrapper"       "$(j "/usr/bin/env ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "assignment run after benign prefix"        "$(j "BENIGN_TOKEN=1 ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "quoted assignment value"                   "$(j "${MOG_VAR}='a b' bash $MERGE_ON_GREEN")"
assert_deny "compound after &&"                         "$(j "cd /tmp && ${SW_VAR}=9 bash $STOP_WORKER --list")"
assert_deny "second line of a newline compound"         "$(j "git status
${SW_VAR}=9 bash $STOP_WORKER --list")"
assert_deny "\$CLAUDE_PROJECT_DIR-qualified path"       "$(j "${MOG_VAR}=1 bash \"\$CLAUDE_PROJECT_DIR/$MERGE_ON_GREEN\"")"
assert_deny "PowerShell tool carrying the same shape"   "$(jp "${MOG_VAR}=1 bash $MERGE_ON_GREEN")"

# --- CR ROUND 1 (HIMMEL-1746): the env-prefix must bind to the chokepoint's
# OWN command segment. The pre-fix predicate tested "path found anywhere"
# AND "assignment found anywhere" over the whole compound, which false-denied
# (assignment in a different segment -- finding 1) and evaded (separator
# defeating the path's end-of-string boundary -- finding 2) as one weakness.
assert_allow "finding 1: seam var on OTHER segment (;)"   "$(j "${MOG_VAR}=x echo ok; bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (&&)"  "$(j "${MOG_VAR}=x echo ok && bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (||)"  "$(j "${MOG_VAR}=x echo ok || bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (|)"   "$(j "${MOG_VAR}=x echo ok | bash $MERGE_ON_GREEN")"
assert_allow "finding 1: seam var on OTHER segment (nl)"  "$(j "${MOG_VAR}=x echo ok
bash $MERGE_ON_GREEN")"
assert_allow "chokepoint, THEN unrelated assignment segment" "$(j "bash $MERGE_ON_GREEN; ${MOG_VAR}=x echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (;)"  "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN; echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (&&)" "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN && echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (||)" "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN || echo ok")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (|)"  "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN | cat")"
assert_deny "finding 2: separator AFTER env-prefixed chokepoint (nl)" "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN
echo ok")"
assert_deny "env-prefixed chokepoint alone still denied"  "$(j "${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny "quoted separator inside a value never splits" "$(j "${MOG_VAR}='a;b' bash $MERGE_ON_GREEN")"

# --- CR ROUND 2 (HIMMEL-1746): same class, third instance forbidden. The
# INVARIANT (stated at the hook's scanner): a chokepoint is recognized only
# when its path is the invoked-program TOKEN of a segment -- decided by
# tokenizing into shell words, never by substring search -- and a seam
# assignment counts only as a leading assignment word of that SAME segment.
# Finding 3 (evasion): an attached redirection is not a word boundary any
# enumerated character set knew about; the tokenizer ends the word there.
# Finding 4 (false deny): a path in ARGUMENT position is not the
# invoked-program token, wherever in the segment it appears.
assert_deny  "finding 3: attached stdout redirection"      "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN>/tmp/h.log")"
assert_deny  "finding 3: attached append redirection"      "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN>>/tmp/h.log")"
assert_deny  "finding 3: attached stderr redirection"      "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN 2>/dev/null")"
assert_deny  "finding 3 kin: redirect interleaved before interpreter" "$(j "${MOG_VAR}=1 >/tmp/h.log bash $MERGE_ON_GREEN")"
assert_allow "finding 4: path in ARGUMENT position (echo)" "$(j "${MOG_VAR}=1 echo $MERGE_ON_GREEN")"
assert_allow "finding 4: path in ARGUMENT position (cat)"  "$(j "${MOG_VAR}=1 cat $MERGE_ON_GREEN")"

# --- Invariant probes past the four findings: word identity and command
# position come from the tokenizer, so quote/escape splits, continuations,
# groupings ('(' carve-out CLOSED), and re-parsing wrappers all resolve. ---
assert_deny  "backslash-newline continuation"      "$(j "${MOG_VAR}=1 \\
bash $MERGE_ON_GREEN")"
assert_deny  "split-quoted path is one word"       "$(j "${MOG_VAR}=1 bash ${MERGE_ON_GREEN%/*}/'${MERGE_ON_GREEN##*/}'")"
assert_deny  "backslash-escaped interpreter word"  "$(j "${MOG_VAR}=1 \\bash $MERGE_ON_GREEN")"
assert_deny  "subshell-wrapped invocation"         "$(j "(${MOG_VAR}=1 bash $MERGE_ON_GREEN)")"
assert_deny  "substitution inside double quotes"   "$(j "echo \"\$(${MOG_VAR}=1 bash $MERGE_ON_GREEN)\"")"
assert_deny  "eval with a quoted command string"   "$(j "eval \"${MOG_VAR}=1 bash $MERGE_ON_GREEN\"")"
assert_deny  "exec wrapper"                        "$(j "${MOG_VAR}=1 exec bash $MERGE_ON_GREEN")"
assert_deny  "bash -c string carrying the invocation" "$(j "${MOG_VAR}=1 bash -c 'bash $MERGE_ON_GREEN'")"
assert_allow "bash -c: path in \$0 position is not invoked" "$(j "${MOG_VAR}=1 bash -c 'echo hi' $MERGE_ON_GREEN")"
assert_allow "double-quoted literal text is not an invocation" "$(j "echo \"${MOG_VAR}=1 bash $MERGE_ON_GREEN\"")"

# --- HIMMEL-1803: the env -S split-string seam. `env -S 'VAR=x cmd'`
# re-tokenizes the operand into the whole command line (GNU env's documented
# -S / --split-string), so the operand is an eval/-c-shaped string the guard
# re-parses under its depth cap, with names inherited from the outer env
# words (env A=1 -S 'B=2 cmd' exports both). Words AFTER the operand are
# arguments APPENDED to the string's command, never a fresh command
# position; and the pinned interpreter shapes survive inside the string. ---
assert_deny  "env -S split string carries the seam"    "$(j "env -S '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S attached operand"                 "$(j "env -S'${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env --split-string long form"            "$(j "env --split-string '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S behind a -u flag"                 "$(j "env -u FOO -S '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S: seam on the OUTER env words"     "$(j "env ${MOG_VAR}=x -S 'bash $MERGE_ON_GREEN'")"
assert_allow "env -S string WITHOUT a seam var"        "$(j "env -S 'bash $MERGE_ON_GREEN'")"
assert_allow "env -S: words after the string are appended args" "$(j "env -S 'echo hi' bash $MERGE_ON_GREEN")"
assert_allow "env -S: path at \$0 inside the string"   "$(j "env -S '${MOG_VAR}=x bash -c \"echo hi\" $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 2: the CLUSTERED short-option spelling. Flags
# clustered ahead of S ("-vS", "-iS", "-ivS") are ONE option word, and env
# still re-tokenizes the operand -- the NEXT word when S ends the cluster,
# the REST of the word when it does not ("-vSstr"). The same getopt rule
# makes an argument-taking letter mid-cluster ("-vu FOO") consume the next
# word as ITS operand. These ratchets were proven RED against the round-1
# hook (a clustered option word was skipped whole, so the split string
# rode into command position as one opaque word). ---
assert_deny  "env -vS cluster carries the seam"        "$(j "env -vS '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -iS cluster carries the seam"        "$(j "env -iS '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -ivS multi-flag cluster"             "$(j "env -ivS '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -vS attached operand"                "$(j "env -vS'${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -ivS attached operand"               "$(j "env -ivS'${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -vS: seam on the OUTER env words"    "$(j "env ${MOG_VAR}=x -vS 'bash $MERGE_ON_GREEN'")"
assert_deny  "env -vu PATH cluster (operand consumed)" "$(j "env -vu PATH ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "env -vS string WITHOUT a seam var"       "$(j "env -vS 'bash $MERGE_ON_GREEN'")"
assert_allow "env -vS: words after the string are appended args" "$(j "env -vS 'echo hi' bash $MERGE_ON_GREEN")"
assert_allow "env -iS: path at \$0 inside the string"  "$(j "env -iS '${MOG_VAR}=x bash -c \"echo hi\" $MERGE_ON_GREEN'")"
assert_allow "env -vSu: mid-cluster S consumes u; rest are appended args" "$(j "env -vSu '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 3: the OPTION-TABLE class closure. Three CR
# rounds each found a spelling the hand-written option list missed; the
# hook's env arm now DERIVES operand consumption from a grammar table
# (ENV_LONG_OPTS). Proven RED by hand against the round-2 hook (the
# option word was skipped alone, so its separate operand parked in
# command position and the scan never reached the chokepoint):
# --unset / --chdir / --argv0 with a SEPARATE operand, the --uns and
# --spl ABBREVIATIONS, --spl=..., -P, --unset-then- "--", and the
# unrecognised/ambiguous-option defaults. The long-with-= pins and the
# bare "--"/"-" pins were already green under round-2 and are pinned
# against regression. Two verdicts FLIP deny->allow, deliberately,
# because the model now matches env's real grammar: after "--" or "-",
# an option-looking WORD is the first operand (the command of an
# invocation env cannot run -- it fails to exec), never an option --
# "env -- --unset ..." and "env - --unset ..." allow where round-2
# denied. The nested-env cases pin that a fresh env word restarts
# option parsing (the outer "--" must not leak into the inner env). ---
assert_deny  "env --unset separate operand carries the seam"  "$(j "env --unset FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --chdir separate operand carries the seam"  "$(j "env --chdir /tmp ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --argv0 separate operand carries the seam"  "$(j "env --argv0 zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --unset=FOO attached operand"               "$(j "env --unset=FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --chdir=/tmp attached operand"              "$(j "env --chdir=/tmp ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --argv0=zzz attached operand"               "$(j "env --argv0=zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --unset ABBREVIATED (--uns)"                "$(j "env --uns FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --split-string ABBREVIATED (--spl)"         "$(j "env --spl '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env --spl=... abbreviated long-with-="          "$(j "env --spl='${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -P alternate path (BSD arg operand)"        "$(j "env -P /bin ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -- ends options; assignments still bind"     "$(j "env -- ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env --unset FOO then -- then the seam"           "$(j "env --unset FOO -- ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env - (lone dash) ends options; seam still binds" "$(j "env - ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "unrecognised option: seam collected BEFORE it"   "$(j "env ${MOG_VAR}=x --not-an-env-option FOO bash $MERGE_ON_GREEN")"
assert_deny  "unrecognised option: operand does not park command position" "$(j "env --not-an-env-option FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "ambiguous abbreviation (--ig) uses the default too" "$(j "env --ig FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "after --, an option WORD is the command, not an option"      "$(j "env -- --unset ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "after -, an option WORD is the command, not an option"       "$(j "env - --unset ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "optarg long (--ignore-signal) takes no separate word"        "$(j "env --ignore-signal INT ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "nested env carries the seam through its own -S"              "$(j "env ${MOG_VAR}=x env -S 'bash $MERGE_ON_GREEN'")"
assert_deny  "env after --: inner env option parsing restarts"             "$(j "env -- ${MOG_VAR}=x env -S 'bash $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 4: the conservative default for SHORT clusters and
# the -S OPTION-state re-entry. Round 3 documented "an option the scanner
# does not recognise must fall to a conservative default that assumes it
# MAY consume an operand" but implemented it for LONG options only:
# env_short_cluster returned "unknown" (a bare word-skip) and had no -a
# (GNU's short spelling of --argv0), so `env -a zzz SEAM=x bash
# <chokepoint>` parked zzz in command position and the scan returned
# before the chokepoint. And a -S operand re-entered a FRESH COMMAND SCAN
# instead of env's own option parsing, so a leading -i/-u/-C inside the
# string was modelled as the invoked program. The seven shapes driven RED
# by hand against the round-3 hook (env -a zzz / -a ignored / -a ignored
# -S / clustered -va zzz / -S '-i ...' / -S '-u X ...' / -S '-C /tmp
# ...') are closed by the same two fixes; the -azzz and -QFOO attached
# spellings already denied via the interpreter arm and are pinned. The
# scan_split_argv model (coreutils parse_split_string): the -S string's
# tokenized argv, with the CLI words after the operand APPENDED, goes
# back through env's OPTION state -- GNU's documented "\_" argument
# separator included; ';' inside the string is a word character, not a
# shell separator. ---
assert_deny  "env -a separate operand carries the seam"    "$(j "env -a zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -a attached operand"                     "$(j "env -azzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -va cluster: a consumes the next word"   "$(j "env -va zzz ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -a operand, then a -S split string"      "$(j "env -a ignored -S '${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "unknown short letter uses the conservative default" "$(j "env -Q FOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "unknown short letter, attached spelling"     "$(j "env -QFOO ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S string: leading -i is an env OPTION"  "$(j "env -S '-i ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S string: leading -u consumes its word" "$(j "env -S '-u X ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S string: leading -C consumes its word" "$(j "env -S '-C /tmp ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S string: leading -- ends its options"  "$(j "env -S '-- ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"
assert_deny  "env -S option-only string; command rides the outer words" "$(j "env -S '-i' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: \_ is the argument separator"        "$(j "env -S '${MOG_VAR}=x bash\\_$MERGE_ON_GREEN'")"
assert_allow "env -S option state, no seam var"            "$(j "env -S '-u X bash $MERGE_ON_GREEN'")"
assert_allow "env -S: ; inside the string is a word character" "$(j "env -S 'echo ok; ${MOG_VAR}=x bash $MERGE_ON_GREEN'")"

# --- HIMMEL-1803 round 7: an unquoted # at argument start discards the
# rest of an env -S string; an escaped \# remains literal word content. ---
assert_deny  "env -S: leading # comment discards the string" "$(j "env -S '# ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: mid-string # comment discards the rest" "$(j "env -S '-u X # ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "env -S: escaped \# stays literal before a later comment" "$(j "env -S '-u \\# # ignored' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"

# --- HIMMEL-1803 round 6: ZERO-LENGTH WORDS keep their argv slot. The
# invariant the whole r1-r6 family violated piecemeal: the scan is a
# positional simulation of the argv each interpreter really receives, so
# every hand-off must preserve word COUNT, ORDER, and CONTENT --
# zero-length words included -- and every consumption decision must come
# from the consuming interpreter's real grammar. Pre-fix, the bare
# newline-delimited word streams could not represent an empty word, so
# '' was silently dropped and every later word's role shifted -- which
# BOTH mis-allowed (env -a '' SEAM=x bash <chokepoint>: the dropped ''
# let -a eat the seam assignment as its operand; GNU env really consumes
# '' and runs the chokepoint with the seam) AND mis-denied (SEAM=x ''
# bash <chokepoint>: the empty word IS the command, exec fails, nothing
# runs). All eight non-redirect shapes below were driven RED by hand
# against the round-5 hook. The kin pins: --split-string= and -S ''
# (verified: GNU env runs the appended CLI words after an EMPTY split
# string) exercise the empty-OPERAND half -- $(...) strips an empty
# second protocol line, which pre-fix parked the verdict word itself in
# command position. ---
assert_deny  "r6: -S string, -a consumes a quoted-empty operand"  "$(j "env -S \"-a '' ${MOG_VAR}=x bash $MERGE_ON_GREEN\"")"
assert_deny  "r6: -S string, -u consumes a quoted-empty operand"  "$(j "env -S \"-u '' ${MOG_VAR}=x bash $MERGE_ON_GREEN\"")"
assert_deny  "r6: plain env -a with quoted-empty operand"         "$(j "env -a '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "r6: plain env -u with quoted-empty operand"         "$(j "env -u '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "r6: --split-string= empty attached operand"         "$(j "env --split-string= ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_deny  "r6: -S '' empty separate operand"                   "$(j "env -S '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "r6: empty word IS env's command (exec fails)"       "$(j "env '' ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "r6: empty word IS the shell command"                "$(j "${MOG_VAR}=x '' bash $MERGE_ON_GREEN")"
assert_allow "r6: empty word at command position inside -S"       "$(j "env -S \"${MOG_VAR}=x '' bash $MERGE_ON_GREEN\"")"
assert_allow "r6: -S string of only a quoted empty"               "$(j "env -S \"''\" ${MOG_VAR}=x bash $MERGE_ON_GREEN")"
assert_allow "r6: quoted-empty word attached to a redirect is a word, not an IO number" "$(j "${MOG_VAR}=x ''>/tmp/h.log bash $MERGE_ON_GREEN")"

# --- Round-3 grammar probes (INFORMATIONAL -- echo only, never counted,
# never FAIL): the hook's option table is derived from env's real
# grammar; these print what THIS machine's env does with the load-bearing
# spellings, so a reviewer re-running the suite sees the derivation
# basis. "exit 0" = env accepted and ran `true`; "exit non-zero" = env
# rejected/errored before running anything (e.g. the signal name in the
# --ignore-signal probe parking as the command is the no-separate-word
# rule working). On a machine whose env lacks a spelling the probe just
# prints non-zero -- the table entry stays harmless there. ---
probe_env() {  # probe_env <label> <argv...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "PROBE $label: exit 0"
    else echo "PROBE $label: exit non-zero"; fi
}
probe_env "--unset NAME (separate operand)"    env --unset HM_1803_NOEXIST HM_1803_PROBE=1 true
probe_env "--unset=NAME (attached operand)"    env --unset=HM_1803_NOEXIST HM_1803_PROBE=1 true
probe_env "--chdir DIR (separate operand)"     env --chdir . HM_1803_PROBE=1 true
probe_env "--argv0 NAME (separate operand)"    env --argv0 HM_1803 HM_1803_PROBE=1 true
probe_env "--argv0=NAME (attached operand)"    env --argv0=HM_1803 HM_1803_PROBE=1 true
probe_env "-P DIR (BSD-only; GNU rejects)"     env -P /bin HM_1803_PROBE=1 true
probe_env "-a NAME (GNU argv0 short; older env rejects)" env -a HM_1803 HM_1803_PROBE=1 true
probe_env "--uns NAME (unique abbreviation)"   env --uns HM_1803_NOEXIST HM_1803_PROBE=1 true
probe_env "--spl=STR (abbreviated split)"      env --spl=HM_1803_PROBE=1 true
probe_env "--split-string STR (separate)"      env --split-string HM_1803_PROBE=1 true
probe_env "--ignore-signal=INT (= spelling)"   env --ignore-signal=INT HM_1803_PROBE=1 true
probe_env "--debug (long twin of -v)"          env --debug HM_1803_PROBE=1 true
probe_env "--ignore-signal INT (separate word NOT consumed -- non-zero expected)" env --ignore-signal INT HM_1803_PROBE=1 true
probe_env "-- then assignments"                env -- HM_1803_PROBE=1 true
probe_env "- (lone dash; GNU treats as -i and runs, BSD treats as --)" env - HM_1803_PROBE=1 true
probe_env "--ig (ambiguous abbreviation)"      env --ig HM_1803_PROBE=1 true
probe_env "--not-an-env-option (unknown)"      env --not-an-env-option HM_1803_PROBE=1 true
# Round-6 zero-length probes: the two "exit 0" lines are the load-bearing
# ones -- an EMPTY split string still runs the appended CLI words, so a
# seam there must deny; the non-zero lines show the shapes where nothing
# can run (deny stays the conservative union-model verdict for -a/-u '').
probe_env "--split-string= (EMPTY split; appended words RUN)" env --split-string= HM_1803_PROBE=1 true
probe_env "-S '' (EMPTY separate split; appended words RUN)"  env -S '' HM_1803_PROBE=1 true
probe_env "-u '' (empty unset name; GNU rejects)"             env -u '' HM_1803_PROBE=1 true
probe_env "-a '' (empty argv0; env without -a rejects)"       env -a '' HM_1803_PROBE=1 true
probe_env "'' as the command word (exec fails)"               env '' HM_1803_PROBE=1 true

# --- ALLOWED: fail-open proofs ---
assert_allow "bare sanctioned invocation (no prefix)"    "$(j "bash $MERGE_ON_GREEN")"
assert_allow "bare invocation, other chokepoint"         "$(j "bash $STOP_WORKER --list")"
assert_allow "env wrapper WITHOUT a seam var"            "$(j "env bash $MERGE_ON_GREEN")"
assert_allow "registered var, UNREGISTERED script"       "$(j "${SW_VAR}=9 bash scripts/some/unregistered-script.sh")"
assert_allow "UNREGISTERED var, registered chokepoint"   "$(j "TOTALLY_UNRELATED_VAR=1 bash $MERGE_ON_GREEN")"
assert_allow "seam var of a DIFFERENT chokepoint"        "$(j "${MOG_VAR}=1 bash $STOP_WORKER --list")"
assert_allow "longer var name sharing a prefix"          "$(j "${MOG_VAR}X=1 bash $MERGE_ON_GREEN")"
assert_allow "assignment as an ARGUMENT, not a prefix"   "$(j "bash $STOP_WORKER --dry-run ${SW_VAR}=9")"
assert_allow "non-Bash/PowerShell tool"                  '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
assert_allow "bypass: ENV_PREFIX_GUARD_OK=1 in the hook env" "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN")" "ENV_PREFIX_GUARD_OK=1"

# --- ALLOWED: fail-open on unresolvable inputs (belt posture) ---
TMPDIR_F=$(mktemp -d)
assert_allow "registry file missing"        "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN")" "CHOKEPOINT_REGISTRY=$TMPDIR_F/nope.json"
printf '[1,2,3]\n' >"$TMPDIR_F/bad.json"
assert_allow "registry not a JSON object"   "$(j "${MOG_VAR}=1 bash $MERGE_ON_GREEN")" "CHOKEPOINT_REGISTRY=$TMPDIR_F/bad.json"
rm -rf "$TMPDIR_F"
assert_allow "empty stdin"                  ''

# --- Soft drift check: the guard should be wired in .claude/settings.json.
# WARN-only (not a FAIL) because the wiring may land in a later commit than
# the hook (review lanes cannot always edit settings.json) -- a hard gate
# here would turn that sequencing into a false red. The hookspath-misconfig
# pre-commit hook validates settings.json hook references independently.
CASES=$((CASES + 1))
if grep -q "block-chokepoint-env-prefix.sh" "$REPO_ROOT/.claude/settings.json" 2>/dev/null; then
    echo "PASS settings.json wiring present"
else
    echo "WARN settings.json does not reference block-chokepoint-env-prefix.sh yet (not counted as a failure)"
    CASES=$((CASES - 1))
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK: all $CASES cases passed"
    exit 0
fi
echo "FAILED: $FAILED of $CASES cases failed"
exit 1
