#!/usr/bin/env bash
# Integration coverage for plugin-delivered hook commands (HIMMEL-1526).
# Executes the live hooks.json command strings with a real PreToolUse payload,
# then proves a wired security guard still refuses a dangerous command.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/marketplace/plugins/himmel-ops"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
CANONICAL_LAUNCHER="$HOOKS_DIR/run-hook-with-bash.js"
PLUGIN_LAUNCHER="$PLUGIN_ROOT/hooks/run-hook-with-bash.js"
# HIMMEL-2047: the node-resolving launcher is VENDORED into the plugin
# (same pattern as run-hook-with-bash.js above) rather than sourced from
# $CLAUDE_PROJECT_DIR — that path is attacker-controlled for whatever
# project the plugin happens to be active in, and CR round 2's critic-panel
# finding [codex-1] is right that sourcing an arbitrary project file there,
# unconditionally, would let an untrusted opened repo execute code on every
# hook event. Two more byte-identical pairs to track.
CANONICAL_RUN_NODE="$REPO_ROOT/scripts/lib/run-node.sh"
PLUGIN_RUN_NODE="$PLUGIN_ROOT/hooks/run-node.sh"
CANONICAL_RESOLVE_NODE="$REPO_ROOT/scripts/lib/resolve-node.sh"
PLUGIN_RESOLVE_NODE="$PLUGIN_ROOT/hooks/resolve-node.sh"
# HIMMEL-2528: the launcher's hook-integrity verification moved into a sibling
# module it requires by a directory-relative path, so the plugin needs its own
# vendored copy for the same reason the launcher does. A fourth byte-identical
# pair to track.
CANONICAL_HOOK_INTEGRITY="$HOOKS_DIR/hook-integrity.js"
PLUGIN_HOOK_INTEGRITY="$PLUGIN_ROOT/hooks/hook-integrity.js"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-plugin-hook-bash.XXXXXX")"
trap 'rm -rf "$T"' EXIT
COMMANDS="$T/commands"
FIRED="$T/fired"
ERR="$T/err"
mkdir -p "$T/plugin/hooks" "$T/project/scripts/hooks"
cp "$PLUGIN_LAUNCHER" "$T/plugin/hooks/run-hook-with-bash.js"
cp "$PLUGIN_RUN_NODE" "$T/plugin/hooks/run-node.sh"
cp "$PLUGIN_RESOLVE_NODE" "$T/plugin/hooks/resolve-node.sh"
# The sandboxed launcher requires ./hook-integrity.js from its own directory.
cp "$PLUGIN_HOOK_INTEGRITY" "$T/plugin/hooks/hook-integrity.js"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

if cmp -s "$CANONICAL_LAUNCHER" "$PLUGIN_LAUNCHER"; then
    ok "plugin launcher is byte-identical to the canonical launcher"
else
    bad "plugin launcher drifted from the canonical launcher"
fi

if cmp -s "$CANONICAL_RUN_NODE" "$PLUGIN_RUN_NODE"; then
    ok "plugin run-node.sh is byte-identical to scripts/lib/run-node.sh"
else
    bad "plugin run-node.sh drifted from scripts/lib/run-node.sh"
fi

if cmp -s "$CANONICAL_RESOLVE_NODE" "$PLUGIN_RESOLVE_NODE"; then
    ok "plugin resolve-node.sh is byte-identical to scripts/lib/resolve-node.sh"
else
    bad "plugin resolve-node.sh drifted from scripts/lib/resolve-node.sh"
fi

if cmp -s "$CANONICAL_HOOK_INTEGRITY" "$PLUGIN_HOOK_INTEGRITY"; then
    ok "plugin hook-integrity.js is byte-identical to scripts/hooks/hook-integrity.js"
else
    bad "plugin hook-integrity.js drifted from scripts/hooks/hook-integrity.js"
fi

# HIMMEL-1952: no hardcoded inventory count here — wire-plugin-hook-bash.mjs's
# own EXPECTED_HOOKS/EXPECTED_COUNTS (exercised by
# wire-plugin-hook-bash.test.mjs, which already hardcodes "20" as an
# independent restatement of THIS SAME hooks.json) is the wall that already
# owns that invariant; a second hardcoded copy here would just be a second
# wall for the 21st hook to climb. $count below is used only internally, as
# the expected side of the real (non-vacuous) invariant further down: the
# number of commands the launcher actually dispatched and forwarded a
# payload for, measured at runtime, must match the number jq finds in the
# static inventory.
count="$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.type == "command")] | length' "$HOOKS_JSON")"

if jq -e '[.hooks | to_entries[] | .value[] | .hooks[] | .command | select(test("(^|[[:space:]])bash([[:space:]]|$)"))] | length == 0' "$HOOKS_JSON" >/dev/null; then
    ok "plugin command inventory contains no bare bash token"
else
    bad "plugin command inventory still contains a bare bash token"
fi

cat > "$T/fixture-hook.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -u
input=$(cat)
case "$input" in
    *'"hook_event_name":"PreToolUse"'*'"tool_name":"Bash"'*) ;;
    *) echo "fixture did not receive a PreToolUse Bash payload" >&2; exit 3 ;;
esac
printf '%s\n' "$(basename "$0")" >> "$FIRED"
FIXTURE
chmod +x "$T/fixture-hook.sh"

jq -r '.hooks | to_entries[] | .value[] | .hooks[] | select(.type == "command") | .command' "$HOOKS_JSON" > "$COMMANDS"

# HIMMEL-1952: no hardcoded script list either — derive which scripts to
# fixture-stub straight from the inventory's own command strings, so a new
# hook (this branch's record-primary-baseline.sh; the 21st someone adds next)
# gets stubbed automatically without anyone naming it here. Each command
# names exactly one non-launcher .sh target today (no --chain in hooks.json),
# but this loop copes with more than one per command should that change:
# every ".sh" token is a candidate, we just drop the launcher scripts
# (run-node.sh, resolve-node.sh) that ride along in every command string.
while IFS= read -r command; do
    while IFS= read -r sh_path; do
        base="$(basename "$sh_path")"
        case "$base" in
            run-node.sh | resolve-node.sh) continue ;;
        esac
        # shellcheck disable=SC2016 # deliberately literal: $sh_path holds the
        # raw ${CLAUDE_PLUGIN_ROOT} text straight out of hooks.json, unexpanded
        case "$sh_path" in
            '${CLAUDE_PLUGIN_ROOT}/hooks/'*) dest="$T/plugin/hooks/$base" ;;
            *) dest="$T/project/scripts/hooks/$base" ;;
        esac
        cp "$T/fixture-hook.sh" "$dest"
    done < <(printf '%s\n' "$command" | grep -oE '"[^"]*\.sh"' | tr -d '"')
done < "$COMMANDS"
PAYLOAD='{"session_id":"himmel-1526-test","cwd":"fixture","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf harmless"}}'
executed=0
while IFS= read -r command; do
    printf '%s' "$PAYLOAD" | env \
        CLAUDE_PLUGIN_ROOT="$T/plugin" \
        CLAUDE_PROJECT_DIR="$T/project" \
        FIRED="$FIRED" \
        bash -c "$command" >/dev/null 2>"$ERR"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        bad "plugin fixture command $((executed + 1)) exited $rc: $(cat "$ERR")"
        break
    fi
    executed=$((executed + 1))
done < "$COMMANDS"

fired=0
if [ -f "$FIRED" ]; then
    fired="$(wc -l < "$FIRED" | tr -d '[:space:]')"
fi
if [ "$executed" = "$count" ] && [ "$fired" = "$count" ]; then
    ok "all $count plugin-delivered commands executed and forwarded the PreToolUse payload"
else
    bad "expected $count executed/forwarded commands (per plugin inventory), got executed=$executed fired=$fired"
fi

GUARD_COMMAND="$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("block-docker-privesc.sh")) | .hooks[0].command' "$HOOKS_JSON")"
BAD_PAYLOAD='{"session_id":"himmel-1526-positive-control","cwd":"fixture","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"docker run --rm --privileged alpine true"}}'
printf '%s' "$BAD_PAYLOAD" | env \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    CLAUDE_PROJECT_DIR="$REPO_ROOT" \
    bash -c "$GUARD_COMMAND" >/dev/null 2>"$ERR"
guard_rc=$?
if [ "$guard_rc" -eq 2 ] && grep -q 'root-equivalent container access' "$ERR"; then
    ok "positive control: wired block-docker-privesc refused --privileged (exit 2)"
else
    bad "positive control: wired block-docker-privesc expected refusal, got exit $guard_rc: $(cat "$ERR")"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
