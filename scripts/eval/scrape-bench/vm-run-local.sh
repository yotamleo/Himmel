#!/usr/bin/env bash
# Guest-side runner: one local provider over the fixture while sampling system
# memory. Usage: vm-run-local.sh <scrapling-static|scrapling-stealth|lightpanda|camofox>
# The provider's command template lives here, so the report is reproducible from
# the repo. Prints wall seconds and the peak drop in MemAvailable (MB).
set -u
name=${1:?provider name}
here=$(cd "$(dirname "$0")" && pwd)
export SCRAPLING_BIN=${SCRAPLING_BIN:-$HOME/bench/sc-venv/bin/scrapling}
export LIGHTPANDA_BIN=${LIGHTPANDA_BIN:-$HOME/bench/lightpanda}
case "$name" in
  scrapling-static|scrapling-stealth|lightpanda|camofox)
    cmd="python3 '$here/local_adapters.py' $name {url}" ;;
  *) echo "unknown provider: $name" >&2; exit 2 ;;
esac
mem() { awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo; }
samples=$(mktemp "${TMPDIR:-/tmp}/scrape-bench-ram.XXXXXX") || exit 1
base=$(mem)
( while :; do mem >> "$samples"; sleep 0.5; done ) &
sampler=$!
trap 'kill "$sampler" 2>/dev/null; rm -f "$samples"' EXIT INT TERM
start=$(date +%s)
python3 "$here/bench.py" --provider cmd --name "$name" --fixture "$here/fixtures/urls.json" \
  --out "$here/results/$name.jsonl" --cmd "$cmd"
rc=$?
wall=$(( $(date +%s) - start ))
kill "$sampler" 2>/dev/null
low=$(sort -n "$samples" | head -1)
echo "provider=$name rc=$rc wall_s=$wall base_avail_mb=$base min_avail_mb=${low:-$base} peak_ram_mb=$(( base - ${low:-$base} ))"
exit "$rc"
