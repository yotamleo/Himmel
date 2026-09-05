#!/usr/bin/env bash
# scripts/cr/test-critic-panel.sh -- TDD tests for critic-panel.sh (HIMMEL-415).
# Bash 3.2 safe.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

# Hermetic: the panel now reads CR_PROFILE (HIMMEL-558) — and has always read
# CRITIC_PANEL_TIERS — from the environment. Clear any ambient values so the
# default-behaviour tests are not perturbed by the operator's shell (.env often
# exports CR_PROFILE=free,paid). Each CR_PROFILE test below sets it explicitly.
unset CR_PROFILE CRITIC_PANEL_TIERS CRITIC_LEDGER_APPEND CR_LEDGER \
    CRITIC_FIRST_PASS CRITICS_JSON CRITIC_PARALLEL CRITIC_TIMEOUT_SECS \
    CRITIC_PANEL_TOTAL_TIMEOUT_SECS CRITIC_PANEL_STARTED_AT \
    CR_TRIVIALITY_OVERRIDE 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
tmp="$(mktemp -d -t critic-panel-test.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
# HIMMEL-2130: members really shell out through critic-first-pass.sh to
# hermes/invoke.sh (only HERMES_PY is stubbed), which really appends
# flow-run rows — route those at a scratch file so this suite never pollutes
# ~/.himmel/flow-runs.jsonl. Exported vars inherit into every bash "$CFP"/
# "$PANEL" child spawned below (no env -i / explicit env-list scrub).
export HIMMEL_FLOW_RUNS_LEDGER="$tmp/flow-runs.jsonl"
fails=0

# Most cases exercise panel behavior, not persistence; isolate them from the real
# git-common-dir ledger and from each other's repeated finding IDs. Dedicated
# ledger assertions below override this seam with the real helper.
LEDGER_NOOP="$tmp/ledger-noop.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$LEDGER_NOOP"
chmod +x "$LEDGER_NOOP"
export CRITIC_LEDGER_APPEND="$LEDGER_NOOP"
_skips=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

check_contains() {
    if grepq "$2" -F -- "$3"; then
        echo "ok - $1"
    else
        echo "FAIL - $1: expected to contain [$3]"
        fails=$((fails + 1))
    fi
}

# skip <label> -- a case that could not run in this environment. Must NEVER
# be reported with the "ok - " pass token: a skip credited as a pass hides
# the fact that nothing was asserted (HIMMEL-2258 audit; HIMMEL-2226 fix).
skip() {
    echo "SKIP - $1"
    _skips=$((_skips + 1))
}

STUB_PY="$HERE/testdata/stub-cfp.py"

# Create bash wrapper around Python stub
STUB="$tmp/stub-cfp.sh"
printf '%s\n' '#!/usr/bin/env bash' > "$STUB"
printf 'exec python3 "%s" "$@"\n' "$STUB_PY" >> "$STUB"
chmod +x "$STUB"

# Write fixture JSONs
python3 - "$tmp" <<'PYEOF'
import sys, json, os
tmp = sys.argv[1]
data_all = {'panel': [
    {'slug': 'qwen3coder', 'model': 'qwen/qwen3-coder-480b-a35b-instruct', 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'gptoss',     'model': 'openai/gpt-oss-120b',                 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'kimi',       'model': 'moonshotai/kimi-k2.6',                'provider': 'nvidia', 'tier': 'free'},
]}
data_paid = {'panel': [
    {'slug': 'qwen3coder', 'model': 'qwen/qwen3-coder-480b-a35b-instruct', 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'gptoss',     'model': 'openai/gpt-oss-120b',                 'provider': 'nvidia', 'tier': 'free'},
    {'slug': 'kimi',       'model': 'moonshotai/kimi-k2.6',                'provider': 'nvidia', 'tier': 'paid'},
]}
data_fail = {'panel': [{'slug': 'kimi', 'model': 'moonshotai/kimi-k2.6', 'provider': 'nvidia', 'tier': 'free'}]}
for nm, d in [('critics-all', data_all), ('critics-paid', data_paid), ('critics-allfail', data_fail)]:
    open(os.path.join(tmp, nm + '.json'), 'w').write(__import__('json').dumps(d))
PYEOF

DIFF='diff --git a/foo.sh b/foo.sh
index 0000000..1111111 100644
--- a/foo.sh
+++ b/foo.sh
@@ -1,2 +1,8 @@
 line
+null check missing
+another line
+x = 1
+unused
+rename me
+bar
+baz'

# Test R: registry-sync — the REAL critics.json must keep the panel invariants:
# a non-empty free tier (counting only rows the panel would accept: slug+model+
# tier, mirroring its row filter) and the anchor slug pinned to the anchor model.
# The anchor constants are sourced FROM critic-panel.sh, so this is a live
# cross-check of critics.json against the panel's fallback, not a third copy.
ANCHOR_SLUG="$(sed -n 's/^ANCHOR_SLUG="\(.*\)"$/\1/p' "$PANEL")"
ANCHOR_MODEL="$(sed -n 's/^ANCHOR_MODEL="\(.*\)"$/\1/p' "$PANEL")"
ANCHOR_PROVIDER="$(sed -n 's/^ANCHOR_PROVIDER="\(.*\)"$/\1/p' "$PANEL")"
check "R: ANCHOR_SLUG extracted from critic-panel.sh" "$([ -n "$ANCHOR_SLUG" ] && echo yes)" "yes"
check "R: ANCHOR_MODEL extracted from critic-panel.sh" "$([ -n "$ANCHOR_MODEL" ] && echo yes)" "yes"
check "R: ANCHOR_PROVIDER extracted from critic-panel.sh" "$([ -n "$ANCHOR_PROVIDER" ] && echo yes)" "yes"
reg_valid="$(python3 - "$HERE/critics.json" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1]))
ok = any(e.get("slug") and e.get("model") and e.get("tier") in ("free", "paid")
         for e in d.get("panel", []))
print("yes" if ok else "no")
PYEOF
)"
check "R: registry has >=1 valid critic" "$reg_valid" "yes"
# The anchor may be paid (the free laguna anchor was dropped); it routes via its
# `provider` (openai-codex) rather than a `route_provider`. Accept either key.
reg_anchor="$(python3 - "$HERE/critics.json" "$ANCHOR_SLUG" <<'PYEOF'
import sys, json
d = json.load(open(sys.argv[1]))
for e in d.get("panel", []):
    if e.get("slug") == sys.argv[2]:
        prov = e.get("route_provider") or e.get("provider") or ""
        print(e.get("tier", "") + " " + e.get("model", "") + " " + prov); break
PYEOF
)"
check "R: anchor slug $ANCHOR_SLUG is in the registry + pinned to the panel's ANCHOR_MODEL + ANCHOR_PROVIDER" "$reg_anchor" "paid $ANCHOR_MODEL $ANCHOR_PROVIDER"

# Test A: merge + global renumber
out_a="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "A: qwen3coder-1 present" "$(printf '%s\n' "$out_a" | grep -cF '[qwen3coder-1]:')" "1"
check "A: qwen3coder-2 present" "$(printf '%s\n' "$out_a" | grep -cF '[qwen3coder-2]:')" "1"
check "A: qwen3coder-3 present" "$(printf '%s\n' "$out_a" | grep -cF '[qwen3coder-3]:')" "1"
check "A: gptoss renumbered to gptoss-4" "$(printf '%s\n' "$out_a" | grep -cF '[gptoss-4]:')" "1"
check "A: no bare gptoss-1" "$(printf '%s\n' "$out_a" | grep -cF '[gptoss-1]:')" "0"

# Test B: member drop -> stderr + header count
stderr_b="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
out_b="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "B: kimi unavailable" "$(printf '%s\n' "$stderr_b" | grep -cF 'panel-availability: kimi unavailable')" "1"
check "B: qwen3coder ok" "$(printf '%s\n' "$stderr_b" | grep -cF 'panel-availability: qwen3coder ok')" "1"
check "B: gptoss ok" "$(printf '%s\n' "$stderr_b" | grep -cF 'panel-availability: gptoss ok')" "1"
check "B: header 2/3" "$(printf '%s\n' "$out_b" | grep -cF '(2/3 critics responded)')" "1"

# Test C: all-fail -> exit 1
printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-allfail.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" >/dev/null 2>&1
check "C: all-fail -> exit 1" "$?" "1"

# Test D: >=1 responds -> exit 0 (the stdin shape remains supported).
printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" >/dev/null 2>&1
check "D: stdin shape + >=1 responds -> exit 0" "$?" "0"

# HIMMEL-1871: integration fixture through the REAL critic-first-pass citation
# validator. Every model finding cites the wrong file/range. The member still
# responded successfully (panel rc stays 0 — non-zero means unavailable/fallback),
# but the PANEL must convert the all-dropped signal into a blocking Critical and
# preserve every rejected finding under Dropped Citations. Those rejected bullets
# must NOT enter the accuracy ledger as normal findings.
AD_JSON="$tmp/critics-all-dropped.json"
printf '%s' '{"panel":[{"slug":"all-drop","model":"fake/reviewer","provider":"test","tier":"free"}]}' > "$AD_JSON"
AD_STUB_PY="$tmp/all-dropped.py"
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: missing rollback guard [foo-script.sh:3]")
print("## Important Issues (1 found)")
print("- [CRITIC-2]: unbounded retry [foo.sh:999]")
print("## Suggestions (0 found)")
PYEOF
AD_PY="$tmp/all-dropped-py.sh"
cat > "$AD_PY" <<PYEOF
#!/usr/bin/env bash
exec python3 "$AD_STUB_PY"
PYEOF
chmod +x "$AD_PY"
AD_LEDGER="$tmp/all-dropped-ledger.jsonl"; : > "$AD_LEDGER"
ad_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$AD_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/ad-out" 2> "$tmp/ad-err" || ad_rc=$?
ad_out="$(cat "$tmp/ad-out")"
check "HIMMEL-1871: all-dropped member remains a responded critic" "$ad_rc" "0"
check_contains "HIMMEL-1871: panel as a whole emits a blocking Critical" "$ad_out" "## Critical Issues (1 found)"
check_contains "HIMMEL-1871: blocking Critical names citation validation" "$ad_out" "[citation-guard-"
check_contains "HIMMEL-1871: merged review counts both dropped findings" "$ad_out" "## Dropped Citations (2 dropped)"
check_contains "HIMMEL-1871: first dropped finding is recoverable" "$ad_out" "missing rollback guard"
check_contains "HIMMEL-1871: second dropped finding is recoverable" "$ad_out" "unbounded retry"
# Two halves of the ledger invariant (the guard is queued to the LEDGER, not
# just stdout, so clear-cr-marker's ledger-derived clearance can see it):
#   1. member accuracy is not inflated — zero finding rows attributed to the
#      member slug; its rejected bullets were never validated.
#   2. the guard is blocking evidence — exactly one finding row identified as
#      the citation-guard blocker AND matching the GATE's blocking definition.
# `blocking` mirrors scripts/lib/cr-ledger-evidence.sh verbatim (crit|imp,
# verdict neither `disproved` nor a TRACKED deferral: ticket key + reason), so
# this asserts the gate's semantics rather than a local re-invention of them.
ad_ledger="$(python3 - "$AD_LEDGER" <<'PYEOF'
import json, re, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
findings = [r for r in rows if r.get('kind') == 'finding']
def blocking(r):
    if r.get('severity') not in ('crit', 'imp'):
        return False
    if r.get('verdict') == 'disproved':
        return False
    if r.get('verdict') == 'deferred':
        ticket = str(r.get('deferred_to') or '').strip()
        why = str(r.get('reason') or '').strip()
        if re.match(r'^[A-Z][A-Z0-9]*-[0-9]+$', ticket) and why:
            return False
    return True
member = [r for r in findings if r.get('model') == 'all-drop']
guard = [r for r in findings
         if r.get('model') == 'citation-guard'
         and str(r.get('finding_id', '')).startswith('citation-guard-')
         and r.get('severity') == 'crit'
         and blocking(r)]
print('member-findings=' + str(len(member)))
print('guard-blockers=' + str(len(guard)))
print('avail-ok=' + str(sum(r.get('kind') == 'avail' and r.get('status') == 'ok' for r in rows)))
PYEOF
)"
check "HIMMEL-1871: dropped findings do not inflate member accuracy (no all-drop finding rows)" "$(printf '%s\n' "$ad_ledger" | sed -n 's/^member-findings=//p')" "0"
check "HIMMEL-1871: citation guard reaches the ledger as exactly one blocking finding" "$(printf '%s\n' "$ad_ledger" | sed -n 's/^guard-blockers=//p')" "1"
check "HIMMEL-1871: responding member still records availability" "$(printf '%s\n' "$ad_ledger" | sed -n 's/^avail-ok=//p')" "1"

# Round 3: one invalid Critical plus one valid Suggestion. The surviving
# Suggestion is non-blocking and must not suppress the citation guard on either
# published surface. The rejected Critical stays out of member accuracy; the
# validated Suggestion remains a normal member finding.
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: missing rollback guard [foo-script.sh:3]")
print("## Important Issues (0 found)")
print("## Suggestions (1 found)")
print("- [CRITIC-2]: simplify the loop [foo.sh:3]")
PYEOF
MIXED_LEDGER="$tmp/mixed-drop-ledger.jsonl"; : > "$MIXED_LEDGER"
mixed_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$MIXED_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/mixed-out" 2> "$tmp/mixed-err" || mixed_rc=$?
mixed_out="$(cat "$tmp/mixed-out")"
check "HIMMEL-1871 round 3: mixed-severity member remains a responded critic" "$mixed_rc" "0"
check_contains "HIMMEL-1871 round 3: rendered report keeps a blocking Critical" "$mixed_out" "## Critical Issues (1 found)"
check_contains "HIMMEL-1871 round 3: rendered blocker keeps the citation-guard id" "$mixed_out" "[citation-guard-"
check_contains "HIMMEL-1871 round 3: guard message remains true for partial drops" "$mixed_out" "were rejected because their citations were unverifiable"
check_contains "HIMMEL-1871 round 3: valid Suggestion survives" "$mixed_out" "## Suggestions (1 found)"
check_contains "HIMMEL-1871 round 3: invalid Critical remains recoverable" "$mixed_out" "## Dropped Citations (1 dropped)"
mixed_ledger="$(python3 - "$MIXED_LEDGER" <<'PYEOF'
import json, re, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
findings = [r for r in rows if r.get('kind') == 'finding']
def blocking(r):
    if r.get('severity') not in ('crit', 'imp'):
        return False
    if r.get('verdict') == 'disproved':
        return False
    if r.get('verdict') == 'deferred':
        ticket = str(r.get('deferred_to') or '').strip()
        why = str(r.get('reason') or '').strip()
        if re.match(r'^[A-Z][A-Z0-9]*-[0-9]+$', ticket) and why:
            return False
    return True
member = [r for r in findings if r.get('model') == 'all-drop']
member_blockers = [r for r in member if blocking(r)]
member_suggestions = [r for r in member if r.get('severity') == 'sug']
guard = [r for r in findings
         if r.get('model') == 'citation-guard'
         and str(r.get('finding_id', '')).startswith('citation-guard-')
         and r.get('severity') == 'crit'
         and blocking(r)]
print('member-blockers=' + str(len(member_blockers)))
print('member-suggestions=' + str(len(member_suggestions)))
print('guard-blockers=' + str(len(guard)))
PYEOF
)"
check "HIMMEL-1871 round 3: rejected Critical creates no member-attributed blocker row" "$(printf '%s\n' "$mixed_ledger" | sed -n 's/^member-blockers=//p')" "0"
check "HIMMEL-1871 round 3: validated Suggestion remains one member finding row" "$(printf '%s\n' "$mixed_ledger" | sed -n 's/^member-suggestions=//p')" "1"
check "HIMMEL-1871 round 3: ledger has exactly one blocking citation guard" "$(printf '%s\n' "$mixed_ledger" | sed -n 's/^guard-blockers=//p')" "1"

# A genuinely clean response must remain clean: no synthetic blocker and no
# Dropped Citations section — and, wired to a ledger exactly like the
# all-dropped case above, ZERO finding rows of ANY kind (including no
# citation-guard row): a clean review must stay clean in the LEDGER too, or
# the ledger-derived clearance path would block on phantom evidence.
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (0 found)")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
CLEAN_LEDGER="$tmp/clean-ledger.jsonl"; : > "$CLEAN_LEDGER"
clean_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$CLEAN_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/ad-clean-out" 2> "$tmp/ad-clean-err" || clean_rc=$?
ad_clean_out="$(cat "$tmp/ad-clean-out")"
clean_ledger="$(python3 - "$CLEAN_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
findings = [r for r in rows if r.get('kind') == 'finding']
print('findings=' + str(len(findings)))
print('guard-rows=' + str(sum(r.get('model') == 'citation-guard' for r in findings)))
PYEOF
)"
check "HIMMEL-1871: genuinely clean panel still exits completed" "$clean_rc" "0"
check_contains "HIMMEL-1871: genuinely clean panel stays Critical=0" "$ad_clean_out" "## Critical Issues (0 found)"
check "HIMMEL-1871: genuinely clean panel has no Dropped Citations" "$(printf '%s\n' "$ad_clean_out" | grep -c '^## Dropped Citations')" "0"
check "HIMMEL-1871: genuinely clean panel records zero finding rows (any model)" "$(printf '%s\n' "$clean_ledger" | sed -n 's/^findings=//p')" "0"
check "HIMMEL-1871: genuinely clean panel records no citation-guard row" "$(printf '%s\n' "$clean_ledger" | sed -n 's/^guard-rows=//p')" "0"

# HIMMEL-1871 round 4, seam 1: a valid Critical surviving must not make a
# dropped Important vanish. Before round 4 the Dropped Citations section fired
# only when EVERY blocking finding dropped, so the dropped Important left no
# trace on stdout or in the ledger whenever any blocker survived — and once the
# surviving blocker was amended disproved, the gate cleared with the dropped
# finding never adjudicated. The guard must fire on ANY dropped blocking
# finding, independent of what else survived.
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: valid blocker [foo.sh:3]")
print("## Important Issues (1 found)")
print("- [CRITIC-2]: dropped important [foo.sh:999]")
print("## Suggestions (0 found)")
PYEOF
SEAM1_LEDGER="$tmp/seam1-ledger.jsonl"; : > "$SEAM1_LEDGER"
seam1_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$SEAM1_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/seam1-out" 2> "$tmp/seam1-err" || seam1_rc=$?
seam1_out="$(cat "$tmp/seam1-out")"
check "HIMMEL-1871 seam 1: partial-drop member remains a responded critic" "$seam1_rc" "0"
check_contains "HIMMEL-1871 seam 1: surviving Critical plus guard both render" "$seam1_out" "## Critical Issues (2 found)"
check_contains "HIMMEL-1871 seam 1: dropped Important stays recoverable" "$seam1_out" "## Dropped Citations (1 dropped)"
check_contains "HIMMEL-1871 seam 1: dropped Important text present" "$seam1_out" "dropped important"
seam1_ledger="$(python3 - "$SEAM1_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
findings = [r for r in rows if r.get('kind') == 'finding']
member = [r for r in findings if r.get('model') == 'all-drop']
guard = [r for r in findings if r.get('model') == 'citation-guard'
         and r.get('severity') == 'crit' and not r.get('verdict')]
print('member-findings=' + str(len(member)))
print('guard-blockers=' + str(len(guard)))
PYEOF
)"
check "HIMMEL-1871 seam 1: surviving Critical is one member row" "$(printf '%s\n' "$seam1_ledger" | sed -n 's/^member-findings=//p')" "1"
check "HIMMEL-1871 seam 1: dropped Important still blocks in the LEDGER" "$(printf '%s\n' "$seam1_ledger" | sed -n 's/^guard-blockers=//p')" "1"

# Round 4, other direction: dropped SUGGESTIONS never block. Even when every
# finding the member produced was a rejected Suggestion (the shape that used to
# fire the all-dropped guard), the content stays readable under Dropped
# Citations but no synthetic Critical and no guard row may appear.
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (0 found)")
print("## Important Issues (0 found)")
print("## Suggestions (2 found)")
print("- [CRITIC-1]: bogus cleanup [foo.sh:999]")
print("- [CRITIC-2]: bogus rename [foo-script.sh:3]")
PYEOF
SUGD_LEDGER="$tmp/sug-drop-ledger.jsonl"; : > "$SUGD_LEDGER"
sugd_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$SUGD_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/sugd-out" 2> "$tmp/sugd-err" || sugd_rc=$?
sugd_out="$(cat "$tmp/sugd-out")"
check "HIMMEL-1871: suggestion-only drops keep panel rc 0" "$sugd_rc" "0"
check_contains "HIMMEL-1871: suggestion-only drops add no synthetic Critical" "$sugd_out" "## Critical Issues (0 found)"
check_contains "HIMMEL-1871: suggestion-only drops stay readable" "$sugd_out" "## Dropped Citations (2 dropped)"
check "HIMMEL-1871: suggestion-only drops queue no guard row" \
    "$(grep -c 'citation-guard' "$SUGD_LEDGER" || true)" "0"

# Round 4, seam 2: the guard's identity derives from the rejected blocking
# evidence itself. ledger-append.sh dedups findings on (head, finding_id); a
# CONSTANT guard id made a same-head rerun with DIFFERENT rejected evidence
# dedup into the original guard row and inherit its disproved/deferred
# amendment — new evidence adjudicated by inheritance, never seen. Two runs at
# the same head with different rejected blockers must yield two distinct
# verdict-less guard rows; an identical rerun must stay idempotent (no third).
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: evidence alpha [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
SEAM2_LEDGER="$tmp/seam2-ledger.jsonl"; : > "$SEAM2_LEDGER"
HERMES_PY="$AD_PY" CR_LEDGER="$SEAM2_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/seam2-out-a" 2>/dev/null || true
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: evidence beta [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
seam2b_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$SEAM2_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/seam2-out-b" 2>/dev/null || seam2b_rc=$?
check "HIMMEL-1871 seam 2: rerun with new evidence completes" "$seam2b_rc" "0"
# Identical rerun of the beta evidence: quiet dedup, still rc 0, no third row.
seam2c_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$SEAM2_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/seam2-out-c" 2>/dev/null || seam2c_rc=$?
check "HIMMEL-1871 seam 2: identical rerun stays idempotent (rc 0)" "$seam2c_rc" "0"
# HERMETIC probe (HIMMEL-1871 round 7 post-mortem): the panel stamps
# REVIEW_HEAD from the cwd repo, so a commit landing on this branch while the
# suite is mid-run legitimately puts seam-2's later runs at a NEW head — and
# (head, finding_id) dedup then correctly declines to dedup across heads.
# Asserting absolute row counts ("exactly 2 rows") therefore misattributes a
# mid-suite commit to the diff under test (the HIMMEL-1931 failure class;
# observed live: guard-rows=3/distinct-ids=2/verdictless=3 when a commit
# landed between run 2 and run 3). Assert the PROPERTIES instead — each still
# catches its real regression: a constant id -> distinct-ids=1; broken same-
# head dedup -> a duplicate (head, finding_id) pair; a non-idempotent digest
# (same evidence, new id) -> distinct-ids=3; an inherited verdict -> not all
# rows verdict-less.
seam2_ledger="$(python3 - "$SEAM2_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
guards = [r for r in rows if r.get('kind') == 'finding'
          and r.get('model') == 'citation-guard']
ids = sorted(set(str(r.get('finding_id')) for r in guards))
pairs = [(r.get('head'), r.get('finding_id')) for r in guards]
print('distinct-ids=' + str(len(ids)))
print('dup-pairs=' + str(len(pairs) - len(set(pairs))))
print('all-verdictless=' + ('yes' if guards and all(not r.get('verdict') for r in guards) else 'no'))
PYEOF
)"
check "HIMMEL-1871 seam 2: alpha and beta evidence mint exactly two distinct ids" "$(printf '%s\n' "$seam2_ledger" | sed -n 's/^distinct-ids=//p')" "2"
check "HIMMEL-1871 seam 2: identical rerun never duplicates a (head, finding_id) pair" "$(printf '%s\n' "$seam2_ledger" | sed -n 's/^dup-pairs=//p')" "0"
check "HIMMEL-1871 seam 2: every guard row blocks (no inherited verdict)" "$(printf '%s\n' "$seam2_ledger" | sed -n 's/^all-verdictless=//p')" "yes"

# Rounds 5-6, tab injectivity: member_parsed is a TAB-delimited channel and
# the guard digest is computed over what crosses it. Before round 5 a literal
# tab inside a rejected bullet truncated the evidence at the first channel
# reader, so two distinct blockers identical up to the tab collapsed to ONE
# digest — the second run deduped into the first (possibly adjudicated) ledger
# row. Round 5's tab->space normalization fixed the truncation but still
# collapsed tab-vs-space-distinct evidence to one id (the same inheritance
# failure, narrower); round 6 carries the payload as a BYTE-EXACT remainder.
# So tab-alpha, tab-beta, and space-alpha at the same head must mint THREE
# distinct verdict-less guard rows, and the tab must reach ## Dropped
# Citations as a literal tab — untruncated and unnormalized.
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: shared prefix\ttail-alpha [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
TABI_LEDGER="$tmp/tab-inject-ledger.jsonl"; : > "$TABI_LEDGER"
HERMES_PY="$AD_PY" CR_LEDGER="$TABI_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/tabi-out-a" 2>/dev/null || true
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: shared prefix\ttail-beta [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
tabi_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$TABI_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/tabi-out-b" 2>/dev/null || tabi_rc=$?
# Run C: same head, SPACE where run A had a tab — visually identical, distinct
# bytes. Round 5's normalization collapsed this into run A's id (Finding A of
# the round-6 review); byte-exact evidence must mint a third row.
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: shared prefix tail-alpha [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
HERMES_PY="$AD_PY" CR_LEDGER="$TABI_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/tabi-out-c" 2>/dev/null || true
tabi_out_a="$(cat "$tmp/tabi-out-a")"
check "HIMMEL-1871 round 5: tab-bearing rejected blocker completes" "$tabi_rc" "0"
check_contains "HIMMEL-1871 round 6: tab evidence reaches Dropped Citations byte-exact" "$tabi_out_a" $'prefix\ttail-alpha'
tabi_ledger="$(python3 - "$TABI_LEDGER" <<'PYEOF'
import json, re, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
guards = [r for r in rows if r.get('kind') == 'finding'
          and r.get('model') == 'citation-guard']
ids = sorted(set(str(r.get('finding_id')) for r in guards))
print('guard-rows=' + str(len(guards)))
print('distinct-ids=' + str(len(ids)))
print('verdictless=' + str(sum(not r.get('verdict') for r in guards)))
print('id-shape=' + ('yes' if ids and all(re.fullmatch(r'citation-guard-[0-9a-f]{16}', i) for i in ids) else 'no'))
PYEOF
)"
check "HIMMEL-1871 rounds 5-6: tab-alpha, tab-beta, space-alpha each mint a guard row" "$(printf '%s\n' "$tabi_ledger" | sed -n 's/^guard-rows=//p')" "3"
check "HIMMEL-1871 rounds 5-6: all three guard ids are distinct (incl. tab-vs-space)" "$(printf '%s\n' "$tabi_ledger" | sed -n 's/^distinct-ids=//p')" "3"
check "HIMMEL-1871 rounds 5-6: all three guard rows block (no inherited verdict)" "$(printf '%s\n' "$tabi_ledger" | sed -n 's/^verdictless=//p')" "3"
check "HIMMEL-1871 round 5: guard ids are 16-hex sha256 digests" "$(printf '%s\n' "$tabi_ledger" | sed -n 's/^id-shape=//p')" "yes"

# Round 5, binary-byte evidence: GNU grep's binary heuristic (Git Bash grep
# 3.0, UTF-8 locale) suppresses matched LINES when stdin carries a
# locale-invalid byte — the old rendered-prefix grep classifier could come
# back EMPTY on such evidence, ndb=0, guard never fires: a total gate bypass,
# no collision needed. Round 6 removed that grep (classification travels as a
# decoded flag; no code path greps model bytes to classify), but this pins the
# INVARIANT — a rejected blocker carrying an invalid-UTF-8 byte still fires
# the guard on stdout AND in the ledger — against any future reintroduction.
cat > "$AD_STUB_PY" <<'PYEOF'
import sys
sys.stdout.buffer.write(b"## Critical Issues (1 found)\n")
sys.stdout.buffer.write(b"- [CRITIC-1]: clipped multibyte \x80 evidence [nope.sh:999]\n")
sys.stdout.buffer.write(b"## Important Issues (0 found)\n")
sys.stdout.buffer.write(b"## Suggestions (0 found)\n")
PYEOF
BINB_LEDGER="$tmp/bin-byte-ledger.jsonl"; : > "$BINB_LEDGER"
binb_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$BINB_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/binb-out" 2>/dev/null || binb_rc=$?
binb_out="$(cat "$tmp/binb-out")"
check "HIMMEL-1871 round 5: binary-byte rejected blocker completes" "$binb_rc" "0"
check_contains "HIMMEL-1871 round 5: binary-byte evidence still fires the guard on stdout" "$binb_out" "[citation-guard-"
binb_guards="$(python3 - "$BINB_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print(sum(r.get('kind') == 'finding' and r.get('model') == 'citation-guard'
          and r.get('severity') == 'crit' and not r.get('verdict') for r in rows))
PYEOF
)"
check "HIMMEL-1871 round 5: binary-byte evidence blocks in the ledger" "$binb_guards" "1"

# Round 6, slash-bearing slug: the registry accepts ANY non-empty slug
# (local-overlay values like "openai/gpt"). The old classifier re-parsed the
# RENDERED "- slug / Section: " prefix with a slash-free-slug regex: the drop
# raised nd but fell out of drop_blocking -> ndb=0 -> no guard, no ledger row,
# false clean. Classification now decodes with the KNOWN slug as a literal
# prefix, so a slash slug must (a) fire the guard on a dropped blocker, (b)
# still NOT block on a dropped Suggestion, and (c) keep its avail row (the
# spool bucket filename sanitizes the slash; an unsanitized one silently lost
# the append).
SLASH_JSON="$tmp/critics-slash.json"
printf '%s' '{"panel":[{"slug":"openai/gpt","model":"fake/reviewer","provider":"test","tier":"free"}]}' > "$SLASH_JSON"
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: slash slug evidence [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
SLASH_LEDGER="$tmp/slash-ledger.jsonl"; : > "$SLASH_LEDGER"
slash_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$SLASH_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$SLASH_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/slash-out" 2>/dev/null || slash_rc=$?
slash_out="$(cat "$tmp/slash-out")"
check "HIMMEL-1871 round 6: slash-slug member remains a responded critic" "$slash_rc" "0"
check_contains "HIMMEL-1871 round 6: slash-slug dropped blocker still fires the guard" "$slash_out" "[citation-guard-"
check_contains "HIMMEL-1871 round 6: slash-slug rejected evidence stays recoverable" "$slash_out" "## Dropped Citations (1 dropped)"
slash_ledger="$(python3 - "$SLASH_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print('guard-blockers=' + str(sum(r.get('kind') == 'finding' and r.get('model') == 'citation-guard'
      and r.get('severity') == 'crit' and not r.get('verdict') for r in rows)))
print('avail-ok=' + str(sum(r.get('kind') == 'avail' and r.get('status') == 'ok'
      and r.get('model') == 'openai/gpt' for r in rows)))
PYEOF
)"
check "HIMMEL-1871 round 6: slash-slug dropped blocker blocks in the ledger" "$(printf '%s\n' "$slash_ledger" | sed -n 's/^guard-blockers=//p')" "1"
check "HIMMEL-1871 round 6: slash-slug avail row survives the spool (exact slug)" "$(printf '%s\n' "$slash_ledger" | sed -n 's/^avail-ok=//p')" "1"
# Other direction: a slash slug's dropped SUGGESTION must still classify
# non-blocking (the Suggestions prefix match also embeds the slug).
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (0 found)")
print("## Important Issues (0 found)")
print("## Suggestions (1 found)")
print("- [CRITIC-1]: bogus tidy-up [nope.sh:999]")
PYEOF
SLASHS_LEDGER="$tmp/slash-sug-ledger.jsonl"; : > "$SLASHS_LEDGER"
slashs_rc=0
HERMES_PY="$AD_PY" CR_LEDGER="$SLASHS_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$SLASH_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/slash-sug-out" 2>/dev/null || slashs_rc=$?
slashs_out="$(cat "$tmp/slash-sug-out")"
check "HIMMEL-1871 round 6: slash-slug suggestion-only drop keeps rc 0" "$slashs_rc" "0"
check_contains "HIMMEL-1871 round 6: slash-slug suggestion-only drop adds no synthetic Critical" "$slashs_out" "## Critical Issues (0 found)"
check "HIMMEL-1871 round 6: slash-slug suggestion-only drop queues no guard row" \
    "$(grep -c 'citation-guard' "$SLASHS_LEDGER" || true)" "0"

# Round 7: digest failure fails CLOSED. command -v checked tool EXISTENCE
# only; a present-but-FAILING sha256sum left the digest empty, and
# printf %.16s minted the CONSTANT id "citation-guard-" — the round-4 bug
# back: one adjudication of that row would make every later digest-failure
# guard non-blocking by dedup inheritance. The id is now shape-validated
# (64 hex) and an uncertifiable run is REFUSED (exit 6): no review body, no
# ledger rows. Two distinct same-head drops under digest failure must leave
# ZERO shared ledger key — zero rows at all — never two rows collapsed onto
# one constant id.
FAKEBIN="$tmp/fakebin"
mkdir -p "$FAKEBIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$FAKEBIN/sha256sum"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$FAKEBIN/shasum"
chmod +x "$FAKEBIN/sha256sum" "$FAKEBIN/shasum"
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: digestless evidence one [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
DIGF_LEDGER="$tmp/digest-fail-ledger.jsonl"; : > "$DIGF_LEDGER"
digf_rc=0
PATH="$FAKEBIN:$PATH" HERMES_PY="$AD_PY" CR_LEDGER="$DIGF_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/digf-out-a" 2> "$tmp/digf-err-a" || digf_rc=$?
check "HIMMEL-1871 round 7: digest failure refuses the run (exit 6)" "$digf_rc" "6"
check_contains "HIMMEL-1871 round 7: refusal is loud on stderr" "$(cat "$tmp/digf-err-a")" "refusing to certify"
check "HIMMEL-1871 round 7: no review body is emitted on refusal" \
    "$(grep -c '^## Critical Issues' "$tmp/digf-out-a" || true)" "0"
cat > "$AD_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: digestless evidence two [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
digf_rc_b=0
PATH="$FAKEBIN:$PATH" HERMES_PY="$AD_PY" CR_LEDGER="$DIGF_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$AD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/digf-out-b" 2> "$tmp/digf-err-b" || digf_rc_b=$?
check "HIMMEL-1871 round 7: second distinct-evidence run also refuses (exit 6)" "$digf_rc_b" "6"
check "HIMMEL-1871 round 7: distinct same-head drops share NO ledger key (no guard rows)" \
    "$(grep -c 'citation-guard' "$DIGF_LEDGER" || true)" "0"
check "HIMMEL-1871 round 7: refused runs append NOTHING to the ledger" \
    "$(wc -l < "$DIGF_LEDGER" | tr -d ' ')" "0"

# Round 9: the FALLBACK chain shares the rc=4 contract the primary path
# learned in round 8. Before this, the chain accepted only rc 0: a fallback
# critic answering with a valid all-dropped review (rc 4, Dropped Citations on
# stdout) was recorded as an error, its output DELETED, and the chain moved to
# the next candidate — a later clean response then cleared the panel with the
# rejected blockers and the citation guard never reaching stdout or the
# ledger. Fixture: primary fails (quota-shaped garbage, rc 1), fb1 answers
# rc 4 with a dropped blocker, fb2 would answer CLEAN rc 0. The chain must
# accept fb1, STOP (fb2 never consulted — the counter proves it), record
# truthful availability (ok, responding-model fb1), and the guard must mint
# its blocking ledger row.
FBD_JSON="$tmp/critics-fb-drop.json"
printf '%s' '{"panel":[{"slug":"fbdrop","model":"fake/primary","provider":"test","tier":"free","fallback_models":["fake/fb1","fake/fb2"],"fallback_trigger":"any"}]}' > "$FBD_JSON"
FBD_COUNT="$tmp/fbd-count"
printf '0' > "$FBD_COUNT"
FBD_DROP_PY="$tmp/fbd-drop.py"
cat > "$FBD_DROP_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: fallback dropped blocker [nope.sh:999]")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
FBD_CLEAN_PY="$tmp/fbd-clean.py"
cat > "$FBD_CLEAN_PY" <<'PYEOF'
print("## Critical Issues (0 found)")
print("## Important Issues (0 found)")
print("## Suggestions (0 found)")
PYEOF
FBD_STUB="$tmp/fbd-stub.sh"
cat > "$FBD_STUB" <<SHEOF
#!/usr/bin/env bash
c=\$(cat "$FBD_COUNT" 2>/dev/null || echo 0)
c=\$((c+1))
printf '%s' "\$c" > "$FBD_COUNT"
case "\$c" in
  1) echo "HTTP 403: The free quota has been exhausted" ;;
  2) python3 "$FBD_DROP_PY" ;;
  *) python3 "$FBD_CLEAN_PY" ;;
esac
SHEOF
chmod +x "$FBD_STUB"
FBD_LEDGER="$tmp/fb-drop-ledger.jsonl"; : > "$FBD_LEDGER"
fbd_rc=0
HERMES_PY="$FBD_STUB" CR_LEDGER="$FBD_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$FBD_JSON" CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/fbd-out" 2> "$tmp/fbd-err" || fbd_rc=$?
fbd_out="$(cat "$tmp/fbd-out")"
check "HIMMEL-1871 round 9: rc-4 fallback keeps the panel responding (rc 0)" "$fbd_rc" "0"
check_contains "HIMMEL-1871 round 9: rc-4 fallback still fires the guard on stdout" "$fbd_out" "[citation-guard-"
check_contains "HIMMEL-1871 round 9: fallback's rejected blocker stays recoverable" "$fbd_out" "## Dropped Citations (1 dropped)"
check "HIMMEL-1871 round 9: chain STOPPED at the rc-4 candidate (fb2 never consulted)" "$(cat "$FBD_COUNT")" "2"
fbd_ledger="$(python3 - "$FBD_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print('guard-blockers=' + str(sum(r.get('kind') == 'finding' and r.get('model') == 'citation-guard'
      and r.get('severity') == 'crit' and not r.get('verdict') for r in rows)))
print('avail-ok-fb1=' + str(sum(r.get('kind') == 'avail' and r.get('status') == 'ok'
      and r.get('model') == 'fbdrop' and r.get('responding_model') == 'fake/fb1' for r in rows)))
print('member-findings=' + str(sum(r.get('kind') == 'finding' and r.get('model') == 'fbdrop' for r in rows)))
PYEOF
)"
check "HIMMEL-1871 round 9: fallback's dropped blocker blocks in the LEDGER" "$(printf '%s\n' "$fbd_ledger" | sed -n 's/^guard-blockers=//p')" "1"
check "HIMMEL-1871 round 9: availability is truthful (ok via responding-model fb1)" "$(printf '%s\n' "$fbd_ledger" | sed -n 's/^avail-ok-fb1=//p')" "1"
check "HIMMEL-1871 round 9: rejected fallback bullets stay out of member accuracy" "$(printf '%s\n' "$fbd_ledger" | sed -n 's/^member-findings=//p')" "0"

# Test LA: the panel persists its OWN evidence through ledger-append.sh. One run
# contains two responders + one unavailable member and four findings, so it
# covers both availability statuses and empty raw verdicts without orchestrator
# glue. Every row must carry the exact head that was reviewed.
LEDGER_CASE="$tmp/panel-ledger.jsonl"
: > "$LEDGER_CASE"
CR_LEDGER="$LEDGER_CASE" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/ledger-out" 2> "$tmp/ledger-err"
ledger_rc=$?
reviewed_head="$(git rev-parse HEAD)"
ledger_summary="$(python3 - "$LEDGER_CASE" "$reviewed_head" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
head = sys.argv[2]
avail = [r for r in rows if r.get('kind') == 'avail']
findings = [r for r in rows if r.get('kind') == 'finding']
print('avail=' + str(len(avail)))
print('ok=' + str(sum(r.get('status') == 'ok' for r in avail)))
print('unavailable=' + str(sum(r.get('status') == 'unavailable' for r in avail)))
print('unavailable-reason=' + ('yes' if any(r.get('model') == 'kimi' and r.get('reason') == 'generic-rc-1' for r in avail) else 'no'))
print('all-head=' + ('yes' if rows and all(r.get('head') == head for r in rows) else 'no'))
print('findings=' + str(len(findings)))
print('empty-verdicts=' + ('yes' if findings and all(r.get('verdict') == '' for r in findings) else 'no'))
print('models=' + ','.join(sorted(r.get('model', '') for r in avail)))
PYEOF
)"
check "LA: panel succeeds while self-appending" "$ledger_rc" "0"
check "LA: one availability row per member" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^avail=//p')" "3"
check "LA: responder availability rows are ok" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^ok=//p')" "2"
check "LA: failed member availability row is unavailable" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^unavailable=//p')" "1"
check "LA: unavailable row includes its classified reason" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^unavailable-reason=//p')" "yes"
check "LA: availability models are the registry slugs" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^models=//p')" "gptoss,kimi,qwen3coder"
check "LA: every row is stamped with the reviewed head" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^all-head=//p')" "yes"
check "LA: every emitted finding self-appended" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^findings=//p')" "4"
check "LA: raw finding verdicts are empty" "$(printf '%s\n' "$ledger_summary" | sed -n 's/^empty-verdicts=//p')" "yes"

# Test LAP: parallel mode self-appends the SAME ledger evidence as sequential
# (HIMMEL-1494 r3; per-member spool files r4). The evidence path flows through
# PER-MEMBER spool files (avail.<slug>/finding.<slug>), one per member, not a
# shared file; this is the regression guard. If process_member is ever moved
# into a background subshell, each member's spool must still land every row —
# assert the parallel ledger has the same avail/finding counts AND the same
# per-member model sets (avail + findings) as the sequential run over the
# identical fixture, so a lost per-member file can't hide behind a matching count.
LAP_SEQ="$tmp/lap-seq.jsonl"; : > "$LAP_SEQ"
LAP_PAR="$tmp/lap-par.jsonl"; : > "$LAP_PAR"
CR_LEDGER="$LAP_SEQ" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/lap-seq-out" 2> "$tmp/lap-seq-err"
CR_LEDGER="$LAP_PAR" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    CRITIC_PARALLEL=1 \
    bash "$PANEL" <<< "$DIFF" > "$tmp/lap-par-out" 2> "$tmp/lap-par-err"
lap_summary="$(python3 - "$LAP_SEQ" "$LAP_PAR" <<'PYEOF'
import json, sys
def shape(p):
    rows = [json.loads(l) for l in open(p) if l.strip()]
    a = [r for r in rows if r.get('kind') == 'avail']
    f = [r for r in rows if r.get('kind') == 'finding']
    return (len(a), len(f),
            ','.join(sorted(r.get('model', '') for r in a)),
            ','.join(sorted(r.get('model', '') for r in f)))
sa, sf, sm, sfm = shape(sys.argv[1]); pa, pf, pm, pfm = shape(sys.argv[2])
print('seq_avail=%d' % sa); print('seq_find=%d' % sf)
print('par_avail=%d' % pa); print('par_find=%d' % pf)
print('avail_same=%s' % (sa == pa)); print('find_same=%s' % (sf == pf))
print('models_same=%s' % (sm == pm)); print('seq_models=%s' % sm)
print('find_models_same=%s' % (sfm == pfm)); print('seq_find_models=%s' % sfm)
PYEOF
)"
check "LAP: sequential avail rows (3)" "$(printf '%s\n' "$lap_summary" | sed -n 's/^seq_avail=//p')" "3"
check "LAP: sequential finding rows (4)" "$(printf '%s\n' "$lap_summary" | sed -n 's/^seq_find=//p')" "4"
check "LAP: parallel avail rows == sequential" "$(printf '%s\n' "$lap_summary" | sed -n 's/^avail_same=//p')" "True"
check "LAP: parallel finding rows == sequential" "$(printf '%s\n' "$lap_summary" | sed -n 's/^find_same=//p')" "True"
check "LAP: parallel avail model set == sequential" "$(printf '%s\n' "$lap_summary" | sed -n 's/^models_same=//p')" "True"
check "LAP: parallel finding model set == sequential" "$(printf '%s\n' "$lap_summary" | sed -n 's/^find_models_same=//p')" "True"
check "LAP: avail model set is the registry slugs" "$(printf '%s\n' "$lap_summary" | sed -n 's/^seq_models=//p')" "gptoss,kimi,qwen3coder"

# Test WT: sanctioned --worktree mode computes main...HEAD itself. A real diff
# runs and stamps that worktree's head; an empty diff and a non-worktree path
# fail loudly with distinct documented exits.
WT_REPO="$tmp/review-worktree"
git init -q "$WT_REPO"
git -C "$WT_REPO" checkout -q -b main
git -C "$WT_REPO" config user.name test
git -C "$WT_REPO" config user.email test@example.invalid
printf 'base\n' > "$WT_REPO/review.txt"
git -C "$WT_REPO" add review.txt
git -C "$WT_REPO" commit -q -m base
git -C "$WT_REPO" checkout -q -b feature
printf 'changed\n' >> "$WT_REPO/review.txt"
git -C "$WT_REPO" add review.txt
git -C "$WT_REPO" commit -q -m feature
wt_head="$(git -C "$WT_REPO" rev-parse HEAD)"
WT_LEDGER="$tmp/worktree-ledger.jsonl"
: > "$WT_LEDGER"
CR_LEDGER="$WT_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" --worktree "$WT_REPO" > "$tmp/wt-out" 2> "$tmp/wt-err"
wt_rc=$?
check "WT1: --worktree real main...HEAD diff runs" "$wt_rc" "0"
check_contains "WT1: --worktree still emits panel output" "$(cat "$tmp/wt-out")" "# Critic Panel Review"
check "WT1: ledger rows use the reviewed worktree head" \
    "$(python3 - "$WT_LEDGER" "$wt_head" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print('yes' if rows and all(r.get('head') == sys.argv[2] for r in rows) else 'no')
PYEOF
)" "yes"

git -C "$WT_REPO" checkout -q main
wt_empty_rc=0
CR_LEDGER="$tmp/wt-empty-ledger.jsonl" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" --worktree "$WT_REPO" > "$tmp/wt-empty-out" 2> "$tmp/wt-empty-err" || wt_empty_rc=$?
check "WT2: empty --worktree diff uses distinct exit" "$wt_empty_rc" "4"
check_contains "WT2: empty --worktree diff refusal is loud" "$(cat "$tmp/wt-empty-err")" "REFUSING empty --worktree diff"

mkdir -p "$tmp/not-a-worktree"
wt_bad_rc=0
bash "$PANEL" --worktree "$tmp/not-a-worktree" > "$tmp/wt-bad-out" 2> "$tmp/wt-bad-err" || wt_bad_rc=$?
check "WT3: non-worktree path uses distinct exit" "$wt_bad_rc" "3"
check_contains "WT3: non-worktree refusal is explicit" "$(cat "$tmp/wt-bad-err")" "is not a git worktree"

# ── HIMMEL-1175: --head pins the review inputs to the caller's captured SHA ──
# /pr-check captures branch+HEAD up front and stamps every ledger row with that
# SHA, but the panel resolved its own head (and its --worktree diff) from LIVE
# state. A checkout that moved between capture and review therefore had one tree
# reviewed and another certified. PIN1 = the pinned range is what the critic
# actually sees; PIN2/PIN3 = a moved checkout REFUSES (exit 7) in both the
# --worktree and the stdin lane, with nothing reviewed and nothing stamped.
PIN_STUB="$tmp/stub-dump-diff.sh"
cat > "$PIN_STUB" <<'EOS'
#!/usr/bin/env bash
# Dumps the diff it was handed, then answers with a clean review.
if [ -n "${PIN_DIFF_DUMP:-}" ]; then cat > "$PIN_DIFF_DUMP"; else cat > /dev/null; fi
printf '# pin First-Pass Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOS
chmod +x "$PIN_STUB"
python3 - "$tmp" <<'PYEOF'
import sys, json, os
tmp = sys.argv[1]
with open(os.path.join(tmp, 'critics-pin.json'), 'w') as fh:
    json.dump({'panel': [{'slug': 'pin', 'model': 'pin-model', 'provider': 'nvidia', 'tier': 'free'}]}, fh)
PYEOF

git -C "$WT_REPO" checkout -q feature
PIN_LEDGER="$tmp/pin-ledger.jsonl"
: > "$PIN_LEDGER"
PIN_DUMP="$tmp/pin-diff.txt"
rm -f "$PIN_DUMP"
pin_rc=0
CR_LEDGER="$PIN_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
    PIN_DIFF_DUMP="$PIN_DUMP" \
    bash "$PANEL" --worktree "$WT_REPO" --head "$wt_head" --branch feature > "$tmp/pin-out" 2> "$tmp/pin-err" || pin_rc=$?
check "PIN1: --head matching the checkout runs" "$pin_rc" "0"
check "PIN1: ledger rows stamp the PINNED branch (not a fresh resolution)" \
    "$(python3 - "$PIN_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print('yes' if rows and all(r.get('branch') == 'feature' for r in rows) else 'no')
PYEOF
)" "yes"
check "PIN1: the critic saw the diff of the PINNED range" \
    "$(cat "$PIN_DUMP" 2>/dev/null)" "$(git -C "$WT_REPO" diff "main...$wt_head")"
check "PIN1: ledger rows stamp the pinned head" \
    "$(python3 - "$PIN_LEDGER" "$wt_head" <<'PYEOF'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
print('yes' if rows and all(r.get('head') == sys.argv[2] for r in rows) else 'no')
PYEOF
)" "yes"

# The checkout moves on past the captured SHA — the race the pin exists for.
printf 'moved after capture\n' >> "$WT_REPO/review.txt"
git -C "$WT_REPO" add review.txt
git -C "$WT_REPO" commit -q -m moved
PIN2_LEDGER="$tmp/pin2-ledger.jsonl"
: > "$PIN2_LEDGER"
PIN2_DUMP="$tmp/pin2-diff.txt"
rm -f "$PIN2_DUMP"
pin2_rc=0
CR_LEDGER="$PIN2_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
    PIN_DIFF_DUMP="$PIN2_DUMP" \
    bash "$PANEL" --worktree "$WT_REPO" --head "$wt_head" > "$tmp/pin2-out" 2> "$tmp/pin2-err" || pin2_rc=$?
check "PIN2: --worktree stale pin uses the distinct exit" "$pin2_rc" "7"
check_contains "PIN2: refusal names the moved checkout" "$(cat "$tmp/pin2-err")" \
    "the checkout moved since the caller captured its inputs"
check "PIN2: NO ledger rows stamped on a refused run" "$(wc -l < "$PIN2_LEDGER" | tr -d ' ')" "0"
check "PIN2: no critic ran (the diff was never handed out)" \
    "$([ -f "$PIN2_DUMP" ] && echo yes || echo no)" "no"

# Stdin lane (what /pr-check actually invokes): the caller computed the diff
# against the captured SHA, so a moved checkout must refuse there too rather
# than stamp the ledger with a head the diff never described.
PIN3_LEDGER="$tmp/pin3-ledger.jsonl"
: > "$PIN3_LEDGER"
pin3_rc=0
( cd "$WT_REPO" && printf '%s' "$DIFF" \
    | CR_LEDGER="$PIN3_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
      CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
      bash "$PANEL" --head "$wt_head" > "$tmp/pin3-out" 2> "$tmp/pin3-err" ) || pin3_rc=$?
check "PIN3: stdin lane stale pin uses the distinct exit" "$pin3_rc" "7"
check "PIN3: NO ledger rows stamped on a refused stdin run" "$(wc -l < "$PIN3_LEDGER" | tr -d ' ')" "0"

# PIN4: a revision EXPRESSION is not a pin. `HEAD` (or a branch name) resolves
# dynamically, so it would follow the very checkout move the pin exists to
# catch — reject it at parse time rather than silently self-satisfying.
pin4_rc=0
( cd "$WT_REPO" && printf '%s' "$DIFF" | bash "$PANEL" --head HEAD > "$tmp/pin4-out" 2> "$tmp/pin4-err" ) || pin4_rc=$?
check "PIN4: --head HEAD rejected as a usage error" "$pin4_rc" "2"
check_contains "PIN4: rejection says why" "$(cat "$tmp/pin4-err")" "not a revision expression"

# PIN5: the same-SHA branch switch — the case the ticket names. The SHA pin
# alone is satisfied (both branches point at the same commit), so only the
# --branch half catches it; without it the panel stamps its ledger rows with
# the branch it happens to be on rather than the one the caller certifies.
wt_moved_head="$(git -C "$WT_REPO" rev-parse HEAD)"
git -C "$WT_REPO" checkout -q -b feature-alias
PIN5_LEDGER="$tmp/pin5-ledger.jsonl"
: > "$PIN5_LEDGER"
pin5_rc=0
CR_LEDGER="$PIN5_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
    bash "$PANEL" --worktree "$WT_REPO" --head "$wt_moved_head" --branch feature \
    > "$tmp/pin5-out" 2> "$tmp/pin5-err" || pin5_rc=$?
check "PIN5: same-SHA branch switch refuses" "$pin5_rc" "7"
check_contains "PIN5: refusal names the branch mismatch" "$(cat "$tmp/pin5-err")" \
    "is on branch feature-alias but the review was pinned to feature"
check "PIN5: NO ledger rows stamped on a refused run" "$(wc -l < "$PIN5_LEDGER" | tr -d ' ')" "0"
git -C "$WT_REPO" checkout -q main

# ── HIMMEL-1984: --base-sha pins the OTHER end of the reviewed range ─────────
# --head froze the tip, but the BASE was still resolved LIVE at review time, so
# the caller captured one base commit and the panel could review against
# another. PIN6 = a matching base pin runs and the critic sees the PINNED range.
# PIN7/PIN8 = a base that moved past the pin REFUSES (exit 7) in the --worktree
# and the stdin lane, with nothing reviewed and nothing stamped. PIN9 = a
# revision expression is not a pin.
git -C "$WT_REPO" checkout -q feature
pin_base="$(git -C "$WT_REPO" rev-parse main)"
PIN6_LEDGER="$tmp/pin6-ledger.jsonl"
: > "$PIN6_LEDGER"
PIN6_DUMP="$tmp/pin6-diff.txt"
rm -f "$PIN6_DUMP"
pin6_rc=0
CR_LEDGER="$PIN6_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
    PIN_DIFF_DUMP="$PIN6_DUMP" \
    bash "$PANEL" --worktree "$WT_REPO" --head "$wt_moved_head" --branch feature \
    --base-sha "$pin_base" > "$tmp/pin6-out" 2> "$tmp/pin6-err" || pin6_rc=$?
check "PIN6: --base-sha matching the live base runs" "$pin6_rc" "0"
check "PIN6: the critic saw the diff of the PINNED base range" \
    "$(cat "$PIN6_DUMP" 2>/dev/null)" "$(git -C "$WT_REPO" diff "$pin_base...$wt_moved_head")"

# The base branch moves on past the captured SHA. The branch tip is untouched,
# so the --head/--branch halves still pass: only the base pin catches this.
git -C "$WT_REPO" checkout -q main
printf 'base moved after capture\n' > "$WT_REPO/base-moved.txt"
git -C "$WT_REPO" add base-moved.txt
git -C "$WT_REPO" commit -q -m "base moved"
git -C "$WT_REPO" checkout -q feature
PIN7_LEDGER="$tmp/pin7-ledger.jsonl"
: > "$PIN7_LEDGER"
PIN7_DUMP="$tmp/pin7-diff.txt"
rm -f "$PIN7_DUMP"
pin7_rc=0
CR_LEDGER="$PIN7_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
    PIN_DIFF_DUMP="$PIN7_DUMP" \
    bash "$PANEL" --worktree "$WT_REPO" --head "$wt_moved_head" --branch feature \
    --base-sha "$pin_base" > "$tmp/pin7-out" 2> "$tmp/pin7-err" || pin7_rc=$?
check "PIN7: --worktree stale base pin uses the head-pin exit" "$pin7_rc" "7"
check_contains "PIN7: refusal names the moved base" "$(cat "$tmp/pin7-err")" \
    "the base branch moved since the caller captured its inputs"
check "PIN7: NO ledger rows stamped on a refused run" "$(wc -l < "$PIN7_LEDGER" | tr -d ' ')" "0"
check "PIN7: no critic ran (the diff was never handed out)" \
    "$([ -f "$PIN7_DUMP" ] && echo yes || echo no)" "no"

# Stdin lane: the diff is already frozen, so a moved base cannot change what
# THIS lane reviews — but the caller's captured base is stale and the sibling
# lanes of the same run would review a different range, so refuse at the first.
PIN8_LEDGER="$tmp/pin8-ledger.jsonl"
: > "$PIN8_LEDGER"
pin8_rc=0
( cd "$WT_REPO" && printf '%s' "$DIFF" \
    | CR_LEDGER="$PIN8_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
      CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
      bash "$PANEL" --base-sha "$pin_base" > "$tmp/pin8-out" 2> "$tmp/pin8-err" ) || pin8_rc=$?
check "PIN8: stdin lane stale base pin refuses" "$pin8_rc" "7"
check "PIN8: NO ledger rows stamped on a refused stdin run" "$(wc -l < "$PIN8_LEDGER" | tr -d ' ')" "0"

# PIN9: same as PIN4 for the base half — `main` resolves dynamically, so it
# would follow the very move the pin exists to catch.
pin9_rc=0
( cd "$WT_REPO" && printf '%s' "$DIFF" | bash "$PANEL" --base-sha main > "$tmp/pin9-out" 2> "$tmp/pin9-err" ) || pin9_rc=$?
check "PIN9: --base-sha main rejected as a usage error" "$pin9_rc" "2"
check_contains "PIN9: rejection says why" "$(cat "$tmp/pin9-err")" "not a revision expression"
git -C "$WT_REPO" checkout -q main

# PIN10 (panel r3): a MASTER-only repo with no origin/HEAD — the panel's own
# fallback resolves `main`, which does not exist here. /pr-check captures $db
# through default_branch, which finds master, so a SHA-only pin would refuse a
# base that never moved. The caller naming its base with --base is what makes
# the two agree; this pins that the named base is what gets verified.
MASTER_REPO="$tmp/master-only"
git init -q "$MASTER_REPO"
git -C "$MASTER_REPO" checkout -q -b master
git -C "$MASTER_REPO" config user.name test
git -C "$MASTER_REPO" config user.email test@example.invalid
printf 'base\n' > "$MASTER_REPO/f.txt"
git -C "$MASTER_REPO" add f.txt
git -C "$MASTER_REPO" commit -q -m base
master_base="$(git -C "$MASTER_REPO" rev-parse master)"
git -C "$MASTER_REPO" checkout -q -b work
printf 'changed\n' >> "$MASTER_REPO/f.txt"
git -C "$MASTER_REPO" add f.txt
git -C "$MASTER_REPO" commit -q -m work
PIN10_LEDGER="$tmp/pin10-ledger.jsonl"
: > "$PIN10_LEDGER"
pin10_rc=0
( cd "$MASTER_REPO" && printf '%s' "$DIFF" \
    | CR_LEDGER="$PIN10_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
      CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
      bash "$PANEL" --base master --base-sha "$master_base" > "$tmp/pin10-out" 2> "$tmp/pin10-err" ) || pin10_rc=$?
check "PIN10: --base master lets a master-only repo verify its unmoved base" "$pin10_rc" "0"
# Control: without --base the panel falls back to a nonexistent `main` and
# refuses — proving PIN10 passed because the caller named its base.
pin10b_rc=0
( cd "$MASTER_REPO" && printf '%s' "$DIFF"     | CR_LEDGER="$tmp/pin10b-ledger.jsonl" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh"       CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB"       bash "$PANEL" --base-sha "$master_base" > "$tmp/pin10b-out" 2> "$tmp/pin10b-err" ) || pin10b_rc=$?
check "PIN10: control — an unnamed base cannot be verified on a master-only repo" "$pin10b_rc" "7"

# PIN11 (panel r5): the caller's --base NAME wins over CR_BASE_BRANCH. /pr-check
# captures $db through default_branch, which does NOT read CR_BASE_BRANCH — so
# an operator with that env var set had the panel verify the pin against a
# different branch entirely and refuse a base that never moved.
PIN11_LEDGER="$tmp/pin11-ledger.jsonl"
: > "$PIN11_LEDGER"
git -C "$MASTER_REPO" branch -q elsewhere master
git -C "$MASTER_REPO" checkout -q elsewhere
printf 'divergent\n' >> "$MASTER_REPO/f.txt"
git -C "$MASTER_REPO" add f.txt
git -C "$MASTER_REPO" commit -q -m elsewhere
git -C "$MASTER_REPO" checkout -q work
pin11_rc=0
( cd "$MASTER_REPO" && printf '%s' "$DIFF" \
    | CR_BASE_BRANCH=elsewhere CR_LEDGER="$PIN11_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
      CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
      bash "$PANEL" --base master --base-sha "$master_base" > "$tmp/pin11-out" 2> "$tmp/pin11-err" ) || pin11_rc=$?
check "PIN11: --base beats CR_BASE_BRANCH when verifying the pin" "$pin11_rc" "0"
# Control: without --base, the same CR_BASE_BRANCH resolves the OTHER branch and
# the pin correctly refuses — proving PIN11 passed because the flag won.
pin11b_rc=0
( cd "$MASTER_REPO" && printf '%s' "$DIFF" \
    | CR_BASE_BRANCH=elsewhere CR_LEDGER="$tmp/pin11b-ledger.jsonl" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
      CRITICS_JSON="$tmp/critics-pin.json" CRITIC_FIRST_PASS="$PIN_STUB" \
      bash "$PANEL" --base-sha "$master_base" > "$tmp/pin11b-out" 2> "$tmp/pin11b-err" ) || pin11b_rc=$?
check "PIN11: control — without --base the env-resolved base refuses" "$pin11b_rc" "7"

# ── HIMMEL-1494 r2: stdin graceful degrade, base-branch resolution, ──────────
#    citation-less ledger rows. Three panel suggestions, parent premise-
#    verified; each fix has its own fixture and touches only critic-panel.sh.

# Test NWS: stdin review from a NON-worktree cwd degrades gracefully — the
# review runs, a loud warning names the skipped self-append, NO ledger rows are
# written, and the exit code matches pre-change behavior (the review's own 0/1,
# not the old exit 5). Pre-fix this path exited 5; the worktree is only needed
# to STAMP ledger rows.
NWS_DIR="$tmp/non-worktree-cwd"
mkdir -p "$NWS_DIR"
NWS_LEDGER="$tmp/nws-ledger.jsonl"
: > "$NWS_LEDGER"
nws_rc=0
( cd "$NWS_DIR" && printf '%s' "$DIFF" \
    | CR_LEDGER="$NWS_LEDGER" CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
      bash "$PANEL" > "$tmp/nws-out" 2> "$tmp/nws-err" ) || nws_rc=$?
check "NWS: review runs from a non-worktree cwd (exit 0, was 5)" "$nws_rc" "0"
check_contains "NWS: loud self-append-skipped warning" "$(cat "$tmp/nws-err")" "stdin review outside a git worktree"
check_contains "NWS: warning names the skipped self-append" "$(cat "$tmp/nws-err")" "CR-ledger self-append skipped"
check "NWS: merged review output still emitted" "$(grep -cF '# Critic Panel Review' "$tmp/nws-out")" "1"
check "NWS: NO ledger rows written (self-append skipped)" "$(wc -l < "$NWS_LEDGER" | tr -d ' ')" "0"

# Tests B1-B6 share a common repo-construction prefix (git init + checkout -b
# <branch> + config x2 + write r.txt + add + commit) that only the initial
# branch name (master/trunk/develop) distinguishes. Build it ONCE and cp -r +
# branch-rename per scenario instead of re-running the full git sequence 5x
# (HIMMEL-2120). Micro-A/B (5 reps): build-from-scratch 3.68s/rep vs
# template-copy+rename 1.60s/rep — the copy path wins by ~2.3x.
BR_TEMPLATE="$tmp/br-template"
git init -q "$BR_TEMPLATE"
git -C "$BR_TEMPLATE" checkout -q -b master
git -C "$BR_TEMPLATE" config user.name test
git -C "$BR_TEMPLATE" config user.email test@example.invalid
printf 'base\n' > "$BR_TEMPLATE/r.txt"
git -C "$BR_TEMPLATE" add r.txt
git -C "$BR_TEMPLATE" commit -q -m base

# br_from_template <dest> <branch> — cp -r the template, then rename its
# branch from master to <branch> if it differs (a no-op copy when it doesn't).
br_from_template() {
    local dest="$1" branch="$2"
    cp -r "$BR_TEMPLATE" "$dest"
    if [ "$branch" != "master" ]; then
        git -C "$dest" branch -q -m master "$branch"
    fi
}

# Tests B1-B3: --worktree resolves the base branch instead of hardcoding main.
# B1 — CR_BASE_BRANCH wins over origin/HEAD. Fixture: master base + feature
# change, origin/HEAD -> master (valid). An override to a NONEXISTENT branch
# must still win and produce the diff-failed exit naming the override, proving
# origin/HEAD's master was never consulted.
BR_REPO="$tmp/base-resolve-repo"
br_from_template "$BR_REPO" master
# Point origin/HEAD at master so the override-only path is the discriminating one.
git -C "$BR_REPO" update-ref refs/remotes/origin/master "$(git -C "$BR_REPO" rev-parse master)"
git -C "$BR_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
git -C "$BR_REPO" checkout -q -b feature
printf 'change\n' >> "$BR_REPO/r.txt"
git -C "$BR_REPO" add r.txt
git -C "$BR_REPO" commit -q -m feature
b1_rc=0
CR_BASE_BRANCH=zzz-nope-override CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" --worktree "$BR_REPO" > "$tmp/b1-out" 2> "$tmp/b1-err" || b1_rc=$?
check "B1: CR_BASE_BRANCH override is honored (diff fails on the override, exit 5)" "$b1_rc" "5"
check_contains "B1: failed diff names the OVERRIDE base, not origin/HEAD's master" "$(cat "$tmp/b1-err")" "diff zzz-nope-override...HEAD"

# B2 — origin/HEAD fallback (no override). Same fixture; master is a real
# branch, so diffing master...HEAD on feature runs and the panel succeeds —
# proving origin/HEAD resolved to master (the old hardcoded `main` would have
# failed, since this repo has no main branch).
b2_rc=0
CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" --worktree "$BR_REPO" > "$tmp/b2-out" 2> "$tmp/b2-err" || b2_rc=$?
check "B2: origin/HEAD fallback resolves master and the diff runs (exit 0)" "$b2_rc" "0"
check_contains "B2: panel output emitted (diff against master ran)" "$(cat "$tmp/b2-out")" "# Critic Panel Review"

# B3 — final fallback `main`. A repo with NO origin/HEAD and NO CR_BASE_BRANCH,
# on a `trunk` base branch; there is no `main`, so the diff fails and the
# message reveals the resolved base is `main` (not trunk).
BR3_REPO="$tmp/base-resolve-main-fallback"
br_from_template "$BR3_REPO" trunk
git -C "$BR3_REPO" checkout -q -b feature
printf 'change\n' >> "$BR3_REPO/r.txt"
git -C "$BR3_REPO" add r.txt
git -C "$BR3_REPO" commit -q -m feature
b3_rc=0
CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" --worktree "$BR3_REPO" > "$tmp/b3-out" 2> "$tmp/b3-err" || b3_rc=$?
check "B3: no override + no origin/HEAD falls back to main (diff fails, exit 5)" "$b3_rc" "5"
check_contains "B3: failed diff names the FINAL fallback base main" "$(cat "$tmp/b3-err")" "diff main...HEAD"

# B4 — origin/HEAD base that exists ONLY as origin/<name> (no local branch).
# A clone/worktree that never checked the default out locally carries no
# refs/heads/<name>, so the bare name must NOT be diffed. The remote ref
# origin/<name> (which origin/HEAD guaranteed exists) must be diffed instead
# (HIMMEL-1494 r3). Without the fix the bare `develop` fails to resolve and the
# panel exits 5; with it, origin/develop resolves and the diff runs.
BR4_REPO="$tmp/base-resolve-origin-only"
br_from_template "$BR4_REPO" develop
git -C "$BR4_REPO" update-ref refs/remotes/origin/develop "$(git -C "$BR4_REPO" rev-parse develop)"
git -C "$BR4_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
git -C "$BR4_REPO" checkout -q -b feature
printf 'change\n' >> "$BR4_REPO/r.txt"
git -C "$BR4_REPO" add r.txt
git -C "$BR4_REPO" commit -q -m feature
git -C "$BR4_REPO" branch -D develop   # local develop GONE; only origin/develop remains
b4_rc=0
CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" --worktree "$BR4_REPO" > "$tmp/b4-out" 2> "$tmp/b4-err" || b4_rc=$?
check "B4: origin-only base diffs origin/<name> and runs (exit 0)" "$b4_rc" "0"
check_contains "B4: panel output emitted (diff against origin/develop ran)" "$(cat "$tmp/b4-out")" "# Critic Panel Review"

# B5 — when BOTH a local <name> and origin/<name> exist and origin/HEAD -> <name>,
# the bare LOCAL name is used (it verifies), NOT the stale remote (HIMMEL-1494
# r3). Discriminating proof: local develop is AHEAD of origin/develop by one
# commit, so an origin/<name> three-dot diff would include that ancestral change
# while a bare-local diff excludes it. The critic stub echoes a marker derived
# from its stdin (the computed diff), so the merged output names which ref was
# diffed.
BR5_REPO="$tmp/base-resolve-local-verifies"
br_from_template "$BR5_REPO" develop
git -C "$BR5_REPO" update-ref refs/remotes/origin/develop "$(git -C "$BR5_REPO" rev-parse develop)"
git -C "$BR5_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
printf 'origin-only-ancestral-marker\n' >> "$BR5_REPO/r.txt"
git -C "$BR5_REPO" add r.txt
git -C "$BR5_REPO" commit -q -m advance-local-develop   # local develop now AHEAD of origin/develop
git -C "$BR5_REPO" checkout -q -b feature
printf 'feature-change\n' >> "$BR5_REPO/r.txt"
git -C "$BR5_REPO" add r.txt
git -C "$BR5_REPO" commit -q -m feature
B5_STUB="$tmp/b5-cfp.sh"
cat > "$B5_STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Discriminate which base ref was diffed. The ancestral marker is ADDED only
# when origin/develop (C0) is the base; when bare local develop (C0a, which
# already contains the marker) is the base the marker is mere context, so the
# unified-diff ADDITION prefix '+origin-only-ancestral-marker' is present in the
# origin/ diff and absent from the bare-local diff.
input="$(cat)"
if printf '%s' "$input" | grep -qF '+origin-only-ancestral-marker'; then
    ref='ORIGIN-REF-USED'
else
    ref='LOCAL-REF-USED'
fi
printf '# gptoss First-Pass Review\n\n## Critical Issues (1 found)\n- [gptoss-1]: %s [r.txt:3]\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n' "$ref"
STUBEOF
chmod +x "$B5_STUB"
b5_rc=0
CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$B5_STUB" \
    bash "$PANEL" --worktree "$BR5_REPO" > "$tmp/b5-out" 2> "$tmp/b5-err" || b5_rc=$?
check "B5: local-verifies base diffs bare local name and runs (exit 0)" "$b5_rc" "0"
check_contains "B5: bare LOCAL name used (not stale origin/)" "$(cat "$tmp/b5-out")" "LOCAL-REF-USED"

# B6 — tag shadowing (HIMMEL-1494 r4 Fix 2). A repo with NO local branch
# <name>, but BOTH a TAG named <name> AND origin/<name>. r3's bare
# `--verify "$_base"` matched the TAG, falsely satisfying the local-branch
# check and suppressing the origin/<name> fallback; r4 verifies
# refs/heads/<name> so only a real local branch satisfies it, the fallback
# fires, and the diff uses origin/<name>.
# Discriminator (mirrors B5): the tag sits one ancestral commit ABOVE
# origin/<name> (a marker line), so an origin/<name> three-dot diff includes
# the marker as an ADDITION while a tag-based diff (base = the tag commit,
# which is HEAD's ancestor) does not. A stub inspecting its stdin names which
# ref ran.
BR6_REPO="$tmp/base-resolve-tag-shadow"
br_from_template "$BR6_REPO" develop                 # C0: origin/<name> base
_b6_c0="$(git -C "$BR6_REPO" rev-parse HEAD)"
printf 'tag-only-ancestral-marker\n' >> "$BR6_REPO/r.txt"
git -C "$BR6_REPO" add r.txt
git -C "$BR6_REPO" commit -q -m tagpoint              # C1: the TAG's commit
git -C "$BR6_REPO" tag develop                        # tag <name> -> C1
git -C "$BR6_REPO" update-ref refs/remotes/origin/develop "$_b6_c0"
git -C "$BR6_REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
git -C "$BR6_REPO" checkout -q -b feature            # feature from C1
printf 'feature-change\n' >> "$BR6_REPO/r.txt"
git -C "$BR6_REPO" add r.txt
git -C "$BR6_REPO" commit -q -m feature
git -C "$BR6_REPO" branch -D develop                 # local branch GONE; tag + origin/<name> remain
B6_STUB="$tmp/b6-cfp.sh"
cat > "$B6_STUB" <<'STUBEOF'
#!/usr/bin/env bash
# Discriminate which base ref was diffed. origin/develop (C0) as the base
# includes the marker as an ADDITION (the marker is in C1, between C0 and
# HEAD); the tag develop (C1) as the base is HEAD's ancestor, so the marker is
# mere context and the '+...' addition is absent.
input="$(cat)"
if printf '%s' "$input" | grep -qF '+tag-only-ancestral-marker'; then
    ref='ORIGIN-REF-USED'
else
    ref='TAG-REF-USED'
fi
printf '# gptoss First-Pass Review\n\n## Critical Issues (1 found)\n- [gptoss-1]: %s [r.txt:3]\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n' "$ref"
STUBEOF
chmod +x "$B6_STUB"
b6_rc=0
CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$B6_STUB" \
    bash "$PANEL" --worktree "$BR6_REPO" > "$tmp/b6-out" 2> "$tmp/b6-err" || b6_rc=$?
check "B6: tag-shadowed base diffs origin/<name> and runs (exit 0)" "$b6_rc" "0"
check_contains "B6: origin/<name> used (not the shadowing tag)" "$(cat "$tmp/b6-out")" "ORIGIN-REF-USED"

# Test NC: a finding WITHOUT a trailing [file:line] citation must land in the
# ledger with EMPTY file/line (the absent-value convention), not the malformed
# values the old unguarded AWK parse produced from the ID bracket. Inline stub
# so the test stays self-contained (stub-cfp.py is out of the file fence).
NC_STUB="$tmp/nc-cfp.sh"
cat > "$NC_STUB" <<'EOS'
#!/usr/bin/env bash
cat >/dev/null
echo "# nc First-Pass Review"
echo ""
echo "## Critical Issues (1 found)"
echo "- [nc-1]: global concern with no code location"
echo ""
echo "## Important Issues (0 found)"
echo ""
echo "## Suggestions (0 found)"
EOS
chmod +x "$NC_STUB"
NC_JSON="$tmp/critics-nc.json"
printf '%s' '{"panel":[{"slug":"nc","model":"fake/nc","provider":"test","tier":"free"}]}' > "$NC_JSON"
NC_LEDGER="$tmp/nc-ledger.jsonl"
: > "$NC_LEDGER"
printf '%s' "$DIFF" | CR_LEDGER="$NC_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$NC_JSON" CRITIC_FIRST_PASS="$NC_STUB" bash "$PANEL" > "$tmp/nc-out" 2> "$tmp/nc-err"
nc_fields="$(python3 - "$NC_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
f = [r for r in rows if r.get('kind') == 'finding']
print('findings=' + str(len(f)))
if f:
    print('file=' + repr(f[0].get('file', '<MISSING>')))
    print('line=' + repr(f[0].get('line', '<MISSING>')))
else:
    print('file=<no-finding>')
    print('line=<no-finding>')
PYEOF
)"
check "NC: citation-less finding self-appends (one finding row)" "$(printf '%s\n' "$nc_fields" | sed -n 's/^findings=//p')" "1"
check "NC: citation-less finding has EMPTY file" "$(printf '%s\n' "$nc_fields" | sed -n 's/^file=//p')" "''"
check "NC: citation-less finding has EMPTY line" "$(printf '%s\n' "$nc_fields" | sed -n 's/^line=//p')" "''"

# Test E: missing registry -> anchor fallback
stderr_e="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/does-not-exist.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
out_e="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/does-not-exist.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "E: warning on missing registry" "$(printf '%s\n' "$stderr_e" | grep -cF 'anchor-only')" "1"
check "E: anchor used (1/1)" "$(printf '%s\n' "$out_e" | grep -cF '(1/1 critics responded)')" "1"
check_contains "E: anchor finding present" "$out_e" "[$ANCHOR_SLUG-"
# deliberately tied to the stub's qwen-branch text — proves the anchor MODEL ran
check_contains "E: codex anchor branch ran" "$out_e" "[codex-1]:"

printf '{}' > "$tmp/critics-empty.json"
stderr_e2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-empty.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check "E2: empty JSON -> anchor warning" "$(printf '%s\n' "$stderr_e2" | grep -cF 'anchor-only')" "1"

# Test F: tier filter
out_f="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-paid.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
stderr_f="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-paid.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check "F: paid kimi skipped -> 2/2" "$(printf '%s\n' "$out_f" | grep -cF '(2/2 critics responded)')" "1"
# HIMMEL-2129: kimi (tier=paid, excluded by the default free filter) is now
# reported tier-excluded instead of silently invisible, so a ledger row lands
# for clear-cr-marker's CR_FLOOR_FALLBACK=claude-only exhaustion check. Assert
# the honest diagnostic, and that kimi was still never actually CONSULTED.
check_contains "F: paid kimi reported tier-excluded (HIMMEL-2129)" "$stderr_f" \
    "panel-availability: kimi unavailable (tier=paid not in filter(free)) reason=tier-excluded"
check "F: kimi never actually consulted (no ok line)" \
    "$(printf '%s\n' "$stderr_f" | grep -cF 'panel-availability: kimi ok')" "0"

# Test FL (HIMMEL-2129, HIMMEL-2128 follow-up): the tier-excluded critic (kimi,
# tier=paid, deselected by the default free filter) lands a REAL ledger row
# with a NON-exhaustion reason, so clear-cr-marker.sh's
# CR_FLOOR_FALLBACK=claude-only exhaustion check can see it was deselected --
# not silently absent, which looked identical to "never configured" before
# this ticket. The two ACTUAL responders (qwen3coder, gptoss) are unaffected:
# same avail-ok rows, same panel exit code (requirement: selected-critic
# behavior + exit code stay unchanged).
FL_LEDGER="$tmp/fl-ledger.jsonl"
: > "$FL_LEDGER"
CR_LEDGER="$FL_LEDGER" CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" \
    CRITICS_JSON="$tmp/critics-paid.json" CRITIC_FIRST_PASS="$STUB" \
    bash "$PANEL" <<< "$DIFF" > "$tmp/fl-out" 2> "$tmp/fl-err"
fl_rc=$?
fl_summary="$(python3 - "$FL_LEDGER" <<'PYEOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
avail = [r for r in rows if r.get('kind') == 'avail']
kimi = [r for r in avail if r.get('model') == 'kimi']
print('avail=' + str(len(avail)))
print('ok=' + str(sum(r.get('status') == 'ok' for r in avail)))
print('kimi-count=' + str(len(kimi)))
print('kimi-status=' + (kimi[0].get('status', '') if kimi else 'MISSING'))
print('kimi-reason=' + (kimi[0].get('reason', '') if kimi else 'MISSING'))
PYEOF
)"
check "FL: panel exit code unaffected" "$fl_rc" "0"
check "FL: 3 avail rows (2 real responders + 1 tier-excluded)" \
    "$(printf '%s\n' "$fl_summary" | sed -n 's/^avail=//p')" "3"
check "FL: the 2 real responders are still ok" "$(printf '%s\n' "$fl_summary" | sed -n 's/^ok=//p')" "2"
check "FL: exactly one kimi avail row (not double-counted)" \
    "$(printf '%s\n' "$fl_summary" | sed -n 's/^kimi-count=//p')" "1"
check "FL: kimi row is unavailable" "$(printf '%s\n' "$fl_summary" | sed -n 's/^kimi-status=//p')" "unavailable"
check "FL: kimi reason is tier-excluded (NOT an exhaustion class)" \
    "$(printf '%s\n' "$fl_summary" | sed -n 's/^kimi-reason=//p')" "tier-excluded"

# Test G: header format
check "G: Critic Panel Review header" "$(printf '%s\n' "$out_b" | grep -cF '# Critic Panel Review')" "1"

# Test H: section headings
check "H: Critical Issues heading" "$(printf '%s\n' "$out_b" | grep -cF '## Critical Issues')" "1"
check "H: Important Issues heading" "$(printf '%s\n' "$out_b" | grep -cF '## Important Issues')" "1"
check "H: Suggestions heading" "$(printf '%s\n' "$out_b" | grep -cF '## Suggestions')" "1"

# Test I1: (N found) recount in merged output
# Two responders: qwen3coder (1 crit, 1 imp, 1 sug) + gptoss (0 crit, 1 imp, 0 sug) = 1 crit, 2 imp, 1 sug
check_contains "I1: Critical Issues (1 found)" "$out_a" "## Critical Issues (1 found)"
check_contains "I1: Important Issues (2 found)" "$out_a" "## Important Issues (2 found)"
check_contains "I1: Suggestions (1 found)" "$out_a" "## Suggestions (1 found)"

# Test I2: malformed-JSON registry falls back to anchor
printf '{not json}' > "$tmp/critics-bad.json"
stderr_i2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-bad.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
out_i2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-bad.json" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "I2: malformed JSON -> anchor warning" "$(printf '%s\n' "$stderr_i2" | grep -cF 'anchor-only')" "1"
check_contains "I2: malformed JSON -> anchor finding present" "$out_i2" "[$ANCHOR_SLUG-"
# deliberately tied to the stub's qwen-branch text — proves the anchor MODEL ran
check_contains "I2: codex anchor branch ran" "$out_i2" "[codex-1]:"

# Test J: per-member timeout — hung member bounded and dropped
STUB_HANG="$tmp/stub-hang.sh"
printf '%s\n' '#!/usr/bin/env bash' > "$STUB_HANG"
printf '%s\n' 'sleep 999' >> "$STUB_HANG"
chmod +x "$STUB_HANG"

HANG_JSON="$tmp/critics-hang.json"
printf '%s\n' '{"panel":[{"slug":"hang-critic","model":"fake/hang","provider":"test","tier":"free"}]}' > "$HANG_JSON"

# retry_once <case-fn> — loaded-runner tolerance for the timing-sensitive
# cases below (HIMMEL-963: J1/K1/K2 flip under CI runner contention). Runs the
# case as a silent probe; on failure re-runs it ONCE and lets the checks after
# report on the second attempt's captured globals. Never masks a deterministic
# failure — a real bug fails both attempts.
retry_once() {
    "$1" && return 0
    echo "note - $1: probe failed once, retrying (loaded-runner tolerance)"
    "$1" || true
}

# Only run this test if 'timeout' is available (same condition as the panel uses)
if command -v timeout > /dev/null 2>&1; then
    # Outer timeout 20 (was 5): only a backstop against a genuinely hung panel.
    # The tight 5s margin raced panel startup + the 2s member timeout on loaded
    # runners (outer kill -> rc=124, stderr lines never emitted).
    j1_case() {
        j_rc=0
        stderr_j="$(printf '%s' "$DIFF" | CRITIC_TIMEOUT_SECS=2 CRITICS_JSON="$HANG_JSON" CRITIC_FIRST_PASS="$STUB_HANG" \
            timeout 20 bash "$PANEL" 2>&1 >/dev/null)" || j_rc=$?
        grepq "$stderr_j" -F "unavailable (timeout 2s)" \
            && grepq "$stderr_j" -F "hang-critic" \
            && [ "$j_rc" = "1" ]
    }
    retry_once j1_case

    check_contains "J1: hung member timeout in stderr" "$stderr_j" "unavailable (timeout 2s)"
    check_contains "J1: hung member slug in stderr" "$stderr_j" "hang-critic"
    check "J1: all-hang -> exit 1" "$j_rc" "1"

    # Test J2 (HIMMEL-1245): a row's OPT-IN timeout_secs governs even when the
    # shared CRITIC_TIMEOUT_SECS default is much larger — proves the per-row
    # value actually threads through the timeout wrap, not just gets parsed.
    HANG_OVERRIDE_JSON="$tmp/critics-hang-override.json"
    printf '%s\n' '{"panel":[{"slug":"hang-critic2","model":"fake/hang2","provider":"test","tier":"free","timeout_secs":1}]}' > "$HANG_OVERRIDE_JSON"

    j2_case() {
        j2_rc=0
        stderr_j2="$(printf '%s' "$DIFF" | CRITIC_TIMEOUT_SECS=20 CRITICS_JSON="$HANG_OVERRIDE_JSON" CRITIC_FIRST_PASS="$STUB_HANG" \
            timeout 20 bash "$PANEL" 2>&1 >/dev/null)" || j2_rc=$?
        grepq "$stderr_j2" -F "unavailable (timeout 1s)" \
            && grepq "$stderr_j2" -F "hang-critic2" \
            && [ "$j2_rc" = "1" ]
    }
    retry_once j2_case

    check_contains "J2: row timeout_secs overrides shared default (1s, not 20s)" "$stderr_j2" "unavailable (timeout 1s)"
    check_contains "J2: overridden member slug in stderr" "$stderr_j2" "hang-critic2"
    check "J2: all-hang (override) -> exit 1" "$j2_rc" "1"

    # Test J3 (HIMMEL-1245): an INVALID timeout_secs (non-numeric) must NOT fail
    # the row — it falls back to the shared CRITIC_TIMEOUT_SECS default, with a
    # stderr note (mirrors the existing CRITIC_TIMEOUT_SECS-itself validation).
    HANG_BAD_JSON="$tmp/critics-hang-bad.json"
    printf '%s\n' '{"panel":[{"slug":"hang-critic3","model":"fake/hang3","provider":"test","tier":"free","timeout_secs":"nope"}]}' > "$HANG_BAD_JSON"

    j3_case() {
        j3_rc=0
        stderr_j3="$(printf '%s' "$DIFF" | CRITIC_TIMEOUT_SECS=2 CRITICS_JSON="$HANG_BAD_JSON" CRITIC_FIRST_PASS="$STUB_HANG" \
            timeout 20 bash "$PANEL" 2>&1 >/dev/null)" || j3_rc=$?
        grepq "$stderr_j3" -F "unavailable (timeout 2s)" \
            && grepq "$stderr_j3" -F "hang-critic3" \
            && [ "$j3_rc" = "1" ]
    }
    retry_once j3_case

    check_contains "J3: invalid timeout_secs falls back to shared default (2s)" "$stderr_j3" "unavailable (timeout 2s)"
    check_contains "J3: invalid timeout_secs logs a warning" "$stderr_j3" "timeout_secs=nope invalid, using shared default"
    check "J3: all-hang (invalid override) -> exit 1" "$j3_rc" "1"
else
    # HIMMEL-2226 (HIMMEL-2258 audit): this branch used to emit the "ok - "
    # pass token, so a runner without GNU timeout silently credited 9 passes
    # for assertions that never ran. Route through skip() instead.
    skip "J1: no timeout binary"
    skip "J1: no timeout binary"
    skip "J1: no timeout binary"
    skip "J2: no timeout binary"
    skip "J2: no timeout binary"
    skip "J2: no timeout binary"
    skip "J3: no timeout binary"
    skip "J3: no timeout binary"
    skip "J3: no timeout binary"
fi

# Tests K1+K2+K3: parallel mode (CRITIC_PARALLEL=1)
# Wrapped in timeout guard like J1 — parallel tests require the 'timeout' binary
# to bound CI runs if something hangs.
if command -v timeout > /dev/null 2>&1; then

    # K1: Determinism — parallel output must be byte-identical to sequential.
    # The real proof: critic-0 (qwen3coder, index 0 in registry) is SLOW (sleep 2),
    # critic-1 (gptoss, index 1) is INSTANT. In parallel mode critic-1 finishes first,
    # but the merged output MUST still be in registry order (qwen3coder findings first,
    # numbered before gptoss findings). We assert:
    #   (a) parallel stdout == sequential stdout (byte-identical convergence)
    #   (b) qwen3coder slug-IDs come before gptoss slug-IDs in the merged output
    # A bug that merged in completion order would put gptoss-1 before qwen3coder-*
    # and fail both assertions.
    STUB_SLOW="$tmp/stub-cfp-slow.sh"
    # stub-cfp-slow.py: same as stub-cfp.py but qwen3coder sleeps 2s first
    python3 - "$tmp" <<'PYEOF'
import sys, os
src = os.path.join(sys.argv[1], "stub-cfp-slow.py")
open(src, "w").write("""\
#!/usr/bin/env python3
import sys, time

model = ""
slug = ""
args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--model" and i+1 < len(args):
        model = args[i+1]; i += 2
    elif args[i] == "--slug" and i+1 < len(args):
        slug = args[i+1]; i += 2
    else:
        i += 1

sys.stdin.read()

if model == "qwen/qwen3-coder-480b-a35b-instruct":
    time.sleep(2)  # slow: finishes AFTER gptoss in parallel mode
    print("# qwen3coder First-Pass Review")
    print("")
    print("## Critical Issues (1 found)")
    print("- [qwen3coder-1]: null dereference in handler [foo.sh:3]")
    print("")
    print("## Important Issues (1 found)")
    print("- [qwen3coder-2]: unused variable x [foo.sh:5]")
    print("")
    print("## Suggestions (1 found)")
    print("- [qwen3coder-3]: rename for clarity [foo.sh:7]")
    sys.exit(0)
elif model == "openai/gpt-oss-120b":
    # instant: finishes BEFORE qwen3coder in parallel mode
    print("# gptoss First-Pass Review")
    print("")
    print("## Critical Issues (0 found)")
    print("")
    print("## Important Issues (1 found)")
    print("- [gptoss-1]: missing error check [bar.sh:2]")
    print("")
    print("## Suggestions (0 found)")
    sys.exit(0)
else:
    print("stub-cfp-slow: unknown model:", model, file=sys.stderr)
    sys.exit(1)
""")
PYEOF
    printf '%s\n' '#!/usr/bin/env bash' > "$STUB_SLOW"
    printf 'exec python3 "%s/stub-cfp-slow.py" "$@"\n' "$tmp" >> "$STUB_SLOW"
    chmod +x "$STUB_SLOW"

    DATA_2='{"panel":[
  {"slug":"qwen3coder","model":"qwen/qwen3-coder-480b-a35b-instruct","provider":"test","tier":"free"},
  {"slug":"gptoss","model":"openai/gpt-oss-120b","provider":"test","tier":"free"}
]}'
    printf '%s' "$DATA_2" > "$tmp/critics-2.json"

    # (a) byte-identical convergence: slow-critic-0 + instant-critic-1, parallel == sequential
    # timeout 60 (was 30) + retry_once: the merge logic is deterministic, but a
    # thrashing runner can trip the outer timeout and truncate one capture.
    k1_case() {
        out_seq="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-2.json" CRITIC_FIRST_PASS="$STUB_SLOW" CRITIC_PARALLEL=0 timeout 60 bash "$PANEL" 2>/dev/null)"
        out_par="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-2.json" CRITIC_FIRST_PASS="$STUB_SLOW" CRITIC_PARALLEL=1 timeout 60 bash "$PANEL" 2>/dev/null)"
        [ -n "$out_seq" ] && [ "$out_seq" = "$out_par" ]
    }
    retry_once k1_case
    check "K1: parallel output identical to sequential (slow critic-0)" "$out_seq" "$out_par"

    # (b) registry order: qwen3coder-1 must appear before gptoss-* in merged output
    qwen_line="$(printf '%s\n' "$out_par" | grep -n '\[qwen3coder-1\]:' | head -1 | cut -d: -f1)"
    gptoss_line="$(printf '%s\n' "$out_par" | grep -n '\[gptoss-' | head -1 | cut -d: -f1)"
    if [ -n "$qwen_line" ] && [ -n "$gptoss_line" ] && [ "$qwen_line" -lt "$gptoss_line" ]; then
        echo "ok - K1: qwen3coder-* before gptoss-* in merged output (registry order)"
    else
        echo "FAIL - K1: registry order not preserved (qwen3coder line=$qwen_line gptoss line=$gptoss_line)"
        fails=$((fails + 1))
    fi

    # K2: Parallel member-drop — kimi fails in parallel mode; check availability + header
    # Note: critics-all.json has kimi which fails (stub exits 1 for kimi model)
    # Run twice: once for stderr, once for stdout (can't capture both at once cleanly)
    # timeout 60 (was 30) + retry_once: same loaded-runner tolerance as K1.
    k2_case() {
        stderr_k2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" CRITIC_PARALLEL=1 timeout 60 bash "$PANEL" 2>&1 >/dev/null)"
        out_k2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/critics-all.json" CRITIC_FIRST_PASS="$STUB" CRITIC_PARALLEL=1 timeout 60 bash "$PANEL" 2>/dev/null)"
        grepq "$stderr_k2" -F 'panel-availability: kimi unavailable' \
            && grepq "$out_k2" -F '(2/3 critics responded)'
    }
    retry_once k2_case
    check "K2: parallel kimi unavailable" "$(printf '%s\n' "$stderr_k2" | grep -cF 'panel-availability: kimi unavailable')" "1"
    check "K2: parallel header 2/3" "$(printf '%s\n' "$out_k2" | grep -cF '(2/3 critics responded)')" "1"

else
    # HIMMEL-2226 (HIMMEL-2258 audit): was "ok - " (silently-credited passes).
    skip "K1: no timeout binary"
    skip "K1: no timeout binary"
    skip "K1: no timeout binary"
    skip "K2: no timeout binary"
    skip "K2: no timeout binary"
fi

# Tests L: CR_PROFILE tier resolution (HIMMEL-558).
# Fixture with a paid + a free critic, BOTH answered by the stub (qwen, gptoss),
# so tier SELECTION is what's under test (unlike critics-paid.json where the paid
# row is kimi, which the stub always fails).
CRP_JSON="$tmp/critics-crprofile.json"
printf '%s' '{"panel":[
  {"slug":"qwen3coder","model":"qwen/qwen3-coder-480b-a35b-instruct","provider":"test","tier":"paid"},
  {"slug":"gptoss","model":"openai/gpt-oss-120b","provider":"test","tier":"free"}
]}' > "$CRP_JSON"

# L1: CR_PROFILE=paid → only the paid row (qwen) is selected; free (gptoss) is not.
out_l1="$(printf '%s' "$DIFF"    | CR_PROFILE=paid CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
stderr_l1="$(printf '%s' "$DIFF" | CR_PROFILE=paid CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check_contains "L1: tiers resolved from CR_PROFILE" "$stderr_l1" "tiers=paid (from CR_PROFILE=paid)"
check "L1: paid-only -> 1/1 responded" "$(printf '%s\n' "$out_l1" | grep -cF '(1/1 critics responded)')" "1"
# HIMMEL-2129: gptoss (tier=free, excluded by CR_PROFILE=paid) is now reported
# tier-excluded instead of silently invisible. Assert the honest diagnostic,
# and that gptoss was still never actually CONSULTED (no "ok" avail line).
check_contains "L1: free row gptoss reported tier-excluded (HIMMEL-2129)" "$stderr_l1" \
    "panel-availability: gptoss unavailable (tier=free not in filter(paid)) reason=tier-excluded"
check "L1: gptoss never actually consulted (no ok line)" \
    "$(printf '%s\n' "$stderr_l1" | grep -cF 'panel-availability: gptoss ok')" "0"
# The paid row's slug/model equals the panel anchor, so a regressed paid-selection
# would fall back to anchor-only (also qwen, also 1/1). Assert no anchor fallback
# so the 1/1 above can only mean genuine paid selection, not the fallback.
check "L1: no anchor fallback (real paid selection, not fallback)" "$(printf '%s\n' "$stderr_l1" | grep -cF 'anchor-only')" "0"

# L2: CR_PROFILE=free,paid → both rows selected.
out_l2="$(printf '%s' "$DIFF" | CR_PROFILE="free,paid" CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "L2: free,paid -> 2/2 responded" "$(printf '%s\n' "$out_l2" | grep -cF '(2/2 critics responded)')" "1"

# L3 (KEY structural test): CR_PROFILE WINS over a hand-set CRITIC_PANEL_TIERS.
# A run that hardcoded CRITIC_PANEL_TIERS=free must NOT scope out the paid critic
# when CR_PROFILE=free,paid — this is the exact drift HIMMEL-558 closes.
out_l3="$(printf '%s' "$DIFF" | CRITIC_PANEL_TIERS=free CR_PROFILE="free,paid" CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
check "L3: CR_PROFILE wins over CRITIC_PANEL_TIERS=free -> 2/2 (not free-only 1/1)" "$(printf '%s\n' "$out_l3" | grep -cF '(2/2 critics responded)')" "1"

# L4: CR_PROFILE=thorough → tiers=free,thorough (only the free row matches here).
out_l4="$(printf '%s' "$DIFF"    | CR_PROFILE=thorough CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
stderr_l4="$(printf '%s' "$DIFF" | CR_PROFILE=thorough CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check_contains "L4: thorough maps to free,thorough" "$stderr_l4" "tiers=free,thorough (from CR_PROFILE=thorough)"
check "L4: thorough selects only the free row -> 1/1" "$(printf '%s\n' "$out_l4" | grep -cF '(1/1 critics responded)')" "1"
check "L4: no anchor fallback" "$(printf '%s\n' "$stderr_l4" | grep -cF 'anchor-only')" "0"

# L5: CR_PROFILE unset → the CRITIC_PANEL_TIERS override still governs (back-compat).
out_l5="$(printf '%s' "$DIFF"    | CRITIC_PANEL_TIERS=free CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
stderr_l5="$(printf '%s' "$DIFF" | CRITIC_PANEL_TIERS=free CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check "L5: unset CR_PROFILE + CRITIC_PANEL_TIERS=free -> free-only 1/1" "$(printf '%s\n' "$out_l5" | grep -cF '(1/1 critics responded)')" "1"
check "L5: no CR_PROFILE resolution line when unset" "$(printf '%s\n' "$stderr_l5" | grep -cF 'from CR_PROFILE')" "0"

# L6: CR_PROFILE=none exercises the load-bearing `!= "none"` guard branch. The
# runbook skips the panel on none, but if none ever reaches the panel it must
# fall through to the CRITIC_PANEL_TIERS/default path (a VISIBLE free run), never
# an anchor-only run. Dropping the guard would send none into case *) -> tier
# "none" -> zero rows -> anchor-only; this test locks that contract.
out_l6="$(printf '%s' "$DIFF"    | CR_PROFILE=none CRITIC_PANEL_TIERS=free CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>/dev/null)"
stderr_l6="$(printf '%s' "$DIFF" | CR_PROFILE=none CRITIC_PANEL_TIERS=free CRITICS_JSON="$CRP_JSON" CRITIC_FIRST_PASS="$STUB" bash "$PANEL" 2>&1 >/dev/null)"
check "L6: none falls through to free panel -> 1/1" "$(printf '%s\n' "$out_l6" | grep -cF '(1/1 critics responded)')" "1"
check "L6: none does NOT resolve via CR_PROFILE path" "$(printf '%s\n' "$stderr_l6" | grep -cF 'from CR_PROFILE')" "0"
check "L6: none does NOT trigger anchor-only fallback" "$(printf '%s\n' "$stderr_l6" | grep -cF 'anchor-only')" "0"

# ── WS4 (HIMMEL-414): --check registry health probe ─────────────────────────
# Stub the CRITIC_INVOKE seam: ok for every model except one containing "deadmodel".
CHK_INVOKE="$tmp/chk-invoke.sh"
cat > "$CHK_INVOKE" <<'EOS'
#!/usr/bin/env bash
m=""
while [ $# -gt 0 ]; do case "$1" in --model) m="$2"; shift 2;; --prompt-file) shift 2;; *) shift;; esac; done
case "$m" in
  *deadmodel*) exit 1;;
  *) printf 'ok\n'; exit 0;;
esac
EOS
chmod +x "$CHK_INVOKE"

# Registry: two free (one ok, one dead) + one paid.
CHK_JSON="$tmp/critics-check.json"
printf '%s' '{"panel":[
  {"slug":"okrow","model":"vendor/okmodel","provider":"test","tier":"free"},
  {"slug":"deadrow","model":"vendor/deadmodel","provider":"test","tier":"free"},
  {"slug":"paidrow","model":"vendor/paidmodel","provider":"test","tier":"paid"}
]}' > "$CHK_JSON"

# M1: --check does not hang with no diff on stdin (times out => FAIL).
chk_out="$(CRITICS_JSON="$CHK_JSON" CRITIC_INVOKE="$CHK_INVOKE" timeout 15 bash "$PANEL" --check </dev/null 2>&1)"; chk_rc=$?
check "M1: --check terminates (not 124 timeout)" "$([ "$chk_rc" != "124" ] && echo ok)" "ok"
# M2: ok row reported ok.
check_contains "M2: okrow ok" "$chk_out" "row okrow: ok"
# M3: dead row reported dead with rc.
check_contains "M3: deadrow dead" "$chk_out" "row deadrow: dead (rc=1)"
# M4: paid row skipped by default (no --all-tiers).
check_contains "M4: paidrow skipped (paid)" "$chk_out" "row paidrow: skipped (paid)"
# M5: any dead row => exit 1.
check "M5: dead row -> exit 1" "$chk_rc" "1"

# M6: all-ok registry => exit 0.
OK_JSON="$tmp/critics-check-ok.json"
printf '%s' '{"panel":[{"slug":"okrow","model":"vendor/okmodel","provider":"test","tier":"free"}]}' > "$OK_JSON"
CRITICS_JSON="$OK_JSON" CRITIC_INVOKE="$CHK_INVOKE" timeout 15 bash "$PANEL" --check </dev/null >/dev/null 2>&1
check "M6: all-ok -> exit 0" "$?" "0"

# M7: --all-tiers probes the paid row too (paid model is ok here => still exit 0, and reported ok not skipped).
ALLTIER_OUT="$(CRITICS_JSON="$CHK_JSON" CRITIC_INVOKE="$CHK_INVOKE" timeout 15 bash "$PANEL" --check --all-tiers </dev/null 2>&1)"
check_contains "M7: --all-tiers probes paid row" "$ALLTIER_OUT" "row paidrow: ok"

# M8 (code-reviewer CR): unknown flag errors (exit 2), consistent with siblings.
CRITICS_JSON="$CHK_JSON" bash "$PANEL" --bogus </dev/null >/dev/null 2>&1
check "M8: unknown flag -> exit 2" "$?" "2"

# P4 (code-reviewer CR): the PARALLEL path threads --perspective-file too (P1-P3
# cover only the sequential loop; the parallel loop duplicates the wiring).
if command -v timeout > /dev/null 2>&1; then
    CAP_P="$tmp/persp-argv-par"; PSTUB_P="$tmp/pstub-par.sh"
    cat > "$PSTUB_P" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAP_P"
echo "# s First-Pass Review"; echo ""; echo "## Critical Issues (0 found)"; echo ""; echo "## Important Issues (0 found)"; echo ""; echo "## Suggestions (0 found)"
EOS
    chmod +x "$PSTUB_P"
    PJSON="$tmp/critics-persp.json"
    printf '%s' '{"panel":[{"slug":"skept","model":"vendor/m","provider":"test","tier":"free","perspective":"perspectives/skeptic.md"}]}' > "$PJSON"
    printf '%s' "$DIFF" | CRITICS_JSON="$PJSON" CRITIC_FIRST_PASS="$PSTUB_P" CRITIC_PARALLEL=1 timeout 20 bash "$PANEL" >/dev/null 2>&1
    check_contains "P4: parallel path threads --perspective-file" "$(cat "$CAP_P" 2>/dev/null)" "--perspective-file"
else
    # HIMMEL-2226 (HIMMEL-2258 audit): was "ok - " (a silently-credited pass).
    skip "P4: no timeout binary"
fi
# Tests P: perspective rows are threaded to critic-first-pass without changing
# the merged stdout contract.
CAPTURE_STUB="$tmp/capture-cfp.sh"
CAPTURE_FILE="$tmp/capture-args.txt"
cat > "$CAPTURE_STUB" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE_FILE"
cat >/dev/null
printf '%s\n' '## Critical Issues (1 found)'
printf '%s\n' '- [x-1]: y [foo.sh:2]'
printf '%s\n' '## Important Issues (0 found)'
printf '%s\n' '## Suggestions (0 found)'
EOS
chmod +x "$CAPTURE_STUB"

PERSPECTIVE_JSON="$tmp/critics-perspective.json"
printf '%s' '{"panel":[{"slug":"skeptic","model":"fake/perspective","provider":"test","tier":"free","perspective":"perspectives/skeptic.md"}]}' > "$PERSPECTIVE_JSON"
PLAIN_JSON="$tmp/critics-plain.json"
printf '%s' '{"panel":[{"slug":"plain","model":"fake/plain","provider":"test","tier":"free"}]}' > "$PLAIN_JSON"

: > "$CAPTURE_FILE"
out_p1="$(printf '%s' "$DIFF" | CRITICS_JSON="$PERSPECTIVE_JSON" CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$PANEL" 2>/dev/null)"
check "P1: perspective flag passed to first-pass" "$(grep -c -- '--perspective-file' "$CAPTURE_FILE")" "1"
check "P1: perspective path passed to first-pass" "$(grep -c 'perspectives/skeptic.md' "$CAPTURE_FILE")" "1"
check "P3: merged stdout keeps pr-check bullet contract" "$(grepq "$out_p1" -E '^- \[[a-z0-9]+-[0-9]+\]: .*\[[^]]+:[0-9]+\]$' && echo yes || echo no)" "yes"

: > "$CAPTURE_FILE"
printf '%s' "$DIFF" | CRITICS_JSON="$PLAIN_JSON" CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$PANEL" >/dev/null 2>&1
check "P2: row without perspective omits flag" "$(grep -c -- '--perspective-file' "$CAPTURE_FILE")" "0"

# Test PV: OPT-IN route_provider threaded to first-pass as --provider
# (HIMMEL-727) so model ids newer than hermes' catalog can't fall to its
# default provider. The descriptive "provider" metadata key alone must NOT
# thread (blanket --provider broke alias-routed rows: 401 on alibaba).
PROV_JSON="$tmp/critics-provider.json"
printf '%s' '{"panel":[{"slug":"routed","model":"fake/newid:free","provider":"openrouter","route_provider":"openrouter","tier":"free"}]}' > "$PROV_JSON"
: > "$CAPTURE_FILE"
printf '%s' "$DIFF" | CRITICS_JSON="$PROV_JSON" CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$PANEL" >/dev/null 2>&1
check "PV1: --provider openrouter passed to first-pass" "$(grep -c -- '--provider openrouter' "$CAPTURE_FILE")" "1"
PROVMETA_JSON="$tmp/critics-provider-meta.json"
printf '%s' '{"panel":[{"slug":"meta","model":"fake/meta","provider":"openrouter","tier":"free"}]}' > "$PROVMETA_JSON"
: > "$CAPTURE_FILE"
printf '%s' "$DIFF" | CRITICS_JSON="$PROVMETA_JSON" CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$PANEL" >/dev/null 2>&1
check "PV2: provider metadata alone does NOT thread --provider <name>" "$(grep -c -- '--provider openrouter' "$CAPTURE_FILE")" "0"
# PV3: the anchor-only fallback row (registry missing) must carry the anchor's
# route_provider to the invocation seam — the anchor model is provider-pinned,
# so a bare row would route it to the wrong backend exactly on the recovery path.
: > "$CAPTURE_FILE"
printf '%s' "$DIFF" | CRITICS_JSON="$tmp/does-not-exist.json" CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$PANEL" >/dev/null 2>&1
check "PV3: anchor-only fallback threads --provider ANCHOR_PROVIDER" "$(grep -c -- "--provider $ANCHOR_PROVIDER" "$CAPTURE_FILE")" "1"

# Test O: operator-local registry overlay (HIMMEL-727 + HIMMEL-1221 merge).
# critics.local.json next to the panel is now MERGED per-slug OVER critics.json
# (was: wholesale replacement) — a local-only slug appends, a base-only slug
# survives; CRITICS_JSON env still wins over both (no merge). Run a COPY of the
# panel from a tmp dir so the repo tree is never polluted with a local overlay
# file (concurrent sessions share this checkout).
mkdir -p "$tmp/panelcopy"
cp "$PANEL" "$tmp/panelcopy/critic-panel.sh"
printf '%s' '{"panel":[{"slug":"repodefault","model":"fake/repo","provider":"test","tier":"free"}]}' > "$tmp/panelcopy/critics.json"
printf '%s' '{"panel":[{"slug":"localoverlay","model":"fake/local","provider":"test","tier":"free"}]}' > "$tmp/panelcopy/critics.local.json"
stderr_l="$(printf '%s' "$DIFF" | CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check "O1: local overlay used when present" "$(printf '%s\n' "$stderr_l" | grep -cF 'panel-availability: localoverlay')" "1"
# HIMMEL-1221: the base row is now MERGED IN (not masked by the overlay). Reverting
# Change 2 to wholesale replacement makes this assertion fail — it guards the shift.
check "O1: base row also merged in (HIMMEL-1221)" "$(printf '%s\n' "$stderr_l" | grep -cF 'panel-availability: repodefault')" "1"
check "O1: overlay merge announced on stderr" "$(printf '%s\n' "$stderr_l" | grep -cF 'critics.local.json')" "1"
stderr_l2="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/panelcopy/critics.json" CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check "O2: CRITICS_JSON env wins over local overlay" "$(printf '%s\n' "$stderr_l2" | grep -cF 'panel-availability: repodefault')" "1"
rm -f "$tmp/panelcopy/critics.local.json"
stderr_l3="$(printf '%s' "$DIFF" | CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check "O3: no overlay -> repo registry" "$(printf '%s\n' "$stderr_l3" | grep -cF 'panel-availability: repodefault')" "1"

# --- HIMMEL-1280: liveness beacon + total-panel deadline --------------------
#
# The wedge this guards against produced 0 bytes and ~0.1 CPU-seconds with NO
# child process: the shell never reached its first echo. A 0-byte output is
# otherwise ambiguous between "still thinking" and "never started", and a live
# session waited 3h13m on the wrong reading.

beacon_out="$(printf '%s' "$DIFF" | CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check_contains "W1: beacon is emitted" "$beacon_out" "critic-panel.sh: START pid="
# It must be the FIRST line: anything printed before it is work that could
# block, which would re-open the ambiguity the beacon exists to remove.
check "W1: beacon is the FIRST stderr line" "$(printf '%s
' "$beacon_out" | head -1 | grep -c 'critic-panel.sh: START pid=')" "1"

# The beacon must survive a registry that cannot be read at all — that failure
# happens AFTER the beacon, so absence still means "never started".
bad_reg_out="$(printf '%s' "$DIFF" | CRITICS_JSON=/nonexistent/nope.json CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check_contains "W2: beacon precedes even a registry failure" "$bad_reg_out" "critic-panel.sh: START pid="

# Total-panel deadline: 1s budget, and the stub burns >1s on the first member,
# so the SECOND member must be skipped and reported unavailable rather than run.
SLOW_STUB="$tmp/slow-cfp.sh"
cat > "$SLOW_STUB" <<'SLOW'
#!/usr/bin/env bash
sleep 2
echo "## Critical Issues (0 found)"
echo "## Important Issues (0 found)"
echo "## Suggestions (0 found)"
SLOW
chmod +x "$SLOW_STUB"
# TWO rows: the deadline is checked BETWEEN members, so a single-member
# registry never reaches the check at all. The first member burns past the 1s
# budget; the second must be skipped.
printf '%s' '{"panel":[{"slug":"dl1","model":"fake/one","provider":"test","tier":"free"},{"slug":"dl2","model":"fake/two","provider":"test","tier":"free"}]}' > "$tmp/dl-critics.json"
dl_out="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/dl-critics.json" CRITIC_PANEL_TOTAL_TIMEOUT_SECS=1 CRITIC_FIRST_PASS="$SLOW_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check_contains "W3: total deadline announces itself" "$dl_out" "TOTAL panel deadline"
check_contains "W3: skipped member is reported unavailable, not silently dropped" "$dl_out" "reason=panel-deadline"
check_contains "W3: it is the SECOND member that was skipped" "$dl_out" "panel-availability: dl2 unavailable (panel-deadline)"

# 0 disables the cap. Uses the SAME slow stub and two-row registry as W3 — the
# identical setup that DID trip the deadline there, so the only difference is
# the cap being off. With the fast stub this would pass vacuously (nothing to
# exceed) and prove nothing about the disable path.
off_out="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/dl-critics.json" CRITIC_PANEL_TOTAL_TIMEOUT_SECS=0 CRITIC_FIRST_PASS="$SLOW_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check "W4: 0 disables the cap (no deadline line) under the SAME load that tripped W3" "$(printf '%s
' "$off_out" | grep -c 'TOTAL panel deadline')" "0"
# And prove it by outcome, not just by the absent warning: BOTH members ran.
check_contains "W4: first member still ran" "$off_out" "panel-availability: dl1"
check_contains "W4: second member ran too (not skipped)" "$off_out" "panel-availability: dl2"
check "W4: no member was reported panel-deadline" "$(printf '%s
' "$off_out" | grep -c 'reason=panel-deadline')" "0"

# An invalid value must fall back to the default, never disable the cap silently.
inv_out="$(printf '%s' "$DIFF" | CRITIC_PANEL_TOTAL_TIMEOUT_SECS=abc CRITIC_FIRST_PASS="$CAPTURE_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check_contains "W5: invalid total timeout warns and uses the default" "$inv_out" "CRITIC_PANEL_TOTAL_TIMEOUT_SECS=abc invalid, using 900"

# W5b (public-PR CR): a LEADING ZERO passes the `^[0-9][0-9]*$` regex, and
# `[ "0900" -gt 0 ]` passes too (test's integer comparison is decimal) — so both
# guards in _panel_remaining are satisfied and the failure lands one line later
# in `$(( ))`, which reads a leading zero as OCTAL. Measured before the fix:
#   0900: value too great for base (error token is "0900")
# and _panel_remaining then returns rc 1 with empty output — its documented
# "no usable budget" path. So a fat-fingered 0900 SILENTLY DISABLED the cap and
# leaked a shell error on every call, while looking configured.
#
# The VALUE matters: only a leading zero containing an 8 or a 9 is invalid
# octal. `$(( 01 ))` is 1 and `$(( 07 ))` is 7 — both fine — while `$(( 08 ))`,
# `$(( 09 ))` and `$(( 0900 ))` all die. A first draft of this test used `01`
# and passed with the fix REMOVED, i.e. it asserted nothing; `08` is the
# shortest value that actually reproduces.
#
# Asserted on the OBSERVABLE consequence, not the internal value: the panel
# start is backdated so an 8-second budget is already spent, so with the cap
# genuinely active the panel must report a panel-deadline drop. If the octal bug
# came back, _panel_remaining would return "no usable budget" and no member
# would carry that reason.
_lz_backdated=$(( $(date +%s) - 5000 ))
lz_out="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/dl-critics.json" CRITIC_PANEL_TOTAL_TIMEOUT_SECS=08 CRITIC_PANEL_STARTED_AT="$_lz_backdated" CRITIC_FIRST_PASS="$SLOW_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check_contains "W5b: a leading-zero total timeout is honoured, not silently disabled" "$lz_out" "reason=panel-deadline"
if grepq "$lz_out" 'value too great for base'; then
    fails=$((fails+1)); echo "  FAIL: W5b: no octal arithmetic error leaked to stderr"
else
    echo "  ok: W5b: no octal arithmetic error leaked to stderr"
fi

# W6 (CR codex-1): the PARALLEL path must honour the deadline on the LAUNCH
# side too. The clamp alone only shortens a member — it does not stop it
# starting — so without this check CRITIC_PARALLEL=1 could still launch every
# member after the budget was spent. A 0-second budget is already spent before
# the first launch, which is the deterministic way to exercise it.
# Backdate the panel start so the budget is ALREADY spent at loop entry.
# Without the seam this is untestable: launches are near-instant so no real
# budget expires during the loop, and 0 means "disabled", not "already spent".
_backdated=$(( $(date +%s) - 5000 ))
par_out="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/dl-critics.json" CRITIC_PARALLEL=1 CRITIC_PANEL_TOTAL_TIMEOUT_SECS=1     CRITIC_PANEL_STARTED_AT="$_backdated"     CRITIC_FIRST_PASS="$SLOW_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check_contains "W6: parallel path announces the deadline" "$par_out" "TOTAL panel deadline"
check_contains "W6: parallel path reports the un-launched member unavailable" "$par_out" "reason=panel-deadline"
# Both members must be reported — an already-spent budget means NOTHING launches.
check "W6: both members reported, none launched" "$(printf '%s
' "$par_out" | grep -c 'reason=panel-deadline')" "2"
# Same seam, sequential path: proves the two paths agree rather than one
# silently drifting.
seq_out="$(printf '%s' "$DIFF" | CRITICS_JSON="$tmp/dl-critics.json" CRITIC_PANEL_TOTAL_TIMEOUT_SECS=1     CRITIC_PANEL_STARTED_AT="$_backdated"     CRITIC_FIRST_PASS="$SLOW_STUB" bash "$tmp/panelcopy/critic-panel.sh" 2>&1 >/dev/null)"
check "W6: sequential path agrees (both reported, none run)" "$(printf '%s
' "$seq_out" | grep -c 'reason=panel-deadline')" "2"

# --- HIMMEL-1291 (public-PR CR): the clamp RESERVES the `timeout -k` grace ----
#
# The runners spend nominal + CRITIC_KILL_GRACE_SECS on a member that ignores
# SIGTERM. Clamping to the BARE remainder therefore still let the panel finish
# up to ONE grace past the total deadline (one, not grace * n_members:
# _panel_remaining recomputes from wall clock, so an earlier member's overrun
# is absorbed into the next member's remaining). The clamp must hand out
# (remaining - grace) so nominal + grace fits inside.
#
# Observed through a fake `timeout` first on PATH: it is the only place the
# EFFECTIVE per-member value is visible from outside (the member itself never
# sees it). It logs the -k grace, the nominal seconds, and the budget REMAINING
# at the moment of launch, then execs the real command so the run proceeds
# normally.
#
# Logging `left` is what makes W7b setup-time independent (CR round: a fixed
# [45,55] band around the expected 55 only discriminated while setup stayed
# under 5s — slower setup would have slid the UNFIXED 60 into the band and
# false-passed the very regression this guards). The fake recomputes `left`
# from the SAME two env vars the panel used, so the assertion is on the
# RESERVED DELTA (left - secs) rather than on an absolute value that drifts
# with however long setup took.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/timeout" <<'FAKETO'
#!/usr/bin/env bash
# invoked as: timeout -k <grace> <secs> <cmd...>
_left=NA
if [ -n "${CRITIC_PANEL_STARTED_AT:-}" ] && [ "${CRITIC_PANEL_TOTAL_TIMEOUT_SECS:-0}" -gt 0 ] 2>/dev/null; then
    _left=$(( CRITIC_PANEL_TOTAL_TIMEOUT_SECS - ( $(date +%s) - CRITIC_PANEL_STARTED_AT ) ))
fi
printf 'k=%s secs=%s left=%s\n' "$2" "$3" "$_left" >> "$TO_LOG"
shift 3
exec "$@"
FAKETO
chmod +x "$tmp/bin/timeout"

# Pull one named field off the FIRST logged launch (fields are `name=value`,
# so a positional sed breaks the moment a field is added — as `left=` just was).
_to_field() {
    awk -v k="$2" 'NR==1{for(i=1;i<=NF;i++) if(index($i, k "=")==1){sub("^" k "=","",$i); print $i; exit}}' "$1"
}

# W7a — budget far from spent: the clamp is a no-op and the member gets its
# full nominal timeout. Pins the grace the runners actually pass, which is the
# value the clamp subtracts; a literal drifting from the constant fails here.
_to_noclamp="$tmp/to-noclamp.log"
: > "$_to_noclamp"
PATH="$tmp/bin:$PATH" TO_LOG="$_to_noclamp" bash -c 'printf "%s" "$1" | CRITICS_JSON="$2" CRITIC_TIMEOUT_SECS=240 CRITIC_PANEL_TOTAL_TIMEOUT_SECS=900 CRITIC_FIRST_PASS="$3" bash "$4" >/dev/null 2>&1' _ "$DIFF" "$tmp/dl-critics.json" "$CAPTURE_STUB" "$tmp/panelcopy/critic-panel.sh"
check "W7a: runner passes the named grace, not a drifting literal" "$(_to_field "$_to_noclamp" k)" "5"
check "W7a: an unspent budget leaves the nominal timeout untouched" "$(_to_field "$_to_noclamp" secs)" "240"

# W7b — the discriminator. ~60s left of a 900s budget, so the clamp binds
# (60 < the 240s nominal). Assert the RESERVED DELTA, not an absolute:
# post-fix the member gets left-grace, so left-secs == 5; pre-fix it got the
# bare remainder, so left-secs == 0. Setup time cancels out of the difference
# entirely, which is the point — the only slack needed is ±1 for the second
# boundary the panel and the fake can land either side of. That leaves 5 vs 0
# with a 3-wide gap, and no way for slow setup to blur them.
_to_clamped="$tmp/to-clamped.log"
: > "$_to_clamped"
_bd60=$(( $(date +%s) - 840 ))
PATH="$tmp/bin:$PATH" TO_LOG="$_to_clamped" bash -c 'printf "%s" "$1" | CRITICS_JSON="$2" CRITIC_TIMEOUT_SECS=240 CRITIC_PANEL_TOTAL_TIMEOUT_SECS=900 CRITIC_PANEL_STARTED_AT="$5" CRITIC_FIRST_PASS="$3" bash "$4" >/dev/null 2>&1' _ "$DIFF" "$tmp/dl-critics.json" "$CAPTURE_STUB" "$tmp/panelcopy/critic-panel.sh" "$_bd60"
_secs="$(_to_field "$_to_clamped" secs)"
_left="$(_to_field "$_to_clamped" left)"
_reserved=""
case "$_secs$_left" in
    ''|*[!0-9]*) ;;                       # a missing/non-numeric field leaves it unset -> FAIL below
    *) _reserved=$(( _left - _secs )) ;;
esac
# The clamp must have bound at all — if it did not, `left` was not ~60 and the
# scenario never exercised the reservation (a silent vacuous pass otherwise).
check "W7b: the clamp actually bound (nominal 240 was reduced)" \
    "$( [ -n "$_secs" ] && [ "$_secs" -lt 240 ] 2>/dev/null && echo bound || echo "unbound(secs=$_secs)" )" "bound"
if [ -n "$_reserved" ] && [ "$_reserved" -ge 4 ] && [ "$_reserved" -le 6 ]; then
    check "W7b: clamp reserves the grace (left=${_left} secs=${_secs}, reserved ${_reserved}s)" "reserved" "reserved"
else
    check "W7b: clamp reserves the grace (0 = the unfixed value; left=${_left} secs=${_secs})" \
        "reserved=${_reserved:-<unparsed>}" "4..6"
fi

# W7c — the floor holds. `timeout 0` means NO timeout in GNU coreutils and a
# negative value is an error, so subtracting the grace must never push the
# clamp to 0 or below however little budget is left.
_to_floor="$tmp/to-floor.log"
: > "$_to_floor"
_bd_tight=$(( $(date +%s) - 896 ))
PATH="$tmp/bin:$PATH" TO_LOG="$_to_floor" bash -c 'printf "%s" "$1" | CRITICS_JSON="$2" CRITIC_TIMEOUT_SECS=240 CRITIC_PANEL_TOTAL_TIMEOUT_SECS=900 CRITIC_PANEL_STARTED_AT="$5" CRITIC_FIRST_PASS="$3" bash "$4" >/dev/null 2>&1' _ "$DIFF" "$tmp/dl-critics.json" "$CAPTURE_STUB" "$tmp/panelcopy/critic-panel.sh" "$_bd_tight"
# Any launch at all must carry secs>=1. A run where the deadline check fired
# first logs nothing, which is also correct — hence "no bad line", not "some
# good line". Combined across all three scenarios so the invariant is total.
#
# Compared NUMERICALLY on the extracted field, not by matching the raw line
# (CR round): the earlier `secs=(0$|-)` regex anchored zero to end-of-line, so
# the moment `left=` was appended after it the zero half of the guard went
# INERT while still reading like it covered both. A field-keyed numeric test
# cannot rot that way when a field is added or reordered.
check "W7c: the clamp never emits a 0 or negative timeout" \
    "$(cat "$tmp"/to-*.log 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(index($i,"secs=")==1){v=$i; sub(/^secs=/,"",v); if(v+0 < 1) n++}} END{print n+0}')" "0"

# --- HIMMEL-1648: panel credential load_dotenv is pinned to script-root ---------
# resolution (load_dotenv --root "$(_load_dotenv_primary_for "$SCRIPT_DIR/../..")"),
# so a panel invoked from an UNRELATED git repo reads himmel's .env, not THAT
# repo's. The fixture copies the panel + load-dotenv.sh into a fake himmel root
# (so $SCRIPT_DIR/../.. resolves THERE) carrying GLM_API_KEY ONLY in its .env; the
# process cwd is a DIFFERENT git repo whose .env holds a DECOY value. A registry
# with a zai/glm row trips the load gate; the glm member (stubbed) must observe
# the himmel-root key, never the cwd decoy — pre-fix CWD-anchored resolution read
# the decoy. A live process value still wins (only-when-unset).
P1648_ROOT="$tmp/p1648-root"; mkdir -p "$P1648_ROOT/scripts/cr" "$P1648_ROOT/scripts/lib"
cp "$PANEL" "$P1648_ROOT/scripts/cr/critic-panel.sh"
cp "$HERE/../lib/load-dotenv.sh" "$P1648_ROOT/scripts/lib/load-dotenv.sh"
printf 'GLM_API_KEY=zk-himmel-root\n' > "$P1648_ROOT/.env"
P1648_CWX="$tmp/p1648-cwd"; mkdir -p "$P1648_CWX"; git init -q "$P1648_CWX"
git -C "$P1648_CWX" config user.name test
git -C "$P1648_CWX" config user.email t@e.invalid
printf 'x\n' > "$P1648_CWX/README"; git -C "$P1648_CWX" add README; git -C "$P1648_CWX" commit -q -m init
printf 'GLM_API_KEY=DECOY-cwd-value\n' > "$P1648_CWX/.env"
P1648_JSON="$tmp/p1648-glm.json"
printf '%s' '{"panel":[{"slug":"glm","model":"glm/glm-5.2","provider":"zai","tier":"free"}]}' > "$P1648_JSON"
P1648_KEY="$tmp/p1648-key"
P1648_STUB="$tmp/p1648-cfp.sh"
cat > "$P1648_STUB" <<EOS
#!/usr/bin/env bash
printf '%s' "\${GLM_API_KEY:-}" > "$P1648_KEY"
echo "# glm First-Pass Review"
echo ""
echo "## Critical Issues (0 found)"
echo ""
echo "## Important Issues (0 found)"
echo ""
echo "## Suggestions (0 found)"
EOS
chmod +x "$P1648_STUB"
# glm panel from an UNRELATED cwd repo: the himmel-root key wins over the cwd decoy.
: > "$P1648_KEY"
( cd "$P1648_CWX" && unset GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY \
    && printf '%s' "$DIFF" | CRITICS_JSON="$P1648_JSON" CRITIC_FIRST_PASS="$P1648_STUB" \
       bash "$P1648_ROOT/scripts/cr/critic-panel.sh" >/dev/null 2>&1 )
check "HIMMEL-1648: panel loads the himmel-root .env key (not the cwd repo's decoy)" "$(cat "$P1648_KEY" 2>/dev/null)" "zk-himmel-root"
# A live process value still wins (only-when-unset): the .env value must NOT overwrite it.
: > "$P1648_KEY"
( cd "$P1648_CWX" && export GLM_API_KEY=process-key \
    && printf '%s' "$DIFF" | CRITICS_JSON="$P1648_JSON" CRITIC_FIRST_PASS="$P1648_STUB" \
       bash "$P1648_ROOT/scripts/cr/critic-panel.sh" >/dev/null 2>&1 )
check "HIMMEL-1648: panel preserves the live process env key over .env" "$(cat "$P1648_KEY" 2>/dev/null)" "process-key"

# --- HIMMEL-1065 residual 1: codex critic credential (CLIPROXY_API_KEY) ---------
# resolves from the PRIMARY checkout's .env via the same script-root-pinned
# load_dotenv as the Z.ai keys, so a worktree run (no .env of its own) still
# authenticates the codex critic (which runs critic-first-pass.sh ->
# hermes/invoke.sh, whose openai-codex provider defers auth to the inherited env).
# Same fixture shape as HIMMEL-1648: a fake himmel root carries the key ONLY in
# its .env; the process cwd is a DIFFERENT git repo with a DECOY. The registry is
# the default codex+glm shape (the glm row's "zai"/"glm" trips the load gate,
# which reads the FULL registry before tier filtering); a stubbed member captures
# the inherited CLIPROXY_API_KEY. A live process value still wins (only-when-unset).
P1065_ROOT="$tmp/p1065-root"; mkdir -p "$P1065_ROOT/scripts/cr" "$P1065_ROOT/scripts/lib"
cp "$PANEL" "$P1065_ROOT/scripts/cr/critic-panel.sh"
cp "$HERE/../lib/load-dotenv.sh" "$P1065_ROOT/scripts/lib/load-dotenv.sh"
printf 'CLIPROXY_API_KEY=cpx-himmel-root\n' > "$P1065_ROOT/.env"
P1065_CWX="$tmp/p1065-cwd"; mkdir -p "$P1065_CWX"; git init -q "$P1065_CWX"
git -C "$P1065_CWX" config user.name test
git -C "$P1065_CWX" config user.email t@e.invalid
printf 'x\n' > "$P1065_CWX/README"; git -C "$P1065_CWX" add README; git -C "$P1065_CWX" commit -q -m init
printf 'CLIPROXY_API_KEY=DECOY-cwd-value\n' > "$P1065_CWX/.env"
P1065_JSON="$tmp/p1065-reg.json"
printf '%s' '{"panel":[{"slug":"codex","model":"gpt-5.5","provider":"openai-codex","tier":"paid"},{"slug":"glm","model":"glm-5.2","provider":"zai","tier":"paid"}]}' > "$P1065_JSON"
P1065_KEY="$tmp/p1065-key"
P1065_STUB="$tmp/p1065-cfp.sh"
cat > "$P1065_STUB" <<EOS
#!/usr/bin/env bash
printf '%s' "\${CLIPROXY_API_KEY:-}" > "$P1065_KEY"
echo "# codex First-Pass Review"
echo ""
echo "## Critical Issues (0 found)"
echo ""
echo "## Important Issues (0 found)"
echo ""
echo "## Suggestions (0 found)"
EOS
chmod +x "$P1065_STUB"
# Worktree-equivalent: run from the UNRELATED cwd repo with the key absent from
# the process env. The codex critic must inherit the himmel-root key, never the
# cwd decoy (pre-fix the key was never loaded at all -> codex died rc=2).
: > "$P1065_KEY"
( cd "$P1065_CWX" && unset CLIPROXY_API_KEY GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY \
    && printf '%s' "$DIFF" | CRITICS_JSON="$P1065_JSON" CRITIC_FIRST_PASS="$P1065_STUB" \
       bash "$P1065_ROOT/scripts/cr/critic-panel.sh" >/dev/null 2>&1 )
check "HIMMEL-1065: codex credential resolves from the primary .env (not the cwd repo's decoy)" "$(cat "$P1065_KEY" 2>/dev/null)" "cpx-himmel-root"
# A live process value still wins (load_dotenv only-when-unset).
: > "$P1065_KEY"
( cd "$P1065_CWX" && export CLIPROXY_API_KEY=process-key \
    && printf '%s' "$DIFF" | CRITICS_JSON="$P1065_JSON" CRITIC_FIRST_PASS="$P1065_STUB" \
       bash "$P1065_ROOT/scripts/cr/critic-panel.sh" >/dev/null 2>&1 )
check "HIMMEL-1065: live process CLIPROXY_API_KEY wins over the .env value" "$(cat "$P1065_KEY" 2>/dev/null)" "process-key"
# ...and on a codex-ONLY registry. The fixture above carries a glm row, which
# trips the Z.ai load gate — so it CANNOT distinguish "the codex key is loaded
# because a codex critic is present" from "because a Z.ai critic happens to be
# present too". A codex-only registry is a supported shape (CRITICS_JSON, or a
# local overlay that drops the GLM row); folding the codex key into the Z.ai gate
# left exactly that shape unauthenticated -> codex rc=2 -> the fail-open 0/0/0
# this ticket closes. This fixture removes the mask: no zai/glm row anywhere.
P1065_CODEX_ONLY="$tmp/p1065-codex-only.json"
printf '%s' '{"panel":[{"slug":"codex","model":"gpt-5.5","provider":"openai-codex","tier":"paid"}]}' > "$P1065_CODEX_ONLY"
: > "$P1065_KEY"
( cd "$P1065_CWX" && unset CLIPROXY_API_KEY GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY \
    && printf '%s' "$DIFF" | CR_PROFILE=paid CRITICS_JSON="$P1065_CODEX_ONLY" CRITIC_FIRST_PASS="$P1065_STUB" \
       bash "$P1065_ROOT/scripts/cr/critic-panel.sh" >/dev/null 2>&1 )
check "HIMMEL-1065: codex-ONLY registry still loads the codex credential (no zai/glm row to trip the gate)" "$(cat "$P1065_KEY" 2>/dev/null)" "cpx-himmel-root"
# Converse: a registry with NO codex critic must not need the codex key to load
# for the Z.ai keys to resolve — the two probes are independent, not coupled.
P1065_GLM_ONLY="$tmp/p1065-glm-only.json"
printf '%s' '{"panel":[{"slug":"glm","model":"glm-5.2","provider":"zai","tier":"paid"}]}' > "$P1065_GLM_ONLY"
printf 'GLM_API_KEY=glm-himmel-root\n' >> "$P1065_ROOT/.env"
P1065_GKEY="$tmp/p1065-glm-key"
P1065_GSTUB="$tmp/p1065-glm-stub.sh"
cat > "$P1065_GSTUB" <<EOS
#!/usr/bin/env bash
printf '%s' "\${GLM_API_KEY:-}" > "$P1065_GKEY"
echo "# glm First-Pass Review"
echo ""
echo "## Critical Issues (0 found)"
echo ""
echo "## Important Issues (0 found)"
echo ""
echo "## Suggestions (0 found)"
EOS
chmod +x "$P1065_GSTUB"
: > "$P1065_GKEY"
( cd "$P1065_CWX" && unset CLIPROXY_API_KEY GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY \
    && printf '%s' "$DIFF" | CR_PROFILE=paid CRITICS_JSON="$P1065_GLM_ONLY" CRITIC_FIRST_PASS="$P1065_GSTUB" \
       bash "$P1065_ROOT/scripts/cr/critic-panel.sh" >/dev/null 2>&1 )
check "HIMMEL-1065: glm-ONLY registry still loads the Z.ai credential (codex probe does not gate it)" "$(cat "$P1065_GKEY" 2>/dev/null)" "glm-himmel-root"

# --- HIMMEL-1065 residual 2: zero-responder fail-closed output ------------------
# When EVERY critic is unavailable, the panel must emit NO "(N found)" findings
# section (byte-identical to a clean review) and instead print an unmistakable
# unavailability block naming the unreachable critics. Exit stays non-zero. A
# stub that always fails makes the single paid codex member unavailable (0/1).
P1065_ZJSON="$tmp/p1065-zero-reg.json"
printf '%s' '{"panel":[{"slug":"codex","model":"gpt-5.5","provider":"openai-codex","tier":"paid"}]}' > "$P1065_ZJSON"
P1065_FAIL_STUB="$tmp/p1065-fail.sh"
cat > "$P1065_FAIL_STUB" <<'EOS'
#!/usr/bin/env bash
echo "stub: critic unreachable" >&2
exit 1
EOS
chmod +x "$P1065_FAIL_STUB"
P1065_ZRC=0
P1065_ZOUT="$(printf '%s' "$DIFF" | CR_PROFILE=paid CRITICS_JSON="$P1065_ZJSON" CRITIC_FIRST_PASS="$P1065_FAIL_STUB" bash "$PANEL" 2>/dev/null)" || P1065_ZRC=$?
check "HIMMEL-1065: zero responders -> non-zero exit (regression)" "$([ "$P1065_ZRC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
check "HIMMEL-1065: zero responders -> NO '## Critical Issues' section" "$(printf '%s\n' "$P1065_ZOUT" | grep -cF '## Critical Issues')" "0"
check "HIMMEL-1065: zero responders -> NO '## Important Issues' section" "$(printf '%s\n' "$P1065_ZOUT" | grep -cF '## Important Issues')" "0"
check "HIMMEL-1065: zero responders -> NO '## Suggestions' section" "$(printf '%s\n' "$P1065_ZOUT" | grep -cF '## Suggestions')" "0"
check_contains "HIMMEL-1065: zero responders -> unmistakable REVIEW NOT PERFORMED block" "$P1065_ZOUT" "REVIEW NOT PERFORMED"
check_contains "HIMMEL-1065: zero responders -> names the unavailable critic" "$P1065_ZOUT" "- codex: unavailable"
check_contains "HIMMEL-1065: zero responders -> header reports 0/1" "$P1065_ZOUT" "(0/1 critics responded)"

# ===========================================================================
# HIMMEL-2052: the panel's finding rows reach the ledger through ONE
# `ledger-append.sh finding --batch-file` call (a node-built JSONL spool
# conversion) instead of one invocation per row. The consumer side is covered
# by test-ledger-append.sh; this is the PRODUCER side — if the \034 field
# split, the JSON shape, or the --batch-file call regresses, panel findings
# vanish from the ledger silently, and a vanished finding reads as no finding
# (a false-clean gate). Cite lines that are IN the diff so the citation guard
# keeps them.
# ===========================================================================
# TWO members on purpose. The batch conversion originally took its spool paths
# through an env var, which Git-Bash rewrites when it spawns a native node.exe:
# correct for ONE path, mangled for a newline-separated LIST. A single-member
# panel therefore PASSED while every real multi-critic run exited 5 with an
# empty ledger, so a one-member fixture here would re-open exactly that blind
# spot. Keep >=2.
P2052_JSON="$tmp/p2052-batch.json"
printf '%s' '{"panel":[{"slug":"batchy","model":"fake/reviewer","provider":"test","tier":"free"},{"slug":"batchy2","model":"fake/reviewer2","provider":"test","tier":"free"}]}' > "$P2052_JSON"
P2052_STUB_PY="$tmp/p2052.py"
cat > "$P2052_STUB_PY" <<'PYEOF'
print("## Critical Issues (1 found)")
print("- [CRITIC-1]: missing null guard [foo.sh:2]")
print("## Important Issues (1 found)")
print("- [CRITIC-2]: unbounded retry [foo.sh:3]")
print("## Suggestions (0 found)")
PYEOF
P2052_PY="$tmp/p2052-py.sh"
cat > "$P2052_PY" <<PYEOF
#!/usr/bin/env bash
exec python3 "$P2052_STUB_PY"
PYEOF
chmod +x "$P2052_PY"
P2052_LEDGER="$tmp/p2052-ledger.jsonl"; : > "$P2052_LEDGER"
printf '%s' "$DIFF" | HERMES_PY="$P2052_PY" CR_LEDGER="$P2052_LEDGER" \
    CRITIC_LEDGER_APPEND="$HERE/ledger-append.sh" CRITICS_JSON="$P2052_JSON" \
    CRITIC_FIRST_PASS="$HERE/critic-first-pass.sh" bash "$PANEL" >/dev/null 2>&1 || true

check "HIMMEL-2052: multi-critic batch path writes EVERY finding row to the ledger" \
    "$(grep -c '"kind":"finding"' "$P2052_LEDGER" 2>/dev/null || echo 0)" "4"
check "HIMMEL-2052: batch rows keep per-finding severity (crit + imp, not one blanket value)" \
    "$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.kind==="finding");console.log(rs.map(r=>r.severity).sort().join(","))' "$P2052_LEDGER" 2>/dev/null)" \
    "crit,crit,imp,imp"
check "HIMMEL-2052: batch rows carry the citation file+line through the \\034 split" \
    "$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.kind==="finding"&&r.severity==="crit");console.log(rs[0]&&(rs[0].file+":"+rs[0].line))' "$P2052_LEDGER" 2>/dev/null)" \
    "foo.sh:2"
check "HIMMEL-2052: EVERY critic's spool reaches the ledger, not just the first" \
    "$(node -e 'const fs=require("fs");const rs=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse).filter(r=>r.kind==="finding");console.log([...new Set(rs.map(r=>r.model))].sort().join(","))' "$P2052_LEDGER" 2>/dev/null)" \
    "batchy,batchy2"

if [ "$fails" -eq 0 ]; then
    if [ "$_skips" -gt 0 ]; then
        echo "ALL PASS ($_skips skipped)"
    else
        echo "ALL PASS"
    fi
else
    echo "$fails FAILED"
    exit 1
fi
