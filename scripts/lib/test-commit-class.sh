#!/usr/bin/env bash
# Unit test for scripts/lib/commit-class.sh. Exit 0 if all pass.
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")" && pwd)/commit-class.sh"
_fail=0
chk() { local subj="$1" want="$2" got; got="$(cc_classify "$subj")"; if [ "$got" = "$want" ]; then printf '  PASS  %s\n' "$subj"; else printf '  FAIL  %s want=%s got=%s\n' "$subj" "$want" "$got"; _fail=$((_fail+1)); fi; }
chk "feat: add x"         feat
chk "feat(scope): add x"  feat
chk "fix: bug"            fix
chk "fix(api): bug"       fix
chk "chore: deps"         changed
chk "refactor(x): tidy"   changed
chk "docs: readme"        changed
chk "test: cover"         changed
chk "Merge branch main"   other
chk "random subject"      other
if [ "$_fail" -eq 0 ]; then echo "OK"; exit 0; else echo "FAIL: $_fail"; exit 1; fi
