#!/usr/bin/env bash
# scripts/upstreams/apply-tool-upgrade.sh — upgrade ONE installed vendor CLI
# that himmel tracks by probe (HIMMEL-1323).
#
# WHY a second script instead of extending apply-drift-bump.sh: the two repair
# the same registry but they are not the same operation. A `mode: base` entry's
# drift is a PIN in the repo — repairing it is a file edit that lands as a PR,
# reviewable, revertable, identical on every machine. A `mode: probe` entry's
# drift is a BINARY on THIS machine — there is nothing in the repo to change,
# nothing to review, and the result is a mutation of the operator's toolchain
# that no PR can undo. Sharing one entry point would blur exactly the line that
# matters here.
#
# The check that makes this trustworthy is the RE-PROBE. A package manager that
# exits 0 without actually moving the version is the normal failure mode (a
# resolver that decided nothing was needed, a partial install, a shim pointing
# at the old build), and it is indistinguishable from success by exit code
# alone. So success is defined as "the probed version STRICTLY advanced", never
# as "the command exited 0".
#
# POLICY GATE. A registry `upgrade` block carries `unattended: true|false`.
# `--unattended` — which the nightly drift-fix cadence ALWAYS passes — refuses
# any entry not marked `unattended: true`, so a gated entry stays a one-command
# MANUAL upgrade rather than a nightly automatic one. Invoking this script
# WITHOUT --unattended is the operator's approval for a gated entry.
#
# WHICH entries are gated lives in the registry, not here — read it, do not
# trust this comment for that. (As of 2026-07-28 neither probe entry is gated:
# twitter-cli is Tier A with no caveat, and rtk was approved unattended by the
# operator that day, overriding its Tier B default; rtk's entry note carries the
# reservation and the revert path.) This paragraph is deliberately short on
# specifics because four earlier copies of it went stale within hours of the
# registry changing — a comment must not restate a fact that lives in data.
#
# `upgrade.command` is an argv ARRAY and is executed as argv — never through a
# shell. There is no string to quote, so there is no injection surface, and a
# registry entry cannot smuggle a `;` into a command.
#
# Usage:
#   bash scripts/upstreams/apply-tool-upgrade.sh <name> [target-version] [--dry-run] [--unattended]
#
# Env / test seams:
#   DRIFT_REGISTRY    registry path (default: <repo>/scripts/upstreams.json).
#   DRIFT_REPO_ROOT   cwd the upgrade command runs from (default: this repo).
#
# Exit codes:
#   0  upgraded — the probed version strictly advanced
#   1  nothing to do — already at or ahead of the requested version
#   2  usage / unknown entry / wrong kind+mode / malformed registry / the tool
#      is not installed (this UPGRADES, it does not install)
#   3  SKIP — no `upgrade` declared, or `--unattended` was passed and the entry
#      is not marked `unattended: true`
#   4  the upgrade ran but the version did NOT advance (or the tool stopped
#      reporting a version at all) — treat the toolchain as suspect
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="${DRIFT_REPO_ROOT:-$(cd "$SELF_DIR/../.." && pwd)}"
REGISTRY="${DRIFT_REGISTRY:-$REPO_ROOT/scripts/upstreams.json}"

usage() {
  echo "usage: apply-tool-upgrade.sh <name> [target-version] [--dry-run] [--unattended]" >&2
  echo "  <name>            a tag_release/probe entry in scripts/upstreams.json" >&2
  echo "  [target-version]  the upstream version to reach (from the drift guard's" >&2
  echo "                    BEHIND line). Optional, but pass it when you have it:" >&2
  echo "                    without it 'already latest' and 'upgrade silently did" >&2
  echo "                    nothing' are indistinguishable." >&2
  echo "  --unattended      refuse any entry not marked upgrade.unattended:true" >&2
  echo "  exit: 0 upgraded | 1 already current | 2 usage/registry/not-installed" >&2
  echo "        | 3 SKIP not auto-upgradable | 4 ran but did not reach the target" >&2
}

NAME=""
TARGET=""
DRY_RUN=0
UNATTENDED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --unattended) UNATTENDED=1 ;;
    -h|--help)    usage; exit 2 ;;
    -*) echo "apply-tool-upgrade: unknown flag '$1'" >&2; usage; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      elif [ -z "$TARGET" ]; then TARGET="$1"
      else echo "apply-tool-upgrade: unexpected extra argument '$1'" >&2; usage; exit 2
      fi ;;
  esac
  shift
done

[ -n "$NAME" ] || { usage; exit 2; }
if [ -n "$TARGET" ]; then
  case "$TARGET" in
    v[0-9]*|[0-9]*) TARGET="${TARGET#v}" ;;
  esac
  # Same version shape as upgrade-rtk.sh's VERSION_RE: major.minor.patch, plus
  # an optional pre-release/build suffix. A bare leading digit ("1foo") does
  # NOT qualify -- it would otherwise reach the comparator as a malformed
  # target.
  if ! [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+[0-9A-Za-z.-]*$ ]]; then
    echo "apply-tool-upgrade: target version '$TARGET' is not a version string" >&2; exit 2
  fi
fi
command -v python3 >/dev/null 2>&1 || {
  echo "apply-tool-upgrade: python3 not on PATH — cannot parse the registry." >&2; exit 2; }
[ -f "$REGISTRY" ] || {
  echo "apply-tool-upgrade: registry not found: $REGISTRY" >&2; exit 2; }

# Read the entry into shell variables. python emits prefixed lines — one ARGV:
# line PER argv element, so an argument containing spaces survives intact. NOT
# NUL-joined: command substitution strips NUL bytes, so that transport silently
# collapses the array. Prefixes are stripped with bash parameter expansion
# rather than sed, because BSD/macOS sed does not understand `\t` in a pattern.
#
# `| tr -d '\r'` is load-bearing, not cosmetic (same guard check-plugin-drift.sh
# uses): python's stdout is in text mode on Windows, so every line comes back
# CRLF-terminated and each value would carry a trailing CR — enough to turn
# `twitter --version` into an argv whose second word is `--version\r`, which the
# tool rejects, which then reads as "not installed". `set -o pipefail` (top of
# file) keeps python's exit code as the pipeline's, so the SKIP/error codes below
# still arrive intact rather than being masked by tr's 0.
entry_out=$(python3 - "$REGISTRY" "$NAME" "$UNATTENDED" <<'PY' | tr -d '\r'
import json, sys
reg_path, name, unattended = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

def die(code, msg):
    sys.stderr.write("apply-tool-upgrade: %s\n" % msg)
    sys.exit(code)

try:
    reg = json.load(open(reg_path, encoding="utf-8"))
except Exception as exc:
    die(2, "could not parse registry %s: %s" % (reg_path, exc))

match = [e for e in reg.get("entries", []) if e.get("name") == name]
if not match:
    die(2, "no registry entry named %r in %s" % (name, reg_path))
if len(match) > 1:
    die(2, "registry has %d entries named %r — names must be unique" % (len(match), name))
e = match[0]

if e.get("kind") != "tag_release" or e.get("mode") != "probe":
    die(2, "entry %r is kind=%s mode=%s — only tag_release/probe names an INSTALLED "
           "tool this script can upgrade" % (name, e.get("kind"), e.get("mode")))

cmd_str, rx = e.get("version_command"), e.get("version_regex")
if not cmd_str or not rx:
    die(2, "entry %r is missing version_command/version_regex" % name)

up = e.get("upgrade")
if not up:
    print("SKIP %s: no upgrade declared — not auto-upgradable, handle manually" % name)
    sys.exit(3)
if not isinstance(up, dict) or not up.get("command"):
    die(2, "entry %r has a malformed upgrade block (need {command, unattended})" % name)
argv = up["command"]
# An argv ARRAY, deliberately: a shell string would need quoting and would give a
# registry entry a way to smuggle in extra commands.
if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
    die(2, "entry %r upgrade.command must be a non-empty array of strings" % name)
# The line-per-element transport below cannot carry an embedded newline, and an
# empty element would be dropped. Neither is legitimate in an upgrade command —
# refuse rather than silently mangle the argv.
for a in argv:
    if a == "" or "\n" in a or "\r" in a:
        die(2, "entry %r upgrade.command has an empty element or one containing a "
               "newline — not supported" % name)
if unattended and up.get("unattended") is not True:
    print("SKIP %s: upgrade.unattended is not true — this entry is operator-triggered "
          "only; run it by hand without --unattended" % name)
    sys.exit(3)

print("VCMD:%s" % cmd_str)
print("VRX:%s" % rx)
for a in argv:
    print("ARGV:%s" % a)
PY
)
entry_rc=$?
if [ "$entry_rc" -ne 0 ]; then
  # SKIP messages are the python side's stdout; errors already went to stderr.
  [ -n "$entry_out" ] && printf '%s\n' "$entry_out"
  exit "$entry_rc"
fi

VERSION_COMMAND=""
VERSION_REGEX=""
UPGRADE_ARGV=()
while IFS= read -r _line; do
  case "$_line" in
    VCMD:*) VERSION_COMMAND="${_line#VCMD:}" ;;
    VRX:*)  VERSION_REGEX="${_line#VRX:}" ;;
    ARGV:*) UPGRADE_ARGV+=("${_line#ARGV:}") ;;
  esac
done <<< "$entry_out"

if [ -z "$VERSION_COMMAND" ] || [ -z "$VERSION_REGEX" ] || [ "${#UPGRADE_ARGV[@]}" -eq 0 ]; then
  echo "apply-tool-upgrade: could not read the registry entry for $NAME" >&2
  exit 2
fi

# Probe the installed version. Mirrors check-plugin-drift.sh's probe: a
# --version that exits non-zero AFTER printing (twitter-cli does this) is fine,
# so parse combined output rather than trusting the exit code.
probe_version() {
  local cmd_arr out
  read -r -a cmd_arr <<< "$VERSION_COMMAND"
  command -v "${cmd_arr[0]}" >/dev/null 2>&1 || return 1
  # Only use `timeout` if it is the GNU/coreutils one (CR glm-4). On a minimal
  # Git-Bash, `command -v timeout` can resolve to Windows' timeout.exe, which is
  # a SLEEP with `/T` syntax, not a command wrapper — it would consume the
  # probe's argv, fail, and make an installed tool read as "not installed"
  # (rc 2). `timeout --help` naming coreutils is the cheap discriminator;
  # anything else falls through to running the probe unbounded, the same
  # graceful-degrade the drift guard uses.
  if command -v timeout >/dev/null 2>&1 && timeout --help 2>&1 | grep -qi 'coreutils\|GNU'; then
    out=$(timeout 20 "${cmd_arr[@]}" 2>&1)
  else
    out=$("${cmd_arr[@]}" 2>&1)
  fi
  printf '%s' "$out" | grep -oE "$VERSION_REGEX" | head -1
}

# Strictly-greater comparison on the leading dotted-numeric run. python, not
# `sort -V`: sort -V is GNU-only and macOS support is already an open thorn
# (HIMMEL-1054 / HIMMEL-1059) — no reason to add a third call site to it.
version_gt() {
  python3 -c '
import re, sys
def key(v):
    m = re.match(r"^v?([0-9]+(?:\.[0-9]+)*)", v)
    return tuple(int(x) for x in m.group(1).split(".")) if m else ()
a, b = key(sys.argv[1]), key(sys.argv[2])
n = max(len(a), len(b))
a += (0,) * (n - len(a)); b += (0,) * (n - len(b))
sys.exit(0 if a > b else 1)
' "$1" "$2"
}

before=$(probe_version)
if [ -z "$before" ]; then
  echo "apply-tool-upgrade: $NAME is not installed (or '$VERSION_COMMAND' yields no parseable version)." >&2
  echo "    This UPGRADES an existing install; it does not bootstrap one. Install it first." >&2
  exit 2
fi

# Already at (or past) the target: say so and run nothing. This is the case that
# makes the target argument worth having — see the verdict block below.
if [ -n "$TARGET" ] && ! version_gt "$TARGET" "$before"; then
  echo "nothing to do: $NAME is already $before (target $TARGET)"
  exit 1
fi

printf 'apply-tool-upgrade: %s installed %s; running:' "$NAME" "$before"
printf ' %s' "${UPGRADE_ARGV[@]}"
printf '\n'

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY $NAME $before -> (upgrade not run)"
  exit 0
fi

if ! command -v "${UPGRADE_ARGV[0]}" >/dev/null 2>&1; then
  echo "apply-tool-upgrade: upgrade command '${UPGRADE_ARGV[0]}' not on PATH — cannot upgrade $NAME." >&2
  exit 2
fi

# Run from the repo root so a repo-relative helper path in the argv resolves.
# Its exit code is recorded but is NOT the verdict — the re-probe below is.
( cd "$REPO_ROOT" && "${UPGRADE_ARGV[@]}" )
cmd_rc=$?

after=$(probe_version)
if [ -z "$after" ]; then
  echo "apply-tool-upgrade: FAILED — after the upgrade, '$VERSION_COMMAND' no longer" >&2
  echo "    reports a parseable version (upgrade command exited rc=$cmd_rc). $NAME was $before." >&2
  echo "    Treat this install as broken and repair it by hand." >&2
  exit 4
fi
if version_gt "$before" "$after"; then
  echo "apply-tool-upgrade: FAILED — $NAME went BACKWARDS, $before -> $after (command exited rc=$cmd_rc)." >&2
  exit 4
fi

if [ "$after" = "$before" ]; then
  # The version did not move. Whether that is FINE or a FAILURE depends on
  # something this script cannot observe on its own: what upstream's latest
  # actually is. "already the newest release" and "the upgrade silently did
  # nothing" look identical from here — both are an rc-0 command and an
  # unchanged version. Guessing either way is wrong: calling it a failure cries
  # wolf every night on a current tool (which is exactly what the first run of
  # this script did to rtk), and calling it success hides a broken upgrader.
  #
  # So: if the caller told us the target, we KNOW — not reaching it is a real
  # failure. If it did not, trust the command's own exit code and say plainly
  # that the claim is unverified.
  if [ -n "$TARGET" ]; then
    echo "apply-tool-upgrade: FAILED — $NAME is still $after, target was $TARGET (command exited rc=$cmd_rc)." >&2
    echo "    An upgrade that exits 0 without reaching the target is not a success:" >&2
    echo "    the resolver may have found nothing, the install may be partial, or a" >&2
    echo "    shim may still point at the old build." >&2
    exit 4
  fi
  if [ "$cmd_rc" -ne 0 ]; then
    echo "apply-tool-upgrade: FAILED — $NAME is still $after and the upgrade command exited rc=$cmd_rc." >&2
    exit 4
  fi
  echo "nothing to do: $NAME is still $before — the upgrade command reported success"
  echo "    with no version change (most likely already the newest release). Pass the"
  echo "    target version to assert that rather than assume it."
  exit 1
fi

if [ -n "$TARGET" ] && version_gt "$TARGET" "$after"; then
  echo "apply-tool-upgrade: FAILED — $NAME moved $before -> $after but the target was $TARGET (command exited rc=$cmd_rc)." >&2
  exit 4
fi

echo "UPGRADE $NAME $before -> $after"
exit 0
