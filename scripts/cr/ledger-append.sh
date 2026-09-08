#!/usr/bin/env bash
# scripts/cr/ledger-append.sh — deduped JSONL writer for the CR critic ledger
# (HIMMEL-415). Findings dedup on (head,finding_id); usage dedups on
# (head,model). `avail` dedups on (head,model) too, but MONOTONE-SUPERSEDES
# rather than flatly deduping (HIMMEL-1613): a critic that times out on run 1
# and succeeds on run 2 at the same head used to have its run-2 `ok` silently
# dropped by the dedup, permanently wedging clear-cr-marker's gate 3 at that
# SHA. unavailable -> ok is now appended as a real improvement; an identical
# repeat stays a quiet no-op; ok -> unavailable (a downgrade that could dodge a
# real blocker) is refused/dropped, same as a plain duplicate. See the avail
# branch below for the transition logic. The `usage` kind (HIMMEL-485) records an ESTIMATED token count
# (chars/4 of the prompt+response) for the paid codex critic — hermes does not
# expose real usage through the one-shot chokepoint, so this is a cost SIGNAL,
# not a billed figure (every usage record carries "estimated":true).
# `attempt` (HIMMEL-1500): per-attempt timing for a critic invocation (the
# primary try AND each fallback candidate) — NEVER deduped, so a retried
# member leaves one row per try, letting a reader correlate timeout clusters
# with a peak-usage window (e.g. z.ai peak-hours throttling) instead of only
# seeing the final `avail` verdict. --status is ok|timeout|error; --attempt is
# the 1-based try number; --duration-secs is the measured wall-clock elapsed.
# --reason/--detail (HIMMEL-1176): OPTIONAL failure-classification capture,
# mainly for `avail --status unavailable` records so cr-scores.sh can report
# WHY a critic was down. Additive + back-compat: omitted -> the fields are
# ABSENT from the JSON (never emitted as empty strings), so every pre-existing
# caller and the dedup key (unchanged) are byte-for-byte unaffected.
# --text (HIMMEL-2078): OPTIONAL one-line prose for a `finding` row — the
# panel's own rendered bullet, so an unadjudicated finding is still legible
# once the panel transcript is gone (previously the ledger recorded only
# id/severity/file/line/verdict, no claim text). Additive + back-compat, same
# posture as --reason/--detail: omitted -> ABSENT from the JSON, never an
# empty string, so every pre-existing row and caller is unaffected.
# --deferred-to (HIMMEL-1294): an honestly-recorded crit/imp finding that is
# out-of-diff / pre-existing / out-of-scope used to have only two mechanical
# exits at clear-cr-marker gate 4 — downgrade it to `sug`, or claim `disproved`.
# Both are lies, so the gate actively pushed an honest session toward
# mis-recording. `--verdict deferred --deferred-to <TICKET> --reason <text>`
# is the third, truthful exit: the finding stands, it is tracked, and the
# branch proceeds. The gate REQUIRES both the ticket key and the reason, so a
# bare "deferred" cannot become a free pass.
#
# `amend` (HIMMEL-1294): the ledger is append-only and had no way to correct a
# record. A finding logged at the wrong severity or keyed to the wrong head
# permanently wedged a branch — clear-cr-marker refuses, the CR-marker hook
# hard-blocks `gh pr create`, and the session cannot fix it (a ledger-rewrite
# script is classifier-denied as gate tampering; Edit is refused because the
# ledger lives under the PRIMARY checkout's .git/). It cost the HIMMEL-1291
# loop two full rounds and an operator-authorised hand-edit of the JSONL.
# `amend` appends a SUPERSEDE record rather than rewriting a line, so the
# ledger stays append-only and the correction is itself auditable.
#
# `delegation` (HIMMEL-2335): the /pr-check trusted-anchor entry point
# (scripts/cr/pr-check-context.sh) logs one row here every time it hands
# execution off to the reviewed branch's own copy of itself (branch
# self-review of a scripts/cr/-touching diff, moved out of the runbook fence
# and into the script - see that file's header). NEVER deduped - same posture
# as `attempt` - a delegation is a per-run EVENT, not a property of the
# (head, model) pair, so a re-run at the same head appends its own row rather
# than colliding with a prior one. Reuses the existing --branch/--head flags,
# plus --reason (why: the diff touches scripts/cr/) and --detail (which
# anchor, which branch copy) rather than inventing new ones.
set -uo pipefail
kind="${1:-}"; shift || true
case "$kind" in
  finding|avail|usage|amend|attempt|delegation) ;;
  *) echo "ledger-append.sh: kind must be finding|avail|usage|amend|attempt|delegation" >&2; exit 2;;
esac

branch="" head="" model="" responding_model="" id="" severity="" file="" line="" verdict="" status="" artifact="diff" perspective="off"
prompt_chars="" response_chars="" reason="" detail="" deferred_to="" set_pairs="" attempt_num="" duration_secs="" batch_file="" text=""
while [ $# -gt 0 ]; do case "$1" in
  --branch) branch="$2"; shift 2;; --head) head="$2"; shift 2;;
  --model) model="$2"; shift 2;; --responding-model) responding_model="$2"; shift 2;;
  --id) id="$2"; shift 2;;
  --severity) severity="$2"; shift 2;; --file) file="$2"; shift 2;;
  --line) line="$2"; shift 2;; --verdict) verdict="$2"; shift 2;;
  --status) status="$2"; shift 2;;
  --artifact) artifact="$2"; shift 2;; --perspective) perspective="$2"; shift 2;;
  --prompt-chars) prompt_chars="$2"; shift 2;; --response-chars) response_chars="$2"; shift 2;;
  --reason) reason="$2"; shift 2;; --detail) detail="$2"; shift 2;;
  --deferred-to) deferred_to="$2"; shift 2;;
  --text) text="$2"; shift 2;;
  --set) set_pairs="$set_pairs$2"$'\n'; shift 2;;
  --attempt) attempt_num="$2"; shift 2;; --duration-secs) duration_secs="$2"; shift 2;;
  --batch-file) batch_file="$2"; shift 2;;
  *) echo "ledger-append.sh: unknown $1" >&2; exit 2;;
esac; done

# --batch-file (HIMMEL-2052): one node process + one ledger read/dedup-scan for
# N finding rows instead of N. The single-row-per-invocation shape above is
# unchanged; this is purely additive. Restricted to `finding` because that is
# the only kind a panel writes in bulk (avail/usage/attempt are one row per
# critic per PR, not per-finding) — see the node block for the write loop.
if [ -n "$batch_file" ]; then
  [ "$kind" = "finding" ] || { echo "ledger-append.sh: --batch-file is only supported for the finding kind" >&2; exit 2; }
  [ -f "$batch_file" ] || { echo "ledger-append.sh: --batch-file '$batch_file' not found" >&2; exit 2; }
fi

raw_head="$head"

normalize_head_arg() {
  local _label="$1" _value="$2" _full
  [ -n "$_value" ] || { printf '%s' "$_value"; return 0; }
  case "$_value" in *[!0-9a-fA-F]*) printf '%s' "$_value"; return 0 ;; esac
  [ "${#_value}" -lt 40 ] || { printf '%s' "$_value"; return 0; }
  _full=$(git rev-parse --verify "$_value^{commit}" 2>/dev/null) || {
    echo "ledger-append.sh: $_label '$_value' is an abbreviated SHA but does not resolve to exactly one commit; refusing to write an unresolvable ledger key." >&2
    return 2
  }
  printf '%s' "$_full"
}

if [ -n "$head" ]; then
  if [ "$kind" = "amend" ]; then
    # amend's --head is a LOOKUP key, not a write key (the emitted target_head
    # is copied from the row it finds, never from this value) - HIMMEL-1294's
    # re-key escape hatch deliberately allows `--set head=` to point at a sha
    # this repo cannot resolve, so a follow-up amend must still be able to
    # locate it by that same literal spelling. Fall back to the raw value on
    # an unresolvable abbreviation instead of refusing; headsMatch below still
    # matches it via its plain string-equality fast path (resolving an
    # unresolvable value would only ever fail, so the exact-match check runs
    # first and is all a foreign, unresolvable spelling can ever hit).
    head=$(normalize_head_arg "--head" "$head" 2>/dev/null) || head="$raw_head"
  else
    head=$(normalize_head_arg "--head" "$head")
    _nh_rc=$?
    [ "$_nh_rc" -eq 0 ] || exit "$_nh_rc"
  fi
fi

case "$artifact" in diff|spec|plan) ;; *) echo "ledger-append.sh: --artifact must be diff|spec|plan" >&2; exit 2;; esac
case "$perspective" in on|off) ;; *) echo "ledger-append.sh: --perspective must be on|off" >&2; exit 2;; esac

# A deferral is only honest if it is TRACKED. Validate the ticket key here so a
# typo cannot silently produce a deferral the gate then rejects for reasons the
# caller has to reverse-engineer.
#
# grep -E, NOT a case glob (codex-1). A shell glob is not a regex: in
# `[A-Z][A-Z0-9]*-[0-9]*` the trailing `*` means ANY characters, not "more
# digits", so `HI-1x` matches here and is then rejected by the gate's real
# anchored regex — the exact split-validation this check exists to prevent.
# One definition, shared with clear-cr-marker gate 4.
valid_ticket() { printf '%s' "$1" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$'; }
if [ -n "$deferred_to" ] && ! valid_ticket "$deferred_to"; then
  echo "ledger-append.sh: --deferred-to must be a ticket key like HIMMEL-1294 (got '$deferred_to')" >&2
  exit 2
fi

if [ "$kind" = "amend" ]; then
  amend_usage="usage: ledger-append.sh amend --head <sha> --id <finding-id> --set <key>=<value> [--set ...] --reason <text> [--artifact <a>] [--perspective <p>]"
  [ -n "$head" ] || { echo "ledger-append.sh: amend requires --head (the head the finding is CURRENTLY recorded at). $amend_usage" >&2; exit 2; }
  [ -n "$id" ]   || { echo "ledger-append.sh: amend requires --id. $amend_usage" >&2; exit 2; }
  [ -n "$set_pairs" ] || { echo "ledger-append.sh: amend requires at least one --set <key>=<value>. $amend_usage" >&2; exit 2; }
  # A correction without a stated reason is indistinguishable from tampering.
  [ -n "$reason" ] || { echo "ledger-append.sh: amend requires --reason (why the original record was wrong). $amend_usage" >&2; exit 2; }
  while IFS= read -r _pair; do
    [ -n "$_pair" ] || continue
    case "$_pair" in
      # `reason` is amendable (glm-3). Gate 4 accepts a deferral only when the
      # FINDING carries a reason, and an amend's own --reason documents why the
      # RECORD was wrong — a different field. Without this key, the deferral
      # path clear-cr-marker itself recommends is a dead end for any finding
      # originally recorded without a reason, which is most of them.
      severity=*|head=*|verdict=*|deferred_to=*|reason=*|file=*|line=*) ;;
      *=*) echo "ledger-append.sh: amend cannot set '${_pair%%=*}' (allowed: severity, head, verdict, deferred_to, reason, file, line)" >&2; exit 2;;
      *)   echo "ledger-append.sh: --set expects <key>=<value> (got '$_pair')" >&2; exit 2;;
    esac
    # Same eager validation as --deferred-to (glm-5): otherwise a typo'd ticket
    # is only caught at gate time, on the path this verb exists to unblock.
    #
    # severity/verdict are validated too (codex-1). Gate 4 blocks on
    # `severity in (crit, imp)`, so a typo like `severity=suq` matches NEITHER
    # and silently makes a blocking finding non-blocking — a fail-OPEN on the
    # one verb that can change a gate verdict. (Verdict typos already fail
    # closed: anything unrecognised is neither `disproved` nor a valid
    # `deferred`, so it keeps blocking. Validated anyway, so a typo is a clear
    # error instead of a silently-ignored amend.)
    #
    # Scope: the AMEND surface only. The `finding` verb has always accepted
    # free-form severity strings and existing callers/tests rely on that;
    # tightening it is a separate, wider change.
    case "$_pair" in
      deferred_to=*)
        if ! valid_ticket "${_pair#deferred_to=}"; then
          echo "ledger-append.sh: --set deferred_to= must be a ticket key like HIMMEL-1294 (got '${_pair#deferred_to=}')" >&2
          exit 2
        fi ;;
      severity=*)
        case "${_pair#severity=}" in
          crit|imp|sug) ;;
          *) echo "ledger-append.sh: --set severity= must be crit|imp|sug (got '${_pair#severity=}') — an unrecognised severity is not blocking, so a typo here would silently clear the gate" >&2; exit 2;;
        esac ;;
      verdict=*)
        case "${_pair#verdict=}" in
          agreed|disproved|conflict|unaddressed|deferred) ;;
          *) echo "ledger-append.sh: --set verdict= must be agreed|disproved|conflict|unaddressed|deferred (got '${_pair#verdict=}')" >&2; exit 2;;
        esac ;;
      head=*)
        # Re-keying is the point of this key (a finding mis-keyed onto the head
        # that FIXES it must be movable to the head it was RAISED against), so
        # the value cannot be constrained to one sha. What it CAN be constrained
        # to is the shape gate 4 will actually accept: clear-cr-marker's isHex
        # takes 7-64 hex chars (HIMMEL-2029: a SHA-256 repo's full head is 64
        # hex, not 40) and silently ignores anything else. Validating a
        # narrower shape here than the gate consumes is the split-validation
        # trap codex-1 already caught once on --deferred-to — so the two agree
        # exactly. Without this, `--set head=HEAD~1` re-keys a blocking finding
        # into nowhere and gate 4 fails OPEN.
        if ! printf '%s' "${_pair#head=}" | grep -qE '^[0-9a-fA-F]{7,64}$'; then
          echo "ledger-append.sh: --set head= must be a 7-64 char hex sha (got '${_pair#head=}') — anything else is not recognised as a head by the gate, so the finding would silently vanish from it" >&2
          exit 2
        fi ;;
    esac
  done <<< "$set_pairs"
fi

# attempt (HIMMEL-1500): one row per invocation ATTEMPT (primary + each
# fallback candidate), never deduped — unlike avail (one authoritative row per
# head+model), the point of this kind is to keep every attempt's own timing,
# so a chain of N tries at one head produces N rows, not one.
if [ "$kind" = "attempt" ]; then
  [ -n "$head" ]  || { echo "ledger-append.sh: attempt requires --head" >&2; exit 2; }
  [ -n "$model" ] || { echo "ledger-append.sh: attempt requires --model" >&2; exit 2; }
  case "$status" in
    ok|timeout|error) ;;
    *) echo "ledger-append.sh: attempt --status must be ok|timeout|error (got '$status')" >&2; exit 2;;
  esac
  if [ -n "$attempt_num" ] && ! expr "$attempt_num" : '^[0-9][0-9]*$' > /dev/null 2>&1; then
    echo "ledger-append.sh: attempt --attempt must be a non-negative integer (got '$attempt_num')" >&2; exit 2
  fi
  if [ -n "$duration_secs" ] && ! expr "$duration_secs" : '^[0-9][0-9]*$' > /dev/null 2>&1; then
    echo "ledger-append.sh: attempt --duration-secs must be a non-negative integer (got '$duration_secs')" >&2; exit 2
  fi
fi

# delegation (HIMMEL-2335): --head and --reason are both required - a
# delegation record with no head cannot be correlated to a run, and one with
# no reason is indistinguishable from an unexplained hand-off.
if [ "$kind" = "delegation" ]; then
  [ -n "$head" ]   || { echo "ledger-append.sh: delegation requires --head" >&2; exit 2; }
  [ -n "$reason" ] || { echo "ledger-append.sh: delegation requires --reason" >&2; exit 2; }
fi

# Secret scrub (HIMMEL-1176, reused for --text by HIMMEL-2078 CR round):
# lightweight, anchored redaction — not a full gitleaks scan (this is a hot
# per-call path with no external deps) — covering the common credential
# shapes gitleaks' default ruleset + this repo's own telegram-bot-token rule
# (.gitleaks.toml) flag. ONE definition shared by --detail (provider error
# bodies can echo request fragments/credentials) and --text (critic review
# prose can quote a secret straight out of the reviewed diff).
scrub_secrets() {
  printf '%s' "$1" | sed -E \
    -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED]/g' \
    -e 's/(Bearer|bearer) [A-Za-z0-9._-]{16,}/\1 [REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9][A-Za-z0-9_-]{15,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/([Aa][Pp][Ii][_-]?[Kk]ey|[Tt]oken|[Ss]ecret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]{12,}/\1=[REDACTED]/g'
}
# HIMMEL-2078 CR round (CodeRabbit): flatten embedded newlines BEFORE the
# scrub, not after. sed processes one line at a time, so a token+value pair
# an embedded newline happens to split (e.g. "Token:\nabcdefghijklmnop")
# never matches within a single sed cycle — flattening first joins it back
# into one line the scrub regexes can actually see. Truncate LAST, so a
# secret cannot survive by being cut in half either.
if [ -n "$detail" ]; then
  # tr '\n\r' (not just '\n'): a LONE carriage return (old-Mac line ending,
  # or a stray \r in provider output) also splits a token from its value
  # across a sed line-cycle boundary the same way \n does (HIMMEL-2078 CR
  # round 2, CodeRabbit/codex).
  detail="$(printf '%s' "$detail" | tr '\n\r' '  ')"
  detail="$(scrub_secrets "$detail")"
  detail="$(printf '%s' "$detail" | cut -c1-200)"
fi

# --text (HIMMEL-2078): the panel's own one-line prose bullet for a finding, so
# an unadjudicated finding is still legible after the panel transcript is
# gone. Same flatten-then-scrub-then-cap shape as --detail above, just a
# longer cap (a bullet is a whole rendered line, not a short error fragment).
if [ -n "$text" ]; then
  text="$(printf '%s' "$text" | tr '\n\r' '  ')"
  text="$(scrub_secrets "$text")"
  text="$(printf '%s' "$text" | cut -c1-500)"
fi

ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"
[ -n "$ledger" ] || { echo "ledger-append.sh: cannot resolve ledger path (not a git repo? set CR_LEDGER)" >&2; exit 2; }
touch "$ledger" || { echo "ledger-append.sh: cannot write $ledger" >&2; exit 2; }

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Build the record + a dedup grep key via node (safe JSON + escaping).
# shellcheck disable=SC2016  # the $-refs inside are a JS heredoc (process.env), not shell expansions
KIND="$kind" BRANCH="$branch" HEAD_="$head" RAW_HEAD="$raw_head" MODEL="$model" RESPONDING_MODEL="$responding_model" ID="$id" SEV="$severity" \
FILE="$file" LINE="$line" VERDICT="$verdict" STATUS="$status" BATCH_FILE="$batch_file" \
PROMPT_CHARS="$prompt_chars" RESPONSE_CHARS="$response_chars" TS="$ts" LEDGER="$ledger" ARTIFACT="$artifact" PERSPECTIVE="$perspective" \
ATTEMPT_NUM="$attempt_num" DURATION_SECS="$duration_secs" \
REASON="$reason" DETAIL="$detail" DEFERRED_TO="$deferred_to" TEXT="$text" SET_PAIRS="$set_pairs" node -e '
  const fs=require("fs"), cp=require("child_process"), e=process.env;
  const led=e.LEDGER;
  // HIMMEL-2078: batch rows carry spec.text straight from a caller-built JSON
  // file, bypassing the bash-side --text scrub/flatten/cap above entirely —
  // this is the path critic-panel.sh actually uses (--batch-file, HIMMEL-2052)
  // — so sanitize here too, same shape as the shell scrub. Single-row TEXT is
  // already scrubbed/flattened/capped by the shell before this process
  // starts; re-running it through here is a harmless no-op (a redacted
  // "[REDACTED]" marker does not match any of these patterns).
  // Same anchored patterns as the shell scrub_secrets function above (CR
  // round, HIMMEL-1176/HIMMEL-2078) — keep both definitions in lockstep.
  const scrubSecrets=(s)=>s
    .replace(/[0-9]{8,10}:[A-Za-z0-9_-]{35}/g,"[REDACTED]")
    .replace(/(Bearer|bearer) [A-Za-z0-9._-]{16,}/g,"$1 [REDACTED]")
    .replace(/sk-[A-Za-z0-9][A-Za-z0-9_-]{15,}/g,"[REDACTED]")
    .replace(/AKIA[0-9A-Z]{16}/g,"[REDACTED]")
    .replace(/([Aa][Pp][Ii][_-]?[Kk]ey|[Tt]oken|[Ss]ecret)[ \t]*[:=][ \t]*[A-Za-z0-9._-]{12,}/g,"$1=[REDACTED]");
  // HIMMEL-2078 CR round (CodeRabbit): flatten BEFORE scrubbing, not after —
  // a token+value pair an embedded newline happens to split (e.g.
  // "Token:\nabcdefghijklmnop") must become one line before scrubSecrets
  // sees it, or the whitespace-class gap in the pattern never spans it.
  // Truncate LAST, so a secret cannot survive by being cut in half either.
  const truncText=(s)=>{
    if(typeof s!=="string"||s==="") return "";
    // [\r\n] (not just \r?\n): a LONE \r also splits a token from its value
    // the same way \n does (HIMMEL-2078 CR round 2, CodeRabbit/codex).
    const flat=scrubSecrets(s.replace(/[\r\n]/g," "));
    return flat.length>500?flat.slice(0,500):flat;
  };
  const existing=fs.existsSync(led)?fs.readFileSync(led,"utf8").split("\n").filter(Boolean):[];
  const parsed=existing.map(l=>{try{return JSON.parse(l);}catch{return null;}}).filter(Boolean);
  // Resolve-then-compare head matching (codex-1/2, HIMMEL-2020 round 5) -
  // the SAME posture clear-cr-marker.sh already takes on READ (its atHead()
  // resolves an abbreviation through git rather than string-comparing it).
  // A plain === match is tried FIRST (the common case: both sides already
  // full, zero git calls); only a mismatch falls through to resolving BOTH
  // sides and comparing the results, so a legacy short-recorded row and a
  // now-always-full caller head still collide regardless of which form
  // either side happens to spell - closing this the same way for every
  // caller, not by threading the callers own raw pre-normalization spelling
  // through a second string-only fallback (the prior keyRaw approach, which
  // could only ever match a row whose stored spelling happened to equal what
  // THIS caller typed, not what any other caller had typed in the past).
  //
  // HIMMEL-2052: this used to call `git rev-parse --verify` per head, once
  // per DISTINCT stored head hit during the dedup scan - on a ledger that has
  // accumulated hundreds of distinct heads (most already full, from callers
  // that pre-resolve before writing) that is hundreds of process spawns for a
  // single row append (measured: 1615 spawns / ~55s on the live 3.4MB
  // ledger; reusable finding ids like "codex-1" that recur across nearly
  // every PR made this the norm, not an edge case). A canonical 40-hex SHA
  // needs no git call at all - resolving it through git can never change it -
  // and every genuinely abbreviated/legacy spelling in the WHOLE ledger can
  // be resolved together in ONE `git cat-file --batch-check` process instead
  // of one spawn each.
  const FULL_SHA_RE=/^[0-9a-f]{40}$/i;
  const resolveCache=new Map();
  {
    const candidates=new Set();
    const addCandidate=(v)=>{ if(typeof v==="string"&&v!==""&&!FULL_SHA_RE.test(v)&&!/\s/.test(v)) candidates.add(v); };
    addCandidate(e.HEAD_); addCandidate(e.RAW_HEAD);
    for(const o of parsed){
      addCandidate(o.head);
      if(o.kind==="amend"&&o.set&&typeof o.set==="object") addCandidate(o.set.head);
    }
    if(candidates.size){
      const list=[...candidates];
      const input=list.map(h=>h+"^{commit}").join("\n")+"\n";
      let out="";
      try{
        out=cp.execFileSync("git",["cat-file","--batch-check=%(objectname) %(objecttype)"],
          {input,encoding:"utf8",stdio:["pipe","pipe","ignore"]});
      }catch{ out=""; }
      const lines=out.split("\n");
      list.forEach((h,i)=>{
        const parts=(lines[i]||"").split(" ");
        resolveCache.set(h, parts.length===2&&parts[1]==="commit" ? parts[0] : null);
      });
    }
  }
  const resolveHead=(h)=>{
    if(typeof h!=="string"||h==="") return null;
    if(FULL_SHA_RE.test(h)) return h.toLowerCase();
    return resolveCache.has(h)?resolveCache.get(h):null;
  };
  const headsMatch=(a,b)=>{
    if(a===b) return true;
    const ra=resolveHead(a);
    return !!ra && ra===resolveHead(b);
  };
  const keyForHead=(o,h)=>o.kind==="finding"&&headsMatch(o.head,h)&&o.finding_id===e.ID
      &&(o.artifact||"diff")===e.ARTIFACT&&(o.perspective||"off")===e.PERSPECTIVE;
  const key=(o)=>keyForHead(o,e.HEAD_);

  // Resolve a finding through PRIOR amends (codex-1 round 4; hoisted out of
  // the amend-only block HIMMEL-2020 round 2 so the finding-write verdict-only
  // check below can use it too - comparing a re-append against the RAW
  // original row let a second verdict change on an already-amended finding
  // silently mint another auto-amend instead of hitting the loud "use amend"
  // refusal, since the raw row verdict field always reads empty no matter how
  // many amends had already set it). A re-key leaves the original finding row
  // untouched (append-only), so after moving a finding A -> B the row still
  // reads A while the ledger EFFECTIVELY places it at B. Match either the
  // original row or its effective state; an emitted amend still keys on the
  // ORIGINAL head, so the reader in clear-cr-marker needs no matching logic
  // of its own.
  const SEP=String.fromCharCode(31);
  const amendsByKey=new Map();
  for(const a of parsed){
    if(a.kind!=="amend"||!a.set||typeof a.set!=="object") continue;
    const k=[a.target_head,a.finding_id,a.artifact||"diff",a.perspective||"off"].join(SEP);
    amendsByKey.set(k,Object.assign({},amendsByKey.get(k)||{},a.set));
  }
  const effective=(o)=>{
    const k=[o.head,o.finding_id,o.artifact||"diff",o.perspective||"off"].join(SEP);
    return amendsByKey.has(k)?Object.assign({},o,amendsByKey.get(k)):o;
  };

  // BATCH (HIMMEL-2052): --batch-file writes N finding rows in ONE process -
  // one ledger read, one head-candidate resolution (above), N in-memory dedup
  // checks - instead of paying that fixed per-invocation cost N times over. A
  // panel writing 14 rows sequentially (14 separate `bash ledger-append.sh`
  // calls) was blowing a 120s tool budget even after the resolveHead fix,
  // because each invocation still re-reads and re-parses the whole ledger
  // file from scratch. Same dedup/amend/refusal semantics as the single-row
  // finding path below, just looped, with each appended row visible to the
  // NEXT row dedup check (mirrors what N separate invocations would see
  // by re-reading the file each time). Exits 3 if ANY row was refused, but
  // still processes every row first - a batch write is partial-success, not
  // all-or-nothing (a refused row must not hide a sibling row that succeeded).
  if(e.KIND==="finding"&&e.BATCH_FILE){
    let rows;
    try{
      rows=fs.readFileSync(e.BATCH_FILE,"utf8").split("\n").filter(Boolean).map(l=>JSON.parse(l));
    }catch(err){
      process.stderr.write("ledger-append.sh: --batch-file "+e.BATCH_FILE+" is not readable/valid JSONL: "+err.message+"\n");
      process.exit(2);
    }
    let anyFail=false;
    for(const spec of rows){
      const sid=spec.id, shead=spec.head;
      const artifact=spec.artifact||"diff", perspective=spec.perspective||"off";
      if(!shead||!FULL_SHA_RE.test(shead)){
        process.stderr.write("ledger-append.sh: batch row "+JSON.stringify(sid)+" has no full 40-hex --head ("+JSON.stringify(shead)+") - batch mode requires a pre-resolved head, refusing this row.\n");
        anyFail=true; continue;
      }
      if(!sid){
        process.stderr.write("ledger-append.sh: batch row for head "+shead.slice(0,8)+" is missing --id, refusing this row.\n");
        anyFail=true; continue;
      }
      // Structural check only - a citation-less finding legitimately carries
      // file:"" / line:"" (HIMMEL-1494), so an empty VALUE is valid; a
      // MISSING key is not (the row silently writes `undefined` into the
      // ledger record). "in" tests key presence, not truthiness.
      const missingFields=["branch","model","severity","file","line","verdict"].filter(f=>!(f in spec));
      if(missingFields.length){
        process.stderr.write("ledger-append.sh: batch row "+sid+" is missing required field(s) ("+missingFields.join(",")+") - refusing this row.\n");
        anyFail=true; continue;
      }
      const keyRow=(o)=>o.kind==="finding"&&headsMatch(o.head,shead)&&o.finding_id===sid
          &&(o.artifact||"diff")===artifact&&(o.perspective||"off")===perspective;
      const rec={kind:"finding",ts:spec.ts||e.TS,branch:spec.branch,head:shead,model:spec.model,
                 finding_id:sid,severity:spec.severity,file:spec.file,
                 line:Number(spec.line)||spec.line,verdict:spec.verdict,artifact,perspective};
      if(spec.responding_model) rec.responding_model=spec.responding_model;
      if(spec.reason) rec.reason=spec.reason;
      if(spec.detail) rec.detail=spec.detail;
      if(spec.deferred_to) rec.deferred_to=spec.deferred_to;
      if(spec.text) rec.text=truncText(spec.text);

      const priorMatches=parsed.filter(o=>keyRow(o)||keyRow(effective(o)));
      if(priorMatches.length>1){
        process.stderr.write("ledger-append.sh: finding "+sid+" matches "+priorMatches.length
          +" distinct existing rows (a legacy short-head + full-head pair) - refusing to guess which one to update.\n"
          +"  Reconcile manually: amend one row to re-key it onto the same head as the other\n"
          +"  (ledger-append.sh amend --head <its-current-head> --id "+sid+" --set head=<other-head> --reason \"<why>\"),\n"
          +"  then re-run.\n");
        anyFail=true; continue;
      }
      const prior=priorMatches.pop();
      if(prior){
        const priorEff=effective(prior);
        // HIMMEL-2321 CR round 2 (codex-1): only ignore text when the
        // INCOMING record (rec) omits it - unconditionally dropping text on
        // BOTH sides let a genuinely DIFFERENT finding that reuses an id
        // (the realistic case: ids are minted in stream order, so a
        // reordered/updated producer run remaps e.g. coderabbit-2 onto new
        // text) compare EQUAL and silently drop, where before it was a loud
        // rc=3 refusal - trading a real signal away. Gate on rec, not prior:
        // the interactive verdict-only call never sends --text (the
        // convergence case this ticket needs), while a second PRODUCER
        // write for the same id DOES carry text and must still be compared,
        // so a genuinely different finding under the same id keeps refusing.
        const ignoreText=!("text" in rec);
        const norm=(o)=>{const c={...o}; delete c.ts; if(ignoreText) delete c.text; return JSON.stringify(Object.keys(c).sort().map(k=>[k,c[k]]));};
        if(norm(priorEff)!==norm(rec)){
          const priorWithVerdict={...priorEff,verdict:rec.verdict};
          if(rec.reason) priorWithVerdict.reason=rec.reason;
          if(rec.deferred_to) priorWithVerdict.deferred_to=rec.deferred_to;
          const verdictOnly=String(priorEff.verdict||"")===""&&String(rec.verdict||"")!==""&&norm(priorWithVerdict)===norm(rec);
          if(verdictOnly){
            const set={verdict:rec.verdict};
            if(rec.reason) set.reason=rec.reason;
            if(rec.deferred_to) set.deferred_to=rec.deferred_to;
            const amend={kind:"amend",ts:spec.ts||e.TS,branch:spec.branch,target_head:prior.head,finding_id:sid,
                         artifact,perspective,set,reason:"verdict appended after adjudication"};
            fs.appendFileSync(led, JSON.stringify(amend)+"\n");
            parsed.push(amend);
            const amKey=[amend.target_head,amend.finding_id,amend.artifact,amend.perspective].join(SEP);
            amendsByKey.set(amKey,Object.assign({},amendsByKey.get(amKey)||{},amend.set));
            process.stderr.write("ledger-append.sh: appended verdict amend for "+sid+" at "+shead.slice(0,8)+"\n");
            continue;
          }
          process.stderr.write("ledger-append.sh: finding "+sid+" is ALREADY recorded at head "+shead
            +" with different content - NOTHING was written (the ledger dedups on head+finding_id).\n"
            +"  Correct it with the amend verb, which appends an auditable supersede record:\n"
            +"    ledger-append.sh amend --head "+shead+" --id "+sid
            +" --set <key>=<value> --reason \"<why>\"\n");
          anyFail=true; continue;
        }
        // identical content: quiet no-op success, same as the single-row path.
        continue;
      }
      fs.appendFileSync(led, JSON.stringify(rec)+"\n");
      parsed.push(rec);
    }
    process.exit(anyFail?3:0);
  }

  // AMEND: append a supersede record pointing at an EXISTING finding. It never
  // rewrites a line - the ledger stays append-only, and the correction is
  // itself auditable. Refuses loudly when there is nothing to amend: a silent
  // success here would recreate the exact failure this verb exists to fix
  // (caller sees 0, record unchanged, gate still refuses).
  if(e.KIND==="amend"){
    const findings=parsed.filter(o=>o.kind==="finding");
    const matches=findings.filter(o=>key(o)||key(effective(o)));
    // Ambiguity (HIMMEL-2029): a stale legacy pair - a short-keyed row and a
    // full-keyed row for the SAME finding_id, both resolving to this --head -
    // used to fall through to .pop() and silently amend whichever happened to
    // be LAST in ledger order, not the row the operator actually meant. This
    // is exactly the recovery path the round-4 ambiguity refusal (finding
    // append, above) points callers at, so it must not itself pick blind.
    // Prefer the row whose EFFECTIVE (post-amend) head equals the --head
    // ARGUMENT byte-for-byte (RAW_HEAD - the literal spelling the caller
    // passed, before any bash-side resolve-to-full normalization) - an exact
    // match on what was actually typed beats a merely-resolved one. This must
    // compare against effective(o).head, NOT the row raw o.head (codex-1 CR
    // round 4): a row that a PRIOR amend already re-keyed elsewhere still
    // carries its ORIGINAL raw head forever (append-only), so comparing raw
    // heads could match the wrong duplicate - the one whose stale original
    // spelling happens to equal --head - while missing the row a caller
    // actually re-keyed TO that head (whose raw field never changes to say
    // so). Still >1 (or 0) exact matches -> refuse loudly and name every
    // candidate row EFFECTIVE head so the operator can retry with the
    // precise spelling (two rows truly sharing the same effective head is a
    // genuine ambiguity no head-spelling can resolve; refusing is correct).
    let target;
    if(matches.length<=1){
      target=matches.pop();
    } else {
      const exact=matches.filter(o=>effective(o).head===e.RAW_HEAD);
      if(exact.length===1){
        target=exact[0];
      } else {
        const heads=[...new Set(matches.map(o=>effective(o).head))];
        process.stderr.write("ledger-append.sh: amend --head "+e.RAW_HEAD+" for "+e.ID
          +" matches "+matches.length+" distinct rows - still ambiguous, refusing to guess.\n"
          +"  The matched rows currently sit at: "+heads.join(", ")+"\n");
        if(exact.length===0){
          process.stderr.write("  None of them is EXACTLY \""+e.RAW_HEAD+"\" - re-run with --head set to one of the heads listed above.\n");
        } else {
          process.stderr.write("  "+exact.length+" of them are ALREADY at exactly \""+e.RAW_HEAD+"\" - no --head spelling can tell them apart.\n"
            +"  Inspect the ledger rows for finding "+e.ID+" directly and re-key one of them (--set head=<a-different-head>) before retrying.\n");
        }
        process.exit(3);
      }
    }
    if(!target){
      process.stderr.write("ledger-append.sh: amend found NO finding "+e.ID+" at head "+e.HEAD_
        +" (artifact="+e.ARTIFACT+" perspective="+e.PERSPECTIVE+") - nothing amended.\n"
        +"  Amend targets the head the finding sits at - either the one it was originally\n"
        +"  recorded at, or the one a previous amend moved it to - never the one you want\n"
        +"  it moved to next.\n");
      process.exit(3);
    }
    const set={};
    for(const p of (e.SET_PAIRS||"").split("\n").filter(Boolean)){
      const i=p.indexOf("=");
      let v=p.slice(i+1);
      const k=p.slice(0,i);
      if(k==="line") v=Number(v)||v;
      set[k]=v;
    }
    const rec={kind:"amend",ts:e.TS,branch:e.BRANCH,target_head:target.head,finding_id:e.ID,
               artifact:e.ARTIFACT,perspective:e.PERSPECTIVE,set,reason:e.REASON};
    fs.appendFileSync(led, JSON.stringify(rec)+"\n");
    process.stderr.write("ledger-append.sh: amended "+e.ID+" at "+e.HEAD_.slice(0,8)+" -> "
      +JSON.stringify(set)+"\n");
    process.exit(0);
  }

  let rec, dup;
  if(e.KIND==="finding"){
    rec={kind:"finding",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,model:e.MODEL,finding_id:e.ID,severity:e.SEV,file:e.FILE,line:Number(e.LINE)||e.LINE,verdict:e.VERDICT,artifact:e.ARTIFACT,perspective:e.PERSPECTIVE};
    if(e.RESPONDING_MODEL) rec.responding_model=e.RESPONDING_MODEL;
    if(e.REASON) rec.reason=e.REASON;
    if(e.DETAIL) rec.detail=e.DETAIL;
    if(e.DEFERRED_TO) rec.deferred_to=e.DEFERRED_TO;
    if(e.TEXT) rec.text=truncText(e.TEXT);
    // A re-append that CHANGES the record is the wedge this ticket is about:
    // the old code hit the dedup key, wrote nothing, and exited 0, so the
    // caller believed the severity had been corrected while the gate kept
    // reading the original. Identical content is still a quiet success (re-
    // running /pr-check on the same head must stay idempotent); DIFFERING
    // content is now a loud refusal that names the sanctioned fix.
    //
    // Compare against the EFFECTIVE state (codex-1, HIMMEL-2020 round 2), not
    // the raw append-only row: the raw row verdict field stays empty forever
    // once the panel writes it, so comparing against it let a SECOND verdict
    // change on an already-amended finding read as "prior verdict empty" all
    // over again and silently mint another auto-amend - overwriting the
    // first adjudication instead of hitting the loud "use amend" refusal a
    // genuine re-adjudication should go through.
    //
    // Legacy short-head rows (codex-1/2, HIMMEL-2020 rounds 3 and 5): a
    // finding row written before this ticket can still carry a short head.
    // key() now resolves both sides through git before comparing (see
    // headsMatch above), so it collides with such a row regardless of
    // whether THIS caller happens to pass the short or the full spelling -
    // matching only the callers own raw pre-normalization spelling (an
    // earlier version of this fix) missed every legacy row once callers
    // (this files own pr-check.md included) always pass the full form.
    //
    // Re-keyed findings (codex-1, HIMMEL-2020 round 5): also check
    // key(effective(o)) - a finding moved by a prior amend re-key (--set
    // head=) lives, EFFECTIVELY, at its new head while its raw stored row
    // still reads the old one; matching only the raw row missed it, the same
    // gap the amend verbs own target lookup above already closes.
    //
    // Ambiguity refusal (codex-1, HIMMEL-2020 round 4): a stale legacy pair -
    // a short-keyed row AND a full-keyed row already both recorded for this
    // exact finding_id - now both resolve to the same commit and BOTH match,
    // and silently taking the last one via pop() would leave the OTHER row
    // (whichever was not picked) with its original verdict untouched,
    // possibly blocking gate 4 forever with no signal that anything was
    // wrong. Two distinct matches is a data-integrity anomaly the write path
    // must never guess through - refuse loudly and name both rows, same
    // posture as every other ambiguous-write refusal in this script.
    const priorMatches=parsed.filter(o=>key(o)||key(effective(o)));
    if(priorMatches.length>1){
      process.stderr.write("ledger-append.sh: finding "+e.ID+" matches "+priorMatches.length
        +" distinct existing rows (a legacy short-head + full-head pair) - refusing to guess which one to update.\n"
        +"  Reconcile manually: amend one row to re-key it onto the same head as the other\n"
        +"  (ledger-append.sh amend --head <its-current-head> --id "+e.ID+" --set head=<other-head> --reason \"<why>\"),\n"
        +"  then re-run.\n");
      process.exit(3);
    }
    const prior=priorMatches.pop();
    if(prior){
      const priorEff=effective(prior);
      // HIMMEL-2321 CR round 2 (codex-1): see the matching comment in the
      // --batch-file block above - ignore text only when rec (the incoming
      // write) omits it, never unconditionally.
      const ignoreText=!("text" in rec);
      const norm=(o)=>{const c={...o}; delete c.ts; if(ignoreText) delete c.text; return JSON.stringify(Object.keys(c).sort().map(k=>[k,c[k]]));};
      if(norm(priorEff)!==norm(rec)){
        const priorWithVerdict={...priorEff,verdict:rec.verdict};
        if(rec.reason) priorWithVerdict.reason=rec.reason;
        if(rec.deferred_to) priorWithVerdict.deferred_to=rec.deferred_to;
        const verdictOnly=String(priorEff.verdict||"")===""&&String(rec.verdict||"")!==""&&norm(priorWithVerdict)===norm(rec);
        if(verdictOnly){
          const set={verdict:rec.verdict};
          if(rec.reason) set.reason=rec.reason;
          if(rec.deferred_to) set.deferred_to=rec.deferred_to;
          const amend={kind:"amend",ts:e.TS,branch:e.BRANCH,target_head:prior.head,finding_id:e.ID,
                       artifact:e.ARTIFACT,perspective:e.PERSPECTIVE,set,
                       reason:"verdict appended after adjudication"};
          fs.appendFileSync(led, JSON.stringify(amend)+"\n");
          process.stderr.write("ledger-append.sh: appended verdict amend for "+e.ID+" at "+e.HEAD_.slice(0,8)+"\n");
          process.exit(0);
        }
        process.stderr.write("ledger-append.sh: finding "+e.ID+" is ALREADY recorded at head "+e.HEAD_
          +" with different content - NOTHING was written (the ledger dedups on head+finding_id).\n"
          +"  Correct it with the amend verb, which appends an auditable supersede record:\n"
          +"    ledger-append.sh amend --head "+e.HEAD_+" --id "+e.ID
          +" --set <key>=<value> --reason \"<why>\"\n");
        process.exit(3);
      }
      process.exit(0);
    }
    dup=false;
  } else if(e.KIND==="usage"){
    // chars/4 token estimate (hermes does not expose real usage via the one-shot
    // chokepoint — HIMMEL-485). The /4 lives here so it is computed in ONE place.
    const pc=Math.max(0, Number(e.PROMPT_CHARS)||0), rc=Math.max(0, Number(e.RESPONSE_CHARS)||0);
    const ept=Math.round(pc/4), ect=Math.round(rc/4);
    rec={kind:"usage",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,model:e.MODEL,prompt_chars:pc,response_chars:rc,est_prompt_tokens:ept,est_completion_tokens:ect,est_total_tokens:ept+ect,estimated:true,artifact:e.ARTIFACT,perspective:e.PERSPECTIVE};
    if(e.RESPONDING_MODEL) rec.responding_model=e.RESPONDING_MODEL;
    if(e.REASON) rec.reason=e.REASON;
    if(e.DETAIL) rec.detail=e.DETAIL;
    dup=existing.some(l=>{try{const o=JSON.parse(l);return o.kind==="usage"&&o.head===e.HEAD_&&o.model===e.MODEL&&(o.artifact||"diff")===e.ARTIFACT&&(o.perspective||"off")===e.PERSPECTIVE;}catch{return false;}});
  } else if(e.KIND==="attempt"){
    // HIMMEL-1500: per-attempt timing (start/duration/outcome) for a critic
    // invocation — the primary try AND every fallback candidate each get their
    // OWN row, so a chain of N tries at one head produces N rows. This is
    // deliberately NOT deduped like `avail` (one authoritative row per
    // head+model) — the whole point is to keep every attempt visible, so a
    // GLM row that times out on try 1 and completes on try 2 leaves BOTH
    // timings on the ledger for peak-window correlation, not just the last.
    // hour_utc is derived from ts here (one place) so a reader can bucket by
    // hour without re-parsing an ISO timestamp per row.
    rec={kind:"attempt",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,model:e.MODEL,status:e.STATUS,
         hour_utc:new Date(e.TS).getUTCHours(),artifact:e.ARTIFACT,perspective:e.PERSPECTIVE};
    if(e.RESPONDING_MODEL) rec.responding_model=e.RESPONDING_MODEL;
    if(e.ATTEMPT_NUM) rec.attempt=Number(e.ATTEMPT_NUM);
    if(e.DURATION_SECS!=="") rec.duration_secs=Number(e.DURATION_SECS)||0;
    if(e.DETAIL) rec.detail=e.DETAIL;
    dup=false;
  } else if(e.KIND==="delegation"){
    // HIMMEL-2335: one row per anchor->branch delegation event. NEVER
    // deduped, same posture as `attempt` - a repeat run at the same head
    // logs its own row rather than colliding with a prior one.
    rec={kind:"delegation",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,reason:e.REASON};
    if(e.DETAIL) rec.detail=e.DETAIL;
    dup=false;
  } else {
    rec={kind:"avail",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,model:e.MODEL,status:e.STATUS,artifact:e.ARTIFACT,perspective:e.PERSPECTIVE};
    if(e.RESPONDING_MODEL) rec.responding_model=e.RESPONDING_MODEL;
    if(e.REASON) rec.reason=e.REASON;
    if(e.DETAIL) rec.detail=e.DETAIL;
    // Monotone supersede (HIMMEL-1613). The supersession identity is
    // (head, model) ONLY — availability is a property of the critic+commit
    // pair, so a critic down at one head is down regardless of which review
    // arm (artifact/perspective) probed it. An unavailable -> ok recovery at
    // the same (head, model) therefore supersedes EVEN WHEN the two readings
    // came back on different artifact/perspective arms (HIMMEL-1640); matching
    // on those conjuncts left stale unavailable evidence alive when the ok
    // returned on a different arm. The STATUS transition then decides the
    // outcome: the ledger is append-only, so the LAST matching line is the
    // current effective record. Only an EXACT-status repeat is a quiet no-op
    // (the pre-existing idempotent-rerun contract). unavailable -> ok is a
    // genuine improvement (the fix this ticket exists for) and gets appended.
    // ok -> unavailable is a downgrade - a later transient failure must never
    // erase an earlier success, since that could dodge a real blocker - so it
    // is refused/dropped with its own message, same as the plain dedup above.
    //
    // Same-status RECLASSIFICATION (HIMMEL-2128): an identical-status repeat
    // used to be a flat dedup no-op regardless of `reason`/`detail`, so a lane
    // first classified unavailable(reason=quota) that later degrades to
    // unavailable(reason=config) kept showing quota forever. `reason` is now
    // gate-relevant (CR_FLOOR_FALLBACK reads it to judge VERIFIED exhaustion),
    // so a genuine reason/detail change must land. No new record kind is
    // needed to keep this append-only + auditable: a fresh `avail` row is
    // appended and the pre-existing "last matching line is the current
    // effective record" contract (see the unavailable->ok case below, and how
    // clear-cr-marker.sh reads this ledger) makes it authoritative without
    // rewriting anything — the superseded row stays on disk for audit.
    // An EXACT status+reason+detail repeat still dedups (the pre-existing
    // idempotent-rerun contract for a truly unchanged reading).
    const priorAvail=existing.map(l=>{try{return JSON.parse(l);}catch{return null;}})
        .filter(o=>o&&o.kind==="avail"&&o.head===e.HEAD_&&o.model===e.MODEL)
        .pop();
    if(!priorAvail){
      dup=false;
    } else if(priorAvail.status===e.STATUS){
      dup=(priorAvail.reason||"")===(e.REASON||"") && (priorAvail.detail||"")===(e.DETAIL||"");
    } else if(priorAvail.status==="unavailable"&&e.STATUS==="ok"){
      dup=false;
    } else {
      process.stderr.write("ledger-append.sh: avail record for "+e.MODEL+" at head "
        +String(e.HEAD_).slice(0,8)+" would DOWNGRADE status "+priorAvail.status+"->"+e.STATUS
        +" - refusing (an avail record may only improve unavailable->ok, never regress; HIMMEL-1613). Nothing written.\n");
      process.exit(0);
    }
  }
  // avail/usage keep the quiet-dedup contract: /pr-check re-runs them on the
  // same head as a matter of course, and turning that into an error would
  // break every existing caller. They are still not SILENT - the note says
  // plainly that nothing was written, which is what the incident actually
  // turned on. Only the finding kind (the record gate 4 blocks on) refuses a
  // conflicting rewrite, above.
  if(dup){
    process.stderr.write("ledger-append.sh: "+e.KIND+" record for "+e.MODEL+" at head "
      +String(e.HEAD_).slice(0,8)+" already exists - nothing written (dedup on head+model).\n");
    process.exit(0);
  }
  fs.appendFileSync(led, JSON.stringify(rec)+"\n");
'
