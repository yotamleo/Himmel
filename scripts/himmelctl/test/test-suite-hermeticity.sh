#!/usr/bin/env bash
# test-suite-hermeticity.sh — HIMMEL-2350 structural guard (Console Ruling 38).
#
# WHY: os.homedir() reads USERPROFILE, not HOME, for node.exe children under
# Git Bash on Windows (proven: `HOME=/tmp/fakehome node -e "console.log(require('os').homedir())"`
# still prints the REAL C:\Users\<user>). himmelctl's two on-disk state seams
# (scripts/himmelctl/lib/helpers.js:cacheDir() -> state.json/install-profile.json,
# and scripts/himmelctl/lib/luna-config.js:configPath() -> ~/.himmel/config.json)
# both fall back to os.homedir() when their own env-var overrides
# (HIMMELCTL_CACHE_DIR, HIMMEL_LUNA_CONFIG_PATH) are unset. A suite that only
# sets HOME= for isolation is therefore a NO-OP for any node CHILD it spawns
# on Windows: the child still writes the OPERATOR'S real ~/.claude/himmel/ and
# ~/.himmel/ files.
#
# THIS GUARD WENT GREEN OVER A LIVE LEAK ONCE ALREADY (HIMMEL-2350's own
# incident): every suite already set HIMMELCTL_CACHE_DIR on every
# "$node_bin" "$wizard" invocation the static check_dir() below could see,
# and the operator's real ~/.claude/himmel/install-profile.json still got
# overwritten by a writeCache() call reached through askQuestions() with an
# all-defaulted answer set (profile=starter, lanes=DEFAULT_LANE_IDS=
# [ollama,copilot] at the time — DEFAULT_LANE_IDS is empty as of HIMMEL-2352's
# v1 lane rescope, but the leak mechanism is unchanged; any all-defaulted
# answer set still reaches writeCache()) via a closed/unredirected
# stdin path the static idiom-matcher never enumerated. A pattern check can
# only catch idioms it was told to look for — require()-style invocations,
# .ps1 entry points, and this closed-stdin writeCache() path all missed it in
# turn. So this guard has THREE layers:
#
#   1. check_dir() — static, cheap, LOCALIZES a fault to a file:line when one
#      exists (kept: still useful for suites using the "$node_bin" "$wizard"
#      idiom directly). It ALSO proves winpath is at least reachable in text
#      (sourced or locally defined) for every $(winpath ...) call site it
#      sees — but text presence is not a runtime value; see GUARD LIMITS.
#   2. check_sources_helper() + check_no_local_winpath() — every suite must
#      source _hermetic-home.sh (the SINGLE shared winpath() definition,
#      HIMMEL-2350 item 1: 34 hand-copied local definitions is itself the bug
#      shape — one missing copy is exactly what happened to
#      test-wizard-preflight.sh), and no suite may still carry its own local
#      copy (proving that consolidation actually held, not just that it
#      happened once).
#   3. canary_snapshot/canary_run + check_real_canary() — hashes a THROWAWAY
#      SANDBOX (seeded faithfully from the three real files' current
#      content, never their live paths — codex-1/codex-2 forced this
#      redesign, see check_real_canary()'s own comment) before/after a suite
#      runs and fails on ANY change, including an absent file becoming
#      present. This is idiom-agnostic: it does not care HOW a suite reached
#      the target, only THAT it did. check_real_canary() wraps this around
#      ACTUALLY RUNNING every real suite (opt-in, HERMETICITY_REAL_CANARY=1
#      — see case g(real)(c) below for why it defaults off; the gating is
#      about CI cost now, not risk, since the sandbox never touches the real
#      files at all).
#
# GUARD LIMITS (stated honestly, not implied away — Console Ruling 38): this
# guard, even with all three layers green, does NOT prove every path is
# hermetic. It does not see in-process require() invocations (a suite that
# requires helpers.js/luna-config.js directly instead of spawning bin.js —
# hand-audited separately, not by this file), it does not see .ps1 entry
# points (verified separately, from inside, to reach only fixture stubs), and
#
# check_sources_helper() (codex-4) is a TEXT-PRESENCE check even after being
# widened to catch more HOME= assignment shapes: it cannot see, and by
# construction never will, a suite that spawns a node child with NO home
# override of any kind -- there is nothing in the source text to match
# against. That class is exactly what check_real_canary()'s sandboxed
# ambient environment exists to catch instead, unconditionally, by actually
# running the suite rather than reading its source. A widened pattern here
# localises MORE faults; it does not mean the check sees everything.
#
# winpath()'s own `exit 1` does NOT abort the calling suite under `set -e`
# when winpath is used the way almost every suite uses it -- as a `VAR=$(...)`
# PREFIX to another command (`USERPROFILE="$(winpath ...)" ... "$node_bin"
# "$wizard" ...`), rather than as its own standalone assignment statement.
# Verified empirically on this exact win32/Git-Bash/node24 stack: a failing
# command substitution in assignment-prefix position does not make bash's
# `set -e` treat the enclosing simple command as failed -- the trailing
# command still runs, with that one var resolved to "". This does NOT reopen
# the HIMMEL-2350 leak, because USERPROFILE is the keystone seam by design
# (_hermetic-home.sh's whole premise): an explicitly EMPTY USERPROFILE makes
# node's os.homedir() THROW (uv_os_homedir ENOENT) rather than silently
# falling back to the real profile -- also verified directly on this stack --
# so a dying winpath on the USERPROFILE computation surfaces as a suite-level
# crash (rc!=0, caught by the suite's own `[ "$rc" -eq 0 ] || fail` assertions)
# rather than a silent leak. And HIMMELCTL_CACHE_DIR/HIMMEL_LUNA_CONFIG_PATH
# resolving empty independently still falls back to an os.homedir()-derived
# path that is ALREADY redirected via USERPROFILE, landing inside the fake
# home rather than the operator's real one -- confirmed directly, as long as
# USERPROFILE itself resolved correctly. The one class this does NOT catch:
# a winpath output that is WRONG but non-empty (a silent cygpath
# mistranslation) -- neither an empty check nor a node crash sees that; it
# remains the canary's job, not winpath()'s or check_dir()'s, by design.
#
# it cannot prove a value is non-empty at runtime for any code path neither
# check_dir()'s idiom-matcher nor check_real_canary()'s per-suite run actually
# exercises — that last one is the canary's job by design, not the static
# check's, and check_real_canary() itself is opt-in (case g(real)(c)) rather
# than run on every corpus pass, for cost reasons documented at its call site.
#
# This file is BOTH the guard AND its own test: every check function is
# invocable standalone (for a RED/GREEN comparison against two different
# trees, or to canary-wrap an arbitrary command), and running this file with
# no argument exercises each one against synthetic fixtures — including a
# POSITIVE CONTROL proving the canary itself can detect a real write — before
# asserting PASS on the real, now-fixed scripts/himmelctl/test/ directory.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (same helper every sibling suite in this directory defines,
# HIMMEL-1430): `<producer> | grep -q` under `set -o pipefail` inverts on a
# large match, since grep -q exits on first match and the producer takes
# SIGPIPE writing the remainder, which the pipeline then reports as failed.
# A guard whose own matcher can invert under load is exactly the false-green
# class this ticket exists to kill, so this file uses the here-string form
# throughout instead of `printf ... | grep -q ...`.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
REAL_TEST_DIR="$REPO_ROOT/scripts/himmelctl/test"

# This guard is itself a consumer of the shared winpath() now (check_real_canary
# below needs it to build a Windows-shaped USERPROFILE for its sandbox) -- sourced
# here rather than hand-rolled again, which would recreate the exact 34-copies
# duplication item 1 of this ticket exists to kill. Self-excluded by name from
# check_sources_helper()/check_no_local_winpath() (this is the guard, not a
# suite under test), so sourcing it here does not trip its own checks.
# shellcheck source=_hermetic-home.sh
# shellcheck disable=SC1091
. "$REAL_TEST_DIR/_hermetic-home.sh"

# _sha256 <path> — detected ONCE (not per call): sha256sum on Linux/Git-Bash,
# `shasum -a 256` on stock macOS, which ships no sha256sum at all (codex-3).
if command -v sha256sum >/dev/null 2>&1; then
  _sha256() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  _sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "test-suite-hermeticity.sh: FATAL — neither sha256sum nor shasum found on PATH" >&2
  exit 1
fi

# canary_snapshot <path1> <path2> <path3> — prints one sha256-or-ABSENT token
# per path, one per line. ABSENT is a real, distinct state (never conflated
# with any hash) so a suite that CREATES one of these files on a clean
# machine — the "file didn't exist, guard has nothing to diff" trap Console
# Ruling 38 flagged — is still caught: absent->present is a mismatch, exactly
# like present->changed.
canary_snapshot() {
  local p
  for p in "$@"; do
    if [ -f "$p" ]; then _sha256 "$p"; else echo "ABSENT"; fi
  done
}

# canary_run <path1> <path2> <path3> -- <cmd...> — snapshots the three paths,
# runs <cmd...>, snapshots again, and reports PASS (rc 0, nothing printed) or
# FAIL (rc 1, one "DRIFT <path>: <before> -> <after>" line per changed path).
# Idiom-agnostic by construction: it does not inspect the command's source at
# all, only whether the three real targets moved.
canary_run() {
  local p1="$1" p2="$2" p3="$3"; shift 3
  [ "$1" = "--" ] && shift
  local before after drift=0
  before=$(canary_snapshot "$p1" "$p2" "$p3")
  "$@"
  local rc=$?
  after=$(canary_snapshot "$p1" "$p2" "$p3")
  if [ "$before" != "$after" ]; then
    local paths=("$p1" "$p2" "$p3")
    local i=0
    while [ "$i" -lt 3 ]; do
      local b a
      b=$(printf '%s\n' "$before" | sed -n "$((i+1))p")
      a=$(printf '%s\n' "$after" | sed -n "$((i+1))p")
      if [ "$b" != "$a" ]; then
        echo "DRIFT ${paths[$i]}: $b -> $a"
        drift=1
      fi
      i=$((i+1))
    done
  fi
  [ "$drift" -eq 0 ] && [ "$rc" -eq 0 ]
}

# real_home_dir — the operator's REAL home as a node child would resolve it.
#
# codex-panel round 6. `os.homedir()` on win32 reads USERPROFILE; $HOME is a
# git-bash convenience that can legitimately point elsewhere (git-bash honours
# an inherited HOME before falling back to USERPROFILE). check_real_canary()'s
# operator-file tripwire must therefore watch the USERPROFILE-derived home,
# not $HOME: under the very divergence this ticket exists to catch, a $HOME-
# derived tripwire watches files nothing writes and reports clean through an
# actual escape into the operator's profile -- the same false-green shape as
# the sandbox-watch defect, one level up in the detector itself.
#
# Falls back to $HOME when USERPROFILE is unset (the normal posix case) or
# when cygpath cannot translate it. Deliberately does NOT reuse winpath():
# this is the OPPOSITE direction (windows -> posix), because the paths it
# builds are consumed by bash's own `sha256sum`/`[ -f ]`, not by a node child.
real_home_dir() {
  local up="${USERPROFILE-}"
  if [ -n "$up" ]; then
    case "$(uname -s 2>/dev/null)" in
      MINGW*|MSYS*|CYGWIN*)
        local posix
        posix=$(cygpath -u "$up" 2>/dev/null) || posix=""
        if [ -n "$posix" ]; then
          printf '%s\n' "$posix"
          return 0
        fi
        ;;
    esac
  fi
  printf '%s\n' "$HOME"
}

# check_real_canary <dir> — actually RUNS every *.sh in <dir> (except this
# guard and the shared helper) and asserts none of them write outside a
# THROWAWAY SANDBOX, seeded with a faithful COPY of the three real
# operator-home files' current content (never their live paths).
#
# Two review findings (codex-1, codex-2) killed the earlier live-file design:
#
#   codex-1 (CRITICAL): watching the REAL files and hashing them means a
#   leaky suite's write already landed before the drift is even reported --
#   the canary would have correctly detected the exact incident this ticket
#   exists to prevent, one step too late to prevent it. A guard that reports
#   "your real file is already gone" is not a guard.
#
#   codex-2 (IMPORTANT, rated above codex-1): deriving the watched paths from
#   $HOME (`"$HOME/.himmel/config.json"` etc.) is Ruling 38's own root cause
#   one level up -- os.homedir() on win32 follows USERPROFILE, not HOME, so
#   watching HOME-derived paths misses exactly the divergent-HOME-vs-
#   USERPROFILE condition this whole ticket exists to catch, and would report
#   a false-green while a real leak landed via USERPROFILE instead.
#
# The fix here is the sandbox check_real_canary builds and points BOTH HOME
# and USERPROFILE (and, for belt-and-braces, HIMMELCTL_CACHE_DIR /
# HIMMEL_LUNA_CONFIG_PATH) at, in its OWN ambient environment, before running
# each suite: `HOME=$sandbox USERPROFILE=$(winpath $sandbox) ... bash "$f"`.
# Every case in this directory already overrides these four per-invocation
# (that is what check_dir()/check_sources_helper() verify), so this sandbox
# setting is INERT for a properly-isolated suite -- its own per-case override
# always wins. It only matters for the class no static check can enumerate:
# a code path that spawns node WITHOUT any override of its own, inheriting
# from the ambient environment instead (exactly how the original incident's
# closed-stdin writeCache() path reached the real home). With this sandbox in
# place, THAT class now falls through to the sandbox, not the operator's real
# home -- eliminating the risk codex-1 flagged rather than adding a
# backup/restore step that still has a window where the real file is wrong.
# This also directly resolves codex-2: HOME and USERPROFILE are the SAME
# sandbox dir here, so it no longer matters which one a leaky path reads --
# both resolve to the identical watched location.
#
# The real operator files are only ever READ -- once to seed the sandbox
# faithfully (so a suite that behaves differently depending on whether
# config.json/state.json already exist, or what shape they're in, still sees
# realistic content), and repeatedly (codex-panel round 5, below) as a
# read-only tripwire -- never written, and the sandbox is deleted after.
#
# codex-panel round 5 (IMPORTANT): the sandbox is the EXECUTION environment
# (every suite still runs pointed at it, per codex-1/codex-2 above), but it
# is blind to a suite that ignores its env overrides entirely -- one that
# explicitly resets USERPROFILE back to the real profile, or hardcodes an
# absolute operator-home path instead of using the seams this guard checks.
# Such a suite mutates the REAL files while the sandbox trio reports no
# drift at all: a fail-open in the layer the console designated the actual
# gate. This is NOT a return to the pre-codex-1 live-file design: the
# sandbox stays the execution environment and the primary defense; hashing
# the three real paths before/after each suite is a read-only ADDITION, a
# tripwire that only ever notices a write that already happened via some
# OTHER path, never a mechanism that could itself cause or prevent one. It
# never writes to them, so it carries none of the destructive risk round 1
# objected to (running suites' state changes directly against the live
# files) -- it only reads and hashes, exactly like the once-off seed copy
# already did.
#
# Deliberately ignores each suite's own exit code for PASS/FAIL purposes: a
# suite's PASS/FAIL is scripts/ci/run-shell-tests.sh's job, not this
# function's — conflating "the suite failed for an unrelated reason" with
# "the suite wrote outside its sandbox" would make this check noisy in a way
# that has nothing to do with hermeticity. That reasoning is sound as far as
# it goes, but it does NOT license discarding the exit code entirely: a
# suite that dies before it reaches the code that would write (a missing
# dependency, a winpath() FATAL, any early crash) writes nothing, moves
# nothing, and therefore reads as behaviourally clean — a VACUOUS pass, not
# evidence of hermeticity. This function still never fails the canary over a
# crashed suite (that stays run-shell-tests.sh's job), but it DOES capture
# each suite's rc, counts how many exited non-zero, and names them in a
# REAL-CANARY VACUITY line so a pass over a corpus where most suites crashed
# cannot present as a clean bill of health. codex-panel round 3: a PARTIAL
# crash rate stays a warning-only VACUITY line (rc unaffected) -- but if
# EVERY suite in the corpus crashed, this run produced ZERO hermeticity
# evidence, and rc was previously only ever set by a DRIFT, so an
# all-crashed run would still return SUCCESS having certified nothing. This
# guard was designated "the actual gate"; a gate that reports clean while
# holding no evidence at all is a fail-open, not a lesser case of the
# warning above. When crashed == total (and total > 0), this function now
# returns non-zero instead.
check_real_canary() {
  local dir="$1"
  local sandbox
  sandbox=$(mktemp -d "${TMPDIR:-/tmp}/hermeticity-real-canary.XXXXXX") || return 1
  mkdir -p "$sandbox/.himmel" "$sandbox/.claude/himmel"
  local real_home; real_home="$(real_home_dir)"
  # Seed from the REAL current content -- read-only, never written back.
  [ -f "$real_home/.himmel/config.json" ] && cp "$real_home/.himmel/config.json" "$sandbox/.himmel/config.json"
  [ -f "$real_home/.claude/himmel/state.json" ] && cp "$real_home/.claude/himmel/state.json" "$sandbox/.claude/himmel/state.json"
  [ -f "$real_home/.claude/himmel/install-profile.json" ] && cp "$real_home/.claude/himmel/install-profile.json" "$sandbox/.claude/himmel/install-profile.json"
  local sandbox_win; sandbox_win="$(winpath "$sandbox")"
  local p1="$sandbox/.himmel/config.json"
  local p2="$sandbox/.claude/himmel/state.json"
  local p3="$sandbox/.claude/himmel/install-profile.json"
  # codex-panel round 5: the REAL paths, watched read-only as a tripwire
  # alongside the sandbox trio above -- see the function header for why this
  # is additive, not a reversion to the pre-codex-1 live-file design.
  # codex-panel round 6: resolved via real_home_dir(), NOT $HOME. Deriving
  # them from $HOME reproduced defect #4 one level up, inside the detector:
  # a node child writes wherever USERPROFILE points, so under a guard shell
  # where the two diverge the tripwire watched paths nothing writes and
  # reported clean through an actual escape.
  # codex-panel round 7: the SEED just above (not only these r1..r3
  # tripwire paths) also resolves through real_home_dir() now. Round 6 fixed
  # only the tripwire and missed the seed, which still read from $HOME: under
  # the identical HOME/USERPROFILE divergence, the seed copied from a path
  # nothing writes, so the sandbox got seeded empty or from unrelated
  # content and the canary stopped exercising any content-dependent leak
  # path -- the same $HOME-vs-USERPROFILE mistake, in the same function,
  # missed once already because round 6 only looked at the tripwire.
  local r1="$real_home/.himmel/config.json"
  local r2="$real_home/.claude/himmel/state.json"
  local r3="$real_home/.claude/himmel/install-profile.json"
  local f base before after realBefore realAfter rc=0 suite_rc total=0 crashed=0
  local crashed_names=()
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "_hermetic-home.sh" ] && continue
    [ "$base" = "test-suite-hermeticity.sh" ] && continue
    total=$((total+1))
    before=$(canary_snapshot "$p1" "$p2" "$p3")
    realBefore=$(canary_snapshot "$r1" "$r2" "$r3")
    HOME="$sandbox" USERPROFILE="$sandbox_win" \
      HIMMELCTL_CACHE_DIR="$(winpath "$sandbox/.claude/himmel")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$sandbox/.himmel/config.json")" \
      bash "$f" >/dev/null 2>&1
    suite_rc=$?
    after=$(canary_snapshot "$p1" "$p2" "$p3")
    realAfter=$(canary_snapshot "$r1" "$r2" "$r3")
    if [ "$before" != "$after" ]; then
      echo "REAL-CANARY DRIFT (sandbox) while running $base: one of config.json/state.json/install-profile.json moved inside the sandbox"
      rc=1
    fi
    if [ "$realBefore" != "$realAfter" ]; then
      echo "REAL-CANARY DRIFT (OPERATOR'S REAL FILES) while running $base: one of ~/.himmel/config.json, ~/.claude/himmel/state.json, ~/.claude/himmel/install-profile.json moved -- $base escaped the sandbox and wrote to the operator's real home (caught read-only, never watched via a write)"
      rc=1
    fi
    if [ "$suite_rc" -ne 0 ]; then
      crashed=$((crashed+1))
      crashed_names+=("$base")
    fi
  done
  if [ "$crashed" -gt 0 ]; then
    echo "REAL-CANARY VACUITY: $crashed/$total suite(s) exited non-zero inside the sandbox and never reached whatever code would have written -- a suite that crashes early yields NO hermeticity evidence for the code it never ran, the same 'stayed clean' shape as a suite that genuinely never writes. Not counted as a failure here (suite PASS/FAIL is run-shell-tests.sh's job), but a canary PASS over this corpus does not vouch for these: ${crashed_names[*]}"
    # codex-panel round 3: a partial crash rate stays a warning (this canary
    # does not exist to police unrelated suite failures), but if EVERY suite
    # crashed, this run produced ZERO hermeticity evidence -- rc was only
    # ever set by a DRIFT, so an all-crashed corpus would return 0 (SUCCESS)
    # having certified nothing. That is a fail-open, the exact "a zero isn't
    # evidence without a positive control" trap this whole ticket is about.
    # Refuse to certify instead.
    if [ "$total" -gt 0 ] && [ "$crashed" -eq "$total" ]; then
      echo "REAL-CANARY NO EVIDENCE: all $total/$total suite(s) crashed before writing anything -- refusing to report PASS over zero evidence"
      rc=1
    fi
  fi
  rm -rf "$sandbox"
  return "$rc"
}

# check_sources_helper <dir> — every *.sh in <dir> that establishes a fake
# HOME (a signal a suite means to isolate a node child) must source
# _hermetic-home.sh. STATED PLAINLY: _hermetic-home.sh does NOT itself set
# USERPROFILE or close os.homedir() at the source -- it defines exactly one
# thing, the shared winpath() function (see its own header). What sourcing it
# actually buys a suite is winpath()'s FAIL-LOUD behaviour: a missing source
# line means winpath is undefined and the suite dies on first use ("command
# not found") instead of a stray hand-rolled copy silently resolving to ""
# (the "set but empty" leak shape check_dir()'s own comment above documents).
# Every suite still has to set USERPROFILE itself, per invocation, using
# winpath -- that requirement is check_dir()'s job (the has_home/
# has_userprofile check above), not this function's. This replaces trying to
# pattern-match every invocation idiom (bin.js subprocess, require(), .ps1)
# with checking for the ONE line that, once present, gives all of them the
# same fail-loud winpath().
#
# codex-4 (IMPORTANT): the original pattern matched only the literal `HOME="`
# text -- a THIRD repetition of presence-of-a-narrow-pattern read as
# coverage, after presence-of-assignment (check_dir()) and presence-of-a-
# source-line (this same function, before item 1's fix). Widened to also
# catch `HOME=$x` (unquoted), `HOME='...'` (single-quoted), `env HOME=...`,
# and `export HOME=...` -- every assignment SHAPE this codebase's suites
# actually use or plausibly could.
#
# STATED PLAINLY, per codex-4: even widened, this is still a TEXT-PRESENCE
# check, not a runtime check, and it CANNOT see a suite that spawns a node
# child with NO home override of any kind -- nothing to grep for when there
# is nothing there. That class is invisible to this function BY
# CONSTRUCTION, not by an enumeration gap this file's authors could close
# with a cleverer regex. It is exactly the class check_real_canary()'s
# sandboxed ambient environment exists to catch instead: unconditionally, by
# running the suite for real, not by pattern-matching its source text. Do not
# read a widened pattern here as completeness -- this function localises
# faults for the idioms it recognises; the canary is the actual gate.
#
# codex-panel round 3: the old second grep (`grep -q '_hermetic-home\.sh'`) is
# a bare substring search over the WHOLE FILE -- a suite that fakes HOME and
# merely MENTIONS the helper (an explanatory comment, a heredoc, an error
# string) passes without ever sourcing it. Not adversarial: writing "# see
# _hermetic-home.sh" while forgetting the actual `.`/`source` line is exactly
# how this happens. Fixed to match an actual source STATEMENT -- `.` or
# `source` at the start of a line (whitespace-led) -- not a mention anywhere.
check_sources_helper() {
  local dir="$1"
  local f base missing=()
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "_hermetic-home.sh" ] && continue
    [ "$base" = "test-suite-hermeticity.sh" ] && continue
    if grep -qE '(^|[^A-Za-z_])HOME=' "$f" && ! grep -qE '^[[:space:]]*(\.|source)[[:space:]]+.*_hermetic-home\.sh' "$f"; then
      missing+=("$base")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "MISSING _hermetic-home.sh source line: ${missing[*]}"
    return 1
  fi
  return 0
}

# check_no_local_winpath <dir> — every *.sh in <dir> (except this guard and
# the shared helper) must NOT define its own winpath() function any more. A
# surviving local copy means the HIMMEL-2350 item-1 consolidation (34
# hand-copied definitions -> one, in _hermetic-home.sh) did not fully hold —
# this is the STRICT positive proof of that, distinct from check_dir()'s
# permissive text-presence check below (which accepts either a source line or
# a local definition, since it also has to judge synthetic fixtures written
# in the old style).
check_no_local_winpath() {
  local dir="$1"
  local f base offenders=()
  for f in "$dir"/*.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    [ "$base" = "_hermetic-home.sh" ] && continue
    # Excluded BY NAME, deliberately, not by directory-scan coincidence: this
    # guard's own case-b fixture (above) embeds a literal
    # `winpath() { printf '%s' "$1"; }` line inside a heredoc as SYNTHETIC
    # TEST DATA (the old-style shape check_dir() must still tolerate) -- it
    # is prose, never a real local definition this suite's own directory
    # relies on, so it must never be mistaken for the 34th genuine copy.
    [ "$base" = "test-suite-hermeticity.sh" ] && continue
    if grep -qE '^winpath[[:space:]]*\(\)' "$f"; then
      offenders+=("$base")
    fi
  done
  if [ "${#offenders[@]}" -gt 0 ]; then
    echo "LOCAL WINPATH STILL DEFINED (consolidation incomplete): ${offenders[*]}"
    return 1
  fi
  return 0
}

# check_dir <dir> — scans <dir>/*.sh, prints one "MISSING <vars> in
# <path>:<line>: <snippet>" line per violating invocation block, and exits
# 1 if any were found (0 otherwise). This is the actual guard: run it
# standalone (`test-suite-hermeticity.sh [dir]`, default = this script's own
# directory) to compare a RED tree against a GREEN one with the SAME code.
check_dir() {
  local dir="$1"
  python3 - "$dir" << 'PYEOF'
import re, sys, glob, os

target = sys.argv[1]
violations_total = 0
checked = 0
offenders = set()

for path in sorted(glob.glob(os.path.join(target, '*.sh'))):
    # Self-exclude: this guard's own docstring and embedded fixture heredocs
    # (case a/b/c below) deliberately CONTAIN the "$node_bin" "$wizard" idiom
    # as example/fixture text, not a real invocation of anything -- scanning
    # this file would be checking prose, not code.
    if os.path.basename(path) in ('test-suite-hermeticity.sh', '_hermetic-home.sh'):
        continue
    checked += 1
    with open(path, encoding='utf-8', errors='replace') as f:
        raw_lines = f.readlines()
    full_text = ''.join(raw_lines)

    # PRESENCE-OF-ASSIGNMENT-TEXT IS NOT PROOF OF A NON-EMPTY RUNTIME VALUE
    # (Console Ruling 38, live incident): cacheDir()/configPath() are both
    # `process.env.X || <real homedir path>`, and an empty string is falsy in
    # JS, so `HIMMELCTL_CACHE_DIR="$(winpath ...)"` that resolves to "" is
    # INDISTINGUISHABLE, to this grep-based check, from one that resolves
    # correctly -- the guard went green over exactly this shape once already.
    # This function can only prove the assignment TEXT exists; it cannot
    # prove the VALUE is non-empty at runtime (that needs check_real_canary(),
    # or hermetic assertions inside winpath() itself -- see
    # _hermetic-home.sh). One cheap, sound thing IS checkable here without
    # executing anything: every value in this directory's convention is
    # `$(winpath "...")`, and winpath must be a defined shell FUNCTION for
    # that to ever produce a non-empty result. Post-HIMMEL-2350-consolidation
    # (item 1), every real suite gets winpath by SOURCING _hermetic-home.sh
    # (the single shared definition) rather than carrying its own local copy
    # -- 34 hand-copied definitions was itself the bug shape, since one file
    # simply not getting its copy is exactly what happened to
    # test-wizard-preflight.sh. A file that uses $(winpath ...) but neither
    # sources that helper NOR still carries an old-style local definition has
    # NO winpath function in scope at all -- every computed
    # HIMMELCTL_CACHE_DIR/HIMMEL_LUNA_CONFIG_PATH/USERPROFILE in it is empty
    # at runtime regardless of what the source text says. (See also
    # check_no_local_winpath(), which asserts the STRICTER positive that no
    # suite still carries its own copy at all -- this check stays permissive,
    # accepting either shape, because it also has to judge synthetic fixtures
    # written in the old, pre-consolidation style.)
    # codex-panel round 5: same mention-vs-source bug fixed in
    # check_sources_helper() (round 3) survived here as a SECOND, still-bare
    # substring check -- a comment or heredoc merely mentioning
    # _hermetic-home.sh satisfied it without an actual source line. Anchored
    # the same way: a `.`/`source` statement at the start of a line, not a
    # substring anywhere in the file.
    _sources_helper = re.search(r'^[ \t]*(\.|source)[ \t]+.*_hermetic-home\.sh', full_text, re.M) is not None
    _has_local_winpath = re.search(r'^winpath\(\)', full_text, re.M) is not None
    if '$(winpath ' in full_text and not _sources_helper and not _has_local_winpath:
        violations_total += 1
        offenders.add(os.path.basename(path))
        print(f'WINPATH-UNDEFINED in {path}: uses $(winpath ...) but neither sources '
              f'_hermetic-home.sh nor defines its own local winpath() -- every value computed '
              f'with it resolves EMPTY at runtime (silent fallthrough to the operator\'s real '
              f'home; this check cannot see a value, only text)')

    groups = []
    i = 0
    n = len(raw_lines)
    while i < n:
        start = i
        while raw_lines[i].rstrip('\n').endswith('\\') and i + 1 < n:
            i += 1
        groups.append((start, i + 1))
        i += 1

    for (start, end) in groups:
        block = raw_lines[start:end]
        text = ''.join(block)
        # Only a REAL subprocess invocation of bin.js counts -- "$node_bin"
        # immediately followed by "$wizard" is the idiom every suite in this
        # directory uses to spawn it; a bare "$wizard" mention (a
        # file-existence check, or a static grep/awk/cat over bin.js's own
        # source text) is not an invocation and is correctly excluded (its
        # content never runs).
        if not re.search(r'"\$node_bin"\s+"\$wizard"', text):
            continue
        # USERPROFILE is the keystone seam (os.homedir() follows it, not HOME,
        # on win32) -- required alongside the two HIMMELCTL_* vars, but only
        # for a block that is ITSELF faking a HOME: a block with no HOME
        # override at all isn't attempting home-directory isolation in the
        # first place (several real suites in this directory pin every
        # state-touching path explicitly -- CLAUDE_USER_SETTINGS,
        # HIMMELCTL_CACHE_DIR, HIMMEL_LUNA_CONFIG_PATH -- and never consult
        # os.homedir() at all, so there is nothing for USERPROFILE to guard
        # there; verified empirically against this directory's real corpus
        # before landing this condition). A block that DOES fake HOME but
        # omits USERPROFILE is exactly the codex-panel gap this check closes:
        # it would pass the two HIMMELCTL_* checks and still leak any OTHER
        # os.homedir() consumer to the operator's real home.
        has_home = re.search(r'(^|[^A-Za-z_])HOME=', text) is not None
        has_userprofile = 'USERPROFILE=' in text
        has_cache = 'HIMMELCTL_CACHE_DIR=' in text
        has_luna = 'HIMMEL_LUNA_CONFIG_PATH=' in text
        missing = []
        if has_home and not has_userprofile:
            missing.append('USERPROFILE')
        if not has_cache:
            missing.append('HIMMELCTL_CACHE_DIR')
        if not has_luna:
            missing.append('HIMMEL_LUNA_CONFIG_PATH')
        if not missing:
            continue
        violations_total += 1
        offenders.add(os.path.basename(path))
        print(f'MISSING {"+".join(missing)} in {path}:{start+1}: {block[0].strip()[:110]}')

print('---')
print(f'hermeticity check: {checked} suites scanned in {target}, '
      f'{len(offenders)} with uncovered bin.js invocations ({violations_total} invocation(s))')
if offenders:
    print('OFFENDING SUITES: ' + ' '.join(sorted(offenders)))
    sys.exit(1)
PYEOF
}

# When invoked directly with an explicit directory argument, just run the
# check and propagate its exit code -- this is the RED/GREEN comparison
# entry point (`test-suite-hermeticity.sh /path/to/pre-fix/copy`).
if [ "${1-}" != "" ]; then
  check_dir "$1"
  exit $?
fi

# ── Suite mode: no argument -- exercise the checker itself, then assert it ──
fail() { echo "FAIL: $*" >&2; exit 1; }

# case h below actually spawns node (to prove check_real_canary()'s sandbox
# catches a real os.homedir() write), same as every sibling suite here.
command -v node >/dev/null 2>&1 || fail "node required"

work=$(mktemp -d "${TMPDIR:-/tmp}/suite-hermeticity-selftest.XXXXXX") || fail "mktemp -d failed"
trap 'rm -rf "$work"' EXIT

# ── case a (POSITIVE CONTROL): a deliberately non-isolated fixture must FAIL ─
mkdir -p "$work/bad"
cat > "$work/bad/test-fake-noniso.sh" << 'EOF'
#!/usr/bin/env bash
# Deliberately non-isolated: HOME= alone, no HIMMELCTL_CACHE_DIR or
# HIMMEL_LUNA_CONFIG_PATH -- the exact no-op-on-Windows pattern this guard
# exists to catch.
wizard="$repo_root/scripts/himmelctl/bin.js"
out=$(PATH="$c" HOME="$h" USERPROFILE="$(winpath "$h")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
EOF
set +e
badOut=$(check_dir "$work/bad" 2>&1); badRc=$?
set -e
[ "$badRc" -ne 0 ] \
  || fail "case a: a deliberately non-isolated fixture must FAIL the check (got rc=0): $badOut"
grepq "$badOut" 'MISSING HIMMELCTL_CACHE_DIR+HIMMEL_LUNA_CONFIG_PATH' \
  || fail "case a: expected fixture to be flagged for BOTH missing vars: $badOut"
echo "ok: case a — positive control: a non-isolated bin.js invocation IS flagged"

# ── case a2 (POSITIVE CONTROL, codex-panel finding 1): a bin.js invocation
# that fakes HOME and sets BOTH HIMMELCTL_* vars, but omits USERPROFILE --
# the keystone seam os.homedir() actually follows on win32 -- must still be
# FAIL. Sources the shared helper (so this isn't also flagged as
# WINPATH-UNDEFINED, which would confound the assertion below): the point is
# specifically that the two pinned seams being covered is NOT sufficient by
# itself once a suite is faking HOME.
mkdir -p "$work/nouserprofile"
cat > "$work/nouserprofile/test-fake-nouserprofile.sh" << 'EOF'
#!/usr/bin/env bash
# Fakes HOME, sets both HIMMELCTL_CACHE_DIR and HIMMEL_LUNA_CONFIG_PATH --
# but never sets USERPROFILE. Any OTHER os.homedir() consumer this
# invocation's code path reaches (not routed through the two pinned seams)
# still resolves the operator's REAL home.
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
out=$(PATH="$c" HOME="$h" HIMMELCTL_CACHE_DIR="$(winpath "$h.cache")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h.cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
EOF
set +e
noupOut=$(check_dir "$work/nouserprofile" 2>&1); noupRc=$?
set -e
[ "$noupRc" -ne 0 ] \
  || fail "case a2: a HOME-faking bin.js invocation missing USERPROFILE must FAIL the check (got rc=0): $noupOut"
grepq "$noupOut" -F 'MISSING USERPROFILE' \
  || fail "case a2: expected a MISSING USERPROFILE finding (got: $noupOut)"
echo "ok: case a2 — positive control: a HOME-faking bin.js invocation missing USERPROFILE IS flagged even with both HIMMELCTL_* vars set -- USERPROFILE is the keystone seam"

# ── case b (negative control): a properly isolated fixture must PASS ────────
mkdir -p "$work/good"
cat > "$work/good/test-fake-iso.sh" << 'EOF'
#!/usr/bin/env bash
# Properly isolated: both seams redirected into the suite's own work dir,
# AND winpath is actually defined (unlike case c2's deliberate omission) --
# the OLD-style local definition, still a valid shape for check_dir() alone.
winpath() { printf '%s' "$1"; }
wizard="$repo_root/scripts/himmelctl/bin.js"
out=$(PATH="$c" HOME="$h" USERPROFILE="$(winpath "$h")" HIMMELCTL_CACHE_DIR="$(winpath "$h.cache")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h.cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
EOF
set +e
goodOut=$(check_dir "$work/good" 2>&1); goodRc=$?
set -e
[ "$goodRc" -eq 0 ] \
  || fail "case b: a properly isolated fixture must PASS (got rc=$goodRc): $goodOut"
echo "ok: case b — negative control: a fully-isolated bin.js invocation is NOT flagged"

# ── case b2 (negative control, the CURRENT real-world shape): a suite that
# gets winpath by SOURCING _hermetic-home.sh (no local copy of its own) must
# also PASS check_dir() -- this is what every real suite looks like after the
# HIMMEL-2350 item-1 consolidation.
mkdir -p "$work/good2"
cat > "$work/good2/test-fake-iso-sourced.sh" << 'EOF'
#!/usr/bin/env bash
# Properly isolated via the SHARED winpath() (sourced, not locally defined) --
# the post-consolidation shape every real suite now uses.
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
out=$(PATH="$c" HOME="$h" USERPROFILE="$(winpath "$h")" HIMMELCTL_CACHE_DIR="$(winpath "$h.cache")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h.cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
EOF
set +e
good2Out=$(check_dir "$work/good2" 2>&1); good2Rc=$?
set -e
[ "$good2Rc" -eq 0 ] \
  || fail "case b2: a suite sourcing _hermetic-home.sh (no local winpath()) must PASS check_dir() (got rc=$good2Rc): $good2Out"
echo "ok: case b2 — negative control: sourcing the shared helper (no local winpath()) satisfies check_dir(), the post-consolidation shape"

# ── case c: a directory with no bin.js invocations at all trivially passes ──
mkdir -p "$work/empty"
cat > "$work/empty/test-fake-noinvoke.sh" << 'EOF'
#!/usr/bin/env bash
# Never spawns bin.js -- just a static reference (file-existence check),
# which must NOT be mistaken for an invocation.
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
EOF
set +e
emptyOut=$(check_dir "$work/empty" 2>&1); emptyRc=$?
set -e
[ "$emptyRc" -eq 0 ] \
  || fail "case c: a suite that never spawns bin.js must not be flagged (got rc=$emptyRc): $emptyOut"
echo "ok: case c — a bare \$wizard reference (existence check) is not mistaken for an invocation"

# ── case c2 (POSITIVE CONTROL): $(winpath ...) used but neither sourced nor
# locally defined must FAIL, even though the assignment TEXT looks complete --
# the exact test-wizard-preflight.sh shape (Console Ruling 38: presence-of-text
# is not proof of a non-empty runtime value).
mkdir -p "$work/nowinpath"
cat > "$work/nowinpath/test-fake-nowinpath.sh" << 'EOF'
#!/usr/bin/env bash
# Looks fully covered by check_dir()'s text-presence check -- both vars are
# assigned -- but winpath is never defined or sourced, so both resolve empty
# at runtime.
wizard="$repo_root/scripts/himmelctl/bin.js"
out=$(PATH="$c" HOME="$h" HIMMELCTL_CACHE_DIR="$(winpath "$h.cache")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$h.cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --dry-run </dev/null 2>&1); rc=$?
EOF
set +e
nowpOut=$(check_dir "$work/nowinpath" 2>&1); nowpRc=$?
set -e
[ "$nowpRc" -ne 0 ] \
  || fail "case c2: a file using \$(winpath ...) with no local winpath() and no source line must FAIL even with both vars textually present (got rc=0): $nowpOut"
grepq "$nowpOut" 'WINPATH-UNDEFINED' \
  || fail "case c2: expected a WINPATH-UNDEFINED finding (got: $nowpOut)"
echo "ok: case c2 — positive control: \$(winpath ...) with no defined/sourced winpath() is flagged even though both vars are textually present"

# ── case d (the acceptance criterion): the REAL, fixed tree must PASS ───────
set +e
realOut=$(check_dir "$REAL_TEST_DIR" 2>&1); realRc=$?
set -e
[ "$realRc" -eq 0 ] \
  || fail "case d: $REAL_TEST_DIR has uncovered bin.js invocations (run \`test-suite-hermeticity.sh $REAL_TEST_DIR\` for details):
$realOut"
echo "ok: case d — every scripts/himmelctl/test/*.sh bin.js invocation sets both HIMMELCTL_CACHE_DIR and HIMMEL_LUNA_CONFIG_PATH"

# ── case e (POSITIVE CONTROL, the canary): it must catch a write check_dir()
# is blind to. Simulates the actual HIMMEL-2350 incident shape -- a script
# that writes the "real" file directly (no bin.js, no HOME=, nothing
# check_dir()'s idiom-matcher could ever see) -- against SYNTHETIC stand-in
# paths (never the operator's real files) so the canary logic itself is
# proven without any risk. check_real_canary() below reuses this exact same
# mechanism against the three REAL files, so this positive control also
# stands as its proof that the mechanism can fire.
fakeReal="$work/canary-real"; mkdir -p "$fakeReal"
p1="$fakeReal/config.json" p2="$fakeReal/state.json" p3="$fakeReal/install-profile.json"
echo '{"seed":true}' > "$p1"
echo '{"seed":true}' > "$p2"
# p3 starts ABSENT -- proves absent->present is caught too (Console Ruling
# 38 refinement (b): a suite CREATING one of these files on a clean machine
# is the same bug as one that overwrites an existing one).
leaky_suite() { echo '{"leaked":"fixture-answer-set"}' > "$p3"; }
set +e
canaryOut=$(canary_run "$p1" "$p2" "$p3" -- leaky_suite 2>&1); canaryRc=$?
set -e
[ "$canaryRc" -ne 0 ] \
  || fail "case e: the canary must FAIL when a targeted file transitions absent->present (got rc=0)"
grepq "$canaryOut" -F "DRIFT $p3: ABSENT ->" \
  || fail "case e: expected a DRIFT line naming $p3's absent->present transition (got: $canaryOut)"
grepq "$canaryOut" -F "DRIFT $p1" \
  && fail "case e: p1 was never touched by leaky_suite -- must not be reported as drifted (got: $canaryOut)"
echo "ok: case e — positive control: the canary catches a write check_dir()'s idiom-matcher cannot see, including absent->present"

# ── case f (negative control): the canary stays silent when nothing moves ──
clean_suite() { :; }
set +e
canaryCleanOut=$(canary_run "$p1" "$p2" "$p3" -- clean_suite 2>&1); canaryCleanRc=$?
set -e
[ "$canaryCleanRc" -eq 0 ] \
  || fail "case f: the canary must PASS when nothing changed (got rc=$canaryCleanRc): $canaryCleanOut"
echo "ok: case f — negative control: the canary is silent when the three targets don't move"

# ── case g: every suite that fakes a HOME must source _hermetic-home.sh ────
mkdir -p "$work/nosrc"
cat > "$work/nosrc/test-fake-nosource.sh" << 'EOF'
#!/usr/bin/env bash
# Sets a fake HOME but never sources the shared hermetic-env helper --
# USERPROFILE stays real, so os.homedir() in any node child this suite
# spawns is unprotected regardless of what HIMMELCTL_CACHE_DIR/
# HIMMEL_LUNA_CONFIG_PATH say.
h="$(mktemp -d "${TMPDIR:-/tmp}/nosource-fixture.XXXXXX")" || exit 1
out=$(HOME="$h" node -e "console.log(1)")
EOF
set +e
nosrcOut=$(check_sources_helper "$work/nosrc" 2>&1); nosrcRc=$?
set -e
[ "$nosrcRc" -ne 0 ] \
  || fail "case g: a suite faking HOME without sourcing the helper must FAIL (got rc=0): $nosrcOut"
echo "ok: case g — a suite that fakes HOME without sourcing _hermetic-home.sh is flagged"

# ── case g2 (POSITIVE CONTROL): a suite that STILL defines its own winpath()
# must be flagged by check_no_local_winpath(), even though it also sources
# the helper -- a leftover local copy is exactly the "consolidation didn't
# fully hold" shape item 1 of Console Ruling 38 exists to prevent.
mkdir -p "$work/dupwinpath"
cat > "$work/dupwinpath/test-fake-dupwinpath.sh" << 'EOF'
#!/usr/bin/env bash
# Sources the shared helper AND still carries its own local winpath() --
# the exact "consolidation incomplete" shape check_no_local_winpath() exists
# to catch.
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
winpath() { printf '%s' "$1"; }
EOF
set +e
dupOut=$(check_no_local_winpath "$work/dupwinpath" 2>&1); dupRc=$?
set -e
[ "$dupRc" -ne 0 ] \
  || fail "case g2: a suite still defining its own winpath() must FAIL (got rc=0)"
grepq "$dupOut" -F 'test-fake-dupwinpath.sh' \
  || fail "case g2: expected the offending file named: $dupOut"
echo "ok: case g2 — positive control: a suite that still defines its own winpath() (consolidation incomplete) is flagged"

# ── case g3 (POSITIVE CONTROL, codex-panel round 3): a suite that fakes HOME
# and only MENTIONS _hermetic-home.sh -- in a comment, never in an actual
# source statement -- must still FAIL. The old check was a bare substring
# search over the whole file, so a comment like "# see _hermetic-home.sh"
# satisfied it without ever sourcing anything. This is the control that
# proves the anchored `.`/`source`-line match actually replaced that, rather
# than just moving the same text-presence trap somewhere else.
mkdir -p "$work/mentiononly"
cat > "$work/mentiononly/test-fake-mention-only.sh" << 'EOF'
#!/usr/bin/env bash
# NOTE: winpath() comes from _hermetic-home.sh in this directory -- see that
# file for details. (This comment is the ONLY mention in this fixture; there
# is no actual `.`/`source` line below.)
h="$(mktemp -d "${TMPDIR:-/tmp}/mention-only-fixture.XXXXXX")" || exit 1
out=$(HOME="$h" node -e "console.log(1)")
EOF
set +e
mentionOut=$(check_sources_helper "$work/mentiononly" 2>&1); mentionRc=$?
set -e
[ "$mentionRc" -ne 0 ] \
  || fail "case g3: a suite faking HOME with only a COMMENT mentioning _hermetic-home.sh (no actual source line) must FAIL (got rc=0): $mentionOut"
grepq "$mentionOut" -F 'test-fake-mention-only.sh' \
  || fail "case g3: expected the offending file named: $mentionOut"
echo "ok: case g3 — positive control: a suite that fakes HOME and only MENTIONS the helper in a comment (never sources it) is flagged"

# ── case h (POSITIVE CONTROL, codex-2): check_real_canary() must still fire
# when HOME and USERPROFILE DIVERGE -- the exact condition Console Ruling 38's
# whole premise rests on (os.homedir() follows USERPROFILE, not HOME, on
# win32). This fixture sets HOME to a throwaway dir but deliberately leaves
# USERPROFILE UNSET, inheriting whatever check_real_canary()'s own ambient
# environment provides for that seam -- which, after codex-1/codex-2's
# redesign, is the SANDBOX check_real_canary() builds, never the operator's
# real profile. The fixture's node child writes cacheDir()'s target directly
# via os.homedir(), simulating exactly the code path the original incident
# took (a seam that resolves via os.homedir() rather than an explicit
# override). Runs entirely against a throwaway directory; check_real_canary()
# only ever touches its own sandbox, never the real operator files.
#
# codex-panel finding 2: check_real_canary() discarded every suite's rc, so a
# suite that crashed before writing anything read as behaviourally clean --
# a vacuous pass. This directory also carries test-fake-crashes.sh, which
# exits 1 before touching anything, to prove the fix: the canary must still
# name it in a REAL-CANARY VACUITY line (not silently count it as evidence)
# while still failing overall for the unrelated reason (the leaky sibling's
# DRIFT) -- proving the vacuity report doesn't get swallowed by, or swallow,
# the real DRIFT finding.
mkdir -p "$work/divergent"
cat > "$work/divergent/test-fake-divergent.sh" << 'EOF'
#!/usr/bin/env bash
# Sets HOME but deliberately never touches USERPROFILE -- the HOME/
# USERPROFILE divergence this case exists to prove the canary still catches.
node -e "
const fs = require('fs');
const path = require('path');
const os = require('os');
const dir = path.join(os.homedir(), '.claude', 'himmel');
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'install-profile.json'), JSON.stringify({leaked:true}));
"
EOF
cat > "$work/divergent/test-fake-crashes.sh" << 'EOF'
#!/usr/bin/env bash
# Crashes before writing anything -- this is what a genuinely vacuous canary
# run looks like: it "stays clean" only because it never got far enough to
# write, not because it is hermetic.
exit 1
EOF
set +e
divergentOut=$(check_real_canary "$work/divergent" 2>&1); divergentRc=$?
set -e
[ "$divergentRc" -ne 0 ] \
  || fail "case h: check_real_canary must FAIL when a suite writes cacheDir()/install-profile.json via an unoverridden USERPROFILE, i.e. HOME/USERPROFILE divergence (got rc=0)"
grepq "$divergentOut" -F 'test-fake-divergent.sh' \
  || fail "case h: expected the offending file named: $divergentOut"
grepq "$divergentOut" -iF 'vacuity' \
  || fail "case h: expected a VACUITY line for the crashed sibling suite: $divergentOut"
grepq "$divergentOut" -F 'test-fake-crashes.sh' \
  || fail "case h: expected the crashed suite named in the vacuity line: $divergentOut"
echo "ok: case h — positive control: check_real_canary()'s sandbox still fires when HOME and USERPROFILE diverge (the exact os.homedir()-follows-USERPROFILE condition this ticket exists to catch), the real operator files were never WRITTEN to prove it (watched read-only as a tripwire, per round 5, but this fixture never touches them), and a sibling suite that crashed before writing anything is called out by name as vacuous evidence rather than silently read as clean"

# ── case h2 (POSITIVE CONTROL, codex-panel round 3): when EVERY suite in the
# corpus crashes -- zero hermeticity evidence produced -- check_real_canary()
# must FAIL rather than return the previous rc=0 (rc was only ever set by a
# DRIFT, so an all-crashed run used to report clean having certified
# nothing). Two crashing fixtures, no leaky one, so the ONLY thing that could
# make this fail is the new no-evidence refusal, not a DRIFT.
mkdir -p "$work/allcrash"
cat > "$work/allcrash/test-fake-crash-a.sh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$work/allcrash/test-fake-crash-b.sh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
set +e
allcrashOut=$(check_real_canary "$work/allcrash" 2>&1); allcrashRc=$?
set -e
[ "$allcrashRc" -ne 0 ] \
  || fail "case h2: check_real_canary must FAIL when every suite in the corpus crashed (zero evidence) (got rc=0): $allcrashOut"
grepq "$allcrashOut" -iF 'no evidence' \
  || fail "case h2: expected a NO-EVIDENCE / refuse-to-certify line (got: $allcrashOut)"
echo "ok: case h2 — positive control: check_real_canary() refuses to certify PASS when every suite in the corpus crashed and produced zero hermeticity evidence"

# ── case h3 (POSITIVE CONTROL, codex-panel round 6): real_home_dir() must
# follow USERPROFILE, not $HOME, when they diverge -- the exact defect this
# round found in check_real_canary()'s operator-file tripwire (it used to
# derive its watched paths from $HOME directly). This is the control that
# would have caught it: under HOME/USERPROFILE divergence, a $HOME-derived
# tripwire watches paths nothing ever writes and reports clean through a real
# escape. Both directions are asserted (divergence follows USERPROFILE; an
# unset USERPROFILE falls back to $HOME) in their own command-substitution
# subshells, so neither override ever leaks into the rest of this file.
#
# real_home_dir()'s cygpath branch only runs on MINGW/MSYS/Cygwin -- gated the
# same honest-skip way case i already is (and for the same reason: case i's
# own round-5 regression was an unconditional assertion here failing this
# suite on this repo's own Linux CI, where there is no cygpath branch to prove
# anything about).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    h3fakeHome=$(mktemp -d "${TMPDIR:-/tmp}/h3-fakehome.XXXXXX") || fail "case h3: mktemp -d failed (fakeHome)"
    h3realUp=$(mktemp -d "${TMPDIR:-/tmp}/h3-realup.XXXXXX") || fail "case h3: mktemp -d failed (realUp)"
    h3expectUp="$(cygpath -u "$h3realUp")"
    h3gotDivergent=$(
      HOME="$h3fakeHome" USERPROFILE="$h3realUp"
      export HOME USERPROFILE
      real_home_dir
    )
    h3gotFallback=$(
      HOME="$h3fakeHome"
      export HOME
      unset USERPROFILE
      real_home_dir
    )
    rm -rf "$h3fakeHome" "$h3realUp"
    [ "$h3gotDivergent" = "$h3expectUp" ] \
      || fail "case h3: real_home_dir() must follow USERPROFILE, not \$HOME, when they diverge (HOME=$h3fakeHome USERPROFILE=$h3realUp): got '$h3gotDivergent', expected '$h3expectUp'"
    [ "$h3gotFallback" = "$h3fakeHome" ] \
      || fail "case h3: real_home_dir() must fall back to \$HOME when USERPROFILE is unset (HOME=$h3fakeHome): got '$h3gotFallback', expected '$h3fakeHome'"
    echo "ok: case h3 — positive control: real_home_dir() follows USERPROFILE over \$HOME when they diverge (the exact defect check_real_canary()'s operator-file tripwire had), and falls back to \$HOME when USERPROFILE is unset"
    ;;
  *)
    echo "SKIP: case h3 — real_home_dir()'s cygpath branch only runs on MINGW/MSYS/Cygwin (uname -s here: $(uname -s)); nothing to assert about USERPROFILE-vs-HOME divergence on this platform"
    ;;
esac

# ── case i (POSITIVE CONTROL, codex-panel round 4 -- the one exception to
# the "only this guard file" fence, and only for this control): winpath()
# itself (sourced from _hermetic-home.sh at the top of THIS file, line
# ~125, for this guard's own use) used to fall back to the untranslated
# MSYS path whenever `cygpath -m` failed -- non-empty, so the empty-output
# check downstream passed it through, defeating winpath()'s entire stated
# fail-loud contract. Shadow `cygpath` with a failing function INSIDE A
# COMMAND-SUBSTITUTION SUBSHELL so the override can never leak into any
# other case in this file, then call the REAL winpath() (not a fixture
# copy) and assert it dies loud instead of returning the bad path.
#
# codex-panel round 5 (CRITICAL, a regression THIS control introduced):
# winpath()'s platform switch is `case "$(uname -s)"` -- on Linux/macOS it
# takes the `*)` branch, echoes its input unchanged, and exits 0 regardless
# of the cygpath shadow (cygpath is never even consulted there). The
# original control asserted `cygpathRc -ne 0` unconditionally, so it failed
# this whole suite on every non-Windows platform, including this repo's own
# Linux CI. Gated the same honest-skip way case g(real)(c) already handles
# a condition that only applies on some runs -- not by weakening the
# assertion (it is correct on the platform winpath's cygpath branch
# actually applies to), only by scoping it to run there.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    set +e
    cygpathOut=$(
      # Called indirectly: winpath() (sourced from _hermetic-home.sh)
      # invokes `cygpath` by name, which shellcheck cannot see from this
      # file alone.
      # shellcheck disable=SC2317,SC2329
      cygpath() { echo "cygpath: simulated failure for the control" >&2; return 1; }
      winpath "/c/Users/testuser" 2>&1
    ); cygpathRc=$?
    set -e
    [ "$cygpathRc" -ne 0 ] \
      || fail "case i: winpath() must FAIL when cygpath fails, not silently return the untranslated MSYS path (got rc=0): $cygpathOut"
    grepq "$cygpathOut" -iF 'FATAL' \
      || fail "case i: expected a FATAL message (got: $cygpathOut)"
    grepq "$cygpathOut" -F '/c/Users/testuser' \
      || fail "case i: expected the failing input path named in the FATAL message (got: $cygpathOut)"
    echo "ok: case i — positive control: winpath() fails loud when cygpath fails, rather than silently returning the untranslated MSYS path a native node.exe/pwsh.exe child cannot resolve"
    ;;
  *)
    echo "SKIP: case i — winpath()'s cygpath branch only runs on MINGW/MSYS/Cygwin (uname -s here: $(uname -s)); nothing to shadow or assert on this platform"
    ;;
esac

# ── case i2 (POSITIVE CONTROL, HIMMEL-2366 known residual): this ticket ships
# one KNOWN fail-open, documented in the guard's own header comment above
# canary_run() -- winpath()'s `exit 1` does NOT abort the calling suite when
# winpath is used the way almost every suite here actually uses it: as a
# `VAR="$(...)"` PREFIX to another command (`USERPROFILE="$(winpath "$h")"
# ... "$node_bin" "$wizard" ...`), rather than as its own standalone
# assignment statement. case i above proves the OTHER half -- winpath dies
# loud (rc != 0) in the STANDALONE shape. This proves the prefix shape is the
# opposite situation: rc stays 0, the command after the prefix still runs,
# and the assigned variable comes out empty. The single reason that residual
# is acceptable to merge is that the FATAL line still reaches stderr even
# though nothing else does -- the precondition (a failing cygpath) cannot
# happen QUIETLY. That claim was prose in the PR body; this control proves it.
#
# Same fence as case i, for the same reason: winpath()'s cygpath branch only
# exists on MINGW/MSYS/Cygwin, so an unconditional assertion here would be
# exactly case i's own round-5 regression (failing this suite on this repo's
# own Linux CI) repeated for a second control.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    set +e
    i2Out=$(
      # `2>&1` on a REDIRECTION AT THE TAIL of a `VAR=$(...) cmd` line binds
      # only to `cmd`'s own fds, NOT to the nested `$(winpath ...)` inside the
      # assignment prefix -- verified empirically: a first attempt with the
      # redirection placed there let winpath's FATAL escape straight to the
      # real stderr, uncaptured, exactly the vacuous-capture trap this
      # control exists to avoid. `exec 2>&1` as the FIRST line of this
      # subshell instead rebinds fd 2 -> fd 1 for the subshell itself, before
      # anything in it runs, so every nested command substitution's stderr
      # (winpath's included) inherits the redirected fd and is captured too.
      exec 2>&1
      # Called indirectly: winpath() (sourced from _hermetic-home.sh) invokes
      # `cygpath` by name, which shellcheck cannot see from this file alone.
      # shellcheck disable=SC2317,SC2329
      cygpath() { echo "cygpath: simulated failure for the control" >&2; return 1; }
      # The real-world prefix shape: winpath() feeds a VAR=$(...) prefix to
      # ANOTHER command, never a standalone assignment. `bash -c` is that
      # other command here -- a fresh process so it reads i2UP from ITS OWN
      # environment (via $i2UP), which is the only way to observe what the
      # prefix actually handed the following command, rather than an
      # already-expanded shell-variable snapshot from before the assignment.
      i2UP="$(winpath "/c/Users/testuser")" bash -c 'echo CONTINUED; echo "USERPROFILE_VALUE=[$i2UP]"'
    ); i2Rc=$?
    set -e
    # (1) the mitigation the merge argument rests on: the FATAL line must
    # actually reach the merged output.
    grepq "$i2Out" -iF 'FATAL' \
      || fail "case i2: expected winpath()'s FATAL to survive the env-prefix shape on stderr (got: $i2Out)"
    # (2) the swallowed exit 1: the command after the prefix still ran, and
    # the overall rc stayed 0 -- this is WHY the FATAL line is the only
    # surviving signal, not a nice-to-have alongside a nonzero rc.
    grepq "$i2Out" -F 'CONTINUED' \
      || fail "case i2: expected the command AFTER the failing prefix assignment to still run, not be aborted by winpath's exit 1 (got: $i2Out)"
    [ "$i2Rc" -eq 0 ] \
      || fail "case i2: expected the overall rc to stay 0 in the env-prefix shape (winpath's exit 1 does not propagate to it) (got rc=$i2Rc): $i2Out"
    # (3) the falsy-in-JS leak shape itself: the assigned variable came out
    # EMPTY, not the untranslated path -- this is what makes the residual
    # reachable at all (cacheDir()/configPath() treat "" the same as unset).
    grepq "$i2Out" -F 'USERPROFILE_VALUE=[]' \
      || fail "case i2: expected the prefix-assigned variable to come out EMPTY (got: $i2Out)"
    echo "ok: case i2 — positive control: in the env-prefix shape (USERPROFILE=\"\$(winpath ...)\" ... cmd, the shape every real suite here uses), a failing winpath() does NOT abort the suite -- rc stays 0 and the following command still runs -- and the assigned variable comes out empty, but the FATAL line still reaches stderr; that surviving FATAL is the loud-failure mitigation the HIMMEL-2366 known residual's merge argument rests on"
    ;;
  *)
    echo "SKIP: case i2 — winpath()'s cygpath branch only runs on MINGW/MSYS/Cygwin (uname -s here: $(uname -s)); nothing to assert about the env-prefix swallowed-exit-1 shape on this platform"
    ;;
esac

# case g(real): the three-part real-tree assertion. (a) the source line is
# present on every suite that fakes a HOME; (b) no suite still defines its
# own winpath() (the consolidation held); (c) the behavioural canary against
# the three REAL operator-home files, wrapped around actually running the
# real suite corpus -- opt-in, see its own comment below for why.
set +e
srcOut=$(check_sources_helper "$REAL_TEST_DIR" 2>&1); srcRc=$?
set -e
[ "$srcRc" -eq 0 ] \
  || fail "case g(real)(a): $REAL_TEST_DIR has suites faking HOME without sourcing _hermetic-home.sh: $srcOut"
echo "ok: case g(real)(a) — every scripts/himmelctl/test/*.sh that fakes HOME sources _hermetic-home.sh"

set +e
noLocalOut=$(check_no_local_winpath "$REAL_TEST_DIR" 2>&1); noLocalRc=$?
set -e
[ "$noLocalRc" -eq 0 ] \
  || fail "case g(real)(b): $REAL_TEST_DIR has a suite still defining its own winpath() -- consolidation incomplete: $noLocalOut"
echo "ok: case g(real)(b) — no scripts/himmelctl/test/*.sh defines its own winpath() any more (the HIMMEL-2350 34-copies-to-one consolidation held)"

# case g(real)(c): OFF BY DEFAULT (opt in via HERMETICITY_REAL_CANARY=1).
# This file is itself discovered and run by scripts/ci/run-shell-tests.sh
# alongside its 26 real siblings under scripts/himmelctl/test/ -- if this
# loop executed unconditionally on every corpus pass, every sibling suite
# would run TWICE per pass (once as its own top-level entry, once nested in
# here), and at least one sibling (test-wizard-probes.sh) has been measured
# at or past the runner's own 600s per-suite cap standalone ("CAP EXCEEDED
# after 608s, cap 600s", run 1) -- nesting the whole set inside THIS suite's
# own budget would make this guard the next flake it exists to prevent. So
# the default corpus pass gets checks (a) and (b) above plus the SYNTHETIC
# canary proof (case e/f/h), which already proves canary_snapshot/canary_run
# itself can fire and stay silent, including under HOME/USERPROFILE
# divergence (case h); the exhaustive sandboxed-real-suite-corpus proof is
# opt-in, for an operator who wants "does actually running every real suite
# ever write outside its sandbox" proven directly rather than inferred from
# clean source text. Purely a CI-cost gate now (check_real_canary() never
# touches the real files at all, post codex-1/codex-2), not a risk one. This
# is a genuine coverage gap when skipped, not a hidden one -- the SKIP line
# below says so out loud, and the final summary line reflects it too rather
# than letting case g read as a complete pass when it did not run the
# expensive layer.
if [ "${HERMETICITY_REAL_CANARY:-0}" = "1" ]; then
  set +e
  realCanaryOut=$(check_real_canary "$REAL_TEST_DIR" 2>&1); realCanaryRc=$?
  set -e
  [ "$realCanaryRc" -eq 0 ] \
    || fail "case g(real)(c): running the real suite corpus wrote outside its sandbox: $realCanaryOut"
  # Print whatever check_real_canary() itself reported (in particular a
  # REAL-CANARY VACUITY line) even on a clean rc -- a pass over a corpus
  # where several real suites crashed before writing anything must not read
  # as a silent, complete clean bill of health.
  [ -n "$realCanaryOut" ] && echo "$realCanaryOut"
  echo "ok: case g(real)(c) — behavioral canary: every real suite in $REAL_TEST_DIR actually ran (against a sandbox seeded from the three real files, never the live ones), and none wrote outside it (HERMETICITY_REAL_CANARY=1)"
  ran_real_canary=1
else
  echo "SKIP: case g(real)(c) — the sandboxed real-suite-corpus canary is opt-in (HERMETICITY_REAL_CANARY=1); this run only proves the synthetic canary mechanism (case e/f/h) and the two static checks (a)/(b), NOT that running the real corpus stays inside its sandbox -- run with HERMETICITY_REAL_CANARY=1, or scripts/ci/run-shell-tests.sh scripts/himmelctl with a before/after sha256 of the three real files, for that proof"
  ran_real_canary=0
fi

# codex-5: this line used to claim the real tree was "clean across all
# layers" unconditionally, including runs where case g(real)(c) above was
# SKIPPED -- on a PR whose headline is that text-which-reads-like-protection
# is not protection, an overstated success line is not a nit. State which
# layers actually ran.
if [ "$ran_real_canary" -eq 1 ]; then
  echo "ok - hermeticity guard fires on a bad fixture, stays silent on a good one (both the old local-winpath() shape and the current sourced-helper shape), the synthetic AND sandboxed-real canaries both catch what the static check can't (including under HOME/USERPROFILE divergence), the winpath consolidation held (no suite defines its own copy any more), and the real suite tree is clean across ALL layers, including the sandboxed real-suite-corpus run (HERMETICITY_REAL_CANARY=1)"
else
  echo "ok - hermeticity guard fires on a bad fixture, stays silent on a good one (both the old local-winpath() shape and the current sourced-helper shape), the synthetic canary catches what the static check can't (including under HOME/USERPROFILE divergence, case h), and the winpath consolidation held (no suite defines its own copy any more) -- the sandboxed real-suite-corpus canary (case g(real)(c)) was SKIPPED this run (opt-in via HERMETICITY_REAL_CANARY=1), so this PASS does NOT itself prove the real suite corpus stays inside its sandbox, only that every layer which DID run is clean"
fi
