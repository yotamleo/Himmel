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
# --reason/--detail (HIMMEL-1176): OPTIONAL failure-classification capture,
# mainly for `avail --status unavailable` records so cr-scores.sh can report
# WHY a critic was down. Additive + back-compat: omitted -> the fields are
# ABSENT from the JSON (never emitted as empty strings), so every pre-existing
# caller and the dedup key (unchanged) are byte-for-byte unaffected.
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
set -uo pipefail
kind="${1:-}"; shift || true
case "$kind" in
  finding|avail|usage|amend) ;;
  *) echo "ledger-append.sh: kind must be finding|avail|usage|amend" >&2; exit 2;;
esac

branch="" head="" model="" responding_model="" id="" severity="" file="" line="" verdict="" status="" artifact="diff" perspective="off"
prompt_chars="" response_chars="" reason="" detail="" deferred_to="" set_pairs=""
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
  --set) set_pairs="$set_pairs$2"$'\n'; shift 2;;
  *) echo "ledger-append.sh: unknown $1" >&2; exit 2;;
esac; done

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
        # takes 7-40 hex chars and silently ignores anything else. Validating a
        # narrower shape here than the gate consumes is the split-validation
        # trap codex-1 already caught once on --deferred-to — so the two agree
        # exactly. Without this, `--set head=HEAD~1` re-keys a blocking finding
        # into nowhere and gate 4 fails OPEN.
        if ! printf '%s' "${_pair#head=}" | grep -qE '^[0-9a-fA-F]{7,40}$'; then
          echo "ledger-append.sh: --set head= must be a 7-40 char hex sha (got '${_pair#head=}') — anything else is not recognised as a head by the gate, so the finding would silently vanish from it" >&2
          exit 2
        fi ;;
    esac
  done <<< "$set_pairs"
fi

# --detail scrub (HIMMEL-1176): provider error bodies (rate-limit/auth/etc.
# messages) can echo request fragments or credentials. Lightweight, anchored
# redaction — not a full gitleaks scan (this is a hot per-call path with no
# external deps) — covering the common credential shapes gitleaks' default
# ruleset + this repo's own telegram-bot-token rule (.gitleaks.toml) flag.
# Scrub BEFORE truncating, so a secret cannot survive by being cut in half.
if [ -n "$detail" ]; then
  detail="$(printf '%s' "$detail" | sed -E \
    -e 's/[0-9]{8,10}:[A-Za-z0-9_-]{35}/[REDACTED]/g' \
    -e 's/(Bearer|bearer) [A-Za-z0-9._-]{16,}/\1 [REDACTED]/g' \
    -e 's/sk-[A-Za-z0-9]{16,}/[REDACTED]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED]/g' \
    -e 's/([Aa][Pp][Ii][_-]?[Kk]ey|[Tt]oken|[Ss]ecret)[[:space:]]*[:=][[:space:]]*[A-Za-z0-9._-]{12,}/\1=[REDACTED]/g')"
  # Flatten embedded newlines to spaces, then truncate to <=200 chars.
  detail="$(printf '%s' "$detail" | tr '\n' ' ')"
  detail="$(printf '%s' "$detail" | cut -c1-200)"
fi

ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"
[ -n "$ledger" ] || { echo "ledger-append.sh: cannot resolve ledger path (not a git repo? set CR_LEDGER)" >&2; exit 2; }
touch "$ledger" || { echo "ledger-append.sh: cannot write $ledger" >&2; exit 2; }

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Build the record + a dedup grep key via node (safe JSON + escaping).
KIND="$kind" BRANCH="$branch" HEAD_="$head" MODEL="$model" RESPONDING_MODEL="$responding_model" ID="$id" SEV="$severity" \
FILE="$file" LINE="$line" VERDICT="$verdict" STATUS="$status" \
PROMPT_CHARS="$prompt_chars" RESPONSE_CHARS="$response_chars" TS="$ts" LEDGER="$ledger" ARTIFACT="$artifact" PERSPECTIVE="$perspective" \
REASON="$reason" DETAIL="$detail" DEFERRED_TO="$deferred_to" SET_PAIRS="$set_pairs" node -e '
  const fs=require("fs"), e=process.env;
  const led=e.LEDGER;
  const existing=fs.existsSync(led)?fs.readFileSync(led,"utf8").split("\n").filter(Boolean):[];
  const key=(o)=>o.kind==="finding"&&o.head===e.HEAD_&&o.finding_id===e.ID
      &&(o.artifact||"diff")===e.ARTIFACT&&(o.perspective||"off")===e.PERSPECTIVE;

  // AMEND: append a supersede record pointing at an EXISTING finding. It never
  // rewrites a line - the ledger stays append-only, and the correction is
  // itself auditable. Refuses loudly when there is nothing to amend: a silent
  // success here would recreate the exact failure this verb exists to fix
  // (caller sees 0, record unchanged, gate still refuses).
  if(e.KIND==="amend"){
    const parsed=existing.map(l=>{try{return JSON.parse(l);}catch{return null;}}).filter(Boolean);
    // Resolve through PRIOR amends (codex-1 round 4). A re-key leaves the
    // original finding row untouched (append-only), so after moving a finding
    // A -> B the row still reads A while the ledger EFFECTIVELY places it at B.
    // Matching only the raw row would then reject an amend aimed at B - the
    // head the operator can actually see - on the one path they reach when they
    // are already stuck. Match either the original row or its effective state;
    // the emitted record still keys on the ORIGINAL head, so the reader in
    // clear-cr-marker needs no matching logic of its own.
    const SEP=String.fromCharCode(31);
    const prior=new Map();
    for(const a of parsed){
      if(a.kind!=="amend"||!a.set||typeof a.set!=="object") continue;
      const k=[a.target_head,a.finding_id,a.artifact||"diff",a.perspective||"off"].join(SEP);
      prior.set(k,Object.assign({},prior.get(k)||{},a.set));
    }
    const effective=(o)=>{
      const k=[o.head,o.finding_id,o.artifact||"diff",o.perspective||"off"].join(SEP);
      return prior.has(k)?Object.assign({},o,prior.get(k)):o;
    };
    const findings=parsed.filter(o=>o.kind==="finding");
    const target=findings.filter(o=>key(o)||key(effective(o))).pop();
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
    // A re-append that CHANGES the record is the wedge this ticket is about:
    // the old code hit the dedup key, wrote nothing, and exited 0, so the
    // caller believed the severity had been corrected while the gate kept
    // reading the original. Identical content is still a quiet success (re-
    // running /pr-check on the same head must stay idempotent); DIFFERING
    // content is now a loud refusal that names the sanctioned fix.
    const prior=existing.map(l=>{try{return JSON.parse(l);}catch{return null;}})
                        .filter(Boolean).filter(key).pop();
    if(prior){
      const norm=(o)=>{const c={...o}; delete c.ts; return JSON.stringify(Object.keys(c).sort().map(k=>[k,c[k]]));};
      if(norm(prior)!==norm(rec)){
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
    const priorAvail=existing.map(l=>{try{return JSON.parse(l);}catch{return null;}})
        .filter(o=>o&&o.kind==="avail"&&o.head===e.HEAD_&&o.model===e.MODEL)
        .pop();
    if(!priorAvail){
      dup=false;
    } else if(priorAvail.status===e.STATUS){
      dup=true;
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
