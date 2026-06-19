#!/usr/bin/env bash
# scripts/cr/critic-panel.sh — run the free-cloud critic panel over a diff (HIMMEL-415).
# Reads a unified diff on stdin, runs each tier=free registry critic via
# critic-first-pass.sh, merges findings (global renumber, per-model slug IDs).
# Stdout = merged findings block. Stderr = panel-availability lines.
# Exit 0 = >=1 responded; 1 = all failed (caller -> claude-only). Bash 3.2-safe.
# Env: CRITIC_PANEL_TIERS — comma-separated tier names to include (default: free).
#      In /pr-check, this is set to $CR_PROFILE (the opt-in profile; claude-only when unset).
#      CRITIC_TIMEOUT_SECS — per-member wall-clock timeout in seconds (default 150;
#          comfortably above fast critics' ~90s observed latency but bounds a true hang).
#          Requires GNU coreutils 'timeout'; gracefully degrades without it.
set -uo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFP="${CRITIC_FIRST_PASS:-$SCRIPT_DIR/critic-first-pass.sh}"
REG="${CRITICS_JSON:-$SCRIPT_DIR/critics.json}"
TIER_FILTER="${CRITIC_PANEL_TIERS:-free}"

ANCHOR_SLUG="gptoss"
ANCHOR_MODEL="openai/gpt-oss-120b"

# Per-member timeout: validate CRITIC_TIMEOUT_SECS (Bash 3.2 safe via expr).
CRITIC_TIMEOUT_SECS="${CRITIC_TIMEOUT_SECS:-150}"
if expr "$CRITIC_TIMEOUT_SECS" : '^[0-9][0-9]*$' > /dev/null 2>&1 && [ "$CRITIC_TIMEOUT_SECS" -gt 0 ]; then
    : # valid
else
    echo "critic-panel.sh: CRITIC_TIMEOUT_SECS=$CRITIC_TIMEOUT_SECS invalid, using 150" >&2
    CRITIC_TIMEOUT_SECS="150"
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
trap 'rm -f "$tmp"' EXIT
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

# Process each "slug<TAB>model" line
# We use printf/read loop which is Bash 3.2 safe
while IFS="	" read -r slug model; do
    [ -n "$slug" ] || continue
    total=$((total + 1))

    # Run this member (with per-member timeout if available)
    if [ -n "$_TIMEOUT_BIN" ]; then
        member_out="$("$_TIMEOUT_BIN" -k 5 "$CRITIC_TIMEOUT_SECS" bash "$CFP" --model "$model" --slug "$slug" < "$tmp" 2>/dev/null)"
        rc=$?
    else
        member_out="$(bash "$CFP" --model "$model" --slug "$slug" < "$tmp" 2>/dev/null)"
        rc=$?
    fi
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "panel-availability: $slug unavailable (timeout ${CRITIC_TIMEOUT_SECS}s)" >&2
        continue
    fi
    if [ "$rc" -ne 0 ]; then
        echo "panel-availability: $slug unavailable (rc=$rc)" >&2
        continue
    fi
    echo "panel-availability: $slug ok" >&2
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
    member_parsed="$(printf '%s\n' "$member_out" | awk -v base="$global_id" -v slug="$slug" '
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

done << ROWSEOF
$rows
ROWSEOF

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
