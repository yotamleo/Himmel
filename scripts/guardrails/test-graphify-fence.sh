#!/usr/bin/env bash
# Hermetic smoke test for scripts/guardrails/graphify-fence.sh, the narrow hook
# scripts/hooks/block-graphify-egress.sh, and the egress-matrix-eval.mjs helper
# (HIMMEL-621/622 Phase G-F). Builds a temp HOME + fixture vault/handover/himmel
# roots + fake PHI config lists, invokes the fence against REAL graphify-grammar
# command strings (`graphify <subcommand> <path> [--backend=x]`), and asserts the
# matrix verdict plus the fail-closed behaviour confirmed by the CR live probes.
#
# Hermeticity (CR round-2): run_fence scrubs every env var that could leak from
# the developer's shell (GRAPHIFY_*_OK, OPENAI_BASE_URL, DEEPSEEK_BASE_URL,
# LUNA_VAULT, OLLAMA_HOST, and all ten cloud provider keys) so a real key set in
# the outer environment cannot flip a fixture verdict.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
FENCE="$REPO_ROOT/scripts/guardrails/graphify-fence.sh"
HOOK="$REPO_ROOT/scripts/hooks/block-graphify-egress.sh"
EVAL_HELPER="$REPO_ROOT/scripts/guardrails/egress-matrix-eval.mjs"

for f in "$FENCE" "$HOOK" "$EVAL_HELPER"; do
    if [ ! -f "$f" ]; then echo "FAIL: $f not found"; exit 1; fi
done

BASH_BIN="$(command -v bash)"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# --- fixture workspace ------------------------------------------------------
WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT

export HOME="$WS/home"; mkdir -p "$HOME/.claude"
LUNA="$WS/luna";        mkdir -p "$LUNA/Clippings"
SALUS="$WS/salusvault"; mkdir -p "$SALUS/notes"; : > "$SALUS/.salus"
HANDDIR="$WS/handover"; mkdir -p "$HANDDIR"
HIMMEL="$WS/himmelco";  mkdir -p "$HIMMEL/scripts"
PHI="$WS/phicfg";       mkdir -p "$PHI"
PHI_BADROOTS="$WS/phicfg2"; mkdir -p "$PHI_BADROOTS/phi-roots"   # phi-roots is a DIR -> unreadable
DENYROOT="$WS/secretvault"; mkdir -p "$DENYROOT/x"
NOWHERE="$WS/nowhere";  mkdir -p "$NOWHERE"

# an egress-denylist root (path-list membership -> salus corpus)
printf '%s\n' "$DENYROOT" > "$PHI/egress-denylist"

export LUNA_VAULT_PATH="$LUNA"
export HANDOVER_DIR="$HANDDIR"
export CLAUDE_GLM_CONFIG_DIR="$PHI"
export GRAPHIFY_HIMMEL_ROOT="$HIMMEL"
LEDGER="$HOME/.claude/graphify-egress.jsonl"

# make fixture target files
: > "$LUNA/journal-2026.md"
: > "$LUNA/Clippings/clip.md"
: > "$SALUS/notes/patient.md"
: > "$HIMMEL/scripts/thing.sh"
: > "$DENYROOT/x/leak.md"
: > "$NOWHERE/loose.md"

# env vars scrubbed on every fence call so the outer shell cannot leak state in.
CLEAN_ENV="-u GRAPHIFY_SALUS_LOCAL_OK -u GRAPHIFY_CLIPPINGS_GLM_OK -u GRAPHIFY_LEDGER \
-u OPENAI_BASE_URL -u DEEPSEEK_BASE_URL -u LUNA_VAULT -u OLLAMA_HOST \
-u DEEPSEEK_API_KEY -u ZAI_API_KEY -u DASHSCOPE_API_KEY -u OPENAI_API_KEY \
-u ANTHROPIC_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY -u XAI_API_KEY \
-u OPENROUTER_API_KEY -u NVIDIA_API_KEY"

# run_fence <expect: allow|deny> <expect-ledger: yes|no> <cwd> <name> <cmd> [VAR=val ...]
# Extra trailing args are per-call `VAR=val` env assignments (override CLEAN_ENV).
run_fence() {
    local expect="$1" expect_ledger="$2" cwd="$3" name="$4" cmd="$5"; shift 5
    rm -f "$LEDGER"
    local out rc
    # shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
    out=$( cd "$cwd" && env $CLEAN_ENV "$@" "$BASH_BIN" "$FENCE" "$cmd" 2>&1 ); rc=$?
    local ledger_lines=0
    [ -f "$LEDGER" ] && ledger_lines=$(wc -l < "$LEDGER" | tr -d ' ')

    local ok=1
    if [ "$expect" = allow ]; then
        [ "$rc" -eq 0 ] || ok=0
    else
        [ "$rc" -eq 2 ] || ok=0
    fi
    if [ "$expect_ledger" = yes ]; then
        [ "$ledger_lines" -ge 1 ] || ok=0
    else
        [ "$ledger_lines" -eq 0 ] || ok=0
    fi
    if [ "$ok" = 1 ]; then
        pass "$name"
    else
        fail "$name (rc=$rc ledger=$ledger_lines) out=$out"
    fi
}

echo "== corpus x provider cells (real grammar) =="

# salus + GLM -> hard deny
run_fence deny no "$HIMMEL" "salus x glm -> deny" \
    "graphify update $SALUS/notes/patient.md --backend glm"

# salus + ollama WITHOUT opt-in -> deny (conditional cell, flag unset)
run_fence deny no "$HIMMEL" "salus x ollama no-optin -> deny" \
    "graphify update $SALUS/notes/patient.md --backend ollama"

# salus + ollama WITH GRAPHIFY_SALUS_LOCAL_OK=1 -> allow + ledger
run_fence allow yes "$HIMMEL" "salus x ollama opt-in -> allow+ledger" \
    "graphify update $SALUS/notes/patient.md --backend ollama" GRAPHIFY_SALUS_LOCAL_OK=1

# luna journal (non-Clippings) + GLM -> deny (default deny)
run_fence deny no "$HIMMEL" "luna-personal x glm -> deny" \
    "graphify update $LUNA/journal-2026.md --backend glm"

# luna Clippings + GLM WITHOUT opt-in -> deny (conditional cell)
run_fence deny no "$HIMMEL" "clippings x glm no-optin -> deny" \
    "graphify update $LUNA/Clippings/clip.md --backend glm"

# luna Clippings + GLM WITH GRAPHIFY_CLIPPINGS_GLM_OK=1 -> allow + ledger
run_fence allow yes "$HIMMEL" "clippings x glm opt-in -> allow+ledger" \
    "graphify update $LUNA/Clippings/clip.md --backend glm" GRAPHIFY_CLIPPINGS_GLM_OK=1

# luna personal + deepseek -> allow+log + ledger
run_fence allow yes "$HIMMEL" "luna-personal x deepseek -> allow+ledger" \
    "graphify update $LUNA/journal-2026.md --backend deepseek"

# luna personal + openai backend WITH deepseek base url -> allow + ledger
run_fence allow yes "$HIMMEL" "luna-personal x openai(deepseek-baseurl) -> allow+ledger" \
    "graphify update $LUNA/journal-2026.md --backend openai" OPENAI_BASE_URL=https://api.deepseek.com/v1

# luna personal + openai WITHOUT deepseek base url -> deny (undeclared provider)
run_fence deny no "$HIMMEL" "luna-personal x openai(no-baseurl) -> deny" \
    "graphify update $LUNA/journal-2026.md --backend openai"

# himmel path + declared provider -> allow (no ledger)
run_fence allow no "$HIMMEL" "himmel-code x deepseek -> allow (no ledger)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek"

# egress-denylist root membership -> salus corpus -> deny
run_fence deny no "$HIMMEL" "denylist-root x deepseek -> salus deny" \
    "graphify update $DENYROOT/x/leak.md --backend deepseek"

# gemini backend anywhere -> hard deny
run_fence deny no "$HIMMEL" "himmel x gemini -> hard deny" \
    "graphify update $HIMMEL/scripts/thing.sh --backend gemini"

echo "== C1: subcommand grammar + cwd-in-himmel reproduction =="

# (1) THE C1 REPRODUCTION: cwd INSIDE the himmel checkout, salus path arg. Old
# parser took `update` as the target (classified himmel-code via cwd) -> allow.
# New parser skips the subcommand, classifies the salus path -> deny.
run_fence deny no "$HIMMEL/scripts" "C1: update salus path w/ cwd-in-himmel -> deny" \
    "graphify update $SALUS/notes/patient.md --backend=deepseek"

# (15) multi-path merge-graphs: himmel + salus -> most-restrictive salus -> deny
run_fence deny no "$HIMMEL" "merge-graphs himmel+salus -> most-restrictive deny" \
    "graphify merge-graphs $HIMMEL/graphify-out/graph.json $SALUS/graphify-out/graph.json --backend deepseek"

# unclassifiable path-like token in an extraction subcommand -> deny
run_fence deny no "$HIMMEL" "unclassifiable path (extraction) -> deny" \
    "graphify update $NOWHERE/loose.md --backend deepseek"

# graphify present but no path arg at all + himmel cwd + no cloud key -> cwd class -> allow
run_fence allow no "$HIMMEL/scripts" "no-path update, cwd-himmel, no key -> allow" \
    "graphify update --force"

echo "== chained + command-position (fail-open fixes) =="

# (2) chained: first clause allows (himmel), second denies (salus) -> deny overall
run_fence deny no "$HIMMEL" "chained safe;salus -> deny overall" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek ; graphify update $SALUS/notes/patient.md --backend glm"

# (3) bash -c wrapped salus invocation -> deny
run_fence deny no "$HIMMEL" "bash -c salus -> deny" \
    "bash -c \"graphify update $SALUS/notes/patient.md --backend glm\""

# (4) command-substitution binary `\$(which graphify)` salus -> deny
run_fence deny no "$HIMMEL" "\$(which graphify) salus -> deny" \
    "\$(which graphify) update $SALUS/notes/patient.md --backend glm"

# (5) mention negatives -> allow rc 0 (NOT a command-position invocation)
run_fence allow no "$HIMMEL" "mention: grep graphify -> allow" \
    "grep graphify $HIMMEL/scripts/thing.sh"
run_fence allow no "$HIMMEL" "mention: echo graphify -> allow" \
    "echo \"graphify is cool\""

echo "== HIMMEL-621: command-position wrapper skip =="

# (W1) exec wrapper before graphify -> salus still fenced -> deny
run_fence deny no "$HIMMEL" "exec graphify salus -> deny" \
    "exec graphify update $SALUS/notes/patient.md --backend glm"

# (W2) nohup wrapper -> deny
run_fence deny no "$HIMMEL" "nohup graphify salus -> deny" \
    "nohup graphify update $SALUS/notes/patient.md --backend glm"

# (W3) timeout with duration arg -> deny
run_fence deny no "$HIMMEL" "timeout 600 graphify salus -> deny" \
    "timeout 600 graphify update $SALUS/notes/patient.md --backend glm"

# (W3b) timeout with leading -k 5 flag + duration -> deny
run_fence deny no "$HIMMEL" "timeout -k 5 600 graphify salus -> deny" \
    "timeout -k 5 600 graphify update $SALUS/notes/patient.md --backend glm"

# (W4) env -i (options form) -> deny (env -i graphify previously bypassed)
run_fence deny no "$HIMMEL" "env -i graphify salus -> deny" \
    "env -i graphify update $SALUS/notes/patient.md --backend glm"

# (W5) sudo wrapper -> deny
run_fence deny no "$HIMMEL" "sudo graphify salus -> deny" \
    "sudo graphify update $SALUS/notes/patient.md --backend glm"

# (W6) chained wrappers sudo nohup timeout -> deny
run_fence deny no "$HIMMEL" "sudo nohup timeout 600 graphify salus -> deny" \
    "sudo nohup timeout 600 graphify update $SALUS/notes/patient.md --backend glm"

# (W7) BACKSLASH: \graphify seen after _strip_cmd -> deny
run_fence deny no "$HIMMEL" "backslash \\graphify salus -> deny" \
    "\graphify update $SALUS/notes/patient.md --backend glm"

echo "== HIMMEL-621: xargs / find -exec fail-closed deny =="

# (X1) graphify as xargs command -> deny outright (not statically fenceable)
run_fence deny no "$HIMMEL" "xargs graphify -> deny" \
    "echo $SALUS/notes/patient.md | xargs graphify update --backend glm"

# (X2) graphify as find -exec target -> deny outright
run_fence deny no "$HIMMEL" "find -exec graphify -> deny" \
    "find . -name \"*.md\" -exec graphify update {} --backend glm ;"

# (X3) NEGATIVE: `find . -name graphify` is a mention, not an -exec invocation -> allow
run_fence allow no "$HIMMEL" "find -name graphify (mention) -> allow" \
    "find . -name graphify"

echo "== HIMMEL-621: position-0 path + unconditional unclassifiable-deny =="

# (P1) POSITION-0 PATH: first positional is a salus path (no subcommand) -> classified -> deny
run_fence deny no "$HIMMEL" "position-0 salus path (no subcmd) -> deny" \
    "graphify $SALUS/notes/patient.md --backend glm"

# (U1) unclassifiable path under a NON-extraction subcommand (export) -> deny
run_fence deny no "$HIMMEL" "export unclassifiable path -> deny" \
    "graphify export $NOWHERE/x.md --backend glm"

# (U2) query (non-extraction) with a classifiable himmel path AND an unclassifiable path -> deny
run_fence deny no "$HIMMEL" "query himmel + unclassifiable path -> deny" \
    "graphify query $HIMMEL/scripts/thing.sh $NOWHERE/loose.md --backend glm"

echo "== fail-closed infra (ledger / trap / node / phi-roots) =="

# (6) unwritable ledger on an allow+log cell -> deny + no partial ledger line.
# GRAPHIFY_LEDGER parent is a regular file so mkdir -p fails.
: > "$WS/ledblocker"
run_fence deny no "$HIMMEL" "unwritable ledger allow+log -> deny, no partial line" \
    "graphify update $LUNA/journal-2026.md --backend deepseek" GRAPHIFY_LEDGER="$WS/ledblocker/led.jsonl"

# (7) abnormal-exit trap: HOME unset -> $HOME expansion aborts under set -u -> trap -> rc 2
out=$( cd "$HIMMEL" && env -u HOME -u CLAUDE_GLM_CONFIG_DIR "$BASH_BIN" "$FENCE" "graphify update $HIMMEL/scripts/thing.sh --backend deepseek" 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "trap: HOME unset -> rc 2"; else fail "trap: HOME unset expected rc=2 got rc=$rc out=$out"; fi

# (8) node absent (PATH stripped to /usr/bin, which has coreutils but not node) -> rc 2
run_fence deny no "$HIMMEL" "node absent -> rc 2 (fail-closed)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek" PATH=/usr/bin

# (9) unreadable phi-roots (a directory sits at the phi-roots path) -> rc 2
run_fence deny no "$HIMMEL" "unreadable phi-roots -> rc 2" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$PHI_BADROOTS"

echo "== normalization + backend-detect + provider mapping =="

# (10a) .. traversal escaping into salus -> deny
run_fence deny no "$LUNA" ".. traversal Clippings/../../salus -> deny" \
    "graphify update Clippings/../../salusvault/notes/patient.md --backend deepseek"

# (10b) .. traversal escaping Clippings into luna-personal -> deny even with clippings opt-in
run_fence deny no "$LUNA" ".. traversal out of Clippings -> deny (opt-in cannot save it)" \
    "graphify update Clippings/../journal-2026.md --backend glm" GRAPHIFY_CLIPPINGS_GLM_OK=1

# (11) uppercase --backend GLM is lower-cased -> zai-glm -> luna-personal deny
run_fence deny no "$HIMMEL" "uppercase --backend GLM -> deny" \
    "graphify update $LUNA/journal-2026.md --backend GLM"

# (12a) no --backend + himmel path -> local-ollama -> allow (corpus rule, HIMMEL-621)
run_fence allow no "$HIMMEL" "no-backend himmel -> allow (local-ollama)" \
    "graphify update $HIMMEL/scripts/thing.sh"

# (12b) no --backend + luna path -> deny REGARDLESS of env keys (cloud key set here)
run_fence deny no "$HIMMEL" "no-backend luna (w/ cloud key) -> deny (corpus rule)" \
    "graphify update $LUNA/journal-2026.md" DEEPSEEK_API_KEY=sk-test

# (12c) no --backend + himmel path + cloud key -> allow (key no longer flips the verdict)
run_fence allow no "$HIMMEL" "no-backend himmel + cloud key -> allow (key irrelevant now)" \
    "graphify update $HIMMEL/scripts/thing.sh" DEEPSEEK_API_KEY=sk-test

# (13) OLLAMA_HOST off-box + --backend ollama + luna path -> undeclared provider deny
run_fence deny no "$HIMMEL" "OLLAMA_HOST remote + ollama -> deny" \
    "graphify update $LUNA/journal-2026.md --backend ollama" OLLAMA_HOST=remote:11434

echo "== query (no path arg -> cwd classification) =="

# (14a) query with cwd in himmel + no cloud key -> cwd himmel-code x local-ollama -> allow
run_fence allow no "$HIMMEL/scripts" "query cwd-himmel no-key -> allow" \
    "graphify query \"where is the entrypoint\""

# (14b) query with cwd in luna-personal + --backend glm -> luna-personal x zai-glm -> deny
run_fence deny no "$LUNA" "query cwd-luna glm -> deny" \
    "graphify query \"what is in my journal\" --backend glm"

echo "== hook-level: parse + delegation + malformed-json fallback =="

# non-graphify Bash command -> hook exits 0 instantly
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}' | "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: non-graphify -> exit 0"; else fail "hook: non-graphify expected rc=0 got rc=$rc out=$out"; fi

# non-Bash tool -> hook exits 0
out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: non-Bash tool -> exit 0"; else fail "hook: non-Bash expected rc=0 got rc=$rc out=$out"; fi

# graphify salus deny delegated through the hook -> rc 2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
out=$(printf '%s' "$payload" | env HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "DENY"; then pass "hook: graphify salus -> delegated deny rc=2"; else fail "hook: expected rc=2 + DENY got rc=$rc out=$out"; fi

# graphify allow (himmel) delegated through the hook -> rc 0
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update %s --backend deepseek"}}' "$HIMMEL/scripts/thing.sh")
out=$(printf '%s' "$payload" | env HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: graphify himmel -> delegated allow rc=0"; else fail "hook: expected rc=0 got rc=$rc out=$out"; fi

# (16) malformed hook JSON that mentions a graphify command + jq present -> deny
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"graphify update /x --backend glm"' | env HOME="$HOME" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "hook: malformed JSON + graphify -> deny rc=2"; else fail "hook: malformed JSON expected rc=2 got rc=$rc out=$out"; fi

# malformed hook JSON WITHOUT graphify -> allow (never block unrelated on bad payload)
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"' | env HOME="$HOME" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: malformed JSON no-graphify -> allow rc=0"; else fail "hook: malformed no-graphify expected rc=0 got rc=$rc out=$out"; fi

echo "== ledger line CONTENT (verdict + corpus fields) =="

# allow+log: luna-personal x deepseek -> ledger line carries verdict + corpus
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify update $LUNA/journal-2026.md --backend deepseek" ) >/dev/null 2>&1
if grep -q '"verdict":"allow+log"' "$LEDGER" 2>/dev/null && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null; then
    pass "ledger content: allow+log verdict + luna-personal corpus"
else
    fail "ledger content allow+log: got $(cat "$LEDGER" 2>/dev/null)"
fi

# conditional: clippings x glm opt-in -> ledger line carries conditional + luna-clippings
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_CLIPPINGS_GLM_OK=1 "$BASH_BIN" "$FENCE" "graphify update $LUNA/Clippings/clip.md --backend glm" ) >/dev/null 2>&1
if grep -q '"verdict":"conditional"' "$LEDGER" 2>/dev/null && grep -q '"corpus":"luna-clippings"' "$LEDGER" 2>/dev/null; then
    pass "ledger content: conditional verdict + luna-clippings corpus"
else
    fail "ledger content conditional: got $(cat "$LEDGER" 2>/dev/null)"
fi

# nested handover root (HIMMEL-817, post-HIMMEL-343 fold): HANDOVER_DIR INSIDE
# the vault -> the path classifies as the VAULT corpus (luna-personal, rank 4),
# NOT handover-state (rank 2) — vault roots are checked first, so a fold-style
# setup tightens classification and the handover-state row keeps serving only
# Mode-B external state repos. deepseek extraction verdict stays allow+log.
mkdir -p "$LUNA/handovers/op"
: > "$LUNA/handovers/op/next-session-1.md"
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV HANDOVER_DIR="$LUNA/handovers" "$BASH_BIN" "$FENCE" "graphify update $LUNA/handovers/op/next-session-1.md --backend deepseek" ) >/dev/null 2>&1
if grep -q '"verdict":"allow+log"' "$LEDGER" 2>/dev/null && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null; then
    pass "nested HANDOVER_DIR inside vault classifies as luna-personal (allow+log)"
else
    fail "nested handover root: got $(cat "$LEDGER" 2>/dev/null)"
fi

echo "== egress-matrix-eval.mjs unit =="

# pending-operator cell -> verdict deny
v=$(node "$EVAL_HELPER" luna-clippings alibaba embedding 2>/dev/null | cut -f1)
if [ "$v" = deny ]; then pass "eval: pending-operator -> deny"; else fail "eval: pending-operator expected deny got '$v'"; fi

# no rule match -> default (deny)
v=$(node "$EVAL_HELPER" no-such-corpus no-such-provider extraction 2>/dev/null | cut -f1)
if [ "$v" = deny ]; then pass "eval: default -> deny"; else fail "eval: default expected deny got '$v'"; fi

# bad args -> exit 2
node "$EVAL_HELPER" onlyone >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "eval: bad args -> exit 2"; else fail "eval: bad args expected exit 2 got rc=$rc"; fi

# --- redirection tokens are I/O plumbing, never classified (final round) ---
run_fence allow no "$HIMMEL" "redirect: attached >/tmp/out -> not classified, allow" \
    "graphify update $HIMMEL/doc.md --backend deepseek >/tmp/redir-out.log"
run_fence allow no "$HIMMEL" "redirect: standalone > target skipped -> allow" \
    "graphify update $HIMMEL/doc.md --backend deepseek > /tmp/redir-out.log"
run_fence deny no "$HIMMEL" "redirect: 2>/dev/null on salus target still denies" \
    "graphify update $SALUS/notes/patient.md --backend glm 2>/dev/null"

echo "== HIMMEL-778: MSYS drive-path normalization =="

# (M1) MSYS-form path under the himmel root -> himmel-code allow. PURE LEXICAL
# (drive-lettered root + /c/... candidate) so it genuinely exercises the
# translation on ANY OS - no real /c dir needed.
run_fence allow no "$HIMMEL" "MSYS /c/... under himmel root -> himmel-code allow" \
    "graphify update /c/fake/himmel/doc.md --backend deepseek" GRAPHIFY_HIMMEL_ROOT="C:/fake/himmel"

# (M2) MSYS-form path under the luna root -> luna-personal (allow+log + ledger).
run_fence allow yes "$HIMMEL" "MSYS /c/... under luna root -> luna-personal allow+ledger" \
    "graphify update /c/fake/luna/journal.md --backend deepseek" LUNA_VAULT_PATH="C:/fake/luna"

# (M3) THE --version regression: no path arg -> cwd fallback. The himmel root is
# supplied drive-lettered (as git prints it); the fence must still classify the
# cwd as himmel-code. drive_form() below yields a genuine drive-lettered/MSYS
# mismatch on Windows Git Bash (where $PWD is /c/...) and degrades to a plain
# match under a POSIX /tmp fixture root (still green).
drive_form() {  # /c/Users/x -> C:/Users/x ; POSIX /tmp/x unchanged
    local L
    case "$1" in
        /[A-Za-z]/*) L=$(printf '%s' "$1" | cut -c2 | tr '[:lower:]' '[:upper:]'); printf '%s:/%s' "$L" "${1#/?/}" ;;
        /[A-Za-z])   L=$(printf '%s' "$1" | cut -c2 | tr '[:lower:]' '[:upper:]'); printf '%s:/' "$L" ;;
        *)           printf '%s' "$1" ;;
    esac
}
ROOT_DRIVE=$( cd "$HIMMEL" && drive_form "$PWD" )
run_fence allow no "$HIMMEL/scripts" "MSYS --version cwd-in-himmel (drive-lettered root) -> allow" \
    "graphify --version" GRAPHIFY_HIMMEL_ROOT="$ROOT_DRIVE"

BACKSLASH_SALUS="$SALUS/notes/patient.md"
BACKSLASH_SALUS="${BACKSLASH_SALUS//\//\\}"
run_fence deny no "$HIMMEL" "backslash-form absolute salus path -> deny" \
    "graphify update $BACKSLASH_SALUS --backend deepseek"

run_fence allow no "$HIMMEL" "drive-relative C:scripts/thing.sh anchors to cwd -> allow" \
    "graphify update C:scripts/thing.sh --backend deepseek"

echo "== HIMMEL-778: .graphify-corpus staged-copy declaration =="

STAGED="$WS/staged";        mkdir -p "$STAGED";        : > "$STAGED/copy.md";  printf 'luna-personal\n' > "$STAGED/.graphify-corpus"
STAGED_SALUS="$WS/stgsalus"; mkdir -p "$STAGED_SALUS"; : > "$STAGED_SALUS/copy.md"; printf 'salus\n'        > "$STAGED_SALUS/.graphify-corpus"
STAGED_BAD="$WS/stgbad";     mkdir -p "$STAGED_BAD";   : > "$STAGED_BAD/copy.md";   printf 'banana\n'       > "$STAGED_BAD/.graphify-corpus"
STAGED_NONE="$WS/stgnone";   mkdir -p "$STAGED_NONE";  : > "$STAGED_NONE/copy.md"
STAGED_HIM="$WS/stghim";     mkdir -p "$STAGED_HIM";   : > "$STAGED_HIM/copy.md";   printf 'himmel-code\n'  > "$STAGED_HIM/.graphify-corpus"

# (S1) staged copy declares luna-personal + deepseek -> allow+log + ledger
run_fence allow yes "$HIMMEL" "staged marker luna-personal + deepseek -> allow+ledger" \
    "graphify update $STAGED/copy.md --backend deepseek"

# (S2) staged copy declares salus + deepseek -> hard salus deny
run_fence deny no "$HIMMEL" "staged marker salus + deepseek -> deny (hard salus row)" \
    "graphify update $STAGED_SALUS/copy.md --backend deepseek"

# (S3) staged marker with invalid content -> deny
run_fence deny no "$HIMMEL" "staged marker invalid content -> deny" \
    "graphify update $STAGED_BAD/copy.md --backend deepseek"

# (S4) staged dir with NO marker -> deny (existing unclassifiable behavior held)
run_fence deny no "$HIMMEL" "staged dir no marker -> deny (unclassifiable)" \
    "graphify update $STAGED_NONE/copy.md --backend deepseek"

# (S5) marker INSIDE the real luna root claiming himmel-code -> luna-personal wins
# (real root beats the marker; classification NOT relaxed; no declared field).
rm -f "$LEDGER"
printf 'himmel-code\n' > "$LUNA/.graphify-corpus"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify update $LUNA/journal-2026.md --backend deepseek" ) >/dev/null 2>&1; rc_s5=$?
rm -f "$LUNA/.graphify-corpus"
if [ "$rc_s5" -eq 0 ] && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null && ! grep -q '"declared":true' "$LEDGER" 2>/dev/null; then
    pass "marker in REAL luna claiming himmel-code -> luna-personal (real root wins)"
else
    fail "marker-in-real-luna: rc=$rc_s5 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (S6) declared himmel-code marker + ollama (matrix verdict is PLAIN allow) ->
# ledger line IS written and carries "declared":true (audit cannot be dodged).
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify update $STAGED_HIM/copy.md --backend ollama" ) >/dev/null 2>&1; rc_s6=$?
if [ "$rc_s6" -eq 0 ] && grep -q '"declared":true' "$LEDGER" 2>/dev/null && grep -q '"corpus":"himmel-code"' "$LEDGER" 2>/dev/null; then
    pass "declared himmel-code marker + ollama (plain allow) -> ledger w/ declared:true"
else
    fail "declared-audit: rc=$rc_s6 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (S7) marker file present but UNREADABLE -> deny (fail-closed). Skip gracefully
# where chmod cannot drop read (admin on Windows, root on Linux).
STAGED_UR="$WS/stgunread"; mkdir -p "$STAGED_UR"; : > "$STAGED_UR/copy.md"; printf 'luna-personal\n' > "$STAGED_UR/.graphify-corpus"
chmod 000 "$STAGED_UR/.graphify-corpus" 2>/dev/null || true
if [ -r "$STAGED_UR/.graphify-corpus" ]; then
    printf '  SKIP  unreadable .graphify-corpus marker (chmod could not drop read perm here)\n'
else
    run_fence deny no "$HIMMEL" "unreadable .graphify-corpus marker -> deny (fail-closed)" \
        "graphify update $STAGED_UR/copy.md --backend deepseek"
fi
chmod 644 "$STAGED_UR/.graphify-corpus" 2>/dev/null || true

# (S8) marker WITHOUT a trailing newline is still valid (CR codex-1: `read`
# exits non-zero on EOF-without-newline but populates the variable; the old
# `|| line=""` cleared it -> false deny on a `printf 'x' >` marker).
STAGED_NONL="$WS/stgnonl"; mkdir -p "$STAGED_NONL"; : > "$STAGED_NONL/copy.md"; printf 'luna-personal' > "$STAGED_NONL/.graphify-corpus"
run_fence allow yes "$HIMMEL" "staged marker with NO trailing newline -> still classifies (allow+ledger)" \
    "graphify update $STAGED_NONL/copy.md --backend deepseek"

# (S10) UNCONFIGURED luna root -> the marker is INERT (silent-failure CR round:
# without a visible luna root the real-root-beats-marker precedence cannot be
# enforced, so a valid marker must NOT classify; pre-marker deny behavior).
run_fence deny no "$HIMMEL" "no luna root configured -> valid marker is inert (deny)" \
    "graphify update $STAGED/copy.md --backend deepseek" LUNA_VAULT_PATH=

# (S6b) declared marker + PLAIN-allow cell (himmel-code x ollama) + UNWRITABLE
# ledger -> DENY (pr-test-analyzer: the always-ledger audit on a plain allow is
# its own branch in apply_verdict; dropping its `|| deny` must not pass green).
run_fence deny no "$HIMMEL" "declared + plain allow + unwritable ledger -> deny (audit required)" \
    "graphify update $STAGED_HIM/copy.md --backend ollama" GRAPHIFY_LEDGER="$WS/ledblocker/led.jsonl"

# (S9) filesystem walks use the ORIGINAL path form: an MSYS-form (/c/...)
# target must still find its .graphify-corpus marker (the stat-walk runs on
# the untranslated path; only root COMPARISON uses the drive-translated form).
# Windows-only shape - needs cygpath to produce a real MSYS form of $STAGED.
if command -v cygpath >/dev/null 2>&1; then
    # cygpath -u round-trips mounted paths (/tmp stays /tmp), so build the raw
    # /x/... form by hand from the drive-lettered mixed form: C:/foo -> /c/foo.
    STAGED_MIXED="$(cygpath -m "$STAGED" 2>/dev/null || true)"
    case "$STAGED_MIXED" in
        [A-Za-z]:/*)
            _drv="$(printf '%s' "${STAGED_MIXED%%:*}" | tr '[:upper:]' '[:lower:]')"
            STAGED_MSYS="/${_drv}${STAGED_MIXED#?:}"
            run_fence allow yes "$HIMMEL" "MSYS-form staged path still finds its marker (walk on original form)" \
                "graphify update $STAGED_MSYS/copy.md --backend deepseek"
            ;;
        *) printf '  SKIP  MSYS-form marker walk (no drive-lettered form here)\n' ;;
    esac
else
    printf '  SKIP  MSYS-form marker walk (no cygpath on this platform)\n'
fi

echo "== HIMMEL-778 CR: declared bit is INVOCATION-WIDE (ordering cannot suppress audit) =="

# (D1) real himmel-code path FIRST, then a staged himmel-code-declared path
# (same rank 1): the marker token loses the strictly-greater rank comparison,
# but the ledger line with declared:true MUST still be written (the
# ordering-bypass case the CR found).
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify merge-graphs $HIMMEL/scripts/thing.sh $STAGED_HIM/copy.md --backend ollama" ) >/dev/null 2>&1; rc_d1=$?
if [ "$rc_d1" -eq 0 ] && grep -q '"declared":true' "$LEDGER" 2>/dev/null; then
    pass "real himmel FIRST + staged himmel marker -> allow + declared ledger (order bypass closed)"
else
    fail "ordering-bypass D1: rc=$rc_d1 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (D2) same two paths in REVERSE order -> same outcome (order-independence).
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify merge-graphs $STAGED_HIM/copy.md $HIMMEL/scripts/thing.sh --backend ollama" ) >/dev/null 2>&1; rc_d2=$?
if [ "$rc_d2" -eq 0 ] && grep -q '"declared":true' "$LEDGER" 2>/dev/null; then
    pass "staged himmel marker FIRST + real himmel -> allow + declared ledger (order-independent)"
else
    fail "ordering-bypass D2: rc=$rc_d2 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (D3) staged luna-personal-declared path + real himmel-code path in ONE
# invocation -> most-restrictive still wins (luna-personal x deepseek ->
# allow+log) AND declared:true is present.
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify merge-graphs $HIMMEL/scripts/thing.sh $STAGED/copy.md --backend deepseek" ) >/dev/null 2>&1; rc_d3=$?
if [ "$rc_d3" -eq 0 ] && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null \
    && grep -q '"verdict":"allow+log"' "$LEDGER" 2>/dev/null && grep -q '"declared":true' "$LEDGER" 2>/dev/null; then
    pass "staged luna-personal + real himmel -> most-restrictive wins + declared ledger"
else
    fail "mixed-corpus D3: rc=$rc_d3 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
