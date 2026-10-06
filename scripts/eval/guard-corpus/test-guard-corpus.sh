#!/usr/bin/env bash
# scripts/eval/guard-corpus/test-guard-corpus.sh - suite for gen + diff
# (HIMMEL-4168). Proves:
#   1. gen is deterministic (same seed + seeds file => same bytes)
#   2. diff flags a planted base-deny/head-allow row, using two tiny STUB hooks
#      (never a real hook)
#   3. diff flags a planted slow stub as a TIMEOUT RISK
#   4. neither tool ever execs a generated command (a sentinel-file assertion)
#   5. gen --seeds-file applies transforms to a supplied (benign) seed
#
# The stub hooks here deny on a harmless sentinel token so no attack string is
# authored. Run via:
#   bash scripts/quiet-run.sh suite -- bash scripts/eval/guard-corpus/test-guard-corpus.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
GEN="$HERE/gen"
DIFF="$HERE/diff"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/guard-corpus-test.XXXXXX")" || {
  echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HIMMEL_EVAL_RUNS_LEDGER="$TMP/eval-runs.jsonl"   # HIMMEL-4647: never the live ledger

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in output";; esac; }
hasnt() { case "$2" in *"$3"*) fail "$1: unexpected '$3' in output";; *) pass "$1";; esac; }

# --- 1. determinism -----------------------------------------------------------
python3 "$GEN" --seed 4168 -o "$TMP/a.jsonl"
python3 "$GEN" --seed 4168 -o "$TMP/b.jsonl"
if cmp -s "$TMP/a.jsonl" "$TMP/b.jsonl"; then pass "determinism: same seed, same bytes"
else fail "determinism: same seed produced different bytes"; fi
python3 "$GEN" --seed 9999 -o "$TMP/c.jsonl"
if cmp -s "$TMP/a.jsonl" "$TMP/c.jsonl"; then
  fail "determinism-control: different seed MUST differ (pad filler)"
else pass "determinism-control: different seed differs"; fi

# --- stub hooks: deny (exit 2) iff the payload command contains SENTINEL ------
# These stand in for a real guard. SENTINEL is a harmless token, not an attack.
mkdir -p "$TMP/scripts/hooks"
cat > "$TMP/base-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *SENTINEL_DENY*) exit 2 ;; esac
exit 0
STUB
# head hook: the REGRESSION - it no longer denies SENTINEL_DENY (allows it).
cat > "$TMP/head-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 0
STUB
# slow hook: sleeps past the warn threshold.
cat > "$TMP/slow-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sleep 2
exit 0
STUB
chmod +x "$TMP/base-hook.sh" "$TMP/head-hook.sh" "$TMP/slow-hook.sh"

# A tiny corpus carrying one deny-expected sentinel row + benign rows.
cat > "$TMP/seeds.txt" <<'SEEDS'
planted	deny	echo SENTINEL_DENY
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/seeds.txt" -o "$TMP/corpus.jsonl"

# --- 2. planted base-deny/head-allow is flagged -------------------------------
OUT=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/head-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC=$?
has "regression: flagged" "$OUT" "base-deny/head-allow (REGRESSION): "
hasnt "regression: not zero" "$OUT" "(REGRESSION): 0"
if [ "$RC" = "1" ]; then pass "regression: exit code 1"
else fail "regression: expected exit 1, got $RC"; fi

# control: base vs base (identical) => zero regressions, exit 0
OUT2=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC2=$?
has "regression-control: zero" "$OUT2" "(REGRESSION): 0"
if [ "$RC2" = "0" ]; then pass "regression-control: exit 0"
else fail "regression-control: expected exit 0, got $RC2"; fi

# eval-runs ledger (HIMMEL-4647): each diff appends one valid row; a regression
# is a valid (ok) measurement.
LROWS=$(python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l); m=r["metrics"]
    print(r["eval"], r["status"], m["regressions"] > 0, m["deny_coverage"], r["config"]["hook"])' "$HIMMEL_EVAL_RUNS_LEDGER" 2>&1)
if [ "$LROWS" = "guard-corpus ok True 1.0 head-hook.sh
guard-corpus ok False 1.0 base-hook.sh" ]; then pass "ledger: one row per diff"
else fail "ledger: unexpected rows: $LROWS"; fi
if python3 "$HERE/../lib/eval_runs.py" validate "$HIMMEL_EVAL_RUNS_LEDGER" >/dev/null 2>&1; then pass "ledger: rows pass validate"
else fail "ledger: rows fail validate"; fi

# --- 3. planted slow stub flagged TIMEOUT RISK --------------------------------
OUT3=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/slow-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 --timeout-warn 1 2>&1)
hasnt "timeout: flagged" "$OUT3" "TIMEOUT RISK (>= 1.0s): 0"
has "timeout: line present" "$OUT3" "TIMEOUT-RISK idx="

# --- 3b. two broken hooks (rc=1 everywhere) => inconclusive, exit 3 ----------
# codex-1: a run where no base exit code is 2 and hooks error must NOT read as
# a clean verdict (exit 0); it is inconclusive (exit 3).
cat > "$TMP/broken-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 1
STUB
chmod +x "$TMP/broken-hook.sh"
python3 "$DIFF" --base "$TMP/broken-hook.sh" --head "$TMP/broken-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC_BRK=$?
if [ "$RC_BRK" = "3" ]; then pass "inconclusive: two broken hooks exit 3 (not clean)"
else fail "inconclusive: expected exit 3, got $RC_BRK"; fi

# --- 3c. base-deny + head-ERROR is inconclusive, never a regression ----------
# codex-1: a regression is base-deny paired with a CLEAN head-allow (rc 0). A
# head that errored (rc 1) did not allow the command, so base-deny/head-error
# must read as inconclusive (exit 3), not a confirmed regression (exit 1).
OUT3C=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/broken-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC3C=$?
has "base-deny/head-error: no regression" "$OUT3C" "(REGRESSION): 0"
if [ "$RC3C" = "3" ]; then pass "base-deny/head-error: inconclusive exit 3"
else fail "base-deny/head-error: expected exit 3, got $RC3C"; fi

# --- 2b. an empty corpus is refused, never certified clean -------------------
# codex-2: zero rows exercise no hook; a clean exit 0 would be a false
# "reviewed clean". diff must refuse it (exit 2).
: > "$TMP/empty-corpus.jsonl"
python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/empty-corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC_EMPTY=$?
if [ "$RC_EMPTY" = "2" ]; then pass "empty-corpus: refused (exit 2)"
else fail "empty-corpus: expected exit 2, got $RC_EMPTY"; fi

# --- 1b. inherited GIT_DIR must not redirect the scratch git setup -----------
# codex-1: GIT_DIR/GIT_WORK_TREE/... override `git -C`, so a stray one in the
# environment could send scratch init/add/commit into a real repo. diff strips
# them; prove a sentinel GIT_DIR is never created by the scratch setup.
SENTGD="$TMP/sentinel-gitdir"
GIT_DIR="$SENTGD" python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 1 >/dev/null 2>&1; RC_GD=$?
# assert the run COMPLETED cleanly first: a setup crash (exit 2) would leave
# SENTGD absent for the wrong reason, making the sentinel check vacuous. base
# vs base on a corpus whose deny seed the base denies => exit 0.
if [ "$RC_GD" = "0" ]; then pass "git-env: diff ran to completion (exit 0)"
else fail "git-env: diff did not complete clean, exit $RC_GD (sentinel check would be vacuous)"; fi
if [ ! -e "$SENTGD" ]; then pass "git-env: inherited GIT_DIR did not redirect scratch git"
else fail "git-env: scratch git honored inherited GIT_DIR ($SENTGD created)"; fi

# --- 1c. inherited core.hooksPath must NOT fire on the scratch commit ---------
# codex-1 (round 5): stripping GIT_DIR/WORK_TREE alone is not isolation --
# GIT_CONFIG_GLOBAL/SYSTEM (and the GIT_CONFIG_COUNT/KEY/VALUE set) can carry
# core.hooksPath, which git would honor on our scratch `git commit`, executing
# a real hook outside the sandbox. diff now scrubs the whole GIT_CONFIG* family
# and pins global+system config empty. Plant a global config whose hooksPath
# fires a sentinel and prove the scratch commit never runs it.
EVILHOOKS="$TMP/evil-hooks"
mkdir -p "$EVILHOOKS"
SENTHP="$TMP/sentinel-hookspath"
cat > "$EVILHOOKS/pre-commit" <<HK
#!/usr/bin/env bash
: > "$SENTHP"
HK
chmod +x "$EVILHOOKS/pre-commit"
cat > "$TMP/evil-gitconfig" <<CFG
[core]
	hooksPath = $EVILHOOKS
CFG
GIT_CONFIG_GLOBAL="$TMP/evil-gitconfig" python3 "$DIFF" \
        --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 1 >/dev/null 2>&1; RC_HP=$?
# complete-run guard: a setup crash would leave SENTHP absent for the wrong
# reason, making the sentinel check vacuous. base vs base => exit 0.
if [ "$RC_HP" = "0" ]; then pass "hookspath: diff ran to completion (exit 0)"
else fail "hookspath: diff did not complete clean, exit $RC_HP (sentinel check would be vacuous)"; fi
if [ ! -e "$SENTHP" ]; then pass "hookspath: inherited core.hooksPath did not fire on scratch commit"
else fail "hookspath: scratch commit executed inherited core.hooksPath hook ($SENTHP created)"; fi

# --- 1d. allowlist env: named escape seams never reach a launched subprocess -
# codex (round 6): a blocklist is whack-a-mole. diff launches hooks and the
# scratch git under a positive allowlist, so BASH_ENV/ENV (bash sources them at
# startup), LD_PRELOAD and GIT_TEMPLATE_DIR cannot reach a child. A probe hook
# dumps its own environment; prove none of the four seams survive. Benign
# corpus so the deny positive-control does not fire (base==head always allows).
python3 "$GEN" --seed 7 -o "$TMP/benign-probe.jsonl"
ENVDUMP="$TMP/envdump"
cat > "$TMP/probe-hook.sh" <<HK
#!/usr/bin/env bash
cat >/dev/null
env > "$ENVDUMP"
exit 0
HK
chmod +x "$TMP/probe-hook.sh"
BASH_ENV=/tmp/seam-bashenv ENV=/tmp/seam-env LD_PRELOAD=/tmp/seam.so \
GIT_TEMPLATE_DIR=/tmp/seam-template \
  python3 "$DIFF" --base "$TMP/probe-hook.sh" --head "$TMP/probe-hook.sh" \
  --corpus "$TMP/benign-probe.jsonl" --jobs 1 >/dev/null 2>&1; RC_AL=$?
if [ "$RC_AL" = "0" ]; then pass "allowlist: diff ran to completion (exit 0)"
else fail "allowlist: diff did not complete clean, exit $RC_AL (seam checks would be vacuous)"; fi
for seam in BASH_ENV ENV LD_PRELOAD GIT_TEMPLATE_DIR; do
  if [ -e "$ENVDUMP" ] && grep -q "^$seam=" "$ENVDUMP"; then
    fail "allowlist: $seam leaked into launched hook env"
  else pass "allowlist: $seam scrubbed from launched hook env"; fi
done

# --- 1e. inherited GIT_TEMPLATE_DIR must NOT seed the scratch repo's hooks ----
# codex (round 6): `git init` copies GIT_TEMPLATE_DIR/hooks into the new .git,
# which the seed commit then runs. The allowlist drops it; prove a planted
# template hook never fires on the scratch commit.
TMPL="$TMP/evil-template"
mkdir -p "$TMPL/hooks"
SENTTD="$TMP/sentinel-template"
cat > "$TMPL/hooks/pre-commit" <<HK
#!/usr/bin/env bash
: > "$SENTTD"
HK
chmod +x "$TMPL/hooks/pre-commit"
GIT_TEMPLATE_DIR="$TMPL" python3 "$DIFF" \
        --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 1 >/dev/null 2>&1; RC_TD=$?
if [ "$RC_TD" = "0" ]; then pass "template-dir: diff ran to completion (exit 0)"
else fail "template-dir: diff did not complete clean, exit $RC_TD (sentinel check would be vacuous)"; fi
if [ ! -e "$SENTTD" ]; then pass "template-dir: inherited GIT_TEMPLATE_DIR did not seed scratch hooks"
else fail "template-dir: scratch init copied+ran a template hook ($SENTTD created)"; fi

# --- 1f. inherited BASH_ENV must NOT be sourced when the hook's bash starts ---
# codex (round 6): non-interactive bash sources $BASH_ENV before the script, so
# an inherited one runs arbitrary code before the hook reads a fixture. The
# allowlist drops it; prove the planted startup script never runs.
SENTBE="$TMP/sentinel-bashenv"
cat > "$TMP/bashenv-script.sh" <<HK
: > "$SENTBE"
HK
BASH_ENV="$TMP/bashenv-script.sh" python3 "$DIFF" \
        --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 1 >/dev/null 2>&1; RC_BE=$?
if [ "$RC_BE" = "0" ]; then pass "bash-env: diff ran to completion (exit 0)"
else fail "bash-env: diff did not complete clean, exit $RC_BE (sentinel check would be vacuous)"; fi
if [ ! -e "$SENTBE" ]; then pass "bash-env: inherited BASH_ENV not sourced by hook bash"
else fail "bash-env: hook bash sourced inherited BASH_ENV ($SENTBE created)"; fi

# --- 2c. each invocation gets a fresh HOME/primary (no cross-run contamination)
# codex-2: a hook that writes state must not leak into another row or the other
# side of the comparison. This stub denies (exit 2) iff a PRIOR run in the same
# HOME planted a marker; with per-invocation fresh HOME it never sees one, so
# every run allows and nothing is spuriously denied. Benign-only corpus (no
# expect=deny rows) so the deny positive-control check does not fire.
cat > "$TMP/contaminate-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
if [ -e "$HOME/.seen" ]; then exit 2; fi
: > "$HOME/.seen"
exit 0
STUB
chmod +x "$TMP/contaminate-hook.sh"
python3 "$GEN" --seed 1 -o "$TMP/benign.jsonl"
OUT2C=$(python3 "$DIFF" --base "$TMP/contaminate-hook.sh" --head "$TMP/contaminate-hook.sh" \
        --corpus "$TMP/benign.jsonl" --jobs 1 2>&1); RC2C=$?
has "isolation: no cross-run contamination" "$OUT2C" "newly-denied: 0"
has "isolation: no stray denials" "$OUT2C" "(REGRESSION): 0"
if [ "$RC2C" = "0" ]; then pass "isolation: fresh HOME per invocation (exit 0)"
else fail "isolation: shared HOME contaminated runs, exit $RC2C"; fi

# --- 4. no code path execs a generated command (sentinel-file assertion) ------
# A seed that WOULD create a sentinel file if ever executed. diff must NOT run
# it; the file must not exist afterward. The hook only reads stdin.
SENT="$TMP/must-not-exist"
# expect=allow so the deny positive-control check (section 6) is not triggered
# here; this section only proves the command is never EXECUTED.
cat > "$TMP/exec-seeds.txt" <<SEEDS
planted	allow	touch $SENT
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/exec-seeds.txt" -o "$TMP/exec-corpus.jsonl"
python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/exec-corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC_NX=$?
# the sentinel-absent check is vacuous if diff crashed in setup before
# processing the corpus, so also assert the run actually completed clean
# (base vs base identical => exit 0).
if [ "$RC_NX" = "0" ]; then pass "no-exec: diff ran to completion (exit 0)"
else fail "no-exec: diff did not complete clean, exit $RC_NX (sentinel check would be vacuous)"; fi
if [ -e "$SENT" ]; then fail "no-exec: diff EXECUTED a generated command (sentinel created)"
else pass "no-exec: no generated command was executed"; fi

# --- 5. gen --seeds-file applies transforms to a supplied seed ----------------
cat > "$TMP/one-seed.txt" <<'SEEDS'
supplied	allow	touch PLACEHOLDER
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/one-seed.txt" -o "$TMP/sf.jsonl"
N=$(grep -c '"family": "supplied"' "$TMP/sf.jsonl")
# one seed x (len(TRANSFORMS)+pad) rows; just assert more than one variant.
if [ "$N" -ge 2 ]; then pass "seeds-file: transforms applied to supplied seed ($N rows)"
else fail "seeds-file: expected >=2 supplied rows, got $N"; fi
has "seeds-file: placeholder preserved" "$(cat "$TMP/sf.jsonl")" "PLACEHOLDER"

# --- 5b. xargs transform is not applied to a stdin-consuming (heredoc) seed ---
# codex-3: xargs feeds its own stdin to the wrapped command, hijacking a
# heredoc seed's input and making the row's expect label unreliable. The
# built-in heredoc-commit seed must never appear xargs-wrapped.
python3 "$GEN" --seed 4168 -o "$TMP/def.jsonl"
NX=$(python3 - "$TMP/def.jsonl" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    c = json.loads(line)["tool_input"]["command"]
    if "xargs" in c and "<<" in c:
        n += 1
print(n)
PY
)
if [ "$NX" = "0" ]; then pass "xargs-transform: not applied to heredoc seed"
else fail "xargs-transform: $NX xargs-wrapped heredoc row(s) emitted"; fi

# --- 5c. a bogus sha base is a setup error, never a silent partial tree -------
# codex-1: materialise must fail loud on an unreadable sha rather than run an
# incomplete hook tree. A nonexistent sha => setup error (exit 2).
GITREPO="$TMP/gitrepo"
mkdir -p "$GITREPO"
( cd "$GITREPO" && git init -q && git -c user.email=x@x -c user.name=x commit -q --allow-empty -m init ) >/dev/null 2>&1
python3 "$DIFF" --base "sha:deadbeefdeadbeefdeadbeefdeadbeefdeadbeef:scripts/hooks/x.sh" \
        --head "$TMP/base-hook.sh" --corpus "$TMP/corpus.jsonl" --repo "$GITREPO" \
        >/dev/null 2>&1; RC_SHA=$?
if [ "$RC_SHA" = "2" ]; then pass "sha-materialise: bogus sha is a setup error (exit 2)"
else fail "sha-materialise: expected exit 2, got $RC_SHA"; fi

# --- 6. deny-expected rows the base never denies => inconclusive (exit 3) ----
# codex-3: if a judge supplies deny seeds but the base denies NONE, the deny
# positive control never fired, so "no regression" proves nothing. A clean
# exit 0 would be a false "reviewed clean"; diff must report it (exit 3).
cat > "$TMP/miss-seeds.txt" <<'SEEDS'
planted-miss	deny	echo harmless
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/miss-seeds.txt" -o "$TMP/miss-corpus.jsonl"
OUT6=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/miss-corpus.jsonl" --jobs 4 2>&1); RC6=$?
has "deny-control: warning present" "$OUT6" "NO deny-side coverage"
# HIMMEL-4219: neither side denied => VACUOUS, the distinct exit 4 (was 3).
has "deny-control: VACUOUS line" "$OUT6" "VACUOUS: "
if [ "$RC6" = "4" ]; then pass "deny-control: neither side denies => VACUOUS exit 4"
else fail "deny-control: expected exit 4, got $RC6"; fi
# the base never denies but the head DOES: not vacuous, still inconclusive (3).
python3 "$DIFF" --base "$TMP/head-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC6B=$?
if [ "$RC6B" = "3" ]; then pass "deny-control: base never denies, head does => exit 3"
else fail "deny-control: expected exit 3 for base-allow/head-deny, got $RC6B"; fi

# --- 6b. HIMMEL-4219: data deps materialised per side, VACUOUS flagged --------
# (a) a planted hook that FAILS OPEN without its registry. Copied alone (the old
# way: no scripts/ tree beside it) its registry is missing, it allows every row,
# and the run must read VACUOUS, not clean.
cat > "$TMP/regdep-hook.sh" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reg="${CHOKEPOINT_REGISTRY:-$d/../chokepoints.json}"
input=$(cat)
[ -r "$reg" ] || exit 0
case "$input" in *SENTINEL_DENY*) exit 2 ;; esac
exit 0
STUB
chmod +x "$TMP/regdep-hook.sh"
OUT6A=$(python3 "$DIFF" --base "$TMP/regdep-hook.sh" --head "$TMP/regdep-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC6A=$?
has "vacuous: planted fail-open hook flagged" "$OUT6A" "VACUOUS: "
if [ "$RC6A" = "4" ]; then pass "vacuous: standalone hook without registry => exit 4"
else fail "vacuous: expected exit 4, got $RC6A"; fi
# control: the same hook inside a scripts/ tree that carries the registry
# denies, so the run is not vacuous (proves the copy is what changes the result).
mkdir -p "$TMP/planted/scripts/hooks"
cp "$TMP/regdep-hook.sh" "$TMP/planted/scripts/hooks/regdep-hook.sh"
printf '{}\n' > "$TMP/planted/scripts/chokepoints.json"
python3 "$DIFF" --base "$TMP/planted/scripts/hooks/regdep-hook.sh" \
        --head "$TMP/planted/scripts/hooks/regdep-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC6C=$?
if [ "$RC6C" = "0" ]; then pass "vacuous-control: registry copied into the tree => exit 0"
else fail "vacuous-control: expected exit 0 with registry in tree, got $RC6C"; fi

# (b) the REAL block-chokepoint-env-prefix.sh, base (git sha) vs the same head
# (path), denies its deny seed rows: the registry resolves per side, so the run
# is not vacuous. Seeds are the hook suite's own registry-pair shape.
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
if git -C "$REPO_ROOT" cat-file -e "HEAD:scripts/hooks/block-chokepoint-env-prefix.sh" 2>/dev/null \
   && command -v jq >/dev/null 2>&1; then
  cat > "$TMP/choke-seeds.txt" <<SEEDS
env-prefix	deny	CR_REQUIRE_CROSS_MODEL=1 bash scripts/cr/clear-cr-marker.sh --list
env-prefix	deny	env CR_REQUIRE_CROSS_MODEL=x bash scripts/cr/clear-cr-marker.sh
exec-probe	allow	touch $TMP/choke-must-not-exist
SEEDS
  python3 "$GEN" --seed 1 --seeds-file "$TMP/choke-seeds.txt" -o "$TMP/choke-corpus.jsonl"
  OUT6D=$(python3 "$DIFF" \
      --base "sha:HEAD:scripts/hooks/block-chokepoint-env-prefix.sh" \
      --head "$REPO_ROOT/scripts/hooks/block-chokepoint-env-prefix.sh" \
      --corpus "$TMP/choke-corpus.jsonl" --repo "$REPO_ROOT" --jobs 4 2>&1); RC6D=$?
  hasnt "real-hook: not vacuous" "$OUT6D" "VACUOUS: "
  hasnt "real-hook: base denied its seeds" "$OUT6D" "(base denied 0;"
  if [ "$RC6D" = "0" ]; then pass "real-hook: base-vs-same-head denies seeds, exit 0"
  else fail "real-hook: expected exit 0, got $RC6D"; fi
  # (c) the no-exec guarantee holds on the tree-materialised path too: the
  # touch row above was piped to the hook, never run.
  if [ -e "$TMP/choke-must-not-exist" ]; then fail "real-hook: diff EXECUTED a row (sentinel created)"
  else pass "real-hook: no row was executed"; fi
else
  echo "SKIP real-hook (hook not in HEAD or jq missing)"
fi

# --- 7. a malformed corpus is a setup error (exit 2), never a regression ----
# CodeRabbit: json.loads on a truncated line, or a row missing
# tool_input.command, raised an uncaught exception -> Python exit 1, which is
# the REGRESSION code, so a broken corpus read as a confirmed regression. Both
# must be setup errors (exit 2).
printf 'this is not json\n' > "$TMP/corrupt.jsonl"
python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/corrupt.jsonl" --jobs 1 >/dev/null 2>&1; RC7A=$?
if [ "$RC7A" = "2" ]; then pass "malformed-corpus: corrupt JSON line => exit 2"
else fail "malformed-corpus: expected exit 2 for corrupt JSON, got $RC7A"; fi

printf '{"tool_input":{}}\n' > "$TMP/nocmd.jsonl"
python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/nocmd.jsonl" --jobs 1 >/dev/null 2>&1; RC7B=$?
if [ "$RC7B" = "2" ]; then pass "malformed-corpus: row missing command => exit 2"
else fail "malformed-corpus: expected exit 2 for missing command, got $RC7B"; fi

# CodeRabbit round 8 (codex-2): a setup failure (a missing hook file, a failed
# mkdir/copy) raises OSError, not RuntimeError. Caught only RuntimeError, it
# escaped as Python exit 1 -- the confirmed-regression code -- on a corpus that
# was never reviewed. A nonexistent plain --base path makes materialise_hook's
# shutil.copyfile raise FileNotFoundError (an OSError); that must be exit 2.
printf '{"tool_input":{"command":"echo hi"}}\n' > "$TMP/one-row.jsonl"
python3 "$DIFF" --base "$TMP/does-not-exist.sh" --head "$TMP/base-hook.sh" \
        --corpus "$TMP/one-row.jsonl" --jobs 1 >/dev/null 2>&1; RC7C=$?
if [ "$RC7C" = "2" ]; then pass "setup-error: missing hook file => exit 2 (not regression 1)"
else fail "setup-error: expected exit 2 for missing hook, got $RC7C"; fi

# --- 8. exec_a transform re-spells SIMPLE commands only ----------------------
# CodeRabbit: `exec -a NAME cmd` replaces the shell with a single command, so a
# compound seed would lose list elements after the first and change meaning
# while keeping its expect label. The transform must leave compound seeds
# unwrapped, and must escape a quoted first token.
cat > "$TMP/exec-seeds.txt" <<'SEEDS'
simple	deny	echo-x hi
compound	deny	echo a && echo b
SEEDS
python3 "$GEN" --seed 1 --seeds-file "$TMP/exec-seeds.txt" -o "$TMP/exec-corpus.jsonl"
EXEC_OK=$(python3 - "$TMP/exec-corpus.jsonl" <<'PY'
import json, sys
simple_wrapped = False
bad_compound = 0
for line in open(sys.argv[1]):
    c = json.loads(line)["tool_input"]["command"]
    if c.startswith("exec -a "):
        if any(op in c for op in ("&&", "||", ";", "|")):
            bad_compound += 1
        if "echo-x" in c:
            simple_wrapped = True
print("ok" if (simple_wrapped and bad_compound == 0) else "bad:%d simple:%s" % (bad_compound, simple_wrapped))
PY
)
if [ "$EXEC_OK" = "ok" ]; then pass "exec_a: wraps simple seed, skips compound seed"
else fail "exec_a: $EXEC_OK"; fi

# CodeRabbit round 9 (codex-1): HIMMEL_REPO must NOT reach a hook from the real
# checkout -- a hook anchoring on it would resolve helpers/state off the primary.
# diff pins it to the per-row scratch primary (cwd, path ending /primary). This
# stub exits 0 only when HIMMEL_REPO ends in /primary, else a non-0/2 rc so diff
# reports ODD-RC and exits 3. Pre-fix (HIMMEL_REPO inherited = real checkout) the
# stub exits 7 => diff exit 3; post-fix it is the sandbox anchor => diff exit 0.
cat > "$TMP/anchor-hook.sh" <<'STUB'
#!/usr/bin/env bash
case "$HIMMEL_REPO" in
  */primary) exit 0 ;;
  *) exit 7 ;;
esac
STUB
chmod +x "$TMP/anchor-hook.sh"
printf '{"tool_input":{"command":"echo hi"}}\n' > "$TMP/anchor-corpus.jsonl"
python3 "$DIFF" --base "$TMP/anchor-hook.sh" --head "$TMP/anchor-hook.sh" \
        --corpus "$TMP/anchor-corpus.jsonl" --jobs 1 >/dev/null 2>&1; RC9=$?
if [ "$RC9" = "0" ]; then pass "sandbox-anchor: HIMMEL_REPO points at scratch primary => exit 0"
else fail "sandbox-anchor: expected exit 0 (sandbox anchor), got $RC9"; fi

# CodeRabbit round 10 (codex-1): a per-row sandbox copy or hook launch that
# raises (disk exhaustion, a missing bash) escapes the worker pool and, with no
# except on the run loop, terminated Python with exit 1 -- the confirmed-
# regression code -- for a harness failure. It must map to setup-error exit 2.
# Trigger it deterministically: run diff under a PATH that has git (so setup
# succeeds) but no bash, so the per-row Popen(["bash",...]) raises
# FileNotFoundError. Pre-fix that is an uncaught exit 1; post-fix it is exit 2.
PY3="$(command -v python3)"
GIT3="$(command -v git)"
mkdir -p "$TMP/nobash-path"
ln -sf "$GIT3" "$TMP/nobash-path/git"
printf '{"tool_input":{"command":"echo hi"}}\n' > "$TMP/run-err-corpus.jsonl"
env PATH="$TMP/nobash-path" "$PY3" "$DIFF" --base "$TMP/base-hook.sh" \
        --head "$TMP/base-hook.sh" --corpus "$TMP/run-err-corpus.jsonl" \
        --jobs 1 >/dev/null 2>&1; RC10=$?
if [ "$RC10" = "2" ]; then pass "run-error: worker launch failure => exit 2 (not regression 1)"
else fail "run-error: expected exit 2 for worker launch failure, got $RC10"; fi

# --- 11. HIMMEL-4537: non-Bash rows pass through unchanged -------------------
# A Write/Edit/NotebookEdit guard was untestable: diff hard-coded tool_name Bash
# and required tool_input.command. A row now carries its own tool_name and
# tool_input; @PRIMARY@ is substituted in every string of tool_input. The stub
# denies only a Write row whose content carries the sentinel AND whose
# file_path had the placeholder substituted.
cat > "$TMP/write-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *@PRIMARY@*) exit 7 ;; esac
case "$input" in *'"tool_name": "Write"'*SENTINEL_DENY*) exit 2 ;; esac
exit 0
STUB
chmod +x "$TMP/write-hook.sh"
printf '%s\n' '{"tool_name":"Write","tool_input":{"file_path":"@PRIMARY@/x.txt","content":"SENTINEL_DENY"},"family":"write","transform":"identity","expect":"deny"}' \
  > "$TMP/write-corpus.jsonl"
OUT11=$(python3 "$DIFF" --base "$TMP/write-hook.sh" --head "$TMP/head-hook.sh" \
        --corpus "$TMP/write-corpus.jsonl" --jobs 1 2>&1); RC11=$?
if [ "$RC11" = "1" ]; then pass "tool-passthrough: Write row base-deny/head-allow => exit 1"
else fail "tool-passthrough: expected exit 1, got $RC11 ($OUT11)"; fi
python3 "$DIFF" --base "$TMP/write-hook.sh" --head "$TMP/write-hook.sh" \
        --corpus "$TMP/write-corpus.jsonl" --jobs 1 >/dev/null 2>&1; RC11B=$?
if [ "$RC11B" = "0" ]; then pass "tool-passthrough-control: same hook => exit 0"
else fail "tool-passthrough-control: expected exit 0, got $RC11B"; fi
printf '%s\n' '{"tool_name":"Write","tool_input":"not-an-object"}' > "$TMP/bad-tool.jsonl"
python3 "$DIFF" --base "$TMP/write-hook.sh" --head "$TMP/write-hook.sh" \
        --corpus "$TMP/bad-tool.jsonl" --jobs 1 >/dev/null 2>&1; RC11C=$?
if [ "$RC11C" = "2" ]; then pass "tool-passthrough: non-object tool_input => exit 2"
else fail "tool-passthrough: expected exit 2 for non-object tool_input, got $RC11C"; fi

# --- 12. HIMMEL-4537: the decision is read from JSON, not exit 2 alone --------
# A hook may deny or ask through hookSpecificOutput.permissionDecision at exit
# 0, and an approver hook allows that way. diff used to read exit 2 only, so a
# JSON-only deny lost by the head, a deny downgraded to ask, and an approver
# that newly approves were all invisible.
cat > "$TMP/json-deny-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *SENTINEL_DENY*)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}\n' ;;
esac
exit 0
STUB
cat > "$TMP/json-ask-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *SENTINEL_DENY*)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}\n' ;;
esac
exit 0
STUB
cat > "$TMP/json-approve-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *SENTINEL_DENY*)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n' ;;
esac
exit 0
STUB
cat > "$TMP/json-stop-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
case "$input" in *SENTINEL_DENY*)
  printf '{"continue":false,"stopReason":"stub"}\n' ;;
esac
exit 0
STUB
chmod +x "$TMP/json-deny-hook.sh" "$TMP/json-ask-hook.sh" "$TMP/json-approve-hook.sh" "$TMP/json-stop-hook.sh"
OUT12E=$(python3 "$DIFF" --base "$TMP/json-stop-hook.sh" --head "$TMP/head-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC12E=$?
has "json-decision: a lost continue-false stop is named" "$OUT12E" "base=deny head=pass"
if [ "$RC12E" = "1" ]; then pass "json-decision: continue-false stop lost by head => exit 1"
else fail "json-decision: expected exit 1 for stop/allow, got $RC12E"; fi
OUT12A=$(python3 "$DIFF" --base "$TMP/json-deny-hook.sh" --head "$TMP/head-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC12A=$?
has "json-decision: JSON-only deny lost is named" "$OUT12A" "base=deny head=pass"
if [ "$RC12A" = "1" ]; then pass "json-decision: JSON-only deny lost by head => exit 1"
else fail "json-decision: expected exit 1 for JSON-deny/allow, got $RC12A"; fi
OUT12B=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/json-ask-hook.sh" \
        --corpus "$TMP/corpus.jsonl" --jobs 4 2>&1); RC12B=$?
has "json-decision: deny downgraded to ask is named" "$OUT12B" "head=ask"
if [ "$RC12B" = "1" ]; then pass "json-decision: deny downgraded to ask => exit 1"
else fail "json-decision: expected exit 1 for deny/ask, got $RC12B"; fi
printf '%s\n' 'approver	either	echo SENTINEL_DENY' > "$TMP/approver-seeds.txt"
python3 "$GEN" --seed 1 --seeds-file "$TMP/approver-seeds.txt" -o "$TMP/approver-corpus.jsonl"
OUT12C=$(python3 "$DIFF" --base "$TMP/head-hook.sh" --head "$TMP/json-approve-hook.sh" \
        --corpus "$TMP/approver-corpus.jsonl" --jobs 4 2>&1); RC12C=$?
has "approver: newly approved row is named" "$OUT12C" "head=approve"
if [ "$RC12C" = "1" ]; then pass "approver: head approves what base did not => exit 1"
else fail "approver: expected exit 1 for pass/approve, got $RC12C"; fi
python3 "$DIFF" --base "$TMP/json-approve-hook.sh" --head "$TMP/json-approve-hook.sh" \
        --corpus "$TMP/approver-corpus.jsonl" --jobs 4 >/dev/null 2>&1; RC12D=$?
if [ "$RC12D" = "0" ]; then pass "approver-control: same approver both sides => exit 0"
else fail "approver-control: expected exit 0, got $RC12D"; fi

# --- 13. HIMMEL-4537: optional per-row cwd and session context ---------------
# Every row used to run in the scratch primary on main with no permission_mode,
# so a guard whose verdict depends on running in a worktree could not be
# exercised. A row may now ask for cwd "worktree" (a scratch worktree of the
# scratch primary on a feature branch, @WORKTREE@ substituted) and carry
# permission_mode / session_id into the payload. The stub exits 0 only when all
# three reached it, else 7 (ODD-RC => exit 3).
cat > "$TMP/ctx-hook.sh" <<'STUB'
#!/usr/bin/env bash
input=$(cat)
b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -n "$b" ] && [ "$b" != main ] || exit 7
case "$input" in *@WORKTREE@*) exit 7 ;; esac
case "$input" in *'"permission_mode": "auto"'*) ;; *) exit 7 ;; esac
case "$input" in *'"session_id": "s-1"'*) ;; *) exit 7 ;; esac
exit 0
STUB
chmod +x "$TMP/ctx-hook.sh"
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"ls @WORKTREE@"},"cwd":"worktree","permission_mode":"auto","session_id":"s-1","expect":"allow"}' \
  > "$TMP/ctx-corpus.jsonl"
python3 "$DIFF" --base "$TMP/ctx-hook.sh" --head "$TMP/ctx-hook.sh" \
        --corpus "$TMP/ctx-corpus.jsonl" --jobs 1 >/dev/null 2>&1; RC13=$?
if [ "$RC13" = "0" ]; then pass "row-context: worktree cwd + permission_mode + session_id reach the hook"
else fail "row-context: expected exit 0, got $RC13"; fi
printf '%s\n' '{"tool_input":{"command":"ls"},"cwd":"elsewhere"}' > "$TMP/bad-cwd.jsonl"
python3 "$DIFF" --base "$TMP/ctx-hook.sh" --head "$TMP/ctx-hook.sh" \
        --corpus "$TMP/bad-cwd.jsonl" --jobs 1 >/dev/null 2>&1; RC13B=$?
if [ "$RC13B" = "2" ]; then pass "row-context: unknown cwd value => exit 2"
else fail "row-context: expected exit 2 for unknown cwd, got $RC13B"; fi

# --- 14. HIMMEL-4537: over-denied read-only shapes are benign twins ----------
# Three read-only shapes real guards denied during the 2026-10-06 hardening
# pass ship as allow-expected twins, and diff counts allow-expected rows a side
# denied, so a judge sees over-deny instead of nothing.
TWINS=$(python3 "$GEN" --seed 1 | python3 -c '
import json, sys
print(" ".join(sorted({json.loads(l)["seed_verb"] for l in sys.stdin
                       if json.loads(l)["expect"] == "allow"})))')
for v in var-path-read glob-grep-stderr hook-glob-grep; do
  has "benign-twin: $v" "$TWINS" "$v"
done
cat > "$TMP/deny-all-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 2
STUB
chmod +x "$TMP/deny-all-hook.sh"
python3 "$GEN" --seed 1 -o "$TMP/benign-corpus.jsonl"
OUT14=$(python3 "$DIFF" --base "$TMP/deny-all-hook.sh" --head "$TMP/deny-all-hook.sh" \
        --corpus "$TMP/benign-corpus.jsonl" --jobs 4 2>&1)
has "over-deny: allow-expected denials counted" "$OUT14" "OVER-DENY idx="
hasnt "over-deny: count not zero" "$OUT14" "(denied by base 0;"

# --- 15. HIMMEL-4586: BOM-prefixed JSON stdout is inconclusive, never a pass ---
# Claude Code's docs say stdout is read as JSON when it starts with { and ends
# with } "ignoring surrounding whitespace" and do not mention a UTF-8 BOM, so
# whether a BOM-prefixed deny is honoured is undocumented: diff scores it ODD
# (exit 3), never `pass`.
printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"echo SENTINEL_DENY"},"expect":"deny"}' \
  > "$TMP/one-row.jsonl"
cat > "$TMP/bom-deny-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '\357\273\277{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}\n'
exit 0
STUB
cat > "$TMP/bom-allow-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '\357\273\277{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}\n'
exit 0
STUB
chmod +x "$TMP/bom-deny-hook.sh" "$TMP/bom-allow-hook.sh"
for kind in deny allow; do
  OUT15=$(python3 "$DIFF" --base "$TMP/base-hook.sh" --head "$TMP/bom-$kind-hook.sh" \
          --corpus "$TMP/one-row.jsonl" --jobs 1 2>&1); RC15=$?
  if [ "$RC15" = "3" ]; then pass "bom-$kind: BOM-prefixed JSON is inconclusive => exit 3"
  else fail "bom-$kind: expected exit 3, got $RC15"; fi
  has "bom-$kind: row named ODD-RC" "$OUT15" "ODD-RC idx="
done

# --- 16. HIMMEL-4587: the hook's own exit ends the row ------------------------
# A hook that backgrounds a child holding stdout must not make the row wait for
# the timeout; what the hook wrote before exiting is read, and a child still
# running never turns a deny into a pass.
cat > "$TMP/bg-deny-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sleep 30 &
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"}}\n'
exit 0
STUB
cat > "$TMP/bg-allow-hook.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
sleep 30 &
exit 0
STUB
chmod +x "$TMP/bg-deny-hook.sh" "$TMP/bg-allow-hook.sh"
T0=$SECONDS
OUT16A=$(python3 "$DIFF" --base "$TMP/bg-deny-hook.sh" --head "$TMP/bg-allow-hook.sh" \
        --corpus "$TMP/one-row.jsonl" --jobs 1 --timeout-run 10 2>&1); RC16A=$?
if [ "$RC16A" = "1" ]; then pass "bg-child: backgrounded deny lost by a backgrounding allow => exit 1"
else fail "bg-child: expected exit 1, got $RC16A"; fi
has "bg-child: deny read, not TIMEOUT" "$OUT16A" "base=deny head=pass"
if [ $((SECONDS - T0)) -lt 8 ]; then pass "bg-child: row did not wait for the timeout"
else fail "bg-child: row took $((SECONDS - T0))s, waited on the child"; fi
python3 "$DIFF" --base "$TMP/bg-deny-hook.sh" --head "$TMP/bg-deny-hook.sh" \
        --corpus "$TMP/one-row.jsonl" --jobs 1 --timeout-run 10 >/dev/null 2>&1; RC16B=$?
if [ "$RC16B" = "0" ]; then pass "bg-child-control: backgrounded deny both sides => exit 0"
else fail "bg-child-control: expected exit 0, got $RC16B"; fi

echo "----"
echo "guard-corpus: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
