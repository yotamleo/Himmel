#!/usr/bin/env bash
# scripts/cr/critic-panel.sh — run the free-cloud critic panel over a diff (HIMMEL-415).
# Reads a unified diff on stdin, or computes main...HEAD itself with
# --worktree <path>, then runs each registry critic in the CRITIC_PANEL_TIERS set
# (default free) via critic-first-pass.sh and merges findings (global renumber,
# per-model slug IDs). The panel appends its own availability + raw-finding rows
# to the CR ledger before it exits.
# Stdout = merged findings block. Stderr = panel-availability lines.
# Exit 0 = >=1 responded; 1 = all failed (caller -> claude-only); 2 = usage;
# 3 = invalid --worktree; 4 = --worktree diff is empty; 5 = git/ledger failure;
# 6 = citation-guard id not computable (SHA-256 unavailable/failed) — run
#     REFUSED, fail-closed: no review emitted, no ledger rows appended.
# (exit 4 also covers stdin mode: an empty piped/null diff, HIMMEL-2107.)
# 7 = --head / --base-sha pin mismatch (HIMMEL-1175, HIMMEL-1984): the checkout
#     or the base branch moved since the caller captured its review inputs — run
#     REFUSED, no review emitted, no ledger rows appended, so a stamp can never
#     certify a SHA nobody reviewed, nor a diff nobody computed.
# Bash 3.2-safe.
# Env: CR_PROFILE — the operator's opt-in critic profile (from repo-root .env,
#      exported by /pr-check). AUTHORITATIVE when set (HIMMEL-558): the panel
#      derives its tier filter from it directly, so an agent running /pr-check
#      can no longer scope the panel to free-only by hand-setting a tier. Mapping:
#      `thorough`→`free,thorough`; any other value (`paid`, `free,paid`, `free`)
#      passes through verbatim. `none` (claude-only) is handled UPSTREAM by the
#      /pr-check runbook, which skips the panel entirely — if it ever reaches here
#      it falls through to the CRITIC_PANEL_TIERS/default path (visible free run).
#      CRITIC_PANEL_TIERS — comma-separated tier names to include (default: free).
#      The low-level override, honored ONLY when CR_PROFILE is unset (direct/
#      advanced use + tests). CR_PROFILE wins when both are set.
#      CRITIC_TIMEOUT_SECS — per-member wall-clock timeout in seconds (default 240;
#          HIMMEL-558: raised from 150 after both the paid codex critic AND the free
#          qwenor anchor were observed timing out at exactly 150s and contributing
#          nothing — 150 clipped their occasional slow reasoning. 240 gives headroom
#          while still bounding a genuinely hung provider. Lower it for a faster gate.
#          Requires GNU coreutils 'timeout'; gracefully degrades without it.
#          A registry row's OPTIONAL "timeout_secs" (HIMMEL-1245) overrides this
#          shared default for that ONE member only — e.g. the glm row needs more
#          headroom than codex on a large diff. Invalid/absent -> this default.
#      CRITIC_PARALLEL — set to 1 to run critics concurrently (default 0 = sequential).
#          Output is byte-identical to sequential: results merged in registry order.
set -uo pipefail

# LIVENESS BEACON (HIMMEL-1280) — the FIRST thing this script does, before any
# sourcing, subshell, mktemp, cygpath or dotenv read, and before LC_ALL export.
# Nothing above this line can block.
#
# WHY IT IS THE FIRST LINE: an armed session lost 3h13m to a backgrounded panel
# that produced 0 bytes and ~0.1 CPU-seconds with NO child process. A 0-byte
# output is otherwise ambiguous — "the panel is thinking" and "the shell never
# reached its first echo" look identical from outside, and the session waited
# on the first reading when the second was true. This beacon disambiguates them
# permanently:
#
#   beacon ABSENT  -> the wedge is BEFORE the panel: the `bash -c -l` login-shell
#                     wrapper, profile init under a detached/no-tty handle, or
#                     the caller's own redirect. critic-panel.sh never ran. Do
#                     not debug the panel.
#   beacon PRESENT -> the panel started; whatever follows (or does not) is the
#                     panel's own doing and its phase lines below localise it.
#
# Unbuffered by construction: one printf to stderr, no pipeline, no subshell.
printf 'critic-panel.sh: START pid=%s (HIMMEL-1280 liveness beacon)\n' "$$" >&2

# Start the total-panel clock HERE, next to the beacon — not down at the
# timeout-config block. Everything between the two (registry read, local-overlay
# merge, triviality gate, tier resolution) is real wall clock the caller is
# waiting through, and a budget that excludes setup is not the budget the caller
# reasons about (CR).
#
# CRITIC_PANEL_STARTED_AT is a TEST SEAM (epoch seconds). The launch-side
# deadline check cannot be reached otherwise: launches are near-instant, so no
# real budget expires *during* the loop, and 0 means "disabled" rather than
# "already spent". Backdating the start is the only deterministic way to put the
# panel past its deadline at a chosen point — and it keeps the suite from
# sleeping through real budgets to get there.
_PANEL_STARTED_AT="${CRITIC_PANEL_STARTED_AT:-$(date +%s 2>/dev/null || echo 0)}"

LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFP="${CRITIC_FIRST_PASS:-$SCRIPT_DIR/critic-first-pass.sh}"
INVOKE="${CRITIC_INVOKE:-$SCRIPT_DIR/../hermes/invoke.sh}"
LEDGER_APPEND="${CRITIC_LEDGER_APPEND:-$SCRIPT_DIR/ledger-append.sh}"

usage() {
    cat >&2 <<'USAGE'
usage: critic-panel.sh [--worktree <path>] [--head <sha>] [--branch <name>] [--base <name>] [--base-sha <sha>] [--check [--all-tiers]]
  stdin                    review the unified diff read from stdin (back-compat)
  --worktree <path>        review `git -C <path> diff <base>...HEAD` (sanctioned)
                           <base> = CR_BASE_BRANCH env, else the remote's default
                           branch (refs/remotes/origin/HEAD), else main
  --head <sha>             pin the review to the caller's captured SHA (7-64 hex
                           chars; a revision expression is refused): exit 7
                           unless the reviewed checkout is still at it
  --branch <name>          pin the review to the caller's captured BRANCH: exit 7
                           unless the checkout is still on it (a SHA pin alone
                           passes a switch to another branch at the same commit)
  --base <name>            the caller's captured base REF NAME; wins over
                           CR_BASE_BRANCH and the auto-resolution, so --base-sha
                           is verified against the base the caller actually used
  --base-sha <sha>         pin the DIFF BASE to the caller's captured base SHA
                           (7-64 hex chars): exit 7 unless <base> still resolves
                           to it, so a base branch that moved between capture and
                           review cannot change the reviewed diff (HIMMEL-1984)
  --check [--all-tiers]    probe registry health without reviewing a diff
exit 3: --worktree path is not a git worktree
exit 4: --worktree <base>...HEAD diff is empty, or stdin mode got no piped diff (review refused)
exit 5: git metadata, diff computation, or CR-ledger persistence failed
exit 6: citation-guard id not computable (SHA-256 unavailable or failing) - run refused
exit 7: --head/--branch/--base-sha pin mismatch - the checkout or the base branch
        moved since capture (review refused)
USAGE
}

# Shape check shared by the two SHA pins (--head, --base-sha). Hex-only, 7..64
# chars (HIMMEL-1175, codex-3): a permissive alphanumeric class also accepts
# `HEAD` or a branch name, which git resolves DYNAMICALLY — a "pin" that follows
# the checkout is not a pin. Only an immutable object name is accepted. Upper
# bound 64, not 40: a SHA-256 git repository names commits with 64 hex chars
# (panel r5). $1 = flag name (for the diagnostic), $2 = the supplied value.
_require_sha_pin() {
    case "$2" in
        *[!0-9a-fA-F]*)
            echo "critic-panel.sh: $1 must be a commit SHA, not a revision expression (got: $2)" >&2
            exit 2
            ;;
    esac
    if [ "${#2}" -lt 7 ] || [ "${#2}" -gt 64 ]; then
        echo "critic-panel.sh: $1 must be a 7-64 character commit SHA (got: $2)" >&2
        exit 2
    fi
}

# failure-classify.sh (HIMMEL-1176): sole owner of the quota-exhaustion
# signature table (is_quota_exhaustion, ex-HIMMEL-729 _is_quota_exhaustion)
# and of classify_failure, used below to append a reason= to every
# panel-availability unavailable line. Sourcing only defines functions (no
# side effect; failure-classify.sh runs without `-e`, so it does not leak
# errexit into this script the way triviality-gate.sh does). Fail-open on a
# missing file: a should-never-happen case degrades to no reason capture and
# an always-false exhaustion check, rather than breaking the panel.
if [ -r "$SCRIPT_DIR/failure-classify.sh" ]; then
    # shellcheck source=scripts/cr/failure-classify.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/failure-classify.sh"
else
    echo "critic-panel.sh: failure-classify.sh not readable at $SCRIPT_DIR - reason capture disabled, quota-exhaustion check degrades to always-false" >&2
    is_quota_exhaustion() { return 1; }
    classify_failure() { echo "generic-rc-${1:-1}"; }
fi

# Registry resolution (HIMMEL-727 split + HIMMEL-1221 merge). CRITICS_JSON env
# (tests/CI) wins outright. Otherwise critics.json is the BASE and
# critics.local.json (gitignored per-operator overlay — ACCOUNT state like
# exhausted free quotas / upgraded models) is MERGED per-slug ON TOP: a local row
# OVERRIDES or APPENDS by slug, and a local row with "drop":true REMOVES the base
# row of that slug. Merge (not the pre-1221 wholesale replace) so a stale overlay
# can no longer silently mask a shipped critic — the glm row HIMMEL-1096 added
# lived only in critics.json and an overlay predating it dropped it. Test hooks:
# CRITICS_BASE_JSON / CRITICS_LOCAL_JSON override the two merge inputs.
_MERGED_REG=""
_REG_BASE="${CRITICS_BASE_JSON:-$SCRIPT_DIR/critics.json}"
_REG_LOCAL="${CRITICS_LOCAL_JSON:-$SCRIPT_DIR/critics.local.json}"
if [ -n "${CRITICS_JSON:-}" ]; then
    REG="$CRITICS_JSON"
elif [ -f "$_REG_LOCAL" ]; then
    _MERGED_REG="$(mktemp -t critics-merged.XXXXXX)" || _MERGED_REG=""
    # Early EXIT trap so the validation / arg-parse error exits below can't leak the
    # merged temp file. The --check and main traps RE-INCLUDE this rm because a
    # later `trap ... EXIT` REPLACES (not extends) an earlier one.
    [ -n "$_MERGED_REG" ] && trap 'rm -f "$_MERGED_REG"' EXIT
    if [ -n "$_MERGED_REG" ] && MERGE_BASE="$_REG_BASE" MERGE_LOCAL="$_REG_LOCAL" node -e '
        const fs = require("fs");
        const rd = p => { try { const j = JSON.parse(fs.readFileSync(p, "utf8"));
            return Array.isArray(j.panel) ? j.panel : []; } catch (e) { return null; } };
        const base = rd(process.env.MERGE_BASE), local = rd(process.env.MERGE_LOCAL);
        if (base === null && local === null) process.exit(7);   // both unreadable
        const bp = base || [], lp = local || [];
        const drop = new Set(), over = new Map();               // local rows by slug
        for (const r of lp) { if (r && typeof r === "object" && typeof r.slug === "string") {
            if (r.drop === true) drop.add(r.slug); else over.set(r.slug, r); } }
        const out = [], seen = new Set();
        for (const r of bp) {                                   // base order first
            if (!r || typeof r !== "object" || typeof r.slug !== "string") { out.push(r); continue; }
            if (drop.has(r.slug)) { seen.add(r.slug); continue; }
            out.push(over.has(r.slug) ? over.get(r.slug) : r);  // local override wins
            seen.add(r.slug);
        }
        for (const r of lp) {                                   // local-only appends
            if (!r || typeof r !== "object" || typeof r.slug !== "string") continue;
            if (r.drop === true || seen.has(r.slug)) continue;
            out.push(r); seen.add(r.slug);
        }
        process.stdout.write(JSON.stringify({ panel: out }));
    ' > "$_MERGED_REG" 2>/dev/null; then
        REG="$_MERGED_REG"
        echo "critic-panel.sh: merged critics.local.json over critics.json" >&2
    else
        # Fail-open to the pre-1221 behavior: local overlay verbatim.
        echo "critic-panel.sh: overlay merge failed — using critics.local.json verbatim" >&2
        rm -f "$_MERGED_REG"; _MERGED_REG=""; REG="$_REG_LOCAL"
    fi
else
    REG="$_REG_BASE"
fi

# HIMMEL-1221: load the Z.ai critic credential from the primary checkout's .env so
# the paid glm panel row (provider zai / route_provider glm, HIMMEL-1096)
# authenticates with NO manual env export — but ONLY when the resolved registry
# actually contains a Z.ai critic (a "zai"/"glm" provider, route_provider, or
# slug). load_dotenv forks a subshell per .env line (≈1.5s on Git Bash over a
# large .env), so gating on need keeps that cost off every free-only / glm-less
# panel run (the common path). load_dotenv sets a key ONLY when currently UNSET
# (a live env value wins) and never sources/logs the .env — it extracts only the
# requested KEY= lines (block-read-secrets safe). Scoped to the CR panel per the
# HIMMEL-1096 Z.ai-key compliance note; deliberately NOT loaded at the hermes
# chokepoint (invoke.sh stays auth-agnostic, HIMMEL-278). load_dotenv exports each
# key it sets, so the child critic-first-pass.sh -> invoke.sh processes inherit it.
# HIMMEL-1065: CLIPROXY_API_KEY is the codex critic's auth credential. The codex
# member runs via critic-first-pass.sh -> hermes/invoke.sh, whose openai-codex
# provider defers auth to the INHERITED env (invoke.sh loads no dotenv itself),
# so it must be exported here. Without this load a worktree run (no .env of its
# own) leaves it unset, the codex critic dies rc=2, critic-first-pass.sh fails
# OPEN, and the panel prints a 0/0/0 "clean" review. It is gated on its OWN
# provider probe, NOT on the Z.ai one: a codex-only registry (CRITICS_JSON, or a
# local overlay that drops the GLM row) is a supported shape, and folding the key
# into the zai/glm gate would leave exactly that shape unauthenticated — the same
# fail-open this ticket exists to close. Both probes read the FULL registry (set
# before tier filtering), so each fires whenever its critic is present at all.
_CRED_KEYS=""
if grep -Eq '"(zai|glm)"' "$REG" 2>/dev/null; then
    _CRED_KEYS="$_CRED_KEYS GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY"
fi
if grep -Eq '"(openai-codex|codex)"' "$REG" 2>/dev/null; then
    _CRED_KEYS="$_CRED_KEYS CLIPROXY_API_KEY"
fi
if [ -n "$_CRED_KEYS" ]; then
    # shellcheck source=../lib/load-dotenv.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/load-dotenv.sh" 2>/dev/null || true
    if command -v load_dotenv >/dev/null 2>&1; then
        # HIMMEL-1648: pin to SCRIPT-ROOT resolution so a panel run from an
        # unrelated git repo still reads himmel's .env, not THAT repo's.
        # Unquoted on purpose — $_CRED_KEYS is a word-split list of KEY names.
        # shellcheck disable=SC2086
        load_dotenv --root "$(_load_dotenv_primary_for "$SCRIPT_DIR/../..")" $_CRED_KEYS 2>/dev/null || true
    fi
fi

# Effective tier resolution (HIMMEL-558). CR_PROFILE is AUTHORITATIVE when set —
# it is the operator's opt-in profile (loaded from .env, exported by /pr-check).
# This closes the drift where an agent hand-executing the /pr-check runbook
# scoped the panel to free-only (dropping the paid codex critic) by hardcoding
# CRITIC_PANEL_TIERS. The runbook no longer computes a tier; the panel does,
# straight from CR_PROFILE, so free-only scoping is no longer reachable by hand.
# `none` is handled upstream (runbook skips the panel) → falls to the else path.
if [ -n "${CR_PROFILE:-}" ] && [ "${CR_PROFILE}" != "none" ]; then
    case "$CR_PROFILE" in
        thorough) TIER_FILTER="free,thorough" ;;
        *)        TIER_FILTER="$CR_PROFILE" ;;
    esac
    echo "critic-panel.sh: tiers=$TIER_FILTER (from CR_PROFILE=$CR_PROFILE)" >&2
else
    TIER_FILTER="${CRITIC_PANEL_TIERS:-free}"
fi

ANCHOR_SLUG="codex"
ANCHOR_MODEL="gpt-6-astra"
# codex routes via the openai-codex provider (the hermes OAuth chokepoint), not
# OpenRouter — the fallback rows carry it as the panel's --provider so a
# registry-missing recovery routes the anchor to the right backend. (The free
# laguna anchor was dropped for low-quality output; codex is the fallback anchor
# when configured — adopters without codex infra still degrade to claude-only.)
ANCHOR_PROVIDER="openai-codex"

# Per-member timeout: validate CRITIC_TIMEOUT_SECS (Bash 3.2 safe via expr).
CRITIC_TIMEOUT_SECS="${CRITIC_TIMEOUT_SECS:-240}"
if expr "$CRITIC_TIMEOUT_SECS" : '^[0-9][0-9]*$' > /dev/null 2>&1 && [ "$CRITIC_TIMEOUT_SECS" -gt 0 ]; then
    # Normalize to base 10 (public-PR CR). The regex accepts a LEADING ZERO, and
    # `$(( ))` reads a leading zero as OCTAL — so `0900` validates here and then
    # dies later with "value too great for base" (9 is not an octal digit). See
    # the sibling block below for the failure this produces.
    CRITIC_TIMEOUT_SECS=$((10#$CRITIC_TIMEOUT_SECS))
else
    echo "critic-panel.sh: CRITIC_TIMEOUT_SECS=$CRITIC_TIMEOUT_SECS invalid, using 240" >&2
    CRITIC_TIMEOUT_SECS="240"
fi

# SIGKILL grace handed to every `timeout -k` below (HIMMEL-1291, public-PR CR).
# A member that ignores SIGTERM lives this many seconds PAST its nominal
# timeout, so the nominal timeout is not the member's real wall-clock cost —
# nominal + grace is. Named once here because the clamp below has to subtract
# exactly what the runners pass: a literal that drifts from the clamp silently
# re-opens the overrun this constant closes.
CRITIC_KILL_GRACE_SECS=5

# TOTAL-panel wall clock (HIMMEL-1280). CRITIC_TIMEOUT_SECS bounds ONE member;
# nothing bounded the panel as a whole, so N members each clipping their own
# budget could still hold a caller for N*CRITIC_TIMEOUT_SECS with no ceiling
# the caller can reason about. Default 900s = comfortably above a healthy
# 2-member run (~2min) and above the worst legitimate case, so it fires only on
# a genuine pile-up. 0 disables the cap.
CRITIC_PANEL_TOTAL_TIMEOUT_SECS="${CRITIC_PANEL_TOTAL_TIMEOUT_SECS:-900}"
if expr "$CRITIC_PANEL_TOTAL_TIMEOUT_SECS" : '^[0-9][0-9]*$' > /dev/null 2>&1; then
    # Normalize to base 10 (public-PR CR) — valid, including 0 = disabled.
    #
    # The regex accepts a LEADING ZERO. `[ "0900" -gt 0 ]` then PASSES (test's
    # integer comparison is decimal), so both guards in _panel_remaining are
    # satisfied — and the failure lands one line later, in `$(( ))`, which reads
    # a leading zero as OCTAL: "0900: value too great for base". Measured, the
    # whole function then returns rc 1 with empty output, which is its
    # documented "no usable budget" path — so a fat-fingered CRITIC_PANEL_TOTAL_
    # TIMEOUT_SECS=0900 SILENTLY DISABLES the total-panel cap and leaks a shell
    # error to stderr on every call, while looking configured.
    #
    # That is the same shape this PR keeps fixing: a value that passes its own
    # validation and then fails open somewhere the validation cannot see.
    CRITIC_PANEL_TOTAL_TIMEOUT_SECS=$((10#$CRITIC_PANEL_TOTAL_TIMEOUT_SECS))
else
    echo "critic-panel.sh: CRITIC_PANEL_TOTAL_TIMEOUT_SECS=$CRITIC_PANEL_TOTAL_TIMEOUT_SECS invalid, using 900" >&2
    CRITIC_PANEL_TOTAL_TIMEOUT_SECS="900"
fi
# _panel_remaining — seconds left in the total budget, or "" when there is no
# usable budget (cap disabled, or an unusable clock). Fail-OPEN by design: a
# broken deadline check must never shorten or abort a panel that is working —
# the per-member timeouts still bound the run.
_panel_remaining() {
    [ "$CRITIC_PANEL_TOTAL_TIMEOUT_SECS" -gt 0 ] 2>/dev/null || return 1
    [ "$_PANEL_STARTED_AT" -gt 0 ] 2>/dev/null || return 1
    local _now _left
    _now="$(date +%s 2>/dev/null || echo 0)"
    [ "$_now" -gt 0 ] 2>/dev/null || return 1
    _left=$(( CRITIC_PANEL_TOTAL_TIMEOUT_SECS - (_now - _PANEL_STARTED_AT) ))
    printf '%s\n' "$_left"
}

# True once the total budget is spent.
_panel_deadline_passed() {
    local _left
    _left="$(_panel_remaining)" || return 1
    [ "$_left" -le 0 ]
}

# _clamp_to_panel_budget <member_timeout> (HIMMEL-1280 CR)
# Echo the member timeout capped by whatever is LEFT of the total budget.
# Without this the total cap only stops NEW members starting: one member with a
# 240s budget begun at T-1 second still runs to T+239, so the "total" bound is
# really total + one member. Clamping makes the ceiling the caller was told
# about the ceiling they actually get. Never returns <1 (the deadline check
# above has already broken the loop by then).
#
# The cap RESERVES the `timeout -k` grace (HIMMEL-1291, public-PR CR): the
# runners spend nominal + CRITIC_KILL_GRACE_SECS on a member that ignores
# SIGTERM, so clamping to the bare remainder still let the panel finish
# CRITIC_KILL_GRACE_SECS past the total deadline. Clamping to
# (remaining - grace) makes nominal + grace fit INSIDE what is left. Only the
# floor case can still overrun, and by then the budget is within a grace of
# zero anyway.
#
# The overrun is ONE grace, not grace * n_members (the public-CR report said
# the latter; panel round said otherwise and was right). _panel_remaining
# recomputes from wall clock on every call, so an earlier member's grace
# overrun is already absorbed into the next member's remaining before it
# launches — only the LAST member to be clamped can end past the deadline.
# Parallel mode is the same bound for a different reason: members overlap, so
# their graces do not sum. One grace is still an overrun of a bound the caller
# was promised, which is why this reserves it.
_clamp_to_panel_budget() {
    local _member="$1" _left
    _left="$(_panel_remaining)" || { printf '%s\n' "$_member"; return 0; }
    _left=$(( _left - CRITIC_KILL_GRACE_SECS ))
    if [ "$_left" -lt 1 ]; then _left=1; fi
    if [ "$_left" -lt "$_member" ]; then printf '%s\n' "$_left"; else printf '%s\n' "$_member"; fi
}

# _resolve_member_timeout <slug> <raw_timeout_secs> (HIMMEL-1245)
# Echoes the effective per-member timeout: the row's OPT-IN timeout_secs when
# it is a positive integer (Bash 3.2 safe via expr, same check as
# CRITIC_TIMEOUT_SECS above), else the shared CRITIC_TIMEOUT_SECS default —
# with a stderr note when a present value was invalid, so a typo'd registry
# row degrades instead of failing closed.
_resolve_member_timeout() {
    _rmt_slug="$1"
    _rmt_raw="$2"
    if [ -n "$_rmt_raw" ]; then
        if expr "$_rmt_raw" : '^[0-9][0-9]*$' > /dev/null 2>&1 && [ "$_rmt_raw" -gt 0 ]; then
            echo "$_rmt_raw"
            return
        fi
        echo "critic-panel.sh: row $_rmt_slug timeout_secs=$_rmt_raw invalid, using shared default (${CRITIC_TIMEOUT_SECS}s)" >&2
    fi
    echo "$CRITIC_TIMEOUT_SECS"
}

# Validate CRITIC_PARALLEL
CRITIC_PARALLEL="${CRITIC_PARALLEL:-0}"
if [ "$CRITIC_PARALLEL" != "0" ] && [ "$CRITIC_PARALLEL" != "1" ]; then
    echo "critic-panel.sh: CRITIC_PARALLEL=$CRITIC_PARALLEL invalid, using 0" >&2
    CRITIC_PARALLEL="0"
fi

# Detect timeout binary once (before the loop).
_TIMEOUT_BIN="$(command -v timeout 2>/dev/null)" || _TIMEOUT_BIN=""
if [ -z "$_TIMEOUT_BIN" ]; then
    echo "critic-panel.sh: 'timeout' not found — per-member hang protection disabled" >&2
fi

CHECK_MODE="0"
CHECK_ALL_TIERS="0"
WORKTREE=""
HEAD_PIN=""
BRANCH_PIN=""
BASE_PIN=""
BASE_REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --head)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "critic-panel.sh: --head requires a commit SHA" >&2
                usage
                exit 2
            fi
            _require_sha_pin --head "$2"
            HEAD_PIN="$2"
            shift 2
            ;;
        --base)
            # The caller's captured base REF NAME (HIMMEL-1984 panel r5). Without
            # it --base-sha was verified against a base this script resolved on
            # its OWN — CR_BASE_BRANCH is read here but NOT by /pr-check's
            # default_branch capture, so an operator with that env var set would
            # get a false refusal on a base that never moved. The two lanes now
            # take the same pair: --base <ref> --base-sha <sha>.
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "critic-panel.sh: --base requires a branch name" >&2
                usage
                exit 2
            fi
            case "$2" in
                *[!A-Za-z0-9._/+-]*)
                    echo "critic-panel.sh: --base contains unsupported characters (got: $2)" >&2
                    exit 2
                    ;;
            esac
            BASE_REF="$2"
            shift 2
            ;;
        --base-sha)
            # Diff-BASE half of the pin (HIMMEL-1984). --head froze the tip; the
            # base was still resolved LIVE at review time, so the OTHER end of
            # the reviewed range could differ from the one the caller computed
            # while the head pin kept passing. A plain fast-forward of the base
            # leaves a three-dot merge-base alone, but a REWRITTEN base (rebase,
            # force-push, reset) moves it — and the CodeRabbit lane of the same
            # /pr-check run diffs against the base TIP it fetches, so the two
            # lanes can review different ranges of the same head.
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "critic-panel.sh: --base-sha requires a commit SHA" >&2
                usage
                exit 2
            fi
            _require_sha_pin --base-sha "$2"
            BASE_PIN="$2"
            shift 2
            ;;
        --branch)
            # Branch-identity half of the pin (HIMMEL-1175 r2). A SHA pin alone
            # passes a switch to a DIFFERENT branch sitting at the same commit —
            # the exact stale-input case the ticket names — and the panel would
            # then stamp its ledger rows with that other branch's name while the
            # caller certifies the captured one.
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "critic-panel.sh: --branch requires a branch name" >&2
                usage
                exit 2
            fi
            case "$2" in
                *[!A-Za-z0-9._/+-]*)
                    echo "critic-panel.sh: --branch contains unsupported characters (got: $2)" >&2
                    exit 2
                    ;;
            esac
            BRANCH_PIN="$2"
            shift 2
            ;;
        --check)
            CHECK_MODE="1"
            shift
            ;;
        --all-tiers)
            CHECK_ALL_TIERS="1"
            shift
            ;;
        --worktree)
            if [ $# -lt 2 ] || [ -z "$2" ]; then
                echo "critic-panel.sh: --worktree requires a path" >&2
                usage
                exit 2
            fi
            WORKTREE="$2"
            shift 2
            ;;
        *)
            echo "critic-panel.sh: unknown option $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [ "$CHECK_MODE" = "1" ] && [ -n "$WORKTREE" ]; then
    echo "critic-panel.sh: --worktree cannot be combined with --check" >&2
    usage
    exit 2
fi

if [ "$CHECK_MODE" = "1" ]; then
    # Parse registry for a health probe: emit "slug<TAB>model<TAB>tier" for every row.
    # Falls back to anchor on missing/invalid/empty registry.
    check_rows="$(REG="$REG" node -e '
  const fs = require("fs");
  const reg = process.env.REG;
  try {
    const j = JSON.parse(fs.readFileSync(reg, "utf8"));
    const p = (j.panel || []).filter(r => r.slug && r.model);
    if (!p.length) throw new Error("no rows");
    process.stdout.write(p.map(r => r.slug + "\t" + r.model + "\t" + (r.tier || "") + "\t" + (r.route_provider || "-")).join("\n"));
  } catch (e) {
    process.exit(7);
  }
' 2>/dev/null)" || check_rows=""

    if [ -z "${check_rows:-}" ]; then
        echo "critic-panel.sh: registry $REG missing/invalid/empty — anchor-only ($ANCHOR_SLUG)" >&2
        check_rows="${ANCHOR_SLUG}	${ANCHOR_MODEL}	paid	${ANCHOR_PROVIDER}"
    fi

    check_prompt="$(mktemp -t critic-panel-check.XXXXXX)"
    trap 'rm -f "$check_prompt"; [ -n "$_MERGED_REG" ] && rm -f "$_MERGED_REG"' EXIT
    printf '%s' 'Reply with exactly: ok' > "$check_prompt"

    check_failed="0"
    while IFS="	" read -r slug model tier row_provider; do
        [ -n "$slug" ] || continue
        [ "$row_provider" = "-" ] && row_provider=""
        if [ "$tier" = "paid" ] && [ "$CHECK_ALL_TIERS" != "1" ]; then
            echo "row $slug: skipped (paid)"
            continue
        fi
        "$INVOKE" --model "$model" --provider "$row_provider" --prompt-file "$check_prompt" >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "row $slug: ok"
        else
            echo "row $slug: dead (rc=$rc)"
            check_failed="1"
        fi
    done << CHECKROWSEOF
$check_rows
CHECKROWSEOF

    rm -f "$check_prompt"
    [ -n "$_MERGED_REG" ] && rm -f "$_MERGED_REG"   # normal --check path (trap is disarmed next)
    trap - EXIT
    [ "$check_failed" -eq 0 ] || exit 1
    exit 0
fi

# HIMMEL-1175 — --head input pinning. /pr-check captures branch+HEAD up front
# and stamps the ledger with that SHA, but this panel resolved its own head (and,
# in --worktree mode, its own diff) from LIVE state. A checkout that moved between
# capture and review — the same-SHA branch switch clear-cr-marker.sh's exit 13/16
# gates cannot catch — therefore reviewed one tree and certified another. With
# --head the run REFUSES rather than reviewing live state. Called BEFORE the diff
# and before any critic runs, so a stale-input run costs nothing and stamps
# nothing. Both sides go through rev-parse so a short pin compares equal to a
# full head.
_verify_head_pin() {
    # $1 = resolved repository root ("" when there is none), $2 = resolved head
    if [ -n "$BRANCH_PIN" ]; then
        if [ -z "$1" ]; then
            echo "critic-panel.sh: REFUSING --branch $BRANCH_PIN — no git worktree here to verify the pin against (HIMMEL-1175)" >&2
            exit 7
        fi
        _live_branch="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)" || _live_branch=""
        if [ "$_live_branch" != "$BRANCH_PIN" ]; then
            echo "critic-panel.sh: REFUSING — $1 is on branch ${_live_branch:-<unresolvable>} but the review was pinned to $BRANCH_PIN; a switch to another branch (even one sitting at the same commit) means this review would be stamped for a branch it did not come from (HIMMEL-1175). Re-run /pr-check from step 1." >&2
            exit 7
        fi
    fi
    [ -n "$HEAD_PIN" ] || return 0
    if [ -z "$1" ]; then
        echo "critic-panel.sh: REFUSING --head $HEAD_PIN — no git worktree here to verify the pin against (HIMMEL-1175)" >&2
        exit 7
    fi
    _pin="$(git -C "$1" rev-parse --verify --quiet "$HEAD_PIN^{commit}" 2>/dev/null)" || _pin=""
    if [ -z "$_pin" ]; then
        echo "critic-panel.sh: REFUSING --head $HEAD_PIN — not a commit in $1 (HIMMEL-1175)" >&2
        exit 7
    fi
    if [ "$_pin" != "$2" ]; then
        echo "critic-panel.sh: REFUSING — $1 is at ${2:-<unresolvable>} but the review was pinned to $_pin; the checkout moved since the caller captured its inputs, so this review would be stamped against a SHA it never covered (HIMMEL-1175). Re-run /pr-check from step 1." >&2
        exit 7
    fi
}

# Resolve the base branch instead of hardcoding `main` (HIMMEL-1494): a repo
# whose default branch is master/other always hit the empty-diff / diff-failed
# exits below. Order: an explicit CR_BASE_BRANCH override -> the remote's
# default branch (symbolic-ref of refs/remotes/origin/HEAD, with the
# refs/remotes/origin/ prefix stripped) -> main. The resolved name flows into
# the diff and every diagnostic so a non-main default branch works.
# $1 = resolved repository root. Echoes the ref name the diff should use.
_resolve_base_ref() {
    # An explicit --base from the caller wins: it is the name the caller
    # actually diffed against, so resolving anything else here would compare the
    # pin to a base nobody used (HIMMEL-1984 panel r5). Then CR_BASE_BRANCH, then
    # origin/HEAD, then default_branch.
    _rb="${BASE_REF:-${CR_BASE_BRANCH:-}}"
    _rb_via_origin=0
    if [ -z "$_rb" ]; then
        _oh="$(git -C "$1" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" || _oh=""
        case "$_oh" in
            refs/remotes/origin/*) _rb="${_oh#refs/remotes/origin/}"; _rb_via_origin=1 ;;
        esac
        # Last resort stays the literal "main" (HIMMEL-1494). Routing this
        # through guardrails/lib.sh default_branch was tried (HIMMEL-1984 r3) to
        # make it agree with /pr-check's $db on a master-only repo, and reverted:
        # that resolver ends at `git config init.defaultBranch`, which reads the
        # SYSTEM config, so the panel's base would silently follow a machine
        # setting. Caller/base divergence is fixed where it belongs instead — the
        # caller NAMES its base with --base, which wins over every fallback here.
        [ -n "$_rb" ] || _rb="main"
    fi
    # Re-resolve the bare name to a ref git can actually diff (HIMMEL-1494 r3).
    # A clone or worktree that carries only origin/<name> (and never checked
    # <name> out locally) fails on a bare name. An explicit CR_BASE_BRANCH
    # override is honored VERBATIM (documented). Otherwise: prefer the bare LOCAL
    # name when it verifies; else, for an origin/HEAD resolution, fall back to
    # the REMOTE origin/<name> the symbolic-ref guaranteed exists. If neither
    # verifies _rb stays bare so the diff still fails loudly with the resolved
    # name (preserving the documented exit-5 diagnostic).
    # r4: verify refs/heads/<name> explicitly. A bare --verify <name> also
    # matches a TAG named like the default branch, which then falsely satisfied
    # this check and suppressed the origin/<name> fallback; qualifying the LOCAL
    # branch ref means only a real branch satisfies it (HIMMEL-1494 r4).
    if [ -z "${CR_BASE_BRANCH:-}" ]; then
        if ! git -C "$1" rev-parse --verify "refs/heads/$_rb" >/dev/null 2>&1; then
            # A caller-supplied --base gets the same remote fallback, but only
            # once the remote ref is VERIFIED to exist — origin/HEAD already
            # guarantees its own, a --base name does not (HIMMEL-1984 r5).
            if [ "$_rb_via_origin" -eq 1 ] || git -C "$1" rev-parse --verify "refs/remotes/origin/$_rb" >/dev/null 2>&1; then
                _rb="origin/$_rb"
            fi
        fi
    fi
    printf '%s' "$_rb"
}

# HIMMEL-1984 — --base-sha input pinning, the other end of the reviewed range.
# --head froze the tip, but the BASE was still resolved live here: the caller
# captured one base commit and this run could review against another. The check
# is on the base REF resolving to the captured commit, not on the diff bytes —
# that is the input the caller controls and the one both lanes of a /pr-check
# run must agree on. Same refusal semantics and exit code as --head: BEFORE the diff
# and before any critic runs, so a stale-input run costs nothing and stamps
# nothing. $1 = resolved repository root ("" when there is none).
_verify_base_pin() {
    [ -n "$BASE_PIN" ] || return 0
    if [ -z "$1" ]; then
        echo "critic-panel.sh: REFUSING --base-sha $BASE_PIN — no git worktree here to verify the pin against (HIMMEL-1984)" >&2
        exit 7
    fi
    _bpin="$(git -C "$1" rev-parse --verify --quiet "$BASE_PIN^{commit}" 2>/dev/null)" || _bpin=""
    if [ -z "$_bpin" ]; then
        echo "critic-panel.sh: REFUSING --base-sha $BASE_PIN — not a commit in $1 (HIMMEL-1984)" >&2
        exit 7
    fi
    _base_ref="$(_resolve_base_ref "$1")"
    _blive="$(git -C "$1" rev-parse --verify --quiet "$_base_ref^{commit}" 2>/dev/null)" || _blive=""
    if [ "$_blive" != "$_bpin" ]; then
        echo "critic-panel.sh: REFUSING — base $_base_ref is at ${_blive:-<unresolvable>} but the review was pinned to base $_bpin; the base branch moved since the caller captured its inputs, so the reviewed diff is not the one the caller computed (HIMMEL-1984). Re-run /pr-check from step 1." >&2
        exit 7
    fi
}

# Resolve the reviewed repository + exact head before running any critic. The
# --worktree path owns both the diff and the ledger location, so a stale caller
# cwd cannot silently review/stamp a different checkout. Stdin mode deliberately
# keeps its historical cwd-based repository context for back-compat.
if [ -n "$WORKTREE" ]; then
    _inside="$(git -C "$WORKTREE" rev-parse --is-inside-work-tree 2>/dev/null)" || _inside=""
    if [ "$_inside" != "true" ]; then
        echo "critic-panel.sh: --worktree path is not a git worktree: $WORKTREE" >&2
        exit 3
    fi
    REVIEW_ROOT="$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null)" || REVIEW_ROOT=""
    if [ -z "$REVIEW_ROOT" ]; then
        echo "critic-panel.sh: cannot resolve worktree root for: $WORKTREE" >&2
        exit 3
    fi
    _base="$(_resolve_base_ref "$REVIEW_ROOT")"
    # Capture the reviewed head ONCE (HIMMEL-1494 r4) and reuse it for BOTH the
    # diff and the ledger stamp: a separate `git rev-parse HEAD` at stamp time
    # could resolve a different commit if a concurrent commit lands between the
    # two invocations, certifying a head that does not match the reviewed diff.
    # The diagnostics still read "<base>...HEAD" (the operator-visible intent);
    # $_head is that same HEAD, snapshotted here.
    _head="$(git -C "$REVIEW_ROOT" rev-parse HEAD 2>/dev/null)" || _head=""
    _verify_head_pin "$REVIEW_ROOT" "$_head"
    _verify_base_pin "$REVIEW_ROOT"
    # A verified pin is the base the diff uses (HIMMEL-1984), for the same
    # capture-once reason $_head is a snapshot: re-reading the ref here would
    # reopen the window _verify_base_pin just closed. Diagnostics keep naming
    # $_base — the operator-visible intent.
    diff_in="$(git -C "$REVIEW_ROOT" diff "${BASE_PIN:-$_base}...$_head")"
    _diff_rc=$?
    if [ "$_diff_rc" -ne 0 ]; then
        echo "critic-panel.sh: git diff $_base...HEAD failed in $REVIEW_ROOT (rc=$_diff_rc)" >&2
        exit 5
    fi
    if [ -z "$diff_in" ]; then
        echo "critic-panel.sh: REFUSING empty --worktree diff (git -C $REVIEW_ROOT diff $_base...HEAD produced no output)" >&2
        exit 4
    fi
else
    diff_in="$(cat)"
    if [ -z "$diff_in" ]; then
        # A null/tty stdin with nothing piped in is always caller error
        # (HIMMEL-2107): forwarding it to members produced 11 false
        # "codex unavailable reason=http-4xx" reports (rc=2 usage text
        # misread as a transport failure downstream). Refuse the same way
        # the --worktree path refuses an empty diff.
        echo "critic-panel.sh: REFUSING empty stdin diff (no diff was piped in)" >&2
        exit 4
    fi
    REVIEW_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REVIEW_ROOT=""
    # Capture the head once for stamping coherence (HIMMEL-1494 r4): the stdin
    # diff is not HEAD-derived, but REVIEW_HEAD must still name the exact commit
    # under review, snapshotted here rather than re-resolved at stamp time.
    _head=""
    if [ -n "$REVIEW_ROOT" ]; then
        _head="$(git -C "$REVIEW_ROOT" rev-parse HEAD 2>/dev/null)" || _head=""
    fi
    # The stdin diff is the CALLER's; the pin still guards the stamp — and, for
    # /pr-check, the fact that the caller computed that diff against this same
    # SHA (HIMMEL-1175). A pin with no worktree to verify against refuses.
    _verify_head_pin "$REVIEW_ROOT" "$_head"
    # The stdin diff is already frozen, so a moved base cannot change what THIS
    # lane reviews — but it means the caller's captured base is stale, and the
    # sibling lanes of the same /pr-check run (CodeRabbit, the rtk retry) would
    # review a different range. Refuse here too, at the first lane, rather than
    # letting the run reach a later one (HIMMEL-1984).
    _verify_base_pin "$REVIEW_ROOT"
    if [ -z "$REVIEW_ROOT" ]; then
        # Back-compat (HIMMEL-1494): the stdin path used to work anywhere; it
        # only needs a worktree to STAMP ledger rows. Run the review anyway,
        # skip the self-append, and warn loudly. Review output and the exit code
        # behave exactly as pre-change. _SKIP_LEDGER gates every ledger step
        # below (head/branch resolution, ledger path, the final append).
        echo "critic-panel.sh: stdin review outside a git worktree — CR-ledger self-append skipped" >&2
        _SKIP_LEDGER=1
        REVIEW_HEAD=""
        REVIEW_BRANCH=""
    fi
fi

# Ledger stamping needs a worktree; the stdin-outside-worktree path skips all
# of it (HIMMEL-1494). REVIEW_HEAD/REVIEW_BRANCH/PANEL_LEDGER stay unset and the
# final _append_panel_ledger call is gated on the same flag below.
if [ "${_SKIP_LEDGER:-0}" != "1" ]; then
    REVIEW_HEAD="$_head"
    # A pinned run stamps the PINNED branch, not a fresh resolution (panel r4,
    # codex-2): _verify_head_pin proved the two were equal, and re-resolving
    # here would reopen the window between that check and this line — the same
    # capture-once reasoning that made $_head a snapshot in HIMMEL-1494 r4.
    if [ -n "$BRANCH_PIN" ]; then
        REVIEW_BRANCH="$BRANCH_PIN"
    else
        REVIEW_BRANCH="$(git -C "$REVIEW_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || REVIEW_BRANCH=""
    fi
    if [ -z "$REVIEW_HEAD" ] || [ -z "$REVIEW_BRANCH" ]; then
        echo "critic-panel.sh: cannot resolve reviewed head/branch in $REVIEW_ROOT" >&2
        exit 5
    fi
    if [ -n "${CR_LEDGER:-}" ]; then
        PANEL_LEDGER="$CR_LEDGER"
    else
        _common_dir="$(git -C "$REVIEW_ROOT" rev-parse --git-common-dir 2>/dev/null)" || _common_dir=""
        if [ -z "$_common_dir" ]; then
            echo "critic-panel.sh: cannot resolve git common dir for ledger in $REVIEW_ROOT" >&2
            exit 5
        fi
        case "$_common_dir" in
            /*|[A-Za-z]:/*) PANEL_LEDGER="$_common_dir/cr-critic-scores.jsonl" ;;
            *) PANEL_LEDGER="$REVIEW_ROOT/$_common_dir/cr-critic-scores.jsonl" ;;
        esac
    fi
    if [ ! -r "$LEDGER_APPEND" ]; then
        echo "critic-panel.sh: ledger append helper is not readable: $LEDGER_APPEND" >&2
        exit 5
    fi
fi

# Triviality gate (HIMMEL-737): a diff classified 'trivial' skips the PAID tier
# to save codex spend. Only fires when 'paid' is in the effective tier filter
# (the common free-only path never sources the gate). --check mode exits above,
# so it never reaches here. The gate honors CR_TRIVIALITY_OVERRIDE itself
# (full -> nontrivial), so no override handling is duplicated here.
case ",$TIER_FILTER," in
    *,paid,*)
        # triviality-gate.sh's CLI body is BASH_SOURCE-guarded, so sourcing only
        # defines functions. Its top-level 'set -euo pipefail' leaks errexit into
        # this script, which deliberately runs WITHOUT -e (it captures member rc
        # by hand) -- undo just the -e immediately after sourcing.
        _tg_verdict="nontrivial"; _tg_reason="gate-unavailable"
        if [ -r "$SCRIPT_DIR/triviality-gate.sh" ]; then
            # shellcheck source=scripts/cr/triviality-gate.sh
            # shellcheck disable=SC1091
            . "$SCRIPT_DIR/triviality-gate.sh"
            set +e
            _tg_result="$(classify_triviality "$diff_in")"
            _tg_rc=$?
            if [ "$_tg_rc" -eq 0 ] && [ -n "$_tg_result" ]; then
                _tg_verdict="${_tg_result%%$'\t'*}"
                _tg_reason="${_tg_result#*$'\t'}"
            else
                # Fail-safe: a broken gate must never narrow the panel silently
                # - keep the requested tiers and say so (CR round).
                echo "critic-panel.sh: triviality gate failed (rc=$_tg_rc) - paid tier kept" >&2
            fi
        else
            echo "critic-panel.sh: triviality-gate.sh not readable at $SCRIPT_DIR - gate skipped, paid tier kept" >&2
        fi
        if [ "$_tg_verdict" = "trivial" ]; then
            # Strip 'paid' from the effective tier filter (the node parse below
            # filters by TIER_FILTER, so dropping it here drops the paid rows).
            _new_filter=""
            _tg_ifs="$IFS"; IFS=','
            for _t in $TIER_FILTER; do
                [ "$_t" = "paid" ] && continue
                if [ -n "$_new_filter" ]; then _new_filter="$_new_filter,$_t"; else _new_filter="$_t"; fi
            done
            IFS="$_tg_ifs"
            if [ -z "$_new_filter" ]; then
                # Paid was the ONLY requested tier (CR round Critical): do NOT
                # silently substitute the registry default 'free' - honor the
                # operator's profile.
                #
                # HIMMEL-1950: degrading to claude-only here DEADLOCKS a trivial
                # diff when CR_REQUIRE_CROSS_MODEL=1, because clear-cr-marker
                # gate 3b then refuses the claude-only floor (exit 14). Two
                # individually-correct mechanisms, jointly unsatisfiable - and
                # the cheaper the change, the harder it became to ship. Observed
                # twice live (2026-08-15; a one-line plugin.json bump 2026-08-19),
                # each time worked around by forcing the FULL panel, i.e. paying
                # MORE for a one-liner than for a normal diff.
                #
                # So when the cross-model floor is REQUIRED, keep exactly ONE
                # external critic rather than zero (HIMMEL-1785's constraint:
                # keep the cheapest external critic, do not weaken the floor).
                # A gate that saves a call by making the branch unshippable
                # saves nothing.
                _tg_xm="${CR_REQUIRE_CROSS_MODEL:-}"
                if [ -z "$_tg_xm" ]; then
                    if ! command -v load_dotenv >/dev/null 2>&1; then
                        # shellcheck source=../lib/load-dotenv.sh
                        # shellcheck disable=SC1091
                        . "$SCRIPT_DIR/../lib/load-dotenv.sh" 2>/dev/null || true
                    fi
                    if command -v load_dotenv >/dev/null 2>&1; then
                        load_dotenv --root "$(_load_dotenv_primary_for "$SCRIPT_DIR/../..")" CR_REQUIRE_CROSS_MODEL 2>/dev/null || true
                        _tg_xm="${CR_REQUIRE_CROSS_MODEL:-}"
                    fi
                fi
                # The SAME truthy rule clear-cr-marker.sh gate 3b uses
                # (1/true/on/yes, case-insensitive, whitespace-trimmed). The two
                # must agree about the policy or the deadlock simply moves.
                case "$(printf '%s' "$_tg_xm" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" in
                    1|true|on|yes)
                        _tg_keep_one=1
                        echo "critic-panel.sh: triviality-gate verdict=trivial ($_tg_reason) would have stripped the ONLY requested tier (paid), but CR_REQUIRE_CROSS_MODEL is set and the claude-only floor cannot clear the marker without a non-Claude responder - keeping exactly ONE external critic so a trivial diff stays shippable (HIMMEL-1950). One cheap call by design; CR_TRIVIALITY_OVERRIDE=full runs the whole panel." >&2
                        ;;
                    *)
                        echo "critic-panel.sh: triviality-gate verdict=trivial ($_tg_reason) stripped the ONLY requested tier (paid) - skipping panel, claude-only (CR_TRIVIALITY_OVERRIDE=full to force). The claude-only floor clears the marker here because CR_REQUIRE_CROSS_MODEL is NOT set; with it set, this path keeps one critic instead (HIMMEL-1950)." >&2
                        exit 1
                        ;;
                esac
            else
                TIER_FILTER="$_new_filter"
                echo "critic-panel.sh: triviality-gate verdict=trivial ($_tg_reason) - paid tier skipped (CR_TRIVIALITY_OVERRIDE=full to force)" >&2
            fi
        fi
        ;;
esac

# Parse registry: emit "slug<TAB>model<TAB>perspective" lines for matching tiers.
# Falls back to anchor on missing/invalid/empty registry.
rows="$(REG="$REG" TIER_FILTER="$TIER_FILTER" node -e '
  const fs = require("fs");
  const reg  = process.env.REG;
  const tiers = (process.env.TIER_FILTER || "free").split(",").map(t => t.trim());
  try {
    const j = JSON.parse(fs.readFileSync(reg, "utf8"));
    // A non-array panel, or a null/non-object row, must be IGNORED rather
    // than throw: "usable" means exactly the rows we can act on, so one
    // malformed row should not condemn an otherwise-fine registry to rc=7.
    // (No backticks in this comment: shellcheck reads them as SC2016
    // command-substitution-in-single-quotes inside the node -e block.)
    // "usable" must require a non-empty tier too, not just slug+model: the
    // rc=8 exit below MEANS "the registry is fine, you asked for a tier nobody
    // has". A tier-less row can never match ANY filter, so counting it as
    // usable would report a MALFORMED registry (every row missing tier) as
    // rc=8 "no tier match" instead of rc=7 "invalid" — undermining the very
    // distinction this split exists to draw.
    const panel = Array.isArray(j.panel) ? j.panel : [];
    const nonEmptyStr = (v) => typeof v === "string" && v.trim().length > 0;
    const usable = panel.filter(r =>
      r && typeof r === "object" &&
      nonEmptyStr(r.slug) && nonEmptyStr(r.model) && nonEmptyStr(r.tier)
    );
    const p = usable.filter(r => tiers.includes(r.tier));
    // Distinct exits so the caller can tell "registry broken" (7) from
    // "registry fine, but no row matches the requested tier" (8) — collapsing
    // both into one "missing/invalid/empty" message sent a HIMMEL-1093 run
    // hunting a registry that was present and valid all along.
    if (!p.length) process.exit(usable.length ? 8 : 7);
    // "-" placeholder for empty middle fields: tab is IFS WHITESPACE in the
    // bash readers, so consecutive tabs collapse and a non-empty 4th field
    // would shift LEFT into the perspective slot (HIMMEL-729 field-shift bug).
    // Field 4 = the fallback CHAIN (HIMMEL-737): the ordered "fallback_models"
    // array, comma-joined; a legacy "fallback_model" string is a 1-element chain
    // for back-compat; "-" when empty. Model names never contain a comma or tab.
    // Field 5 = ROUTE_PROVIDER (HIMMEL-727): OPT-IN per row. When set, threaded
    // to hermes as an explicit --provider so a model id newer than the hermes
    // internal catalog cannot fall to its default provider. Deliberately a
    // SEPARATE key from the descriptive "provider" metadata: blanket-threading
    // provider broke alias-routed rows (explicit --provider bypasses the hermes
    // alias base_url -> 401 on the alibaba lane). Primary dispatch only —
    // fallback-chain members stay name-routed (hermes aliases, possibly
    // cross-provider).
    // Field 6 = FALLBACK_TRIGGER (HIMMEL-953): OPT-IN per row. "any" widens
    // the process_member retry condition to ANY non-zero rc/timeout instead
    // of requiring a quota-exhaustion signature match — for a same-tier
    // candidate chain (e.g. all OpenRouter free models) any failure on one
    // candidate is reason enough to try the next. "-" (unset) keeps the
    // HIMMEL-729 exhaustion-only default for every other row.
    // Field 8 = TIMEOUT_SECS (HIMMEL-1245): OPT-IN per row. Overrides the
    // shared CRITIC_TIMEOUT_SECS wall-clock budget for THIS member only
    // (e.g. glm needs more headroom than codex on a large diff). "-" (unset)
    // -> the shared default; bash validates positivity (see
    // _resolve_member_timeout), same as CRITIC_TIMEOUT_SECS itself.
    process.stdout.write(p.map(r => {
      let chain = Array.isArray(r.fallback_models) ? r.fallback_models
                : (r.fallback_model ? [r.fallback_model] : []);
      chain = chain.filter(m => typeof m === "string" && m.length);
      const fb = chain.length ? chain.join(",") : "-";
      return r.slug + "\t" + r.model + "\t" + (r.perspective || "-") + "\t" + fb + "\t" + (r.route_provider || "-") + "\t" + (r.fallback_trigger || "-") + "\t" + (r.fallback_provider || "-") + "\t" + (r.timeout_secs || "-");
    }).join("\n"));
  } catch (e) {
    process.exit(7);
  }
' 2>/dev/null)" || rows_rc=$?

# HIMMEL-2129 (HIMMEL-2128 follow-up): capture every USABLE non-Claude
# registry row this run's tier filter EXCLUDED (present in critics.json /
# critics.local.json, tier valid, just not in $TIER_FILTER) -- but only on
# the path where at least one OTHER row DID match ($rows non-empty here).
# The zero-match case handled below (rc 7/8) escalates the WHOLE registry to
# the paid anchor instead, a different and already-logged scenario; with
# today's single-critic registry that is the ONLY case that can occur, so
# this stays inert until a second non-Claude row exists to be excluded while
# others run. Fail-open on a read/parse error: no exclusion list, same as
# before this ticket existed.
_tier_excluded_raw=""
if [ -n "${rows:-}" ]; then
    _tier_excluded_raw="$(REG="$REG" TIER_FILTER="$TIER_FILTER" node -e '
      const fs = require("fs");
      const reg = process.env.REG;
      const tiers = (process.env.TIER_FILTER || "free").split(",").map(t => t.trim());
      try {
        const j = JSON.parse(fs.readFileSync(reg, "utf8"));
        const panel = Array.isArray(j.panel) ? j.panel : [];
        const nonEmptyStr = (v) => typeof v === "string" && v.trim().length > 0;
        const usable = panel.filter(r => r && typeof r === "object" &&
            nonEmptyStr(r.slug) && nonEmptyStr(r.model) && nonEmptyStr(r.tier));
        const excluded = usable.filter(r => !tiers.includes(r.tier));
        process.stdout.write(excluded.map(r => r.slug + "\t" + r.tier).join("\n"));
      } catch (e) { /* fail-open: no exclusion list */ }
    ' 2>/dev/null)"
fi

if [ -z "${rows:-}" ]; then
    # rc=8 (HIMMEL-1101): registry present and VALID, but zero rows match the
    # requested tier — the anchor fallback below then escalates to a PAID
    # critic. Say so: this path is how an unset CR_PROFILE (tier filter
    # "free", zero free rows registered) silently spends the OpenAI bank, and
    # it also bypasses HIMMEL-737's triviality gate, which only fires when
    # "paid" is IN the tier filter.
    # Each rc gets its OWN diagnostic: an `else` that swallows 7 together with
    # every unexpected rc (a node crash, an empty-stdout-at-rc-0) would report
    # "missing/invalid/empty" for a registry that is nothing of the sort — the
    # same over-broad message this split set out to kill.
    case "${rows_rc:-0}" in
        8)
            echo "critic-panel.sh: no critics in $REG match tier(s) '$TIER_FILTER' — falling back to the PAID anchor ($ANCHOR_SLUG/$ANCHOR_MODEL), which SPENDS the OpenAI bank (CR_PROFILE=none for claude-only)" >&2
            ;;
        7)
            echo "critic-panel.sh: registry $REG missing/invalid/empty — anchor-only ($ANCHOR_SLUG)" >&2
            ;;
        *)
            echo "critic-panel.sh: registry $REG parse failed unexpectedly (rc=${rows_rc:-0}) — anchor-only ($ANCHOR_SLUG)" >&2
            ;;
    esac
    rows="${ANCHOR_SLUG}	${ANCHOR_MODEL}	-	-	${ANCHOR_PROVIDER}	-	-	-"
fi

# HIMMEL-1950: "keep exactly ONE external critic" is enforced HERE, on the
# resolved rows, not by editing the tier filter above -- the filter selects a
# TIER and a tier may hold several members, which on a trivial diff would spend
# more than the gate was trying to save. First row wins: the registry is an
# ordered list and its head is the anchor-most critic (the registry carries no
# cost field, so "cheapest" is positional by construction, not inferred).
if [ "${_tg_keep_one:-0}" = "1" ]; then
    _tg_all_rows="$rows"
    rows="$(printf '%s\n' "$rows" | head -1)"
    _tg_dropped=$(( $(printf '%s\n' "$_tg_all_rows" | grep -c .) - 1 ))
    if [ "${_tg_dropped:-0}" -gt 0 ]; then
        echo "critic-panel.sh: trivial-diff cheap path - panel capped to 1 critic (${_tg_dropped} other paid member(s) skipped)" >&2
        # HIMMEL-2129: the skipped member(s) are configured AND available --
        # just not consulted, to save cost on a trivial diff -- so they must
        # not look like silence to clear-cr-marker's CR_FLOOR_FALLBACK=claude-
        # only exhaustion check (see the tier-exclusion capture above).
        _keepone_dropped_raw="$(printf '%s\n' "$_tg_all_rows" | tail -n +2)"
    fi
fi

# Write diff to a temp file so each member can read it via stdin redirect
tmp="$(mktemp -t critic-panel.XXXXXX)"
_seq_out=""
_seq_err=""
outdir=""
# Ledger evidence spool (HIMMEL-1494 r3; per-member r4): subshell-safe
# replacement for the old parent-scope STRING accumulators. The parallel path
# runs each member's critic in a background subshell; if process_member is ever
# moved into that subshell, parent-scope string accumulation would be silently
# lost (a subshell forks a copy-on-write snapshot of the vars). Appending to
# FILES instead survives the member boundary in BOTH sequential and parallel
# modes, and _append_panel_ledger reads them at the end.
# r4: ONE spool file PER MEMBER (avail.<slug> / finding.<slug>), not a single
# shared file. A single-printf O_APPEND row is atomic-ish on POSIX but NOT
# guaranteed on Windows/MSYS, so no two members ever append to the same file.
# Each member writes only its own file (a member is processed once, so its own
# file is never written concurrently); _append_panel_ledger globs them all, and
# bash sorts pathname expansion so the read order is deterministic.
PANEL_SPOOL_DIR="$(mktemp -d -t critic-panel-spool.XXXXXX)"
trap 'rm -f "$tmp"; [ -n "$_seq_out" ] && rm -f "$_seq_out"; [ -n "${_seq_err:-}" ] && rm -f "$_seq_err"; [ -n "$outdir" ] && rm -rf "$outdir"; [ -n "${PANEL_SPOOL_DIR:-}" ] && rm -rf "$PANEL_SPOOL_DIR"; [ -n "$_MERGED_REG" ] && rm -f "$_MERGED_REG"' EXIT
printf '%s' "$diff_in" > "$tmp"

# Run each panel member; collect per-member output and renumber globally.
# No associative arrays (Bash 3.2 safe); use positional temp files.
total=0
responded=0
global_id=0

# Section accumulators: newline-separated bullets
agg_crit=""
agg_imp=""
agg_sug=""
agg_drop=""
agg_drop_blocking=""
# member_parsed record separator (HIMMEL-1871 round 6): \034, matching the
# spool files above. NOT tab — tab is IFS *whitespace*, so `read` collapses
# consecutive tabs and an EMPTY interior field (file/line of a citation-less
# finding) would swallow its neighbours. \034 is non-whitespace: empty fields
# survive, and payload bytes stay harmless because the payload always rides
# LAST as a byte-exact remainder (position-structural records — no payload
# byte is ever scanned for a delimiter).
_PFS=$'\034'

# Ledger accumulators live in per-member spool files under PANEL_SPOOL_DIR
# (created above with $tmp — subshell-safe file spools, HIMMEL-1494 r3; one file
# per member r4). Keep availability and findings structured rather than reparsing
# stderr/stdout: availability has intermediate fallback-failed diagnostics that
# are NOT terminal member outcomes, while findings must preserve the exact
# reviewed head even if the orchestrator later commits a fix before judging them.

_queue_avail() {
    # Subshell-safe + per-member (HIMMEL-1494 r3/r4): append the row to THIS
    # member's own avail spool file, not a parent-scope string or a shared file.
    # A file append persists across a background-subshell member boundary (a
    # string mutation would not); per-member files mean no shared-file concurrent
    # append. $1 is the member slug — the registry accepts ANY non-empty value
    # (overlay slugs like "openai/gpt"), so the BUCKET filename sanitizes "/"
    # (HIMMEL-1871 round 6: an un-sanitized slash made the append target a
    # nonexistent subdir and silently lost the row under set +e). The row
    # CONTENT keeps the exact slug; buckets are only accumulation files that
    # _append_panel_ledger globs wholesale, so a name collision (a/b vs a_b)
    # merges buckets without corrupting rows.
    printf '%s\034%s\034%s\034%s\034%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" \
        >> "$PANEL_SPOOL_DIR/avail.${1//\//_}"
}

# HIMMEL-2129 (HIMMEL-2128 follow-up): emit a non-exhaustion avail row for
# every configured non-Claude critic THIS RUN deselected -- tier filter
# exclusion or the HIMMEL-1950 trivial-diff keep-one cap -- captured above as
# $_tier_excluded_raw / $_keepone_dropped_raw. clear-cr-marker.sh's
# CR_FLOOR_FALLBACK=claude-only check only accepts the claude-only floor when
# EVERY non-Claude lane that RECORDED an avail row is verified quota/rate-
# limit exhausted; a deselected-but-available lane previously left NO row at
# all, which looked exactly like "never configured" (silence) rather than
# "chose not to consult" -- the gap this ticket closes. reason=tier-excluded
# and reason=keep-one-skipped are both outside clear-cr-marker.sh's
# EXHAUSTION_REASONS set (quota/quota-5h/quota-long/rate-limit), so a row here
# correctly REFUSES the claude-only floor instead of silently clearing it.
# Deliberately NOT routed through process_member: these members never ran, so
# they must never increment total/responded (the zero-responder exit and the
# trivial-diff cost saving stay exactly what they were before this ticket).
if [ -n "$_tier_excluded_raw" ]; then
    printf '%s\n' "$_tier_excluded_raw" | while IFS=$'\t' read -r _te_slug _te_tier; do
        [ -n "$_te_slug" ] || continue
        echo "panel-availability: $_te_slug unavailable (tier=$_te_tier not in filter($TIER_FILTER)) reason=tier-excluded" >&2
        _queue_avail "$_te_slug" unavailable "" tier-excluded "tier=$_te_tier not in filter($TIER_FILTER)"
    done
fi
if [ -n "${_keepone_dropped_raw:-}" ]; then
    printf '%s\n' "$_keepone_dropped_raw" | while IFS=$'\t' read -r _ko_slug _ko_rest; do
        [ -n "$_ko_slug" ] || continue
        echo "panel-availability: $_ko_slug unavailable (trivial-diff keep-one cap) reason=keep-one-skipped" >&2
        _queue_avail "$_ko_slug" unavailable "" keep-one-skipped "cheapest external critic kept instead (HIMMEL-1950)"
    done
fi

_queue_finding() {
    # Subshell-safe + per-member + symmetric set -u safety (HIMMEL-1494 r3/r4):
    # see _queue_avail. The ${n:-} defaults mirror _queue_avail so a bare
    # positional under set -u can never abort the append.
    # $6 (HIMMEL-2078, optional): the panel's own rendered bullet line for
    # this finding, LAST so it may contain any byte including \034 — mirrors
    # the finding-batch record separator contract below (bullet payload rides
    # last as a byte-exact remainder, never scanned for a delimiter).
    printf '%s\034%s\034%s\034%s\034%s\034%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" "${6:-}" \
        >> "$PANEL_SPOOL_DIR/finding.${1//\//_}"
}

# _queue_attempt <slug> <responding_model> <attempt_num> <outcome> <duration_secs> [<detail>]
# HIMMEL-1500: one row per invocation ATTEMPT (the primary try + every
# fallback candidate), so a retried member (e.g. glm's self-retry chain,
# HIMMEL-1569) leaves its FULL timing history on the ledger instead of only
# the final avail verdict — the signal HIMMEL-1500 needs to correlate GLM
# one-shot timeouts against the suspected z.ai peak-usage window. Appended to
# a PER-MEMBER spool file (same subshell-safety rationale as _queue_avail):
# unlike avail.$1 (one authoritative row), attempt.$1 can and does grow past
# one line per member when a fallback chain runs.
_queue_attempt() {
    printf '%s\034%s\034%s\034%s\034%s\034%s\n' "$1" "$2" "$3" "$4" "$5" "${6:-}" \
        >> "$PANEL_SPOOL_DIR/attempt.${1//\//_}"
}

_append_panel_ledger() {
    _apl_failed=0
    # Glob the per-member spool files (HIMMEL-1494 r4): bash sorts pathname
    # expansion, so the read order is deterministic. [ -f ] guards the no-match
    # case (a finding.* glob with no findings would otherwise be a literal
    # pattern). set -- inside the loop reassigns positionals; the for-loop
    # iterates a named var, so it is unaffected.
    for _apl_spool in "$PANEL_SPOOL_DIR"/avail.*; do
        [ -f "$_apl_spool" ] || continue
        while IFS=$'\034' read -r _apl_model _apl_status _apl_responding _apl_reason _apl_detail; do
            [ -n "$_apl_model" ] || continue
            set -- avail --branch "$REVIEW_BRANCH" --head "$REVIEW_HEAD" \
                --model "$_apl_model" --status "$_apl_status"
            [ -n "$_apl_responding" ] && set -- "$@" --responding-model "$_apl_responding"
            [ -n "$_apl_reason" ] && set -- "$@" --reason "$_apl_reason"
            [ -n "$_apl_detail" ] && set -- "$@" --detail "$_apl_detail"
            CR_LEDGER="$PANEL_LEDGER" bash "$LEDGER_APPEND" "$@" || _apl_failed=1
        done < "$_apl_spool"
    done

    # HIMMEL-1500: attempt.* rows are NEVER deduped by ledger-append.sh (each
    # try — primary + every fallback candidate — gets its own line), unlike
    # avail.* above (one authoritative row per member).
    for _apl_spool in "$PANEL_SPOOL_DIR"/attempt.*; do
        [ -f "$_apl_spool" ] || continue
        while IFS=$'\034' read -r _apl_model _apl_responding _apl_attempt _apl_outcome _apl_duration _apl_detail; do
            [ -n "$_apl_model" ] || continue
            set -- attempt --branch "$REVIEW_BRANCH" --head "$REVIEW_HEAD" \
                --model "$_apl_model" --status "$_apl_outcome"
            [ -n "$_apl_responding" ] && set -- "$@" --responding-model "$_apl_responding"
            [ -n "$_apl_attempt" ] && set -- "$@" --attempt "$_apl_attempt"
            [ -n "$_apl_duration" ] && set -- "$@" --duration-secs "$_apl_duration"
            [ -n "$_apl_detail" ] && set -- "$@" --detail "$_apl_detail"
            CR_LEDGER="$PANEL_LEDGER" bash "$LEDGER_APPEND" "$@" || _apl_failed=1
        done < "$_apl_spool"
    done

    # HIMMEL-2052: one ledger-append.sh --batch-file call for ALL finding rows
    # instead of one `bash ledger-append.sh finding` invocation per row. Each
    # invocation used to re-read + re-parse the whole ledger and re-resolve
    # every legacy head from scratch; a 14-finding panel run could blow a 120s
    # tool budget (measured baseline: tens of seconds PER ROW against the live
    # ledger). Building the batch JSONL via node (not bash printf) keeps the
    # same "safe JSON + escaping" posture ledger-append.sh itself uses -
    # spool fields (file paths, severities) flow through JSON.stringify rather
    # than hand-built quoting.
    _apl_have_findings=0
    for _apl_spool in "$PANEL_SPOOL_DIR"/finding.*; do
        if [ -f "$_apl_spool" ]; then _apl_have_findings=1; fi
    done
    if [ "$_apl_have_findings" -eq 1 ]; then
        _apl_batch_file="$PANEL_SPOOL_DIR/.finding-batch.jsonl"
        # Hand node the spool CONTENT on stdin and take the JSONL back on
        # stdout - never a PATH through the environment. Git-Bash rewrites
        # POSIX-looking paths in env vars when it spawns a native node.exe; it
        # does that correctly for ONE path, but a newline-separated LIST is not
        # a shape it recognises, so on a 2+-critic panel the value arrived as
        # `C:\tmp\...` -> ENOENT -> _apl_failed -> panel exit 5 with EVERY
        # finding missing from the ledger. A single-critic run happened to
        # survive the rewrite, which is exactly why the one-member tests passed
        # while every real multi-critic run was uncertified. Nothing crosses the
        # boundary as a path now, so there is nothing left to rewrite.
        if { for _apl_spool in "$PANEL_SPOOL_DIR"/finding.*; do
                 if [ -f "$_apl_spool" ]; then cat "$_apl_spool"; fi
             done; } | REVIEW_BRANCH="$REVIEW_BRANCH" REVIEW_HEAD="$REVIEW_HEAD" node -e '
            const e=process.env;
            const lines=require("fs").readFileSync(0,"utf8").split("\n").filter(Boolean);
            const out=[];
            for (const line of lines) {
              const parts=line.split(String.fromCharCode(28));
              const [model,id,severity,file,ln]=parts;
              // text (HIMMEL-2078): the panel bullet is field 6, LAST, so it
              // may contain a literal \x1c byte — rejoin any split remainder
              // rather than reading parts[5] alone (mirrors the bullet
              // being a byte-exact remainder throughout this file).
              const text=parts.slice(5).join(String.fromCharCode(28));
              if(!id) continue;
              const row={branch:e.REVIEW_BRANCH,head:e.REVIEW_HEAD,
                model,id,severity,file,line:ln,verdict:""};
              if(text) row.text=text;
              out.push(JSON.stringify(row));
            }
            process.stdout.write(out.length?out.join("\n")+"\n":"");
        ' > "$_apl_batch_file"; then
            if [ -s "$_apl_batch_file" ]; then
                CR_LEDGER="$PANEL_LEDGER" bash "$LEDGER_APPEND" finding --batch-file "$_apl_batch_file" || _apl_failed=1
            fi
        else
            _apl_failed=1
        fi
    fi

    [ "$_apl_failed" -eq 0 ]
}

# HIMMEL-1065: emit the per-critic unavailability list for the zero-responder
# fail-closed block. Reads the SAME per-member avail spool _append_panel_ledger
# globs (one terminal record per member: slug, status, responding-model, reason,
# detail), so the stdout block and the ledger rows agree. Bash 3.2 safe (no
# arrays / mapfile).
_emit_unavailable_critics() {
    _uc_spool=""
    for _uc_spool in "$PANEL_SPOOL_DIR"/avail.*; do
        [ -f "$_uc_spool" ] || continue
        while IFS=$'\034' read -r _uc_slug _uc_status _uc_resp _uc_reason _uc_detail; do
            [ -n "$_uc_slug" ] || continue
            [ "$_uc_status" = "unavailable" ] || continue
            _uc_line="- $_uc_slug: unavailable"
            [ -n "$_uc_reason" ] && _uc_line="$_uc_line reason=$_uc_reason"
            [ -n "$_uc_detail" ] && _uc_line="$_uc_line ($_uc_detail)"
            printf '%s\n' "$_uc_line"
        done < "$_uc_spool"
    done
}

# ---------------------------------------------------------------------------
# _is_quota_exhaustion <out_file> <err_file> (HIMMEL-729)
# Return 0 (true) if the member's captured stdout OR stderr matches a
# quota-exhaustion signature. Used to decide whether to fall a failed member
# back to its OpenRouter fallback_model. A plain timeout (rc 124/137) never
# reaches here: process_member short-circuits timeouts BEFORE this check, so a
# timeout is never mistaken for exhaustion.
# Thin wrapper (HIMMEL-1176): the signature table itself now lives in
# scripts/cr/failure-classify.sh's is_quota_exhaustion, the SOLE owner, so
# critic-panel.sh's fallback trigger and classify_failure's quota-5h bucket
# never drift against two copies of the same table.
# ---------------------------------------------------------------------------
_is_quota_exhaustion() {
    is_quota_exhaustion "$@"
}

# ---------------------------------------------------------------------------
# _run_cfp_member <model> <slug> <perspective> <out_file> <err_file> (HIMMEL-729)
# Re-run a member through the SAME invocation path the primary run uses
# (critic-first-pass.sh, optional timeout wrap, optional --perspective-file),
# with the model swapped to the fallback. Writes stdout -> out_file, stderr ->
# err_file, and sets the global _rm_rc to the member exit code. Called from
# process_member's quota-exhaustion fallback branch, once PER CHAIN MEMBER
# (HIMMEL-737: the chain is iterated in order, each model attempted at most once).
# ---------------------------------------------------------------------------
_run_cfp_member() {
    _rm_model="$1"; _rm_slug="$2"; _rm_persp="${3:-}"; _rm_out="$4"; _rm_err="${5:-/dev/null}"; _rm_provider="${6:-}"
    # Per-attempt timeout override (HIMMEL-953 seat budget): the fallback loop
    # passes the REMAINING seat budget so a chain of hung candidates cannot
    # stack N full member timeouts. Unset -> the normal per-member timeout.
    _rm_to="${_RM_TIMEOUT_SECS:-$CRITIC_TIMEOUT_SECS}"
    if [ -n "$_rm_persp" ]; then
        if [ -n "$_TIMEOUT_BIN" ]; then
            "$_TIMEOUT_BIN" -k "$CRITIC_KILL_GRACE_SECS" "$_rm_to" bash "$CFP" \
                --model "$_rm_model" --provider "$_rm_provider" --slug "$_rm_slug" \
                --perspective-file "$SCRIPT_DIR/$_rm_persp" \
                < "$tmp" > "$_rm_out" 2>"$_rm_err"
            _rm_rc=$?
        else
            bash "$CFP" --model "$_rm_model" --provider "$_rm_provider" --slug "$_rm_slug" \
                --perspective-file "$SCRIPT_DIR/$_rm_persp" \
                < "$tmp" > "$_rm_out" 2>"$_rm_err"
            _rm_rc=$?
        fi
    else
        if [ -n "$_TIMEOUT_BIN" ]; then
            "$_TIMEOUT_BIN" -k "$CRITIC_KILL_GRACE_SECS" "$_rm_to" bash "$CFP" \
                --model "$_rm_model" --provider "$_rm_provider" --slug "$_rm_slug" \
                < "$tmp" > "$_rm_out" 2>"$_rm_err"
            _rm_rc=$?
        else
            bash "$CFP" --model "$_rm_model" --provider "$_rm_provider" --slug "$_rm_slug" \
                < "$tmp" > "$_rm_out" 2>"$_rm_err"
            _rm_rc=$?
        fi
    fi
}

# ---------------------------------------------------------------------------
# process_member: shared per-member logic called from both sequential and
# parallel result loops. Runs in the MAIN shell so it can update global_id,
# responded, agg_crit, agg_imp, agg_sug directly.
#
# $1 = slug
# $2 = path to member stdout file
# $3 = rc value (integer string)
# $4 = path to member stderr file (optional; pass "" to skip)
# $5 = fallback CHAIN for this slug (HIMMEL-737): comma-separated, ordered models
#      ("" = no quota-exhaustion fallback). Iterated in order, each at most once.
# $6 = perspective for this slug (optional; "" = no --perspective-file), threaded
#      into the fallback re-run so it uses the SAME invocation path as the primary
# $7 = primary model for this slug (used only for availability metadata)
# $8 = fallback PROVIDER for this slug's chain (HIMMEL-953, opt-in): explicit
#      --provider for every fallback attempt ("" = chain members stay
#      name-routed — hermes aliases, possibly cross-provider — per HIMMEL-729).
# $9 = fallback trigger mode for this slug (HIMMEL-953): "any" widens the
#      retry condition below to ANY non-zero rc (incl. timeout) instead of
#      requiring a quota-exhaustion signature match. Opt-in per row so the
#      HIMMEL-729 "don't mask a dead primary lane" contract stays the DEFAULT
#      for rows that don't set it ("" = exhaustion-signature-only, unchanged).
# $10 = the RESOLVED per-member timeout in seconds for this slug (HIMMEL-1245):
#      the row's timeout_secs when valid, else the shared CRITIC_TIMEOUT_SECS
#      default — already resolved by _resolve_member_timeout at the call site,
#      so this is used here only for accurate "unavailable (timeout Ns)"
#      reporting and the fallback-chain seat budget. Unset -> CRITIC_TIMEOUT_SECS.
# $11 = the MEASURED wall-clock duration (seconds) of the PRIMARY attempt
#      (HIMMEL-1500), timed by the caller around the invocation it already
#      makes. "" -> no attempt record is queued for the primary (keeps every
#      pre-existing caller, incl. every test stub, working unmodified).
# ---------------------------------------------------------------------------
# rc 4 from critic-first-pass.sh = COMPLETED response whose blocking findings
# were ALL dropped by citation validation (HIMMEL-1915 x HIMMEL-1871): valid,
# evidence-bearing output — never an error. ONE definition, shared by the
# primary path and the fallback chain: round 9's [high] was exactly a second,
# divergent copy of this decision (the chain accepted only rc 0, recorded 4 as
# an error, deleted the Dropped Citations evidence, and kept consulting
# candidates — a later clean response then cleared the panel with the guard
# never fired). Any future rc site MUST route through this helper.
_rc_completed() { [ "$1" -eq 0 ] || [ "$1" -eq 4 ]; }

process_member() {
    _pm_slug="$1"
    _pm_out_file="$2"
    _pm_rc="$3"
    _pm_err_file="${4:-}"
    _pm_fallback="${5:-}"
    _pm_perspective="${6:-}"
    _pm_model="${7:-}"
    # $8 = fallback_provider (HIMMEL-953, OPT-IN): explicit provider for the
    # fallback CHAIN. Unset -> chain members stay name-routed (hermes aliases,
    # possibly cross-provider) per the HIMMEL-729 registry contract.
    _pm_fb_provider="${8:-}"
    _pm_trigger="${9:-}"
    _pm_timeout="${10:-$CRITIC_TIMEOUT_SECS}"
    _pm_duration="${11:-}"
    # HIMMEL-1915 x HIMMEL-1871 (merge of #1730 into #1728): cfp exit 4 =
    # structurally VALID review whose blocking findings were ALL dropped by
    # citation validation. That is a RESPONSE, not unavailability — the
    # member's stdout carries the surviving non-blocking sections plus the
    # ## Dropped Citations evidence the panel citation guard blocks on.
    # Without this remap the generic failure branch below marked the member
    # unavailable and returned BEFORE parsing, so for the exact all-dropped
    # case this ticket exists for the guard never fired and no positive
    # blocking row reached the ledger. Map to the success path: the member is
    # counted responded (avail ok — truthful, it answered), zero validated
    # findings are queued, the drops flow to agg_drop/agg_drop_blocking, and
    # the guard mints its blocking ledger row. No fallback chain runs — the
    # model answered fine; re-asking another critic is the wrong response to
    # rejected citations.
    if _rc_completed "$_pm_rc"; then _pm_rc=0; fi
    if [ -n "$_pm_model" ]; then
        _pm_avail="panel-availability: $_pm_slug ok responding-model($_pm_model)"
    else
        _pm_avail="panel-availability: $_pm_slug ok"
    fi
    _pm_responding_model="$_pm_model"
    _fb_out=""
    _fb_err=""

    _pm_is_timeout=0
    if [ "$_pm_rc" -eq 124 ] || [ "$_pm_rc" -eq 137 ]; then
        _pm_is_timeout=1
    fi

    # HIMMEL-1500: record the PRIMARY attempt's timing unconditionally (ok,
    # timeout, or error) — the instrumentation this ticket exists for. Only
    # skipped when the caller passed no duration (older/hermetic callers that
    # don't measure it), so every existing test stub stays byte-for-byte
    # unaffected.
    if [ -n "$_pm_duration" ]; then
        _pm_attempt_outcome="error"
        [ "$_pm_rc" -eq 0 ] && _pm_attempt_outcome="ok"
        [ "$_pm_is_timeout" -eq 1 ] && _pm_attempt_outcome="timeout"
        _queue_attempt "$_pm_slug" "$_pm_model" 1 "$_pm_attempt_outcome" "$_pm_duration" "rc=$_pm_rc"
    fi

    # Decide up front whether this rc should attempt the fallback chain.
    # Default (unset trigger): only a quota-exhaustion signature on a
    # non-timeout failure retries — a bare timeout or a generic failure never
    # did (HIMMEL-729/737, still the contract for any OTHER row). trigger=any
    # (HIMMEL-953) widens this to ANY non-zero rc, timeout included — for a
    # row whose whole chain is same-tier candidates (e.g. all OpenRouter free
    # models), a plain rate-limit/outage on one candidate is exactly the
    # signal to try the next, not evidence the lane itself is broken.
    # Track WHY the chain fires separately from THAT it fires, so the WARN
    # line below can keep saying "quota-exhausted" only when it is true
    # (an "any"-triggered generic failure gets its own honest wording).
    _pm_exhaustion_match=0
    if [ -n "$_pm_fallback" ] && [ "$_pm_rc" -ne 0 ] && [ "$_pm_is_timeout" -eq 0 ] && _is_quota_exhaustion "$_pm_out_file" "$_pm_err_file"; then
        _pm_exhaustion_match=1
    fi
    _pm_do_fallback=0
    if [ -n "$_pm_fallback" ] && [ "$_pm_rc" -ne 0 ]; then
        if [ "$_pm_exhaustion_match" -eq 1 ] || [ "$_pm_trigger" = "any" ]; then
            _pm_do_fallback=1
        fi
    fi

    if [ "$_pm_is_timeout" -eq 1 ] && [ "$_pm_do_fallback" -eq 0 ]; then
        # HIMMEL-1500 auto-carry: the MEASURED duration (not just the
        # configured budget) rides on the avail detail, so a reader — incl.
        # the "unavailable critics" note now surfaced in the merged review
        # output below even on a PARTIAL degrade, not only the zero-responder
        # block — sees an honest "timed out after Ns" instead of a bare
        # config echo.
        _pm_timeout_detail=""
        [ -n "$_pm_duration" ] && _pm_timeout_detail="timed out after ${_pm_duration}s"
        echo "panel-availability: $_pm_slug unavailable (timeout ${_pm_timeout}s) reason=timeout" >&2
        _queue_avail "$_pm_slug" unavailable "" timeout "$_pm_timeout_detail"
        return
    fi
    if [ "$_pm_rc" -ne 0 ]; then
        # Quota-exhaustion (or, with trigger=any, ANY-failure) fallback CHAIN
        # (HIMMEL-729/737/953): re-run the member through the same
        # critic-first-pass path with each fallback model IN ORDER, each
        # attempted AT MOST ONCE. First success wins; a failed attempt logs
        # fallback-failed and advances; all exhausted -> member unavailable.
        if [ "$_pm_do_fallback" -eq 1 ]; then
            _fb_success=0
            # Iterate the comma-separated chain in order. IFS=',' splits it at the
            # for-header; the body uses only quoted expansions, so ',' is harmless
            # there. Restored after the loop.
            _fb_old_ifs="$IFS"; IFS=','
            # Seat budget (HIMMEL-953, codex-adv): the WHOLE chain shares one
            # extra member-timeout of wall-clock — N hung candidates must not
            # stack N full timeouts (observed 240s hangs on free tiers would
            # otherwise block a seat ~4x240s in sequential mode). Each attempt
            # gets the REMAINING budget via the _run_cfp_member override.
            _fb_deadline=$((SECONDS + _pm_timeout))
            # HIMMEL-1500: attempt 1 is the primary (already queued above);
            # each fallback candidate below is attempt 2, 3, ...
            _fb_attempt_num=1
            _fb_last_duration=""
            for _fb_model in $_pm_fallback; do
                [ -n "$_fb_model" ] || continue
                _fb_attempt_num=$((_fb_attempt_num + 1))
                # The TOTAL-panel budget outranks the chain's own seat budget
                # (HIMMEL-1289, public-PR CR). The HIMMEL-1280 clamp bounded the
                # PRIMARY attempt only; a trigger=any primary that times out
                # then entered this chain with a FRESH deadline built from the
                # full per-member timeout, so a run could exceed the total the
                # caller was promised. Refuse to start a candidate once the
                # panel budget is spent, and cap each one by what is left.
                if _panel_deadline_passed; then
                    echo "panel-availability: $_pm_slug fallback-chain stopped — total panel deadline reached reason=panel-deadline" >&2
                    break
                fi
                _fb_remaining=$((_fb_deadline - SECONDS))
                if [ "$_fb_remaining" -le 0 ]; then
                    echo "panel-availability: $_pm_slug fallback-chain budget exhausted (${_pm_timeout}s) — remaining candidates skipped" >&2
                    break
                fi
                _fb_remaining="$(_clamp_to_panel_budget "$_fb_remaining")"
                _RM_TIMEOUT_SECS="$_fb_remaining"
                _fb_out="$(mktemp -t critic-panel-fb.XXXXXX)"
                _fb_err="$(mktemp -t critic-panel-fb-err.XXXXXX)"
                _fb_start="$(date +%s)"
                _run_cfp_member "$_fb_model" "$_pm_slug" "$_pm_perspective" "$_fb_out" "$_fb_err" "$_pm_fb_provider"
                _fb_rc=$_rm_rc
                _fb_last_duration="$(( $(date +%s) - _fb_start ))"
                # HIMMEL-1500: this fallback candidate's own timing, same
                # outcome classification as the primary attempt above.
                _fb_attempt_outcome="error"
                _rc_completed "$_fb_rc" && _fb_attempt_outcome="ok"
                { [ "$_fb_rc" -eq 124 ] || [ "$_fb_rc" -eq 137 ]; } && _fb_attempt_outcome="timeout"
                _queue_attempt "$_pm_slug" "$_fb_model" "$_fb_attempt_num" "$_fb_attempt_outcome" "$_fb_last_duration" "rc=$_fb_rc"
                # _rc_completed, not -eq 0 (round 9): a fallback returning the
                # documented rc 4 has ANSWERED — an all-dropped review whose
                # stdout carries the Dropped Citations evidence the citation
                # guard blocks on. Accept it, keep its output, STOP the chain
                # (re-asking another critic is the wrong response to rejected
                # citations, same as the primary path); the shared success path
                # below then parses the drops and the guard mints its row.
                if _rc_completed "$_fb_rc"; then
                    if [ "$_pm_exhaustion_match" -eq 1 ]; then
                        echo "WARN critic-panel: $_pm_slug quota-exhausted - fell back to $_fb_model" >&2
                    else
                        echo "WARN critic-panel: $_pm_slug failed (rc=$_pm_rc) - fell back to $_fb_model" >&2
                    fi
                    _pm_avail="panel-availability: $_pm_slug fallback($_fb_model)"
                    _pm_responding_model="$_fb_model"
                    _pm_out_file="$_fb_out"
                    _fb_success=1
                    break
                fi
                # Surface a bounded head of the failed attempt's stderr before
                # deleting it (CR round: a bare rc collapses rate-limit vs auth
                # vs outage into the same line).
                _fb_snip="$(head -c 200 "$_fb_err" 2>/dev/null | tr '\n' ' ')"
                echo "panel-availability: $_pm_slug fallback-failed($_fb_model) (rc=$_fb_rc)${_fb_snip:+: $_fb_snip}" >&2
                rm -f "$_fb_out" "$_fb_err"
            done
            IFS="$_fb_old_ifs"
            unset _RM_TIMEOUT_SECS
            if [ "$_fb_success" -ne 1 ]; then
                # Reason capture (HIMMEL-1176): classify off the PRIMARY
                # attempt's captured files — $_pm_out_file/$_pm_err_file are
                # still the primary's (they are reassigned only on fallback
                # SUCCESS, above), so an exhausted chain keeps the primary's
                # reason, not the last fallback candidate's.
                _pm_reason="$(classify_failure "$_pm_rc" "$_pm_out_file" "$_pm_err_file" 2>/dev/null)"
                [ -n "$_pm_reason" ] || _pm_reason="generic-rc-$_pm_rc"
                # HIMMEL-1500: fold the last candidate's MEASURED duration into
                # the exhausted-chain detail so the ledger row (and the
                # unavailable-critics note surfaced below on a partial degrade)
                # carries actual elapsed time, not just the configured budget.
                _pm_exhausted_detail="fallback-chain exhausted"
                [ -n "$_fb_last_duration" ] && _pm_exhausted_detail="$_pm_exhausted_detail (last attempt ${_fb_last_duration}s)"
                if [ "$_pm_is_timeout" -eq 1 ]; then
                    echo "panel-availability: $_pm_slug unavailable (timeout ${_pm_timeout}s) reason=$_pm_reason detail=$_pm_exhausted_detail" >&2
                else
                    echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc) reason=$_pm_reason detail=$_pm_exhausted_detail" >&2
                fi
                _queue_avail "$_pm_slug" unavailable "" "$_pm_reason" "$_pm_exhausted_detail"
                return
            fi
        else
            _pm_reason="$(classify_failure "$_pm_rc" "$_pm_out_file" "$_pm_err_file" 2>/dev/null)"
            [ -n "$_pm_reason" ] || _pm_reason="generic-rc-$_pm_rc"
            # HIMMEL-2107: one line of the member's own stderr, turned into
            # ground truth ("reason=<class>" stops being a guess — the NOW-19
            # phantom http-4xx hunt would have ended on sight of this). Strip
            # control chars (codex CR, round 1): a \r, tab, or ANSI escape in
            # a subprocess's raw stderr must not corrupt this line or the
            # ledger row it also feeds. Redact (codex CR, round 2) with the
            # SAME anchored patterns ledger-append.sh's --detail scrub uses
            # (HIMMEL-1176) — this line reaches the stderr console BEFORE
            # ledger-append.sh's own scrub would ever see it.
            _pm_detail="$(head -n 1 "$_pm_err_file" 2>/dev/null | tr -d '[:cntrl:]' | sed -E \
                -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED]/g' \
                -e 's/(Bearer|bearer) [A-Za-z0-9._-]{16,}/\1 [REDACTED]/g' \
                -e 's/sk-[A-Za-z0-9][A-Za-z0-9_-]{15,}/[REDACTED]/g' \
                -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
                -e 's/([Aa][Pp][Ii][_-]?[Kk]ey|[Tt]oken|[Ss]ecret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]{12,}/\1=[REDACTED]/g')"
            echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc) reason=$_pm_reason${_pm_detail:+: $_pm_detail}" >&2
            _queue_avail "$_pm_slug" unavailable "" "$_pm_reason" "$_pm_detail"
            return
        fi
    fi
    echo "$_pm_avail" >&2
    _queue_avail "$_pm_slug" ok "$_pm_responding_model" "" ""
    responded=$((responded + 1))

    # Parse the member output sections and renumber bullets globally.
    # The member output format from critic-first-pass.sh:
    #   # <slug> First-Pass Review
    #
    #   ## Critical Issues (N found)
    #   - [<slug>-K]: ...
    #   ...
    #   ## Important Issues (N found)
    #   ...
    #   ## Suggestions (N found)
    #   ...
    #
    # We parse with awk, passing the current global_id base, and collect
    # section bullets. Records are \034-separated ($_PFS — see its comment),
    # bullet payload ALWAYS last as a byte-exact remainder:
    #   sections 1-3: "S\034id\034file\034line\034bullet"
    #   section 4:    "4\034blk\034rendered-drop-line"  (blk: 1=blocking)
    _pm_member_out="$(cat "$_pm_out_file")"
    # Fallback re-run temp files (HIMMEL-729): content now captured -> free them.
    # _fb_out/_fb_err stay "" on the primary-success path (no fallback ran).
    [ -n "$_fb_out" ] && rm -f "$_fb_out" "$_fb_err"
    member_parsed="$(printf '%s\n' "$_pm_member_out" | awk -v base="$global_id" -v slug="$_pm_slug" '
        BEGIN { sec = 0; max_id = base }
        /^## Critical Issues \([0-9]+ found\)/ { sec = 1; next }
        /^## Important Issues \([0-9]+ found\)/ { sec = 2; next }
        /^## Suggestions \([0-9]+ found\)/ { sec = 3; next }
        /^## Dropped Citations \([0-9]+ dropped\)/ { sec = 4; next }
        /^- / {
            # HIMMEL-1871 rounds 5-6: bullets are RAW critic-model bytes, so
            # the records are POSITION-structural: every head field is
            # machine-derived and separator-free, and the bullet payload rides
            # LAST as an unencoded byte-exact remainder. No payload byte is
            # ever scanned for a delimiter, so nothing a model emits can
            # shift, truncate, or merge fields — and no normalization touches
            # the evidence (round 5 normalized tab->space, which collapsed
            # tab-vs-space-distinct evidence to one guard digest: the same
            # inheritance failure, narrower).
            if (sec >= 1 && sec <= 3) {
                max_id++
                b = $0
                # Renumber: replace the ID with slug-max_id
                id = slug "-" max_id
                if (b ~ /^- \[[^]]*\]:/) {
                    sub(/^- \[[^]]*\]:/, "- [" id "]:", b)
                } else {
                    sub(/^- /, "- [" id "]: ", b)
                }
                loc = b
                sub(/^.*\[/, "", loc)
                sub(/\]$/, "", loc)
                # A finding citation is a TRAILING "[file:line]" (the merged
                # output bullet contract). When none is present the last bracket
                # is the ID "[slug-K]" (no colon, and the bullet does not end
                # with "]"), so loc carries finding text, not a path:line token.
                # Emit empty file/line then (HIMMEL-1494): the ledger absent-
                # value convention (file:""/line:""), not the malformed values
                # the old unguarded parse produced from the ID bracket.
                file = ""
                line = ""
                if (b ~ /\]$/ && loc ~ /:[0-9]+$/) {
                    file = loc
                    sub(/:[^:]*$/, "", file)
                    line = loc
                    sub(/^.*:/, "", line)
                }
                # Head fields are separator-free by construction: sec/id are
                # machine-built; line is digits; file came from a citation the
                # validator matched against real diff paths (git quotes paths
                # with control bytes, so they never enter the ranges). gsub
                # guards file anyway — head fields feed the LEDGER row, not
                # the digest, so this cannot collapse evidence.
                gsub("\034", " ", file)
                # Record: sec \034 id \034 file \034 line \034 bullet-remainder.
                print sec "\034" id "\034" file "\034" line "\034" b
            } else if (sec == 4) {
                # Rejected-citation evidence is recoverable review content, not a
                # validated model finding. Keep it out of global IDs and the
                # accuracy ledger; the panel adds its own blocking guard.
                # HIMMEL-1871 round 6: classify blocking-ness HERE, once, using
                # the KNOWN slug as a literal index() prefix match — never by
                # re-parsing the rendered "- slug / Section: " text downstream,
                # where a slug containing "/" (the registry accepts any
                # non-empty value, incl. overlay slugs like "openai/gpt") broke
                # the regex parse: the drop raised nd but fell out of
                # drop_blocking, and the guard silently never fired. Only the
                # Suggestions prefix demotes to non-blocking; Critical,
                # Important, and any UNRECOGNIZED shape stay blocking
                # (fail-closed: corrupted evidence holds the gate until a
                # human looks). Record: 4 \034 blk \034 rendered-line-remainder.
                blk = 1
                if (index($0, "- " slug " / Suggestions: ") == 1) blk = 0
                print sec "\034" blk "\034" $0
            }
            next
        }
    ')"

    # Update the global id counter: find the max id used. The id field is
    # "slug-N"; strip through the LAST dash (slug may contain dashes).
    max_used="$(printf '%s\n' "$member_parsed" | awk -F "$_PFS" '
        $1 ~ /^[123]$/ { n=$2; sub(/^.*-/,"",n); n=n+0; if (n>mx) mx=n }
        END { if (mx>0) print mx }' 2>/dev/null)"
    if [ -n "$max_used" ] && [ "$max_used" -gt "$global_id" ] 2>/dev/null; then
        global_id=$max_used
    fi

    # _pf_bullet is LAST so bash read hands it the remainder (a bullet may
    # contain any byte). HIMMEL-2078: now also queued as the finding's `text`
    # — the ledger row's one-line prose claim, so an unadjudicated finding is
    # still legible once the panel transcript is gone. Sec-4 records put blk
    # where _pf_id sits; the case below discards them. $_PFS is non-
    # whitespace, so read preserves EMPTY interior fields (a citation-less
    # finding has file="" line="").
    while IFS="$_PFS" read -r _pf_sec _pf_id _pf_file _pf_line _pf_bullet; do
        [ -n "$_pf_id" ] || continue
        case "$_pf_sec" in
            1) _pf_severity="crit" ;;
            2) _pf_severity="imp" ;;
            3) _pf_severity="sug" ;;
            *) continue ;;
        esac
        _queue_finding "$_pm_slug" "$_pf_id" "$_pf_severity" "$_pf_file" "$_pf_line" "$_pf_bullet"
    done << PARSEDFINDINGSEOF
$member_parsed
PARSEDFINDINGSEOF

    # Accumulate by section. The payload is recovered as the BYTE-EXACT
    # remainder after the fixed head fields — substr by head length, never a
    # field reference: model bytes may contain the separator, and a
    # field-based read would truncate at the first one (HIMMEL-1871 rounds
    # 5-6). Offsets: sections 1-3 skip 4 head fields + 4 separators; section
    # 4 skips 2 + 2. awk field-splitting on the head is safe because head
    # fields are separator-free by construction (see the encode comment).
    crit_bullets="$(printf '%s\n' "$member_parsed" | awk -F "$_PFS" '$1=="1"{print substr($0, length($1)+length($2)+length($3)+length($4)+5)}')"
    imp_bullets="$(printf '%s\n' "$member_parsed" | awk -F "$_PFS" '$1=="2"{print substr($0, length($1)+length($2)+length($3)+length($4)+5)}')"
    sug_bullets="$(printf '%s\n' "$member_parsed" | awk -F "$_PFS" '$1=="3"{print substr($0, length($1)+length($2)+length($3)+length($4)+5)}')"
    drop_bullets="$(printf '%s\n' "$member_parsed" | awk -F "$_PFS" '$1=="4"{print substr($0, length($1)+length($2)+3)}')"
    drop_blocking_bullets="$(printf '%s\n' "$member_parsed" | awk -F "$_PFS" '$1=="4" && $2=="1"{print substr($0, length($1)+length($2)+3)}')"

    if [ -n "$crit_bullets" ]; then
        if [ -n "$agg_crit" ]; then
            agg_crit="$(printf '%s\n%s' "$agg_crit" "$crit_bullets")"
        else
            agg_crit="$crit_bullets"
        fi
    fi
    if [ -n "$imp_bullets" ]; then
        if [ -n "$agg_imp" ]; then
            agg_imp="$(printf '%s\n%s' "$agg_imp" "$imp_bullets")"
        else
            agg_imp="$imp_bullets"
        fi
    fi
    if [ -n "$sug_bullets" ]; then
        if [ -n "$agg_sug" ]; then
            agg_sug="$(printf '%s\n%s' "$agg_sug" "$sug_bullets")"
        else
            agg_sug="$sug_bullets"
        fi
    fi
    if [ -n "$drop_bullets" ]; then
        if [ -n "$agg_drop" ]; then
            agg_drop="$(printf '%s\n%s' "$agg_drop" "$drop_bullets")"
        else
            agg_drop="$drop_bullets"
        fi
    fi
    if [ -n "$drop_blocking_bullets" ]; then
        if [ -n "$agg_drop_blocking" ]; then
            agg_drop_blocking="$(printf '%s\n%s' "$agg_drop_blocking" "$drop_blocking_bullets")"
        else
            agg_drop_blocking="$drop_blocking_bullets"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Sequential path (CRITIC_PARALLEL=0, default)
# ---------------------------------------------------------------------------
if [ "$CRITIC_PARALLEL" = "0" ]; then
    # Use a temp file per member so process_member can read from a path.
    # _seq_err captures each member's stderr so the quota-exhaustion signature
    # (HIMMEL-729) can be detected in sequential mode too (previously discarded).
    _seq_out="$(mktemp -t critic-panel-seq.XXXXXX)"
    _seq_err="$(mktemp -t critic-panel-seq-err.XXXXXX)"

    while IFS="	" read -r slug model perspective fallback_chain row_provider fallback_trigger fb_provider row_timeout; do
        [ -n "$slug" ] || continue
        # TOTAL-PANEL DEADLINE (HIMMEL-1280). CRITIC_TIMEOUT_SECS bounds ONE
        # member; nothing bounded the panel as a whole, so N members each
        # clipping their own budget could still hold a caller for N*240s.
        # Checked BETWEEN members — no signals, no self-kill: a watchdog that
        # kills its own process group is a worse hazard on msys than the stall
        # it fixes, and an in-flight member is already bounded by its own
        # timeout. Remaining members are reported unavailable so the caller's
        # ledger records a MISSING signal rather than silently fewer critics.
        if _panel_deadline_passed; then
            echo "critic-panel.sh: TOTAL panel deadline ${CRITIC_PANEL_TOTAL_TIMEOUT_SECS}s exceeded after ${total} member(s) — skipping the rest (raise CRITIC_PANEL_TOTAL_TIMEOUT_SECS)" >&2
            echo "panel-availability: $slug unavailable (panel-deadline) reason=panel-deadline" >&2
            _queue_avail "$slug" unavailable "" panel-deadline ""
            while IFS="	" read -r _s _rest; do
                [ -n "$_s" ] || continue
                echo "panel-availability: $_s unavailable (panel-deadline) reason=panel-deadline" >&2
                _queue_avail "$_s" unavailable "" panel-deadline ""
            done
            break
        fi
        # Map the "-" empty-field placeholder back to "" (see the registry
        # emission above — plain empty fields collapse under tab-IFS).
        [ "$perspective" = "-" ] && perspective=""
        [ "$fallback_chain" = "-" ] && fallback_chain=""
        [ "$row_provider" = "-" ] && row_provider=""
        [ "$fallback_trigger" = "-" ] && fallback_trigger=""
        [ "$fb_provider" = "-" ] && fb_provider=""
        [ "$row_timeout" = "-" ] && row_timeout=""
        total=$((total + 1))

        # Per-member timeout override (HIMMEL-1245): the row's timeout_secs
        # when valid, else the shared CRITIC_TIMEOUT_SECS default.
        member_timeout="$(_resolve_member_timeout "$slug" "$row_timeout")"
        # Cap by what is LEFT of the total budget (HIMMEL-1280 CR): otherwise the
        # total bound is really total + one member.
        member_timeout="$(_clamp_to_panel_budget "$member_timeout")"

        # Run this member (with per-member timeout if available). --provider ""
        # is a no-op in critic-first-pass.sh, so it is passed unconditionally.
        # HIMMEL-1500: wall-clock the invocation so process_member can queue
        # an `attempt` timing record — this is the instrumentation the ticket
        # asks for, measured here (the ONE place that actually invokes the
        # member) rather than trusted from the configured timeout.
        _seq_start="$(date +%s)"
        if [ -n "$perspective" ]; then
            if [ -n "$_TIMEOUT_BIN" ]; then
                "$_TIMEOUT_BIN" -k "$CRITIC_KILL_GRACE_SECS" "$member_timeout" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            else
                bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            fi
        else
            if [ -n "$_TIMEOUT_BIN" ]; then
                "$_TIMEOUT_BIN" -k "$CRITIC_KILL_GRACE_SECS" "$member_timeout" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            else
                bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            fi
        fi
        _seq_duration="$(( $(date +%s) - _seq_start ))"

        process_member "$slug" "$_seq_out" "$rc" "$_seq_err" "$fallback_chain" "$perspective" "$model" "$fb_provider" "$fallback_trigger" "$member_timeout" "$_seq_duration"

    done << ROWSEOF
$rows
ROWSEOF

# ---------------------------------------------------------------------------
# Parallel path (CRITIC_PARALLEL=1)
# ---------------------------------------------------------------------------
else
    outdir="$(mktemp -d -t critic-panel-par.XXXXXX)"

    # Launch each member indexed by position i (i=0,1,2,...)
    i=0
    while IFS="	" read -r slug model perspective fallback_chain row_provider fallback_trigger fb_provider row_timeout; do
        [ -n "$slug" ] || continue
        # TOTAL-PANEL DEADLINE, launch side (HIMMEL-1280 CR codex-1). The
        # sequential path had this; the parallel path did not, so with
        # CRITIC_PARALLEL=1 a member could still be LAUNCHED after the deadline
        # — the clamp alone only shortens it, it does not stop it starting.
        # Launches are near-instant here (each member is backgrounded), so this
        # normally only fires when setup itself blew the budget; it matters
        # exactly then, which is the case this ticket is about.
        if _panel_deadline_passed; then
            echo "critic-panel.sh: TOTAL panel deadline ${CRITIC_PANEL_TOTAL_TIMEOUT_SECS}s exceeded after launching ${i} member(s) — not launching the rest (raise CRITIC_PANEL_TOTAL_TIMEOUT_SECS)" >&2
            echo "panel-availability: $slug unavailable (panel-deadline) reason=panel-deadline" >&2
            _queue_avail "$slug" unavailable "" panel-deadline ""
            while IFS="	" read -r _s _rest; do
                [ -n "$_s" ] || continue
                echo "panel-availability: $_s unavailable (panel-deadline) reason=panel-deadline" >&2
                _queue_avail "$_s" unavailable "" panel-deadline ""
            done
            break
        fi
        # Map the "-" empty-field placeholder back to "" (see the registry
        # emission above — plain empty fields collapse under tab-IFS).
        [ "$perspective" = "-" ] && perspective=""
        [ "$fallback_chain" = "-" ] && fallback_chain=""
        [ "$row_provider" = "-" ] && row_provider=""
        [ "$fallback_trigger" = "-" ] && fallback_trigger=""
        [ "$fb_provider" = "-" ] && fb_provider=""
        [ "$row_timeout" = "-" ] && row_timeout=""
        total=$((total + 1))
        # Per-member timeout override (HIMMEL-1245): the row's timeout_secs
        # when valid, else the shared CRITIC_TIMEOUT_SECS default.
        member_timeout="$(_resolve_member_timeout "$slug" "$row_timeout")"
        # Cap by what is LEFT of the total budget (HIMMEL-1280 CR): otherwise the
        # total bound is really total + one member.
        member_timeout="$(_clamp_to_panel_budget "$member_timeout")"
        # Write slug and model so the result loop can recover them
        printf '%s' "$slug"  > "$outdir/$i.slug"
        printf '%s' "$model" > "$outdir/$i.model"
        # Per-row perspective + fallback chain (+ trigger mode, HIMMEL-953) so
        # the result loop can replay them into process_member (HIMMEL-729/737
        # quota-exhaustion fallback chain).
        printf '%s' "$perspective"     > "$outdir/$i.persp"
        printf '%s' "$fallback_chain"  > "$outdir/$i.fb"
        printf '%s' "$fallback_trigger" > "$outdir/$i.trigger"
        printf '%s' "$fb_provider"      > "$outdir/$i.fbprov"
        printf '%s' "$member_timeout"   > "$outdir/$i.timeout"
        # HIMMEL-1500: start/end epoch written across the subshell boundary
        # (same file-handoff pattern as .rc above) so the post-`wait` result
        # loop can compute this member's MEASURED duration for the `attempt`
        # ledger record. start is written in the PARENT (launches are
        # sequential even though bodies background), end in the subshell
        # itself right after the invocation.
        date +%s > "$outdir/$i.start"
        (
            if [ -n "$perspective" ]; then
                if [ -n "$_TIMEOUT_BIN" ]; then
                    "$_TIMEOUT_BIN" -k "$CRITIC_KILL_GRACE_SECS" "$member_timeout" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                else
                    bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                fi
            else
                if [ -n "$_TIMEOUT_BIN" ]; then
                    "$_TIMEOUT_BIN" -k "$CRITIC_KILL_GRACE_SECS" "$member_timeout" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                else
                    bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                fi
            fi
            date +%s > "$outdir/$i.end"
        ) &
        i=$((i + 1))
    done << ROWSEOF
$rows
ROWSEOF

    wait  # Bash 3.2 plain wait — waits for ALL background jobs

    # Process results in registry order (i=0, 1, 2, ..., total-1)
    i=0
    while [ "$i" -lt "$total" ]; do
        slug=""
        read -r slug < "$outdir/$i.slug" || true
        rc_val=1
        read -r rc_val < "$outdir/$i.rc" || true
        persp_val=""
        read -r persp_val < "$outdir/$i.persp" 2>/dev/null || true
        fb_val=""
        read -r fb_val < "$outdir/$i.fb" 2>/dev/null || true
        trig_val=""
        read -r trig_val < "$outdir/$i.trigger" 2>/dev/null || true
        fbprov_val=""
        read -r fbprov_val < "$outdir/$i.fbprov" 2>/dev/null || true
        timeout_val=""
        read -r timeout_val < "$outdir/$i.timeout" 2>/dev/null || true
        # Note: if .rc is absent (subshell received a signal during the .out write,
        # e.g. outer timeout SIGKILLs mid-run before the echo $? line runs),
        # rc_val stays at its initialized 1 → process_member treats the member as
        # unavailable (safe). The benign case (rc=0, .out empty) is also handled:
        # process_member sees zero findings and counts the member as responded.
        model_val=""
        read -r model_val < "$outdir/$i.model" 2>/dev/null || true
        # HIMMEL-1500: MEASURED duration from the .start/.end epoch pair
        # written around the launch above. Either file can be absent on the
        # same signal-during-run edge case noted for .rc — "" -> process_member
        # simply skips the attempt record for this member (safe, matches the
        # opt-in $11 contract), never an arithmetic error under set -u.
        start_val=""
        read -r start_val < "$outdir/$i.start" 2>/dev/null || true
        end_val=""
        read -r end_val < "$outdir/$i.end" 2>/dev/null || true
        dur_val=""
        if [ -n "$start_val" ] && [ -n "$end_val" ]; then
            dur_val=$((end_val - start_val))
        fi
        process_member "$slug" "$outdir/$i.out" "$rc_val" "$outdir/$i.err" "$fb_val" "$persp_val" "$model_val" "$fbprov_val" "$trig_val" "$timeout_val" "$dur_val"
        i=$((i + 1))
    done
fi

# Count bullets per section
nc=0; ni=0; ns=0; nd=0
[ -n "$agg_crit" ] && nc="$(printf '%s\n' "$agg_crit" | grep -c '^- ')" || nc=0
[ -n "$agg_imp"  ] && ni="$(printf '%s\n' "$agg_imp"  | grep -c '^- ')" || ni=0
[ -n "$agg_sug"  ] && ns="$(printf '%s\n' "$agg_sug"  | grep -c '^- ')" || ns=0
[ -n "$agg_drop" ] && nd="$(printf '%s\n' "$agg_drop" | grep -c '^- ')" || nd=0

# Rejected blocking citations are a completed response, not member unavailability:
# keep the panel's rc=0 availability contract, but add one PANEL-level Critical
# blocker. Existing callers already gate on Critical/Important counts, so this
# blocks structurally without sending the member through fallback or recording
# rejected bullets as model-accuracy findings. The rejected content is emitted
# separately.
#
# HIMMEL-1871 round 4 — both the trigger and the identity of the guard derive
# from the rejected evidence itself, never from the surrounding review's state:
#
#   Trigger: any rejected BLOCKING bullet (its original section, carried in the
#   drop line, was Critical/Important) fires the guard — even when other valid
#   blockers survived, so a dropped Important can no longer vanish behind a
#   surviving Critical that later gets disproved. Rejected Suggestions stay
#   readable under Dropped Citations but never block.
#
#   Identity: the finding id is a SHA-256 digest of the rejected blocking bullets.
#   ledger-append.sh dedups findings on (head, finding_id): with a CONSTANT id,
#   a same-head rerun whose citations were rejected for different reasons
#   deduped into the original guard row and inherited its disproved/deferred
#   amendment — adjudicated-by-inheritance, evidence never seen. A digest id
#   keeps an identical rerun idempotent (same evidence, same row, quiet dedup —
#   its adjudication legitimately carries) while different rejected evidence at
#   the same head mints a NEW verdict-less row that must be adjudicated itself.
#
# The blocker must ALSO reach the LEDGER, not just stdout. clear-cr-marker.sh
# derives clearance from the ledger alone (>=1 `avail ... ok` and no blocking
# finding), so a stdout-only blocker leaves a direct panel run + the sanctioned
# clear path able to clear the marker on an all-dropped review — the very
# false-clean this guard exists to stop, just moved one layer down. Queue it
# under a PANEL-level pseudo-slug so it is distinct from the rejected model
# findings: the member's bullets stay out of its accuracy score (they were
# never validated), while the guard itself blocks gate 4. The empty verdict is
# what makes it blocking — `crit` with a verdict that is neither `disproved`
# nor a tracked deferral is the gate's blocking definition.
# HIMMEL-1871 round 6: blocking classification was decided at DECODE time in
# process_member — the blk flag carried as data on the member_parsed channel —
# never by re-parsing the rendered "- slug / Section: " prefix here. The old
# regex reparse broke for any slug containing "/" (legal registry value): the
# drop raised nd but fell out of drop_blocking, ndb stayed 0, and the guard
# silently never fired — false clean. It also required grep to scan raw model
# bytes (the round-5 binary-heuristic concern); no code path greps model text
# for classification any more. The evidence below is BYTE-EXACT — no
# normalization — so distinct rejected evidence is a distinct digest input.
drop_blocking="$agg_drop_blocking"
ndb=0
[ -n "$drop_blocking" ] && ndb="$(printf '%s\n' "$drop_blocking" | grep -c '^- ')" || ndb=0
citation_guard_id=""
if [ "$ndb" -gt 0 ]; then
    nc=$((nc + 1))
    # SHA-256 (HIMMEL-1871 rounds 5-7): this id is the ledger dedup key for
    # (head, finding_id), so any digest weakness adjudicates NEW evidence by
    # inheriting an old row's verdict. Round 7: the digest must be validated
    # by SHAPE, not by tool presence — a present-but-FAILING sha256sum left
    # the digest empty and printf %.16s minted the CONSTANT id
    # "citation-guard-", the exact round-4 bug back. Shape-validate after each
    # attempt (sha256sum, then shasum -a 256 — Git Bash + Linux ship the
    # former, stock macOS only the latter; a missing/failing tool just yields
    # a non-matching value and falls through). If NO attempt produces 64 hex
    # chars, REFUSE the run (exit 6, fail-closed): no review body, no ledger
    # rows — an uncertifiable run must leave nothing a later run could dedup
    # against or a clear path could trust. The old cksum arm is REMOVED: a
    # 32-bit linear id silently weakening a gate identity is worse than a loud
    # refusal, and the no-tool box now lands on this same refusal path.
    # First 16 hex chars = 64 bits: legible in ledger rows.
    _guard_digest="$(printf '%s\n' "$drop_blocking" | sha256sum 2>/dev/null | awk '{print $1}')"
    if ! printf '%s' "$_guard_digest" | grep -qE '^[0-9a-f]{64}$'; then
        _guard_digest="$(printf '%s\n' "$drop_blocking" | shasum -a 256 2>/dev/null | awk '{print $1}')"
    fi
    if ! printf '%s' "$_guard_digest" | grep -qE '^[0-9a-f]{64}$'; then
        echo "critic-panel.sh: FATAL cannot compute the citation-guard SHA-256 id (sha256sum/shasum missing or failing) — refusing to certify this run (exit 6). Blocking findings were rejected by the citation validator; fix the digest tooling and re-run." >&2
        exit 6
    fi
    citation_guard_id="citation-guard-$(printf '%.16s' "$_guard_digest")"
    _queue_finding citation-guard "$citation_guard_id" crit "" ""
fi

# Emit merged block in heading contract format
printf '# Critic Panel Review (%d/%d critics responded)\n' "$responded" "$total"
printf '\n'
if [ "$responded" -ge 1 ]; then
    # HIMMEL-1500 auto-carry: a PARTIAL degrade (some, not all, critics
    # unavailable) used to be invisible in this branch's own output — only the
    # "(N/M critics responded)" header hinted at it, and only stderr's
    # panel-availability lines said WHO or WHY. A caller reading just the
    # merged stdout (a PR comment, a gate log) saw what looked like a clean
    # review from the critics that DID answer, with no record that e.g. GLM
    # was dropped after timing out. That is the "reports success while doing
    # nothing" failure class this ticket exists to close: the panel must
    # never let a partial degrade pass as if nothing were missing. Reuses
    # _emit_unavailable_critics (the SAME spool the zero-responder block below
    # and the ledger both read), so this note, the ledger's avail rows, and
    # the zero-responder block always agree.
    if [ "$responded" -lt "$total" ]; then
        printf '## Note: %d of %d critics did not respond (review proceeds on the rest)\n' \
            "$((total - responded))" "$total"
        printf '\n'
        _emit_unavailable_critics
        printf '\n'
    fi
    printf '## Critical Issues (%d found)\n' "$nc"
    [ -n "$agg_crit" ] && printf '%s\n' "$agg_crit"
    if [ -n "$citation_guard_id" ]; then
        printf '%s\n' "- [$citation_guard_id]: Review is not clean: $ndb blocking finding(s) were rejected because their citations were unverifiable. Inspect Dropped Citations below."
    fi
    printf '\n'
    printf '## Important Issues (%d found)\n' "$ni"
    [ -n "$agg_imp" ] && printf '%s\n' "$agg_imp"
    printf '\n'
    printf '## Suggestions (%d found)\n' "$ns"
    [ -n "$agg_sug" ] && printf '%s\n' "$agg_sug"
    if [ "$nd" -gt 0 ]; then
        printf '\n'
        printf '## Dropped Citations (%d dropped)\n' "$nd"
        printf '%s\n' "$agg_drop"
    fi
else
    # HIMMEL-1065: fail CLOSED on zero responders. The three "(0 found)"
    # sections are byte-identical to a genuinely clean review, so a
    # stdout-capturing caller (or a human reading a log) could conclude the PR
    # passed. Emit NO findings section; print an unmistakable unavailability
    # block naming which critics were unreachable and why, reusing the tracked
    # avail reasons (_emit_unavailable_critics reads the same spool as the
    # ledger). The ledger append + non-zero exit below STILL run — the
    # unavailable rows are what cr-scores.sh reports on, and the exit code is
    # the hard fail-closed signal.
    printf '## REVIEW NOT PERFORMED (0 of %d critics responded)\n' "$total"
    printf '\n'
    printf 'This is NOT a clean review. The panel reached no critic, so no\n'
    printf 'findings were collected. Do NOT treat this output as a passed review.\n'
    printf '\n'
    printf 'Unavailable critics:\n'
    _emit_unavailable_critics
    printf '\n'
    printf 'Resolve the unavailability above and re-run the review.\n'
fi

# The stdin-outside-worktree path skips certification (HIMMEL-1494): the review
# was emitted, but with no worktree there is nothing to stamp, so a failed (or
# skipped) append never overrides the review's own exit code.
if [ "${_SKIP_LEDGER:-0}" != "1" ]; then
    if ! _append_panel_ledger; then
        echo "critic-panel.sh: CR-ledger append failed; review output was emitted but this run is NOT certified" >&2
        exit 5
    fi
fi

[ "$responded" -ge 1 ] || exit 1
exit 0
