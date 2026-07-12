#!/usr/bin/env bash
# Tests for LUNA-57 component-scan.mjs + lib/component-extract.mjs.
#
# Scope (no live gh — end-to-end ingest is LUNA calibration):
#   1. scripts parse (node --check)
#   2. usage / arg-error exit codes
#   3. pure lib: classifyPath / extractComponent / componentKey / select
#   4. Components/ library upsert: create, cross-repo seen_in dedup, idempotent
#   5. path-safety: componentsDir traversal blocked
#   6. SKILL.md documents --deep + Phase 3.5 + Reusable components + Components dest
#
# Cross-platform: bash on Linux/macOS/Git-Bash. Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # PLUGIN_DIR used in Test 6 (Task 7 adds that block)
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
# shellcheck disable=SC2034  # SCRIPT used in Test 1/2/4/5 (Tasks 4-6 add those blocks)
SCRIPT="$TOOLS_DIR/component-scan.mjs"
LIB="$TOOLS_DIR/lib/component-extract.mjs"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

pass=0
fail=0
assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

# -- Test 1: scripts parse via node --check -------------------------------
echo "Test 1: scripts parse"
for f in "$SCRIPT" "$LIB"; do
  if [ ! -r "$f" ]; then assert "$(basename "$f") exists" yes no; else
    assert "$(basename "$f") exists" yes yes
    if node --check "$f" 2>/dev/null; then s=ok; else s=fail; fi
    assert "$(basename "$f") parses" ok "$s"
  fi
done

# -- Test 2: usage / arg errors -------------------------------------------
echo "Test 2: usage on missing --repo"
node "$SCRIPT" --vault /tmp/x >/dev/null 2>&1; rc=$?
assert "missing --repo exits 1" 1 "$rc"
node "$SCRIPT" -h >/dev/null 2>&1; rc=$?
assert "-h exits 0" 0 "$rc"
node "$SCRIPT" --repo foo >/dev/null 2>&1; rc=$?
assert "malformed --repo (no slash) exits 1" 1 "$rc"
node "$SCRIPT" --repo "../../etc" >/dev/null 2>&1; rc=$?
assert "traversal --repo exits 1" 1 "$rc"

# -- Test 3a: classifyPath rules ------------------------------------------
echo "Test 3a: classifyPath"
lib_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$LIB")"
cat >"$tmpdir/classify-test.mjs" <<EOF
import { classifyPath } from "$lib_url";
const cases = [
  [".claude/skills/foo/SKILL.md", "skill"],
  ["marketplace/plugins/x/skills/bar/SKILL.md", "skill"],
  [".claude/commands/deploy.md", "command"],
  ["commands/ship.md", "command"],
  [".claude/agents/reviewer.md", "agent"],
  ["agents/explorer.md", "agent"],
  [".claude-plugin/plugin.json", "plugin-manifest"],
  ["marketplace.json", "plugin-manifest"],
  [".claude-plugin/marketplace.json", "plugin-manifest"],
  ["tools/dedup.mjs", "tool"],
  ["tools/crawl.py", "tool"],
  ["tools/run.sh", "tool"],
  ["tools/lib/helper.mjs", "tool"],
  ["README.md", null],
  ["src/index.ts", null],
  ["skills/foo/reference.md", null],
  ["tools/data.json", null],
  [null, null],
  [undefined, null],
  ["", null],
];
let bad = 0;
for (const [p, want] of cases) {
  const got = classifyPath(p);
  if (got !== want) { bad++; console.log("MISMATCH " + p + " want=" + want + " got=" + got); }
}
console.log("CLASSIFY_BAD=" + bad);
EOF
classify_bad="$(node "$tmpdir/classify-test.mjs" 2>&1 | grep -oE 'CLASSIFY_BAD=[0-9]+' | cut -d= -f2)"
assert "classifyPath: all cases match" "0" "${classify_bad:-99}"

# -- Test 3b: extractComponent + componentKey + componentSlug -------------
echo "Test 3b: extractComponent"
cat >"$tmpdir/extract-test.mjs" <<EOF
import { extractComponent, componentKey, componentSlug } from "$lib_url";

// skill with frontmatter name + description
const skill = extractComponent({ path: "skills/foo-bar/SKILL.md", type: "skill",
  content: "---\nname: Foo Bar\ndescription: Does the foo.\n---\nbody" });
console.log("SKILL_NAME=" + skill.name);
console.log("SKILL_DESC=" + skill.description);

// command with NO frontmatter name -> basename fallback
const cmd = extractComponent({ path: ".claude/commands/deploy.md", type: "command",
  content: "---\ndescription: Ship it.\n---\nbody" });
console.log("CMD_NAME=" + cmd.name);

// plugin manifest JSON
const man = extractComponent({ path: ".claude-plugin/plugin.json", type: "plugin-manifest",
  content: '{"name":"my-plugin","description":"A plugin."}' });
console.log("MAN_NAME=" + man.name);
console.log("MAN_DESC=" + man.description);

// malformed JSON -> basename, empty desc, no throw
const bad = extractComponent({ path: "marketplace.json", type: "plugin-manifest",
  content: "{not json" });
console.log("BAD_NAME=" + bad.name);
console.log("BAD_DESC=[" + bad.description + "]");

// tool -> first doc/comment line
const tool = extractComponent({ path: "tools/run.mjs", type: "tool",
  content: "#!/usr/bin/env node\n/**\n * run.mjs — does the thing.\n */\n" });
console.log("TOOL_NAME=" + tool.name);
console.log("TOOL_DESC=" + tool.description);

// key + slug
console.log("KEY=" + componentKey({ type: "skill", name: "Foo Bar" }));
console.log("SLUG=" + componentSlug("Foo  Bar!!"));

// I-1 regression: frontmatter with --- inside a value must not truncate later fields
const tricky = extractComponent({ path: "skills/tricky/SKILL.md", type: "skill",
  content: "---\nname: Foo\ndescription: has --- dashes\nextra: kept\n---\nbody" });
console.log("TRICKY_NAME=" + tricky.name);
console.log("TRICKY_DESC=" + tricky.description);

// I-2 regression (IM-4): empty-slug names must be deterministic-but-UNIQUE,
// never a shared constant "unnamed" that false-merges distinct components.
const slugSpecial = componentSlug("!!!");
const slugCJK = componentSlug("分析");
console.log("SPECIAL_SLUG=" + slugSpecial);
console.log("CJK_SLUG=" + slugCJK);
console.log("SLUG_NONEMPTY=" + (slugSpecial.length > 0 && slugCJK.length > 0));
console.log("SLUG_FSAFE=" + (/^[a-z0-9-]+$/.test(slugSpecial) && /^[a-z0-9-]+$/.test(slugCJK)));
console.log("SLUG_DISTINCT=" + (slugSpecial !== slugCJK));
console.log("SLUG_STABLE=" + (componentSlug("!!!") === slugSpecial));
const keySpecial = componentKey({ type: "skill", name: "!!!" });
const keyCJK = componentKey({ type: "skill", name: "分析" });
console.log("KEY_DISTINCT=" + (keySpecial !== keyCJK));
EOF
out="$(node "$tmpdir/extract-test.mjs" 2>&1)"
echo "$out" | grep -q 'SKILL_NAME=Foo Bar'        && r=yes || r=no; assert "skill name from frontmatter" yes "$r"
echo "$out" | grep -q 'SKILL_DESC=Does the foo.'  && r=yes || r=no; assert "skill description from frontmatter" yes "$r"
echo "$out" | grep -q 'CMD_NAME=deploy'           && r=yes || r=no; assert "command name basename fallback" yes "$r"
echo "$out" | grep -q 'MAN_NAME=my-plugin'        && r=yes || r=no; assert "manifest name from JSON" yes "$r"
echo "$out" | grep -q 'MAN_DESC=A plugin.'        && r=yes || r=no; assert "manifest desc from JSON" yes "$r"
echo "$out" | grep -q 'BAD_NAME=marketplace'      && r=yes || r=no; assert "malformed JSON -> basename, no throw" yes "$r"
echo "$out" | grep -q 'BAD_DESC=\[\]'             && r=yes || r=no; assert "malformed JSON -> empty desc" yes "$r"
echo "$out" | grep -q 'TOOL_NAME=run.mjs'         && r=yes || r=no; assert "tool name = basename" yes "$r"
echo "$out" | grep -q 'TOOL_DESC=run.mjs — does the thing.' && r=yes || r=no; assert "tool desc = first doc line" yes "$r"
echo "$out" | grep -q 'KEY=skill:foo-bar'         && r=yes || r=no; assert "componentKey = type:slug" yes "$r"
echo "$out" | grep -q 'SLUG=foo-bar'              && r=yes || r=no; assert "componentSlug normalises" yes "$r"
echo "$out" | grep -q 'TRICKY_NAME=Foo'           && r=yes || r=no; assert "I-1: tricky frontmatter name parsed" yes "$r"
echo "$out" | grep -q 'TRICKY_DESC=has --- dashes' && r=yes || r=no; assert "I-1: tricky frontmatter desc not truncated by inner ---" yes "$r"
echo "$out" | grep -q 'SLUG_NONEMPTY=true'        && r=yes || r=no; assert "I-2: empty-slug fallback is non-empty" yes "$r"
echo "$out" | grep -q 'SLUG_FSAFE=true'           && r=yes || r=no; assert "I-2: empty-slug fallback is filesystem-safe" yes "$r"
echo "$out" | grep -q 'SLUG_DISTINCT=true'        && r=yes || r=no; assert "I-2: distinct special/CJK names -> distinct slugs" yes "$r"
echo "$out" | grep -q 'SLUG_STABLE=true'          && r=yes || r=no; assert "I-2: identical name -> identical slug (dedup)" yes "$r"
echo "$out" | grep -q 'KEY_DISTINCT=true'         && r=yes || r=no; assert "I-2: distinct empty-slug names -> distinct componentKeys" yes "$r"

# -- Test 3c: selectComponentPaths (filter + cap + tail-skip) -------------
echo "Test 3c: selectComponentPaths"
cat >"$tmpdir/select-test.mjs" <<EOF
import { selectComponentPaths } from "$lib_url";
const tree = [
  ".claude/skills/a/SKILL.md",
  "node_modules/foo/skills/x/SKILL.md",   // excluded
  "commands/b.md",
  "agents/c.md",
  "tools/d.mjs",
  ".claude-plugin/plugin.json",
  "README.md",                             // not a component
  "tools/node_modules/dep/e.mjs",          // excluded
];
const r = selectComponentPaths(tree, { maxComponents: 3 });
console.log("SELECTED=" + r.selected.length);
console.log("SKIPPED=" + r.skipped);
const all = selectComponentPaths(tree, { maxComponents: 100 });
console.log("ALL=" + all.selected.length);
console.log("ALL_SKIPPED=" + all.skipped);
EOF
out="$(node "$tmpdir/select-test.mjs" 2>&1)"
echo "$out" | grep -q 'SELECTED=3'    && r=yes || r=no; assert "select respects maxComponents cap" yes "$r"
echo "$out" | grep -q 'SKIPPED=2'     && r=yes || r=no; assert "select tail-skips beyond cap" yes "$r"
echo "$out" | grep -q 'ALL=5'         && r=yes || r=no; assert "select finds 5 components (node_modules excluded)" yes "$r"
echo "$out" | grep -q 'ALL_SKIPPED=0' && r=yes || r=no; assert "select no skip when under cap" yes "$r"

# -- Test 4: upsertComponentNote — create, dedup seen_in, idempotent ------
echo "Test 4: upsertComponentNote"
vault="$tmpdir/cvault"; mkdir -p "$vault/.obsidian"
script_url="$(node -e 'console.log(require("url").pathToFileURL(process.argv[1]).href)' "$SCRIPT")"
cat >"$tmpdir/upsert-test.mjs" <<EOF
import { upsertComponentNote } from "$script_url";
const vault = "$vault";
const opts = { vault, componentsDir: "30-Resources/Components", dryRun: false };
const recA = { name: "Foo Bar", type: "skill", description: "Does foo.", path: "skills/foo-bar/SKILL.md",
  repo: "alice/repo1", key: "skill:foo-bar", trust_tier: "known-author", safety_flag: "" };
const recB = { ...recA, repo: "bob/repo2", path: "x/skills/foo-bar/SKILL.md" };
const r1 = await upsertComponentNote(recA, opts); console.log("R1=" + r1.changed);
const r2 = await upsertComponentNote(recA, opts); console.log("R2=" + r2.changed);
const r3 = await upsertComponentNote(recB, opts); console.log("R3=" + r3.changed);
EOF
out="$(node "$tmpdir/upsert-test.mjs" 2>&1)"
note="$vault/30-Resources/Components/skill/foo-bar.md"
[ -f "$note" ] && r=yes || r=no;                                   assert "4: note created at type/slug path" yes "$r"
echo "$out" | grep -q 'R1=true'  && r=yes || r=no;                 assert "4: first upsert writes" yes "$r"
echo "$out" | grep -q 'R2=false' && r=yes || r=no;                 assert "4: re-upsert same repo idempotent" yes "$r"
echo "$out" | grep -q 'R3=true'  && r=yes || r=no;                 assert "4: new repo updates seen_in" yes "$r"
grep -q 'alice/repo1' "$note" && grep -q 'bob/repo2' "$note" && r=yes || r=no; assert "4: seen_in lists both repos" yes "$r"
seen_count=$(grep -cE '^\s+- ' "$note"); [ "$seen_count" -ge 2 ] && r=yes || r=no; assert "4: seen_in has >=2 entries" yes "$r"

# -- Test 4c: cross-repo risk escalation (LUNA-57 I1) ---------------------
echo "Test 4c: cross-repo risk escalation"
vault4c="$tmpdir/cvault4c"; mkdir -p "$vault4c/.obsidian"
cat >"$tmpdir/escalate-test.mjs" <<EOF
import { upsertComponentNote, escalateTrustTier } from "$script_url";

// Pure-unit asserts on the helper.
console.log("UNIT1=" + escalateTrustTier("known-author", "community-thin"));
console.log("UNIT2=" + escalateTrustTier("anything", "unknown-risk"));
// Order-independence: same result regardless of argument order.
const oA = escalateTrustTier("community-thin", "anthropic-official");
const oB = escalateTrustTier("anthropic-official", "community-thin");
console.log("ORDER_INDEP=" + (oA === oB && oA === "community-thin"));
// Tie-break: a recognised label wins the rank tie over a garbage string.
console.log("TIEBREAK=" + escalateTrustTier("garbage", "unknown-risk"));

const vault = "$vault4c";
const opts = { vault, componentsDir: "30-Resources/Components", dryRun: false };
// First create: known-author, blank safety_flag.
const recA = { name: "Risky Tool", type: "tool", description: "Does risk.", path: "tools/risky.mjs",
  repo: "alice/safe", key: "tool:risky-tool", trust_tier: "known-author", safety_flag: "" };
// Later, SAME tool path from a different repo: community-thin + red-team flag.
// (Tools dedup by repo-relative path (LUNA-61), so recB keeps recA's path.)
const recB = { ...recA, repo: "bob/sketchy",
  trust_tier: "community-thin", safety_flag: "red-team+agent" };
const r1 = await upsertComponentNote(recA, opts); console.log("E_R1=" + r1.changed);
const r2 = await upsertComponentNote(recB, opts); console.log("E_R2=" + r2.changed);
EOF
oute="$(node "$tmpdir/escalate-test.mjs" 2>&1)"
note4c="$vault4c/30-Resources/Components/tool/tools-risky-mjs.md"
echo "$oute" | grep -q 'UNIT1=community-thin' && r=yes || r=no; assert "4c: escalateTrustTier(known-author,community-thin)=community-thin" yes "$r"
echo "$oute" | grep -q 'UNIT2=unknown-risk'   && r=yes || r=no; assert "4c: escalateTrustTier(anything,unknown-risk)=unknown-risk" yes "$r"
echo "$oute" | grep -q 'ORDER_INDEP=true'     && r=yes || r=no; assert "4c: escalateTrustTier order-independent" yes "$r"
echo "$oute" | grep -q 'TIEBREAK=unknown-risk' && r=yes || r=no; assert "4c: rank-tie prefers recognised label (garbage,unknown-risk)" yes "$r"
echo "$oute" | grep -q 'E_R2=true'            && r=yes || r=no; assert "4c: escalating upsert reports changed" yes "$r"
grep -qE '^trust_tier: "unknown-risk"$' "$note4c"   && r=yes || r=no; assert "4c: trust_tier escalated to unknown-risk via flag (quoted)" yes "$r"
grep -qE '^safety_flag: "red-team\+agent"$' "$note4c" && r=yes || r=no; assert "4c: safety_flag inherited from later flagged repo (quoted)" yes "$r"
grep -q 'alice/safe' "$note4c" && grep -q 'bob/sketchy' "$note4c" && r=yes || r=no; assert "4c: seen_in lists both repos" yes "$r"

# -- Test 4b: upsertComponentNote — revert-path (malformed frontmatter) ---
echo "Test 4b: revert-path on malformed frontmatter"
cat >"$tmpdir/revert-test.mjs" <<EOF
import { upsertComponentNote } from "$script_url";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve, join } from "node:path";
import os from "node:os";

// Use os.tmpdir() so Node resolves paths consistently on all platforms
// (bash mktemp produces POSIX /c/... paths on Windows that Node.js cannot
// resolve without normalizeVaultPath — os.tmpdir() returns the native path).
const vault4b = join(os.tmpdir(), "cvault4b-" + process.pid);
mkdirSync(vault4b, { recursive: true });
const opts = { vault: vault4b, componentsDir: "30-Resources/Components", dryRun: false };

// Positive control: valid YAML note with one existing seen_in entry; add a new repo.
// upsertComponentNote writes only if YAML stays valid → ok:true, changed:true.
// The new repo's key appears in the file IFF the write + YAML-validate succeeded.
const posDest = resolve(vault4b, "30-Resources/Components/command");
mkdirSync(posDest, { recursive: true });
const posPath = join(posDest, "pos-ctrl.md");
writeFileSync(posPath, [
  "---",
  "type: component",
  "component_type: command",
  'name: "Pos Ctrl"',
  "component_key: command:pos-ctrl",
  'description: "positive control note"',
  "seen_in:",
  '  - "existing/repo#commands/pos-ctrl.md"',
  "trust_tier: unknown",
  "safety_flag: ",
  "---",
  "",
  "# Pos Ctrl (command)",
  "",
  "positive control note",
  "",
  "## Seen in",
  "",
  "- [existing/repo](https://github.com/existing/repo) — \`commands/pos-ctrl.md\`",
  "",
].join("\\n"), "utf-8");
const posRec = { name: "Pos Ctrl", type: "command", description: "positive control note",
  path: "commands/pos-ctrl.md", repo: "newowner/newrepo", key: "command:pos-ctrl",
  trust_tier: "unknown", safety_flag: "" };
const posResult = await upsertComponentNote(posRec, opts);
const posAfter = readFileSync(posPath, "utf-8");
// Validate by checking result + that new repo appears in file
// (upsertComponentNote only writes after successful YAML parse).
console.log("POS_OK=" + posResult.ok);
console.log("POS_CHANGED=" + posResult.changed);
console.log("POS_HAS_NEW=" + posAfter.includes("newowner/newrepo"));

// Negative control: frontmatter with an unterminated quoted string.
// After the seen_in entry is inserted the YAML parse must fail → revert.
const negDest = resolve(vault4b, "30-Resources/Components/tool");
mkdirSync(negDest, { recursive: true });
// Tools key by repo-relative path (LUNA-61): notedPath(tools/bad.mjs) -> tools-bad-mjs.md
const negPath = join(negDest, "tools-bad-mjs.md");
// Intentionally broken YAML: unterminated string in frontmatter
const badContent = [
  "---",
  "type: component",
  "component_type: tool",
  'name: "Bad Yaml',
  "component_key: tool:bad-yaml",
  'description: "broken"',
  "seen_in:",
  "trust_tier: unknown",
  "safety_flag: ",
  "---",
  "",
  "# Bad Yaml (tool)",
  "",
  "## Seen in",
  "",
].join("\\n");
writeFileSync(negPath, badContent, "utf-8");
const negRec = { name: "Bad Yaml", type: "tool", description: "broken",
  path: "tools/bad.mjs", repo: "x/y", key: "tool:bad-yaml",
  trust_tier: "unknown", safety_flag: "" };
const negResult = await upsertComponentNote(negRec, opts);
const negAfter = readFileSync(negPath, "utf-8");
console.log("NEG_OK=" + negResult.ok);
console.log("NEG_MSG_HAS_REVERTED=" + negResult.message.includes("reverted"));
console.log("NEG_FILE_UNCHANGED=" + (negAfter === badContent));
EOF
out4b="$(node "$tmpdir/revert-test.mjs" 2>&1)"
echo "$out4b" | grep -q 'POS_OK=true'              && r=yes || r=no; assert "4b: positive control upsert ok" yes "$r"
echo "$out4b" | grep -q 'POS_CHANGED=true'          && r=yes || r=no; assert "4b: positive control changed=true" yes "$r"
echo "$out4b" | grep -q 'POS_HAS_NEW=true'          && r=yes || r=no; assert "4b: positive control new repo in file after valid-YAML write" yes "$r"
echo "$out4b" | grep -q 'NEG_OK=false'              && r=yes || r=no; assert "4b: malformed frontmatter returns ok:false" yes "$r"
echo "$out4b" | grep -q 'NEG_MSG_HAS_REVERTED=true' && r=yes || r=no; assert "4b: revert message contains 'reverted'" yes "$r"
echo "$out4b" | grep -q 'NEG_FILE_UNCHANGED=true'   && r=yes || r=no; assert "4b: file byte-identical after revert" yes "$r"

# -- Test 5: path-safety — reject componentsDir escaping the vault --------
echo "Test 5: path-safety invariant"
cat >"$tmpdir/escape-test.mjs" <<EOF
import { upsertComponentNote } from "$script_url";
const rec = { name: "x", type: "skill", description: "", path: "skills/x/SKILL.md",
  repo: "a/b", key: "skill:x", trust_tier: "", safety_flag: "" };
try {
  await upsertComponentNote(rec, { vault: "$vault", componentsDir: "../../etc", dryRun: false });
  console.log("ESCAPE=allowed");
} catch (e) { console.log("ESCAPE=blocked:" + e.message.slice(0,20)); }
EOF
out="$(node "$tmpdir/escape-test.mjs" 2>&1)"
echo "$out" | grep -q 'ESCAPE=blocked' && r=yes || r=no; assert "5: componentsDir traversal blocked" yes "$r"

# -- Test 5b: --dry-run never touches disk --------------------------------
# Uses os.tmpdir() for the vault (native path) — bash mktemp yields POSIX
# /c/... paths on Windows that the test's own resolve() cannot rebuild.
echo "Test 5b: dry-run no-write"
cat >"$tmpdir/dryrun-test.mjs" <<EOF
import { upsertComponentNote } from "$script_url";
import { readFileSync, existsSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import os from "node:os";
const vault = join(os.tmpdir(), "cvault5b-" + process.pid);
mkdirSync(vault, { recursive: true });
const dryOpts = { vault, componentsDir: "30-Resources/Components", dryRun: true };
const rec = { name: "Dry Tool", type: "tool", description: "no write.", path: "tools/dry.mjs",
  repo: "alice/repo", key: "tool:dry-tool", trust_tier: "known-author", safety_flag: "" };
// Dry-run against a NON-existent target: changed=true but no file on disk.
// Tools key by repo-relative path (LUNA-61): tools/dry.mjs -> tools-dry-mjs.md
const target = resolve(vault, "30-Resources/Components/tool/tools-dry-mjs.md");
const r1 = await upsertComponentNote(rec, dryOpts);
console.log("DRY_CREATE_CHANGED=" + r1.changed);
console.log("DRY_CREATE_NOFILE=" + (!existsSync(target)));
// Now create it for real, snapshot bytes, then dry-run an escalating upsert.
// recEsc keeps rec's path so it merges (same tool path, different repo).
const realOpts = { vault, componentsDir: "30-Resources/Components", dryRun: false };
await upsertComponentNote(rec, realOpts);
const before = readFileSync(target, "utf-8");
const recEsc = { ...rec, repo: "bob/other",
  trust_tier: "community-thin", safety_flag: "red-team" };
const r2 = await upsertComponentNote(recEsc, dryOpts);
const after = readFileSync(target, "utf-8");
console.log("DRY_UPDATE_CHANGED=" + r2.changed);
console.log("DRY_UPDATE_BYTES_SAME=" + (after === before));
EOF
out5b="$(node "$tmpdir/dryrun-test.mjs" 2>&1)"
echo "$out5b" | grep -q 'DRY_CREATE_CHANGED=true'    && r=yes || r=no; assert "5b: dry-run create reports changed" yes "$r"
echo "$out5b" | grep -q 'DRY_CREATE_NOFILE=true'     && r=yes || r=no; assert "5b: dry-run create writes no file" yes "$r"
echo "$out5b" | grep -q 'DRY_UPDATE_CHANGED=true'    && r=yes || r=no; assert "5b: dry-run escalating update reports changed" yes "$r"
echo "$out5b" | grep -q 'DRY_UPDATE_BYTES_SAME=true' && r=yes || r=no; assert "5b: dry-run update leaves on-disk bytes unchanged" yes "$r"

# -- Test 5c: CR-1 YAML-escape on create (backslashes) --------------------
# js-yaml resolves relative to the tools/ dir, so import it by absolute URL.
echo "Test 5c: YAML-escape on create"
yaml_url="$(node -e 'console.log(require("url").pathToFileURL(require.resolve("js-yaml")).href)' 2>/dev/null || (cd "$TOOLS_DIR" && node -e 'console.log(require("url").pathToFileURL(require.resolve("js-yaml")).href)'))"
cat >"$tmpdir/yamlesc-test.mjs" <<EOF
import { upsertComponentNote } from "$script_url";
import { readFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import os from "node:os";
import yaml from "$yaml_url";
const vault = join(os.tmpdir(), "cvault5c-" + process.pid);
mkdirSync(vault, { recursive: true });
const opts = { vault, componentsDir: "30-Resources/Components", dryRun: false };
// Build the backslash via char-code to keep literal backslashes out of the
// heredoc (bash + JS double-escaping is a footgun). desc = regex \d+ path C:\x
const BS = String.fromCharCode(92);
const desc = "regex " + BS + "d+ path C:" + BS + "x";
const rec = { name: "Back Slash", type: "tool", description: desc, path: "tools/bs.mjs",
  repo: "alice/repo", key: "tool:back-slash", trust_tier: "known-author", safety_flag: "" };
const r = await upsertComponentNote(rec, opts);
console.log("CR1_OK=" + r.ok);
const target = resolve(vault, "30-Resources/Components/tool/tools-bs-mjs.md");
const text = readFileSync(target, "utf-8");
const fm = text.slice(4, text.indexOf(String.fromCharCode(10) + "---", 4));
let parsed = null, err = "";
try { parsed = yaml.load(fm); } catch (e) { err = e.message; }
console.log("CR1_YAML_VALID=" + (parsed !== null));
console.log("CR1_DESC_ROUNDTRIP=" + (parsed && parsed.description === desc));
console.log("CR1_ERR=" + err);
EOF
out5c="$(node "$tmpdir/yamlesc-test.mjs" 2>&1)"
echo "$out5c" | grep -q 'CR1_OK=true'             && r=yes || r=no; assert "5c: create with backslash desc returns ok" yes "$r"
echo "$out5c" | grep -q 'CR1_YAML_VALID=true'     && r=yes || r=no; assert "5c: created note frontmatter parses as valid YAML" yes "$r"
echo "$out5c" | grep -q 'CR1_DESC_ROUNDTRIP=true' && r=yes || r=no; assert "5c: backslash description round-trips through YAML" yes "$r"

# -- Test 6: SKILL.md documents --deep + Phase 3.5 + Components dest -------
echo "Test 6: SKILL --deep wiring"
SKILL_MD="$PLUGIN_DIR/skills/luna-ingest/SKILL.md"
grep -q -- '--deep' "$SKILL_MD"                          && r=yes || r=no; assert "6: SKILL documents --deep flag" yes "$r"
grep -q '## Phase 3.5' "$SKILL_MD"                       && r=yes || r=no; assert "6: SKILL has Phase 3.5" yes "$r"
grep -q '## Reusable components' "$SKILL_MD"             && r=yes || r=no; assert "6: SKILL specs Reusable components section" yes "$r"
grep -q '30-Resources/Components' "$SKILL_MD"            && r=yes || r=no; assert "6: SKILL lists Components dest" yes "$r"
grep -q 'component-scan.mjs' "$SKILL_MD"                 && r=yes || r=no; assert "6: SKILL references the tool" yes "$r"
grep -q 'integrate.*take-parts\|take-parts.*integrate' "$SKILL_MD" && r=yes || r=no; assert "6: SKILL states ref-scan verdict gate" yes "$r"

# -- Test 7: LUNA-61/62/63 disambiguation + polish ------------------------
echo "Test 7a: key disambiguation, frozen types, desc bound (lib units)"
cat >"$tmpdir/luna6163-test.mjs" <<EOF
import { componentKey, componentSlug, COMPONENT_TYPES, extractComponent, normalizeComponentPath } from "$lib_url";

// LUNA-61: two tools sharing a basename in different dirs of ONE repo must not
// collide (distinct keys); the same tool path stays stable under ./ spelling.
const kA = componentKey({ type: "tool", name: "x.mjs", path: "tools/a/x.mjs" });
const kB = componentKey({ type: "tool", name: "x.mjs", path: "tools/b/x.mjs" });
console.log("TOOL_KEYS_DISTINCT=" + (kA !== kB));
console.log("TOOL_KEY_STABLE=" + (kA === componentKey({ type: "tool", name: "x.mjs", path: "./tools/a/x.mjs" })));

// LUNA-61: skills still dedup by declared name regardless of path.
const sA = componentKey({ type: "skill", name: "Foo", path: "skills/foo/SKILL.md" });
const sB = componentKey({ type: "skill", name: "Foo", path: "plugins/p/skills/foo/SKILL.md" });
console.log("SKILL_KEYS_MERGE=" + (sA === sB));

// LUNA-61: truncation collision — distinct long names sharing a 60-char prefix
// must yield distinct, <=60-char, stable slugs.
const long1 = "a".repeat(70) + "-one";
const long2 = "a".repeat(70) + "-two";
const t1 = componentSlug(long1), t2 = componentSlug(long2);
console.log("TRUNC_DISTINCT=" + (t1 !== t2));
console.log("TRUNC_BOUNDED=" + (t1.length <= 60 && t2.length <= 60));
console.log("TRUNC_STABLE=" + (t1 === componentSlug(long1)));

// LUNA-62: COMPONENT_TYPES frozen + complete; unknown type throws.
console.log("TYPES_FROZEN=" + Object.isFrozen(COMPONENT_TYPES));
console.log("TYPES_SET=" + COMPONENT_TYPES.join(","));
let threw = false;
try { extractComponent({ path: "x", type: "bogus", content: "" }); } catch { threw = true; }
console.log("UNKNOWN_TYPE_THROWS=" + threw);

// LUNA-63: description bounded to 500 chars.
const huge = extractComponent({ path: "tools/big.mjs", type: "tool",
  content: "#!/usr/bin/env node\n// " + "z".repeat(2000) + "\n" });
console.log("DESC_BOUNDED=" + (huge.description.length <= 500));

// LUNA-63: normalizeComponentPath strips ./, backslashes, double-slashes.
const BS = String.fromCharCode(92);
console.log("NORM=" + normalizeComponentPath("." + "/tools" + BS + "a//x.mjs"));
EOF
out7="$(node "$tmpdir/luna6163-test.mjs" 2>&1)"
echo "$out7" | grep -q 'TOOL_KEYS_DISTINCT=true'  && r=yes || r=no; assert "7a: LUNA-61 sibling-dir tools get distinct keys" yes "$r"
echo "$out7" | grep -q 'TOOL_KEY_STABLE=true'     && r=yes || r=no; assert "7a: LUNA-61 tool key stable under ./ spelling" yes "$r"
echo "$out7" | grep -q 'SKILL_KEYS_MERGE=true'    && r=yes || r=no; assert "7a: LUNA-61 skills still dedup by name across paths" yes "$r"
echo "$out7" | grep -q 'TRUNC_DISTINCT=true'      && r=yes || r=no; assert "7a: LUNA-61 long-name truncation collision avoided" yes "$r"
echo "$out7" | grep -q 'TRUNC_BOUNDED=true'       && r=yes || r=no; assert "7a: LUNA-61 truncated slug <= 60 chars" yes "$r"
echo "$out7" | grep -q 'TRUNC_STABLE=true'        && r=yes || r=no; assert "7a: LUNA-61 truncated slug stable (dedup)" yes "$r"
echo "$out7" | grep -q 'TYPES_FROZEN=true'        && r=yes || r=no; assert "7a: LUNA-62 COMPONENT_TYPES is frozen" yes "$r"
echo "$out7" | grep -q 'TYPES_SET=skill,command,agent,plugin-manifest,tool' && r=yes || r=no; assert "7a: LUNA-62 COMPONENT_TYPES complete" yes "$r"
echo "$out7" | grep -q 'UNKNOWN_TYPE_THROWS=true' && r=yes || r=no; assert "7a: LUNA-62 extractComponent throws on unknown type" yes "$r"
echo "$out7" | grep -q 'DESC_BOUNDED=true'        && r=yes || r=no; assert "7a: LUNA-63 description bounded to 500 chars" yes "$r"
echo "$out7" | grep -q 'NORM=tools/a/x.mjs'       && r=yes || r=no; assert "7a: LUNA-63 normalizeComponentPath canonicalises" yes "$r"

echo "Test 7b: seen_in path normalize + trust_tier parse-back (upsert)"
cat >"$tmpdir/luna63-upsert-test.mjs" <<EOF
import { upsertComponentNote } from "$script_url";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import os from "node:os";
const vault = join(os.tmpdir(), "cvault7b-" + process.pid);
mkdirSync(vault, { recursive: true });
const opts = { vault, componentsDir: "30-Resources/Components", dryRun: false };

// seen_in normalize: a './'-prefixed path is recorded canonically.
const rec = { name: "Norm Tool", type: "tool", description: "n", path: "./tools/norm.mjs",
  repo: "alice/repo", key: "tool:norm", trust_tier: "known-author", safety_flag: "" };
await upsertComponentNote(rec, opts);
const target = resolve(vault, "30-Resources/Components/tool/tools-norm-mjs.md");
const text = readFileSync(target, "utf-8");
console.log("SEEN_NORMALISED=" + (text.includes("alice/repo#tools/norm.mjs") && !text.includes("#./tools")));
// LUNA-63: the CREATE path quotes trust_tier too (symmetry with the update
// path) — assert directly, before any update touches the note.
console.log("CREATE_TIER_QUOTED=" + /^trust_tier: "known-author"$/m.test(text));

// LUNA-61: two tools sharing a basename in different dirs must land in TWO
// distinct notes (the user-visible bug), not merge into one.
const sibA = { name: "x.mjs", type: "tool", description: "a", path: "tools/a/x.mjs",
  repo: "r/a", key: "tool:a", trust_tier: "", safety_flag: "" };
const sibB = { ...sibA, path: "tools/b/x.mjs", repo: "r/b" };
await upsertComponentNote(sibA, opts);
await upsertComponentNote(sibB, opts);
const fA = resolve(vault, "30-Resources/Components/tool/tools-a-x-mjs.md");
const fB = resolve(vault, "30-Resources/Components/tool/tools-b-x-mjs.md");
console.log("SIBLING_TWO_FILES=" + (readFileSync(fA, "utf-8").length > 0 && readFileSync(fB, "utf-8").length > 0 && fA !== fB));

// tier parse-back: corrupt the on-disk trust_tier to a non-canonical label;
// a new-repo upsert must normalise it to unknown-risk (quoted).
const corrupted = text.replace(/^trust_tier:.*$/m, "trust_tier: garbage-tier");
writeFileSync(target, corrupted, "utf-8");
const recB = { ...rec, repo: "bob/repo" };
const r = await upsertComponentNote(recB, opts);
const after = readFileSync(target, "utf-8");
console.log("PARSEBACK_CHANGED=" + r.changed);
console.log("PARSEBACK_NORMALISED=" + /^trust_tier: "unknown-risk"$/m.test(after));
EOF
out7b="$(node "$tmpdir/luna63-upsert-test.mjs" 2>&1)"
echo "$out7b" | grep -q 'SEEN_NORMALISED=true'     && r=yes || r=no; assert "7b: LUNA-63 seen_in path normalised (no ./ prefix)" yes "$r"
echo "$out7b" | grep -q 'CREATE_TIER_QUOTED=true'  && r=yes || r=no; assert "7b: LUNA-63 create path quotes trust_tier (symmetry)" yes "$r"
echo "$out7b" | grep -q 'SIBLING_TWO_FILES=true'   && r=yes || r=no; assert "7b: LUNA-61 sibling-dir tools land in two distinct notes" yes "$r"
echo "$out7b" | grep -q 'PARSEBACK_CHANGED=true'   && r=yes || r=no; assert "7b: LUNA-63 non-canonical on-disk tier triggers rewrite" yes "$r"
echo "$out7b" | grep -q 'PARSEBACK_NORMALISED=true' && r=yes || r=no; assert "7b: LUNA-63 parsed-back garbage tier normalised to unknown-risk" yes "$r"

# -- Results summary -------------------------------------------------------
total=$((pass + fail))
echo ""
echo "Results: $pass / $total passed, $fail failed."
[ "$fail" -eq 0 ]
