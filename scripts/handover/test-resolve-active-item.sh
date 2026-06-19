#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$HERE/resolve-active-item.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# Fixture handover tree (Mode B) + fake registry.
root="$tmp/handovers"
mkdir -p "$root/yotamleo/himmel/standalones/HIMMEL-389-vault-upgrade"
mkdir -p "$root/yotamleo/himmel/epics/HIMMEL-414-cr-epic"
mkdir -p "$root/yotamleo/himmel/epics/HIMMEL-414-cr-epic/tasks/HIMMEL-416-f2-ledger"
reg="$tmp/registry.json"
cat > "$reg" <<'JSON'
{ "repos": { "himmel": {
  "path": "c:/work/himmel", "user": "yotamleo", "jira_project": "HIMMEL"
} } }
JSON
# repo-root passed in upper/mixed case to prove case-insensitive registry match.
RR="C:/Work/Himmel"

run(){ HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --repo-root "$RR" --branch "$1"; }

check "standalone match" "$(run feat/himmel-389-vault-upgrade)" "$root/yotamleo/himmel/standalones/HIMMEL-389-vault-upgrade"
check "epic match"       "$(run fix/himmel-414-cr-epic)"        "$root/yotamleo/himmel/epics/HIMMEL-414-cr-epic"
check "task match"       "$(run feat/himmel-416-f2-ledger)"     "$root/yotamleo/himmel/epics/HIMMEL-414-cr-epic/tasks/HIMMEL-416-f2-ledger"

# Graceful skips (rc 3, empty stdout).
out="$(run chore/cleanup-no-ticket)"; rc=$?
check "no ticket -> empty stdout" "$out" ""
check "no ticket -> rc 3" "$rc" "3"
out="$(run feat/himmel-999-absent)"; rc=$?
check "no matching item -> rc 3" "$rc" "3"

# Unregistered repo-root -> graceful skip rc 3.
out="$(HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --repo-root "C:/Work/Other" --branch feat/himmel-389-x)"; rc=$?
check "unregistered repo -> rc 3" "$rc" "3"

# Corrupt registry JSON -> hard error rc 2 (NOT misclassified as "repo not registered" rc 3).
badreg="$tmp/bad.json"; printf '{ this is not json' > "$badreg"
out="$(HANDOVER_DIR="$root" HANDOVER_REGISTRY="$badreg" bash "$R" --repo-root "$RR" --branch feat/himmel-389-x 2>/dev/null)"; rc=$?
check "corrupt registry -> rc 2" "$rc" "2"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
