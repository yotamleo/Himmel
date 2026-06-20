#!/usr/bin/env bash
# check-plugin-drift.sh — proactive upstream-drift report for every
# externally-sourced plugin himmel ships. One command answers "are all our
# forks + pinned plugins current with upstream?" (HIMMEL-322).
#
# Two plugin classes are checked, each against its TRUE upstream via `gh api`:
#   1. Pinned remotes — any plugin in marketplace.json whose source is
#      {github, repo, ref}. Two sub-cases:
#        a. Plain pin (no override): drift = the pinned `ref` (a 40-hex SHA) !=
#           the marketplace repo's default-branch HEAD. (kepano/obsidian.)
#        b. Fork-with-upstream override (scripts/plugin-upstreams.json): the
#           marketplace `repo` is OUR fork, so a HEAD compare would only catch
#           fork-vs-pin drift, never the real signal. The override names the TRUE
#           upstream and `track:release` compares its latest VERSION TAG (highest
#           semver, not the GitHub Releases API which omits tag-only/prereleases)
#           against our recorded `synced_base`. Drift = upstream tagged a newer
#           version than the one our fork is merged to. (claude-obsidian -> AgriciDaniel.)
#           This sub-case also makes tag-name refs (e.g. v1.9.2-himmel.1) work —
#           we never compare a tag name to a SHA.
#   2. Vendored forks — any marketplace/plugins/<p>/UPSTREAM_PIN that carries the
#      generic fields `upstream_repo` / `upstream_path` / `upstream_sha256`. Drift
#      = the recorded sha256 != the sha256 of that upstream file fetched now.
#      (telegram-himmel, pr-review-toolkit-himmel.)
#
# Exit codes (a cadence keys its alert on these):
#   0  every plugin verified CURRENT, OR gh is absent/unauthenticated (fail-open
#      for CI / fresh clones — nothing was claimed, the run was skipped).
#   2  DRIFT — at least one plugin is behind/changed upstream.
#   3  INCOMPLETE — gh is present but one or more checks could not complete
#      (network blip, rate-limit, python3 missing). We never report "all current"
#      when a check silently failed — that would be a dangerous false-negative.
#
# Lean-invoke: run `bash scripts/check-plugin-drift.sh` on demand, or arm it on a
# cadence. NOT a pre-commit hook (a network round-trip per commit is too costly).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Paths are env-overridable so the test harness can point at fixtures.
MJSON="${DRIFT_MJSON:-$ROOT/marketplace/.claude-plugin/marketplace.json}"
UPSTREAMS="${DRIFT_UPSTREAMS:-$ROOT/scripts/plugin-upstreams.json}"  # per-plugin true-upstream overrides (may be absent)

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
  echo "drift-check: gh CLI not available/authenticated — skipping (fail-open)."
  exit 0
fi

drift=0
incomplete=0

echo "== pinned remotes (SHA-pin vs HEAD; fork → true-upstream release) =="
if ! command -v python3 >/dev/null 2>&1; then
  echo "  ? python3 not available — cannot parse marketplace.json; pinned-remote class UNCHECKED."
  incomplete=1
else
  # Capture the parser output + its exit status separately, so a python3 crash
  # (the Windows Store stub can wedge) is treated as UNCHECKED, never as "0 pins".
  # Each line: name|repo|ref|upstream_repo|track|synced_base (last three empty
  # unless scripts/plugin-upstreams.json declares a true-upstream override).
  pins_out="$(python3 - "$MJSON" "$UPSTREAMS" <<'PY' 2>/dev/null | tr -d '\r'
import json, os, sys
m = json.load(open(sys.argv[1]))
ups = {}
if os.path.exists(sys.argv[2]):
    ups = json.load(open(sys.argv[2]))   # malformed -> raises -> class UNCHECKED
for p in m.get("plugins", []):
    s = p.get("source")
    if isinstance(s, dict) and s.get("source") == "github" and s.get("ref"):
        o = ups.get(p["name"]) or {}
        print("|".join([p["name"], s["repo"], s["ref"],
                        o.get("upstream_repo", ""), o.get("track", ""), o.get("synced_base", "")]))
PY
)"
  pins_rc=$?  # pipefail makes this the pipeline's status (= python3's, if it failed)
  if [ "$pins_rc" -ne 0 ]; then
    echo "  ? marketplace.json / plugin-upstreams.json parse failed (python3 error) — pinned-remote class UNCHECKED."
    incomplete=1
  else
    while IFS='|' read -r name repo ref up_repo up_track up_base; do
      [ -n "$name" ] || continue
      # Sub-case (b): fork with a true-upstream override. The marketplace `repo`
      # is OUR fork; check the named upstream's latest STABLE version TAG against
      # synced_base. We use the highest stable semver tag (sort -V), NOT the
      # GitHub Releases API: releases/latest silently omits tag-only releases,
      # which would read as CURRENT while upstream had actually moved — exactly
      # the false-negative this script's header forbids. Prereleases are excluded
      # below (a stale same-version prerelease would otherwise read as BEHIND).
      if [ -n "$up_repo" ]; then
        if [ "$up_track" != "release" ]; then
          echo "  $name: ? upstream override has unknown track='$up_track' — UNCHECKED"
          incomplete=1
          continue
        fi
        # A malformed override (missing synced_base) must be UNCHECKED, never a
        # comparison — else a real upstream tag != "" reads as a phantom BEHIND.
        if [ -z "$up_base" ]; then
          echo "  $name: ? upstream override missing synced_base — UNCHECKED (fix scripts/plugin-upstreams.json)"
          incomplete=1
          continue
        fi
        # Capture raw tags first and gate on gh's EXIT STATUS (a pipe would mask
        # it behind sort/tail). per_page=100 so the newest tag is in the page.
        tags_raw="$(gh api "repos/$up_repo/tags?per_page=100" --jq '.[].name' 2>/dev/null)"; api_rc=$?
        if [ "$api_rc" -ne 0 ] || [ -z "$tags_raw" ]; then
          echo "  $name: ? true upstream unreachable ($up_repo tags) — UNCHECKED"
          incomplete=1
          continue
        fi
        # Consider STABLE version tags only (vMAJOR.MINOR[.PATCH], no -suffix).
        # synced_base is a stable release; including prereleases would let a stale
        # same-version prerelease (e.g. v1.9.2-alpha, which `sort -V` ranks AFTER
        # v1.9.2) be picked as "latest" and read as a phantom BEHIND against a
        # current base. A real new stable release still trips the BEHIND path.
        latest="$(printf '%s\n' "$tags_raw" | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V | tail -1)"
        if [ -z "$latest" ]; then
          echo "  $name: ? no stable version tags found on $up_repo — UNCHECKED"
          incomplete=1
          continue
        fi
        if [ "$latest" = "$up_base" ]; then
          echo "  $name: CURRENT  (fork tracks $up_repo @ $up_base; pin $ref)"
        else
          echo "  $name: BEHIND   ($up_repo latest tag $latest; fork synced to $up_base — re-sync fork, bump synced_base + fork tag, then bump marketplace ref)"
          drift=1
        fi
        continue
      fi
      # Sub-case (a): plain pin — ref must be a 40-hex SHA to compare against HEAD.
      # A non-SHA ref (tag/branch) with no override can't be compared meaningfully.
      if ! printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$'; then
        echo "  $name: ? non-SHA ref '$ref' with no upstream override — UNCHECKED (declare it in scripts/plugin-upstreams.json)"
        incomplete=1
        continue
      fi
      head="$(gh api "repos/$repo/commits/HEAD" --jq '.sha' 2>/dev/null)"; api_rc=$?
      # Gate on gh's EXIT STATUS, not stdout emptiness: gh api prints a non-empty
      # error body to stdout on HTTP 4xx/5xx. Also require a 40-hex sha so any
      # error/`null` payload is UNCHECKED, never compared.
      if [ "$api_rc" -ne 0 ] || ! printf '%s' "$head" | grep -qE '^[0-9a-f]{40}$'; then
        echo "  $name: ? upstream unreachable ($repo) — UNCHECKED"
        incomplete=1
        continue
      fi
      if [ "$ref" = "$head" ]; then
        echo "  $name: CURRENT  ($repo @ ${ref:0:7})"
      else
        delta="$(gh api "repos/$repo/compare/$ref...$head" --jq '.ahead_by' 2>/dev/null)"
        echo "  $name: BEHIND   ($repo upstream is ${delta:-?} commit(s) ahead — pin ${ref:0:7} -> ${head:0:7})"
        drift=1
      fi
    done <<< "$pins_out"
  fi
fi

echo ""
echo "== vendored forks (UPSTREAM_PIN sha vs upstream file now) =="
for pin in "$ROOT"/marketplace/plugins/*/UPSTREAM_PIN; do
  [ -f "$pin" ] || continue
  plug="$(basename "$(dirname "$pin")")"
  urepo="$(sed -n 's/^upstream_repo=//p' "$pin" | head -1)"
  upath="$(sed -n 's/^upstream_path=//p' "$pin" | head -1)"
  usha="$(sed -n 's/^upstream_sha256=//p' "$pin" | head -1)"
  if [ -z "$urepo" ] || [ -z "$upath" ] || [ -z "$usha" ]; then
    echo "  $plug: UPSTREAM_PIN lacks upstream_repo/upstream_path/upstream_sha256 — skipping"
    continue
  fi
  # Capture the raw upstream content FIRST and guard it: an empty/failed fetch
  # must be UNCHECKED, not hashed — sha256sum of empty input is a real digest
  # (e3b0c442…), which would otherwise be mis-reported as DRIFT.
  content="$(gh api "repos/$urepo/contents/$upath" --jq '.content' 2>/dev/null)"; api_rc=$?
  # Gate on gh's exit status (HTTP errors print a non-empty body to stdout) AND
  # on a non-empty payload (directory / >1MB file return content="").
  if [ "$api_rc" -ne 0 ] || [ -z "$content" ]; then
    echo "  $plug: ? upstream file unreachable or not a plain file ($urepo:$upath) — UNCHECKED"
    incomplete=1
    continue
  fi
  # Decode to a temp file (NOT a $(...) capture — that strips trailing newlines
  # and breaks the byte-exact hash) so we can both guard a failed/empty decode
  # AND hash the exact bytes the pin's sha256 was computed over.
  tmp="$(mktemp)"
  printf '%s' "$content" | base64 -d >"$tmp" 2>/dev/null
  dec_rc=${PIPESTATUS[1]:-1}
  if [ "$dec_rc" -ne 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    echo "  $plug: ? upstream content could not be base64-decoded ($urepo:$upath) — UNCHECKED"
    incomplete=1
    continue
  fi
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  rm -f "$tmp"
  if [ "$got" = "$usha" ]; then
    echo "  $plug: CURRENT  (upstream $upath unchanged)"
  else
    echo "  $plug: DRIFT    (upstream $urepo:$upath changed — pinned ${usha:0:12}.. vs now ${got:0:12}..)"
    echo "           re-sync the fork + update UPSTREAM_PIN (see the plugin's README)."
    drift=1
  fi
done

echo ""
if [ "$drift" -ne 0 ]; then
  echo "DRIFT DETECTED — one or more plugins are behind upstream (see above)."
  if [ "$incomplete" -ne 0 ]; then
    echo "NOTE: some checks were also INCOMPLETE (see '? … UNCHECKED' above) — exit 2 takes precedence over exit 3."
  fi
  exit 2
fi
if [ "$incomplete" -ne 0 ]; then
  echo "INCOMPLETE — one or more checks could not complete (see '? … UNCHECKED' above)."
  echo "Not asserting 'current' — re-run when connectivity / tooling is restored."
  exit 3
fi
echo "All himmel-shipped external plugins are current with upstream."
exit 0
