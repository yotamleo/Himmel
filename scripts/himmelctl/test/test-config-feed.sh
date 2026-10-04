#!/usr/bin/env bash
# test-config-feed.sh — HIMMEL-4254 P2: `himmelctl report --json`, the config
# UI's one data feed (scripts/himmelctl/lib/config-feed.js), plus redact.js and
# the flag-registry lint.
#
# Hermetic: a fake HOME + HIMMELCTL_CACHE_DIR + HIMMELCTL_REPO_ROOT fixture
# (the test-wizard-status-golden.sh shape). The doctor, the five cadence
# scripts and plugin-profile.sh are stubs reached through the test seams
# HIMMEL_REPORT_DOCTOR and HIMMEL_REPORT_CADENCE_ROOT, and a fake `crontab` is
# first on PATH so the operator's real crontab is never read (and the test
# proves the report never calls it).
#
# Covers:
#   a. one row per manifest item, per doctor line, per registry flag, per
#      secrets-manifest entry, per cadence (5, each once), per optional
#      plugin, per lane, per initiative leg; every spec §4 field present
#   b. codex-sweep on linux is display-only with reason "Windows only"
#   c. fires: doctor cadence = yes (last.tsv mtime); pipeline on linux =
#      unverified even though its stubbed status says ARMED; nothing but
#      component run evidence ever yields yes
#   d. redact(): a canary .env value planted in a stub probe detail is absent
#      from the output (and the RED control, redaction off, leaks it)
#   e. --items: a cadence-only call never invokes the stub doctor
#   f. flag-registry-lint: passes on the real tree, fails on a fixture hook
#      reading FAKE_THING_OK, fails on an entry naming no hook

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
lint="$repo_root/scripts/install/flag-registry-lint.mjs"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/config-feed.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# ── fixture repo root ───────────────────────────────────────────────────────
fixtureRepo="$work/repo"
mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/lanes"
cp "$repo_root/scripts/install/manifest.json" "$fixtureRepo/scripts/install/manifest.json"
cat > "$fixtureRepo/scripts/lanes/lanes.json" <<'JSON'
{"lanes":[{"id":"haiku","label":"Haiku"},{"id":"codex","label":"Codex"}]}
JSON
CANARY="canary-s3cr3t-value-9f8e7d"
printf 'HIMMEL_INITIATIVE=execute,pr\nJIRA_API_TOKEN=%s\n' "$CANARY" > "$fixtureRepo/.env"

homeDir="$work/home"
mkdir -p "$homeDir/.claude" "$homeDir/.himmel/state/doctor-cadence"
printf 'FAIL C44-skill-index\n' > "$homeDir/.himmel/state/doctor-cadence/last.tsv"
cacheDir="$work/cache"; mkdir -p "$cacheDir"
cat > "$cacheDir/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"user","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON

target="$work/target"; mkdir -p "$target"

# stub doctor: three known JSON lines; the third carries the canary
doctorLog="$work/doctor.calls"
stubDoctor="$work/stub-doctor.sh"
cat > "$stubDoctor" <<STUB
#!/usr/bin/env bash
echo called >> "$doctorLog"
printf '%s\n' '{"sev":"OK","id":"C1-guardrail","msg":"guardrail ok","remedy":""}'
printf '%s\n' '{"sev":"WARN","id":"C3-luna","msg":"luna dirty (execute,pr)","remedy":"commit it"}'
printf '%s\n' '{"sev":"FAIL","id":"C9-leak","msg":"token is $CANARY here","remedy":"rotate"}'
STUB
chmod +x "$stubDoctor"

# stub cadence scripts + plugin-profile.sh under one script root
scriptRoot="$work/scripts-root"
mkdir -p "$scriptRoot/scripts/luna" "$scriptRoot/scripts/cleanup" "$scriptRoot/scripts/machine-setup"
for s in luna/pipeline-cadence luna/qmd-cadence luna/graphmap-cadence doctor-cadence; do
  cat > "$scriptRoot/scripts/$s.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = status ] || exit 2
echo "ARMED      HIMMEL-Stub (cron: 30 01 * * *)"
STUB
done
cat > "$scriptRoot/scripts/cleanup/codex-sweep-cadence.sh" <<'STUB'
#!/usr/bin/env bash
echo "ERR codex-sweep-cadence: Windows-only" >&2
exit 2
STUB
cat > "$scriptRoot/scripts/machine-setup/plugin-profile.sh" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"always":[{"spec":"qmd@himmel","state":"enabled"}],"connectors":[],"onDemand":[{"spec":"context7@claude-plugins-official","state":"disabled","neededBy":"docs"},{"spec":"typescript-lsp@claude-plugins-official","state":"enabled","neededBy":"ts"}]}
JSON
STUB
chmod +x "$scriptRoot"/scripts/*.sh "$scriptRoot"/scripts/*/*.sh

# fake crontab first on PATH — must never be called
fakeBin="$work/fakebin"; mkdir -p "$fakeBin"
cronLog="$work/crontab.calls"
printf '#!/usr/bin/env bash\necho called >> "%s"\nexit 1\n' "$cronLog" > "$fakeBin/crontab"
chmod +x "$fakeBin/crontab"

run_report() {
  ( cd "$target" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
      HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" \
      HIMMEL_REPORT_DOCTOR="$(winpath "${DOCTOR_STUB:-$stubDoctor}")" HIMMEL_REPORT_CADENCE_ROOT="$(winpath "$scriptRoot")" \
      PATH="$fakeBin:$PATH" "$node_bin" "$wizard" report --json "$@" )
}

# ── a. RED: the verb does not exist yet ─────────────────────────────────────
out="$work/report.json"
run_report > "$out" 2> "$work/report.err" || { cat "$work/report.err" >&2; fail "report --json exited non-zero"; }
jq -e '.schema == "himmel-config-feed/1"' "$out" >/dev/null || fail "envelope schema"
for k in generatedAt target base rows summary; do
  jq -e "has(\"$k\")" "$out" >/dev/null || fail "envelope lacks $k"
done

manifest_n=$(jq '.items|length' "$repo_root/scripts/install/manifest.json")
n_item=$(jq '[.rows[]|select(.source=="item")]|length' "$out")
# a cadence's manifest item folds into its cadence row (spec §4: one identity)
n_item_cad=$(jq '[.rows[]|select(.source=="cadence")]|length' "$out")
[ "$n_item_cad" -eq 5 ] || fail "expected 5 cadence rows, got $n_item_cad"
folded=$(jq -r '[.items[].id|select(.=="pipeline-cadence" or .=="graphmap-cadence" or .=="codex-sweep-cadence")]|length' "$repo_root/scripts/install/manifest.json")
[ "$n_item" -eq $((manifest_n - folded)) ] || fail "item rows $n_item != manifest $manifest_n - folded $folded"
pass "a1 item rows and 5 cadence rows"

[ "$(jq '[.rows[]|select(.source=="doctor")]|length' "$out")" -eq 3 ] || fail "doctor rows != 3"
jq -e '[.rows[]|select(.id=="doctor:C3-luna")]|length==1' "$out" >/dev/null || fail "doctor:C3-luna row id"
reg_n=$(jq '.flags|length' "$repo_root/scripts/himmelctl/lib/bypass-flags.json" 2>/dev/null || echo 0)
[ "$reg_n" -gt 0 ] || fail "bypass-flags.json missing or empty"
[ "$(jq '[.rows[]|select(.source=="flag")]|length' "$out")" -eq "$reg_n" ] || fail "flag rows != registry"
sec_n=$(jq '.secrets|length' "$repo_root/scripts/himmelctl/lib/secrets-manifest.json")
[ "$(jq '[.rows[]|select(.source=="secret")]|length' "$out")" -eq "$sec_n" ] || fail "secret rows != manifest"
[ "$(jq '[.rows[]|select(.source=="plugin")]|length' "$out")" -eq 2 ] || fail "plugin rows != 2 optional"
[ "$(jq '[.rows[]|select(.source=="lane")]|length' "$out")" -eq 2 ] || fail "lane rows != 2"
[ "$(jq '[.rows[]|select(.source=="initiative")]|length' "$out")" -eq 7 ] || fail "initiative rows != 7"
pass "a2 per-source row counts"

bad=$(jq -r '.rows[]|select((.id|type)!="string" or (.source|type)!="string" or (.group|type)!="string" or (.title|type)!="string" or (.declared|type)!="object" or (.installed.state|type)!="string" or (.fires.state|type)!="string" or (.health|type)!="string" or (.fix|type)!="object" or (.control.class|type)!="string" or (.sensitive|type)!="boolean" or has("probedAt")==false)|.id' "$out")
[ -z "$bad" ] || fail "rows missing spec §4 fields: $bad"
[ "$(jq '[.rows[].id]|length - (unique|length)' "$out")" -eq 0 ] || fail "duplicate row ids: $(jq -r '[.rows[].id]|group_by(.)|map(select(length>1)|.[0])|join(",")' "$out")"
pass "a3 every row has the §4 fields, ids unique"

# ── b. codex-sweep display-only on linux ────────────────────────────────────
if [ "$(uname -s)" = Linux ]; then
  jq -e '.rows[]|select(.id=="codex-sweep-cadence")|.control.class=="display-only" and .control.reason=="Windows only"' "$out" >/dev/null || fail "codex-sweep not display-only 'Windows only'"
  pass "b codex-sweep display-only on linux"
fi

# ── c. fires honesty ────────────────────────────────────────────────────────
jq -e '.rows[]|select(.id=="doctor-cadence")|.fires.state=="yes" and (.fires.at|type)=="string"' "$out" >/dev/null || fail "doctor cadence fires != yes with a timestamp"
if [ "$(uname -s)" != MINGW64_NT ] && [ "$(uname -s)" != MSYS_NT ]; then
  jq -e '.rows[]|select(.id=="pipeline-cadence")|.fires.state=="unverified"' "$out" >/dev/null || fail "pipeline cadence fires != unverified on non-Windows"
fi
[ "$(jq '[.rows[]|select(.fires.state=="yes")]|map(.id)|sort|join(",")' "$out")" = '"doctor-cadence"' ] || fail "fires=yes on a row other than doctor-cadence"
pass "c fires: doctor yes, pipeline unverified, nothing else yes"

# ── d. redaction ────────────────────────────────────────────────────────────
if grep -q "$CANARY" "$out"; then fail "canary leaked into report output"; fi
jq -e '.rows[]|select(.id=="doctor:C9-leak")|(.installed.detail//"")+(.fix.remedy//"")+(.title//"")|contains("‹redacted›")' "$out" >/dev/null || fail "canary row not marked ‹redacted›"
pass "d canary absent, row shows ‹redacted›"
# a non-secret .env value (HIMMEL_INITIATIVE=execute,pr) must stay readable
jq -e '.rows[]|select(.id=="doctor:C3-luna")|.title|contains("execute,pr")' "$out" >/dev/null || fail "non-secret .env value was redacted from a title"
pass "d3 non-secret .env values are not redacted"
# RED control: a canary that is NOT a known .env value cannot be matched by shape, so it
# MUST leak (proves the check can fail). No production kill-switch is needed for this.
redRepo="$work/red-repo"; mkdir -p "$redRepo/scripts/install" "$redRepo/scripts/lanes"
cp "$fixtureRepo/scripts/install/manifest.json" "$redRepo/scripts/install/"; cp "$fixtureRepo/scripts/lanes/lanes.json" "$redRepo/scripts/lanes/"
printf 'HIMMEL_INITIATIVE=execute,pr\n' > "$redRepo/.env"
# shellcheck disable=SC2015
leak=$( cd "$target" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
      HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMELCTL_REPO_ROOT="$(winpath "$redRepo")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" \
      HIMMEL_REPORT_DOCTOR="$(winpath "$stubDoctor")" HIMMEL_REPORT_CADENCE_ROOT="$(winpath "$scriptRoot")" \
      PATH="$fakeBin:$PATH" "$node_bin" "$wizard" report --json | grep -c "$CANARY" || true )
[ "$leak" -ge 1 ] || fail "RED control: a canary absent from .env did not leak (check is vacuous)"
pass "d2 RED control leaks with redaction off"

# ── e. --items skips the doctor for a cadence-only request ──────────────────
: > "$doctorLog"; rm -f "$doctorLog"
run_report --items graphmap-cadence,doctor-cadence > "$work/items.json"
[ ! -e "$doctorLog" ] || fail "cadence-only --items invoked the doctor"
[ "$(jq '.rows|length' "$work/items.json")" -eq 2 ] || fail "--items returned $(jq '.rows|length' "$work/items.json") rows, want 2"
run_report --items doctor:C3-luna > "$work/items2.json"
[ -e "$doctorLog" ] || fail "--items for a doctor row did not run the doctor"
[ "$(jq '.rows|length' "$work/items2.json")" -eq 1 ] || fail "--items doctor:C3-luna row count"
pass "e --items re-probe skips the doctor unless a doctor row is asked for"

[ ! -e "$cronLog" ] || fail "the report called crontab"
pass "e2 crontab never called"

# ── e3. a doctor killed part-way must not read as a complete report ─────────
deadDoctor="$work/dead-doctor.sh"
cat > "$deadDoctor" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"sev":"OK","id":"C1-guardrail","msg":"guardrail ok","remedy":""}'
kill -KILL $$
STUB
chmod +x "$deadDoctor"
DOCTOR_STUB="$deadDoctor" run_report > "$work/dead.json" 2> "$work/dead.err" || fail "report exited non-zero on a killed doctor"
jq -e '[.rows[]|select(.id=="doctor:C1-guardrail")]|length==1' "$work/dead.json" >/dev/null || fail "partial doctor row dropped"
jq -e '.rows[]|select(.id=="doctor:run")|.health=="warn" and .installed.state=="degraded"' "$work/dead.json" >/dev/null || fail "killed doctor emitted no doctor:run failure row"
pass "e3 killed doctor adds a doctor:run failure row beside the partial rows"
DOCTOR_STUB="$deadDoctor" run_report --items doctor:C1-guardrail > "$work/dead2.json" 2> "$work/dead2.err" || fail "--items report exited non-zero on a killed doctor"
jq -e '[.rows[]|select(.id=="doctor:run")]|length==1' "$work/dead2.json" >/dev/null || fail "--items filter hid the doctor:run failure row"
pass "e4 an --items filter keeps the doctor:run failure row"

# ── e5. a secret present only in process.env is redacted ────────────────────
envDoctor="$work/env-doctor.sh"
cat > "$envDoctor" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"sev":"FAIL","id":"C8-envleak","msg":"saw plainsecretvalue99 here","remedy":""}'
printf '%s\n' '{"sev":"OK","id":"C9-plainsecretvalue99","msg":"ok","remedy":""}'
STUB
chmod +x "$envDoctor"
DOCTOR_STUB="$envDoctor" HIMMEL_TEST_API_TOKEN=plainsecretvalue99 run_report > "$work/env.json" 2> "$work/env.err" || fail "report exited non-zero (env-secret case)"
if grep -q plainsecretvalue99 "$work/env.json"; then fail "process.env-only secret leaked into the report"; fi
pass "e5 a secret known only from process.env is redacted"

# ── e6. --items matches the id the report shows (post-redaction) ────────────
DOCTOR_STUB="$envDoctor" HIMMEL_TEST_API_TOKEN=plainsecretvalue99 run_report --items 'doctor:C9-‹redacted›' > "$work/env2.json" 2> "$work/env2.err" || fail "report exited non-zero (redacted --items)"
jq -e '[.rows[]|select(.source=="doctor")]|length==1' "$work/env2.json" >/dev/null || fail "--items did not match a row by its redacted id"
pass "e6 --items finds a row by the redacted id the report prints"

# ── e7. a cadence that prints ARMED then exits non-zero is a failed probe ───
badScripts="$work/bad-scripts-root"; cp -R "$scriptRoot" "$badScripts"
printf '#!/usr/bin/env bash\necho "ARMED      HIMMEL-Stub (cron: 30 01 * * *)"\nexit 3\n' > "$badScripts/scripts/doctor-cadence.sh"
chmod +x "$badScripts/scripts/doctor-cadence.sh"
( cd "$target" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" \
    HIMMEL_REPORT_DOCTOR="$(winpath "$stubDoctor")" HIMMEL_REPORT_CADENCE_ROOT="$(winpath "$badScripts")" \
    PATH="$fakeBin:$PATH" "$node_bin" "$wizard" report --json --items doctor-cadence ) > "$work/bad-cad.json" 2>/dev/null || fail "report exited non-zero (bad cadence)"
jq -e '.rows[]|select(.id=="doctor-cadence")|.health!="ok"' "$work/bad-cad.json" >/dev/null || fail "ARMED + non-zero exit still reads healthy"
pass "e7 a cadence probe exiting non-zero after ARMED is not healthy"

# ── e8. a required secret of an unselected feature is off, not fail ─────────
jq -e '.rows[]|select(.id=="secret:TELEGRAM_BOT_TOKEN")|.health=="off"' "$out" >/dev/null || fail "required secret of an unselected feature reads fail"
pass "e8 required secret outside the selected features is off"

# ── f. flag-registry-lint ───────────────────────────────────────────────────
"$node_bin" "$lint" --root "$repo_root" >/dev/null 2>"$work/lint.err" || { cat "$work/lint.err" >&2; fail "lint fails on the real tree"; }
pass "f1 lint passes on the real tree"

lintRoot="$work/lintroot"
mkdir -p "$lintRoot/scripts/hooks" "$lintRoot/scripts/himmelctl/lib"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ "${FAKE_THING_OK:-}" = 1 ] && exit 0\n' > "$lintRoot/scripts/hooks/block-fake.sh"
printf '{"flags":[]}\n' > "$lintRoot/scripts/himmelctl/lib/bypass-flags.json"
if "$node_bin" "$lint" --root "$lintRoot" >/dev/null 2>"$work/lint2.err"; then fail "lint passed a hook reading FAKE_THING_OK with no entry"; fi
grep -q FAKE_THING_OK "$work/lint2.err" || fail "lint failure does not name FAKE_THING_OK"
printf '{"flags":[{"name":"FAKE_THING_OK","hooks":["scripts/hooks/block-fake.sh"],"bypasses":"x","remedy":"y"},{"name":"GHOST_OK","hooks":["scripts/hooks/no-such.sh"],"bypasses":"x","remedy":"y"}]}\n' > "$lintRoot/scripts/himmelctl/lib/bypass-flags.json"
if "$node_bin" "$lint" --root "$lintRoot" >/dev/null 2>"$work/lint3.err"; then fail "lint passed an entry naming no hook"; fi
grep -q GHOST_OK "$work/lint3.err" || fail "lint failure does not name GHOST_OK"
pass "f2 lint fails on an unregistered flag and on a ghost entry"

# ── g. secret presence comes from each secret's own source, never the repo .env
# HIMMEL-4327 (spec A7). The repo-root .env carries a same-named TELEGRAM_BOT_TOKEN
# (the nudge relay's DIFFERENT bot) and a FIRECRAWL_API_KEY the tools never read.
printf 'TELEGRAM_BOT_TOKEN=repo-root-other-bot-aaaa\nFIRECRAWL_API_KEY=repo-env-firecrawl-bbbb\nBITBUCKET_API_TOKEN=bb-fixture-token-cccc\n' >> "$fixtureRepo/.env"
mkdir -p "$homeDir/.claude/channels/telegram" "$homeDir/.luna/cookies"
sec() { jq -r --arg n "secret:$1" '.rows[]|select(.id==$n)|.installed.state' "$2"; }
WHISPER_MODEL='' WHISPER_DIR='' FIRECRAWL_API_KEY='' TELEGRAM_ENV='' run_report --items secret:TELEGRAM_BOT_TOKEN,secret:FIRECRAWL_API_KEY,secret:BITBUCKET_API_TOKEN,secret:INSTAGRAM_COOKIE_FILE,secret:WHISPER_MODEL > "$work/g1.json" 2>/dev/null || fail "g report exited non-zero"
[ "$(sec TELEGRAM_BOT_TOKEN "$work/g1.json")" = absent ] || fail "g1 TELEGRAM_BOT_TOKEN read as present from the repo-root .env (bridge file absent)"
[ "$(sec FIRECRAWL_API_KEY "$work/g1.json")" = absent ] || fail "g1 FIRECRAWL_API_KEY (process-env only) read as present from the repo-root .env"
[ "$(sec BITBUCKET_API_TOKEN "$work/g1.json")" = present ] || fail "g1 BITBUCKET_API_TOKEN (repo .env is its source) not present"
[ "$(sec INSTAGRAM_COOKIE_FILE "$work/g1.json")" = absent ] || fail "g1 INSTAGRAM_COOKIE_FILE present with no cookie file"
[ "$(sec WHISPER_MODEL "$work/g1.json")" = absent ] || fail "g1 WHISPER_MODEL present with no model file"
printf 'TELEGRAM_BOT_TOKEN=bridge-own-token-dddd\n' > "$homeDir/.claude/channels/telegram/.env"
printf '# Netscape\n.instagram.com\tTRUE\t/\tTRUE\t0\tsessionid\tx\n' > "$homeDir/.luna/cookies/instagram.txt"
mkdir -p "$homeDir/.himmel/whisper"; printf 'model' > "$homeDir/.himmel/whisper/ggml-small.bin"
WHISPER_MODEL='' WHISPER_DIR='' FIRECRAWL_API_KEY=process-env-key-eeee TELEGRAM_ENV='' run_report --items secret:TELEGRAM_BOT_TOKEN,secret:FIRECRAWL_API_KEY,secret:INSTAGRAM_COOKIE_FILE,secret:WHISPER_MODEL > "$work/g2.json" 2>/dev/null || fail "g2 report exited non-zero"
for n in TELEGRAM_BOT_TOKEN FIRECRAWL_API_KEY INSTAGRAM_COOKIE_FILE WHISPER_MODEL; do
  [ "$(sec "$n" "$work/g2.json")" = present ] || fail "g2 $n not present from its own source"
done
for v in bridge-own-token-dddd process-env-key-eeee repo-root-other-bot-aaaa; do
  if grep -q "$v" "$work/g1.json" "$work/g2.json"; then fail "g3 a secret value ($v) reached the feed"; fi
done
# every manifest secret must have a declared presence source (a new secret fails here, not silently absent)
node_missing=$("$node_bin" -e 'const f=require(process.argv[1]);const m=require(process.argv[2]);const miss=m.secrets.map(s=>s.name).filter(n=>!(f.PRESENCE_SOURCES||{})[n]);process.stdout.write(miss.join(","))' "$repo_root/scripts/himmelctl/lib/config-feed.js" "$repo_root/scripts/himmelctl/lib/secrets-manifest.json" 2>&1)
[ -z "$node_missing" ] || fail "g4 manifest secrets with no presence source: $node_missing"
pass "g secret presence per consumer source, no values emitted, manifest fully covered"

# ── h. redactor hardening (HIMMEL-4327) ─────────────────────────────────────
redact_js="$repo_root/scripts/himmelctl/lib/redact.js"
probes_js="$repo_root/scripts/himmelctl/lib/probes.js"
rj() { "$node_bin" -e "const r=require(process.argv[1]);const p=require(process.argv[2]);$1" "$redact_js" "$probes_js"; }
# h1: short secret values are scrubbed; a short literal must not shred a longer word
o=$(rj 'const l=r.envValues("DB_PASSWORD=ab12\n",p.parseDotEnv);process.stdout.write(r.redact("pw is ab12 and ab12xyz",{literals:l}))')
case "$o" in *"is ab12 "*) fail "h1 a 4-char secret value was not scrubbed: $o";; esac
case "$o" in *ab12xyz*) :;; *) fail "h1 a short literal shredded a longer word: $o";; esac
pass "h1 short secret values scrubbed on word boundaries"
# h2: a multiline quoted value is scrubbed line by line, unbalanced leading quote included
o=$(rj 'const raw="API_SECRET=\"firstlinesecret\nsecondlinesecret\"\nOTHER_TOKEN=\"danglingquote\n";const l=r.envValues(raw,p.parseDotEnv);process.stdout.write(r.redact("a firstlinesecret b secondlinesecret c danglingquote d",{literals:l}))') || fail "h2 node redaction run failed"
for v in firstlinesecret secondlinesecret danglingquote; do
  case "$o" in *"$v"*) fail "h2 multiline/unbalanced-quote value leaked ($v): $o";; esac
done
pass "h2 multiline and unbalanced-quote .env values scrubbed"
# h2b: an escaped quote on the first line does not close a multiline value
o=$(rj 'const raw="API_SECRET=\"say \\\"hi\nescapedtailsecret\"\n";const l=r.envValues(raw,p.parseDotEnv);process.stdout.write(r.redact("x escapedtailsecret y",{literals:l}))') || fail "h2b node redaction run failed"
case "$o" in *escapedtailsecret*) fail "h2b escaped-quote multiline value leaked its tail: $o";; esac
pass "h2b escaped quote does not end a multiline value"
# h2c: an empty assignment is absent even when the next line has a value
printf 'BITBUCKET_API_TOKEN=\nOTHER=value\n' > "$work/empty-assign.env"
o=$("$node_bin" -e 'const c=require(process.argv[1]);process.stdout.write(String(c.envFileHasKey(process.argv[2],"BITBUCKET_API_TOKEN")))' "$repo_root/scripts/himmelctl/lib/config-feed.js" "$work/empty-assign.env") || fail "h2c node run failed"
[ "$o" = false ] || fail "h2c empty assignment read as present (got $o)"
pass "h2c empty assignment is not present"
# h3: an unreadable .env is stated in the envelope; a readable one says ok
unreadRepo="$work/unread-repo"; mkdir -p "$unreadRepo/scripts/install" "$unreadRepo/scripts/lanes" "$unreadRepo/.env"
cp "$fixtureRepo/scripts/install/manifest.json" "$unreadRepo/scripts/install/"; cp "$fixtureRepo/scripts/lanes/lanes.json" "$unreadRepo/scripts/lanes/"
( cd "$target" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
    HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMELCTL_REPO_ROOT="$(winpath "$unreadRepo")" \
    HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" \
    HIMMEL_REPORT_DOCTOR="$(winpath "$stubDoctor")" HIMMEL_REPORT_CADENCE_ROOT="$(winpath "$scriptRoot")" \
    PATH="$fakeBin:$PATH" "$node_bin" "$wizard" report --json ) > "$work/unread.json" 2>/dev/null || fail "h3 report exited non-zero on an unreadable .env"
[ "$(jq -r '.redaction.env' "$work/unread.json")" = unreadable ] || fail "h3 unreadable .env not reported in the envelope (got $(jq -c '.redaction' "$work/unread.json"))"
[ "$(jq -r '.redaction.env' "$out")" = ok ] || fail "h3 readable .env not reported ok"
pass "h3 an unreadable .env is stated in the envelope"
# h4: HIMMEL_REPORT_NO_REDACT is gone from production code: setting it changes nothing
# shellcheck disable=SC2015
leak4=$( cd "$target" && HIMMEL_REPORT_NO_REDACT=1 HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
      HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" \
      HIMMEL_REPORT_DOCTOR="$(winpath "$stubDoctor")" HIMMEL_REPORT_CADENCE_ROOT="$(winpath "$scriptRoot")" \
      PATH="$fakeBin:$PATH" "$node_bin" "$wizard" report --json | grep -c "$CANARY" || true )
[ "$leak4" -eq 0 ] || fail "h4 HIMMEL_REPORT_NO_REDACT=1 still disables redaction in production code"
if grep -rq NO_REDACT "$repo_root/scripts/himmelctl/lib"; then fail "h4 NO_REDACT still referenced under scripts/himmelctl/lib"; fi
pass "h4 no production redaction kill-switch"
# h5: flag-registry-lint fails when scripts/hooks is missing, and CI runs it on pinned node
emptyRoot="$work/lint-nohooks"; mkdir -p "$emptyRoot/scripts/himmelctl/lib"
printf '{"flags":[]}\n' > "$emptyRoot/scripts/himmelctl/lib/bypass-flags.json"
if "$node_bin" "$lint" --root "$emptyRoot" >/dev/null 2>"$work/lint4.err"; then fail "h5 lint passed vacuously with no scripts/hooks"; fi
grep -q 'scripts/hooks' "$work/lint4.err" || fail "h5 lint failure does not name scripts/hooks"
lint_job=$(awk '/^  lint:/{f=1;next} /^  [a-z-]+:$/{f=0} f' "$repo_root/.github/workflows/ci.yml")
case "$lint_job" in *actions/setup-node*) :;; *) fail "h5 CI lint job runs flag-registry-lint without setup-node (unpinned node)";; esac
pass "h5 flag-registry-lint fails on a missing hooks dir; CI pins node"

echo "ALL PASS"
