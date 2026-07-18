#!/usr/bin/env bash
# test-wizard-ensure.sh — hermetic tests for the himmelctl `ensure` subcommand
# (HIMMEL-755 A5): converges a target toward its desired manifest state via
# statusReport (pre-check) -> installEngineLib.planInstall/runInstall ->
# statusReport (post-check), fail-closed on anything still not converged that
# HAD a runnable install descriptor. Tests drive bin.js end-to-end (not the
# libs directly) via a HIMMELCTL_REPO_ROOT fixture carrying a small, purpose-
# built manifest.json + STUB primitive scripts (never the real adopt.sh/
# wire-*.sh/install-plugins.sh/qmd-bin.sh) that log their own invocation to a
# shared ENSURE_LOG file — a spy proving invocation count/order without
# depending on any real toolchain. Mirrors sibling test-wizard-*.sh
# conventions: fake HOME + HIMMELCTL_CACHE_DIR/HIMMELCTL_REPO_ROOT, node
# launched by absolute path, winpath for node.exe's MSYS-path blindness,
# scripts/lib/hermetic-path.sh's link_hermetic_tool/scrub_path for a curated
# stub PATH.
#
# Covers:
#   a. bare `ensure` with no install-profile cache -> exit 2 pointing at
#      `himmelctl install`, zero mutation.
#   b. an already-green fixture -> no-op exit 0, byte-identical tree.
#   c. `--profile luna` on a core fixture reconciles then converges the luna
#      work list (stub primitives that create their own marker file) ->
#      post-check green.
#   d. `--dry-run` prints the ordered plan, zero mutation (no primitive
#      invoked, spy log stays empty).
#   e. a 6-red fixture pinned to PER-ITEM install types (wire/wire/plugins/
#      qmd/dep/build, NO adopt/setup) drives EXACTLY 6 primitive invocations
#      in deps[] order (spy log asserted at the verb level).
#   f. a 2-adopt-red fixture coalesces to EXACTLY 1 adopt.sh invocation.
#   g. without --yes the consolidated offer prints ONCE (never per-item);
#      --yes suppresses it. Neither hangs (non-interactive stdin).
#   h. a red config-type item (install:{type:"config"}) AND a red
#      no-install (MCP-shaped) item are hint-only: NOT dispatched (no log
#      entry), and do NOT make ensure fail-close (exit 0).
#   p/q/r. (CR fix) --items must not break dependency closure: item-b deps
#      on item-a. p: `--items item-b` (item-a, its red prereq, excluded) is
#      REJECTED — exit 2, names the excluded prereq, zero mutation (no
#      primitive invoked, state.json never written). q: `--items
#      item-a,item-b` (the full closure) proceeds and converges both in
#      dependency order. r: item-a already GREEN (converged in a prior
#      step) and excluded from a follow-up `--items item-b` — no false
#      rejection, since an already-satisfied dep is exactly what the
#      "excluded == already satisfied" assumption legitimately covers.
#   s. (CR fix, HIMMEL-755 manifest-authoring bug) pre-commit-hooks
#      (reproduced with its exact real shape, post-fix: no `install` key)
#      is hint-only — adopt.sh is NEVER dispatched for it (spy log proven
#      empty) and ensure exits 0, not fail-closed forever on a genuinely
#      fine machine (adopt.sh never lays a .pre-commit-config.yaml into an
#      adopted project — "does THIS project carry the gate" is a
#      legitimate read-only signal).
#   t. (CR fix, CodeRabbit round 15, MAJOR — the toward-ENABLED mirror of
#      case k's bug in test-wizard-ensure-disable.sh) `--items
#      dependent-item,hint-prereq`, where hint-prereq is desired+red but
#      hint-only (no runnable install descriptor, so it can never actually
#      converge) — `itemsSet.has(depId)` membership alone is NOT proof a
#      dep will really be installed this run. REJECTED — exit 2, names
#      both items, zero mutation (dependent.marker never created).
#   u. (CR fix, codex round 4, Suggestion) the same hint-only prerequisite,
#      this time EXCLUDED from --items entirely (`--items dependent-item`
#      alone) — must give the SAME "converge it manually" guidance as case
#      t, never the "add it: --items ..." advice (which would resolve
#      nothing, since hint-prereq still could never converge once added).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# sha256_hash <file> — sha256sum when present, else macOS's shasum -a 256
# (no sha256sum binary there by default). Resolved once so snapshot_dir uses
# one consistent hasher.
if command -v sha256sum >/dev/null 2>&1; then
  sha256_hash() { sha256sum "$1"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_hash() { shasum -a 256 "$1"; }
else
  echo "FAIL: sha256sum or shasum required" >&2
  exit 1
fi

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

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

# write_cache <path> <role> <scope> <vault-mode> <vault-path> <handover-mode>
#             <handover-path> <plugin-set> — same minimal valid Draft-A
#             profile shape every sibling suite's write_cache writes.
write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"alwaysOn":false}
JSON
}

# snapshot_dir <dir> — sorted lines, one per file/dir/symlink, byte-identity
# check. CR fix: the original file-only version was blind to an empty
# directory create/remove or a symlink change — neither shows up as a
# "file", so a mutation limited to either would slip through every
# zero-mutation assertion undetected. Now every filesystem-object TYPE is
# represented: a regular file as its existing `sha256_hash` line
# (unchanged format), a directory as `dir <path>`, a symlink as
# `symlink <path> -> <target>` (readlink, not the dereferenced content —
# proves the LINK itself, not what it happens to point at today, is
# unchanged). Deterministic LC_ALL=C sort ordering, same as before.
snapshot_dir() {
  ( cd "$1" && find . \( -type f -o -type d -o -type l \) | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then
        printf 'symlink %s -> %s\n' "$p" "$(readlink "$p")"
      elif [ -d "$p" ]; then
        printf 'dir %s\n' "$p"
      else
        sha256_hash "$p"
      fi
    done )
}

# ── hermetic stub PATH: bash (real, needed to launch every stub primitive)
# + winget/brew/sudo (stubs, intercept the dep-a win32/darwin/linux install
# lines respectively — install-engine.js's `dep` dispatch is platform-
# branched, so ALL THREE possible host package managers must be
# intercepted, not just whichever this CI host happens to be, or the case
# is not actually hermetic: a darwin run would reach the REAL `brew`, a
# linux run could fall through to REAL `sudo apt-get`, either capable of
# hanging on a permission prompt or genuinely mutating the host) + bun
# (stub, intercepts build-a's build chain); git is SCRUBBED so dep-a's
# `which(git)` probe reads absent (red) until the platform stub is
# invoked. ───────────────────────────────────────────────────────────────
stubBin="$work/stub-bin"; mkdir -p "$stubBin"
link_hermetic_tool bash "$stubBin"
cat > "$stubBin/winget" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "dep-a" >> "$ENSURE_LOG"
exit 0
SH
chmod +x "$stubBin/winget"
cat > "$stubBin/brew" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "dep-a" >> "$ENSURE_LOG"
exit 0
SH
chmod +x "$stubBin/brew"
cat > "$stubBin/sudo" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "dep-a" >> "$ENSURE_LOG"
exit 0
SH
chmod +x "$stubBin/sudo"
cat > "$stubBin/bun" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "run" ] && [ "$2" = "build" ]; then
  [ -n "${ENSURE_LOG:-}" ] && echo "build-a" >> "$ENSURE_LOG"
fi
exit 0
SH
chmod +x "$stubBin/bun"
scrubbedPath=$(scrub_path "$PATH" git)
hermeticPath="$stubBin:$scrubbedPath"

# ── case a: bare ensure, no install-profile cache -> exit 2, zero mutation ─
repoA="$work/repoA"; mkdir -p "$repoA/scripts/install"
cat > "$repoA/scripts/install/manifest.json" <<'JSON'
{"schemaVersion":2,"harness":"claude","items":[]}
JSON
targetA="$work/targetA"; mkdir -p "$targetA"
cacheA="$work/cacheA"; mkdir -p "$cacheA"
snapABefore=$(snapshot_dir "$work")
set +e
errA=$( cd "$targetA" && HIMMELCTL_REPO_ROOT="$(winpath "$repoA")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheA")" HOME="$work/home" \
  "$node_bin" "$wizard" ensure 2>&1 )
rcA=$?
set -e
[ "$rcA" -eq 2 ] || fail "case a: bare ensure with no cache should exit 2 (got rc=$rcA): $errA"
echo "$errA" | grep -qF 'run himmelctl install first' || fail "case a: expected the 'run himmelctl install first' message (got: $errA)"
[ ! -f "$cacheA/state.json" ] || fail "case a: state.json must NOT be created when no install-profile cache exists"
snapAAfter=$(snapshot_dir "$work")
[ "$snapABefore" = "$snapAAfter" ] || fail "case a: bare ensure with no cache should make zero mutations"
echo "ok: case a — bare ensure with no install-profile cache exits 2, zero mutation"

# ── shared small fixture repo/manifest for cases b/d/g: ONE item, already
# desired+green (no red work) so these cases exercise the no-op / dry-run /
# offer-printing paths without needing a full convergence run. ─────────────
repoBDG="$work/repoBDG"; mkdir -p "$repoBDG/scripts/install"
cat > "$repoBDG/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "green-item",
      "kind": "hook",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "green.marker" }
    }
  ]
}
JSON

targetB="$work/targetB"; mkdir -p "$targetB"
: > "$targetB/green.marker"
cacheB="$work/cacheB"; mkdir -p "$cacheB"
write_cache "$cacheB/install-profile.json" adopter project none "" inline "" lean

runEnsureB() {
  ( cd "$targetB" && HIMMELCTL_REPO_ROOT="$(winpath "$repoBDG")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheB")" HOME="$work/home" \
      "$node_bin" "$wizard" ensure </dev/null )
}
# Seed the ONE sanctioned derive-if-missing write before the purity snapshot
# (same convention every shipped status suite uses).
runEnsureB >/dev/null

# ── case b: already-green fixture -> no-op exit 0, byte-identical tree ─────
snapBBefore=$(snapshot_dir "$work")
set +e
outB=$(runEnsureB); rcB=$?
set -e
[ "$rcB" -eq 0 ] || fail "case b: an already-green fixture should exit 0 (got rc=$rcB): $outB"
echo "$outB" | grep -qF 'already at the desired state' || fail "case b: expected a no-op message (got: $outB)"
snapBAfter=$(snapshot_dir "$work")
[ "$snapBBefore" = "$snapBAfter" ] || fail "case b: an already-green ensure run should leave the fixture tree byte-identical"
echo "ok: case b — an already-green fixture is a no-op, exit 0, byte-identical tree"

# ── shared small fixture for case d: ONE red item with a runnable install
# descriptor whose stub primitive would log to ENSURE_LOG if ever invoked ──
repoD="$work/repoD"; mkdir -p "$repoD/scripts/install" "$repoD/scripts/lib"
cat > "$repoD/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "red-item",
      "kind": "wiring",
      "scopes": ["project"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "red.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repoD/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "red-item" >> "$ENSURE_LOG"
: > red.marker
exit 0
SH
targetD="$work/targetD"; mkdir -p "$targetD"
cacheD="$work/cacheD"; mkdir -p "$cacheD"
write_cache "$cacheD/install-profile.json" adopter project none "" inline "" lean
logD="$work/ensure-log-d.txt"; : > "$logD"

snapDBefore=$(snapshot_dir "$work")
set +e
outD=$( cd "$targetD" && HIMMELCTL_REPO_ROOT="$(winpath "$repoD")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HOME="$work/home" ENSURE_LOG="$(winpath "$logD")" \
  "$node_bin" "$wizard" ensure --dry-run </dev/null ); rcD=$?
set -e
[ "$rcD" -eq 0 ] || fail "case d: --dry-run should exit 0 (got rc=$rcD): $outD"
echo "$outD" | grep -q 'DRY:' || fail "case d: --dry-run should print the ordered plan as DRY lines (got: $outD)"
[ ! -s "$logD" ] || fail "case d: --dry-run must invoke NOTHING — spy log should stay empty (got: $(cat "$logD")))"
snapDAfter=$(snapshot_dir "$work")
[ "$snapDBefore" = "$snapDAfter" ] || fail "case d: --dry-run should make zero mutations"
echo "ok: case d — --dry-run prints the ordered plan; spy log empty; zero mutation"

# ── case g: consolidated offer prints ONCE; --yes suppresses it; neither
# hangs on non-interactive stdin ────────────────────────────────────────────
logG="$work/ensure-log-g.txt"; : > "$logG"
set +e
outG1=$( cd "$targetD" && HIMMELCTL_REPO_ROOT="$(winpath "$repoD")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HOME="$work/home" ENSURE_LOG="$(winpath "$logG")" \
  "$node_bin" "$wizard" ensure --dry-run </dev/null ); rcG1=$?
set -e
[ "$rcG1" -eq 0 ] || fail "case g: without --yes should still exit 0 non-interactively (got rc=$rcG1): $outG1"
offerCount=$(echo "$outG1" | grep -c 'about to ' || true)
[ "$offerCount" -eq 1 ] || fail "case g: the consolidated offer should print EXACTLY once (got $offerCount): $outG1"
set +e
outG2=$( cd "$targetD" && HIMMELCTL_REPO_ROOT="$(winpath "$repoD")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheD")" HOME="$work/home" ENSURE_LOG="$(winpath "$logG")" \
  "$node_bin" "$wizard" ensure --dry-run --yes </dev/null ); rcG2=$?
set -e
[ "$rcG2" -eq 0 ] || fail "case g: --yes should exit 0 non-interactively (got rc=$rcG2): $outG2"
echo "$outG2" | grep -qv 'about to ' >/dev/null 2>&1 || true
offerCount2=$(echo "$outG2" | grep -c 'about to ' || true)
[ "$offerCount2" -eq 0 ] || fail "case g: --yes should suppress the consolidated offer entirely (got $offerCount2 lines): $outG2"
echo "ok: case g — the consolidated offer prints exactly once without --yes; --yes suppresses it; neither hangs"

# ── case j (CR fix, HIMMEL-755): a NON-interactive ensure without --yes
# must NOT proceed to convergence — exit 2, zero mutation, BEFORE any
# install/unwire. Reuses repoD's manifest/stub (one runnable red item). ────
targetJ="$work/targetJ"; mkdir -p "$targetJ"
cacheJ="$work/cacheJ"; mkdir -p "$cacheJ"
write_cache "$cacheJ/install-profile.json" adopter project none "" inline "" lean
logJ="$work/ensure-log-j.txt"; : > "$logJ"

snapJBefore=$(snapshot_dir "$work")
set +e
outJ=$( cd "$targetJ" && HIMMELCTL_REPO_ROOT="$(winpath "$repoD")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheJ")" HOME="$work/home" ENSURE_LOG="$(winpath "$logJ")" \
    "$node_bin" "$wizard" ensure 2>&1 </dev/null ); rcJ=$?
set -e
[ "$rcJ" -eq 2 ] || fail "case j: a non-interactive ensure without --yes should exit 2 (got rc=$rcJ): $outJ"
echo "$outJ" | grep -qF 'non-interactive ensure requires --yes' || fail "case j: expected the non-interactive-requires---yes message (got: $outJ)"
[ ! -f "$cacheJ/state.json" ] || fail "case j: state.json must NOT be created when ensure is refused for lacking --yes"
[ ! -s "$logJ" ] || fail "case j: no primitive should have been invoked (spy log: $(cat "$logJ"))"
snapJAfter=$(snapshot_dir "$work")
[ "$snapJBefore" = "$snapJAfter" ] || fail "case j: a non-interactive ensure without --yes should make ZERO mutations"
echo "ok: case j — non-interactive ensure without --yes exits 2 before any install/unwire; zero mutation"

# ── case k (CR fix, HIMMEL-755): an interactive decline leaves state.json
# unwritten (the save is deferred past the consent gate). ──────────────────
targetK="$work/targetK"; mkdir -p "$targetK"
cacheK="$work/cacheK"; mkdir -p "$cacheK"
write_cache "$cacheK/install-profile.json" adopter project none "" inline "" lean
logK="$work/ensure-log-k.txt"; : > "$logK"

snapKBefore=$(snapshot_dir "$work")
set +e
outK=$( cd "$targetK" && HIMMELCTL_REPO_ROOT="$(winpath "$repoD")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheK")" HOME="$work/home" ENSURE_LOG="$(winpath "$logK")" HIMMELCTL_INTERACTIVE=1 \
    "$node_bin" "$wizard" ensure <<<"n" 2>&1 ); rcK=$?
set -e
[ "$rcK" -eq 0 ] || fail "case k: an interactive decline should exit 0 (got rc=$rcK): $outK"
echo "$outK" | grep -qF 'declined; nothing run' || fail "case k: expected the decline message (got: $outK)"
[ ! -f "$cacheK/state.json" ] || fail "case k: state.json must NOT be created after an interactive decline"
[ ! -s "$logK" ] || fail "case k: no primitive should have been invoked after a decline (spy log: $(cat "$logK"))"
snapKAfter=$(snapshot_dir "$work")
[ "$snapKBefore" = "$snapKAfter" ] || fail "case k: an interactive decline should make ZERO mutations"
echo "ok: case k — an interactive decline leaves state.json unwritten; zero mutation"

# ── case c: --profile luna reconciles a core fixture, converges the luna
# work list (a stub primitive that creates its own marker) -> post-check
# green ──────────────────────────────────────────────────────────────────
repoC="$work/repoC"; mkdir -p "$repoC/scripts/install" "$repoC/scripts/lib"
cat > "$repoC/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "luna-item",
      "kind": "vault",
      "scopes": ["project"],
      "profiles": ["luna", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "luna.marker" },
      "install": { "type": "qmd" }
    }
  ]
}
JSON
cat > "$repoC/scripts/lib/qmd-bin.sh" <<'SH'
qmd_install() {
  : > luna.marker
}
# CR fix (CodeRabbit round 19): stub mirrors the real qmd-bin.sh contract —
# qmd_register_collection <path> <name>. Records each registered NAME ($2; the
# path is $1 and irrelevant to the spy) so the assertions below prove the qmd
# install flow wires BOTH the himmel and luna collections, not just the binary
# (qmd_install alone leaves the qmd-index probe red).
qmd_register_collection() {
  [ -n "${QMD_REG_LOG_C:-}" ] && echo "$2" >> "$QMD_REG_LOG_C"
}
SH
targetC="$work/targetC"; mkdir -p "$targetC"
cacheC="$work/cacheC"; mkdir -p "$cacheC"
# CR fix (CodeRabbit round 20): vault.mode=existing + a REAL vault path so
# ctx.vaultPath is non-empty and the qmd install flow actually exercises the
# luna-collection registration it is meant to (a no-vault profile now hits the
# empty-path guard in install-engine.js instead — see case x). profileForVault
# ('existing') is still 'core', so luna-item (profiles:["luna","all"]) stays
# NOT desired under the DERIVED profile; only --profile luna desires it.
vaultC="$work/vaultC"; mkdir -p "$vaultC"
write_cache "$cacheC/install-profile.json" adopter project existing "$vaultC" inline "" lean
qmdRegLogC="$work/qmd-reg-log-c.txt"; : > "$qmdRegLogC"

runEnsureC() {
  ( cd "$targetC" && HIMMELCTL_REPO_ROOT="$(winpath "$repoC")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" HOME="$work/home" QMD_REG_LOG_C="$(winpath "$qmdRegLogC")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
outC0=$(runEnsureC --yes)
echo "$outC0" | grep -qF 'already at the desired state' || fail "case c setup: under profile core, luna-item should not be desired yet (got: $outC0)"
[ ! -f "$targetC/luna.marker" ] || fail "case c setup: luna.marker should not exist before the --profile luna reconcile"

set +e
outC1=$(runEnsureC --profile luna --yes); rcC1=$?
set -e
[ "$rcC1" -eq 0 ] || fail "case c: ensure --profile luna should converge + exit 0 (got rc=$rcC1): $outC1"
[ -f "$targetC/luna.marker" ] || fail "case c: --profile luna should have run the stub qmd_install primitive (luna.marker missing)"
# CR fix (CodeRabbit round 19): the qmd install flow must register BOTH the
# himmel and luna collections (qmd_install alone leaves the qmd-index probe
# red). The stub spy recorded each qmd_register_collection NAME.
grep -qxF 'himmel' "$qmdRegLogC" || fail "case c: qmd install should register the himmel collection (spy log: $(cat "$qmdRegLogC"))"
grep -qxF 'luna' "$qmdRegLogC" || fail "case c: qmd install should register the luna collection (spy log: $(cat "$qmdRegLogC"))"

outC2=$( cd "$targetC" && HIMMELCTL_REPO_ROOT="$(winpath "$repoC")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC")" HOME="$work/home" \
    "$node_bin" "$wizard" status --json </dev/null )
echo "$outC2" | jq -e '.items[] | select(.id=="luna-item") | .severity == "green"' >/dev/null \
  || fail "case c: post-reconcile status should read luna-item green (got: $outC2)"
echo "ok: case c — ensure --profile luna reconciles then converges the luna work list; post-check green"

# ── case i (CR fix, HIMMEL-755): --profile + --dry-run TOGETHER — the
# preview must reflect the in-memory reconcile, not the stale on-disk entry.
# Reuses repoC's manifest/stub (read-only) with a FRESH target/cache so it
# doesn't interact with case c's own (already-converged) state. ───────────
targetI="$work/targetI"; mkdir -p "$targetI"
cacheI="$work/cacheI"; mkdir -p "$cacheI"
# CR fix (CodeRabbit round 20): REAL vault path (same reason as case c) — case i
# previews --profile luna, which desires luna-item (a qmd install); without a
# vault path buildEntry's empty-path guard turns that preview into an
# unrunnable hint instead of the DRY plan line this case asserts.
# profileForVault('existing')='core' keeps the outI0 setup (luna-item not
# desired under the derived profile) intact.
vaultI="$work/vaultI"; mkdir -p "$vaultI"
write_cache "$cacheI/install-profile.json" adopter project existing "$vaultI" inline "" lean

runEnsureI() {
  ( cd "$targetI" && HIMMELCTL_REPO_ROOT="$(winpath "$repoC")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheI")" HOME="$work/home" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
# Seed under core (the ONE sanctioned derive-if-missing write) BEFORE the
# purity snapshot — luna-item is not yet desired, same as case c's setup.
outI0=$(runEnsureI --yes)
echo "$outI0" | grep -qF 'already at the desired state' || fail "case i setup: under profile core, luna-item should not be desired yet (got: $outI0)"

snapIBefore=$(snapshot_dir "$work")
outI1=$(runEnsureI --profile luna --dry-run)
echo "$outI1" | grep -qF 'luna-item' \
  || fail "case i: ensure --profile luna --dry-run should PREVIEW luna-item's convergence (proving the reconcile is reflected) (got: $outI1)"
echo "$outI1" | grep -q 'DRY:' || fail "case i: --profile luna --dry-run should print DRY plan lines (got: $outI1)"
[ ! -f "$targetI/luna.marker" ] || fail "case i: --dry-run must NOT have invoked the stub primitive (luna.marker exists)"
snapIAfter=$(snapshot_dir "$work")
[ "$snapIBefore" = "$snapIAfter" ] || fail "case i: ensure --profile luna --dry-run should make ZERO mutations (no state.json write either)"
echo "ok: case i — ensure --profile X --dry-run previews the reconciled profile's work list (not the stale on-disk profile); zero mutation"

# ── case x (CR fix, CodeRabbit round 20): a no-vault adopter running
# --profile luna must NOT reach qmd_register_collection with an empty path.
# vault.mode=none -> ctx.vaultPath='' (bin.js: vaultPath stays '' when
# vault.mode='none'); qmd-binary/qmd-index are profiles:["luna","all"], so
# under --profile luna luna-item IS desired+red even with NO vault. The
# install-engine.js 'qmd' guard returns a hint-only unrunnable entry instead
# of building the broken `qmd_register_collection "" luna` command, so the
# stub spy log (QMD_REG_LOG_C) stays EMPTY — proving no corrupt empty-path
# registration was attempted — and ensure surfaces the hint. Reuses repoC's
# manifest/stub (read-only) with a FRESH no-vault target/cache so it never
# touches case c/i state. ────────────────────────────────────────────────────
targetX="$work/targetX"; mkdir -p "$targetX"
cacheX="$work/cacheX"; mkdir -p "$cacheX"
write_cache "$cacheX/install-profile.json" adopter project none "" inline "" lean
qmdRegLogX="$work/qmd-reg-log-x.txt"; : > "$qmdRegLogX"

set +e
outX=$( cd "$targetX" && HIMMELCTL_REPO_ROOT="$(winpath "$repoC")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheX")" HOME="$work/home" QMD_REG_LOG_C="$(winpath "$qmdRegLogX")" \
    "$node_bin" "$wizard" ensure --profile luna --yes 2>&1 </dev/null ); rcX=$?
set -e
# CR fix (CodeRabbit round 22, MAJOR — a REAL false green): assert the run
# FAILED CLOSED (rcX nonzero). rcX was captured but never checked, so a
# regression that printed the hint below AND returned 0 would sail past every
# text-only assertion in this case — the exact false-green class this whole
# PR has been fighting (an unrunnable qmd entry reported as success). rcX is
# nonzero BY DESIGN here, not a section-4.5 hint-only exemption: luna-item is
# a runnable-type item (qmd) whose buildEntry returns {unrunnable} for the
# empty vault path, so runInstall records it in failed[] and ensure exits 1
# at the post-check — the established winget-precedent fail-closed behaviour.
# Assert the EXIT, not just the printed text.
[ "$rcX" -ne 0 ] \
  || fail "case x: a no-vault --profile luna run must FAIL CLOSED (nonzero exit) after surfacing the hint — got rc=0 (the hint printed but ensure returned success: a false green). out: $outX"
# The guard must surface the hint naming the missing vault path...
echo "$outX" | grep -qF 'no luna vault path configured' \
  || fail "case x: a no-vault --profile luna run must surface the 'no luna vault path configured' hint (got: $outX)"
# ...and must NEVER invoke qmd_register_collection (empty path or otherwise) —
# the spy log stays empty, proving no corrupt registration was attempted.
[ ! -s "$qmdRegLogX" ] || fail "case x: qmd_register_collection must NOT be invoked with an empty path (spy log: $(cat "$qmdRegLogX"))"
# qmd_install (which creates luna.marker) lives in the SAME unrunnable command,
# so it must not have fired either — the whole qmd entry is hint-only.
[ ! -f "$targetX/luna.marker" ] || fail "case x: the unrunnable qmd entry must not have spawned qmd_install (luna.marker exists)"
echo "ok: case x — a no-vault --profile luna run surfaces the hint and never invokes qmd_register_collection with an empty path (rc=$rcX)"

# ── case e: a 6-red fixture pinned to PER-ITEM install types drives EXACTLY
# 6 primitive invocations in deps[] order. CR fix: the item DECLARATIONS
# below are in scrambled/reverse order (build-a first, wire-a last) while
# every `deps` relationship (and the expected wire-a..build-a invocation
# sequence below) is UNCHANGED — a planner that just iterated declaration
# order instead of actually resolving deps[] would emit build-a first and
# fail this test; the original items-already-in-dependency-order fixture
# could never have caught that class of bug. ───────────────────────────────
repoE="$work/repoE"
mkdir -p "$repoE/scripts/install" "$repoE/scripts/lib" "$repoE/scripts/machine-setup" "$repoE/scripts/jira"
cat > "$repoE/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "build-a", "kind": "dep", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["dep-a"],
      "probe": { "type": "file-exists", "path": "build-a.marker" },
      "install": { "type": "build", "target": "jira-cli" }
    },
    {
      "id": "dep-a", "kind": "dep", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["qmd-a"],
      "probe": { "type": "dep", "cmd": "git" },
      "install": { "type": "dep" }
    },
    {
      "id": "qmd-a", "kind": "vault", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["plugins-a"],
      "probe": { "type": "file-exists", "path": "qmd-a.marker" },
      "install": { "type": "qmd" }
    },
    {
      "id": "plugins-a", "kind": "plugin", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["wire-b"],
      "probe": { "type": "file-exists", "path": "plugins-a.marker" },
      "install": { "type": "plugins" }
    },
    {
      "id": "wire-b", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["wire-a"],
      "probe": { "type": "file-exists", "path": "wire-b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" }
    },
    {
      "id": "wire-a", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "wire-a.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repoE/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "wire-a" >> "$ENSURE_LOG"
exit 0
SH
cat > "$repoE/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "wire-b" >> "$ENSURE_LOG"
exit 0
SH
cat > "$repoE/scripts/machine-setup/install-plugins.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "plugins-a" >> "$ENSURE_LOG"
exit 0
SH
cat > "$repoE/scripts/lib/qmd-bin.sh" <<'SH'
qmd_install() {
  [ -n "${ENSURE_LOG:-}" ] && echo "qmd-a" >> "$ENSURE_LOG"
}
# CR fix (CodeRabbit round 19): the qmd install flow now also calls
# qmd_register_collection (the real qmd-bin.sh contract). This spy-only stub
# defines it as a no-op so the qmd command stays exit-0; the invocation-ORDER
# assertion (qmd_install logging "qmd-a" 4th of 6) is what this case proves.
qmd_register_collection() { :; }
SH

targetE="$work/targetE"; mkdir -p "$targetE"
cacheE="$work/cacheE"; mkdir -p "$cacheE"
# CR fix (CodeRabbit round 20): REAL vault path — this fixture includes qmd-a (a
# qmd install item) to exercise the qmd dispatch in the 6-invocation order; a
# no-vault profile now hits the empty-path guard instead, so qmd-a would never
# dispatch and the 6-count assertion below would break. profileForVault
# ('existing')='core' keeps all six items (profiles:["core","all"]) desired.
vaultE="$work/vaultE"; mkdir -p "$vaultE"
write_cache "$cacheE/install-profile.json" adopter project existing "$vaultE" inline "" lean
logE="$work/ensure-log-e.txt"; : > "$logE"

# exit code deliberately not captured: dep-a/build-a never actually converge
# to green in this spy-only fixture (expected, irrelevant here) — the
# ASSERTION is the invocation log, not the exit code.
outE=$( cd "$targetE" && HIMMELCTL_REPO_ROOT="$(winpath "$repoE")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheE")" HOME="$work/home" \
    PATH="$hermeticPath" ENSURE_LOG="$(winpath "$logE")" \
    "$node_bin" "$wizard" ensure --yes </dev/null ) || true
lineCountE=$(wc -l < "$logE" | tr -d ' ')
[ "$lineCountE" -eq 6 ] || fail "case e: expected EXACTLY 6 primitive invocations (got $lineCountE); log: $(cat "$logE"); ensure output: $outE"
# CR fix: mapfile is bash 4+ (macOS ships bash 3.2) — a portable
# read-append loop instead.
logLinesE=()
while IFS= read -r _l; do logLinesE+=("$_l"); done < "$logE"
expectedE=(wire-a wire-b plugins-a qmd-a dep-a build-a)
for i in 0 1 2 3 4 5; do
  [ "${logLinesE[$i]}" = "${expectedE[$i]}" ] || fail "case e: invocation #$((i+1)) should be '${expectedE[$i]}' (got '${logLinesE[$i]}'); full log: $(cat "$logE")"
done
echo "ok: case e — a 6-red per-item-type fixture drives EXACTLY 6 primitive invocations in deps[] order"

# ── case f: a 2-adopt-red fixture coalesces to EXACTLY 1 adopt.sh invocation
repoF="$work/repoF"; mkdir -p "$repoF/scripts/install"
cat > "$repoF/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "adopt-1", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "adopt1.marker" },
      "install": { "type": "adopt" }
    },
    {
      "id": "adopt-2", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["adopt-1"],
      "probe": { "type": "file-exists", "path": "adopt2.marker" },
      "install": { "type": "adopt" }
    }
  ]
}
JSON
cat > "$repoF/scripts/adopt.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "adopt" >> "$ENSURE_LOG"
exit 0
SH

targetF="$work/targetF"; mkdir -p "$targetF"
cacheF="$work/cacheF"; mkdir -p "$cacheF"
write_cache "$cacheF/install-profile.json" adopter project none "" inline "" lean
logF="$work/ensure-log-f.txt"; : > "$logF"

# exit code deliberately not captured (adopt-1/adopt-2 never actually
# converge in this spy-only fixture) — same rationale as case e above.
outF=$( cd "$targetF" && HIMMELCTL_REPO_ROOT="$(winpath "$repoF")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheF")" HOME="$work/home" \
    ENSURE_LOG="$(winpath "$logF")" \
    "$node_bin" "$wizard" ensure --yes </dev/null ) || true
lineCountF=$(wc -l < "$logF" | tr -d ' ')
[ "$lineCountF" -eq 1 ] || fail "case f: 2 adopt-type reds should coalesce to EXACTLY 1 invocation (got $lineCountF); log: $(cat "$logF"); ensure output: $outF"
echo "ok: case f — 2 adopt-type red items coalesce to exactly 1 adopt.sh invocation"

# ── case h: a red config-type item AND a red no-install item are hint-only
# — never dispatched, never fail-close ensure ──────────────────────────────
repoH="$work/repoH"; mkdir -p "$repoH/scripts/install"
cat > "$repoH/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "config-item", "kind": "dep", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "config.marker" },
      "install": { "type": "config", "key": "SOME_KEY" }
    },
    {
      "id": "mcp-item", "kind": "mcp", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "mcp.marker" }
    }
  ]
}
JSON
targetH="$work/targetH"; mkdir -p "$targetH"
cacheH="$work/cacheH"; mkdir -p "$cacheH"
write_cache "$cacheH/install-profile.json" adopter project none "" inline "" lean
logH="$work/ensure-log-h.txt"; : > "$logH"

set +e
outH=$( cd "$targetH" && HIMMELCTL_REPO_ROOT="$(winpath "$repoH")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheH")" HOME="$work/home" \
    ENSURE_LOG="$(winpath "$logH")" \
    "$node_bin" "$wizard" ensure --yes </dev/null ); rcH=$?
set -e
[ "$rcH" -eq 0 ] || fail "case h: hint-only reds must NOT fail-close ensure (got rc=$rcH): $outH"
[ ! -s "$logH" ] || fail "case h: neither config-item nor mcp-item should ever be dispatched (spy log should stay empty; got: $(cat "$logH"))"
echo "$outH" | grep -qF 'config-item' || fail "case h: the hint message should name config-item (got: $outH)"
echo "$outH" | grep -qF 'mcp-item' || fail "case h: the hint message should name mcp-item (got: $outH)"
echo "ok: case h — a red config-type item and a red no-install item are hint-only: not dispatched, do not fail-close ensure"

# ── case l (CR fix round 3, HIMMEL-755): a genuinely FAILED install must
# fail ensure even when the post-check probe coincidentally reads green
# (the stub touches its marker THEN exits 1 — a realistic "partially
# applied, then crashed" primitive). Previously runInstall's own failed[]
# report was computed but never consulted in the final outcome. ───────────
repoL="$work/repoL"; mkdir -p "$repoL/scripts/install" "$repoL/scripts/lib"
cat > "$repoL/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "coincidence-item", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "external.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repoL/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
touch external.marker
exit 1
SH
targetL="$work/targetL"; mkdir -p "$targetL"
cacheL="$work/cacheL"; mkdir -p "$cacheL"
write_cache "$cacheL/install-profile.json" adopter project none "" inline "" lean

set +e
outL=$( cd "$targetL" && HIMMELCTL_REPO_ROOT="$(winpath "$repoL")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheL")" HOME="$work/home" \
    "$node_bin" "$wizard" ensure --yes 2>&1 </dev/null ); rcL=$?
set -e
[ -f "$targetL/external.marker" ] || fail "case l setup: the stub should have created the marker before exiting 1 (fixture drift)"
[ "$rcL" -ne 0 ] || fail "case l: a genuinely failed install must fail ensure even though the post-check probe reads green (marker exists) (got rc=0): $outL"
echo "$outL" | grep -qF 'coincidence-item' || fail "case l: the failure should name coincidence-item (got: $outL)"
echo "ok: case l — a failed install fails ensure even when the post-check probe coincidentally passes"

# ── case m (CR fix round 3, HIMMEL-755): the toward-disabled loop must
# respect item.scopes — a project-scope run must NEVER process a
# user-only removable item (scope bleed), even though it reads present
# and is not desired. ──────────────────────────────────────────────────────
repoM="$work/repoM"; mkdir -p "$repoM/scripts/install" "$repoM/scripts/lib"
cat > "$repoM/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "user-only-item", "kind": "wiring", "scopes": ["user"], "profiles": ["luna", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "user-only.marker" },
      "install": { "type": "wire", "target": "statusline" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    }
  ]
}
JSON
cat > "$repoM/scripts/lib/unwire-statusline.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${SCOPE_LOG:-}" ] && echo "unwire-invoked" >> "$SCOPE_LOG"
rm -f user-only.marker
exit 0
SH
targetM="$work/targetM"; mkdir -p "$targetM"
# user-only-item's probe reads present (physically "there") — under a
# scope-correct run this alone (not desired, present) would trigger
# toward-disabled; the scope filter must exclude it here regardless.
: > "$targetM/user-only.marker"
cacheM="$work/cacheM"; mkdir -p "$cacheM"
# scope=project (cachedAnswers.scope) -- user-only-item's scopes:["user"]
# excludes it from a PROJECT run's toward-disabled loop entirely.
write_cache "$cacheM/install-profile.json" adopter project none "" inline "" lean
scopeLogM="$work/scope-log-m.txt"; : > "$scopeLogM"

outM=$( cd "$targetM" && HIMMELCTL_REPO_ROOT="$(winpath "$repoM")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheM")" HOME="$work/home" SCOPE_LOG="$(winpath "$scopeLogM")" \
    "$node_bin" "$wizard" ensure --yes </dev/null )
echo "$outM" | grep -qF 'already at the desired state' || fail "case m: a project-scope run should see NOTHING to converge (user-only-item is out of scope) (got: $outM)"
[ ! -s "$scopeLogM" ] || fail "case m: user-only-item's unwire must NEVER be invoked from a project-scope run (spy log: $(cat "$scopeLogM"))"
[ -f "$targetM/user-only.marker" ] || fail "case m: user-only-item's marker must be left untouched (scope bleed would have removed it)"
echo "ok: case m — the toward-disabled loop respects item.scopes; a project-scope run never touches a user-only removable item"

# ── case n (CR fix round 3, HIMMEL-755): hints must be surfaced on EVERY
# path, not only the early "nothing to converge" return — a run that ALSO
# does real convergence work must still print the hint-only items. ───────
repoN="$work/repoN"; mkdir -p "$repoN/scripts/install" "$repoN/scripts/lib"
cat > "$repoN/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "hint-item", "kind": "dep", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "hint.marker" },
      "install": { "type": "config", "key": "SOME_KEY" }
    },
    {
      "id": "real-item", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "real.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repoN/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > real.marker
exit 0
SH
targetN="$work/targetN"; mkdir -p "$targetN"
cacheN="$work/cacheN"; mkdir -p "$cacheN"
write_cache "$cacheN/install-profile.json" adopter project none "" inline "" lean

set +e
outN=$( cd "$targetN" && HIMMELCTL_REPO_ROOT="$(winpath "$repoN")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheN")" HOME="$work/home" \
    "$node_bin" "$wizard" ensure --yes </dev/null ); rcN=$?
set -e
[ "$rcN" -eq 0 ] || fail "case n: real-item should converge cleanly (got rc=$rcN): $outN"
[ -f "$targetN/real.marker" ] || fail "case n: real-item's stub should have run (marker missing)"
echo "$outN" | grep -qF 'hint-item' || fail "case n: hint-item should STILL be surfaced even though real convergence work also happened (got: $outN)"
echo "ok: case n — hints are surfaced even on a run that also does real convergence work"

# ── case o (CR fix round 6, HIMMEL-755): reconcile must run whenever
# --profile is EXPLICITLY supplied, even when it matches the target's
# already-stored profile — a target's per-item enables can go stale (a
# hand-edited state.json here stands in for that; the same code path also
# covers a manifest that gained a new same-profile item since the target
# was last derived) without the profile NAME itself changing. ────────────
repoO="$work/repoO"; mkdir -p "$repoO/scripts/install" "$repoO/scripts/lib"
cat > "$repoO/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "stale-item", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "stale.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repoO/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > stale.marker
exit 0
SH
targetO="$work/targetO"; mkdir -p "$targetO"
cacheO="$work/cacheO"; mkdir -p "$cacheO"
homeO="$work/homeO"; mkdir -p "$homeO"
# vault.mode=none -> profile 'core' -> stale-item IS desired under core.
write_cache "$cacheO/install-profile.json" adopter project none "" inline "" lean

runEnsureO() {
  ( cd "$targetO" && HIMMELCTL_REPO_ROOT="$(winpath "$repoO")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheO")" HOME="$homeO" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
# Bootstrap: derive under profile core AND converge (stale-item is freshly
# desired+red -> the stub runs -> stale.marker created).
set +e
outO_setup=$(runEnsureO --yes); rcO_setup=$?
set -e
[ "$rcO_setup" -eq 0 ] || fail "case o setup: the initial bootstrap converge should exit 0 (got rc=$rcO_setup): $outO_setup"
[ -f "$targetO/stale.marker" ] || fail "case o setup: stale.marker should exist after the initial bootstrap converge"

# Hand-corrupt state.json: flip stale-item's enabled to false WITHOUT
# changing the target's stored profile ('core' stays 'core') — simulates
# staleness that a profile-string comparison alone can't detect. Also
# remove the marker (simulating the wiring having drifted/reverted
# out-of-band) so re-converging it is observable.
STATE_LIB_PATH="$(winpath "$repo_root/scripts/himmelctl/lib/state.js")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$cacheO")" HOME="$homeO" "$node_bin" -e "
const state = require(process.env.STATE_LIB_PATH);
const s = state.load();
const key = Object.keys(s.targets)[0];
s.targets[key].items['stale-item'].enabled = false;
state.save(s);
"
rm -f "$targetO/stale.marker"

# Sanity: with the corruption in place and NO --profile, stale-item reads
# as not-desired (fixture-drift guard for the corruption step itself).
outO0=$(runEnsureO --yes)
echo "$outO0" | grep -qF 'already at the desired state' \
  || fail "case o setup: after corrupting state.json, a plain ensure (no --profile) should see nothing to converge (got: $outO0)"
[ ! -f "$targetO/stale.marker" ] || fail "case o setup: stale.marker should not exist yet (fixture drift)"

# case o: --profile core (SAME as the target's already-stored profile)
# must still reconcile and pick stale-item back up.
set +e
outO1=$(runEnsureO --profile core --yes); rcO1=$?
set -e
[ "$rcO1" -eq 0 ] || fail "case o: ensure --profile core (matching the stored profile) should reconcile + converge (got rc=$rcO1): $outO1"
[ -f "$targetO/stale.marker" ] || fail "case o: --profile core should have reconciled stale-item back to enabled:true and converged it (stale.marker missing)"
echo "ok: case o — an explicit --profile matching the target's stored profile still reconciles and picks up a stale item"

# ── cases p/q/r (CR fix, HIMMEL-755): --items must not break dependency
# closure. planInstall's DFS treats a dep OUTSIDE the given item set as
# already-satisfied — valid for a full run, false under --items when a red
# prerequisite is excluded by the filter alone. item-b deps on item-a; both
# desired under profile core (matches write_cache's vault.mode=none). ─────
repoPQR="$work/repoPQR"; mkdir -p "$repoPQR/scripts/install" "$repoPQR/scripts/lib"
cat > "$repoPQR/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-a", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "item-a.marker" },
      "install": { "type": "wire", "target": "statusline" }
    },
    {
      "id": "item-b", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["item-a"],
      "probe": { "type": "file-exists", "path": "item-b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" }
    }
  ]
}
JSON
cat > "$repoPQR/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > item-a.marker
[ -n "${ENSURE_LOG:-}" ] && echo "item-a" >> "$ENSURE_LOG"
exit 0
SH
cat > "$repoPQR/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > item-b.marker
[ -n "${ENSURE_LOG:-}" ] && echo "item-b" >> "$ENSURE_LOG"
exit 0
SH

# ── case p: --items item-b alone (item-a, its red prereq, excluded) must be
# REJECTED — exit 2, message names the excluded prereq, and ZERO mutation:
# no marker created, no primitive invoked, state.json never even written
# (the validation runs before ensureTarget's derive-if-missing save). ──────
targetP="$work/targetP"; mkdir -p "$targetP"
cacheP="$work/cacheP"; mkdir -p "$cacheP"
homeP="$work/homeP"; mkdir -p "$homeP"
write_cache "$cacheP/install-profile.json" adopter project none "" inline "" lean
logP="$work/ensure-log-p.txt"; : > "$logP"
set +e
outP=$( cd "$targetP" && HIMMELCTL_REPO_ROOT="$(winpath "$repoPQR")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheP")" HOME="$homeP" ENSURE_LOG="$(winpath "$logP")" \
    "$node_bin" "$wizard" ensure --items item-b --yes 2>&1 </dev/null ); rcP=$?
set -e
[ "$rcP" -eq 2 ] || fail "case p: --items item-b (prereq item-a excluded) should exit 2 (got rc=$rcP): $outP"
echo "$outP" | grep -qF 'item-a' || fail "case p: the rejection should name the excluded prerequisite item-a (got: $outP)"
echo "$outP" | grep -qF 'item-b' || fail "case p: the rejection should name the requesting item item-b (got: $outP)"
[ ! -s "$logP" ] || fail "case p: no primitive should have been invoked (spy log: $(cat "$logP"))"
[ ! -f "$targetP/item-a.marker" ] || fail "case p: item-a.marker must NOT exist (zero mutation)"
[ ! -f "$targetP/item-b.marker" ] || fail "case p: item-b.marker must NOT exist (zero mutation)"
[ ! -f "$cacheP/state.json" ] || fail "case p: state.json must NOT be written — the closure check runs before any save"
echo "ok: case p — --items excluding a red prerequisite is REJECTED (exit 2, names the prereq), zero mutation"

# ── case q: --items item-a,item-b (the FULL closure) proceeds and converges
# both, in dependency order (item-a before item-b). ─────────────────────────
targetQ="$work/targetQ"; mkdir -p "$targetQ"
cacheQ="$work/cacheQ"; mkdir -p "$cacheQ"
homeQ="$work/homeQ"; mkdir -p "$homeQ"
write_cache "$cacheQ/install-profile.json" adopter project none "" inline "" lean
logQ="$work/ensure-log-q.txt"; : > "$logQ"
set +e
outQ=$( cd "$targetQ" && HIMMELCTL_REPO_ROOT="$(winpath "$repoPQR")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheQ")" HOME="$homeQ" ENSURE_LOG="$(winpath "$logQ")" \
    "$node_bin" "$wizard" ensure --items item-a,item-b --yes </dev/null ); rcQ=$?
set -e
[ "$rcQ" -eq 0 ] || fail "case q: --items item-a,item-b (full closure) should converge both and exit 0 (got rc=$rcQ): $outQ"
[ -f "$targetQ/item-a.marker" ] || fail "case q: item-a.marker should exist"
[ -f "$targetQ/item-b.marker" ] || fail "case q: item-b.marker should exist"
logLinesQ=()
while IFS= read -r _l; do logLinesQ+=("$_l"); done < "$logQ"
[ "${#logLinesQ[@]}" -eq 2 ] || fail "case q: expected exactly 2 primitive invocations (got ${#logLinesQ[@]}); log: $(cat "$logQ")"
[ "${logLinesQ[0]}" = "item-a" ] || fail "case q: item-a (the prerequisite) should run FIRST (got: ${logLinesQ[0]})"
[ "${logLinesQ[1]}" = "item-b" ] || fail "case q: item-b (the dependent) should run SECOND (got: ${logLinesQ[1]})"
echo "ok: case q — --items naming the FULL closure proceeds and converges both, in dependency order"

# ── case r: item-a is already GREEN (converged in a prior run) and excluded
# from --items — no false rejection, since an already-satisfied dep is
# exactly what the "excluded == already satisfied" assumption legitimately
# covers. Same target/cache reused across both steps. ──────────────────────
targetR="$work/targetR"; mkdir -p "$targetR"
cacheR="$work/cacheR"; mkdir -p "$cacheR"
homeR="$work/homeR"; mkdir -p "$homeR"
write_cache "$cacheR/install-profile.json" adopter project none "" inline "" lean
logR="$work/ensure-log-r.txt"; : > "$logR"
runEnsureR() {
  ( cd "$targetR" && HIMMELCTL_REPO_ROOT="$(winpath "$repoPQR")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheR")" HOME="$homeR" ENSURE_LOG="$(winpath "$logR")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
set +e
outR0=$(runEnsureR --items item-a --yes); rcR0=$?
set -e
[ "$rcR0" -eq 0 ] || fail "case r setup: converging item-a alone should exit 0 (got rc=$rcR0): $outR0"
[ -f "$targetR/item-a.marker" ] || fail "case r setup: item-a.marker should exist after converging item-a alone"
set +e
outR1=$(runEnsureR --items item-b --yes); rcR1=$?
set -e
[ "$rcR1" -eq 0 ] || fail "case r: --items item-b (item-a already green + excluded) should proceed, NOT be rejected (got rc=$rcR1): $outR1"
[ -f "$targetR/item-b.marker" ] || fail "case r: item-b.marker should exist after converging item-b"
logLinesR=()
while IFS= read -r _l; do logLinesR+=("$_l"); done < "$logR"
[ "${#logLinesR[@]}" -eq 2 ] || fail "case r: expected exactly 2 primitive invocations across both steps (got ${#logLinesR[@]}); log: $(cat "$logR")"
[ "${logLinesR[1]}" = "item-b" ] || fail "case r: the second invocation should be item-b (got: ${logLinesR[1]})"
echo "ok: case r — an already-GREEN excluded dep does not trigger a false closure rejection"

# ── case s (CR fix, HIMMEL-755 manifest-authoring bug): pre-commit-hooks
# must be HINT-ONLY, not dispatched via adopt.sh. adopt.sh never lays a
# .pre-commit-config.yaml into an adopted project (status-report.js's own
# carry-forward comment documents this explicitly: "does THIS project carry
# the gate" is a legitimate read-only signal, not a broken install) — a
# prior manifest.json authoring mistake gave it install:{type:"adopt"}
# anyway, which would have made a genuinely fine machine fail-close FOREVER
# (adopt.sh runs, the post-check still reads red, ensure never converges).
# Reproduces the item's EXACT real shape (id/kind/scopes/profiles/probe/
# removable, post-fix: no `install` key) with an adopt.sh SPY stub to
# definitively prove it is never invoked. ───────────────────────────────────
repoS="$work/repoS"; mkdir -p "$repoS/scripts/install" "$repoS/scripts"
cat > "$repoS/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "pre-commit-hooks", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": ".pre-commit-config.yaml" },
      "removable": "full-offboard-only"
    }
  ]
}
JSON
cat > "$repoS/scripts/adopt.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${ENSURE_LOG:-}" ] && echo "adopt.sh-INVOKED" >> "$ENSURE_LOG"
exit 0
SH
targetS="$work/targetS"; mkdir -p "$targetS"
cacheS="$work/cacheS"; mkdir -p "$cacheS"
write_cache "$cacheS/install-profile.json" adopter project none "" inline "" lean
logS="$work/ensure-log-s.txt"; : > "$logS"

set +e
outS=$( cd "$targetS" && HIMMELCTL_REPO_ROOT="$(winpath "$repoS")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheS")" HOME="$work/homeS" \
    ENSURE_LOG="$(winpath "$logS")" \
    "$node_bin" "$wizard" ensure --yes </dev/null ); rcS=$?
set -e
[ "$rcS" -eq 0 ] || fail "case s: pre-commit-hooks as a hint must NOT fail-close ensure (got rc=$rcS): $outS"
[ ! -s "$logS" ] || fail "case s: adopt.sh must NEVER be invoked for pre-commit-hooks (spy log should stay empty; got: $(cat "$logS"))"
echo "$outS" | grep -qF 'pre-commit-hooks' || fail "case s: the hint message should name pre-commit-hooks (got: $outS)"
echo "ok: case s — pre-commit-hooks is hint-only: ensure reports it as a hint, never dispatches adopt.sh, exits 0"

# ── case t (CR fix, MAJOR — the toward-ENABLED mirror of case k's bug):
# being NAMED in --items does NOT mean a dependency will actually be
# installed this run — a hint-only prerequisite (no runnable install
# descriptor, e.g. a config-type item) NEVER lands in towardEnabled no
# matter how it's selected, so a dependent naming it as a dep must still be
# REJECTED even when the prereq is explicitly included in --items. ────────
repoT="$work/repoT"; mkdir -p "$repoT/scripts/install" "$repoT/scripts/lib"
cat > "$repoT/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "hint-prereq", "kind": "dep", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "config.marker" },
      "install": { "type": "config", "key": "SOME_KEY" }
    },
    {
      "id": "dependent-item", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["hint-prereq"],
      "probe": { "type": "file-exists", "path": "dependent.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repoT/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > dependent.marker
exit 0
SH
targetT="$work/targetT"; mkdir -p "$targetT"
cacheT="$work/cacheT"; mkdir -p "$cacheT"
homeT="$work/homeT"; mkdir -p "$homeT"
write_cache "$cacheT/install-profile.json" adopter project none "" inline "" lean

# Both items named in --items -- hint-prereq is desired+red but hint-only,
# so it will NEVER be dispatched; dependent-item must still be REJECTED,
# not installed on top of the missing prereq.
set +e
outT=$( cd "$targetT" && HIMMELCTL_REPO_ROOT="$(winpath "$repoT")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheT")" HOME="$homeT" \
    "$node_bin" "$wizard" ensure --items dependent-item,hint-prereq --yes 2>&1 </dev/null ); rcT=$?
set -e
[ "$rcT" -eq 2 ] || fail "case t: --items dependent-item,hint-prereq (prereq included but hint-only) should exit 2 (got rc=$rcT): $outT"
echo "$outT" | grep -qF 'dependent-item' || fail "case t: the rejection should name dependent-item (got: $outT)"
echo "$outT" | grep -qF 'hint-prereq' || fail "case t: the rejection should name hint-prereq (got: $outT)"
[ ! -f "$targetT/dependent.marker" ] || fail "case t: dependent.marker must NOT exist (zero mutation — dependent-item was never installed)"
echo "ok: case t — --items naming a hint-only prerequisite is REJECTED too (membership alone was never sufficient on the enabled side either), zero mutation"

# ── case u (CR fix, codex round 4, Suggestion — audit of the toward-enabled
# sibling message): a hint-only prerequisite EXCLUDED from --items entirely
# (never named at all) must give the SAME useful "converge it manually"
# guidance as case t's included-but-hint-only variant, not the "add it:
# --items ..." advice — that advice would resolve nothing (hint-prereq
# would still never land in towardEnabled after being added, only walking
# the operator into case t's rejection on a second attempt instead of
# telling them the real fix immediately). Reuses repoT/targetT — case t's
# run above was a zero-mutation rejection, so the fixture is still clean.
set +e
outU=$( cd "$targetT" && HIMMELCTL_REPO_ROOT="$(winpath "$repoT")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheT")" HOME="$homeT" \
    "$node_bin" "$wizard" ensure --items dependent-item --yes 2>&1 </dev/null ); rcU=$?
set -e
[ "$rcU" -eq 2 ] || fail "case u: --items dependent-item (hint-prereq excluded entirely) should exit 2 (got rc=$rcU): $outU"
echo "$outU" | grep -qF 'dependent-item' || fail "case u: the rejection should name dependent-item (got: $outU)"
echo "$outU" | grep -qF 'hint-prereq' || fail "case u: the rejection should name hint-prereq (got: $outU)"
if echo "$outU" | grep -qF 'add it: --items'; then
  fail "case u: the rejection must NOT advise adding hint-prereq to --items -- it's hint-only and would never converge even if added (got: $outU)"
fi
echo "$outU" | grep -qF 'hint-only' || fail "case u: the rejection should say hint-prereq is hint-only (got: $outU)"
[ ! -f "$targetT/dependent.marker" ] || fail "case u: dependent.marker must NOT exist (zero mutation)"
echo "ok: case u — a hint-only prerequisite excluded from --items entirely gets the same 'converge manually' guidance as being named-but-hint-only, never the useless 'add it' advice"

# ── case v (CR fix, CodeRabbit round 18, HIMMEL-755): --profile reconcile must
# key off the AUTHORITATIVE invocation scope (cachedAnswers.scope), not the
# target entry's PERSISTED scope field — which can drift from the key it lives
# under (a hand-edited state.json, or an entry predating a schema change).
# reconcileTarget() recomputes its OWN key via targetKeyForScope(scope), so a
# stale target.scope made the pre-fix call write to a DIFFERENT entry than the
# one being ensured: a project-scope `ensure --profile core` run from /foo
# whose persisted entry claimed scope:'user' would reconcile the USER target
# (writing project-derived membership into it) and leave /foo's entry stale —
# a silent false-no-op on exactly the items the operator asked to reconcile,
# PLUS collateral damage to the other scope's entry. This case builds exactly
# that drift (a project entry whose persisted scope field says 'user') and
# asserts BOTH that the PROJECT entry got reconciled (drift-item re-enabled +
# converged) AND, critically, that the spurious 'user' entry was NEVER created.
# The second assertion is the one that actually discriminates the bug. ──────
repoV="$work/repoV"; mkdir -p "$repoV/scripts/install" "$repoV/scripts/lib"
cat > "$repoV/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "drift-item", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "drift.marker" },
      "install": { "type": "wire", "target": "statusline" }
    }
  ]
}
JSON
cat > "$repoV/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > drift.marker
exit 0
SH
targetV="$work/targetV"; mkdir -p "$targetV"
cacheV="$work/cacheV"; mkdir -p "$cacheV"
homeV="$work/homeV"; mkdir -p "$homeV"
# project scope (cachedAnswers.scope) — the authoritative target key is the
# absolute cwd (<abs targetV>).
write_cache "$cacheV/install-profile.json" adopter project none "" inline "" lean

runEnsureV() {
  ( cd "$targetV" && HIMMELCTL_REPO_ROOT="$(winpath "$repoV")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheV")" HOME="$homeV" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}
# Bootstrap: derive + converge the project entry at <abs targetV> (its scope
# field is 'project' here — the corruption below introduces the drift).
set +e
outV_setup=$(runEnsureV --yes); rcV_setup=$?
set -e
[ "$rcV_setup" -eq 0 ] || fail "case v setup: the initial bootstrap converge should exit 0 (got rc=$rcV_setup): $outV_setup"
[ -f "$targetV/drift.marker" ] || fail "case v setup: drift.marker should exist after the initial bootstrap converge"

# Hand-corrupt state.json: leave the entry at the PROJECT key <abs targetV>
# but overwrite its PERSISTED scope field to 'user' (the drift a hand-edit or
# a pre-schema-change entry can introduce), AND flip drift-item's enabled to
# false WITHOUT changing the stored profile ('core' stays 'core') — so a
# correct reconcile (keyed off the authoritative project scope) re-enables +
# converges it, while a stale-scope-keyed reconcile does not. Then remove the
# marker so re-convergence is observable.
STATE_LIB_PATH="$(winpath "$repo_root/scripts/himmelctl/lib/state.js")" \
  HIMMELCTL_CACHE_DIR="$(winpath "$cacheV")" HOME="$homeV" "$node_bin" -e "
const state = require(process.env.STATE_LIB_PATH);
const s = state.load();
const key = Object.keys(s.targets)[0];
s.targets[key].scope = 'user';
s.targets[key].items['drift-item'].enabled = false;
state.save(s);
"
rm -f "$targetV/drift.marker"

# Sanity: with the corruption in place and NO --profile, drift-item reads as
# not-desired — a fixture-drift guard for the corruption step itself.
outV0=$(runEnsureV --yes)
echo "$outV0" | grep -qF 'already at the desired state' \
  || fail "case v setup: after corrupting state.json, a plain ensure (no --profile) should see nothing to converge (got: $outV0)"
[ ! -f "$targetV/drift.marker" ] || fail "case v setup: drift.marker should not exist yet (fixture drift)"

# case v: --profile core must reconcile the PROJECT entry (re-enable +
# converge drift-item), keyed off the AUTHORITATIVE scope — never create a
# spurious 'user' entry.
set +e
outV1=$(runEnsureV --profile core --yes); rcV1=$?
set -e
[ "$rcV1" -eq 0 ] || fail "case v: ensure --profile core should reconcile + converge (got rc=$rcV1): $outV1"
# Assertion 1: the PROJECT entry got reconciled — drift-item is enabled again
# and converged (marker recreated).
[ -f "$targetV/drift.marker" ] \
  || fail "case v: --profile core should have reconciled drift-item back to enabled:true and converged it (drift.marker missing — reconcile wrote to the WRONG entry)"
# Assertion 2 (THE discriminator): no spurious 'user' entry may exist — a
# pre-fix reconcile keyed off the stale target.scope:'user' would have CREATED
# one here, while statusReport (which already uses the authoritative scope)
# kept reading the untouched project entry.
[ "$(jq '.targets | has("user")' "$cacheV/state.json")" = "false" ] \
  || fail "case v: reconcile must NOT create a 'user' entry (got keys: $(jq -c '.targets | keys' "$cacheV/state.json"))"
[ "$(jq '.targets | length' "$cacheV/state.json")" -eq 1 ] \
  || fail "case v: state.json should carry EXACTLY one target entry (got $(jq '.targets | length' "$cacheV/state.json"))"
echo "ok: case v — --profile reconcile keys off the authoritative scope; the project entry is reconciled and no spurious 'user' entry is created"

# ── case w (CR fix, CodeRabbit round 19): the "N converged" count reports
# MANIFEST ITEMS, not plan ENTRIES. Two COALESCE_TYPES (adopt) items collapse
# to ONE adopt.sh invocation (case f proves the invocation count is 1), yet
# BOTH items converged — so the summary must read "2 converged". The pre-fix
# shape derived the count from runInstall's per-entry report (ran.length=1)
# and silently under-reported. The stub adopt.sh creates BOTH markers so the
# post-check goes green and the success summary actually prints. ───────────
repoW="$work/repoW"; mkdir -p "$repoW/scripts/install"
cat > "$repoW/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "adopt-1", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "adopt1.marker" },
      "install": { "type": "adopt" }
    },
    {
      "id": "adopt-2", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["adopt-1"],
      "probe": { "type": "file-exists", "path": "adopt2.marker" },
      "install": { "type": "adopt" }
    }
  ]
}
JSON
cat > "$repoW/scripts/adopt.sh" <<'SH'
#!/usr/bin/env bash
# Monolithic installer stub: adopt converges the WHOLE core bundle in one
# shot, so a single invocation satisfies BOTH items' markers (the real
# adopt.sh contract planInstall's COALESCE_TYPES relies on).
: > adopt1.marker
: > adopt2.marker
exit 0
SH
targetW="$work/targetW"; mkdir -p "$targetW"
cacheW="$work/cacheW"; mkdir -p "$cacheW"
write_cache "$cacheW/install-profile.json" adopter project none "" inline "" lean

set +e
outW=$( cd "$targetW" && HIMMELCTL_REPO_ROOT="$(winpath "$repoW")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheW")" HOME="$work/home" \
    "$node_bin" "$wizard" ensure --yes </dev/null ); rcW=$?
set -e
[ "$rcW" -eq 0 ] || fail "case w: converging both adopt items should exit 0 (got rc=$rcW): $outW"
[ -f "$targetW/adopt1.marker" ] || fail "case w: adopt1.marker should exist (the coalesced adopt.sh converges both)"
[ -f "$targetW/adopt2.marker" ] || fail "case w: adopt2.marker should exist (the coalesced adopt.sh converges both)"
echo "$outW" | grep -qF 'ensure complete (2 converged)' \
  || fail "case w: 2 coalesced adopt items must report '2 converged' (manifest items), not '1 converged' (the single plan entry / ran.length) (got: $outW)"
echo "ok: case w — coalesced adopt items report the manifest-item count (2 converged), not the plan-entry count"

# ── case y (CR fix, CodeRabbit round 23, MAJOR — toward-ENABLED TRANSITIVE
# closure): the prerequisite walk must be TRANSITIVE, not direct-edges-only.
# Topology A(red,desired) <- B(green) <- C(red,desired): converging C alone
# via `--items C` must be REJECTED naming A, even though C's DIRECT dep B is
# already green. The prior direct-edge loop inspected only C.deps=[B],
# skipped green B via its `severity !== red` guard, and never examined A
# (which lives in B's deps, not C's) — so C installed atop a genuinely
# missing desired+red prerequisite. Reachable state per the CR thread: A
# and B converged earlier, then A removed afterwards — reproduced here by
# deleting a.marker out-of-band between the two runs, leaving B green but
# A red. ─────────────────────────────────────────────────────────────────
repoY="$work/repoY"; mkdir -p "$repoY/scripts/install" "$repoY/scripts/lib"
cat > "$repoY/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    {
      "id": "item-a", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "a.marker" },
      "install": { "type": "wire", "target": "statusline" }
    },
    {
      "id": "item-b", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["item-a"],
      "probe": { "type": "file-exists", "path": "b.marker" },
      "install": { "type": "wire", "target": "pretooluse-hooks" }
    },
    {
      "id": "item-c", "kind": "plugin", "scopes": ["project"], "profiles": ["core", "all"], "deps": ["item-b"],
      "probe": { "type": "file-exists", "path": "c.marker" },
      "install": { "type": "plugins" }
    }
  ]
}
JSON
cat > "$repoY/scripts/lib/wire-statusline.sh" <<'SH'
#!/usr/bin/env bash
: > a.marker
exit 0
SH
cat > "$repoY/scripts/lib/wire-pretooluse-hooks.sh" <<'SH'
#!/usr/bin/env bash
: > b.marker
exit 0
SH
# item-c's plugins stub IS provided (creates c.marker) so the RED proof is
# crisp: under the OLD direct-edges-only code the closure check let
# `--items item-c` proceed, dispatched install-plugins.sh, and C installed
# atop the missing A (rc=0, c.marker created). Under the FIXED code the
# transitive walk rejects BEFORE dispatch (rc=2, c.marker stays absent) —
# so this stub is present-but-unused on the green path, like case s's
# adopt.sh spy.
mkdir -p "$repoY/scripts/machine-setup"
cat > "$repoY/scripts/machine-setup/install-plugins.sh" <<'SH'
#!/usr/bin/env bash
: > c.marker
exit 0
SH
targetY="$work/targetY"; mkdir -p "$targetY"
cacheY="$work/cacheY"; mkdir -p "$cacheY"
homeY="$work/homeY"; mkdir -p "$homeY"
write_cache "$cacheY/install-profile.json" adopter project none "" inline "" lean

runEnsureY() {
  ( cd "$targetY" && HIMMELCTL_REPO_ROOT="$(winpath "$repoY")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheY")" HOME="$homeY" \
      "$node_bin" "$wizard" ensure "$@" </dev/null )
}

# Setup: converge item-a AND item-b together (the full chain — the closure
# check allows it), so both markers exist and both read green.
set +e
outY0=$(runEnsureY --items item-a,item-b --yes); rcY0=$?
set -e
[ "$rcY0" -eq 0 ] || fail "case y setup: converging item-a,item-b should exit 0 (got rc=$rcY0): $outY0"
[ -f "$targetY/a.marker" ] || fail "case y setup: a.marker should exist after converging item-a,item-b"
[ -f "$targetY/b.marker" ] || fail "case y setup: b.marker should exist after converging item-a,item-b"

# Reproduce the CR thread's reachable state — "A removed afterwards": delete
# a.marker out-of-band. Now item-a is red (missing) while item-b is STILL
# green (its marker is present): the GREEN MIDDLE that hid A from the old
# direct-edge loop.
rm -f "$targetY/a.marker"

# case y: `--items item-c` alone. item-c's DIRECT dep item-b is green, but
# item-b's own dep item-a is red+desired+not converging this run — the
# transitive walk must catch A and REJECT (rc=2, naming A), not install C
# atop the missing A.
set +e
outY1=$(runEnsureY --items item-c --yes 2>&1); rcY1=$?
set -e
[ "$rcY1" -eq 2 ] || fail "case y: --items item-c (transitive prereq item-a missing behind green item-b) should exit 2 (got rc=$rcY1): $outY1"
echo "$outY1" | grep -qF 'item-a' || fail "case y: the rejection should name the missing TRANSITIVE prerequisite item-a (got: $outY1)"
echo "$outY1" | grep -qF 'item-c' || fail "case y: the rejection should name the requesting item item-c (got: $outY1)"
[ ! -f "$targetY/c.marker" ] || fail "case y: c.marker must NOT exist (zero mutation — item-c was never installed atop missing item-a)"
echo "ok: case y — a red/desired prerequisite hidden behind a GREEN middle node is still caught by the TRANSITIVE walk (exit 2, names item-a), zero mutation"

echo "PASS"
