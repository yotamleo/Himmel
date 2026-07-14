#!/usr/bin/env bash
# scripts/codex/codex-arg-filter.sh - the codex-exec passthrough-args filter
# (HIMMEL-999), extracted from dispatch-codex-exec.sh so the exec and WSL
# dispatchers share ONE decision source (HIMMEL-195: never two prose-synced
# copies of a security filter).
#
# Contract:
#   Caller MAY set (before calling; defaults preserve the exec lane's
#   byte-identical messages):
#     CAF_SELF_NAME       message prefix (default dispatch-codex-exec.sh)
#     CAF_SCOPE_NOUN      "worktree" | "clone" (default worktree)
#     CAF_CONTAINER_FLAG  "--worktree" | "--clone" (default --worktree)
#     CAF_ADDDIR_HINT     --add-dir refusal hint (default names the ACL preflight)
#   codex_filter_passthrough_args "$@"
#     rc=0: CAF_NEW_ARGS (array), CAF_HAVE_MODEL, CAF_HAVE_SANDBOX,
#           CAF_REASONING_EFFORT are set.
#     rc=1: a refusal was printed to stderr; caller exits 2.
#
# Bash 3.2 safe.
# shellcheck disable=SC2034 # CAF_* globals are the sourced function output contract.

codex_filter_passthrough_args() {
    local self="${CAF_SELF_NAME:-dispatch-codex-exec.sh}"
    local noun="${CAF_SCOPE_NOUN:-worktree}"
    local cflag="${CAF_CONTAINER_FLAG:---worktree}"
    local adddir_hint="${CAF_ADDDIR_HINT:-the ACL preflight covers only the dispatched worktree}"

    CAF_HAVE_MODEL=0
    CAF_HAVE_SANDBOX=0
    CAF_REASONING_EFFORT=""
    CAF_NEW_ARGS=()

    local a prev="" rev_val
    # codex-adv r5/r6: 'codex exec resume' (esp. resume --all) selects
    # sessions ACROSS cwds. Refuse the bare tokens anywhere.
    for a in "$@"; do
        case "$a" in
            resume|review) echo "$self: 'codex exec $a' refused - the lane dispatches fresh runs only (resume/review can escape the preflighted $noun)" >&2; return 1 ;;
        esac
    done

    for a in "$@"; do
        case "$prev" in
            --sandbox|-s)
                case "$a" in
                    danger-full-access) echo "$self: '$prev danger-full-access' refused - the lane guard requires a sandboxed run" >&2; return 1 ;;
                esac
                ;;
            --reasoning-effort)
                case "$a" in
                    none|low|medium|high|xhigh|max) CAF_REASONING_EFFORT="$a" ;;
                    *) echo "$self: --reasoning-effort value '$a' not in none|low|medium|high|xhigh|max" >&2; return 1 ;;
                esac
                prev="$a"
                continue
                ;;
        esac
        # ALLOW-LIST (codex-adv final round): deny-listing clap's option
        # surface is unwinnable. Specific deny cases stay for their
        # actionable messages; EVERYTHING ELSE dash-prefixed is refused.
        case "$a" in
            --reasoning-effort) prev="$a"; continue ;;
            --reasoning-effort=*)
                rev_val="${a#--reasoning-effort=}"
                case "$rev_val" in
                    none|low|medium|high|xhigh|max) CAF_REASONING_EFFORT="$rev_val" ;;
                    *) echo "$self: --reasoning-effort value '$rev_val' not in none|low|medium|high|xhigh|max" >&2; return 1 ;;
                esac
                prev="$a"
                continue
                ;;
            --background|--background=*) echo "$self: --background refused (upstream silent-death, HIMMEL-741) - use the default wait behavior + companion-liveness.sh" >&2; return 1 ;;
            -C*|--cd|--cd=*) echo "$self: workspace-redirect flag '$a' refused - the wrapper owns the $noun (pass it via $cflag)" >&2; return 1 ;;
            --add-dir|--add-dir=*) echo "$self: --add-dir refused - $adddir_hint" >&2; return 1 ;;
            --dangerously-bypass-approvals-and-sandbox|--yolo) echo "$self: sandbox-bypass flag '$a' refused - the lane guard requires a sandboxed run" >&2; return 1 ;;
            --sandbox=danger-full-access|-s=danger-full-access|-sdanger-full-access) echo "$self: sandbox danger-full-access refused - the lane guard requires a sandboxed run" >&2; return 1 ;;
            -c*|--config|--config=*) echo "$self: config-override flag '$a' refused - -c/--config can widen sandbox_permissions past the lane guard" >&2; return 1 ;;
            -p*|--profile|--profile=*) echo "$self: profile flag '$a' refused - a config profile can widen the sandbox past the lane guard" >&2; return 1 ;;
            --dangerously-bypass-hook-trust|--ignore-rules) echo "$self: trust-bypass flag '$a' refused - the lane guard does not vet hook sources or waive execpolicy rules" >&2; return 1 ;;
            --enable|--enable=*|--disable|--disable=*) echo "$self: feature flag '$a' refused - config-equivalent (can disable the hooks feature past the lane guard)" >&2; return 1 ;;
            -o*|--output-last-message|--output-last-message=*) echo "$self: output-file flag '$a' refused - a CLI-level write to a caller-supplied path can escape the $noun" >&2; return 1 ;;
            --model|--model=*|-m|-m?*) CAF_HAVE_MODEL=1 ;;
            --sandbox|--sandbox=*|-s|-s=*|-s?*) CAF_HAVE_SANDBOX=1 ;;
            --json) ;;  # structured output - inert
            -*) echo "$self: flag '$a' is not in the lane allow-list (--model/-m, --sandbox/-s safe values, --reasoning-effort, --json) - refused" >&2; return 1 ;;
        esac
        CAF_NEW_ARGS+=("$a")
        prev="$a"
    done
    # Trailing bare --reasoning-effort (nothing follows): without this guard
    # the flag vanishes silently and the run proceeds at default effort.
    if [ "$prev" = "--reasoning-effort" ]; then
        echo "$self: --reasoning-effort requires a value (none|low|medium|high|xhigh|max)" >&2
        return 1
    fi
    return 0
}
