#!/usr/bin/env bash
# scripts/cr/critic-panel.sh — run the free-cloud critic panel over a diff (HIMMEL-415).
# Reads a unified diff on stdin, runs each registry critic in the CRITIC_PANEL_TIERS
# set (default free) via critic-first-pass.sh, merges findings (global renumber, per-model slug IDs).
# Stdout = merged findings block. Stderr = panel-availability lines.
# Exit 0 = >=1 responded; 1 = all failed (caller -> claude-only). Bash 3.2-safe.
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
#      CRITIC_PARALLEL — set to 1 to run critics concurrently (default 0 = sequential).
#          Output is byte-identical to sequential: results merged in registry order.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFP="${CRITIC_FIRST_PASS:-$SCRIPT_DIR/critic-first-pass.sh}"
# Registry resolution (HIMMEL-727 operator-vs-universal split): CRITICS_JSON env
# (tests/CI) > critics.local.json (gitignored per-operator overlay — carries
# ACCOUNT state like exhausted free quotas / upgraded models, so the shipped
# registry stays adopter-neutral) > critics.json (universal defaults).
if [ -n "${CRITICS_JSON:-}" ]; then
    REG="$CRITICS_JSON"
elif [ -f "$SCRIPT_DIR/critics.local.json" ]; then
    REG="$SCRIPT_DIR/critics.local.json"
    echo "critic-panel.sh: using operator-local registry critics.local.json" >&2
else
    REG="$SCRIPT_DIR/critics.json"
fi
INVOKE="${CRITIC_INVOKE:-$SCRIPT_DIR/../hermes/invoke.sh}"

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
    : # valid
else
    echo "critic-panel.sh: CRITIC_TIMEOUT_SECS=$CRITIC_TIMEOUT_SECS invalid, using 240" >&2
    CRITIC_TIMEOUT_SECS="240"
fi

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
        *)
            echo "critic-panel.sh: unknown option $1" >&2
            exit 2
            ;;
    esac
done

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
    trap 'rm -f "$check_prompt"' EXIT
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
    trap - EXIT
    [ "$check_failed" -eq 0 ] || exit 1
    exit 0
fi

# Read diff from stdin and store it
diff_in="$(cat)"

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
    process.stdout.write(p.map(r => {
      let chain = Array.isArray(r.fallback_models) ? r.fallback_models
                : (r.fallback_model ? [r.fallback_model] : []);
      chain = chain.filter(m => typeof m === "string" && m.length);
      const fb = chain.length ? chain.join(",") : "-";
      return r.slug + "\t" + r.model + "\t" + (r.perspective || "-") + "\t" + fb + "\t" + (r.route_provider || "-") + "\t" + (r.fallback_trigger || "-") + "\t" + (r.fallback_provider || "-");
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
    rows="${ANCHOR_SLUG}	${ANCHOR_MODEL}	-	-	${ANCHOR_PROVIDER}	-	-"
fi

# Write diff to a temp file so each member can read it via stdin redirect
tmp="$(mktemp -t critic-panel.XXXXXX)"
_seq_out=""
_seq_err=""
outdir=""
trap 'rm -f "$tmp"; [ -n "$_seq_out" ] && rm -f "$_seq_out"; [ -n "${_seq_err:-}" ] && rm -f "$_seq_err"; [ -n "$outdir" ] && rm -rf "$outdir"' EXIT
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

# ---------------------------------------------------------------------------
# _is_quota_exhaustion <out_file> <err_file> (HIMMEL-729)
# Return 0 (true) if the member's captured stdout OR stderr matches a
# quota-exhaustion signature. Used to decide whether to fall a failed member
# back to its OpenRouter fallback_model. A plain timeout (rc 124/137) never
# reaches here: process_member short-circuits timeouts BEFORE this check, so a
# timeout is never mistaken for exhaustion.
# ---------------------------------------------------------------------------
_is_quota_exhaustion() {
    # Bare AccessDenied is NOT exhaustion (codex adversarial CR on HIMMEL-729):
    # e.g. Alibaba's AccessDenied.Unpurchased means "service not activated" and
    # a plain AccessDenied is an auth/permission failure — falling back on those
    # would mask a dead primary lane as a healthy critic. AccessDenied counts
    # only when PAIRED with an exhaustion/quota/arrearage phrase.
    # NOTE: plain .* is correct here — grep matches line-by-line, so .* can
    # never cross a newline; [^\n] in POSIX ERE would wrongly mean "any char
    # except backslash or the letter n" (codex CR round 2).
    # AllocationQuota.FreeTierOnly (HIMMEL-736): Alibaba Stop-on-Exhaust's
    # documented free-tier-exhaustion 403 code — the dotted literal, kept
    # tight so bare "AllocationQuota" elsewhere can't false-positive.
    _qe_sig='exceeded.*quota|quota.*exhaust|Arrearage|Throttling\.User|allocated quota|AllocationQuota\.FreeTierOnly|AccessDenied.*(quota|exhaust|arrear)|(quota|exhaust|arrear).*AccessDenied'
    if [ -n "$1" ] && [ -f "$1" ] && grep -qiE "$_qe_sig" "$1"; then
        return 0
    fi
    if [ -n "${2:-}" ] && [ -f "$2" ] && grep -qiE "$_qe_sig" "$2"; then
        return 0
    fi
    return 1
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
            "$_TIMEOUT_BIN" -k 5 "$_rm_to" bash "$CFP" \
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
            "$_TIMEOUT_BIN" -k 5 "$_rm_to" bash "$CFP" \
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
    if [ -n "$_pm_model" ]; then
        _pm_avail="panel-availability: $_pm_slug ok responding-model($_pm_model)"
    else
        _pm_avail="panel-availability: $_pm_slug ok"
    fi
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
        echo "panel-availability: $_pm_slug unavailable (timeout ${CRITIC_TIMEOUT_SECS}s)" >&2
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
            _fb_deadline=$((SECONDS + CRITIC_TIMEOUT_SECS))
            for _fb_model in $_pm_fallback; do
                [ -n "$_fb_model" ] || continue
                _fb_remaining=$((_fb_deadline - SECONDS))
                if [ "$_fb_remaining" -le 0 ]; then
                    echo "panel-availability: $_pm_slug fallback-chain budget exhausted (${CRITIC_TIMEOUT_SECS}s) — remaining candidates skipped" >&2
                    break
                fi
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
                if [ "$_pm_is_timeout" -eq 1 ]; then
                    echo "panel-availability: $_pm_slug unavailable (timeout ${CRITIC_TIMEOUT_SECS}s)" >&2
                else
                    echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc)" >&2
                fi
                return
            fi
        else
            echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc)" >&2
            return
        fi
    fi
    echo "$_pm_avail" >&2
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
                if (b ~ /^- \[[^]]*\]:/) {
                    sub(/^- \[[^]]*\]:/, "- [" slug "-" max_id "]:", b)
                } else {
                    sub(/^- /, "- [" slug "-" max_id "]: ", b)
                }
                print sec "\t" b
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

    while IFS="	" read -r slug model perspective fallback_chain row_provider fallback_trigger fb_provider; do
        [ -n "$slug" ] || continue
        # Map the "-" empty-field placeholder back to "" (see the registry
        # emission above — plain empty fields collapse under tab-IFS).
        [ "$perspective" = "-" ] && perspective=""
        [ "$fallback_chain" = "-" ] && fallback_chain=""
        [ "$row_provider" = "-" ] && row_provider=""
        [ "$fallback_trigger" = "-" ] && fallback_trigger=""
        [ "$fb_provider" = "-" ] && fb_provider=""
        total=$((total + 1))

        # Run this member (with per-member timeout if available). --provider ""
        # is a no-op in critic-first-pass.sh, so it is passed unconditionally.
        if [ -n "$perspective" ]; then
            if [ -n "$_TIMEOUT_BIN" ]; then
                "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            else
                bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            fi
        else
            if [ -n "$_TIMEOUT_BIN" ]; then
                "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            else
                bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            fi
        fi

        process_member "$slug" "$_seq_out" "$rc" "$_seq_err" "$fallback_chain" "$perspective" "$model" "$fb_provider" "$fallback_trigger"

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
    while IFS="	" read -r slug model perspective fallback_chain row_provider fallback_trigger fb_provider; do
        [ -n "$slug" ] || continue
        # Map the "-" empty-field placeholder back to "" (see the registry
        # emission above — plain empty fields collapse under tab-IFS).
        [ "$perspective" = "-" ] && perspective=""
        [ "$fallback_chain" = "-" ] && fallback_chain=""
        [ "$row_provider" = "-" ] && row_provider=""
        [ "$fallback_trigger" = "-" ] && fallback_trigger=""
        [ "$fb_provider" = "-" ] && fb_provider=""
        total=$((total + 1))
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
        (
            if [ -n "$perspective" ]; then
                if [ -n "$_TIMEOUT_BIN" ]; then
                    "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                else
                    bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                fi
            else
                if [ -n "$_TIMEOUT_BIN" ]; then
                    "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --provider "$row_provider" --slug "$slug" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
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
        # Note: if .rc is absent (subshell received a signal during the .out write,
        # e.g. outer timeout SIGKILLs mid-run before the echo $? line runs),
        # rc_val stays at its initialized 1 → process_member treats the member as
        # unavailable (safe). The benign case (rc=0, .out empty) is also handled:
        # process_member sees zero findings and counts the member as responded.
        model_val=""
        read -r model_val < "$outdir/$i.model" 2>/dev/null || true
        process_member "$slug" "$outdir/$i.out" "$rc_val" "$outdir/$i.err" "$fb_val" "$persp_val" "$model_val" "$fbprov_val" "$trig_val"
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
printf '## Critical Issues (%d found)\n' "$nc"
[ -n "$agg_crit" ] && printf '%s\n' "$agg_crit"
printf '\n'
printf '## Important Issues (%d found)\n' "$ni"
[ -n "$agg_imp" ] && printf '%s\n' "$agg_imp"
printf '\n'
printf '## Suggestions (%d found)\n' "$ns"
[ -n "$agg_sug" ] && printf '%s\n' "$agg_sug"

[ "$responded" -ge 1 ] || exit 1
exit 0
