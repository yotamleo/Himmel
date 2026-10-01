#!/usr/bin/env bash
# Tests for followup-report.sh (HIMMEL-4034): per-version follow-up report.
# No network: the jira CLI is a stub (FOLLOWUP_JIRA_CMD), the usage store a fixture.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; RPT="$HERE/followup-report.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/followup-report.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
has() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: missing [$3] in: $2"; fails=$((fails+1)) ;; esac; }

# Stub jira: key, type, status, summary, labels (tab separated), like `jira list --labels`.
cat >"$tmp/jira" <<'EOF'
#!/usr/bin/env bash
printf 'HIMMEL-1\tTask\tDone\tfeature one\t\n'
printf 'HIMMEL-2\tTask\tDone\tfeature two\t\n'
printf 'HIMMEL-3\tTask\tDone\tfeature three\t\n'
printf 'HIMMEL-4\tTask\tDone\tfeature four\t\n'
printf 'HIMMEL-5\tTask\tDone\tfeature five\t\n'
printf 'HIMMEL-6\tTask\tTo Do\tfollow-up: guard gap\tfu-escape\n'
printf 'HIMMEL-7\tTask\tDone\tdeferred: edge case\tfu-hardening\n'
printf 'HIMMEL-8\tTask\tTo Do\tdeferred: rare edge\tfu-hardening,roadmap\n'
printf 'HIMMEL-9\tTask\tTo Do\tresidual: wording\tfu-polish\n'
printf 'HIMMEL-10\tTask\tTo Do\tfollow-up: no class yet\tprocess\n'
printf 'HIMMEL-11\tTask\tDone\tfollow-up: bit us later\tfu-escape,fu-slipped\n'
EOF
chmod +x "$tmp/jira"

mkdir -p "$tmp/store"
printf '%s\n' \
  '{"schema":1,"ticket":"HIMMEL-1","totals":{"leg":{"input":10,"output":20,"cache_create":30,"cache_read":40},"console":{"input":0,"output":0,"cache_create":0,"cache_read":0},"judge":{"input":0,"output":0,"cache_create":0,"cache_read":0}},"cr":{"rounds":2}}' \
  '{"schema":1,"ticket":"HIMMEL-2","totals":{"leg":{"input":1,"output":2,"cache_create":3,"cache_read":4},"console":{"input":0,"output":0,"cache_create":0,"cache_read":0},"judge":{"input":0,"output":0,"cache_create":0,"cache_read":0}},"cr":{"rounds":4}}' \
  '{"schema":1,"ticket":"HIMMEL-99","totals":{"leg":{"input":9,"output":9,"cache_create":9,"cache_read":9},"console":{"input":0,"output":0,"cache_create":0,"cache_read":0},"judge":{"input":0,"output":0,"cache_create":0,"cache_read":0}},"cr":{"rounds":9}}' \
  > "$tmp/store/records.jsonl"

out="$(FOLLOWUP_JIRA_CMD="$tmp/jira" bash "$RPT" --version v9.9.9 --store "$tmp/store" 2>&1)"; rc=$?
check "exits 0" "$rc" "0"
has "escape: 2 created, 1 done" "$out" "escape 2 1"
has "hardening: 2 created, 1 done" "$out" "hardening 2 1"
has "polish: 1 created, 0 done" "$out" "polish 1 0"
has "unclassified follow-up counted" "$out" "unclassified-followups 1"
has "slipped escapes counted" "$out" "slipped-escapes 1"
has "cap: 2 hardening of 5 load = 40 pct, over the 20 pct cap" "$out" "hardening-share 40% cap 20% OVER"
has "claim A joins only this version's tickets, mean rounds 3" "$out" "usage-tickets 2 mean-rounds 3"
has "claim A sums tokens" "$out" "input 11 output 22 cache_create 33 cache_read 44"

# A version with no follow-up labels still reports and does not divide by zero.
printf '#!/usr/bin/env bash\nprintf "HIMMEL-1\\tTask\\tDone\\tfeature\\t\\n"\n' >"$tmp/jira2"; chmod +x "$tmp/jira2"
out2="$(FOLLOWUP_JIRA_CMD="$tmp/jira2" bash "$RPT" --version v1 --store "$tmp/store" 2>&1)"; rc=$?
check "no follow-ups: exits 0" "$rc" "0"
has "no follow-ups: hardening share 0" "$out2" "hardening-share 0% cap 20% ok"

# Hardening with zero base load is OVER, never a vacuous ok (review codex-1).
printf '#!/usr/bin/env bash\nprintf "HIMMEL-7\\tTask\\tDone\\tdeferred: x\\tfu-hardening\\n"\n' >"$tmp/jira4"; chmod +x "$tmp/jira4"
out4="$(FOLLOWUP_JIRA_CMD="$tmp/jira4" bash "$RPT" --version v1 --store "$tmp/store" 2>&1)"
has "zero load with hardening is OVER" "$out4" "OVER"

# A share just above the cap is not hidden by integer truncation (21 of 104 = 20.19 pct vs cap 20; review codex-3).
{ echo '#!/usr/bin/env bash'; for i in $(seq 1 104); do printf 'printf "HIMMEL-%s\\tTask\\tDone\\tfeat\\t\\n"\n' "$i"; done
  for i in $(seq 100 120); do printf 'printf "HIMMEL-%s\\tTask\\tDone\\tdeferred: h\\tfu-hardening\\n"\n' "$i"; done; } >"$tmp/jira5"; chmod +x "$tmp/jira5"
out5="$(FOLLOWUP_JIRA_CMD="$tmp/jira5" bash "$RPT" --version v1 --store "$tmp/store" 2>&1)"
has "21 hardening of 104 load (20.19 pct) is over a 20 pct cap" "$out5" "OVER"

# Missing store: claim A is reported unavailable, class counts still print.
out3="$(FOLLOWUP_JIRA_CMD="$tmp/jira" bash "$RPT" --version v9.9.9 --store "$tmp/none" 2>&1)"; rc=$?
check "missing store: exits 0" "$rc" "0"
has "missing store: claim A unavailable" "$out3" "claim-A unavailable"
has "missing store: counts still print" "$out3" "escape 2 1"

# A failing jira call is an error, never an empty report.
printf '#!/usr/bin/env bash\nexit 7\n' >"$tmp/jira3"; chmod +x "$tmp/jira3"
FOLLOWUP_JIRA_CMD="$tmp/jira3" bash "$RPT" --version v1 --store "$tmp/store" >/dev/null 2>&1; rc=$?
check "jira failure exits 2" "$rc" "2"
bash "$RPT" --store "$tmp/store" >/dev/null 2>&1; rc=$?
check "missing --version exits 1" "$rc" "1"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"
exit 1
