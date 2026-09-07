#!/usr/bin/env bash
# cr-ledger-evidence.sh — does the CR critic panel carry the gate at this SHA?
# (HIMMEL-1465.)
#
# WHY THIS EXISTS. CodeRabbit's App review is rate limited at times, and when it
# is it posts state=success + description="Review rate limited" — a DECLINED
# review that cr-signal.sh projects to state=skipped (HIMMEL-1354). Both the
# certifier (check-ci.sh) and the merge hook (cr-merge-gate.sh, the CR gate
# behind block-unresolved-cr-merge.sh) fail CLOSED on that, so a rate-limited
# App blocks a merge even when the critic PANEL (codex+glm) had already reviewed
# the exact head cleanly and recorded that in the CR ledger. The operator's
# standing rule (stated 3x since 2026-07-30): when the App is rate-limited, a
# CLEAN panel at the PR's CURRENT head + 0 unresolved threads carries the gate.
#
# This lib is the ONE reader for that evidence. The verdict it derives MIRRORS
# scripts/cr/clear-cr-marker.sh gates 3-4 exactly — the same amend application,
# the same atHead resolution (short SHAs resolved through git, never prefix
# match — the HIMMEL-2190 prefix step only SKIPS heads that cannot match,
# it never accepts one), the same responder floor (>=1 `avail ... status=ok`), and the same
# blocking definition (crit|imp whose verdict is neither `disproved` nor a
# TRACKED `deferred`). clear-cr-marker is the reference; this is the same
# evaluation factored for the two MERGE gates. A future unification would move
# clear-cr-marker onto this reader too — left out of HIMMEL-1465 to keep that
# change off the most-sensitive surface (clear-cr-marker is untouched here).
#
# Evidence-gated, fail-closed, NEVER a free pass: this only ANSWERS the question
# "did the panel carry the gate at this head". The caller decides whether that
# answer lets a rate-limited CodeRabbit skip stand, and ONLY ever asks it on the
# rate-limited description (the sole skip wording that is panel-carriable). A
# clean ledger never waves through an ABSENT, pending, failed, or
# auto-reviews-disabled CodeRabbit review — those keep their current verdict.
#
# cr_ledger_carries_gate <full-sha>
#   rc 0 = the panel CARRIES the gate at this SHA: >=1 responder recorded
#          `avail ... status=ok` here AND no blocking finding AND no malformed
#          ledger line. stdout: "carried responders=<N> models=<comma list>"
#          (the responder models, for the merge-gate audit line).
#   rc 1 = the panel does NOT carry the gate here, OR the evidence cannot be
#          read reliably (no git dir / no node / ledger unreadable / malformed
#          line / zero responders / a blocking finding). stdout: a short
#          machine reason (no-git-dir|no-node|ledger-unreadable|malformed:N|
#          no-responders|blocking:<ids>). The caller treats rc 1 uniformly as
#          "evidence absent -> current verdict stands" (HIMMEL-1465): for
#          check-ci that is exit 2, for cr-merge-gate it is rc 2 (block).
#
# GATE INTEGRITY (mirrors clear-cr-marker.sh / merge-on-green.sh): the ledger
# path is FIXED at `<git-common-dir>/cr-critic-scores.jsonl` and is NOT
# environment-overridable here. ledger-append.sh honors a CR_LEDGER override for
# its WRITES, but this GATE must never read a caller-pointed ledger — that would
# let a contaminated environment forge the evidence the carry depends on.
# check-ci.sh / cr-merge-gate.sh / gh are likewise not overridable from here.
#
# Sourceable from check-ci.sh and cr-merge-gate.sh: uses only `return`, never
# `exit`; does not toggle set -e. bash 3.2-safe.

cr_ledger_carries_gate() {
    local full_sha="${1:-}"

    # Resolve the FIXED ledger location. Empty (no git dir) => cannot read
    # evidence => not carried.
    local git_dir
    git_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)
    if [ -z "$git_dir" ]; then
        printf 'no-git-dir\n'; return 1
    fi
    local ledger="$git_dir/cr-critic-scores.jsonl"

    # node reads + evaluates the ledger. Missing => cannot read => not carried.
    command -v node >/dev/null 2>&1 || { printf 'no-node\n'; return 1; }

    # The evaluation mirrors clear-cr-marker.sh gates 3-4 verbatim (amend
    # application, atHead resolution, responder floor, blocking definition). The
    # block is single-quoted for the shell, so NO apostrophes / backticks /
    # dollar-braces may appear inside it (same constraint as clear-cr-marker's
    # twin block). It emits a SPACE-delimited decision line the bash below
    # parses with `case` (no jq/node second pass needed). carried=<0|1> is the
    # verdict; responders=/models= ride along for the audit line on a carry,
    # reason= names the refusal otherwise.
    local line
    line=$(LEDGER="$ledger" FULL_SHA="$full_sha" node -e '
      const fs = require("fs"), e = process.env;
      const lines = fs.existsSync(e.LEDGER)
          ? fs.readFileSync(e.LEDGER, "utf8").split("\n").filter(Boolean) : [];
      const cp = require("child_process");
      // atHead: a ledger head is EVIDENCE — it must name this commit, not merely
      // look like it. Prefix equality accepted any record whose head shared the
      // first 7 chars, so a DIFFERENT commit with a colliding abbreviation
      // satisfied the gate. /pr-check writes SHORT heads, so short-SHA support
      // survives via RESOLVE-then-compare; an unresolvable or ambiguous
      // abbreviation resolves to null and matches nothing.
      const HEX = "0123456789abcdef";
      const isHex = (s) => s.length >= 7 && s.length <= 40 &&
          s.split("").every((c) => HEX.indexOf(c) >= 0);
      const cache = new Map();
      const resolve = (h) => {
          if (!cache.has(h)) {
              let full = null;
              try {
                  full = cp.execFileSync("git",
                      ["rev-parse", "--verify", "--quiet", h + "^{commit}"],
                      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
              } catch { full = null; }
              cache.set(h, full || null);
          }
          return cache.get(h);
      };
      const atHead = (o) => {
          const h = String(o.head || "");
          // Exact string equality FIRST: a head identical to the one the caller
          // asked about IS evidence at that head, hex-shaped or not. In
          // production FULL_SHA is a full 40-hex oid, so any h equal to it is
          // hex anyway and this ordering is semantically identical — it only
          // lets hermetic suites use short stub heads. isHex then gates ONLY
          // the resolve path, where prefix collisions are the actual risk.
          if (e.FULL_SHA === h) return true;
          if (!isHex(h)) return false;
          // HIMMEL-2190: PREFIX PRE-FILTER, identical to clear-cr-marker.sh (see
          // the long note there). git resolves an abbreviation by object-name
          // prefix, so resolve(h) can only return FULL_SHA when h is a prefix of
          // it; a non-prefix head needs no git call. Performance only - the
          // resolve-then-compare decision for every surviving head is unchanged,
          // and an ambiguous prefix still resolves to null and matches nothing.
          if (!e.FULL_SHA.startsWith(h)) return false;
          return resolve(h) === e.FULL_SHA;
      };
      // A malformed record is a REFUSAL, not a skip: silently skipping
      // unparseable lines fails OPEN (a blocking finding corrupted while an
      // avail-ok line stays readable would clear the gate unevaluated). An
      // unreadable ledger is an unknown verdict, and unknown is never clean.
      let responders = 0, models = [], blocking = [], malformed = 0;
      // AMENDS: the ledger is append-only, so a correction arrives as a
      // supersede record. Collect them FIRST (keyed by the ORIGINAL tuple) and
      // apply before any finding is judged, so a correction (wrong severity,
      // wrong head) actually takes effect. Later amends win per key; a set.head
      // re-keys the finding, so atHead evaluates it against its real head.
      // SEP is U+001F (unit separator) via fromCharCode — no raw control byte
      // in the file, and U+001F cannot occur in a sha/slug/artifact/perspective
      // (so two tuples cannot flatten to one key and mis-route an amend).
      const SEP = String.fromCharCode(31);
      const amends = new Map();
      for (const l of lines) {
          let a;
          try { a = JSON.parse(l); } catch { continue; }
          if (a.kind !== "amend" || !a.set || typeof a.set !== "object") continue;
          const k = [a.target_head, a.finding_id, a.artifact || "diff", a.perspective || "off"].join(SEP);
          amends.set(k, Object.assign({}, amends.get(k) || {}, a.set));
      }
      for (const l of lines) {
          let o;
          try { o = JSON.parse(l); } catch { malformed++; continue; }
          if (o.kind === "amend") continue;
          if (o.kind === "finding") {
              const k = [o.head, o.finding_id, o.artifact || "diff", o.perspective || "off"].join(SEP);
              if (amends.has(k)) o = Object.assign({}, o, amends.get(k));
          }
          if (!atHead(o)) continue;
          if (o.kind === "avail" && o.status === "ok") {
              responders++;
              const model = (typeof o.model === "string" ? o.model : "").trim();
              if (model) models.push(model);
          }
          if (o.kind === "finding" && (o.severity === "crit" || o.severity === "imp")
              && o.verdict !== "disproved") {
              // DEFERRAL: accepted ONLY when TRACKED — verdict deferred AND a
              // ticket key AND a reason. A bare "deferred" stays blocking (a
              // third truthful exit, not a free pass).
              const ticket = typeof o.deferred_to === "string" ? o.deferred_to.trim() : "";
              const why = typeof o.reason === "string" ? o.reason.trim() : "";
              if (o.verdict === "deferred" && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(ticket) && why) {
                  continue;
              }
              blocking.push((o.finding_id || "?") + "(" + o.severity + "," +
                  (o.verdict || "no-verdict") + ")");
          }
      }
      if (malformed > 0) {
          process.stdout.write("carried=0 reason=malformed:" + malformed);
      } else if (responders < 1) {
          process.stdout.write("carried=0 reason=no-responders");
      } else if (blocking.length > 0) {
          process.stdout.write("carried=0 reason=blocking:" + blocking.join(","));
      } else {
          process.stdout.write("carried=1 responders=" + responders +
              " models=" + (models.length ? models.join(",") : "?"));
      }
    ' 2>/dev/null) || line=""
    if [ -z "$line" ]; then
        printf 'ledger-unreadable\n'; return 1
    fi

    # Parse the decision line (key=value tokens). `case` anchors each token
    # from its start, so carried= / reason= / responders= / models= never
    # collide regardless of order.
    local carried="" reason="" responders="" models="" tok
    for tok in $line; do
        case "$tok" in
            carried=*)   carried=${tok#carried=} ;;
            reason=*)    reason=${tok#reason=} ;;
            responders=*) responders=${tok#responders=} ;;
            models=*)    models=${tok#models=} ;;
        esac
    done
    if [ "$carried" = "1" ]; then
        printf 'carried responders=%s models=%s\n' "${responders:-?}" "${models:-?}"
        return 0
    fi
    printf '%s\n' "${reason:-not-carried}"
    return 1
}
