#!/usr/bin/env bash
# orphan-census.sh — READ-ONLY census of orphaned himmel suite/probe processes.
#
# WHY (HIMMEL-1978). run-shell-tests.sh caps each suite with a watchdog that
# terminates the suite's process tree, and worker lanes time out around their
# own children. Neither reliably collects grandchildren: ~107 stray bash
# processes were alive on the OVERLORD8 box by the end of one afternoon, and
# process-spawn latency on that box swings ~10x under that load. This tells you
# which ones are actually abandoned before anyone reaches for a kill switch.
#
# A process is an ORPHAN CANDIDATE when all of these hold:
#   1. its parent PID is not in the live process list, and
#   2. its command line names a himmel suite / probe / harness script INSIDE
#      THIS checkout (see the root anchor below), and
#   3. it is older than --min-age minutes (default 10) — a young process whose
#      parent just exited is normal, not abandoned, and
#   4. it is not a check-ci / merge-on-green watcher. Those are SUPPOSED to
#      outlive the session that armed them; killing one silently drops a merge
#      gate. They are listed as WATCHER and never reaped.
#
# WHAT THE CLASSIFIER IS. A heuristic over command-line TEXT, not a shell
# parser. It knows argv[0], path boundaries and interpreter tokens; it does not
# know quoting or command semantics, so a line that QUOTES an invocation it
# never performs can still be claimed. That is precisely why the reap step is
# operator-run behind a census you read first, and why every ambiguity above is
# resolved toward claiming less.
#
# DEFAULT IS READ-ONLY. `--reap` exists for the operator; it is not usable from
# a Claude session (the destructive-command hook denies taskkill / Stop-Process
# / kill from an agent, by design). Run it yourself in a terminal, after
# reading the census.
#
# TEST SEAM. ORPHAN_CENSUS_INPUT=<file> substitutes a canned process table for
# the live one, so the classifier can be tested without spawning anything.
# The format is one record per line:
#   pid|ppid|age_seconds|start_token|command line
# The command line is last and may contain anything, including `|`. start_token
# is the process's creation time as the platform reports it, whitespace folded
# to `_`; --reap re-reads it per PID and refuses to signal a PID whose token
# has changed (that PID was recycled onto a different process).
#
# Usage:
#   bash scripts/ci/orphan-census.sh [--min-age <minutes>] [--reap]
#
# Exit codes:
#   0 — census printed (whether or not orphans were found)
#   2 — usage error, or no way to enumerate processes on this host
set -uo pipefail

MIN_AGE_MIN=10
REAP=0

usage() {
    cat >&2 <<'EOF'
Usage: orphan-census.sh [--min-age <minutes>] [--reap]

  --min-age <m>   ignore processes younger than <m> minutes (default: 10)
  --reap          terminate the reapable orphans (OPERATOR-RUN — denied from
                  a Claude session by the destructive-command hook)
EOF
    exit "${1:-2}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --min-age) [ $# -ge 2 ] || usage; MIN_AGE_MIN="$2"; shift 2 ;;
        --reap) REAP=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "orphan-census: unknown argument: $1" >&2; usage ;;
    esac
done

# The fixture seam and the kill switch must never meet. ORPHAN_CENSUS_INPUT is
# a canned table — its PIDs are literals in a test file, and by the time anyone
# runs --reap those numbers belong to whatever the OS has since assigned them.
# An inherited env var would otherwise be enough to terminate live processes.
if [ "$REAP" -eq 1 ] && [ -n "${ORPHAN_CENSUS_INPUT:-}" ]; then
    echo "orphan-census: refusing --reap with ORPHAN_CENSUS_INPUT set — a fixture's PIDs are not live PIDs" >&2
    exit 2
fi

case "$MIN_AGE_MIN" in
    ''|*[!0-9]*) echo "orphan-census: --min-age must be a non-negative integer, got: $MIN_AGE_MIN" >&2; usage ;;
esac
MIN_AGE=$(( MIN_AGE_MIN * 60 ))

# ROOT ANCHOR (HIMMEL-1995). `scripts/**/test-*.sh` and `probe-*.sh` are a
# LAYOUT, not an identity: any repo that happens to use it would be classified
# here — and, under an operator's --reap, signalled. Require the command line to
# name a path inside THIS checkout. Worktrees live at
# <primary>/.claude/worktrees/<name>, so stripping that suffix yields ONE root
# that covers the primary checkout and every worktree under it, whichever of the
# two this script was invoked from.
#
# A suite named by a RELATIVE path still classifies as long as the line shows
# the `cd` into this checkout that put it there (`cd <root> && bash scripts/…`,
# which is how nearly every live suite on the box spells itself). What no longer
# classifies is a bare relative invocation with the root nowhere on the line —
# and that is the direction to fail in: a read-only census that misses a row
# costs a re-run; a --reap that signals someone else's process does not undo.
HIM_ROOT=$(cd "$(dirname "$0")/../.." && pwd -P) \
    || { echo "orphan-census: cannot resolve the himmel checkout root" >&2; exit 2; }
HIM_ROOT="${HIM_ROOT%/.claude/worktrees/*}"
# Win32_Process spells the tree `C:\Users\...`, Git-Bash `/c/Users/...` — the
# same directory, two spellings, so both are offered to the classifier (the awk
# pass folds backslashes to `/` before matching).
HIM_ROOT_WIN=$(printf '%s' "$HIM_ROOT" | sed -E 's#^/([a-zA-Z])/#\1:/#')

WORK=$(mktemp -d) || { echo "orphan-census: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
TABLE="$WORK/procs"

if [ -n "${ORPHAN_CENSUS_INPUT:-}" ]; then
    [ -r "$ORPHAN_CENSUS_INPUT" ] || { echo "orphan-census: cannot read ORPHAN_CENSUS_INPUT=$ORPHAN_CENSUS_INPUT" >&2; exit 2; }
    cp "$ORPHAN_CENSUS_INPUT" "$TABLE"
elif command -v powershell.exe >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
    # Win32_Process is the only enumeration on Windows that carries the full
    # command line AND the parent PID; tasklist has neither together. The `|`
    # separator is safe because CommandLine is last on the line.
    PS_BIN=$(command -v powershell.exe 2>/dev/null || command -v powershell)
    # shellcheck disable=SC2016  # single quotes are required: $_ is PowerShell's
    "$PS_BIN" -NoProfile -NonInteractive -Command \
        'Get-CimInstance Win32_Process | ForEach-Object {
           $age = 0
           $born = "-"
           if ($_.CreationDate) {
             $age = [int]((Get-Date) - $_.CreationDate).TotalSeconds
             $born = $_.CreationDate.ToString("yyyyMMddHHmmss")
           }
           "{0}|{1}|{2}|{3}|{4}" -f $_.ProcessId, $_.ParentProcessId, $age, $born, ($_.CommandLine -replace "[\r\n]+"," ")
         }' 2>/dev/null | tr -d '\r' > "$TABLE"
elif command -v ps >/dev/null 2>&1; then
    # etime, not etimes: procps has both, BSD/macOS ps only has etime.
    # Format is [[dd-]hh:]mm:ss — normalised to seconds here so the classifier
    # sees one shape on every platform.
    # lstart is a FIXED five-token date ("Thu Aug 21 04:12:00 2026") however
    # the columns wrap, so args starts at $9. It is also exactly what
    # `ps -o lstart= -p <pid>` re-reads at reap time, which is why it is here.
    ps -eo pid=,ppid=,etime=,lstart=,args= 2>/dev/null | awk '
      {
        e = $3; gsub(/-/, ":", e)
        n = split(e, f, ":")
        if (n == 4)      s = f[1] * 86400 + f[2] * 3600 + f[3] * 60 + f[4]
        else if (n == 3) s = f[1] * 3600 + f[2] * 60 + f[3]
        else             s = f[1] * 60 + f[2]
        born = $4 "_" $5 "_" $6 "_" $7 "_" $8
        cmd = ""
        for (i = 9; i <= NF; i++) cmd = cmd (i > 9 ? " " : "") $i
        printf "%s|%s|%s|%s|%s\n", $1, $2, s, born, cmd
      }' > "$TABLE"
else
    echo "orphan-census: no powershell and no ps on this host — cannot enumerate processes" >&2
    exit 2
fi

[ -s "$TABLE" ] || { echo "orphan-census: process table came back empty" >&2; exit 2; }

# One awk pass: collect live PIDs, then classify. The himmel pattern is
# deliberately narrow — a generic "bash" match would sweep in the operator's
# own shells, and this list is read by someone about to kill things.
#
# Case folding is a WINDOWS accommodation, not a default (panel r1 codex-2):
# NTFS is case-insensitive and Win32_Process may report any casing of the drive
# letter or of a path component, but on a case-sensitive POSIX filesystem
# `/srv/Himmel` and `/srv/himmel` are two different checkouts and folding them
# together would let --reap signal a process from the wrong one. `PS_BIN` set is
# this script's own "the table came from Windows" signal.
FOLD_CASE=0
[ -z "${PS_BIN:-}" ] || FOLD_CASE=1

# The roots are passed WITHOUT a trailing slash: `cd <root> && bash scripts/…`
# from the primary checkout has whitespace after the root, not a slash, and a
# slash-terminated root could never match it (panel r4 codex-1). claimed()
# checks the boundary character itself.
awk -F'|' -v min_age="$MIN_AGE" -v root1="$HIM_ROOT" -v root2="$HIM_ROOT_WIN" \
    -v fold="$FOLD_CASE" '
  # runctx(b) — true when the text `b` preceding a rooted script path is an
  # interpreter INVOKING it, rather than one that merely mentions it. Either
  # `b` is the whole interpreter prefix (argv[0] plus flags — the quoted
  # Windows form included, which a last-space split cannot handle because the
  # path contains a space), or the interpreter token is preceded by a command
  # separator rather than by a bare word. Without this,
  # `bash -c "echo bash <root>/scripts/ci/test-x.sh; sleep 1000"` was a suite
  # (panel r10 codex-1) — the same hole the glue rule already closed on the
  # relative branch.
  function runctx(b,   t, prev) {
    if (b == "") return 1
    # `-c` disqualifies the argv[0] reading entirely: with it, the shell runs
    # the NEXT word as a command string and everything after that is $0, $1, …
    # `bash -c read <root>/scripts/ci/test-x.sh` never executes that path
    # (panel r12 codex-1). Such a line can still be claimed, but only through
    # the separator rule below — which is what an interpreter genuinely reached
    # inside a `-c` string looks like (`bash -c cd /tmp && bash <root>/…`).
    if (b !~ minusc && b ~ argv0only) return 1
    t = b
    sub("[ \042\047]+$", "", t)
    prev = t
    if (match(t, /[^ ]*$/)) prev = substr(t, 1, RSTART - 1)
    sub("[ \042\047]+$", "", prev)
    if (prev == "") return 1
    return (substr(prev, length(prev), 1) ~ "[;&|`(]")
  }

  # claimed(s, root) — true when a himmel script reference FOLLOWS an occurrence
  # of <root> on the command line, either prefixed by it or relative to it (see
  # relroot / relcwd). Testing the root and the script pattern independently was
  # not enough (panel r1 codex-1): a FOREIGN `.../scripts/ci/test-x.sh --repo
  # <this checkout>` satisfies both, anywhere on the line and in any order, and
  # would be handed to --reap. Every occurrence of the root is tried because a
  # command line may mention it more than once. Sets the global `hit` to the
  # script reference it matched, so the WATCHER test can read THAT rather than
  # the whole command line.
  function claimed(s, root,   off, p, rest, before, after, seg, q, tail, sfx) {
    if (root == "") return 0
    off = 0
    p = index(substr(s, off + 1), root)
    while (p > 0) {
      p += off
      rest = substr(s, p + length(root))
      before = substr(s, 1, p - 1)
      after = substr(rest, 1, 1)
      off = p
      p = index(substr(s, off + 1), root)
      # The root has to BE a whole path token, not a substring of one. index()
      # alone matched it mid-path, so a foreign `/jail/home/u/himmel/scripts/…`
      # satisfied a `/home/u/himmel` root (panel r3 codex-1); and on the right,
      # `<root>-old/scripts/…` is a different checkout. Either boundary failing
      # only disqualifies THIS occurrence — the loop keeps looking.
      if (off > 1 && substr(s, off - 1, 1) ~ "[A-Za-z0-9_./-]") continue
      if (after ~ "[A-Za-z0-9_.-]") continue
      # (a) the root prefixes the script path — the rest of the token after the
      #     separating slash has to be a himmel script.
      if (after == "/" && (before == "" || (before ~ runpfx && runctx(before)))) {
        tail = substr(rest, 2)
        if (match(tail, relroot) && substr(tail, RSTART, RLENGTH) !~ dotdot) {
          hit = substr(tail, RSTART, RLENGTH); return 1
        }
      }
      # (b) the relative form, which counts only where the root is being
      #     ENTERED: the characters just before it are a `cd`. Accepting it
      #     after any mention of the root was too loose (panel r2 codex-1):
      #     `foreign-tool --repo <root> --script scripts/ci/test-x.sh` named
      #     both without ever running here. The search stops at the NEXT `cd`
      #     on the line: after `cd <root> && cd /foreign && bash scripts/…` the
      #     cwd is no longer this checkout (panel r5 codex-1).
      if (before ~ cdpfx) {
        seg = rest
        # Trim the rest of the cd TARGET token, so what is left starts at the
        # shell glue: `cd <root>/sub && bash scripts/…` has to reduce to
        # ` && bash scripts/…` before relcwd sees it.
        if (substr(seg, 1, 1) != " " && substr(seg, 1, 1) != "\"") {
          q = match(seg, "[ \"]")
          sfx = (q > 0) ? substr(seg, 1, q - 1) : seg
          seg = (q > 0) ? substr(seg, q) : ""
          if (sfx ~ dotdot) seg = ""
        }
        q = match(seg, cdnext)
        if (q > 0) seg = substr(seg, 1, q - 1)
        if (match(seg, relcwd)) { hit = substr(seg, RSTART, RLENGTH); return 1 }
      }
    }
    return 0
  }
  { pid[$1] = 1; rec[NR] = $0 }
  END {
    # Anchored on the leading `/` so `/test-merge-on-green.sh` (a suite, and a
    # legitimate reap target) is not mistaken for `/merge-on-green.sh` (a live
    # merge gate), and `/probe-check-ci-escalate.sh` is not mistaken for
    # `/check-ci.sh`.
    watcher = "/check-ci\\.sh|/merge-on-green\\.sh|/merge-public-on-green\\.sh"
    # Same set, but written RELATIVE to the checkout root: claimed() applies it
    # to what FOLLOWS an occurrence of the root, so the script has to belong to
    # this checkout rather than merely be mentioned on the same line.
    # `[^ ]*` throughout — a path component cannot span the gap to a later
    # argument.
    # The trailing boundary is load-bearing: without it `.sh` matched in the
    # middle of a name, so an invoked `test-worker.sh.bak` was a suite (panel
    # r13 codex-1). A quote, whitespace, a shell operator or end-of-line ends
    # the token; another path character does not.
    script = "([^ ]*/)?(test-[^ ]*|probe-[^ ]*|quiet-run|critic-panel|run-shell-tests|dispatch-lane|check-ci|merge-on-green|merge-public-on-green)\\.sh([^A-Za-z0-9_.-]|$)"
    # (a) the root directly prefixes the script path. The optional
    #     `.claude/worktrees/<name>/` step is what makes ONE root cover the
    #     primary checkout and every worktree hanging off it.
    relroot = "^(\\.claude/worktrees/[^ /]+/)?scripts/" script
    # (b) the root was ENTERED with a `cd` and the script is named relative to
    #     it — the dominant real shape (`cd <root> && bash scripts/quiet-run.sh
    #     …`), so dropping it would miss most live suites. Three things keep it
    #     honest: the `cd` requirement (cdpfx, matched against what PRECEDES the
    #     root) rules out a foreign tool that merely passes this root as an
    #     argument; the glue-only lead rules out a word like `echo` between the
    #     cd and the interpreter; and cdnext stops the search at the next `cd`.
    #     Residual: a shell that cds here and then runs a `scripts/…` path
    #     belonging to someone else is still claimed. No tool on this box
    #     writes that line, and a path that never appears cannot be claimed at
    #     all.
    #
    # (No apostrophes below this point — the awk program is single-quoted.)
    #
    #     An INTERPRETER has to sit in front of the script either way: without
    #     it, `vim <root>/scripts/ci/test-x.sh` or a scanner reading the same
    #     file is a suite process (panel r6 codex-1), and --reap would take the
    #     editor. Optional short flags cover `bash -x <script>`; the optional
    #     quotes cover the Windows shape `"C:/Program Files/Git/bin/bash.exe"
    #     "<root>/scripts/…"` (panel r7 codex-2), whose interpreter path
    #     contains a space and whose arguments are quoted; `before == ""` covers
    #     a shebang script that IS the command.
    #     The flag part takes long options and flags that carry a value
    #     (`bash --noprofile …`, `bash -o pipefail …`) — accepting only repeated
    #     short flags dropped both from the census (panel r8 codex-2). A value
    #     word cannot swallow the script path: it may not begin with `/`.
    interp = "(bash|sh|dash|zsh|ksh)(\\.exe)?[\"]?( +-[^ \"]*( +[A-Za-z][A-Za-z0-9_-]*)?)* +[\"]?"
    runpfx = "(^|[^A-Za-z0-9_-])" interp "$"
    #     relcwd is anchored at the START of what follows the root: an optional
    #     continuation of the cd target, then SHELL GLUE only (`&& `, `; `,
    #     quotes), then the interpreter. Letting the interpreter appear anywhere
    #     after the root meant `cd <root> && echo bash scripts/ci/test-x.sh` was
    #     an invocation (panel r8 codex-1); a word like `echo` cannot pass the
    #     glue class, so it no longer is. This is still TEXT, not a shell
    #     parser — see the note in the file header.
    #     Applied to the text after the cd TARGET has been trimmed off (see
    #     claimed()), so the glue class alone leads. Two adjacent negated
    #     classes do not compose here — the first matching empty stops the
    #     second from being tried — hence the explicit trim.
    relcwd = "^[^A-Za-z0-9_./-]*" interp "(\\./)?scripts/" script
    # argv[0] has to BE an interpreter. Without this, a supervisor or launcher
    # whose ARGUMENT string happens to read `bash <root>/scripts/…` is
    # indistinguishable from the invocation it describes (panel r7 codex-1) —
    # and the description is what would be reaped. Both process enumerators
    # start the line with argv[0], so the first token settles it. Two shapes,
    # because only a quoted argv[0] may contain a space.
    argv0 = "^\"([^\"]*/)?(bash|sh|dash|zsh|ksh)(\\.exe)?\"( |$)|^([^ \"]*/)?(bash|sh|dash|zsh|ksh)(\\.exe)?( |$)"
    # The same two shapes plus flags, anchored to cover a WHOLE prefix: true
    # when everything before the script is the interpreter invocation and
    # nothing else. This is what tells `bash <root>/scripts/…` (an execution)
    # from `bash -c "echo bash <root>/scripts/…"` (a string that mentions one,
    # panel r10 codex-1). See runctx().
    argv0only = "^(\"([^\"]*/)?(bash|sh|dash|zsh|ksh)(\\.exe)?\"|([^ \"]*/)?(bash|sh|dash|zsh|ksh)(\\.exe)?)( +-[^ \"]*( +[A-Za-z][A-Za-z0-9_-]*)?)* +[\"]?$"
    # A single-dash flag bundle containing `c`, i.e. `-c` or `-xc`. Long options
    # are excluded on purpose: no bash long option takes a command string.
    minusc = "(^|[^A-Za-z0-9_-])-[A-Za-z]*c[A-Za-z]*( |$)"
    #     Optional quote after `cd ` because the real lines arrive as
    #     `eval "cd <root> && …"` — one non-path character is allowed there.
    cdpfx = "(^|[^A-Za-z0-9_.-])cd +[^A-Za-z0-9_/.-]?$"
    #     The same `cd` token, unanchored — used to cut the search short at the
    #     point the command line changes directory again.
    cdnext = "(^|[^A-Za-z0-9_.-])cd +"
    #     A `..` component walks back OUT of the checkout, so a path that
    #     starts at the root proves nothing: `cd <root>/../foreign && bash
    #     scripts/…` and `<root>/scripts/../../foreign/test-x.sh` both left it
    #     (panel r9 codex-1). Checked on the part of the path that follows the
    #     root, in both branches.
    dotdot = "(^|/)\\.\\.(/|$)"
    if (fold + 0 == 1) { root1 = tolower(root1); root2 = tolower(root2) }
    for (i = 1; i <= NR; i++) {
      n = split(rec[i], f, "|")
      p = f[1]; pp = f[2]; age = f[3]; born = f[4]
      cmd = f[5]
      for (j = 6; j <= n; j++) cmd = cmd "|" f[j]
      # Windows reports its own scripts with backslashes; the patterns below
      # are written with `/` because that is how every other platform (and
      # Git-Bash itself) spells them. Normalise once, match once.
      gsub(/\\/, "/", cmd)
      # The root is compared with index(), not a regex: a checkout path can
      # contain `+` (worktree directories do) and other regex metacharacters.
      key = (fold + 0 == 1) ? tolower(cmd) : cmd
      # A shebang script run directly is its own argv[0]; anything else has to
      # be launched by a shell for the paths below to mean execution. The root
      # comparison is substr(), not a regex, for the same reason as in
      # claimed(): a checkout path may carry regex metacharacters.
      head = key
      if (substr(head, 1, 1) == "\"") head = substr(head, 2)
      if (key !~ argv0 \
          && substr(head, 1, length(root1)) != root1 \
          && substr(head, 1, length(root2)) != root2) continue
      hit = ""
      if (!claimed(key, root1) && !claimed(key, root2)) continue
      # Dead parent. Two shapes, because the platforms differ: on Windows the
      # ppid simply dangles (nothing reparents), while POSIX reparents an
      # orphan onto init/launchd — so a live ppid of 1 (or 0) is exactly the
      # orphaned case there, not a live parent. Without this the POSIX branch
      # would never report the processes it exists to find. A himmel suite
      # script legitimately parented to init does not happen; the command-line
      # filter above already excludes real daemons.
      if ((pp in pid) && pp + 0 > 1) continue
      if (age + 0 < min_age) { young++; continue }
      # `hit` — the script reference claimed() actually matched — not the whole
      # command line: a suite whose ARGUMENTS merely mention `/check-ci.sh` was
      # labelled WATCHER and quietly excluded from reaping (panel r8 codex-3).
      # `hit` also carries the case folding the claim used, so a watcher spelled
      # `.../scripts/Check-CI.sh` on Windows cannot be claimed and then miss
      # this test (panel r2 codex-2).
      if (hit ~ watcher) { kind = "WATCHER"; watchers++ }
      else { kind = "ORPHAN"; orphans++ }
      tail = cmd
      if (length(tail) > 110) tail = "..." substr(tail, length(tail) - 106)
      printf "  %-8s %-8s %-7s %-8s %-15s %s\n", p, pp, age "s", kind, born, tail
    }
    printf "SUMMARY orphans=%d watchers=%d young-skipped=%d scanned=%d\n", \
      orphans + 0, watchers + 0, young + 0, NR
  }
' "$TABLE" > "$WORK/report"

echo "orphan-census: min-age=${MIN_AGE_MIN}m  source=$([ -n "${ORPHAN_CENSUS_INPUT:-}" ] && echo fixture || echo live)"
printf '  %-8s %-8s %-7s %-8s %-15s %s\n' PID PPID AGE KIND STARTED CMDLINE
cat "$WORK/report"

# The KIND column IS the reap list — one source of truth, and what --reap acts
# on is exactly what the operator just read. --reap re-runs the whole census in
# its own invocation, so the enumeration it signals from is milliseconds old —
# and the per-PID creation-time re-check below NARROWS that window to the gap
# between the re-check and the signal. It does not close it: bash cannot signal
# by handle, only by PID, so a PID freed and reused inside that gap is still
# theoretically reachable. What the re-check buys is turning a minutes-wide
# window into a microseconds-wide one; the residual is accepted (HIMMEL-1995).
awk '$4 == "ORPHAN" { print $1 "|" $5 }' "$WORK/report" > "$WORK/reapable"

if [ "$REAP" -ne 1 ]; then
    if [ -s "$WORK/reapable" ]; then
        echo "orphan-census: read-only — re-run with --reap (in YOUR terminal, not a Claude session) to terminate the ORPHAN rows"
    fi
    exit 0
fi

while IFS='|' read -r p born; do
    # The PID reaches this line from a process table — an external input — and
    # is about to be interpolated into a -Command string. Digits only.
    case "$p" in ''|*[!0-9]*) continue ;; esac

    # Re-read THIS pid's creation time immediately before signalling it. The
    # census above is milliseconds old, but "milliseconds" is not "atomic": a
    # PID freed in that window is immediately reusable, and the next process to
    # get it would be the one we killed. A matching creation time proves it was
    # still the same process AT THE MOMENT OF THE READ — the reuse window is
    # narrowed to the microseconds between this read and the signal below, not
    # eliminated. Anything else (changed, or gone) is a skip, loudly, because a
    # silent skip reads as a successful reap.
    if [ -n "${PS_BIN:-}" ]; then
        now=$("$PS_BIN" -NoProfile -NonInteractive -Command               "(Get-CimInstance Win32_Process -Filter \"ProcessId=$p\").CreationDate.ToString('yyyyMMddHHmmss')"               2>/dev/null | tr -d '
' | tr -d '[:space:]')
    else
        now=$(ps -o lstart= -p "$p" 2>/dev/null | tr -s '[:space:]' '_' | sed 's/^_//; s/_$//')
    fi
    if [ -z "$now" ]; then
        echo "orphan-census: WARN $p is gone — not signalling" >&2
        continue
    fi
    if [ "$now" != "$born" ]; then
        echo "orphan-census: WARN $p was recycled (started $now, census saw $born) — not signalling" >&2
        continue
    fi

    if [ -n "${PS_BIN:-}" ]; then
        "$PS_BIN" -NoProfile -NonInteractive -Command "Stop-Process -Id $p -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1
    else
        kill -TERM "$p" 2>/dev/null
    fi
    echo "orphan-census: signalled $p"
done < "$WORK/reapable"
exit 0
