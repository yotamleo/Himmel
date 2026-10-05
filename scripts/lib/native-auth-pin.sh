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
# enumeration is the `"${!A@}"`-style prefix expansion -- no external tool and no
# builtin, so neither a shadowed PATH entry nor a function or alias can blind it
# (HIMMEL-4459, HIMMEL-4461). JSON screening shells out to
# node -- an established himmel dependency (claude-glm's screen does the same).
#
# LAUNCH GATE (HIMMEL-4459) -- the guarantee, and what carries it.
# native_auth_pin_env returns non-zero when a target variable is still set. Since
# HIMMEL-4461 that verdict rides on no builtin: enumeration and verification are
# expansions and the status is a final `[[ ]]` (no `return`), so a function or
# alias shadowing `unset`/`return`/`builtin`/`compgen`, or a readonly/nameref
# loop variable set beforehand, can stop the strip but not hide it. A shadowed
# `unset` is still CALLED inside the function, though, and can rewrite its locals
# (e.g. `_failed`, `_keep_mock`) -- so the rc is advisory. The limits below (aliased keywords, BASH_ENV DEBUG traps) still apply
# to the function, and a launch must not depend on a function call, so every
# caller ALSO gates the LAUNCH on a condition built only from shell keywords and
# expansions (`[[ ]]`, `case`, `&&`, `${!PREFIX*}`, `$(<file)`) -- no function
# call, builtin or external command, hence nothing to shadow. It is a documented
# snippet, deliberately NOT a function (a function is shadowable). After the pin:
#
#   native_auth_pin_env
#   if [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}" ]]; then
#     <launch>
#   else
#     <refuse>
#   fi
#
# The LAUNCH sits INSIDE the keyword branch; the refusal may use exit/return/`[`
# freely, because a shadowed refusal can only skip the refusal, never reach the
# launch (a refuse-then-launch shape falls through when `exit`/`return` is
# shadowed). The one exception is the loopback-mock
# seam below, re-derived with the same keyword-only syntax in claude-headless.sh:
# the survivors must be exactly ANTHROPIC_BASE_URL / ANTHROPIC_API_KEY, the URL a
# loopback literal without `@`, and `$(</proc/net/dev)` must list only `lo`.
#
# The gate checks the exact-case prefixes (ANTHROPIC_ / anthropic_ and the
# CLAUDE_CODE_USE_ pair) -- the names a child on Linux/macOS actually reads, since
# environment names are case-sensitive there. The pin itself strips every
# mixed-case spelling for the case-insensitive Windows reader, and refuses
# (non-zero) when one survives (HIMMEL-4461).
# ponytail: the launch gate is exact-case and callers ignore the pin's rc, so on a
# case-insensitive Windows reader a mixed-case survivor of a shadowed `unset` is
# not refused at launch; extend the gate when Windows is unparked (HIMMEL-4102).
#
# What this guarantees (HIMMEL-4459, narrowed by HIMMEL-4461): an INHERITED
# exact-case variable cannot reach a launch through these callers, and a shadowed
# unset/return/builtin/compgen/exit/cd or `[` cannot turn a refusal into a launch
# or set a variable between the gate and the launch -- every caller does its `cd`
# and other commands BEFORE the gate, so only the launch follows the keyword test.
# It does NOT guarantee, and these are out of scope:
#   - a shadowed LAUNCHER (an exported function or alias for `claude`, `timeout`,
#     `env`, or the stub binary) -- the gate cannot see what the launch runs;
#   - a `[[` alias or redefinition injected by a startup file (BASH_ENV, rc file);
#   - a BASH_ENV with `set -T` plus a DEBUG trap that re-exports a variable at
#     launch time, which defeats any in-shell gate;
#   - an env-selected launcher: LQ_CLAUDE_BIN, LQ_LANE_BIN, CRYSTALLIZE_CLAUDE_BIN
#     and HIMMEL_CLAUDE_BIN name the binary that runs, so whoever sets them
#     controls the launch outright;
#   - a mixed-case spelling at launch (see above): the pin strips it and its rc
#     refuses a survivor, the gate does not re-check it; or the PowerShell twin.

# The predicate lives once, as the case glob inside native_auth_pin_env (no
# fork per variable -- a `tr` per variable was brutally slow on Windows). The
# node screen and the PowerShell twin (not mirrored for HIMMEL-4459; Windows is
# parked, HIMMEL-4102) carry the same predicate in their own runtimes; this
# header's CANONICAL VARIABLE SET block is the definition they are checked against.

native_auth_pin_env() {
  # No external tool, no builtin in the decision path and no `return`: the
  # enumeration and the verification are `${!X@}` expansions, the checks are
  # `[[ ]]` / case / `for`, and the verdict is the final `[[ ]]`'s status
  # (HIMMEL-4461). The one builtin that acts is `unset`; a shadowed `unset` that
  # only no-ops stops the strip without hiding it -- the expansion pass sees the
  # survivor and the pin returns non-zero. One that also rewrites this function's
  # locals can hide it, which is why callers gate the launch on the keyword-only
  # LAUNCH GATE in the file header (the limits listed there -- aliased keywords,
  # BASH_ENV DEBUG traps -- apply to this function too).
  unset -f unset 2>/dev/null
  local IFS=$'\n' _name _failed _keep_mock _nd _line _n _nonlo _sawlo
  # Plain assignments, not `local` initialisers: a shadowed `local` must not leave
  # an inherited _keep_mock=1 in force.
  _failed=0 _keep_mock=0 _n=0 _nonlo=0 _sawlo=0
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
  # Enumerate by EXPANSION (HIMMEL-4461): "${!A@}" and friends are parameter
  # expansions, not commands, so no function, alias or PATH entry can blind them,
  # and every canonical name -- any case mix -- starts with one of these four
  # letters. Each expansion still scans bash's whole variable table (as compgen
  # does), so a huge environment stays slow -- measured, deferred (HIMMEL-4474).
  # Loop-variable sentinel (HIMMEL-4461): a readonly `_name` set before the call
  # makes `local` fail and `for _name` abort silently, and a nameref `_name`
  # (with `local` shadowed) walks VALUES instead of names. A plain self-named
  # assignment exposes both -- it errors out on a readonly (aborting the call,
  # non-zero) and `${!_name}` names the target of a nameref -- so either one
  # fails closed here instead of returning 0 from an empty loop.
  _name=_name
  [[ ${!_name} == _name ]] || _failed=1
  for _name in "${!A@}" "${!a@}" "${!C@}" "${!c@}"; do
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
  # Independent verification by the same expansions: anything still set (a no-op
  # `unset`, a readonly) is a refusal. Exact-name matches only -- never substring
  # removal, which would erase a name built from the two kept ones. The sentinel
  # is re-checked: the `unset` above is the one call a shadow could run inside.
  _name=_name
  [[ ${!_name} == _name ]] || _failed=1
  for _name in "${!A@}" "${!a@}" "${!C@}" "${!c@}"; do
    case "$_name" in
      [Aa][Nn][Tt][Hh][Rr][Oo][Pp][Ii][Cc]_* | [Cc][Ll][Aa][Uu][Dd][Ee]_[Cc][Oo][Dd][Ee]_[Uu][Ss][Ee]_*) ;;
      *) continue ;;
    esac
    if [[ $_keep_mock = 1 ]]; then
      case "$_name" in ANTHROPIC_BASE_URL | ANTHROPIC_API_KEY) continue ;; esac
    fi
    _failed=1
  done
  # The verdict is the status of this last keyword test -- no `return`, which a
  # function could shadow into a fall-through.
  [[ $_failed = 0 ]]
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
