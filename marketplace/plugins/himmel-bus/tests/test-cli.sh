#!/usr/bin/env bash
# himmel-bus CLI (T10): `bus send` (stamped from process ancestry), `--doc`
# mirror, `bus gc`, `bus status --unacked` with computed expiry.
#
# A bound identity needs a real `claude`-named ancestor, so the driver below runs
# under a symlink to bash called `claude`, points the registered peer at itself,
# and spawns the CLI as its child. State lives in a throwaway XDG_STATE_HOME.
#
# Usage: bash marketplace/plugins/himmel-bus/tests/test-cli.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BUS="$HERE/bin/bus"
INBOX_SEND="$REPO/scripts/handover/console-kit/inbox-send.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }
check() { # check <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bus-cli.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
mkdir -m 700 "$XDG_STATE_HOME"
export HANDOVER_DIR="$tmp/handovers"
mkdir "$HANDOVER_DIR"
ln -s "$(command -v bash)" "$tmp/claude"

# Node helper: lib() runs a snippet against the store with ROOT/NAME bound.
lib() {
  node --input-type=module -e "
    import * as store from '$HERE/lib/store.mjs';
    import * as identity from '$HERE/lib/identity.mjs';
    const root = await store.busRoot();
    $1
  "
}

# Driver: bash running as `claude` (node renames its own comm, bash does not).
# It points <name> at itself, then runs the CLI as its child.
cat > "$tmp/repoint.mjs" <<EOF
import { readFile, writeFile } from 'node:fs/promises';
import * as store from '$HERE/lib/store.mjs';
const [name, pid, start] = process.argv.slice(2);
const file = (await store.busRoot()) + '/peers/' + name + '.json';
const peer = JSON.parse(await readFile(file, 'utf8'));
await writeFile(file, JSON.stringify({ ...peer, pid: Number(pid), start }) + '\n');
EOF
cat > "$tmp/as.sh" <<'EOF'
name="$1"; shift
start=$(cut -d' ' -f22 "/proc/$$/stat")
node "$REPOINT" "$name" "$$" "$start" || exit 1
"$BUS_CLI" "$@"
EOF
as() { REPOINT="$tmp/repoint.mjs" BUS_CLI="$BUS" "$tmp/claude" "$tmp/as.sh" "$@"; }

"$BUS" register con --role console
"$BUS" register legA --role leg --console con
"$BUS" register legB --role leg --console con
"$BUS" register other --role console
"$BUS" register otherLeg --role leg --console other
printf 'rule one\n' > "$tmp/body"

echo "== send: identity and stamping =="
out=$("$BUS" send legA "$tmp/body" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'identity unbound'; then pass "send from an unbound process is refused"; else fail "send from an unbound process (rc=$rc: $out)"; fi
check "unbound send wrote nothing" test ! -e "$XDG_STATE_HOME/himmel/bus/log/legA.jsonl"

out=$(as con send legA "$tmp/body" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "sent #1 to legA" ]; then pass "console sends to its leg"; else fail "console send (rc=$rc: $out)"; fi
rec=$(lib "console.log(JSON.stringify((await store.scan(root, 'legA'))[0]))")
case "$rec" in *'"f":"con"'*'"c":1'*|*'"c":1'*'"f":"con"'*) pass "record is stamped f=con with c=1" ;; *) fail "record stamping: $rec" ;; esac
out=$(as con send otherLeg "$tmp/body" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no edge to otherLeg'; then pass "send to another console's leg is refused"; else fail "edge refusal (rc=$rc: $out)"; fi
out=$(as legA send legB "$tmp/body" 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then pass "leg to sibling is refused"; else fail "leg to sibling allowed: $out"; fi
printf 'x%.0s' $(seq 1 1600) > "$tmp/big"
out=$(as con send legA "$tmp/big" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'needs --summary'; then pass "body over 1500 bytes needs a summary"; else fail "summary rule (rc=$rc: $out)"; fi
out=$(as con send legA "$tmp/big" --summary "big one" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "body over 1500 bytes with --summary is sent"; else fail "summary send (rc=$rc: $out)"; fi

echo "== send: --re acks =="
as legA send con "$tmp/body" --re 1 >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q '"re"' "$XDG_STATE_HOME/himmel/bus/ack/legA.jsonl" 2>/dev/null; then pass "--re writes an ack row under the acker"; else fail "--re ack (rc=$rc)"; fi
out=$(as legA send con "$tmp/body" --re 9 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no message #9'; then pass "--re of an unknown message is refused"; else fail "--re unknown (rc=$rc: $out)"; fi

echo "== send --doc: byte-identical to inbox-send.sh --doc =="
mkdir "$tmp/inbox-ref"
for _ in 1 2 3; do
  printf '# leg doc\n\n## Console Rulings (newest at the bottom)\n- 00:00 old\n\n## Results\n' > "$tmp/doc-bus.md"
  cp "$tmp/doc-bus.md" "$tmp/doc-ref.md"
  printf '%s\0%s\0%s\0' claude -n con > "$tmp/cmdline"
  before=$(date +%H:%M)
  as con send legA "$tmp/body" --doc "$tmp/doc-bus.md" >/dev/null 2>&1; bus_rc=$?
  HANDOVER_DIR="$tmp/inbox-ref" CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$tmp/cmdline" bash "$INBOX_SEND" legA --file "$tmp/body" --doc "$tmp/doc-ref.md" >/dev/null 2>&1
  after=$(date +%H:%M)
  [ "$before" = "$after" ] && break
done
if [ "$bus_rc" -eq 0 ] && cmp -s "$tmp/doc-bus.md" "$tmp/doc-ref.md" && grep -q 'from=con rule one' "$tmp/doc-bus.md"; then pass "--doc mirror is byte-identical to inbox-send.sh --doc"; else fail "--doc mirror differs (rc=$bus_rc)"; diff "$tmp/doc-bus.md" "$tmp/doc-ref.md"; fi
check "--doc leaves no inbox file in the real handover root" test -z "$(ls -A "$HANDOVER_DIR")"
out=$(as con send legA "$tmp/body" --doc "$tmp/no-such-doc.md" 2>&1); rc=$?
n=$(lib "console.log((await store.scan(root, 'legA')).length)")
if [ "$rc" -ne 0 ] && [ "$n" = 3 ]; then pass "a missing --doc refuses before anything is sent"; else fail "missing --doc (rc=$rc, legA log=$n): $out"; fi

echo "== gc =="
# Rotate legB's log into segments 0 and 1 (each record ~1.4 KB).
lib "
  const b = 'y'.repeat(1400);
  for (let i = 0; i < 400; i++) await store.append(root, 'legB', { i: 'r' + i, t: Date.now(), f: 'con', r: 'legB', b, c: 1 });
"
seg0=$(find "$XDG_STATE_HOME/himmel/bus/log" -name 'legB.0.jsonl.*' | head -1)
if [ -n "$seg0" ]; then pass "setup: legB log rotated into a closed segment"; else fail "setup: no closed segment"; fi
touch -d '31 days ago' "$XDG_STATE_HOME"/himmel/bus/log/legB.*.jsonl.*
out=$("$BUS" gc 2>&1)
if [ -e "$seg0" ] && printf '%s' "$out" | grep -q 'kept legB.0 (undelivered)'; then pass "gc keeps an aged segment the cursor has not passed"; else fail "gc undelivered: $out"; fi
# Deliver past segment 0.
lib "const r = await store.read(root, 'legB'); await store.commit(root, 'legB', r.next);"
touch -d '29 days ago' "$seg0"
out=$("$BUS" gc 2>&1)
if [ -e "$seg0" ]; then pass "gc keeps a delivered segment younger than 30 days"; else fail "gc removed a 29-day segment: $out"; fi
touch -d '31 days ago' "$seg0"
out=$("$BUS" gc 2>&1)
if [ -e "$seg0" ] && printf '%s' "$out" | grep -q 'would remove legB.0' && printf '%s' "$out" | grep -q 'HIMMEL-5072'; then pass "gc is report-only: names a delivered 31-day segment and the follow-up, deletes nothing"; else fail "gc delivered: $out"; fi
# Halted logs are kept and reported.
lib "
  for (let i = 0; i < 400; i++) await store.append(root, 'otherLeg', { i: 'h' + i, t: Date.now(), f: 'other', r: 'otherLeg', b: 'z'.repeat(1400) });
"
touch -d '31 days ago' "$XDG_STATE_HOME"/himmel/bus/log/otherLeg.*.jsonl.*
printf '{"k":1,"off":0,"n":99,"h":"%064d","halted":5}\n' 0 > "$XDG_STATE_HOME/himmel/bus/cur/otherLeg"
out=$("$BUS" gc 2>&1)
if printf '%s' "$out" | grep -q 'kept otherLeg.0 (halted)' && ls "$XDG_STATE_HOME"/himmel/bus/log/otherLeg.0.jsonl.* >/dev/null 2>&1; then pass "gc keeps and reports a halted log"; else fail "gc halted: $out"; fi

# KNOWN BREAK (HIMMEL-5072), why gc must not delete yet: store.scan chain-verifies
# from n=0, so a log with a segment removed scans as empty and --re / read #n die.
before=$(lib "console.log((await store.scan(root, 'legB')).length)")
rm -f "$seg0"
after=$(lib "console.log((await store.scan(root, 'legB')).length)")
if [ "$before" -gt 0 ] && [ "$after" = 0 ]; then pass "known break: scan of a log with a removed segment is empty ($before to $after), so gc stays report-only"; else fail "scan break not reproduced (before=$before after=$after)"; fi

echo "== status --unacked =="
lib "
  const t = Date.now();
  const mk = (i, age, extra = {}) => ({ i, t: t - age, f: 'con', r: 'legA', b: 'ruling', ...extra });
  await store.append(root, 'legA', mk('old-unacked', 5 * 3600e3, { c: 1 }));
  await store.append(root, 'legA', mk('old-acked', 5 * 3600e3, { c: 1 }));
  await store.append(root, 'legA', mk('fresh-unacked', 60e3, { c: 1 }));
  await store.append(root, 'legA', mk('old-plain', 5 * 3600e3));
"
printf '{"i":"old-acked","re":"x","t":1}\n' >> "$XDG_STATE_HOME/himmel/bus/ack/legA.jsonl"
out=$(as con status --unacked 2>&1)
# state_of <id>: the last word of the listing line naming <id> (empty if absent).
state_of() { printf '%s\n' "$out" | grep -F "$1" | awk '{print $NF}'; }
[ "$(state_of old-unacked)" = expired ] && ok=1 || ok=0
if [ "$ok" = 1 ]; then pass "an aged unacked ruling prints expired"; else fail "expired: $out"; fi
if [ "$(state_of fresh-unacked)" = unacked ]; then pass "a fresh unacked ruling prints unacked"; else fail "unacked: $out"; fi
if [ -z "$(state_of old-acked)" ]; then pass "--unacked omits an acked ruling"; else fail "--unacked listed an acked ruling: $out"; fi
if [ -z "$(state_of old-plain)" ]; then pass "expiry applies to c=1 rulings only"; else fail "a c=0 record was listed: $out"; fi
out=$(as con status 2>&1)
if [ "$(state_of old-acked)" = acked ]; then pass "status without --unacked lists acked rulings"; else fail "status all: $out"; fi
out=$(as legA status --unacked --for other 2>&1)
if [ -z "$(state_of old-unacked)" ]; then pass "--for <console> filters to that sender"; else fail "--for filtered nothing: $out"; fi
out=$("$BUS" status --unacked 2>&1); rc=$?
if [ "$rc" -ne 0 ]; then pass "status --unacked from an unbound process is refused"; else fail "unbound status listed: $out"; fi
out=$("$BUS" status legA 2>&1)
case "$out" in live|gone) pass "bus status <name> keeps its live/gone meaning" ;; *) fail "status name: $out" ;; esac

[ "$failures" -eq 0 ] || { echo "FAILED: $failures"; exit 1; }
echo "all passed"
