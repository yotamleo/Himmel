#!/usr/bin/env bash
# Tests for LUNA-59 roadmap-aggregate.mjs + lib/roadmap-aggregate.mjs.
#
# Scope (no live vault — uses a synthetic fixture vault):
#   1. scripts parse (node --check)
#   2. usage / arg-error exit codes
#   3. pure lib: per-source parsers (daily / deferred / synthesis / promotion / component)
#   4. CLI: JSON shape, counts, empty-source graceful, --emit none
#   5. vault validation: missing .obsidian → rc2
#
# Cross-platform: bash on Linux/macOS/Git-Bash. Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/roadmap-aggregate.mjs"
LIB="$TOOLS_DIR/lib/roadmap-aggregate.mjs"

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

# Pure-lib call via a node ESM driver (file URL import — Windows-safe).
libcall() {
    LIB="$LIB" node --input-type=module -e "
import {pathToFileURL} from 'node:url';
const lib = await import(pathToFileURL(process.env.LIB).href);
$1
" 2>&1
}

# -- Test 1: scripts parse -----------------------------------------------
echo "Test 1: scripts parse"
for f in "$SCRIPT" "$LIB"; do
  if node --check "$f" 2>/dev/null; then s=ok; else s=fail; fi
  assert "$(basename "$f") parses" ok "$s"
done

# -- Test 2: usage / arg errors ------------------------------------------
echo "Test 2: usage / arg errors"
node "$SCRIPT" -h >/dev/null 2>&1; assert "-h exits 0" 0 "$?"
node "$SCRIPT" --bogus >/dev/null 2>&1; assert "unknown arg exits 1" 1 "$?"
node "$SCRIPT" --emit yaml >/dev/null 2>&1; assert "bad --emit exits 1" 1 "$?"
# LUNA-66: a value-taking flag with no following value (or a flag as its value) is rejected
node "$SCRIPT" --vault >/dev/null 2>&1; assert "--vault with no value exits 1" 1 "$?"
node "$SCRIPT" --emit >/dev/null 2>&1; assert "--emit with no value exits 1" 1 "$?"
node "$SCRIPT" --vault --emit json >/dev/null 2>&1; assert "--vault swallowing a flag exits 1" 1 "$?"

# -- Test 3: pure-lib parsers --------------------------------------------
echo "Test 3: pure-lib parsers"
assert "daily action items count" 2 "$(C=$'- [ ] do thing\nnot a task\n- [ ] other (from [[Clippings/x]])' libcall "console.log(lib.parseDailyActionItems(process.env.C,'d.md').length)")"
assert "daily backref → category" "Clippings/x" "$(C='- [ ] other (from [[Clippings/x]])' libcall "console.log(lib.parseDailyActionItems(process.env.C,'d.md')[0].category)")"
assert "deferred section → category" "Fan-out" "$(C=$'## Fan-out\n- [ ] https://github.com/a/b' libcall "console.log(lib.parseDeferred(process.env.C,'_deferred.md')[0].category)")"
assert "deferred item count" 2 "$(C=$'## S1\n- [ ] a\n## S2\n- [ ] b' libcall "console.log(lib.parseDeferred(process.env.C,'x').length)")"
# LUNA-66: a deferred item that is exactly a wrapping markdown link → bare URL; other text untouched
assert "deferred unwraps wrapping md-link to url" "https://github.com/a/b" "$(C=$'## S\n- [ ] [repo a/b](https://github.com/a/b)' libcall "console.log(lib.parseDeferred(process.env.C,'x')[0].text)")"
assert "deferred leaves plain text untouched" "do the thing" "$(C=$'## S\n- [ ] do the thing' libcall "console.log(lib.parseDeferred(process.env.C,'x')[0].text)")"
assert "deferred leaves mid-sentence link untouched" "see [docs](https://x) for more" "$(C=$'## S\n- [ ] see [docs](https://x) for more' libcall "console.log(lib.parseDeferred(process.env.C,'x')[0].text)")"
assert "synthesis proposal extracted" "synthesis-proposal" "$(C=$'## Evidence\nstuff\n## Proposed vault change\nMake a new MOC for agents.\n## Why\nok' libcall "console.log(lib.parseSynthesisProposal(process.env.C,'s.md')[0].source_type)")"
assert "synthesis no-section → empty" 0 "$(C=$'## Evidence\nstuff' libcall "console.log(lib.parseSynthesisProposal(process.env.C,'s.md').length)")"
assert "promotion candidate emitted" 1 "$(C=$'---\ntitle: T\npromotion_candidate: yes promote to project\n---\nbody' libcall "console.log(lib.parsePromotionCandidate(process.env.C,'c.md').length)")"
assert "promotion false → empty" 0 "$(C=$'---\ntitle: T\npromotion_candidate: false\n---\nbody' libcall "console.log(lib.parsePromotionCandidate(process.env.C,'c.md').length)")"
assert "promotion absent → empty" 0 "$(C=$'---\ntitle: T\n---\nbody' libcall "console.log(lib.parsePromotionCandidate(process.env.C,'c.md').length)")"
assert "promotion quoted none → empty" 0 "$(C=$'---\ntitle: T\npromotion_candidate: \"none\"\n---' libcall "console.log(lib.parsePromotionCandidate(process.env.C,'c.md').length)")"
assert "promotion None caps → empty" 0 "$(C=$'---\ntitle: T\npromotion_candidate: None\n---' libcall "console.log(lib.parsePromotionCandidate(process.env.C,'c.md').length)")"
assert "promotion title fallback to origin" "c.md — go" "$(C=$'---\npromotion_candidate: go\n---' libcall "console.log(lib.parsePromotionCandidate(process.env.C,'c.md')[0].text)")"
# component_type: real LUNA-57 note shape is type:component + component_type:<kind>
assert "component prefers component_type" "Foo (skill)" "$(C=$'---\nname: Foo\ntype: component\ncomponent_type: skill\n---' libcall "console.log(lib.parseComponent(process.env.C,'k.md')[0].text)")"
assert "component falls back to type" "Bar (tool)" "$(C=$'---\nname: Bar\ntype: tool\n---' libcall "console.log(lib.parseComponent(process.env.C,'k.md')[0].text)")"
assert "deferred item before any section → null category" "null" "$(C=$'- [ ] orphan' libcall "console.log(JSON.stringify(lib.parseDeferred(process.env.C,'x')[0].category))")"
assert "CRLF synthesis proposal joins cleanly" "New MOC for agents." "$(C=$'## Proposed vault change\r\nNew MOC for agents.\r\n## Why\r\nok' libcall "console.log(lib.parseSynthesisProposal(process.env.C,'s.md')[0].text)")"
assert "countBySource tally" '{"a":2,"b":1}' "$(libcall "console.log(JSON.stringify(lib.countBySource([{source_type:'a'},{source_type:'a'},{source_type:'b'}])))")"

# -- Test 4: CLI against a synthetic fixture vault -----------------------
echo "Test 4: CLI on fixture vault"
V="$tmpdir/vault"
mkdir -p "$V/.obsidian" "$V/50-Journal/Daily" "$V/Clippings/_synthesis/_done" "$V/30-Resources/Components/skill"
printf -- '- [ ] daily task one\n- [ ] daily task two (from [[Clippings/z]])\n' > "$V/50-Journal/Daily/2026-05-29.md"
printf -- '---\ntype: pipeline-deferred\n---\n## Fan-out\n- [ ] https://github.com/a/b\n- [ ] https://github.com/c/d\n' > "$V/Clippings/_deferred.md"
printf -- '## Evidence\nx\n## Proposed vault change\nNew agents MOC.\n## Why\nok\n' > "$V/Clippings/_synthesis/2026-05-29-tag.md"
printf -- '## Proposed vault change\nSHOULD BE SKIPPED (in _done).\n' > "$V/Clippings/_synthesis/_done/old.md"
printf -- '---\ntitle: Cool clip\npromotion_candidate: promote to a project\n---\nbody\n' > "$V/Clippings/cool.md"
printf -- '---\nname: harvest-clips\ntype: component\ncomponent_type: command\n---\n' > "$V/30-Resources/Components/skill/harvest.md"

JSON="$(node "$SCRIPT" --vault "$V" 2>/dev/null)"
echo "$JSON" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);process.stdout.write(String(j.total))})" >"$tmpdir/_total"
assert "CLI total items (2 daily + 2 deferred + 1 synth + 1 promo + 1 comp)" 7 "$(cat "$tmpdir/_total")"
echo "$JSON" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);process.stdout.write(String(j.counts['synthesis-proposal']||0))})" >"$tmpdir/_synth"
assert "synthesis count excludes _done" 1 "$(cat "$tmpdir/_synth")"
echo "$JSON" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);process.stdout.write(String(j.counts['component']||0))})" >"$tmpdir/_comp"
assert "component scanned (nested subdir)" 1 "$(cat "$tmpdir/_comp")"
echo "$JSON" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);const c=j.items.find(i=>i.source_type==='component');process.stdout.write(c?c.text:'none')})" >"$tmpdir/_ctext"
assert "fixture component uses component_type" "harvest-clips (command)" "$(cat "$tmpdir/_ctext")"
echo "$JSON" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);console.log(j.items.every(i=>typeof i.text==='string'&&i.source_type)?'ok':'bad')})" >"$tmpdir/_shape"
assert "every item has text + source_type" ok "$(cat "$tmpdir/_shape")"
# scan-order contract: sources appended action-item → deferred → synthesis → promotion → component
echo "$JSON" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const j=JSON.parse(s);const seen=[...new Set(j.items.map(i=>i.source_type))];console.log(seen.join(','))})" >"$tmpdir/_order"
assert "source scan order stable" "action-item,deferred,synthesis-proposal,promotion,component" "$(cat "$tmpdir/_order")"

# JSON valid via js-yaml-free parse already done above; --emit none writes nothing
out="$(node "$SCRIPT" --vault "$V" --emit none 2>&1)"
assert "--emit none prints nothing" "" "$out"

# empty vault (only .obsidian) → total 0, exit 0
EV="$tmpdir/empty"; mkdir -p "$EV/.obsidian"
node "$SCRIPT" --vault "$EV" >/dev/null 2>&1; assert "empty vault exits 0" 0 "$?"
et="$(node "$SCRIPT" --vault "$EV" 2>/dev/null | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(String(JSON.parse(s).total)))")"
assert "empty vault total 0" 0 "$et"

# OBSIDIAN_VAULT_PATH fallback (no --vault) resolves the env vault
et2="$(OBSIDIAN_VAULT_PATH="$V" node "$SCRIPT" 2>/dev/null | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(String(JSON.parse(s).total)))")"
assert "OBSIDIAN_VAULT_PATH resolves (total 7)" 7 "$et2"

# -- Test 5: vault validation --------------------------------------------
echo "Test 5: vault validation"
NV="$tmpdir/novault"; mkdir -p "$NV"
node "$SCRIPT" --vault "$NV" >/dev/null 2>&1; assert "vault without .obsidian exits 2" 2 "$?"
node "$SCRIPT" --vault "$tmpdir/does-not-exist" >/dev/null 2>&1; assert "missing vault exits 2" 2 "$?"

# -- Summary --------------------------------------------------------------
echo ""
echo "roadmap-aggregate tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
