#!/usr/bin/env bash
# Drift guard: block a commit where AGENTS.md is stale vs CLAUDE.md (HIMMEL-471).
# AGENTS.md is generated from CLAUDE.md (scripts/agents-md/generate.mjs); this
# keeps the two from drifting. himmel-dev-only (gated by .himmel-dev, mirrors
# doc-guard) — no-op in adopter clones. Fires only when CLAUDE.md / AGENTS.md /
# scripts/agents-md/* is staged. rc: 0 pass | 1 stale | 2 cannot-evaluate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$SCRIPT_DIR/../agents-md/generate.mjs"

# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ agents-md-fresh: cannot source guardrails/lib.sh — fail-closed" >&2; exit 2
fi
rc=0; is_himmel_dev_repo || rc=$?
[ "$rc" -eq 2 ] && { echo "→ agents-md-fresh: cannot resolve repo root — fail-closed" >&2; exit 2; }
[ "$rc" -eq 1 ] && exit 0   # not a himmel-dev checkout → no-op (mirrors doc-guard)
if [ "${AGENTS_MD_OK:-0}" = "1" ]; then
    echo "→ agents-md-fresh: AGENTS_MD_OK=1 — skipping (verify AGENTS.md manually)" >&2; exit 0
fi

# Trigger only when an input that affects AGENTS.md is staged.
staged=$(git diff --cached --name-only)
if ! printf '%s\n' "$staged" | grep -qE '^CLAUDE\.md$|^AGENTS\.md$|^scripts/agents-md/'; then
    exit 0
fi

[ -f "$GEN" ] || { echo "→ agents-md-fresh: generator missing ($GEN) — fail-closed" >&2; exit 2; }

# Validate the STAGED index content — the bytes that will actually be committed
# — NOT the working tree. A partial `git add CLAUDE.md` (without the regenerated
# AGENTS.md) must be caught even when the working tree happens to be consistent.
# Index path specs (`:path`) are repo-root-relative regardless of cwd.
tmpd=$(mktemp -d) || { echo "→ agents-md-fresh: mktemp failed — fail-closed" >&2; exit 2; }
trap 'rm -rf "$tmpd"' EXIT

if ! git show ":CLAUDE.md" > "$tmpd/CLAUDE.md" 2>/dev/null; then
    echo "→ agents-md-fresh: CLAUDE.md not in index — fail-closed" >&2; exit 2
fi
if ! git show ":AGENTS.md" > "$tmpd/AGENTS.md" 2>/dev/null; then
    # A generator input is staged but AGENTS.md is absent from the index → the
    # regenerated file was never staged (drift). Block as stale, not cannot-eval.
    cat >&2 <<'EOF'
⛔ agents-md-fresh: AGENTS.md is missing from the commit (not staged).
   Fix: node scripts/agents-md/generate.mjs --write   (then stage AGENTS.md)
EOF
    exit 1
fi
# preamble + debrand: prefer the STAGED copy, else the generator's working-tree
# siblings (unchanged inputs aren't in the staged set). `if` exempts set -e.
pre="$SCRIPT_DIR/../agents-md/preamble.md"; deb="$SCRIPT_DIR/../agents-md/debrand.json"
if git show ":scripts/agents-md/preamble.md" > "$tmpd/preamble.md" 2>/dev/null; then pre="$tmpd/preamble.md"; fi
if git show ":scripts/agents-md/debrand.json" > "$tmpd/debrand.json" 2>/dev/null; then deb="$tmpd/debrand.json"; fi

set +e
AGENTS_MD_SOURCE="$tmpd/CLAUDE.md" AGENTS_MD_TARGET="$tmpd/AGENTS.md" \
AGENTS_MD_PREAMBLE="$pre" AGENTS_MD_DEBRAND="$deb" node "$GEN" --check
gen_rc=$?
set -e
case "$gen_rc" in
  0) exit 0;;
  1) cat >&2 <<'EOF'
⛔ agents-md-fresh: AGENTS.md is STALE vs CLAUDE.md.
   Fix: node scripts/agents-md/generate.mjs --write   (then stage AGENTS.md)
   Bypass a doc-irrelevant edit with  AGENTS_MD_OK=1 git commit ...  (session env, not a prefix).
EOF
     exit 1;;
  *) echo "→ agents-md-fresh: generator cannot evaluate (see message above) — fail-closed" >&2; exit 2;;
esac
