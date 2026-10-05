'use strict';
// scripts/himmelctl/lib/feed-bundles.js — HIMMEL-4379: row id -> user-facing
// bundle, from the ONE table feed-bundles.json. Side-effect free (no I/O at
// require time) so the feed and bundle-registry-lint share one matcher.

const fs = require('fs');
const path = require('path');

const TABLE = path.join(__dirname, 'feed-bundles.json');
const UNSORTED = 'unsorted';

// [{ id, title, rows: [entry] }] in display order; throws on a missing/bad table.
function loadBundles(file) {
  const t = JSON.parse(fs.readFileSync(file || TABLE, 'utf8'));
  if (!t || !Array.isArray(t.bundles)) throw new Error(`${file || TABLE}: no bundles array`);
  for (const b of t.bundles) {
    const ok = b && typeof b.id === 'string' && typeof b.title === 'string' &&
      Array.isArray(b.rows) && b.rows.every((e) => typeof e === 'string');
    if (!ok) throw new Error(`${file || TABLE}: malformed bundle ${JSON.stringify(b && b.id)} (needs string id, title and a rows array of strings)`);
  }
  return t.bundles;
}

// An entry is an exact row id, or a prefix ending in '*' (the only wildcard).
function matches(entry, id) {
  return entry.endsWith('*') ? id.startsWith(entry.slice(0, -1)) : id === entry;
}

// The bundle id of a RAW (unredacted) row id; the first bundle with a matching
// entry wins (the lint keeps matches unique). No match = 'unsorted'.
function bundleOf(id, table) {
  for (const b of table) if (b.rows.some((e) => matches(e, id))) return b.id;
  return UNSORTED;
}

module.exports = { loadBundles, bundleOf, matches, UNSORTED };
