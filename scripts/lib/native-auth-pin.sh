#!/usr/bin/env bash
# native-auth-pin.sh -- the native-auth chokepoint for headless claude
# (HIMMEL-1867, second child of epic HIMMEL-1859). Source this library and call
# its entry points from every cadence site that launches claude in headless
# (print) mode, so the launch can never be silently proxied off native auth.
#
# Operator ruling 2026-08-17: headless claude as the default cadence shape is
# acceptable ONLY while it runs on NATIVE auth (the Anthropic login), never
# through CLIProxyAPI. The failure mode is silent, which is the whole problem:
# scripts/claude-codex.ps1:740 and scripts/claude-glm.ps1:525 export
# ANTHROPIC_BASE_URL pointing at their local proxy, so a headless claude that
# inherits that variable from an ambient shell is proxied with no error, no
# warning, and no signal -- the subscription credential re-exposed to a
# third-party router. A documented "don't set ANTHROPIC_BASE_URL" rule is
# undetectable when violated; this pin is the mechanism instead
# (structural > instructional).
#
# CANONICAL VARIABLE SET -- the single definition the other consumers are
# checked against. The emitted .bat cadence runners and the PowerShell twin
# scripts/lib/native-auth-pin.ps1 clear the SAME set:
#
#   every environment variable whose UPPER-CASED name starts with
#   `ANTHROPIC_` or `CLAUDE_CODE_USE_`
#
# Deliberately a PREFIX rule, not an enumeration -- the exact predicate of
# claude-glm's v2 screen/sanitizer (see the SEED_VERSION note there): a
# three-name list would miss ANTHROPIC_MODEL, the Bedrock/Vertex toggles, and
# any future key. Matching is case-insensitive in BOTH directions (the name is
# upper-cased before the prefix test; a lower-case `anthropic_base_url` is the
# same variable to a Windows child process).
#
# Native auth needs NONE of these variables: it authenticates from
# ~/.claude/.credentials.json or CLAUDE_CODE_OAUTH_TOKEN, neither of which
# carries those prefixes. CLAUDE_CODE_OAUTH_TOKEN is therefore NOT cleared --
# a pin that clears the native credential breaks the lane it exists to protect.
#
# The proxy lanes (scripts/claude-glm, scripts/claude-glm.ps1,
# scripts/claude-codex.ps1) are SUPPOSED to set ANTHROPIC_BASE_URL -- that is
# their correct behaviour and they are out of scope; this pin protects the
# native-claude path from INHERITING it.
#
# Entry points:
#   native_auth_pin_env              -- unset (not empty-export) every
#                                      canonical-set variable in the CURRENT
#                                      shell; call it immediately before the
#                                      launch. An empty ANTHROPIC_API_KEY is
#                                      itself a load-bearing routed-auth shape
#                                      (see scripts/claude-openrouter), so
#                                      emptying would not be clearing.
#   native_auth_pin_screen_settings  -- screen a `--settings` payload: refuse
#                                      (rc 3, message on stderr, BEFORE any
#                                      launch) when it injects
#                                      env.ANTHROPIC_* / env.CLAUDE_CODE_USE_*,
#                                      case-insensitively; fail closed when the
#                                      payload is unparseable or unreadable.
#                                      Callers that forward a FILE-backed
#                                      payload must also materialize it to
#                                      inline JSON (TOCTOU) -- see claude-glm's
#                                      screen_settings_arg for the pattern.
#
# bash 3.2-safe (macOS ships 3.2) and Git-Bash-safe: no `declare -A`, no
# `${var^^}` (the prefix test is a case-insensitive glob), no `grep -P`;
# enumeration is the `compgen -v` builtin -- no external tool, so a shadowed
# PATH entry cannot blind it (HIMMEL-4459). JSON screening shells out to
# node -- an established himmel dependency (claude-glm's screen does the same).
#
# LAUNCH GATE (HIMMEL-4459) -- the guarantee, and what carries it.
# native_auth_pin_env returns non-zero when it cannot enumerate or a target
# variable is still set, BUT ITS RETURN VALUE IS ADVISORY: any builtin it uses
# (`unset`, `return`, `builtin`, `compgen`) can be shadowed by an exported or
# in-shell function, an alias, or a BASH_ENV file, and with `unset` and `return`
# both shadowed it falls through rc 0 with the proxy variables still set. So
# every caller gates the LAUNCH on a condition built only from shell keywords and
# expansions (`[[ ]]`, `case`, `&&`, `${!PREFIX*}`, `$(<file)`) -- no function
# call, builtin or external command, hence nothing to shadow. It is a documented
# snippet, deliberately NOT a function (a function is shadowable). After the pin:
#
#   native_auth_pin_env
#   [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]] && <launch>
#
# (`|| <refuse>` for a refusing caller.) The one exception is the loopback-mock
# seam below, re-derived with the same keyword-only syntax in claude-headless.sh:
# the survivors must be exactly ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY, the URL a
# loopback literal without `@`, and `$(</proc/net/dev)` must list only `lo`.
#
# The gate checks the exact-case prefixes (ANTHROPIC_ / anthropic_ and the
# CLAUDE_CODE_USE_ pair) -- the names a child on Linux/macOS actually reads, since
# environment names are case-sensitive there. The pin itself still strips every
# mixed-case spelling for the case-insensitive Windows reader (parked,
# HIMMEL-4102); extending the gate to mixed case is tracked in HIMMEL-4461.
#
# True guarantee: an INHERITED variable, or a shadowed tool, cannot reach a
# launch through these callers. NOT guaranteed: a hostile shell that shadows the
# launcher itself (or `[[`/`.` etc.) -- that is out of scope; so is the PowerShell
# twin.

# The predicate lives once, as the case glob inside native_auth_pin_env (no
# fork per variable -- a `tr` per variable was brutally slow on Windows). The
# node screen and the PowerShell twin (not mirrored for HIMMEL-4459; Windows is
# parked, HIMMEL-4102) carry the same predicate in their own runtimes; this
# header's CANONICAL VARIABLE SET block is the definition they are checked against.

native_auth_pin_env() {
  # No external tool and no process substitution anywhere in this function: the
  # enumeration is `compgen -v` (a builtin) and the checks are `[[ ]]` / case /
  # parameter expansion, none of which a PATH entry can replace. A function named
  # like a builtin CAN shadow it, so the first line removes functions of the names
  # used here, and the final step re-checks with `${!PREFIX*}` expansions. That
  # is best effort: shadowing `unset` AND `return` defeats this function's own
  # report. The return value is therefore ADVISORY; callers MUST gate the launch
  # on the keyword-only LAUNCH GATE documented in the file header (HIMMEL-4459).
  unset -f unset builtin command compgen 2>/dev/null
  local IFS=$'\n' _name _names _failed=0 _keep_mock=0 _nd _line _n=0 _nonlo=0 _sawlo=0
  # Test seam (HIMMEL-4411): a mock-backed test may keep EXACTLY the base URL and
  # key, and only when the base URL is loopback -- so a headless launch can be
  # pointed at scripts/testing/mock-anthropic without the pin ever letting a real
  # or proxy host through. Everything else in the canonical set is still stripped.
  # The variable alone is not enough: a local relay on loopback could forward the
  # kept key anywhere, so the seam is honoured only when this process sees no
  # network interface but `lo` -- /proc/net/dev (per-netns; /sys/class/net still
  # lists the host NICs inside `unshare -rn`). Unreadable (non-Linux) = refuse.
  # This bounds an INHERITED variable only: a process that deliberately bridges
  # `lo` to the outside (e.g. a unix-socket relay) is NOT detected by it.
  if [[ "${NATIVE_AUTH_PIN_KEEP_LOOPBACK_MOCK:-}" = 1 && -r /proc/net/dev ]]; then
    _nd=$(</proc/net/dev) || { _nd=; _nonlo=1; }
    for _line in $_nd; do
      _n=$((_n + 1))
      [[ $_n -le 2 ]] && continue
      _line=${_line%%:*}
      _line=${_line// /}
      if [[ $_line = lo ]]; then _sawlo=1; else _nonlo=1; fi
    done
    if [[ $_nonlo = 0 && $_sawlo = 1 ]]; then
      case "${ANTHROPIC_BASE_URL:-}" in
        *@*) ;;
        http://127.0.0.1 | http://127.0.0.1[:/]* | http://localhost | http://localhost[:/]*) _keep_mock=1 ;;
      esac
    fi
  fi
  _names=$(builtin compgen -v) || return 1
  # An enumeration that yields nothing cannot be trusted (any real shell has PATH).
  [[ -n "$_names" ]] || return 1
  for _name in $_names; do
    case "$_name" in
      [Aa][Nn][Tt][Hh][Rr][Oo][Pp][Ii][Cc]_* | [Cc][Ll][Aa][Uu][Dd][Ee]_[Cc][Oo][Dd][Ee]_[Uu][Ss][Ee]_*) ;;
      *) continue ;;
    esac
    if [[ $_keep_mock = 1 ]]; then
      case "$_name" in ANTHROPIC_BASE_URL | ANTHROPIC_API_KEY) continue ;; esac
    fi
    # Plain unset: a failure here (e.g. readonly) means a canonical variable
    # SURVIVED the pin -- reported, never masked, so the caller can abort.
    unset "$_name" || _failed=1
  done
  # Independent verification: anything still set is a refusal. First a second
  # enumeration pass (catches mixed-case names a no-op `unset` left behind), then
  # by expansion -- four prefix expansions, not commands, so unshadowable.
  _names=$(builtin compgen -v) || return 1
  for _name in $_names; do
    case "$_name" in
      [Aa][Nn][Tt][Hh][Rr][Oo][Pp][Ii][Cc]_* | [Cc][Ll][Aa][Uu][Dd][Ee]_[Cc][Oo][Dd][Ee]_[Uu][Ss][Ee]_*) ;;
      *) continue ;;
    esac
    if [[ $_keep_mock = 1 ]]; then
      case "$_name" in ANTHROPIC_BASE_URL | ANTHROPIC_API_KEY) continue ;; esac
    fi
    _failed=1
  done
  _name="${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}"
  if [[ $_keep_mock = 1 ]]; then
    _name=${_name//ANTHROPIC_BASE_URL/}
    _name=${_name//ANTHROPIC_API_KEY/}
    _name=${_name//$'\n'/}
  fi
  [[ -z "$_name" ]] || _failed=1
  return "$_failed"
}

native_auth_pin_screen_settings() { # $1 = --settings value (file path or inline JSON)
  local _payload="${1:-}" _rc
  # Fail closed when node is absent -- a screen that cannot run must not pass.
  command -v node >/dev/null 2>&1 || {
    echo "native-auth-pin: REFUSED - cannot screen the --settings payload (node not found); an unscreened payload might pull headless claude off native auth (HIMMEL-1867)." >&2
    return 3
  }
  # Exit codes from node: 2 = unparseable/unreadable, 3 = canonical-key
  # injection (mirrors claude-glm's screen_settings_arg).
  if node -e '
const s = process.argv[1];
const inline = s.trim().charAt(0) === "{";
let j;
try {
  j = JSON.parse(inline ? s : require("fs").readFileSync(s, "utf8"));
} catch (e) { process.exit(2); }
for (const k of Object.keys((j && j.env) || {})) {
  const u = k.toUpperCase();
  if (u.indexOf("ANTHROPIC_") === 0 || u.indexOf("CLAUDE_CODE_USE_") === 0) process.exit(3);
}
process.exit(0);
' "$_payload"; then
    return 0
  else
    _rc=$?
    echo "native-auth-pin: REFUSED - --settings payload sets env.ANTHROPIC_* / env.CLAUDE_CODE_USE_* (or is unparseable/unreadable, node rc=$_rc); it would pull headless claude off native auth (HIMMEL-1867)." >&2
    return 3
  fi
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "usage: native-auth-pin.sh is a sourceable library -- source it, then call native_auth_pin_env or native_auth_pin_screen_settings <payload>" >&2
  exit 2
fi
