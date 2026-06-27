#!/usr/bin/env bash
# Tests for LUNA-58 telegram-clip.mjs + lib/telegram-clip.mjs.
#
# Scope (no live telegram — end-to-end is LUNA calibration):
#   1. scripts parse (node --check)
#   2. usage / arg-error exit codes (msg-id, text, sender, -h)
#   3. pure lib: classifyMessage / firstUrl / slugify / clipFilename / deriveTitle
#   4. buildClip frontmatter shape (type, provenance, no harvested_at, source)
#   5. CLI write: dry-run no-write, real write, idempotent re-run skip
#   6. vault validation: missing .obsidian → rc2; missing sender → rc2
#
# Cross-platform: bash on Linux/macOS/Git-Bash. Uses node (not bun) for CI.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
SCRIPT="$TOOLS_DIR/telegram-clip.mjs"
LIB="$TOOLS_DIR/lib/telegram-clip.mjs"

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

# Call a pure-lib function via a node ESM driver. Args via env to avoid quoting
# hell + Windows path issues (import by file URL). Usage: libcall <expr-using-`lib`>
libcall() {
    LIB="$LIB" node --input-type=module -e "
import {pathToFileURL} from 'node:url';
const lib = await import(pathToFileURL(process.env.LIB).href);
$1
" 2>&1
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
echo "Test 2: usage / arg errors"
node "$SCRIPT" -h >/dev/null 2>&1; assert "-h exits 0" 0 "$?"
node "$SCRIPT" --sender u --text hi >/dev/null 2>&1; assert "missing --msg-id exits 1" 1 "$?"
node "$SCRIPT" --sender u --msg-id 5 >/dev/null 2>&1; assert "missing --text exits 1" 1 "$?"
node "$SCRIPT" --msg-id 5 --text hi >/dev/null 2>&1; assert "missing --sender exits 2" 2 "$?"
node "$SCRIPT" --weird >/dev/null 2>&1; assert "unknown arg exits 1" 1 "$?"

# -- Test 3: classifyMessage --------------------------------------------
echo "Test 3: classifyMessage"
assert "github → research"  research "$(T='see https://github.com/a/b' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "x.com → tweet"      tweet    "$(T='https://x.com/u/status/1' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "twitter → tweet"    tweet    "$(T='https://twitter.com/u/status/1' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "youtube → youtube"  youtube  "$(T='https://www.youtube.com/watch?v=x' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "youtu.be → youtube" youtube  "$(T='https://youtu.be/x' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "reddit → reddit"    reddit   "$(T='https://www.reddit.com/r/x/comments/1' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "other url → article" article "$(T='https://example.com/post' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "no url → note"      note     "$(T='just a thought' libcall "console.log(lib.classifyMessage({text:process.env.T}).type)")"
assert "no-url source null" null     "$(T='just a thought' libcall "console.log(JSON.stringify(lib.classifyMessage({text:process.env.T}).source))")"

# -- Test 3b: firstUrl / slugify / clipFilename / deriveTitle -----------
echo "Test 3b: helpers"
assert "firstUrl strips trailing punct" "https://x.com/a" "$(T='look at https://x.com/a, nice' libcall "console.log(lib.firstUrl(process.env.T))")"
assert "firstUrl none → null" null "$(T='no link here' libcall "console.log(JSON.stringify(lib.firstUrl(process.env.T)))")"
# LUNA-65: balanced parens inside a URL survive; only an unbalanced trailing ) is stripped
assert "firstUrl keeps balanced wiki paren" "https://en.wikipedia.org/wiki/Foo_(bar)" "$(T='see https://en.wikipedia.org/wiki/Foo_(bar) ok' libcall "console.log(lib.firstUrl(process.env.T))")"
assert "firstUrl strips unbalanced wrapping paren" "https://x.com/a" "$(T='(https://x.com/a)' libcall "console.log(lib.firstUrl(process.env.T))")"
assert "firstUrl strips paren + trailing dot, keeps inner paren" "https://en.wikipedia.org/wiki/Foo_(bar)" "$(T='(https://en.wikipedia.org/wiki/Foo_(bar)).' libcall "console.log(lib.firstUrl(process.env.T))")"
assert "slugify kebab" "hello-world" "$(libcall "console.log(lib.slugify('Hello, World!'))")"
assert "slugify empty → untitled" "untitled" "$(libcall "console.log(lib.slugify('!!!'))")"
assert "clipFilename shape" "telegram-42-my-note.md" "$(libcall "console.log(lib.clipFilename({msgId:'42',title:'My Note'}))")"
assert "clipFilename sanitizes id" "telegram-ab12-x.md" "$(libcall "console.log(lib.clipFilename({msgId:'a/b\\\\1 2',title:'x'}))")"
assert "deriveTitle uses first line" "My idea here" "$(T=$'My idea here\nmore' libcall "console.log(lib.deriveTitle({text:process.env.T,type:'note',source:null}))")"
assert "deriveTitle url-only → host+path" "tweet from x.com/u/status/1" "$(libcall "console.log(lib.deriveTitle({text:'https://x.com/u/status/1',type:'tweet',source:'https://x.com/u/status/1'}))")"

# -- Test 3c: tweetStatusId (dedup-at-ingest match key) ------------------
echo "Test 3c: tweetStatusId"
# i/status (telegram forward) and user/status (browser clip) of the SAME tweet → same id
assert "tweetStatusId i/status form"    "123" "$(libcall "console.log(lib.tweetStatusId('https://x.com/i/status/123'))")"
assert "tweetStatusId user/status form" "123" "$(libcall "console.log(lib.tweetStatusId('https://x.com/someuser/status/123'))")"
assert "tweetStatusId twitter.com host" "456" "$(libcall "console.log(lib.tweetStatusId('https://twitter.com/u/status/456'))")"
assert "tweetStatusId www. prefix"      "789" "$(libcall "console.log(lib.tweetStatusId('https://www.x.com/u/status/789'))")"
assert "tweetStatusId mobile. prefix"   "789" "$(libcall "console.log(lib.tweetStatusId('https://mobile.twitter.com/u/status/789'))")"
assert "tweetStatusId trailing query"   "321" "$(libcall "console.log(lib.tweetStatusId('https://x.com/u/status/321?s=20'))")"
assert "tweetStatusId non-X → null"     "null" "$(libcall "console.log(JSON.stringify(lib.tweetStatusId('https://example.com/status/123')))")"
assert "tweetStatusId X non-status → null" "null" "$(libcall "console.log(JSON.stringify(lib.tweetStatusId('https://x.com/someuser')))")"
assert "tweetStatusId unparseable → null" "null" "$(libcall "console.log(JSON.stringify(lib.tweetStatusId('not a url')))")"

# -- Test 4: buildClip frontmatter shape --------------------------------
echo "Test 4: buildClip"
CLIP="$(T='check https://example.com/p — cool' libcall "
const {type,source}=lib.classifyMessage({text:process.env.T});
process.stdout.write(lib.buildClip({sender:'alice',ts:'2026-05-29T10:00:00Z',msgId:'77',text:process.env.T,type,source,today:'2026-05-29'}));
")"
echo "$CLIP" | grep -q '^type: article$'              && a=ok || a=no; assert "buildClip type line" ok "$a"
echo "$CLIP" | grep -q '^telegram_msg_id: "77"$'      && a=ok || a=no; assert "buildClip msg-id provenance" ok "$a"
echo "$CLIP" | grep -q '^telegram_sender: "alice"$'   && a=ok || a=no; assert "buildClip sender provenance" ok "$a"
echo "$CLIP" | grep -q '^clipped_via: telegram$'      && a=ok || a=no; assert "buildClip clipped_via" ok "$a"
echo "$CLIP" | grep -q '^source: https://example.com/p$' && a=ok || a=no; assert "buildClip source line" ok "$a"
echo "$CLIP" | grep -q '^## Source$'                  && a=ok || a=no; assert "buildClip Source section" ok "$a"
if echo "$CLIP" | grep -q '^harvested_at:'; then a=present; else a=absent; fi
assert "buildClip has NO harvested_at (unharvested)" absent "$a"
# note (no url) → no source line
NOTECLIP="$(libcall "process.stdout.write(lib.buildClip({sender:'a',ts:'',msgId:'9',text:'plain note',type:'note',source:null,today:'2026-05-29'}))")"
if echo "$NOTECLIP" | grep -q '^source:'; then a=present; else a=absent; fi
assert "note clip omits source line" absent "$a"
# unknown type throws
libcall "try{lib.buildClip({sender:'a',ts:'',msgId:'1',text:'x',type:'bogus',source:null,today:'2026-05-29'});console.log('nothrow')}catch(e){console.log('threw')}" >"$tmpdir/_tc_throw" 2>&1
assert "buildClip unknown type throws" threw "$(cat "$tmpdir/_tc_throw")"

# -- Test 5/6: CLI write, dry-run, idempotency, vault validation --------
echo "Test 5/6: CLI write + idempotency + vault validation"
VAULT="$tmpdir/vault"
mkdir -p "$VAULT/.obsidian" "$VAULT/Clippings"

# missing .obsidian → rc2
NOVAULT="$tmpdir/novault"; mkdir -p "$NOVAULT"
node "$SCRIPT" --vault "$NOVAULT" --sender a --msg-id 1 --text hi >/dev/null 2>&1
assert "vault without .obsidian exits 2" 2 "$?"

# dry-run: prints, writes nothing
out="$(node "$SCRIPT" --vault "$VAULT" --sender alice --msg-id 100 --ts 2026-05-29T10:00:00Z --text 'dry note' --dry-run 2>&1)"; rc=$?
assert "dry-run exits 0" 0 "$rc"
echo "$out" | grep -q 'dry-run' && a=ok || a=no; assert "dry-run announces" ok "$a"
n=$(find "$VAULT/Clippings" -name '*.md' | wc -l | tr -d ' ')
assert "dry-run wrote no file" 0 "$n"

# real write
out="$(node "$SCRIPT" --vault "$VAULT" --sender alice --msg-id 100 --ts 2026-05-29T10:00:00Z --text 'check https://github.com/o/r' 2>&1)"; rc=$?
assert "write exits 0" 0 "$rc"
n=$(find "$VAULT/Clippings" -name 'telegram-100-*.md' | wc -l | tr -d ' ')
assert "write created telegram-100 clip" 1 "$n"
clipfile="$(find "$VAULT/Clippings" -name 'telegram-100-*.md')"
grep -q '^type: research$' "$clipfile" && a=ok || a=no; assert "github clip type=research" ok "$a"

# idempotent re-run (same msg-id, different text/slug) → skip, no new file
out="$(node "$SCRIPT" --vault "$VAULT" --sender alice --msg-id 100 --ts 2026-05-29T11:00:00Z --text 'edited text https://github.com/o/r' 2>&1)"; rc=$?
assert "re-run exits 0" 0 "$rc"
echo "$out" | grep -q 'already-filed' && a=ok || a=no; assert "re-run reports already-filed" ok "$a"
n=$(find "$VAULT/Clippings" -name 'telegram-100-*.md' | wc -l | tr -d ' ')
assert "re-run added no duplicate" 1 "$n"

# clip frontmatter is valid YAML (js-yaml resolves from tools/node_modules —
# run from TOOLS_DIR so the bare 'js-yaml' import finds the vendored package).
(cd "$TOOLS_DIR" && CLIPF="$clipfile" node --input-type=module -e "
import {readFileSync} from 'node:fs';
const _y = await import('js-yaml'); const yaml = _y.default ?? _y;
const t = readFileSync(process.env.CLIPF,'utf8').replace(/\r\n/g,'\n');
const fm = t.slice(4, t.indexOf('\n---', 4));
yaml.load(fm);
console.log('valid');
") >"$tmpdir/_tc_yaml" 2>&1
assert "written clip frontmatter is valid YAML" valid "$(cat "$tmpdir/_tc_yaml")"

# -- Test 7: --text-file path (the channel-session forwarding shape) -----
echo "Test 7: --text-file"
node "$SCRIPT" --vault "$VAULT" --sender a --msg-id 700 --text-file "$tmpdir/nope.txt" >/dev/null 2>&1
assert "--text-file missing exits 1" 1 "$?"
# Distinct repo from Test 5/6's github.com/o/r — else the new url-dedup skips it.
printf 'multi line\nsecond line\n\nhttps://github.com/o/r-textfile' > "$tmpdir/msg.txt"
out="$(node "$SCRIPT" --vault "$VAULT" --sender a --msg-id 701 --text-file "$tmpdir/msg.txt" 2>&1)"
assert "--text-file write exits 0" 0 "$?"
tf701="$(find "$VAULT/Clippings" -name 'telegram-701-*.md')"
grep -q '^type: research$' "$tf701" && a=ok || a=no; assert "--text-file body fed classifier (github→research)" ok "$a"
grep -qx 'second line' "$tf701" && a=ok || a=no; assert "--text-file multi-line body preserved verbatim" ok "$a"
grep -qx '# multi line' "$tf701" && a=ok || a=no; assert "--text-file title = first line" ok "$a"

# -- Test 8: dedup across a Clippings/ subdir ----------------------------
echo "Test 8: dedup in subdir"
mkdir -p "$VAULT/Clippings/sub"
node "$SCRIPT" --vault "$VAULT" --sender a --msg-id 800 --text 'note in sub' >/dev/null 2>&1
# move the just-written clip into a subdir (simulates /triage-clips promotion)
mv "$(find "$VAULT/Clippings" -maxdepth 1 -name 'telegram-800-*.md')" "$VAULT/Clippings/sub/"
out="$(node "$SCRIPT" --vault "$VAULT" --sender a --msg-id 800 --text 'note in sub edited' 2>&1)"
echo "$out" | grep -q 'already-filed' && a=ok || a=no; assert "dedup finds clip in Clippings/ subdir" ok "$a"
# id present only in BODY must NOT false-positive (frontmatter-scoped match)
printf -- '---\ntype: note\n---\n# x\ntelegram_msg_id: "900"\n' > "$VAULT/Clippings/decoy.md"
out="$(node "$SCRIPT" --vault "$VAULT" --sender a --msg-id 900 --text 'real 900' 2>&1)"
echo "$out" | grep -q '✓' && a=ok || a=no; assert "msg-id in body does NOT false-positive dedup" ok "$a"

# -- Test 9: adversarial msg-id stays contained --------------------------
echo "Test 9: path-safety + provenance escaping"
out="$(node "$SCRIPT" --vault "$VAULT" --sender a --msg-id '../../evil' --text 'x' 2>&1)"; rc=$?
assert "adversarial msg-id exits 0 (sanitized)" 0 "$rc"
esc="$(find "$VAULT" -name '*evil*' -not -path "*/Clippings/*" | wc -l | tr -d ' ')"
assert "adversarial msg-id wrote nothing outside Clippings/" 0 "$esc"

# adversarial sender (quotes/backslash) → still valid YAML
node "$SCRIPT" --vault "$VAULT" --sender 'a"b\c' --msg-id 950 --text 'quote test' >/dev/null 2>&1
qf="$(find "$VAULT/Clippings" -name 'telegram-950-*.md')"
(cd "$TOOLS_DIR" && CLIPF="$qf" node --input-type=module -e "
import {readFileSync} from 'node:fs';
const _y = await import('js-yaml'); const yaml = _y.default ?? _y;
const t = readFileSync(process.env.CLIPF,'utf8').replace(/\r\n/g,'\n');
const fm = yaml.load(t.slice(4, t.indexOf('\n---', 4)));
console.log(fm.telegram_sender === 'a\"b\\\\c' ? 'match' : 'MISMATCH:'+fm.telegram_sender);
") >"$tmpdir/_tc_sender" 2>&1
assert "adversarial sender round-trips through YAML" match "$(cat "$tmpdir/_tc_sender")"

# -- Test 10: OBSIDIAN_VAULT_PATH env resolution -------------------------
echo "Test 10: OBSIDIAN_VAULT_PATH"
out="$(OBSIDIAN_VAULT_PATH="$VAULT" node "$SCRIPT" --sender a --msg-id 1000 --text 'env vault' 2>&1)"; rc=$?
assert "OBSIDIAN_VAULT_PATH write exits 0" 0 "$rc"
n=$(find "$VAULT/Clippings" -name 'telegram-1000-*.md' | wc -l | tr -d ' ')
assert "OBSIDIAN_VAULT_PATH resolved" 1 "$n"

# -- Summary --------------------------------------------------------------
echo ""
echo "telegram-clip tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
