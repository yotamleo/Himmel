#!/usr/bin/env bash
# Branch-scoped /pr-check review-round state and round-4 cap (HIMMEL-2780).
# State lives under the repository's shared git common directory, so head
# commits and merge-forwards do not reset it and linked worktrees agree.
# Bash 3.2-safe.
# Platform guard: requires POSIX Bash 3.2+; on Windows, run under Git Bash.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    echo "usage: review-round.sh start --branch <name>" >&2
    echo "       review-round.sh defer --branch <name> --head <sha> [--defer-to <ticket>]" >&2
    echo "       review-round.sh promote --branch <name> --head <sha>" >&2
    exit 2
}

verb="${1:-}"
[ -n "$verb" ] || usage
shift
branch=""
head_sha=""
defer_to="${CR_DEFER_TO:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) [ $# -ge 2 ] || usage; branch="$2"; shift 2 ;;
        --head) [ $# -ge 2 ] || usage; head_sha="$2"; shift 2 ;;
        --defer-to) [ $# -ge 2 ] || usage; defer_to="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$branch" ] || usage
case "$verb" in
    start) [ -z "$head_sha" ] || usage ;;
    defer) [ -n "$head_sha" ] || usage ;;
    promote) [ -n "$head_sha" ] || usage ;;
    *) usage ;;
esac

if ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "review-round: invalid branch name '$branch'" >&2
    exit 2
fi

git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || git_dir=""
if [ -z "$git_dir" ]; then
    echo "review-round: cannot resolve the shared git common directory" >&2
    exit 5
fi
state="$git_dir/cr-review-rounds/$branch.round"
state_dir="$(dirname "$state")"
mkdir -p "$state_dir" || {
    echo "review-round: cannot create state directory $state_dir" >&2
    exit 5
}

read_round() {
    round=0
    if [ -f "$state" ]; then
        round="$(cat "$state" 2>/dev/null)" || round=""
        case "$round" in
            ''|*[!0-9]*)
                echo "review-round: invalid counter state in $state — refusing to reset it silently" >&2
                return 5
                ;;
        esac
    fi
    return 0
}

if [ "$verb" = "start" ]; then
    lock_lib="$HIMMEL_ROOT/scripts/lib/shared-branch-lock.sh"
    if [ ! -f "$lock_lib" ]; then
        echo "review-round: counter lock library is missing at $lock_lib" >&2
        exit 5
    fi
    lock_out=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
        bash "$lock_lib" acquire-wait "." "$branch" "review-round" 10 300 2>&1)
    lock_rc=$?
    [ -z "$lock_out" ] || printf '%s\n' "$lock_out" >&2
    if [ "$lock_rc" -ne 0 ]; then
        echo "review-round: cannot acquire the counter lock for $branch (rc=$lock_rc)" >&2
        exit 5
    fi
    lock_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" status "." "$branch" 2>/dev/null || true)
    # lock_owner is a single small JSON status line (well under the pipe
    # buffer), so printf's write completes atomically before grep could
    # exit early and SIGPIPE it (HIMMEL-1430 class).
    if ! printf '%s' "$lock_owner" | grep -q '^{"pid":'; then  # pipefail-ok: bounded small input, see comment above
        echo "review-round: counter lock holder state for $branch is missing or unreadable — refusing" >&2
        exit 5
    fi
    if ! read_round; then
        SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
        exit 5
    fi
    round=$((round + 1))
    tmp_state="$state.tmp.$$"
    current_owner=$(SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" status "." "$branch" 2>/dev/null || true)
    if [ "$current_owner" != "$lock_owner" ] \
        || ! printf '%s\n' "$round" > "$tmp_state" \
        || ! mv "$tmp_state" "$state"; then
        rm -f "$tmp_state"
        SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1 || true
        echo "review-round: cannot persist round $round for $branch under the counter lock" >&2
        exit 5
    fi
    if ! SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$lock_lib" release-if-owner "." "$branch" "$lock_owner" >/dev/null 2>&1; then
        echo "review-round: persisted round $round for $branch but could not release its counter lock" >&2
        exit 5
    fi
    printf '%s\n' "$round"
    exit 0
fi

# promote (HIMMEL-2911): the /pr-check flow writes verdict=agreed as a leg-agrees
# intermediate (write-verdicts.sh + step 4.5's ledger-append.sh amend) and
# nothing ever promotes it to a terminal verdict — until now it was only ever
# hand-amended to `fixed`. Given a CLEAN round at --head (the caller asserts
# this — promote does not itself re-check the panel, same posture as `defer`
# not re-running it), every `finding` row on --branch whose LATEST amend
# (joined on target_head + finding_id + artifact + perspective — NOT branch,
# since pre-HIMMEL-2911 rows can carry branch:"") is `agreed` is promoted to
# `fixed` UNLESS it is re-raised at --head: another finding row on the same
# branch, at --head, sharing the same stored `fingerprint` (ledger-append.sh
# already computes this at write time — promote reads it, never recomputes
# it). A row's own identity (head, finding_id, artifact, perspective) is
# excluded from its own re-raise check, so a finding raised and agreed AT
# --head itself (never re-raised anywhere else) is promoted too — the
# acceptance bar is "no agreed row survives a clean round", not merely "no
# agreed row from an earlier head survives". Terminal rows (fixed/disproved/
# deferred) are left untouched; conflict/unaddressed were never agreed and are
# only WARNed. A finding whose stored fingerprint is empty (pre-fingerprint
# row, or no --text was ever supplied) cannot be safely checked for re-raise,
# so it is conservatively left agreed (counted as still-open) rather than
# guessed at. Idempotent: a second run sees the fixed amend via the same
# effective-state merge and skip-terminals it, writing nothing.
# Exit 0 = nothing left agreed; exit 3 = one or more rows are still-open (the
# caller's round was not actually clean for that finding); exit 1 = a
# malformed ledger row or a ledger write failure.
if [ "$verb" = "promote" ]; then
    if ! full_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$full_head" ]; then
        echo "review-round: --head $head_sha does not resolve to a commit" >&2
        exit 2
    fi
    ledger="$git_dir/cr-critic-scores.jsonl"
    if [ ! -f "$ledger" ]; then
        echo "review-round: CR ledger is missing at $ledger" >&2
        exit 5
    fi
    decisions_tmp="$(mktemp -t cr-promote-decisions.XXXXXX)" || { echo "review-round: cannot create scratch state" >&2; exit 1; }
    analysis="$(FULL_HEAD="$full_head" LEDGER="$ledger" BRANCH="$branch" DECISIONS_FILE="$decisions_tmp" node -e '
const fs = require("fs"), cp = require("child_process"), e = process.env;
const lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean);
const SEP = String.fromCharCode(31);
let malformed = 0;
const rows = [];
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { malformed++; continue; }
  rows.push(o);
}
if (malformed !== 0) {
  process.stdout.write(JSON.stringify({malformed}));
  process.exit(0);
}
const resolveCache = new Map();
function resolvesToHead(value) {
  const h = String(value || "");
  if (h === e.FULL_HEAD) return true;
  if (!/^[0-9a-f]{7,64}$/i.test(h)) return false;
  if (!resolveCache.has(h)) {
    let resolved = "";
    try {
      resolved = cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"],
        {encoding: "utf8", stdio: ["ignore", "pipe", "ignore"]}).trim();
    } catch { resolved = ""; }
    resolveCache.set(h, resolved);
  }
  return resolveCache.get(h) === e.FULL_HEAD;
}
// Merge every amend.set for a (target_head, finding_id, artifact, perspective)
// key in ledger (chronological) order — a later amend field wins, a field a
// later amend never touched keeps its earlier value. Same shape as
// ledger-append.shs own amendsByKey/effective().
const amendsByKey = new Map();
for (const o of rows) {
  if (o.kind !== "amend" || !o.set || typeof o.set !== "object") continue;
  const k = [o.target_head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  amendsByKey.set(k, Object.assign({}, amendsByKey.get(k) || {}, o.set));
}
const findingRows = rows.filter((o) => o.kind === "finding" && o.branch === e.BRANCH);
const atHead = findingRows.filter((o) => resolvesToHead(o.head));
const fpAtHead = new Map();
for (const o of atHead) {
  if (!o.fingerprint) continue;
  const idKey = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  if (!fpAtHead.has(o.fingerprint)) fpAtHead.set(o.fingerprint, new Set());
  fpAtHead.get(o.fingerprint).add(idKey);
}
const outLines = [];
for (const row of findingRows) {
  const idKey = [row.head, row.finding_id, row.artifact || "diff", row.perspective || "off"].join(SEP);
  const effective = Object.assign({}, row, amendsByKey.get(idKey) || {});
  const verdict = String(effective.verdict || "").trim();
  let action;
  if (verdict === "fixed" || verdict === "disproved" || verdict === "deferred") action = "skip-terminal";
  else if (verdict === "conflict" || verdict === "unaddressed") action = "warn-unadjudicated";
  else if (verdict !== "agreed") continue;
  else {
    const fp = effective.fingerprint || "";
    const present = fp ? fpAtHead.get(fp) : null;
    const reraised = !fp || (present && [...present].some((k) => k !== idKey));
    action = reraised ? "still-open" : "promote";
  }
  outLines.push(JSON.stringify({
    action, id: row.finding_id, head: row.head, branch: row.branch,
    artifact: row.artifact || "diff", perspective: row.perspective || "off", verdict,
  }));
}
fs.writeFileSync(e.DECISIONS_FILE, outLines.length ? outLines.join("\n") + "\n" : "");
process.stdout.write(JSON.stringify({malformed: 0}));
' 2>/dev/null)"
    node_rc=$?
    malformed="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).malformed)))' 2>/dev/null)" || malformed=""
    if [ "$node_rc" -ne 0 ] || [ -z "$malformed" ]; then
        rm -f "$decisions_tmp"
        echo "review-round: could not evaluate the ledger for promotion" >&2
        exit 1
    fi
    if [ "$malformed" -ne 0 ]; then
        rm -f "$decisions_tmp"
        echo "review-round: malformed CR ledger row(s) — refusing automatic promotion" >&2
        exit 1
    fi
    head8="$(printf '%s' "$full_head" | cut -c1-8)"
    promoted=0 still_open=0 skip_terminal=0 warn_count=0 write_fail=0
    while IFS= read -r decision || [ -n "$decision" ]; do
        [ -n "$decision" ] || continue
        action="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).action))' 2>/dev/null)" || action=""
        id="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).id))' 2>/dev/null)" || id=""
        row_head="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).head))' 2>/dev/null)" || row_head=""
        row_branch="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).branch))' 2>/dev/null)" || row_branch=""
        row_artifact="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).artifact))' 2>/dev/null)" || row_artifact=""
        row_perspective="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).perspective))' 2>/dev/null)" || row_perspective=""
        row_verdict="$(printf '%s' "$decision" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).verdict))' 2>/dev/null)" || row_verdict=""
        if [ -z "$action" ] || [ -z "$id" ] || [ -z "$row_head" ]; then
            write_fail=1
            break
        fi
        row_head8="$(printf '%s' "$row_head" | cut -c1-8)"
        case "$action" in
            promote)
                if ! bash "$SCRIPT_DIR/ledger-append.sh" amend \
                    --branch "$row_branch" --head "$row_head" --id "$id" \
                    --artifact "$row_artifact" --perspective "$row_perspective" \
                    --set verdict=fixed \
                    --reason "Promoted from agreed: no re-raise at clean round head $head8 (HIMMEL-2911)"; then
                    write_fail=1
                    break
                fi
                echo "promoted ${id}@${row_head8}"
                promoted=$((promoted + 1))
                ;;
            still-open)
                echo "still-open ${id}@${row_head8}"
                still_open=$((still_open + 1))
                ;;
            skip-terminal)
                echo "skip-terminal ${id}@${row_head8} (verdict=${row_verdict})"
                skip_terminal=$((skip_terminal + 1))
                ;;
            warn-unadjudicated)
                echo "WARN unadjudicated ${id}@${row_head8} (verdict=${row_verdict})"
                warn_count=$((warn_count + 1))
                ;;
        esac
    done < "$decisions_tmp"
    rm -f "$decisions_tmp"
    if [ "$write_fail" -ne 0 ]; then
        echo "review-round: ledger write failed during promotion" >&2
        exit 1
    fi
    echo "review-round promote: $promoted promoted, $still_open still-open, $skip_terminal skip-terminal, $warn_count warn (head $head8)"
    [ "$still_open" -eq 0 ] || exit 3
    exit 0
fi

read_round || exit $?

if [ "$round" -lt 4 ]; then
    echo "review-round: $branch is at round $round; automatic deferral starts at round 4" >&2
    exit 2
fi
if ! full_head="$(git rev-parse --verify --quiet "$head_sha^{commit}" 2>/dev/null)" || [ -z "$full_head" ]; then
    echo "review-round: --head $head_sha does not resolve to a commit" >&2
    exit 2
fi
ledger="$git_dir/cr-critic-scores.jsonl"
if [ ! -f "$ledger" ]; then
    echo "review-round: CR ledger is missing at $ledger" >&2
    exit 5
fi

analysis="$(FULL_SHA="$full_head" LEDGER="$ledger" node -e '
const fs = require("fs"), cp = require("child_process"), e = process.env;
const lines = fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean);
const SEP = String.fromCharCode(31), amends = new Map(), findings = new Map();
let malformed = 0;
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { malformed++; continue; }
  if (o.kind === "amend" && o.set && typeof o.set === "object") {
    const key = [o.target_head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
    amends.set(key, Object.assign({}, amends.get(key) || {}, o.set));
  }
}
const cache = new Map();
function resolvesToHead(value) {
  const h = String(value || "");
  if (h === e.FULL_SHA) return true;
  if (!/^[0-9a-f]{7,64}$/.test(h) || !e.FULL_SHA.startsWith(h)) return false;
  if (!cache.has(h)) {
    let resolved = "";
    try { resolved = cp.execFileSync("git", ["rev-parse", "--verify", "--quiet", h + "^{commit}"], {encoding:"utf8", stdio:["ignore","pipe","ignore"]}).trim(); }
    catch { resolved = ""; }
    cache.set(h, resolved);
  }
  return cache.get(h) === e.FULL_SHA;
}
for (const line of lines) {
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  if (o.kind !== "finding") continue;
  const original = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
  if (amends.has(original)) o = Object.assign({}, o, amends.get(original));
  if (!resolvesToHead(o.head)) continue;
  const key = [o.finding_id || "?", o.artifact || "diff", o.perspective || "off"].join(SEP);
  findings.set(key, o);
}
const pending = [], capDeferred = [], blocking = [];
for (const o of findings.values()) {
  const id = String(o.finding_id || "?");
  const severity = String(o.severity || "");
  const verdict = typeof o.verdict === "string" ? o.verdict.trim() : "";
  const ticket = typeof o.deferred_to === "string" ? o.deferred_to.trim() : "";
  const reason = typeof o.reason === "string" ? o.reason.trim() : "";
  const trackedDeferred = verdict === "deferred" && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(ticket) && reason;
  const resolved = verdict === "disproved" || trackedDeferred;
  if ((severity === "crit" || severity === "imp") && !resolved) blocking.push(id);
  else if (!verdict && (severity === "sug" || severity === "nit")) pending.push({
    id,
    artifact: o.artifact || "diff",
    perspective: o.perspective || "off"
  });
  else if ((severity === "sug" || severity === "nit") && trackedDeferred &&
           reason === "Suggestion deferred after the three-round /pr-check cap.") {
    capDeferred.push({id, ticket});
  }
  else if (!verdict) blocking.push(id);
}
process.stdout.write(JSON.stringify({malformed, pending, capDeferred, blocking}));
' 2>/dev/null)"
if [ -z "$analysis" ]; then
    echo "review-round: could not evaluate findings at $full_head" >&2
    exit 5
fi
malformed="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).malformed)))' 2>/dev/null)" || malformed=""
blocking="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).blocking.join(" ")))' 2>/dev/null)" || blocking=""
pending_count="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).pending.length)))' 2>/dev/null)" || pending_count=""
cap_deferred_count="$(printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).capDeferred.length)))' 2>/dev/null)" || cap_deferred_count=""
if [ -z "$malformed" ] || [ -z "$pending_count" ] || [ -z "$cap_deferred_count" ]; then
    echo "review-round: could not parse the ledger evaluation" >&2
    exit 5
fi
if [ "$malformed" -ne 0 ]; then
    echo "review-round: malformed CR ledger row(s) — refusing automatic disposition" >&2
    exit 5
fi
if [ -n "$blocking" ]; then
    echo "review-round: Critical or Important finding(s) remain blocking at round $round: $blocking" >&2
    exit 4
fi
if [ "$pending_count" -eq 0 ] && [ "$cap_deferred_count" -eq 0 ]; then
    exit 0
fi

# defer_to is a single small ticket-key string (well under the pipe
# buffer), so printf's write completes atomically before grep could exit
# early and SIGPIPE it (HIMMEL-1430 class).
if [ "$pending_count" -gt 0 ] && ! printf '%s' "$defer_to" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; then  # pipefail-ok: bounded small input, see comment above
    primary_root="$HIMMEL_ROOT"
    himmel_common="$(git -C "$HIMMEL_ROOT" rev-parse --git-common-dir 2>/dev/null)" || himmel_common=""
    if [ -n "$himmel_common" ]; then
        case "$himmel_common" in
            /*) ;;
            *) himmel_common="$HIMMEL_ROOT/$himmel_common" ;;
        esac
        resolved_primary="$(cd "$himmel_common/.." 2>/dev/null && pwd)" || resolved_primary=""
        [ -n "$resolved_primary" ] && primary_root="$resolved_primary"
    fi
    echo "review-round: round $round has suggestion/nit-only findings, but no valid defer ticket was supplied." >&2
    printf "node '%s/scripts/jira/dist/index.js' create --type Task --title 'Track deferred /pr-check round 4+ suggestions' --desc 'Track suggestion/nit-only findings deferred after the three-round review cap.'\n" "$primary_root" >&2
    printf "Then resume without rerunning the panel:\nCR_DEFER_TO=HIMMEL-NNNN bash '%s/review-round.sh' defer --head '%s' --branch '%s'\n" "$SCRIPT_DIR" "$full_head" "$branch" >&2
    exit 6
fi

ids_tmp="$(mktemp -t cr-round-ids.XXXXXX)" || exit 5
verdicts_tmp="$(mktemp -t cr-round-verdicts.XXXXXX)" || { rm -f "$ids_tmp"; exit 5; }
if ! printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const finding of JSON.parse(s).pending) process.stdout.write(JSON.stringify(finding)+"\n")})' > "$ids_tmp" \
    || ! printf '%s' "$analysis" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{for(const finding of JSON.parse(s).capDeferred) process.stdout.write("VERDICT ["+finding.id+"] = deferred -> "+finding.ticket+"\n")})' > "$verdicts_tmp"; then
    rm -f "$ids_tmp" "$verdicts_tmp"
    echo "review-round: could not prepare the deferred finding recovery state" >&2
    exit 5
fi
amend_rc=0
while IFS= read -r finding_identity || [ -n "$finding_identity" ]; do
    [ -n "$finding_identity" ] || continue
    finding_id="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).id))' 2>/dev/null)" || finding_id=""
    artifact="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).artifact))' 2>/dev/null)" || artifact=""
    perspective="$(printf '%s' "$finding_identity" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).perspective))' 2>/dev/null)" || perspective=""
    if [ -z "$finding_id" ] || [ -z "$artifact" ] || [ -z "$perspective" ]; then
        amend_rc=5
        break
    fi
    if ! bash "$SCRIPT_DIR/ledger-append.sh" amend \
        --branch "$branch" --head "$full_head" --id "$finding_id" \
        --artifact "$artifact" --perspective "$perspective" \
        --set verdict=deferred --set "deferred_to=$defer_to" \
        --set 'reason=Suggestion deferred after the three-round /pr-check cap.' \
        --reason 'deferred by review-round.sh after the three-round cap'; then
        amend_rc=5
        break
    fi
    printf 'VERDICT [%s] = deferred -> %s\n' "$finding_id" "$defer_to" >> "$verdicts_tmp"
done < "$ids_tmp"
rm -f "$ids_tmp"
if [ "$amend_rc" -ne 0 ]; then
    rm -f "$verdicts_tmp"
    exit "$amend_rc"
fi

write_recovered_verdicts() {
    verdict_mode="$1"
    existing_verdicts="$2"
    merged_tmp="$(mktemp -t cr-round-merged.XXXXXX)" || return 5
    dedup_tmp="$(mktemp -t cr-round-dedup.XXXXXX)" || { rm -f "$merged_tmp"; return 5; }
    : > "$merged_tmp"
    if [ -f "$existing_verdicts" ] && ! cat "$existing_verdicts" >> "$merged_tmp"; then
        rm -f "$merged_tmp" "$dedup_tmp"
        return 5
    fi
    if ! cat "$verdicts_tmp" >> "$merged_tmp" \
        || ! awk 'NF && !seen[$0]++' "$merged_tmp" > "$dedup_tmp" \
        || ! bash "$SCRIPT_DIR/write-verdicts.sh" "$verdict_mode" --branch "$branch" < "$dedup_tmp"; then
        rm -f "$merged_tmp" "$dedup_tmp"
        return 5
    fi
    rm -f "$merged_tmp" "$dedup_tmp"
    return 0
}

if ! write_recovered_verdicts prior-blocking "$git_dir/cr-prior-blocking/$branch" \
    || ! write_recovered_verdicts aggregate "$git_dir/cr-aggregate-verdicts/$branch"; then
    rm -f "$verdicts_tmp"
    exit 5
fi
rm -f "$verdicts_tmp"
bash "$SCRIPT_DIR/clear-cr-marker.sh" "$branch"
