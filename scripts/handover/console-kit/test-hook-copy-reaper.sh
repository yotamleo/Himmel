#!/usr/bin/env bash
# test-hook-copy-reaper.sh — HIMMEL-4183. Hermetic tests for
# hook-copy-reaper.sh: the process table is a PATH `ps` stub over a fixture and
# the kill is a logging stub (HOOK_REAPER_KILL), so no live process is read or
# signalled.
#
# PLATFORM GUARD: no .ps1 twin, by design — the reaper reads procps or macOS
# `ps`; this Bash 3.2 suite exercises that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/hook-copy-reaper.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/hook-copy-reaper-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (unexpected '$3' in '$2')" ;; *) pass "$1" ;; esac; }

mkdir -p "$W/bin"
uid=$(id -u)
# `ps` stub: the ONE argv the SUT may use, answered from $PS_FIXTURE.
cat > "$W/bin/ps" <<STUB
#!/usr/bin/env bash
if [ "\$*" = "-u $uid -o pid=,ppid=,etime=,pcpu=,comm=,args=" ]; then
  [ "\${PS_FAIL:-0}" -eq 0 ] || exit 1
  cat "\$PS_FIXTURE"; exit 0
fi
echo "unexpected ps argv: \$*" >&2; exit 3
STUB
# shellcheck disable=SC2016  # $* and $KILL_LOG must reach the stub literally
printf '#!/usr/bin/env bash\necho "$*" >> "$KILL_LOG"\nexit "${KILL_RC:-0}"\n' > "$W/bin/killstub"
# A failing awk, for the analysis-failure case.
mkdir -p "$W/badbin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/badbin/awk"
chmod +x "$W/bin/ps" "$W/bin/killstub" "$W/badbin/awk"

# 501: the incident shape (5h, 89 %, under the systemd --user subreaper) and
# 502 its own looping $(…) subshell (parent 501, so not itself reparented);
# 503: reparented to init, its comm a path as macOS ps prints it; 504 young;
# 505 idle; 506 still owned by a live harness (700); 507 a hook outside
# /tmp/claude-*; 508 not a shell script. Ages are etime ([[dd-]hh:]mm:ss).
cat > "$W/ps.txt" <<'FIX'
 1304     1 11-13:46:39  0.0 systemd  /usr/lib/systemd/systemd --user
  501  1304    05:00:00 89.5 bash     bash /tmp/claude-1000/j1677/base/scripts/hooks/block-chokepoint-env-prefix.sh
  502   501    05:00:00 89.0 bash     bash /tmp/claude-1000/j1677/base/scripts/hooks/block-chokepoint-env-prefix.sh
  503     1    02:30:00 95.0 /bin/bash /usr/bin/bash /tmp/claude-1000/-home-u/6c7d2135/scratchpad/hook.sh --flag
  504  1304       10:00 99.0 bash     bash /tmp/claude-1000/j/young.sh
  505  1304    05:00:00  2.0 bash     bash /tmp/claude-1000/j/idle.sh
  700  1304    05:00:00  1.0 python3  python3 harness.py
  506   700    05:00:00 99.0 bash     bash /tmp/claude-1000/j/owned.sh
  507  1304    05:00:00 99.0 bash     bash /home/u/himmel/scripts/hooks/real.sh
  508  1304    05:00:00 99.0 node     node /tmp/claude-1000/j/x.sh.js
  509  1304  1-00:00:00 60.0 bash     bash /tmp/claude-1000/j/dayold.sh
FIX

run() { PATH="$W/bin:$PATH" PS_FIXTURE="$W/ps.txt" KILL_LOG="$W/kill.log" \
    HOOK_REAPER_KILL="$W/bin/killstub" bash "$SUT" "$@"; }

out="$(run)"; rc=$?
eq 'report: rc 1 when copies are found' 1 "$rc"
contains 'report: the subreaper-parented spinner' "$out" 'pid=501 age=300m cpu=89.5 script=/tmp/claude-1000/j1677/base/scripts/hooks/block-chokepoint-env-prefix.sh'
contains 'report: the init-parented spinner' "$out" 'pid=503 age=150m cpu=95.0 script=/tmp/claude-1000/-home-u/6c7d2135/scratchpad/hook.sh'
contains 'report: a day-form etime (1-00:00:00) is 1440m and counted' "$out" 'pid=509 age=1440m cpu=60.0 script=/tmp/claude-1000/j/dayold.sh'
contains 'report: summary line' "$out" 'hook-copies=3'
for p in 502 504 505 506 507 508; do lacks "report: pid $p excluded" "$out" "pid=$p "; done
lacks 'report: never kills by default' "$out" 'killed='
if [ -e "$W/kill.log" ]; then fail 'report: kill stub was called'; else pass 'report: kill stub untouched'; fi

out="$(run --kill)"; rc=$?
eq '--kill: rc 1 (copies were found)' 1 "$rc"
eq '--kill: SIGKILLs each copy and its descendants' '-KILL 501 502 503 509' "$(cat "$W/kill.log")"
contains '--kill: says what it killed' "$out" 'killed=501,502,503,509'

out="$(run --min 2000)"; rc=$?
eq '--min above every age: none' 'hook-copies=none' "$out"
eq '--min above every age: rc 0' 0 "$rc"

out="$(run --cpu 90)"
contains '--cpu 90 keeps the 95 % copy' "$out" 'pid=503 '
lacks '--cpu 90 drops the 89.5 % copy' "$out" 'pid=501 '

out="$(PS_FAIL=1 run)"; rc=$?
eq 'unreadable process table: ?' 'hook-copies=?' "$out"
eq 'unreadable process table: rc 3' 3 "$rc"

rm -f "$W/kill.log"
out="$(KILL_RC=1 run --kill)"; rc=$?
eq '--kill failing: rc 3' 3 "$rc"
contains '--kill failing: says so' "$out" 'kill-failed=501,502,503,509'
lacks '--kill failing: never claims killed=' "$out" 'killed='

out="$(PATH="$W/badbin:$PATH" run)"; rc=$?
eq 'failing analysis: ?' 'hook-copies=?' "$out"
eq 'failing analysis: rc 3' 3 "$rc"

run --bogus >/dev/null 2>&1
eq 'unknown flag: rc 2' 2 "$?"
run --min x >/dev/null 2>&1
eq 'non-numeric --min: rc 2' 2 "$?"

if [ "$fails" -eq 0 ]; then echo "PASS: hook-copy-reaper"; exit 0; fi
echo "FAIL: hook-copy-reaper ($fails)"; exit 1
