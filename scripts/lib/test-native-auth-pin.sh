#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1090,SC2030,SC2031,SC2016,SC2317,SC2329
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
# nz <rc> -> "refused" only for a numeric non-zero rc (empty or garbage is not a refusal)
nz(){ case "$1" in '' | *[!0-9]* | 0) echo "rc:$1" ;; *) echo refused ;; esac; }

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

# --- fail closed under a shadowed tool / broken strip (HIMMEL-4459) -----------
# shadow_run <setup> -- run <setup> (shadows) in a subshell BEFORE sourcing the
# pin, pin an evil-routed environment, then report "<pin rc> <child verdict>"
# where the child verdict is whether the routing variables are absent in a CHILD.
shadow_run() {
  (
    export ANTHROPIC_BASE_URL=https://evil.example ANTHROPIC_API_KEY=sk-x ANTHROPIC_MODEL=m
    eval "$1"
    . "$lib"
    native_auth_pin_env; prc=$?
    bash "$td/absent.sh" ANTHROPIC_BASE_URL ANTHROPIC_API_KEY ANTHROPIC_MODEL 2>/dev/null && v=absent || v=survived
    echo "$prc $v"
  )
}

check "T9 export -f awk cannot stop the strip" "$(shadow_run 'awk(){ :; }; export -f awk')" "0 absent"
check "T10 export -f tail/cut/tr/grep/env cannot stop the strip" \
  "$(shadow_run 'for f in tail cut tr grep env; do eval "$f(){ :; }"; export -f "$f"; done')" "0 absent"
check "T10b export -f compgen/builtin/command cannot stop the strip" \
  "$(shadow_run 'compgen(){ return 1; }; builtin(){ return 1; }; command(){ return 1; }; export -f compgen builtin command')" "0 absent"

mkdir -p "$td/fakebin"
for t in awk env tail cut tr grep sed; do printf '#!/bin/sh\nexit 0\n' > "$td/fakebin/$t"; chmod +x "$td/fakebin/$t"; done
check "T11 fake tools earlier in PATH cannot stop the strip" "$(shadow_run "PATH='$td/fakebin':\$PATH")" "0 absent"

# A strip that cannot run must REFUSE (rc != 0), never return 0 with the
# routing variable still set: a no-op `unset` leaves every target set.
r=$(shadow_run 'unset(){ return 0; }; export -f unset')
check "T12 no-op unset: pin refuses (rc non-zero)" "$(nz "${r%% *}")" "refused"

r=$( (
  export Anthropic_Base_Url=https://evil.example
  unset(){ return 0; }; export -f unset
  . "$lib"
  native_auth_pin_env; echo $?
) 2>/dev/null)
check "T14 no-op unset: surviving mixed-case name -> pin refuses" "$(nz "$r")" "refused"

# Seam (HIMMEL-4411) keeping BOTH mock names must return 0, not trip the
# verification on the separator between them. Needs a loopback-only netns.
r=$(unshare -rn bash -c '
  export NATIVE_AUTH_PIN_KEEP_LOOPBACK_MOCK=1 ANTHROPIC_BASE_URL=http://127.0.0.1:9 ANTHROPIC_API_KEY=k ANTHROPIC_MODEL=m
  . "$1"; native_auth_pin_env; echo "$? ${ANTHROPIC_BASE_URL:+kept} ${ANTHROPIC_MODEL:-gone}"' _ "$lib" 2>/dev/null) || r=skip
if [ "$r" = skip ]; then echo "  SKIP  T15 (no unshare -rn)"; else check "T15 seam keeping base URL + key returns 0, strips the rest" "$r" "0 kept gone"; fi

r=$( (
  export ANTHROPIC_BASE_URL=https://evil.example
  readonly ANTHROPIC_BASE_URL
  . "$lib"
  native_auth_pin_env; echo $?
) 2>/dev/null)
check "T13 readonly target survives -> pin refuses (rc non-zero)" "$(nz "$r")" "refused"

# HIMMEL-4461 item 1: `unset` no-op AND `builtin` replaced by a function that
# emits only PATH blinds both compgen passes; a mixed-case name the exact-case
# expansions do not cover must still make the pin refuse. `return` shadowed too:
# the verdict may not ride on a shadowable builtin.
r=$( (
  export Anthropic_Base_Url=https://evil.example
  unset(){ return 0; }; builtin(){ echo PATH; }; export -f unset builtin
  . "$lib"
  native_auth_pin_env; echo $?
) 2>/dev/null)
check "T16 unset+builtin shadow: surviving mixed-case name -> pin refuses" "$(nz "$r")" "refused"
r=$( (
  export Claude_Code_Use_Bedrock=1
  unset(){ return 0; }; builtin(){ echo PATH; }; return(){ :; }; export -f unset builtin return
  . "$lib"
  native_auth_pin_env; echo $?
) 2>/dev/null)
check "T16b unset+builtin+return shadow: mixed-case name -> pin refuses" "$(nz "$r")" "refused"
r=$(bash -c '
  export Anthropic_Api_Key=sk-x
  shopt -s expand_aliases
  alias unset=: builtin="echo PATH; :" compgen="echo PATH; :"
  . "$1"
  native_auth_pin_env; echo $?' _ "$lib" 2>/dev/null)
check "T16c alias unset/builtin/compgen: mixed-case name -> pin refuses" "$(nz "$r")" "refused"

# Substring removal (HIMMEL-4461 follow-up): with the seam on, a name built from
# the two kept names must not vanish from the verification.
r=$(unshare -rn bash -c '
  export NATIVE_AUTH_PIN_KEEP_LOOPBACK_MOCK=1 ANTHROPIC_BASE_URL=http://127.0.0.1:9 ANTHROPIC_API_KEY=k ANTHROPIC_BASE_URLANTHROPIC_API_KEY=x
  unset(){ return 0; }; builtin(){ echo PATH; }; export -f unset builtin
  . "$1"; native_auth_pin_env; echo $?' _ "$lib" 2>/dev/null) || r=skip
if [ "$r" = skip ]; then echo "  SKIP  T17 (no unshare -rn)"; else check "T17 seam: concatenated kept names do not vanish -> pin refuses" "$(nz "$r")" "refused"; fi

# HIMMEL-4461 item 2: the seam keeps the mock only after a read of
# /proc/net/dev that OBSERVED `lo` and nothing else. A fake /proc is bind-mounted
# in a private mount+user namespace; prints "kept" or "stripped".
netdev_run() { # <net/dev content file>
  mkdir -p "$td/fp/net"; cp "$1" "$td/fp/net/dev"
  unshare -rmn bash -c '
    mount --bind "$2" /proc || exit 9
    export NATIVE_AUTH_PIN_KEEP_LOOPBACK_MOCK=1 ANTHROPIC_BASE_URL=http://127.0.0.1:9 ANTHROPIC_API_KEY=k
    . "$1"; native_auth_pin_env; [[ -n ${ANTHROPIC_BASE_URL-} ]] && echo kept || echo stripped' _ "$lib" "$td/fp" 2>/dev/null || echo skip
}
hdr=$'Inter-|   Receive\n face |bytes'
: > "$td/nd-empty"
printf '%s\n' "$hdr" > "$td/nd-hdr"
printf '%s\n%s\n' "$hdr" '    lo: 0 0' > "$td/nd-lo"
printf '%s\n%s\n%s\n' "$hdr" '    lo: 0 0' '  eth0: 0 0' > "$td/nd-eth"
r=$(netdev_run "$td/nd-lo")
if [ "$r" = skip ]; then echo "  SKIP  N1-N4 (no unshare -rmn bind of /proc)"; else
  check "N1 control: lo-only read keeps the mock" "$r" "kept"
  check "N2 empty /proc/net/dev read -> mock stripped" "$(netdev_run "$td/nd-empty")" "stripped"
  check "N3 header-only read (no lo observed) -> mock stripped" "$(netdev_run "$td/nd-hdr")" "stripped"
  check "N4 lo plus a non-lo interface -> mock stripped" "$(netdev_run "$td/nd-eth")" "stripped"
fi

# --- caller-level: the keyword-only LAUNCH GATE (HIMMEL-4459) ------------------
# With `unset` AND `return` shadowed the pin itself falls through rc 0 with the
# proxy variables set; the gate each caller carries (header of the pin) must still
# refuse. gate_caller.sh is the short gate verbatim; `launched` = the gate passed.
cat > "$td/gate_caller.sh" <<'EOF'
#!/usr/bin/env bash
# $1 = pin lib, $2 = shadow mode
lib="$1"
case "$2" in
  insh) unset(){ :; }; return(){ :; } ;;
  alias) shopt -s expand_aliases
alias unset=: return=:
;;
  ro) return(){ :; }; readonly ANTHROPIC_BASE_URL ;;
esac
. "$lib"
native_auth_pin_env
[[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]] && echo launched || echo refused
EOF
gate_run() { # <mode> -> launched|refused ; ambient proxy vars as an inherited shell carries them
  ( export ANTHROPIC_BASE_URL=https://evil.example ANTHROPIC_API_KEY=x CLAUDE_CODE_USE_BEDROCK=1
    case "$1" in
      exp) unset(){ :; }; return(){ :; }; export -f unset return ;;
      env) printf '%s\n' 'unset(){ :; }' 'return(){ :; }' > "$td/shadow-env.sh"; export BASH_ENV="$td/shadow-env.sh" ;;
    esac
    bash "$td/gate_caller.sh" "$lib" "$1" 2>/dev/null )
}
check "G1 control: no shadow -> pin strips, gate passes (launched)" "$(gate_run none)" "launched"
check "G2 exported unset+return shadows -> gate refuses" "$(gate_run exp)" "refused"
check "G3 in-shell (non-exported) unset+return shadows -> gate refuses" "$(gate_run insh)" "refused"
check "G4 startup-file unset+return shadows -> gate refuses" "$(gate_run env)" "refused"
check "G5 alias unset/return shadows -> gate refuses" "$(gate_run alias)" "refused"
check "G6 readonly target + return shadow -> gate refuses" "$(gate_run ro)" "refused"

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
