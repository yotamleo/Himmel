# shellcheck shell=bash
# runtime-preflight.sh — the ONE place himmel states its runtime policy, and the
# check every supported production/test entry point runs before it commits to a
# long or unattended piece of work (HIMMEL-1991, RAM program P1-5; extends
# HIMMEL-1986 from "file it" to "gate it").
#
# WHY: measured on OVERLORD8 2026-08-20/21 — .nvmrc pins Node 24 while the live
# shell runs 26.7.0, no nvm anywhere on PATH (C:\Program Files\nodejs is a plain
# directory, not an NVM link), Bun 1.4.0 from a canary build, and a bare `bash`
# from a Windows process resolves to C:\Windows\System32\bash.exe (the WSL
# launcher) before Git Bash. None of that is proof any runtime leaks kernel
# objects — it is a retry/churn amplifier, and it was rediscovered by hand every
# session because nothing on the way in ever said it out loud.
#
# RUNTIME POLICY (change it HERE; entry points never restate it):
#   node — the running major MUST equal the .nvmrc pin.
#   npm  — MUST be invocable wherever node is (detection reused from
#          preflight-adopter.sh; only the wording differs).
#   bun  — release builds only. A canary build is not reproducible and is not
#          what any lockfile or CI run was validated against.
#   bash — must NOT resolve, in WINDOWS PATH order, to the WSL launcher or a
#          WindowsApps 0-byte alias. Same known-bad set as
#          scripts/hooks/run-hook-with-bash.js (HIMMEL-1992); this file never
#          SPAWNS a bare bash, it only asks what one would resolve to.
#
# SEVERITY (deliberate, and the reason this is not a hard gate on day one):
#   default              advisory — print the findings LOUDLY, return 0.
#   HIMMEL_RUNTIME_PREFLIGHT=strict   refuse: same findings, return 1.
#   HIMMEL_RUNTIME_PREFLIGHT=0        skip entirely (CI images, adopters).
# The ticket allows "fail loudly OR advisory-then-refuse behind a flag". It is
# advisory-first because every finding above is TRUE on the machine this landed
# on: a default-strict gate would have bricked every test run, cadence arm and
# lane dispatch the moment it merged, which is not a gate, it is an outage. Flip
# the flag once the runtime is aligned. Nothing here ever switches a runtime.
#
# FUNCTIONS ONLY when sourced — no side effects at source time. Also runnable
# directly for an ad-hoc read:  bash scripts/lib/runtime-preflight.sh [<label>]
#
# Verdict lines (stdout), nothing when clean — same shape as
# dependency-readiness.sh's READY-DRIFT lines so both are greppable:
#   RUNTIME-DRIFT node-major <running> <pin>
#   RUNTIME-DRIFT node-missing
#   RUNTIME-DRIFT node-unreadable <what --version said>
#   RUNTIME-DRIFT pin-unreadable <.nvmrc path>   (present but not a numeric major)
#   RUNTIME-DRIFT npm-missing
#   RUNTIME-DRIFT npm-uncheckable <detector path>
#   RUNTIME-DRIFT bun-canary <version>
#   RUNTIME-DRIFT bun-unreadable <what the version probe said>
#   RUNTIME-DRIFT bash-wsl-first <path>
#   RUNTIME-DRIFT bash-uncheckable <probe>
#   RUNTIME-GUIDANCE nvm-absent          (never a refusal on its own)
#
# Test seams:
#   RUNTIME_PREFLIGHT_NVMRC   pin file (default: <repo>/.nvmrc)
#   RUNTIME_PREFLIGHT_WHERE   the Windows PATH-order probe (default: where.exe)
#   RUNTIME_PREFLIGHT_OS      uname override, so the Windows-only bash check is
#                             exercisable from any host

_runtime_preflight_dir() {
    cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd
}

# _runtime_preflight_major <string> -> the major, or EMPTY when the string is
# not exactly `<major>[.<minor>[.<patch>]]` (optionally v-prefixed).
#
# Anchored end to end, every dot followed by real digits: `24`, `v24`, `24.9.0`
# parse; `24foo`, `24.`, `24...`, `24.1.2.3`, `v24-corrupt` and `lts/iron` come
# back empty. ONE parser for both sides of the comparison (panel r1 codex-3,
# r2 codex-2, r4 codex-1) — reading a major out of a string that is not a
# version invents a fact on the input side, and matches the pin against garbage
# on the runtime side.
_runtime_preflight_major() {
    printf '%s' "$1" \
        | sed -n 's/^[[:space:]]*[vV]\{0,1\}\([0-9][0-9]*\)\(\.[0-9][0-9]*\)\{0,2\}[[:space:]]*$/\1/p'
}

_runtime_preflight_nvmrc() {
    printf '%s' "${RUNTIME_PREFLIGHT_NVMRC:-$(_runtime_preflight_dir)/../../.nvmrc}"
}

# The pinned major, or empty when there is no .nvmrc (a legitimate skip) or when
# it holds something this file cannot compare (the caller turns THAT into a
# finding — see pin-unreadable below).
runtime_preflight_pin() {
    local nvmrc
    nvmrc="$(_runtime_preflight_nvmrc)"
    [ -f "$nvmrc" ] || return 0
    _runtime_preflight_major "$(sed -n '1p' "$nvmrc" | tr -d '\r')"
}

# The known-bad Windows bash targets, kept byte-identical to
# isKnownBadWindowsBash() in scripts/hooks/run-hook-with-bash.js. The suite pins
# that coupling with a canary case rather than trusting this comment.
RUNTIME_PREFLIGHT_BAD_BASH='/windows/system32/bash.exe /windows/sysnative/bash.exe /windowsapps/bash.exe'

runtime_preflight_scan() {
    local drift=0 pin cur cur_major node_bin bun_ver where_bin first_bash low bad

    # --- node ---------------------------------------------------------------
    node_bin="$(command -v node 2>/dev/null || true)"
    pin="$(runtime_preflight_pin)"
    if [ -z "$node_bin" ]; then
        echo "RUNTIME-DRIFT node-missing"
        drift=1
    elif [ -z "$pin" ] && [ -f "$(_runtime_preflight_nvmrc)" ]; then
        # A .nvmrc that exists but does not name a numeric major (an alias like
        # `lts/iron`, or a typo) leaves the MANDATORY node rule unenforceable —
        # and skipping it would let strict mode pass without checking node at
        # all, the last member of the silent-pass family (panel r6 codex-1).
        # No .nvmrc at all is a different thing entirely: nothing was pinned, so
        # there is nothing to compare, and that stays a clean skip.
        echo "RUNTIME-DRIFT pin-unreadable $(_runtime_preflight_nvmrc)"
        drift=1
    elif [ -n "$pin" ]; then
        cur="$("$node_bin" --version 2>/dev/null | tr -d '\r')"
        cur_major="$(_runtime_preflight_major "$cur")"
        if [ -z "$cur_major" ]; then
            # A node that will not say what it is cannot be compared to the pin,
            # and a GATE that shrugs at that is not a gate (panel r1 codex-1):
            # the whole point is that nothing runs unverified.
            echo "RUNTIME-DRIFT node-unreadable ${cur:-<no output>}"
            drift=1
        elif [ "$cur_major" != "$pin" ]; then
            echo "RUNTIME-DRIFT node-major $cur $pin"
            drift=1
            # Guidance, not a finding: the drift is only actionable in place if
            # a version manager exists to act with.
            if ! command -v nvm >/dev/null 2>&1 && ! command -v volta >/dev/null 2>&1 \
                && ! command -v fnm >/dev/null 2>&1 && [ ! -d "${NVM_DIR:-${HOME:-}/.nvm}" ]; then
                echo "RUNTIME-GUIDANCE nvm-absent"
            fi
        fi
    fi

    # --- npm (detection reused, wording ours) -------------------------------
    # shellcheck source=preflight-adopter.sh
    # shellcheck disable=SC1091
    . "$(_runtime_preflight_dir)/preflight-adopter.sh" 2>/dev/null || true
    if ! declare -F preflight_check_npm_invocable >/dev/null 2>&1; then
        # The npm rule is MANDATORY, so an unreachable detector is a finding, not
        # a silent skip (panel r1 codex-2) — otherwise a missing/unreadable
        # sibling lets strict mode pass without ever checking npm.
        echo "RUNTIME-DRIFT npm-uncheckable $(_runtime_preflight_dir)/preflight-adopter.sh"
        drift=1
    elif ! preflight_check_npm_invocable 2>/dev/null; then
        echo "RUNTIME-DRIFT npm-missing"
        drift=1
    fi

    # --- bun ----------------------------------------------------------------
    if command -v bun >/dev/null 2>&1; then
        bun_ver="$( { bun --revision 2>/dev/null || bun --version 2>/dev/null; } | head -1 | tr -d '\r')"
        case "$bun_ver" in
            *canary*|*CANARY*) echo "RUNTIME-DRIFT bun-canary $bun_ver"; drift=1 ;;
            *)
                # "Release builds only" is asserted POSITIVELY (panel r4
                # codex-2): strip the optional `+<build hash>` that --revision
                # appends, and what remains must parse as a real version — the
                # SAME parser the pin and node use, so `1..4` and `.` are
                # refused like every other not-a-version (panel r5 codex-1).
                if [ -z "$(_runtime_preflight_major "${bun_ver%%+*}")" ]; then
                    echo "RUNTIME-DRIFT bun-unreadable ${bun_ver:-<no output>}"
                    drift=1
                fi ;;
        esac
    fi

    # --- bash (Windows only) ------------------------------------------------
    # Asking `command -v bash` from inside Git Bash always answers Git Bash and
    # would sweep clean: the resolution that bites is the one a WINDOWS process
    # (a cadence .bat, a scheduler runner) performs, so probe Windows PATH order.
    # SCOPE: this answers for the process tree THIS entry point will spawn — its
    # own inherited Windows PATH. A scheduler-launched .bat starts from the
    # machine PATH, where the order can differ; that path is already covered
    # structurally by run-hook-with-bash.js, which RESOLVES a concrete bash
    # instead of trusting order (HIMMEL-1992). This check is the belt to that
    # brace, not a replacement for it.
    case "${RUNTIME_PREFLIGHT_OS:-$(uname -s 2>/dev/null || echo unknown)}" in
        MINGW*|MSYS*|CYGWIN*|Windows*)
            where_bin="${RUNTIME_PREFLIGHT_WHERE:-where.exe}"
            first_bash="$("$where_bin" bash 2>/dev/null | head -1 | tr -d '\r')"
            if [ -z "$first_bash" ]; then
                # The probe is missing, errored, or found no bash on the Windows
                # PATH at all. Either way the ORDER is unknown, and treating
                # unknown as clean is the same silent pass r1 closed for npm
                # (panel r3 codex-1).
                echo "RUNTIME-DRIFT bash-uncheckable $where_bin"
                drift=1
            else
                # tr '\134': the octal escape for a backslash. A literal '\\'
                # here reads to shellcheck as an attempted quote escape (SC1003).
                low="$(printf '%s' "$first_bash" | tr '\134' '/' | tr '[:upper:]' '[:lower:]')"
                for bad in $RUNTIME_PREFLIGHT_BAD_BASH; do
                    case "$low" in
                        *"$bad") echo "RUNTIME-DRIFT bash-wsl-first $first_bash"; drift=1; break ;;
                    esac
                done
            fi
            ;;
    esac

    [ "$drift" -eq 0 ]
}

# runtime_preflight [<entry-point label>] — what an entry point calls.
# Prints the findings + the remedy banner to STDERR (so a caller's stdout stays
# machine-readable), and returns per the severity policy above.
runtime_preflight() {
    local label="${1:-himmel}" mode findings
    mode="${HIMMEL_RUNTIME_PREFLIGHT:-advisory}"
    [ "$mode" = "0" ] && return 0

    findings="$(runtime_preflight_scan)" && return 0

    {
        printf '\n'
        printf '=== runtime preflight: %s ===\n' "$label"
        # Two fields, then THE REST (panel r3 codex-2): a detector path or a
        # version string can contain spaces (`C:\Program Files\...`), and
        # splitting into fixed fields printed only its first token. node-major
        # is the one line with two space-free values, so it splits $_rest itself.
        printf '%s\n' "$findings" | while IFS=' ' read -r _kind _what _rest; do
            case "$_what" in
                node-major)    printf '  node %s is running, .nvmrc pins %s — hooks, the Jira CLI and the lane suites all run UNPINNED here\n' "${_rest%% *}" "${_rest##* }" ;;
                node-missing)  printf '  no node on PATH — every node-backed hook and CLI in this repo is inert\n' ;;
                node-unreadable) printf '  node is on PATH but node --version answered %s — nothing can be compared to the pin\n' "$_rest" ;;
                pin-unreadable) printf '  %s does not name a numeric major, so the node rule cannot be enforced — aliases like lts/iron are not resolvable here; write the major\n' "$_rest" ;;
                npm-missing)   printf '  node is present but npm is not — lockfile/audit gates and dist builds cannot run\n' ;;
                npm-uncheckable) printf '  the npm rule could not be evaluated: %s is missing or unreadable\n' "$_rest" ;;
                bun-canary)    printf '  bun %s is a canary build — not reproducible, and not what any lockfile was validated against\n' "$_rest" ;;
                bash-wsl-first) printf '  a bare bash resolves to %s (the WSL launcher/alias) before Git Bash — a Windows-launched hook or cadence runner gets the wrong shell\n' "$_rest" ;;
                bun-unreadable) printf '  bun answered %s — not a version this policy can confirm as a release build\n' "$_rest" ;;
                bash-uncheckable) printf '  the bash-order rule could not be evaluated: the probe %s is missing or answered nothing\n' "$_rest" ;;
                nvm-absent)    printf '  no nvm/volta/fnm on this box — install one to align in place, or bump the pin after a suite pass\n' ;;
                *)             printf '  %s %s %s\n' "$_kind" "$_what" "$_rest" ;;
            esac
        done
        printf '  fix the runtime, or set HIMMEL_RUNTIME_PREFLIGHT=0 to silence this (HIMMEL-1991).\n'
        if [ "$mode" = "strict" ]; then
            printf '  HIMMEL_RUNTIME_PREFLIGHT=strict — REFUSING to run %s on a drifted runtime.\n' "$label"
        fi
        printf '\n'
    } >&2

    [ "$mode" = "strict" ] && return 1
    return 0
}

# Direct invocation: report + exit per the same policy.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
    runtime_preflight "${1:-manual}"
    exit $?
fi
