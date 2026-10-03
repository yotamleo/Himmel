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
if [ "$RC6" = "3" ]; then pass "deny-control: no base deny => inconclusive exit 3"
else fail "deny-control: expected exit 3, got $RC6"; fi

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

echo "----"
echo "guard-corpus: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
