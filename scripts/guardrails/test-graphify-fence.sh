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

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

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
HIMMEL_UPPER="$HIMMEL/CorpusDir"; mkdir -p "$HIMMEL_UPPER"      # HIMMEL-3641 codex-1: uppercase-C path, non-PHI

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
: > "$HIMMEL_UPPER/thing.sh"

# env vars scrubbed on every fence call so the outer shell cannot leak state in.
CLEAN_ENV="-u GRAPHIFY_SALUS_LOCAL_OK -u GRAPHIFY_CLIPPINGS_GLM_OK -u GRAPHIFY_LEDGER \
-u GRAPHIFY_TOOL_CWD -u GRAPHIFY_DECLARED_BACKEND \
-u OPENAI_BASE_URL -u DEEPSEEK_BASE_URL -u ANTHROPIC_BASE_URL -u LUNA_VAULT -u OLLAMA_HOST \
-u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY \
-u CLAUDE_CODE_USE_GATEWAY -u CLAUDE_CODE_USE_MANTLE -u CLAUDE_CODE_USE_ANTHROPIC_AWS \
-u CLAUDE_CODE_USE_COWORK_PLUGINS -u CLAUDE_CODE_USE_POWERSHELL_TOOL \
-u DEEPSEEK_API_KEY -u ZAI_API_KEY -u DASHSCOPE_API_KEY -u OPENAI_API_KEY \
-u ANTHROPIC_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY -u XAI_API_KEY \
-u OPENROUTER_API_KEY -u NVIDIA_API_KEY -u BASH_ENV"

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

# HIMMEL-2120 Task-3 manifest (corpus-reduction plan): every run_fence case in
# this file from here through the CLAUDE_CODE_USE_* reroute section (:110-408
# at review time) was mapped to its graphify-fence.sh branch and disposition
# `keep` / `drop->survivor`. Drops were gated to intra-branch duplicates with
# NO ticket-ID or salus/PHI-corpus citation (Global Constraint - when in
# doubt, keep); 64 of 65 cases keep on that bar (ticket-cited: HIMMEL-1122/
# 1257/1049/1070/1133; salus/PHI: the salus + denylist-root rows; distinct
# code path or literal otherwise - e.g. two-sided OR-pattern alias/lookalike
# coverage that a single case cannot prove). Exactly ONE case dropped: the
# former "luna x claude(http://api.z.ai) -> deny (https only)" sibling of the
# surviving "http://api.anthropic.com" case just below - see that case's
# comment for the branch trace. Full per-case table: task-3-report.md under
# .superpowers/sdd/2026-08-26-himmel-2120-corpus-reduction/.
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

# luna journal (non-Clippings) + GLM -> DENY (HIMMEL-2224/1749: the GLM/Z.ai
# Coding Plan lapsed 2026-08-17, so this cell was reversed from HIMMEL-1122's
# allow+log to an explicit deny — no CN/cloud extraction lane remains for
# luna-personal now that kimi/moonshot is also retired (HIMMEL-2101);
# claude-cli, the operating substrate, is the sanctioned semantic backend).
run_fence deny no "$HIMMEL" "luna-personal x glm -> deny (GLM de-listed, HIMMEL-2224/1749)" \
    "graphify update $LUNA/journal-2026.md --backend glm"

# kimi/Moonshot is retired (operator ruling 2026-08-24/2026-09-15, HIMMEL-2101):
# there is no kimi backend any more. graphify-fence.sh no longer classifies it
# (the deleted _map_kimi_endpoint mapping), so --backend kimi now falls to the
# undeclared-literal-backend default: deny on any non-himmel-code corpus.
run_fence deny no "$HIMMEL" "luna-personal x kimi (retired, HIMMEL-2101) -> deny (unclassified backend, fail-closed default)" \
    "graphify update $LUNA/journal-2026.md --backend kimi"

# luna Clippings + GLM -> deny (HIMMEL-2224: the cell is now a plain matrix
# deny, not a conditional gated by a missing opt-in)
run_fence deny no "$HIMMEL" "clippings x glm no-optin -> deny" \
    "graphify update $LUNA/Clippings/clip.md --backend glm"

# luna Clippings + GLM WITH the retired GRAPHIFY_CLIPPINGS_GLM_OK=1 opt-in ->
# still DENY (HIMMEL-2224/1749: the cell flipped from conditional to explicit
# deny, so the retired opt-in can no longer open it — the single most
# valuable control here, proving the flag is dead, not merely unset).
run_fence deny no "$HIMMEL" "clippings x glm opt-in -> deny (retired opt-in, HIMMEL-2224/1749)" \
    "graphify update $LUNA/Clippings/clip.md --backend glm" GRAPHIFY_CLIPPINGS_GLM_OK=1

# luna personal + deepseek -> DENY (HIMMEL-1257: DeepSeek de-listed, bad results)
run_fence deny no "$HIMMEL" "luna-personal x deepseek -> deny (HIMMEL-1257 de-listed)" \
    "graphify update $LUNA/journal-2026.md --backend deepseek"

# luna personal + openai backend WITH deepseek base url -> DENY (maps to the
# de-listed deepseek provider). NOTE (HIMMEL-1257): post de-listing, deepseek
# behaves exactly like an undeclared provider everywhere (deny on vaults, allow
# on himmel-code's wildcard), so the OPENAI_BASE_URL->deepseek MAPPING is no
# longer observable by verdict — a himmel-code probe would allow whether or not
# the base-url mapped (the wildcard admits any openai). This case pins the
# POLICY that matters (luna denies the deepseek-base-url'd backend).
run_fence deny no "$HIMMEL" "luna-personal x openai(deepseek-baseurl) -> deny (HIMMEL-1257)" \
    "graphify update $LUNA/journal-2026.md --backend openai" OPENAI_BASE_URL=https://api.deepseek.com/v1

# luna personal + openai WITHOUT deepseek base url -> deny (undeclared provider)
run_fence deny no "$HIMMEL" "luna-personal x openai(no-baseurl) -> deny" \
    "graphify update $LUNA/journal-2026.md --backend openai"

# himmel path + declared provider -> allow (no ledger). deepseek stays a valid
# example of the himmel-code allow-any wildcard (public code, provider-agnostic).
run_fence allow no "$HIMMEL" "himmel-code x deepseek -> allow (no ledger)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek"

# egress-denylist root membership -> salus corpus -> deny
run_fence deny no "$HIMMEL" "denylist-root x deepseek -> salus deny" \
    "graphify update $DENYROOT/x/leak.md --backend deepseek"

# gemini backend anywhere -> hard deny
run_fence deny no "$HIMMEL" "himmel x gemini -> hard deny" \
    "graphify update $HIMMEL/scripts/thing.sh --backend gemini"

echo "== claude backend -> anthropic: warn-not-block per corpus (HIMMEL-1049) =="

# claude backend maps to the anthropic provider (the operating harness itself).
# The matrix ALLOWS anthropic on every non-salus corpus (WARN-not-block: the
# adopter proceeds) and HARD-DENIES salus/PHI (invariant, stays blocked).

# himmel-code x claude -> allow (no ledger)
run_fence allow no "$HIMMEL" "himmel-code x claude -> allow (warn-not-block)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude"

# claude-cli alias maps identically -> allow
run_fence allow no "$HIMMEL" "himmel-code x claude-cli -> allow (alias)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli"

# luna-personal x claude -> allow (anthropic = operating substrate, no ledger)
run_fence allow no "$HIMMEL" "luna-personal x claude -> allow (warn-not-block)" \
    "graphify update $LUNA/journal-2026.md --backend claude"

# luna-clippings x claude -> allow
run_fence allow no "$HIMMEL" "luna-clippings x claude -> allow (warn-not-block)" \
    "graphify update $LUNA/Clippings/clip.md --backend claude"

# salus x claude -> HARD DENY (PHI invariant preserved)
run_fence deny no "$HIMMEL" "salus x claude -> hard deny (PHI invariant)" \
    "graphify update $SALUS/notes/patient.md --backend claude"

# denylist-root (path-list PHI) x claude -> salus -> hard deny (user-extensible PHI set)
run_fence deny no "$HIMMEL" "denylist-root x claude -> salus hard deny" \
    "graphify update $DENYROOT/x/leak.md --backend claude"

echo "== claude backend is ENDPOINT-AWARE (codex-adv-1: no Anthropic-labelled Z.ai egress) =="

# THE HOLE: claude backend under a claude-glm launcher (ANTHROPIC_BASE_URL=api.z.ai)
# actually egresses to Z.ai. It must classify as zai-glm, NOT anthropic. HIMMEL-2224/
# 1749 reversed luna-personal x zai-glm x extraction to a plain DENY (GLM/Z.ai Coding
# Plan lapsed), so the guard moved from the ledger line to the VERDICT itself: correct
# zai-glm classification now denies outright; a misclassification as anthropic would
# come back ALLOW (luna-personal x anthropic is allow, HIMMEL-1049), so this `deny`
# assertion still discriminates correct zai-glm classification from an anthropic
# misclassification just as surely as the old ledger check did (HIMMEL-1122 origin).
run_fence deny no "$HIMMEL" "luna-personal x claude(z.ai baseurl) -> zai-glm deny (GLM de-listed, HIMMEL-2224/1749)" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic

# same z.ai gateway on Clippings -> deny (HIMMEL-2224: the cell itself is now a
# plain matrix deny, not a conditional cell gated by a missing opt-in)
run_fence deny no "$HIMMEL" "clippings x claude(z.ai baseurl) -> zai-glm deny (GLM de-listed, HIMMEL-2224/1749)" \
    "graphify update $LUNA/Clippings/clip.md --backend claude" ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic

# z.ai gateway on himmel-code -> zai-glm -> himmel-code STILL allows any ratified
# lane (HIMMEL-2224 de-listing is private-content egress only, not public code)
run_fence allow no "$HIMMEL" "himmel-code x claude(z.ai baseurl) -> zai-glm allow" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude" ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic

# plain --backend glm twin of the case above -> same allow, without going
# through the claude/ANTHROPIC_BASE_URL endpoint-aware path (HIMMEL-2224
# positive control: himmel-code x glm still allows post de-listing)
run_fence allow no "$HIMMEL" "himmel-code x glm -> allow (public code, HIMMEL-2224)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend glm"

# explicit real Anthropic endpoint -> anthropic -> luna allow (operating substrate)
run_fence allow no "$HIMMEL" "luna-personal x claude(api.anthropic.com) -> anthropic allow" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=https://api.anthropic.com

# UNKNOWN custom gateway -> undeclared anthropic-custom -> fail-closed default deny
run_fence deny no "$HIMMEL" "luna-personal x claude(unknown gateway) -> deny (fail-closed)" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=https://litellm.internal.example/v1

# z.ai gateway on salus -> still HARD DENY (PHI invariant beats any provider)
run_fence deny no "$HIMMEL" "salus x claude(z.ai baseurl) -> hard deny (PHI invariant)" \
    "graphify update $SALUS/notes/patient.md --backend claude" ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic

# EXACT-host match, not substring (CodeRabbit-critical): spoofed lookalike hosts
# that CONTAIN a trusted host as a substring must NOT be classified as trusted.
# api.anthropic.com.<attacker> -> NOT anthropic -> luna-personal default deny.
run_fence deny no "$HIMMEL" "luna x claude(api.anthropic.com.evil) -> deny (no substring trust)" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=https://api.anthropic.com.evil.invalid/v1
# a path that embeds a trusted host -> host is evil.invalid -> anthropic-custom.
# Tested on luna-personal (himmel-code allows ANY provider by design, so a
# restrictive corpus is where the lookalike deny is observable).
run_fence deny no "$HIMMEL" "luna x claude(evil/api.anthropic.com path) -> deny" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=https://evil.invalid/api.anthropic.com
# z.ai lookalike subdomain -> host api.z.ai.attacker.invalid -> anthropic-custom
# (NOT trusted as anthropic) -> luna-personal deny.
run_fence deny no "$HIMMEL" "luna x claude(api.z.ai.attacker) -> deny (no substring trust)" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=https://api.z.ai.attacker.invalid/v1
# real z.ai host with a port + userinfo still normalizes to api.z.ai -> zai-glm.
run_fence allow no "$HIMMEL" "himmel x claude(user@api.z.ai:443) -> zai-glm allow" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude" ANTHROPIC_BASE_URL=https://user@api.z.ai:443/api/anthropic
# scheme-less bare trusted hostname must NOT be trusted -> fail-closed deny on luna.
run_fence deny no "$HIMMEL" "luna x claude(scheme-less api.anthropic.com) -> deny (needs http(s))" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=api.anthropic.com
# arbitrary non-http scheme -> fail-closed deny on luna.
run_fence deny no "$HIMMEL" "luna x claude(file:// scheme) -> deny (needs https)" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=file:///api.anthropic.com
# plaintext http:// to a trusted host -> deny (cleartext egress; https required).
# Survivor of a HIMMEL-2120 manifest-gated drop: the https-scheme check
# (_map_anthropic_endpoint's `case "$u" in https://*) : ;; *) echo
# anthropic-custom; return ;; esac`) rejects on scheme alone, before the host
# is ever read, so the former "http://api.z.ai" sibling case exercised the
# identical branch with a destination the code never inspects - no
# distinguishing coverage. Dropped, not cited by a ticket, non-PHI (luna).
run_fence deny no "$HIMMEL" "luna x claude(http://api.anthropic.com) -> deny (https only)" \
    "graphify update $LUNA/journal-2026.md --backend claude" ANTHROPIC_BASE_URL=http://api.anthropic.com
# backslash-in-authority (WHATWG \-as-/ confusion) -> fail-closed deny: a naive
# userinfo strip would see api.anthropic.com, but the real host may be evil.com.
run_fence deny no "$HIMMEL" "luna x claude(backslash authority) -> deny (fail-closed)" \
    "graphify update $LUNA/journal-2026.md --backend claude" 'ANTHROPIC_BASE_URL=https://evil.invalid\@api.anthropic.com/v1'

# An UNVERIFIED endpoint hard-denies on EVERY corpus — including himmel-code,
# whose `* *` matrix wildcard is for RATIFIED providers, NOT an arbitrary host an
# attacker can point ANTHROPIC_BASE_URL at. Without the anthropic-custom
# hard-deny these would ALLOW via the wildcard (CodeRabbit-major regression pins).
run_fence deny no "$HIMMEL" "himmel-code x claude(unknown gateway) -> hard deny (not the wildcard)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude" ANTHROPIC_BASE_URL=https://litellm.internal.example/v1
run_fence deny no "$HIMMEL" "himmel-code x claude(api.anthropic.com.evil) -> hard deny" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude" ANTHROPIC_BASE_URL=https://api.anthropic.com.evil.invalid/v1
run_fence deny no "$HIMMEL" "himmel-code x claude(http plaintext) -> hard deny" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude" ANTHROPIC_BASE_URL=http://api.anthropic.com

echo "== claude rerouted away from Anthropic (CLAUDE_CODE_USE_*) -> hard deny (HIMMEL-1070) =="

# THE HOLE: the CLAUDE_CODE_USE_* selectors reroute the claude CLI to AWS/GCP/a
# gateway WITHOUT setting ANTHROPIC_BASE_URL, so the endpoint check saw an unset
# base-url -> `anthropic` -> allowed. They now hard-deny on EVERY corpus
# (himmel-code included: its `* *` wildcard is for RATIFIED providers only).
#
# Scoped to claude-cli, the ONLY backend that shells the CLI and can inherit them
# (graphify llm.py: claude-cli -> _call_claude_cli; `claude` -> plain HTTP to
# ANTHROPIC_BASE_URL/ANTHROPIC_API_KEY). The `-> allow` pins below are the
# false-deny regression pins for that scoping.
run_fence deny no "$HIMMEL" "luna x claude-cli(bedrock) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_BEDROCK=1
run_fence deny no "$HIMMEL" "luna x claude-cli(vertex) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_VERTEX=1
run_fence deny no "$HIMMEL" "himmel-code x claude-cli(bedrock) -> hard deny (not the wildcard)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" CLAUDE_CODE_USE_BEDROCK=1
run_fence deny no "$HIMMEL" "himmel-code x claude-cli(vertex) -> hard deny (not the wildcard)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" CLAUDE_CODE_USE_VERTEX=1
# the reroute wins over an otherwise-trusted ANTHROPIC_BASE_URL: with Bedrock on,
# the base-url is not what the CLI dials, so a trusted-looking value must not
# launder it back to `anthropic`.
run_fence deny no "$HIMMEL" "luna x claude-cli(bedrock + trusted base-url) -> hard deny (reroute wins)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_BASE_URL=https://api.anthropic.com
run_fence deny no "$HIMMEL" "luna x claude-cli(bedrock=yes) -> hard deny (non-boolean = on)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_BEDROCK=yes
# SET-not-truthy (CodeRabbit-major regression pins): `0` and `false` are SET, and
# a Node truthiness check reads the STRING "0" as TRUE — so a bash-minded "0 = off"
# read would be the exact fail-open this fix closes. Only unset/empty is off.
run_fence deny no "$HIMMEL" "luna x claude-cli(bedrock=0) -> hard deny (0 is SET, not off)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_BEDROCK=0
run_fence deny no "$HIMMEL" "luna x claude-cli(vertex=false) -> hard deny (false is SET, not off)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_VERTEX=false
# the siblings in the same family reroute identically -> same deny
run_fence deny no "$HIMMEL" "luna x claude-cli(foundry) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_FOUNDRY=1
run_fence deny no "$HIMMEL" "luna x claude-cli(gateway) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_GATEWAY=1
run_fence deny no "$HIMMEL" "luna x claude-cli(mantle) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_MANTLE=1
run_fence deny no "$HIMMEL" "luna x claude-cli(anthropic_aws) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" CLAUDE_CODE_USE_ANTHROPIC_AWS=1
# CASE-INSENSITIVE (CodeRabbit-major regression pins): bash matches var names
# case-SENSITIVELY, Node's process.env on Windows does NOT — so a lowercase
# selector turns Bedrock ON for the CLI while an exact-case fence read it as
# unset and allowed the run. Proven: `env claude_code_use_bedrock=1 node -e
# 'process.env.CLAUDE_CODE_USE_BEDROCK'` -> "1", same var in bash -> unset.
run_fence deny no "$HIMMEL" "luna x claude-cli(lowercase bedrock) -> hard deny (Node env is case-insensitive)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" claude_code_use_bedrock=1
run_fence deny no "$HIMMEL" "luna x claude-cli(MiXeD-case vertex) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" Claude_Code_Use_Vertex=1
run_fence deny no "$HIMMEL" "himmel-code x claude-cli(lowercase bedrock) -> hard deny (not the wildcard)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" claude_code_use_bedrock=1
# a lowercase FEATURE flag still must not deny (the list is exact, case aside)
run_fence allow no "$HIMMEL" "himmel-code x claude-cli(lowercase cowork flag) -> allow (feature flag)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" claude_code_use_cowork_plugins=1
# a lowercase selector with an EMPTY value is still off
run_fence allow no "$HIMMEL" "himmel-code x claude-cli(lowercase bedrock empty) -> allow (empty = off)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" claude_code_use_bedrock=
# LOCALE-INDEPENDENT matching (CodeRabbit-major): under tr_TR, lowercase/uppercase
# equivalence differs around 'i', so an unpinned nocasematch could miss
# claude_code_use_anthropic_aws and ALLOW the run. _claude_reroute_var pins
# LC_ALL=C before enabling nocasematch. Runs under a Turkish locale when the box
# has one; SKIPs (never silently passes) otherwise, since without the locale the C
# comparison is what runs anyway and the case proves nothing.
# The locale MUST arrive via LANG/LC_CTYPE, never LC_ALL (CodeRabbit-minor): the
# fence pins LC_ALL=C itself, so an LC_ALL-driven case would be overridden by the
# very line under test and prove nothing.
if locale -a 2>/dev/null | grep -qi '^tr_TR'; then
    tr_loc=$(locale -a 2>/dev/null | grep -i '^tr_TR' | head -1)
    run_fence deny no "$HIMMEL" "luna x claude-cli(lowercase anthropic_aws under $tr_loc) -> hard deny (locale-independent match)" \
        "graphify update $LUNA/journal-2026.md --backend claude-cli" claude_code_use_anthropic_aws=1 LANG="$tr_loc" LC_CTYPE="$tr_loc"
else
    printf '  SKIP  lowercase anthropic_aws under a Turkish locale (no tr_TR locale on this box)\n'
fi
# BUILTIN-ONLY matching: caller-controlled PATH entries for `env` or `tr` must
# be irrelevant to the selector sweep. The fake dir is PREPENDED to the REAL PATH
# so the rest of the fence still runs normally; the selective fake `tr` forwards
# non-selector folds because other _lc() sites intentionally still use it and
# already fail closed on errors.
hj_tr="$WS/hijack-tr";   mkdir -p "$hj_tr"
hj_env="$WS/hijack-env"; mkdir -p "$hj_env"
real_tr="$(command -p -v tr)"
cat > "$hj_tr/tr" <<EOF
#!/bin/sh
in=\$(cat)
case "\$in" in
    claude_code_use_*|Claude_Code_Use_*) printf 'X_NOT_A_SELECTOR' ;;
    *) printf '%s' "\$in" | "$real_tr" "\$@" ;;
esac
EOF
printf '#!/bin/sh\necho NOTHING=1\n' > "$hj_env/env"
chmod +x "$hj_tr/tr" "$hj_env/env"
run_fence deny no "$HIMMEL" "luna x claude-cli(lowercase bedrock, fake tr on PATH) -> hard deny (builtin nocasematch)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" claude_code_use_bedrock=1 PATH="$hj_tr:$PATH"
run_fence deny no "$HIMMEL" "luna x claude-cli(lowercase bedrock, fake env on PATH) -> hard deny (builtin compgen)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" claude_code_use_bedrock=1 PATH="$hj_env:$PATH"
# HIMMEL-1133 regression: model a host where the OLD `command -p tr` lookup
# errors, without modifying the machine's real default PATH. BASH_ENV installs a
# narrow command wrapper inside the fence process: only `command -p tr ...`
# returns 127; every other command builtin call delegates unchanged. The old fold
# therefore produced an empty name and ALLOWED this lowercase Bedrock selector;
# the builtin-only path never touches the wrapper and must DENY.
no_command_p_tr_env="$WS/no-command-p-tr.bash"
cat > "$no_command_p_tr_env" <<'EOF'
command() {
    if [ "${1:-}" = "-p" ] && [ "${2:-}" = "tr" ]; then return 127; fi
    builtin command "$@"
}
EOF
run_fence deny no "$HIMMEL" "luna x claude-cli(lowercase bedrock, command -p tr unusable) -> hard deny (builtin-only)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" claude_code_use_bedrock=1 BASH_ENV="$no_command_p_tr_env"
# NEWLINE-IN-VALUE (CodeRabbit-major, private #1263): a LIVE fail-open, measured.
# The sweep used to parse `env` output line-by-line, so a selector whose value
# STARTS with a newline printed as `claude_code_use_bedrock=` + `x` — the first
# line read as an EMPTY value and hit the empty-skip, the selector went unseen and
# the run was ALLOWED (rc=0), while Node reads "\nx" as truthy and Bedrock is ON.
# Reading values BY NAME (compgen -e) removes the line-oriented round-trip that
# made this expressible at all. The `=` and mid-value cases pin the neighbours.
nl_lead="$(printf '\nx')"
run_fence deny no "$HIMMEL" "luna x claude-cli(lowercase bedrock, LEADING-newline value) -> hard deny (value read by name)" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" claude_code_use_bedrock="$nl_lead"
nl_mid="$(printf 'a\nb')"
run_fence deny no "$HIMMEL" "luna x claude-cli(lowercase bedrock, MID-value newline) -> hard deny" \
    "graphify update $LUNA/journal-2026.md --backend claude-cli" claude_code_use_bedrock="$nl_mid"
# a forged lookalike LINE inside a value must not be readable as a selector
nl_forge="$(printf 'x\nclaude_code_use_vertex=1')"
run_fence allow no "$HIMMEL" "himmel-code x claude-cli(harmless var forging a selector LINE in its value) -> allow (no line parsing)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" harmless_var="$nl_forge"
# EMPTY is the only off value besides unset — it must NOT false-deny
run_fence allow no "$HIMMEL" "himmel-code x claude-cli(bedrock empty) -> allow (empty = off)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" CLAUDE_CODE_USE_BEDROCK=
# BACKEND-SCOPED (CodeRabbit-major regression pins): `claude` is the HTTP API
# path — it never execs the CLI, so a selector set for the operator's INTERACTIVE
# Claude Code (e.g. they run Claude Code on Bedrock, but extract over the API)
# is inert for it. Denying these was a false deny on a legitimate config.
run_fence allow no "$HIMMEL" "himmel-code x claude(bedrock) -> allow (API path never execs the CLI)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude" CLAUDE_CODE_USE_BEDROCK=1
run_fence allow no "$HIMMEL" "luna-personal x claude(vertex) -> allow (API path, matrix warn-not-block)" \
    "graphify update $LUNA/journal-2026.md --backend claude" CLAUDE_CODE_USE_VERTEX=1
# ...but the ENDPOINT check still binds `claude`: the API backend really does
# read ANTHROPIC_BASE_URL, so an unverified endpoint denies even with no selector.
run_fence deny no "$HIMMEL" "himmel-code x claude(unknown gateway, no selector) -> hard deny (endpoint check still applies)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude" ANTHROPIC_BASE_URL=https://litellm.internal.example/v1
# same-prefix FEATURE flags are NOT reroute selectors — a wildcard match on
# CLAUDE_CODE_USE_* would false-deny these; the explicit list must not.
run_fence allow no "$HIMMEL" "himmel-code x claude-cli(cowork-plugins flag) -> allow (feature flag, not a reroute)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" CLAUDE_CODE_USE_COWORK_PLUGINS=1
run_fence allow no "$HIMMEL" "himmel-code x claude-cli(powershell-tool flag) -> allow (feature flag, not a reroute)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend claude-cli" CLAUDE_CODE_USE_POWERSHELL_TOOL=1
# a NON-claude backend does not read these vars -> no false deny
run_fence allow no "$HIMMEL" "himmel-code x deepseek(bedrock set) -> allow (backend ignores it)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek" CLAUDE_CODE_USE_BEDROCK=1
# salus stays hard-denied regardless (invariant, never reachable by any flag)
run_fence deny no "$HIMMEL" "salus x claude-cli(bedrock) -> hard deny (invariant)" \
    "graphify update $SALUS/notes/patient.md --backend claude-cli" CLAUDE_CODE_USE_BEDROCK=1

echo "== HIMMEL-1085: command-local endpoint-selector assignments in front of graphify =="

# THE HOLE: classify_clause deliberately SKIPS leading/env-local assignments so
# a wrapper cannot HIDE the graphify invocation from the command-position walk
# -- but that same skip means an endpoint-selector assignment scoped to the
# COMMAND (not this fence process's own ambient env, which CLEAN_ENV keeps
# unset below) is invisible to _map_anthropic_endpoint's read of its own
# environment, while the graphify SUBPROCESS still inherits it. Every case
# below embeds the assignment IN THE COMMAND STRING ($cmd itself) -- no
# trailing ambient VAR=val args -- so a false ALLOW here is exactly the bypass
# HIMMEL-1085 reports. luna-personal is the observing corpus: claude x
# anthropic allows there (warn-not-block baseline just above), so only a
# command-local override changes the verdict.

# direct form: VAR=x graphify ...
run_fence deny no "$HIMMEL" "luna x claude, command-local ANTHROPIC_BASE_URL=z.ai -> deny (HIMMEL-1085)" \
    "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic graphify update $LUNA/journal-2026.md --backend claude"
run_fence deny no "$HIMMEL" "luna x claude-cli, command-local CLAUDE_CODE_USE_BEDROCK=1 -> deny" \
    "CLAUDE_CODE_USE_BEDROCK=1 graphify update $LUNA/journal-2026.md --backend claude-cli"
run_fence deny no "$HIMMEL" "luna x claude-cli, command-local CLAUDE_CODE_USE_VERTEX=1 -> deny" \
    "CLAUDE_CODE_USE_VERTEX=1 graphify update $LUNA/journal-2026.md --backend claude-cli"
run_fence deny no "$HIMMEL" "luna x claude, command-local ANTHROPIC_API_KEY=x -> deny" \
    "ANTHROPIC_API_KEY=sk-fake graphify update $LUNA/journal-2026.md --backend claude"
run_fence deny no "$HIMMEL" "luna x claude, command-local ANTHROPIC_AUTH_TOKEN=x -> deny" \
    "ANTHROPIC_AUTH_TOKEN=fake-token graphify update $LUNA/journal-2026.md --backend claude"

# env VAR=x graphify ...
run_fence deny no "$HIMMEL" "luna x claude, env ANTHROPIC_BASE_URL=z.ai -> deny" \
    "env ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic graphify update $LUNA/journal-2026.md --backend claude"
run_fence deny no "$HIMMEL" "luna x claude-cli, env CLAUDE_CODE_USE_BEDROCK=1 -> deny" \
    "env CLAUDE_CODE_USE_BEDROCK=1 graphify update $LUNA/journal-2026.md --backend claude-cli"

# wrapped: a wrapper in front of `env VAR=x` must not hide the assignment either
run_fence deny no "$HIMMEL" "luna x claude, timeout 600 env ANTHROPIC_BASE_URL=z.ai -> deny (wrapped)" \
    "timeout 600 env ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic graphify update $LUNA/journal-2026.md --backend claude"

# HIMMEL-2087: path-qualified wrappers (/usr/bin/env, /bin/sudo, ...) must be
# recognized the same as their bare form -- classify_clause previously matched
# wrapper tokens by bare name only, so a path-qualified form walked past every
# wrapper case, stopped the token walk before reaching graphify, and skipped
# BOTH this endpoint-override deny and the ordinary corpus x provider policy.
run_fence deny no "$HIMMEL" "luna x claude, /usr/bin/env ANTHROPIC_BASE_URL=z.ai -> deny (path-qualified env)" \
    "/usr/bin/env ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic graphify update $LUNA/journal-2026.md --backend claude"
run_fence deny no "$HIMMEL" "luna x claude, ANTHROPIC_BASE_URL=z.ai /bin/sudo graphify -> deny (path-qualified sudo)" \
    "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic /bin/sudo graphify update $LUNA/journal-2026.md --backend claude"
run_fence deny no "$HIMMEL" "luna x claude, /usr/bin/timeout 600 /usr/bin/env ANTHROPIC_BASE_URL=z.ai -> deny (path-qualified chain)" \
    "/usr/bin/timeout 600 /usr/bin/env ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic graphify update $LUNA/journal-2026.md --backend claude"

# himmel-code (allow-any wildcard) must ALSO deny -- the command-local override
# hard-denies exactly like an ambient one would (HIMMEL-1049's anthropic-custom
# hard-deny is not the wildcard's to waive), pinning that this is not a
# luna-only artifact of the observing corpus.
run_fence deny no "$HIMMEL" "himmel-code x claude, command-local ANTHROPIC_BASE_URL=z.ai -> deny (not the wildcard)" \
    "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic graphify update $HIMMEL/scripts/thing.sh --backend claude"

# a bash -c wrapper: the assignment is OUTSIDE the quoted string, the graphify
# token is INSIDE it -- the override has to survive classify_clause's
# recursive re-entry to unwrap `bash -c`.
run_fence deny no "$HIMMEL" "luna x claude, ANTHROPIC_BASE_URL=z.ai bash -c 'graphify ...' -> deny (survives bash -c unwrap)" \
    "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic bash -c 'graphify update $LUNA/journal-2026.md --backend claude'"

# regression / false-positive guard: an UNRELATED command-local assignment
# (not one of the five endpoint selectors) must not trip the new deny -- only
# the named selector set does.
run_fence allow no "$HIMMEL" "luna x claude, unrelated command-local FOO=bar -> allow (not a selector)" \
    "FOO=bar graphify update $LUNA/journal-2026.md --backend claude"

# regression guard: the override must not LEAK across clauses -- a selector
# assignment in front of an unrelated command in clause 1 must not deny a
# CLEAN graphify invocation in clause 2.
run_fence allow no "$HIMMEL" "luna x claude, selector on an unrelated clause 1 does not poison clause 2 -> allow" \
    "ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic echo hi; graphify update $LUNA/journal-2026.md --backend claude"

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

# (W8) HIMMEL-2087: path-qualified wrappers (/usr/bin/env, /bin/sudo, ...) ->
# deny, same as their bare form -- classify_clause matched wrapper tokens by
# bare name only, so a path-qualified wrapper walked past the wrapper case,
# stopped the token walk, and never reached the corpus x provider policy below.
run_fence deny no "$HIMMEL" "/usr/bin/timeout 600 graphify salus -> deny (path-qualified timeout)" \
    "/usr/bin/timeout 600 graphify update $SALUS/notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "/usr/bin/env -i graphify salus -> deny (path-qualified env)" \
    "/usr/bin/env -i graphify update $SALUS/notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "/usr/bin/sudo graphify salus -> deny (path-qualified sudo)" \
    "/usr/bin/sudo graphify update $SALUS/notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "/usr/bin/stdbuf -oL graphify salus -> deny (path-qualified stdbuf)" \
    "/usr/bin/stdbuf -oL graphify update $SALUS/notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "/usr/bin/sudo /usr/bin/nohup /usr/bin/timeout 600 graphify salus -> deny (path-qualified chain)" \
    "/usr/bin/sudo /usr/bin/nohup /usr/bin/timeout 600 graphify update $SALUS/notes/patient.md --backend glm"

# (W7) BACKSLASH: \graphify seen after _strip_cmd -> deny
run_fence deny no "$HIMMEL" "backslash \\graphify salus -> deny" \
    "\graphify update $SALUS/notes/patient.md --backend glm"

echo "== HIMMEL-2615: setsid + quiet-run.sh wrapper laundering =="

# Before the fix, every DENY row below returned rc=0 (silent allow, no ledger
# line): `setsid` was simply missing from the wrapper walk, and
# scripts/quiet-run.sh's `--` tail was never re-classified as the clause -
# either invoked directly or through an explicit `bash <script>` launch. The
# nohup/env rows in the HIMMEL-621 block above are the unchanged negative
# controls proving the wrapper walk itself was already working; these rows
# add the two shapes it was missing.

# (S1) setsid, bare -> deny (same shape as nohup, just missing from the list)
run_fence deny no "$HIMMEL" "setsid graphify salus -> deny" \
    "setsid graphify update $SALUS/notes/patient.md --backend glm"

# (S2) setsid with a flag-consuming option -> deny
run_fence deny no "$HIMMEL" "setsid -f graphify salus -> deny" \
    "setsid -f graphify update $SALUS/notes/patient.md --backend glm"

# (S3) HIMMEL-2087 parity: path-qualified setsid -> deny, same as bare form
run_fence deny no "$HIMMEL" "/usr/bin/setsid graphify salus -> deny (path-qualified setsid)" \
    "/usr/bin/setsid graphify update $SALUS/notes/patient.md --backend glm"

# (S4) setsid chained with an existing wrapper -> deny
run_fence deny no "$HIMMEL" "setsid nohup graphify salus -> deny (chained wrappers)" \
    "setsid nohup graphify update $SALUS/notes/patient.md --backend glm"

# (S5) quiet-run.sh, direct invocation via `bash <script>` -> its `--` tail is
# the clause -> deny
run_fence deny no "$HIMMEL" "bash scripts/quiet-run.sh graphify salus -> deny" \
    "bash scripts/quiet-run.sh lbl -- graphify update $SALUS/notes/patient.md --backend glm"

# (S6) quiet-run.sh, direct relative invocation (no `bash` prefix) -> deny
run_fence deny no "$HIMMEL" "./scripts/quiet-run.sh graphify salus -> deny (direct, relative)" \
    "./scripts/quiet-run.sh lbl -- graphify update $SALUS/notes/patient.md --backend glm"

# (S7) quiet-run.sh, path-qualified direct invocation -> deny (the fence only
# reads the basename, so any absolute path in front of the script is fine)
run_fence deny no "$HIMMEL" "/some/abs/path/scripts/quiet-run.sh graphify salus -> deny (path-qualified direct)" \
    "/some/abs/path/scripts/quiet-run.sh lbl -- graphify update $SALUS/notes/patient.md --backend glm"

# (S8) bash -c unwrap + the runner combined -> deny
run_fence deny no "$HIMMEL" "bash -c 'quiet-run.sh graphify salus' -> deny (bash -c unwrap + runner)" \
    "bash -c \"bash scripts/quiet-run.sh lbl -- graphify update $SALUS/notes/patient.md --backend glm\""

# (S9) the exact shape from the HIMMEL-2615 incident: setsid + nohup +
# `bash <script>` all stacked in front of the runner -> deny
run_fence deny no "$HIMMEL" "setsid nohup bash scripts/quiet-run.sh graphify salus -> deny (incident shape)" \
    "setsid nohup bash scripts/quiet-run.sh lbl -- graphify update $SALUS/notes/patient.md --backend glm"

# (S10) quoted label containing whitespace AND an embedded literal `--`
# (worst case: the label's own content word-splits into a token that looks
# exactly like the real separator) -> the runner's own label/`--` alignment
# check cannot rejoin the label (this file tokenises by naive word-split, not
# real shell parsing) and, without a guard, would misalign onto the label's
# OWN `--` and lose the real separator - and the graphify tail after it -
# from view. The label token contains a `'`, which the CR-round-2 rule
# (no `'`/`"`/`\` anywhere in the raw label token, full stop - see the arm's
# own comment for why a per-quote-type PARITY count does not work) rejects
# on sight, so this still falls through to the fail-closed unparsable-label
# scan and denies, same treatment as xargs / find -exec.
run_fence deny no "$HIMMEL" "quiet-run.sh unparsable quoted label w/ embedded -- -> deny (fail-closed)" \
    "bash scripts/quiet-run.sh 'a -- b' -- graphify update $SALUS/notes/patient.md --backend glm"

# (S11) NEGATIVE: setsid in front of a non-graphify command stays rc=0
run_fence allow no "$HIMMEL" "setsid ls (non-graphify) -> allow" \
    "setsid ls -la $HIMMEL"

# (S12) NEGATIVE: an unrelated quiet-run.sh tail stays rc=0
run_fence allow no "$HIMMEL" "quiet-run.sh ls (non-graphify tail) -> allow" \
    "bash scripts/quiet-run.sh lbl -- ls $HIMMEL"

# (S13) NEGATIVE: a `--`-bearing but graphify-free tail stays rc=0
run_fence allow no "$HIMMEL" "quiet-run.sh git log (graphify-free, has --) -> allow" \
    "bash scripts/quiet-run.sh lbl -- git log --oneline"

# (S14) NEGATIVE: `bash <unknown-script>` with a bare graphify MENTION stays
# rc=0 - proves the Task-1 bash-unwrap restart does not widen the walk into a
# bare-mention denial for a script the wrapper walk does not otherwise know.
run_fence allow no "$HIMMEL" "bash scripts/some-other-script.sh graphify (bare mention) -> allow" \
    "bash scripts/some-other-script.sh graphify"

# (S15) ALLOW-side proof: a quiet-run.sh tail is really CLASSIFIED, not denied
# blindly - mirrors the "himmel-code x deepseek -> allow (no ledger)" case
# above with the exact same tail, same expected verdict and ledger behaviour.
run_fence allow no "$HIMMEL" "quiet-run.sh himmel-code x deepseek -> allow (no ledger)" \
    "bash scripts/quiet-run.sh lbl -- graphify update $HIMMEL/scripts/thing.sh --backend deepseek"

# (S16) BOUNDS REGRESSION: quiet-run.sh with NO args at all - the clause's
# last token IS the runner, so toks[i+1] (the label) does not exist. Before
# the bounds-first reorder this read an out-of-range index under `set -u`,
# aborting the fence with an "unbound variable" internal error (surfaced as a
# spurious DENY on a completely harmless command). Must allow cleanly.
run_fence allow no "$HIMMEL" "quiet-run.sh with NO args -> allow (no out-of-range read)" \
    "bash scripts/quiet-run.sh"

# (S17) BOUNDS REGRESSION: quiet-run.sh + a label but no `--` at all - the
# clause's last token is the label, so toks[i+2] (the would-be `--`) does not
# exist either. Same out-of-range read as S16, one token later; the runner
# itself would reject this call (usage/exit 2), so denying it here would cost
# nothing either way - but the bounds check must still resolve it as allow
# without touching toks[i+2].
run_fence allow no "$HIMMEL" "quiet-run.sh label with no -- -> allow (runner itself rejects it)" \
    "bash scripts/quiet-run.sh lbl"

# (S18) CR round-1 regression [codex-2]: a MIXED-quote label (`'"a -- b'`) has
# one `'` and one `"` in its first word-split fragment - an EVEN *pooled*
# quote count, which the CR-round-1 combined-count guard trusted as a whole
# aligned label even though neither quote type is actually balanced within
# this fragment on its own. That per-type-parity fix was ITSELF broken by CR
# round 2 (see [codex-1 round-2] below) and replaced with a simpler rule: ANY
# of `'`/`"`/`\` anywhere in the raw label token makes it ambiguous, full
# stop, no counting at all. This label plainly contains both -> deny
# (fail-closed unparsable-label scan), now for the simpler reason.
run_fence deny no "$HIMMEL" "quiet-run.sh mixed-quote label '\"a -- b' -> deny (fail-closed) [codex-2]" \
    "bash scripts/quiet-run.sh '\"a -- b' -- graphify update $SALUS/notes/patient.md --backend glm"

# (S19) CR round-1 [codex-2] mirror: same shape with the OTHER quote type
# outermost in the first fragment (`"'a -- b"`) - proves the current rule is
# not order-sensitive between the two quote characters either -> deny.
run_fence deny no "$HIMMEL" "quiet-run.sh mixed-quote label \"'a -- b\" -> deny (fail-closed, other quote outermost) [codex-2]" \
    "bash scripts/quiet-run.sh \"'a -- b\" -- graphify update $SALUS/notes/patient.md --backend glm"

# (S20) CR round-1 [codex-2] backslash case: `a\ -- -- graphify ...` word-
# splits (naive IFS split, no backslash-escape interpretation) into the label
# fragment `a\`, then a literal `--`, then a SECOND literal `--`, then the
# graphify tail - real argv the runner would see is LABEL='a --' (escaped
# space) followed by the actual `--` separator and the tail, a call the
# runner itself accepts and runs. The label fragment has no quote characters
# of either type, so a bare quote-only test would miss it; the current rule
# checks for a literal backslash too (on the RAW, pre-_strip_cmd token, in
# the SAME single test as the quote check) -> deny.
run_fence deny no "$HIMMEL" "quiet-run.sh backslash label a\\ -- -> deny (fail-closed) [codex-2]" \
    "bash scripts/quiet-run.sh a\\ -- -- graphify update $SALUS/notes/patient.md --backend glm"

# (S21) CR round-1 regression pin [codex-1]: a QUOTED script path
# (`bash "scripts/quiet-run.sh" ...`) still resolves on the FENCE side - the
# bash-unwrap default arm hands the quoted token to _wrapper_base, which
# strips quotes via _strip_cmd before matching the basename, so this already
# passed before this CR round. Pinned anyway so a future regex/parsing change
# cannot silently regress it (the HOOK-side prefilter gap this same shape
# exposed is fixed and pinned separately in block-graphify-egress.sh / its
# own suite).
run_fence deny no "$HIMMEL" "quiet-run.sh via bash \"scripts/quiet-run.sh\" (quoted path) -> deny [codex-1]" \
    "bash \"scripts/quiet-run.sh\" lbl -- graphify update $SALUS/notes/patient.md --backend glm"

# (S22) CR round 2 [codex-1] FLIPPED this row's expectation - it used to
# assert that a legitimate single-word quoted label (`'lbl'`) aligned and
# reached the real himmel-code x deepseek ALLOW verdict, under the CR-round-1
# per-quote-type PARITY guard (one balanced `'` pair, no `"`, no backslash ->
# "balanced" -> trusted). CR round 2 broke that guard outright: adjacent
# quoted segments in one fragment (e.g. label `'"'"a -- b"`, real argv label
# `"a -- b`) make BOTH quote types count EVEN in fragment 1 while a double
# quote is still genuinely open across the space - the first `"` there is
# literal DATA (inside a `'` pair), the second is the OPERATOR that closes
# later, and a character count cannot tell data from operator apart. No
# parity rule can (see the arm's own comment). The fix replaces parity with
# one conservative rule: ANY `'`, `"`, or `\` in the raw label token makes it
# ambiguous, no exceptions - so `'lbl'` now ALSO denies. This is a known,
# accepted false positive (a real quoted-but-otherwise-plain label loses),
# not a regression: it fails in the safe direction, and only fires because
# this tail actually contains a graphify token. S15 above already keeps the
# "a runner tail is genuinely CLASSIFIED, not blindly denied" proof alive
# with the un-quoted `lbl` sibling of this exact himmel-code x deepseek
# case - no new positive row needed, just this flip.
run_fence deny no "$HIMMEL" "quiet-run.sh 'lbl' (quoted label) -> deny (accepted false positive, CR round 2)" \
    "bash scripts/quiet-run.sh 'lbl' -- graphify update $HIMMEL/scripts/thing.sh --backend deepseek"

# (S23) CR round 2 [codex-1]: the adjacent-quoted-segments bypass itself -
# label `'"'"a -- b"` (real argv label is `"a -- b`, one word); word-split
# fragments are `'"'"a` / `--` / `b"` / `--` / `graphify ...`. Fragment 1
# holds two `'` and two `"` - EVEN on both types - which is exactly what
# defeated the CR-round-1 per-type-parity guard (see the arm's own comment
# for the data-vs-operator explanation: one quote is literal content INSIDE
# the other type's pair, the other is a real operator closed only in a later
# fragment, and no count can distinguish them). The current rule denies
# outright on any quote character present, sidestepping the whole question.
run_fence deny no "$HIMMEL" "quiet-run.sh adjacent-quoted-segments label '\"'\"a -- b\" -> deny (fail-closed) [codex-1 round-2]" \
    "bash scripts/quiet-run.sh '\"'\"a -- b\" -- graphify update $SALUS/notes/patient.md --backend glm"

# (S24) CR round 2 [codex-1] mirror: the two quote types swapped
# (`"'"'a -- b'`) - proves the fix is not accidentally sensitive to which
# quote type opens the ambiguous run.
run_fence deny no "$HIMMEL" "quiet-run.sh adjacent-quoted-segments label \"'\"'a -- b' -> deny (fail-closed, types swapped) [codex-1 round-2]" \
    "bash scripts/quiet-run.sh \"'\"'a -- b' -- graphify update $SALUS/notes/patient.md --backend glm"

echo "== HIMMEL-2094: flag-bearing transparent wrappers (nice/time/nohup/command/exec/builtin) =="

# Before the fix, classify_clause matched command/exec/builtin/nohup/time/nice
# as BARE literals with no flag-consuming loop -- a flag-bearing form of any
# of them (e.g. `nice -n 5 graphify ...`) stopped the wrapper walk at the
# flag token instead of reaching graphify, and the clause was left
# unclassified (allow). Each DENY row below is a flag-bearing form of one of
# the six wrappers; the ALLOW rows are negative controls proving the fix does
# not widen what counts as a flag or misclassify a wrapper used on an
# unrelated command.

# (F1) nice with a separate-value flag -> deny
run_fence deny no "$HIMMEL" "nice -n 5 graphify salus -> deny" \
    "nice -n 5 graphify update $SALUS/notes/patient.md --backend glm"

# (F2) nice with a combined-adjustment flag -> deny
run_fence deny no "$HIMMEL" "nice -5 graphify salus -> deny" \
    "nice -5 graphify update $SALUS/notes/patient.md --backend glm"

# (F3) time with its POSIX-format flag -> deny
run_fence deny no "$HIMMEL" "time -p graphify salus -> deny" \
    "time -p graphify update $SALUS/notes/patient.md --backend glm"

# (F4) nohup with its `--` end-of-options marker -> deny
run_fence deny no "$HIMMEL" "nohup -- graphify salus -> deny" \
    "nohup -- graphify update $SALUS/notes/patient.md --backend glm"

# (F5) command with its -p flag -> deny
run_fence deny no "$HIMMEL" "command -p graphify salus -> deny" \
    "command -p graphify update $SALUS/notes/patient.md --backend glm"

# (F6) exec with its -a NAME flag -> deny
run_fence deny no "$HIMMEL" "exec -a name graphify salus -> deny" \
    "exec -a name graphify update $SALUS/notes/patient.md --backend glm"

# (F7) codex-1 CR finding (round 1): `command -v`/`command -V` are identify-only
# lookups (type/which), never an invocation of NAME - unlike `command -p`,
# which does invoke. Both must skip past the flag the same way, but only -v/-V
# make the whole clause a no-op.
run_fence allow no "$HIMMEL" "command -v graphify salus -> allow (lookup, not invocation)" \
    "command -v graphify update $SALUS/notes/patient.md --backend glm"
run_fence allow no "$HIMMEL" "command -V graphify salus -> allow (lookup, not invocation)" \
    "command -V graphify update $SALUS/notes/patient.md --backend glm"

# (F7) builtin, bare (no flags of its own) -> deny, unchanged regression guard
run_fence deny no "$HIMMEL" "builtin graphify salus -> deny" \
    "builtin graphify update $SALUS/notes/patient.md --backend glm"

# (F8) negative control: nice on an unrelated command -> allow (no graphify
# mention at all)
run_fence allow no "$HIMMEL" "nice -n 5 ls -> allow (not graphify)" \
    "nice -n 5 ls"

# (F9) negative control: graphify appears only as an ARGUMENT to a command
# wrapped by time -p, not at command position -> allow
run_fence allow no "$HIMMEL" "time -p echo graphify -> allow (not command position)" \
    "time -p echo graphify"

echo "== HIMMEL-2610: nice/time abbreviated long options =="

# Before the fix, the nice/time arms matched their value-taking long option
# (--adjustment / --output / --format) as a BARE LITERAL with no abbreviation
# support. An unrecognized spelling (any GNU-unambiguous abbreviation of that
# option, e.g. --adj) fell to the generic `-*` catch-all, which consumes only
# the flag TOKEN itself and not its separate value - the wrapper walk then
# resolved the option's VALUE token as the wrapper's head, never reaching
# `graphify` at all, and the whole clause went unclassified (allow). Same
# misalignment mechanism as HIMMEL-2592 / HIMMEL-2610's other sites.

# (G1) nice --adj (unambiguous abbreviation of --adjustment) -> deny
run_fence deny no "$HIMMEL" "nice --adj 5 graphify salus -> deny (abbrev)" \
    "nice --adj 5 graphify update $SALUS/notes/patient.md --backend glm"

# (G2) nice --adjustment=N (attached value, single token) -> deny
run_fence deny no "$HIMMEL" "nice --adjustment=5 graphify salus -> deny (attached)" \
    "nice --adjustment=5 graphify update $SALUS/notes/patient.md --backend glm"

# (G3) negative control: nice --version does NOT take a value and is not a
# prefix of --adjustment - it must not swallow the next token (which would
# eat `graphify` itself as a bogus adjustment value and hide the clause).
run_fence deny no "$HIMMEL" "nice --version graphify salus -> deny (unrelated flag not swallowed)" \
    "nice --version graphify update $SALUS/notes/patient.md --backend glm"

# (G4) time --for (unambiguous abbreviation of --format) -> deny
run_fence deny no "$HIMMEL" "time --for %e graphify salus -> deny (abbrev)" \
    "time --for %e graphify update $SALUS/notes/patient.md --backend glm"

# (G5) time --o (unambiguous abbreviation of --output) -> deny
run_fence deny no "$HIMMEL" "time --o /tmp/x graphify salus -> deny (abbrev)" \
    "time --o /tmp/x graphify update $SALUS/notes/patient.md --backend glm"

# (G6) negative control: time --verbose does not take a value and is not a
# prefix of --output/--format - must not swallow the next token.
run_fence deny no "$HIMMEL" "time --verbose graphify salus -> deny (unrelated flag not swallowed)" \
    "time --verbose graphify update $SALUS/notes/patient.md --backend glm"

# (G7) env --u (abbreviation of --unset) -> deny
run_fence deny no "$HIMMEL" "env --u FOO graphify salus -> deny (abbrev)" \
    "env --u FOO graphify update $SALUS/notes/patient.md --backend glm"

# (G8) env --unset=FOO (attached value, single token) -> deny
run_fence deny no "$HIMMEL" "env --unset=FOO graphify salus -> deny (attached)" \
    "env --unset=FOO graphify update $SALUS/notes/patient.md --backend glm"

# (G9) negative control: env --ignore-environment does not take a value and
# is not a prefix of --unset - must not swallow the next token.
run_fence deny no "$HIMMEL" "env --ignore-environment graphify salus -> deny (unrelated flag not swallowed)" \
    "env --ignore-environment graphify update $SALUS/notes/patient.md --backend glm"

# (G10) timeout --k (abbreviation of --kill-after) -> deny
run_fence deny no "$HIMMEL" "timeout --k 5 10 graphify salus -> deny (abbrev)" \
    "timeout --k 5 10 graphify update $SALUS/notes/patient.md --backend glm"

# (G11) timeout --kill-after=5 (attached value, single token) -> deny
run_fence deny no "$HIMMEL" "timeout --kill-after=5 10 graphify salus -> deny (attached)" \
    "timeout --kill-after=5 10 graphify update $SALUS/notes/patient.md --backend glm"

# (G12) negative control: timeout --preserve-status does not take a value and
# is not a prefix of --kill-after/--signal - must not swallow the next token.
run_fence deny no "$HIMMEL" "timeout --preserve-status 10 graphify salus -> deny (unrelated flag not swallowed)" \
    "timeout --preserve-status 10 graphify update $SALUS/notes/patient.md --backend glm"

# (G13) stdbuf --outp (abbreviation of --output) -> deny
run_fence deny no "$HIMMEL" "stdbuf --outp L graphify salus -> deny (abbrev)" \
    "stdbuf --outp L graphify update $SALUS/notes/patient.md --backend glm"

# (G14) stdbuf --in=L (abbreviation of --input, attached value) -> deny
run_fence deny no "$HIMMEL" "stdbuf --in=L graphify salus -> deny (abbrev, attached)" \
    "stdbuf --in=L graphify update $SALUS/notes/patient.md --backend glm"

# (G15) negative control: stdbuf --version does not take a value and is not a
# prefix of --input/--output/--error - must not swallow the next token.
run_fence deny no "$HIMMEL" "stdbuf --version graphify salus -> deny (unrelated flag not swallowed)" \
    "stdbuf --version graphify update $SALUS/notes/patient.md --backend glm"

# (G16) sudo --us (abbreviation of --user) -> deny
run_fence deny no "$HIMMEL" "sudo --us root graphify salus -> deny (abbrev)" \
    "sudo --us root graphify update $SALUS/notes/patient.md --backend glm"

# (G17) sudo --user=root (attached value, single token) -> deny
run_fence deny no "$HIMMEL" "sudo --user=root graphify salus -> deny (attached)" \
    "sudo --user=root graphify update $SALUS/notes/patient.md --backend glm"

# (G18) negative control: sudo --reset-timestamp is not a prefix of any of
# sudo's value-taking long options (user/group/other-user/prompt/close-from/
# role/type/host) - must not swallow the next token.
run_fence deny no "$HIMMEL" "sudo --reset-timestamp graphify salus -> deny (unrelated flag not swallowed)" \
    "sudo --reset-timestamp graphify update $SALUS/notes/patient.md --backend glm"

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

# (6) unwritable-ledger fixture: GRAPHIFY_LEDGER parent is a regular file so
# mkdir -p fails. kimi/Moonshot (the only allow+log matrix cell this fixture
# used to exercise directly) is retired (HIMMEL-2101) — the equivalent
# unwritable-ledger case on the DECLARED-path branch is covered by S6b below,
# which reuses this same $WS/ledblocker file.
: > "$WS/ledblocker"

# (7) abnormal-exit trap: HOME unset -> $HOME expansion aborts under set -u -> trap -> rc 2
out=$( cd "$HIMMEL" && env -u HOME -u CLAUDE_GLM_CONFIG_DIR "$BASH_BIN" "$FENCE" "graphify update $HIMMEL/scripts/thing.sh --backend deepseek" 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "trap: HOME unset -> rc 2"; else fail "trap: HOME unset expected rc=2 got rc=$rc out=$out"; fi

# (8) node absent -> rc 2. PATH needs coreutils but NOT node; on apt-node
# systems node lives IN /usr/bin (HIMMEL-966), so mirror it minus node.
NONODE_BIN=/usr/bin
if [ -x /usr/bin/node ] || [ -x /usr/bin/node.exe ]; then
    NONODE_BIN="$WS/nonode-bin"
    mkdir -p "$NONODE_BIN"
    for _f in /usr/bin/*; do
        _b="${_f##*/}"
        case "$_b" in node|node.exe|nodejs) continue ;; esac
        ln -s "$_f" "$NONODE_BIN/$_b" 2>/dev/null || true
    done
fi
run_fence deny no "$HIMMEL" "node absent -> rc 2 (fail-closed)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek" PATH="$NONODE_BIN"

# (9) unreadable phi-roots (a directory sits at the phi-roots path) -> rc 2
run_fence deny no "$HIMMEL" "unreadable phi-roots -> rc 2" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$PHI_BADROOTS"

# (9b) HIMMEL-3242: the phi-roots / egress-denylist reader trims surrounding
# whitespace and skips whole-line `#` comments, the same rules as
# refresh-graph-map.sh's _corpus_is_salus_root guard. Untrimmed, an indented or
# CRLF/space-padded salus root never prefix-matched and the target fell through
# to himmel-code (allow) — fail-OPEN on the hook path. Each target sits under
# $HIMMEL, so a MISS classifies himmel-code (allow) and a HIT classifies salus
# (deny): the verdict alone discriminates. The last two cases guard the other
# direction: a blank/whitespace-only or `#` line must match NOTHING (an entry
# that trims to "" would otherwise prefix-match every path).
echo "== phi-roots / egress-denylist trim + #-comment skip (HIMMEL-3242) =="
mkdir -p "$HIMMEL/phiA" "$HIMMEL/phiB" "$HIMMEL/other"
: > "$HIMMEL/phiA/x.md"; : > "$HIMMEL/phiB/y.md"; : > "$HIMMEL/other/z.md"
# trimcfg <list-name> <printf-format> [args...] — fresh config dir, left in
# $_cfg. Not a command substitution: a fixture failure aborts the suite, since
# an empty $_cfg would make the allow cases pass vacuously (no list at all).
trimcfg() {
    local name="$1" fmt="$2"; shift 2
    if ! _cfg="$(mktemp -d "$WS/trimcfg.XXXXXX")" || [ ! -d "$_cfg" ]; then
        echo "FAIL: trimcfg: mktemp -d under $WS failed" >&2; exit 1
    fi
    # shellcheck disable=SC2059 # fmt is the per-case printf format
    printf "$fmt" "$@" > "$_cfg/$name" \
        || { echo "FAIL: trimcfg: cannot write $_cfg/$name" >&2; exit 1; }
}
trimcfg phi-roots '   %s\n' "$HIMMEL/phiA"
run_fence deny no "$HIMMEL" "phi-roots: space-indented salus root classifies salus -> deny" \
    "graphify update $HIMMEL/phiA/x.md --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$_cfg"
trimcfg phi-roots '\t%s\t\n' "$HIMMEL/phiA"
run_fence deny no "$HIMMEL" "phi-roots: tab-padded salus root classifies salus -> deny" \
    "graphify update $HIMMEL/phiA/x.md --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$_cfg"
trimcfg egress-denylist '  %s  \r\n' "$HIMMEL/phiA"
run_fence deny no "$HIMMEL" "egress-denylist: space-padded CRLF salus root classifies salus -> deny" \
    "graphify update $HIMMEL/phiA/x.md --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$_cfg"
trimcfg phi-roots '# operator note\n%s\n# trailing note\n' "$HIMMEL/phiA"
run_fence deny no "$HIMMEL" "phi-roots: root between #-comment lines still classifies salus -> deny" \
    "graphify update $HIMMEL/phiA/x.md --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$_cfg"
trimcfg phi-roots '  # indented note\n%s\n' "$HIMMEL/phiA"
run_fence deny no "$HIMMEL" "phi-roots: indented #-comment line does not hide the next root -> deny" \
    "graphify update $HIMMEL/phiA/x.md --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$_cfg"
trimcfg phi-roots '   \n\t\n\n#\n'
run_fence allow no "$HIMMEL" "phi-roots: blank / whitespace-only / bare-# lines match nothing -> allow" \
    "graphify update $HIMMEL/other/z.md --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$_cfg"
trimcfg phi-roots '# %s\n  #%s\n' "$HIMMEL/phiB" "$HIMMEL/phiB"
run_fence allow no "$HIMMEL" "phi-roots: a commented-out root is NOT an entry -> allow" \
    "graphify update $HIMMEL/phiB/y.md --backend deepseek" CLAUDE_GLM_CONFIG_DIR="$_cfg"

echo "== normalization + backend-detect + provider mapping =="

# (10a) .. traversal escaping into salus -> deny
run_fence deny no "$LUNA" ".. traversal Clippings/../../salus -> deny" \
    "graphify update Clippings/../../salusvault/notes/patient.md --backend deepseek"

# (10b) .. traversal escaping Clippings resolves to luna-personal (NOT treated as
# a Clippings path). luna-clippings and luna-personal are verdict-IDENTICAL for
# every remaining extraction provider now that moonshot is retired (HIMMEL-2101:
# both corpora fall to the same plain `allow` via the anthropic operating-
# substrate cell, or default-deny for everything else), so a verdict-alone
# discriminator no longer proves reclassification. Assert directly on the
# ledger's "corpus" field instead (strictly stronger). Vehicle:
# GRAPHIFY_DECLARED_BACKEND=claude-cli (declared-backend substitution always
# ledgers, even on the plain `allow` cell this real luna-personal root now
# hits) rather than an explicit --backend flag, so a ledger line exists to
# inspect. The opt-in-cannot-save-a-MORE-restrictive-escape property is
# carried by the salus-escape case (10a above, which stays a hard deny).
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$LUNA" && env $CLEAN_ENV GRAPHIFY_DECLARED_BACKEND=claude-cli "$BASH_BIN" "$FENCE" "graphify update Clippings/../journal-2026.md" ) >/dev/null 2>&1; rc_trav=$?
if [ "$rc_trav" -eq 0 ] && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null; then
    pass ".. traversal out of Clippings -> luna-personal reclassification (ledger corpus)"
else
    fail ".. traversal out of Clippings: rc=$rc_trav ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (11) uppercase --backend CLAUDE-CLI is lower-cased -> anthropic -> luna-personal
# allow (HIMMEL-2101: claude-cli is the sanctioned semantic backend, kimi/
# moonshot is retired). Pins case-insensitive backend normalization: an
# un-lowered "CLAUDE-CLI" would miss the claude|claude-cli case arm and fall
# to the default (undeclared-literal) branch, which denies on luna-personal.
run_fence allow no "$HIMMEL" "uppercase --backend CLAUDE-CLI -> allow (case-insensitive backend normalization)" \
    "graphify update $LUNA/journal-2026.md --backend CLAUDE-CLI"

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

# (14b) query with cwd in luna-personal + --backend deepseek -> luna-personal
# x deepseek x extraction -> deny (egress-matrix.json: an explicit deny row,
# REVERSED 2026-07-22 HIMMEL-1257 — DeepSeek de-listed for luna-personal
# extraction). This vehicle actually discriminates cwd classification: the
# SAME --backend deepseek is a plain `allow` under the himmel-code wildcard
# row (corpus "himmel-code", provider "*", purpose "*"), so if this cwd were
# misclassified as himmel-code the verdict would flip to allow and the test
# would catch it — claude-cli could not do this (its luna-personal cell is
# also `allow`, so a misclassification to himmel-code's wildcard allow would
# still read as allow and the test would pass either way).
run_fence deny no "$LUNA" "query cwd-luna deepseek -> deny (cwd classification: luna-personal, not himmel-code)" \
    "graphify query \"what is in my journal\" --backend deepseek"

echo "== hook-level: parse + delegation + malformed-json fallback =="

# non-graphify Bash command -> hook exits 0 instantly
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}' | env $CLEAN_ENV HOME="$HOME" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: non-graphify -> exit 0"; else fail "hook: non-graphify expected rc=0 got rc=$rc out=$out"; fi

# non-Bash tool -> hook exits 0
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | env $CLEAN_ENV HOME="$HOME" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: non-Bash tool -> exit 0"; else fail "hook: non-Bash expected rc=0 got rc=$rc out=$out"; fi

# graphify salus deny delegated through the hook -> rc 2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: graphify salus -> delegated deny rc=2"; else fail "hook: expected rc=2 + DENY got rc=$rc out=$out"; fi

# graphify allow (himmel) delegated through the hook -> rc 0
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update %s --backend deepseek"}}' "$HIMMEL/scripts/thing.sh")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: graphify himmel -> delegated allow rc=0"; else fail "hook: expected rc=0 got rc=$rc out=$out"; fi

# HIMMEL-2610: the hook's CMDPOS pre-filter regex must recognize abbreviated
# nice/time long options (not just their literal full spellings), or the
# wrapped clause under-consumes a token, CMDPOS never matches "graphify" at
# command position, and the hook exits 0 WITHOUT EVER INVOKING THE FENCE — a
# full silent bypass, more severe than a classify_clause-side miss since
# there is no downstream fail-closed catch-all at this layer.

# nice --adj (abbreviation of --adjustment) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"nice --adj 5 graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: nice --adj graphify salus -> delegated deny rc=2 (abbrev reaches fence)"; else fail "hook: nice --adj expected rc=2 + DENY got rc=$rc out=$out"; fi

# time --for (abbreviation of --format) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"time --for %%e graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: time --for graphify salus -> delegated deny rc=2 (abbrev reaches fence)"; else fail "hook: time --for expected rc=2 + DENY got rc=$rc out=$out"; fi

# time --o (abbreviation of --output) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"time --o /tmp/x graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: time --o graphify salus -> delegated deny rc=2 (abbrev reaches fence)"; else fail "hook: time --o expected rc=2 + DENY got rc=$rc out=$out"; fi

# negative control: nice --adjustment (unabbreviated, separate value) still
# denies for the real reason -- confirms the fix didn't change the
# already-working literal-spelling path
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"nice --adjustment 5 graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: nice --adjustment (unabbreviated) graphify salus -> delegated deny rc=2 (unchanged)"; else fail "hook: nice --adjustment expected rc=2 + DENY got rc=$rc out=$out"; fi

# env --u (abbreviation of --unset) wrapping a salus deny -> rc=2 (hook's
# generic env alternative already matched this; pins the fence-side fix too)
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"env --u FOO graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: env --u graphify salus -> delegated deny rc=2 (abbrev reaches fence)"; else fail "hook: env --u expected rc=2 + DENY got rc=$rc out=$out"; fi

# timeout --k (abbreviation of --kill-after) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"timeout --k 5 10 graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: timeout --k graphify salus -> delegated deny rc=2 (abbrev reaches fence)"; else fail "hook: timeout --k expected rc=2 + DENY got rc=$rc out=$out"; fi

# sudo --us (abbreviation of --user) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"sudo --us root graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: sudo --us graphify salus -> delegated deny rc=2 (abbrev reaches fence)"; else fail "hook: sudo --us expected rc=2 + DENY got rc=$rc out=$out"; fi

# HIMMEL-2610: stdbuf was MISSING from the hook's CMDPOS pre-filter wrapper
# alternation entirely (unlike sudo/env/timeout/nice/time above) - ANY
# stdbuf-wrapped graphify call, regardless of flag spelling (even a bare
# short option), never matched CMDPOS and the hook exited 0 WITHOUT EVER
# INVOKING THE FENCE. This is a routing-layer bypass, distinct from and
# broader than the abbreviation gap inside graphify-fence.sh's own stdbuf arm
# (operator-applied one-line CMDPOS fix, HIMMEL-2610).

# stdbuf -o (short option, was already correct fence-side, but blocked at the
# routing layer pre-fix) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"stdbuf -o L graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: stdbuf -o graphify salus -> delegated deny rc=2 (routing reaches fence)"; else fail "hook: stdbuf -o expected rc=2 + DENY got rc=$rc out=$out"; fi

# stdbuf --output (long spelling) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"stdbuf --output L graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: stdbuf --output graphify salus -> delegated deny rc=2 (routing reaches fence)"; else fail "hook: stdbuf --output expected rc=2 + DENY got rc=$rc out=$out"; fi

# stdbuf --outp= (abbreviated, attached value) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"stdbuf --outp=L graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: stdbuf --outp= graphify salus -> delegated deny rc=2 (routing reaches fence)"; else fail "hook: stdbuf --outp= expected rc=2 + DENY got rc=$rc out=$out"; fi

# stdbuf -oL (combined short flag) wrapping a salus deny -> rc=2
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"stdbuf -oL graphify update %s --backend glm"}}' "$SALUS/notes/patient.md")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" -i "DENY"; then pass "hook: stdbuf -oL graphify salus -> delegated deny rc=2 (routing reaches fence)"; else fail "hook: stdbuf -oL expected rc=2 + DENY got rc=$rc out=$out"; fi

# negative control: stdbuf -o L echo graphify -> allow (graphify is only an
# ARGUMENT to echo here, not at command position; the looser stdbuf
# pre-filter must still fall through correctly once the fence classifies it)
payload='{"tool_name":"Bash","tool_input":{"command":"stdbuf -o L echo graphify"}}'
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: stdbuf -o L echo graphify -> allow rc=0 (not command position)"; else fail "hook: stdbuf -o L echo graphify expected rc=0 got rc=$rc out=$out"; fi

# (16) malformed hook JSON that mentions a graphify command + jq present -> deny
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"graphify update /x --backend glm"' | env $CLEAN_ENV HOME="$HOME" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "hook: malformed JSON + graphify -> deny rc=2"; else fail "hook: malformed JSON expected rc=2 got rc=$rc out=$out"; fi

# malformed hook JSON WITHOUT graphify -> allow (never block unrelated on bad payload)
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"echo hi"' | env $CLEAN_ENV HOME="$HOME" "$BASH_BIN" "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: malformed JSON no-graphify -> allow rc=0"; else fail "hook: malformed no-graphify expected rc=0 got rc=$rc out=$out"; fi

echo "== ledger line CONTENT (verdict + corpus fields) =="

# declared-backend + plain allow: luna-personal x claude-cli -> ledger line
# carries verdict + corpus (HIMMEL-2101: kimi/moonshot's native allow+log lane
# is retired — no matrix cell produces "allow+log" any more, so this now pins
# the declared-backend-substitution always-ledgers-on-allow path instead;
# GRAPHIFY_DECLARED_BACKEND, not an explicit --backend flag, so a ledger line
# exists to inspect on this real, non-marker-declared root).
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_DECLARED_BACKEND=claude-cli "$BASH_BIN" "$FENCE" "graphify update $LUNA/journal-2026.md" ) >/dev/null 2>&1
if grep -q '"verdict":"allow"' "$LEDGER" 2>/dev/null && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null; then
    pass "ledger content: allow verdict + luna-personal corpus (declared backend)"
else
    fail "ledger content allow: got $(cat "$LEDGER" 2>/dev/null)"
fi

# A legal POSIX path may contain ESC (0x1b). The ledger must encode it as a
# Unicode escape so the physical JSONL line remains parseable. Vehicle:
# GRAPHIFY_DECLARED_BACKEND=claude-cli (HIMMEL-2101: kimi/moonshot's allow+log
# lane is retired — a declared backend is what still guarantees a ledger line
# on this real, non-marker root).
FENCE_CTRL_PATH="$LUNA/$(printf 'control\033path.md')"
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_DECLARED_BACKEND=claude-cli "$BASH_BIN" "$FENCE" "graphify update $FENCE_CTRL_PATH" ) >/dev/null 2>&1
if grep -qF "$(printf '\\u%04x' 27)" "$LEDGER" 2>/dev/null \
   && node -e "JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'))" "$LEDGER"; then
    pass "ledger content: ESC path is escaped into valid JSON"
else
    fail "ledger content ESC path: got $(cat "$LEDGER" 2>/dev/null)"
fi

# conditional: salus x local-ollama opt-in -> ledger line carries conditional +
# salus. Moved here (HIMMEL-2224): clippings x zai-glm was the OTHER
# conditional cell exercised by this case, but HIMMEL-2224/1749 reversed it to
# a plain deny, so it can no longer produce a "conditional" ledger line. The
# only conditional cell the fence can still reach at extraction is
# salus x local-ollama (GRAPHIFY_SALUS_LOCAL_OK=1).
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_SALUS_LOCAL_OK=1 "$BASH_BIN" "$FENCE" "graphify update $SALUS/notes/patient.md --backend ollama" ) >/dev/null 2>&1
if grep -q '"verdict":"conditional"' "$LEDGER" 2>/dev/null && grep -q '"corpus":"salus"' "$LEDGER" 2>/dev/null; then
    pass "ledger content: conditional verdict + salus corpus"
else
    fail "ledger content conditional: got $(cat "$LEDGER" 2>/dev/null)"
fi

# nested handover root (HIMMEL-817, post-HIMMEL-343 fold): HANDOVER_DIR INSIDE
# the vault -> the path classifies as the VAULT corpus (luna-personal, rank 4),
# NOT handover-state (rank 2) — vault roots are checked first, so a fold-style
# setup tightens classification and the handover-state row keeps serving only
# Mode-B external state repos. claude-cli extraction verdict is a plain allow
# (HIMMEL-2101: kimi/moonshot's allow+log lane is retired); declared via
# GRAPHIFY_DECLARED_BACKEND so a ledger line exists to inspect.
mkdir -p "$LUNA/handovers/op"
: > "$LUNA/handovers/op/next-session-1.md"
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV HANDOVER_DIR="$LUNA/handovers" GRAPHIFY_DECLARED_BACKEND=claude-cli "$BASH_BIN" "$FENCE" "graphify update $LUNA/handovers/op/next-session-1.md" ) >/dev/null 2>&1
if grep -q '"verdict":"allow"' "$LEDGER" 2>/dev/null && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null; then
    pass "nested HANDOVER_DIR inside vault classifies as luna-personal (allow)"
else
    fail "nested handover root: got $(cat "$LEDGER" 2>/dev/null)"
fi

echo "== egress-matrix-eval.mjs unit =="

# de-listed alibaba cell (was pending-operator, explicit deny post-HIMMEL-1257) -> verdict deny
v=$(node "$EVAL_HELPER" luna-clippings alibaba embedding 2>/dev/null | cut -f1)
if [ "$v" = deny ]; then pass "eval: de-listed alibaba cell -> deny"; else fail "eval: alibaba cell expected deny got '$v'"; fi

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

# (M2) MSYS-form path under the luna root -> luna-personal (allow + ledger).
# claude-cli is the sanctioned luna-personal backend (HIMMEL-2101; kimi/
# moonshot's allow+log lane is retired) — declared via GRAPHIFY_DECLARED_BACKEND
# so a ledger line exists to prove the MSYS path resolved under this root.
run_fence allow yes "$HIMMEL" "MSYS /c/... under luna root -> luna-personal allow+ledger" \
    "graphify update /c/fake/luna/journal.md" LUNA_VAULT_PATH="C:/fake/luna" GRAPHIFY_DECLARED_BACKEND=claude-cli

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

echo "== HIMMEL-845: cross-drive drive-relative fail-open =="

# HIMMEL-808 anchored a drive-RELATIVE `X:tail` token to the tool-call cwd,
# which is exact ONLY when that cwd is on drive X. Windows keeps a SEPARATE cwd
# PER DRIVE (the hidden `=C:`/`=D:` env vars), so `Z:tail` from a C: cwd
# resolves under Z:'s own current directory - one this fence cannot read.
# Anchoring it to the C: cwd anyway yielded a synthetic path that classified as
# the benign himmel-code corpus and ALLOWED, while the real target could sit
# inside the salus PHI vault. Must now fail closed.

# (X1) THE fail-open regression: pre-fix this anchored to $HIMMEL/doc.md ->
# himmel-code -> ALLOW. The cwd here is the MSYS-mount fixture root, whose
# backing drive is not lexically derivable, so the fence cannot prove the
# same-drive case either way -> deny.
run_fence deny no "$HIMMEL" "845: cross-drive Z:doc.md (was fail-OPEN as himmel-code) -> deny" \
    "graphify update Z:doc.md --backend deepseek"

# (X2) The pre-845 case this replaces: `C:scripts/thing.sh` under the MSYS-form
# fixture cwd. It used to anchor to the cwd and allow; with no determinable cwd
# drive the anchor is unprovable, so it now denies (was: "drive-relative
# C:scripts/thing.sh anchors to cwd -> allow").
run_fence deny no "$HIMMEL" "845: drive-relative under an undeterminable-drive cwd -> deny" \
    "graphify update C:scripts/thing.sh --backend deepseek"

# (X3) A drive-ROOTED absolute (`C:/...`) is cwd-INDEPENDENT and must NOT be
# swept up by the cross-drive deny - it still classifies against the roots
# exactly as before. Pure lexical (drive-lettered root + drive-lettered
# candidate), so it exercises on any OS.
run_fence allow no "$HIMMEL" "845: drive-ROOTED C:/... is cwd-independent, not cross-drive -> allow" \
    "graphify update C:/fake/himmel/doc.md --backend deepseek" GRAPHIFY_HIMMEL_ROOT="C:/fake/himmel"

# (X4/X5) With a drive-lettered cwd the fence can PROVE the drive relation, so
# same-drive must still anchor (allow) and a genuine mismatch must deny. Needs a
# genuinely drive-lettered form of the fixture root: `drive_form`/$ROOT_DRIVE
# above only rewrites an MSYS `/c/...` path, and the mktemp fixture lives under
# Git-Bash's virtual `/tmp` mount, which has no such form. `pwd -W` is the MSYS
# builtin that yields the real Windows view; it fails on POSIX -> skip there.
HIMMEL_WIN=""
if HIMMEL_WIN_TRY=$( cd "$HIMMEL" && pwd -W 2>/dev/null ); then
    HIMMEL_WIN="$HIMMEL_WIN_TRY"
fi
case "$HIMMEL_WIN" in
    [A-Za-z]:/*)
        CWD_DRIVE="${HIMMEL_WIN%%:*}"
        run_fence allow no "$HIMMEL" "845: SAME-drive drive-relative still anchors to cwd -> allow" \
            "graphify update ${CWD_DRIVE}:scripts/thing.sh --backend deepseek" \
            GRAPHIFY_TOOL_CWD="$HIMMEL_WIN" GRAPHIFY_HIMMEL_ROOT="$HIMMEL_WIN"
        run_fence deny no "$HIMMEL" "845: genuine cross-drive mismatch vs a drive-lettered cwd -> deny" \
            "graphify update Z:scripts/thing.sh --backend deepseek" \
            GRAPHIFY_TOOL_CWD="$HIMMEL_WIN" GRAPHIFY_HIMMEL_ROOT="$HIMMEL_WIN"
        ;;
    *)
        printf '  SKIP  845: same-drive / mismatch pair (no drive-lettered cwd on this host)\n' ;;
esac

echo "== HIMMEL-778: .graphify-corpus staged-copy declaration =="

STAGED="$WS/staged";        mkdir -p "$STAGED";        : > "$STAGED/copy.md";  printf 'luna-personal\n' > "$STAGED/.graphify-corpus"
STAGED_SALUS="$WS/stgsalus"; mkdir -p "$STAGED_SALUS"; : > "$STAGED_SALUS/copy.md"; printf 'salus\n'        > "$STAGED_SALUS/.graphify-corpus"
STAGED_BAD="$WS/stgbad";     mkdir -p "$STAGED_BAD";   : > "$STAGED_BAD/copy.md";   printf 'banana\n'       > "$STAGED_BAD/.graphify-corpus"
STAGED_NONE="$WS/stgnone";   mkdir -p "$STAGED_NONE";  : > "$STAGED_NONE/copy.md"
STAGED_HIM="$WS/stghim";     mkdir -p "$STAGED_HIM";   : > "$STAGED_HIM/copy.md";   printf 'himmel-code\n'  > "$STAGED_HIM/.graphify-corpus"

# (S1) staged copy declares luna-personal + claude-cli -> allow + ledger (the
# corpus marker's declared=1 always ledgers on an allow-family verdict, even
# the plain `allow` claude-cli/anthropic now gets — HIMMEL-2101, kimi/moonshot
# retired)
run_fence allow yes "$HIMMEL" "staged marker luna-personal + claude-cli -> allow+ledger" \
    "graphify update $STAGED/copy.md --backend claude-cli"

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
# (real root beats the marker; classification NOT relaxed; no declared:true
# field — the corpus is NOT marker-declared). Backend declared via
# GRAPHIFY_DECLARED_BACKEND=claude-cli (HIMMEL-2101, kimi/moonshot retired) so
# a ledger line exists to inspect on this real, non-marker-declared root; that
# is a SEPARATE declared_backend_source field from the corpus "declared" bit
# this case asserts is absent.
rm -f "$LEDGER"
printf 'himmel-code\n' > "$LUNA/.graphify-corpus"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_DECLARED_BACKEND=claude-cli "$BASH_BIN" "$FENCE" "graphify update $LUNA/journal-2026.md" ) >/dev/null 2>&1; rc_s5=$?
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
        "graphify update $STAGED_UR/copy.md --backend glm"
fi
chmod 644 "$STAGED_UR/.graphify-corpus" 2>/dev/null || true

# (S8) marker WITHOUT a trailing newline is still valid (CR codex-1: `read`
# exits non-zero on EOF-without-newline but populates the variable; the old
# `|| line=""` cleared it -> false deny on a `printf 'x' >` marker).
STAGED_NONL="$WS/stgnonl"; mkdir -p "$STAGED_NONL"; : > "$STAGED_NONL/copy.md"; printf 'luna-personal' > "$STAGED_NONL/.graphify-corpus"
run_fence allow yes "$HIMMEL" "staged marker with NO trailing newline -> still classifies (allow+ledger)" \
    "graphify update $STAGED_NONL/copy.md --backend claude-cli"

# (S10) UNCONFIGURED luna root -> the marker is INERT (silent-failure CR round:
# without a visible luna root the real-root-beats-marker precedence cannot be
# enforced, so a valid marker must NOT classify; pre-marker deny behavior).
run_fence deny no "$HIMMEL" "no luna root configured -> valid marker is inert (deny)" \
    "graphify update $STAGED/copy.md --backend glm" LUNA_VAULT_PATH=

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
                "graphify update $STAGED_MSYS/copy.md --backend claude-cli"
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
# invocation -> most-restrictive still wins (luna-personal x claude-cli ->
# allow) AND declared:true is present (the corpus marker's declared=1 always
# ledgers). HIMMEL-2101: kimi/moonshot's allow+log lane is retired — the
# matrix cell claude-cli reaches (anthropic, operating substrate) is a plain
# allow.
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify merge-graphs $HIMMEL/scripts/thing.sh $STAGED/copy.md --backend claude-cli" ) >/dev/null 2>&1; rc_d3=$?
if [ "$rc_d3" -eq 0 ] && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null \
    && grep -q '"verdict":"allow"' "$LEDGER" 2>/dev/null && grep -q '"declared":true' "$LEDGER" 2>/dev/null; then
    pass "staged luna-personal + real himmel -> most-restrictive wins + declared ledger"
else
    fail "mixed-corpus D3: rc=$rc_d3 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

echo "== HIMMEL-779 gap 1: bare-word target resolved against tool-call cwd =="

# (B1) POSITION-0 BARE-WORD swallowed as a subcommand (HIMMEL-779): a bare
# (no slash/drive/extension) dir name that EXISTS under the tool-call cwd is a
# target, not a subcommand word. Nest a .salus-marked PHI dir inside the safe
# himmel corpus; the bare name must classify salus -> deny, not be eaten as a
# subcommand so the safe cwd fallback allows (the fail-open).
mkdir -p "$HIMMEL/nestedphi"; : > "$HIMMEL/nestedphi/.salus"
run_fence deny no "$HIMMEL" "position-0 bare-word PHI dir -> classify (not subcmd)" \
    "graphify nestedphi --backend deepseek"

# (B2) bare-word target at a later position alongside a safe path: the bare
# PHI dir name used to be skipped as a "non-path arg" so the co-present safe
# path won the rank -> allow; it must now resolve under cwd -> salus -> deny.
run_fence deny no "$WS" "bare-word PHI + safe path -> most-restrictive deny" \
    "graphify merge-graphs salusvault $HIMMEL/scripts/thing.sh --backend deepseek"

# (B3) NEGATIVE: a position-0 bare word that does NOT exist under cwd is still
# the subcommand (update), so the real subcommand grammar keeps working.
run_fence allow no "$HIMMEL/scripts" "bare word not on disk -> still subcommand (update)" \
    "graphify update --force"

echo "== HIMMEL-779 gap 2: relative path resolves against tool-call cwd =="

# (C1) Hook-cwd mismatch fail-open (HIMMEL-779): the fence's own $PWD is the
# SAFE himmel corpus, but the tool-call cwd (GRAPHIFY_TOOL_CWD, what the hook
# payload carries in .tool_input.cwd) is the luna vault. A relative path must
# resolve against the TOOL-CALL cwd -> luna-personal -> deny, not against the
# fence $PWD -> himmel -> allow (the fail-open). Uses --backend deepseek
# DELIBERATELY (HIMMEL-1257): luna-personal x deepseek = DENY while himmel-code x
# deepseek = ALLOW, so the deny actually catches the fail-open (glm now allows on
# BOTH corpora post-HIMMEL-1122, and gemini denies on both — either would be a
# vacuous test that passes even when the resolution is wrong).
run_fence deny no "$HIMMEL" "relative path resolves vs tool-call cwd (luna) -> deny" \
    "graphify update journal-2026.md --backend deepseek" GRAPHIFY_TOOL_CWD="$LUNA"

# (C2) same shape but tool-call cwd is the SAFE himmel corpus -> allow (the
# declared cwd genuinely points at an allow corpus; not a blanket allow).
run_fence allow no "$HIMMEL" "relative path resolves vs tool-call cwd (himmel) -> allow" \
    "graphify update scripts/thing.sh --backend deepseek" GRAPHIFY_TOOL_CWD="$HIMMEL"

# (C-hook) the hook threads .tool_input.cwd -> GRAPHIFY_TOOL_CWD: a relative
# path into the luna corpus (payload cwd=$LUNA) denies even though the hook
# process runs from the safe himmel corpus (the production shape: the hook's
# own $PWD is the project root, not the command's cwd). --backend deepseek for
# the same asymmetry reason as C1 (luna deny / himmel allow, HIMMEL-1257).
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update journal-2026.md --backend deepseek","cwd":"%s"}}' "$LUNA")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | ( cd "$HIMMEL" && env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1 )); rc=$?
if [ "$rc" -eq 2 ]; then pass "hook: threads .tool_input.cwd -> relative luna path denies"; else fail "hook cwd-thread: expected rc=2 got rc=$rc out=$out"; fi

echo "== HIMMEL-779 gap 3: update-subcommand backend declaration + order-insensitive parse =="

# (D1) graphify `update` takes NO --backend on its CLI (re-extraction is
# LLM-free), yet the fence demands a declared provider for a non-himmel
# corpus. A declared backend via env (GRAPHIFY_DECLARED_BACKEND) must satisfy
# the requirement AND still flow through the egress matrix -> luna-personal x
# claude-cli -> allow+ledger (HIMMEL-779 gap 3a; declared_backend_source
# always ledgers on allow). claude-cli is the sanctioned luna-personal
# backend (HIMMEL-2101: kimi/moonshot is retired).
run_fence allow yes "$HIMMEL" "declared backend (claude-cli) on update luna -> allow+ledger" \
    "graphify update $LUNA/journal-2026.md" GRAPHIFY_DECLARED_BACKEND=claude-cli

# (D2) declared backend still routed through the matrix: a deny-provider (gemini)
# declared via env on luna-personal -> deny (declaration is not a bypass). gemini
# is the churn-proof denier (hard-deny everywhere, unaffected by the HIMMEL-2224
# zai-glm reversal above) — kept as the vehicle so this case does not depend on
# glm's currently-denying policy either.
run_fence deny no "$HIMMEL" "declared backend (gemini) on luna -> deny (matrix still applies)" \
    "graphify update $LUNA/journal-2026.md" GRAPHIFY_DECLARED_BACKEND=gemini

# (D3) multi-distinct-backend last-wins order sensitivity (HIMMEL-779 gap 3b):
# a BLOCKED backend (gemini) placed BEFORE an allowed one (deepseek) used to
# let the allowed one win (last-wins) -> allow; distinct conflicting backends
# must now DENY regardless of order so a blocked backend cannot be hidden.
run_fence deny no "$HIMMEL" "conflicting backends (gemini then deepseek) -> deny" \
    "graphify update $HIMMEL/scripts/thing.sh --backend gemini --backend deepseek"

# (D4) reverse order is also a conflict -> deny (order-INsensitive).
run_fence deny no "$HIMMEL" "conflicting backends (deepseek then gemini) -> deny" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek --backend gemini"

# (D5) the SAME backend repeated is NOT a conflict -> allow (no over-deny).
run_fence allow no "$HIMMEL" "same backend repeated -> not a conflict -> allow" \
    "graphify update $HIMMEL/scripts/thing.sh --backend deepseek --backend deepseek"

echo "== HIMMEL-779 CR round-1: GRAPHIFY_DECLARED_BACKEND scoping (FIX 1) =="

# (F1a) non-update subcommand + declared backend + no --backend on a luna path
# -> deny (GRAPHIFY_DECLARED_BACKEND is scoped to the LLM-free `update`
# subcommand only; a provider-using subcommand still hits the no-backend deny).
run_fence deny no "$HIMMEL" "declared backend on non-update subcommand -> deny (scope)" \
    "graphify cluster $LUNA/journal-2026.md" GRAPHIFY_DECLARED_BACKEND=glm

# (F1b) himmel-code corpus, no flag, declared backend set to a HARD-DENY
# provider (gemini) -> still evaluated as the local-ollama default -> allow,
# no ledger. If the declared value leaked through it would hit the gemini
# hard-deny row instead.
run_fence allow no "$HIMMEL" "declared backend ignored for himmel-code no-flag -> ollama default allow" \
    "graphify update $HIMMEL/scripts/thing.sh" GRAPHIFY_DECLARED_BACKEND=gemini

# (F1c) explicit --backend wins over a safe declared backend (precedence
# pinned): --backend gemini denies even though GRAPHIFY_DECLARED_BACKEND=ollama
# (a safe value) is also set - the declared var is consulted ONLY when
# --backend is absent. gemini is the churn-proof denier (glm now allows on luna
# post-HIMMEL-1122, so it can no longer show the explicit-wins deny).
run_fence deny no "$HIMMEL" "explicit --backend gemini wins over safe declared ollama -> deny" \
    "graphify update $LUNA/journal-2026.md --backend gemini" GRAPHIFY_DECLARED_BACKEND=ollama

echo "== HIMMEL-779 CR round-1: in-command cd drift (FIX 2) =="

# (F2a) cd into an unsafe corpus, then a RELATIVE graphify target: the
# recorded tool-call cwd is the SAFE himmel corpus (what the hook payload
# captured before the shell ran `cd`), so the old parser resolved the
# relative target against it and allowed (himmel-code x zai-glm is an allow
# cell) - the fence cannot see the `cd`. CD_SEEN must deny instead.
run_fence deny no "$HIMMEL" "in-command cd then relative graphify target -> deny" \
    "cd $LUNA && graphify update journal-2026.md --backend glm" GRAPHIFY_TOOL_CWD="$HIMMEL"

# (F2b) same in-command cd, but the graphify target is ABSOLUTE -> unaffected
# by the cd-drift guard, normal matrix result (luna-personal x claude-cli ->
# allow+ledger via GRAPHIFY_DECLARED_BACKEND; claude-cli is the sanctioned
# luna-personal backend, HIMMEL-2101 — kimi/moonshot's allow+log lane is
# retired, so a declared backend is what still ledgers here).
run_fence allow yes "$HIMMEL" "in-command cd then ABSOLUTE graphify target -> unaffected (allow+ledger)" \
    "cd $LUNA && graphify update $LUNA/journal-2026.md" GRAPHIFY_TOOL_CWD="$HIMMEL" GRAPHIFY_DECLARED_BACKEND=claude-cli

# (F2c) no-cwd hook payload regression pin: WITHOUT any .tool_input.cwd field,
# a relative safe path still resolves against the hook process's own $PWD (the
# documented fallback) and allows - this must keep working (no cd involved).
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update scripts/thing.sh --backend deepseek"}}')
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$( cd "$HIMMEL" && printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: no-cwd payload + relative safe path -> allow (fallback pin)"; else fail "hook no-cwd fallback: expected rc=0 got rc=$rc out=$out"; fi

# (F2c2, CR round-2) inherited-env regression: a no-cwd payload must DROP any
# GRAPHIFY_TOOL_CWD already present in the hook's own environment (e.g. leaked
# from the launching shell) rather than anchor to it - the hook must unset it
# and fall back to its own $PWD. GRAPHIFY_TOOL_CWD is set here to the UNSAFE
# luna corpus AFTER CLEAN_ENV so it survives the scrub. No --backend flag on
# the command (the no-backend policy denies every non-himmel corpus, see the
# "no-backend luna" case above): if the hook failed to drop the leaked var,
# the relative target would resolve under luna and DENY (rc=2) instead of the
# correct himmel-corpus ALLOW (rc=0, local-ollama default).
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update scripts/thing.sh"}}')
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$( cd "$HIMMEL" && printf '%s' "$payload" | env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" GRAPHIFY_TOOL_CWD="$LUNA" "$BASH_BIN" "$HOOK" 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: no-cwd payload drops inherited GRAPHIFY_TOOL_CWD -> allow (not luna-anchored)"; else fail "hook inherited-cwd drop: expected rc=0 got rc=$rc out=$out"; fi

# (F2d) hook-level allow mirror of the C2 cwd-thread test: payload cwd =
# himmel (safe), relative path -> rc=0.
rm -f "$LEDGER"
payload=$(printf '{"tool_name":"Bash","tool_input":{"command":"graphify update scripts/thing.sh --backend deepseek","cwd":"%s"}}' "$HIMMEL")
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$(printf '%s' "$payload" | ( cd "$HIMMEL" && env $CLEAN_ENV HOME="$HOME" LUNA_VAULT_PATH="$LUNA" HANDOVER_DIR="$HANDDIR" CLAUDE_GLM_CONFIG_DIR="$PHI" GRAPHIFY_HIMMEL_ROOT="$HIMMEL" "$BASH_BIN" "$HOOK" 2>&1 )); rc=$?
if [ "$rc" -eq 0 ]; then pass "hook: threads .tool_input.cwd=himmel -> relative himmel path allows"; else fail "hook cwd-thread allow mirror: expected rc=0 got rc=$rc out=$out"; fi

echo "== HIMMEL-779 CR round-1: bare-word over/under-restriction guards =="

# (F4g) bare word that EXISTS and is SAFE (a real subdir under the himmel
# corpus) -> himmel-code allow. Guards against over-restricting every bare
# word to deny once it resolves to a real path.
run_fence allow no "$HIMMEL" "bare-word existing SAFE subdir -> himmel-code allow (no over-restriction)" \
    "graphify scripts --backend deepseek"

# (F4h) bare-word PHI dir resolved via GRAPHIFY_TOOL_CWD, not the fence's own
# $PWD (gap1 x gap2 interaction): _exists_under_cwd and classify() both stat
# TOOL_CWD. Fence process cwd is $WS (no nestedphi there); TOOL_CWD points at
# $HIMMEL, whose nestedphi/ is .salus-marked (fixture from gap-1 above).
run_fence deny no "$WS" "bare-word PHI dir resolves via TOOL_CWD not fence \$PWD -> deny" \
    "graphify nestedphi --backend deepseek" GRAPHIFY_TOOL_CWD="$HIMMEL"

echo "== HIMMEL-881: .graphify-backend file-declared backend (update subcommand) =="

# HIMMEL-2101: kimi/moonshot is retired (operator ruling — there is no kimi
# backend). STAGED_BE = claude-cli is the "allow example" (luna-personal x
# anthropic x extraction = allow, via the operating-substrate cell — the
# corpus marker's declared=1 ledgers regardless); STAGED_BE2 = gemini is the
# churn-proof "deny example" (hard-deny everywhere, so it stays a denier no
# matter how provider policy evolves).
STAGED_BE="$WS/stgbackend"; mkdir -p "$STAGED_BE"; : > "$STAGED_BE/copy.md"
printf 'luna-personal\n' > "$STAGED_BE/.graphify-corpus"
printf 'claude-cli\n' > "$STAGED_BE/.graphify-backend"

STAGED_BE2="$WS/stgbackend2"; mkdir -p "$STAGED_BE2"; : > "$STAGED_BE2/copy.md"
printf 'luna-personal\n' > "$STAGED_BE2/.graphify-corpus"
printf 'gemini\n' > "$STAGED_BE2/.graphify-backend"

STAGED_BE_EMPTY="$WS/stgbeempty"; mkdir -p "$STAGED_BE_EMPTY"; : > "$STAGED_BE_EMPTY/copy.md"
printf 'luna-personal\n' > "$STAGED_BE_EMPTY/.graphify-corpus"
: > "$STAGED_BE_EMPTY/.graphify-backend"

STAGED_BE_MULTI="$WS/stgbemulti"; mkdir -p "$STAGED_BE_MULTI"; : > "$STAGED_BE_MULTI/copy.md"
printf 'luna-personal\n' > "$STAGED_BE_MULTI/.graphify-corpus"
printf 'claude-cli\nextra-line\n' > "$STAGED_BE_MULTI/.graphify-backend"   # multiline -> fail-closed deny (claude-cli would allow if the check broke)

STAGED_BE_BADCHARS="$WS/stgbebadchars"; mkdir -p "$STAGED_BE_BADCHARS"; : > "$STAGED_BE_BADCHARS/copy.md"
printf 'luna-personal\n' > "$STAGED_BE_BADCHARS/.graphify-corpus"
printf 'deep seek\n' > "$STAGED_BE_BADCHARS/.graphify-backend"

STAGED_BE_WRONGDIR="$WS/stgbewrong"; mkdir -p "$STAGED_BE_WRONGDIR/sub"; : > "$STAGED_BE_WRONGDIR/sub/copy.md"
printf 'luna-personal\n' > "$STAGED_BE_WRONGDIR/sub/.graphify-corpus"
printf 'claude-cli\n' > "$STAGED_BE_WRONGDIR/.graphify-backend"   # WRONG dir: parent, not sub/ (claude-cli would allow if the wrong-dir check broke)

# (BE1) file-declared backend (claude-cli) satisfies `update` on a non-himmel
# corpus with no --backend and no env var -> allow+ledger (the corpus
# marker's declared=1 always ledgers; luna-personal x claude-cli x extraction
# is a plain `allow` matrix cell via anthropic — HIMMEL-2101, kimi/moonshot's
# allow+log lane is retired).
run_fence allow yes "$HIMMEL" "file-declared backend satisfies update on non-himmel corpus -> allow+ledger" \
    "graphify update $STAGED_BE/copy.md"

# (BE2) sanity: the SAME file alone (gemini, a hard-deny provider on
# luna-personal) denies - proves the file genuinely flows through the matrix,
# not a bypass.
run_fence deny no "$HIMMEL" "file-declared gemini alone denies (matrix still applies)" \
    "graphify update $STAGED_BE2/copy.md"

# (BE3) env wins over file: file declares gemini (denies on its own, see BE2),
# env declares claude-cli (allows) -> allow, proving env precedence over file.
run_fence allow yes "$HIMMEL" "env backend wins over conflicting file backend -> allow (env precedence)" \
    "graphify update $STAGED_BE2/copy.md" GRAPHIFY_DECLARED_BACKEND=claude-cli

# (BE4) empty .graphify-backend file -> deny (fail-closed).
run_fence deny no "$HIMMEL" "empty .graphify-backend file -> deny (fail-closed)" \
    "graphify update $STAGED_BE_EMPTY/copy.md"

# (BE5) multiline .graphify-backend file -> deny (fail-closed).
run_fence deny no "$HIMMEL" "multiline .graphify-backend file -> deny (fail-closed)" \
    "graphify update $STAGED_BE_MULTI/copy.md"

# (BE6) backend name with invalid characters -> deny (fail-closed).
run_fence deny no "$HIMMEL" "backend name with invalid characters -> deny (fail-closed)" \
    "graphify update $STAGED_BE_BADCHARS/copy.md"

# (BE7) .graphify-backend in the WRONG directory (the parent of the
# .graphify-corpus marker's own directory, not the marker's directory itself)
# does not count - treated as absent, falls to the existing no-backend deny.
run_fence deny no "$HIMMEL" ".graphify-backend in parent dir (not the marker dir) does not count -> deny" \
    "graphify update $STAGED_BE_WRONGDIR/sub/copy.md"

# (BE8) LLM-free scoping mirrors the env var (F1a above): a non-update
# subcommand with a file-declared backend still hits the no-backend deny.
run_fence deny no "$HIMMEL" "file-declared backend on non-update subcommand -> deny (scope)" \
    "graphify cluster $STAGED_BE/copy.md"

# (BE9) himmel-code marker + co-located .graphify-backend file: the no-flag
# local-ollama default stands unconditionally for himmel-code (mirrors F1b for
# the env var) - a hard-deny-provider file must NOT leak through. Ledger IS
# expected: STAGED_HIM's corpus is marker-declared, and a marker-declared
# corpus always ledgers even on a plain `allow` cell (see the existing S6
# "declared himmel-code marker + ollama" case above) - unrelated to the
# backend file, which this case proves was ignored (no gemini hard-deny hit).
printf 'gemini\n' > "$STAGED_HIM/.graphify-backend"
run_fence allow yes "$HIMMEL" "himmel-code marker + .graphify-backend file ignored for no-flag default -> ollama allow" \
    "graphify update $STAGED_HIM/copy.md"

echo "== HIMMEL-881 codex-adv-1: all marker dirs must agree (order cannot mask a declaration) =="

# STAGED_BE declares claude-cli, STAGED_BE2 declares gemini, STAGED has NO
# .graphify-backend (all three are luna-personal-marked, same corpus rank) -
# before the fix, only the FIRST target's marker dir was consulted, so
# argument ordering picked which declaration counted (fail-open).

STAGED_BE3="$WS/stgbackend3"; mkdir -p "$STAGED_BE3"; : > "$STAGED_BE3/copy.md"
printf 'luna-personal\n' > "$STAGED_BE3/.graphify-corpus"
printf 'claude-cli\n' > "$STAGED_BE3/.graphify-backend"   # agrees with STAGED_BE (claude-cli) for MA3

# (MA1a/MA1b) two same-corpus dirs with CONFLICTING declarations (claude-cli
# vs gemini) -> deny in BOTH argument orders (neither can hide behind the
# other listed first — the conflict is detected by distinct backend NAMES,
# before any matrix verdict, so the churn-proof claude-cli/gemini pair works
# identically).
run_fence deny no "$HIMMEL" "conflicting file backends claude-cli-dir first -> deny" \
    "graphify update $STAGED_BE/copy.md $STAGED_BE2/copy.md"
run_fence deny no "$HIMMEL" "conflicting file backends gemini-dir first -> deny" \
    "graphify update $STAGED_BE2/copy.md $STAGED_BE/copy.md"

# (MA2a/MA2b) declared dir + dir with NO .graphify-backend -> deny in BOTH
# orders (a declared dir must not vouch for an undeclared co-listed dir).
run_fence deny no "$HIMMEL" "declared dir + missing-file dir (declared first) -> deny" \
    "graphify update $STAGED_BE/copy.md $STAGED/copy.md"
run_fence deny no "$HIMMEL" "declared dir + missing-file dir (missing first) -> deny" \
    "graphify update $STAGED/copy.md $STAGED_BE/copy.md"

# (MA3) two dirs that AGREE (claude-cli + claude-cli) -> allow+ledger
# (agreement is not over-denied; both orders).
run_fence allow yes "$HIMMEL" "two agreeing file backends -> allow+ledger" \
    "graphify update $STAGED_BE/copy.md $STAGED_BE3/copy.md"
run_fence allow yes "$HIMMEL" "two agreeing file backends (reverse order) -> allow+ledger" \
    "graphify update $STAGED_BE3/copy.md $STAGED_BE/copy.md"
# the MA3 ledger line (left by the run_fence call above) must attribute the
# backend to the file declaration path.
if grep -q '"declared_backend_source":"file"' "$LEDGER" 2>/dev/null; then
    pass "MA3 ledger attributes backend to declared_backend_source=file"
else
    fail "MA3 ledger source: got $(cat "$LEDGER" 2>/dev/null)"
fi

# (MA4) multiple target files under ONE staged dir -> a single (dedup'd)
# marker dir -> allow+ledger (the today-path is unchanged).
: > "$STAGED_BE/copy2.md"
run_fence allow yes "$HIMMEL" "two targets under one marker dir -> single dedup'd dir, allow+ledger" \
    "graphify update $STAGED_BE/copy.md $STAGED_BE/copy2.md"

echo "== HIMMEL-881 codex-adv-2: file declaration is STAGED-ONLY (real-root target disables it) =="

# (SO1a/SO1b) staged luna copy (valid claude-cli file) + a REAL luna
# vault path in ONE update, no --backend / no env: before the fix the staged
# copy's declaration satisfied the no-backend policy FOR THE REAL PATH (the
# winning corpus is the real path's) - it must now deny in BOTH orders.
run_fence deny no "$HIMMEL" "staged copy + REAL luna path (staged first) -> deny (staged-only)" \
    "graphify update $STAGED_BE/copy.md $LUNA/journal-2026.md"
run_fence deny no "$HIMMEL" "REAL luna path + staged copy (real first) -> deny (staged-only)" \
    "graphify update $LUNA/journal-2026.md $STAGED_BE/copy.md"

# (SO2) ALL-staged mixed corpora: staged-himmel + staged-luna, both dirs with
# agreeing claude-cli files -> most-restrictive luna-personal x claude-cli ->
# allow+ledger (the staged-only rule must not over-deny fully-staged runs).
STAGED_HIM2="$WS/stghim2"; mkdir -p "$STAGED_HIM2"; : > "$STAGED_HIM2/copy.md"
printf 'himmel-code\n' > "$STAGED_HIM2/.graphify-corpus"
printf 'claude-cli\n' > "$STAGED_HIM2/.graphify-backend"   # agrees with STAGED_BE (claude-cli) for SO2
run_fence allow yes "$HIMMEL" "all-staged mixed corpora w/ agreeing files -> allow+ledger" \
    "graphify update $STAGED_HIM2/copy.md $STAGED_BE/copy.md"
# the SO2 ledger line (left by the run_fence call above) must attribute the
# backend to the file declaration path.
if grep -q '"declared_backend_source":"file"' "$LEDGER" 2>/dev/null; then
    pass "SO2 ledger attributes backend to declared_backend_source=file"
else
    fail "SO2 ledger source: got $(cat "$LEDGER" 2>/dev/null)"
fi

echo "== HIMMEL-881 final CR: unreadable file / cwd-fallback / env-over-mixed / case pins =="

# (FC1) unreadable .graphify-backend -> deny (fail-closed sentinel). Mirrors
# the S7 unreadable-corpus-marker test; skip gracefully where chmod cannot
# drop read (admin on Windows, root on Linux).
STAGED_BE_UR="$WS/stgbeunread"; mkdir -p "$STAGED_BE_UR"; : > "$STAGED_BE_UR/copy.md"
printf 'luna-personal\n' > "$STAGED_BE_UR/.graphify-corpus"
printf 'claude-cli\n' > "$STAGED_BE_UR/.graphify-backend"   # claude-cli would allow if the unreadable check broke (non-vacuous fail-closed)
chmod 000 "$STAGED_BE_UR/.graphify-backend" 2>/dev/null || true
if [ -r "$STAGED_BE_UR/.graphify-backend" ]; then
    printf '  SKIP  unreadable .graphify-backend marker (chmod could not drop read perm here)\n'
else
    run_fence deny no "$HIMMEL" "unreadable .graphify-backend -> deny (fail-closed)" \
        "graphify update $STAGED_BE_UR/copy.md"
fi
chmod 644 "$STAGED_BE_UR/.graphify-backend" 2>/dev/null || true

# (FC2) cwd-fallback call site: cwd IS the staged dir (marker + backend file
# co-located), `graphify update` with NO path arg -> the fallback
# classification is marker-declared, its marker dir is threaded as a 1-entry
# list, any_real_root=0 -> file declaration satisfies the no-backend policy ->
# luna-personal x claude-cli allow, ledger carries source=file.
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$STAGED_BE" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify update --force" ) >/dev/null 2>&1; rc_fc2=$?
if [ "$rc_fc2" -eq 0 ] && grep -q '"declared_backend_source":"file"' "$LEDGER" 2>/dev/null \
    && grep -q '"corpus":"luna-personal"' "$LEDGER" 2>/dev/null; then
    pass "cwd-fallback in staged dir -> file declaration honored (allow + source=file)"
else
    fail "cwd-fallback file declaration: rc=$rc_fc2 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (FC3) env + MIXED staged/real invocation: GRAPHIFY_DECLARED_BACKEND=claude-cli
# with a staged dir whose gemini file would deny alone (BE2) plus a REAL luna
# path. DELIBERATE design: env is the operator/launching-shell trust boundary
# and overrides the staged-only file gate (the file list is never consulted
# when env is set) -> env wins, luna-personal x claude-cli allow, ledger
# records source=env.
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_DECLARED_BACKEND=claude-cli "$BASH_BIN" "$FENCE" "graphify update $STAGED_BE2/copy.md $LUNA/journal-2026.md" ) >/dev/null 2>&1; rc_fc3=$?
if [ "$rc_fc3" -eq 0 ] && grep -q '"declared_backend_source":"env"' "$LEDGER" 2>/dev/null; then
    pass "env declaration wins over mixed staged/real (staged-only gate is file-path-only)"
else
    fail "env-over-mixed: rc=$rc_fc3 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (FC4) fix-1 behavior pin: env-declared run on a REAL root hitting a PLAIN
# `allow` matrix cell (luna-personal x local-ollama) must ALSO leave a ledger
# line with source=env and NO declared:true (previously the allow branch only
# ledgered marker-declared runs - the env-declared line never existed).
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_DECLARED_BACKEND=ollama "$BASH_BIN" "$FENCE" "graphify update $LUNA/journal-2026.md" ) >/dev/null 2>&1; rc_fc4=$?
if [ "$rc_fc4" -eq 0 ] && grep -q '"verdict":"allow"' "$LEDGER" 2>/dev/null \
    && grep -q '"declared_backend_source":"env"' "$LEDGER" 2>/dev/null \
    && ! grep -q '"declared":true' "$LEDGER" 2>/dev/null; then
    pass "env-declared + plain allow cell on real root -> ledgered w/ source=env (fix-1)"
else
    fail "plain-allow env ledger pin: rc=$rc_fc4 ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# (FC5) case-insensitive agreement: 'Claude-Cli' vs 'claude-cli' across two
# dirs is NOT a conflict (mirrors _record_backend's lower-cased comparison).
STAGED_BE_CASE="$WS/stgbecase"; mkdir -p "$STAGED_BE_CASE"; : > "$STAGED_BE_CASE/copy.md"
printf 'luna-personal\n' > "$STAGED_BE_CASE/.graphify-corpus"
printf 'Claude-Cli\n' > "$STAGED_BE_CASE/.graphify-backend"
run_fence allow yes "$HIMMEL" "case-differing agreeing file backends -> not a conflict -> allow" \
    "graphify update $STAGED_BE/copy.md $STAGED_BE_CASE/copy.md"

echo "== HIMMEL-881: ledger records declared_backend_source (env vs file) =="

# file-declared backend -> ledger carries declared_backend_source:"file"
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify update $STAGED_BE/copy.md" ) >/dev/null 2>&1
if grep -q '"declared_backend_source":"file"' "$LEDGER" 2>/dev/null; then
    pass "ledger content: declared_backend_source=file for file-declared backend"
else
    fail "ledger content declared_backend_source=file: got $(cat "$LEDGER" 2>/dev/null)"
fi

# env-declared backend -> ledger carries declared_backend_source:"env"
# (claude-cli is the sanctioned luna-personal backend, HIMMEL-2101 — kimi/
# moonshot's allow+log lane is retired; an allow line must exist to carry the
# source field, so a denying provider would make this vacuous)
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV GRAPHIFY_DECLARED_BACKEND=claude-cli "$BASH_BIN" "$FENCE" "graphify update $LUNA/journal-2026.md" ) >/dev/null 2>&1
if grep -q '"declared_backend_source":"env"' "$LEDGER" 2>/dev/null; then
    pass "ledger content: declared_backend_source=env for env-declared backend"
else
    fail "ledger content declared_backend_source=env: got $(cat "$LEDGER" 2>/dev/null)"
fi

# real --backend flag (no declaration involved) -> no declared_backend_source field.
# Vehicle: $STAGED (a corpus-marker-declared luna-personal dir, declared=1 --
# always ledgers) + an explicit --backend claude-cli flag, so a real allow
# ledger line exists to grep. HIMMEL-2101: kimi/moonshot's native, non-declared
# allow+log lane is retired, so a plain --backend flag on a REAL (non-marker)
# root no longer produces any ledger line at all, which would make this
# negative grep pass vacuously.
rm -f "$LEDGER"
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify update $STAGED/copy.md --backend claude-cli" ) >/dev/null 2>&1
if ! grep -q 'declared_backend_source' "$LEDGER" 2>/dev/null; then
    pass "ledger content: no declared_backend_source field for an explicit --backend flag"
else
    fail "ledger content unexpected declared_backend_source: got $(cat "$LEDGER" 2>/dev/null)"
fi

# --- HIMMEL-1084: direct-eval mode (non-hook callers) ------------------------
# `graphify-fence.sh --eval <corpus> <backend> <abs-target> <tool>` (exactly 5
# args) is the contract a scheduled/non-agent graphify caller uses instead of a
# private copy of this fence's matrix eval + ledger. The hook passes exactly
# ONE arg, so it can never enter this mode. The caller-asserted corpus is a
# DECLARATION (ledgered on every allow, like a `.graphify-corpus` marker) and
# can only be TIGHTENED by the target's own path classification.

# E1 unverified endpoint -> deny before any egress (RED today: rc=0, not a graphify cmd)
rm -f "$LEDGER"
# shellcheck disable=SC2086
env $CLEAN_ENV ANTHROPIC_BASE_URL=https://evil.example/v1 "$BASH_BIN" "$FENCE" --eval luna-clippings claude-cli "$NOWHERE" refresh-graph-map >/dev/null 2>"$WS/eval.err"; rc=$?
if [ "$rc" -eq 2 ] && grepq "$(cat "$WS/eval.err")" 'unverified endpoint' && [ ! -s "$LEDGER" ]; then
    pass "HIMMEL-1084 E1 --eval: unratified ANTHROPIC_BASE_URL denied, no ledger line"
else
    fail "HIMMEL-1084 E1 --eval unratified endpoint: rc=$rc err=$(cat "$WS/eval.err")"
fi

# E2 asserted clippings x claude-cli (anthropic) -> allow + declared ledger line carrying the caller's tool label
rm -f "$LEDGER"
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval luna-clippings claude-cli "$NOWHERE" refresh-graph-map >/dev/null 2>"$WS/eval.err"; rc=$?
if [ "$rc" -eq 0 ] && grep -q '"corpus":"luna-clippings","backend":"claude-cli","provider":"anthropic","verdict":"allow","purpose":"extraction","tool":"refresh-graph-map","declared":true' "$LEDGER" 2>/dev/null; then
    pass "HIMMEL-1084 E2 --eval: clippings x anthropic allowed + ledgered with tool=refresh-graph-map"
else
    fail "HIMMEL-1084 E2 --eval allow+ledger: rc=$rc err=$(cat "$WS/eval.err") ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# E3 path-derived salus tightens a laxer asserted class -> hard deny
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval himmel-code claude-cli "$SALUS/notes" refresh-graph-map >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "HIMMEL-1084 E3 --eval: path-derived salus beats asserted himmel-code"; else fail "HIMMEL-1084 E3 --eval salus tighten: rc=$rc"; fi

# E4 luna-clippings x zai-glm: matrix explicit deny, the retired opt-in cannot open it
# shellcheck disable=SC2086
env $CLEAN_ENV GRAPHIFY_CLIPPINGS_GLM_OK=1 ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic "$BASH_BIN" "$FENCE" --eval luna-clippings claude "$NOWHERE" refresh-graph-map >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then pass "HIMMEL-1084 E4 --eval: clippings x zai-glm denied even with GRAPHIFY_CLIPPINGS_GLM_OK=1"; else fail "HIMMEL-1084 E4 --eval clippings zai-glm: rc=$rc"; fi

# E5 himmel-code x zai-glm (the --backend glm remap shape) -> allow + ledger names zai-glm
rm -f "$LEDGER"
# shellcheck disable=SC2086
env $CLEAN_ENV ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic "$BASH_BIN" "$FENCE" --eval himmel-code claude "$NOWHERE" refresh-graph-map >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '"provider":"zai-glm","verdict":"allow","purpose":"extraction","tool":"refresh-graph-map"' "$LEDGER" 2>/dev/null; then
    pass "HIMMEL-1084 E5 --eval: himmel-code x zai-glm allowed + ledgered"
else
    fail "HIMMEL-1084 E5 --eval himmel-code zai-glm: rc=$rc ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# E6 salus x local-ollama: conditional -> denied without the opt-in, allowed + ledgered with it
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval salus ollama "$SALUS/notes" refresh-graph-map >/dev/null 2>&1; rc_a=$?
rm -f "$LEDGER"
# shellcheck disable=SC2086
env $CLEAN_ENV GRAPHIFY_SALUS_LOCAL_OK=1 "$BASH_BIN" "$FENCE" --eval salus ollama "$SALUS/notes" refresh-graph-map >/dev/null 2>&1; rc_b=$?
if [ "$rc_a" -eq 2 ] && [ "$rc_b" -eq 0 ] && grep -q '"verdict":"conditional","purpose":"extraction","tool":"refresh-graph-map"' "$LEDGER" 2>/dev/null; then
    pass "HIMMEL-1084 E6 --eval: salus x local-ollama needs GRAPHIFY_SALUS_LOCAL_OK=1"
else
    fail "HIMMEL-1084 E6 --eval salus conditional: rc_a=$rc_a rc_b=$rc_b ledger=$(cat "$LEDGER" 2>/dev/null)"
fi

# E7 malformed --eval arguments fail closed (unknown corpus, unsafe tool label/backend, relative target)
e7=0
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval not-a-corpus claude-cli "$NOWHERE" refresh-graph-map >/dev/null 2>&1; [ "$?" -eq 2 ] || e7=1
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval himmel-code claude-cli "$NOWHERE" 'bad"tool' >/dev/null 2>&1; [ "$?" -eq 2 ] || e7=1
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval himmel-code 'claude"x' "$NOWHERE" refresh-graph-map >/dev/null 2>&1; [ "$?" -eq 2 ] || e7=1
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval himmel-code claude-cli rel/path refresh-graph-map >/dev/null 2>&1; [ "$?" -eq 2 ] || e7=1
if [ "$e7" -eq 0 ]; then pass "HIMMEL-1084 E7 --eval: malformed arguments deny"; else fail "HIMMEL-1084 E7 --eval malformed arguments did not all deny"; fi

# E8 the hook path passes ONE arg and cannot reach --eval: a hook-mode ledger line keeps tool=graphify
rm -f "$LEDGER"
# shellcheck disable=SC2086
( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "graphify update $STAGED/copy.md --backend claude-cli" ) >/dev/null 2>&1
if grep -q '"tool":"graphify"' "$LEDGER" 2>/dev/null && ! grep -q '"tool":"refresh-graph-map"' "$LEDGER" 2>/dev/null \
   && ! grep -q '"purpose"' "$LEDGER" 2>/dev/null; then
    pass "HIMMEL-1084 E8 hook-mode ledger keeps tool=graphify (no purpose field)"
else
    fail "HIMMEL-1084 E8 hook-mode ledger tool: $(cat "$LEDGER" 2>/dev/null)"
fi

# E9 (CR codex-1) --eval with the wrong operand count denies instead of falling
# through to hook-mode parsing (where a bare "--eval" is not a graphify clause
# and would exit 0 - a false allow for a malformed preflight)
e9=0
rm -f "$LEDGER"
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval >/dev/null 2>&1; [ "$?" -eq 2 ] || e9=1
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval himmel-code claude-cli "$NOWHERE" >/dev/null 2>&1; [ "$?" -eq 2 ] || e9=1
# shellcheck disable=SC2086
env $CLEAN_ENV "$BASH_BIN" "$FENCE" --eval himmel-code claude-cli "$NOWHERE" refresh-graph-map extra >/dev/null 2>&1; [ "$?" -eq 2 ] || e9=1
[ ! -e "$LEDGER" ] || e9=1
if [ "$e9" -eq 0 ]; then pass "HIMMEL-1084 E9 --eval: wrong operand count denies, no ledger"; else fail "HIMMEL-1084 E9 --eval wrong operand count did not all deny"; fi

echo "== HIMMEL-3641: env -C/--chdir, sudo -D/--chdir directory-change wrappers (PHI fail-closed) =="

# (C1) env -C DIR (separate token) -> deny (chdir into salus, relative target)
run_fence deny no "$HIMMEL" "env -C DIR salus (relative target) -> deny" \
    "env -C $SALUS graphify update notes/patient.md --backend glm"

# (C2) env -CDIR (attached, single token) -> deny
run_fence deny no "$HIMMEL" "env -CDIR salus -> deny (attached)" \
    "env -C$SALUS graphify update notes/patient.md --backend glm"

# (C3) env --chdir=DIR (attached value) -> deny
run_fence deny no "$HIMMEL" "env --chdir=DIR salus -> deny (attached)" \
    "env --chdir=$SALUS graphify update notes/patient.md --backend glm"

# (C4) env --chdir DIR (separate token) -> deny
run_fence deny no "$HIMMEL" "env --chdir DIR salus -> deny" \
    "env --chdir $SALUS graphify update notes/patient.md --backend glm"

# (C5) env --ch DIR (unambiguous abbreviation) -> deny
run_fence deny no "$HIMMEL" "env --ch DIR salus -> deny (abbrev)" \
    "env --ch $SALUS graphify update notes/patient.md --backend glm"

# (C6) env --chd DIR (deeper unambiguous abbreviation) -> deny
run_fence deny no "$HIMMEL" "env --chd DIR salus -> deny (abbrev)" \
    "env --chd $SALUS graphify update notes/patient.md --backend glm"

# (C7) sudo -D DIR (separate token) -> deny
run_fence deny no "$HIMMEL" "sudo -D DIR salus -> deny" \
    "sudo -D $SALUS graphify update notes/patient.md --backend glm"

# (C8) sudo -DDIR (attached, single token) -> deny
run_fence deny no "$HIMMEL" "sudo -DDIR salus -> deny (attached)" \
    "sudo -D$SALUS graphify update notes/patient.md --backend glm"

# (C9) sudo --chdir=DIR (attached value) -> deny
run_fence deny no "$HIMMEL" "sudo --chdir=DIR salus -> deny (attached)" \
    "sudo --chdir=$SALUS graphify update notes/patient.md --backend glm"

# (C10) sudo -D combined with an earlier sudo flag -> deny
run_fence deny no "$HIMMEL" "sudo -u root -D DIR salus -> deny (combined, -D after -u)" \
    "sudo -u root -D $SALUS graphify update notes/patient.md --backend glm"

# (C11) sudo -D combined with a later sudo flag -> deny
run_fence deny no "$HIMMEL" "sudo -D DIR -H salus -> deny (combined, -D before -H)" \
    "sudo -D $SALUS -H graphify update notes/patient.md --backend glm"

# (C12) fail-closed: env --chdir= with a missing/empty directory argument
# (attached form, so graphify is still reachable right after) -> deny
run_fence deny no "$HIMMEL" "env --chdir= (empty arg) -> deny (fail-closed)" \
    "env --chdir= graphify update notes/patient.md --backend glm"

# (C13) fail-closed: sudo -D with an unresolvable (unexpanded variable)
# directory argument -> deny. This fence does not run a shell, so it cannot
# know what \$UNKNOWN_DIR expands to.
run_fence deny no "$HIMMEL" "sudo -D \$UNKNOWN_DIR (unresolvable arg) -> deny (fail-closed)" \
    "sudo -D \$UNKNOWN_DIR graphify update notes/patient.md --backend glm"

# (C14) env -C into a non-PHI corpus still allows (no over-deny regression)
run_fence allow no "$HIMMEL" "env -C DIR himmel-code -> allow (non-PHI)" \
    "env -C $HIMMEL graphify update scripts/thing.sh"

# (C15) sudo -D into a non-PHI corpus still allows (no over-deny regression)
run_fence allow no "$HIMMEL" "sudo -D DIR himmel-code -> allow (non-PHI)" \
    "sudo -D $HIMMEL graphify update scripts/thing.sh"

echo "== HIMMEL-3641 J1290O fix round: F1 double-chdir, F2 raw-token \$/\` check, F3 tilde, F4 bundled short opts =="

# (C16) F1: env -C salus -C himmel stacked in ONE invocation -> deny
# unconditionally, even though the SECOND (real last-wins) target is
# itself non-PHI - old code applies each -C in sequence and lands on
# himmel (allow); this must fail closed on the STACK, not on the result.
run_fence deny no "$HIMMEL" "env -C salus -C himmel stacked in one env -> deny (F1)" \
    "env -C $SALUS -C $HIMMEL graphify update notes/patient.md --backend glm"

# (C17) F1: env --chdir=salus --chdir=himmel stacked (long form) -> deny
run_fence deny no "$HIMMEL" "env --chdir=salus --chdir=himmel stacked -> deny (F1)" \
    "env --chdir=$SALUS --chdir=$HIMMEL graphify update notes/patient.md --backend glm"

# (C18) F1: the J1290O repro - env -C<himmel> -C<relative sibling salus>,
# run from the shared parent dir. Old code anchors the second RELATIVE -C
# against the already-mutated TOOL_CWD (<himmel>/salusvault, non-PHI ->
# allow); real env resolves the LAST -C against the ORIGINAL cwd (real
# salus). Fail closed on the stack instead of modelling that.
run_fence deny no "$HIMMEL" "env -C<himmel> -Csalusvault -> deny (F1)" \
    "env -C $HIMMEL -Csalusvault graphify update notes/patient.md --backend glm"

# (C18b) same repro, run from the actual shared parent dir as cwd
run_fence deny no "$WS" "env -C<himmel> -Csalusvault from parent -> deny (F1, real parent cwd)" \
    "env -C $HIMMEL -Csalusvault graphify update notes/patient.md --backend glm"

# (C19) F1, no-path-arg form: cwd is really salus; env -C<himmel> -C.
# stacked. Old code anchors the trailing "." to the mutated TOOL_CWD
# (<himmel>, non-PHI -> allow with no explicit path argument at all); real
# env's last -C "." resolves against the ORIGINAL cwd (salus).
run_fence deny no "$SALUS" "env -C<himmel> -C. (no-path-arg) from salus -> deny (F1)" \
    "env -C $HIMMEL -C . graphify --backend glm"

# (C20) F1: sudo -D<himmel> -D<relative sibling salus>, run from the shared
# parent dir - the sudo twin of C18.
run_fence deny no "$WS" "sudo -D<himmel> -Dsalusvault from parent -> deny (F1)" \
    "sudo -D $HIMMEL -Dsalusvault graphify update notes/patient.md --backend glm"

# (C21) F2: env -C\$VAR (attached, unexpanded substitution) -> deny.
# _gf_apply_chdir's \$/\` check must see the RAW token, not the
# _strip_cmd'd one (which deletes \$ before the check can ever fire).
run_fence deny no "$HIMMEL" "env -C\$UNKNOWN_DIR attached -> deny (F2)" \
    "env -C\$UNKNOWN_DIR graphify update notes/patient.md --backend glm"

# (C22) F2: env --chdir=\$VAR (attached long form) -> deny
run_fence deny no "$HIMMEL" "env --chdir=\$UNKNOWN_DIR attached -> deny (F2)" \
    "env --chdir=\$UNKNOWN_DIR graphify update notes/patient.md --backend glm"

# (C23) F2: sudo -D\$VAR (attached) -> deny
run_fence deny no "$HIMMEL" "sudo -D\$UNKNOWN_DIR attached -> deny (F2)" \
    "sudo -D\$UNKNOWN_DIR graphify update notes/patient.md --backend glm"

# (C24) F2: sudo --chdir=\$VAR (attached long form) -> deny
run_fence deny no "$HIMMEL" "sudo --chdir=\$UNKNOWN_DIR attached -> deny (F2)" \
    "sudo --chdir=\$UNKNOWN_DIR graphify update notes/patient.md --backend glm"

# (C25) F3: env -C ~someuser (tilde-user form, not bare ~ or ~/...) -> deny.
# _abs only expands a bare ~ or ~/...; a ~user form really expands to that
# user's home, which this fence cannot know lexically.
run_fence deny no "$HIMMEL" "env -C ~someuser/x (tilde-user) -> deny (F3)" \
    "env -C ~someuser/x graphify update notes/patient.md --backend glm"

# (C26) F3: env -C ~- (tilde-OLDPWD form) -> deny
run_fence deny no "$HIMMEL" "env -C ~- (tilde-OLDPWD) -> deny (F3)" \
    "env -C ~- graphify update notes/patient.md --backend glm"

# (C27) F4: env -iC DIR (bundled short opt containing -C's letter,
# separate value) -> deny. Old code falls to the generic -*) arm, which
# consumes only the "-iC" token; the DIR value is then misaligned into
# command position and graphify past it is never reached (silent allow).
run_fence deny no "$HIMMEL" "env -iC salus (bundled) -> deny (F4)" \
    "env -iC $SALUS graphify update notes/patient.md --backend glm"

# (C28) F4: env -vC DIR (bundled, -v + -C) -> deny
run_fence deny no "$HIMMEL" "env -vC salus (bundled) -> deny (F4)" \
    "env -vC $SALUS graphify update notes/patient.md --backend glm"

# (C29) F4: sudo -nD DIR (bundled short opt containing -D's letter) -> deny
run_fence deny no "$HIMMEL" "sudo -nD salus (bundled) -> deny (F4)" \
    "sudo -nD $SALUS graphify update notes/patient.md --backend glm"

# (C30) F4: sudo -EHD DIR (bundled, -E -H + -D) -> deny
run_fence deny no "$HIMMEL" "sudo -EHD salus (bundled) -> deny (F4)" \
    "sudo -EHD $SALUS graphify update notes/patient.md --backend glm"

# (C31) control: env -C DIR with NO graphify anywhere in the clause still
# allows (the F1-F4 fail-closed additions must never over-deny a command
# that never touches graphify at all).
run_fence allow no "$HIMMEL" "env -C DIR make (no graphify) -> allow (control)" \
    "env -C $NOWHERE make"

# (C32) control: the bundled-short-opt scan-ahead (F4) must also leave a
# graphify-free bundled command alone.
run_fence allow no "$HIMMEL" "env -iC DIR make (bundled, no graphify) -> allow (control)" \
    "env -iC $NOWHERE make"

echo "== HIMMEL-3641 codex-1 (J1290R): --* long options checked before the -*C*/-*D* bundled-short-opt glob =="

# (C33) codex-1: env --chdir=DIR where DIR contains an uppercase C must be
# handled as the long option it is, not misrouted into the F4 bundled-short-
# opt scan just because the token contains "-C" as a substring. Non-PHI
# target -> allow (this DENYed before the fix, on the F4 bundled-opt
# message, even though env --chdir= is fully resolvable here).
run_fence allow no "$HIMMEL" "env --chdir=DIR (uppercase-C path) non-PHI -> allow (codex-1)" \
    "env --chdir=$HIMMEL_UPPER graphify update $HIMMEL_UPPER/thing.sh"

# (C34) codex-1: env --unset=VAR where VAR's name contains an uppercase C
# (CLAUDE_CODE_USE_BEDROCK) must also stay on the --* long-option arm; it
# never chdirs at all, so a non-PHI target must allow.
run_fence allow no "$HIMMEL" "env --unset=CLAUDE_CODE_USE_BEDROCK non-PHI -> allow (codex-1)" \
    "env --unset=CLAUDE_CODE_USE_BEDROCK graphify update $HIMMEL/scripts/thing.sh"

# (C35) codex-1 sudo twin: sudo --chdir=DIR where DIR contains an uppercase D
# must stay on the --* long-option arm, not the F4 bundled-opt scan.
mkdir -p "$HIMMEL/DataDir"
: > "$HIMMEL/DataDir/thing.sh"
run_fence allow no "$HIMMEL" "sudo --chdir=DIR (uppercase-D path) non-PHI -> allow (codex-1)" \
    "sudo --chdir=$HIMMEL/DataDir graphify update $HIMMEL/DataDir/thing.sh"

# (C36) codex-1 regression control: env --chdir=DIR into SALUS (PHI), where
# the path also contains an uppercase C, must still deny - on the real
# chdir-into-PHI reason, not the (now bypassed) bundled-opt reason.
run_fence deny no "$HIMMEL" "env --chdir=DIR (uppercase-C path) into salus -> still deny (codex-1 control)" \
    "env --chdir=$SALUS graphify update notes/patient.md --backend glm"

# (C37) codex-1 regression control: a TRUE bundled short option containing
# -C's letter must still fail closed (F4 unchanged for real bundled opts).
run_fence deny no "$HIMMEL" "env -iC DIR salus (true bundled) -> still deny (codex-1 control)" \
    "env -iC $SALUS graphify update notes/patient.md --backend glm"

echo "== HIMMEL-3641 J1290R: R1 unquoted-vs-shell tilde, R2 raw/stripped mismatch + env -S, R3 backtick-wrapped value =="

# (R1a) R1: env -C~/x (attached tilde) run from a real salus cwd, relative
# target. In bash/zsh a `~` is ONLY tilde-expanded when it is the FIRST
# character of a whole word - attached to -C it is never shell-expanded and
# stays the literal two characters `~/x`, so the DIR env would really try to
# chdir into is a literal (almost certainly nonexistent) subdirectory, never
# $HOME/x. The old _abs()-based fix expanded it to $HOME/x unconditionally,
# so the real cwd (salus, PHI) was replaced by a $HOME-relative one that
# looks non-PHI -> a new false ALLOW. Fail closed instead: any chdir
# argument containing `~` is unresolvable now, full stop.
run_fence deny no "$SALUS" "env -C~/x (attached tilde) from salus -> deny (R1, fail-closed)" \
    "env -C~/x graphify update notes/patient.md --backend glm" "HOME=$HIMMEL"

# (R1b) R1: env -C"~/x" (attached AND quoted) - same non-expansion in real
# bash/zsh, same old bug (_strip_wrap peeled the quotes, then _abs still
# expanded the now-bare ~/x to $HOME/x).
run_fence deny no "$SALUS" "env -C\"~/x\" (attached+quoted tilde) from salus -> deny (R1, fail-closed)" \
    "env -C\"~/x\" graphify update notes/patient.md --backend glm" "HOME=$HIMMEL"

# (R2a) R2: env '-C'<salus> - the flag is quoted, the value is glued on with
# no space, so the RAW token does not literally start with `-C` and the old
# `${toks[$i]#-C}` prefix-strip was a no-op; the OLD code still matched the
# _stripped_ form against the `-C?*` glob and ran `_abs()` on the untouched
# (quote-prefixed) raw value, which is not absolute, so it resolved as a
# garbage path under the real (non-PHI) cwd - silently misresolving instead
# of failing closed. Real shell semantics: quoted+unquoted fragments with no
# space between them concatenate into ONE argument, so this really is `-C
# <salus>` and would have chdir'd into PHI.
run_fence deny no "$HIMMEL" "env '-C'<salus> (quoted flag, glued value) -> deny (R2)" \
    "env '-C'$SALUS graphify update notes/patient.md --backend glm"

# (R2b) R2 twin: env "-C<salus>" - the WHOLE flag+value is one double-quoted
# token. Same raw-vs-stripped mismatch, same old misresolution.
run_fence deny no "$HIMMEL" "env \"-C<salus>\" (whole token double-quoted) -> deny (R2)" \
    "env \"-C$SALUS\" graphify update notes/patient.md --backend glm"

# (R2c) R2: env -\C<salus> (backslash before the C) - same mismatch, this
# time via a backslash rather than a quote character.
run_fence deny no "$HIMMEL" "env -\\C<salus> (backslash-escaped) -> deny (R2)" \
    "env -\\C$SALUS graphify update notes/patient.md --backend glm"

# (R2d) R2 sudo twin: sudo '-D'<salus>, same quoted-flag/glued-value
# mismatch as R2a.
run_fence deny no "$HIMMEL" "sudo '-D'<salus> (quoted flag, glued value) -> deny (R2)" \
    "sudo '-D'$SALUS graphify update notes/patient.md --backend glm"

# (R2e) R2: env -S/--split-string re-splits its value into a brand new argv
# at RUNTIME - a shebang-line mechanism this fence cannot statically
# evaluate. The old code had NO handling for -S at all: it fell to the
# generic `-*)` "skip one token" arm, which then misaligned the walk onto the
# split-string value's own FIRST word (here a decoy, "true") - that word is
# neither a recognised wrapper nor `graphify`, so the whole positional walk
# stopped right there and classify_clause returned without ever calling
# deny() OR apply_verdict(): the invocation allowed SILENTLY, never even
# noticing graphify was invoked one word later in the same value, even
# though the real cwd here is salus (PHI) and the real env -S argv really
# does end in `graphify update notes/patient.md ...`.
run_fence deny no "$SALUS" "env -S \"true graphify ...\" (hidden invocation) from salus -> deny (R2)" \
    "env -S \"true graphify update notes/patient.md --backend glm\""

# (R3) env -C\`pwd\` - a whole-token wrapped backtick chdir value. The old
# _gf_apply_chdir called _strip_wrap FIRST, which peeled the matching pair of
# backticks off BEFORE the $/backtick unresolvable-substitution check ever
# ran, leaving the plain literal string "pwd" - which _abs() then resolved as
# an ordinary (nonexistent) relative subdirectory instead of recognising an
# unresolvable command substitution and failing closed. Real shell semantics:
# `` `pwd` `` evaluates to whatever the real cwd is AT RUNTIME - something
# this fence can never know ahead of time - so it must deny regardless of
# where it happens to land, not silently resolve to a literal "pwd" folder.
run_fence deny no "$HIMMEL" "env -C\`pwd\` (backtick-wrapped value) -> deny (R3, fail-closed)" \
    "env -C\`pwd\` graphify update notes/patient.md --backend glm"

# (R1 consequence) documentation row, not a fix target: J1290R rated this an
# acceptable over-deny, so no code change was made for it. Before this round,
# an UNQUOTED, SEPARATE-token `~/x` (real bash *would* shell-expand this one,
# since the tilde is the first character of its own word) was correctly
# allowed via $HOME/x. The "stop modelling shell expansion" fix in this round
# denies ALL `~` forms without exception, so this previously-correct case now
# also fails closed - a deliberate, accepted trade documented here so a
# future reader does not mistake it for a regression. HIMMEL-3641 J1290S M2:
# this row used to be tagged "(R4, ...)" - J1290R's own R1-R3 findings never
# included a fourth item (its actual fourth contribution was the codex-1
# --*-vs--*C*/-*D* ordering fix above, not this one), so the tag is corrected
# to what it actually is: a consequence of R1 (the unquoted-tilde finding).
run_fence deny no "$HIMMEL" "env -C ~/x (unquoted separate-token tilde, previously-correct case) -> deny (R1 consequence, accepted over-deny)" \
    "env -C ~/x graphify update notes/patient.md --backend glm" "HOME=$HIMMEL"

# HIMMEL-3641 J1290S S1: a separate-token chdir DIR argument that the
# tokenizer splits across multiple raw tokens ($(...) command substitution,
# a backtick form, or a double-quoted "$(...)") sets
# _GF_CHDIR_DENY_REASON inside _gf_apply_chdir, but the walk used to step
# past it with i+=2 regardless, landing on the substitution's leftover tail
# token, misclassifying it as the wrapped command, and never reaching
# graphify's own command-position check - so the deny reason was recorded
# but never enforced. Net effect: a real chdir into salus (PHI) via one of
# these forms silently ALLOWed. Same defect, applies to all 4 separate-token
# DIR arms (env -C, env --chdir, sudo -D, sudo --chdir).
run_fence deny no "$HIMMEL" "env -C \$(echo salus) (tokenizer-split \$(...) value) -> deny (S1)" \
    "env -C \$(echo $SALUS) graphify update notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "env -C \`echo salus\` (tokenizer-split backtick value) -> deny (S1)" \
    "env -C \`echo $SALUS\` graphify update notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "env -C \"\$(echo salus)\" (tokenizer-split quoted \$(...) value) -> deny (S1)" \
    "env -C \"\$(echo $SALUS)\" graphify update notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "env --chdir \$(echo salus) (long-option twin) -> deny (S1)" \
    "env --chdir \$(echo $SALUS) graphify update notes/patient.md --backend glm"
run_fence deny no "$HIMMEL" "sudo -D \$(echo salus) (sudo twin) -> deny (S1)" \
    "sudo -D \$(echo $SALUS) graphify update notes/patient.md --backend glm"

# HIMMEL-3641 J1290S codex-1 (round-5 critic panel): the raw-vs-stripped
# mismatch guard (added in the same R2 round as env -S handling) only scans
# LATER tokens for a literal "graphify" via _gf_deny_if_graphify_follows -
# but env -S"graphify ..." (the flag glued to its double-quoted value, no
# space) puts the literal word "graphify" INSIDE the very token that
# mismatched (_strip_cmd turns -S"graphify into -Sgraphify by removing the
# quote), so the later-tokens-only scan never sees it and the walk fell
# through untouched - even though env -S's split-string argv really does
# invoke graphify. sudo has no -S/--split-string, so only env's mismatch
# guard is exposed to this shape.
run_fence deny no "$SALUS" "env -S\"graphify ...\" (glued double-quoted value) from salus -> deny (codex-1)" \
    "env -S\"graphify update notes/patient.md --backend glm\""

# HIMMEL-3641 round-6 codex-1 (critic panel, distinct from the round-5
# finding above): _gf_deny_if_graphify_follows itself only exact-matched
# "graphify"/"*/graphify" on later tokens, so an unresolvable env -C
# argument's fail-closed scan-ahead missed a LATER token that carries
# graphify glued into another flag's value (env -S"graphify ...") instead
# of as its own bare token - the scan finished with no match and the
# caller returned un-denied.
run_fence deny no "$SALUS" "env -C \$(...) unresolvable, later -S\"graphify ...\" glued token -> deny (round-6 codex-1)" \
    "env -C \$(echo /nonexistent) -S\"graphify update notes/patient.md --backend glm\""

# HIMMEL-3641 round-7 codex-1 (critic panel) + class sweep: every OTHER
# fail-closed "scan the rest of the clause for graphify and deny" arm had
# the same exact-match bug as the two fixed above - a later token carrying
# graphify GLUED into another flag's value (env -S"graphify ...") was
# never matched. round-7's own citation is the env -*C* bundled-short-opt
# arm; the sudo -*D* mirror, xargs/find -exec's deferred-target scan, and
# quiet-run.sh's unparsable-label tail scan share the identical shape and
# are swept in the same fix per CLAUDE.md's "sweep the whole class" rule.
run_fence deny no "$HIMMEL" "env -iC DIR (bundled), later -S\"graphify ...\" glued token -> deny (round-7 codex-1)" \
    "env -iC /nonexistent -S\"graphify update notes/patient.md --backend glm\""
run_fence deny no "$HIMMEL" "sudo -nD DIR (bundled), later env -S\"graphify ...\" glued token -> deny (round-7 sweep)" \
    "sudo -nD /nonexistent env -S\"graphify update notes/patient.md --backend glm\""
run_fence deny no "$HIMMEL" "xargs env -S\"graphify ...\" glued token -> deny (round-7 sweep)" \
    "xargs env -S\"graphify update notes/patient.md --backend glm\""
run_fence deny no "$HIMMEL" "find -exec env -S\"graphify ...\" glued token -> deny (round-7 sweep)" \
    "find . -exec env -S\"graphify update notes/patient.md --backend glm\""
run_fence deny no "$HIMMEL" "quiet-run.sh unparsable label, tail env -S\"graphify ...\" glued token -> deny (round-7 sweep)" \
    "bash scripts/quiet-run.sh \"a -- b\" -- env -S\"graphify update notes/patient.md --backend glm\""

echo "== HIMMEL-3683: a clause separator INSIDE a command substitution must not =="
echo "== split the substitution across two false top-level clauses =="

# (X1) env -C \$(cd ..; pwd)/salus - the original repro: a ; inside \$(...)
# used to become a clause boundary, so clause 1 was "env -C \$(cd .." and
# clause 2 "pwd)/salus graphify ..." and the real chdir target (salus) was
# never classified.
run_fence deny no "$HIMMEL" "env -C \$(cd ..; pwd)/salus (; inside \$(...)) -> deny (X1)" \
    "env -C \$(cd ..; pwd)/salus graphify update notes/patient.md --backend glm"
# (X2) same shape via echo \$PWD/salus instead of pwd.
run_fence deny no "$HIMMEL" "env -C \$(cd ..; echo \$PWD/salus) -> deny (X2)" \
    "env -C \$(cd ..; echo \$PWD/salus) graphify update notes/patient.md --backend glm"
# (X3) sudo -D twin of X1.
run_fence deny no "$HIMMEL" "sudo -D \$(cd ..; pwd)/salus (; inside \$(...)) -> deny (X3)" \
    "sudo -D \$(cd ..; pwd)/salus graphify update notes/patient.md --backend glm"
# (X4) a leading no-op clause (true;) ahead of the real value inside \$(...).
run_fence deny no "$HIMMEL" "env -C \$(true; echo salus) -> deny (X4)" \
    "env -C \$(true; echo $SALUS) graphify update notes/patient.md --backend glm"
# (X5) && inside \$(...) - collapses to the same newline split as ; and |.
run_fence deny no "$HIMMEL" "env -C \$(true && echo salus) -> deny (X5)" \
    "env -C \$(true && echo $SALUS) graphify update notes/patient.md --backend glm"
# (X6) a pipe AND a ; both inside the same \$(...).
run_fence deny no "$HIMMEL" "env -C \$(true | cat; echo salus) -> deny (X6)" \
    "env -C \$(true | cat; echo $SALUS) graphify update notes/patient.md --backend glm"
# (X7) backtick form of X4, not \$(...).
run_fence deny no "$HIMMEL" "env -C \`true; echo salus\` (; inside backticks) -> deny (X7)" \
    "env -C \`true; echo $SALUS\` graphify update notes/patient.md --backend glm"
# (X8) J1290S w06 shape: cd .. then a bare relative echo (no absolute path).
run_fence deny no "$HIMMEL" "env -C \$(cd ..; echo salus) relative echo -> deny (X8, w06)" \
    "env -C \$(cd ..; echo salus) graphify update notes/patient.md --backend glm"

# Controls: clause-splitting for every OTHER shape must stay exactly as before.
# (X9) no substitution at all -> unaffected.
run_fence allow no "$HIMMEL" "no substitution, himmel-code x glm -> allow (X9 control)" \
    "graphify update $HIMMEL/scripts/thing.sh --backend glm"
# (X10) a substitution with NO separator inside -> judged exactly as at base
# (still denied, but via the pre-existing unresolved-chdir reason, not the
# new hidden-separator one).
# shellcheck disable=SC2086 # CLEAN_ENV is an intentional word-split flag list
out=$( cd "$HIMMEL" && env $CLEAN_ENV "$BASH_BIN" "$FENCE" "env -C \$(pwd) graphify update notes/patient.md --backend glm" 2>&1 ); rc=$?
hit=$(printf '%s' "$out" | grep -F 'clause separator')
if [ "$rc" -eq 2 ] && [ -z "$hit" ]; then
    pass "env -C \$(pwd) (no separator inside) -> deny via pre-existing chdir reason, unchanged (X10 control)"
else
    fail "env -C \$(pwd) (no separator inside) unchanged (X10 control) (rc=$rc) out=$out"
fi
# (X11) a REAL top-level separator (not inside any substitution) -> unaffected.
run_fence allow no "$HIMMEL" "echo a; graphify update . (real top-level ;, not inside \$(...)) -> allow (X11 control)" \
    "echo a; graphify update . --backend glm"

if [ "$failures" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
else
    echo "FAIL: $failures case(s) failed"
    exit 1
fi
