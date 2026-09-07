#!/usr/bin/env bash
# Suite for scripts/observability/agent-runtime-census.{ps1,sh} (HIMMEL-1988).
#
# Canned fixtures only. Every case below pins OUR contract - the supervisor /
# fleet-root / duplicate classification, the exe+first-arg redaction, the
# family counts, the poolmon tag rollup and the JSONL append shape - by
# feeding the script a synthetic process table and a synthetic poolmon dump
# through its documented test-only seams (-FixtureProcesses / -FixturePoolmon).
# Nothing here re-proves Win32_Process, Get-Counter or poolmon themselves:
# in fixture mode those live probes are skipped and their fields come out null.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/agent-runtime-census.sh"
PS1_FILE="$SCRIPT_DIR/agent-runtime-census.ps1"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected '$want', got '$got'"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
    msys*|cygwin*|win32*|MINGW*|MSYS*) ;;
    *)
        echo "SKIP: agent-runtime-census is Windows-only (Win32_Process/Get-Counter/poolmon)"
        exit 0
        ;;
esac
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available (used to parse the JSONL)"; exit 0; }

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t arc)"
PROCS="$TMP_ROOT/procs.json"
POOL="$TMP_ROOT/poolmon.txt"
OUT="$TMP_ROOT/census.jsonl"

winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# Read one JSONL line and evaluate a JS expression over the parsed object `o`.
jread() {
    node -e '
      const fs = require("fs");
      const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n");
      const o = JSON.parse(lines[Number(process.argv[2])]);
      const v = (new Function("o", "return (" + process.argv[3] + ")"))(o);
      process.stdout.write(typeof v === "object" ? JSON.stringify(v) : String(v));
    ' "$1" "$2" "$3" 2>/dev/null
}

# --- fixtures --------------------------------------------------------------
# One codex supervisor with a duplicated MCP identity, a bun root with its own
# subtree, and a cmd.exe wrapper (deliberately NOT a fleet root); one claude
# supervisor with a credential-shaped first argument, a post-`--` payload and
# two uvx servers distinguished only past their flags; and one unrelated
# explorer.exe subtree whose node.exe child must never count as a fleet root.
cat > "$PROCS" <<'JSON'
[
  {"ProcessId":100,"ParentProcessId":4,"Name":"codex.exe","CommandLine":"codex.exe app-server","CreationDate":"2026-08-21T04:00:00Z","WorkingSetSize":209715200},
  {"ProcessId":101,"ParentProcessId":100,"Name":"node.exe","CommandLine":"\"C:\\srv\\node.exe\" C:\\srv\\mcp\\index.js --api-key=AKIAZZZZZZZZZZZZZZZZ","CreationDate":"2026-08-21T04:01:00Z","WorkingSetSize":104857600},
  {"ProcessId":102,"ParentProcessId":100,"Name":"node.exe","CommandLine":"\"C:\\srv\\node.exe\" C:\\srv\\mcp\\index.js --port 9002","CreationDate":"2026-08-21T04:20:00Z","WorkingSetSize":52428800},
  {"ProcessId":103,"ParentProcessId":100,"Name":"node_repl.exe","CommandLine":"node_repl.exe --stdio","CreationDate":"2026-08-21T04:02:00Z","WorkingSetSize":31457280},
  {"ProcessId":104,"ParentProcessId":100,"Name":"bun.exe","CommandLine":"bun.exe C:\\cache\\qmd\\server.ts start","CreationDate":"2026-08-21T04:03:00Z","WorkingSetSize":41943040},
  {"ProcessId":105,"ParentProcessId":104,"Name":"bash.exe","CommandLine":"bash.exe -lc hook","CreationDate":"2026-08-21T04:04:00Z","WorkingSetSize":10485760},
  {"ProcessId":106,"ParentProcessId":105,"Name":"git.exe","CommandLine":"git.exe status","CreationDate":"2026-08-21T04:05:00Z","WorkingSetSize":5242880},
  {"ProcessId":110,"ParentProcessId":104,"Name":"conhost.exe","CommandLine":"conhost.exe","CreationDate":"2026-08-21T04:00:00Z","WorkingSetSize":99999999},
  {"ProcessId":107,"ParentProcessId":100,"Name":"cmd.exe","CommandLine":"cmd.exe /c npx some-mcp","CreationDate":"2026-08-21T04:06:00Z","WorkingSetSize":2097152},
  {"ProcessId":109,"ParentProcessId":100,"Name":"python.exe","CommandLine":"python.exe -c \"import sys; print(sys.hunter2path)\"","CreationDate":"2026-08-21T04:07:00Z","WorkingSetSize":26214400},
  {"ProcessId":108,"ParentProcessId":100,"Name":"node.exe","CommandLine":"node.exe C:\\stale\\old.js","CreationDate":"2026-08-21T03:50:00Z","WorkingSetSize":1048576},
  {"ProcessId":200,"ParentProcessId":4,"Name":"claude.exe","CommandLine":"claude.exe","CreationDate":"2026-08-21T03:00:00Z","WorkingSetSize":838860800},
  {"ProcessId":201,"ParentProcessId":200,"Name":"qmd.exe","CommandLine":"qmd.exe sk-AAAABBBBCCCCDDDD1111 -- --prompt hunter2secretpayload","CreationDate":"2026-08-21T03:10:00Z","WorkingSetSize":20971520},
  {"ProcessId":202,"ParentProcessId":200,"Name":"uvx.exe","CommandLine":"uvx --with mcp==1.28.1 mcp-obsidian","CreationDate":"2026-08-21T03:11:00Z","WorkingSetSize":5242880},
  {"ProcessId":203,"ParentProcessId":200,"Name":"uvx.exe","CommandLine":"uvx --with mcp==1.28.1 mcp-other","CreationDate":"2026-08-21T03:12:00Z","WorkingSetSize":5242880},
  {"ProcessId":204,"ParentProcessId":200,"Name":"qmd.exe","CommandLine":"qmd.exe --prompt hunter4_free_text --port 7777","CreationDate":"2026-08-21T03:13:00Z","WorkingSetSize":5242880},
  {"ProcessId":205,"ParentProcessId":200,"Name":"qmd.exe","CommandLine":"qmd.exe /token:hunter5secret","CreationDate":"2026-08-21T03:14:00Z","WorkingSetSize":5242880},
  {"ProcessId":206,"ParentProcessId":200,"Name":"node.exe","CommandLine":"node.exe --opt \"a \\\"hunter6secret\\\" b\" srv.js","CreationDate":"2026-08-21T03:15:00Z","WorkingSetSize":5242880},
  {"ProcessId":207,"ParentProcessId":200,"Name":"tokensave.exe","CommandLine":"tokensave.exe sk-ant-api03-hunter7secretkeyvalue","CreationDate":"2026-08-21T03:16:00Z","WorkingSetSize":5242880},
  {"ProcessId":208,"ParentProcessId":200,"Name":"npx.exe","CommandLine":"npx.exe -y server-a","CreationDate":"2026-08-21T03:17:00Z","WorkingSetSize":5242880},
  {"ProcessId":209,"ParentProcessId":200,"Name":"npx.exe","CommandLine":"npx.exe -y server-b","CreationDate":"2026-08-21T03:18:00Z","WorkingSetSize":5242880},
  {"ProcessId":210,"ParentProcessId":200,"Name":"qmd.exe","CommandLine":"qmd.exe -phunter8secret","CreationDate":"2026-08-21T03:19:00Z","WorkingSetSize":5242880},
  {"ProcessId":300,"ParentProcessId":4,"Name":"explorer.exe","CommandLine":"explorer.exe","CreationDate":"2026-08-21T02:00:00Z","WorkingSetSize":104857600},
  {"ProcessId":301,"ParentProcessId":300,"Name":"node.exe","CommandLine":"node.exe C:\\other\\srv.js","CreationDate":"2026-08-21T02:30:00Z","WorkingSetSize":15728640},
  {"ProcessId":302,"ParentProcessId":300,"Name":"bash.exe","CommandLine":"bash.exe -i","CreationDate":"2026-08-21T02:31:00Z","WorkingSetSize":8388608}
]
JSON

# poolmon dump in the real column layout (see .tmp-poolsnap-postreboot-*.log).
# `File` appears as BOTH a Nonp and a Paged row - the rollup must SUM them,
# not take the first row (station-ops/pool/pool-rate.ps1's own note).
cat > "$POOL" <<'DUMP'
 Memory:49371552K Avail:26121028K  PageFlts:901597864   InRam Krnl:76500K P:4130272K
 Commit:35762700K Limit:64575904K Peak:43634092K            Pool N:2275124K P:4427892K

 Tag  Type     Allocs            Frees               Diff            Bytes                 Per Alloc

 FMfn Paged            8665967            5982729           2683238     1495080176              557
 File Nonp            44288592           43651808            636784      254683680              399
 File Paged                 100                 40                60           4000               66
 Toke Paged             1000000             900000            100000      120000000             1200
 SeAt Paged             2000000            1900000            100000       20000000              200
 SeTd Paged                 500                 100               400          40000              100
 SeTl Nonp                  600                 200               400          80000              200
 MmSt Paged            1624294            1189612            434682      515671920             1186
DUMP

run_census() {
    bash "$SCRIPT" -FixtureProcesses "$(winpath "$PROCS")" -FixturePoolmon "$(winpath "$POOL")" \
        -OutFile "$(winpath "$OUT")" -Label fixture-harness
}

echo "=== 1. the script is report-only ==="
# The whole premise of this collector is that it never touches a process.
# Grep the .ps1 for process-control verbs; the character classes keep this
# file's own text from matching a naive destructive-command scanner.
banned="$(grep -nE 'Stop-Proces[s]|task[k]ill|\.Kil[l]\(' "$PS1_FILE" || true)"
assert_eq "no process-control verb in the collector" "" "$banned"

echo "=== 2. one snapshot per invocation, appended as valid JSON ==="
run_census >/dev/null 2>&1
rc1=$?
assert_eq "first invocation exits 0" "0" "$rc1"
assert_eq "first invocation writes exactly one line" "1" "$(grep -c . "$OUT")"
run_census >/dev/null 2>&1
assert_eq "second invocation appends (two lines total)" "2" "$(grep -c . "$OUT")"
valid=0
while read -r line; do
    printf '%s' "$line" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s);})' 2>/dev/null && valid=$((valid+1))
done < "$OUT"
assert_eq "every line parses as JSON" "2" "$valid"
assert_eq "schema tag" "agent-runtime-census/1" "$(jread "$OUT" 0 'o.schema')"
assert_eq "label is carried into the row" "fixture-harness" "$(jread "$OUT" 0 'o.label')"
assert_eq "timestamp is UTC ISO-8601" "true" "$(jread "$OUT" 0 '/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(o.ts_utc)')"

echo "=== 3. supervisor + MCP fleet-root classification ==="
assert_eq "both supervisors found" "2" "$(jread "$OUT" 0 'o.supervisors.length')"
assert_eq "supervisor exes" '["codex.exe","claude.exe"]' "$(jread "$OUT" 0 'o.supervisors.map(s=>s.exe)')"
assert_eq "codex fleet roots (cmd.exe wrapper excluded)" "5" "$(jread "$OUT" 0 'o.supervisors[0].mcp_root_count')"
assert_eq "claude fleet roots" "10" "$(jread "$OUT" 0 'o.supervisors[1].mcp_root_count')"
assert_eq "cmd.exe wrapper is not a fleet root" "false" "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.some(r=>r.pid===107)')"
assert_eq "a node.exe under a non-supervisor is not a fleet root" "false" \
    "$(jread "$OUT" 0 'JSON.stringify(o.supervisors).includes("\"pid\":301")')"
assert_eq "a child that predates its supervisor is a stale PPID, not a fleet root" "false" \
    "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.some(r=>r.pid===108)')"
assert_eq "fleet-root creation time is kept" "2026-08-21T04:01:00Z" \
    "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.find(r=>r.pid===101).created_utc')"
assert_eq "bun root descendant count" "2" \
    "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.find(r=>r.pid===104).descendants')"
assert_eq "bun root descendant working set (MB)" "15" \
    "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.find(r=>r.pid===104).descendant_working_set_mb')"
# pid 110 records bun (04:03) as its parent but started at 04:00 - a reused pid,
# not a descendant. Counting it would inflate both the count and the ~95 MB.

echo "=== 4. duplicate counts per MCP group ==="
assert_eq "one duplicate group under codex" "1" "$(jread "$OUT" 0 'o.supervisors[0].duplicate_groups.length')"
assert_eq "duplicate identity" "node.exe index.js" "$(jread "$OUT" 0 'o.supervisors[0].duplicate_groups[0].identity')"
assert_eq "duplicate count" "2" "$(jread "$OUT" 0 'o.supervisors[0].duplicate_groups[0].count')"
assert_eq "duplicate pids" '[101,102]' "$(jread "$OUT" 0 'o.supervisors[0].duplicate_groups[0].pids')"
assert_eq "two uvx/npx servers that differ only past the flags are NOT duplicates" "0" \
    "$(jread "$OUT" 0 'o.supervisors[1].duplicate_groups.length')"
# `npx -y <pkg>` is the most common MCP launch shape: treating the boolean `-y`
# as value-taking would identify every npx server as `npx.exe -y` and group them
# as duplicates - a false positive exactly where the census matters. The list is
# known-boolean only; an UNKNOWN flag still suppresses its value (pid 204 above).
assert_eq "npx -y server-a identifies by its package" "npx.exe server-a" "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===208).identity')"
assert_eq "npx -y server-b identifies by its package" "npx.exe server-b" "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===209).identity')"
assert_eq "leading value-taking flags are skipped when identifying a server" "uvx.exe mcp-obsidian" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===202).identity')"
assert_eq "an all-flags command line falls back to its first flag" "node_repl.exe --stdio" \
    "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.find(r=>r.pid===103).identity')"

echo "=== 5. redaction: exe + first argument only ==="
assert_eq "credential-shaped arg in the AWS-key shape never reaches the row" "0" \
    "$(grep -c 'AKIAZZZZZZZZZZZZZZZZ' "$OUT")"
assert_eq "everything after a bare -- is dropped" "0" "$(grep -c 'hunter2secretpayload' "$OUT")"
assert_eq "a credential-shaped first argument is redacted" "[REDACTED]" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots[0].first_arg')"
assert_eq "identity keeps the exe and the redacted arg" "qmd.exe [REDACTED]" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots[0].identity')"
assert_eq "a path-shaped first argument is reduced to its leaf" "index.js" \
    "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.find(r=>r.pid===101).first_arg')"
assert_eq "no later argument survives" "0" "$(grep -c -- '--port' "$OUT")"
assert_eq "no full command line is stored" "false" \
    "$(jread "$OUT" 0 'JSON.stringify(o).toLowerCase().includes("commandline")')"
# A code-carrying flag (`python -c`, `node -e`) puts a PROGRAM in the position
# where an identity would otherwise be read. It must never be recorded.
assert_eq "a -c payload never reaches the row" "0" "$(grep -c 'hunter2path' "$OUT")"
assert_eq "a -c command line identifies as the flag alone" "python.exe -c" \
    "$(jread "$OUT" 0 'o.supervisors[0].mcp_roots.find(r=>r.pid===109).identity')"
# The token after an UNKNOWN flag is where a prompt/credential sits, so every
# flag is treated as value-taking - no enumerated list can be safe here.
assert_eq "the value of an unknown flag never reaches the row" "0" "$(grep -c 'hunter4_free_text' "$OUT")"
assert_eq "an unknown flag's value is not mistaken for an identity" "qmd.exe --prompt" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===204).identity')"
# A Windows-style `/flag:value` switch reads as positional to a `-` test, and an
# escaped quote inside a flag value can split a naive tokenizer into fragments.
assert_eq "a /flag:value switch keeps only the flag name" "0" "$(grep -c 'hunter5secret' "$OUT")"
assert_eq "the /flag:value identity" "qmd.exe token" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===205).identity')"
assert_eq "an escaped quote inside a flag value leaks no fragment" "0" "$(grep -c 'hunter6secret' "$OUT")"
# HIMMEL-1997: a short flag whose value is GLUED (`-psecret`) and is the ONLY
# argument reaches the first-flag fallback with nothing to cut at and no next
# token to step over - the flag letter is all that may be kept. `python.exe -c`
# above pins the other half: a 2-char short flag is left alone.
assert_eq "a glued short-flag value never reaches the row" "0" "$(grep -c 'hunter8secret' "$OUT")"
assert_eq "a glued short flag identifies by its letter alone" "qmd.exe -p" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===210).identity')"
# Modern keys are hyphenated (`sk-ant-…`, `sk-proj-…`); an alphanumeric-only
# class misses them entirely.
assert_eq "a hyphenated sk- key is scrubbed" "0" "$(grep -c 'hunter7secretkeyvalue' "$OUT")"
assert_eq "the scrubbed key leaves a redaction marker" "tokensave.exe [REDACTED]" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===207).identity')"
assert_eq "the escaped-quote command line still identifies by its script" "node.exe srv.js" \
    "$(jread "$OUT" 0 'o.supervisors[1].mcp_roots.find(r=>r.pid===206).identity')"

echo "=== 6. process-family counts ==="
assert_eq "bash" "2" "$(jread "$OUT" 0 'o.families.bash')"
assert_eq "node (node_repl.exe is a different stem)" "5" "$(jread "$OUT" 0 'o.families.node')"
assert_eq "bun" "1" "$(jread "$OUT" 0 'o.families.bun')"
assert_eq "cmd" "1" "$(jread "$OUT" 0 'o.families.cmd')"
assert_eq "git" "1" "$(jread "$OUT" 0 'o.families.git')"
assert_eq "an absent family reports zero, not missing" "0" "$(jread "$OUT" 0 'o.families.wsl')"
assert_eq "process total" "25" "$(jread "$OUT" 0 'o.process_total')"

echo "=== 7. poolmon tag rollup ==="
assert_eq "File sums its Nonp AND Paged rows (outstanding)" "636844" "$(jread "$OUT" 0 'o.pool_tags.File.outstanding')"
assert_eq "File sums its Nonp AND Paged rows (bytes)" "254687680" "$(jread "$OUT" 0 'o.pool_tags.File.bytes')"
assert_eq "a tag seen in both pools is marked both" "both" "$(jread "$OUT" 0 'o.pool_tags.File.type')"
assert_eq "FMfn outstanding" "2683238" "$(jread "$OUT" 0 'o.pool_tags.FMfn.outstanding')"
assert_eq "Toke type" "Paged" "$(jread "$OUT" 0 'o.pool_tags.Toke.type')"
assert_eq "all six tracked tags present" '["FMfn","File","Toke","SeAt","SeTd","SeTl"]' "$(jread "$OUT" 0 'Object.keys(o.pool_tags)')"
assert_eq "an untracked tag is ignored" "false" "$(jread "$OUT" 0 'Object.keys(o.pool_tags).includes("MmSt")')"
assert_eq "the poolmon artifact is pointed at" "true" \
    "$(jread "$OUT" 0 'String(o.poolmon_artifact).toLowerCase().includes("poolmon.txt")')"

echo "=== 8. the two snapshots are comparable ==="
assert_eq "second row has the same fleet generation" "true" \
    "$(node -e '
       const fs=require("fs");
       const [a,b]=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse);
       const ids=o=>JSON.stringify(o.supervisors.map(s=>s.mcp_roots.map(r=>[r.pid,r.created_utc])));
       process.stdout.write(String(ids(a)===ids(b)));
     ' "$OUT")"

echo "=== 9. fixture mode stays hermetic ==="
# -FixtureProcesses alone must not fall through to the host's poolmon.
( cd "$TMP_ROOT" && bash "$SCRIPT" -FixtureProcesses "$(winpath "$PROCS")" -OutFile "$(winpath "$TMP_ROOT/nopool.jsonl")" -Label fixture-harness >/dev/null 2>&1 )
assert_eq "no poolmon artifact without -FixturePoolmon" "null" "$(jread "$TMP_ROOT/nopool.jsonl" 0 'o.poolmon_artifact')"
assert_eq "no pool rows without -FixturePoolmon" "0" "$(jread "$TMP_ROOT/nopool.jsonl" 0 'Object.keys(o.pool_tags).length')"

echo "=== 10. usage contract ==="
# Unlabelled evidence cannot be attributed to a harness later, which is the one
# thing this program's notes insist on - so it is refused, not defaulted.
nolabel_out="$(bash "$SCRIPT" -FixtureProcesses "$(winpath "$PROCS")" -OutFile "$(winpath "$TMP_ROOT/nolabel.jsonl")" 2>&1)"
nolabel_rc=$?
assert_eq "a run without -Label fails" "1" "$nolabel_rc"
case "$nolabel_out" in
    *"-Label is required"*) pass "the refusal names -Label" ;;
    *) fail "the refusal names -Label" "got: $nolabel_out" ;;
esac
assert_eq "the refused run writes no row" "1" "$([ -f "$TMP_ROOT/nolabel.jsonl" ] && echo 0 || echo 1)"

# A relative -OutFile must land next to the caller, not break on an empty
# parent path (which is what the poolmon artifact path used to trip over).
( cd "$TMP_ROOT" && bash "$SCRIPT" -FixtureProcesses "$(winpath "$PROCS")" -OutFile relative.jsonl -Label fixture-harness >/dev/null 2>&1 )
assert_eq "a relative -OutFile resolves against the current directory" "0" \
    "$([ -f "$TMP_ROOT/relative.jsonl" ] && echo 0 || echo 1)"

summary
