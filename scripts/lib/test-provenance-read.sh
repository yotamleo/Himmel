#!/usr/bin/env bash
# Platform guard (gitbash-only): bash + jq only.
# test-provenance-read.sh -- tests for scripts/lib/provenance-read.sh (HIMMEL-3332 S6).
# Everything runs under a scratch HOME / HIMMEL_PROVENANCE_DIR; the real
# ~/.himmel is never read or written, and uninstall.sh is never run.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
passes=0
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }  # gnu-ok: BSD stat -f paired

td=$(mktemp -d "${TMPDIR:-/tmp}/prov-read-test.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap '[ -n "${td:-}" ] && [ -d "$td" ] && rm -rf "$td"' EXIT
export HOME="$td/home"
mkdir -p "$HOME"
export HIMMEL_PROVENANCE_DIR="$td/prov"
export HIMMEL_PROVENANCE_NOW=2026-09-21T00:00:00Z
unset HIMMEL_PROVENANCE_IID DRY_RUN CLAUDE_CONFIG_DIR
w="$td/cwd"
mkdir -p "$w"
cd "$w" || exit 1

# shellcheck source=scripts/lib/provenance.sh
. "$here/provenance.sh"
# shellcheck source=scripts/lib/provenance-read.sh
. "$here/provenance-read.sh"

ledger="$HIMMEL_PROVENANCE_DIR/provenance.jsonl"
reset() { unset HIMMEL_PROVENANCE_IID _PROV_OWNS; rm -rf "$HIMMEL_PROVENANCE_DIR"; }
u_for() { # --path P [--kind K] [--row R] -- prints the first matching fold unit
    prov_read_units "$@" | head -n1
}
field() { printf '%s' "$1" | jq -r "$2"; } # unit-json jq-expr

# ── load: missing / symlink / bad rows / not-install-begin / foreign / partial ──

reset
prov_read_load
check "missing ledger -> state" "$PROV_READ_STATE" "missing"
check "missing ledger -> rows" "$PROV_READ_ROWS" "0"
prov_read_cleanup

reset
mkdir -p "$HIMMEL_PROVENANCE_DIR"
printf 'keep\n' > "$w/victim.jsonl"
ln -s "$w/victim.jsonl" "$ledger"
prov_read_load
check "symlinked ledger -> unparsable" "$PROV_READ_STATE" "unparsable"
prov_read_cleanup

reset
prov_begin --iid S1 --writer t
{
    printf 'not json at all\n'
    printf '{}\n'          # object with no "op" -- still bad
    printf '{"op":5}\n'    # op not a string -- still bad
} >> "$ledger"
prov_end ok
prov_read_load
check "garbage lines: state stays ok" "$PROV_READ_STATE" "ok"
check "garbage lines: counted as bad" "$PROV_READ_BAD_ROWS" "3"
check "garbage lines: valid rows unaffected" "$PROV_READ_ROWS" "2"
prov_read_cleanup

reset
mkdir -p "$HIMMEL_PROVENANCE_DIR"
{
    printf '%s\n' '{"t":"2026-09-21T00:00:00Z","iid":"X1","op":"create","kind":"file","path":"/x"}'
} > "$ledger"
prov_read_load
check "first row not install-begin -> unparsable" "$PROV_READ_STATE" "unparsable"
prov_read_cleanup

reset
mkdir -p "$HIMMEL_PROVENANCE_DIR"
{
    printf '%s\n' '{"t":"2026-09-21T00:00:00Z","iid":"F1","op":"install-begin","home":"/some/other/home"}'
    printf '%s\n' '{"t":"2026-09-21T00:00:00Z","iid":"F1","op":"install-end","status":"ok","failed_step":null}'
} > "$ledger"
prov_read_load
check "foreign home -> state" "$PROV_READ_STATE" "foreign"
check "foreign home names both homes" "$(printf '%s' "$PROV_READ_REASON" | grep -c "/some/other/home")" "1"
prov_read_cleanup

reset
prov_begin --iid P1 --writer t
prov_record create file "$w/p.txt" --post-file "$here/provenance.sh"
# no prov_end -- the session is left open
prov_read_load
check "partial: state stays ok" "$PROV_READ_STATE" "ok"
check "partial: flag set" "$PROV_READ_PARTIAL" "1"
prov_read_cleanup
unset HIMMEL_PROVENANCE_IID _PROV_OWNS

# ── fold: create->replace chain, noop never changes the fold ────────────────

reset
prov_begin --iid C1 --writer t
printf 'v1\n' > "$w/f.txt"
prov_record create file "$w/f.txt" --pre-absent --post-file "$w/f.txt" --scope user --class code
snap1=$(mktemp "$td/snap1.XXXXXX") || exit 1; cp "$w/f.txt" "$snap1"
printf 'v2\n' > "$w/f.txt"
prov_record replace file "$w/f.txt" --pre-file "$snap1" --backup --post-file "$w/f.txt" --scope user --class code
prov_record noop file "$w/f.txt" --scope user --class code   # must not change the fold
prov_end ok
prov_read_load
u=$(u_for --path "$w/f.txt")
check "chain: governed" "$(field "$u" .governed)" "true"
check "chain: eff_pre is absent (the create's pre, since presha(replace)==create's post.sha)" "$(field "$u" '.eff_pre.state')" "absent"
check "chain: eff_post is the replace's post" "$(field "$u" '.eff_post.sha')" "$(prov_sha_file "$w/f.txt")"
check "chain: ops includes noop but does not reorder eff_pre/post" "$(field "$u" '.ops|join(",")')" "create,replace,noop"
prov_read_cleanup
rm -f "$snap1"

# ── replace with backup: restore verdict + apply restores bytes, mode & sha ──

reset
prov_begin --iid R1 --writer t
printf 'orig\n' > "$w/r.txt"; chmod 640 "$w/r.txt"
snap2=$(mktemp "$td/snap2.XXXXXX") || exit 1; cp -p "$w/r.txt" "$snap2"
printf 'newer\n' > "$w/r.txt"; chmod 644 "$w/r.txt"
prov_record replace file "$w/r.txt" --pre-file "$snap2" --backup --post-file "$w/r.txt" --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/r.txt")
check "replace+backup: verdict" "$(prov_read_verdict "$u")" "restore ours"
prov_read_apply "$u" restore
check "restore: bytes back to pre" "$(cat "$w/r.txt")" "orig"
check "restore: mode back to pre (0640)" "$(fmode "$w/r.txt")" "640"
check "restore: sha verified" "$(prov_sha_file "$w/r.txt")" "$(field "$u" '.eff_pre.sha')"
prov_read_cleanup
rm -f "$snap2"

# ── user-modified / already-absent ───────────────────────────────────────────

reset
prov_begin --iid M1 --writer t
printf 'installed\n' > "$w/m.txt"
prov_record create file "$w/m.txt" --pre-absent --post-file "$w/m.txt" --scope user --class code
prov_end ok
printf 'user changed this\n' > "$w/m.txt"
prov_read_load
u=$(u_for --path "$w/m.txt")
check "user-modified verdict" "$(prov_read_verdict "$u")" "keep user-modified"
prov_read_cleanup

reset
prov_begin --iid A1 --writer t
printf 'gone\n' > "$w/abs.txt"
prov_record create file "$w/abs.txt" --pre-absent --post-file "$w/abs.txt" --scope user --class code
prov_end ok
rm -f "$w/abs.txt"
prov_read_load
u=$(u_for --path "$w/abs.txt")
check "already-absent verdict" "$(prov_read_verdict "$u")" "keep already-absent"
prov_read_cleanup

# ── ungoverned: noop-only(preexisted) keep, noop-only(no flag) heuristic ────

reset
prov_begin --iid N1 --writer t
prov_record noop file "$w/pre.txt" --field preexisted=true --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/pre.txt")
check "noop-only + preexisted: ungoverned" "$(field "$u" .governed)" "false"
check "noop-only + preexisted: verdict" "$(prov_read_verdict "$u")" "keep noop-preexisted"
prov_read_cleanup

reset
prov_begin --iid N2 --writer t
prov_record noop file "$w/nopre.txt" --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/nopre.txt")
check "noop-only, no preexisted flag: verdict" "$(prov_read_verdict "$u")" "heuristic heuristic"
prov_read_cleanup

# ── HIMMEL-3363: create then later noop(preexisted=true) -- still ours ─────

reset
prov_begin --iid H1 --writer t
printf 'x\n' > "$w/h.txt"
prov_record create file "$w/h.txt" --pre-absent --post-file "$w/h.txt" --scope user --class code
prov_record noop file "$w/h.txt" --field preexisted=true --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/h.txt")
check "HIMMEL-3363: still governed by the create" "$(field "$u" .governed)" "true"
check "HIMMEL-3363: verdict is remove ours, not kept" "$(prov_read_verdict "$u")" "remove ours"
prov_read_cleanup

# ── HIMMEL-3363: re-adopt -- the second install's noop(preexisted=true) json-key
#    row (adopt.sh wire_handover_dir_luna) must not override the first install's create ──

reset
HS="$w/hsettings.json"
printf '{}\n' > "$HS"
prov_begin --iid RA1 --writer adopt.sh
prov_record create json-key "$HS" --unit /env/HANDOVER_DIR --pre-absent --post-json '"/h/one"' --scope user --class code --row user-settings
prov_end ok
printf '%s' '{"env":{"HANDOVER_DIR":"/h/one"}}' > "$HS"
prov_begin --iid RA2 --writer adopt.sh
prov_record noop json-key "$HS" --unit /env/HANDOVER_DIR --pre-json '"/h/one"' --post-json '"/h/one"' --field preexisted=true --scope user --class code --row user-settings
prov_end ok
prov_read_load
u=$(u_for --path "$HS")
check "HIMMEL-3363 re-adopt json-key: one unit" "$(prov_read_units --path "$HS" | wc -l | tr -d ' ')" "1"
check "HIMMEL-3363 re-adopt json-key: governed by the first install's create" "$(field "$u" .governed)" "true"
check "HIMMEL-3363 re-adopt json-key: not noop-preexisted-only" "$(field "$u" .preexisted_only)" "false"
check "HIMMEL-3363 re-adopt json-key: verdict is remove ours" "$(prov_read_verdict "$u")" "remove ours"
prov_read_cleanup

# control: a lone noop(preexisted=true) json-key row (the operator chose the value) stays kept

reset
printf '%s' '{"env":{"HANDOVER_DIR":"/h/op"}}' > "$HS"
prov_begin --iid RC1 --writer adopt.sh
prov_record noop json-key "$HS" --unit /env/HANDOVER_DIR --pre-json '"/h/op"' --post-json '"/h/op"' --field preexisted=true --scope user --class code --row user-settings
prov_end ok
prov_read_load
u=$(u_for --path "$HS")
check "HIMMEL-3363 control: lone noop json-key is ungoverned" "$(field "$u" .governed)" "false"
check "HIMMEL-3363 control: lone noop json-key verdict is keep noop-preexisted" "$(prov_read_verdict "$u")" "keep noop-preexisted"
prov_read_cleanup

# ── json-key remove with ~1 escaping ────────────────────────────────────────

reset
S1="$w/settings1.json"
printf '{}\n' > "$S1"
prov_begin --iid K1 --writer t
prov_record create json-key "$S1" --unit '/env/a~1b' --pre-absent --post-json '"v"' --scope user --class code
prov_end ok
printf '%s' '{"env":{"a/b":"v"}}' > "$S1"
prov_read_load
u=$(u_for --path "$S1")
check "json-key ~1 escaping: unit stored verbatim" "$(field "$u" .unit)" "/env/a~1b"
check "json-key ~1 escaping: current finds the literal-slash key" "$(prov_read_current "$u")" "$(prov_sha_json '"v"')"
prov_read_apply "$u" remove
check "json-key ~1 escaping: key removed" "$(jq -c . "$S1")" '{"env":{}}'
prov_read_cleanup

# ── json-elem insert/remove + container_created deletes the empty container ─

reset
S2="$w/settings2.json"
printf '{}\n' > "$S2"
elem='{"cmd":"a"}'
esha=$(prov_sha_json "$elem")
prov_begin --iid E1 --writer t
prov_record insert json-elem "$S2" --unit /hooks/PreToolUse --pre-absent --post-json "$elem" \
    --field container_created=true --field elem_sha="\"$esha\"" --scope user --class code
prov_end ok
printf '%s' '{"hooks":{"PreToolUse":[{"cmd":"a"}]}}' > "$S2"
prov_read_load
u=$(u_for --path "$S2")
check "json-elem insert: governed" "$(field "$u" .governed)" "true"
check "json-elem insert: current == elem sha" "$(prov_read_current "$u")" "$esha"
check "json-elem insert: verdict" "$(prov_read_verdict "$u")" "remove ours"
prov_read_apply "$u" remove
check "json-elem remove + container_created: container key gone" "$(jq -c . "$S2")" '{"hooks":{}}'
prov_read_cleanup

# ── json-elem replace chain: pre.sha links to the previous post ────────────

reset
S3="$w/settings3.json"
printf '{}\n' > "$S3"
elemA='{"cmd":"a"}'; shaA=$(prov_sha_json "$elemA")
elemB='{"cmd":"b"}'; shaB=$(prov_sha_json "$elemB")
prov_begin --iid J1 --writer t
prov_record insert json-elem "$S3" --unit /hooks/PreToolUse --pre-absent --post-json "$elemA" \
    --field container_created=true --field elem_sha="\"$shaA\"" --scope user --class code
prov_record replace json-elem "$S3" --unit /hooks/PreToolUse --pre-json "$elemA" --backup --post-json "$elemB" \
    --field elem_sha="\"$shaB\"" --scope user --class code
prov_end ok
printf '%s' '{"hooks":{"PreToolUse":[{"cmd":"b"}]}}' > "$S3"
prov_read_load
u=$(u_for --path "$S3")
check "json-elem replace chain: one unit (chain merged)" "$(prov_read_units --path "$S3" | wc -l | tr -d ' ')" "1"
check "json-elem replace chain: eff_pre is the insert's absent pre" "$(field "$u" '.eff_pre.state')" "absent"
check "json-elem replace chain: eff_post is the replace's post" "$(field "$u" '.eff_post.sha')" "$shaB"
check "json-elem replace chain: verdict (eff_pre absent -> ours)" "$(prov_read_verdict "$u")" "remove ours"
prov_read_cleanup

# ── json-elem nested (SessionStart-shaped): the tracked element lives one
# level under a stanza's .hooks[], not at the top level of the unit's own
# array -- e.g. wire-pretooluse-hooks.sh's --sessionstart writer records
# elem_sha of the hook OBJECT while --unit /hooks/SessionStart points at the
# stanza ARRAY. HIMMEL-3332 S6: prov_read_current/apply used to scan ONLY the
# top-level array, so a nested element always read ABSENT, its unit always
# verdicted `keep already-absent`, and uninstall.sh's per-unit loop then
# wrongly PROTECTED it (and, coarse-masked, skipped the whole hooks helper
# too) -- caught live by test-e2e-symmetry.sh's SessionStart round trip.

reset
S4="$w/settings4.json"
printf '{}\n' > "$S4"
ssobj='{"type":"command","command":"bash x/inject-initiative.sh"}'
sssha=$(prov_sha_json "$ssobj")
prov_begin --iid K1 --writer t
prov_record insert json-elem "$S4" --unit /hooks/SessionStart --pre-absent --post-json "$ssobj" \
    --field container_created=true --field elem_sha="\"$sssha\"" --scope user --class code
prov_end ok
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash x/inject-initiative.sh"}]}]}}' > "$S4"
prov_read_load
u=$(u_for --path "$S4")
check "json-elem nested: current finds the nested hook object" "$(prov_read_current "$u")" "$sssha"
check "json-elem nested: verdict" "$(prov_read_verdict "$u")" "remove ours"
prov_read_apply "$u" remove
check "json-elem nested: removed + empty wrapper stanza pruned" "$(jq -c . "$S4")" '{"hooks":{"SessionStart":[]}}'
prov_read_cleanup

# ── register: plugin ours vs preexisted, and prov_read_owned's TSV ─────────

reset
prov_begin --iid G1 --writer t
prov_record register plugin - --unit himmel-ops@himmel --scope user --class state \
    --field preexisted=false --field cli_scope='"user"' --post-json '{"v":1}'
prov_record register plugin - --unit someone-elses@shop --scope user --class state \
    --field preexisted=true --field cli_scope='"user"' --post-json '{"v":1}'
prov_record register marketplace - --unit himmel --scope user --class state \
    --field preexisted=false --field cli_scope='"user"' --post-json '{"v":1}'
prov_end ok
prov_read_load
uours=$(prov_read_units --kind plugin | jq -c 'select(.unit=="himmel-ops@himmel")')
upre=$(prov_read_units --kind plugin | jq -c 'select(.unit=="someone-elses@shop")')
check "register plugin ours" "$(field "$uours" .ours)" "true"
check "register plugin ours -> verdict" "$(prov_read_verdict "$uours")" "remove ours"
check "register plugin preexisted" "$(field "$upre" .ours)" "false"
check "register plugin preexisted -> verdict" "$(prov_read_verdict "$upre")" "keep preexisted"
ownedfile="$td/owned.tsv"
prov_read_owned "$ownedfile"
check "prov_read_owned: plugin row" "$(grep -c "$(printf 'plugin\thimmel-ops@himmel\tuser')" "$ownedfile")" "1"
check "prov_read_owned: marketplace row" "$(grep -c "$(printf 'marketplace\thimmel\tuser')" "$ownedfile")" "1"
check "prov_read_owned: preexisted plugin excluded" "$(grep -c 'someone-elses@shop' "$ownedfile")" "0"
prov_read_cleanup

# ── kind tool -> class-keep; class state -> skip ───────────────────────────

reset
prov_begin --iid T1 --writer t
prov_record register tool - --unit some-tool --scope user --class state --post-json '{"v":1}'
prov_end ok
prov_read_load
u=$(u_for --kind tool)
check "kind tool -> class-keep" "$(prov_read_verdict "$u")" "keep class-keep"
prov_read_cleanup

reset
prov_begin --iid CS1 --writer t
prov_record replace tree "$w/cache-dir" --scope user --class state --row hud-config \
    --pre-json '{"a":1}' --post-json '{"a":2}'
prov_end ok
prov_read_load
u=$(u_for --kind tree)
check "class state -> skip" "$(prov_read_verdict "$u")" "skip class-state"
prov_read_cleanup

# ── dry-run apply changes nothing ───────────────────────────────────────────

reset
prov_begin --iid D1 --writer t
printf 'x\n' > "$w/dry.txt"
prov_record create file "$w/dry.txt" --pre-absent --post-file "$w/dry.txt" --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/dry.txt")
before=$(prov_sha_file "$w/dry.txt")
out=$(prov_read_apply "$u" remove --dry-run)
check "dry-run apply: prints DRY" "$(printf '%s' "$out" | grep -c '^DRY: would remove')" "1"
check "dry-run apply: file untouched" "$([ -f "$w/dry.txt" ] && prov_sha_file "$w/dry.txt")" "$before"
prov_read_cleanup

# ── session rows: only when ok, never create a missing ledger ──────────────

reset
prov_read_load
check "session on a missing ledger: state" "$PROV_READ_STATE" "missing"
prov_read_session_begin wet --dry-run
check "session on a missing ledger: no ledger dir created" "$([ -e "$HIMMEL_PROVENANCE_DIR" ] && echo yes || echo no)" "no"
prov_read_cleanup

reset
prov_begin --iid SB1 --writer t
printf 'x\n' > "$w/s.txt"
prov_record create file "$w/s.txt" --pre-absent --post-file "$w/s.txt" --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/s.txt")
prov_read_session_begin wet --dry-run
check "session begin (wet): writes uninstall-begin" "$(tail -n1 "$ledger" | jq -r .op)" "uninstall-begin"
check "session begin (wet): mode recorded" "$(tail -n1 "$ledger" | jq -r .mode)" "wet"
prov_read_outcome removed "$u" ours
check "outcome row: op" "$(tail -n1 "$ledger" | jq -r .op)" "removed"
check "outcome row: reason" "$(tail -n1 "$ledger" | jq -r .reason)" "ours"
check "outcome row: ref points at the install row" "$(tail -n1 "$ledger" | jq -r .ref)" "SB1:2"
prov_read_session_end ok
check "session end: op" "$(tail -n1 "$ledger" | jq -r .op)" "uninstall-end"
check "session end: removed count" "$(tail -n1 "$ledger" | jq -r .removed)" "1"
prov_read_cleanup

# dry-mode session: no writes, counters still tracked
reset
prov_begin --iid SD1 --writer t
printf 'x\n' > "$w/sd.txt"
prov_record create file "$w/sd.txt" --pre-absent --post-file "$w/sd.txt" --scope user --class code
prov_end ok
n0=$(wc -l < "$ledger" | tr -d ' ')
prov_read_load
u=$(u_for --path "$w/sd.txt")
prov_read_session_begin dry
prov_read_outcome removed "$u" ours
prov_read_session_end ok
check "dry session: no rows appended" "$(wc -l < "$ledger" | tr -d ' ')" "$n0"
check "dry session: counter still incremented" "$PROV_READ_N_REMOVED" "1"
prov_read_cleanup

# ── prune_backups keeps a backup named by a failed outcome row ─────────────

reset
prov_begin --iid PB1 --writer t
printf 'one\n' > "$w/b1.txt"
snap3=$(mktemp "$td/snap3.XXXXXX") || exit 1; cp "$w/b1.txt" "$snap3"
printf 'one-new\n' > "$w/b1.txt"
prov_record replace file "$w/b1.txt" --pre-file "$snap3" --backup --post-file "$w/b1.txt" --scope user --class code
printf 'two\n' > "$w/b2.txt"
snap4=$(mktemp "$td/snap4.XXXXXX") || exit 1; cp "$w/b2.txt" "$snap4"
printf 'two-new\n' > "$w/b2.txt"
prov_record replace file "$w/b2.txt" --pre-file "$snap4" --backup --post-file "$w/b2.txt" --scope user --class code
prov_end ok
prov_read_load
u1=$(u_for --path "$w/b1.txt")
u2=$(u_for --path "$w/b2.txt")
bk1=$(field "$u1" '.eff_pre.backup')
bk2=$(field "$u2" '.eff_pre.backup')
prov_read_session_begin wet
prov_read_outcome failed "$u1" step-failed "$bk1"
prov_read_outcome restored "$u2" ours "$bk2"
prov_read_session_end ok
prov_read_prune_backups
check "prune_backups: failed unit's backup kept" "$([ -f "$bk1" ] && echo yes || echo no)" "yes"
check "prune_backups: restored (clean) unit's backup removed" "$([ -f "$bk2" ] && echo yes || echo no)" "no"
prov_read_cleanup
rm -f "$snap3" "$snap4"

# ── codex-7: prune_backups deletes ONLY removed/restored-referenced backups.
#    A kept-outcome unit's backup and a backup no outcome row this session
#    named at all (a leftover another run still needs) both survive; a
#    restored-outcome unit's backup is gone. ───────────────────────────────

reset
prov_begin --iid PB2 --writer t
printf 'k1\n' > "$w/k1.txt"
snap5=$(mktemp "$td/snap5.XXXXXX") || exit 1; cp "$w/k1.txt" "$snap5"
printf 'k1-new\n' > "$w/k1.txt"
prov_record replace file "$w/k1.txt" --pre-file "$snap5" --backup --post-file "$w/k1.txt" --scope user --class code
prov_end ok
prov_read_load
uk1=$(u_for --path "$w/k1.txt")
bkk1=$(field "$uk1" '.eff_pre.backup')
unrefbk="$(prov_dir)/provenance-backups/orphan.bak"
printf 'leftover\n' > "$unrefbk"
prov_read_session_begin wet
prov_read_outcome kept "$uk1" user-modified
prov_read_session_end ok
prov_read_prune_backups
check "codex-7: kept-outcome unit's backup survives prune" "$([ -f "$bkk1" ] && echo yes || echo no)" "yes"
check "codex-7: an unreferenced backup also survives prune" "$([ -f "$unrefbk" ] && echo yes || echo no)" "yes"
prov_read_cleanup
rm -f "$snap5"

reset
prov_begin --iid PB3 --writer t
printf 'r1\n' > "$w/r1.txt"
snap6=$(mktemp "$td/snap6.XXXXXX") || exit 1; cp "$w/r1.txt" "$snap6"
printf 'r1-new\n' > "$w/r1.txt"
prov_record replace file "$w/r1.txt" --pre-file "$snap6" --backup --post-file "$w/r1.txt" --scope user --class code
prov_end ok
prov_read_load
ur1=$(u_for --path "$w/r1.txt")
bkr1=$(field "$ur1" '.eff_pre.backup')
prov_read_session_begin wet
prov_read_outcome restored "$ur1" ours "$bkr1"
prov_read_session_end ok
prov_read_prune_backups
check "codex-7: restored-outcome unit's backup is deleted" "$([ -f "$bkr1" ] && echo yes || echo no)" "no"
prov_read_cleanup
rm -f "$snap6"

# ── codex-3: a failed upstream jq must not truncate the JSON target. A
#    json-key restore whose backup holds invalid JSON makes the
#    `jq --argjson v "$val" ...` pipeline stage fail before it ever writes to
#    stdout; _provread_atomic_write must refuse the resulting empty stdin
#    rather than mv it over the real file. ──────────────────────────────────

reset
S6="$w/settings6.json"
printf '{"env":{"K":"orig"}}\n' > "$S6"
prov_begin --iid JK1 --writer t
prov_record replace json-key "$S6" --unit /env/K --pre-json '"orig"' --backup --post-json '"new"' --scope user --class code
prov_end ok
printf '%s' '{"env":{"K":"new"}}' > "$S6"
prov_read_load
u=$(u_for --path "$S6")
bk=$(field "$u" '.eff_pre.backup')
printf 'not valid json{{{' > "$bk"
BEFORE6=$(cat "$S6")
prov_read_apply "$u" restore
rc6=$?
check "codex-3: restore with invalid-json backup returns non-zero" "$rc6" "1"
check "codex-3: target settings file byte-identical after the refused restore" "$(cat "$S6")" "$BEFORE6"
prov_read_cleanup

# ── R2-codex3: a backup whose BYTES were altered (not deleted, not invalid)
#    must be caught by an eff_pre.sha comparison before it replaces the
#    target -- a corrupted-but-readable backup must never overwrite a
#    working file. Two halves: kind=file (sha checked before the mv) and
#    kind=json-key (sha checked before the setpath splice). ─────────────────

reset
prov_begin --iid FR1 --writer t
printf 'orig\n' > "$w/fr.txt"; chmod 640 "$w/fr.txt"
snap7=$(mktemp "$td/snap7.XXXXXX") || exit 1; cp -p "$w/fr.txt" "$snap7"
printf 'newer\n' > "$w/fr.txt"; chmod 644 "$w/fr.txt"
prov_record replace file "$w/fr.txt" --pre-file "$snap7" --backup --post-file "$w/fr.txt" --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/fr.txt")
bkfr=$(field "$u" '.eff_pre.backup')
printf 'tampered\n' > "$bkfr"   # still a readable file, wrong bytes/sha
BEFORE_FR=$(cat "$w/fr.txt")
prov_read_apply "$u" restore
rcfr=$?
check "R2-codex3: file restore with corrupted (bytes-altered) backup returns non-zero" "$rcfr" "1"
check "R2-codex3: file target untouched (not overwritten by the corrupted backup)" "$(cat "$w/fr.txt")" "$BEFORE_FR"
prov_read_cleanup
rm -f "$snap7"

reset
S8="$w/settings8.json"
printf '{"env":{"K":"orig"}}\n' > "$S8"
prov_begin --iid JK2 --writer t
prov_record replace json-key "$S8" --unit /env/K --pre-json '"orig"' --backup --post-json '"new"' --scope user --class code
prov_end ok
printf '%s' '{"env":{"K":"new"}}' > "$S8"
prov_read_load
u=$(u_for --path "$S8")
bkjk=$(field "$u" '.eff_pre.backup')
printf '%s' '"tampered"' > "$bkjk"   # valid JSON, but not the recorded pre-value
BEFORE_JK=$(cat "$S8")
prov_read_apply "$u" restore
rcjk=$?
check "R2-codex3: json-key restore with corrupted (wrong-value) backup returns non-zero" "$rcjk" "1"
check "R2-codex3: json-key target byte-identical after the refused restore" "$(cat "$S8")" "$BEFORE_JK"
prov_read_cleanup

# ── HIMMEL-3386 (1): the json-elem restore hashes the backup against
#    eff_pre.sha (prov_sha_json, the writer's element hasher) BEFORE the splice,
#    exactly like the file and json-key halves above. A valid-JSON backup with
#    the wrong element must leave the target byte-identical; an untouched
#    backup must still restore (control -- the check may not reject the
#    legitimate backup). ─────────────────────────────────────────────────────

reset
S9="$w/settings9.json"
printf '{}\n' > "$S9"
elemP='{"cmd":"pre"}'
elemQ='{"cmd":"post"}'; shaQ=$(prov_sha_json "$elemQ")
prov_begin --iid JE1 --writer t
prov_record replace json-elem "$S9" --unit /hooks/PreToolUse --pre-json "$elemP" --backup --post-json "$elemQ" \
    --field elem_sha="\"$shaQ\"" --scope user --class code
prov_end ok
printf '%s' '{"hooks":{"PreToolUse":[{"cmd":"post"}]}}' > "$S9"
prov_read_load
u=$(u_for --path "$S9")
bkje=$(field "$u" '.eff_pre.backup')
cp -p "$bkje" "$td/je1.bk.orig"
printf '%s' '{"cmd":"tampered"}' > "$bkje"   # valid JSON, but not the recorded pre-element
BEFORE_JE=$(cat "$S9")
prov_read_apply "$u" restore
rcje=$?
check "HIMMEL-3386 (1): json-elem restore with corrupted (wrong-element) backup returns non-zero" "$rcje" "1"
check "HIMMEL-3386 (1): json-elem target byte-identical after the refused restore" "$(cat "$S9")" "$BEFORE_JE"
cp -p "$td/je1.bk.orig" "$bkje"
prov_read_apply "$u" restore
rcje2=$?
check "HIMMEL-3386 (1) control: json-elem restore with the untouched backup succeeds" "$rcje2" "0"
check "HIMMEL-3386 (1) control: json-elem target holds the pre-element after the restore" "$(jq -c . "$S9")" '{"hooks":{"PreToolUse":[{"cmd":"pre"}]}}'
prov_read_cleanup
rm -f "$td/je1.bk.orig"

# ── HIMMEL-3386 (3): the json-elem fold ORs container_created across the
#    chain. The insert created the container; a later replace row that does
#    not repeat the flag must not make the removal forget it. ────────────────

reset
S10="$w/settings10.json"
printf '{}\n' > "$S10"
elemA='{"cmd":"a"}'; shaA=$(prov_sha_json "$elemA")
elemB='{"cmd":"b"}'; shaB=$(prov_sha_json "$elemB")
prov_begin --iid CC1 --writer t
prov_record insert json-elem "$S10" --unit /hooks/PreToolUse --pre-absent --post-json "$elemA" \
    --field container_created=true --field elem_sha="\"$shaA\"" --scope user --class code
prov_record replace json-elem "$S10" --unit /hooks/PreToolUse --pre-json "$elemA" --backup --post-json "$elemB" \
    --field elem_sha="\"$shaB\"" --scope user --class code
prov_end ok
printf '%s' '{"hooks":{"PreToolUse":[{"cmd":"b"}]}}' > "$S10"
prov_read_load
u=$(u_for --path "$S10")
check "HIMMEL-3386 (3): folded chain carries container_created from the insert row" "$(field "$u" '.fields.container_created // false')" "true"
prov_read_apply "$u" remove
check "HIMMEL-3386 (3): remove drops the container the insert created" "$(jq -c . "$S10")" '{"hooks":{}}'
prov_read_cleanup

# control: no row in the chain set container_created -> the empty container is left alone

reset
S11="$w/settings11.json"
printf '{}\n' > "$S11"
prov_begin --iid CC2 --writer t
prov_record insert json-elem "$S11" --unit /hooks/PreToolUse --pre-absent --post-json "$elemA" \
    --field elem_sha="\"$shaA\"" --scope user --class code
prov_record replace json-elem "$S11" --unit /hooks/PreToolUse --pre-json "$elemA" --backup --post-json "$elemB" \
    --field elem_sha="\"$shaB\"" --scope user --class code
prov_end ok
printf '%s' '{"hooks":{"PreToolUse":[{"cmd":"b"}]}}' > "$S11"
prov_read_load
u=$(u_for --path "$S11")
check "HIMMEL-3386 (3) control: no container_created anywhere in the chain -> flag absent" "$(field "$u" '.fields.container_created // false')" "false"
prov_read_apply "$u" remove
check "HIMMEL-3386 (3) control: remove leaves the empty container" "$(jq -c . "$S11")" '{"hooks":{"PreToolUse":[]}}'
prov_read_cleanup

# ── HIMMEL-3386 (4): prune_backups matches WHOLE newline-delimited entries.
#    A finished backup `foo.bak.extra` must not authorise deleting `foo.bak`
#    (its name is only a prefix of the finished one). ─────────────────────────

reset
prov_begin --iid PB4 --writer t
prov_end ok
prov_read_load
prov_read_session_begin wet
pbdir="$(prov_dir)/provenance-backups"
mkdir -p "$pbdir"
printf 'a\n' > "$pbdir/foo.bak"
printf 'b\n' > "$pbdir/foo.bak.extra"
prov_read_outcome restored '{}' ours "$pbdir/foo.bak.extra"
prov_read_session_end ok
prov_read_prune_backups
check "HIMMEL-3386 (4): finished foo.bak.extra is deleted" "$([ -f "$pbdir/foo.bak.extra" ] && echo yes || echo no)" "no"
check "HIMMEL-3386 (4): foo.bak (only a prefix of the finished name) survives" "$([ -f "$pbdir/foo.bak" ] && echo yes || echo no)" "yes"
prov_read_cleanup

# ── codex-11: prov_read_drop_env_if_ours requires an EXPLICIT
#    eff_pre.state=="absent" -- a governed /env unit with NO recorded pre
#    (eff_pre null) must NOT be treated as himmel's own and dropped. ───────

reset
S7="$w/settings7.json"
prov_begin --iid ENV1 --writer t
prov_record create json-key "$S7" --unit /env --post-json '{}' --scope user --class code
prov_end ok
printf '%s' '{"env":{}}' > "$S7"
prov_read_load
prov_read_drop_env_if_ours "$S7"
check "codex-11: /env with no recorded eff_pre.state is kept, not dropped" "$(jq -r 'has("env")' "$S7")" "true"
prov_read_cleanup

# ── F1 (parent review): a fold failure must fail closed, not leave "ok" with
#    an empty fold. A second row on the same unit with a non-object "pre" is
#    a valid JSON object with a string .op (passes program 1's is_row check
#    and the artifact-op select) but breaks presha()'s `r.pre.state` lookup
#    inside eff_pre_of's chain walk (only triggered with >=2 rows in a unit).

reset
prov_begin --iid F1 --writer t
printf 'f1\n' > "$w/f1.txt"
prov_record create file "$w/f1.txt" --pre-absent --post-file "$w/f1.txt" --scope user --class code
printf '%s\n' '{"t":"2026-09-21T00:00:01Z","iid":"F1","op":"replace","kind":"file","path":"'"$w"'/f1.txt","unit":"","scope":"user","class":"code","pre":"not-an-object","post":{"sha":"x"},"writer":"t"}' >> "$ledger"
prov_end ok
prov_read_load
check "F1: fold failure -> state unparsable, not ok" "$PROV_READ_STATE" "unparsable"
check "F1: fold failure -> reason" "$PROV_READ_REASON" "the ledger could not be folded"
check "F1: fold failure -> fold left empty" "$(prov_read_units | wc -l | tr -d ' ')" "0"
prov_read_cleanup

# ── F2 (parent review): a governed unit with NO recorded pre (eff_pre null,
#    never written because no --pre-* flag was given) must NOT be treated as
#    an explicit "{state:absent}" -- only the latter may yield "remove ours".
#    Missing pre + no backup falls through to "keep no-backup". ────────────

reset
prov_begin --iid F2 --writer t
printf 'f2\n' > "$w/f2.txt"
prov_record create file "$w/f2.txt" --post-file "$w/f2.txt" --scope user --class code
prov_end ok
prov_read_load
u=$(u_for --path "$w/f2.txt")
check "F2: eff_pre is null, not an absent object" "$(field "$u" '.eff_pre')" "null"
check "F2: verdict is keep no-backup, not remove" "$(prov_read_verdict "$u")" "keep no-backup"
prov_read_cleanup

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
