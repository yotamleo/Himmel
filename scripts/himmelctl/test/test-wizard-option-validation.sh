#!/usr/bin/env bash
# test-wizard-option-validation.sh — hermetic tests for himmelctl bin.js's
# per-subcommand option validation (CR fix): every CLI flag is parsed
# GLOBALLY by parseArgs (order-independent — a flag can appear before or
# after its subcommand token), but each subcommand only READS a specific
# subset of them (see cmdInstall/cmdUninstall/cmdStatus/cmdEnsure's own
# args.* reads). Before this fix a misdirected combo like `status --profile`
# or `ensure --json` was silently ACCEPTED — the extra flag parsed fine, was
# simply never consulted, with no signal to the caller that they'd typo'd or
# picked the wrong command. parseArgs now rejects any option outside the
# parsed subcommand's whitelist with exit 2 + a message naming the flag and
# the subcommand.
#
# Rejected-combo cases need ZERO fixture: the validation runs inside
# parseArgs, before ANY manifest/cache/state I/O, so an invalid combo never
# reaches loadManifest()/cachePath() at all.
#
# Covers:
#   a. `status --profile core` -> exit 2, message names --profile + 'status'.
#   b. `status --yes` -> exit 2, message names --yes + 'status'.
#   c. `ensure --json` -> exit 2, message names --json + 'ensure'.
#   d. `install --items a,b` -> exit 2, message names --items + 'install'.
#   e. `uninstall --profile core` -> exit 2, message names --profile +
#      'uninstall'.
#   f. `uninstall --items a` -> exit 2, message names --items + 'uninstall'.
#   g. every OTHER valid combination is preserved: `status --items x --json`
#      and `ensure --items x --profile core --yes --dry-run` both pass
#      validation and reach their subcommand handler (proven by getting the
#      SAME "no himmelctl install profile found" error the handler itself
#      raises for a missing cache — not the option-validation error).
#   h. (CR fix) an entirely unrecognized flag (`--bogus-flag`, not just a
#      valid-flag-wrong-subcommand) now reports via process.exitCode + return
#      (not process.exit()) — same flush hazard already fixed for --profile
#      validation and the top-level .then() handler. Piped output (this
#      whole suite captures via `$(...)`, exactly the exposed case) must
#      show BOTH diagnostic lines, never a truncated single line.
#   i. (CR fix) a flag placed BEFORE the subcommand token (`--json status`,
#      valid for status) passes validation and reaches cmdStatus, same as
#      the post-subcommand form — flags are parsed order-independently.
#   j. (CR fix) an invalid flag placed BEFORE the subcommand token
#      (`--profile core status`, --profile is ensure-only) is rejected with
#      the SAME exit 2 + message as its post-subcommand form (case a) —
#      position never bypasses the per-subcommand whitelist.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# CR fix (hermeticity): every rejected-combo case (a-f, h, j) depends on
# parseArgs's own no-I/O invariant — the validation runs and exits BEFORE
# any cache/state file is ever touched, so today NEITHER HIMMELCTL_CACHE_DIR
# nor HOME actually matters to the outcome. That's exactly the risk: if that
# invariant ever regressed (or the test happened to run in an environment
# where it silently doesn't hold), these cases would fall through to the
# CALLER's real HIMMELCTL_CACHE_DIR/HOME and could read/touch the operator's
# actual ~/.claude/himmel state. Pointed at scratch dirs anyway, same
# discipline as every other suite — pure defense in depth; the assertions
# stay about exit code + message only.
noopCache="$work/noop-cache"; mkdir -p "$noopCache"
noopHome="$work/noop-home"; mkdir -p "$noopHome"
noopCacheW="$(winpath "$noopCache")"

# ── case a: status --profile core -> rejected ───────────────────────────────
set +e
outA=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" status --profile core </dev/null 2>&1); rcA=$?
set -e
[ "$rcA" -eq 2 ] || fail "case a: 'status --profile core' should exit 2 (got rc=$rcA): $outA"
echo "$outA" | grep -qF -- "--profile is not valid with 'status'" \
  || fail "case a: expected a message naming --profile + 'status' (got: $outA)"
echo "ok: case a — 'status --profile' is rejected with exit 2"

# ── case b: status --yes -> rejected ────────────────────────────────────────
set +e
outB=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" status --yes </dev/null 2>&1); rcB=$?
set -e
[ "$rcB" -eq 2 ] || fail "case b: 'status --yes' should exit 2 (got rc=$rcB): $outB"
echo "$outB" | grep -qF -- "--yes is not valid with 'status'" \
  || fail "case b: expected a message naming --yes + 'status' (got: $outB)"
echo "ok: case b — 'status --yes' is rejected with exit 2"

# ── case c: ensure --json -> rejected ───────────────────────────────────────
set +e
outC=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" ensure --json </dev/null 2>&1); rcC=$?
set -e
[ "$rcC" -eq 2 ] || fail "case c: 'ensure --json' should exit 2 (got rc=$rcC): $outC"
echo "$outC" | grep -qF -- "--json is not valid with 'ensure'" \
  || fail "case c: expected a message naming --json + 'ensure' (got: $outC)"
echo "ok: case c — 'ensure --json' is rejected with exit 2"

# ── case d: install --items a,b -> rejected ─────────────────────────────────
set +e
outD=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" install --items a,b </dev/null 2>&1); rcD=$?
set -e
[ "$rcD" -eq 2 ] || fail "case d: 'install --items a,b' should exit 2 (got rc=$rcD): $outD"
echo "$outD" | grep -qF -- "--items is not valid with 'install'" \
  || fail "case d: expected a message naming --items + 'install' (got: $outD)"
echo "ok: case d — 'install --items' is rejected with exit 2"

# ── case e: uninstall --profile core -> rejected ────────────────────────────
set +e
outE=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" uninstall --profile core </dev/null 2>&1); rcE=$?
set -e
[ "$rcE" -eq 2 ] || fail "case e: 'uninstall --profile core' should exit 2 (got rc=$rcE): $outE"
echo "$outE" | grep -qF -- "--profile is not valid with 'uninstall'" \
  || fail "case e: expected a message naming --profile + 'uninstall' (got: $outE)"
echo "ok: case e — 'uninstall --profile' is rejected with exit 2"

# ── case f: uninstall --items a -> rejected ─────────────────────────────────
set +e
outF=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" uninstall --items a </dev/null 2>&1); rcF=$?
set -e
[ "$rcF" -eq 2 ] || fail "case f: 'uninstall --items a' should exit 2 (got rc=$rcF): $outF"
echo "$outF" | grep -qF -- "--items is not valid with 'uninstall'" \
  || fail "case f: expected a message naming --items + 'uninstall' (got: $outF)"
echo "ok: case f — 'uninstall --items' is rejected with exit 2"

# ── case g: valid combos pass validation and reach their handler ───────────
# HIMMELCTL_CACHE_DIR -> an empty scratch dir, so cachePath() never resolves
# to a real profile: both cmdStatus and cmdEnsure raise the SAME "no
# himmelctl install profile found" error as their very first I/O-dependent
# step. Seeing THAT message (not the option-validation error) proves every
# flag in the combo passed validation and control reached the handler.
cacheG="$work/cache-g"; mkdir -p "$cacheG"
# CR fix (CodeRabbit round 20, hermeticity): set an empty scratch HOME (matching
# case i's `homeI` idiom below) — case g used to inherit the CALLER's HOME, so a
# HOME-derived fallback path in cmdStatus/cmdEnsure could touch real user state.
homeG="$work/home-g"; mkdir -p "$homeG"
set +e
outG1=$(HIMMELCTL_CACHE_DIR="$(winpath "$cacheG")" HOME="$homeG" \
  "$node_bin" "$wizard" status --items x --json </dev/null 2>&1); rcG1=$?
set -e
[ "$rcG1" -eq 2 ] || fail "case g: 'status --items x --json' should reach cmdStatus and exit 2 for no profile (got rc=$rcG1): $outG1"
echo "$outG1" | grep -qF 'no himmelctl install profile found' \
  || fail "case g: 'status --items x --json' should pass option validation (got: $outG1)"
if echo "$outG1" | grep -qF 'is not valid with'; then
  fail "case g: 'status --items x --json' incorrectly hit the option-validation error (got: $outG1)"
fi

set +e
outG2=$(HIMMELCTL_CACHE_DIR="$(winpath "$cacheG")" HOME="$homeG" \
  "$node_bin" "$wizard" ensure --items x --profile core --yes --dry-run </dev/null 2>&1); rcG2=$?
set -e
[ "$rcG2" -eq 2 ] || fail "case g: the full valid ensure combo should reach cmdEnsure and exit 2 for no profile (got rc=$rcG2): $outG2"
echo "$outG2" | grep -qF 'no himmelctl install profile found' \
  || fail "case g: the full valid ensure combo should pass option validation (got: $outG2)"
if echo "$outG2" | grep -qF 'is not valid with'; then
  fail "case g: the full valid ensure combo incorrectly hit the option-validation error (got: $outG2)"
fi
echo "ok: case g — 'status --items --json' and every ensure flag together both pass validation and reach their handler"

# ── case h (CR fix): an entirely unrecognized flag reports via
# process.exitCode + return (not process.exit()), so BOTH diagnostic lines
# flush before exit under piped output — never a truncated single line. ────
set +e
outH=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" status --bogus-flag </dev/null 2>&1); rcH=$?
set -e
[ "$rcH" -eq 2 ] || fail "case h: an unrecognized flag should exit 2 (got rc=$rcH): $outH"
echo "$outH" | grep -qF 'unknown argument: --bogus-flag' \
  || fail "case h: expected the 'unknown argument' line (got: $outH)"
echo "$outH" | grep -qF "Run 'himmelctl --help' for usage." \
  || fail "case h: expected the usage-pointer line too — BOTH must flush, not just the first (got: $outH)"
echo "ok: case h — an unrecognized flag exits 2 with BOTH diagnostic lines flushed (no truncation under piped output)"

# ── case i (CR fix): VALID flags placed BEFORE the subcommand token
# (`--items x --json status`) pass validation and reach cmdStatus — same
# outcome as the post-subcommand form (`status --items x --json`), proving
# flags are parsed order-independently, not just tolerated when they happen
# to trail the subcommand. cacheI is an empty scratch dir so cmdStatus's own
# "no himmelctl install profile found" is the FIRST I/O-dependent error it
# can hit — seeing THAT (not the option-validation error) proves both flags
# passed validation. ────────────────────────────────────────────────────────
cacheI="$work/cache-i"; mkdir -p "$cacheI"
homeI="$work/home-i"; mkdir -p "$homeI"
set +e
outI=$(HIMMELCTL_CACHE_DIR="$(winpath "$cacheI")" HOME="$homeI" \
  "$node_bin" "$wizard" --items x --json status </dev/null 2>&1); rcI=$?
set -e
[ "$rcI" -eq 2 ] || fail "case i: '--items x --json status' should reach cmdStatus and exit 2 for no profile (got rc=$rcI): $outI"
echo "$outI" | grep -qF 'no himmelctl install profile found' \
  || fail "case i: '--items x --json status' should pass option validation (got: $outI)"
if echo "$outI" | grep -qF 'is not valid with'; then
  fail "case i: '--items x --json status' incorrectly hit the option-validation error (got: $outI)"
fi
echo "ok: case i — valid flags placed BEFORE the subcommand ('--items x --json status') pass validation and reach cmdStatus"

# ── case j (CR fix): an INVALID flag placed BEFORE the subcommand token
# (`--profile core status` — --profile is ensure-only) is rejected with the
# SAME exit 2 + message as its post-subcommand form (case a) — position
# never bypasses the per-subcommand whitelist. ─────────────────────────────
set +e
outJ=$(HIMMELCTL_CACHE_DIR="$noopCacheW" HOME="$noopHome" "$node_bin" "$wizard" --profile core status </dev/null 2>&1); rcJ=$?
set -e
[ "$rcJ" -eq 2 ] || fail "case j: '--profile core status' should exit 2 (got rc=$rcJ): $outJ"
echo "$outJ" | grep -qF -- "--profile is not valid with 'status'" \
  || fail "case j: expected the same rejection message as the post-subcommand form (got: $outJ)"
echo "ok: case j — an invalid flag placed BEFORE the subcommand ('--profile core status') is rejected exactly like its post-subcommand form"

echo "PASS"
