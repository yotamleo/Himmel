#!/usr/bin/env bash
# launch-profile-ok-file: startup tests run claude under a fake key with no model turn; a role profile would change the config under test (HIMMEL-4410)
# fakekey-claude.sh — credential-free headless claude runner for startup-only tests
# (HIMMEL-4410, epic HIMMEL-4409). Source it, then call:
#
#   fakekey_run <outdir> <claude args...>
#
# A run is "startup-only": Claude loads its config, plugins, hooks and MCP
# servers, then its first /v1/messages call is refused and the session ends in
# about a second. No model turn happens, so a run costs nothing and needs no
# login. What it leaves for assertions (verify by these, never by rc):
#   <outdir>/cfg/debug/*.txt   the --debug log (it is NOT on stderr)
#   <outdir>/out.json          the stdout envelope
#   <outdir>/err.txt           stderr
#   <outdir>/rc                the exit code
#
# Isolation (every item is checked by test-fakekey-claude-startup.sh):
#   * env -i: no operator variable reaches claude (no real key, token or
#     config dir); HOME and CLAUDE_CONFIG_DIR are scratch dirs under <outdir>.
#   * ANTHROPIC_API_KEY is a fake; ANTHROPIC_BASE_URL must be loopback or the
#     run is refused (return 2).
#   * a network namespace (unshare -rn) with only loopback up, so nothing can
#     reach a real host even if a code path ignores the base URL. If unshare
#     or ip is missing the run is REFUSED (return 3), never run unsandboxed;
#     FAKEKEY_SANDBOX=0 is the one explicit opt-out, used only by the RED
#     control that proves the sandbox matters.
#   * CLAUDE_CODE_MAX_RETRIES=0 + API_TIMEOUT_MS cap the doomed API call;
#     `timeout` bounds the whole run.
#
# Knobs (env, all optional): FAKEKEY_TIMEOUT_S (30), FAKEKEY_BASE_URL
# (http://127.0.0.1:9), FAKEKEY_NONESSENTIAL (1 sets
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC; 0 is the RED control that lets
# [Bootstrap] fire), FAKEKEY_SANDBOX (1), FAKEKEY_EXTRA_ENV (space-separated
# NAME=value pairs passed through env -i, for a fixture's own variables).

FAKEKEY_KEY="sk-ant-fake-000000000000"

# fakekey_loopback_url <url> — success only for http(s)://127.x / localhost / [::1].
fakekey_loopback_url() {
  case "$1" in
    *@*) return 1 ;; # userinfo (http://localhost:9@evil): the real host is after the @
  esac
  case "$1" in
    http://127.0.0.1 | http://127.0.0.1[:/]* | https://127.0.0.1 | https://127.0.0.1[:/]*) return 0 ;;
    http://localhost | http://localhost[:/]* | https://localhost | https://localhost[:/]*) return 0 ;;
    'http://[::1]' | 'http://[::1]'[:/]*) return 0 ;;
  esac
  return 1
}

# fakekey_sandbox_available — loopback-only netns usable here.
fakekey_sandbox_available() {
  command -v unshare >/dev/null 2>&1 && command -v ip >/dev/null 2>&1 &&
    unshare -rn sh -c 'ip link set lo up' >/dev/null 2>&1
}

# fakekey_debuglog <outdir> — path of the run's debug log (empty if none).
fakekey_debuglog() {
  local f
  for f in "$1"/cfg/debug/*.txt; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

fakekey_run() {
  local out="${1:?fakekey_run: outdir}"
  shift
  local base="${FAKEKEY_BASE_URL:-http://127.0.0.1:9}"
  local secs="${FAKEKEY_TIMEOUT_S:-30}"
  if ! fakekey_loopback_url "$base"; then
    echo "fakekey: refusing non-loopback ANTHROPIC_BASE_URL '$base'" >&2
    return 2
  fi
  local sandbox="${FAKEKEY_SANDBOX:-1}"
  case "$sandbox" in
    0 | 1) ;;
    *) echo "fakekey: FAKEKEY_SANDBOX must be 0 or 1, got '$sandbox' (fail closed)" >&2; return 2 ;;
  esac
  if [ "$sandbox" = 1 ] && ! fakekey_sandbox_available; then
    echo "fakekey: unshare -rn unavailable; refusing to run unsandboxed (fail closed)" >&2
    return 3
  fi
  local claude_bin node_bin
  claude_bin=$(command -v claude) || { echo "fakekey: claude not on PATH" >&2; return 4; }
  node_bin=$(command -v node) || { echo "fakekey: node not on PATH" >&2; return 4; }
  mkdir -p "$out/cfg" "$out/home" || return 4
  out=$(cd "$out" && pwd) || return 4 # absolute: the run cd's into $out
  rm -f "$out/rc" "$out/out.json" "$out/err.txt"
  local path="${claude_bin%/*}:${node_bin%/*}:/usr/local/bin:/usr/bin:/bin"
  local -a envv=(
    "PATH=$path" "HOME=$out/home" "CLAUDE_CONFIG_DIR=$out/cfg"
    "ANTHROPIC_API_KEY=$FAKEKEY_KEY" "ANTHROPIC_BASE_URL=$base"
    "CLAUDE_CODE_MAX_RETRIES=0" "API_TIMEOUT_MS=5000"
  )
  [ "${FAKEKEY_NONESSENTIAL:-1}" = 1 ] && envv+=("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1")
  # shellcheck disable=SC2206  # intentional word-splitting of NAME=value pairs
  [ -n "${FAKEKEY_EXTRA_ENV:-}" ] && envv+=(${FAKEKEY_EXTRA_ENV})
  local rc
  # headless-claude-ok: fake-key credential-free test, HIMMEL-4410
  if [ "$sandbox" = 1 ]; then
    (cd "$out" && env -i "${envv[@]}" unshare -rn sh -c 'ip link set lo up && exec timeout "$@"' _ \
      "$secs" "$claude_bin" -p "say hi" --output-format json --debug "$@" >"$out/out.json" 2>"$out/err.txt")
  else
    # headless-claude-ok: fake-key credential-free test, HIMMEL-4410
    (cd "$out" && env -i "${envv[@]}" timeout "$secs" "$claude_bin" -p "say hi" --output-format json --debug "$@" \
      >"$out/out.json" 2>"$out/err.txt")
  fi
  rc=$?
  printf '%s\n' "$rc" >"$out/rc"
  return 0
}
