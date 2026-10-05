#!/usr/bin/env bash
# test-block-agent-native-egress.sh — suite for the PreToolUse egress guard on
# the hosted agent-native (Builder.io) MCP (HIMMEL-4328). The suite is the spec.
#
# Hermetic: every git fixture lives under a scratch dir and HOME points at a
# scratch dir, so the station's ~/.config/claude-glm lists and git config are
# never read.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/block-agent-native-egress.sh"
HOOKS_JSON="$HERE/hooks.json"
fail=0
pass=0

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE

mkrepo() { # mkrepo <dir> [origin-url]
    mkdir -p "$1"
    git -C "$1" -c init.defaultBranch=main init -q
    if [ -n "${2:-}" ]; then git -C "$1" remote add origin "$2"; fi
}

SALUS="$TMP/github/salus";           mkrepo "$SALUS" "git@github.com:someone/salus.git"
HIMMEL="$TMP/github/himmel";         mkrepo "$HIMMEL" "git@github.com:someone/Himmel.git"
REMOTE_ONLY="$TMP/github/clinic";    mkrepo "$REMOTE_ONLY" "https://github.com/someone/Salus-app.git"
MARKED="$TMP/github/plain";          mkrepo "$MARKED"; : > "$MARKED/.salus"
mkdir -p "$SALUS/src/app" "$MARKED/deep/dir"
PHI_ROOT="$TMP/phi/records"
mkdir -p "$PHI_ROOT" "$HOME/.config/claude-glm"

TOOL='mcp__plugin_builder-visual_agent-native-dispatch__generate'

payload() { # payload <tool> <cwd> <prompt>
    jq -cn --arg t "$1" --arg c "$2" --arg p "$3" \
        '{session_id:"s",hook_event_name:"PreToolUse",cwd:$c,tool_name:$t,tool_input:{prompt:$p}}'
}

# expect <rc> <label> <stdin>
expect() {
    local want="$1" label="$2" input="$3" rc
    printf '%s' "$input" | bash "$SCRIPT" >/dev/null 2>"$TMP/err"
    rc=$?
    if [ "$rc" = "$want" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label (want rc=$want, got rc=$rc): $(cat "$TMP/err")"
    fi
}

# --- RED rows the ticket names ------------------------------------------------
expect 2 "salus cwd -> agent-native call denied" \
    "$(payload "$TOOL" "$SALUS" "make a landing page")"
expect 0 "himmel cwd -> agent-native call allowed" \
    "$(payload "$TOOL" "$HIMMEL" "make a landing page")"

# --- salus detection signals --------------------------------------------------
expect 2 "subdir of a salus checkout -> denied (git toplevel)" \
    "$(payload "$TOOL" "$SALUS/src/app" "hello")"
expect 2 "repo whose origin remote names salus -> denied" \
    "$(payload "$TOOL" "$REMOTE_ONLY" "hello")"
expect 2 ".salus marker in an ancestor -> denied" \
    "$(payload "$TOOL" "$MARKED/deep/dir" "hello")"
# Symlinks in (HIMMEL-4328 CR codex-2): non-git dirs, so only the canonical
# cwd can reveal salus / the marker.
mkdir -p "$TMP/data/salus-exports/batch" "$TMP/data/nogit-marked/sub" "$TMP/links"
: > "$TMP/data/nogit-marked/.salus"
ln -s "$TMP/data/salus-exports/batch" "$TMP/links/exports"
ln -s "$TMP/data/nogit-marked/sub" "$TMP/links/marked-sub"
expect 2 "cwd is a symlink into a dir whose real path names salus -> denied" \
    "$(payload "$TOOL" "$TMP/links/exports" "hello")"
expect 2 "cwd is a symlink into a .salus-marked tree -> denied" \
    "$(payload "$TOOL" "$TMP/links/marked-sub" "hello")"
expect 2 "himmel cwd, payload names a salus path -> denied" \
    "$(payload "$TOOL" "$HIMMEL" "restyle $SALUS/src/app/page.tsx")"
expect 2 "himmel cwd, payload names salus in mixed case -> denied" \
    "$(payload "$TOOL" "$HIMMEL" "port the SALUS intake form")"

printf '# comment\n  %s/  \n' "$PHI_ROOT" > "$HOME/.config/claude-glm/phi-roots"
expect 2 "himmel cwd, payload names a phi-roots path -> denied" \
    "$(payload "$TOOL" "$HIMMEL" "summarise $PHI_ROOT/patient.md")"
expect 2 "cwd under a phi-roots root -> denied" \
    "$(payload "$TOOL" "$PHI_ROOT" "hello")"
expect 0 "himmel cwd, unrelated payload with phi-roots configured -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "make a landing page")"
# A symlink into a PHI root whose own path names nothing (HIMMEL-4328 CR
# codex-2): the cwd must be canonicalized before the root comparison.
mkdir -p "$TMP/links"
ln -s "$PHI_ROOT" "$TMP/links/records-link"
expect 2 "cwd is a symlink into a phi-roots root -> denied (canonical cwd)" \
    "$(payload "$TOOL" "$TMP/links/records-link" "hello")"
# A payload PATH through a symlink alias into a PHI root (round-2 codex-1):
# path-like payload tokens are resolved against the cwd and canonicalized.
ln -s "$PHI_ROOT" "$HIMMEL/records-alias"
expect 2 "himmel cwd, payload names a RELATIVE alias into a phi-roots root -> denied" \
    "$(payload "$TOOL" "$HIMMEL" "summarise records-alias/patient.md")"
expect 2 "himmel cwd, payload names an ABSOLUTE alias into a phi-roots root -> denied" \
    "$(payload "$TOOL" "$HIMMEL" "summarise $TMP/links/records-link/patient.md please")"
mkdir -p "$HIMMEL/src/app"
expect 0 "himmel cwd, payload names an ordinary relative path -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "restyle src/app/page.tsx and https://example.com/a/b")"
# A list read that fails after the readability check fails closed (round-2
# codex-3). Staged with a cat stub that fails when handed a file operand.
mkdir -p "$TMP/stubbin"
printf '#!/bin/sh\n[ $# -gt 0 ] && exit 1\nexec "%s"\n' "$(command -v cat)" > "$TMP/stubbin/cat"
chmod +x "$TMP/stubbin/cat"
PATH="$TMP/stubbin:$PATH" expect 2 "phi-roots list read fails after the readability check -> denied (fail closed)" \
    "$(payload "$TOOL" "$HIMMEL" "make a landing page")"
chmod 000 "$HOME/.config/claude-glm/phi-roots"
if [ -r "$HOME/.config/claude-glm/phi-roots" ]; then
    pass=$((pass + 1))   # running as root: unreadability cannot be staged
else
    expect 2 "unreadable phi-roots list -> denied (fail closed)" \
        "$(payload "$TOOL" "$HIMMEL" "make a landing page")"
fi
chmod 600 "$HOME/.config/claude-glm/phi-roots"
# A PHI root of "/" covers everything (round-2 codex-2): it must not strip to
# empty and be skipped.
printf '/\n' > "$HOME/.config/claude-glm/phi-roots"
expect 2 "phi-roots root of / -> every call denied" \
    "$(payload "$TOOL" "$HIMMEL" "make a landing page")"
rm -f "$HOME/.config/claude-glm/phi-roots"

# --- tool-name scope ----------------------------------------------------------
expect 2 "directly-registered agent-native server, salus cwd -> denied" \
    "$(payload 'mcp__agent-native-dispatch__generate' "$SALUS" "hello")"
expect 2 "upper-case server name, salus cwd -> denied" \
    "$(payload 'mcp__Agent-Native__x' "$SALUS" "hello")"
expect 0 "other MCP tool in a salus cwd -> not this hook's business" \
    "$(payload 'mcp__plugin_context7_context7__query-docs' "$SALUS" "hello")"
expect 0 "Bash tool in a salus cwd -> not this hook's business" \
    "$(jq -cn --arg c "$SALUS" '{cwd:$c,tool_name:"Bash",tool_input:{command:"ls"}}')"

# --- fail-closed input handling ----------------------------------------------
expect 2 "malformed JSON naming agent-native -> denied" \
    '{"tool_name":"mcp__agent-native-dispatch__x", oops'
expect 0 "malformed JSON not naming agent-native -> allowed" \
    '{"tool_name":"Bash", oops'
# A payload with no cwd falls back to the hook's own $PWD: run it from the
# salus dir so that fallback is the salus checkout.
out_rc=0
( cd "$SALUS" && jq -cn --arg t "$TOOL" '{tool_name:$t,tool_input:{prompt:"x"}}' | bash "$SCRIPT" >/dev/null 2>&1 ) || out_rc=$?
if [ "$out_rc" = 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: no-cwd payload from a salus pwd (want rc=2, got rc=$out_rc)"; fi

# --- wiring: the plugin hooks.json routes agent-native MCP calls here ---------
matcher=$(jq -r '.hooks.PreToolUse[] | select(any(.hooks[]; .command | contains("block-agent-native-egress.sh"))) | .matcher' "$HOOKS_JSON" 2>/dev/null)
if [ -n "$matcher" ] && printf '%s\n' "$TOOL" | grep -Eq "^(${matcher})$" \
    && ! printf '%s\n' 'mcp__plugin_context7_context7__query-docs' | grep -Eq "^(${matcher})$"; then
    pass=$((pass + 1))
else
    fail=$((fail + 1)); echo "FAIL: hooks.json does not route $TOOL to block-agent-native-egress.sh (matcher='$matcher')"
fi
# Claude Code's matcher is case-sensitive while the hook lowercases, so the
# matcher must spell its own case-insensitivity (HIMMEL-4328 CR codex-1).
for name in 'mcp__Agent-Native__x' 'mcp__plugin_builder-visual_AGENT_NATIVE-dispatch__y' 'mcp__agent_Native__z'; do
    if [ -n "$matcher" ] && printf '%s\n' "$name" | grep -Eq "^(${matcher})$"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); echo "FAIL: hooks.json matcher does not route mixed-case $name (matcher='$matcher')"
    fi
done

echo "test-block-agent-native-egress: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
