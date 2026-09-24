#!/usr/bin/env bash
# Platform guard (gitbash-only): bash + jq + (sha256sum|shasum).
# test-provenance.sh -- tests for scripts/lib/provenance.sh (HIMMEL-3332 S1).
# Everything runs under a scratch HOME / HIMMEL_PROVENANCE_DIR; the real
# ~/.himmel is never read or written. The node twin and the bash<->node
# byte-identity cross-check live in scripts/himmelctl/test/test-provenance-js.sh.
# shellcheck disable=SC2030,SC2031  # PATH is overridden per-subshell on purpose (fake jq)
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
passes=0
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }  # gnu-ok: BSD stat -f paired
sha() { printf '%s' "$1" | _prov_sha256; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/prov-test.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
trap '[ -n "${tmp:-}" ] && [ -d "$tmp" ] && rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"
export HIMMEL_PROVENANCE_DIR="$tmp/prov"
export HIMMEL_PROVENANCE_NOW=2026-09-21T00:00:00Z
unset HIMMEL_PROVENANCE_IID DRY_RUN CLAUDE_CONFIG_DIR
ledger="$HIMMEL_PROVENANCE_DIR/provenance.jsonl"
w="$tmp/w"
mkdir -p "$w"

opts_before="$-"
# shellcheck source=scripts/lib/provenance.sh
. "$here/provenance.sh"
check "sourcing leaves shell options alone" "$-" "$opts_before"

last() { grep -v "\"op\":\"install-" "$ledger" | tail -n1; }
lastraw() { tail -n1 "$ledger"; }
lines() { wc -l < "$ledger" | tr -d ' '; }

# ── RED assertions from the plan ──────────────────────────────────────────
# 1. replace + --pre-file + --backup: the backup exists and hashes to the pre bytes.
printf 'old-bytes\n' > "$w/a.txt"
cp -p "$w/a.txt" "$w/a.snap"
printf 'new-bytes\n' > "$w/a.txt"
prov_record replace file "$w/a.txt" --pre-file "$w/a.snap" --backup --post-file "$w/a.txt" \
    --scope project --class code --row adopter-scripts --writer test
rc=$?
check "replace+backup rc" "$rc" "0"
bk=$(last | jq -r '.pre.backup')
check "backup file exists" "$([ -f "$bk" ] && echo yes || echo no)" "yes"
check "backup sha == pre bytes" "$(_prov_sha256 < "$bk")" "$(sha 'old-bytes
')"
check "pre.sha == backup sha" "$(last | jq -r '.pre.sha')" "$(_prov_sha256 < "$bk")"
check "post.sha == new bytes" "$(last | jq -r '.post.sha')" "$(sha 'new-bytes
')"
check "post.size" "$(last | jq -r '.post.size')" "10"
check "op/kind/scope/class" "$(last | jq -r '[.op,.kind,.scope,.class,.manifest_row,.writer]|join(",")')" "replace,file,project,code,adopter-scripts,test"
check "backup path is <dir>/provenance-backups/<iid>/001-a.txt" "${bk#"$HIMMEL_PROVENANCE_DIR/provenance-backups/"}" "$(last | jq -r '.iid')/001-a.txt"

# 2. dry run: nothing written, DRY line printed.
rm -rf "$HIMMEL_PROVENANCE_DIR"
out=$(DRY_RUN=1 prov_record replace file "$w/a.txt" --pre-file "$w/a.snap" --backup --post-file "$w/a.txt")
check "dry-run prints DRY: record" "$out" "DRY: record replace file $w/a.txt"
check "dry-run writes no ledger" "$([ -e "$HIMMEL_PROVENANCE_DIR" ] && echo yes || echo no)" "no"
out=$(prov_record create file "$w/a.txt" --dry-run)
check "--dry-run flag prints too" "$out" "DRY: record create file $w/a.txt"
check "--dry-run writes no ledger" "$([ -e "$HIMMEL_PROVENANCE_DIR" ] && echo yes || echo no)" "no"

# 3. json-key post.sha == sha256 of the independently canonicalised (jq -cS) value.
val='{"b":1,"a":[2,1],"c":"é\u007f"}'
canon=$(printf '%s' "$val" | jq -cS .)
prov_record replace json-key "$w/settings.json" --unit env.HIMMEL_REPO --pre-json '{"z":0}' --backup --post-json "$val" --scope user --class state
check "json-key post.sha" "$(last | jq -r '.post.sha')" "$(sha "$canon")"
check "json-key pre.sha" "$(last | jq -r '.pre.sha')" "$(sha '{"z":0}')"
check "json-key: no size/mode on a value" "$(last | jq -c '.post|keys')" '["sha"]'
bk=$(last | jq -r '.pre.backup')
case "$bk" in *-settings.json.prior.json) ok=yes ;; *) ok=no ;; esac
check "json backup is .prior.json" "$ok" "yes"
check "json backup holds the canonical prior value, no newline" "$(cat "$bk")" '{"z":0}'
check "json backup sha == pre.sha" "$(_prov_sha256 < "$bk")" "$(last | jq -r '.pre.sha')"
check "prov_sha_json" "$(prov_sha_json "$val")" "$(sha "$canon")"

# ── row shape ─────────────────────────────────────────────────────────────
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_record insert json-elem "$w/settings.json" --unit hooks.PreToolUse --scope user --class code \
    --field container_created=true --field elem_sha='"abc"' --pre-absent --post-json '{"hooks":[]}' --writer w --row r1
check "key order" "$(last | jq -r 'keys_unsorted|join(",")')" "t,iid,op,kind,path,unit,scope,class,container_created,elem_sha,pre,post,writer,manifest_row"
check "pre-absent" "$(last | jq -c .pre)" '{"state":"absent"}'
check "field values are JSON" "$(last | jq -c '[.container_created,.elem_sha]')" '[true,"abc"]'
check "t honours the seam" "$(last | jq -r .t)" "2026-09-21T00:00:00Z"

# a registration: no path, value post
prov_record register plugin - --unit himmel-ops@himmel --scope user --class state --field preexisted=false --post-json '{"v":1}'
check "registration has no path" "$(last | jq -c 'has("path")')" "false"
check "registration post is a value" "$(last | jq -c .post)" '{"value":{"v":1}}'
check "registration row order" "$(last | jq -r 'keys_unsorted|join(",")')" "t,iid,op,kind,unit,scope,class,preexisted,post"

# block / line: text hashed as exact bytes
prov_record append block "$w/rc" --pre-text 'x' --post-text 'y' --backup --scope user --class state
check "text post.sha" "$(last | jq -r .post.sha)" "$(sha y)"
bk=$(last | jq -r .pre.backup)
case "$bk" in *-rc.prior.txt) ok=yes ;; *) ok=no ;; esac
check "text backup is .prior.txt" "$ok" "yes"
check "text backup bytes" "$(cat "$bk")" "x"

# unicode / DEL in a string is escaped the jq way
prov_record create file "$w/u.txt" --unit "$(printf 'a\177b\303\251')"
check "DEL escaped as \\u007f" "$(last | grep -c '\\u007f')" "1"
check "unicode kept raw" "$(last | grep -c 'é')" "1"

# path canonicalisation: the parent chain is resolved, a link basename is kept
mkdir -p "$w/real"
ln -s "$w/real" "$w/linkdir"
ln -s "$w/a.txt" "$w/real/lnk"
prov_record link symlink "$w/linkdir/lnk" --post-json '"x"'
check "symlinked parent resolved, basename kept" "$(last | jq -r .path)" "$w/real/lnk"

# ── modes ─────────────────────────────────────────────────────────────────
check "ledger is 0600" "$(fmode "$ledger")" "600"
printf 'm\n' > "$w/m.txt"; chmod 640 "$w/m.txt"
prov_record replace file "$w/m.txt" --pre-file "$w/m.txt" --backup --post-file "$w/m.txt"
check "pre.mode is 4-digit octal" "$(last | jq -r .pre.mode)" "0640"
bk=$(last | jq -r .pre.backup)
check "backup keeps the mode (cp -p)" "$(fmode "$bk")" "640"
check "backups dir is 0700" "$(fmode "$(dirname "$bk")")" "700"

# ── usage errors write nothing ────────────────────────────────────────────
n0=$(lines)
prov_record bogus file "$w/x" 2>/dev/null; check "bad op → rc 2" "$?" "2"
prov_record create nonsense "$w/x" 2>/dev/null; check "bad kind → rc 2" "$?" "2"
prov_record create file "$w/x" --scope nowhere 2>/dev/null; check "bad scope → rc 2" "$?" "2"
prov_record create file "$w/x" --class nope 2>/dev/null; check "bad class → rc 2" "$?" "2"
prov_record create file "$w/x" --backup 2>/dev/null; check "--backup without a pre source → rc 2" "$?" "2"
prov_record create file "$w/x" --field iid='"x"' 2>/dev/null; check "reserved --field → rc 2" "$?" "2"
prov_record create file "$w/x" --field 'k=not json' 2>/dev/null; check "non-JSON --field → rc 2" "$?" "2"
prov_record create file "$w/x" --post-file "$w/does-not-exist" 2>/dev/null; check "missing post file → rc 1" "$?" "1"
prov_record create file "$w/x" --post-json '{oops' 2>/dev/null; check "invalid post JSON → rc 1" "$?" "1"
prov_record create file 2>/dev/null; check "too few args → rc 2" "$?" "2"
check "refusals append nothing" "$(lines)" "$n0"

# ── sessions ──────────────────────────────────────────────────────────────
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_begin --iid S1 --writer adopt.sh --target "$w" -- --dry a 'b c'
check "prov_begin exports the iid" "${HIMMEL_PROVENANCE_IID:-}" "S1"
b=$(head -n1 "$ledger")
check "begin row order" "$(printf '%s' "$b" | jq -r 'keys_unsorted|join(",")')" "t,iid,op,himmel_root,himmel_head,version,argv,home,claude_config_dir,target,platform,writer"
check "begin op/iid/writer" "$(printf '%s' "$b" | jq -r '[.op,.iid,.writer]|join(",")')" "install-begin,S1,adopt.sh"
check "begin argv" "$(printf '%s' "$b" | jq -c .argv)" '["--dry","a","b c"]'
check "begin home" "$(printf '%s' "$b" | jq -r .home)" "$HOME"
check "begin claude_config_dir defaults under HOME" "$(printf '%s' "$b" | jq -r .claude_config_dir)" "$HOME/.claude"
check "begin target" "$(printf '%s' "$b" | jq -r .target)" "$w"
check "begin himmel_head is a sha" "$(printf '%s' "$b" | jq -r '.himmel_head|test("^[0-9a-f]{40}$")')" "true"
check "begin platform" "$(printf '%s' "$b" | jq -r '.platform|IN("linux","darwin","win32")')" "true"
prov_record create file "$w/a.txt" --post-file "$w/a.txt"
check "record joins the open session" "$(last | jq -r .iid)" "S1"
# a child that inherits the session must not open or close it
bash -c '. "$1/provenance.sh"; prov_begin --writer child; prov_end ok; echo "child:${HIMMEL_PROVENANCE_IID:-}"' _ "$here" > "$tmp/child.out"
check "child inherits the iid" "$(cat "$tmp/child.out")" "child:S1"
check "child wrote no begin/end" "$(lines)" "2"
prov_end ok
check "owner's prov_end writes install-end" "$(lastraw | jq -c '[.op,.iid,.status,.failed_step]')" '["install-end","S1","ok",null]'
check "prov_end unsets the iid" "${HIMMEL_PROVENANCE_IID:-unset}" "unset"
prov_begin --iid S2 --writer x; prov_end failed step-3
check "failed_step recorded" "$(lastraw | jq -c '[.status,.failed_step]')" '["failed","step-3"]'
prov_end weird 2>/dev/null; check "bad status → rc 2" "$?" "2"

# a writer called with no session opens a one-row session of its own
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_record create file "$w/a.txt" --post-file "$w/a.txt" --writer solo
check "implicit session = begin+row+end" "$(jq -r .op "$ledger" | paste -sd, -)" "install-begin,create,install-end"
check "implicit session shares one iid" "$(jq -r .iid "$ledger" | sort -u | wc -l | tr -d ' ')" "1"
check "implicit session does not export" "${HIMMEL_PROVENANCE_IID:-unset}" "unset"
check "implicit end status" "$(lastraw | jq -r .status)" "ok"

# dry-run session calls are silent no-ops
rm -rf "$HIMMEL_PROVENANCE_DIR"
DRY_RUN=1 prov_begin --iid D1 -- x
DRY_RUN=1 prov_end ok
check "dry-run begin/end write nothing" "$([ -e "$HIMMEL_PROVENANCE_DIR" ] && echo yes || echo no)" "no"
check "dry-run begin exports nothing" "${HIMMEL_PROVENANCE_IID:-unset}" "unset"

# torn last line: closed, one row lost, the rest parse
rm -rf "$HIMMEL_PROVENANCE_DIR"; mkdir -p "$HIMMEL_PROVENANCE_DIR"
printf '{"t":"2026' > "$ledger"
prov_record create file "$w/a.txt" --post-file "$w/a.txt"
check "torn line: appended rows all parse" "$(tail -n +2 "$ledger" | jq -c . >/dev/null 2>&1; echo $?)" "0"
check "torn line: torn row is its own line" "$(head -n1 "$ledger")" '{"t":"2026'

# HOME unset and no override → a clear failure, not a write to /
( unset HIMMEL_PROVENANCE_DIR HOME; prov_record create file "$w/a.txt" 2>"$tmp/err"; echo "rc=$?" > "$tmp/rc" )
check "no HOME → rc 1" "$(cat "$tmp/rc")" "rc=1"
check "no HOME → says why" "$(grep -c 'HOME is unset' "$tmp/err")" "1"

# ── review fixes: one-document values, atomic backups, retryable end ───────
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_record create file "$w/x" --field 'k=1 2' 2>/dev/null; check "multi-document --field → rc 2" "$?" "2"
prov_record create file "$w/x" --post-json '1 2' 2>/dev/null; check "multi-document post JSON → rc 1" "$?" "1"
prov_record create file "$w/x" --post-json '' 2>/dev/null; check "empty post JSON → rc 1" "$?" "1"
check "multi-document refusals wrote nothing" "$([ -e "$ledger" ] && echo yes || echo no)" "no"

# concurrent --backup calls in ONE session must get distinct sequence numbers
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_begin --iid C1 --writer conc
pids=""
for k in 1 2 3 4 5 6 7 8; do
    printf 'v%s\n' "$k" > "$w/c$k.snap"
    prov_record replace file "$w/same.txt" --pre-file "$w/c$k.snap" --backup --post-file "$w/c$k.snap" >/dev/null &
    pids="$pids $!"
done
for pid in $pids; do wait "$pid"; done
prov_end ok
set -- "$HIMMEL_PROVENANCE_DIR/provenance-backups/C1"/*
check "8 concurrent backups → 8 distinct files" "$#" "8"
check "8 concurrent backups → 8 distinct backup paths in the ledger" "$(jq -r '.pre.backup // empty' "$ledger" | sort -u | wc -l | tr -d ' ')" "8"

# a failed end-row append must leave the session open so prov_end can be retried
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_begin --iid E1 --writer retry
mv "$ledger" "$ledger.bak"; mkdir "$ledger"
prov_end ok 2>/dev/null; check "prov_end with an unwritable ledger → rc 1" "$?" "1"
check "failed prov_end keeps the session open" "${HIMMEL_PROVENANCE_IID:-unset}" "E1"
rmdir "$ledger"; mv "$ledger.bak" "$ledger"
prov_end ok; check "prov_end retry succeeds" "$?" "0"
check "retry wrote install-end" "$(lastraw | jq -c '[.op,.iid,.status]')" '["install-end","E1","ok"]'
check "retry closed the session" "${HIMMEL_PROVENANCE_IID:-unset}" "unset"

# a failing jq must not append an empty row, and an unwritable backup name must not spin
rm -rf "$HIMMEL_PROVENANCE_DIR"
# a jq that works for everything except the final artifact-row build, as if it died there
mkdir -p "$tmp/badjq"; printf '#!/bin/sh\ncase "$*" in *"--arg kind"*) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v jq)" > "$tmp/badjq/jq"; chmod +x "$tmp/badjq/jq"
( PATH="$tmp/badjq:$PATH"; prov_record create file "$w/a.txt" --post-file "$w/a.txt" 2>/dev/null ); check "failing jq → rc 1" "$?" "1"
check "failing jq left no empty line in the ledger" "$(grep -c '^$' "$ledger")" "0"
check "failing jq left no artifact row (begin only)" "$(jq -r .op "$ledger" | paste -sd, -)" "install-begin"
long=$(printf '%0300d' 0)
# shellcheck source=scripts/lib/timeout-bin.sh
. "$here/timeout-bin.sh" 2>/dev/null
if [ -n "${_TIMEOUT_BIN:-}" ]; then
    # shellcheck disable=SC2016  # $1..$3 are the child shell's positional parameters
    "$_TIMEOUT_BIN" 20 bash -c '. "$1/provenance.sh"; prov_record replace file "$2/$3" --pre-file "$2/a.txt" --backup --post-file "$2/a.txt"' _ "$here" "$w" "$long" 2>/dev/null
    check "unwritable backup name → rc 1, not a hang" "$?" "1"
else
    echo "SKIP - timeout not installed: unwritable-backup-name hang guard not exercised"
fi

# a jq that ends its lines with CRLF (jq.exe on Windows) must not leak a CR into hashes, backups or rows
rm -rf "$HIMMEL_PROVENANCE_DIR"
mkdir -p "$tmp/crjq"
# shellcheck disable=SC2016  # $@ / $0 belong to the generated wrapper script
printf '#!/bin/sh\n"%s" "$@" | awk '"'"'{ printf "%%s\\r\\n", $0 }'"'"'\n' "$(command -v jq)" > "$tmp/crjq/jq"; chmod +x "$tmp/crjq/jq"
( PATH="$tmp/crjq:$PATH"; prov_record replace json-key "$w/s.json" --unit k --post-json '{"b":1,"a":2}' --pre-json '{"z":[1]}' --backup )
check "CRLF jq: post.sha is of the canonical bytes" "$(last | jq -r .post.sha)" "$(sha '{"a":2,"b":1}')"
check "CRLF jq: the backup holds the canonical bytes" "$(cat "$(last | jq -r .pre.backup)")" '{"z":[1]}'
check "CRLF jq: no ledger line carries a CR" "$(grep -c "$(printf '\r')" "$ledger")" "0"

# a session id that is not one safe path segment never reaches the filesystem
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_begin --iid '../evil' --writer t
prov_record replace file "$w/a.txt" --pre-file "$w/a.snap" --backup --post-file "$w/a.txt" 2>/dev/null; check "unsafe iid + --backup → rc 1" "$?" "1"
check "unsafe iid wrote no backup outside the ledger dir" "$([ -e "$HIMMEL_PROVENANCE_DIR/evil" ] && echo yes || echo no)" "no"
unset HIMMEL_PROVENANCE_IID _PROV_OWNS

# a POSIX filename may contain a backslash; only Windows treats it as a separator
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "SKIP - Windows: a backslash is a path separator here" ;;
    *)
        rm -rf "$HIMMEL_PROVENANCE_DIR"
        prov_record create file "$w"'/a\b' --post-json '"x"'
        check "POSIX backslash filename is recorded as given" "$(last | jq -r .path)" "$w"'/a\b'
        ;;
esac

# a hasher that fails must fail the record, never write an empty sha (no pipefail in this shell)
rm -rf "$HIMMEL_PROVENANCE_DIR"
mkdir -p "$tmp/badsha"; printf '#!/bin/sh\nexit 1\n' > "$tmp/badsha/sha256sum"; chmod +x "$tmp/badsha/sha256sum"
( PATH="$tmp/badsha:$PATH"; prov_record create file "$w/a.txt" --post-file "$w/a.txt" 2>/dev/null ); check "failing sha256sum on a file → rc 1" "$?" "1"
( PATH="$tmp/badsha:$PATH"; prov_record replace json-key "$w/s.json" --unit k --post-json '{"a":1}' 2>/dev/null ); check "failing sha256sum on json → rc 1" "$?" "1"
n=$(grep -sc '"sha":""' "$ledger"); check "failing sha256sum left no row with an empty sha" "${n:-0}" "0"
check "failing sha256sum left no artifact row" "$(jq -r .op "$ledger" 2>/dev/null | grep -vc 'install-')" "0"

# op / kind are exact tokens, not substrings of the vocabulary list
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_record "create replace" file "$w/a.txt" 2>/dev/null; check "quoted two-word op → rc 2" "$?" "2"
prov_record create "file tree" "$w/a.txt" 2>/dev/null; check "quoted two-word kind → rc 2" "$?" "2"
check "rejected op/kind wrote nothing" "$([ -e "$ledger" ] && echo yes || echo no)" "no"

# a record at the filesystem root keeps its path
rm -rf "$HIMMEL_PROVENANCE_DIR"
prov_record register mcp / --unit m --post-json '"x"'
check "path '/' is recorded as /" "$(last | jq -r .path)" "/"

# a Windows drive root keeps its slash and is not split into the bare "C:" (the drive's
# cwd); fixture: a directory literally named "C:" (a real drive root needs Windows)
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) echo "SKIP - Windows: 'C:/' is a real drive root here" ;;
    *)
        rm -rf "$HIMMEL_PROVENANCE_DIR" "$tmp/drv"; mkdir -p "$tmp/drv/C:"
        ( cd "$tmp/drv" && prov_record register mcp 'C:/' --unit m --post-json '"x"' )
        check "drive root 'C:/' is recorded as the root itself" "$(last | jq -r .path)" "$(cd "$tmp/drv/C:" && pwd -P)/"
        ;;
esac

# a pre-existing group/world-readable ledger is tightened to 0600 by the next append
rm -rf "$HIMMEL_PROVENANCE_DIR"; mkdir -p "$HIMMEL_PROVENANCE_DIR"; : > "$ledger"; chmod 644 "$ledger"
prov_record register mcp - --unit m --post-json '"x"'
check "existing 0644 ledger is tightened to 0600" "$(fmode "$ledger")" "600"

# a symlink input records the TARGET's mode, like its sha and size (node follows it too)
rm -rf "$HIMMEL_PROVENANCE_DIR"; printf 'abc' > "$w/tgt"; chmod 640 "$w/tgt"; ln -s "$w/tgt" "$w/lnk"
prov_record create file "$w/dst" --post-file "$w/lnk"
check "symlink --post-file records the target's mode" "$(last | jq -r .post.mode)" "0640"

# a symlink at the ledger is refused before any chmod or append lands in its target
rm -rf "$HIMMEL_PROVENANCE_DIR"; mkdir -p "$HIMMEL_PROVENANCE_DIR"
printf 'keep\n' > "$w/victim"; chmod 644 "$w/victim"; ln -s "$w/victim" "$ledger"
err=$(prov_record register mcp - --unit m --post-json '"x"' 2>&1 >/dev/null); rc=$?
check "symlink ledger → rc 1" "$rc" "1"
check "symlink ledger is a provenance: diagnostic" "${err%%:*}" "provenance"
check "symlink ledger target is byte-identical" "$(cat "$w/victim")" "keep"
check "symlink ledger target mode is untouched" "$(fmode "$w/victim")" "644"
rm -f "$ledger"; ln -s "$w/nowhere" "$ledger"
prov_record register mcp - --unit m --post-json '"x"' 2>/dev/null; rc=$?
check "dangling symlink ledger → rc 1" "$rc" "1"
check "dangling symlink ledger creates nothing through the link" "$([ -e "$w/nowhere" ] && echo yes || echo no)" "no"

# a symlink at the backup dir (or its parent) is refused before anything is copied through it
rm -rf "$HIMMEL_PROVENANCE_DIR" "$w/bkvictim"; mkdir -p "$HIMMEL_PROVENANCE_DIR/provenance-backups" "$w/bkvictim"
printf 'pre\n' > "$w/pre.txt"; iid=20260921T000000Z-aaaaaa
ln -s "$w/bkvictim" "$HIMMEL_PROVENANCE_DIR/provenance-backups/$iid"
err=$(HIMMEL_PROVENANCE_IID=$iid prov_record replace file "$w/pre.txt" --pre-file "$w/pre.txt" --backup --post-file "$w/pre.txt" 2>&1 >/dev/null); rc=$?
check "symlink backup dir → rc 1" "$rc" "1"
check "symlink backup dir is a provenance: diagnostic" "${err%%:*}" "provenance"
check "nothing was copied through the symlink backup dir" "$(find "$w/bkvictim" -mindepth 1 | wc -l | tr -d ' ')" "0"
rm -rf "$HIMMEL_PROVENANCE_DIR/provenance-backups"; ln -s "$w/bkvictim" "$HIMMEL_PROVENANCE_DIR/provenance-backups"
HIMMEL_PROVENANCE_IID=$iid prov_record replace file "$w/pre.txt" --pre-file "$w/pre.txt" --backup --post-file "$w/pre.txt" 2>/dev/null; rc=$?
check "symlink provenance-backups parent → rc 1" "$rc" "1"
check "nothing was copied through the symlink parent" "$(find "$w/bkvictim" -mindepth 1 | wc -l | tr -d ' ')" "0"

# the lib hashes on a host with no sha256sum (stock macOS has only shasum)
if ! command -v shasum >/dev/null 2>&1; then echo "SKIP - no shasum to exercise the sha256sum-less path"; else
    rm -rf "$tmp/nosha"; mkdir -p "$tmp/nosha"
    for t in bash sh jq shasum perl git uname date stat tail wc tr cp chmod mkdir cat sed awk grep dirname basename readlink rm ls printf mktemp dd; do
        p=$(command -v "$t" 2>/dev/null) && [ -x "$p" ] && ln -s "$p" "$tmp/nosha/$t"
    done
    check "control: the stub PATH has no sha256sum" "$(PATH="$tmp/nosha" command -v sha256sum >/dev/null 2>&1 && echo present || echo absent)" "absent"
    check "_prov_sha256 without sha256sum returns only the digest" "$(printf 'abc' | PATH="$tmp/nosha" _prov_sha256)" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    rm -rf "$HIMMEL_PROVENANCE_DIR"; printf 'abc' > "$w/sh.txt"
    ( PATH="$tmp/nosha" prov_record create file "$w/sh.txt" --post-file "$w/sh.txt" ); rc=$?
    check "prov_record without sha256sum → rc 0" "$rc" "0"
    check "prov_record without sha256sum records the right sha" "$(last | jq -r .post.sha)" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
fi

# ── HIMMEL-3347 ───────────────────────────────────────────────────────────
# (1) a row longer than a stdio buffer must still land in ONE write(2): the row goes through
# `dd bs=<row bytes>` (one read, one write to the O_APPEND descriptor), not the printf builtin's
# 4 KiB chunks. A dd spy pins the mechanism; the concurrent-writer run pins the behaviour.
rm -rf "$HIMMEL_PROVENANCE_DIR" "$tmp/spy"; mkdir -p "$tmp/spy"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/dd.calls"\nexec "%s" "$@"\n' "$tmp" "$(command -v dd)" > "$tmp/spy/dd"; chmod +x "$tmp/spy/dd"
rm -f "$tmp/dd.calls"
bigfield=$(head -c 20000 /dev/zero | tr '\0' x)
( PATH="$tmp/spy:$PATH"; prov_record create file "$w/a.txt" --post-file "$w/a.txt" --field "big=\"$bigfield\"" ); rc=$?
check "large row: rc" "$rc" "0"
check "large row: the ledger row parses" "$(last | jq -r '.big | length')" "20000"
rowbytes=$(last | wc -c | tr -d ' ')
ddbs=$(sed -n 's/.*bs=\([0-9][0-9]*\).*/\1/p' "$tmp/dd.calls" 2>/dev/null | sort -n | tail -n1)
check "large row: appended by one dd whose block covers the whole row" "$([ -n "$ddbs" ] && [ "$ddbs" -ge "$rowbytes" ] && echo yes || echo "no (bs=${ddbs:-none} row=$rowbytes)")" "yes"
leftover=0
for f in "$HIMMEL_PROVENANCE_DIR"/.append.*; do [ -e "$f" ] && leftover=$((leftover + 1)); done
check "large row: no temp file left behind" "$leftover" "0"
rm -rf "$HIMMEL_PROVENANCE_DIR"; mkdir -p "$HIMMEL_PROVENANCE_DIR"
pad=$(head -c 30000 /dev/zero | tr '\0' y)
for wn in 1 2 3 4 5 6 7 8; do
    ( i=0; while [ "$i" -lt 25 ]; do _prov_append "$(jq -nc --argjson w "$wn" --argjson i "$i" --arg pad "$pad" '{w:$w,i:$i,pad:$pad}')" || exit 1; i=$((i + 1)); done ) &
done
wait
check "8 concurrent writers x 25 large rows: every row landed" "$(grep -c . "$ledger")" "200"
check "8 concurrent writers x 25 large rows: every row parses" "$(jq -c . "$ledger" >/dev/null 2>&1; echo $?)" "0"

# (2) a subshell of the opener inherits _PROV_OWNS but is not the owner: its prov_end is a no-op.
rm -rf "$HIMMEL_PROVENANCE_DIR"; unset HIMMEL_PROVENANCE_IID _PROV_OWNS
prov_begin --writer sub --iid SUB1
( prov_end ok ); check "subshell prov_end rc" "$?" "0"
check "subshell prov_end wrote no install-end" "$(grep -c '"op":"install-end"' "$ledger")" "0"
check "subshell prov_end left the session open" "${HIMMEL_PROVENANCE_IID:-unset}" "SUB1"
: "$(prov_end failed)"
check "command-substitution prov_end wrote no install-end" "$(grep -c '"op":"install-end"' "$ledger")" "0"
prov_end ok; check "the opener's prov_end rc" "$?" "0"
check "the opener's prov_end wrote exactly one install-end" "$(grep -c '"op":"install-end"' "$ledger")" "1"
check "the opener's prov_end closed the session" "${HIMMEL_PROVENANCE_IID:-unset}" "unset"
( prov_begin --writer own --iid SUB2; prov_end ok ); check "a subshell that opens its own session closes it" "$(grep -c '"iid":"SUB2","op":"install-end"' "$ledger")" "1"

# ── HIMMEL-3556 ───────────────────────────────────────────────────────────
# prov_ledger_registered_ours: a register row counts as ours only after the
# most recent uninstall-begin boundary (or from the ledger's start, if none).
rm -f "$ledger"
_prov_append '{"op":"register","kind":"marketplace","unit":"himmel","preexisted":false}'
check "registered_ours: no boundary yet, a register row counts as ours" \
    "$(prov_ledger_registered_ours marketplace himmel >/dev/null 2>&1 && echo yes || echo no)" "yes"
_prov_append '{"op":"uninstall-begin"}'
check "registered_ours: a register row before the boundary is NOT ours (operator re-added)" \
    "$(prov_ledger_registered_ours marketplace himmel >/dev/null 2>&1 && echo yes || echo no)" "no"
_prov_append '{"op":"register","kind":"marketplace","unit":"himmel","preexisted":false}'
check "registered_ours: a register row after the boundary IS ours" \
    "$(prov_ledger_registered_ours marketplace himmel >/dev/null 2>&1 && echo yes || echo no)" "yes"
rm -f "$ledger"
_prov_append '{"op":"uninstall-begin"}'
_prov_append '{"op":"register","kind":"marketplace","unit":"himmel","preexisted":true}'
check "registered_ours: preexisted=true after the boundary is NOT ours" \
    "$(prov_ledger_registered_ours marketplace himmel >/dev/null 2>&1 && echo yes || echo no)" "no"

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
