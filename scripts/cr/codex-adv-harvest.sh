#!/usr/bin/env bash
# scripts/cr/codex-adv-harvest.sh -- HIMMEL-2226
#
# WHAT: this is the step-3.1 "codex adversarial-review pass: harvest" fence
# from .claude/commands/pr-check.md, extracted verbatim into a real script.
#
# WHY: /pr-check's bash fences are run inline, via the Bash tool, by the
# orchestrating Claude session. When that session is worktree-isolated
# (Claude Code's own EnterWorktree), the harness statically inspects every
# command line before running it and REFUSES a shape it cannot verify --
# proven (harness v2.1.251) to include ANY shell function definition and any
# `IFS= read` prefix assignment, both of which this fence used
# (harvest_recover_survivor() and `while IFS=$'\t' read -r ...`). That fence
# can therefore never run inline in an isolated session; it has to become a
# script the runbook merely invokes with `bash scripts/cr/codex-adv-harvest.sh`
# (a command shape the harness already accepts). Restrictions that apply to a
# runbook COMMAND LINE do not apply to code inside a script FILE, so functions
# and IFS= read are fine in here.
#
# BEHAVIOR CONTRACT: byte-equivalent to the fence it replaces -- same order,
# same messages on the same streams (stdout vs stderr), same exit codes, same
# env handling, same sidecar-file preservation/removal decisions. The one
# deliberate addition (not present in the fence) is documented below.
#
# Every `"${CLAUDE_PROJECT_DIR:?}"` in the original fence is replaced with a
# SCRIPT_DIR-derived himmel root (this script lives at <himmel>/scripts/cr/,
# so ../.. is the himmel root) -- the same convention scripts/cr/pr-check-
# external.sh already uses. $CLAUDE_PROJECT_DIR is genuinely unset in an
# isolated-session Bash-tool shell, which is the other half of why the
# original fence could not run there unmodified.
#
# Usage: bash scripts/cr/codex-adv-harvest.sh
#   No arguments. Self-contained, exactly like the fence: re-derives $db and
#   $branch, and loads CR_PROFILE from .env itself.
#
# Env:
#   CR_PROFILE            - as read by the fence (none = codex pass skipped).
#   CRITIC_TIMEOUT_SECS    - per-pass timeout budget (default 240, doubled for
#                            the harvest poll budget, exactly as the fence did).
#
# Output:
#   stdout - codex findings (if any), exactly as the fence surfaced them.
#   stderr - all diagnostic/status lines the fence wrote to stderr, PLUS the
#            one deliberate addition below.
#
# DELIBERATE ADDITION (not in the original fence): the fence set the shell
# variable $codex_avail_status but never printed it -- inline, that variable
# stayed live in the orchestrating session's shell for step 4.5's
# `avail --model codex-adv --status "$codex_avail_status"`. A separate script
# cannot leak a shell variable back to its caller, so this script prints it.
# Exactly one line, to stderr, ONLY when the fence would have set the
# variable at all (i.e. a job was actually launched -- CR_PROFILE=none and the
# no-pid-file/dormant cases print nothing, matching the fence never setting
# it there either):
#   codex-adv-status: <ok|unavailable>
#
# Exit: always 0 -- this is a harvest/report step, never a gate itself (matches
# the fence, which never had its own exit code; findings/status flow via
# stdout/stderr for the caller to read).
#
# bash 3.2-safe (Git Bash on Windows and Linux).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
db=$(. "$HIMMEL_ROOT"/scripts/guardrails/lib.sh 2>/dev/null && default_branch || echo main)
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT"/scripts/lib/load-dotenv.sh; load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" CR_PROFILE || true
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT"/scripts/lib/proc-tree.sh
export CR_PROFILE

# HIMMEL-2321 -- self-write codex-adv findings into the CR ledger, mirroring
# coderabbit-review.sh's own self-write (see that script for the fuller
# rationale): the session no longer has to retype a codex-adv finding title
# into a single-quoted shell fence at step 4.5 (an apostrophe in the title
# breaks out of the quotes -- the vulnerability this ticket closes).
#
# Schema: the companion renders one bullet per candidate,
# "- [critical|high|medium|low] <title> (<file>:<line>)" -- the trailing
# "(file:line)" citation is OPTIONAL (harvest_recover_survivor bullets and
# some findings carry none); when absent the row gets empty file/line
# (HIMMEL-1494's citation-less-finding shape, the same convention
# critic-panel.sh already uses). Only lines starting with "- [" are findings;
# any other line (prose, indented continuation) is ignored, matching how the
# harvest header comment already describes this stream (critical/high/medium
# = Critical-or-Important; low = Suggestion, never a blocker).
# Severity mapping (this ticket, HIMMEL-2321): critical/high -> crit,
# medium -> imp, low -> sug.
# ids are minted codex-adv-1, codex-adv-2, ... in stream order -- the same
# mechanical numbering pr-check.md step 3.1/3.2 already documents for the
# session to apply by hand to this exact stream.
#
# Best-effort, same posture as the coderabbit self-write: a ledger-write
# failure warns on stderr and never changes this script's own exit code (it
# is documented as always 0, a harvest/report step, never a gate) or its
# stdout (findings are still printed verbatim by the caller below).
_cxa_ledger_self_write() {
    _cxl_findings="$1"
    [ -n "$_cxl_findings" ] || return 0
    # HIMMEL-2321/HIMMEL-1175 (CR round 4): codex-adv-kickoff.sh now persists
    # the head it launched against alongside the pid/rc/output sidecar files
    # (same "${codex_out}.SUFFIX" convention, .head). That is the one
    # provably-correct stamp - it is resolved at LAUNCH time, before a
    # concurrent commit can land. A missing or unreadable record still means
    # warn-and-skip, never guess (round 3's refusal is now the exception,
    # not the permanent state): a skipped self-write is recoverable, a
    # mis-keyed one silently corrupts gate evidence.
    _cxl_head_file="${codex_out}.head"
    if [ ! -s "$_cxl_head_file" ]; then
        echo "codex-adv-harvest: no launched-head record at $_cxl_head_file - cannot prove which commit this pass reviewed, CR-ledger self-write skipped (HIMMEL-2321/HIMMEL-1175)" >&2
        return 0
    fi
    _cxl_head="$(cat "$_cxl_head_file" 2>/dev/null)" || _cxl_head=""
    if [ -z "$_cxl_head" ]; then
        echo "codex-adv-harvest: launched-head record at $_cxl_head_file is unreadable - CR-ledger self-write skipped (HIMMEL-2321/HIMMEL-1175)" >&2
        return 0
    fi
    _cxl_raw="$(mktemp -t codex-adv-ledger-raw.XXXXXX)" || { echo "codex-adv-harvest: mktemp failed -- CR-ledger self-write skipped (HIMMEL-2321)" >&2; return 0; }
    _cxl_batch="$(mktemp -t codex-adv-ledger-batch.XXXXXX)" || { echo "codex-adv-harvest: mktemp failed -- CR-ledger self-write skipped (HIMMEL-2321)" >&2; rm -f "$_cxl_raw"; return 0; }
    # Findings text is unbounded and reviewer-controlled -- goes through a
    # FILE, never a here-string/heredoc (HIMMEL-2027: a >64KiB here-string
    # wedges Git Bash on Windows).
    printf '%s\n' "$_cxl_findings" > "$_cxl_raw"
    if BRANCH="$branch" HEAD_SHA="$_cxl_head" node -e '
        const e=process.env;
        const lines=require("fs").readFileSync(0,"utf8").split("\n");
        let n=0; const out=[];
        const bulletRe=/^- \[(critical|high|medium|low)\]\s*(.*)$/;
        const citeRe=/\(([^()]+):([0-9]+)\)\s*$/;
        for (const line of lines) {
            const m=line.match(bulletRe);
            if (!m) continue;
            n++;
            const tag=m[1];
            const sev = (tag==="critical"||tag==="high") ? "crit" : tag==="medium" ? "imp" : "sug";
            const c=line.match(citeRe);
            const file = c ? c[1] : "";
            const ln = c ? c[2] : "";
            const row={branch:e.BRANCH, head:e.HEAD_SHA, model:"codex-adv", id:"codex-adv-"+n,
                       severity:sev, file, line:ln, verdict:"", text:line};
            out.push(JSON.stringify(row));
        }
        process.stdout.write(out.length ? out.join("\n")+"\n" : "");
    ' < "$_cxl_raw" > "$_cxl_batch"; then
        if [ -s "$_cxl_batch" ]; then
            bash "$SCRIPT_DIR/ledger-append.sh" finding --batch-file "$_cxl_batch" >&2 \
                || echo "codex-adv-harvest: CR-ledger self-write failed -- findings still printed on stdout, but the ledger is missing them until the next successful run (HIMMEL-2321)" >&2
        fi
    else
        echo "codex-adv-harvest: failed to build CR-ledger batch rows from the harvest output -- self-write skipped (HIMMEL-2321)" >&2
    fi
    rm -f "$_cxl_raw" "$_cxl_batch"
}
branch=$(git branch --show-current)
# HIMMEL-1509: the bounded retry below re-invokes the shared launcher, so it
# must carry the branch launch claim too (the primary render's lease was
# released on its verified-clean exit before any retry can fire).
export RENDER_LEASE_BRANCH="$branch"
git_dir=$(git rev-parse --git-common-dir)
codex_out="${git_dir}/codex-adv-out/${branch}"
codex_pid_file="${codex_out}.pid"
codex_identity_file="${codex_pid_file}.identity"
codex_survivors_file="${codex_pid_file}.survivors"
codex_rc_file="${codex_out}.rc"
codex_cleanup_rc_file="${codex_pid_file}.cleanup-rc"
codex_err_file="${codex_out}.err"  # companion stderr, kept for debugging -- see kickoff fence (glm-3, CR round 2)
codex_findings=""; codex_rc=0; codex_avail_status=""
if [ "${CR_PROFILE:-}" = "none" ]; then
    : # claude-only -- codex adversarial pass also skipped under none (kickoff fence never launched a job).
elif [ ! -s "$codex_pid_file" ]; then
    # No job was launched -- companion was absent at kickoff time (already
    # reported there with "codex adversarial pass skipped (codex not
    # configured)"), OR the pass is dormant (HIMMEL-1957): the same tested
    # completion-check single source of truth recognizes the dormant
    # sentinel and reports it explicitly (HIMMEL-2056) -- never a retry,
    # never a ledger row.
    [ "$(bash "$HIMMEL_ROOT"/scripts/cr/codex-adv-completion-check.sh 0 "$codex_out" "$codex_err_file" 2>/dev/null | sed -n 's/^status=//p')" = "absent" ] && echo "codex-adv: dormant/absent (HIMMEL-1957) -- not launched, no retry"
    : # nothing to harvest.
else
    codex_pid=$(cat "$codex_pid_file")
    codex_identity=$(cat "$codex_identity_file" 2>/dev/null) || codex_identity=""
    # 10# forces base 10: `$(( ))` reads a LEADING ZERO as octal, so
    # CRITIC_TIMEOUT_SECS=08 would die here with "value too great for base",
    # leave codex_to empty, and surface as a wrong cause for a value that
    # looks perfectly configured. Same fix critic-panel.sh applies to its
    # own copy of this variable.
    # Normalize BEFORE the 10# arithmetic: a non-numeric value (e.g. "abc")
    # dies the `$(( ))` outright, and a negative or zero value yields an
    # instant timeout -- neither matches the documented contract
    # (critic-panel.sh falls back to 240 on the same bad-value cases).
    codex_timeout=${CRITIC_TIMEOUT_SECS:-240}
    case "$codex_timeout" in ''|*[!0-9]*) codex_timeout=240 ;; esac
    [ "$codex_timeout" -gt 0 ] || codex_timeout=240
    codex_to=$(( 10#$codex_timeout * 2 ))
    # HIMMEL-1474 r4/r6b: rc is the first liveness fact. Only when no rc
    # exists may the launch identity be probed; break only on a confirmed
    # mismatch/exit, not when the identity probe is unavailable.
    waited=0
    while [ ! -s "$codex_rc_file" ]; do
        identity_rc=0
        proc_tree_process_identity_matches "$codex_pid" "$codex_identity" || identity_rc=$?
        [ "$identity_rc" -eq 1 ] && break
        [ "$waited" -ge "$codex_to" ] && break
        sleep 5
        waited=$((waited + 5))
    done
    harvest_timed_out=0
    harvest_live_unreaped=0
    harvest_survivors=0
    harvest_cleanup_unverified=0
    harvest_recover_survivor() {
        local survivor_pid="${1}" survivor_identity="${2}" identity_rc
        if [ -z "$survivor_pid" ] || [ -z "$survivor_identity" ]; then
            echo "codex adversarial pass cleanup unverified: survivor record is malformed" >&2
            return 1
        fi
        identity_rc=0
        proc_tree_process_identity_matches "$survivor_pid" "$survivor_identity" || identity_rc=$?
        if [ "$identity_rc" -eq 1 ]; then
            if proc_tree_process_alive "$survivor_pid"; then
                echo "codex adversarial pass cleanup unverified: survivor pid $survivor_pid has an identity mismatch; no signal sent" >&2
                return 1
            fi
            return 0
        fi
        if [ "$identity_rc" -ne 0 ]; then
            echo "codex adversarial pass cleanup unverified: survivor pid $survivor_pid cannot be identity-verified (identity rc=$identity_rc); no signal sent" >&2
            return 1
        fi
        kill -TERM "$survivor_pid" 2>/dev/null || true
        sleep 1
        identity_rc=0
        proc_tree_process_identity_matches "$survivor_pid" "$survivor_identity" || identity_rc=$?
        if [ "$identity_rc" -eq 0 ]; then
            kill -KILL "$survivor_pid" 2>/dev/null || true
            sleep 1
            identity_rc=0
            proc_tree_process_identity_matches "$survivor_pid" "$survivor_identity" || identity_rc=$?
        fi
        if [ "$identity_rc" -eq 1 ]; then
            proc_tree_process_alive "$survivor_pid" || return 0
        fi
        echo "codex adversarial pass cleanup unverified: survivor pid $survivor_pid remains live or unverifiable after recovery (identity rc=$identity_rc)" >&2
        return 1
    }
    if [ ! -s "$codex_rc_file" ] && [ "$waited" -ge "$codex_to" ]; then
        # Re-check rc FIRST immediately before the identity-guarded signal.
        # proc_tree_terminate returns 2 without signaling when the identity
        # probe cannot confirm anything either way (still may be live --
        # needs its recovery sidecars); 3 when the probe CONFIRMS the
        # leader already exited/was recycled before any signal was sent
        # (HIMMEL-1501: fall through to the ordinary exited path below
        # instead of the live-but-unreaped one); rc 1 means escalated
        # cleanup left survivors.
        if [ ! -s "$codex_rc_file" ]; then
            proc_tree_terminate "$codex_pid" 1 "$codex_identity"
            terminate_rc=$?
            if [ "$terminate_rc" -eq 2 ]; then
                harvest_live_unreaped=1
            elif [ "$terminate_rc" -ne 3 ]; then
                harvest_timed_out=1
                [ "$terminate_rc" -eq 1 ] && harvest_survivors=1
            fi
        fi
    fi
    if [ "$harvest_live_unreaped" -eq 1 ]; then
        echo "codex adversarial pass is live but unreaped: cleanup refused for pid/group $codex_pid (rc=2); preserving recovery sidecars $codex_pid_file and $codex_identity_file because no signal was sent -- continuing without it" >&2
        codex_findings=""; codex_rc=2; codex_avail_status="unavailable"
    elif [ "$harvest_timed_out" -eq 1 ]; then
        if [ "$harvest_survivors" -eq 1 ]; then
            echo "codex adversarial pass timed out with survivors after escalated cleanup -- sidecars preserved for recovery: $codex_pid_file and $codex_identity_file; continuing without it" >&2
        else
            echo "codex adversarial pass timed out (>${codex_to}s after the panel finished; stderr: $codex_err_file) -- continuing without it" >&2
        fi
        codex_findings=""; codex_rc=124; codex_avail_status="unavailable"
    else
        # Node has exited (or its identity no longer matches), but the wrapper
        # subshell writes $codex_rc_file a BEAT LATER -- after the shared
        # launcher's internal node wait returns -- so a successful run landing in
        # that window must not be discarded as "no recorded status"
        # (codex-1, CR round 2, HIMMEL-1407: this was a real race, not a
        # theoretical one). Poll briefly for the rc file to appear before
        # falling through to the fail-open no-status branch.
        rc_wait=0
        while [ ! -s "$codex_rc_file" ] && [ "$rc_wait" -lt 10 ]; do
            sleep 1
            rc_wait=$((rc_wait + 1))
        done
        if [ -s "$codex_rc_file" ]; then
            codex_rc=$(cat "$codex_rc_file")
            case "$codex_rc" in
                0)
                    # HIMMEL-1420: rc=0 alone is NOT sufficient evidence of a
                    # clean pass -- classify via the tested completion check
                    # (scripts/cr/codex-adv-completion-check.sh /
                    # test-codex-adv-completion-check.sh), whose header
                    # comment carries the current contract (hardened across
                    # three CR rounds against the real companion source --
                    # do not re-derive it here).
                    cac_check=$(bash "$HIMMEL_ROOT"/scripts/cr/codex-adv-completion-check.sh 0 "$codex_out" "$codex_err_file" 2>/dev/null)
                    # $? here is the command substitution's own status (codex-adv-completion-
                    # check.sh's rc), captured separately from cac_check's stdout above; folding
                    # into `if cmd; then` would lose that output.
                    # shellcheck disable=SC2181
                    if [ $? -eq 0 ]; then
                        codex_findings=$(cat "$codex_out" 2>/dev/null)  # success -- findings (if any) captured
                        codex_avail_status="ok"
                    else
                        cac_err_tail=$(printf '%s\n' "$cac_check" | sed -n 's/^err_tail=//p')
                        echo "codex adversarial pass rc=0 with no 'Verdict:' marker on stdout -- silent death suspected (err tail: ${cac_err_tail:-<none>}; stderr: $codex_err_file) -- taking one bounded retry" >&2
                        # ONE bounded retry (HIMMEL-1420, ticket-sanctioned).
                        # Synchronous here, bounded by the same $codex_timeout
                        # the async kickoff used -- that async slot is already
                        # spent, so the retry runs foreground in this fence.
                        # This fence is independent of the kickoff fence (no
                        # shared shell state across bash-tool calls), so
                        # $companion must be RE-resolved here -- same glob +
                        # cygpath logic as the kickoff fence (HIMMEL-741c).
                        companion=""
                        for _rc_c in "$HOME/.claude/plugins/cache/openai-codex/codex/"*/scripts/codex-companion.mjs; do
                            [ -f "$_rc_c" ] && companion="$_rc_c"
                        done
                        if [ -n "$companion" ] && command -v cygpath >/dev/null 2>&1; then
                            companion=$(cygpath -m "$companion")
                        fi
                        if [ -z "$companion" ]; then
                            echo "codex adversarial pass retry skipped -- companion path could not be re-resolved in this fence -- recording unavailable" >&2
                            codex_findings=""; codex_avail_status="unavailable"
                        else
                            codex_retry_pid_file="${codex_pid_file}.retry"
                            codex_retry_identity_file="${codex_retry_pid_file}.identity"
                            codex_retry_survivors_file="${codex_retry_pid_file}.survivors"
                            codex_retry_cleanup_rc_file="${codex_retry_pid_file}.cleanup-rc"
                            rm -f "$codex_retry_pid_file" "$codex_retry_identity_file" "$codex_retry_survivors_file" "$codex_retry_cleanup_rc_file"
                            : > "$codex_out"; : > "$codex_err_file"
                            # Shared launcher owns the real node pid, starts the
                            # Layer B client-lease heartbeat, and preserves the
                            # existing bounded tree-kill behavior without relying
                            # on an external timeout binary.
                            bash "$HIMMEL_ROOT"/scripts/cr/run-codex-adversarial.sh "$companion" "$db" "$codex_out" "$codex_err_file" "$codex_retry_pid_file" "$codex_timeout" "$codex_retry_cleanup_rc_file"
                            codex_retry_rc=$?
                            codex_retry_cleanup_rc=""
                            if [ -s "$codex_retry_cleanup_rc_file" ]; then
                                codex_retry_cleanup_rc=$(cat "$codex_retry_cleanup_rc_file")
                            fi
                            if [ "$codex_retry_cleanup_rc" = "0" ]; then
                                rm -f "$codex_retry_pid_file" "$codex_retry_identity_file" "$codex_retry_survivors_file" "$codex_retry_cleanup_rc_file"
                            else
                                echo "codex adversarial pass retry cleanup unverified (rc=${codex_retry_cleanup_rc:-missing}) -- preserving recovery sidecars: $codex_retry_pid_file, $codex_retry_identity_file, and $codex_retry_survivors_file" >&2
                            fi
                            cac_retry_check=$(bash "$HIMMEL_ROOT"/scripts/cr/codex-adv-completion-check.sh "$codex_retry_rc" "$codex_out" "$codex_err_file" 2>/dev/null)
                            # $? here is the command substitution's own status (codex-adv-
                            # completion-check.sh's rc), captured separately from cac_retry_check's
                            # stdout above; folding into `if cmd; then` would lose that output.
                            # shellcheck disable=SC2181
                            if [ $? -eq 0 ]; then
                                codex_findings=$(cat "$codex_out" 2>/dev/null)
                                codex_avail_status="ok"
                                echo "codex adversarial pass retry succeeded -- 'Verdict:' marker present" >&2
                            else
                                cac_retry_err_tail=$(printf '%s\n' "$cac_retry_check" | sed -n 's/^err_tail=//p')
                                echo "codex adversarial pass retry ALSO failed (rc=$codex_retry_rc; err tail: ${cac_retry_err_tail:-<none>}; stderr: $codex_err_file) -- recording unavailable, not clean" >&2
                                codex_findings=""; codex_avail_status="unavailable"
                            fi
                        fi
                    fi
                    ;;
                *)
                    echo "codex adversarial pass failed (rc=$codex_rc; stderr: $codex_err_file) -- continuing without it" >&2
                    codex_findings=""; codex_avail_status="unavailable"
                    ;;
            esac
        else
            # rc file genuinely never appeared (killed pre-write, or a
            # crash) -- same fail-open "continuing without it" outcome.
            echo "codex adversarial pass exited without a recorded status (waited ${rc_wait}s; stderr: $codex_err_file) -- continuing without it" >&2
            codex_findings=""; codex_rc=1; codex_avail_status="unavailable"
        fi
    fi
    # The launcher publishes cleanup independently because a nonzero companion
    # rc remains the process exit status even when cleanup also failed.
    harvest_cleanup_rc=""
    if [ ! -s "$codex_rc_file" ]; then
        harvest_cleanup_unverified=1
        echo "codex adversarial pass launcher status missing -- preserving recovery sidecars until both launcher and cleanup status are verified: $codex_pid_file and $codex_identity_file" >&2
    else
        if [ -s "$codex_cleanup_rc_file" ]; then
            harvest_cleanup_rc=$(cat "$codex_cleanup_rc_file")
        fi
        if [ "$harvest_cleanup_rc" = "3" ]; then
            if [ ! -e "$codex_survivors_file" ]; then
                harvest_cleanup_unverified=1
            else
                while IFS=$'\t' read -r survivor_pid survivor_identity || [ -n "$survivor_pid$survivor_identity" ]; do
                    if ! harvest_recover_survivor "$survivor_pid" "$survivor_identity"; then
                        harvest_cleanup_unverified=1
                        break
                    fi
                done < "$codex_survivors_file"
            fi
        elif [ "$harvest_cleanup_rc" != "0" ]; then
            harvest_cleanup_unverified=1
        fi
        if [ "$harvest_cleanup_unverified" -eq 1 ]; then
            echo "codex adversarial pass cleanup unverified (rc=${harvest_cleanup_rc:-missing}) -- preserving recovery sidecars: $codex_pid_file, $codex_identity_file, and $codex_survivors_file" >&2
        fi
    fi
    # $codex_err_file is intentionally NOT removed here (glm-3, CR round 2)
    # -- companion stderr stays on disk for debugging. Jobs that may still be
    # live keep their recovery handles; completed/terminated jobs are cleaned.
    if [ "$harvest_live_unreaped" -eq 0 ] && [ "$harvest_survivors" -eq 0 ] && [ "$harvest_cleanup_unverified" -eq 0 ]; then
        rm -f "$codex_pid_file" "$codex_identity_file" "$codex_survivors_file" "$codex_rc_file" "$codex_cleanup_rc_file"
    fi
fi
# HIMMEL-2321: self-write BEFORE printing -- a ledger failure only warns (see
# _cxa_ledger_self_write above), it never withholds the findings this script
# has always printed.
_cxa_ledger_self_write "$codex_findings"
# Surface findings (if any) so they flow into the step-3 adjudication prepend.
[ -n "$codex_findings" ] && printf '%s\n' "$codex_findings"
# HIMMEL-1219 round 3 -- this fence no longer accumulates a candidate count
# onto the prior-blocking file. codex findings are BLOCKING CANDIDATES
# (critical/high/medium severity -- the Important-or-worse tier); like the
# panel's, they flow into step 3.2 phase A, where the session adjudicates
# each `[codex-adv-N]` candidate and writes the VERDICT line the
# conservation count is derived from. (When you adjudicate in 3.2 phase A,
# treat a codex `- [critical|high|medium] ...` line as a Critical/Important
# candidate and a `- [low] ...` line as a Suggestion, which is never a
# blocker and needs no verdict for conservation.)

# HIMMEL-2226 deliberate addition -- see header comment. codex_avail_status is
# non-empty only when a job was actually launched (the `else` branch above);
# CR_PROFILE=none and the no-pid-file/dormant paths never set it, matching
# the fence never surfacing anything there either.
[ -n "$codex_avail_status" ] && echo "codex-adv-status: $codex_avail_status" >&2

exit 0
