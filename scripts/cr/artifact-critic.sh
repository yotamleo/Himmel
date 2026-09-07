#!/usr/bin/env bash
# scripts/cr/artifact-critic.sh — thin artifact-mode wrapper for critic-first-pass.sh (HIMMEL-414).
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFP="${CRITIC_FIRST_PASS:-$SCRIPT_DIR/critic-first-pass.sh}"

usage() {
    cat >&2 <<'EOF'
Usage: artifact-critic.sh --artifact <file> --charter <file> --model <m> [--slug <s>]

Runs critic-first-pass.sh in artifact mode, reading the artifact from stdin and
using the charter file as the reviewer role. Exit codes pass through from the
underlying first-pass critic (incl. 4 = all findings dropped, HIMMEL-1915); 2 = usage error.

PROSE ARTIFACTS ONLY (specs, plans, design docs). To review a unified DIFF, use
critic-first-pass.sh in diff mode instead:

  bash scripts/cr/critic-first-pass.sh --model <m> --slug <s> < the.diff

Artifact mode validates every citation against ATX markdown headings extracted
from the artifact, and critic-first-pass.sh itself enforces that contract
(HIMMEL-1915): an artifact with zero extractable headings (any diff, headingless
prose) is refused before the model call, and a run whose findings are all
dropped by citation validation exits nonzero instead of reporting "0 found".
EOF
}

artifact=""
charter=""
model=""
slug=""

while [ $# -gt 0 ]; do
    case "$1" in
        --artifact) [ $# -ge 2 ] || { echo "artifact-critic.sh: --artifact requires a value" >&2; exit 2; }; artifact="$2"; shift 2 ;;
        --charter)  [ $# -ge 2 ] || { echo "artifact-critic.sh: --charter requires a value" >&2; exit 2; }; charter="$2"; shift 2 ;;
        --model)    [ $# -ge 2 ] || { echo "artifact-critic.sh: --model requires a value" >&2; exit 2; }; model="$2"; shift 2 ;;
        --slug)     [ $# -ge 2 ] || { echo "artifact-critic.sh: --slug requires a value" >&2; exit 2; }; slug="$2"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "artifact-critic.sh: unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$artifact" ] || { echo "artifact-critic.sh: --artifact is required" >&2; usage; exit 2; }
[ -n "$charter" ] || { echo "artifact-critic.sh: --charter is required" >&2; usage; exit 2; }
[ -n "$model" ] || { echo "artifact-critic.sh: --model is required" >&2; usage; exit 2; }
[ -f "$artifact" ] || { echo "artifact-critic.sh: artifact file not found: $artifact" >&2; exit 2; }
[ -f "$charter" ] || { echo "artifact-critic.sh: charter file not found: $charter" >&2; exit 2; }

# Load the Z.ai critic credential from the primary checkout's .env so the glm
# artifact-critic lane (provider zai / route_provider glm, HIMMEL-1096)
# authenticates with NO manual env export — mirroring critic-panel.sh's
# HIMMEL-1221 load. minerva's Stage-2/4 advisory panel calls this script per
# registry row; without this load the glm row sees "No usable credentials found
# for provider 'zai'" on .env-keyed machines (HIMMEL-1646). Gated on the
# model/slug being a zai/glm lane (the artifact-path analog of the panel's
# registry grep) so the load_dotenv subshell cost stays off the claude/codex
# artifact rows. load_dotenv sets a key ONLY when currently UNSET (a live env
# value wins) and exports it, so the exec'd critic-first-pass.sh -> invoke.sh
# inherits it. Loaded here (not in critic-first-pass.sh) so the panel path is
# NOT touched: the panel calls critic-first-pass.sh directly and already loads
# its own creds, so each entry point loads exactly once (no double-loading).
_lane_lc="$(printf '%s %s' "$model" "$slug" | tr '[:upper:]' '[:lower:]')"
case "$_lane_lc" in
    *glm*|*zai*)
        # shellcheck source=../lib/load-dotenv.sh
        # shellcheck disable=SC1091
        . "$SCRIPT_DIR/../lib/load-dotenv.sh" 2>/dev/null || true
        if command -v load_dotenv >/dev/null 2>&1; then
            # HIMMEL-1648: pin to SCRIPT-ROOT resolution so an artifact run from
            # an unrelated git repo still reads himmel's .env, not THAT repo's.
            load_dotenv --root "$(_load_dotenv_primary_for "$SCRIPT_DIR/../..")" GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY 2>/dev/null || true
        fi
        ;;
esac

if [ -n "$slug" ]; then
    exec bash "$CFP" --artifact-mode --charter-file "$charter" --model "$model" --slug "$slug" < "$artifact"
else
    exec bash "$CFP" --artifact-mode --charter-file "$charter" --model "$model" < "$artifact"
fi
