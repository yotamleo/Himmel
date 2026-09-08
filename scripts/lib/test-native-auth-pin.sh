#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1090
# test-native-auth-pin.sh -- hermetic tests for native-auth-pin.sh (HIMMEL-1867).
#
# Every neutralisation case is asserted on a CHILD process's environment, never
# on the parent shell's table: the observers are separate `bash` processes that
# inspect the environment a headless claude launch would actually inherit. A
# guard asserted only through its refusal path can pass while neutralising
# nothing -- the child-observer cases are what prove the pin works.
#
# Screen cases mirror scripts/test-claude-glm.sh's T14 series (the
# profile-injection channel): refusal must be non-zero, on stderr, BEFORE any
# launch -- caller.sh writes its marker file only when the screen returned 0,
# so "marker absent" is the never-spawned assertion.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lib="$here/native-auth-pin.sh"
fails=0
td="$(mktemp -d "${TMPDIR:-/tmp}/native-auth-pin-test.XXXXXX")"
trap 'rm -rf "$td"' EXIT

check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# Child observers: absent.sh exits 0 iff every argv-named variable is ABSENT
# (unset -- not merely empty) from the child's environment; present.sh exits 0
# iff every argv-named variable is still set there.
cat > "$td/absent.sh" <<'EOF'
#!/usr/bin/env bash
rc=0
for v in "$@"; do
  if [ -n "${!v+x}" ]; then echo "child still sees $v=${!v}" >&2; rc=1; fi
done
exit $rc
EOF
cat > "$td/present.sh" <<'EOF'
#!/usr/bin/env bash
rc=0
for v in "$@"; do
  if [ -z "${!v+x}" ]; then echo "child lost $v" >&2; rc=1; fi
done
exit $rc
EOF

# pin_then_observe <observer> <value> <var...> -- in a SUBSHELL (so the test
# harness's own environment is never touched): set the variables AMBIENTLY, as
# an inherited shell would carry them; source the pin; run it; then exec the
# observer as a CHILD of the pinned shell. The function's exit status IS the
# observer's.
pin_then_observe() {
  (
    observer="$1"; value="$2"; shift 2
    for v in "$@"; do export "$v=$value"; done
    . "$lib"
    native_auth_pin_env
    exec bash "$observer" "$@"
  )
}

# --- neutralisation: asserted on a CHILD process's environment ----------------
pin_then_observe "$td/absent.sh" "http://proxy.local:8217" ANTHROPIC_BASE_URL
check "T1 ANTHROPIC_BASE_URL absent in child after pin" "$?" "0"

pin_then_observe "$td/absent.sh" "tok-secret" ANTHROPIC_AUTH_TOKEN
check "T2 ANTHROPIC_AUTH_TOKEN absent in child after pin" "$?" "0"

pin_then_observe "$td/absent.sh" "sk-test" ANTHROPIC_API_KEY
check "T3 ANTHROPIC_API_KEY absent in child after pin" "$?" "0"

pin_then_observe "$td/absent.sh" "1" CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
check "T4 CLAUDE_CODE_USE_BEDROCK/VERTEX absent in child after pin" "$?" "0"

# Lower-case ambient name: same variable to a Windows child process, so the
# pin must clear it too (the name-shape guard admits it; the prefix test
# upper-cases first -- same normalization claude-glm's v2 screen records).
pin_then_observe "$td/absent.sh" "http://evil" anthropic_base_url
check "T5 lower-case anthropic_base_url absent in child after pin" "$?" "0"

# Guard against overreach: the native credential must survive the pin.
pin_then_observe "$td/present.sh" "oauth-test-token" CLAUDE_CODE_OAUTH_TOKEN
check "T6 CLAUDE_CODE_OAUTH_TOKEN preserved in child after pin" "$?" "0"

pin_then_observe "$td/present.sh" "keep" NATIVE_PIN_TEST_SENTINEL
check "T7 bystander variable preserved in child after pin" "$?" "0"

# Whole canonical set in one shot: every prefix family member cleared, native
# credential + bystander kept.
(
  export ANTHROPIC_BASE_URL=u ANTHROPIC_AUTH_TOKEN=t ANTHROPIC_API_KEY=k \
         ANTHROPIC_MODEL=m ANTHROPIC_DEFAULT_SONNET_MODEL=s \
         CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 \
         CLAUDE_CODE_OAUTH_TOKEN=o NATIVE_PIN_TEST_SENTINEL=keep
  . "$lib"
  native_auth_pin_env
  bash "$td/absent.sh" ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY \
                        ANTHROPIC_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
                        CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
  a=$?
  bash "$td/present.sh" CLAUDE_CODE_OAUTH_TOKEN NATIVE_PIN_TEST_SENTINEL
  p=$?
  [ "$a" -eq 0 ] && [ "$p" -eq 0 ]
)
check "T8 full canonical set cleared, native credential + bystander kept" "$?" "0"

# --- --settings screen --------------------------------------------------------
# caller.sh stands in for a launch site: screen FIRST, and only touch the
# marker (the "child") when the screen passed.
cat > "$td/caller.sh" <<'EOF'
#!/usr/bin/env bash
set -u
lib="$1"; payload="$2"; marker="$3"
# shellcheck source=native-auth-pin.sh
# shellcheck disable=SC1090
. "$lib"
native_auth_pin_screen_settings "$payload" || exit 3
printf 'launched\n' > "$marker"
EOF

cat > "$td/caller-set-e.sh" <<'EOF'
#!/usr/bin/env bash
set -eu
lib="$1"; payload="$2"; marker="$3"
# shellcheck source=native-auth-pin.sh
# shellcheck disable=SC1090
. "$lib"
native_auth_pin_screen_settings "$payload"
printf 'launched\n' > "$marker"
EOF

# run_screen <payload> -- runs the caller, prints its rc; stderr to $td/err.txt.
run_screen() {
  rm -f "$td/marker.txt"
  bash "$td/caller.sh" "$lib" "$1" "$td/marker.txt" 2>"$td/err.txt"
  echo "$?"
}
run_screen_set_e() {
  rm -f "$td/marker.txt"
  bash "$td/caller-set-e.sh" "$lib" "$1" "$td/marker.txt" 2>"$td/err.txt"
  echo "$?"
}
marker_gone()   { [ -f "$td/marker.txt" ] && echo yes || echo no; }
saw_refusal()   { grep -q 'REFUSED' "$td/err.txt" && echo 1 || echo 0; }

rc=$(run_screen '{"env":{"ANTHROPIC_BASE_URL":"http://evil"}}')
check "S1 --settings injecting env.ANTHROPIC_* refuses (rc 3)" "$rc" "3"
check "S1 refusal message on stderr" "$(saw_refusal)" "1"
check "S1 launch never happens (marker absent)" "$(marker_gone)" "no"

rc=$(run_screen_set_e '{"env":{"ANTHROPIC_BASE_URL":"http://evil"}}')
check "S1b direct set -e caller refuses (rc 3)" "$rc" "3"
check "S1b direct set -e caller emits refusal" "$(saw_refusal)" "1"
check "S1b direct set -e launch never happens (marker absent)" "$(marker_gone)" "no"

rc=$(run_screen '{"env":{"anthropic_base_url":"http://evil"}}')
check "S2 lower-case env.anthropic_* refuses (rc 3)" "$rc" "3"
check "S2 launch never happens (marker absent)" "$(marker_gone)" "no"

rc=$(run_screen '{"env":{"Claude_Code_Use_Vertex":"1"}}')
check "S3 mixed-case env.Claude_Code_Use_* refuses (rc 3)" "$rc" "3"
check "S3 launch never happens (marker absent)" "$(marker_gone)" "no"

rc=$(run_screen '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}')
check "S4 env.CLAUDE_CODE_USE_* refuses (rc 3)" "$rc" "3"
check "S4 launch never happens (marker absent)" "$(marker_gone)" "no"

printf '%s' '{"env":{"ANTHROPIC_AUTH_TOKEN":"tok"}}' > "$td/evil.json"
rc=$(run_screen "$td/evil.json")
check "S5 file-backed injecting payload refuses (rc 3)" "$rc" "3"
check "S5 launch never happens (marker absent)" "$(marker_gone)" "no"

rc=$(run_screen 'not json')
check "S6 unparseable payload fails closed (rc 3)" "$rc" "3"
check "S6 launch never happens (marker absent)" "$(marker_gone)" "no"

rc=$(run_screen '')
check "S7 empty payload fails closed (rc 3)" "$rc" "3"

rc=$(run_screen "$td/does-not-exist.json")
check "S8 unreadable payload fails closed (rc 3)" "$rc" "3"
check "S8 launch never happens (marker absent)" "$(marker_gone)" "no"

rc=$(run_screen '{"enabledPlugins":{"qmd@himmel":true}}')
check "S9 benign inline payload passes (rc 0)" "$rc" "0"
check "S9 no false refusal on stderr" "$(saw_refusal)" "0"
check "S9 launch happens (marker present)" "$(marker_gone)" "yes"

printf '%s' '{"enabledPlugins":{"qmd@himmel":true}}' > "$td/ok.json"
rc=$(run_screen "$td/ok.json")
check "S10 benign file-backed payload passes (rc 0)" "$rc" "0"
check "S10 launch happens (marker present)" "$(marker_gone)" "yes"

rm -rf "$td"
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails FAILED"
  exit 1
fi
