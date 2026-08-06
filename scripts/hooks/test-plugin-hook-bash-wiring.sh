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

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-plugin-hook-bash.XXXXXX")"
trap 'rm -rf "$T"' EXIT
COMMANDS="$T/commands"
FIRED="$T/fired"
ERR="$T/err"
mkdir -p "$T/plugin/hooks" "$T/project/scripts/hooks"
cp "$PLUGIN_LAUNCHER" "$T/plugin/hooks/run-hook-with-bash.js"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

if cmp -s "$CANONICAL_LAUNCHER" "$PLUGIN_LAUNCHER"; then
    ok "plugin launcher is byte-identical to the canonical launcher"
else
    bad "plugin launcher drifted from the canonical launcher"
fi

count="$(jq '[.hooks | to_entries[] | .value[] | .hooks[] | select(.type == "command")] | length' "$HOOKS_JSON")"
if [ "$count" = "16" ]; then
    ok "plugin inventory contains exactly 16 command hooks"
else
    bad "plugin inventory expected 16 command hooks, found $count"
fi

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

cp "$T/fixture-hook.sh" "$T/plugin/hooks/inject-minerva-critic.sh"
for script in \
    block-docker-privesc.sh \
    block-merged-pr-commit.sh \
    block-unresolved-cr-merge.sh \
    block-glm-external-writes.sh \
    block-graphify-egress.sh \
    block-rogue-codex-wsl.sh \
    block-lesson-enforcement-writes.sh \
    guard-implementor-dispatch.sh \
    inject-where-are-we.sh \
    inject-doc-freshness.sh \
    inject-worktree-nudge.sh \
    refresh-where-are-we-on-end.sh \
    jira-nudge-on-end.sh \
    telegram-session-end.sh \
    telegram-notification.sh; do
    cp "$T/fixture-hook.sh" "$T/project/scripts/hooks/$script"
done

jq -r '.hooks | to_entries[] | .value[] | .hooks[] | select(.type == "command") | .command' "$HOOKS_JSON" > "$COMMANDS"
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
if [ "$executed" = "16" ] && [ "$fired" = "16" ]; then
    ok "all 16 plugin-delivered commands executed and forwarded the PreToolUse payload"
else
    bad "expected 16 executed/forwarded commands, got executed=$executed fired=$fired"
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
