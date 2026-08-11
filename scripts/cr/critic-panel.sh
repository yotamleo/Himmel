#!/usr/bin/env bash
# scripts/cr/critic-panel.sh — run the free-cloud critic panel over a diff (HIMMEL-415).
# Reads a unified diff on stdin, or computes main...HEAD itself with
# --worktree <path>, then runs each registry critic in the CRITIC_PANEL_TIERS set
# (default free) via critic-first-pass.sh and merges findings (global renumber,
# per-model slug IDs). The panel appends its own availability + raw-finding rows
# to the CR ledger before it exits.
# Stdout = merged findings block. Stderr = panel-availability lines.
# Exit 0 = >=1 responded; 1 = all failed (caller -> claude-only); 2 = usage;
# 3 = invalid --worktree; 4 = --worktree diff is empty; 5 = git/ledger failure.
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
usage: critic-panel.sh [--worktree <path>] [--check [--all-tiers]]
  stdin                    review the unified diff read from stdin (back-compat)
  --worktree <path>        review `git -C <path> diff <base>...HEAD` (sanctioned)
                           <base> = CR_BASE_BRANCH env, else the remote's default
                           branch (refs/remotes/origin/HEAD), else main
  --check [--all-tiers]    probe registry health without reviewing a diff
exit 3: --worktree path is not a git worktree
exit 4: --worktree <base>...HEAD diff is empty (review refused)
exit 5: git metadata, diff computation, or CR-ledger persistence failed
USAGE
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
ANCHOR_MODEL="gpt-5.5"
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
while [ $# -gt 0 ]; do
    case "$1" in
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
    # Resolve the base branch instead of hardcoding `main` (HIMMEL-1494): a repo
    # whose default branch is master/other always hit the empty-diff / diff-failed
    # exits below. Order: an explicit CR_BASE_BRANCH override -> the remote's
    # default branch (symbolic-ref of refs/remotes/origin/HEAD, with the
    # refs/remotes/origin/ prefix stripped) -> main. The resolved name flows into
    # the diff and every diagnostic so a non-main default branch works.
    _base="${CR_BASE_BRANCH:-}"
    _base_via_origin=0
    if [ -z "$_base" ]; then
        _oh="$(git -C "$REVIEW_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" || _oh=""
        case "$_oh" in
            refs/remotes/origin/*) _base="${_oh#refs/remotes/origin/}"; _base_via_origin=1 ;;
        esac
        [ -n "$_base" ] || _base="main"
    fi
    # Re-resolve the bare name to a ref git can actually diff (HIMMEL-1494 r3).
    # A clone or worktree that carries only origin/<name> (and never checked
    # <name> out locally) fails on a bare name. An explicit CR_BASE_BRANCH
    # override is honored VERBATIM (documented). Otherwise: prefer the bare LOCAL
    # name when it verifies; else, for an origin/HEAD resolution, fall back to
    # the REMOTE origin/<name> the symbolic-ref guaranteed exists. If neither
    # verifies _base stays bare so the diff still fails loudly with the resolved
    # name (preserving the documented exit-5 diagnostic).
    # r4: verify refs/heads/<name> explicitly. A bare --verify <name> also
    # matches a TAG named like the default branch, which then falsely satisfied
    # this check and suppressed the origin/<name> fallback; qualifying the LOCAL
    # branch ref means only a real branch satisfies it (HIMMEL-1494 r4).
    if [ -z "${CR_BASE_BRANCH:-}" ]; then
        if ! git -C "$REVIEW_ROOT" rev-parse --verify "refs/heads/$_base" >/dev/null 2>&1; then
            if [ "$_base_via_origin" -eq 1 ]; then
                _base="origin/$_base"
            fi
        fi
    fi
    # Capture the reviewed head ONCE (HIMMEL-1494 r4) and reuse it for BOTH the
    # diff and the ledger stamp: a separate `git rev-parse HEAD` at stamp time
    # could resolve a different commit if a concurrent commit lands between the
    # two invocations, certifying a head that does not match the reviewed diff.
    # The diagnostics still read "<base>...HEAD" (the operator-visible intent);
    # $_head is that same HEAD, snapshotted here.
    _head="$(git -C "$REVIEW_ROOT" rev-parse HEAD 2>/dev/null)" || _head=""
    diff_in="$(git -C "$REVIEW_ROOT" diff "$_base...$_head")"
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
    REVIEW_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REVIEW_ROOT=""
    # Capture the head once for stamping coherence (HIMMEL-1494 r4): the stdin
    # diff is not HEAD-derived, but REVIEW_HEAD must still name the exact commit
    # under review, snapshotted here rather than re-resolved at stamp time.
    _head=""
    if [ -n "$REVIEW_ROOT" ]; then
        _head="$(git -C "$REVIEW_ROOT" rev-parse HEAD 2>/dev/null)" || _head=""
    fi
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
    REVIEW_BRANCH="$(git -C "$REVIEW_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || REVIEW_BRANCH=""
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
                # operator's profile and degrade to claude-only (rc=1 is the
                # caller's documented all-critics-failed fail-open path).
                echo "critic-panel.sh: triviality-gate verdict=trivial ($_tg_reason) stripped the ONLY requested tier (paid) - skipping panel, claude-only (CR_TRIVIALITY_OVERRIDE=full to force)" >&2
                exit 1
            fi
            TIER_FILTER="$_new_filter"
            echo "critic-panel.sh: triviality-gate verdict=trivial ($_tg_reason) - paid tier skipped (CR_TRIVIALITY_OVERRIDE=full to force)" >&2
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
    # append. $1 is the member slug (a registry kebab-case identifier, filesystem-
    # safe); _append_panel_ledger globs avail.* at the end.
    printf '%s\034%s\034%s\034%s\034%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" \
        >> "$PANEL_SPOOL_DIR/avail.$1"
}

_queue_finding() {
    # Subshell-safe + per-member + symmetric set -u safety (HIMMEL-1494 r3/r4):
    # see _queue_avail. The ${n:-} defaults mirror _queue_avail so a bare
    # positional under set -u can never abort the append.
    printf '%s\034%s\034%s\034%s\034%s\n' "$1" "$2" "${3:-}" "${4:-}" "${5:-}" \
        >> "$PANEL_SPOOL_DIR/finding.$1"
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

    for _apl_spool in "$PANEL_SPOOL_DIR"/finding.*; do
        [ -f "$_apl_spool" ] || continue
        while IFS=$'\034' read -r _apl_model _apl_id _apl_severity _apl_file _apl_line; do
            [ -n "$_apl_id" ] || continue
            CR_LEDGER="$PANEL_LEDGER" bash "$LEDGER_APPEND" finding \
                --branch "$REVIEW_BRANCH" --head "$REVIEW_HEAD" \
                --model "$_apl_model" --id "$_apl_id" \
                --severity "$_apl_severity" --file "$_apl_file" \
                --line "$_apl_line" --verdict "" || _apl_failed=1
        done < "$_apl_spool"
    done

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
# ---------------------------------------------------------------------------
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
        echo "panel-availability: $_pm_slug unavailable (timeout ${_pm_timeout}s) reason=timeout" >&2
        _queue_avail "$_pm_slug" unavailable "" timeout ""
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
            for _fb_model in $_pm_fallback; do
                [ -n "$_fb_model" ] || continue
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
                _run_cfp_member "$_fb_model" "$_pm_slug" "$_pm_perspective" "$_fb_out" "$_fb_err" "$_pm_fb_provider"
                _fb_rc=$_rm_rc
                if [ "$_fb_rc" -eq 0 ]; then
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
                if [ "$_pm_is_timeout" -eq 1 ]; then
                    echo "panel-availability: $_pm_slug unavailable (timeout ${_pm_timeout}s) reason=$_pm_reason detail=fallback-chain exhausted" >&2
                else
                    echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc) reason=$_pm_reason detail=fallback-chain exhausted" >&2
                fi
                _queue_avail "$_pm_slug" unavailable "" "$_pm_reason" "fallback-chain exhausted"
                return
            fi
        else
            _pm_reason="$(classify_failure "$_pm_rc" "$_pm_out_file" "$_pm_err_file" 2>/dev/null)"
            [ -n "$_pm_reason" ] || _pm_reason="generic-rc-$_pm_rc"
            echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc) reason=$_pm_reason" >&2
            _queue_avail "$_pm_slug" unavailable "" "$_pm_reason" ""
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
    # We parse with awk, passing the current global_id base,
    # and collect section bullets. Output format: "S<TAB>bullet" where S=1,2,3
    _pm_member_out="$(cat "$_pm_out_file")"
    # Fallback re-run temp files (HIMMEL-729): content now captured -> free them.
    # _fb_out/_fb_err stay "" on the primary-success path (no fallback ran).
    [ -n "$_fb_out" ] && rm -f "$_fb_out" "$_fb_err"
    member_parsed="$(printf '%s\n' "$_pm_member_out" | awk -v base="$global_id" -v slug="$_pm_slug" '
        BEGIN { sec = 0; max_id = base }
        /^## Critical Issues \([0-9]+ found\)/ { sec = 1; next }
        /^## Important Issues \([0-9]+ found\)/ { sec = 2; next }
        /^## Suggestions \([0-9]+ found\)/ { sec = 3; next }
        /^- / {
            if (sec > 0) {
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
                print sec "\t" b "\t" id "\t" file "\t" line
            }
            next
        }
    ')"

    # Update the global id counter: find the max id used.
    # POSIX-safe: strip the "- [slug-" prefix with sub(), then take the leading number.
    max_used="$(printf '%s\n' "$member_parsed" | awk -F'\t' '
        NF>=2 { b=$2; if (sub(/^- \[[^]]*-/,"",b)) { n=b+0; if (n>mx) mx=n } }
        END { if (mx>0) print mx }' 2>/dev/null)"
    if [ -n "$max_used" ] && [ "$max_used" -gt "$global_id" ] 2>/dev/null; then
        global_id=$max_used
    fi

    while IFS=$'\t' read -r _pf_sec _pf_bullet _pf_id _pf_file _pf_line; do
        [ -n "$_pf_id" ] || continue
        case "$_pf_sec" in
            1) _pf_severity="crit" ;;
            2) _pf_severity="imp" ;;
            3) _pf_severity="sug" ;;
            *) continue ;;
        esac
        _queue_finding "$_pm_slug" "$_pf_id" "$_pf_severity" "$_pf_file" "$_pf_line"
    done << PARSEDFINDINGSEOF
$member_parsed
PARSEDFINDINGSEOF

    # Accumulate by section
    crit_bullets="$(printf '%s\n' "$member_parsed" | awk -F'\t' '$1=="1"{print $2}')"
    imp_bullets="$(printf '%s\n' "$member_parsed" | awk -F'\t' '$1=="2"{print $2}')"
    sug_bullets="$(printf '%s\n' "$member_parsed" | awk -F'\t' '$1=="3"{print $2}')"

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

        process_member "$slug" "$_seq_out" "$rc" "$_seq_err" "$fallback_chain" "$perspective" "$model" "$fb_provider" "$fallback_trigger" "$member_timeout"

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
        process_member "$slug" "$outdir/$i.out" "$rc_val" "$outdir/$i.err" "$fb_val" "$persp_val" "$model_val" "$fbprov_val" "$trig_val" "$timeout_val"
        i=$((i + 1))
    done
fi

# Count bullets per section
nc=0; ni=0; ns=0
[ -n "$agg_crit" ] && nc="$(printf '%s\n' "$agg_crit" | grep -c '^- ')" || nc=0
[ -n "$agg_imp"  ] && ni="$(printf '%s\n' "$agg_imp"  | grep -c '^- ')" || ni=0
[ -n "$agg_sug"  ] && ns="$(printf '%s\n' "$agg_sug"  | grep -c '^- ')" || ns=0

# Emit merged block in heading contract format
printf '# Critic Panel Review (%d/%d critics responded)\n' "$responded" "$total"
printf '\n'
if [ "$responded" -ge 1 ]; then
    printf '## Critical Issues (%d found)\n' "$nc"
    [ -n "$agg_crit" ] && printf '%s\n' "$agg_crit"
    printf '\n'
    printf '## Important Issues (%d found)\n' "$ni"
    [ -n "$agg_imp" ] && printf '%s\n' "$agg_imp"
    printf '\n'
    printf '## Suggestions (%d found)\n' "$ns"
    [ -n "$agg_sug" ] && printf '%s\n' "$agg_sug"
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
