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
ANCHOR_MODEL="qwen/qwen3.6-35b-a3b"

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

# Read diff from stdin and store it
diff_in="$(cat)"

# Parse registry: emit "slug<TAB>model" lines for matching tiers.
# Falls back to anchor on missing/invalid/empty registry.
rows="$(REG="$REG" TIER_FILTER="$TIER_FILTER" node -e '
  const fs = require("fs");
  const reg  = process.env.REG;
  const tiers = (process.env.TIER_FILTER || "free").split(",").map(t => t.trim());
  try {
    const j = JSON.parse(fs.readFileSync(reg, "utf8"));
    const p = (j.panel || []).filter(r => r.slug && r.model && tiers.includes(r.tier));
    if (!p.length) throw new Error("no rows");
    process.stdout.write(p.map(r => r.slug + "\t" + r.model).join("\n"));
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
outdir=""
trap 'rm -f "$tmp"; [ -n "$_seq_out" ] && rm -f "$_seq_out"; [ -n "$outdir" ] && rm -rf "$outdir"' EXIT
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
# process_member: shared per-member logic called from both sequential and
# parallel result loops. Runs in the MAIN shell so it can update global_id,
# responded, agg_crit, agg_imp, agg_sug directly.
#
# $1 = slug
# $2 = path to member stdout file
# $3 = rc value (integer string)
# $4 = path to member stderr file (optional; pass "" to skip)
# ---------------------------------------------------------------------------
process_member() {
    _pm_slug="$1"
    _pm_out_file="$2"
    _pm_rc="$3"
    _pm_err_file="${4:-}"

    if [ "$_pm_rc" -eq 124 ] || [ "$_pm_rc" -eq 137 ]; then
        echo "panel-availability: $_pm_slug unavailable (timeout ${CRITIC_TIMEOUT_SECS}s)" >&2
        return
    fi
    if [ "$_pm_rc" -ne 0 ]; then
        echo "panel-availability: $_pm_slug unavailable (rc=$_pm_rc)" >&2
        return
    fi
    echo "panel-availability: $_pm_slug ok" >&2
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
    # Use a temp file per member so process_member can read from a path
    _seq_out="$(mktemp -t critic-panel-seq.XXXXXX)"

    while IFS="	" read -r slug model; do
        [ -n "$slug" ] || continue
        total=$((total + 1))

        # Run this member (with per-member timeout if available)
        if [ -n "$_TIMEOUT_BIN" ]; then
            "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$_seq_out" 2>/dev/null
            rc=$?
        else
            bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$_seq_out" 2>/dev/null
            rc=$?
        fi

        process_member "$slug" "$_seq_out" "$rc" ""

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
    while IFS="	" read -r slug model; do
        [ -n "$slug" ] || continue
        total=$((total + 1))
        # Write slug and model so the result loop can recover them
        printf '%s' "$slug"  > "$outdir/$i.slug"
        printf '%s' "$model" > "$outdir/$i.model"
        (
            if [ -n "$_TIMEOUT_BIN" ]; then
                "$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                echo $? > "$outdir/$i.rc"
            else
                bash "$CFP" --model "$model" --slug "$slug" < "$tmp" > "$outdir/$i.out" 2>"$outdir/$i.err"
                echo $? > "$outdir/$i.rc"
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
        # Note: if .rc is absent (subshell received a signal during the .out write,
        # e.g. outer timeout SIGKILLs mid-run before the echo $? line runs),
        # rc_val stays at its initialized 1 → process_member treats the member as
        # unavailable (safe). The benign case (rc=0, .out empty) is also handled:
        # process_member sees zero findings and counts the member as responded.
        process_member "$slug" "$outdir/$i.out" "$rc_val" "$outdir/$i.err"
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
