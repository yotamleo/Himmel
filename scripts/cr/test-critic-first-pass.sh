#!/usr/bin/env bash
# scripts/cr/test-critic-first-pass.sh — TDD tests for critic-first-pass.sh (HIMMEL-415).
# Deterministic: HERMES_PY is set to a bash shim that ignores its args and
# prints canned output — no live hermes, no network.
#
# Stub mechanism: invoke.sh calls "$py" -c '<snippet>'. The shim (py.sh)
# ignores all argv (including the -c snippet) and execs python with stub.py,
# which prints canned contract-shaped output. The -c snippet never runs so
# 'from hermes_cli.main import main' is never attempted.
# Bash 3.2 safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFP="$HERE/critic-first-pass.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check(){ if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }

# Stub python: prints a canned, contract-shaped review with a valid citation.
# The citation [foo.sh:3] is within the hunk range of the DIFF below (+1,2 -> lines 1-2...
# actually diff @@ -1,2 +1,3 @@ means new-file lines 1-3, so line 3 is in range).
cat > "$tmp/stub.py" <<'PY'
import os
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: off-by-one in loop bound [foo.sh:3]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY

# invoke.sh execs: "$py" -c '<snippet reading HERMES_PROMPT_FILE>'. The snippet
# imports hermes_cli; our stub must satisfy that call. The shim ignores -c and
# all other argv, then runs stub.py via plain python — hermes_cli import never
# attempted. This is the proven path: shim ignores argv, python runs stub.py.
cat > "$tmp/py.sh" <<PY
#!/usr/bin/env bash
exec python3 "$tmp/stub.py"
PY
chmod +x "$tmp/py.sh"

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,3 @@
 line
+for i in 1 2 3; do :; done
+another line'

# --- test: derived slug in header + ID ---
out="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py.sh" bash "$CFP" --model qwen/qwen3-coder-480b-a35b-instruct 2>/dev/null)"
# slug derives to: qwen3coder480ba3 (last segment after /, lowercased, non-alnum stripped, 16 chars)
check "header carries slug" "$(printf '%s' "$out" | grep -c '^# qwen3coder480ba3 First-Pass Review')" "1"
check "finding renumbered to slug-1" "$(printf '%s' "$out" | grep -c '\[qwen3coder480ba3-1\]')" "1"

# --- test: --slug override ---
cat > "$tmp/stub.py" <<'PY'
import os
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: off-by-one in loop bound [foo.sh:3]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
out2="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug qwen3coder 2>/dev/null)"
check "explicit slug used" "$(printf '%s' "$out2" | grep -c '\[qwen3coder-1\]')" "1"

# --- test: missing --model is a usage error (rc 2) ---
printf '%s' "$DIFF" | bash "$CFP" >/dev/null 2>&1; check "missing model rc2" "$?" "2"

# --- test: citation guard still drops out-of-range cites ---
cat > "$tmp/stub.py" <<'PY'
import os
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: bogus [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
out3="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug s 2>/dev/null)"
check "hallucinated cite dropped" "$(printf '%s' "$out3" | grep -c '^## Critical Issues (0 found)')" "1"

# --- HIMMEL-737: provider-failure body surfaces on stderr (raw head) ---
# A quota 403 arrives as the "review" BODY (rc 0, non-empty, malformed). The
# fail path must exit 1 AND print a bounded raw head to stderr - the panel's
# quota-exhaustion fallback matches its signature against THIS stderr; a
# path-only line kept the fallback chain permanently dark in production.
cat > "$tmp/stub.py" <<'PY'
print("HTTP 403: The free quota has been exhausted")
PY
err403="$tmp/err403"
printf '%s' "$DIFF" | HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug s >/dev/null 2>"$err403"
check "quota-shaped garbage exits 1" "$?" "1"
check "raw head on stderr carries the quota text" \
    "$(grep -c 'critic-first-pass.sh: raw head: HTTP 403: The free quota has been exhausted' "$err403")" "1"

# --- test: retry recovers on first-attempt empty response ---
# Counter file: bash shim increments it, decides which stub.py to exec.
counter_file="$tmp/retry_counter"
printf '0' > "$counter_file"
cat > "$tmp/stub_retry_empty.py" <<'PY'
# Returns nothing (empty output, rc 0) — simulates hermes producing no response.
PY
cat > "$tmp/stub_retry_good.py" <<'PY'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: off-by-one in loop bound [foo.sh:3]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
# The shim increments a bash counter, then picks empty on call 1 and good from call 2 onward.
cat > "$tmp/py_retry.sh" <<SHEOF
#!/usr/bin/env bash
n=\$(cat "$counter_file")
n=\$((n + 1))
printf '%s' "\$n" > "$counter_file"
if [ "\$n" -le 1 ]; then
    exec python3 "$tmp/stub_retry_empty.py"
else
    exec python3 "$tmp/stub_retry_good.py"
fi
SHEOF
chmod +x "$tmp/py_retry.sh"
out4="$(printf '%s' "$DIFF" | HERMES_PY="$tmp/py_retry.sh" bash "$CFP" --model x/y --slug s 2>/dev/null)"
rc4=$?
check "retry recovers rc" "$rc4" "0"
check "retry recovers output" "$(printf '%s' "$out4" | grep -c '^## Critical Issues (1 found)')" "1"
check "retry used 2 attempts" "$(cat "$counter_file")" "2"

# --- test: fail-open after exhaustion (3 retries all empty) ---
counter_file2="$tmp/exhaust_counter"
printf '0' > "$counter_file2"
cat > "$tmp/stub_exhaust_empty.py" <<'PY'
# Always returns nothing (empty output, rc 0).
PY
cat > "$tmp/py_exhaust.sh" <<SHEOF
#!/usr/bin/env bash
n=\$(cat "$counter_file2")
n=\$((n + 1))
printf '%s' "\$n" > "$counter_file2"
exec python3 "$tmp/stub_exhaust_empty.py"
SHEOF
chmod +x "$tmp/py_exhaust.sh"
printf '%s' "$DIFF" | HERMES_PY="$tmp/py_exhaust.sh" bash "$CFP" --model x/y --slug s >/dev/null 2>&1
rc5=$?
check "exhausted retries fail-open rc1" "$rc5" "1"
check "exhausted retries tried 3 times" "$(cat "$counter_file2")" "3"

# --- HIMMEL-473: per-family prompt adaptation -----------------------------
# Family classification is verified through the prompt the model receives
# (--print-prompt builds the family-adapted prompt without invoking hermes).
PP(){ printf '%s' "$DIFF" | bash "$CFP" --model "$1" --print-prompt 2>/dev/null; }

# gpt/codex family → spec tags + explicit non-contradiction.
check "codex (gpt-5.5) → gpt: has <task> tag"        "$(PP gpt-5.5 | grep -c '<task>')"                "1"
check "codex (gpt-5.5) → gpt: non-contradiction"     "$(PP gpt-5.5 | grep -c 'internally consistent')" "1"
check "codex (gpt-5.5) → gpt: no-preamble clause"    "$(PP gpt-5.5 | grep -c 'no preamble, no commentary, no code fences')" "1"
# gpt-oss is OPEN-weights — must get the rigid open framing, NOT the gpt tags.
check "gpt-oss → open framing (reproduce precisely)" "$(PP openai/gpt-oss-120b | grep -c 'reproduce precisely')" "1"
check "gpt-oss → NOT gpt (<task> absent)"            "$(PP openai/gpt-oss-120b | grep -c '<task>')"     "0"
check "kimi → open framing"                          "$(PP moonshotai/kimi-k2.6 | grep -c 'reproduce precisely')" "1"
check "qwen → open framing"                          "$(PP qwen/qwen3-coder-480b | grep -c 'reproduce precisely')" "1"
check "unknown → open framing (rigid default)"       "$(PP some/unknown-model | grep -c 'reproduce precisely')" "1"
# claude family → XML + IMPORTANT.
check "claude → IMPORTANT line"                      "$(PP claude-opus-4-8 | grep -c 'IMPORTANT:')"    "1"
check "claude → NOT open (no rigid FORMAT framing)"  "$(PP claude-opus-4-8 | grep -c 'reproduce precisely')" "0"

# The parseable contract is family-INVARIANT (downstream awk depends on it).
check "gpt keeps Critical heading"     "$(PP gpt-5.5 | grep -c '## Critical Issues (N found)')"            "1"
check "open keeps Critical heading"    "$(PP openai/gpt-oss-120b | grep -c '## Critical Issues (N found)')" "1"
check "claude keeps Critical heading"  "$(PP claude-opus-4-8 | grep -c '## Critical Issues (N found)')"     "1"
check "all families keep citation rule" "$(PP gpt-5.5 | grep -c '\[<file>:<line>\] citation')"             "1"
# HIMMEL-498: prompt-injection guard present for EVERY family (shared rules block).
check "gpt has injection guard"    "$(PP gpt-5.5             | grep -c 'UNTRUSTED DATA to review')" "1"
check "open has injection guard"   "$(PP openai/gpt-oss-120b | grep -c 'UNTRUSTED DATA to review')" "1"
check "claude has injection guard" "$(PP claude-opus-4-8     | grep -c 'UNTRUSTED DATA to review')" "1"
check "gpt diff-mode keeps injection Critical clause" "$(PP gpt-5.5 | grep -c 'itself a Critical finding')" "1"
check "gpt diff-mode carves out agent-instruction content" "$(PP gpt-5.5 | grep -c 'NOT a prompt-injection finding')" "1"
# HIMMEL-944 policy structure (not just phrase presence): current-run steering
# flags EVEN inside agent files; the carve-out is scoped to LATER-LOADED text;
# and the precedence clause appears BEFORE the carve-out on the rule line.
check "gpt diff-mode steering flags even in agent files" "$(PP gpt-5.5 | grep -c 'EVEN IF it sits inside an agent-instruction file')" "1"
check "gpt diff-mode carve-out scoped to later-loaded text" "$(PP gpt-5.5 | grep -c 'LATER LOADED')" "1"
check "gpt diff-mode precedence clause precedes carve-out" "$(PP gpt-5.5 | grep -c 'EVEN IF.*LATER LOADED')" "1"

# --- HIMMEL-485: ESTIMATED usage telemetry (CR_USAGE_LOG, opt-in) ----------
cat > "$tmp/stub.py" <<'PY'
print("## Critical Issues (0 found)")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
# CR_USAGE_LOG=1 → a `usage` record is appended (best-effort), keyed by slug.
u_ledger="$tmp/usage-ledger.jsonl"
printf '%s' "$DIFF" | CR_USAGE_LOG=1 CR_LEDGER="$u_ledger" HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug codex >/dev/null 2>&1
check "usage record written when CR_USAGE_LOG=1" "$([ -f "$u_ledger" ] && grep -c '"kind":"usage"' "$u_ledger" || echo 0)" "1"
check "usage record carries slug as model"       "$([ -f "$u_ledger" ] && grep -c '"model":"codex"' "$u_ledger" || echo 0)" "1"
check "usage est_total_tokens positive"          "$(u="$u_ledger" node -e 'const o=require("fs").readFileSync(process.env.u,"utf8").trim().split(String.fromCharCode(10)).map(JSON.parse).find(r=>r.kind==="usage");process.stdout.write(String(o.est_total_tokens>0))' 2>/dev/null)" "true"

# CR_USAGE_LOG unset (default) → NO usage record (telemetry is opt-in).
u_off="$tmp/usage-ledger-off.jsonl"
printf '%s' "$DIFF" | CR_LEDGER="$u_off" HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug codex >/dev/null 2>&1
check "no usage record when CR_USAGE_LOG unset" "$([ -f "$u_off" ] && grep -c '"kind":"usage"' "$u_off" || echo 0)" "0"

# stdout contract is byte-intact whether or not usage logging is on.
out_on="$(printf '%s' "$DIFF" | CR_USAGE_LOG=1 CR_LEDGER="$tmp/u3.jsonl" HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug s 2>/dev/null)"
out_off="$(printf '%s' "$DIFF" | CR_LEDGER="$tmp/u4.jsonl" HERMES_PY="$tmp/py.sh" bash "$CFP" --model x/y --slug s 2>/dev/null)"
check "stdout identical with/without usage logging" "$out_on" "$out_off"

# --- HIMMEL-558: CR critics route through the senior himmel_agent profile ------
# A recording shim writes HERMES_ONESHOT_PROFILE (what invoke.sh resolved) to a
# capture file, then prints a contract-shaped review so the pass succeeds.
prof_cap="$tmp/prof_capture"
tool_cap="$tmp/tool_capture"
cat > "$tmp/stub_prof.py" <<'PY'
print("## Critical Issues (0 found)")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
cat > "$tmp/py_prof.sh" <<SHEOF
#!/usr/bin/env bash
printf '%s' "\${HERMES_ONESHOT_PROFILE:-}"  > "$prof_cap"
printf '%s' "\${HERMES_ONESHOT_TOOLSETS:-}" > "$tool_cap"
exec python3 "$tmp/stub_prof.py"
SHEOF
chmod +x "$tmp/py_prof.sh"
mkdir -p "$tmp/hh/profiles/himmel_agent"   # so invoke.sh's existence guard passes

# gpt/codex family, default (CR_CRITIC_PROFILE unset) → senior himmel_agent.
printf '%s' "$DIFF" | HERMES_HOME="$tmp/hh" HERMES_PY="$tmp/py_prof.sh" bash "$CFP" --model gpt-5.5 --slug codex >/dev/null 2>&1
check "gpt-family critic defaults to himmel_agent (senior)" "$(cat "$prof_cap" 2>/dev/null)" "himmel_agent"

# open family (qwen), default → hermes default profile (himmel_agent is Codex-
# provider-bound and would 400 on an NVIDIA model). Empty profile.
printf '%s' "$DIFF" | HERMES_HOME="$tmp/hh" HERMES_PY="$tmp/py_prof.sh" bash "$CFP" --model qwen/qwen3-coder-480b --slug qwen3coder >/dev/null 2>&1
check "open-family critic stays on default profile (provider-safe)" "$(cat "$prof_cap" 2>/dev/null)" ""

# gpt-family + CR_CRITIC_PROFILE=none → forced hermes default (no -p).
printf '%s' "$DIFF" | CR_CRITIC_PROFILE=none HERMES_HOME="$tmp/hh" HERMES_PY="$tmp/py_prof.sh" bash "$CFP" --model gpt-5.5 --slug codex >/dev/null 2>&1
check "CR_CRITIC_PROFILE=none forces default profile (empty)" "$(cat "$prof_cap" 2>/dev/null)" ""

# gpt-family + CR_CRITIC_PROFILE="" (explicitly empty, SET) → forced default. This
# is the regression-prone branch: the gate uses ${CR_CRITIC_PROFILE+x} (set-test),
# so an empty explicit value must WIN over the gpt-family himmel_agent default. A
# refactor to `:-`/`-n` would silently defeat this operator escape hatch.
printf '%s' "$DIFF" | CR_CRITIC_PROFILE="" HERMES_HOME="$tmp/hh" HERMES_PY="$tmp/py_prof.sh" bash "$CFP" --model gpt-5.5 --slug codex >/dev/null 2>&1
check "empty CR_CRITIC_PROFILE forces default on gpt family" "$(cat "$prof_cap" 2>/dev/null)" ""

# claude family, default → default profile (provider-safe, shares the else arm).
printf '%s' "$DIFF" | HERMES_HOME="$tmp/hh" HERMES_PY="$tmp/py_prof.sh" bash "$CFP" --model claude-opus-4-8 --slug claude >/dev/null 2>&1
check "claude-family critic stays on default profile" "$(cat "$prof_cap" 2>/dev/null)" ""

# Explicit CR_CRITIC_PROFILE overrides the family gate (applies to open family too).
printf '%s' "$DIFF" | CR_CRITIC_PROFILE=himmel_agent HERMES_HOME="$tmp/hh" HERMES_PY="$tmp/py_prof.sh" bash "$CFP" --model qwen/qwen3-coder-480b --slug qwen3coder >/dev/null 2>&1
check "explicit CR_CRITIC_PROFILE overrides family gate" "$(cat "$prof_cap" 2>/dev/null)" "himmel_agent"

# Anti-injection (CR finding codex-4): a CR_CRITIC_PROFILE with an embedded flag
# must be passed to invoke.sh as ONE argument, never word-split — so it can NOT
# inject a second flag like --toolsets. Toolsets must stay the invoke.sh default.
printf '%s' "$DIFF" | CR_CRITIC_PROFILE="himmel_agent --toolsets terminal" HERMES_HOME="$tmp/hh" HERMES_PY="$tmp/py_prof.sh" bash "$CFP" --model gpt-5.5 --slug codex >/dev/null 2>&1
check "injecting profile value cannot leak --toolsets to invoke" "$(cat "$tool_cap" 2>/dev/null)" "todo"

# ── WS4 (HIMMEL-414): artifact mode + charter seam ──────────────────────────
ART="$tmp/spec.md"
cat > "$ART" <<'MD'
# Design Alpha
## Motivation
Some motivating text.
## Goals
The goals section.
MD
CHARTER="$tmp/charter.md"
printf '%s\n' 'You are a rigorous SPEC critic. Hunt for ambiguity and missing acceptance criteria.' > "$CHARTER"

# (a) non-diff text WITHOUT --artifact-mode → exit 2 (diff-shape guard intact)
printf 'just some markdown\n' | bash "$CFP" --model x/y --slug s >/dev/null 2>&1
check "a: non-diff without artifact-mode -> exit 2" "$?" "2"

# Stub model output: 2 critical (one good heading, one bad heading), 1 important (line-style cite).
cat > "$tmp/stub_art.py" <<'PY'
print("## Critical Issues (2 found)")
print("- [CRITIC-1]: unclear scope [spec.md#Goals]")
print("- [CRITIC-2]: bogus [spec.md#No Such Heading]")
print("## Important Issues (1 found)")
print("- [CRITIC-3]: line style [spec.md:42]")
print("## Suggestions (0 found)")
PY
cat > "$tmp/py_art.sh" <<PYX
#!/usr/bin/env bash
exec python3 "$tmp/stub_art.py"
PYX
chmod +x "$tmp/py_art.sh"

art_out="$(HERMES_PY="$tmp/py_art.sh" bash "$CFP" --artifact-mode --charter-file "$CHARTER" --model x/y --slug s < "$ART" 2>/dev/null)"
# (b) findings emitted under heading contract
check "b: artifact-mode emits Critical heading" "$(printf '%s\n' "$art_out" | grep -c '^## Critical Issues')" "1"
# (d) real-heading citation survives
check "d: real-heading finding kept" "$(printf '%s\n' "$art_out" | grep -cF '[spec.md#Goals]')" "1"
# (c) bad-heading citation dropped + Critical recomputed to 1
check "c: bad-heading dropped -> Critical (1 found)" "$(printf '%s\n' "$art_out" | grep -c '^## Critical Issues (1 found)')" "1"
# (d2) line-style [file:42] citation dropped in artifact mode -> Important (0 found)
check "d2: line-style cite dropped -> Important (0 found)" "$(printf '%s\n' "$art_out" | grep -c '^## Important Issues (0 found)')" "1"

# (d2b/e) --print-prompt in artifact mode: charter text present, hardcoded role absent,
# heading-citation instruction present, diff-line-citation instruction absent.
pp_art="$(bash "$CFP" --artifact-mode --charter-file "$CHARTER" --model x/y --slug s --print-prompt < "$ART" 2>/dev/null)"
check "e: charter text in prompt"        "$(printf '%s\n' "$pp_art" | grep -c 'rigorous SPEC critic')" "1"
check "e: hardcoded reviewer role absent" "$(printf '%s\n' "$pp_art" | grep -c 'first-pass code reviewer')" "0"
check "d2: prompt instructs heading citation" "$(printf '%s\n' "$pp_art" | grep -qF '[<file>#<heading>]' && echo yes || echo no)" "yes"
check "d2: prompt drops diff-line citation clause" "$(printf '%s\n' "$pp_art" | grep -c 'new-file line numbers')" "0"
# codex-1 (CR panel): artifact mode must NOT reuse the diff prompt-injection rule
# (which flags embedded instruction-like text as a Critical finding) — a spec that
# DISCUSSES injection would get false-positive Criticals. And it fences as artifact.
check "artifact-mode softens the injection rule (no false-positive Critical)" "$(printf '%s\n' "$pp_art" | grep -qF 'normal artifact content, NOT a finding' && echo yes || echo no)" "yes"
check "artifact-mode drops the diff injection-Critical clause" "$(printf '%s\n' "$pp_art" | grep -c 'itself a Critical finding')" "0"
# code-reviewer (CR panel): a heading containing '#' must be extracted intact
# (split on the FIRST '#', not the last) — else a validly-cited finding drops.
ART2="$tmp/spec2.md"
cat > "$ART2" <<'MD'
# Design
## Issue #42 handling
Body.
MD
cat > "$tmp/stub_hash.py" <<'PY'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: unhandled path [spec2.md#Issue #42 handling]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PY
cat > "$tmp/py_hash.sh" <<PYX
#!/usr/bin/env bash
exec python3 "$tmp/stub_hash.py"
PYX
chmod +x "$tmp/py_hash.sh"
hash_out="$(HERMES_PY="$tmp/py_hash.sh" bash "$CFP" --artifact-mode --charter-file "$CHARTER" --model x/y --slug s < "$ART2" 2>/dev/null)"
check "heading containing '#' kept (first-# split)" "$(printf '%s\n' "$hash_out" | grep -c '^## Critical Issues (1 found)')" "1"

# missing charter file -> exit 2
printf 'x\n' | bash "$CFP" --artifact-mode --charter-file "$tmp/nope.md" --model x/y --slug s >/dev/null 2>&1
check "missing charter file -> exit 2" "$?" "2"
# --perspective-file appends an optional analytical lens after the shared rules.
PERSPECTIVE="$tmp/perspective.md"
printf '%s\n' 'PERSPECTIVE_SENTINEL: hunt for shared-state breakage.' > "$PERSPECTIVE"
pp_persp="$(printf '%s' "$DIFF" | bash "$CFP" --model x/y --slug s --perspective-file "$PERSPECTIVE" --print-prompt 2>/dev/null)"
check "perspective text appears when enabled" "$(printf '%s\n' "$pp_persp" | grep -qF 'PERSPECTIVE_SENTINEL' && echo yes || echo no)" "yes"

pp_persp_off="$(printf '%s' "$DIFF" | CRITIC_PERSPECTIVES=0 bash "$CFP" --model x/y --slug s --perspective-file "$PERSPECTIVE" --print-prompt 2>/dev/null)"
check "CRITIC_PERSPECTIVES=0 suppresses perspective text" "$(printf '%s\n' "$pp_persp_off" | grep -qF 'PERSPECTIVE_SENTINEL' && echo yes || echo no)" "no"

rules_line="$(printf '%s\n' "$pp_persp" | grep -nF 'Do NOT call any tools.' | head -1 | cut -d: -f1)"
persp_line="$(printf '%s\n' "$pp_persp" | grep -nF 'PERSPECTIVE_SENTINEL' | head -1 | cut -d: -f1)"
if [ -n "$rules_line" ] && [ -n "$persp_line" ] && [ "$rules_line" -lt "$persp_line" ]; then
    echo "ok - perspective text appears after rules block"
else
    echo "FAIL - perspective text appears after rules block: rules_line=$rules_line persp_line=$persp_line"
    fails=$((fails + 1))
fi

printf '%s' "$DIFF" | bash "$CFP" --model x/y --slug s --perspective-file "$PERSPECTIVE" --charter-file "$CHARTER" --print-prompt >/dev/null 2>&1
check "perspective plus charter is usage error rc2" "$?" "2"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
