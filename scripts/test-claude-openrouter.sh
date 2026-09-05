#!/usr/bin/env bash
# Hermetic tests for scripts/claude-openrouter (HIMMEL-1774). bash 3.2-safe.
# Twin of test-claude-routed.sh's harness, adapted for the OpenRouter lane's
# defining behavior: the egress-matrix HARD gate. The real egress matrix
# declares the `openrouter` provider with allow cells for himmel-code +
# handover-state ONLY (operator ruling, HIMMEL-1774): an unclassified cwd
# (corpus "unknown") and the vault corpora still REFUSE fail-closed against
# the REAL matrix, while a himmel-code cwd proceeds; the wildcard/fixture
# tests use CLAUDE_OPENROUTER_EGRESS_MATRIX hermetic matrices. The OpenRouter
# credit probe is pointed at a fast-failing loopback (OPENROUTER_API_BASE) so
# the suite stays hermetic + network-free.
# shellcheck disable=SC2015  # && || pattern is intentional for ternary-like behavior
set -u
FAILS=0
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/claude-openrouter"
REAL_MATRIX="$HERE/guardrails/egress-matrix.json"

t() { # t <name> <expected-exit> — runs launcher in the prepared sandbox.
  # OR_CWD (optional) pins CLAUDE_OPENROUTER_CWD so the egress consult
  # classifies a chosen corpus without the test having to chdir there.
  local name="$1" want="$2"; shift 2
  ( cd "$WORK" && HOME="$FAKEHOME" PATH="$BIN:$PATH" OPENROUTER_API_KEY="${KEY-}" \
      CLAUDE_OPENROUTER_DOTENV_ROOT="$WORK" \
      CLAUDE_OPENROUTER_EGRESS_MATRIX="${MATRIX-$REAL_MATRIX}" \
      CLAUDE_OPENROUTER_CWD="${OR_CWD-}" \
      OPENROUTER_API_BASE="${API_BASE-}" \
      bash "$LAUNCHER" "$@" >"$WORK/out.txt" 2>&1 )
  local got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $name (exit $got, want $want)"; cat "$WORK/out.txt"; FAILS=$((FAILS+1))
  else
    echo "ok: $name"
  fi
}

setup() { # fresh sandbox: fake HOME with minimal ~/.claude, mock claude in BIN
  FAKEHOME="$(mktemp -d)"; WORK="$(mktemp -d)"; BIN="$(mktemp -d)"
  MATRIX=""   # empty -> t() defaults to the REAL matrix (no openrouter cell)
  API_BASE="http://127.0.0.1:1/api/v1"   # fast-failing loopback -> credit UNKNOWN, no network
  mkdir -p "$FAKEHOME/.claude"
  printf '{"model":"claude-fable-5[1m]","env":{"ANTHROPIC_MODEL":"x","HIMMEL_INITIATIVE":"1"}}' \
    > "$FAKEHOME/.claude/settings.json"
  printf 'secret' > "$FAKEHOME/.claude/.credentials.json"
  mkdir -p "$FAKEHOME/.claude/plugins/claude-hud"
  printf '{"hud":true}\n' > "$FAKEHOME/.claude/plugins/claude-hud/config.json"
  cat > "$BIN/claude" <<'MOCK'
#!/usr/bin/env bash
# Launch dumps env and records the passthrough argv. A magic --mock-exit-N arg
# makes the mock exit N so exit-code propagation is provable.
env > "${MOCK_ENV_OUT:?}"
printf '%s\n' "$*" >> "${MOCK_ARGV_OUT:?}"
for a in "$@"; do
  case "$a" in --mock-exit-*) exit "${a#--mock-exit-}" ;; esac
done
exit 0
MOCK
  chmod +x "$BIN/claude"
  export MOCK_ENV_OUT="$WORK/child-env.txt"
  export MOCK_ARGV_OUT="$WORK/claude-argv.txt"
}

# A hermetic matrix that DECLARES openrouter + an explicit allow cell (the only
# shape under which the lane may proceed). write_allow_matrix <path>.
write_allow_matrix() {
  cat > "$1" <<'JSON'
{ "providers": { "openrouter": { "region": "US", "note": "test fixture" } },
  "rules": [ { "corpus": "*", "provider": "openrouter", "purpose": "*", "verdict": "allow", "why": "test" } ],
  "default": "deny" }
JSON
}

# A hermetic matrix that DECLARES openrouter but offers ONLY a wildcard-provider
# allow (provider:"*", never provider:"openrouter"). The lane must STILL refuse —
# a wildcard allow does not authorize a new third-party path. write_wildcard_matrix <path>.
write_wildcard_matrix() {
  cat > "$1" <<'JSON'
{ "providers": { "openrouter": { "region": "US", "note": "test fixture" } },
  "rules": [ { "corpus": "*", "provider": "*", "purpose": "*", "verdict": "allow", "why": "wildcard must not authorize openrouter" } ],
  "default": "deny" }
JSON
}

# CR round 2 (HIMMEL-1774): purpose-scoped fixtures. The matrix's rules are
# (corpus, provider, purpose) cells and the launcher performs INFERENCE, so an
# allow scoped to a DIFFERENT purpose must not authorize the lane, while an
# explicit "inference" cell must (the "*" case is write_allow_matrix above).
write_other_purpose_matrix() {
  cat > "$1" <<'JSON'
{ "providers": { "openrouter": { "region": "US", "note": "test fixture" } },
  "rules": [ { "corpus": "*", "provider": "openrouter", "purpose": "embedding", "verdict": "allow", "why": "test" } ],
  "default": "deny" }
JSON
}

write_inference_purpose_matrix() {
  cat > "$1" <<'JSON'
{ "providers": { "openrouter": { "region": "US", "note": "test fixture" } },
  "rules": [ { "corpus": "*", "provider": "openrouter", "purpose": "inference", "verdict": "allow", "why": "test" } ],
  "default": "deny" }
JSON
}

# CR round 4 (HIMMEL-1774): first-match-wins fixtures. An explicit deny placed
# ABOVE a later permissive openrouter row must win — the real matrix depends on
# that ordering, and a gate that scanned past the deny for a later allow would
# silently void every explicit vault deny the moment a wildcard-corpus allow is
# ratified. write_deny_then_allow_matrix <path>.
write_deny_then_allow_matrix() {
  cat > "$1" <<'JSON'
{ "providers": { "openrouter": { "region": "US", "note": "test fixture" } },
  "rules": [ { "corpus": "*", "provider": "openrouter", "purpose": "*", "verdict": "deny", "why": "earlier deny must win" },
             { "corpus": "*", "provider": "openrouter", "purpose": "*", "verdict": "allow", "why": "later allow must NOT override" } ],
  "default": "deny" }
JSON
}

# A "conditional" cell is permitted ONLY while its condition holds; this
# launcher cannot evaluate matrix conditions, so it must fail closed rather than
# treat the cell as an unconditional allow. write_conditional_matrix <path>.
write_conditional_matrix() {
  cat > "$1" <<'JSON'
{ "providers": { "openrouter": { "region": "US", "note": "test fixture" } },
  "rules": [ { "corpus": "*", "provider": "openrouter", "purpose": "*", "verdict": "conditional", "condition": "a condition this launcher cannot evaluate", "why": "test" } ],
  "default": "deny" }
JSON
}

# --- T1: missing key -> exit 2, claude never launched
setup; KEY=""
t "missing key exits 2" 2
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched without key"; FAILS=$((FAILS+1)); }

# --- T2 (CENTERPIECE): the real matrix allows ONLY himmel-code + handover-state
# (HIMMEL-1774 operator ruling). An UNCLASSIFIED cwd (temp dir -> corpus
# "unknown") refuses fail-closed with exit 3, claude never launched, and the
# message names the corpus with no permitting cell.
setup; KEY="or-test-123"
t "real matrix refuses unclassified cwd fail-closed" 3
grep -q "REFUSED" "$WORK/out.txt" || { echo "FAIL: no REFUSED line"; FAILS=$((FAILS+1)); }
grep -qi "no egress-matrix cell permits" "$WORK/out.txt" || { echo "FAIL: refusal does not name the unpermitted corpus"; FAILS=$((FAILS+1)); }
grep -qi "unknown" "$WORK/out.txt" || { echo "FAIL: refusal does not name the unknown corpus"; FAILS=$((FAILS+1)); }
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched past the egress refusal"; FAILS=$((FAILS+1)); }

# --- T2d: the DECLARED real-matrix cell authorizes a himmel-code cwd (the
# ruling's first allow). CLAUDE_OPENROUTER_CWD pins the corpus classification
# to this checkout without chdir-ing the harness out of its sandbox.
setup; KEY="or-test-123"; OR_CWD="$HERE/.."
t "real matrix allows himmel-code cwd (declared cell)" 0
grep -q "ANTHROPIC_AUTH_TOKEN=or-test-123" "$WORK/child-env.txt" || { echo "FAIL: declared cell did not launch himmel-code"; FAILS=$((FAILS+1)); }

# --- T2e: the real matrix DENIES a luna vault cwd even with the provider
# declared (vault corpora stay DENY per the ruling; the explicit deny row, not
# the wildcard, is what a future rule cannot silently shadow).
setup; KEY="or-test-123"
mkdir -p "$WORK/vault"
SAVED_LVP="${LUNA_VAULT_PATH-}"
LUNA_VAULT_PATH="$WORK/vault"; export LUNA_VAULT_PATH
OR_CWD="$WORK/vault"
t "real matrix denies luna vault cwd (vault DENY)" 3
grep -q "REFUSED" "$WORK/out.txt" || { echo "FAIL: no REFUSED line for luna cwd"; FAILS=$((FAILS+1)); }
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: claude launched from a luna vault cwd"; FAILS=$((FAILS+1)); }
if [ -n "$SAVED_LVP" ]; then LUNA_VAULT_PATH="$SAVED_LVP"; export LUNA_VAULT_PATH; else unset LUNA_VAULT_PATH; fi
unset OR_CWD

# --- T2b: --force does NOT bypass the egress gate (no proceed-anyway override)
setup; KEY="or-test-123"
t "egress refusal survives --force" 3 --force
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: --force bypassed the egress refusal"; FAILS=$((FAILS+1)); }

# --- T2c: declaring the provider alone is NOT enough — a wildcard-provider allow
# (provider:"*") must not authorize the new third-party path. Only an EXPLICIT
# provider:"openrouter" rule permits the lane.
setup; KEY="or-test-123"
write_wildcard_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "wildcard-provider allow still refuses" 3
grep -qi "no egress-matrix cell permits" "$WORK/out.txt" || { echo "FAIL: wildcard refusal message wrong"; FAILS=$((FAILS+1)); }
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: wildcard allow let the lane proceed"; FAILS=$((FAILS+1)); }

# --- T3: declared openrouter + explicit allow cell -> exit 0 and the full env
# contract reaches the child (base URL = Anthropic endpoint, auth from the key,
# Claude 1M model pin, 1M auto-compact window, per-lane config dir).
setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "declared cell launches" 0
for pair in \
  "ANTHROPIC_BASE_URL=https://openrouter.ai/api" \
  "ANTHROPIC_AUTH_TOKEN=or-test-123" \
  "ANTHROPIC_MODEL=anthropic/claude-opus-5" \
  "ANTHROPIC_DEFAULT_HAIKU_MODEL=anthropic/claude-opus-5" \
  "ANTHROPIC_DEFAULT_SONNET_MODEL=anthropic/claude-opus-5" \
  "ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic/claude-opus-5" \
  "CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000" \
  "CLAUDE_CONFIG_DIR=$FAKEHOME/.claude-openrouter"; do
  grep -qF "$pair" "$WORK/child-env.txt" || { echo "FAIL: child env missing $pair"; FAILS=$((FAILS+1)); }
done
# ANTHROPIC_API_KEY must reach the child EXPLICITLY EMPTY (whole-line match): the
# empty key is load-bearing — it is what forces the SDK onto the OpenRouter path
# (verified 2026-08-15; every OpenRouter Claude Code example carries this shape).
grep -qxF "ANTHROPIC_API_KEY=" "$WORK/child-env.txt" || { echo "FAIL: ANTHROPIC_API_KEY not exported empty"; FAILS=$((FAILS+1)); }

# --- T3b: model pin — the pinned model is a Claude slug AND the window is the 1M
# tier (the HIMMEL-1774 §5 requirement).
setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "model pin is a Claude 1M tier" 0
grep -qE "ANTHROPIC_MODEL=anthropic/claude" "$WORK/child-env.txt" || { echo "FAIL: model is not a Claude slug"; FAILS=$((FAILS+1)); }
grep -qF "CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000" "$WORK/child-env.txt" || { echo "FAIL: context window is not the 1M tier"; FAILS=$((FAILS+1)); }

# --- T3c: OPENROUTER_MODEL override reaches the child verbatim
setup; KEY="or-test-123"; export OPENROUTER_MODEL="anthropic/claude-sonnet-5"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "model override launches" 0
grep -qF "ANTHROPIC_MODEL=anthropic/claude-sonnet-5" "$WORK/child-env.txt" || { echo "FAIL: OPENROUTER_MODEL override did not reach child"; FAILS=$((FAILS+1)); }
unset OPENROUTER_MODEL

# --- T3d: OPENROUTER_ANTHROPIC_BASE_URL override reaches the child
setup; KEY="or-test-123"; export OPENROUTER_ANTHROPIC_BASE_URL="http://127.0.0.1:7777"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "base-url override launches" 0
grep -qF "ANTHROPIC_BASE_URL=http://127.0.0.1:7777" "$WORK/child-env.txt" || { echo "FAIL: base-url override did not reach child"; FAILS=$((FAILS+1)); }
unset OPENROUTER_ANTHROPIC_BASE_URL

# --- T3e: an ambient non-empty ANTHROPIC_API_KEY is NEUTRALIZED — the launcher
# exports it empty regardless of what the calling shell carries (an inherited
# key would pull the SDK back onto its Anthropic-native auth path).
setup; KEY="or-test-123"; export ANTHROPIC_API_KEY="sk-ant-ambient-999"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "ambient ANTHROPIC_API_KEY neutralized to empty" 0
grep -qxF "ANTHROPIC_API_KEY=" "$WORK/child-env.txt" || { echo "FAIL: ambient ANTHROPIC_API_KEY not neutralized"; FAILS=$((FAILS+1)); }
unset ANTHROPIC_API_KEY

# --- T3f/T3g/T3h (CR round 2): the egress gate is PURPOSE-aware. The launcher
# performs inference, so (f) an allow scoped to a DIFFERENT purpose must NOT
# authorize it (still exit 3, claude never launched, refusal names the purpose),
# (g) a purpose:"*" rule still authorizes (no regression), and (h) an explicit
# purpose:"inference" rule authorizes.
setup; KEY="or-test-123"
write_other_purpose_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "other-purpose allow still refuses" 3
grep -qi "no egress-matrix cell permits" "$WORK/out.txt" || { echo "FAIL: wrong refusal message for other-purpose cell"; FAILS=$((FAILS+1)); }
grep -qi "purpose" "$WORK/out.txt" || { echo "FAIL: refusal does not name the purpose"; FAILS=$((FAILS+1)); }
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: other-purpose allow let the lane proceed"; FAILS=$((FAILS+1)); }

setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"   # purpose: "*"
t "purpose-wildcard allow still authorizes" 0
grep -q "ANTHROPIC_AUTH_TOKEN=or-test-123" "$WORK/child-env.txt" || { echo "FAIL: purpose-* cell did not launch"; FAILS=$((FAILS+1)); }

setup; KEY="or-test-123"
write_inference_purpose_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "inference-purpose allow authorizes" 0
grep -q "ANTHROPIC_AUTH_TOKEN=or-test-123" "$WORK/child-env.txt" || { echo "FAIL: inference-purpose cell did not launch"; FAILS=$((FAILS+1)); }

# --- T3i/T3j (CR round 4): the gate honours the matrix's FIRST-MATCH-WINS
# semantics. (i) An explicit deny placed ABOVE a later permissive openrouter row
# must WIN — the real matrix relies on exactly this ordering to keep its vault
# denies effective above any future wildcard-corpus allow. (j) A "conditional"
# cell is permitted only while its condition holds, and this launcher cannot
# evaluate matrix conditions, so it must fail CLOSED rather than launch as if
# the cell were unconditional.
setup; KEY="or-test-123"
write_deny_then_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "earlier deny wins over a later permissive row" 3
grep -qi "first matching cell has verdict" "$WORK/out.txt" || { echo "FAIL: refusal does not name the deciding cell"; FAILS=$((FAILS+1)); }
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: a later allow overrode an earlier deny"; FAILS=$((FAILS+1)); }

setup; KEY="or-test-123"
write_conditional_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "conditional cell fails closed" 3
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: conditional cell launched unconditionally"; FAILS=$((FAILS+1)); }

# --- T4: key never echoed to stdout/stderr
setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "no key echo" 0
grep -q "or-test-123" "$WORK/out.txt" && { echo "FAIL: key echoed"; FAILS=$((FAILS+1)); }

# --- T5: key resolvable from a repo .env ONLY (the load_dotenv path), incl.
# surrounding-quote strip. gitleaks markers required on dummy key lines.
setup; KEY=""
printf 'OPENROUTER_API_KEY=from-dotenv-456\n' > "$WORK/.env"  # gitleaks:allow
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "key from .env launches" 0
grep -qF "ANTHROPIC_AUTH_TOKEN=from-dotenv-456" "$WORK/child-env.txt" || { echo "FAIL: .env key did not reach child"; FAILS=$((FAILS+1)); }  # gitleaks:allow

setup; KEY=""
printf 'OPENROUTER_API_KEY="quoted-val-789"\n' > "$WORK/.env"  # gitleaks:allow
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "quoted .env key launches" 0
grep -qF "ANTHROPIC_AUTH_TOKEN=quoted-val-789" "$WORK/child-env.txt" || { echo "FAIL: surrounding quotes not stripped from key"; FAILS=$((FAILS+1)); }  # gitleaks:allow

# --- T6: PHI refusal (HIMMEL-1774 §2) — .salus marker and phi-roots both refuse
# with exit 3 EVEN under a declared allow cell (PHI is absolute, no override),
# matching the sibling structure. HIMMEL-1773: the marker-based guard is inert on
# the real vault, but its STRUCTURE is what this asserts.
setup; KEY="or-test-123"; touch "$WORK/.salus"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "salus refuses despite declared cell" 3
t "salus refuses despite declared cell + --force" 3 --force

setup; KEY="or-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\n' "$WORK" > "$FAKEHOME/.config/claude-glm/phi-roots"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "phi-root refuses despite declared cell + --force" 3 --force

# --- T7: egress-denylist -> refuse without --force, proceed with it (under a
# declared cell). The path denylist keeps the --force override the siblings carry;
# the egress MATRIX does not (T2b).
setup; KEY="or-test-123"
mkdir -p "$FAKEHOME/.config/claude-glm"
printf '%s\n' "$WORK" > "$FAKEHOME/.config/claude-glm/egress-denylist"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "denylist refuses under declared cell" 3
t "denylist + --force proceeds under declared cell" 0 --force

# --- T8: a broken/missing node fails CLOSED — the egress matrix cannot be
# consulted, so claude is NEVER launched un-audited (HIMMEL-1771 fail-open class).
# Simulated with a node shim that exits 127 (command -v still finds it, so the
# presence guard passes; the consultation then propagates the nonzero exit).
setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
cat > "$BIN/node" <<'NODESHIM'
#!/usr/bin/env bash
exit 127
NODESHIM
chmod +x "$BIN/node"
( cd "$WORK" && HOME="$FAKEHOME" PATH="$BIN:$PATH" OPENROUTER_API_KEY="$KEY" \
    CLAUDE_OPENROUTER_DOTENV_ROOT="$WORK" CLAUDE_OPENROUTER_EGRESS_MATRIX="$MATRIX" \
    OPENROUTER_API_BASE="$API_BASE" bash "$LAUNCHER" >"$WORK/out.txt" 2>&1 )
t8_rc=$?
if [ "$t8_rc" -eq 0 ]; then echo "FAIL: broken node launched (exit 0)"; cat "$WORK/out.txt"; FAILS=$((FAILS+1)); else echo "ok: broken node fails closed (rc=$t8_rc)"; fi
[ ! -f "$WORK/child-env.txt" ] || { echo "FAIL: launched claude with a broken node"; FAILS=$((FAILS+1)); }
rm -f "$BIN/node"

# --- T9: credit surfacing is advisory + loud-on-unknown — a query failure prints
# UNKNOWN and the launch STILL proceeds (exit 0). Fast-failing loopback API base.
setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "credit UNKNOWN surfaced + launch proceeds" 0
grep -qi "remaining metered credit: UNKNOWN" "$WORK/out.txt" || { echo "FAIL: no loud UNKNOWN credit line"; FAILS=$((FAILS+1)); }

# --- T10: claude flags pass through verbatim; leading --reseed is consumed
setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "passthrough launch" 0 --reseed -p hello -d
grep -qF -- "-p hello -d" "$WORK/claude-argv.txt" || { echo "FAIL: claude flags not passed verbatim"; FAILS=$((FAILS+1)); }
grep -qF -- "--reseed" "$WORK/claude-argv.txt" && { echo "FAIL: --reseed leaked to claude argv"; FAILS=$((FAILS+1)); }

# --- T11: launcher propagates claude's exit code
setup; KEY="or-test-123"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "exit code propagates from claude" 7 --mock-exit-7

# --- T12: first launch under a declared cell seeds the config dir; credentials
# NEVER copied.
setup; KEY="or-test-123"
mkdir -p "$FAKEHOME/.claude/commands" "$FAKEHOME/.claude/plugins/marketplaces"
printf 'x' > "$FAKEHOME/.claude/CLAUDE.md"
printf '{}' > "$FAKEHOME/.claude/plugins/installed_plugins.json"
write_allow_matrix "$WORK/matrix.json"; MATRIX="$WORK/matrix.json"
t "seed on first launch under declared cell" 0
[ -f "$FAKEHOME/.claude-openrouter/plugins/claude-hud/config.json" ] || { echo "FAIL: claude-hud config not seeded"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-openrouter/CLAUDE.md" ] || { echo "FAIL: CLAUDE.md not seeded"; FAILS=$((FAILS+1)); }
[ -f "$FAKEHOME/.claude-openrouter/plugins/installed_plugins.json" ] || { echo "FAIL: plugin registry not seeded"; FAILS=$((FAILS+1)); }
[ ! -f "$FAKEHOME/.claude-openrouter/.credentials.json" ] || { echo "FAIL: credentials copied"; FAILS=$((FAILS+1)); }
grep -R "or-test-123" "$FAKEHOME/.claude-openrouter" >/dev/null 2>&1 && { echo "FAIL: key leaked into config dir"; FAILS=$((FAILS+1)); }

echo; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || { echo "$FAILS failure(s)"; exit 1; }
