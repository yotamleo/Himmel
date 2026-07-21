#!/usr/bin/env bash
# test-wizard-questions.sh — hermetic tests for the himmelctl install wizard's
# question engine (HIMMEL-887 T2) + answer schema/cache (T3). Mirrors
# test-wizard-preflight.sh conventions: a stub PATH built via
# scripts/lib/hermetic-path.sh, a fake HOME, node launched by absolute path so
# the wizard's tool detection sees ONLY the stub dir. A fake `git` stub
# controls the role heuristic's origin answer, so cwd never matters. Nothing on
# the real machine is read or written (the cache lands in a throwaway
# HIMMELCTL_CACHE_DIR — under Git Bash, HOME does NOT propagate into node.exe,
# so ~/.claude/himmel/ is redirected via this env seam instead).
#
# Covers (T2):
#   1. adopter stdin sequence -> 5 main questions (role+scope+vault+handover+
#      pluginSet) + the answer summary with role=adopter.
#   2. contributor sequence (git stub origin = himmel URL AND a .himmel-dev
#      marker at the stubbed repo toplevel — CR r5: the marker is the
#      contributor signal, the origin name alone is not) -> 4 main questions
#      (no scope) + the printed heuristic reasoning line naming contributor.
#   3. invalid enum answer -> the question repeats once, then accepts.
#   4. non-interactive without --from-profile -> refuses (non-zero + message),
#      no hang.
#   7. CR r5: himmel-named origin WITHOUT the .himmel-dev marker (the shape
#      every official-clone adopter lands on after the CR r4 shims cd into
#      the fresh clone) -> ADOPTER default, scope asked, and the accepted
#      defaults derive adopt.sh with the vault flags honored — never
#      setup.sh.
#   8. --default-scope user changes only the adopter scope question's default;
#      accepting it still prints the plan normally and preserves confirmation.
# Covers (T3):
#   5. interactive run writes the cache; --from-profile on it reproduces the
#      same answer JSON with ZERO prompts.
#   6. --from-profile on a cache missing `role` -> non-zero + message, no hang
#      (CR r5: rc=2 via the strict schema validator).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# node is launched by absolute path so a stub-only PATH can be hermetic without
# making node itself unlaunchable.
node_bin=$(command -v node)

# HIMMEL-1192: pin bin.js's bash spawns (detectRole shells out to the STUB
# `git` via `bash -c`) to the bare, PATH-honoring `bash` this suite links into
# its stub dir. Without the pin, resolveBash() would pick a Windows-native Git
# Bash (…\Git\bin\bash.exe) whose MSYS launcher PREPENDS Git's /mingw64/bin to
# PATH — shadowing the hermetic `git` stub with the real git, so detectRole
# reads the real repo origin and the role heuristic under test breaks. `git` is
# the one stubbed tool that also ships inside Git Bash's own bin dirs; the seam
# keeps this question-engine suite isolated from the bash-resolution concern
# (resolveBash itself is covered by test-wizard-update.sh Case F). No-op on
# posix, where resolveBash returns bare 'bash' anyway.
export HIMMELCTL_BASH=bash

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin. node.exe on win32 misresolves MSYS /tmp-style paths
# (and MSYS resets HOME for native procs), so paths handed to node as env
# values or --from-profile args must be Windows-shaped there.
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# build_path <stub_dir> <present_tools...> -- <absent_tools...>
# (Copied from test-wizard-preflight.sh: link the named present tools off the
# CURRENT PATH into <stub_dir>, then echo a PATH with the stub prepended and
# the named absent tools scrubbed.)
build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  for _t in "${_present[@]}"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

# make_git_stub <destdir> <origin-url> [toplevel] — writes <destdir>/git that
# answers `remote get-url origin` with <origin-url> and (CR r5)
# `rev-parse --show-toplevel` with [toplevel] when given (else exits 1, like
# git outside a work tree), so the role heuristic sees a controlled origin
# AND a controlled repo root for the .himmel-dev marker probe. The wizard
# resolves git through `bash -c`, so a bash-script stub is executable on
# every OS. [toplevel] must be node-shaped (winpath) — bin.js hands it to
# fs.existsSync.
make_git_stub() {
  local _d="$1" _url="$2" _top="${3:-}"
  cat > "$_d/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ] && [ "\$3" = "origin" ]; then
  printf '%s\n' "$_url"
  exit 0
fi
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
  if [ -n "$_top" ]; then printf '%s\n' "$_top"; exit 0; fi
  exit 1
fi
exit 0
STUB
  chmod +x "$_d/git"
}

# Count main (enum) question headers in a captured output blob. Path sub-
# prompts carry no '[' so they are excluded; adopter -> 5, contributor -> 4.
count_questions() { printf '%s' "$1" | grep -cE '^\? .*\[' || true; }

# ── Case 1: adopter sequence -> 5 questions + summary role=adopter ─────────────
stub1="$work/case1"; mkdir -p "$stub1"
c1path=$(build_path "$stub1" bash jq python3 npm -- )
make_git_stub "$stub1" "https://github.com/someone/other-repo.git"
h1="$work/h1"; mkdir -p "$h1"
set +e
out=$(PATH="$c1path" HOME="$h1" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
adopter
project
none
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case1: adopter run should succeed (got rc=$rc)"
qs=$(count_questions "$out")
[ "$qs" -eq 5 ] \
  || fail "case1: adopter should ask 5 main questions (got $qs): $out"
printf '%s' "$out" | grep -q '"role": "adopter"' \
  || fail "case1: summary should show role=adopter (got: $out)"
printf '%s' "$out" | grep -q '? scope \[' \
  || fail "case1: adopter should be asked scope (got: $out)"
echo "ok: case1 adopter -> 5 questions + summary role=adopter"

# ── Case 2: contributor sequence -> 4 questions + contributor reasoning ───────
# CR r5: a himmel-named origin alone no longer defaults contributor — the
# stubbed repo toplevel must also carry the .himmel-dev marker (the
# contributor dev-checkout signal the pre-commit gates key on).
stub2="$work/case2"; mkdir -p "$stub2"
c2path=$(build_path "$stub2" bash jq python3 npm -- )
top2="$work/case2-top"; mkdir -p "$top2"; touch "$top2/.himmel-dev"
make_git_stub "$stub2" "https://github.com/user/himmel.git" "$(winpath "$top2")"
h2="$work/h2"; mkdir -p "$h2"
set +e
out=$(PATH="$c2path" HOME="$h2" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install 2>&1 <<INPUT

none
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case2: contributor run should succeed (got rc=$rc)"
qs=$(count_questions "$out")
[ "$qs" -eq 4 ] \
  || fail "case2: contributor should ask 4 main questions (got $qs): $out"
printf '%s' "$out" | grep -q '^detected:.*contributor' \
  || fail "case2: reasoning line should name contributor (got: $out)"
printf '%s' "$out" | grep -q '? scope \[' \
  && fail "case2: contributor must NOT be asked scope (got: $out)"
printf '%s' "$out" | grep -q '"role": "contributor"' \
  || fail "case2: summary should show role=contributor (got: $out)"
echo "ok: case2 contributor -> 4 questions + reasoning + no scope"

# ── Case 3: invalid enum -> question repeats once then accepts ────────────────
stub3="$work/case3"; mkdir -p "$stub3"
c3path=$(build_path "$stub3" bash jq python3 npm -- )
make_git_stub "$stub3" "https://github.com/someone/other-repo.git"
h3="$work/h3"; mkdir -p "$h3"
set +e
out=$(PATH="$c3path" HOME="$h3" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
bogus
adopter
project
none
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case3: invalid-then-valid run should succeed (got rc=$rc)"
reprompts=$(printf '%s' "$out" | grep -cE '^\? role \[' || true)
[ "$reprompts" -eq 2 ] \
  || fail "case3: role header should appear twice (invalid then accept) (got $reprompts): $out"
echo "ok: case3 invalid enum -> role re-prompted once then accepted"

# ── Case 4: non-interactive without --from-profile -> refuse, no hang ─────────
stub4="$work/case4"; mkdir -p "$stub4"
c4path=$(build_path "$stub4" bash jq python3 npm -- )
make_git_stub "$stub4" "https://github.com/someone/other-repo.git"
h4="$work/h4"; mkdir -p "$h4"
set +e
out=$(PATH="$c4path" HOME="$h4" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "case4: non-interactive no-profile should exit non-zero (got $rc)"
printf '%s' "$out" | grep -q 'requires --from-profile' \
  || fail "case4: should print a --from-profile hint (got: $out)"
printf '%s' "$out" | grep -q '^detected:' \
  && fail "case4: non-interactive refuse must NOT start the question engine (got: $out)"
echo "ok: case4 non-interactive no profile -> refuse + message, no hang"

# ── Case 5: interactive writes cache; --from-profile round-trips, zero prompts ─
# Under Git Bash, HOME does NOT propagate into node.exe children, so the cache
# dir is redirected via HIMMELCTL_CACHE_DIR (Windows-shaped for node); a POSIX
# alias of the same dir is kept for bash file ops.
stub5="$work/case5"; mkdir -p "$stub5"
c5path=$(build_path "$stub5" bash jq python3 npm -- )
make_git_stub "$stub5" "https://github.com/someone/other-repo.git"
h5="$work/h5"; mkdir -p "$h5"
cache5_posix="$work/case5-cache"; mkdir -p "$cache5_posix"
cache5_node=$(winpath "$cache5_posix")
set +e
out=$(PATH="$c5path" HOME="$h5" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_CACHE_DIR="$cache5_node" \
      "$node_bin" "$wizard" install 2>&1 <<INPUT
adopter
project
none
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case5: interactive run should succeed (got rc=$rc)"
cachefile="$cache5_posix/install-profile.json"
[ -f "$cachefile" ] || fail "case5: cache file should be written (expected $cachefile)"
cache_body=$(cat "$cachefile")
# Draft-A schema sanity on the written cache.
printf '%s' "$cache_body" | grep -q '"role": "adopter"' \
  || fail "case5: cache should record role=adopter (got: $cache_body)"
printf '%s' "$cache_body" | grep -q '"tier": "standard"' \
  || fail "case5: cache should carry the tier placeholder (got: $cache_body)"
printf '%s' "$cache_body" | grep -q '"lanes": \[\]' \
  || fail "case5: cache should carry the lanes placeholder (got: $cache_body)"
printf '%s' "$cache_body" | grep -q '"alwaysOn": false' \
  || fail "case5: cache should carry the alwaysOn placeholder (got: $cache_body)"
# Now replay the cache non-interactively: ZERO prompts + byte-stable JSON.
# Non-interactive --from-profile (T4) skips the confirm and shells out for
# real, so HIMMELCTL_REPO_ROOT is pointed at a throwaway fixture carrying a
# harmless no-op adopt.sh stub — keeps this replay hermetic (no real adopt.sh
# execution against the checkout) without changing what's being asserted here
# (the --from-profile round-trip, not T4 derivation — that's covered by
# test-wizard-derive.sh).
fixture5="$work/case5-fixture"; mkdir -p "$fixture5/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture5/scripts/adopt.sh"
chmod +x "$fixture5/scripts/adopt.sh"
set +e
out_b=$(PATH="$c5path" HOME="$h5" HIMMELCTL_INTERACTIVE=0 \
        HIMMELCTL_REPO_ROOT="$(winpath "$fixture5")" \
        "$node_bin" "$wizard" install --from-profile "$(winpath "$cachefile")" \
        </dev/null 2>&1); rc_b=$?
set -e
[ "$rc_b" -eq 0 ] || fail "case5: --from-profile should succeed (got rc=$rc_b): $out_b"
prompts=$(printf '%s' "$out_b" | grep -cE '^\? ' || true)
[ "$prompts" -eq 0 ] \
  || fail "case5: --from-profile must ask ZERO questions (got $prompts): $out_b"
# Extract the JSON block node printed: from the first '{' line to the first
# bare '}' line (the top-level close — nested closes are indented, e.g.
# `  },`, so they don't match). T4 prints a `derived: ...` line right after
# the JSON, which a to-end-of-output extraction would now swallow.
json_b=$(printf '%s' "$out_b" | sed -n '/^{/,/^}/p')
[ "$json_b" = "$cache_body" ] \
  || fail "case5: --from-profile should reproduce the cache byte-stable
got:      <$json_b>
expected: <$cache_body>"
echo "ok: case5 interactive writes cache; --from-profile round-trips byte-stable, zero prompts"

# ── Case 6: --from-profile on a cache missing `role` -> non-zero + msg, no hang ─
stub6="$work/case6"; mkdir -p "$stub6"
c6path=$(build_path "$stub6" bash jq python3 npm -- )
make_git_stub "$stub6" "https://github.com/someone/other-repo.git"
h6="$work/h6"; mkdir -p "$h6"
bad="$work/bad-profile.json"
# Valid JSON, valid Draft-A shape, but NO `role` field.
cat > "$bad" <<JSON
{"tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"alwaysOn":false}
JSON
set +e
out=$(PATH="$c6path" HOME="$h6" HIMMELCTL_INTERACTIVE=0 \
      "$node_bin" "$wizard" install --from-profile "$(winpath "$bad")" \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "case6: missing-role profile should exit non-zero (got $rc)"
printf '%s' "$out" | grep -qi 'role' \
  || fail "case6: should mention the missing role field (got: $out)"
# No hang: it returned (we reached here). And it must not have started prompting.
printf '%s' "$out" | grep -qE '^\? ' \
  && fail "case6: missing-role profile must NOT start the question engine (got: $out)"
echo "ok: case6 --from-profile missing role -> non-zero + message, no hang"

# ── Case 7: himmel origin WITHOUT .himmel-dev marker -> ADOPTER default ───────
# CR r5: the exact shape every official-clone adopter lands on after the CR r4
# shims cd into the fresh clone — origin ends in himmel, no dev marker. The
# default must be adopter (scope IS asked, answers honored, adopt.sh derived
# with the vault flags) — the old name-suffix heuristic defaulted contributor
# and ran setup.sh, discarding the scope/vault answers.
stub7="$work/case7"; mkdir -p "$stub7"
c7path=$(build_path "$stub7" bash jq python3 npm -- )
top7="$work/case7-top"; mkdir -p "$top7"   # toplevel resolves, but NO marker
make_git_stub "$stub7" "https://github.com/yotamleo/himmel.git" "$(winpath "$top7")"
h7="$work/h7"; mkdir -p "$h7"
luna7="$work/case7-luna"
set +e
out=$(PATH="$c7path" HOME="$h7" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run 2>&1 <<INPUT

project
default-template
$(winpath "$luna7")
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case7: official-clone adopter run should succeed (got rc=$rc): $out"
printf '%s' "$out" | grep -q '^detected:.*without a \.himmel-dev marker.*default adopter' \
  || fail "case7: reasoning line should name the missing marker + adopter default (got: $out)"
printf '%s' "$out" | grep -q '? scope \[' \
  || fail "case7: the adopter default must ask scope (got: $out)"
printf '%s' "$out" | grep -q '"role": "adopter"' \
  || fail "case7: summary should show role=adopter (got: $out)"
printf '%s' "$out" | grep -qE 'derived:.*adopt\.sh --profile all --scope project --luna-target' \
  || fail "case7: expected adopt.sh derived with the vault flags honored (got: $out)"
printf '%s' "$out" | grep -q 'case7-luna' \
  || fail "case7: derived --luna-target should carry the answered vault path (got: $out)"
printf '%s' "$out" | grep '^derived:' | grep -q 'setup\.sh' \
  && fail "case7: an official-clone adopter must never derive setup.sh (got: $out)"
echo "ok: case7 himmel origin without .himmel-dev -> adopter default, scope asked, adopt.sh derived with vault flags"

# ── Case 8: explicit user-scope hint changes the confirmable default only ────
stub8="$work/case8"; mkdir -p "$stub8"
c8path=$(build_path "$stub8" bash jq python3 npm -- )
make_git_stub "$stub8" "https://github.com/someone/other-repo.git"
h8="$work/h8"; mkdir -p "$h8"
set +e
out=$(PATH="$c8path" HOME="$h8" HIMMELCTL_INTERACTIVE=1 \
      "$node_bin" "$wizard" install --dry-run --default-scope user 2>&1 <<INPUT


none
inline
lean
INPUT
)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "case8: user-scope hint run should succeed (got rc=$rc): $out"
printf '%s' "$out" | grep -qF '? scope [project|user] (default: user)' \
  || fail "case8: scope question should display user as its default (got: $out)"
printf '%s' "$out" | grep -q '"scope": "user"' \
  || fail "case8: accepting the scope default should record user (got: $out)"
printf '%s' "$out" | grep -qE 'derived:.*adopt\.sh --profile core --scope user$' \
  || fail "case8: accepted hint should derive the normal user-scope plan (got: $out)"
echo "ok: case8 --default-scope user -> confirmable scope default=user + normal derived plan"

echo "PASS"
