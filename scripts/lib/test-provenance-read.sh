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
snap1=$(mktemp); cp "$w/f.txt" "$snap1"
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
snap2=$(mktemp); cp -p "$w/r.txt" "$snap2"
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
snap3=$(mktemp); cp "$w/b1.txt" "$snap3"
printf 'one-new\n' > "$w/b1.txt"
prov_record replace file "$w/b1.txt" --pre-file "$snap3" --backup --post-file "$w/b1.txt" --scope user --class code
printf 'two\n' > "$w/b2.txt"
snap4=$(mktemp); cp "$w/b2.txt" "$snap4"
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
