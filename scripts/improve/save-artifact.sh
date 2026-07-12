#!/usr/bin/env bash
# save-artifact.sh — write a refined-prompt audit artifact for /improve.
#
# Called by the /improve slash command (HIMMEL-127) after the operator
# answers the clarifying questions and Claude synthesizes a refined
# prompt. Writes a timestamped markdown file under <handover-root>/.improve/
# so the refinement is auditable without spending tokens to keep it in
# chat context.
#
# Usage:
#   save-artifact.sh --original <text> --refined <text> [--notes <text>]
#                    [--rationale <text>] [--dry-run]
#
# Resolution of the .improve/ root:
#   1. If HANDOVER_DIR is set + exists → <HANDOVER_DIR>/.improve/
#      (Mode B, post-HIMMEL-124 default for the operator.)
#   2. Else → <repo-root>/.improve/ (Mode A, inline).
#   Failure modes: HANDOVER_DIR set but missing → rc=2.
#
# Exit codes:
#   0 — wrote artifact (or dry-run printed plan)
#   1 — usage / input error
#   2 — env unusable (HANDOVER_DIR pointing at missing dir; not in a git repo)
#   3 — write failed

set -euo pipefail

usage() {
    cat <<EOF >&2
save-artifact.sh — write a refined-prompt audit artifact for /improve.

Usage:
  $0 --original <text> --refined <text> [--notes <text>] [--rationale <text>] [--dry-run]

Required:
  --original <text>    The original draft prompt (verbatim).
  --refined <text>     The synthesized refined prompt.

Optional:
  --notes <text>       Summary of clarifying-Q answers (multi-line OK).
  --rationale <text>   1-2 sentences on what the refinement changed + why.
  --dry-run            Print the artifact path + body to stdout; do not write.

Resolution of the .improve/ root:
  1. If \$HANDOVER_DIR is set + exists → <HANDOVER_DIR>/.improve/ (Mode B).
  2. Else → <repo-root>/.improve/ (Mode A).
EOF
}

original=""
refined=""
notes=""
rationale=""
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        --original)
            [ $# -ge 2 ] || { echo "save-artifact: --original requires a value" >&2; exit 1; }
            original="$2"
            shift 2
            ;;
        --refined)
            [ $# -ge 2 ] || { echo "save-artifact: --refined requires a value" >&2; exit 1; }
            refined="$2"
            shift 2
            ;;
        --notes)
            [ $# -ge 2 ] || { echo "save-artifact: --notes requires a value" >&2; exit 1; }
            notes="$2"
            shift 2
            ;;
        --rationale)
            [ $# -ge 2 ] || { echo "save-artifact: --rationale requires a value" >&2; exit 1; }
            rationale="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "save-artifact: unknown arg: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [ -z "$original" ] || [ -z "$refined" ]; then
    echo "save-artifact: --original and --refined are required" >&2
    usage
    exit 1
fi

# Resolve the .improve/ root via the handover-path helper for consistency
# with /handover-link semantics. We don't source handover-path.sh because
# /improve doesn't strictly need the inline mkdir; reimplement the small
# resolution here to keep dependencies tight.
mode="A"
if [ -n "${HANDOVER_DIR:-}" ]; then
    if [ ! -d "$HANDOVER_DIR" ]; then
        echo "save-artifact: HANDOVER_DIR='$HANDOVER_DIR' is not a directory" >&2
        exit 2
    fi
    root="$HANDOVER_DIR"
    mode="B"
else
    if ! root=$(git rev-parse --show-toplevel 2>/dev/null); then
        echo "save-artifact: not inside a git repository and HANDOVER_DIR is unset" >&2
        exit 2
    fi
fi

improve_dir="$root/.improve"
ts=$(date -u +%Y%m%dT%H%M%SZ)
iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Derive a short slug from the original prompt: first 40 chars, lowercased,
# non-alnum → "-". Fall back to "draft" when the prompt is empty/whitespace.
slug=$(printf '%s' "$original" \
    | head -c 80 \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | sed 's/-\+/-/g; s/^-//; s/-$//' \
    | head -c 40)
[ -n "$slug" ] || slug="draft"

# Second-resolution timestamp + PID disambiguator. Two concurrent
# invocations in the same wall-clock second land on distinct files.
artifact="$improve_dir/${ts}-${slug}-${$}.md"

original_chars=${#original}
refined_chars=${#refined}

render_body() {
    cat <<EOF
---
name: improve-${ts}-${slug}
created: ${iso}
original_chars: ${original_chars}
refined_chars: ${refined_chars}
mode: ${mode}
---

# Original draft

$(printf '%s' "$original" | sed 's/^/> /')

# Clarifying-Q answers

EOF
    if [ -n "$notes" ]; then
        printf '%s\n' "$notes"
    else
        printf '%s\n' "(none captured)"
    fi
    cat <<EOF

# Refined prompt

${refined}

# Rationale

EOF
    if [ -n "$rationale" ]; then
        printf '%s\n' "$rationale"
    else
        printf '%s\n' "(none captured)"
    fi
}

if [ "$dry_run" -eq 1 ]; then
    echo "save-artifact: would write to $artifact"
    echo "---"
    render_body
    exit 0
fi

if ! mkdir -p "$improve_dir"; then
    echo "save-artifact: mkdir failed: $improve_dir" >&2
    exit 3
fi

if ! render_body > "$artifact"; then
    echo "save-artifact: write failed: $artifact" >&2
    exit 3
fi

echo "$artifact"
