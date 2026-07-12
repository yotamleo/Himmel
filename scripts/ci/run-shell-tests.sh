#!/usr/bin/env bash
# scripts/ci/run-shell-tests.sh — discover + run himmel's hermetic shell suites.
#
# Runs every `<scan-root>/**/test-*.sh` EXCEPT the suites listed in SKIP_LIST,
# which need the full agent stack (claude / hermes / docker), a live VM, or
# network / git-remote access — none of which exist on a bare CI runner. That
# SKIP_LIST is the ledger of "what we can't test here"; everything else is
# "what we can".
#
# Phased-CI intent (HIMMEL-494): the first runs are a discovery instrument. A
# suite that fails only because of a missing runner capability gets moved into
# SKIP_LIST (with a reason) until the job is green; a suite that fails for a
# real bug stays red. Keep SKIP_LIST minimal and justified.
#
# Usage:
#   scripts/ci/run-shell-tests.sh                        # run all non-skipped suites under scripts/
#   scripts/ci/run-shell-tests.sh [scan-root]            # run under a different root
#   scripts/ci/run-shell-tests.sh --list [scan-root]     # print run/skip plan, run nothing
#   scripts/ci/run-shell-tests.sh --skip-extra <relpath> # add an ad-hoc skip (repeatable)
#
#   Flags may appear before or after the scan-root.
#   scan-root defaults to "scripts" when omitted.
#
# Exit codes: 0 — all run suites passed; 1 — at least one failed.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

# REPO_ROOT is used only to source libs the runner itself needs; it is NOT
# used for discovery. Discovery uses $scan (the positional scan-root arg).
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT" || exit 1

# Per-suite wall-clock cap so a hung suite can't stall the whole job.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-180}"

# Suites that cannot run on a bare runner. One SCAN-ROOT-RELATIVE path per
# entry. Each: "<relpath>   # <reason>". Keep the reason — it documents the gap.
#
# CI policy (HIMMEL-594): CI runs UNIT tests only — no API keys, no secrets, no
# 3rd-party/network (claude / hermes / codex-OAuth / Jira-API). Suites needing
# those are INTEGRATION tests and belong on the VM e2e (host .env keys copied in,
# codex via OAuth), not here. The VM-e2e-with-keys harness + per-skill/plugin
# test reorg are tracked as a follow-up epic; until then these are skipped on CI.
#
# Paths are relative to $scan (default: scripts), so the entry
# "test-install-symmetry-vm.sh" matches scripts/test-install-symmetry-vm.sh
# when the default scan root is used.
SKIP_LIST="
test-install-symmetry-vm.sh          # drives a real VM over SSH
test-luna-upgrade-vm.sh              # drives a real (Ubuntu or Windows) VM over SSH
test-himmel-update.sh                # live git pull + marketplace re-sync
test-himmel-update-hermes.sh         # needs the hermes runtime
hermes/test-invoke.sh                # needs the hermes runtime
gemini/test-invoke.sh                # needs the gemini-cli binary
cr/test-hermes-critic.sh             # integration: needs the hermes runtime (no keys on CI) — VM e2e covers it
handover/test-hop.sh                 # integration: needs a live 'claude' (--print relaunch) — VM e2e covers it
handover/test-resume-armed.sh        # integration: needs the bun runtime + armed-resume flow — VM e2e covers it
luna/test-pipeline-cadence.sh        # integration: drives a live 'claude' (--settings fragment) — VM e2e covers it
test-plugin-test.sh                  # integration: self-bootstraps a plugin's deps over npm/network — VM e2e covers it
"

# extra_skips accumulates paths added via --skip-extra flags.
# Each entry is a newline-terminated scan-root-relative path.
extra_skips=""

# --------------------------------------------------------------------------
# is_skipped <relpath>
# Returns 0 (true = skip) and prints the reason; returns 1 (false = run).
# Checks SKIP_LIST first, then extra_skips.
# --------------------------------------------------------------------------
is_skipped() {
  local needle="$1"
  local _line _path
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _path=${_line%%#*}
    _path=$(printf '%s' "$_path" | tr -d '[:space:]')
    [ -n "$_path" ] || continue
    if [ "$_path" = "$needle" ]; then
      printf '%s' "${_line#*# }"
      return 0
    fi
  done <<EOF
$SKIP_LIST
EOF
  # Also check extra_skips (no inline reason; just the path).
  if [ -n "$extra_skips" ]; then
    while IFS= read -r _path; do
      [ -n "$_path" ] || continue
      if [ "$_path" = "$needle" ]; then
        printf '%s' "skipped via --skip-extra"
        return 0
      fi
    done <<EOF2
$extra_skips
EOF2
  fi
  return 1
}

# --------------------------------------------------------------------------
# Arg parsing — single-pass, position-independent:
#   --list               set list-mode
#   --skip-extra <val>   append to extra_skips
#   first non-flag       scan-root (default: scripts)
# --------------------------------------------------------------------------
list_only=0
scan=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list)
      list_only=1
      shift
      ;;
    --skip-extra)
      if [ "$#" -lt 2 ]; then
        echo "run-shell-tests.sh: --skip-extra requires an argument" >&2
        exit 1
      fi
      extra_skips="${extra_skips}${2}
"
      shift 2
      ;;
    -*)
      echo "run-shell-tests.sh: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$scan" ]; then
        scan="$1"
      else
        echo "run-shell-tests.sh: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Apply default scan root after parsing so a leading --list doesn't collide.
scan="${scan%/}"      # strip any trailing slash so the relpath prefix-strip works
scan="${scan:-scripts}"

# --------------------------------------------------------------------------
# Discover suites via a temp file so counters survive the read-loop
# (piping into while would run in a subshell on some shells).
# --------------------------------------------------------------------------
suites_file=$(mktemp)
trap 'rm -f "$suites_file"' EXIT

find "$scan" -path '*/node_modules' -prune -o -name 'test-*.sh' -print \
  | grep -v '/node_modules/' | sort > "$suites_file"

pass=0 fail=0 skip=0 ran=0
failed_suites=""

while IFS= read -r suite; do
  [ -n "$suite" ] || continue

  # Derive the scan-root-relative path for skip matching.
  # Strip the leading "$scan/" prefix.
  relpath="${suite#"${scan}"/}"

  if reason=$(is_skipped "$relpath"); then
    skip=$((skip + 1))
    printf '[SKIP] %s — %s\n' "$suite" "$reason"
    continue
  fi

  if [ "$list_only" -eq 1 ]; then
    printf '[RUN ] %s\n' "$suite"
    continue
  fi

  log=$(mktemp)
  start=$(date +%s)

  # Guard timeout: use it only when available (not present on all platforms).
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SUITE_TIMEOUT" bash "$suite" >"$log" 2>&1
    rc=$?
  else
    bash "$suite" >"$log" 2>&1
    rc=$?
  fi

  dur=$(( $(date +%s) - start ))
  ran=$((ran + 1))

  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf '[PASS] %s (%ss)\n' "$suite" "$dur"
  else
    fail=$((fail + 1))
    failed_suites="${failed_suites}  ${suite} (rc=${rc})
"
    printf '[FAIL] %s (rc=%s, %ss)\n' "$suite" "$rc" "$dur"
    echo '----- last 100 lines -----'
    tail -n 100 "$log" | sed 's/^/    /'
    echo '--------------------------'
    # Preserve the FULL failed-suite log when FAIL_LOG_DIR is set (CI uploads
    # it as an artifact — HIMMEL-963: tail-only + rm made the failing
    # assertion unrecoverable from Actions logs). Injective escape (_ -> _u,
    # / -> _s) so distinct relpaths like a/b and a_b can't collide.
    if [ -n "${FAIL_LOG_DIR:-}" ]; then
      mkdir -p "$FAIL_LOG_DIR"
      safe_relpath=$(printf '%s' "$relpath" | sed 's/_/_u/g; s#/#_s#g')
      cp "$log" "$FAIL_LOG_DIR/$safe_relpath.log"
    fi
  fi
  rm -f "$log"
done < "$suites_file"

echo
echo '== Summary =='
if [ "$list_only" -eq 1 ]; then
  echo "(--list: nothing executed)"
  exit 0
fi
printf ' PASS: %s\n SKIP: %s\n FAIL: %s\n' "$pass" "$skip" "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'Failed suites:\n%s' "$failed_suites"
  exit 1
fi
echo "OK: all $ran run suites passed ($skip skipped)"
exit 0
