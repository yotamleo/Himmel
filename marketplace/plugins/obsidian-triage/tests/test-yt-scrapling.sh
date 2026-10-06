#!/usr/bin/env bash
# Tests for the cookieless YouTube path (HIMMEL-4677): tools/yt-scrapling-meta.py
# (metadata from a recorded watch page, transcript from a recorded yt-dlp json3)
# and its wiring into playwright-crawl-youtube.mjs as the PRIMARY path, the
# logged-in Playwright crawl the fallback only.
# Hermetic: NO network. The helper reads fixtures/yt-scrapling/; yt-dlp is a
# stub on a sealed PATH; the crawler runs from a tmp copy with a stub
# YT_SCRAPLING_PYTHON and a stub js-yaml, and HOME has no storage_state.
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "$SCRIPT_DIR/../tools" && pwd)"
HELPER="$TOOLS_DIR/yt-scrapling-meta.py"
FIX="$SCRIPT_DIR/fixtures/yt-scrapling"
VID=Xxuxg8PcBvc

pass=0; fail=0
assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo "  PASS  $desc"; pass=$((pass+1));
  else echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1)); fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/yt-scrapling.XXXXXX")" || exit 1; [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$tmp"' EXIT; echo "tmp=$tmp"
HOME="$tmp/home"; mkdir -p "$HOME"; export HOME USERPROFILE="$HOME"
unset YT_SCRAPLING_PYTHON HARVEST_SCRAPE_DENY

jq_py() { # $1 = json file, $2 = python expression over `d`
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}
helper() { python3 "$HELPER" --video-id "$VID" "$@"; }

# --- Test 1: metadata + transcript from the recorded page and json3 --------
echo "Test 1: extract metadata + transcript"
helper --from-html "$FIX/watch.html" --subs-file "$FIX/$VID.en.json3" >"$tmp/ok.json"
assert "ok exit 0" 0 "$?"
assert "status ok" ok "$(jq_py "$tmp/ok.json" 'd["status"]')"
assert "title from the player response, not the decoy" "Rethinking AI Agents: The Rise of Harness Engineering" "$(jq_py "$tmp/ok.json" 'd["title"]')"
assert "channel / duration / published" "PY 11:45 2026-04-14" \
  "$(jq_py "$tmp/ok.json" '" ".join([d["channel"], d["duration"], d["published"]])')"
assert "description carried" "True" "$(jq_py "$tmp/ok.json" 'd["description"].startswith("Same model. Same benchmark.")')"
assert "20 transcript lines, line breaks dropped" 20 "$(jq_py "$tmp/ok.json" 'len(d["transcript"])')"
assert "first line timestamped" "0:00 Same model." "$(jq_py "$tmp/ok.json" 'd["transcript"][0]["ts"]+" "+d["transcript"][0]["tx"]')"
assert "transcript source is yt-dlp" "yt-dlp None" "$(jq_py "$tmp/ok.json" 'd["transcript_source"]+" "+str(d["transcript_error"])')"

# --- Test 2: login wall, consent, removed, another video -------------------
echo "Test 2: page outcomes"
sed 's/"playabilityStatus": {"status": "OK"}/"playabilityStatus": {"status": "LOGIN_REQUIRED"}/' "$FIX/watch.html" >"$tmp/login.html"
helper --from-html "$tmp/login.html" >"$tmp/login.json"
assert "LOGIN_REQUIRED exit 4" 4 "$?"
assert "LOGIN_REQUIRED is a login wall" login_wall "$(jq_py "$tmp/login.json" 'd["status"]')"
helper --from-html "$FIX/watch.html" --final-url "https://consent.youtube.com/m?continue=x" >"$tmp/consent.json"
assert "consent redirect exit 4" 4 "$?"
sed 's/"playabilityStatus": {"status": "OK"}/"playabilityStatus": {"status": "ERROR"}/' "$FIX/watch.html" >"$tmp/gone.html"
helper --from-html "$tmp/gone.html" >"$tmp/gone.json"
assert "ERROR playability exit 5" 5 "$?"
assert "ERROR playability is removed" removed "$(jq_py "$tmp/gone.json" 'd["status"]')"
sed 's/"playabilityStatus": {"status": "OK"}/"playabilityStatus": {"status": "UNPLAYABLE"}/' "$FIX/watch.html" >"$tmp/unplayable.html"
helper --from-html "$tmp/unplayable.html" >"$tmp/unplayable.json"
assert "UNPLAYABLE (region/age/members) exit 6, retryable" 6 "$?"
assert "UNPLAYABLE is an error, never removed" error "$(jq_py "$tmp/unplayable.json" 'd["status"]')"
python3 "$HELPER" --video-id DECOYDECOY1 --from-html "$FIX/watch.html" >"$tmp/decoy.json"
assert "a decoy blob is not a player response -> exit 6" 6 "$?"
python3 "$HELPER" --video-id 'x;rm' --from-html "$FIX/watch.html" >/dev/null 2>&1
assert "malformed video id refused" 2 "$?"

# --- Test 3: routing -------------------------------------------------------
echo "Test 3: HIMMEL-4361 route"
mkdir -p "$tmp/v3"
HARVEST_SCRAPE_DENY=local-headless helper --vault "$tmp/v3" --from-html "$FIX/watch.html" >"$tmp/kill.json"
assert "kill switch -> skipped exit 7" 7 "$?"
echo "www.youtube.com skip=local-headless" >"$tmp/v3/.harvest-backends"
helper --vault "$tmp/v3" --from-html "$FIX/watch.html" >"$tmp/route.json"
assert ".harvest-backends skip -> exit 7" 7 "$?"
assert "route skip status" skipped "$(jq_py "$tmp/route.json" 'd["status"]')"

# --- Test 4: the transcript comes from yt-dlp, cookieless ------------------
echo "Test 4: yt-dlp transcript"
mkdir -p "$tmp/bin" "$tmp/sys"
for t in python3 bash env cat mkdir cp dirname; do ln -s "$(command -v "$t")" "$tmp/sys/$t"; done
cat > "$tmp/bin/yt-dlp" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$YTDLP_CALLS"
tmpl=""
while [ $# -gt 0 ]; do case "$1" in -o) shift; tmpl="$1" ;; esac; shift; done
cp "$YTDLP_SUBS" "$(dirname "$tmpl")/Xxuxg8PcBvc.en-orig.json3"
STUB
chmod +x "$tmp/bin/yt-dlp"
PATH="$tmp/bin:$tmp/sys" YTDLP_CALLS="$tmp/ytdlp.calls" YTDLP_SUBS="$FIX/$VID.en.json3" \
  helper --from-html "$FIX/watch.html" >"$tmp/ytdlp.json"
assert "yt-dlp run exit 0" 0 "$?"
assert "en-orig track parsed" 20 "$(jq_py "$tmp/ytdlp.json" 'len(d["transcript"])')"
calls="$(cat "$tmp/ytdlp.calls")"
case "$calls" in *--no-config*--skip-download*--sub-format\ json3*"-- https://www.youtube.com/watch?v=$VID"*) a=ok ;; *) a="$calls" ;; esac
assert "yt-dlp: no config, no download, json3, URL after --" ok "$a"
case "$calls" in *cookie*) a=cookie ;; *) a=none ;; esac
assert "yt-dlp gets no cookie" none "$a"
PATH="$tmp/sys" helper --from-html "$FIX/watch.html" >"$tmp/noytdlp.json"
assert "no yt-dlp: metadata still ok" ok "$(jq_py "$tmp/noytdlp.json" 'd["status"]')"
assert "no yt-dlp: transcript error named" yt_dlp_missing "$(jq_py "$tmp/noytdlp.json" 'd["transcript_error"]')"

# --- crawler under test: a tmp copy with a stub js-yaml ---------------------
mkdir -p "$tmp/tools/node_modules/js-yaml"
cp "$TOOLS_DIR/playwright-crawl-youtube.mjs" "$tmp/tools/"
echo '{"name":"js-yaml","version":"0.0.0","type":"module","main":"index.js"}' >"$tmp/tools/node_modules/js-yaml/package.json"
echo 'export function load(s) { return s; } export default { load };' >"$tmp/tools/node_modules/js-yaml/index.js"
CRAWL="$tmp/tools/playwright-crawl-youtube.mjs"
# Stub scrapling python: canned $STUB_JSON when set, else the REAL helper on the
# fixtures (the crawler passes --video-id and --vault).
cat > "$tmp/scrapling-python" <<STUB
#!/usr/bin/env bash
shift
if [ -n "\${STUB_JSON:-}" ]; then cat "\$STUB_JSON"; exit "\${STUB_RC:-0}"; fi
exec python3 "$HELPER" "\$@" --from-html "$FIX/watch.html" --subs-file "$FIX/$VID.en.json3"
STUB
chmod +x "$tmp/scrapling-python"
make_vault() { # $1 dir
  mkdir -p "$1/Clippings"
  cat > "$1/Clippings/clip.md" <<EOF
---
title: "yt clip"
source: "https://www.youtube.com/watch?v=$VID"
harvest_skill: clip-body
---
# yt clip

## Source
[link](https://www.youtube.com/watch?v=$VID)
EOF
}
crawl() { node "$CRAWL" --vault "$1"; }

# --- Test 5: Scrapling primary, no storage_state ---------------------------
echo "Test 5: crawler, scrapling primary"
export YT_SCRAPLING_PYTHON="$tmp/scrapling-python"
make_vault "$tmp/v5"
crawl "$tmp/v5" >"$tmp/v5.out" 2>"$tmp/v5.err"
assert "crawl exit 0" 0 "$?"
C="$tmp/v5/Clippings/clip.md"
grep -q '^crawl_skill: scrapling-youtube$' "$C" && a=ok || a=no; assert "crawl_skill scrapling-youtube" ok "$a"
grep -q '^crawl_status: ok$' "$C" && a=ok || a=no; assert "crawl_status ok" ok "$a"
grep -q 'via scrapling-youtube (metadata) + yt-dlp (transcript) -->' "$C" && a=ok || a=no; assert "provenance names both sources" ok "$a"
grep -qF '[0:00] Same model.' "$C" && a=ok || a=no; assert "transcript line written" ok "$a"
grep -q '^### Description$' "$C" && a=ok || a=no; assert "description section written" ok "$a"
grep -qF -- '- Duration: 11:45' "$C" && a=ok || a=no; assert "duration written" ok "$a"

# --- Test 6: login wall, no fallback -> retryable, clip untouched -----------
echo "Test 6: crawler, miss without a fallback"
echo '{"status": "login_wall", "detail": "LOGIN_REQUIRED"}' >"$tmp/wall.json"
make_vault "$tmp/v6"; before="$(cat "$tmp/v6/Clippings/clip.md")"
STUB_JSON="$tmp/wall.json" STUB_RC=4 crawl "$tmp/v6" >"$tmp/v6.out" 2>"$tmp/v6.err"
assert "crawl exit 0" 0 "$?"
assert "clip left byte-identical for a retry" "$before" "$(cat "$tmp/v6/Clippings/clip.md")"
grep -q 'retryable, not marked' "$tmp/v6.err" && a=ok || a=no; assert "failure says retryable" ok "$a"

# --- Test 7: removed video -> marked failed ---------------------------------
echo "Test 7: crawler, removed video"
echo '{"status": "removed", "detail": "ERROR"}' >"$tmp/gone.json"
make_vault "$tmp/v7"
STUB_JSON="$tmp/gone.json" STUB_RC=5 crawl "$tmp/v7" >"$tmp/v7.out" 2>"$tmp/v7.err"
grep -q '^crawl_status: failed$' "$tmp/v7/Clippings/clip.md" && a=ok || a=no; assert "removed marked failed" ok "$a"

# --- Test 8: metadata without a transcript -> partial -----------------------
echo "Test 8: crawler, transcript missing"
echo '{"status": "ok", "title": "T", "channel": "C", "duration": "1:00", "views": "", "published": "", "description": "", "transcript": [], "transcript_source": "yt-dlp", "transcript_error": "yt_dlp_missing"}' >"$tmp/notx.json"
make_vault "$tmp/v8"
STUB_JSON="$tmp/notx.json" crawl "$tmp/v8" >"$tmp/v8.out" 2>"$tmp/v8.err"
grep -q '^crawl_status: partial$' "$tmp/v8/Clippings/clip.md" && a=ok || a=no; assert "no transcript -> partial" ok "$a"
grep -q '^last_error: yt_dlp_missing$' "$tmp/v8/Clippings/clip.md" && a=ok || a=no; assert "transcript error recorded" ok "$a"

# --- Test 9: neither path available -> exit 2 naming both -------------------
echo "Test 9: preflight"
unset YT_SCRAPLING_PYTHON
make_vault "$tmp/v9"
crawl "$tmp/v9" >"$tmp/v9.out" 2>"$tmp/v9.err"
assert "no venv, no storage_state -> exit 2" 2 "$?"
grep -q 'scrapling-venv' "$tmp/v9.err" && a=ok || a=no; assert "message names the scrapling venv" ok "$a"

# --- fallback rung: a stub playwright module + a storage_state ---------------
# FAKE_PW_MODE=launch-throws: chromium.launch rejects (no browser binaries).
# FAKE_PW_MODE=goto-throws: the fallback runs but the page never loads.
# Every call is logged to $FAKE_PW_LOG so a test can prove the rung ran.
mkdir -p "$tmp/tools/node_modules/playwright" "$HOME/.luna/playwright-state"
echo '{}' >"$HOME/.luna/playwright-state/youtube.json"
echo '{"name":"playwright","version":"0.0.0","type":"module","main":"index.js"}' >"$tmp/tools/node_modules/playwright/package.json"
cat > "$tmp/tools/node_modules/playwright/index.js" <<'STUB'
import { appendFileSync } from "node:fs";
const log = (s) => appendFileSync(process.env.FAKE_PW_LOG, s + "\n");
const page = { goto: async () => { log("goto"); throw new Error("stub nav failure"); } };
export const chromium = {
  launch: async () => {
    log("launch");
    if (process.env.FAKE_PW_MODE === "launch-throws") throw new Error("Executable doesn't exist");
    return { newContext: async () => ({ newPage: async () => page }), close: async () => {} };
  },
};
STUB
export YT_SCRAPLING_PYTHON="$tmp/scrapling-python" FAKE_PW_LOG="$tmp/pw.log"

# --- Test 10: fallback launch fails -> the scrapling primary still runs ------
echo "Test 10: crawler, fallback browser cannot launch"
make_vault "$tmp/v10"; : >"$FAKE_PW_LOG"
FAKE_PW_MODE=launch-throws crawl "$tmp/v10" >"$tmp/v10.out" 2>"$tmp/v10.err"
assert "crawl exit 0" 0 "$?"
grep -q '^crawl_status: ok$' "$tmp/v10/Clippings/clip.md" && a=ok || a=no; assert "scrapling primary still crawled" ok "$a"
grep -q '^launch$' "$FAKE_PW_LOG" && a=ok || a=no; assert "the fallback launch was attempted" ok "$a"

# --- Test 11: metadata without a transcript -> the fallback is tried ---------
echo "Test 11: crawler, partial primary tries the fallback"
make_vault "$tmp/v11"; : >"$FAKE_PW_LOG"
STUB_JSON="$tmp/notx.json" FAKE_PW_MODE=goto-throws crawl "$tmp/v11" >"$tmp/v11.out" 2>"$tmp/v11.err"
assert "crawl exit 0" 0 "$?"
grep -q '^goto$' "$FAKE_PW_LOG" && a=ok || a=no; assert "fallback tried for the missing transcript" ok "$a"
grep -q '^crawl_status: partial$' "$tmp/v11/Clippings/clip.md" && a=ok || a=no; assert "failed fallback keeps the scrapling partial" ok "$a"
grep -q '^crawl_skill: scrapling-youtube$' "$tmp/v11/Clippings/clip.md" && a=ok || a=no; assert "partial still credited to scrapling" ok "$a"

echo ""
echo "yt-scrapling tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
