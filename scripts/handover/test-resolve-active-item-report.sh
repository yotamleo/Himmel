#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$HERE/resolve-active-item-report.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-resolve-active-item-report.XXXXXX")" || exit 1
tmp="$(cd "$tmp" && pwd -P)"  # macOS: /var/folders -> /private/var (git reports the real path)
trap 'rm -rf "$tmp"' EXIT
fails=0; check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# tmp itself is the fixture repo root: resolve-active-item.sh derives
# repo_root from git when --repo-root is not passed, and this wrapper never
# forwards --repo-root (it only ever takes --branch, matching pr-check.md's
# own call shape), so the wrapper's invocation must run with cwd inside a
# registered git repo.
git -C "$tmp" init -q
git -C "$tmp" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x

root="$tmp/handovers"
mkdir -p "$root/yotamleo/himmel/standalones/HIMMEL-389-vault-upgrade"
reg="$tmp/registry.json"
cat > "$reg" <<JSON
{ "repos": { "himmel": {
  "path": "$tmp", "user": "yotamleo", "jira_project": "HIMMEL"
} } }
JSON

run(){ ( cd "$tmp" && HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --branch "$1" ); }

out="$(run feat/himmel-389-vault-upgrade)"; rc=$?
check "rc 0 -> item dir on stdout" "$out" "$root/yotamleo/himmel/standalones/HIMMEL-389-vault-upgrade"
check "rc 0 -> wrapper still exits 0" "$rc" "0"

out="$(run chore/cleanup-no-ticket)"; rc=$?
check "rc 3 -> skip line on stdout" "$out" "4.6/4.7: no active handover item for chore/cleanup-no-ticket — handover bridges SKIPPED (not a failure)"
check "rc 3 -> wrapper still exits 0" "$rc" "0"

badreg="$tmp/bad.json"; printf '{ this is not json' > "$badreg"
out="$( ( cd "$tmp" && HANDOVER_DIR="$root" HANDOVER_REGISTRY="$badreg" bash "$R" --branch feat/himmel-389-vault-upgrade 2>"$tmp/err" ) )"; rc=$?
err="$(cat "$tmp/err" 2>/dev/null)"
check "rc 2 -> nothing on stdout" "$out" ""
check "rc 2 -> wrapper still exits 0" "$rc" "0"
case "$err" in
  *"errored (rc=2)"*) echo "ok - rc 2 -> error line on stderr names rc=2" ;;
  *) echo "FAIL - rc 2 -> stderr lacks 'errored (rc=2)': $err"; fails=$((fails+1)) ;;
esac

out="$( ( cd "$tmp" && HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --bogus-flag --branch feat/himmel-389-vault-upgrade 2>"$tmp/err2" ) )"; rc=$?
check "unknown arg -> still exits 0 (best-effort)" "$rc" "0"
err2="$(cat "$tmp/err2" 2>/dev/null)"
case "$err2" in
  *"unknown arg --bogus-flag"*) echo "ok - unknown arg -> stderr names it, never exit 2" ;;
  *) echo "FAIL - unknown arg -> stderr missing the notice: $err2"; fails=$((fails+1)) ;;
esac

out="$( ( cd "$tmp" && HANDOVER_DIR="$root" HANDOVER_REGISTRY="$reg" bash "$R" --branch 2>/dev/null ) )"; rc=$?
check "trailing --branch with no value -> still exits 0 (no set -u crash)" "$rc" "0"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
