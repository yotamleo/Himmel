#!/usr/bin/env bash
# prose-audit.sh — report mechanical prose in himmel command/skill files
# (HIMMEL-1939). Read-only and deterministic: findings are advisory, so a
# successful scan always exits 0. Non-zero means this reporter itself failed.
# "~tokens" is bytes / 4, rounded; it is an approximation, not a tokenizer.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Tuned guesses, not policy. Override them to test or recalibrate the heuristic.
MIN_BYTES="${PROSE_AUDIT_MIN_BYTES:-6144}"
FENCE_RATIO="${PROSE_AUDIT_FENCE_RATIO:-15}"
MAX_SNIPPETS="${PROSE_AUDIT_MAX_SNIPPETS:-3}"
TABLE_LIMIT=15

FLAGGED_ONLY=0
JSON=0

usage() {
  echo "usage: bash scripts/measurements/prose-audit.sh [--flagged-only] [--json]" >&2
}

die() {
  echo "prose-audit: $*" >&2
  exit 2
}

for arg in "$@"; do
  case "$arg" in
    --flagged-only) FLAGGED_ONLY=1 ;;
    --json) JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown flag: $arg" ;;
  esac
done

[[ "$MIN_BYTES" =~ ^[0-9]+$ ]] || die "PROSE_AUDIT_MIN_BYTES must be a non-negative integer"
[[ "$MAX_SNIPPETS" =~ ^[0-9]+$ ]] || die "PROSE_AUDIT_MAX_SNIPPETS must be a non-negative integer"
[[ "$FENCE_RATIO" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] || die "PROSE_AUDIT_FENCE_RATIO must be a number from 0 to 100"
awk -v ratio="$FENCE_RATIO" 'BEGIN { exit !(ratio >= 0 && ratio <= 100) }' \
  || die "PROSE_AUDIT_FENCE_RATIO must be a number from 0 to 100"

for tree in "$ROOT/.claude/commands" "$ROOT/marketplace/plugins" "$ROOT/.agents/skills"; do
  if [ ! -d "$tree" ] || [ ! -r "$tree" ]; then
    die "unreadable scan tree: ${tree#"$ROOT"/}"
  fi
done
# plugins/ (first-party top-level plugins) is optional: unlike the trees above
# it need not exist in every adopter clone. Absent is fine; present-but-bad is not.
if [ -d "$ROOT/plugins" ] && [ ! -r "$ROOT/plugins" ]; then
  die "unreadable scan tree: plugins"
fi

# Each discovery step's exit status is captured and checked (command
# substitution, not a pipe, so $? reflects `find` itself) — a partial file
# list from a failing `find` must not be mistaken for a complete scan.
files=()
discover() {
  local desc="$1"; shift
  local out
  if ! out="$(find "$@")"; then
    die "discovery failed under $desc — partial scan, refusing to report"
  fi
  [ -z "$out" ] && return 0
  while IFS= read -r line; do
    files+=("$line")
  done <<< "$out"
}

discover ".claude/commands" "$ROOT/.claude/commands" -maxdepth 1 -type f -name '*.md'
discover "marketplace/plugins" "$ROOT/marketplace/plugins" -type f \( -name 'SKILL.md' -o -path '*/commands/*.md' \)
discover ".agents/skills" "$ROOT/.agents/skills" -type f -name 'SKILL.md'
if [ -d "$ROOT/plugins" ]; then
  discover "plugins" "$ROOT/plugins" -type f \( -path '*/commands/*.md' -o -path '*/skills/*/SKILL.md' \)
fi

records=()
total_files=0
total_bytes=0
flagged_count=0

for file in "${files[@]}"; do
  rel="${file#"$ROOT"/}"
  case "$rel" in
    .claude/worktrees/*|templates/*) continue ;;
  esac

  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    die "unreadable file: $rel"
  fi
  if ! bytes="$(wc -c <"$file")"; then
    die "could not count bytes: $rel"
  fi
  bytes="${bytes//[[:space:]]/}"

  # Fence delimiters are excluded; content bytes (including line endings) count.
  if ! fenced_bytes="$(LC_ALL=C awk '
    /^[[:space:]]*```/ { inside = !inside; next }
    inside { total += length($0) + 1 }
    END { print total + 0 }
  ' "$file")"; then
    die "could not measure fenced bytes: $rel"
  fi

  if ! snippets="$(LC_ALL=C awk '
    {
      rest = $0
      while (match(rest, /bash scripts\/[[:alnum:]_.\/-]+/)) {
        count++
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    END { print count + 0 }
  ' "$file")"; then
    die "could not count script snippets: $rel"
  fi

  backing="no"
  if LC_ALL=C grep -Eq '(^|[^[:alnum:]_.-])(scripts|tools)/[[:alnum:]_.\/-]+' "$file"; then
    backing="yes"
  fi

  if ! ratio="$(awk -v fenced="$fenced_bytes" -v bytes="$bytes" \
    'BEGIN { printf "%.1f", bytes ? (100 * fenced / bytes) : 0 }')"; then
    die "could not compute fence ratio: $rel"
  fi
  [ -n "$ratio" ] || die "empty fence ratio: $rel"
  approx_tokens=$(( (bytes + 2) / 4 ))

  flagged=0
  if [ "$bytes" -gt "$MIN_BYTES" ]; then
    awk -v fenced="$fenced_bytes" -v bytes="$bytes" -v limit="$FENCE_RATIO" \
      'BEGIN { exit !((100 * fenced / bytes) > limit) }'
    ratio_status=$?
    if [ "$ratio_status" -eq 0 ]; then
      flagged=1
    elif [ "$ratio_status" -eq 1 ]; then
      [ "$snippets" -gt "$MAX_SNIPPETS" ] && flagged=1
    else
      die "fence-ratio threshold check failed (awk exit $ratio_status): $rel"
    fi
  fi

  records+=("$flagged"$'\t'"$bytes"$'\t'"$approx_tokens"$'\t'"$fenced_bytes"$'\t'"$ratio"$'\t'"$snippets"$'\t'"$backing"$'\t'"$rel")
  total_files=$((total_files + 1))
  total_bytes=$((total_bytes + bytes))
  flagged_count=$((flagged_count + flagged))
done

total_tokens=$(( (total_bytes + 2) / 4 ))
sorted=()
if [ "${#records[@]}" -gt 0 ]; then
  # As with discovery above: capture via command substitution (pipefail is
  # set, so this reflects `sort`'s own exit status, not just the pipe's last
  # stage) and cross-check the row count — a failed or truncated sort must
  # not silently pass through as a shorter-but-clean report.
  if ! sorted_out="$(printf '%s\n' "${records[@]}" | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr -k8,8)"; then
    die "sort failed — partial ranking, refusing to report"
  fi
  while IFS= read -r sorted_line; do
    sorted+=("$sorted_line")
  done <<< "$sorted_out"
  if [ "${#sorted[@]}" -ne "${#records[@]}" ]; then
    die "sort produced ${#sorted[@]} row(s), expected ${#records[@]} — partial ranking, refusing to report"
  fi
fi

emit_json_records() {
  local record flagged
  for record in "${sorted[@]}"; do
    flagged="${record%%$'\t'*}"
    if [ "$FLAGGED_ONLY" -eq 1 ] && [ "$flagged" -ne 1 ]; then
      continue
    fi
    printf '%s\n' "$record"
  done
}

if [ "$JSON" -eq 1 ]; then
  command -v node >/dev/null 2>&1 || die "node is required for --json"
  if ! emit_json_records | node -e '
const fs = require("fs");
const args = process.argv.slice(1);
const [minBytes, fenceRatio, maxSnippets, totalFiles, totalBytes, totalTokens, flaggedCount] = args;
const input = fs.readFileSync(0, "utf8").trim();
const rows = input ? input.split("\n").map((line) => {
  const [flagged, bytes, approxTokens, fencedBytes, fenceRatioPct, snippets, backingScript, file] = line.split("\t");
  return {
    file,
    bytes: Number(bytes),
    approx_tokens: Number(approxTokens),
    fenced_bytes: Number(fencedBytes),
    fence_ratio_pct: Number(fenceRatioPct),
    script_snippets: Number(snippets),
    backing_script: backingScript === "yes",
    flagged: flagged === "1"
  };
}) : [];
process.stdout.write(JSON.stringify({
  approximation: "tokens = bytes / 4 (rounded)",
  thresholds: {
    min_bytes: Number(minBytes),
    fence_ratio_pct: Number(fenceRatio),
    max_script_snippets: Number(maxSnippets)
  },
  rows,
  summary: {
    files: Number(totalFiles),
    bytes: Number(totalBytes),
    approx_tokens: Number(totalTokens),
    flagged: Number(flaggedCount)
  }
}) + "\n");
' "$MIN_BYTES" "$FENCE_RATIO" "$MAX_SNIPPETS" "$total_files" "$total_bytes" "$total_tokens" "$flagged_count"; then
    die "could not emit JSON"
  fi
  exit 0
fi

short_path() {
  local path="$1"
  if [ "${#path}" -le 58 ]; then
    printf '%s' "$path"
  else
    printf '%s…%s' "${path:0:28}" "${path: -29}"
  fi
}

echo "prose-audit: report-only; findings exit 0. ~tok = bytes/4 (rounded); fence = bytes inside \`\`\` blocks."
printf '%-1s %8s %7s %8s %6s %4s %6s  %s\n' "" "bytes" "~tok" "fence" "fence%" "bash" "script" "file"
printf '%-1s %8s %7s %8s %6s %4s %6s  %s\n' "-" "--------" "-------" "--------" "------" "----" "------" "----"

shown=0
eligible="$total_files"
[ "$FLAGGED_ONLY" -eq 1 ] && eligible="$flagged_count"
for record in "${sorted[@]}"; do
  IFS=$'\t' read -r flagged bytes approx_tokens fenced_bytes ratio snippets backing rel <<< "$record"
  if [ "$FLAGGED_ONLY" -eq 1 ] && [ "$flagged" -ne 1 ]; then
    continue
  fi
  if [ "$FLAGGED_ONLY" -eq 0 ] && [ "$shown" -ge "$TABLE_LIMIT" ] && [ "$flagged" -ne 1 ]; then
    continue
  fi
  marker="-"
  [ "$flagged" -eq 1 ] && marker="!"
  display_path="$(short_path "$rel")"
  printf '%-1s %8d %7d %8d %6s %4d %6s  %s\n' \
    "$marker" "$bytes" "$approx_tokens" "$fenced_bytes" "$ratio" "$snippets" "$backing" "$display_path"
  shown=$((shown + 1))
done

omitted=$((eligible - shown))
if [ "$omitted" -gt 0 ]; then
  echo "... $omitted more row(s); use --json for complete data."
fi
echo "summary: files=$total_files bytes=$total_bytes ~tokens=$total_tokens flagged=$flagged_count"
exit 0
