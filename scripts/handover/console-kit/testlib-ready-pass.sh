# shellcheck shell=bash
# git-env-ok: test fixture; its only git call is `git -C` on a suite-owned temp repo
# scripts/handover/console-kit/testlib-ready-pass.sh - shared fixture for the
# suites that run go.sh for real (HIMMEL-4565). go.sh now runs ready-check.sh
# itself and refuses unless it passes, so a suite that only needs a GO written
# must make ready-check pass: a gh that answers ready-check's queries green, and
# an ok CR-ledger row for the head in the repo go.sh runs from.
# Sourced, never run. bash 3.2-safe.

# ready_pass_bin <dir> - write <dir>/gh. It answers ready-check.sh's queries
# green for head $READY_STUB_HEAD (export it before go.sh runs), and hands every
# other call to the next gh on PATH, so a suite's own gh stub keeps working.
# Prepend <dir> to PATH for the go.sh call only.
ready_pass_bin() {
    mkdir -p "$1" || return 1
    cat > "$1/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "repo view --json owner,name"*) printf '%s\n' "${READY_STUB_NWO:-o/r}"; exit 0 ;;
    *"--json headRefOid,mergeStateStatus"*) printf '%s CLEAN\n' "${READY_STUB_HEAD:-}"; exit 0 ;;
    *"--json statusCheckRollup"*) printf '%s' '[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]'; exit 0 ;;
    *"--json commits"*)
        printf '%s' '[{"messageHeadline":"fix(x): [HIMMEL-1] t (#1)","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
        exit 0 ;;
    *"--json body"*) printf '## Ticket coverage\n- ask: done\n'; exit 0 ;;
    *"commits(first:100)"*) exit 0 ;;
    *"api graphql"*) printf '0 false null\n'; exit 0 ;;
    *"api --paginate"*"/files"*) printf 'scripts/x.sh\n'; exit 0 ;;
esac
self=$(cd "$(dirname "$0")" && pwd)
IFS=:
for d in $PATH; do
    [ "$d" = "$self" ] && continue
    [ -x "$d/gh" ] && exec "$d/gh" "$@"
done
echo "ready-pass gh: no gh after $self on PATH for: $*" >&2
exit 1
STUB
    chmod +x "$1/gh"
}

# ready_pass_ledger <repo> <sha>... - append an ok CR-ledger row per sha to
# <repo>'s git-common-dir (what ready-check's check 4 reads).
ready_pass_ledger() {
    local repo="$1" gd s
    shift
    gd=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || return 1
    for s in "$@"; do
        printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","status":"ok"}\n' "$s" \
            >> "$gd/cr-critic-scores.jsonl" || return 1
    done
}
