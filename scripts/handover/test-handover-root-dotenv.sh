#!/usr/bin/env bash
# HIMMEL-4420: every handover_root caller must feed it the .env HANDOVER_DIR
# first. handover_root reads only the live env, so a caller that skips
# load_dotenv resolves the <repo>/handovers stub (or fails closed) when .env is
# the only source. Each probe runs the script from a non-git cwd with
# HANDOVER_DIR unset and the .env in a fixture HIMMELCTL_CACHE_DIR (the loader
# reads it first, so the operator's real .env is never touched).
# shellcheck disable=SC2015
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$HERE/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/handover-root-dotenv.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
# has <label> <haystack> <needle> / lacks
has()   { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] lacks [$3]"; fails=$((fails+1)) ;; esac; }
lacks() { case "$2" in *"$3"*) echo "FAIL - $1: [$2] has [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

HO="$tmp/ho"; mkdir -p "$tmp/cache" "$HO" "$tmp/work"
printf 'HANDOVER_DIR=%s\n' "$HO" > "$tmp/cache/.env"
cd "$tmp/work" || exit 1
# probe <cmd...>: stdout+stderr, HANDOVER_DIR unset, .env only in the cache dir.
# A probe that cannot run at all (rc 126/127) would pass every "lacks" check, so
# it is logged to $tmp/unrunnable and fails the suite at the end.
probe() {
    local o rc
    o="$(env -u HANDOVER_DIR HIMMELCTL_CACHE_DIR="$tmp/cache" "$@" 2>&1 </dev/null)"; rc=$?
    case "$rc" in 126|127) echo "rc=$rc: $*" >> "$tmp/unrunnable" ;; esac
    printf '%s' "$o"
}

out="$(probe bash "$SCRIPTS/handover-link.sh")"
has "handover-link: resolves the .env root" "$out" "root:       $HO"

out="$(probe bash "$SCRIPTS/handover/bugs-dashboard.sh")"
lacks "bugs-dashboard: root resolved from .env" "$out" "root unresolved"

out="$(probe bash "$SCRIPTS/handover/lessons-sweep.sh")"
lacks "lessons-sweep: root resolved from .env" "$out" "root unresolved"

out="$(probe bash "$SCRIPTS/handover/resolve-active-item.sh")"
lacks "resolve-active-item: root resolved from .env" "$out" "root unresolved"

out="$(probe bash "$SCRIPTS/handover/queue-lock.sh" status "$tmp/x.md")"
lacks "queue-lock: root resolved from .env" "$out" "could not resolve handover root"

out="$(probe bash "$SCRIPTS/handover/flush.sh")"
lacks "flush: Mode B taken from .env" "$out" "Mode A (inline) not supported"

out="$(probe bash "$SCRIPTS/handover/resume.sh" --list)"
lacks "resume: root resolved from .env" "$out" "handover root unresolved"

out="$(probe bash -c ". '$SCRIPTS/lanes/lib/leg-cost-row.sh'; leg_cost_ledger_path")"
check "leg-cost-row: ledger under the .env root" "$out" "$HO/.ledger/leg-cost.jsonl"

printf 'doc\n' > "$tmp/doc.md"
out="$(probe bash "$SCRIPTS/lanes/bench/scorecard/ready-go-latency.sh" --doc "$tmp/doc.md")"
lacks "ready-go-latency: root resolved from .env" "$out" "cannot resolve the handover root"

out="$(probe bash "$SCRIPTS/handover/console-kit/inbox-send.sh" --pending)"
lacks "inbox-send: root resolved from .env" "$out" "cannot resolve handover root"

out="$(probe bash "$SCRIPTS/telegram/auto-action.sh" arm-resume HIMMEL-1 12:00)"
lacks "auto-action: root resolved from .env" "$out" "handover_root unresolved"

probe bash "$SCRIPTS/handover/breadcrumb.sh" write --ticket HIMMEL-1 >/dev/null
check "breadcrumb: write lands under the .env root" "$([ -f "$HO/breadcrumbs/HIMMEL-1.json" ] && echo yes || echo no)" "yes"

printf 'https://claude.ai/artifact/abc\n' > "$tmp/art.md"
probe bash "$SCRIPTS/handover/artifact-sync.sh" record "https://claude.ai/artifact/abc" "$tmp/art.md" >/dev/null
check "artifact-sync: registry under the .env root" "$([ -f "$HO/.artifacts/registry.jsonl" ] && echo yes || echo no)" "yes"

out="$(printf 'HIMMEL-1\tfeat/x\t1\tdone\tok\n' | env -u HANDOVER_DIR HIMMELCTL_CACHE_DIR="$tmp/cache" bash "$SCRIPTS/overnight/morning-report.sh" --dry-run 2>&1)"
has "morning-report: output path under the .env root" "$out" "$HO/overnight-report-"

mkdir -p "$HO/breadcrumbs"; printf '{}\n' > "$HO/breadcrumbs/HIMMEL-1.json"
out="$(probe bash "$SCRIPTS/where-are-we/statusline-segment.sh" --branch feat/himmel-1-x --cwd "$tmp/work")"
has "statusline-segment: breadcrumb marker found via the .env root" "$out" "📋"

# Callers whose root use is not observable from outside (the fence and the gate
# swallow the resolver; the smoke is opt-in and spends bank): assert the loader
# runs before the first handover_root call.
for f in hermes/egress-gate.sh guardrails/graphify-fence.sh handover/console-kit/smoke-consult-sandbox.sh; do
    ld="$(grep -n 'load_dotenv HANDOVER_DIR' "$SCRIPTS/$f" | head -1 | cut -d: -f1)"
    hr="$(grep -nE '(^|[^_a-z])handover_root( |\)|"|$)' "$SCRIPTS/$f" | grep -v '^[0-9]*:[[:space:]]*#' | head -1 | cut -d: -f1)"
    check "$f: load_dotenv precedes handover_root" "$([ -n "$ld" ] && [ -n "$hr" ] && [ "$ld" -lt "$hr" ] && echo yes || echo "no (ld=$ld hr=$hr)")" "yes"
done

# A live value still wins over .env (load_dotenv fills only an absent key).
other="$tmp/other"; mkdir -p "$other"
out="$(env HANDOVER_DIR="$other" HIMMELCTL_CACHE_DIR="$tmp/cache" bash "$SCRIPTS/handover-link.sh" 2>&1 </dev/null)"
has "handover-link: a live HANDOVER_DIR wins over .env" "$out" "root:       $other"

[ -s "$tmp/unrunnable" ] && { echo "FAIL - unrunnable probe(s):"; cat "$tmp/unrunnable"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
