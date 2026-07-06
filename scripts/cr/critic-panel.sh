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
#          qwen3coder anchor were observed timing out at exactly 150s and contributing
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
REG="${CRITICS_JSON:-$SCRIPT_DIR/critics.json}"
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

ANCHOR_SLUG="qwen3coder"
ANCHOR_MODEL="qwen3-coder-plus"

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
    process.stdout.write(p.map(r => r.slug + "\t" + r.model + "\t" + (r.tier || "")).join("\n"));
  } catch (e) {
    process.exit(7);
  }
' 2>/dev/null)" || check_rows=""

    if [ -z "${check_rows:-}" ]; then
        echo "critic-panel.sh: registry $REG missing/invalid/empty — anchor-only ($ANCHOR_SLUG)" >&2
        check_rows="${ANCHOR_SLUG}	${ANCHOR_MODEL}	free"
    fi

    check_prompt="$(mktemp -t critic-panel-check.XXXXXX)"
    trap 'rm -f "$check_prompt"' EXIT
    printf '%s' 'Reply with exactly: ok' > "$check_prompt"

    check_failed="0"
    while IFS="	" read -r slug model tier; do
        [ -n "$slug" ] || continue
        if [ "$tier" = "paid" ] && [ "$CHECK_ALL_TIERS" != "1" ]; then
            echo "row $slug: skipped (paid)"
            continue
        fi
        "$INVOKE" --model "$model" --prompt-file "$check_prompt" >/dev/null 2>&1
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

# Parse registry: emit "slug<TAB>model<TAB>perspective" lines for matching tiers.
# Falls back to anchor on missing/invalid/empty registry.
rows="$(REG="$REG" TIER_FILTER="$TIER_FILTER" node -e '
  const fs = require("fs");
  const reg  = process.env.REG;
  const tiers = (process.env.TIER_FILTER || "free").split(",").map(t => t.trim());
  try {
    const j = JSON.parse(fs.readFileSync(reg, "utf8"));
    const p = (j.panel || []).filter(r => r.slug && r.model && tiers.includes(r.tier));
    if (!p.length) throw new Error("no rows");
    // "-" placeholder for empty middle fields: tab is IFS WHITESPACE in the
    // bash readers, so consecutive tabs collapse and a non-empty 4th field
    // would shift LEFT into the perspective slot (HIMMEL-729 field-shift bug).
    process.stdout.write(p.map(r => r.slug + "\t" + r.model + "\t" + (r.perspective || "-") + "\t" + (r.fallback_model || "-")).join("\n"));
  } catch (e) {
    process.exit(7);
  }
' 2>/dev/null)" || rows=""

if [ -z "${rows:-}" ]; then
    echo "critic-panel.sh: registry $REG missing/invalid/empty — anchor-only ($ANCHOR_SLUG)" >&2
    rows="${ANCHOR_SLUG}	${ANCHOR_MODEL}"
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
    _qe_sig='exceeded.*quota|quota.*exhaust|Arrearage|Throttling\.User|allocated quota|AccessDenied.*(quota|exhaust|arrear)|(quota|exhaust|arrear).*AccessDenied'
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
# err_file, and sets the global _rm_rc to the member exit code. Called only from
# process_member's quota-exhaustion fallback branch (EXACTLY ONCE per member).
# ---------------------------------------------------------------------------
_run_cfp_member() {
    _rm_model="$1"; _rm_slug="$2"; _rm_persp="${3:-}"; _rm_out="$4"; _rm_err="${5:-/dev/null}"
    if [ -n "$_rm_persp" ]; then
        if [ -n "$_TIMEOUT_BIN" ]; then
            "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" \
                --model "$_rm_model" --slug "$_rm_slug" \
                --perspective-file "$SCRIPT_DIR/$_rm_persp" \
                < "$tmp" > "$_rm_out" 2>"$_rm_err"
            _rm_rc=$?
        else
            bash "$CFP" --model "$_rm_model" --slug "$_rm_slug" \
                --perspective-file "$SCRIPT_DIR/$_rm_persp" \
                < "$tmp" > "$_rm_out" 2>"$_rm_err"
            _rm_rc=$?
        fi
    else
        if [ -n "$_TIMEOUT_BIN" ]; then
            "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" \
                --model "$_rm_model" --slug "$_rm_slug" \
                < "$tmp" > "$_rm_out" 2>"$_rm_err"
            _rm_rc=$?
        else
            bash "$CFP" --model "$_rm_model" --slug "$_rm_slug" \
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
# $5 = fallback_model for this slug (optional; "" = no quota-exhaustion fallback)
# $6 = perspective for this slug (optional; "" = no --perspective-file), threaded
#      into the fallback re-run so it uses the SAME invocation path as the primary
# ---------------------------------------------------------------------------
process_member() {
    _pm_slug="$1"
    _pm_out_file="$2"
    _pm_rc="$3"
    _pm_err_file="${4:-}"
    _pm_fallback="${5:-}"
    _pm_perspective="${6:-}"
    _pm_avail="panel-availability: $_pm_slug ok"
    _fb_out=""
    _fb_err=""

    if [ "$_pm_rc" -eq 124 ] || [ "$_pm_rc" -eq 137 ]; then
        echo "panel-availability: $_pm_slug unavailable (timeout ${CRITIC_TIMEOUT_SECS}s)" >&2
        return
    fi
    if [ "$_pm_rc" -ne 0 ]; then
        # Quota-exhaustion fallback (HIMMEL-729): if the slug has a fallback_model
        # AND the member output/stderr matches an exhaustion signature, re-run the
        # member ONCE through the same critic-first-pass path with the fallback
        # model. A plain non-exhaustion failure (or a timeout, handled above) gets
        # the original unavailable line and NO retry.
        if [ -n "$_pm_fallback" ] && _is_quota_exhaustion "$_pm_out_file" "$_pm_err_file"; then
            _fb_out="$(mktemp -t critic-panel-fb.XXXXXX)"
            _fb_err="$(mktemp -t critic-panel-fb-err.XXXXXX)"
            _run_cfp_member "$_pm_fallback" "$_pm_slug" "$_pm_perspective" "$_fb_out" "$_fb_err"
            _fb_rc=$_rm_rc
            if [ "$_fb_rc" -eq 0 ]; then
                echo "WARN critic-panel: $_pm_slug quota-exhausted - fell back to $_pm_fallback (openrouter)" >&2
                _pm_avail="panel-availability: $_pm_slug fallback($_pm_fallback)"
                _pm_out_file="$_fb_out"
            else
                echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc)" >&2
                echo "panel-availability: $_pm_slug fallback-failed (rc=$_fb_rc)" >&2
                rm -f "$_fb_out" "$_fb_err"
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

    while IFS="	" read -r slug model perspective fallback_model; do
        [ -n "$slug" ] || continue
        # Map the "-" empty-field placeholder back to "" (see the registry
        # emission above — plain empty fields collapse under tab-IFS).
        [ "$perspective" = "-" ] && perspective=""
        [ "$fallback_model" = "-" ] && fallback_model=""
        total=$((total + 1))

        # Run this member (with per-member timeout if available)
        if [ -n "$perspective" ]; then
            if [ -n "$_TIMEOUT_BIN" ]; then
                "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            else
                bash "$CFP" --model "$model" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            fi
        else
            if [ -n "$_TIMEOUT_BIN" ]; then
                "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            else
                bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$_seq_out" 2>"$_seq_err"
                rc=$?
            fi
        fi

        process_member "$slug" "$_seq_out" "$rc" "$_seq_err" "$fallback_model" "$perspective"

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
    while IFS="	" read -r slug model perspective fallback_model; do
        [ -n "$slug" ] || continue
        # Map the "-" empty-field placeholder back to "" (see the registry
        # emission above — plain empty fields collapse under tab-IFS).
        [ "$perspective" = "-" ] && perspective=""
        [ "$fallback_model" = "-" ] && fallback_model=""
        total=$((total + 1))
        # Write slug and model so the result loop can recover them
        printf '%s' "$slug"  > "$outdir/$i.slug"
        printf '%s' "$model" > "$outdir/$i.model"
        # Per-row perspective + fallback_model so the result loop can replay them
        # into process_member (HIMMEL-729 quota-exhaustion fallback).
        printf '%s' "$perspective"    > "$outdir/$i.persp"
        printf '%s' "$fallback_model" > "$outdir/$i.fb"
        (
            if [ -n "$perspective" ]; then
                if [ -n "$_TIMEOUT_BIN" ]; then
                    "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                else
                    bash "$CFP" --model "$model" --slug "$slug" --perspective-file "$SCRIPT_DIR/$perspective" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                fi
            else
                if [ -n "$_TIMEOUT_BIN" ]; then
                    "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                    echo $? > "$outdir/$i.rc"
                else
                    bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
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
        # Note: if .rc is absent (subshell received a signal during the .out write,
        # e.g. outer timeout SIGKILLs mid-run before the echo $? line runs),
        # rc_val stays at its initialized 1 → process_member treats the member as
        # unavailable (safe). The benign case (rc=0, .out empty) is also handled:
        # process_member sees zero findings and counts the member as responded.
        process_member "$slug" "$outdir/$i.out" "$rc_val" "$outdir/$i.err" "$fb_val" "$persp_val"
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
