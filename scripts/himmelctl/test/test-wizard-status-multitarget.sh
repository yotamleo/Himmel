#!/usr/bin/env bash
# test-wizard-status-multitarget.sh — himmelctl `status` against a state.json
# carrying TWO coexisting targets (HIMMEL-756 T1.8): one project-scope temp
# repo target (keyed by path.resolve(cwd), lib/state.js's targetKeyForScope)
# and one "user" target (the literal "user" key). Mirrors sibling
# test-wizard-status-cmd.sh / test-wizard-status-golden.sh conventions: a
# fake HOME + HIMMELCTL_CACHE_DIR + HIMMELCTL_REPO_ROOT fixture, node
# launched by absolute path, winpath for node.exe's MSYS-path blindness.
#
# Both targets share ONE cache dir (HIMMELCTL_CACHE_DIR), so ONE state.json
# accumulates both entries — install-profile.json's `scope` field is the
# ONLY thing that picks which target a given `status` invocation resolves
# against (project scope -> cwd-keyed; user scope -> the "user" key), and
# it's overwritten between runs the same way a real adopter would re-run
# `install` with a different scope answer. wiring-statusline (settings-key,
# resolves against ctx.targetPath for project scope / $HOME for user scope)
# is the shared litmus item: authored desired-enabled on BOTH target
# entries directly (state.json's own documented schema — see
# lib/state.js's module header), independent of the manifest's own
# scopes:["project"] restriction, which gates deriveTarget()'s natural
# derivation, not the probe or the hand-authored state read here.
#
# Covers:
#   a. status against target A reports A's red/green set; flipping the
#      wiring on B's scope (adding statusLine.command to the user-scope
#      $HOME/.claude/settings.json) does NOT change A's report — and the
#      reverse (flipping A's targetPath-relative settings.json) does NOT
#      change B's report either. Both directions re-probed live (not a
#      cached/stale read) at each step.
#   b. --items subset scoping works per target (each target's run returns
#      exactly the requested ids, scoped to THAT target's own state).
#   c. the state file's OTHER target entry is byte-untouched (jq -S
#      comparison, plus a whole-file sha256) after a run against one target
#      — running against A only ever touches state.targets[[A's key]].

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: sha256sum required" >&2; exit 1; }

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

# write_cache <path> <role> <scope> <vault-mode> <vault-path> <handover-mode>
#             <handover-path> <plugin-set> — a minimal valid Draft-A profile
#             (same shape test-wizard-status-cmd.sh's write_cache writes).
write_cache() {
  cat > "$1" <<JSON
{"role":"$2","tier":"standard","scope":"$3","vault":{"mode":"$4","path":"$5"},"handover":{"mode":"$6","path":"$7"},"pluginSet":"$8","lanes":[],"alwaysOn":false}
JSON
}

# ── shared fixture repo root (HIMMELCTL_REPO_ROOT) ──────────────────────────
fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/install"
cp "$manifest_path" "$fixtureRepo/scripts/install/manifest.json"
fixtureRepo_w="$(winpath "$fixtureRepo")"

# ── target A (project scope) ────────────────────────────────────────────────
targetA="$work/targetA"; mkdir -p "$targetA/.claude"
baselineSettings='{"statusLine":{},"hooks":{"PreToolUse":[]}}'
printf '%s' "$baselineSettings" > "$targetA/.claude/settings.json"

# ── target B (user scope — $HOME/.claude/settings.json) ────────────────────
homeDir="$work/home"; mkdir -p "$homeDir/.claude"
printf '%s' "$baselineSettings" > "$homeDir/.claude/settings.json"

cacheDir="$work/cache"; mkdir -p "$cacheDir"
cacheDir_w="$(winpath "$cacheDir")"

# runA <items-csv> — status against target A (project scope, cwd=targetA).
# Rewrites install-profile.json's scope to 'project' first (shared cache
# dir — the profile records whichever scope a real adopter answered last).
runA() {
  write_cache "$cacheDir/install-profile.json" adopter project none "" inline "" lean
  ( cd "$targetA" && HIMMELCTL_REPO_ROOT="$fixtureRepo_w" HIMMELCTL_CACHE_DIR="$cacheDir_w" HOME="$homeDir" \
      "$node_bin" "$wizard" status --json --items "$1" )
}

# runB <items-csv> — status against target B (user scope; targetPath =
# repoRoot() regardless of cwd, per bin.js's cmdStatus — cwd is irrelevant
# here, so no `cd` is needed).
runB() {
  write_cache "$cacheDir/install-profile.json" adopter user none "" inline "" lean
  ( HIMMELCTL_REPO_ROOT="$fixtureRepo_w" HIMMELCTL_CACHE_DIR="$cacheDir_w" HOME="$homeDir" \
      "$node_bin" "$wizard" status --json --items "$1" )
}

# ── seed both target entries (ensureTarget's derive-and-save, once each),
# then patch wiring-statusline desired-enabled directly on BOTH entries —
# state.json is himmelctl's own documented-schema artifact (lib/state.js),
# authored here independent of the manifest's scopes:["project"] gate
# (which governs deriveTarget()'s natural derivation, not this hand-authored
# read). ─────────────────────────────────────────────────────────────────
runA wiring-statusline >/dev/null || fail "setup: seed run against A failed"
runB wiring-statusline >/dev/null || fail "setup: seed run against B failed"

targetKeys=$(jq -r '.targets | keys[]' "$cacheDir/state.json")
[ "$(echo "$targetKeys" | wc -l)" -eq 2 ] || fail "setup: expected exactly 2 target entries in state.json (got: $targetKeys)"
echo "$targetKeys" | grep -qx 'user' || fail "setup: expected a 'user' target entry (got: $targetKeys)"
targetKeyA=$(echo "$targetKeys" | grep -vx 'user')
[ -n "$targetKeyA" ] || fail "setup: could not identify target A's key"

jq --arg ka "$targetKeyA" '
  .targets[$ka].items["wiring-statusline"].enabled = true |
  .targets["user"].items["wiring-statusline"].enabled = true
' "$cacheDir/state.json" > "$cacheDir/state.json.tmp" && mv "$cacheDir/state.json.tmp" "$cacheDir/state.json"
echo "ok: setup — state.json carries two target entries (A + user), wiring-statusline desired-enabled on both"

sevOf() { # <json>
  echo "$1" | jq -r '.items[0].severity'
}

# ── case (a): baseline — both red (neither settings.json carries the key) ──
sevA0=$(sevOf "$(runA wiring-statusline)")
sevB0=$(sevOf "$(runB wiring-statusline)")
[ "$sevA0" = "red" ] || fail "case a: expected target A baseline severity=red (got: $sevA0)"
[ "$sevB0" = "red" ] || fail "case a: expected target B baseline severity=red (got: $sevB0)"
echo "ok: case a (baseline) — both A and B read red before either is flipped"

# ── case (a): flip B, confirm A is unaffected, confirm B updated ───────────
printf '{"statusLine":{"command":"bash foo.sh"},"hooks":{"PreToolUse":[]}}' > "$homeDir/.claude/settings.json"
sevA1=$(sevOf "$(runA wiring-statusline)")
sevB1=$(sevOf "$(runB wiring-statusline)")
[ "$sevA1" = "red" ] || fail "case a: flipping B's wiring must NOT change A's report (got A severity: $sevA1)"
[ "$sevB1" = "green" ] || fail "case a: B's own report should read green after its wiring was flipped (got: $sevB1)"
printf '%s' "$baselineSettings" > "$homeDir/.claude/settings.json"
echo "ok: case a — toggling B's wiring does not bleed into A's report (A stayed red); B's own report updated correctly"

# ── case (a): flip A, confirm B is unaffected (reverse direction), confirm
# A updated ─────────────────────────────────────────────────────────────
printf '{"statusLine":{"command":"bash foo.sh"},"hooks":{"PreToolUse":[]}}' > "$targetA/.claude/settings.json"
sevB2=$(sevOf "$(runB wiring-statusline)")
sevA2=$(sevOf "$(runA wiring-statusline)")
[ "$sevB2" = "red" ] || fail "case a: flipping A's wiring must NOT change B's report (got B severity: $sevB2)"
[ "$sevA2" = "green" ] || fail "case a: A's own report should read green after its wiring was flipped (got: $sevA2)"
printf '%s' "$baselineSettings" > "$targetA/.claude/settings.json"
echo "ok: case a — toggling A's wiring does not bleed into B's report (B stayed red); A's own report updated correctly (vice versa proven)"

# ── case (c) snapshot point: capture B's exact entry + the whole-file hash
# BEFORE the batch of A-only runs below (both settings.json files are back
# at baseline here, matching the post-setup fixture state). ───────────────
stateBefore=$(sha256sum "$cacheDir/state.json")
userEntryBefore=$(jq -S '.targets["user"]' "$cacheDir/state.json")

# ── case (b): --items subset scoping is per-target ─────────────────────────
outSubA=$(runA "wiring-statusline,jira-cli-dist-build")
countSubA=$(echo "$outSubA" | jq '.items | length')
[ "$countSubA" -eq 2 ] || fail "case b: --items should scope target A's run to exactly 2 items (got $countSubA): $outSubA"
echo "$outSubA" | jq -e '[.items[].id] == ["jira-cli-dist-build","wiring-statusline"]' >/dev/null \
  || fail "case b: --items should scope target A's run to exactly the listed ids (got: $outSubA)"

outSubB=$(runB "wiring-statusline,jira-cli-dist-build")
countSubB=$(echo "$outSubB" | jq '.items | length')
[ "$countSubB" -eq 2 ] || fail "case b: --items should scope target B's run to exactly 2 items (got $countSubB): $outSubB"
echo "$outSubB" | jq -e '[.items[].id] == ["jira-cli-dist-build","wiring-statusline"]' >/dev/null \
  || fail "case b: --items should scope target B's run to exactly the listed ids (got: $outSubB)"
echo "ok: case b — --items subset scoping works independently per target"

# ── case (c): after a batch of runs against A only, B's entry (and the
# whole state.json) is byte-untouched. ─────────────────────────────────────
runA wiring-statusline >/dev/null
runA "wiring-statusline,jira-cli-dist-build" >/dev/null
stateAfter=$(sha256sum "$cacheDir/state.json")
userEntryAfter=$(jq -S '.targets["user"]' "$cacheDir/state.json")
[ "$stateBefore" = "$stateAfter" ] || fail "case c: state.json changed after a batch of runs against A only (expected zero writes — both targets already had entries)"
[ "$userEntryBefore" = "$userEntryAfter" ] || fail "case c: target B's entry changed after runs against A only"
echo "ok: case c — the other target's state entry (and the whole state.json) is byte-untouched after runs against one target"

echo "PASS"
