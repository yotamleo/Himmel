#!/usr/bin/env bash
# scripts/ci/shard-manifest-verify.sh — HIMMEL-3897 (HIMMEL-3815 slice G).
#
# The shell-unit aggregator's proof that the fixed shards ran exactly what the
# base-sourced selection picked, at this head. Each shard's run-shell-tests.sh
# writes manifest-shard<k>.txt (SUITE_MANIFEST): the impacted-selection.sh
# header it acted on, a `shard k/n` line, then one line per suite it touched:
#   ran <rc> <path>   the suite ran on this shard with that exit code
#   skip <path>       filtered out (tier, platform, impacted, ...)
#   unrun <path>      assigned to this shard but never started (budget)
#   notfound <path>   selected, but the runner never discovered it
#
# Usage: shard-manifest-verify.sh --dir <d> --shards <n> --selection <file>
#   <file> is impacted-selection.sh's output, computed by the aggregator itself.
#
# Refuses (rc 1): a missing manifest; a manifest whose head, header or shard
# line differs from what this job computed (a manifest from another sha, or a
# shard that decided differently); any `unrun`; any `ran` with rc != 0; and in
# impacted mode a selected suite that no shard ran (unless it was skipped or
# not found — named as a NOTE), a suite ran more than once, or a suite ran that
# was not selected. Prints OK and exits 0 otherwise; rc 2 on usage errors.
#
# Platform guard: bash 3.2+ and POSIX awk; the aggregator runs on Linux.
set -uo pipefail

dir="" shards="" selection=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:-}"; shift 2 || break ;;
    --shards) shards="${2:-}"; shift 2 || break ;;
    --selection) selection="${2:-}"; shift 2 || break ;;
    *) echo "shard-manifest-verify: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -z "$dir" ] || [ -z "$selection" ] || ! [[ "$shards" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: shard-manifest-verify.sh --dir <d> --shards <n> --selection <file>" >&2
  exit 2
fi
if [ ! -r "$selection" ] || ! grep -qE '^mode (full|impacted)$' "$selection"; then
  echo "shard-manifest-verify: selection '$selection' is unreadable or has no mode line" >&2
  exit 2
fi

HDR_RE='^(mode|reason|base|head|selector|changed|suite) '
want_hdr=$(grep -E "$HDR_RE" "$selection")
want_head=$(grep -m1 '^head ' "$selection")
mode=$(grep -m1 '^mode ' "$selection"); mode="${mode#mode }"

bad=0
bodies=""
k=1
while [ "$k" -le "$shards" ]; do
  m="$dir/manifest-shard$k.txt"
  if [ ! -r "$m" ]; then
    echo "FAIL: missing manifest for shard$k: $m"
    bad=1; k=$((k + 1)); continue
  fi
  got_head=$(grep -m1 '^head ' "$m")
  got_shard=$(grep -m1 '^shard ' "$m")
  if [ "$got_head" != "$want_head" ]; then
    echo "FAIL: shard$k: manifest '${got_head:-no head line}' != selection '$want_head'"
    bad=1
  elif [ "$(grep -E "$HDR_RE" "$m")" != "$want_hdr" ]; then
    echo "FAIL: shard$k: manifest header differs from the selection this job computed"
    diff <(printf '%s\n' "$want_hdr") <(grep -E "$HDR_RE" "$m") | sed 's/^/    /'
    bad=1
  fi
  if [ "$got_shard" != "shard $k/$shards" ]; then
    echo "FAIL: shard$k: want 'shard $k/$shards', found '${got_shard:-no shard line}'"
    bad=1
  fi
  bodies="${bodies}$(grep -E '^(ran|skip|unrun|notfound) ' "$m" | sed "s/^/$k /")"$'\n'
  k=$((k + 1))
done

# Accounting across every shard. Input: "sel <path>" lines, then "<k> <body>".
acct=$( { grep '^suite ' "$selection" | sed 's/^suite /sel /'; printf '%s' "$bodies"; } | awk -v mode="$mode" '
  $1 == "sel" { sel[$2] = 1; order[++nsel] = $2; next }
  NF < 3 { next }
  $2 == "ran"      { runs[$4]++; if ($3 != "0") printf "FAIL: %s ran on shard%s with rc %s\n", $4, $1, $3; else nran++; next }
  $2 == "unrun"    { printf "FAIL: %s was assigned to shard%s but left unrun\n", $3, $1; next }
  $2 == "skip"     { skipped[$3] = 1; next }
  $2 == "notfound" { missing[$3] = 1; next }
  END {
    for (p in runs) {
      if (runs[p] > 1) printf "FAIL: %s ran %d times across shards\n", p, runs[p]
      if (mode == "impacted" && !(p in sel)) printf "FAIL: %s ran but was not selected\n", p
    }
    if (mode != "impacted") exit
    for (i = 1; i <= nsel; i++) {
      p = order[i]
      if (p in runs) continue
      if (p in skipped)      printf "NOTE: selected %s was skipped by the runner (tier/platform filter)\n", p
      else if (p in missing) printf "NOTE: selected %s was not discovered by the runner\n", p
      else                   printf "FAIL: selected %s never ran on any shard\n", p
    }
  }')
[ -z "$acct" ] || printf '%s\n' "$acct"
grep -q '^FAIL' <<< "$acct" && bad=1

if [ "$bad" -ne 0 ]; then
  echo "shard-manifest-verify: REFUSED — the shards did not run the selection ($mode mode)"
  exit 1
fi
n_sel=$(grep -c '^suite ' "$selection")
echo "OK: $shards shard manifest(s) match the $mode selection at ${want_head#head } ($n_sel selected)"
exit 0
