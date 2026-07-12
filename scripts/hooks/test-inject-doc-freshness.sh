#!/usr/bin/env bash
# Smoke test for scripts/hooks/inject-doc-freshness.sh. Exit 0 if all pass.
set -uo pipefail
HOOK="$(cd "$(dirname "$0")" && pwd)/inject-doc-freshness.sh"
_fail=0
chk() { local name="$1" cond="$2"; if eval "$cond"; then printf '  PASS  %s\n' "$name"; else printf '  FAIL  %s\n' "$name"; _fail=$((_fail+1)); fi; }

# Leg OFF (use "off", NOT "" — load_dotenv overwrites an empty var, critic #3) →
# no output, exit 0.
out=$(HIMMEL_DOC_FRESHNESS=off HIMMEL_REPO="$(git rev-parse --show-toplevel)" bash "$HOOK" </dev/null 2>/dev/null); rc=$?
chk "leg off → exit 0" "[ $rc -eq 0 ]"
chk "leg off → no output" "[ -z \"\$out\" ]"

# Leg ON but invoked on main/detached or with no drift → still exit 0 (fail-open).
# shellcheck disable=SC2034  # out unused in this case (only rc is checked)
out=$(HIMMEL_DOC_FRESHNESS=session HIMMEL_REPO="$(git rev-parse --show-toplevel)" bash "$HOOK" </dev/null 2>/dev/null); rc=$?
chk "leg on → exit 0 (fail-open)" "[ $rc -eq 0 ]"

# Emission-path test: feat commit on a mapped source (without touching the doc)
# triggers a <system-reminder> block when the session leg is on.
# Fixture: temp repo with 4-col map + mapped doc; origin/main at the seed commit;
# feature branch with a single feat: commit touching a mapped source.
_em_tmp=$(mktemp -d)
git -C "$_em_tmp" init -q -b main >/dev/null 2>&1 || git -C "$_em_tmp" init -q >/dev/null 2>&1
git -C "$_em_tmp" config user.email t@t; git -C "$_em_tmp" config user.name t
mkdir -p "$_em_tmp/scripts/hooks" "$_em_tmp/docs/internals"
# 4-col map with one advise row
printf 'advise\tmodify\t^scripts/hooks/\tdocs/internals/enforcement.md\n' \
    > "$_em_tmp/scripts/hooks/doc-guard-map.tsv"
# Target doc must exist so the row is "live" (not path-keyed-inert)
printf 'placeholder\n' > "$_em_tmp/docs/internals/enforcement.md"
git -C "$_em_tmp" add -A; git -C "$_em_tmp" commit -q -m "chore: seed"
# Wire origin/main to the seed commit so origin/main...HEAD diff range resolves
git -C "$_em_tmp" update-ref refs/remotes/origin/main HEAD
# Feature branch with a feat: commit touching the mapped source, NOT the doc
git -C "$_em_tmp" checkout -q -b feat/emission-test
printf 'x\n' >> "$_em_tmp/scripts/hooks/new-hook.sh"
git -C "$_em_tmp" add "$_em_tmp/scripts/hooks/new-hook.sh"
git -C "$_em_tmp" commit -q -m "feat: add hook"
# shellcheck disable=SC2034  # em_out used via eval in chk calls below
em_out=$(HIMMEL_DOC_FRESHNESS=session HIMMEL_REPO="$_em_tmp" bash "$HOOK" </dev/null 2>/dev/null)
em_rc=$?
chk "emission: feat commit on mapped source → exit 0" "[ $em_rc -eq 0 ]"
# shellcheck disable=SC2016  # single-quotes intentional: eval expands $em_out at check time
chk "emission: stdout contains <system-reminder>" 'printf "%s" "$em_out" | grep -q "<system-reminder>"'
# shellcheck disable=SC2016
chk "emission: stdout contains enforcement.md" 'printf "%s" "$em_out" | grep -q "enforcement.md"'
rm -rf "$_em_tmp"

if [ "$_fail" -eq 0 ]; then echo "OK"; exit 0; else echo "FAIL: $_fail"; exit 1; fi
