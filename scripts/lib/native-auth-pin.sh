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
# `${var^^}` (upper-casing happens inside POSIX awk's toupper), no `grep -P`;
# portable environment enumeration via `env`. JSON screening shells out to
# node -- an established himmel dependency (claude-glm's screen does the same).

# _native_auth_pin_is_canonical is intentionally NOT a shell function: the
# predicate lives once, inside the awk below (toupper is POSIX), because a
# `tr` fork PER VARIABLE is brutally slow on Windows (large environment, MSYS
# fork cost) -- the first draft did exactly that and its test suite spent
# ~60s per case. The node screen and the PowerShell twin carry the same
# predicate in their own runtimes; this header's CANONICAL VARIABLE SET block
# is the definition they are all checked against.

native_auth_pin_env() {
  # Enumerate the environment portably: `env` emits one NAME=value per line
  # and names cannot contain newlines, so splitting at the first '=' is exact
  # even when a VALUE spans lines -- a value-continuation line either fails
  # the identifier-shape regex or names a canonical-family variable, which is
  # the fail-safe direction either way (it only ever unsets something the pin
  # is meant to clear). Process substitution (not a pipe) keeps the unsets in
  # THIS shell.
  local _name _failed=0
  while IFS= read -r _name; do
    # Plain unset: a failure here (e.g. readonly) means a canonical variable
    # SURVIVED the pin -- reported, never masked, so the caller can abort.
    unset "$_name" || _failed=1
  done < <(env | awk -F= '
    $1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ {
      n = toupper($1)
      if (n ~ /^ANTHROPIC_/ || n ~ /^CLAUDE_CODE_USE_/) print $1
    }')
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
