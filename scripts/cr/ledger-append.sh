#!/usr/bin/env bash
# scripts/cr/ledger-append.sh — deduped JSONL writer for the CR critic ledger
# (HIMMEL-415). Findings dedup on (head,finding_id); avail + usage dedup on
# (head,model). The `usage` kind (HIMMEL-485) records an ESTIMATED token count
# (chars/4 of the prompt+response) for the paid codex critic — hermes does not
# expose real usage through the one-shot chokepoint, so this is a cost SIGNAL,
# not a billed figure (every usage record carries "estimated":true).
set -uo pipefail
kind="${1:-}"; shift || true
[ "$kind" = "finding" ] || [ "$kind" = "avail" ] || [ "$kind" = "usage" ] || { echo "ledger-append.sh: kind must be finding|avail|usage" >&2; exit 2; }

branch="" head="" model="" id="" severity="" file="" line="" verdict="" status=""
prompt_chars="" response_chars=""
while [ $# -gt 0 ]; do case "$1" in
  --branch) branch="$2"; shift 2;; --head) head="$2"; shift 2;;
  --model) model="$2"; shift 2;; --id) id="$2"; shift 2;;
  --severity) severity="$2"; shift 2;; --file) file="$2"; shift 2;;
  --line) line="$2"; shift 2;; --verdict) verdict="$2"; shift 2;;
  --status) status="$2"; shift 2;;
  --prompt-chars) prompt_chars="$2"; shift 2;; --response-chars) response_chars="$2"; shift 2;;
  *) echo "ledger-append.sh: unknown $1" >&2; exit 2;;
esac; done

ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"
[ -n "$ledger" ] || { echo "ledger-append.sh: cannot resolve ledger path (not a git repo? set CR_LEDGER)" >&2; exit 2; }
touch "$ledger" || { echo "ledger-append.sh: cannot write $ledger" >&2; exit 2; }

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Build the record + a dedup grep key via node (safe JSON + escaping).
KIND="$kind" BRANCH="$branch" HEAD_="$head" MODEL="$model" ID="$id" SEV="$severity" \
FILE="$file" LINE="$line" VERDICT="$verdict" STATUS="$status" \
PROMPT_CHARS="$prompt_chars" RESPONSE_CHARS="$response_chars" TS="$ts" LEDGER="$ledger" node -e '
  const fs=require("fs"), e=process.env;
  const led=e.LEDGER;
  const existing=fs.existsSync(led)?fs.readFileSync(led,"utf8").split("\n").filter(Boolean):[];
  let rec, dup;
  if(e.KIND==="finding"){
    rec={kind:"finding",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,model:e.MODEL,finding_id:e.ID,severity:e.SEV,file:e.FILE,line:Number(e.LINE)||e.LINE,verdict:e.VERDICT};
    dup=existing.some(l=>{try{const o=JSON.parse(l);return o.kind==="finding"&&o.head===e.HEAD_&&o.finding_id===e.ID;}catch{return false;}});
  } else if(e.KIND==="usage"){
    // chars/4 token estimate (hermes does not expose real usage via the one-shot
    // chokepoint — HIMMEL-485). The /4 lives here so it is computed in ONE place.
    const pc=Math.max(0, Number(e.PROMPT_CHARS)||0), rc=Math.max(0, Number(e.RESPONSE_CHARS)||0);
    const ept=Math.round(pc/4), ect=Math.round(rc/4);
    rec={kind:"usage",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,model:e.MODEL,prompt_chars:pc,response_chars:rc,est_prompt_tokens:ept,est_completion_tokens:ect,est_total_tokens:ept+ect,estimated:true};
    dup=existing.some(l=>{try{const o=JSON.parse(l);return o.kind==="usage"&&o.head===e.HEAD_&&o.model===e.MODEL;}catch{return false;}});
  } else {
    rec={kind:"avail",ts:e.TS,branch:e.BRANCH,head:e.HEAD_,model:e.MODEL,status:e.STATUS};
    dup=existing.some(l=>{try{const o=JSON.parse(l);return o.kind==="avail"&&o.head===e.HEAD_&&o.model===e.MODEL;}catch{return false;}});
  }
  if(dup) process.exit(0);
  fs.appendFileSync(led, JSON.stringify(rec)+"\n");
'
