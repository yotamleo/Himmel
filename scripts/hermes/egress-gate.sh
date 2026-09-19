#!/usr/bin/env bash
# scripts/hermes/egress-gate.sh — egress-matrix gate for the Hermes dispatch
# chokepoint (HIMMEL-1259). Called by invoke.sh (which dispatch-trusted.sh execs)
# BEFORE hermes is spawned.
#
# WHY: scripts/guardrails/egress-matrix.json is the one corpus x provider x
# purpose policy, but the Hermes chokepoint never evaluated it — so a handover-
# or vault-backed prompt could still reach a provider the matrix denies
# (Alibaba/qwen, DeepSeek, Z.ai/GLM: de-listed by HIMMEL-1257 / HIMMEL-2224)
# while graphify and claude-openrouter both honored the same deny.
#
# What it does: classifies the --prompt-file by PATH (physical path — symlinks
# and `..` resolved) into salus / luna-personal / luna-clippings /
# handover-state, maps the --provider to its matrix provider name, and asks
# scripts/guardrails/egress-matrix-eval.mjs (the shared first-match-wins
# evaluator; nothing re-implemented here) for the verdict at purpose=inference.
#
#   allow / allow+log -> permitted
#   conditional       -> permitted ONLY for the one cell this gate can verify:
#                        handover-state x openai-codex (brief-scoped — one
#                        prompt file per dispatch, through this chokepoint).
#                        Any other conditional cell (salus x local-ollama's
#                        per-run opt-in) is refused: the condition cannot be
#                        checked here, so it fails closed.
#   deny / anything else / evaluator unreachable / unknown provider -> refused
#
# The gate admits exactly ONE regular file per dispatch (a directory or other
# non-regular path is refused, as is a path under the handover root that
# resolves outside it). A permitted dispatch of a gated corpus appends one line
# to the ledger (HIMMEL_HERMES_EGRESS_LEDGER, default
# ~/.himmel/hermes-egress.jsonl) carrying the resolved path and its byte size;
# a ledger that cannot be written refuses the dispatch (allow+log obligation).
#
# SNAPSHOT (HIMMEL-3221): with --snapshot <dest> the gate copies the classified
# file ONCE into <dest> (a private mode-0600 file the caller created) and the
# caller dispatches only that copy — never the path — so a file swapped or a
# symlink retargeted after the gate cannot change what the interpreter reads.
# The file's identity (dev:inode:size:mtime) is taken before classification and
# re-checked after the copy; any change, copy error or size mismatch refuses
# (fail closed). The ledger line carries the snapshot's sha256 and byte size.
# The copy is taken for un-gated files too: a swap could turn one into a gated one.
#
# A prompt file outside every gated corpus is NOT gated: public code
# (himmel-code) is allowed on every lane by the matrix's own wildcard row, so
# qwen/alibaba stays a legitimate --model for code work.
#
# --provider is REQUIRED for a gated corpus: without it hermes routes by its own
# profile default / model alias, which this gate cannot see, so an unresolvable
# provider is refused rather than assumed sanctioned.
#
# ponytail: the snapshot pins the bytes at copy time, not at classification time:
# a same-inode in-place edit before the copy is not detected (the identity check
# compares dev:inode:size:mtime, so it catches replacement and size/mtime moves),
# and a swap landing between _canon and the first identity read is refused only
# when it leaves a symlink at the path (a shell cannot bind an fd to the
# classified inode, so a plain-file replacement in that window is not detected).
# Classification is by the prompt FILE's path only. A brief handed over
# as positional text or stdin (or copied out of the vault into /tmp first)
# carries no path and is NOT recognised as handover-derived; only a
# --prompt-file under the handover root / luna vault / a .salus tree is gated.
# The salus check is the `.salus` marker walk only — the phi-roots /
# egress-denylist lists are enforced by parity_guard's read-fence, not here.
# Provider names hermes routes to WITHOUT a matching --provider (e.g. an env
# override hermes reads itself) are also outside this gate.
#
# Usage: egress-gate.sh --prompt-file <path> [--provider <hermes-provider>]
#                       [--snapshot <dest>]
# Exit: 0 permitted (or not a gated corpus) · 2 usage · 4 refused (fail-closed)
#
# Environment:
#   HANDOVER_DIR / LUNA_VAULT_PATH / LUNA_VAULT   corpus roots (same as the fence)
#   HIMMEL_HERMES_EGRESS_LEDGER                   ledger path override (tests)
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL="$SCRIPT_DIR/../guardrails/egress-matrix-eval.mjs"
LEDGER="${HIMMEL_HERMES_EGRESS_LEDGER:-$HOME/.himmel/hermes-egress.jsonl}"
PURPOSE="inference"

refuse() { echo "egress-gate: REFUSED — $1" >&2; exit 4; }

prompt_file=""
provider=""
snapshot=""
while [ $# -gt 0 ]; do
    case "$1" in
        --prompt-file) [ $# -ge 2 ] || { echo "egress-gate: --prompt-file requires a value" >&2; exit 2; }
                       prompt_file="$2"; shift 2 ;;
        --provider)    [ $# -ge 2 ] || { echo "egress-gate: --provider requires a value" >&2; exit 2; }
                       provider="$2"; shift 2 ;;
        --snapshot)    [ $# -ge 2 ] || { echo "egress-gate: --snapshot requires a value" >&2; exit 2; }
                       snapshot="$2"; shift 2 ;;
        *) echo "egress-gate: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$prompt_file" ] || { echo "egress-gate: --prompt-file is required" >&2; exit 2; }

# _canon <path> -> physical absolute path (symlinks + `..` resolved); rc 1 if it
# cannot be resolved (fail closed at the call site). POSIX readlink/cd/pwd only —
# no GNU realpath (absent on stock macOS).
_canon() {
    local p="$1" n d i=0
    while [ -L "$p" ] && [ "$i" -lt 40 ]; do
        n="$(readlink "$p")" || return 1
        case "$n" in /*|[A-Za-z]:*) p="$n" ;; *) p="$(dirname "$p")/$n" ;; esac
        i=$((i + 1))
    done
    [ "$i" -lt 40 ] || return 1
    if [ -d "$p" ]; then ( cd -P "$p" 2>/dev/null && pwd -P ); return; fi
    d="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s\n' "${d%/}" "$(basename "$p")"
}

# _ident <path> -> dev:inode:size:mtime of the directory ENTRY at <path> (a
# symlink is NOT followed, so a link swapped in changes the identity); rc 1 + no
# output if it cannot be read. GNU stat, then BSD/macOS stat.
_ident() {
    local o
    o="$(stat -c '%d:%i:%s:%Y' "$1" 2>/dev/null)" || o="$(stat -f '%d:%i:%z:%m' "$1" 2>/dev/null)" || return 1
    [ -n "$o" ] || return 1
    printf '%s\n' "$o"
}

# take_snapshot -> copy the classified file into --snapshot (no-op without one).
# Fail closed: a copy error, a file whose identity/size moved between the
# classification and the copy, or an unreadable size all refuse.
take_snapshot() {
    [ -n "$snapshot" ] || return 0
    local after ssize
    cat "$pf" > "$snapshot" 2>/dev/null || refuse "cannot copy '$pf' into the prompt snapshot '$snapshot' — refusing rather than dispatching a path that can change under us"
    chmod 600 "$snapshot" 2>/dev/null || refuse "cannot restrict the prompt snapshot '$snapshot' to mode 0600"
    after="$(_ident "$pf")" || refuse "cannot re-stat '$pf' after the snapshot copy — refusing rather than trusting an unverified copy"
    [ "$after" = "$ident" ] || refuse "'$pf' changed between the egress classification and the snapshot copy (identity $ident -> $after) — refusing a swapped prompt file"
    ssize="$(wc -c < "$snapshot" 2>/dev/null | tr -d ' ')"
    [ "$ssize" = "$size" ] || refuse "the prompt snapshot holds ${ssize:-?} bytes but '$pf' was classified at $size — refusing a partial or changed copy"
}

_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _under <path> <root> -> rc 0 iff <path> is <root> or inside it (case-folded:
# over-matching on a case-insensitive FS is the stricter, safe direction).
_under() {
    local p r
    p="$(_lc "$1")"; r="$(_lc "${2%/}")"
    [ -n "$r" ] || return 1
    [ "$p" = "$r" ] && return 0
    case "$p" in "$r"/*) return 0 ;; esac
    return 1
}

pf="$(_canon "$prompt_file")" || refuse "cannot resolve the prompt file path '$prompt_file' (symlink loop / unreadable) — refusing rather than classifying it blind"

# --- corpus classification (most restrictive first; mirrors the fence's order) ---
# A root that EXISTS but cannot be resolved is refused, never skipped: skipping it
# would let a prompt under that tree ride the un-gated exit below. A root that
# does not exist (or is unset) holds no prompt file, so there is nothing to gate.
luna_root=""
for v in "${LUNA_VAULT:-}" "${LUNA_VAULT_PATH:-}"; do
    if [ -n "$v" ]; then
        if [ -d "$v" ]; then
            luna_root="$(_canon "$v")" || refuse "cannot resolve the luna vault root '$v' — refusing rather than classifying blind"
        fi
        break
    fi
done

handover_root=""
HANDOVER_LIB="$SCRIPT_DIR/../lib/handover-path.sh"
[ -f "$HANDOVER_LIB" ] || refuse "handover-path.sh not found ($HANDOVER_LIB) — the handover root cannot be resolved, so a handover brief could not be recognised"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$HANDOVER_LIB"
# handover_root fails only when no handover tree exists (HANDOVER_DIR unset or not
# a directory, no inline handovers/) — then no prompt file can be under one.
handover_root="$(handover_root 2>/dev/null || true)"
if [ -n "$handover_root" ]; then
    hr_raw="$handover_root"
    handover_root="$(_canon "$hr_raw")" || refuse "cannot resolve the handover root '$hr_raw' — refusing rather than classifying blind"
fi

# Brief-scoped means ONE regular file per dispatch (matrix handover-state x
# openai-codex: "never bulk corpus runs"). A directory / device / FIFO / missing
# path is not a brief, and a path that LOOKS handover-rooted but resolves outside
# the root is not a handover brief either — refuse both so the ledger line
# (resolved path + byte size) is an honest record of what left the machine.
[ -f "$pf" ] || refuse "'$prompt_file' (resolves to '$pf') is not a regular file — the gate admits exactly ONE regular file per dispatch (a directory, device or missing path is refused)"
case "$prompt_file" in /*|[A-Za-z]:*) lex="$prompt_file" ;; *) lex="$PWD/$prompt_file" ;; esac
if [ -n "$handover_root" ] && _under "$lex" "$hr_raw" && ! _under "$pf" "$handover_root"; then
    refuse "'$prompt_file' sits under the handover root but resolves to '$pf', outside the handover root — refusing a symlink/'..' escape rather than classifying it as un-gated"
fi
ident="$(_ident "$pf")" || refuse "cannot stat '$pf' — a snapshot needs the file's identity to detect a swap"
# _canon resolved every symlink, so a link here means the path was swapped after
# canonicalisation; stat did not follow it but wc/cat would — refuse it.
[ ! -L "$pf" ] || refuse "'$pf' became a symlink after it was classified — refusing a swapped prompt file"
size="$(wc -c < "$pf" 2>/dev/null | tr -d ' ')"
case "$size" in ''|*[!0-9]*) refuse "cannot read the size of '$pf' — a permitted gated dispatch must record its byte size" ;; esac

corpus=""
d="$(dirname "$pf")"
while :; do   # .salus marker walk (PHI tree)
    if [ -e "$d/.salus" ]; then corpus="salus"; break; fi
    [ "$d" = "/" ] || [ "$d" = "." ] || [ "$(dirname "$d")" = "$d" ] && break
    d="$(dirname "$d")"
done
if [ -z "$corpus" ] && [ -n "$handover_root" ] && _under "$pf" "$handover_root" \
   && ! { [ -n "$luna_root" ] && _under "$luna_root" "$handover_root" && _under "$pf" "$luna_root"; }; then
    # Handover state NESTED in the vault (luna/handovers) is handover-state, not
    # luna-personal: the matrix carries a brief-scoped cell for exactly worker
    # briefs. The exception is a prompt INSIDE the vault when the handover root
    # IS (or contains) the vault root — the vault's stricter corpus must win for
    # those files only; a handover file outside the vault stays handover-state.
    corpus="handover-state"
fi
if [ -z "$corpus" ] && [ -n "$luna_root" ] && _under "$pf" "$luna_root"; then
    if _under "$pf" "$luna_root/Clippings"; then corpus="luna-clippings"; else corpus="luna-personal"; fi
fi
[ -n "$corpus" ] || { take_snapshot; exit 0; }   # not a gated corpus (public code / unclassified)

# --- provider: hermes name -> matrix name. Unknown names pass through verbatim
# and fall to the matrix `default: deny` (fail closed). ---
[ -n "$provider" ] || refuse "prompt file is in corpus \"$corpus\" but no --provider was given — hermes would route by its own profile default / model alias, which this gate cannot see. Pass an explicit --provider (sanctioned for this corpus per scripts/guardrails/egress-matrix.json)."
case "$(_lc "$provider")" in
    alibaba-coding-plan) mprov="alibaba" ;;
    zai)                 mprov="zai-glm" ;;
    ollama)              mprov="local-ollama" ;;
    gemini)              mprov="google-gemini" ;;
    *)                   mprov="$(_lc "$provider")" ;;
esac

# --- evaluate through the shared evaluator (fail closed on ANY problem) ---
[ -f "$EVAL" ] || refuse "egress-matrix evaluator not found ($EVAL) — cannot evaluate corpus \"$corpus\" x provider \"$mprov\""
command -v node >/dev/null 2>&1 || refuse "node not found — cannot run the egress-matrix evaluator"
line="$(node "$EVAL" "$corpus" "$mprov" "$PURPOSE" 2>/dev/null)" || refuse "egress-matrix evaluator failed for corpus \"$corpus\" x provider \"$mprov\""
verdict="${line%%$'\t'*}"
note="${line#*$'\t'}"

case "$verdict" in
    allow|allow+log) : ;;
    conditional)
        # Brief-scoped cell: task briefs through the guarded dispatch chokepoint,
        # one prompt file per run. This gate IS that chokepoint and the prompt is
        # always a single file, so the condition holds — but only for this cell.
        if [ "$corpus" != "handover-state" ] || [ "$mprov" != "openai-codex" ]; then
            refuse "corpus \"$corpus\" x provider \"$mprov\" is conditional (${note}) and this gate cannot verify that condition — refusing"
        fi ;;
    *) refuse "corpus \"$corpus\" x provider \"$mprov\" x purpose \"$PURPOSE\" is \"$verdict\" in the egress matrix (${note}). Sanctioned providers for this corpus are listed in scripts/guardrails/egress-matrix.json; for public code, pass a prompt file outside the vault/handover trees." ;;
esac

# --- snapshot, then the audit line for a permitted gated dispatch (the ledger
# hashes the SNAPSHOT — the bytes that will leave the machine); unwritable => refuse ---
take_snapshot
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || refuse "cannot create the egress ledger directory for '$LEDGER' — a permitted gated dispatch must leave an audit line"
# JSON.stringify (node is already required above) so a path with control
# characters, quotes or backslashes still yields one valid JSONL line.
node -e 'const fs=require("fs"),c=require("crypto");const b=fs.readFileSync(process.argv[8]);process.stdout.write(JSON.stringify({ts:process.argv[1],corpus:process.argv[2],provider:process.argv[3],purpose:process.argv[4],verdict:process.argv[5],prompt:process.argv[6],bytes:Number(process.argv[7]),sha256:c.createHash("sha256").update(b).digest("hex")})+"\n")' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$corpus" "$mprov" "$PURPOSE" "$verdict" "$pf" "$size" "${snapshot:-$pf}" \
    >> "$LEDGER" 2>/dev/null || refuse "cannot append to the egress ledger '$LEDGER' — a permitted gated dispatch must leave an audit line"
exit 0
