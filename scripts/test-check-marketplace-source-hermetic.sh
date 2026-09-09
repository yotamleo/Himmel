#!/usr/bin/env bash
# Smoke test for check-marketplace-source-hermetic.sh. Drives the guard with
# fixture settings-template.json files via its env-override seam.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure jq + POSIX shell; no .ps1 twin needed.
set -euo pipefail
HERE="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/check-marketplace-source-hermetic.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/check-marketplace-source-hermetic-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

run_guard() { HIMMEL_SETTINGS_TEMPLATE="$1" bash "$GUARD"; }

# Fixture helper: writes a minimal marketplace.json with the given plugins
# JSON array body under "$1/.claude-plugin/marketplace.json".
write_marketplace() {
  local dir="$1" plugins="$2"
  mkdir -p "$dir/.claude-plugin"
  printf '{\n  "name": "fixture",\n  "plugins": [%s]\n}\n' "$plugins" > "$dir/.claude-plugin/marketplace.json"
}

# Case 1 (RED — the exact HIMMEL-2733 regression shape): a plugin enabled
# under a marketplace whose extraKnownMarketplaces source is "github"
# (owner/repo shorthand, SSH clone) must FAIL.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "plannotator-effective-html@effective-html": true
  },
  "extraKnownMarketplaces": {
    "effective-html": {"source": {"source": "github", "repo": "plannotator/effective-html"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a github-shorthand marketplace source"; exit 1
fi
echo "ok: github-shorthand source detected (RED, HIMMEL-2733 regression shape)"

# Case 2 (GREEN — the HIMMEL-2837 fix shape): the same plugin re-homed under
# a marketplace whose source is a local "directory" (himmel's own
# marketplace, which vendors the plugin with its own per-plugin url+sha
# source) must PASS — and (HIMMEL-2846) every per-plugin source INSIDE that
# vendored marketplace.json must itself be hermetic.
write_marketplace "$tmp/mkt_ok" '
    {"name": "a", "source": "./plugins/a"},
    {"name": "b", "source": {"source": "url", "url": "https://github.com/x/b.git", "sha": "deadbeef"}}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_ok"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a directory-sourced marketplace whose plugin sources are all hermetic"; exit 1
fi
echo "ok: directory-sourced marketplace with hermetic plugin sources passes"

# Case 2b (RED, HIMMEL-2846): a plugin entry INSIDE the vendored
# marketplace.json using an SSH/github-shorthand source must FAIL, naming
# the plugin — the exact regression this guard was blind to (it only
# checked the top-level extraKnownMarketplaces source type).
write_marketplace "$tmp/mkt_ssh" '
    {"name": "a", "source": "./plugins/a"},
    {"name": "evil", "source": {"source": "github", "repo": "owner/evil"}}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_ssh"}}
  }
}
JSON
out=""
if out="$(run_guard "$tmp/tmpl.json" 2>&1)"; then
  echo "FAIL: guard passed despite a github-shorthand plugin source inside a directory-sourced marketplace"; exit 1
fi
case "$out" in
  *evil*) ;;
  *) echo "FAIL: guard did not name the offending plugin \"evil\""; exit 1 ;;
esac
echo "ok: github-shorthand plugin source inside vendored marketplace detected"

# Case 2c (RED, HIMMEL-2846): a plugin entry with a non-HTTPS "url" source
# inside the vendored marketplace.json must FAIL.
write_marketplace "$tmp/mkt_sshurl" '
    {"name": "evil", "source": {"source": "url", "url": "ssh://git@github.com/owner/evil.git"}}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_sshurl"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a non-HTTPS url plugin source inside a directory-sourced marketplace"; exit 1
fi
echo "ok: non-HTTPS url plugin source inside vendored marketplace detected"

# Case 2d (RED, HIMMEL-2846): the vendored marketplace's own marketplace.json
# is missing -> fail loud (fail-closed), never a silent PASS.
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_missing"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a missing marketplace.json in a directory-sourced marketplace"; exit 1
fi
echo "ok: missing marketplace.json inside a directory-sourced marketplace fails loud"

# Case 2e (RED, HIMMEL-2846): an unparsable marketplace.json in a
# directory-sourced marketplace -> fail loud, never a silent PASS.
mkdir -p "$tmp/mkt_unparsable/.claude-plugin"
printf 'not json' > "$tmp/mkt_unparsable/.claude-plugin/marketplace.json"
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_unparsable"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite an unparsable marketplace.json in a directory-sourced marketplace"; exit 1
fi
echo "ok: unparsable marketplace.json inside a directory-sourced marketplace fails loud"

# Case 2f (GREEN, HIMMEL-2846): a plugin entry that is ITSELF sourced from
# another local directory (a nested vendored marketplace) recurses — and
# passes when that nested marketplace.json is also all-hermetic.
write_marketplace "$tmp/mkt_nested_inner" '
    {"name": "c", "source": "./plugins/c"}
'
write_marketplace "$tmp/mkt_nested_outer" "
    {\"name\": \"a\", \"source\": \"./plugins/a\"},
    {\"name\": \"inner\", \"source\": {\"source\": \"directory\", \"path\": \"$tmp/mkt_nested_inner\"}}
"
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_nested_outer"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a nested directory-sourced marketplace that is all-hermetic"; exit 1
fi
echo "ok: nested directory-sourced marketplace (hermetic) passes"

# Case 2g (RED, HIMMEL-2846): same nested shape, but the nested marketplace
# is a self-reference (points back at the outer marketplace directory) ->
# fail loud, never an infinite loop.
write_marketplace "$tmp/mkt_self" "
    {\"name\": \"a\", \"source\": \"./plugins/a\"},
    {\"name\": \"loop\", \"source\": {\"source\": \"directory\", \"path\": \"$tmp/mkt_self\"}}
"
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_self"}}
  }
}
JSON
self_rc=0
if command -v timeout >/dev/null 2>&1; then
  # gnu-ok: guarded by command -v above, with an unbounded fallback in the
  # else branch below when timeout is absent (e.g. bare macOS/BSD) — same
  # graceful-degrade convention as test-himmel-update-hermes.sh.
  # shellcheck disable=SC2016 # $1/$2 expand inside the bash -c subshell, not here
  timeout 10 bash -c 'HIMMEL_SETTINGS_TEMPLATE="$1" bash "$2"' _ "$tmp/tmpl.json" "$GUARD" >/dev/null 2>&1 || self_rc=$?
  if [ "$self_rc" -eq 124 ]; then
    echo "FAIL: guard hung on a self-referential directory-sourced marketplace"; exit 1
  fi
else
  # timeout not on PATH (e.g. bare macOS/BSD) — fall back to an unbounded
  # direct call, same graceful-degrade convention as test-himmel-update-hermes.sh.
  # shellcheck disable=SC2016 # $1/$2 expand inside the bash -c subshell, not here
  bash -c 'HIMMEL_SETTINGS_TEMPLATE="$1" bash "$2"' _ "$tmp/tmpl.json" "$GUARD" >/dev/null 2>&1 || self_rc=$?
fi
if [ "$self_rc" -eq 0 ]; then
  echo "FAIL: guard passed despite a self-referential directory-sourced marketplace"; exit 1
fi
echo "ok: self-referential directory-sourced marketplace fails loud without hanging"

# Case 2h (RED, HIMMEL-2846 panel round 2): a nested plugin "directory"
# source given as a Windows drive-letter absolute path (e.g. "C:/nested")
# must be resolved AS ABSOLUTE, never prefixed with the outer marketplace's
# own directory — resolve_dir_path's absolute-path check only recognized a
# leading "/" before this fix, so on Git Bash (the explicitly supported
# platform) a legitimate drive-letter path was silently treated as relative.
# The observable signature: the guard's "missing marketplace.json" message
# names the resolved path it looked for — it must be the bare drive-letter
# path, never the outer dir prepended onto it.
write_marketplace "$tmp/mkt_winbase" '
    {"name": "a", "source": "./plugins/a"},
    {"name": "win", "source": {"source": "directory", "path": "C:/nested/marketplace"}}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_winbase"}}
  }
}
JSON
out=""
if out="$(run_guard "$tmp/tmpl.json" 2>&1)"; then
  echo "FAIL: guard passed despite an unresolvable nested directory source"; exit 1
fi
case "$out" in
  *"$tmp/mkt_winbase/C:"*)
    echo "FAIL: Windows drive-letter path was prefixed with the outer marketplace dir (treated as relative)"; exit 1
    ;;
  *"C:/nested/marketplace/.claude-plugin/marketplace.json"*) ;;
  *) echo "FAIL: guard output did not name the expected Windows absolute path at all"; exit 1 ;;
esac
echo "ok: Windows drive-letter absolute path resolved as absolute, not relative"

# Case 2i (RED, HIMMEL-2855): a plugin entry with a bare-STRING source that is
# an ssh:// URL must FAIL — a STRING source is only hermetic when it actually
# IS a relative path within the marketplace's own tree.
write_marketplace "$tmp/mkt_string_ssh" '
    {"name": "a", "source": "./plugins/a"},
    {"name": "evil", "source": "ssh://git@github.com/owner/evil.git"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_string_ssh"}}
  }
}
JSON
out=""
if out="$(run_guard "$tmp/tmpl.json" 2>&1)"; then
  echo "FAIL: guard passed despite a bare-STRING ssh:// plugin source"; exit 1
fi
case "$out" in
  *evil*) ;;
  *) echo "FAIL: guard did not name the offending plugin \"evil\""; exit 1 ;;
esac
echo "ok: bare-STRING ssh:// plugin source detected"

# Case 2j (RED, HIMMEL-2855): a bare-STRING scp-style SSH spec
# (git@host:owner/repo.git) must FAIL for the same reason.
write_marketplace "$tmp/mkt_string_scp" '
    {"name": "a", "source": "./plugins/a"},
    {"name": "evil", "source": "git@github.com:owner/evil.git"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_string_scp"}}
  }
}
JSON
out=""
if out="$(run_guard "$tmp/tmpl.json" 2>&1)"; then
  echo "FAIL: guard passed despite a bare-STRING scp-style plugin source"; exit 1
fi
case "$out" in
  *evil*) ;;
  *) echo "FAIL: guard did not name the offending plugin \"evil\""; exit 1 ;;
esac
echo "ok: bare-STRING scp-style plugin source detected"

# Case 2k (RED, HIMMEL-2855): a bare-STRING HTTPS url must also FAIL — the
# STRING form is a relative-path shorthand, never a URL, HTTPS included.
write_marketplace "$tmp/mkt_string_https" '
    {"name": "a", "source": "./plugins/a"},
    {"name": "evil", "source": "https://github.com/owner/evil.git"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_string_https"}}
  }
}
JSON
out=""
if out="$(run_guard "$tmp/tmpl.json" 2>&1)"; then
  echo "FAIL: guard passed despite a bare-STRING https:// plugin source"; exit 1
fi
case "$out" in
  *evil*) ;;
  *) echo "FAIL: guard did not name the offending plugin \"evil\""; exit 1 ;;
esac
echo "ok: bare-STRING https:// plugin source detected"

# Case 2l (GREEN, HIMMEL-2855): bare-STRING relative paths — with and without
# a leading "./" — remain hermetic and must keep passing.
write_marketplace "$tmp/mkt_string_rel" '
    {"name": "a", "source": "./plugins/a"},
    {"name": "b", "source": "plugins/b"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_string_rel"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on bare-STRING relative-path plugin sources"; exit 1
fi
echo "ok: bare-STRING relative-path plugin sources pass"

# Case 2m (HIMMEL-2855): a nested "directory" plugin source whose path uses a
# backslash separator (the shape a Windows relative path takes, e.g.
# "plugins\inner") must reach resolve_dir_path losslessly — jq's @tsv
# encoding backslash-doubles ("\" -> "\\") and a plain `read -r` does not
# un-escape it, so the pre-fix transport corrupts the value before it ever
# reaches resolve_dir_path. Fixture: create a directory whose LITERAL name
# contains a single backslash byte (legal on Linux) so a doubled value fails
# to resolve and a lossless value succeeds.
write_marketplace "$tmp/mkt_backslash/plugins\\inner" '
    {"name": "c", "source": "./plugins/c"}
'
write_marketplace "$tmp/mkt_backslash" "
    {\"name\": \"a\", \"source\": \"./plugins/a\"},
    {\"name\": \"win\", \"source\": {\"source\": \"directory\", \"path\": \"plugins\\\\inner\"}}
"
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_backslash"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed to losslessly resolve a backslash-separated nested plugin path"; exit 1
fi
echo "ok: backslash-separated nested plugin path resolves losslessly"

# Case 2n (RED, HIMMEL-2855 pr-check round 1, codex-1): a plugin name
# containing a JSON \u0000 escape desyncs the fixed 3-field NUL-delimited
# read (jq -j emits the escaped NUL as a raw byte, indistinguishable from the
# deliberate field-separator NUL) for every subsequent plugin, shifting a
# later, genuinely prohibited plugin source out of the read window entirely
# so it is silently dropped and never validated. Fixture: plugin 1's name is
# "a\u0000STRING" (the embedded NUL plus the literal marker text "STRING");
# plugin 2's name is the literal "STRING" and its source is a prohibited
# ssh:// URL. The desync makes the shifted reads land the "STRING" markers in
# both entries' type/detail slots (trivially passing the relative-path
# check), while the real ssh:// value is shifted out and dropped at EOF.
write_marketplace "$tmp/mkt_nulsync" '
    {"name": "a\u0000STRING", "source": "./ok1"},
    {"name": "STRING", "source": "ssh://git@github.com/x/y.git"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_nulsync"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a NUL-desynced ssh:// plugin source hidden by an embedded \u0000"; exit 1
fi
echo "ok: NUL-desync field-shift bypass (embedded \u0000 hiding a prohibited source) detected"

# Case 2o (RED, HIMMEL-2855 pr-check round 2, codex-1): a plugin source
# string that is a Windows UNC path ("\\server\share\plugin") is a network
# path, not a relative path within the marketplace's own tree, but the
# absolute-path pattern only recognized a leading "/" or a drive-letter
# prefix ("C:/..." / "C:\..."), so a bare UNC path fell through to the
# default "relative -- hermetic" case and went unflagged.
write_marketplace "$tmp/mkt_unc" '
    {"name": "unc-plugin", "source": "\\\\server\\share\\plugin"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_unc"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a Windows UNC-path plugin source"; exit 1
fi
echo "ok: Windows UNC-path plugin source detected as non-hermetic"

# Case 2p (RED, HIMMEL-2855 pr-check round 2, codex-2): a plugin whose
# "name" field is a JSON number (not a string) previously made the raw
# `$n + $t + $d` jq concatenation type-error and abort the ENTIRE
# .plugins[] pipeline (jq halts the whole program on a runtime type
# error), so every plugin after the malformed one -- including a
# genuinely prohibited source -- was silently never read from the process
# substitution and the guard passed vacuously.
write_marketplace "$tmp/mkt_nonstring" '
    {"name": 12345, "source": "./ok1"},
    {"name": "evil", "source": "ssh://git@github.com/x/y.git"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_nonstring"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a non-string plugin name masking a later ssh:// source"; exit 1
fi
echo "ok: non-string plugin name does not abort the extraction pipeline (later ssh:// source still detected)"

# Case 2q (RED, HIMMEL-2855 pr-check round 3, codex-1): a plugin source
# string containing a ".." path segment (e.g. "../outside/plugin") is
# syntactically relative, so it fell through the default "relative --
# hermetic" branch, but resolving it against the marketplace's own
# directory walks OUTSIDE that directory -- the same "escapes the tree"
# hazard the absolute-path checks exist to catch, just spelled relatively.
# A dotted filename like "plugins/a.b" (no ".." path segment) must still
# pass -- the check must key on a literal ".." segment, not any "." byte.
write_marketplace "$tmp/mkt_dotdot" '
    {"name": "traversal-plugin", "source": "../outside/plugin"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_dotdot"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a \"..\"-traversal plugin source"; exit 1
fi
echo "ok: \"..\"-traversal plugin source detected as non-hermetic"

write_marketplace "$tmp/mkt_dotted" '
    {"name": "dotted-plugin", "source": "plugins/a.b"}
'
cat > "$tmp/tmpl.json" <<JSON
{
  "enabledPlugins": {
    "plannotator-effective-html@himmel": true
  },
  "extraKnownMarketplaces": {
    "himmel": {"source": {"source": "directory", "path": "$tmp/mkt_dotted"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a dotted (non-traversal) relative-path plugin source"; exit 1
fi
echo "ok: dotted relative-path plugin source (no .. segment) still passes"

# Case 3: an explicit HTTPS "url" source (e.g. claude-obsidian's own
# marketplace shape) must also PASS.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "claude-obsidian@claude-obsidian-fork": true
  },
  "extraKnownMarketplaces": {
    "claude-obsidian-fork": {"source": {"source": "url", "url": "https://github.com/yotamleo/claude-obsidian.git"}}
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on a url-sourced marketplace"; exit 1
fi
echo "ok: url-sourced marketplace passes"

# Case 3b (RED — codex-adv finding, pr-check round 1): a "url"-typed source
# whose url is NOT https:// (e.g. ssh:// or a bare git@ scp-style remote)
# still requires the exact SSH host-key setup this guard exists to catch —
# typing alone is not enough, the scheme itself must be checked.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "claude-obsidian@claude-obsidian-fork": true
  },
  "extraKnownMarketplaces": {
    "claude-obsidian-fork": {"source": {"source": "url", "url": "ssh://git@github.com/yotamleo/claude-obsidian.git"}}
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite a non-HTTPS url source"; exit 1
fi
echo "ok: non-HTTPS url source detected"

# Case 4: claude-plugins-official is exempt even though this fixture gives
# it no extraKnownMarketplaces entry at all (real state: Anthropic's own
# marketplace, source type irrelevant to this guard).
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true
  }
}
JSON
if ! run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard failed on claude-plugins-official, which must be exempt"; exit 1
fi
echo "ok: claude-plugins-official exempt"

# Case 5: a marketplace suffix with NO extraKnownMarketplaces entry at all
# (unregistered) cannot resolve to url/directory either -> FAIL.
cat > "$tmp/tmpl.json" <<'JSON'
{
  "enabledPlugins": {
    "some-plugin@unregistered": true
  }
}
JSON
if run_guard "$tmp/tmpl.json" >/dev/null 2>&1; then
  echo "FAIL: guard passed despite an unregistered marketplace"; exit 1
fi
echo "ok: unregistered marketplace detected"

# Case 6: missing input file -> fail-OPEN skip (exit 0), matching the
# always_run convention (a partial checkout must not start blocking).
if ! run_guard "$tmp/does-not-exist.json" >/dev/null 2>&1; then
  echo "FAIL: guard did not skip (exit 0) on a missing template file"; exit 1
fi
echo "ok: missing input skips"

echo "ALL PASS"
