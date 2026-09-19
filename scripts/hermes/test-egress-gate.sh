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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/egress-gate-test.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
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

# handover root CONTAINS the vault: a handover file OUTSIDE the vault is still
# handover-state (round 3) — only files inside the vault keep the stricter corpus
mkdir -p "$TMP/hp/luna/journal" "$TMP/hp/other"
printf 'n\n' > "$TMP/hp/luna/journal/n.md"
printf 'b\n' > "$TMP/hp/other/b.md"
err="$(HANDOVER_DIR="$TMP/hp" LUNA_VAULT_PATH="$TMP/hp/luna" bash "$GATE" --prompt-file "$TMP/hp/other/b.md" --provider deepseek 2>&1)"; rc=$?
check "handover root containing the vault: handover file OUTSIDE the vault x deepseek refused" 4 "$rc"
check_contains "…and classified handover-state, not un-gated" "handover-state" "$err"
err="$(HANDOVER_DIR="$TMP/hp" LUNA_VAULT_PATH="$TMP/hp/luna" bash "$GATE" --prompt-file "$TMP/hp/luna/journal/n.md" --provider openai-codex 2>&1)"; rc=$?
check "handover root containing the vault: file INSIDE the vault keeps luna-personal (codex refused)" 4 "$rc"
check_contains "…and is classified luna-personal" "luna-personal" "$err"

# ── fail closed when the evaluator cannot be reached ────────────────────────
BROKEN="$TMP/broken/scripts/hermes"
mkdir -p "$BROKEN"
cp "$GATE" "$BROKEN/egress-gate.sh"
mkdir -p "$TMP/broken/scripts/lib"
cp "$SCRIPT_DIR/../lib/handover-path.sh" "$TMP/broken/scripts/lib/"
err="$(bash "$BROKEN/egress-gate.sh" --prompt-file "$BRIEF" --provider anthropic 2>&1)"; rc=$?
check "evaluator missing -> refused, never allowed" 4 "$rc"
check_contains "evaluator-missing refusal is explicit" "egress-matrix" "$err"

# handover-path.sh missing: the handover root cannot be resolved, so a handover
# brief could ride the un-gated exit — refuse instead (HIMMEL-1259 review round 1)
NOLIB="$TMP/nolib/scripts/hermes"
mkdir -p "$NOLIB" "$TMP/nolib/scripts/guardrails"
cp "$GATE" "$NOLIB/egress-gate.sh"
cp "$SCRIPT_DIR/../guardrails/egress-matrix-eval.mjs" "$SCRIPT_DIR/../guardrails/egress-matrix.json" "$TMP/nolib/scripts/guardrails/"
err="$(bash "$NOLIB/egress-gate.sh" --prompt-file "$BRIEF" --provider anthropic 2>&1)"; rc=$?
check "handover-path.sh missing -> refused (root unresolvable), never un-gated" 4 "$rc"
check_contains "handover-path refusal is explicit" "handover-path" "$err"

# a prompt path carrying control characters must still yield a valid JSONL line
TABF="$(printf '%s/u/himmel/ta\tb.md' "$HO")"
printf 'x\n' > "$TABF"
: > "$HIMMEL_HERMES_EGRESS_LEDGER"
gate "$TABF" anthropic
check "control-char path x anthropic allowed" 0 "$rc"
check "control-char path yields a parseable ledger line" ok "$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");JSON.parse(l[l.length-1]);process.stdout.write("ok")' "$HIMMEL_HERMES_EGRESS_LEDGER" 2>/dev/null || echo bad)"

# ── brief-scoped: exactly ONE regular file per dispatch, visible in the audit ──
# (matrix handover-state x openai-codex is "brief-scoped ... never bulk corpus
# runs"; the chokepoint audit is the ledger — HIMMEL-1259 round-2 ruling)
gate "$HO/u/himmel" openai-codex
check "a directory as the prompt refused (one regular file only)" 4 "$rc"
check_contains "directory refusal names the regular-file rule" "regular file" "$err"
gate "$HO/u/himmel/no-such-brief.md" openai-codex
check "a nonexistent prompt refused (not a regular file)" 4 "$rc"
ln -s "$TMP/code/diff.txt" "$HO/u/himmel/escape.md" 2>/dev/null
gate "$HO/u/himmel/escape.md" anthropic
check "symlink under the handover root resolving OUTSIDE it refused" 4 "$rc"
check_contains "escape refusal says it resolves outside the handover root" "outside the handover root" "$err"
ln -s "$HO/u/himmel/brief.md" "$HO/u/himmel/alias.md" 2>/dev/null
: > "$HIMMEL_HERMES_EGRESS_LEDGER"
gate "$HO/u/himmel/alias.md" anthropic
check "symlink under the handover root resolving INSIDE it allowed" 0 "$rc"
check "ledger line carries the RESOLVED path and the byte size" "$HO/u/himmel/brief.md 6" "$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");const r=JSON.parse(l[l.length-1]);process.stdout.write(r.prompt+" "+r.bytes)' "$HIMMEL_HERMES_EGRESS_LEDGER" 2>/dev/null || echo bad)"

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

# ── HIMMEL-3221: hermes is dispatched an immutable SNAPSHOT of the gated file ──
# The gate classifies the prompt by path; invoke.sh used to hand hermes that same
# path afterwards, so a file swapped in between (check-then-use) reached the
# interpreter unclassified. The gate now copies the file once into a private
# 0600 snapshot (identity re-checked around the copy) and invoke.sh dispatches
# only the snapshot. The swaps below are driven by PATH stubs: `hostname` runs
# inside invoke.sh AFTER the gate and BEFORE the interpreter spawn; `node` runs
# the evaluator INSIDE the gate, between classification and the copy.
REALNODE="$(command -v node)"
HOSTBIN="$TMP/hostbin"; NODEBIN="$TMP/nodebin"; mkdir -p "$HOSTBIN" "$NODEBIN"
cat > "$TMP/do-swap.sh" <<'EOS'
#!/usr/bin/env bash
[ -e "${SWAP_DONE:?}" ] && exit 0
: > "$SWAP_DONE"
printf 'SWAPPED-CORPUS\n' > "${SWAP_TARGET:?}.new" && mv -f "$SWAP_TARGET.new" "$SWAP_TARGET"
EOS
cat > "$HOSTBIN/hostname" <<EOS
#!/usr/bin/env bash
bash "$TMP/do-swap.sh"
echo swaphost
EOS
cat > "$NODEBIN/node" <<EOS
#!/usr/bin/env bash
case "\${1:-}" in *egress-matrix-eval.mjs) bash "$TMP/do-swap.sh" ;; esac
exec "$REALNODE" "\$@"
EOS
chmod +x "$TMP/do-swap.sh" "$HOSTBIN/hostname" "$NODEBIN/node"
SNAPSTUB="$TMP/fake-python-snap"
cat > "$SNAPSTUB" <<'EOS'
#!/usr/bin/env bash
cat "${HERMES_PROMPT_FILE:?}" > "${STUB_CAPTURE:?}"
echo "$HERMES_PROMPT_FILE" > "$STUB_CAPTURE.path"
ls -l "$HERMES_PROMPT_FILE" | cut -c1-10 > "$STUB_CAPTURE.mode"
printf 'stub-ok'
EOS
chmod +x "$SNAPSTUB"
SWAPFILE="$HO/u/himmel/swap.md"
export SWAP_TARGET="$SWAPFILE" SWAP_DONE="$TMP/swap.done"

# A. file swapped AFTER the gate, BEFORE the interpreter: hermes gets the gated bytes
printf 'GATED-CORPUS\n' > "$SWAPFILE"; rm -f "$SWAP_DONE" "$STUB_CAPTURE" "$STUB_CAPTURE".path "$STUB_CAPTURE".mode
HERMES_PY="$SNAPSTUB" PATH="$HOSTBIN:$PATH" bash "$INVOKE" --prompt-file "$SWAPFILE" --provider openai-codex >/dev/null 2>&1; rc=$?
check "snapshot: the swap fired between the gate and the spawn (control)" "SWAPPED-CORPUS" "$(tr -d '\n' < "$SWAPFILE")"
check "snapshot: swapped-after-gate dispatch still succeeds" 0 "$rc"
check "snapshot: the interpreter receives the GATED bytes, not the swapped file" "GATED-CORPUS" "$(tr -d '\n' < "$STUB_CAPTURE" 2>/dev/null)"
check "snapshot: the interpreter reads a private path, not the gated path" "no" "$([ "$(cat "$STUB_CAPTURE.path" 2>/dev/null)" = "$SWAPFILE" ] && echo yes || echo no)"
check "snapshot: the snapshot is mode 0600" "-rw-------" "$(cat "$STUB_CAPTURE.mode" 2>/dev/null)"

# B. file swapped INSIDE the gate (classified, then replaced before the copy):
# the identity re-check refuses — the swapped bytes must never be dispatched
printf 'GATED-CORPUS\n' > "$SWAPFILE"; rm -f "$SWAP_DONE" "$STUB_CAPTURE" "$STUB_CAPTURE".path "$STUB_CAPTURE".mode
err="$(HERMES_PY="$SNAPSTUB" PATH="$NODEBIN:$PATH" bash "$INVOKE" --prompt-file "$SWAPFILE" --provider openai-codex 2>&1)"; rc=$?
check "snapshot: the swap fired inside the gate (control)" "SWAPPED-CORPUS" "$(tr -d '\n' < "$SWAPFILE")"
check "snapshot: a file replaced mid-gate is refused rc 4" 4 "$rc"
check "snapshot: …and the interpreter never ran" "absent" "$([ -e "$STUB_CAPTURE" ] && echo present || echo absent)"
check_contains "snapshot: …and the refusal names the change" "changed" "$err"

# B2. a symlink swapped in right before the identity read (after the path was
# canonicalised), as the file itself OR as an ANCESTOR directory: stat, wc and cat
# follow it consistently, so only re-resolving the original argument after the
# copy shows the path no longer lands where it was classified
REALSTAT="$(command -v stat)"; STATBIN="$TMP/statbin"; mkdir -p "$STATBIN"
OTHERFILE="$HO/u/himmel/other.md"; printf 'OTHER-GATED-CORPUS\n' > "$OTHERFILE"
ALTDIR="$HO/u/alt"; mkdir -p "$ALTDIR"; cp "$OTHERFILE" "$ALTDIR/swap.md"; HDIR="$HO/u/himmel"
cat > "$STATBIN/stat" <<EOS
#!/usr/bin/env bash
if [ ! -e "$TMP/stat.swapped" ]; then
    for a in "\$@"; do
        [ "\$a" = "$SWAPFILE" ] || continue
        : > "$TMP/stat.swapped"
        case "\${SWAP_MODE:-file}" in
            file) ln -sf "$OTHERFILE" "$SWAPFILE.lnk" && mv -f "$SWAPFILE.lnk" "$SWAPFILE" ;;
            dir)  mv "$HDIR" "$HDIR.orig" && ln -s "$ALTDIR" "$HDIR" ;;
        esac
    done
fi
exec "$REALSTAT" "\$@"
EOS
chmod +x "$STATBIN/stat"
for mode in file dir; do
    printf 'GATED-CORPUS\n' > "$SWAPFILE"; rm -f "$TMP/stat.swapped" "$TMP/snap2.out"
    err="$(SWAP_MODE=$mode PATH="$STATBIN:$PATH" bash "$GATE" --prompt-file "$SWAPFILE" --provider openai-codex --snapshot "$TMP/snap2.out" 2>&1)"; rc=$?
    check "snapshot: the $mode-symlink swap fired before the identity read (control)" "swapped" "$([ -e "$TMP/stat.swapped" ] && echo swapped || echo not)"
    check "snapshot: a $mode symlink swapped in after canonicalisation is refused rc 4" 4 "$rc"
    check_contains "snapshot: …and the refusal says the path no longer resolves" "no longer resolves" "$err"
    if [ "$mode" = dir ]; then rm -f "$HDIR"; mv "$HDIR.orig" "$HDIR"; else rm -f "$SWAPFILE"; fi
done

# C. the gate's own --snapshot + the ledger line
printf 'GATED-CORPUS\n' > "$SWAPFILE"; : > "$HIMMEL_HERMES_EGRESS_LEDGER"; SNAP="$TMP/snap.out"
bash "$GATE" --prompt-file "$SWAPFILE" --provider openai-codex --snapshot "$SNAP" >/dev/null 2>&1; rc=$?
check "gate --snapshot: permitted dispatch rc 0" 0 "$rc"
check "gate --snapshot: the snapshot holds the gated bytes" "GATED-CORPUS" "$(tr -d '\n' < "$SNAP" 2>/dev/null)"
WANT_SHA="$(node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$SNAP")"
check "gate --snapshot: the ledger line carries the snapshot sha256 and byte size" "$WANT_SHA 13" "$(node -e 'const l=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n");const r=JSON.parse(l[l.length-1]);process.stdout.write(r.sha256+" "+r.bytes)' "$HIMMEL_HERMES_EGRESS_LEDGER" 2>/dev/null || echo bad)"
# a NOT-gated file is snapshotted too (a swap could turn it into a gated one)
rm -f "$SNAP"; bash "$GATE" --prompt-file "$TMP/code/diff.txt" --snapshot "$SNAP" >/dev/null 2>&1; rc=$?
check "gate --snapshot: an un-gated file is snapshotted too" "0 diff" "$rc $(tr -d '\n' < "$SNAP" 2>/dev/null)"

# D. fail closed on any copy / mktemp error
err="$(bash "$GATE" --prompt-file "$SWAPFILE" --provider openai-codex --snapshot "$TMP/no-such-dir/snap" 2>&1)"; rc=$?
check "gate --snapshot: an uncopyable destination refuses rc 4" 4 "$rc"
check_contains "gate --snapshot: …with an explicit snapshot refusal" "snapshot" "$err"
rm -f "$STUB_CAPTURE"
err="$(TMPDIR="$TMP/no-such-tmpdir" bash "$INVOKE" --prompt-file "$SWAPFILE" --provider openai-codex 2>&1)"; rc=$?
check "invoke.sh: a snapshot mktemp failure refuses rc 2" 2 "$rc"
check_contains "invoke.sh: …naming the snapshot, not a later mktemp" "prompt snapshot" "$err"
check "invoke.sh: …and the interpreter never ran" "absent" "$([ -e "$STUB_CAPTURE" ] && echo present || echo absent)"

# E. the snapshot is removed on every exit path (success, refusal, hermes failure)
PTMP="$TMP/ptmp"; mkdir -p "$PTMP"
TMPDIR="$PTMP" HERMES_PY="$SNAPSTUB" bash "$INVOKE" --prompt-file "$SWAPFILE" --provider openai-codex >/dev/null 2>&1
TMPDIR="$PTMP" HERMES_PY="$SNAPSTUB" bash "$INVOKE" --prompt-file "$SWAPFILE" --provider deepseek >/dev/null 2>&1
FAILPY="$TMP/fake-python-fail"; printf '#!/usr/bin/env bash\nexit 7\n' > "$FAILPY"; chmod +x "$FAILPY"
TMPDIR="$PTMP" HERMES_PY="$FAILPY" bash "$INVOKE" --prompt-file "$SWAPFILE" --provider openai-codex >/dev/null 2>&1
check "snapshot: no hermes-snapshot file survives success, refusal or hermes failure" 0 "$(find "$PTMP" -name 'hermes-snapshot.*' 2>/dev/null | wc -l | tr -d ' ')"

if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "PASS all cases"; exit 0
