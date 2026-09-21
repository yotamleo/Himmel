#!/usr/bin/env bash
# Platform guard (gitbash-only): bash + node + jq + (sha256sum|shasum).
# test-provenance-js.sh -- scripts/himmelctl/lib/provenance.js (HIMMEL-3332 S1),
# and the bash<->node BYTE-IDENTITY cross-check: the same scenario is run
# through scripts/lib/provenance.sh and through provenance.js into two scratch
# ledgers, and the ledger rows and the backup trees must match byte for byte.
# Runs entirely under a scratch HOME (real ~/.himmel is never touched).
# shellcheck disable=SC2030,SC2031  # each scenario scopes HIMMEL_PROVENANCE_DIR to its own subshell on purpose
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_hermetic-home.sh
. "$here/_hermetic-home.sh"
repo="$(cd "$here/../../.." && pwd)"
fails=0
passes=0
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }  # gnu-ok: BSD stat -f paired
modes() { ( cd "$1" && find . -type f | sort | while read -r p; do printf "%s %s\n" "$p" "$(fmode "$p")"; done | paste -sd, - ); }
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}

node_bin="$(command -v node || true)"
if [ -z "$node_bin" ]; then echo "SKIP - node not installed"; exit 0; fi
command -v jq >/dev/null 2>&1 || { echo "SKIP - jq not installed"; exit 0; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/prov-js-test.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap '[ -n "${tmp:-}" ] && [ -d "$tmp" ] && rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/w"
export HOME="$tmp/home"
USERPROFILE="$(winpath "$tmp/home")"; export USERPROFILE
HIMMELCTL_CACHE_DIR="$(winpath "$tmp/home/.claude/himmel")"; export HIMMELCTL_CACHE_DIR
HIMMEL_LUNA_CONFIG_PATH="$(winpath "$tmp/home/.himmel/config.json")"; export HIMMEL_LUNA_CONFIG_PATH
export HIMMEL_PROVENANCE_NOW=2026-09-21T00:00:00Z
unset HIMMEL_PROVENANCE_IID DRY_RUN CLAUDE_CONFIG_DIR HIMMEL_PROVENANCE_DIR
w="$tmp/w"
jsw="$(winpath "$repo/scripts/himmelctl/lib/provenance.js")"
# shellcheck source=scripts/lib/provenance.sh
. "$repo/scripts/lib/provenance.sh"

b_begin() { prov_begin "$@"; }
b_rec() { prov_record "$@"; }
b_end() { prov_end "$@"; }
n_begin() { "$node_bin" "$jsw" begin "$@" >/dev/null; }
n_rec() { "$node_bin" "$jsw" record "$@"; }
n_end() { "$node_bin" "$jsw" end "$@"; }

# fixtures shared by both runs (identical paths => identical rows)
printf 'one\n' > "$w/f1"
printf 'old2\n' > "$w/f2.snap"; printf 'new2\n' > "$w/f2"; chmod 640 "$w/f2.snap"
printf 'l1\nl2\n' > "$w/rc"
mkdir -p "$w/proj"

scenario() { # <begin-fn> <rec-fn> <end-fn>
    "$1" --iid X1 --writer xw --target "$w/proj/../proj" --root "$repo" -- --flag 'a b' 'ü'
    export HIMMEL_PROVENANCE_IID=X1
    "$2" create file "$w/f1" --post-file "$w/f1" --scope project --class code --row r-f1 --writer xw
    "$2" replace file "$w/f2" --pre-file "$w/f2.snap" --backup --post-file "$w/f2" --scope project --class code
    "$2" replace json-key "$w/s.json" --unit env.HIMMEL_REPO --pre-json '{"z":1,"a":[3,2]}' --backup \
        --post-json '{"b":1,"a":"é\u007f","n":1.0,"m":1E+2,"big":123456789012345678901234567890}' --scope user --class state --field container_created=false
    "$2" insert json-elem "$w/s.json" --unit hooks.Stop --pre-absent --post-json '{"hooks":[{"command":"x"}]}' \
        --field elem_sha='"deadbeef"' --field container_created=true --field container_created=false --scope user --class code
    "$2" append block "$w/rc" --unit himmel-block --pre-text $'l1\nl2' --backup --post-text $'l1\nl2\nl3' --scope user --class state
    "$2" append line "$w/rc" --post-text 'export X=1' --field linger_preexisted=false
    "$2" register plugin - --unit himmel-ops@himmel --scope user --class state --field preexisted=true --post-json '{"v":"1.0.0"}'
    "$2" link symlink "$w/lnk" --post-json '"target"'
    "$2" noop file "$w/f1" --scope project --class keep
    # shellcheck disable=SC1003  # the \\ inside printf's format is a literal backslash, not an escaped quote
    "$2" create file "$w/unicode ✓" --unit "$(printf 'a\177b\303\251\342\200\250"\\')" --post-file "$w/f1"
    "$2" create file relative.txt --post-file "$w/f1"
    "$2" replace file "$w/f2" --pre-file "$w/f2.snap" --backup --post-file "$w/f2"
    "$3" failed step-9
}

( export HIMMEL_PROVENANCE_DIR="$tmp/pb"; cd "$w" && scenario b_begin b_rec b_end ) >"$tmp/b.out" 2>&1
check "bash scenario rc" "$?" "0"
( export HIMMEL_PROVENANCE_DIR="$tmp/pn"; cd "$w" && scenario n_begin n_rec n_end ) >"$tmp/n.out" 2>&1
check "node scenario rc" "$?" "0"
[ -s "$tmp/b.out" ] && cat "$tmp/b.out"
[ -s "$tmp/n.out" ] && cat "$tmp/n.out"

norm() { sed "s#$1#PROV#g" "$1/provenance.jsonl"; }
norm "$tmp/pb" > "$tmp/pb.rows"
norm "$tmp/pn" > "$tmp/pn.rows"
check "scenario wrote 14 rows (bash)" "$(wc -l < "$tmp/pb.rows" | tr -d ' ')" "14"
if cmp -s "$tmp/pb.rows" "$tmp/pn.rows"; then check "bash and node rows are byte-identical" same same
else check "bash and node rows are byte-identical" differ same; diff "$tmp/pb.rows" "$tmp/pn.rows" | head -n 20; fi
if diff -r "$tmp/pb/provenance-backups" "$tmp/pn/provenance-backups" >/dev/null 2>&1; then check "bash and node backup trees are identical" same same
else check "bash and node backup trees are identical" differ same; diff -r "$tmp/pb/provenance-backups" "$tmp/pn/provenance-backups" | head; fi
check "backup file modes match" "$(modes "$tmp/pb/provenance-backups")" \
    "$(modes "$tmp/pn/provenance-backups")"
check "ledger mode (node) 0600" "$(fmode "$tmp/pn/provenance.jsonl")" "600"
check "backups dir mode (node) 0700" "$(fmode "$tmp/pn/provenance-backups/X1")" "700"
check "every row parses" "$(jq -c . "$tmp/pn.rows" >/dev/null 2>&1; echo $?)" "0"

# a writer called with no session: implicit begin+row+end, iid normalised
implicit() { # <rec-fn> <dir>
    ( export HIMMEL_PROVENANCE_DIR="$2"; cd "$w" && "$1" create file "$w/f1" --post-file "$w/f1" --writer solo --scope project --class code )
}
implicit b_rec "$tmp/ib"; implicit n_rec "$tmp/in"
iid_b=$(jq -r .iid "$tmp/ib/provenance.jsonl" | head -n1); iid_n=$(jq -r .iid "$tmp/in/provenance.jsonl" | head -n1)
check "implicit session (bash) = begin,create,end" "$(jq -r .op "$tmp/ib/provenance.jsonl" | paste -sd, -)" "install-begin,create,install-end"
check "implicit rows byte-identical modulo the iid" "$(sed "s#$iid_n#IID#" "$tmp/in/provenance.jsonl" | _prov_sha256)" "$(sed "s#$iid_b#IID#" "$tmp/ib/provenance.jsonl" | _prov_sha256)"

# ── node behaviour ───────────────────────────────────────────────────────
export HIMMEL_PROVENANCE_DIR="$tmp/pu"
"$node_bin" "$jsw" record bogus file x 2>"$tmp/err"; check "node: bad op → rc 2" "$?" "2"
check "node: usage error names the tool" "$(grep -c '^provenance: ' "$tmp/err")" "1"
"$node_bin" "$jsw" record create file "$w/x" --backup 2>/dev/null; check "node: --backup without a pre source → rc 2" "$?" "2"
"$node_bin" "$jsw" record create file "$w/x" --field iid='"x"' 2>/dev/null; check "node: reserved --field → rc 2" "$?" "2"
"$node_bin" "$jsw" record create file "$w/x" --post-file "$w/nope" 2>/dev/null; check "node: missing post file → rc 1" "$?" "1"
"$node_bin" "$jsw" record create file "$w/x" --post-json '{oops' 2>/dev/null; check "node: invalid post JSON → rc 1" "$?" "1"
check "node: refusals wrote nothing" "$([ -e "$tmp/pu" ] && echo yes || echo no)" "no"
out=$(DRY_RUN=1 "$node_bin" "$jsw" record replace file "$w/f1" --backup --pre-file "$w/f1")
check "node: dry-run prints DRY: record" "$out" "DRY: record replace file $w/f1"
check "node: dry-run writes nothing" "$([ -e "$tmp/pu" ] && echo yes || echo no)" "no"

# a child that only inherits the session must not close it; `end` on the CLI closes it
HIMMEL_PROVENANCE_IID=Z9 "$node_bin" -e "require(process.argv[1]).provEnd('ok')" "$jsw"
check "node: provEnd is a no-op for a non-owner" "$([ -e "$tmp/pu" ] && echo yes || echo no)" "no"
HIMMEL_PROVENANCE_IID=Z9 "$node_bin" "$jsw" end ok
check "node: CLI end closes the exported session" "$(jq -c '[.op,.iid,.status]' "$tmp/pu/provenance.jsonl")" '["install-end","Z9","ok"]'
HIMMEL_PROVENANCE_IID=Z9 "$node_bin" "$jsw" begin --writer child
check "node: begin inside an exported session is a no-op" "$(wc -l < "$tmp/pu/provenance.jsonl" | tr -d ' ')" "1"

# torn last line
rm -rf "$tmp/pu"; mkdir -p "$tmp/pu"; printf '{"t":"2026' > "$tmp/pu/provenance.jsonl"
"$node_bin" "$jsw" record create file "$w/f1" --post-file "$w/f1"
check "node: torn line stays its own line" "$(head -n1 "$tmp/pu/provenance.jsonl")" '{"t":"2026'
check "node: rows after a torn line parse" "$(tail -n +2 "$tmp/pu/provenance.jsonl" | jq -c . >/dev/null 2>&1; echo $?)" "0"

# no HOME and no override → rc 1
( unset HIMMEL_PROVENANCE_DIR HOME USERPROFILE; "$node_bin" "$jsw" record create file "$w/f1" 2>"$tmp/err2"; echo "rc=$?" > "$tmp/rc2" )
check "node: no HOME → rc 1" "$(cat "$tmp/rc2")" "rc=1"

# no jq on PATH: the pure-JS canonicaliser must still agree on ordinary values
mkdir -p "$tmp/nodeonly"; ln -s "$node_bin" "$tmp/nodeonly/node"
val='{"b":1,"a":[2,{"d":1,"c":null}],"s":"é\u007f\n"}'
rm -rf "$tmp/pu"
PATH="$tmp/nodeonly" "$tmp/nodeonly/node" "$jsw" record replace json-key "$w/s.json" --post-json "$val" --pre-json "$val" >/dev/null 2>&1
check "node without jq: post.sha matches jq -cS" "$(grep -v install- "$tmp/pu/provenance.jsonl" | jq -r .post.sha)" "$(printf '%s' "$val" | jq -cS . | tr -d '\n' | _prov_sha256)"

# review fixes: the CLI begin prints the iid; one-document values; atomic backups; retryable end
rm -rf "$tmp/pu"
iid=$("$node_bin" "$jsw" begin --writer cli)
check "node: CLI begin prints a generated iid" "$(printf '%s' "$iid" | grep -cE '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$')" "1"
check "node: the printed iid is the row's iid" "$(jq -r .iid "$tmp/pu/provenance.jsonl")" "$iid"
check "node: CLI begin --iid prints it back" "$("$node_bin" "$jsw" begin --iid FIXED --writer cli)" "FIXED"
rm -rf "$tmp/pu"
"$node_bin" "$jsw" record create file "$w/x" --field 'k=1 2' 2>/dev/null; check "node: multi-document --field → rc 2" "$?" "2"
"$node_bin" "$jsw" record create file "$w/x" --post-json '1 2' 2>/dev/null; check "node: multi-document post JSON → rc 1" "$?" "1"
"$node_bin" "$jsw" record create file "$w/x" --post-json '' 2>/dev/null; check "node: empty post JSON → rc 1" "$?" "1"
check "node: multi-document refusals wrote nothing" "$([ -e "$tmp/pu" ] && echo yes || echo no)" "no"

pids=""
for k in 1 2 3 4 5 6 7 8; do
    printf 'v%s\n' "$k" > "$w/c$k.snap"
    HIMMEL_PROVENANCE_IID=C1 "$node_bin" "$jsw" record replace file "$w/same.txt" --pre-file "$w/c$k.snap" --backup --post-file "$w/c$k.snap" >/dev/null &
    pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
set -- "$tmp/pu/provenance-backups/C1"/*
check "node: 8 concurrent backups → 8 distinct files" "$#" "8"
check "node: 8 concurrent backups → 8 distinct backup paths in the ledger" "$(jq -r '.pre.backup // empty' "$tmp/pu/provenance.jsonl" | sort -u | wc -l | tr -d ' ')" "8"

rm -rf "$tmp/pu"
cat > "$tmp/retry.js" <<'RETRY_EOF'
const fs = require('fs'); const p = require(process.argv[2]);
const led = process.env.HIMMEL_PROVENANCE_DIR + '/provenance.jsonl';
p.provBegin(['--iid', 'E1', '--writer', 'retry']);
fs.renameSync(led, led + '.bak'); fs.mkdirSync(led);
let threw = false;
try { p.provEnd('ok'); } catch (_) { threw = true; }
console.log('threw=' + threw, 'open=' + (process.env.HIMMEL_PROVENANCE_IID || 'unset'));
fs.rmdirSync(led); fs.renameSync(led + '.bak', led);
p.provEnd('ok');
console.log('closed=' + (process.env.HIMMEL_PROVENANCE_IID || 'unset'));
RETRY_EOF
check "node: a failed provEnd throws, keeps the session, and the retry closes it" \
    "$(HIMMEL_PROVENANCE_DIR="$tmp/pu" "$node_bin" "$(winpath "$tmp/retry.js")" "$jsw" | paste -sd' ' -)" "threw=true open=E1 closed=unset"
check "node: retry wrote install-end" "$(tail -n1 "$tmp/pu/provenance.jsonl" | jq -c '[.op,.iid,.status]')" '["install-end","E1","ok"]'

# unwritable backup name is an I/O error (rc 1), not a spin; the root path survives
rm -rf "$tmp/pu"
long=$(printf '%0300d' 0)
# shellcheck source=scripts/lib/timeout-bin.sh
. "$repo/scripts/lib/timeout-bin.sh" 2>/dev/null
if [ -n "${_TIMEOUT_BIN:-}" ]; then
    "$_TIMEOUT_BIN" 20 "$node_bin" "$jsw" record replace file "$w/$long" --pre-file "$w/f1" --backup --post-file "$w/f1" 2>/dev/null
    check "node: unwritable backup name → rc 1" "$?" "1"
else
    echo "SKIP - timeout not installed: unwritable-backup-name guard not exercised"
fi
rm -rf "$tmp/pu"
"$node_bin" "$jsw" record register mcp / --unit m --post-json '"x"'
check "node: path '/' is recorded as /" "$(grep -v install- "$tmp/pu/provenance.jsonl" | jq -r .path)" "/"

# a jq that ends its lines with CRLF (jq.exe on Windows) must not leak a CR into the sha or the backup
rm -rf "$tmp/pu"
mkdir -p "$tmp/crjq"
# shellcheck disable=SC2016  # $@ / $0 belong to the generated wrapper script
printf '#!/bin/sh\n"%s" "$@" | awk '"'"'{ printf "%%s\\r\\n", $0 }'"'"'\n' "$(command -v jq)" > "$tmp/crjq/jq"; chmod +x "$tmp/crjq/jq"
PATH="$tmp/crjq:$PATH" "$node_bin" "$jsw" record replace json-key "$w/s.json" --unit k --post-json '{"b":1,"a":2}' --pre-json '{"z":[1]}' --backup >/dev/null
check "node CRLF jq: post.sha is of the canonical bytes" "$(grep -v install- "$tmp/pu/provenance.jsonl" | jq -r .post.sha)" "$(printf '%s' '{"a":2,"b":1}' | _prov_sha256)"
check "node CRLF jq: the backup holds the canonical bytes" "$(cat "$(grep -v install- "$tmp/pu/provenance.jsonl" | jq -r .pre.backup)")" '{"z":[1]}'

# a session id that is not one safe path segment never reaches the filesystem
rm -rf "$tmp/pu"
HIMMEL_PROVENANCE_IID='../evil' "$node_bin" "$jsw" record replace file "$w/f1" --pre-file "$w/f1" --backup --post-file "$w/f1" 2>/dev/null
check "node: unsafe iid + --backup → rc 1" "$?" "1"
check "node: unsafe iid wrote no backup outside the ledger dir" "$([ -e "$tmp/pu/evil" ] && echo yes || echo no)" "no"

# a POSIX filename may contain a backslash; only Windows treats it as a separator
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "SKIP - Windows: a backslash is a path separator here" ;;
    *)
        rm -rf "$tmp/pu"
        "$node_bin" "$jsw" record create file "$w"'/a\b' --post-json '"x"'
        check "node: POSIX backslash filename is recorded as given" "$(grep -v install- "$tmp/pu/provenance.jsonl" | jq -r .path)" "$w"'/a\b'
        ;;
esac

# a Windows drive root keeps its slash and is not split into the bare "C:" (the drive's
# cwd); fixture: a directory literally named "C:" (a real drive root needs Windows)
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "SKIP - Windows: 'C:/' is a real drive root here" ;;
    *)
        rm -rf "$tmp/pu" "$tmp/drv"; mkdir -p "$tmp/drv/C:"
        ( cd "$tmp/drv" && "$node_bin" "$jsw" record register mcp 'C:/' --unit m --post-json '"x"' )
        check "node: drive root 'C:/' is recorded as the root itself" "$(grep -v install- "$tmp/pu/provenance.jsonl" | jq -r .path)" "$(cd "$tmp/drv/C:" && pwd -P)/"
        ;;
esac

# a pre-existing group/world-readable ledger is tightened to 0600 by the next append
rm -rf "$tmp/pu"; mkdir -p "$tmp/pu"; : > "$tmp/pu/provenance.jsonl"; chmod 644 "$tmp/pu/provenance.jsonl"
"$node_bin" "$jsw" record register mcp - --unit m --post-json '"x"'
check "node: existing 0644 ledger is tightened to 0600" "$(fmode "$tmp/pu/provenance.jsonl")" "600"

# a symlink input records the TARGET's mode, like its sha and size (bash follows it too)
rm -rf "$tmp/pu"; printf 'abc' > "$w/tgt"; chmod 640 "$w/tgt"; ln -s "$w/tgt" "$w/lnk"
"$node_bin" "$jsw" record create file "$w/dst" --post-file "$w/lnk"
check "node: symlink --post-file records the target's mode" "$(grep -v install- "$tmp/pu/provenance.jsonl" | jq -r .post.mode)" "0640"
rm -rf "$tmp/sb" "$tmp/sn"
( export HIMMEL_PROVENANCE_DIR="$tmp/sb"; cd "$w" && b_rec create file "$w/dst" --post-file "$w/lnk" )
( export HIMMEL_PROVENANCE_DIR="$tmp/sn"; cd "$w" && n_rec create file "$w/dst" --post-file "$w/lnk" )
check "bash-vs-node: symlink rows are byte-identical" "$(sed 's#"iid":"[^"]*"#"iid":"X"#' "$tmp/sn/provenance.jsonl" | _prov_sha256)" "$(sed 's#"iid":"[^"]*"#"iid":"X"#' "$tmp/sb/provenance.jsonl" | _prov_sha256)"

# an existing but unreadable file is a provenance: diagnostic (rc 1), not a stack trace
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "SKIP - Windows: chmod 000 does not block reads here" ;;
    *)
        if [ "$(id -u)" = 0 ]; then echo "SKIP - root reads a mode-000 file"; else
            rm -rf "$tmp/pu"; printf 'x' > "$w/unread"; chmod 000 "$w/unread"
            out=$("$node_bin" "$jsw" record create file "$w/dst" --post-file "$w/unread" 2>&1); rc=$?
            check "node: unreadable --post-file → rc 1" "$rc" "1"
            check "node: unreadable --post-file is a provenance: diagnostic" "${out%%:*}" "provenance"
            check "node: unreadable --post-file leaves no stack trace" "$(printf '%s' "$out" | grep -c 'node:internal')" "0"
            chmod 600 "$w/unread"
        fi
        ;;
esac

# a symlink at the ledger is refused before any chmod or append lands in its target
rm -rf "$tmp/pu" "$w/victim" "$w/nowhere"; mkdir -p "$tmp/pu"
printf 'keep\n' > "$w/victim"; chmod 644 "$w/victim"; ln -s "$w/victim" "$tmp/pu/provenance.jsonl"
err=$("$node_bin" "$jsw" record register mcp - --unit m --post-json '"x"' 2>&1 >/dev/null); rc=$?
check "node: symlink ledger → rc 1" "$rc" "1"
check "node: symlink ledger is a provenance: diagnostic" "${err%%:*}" "provenance"
check "node: symlink ledger target is byte-identical" "$(cat "$w/victim")" "keep"
check "node: symlink ledger target mode is untouched" "$(fmode "$w/victim")" "644"
rm -f "$tmp/pu/provenance.jsonl"; ln -s "$w/nowhere" "$tmp/pu/provenance.jsonl"
"$node_bin" "$jsw" record register mcp - --unit m --post-json '"x"' 2>/dev/null; rc=$?
check "node: dangling symlink ledger → rc 1" "$rc" "1"
check "node: dangling symlink ledger creates nothing through the link" "$([ -e "$w/nowhere" ] && echo yes || echo no)" "no"

# a symlink at the backup dir (or its parent) is refused before anything is copied through it
rm -rf "$tmp/pu" "$w/bkvictim"; mkdir -p "$tmp/pu/provenance-backups" "$w/bkvictim"
printf 'pre\n' > "$w/pre.txt"; iid=20260921T000000Z-aaaaaa
ln -s "$w/bkvictim" "$tmp/pu/provenance-backups/$iid"
err=$(HIMMEL_PROVENANCE_IID=$iid "$node_bin" "$jsw" record replace file "$w/pre.txt" --pre-file "$w/pre.txt" --backup --post-file "$w/pre.txt" 2>&1 >/dev/null); rc=$?
check "node: symlink backup dir → rc 1" "$rc" "1"
check "node: symlink backup dir is a provenance: diagnostic" "${err%%:*}" "provenance"
check "node: nothing was copied through the symlink backup dir" "$(find "$w/bkvictim" -mindepth 1 | wc -l | tr -d ' ')" "0"
rm -rf "$tmp/pu/provenance-backups"; ln -s "$w/bkvictim" "$tmp/pu/provenance-backups"
HIMMEL_PROVENANCE_IID=$iid "$node_bin" "$jsw" record replace file "$w/pre.txt" --pre-file "$w/pre.txt" --backup --post-file "$w/pre.txt" 2>/dev/null; rc=$?
check "node: symlink provenance-backups parent → rc 1" "$rc" "1"
check "node: nothing was copied through the symlink parent" "$(find "$w/bkvictim" -mindepth 1 | wc -l | tr -d ' ')" "0"

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
