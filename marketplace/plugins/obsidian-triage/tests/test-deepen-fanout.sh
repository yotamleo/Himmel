#!/usr/bin/env bash
# Fixture-gated acceptance test for github source fan-out on promotion (LUNA-89).
#
# Contract: when a github _evidence/ clip is promoted to a Tech subject, the
# subject lands with a `## References` scaffold ready for deepening (the actual
# one-hop crawl is the /deepen-subject network runbook) AND the corresponding
# `Clippings/_deferred.md` tail-skipped row CLEARS (claimed by the new subject).
# Ledger-tracked + reversible: --revert restores the deferred rows verbatim.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$PLUGIN_DIR/tools/synthesize-stubs.mjs"

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
EV="$tmp/Clippings/_evidence"
mkdir -p "$EV" "$tmp/30-Resources/Tech"

ghclip() { # $1=file $2=author $3=repo-url $4=tag
  cat > "$EV/$1" <<EOF
---
type: research
source: "$3"
author: $2
processed: true
evidence_kind:
  - tools
tags:
  - $4
---
github clip $1
EOF
}
ghclip gh1.md "Acme Dev" "https://github.com/acme/agent-kit"     "agent-frameworks"
ghclip gh2.md "Zeta Dev" "https://github.com/zeta/orchestrator"  "agent-frameworks"

DEFERRED="$tmp/Clippings/_deferred.md"
cat > "$DEFERRED" <<'EOF'
---
type: pipeline-deferred
generated_at: 2026-06-20
generated_by: /archive-clips
---

# Deferred — clipper pipeline backlog

## Tail-skipped refs (luna-ingest --limit cap)
- [ ] acme/agent-kit — 178 refs beyond --limit; re-run `/luna-ingest https://github.com/acme/agent-kit --limit 200`
- [ ] zeta/orchestrator — 89 refs beyond --limit; re-run `/luna-ingest https://github.com/zeta/orchestrator --limit 200`
- [ ] other/unrelated — 12 refs beyond --limit; re-run `/luna-ingest https://github.com/other/unrelated --limit 200`
EOF

LEDGER="$tmp/.synthesize-stubs.ledger.jsonl"

echo "Test group 1: apply (Tech promotion + deferred claim)"
out1="$(node "$TOOL" "$tmp" --apply 2>&1)"
printf '%s\n' "$out1"

stub="$tmp/30-Resources/Tech/Agent Frameworks.md"
if [ -f "$stub" ]; then f=yes; else f=no; fi
assert "Tech subject stub created" "yes" "$f"

if grep -qF 'deepen_pending: true' "$stub" 2>/dev/null; then f=yes; else f=no; fi
assert "Tech stub marked deepen_pending: true" "yes" "$f"

if grep -qF '## References' "$stub" 2>/dev/null; then f=yes; else f=no; fi
assert "Tech stub has ## References scaffold" "yes" "$f"

# Both matching tail-skipped rows claimed (checkbox flipped, subject linked).
acme_done="$(grep -cE '^\- \[x\] acme/agent-kit' "$DEFERRED" 2>/dev/null || echo 0)"
assert "acme/agent-kit tail-skipped row cleared" "1" "$acme_done"

zeta_done="$(grep -cE '^\- \[x\] zeta/orchestrator' "$DEFERRED" 2>/dev/null || echo 0)"
assert "zeta/orchestrator tail-skipped row cleared" "1" "$zeta_done"

# Unrelated row untouched.
other_open="$(grep -cE '^\- \[ \] other/unrelated' "$DEFERRED" 2>/dev/null || echo 0)"
assert "unrelated tail-skipped row untouched" "1" "$other_open"

# Claimed rows link the subject.
if grep -qF 'Agent Frameworks' "$DEFERRED"; then f=yes; else f=no; fi
assert "claimed rows reference the promoting subject" "yes" "$f"

if grep -qF '"action":"deferred-claim"' "$LEDGER" 2>/dev/null; then f=yes; else f=no; fi
assert "ledger records deferred-claim" "yes" "$f"

echo "Test group 2: revert (deferred rows restored)"
node "$TOOL" "$tmp" --revert "$LEDGER" >/dev/null 2>&1
acme_open="$(grep -cE '^\- \[ \] acme/agent-kit' "$DEFERRED" 2>/dev/null || echo 0)"
assert "acme row restored to open after revert" "1" "$acme_open"

if [ -f "$stub" ]; then f=present; else f=removed; fi
assert "Tech stub removed after revert" "removed" "$f"

if grep -qF 'Agent Frameworks' "$DEFERRED"; then f=present; else f=clean; fi
assert "subject link removed from deferred on revert" "clean" "$f"

echo ""
echo "test-deepen-fanout: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
