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
# Past the path-token cap the hook cannot inspect every path, so it fails
# closed (CodeRabbit round 3): a PHI alias after 300 filler paths denies.
filler=""
i=0
while [ "$i" -lt 300 ]; do filler="$filler src/app/f$i.tsx"; i=$((i + 1)); done
expect 2 "PHI alias after more path-like tokens than the cap -> denied (fail closed)" \
    "$(payload "$TOOL" "$HIMMEL" "restyle$filler then records-alias/patient.md")"
ten=""
i=0
while [ "$i" -lt 10 ]; do ten="$ten src/app/f$i.tsx"; i=$((i + 1)); done
expect 0 "himmel cwd, payload names 10 ordinary paths -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "restyle$ten")"
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
# A dangling symlink at the list path is unreadable, not absent (CodeRabbit
# round 3): it must deny, not be skipped.
ln -s "$TMP/nowhere/phi-roots" "$HOME/.config/claude-glm/egress-denylist"
expect 2 "dangling-symlink egress-denylist -> denied (fail closed)" \
    "$(payload "$TOOL" "$HIMMEL" "make a landing page")"
rm -f "$HOME/.config/claude-glm/egress-denylist"

# --- performance: decide well inside the 15 s harness timeout (J1878) --------
# The harness kills a hook at its timeout and ALLOWS the call, so a slow hook
# fails open. Timings via date +%s%N, falling back to SECONDS where %N is
# unsupported (BSD date).
now_ms() {
    local n
    n=$(date +%s%N 2>/dev/null)
    case "$n" in ""|*[!0-9]*) echo $((SECONDS * 1000)) ;; *) echo $((n / 1000000)) ;; esac
}
# expect_fast <rc> <max-ms> <label> <payload-file>
expect_fast() {
    local want="$1" max_ms="$2" label="$3" file="$4" rc a b ms
    a=$(now_ms)
    if command -v timeout >/dev/null 2>&1; then
        timeout $((max_ms / 1000 + 10)) bash "$SCRIPT" < "$file" >/dev/null 2>"$TMP/err"
    else
        bash "$SCRIPT" < "$file" >/dev/null 2>"$TMP/err"
    fi
    rc=$?
    b=$(now_ms)
    ms=$((b - a))
    echo "timing: $label: rc=$rc in ${ms}ms"
    if [ "$rc" = "$want" ] && [ "$ms" -lt "$max_ms" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $label (want rc=$want under ${max_ms}ms, got rc=$rc in ${ms}ms): $(cat "$TMP/err")"
    fi
}
printf '%s\n' "$PHI_ROOT" > "$HOME/.config/claude-glm/phi-roots"
i=0
dense=""
while [ "$i" -lt 15000 ]; do dense="${dense}a/"; i=$((i + 1)); done
printf '%s' "$dense" | jq -Rsc --arg t "$TOOL" --arg c "$PHI_ROOT" \
    '{hook_event_name:"PreToolUse",cwd:$c,tool_name:$t,tool_input:{prompt:.}}' > "$TMP/dense.json"
expect_fast 2 2000 "30 KB dense a/ payload, cwd under a phi-roots root -> denied in under 2 s" "$TMP/dense.json"
# s/S are stripped so random bytes can never spell "salus" (signal 1) and
# short-circuit the row before the budget is what decides it.
head -c 1150000 /dev/urandom | base64 | tr -d '\nsS' | jq -Rsc --arg t "$TOOL" --arg c "$HIMMEL" \
    '{hook_event_name:"PreToolUse",cwd:$c,tool_name:$t,tool_input:{prompt:.}}' > "$TMP/b64.json"
expect_fast 2 5000 "1.5 MB base64 payload, himmel cwd -> denied (over the payload byte budget) in under 5 s" "$TMP/b64.json"
rm -f "$HOME/.config/claude-glm/phi-roots"

# --- fail-closed residuals (HIMMEL-4463) -------------------------------------
printf '%s\n' "$PHI_ROOT" > "$HOME/.config/claude-glm/phi-roots"
: > "$PHI_ROOT/patient.md"
mkdir -p "$HIMMEL/public"
: > "$HIMMEL/public/plain.md"
: > "$TMP/benign.md"
ln -s "$PHI_ROOT/patient.md" "$HIMMEL/public/alias.md"
ln -s "$TMP/benign.md" "$HIMMEL/public/benign-link.md"
# 1. A jq failure while extracting the payload text denies (was: allow).
mkdir -p "$TMP/jqstub"
# shellcheck disable=SC2016  # the stub's $@/$a must stay literal
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *strings*) exit 1 ;; esac; done\nexec "%s" "$@"\n' "$(command -v jq)" > "$TMP/jqstub/jq"
chmod +x "$TMP/jqstub/jq"
PATH="$TMP/jqstub:$PATH" expect 2 "jq fails extracting the payload text -> denied (fail closed)" \
    "$(payload "$TOOL" "$HIMMEL" "restyle src/app/page.tsx")"
# 2. _canon failing on a token that names an existing path denies: an alias to
# a mode-000 PHI root cannot be cd'd into, so it cannot be canonicalized.
LOCKED="$TMP/phi2/locked"
mkdir -p "$LOCKED"
printf '%s\n' "$LOCKED" > "$HOME/.config/claude-glm/phi-roots"
ln -s "$LOCKED" "$HIMMEL/locked-alias"
chmod 000 "$LOCKED"
if [ -x "$LOCKED" ]; then
    pass=$((pass + 1))   # running as root: a mode-000 dir cannot be staged
else
    expect 2 "alias to a mode-000 PHI root (cannot be canonicalized) -> denied (fail closed)" \
        "$(payload "$TOOL" "$HIMMEL" "summarise locked-alias/patients")"
fi
chmod 755 "$LOCKED"
printf '%s\n' "$PHI_ROOT" > "$HOME/.config/claude-glm/phi-roots"
# 3. A path-shaped token over token_max bytes denies (was: skipped).
longp="records-alias"
i=0
while [ "$i" -lt 2100 ]; do longp="$longp/."; i=$((i + 1)); done
expect 2 "alias path token over 4096 bytes -> denied (fail closed)" \
    "$(payload "$TOOL" "$HIMMEL" "summarise $longp/patients")"
# Length alone does not deny: long tokens that are not paths into a root (base64,
# data URIs, minified JS, long URLs) stop the walk at their first missing
# component and are allowed, as they were before item 3.
rep() { local s="" i=0; while [ "$i" -lt "$2" ]; do s="$s$1"; i=$((i + 1)); done; printf '%s' "$s"; }
b64=$(rep 'aGVsbG8/d29ybGQ+' 520)
expect 0 "8 KB data:image/png;base64 URI -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "use data:image/png;base64,$b64")"
expect 0 "raw 8 KB base64 blob with slashes -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "embed $b64")"
expect 0 "8 KB /9j/ JPEG base64 blob -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "embed /9j/4AAQSkZJRgABAQ$b64")"
expect 0 "minified JS line over 4096 bytes containing // -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "inline $(rep 'a="x";//c;' 400)")"
expect 0 "4.2 KB URL -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "see https://example.com/$(rep 'segment/' 540)")"
# A first component no real filesystem can hold (over NAME_MAX) must not be fed
# to pattern expansion: ${x%%/*} on a 262 KB no-slash run takes ~20 s, past the
# 15 s harness timeout, which allows. The alias token after it must still deny.
{ head -c 262000 /dev/zero | tr '\0' x; printf '%s' "/b records-alias/patient.md"; } \
    | jq -Rsc --arg t "$TOOL" --arg c "$HIMMEL" \
    '{hook_event_name:"PreToolUse",cwd:$c,tool_name:$t,tool_input:{prompt:.}}' > "$TMP/huge1.json"
expect_fast 2 3000 "262 KB no-slash first component then an alias token -> denied on the alias in under 3 s" "$TMP/huge1.json"
{ head -c 125000 /dev/zero | tr '\0' '('; printf '%s' "a/b records-alias/patient.md"; } \
    | jq -Rsc --arg t "$TOOL" --arg c "$HIMMEL" \
    '{hook_event_name:"PreToolUse",cwd:$c,tool_name:$t,tool_input:{prompt:.}}' > "$TMP/huge2.json"
expect_fast 2 3000 "125000 punctuation-wrapped token then an alias token -> denied on the alias in under 3 s" "$TMP/huge2.json"
# 4. A wall-clock budget denies. EGRESS_HOOK_BUDGET_S can only LOWER the 10 s
# budget; 0 makes the first path token overrun it, standing in for a slow resolver.
EGRESS_HOOK_BUDGET_S=0 expect 2 "path token resolved past the wall-clock budget -> denied (fail closed)" \
    "$(payload "$TOOL" "$HIMMEL" "restyle src/app/page.tsx")"
EGRESS_HOOK_BUDGET_S=99 expect 0 "a budget override above 10 s is ignored (cannot raise it)" \
    "$(payload "$TOOL" "$HIMMEL" "restyle src/app/page.tsx")"
# 5. A leaf symlink to a file inside a PHI root denies (was: allowed, the walk
# canonicalized only the parent directory).
expect 2 "payload names a LEAF symlink to a file in a phi-roots root -> denied" \
    "$(payload "$TOOL" "$HIMMEL" "summarise public/alias.md")"
expect 0 "payload names a leaf symlink to a benign file outside every root -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "summarise public/benign-link.md")"
expect 0 "payload names a plain file outside every root -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "summarise public/plain.md")"
# A symlink whose target ends in .. is normalized whole: this one points at the
# parent of the PHI root, which is not inside it.
ln -s "$PHI_ROOT/.." "$HIMMEL/public/up-link"
expect 0 "payload names a symlink to the PARENT of a phi-roots root -> allowed" \
    "$(payload "$TOOL" "$HIMMEL" "summarise public/up-link")"
# The budget is also checked after the last token, so a payload whose final
# resolution overran cannot reach the allow.
EGRESS_HOOK_BUDGET_S=0 expect 2 "budget overrun with no path token to trip the per-token check -> denied" \
    "$(payload "$TOOL" "$HIMMEL" "restyle the landing page")"
# 6. The .salus ancestor walk probes /.salus. Root cannot be written to stage a
# real marker, so run the hook's own function with its existence test swapped
# for a recorder.
_probe() { probed="$probed|$1"; return 1; }
eval "$(sed -n '/^_salus_marked() {/,/^}/p' "$SCRIPT" | sed 's/\[ -e \("[^"]*"\) \]/_probe \1/')"
probed=""
_salus_marked "$HIMMEL/src/app" || true
case "$probed" in
    *"|/.salus"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); echo "FAIL: the .salus ancestor walk never probed /.salus (probed: $probed)" ;;
esac
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
