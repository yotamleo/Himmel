#!/usr/bin/env bash
# scripts/hermes/test-egress-gate.sh — denial + pass tests for the egress-matrix
# gate at the Hermes dispatch chokepoint (HIMMEL-1259).
#
# Stubs only: HERMES_PY is a fake interpreter, no hermes is started and nothing
# is dispatched to a real provider. Every roots/ledger env is pointed at a temp
# tree so the operator's live vault, handover state and ledgers are never read
# or written.
#
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/egress-gate.sh"
INVOKE="$SCRIPT_DIR/invoke.sh"
WRAP="$SCRIPT_DIR/dispatch-trusted.sh"
FAILED=0

TMP="$(mktemp -d "${TMPDIR:-/tmp}/egress-gate-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

check() { # label expected actual
    if [ "$2" = "$3" ]; then echo "PASS $1"
    else echo "FAIL $1 — expected [$2], got [$3]"; FAILED=$((FAILED+1)); fi
}
check_contains() { # label needle haystack
    case "$3" in *"$2"*) echo "PASS $1" ;;
        *) echo "FAIL $1 — missing [$2] in: $3"; FAILED=$((FAILED+1)) ;; esac
}

# ── fixture corpora ─────────────────────────────────────────────────────────
HO="$TMP/luna/handovers"                     # handover root NESTED in the vault
mkdir -p "$HO/u/himmel" "$TMP/luna/Clippings" "$TMP/luna/journal" \
         "$TMP/code" "$TMP/salusproj"
printf 'brief\n' > "$HO/u/himmel/brief.md"
printf 'clip\n'  > "$TMP/luna/Clippings/c.md"
printf 'note\n'  > "$TMP/luna/journal/n.md"
printf 'diff\n'  > "$TMP/code/diff.txt"
: > "$TMP/salusproj/.salus"
printf 'phi\n'   > "$TMP/salusproj/p.md"
ln -s "$HO/u/himmel/brief.md" "$TMP/code/disguised.md" 2>/dev/null

export HANDOVER_DIR="$HO"
export LUNA_VAULT_PATH="$TMP/luna"
unset LUNA_VAULT
export HIMMEL_HERMES_EGRESS_LEDGER="$TMP/egress.jsonl"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"

# gate <prompt-file> [provider]  -> sets rc + err
gate() {
    if [ -n "${2:-}" ]; then
        err="$(bash "$GATE" --prompt-file "$1" --provider "$2" 2>&1)"; rc=$?
    else
        err="$(bash "$GATE" --prompt-file "$1" 2>&1)"; rc=$?
    fi
}

# ── de-listed / unsanctioned providers are refused for handover briefs ──────
BRIEF="$HO/u/himmel/brief.md"
for p in alibaba-coding-plan alibaba deepseek zai zai-glm nous; do
    gate "$BRIEF" "$p"
    check "handover brief x $p refused (rc 4)" 4 "$rc"
    check_contains "handover brief x $p names the corpus" "handover-state" "$err"
done
gate "$BRIEF" ""
check "handover brief with NO --provider refused (routing unresolvable)" 4 "$rc"
check_contains "no-provider refusal tells the caller what to do" "--provider" "$err"

# ── sanctioned providers pass, and the dispatch is ledgered ─────────────────
: > "$HIMMEL_HERMES_EGRESS_LEDGER"
gate "$BRIEF" openai-codex
check "handover brief x openai-codex allowed (brief-scoped conditional)" 0 "$rc"
gate "$BRIEF" anthropic
check "handover brief x anthropic allowed" 0 "$rc"
gate "$BRIEF" ollama
check "handover brief x ollama (local-ollama alias) allowed" 0 "$rc"
gate "$BRIEF" openrouter
check "handover brief x openrouter allowed (HIMMEL-1774 inference cell)" 0 "$rc"
check "each permitted gated dispatch wrote one ledger line" 4 "$(wc -l < "$HIMMEL_HERMES_EGRESS_LEDGER" | tr -d ' ')"
check_contains "ledger line carries corpus+verdict" '"corpus":"handover-state"' "$(cat "$HIMMEL_HERMES_EGRESS_LEDGER")"

# ── vault corpora: only anthropic / local stay open ─────────────────────────
gate "$TMP/luna/journal/n.md" openai-codex
check "luna-personal x openai-codex refused (no cell -> default deny)" 4 "$rc"
check_contains "luna-personal named" "luna-personal" "$err"
gate "$TMP/luna/journal/n.md" anthropic
check "luna-personal x anthropic allowed" 0 "$rc"
gate "$TMP/luna/Clippings/c.md" alibaba-coding-plan
check "luna-clippings x alibaba refused" 4 "$rc"
check_contains "luna-clippings named" "luna-clippings" "$err"

# ── salus: deny; the local-ollama cell is conditional and unverifiable here ─
gate "$TMP/salusproj/p.md" openai-codex
check "salus x openai-codex refused" 4 "$rc"
gate "$TMP/salusproj/p.md" ollama
check "salus x ollama (conditional opt-in) refused — gate cannot verify the opt-in" 4 "$rc"

# ── classification cannot be dodged ─────────────────────────────────────────
gate "$TMP/code/disguised.md" deepseek
check "symlink OUT of a code dir INTO handovers still classified handover-state" 4 "$rc"
gate "$HO/u/../u/himmel/brief.md" deepseek
check "dot-dot path resolved before classification" 4 "$rc"

# ── un-gated corpora are untouched (public code stays open on every lane) ───
gate "$TMP/code/diff.txt" alibaba-coding-plan
check "non-vault prompt file x alibaba passes (himmel-code / unclassified)" 0 "$rc"
gate "$TMP/code/diff.txt"
check "non-vault prompt file with no --provider passes" 0 "$rc"

# ── handover root == vault root: the stricter vault corpus wins ─────────────
err="$(HANDOVER_DIR="$TMP/luna" bash "$GATE" --prompt-file "$TMP/luna/journal/n.md" --provider openai-codex 2>&1)"; rc=$?
check "handover root == vault root keeps luna-personal (codex refused)" 4 "$rc"

# ── fail closed when the evaluator cannot be reached ────────────────────────
BROKEN="$TMP/broken/scripts/hermes"
mkdir -p "$BROKEN"
cp "$GATE" "$BROKEN/egress-gate.sh"
mkdir -p "$TMP/broken/scripts/lib"
cp "$SCRIPT_DIR/../lib/handover-path.sh" "$TMP/broken/scripts/lib/"
err="$(bash "$BROKEN/egress-gate.sh" --prompt-file "$BRIEF" --provider anthropic 2>&1)"; rc=$?
check "evaluator missing -> refused, never allowed" 4 "$rc"
check_contains "evaluator-missing refusal is explicit" "egress-matrix" "$err"

# ── unwritable ledger on a permitted gated dispatch refuses ─────────────────
err="$(HIMMEL_HERMES_EGRESS_LEDGER="$BRIEF/x/l.jsonl" bash "$GATE" --prompt-file "$BRIEF" --provider anthropic 2>&1)"; rc=$?
check "unwritable ledger on a permitted gated dispatch refuses" 4 "$rc"

# ── through the real chokepoint (invoke.sh) with a stub interpreter ─────────
STUB="$TMP/fake-python"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
echo "called" > "${STUB_CAPTURE:?}"
printf 'stub-ok'
EOS
chmod +x "$STUB"
export HERMES_PY="$STUB"
export STUB_CAPTURE="$TMP/cap"

rm -f "$STUB_CAPTURE"; : > "$HIMMEL_FLOW_RUNS_LEDGER"
bash "$INVOKE" --prompt-file "$BRIEF" --provider deepseek --model deepseek-v4-flash >/dev/null 2>&1; rc=$?
check "invoke.sh: handover brief x deepseek refused rc 4" 4 "$rc"
check "invoke.sh: refusal happens BEFORE the interpreter runs" "absent" "$([ -e "$STUB_CAPTURE" ] && echo present || echo absent)"
check "invoke.sh: refusal writes no flow-run start row" 0 "$(wc -c < "$HIMMEL_FLOW_RUNS_LEDGER" | tr -d ' ')"

rm -f "$STUB_CAPTURE"
bash "$WRAP" --prompt-file "$BRIEF" --provider alibaba-coding-plan --model qwen3-coder-plus >/dev/null 2>&1; rc=$?
check "dispatch-trusted.sh: handover brief x alibaba refused (chokepoint chaining)" 4 "$rc"
check "dispatch-trusted.sh: interpreter never ran" "absent" "$([ -e "$STUB_CAPTURE" ] && echo present || echo absent)"

rm -f "$STUB_CAPTURE"
bash "$INVOKE" --prompt-file "$BRIEF" --provider openai-codex >/dev/null 2>&1; rc=$?
check "invoke.sh: handover brief x openai-codex reaches the interpreter" 0 "$rc"
check "invoke.sh: interpreter ran for the sanctioned provider" present "$([ -e "$STUB_CAPTURE" ] && echo present || echo absent)"

rm -f "$STUB_CAPTURE"
bash "$INVOKE" --prompt-file "$TMP/code/diff.txt" --provider alibaba-coding-plan --model qwen3-coder-plus >/dev/null 2>&1; rc=$?
check "invoke.sh: public-code prompt x alibaba still dispatches (qwen stays a himmel-code option)" 0 "$rc"

if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "PASS all cases"; exit 0
