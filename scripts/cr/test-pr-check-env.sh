#!/usr/bin/env bash
# Smoke test for scripts/cr/pr-check-env.sh (HIMMEL-2226).
#
# Runs the script under test against isolated mktemp fixtures only - never
# the real repo's .env, never the network. Each fixture is a throwaway copy
# of scripts/cr/pr-check-env.sh + scripts/lib/load-dotenv.sh so the script's
# own SCRIPT_DIR/HIMMEL_ROOT resolution lands inside the fixture, not the
# real checkout.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/pr-check-env.sh"

pass=0
fail=0
check() {
    # $1 = got  $2 = want  $3 = label
    if [ "$1" = "$2" ]; then
        pass=$((pass + 1))
        echo "PASS: $3"
    else
        fail=$((fail + 1))
        echo "FAIL: $3 -- got '$1' want '$2'"
    fi
}

tmp="$(mktemp -d -t test-pr-check-env.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# fixture: a full .env, so the "resolved from .env" and "unset placeholder"
# paths are both exercised.
fixture="$tmp/fixture"
mkdir -p "$fixture/scripts/cr" "$fixture/scripts/lib"
cp "$SCRIPT" "$fixture/scripts/cr/pr-check-env.sh"
cp "$DIR/../lib/load-dotenv.sh" "$fixture/scripts/lib/load-dotenv.sh"
run="$fixture/scripts/cr/pr-check-env.sh"
cat >"$fixture/.env" <<'EOF'
CR_PROFILE=free,paid
CR_CLAUDE_AGENTS=
CR_REQUIRE_CROSS_MODEL=1
HIMMEL_DOC_FRESHNESS=advise
EOF

# fixture_bare: same script tree, NO .env at all - proves the truly-unset
# (no .env, no process env) path with nothing to fall back on.
bare="$tmp/bare"
mkdir -p "$bare/scripts/cr" "$bare/scripts/lib"
cp "$SCRIPT" "$bare/scripts/cr/pr-check-env.sh"
cp "$DIR/../lib/load-dotenv.sh" "$bare/scripts/lib/load-dotenv.sh"
run_bare="$bare/scripts/cr/pr-check-env.sh"

# 1. Default no-arg set: all four names, in order, values from .env, unset
# CR_CLAUDE_AGENTS gets the documented placeholder.
out1="$(env -u CR_PROFILE -u CR_CLAUDE_AGENTS -u CR_REQUIRE_CROSS_MODEL -u HIMMEL_DOC_FRESHNESS bash "$run")"
want1='pr-check-env: CR_PROFILE=free,paid
pr-check-env: CR_CLAUDE_AGENTS=<unset: inline adjudication, no Claude reviewer agents>
pr-check-env: CR_REQUIRE_CROSS_MODEL=1
pr-check-env: CR_REQUIRE_CROSS_MODEL_NORMALISED=1
pr-check-env: HIMMEL_DOC_FRESHNESS=advise'
check "$out1" "$want1" "T1 default no-arg set, in order"

# 2. Explicit subset prints only those, in the order requested (reversed vs
# the default order, and omitting CR_CLAUDE_AGENTS/CR_REQUIRE_CROSS_MODEL).
out2="$(env -u HIMMEL_DOC_FRESHNESS -u CR_PROFILE bash "$run" HIMMEL_DOC_FRESHNESS CR_PROFILE)"
want2='pr-check-env: HIMMEL_DOC_FRESHNESS=advise
pr-check-env: CR_PROFILE=free,paid'
check "$out2" "$want2" "T2 explicit subset, requested order"

# 3. Process-env value wins over the .env value.
out3="$(CR_PROFILE=live-only bash "$run" CR_PROFILE)"
check "$out3" "pr-check-env: CR_PROFILE=live-only" "T3 process env wins over .env"

# 4. Truly-unset variable (no .env, no process env) prints the documented
# placeholder for CR_CLAUDE_AGENTS.
out4="$(env -u CR_CLAUDE_AGENTS bash "$run_bare" CR_CLAUDE_AGENTS)"
check "$out4" "pr-check-env: CR_CLAUDE_AGENTS=<unset: inline adjudication, no Claude reviewer agents>" "T4 unset prints documented wording"

# 4b. A variable with no documented placeholder prints an empty value when
# unset, same as the fence it replaces.
out4b="$(env -u CR_PROFILE bash "$run_bare" CR_PROFILE)"
check "$out4b" "pr-check-env: CR_PROFILE=" "T4b unset var with no placeholder prints empty"

# 5. CR_REQUIRE_CROSS_MODEL_NORMALISED: truthy set (case-insensitive, trimmed).
for val in "1" "true" "TRUE" "on" "yes" "  yes  "; do
    out="$(env -u CR_REQUIRE_CROSS_MODEL CR_REQUIRE_CROSS_MODEL="$val" bash "$run_bare" CR_REQUIRE_CROSS_MODEL | tail -1)"
    check "$out" "pr-check-env: CR_REQUIRE_CROSS_MODEL_NORMALISED=1" "T5 normalised=1 for '$val'"
done

# 5b. Falsy / garbage set, plus truly empty (no .env, no process value).
for val in "0" "false" "off" "garbage"; do
    out="$(env -u CR_REQUIRE_CROSS_MODEL CR_REQUIRE_CROSS_MODEL="$val" bash "$run_bare" CR_REQUIRE_CROSS_MODEL | tail -1)"
    check "$out" "pr-check-env: CR_REQUIRE_CROSS_MODEL_NORMALISED=0" "T5b normalised=0 for '$val'"
done
out5c="$(env -u CR_REQUIRE_CROSS_MODEL bash "$run_bare" CR_REQUIRE_CROSS_MODEL | tail -1)"
check "$out5c" "pr-check-env: CR_REQUIRE_CROSS_MODEL_NORMALISED=0" "T5c normalised=0 for truly empty"

# 6. Invalid variable name exits 2 (and prints nothing to stdout).
out6="$(bash "$run" 'bad name' 2>"$tmp/err6.txt")"
rc6=$?
check "$rc6" "2" "T6 invalid name exit code"
check "$out6" "" "T6 invalid name emits nothing on stdout"

# 6b. A name starting with a digit is also refused.
rc6b=0
bash "$run" '1FOO' >/dev/null 2>"$tmp/err6b.txt" || rc6b=$?
check "$rc6b" "2" "T6b digit-leading name exit code"

[ "$fail" -eq 0 ] && echo "PASS test-pr-check-env ($pass/$((pass + fail)))"
[ "$fail" -eq 0 ] || { echo "FAIL test-pr-check-env ($fail/$((pass + fail)) failed)"; exit 1; }
