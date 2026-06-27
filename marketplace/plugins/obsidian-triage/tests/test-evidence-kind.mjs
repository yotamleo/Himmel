/**
 * test-evidence-kind.mjs — unit tests for inferEvidenceKind.
 *
 * Run: node tests/test-evidence-kind.mjs
 * (from marketplace/plugins/obsidian-triage/)
 *
 * No npm deps, no I/O: pure inference over plain objects.
 */
import { inferEvidenceKind } from "../tools/lib/evidence-kind.mjs";

let pass = 0;
let fail = 0;

function assert(desc, expected, actual) {
  const exp = JSON.stringify(expected);
  const act = JSON.stringify(actual);
  if (exp === act) {
    console.log(`  PASS  ${desc}`);
    pass++;
  } else {
    console.log(`  FAIL  ${desc}`);
    console.log(`         expected: ${exp}`);
    console.log(`         actual:   ${act}`);
    fail++;
  }
}

// --- multi-valued acceptance fixture (D4 required) ---
// github repo + research type + framework tag → both 'concepts' AND 'tools'
assert(
  "github+research+framework → ['concepts','tools'] (sorted, both present)",
  ["concepts", "tools"],
  inferEvidenceKind({ type: "research", url: "https://github.com/foo/bar", tags: ["framework", "rag"] })
);

// --- type:tweet → includes authors ---
assert(
  "type:tweet → ['authors']",
  ["authors"],
  inferEvidenceKind({ type: "tweet" })
);

// --- type:article → concepts ---
assert(
  "type:article → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ type: "article" })
);

// --- type:youtube → concepts ---
assert(
  "type:youtube → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ type: "youtube" })
);

// --- type:newsletter → concepts ---
assert(
  "type:newsletter → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ type: "newsletter" })
);

// --- type:reddit → concepts ---
assert(
  "type:reddit → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ type: "reddit" })
);

// --- github url → tools ---
assert(
  "url with github.com → ['tools']",
  ["tools"],
  inferEvidenceKind({ url: "https://github.com/owner/repo" })
);

// --- github url case-insensitive ---
assert(
  "url with GITHUB.COM (uppercase) → ['tools']",
  ["tools"],
  inferEvidenceKind({ url: "https://GITHUB.COM/owner/repo" })
);

// --- tag: tool → tools ---
assert(
  "tag 'tool' → ['tools']",
  ["tools"],
  inferEvidenceKind({ tags: ["tool"] })
);

// --- tag: cli → tools ---
assert(
  "tag 'cli' → ['tools']",
  ["tools"],
  inferEvidenceKind({ tags: ["cli"] })
);

// --- tag: plugin → tools ---
assert(
  "tag 'plugin' → ['tools']",
  ["tools"],
  inferEvidenceKind({ tags: ["plugin"] })
);

// --- tag: concept → concepts ---
assert(
  "tag 'concept' → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ tags: ["concept"] })
);

// --- tag: mental-model → concepts ---
assert(
  "tag 'mental-model' → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ tags: ["mental-model"] })
);

// --- tag: author → authors ---
assert(
  "tag 'author' → ['authors']",
  ["authors"],
  inferEvidenceKind({ tags: ["author"] })
);

// --- tag: person → authors ---
assert(
  "tag 'person' → ['authors']",
  ["authors"],
  inferEvidenceKind({ tags: ["person"] })
);

// --- tag: question → questions ---
assert(
  "tag 'question' → ['questions']",
  ["questions"],
  inferEvidenceKind({ tags: ["question"] })
);

// --- tag: open-question → questions ---
assert(
  "tag 'open-question' → ['questions']",
  ["questions"],
  inferEvidenceKind({ tags: ["open-question"] })
);

// --- tag: pattern → patterns ---
assert(
  "tag 'pattern' → ['patterns']",
  ["patterns"],
  inferEvidenceKind({ tags: ["pattern"] })
);

// --- tag: patterns → patterns ---
assert(
  "tag 'patterns' → ['patterns']",
  ["patterns"],
  inferEvidenceKind({ tags: ["patterns"] })
);

// --- clip matching nothing → misc ---
assert(
  "clip matching nothing → ['misc']",
  ["misc"],
  inferEvidenceKind({ type: "note" })
);

// --- graceful: missing fields → misc ---
assert(
  "inferEvidenceKind({}) → ['misc'], no throw",
  ["misc"],
  inferEvidenceKind({})
);

// --- graceful: undefined fields ---
assert(
  "inferEvidenceKind({type:undefined, url:undefined, tags:undefined}) → ['misc']",
  ["misc"],
  inferEvidenceKind({ type: undefined, url: undefined, tags: undefined })
);

// --- dedup: tags producing the same kind twice yields one entry ---
assert(
  "tool + cli tags both → tools (deduped, not doubled)",
  ["tools"],
  inferEvidenceKind({ tags: ["tool", "cli"] })
);

// --- sorted output deterministic: questions + patterns + concepts ---
assert(
  "questions + patterns + concepts → sorted ['concepts','patterns','questions']",
  ["concepts", "patterns", "questions"],
  inferEvidenceKind({ type: "article", tags: ["pattern", "question"] })
);

// --- tag case-insensitive: TOOL → tools ---
assert(
  "tag 'TOOL' (uppercase) → ['tools'] (case-insensitive)",
  ["tools"],
  inferEvidenceKind({ tags: ["TOOL"] })
);

// --- tag whitespace-trimmed ---
assert(
  "tag '  tool  ' (whitespace) → ['tools']",
  ["tools"],
  inferEvidenceKind({ tags: ["  tool  "] })
);

// --- framework maps to BOTH tools AND concepts ---
assert(
  "tag 'framework' alone → ['concepts','tools'] (maps to both)",
  ["concepts", "tools"],
  inferEvidenceKind({ tags: ["framework"] })
);

// --- tweet + author tag: dedup authors (only once) ---
assert(
  "type:tweet + tag 'author' → ['authors'] (deduped)",
  ["authors"],
  inferEvidenceKind({ type: "tweet", tags: ["author"] })
);

// --- misc NOT present when any other kind matched ---
assert(
  "when tools matched, misc absent",
  ["tools"],
  inferEvidenceKind({ url: "https://github.com/a/b" })
);

// --- empty tags array → misc ---
assert(
  "empty tags array, no type/url → ['misc']",
  ["misc"],
  inferEvidenceKind({ tags: [] })
);

// --- repo tag → tools ---
assert(
  "tag 'repo' → ['tools']",
  ["tools"],
  inferEvidenceKind({ tags: ["repo"] })
);

// --- sdk tag → tools ---
assert(
  "tag 'sdk' → ['tools']",
  ["tools"],
  inferEvidenceKind({ tags: ["sdk"] })
);

// --- library tag → tools ---
assert(
  "tag 'library' → ['tools']",
  ["tools"],
  inferEvidenceKind({ tags: ["library"] })
);

// --- ideas tag → concepts ---
assert(
  "tag 'idea' → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ tags: ["idea"] })
);

// --- theory tag → concepts ---
assert(
  "tag 'theory' → ['concepts']",
  ["concepts"],
  inferEvidenceKind({ tags: ["theory"] })
);

console.log("");
console.log(`Results: ${pass} passed, ${fail} failed`);
if (fail > 0) process.exit(1);
