#!/usr/bin/env bash
# test-claude-lane.sh — HIMMEL-4082. Hermetic: no claude launch.
# Pins the HIMMEL_CLAUDE_LANE resolver (scripts/lib/claude-lane.sh) and that the
# headless claude spawn sites honour it with a stubbed launcher.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/scripts/lib/claude-lane.sh"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

[ -r "$LIB" ] || { echo "FAIL - $LIB missing"; echo "pass=0 fail=1"; exit 1; }
# shellcheck source=claude-lane.sh
# shellcheck disable=SC1091
. "$LIB"

resolve() { # <lane|__unset__> -> prints "rc|cmd words"
  local out rc
  if [ "$1" = __unset__ ]; then
    out="$( (unset HIMMEL_CLAUDE_LANE; claude_lane_resolve "$REPO" && echo "${CLAUDE_LANE_CMD[*]}") 2>/dev/null )"; rc=$?
  else
    out="$( (HIMMEL_CLAUDE_LANE="$1"; export HIMMEL_CLAUDE_LANE; claude_lane_resolve "$REPO" && echo "${CLAUDE_LANE_CMD[*]}") 2>/dev/null )"; rc=$?
  fi
  echo "$rc|$out"
}

check "unset = plain claude"        "0|claude" "$(resolve __unset__)"
check "native = plain claude"       "0|claude" "$(resolve native)"
check "empty = plain claude"        "0|claude" "$(resolve '')"
check "openrouter launcher"         "0|$REPO/scripts/claude-openrouter" "$(resolve openrouter)"
check "claudex launcher"            "0|$REPO/scripts/claude-codex" "$(resolve claudex)"
bad="$(resolve bogus)"
check "unknown refuses (rc)"        "2" "${bad%%|*}"
# shellcheck disable=SC2030,SC2031 # the lane var is set in a subshell on purpose
err="$( (HIMMEL_CLAUDE_LANE=bogus; export HIMMEL_CLAUDE_LANE; claude_lane_resolve "$REPO") 2>&1 >/dev/null )"
case "$err" in *bogus*native*openrouter*claudex*) r=ok;; *) r="got: $err";; esac
check "unknown refusal names value + valid lanes" "ok" "$r"

# HIMMEL-4111: claude_lane_egress classifies the REVIEWED repo (not the cwd) and
# refuses a non-native lane when the matrix forbids that backend for its corpus.
W="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-lane.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/phi" "$W/hand/sub" "$W/plain" "$W/vault/.obsidian/x" "$W/cfg"
: > "$W/phi/.salus"
egress() { # <lane|__unset__> <dir> -> prints "rc|CLAUDE_OPENROUTER_CWD|stderr-first-line"
  # shellcheck disable=SC2015,SC2030,SC2031 # unset cannot fail, so the || arm only runs for a real lane
  ( [ "$1" = __unset__ ] && unset HIMMEL_CLAUDE_LANE || export HIMMEL_CLAUDE_LANE="$1"
    unset CLAUDE_OPENROUTER_CWD
    export HANDOVER_DIR="$W/hand" CLAUDE_GLM_CONFIG_DIR="$W/cfg"
    claude_lane_resolve "$REPO" >/dev/null 2>&1
    claude_lane_egress "$2" 2>"$W/egress.err"; rc=$?
    echo "$rc|${CLAUDE_OPENROUTER_CWD:-}|$(head -1 "$W/egress.err")" )
}
r="$(egress __unset__ "$W/phi")";    check "native + salus repo: no gate, no env"   "0||" "$r"
r="$(egress native "$W/hand/sub")";  check "native + handover repo: no gate"        "0||" "$r"
r="$(egress openrouter "$W/phi")";   case "$r" in 3\|\|*salus*) r=ok;; esac
check "openrouter + salus repo refused (names corpus)" ok "$r"
r="$(egress openrouter "$W/vault")"; case "$r" in 3\|\|*luna-personal*) r=ok;; esac
check "openrouter + vault (.obsidian) repo refused"    ok "$r"
r="$(egress claudex "$W/hand/sub")"; case "$r" in 3\|\|*handover-state*) r=ok;; esac
check "claudex + handover-state repo refused (conditional)" ok "$r"
r="$(egress openrouter "$REPO")";    check "openrouter + himmel repo: allowed, launcher cwd = reviewed repo" "0|$REPO|" "$r"
r="$(egress claudex "$REPO")";       check "claudex + himmel repo: allowed"     "0||" "$r"
r="$(egress claudex "$W/plain")";    case "$r" in 3\|\|*"no known corpus"*) r=ok;; esac
check "claudex + unclassified repo refused (matrix default deny)" ok "$r"
r="$(egress openrouter "$W/plain")"; case "$r" in 3\|\|*"no known corpus"*) r=ok;; esac
check "openrouter + unclassified repo refused" ok "$r"
mkdir -p "$W/real/x" "$W/cfg2"; ln -s "$W/real" "$W/link"; echo "$W/link" > "$W/cfg2/phi-roots"
cp "$W/cfg2/phi-roots" "$W/cfg/phi-roots"
r="$(egress openrouter "$W/real/x")"; case "$r" in 3\|\|*salus*) r=ok;; esac
check "phi-roots entry that is a symlink still matches the canonical repo" ok "$r"
printf '/\n' > "$W/cfg/phi-roots"
r="$(egress openrouter "$W/plain")"; case "$r" in 3\|\|*salus*) r=ok;; esac
check "phi-roots entry of / covers every repo" ok "$r"
rm -f "$W/cfg/phi-roots"
# shellcheck disable=SC2030,SC2031 # the vars are set in a subshell on purpose
r="$( ( export HANDOVER_DIR="$W/gone"; export HIMMEL_CLAUDE_LANE=claudex CLAUDE_GLM_CONFIG_DIR="$W/cfg"; claude_lane_egress "$W/plain" 2>&1 >/dev/null ) )"
case "$r" in *handover*fail\ closed*) r=ok;; esac
check "configured but unresolvable handover root refused" ok "$r"
# A HANDOVER_DIR that only a .env supplies (quoted value, or a stale path) is still
# "set": a private copy of the lib reads <copy>/.env, never the real checkout's.
mkdir -p "$W/tree/scripts/lib"
cp "$REPO/scripts/lib/claude-lane.sh" "$REPO/scripts/lib/load-dotenv.sh" "$REPO/scripts/lib/handover-path.sh" "$W/tree/scripts/lib/"
envonly() { # <.env line> -> prints "rc|stderr-first-line" for claudex reviewing the handover fixture
  printf '%s\n' "$1" > "$W/tree/.env"
  # shellcheck disable=SC2031 # the vars are set in a subshell on purpose
  # shellcheck disable=SC2030
  ( unset HANDOVER_DIR LUNA_VAULT LUNA_VAULT_PATH; export HIMMEL_CLAUDE_LANE=claudex CLAUDE_GLM_CONFIG_DIR="$W/cfg"
    # shellcheck disable=SC1091
    . "$W/tree/scripts/lib/claude-lane.sh"
    claude_lane_egress "$W/hand" 2>"$W/egress.err"; rc=$?
    echo "$rc|$(head -1 "$W/egress.err")" )
}
r="$(envonly "HANDOVER_DIR=\"$W/hand\"")"; case "$r" in 3\|*handover*fail\ closed*) r=ok;; esac
check ".env-only quoted HANDOVER_DIR (quotes kept, unresolvable) refused" ok "$r"
r="$(envonly "HANDOVER_DIR=$W/gone")";     case "$r" in 3\|*handover*fail\ closed*) r=ok;; esac
check ".env-only stale HANDOVER_DIR refused" ok "$r"
rm -f "$W/tree/.env"
r="$(egress openrouter "$W/nope")";  case "$r" in 3\|*) r=ok;; esac
check "unresolvable reviewed repo refused (fail closed)" ok "$r"

# HIMMEL-5099: a LUNA_VAULT / LUNA_VAULT_PATH that is set but does not resolve refuses
# (the himmel repo itself is otherwise allowed, so only the vault var can cause the rc 3).
# shellcheck disable=SC2030,SC2031 # the vars are set in a subshell on purpose
vaultegress() { # <lane> <LUNA_VAULT|-> <LUNA_VAULT_PATH|-> -> prints "rc|stderr-first-line"
  ( export HIMMEL_CLAUDE_LANE="$1" HANDOVER_DIR="$W/hand" CLAUDE_GLM_CONFIG_DIR="$W/cfg"
    unset LUNA_VAULT LUNA_VAULT_PATH
    [ "$2" = - ] || export LUNA_VAULT="$2"
    [ "$3" = - ] || export LUNA_VAULT_PATH="$3"
    claude_lane_egress "$REPO" 2>"$W/egress.err"; rc=$?
    echo "$rc|$(head -1 "$W/egress.err")" )
}
r="$(vaultegress claudex "$W/gone" -)";  case "$r" in 3\|*vault*fail\ closed*) r=ok;; esac
check "claudex + unresolvable LUNA_VAULT refused" ok "$r"
r="$(vaultegress openrouter - "$W/gone")"; case "$r" in 3\|*vault*fail\ closed*) r=ok;; esac
check "openrouter + unresolvable LUNA_VAULT_PATH refused" ok "$r"
r="$(vaultegress claudex "$W/plain" "$W/gone")"; case "$r" in 3\|*vault*fail\ closed*) r=ok;; esac
check "resolvable LUNA_VAULT does not mask an unresolvable LUNA_VAULT_PATH" ok "$r"
r="$(vaultegress claudex "$W/plain" "$W/plain")"; check "resolvable vault vars elsewhere: himmel repo still allowed" "0|" "$r"

# HIMMEL-5099: himmel-code means the reviewed repo shares THIS checkout's git common dir.
# A hermetic checkout (lib copy + real guardrails) holds a nested foreign repo and a worktree.
G="$W/gt"; mkdir -p "$G/scripts/lib" "$G/.claude/worktrees" "$G/foreign" "$G/plain-sub"
cp "$REPO/scripts/lib/claude-lane.sh" "$REPO/scripts/lib/load-dotenv.sh" "$REPO/scripts/lib/handover-path.sh" "$REPO/scripts/lib/git-clean.sh" "$G/scripts/lib/"
ln -s "$REPO/scripts/guardrails" "$G/scripts/guardrails"
gitq() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
gitq -C "$G" init -q && : > "$G/f" && gitq -C "$G" add f scripts/lib && gitq -C "$G" commit -q -m init && gitq -C "$G" worktree add -q "$G/.claude/worktrees/wt" -b wt
gitq -C "$G/foreign" init -q
gtegress() { # <lane> <dir> -> prints "rc|stderr-first-line"
  # shellcheck disable=SC2031
  ( export HIMMEL_CLAUDE_LANE="$1" HANDOVER_DIR="$W/hand" CLAUDE_GLM_CONFIG_DIR="$W/cfg"
    unset LUNA_VAULT LUNA_VAULT_PATH
    # shellcheck disable=SC1091
    . "$G/scripts/lib/claude-lane.sh"
    claude_lane_egress "$2" 2>"$W/egress.err"; rc=$?
    echo "$rc|$(head -1 "$W/egress.err")" )
}
for lane in openrouter claudex; do
  r="$(gtegress "$lane" "$G")";                      check "$lane + checkout primary: himmel-code allowed" "0|" "$r"
  r="$(gtegress "$lane" "$G/.claude/worktrees/wt")"; check "$lane + worktree under .claude/worktrees: allowed" "0|" "$r"
  r="$(gtegress "$lane" "$G/plain-sub")";            check "$lane + plain subdir of the checkout: allowed" "0|" "$r"
  r="$(gtegress "$lane" "$G/foreign")";              case "$r" in 3\|*"no known corpus"*) r=ok;; esac
  check "$lane + nested foreign git repo refused" ok "$r"
done

# Spawn-site coverage with stubbed launchers: scripts/lib/test-claude-headless.sh case 17
# and scripts/cr/test-hermes-critic.sh case 8c.

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
