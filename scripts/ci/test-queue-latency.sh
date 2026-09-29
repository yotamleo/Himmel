#!/usr/bin/env bash
# Test for scripts/ci/queue-latency.sh (HIMMEL-3840).
# A fake gh serves canned Actions API fixtures and applies the script's own
# --jq expression with real jq, so the filters are exercised, not stubbed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/queue-latency.sh"
TMP="$(mktemp -d "/tmp/himmel-test-queue-latency.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../lib/timeout-bin.sh
. "$ROOT/scripts/lib/timeout-bin.sh" 2>/dev/null

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
is()  { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1: want '$2' got '$3'"; fi; }

mkdir -p "$TMP/bin" "$TMP/fx"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: `gh api <path> --jq <expr>`; fixtures live in $FX.
[ -n "${FAKE_GH_FAIL:-}" ] && { echo "fake-gh: simulated API failure" >&2; exit 1; }
shift; path="$1"; shift
expr=""
while [ $# -gt 0 ]; do case "$1" in --jq) expr="$2"; shift 2 ;; *) shift ;; esac; done
case "$path" in
  *status=in_progress*) f="$FX/runs-in_progress.json" ;;
  *status=queued*)      f="$FX/runs-queued.json" ;;
  */runs/*/jobs*)       id="${path#*/runs/}"; id="${id%%/*}"; f="$FX/jobs-$id.json" ;;
  *) echo "fake-gh: unsupported $path" >&2; exit 1 ;;
esac
[ -f "$f" ] || { echo "fake-gh: no fixture $f" >&2; exit 1; }
jq -r "$expr" < "$f"
EOF
chmod +x "$TMP/bin/gh"

now=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }  # GNU || BSD
t10=$(iso $((now - 600)))   # 10 minutes ago
t3=$(iso $((now - 180)))    # 3 minutes ago

# jobs fixture helper: jobs_json <n_ip_linux> <n_ip_macos> <n_queued> <queued_created>
jobs_json() {
  local out='{"jobs":[' sep='' i
  for ((i = 0; i < $1; i++)); do out+="$sep{\"status\":\"in_progress\",\"labels\":[\"ubuntu-latest\"],\"created_at\":\"$t10\"}"; sep=','; done
  for ((i = 0; i < $2; i++)); do out+="$sep{\"status\":\"in_progress\",\"labels\":[\"macos-latest\"],\"created_at\":\"$t10\"}"; sep=','; done
  for ((i = 0; i < $3; i++)); do out+="$sep{\"status\":\"queued\",\"labels\":[\"ubuntu-latest\"],\"created_at\":\"$4\"}"; sep=','; done
  echo "$out]}"
}
runs_json() { # runs_json <status> <id>...
  local st="$1" out='{"workflow_runs":[' sep=''; shift
  for id in "$@"; do out+="$sep{\"id\":$id,\"status\":\"$st\",\"created_at\":\"$t10\"}"; sep=','; done
  echo "$out]}"
}
reset() { rm -f "$TMP"/fx/*; }
run() { FX="$TMP/fx" PATH="$TMP/bin:$PATH" bash "$SCRIPT" -R owner/repo 2>&1; }

if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# idle
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
out="$(run)"
is "idle" "ci-queue: jobs_in_progress=0/20 macos=0/5 queued=0 oldest_wait=0m" "$out"

# saturated 20/20 across two runs, 2 queued jobs waiting 10m
reset
runs_json in_progress 1 2 > "$TMP/fx/runs-in_progress.json"; runs_json queued 3 > "$TMP/fx/runs-queued.json"
jobs_json 12 0 0 "$t10" > "$TMP/fx/jobs-1.json"
jobs_json 8 0 0 "$t10" > "$TMP/fx/jobs-2.json"
jobs_json 0 0 2 "$t10" > "$TMP/fx/jobs-3.json"
out="$(run)"
is "saturated 20/20" "ci-queue: jobs_in_progress=20/20 macos=0/5 queued=2 oldest_wait=10m" "$out"

# macOS 5/5 (counted inside the total)
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
jobs_json 3 5 0 "$t3" > "$TMP/fx/jobs-1.json"
out="$(run)"
is "macOS 5/5" "ci-queue: jobs_in_progress=8/20 macos=5/5 queued=0 oldest_wait=0m" "$out"

# a run in BOTH lists is counted once
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued 1 > "$TMP/fx/runs-queued.json"
jobs_json 2 0 0 "$t3" > "$TMP/fx/jobs-1.json"
out="$(run)"
case "$out" in *jobs_in_progress=2/20*) ok "dedupe run listed twice" ;; *) bad "dedupe: $out" ;; esac

# storm: queued runs with no jobs materialised still count as waiting
reset
runs_json in_progress > "$TMP/fx/runs-in_progress.json"; runs_json queued 7 8 > "$TMP/fx/runs-queued.json"
echo '{"jobs":[]}' > "$TMP/fx/jobs-7.json"; echo '{"jobs":[]}' > "$TMP/fx/jobs-8.json"
out="$(run)"
is "queued runs with 0 jobs" "ci-queue: jobs_in_progress=0/20 macos=0/5 queued=2 oldest_wait=10m" "$out"

# API error -> unknown, exit 0
reset
out="$(FAKE_GH_FAIL=1 run)"; rc=$?
is "API error -> unknown" "ci-queue: unknown" "$out"
is "API error -> rc 0" "0" "$rc"

# a per-run jobs failure (no fixture) also degrades to unknown
reset
runs_json in_progress 1 > "$TMP/fx/runs-in_progress.json"; runs_json queued > "$TMP/fx/runs-queued.json"
out="$(run)"
is "per-run jobs failure -> unknown" "ci-queue: unknown" "$out"

# `-R` with no argument must fail fast, not spin (shift 2 fails on a lone arg)
if [ -n "$_TIMEOUT_BIN" ]; then
  "$_TIMEOUT_BIN" 5 bash "$SCRIPT" -R >/dev/null 2>&1; rc=$?
  is "-R without value exits 2" "2" "$rc"
else
  echo "skip - -R without value: no timeout binary"
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASSED"; exit 0; else echo "FAILED=$fails"; exit 1; fi
