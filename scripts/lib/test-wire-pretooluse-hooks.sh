#!/usr/bin/env bash
# shellcheck disable=SC2015,SC1090
# test-wire-pretooluse-hooks.sh -- hermetic tests for wire-pretooluse-hooks.sh.
# Covers: PreToolUse trio wired; dedup-by-basename across a clone-path change
# (SC8 -> no double-wire); rtk-hook-guard / non-himmel hook preserved; SessionStart
# shared-array merge; idempotent re-run.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
wire="$here/wire-pretooluse-hooks.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

td="$(mktemp -d)"

# 1. missing file -> creates the 3 PreToolUse stanzas, forward-slashed + quoted.
s1="$td/s1.json"
bash "$wire" "$s1" "C:/himmel" >/dev/null
check "3 PreToolUse stanzas"      "$(jq '.hooks.PreToolUse | length' "$s1")" "3"
check "auto-approve quoted path"  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s1")" 'bash "C:/himmel/scripts/hooks/auto-approve-safe-bash.sh"'

# 2. backslash prefix -> forward-slashed in the command.
s2="$td/s2.json"
bash "$wire" "$s2" 'C:\Users\me\himmel' >/dev/null
check "backslash forward-slashed" "$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$s2")" 'bash "C:/Users/me/himmel/scripts/hooks/block-edit-on-main.sh"'

# 3. SC8 dedup-by-basename across a CLONE-PATH change -> still exactly 3, new path.
s3="$td/s3.json"
bash "$wire" "$s3" "C:/old/himmel" >/dev/null
bash "$wire" "$s3" "C:/new/himmel" >/dev/null
check "clone-path change: still 3"   "$(jq '.hooks.PreToolUse | length' "$s3")" "3"
check "clone-path change: new path"  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s3")" 'bash "C:/new/himmel/scripts/hooks/auto-approve-safe-bash.sh"'

# 4. rtk-hook-guard / non-himmel hook in the SAME Bash stanza is preserved.
s4="$td/s4.json"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rtk-hook-guard.sh"},{"type":"command","command":"bash /old/scripts/hooks/auto-approve-safe-bash.sh"}]}]}}' > "$s4"
bash "$wire" "$s4" "C:/himmel" >/dev/null
check "rtk guard survives" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))] | length' "$s4")" "1"
check "himmel object replaced (no dup)" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$s4")" "1"

# 5. SessionStart shared-array merge: inject-initiative co-resides with a sibling.
s5="$td/s5.json"
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /x/scripts/hooks/check-update-available.sh"}]}]}}' > "$s5"
# SessionStart wiring is a function call (direct-invoke only does PreToolUse):
( . "$wire"; wire_sessionstart_hook "$s5" "C:/himmel" "inject-initiative.sh" 0 >/dev/null )
check "SessionStart stanza count" "$(jq '.hooks.SessionStart | length' "$s5")" "1"
check "sibling check-update kept"  "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("check-update-available"))] | length' "$s5")" "1"
check "inject-initiative added"    "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s5")" "1"

# 6. SessionStart idempotent across re-run with changed clone path -> single object.
( . "$wire"; wire_sessionstart_hook "$s5" "C:/moved/himmel" "inject-initiative.sh" 0 >/dev/null )
check "inject-initiative dedup"    "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s5")" "1"
check "inject-initiative new path" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))][0]' "$s5")" 'bash "C:/moved/himmel/scripts/hooks/inject-initiative.sh"'

# 7. SessionStart with no prior stanza -> creates a standalone one.
s7="$td/s7.json"
( . "$wire"; wire_sessionstart_hook "$s7" "C:/himmel" "inject-initiative.sh" 0 >/dev/null )
check "standalone SessionStart created" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s7")" "1"

# 7b. --sessionstart CLI dispatch (the subprocess path setup.sh uses) wires it.
s7b="$td/s7b.json"
bash "$wire" --sessionstart "$s7b" "C:/himmel" "inject-initiative.sh" >/dev/null
check "--sessionstart CLI wires inject" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s7b")" "1"

# 8. PreToolUse idempotent re-run (same path) -> identical bytes.
s8="$td/s8.json"
bash "$wire" "$s8" "C:/himmel" >/dev/null
b8="$(cat "$s8")"
bash "$wire" "$s8" "C:/himmel" >/dev/null
check "PreToolUse idempotent" "$(cat "$s8")" "$b8"

# 8b. whitespace-only existing file -> treated as {} (not refused), 3 stanzas.
s8b="$td/s8b.json"; printf '   \n' > "$s8b"
bash "$wire" "$s8b" "C:/himmel" >/dev/null
check "whitespace file -> 3 stanzas" "$(jq '.hooks.PreToolUse | length' "$s8b")" "3"
# 8c. whitespace-only file -> SessionStart wires cleanly too.
s8c="$td/s8c.json"; printf '\t\n ' > "$s8c"
( . "$wire"; wire_sessionstart_hook "$s8c" "C:/himmel" "inject-initiative.sh" 0 >/dev/null )
check "whitespace file -> SessionStart inject" "$(jq -r '[.hooks.SessionStart[].hooks[].command | select(test("inject-initiative"))] | length' "$s8c")" "1"

# 8d. HIMMEL-2892 CR round 1 [codex-1]: dedup is per (hook, MATCHER). A hook
# registered under two DISTINCT matchers is two genuinely different
# registrations -- keeping only the first silently drops the second's tool
# coverage. RED before the fix: the `Write` stanza vanished, leaving Write
# unprotected while the retained matcher still read `Edit`.
s8d="$td/s8d.json"
cat > "$s8d" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Edit","hooks":[{"type":"command","command":"bash \"/old/scripts/hooks/block-edit-on-main.sh\""}]},
  {"matcher":"Write","hooks":[{"type":"command","command":"bash \"/old/scripts/hooks/block-edit-on-main.sh\""}]}
]}}
JSON
bash "$wire" "$s8d" "C:/himmel" >/dev/null
check "distinct matchers: Edit registration kept" \
  "$(jq -r '[.hooks.PreToolUse[] | select(.matcher=="Edit") | .hooks[].command | select(test("block-edit-on-main"))] | length' "$s8d")" "1"
check "distinct matchers: Write registration kept" \
  "$(jq -r '[.hooks.PreToolUse[] | select(.matcher=="Write") | .hooks[].command | select(test("block-edit-on-main"))] | length' "$s8d")" "1"
check "distinct matchers: both repointed at this install" \
  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-edit-on-main")) | select(test("C:/himmel"))] | length' "$s8d")" "2"
check "distinct matchers: no canonical stanza appended" \
  "$(jq -r '[.hooks.PreToolUse[] | select(.matcher=="Edit|Write|MultiEdit|NotebookEdit")] | length' "$s8d")" "0"

# 8e. negative control for 8d: a TRUE double-wire -- the same hook twice under
# the SAME matcher -- is still deduped to one. Without this, 8d would pass on a
# merge that simply stopped deduping at all.
s8e="$td/s8e.json"
cat > "$s8e" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Edit","hooks":[
    {"type":"command","command":"bash \"/old/scripts/hooks/block-edit-on-main.sh\""},
    {"type":"command","command":"bash \"/other/scripts/hooks/block-edit-on-main.sh\""}
  ]}
]}}
JSON
bash "$wire" "$s8e" "C:/himmel" >/dev/null
check "same matcher twice: deduped to one" \
  "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("block-edit-on-main"))] | length' "$s8e")" "1"

# 8f. CodeRabbit round 1: a prefix containing a `"` must still wire. The specs
# JSON is built with `jq -n --arg pfx`, not by interpolating the prefix into
# JSON TEXT — a POSIX path may legally contain a quote, and the old textual
# form produced malformed JSON that `jq --argjson specs` rejected. RED control
# (measured on the pre-fix lib): the run printed "wired PreToolUse hooks ->"
# and left the file UNWIRED — a SILENT false success, not a loud abort, which
# is why this asserts the file content and never the exit line.
s8f="$td/s8f.json"
printf '%s' '{}' > "$s8f"
bash "$wire" "$s8f" '/opt/we"ird/clone' >/dev/null 2>&1 || true
check "quote in prefix: block still wired" "$(jq -r '.hooks.PreToolUse | length' "$s8f" 2>/dev/null)" "3"
# HIMMEL-2905: one layer further out than the JSON. The command is a SHELL
# string, so the prefix must survive a shell round-trip too -- the pre-fix lib
# emitted `bash "/opt/we"ird/clone/scripts/hooks/X.sh"`, whose unmatched quote
# is a syntax error, so the hook (and with it every installed guard) was
# silently inert on such a checkout. Assert the two properties that matter:
# the command PARSES, and the single argument a shell would hand to bash is
# exactly the intended path. RED before the fix: `bash -n -c` exits 2.
cmd8f=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s8f" 2>/dev/null)
if bash -n -c "$cmd8f" 2>/dev/null; then echo "ok - quote in prefix: command parses as shell"
else echo "FAIL - quote in prefix: command does not parse as shell: [$cmd8f]"; fails=$((fails+1)); fi
# `${cmd8f#bash }` is the quoted path exactly as written; printf echoes what
# the shell actually resolved it to -- no eval of the hook itself.
check "quote in prefix: path round-trips through the shell" \
  "$(bash -c "printf '%s\n' ${cmd8f#bash }" 2>/dev/null)" \
  '/opt/we"ird/clone/scripts/hooks/auto-approve-safe-bash.sh'
# ...and the SessionStart composer, which builds its command the same way.
s8f2="$td/s8f2.json"
( . "$wire"; wire_sessionstart_hook "$s8f2" '/opt/we"ird/clone' "inject-initiative.sh" 0 >/dev/null 2>&1 ) || true
cmd8f2=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s8f2" 2>/dev/null)
if bash -n -c "$cmd8f2" 2>/dev/null; then echo "ok - quote in prefix: SessionStart command parses as shell"
else echo "FAIL - quote in prefix: SessionStart command does not parse as shell: [$cmd8f2]"; fails=$((fails+1)); fi
check "quote in prefix: SessionStart path round-trips" \
  "$(bash -c "printf '%s\n' ${cmd8f2#bash }" 2>/dev/null)" \
  '/opt/we"ird/clone/scripts/hooks/inject-initiative.sh'

# 8f2. CodeRabbit on PR #612: the hook BASENAME goes through the same escaper.
# It is an ARGUMENT of wire_sessionstart_hook (and of the --sessionstart CLI),
# not a hardcoded literal like the trio's names, so leaving it unescaped made
# the rule cover only half its own input. Same two properties as 8f.
s8f3="$td/s8f3.json"
( . "$wire"; wire_sessionstart_hook "$s8f3" "C:/himmel" 'we"ird-hook.sh' 0 >/dev/null 2>&1 ) || true
cmd8f3=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s8f3" 2>/dev/null)
if bash -n -c "$cmd8f3" 2>/dev/null; then echo "ok - quote in basename: command parses as shell"
else echo "FAIL - quote in basename: command does not parse as shell: [$cmd8f3]"; fails=$((fails+1)); fi
check "quote in basename: path round-trips through the shell" \
  "$(bash -c "printf '%s\n' ${cmd8f3#bash }" 2>/dev/null)" \
  'C:/himmel/scripts/hooks/we"ird-hook.sh'
# ...and the DEDUP test must still recognise the command it just wrote (CR
# round 3, [codex-1]). Escaping the basename without re-deriving the needle
# from the same escaped string left the pattern unable to match its own
# output, so a re-run APPENDED instead of replacing. RED before that fix:
# 2 hook objects here, at the OLD path.
( . "$wire"; wire_sessionstart_hook "$s8f3" "C:/moved" 'we"ird-hook.sh' 0 >/dev/null 2>&1 ) || true
check "quote in basename: re-wire dedups (no double-wire)" \
  "$(jq -r '[.hooks.SessionStart[].hooks[]] | length' "$s8f3" 2>/dev/null)" "1"
check "quote in basename: re-wire repoints at the new clone path" \
  "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s8f3" 2>/dev/null)" \
  'bash "C:/moved/scripts/hooks/we\"ird-hook.sh"'

# 8g. NEGATIVE control for 8f (load-bearing): the project-scope prefix is the
# LITERAL, unexpanded `$CLAUDE_PROJECT_DIR` -- Claude Code expands it at
# hook-fire time. Escaping it (`\$CLAUDE_PROJECT_DIR`) or single-quoting it
# would kill that expansion and point every project-scope hook at a
# nonexistent path. Without this case, 8f would pass on a blanket escape.
s8g="$td/s8g.json"
bash "$wire" "$s8g" '$CLAUDE_PROJECT_DIR' >/dev/null
# shellcheck disable=SC2016  # the literal, UNEXPANDED $CLAUDE_PROJECT_DIR is the assertion
check "project scope: unexpanded \$CLAUDE_PROJECT_DIR kept verbatim" \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$s8g")" \
  'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/auto-approve-safe-bash.sh"'
s8g2="$td/s8g2.json"
# shellcheck disable=SC2016  # the literal, UNEXPANDED $CLAUDE_PROJECT_DIR is the assertion
( . "$wire"; wire_sessionstart_hook "$s8g2" '$CLAUDE_PROJECT_DIR' "inject-initiative.sh" 0 >/dev/null )
# shellcheck disable=SC2016  # the literal, UNEXPANDED $CLAUDE_PROJECT_DIR is the assertion
check "project scope: SessionStart keeps the literal too" \
  "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s8g2")" \
  'bash "$CLAUDE_PROJECT_DIR/scripts/hooks/inject-initiative.sh"'

# 9. invalid JSON -> refused, file unchanged.
s9="$td/s9.json"
printf '%s' 'nope {' > "$s9"
if bash "$wire" "$s9" "C:/himmel" >/dev/null 2>&1; then
  echo "FAIL: invalid JSON not refused"; fails=$((fails+1))
else
  echo "ok - refuses invalid JSON"
fi
check "invalid file unchanged" "$(cat "$s9")" "nope {"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
