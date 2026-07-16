#!/usr/bin/env bash
# check-plugin-drift.sh — proactive upstream-drift report for every
# externally-sourced plugin himmel ships. One command answers "are all our
# forks + pinned plugins current with upstream?" (HIMMEL-322).
#
# Two plugin classes are checked, each against its TRUE upstream via `gh api`:
#   1. Pinned remotes — any plugin in marketplace.json whose source is a git
#      remote with a ref: {github, repo, ref} or {url, url, ref} (the explicit
#      HTTPS url form claude-obsidian uses after HIMMEL-549). Two sub-cases:
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
#   3. Carried upstreams (HIMMEL-869) — the rest of the fleet that the two
#      classes above don't reach. A data-driven registry
#      (scripts/upstreams.json, DRIFT_REGISTRY-overridable) enumerates each with a
#      detection `kind`:
#        a. commit_head — compare a local commit to the tracked repo's default
#           HEAD. mode `pin` takes the commit from `pinned_commit` (full or short
#           SHA; short is resolved via gh) — for vendored copies that are NOT a
#           git checkout of upstream (claude-hud, claude-statusline). mode
#           `checkout` takes it from a local git checkout at `checkout_path`
#           (env-expanded cross-platform) — for editable/installed checkouts
#           (hermes-agent). Drift = the tracked repo advanced past our commit.
#        b. tag_release — compare a local version to the tracked repo's latest
#           STABLE version tag (highest semver via sort -V, prereleases excluded —
#           same discipline as the claude-obsidian fork override). mode `base`
#           takes the version from `synced_base`; mode `probe` runs
#           `version_command` and extracts the version via `version_regex` — for
#           installed binaries/CLIs (rtk, twitter-cli). Optional `latest_source:
#           release` reads the maintainer's latest-non-prerelease via the Releases
#           API instead of the highest semver tag — for upstreams whose tags are
#           NON-MONOTONIC (a stale higher-semver tag would otherwise be a phantom
#           "latest"; graphify's months-old v1.0.0 vs its current v0.9.x line).
#      Installed marketplaces (caveman, obsidian-skills, openai-codex,
#      claude-video, claude-plugins-official, …) are NOT listed in the registry:
#      they are discovered dynamically from ~/.claude/plugins/known_marketplaces.json
#      (DRIFT_KNOWN_MARKETPLACES-overridable) so the guard auto-covers any future
#      marketplace install, each checked as commit_head/checkout vs its source repo.
#      `tier` (A=proactive / B=reactive, from the HIMMEL-850 audit) is printed in
#      the verdict so a reader can tell expected churn (Tier B usually reads BEHIND
#      by design) from a genuinely stale pin. An absent checkout / uninstalled
#      tool / unreachable upstream is UNCHECKED, never drift.
#
# Additive-only-delta audit (true forks: claude-obsidian, telegram-himmel,
# pr-review-toolkit-himmel, qmd) is a MANUAL step — verifying that each fork's
# diff vs its synced base is the expected whitelisted delta and nothing else is a
# per-fork judgment this script does not automate (the deltas differ per fork and
# are reviewed in their own tickets). One-liner per fork, runnable when gh is up:
#   claude-obsidian:    gh api 'repos/AgriciDaniel/claude-obsidian/compare/v1.9.2...yotamleo:claude-obsidian:v1.9.2-himmel.1'
#   telegram-himmel:    diff the fork's server.ts vs the UPSTREAM_PIN sha256 base
#   pr-review-tk-himmel: diff the fork's agents/code-reviewer.md vs the UPSTREAM_PIN base
#   qmd:                gh api 'repos/tobi/qmd/compare/<base>...yotamleo:qmd:<fork-head>'  (base = last synced tag)
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

# Portable replacement for `sort -V | tail -1`: GNU-only (BSD sort on macOS has
# no -V), which would silently leave `latest`/`hi` empty on macOS and either
# mark a tag_release check UNCHECKED or misreport it as BEHIND. Reads
# newline-separated version strings on stdin (optional leading 'v', extra
# non-numeric suffixes tolerated) and prints the one with the highest
# major.minor.patch — via the python3 this class already requires.
highest_version() {
  python3 -c '
import re, sys

def numprefix(s):
    m = re.match(r"\d+", s)
    return int(m.group()) if m else 0

def key(v):
    v = v.strip().lstrip("vV")
    parts = (v.split(".") + ["0", "0", "0"])[:3]
    return tuple(numprefix(p) for p in parts)

lines = [l.strip() for l in sys.stdin if l.strip()]
if lines:
    print(max(lines, key=key))
'
}

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
def repo_of(s):
    # github source carries owner/repo directly; the explicit-https url source
    # (claude-obsidian after HIMMEL-549) encodes it in the url. repo is only used
    # for the plain-pin HEAD compare + message text — fork overrides ignore it.
    if s.get("source") == "github":
        return s.get("repo", "")
    u = s.get("url", "")
    if "github.com/" in u:
        r = u.split("github.com/", 1)[1].rstrip("/")
        return r[:-4] if r.endswith(".git") else r
    return ""
for p in m.get("plugins", []):
    s = p.get("source")
    if isinstance(s, dict) and s.get("source") in ("github", "url") and s.get("ref"):
        o = ups.get(p["name"]) or {}
        print("|".join([p["name"], repo_of(s), s["ref"],
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
    echo "  $plug: ? UPSTREAM_PIN lacks upstream_repo/upstream_path/upstream_sha256 -- UNCHECKED"
    incomplete=1
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
  if command -v sha256sum >/dev/null 2>&1; then
    hash_out="$(sha256sum "$tmp" 2>/dev/null)"; hash_rc=$?
  elif command -v shasum >/dev/null 2>&1; then
    hash_out="$(shasum -a 256 "$tmp" 2>/dev/null)"; hash_rc=$?
  else
    hash_out=""; hash_rc=127
  fi
  rm -f "$tmp"
  got="$(printf '%s\n' "$hash_out" | awk '{print $1}')"
  if [ "$hash_rc" -ne 0 ] || [ -z "$got" ]; then
    echo "  $plug: ? could not compute sha256 (sha256sum/shasum unavailable or failed) ($urepo:$upath) -- UNCHECKED"
    incomplete=1
    continue
  fi
  if [ "$got" = "$usha" ]; then
    echo "  $plug: CURRENT  (upstream $upath unchanged)"
  else
    echo "  $plug: DRIFT    (upstream $urepo:$upath changed — pinned ${usha:0:12}.. vs now ${got:0:12}..)"
    echo "           re-sync the fork + update UPSTREAM_PIN (see the plugin's README)."
    drift=1
  fi
done

echo ""
echo "== carried upstreams (registry + installed marketplaces; HIMMEL-869) =="
# scripts/upstreams.json enumerates the fleet the two classes above don't reach
# (claude-hud, claude-statusline, hermes-agent, rtk, twitter-cli); installed
# marketplaces are discovered from known_marketplaces.json. Both paths are
# env-overridable so the test harness can point at fixtures / a stubbed gh.
REGISTRY="${DRIFT_REGISTRY:-$ROOT/scripts/upstreams.json}"
KNOWN_MKTS="${DRIFT_KNOWN_MARKETPLACES:-$HOME/.claude/plugins/known_marketplaces.json}"
if ! command -v python3 >/dev/null 2>&1; then
  echo "  ? python3 not available — cannot parse the upstream registry / known marketplaces; carried-upstreams class UNCHECKED."
  incomplete=1
else
  # Emit one line per carried upstream: name<US>kind<US>repo<US>mode<US>v1<US>v2<US>tier,
  # <US> = ASCII unit separator (\x1f), NOT `|` — a probe entry's version_regex
  # can itself contain `|` (regex alternation), which would silently misalign a
  # pipe-delimited protocol. v1/v2 are kind/mode-specific (see header). A
  # malformed JSON file raises -> the pipeline exits non-zero -> class UNCHECKED;
  # a missing/empty file emits nothing (clean).
  reg_out="$(python3 - "$REGISTRY" "$KNOWN_MKTS" <<'PY' 2>/dev/null | tr -d '\r'
import json, os, re, sys
reg_path, mkt_path = sys.argv[1], sys.argv[2]

def expand(p):
    # Cross-platform env expansion ($VAR / ${VAR} / %VAR%) so the same registry
    # entry resolves on Git Bash python AND Windows python, then forward-slash
    # the result so `git -C <path>` is portable.
    if not p:
        return p
    def rep(m):
        return os.environ.get(m.group(1) or m.group(2), '')
    p = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)', rep, p)
    p = re.sub(r'%([A-Za-z_][A-Za-z0-9_]*)%', lambda m: os.environ.get(m.group(1), ''), p)
    return os.path.expanduser(p).replace('\\', '/')

def line(name, kind, repo, mode, v1, v2, tier, extra=''):
    # \x1f (ASCII unit separator), not '|': version_regex (v2, probe mode) can
    # legitimately contain '|' for regex alternation, which would misalign a
    # pipe-delimited record. `extra` (8th field) carries the tag_release
    # `latest_source` ('release' -> read the maintainer's latest-non-prerelease
    # via the Releases API instead of the highest semver tag, for upstreams
    # whose tags are non-monotonic); empty for every other record.
    print('\x1f'.join([name, kind, repo, mode, v1 or '', v2 or '', tier or '', extra or '']))

if os.path.exists(reg_path) and os.path.getsize(reg_path) > 0:
    d = json.load(open(reg_path))   # malformed -> raises -> class UNCHECKED
    for e in d.get('entries', []):
        kind = e.get('kind', '')
        mode = e.get('mode', '')
        repo = e.get('tracked_repo', '')
        tier = e.get('tier', '')
        if kind == 'commit_head' and mode == 'pin':
            line(e['name'], 'commit_head', repo, 'pin', e.get('pinned_commit', ''), '', tier)
        elif kind == 'commit_head' and mode == 'checkout':
            line(e['name'], 'commit_head', repo, 'checkout', expand(e.get('checkout_path', '')), '', tier)
        elif kind == 'tag_release' and mode == 'base':
            line(e['name'], 'tag_release', repo, 'base', e.get('synced_base', ''), '', tier, e.get('latest_source', ''))
        elif kind == 'tag_release' and mode == 'probe':
            line(e['name'], 'tag_release', repo, 'probe', e.get('version_command', ''), e.get('version_regex', ''), tier, e.get('latest_source', ''))
        else:
            # Unrecognized kind/mode: pass it through verbatim so the bash
            # dispatch reports the REAL kind/mode (e.g. a known kind with a bad
            # mode reads as "commit_head mode '<mode>' unknown", not a generic
            # "unknown kind"). Empty kind -> 'unknown' for a stable message.
            line(e.get('name', '?'), kind or 'unknown', repo, mode, '', '', tier)

if os.path.exists(mkt_path) and os.path.getsize(mkt_path) > 0:
    km = json.load(open(mkt_path))   # malformed -> raises -> class UNCHECKED
    for mname, info in km.items():
        src = info.get('source', {}) or {}
        if src.get('source') == 'github' and src.get('repo'):
            tier = 'mkt-auto' if info.get('autoUpdate') else 'mkt-manual'
            loc = info.get('installLocation', '')
            if not loc:
                # Older/foreign known_marketplaces.json shape without
                # installLocation: an empty path would otherwise flow into the
                # checkout-missing branch below and print as "checkout not
                # present on this machine ()" — reads like a real absent
                # checkout instead of a shape gap. Flag it explicitly instead.
                line('mkt:' + mname, 'commit_head', src['repo'], 'no-install-location', '', '', tier)
            else:
                line('mkt:' + mname, 'commit_head', src['repo'], 'checkout',
                     expand(loc), '', tier)
PY
)"
  reg_rc=$?
  if [ "$reg_rc" -ne 0 ]; then
    echo "  ? upstreams.json / known_marketplaces.json parse failed (python3 error) — carried-upstreams class UNCHECKED."
    incomplete=1
  else
    while IFS=$'\x1f' read -r name kind repo mode v1 v2 tier latest_src; do
      [ -n "$name" ] || continue
      tier_note=""
      if [ -n "$tier" ]; then tier_note="  [$tier]"; fi
      case "$kind" in
        commit_head)
          # Resolve the LOCAL commit: a pinned SHA, or the HEAD of a checkout.
          if [ "$mode" = "pin" ]; then
            local_ref="$v1"
            if [ -z "$local_ref" ]; then
              echo "  $name: ? entry missing pinned_commit — UNCHECKED (fix scripts/upstreams.json)"
              incomplete=1; continue
            fi
          elif [ "$mode" = "checkout" ]; then
            path="$v1"
            if [ -z "$path" ] || [ ! -d "$path" ]; then
              echo "  $name: ? checkout not present on this machine ($path) — UNCHECKED"
              incomplete=1; continue
            fi
            if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
              echo "  $name: ? checkout is not a git repo ($path) — UNCHECKED"
              incomplete=1; continue
            fi
            local_ref="$(git -C "$path" rev-parse HEAD 2>/dev/null)"
            if [ -z "$local_ref" ]; then
              echo "  $name: ? could not read HEAD of checkout ($path) — UNCHECKED"
              incomplete=1; continue
            fi
          elif [ "$mode" = "no-install-location" ]; then
            # Older/foreign known_marketplaces.json entry shape: github-sourced
            # but no installLocation field to check out. Skip with a named,
            # explicit UNCHECKED note — never let an empty path fall through to
            # the checkout branch above (that would print "()" and read like a
            # real absent checkout instead of a metadata-shape gap).
            echo "  $name: ? marketplace entry lacks installLocation (older/foreign metadata shape) — UNCHECKED${tier_note}"
            incomplete=1; continue
          else
            echo "  $name: ? commit_head mode '$mode' unknown — UNCHECKED (fix scripts/upstreams.json)"
            incomplete=1; continue
          fi
          # Normalize the local ref to a full 40-hex SHA (short SHA -> gh resolves).
          if printf '%s' "$local_ref" | grep -qE '^[0-9a-f]{40}$'; then
            local_sha="$local_ref"
          else
            local_sha="$(gh api "repos/$repo/commits/$local_ref" --jq '.sha' 2>/dev/null)"; api_rc=$?
            if [ "$api_rc" -ne 0 ] || ! printf '%s' "$local_sha" | grep -qE '^[0-9a-f]{40}$'; then
              echo "  $name: ? cannot resolve local ref '$local_ref' on $repo — UNCHECKED"
              incomplete=1; continue
            fi
          fi
          head="$(gh api "repos/$repo/commits/HEAD" --jq '.sha' 2>/dev/null)"; api_rc=$?
          if [ "$api_rc" -ne 0 ] || ! printf '%s' "$head" | grep -qE '^[0-9a-f]{40}$'; then
            echo "  $name: ? upstream unreachable ($repo) — UNCHECKED"
            incomplete=1; continue
          fi
          if [ "$local_sha" = "$head" ]; then
            echo "  $name: CURRENT  ($repo @ ${local_sha:0:7})${tier_note}"
          else
            delta="$(gh api "repos/$repo/compare/$local_sha...$head" --jq '.ahead_by' 2>/dev/null)"
            echo "  $name: BEHIND   ($repo upstream is ${delta:-?} commit(s) ahead — ${local_sha:0:7} -> ${head:0:7})${tier_note}"
            drift=1
          fi
          ;;
        tag_release)
          # Resolve the LOCAL version: a recorded synced_base, or a probed one.
          if [ "$mode" = "base" ]; then
            local_ver="$v1"
            if [ -z "$local_ver" ]; then
              echo "  $name: ? entry missing synced_base — UNCHECKED (fix scripts/upstreams.json)"
              incomplete=1; continue
            fi
          elif [ "$mode" = "probe" ]; then
            cmd_str="$v1"; rx="$v2"
            if [ -z "$cmd_str" ] || [ -z "$rx" ]; then
              echo "  $name: ? probe entry missing version_command/version_regex — UNCHECKED (fix scripts/upstreams.json)"
              incomplete=1; continue
            fi
            # version_command is simple space-separated tokens; split into an array.
            read -r -a cmd_arr <<< "$cmd_str"
            if ! command -v "${cmd_arr[0]}" >/dev/null 2>&1; then
              echo "  $name: ? tool '${cmd_arr[0]}' not installed — UNCHECKED${tier_note}"
              incomplete=1; continue
            fi
            # A --version that exits non-zero after printing the version (e.g.
            # twitter-cli) is fine: we extract the version from combined output.
            if command -v timeout >/dev/null 2>&1; then
              probe_out="$(timeout 10 "${cmd_arr[@]}" 2>&1)"; probe_rc=$?
              # rc=124 is `timeout`'s own kill signal; 137 (128+9) shows up if
              # the probe was SIGKILLed some other way. Either means the probe
              # never finished — route to UNCHECKED, never parse the partial
              # output (a probe that prints a version line and THEN hangs
              # would otherwise parse as CURRENT/BEHIND on truncated output).
              if [ "$probe_rc" -eq 124 ] || [ "$probe_rc" -eq 137 ]; then
                echo "  $name: ? probe timed out (10s) — UNCHECKED${tier_note}"
                incomplete=1; continue
              fi
            else
              # No `timeout` on PATH (uncommon but not guaranteed — a stripped
              # PATH, an odd distro): fall back to a portable bash-native
              # watchdog so a hanging probe can never wedge the whole run.
              # Plain background job + sleep-then-kill — no `wait -n` (absent
              # on bash 3.2 / older Git-Bash), so this stays portable.
              echo "  $name: note — 'timeout' unavailable, using bash-native watchdog fallback (10s budget)${tier_note}"
              probe_tmp="$(mktemp)"
              # Best-effort GROUP cleanup: with `setsid` the probe becomes its
              # own process-group leader, so `kill -9 -- -$probe_pid` (negative
              # pid = the whole group) also reaps any children it spawned.
              # Without setsid (not every box has coreutils/util-linux) we fall
              # back to killing the direct pid plus any direct children found
              # via `ps -ef` ppid matching — NOT full-group semantics
              # (grandchildren can survive), but probes here are short-lived
              # `--version`-style calls, so the residual leak is small. Real
              # process-group semantics need the `timeout` path above (coreutils).
              if command -v setsid >/dev/null 2>&1; then
                setsid "${cmd_arr[@]}" >"$probe_tmp" 2>&1 &
                probe_pid=$!
                probe_grouped=1
              else
                "${cmd_arr[@]}" >"$probe_tmp" 2>&1 &
                probe_pid=$!
                probe_grouped=0
              fi
              (
                sleep 10
                if [ "$probe_grouped" -eq 1 ]; then
                  kill -9 -- -"$probe_pid" 2>/dev/null
                else
                  kill -9 "$probe_pid" 2>/dev/null
                  if command -v ps >/dev/null 2>&1; then
                    ps -ef 2>/dev/null | awk -v ppid="$probe_pid" '$3==ppid{print $2}' \
                      | while IFS= read -r cpid; do kill -9 "$cpid" 2>/dev/null; done
                  fi
                fi
              ) &
              watchdog_pid=$!
              wait "$probe_pid" 2>/dev/null
              probe_status=$?
              # Probe finished (or was killed) — the watchdog's sleep is no
              # longer needed either way; reap it so it doesn't linger. Cleanup
              # above is best-effort only — it must never change probe_status
              # or the UNCHECKED verdict path below.
              kill "$watchdog_pid" 2>/dev/null
              wait "$watchdog_pid" 2>/dev/null
              if [ "$probe_status" -ge 128 ]; then
                rm -f "$probe_tmp"
                echo "  $name: ? probe timed out (10s watchdog) — UNCHECKED${tier_note}"
                incomplete=1; continue
              fi
              probe_out="$(cat "$probe_tmp" 2>/dev/null)"
              rm -f "$probe_tmp"
            fi
            local_ver="$(printf '%s' "$probe_out" | grep -oE "$rx" | head -1)"
            if [ -z "$local_ver" ]; then
              echo "  $name: ? could not parse version from '${cmd_arr[0]}' output — UNCHECKED${tier_note}"
              incomplete=1; continue
            fi
          else
            echo "  $name: ? tag_release mode '$mode' unknown — UNCHECKED (fix scripts/upstreams.json)"
            incomplete=1; continue
          fi
          if [ "$latest_src" = "release" ]; then
            # Non-monotonic tags: a stale higher-semver tag (e.g. graphify's
            # v1.0.0, cut months before the current v0.9.x line) would make
            # `sort -V` pick a phantom "latest" and report a permanent false
            # BEHIND. Opt into the maintainer's own latest-non-prerelease
            # designation (the Releases API), which reflects real recency.
            latest="$(gh api "repos/$repo/releases/latest" --jq '.tag_name' 2>/dev/null)"; api_rc=$?
            if [ "$api_rc" -ne 0 ] || ! printf '%s' "$latest" | grep -qE '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
              echo "  $name: ? no parseable latest release on $repo (latest_source=release) — UNCHECKED"
              incomplete=1; continue
            fi
          elif [ -n "$latest_src" ]; then
            # Only an empty latest_source means "default: highest stable tag". Any
            # other non-empty value is a typo (e.g. "releases") that would silently
            # fall into tag mode and re-introduce the phantom-drift this option
            # exists to prevent — mark it UNCHECKED, never guess.
            echo "  $name: ? unknown latest_source '$latest_src' — UNCHECKED (use 'release' or omit; fix scripts/upstreams.json)"
            incomplete=1; continue
          else
            tags_raw="$(gh api "repos/$repo/tags?per_page=100" --jq '.[].name' 2>/dev/null)"; api_rc=$?
            if [ "$api_rc" -ne 0 ] || [ -z "$tags_raw" ]; then
              echo "  $name: ? true upstream unreachable ($repo tags) — UNCHECKED"
              incomplete=1; continue
            fi
            latest="$(printf '%s\n' "$tags_raw" | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' | highest_version)"
            if [ -z "$latest" ]; then
              echo "  $name: ? no stable version tags found on $repo — UNCHECKED"
              incomplete=1; continue
            fi
          fi
          # Normalize leading 'v' on both sides before comparing.
          norm_local="${local_ver#v}"
          norm_latest="${latest#v}"
          if [ "$norm_local" = "$norm_latest" ]; then
            echo "  $name: CURRENT  (installed $norm_local = $repo latest tag)${tier_note}"
          else
            hi="$(printf '%s\n%s\n' "$norm_local" "$norm_latest" | highest_version)"
            if [ "$hi" = "$norm_local" ]; then
              # Installed is newer than the latest STABLE tag (e.g. a prerelease or
              # locally-built version): not behind upstream's stable line.
              echo "  $name: CURRENT  (installed $norm_local >= $repo latest stable $norm_latest)${tier_note}"
            else
              echo "  $name: BEHIND   ($repo latest tag $latest; installed $local_ver — upgrade)${tier_note}"
              drift=1
            fi
          fi
          ;;
        *)
          echo "  $name: ? unknown kind '$kind' (mode '$mode') — UNCHECKED (fix scripts/upstreams.json)"
          incomplete=1
          ;;
      esac
    done <<< "$reg_out"
  fi
fi

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
