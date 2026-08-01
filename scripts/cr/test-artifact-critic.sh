#!/usr/bin/env bash
# scripts/cr/test-artifact-critic.sh — TDD for artifact-critic.sh (HIMMEL-414 WS4).
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HERE="$(cd "$(dirname "$0")" && pwd)"; AC="$HERE/artifact-critic.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check(){ if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }
check_contains(){ if grepq "$2" -F -- "$3"; then echo "ok - $1"; else echo "FAIL - $1: missing [$3]"; fails=$((fails+1)); fi; }

ART="$tmp/spec.md"; printf '# T\n## S\nbody\n' > "$ART"
CH="$tmp/charter.md"; printf 'charter role text\n' > "$CH"

# Stub CFP: record argv + stdin-first-line so we can assert the delegation.
STUB="$tmp/cfp-stub.sh"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$tmp/argv"
head -1 > "$tmp/stdin1"
echo "# s First-Pass Review"
EOS
chmod +x "$STUB"

# (f) wrapper delegates with --artifact-mode --charter-file and pipes the artifact
out="$(CRITIC_FIRST_PASS="$STUB" bash "$AC" --artifact "$ART" --charter "$CH" --model x/y --slug s 2>/dev/null)"
argv="$(cat "$tmp/argv")"
check_contains "f: returns CFP output" "$out" "# s First-Pass Review"
check_contains "f: delegates --artifact-mode" "$argv" "--artifact-mode"
check_contains "f: delegates --charter-file" "$argv" "--charter-file $CH"
check_contains "f: passes model" "$argv" "--model x/y"
check "f: artifact piped on stdin (first line)" "$(cat "$tmp/stdin1")" "# T"

# missing artifact file -> exit 2
CRITIC_FIRST_PASS="$STUB" bash "$AC" --artifact "$tmp/nope.md" --charter "$CH" --model x/y >/dev/null 2>&1
check "missing artifact -> exit 2" "$?" "2"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
