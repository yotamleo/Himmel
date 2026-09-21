#!/usr/bin/env bash
# Platform guard (gitbash-only): bash + jq + sha256sum; pwsh block skips when absent.
# test-provenance.sh -- tests for scripts/lib/provenance.sh (HIMMEL-3332 S1).
# Everything runs under a scratch HOME / HIMMEL_PROVENANCE_DIR; the real
# ~/.himmel is never read or written. The node twin and the bash<->node
# byte-identity cross-check live in scripts/himmelctl/test/test-provenance-js.sh.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fails=0
passes=0
check() { # name got want
    if [ "$2" = "$3" ]; then passes=$((passes + 1)); echo "ok - $1"
    else fails=$((fails + 1)); echo "FAIL - $1: [$2] != [$3]"; fi
}
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }  # gnu-ok: BSD stat -f paired
sha() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }

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
check "backup sha == pre bytes" "$(sha256sum "$bk" | awk '{print $1}')" "$(sha 'old-bytes
')"
check "pre.sha == backup sha" "$(last | jq -r '.pre.sha')" "$(sha256sum "$bk" | awk '{print $1}')"
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
check "json backup sha == pre.sha" "$(sha256sum "$bk" | awk '{print $1}')" "$(last | jq -r '.pre.sha')"
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

# ── pwsh twin: same scenario, same bytes ─────────────────────────────────
if command -v pwsh >/dev/null 2>&1; then
    rm -rf "$HIMMEL_PROVENANCE_DIR" "$tmp/prov-ps"
    printf 'p\n' > "$w/p.txt"
    prov_begin --iid P1 --writer t --target "$w" -- a b
    prov_record create file "$w/p.txt" --post-file "$w/p.txt" --scope project --class code --row r
    prov_record replace json-key "$w/s.json" --unit k --pre-json '{"a":1}' --backup --post-json '{"b":[2,1]}' --field container_created=false
    prov_end ok
    HIMMEL_PROVENANCE_DIR="$tmp/prov-ps" pwsh -NoProfile -Command "
        . '$here/provenance.ps1'
        Prov-Begin -Iid P1 -Writer t -Target '$w' -Argv @('a','b')
        Prov-Record create file '$w/p.txt' -PostFile '$w/p.txt' -Scope project -Class code -Row r
        Prov-Record replace json-key '$w/s.json' -Unit k -PreJson '{\"a\":1}' -Backup -PostJson '{\"b\":[2,1]}' -Field @{container_created='false'}
        Prov-End ok" >"$tmp/ps.out" 2>&1
    check "pwsh: ran" "$?" "0"
    # backup paths embed the ledger dir; normalise it before comparing bytes
    # PowerShell omits "mode" on Windows (no POSIX modes there), so drop it from both sides
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) nomode='s/,"mode":"[0-9]*"//g' ;; *) nomode='s/^//' ;; esac
    norm() { sed -e "s#$1#PROV#g" -e "$nomode" "$2"; }
    check "pwsh: rows byte-identical to bash" "$(norm "$tmp/prov-ps" "$tmp/prov-ps/provenance.jsonl" | sha256sum)" "$(norm "$HIMMEL_PROVENANCE_DIR" "$ledger" | sha256sum)"
else
    echo "SKIP - pwsh not installed: provenance.ps1 twin NOT exercised here (run: pwsh scenario in this file on a host with pwsh)"
fi

echo "$passes passed, $fails failed"
[ "$fails" -eq 0 ]
