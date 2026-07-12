#!/usr/bin/env bash
# /handover-link backend.
#
# Reports the currently resolved handover root + mode. The point is to
# give the operator a single command that answers "where is Claude
# reading and writing handover state right now?", before either of us
# trusts the answer.
#
# Verbs:
#   status (default) — print the resolved root, mode (A inline / B
#                      external), and whether the dir is git-tracked.
#   doctor           — same as status but exits non-zero on any
#                      misconfiguration (HANDOVER_DIR set but missing,
#                      mode B but $HANDOVER_DIR is inside repo, etc.).
#
# Future verbs (not in scope for this PR — separate ticket):
#   migrate <dest>   — move handovers/<owner>/ to <dest> + persist
#                      HANDOVER_DIR.
#   init <path>      — bootstrap a fresh external state repo.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/handover-path.sh"

usage() {
    cat <<'EOF'
Usage: handover-link.sh [status|doctor|--help]

  status   (default) Print the currently resolved handover root and mode.
  doctor   Same as status but exits non-zero on misconfiguration.
  --help   Show this message.

Resolution:
  Mode B (external) — HANDOVER_DIR set to an existing directory.
  Mode A (inline)   — HANDOVER_DIR unset; content lives in <repo>/handovers.

Set HANDOVER_DIR in the shell that launches Claude Code (session-sticky;
per-call prefix does not work because the resolver runs in subprocesses
that inherit env).
EOF
}

verb="${1:-status}"

case "$verb" in
    -h|--help)
        usage
        exit 0
        ;;
    status|doctor) ;;
    *)
        echo "handover-link: unknown verb '$verb'" >&2
        usage >&2
        exit 64
        ;;
esac

mode=$(handover_mode)
root=""
resolve_rc=0
root=$(handover_root) || resolve_rc=$?

cat <<EOF
mode:       $mode  ($([ "$mode" = "A" ] && echo "inline default" || echo "external via HANDOVER_DIR"))
root:       ${root:-<unresolved>}
HANDOVER_DIR=${HANDOVER_DIR:-<unset>}
EOF

# Diagnostic checks. status reports only; doctor exits 1 on the first
# issue so CI/pre-push can gate on it.
issues=0
issue() {
    echo "  - $1"
    issues=$((issues + 1))
}

if [ "$resolve_rc" -ne 0 ]; then
    echo
    echo "issues:"
    issue "resolver failed (rc=$resolve_rc) — see stderr above"
elif [ "$mode" = "B" ]; then
    # Mode B sanity: external root should NOT live inside the current
    # repo (that defeats the point of externalising). Use prefix match
    # on resolved paths; both came through `cd && pwd` so are
    # canonical-ish.
    if repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
        repo_real=$(cd "$repo_root" && pwd)
        case "$root" in
            "$repo_real"|"$repo_real"/*)
                echo
                echo "issues:"
                issue "HANDOVER_DIR resolves inside the current repo ($repo_real) — that defeats externalisation"
                ;;
        esac
    fi
fi

if [ "$verb" = "doctor" ] && [ "$issues" -gt 0 ]; then
    exit 1
fi
exit 0
