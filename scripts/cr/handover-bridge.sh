#!/usr/bin/env bash
# scripts/cr/handover-bridge.sh -- HIMMEL-2321: reads the CR ledger for one
# --head and drives BOTH handover bridges (scripts/handover/append-cr-findings.sh
# for reviewer-notes.md, scripts/handover/append-cr-bugs.sh for bugs.md)
# without ever putting reviewer-authored text (a finding title, a symptom)
# through a shell string. /pr-check steps 4.6/4.7 used to substitute that text
# straight into a shell fence as a quoted literal; a CodeRabbit finding title
# containing an apostrophe broke out of the surrounding quotes and could
# execute. This closes the class at its root: the node block below reads the
# ledger and calls each bridge via child_process.execFileSync, which spawns
# the child directly from an argv array -- argv is inert, never re-parsed by a
# shell, so no escaping rule is needed and none is invented. Neither bridge
# script needed to change.
#
# Usage:
#   handover-bridge.sh --head <sha> --branch <branch> \
#       [--notes <path>] [--bugs <path>] [--date <YYYY-MM-DD>] [--pr <n>]
#
# --head/--branch are REQUIRED and are never re-derived from git here (the
# caller pins the SHA the ledger review actually certifies, not live HEAD --
# HIMMEL-1175). At least one of --notes/--bugs is required; each half runs
# independently of the other (only --notes given -> only reviewer-notes.md is
# touched, and vice versa).
#
# Best-effort, matching append-cr-bugs.sh's own posture: steps 4.6/4.7 must
# never block the /pr-check gate, so this always exits 0 once arguments parse
# -- a missing/empty ledger, a node failure, or a bridge failure is reported
# on stderr and skipped, never fatal. Only an ARGUMENT error exits 2.
set -uo pipefail

head="" branch="" notes="" bugs="" date_="" pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head) [ $# -ge 2 ] || { echo "handover-bridge.sh: --head requires an argument" >&2; exit 2; }; head="$2"; shift 2;;
    --branch) [ $# -ge 2 ] || { echo "handover-bridge.sh: --branch requires an argument" >&2; exit 2; }; branch="$2"; shift 2;;
    --notes) [ $# -ge 2 ] || { echo "handover-bridge.sh: --notes requires an argument" >&2; exit 2; }; notes="$2"; shift 2;;
    --bugs) [ $# -ge 2 ] || { echo "handover-bridge.sh: --bugs requires an argument" >&2; exit 2; }; bugs="$2"; shift 2;;
    --date) [ $# -ge 2 ] || { echo "handover-bridge.sh: --date requires an argument" >&2; exit 2; }; date_="$2"; shift 2;;
    --pr) [ $# -ge 2 ] || { echo "handover-bridge.sh: --pr requires an argument" >&2; exit 2; }; pr="$2"; shift 2;;
    *) echo "handover-bridge.sh: unknown arg $1" >&2; exit 2;;
  esac
done

[ -n "$head" ] || { echo "handover-bridge.sh: --head required" >&2; exit 2; }
[ -n "$branch" ] || { echo "handover-bridge.sh: --branch required" >&2; exit 2; }
[ -n "$notes" ] || [ -n "$bugs" ] || { echo "handover-bridge.sh: at least one of --notes/--bugs required" >&2; exit 2; }

# Same resolution ledger-append.sh uses; honouring CR_LEDGER is what makes
# this script testable (tests never touch the real ledger).
ledger="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC2016  # the $-refs inside are a JS heredoc (process.env), not shell expansions
LEDGER="$ledger" TARGET_HEAD="$head" BRANCH="$branch" NOTES="$notes" BUGS="$bugs" DATE_="$date_" PR_="$pr" \
FINDINGS_BRIDGE="$HERE/../handover/append-cr-findings.sh" BUGS_BRIDGE="$HERE/../handover/append-cr-bugs.sh" \
node -e '
  const fs=require("fs"), os=require("os"), path=require("path"), cp=require("child_process"), e=process.env;
  try {
    const SEP=String.fromCharCode(31);   // same delimiter idiom as ledger-append.sh/clear-cr-marker.sh
    const TAB=String.fromCharCode(9);

    let lines=[];
    try { lines=fs.readFileSync(e.LEDGER,"utf8").split("\n").filter(Boolean); }
    catch(err) { process.stderr.write("handover-bridge: ledger unreadable at "+e.LEDGER+" ("+err.message+") - treating as empty (best effort)\n"); }
    // A row we cannot parse is a row we cannot ACCOUNT FOR, and that is not
    // the same as a row that is not there (CR round 1, codex-1).
    // append-cr-bugs.sh resolves an open bug whose finding-id is absent this
    // run, gated on that critic having recorded ok - so a corrupted FINDING
    // line silently dropped here, while the same critic own (still valid)
    // avail line says ok, reads as "the finding vanished" and falsely
    // resolves a still-open bug. Count the failures; the bugs half fails safe
    // on them below.
    const rows=[]; let malformed=0;
    for (const l of lines) { try { rows.push(JSON.parse(l)); } catch (err) { malformed++; } }
    if (malformed) process.stderr.write("handover-bridge: "+malformed+" unparseable ledger row(s) skipped - finding set may be incomplete\n");

    // Same amendsByKey / effective() shape as ledger-append.sh (405-413) and
    // clear-cr-marker.sh: collect amends FIRST, keyed by the ORIGINAL
    // (target_head, finding_id, artifact, perspective), later amends
    // shallow-merged over earlier ones for the same key.
    const amendsByKey=new Map();
    for (const a of rows) {
      if (a.kind!=="amend" || !a.set || typeof a.set!=="object") continue;
      const k=[a.target_head,a.finding_id,a.artifact||"diff",a.perspective||"off"].join(SEP);
      amendsByKey.set(k, Object.assign({}, amendsByKey.get(k)||{}, a.set));
    }

    // Reviewer text already has \n/\r flattened by ledger-append.sh on write;
    // this is defence in depth for a legacy row or an amend.set.text that
    // bypassed that scrub, so a stray line break can never corrupt a TSV row
    // or a downstream argv value.
    const clean=(s)=> typeof s==="string" ? s.replace(/[\r\n]/g," ") : "";

    // Select finding rows for TARGET_HEAD only, applying any amend BEFORE
    // comparing the head -- an amend can re-key a finding onto a different
    // head via set.head, exactly as clear-cr-marker.sh evaluates it.
    const findingsByKey=new Map();
    for (const o of rows) {
      if (o.kind!=="finding") continue;
      const origKey=[o.head,o.finding_id,o.artifact||"diff",o.perspective||"off"].join(SEP);
      const eff = amendsByKey.has(origKey) ? Object.assign({}, o, amendsByKey.get(origKey)) : o;
      // Select on (head, branch), never head alone (CR round 1, codex-2).
      // --branch was required but unused, which is exactly the hole
      // HIMMEL-1175 names on the other side: two branches can sit at the SAME
      // commit, so a SHA alone does not identify whose review this is, and
      // rows from the other branch would be copied into this handover item.
      // A row predating branch stamping has no branch field; accept it rather
      // than silently dropping it, since head still pins the commit.
      if (eff.head !== e.TARGET_HEAD) continue;
      if (eff.branch && eff.branch !== e.BRANCH) continue;
      // A row that PARSES but is missing the fields this bridge must forward
      // is unusable evidence, and unusable is not the same as absent -- the
      // same distinction the malformed-row fail-safe above turns on, one
      // level deeper (CodeRabbit App, PR 2097). Dropping such a row silently
      // would delete a REAL finding from the findings file while its critic
      // avail row still says ok, which is precisely the licence
      // append-cr-bugs.sh needs to resolve the bug it belongs to. Count it
      // into the same incomplete-ledger state so the avail rows are withheld.
      if (!eff.finding_id || typeof eff.finding_id!=="string" || !eff.severity) {
        malformed++;
        process.stderr.write("handover-bridge: finding row at head "+String(eff.head).slice(0,8)+" is missing finding_id or severity - unusable, counted as an incomplete ledger\n");
        continue;
      }
      const k2=[eff.finding_id||"?",eff.artifact||"diff",eff.perspective||"off"].join(SEP);
      findingsByKey.set(k2, eff);   // last row at this head wins (file order)
    }
    const findings=[...findingsByKey.values()];

    // avail rows are not amendable; last row per model at this head wins.
    // Deliberately NOT branch-scoped, unlike findings above: the gate
    // (clear-cr-marker.sh) keys availByModel on (head, model) alone -
    // availability is a property of the critic+commit pair, not of which
    // review arm probed it (HIMMEL-1613/1640). Filtering by branch here would
    // make this bridge see FEWER avail rows than the gate does, so the
    // handover trail could disagree with the gate about what covered a head
    // (HIMMEL-2405) - do not "restore symmetry" with the findings loop.
    const availByModel=new Map();
    for (const o of rows) {
      if (o.kind!=="avail" || o.head!==e.TARGET_HEAD) continue;
      availByModel.set(o.model, typeof o.status==="string" ? o.status : "");
    }
    const avail=[...availByModel.entries()].map(([slug,status])=>({slug,status}));

    const parts=[];

    if (e.NOTES) {
      let notesN=0, notesFailed=0;
      for (const f of findings) {
        const args=["--notes",e.NOTES,"--head",e.TARGET_HEAD];
        if (e.DATE_) args.push("--date",e.DATE_);
        if (e.PR_) args.push("--pr",e.PR_);
        args.push(
          "--id", f.finding_id || "",
          "--severity", f.severity || "",
          "--file", f.file || "",
          "--line", String(f.line==null ? "" : f.line),
          "--title", clean(f.text || ""),
          "--verdict", (f.verdict==null ? "" : f.verdict)
        );
        // Count the WRITE, not the attempt (CR round 1, codex-3). This summary
        // is relayed verbatim into the /pr-check report, so a failed append
        // counted as a success is the report claiming a finding reached
        // reviewer-notes when it did not - the same false-evidence class the
        // gate exists to prevent.
        try {
          cp.execFileSync("bash",[e.FINDINGS_BRIDGE,...args],{stdio:["ignore","ignore","inherit"]});
          notesN++;
        } catch(err) {
          notesFailed++;
          process.stderr.write("handover-bridge: append-cr-findings.sh failed for "+(f.finding_id||"?")+": "+err.message+"\n");
        }
      }
      parts.push(notesN+" finding(s) -> reviewer-notes"+(notesFailed?" ("+notesFailed+" FAILED)":""));
    }

    if (e.BUGS) {
      // 4.7 tracks blocking findings only (crit/imp); a finding adjudicated
      // away (disproved/deferred) is not an open blocker and must not open
      // or reopen a bug for it.
      const blocking=findings.filter(f=>{
        if (f.severity!=="crit" && f.severity!=="imp") return false;
        const v=typeof f.verdict==="string" ? f.verdict.trim() : f.verdict;
        return v!=="disproved" && v!=="deferred";
      });
      const availOut = malformed ? [] : avail;
      const tmpDir=fs.mkdtempSync(path.join(os.tmpdir(),"handover-bridge-"));
      const findingsPath=path.join(tmpDir,"findings.tsv");
      const availPath=path.join(tmpDir,"avail.tsv");
      try {
        // Child stderr is INHERITED, never piped: append-cr-bugs.sh is
        // best-effort and ALWAYS exits 0, so a piped stderr would be captured
        // into an exception that never fires and its diagnostics would vanish
        // on the very path that needs them.
        // Zero blocking findings is the normal clean-review state, not a
        // reason to skip: an empty findings file still gets written and the
        // bridge is still called, so it can resolve vanished tracked bugs
        // off the avail rows.
        fs.writeFileSync(findingsPath, blocking.map(f=>[f.finding_id||"",f.severity||"",clean(f.text||"")].join(TAB)).join("\n")+(blocking.length?"\n":""));
        // FAIL SAFE on an incomplete finding set (CR round 1, codex-1): the
        // avail rows are what LICENSE append-cr-bugs.sh to resolve a bug whose
        // finding is absent this run. If any ledger row failed to parse we
        // cannot prove a finding is genuinely gone rather than merely
        // unreadable, so we withhold that licence by passing an EMPTY avail
        // file: opening and reopening still work (those only ever ADD), and
        // nothing can be resolved on evidence we do not have.
        // (declared with let above the try, so the summary below can read it.)
        if (malformed) process.stderr.write("handover-bridge: withholding "+avail.length+" avail row(s) from append-cr-bugs.sh - an unparseable ledger row means a missing finding cannot be told from a resolved one, so no bug is auto-resolved this run\n");
        fs.writeFileSync(availPath, availOut.map(a=>[a.slug,a.status].join(TAB)).join("\n")+(availOut.length?"\n":""));
        try { cp.execFileSync("bash",[e.BUGS_BRIDGE,"--bugs",e.BUGS,"--findings",findingsPath,"--avail",availPath],{stdio:["ignore","ignore","inherit"]}); }
        catch(err) { process.stderr.write("handover-bridge: append-cr-bugs.sh failed: "+err.message+"\n"); }
      } finally {
        fs.rmSync(tmpDir,{recursive:true,force:true});
      }
      // Report what was FORWARDED, not what was found (CR round 3, codex-3):
      // when malformed rows withheld the avail evidence, availOut is empty and
      // saying otherwise makes this relayed line claim evidence reached
      // bugs.md that deliberately did not. Same truthfulness rule as the
      // notes half above.
      parts.push(blocking.length+" blocking + "+availOut.length+" avail row(s) -> bugs.md"+(malformed?" ("+avail.length+" withheld)":""));
    }

    process.stdout.write("handover-bridge: "+parts.join(", ")+"\n");
  } catch (err) {
    process.stderr.write("handover-bridge: unexpected error: "+err.message+"\n");
  }
' || true

exit 0
