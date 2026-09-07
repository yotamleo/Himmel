#!/usr/bin/env bash
# test-session-end-timeout-budget.sh — SessionEnd fits the codex 3 s clamp (HIMMEL-2492).
#
# WHY: codex-cli 0.153 hard-clamps SessionEnd hook timeouts to 3 s and prints
#   ⚠ clamping SessionEnd hook timeout to 3s in <cache>/himmel-ops/<ver>/hooks/hooks.json
# once per entry that declares more. himmel-ops declared `timeout: 15` on all
# three SessionEnd entries, so the operator saw that warning three times per
# codex session. The noise is the visible half; the load-bearing half is that a
# SessionEnd hook needing more than 3 s is KILLED mid-flight under the codex
# lane — on Windows the launch chain alone (bash -l -> node -> script) measures
# 0.6-3 s under load (HIMMEL-2480), the same silent-no-run class as HIMMEL-2148.
#
# So the declaration and the behaviour both have to hold, and each is vacuous
# without the other — a 3 s declaration over a 10 s command still gets killed,
# and a fast command under a 15 s declaration still warns and still gets
# clamped. Four cases, two per half:
#
#   1. DECLARATION (plugin) — no SessionEnd entry in the himmel-ops plugin
#      hooks.json declares a timeout above 3.
#   2. DECLARATION (codex twin) — same for .codex/hooks.json.
#   3. BEHAVIOUR (budget) — every plugin SessionEnd command, executed against
#      the REAL hook scripts with a real SessionEnd payload, returns in under
#      3 s while a 10 s delay is injected into the detached child body. The
#      delay is the negative control: it is invisible to the parent ONLY
#      because the hook full-body detaches (HIMMEL-636/661), so a regression
#      that un-detaches one runs those 10 s in the foreground and fails here.
#   4. BEHAVIOUR (structure) — every SessionEnd hook script carries the
#      full-body `__himmel_detached` re-exec guard. Case 3 can only inject its
#      delay where a script exposes a test seam; this covers the ones that do
#      not, so adding a NEW synchronous SessionEnd hook cannot pass unnoticed.
#
# Side-effect containment for case 3: the payload cwd points at a scratch repo
# with an empty .env, every hook's gate var is exported OFF (an exported empty
# / 0 beats a .env value — load_dotenv is non-clobbering), and a stub `bun`
# fronts PATH so the telegram relay can reach no network even if a gate flipped.
#
# Both config files are core himmel files that live beside this suite: a
# missing one FAILs, it is never SKIPped, and cases 3/4 additionally FAIL if
# they enumerate zero SessionEnd commands/scripts — an emptied, truncated or
# malformed config must never read as a vacuous green (CR round 1, HIMMEL-2492).
#
# Platform guard (gitbash-only): POSIX bash 3.2+, incl. Git Bash on Windows. No
# .ps1 twin — project convention for a test harness (see T15 in
# scripts/parity/test-ws5-invariants.sh). Case 3 needs GNU coreutils `timeout`
# and SKIPs where it is absent (stock macOS).
#
# Wall time: case 3 deliberately spends ~(CHILD_DELAY + 2)s AFTER its command
# loop waiting out the detached children's delay before the EXIT trap removes
# the scratch dir they read from — the alternative is deleting it out from
# under a live child. Expect ~12s total, not the ~0s the loop itself takes.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/marketplace/plugins/himmel-ops"
PLUGIN_HOOKS="$PLUGIN_ROOT/hooks/hooks.json"
CODEX_HOOKS="$REPO_ROOT/.codex/hooks.json"

# codex-cli 0.153 clamps SessionEnd to this many seconds and warns above it.
CODEX_SESSION_END_CLAMP=3
# Derived, not a second independently-editable constant: cases 1/2 compare
# against a JSON `timeout` field in seconds and must keep using the seconds
# form above; case 3's sub-second measurement compares against this ms form.
CODEX_SESSION_END_CLAMP_MS=$((CODEX_SESSION_END_CLAMP * 1000))
# Injected into each detached child body; must exceed the clamp by enough that
# a foreground run cannot be mistaken for jitter.
CHILD_DELAY=10

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 1; }

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL %s\n' "$1" >&2; }

# --- Cases 1 + 2: declared SessionEnd timeouts are within the clamp ----------
# A missing timeout is NOT accepted: bench-hook-stack.test.mjs requires an
# explicit timeout on every command hook (HIMMEL-1985), so "omit it" would trade
# this red for that one.
#
# codex-1 (CR round 5): valid means a POSITIVE INTEGER no greater than the
# clamp, not merely "<= clamp" — the prior predicate only rejected non-numbers
# and values above the clamp, so 0 / -1 / 2.5 all read as fine. This is a
# RANGE check, deliberately not the closed tier set bench-hook-stack.test.mjs
# enforces (`ALLOWED = [3, 10, 15, 20, 30, 60]`): that suite already covers
# $PLUGIN_HOOKS with its closed set, but it never reads $CODEX_HOOKS, so the
# codex twin had no lower-bound gate anywhere. A range check here closes that
# gap for the codex twin without duplicating bench-hook-stack's tier-set job
# for the plugin config, and is applied symmetrically to both configs so the
# two declaration checks keep asserting the same rule.
assert_declared_within_clamp() {
    label="$1"
    config="$2"
    if [ ! -f "$config" ]; then
        # Neither config is optional: both are core himmel files this suite
        # lives beside. A missing config must FAIL, never SKIP — a SKIP here
        # would report PASSED as if the declaration had been checked at all.
        fail "$label: config not found at $config"
        return
    fi
    n="$(jq '[.hooks.SessionEnd // [] | .[] | .hooks[] | select(.type == "command")] | length' "$config" 2>/dev/null)"
    n_rc=$?
    # A jq parse failure writes to stderr and prints nothing, so `n` would be
    # empty; `[ "" -lt 1 ]` reads as false under bash (the test errors out and
    # `if` treats that as failure), falling through past the "found $n" fail
    # and into the offenders jq below — which fails the same way, so
    # `[ -z "$offenders" ]` is true and a MALFORMED config reports `pass`
    # (CR round 2, HIMMEL-2492). Catch the parse failure explicitly, distinct
    # from the well-formed-but-empty case.
    if [ "$n_rc" -ne 0 ] || ! printf '%s' "$n" | grep -qE '^[0-9]+$'; then
        fail "$label: $config did not parse as valid JSON (jq exit $n_rc)"
        return
    fi
    if [ "$n" -lt 1 ]; then
        fail "$label: expected at least one SessionEnd command hook, found $n"
        return
    fi
    # codex-1: offender = not a number, not an integer, less than 1, or above
    # the clamp. `or` short-circuits in jq, so a non-number never reaches the
    # `floor`/`<`/`>` comparisons that assume a number.
    #
    # codex-3 (CR round 5): render the timeout's ACTUAL value for a
    # present-but-invalid entry — `.timeout // "unset"` treated `false` as
    # empty and reported it as "unset", hiding the real invalid value even
    # though the entry was still correctly rejected. Reserve "unset" for a
    # genuinely absent key.
    offenders="$(jq -r --argjson clamp "$CODEX_SESSION_END_CLAMP" '
        .hooks.SessionEnd // [] | .[] | .hooks[]
        | select(.type == "command")
        | select((.timeout | type) != "number" or (.timeout | floor) != .timeout or .timeout < 1 or .timeout > $clamp)
        | "\(.command | split(" ") | .[-1] | split("/") | .[-1] | gsub("\"";""))=\(if has("timeout") then (.timeout | tostring) else "unset" end)s"' "$config" 2>/dev/null)"
    offenders_rc=$?
    if [ "$offenders_rc" -ne 0 ]; then
        fail "$label: $config failed to parse while scanning for offending timeouts (jq exit $offenders_rc)"
        return
    fi
    if [ -z "$offenders" ]; then
        pass "$label: all $n SessionEnd hooks declare a positive integer timeout no greater than ${CODEX_SESSION_END_CLAMP}s"
    else
        fail "$label: SessionEnd timeout must be a positive integer no greater than the codex ${CODEX_SESSION_END_CLAMP}s clamp: $(echo "$offenders" | tr '\n' ' ')"
    fi
}

assert_declared_within_clamp "plugin hooks.json" "$PLUGIN_HOOKS"
assert_declared_within_clamp ".codex/hooks.json" "$CODEX_HOOKS"

# --- Case 3: each SessionEnd command returns inside the clamp ----------------
if ! command -v timeout >/dev/null 2>&1; then
    echo "SKIP session-end-command-budget (no GNU coreutils timeout on this runner)"
else
    # Pin the shape of $T before arming any trap or touching the filesystem
    # with it (HIMMEL-2518): this script runs under `set -uo pipefail` without
    # `set -e`, so an mktemp failure alone would NOT abort — T would go on to
    # be used empty, turning "mkdir -p $T/repo" into "mkdir -p /repo" and the
    # EXIT trap into `rm -rf /`. Check the result and the shape FIRST; only a
    # verified absolute path to an existing directory gets a cleanup trap.
    T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-2492-budget.XXXXXX" 2>/dev/null)"
    mktemp_rc=$?
    case "$T" in
        /*) : ;;
        *) T="" ;;
    esac
    if [ "$mktemp_rc" -ne 0 ] || [ -z "$T" ] || [ ! -d "$T" ]; then
        fail "session-end-command-budget: mktemp -d did not return a usable absolute scratch directory (got '${T:-<empty>}')"
    else
        trap 'rm -rf "$T"' EXIT
        # codex-2 (CR round 5): this file deliberately runs without `set -e`
        # (round 1's rationale for $T applies here too), so an unchecked
        # fixture write lets the loop below proceed against missing/partial
        # inputs — the hooks then short-circuit on absent inputs and STILL
        # measure fast, so case 3 passes on a fixture that never existed.
        # The stub `bun` matters most: the file's header states a
        # network-containment guarantee ("a stub bun fronts PATH so the
        # telegram relay can reach no network even if a gate flipped"), and an
        # unchecked write leaves that guarantee unverified. Check each step
        # and fail loudly before the command loop runs; for the stub, also
        # confirm it actually ended up executable, since that is what the
        # containment claim rests on.
        if ! mkdir -p "$T/repo" "$T/stub"; then
            fail "session-end-command-budget: mkdir -p \"$T/repo\" \"$T/stub\" failed"
        elif ! : > "$T/repo/.env"; then
            fail "session-end-command-budget: could not create $T/repo/.env"
        elif ! printf '{"type":"user","timestamp":"2026-09-05T10:00:00.000Z","message":{"role":"user","content":"budget probe"}}\n' \
            > "$T/transcript.jsonl"; then
            fail "session-end-command-budget: could not write $T/transcript.jsonl"
        # Stub bun: records nothing, reaches nothing. Present so an unexpectedly
        # open gate still cannot make a network call out of this suite.
        elif ! printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/bun"; then
            fail "session-end-command-budget: could not write stub bun at $T/stub/bun"
        elif ! chmod +x "$T/stub/bun"; then
            fail "session-end-command-budget: chmod +x on stub bun at $T/stub/bun failed"
        elif [ ! -x "$T/stub/bun" ]; then
            fail "session-end-command-budget: stub bun at $T/stub/bun is not executable after chmod (the network-containment guarantee would not hold)"
        else
            PAYLOAD="$(jq -nc --arg cwd "$T/repo" --arg tx "$T/transcript.jsonl" \
                '{session_id:"himmel-2492-budget", cwd:$cwd, transcript_path:$tx, hook_event_name:"SessionEnd", reason:"other"}')"

            jq -r '.hooks.SessionEnd // [] | .[] | .hooks[] | select(.type == "command") | .command' "$PLUGIN_HOOKS" \
                > "$T/commands"

            # date +%s%N is a GNU coreutils extension: on a platform without it
            # (stock macOS/BSD date), the literal "N" is not substituted and the
            # output ends in a literal "N" rather than digits. Detect that once,
            # up front, and fall back to the existing whole-second measurement
            # rather than computing garbage from a non-numeric value.
            ns_probe="$(date +%s%N)"
            case "$ns_probe" in
                *[0-9]) ns_supported=1 ;;
                *) ns_supported=0 ;;
            esac

            tested_commands=0
            while IFS= read -r command; do
                [ -n "$command" ] || continue
                tested_commands=$((tested_commands + 1))
                # Last whitespace-separated token is the hook script path; its basename
                # is the label.
                label="$(printf '%s' "$command" | awk '{print $NF}' | tr -d '"' | awk -F/ '{print $NF}')"
                if [ "$ns_supported" -eq 1 ]; then
                    t0=$(date +%s%N)
                else
                    t0=$(date +%s)
                fi
                printf '%s' "$PAYLOAD" | timeout $((CHILD_DELAY + 10)) env \
                    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
                    CLAUDE_PROJECT_DIR="$REPO_ROOT" \
                    PATH="$T/stub:$PATH" \
                    TMPDIR="$T" \
                    HIMMEL_STOP_QUEUE_OFF=1 \
                    HIMMEL_WHERE_ARE_WE=0 \
                    HIMMEL_JIRA_NUDGE=0 \
                    TELEGRAM_GROUP_CHAT_ID="" \
                    HIMMEL_WHERE_ARE_WE_TEST_DELAY="$CHILD_DELAY" \
                    JIRA_NUDGE_TEST_DELAY="$CHILD_DELAY" \
                    bash -c "$command" >/dev/null 2>&1
                rc=$?
                if [ "$ns_supported" -eq 1 ]; then
                    elapsed_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
                    budget_msg="${elapsed_ms}ms (< ${CODEX_SESSION_END_CLAMP_MS}ms)"
                    overrun_msg="${elapsed_ms}ms, at or over the codex ${CODEX_SESSION_END_CLAMP_MS}ms clamp"
                    if [ "$elapsed_ms" -lt "$CODEX_SESSION_END_CLAMP_MS" ]; then within_budget=1; else within_budget=0; fi
                else
                    elapsed_s=$(( $(date +%s) - t0 ))
                    budget_msg="${elapsed_s}s (< ${CODEX_SESSION_END_CLAMP}s)"
                    overrun_msg="${elapsed_s}s, at or over the codex ${CODEX_SESSION_END_CLAMP}s clamp"
                    if [ "$elapsed_s" -lt "$CODEX_SESSION_END_CLAMP" ]; then within_budget=1; else within_budget=0; fi
                fi
                if [ "$rc" -ne 0 ]; then
                    fail "SessionEnd $label exited $rc (a SessionEnd hook must never fail teardown)"
                elif [ "$within_budget" -eq 1 ]; then
                    pass "SessionEnd $label returned in $budget_msg despite a ${CHILD_DELAY}s child delay"
                else
                    fail "SessionEnd $label took $overrun_msg"
                fi
            done < "$T/commands"

            if [ "$tested_commands" -lt 1 ]; then
                fail "session-end-command-budget: enumerated zero SessionEnd commands from $PLUGIN_HOOKS (an emptied/truncated/malformed config must not read as green)"
            else
                pass "session-end-command-budget: exercised $tested_commands SessionEnd command(s), not zero"
            fi

            # codex-4: each command above launched a detached (setsid) child that
            # sleeps CHILD_DELAY seconds and only THEN reads its payload out of
            # $T (TMPDIR=$T is inherited). This loop returns almost immediately
            # per command — that speed is the whole point of case 3 — so without
            # this wait the EXIT trap's `rm -rf "$T"` fires ~1s later and deletes
            # the payload out from under children that have not read it yet, and
            # those children keep running ~CHILD_DELAY seconds past the end of
            # this suite (stray sleepers under run-shell-tests.sh). The children
            # are deliberately setsid-detached and cannot be reliably reaped by
            # pid, so a plain sleep past CHILD_DELAY — not pid tracking — is the
            # right shape here. This is why the suite's wall time is ~12s instead
            # of ~0s.
            sleep "$((CHILD_DELAY + 2))"
        fi
    fi
fi

# --- Case 4: every SessionEnd hook script full-body detaches -----------------
# The structural counterpart to case 3, and the one that covers a script with no
# delay seam to inject. `__himmel_detached` is the repo-wide marker for the
# re-exec guard (HIMMEL-636/661).
#
# codex-3: match the GUARD SHAPE, not the bare token — all three scripts also
# name `__himmel_detached` in header comments, so a bare `grep -q
# '__himmel_detached'` would pass a hook that only mentions the token while
# running synchronously, defeating case 4's entire purpose as a structural
# backstop. This pattern is anchored on the actual re-exec-guard comparison
# every script carries: `if [ "${1:-}" != "__himmel_detached" ]; then`.
#
# codex-2 (CR round 3): anchor on the `if` keyword too, not just the
# comparison shape — a line commented out as
# `# if [ "${1:-}" != "__himmel_detached" ]; then` still matched the prior
# pattern (verified directly: `grep -c` on a comment-only fixture returned 1),
# so disabling the guard by commenting it out still passed this case. Requiring
# the line to open with `if` (after only optional leading whitespace) rejects
# a `#`-prefixed line while still matching every real guard, indented or not.
GUARD_SHAPE_PATTERN='^[[:space:]]*if[[:space:]].*"\$\{1:-\}"[[:space:]]*!=[[:space:]]*"__himmel_detached"'

tested_scripts=0
# codex-1 (CR round 3): the basenames case 4 actually checked above, so the
# coverage assertion below can tell a codex-only script apart from one this
# loop already vouched for. Padded with a leading/trailing newline so the
# `case` membership test below can match on a whole-name boundary.
covered_scripts=$'\n'
while IFS= read -r script_path; do
    [ -n "$script_path" ] || continue
    tested_scripts=$((tested_scripts + 1))
    resolved="${script_path/\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    resolved="${resolved/\$\{CLAUDE_PLUGIN_ROOT\}/$PLUGIN_ROOT}"
    label="$(printf '%s' "$resolved" | awk -F/ '{print $NF}')"
    covered_scripts="${covered_scripts}${label}"$'\n'
    if [ ! -f "$resolved" ]; then
        fail "SessionEnd $label: wired script not found at $resolved"
    elif /usr/bin/grep -qE "$GUARD_SHAPE_PATTERN" "$resolved"; then
        pass "SessionEnd $label carries the full-body detach guard"
    else
        fail "SessionEnd $label runs synchronously — it cannot fit the codex ${CODEX_SESSION_END_CLAMP}s clamp"
    fi
done < <(jq -r '.hooks.SessionEnd // [] | .[] | .hooks[] | select(.type == "command") | .command | split(" ") | .[-1] | gsub("\"";"")' "$PLUGIN_HOOKS")

if [ "$tested_scripts" -lt 1 ]; then
    fail "session-end-detach-guard: enumerated zero SessionEnd hook scripts from $PLUGIN_HOOKS (an emptied/truncated/malformed config must not read as green)"
else
    pass "session-end-detach-guard: checked $tested_scripts SessionEnd hook script(s), not zero"
fi

# --- codex-1 (CR round 3): the codex twin is wired, not just declared --------
# Case 2 checks .codex/hooks.json's declared *timeout*; nothing above checked
# that the scripts it wires are actually covered by the detach-guard loop just
# above. A codex-only SessionEnd hook could declare `timeout: 3` and pass
# every case in this suite while running synchronously under the codex lane —
# exactly the failure this suite exists to catch. Fully parsing the codex
# command format is disproportionate here: its `--lifecycle` operand is a
# `+`-separated CHAIN of script basenames, a materially different shape from
# the plugin's "last token is an absolute path", and a second parser for it is
# not what the ticket asked for. Instead, turn the gap into an assertion: every
# basename the codex twin wires for SessionEnd must already be a name case 4
# enumerated from the plugin config above. An uncovered name FAILs loudly,
# naming the gap, rather than letting it pass in silence — so a future
# codex-only SessionEnd hook cannot slip past this suite unnoticed.
if [ -f "$CODEX_HOOKS" ]; then
    # codex-4 (CR round 4): the extraction below can legitimately yield zero
    # lines only if $CODEX_HOOKS declares zero SessionEnd command hooks — it
    # genuinely declares at least one today, so "extracted zero names" must
    # never read as `pass`. Derive the same declared-count jq case 2's
    # assert_declared_within_clamp uses, computed fresh here (not shared
    # across functions) with the same jq-failure hardening the rest of this
    # file applies: capture jq's exit status and validate the count is a real
    # integer before any numeric test.
    codex_declared_count="$(jq '[.hooks.SessionEnd // [] | .[] | .hooks[] | select(.type == "command")] | length' "$CODEX_HOOKS" 2>/dev/null)"
    codex_declared_rc=$?
    if [ "$codex_declared_rc" -ne 0 ] || ! printf '%s' "$codex_declared_count" | grep -qE '^[0-9]+$'; then
        fail "codex session-end coverage: $CODEX_HOOKS did not parse as valid JSON while counting declared SessionEnd command hooks (jq exit $codex_declared_rc)"
    elif [ "$codex_declared_count" -lt 1 ]; then
        fail "codex session-end coverage: expected at least one SessionEnd command hook in $CODEX_HOOKS, found $codex_declared_count"
    else
        # codex-2 (CR round 6): validate PER ENTRY, not globally. A single
        # well-formed --lifecycle entry used to satisfy this whole check for
        # the file, so an ADDITIONAL SessionEnd command whose --lifecycle
        # operand is missing or differently shaped contributed zero names and
        # was silently dropped from coverage. Enumerate each declared command
        # hook on its own (same source array codex_declared_count just
        # counted) and extract its chain independently, so an entry that
        # yields nothing FAILs naming that specific entry rather than hiding
        # behind a global count.
        codex_entries="$(jq -r '
            [.hooks.SessionEnd // [] | .[] | .hooks[] | select(.type == "command")]
            | to_entries[]
            | "\(.key)\t\(.value.command // "")\t\(.value.commandWindows // "")"
        ' "$CODEX_HOOKS" 2>/dev/null)"
        codex_lifecycle_chains=""
        if [ -z "$codex_entries" ]; then
            fail "codex session-end coverage: $CODEX_HOOKS declares $codex_declared_count SessionEnd command hook(s) but none could be enumerated for per-entry --lifecycle extraction"
        else
            while IFS=$'\t' read -r codex_entry_idx codex_entry_cmd codex_entry_cmdwin; do
                [ -n "$codex_entry_idx" ] || continue
                codex_entry_chain="$(printf '%s\n%s\n' "$codex_entry_cmd" "$codex_entry_cmdwin" \
                    | grep -oE -- '--lifecycle[[:space:]]+[^[:space:]"]+' \
                    | awk '{print $2}')"
                if [ -z "$codex_entry_chain" ]; then
                    fail "codex session-end coverage: $CODEX_HOOKS SessionEnd command hook entry #${codex_entry_idx} (command: ${codex_entry_cmd}) produced zero --lifecycle script names (the parser may have stopped matching this entry's shape — an emptied/malformed extraction must not read as green)"
                else
                    codex_lifecycle_chains="${codex_lifecycle_chains}${codex_entry_chain}
"
                fi
            done <<CODEX_ENTRIES
$codex_entries
CODEX_ENTRIES
        fi
        if [ -n "$codex_lifecycle_chains" ]; then
            # codex-4 dedupe: a name can appear from both .command and
            # .commandWindows for the same script (or from more than one
            # SessionEnd entry), which previously reported the same uncovered
            # basename twice. Track what has already been reported the same
            # way covered_scripts tracks membership, and skip a repeat.
            codex_uncovered=""
            codex_uncovered_seen=$'\n'
            while IFS= read -r chain; do
                [ -n "$chain" ] || continue
                old_ifs="$IFS"
                IFS='+'
                for name in $chain; do
                    IFS="$old_ifs"
                    [ -n "$name" ] || continue
                    case "$covered_scripts" in
                        *$'\n'"$name"$'\n'*) : ;;
                        *)
                            case "$codex_uncovered_seen" in
                                *$'\n'"$name"$'\n'*) : ;;
                                *)
                                    codex_uncovered="${codex_uncovered}${name} "
                                    codex_uncovered_seen="${codex_uncovered_seen}${name}"$'\n'
                                    ;;
                            esac
                            ;;
                    esac
                done
                IFS="$old_ifs"
            done <<CODEX_CHAINS
$codex_lifecycle_chains
CODEX_CHAINS
            if [ -n "$codex_uncovered" ]; then
                fail "codex session-end coverage: ${codex_uncovered}not covered by the plugin detach-guard check above — a codex-only SessionEnd hook must extend this suite's coverage before it can be trusted to detach"
            else
                pass "codex session-end coverage: every .codex/hooks.json SessionEnd script is covered by the plugin detach-guard check above"
            fi
        fi
    fi
else
    fail "codex session-end coverage: config not found at $CODEX_HOOKS"
fi

echo "---"
echo "PASSED=$PASSED FAILED=$FAILED"
[ "$FAILED" = 0 ]
