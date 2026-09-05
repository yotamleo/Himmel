#!/usr/bin/env bash
# test-wizard-gaps.sh — hermetic tests for the himmelctl `gaps` subcommand
# (HIMMEL-2348 deliverable 2): "what does starter not get from operator?"
# gaps diffs THIS setup's saved install profile against a reference profile
# (default docs/setup/profiles/operator.install-profile.json, or
# --preset <name>/--from-profile <path>) and prints four DISTINCT groups:
#   (a) answered off/none — the reference has it on, this setup turned it
#       off. The operator's OWN CHOICE, never framed as a deficiency.
#   (b) not recorded — the field is genuinely absent from this profile (a
#       profile written before the question existed), never a false "off"
#       answer the operator never made.
#   (c) reference-only — no wizard question can produce this yet. Rendered
#       from the checked-in scripts/himmelctl/tbd-delta.json map, itself
#       checked (case f below) against docs/setup/operator-profile-tbd-
#       delta.md so the two can never silently drift apart.
#   (d) present but unverified — this setup's answer matches the reference
#       (both "on"), but gaps is a static profile diff, not a live probe —
#       named as still-manual (run `himmelctl status` to confirm).
#
# `gaps` is a REPORT, not a gate: exit 0 whenever the report was produced,
# even when gaps exist (unlike status's severity model, which this is NOT).
# It never prompts (no readline anywhere in its code path) and never shells
# out — unlike test-wizard-status-cmd.sh's sibling suite it needs no
# HIMMELCTL_REPO_ROOT fixture at all: the default --preset (operator) reads
# the REAL checked-in docs/setup/profiles/operator.install-profile.json,
# same file `gaps` ships against.
#
# Covers:
#   a. a profile with a feature answered off (vs the operator reference)
#      appears under group (a), labelled as a choice, not a gap.
#   b. group (b) renders a reference-only item WITH its ticket id.
#   c. --json emits parseable JSON; assert on a field via node -e, not a
#      substring of prose.
#   d. exit code is 0 when gaps exist (a report, not a gate).
#   e. a missing install profile exits non-zero with the same clear message
#      cmdStatus/cmdEnsure already use.
#   f. doc<->map ROW-LEVEL agreement: every doc table row (# column) appears
#      as a key in scripts/himmelctl/tbd-delta.json's `entries` with the
#      SAME primary ticket, and vice versa (STRUCTURAL, not instructional —
#      this test fails the moment a row is dropped from either side, even
#      when its path/ticket happen to still appear via a different row —
#      HIMMEL-2348 CR: a path-keyed or ticket-set check is structurally
#      blind to exactly that kind of drift).
#   g. an identical-to-reference profile -> group (a) empty, group (c)
#      populated (present but unverified).
#   h. --from-profile points gaps at a profile file outside the cache.
#   i. --preset rejects a traversal name (reuses isValidProfileName —
#      Part A's fix made the whitespace/trim half of that guard live).
#   j. `gaps` is listed in the USAGE banner (bare --help and gaps --help).
#   k. HIMMEL-2348 CR finding 2: a field genuinely MISSING from this
#      profile (not "off", not even the key present) is reported as
#      "not recorded" — never as a choice the operator never made.
#   l. HIMMEL-2348 CR finding 3: a non-operator --preset omits the
#      operator-machine TBD-delta rows (group b) instead of presenting
#      them as gaps against that preset.
#   m. HIMMEL-2348 CR round 2 finding 4: a cadence id that's ARMED in the
#      reference but genuinely ABSENT (not "off") from this profile's own
#      `cadences` object is reported as "not recorded", never as a choice —
#      the same collapse case k already closed for GAPS_FIELDS, in the
#      cadence loop that was scoped out of round 1.
#   n. HIMMEL-2348 CR round 3 finding: a legacy v1 non-adopter (contributor)
#      profile — lanes:[] with no lanesMeaningful, the shape loadProfile's
#      own !isV2 role==='adopter' exemption lets validate — never answered
#      the lanes question at all. A reference lane absent from it must be
#      reported as "not recorded", never as a choice — the same collapse
#      case k/m already closed for GAPS_FIELDS/cadences, now closed for the
#      lane loop.
#   o. the OTHER direction of case n, pinned so the fix does not over-apply:
#      an EXPLICIT empty lane selection (lanes:[], lanesMeaningful:true —
#      write_cache_off's shape) is a real answer and must STILL be reported
#      as a choice, never as "not recorded".

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
tbd_delta_map="$repo_root/scripts/himmelctl/tbd-delta.json"
tbd_delta_doc="$repo_root/docs/setup/operator-profile-tbd-delta.md"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$tbd_delta_doc" ] || { echo "FAIL: $tbd_delta_doc not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }
# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (see sibling suites' identical helper for why: under `set -o
# pipefail`, printf/echo into `grep -q` can report a SUCCESSFUL early match
# as a failed pipeline — HIMMEL-1430).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/wizard-gaps.XXXXXX") || fail "mktemp -d failed"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# write_cache_off <cache_dir> — a v2 profile with every comparable field
# "off/none" relative to the operator reference: devOverlay/alwaysOn false,
# vault=none, handover=inline, no lanes, no cadences/bridge/luna/secretsWalk
# sections at all (absence reads as "off" the same way presence-vs-absence
# already does everywhere else in this schema).
write_cache_off() {
  mkdir -p "$1"
  cat > "$1/install-profile.json" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "devOverlay": false,
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON
}

# write_cache_match <cache_dir> — byte-identical to the real operator
# reference profile, so every comparable field is "on" both sides (group c:
# present but unverified; group a must be empty).
write_cache_match() {
  mkdir -p "$1"
  cp "$repo_root/docs/setup/profiles/operator.install-profile.json" "$1/install-profile.json"
}

# write_cache_missing_alwaysOn <cache_dir> — same as write_cache_off, EXCEPT
# the `alwaysOn` key is entirely ABSENT (not present-and-false) — an older
# profile written before this question existed. Used by case k (HIMMEL-2348
# CR finding 2) to prove a missing field is reported as "not recorded",
# never as an off-by-choice gap.
write_cache_missing_alwaysOn() {
  mkdir -p "$1"
  cat > "$1/install-profile.json" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "devOverlay": false,
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true
}
JSON
}

# write_cache_missing_cadence <cache_dir> — a `cadences` object that's
# PRESENT but omits the "pipeline" id entirely (armed in the operator
# reference) while explicitly answering "qmd" off — the round-2 twin of
# write_cache_missing_alwaysOn, for the cadence loop in diffProfiles. Used by
# case m (HIMMEL-2348 CR round 2 finding 4).
write_cache_missing_cadence() {
  mkdir -p "$1"
  cat > "$1/install-profile.json" <<'JSON'
{
  "schemaVersion": 2,
  "profile": "starter",
  "devOverlay": false,
  "scope": "project",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false,
  "cadences": { "qmd": "off" }
}
JSON
}

# write_cache_legacy_contributor <cache_dir> — a legacy v1 (no schemaVersion)
# profile with role: contributor and lanes:[] and NO lanesMeaningful key at
# all — the OLD lanes question was adopter-only, so a contributor cache never
# answered it; loadProfile's !isV2 role==='adopter' gate (bin.js ~1645)
# exempts exactly this shape from the "lanes:[] needs lanesMeaningful" refusal
# that would otherwise fire. Used by case n (HIMMEL-2348 CR round 3) to prove
# the lane loop treats this as never-asked, not as an empty choice.
write_cache_legacy_contributor() {
  mkdir -p "$1"
  cat > "$1/install-profile.json" <<'JSON'
{
  "role": "contributor",
  "scope": "project",
  "pluginSet": "lean",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "lanes": []
}
JSON
}

home="$work/home"; mkdir -p "$home"
homeWin=$(winpath "$home")

run_gaps() {
  # cache dir first arg, remaining args passed through to `gaps`.
  local _cache="$1"; shift
  HIMMELCTL_CACHE_DIR="$(winpath "$_cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_cache/luna-config.json")" HOME="$home" USERPROFILE="$homeWin" \
    "$node_bin" "$wizard" gaps "$@"
}

# ── case a/b: an all-off profile -> group (a) choice + group (b) ticket ────
cacheAB="$work/cache-ab"; write_cache_off "$cacheAB"
set +e
outAB=$(run_gaps "$cacheAB" 2>&1); rcAB=$?
set -e
[ "$rcAB" -eq 0 ] || fail "case a/b: gaps should exit 0 even with gaps present (got rc=$rcAB): $outAB"
grepq "$outAB" -i 'not a gap' || fail "case a: expected group (a) to label an off answer as a choice, not a gap (got: $outAB)"
grepq "$outAB" -i 'always-on' || fail "case a: expected the always-on field to appear as an off-by-choice gap (got: $outAB)"
grepq "$outAB" 'HIMMEL-2302' || fail "case b: expected a reference-only item to carry its ticket id (got: $outAB)"
echo "ok: case a/b — an all-off profile surfaces group (a) as a labelled choice and group (b) with a ticket id; exit 0"

# ── case c/d: --json is parseable, has the expected shape, exit 0 ─────────
outJSON=$(run_gaps "$cacheAB" --json)
node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (!Array.isArray(data.choices) || data.choices.length === 0) throw new Error("choices should be a non-empty array");
  if (!Array.isArray(data.referenceOnly) || data.referenceOnly.length === 0) throw new Error("referenceOnly should be a non-empty array");
  if (!Array.isArray(data.unverified)) throw new Error("unverified should be an array");
  const bad = data.referenceOnly.find((r) => !/^HIMMEL-\d+$/.test(r.ticket || ""));
  if (bad) throw new Error("every referenceOnly row must carry a HIMMEL-NNNN ticket, got: " + JSON.stringify(bad));
' <<< "$outJSON" || fail "case c: --json output failed shape assertions (got: $outJSON)"
echo "ok: case c/d — --json is parseable, has the expected {choices,referenceOnly,unverified} shape, every referenceOnly row carries a ticket"

# ── case e: a missing install profile exits non-zero with a clear message ──
cacheEmpty="$work/cache-empty"; mkdir -p "$cacheEmpty"
set +e
errE=$(run_gaps "$cacheEmpty" 2>&1); rcE=$?
set -e
[ "$rcE" -ne 0 ] || fail "case e: a missing install profile should exit non-zero (got rc=$rcE): $errE"
grepq "$errE" -F 'no himmelctl install profile found' || fail "case e: expected the standard missing-profile message (got: $errE)"
grepq "$errE" -F 'run himmelctl install first' || fail "case e: expected the standard missing-profile message (got: $errE)"
echo "ok: case e — a missing install profile exits non-zero with the standard message"

# ── case f: doc<->map ROW-LEVEL STRUCTURAL agreement — every doc table row
# (# column) must appear as a key in the map's `entries`, with the SAME
# primary ticket, and vice versa. A path- or ticket-SET check (the prior
# version of this test) is structurally blind to a dropped row whose
# path/ticket happen to still appear via a sibling row — HIMMEL-2348 CR:
# rows 2 and 4 both cite delta.cadences.extraArmedTasks, so a path-keyed map
# silently swallowed row 4 and the old set-based check still passed. This
# version fails the moment a row is missing from either side. It also keeps
# a path cross-check: every delta.*/profile.* path cited in a doc row's
# Item or "Captured how" cell must be listed in that SAME row's map entry
# (row 12 cites its one path, delta.alwaysOnInferred, parenthetically in the
# Item cell rather than in Captured how — scanning both is what the map's
# own paths[] is meant to agree with; scanning the whole row instead would
# false-positive on incidental mentions in the prose columns, as case f's
# ticket-extraction comment below already found for row 11's Classification
# cell).
# Extraction is scoped to actual table DATA rows (`^\|\s*\d+\s*\|`) and, for
# tickets, to the Classification cell specifically (not the whole row) — a
# naive whole-row scan false-positives on incidental ticket mentions inside
# the "Wizard coverage today" prose column (e.g. row 11 cites HIMMEL-2304 as
# unrelated background, not its own classification); the PRIMARY ticket is
# the first HIMMEL-NNNN in that cell (always the one right after
# "ticketed:" — a row's classification prose may parenthetically mention a
# second, unrelated ticket, as row 2 does).
# HIMMEL-2348 CR finding 4: the row-level check above still had two blind
# spots — a stale `label` in the map was never compared against the doc's
# Item cell at all, and a path check only ran doc->map (an EXTRA path in a
# map entry the doc never cites went unnoticed). Both extended below:
# label comparison uses a normalised WORD-CONTAINMENT rule (not exact
# equality): strip markdown backticks/emphasis, lowercase, split into a
# word set, and require that at least 90% of the map label's distinct words
# appear verbatim in the doc Item cell's word set. Exact equality is
# impractical here — the map's `label` is a hand-paraphrase of the doc's
# Item cell, not a copy (row 9's Item cell adds a parenthetical the label
# omits; row 12's Item cell says "the capture INFERS ... it is never an
# asked-and-recorded answer" where the label says "inferred ..., never
# asked-and-recorded" — same content, different inflection/wording) so a
# byte- or even whitespace/markdown-normalised equality check would fail on
# EVERY currently-correct row that paraphrases at all. Containment (map
# words found in doc words) tolerates that paraphrasing — extra explanatory
# clauses in the doc's longer prose don't hurt since we only require the
# map's (fewer, shorter) words to be present, not the reverse — while still
# failing hard on a label that's actually stale or copied from a different
# row, where most of its words won't appear in this row's Item cell at all.
docMapAgreement=$(node -e '
  const fs = require("fs");
  const doc = fs.readFileSync(process.argv[1], "utf8");
  const map = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).entries;
  const rows = doc.split(/\r?\n/).filter((l) => /^\|\s*\d+\s*\|/.test(l));
  if (rows.length === 0) throw new Error("no table data rows found in the doc — parser assumption broken");
  const words = (s) => new Set(
    s.replace(/[`*_]/g, "").toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)
  );
  const docRows = new Map(); // rowNum -> { ticket, paths: Set, itemWords: Set }
  for (const l of rows) {
    const cells = l.split("|");
    const rowNum = (cells[1] || "").trim();
    if (!/^\d+$/.test(rowNum)) throw new Error("unparseable row number in line: " + l);
    const itemCell = cells[2] || "";
    const capturedHowCell = cells[3] || "";
    const classificationCell = cells[5] || "";
    const pathPattern = /(?:delta|profile)\.[A-Za-z0-9_.]+/g;
    const paths = new Set([
      ...(itemCell.match(pathPattern) || []),
      ...(capturedHowCell.match(pathPattern) || []),
    ]);
    const tickets = classificationCell.match(/HIMMEL-\d+/g) || [];
    if (tickets.length === 0) throw new Error("row " + rowNum + " has no HIMMEL-NNNN ticket in its Classification cell");
    docRows.set(rowNum, { ticket: tickets[0], paths, itemWords: words(itemCell) });
  }
  const mapRowNums = new Set(Object.keys(map));
  const docRowNums = new Set(docRows.keys());
  const diff = (a, b) => [...a].filter((x) => !b.has(x));
  const problems = [];
  const missingFromMap = diff(docRowNums, mapRowNums);
  if (missingFromMap.length) problems.push("doc row(s) missing from map entries: " + JSON.stringify(missingFromMap));
  const missingFromDoc = diff(mapRowNums, docRowNums);
  if (missingFromDoc.length) problems.push("map entry/entries with no matching doc row: " + JSON.stringify(missingFromDoc));
  for (const rowNum of docRowNums) {
    if (!mapRowNums.has(rowNum)) continue;
    const docRow = docRows.get(rowNum);
    const mapRow = map[rowNum];
    if (mapRow.ticket !== docRow.ticket) {
      problems.push("row " + rowNum + ": ticket mismatch — doc=" + docRow.ticket + " map=" + mapRow.ticket);
    }
    const mapPaths = new Set(mapRow.paths || []);
    const missingPaths = [...docRow.paths].filter((p) => !mapPaths.has(p));
    if (missingPaths.length) {
      problems.push("row " + rowNum + ": path(s) cited in doc but missing from map entry: " + JSON.stringify(missingPaths));
    }
    const extraPaths = [...mapPaths].filter((p) => !docRow.paths.has(p));
    if (extraPaths.length) {
      problems.push("row " + rowNum + ": path(s) in map entry not cited in doc: " + JSON.stringify(extraPaths));
    }
    const labelWords = words(mapRow.label || "");
    if (labelWords.size === 0) {
      problems.push("row " + rowNum + ": map entry has no usable label (missing/empty/whitespace-only): " + JSON.stringify(mapRow.label));
    } else {
      const found = [...labelWords].filter((w) => docRow.itemWords.has(w));
      const ratio = found.length / labelWords.size;
      if (ratio < 0.9) {
        problems.push("row " + rowNum + ": map label looks stale vs doc Item cell (word overlap " + (found.length) + "/" + labelWords.size + "): map label=" + JSON.stringify(mapRow.label));
      }
    }
  }
  if (problems.length) { console.error(problems.join("\n")); process.exit(1); }
  console.log("agree: " + docRowNums.size + " doc rows, " + mapRowNums.size + " map entries");
' "$tbd_delta_doc" "$tbd_delta_map" 2>&1) || fail "case f: doc<->map row-level agreement check failed:
$docMapAgreement"
echo "ok: case f — doc<->map row-level structural agreement holds ($docMapAgreement)"

# ── case g: an identical-to-reference profile -> no choices, has unverified
cacheMatch="$work/cache-match"; write_cache_match "$cacheMatch"
outMatch=$(run_gaps "$cacheMatch" --json)
node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (data.choices.length !== 0) throw new Error("an identical profile should have zero off-by-choice gaps, got: " + JSON.stringify(data.choices));
  if (data.unverified.length === 0) throw new Error("an identical profile should have unverified (present-but-unconfirmed) entries");
' <<< "$outMatch" || fail "case g: identical-profile assertions failed (got: $outMatch)"
echo "ok: case g — an identical-to-reference profile has zero choices and non-empty unverified entries"

# ── case h: --from-profile points gaps at a profile outside the cache dir ──
standaloneProfile="$work/standalone.json"
cp "$repo_root/docs/setup/profiles/operator.install-profile.json" "$standaloneProfile"
cacheUnused="$work/cache-unused"; mkdir -p "$cacheUnused"  # deliberately no install-profile.json here
set +e
outH=$(HIMMELCTL_CACHE_DIR="$(winpath "$cacheUnused")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheUnused/luna-config.json")" HOME="$home" USERPROFILE="$homeWin" \
  "$node_bin" "$wizard" gaps --from-profile "$(winpath "$standaloneProfile")" 2>&1); rcH=$?
set -e
[ "$rcH" -eq 0 ] || fail "case h: --from-profile should let gaps run without a cache profile (got rc=$rcH): $outH"
echo "ok: case h — --from-profile points gaps at a profile outside the cache dir"

# ── case i: --preset rejects a traversal name ───────────────────────────────
set +e
errI=$(run_gaps "$cacheAB" --preset '../evil' 2>&1); rcI=$?
set -e
[ "$rcI" -ne 0 ] || fail "case i: --preset '../evil' should be rejected (got rc=$rcI): $errI"
grepq "$errI" -i 'preset' || fail "case i: expected an error naming --preset (got: $errI)"
echo "ok: case i — --preset rejects a path-traversal name"

# ── case j: gaps is listed in the USAGE banner ──────────────────────────────
outHelp=$(HIMMELCTL_CACHE_DIR="$(winpath "$work/help-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/help-cache/luna-config.json")" HOME="$home" USERPROFILE="$homeWin" \
  "$node_bin" "$wizard" --help)
grepq "$outHelp" 'gaps' || fail "case j: bare --help should list the gaps subcommand (got: $outHelp)"
echo "ok: case j — gaps is listed in the USAGE banner"

# ── case k: HIMMEL-2348 CR finding 2 — a field MISSING from this profile
# (not merely off) is reported as "not recorded", never as a choice ────────
cacheK="$work/cache-k"; write_cache_missing_alwaysOn "$cacheK"
outKjson=$(run_gaps "$cacheK" --json)
node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (!Array.isArray(data.notRecorded)) throw new Error("notRecorded should be an array");
  const bad = data.choices.find((c) => c.field === "alwaysOn");
  if (bad) throw new Error("a MISSING field must never be reported as a choice, got: " + JSON.stringify(bad));
  const nr = data.notRecorded.find((n) => n.field === "alwaysOn");
  if (!nr) throw new Error("a MISSING field should be reported as notRecorded, got: " + JSON.stringify(data.notRecorded));
' <<< "$outKjson" || fail "case k: --json missing-field assertions failed (got: $outKjson)"
outKtext=$(run_gaps "$cacheK")
grepq "$outKtext" -i 'not recorded' || fail "case k: expected a not-recorded section in console output (got: $outKtext)"
echo "ok: case k — a profile missing a field entirely is reported as not recorded, never as a choice"

# ── case l: HIMMEL-2348 CR finding 3 — a non-operator --preset omits the
# operator-machine TBD-delta rows (group b) rather than presenting them as
# gaps against that preset ──────────────────────────────────────────────────
repoStubL="$work/repo-stub-l"
mkdir -p "$repoStubL/docs/setup/profiles"
cp "$repo_root/docs/setup/profiles/operator.install-profile.json" "$repoStubL/docs/setup/profiles/custom.install-profile.json"
cacheL="$work/cache-l"; write_cache_off "$cacheL"
outLjson=$(HIMMELCTL_CACHE_DIR="$(winpath "$cacheL")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheL/luna-config.json")" HOME="$home" USERPROFILE="$homeWin" \
  HIMMELCTL_REPO_ROOT="$(winpath "$repoStubL")" "$node_bin" "$wizard" gaps --preset custom --json)
node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  if (!Array.isArray(data.referenceOnly) || data.referenceOnly.length !== 0) throw new Error("a non-operator preset must omit group (b), got: " + JSON.stringify(data.referenceOnly));
  if (data.referenceOnlyOmitted !== true) throw new Error("expected referenceOnlyOmitted:true for a non-operator preset");
' <<< "$outLjson" || fail "case l: --json non-operator-preset assertions failed (got: $outLjson)"
outLtext=$(HIMMELCTL_CACHE_DIR="$(winpath "$cacheL")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheL/luna-config.json")" HOME="$home" USERPROFILE="$homeWin" \
  HIMMELCTL_REPO_ROOT="$(winpath "$repoStubL")" "$node_bin" "$wizard" gaps --preset custom)
grepq "$outLtext" 'HIMMEL-2302' && fail "case l: a non-operator preset must not present the operator TBD ticket rows as its own (got: $outLtext)"
grepq "$outLtext" -i 'omitted' || fail "case l: expected an omission note explaining why group (b) is empty (got: $outLtext)"
echo "ok: case l — a non-operator --preset omits the operator-machine TBD rows instead of presenting them as its own"

# ── case m: HIMMEL-2348 CR round 2 finding 4 — a cadence id armed in the
# reference but genuinely ABSENT from this profile's own `cadences` object
# is reported as notRecorded, never as a choice ─────────────────────────────
cacheM="$work/cache-m"; write_cache_missing_cadence "$cacheM"
outMjson=$(run_gaps "$cacheM" --json)
node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const badChoice = data.choices.find((c) => c.field === "cadences.pipeline");
  if (badChoice) throw new Error("a MISSING cadence must never be reported as a choice, got: " + JSON.stringify(badChoice));
  const nr = data.notRecorded.find((n) => n.field === "cadences.pipeline");
  if (!nr) throw new Error("a MISSING cadence should be reported as notRecorded, got: " + JSON.stringify(data.notRecorded));
  // qmd was explicitly answered "off" (present, not absent) -> still a real choice.
  const qmdChoice = data.choices.find((c) => c.field === "cadences.qmd");
  if (!qmdChoice) throw new Error("an explicitly off cadence should still be reported as a choice, got: " + JSON.stringify(data.choices));
' <<< "$outMjson" || fail "case m: --json missing-cadence assertions failed (got: $outMjson)"
echo "ok: case m — a cadence armed in the reference but absent from this profile is reported as not recorded, never as a choice"

# ── case n: HIMMEL-2348 CR round 3 — a legacy v1 contributor profile
# (lanes:[], no lanesMeaningful) never answered the lanes question; a
# reference lane absent from it is reported as notRecorded, never a choice ──
cacheN="$work/cache-n"; write_cache_legacy_contributor "$cacheN"
outNjson=$(run_gaps "$cacheN" --json)
node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const badChoice = data.choices.find((c) => c.field === "lanes.codex");
  if (badChoice) throw new Error("a never-asked lanes profile must never report a lane as a choice, got: " + JSON.stringify(badChoice));
  const nr = data.notRecorded.find((n) => n.field === "lanes.codex");
  if (!nr) throw new Error("a never-asked lanes profile should report the reference lane as notRecorded, got: " + JSON.stringify(data.notRecorded));
' <<< "$outNjson" || fail "case n: --json never-asked-lanes assertions failed (got: $outNjson)"
echo "ok: case n — a legacy contributor profile that never answered lanes reports reference lanes as not recorded, never as a choice"

# ── case o: the other direction — an EXPLICIT empty lane selection
# (lanes:[], lanesMeaningful:true) is a real answer and stays a choice ──────
outOjson=$(run_gaps "$cacheAB" --json)
node -e '
  const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const nr = data.notRecorded.find((n) => n.field === "lanes.codex");
  if (nr) throw new Error("an EXPLICIT empty lane selection must never be reported as notRecorded, got: " + JSON.stringify(nr));
  const c = data.choices.find((c) => c.field === "lanes.codex");
  if (!c) throw new Error("an EXPLICIT empty lane selection should still be reported as a choice, got: " + JSON.stringify(data.choices));
' <<< "$outOjson" || fail "case o: --json explicit-empty-lanes assertions failed (got: $outOjson)"
echo "ok: case o — an explicit empty lane selection (lanesMeaningful:true) still reports reference lanes as a choice, never as not recorded"

echo "PASS"
