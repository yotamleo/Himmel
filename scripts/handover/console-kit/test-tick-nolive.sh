#!/usr/bin/env bash
# test-tick-nolive.sh — HIMMEL-4234. tick.sh reads a leg that never went LIVE as
# `<N>:NOLIVE` and a leg whose session transcript ends in a `continued-in`
# record as `<N>:FORKED`; console-wait.sh then wakes on the legs= change.
# Hermetic: stubs for every external probe, scratch HOME / handover / projects.
# Its own file because test-tick.sh is being edited by another open PR.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
WAIT="$HERE/console-wait.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-nolive-test.XXXXXX")" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/home" "$W/projects/p" "$W/console-work/chain"

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status) case "$2" in *-N910-*) printf '%s\n' 'status: FRESH'; exit 11 ;; *) printf '%s\n' free; exit 0 ;; esac ;;
esac
exit 2
STUB
printf '#!/usr/bin/env bash\nprintf "%%s\\n" 28\n' > "$W/repo/scripts/context-fill.sh"
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/atq"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/gh"
printf '#!/usr/bin/env bash\ncat "$PS_FIXTURE"\n' > "$W/bin/ps"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/bun"
printf '%s\n' '    1     0 40-00:00:01 /sbin/init' > "$W/ps-none.txt"
cp "$HERE/../../lanes/ceiling-conformance.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh"
cp "$HERE/../../lanes/lib/claude-sessions.sh" "$W/repo/scripts/lanes/lib/claude-sessions.sh"
cat > "$W/repo/scripts/lib/bank-preflight.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8' >&2
printf '%s\n' PROCEED
STUB
chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/repo/scripts/lib/bank-preflight.sh" "$W/bin/"*
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"

export PATH="$W/bin:$PATH"
export HOME="$W/home"
export HANDOVER_DIR="$W/handover" REPO="$W/repo" TICK_TMPDIR="$W" PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json" TICK_STATE_DIR="$W/state" CLAUDE_SESSIONS_PROC="$W/proc"
export TICK_LAUNCH_DIR="$W/console-work" TICK_PROJECTS_DIR="$W/projects"
export DOC="$W/handover/console.md" TOKEN=t LEGS=''

# mkleg <id-slug> [bullet...]: a leg doc whose marker bullets are the args.
mkleg() {
    local f="$W/handover/HIMMEL-9$1.md"; shift
    printf '# leg\n' > "$f"
    local b
    for b in "$@"; do printf '%s\n' "$b" >> "$f"; done
    printf '%s' "$f"
}
# manifest <doc:minutes-ago>...: a fleet manifest with each leg added N min ago.
manifest() {
    local m="$W/handover/console.fleet.json" legs="" e d t
    for e in "$@"; do
        d="${e%%:*}"; t="$(/bin/date -u -d "${e##*:} minutes ago" +%Y-%m-%dT%H:%M:%SZ)"
        legs="$legs${legs:+,}{\"doc\":\"$d\",\"label\":\"x\",\"added\":\"$t\"}"
    done
    printf '{"schema":1,"legs":[%s]}\n' "$legs" > "$m"
    printf '%s' "$m"
}
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
run_from() { bash "$SUT" --legs-from "$1" 2>/dev/null; }

# --- NOLIVE: at / before the threshold -------------------------------------
old="$(mkleg 901-N901-old)"; young="$(mkleg 902-N902-young)"
m="$(manifest "$old:20" "$young:2")"
out="$(run_from "$m")"
check 'a leg with no lock and no LIVE bullet 20 min after its manifest add reads NOLIVE' 'N901:NOLIVE,N902:FREE' "$(field legs "$out")"
check 'tails= still says ? for the NOLIVE leg' 'N901:?,N902:?' "$(field tails "$out")"

m="$(manifest "$old:11")"
check 'past the 10 min default reads NOLIVE' 'N901:NOLIVE' "$(field legs "$(run_from "$m")")"
m="$(manifest "$old:9")"
check 'under the 10 min default stays FREE' 'N901:FREE' "$(field legs "$(run_from "$m")")"
export TICK_NOLIVE_MIN=5
m="$(manifest "$old:6")"
check 'TICK_NOLIVE_MIN=5 moves the threshold (6 min is NOLIVE)' 'N901:NOLIVE' "$(field legs "$(run_from "$m")")"
m="$(manifest "$old:4")"
check 'TICK_NOLIVE_MIN=5 (4 min is still FREE)' 'N901:FREE' "$(field legs "$(run_from "$m")")"
unset TICK_NOLIVE_MIN

# --- later states are never NOLIVE ------------------------------------------
wr="$(mkleg 903-N903-wrapped '- 10:00 LIVE — x' '- 10:30 WRAPPED — done')"
rd="$(mkleg 904-N904-ready '- 10:00 READY 1 abc GREEN')"
lv="$(mkleg 905-N905-live '- 10:00 LIVE — working')"
bl="$(mkleg 906-N906-blocked '- 10:00 BLOCKED — q')"
fresh="$(mkleg 910-N910-held)"
m="$(manifest "$wr:30" "$rd:30" "$lv:30" "$bl:30" "$fresh:30")"
out="$(run_from "$m")"
check 'WRAPPED / READY / LIVE / BLOCKED / held-lock legs are never NOLIVE' 'N903:WRAPPED,N904:FREE,N905:FREE,N906:FREE,N910:FRESH' "$(field legs "$out")"

# --- start time fallbacks: launch log armed line, then doc mtime ------------
nm="$(mkleg 907-N907-nomanifest)"
touch -d '30 minutes ago' "$nm"
check 'no manifest, no launch log: the doc mtime starts the clock (old = NOLIVE)' 'N907:NOLIVE' "$(field legs "$(bash "$SUT" --legs "$nm" 2>/dev/null)")"
touch "$nm"
check 'no manifest, no launch log: a fresh doc is still FREE' 'N907:FREE' "$(field legs "$(bash "$SUT" --legs "$nm" 2>/dev/null)")"
ts="$(/bin/date -d '40 minutes ago' +%F_%T)"  # gnu-ok: Linux-only kit
printf '%s armed: name=HIMMEL-9907-N907-nomanifest doc=%s signal=x deadline=y role=leg\n' "$ts" "$nm" > "$W/console-work/chain/a.launch.log"
check 'the launch log armed: line (older than the fresh doc) starts the clock' 'N907:NOLIVE' "$(field legs "$(bash "$SUT" --legs "$nm" 2>/dev/null)")"
rm -f "$W/console-work/chain/a.launch.log"

# --- FORKED ------------------------------------------------------------------
fk="$(mkleg 908-N908-forked)"; nf="$(mkleg 909-N909-notforked)"; nt="$(mkleg 911-N911-notranscript)"
printf '%s\n' '{"type":"custom-title","customTitle":"HIMMEL-9908-N908-forked","sessionId":"s1"}' '{"type":"continued-in","sessionId":"s1","continuedInSessionId":"s2"}' '{"type":"cost-state","sessionId":"s1"}' > "$W/projects/p/s1.jsonl"
printf '%s\n' '{"type":"custom-title","customTitle":"HIMMEL-9909-N909-notforked","sessionId":"s3"}' '{"type":"assistant","sessionId":"s3"}' > "$W/projects/p/s3.jsonl"
# a transcript that only MENTIONS the name is not a custom-title link: never guessed
printf '%s\n' '{"type":"user","text":"HIMMEL-9911-N911-notranscript"}' '{"type":"continued-in","sessionId":"s4"}' > "$W/projects/p/s4.jsonl"
m="$(manifest "$fk:1" "$nf:1" "$nt:1")"
check 'a leg whose custom-title transcript ends in continued-in reads FORKED at once; the others are untouched' 'N908:FORKED,N909:FREE,N911:FREE' "$(field legs "$(run_from "$m")")"
m="$(manifest "$fk:30" "$nf:30" "$nt:30")"
check 'FORKED wins over NOLIVE; a missing transcript is skipped (NOLIVE by age, never FORKED)' 'N908:FORKED,N909:NOLIVE,N911:NOLIVE' "$(field legs "$(run_from "$m")")"
# a continuation under the same title that does not end in continued-in is alive
printf '%s\n' '{"type":"custom-title","customTitle":"HIMMEL-9908-N908-forked","sessionId":"s2"}' '{"type":"assistant","sessionId":"s2"}' > "$W/projects/p/s2.jsonl"
touch -d '1 minute ago' "$W/projects/p/s1.jsonl"
check 'the newest transcript under the title decides: a live continuation is not FORKED' 'N908:NOLIVE' "$(field legs "$(run_from "$(manifest "$fk:30")")")"
rm -f "$W/projects/p/s2.jsonl"
# a forked leg that has since wrapped reads WRAPPED
printf '%s\n' '- 10:00 WRAPPED — done' >> "$fk"
check 'a wrapped leg is never FORKED' 'N908:WRAPPED' "$(field legs "$(run_from "$(manifest "$fk:30")")")"

# a leg that has written any marker bullet is never relabelled FORKED
mk="$(mkleg 912-N912-markerfork '- 10:00 LIVE — working')"
printf '%s\n' '{"type":"custom-title","customTitle":"HIMMEL-9912-N912-markerfork","sessionId":"s5"}' '{"type":"continued-in","sessionId":"s5"}' > "$W/projects/p/s5.jsonl"
check 'a LIVE leg whose transcript ended in continued-in is not relabelled FORKED' 'N912:FREE' "$(field legs "$(run_from "$(manifest "$mk:1")")")"
# a resumed session appends records after continued-in: not forked
rs="$(mkleg 913-N913-resumed)"
printf '%s\n' '{"type":"custom-title","customTitle":"HIMMEL-9913-N913-resumed","sessionId":"s6"}' '{"type":"continued-in","sessionId":"s6"}' '{"type":"assistant","sessionId":"s6"}' '{"type":"cost-state","sessionId":"s6"}' > "$W/projects/p/s6.jsonl"
check 'a transcript that resumed after continued-in is not FORKED' 'N913:FREE' "$(field legs "$(run_from "$(manifest "$rs:1")")")"

# --- threshold parsing and launch-log ordering --------------------------------
export TICK_NOLIVE_MIN=08
check 'a leading-zero TICK_NOLIVE_MIN is decimal, not an octal error (9 min is NOLIVE)' 'N901:NOLIVE' "$(field legs "$(run_from "$(manifest "$old:9")")")"
unset TICK_NOLIVE_MIN
ln="$(mkleg 914-N914-logorder)"
touch -d '30 minutes ago' "$ln"
{
    printf '%s armed: name=HIMMEL-9914-N914-logorder doc=%s signal=x deadline=y role=leg\n' "$(/bin/date -d '40 minutes ago' +%F_%T)" "$ln"  # gnu-ok: Linux-only kit
    printf '%s armed: name=HIMMEL-9914-N914-logorder doc=%s signal=x deadline=y role=leg\n' "$(/bin/date -d '2 minutes ago' +%F_%T)" "$ln"  # gnu-ok: Linux-only kit
} > "$W/console-work/chain/b.launch.log"
check 'the newest armed: timestamp wins over an older one (2 min ago is FREE)' 'N914:FREE' "$(field legs "$(bash "$SUT" --legs "$ln" 2>/dev/null)")"
rm -f "$W/console-work/chain/b.launch.log"

# --- the waiter wakes when legs= moves FREE -> NOLIVE / FREE -> FORKED -------
STUB="$W/stub"; mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/tick.line"
EOF
printf '#!/usr/bin/env bash\ncat "$STUB/bank"\n' > "$STUB/bank.sh"
export STUB CONSOLE_WAIT_TICK="$STUB/tick.sh" CONSOLE_WAIT_BANK="$STUB/bank.sh"
export CONSOLE_WAIT_INTERVAL=1 CONSOLE_WAIT_POLL_SEC=0.2 CONSOLE_WAIT_FAIL_WAKE=1000
printf 'PROCEED\n' > "$STUB/bank"
tick_line() {
    printf 'TICK 03:00 hb=1m legs=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:? inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip\n' "$1" > "$STUB/tick.line"
}
wait_hb() { local n=0; while [ "$n" -lt 50 ]; do grep -q 'key=[0-9a-f]' "$1.wait" 2>/dev/null && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
waiter_case() { # <name> <baseline legs> <new legs>
    local inbox="$W/in-$1/consoles/c.md" n=0 pid
    inbox="$W/in-${#1}-$2-$3/consoles/c.md"
    mkdir -p "$(dirname "$inbox")"; : > "$inbox"
    tick_line "$2"
    bash "$WAIT" "$inbox" --legs "N1.md" > "$W/w.out" 2>/dev/null &
    pid=$!
    wait_hb "$inbox" || fail "$1: waiter never took its baseline"
    tick_line "$3"
    while [ "$n" -lt 80 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fail "$1: waiter did not wake"; else wait "$pid"; fi
    case "$(cat "$W/w.out")" in *'WAKE tick changed=legs'*) pass "$1" ;; *) fail "$1 (out: $(cat "$W/w.out"))" ;; esac
}
waiter_case 'the waiter wakes with changed=legs when a silent-baseline leg turns NOLIVE' 'N1:FREE' 'N1:NOLIVE'
waiter_case 'the waiter wakes when a leg turns FORKED' 'N1:FREE' 'N1:FORKED'

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
