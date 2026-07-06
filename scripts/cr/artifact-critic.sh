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
underlying first-pass critic; 2 = usage error.
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

if [ -n "$slug" ]; then
    exec bash "$CFP" --artifact-mode --charter-file "$charter" --model "$model" --slug "$slug" < "$artifact"
else
    exec bash "$CFP" --artifact-mode --charter-file "$charter" --model "$model" < "$artifact"
fi
