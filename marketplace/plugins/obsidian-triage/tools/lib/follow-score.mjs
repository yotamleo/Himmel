#!/usr/bin/env node
// follow-score.mjs — HIMMEL-660 X-follow-list scorer, Task 7: deterministic
// scoring/tiering math + ranking + render. Pure (no filesystem, no
// network) — the assemble subcommand (follow-list-score.mjs) is the only
// caller that touches disk.
//
// Pinned constants (Global Constraints — do not vary without a spec
// change):
//   composite(scores) = 0.25*factual_reliability + 0.25*resources
//     + 0.25*focus_fit + 0.15*substance + 0.10*reach   (each 0-5 -> 0-5)
//   adjusted(composite, confidence) = composite * {high:1.0, med:0.85, low:0.70}[confidence]
//   tierOf(adjusted): >=3.8 -> 1; >=2.8 -> 2; >=1.8 -> 3; else "exclude"
//
// Every dimension is scored on exactly the same axes regardless of topic
// (the judge charter's neutrality rule) -- this file has no notion of
// topic at all, only the five numeric dimensions above.
//
// rankAccounts sorts by (tier, adjusted desc, factual_reliability desc,
// resources desc, canonical handle lexical asc), THEN applies overrides:
//   - force-exclude removes the handle regardless of score.
//   - whitelist ensures presence -- if the computed tier is "exclude", the
//     handle is placed at Tier 3 (lowest visible tier) with an override
//     note. No promotion beyond Tier 3.

import { normalizeHandle } from "./follow-roster.mjs";

const CONFIDENCE_FACTOR = { high: 1.0, med: 0.85, low: 0.70 };

/** composite(scores): weighted 0-5 blend of the five judge dimensions. */
export function composite(scores) {
  const s = scores || {};
  return (
    0.25 * (s.factual_reliability || 0) +
    0.25 * (s.resources || 0) +
    0.25 * (s.focus_fit || 0) +
    0.15 * (s.substance || 0) +
    0.10 * (s.reach || 0)
  );
}

/** adjusted(composite, confidence): composite scaled by confidence factor. */
export function adjusted(compositeScore, confidence) {
  return compositeScore * CONFIDENCE_FACTOR[confidence];
}

/** tierOf(adjustedScore): >=3.8 -> 1; >=2.8 -> 2; >=1.8 -> 3; else "exclude". */
export function tierOf(adjustedScore) {
  if (adjustedScore >= 3.8) return 1;
  if (adjustedScore >= 2.8) return 2;
  if (adjustedScore >= 1.8) return 3;
  return "exclude";
}

// "exclude" sorts after every numbered tier.
function tierRank(tier) {
  return tier === "exclude" ? 4 : tier;
}

/**
 * Ranks judgments into `{handle, scores, confidence, rationale,
 * grounding_notes, composite, adjusted, tier, overrideNote}[]`, applying
 * overrides last (per the spec: sort first on computed scores, then apply
 * force-exclude/whitelist, THEN the tie-break re-sort settles final order
 * including any override-promoted entries).
 */
export function rankAccounts(judgments, overrides = {}) {
  const whitelist = new Set((overrides.whitelist || []).map(normalizeHandle));
  const excludeSet = new Set((overrides.exclude || []).map(normalizeHandle));

  let entries = (judgments || []).map((j) => {
    const c = composite(j.scores);
    const a = adjusted(c, j.confidence);
    return {
      handle: normalizeHandle(j.handle),
      scores: j.scores,
      confidence: j.confidence,
      rationale: j.rationale,
      grounding_notes: j.grounding_notes,
      composite: c,
      adjusted: a,
      tier: tierOf(a),
      overrideNote: null,
    };
  });

  // Force-exclude: removes the handle regardless of score.
  entries = entries.filter((e) => !excludeSet.has(e.handle));

  // Whitelist: ensures presence -- if the computed tier is "exclude",
  // force it to Tier 3 (lowest visible) with an override note. No
  // promotion beyond Tier 3.
  entries = entries.map((e) => {
    if (whitelist.has(e.handle) && e.tier === "exclude") {
      return {
        ...e,
        tier: 3,
        overrideNote: `override: whitelisted (computed tier was exclude, adjusted=${e.adjusted.toFixed(2)})`,
      };
    }
    return e;
  });

  entries.sort((x, y) => {
    const byTier = tierRank(x.tier) - tierRank(y.tier);
    if (byTier !== 0) return byTier;
    if (y.adjusted !== x.adjusted) return y.adjusted - x.adjusted;
    const xf = (x.scores && x.scores.factual_reliability) || 0;
    const yf = (y.scores && y.scores.factual_reliability) || 0;
    if (yf !== xf) return yf - xf;
    const xr = (x.scores && x.scores.resources) || 0;
    const yr = (y.scores && y.scores.resources) || 0;
    if (yr !== xr) return yr - xr;
    return x.handle.localeCompare(y.handle);
  });

  return entries;
}

// ---------------------------------------------------------------------------
// Render: ai-x-follow-list.md (tier sections only) + ai-x-follow-scores.md.
// ---------------------------------------------------------------------------

function isTierHeading(line) {
  return /^## Tier \d+/i.test(line) || /^## Excluded/i.test(line);
}

const TIER_TITLES = {
  1: "Tier 1 — Must-follow",
  2: "Tier 2 — Strong",
  3: "Tier 3 — Solid",
};

function bulletFor(e) {
  const score = e.adjusted.toFixed(1);
  let desc = e.rationale || "";
  if (e.overrideNote) desc = desc ? `${desc} [${e.overrideNote}]` : `[${e.overrideNote}]`;
  return `- **[@${e.handle}](https://x.com/${e.handle})** (${score}) — ${desc}`;
}

function tierSectionsText(ranked) {
  const byTier = { 1: [], 2: [], 3: [] };
  const excluded = [];
  for (const e of ranked) {
    if (e.tier === "exclude") excluded.push(e);
    else byTier[e.tier].push(e);
  }

  const parts = [];
  for (const t of [1, 2, 3]) {
    parts.push(`## ${TIER_TITLES[t]}`, "");
    parts.push(...(byTier[t].length ? byTier[t].map(bulletFor) : ["_none_"]));
    parts.push("");
  }
  parts.push("## Excluded", "");
  parts.push(...(excluded.length ? excluded.map(bulletFor) : ["_none_"]));
  return parts.join("\n") + "\n";
}

/**
 * Regenerates ONLY the tier sections (`## Tier N …` / `## Excluded …`) of
 * `existingFileContent`, keeping everything else (frontmatter, any footer
 * such as "Why this list exists") byte-identical. If no tier section is
 * found, the generated sections are appended at the end of the file.
 * Deterministic: no timestamps, no generated content outside `ranked`.
 */
export function renderList(ranked, existingFileContent = "") {
  const lines = existingFileContent === "" ? [] : existingFileContent.split("\n");

  let spanStart = lines.length;
  for (let i = 0; i < lines.length; i++) {
    if (isTierHeading(lines[i])) {
      spanStart = i;
      break;
    }
  }

  // The regenerated span ends at the FIRST of: a non-tier `## ` heading, a
  // blockquote line (`> ...`), or a bare `---` line -- whichever comes
  // first. Real vault files have no trailing `## ` heading (their tail is
  // an operator blockquote + `---` + footer prose + a `Related:` line), so
  // relying on a heading alone would fall through to EOF and destroy that
  // tail (HIMMEL-660 Task 7 review).
  let spanEnd = lines.length;
  for (let i = spanStart + 1; i < lines.length; i++) {
    const line = lines[i];
    if (
      (line.startsWith("## ") && !isTierHeading(line)) ||
      line.startsWith(">") ||
      line === "---"
    ) {
      spanEnd = i;
      break;
    }
  }

  const genLines = tierSectionsText(ranked).split("\n");
  const outLines = lines.slice(0, spanStart).concat(genLines, lines.slice(spanEnd));
  return outLines.join("\n");
}

/**
 * Renders the scorecard (ai-x-follow-scores.md): one block per ranked
 * account with subscores, confidence, composite/adjusted, a
 * verified-vs-asserted evidence summary (pulled from the matching
 * dossier's claims), and a one-line rationale. `dossiers` is a plain
 * object keyed by (normalized) handle -> dossier. An account whose
 * dossier carries `roster.clip_count === 0` is flagged `low_sample`.
 */
export function renderScorecard(ranked, dossiers = {}) {
  const lines = ["# X Follow-List Scorecard (HIMMEL-660)", ""];

  for (const e of ranked) {
    const dossier = dossiers[e.handle];
    const claims = (dossier && dossier.claims) || [];
    const verified = claims.filter((c) => c.status === "verified");
    const other = claims.length - verified.length;
    const s = e.scores || {};

    lines.push(`### @${e.handle} — Tier ${e.tier}`);
    lines.push(
      `- scores: factual_reliability=${s.factual_reliability}, resources=${s.resources}, focus_fit=${s.focus_fit}, substance=${s.substance}, reach=${s.reach}`
    );
    lines.push(`- confidence: ${e.confidence}`);
    lines.push(`- composite: ${e.composite.toFixed(2)}`);
    lines.push(`- adjusted: ${e.adjusted.toFixed(2)}`);
    lines.push(
      `- evidence: ${verified.length} verified / ${other} other` +
        (verified.length ? ` — verified: ${verified.map((c) => `"${c.text}"`).join("; ")}` : " — verified: none")
    );
    if (dossier && dossier.roster && dossier.roster.clip_count === 0) {
      lines.push("- low_sample: true (roster.clip_count == 0)");
    }
    // Spec invariant: every visible (Tier 1/2/3) entry must cite >=1
    // verified claim OR carry confidence:low. This is only true by judge
    // discipline, not enforced elsewhere -- surface a loud (non-fatal)
    // warning so a bad judge pass is visible instead of silently shipping.
    if ((e.tier === 1 || e.tier === 2 || e.tier === 3) && verified.length === 0 && e.confidence !== "low") {
      console.error(
        `WARN: ${e.handle} in Tier ${e.tier} has no verified evidence and confidence=${e.confidence} — violates grounding invariant`
      );
    }
    if (e.overrideNote) lines.push(`- override: ${e.overrideNote}`);
    lines.push(`- rationale: ${e.rationale || ""}`);
    lines.push("");
  }

  return lines.join("\n") + "\n";
}
