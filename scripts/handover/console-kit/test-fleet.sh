#!/usr/bin/env bash
# test-fleet.sh — HIMMEL-3404. Hermetic tests for fleet.mjs, the local fleet status
# UI (`--serve` page + `--json` / `--out` snapshot). Every external source is a
# fixture or a stub: the console doc, leg docs and launch logs are files under a
# temp handover root; /proc is a fixture tree (FLEET_PROC); queue-lock.sh,
# bank-preflight.sh, gh and `claude agents --json` are stubs (FLEET_QUEUE_LOCK /
# FLEET_BANK / FLEET_GH / FLEET_AGENTS). The
# suite reads no live queue, process table or GitHub state. Leg identity is the REAL
# scripts/lib/leg-identity.sh.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only (fleet.mjs
# reads /proc and the konsole/launch logs); this suite exercises a kit script.
# shellcheck disable=SC2016  # the fixture bullets carry literal backticks, not expansions
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/fleet.mjs"
if ! command -v node >/dev/null 2>&1; then
    printf 'SKIP - test-fleet.sh (node not installed)\n'
    exit 0
fi
W="$(mktemp -d "${TMPDIR:-/tmp}/fleet-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }

ROOT="$W/root"
B="$ROOT/u/repo"
LOGS="$W/logs"
mkdir -p "$B" "$LOGS" "$W/bin" "$W/proc"

# jq-free JSON probe: q '<js expr over s>' < snapshot.json
cat > "$W/q.mjs" <<'JS'
import { readFileSync } from 'node:fs';
const s = JSON.parse(readFileSync(0, 'utf8'));
const L = (l) => s.legs.find((x) => x.label === l);
const r = eval(process.argv[2]);
process.stdout.write(typeof r === 'string' ? r : JSON.stringify(r));
JS
q() { node "$W/q.mjs" "$1"; }

# ------------------------------------------------------------------ fixtures
# Leg docs. Each carries a nonce and a lock token in its own text: neither may
# ever reach an output.
mkleg() {  # mkleg <stem> <model> <results-bullets...>
    local stem="$1" model="$2"; shift 2
    {
        printf '# %s — leg (%s, native)\n\n> Your RETASK token is `%s`.\n\n## Results (newest at the bottom)\n\n' "$stem" "$model" "Z-${stem%%-2026*}-abcdef12"
        for b in "$@"; do printf '%s\n' "$b"; done
    } > "$B/$stem-RESUME.md"
}
mkleg HIMMEL-9001-N1-alpha-2026-09-22 claude-opus-5 \
    '- 10:00 LIVE — started, release-token `cachyos-x8664-pid7001`' \
    '- 10:30 LIVE — building, nonce `Z-N1-a1a1a1a1` is secret'
mkleg HIMMEL-9002-N2-beta-2026-09-22 claude-sonnet-5 \
    '- 10:10 LIVE — headless leg working'
mkleg HIMMEL-9003-N3-gamma-2026-09-22 claude-opus-5 \
    '- 10:20 LIVE — working on it'
mkleg HIMMEL-9004-N4-delta-2026-09-22 claude-opus-5 \
    '- 10:21 LIVE — working' \
    '- 10:40 BLOCKED — classifier denied `git push`, need a ruling'
mkleg HIMMEL-9005-N5-eps-2026-09-22 claude-opus-5 \
    '- 10:22 FINDING — <script>alert(1)</script> and <img src=x onerror=alert(2)> in a bullet'
mkleg HIMMEL-9006-N6-zeta-2026-09-22 claude-opus-5 \
    '- 10:23 LIVE — PR 2001 open, watching CI' \
    '- 10:50 READY 2001 0123456789abcdef0123456789abcdef01234567 GREEN'
mkleg HIMMEL-9007-N7-eta-2026-09-22 claude-opus-5 \
    '- 10:24 LIVE — working' \
    '- 11:00 WRAPPED — merged, lock released'
mkleg HIMMEL-9008-N8-theta-2026-09-22 claude-opus-5 \
    '- 10:25 LIVE — lock was lost'
# N9 is not in the console's Live state, but holds a lock: it must still get a row.
mkleg HIMMEL-9009-N9-iota-2026-09-22 claude-opus-5 \
    '- 10:26 LIVE — unlisted leg'
# N10 is a background-mode leg the daemon runs: its process comm is the version string, its
# Live-state pid is the (dead) launcher wrapper, and no launch log exists. Only the
# `claude agents --json` row identifies it.
mkleg HIMMEL-9010-N10-kappa-2026-09-22 claude-sonnet-5 \
    '- 10:27 LIVE — background leg via the daemon'  # t13b-ok: literal fixture text for a mocked leg row, not real automation
# N11 is unlisted (not in Live state) and held only by the sweep, with no launch log
# and a lock session that carries no pid: the ONLY pid source is a FINISHED bg agents
# row whose pid (1011) happens to alias a live /proc entry — a stale/reused pid must
# not resurrect it.
mkleg HIMMEL-9011-N11-mu-2026-09-22 claude-sonnet-5 \
    '- 10:28 LIVE — unlisted, bg-finished'  # t13b-ok: literal fixture text for a mocked leg row, not real automation
# N13 is unlisted, held only by the sweep, with a launch log whose pid= line lands
# past the first 8192 bytes.
mkleg HIMMEL-9013-N13-nu-2026-09-22 claude-sonnet-5 \
    '- 10:29 LIVE — unlisted, pid past 8192 bytes'  # t13b-ok: literal fixture text for a mocked leg row, not real automation

cat > "$B/HIMMEL-nextleg-2026-09-22Z-console.md" <<'DOC'
# console

## Live state

legs: `N1:X-N1-a1a1a1a1:cachyos-x8664-pid7001:1001`
  `N2:X-N2-b2b2b2b2:cachyos-x8664-pid7002:1002`
  `N3:X-N3-c3c3c3c3:cachyos-x8664-pid7003:1003`
  `N4:X-N4-d4d4d4d4:cachyos-x8664-pid7004:1004`
  `N5:X-N5-e5e5e5e5:cachyos-x8664-pid7005:1005`
  `N6:X-N6-f6f6f6f6:cachyos-x8664-pid7006:1006`
  `N7:X-N7-a7a7a7a7:cachyos-x8664-pid7007:1007`
  `N8:X-N8-b8b8b8b8:cachyos-x8664-pid7008:1008`
  `N10:X-N10-c1c1c1c1:cachyos-x8664-pid7010:1099`
queue: none

## Results (newest at the bottom)
DOC

# /proc fixture: 1001 headed (konsole), 1002 headless (a bg-mode claude), 1004..1006,
# 1007 (wrapped but alive), 1008 alive. 1003 is absent (dead).
mkproc() {  # mkproc <pid> <startticks> <argv...>
    local pid="$1" start="$2"; shift 2
    mkdir -p "$W/proc/$pid"
    printf '%s\0' "$@" > "$W/proc/$pid/cmdline"
    # 22 fields; comm may hold spaces and parens.
    printf '%s (my (proc)) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "$start" > "$W/proc/$pid/stat"
}
printf '5000.00 4000.00\n' > "$W/proc/uptime"
mkproc 1001 100000 konsole --separate -p tabtitle=HIMMEL-9001-N1-alpha -e env leg-claude --model 'claude-opus-5[1m]'
# headless-claude-ok: fixture /proc cmdline text only; this suite launches nothing
mkproc 1002 480000 claude --bg -n HIMMEL-9002-N2-beta --model claude-sonnet-5
mkproc 1004 490000 konsole -e claude
mkproc 1005 490000 konsole -e claude
mkproc 1006 490000 konsole -e claude
mkproc 1007 490000 konsole -e claude
mkproc 1008 490000 konsole -e claude
mkproc 7009 490000 claude -n HIMMEL-9009-N9-iota
mkproc 1010 300000 2.1.278
mkproc 1011 490000 konsole -e claude
mkproc 1013 490000 konsole -e claude

# Launch logs: a headless one (headless=1, pid, session log) and a headed one.
printf '%s\n' \
    '2026-09-22_10:10:00 headless=1 pid=1002 name=HIMMEL-9002-N2-beta model=claude-sonnet-5' \
    "2026-09-22_10:10:01 session-log=$LOGS/N2.session.log" > "$LOGS/HIMMEL-9002-N2-beta.launch.log"
printf '%s\n' \
    'earlier line' \
    'tool result: wrote file (token Z-N2-deadbeef leaked here) ok <b>bold</b>' > "$LOGS/N2.session.log"
printf '%s\n' '2026-09-22_10:00:00 konsole launched pid=1001 for HIMMEL-9001-N1-alpha' > "$LOGS/HIMMEL-9001-N1-alpha.launch.log"
# N13's launch log: headless=1 up front, but its pid= line is appended after >8192
# bytes of padding — only a tail read (not just the head) can see it.
{
    printf 'headless=1 name=HIMMEL-9013-N13-nu model=claude-sonnet-5\n'
    head -c 9000 /dev/zero | tr '\0' '#'
    printf '\n'
    printf 'pid=1013\n'
} > "$LOGS/HIMMEL-9013-N13-nu.launch.log"

# queue-lock sweep stub: the real one's line shape. N3 (held, process dead), N8's lock
# is gone (FREE while alive), N7 released (WRAPPED). N9 is held but unlisted.
cat > "$W/bin/queue-lock" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "status --sweep "*)
        p=u__repo__HIMMEL
        echo "sweep: read only $3"
        echo "slug=${p}-9001-N1-alpha-2026-09-22-RESUME session=cachyos-x8664-pid7001 host=h age=600s status=OK"
        echo "slug=${p}-9002-N2-beta-2026-09-22-RESUME session=cachyos-x8664-pid7002 host=h age=30s status=OK"
        echo "slug=${p}-9003-N3-gamma-2026-09-22-RESUME session=cachyos-x8664-pid7003 host=h age=90s status=OK"
        echo "slug=${p}-9004-N4-delta-2026-09-22-RESUME session=cachyos-x8664-pid7004 host=h age=4000s status=IDLE-HELD?"
        echo "slug=${p}-9005-N5-eps-2026-09-22-RESUME session=cachyos-x8664-pid7005 host=h age=50s status=OK"
        echo "slug=${p}-9006-N6-zeta-2026-09-22-RESUME session=cachyos-x8664-pid7006 host=h age=20s status=OK"
        echo "slug=${p}-9009-N9-iota-2026-09-22-RESUME session=cachyos-x8664-pid7009 host=h age=15s status=OK"
        echo "slug=${p}-9010-N10-kappa-2026-09-22-RESUME session=cachyos-x8664-pid7010 host=h age=12s status=OK"
        echo "slug=${p}-9011-N11-mu-2026-09-22-RESUME session=host-nopid host=h age=15s status=OK"
        echo "slug=${p}-9013-N13-nu-2026-09-22-RESUME session=host-nopid host=h age=15s status=OK"
        echo "slug=${p}-nextleg-2026-09-22Z-console session=cachyos-x8664-pid7100 host=h age=5s status=OK"
        ;;
    *) exit 2 ;;
esac
STUB
cat > "$W/bin/bank" <<'STUB'
#!/usr/bin/env bash
echo "bank-preflight: FLEET native=10 claudex=0 reserved=0 total=10/15" >&2
echo "bank-preflight: leg=unknown five_hour=28.0 seven_day=61.0 extra_usage=n/a age=7s codex=?"
echo PROCEED
STUB
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "pr list "*) cat "$GH_OPEN" ;;
    "pr view "*) echo '{"state":"OPEN"}' ;;
    *) exit 1 ;;
esac
STUB
cat > "$W/bin/agents" <<'STUB'
#!/usr/bin/env bash
cat "$AG_JSON"
STUB
cat > "$W/bin/agents-bad" <<'STUB'
#!/usr/bin/env bash
echo "not json at all"
STUB
chmod +x "$W/bin/queue-lock" "$W/bin/bank" "$W/bin/gh" "$W/bin/agents" "$W/bin/agents-bad"
# `claude agents --json` rows (the real shape): interactive rows carry pid + status,
# background rows carry state. N10's row is the only thing that names its pid; a
# finished background row for N7 must not resurrect it as headless.
cat > "$W/agents.json" <<JSON
[{"pid":9991,"cwd":"/x","kind":"interactive","startedAt":1,"sessionId":"s1","name":"HIMMEL-9001-N1-alpha","status":"busy"},
 {"id":"abc","cwd":"/x","kind":"background","startedAt":1790000000000,"sessionId":"s2","name":"HIMMEL-9010-N10-kappa","state":"running","pid":1010},
 {"id":"def","cwd":"/x","kind":"background","startedAt":1,"sessionId":"s3","name":"HIMMEL-9007-N7-eta","state":"done","pid":9999},
 {"id":"ghi","cwd":"/x","kind":"background","startedAt":1,"sessionId":"s4","name":"HIMMEL-9011-N11-mu","state":"done","pid":1011}]
JSON
cat > "$W/open.json" <<'JSON'
[{"number":2001,"title":"feat(x): [HIMMEL-9006] zeta","headRefName":"feat/himmel-9006","isDraft":false,
  "statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"},{"state":"SUCCESS"}]},
 {"number":2002,"title":"feat(y): [HIMMEL-9001] alpha","headRefName":"feat/himmel-9001","isDraft":false,
  "statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED"}]},
 {"number":2003,"title":"feat(z): [HIMMEL-9003] gamma","headRefName":"feat/himmel-9003","isDraft":false,
  "statusCheckRollup":[{"conclusion":"ACTION_REQUIRED","status":"COMPLETED"}]}]
JSON

# bash seam files run by `bash <path>`, gh by exec.
run() {  # run <args...> — the SUT under the full stub environment
    FLEET_QUEUE_LOCK="${FLEET_QUEUE_LOCK:-$W/bin/queue-lock}" FLEET_BANK="${FLEET_BANK:-$W/bin/bank}" \
        FLEET_GH="${FLEET_GH:-$W/bin/gh}" FLEET_AGENTS="${FLEET_AGENTS:-$W/bin/agents}" AG_JSON="${AG_JSON:-$W/agents.json}" \
        FLEET_PROC="$W/proc" GH_OPEN="$W/open.json" HANDOVER_DIR="$ROOT" \
        node "$SUT" "$@"
}
DOC="$B/HIMMEL-nextleg-2026-09-22Z-console.md"
COMMON=(--doc "$DOC" --logs "$LOGS" --handover-root "$ROOT")

# ------------------------------------------------------------------ RED marker
if [ ! -f "$SUT" ]; then
    fail "fleet.mjs exists"
    printf '%s\n' "test-fleet.sh: $fails failed"
    exit 1
fi

# ------------------------------------------------------------------ usage
run --bogus >/dev/null 2>&1; eq "unknown flag exits 2" "$?" "2"
run --json >/dev/null 2>&1; eq "no --doc exits 2" "$?" "2"
run --serve --out "$W/x.html" "${COMMON[@]}" >/dev/null 2>&1; eq "--serve with --out exits 2" "$?" "2"

# ------------------------------------------------------------------ snapshot
J="$(run --json "${COMMON[@]}" 2>"$W/err")"
eq "snapshot is valid JSON with 12 leg rows (9 listed + 3 unlisted held)" "$(printf '%s' "$J" | q 's.legs.length')" "12"
eq "fleet is 10/15" "$(printf '%s' "$J" | q 's.fleet.live+"/"+s.fleet.cap')" "10/15"
eq "bank 5h/7d" "$(printf '%s' "$J" | q 's.bank.fiveHour+"/"+s.bank.sevenDay')" "28.0/61.0"
eq "headed leg: mode" "$(printf '%s' "$J" | q 'L("N1").mode')" "headed"
eq "headed leg: pid" "$(printf '%s' "$J" | q 'L("N1").pid')" "1001"
eq "headed leg: model from cmdline" "$(printf '%s' "$J" | q 'L("N1").model')" "claude-opus-5[1m]"
eq "headed leg: alive" "$(printf '%s' "$J" | q 'L("N1").alive')" "true"
eq "headed leg: uptime from /proc (5000s up - start 1000s)" "$(printf '%s' "$J" | q 'L("N1").uptimeSec')" "4000"
eq "headed leg: ticket" "$(printf '%s' "$J" | q 'L("N1").ticket')" "HIMMEL-9001"
eq "headed leg: lock FRESH" "$(printf '%s' "$J" | q 'L("N1").lock.state')" "FRESH"
eq "headed leg: status token is the newest marker bullet" "$(printf '%s' "$J" | q 'L("N1").status.token')" "LIVE"
eq "headed leg: PR joined on the ticket in the open PR title" "$(printf '%s' "$J" | q 'L("N1").pr.number+":"+L("N1").pr.ci')" "2002:failing"
eq "headless leg: mode from the launch log" "$(printf '%s' "$J" | q 'L("N2").mode')" "headless"
eq "headless leg: alive" "$(printf '%s' "$J" | q 'L("N2").alive')" "true"
eq "headless leg: model" "$(printf '%s' "$J" | q 'L("N2").model')" "claude-sonnet-5"
contains "headless leg: last session-log line shown" "$(printf '%s' "$J" | q 'L("N2").lastLine')" "wrote file"
eq "an ACTION_REQUIRED check is not green" "$(printf '%s' "$J" | q 'L("N3").pr.number+":"+L("N3").pr.ci')" "2003:failing"
eq "READY leg: PR from the READY bullet, CI green" "$(printf '%s' "$J" | q 'L("N6").pr.number+":"+L("N6").pr.ci')" "2001:green"
eq "WRAPPED leg: lock state WRAPPED" "$(printf '%s' "$J" | q 'L("N7").lock.state')" "WRAPPED"
eq "lost lock: FREE" "$(printf '%s' "$J" | q 'L("N8").lock.state')" "FREE"
eq "unlisted held leg gets a row" "$(printf '%s' "$J" | q 'L("N9").listed')" "false"
eq "idle-held lock still reads FRESH, flagged idle" "$(printf '%s' "$J" | q 'L("N4").lock.state+":"+L("N4").lock.idle')" "FRESH:true"
eq "agents source: bg row makes N10 headless (no launch log, comm is a version string)" "$(printf '%s' "$J" | q 'L("N10").mode')" "headless"
eq "agents source: the bg row's pid beats the dead launcher pid in Live state" "$(printf '%s' "$J" | q 'L("N10").pid+":"+L("N10").alive')" "1010:true"
eq "agents source: N10 uptime from /proc (5000s up - start 3000s)" "$(printf '%s' "$J" | q 'L("N10").uptimeSec')" "2000"
eq "agents source: the bg state is carried" "$(printf '%s' "$J" | q 'L("N10").agent.kind+":"+L("N10").agent.state')" "background:running"
eq "agents source: an interactive row does not turn a konsole leg headless" "$(printf '%s' "$J" | q 'L("N1").mode+":"+L("N1").pid')" "headed:1001"
eq "agents source: a finished bg row does not overrule the launcher pid" "$(printf '%s' "$J" | q 'L("N7").pid')" "1007"
eq "agents source: a finished bg row leaves a konsole leg headed" "$(printf '%s' "$J" | q 'L("N7").mode')" "headed"
printf '%s\n' '[{"id":"g","kind":"background","startedAt":1790000000000,"name":"HIMMEL-9003-N3-gamma","state":"running"}]' > "$W/agents-nopid.json"
J5="$(AG_JSON="$W/agents-nopid.json" run --json "${COMMON[@]}" 2>/dev/null)"
eq "agents source: a running bg row with no pid is alive by its state (no proc-dead)" "$(printf '%s' "$J5" | q 'L("N3").mode+":"+L("N3").alive+":"+L("N3").attention.length')" "headless:true:0"
eq "agents source: healthy headless N10 needs nothing" "$(printf '%s' "$J" | q 'L("N10").attention.length')" "0"
eq "agents source available: no agents warning" "$(printf '%s' "$J" | q 's.warnings.some(w=>/agents/.test(w))')" "false"
eq "HIMMEL-3412(a): a finished bg row's stale/reused pid does not resurrect the leg" "$(printf '%s' "$J" | q 'L("N11").alive')" "false"
eq "HIMMEL-3412(c): a launch-log pid= past byte 8192 is still read from the tail" "$(printf '%s' "$J" | q 'L("N13").pid')" "1013"
eq "HIMMEL-3412(c): that tail-read pid makes the leg alive" "$(printf '%s' "$J" | q 'L("N13").alive')" "true"

# ------------------------------------------------------------------ attention
att() { printf '%s' "$J" | q "L(\"$1\").attention.map(a=>a.code).join(',')"; }
eq "N3: process dead while the lock is held" "$(att N3)" "proc-dead"
eq "N4: BLOCKED" "$(att N4)" "blocked"
eq "N5: FINDING" "$(att N5)" "finding"
eq "N6: READY awaiting GO" "$(att N6)" "ready"
eq "N7: WRAPPED but process alive" "$(att N7)" "wrapped-alive"
eq "N8: lock FREE while process alive" "$(att N8)" "lock-lost"
eq "N2 (healthy headless) needs nothing" "$(att N2)" ""
eq "attention rows sort first" "$(printf '%s' "$J" | q 's.legs[0].attention.length>0')" "true"

# ------------------------------------------------------------------ safety
H="$W/fleet.html"
run --out "$H" "${COMMON[@]}" >/dev/null 2>&1; eq "--out writes the file" "$?" "0"
HTML="$(cat "$H")"
for tok in 'Z-N1-a1a1a1a1' 'X-N1-a1a1a1a1' 'X-N2-b2b2b2b2' 'Z-N2-deadbeef' 'cachyos-x8664-pid7001' 'cachyos-x8664-pid7002' 'pid7004'; do
    lacks "json redacts $tok" "$J" "$tok"
    lacks "html redacts $tok" "$HTML" "$tok"
done
lacks "html holds no raw <script>alert" "$HTML" '<script>alert(1)'
lacks "html holds no raw <img" "$HTML" '<img src=x'
contains "html embeds the snapshot with < escaped" "$HTML" '<script'
contains "html is a self-contained page" "$HTML" '<!doctype html>'
lacks "html loads nothing external" "$HTML" 'src="http'
lacks "html loads no external stylesheet" "$HTML" 'rel="stylesheet"'
eq "the snapshot page does not poll" "$(printf '%s' "$HTML" | grep -c 'const LIVE = true')" "0"

# ------------------------------------------------------------------ degraded sources
J2="$(FLEET_BANK=/nonexistent FLEET_GH=/nonexistent run --json "${COMMON[@]}" 2>/dev/null)"
eq "dead bank + gh: still renders every row" "$(printf '%s' "$J2" | q 's.legs.length')" "12"
eq "dead bank: fleet is null, not a made-up 0" "$(printf '%s' "$J2" | q 's.fleet===null')" "true"
eq "dead gh: warning recorded" "$(printf '%s' "$J2" | q 's.warnings.some(w=>/gh/.test(w))')" "true"
J3="$(run --json --doc "$DOC" --logs "$W/no-such-logs" --handover-root "$ROOT" 2>/dev/null)"
eq "absent launch-log dir tolerated" "$(printf '%s' "$J3" | q 's.legs.length')" "12"
for AGCMD in /nonexistent "$W/bin/agents-bad"; do
    J4="$(FLEET_AGENTS="$AGCMD" run --json "${COMMON[@]}" 2>/dev/null)"
    eq "agents source ($(basename "$AGCMD")): every row still renders" "$(printf '%s' "$J4" | q 's.legs.length')" "12"
    eq "agents source ($(basename "$AGCMD")): 'agents: unavailable' warning" "$(printf '%s' "$J4" | q 's.warnings.some(w=>/^agents: unavailable/.test(w))')" "true"
    eq "agents source ($(basename "$AGCMD")): the /proc source still finds headless N2" "$(printf '%s' "$J4" | q 'L("N2").mode')" "headless"
    eq "agents source ($(basename "$AGCMD")): N10 falls back to the Live-state pid (dead, lock held)" "$(printf '%s' "$J4" | q 'L("N10").mode+":"+L("N10").alive')" "?:false"
done

# ------------------------------------------------------------------ HIMMEL-3412(b): readSweep rc contract
# A sweep that dies with an rc other than 0/20 is not a complete sweep, even if it
# printed some slug= rows before it died: legs go UNKNOWN, not a partial trust.
cat > "$W/bin/queue-lock-partial" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "status --sweep "*)
        p=u__repo__HIMMEL
        echo "sweep: read only $3"
        echo "slug=${p}-9001-N1-alpha-2026-09-22-RESUME session=cachyos-x8664-pid7001 host=h age=600s status=OK"
        exit 1
        ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$W/bin/queue-lock-partial"
J6="$(FLEET_QUEUE_LOCK="$W/bin/queue-lock-partial" run --json "${COMMON[@]}" 2>/dev/null)"
eq "sweep rc=1 with partial rows: sweep unavailable warning" "$(printf '%s' "$J6" | q 's.warnings.some(w=>/queue-lock sweep unavailable/.test(w))')" "true"
eq "sweep rc=1 with partial rows: N1 lock falls back to UNKNOWN, not the partial row" "$(printf '%s' "$J6" | q 'L("N1").lock.state')" "UNKNOWN"
eq "sweep rc=1: unlisted-held legs (need the sweep to be found) drop out" "$(printf '%s' "$J6" | q 's.legs.length')" "9"

# rc=20 (a flagged lock) is a COMPLETE sweep, not a failure.
cat > "$W/bin/queue-lock-flagged" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "status --sweep "*)
        p=u__repo__HIMMEL
        echo "sweep: read only $3"
        echo "slug=${p}-9001-N1-alpha-2026-09-22-RESUME session=cachyos-x8664-pid7001 host=h age=600s status=OK"
        echo "slug=${p}-9002-N2-beta-2026-09-22-RESUME session=cachyos-x8664-pid7002 host=h age=30s status=OK"
        echo "slug=${p}-9003-N3-gamma-2026-09-22-RESUME session=cachyos-x8664-pid7003 host=h age=90s status=OK"
        echo "slug=${p}-9004-N4-delta-2026-09-22-RESUME session=cachyos-x8664-pid7004 host=h age=4000s status=IDLE-HELD?"
        echo "slug=${p}-9005-N5-eps-2026-09-22-RESUME session=cachyos-x8664-pid7005 host=h age=50s status=OK"
        echo "slug=${p}-9006-N6-zeta-2026-09-22-RESUME session=cachyos-x8664-pid7006 host=h age=20s status=OK"
        echo "slug=${p}-9009-N9-iota-2026-09-22-RESUME session=cachyos-x8664-pid7009 host=h age=15s status=OK"
        echo "slug=${p}-9010-N10-kappa-2026-09-22-RESUME session=cachyos-x8664-pid7010 host=h age=12s status=OK"
        echo "slug=${p}-9011-N11-mu-2026-09-22-RESUME session=host-nopid host=h age=15s status=OK"
        echo "slug=${p}-9013-N13-nu-2026-09-22-RESUME session=host-nopid host=h age=15s status=OK"
        echo "slug=${p}-nextleg-2026-09-22Z-console session=cachyos-x8664-pid7100 host=h age=5s status=OK"
        exit 20
        ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$W/bin/queue-lock-flagged"
J7="$(FLEET_QUEUE_LOCK="$W/bin/queue-lock-flagged" run --json "${COMMON[@]}" 2>/dev/null)"
eq "sweep rc=20 (flagged lock): still a complete sweep, no warning" "$(printf '%s' "$J7" | q 's.warnings.some(w=>/queue-lock sweep unavailable/.test(w))')" "false"
eq "sweep rc=20: N1 lock resolves normally" "$(printf '%s' "$J7" | q 'L("N1").lock.state')" "FRESH"
eq "sweep rc=20: every row still renders" "$(printf '%s' "$J7" | q 's.legs.length')" "12"

# ------------------------------------------------------------------ server
cat > "$W/srv-test.mjs" <<'JS'
import { spawn } from 'node:child_process';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
const [sut, ...rest] = process.argv.slice(2);
const say = (ok, msg) => console.log(`${ok ? 'ok' : 'FAIL'} - ${msg}`);
const child = spawn('node', [sut, '--serve', '--port', '0', ...rest], { stdio: ['ignore', 'pipe', 'inherit'] });
const kill = () => child.kill('SIGKILL');
process.on('exit', kill);
const line = await new Promise((res) => {
    let buf = '';
    child.stdout.on('data', (d) => { buf += d; const m = /http:\/\/127\.0\.0\.1:(\d+)\//.exec(buf); if (m) res(m); });
    setTimeout(() => res(null), 15000);
});
if (!line) { say(false, 'server printed its loopback URL'); kill(); process.exit(0); }
const port = Number(line[1]);
say(true, 'server printed its loopback URL');
const get = (path, opt = {}) => new Promise((res, rej) => {
    const r = http.request({ host: '127.0.0.1', port, path, method: opt.method || 'GET', headers: opt.headers || {} }, (resp) => {
        let b = ''; resp.on('data', (d) => { b += d; }); resp.on('end', () => res({ status: resp.statusCode, body: b, headers: resp.headers }));
    });
    r.on('error', rej); r.end();
});
const page = await get('/');
say(page.status === 200 && /<!doctype html>/.test(page.body), 'GET / serves the page');
say(/const LIVE = true/.test(page.body), 'the served page polls');
say(!/Z-N1-a1a1a1a1|cachyos-x8664-pid7001/.test(page.body), 'the served page holds no nonce or lock token');
const api = await get('/api/fleet');
let snap = null; try { snap = JSON.parse(api.body); } catch { /* reported below */ }
say(api.status === 200 && snap && snap.legs.length === 12, 'GET /api/fleet returns the snapshot');
say(/json/.test(api.headers['content-type'] || ''), '/api/fleet is application/json');
say(!/Z-N1-a1a1a1a1|cachyos-x8664-pid7001|Z-N2-deadbeef/.test(api.body), '/api/fleet holds no nonce or lock token');
say((await get('/nope')).status === 404, 'unknown path is 404');
say((await get('/api/fleet', { method: 'POST' })).status === 405, 'POST is 405 (read-only server)');
say((await get('/api/fleet', { method: 'DELETE' })).status === 405, 'DELETE is 405');
say((await get('/api/fleet', { headers: { host: 'evil.example:' + port } })).status === 403, 'a foreign Host header is refused (DNS rebinding)');
say(/no-store/.test(api.headers['cache-control'] || ''), 'responses are no-store');
say(/default-src 'none'/.test(page.headers['content-security-policy'] || ''), 'the page carries a locked-down CSP');
// Bound to loopback only: the same port must refuse on every non-loopback address.
const ext = Object.values(os.networkInterfaces()).flat().filter((i) => i && !i.internal && i.family === 'IPv4').map((i) => i.address);
if (!ext.length) say(true, 'no non-loopback interface on this host (loopback-only probe skipped)');
for (const a of ext.slice(0, 2)) {
    const refused = await new Promise((res) => {
        const s = net.connect({ host: a, port, timeout: 3000 }, () => { s.destroy(); res(false); });
        s.on('error', () => res(true)); s.on('timeout', () => { s.destroy(); res(true); });
    });
    say(refused, `not reachable on ${a} (bound to 127.0.0.1 only)`);
}
kill();
process.exit(0);
JS
SRV_RC=0
SRV="$(FLEET_QUEUE_LOCK="$W/bin/queue-lock" FLEET_BANK="$W/bin/bank" FLEET_GH="$W/bin/gh" \
    FLEET_AGENTS="$W/bin/agents" AG_JSON="$W/agents.json" \
    FLEET_PROC="$W/proc" GH_OPEN="$W/open.json" HANDOVER_DIR="$ROOT" \
    node "$W/srv-test.mjs" "$SUT" "${COMMON[@]}" 2>&1)" || SRV_RC=$?
printf '%s\n' "$SRV"
# an uncaught error in the probe exits non-zero without printing FAIL; do not let that pass
[ "$SRV_RC" -eq 0 ] || fail "server probe exited $SRV_RC"
case "$SRV" in *FAIL*) fails=$((fails + $(printf '%s\n' "$SRV" | grep -c '^FAIL'))) ;; esac
[ -n "$SRV" ] || fail "server probe produced output"

# --serve refuses a non-loopback bind request outright.
run --serve --port 0 --host 0.0.0.0 "${COMMON[@]}" >/dev/null 2>&1; eq "--host is not a flag (no way to bind off loopback)" "$?" "2"

if [ "$fails" -eq 0 ]; then
    printf 'test-fleet.sh: all passed\n'
    exit 0
fi
printf 'test-fleet.sh: %s failed\n' "$fails"
exit 1
