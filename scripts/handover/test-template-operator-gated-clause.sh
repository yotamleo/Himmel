#!/usr/bin/env bash
# HIMMEL-2369 — every emitted next-session / mission doc must carry the
# operator-gated wrap clause.
#
# Why a test and not just prose: HIMMEL-1719 showed that the same paragraph
# copied into N templates silently drifts — the launch preamble lost its copy
# in essentially every autonomously emitted session for ~2 months before
# anyone noticed. The lesson banked there was "one source, tested presence",
# so the canonical clause text lives HERE, once, and this suite asserts every
# next-session template contains it verbatim. Edit the clause here and the
# templates fail until they match; edit a template alone and it fails too.
#
# Usage: bash scripts/handover/test-template-operator-gated-clause.sh
# Exit:  0 = every template carries the clause, 1 = at least one does not.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TEMPLATES="$ROOT/marketplace/plugins/handover/templates"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "[OK] $1"; }
ko() { fail=$((fail + 1)); echo "[FAIL] $1"; }

# The canonical clause. Byte-identical in every *-next-session.md template.
# Quoted here-doc: nothing inside is expanded, so the backticks and $ below are
# literal text.
CLAUSE=$(cat <<'CLAUSE_EOF'
## Operator-Gated Wrap

If your only remaining dependency is an operator action, **wrap at once** — do
not idle-wait. Append a RESUME BRIEF to this file (worktree, branch, base SHA,
dirty paths, the verbatim operator block, the ordered remaining steps), release
the queue lock, message the console `OPERATOR-GATED, wrapped, safe to close`,
and end the turn. **Never idle-wait for the operator** — an idle leg holds the
queue lock, burns its prompt cache and emits no signal, so it is
indistinguishable from a crashed one. The console resumes it from that brief
(`bash scripts/handover/leg-resume-brief.sh <this file>` regenerates the
skeleton from git) instead of waking a cold session to ask.

"End the turn" means the session actually **ends** — the harness exits. A
message announcing that you are closing is not closing: a leg that says
"safe to close" and stays resident holds its RAM, keeps its queue lock, and
still reads as live in `ListAgents`. If you cannot end your own session,
say exactly that in your final message so the console can list you for the
operator instead of assuming you are gone.
CLAUSE_EOF
)

# Positive control: a broken here-doc would leave CLAUSE empty and make every
# containment check below vacuously true.
clause_lines=$(printf '%s\n' "$CLAUSE" | wc -l)
if [ "$clause_lines" -ge 16 ]; then
  ok "canonical clause loaded ($clause_lines lines)"
else
  ko "canonical clause did not load ($clause_lines lines) — every check below would be vacuous"
  echo "Total: pass=$pass fail=$fail"
  exit 1
fi

shopt -s nullglob
templates=("$TEMPLATES"/*-next-session.md)
shopt -u nullglob

if [ "${#templates[@]}" -eq 0 ]; then
  ko "no *-next-session.md templates found under $TEMPLATES"
  echo "Total: pass=$pass fail=$fail"
  exit 1
fi
ok "found ${#templates[@]} next-session templates"

# Contiguous-block containment, CRLF-tolerant (templates land on Windows too).
carries_clause() {
  local body
  body=$(tr -d '\r' < "$1")
  [[ "$body" == *"$CLAUSE"* ]]
}

for t in "${templates[@]}"; do
  rel="${t#"$ROOT"/}"
  if carries_clause "$t"; then
    ok "$rel carries the operator-gated wrap clause"
  else
    ko "$rel is MISSING the clause (or it has drifted from the canonical text in this suite)"
  fi
done

# Negative control: prove the check can actually fail.
tmp=$(mktemp "${TMPDIR:-/tmp}/clause-negctrl.XXXXXX") || { ko "negative control: mktemp failed"; echo "Total: pass=$pass fail=$fail"; exit 1; }
printf 'no clause here\n' > "$tmp"
if carries_clause "$tmp"; then
  ko "negative control: a clause-free file was reported as carrying the clause"
else
  ok "negative control: clause-free file correctly reported as missing"
fi
rm -f "$tmp"

echo "Total: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
