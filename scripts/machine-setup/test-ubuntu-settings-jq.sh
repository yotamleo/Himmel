#!/usr/bin/env bash
# test-ubuntu-settings-jq.sh — fixture regression tests for the
# settings.json jq transforms in scripts/machine-setup/ubuntu.sh
# (HIMMEL-264).
#
# ubuntu.sh is interactive (read -r -p prompts) and mutates
# ~/.claude/settings.json, so it cannot be executed end-to-end here.
# Instead the jq filters are MIRRORED below and each mirror is pinned to
# the source with a literal drift-guard grep: if ubuntu.sh's filter
# changes, the corresponding grep fails and forces this test back in
# sync. win11.ps1 carries the same swap/patch logic as PowerShell object
# walks (no jq) — that twin is NOT covered here; it is
# fixture-verified-only by manual runs on Windows (flagged honestly:
# keep both in lockstep when changing either).
#
# Covers:
#   1. Swap filter (HIMMEL-264 bug fix): a settings.json holding BOTH a
#      guard entry AND a bare `rtk hook claude` entry → the bare one is
#      swapped, the guard one untouched.
#   2. Idempotency: after the swap, BARE_COUNT is 0 and the
#      "already swapped" detection fires — a re-run changes nothing.
#   3. Bare-entry regex: extra flags (`rtk hook claude --foo`) still
#      count as bare; `rtk-hook-guard.sh` and unrelated commands don't.
#   4. Template patch (HIMMEL-264 <himmel-path> resolution): running the
#      patch filter against docs/setup/settings-template.json leaves no
#      `<himmel-path>` in the output, drops SessionEnd, and appends the
#      check-hookspath SessionStart entry.

set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not on PATH — required by these fixtures" >&2
    exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
ubuntu_sh="$repo_root/scripts/machine-setup/ubuntu.sh"
template="$repo_root/docs/setup/settings-template.json"

[ -f "$ubuntu_sh" ] || { echo "FAIL: $ubuntu_sh not found" >&2; exit 1; }
[ -f "$template" ] || { echo "FAIL: $template not found" >&2; exit 1; }

pass=0
fail=0

assert_pass() {
    pass=$((pass + 1))
    echo "  PASS: $1"
}

assert_fail() {
    fail=$((fail + 1))
    echo "  FAIL: $1"
}

# ---------- mirrored filters + drift guards ----------
# Each constant below MUST byte-match its counterpart in ubuntu.sh.
BARE_RTK_RE='^[[:space:]]*rtk[[:space:]]+hook[[:space:]]+claude([[:space:]]|$)'
# shellcheck disable=SC2016  # single quotes intentional: $re/$cmd are jq variables, not shell
SWAP_FILTER='(.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test($re))).command = $cmd'
# shellcheck disable=SC2016  # single quotes intentional: $re is a jq variable
COUNT_FILTER='[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test($re))] | length'
GUARD_PRESENT_FILTER='.hooks.PreToolUse // [] | map(.hooks // [] | map(.command) | join(" ")) | join(" ") | contains("rtk-hook-guard.sh")'
# shellcheck disable=SC2016  # single quotes intentional: $hp is a jq variable
WALK_LINE='| walk(if type == "string" then gsub("<himmel-path>"; $hp) else . end)'

echo "Drift guards: mirrored filters still match ubuntu.sh"
for needle in "$BARE_RTK_RE" "$SWAP_FILTER" "$COUNT_FILTER" "$GUARD_PRESENT_FILTER" "$WALK_LINE"; do
    if grep -qF -- "$needle" "$ubuntu_sh"; then
        assert_pass "ubuntu.sh still contains: ${needle:0:60}..."
    else
        assert_fail "ubuntu.sh drifted from mirrored filter: $needle"
    fi
done

# ---------- 1+2+3. Swap filter: guard + bare coexist ----------
echo "Test 1: bare entry next to an existing guard entry is swapped"
GUARD_CMD='bash "/opt/himmel/scripts/hooks/rtk-hook-guard.sh"'
fixture=$(jq -n --arg guard "$GUARD_CMD" '{
  hooks: {
    PreToolUse: [
      {matcher: "Bash", hooks: [{type: "command", command: $guard}]},
      {matcher: "Bash", hooks: [{type: "command", command: "rtk hook claude"}]},
      {matcher: "*",    hooks: [{type: "command", command: "bash /x/auto-arm-on-cap.sh"}]}
    ]
  },
  theme: "dark"
}')

bare_count=$(printf '%s' "$fixture" | jq --arg re "$BARE_RTK_RE" "$COUNT_FILTER")
if [ "$bare_count" -eq 1 ]; then
    assert_pass "fixture: exactly 1 bare entry detected despite guard entry present"
else
    assert_fail "expected BARE_COUNT=1, got $bare_count"
fi

swapped=$(printf '%s' "$fixture" \
    | jq --arg cmd "$GUARD_CMD" --arg re "$BARE_RTK_RE" "$SWAP_FILTER")

if printf '%s' "$swapped" | jq -e --arg re "$BARE_RTK_RE" "($COUNT_FILTER) == 0" >/dev/null; then
    assert_pass "no bare 'rtk hook claude' entry remains after swap"
else
    assert_fail "bare entry survived the swap: $swapped"
fi

guard_count=$(printf '%s' "$swapped" \
    | jq --arg g "$GUARD_CMD" '[.hooks.PreToolUse[]?.hooks[]? | select(.command == $g)] | length')
if [ "$guard_count" -eq 2 ]; then
    assert_pass "guard command present twice (pre-existing + swapped)"
else
    assert_fail "expected 2 guard commands after swap, got $guard_count"
fi

if printf '%s' "$swapped" | jq -e '.hooks.PreToolUse[2].hooks[0].command == "bash /x/auto-arm-on-cap.sh" and .theme == "dark"' >/dev/null; then
    assert_pass "unrelated entries and keys untouched"
else
    assert_fail "swap disturbed unrelated content: $swapped"
fi

echo "Test 2: re-run is idempotent (skip branch fires, output unchanged)"
bare_after=$(printf '%s' "$swapped" | jq --arg re "$BARE_RTK_RE" "$COUNT_FILTER")
if [ "$bare_after" -eq 0 ] \
   && printf '%s' "$swapped" | jq -e --arg re "$BARE_RTK_RE" "$GUARD_PRESENT_FILTER" >/dev/null; then
    assert_pass "re-run takes the 'already swapped' branch (BARE_COUNT=0, guard detected)"
else
    assert_fail "re-run would not skip: bare=$bare_after"
fi
reswapped=$(printf '%s' "$swapped" \
    | jq --arg cmd "$GUARD_CMD" --arg re "$BARE_RTK_RE" "$SWAP_FILTER")
if [ "$(printf '%s' "$swapped" | jq -S .)" = "$(printf '%s' "$reswapped" | jq -S .)" ]; then
    assert_pass "applying the swap filter twice is a no-op"
else
    assert_fail "second swap application changed the document"
fi

echo "Test 3: bare-entry regex boundaries"
for cmd_should_match in 'rtk hook claude' '  rtk  hook  claude' 'rtk hook claude --foo'; do
    if printf '%s' "$cmd_should_match" | grep -qE "$BARE_RTK_RE"; then
        assert_pass "matches bare: '$cmd_should_match'"
    else
        assert_fail "should match bare entry: '$cmd_should_match'"
    fi
done
for cmd_should_skip in 'bash "/opt/himmel/scripts/hooks/rtk-hook-guard.sh"' 'rtk hook claudette' 'echo rtk hook claude'; do
    if printf '%s' "$cmd_should_skip" | grep -qE "$BARE_RTK_RE"; then
        assert_fail "must NOT match: '$cmd_should_skip'"
    else
        assert_pass "skips: '$cmd_should_skip'"
    fi
done

# ---------- 4. Template patch resolves <himmel-path> ----------
# Mirror of the PATCH filter in ubuntu.sh step "Patch ~/.claude/settings.json"
# (drift-guarded above via WALK_LINE; the surrounding additions are exercised
# by the SessionEnd/SessionStart asserts below).
echo "Test 4: patch filter against the real template leaves no <himmel-path>"
HP='/opt/himmel'
patched=$(jq \
    --arg sl 'bash "/opt/claude-statusline/bin/statusline.sh"' \
    --arg lv '/home/u/Documents/luna' \
    --arg hp "$HP" \
    '. + {
      statusLine: { type: "command", command: $sl },
      mcpServers: {
        "obsidian-vault": { command: "uvx", args: ["mcp-obsidian", $lv] }
      },
      extraKnownMarketplaces: (.extraKnownMarketplaces + {
        "himmel": { source: { source: "directory", path: ($hp + "/marketplace") } }
      }),
      hooks: ((.hooks | del(.SessionEnd))
        | .SessionStart[0].hooks += [{
            type: "command",
            command: ("bash \"" + $hp + "/scripts/hooks/check-hookspath.sh\""),
            shell: "bash",
            timeout: 10
          }])
    }
    | walk(if type == "string" then gsub("<himmel-path>"; $hp) else . end)' \
    "$template")

if printf '%s' "$patched" | jq -e . >/dev/null 2>&1; then
    assert_pass "patched template is valid JSON"
else
    assert_fail "patch filter produced invalid JSON"
fi
if printf '%s' "$patched" | grep -qF '<himmel-path>'; then
    assert_fail "dangling <himmel-path> remains in patched output"
else
    assert_pass "no <himmel-path> placeholder remains"
fi
if printf '%s' "$patched" | jq -e --arg hp "$HP" \
    '[.hooks.PreToolUse[].hooks[].command] | any(. == ("bash \"" + $hp + "/scripts/hooks/rtk-hook-guard.sh\""))' >/dev/null; then
    assert_pass "rtk-hook-guard PreToolUse entry resolved to the himmel path"
else
    assert_fail "rtk-hook-guard entry missing or unresolved: $(printf '%s' "$patched" | jq -c '.hooks.PreToolUse')"
fi
if printf '%s' "$patched" | jq -e '.hooks | has("SessionEnd") | not' >/dev/null; then
    assert_pass "SessionEnd stripped (owned by the dedicated setup step)"
else
    assert_fail "SessionEnd survived the patch"
fi
if printf '%s' "$patched" | jq -e '[.hooks.SessionStart[0].hooks[].command] | any(test("check-hookspath\\.sh"))' >/dev/null; then
    assert_pass "check-hookspath SessionStart entry appended"
else
    assert_fail "check-hookspath SessionStart entry missing"
fi

# ---------- summary ----------
echo ""
echo "ubuntu-settings-jq: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
