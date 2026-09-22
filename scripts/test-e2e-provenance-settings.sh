#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-e2e-provenance-settings.sh -- the settings.json wire libs record what they
# did in the install-provenance ledger (HIMMEL-3332 S2). Drives the real
# test-e2e-symmetry.sh install phase (statusline, himmel-repo, the PreToolUse trio,
# the SessionStart hook) plus luna-vault and handover-dir against a scratch HOME,
# then asserts the ledger rows: op, kind, unit, scope, backup and pre/post shas.
#
# RED before the slice: no lib writes a ledger, so provenance.jsonl never exists.
# jq-only (no git / node / bun). The uninstall side is S6's, not read here.
#
# Usage: bash scripts/test-e2e-provenance-settings.sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"   # <repo>/scripts
lib="$here/lib"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

command -v jq >/dev/null 2>&1 || { echo "test-e2e-provenance-settings: jq required" >&2; exit 2; }

td="$(mktemp -d "${TMPDIR:-/tmp}/prov-settings.XXXXXX")" || { echo "test-e2e-provenance-settings: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$td"' EXIT
HIMMEL_FAKE="C:/fake/himmel"
# A scratch HOME for the whole run: the ledger defaults to $HOME/.himmel, so this
# is what keeps the suite off the operator's real ~/.himmel. CLAUDE_CONFIG_DIR is
# unset (the wire scripts honour it) and HIMMEL_PROVENANCE_DIR / _IID are cleared
# so the default location and the implicit one-row session are what is exercised.
export HOME="$td/home"
unset CLAUDE_CONFIG_DIR HIMMEL_PROVENANCE_DIR HIMMEL_PROVENANCE_IID
SETTINGS="$HOME/.claude/settings.json"
LEDGER="$HOME/.himmel/provenance.jsonl"
mkdir -p "$(dirname "$SETTINGS")" "$td/cwd"
cd "$td/cwd" || exit 2

# The operator's own settings: an rtk guard, a user statusLine (keys deliberately
# not in jq -S order) and an MCP allow. No .env, so the wires create it.
cat > "$SETTINGS" <<'JSON'
{
  "hooks": {"PreToolUse": [{"matcher":"Bash","hooks":[{"type":"command","command":"bash /opt/rtk-hook-guard.sh"}]}]},
  "statusLine": {"type":"command","command":"my-own-statusline --x","padding":1},
  "permissions": {"allow":["mcp__obsidian-vault__obsidian_simple_search"]}
}
JSON
SEED_STATUSLINE="$(jq -cS .statusLine "$SETTINGS")"

wires() {
  bash "$lib/wire-statusline.sh"        "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
  bash "$lib/wire-himmel-repo.sh"       "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
  bash "$lib/wire-pretooluse-hooks.sh"  "$SETTINGS" "$HIMMEL_FAKE" >/dev/null
  bash "$lib/wire-pretooluse-hooks.sh"  --sessionstart "$SETTINGS" "$HIMMEL_FAKE" "inject-initiative.sh" >/dev/null
  bash "$lib/wire-luna-vault.sh"        "$SETTINGS" "C:/fake/vault" >/dev/null
  bash "$lib/wire-handover-dir.sh"      "$SETTINGS" "C:/fake/vault/handovers" >/dev/null
}
sha() { printf '%s' "$1" | sha256sum | awk '{print $1}'; }
# rows_of <unit> [op] -- artifact rows for one unit, optionally one op
rows_of() { jq -c --arg u "$1" --arg o "${2:-}" 'select(.unit==$u and ($o=="" or .op==$o))' "$LEDGER" 2>/dev/null; }
count_of() { rows_of "$@" | grep -c . ; }
field() { jq -r "$1" 2>/dev/null; }

echo "==== FIRST RUN ===="
wires
check "ledger written" "$([ -s "$LEDGER" ] && echo yes || echo no)" "yes"
check "every ledger line parses" "$(jq -c . "$LEDGER" >/dev/null 2>&1 && echo yes || echo no)" "yes"

# --- /statusLine: the user's own value is replaced, so it is backed up -------------
check "one /statusLine row"            "$(count_of /statusLine)" "1"
sl="$(rows_of /statusLine)"
check "statusLine op=replace"          "$(printf '%s' "$sl" | field .op)" "replace"
check "statusLine kind=json-key"       "$(printf '%s' "$sl" | field .kind)" "json-key"
check "statusLine scope=user"          "$(printf '%s' "$sl" | field .scope)" "user"
check "statusLine path is the resolved settings" "$(printf '%s' "$sl" | field .path)" "$(cd "$(dirname "$SETTINGS")" && pwd -P)/settings.json"
check "statusLine pre.sha = seeded value sha" "$(printf '%s' "$sl" | field .pre.sha)" "$(sha "$SEED_STATUSLINE")"
check "statusLine post.sha = wired value sha" "$(printf '%s' "$sl" | field .post.sha)" "$(sha "$(jq -cS .statusLine "$SETTINGS")")"
bk="$(printf '%s' "$sl" | field .pre.backup)"
check "statusLine backup is a .prior.json"   "$(case "$bk" in *.prior.json) echo yes;; *) echo no;; esac)" "yes"
check "statusLine backup exists"             "$([ -f "$bk" ] && echo yes || echo no)" "yes"
check "statusLine backup jq -S-equals the seed" "$(jq -S . "$bk" 2>/dev/null | jq -cS .)" "$SEED_STATUSLINE"
n_backups_1="$(find "$HOME/.himmel/provenance-backups" -type f | wc -l | tr -d ' ')"

# --- /env: created by the first wire that needs it, once ---------------------------
check "one /env create row"             "$(count_of /env create)" "1"
check "/env/CLAUDE_HUD_ALLOW_EXTRA_CMD create" "$(rows_of /env/CLAUDE_HUD_ALLOW_EXTRA_CMD | field .op)" "create"
check "/env/HIMMEL_REPO create"         "$(rows_of /env/HIMMEL_REPO | field .op)" "create"
check "/env/HIMMEL_REPO pre absent"     "$(rows_of /env/HIMMEL_REPO | field .pre.state)" "absent"
check "/env/HIMMEL_REPO post.sha"       "$(rows_of /env/HIMMEL_REPO | field .post.sha)" "$(sha "$(jq -cS .env.HIMMEL_REPO "$SETTINGS")")"
check "/env/LUNA_VAULT_PATH create"     "$(rows_of /env/LUNA_VAULT_PATH | field .op)" "create"
check "/env/HANDOVER_DIR create"        "$(rows_of /env/HANDOVER_DIR | field .op)" "create"

# --- PreToolUse trio + SessionStart: elements inserted into a container -------------
check "three PreToolUse insert rows"    "$(count_of /hooks/PreToolUse insert)" "3"
check "PreToolUse container pre-existed" "$(rows_of /hooks/PreToolUse insert | field .container_created | sort -u)" "false"
check "PreToolUse elem_sha = post.sha"  "$(rows_of /hooks/PreToolUse insert | jq -r 'select(.elem_sha != .post.sha)' | grep -c .)" "0"
check "PreToolUse elem shas are the wired stanzas" \
  "$(rows_of /hooks/PreToolUse insert | jq -r .elem_sha | sort | tr '\n' ' ')" \
  "$(jq -c '.hooks.PreToolUse[] | select(.hooks[0].command | test("scripts/hooks/(auto-approve-safe-bash|block-edit-on-main|block-read-secrets)"))' "$SETTINGS" | while IFS= read -r e; do sha "$(printf '%s' "$e" | jq -cS .)"; done | sort | tr '\n' ' ')"
check "PreToolUse rows pre absent"      "$(rows_of /hooks/PreToolUse insert | field .pre.state | sort -u)" "absent"
check "the operator's rtk stanza has no row" "$(rows_of /hooks/PreToolUse | grep -c 'rtk-hook-guard')" "0"
check "one SessionStart insert row"     "$(count_of /hooks/SessionStart insert)" "1"
check "SessionStart container created"  "$(rows_of /hooks/SessionStart insert | field .container_created)" "true"
check "no /hooks row: the operator's hooks object pre-existed" "$(count_of /hooks)" "0"
check "SessionStart elem_sha = wired hook sha" "$(rows_of /hooks/SessionStart insert | field .elem_sha)" \
  "$(sha "$(jq -cS '.hooks.SessionStart[0].hooks[0]' "$SETTINGS")")"

# --- one session per wire call: every row carries a session and a writer ------------
check "every artifact row names its writer" "$(jq -r 'select(.kind and (.writer|not))' "$LEDGER" | grep -c .)" "0"
check "every artifact row carries a manifest row" "$(jq -r 'select(.kind and (.manifest_row|not))' "$LEDGER" | grep -c .)" "0"

echo "==== SECOND RUN (control: same wires, nothing changes) ===="
n_rows_1="$(wc -l < "$LEDGER" | tr -d ' ')"
wires
n_backups_2="$(find "$HOME/.himmel/provenance-backups" -type f | wc -l | tr -d ' ')"
check "no second backup of the user's statusLine" "$n_backups_2" "$n_backups_1"
check "two /statusLine rows now"        "$(count_of /statusLine)" "2"
sl2="$(rows_of /statusLine | tail -1)"
check "second /statusLine row is a noop" "$(printf '%s' "$sl2" | field .op)" "noop"
check "noop pre.sha == previous post.sha" "$(printf '%s' "$sl2" | field .pre.sha)" "$(printf '%s' "$sl" | field .post.sha)"
check "noop post.sha == previous post.sha" "$(printf '%s' "$sl2" | field .post.sha)" "$(printf '%s' "$sl" | field .post.sha)"
check "no second /env create row"       "$(count_of /env create)" "1"
check "second PreToolUse rows are all noop" "$(rows_of /hooks/PreToolUse | tail -3 | field .op | sort -u)" "noop"
check "second SessionStart row is a noop" "$(rows_of /hooks/SessionStart | tail -1 | field .op)" "noop"
check "second HIMMEL_REPO row is a noop"  "$(rows_of /env/HIMMEL_REPO | tail -1 | field .op)" "noop"
check "the second run recorded rows"    "$([ "$(wc -l < "$LEDGER" | tr -d ' ')" -gt "$n_rows_1" ] && echo yes || echo no)" "yes"

echo "==== CHANGED VALUES (replace + backup) ===="
# A moved clone: every himmel-owned value changes. Each replace backs up the prior
# value, and the PreToolUse / SessionStart entries are edited in place.
bash "$lib/wire-himmel-repo.sh"       "$SETTINGS" "C:/moved/himmel" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh"  "$SETTINGS" "C:/moved/himmel" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh"  --sessionstart "$SETTINGS" "C:/moved/himmel" "inject-initiative.sh" >/dev/null
r="$(rows_of /env/HIMMEL_REPO | tail -1)"
check "moved HIMMEL_REPO op=replace"    "$(printf '%s' "$r" | field .op)" "replace"
check "moved HIMMEL_REPO backup holds the old value" "$(cat "$(printf '%s' "$r" | field .pre.backup)")" '"C:/fake/himmel"'
check "three PreToolUse replace rows"   "$(count_of /hooks/PreToolUse replace)" "3"
check "PreToolUse replace backups exist" "$(rows_of /hooks/PreToolUse replace | jq -r .pre.backup | while IFS= read -r b; do [ -f "$b" ] && echo y; done | grep -c y)" "3"
check "PreToolUse replace post.sha = new stanza" "$(rows_of /hooks/PreToolUse replace | jq -r .post.sha | sort | tr '\n' ' ')" \
  "$(jq -c '.hooks.PreToolUse[] | select(.hooks[0].command | test("moved/himmel"))' "$SETTINGS" | while IFS= read -r e; do sha "$(printf '%s' "$e" | jq -cS .)"; done | sort | tr '\n' ' ')"
check "SessionStart replace row"        "$(count_of /hooks/SessionStart replace)" "1"

echo "==== PROJECT SCOPE ===="
PSET="$td/proj/.claude/settings.json"
bash "$lib/wire-himmel-repo.sh"       "$PSET" "$HIMMEL_FAKE" >/dev/null
bash "$lib/wire-pretooluse-hooks.sh"  "$PSET" '$CLAUDE_PROJECT_DIR' >/dev/null
check "project HIMMEL_REPO row scope"   "$(jq -r --arg p "$(cd "$td/proj/.claude" && pwd -P)/settings.json" 'select(.unit=="/env/HIMMEL_REPO" and .path==$p) | .scope' "$LEDGER")" "project"
bash "$lib/wire-pretooluse-hooks.sh"  --sessionstart "$PSET" '$CLAUDE_PROJECT_DIR' "inject-initiative.sh" >/dev/null
prow() { jq -c --arg u "$1" --arg p "$(cd "$td/proj/.claude" && pwd -P)/settings.json" 'select(.unit==$u and .path==$p)' "$LEDGER"; }
check "project: one /hooks row for the created hooks object (HIMMEL-3389)" "$(prow /hooks | grep -c .)" "1"
check "project: /hooks op=create"       "$(prow /hooks | field .op)" "create"
check "project: /hooks pre absent"      "$(prow /hooks | field .pre.state)" "absent"
check "project: /hooks writer"          "$(prow /hooks | field .writer)" "wire-pretooluse-hooks.sh"
check "project PreToolUse rows scope"   "$(jq -r --arg p "$(cd "$td/proj/.claude" && pwd -P)/settings.json" 'select(.unit=="/hooks/PreToolUse" and .path==$p) | .scope' "$LEDGER" | sort -u)" "project"

echo "==== AN EXPLICIT JSON null PRE-STATE IS RECORDED AS null, NOT AS ABSENT (HIMMEL-3352) ===="
# `"statusLine": null` / `"env": null` / `"env": {"K": null}` are present-with-null:
# the row must be pre.state=present with the sha of `null` (and a backup, since the
# wire replaces it), so a rollback restores the null instead of deleting the key.
NULLSHA="$(sha null)"
# null_rows <settings dir> <unit> -- the rows one settings file wrote for one unit
null_rows() { jq -c --arg u "$2" --arg p "$(cd "$1" && pwd -P)/settings.json" 'select(.unit==$u and .path==$p)' "$LEDGER"; }
# null_case <label> <settings JSON> <unit> <expected op> <writer lib> <wire arg> [<key>]
null_case() {
  local label="$1" seed="$2" unit="$3" want_op="$4" wlib="$5" warg="$6" d r bk
  d="$td/null-$label/.claude"; mkdir -p "$d"; printf '%s' "$seed" > "$d/settings.json"
  bash "$lib/$wlib" "$d/settings.json" "$warg" >/dev/null
  r="$(null_rows "$d" "$unit")"
  check "$label: $unit op=$want_op"          "$(printf '%s' "$r" | field .op)" "$want_op"
  check "$label: $unit pre.state=present"    "$(printf '%s' "$r" | field .pre.state)" "present"
  check "$label: $unit pre.sha = sha(null)"  "$(printf '%s' "$r" | field .pre.sha)" "$NULLSHA"
  bk="$(printf '%s' "$r" | field .pre.backup)"
  check "$label: $unit backup holds null"    "$([ -f "$bk" ] && cat "$bk")" "null"
}
null_case sl-statusline '{"statusLine": null}'                                 /statusLine                    replace wire-statusline.sh   "$HIMMEL_FAKE"
null_case sl-env        '{"env": null}'                                        /env                           replace wire-statusline.sh   "$HIMMEL_FAKE"
null_case sl-envkey     '{"env": {"CLAUDE_HUD_ALLOW_EXTRA_CMD": null}}'        /env/CLAUDE_HUD_ALLOW_EXTRA_CMD replace wire-statusline.sh   "$HIMMEL_FAKE"
null_case hr-env        '{"env": null}'                                        /env                           replace wire-himmel-repo.sh  "$HIMMEL_FAKE"
null_case hr-envkey     '{"env": {"HIMMEL_REPO": null}}'                       /env/HIMMEL_REPO               replace wire-himmel-repo.sh  "$HIMMEL_FAKE"
null_case lv-env        '{"env": null}'                                        /env                           replace wire-luna-vault.sh   "C:/fake/vault"
null_case lv-envkey     '{"env": {"LUNA_VAULT_PATH": null}}'                   /env/LUNA_VAULT_PATH           replace wire-luna-vault.sh   "C:/fake/vault"
null_case hd-env        '{"env": null}'                                        /env                           replace wire-handover-dir.sh "C:/fake/handovers"
null_case hooks-null     '{"hooks": null}'                                      /hooks                         replace wire-pretooluse-hooks.sh "$HIMMEL_FAKE"
null_case hd-envkey     '{"env": {"HANDOVER_DIR": null}}'                      /env/HANDOVER_DIR              replace wire-handover-dir.sh "C:/fake/handovers"
# A null-valued sibling key is not the key being wired: the wired key is still `create`.
d="$td/null-sibling/.claude"; mkdir -p "$d"; printf '%s' '{"env": {"OTHER": null}}' > "$d/settings.json"
bash "$lib/wire-himmel-repo.sh" "$d/settings.json" "$HIMMEL_FAKE" >/dev/null
check "a null SIBLING key leaves the wired key a create" "$(null_rows "$d" /env/HIMMEL_REPO | field .op)" "create"
check "a null SIBLING key leaves the wired key absent"   "$(null_rows "$d" /env/HIMMEL_REPO | field .pre.state)" "absent"

echo "==== A LEADING ~ IN CLAUDE_CONFIG_DIR IS EXPANDED WHEN CLASSIFYING SCOPE (HIMMEL-3352) ===="
# The settings file sits in the user's config dir, spelled `~/tildecfg` in
# CLAUDE_CONFIG_DIR. Every recorder must classify it `user`, as the hud's own
# getClaudeConfigDir() does; unexpanded, `cd '~/tildecfg'` fails and it reads `project`.
TCFG="$HOME/tildecfg"; mkdir -p "$TCFG"
TSET="$TCFG/settings.json"
# shellcheck disable=SC2088  # the literal `~/` is the input under test
TILDE='~/tildecfg'
CLAUDE_CONFIG_DIR="$TILDE" bash "$lib/wire-statusline.sh"       "$TSET" "$HIMMEL_FAKE" >/dev/null
CLAUDE_CONFIG_DIR="$TILDE" bash "$lib/wire-himmel-repo.sh"      "$TSET" "$HIMMEL_FAKE" >/dev/null
CLAUDE_CONFIG_DIR="$TILDE" bash "$lib/wire-luna-vault.sh"       "$TSET" "C:/fake/vault" >/dev/null
CLAUDE_CONFIG_DIR="$TILDE" bash "$lib/wire-handover-dir.sh"     "$TSET" "C:/fake/handovers" >/dev/null
CLAUDE_CONFIG_DIR="$TILDE" bash "$lib/wire-pretooluse-hooks.sh" "$TSET" "$HIMMEL_FAKE" >/dev/null
CLAUDE_CONFIG_DIR="$TILDE" bash "$lib/wire-pretooluse-hooks.sh" --sessionstart "$TSET" "$HIMMEL_FAKE" "inject-initiative.sh" >/dev/null
for u in /statusLine /env/HIMMEL_REPO /env/LUNA_VAULT_PATH /env/HANDOVER_DIR /hooks/PreToolUse /hooks/SessionStart; do
  check "tilde CLAUDE_CONFIG_DIR: $u scope=user" "$(null_rows "$TCFG" "$u" | field .scope | sort -u)" "user"
done
# Control: the tilde must not over-match -- a settings file elsewhere stays project.
TPROJ="$td/tilde-proj/.claude"; mkdir -p "$TPROJ"
CLAUDE_CONFIG_DIR="$TILDE" bash "$lib/wire-himmel-repo.sh" "$TPROJ/settings.json" "$HIMMEL_FAKE" >/dev/null
check "tilde CLAUDE_CONFIG_DIR: a project settings file stays project" "$(null_rows "$TPROJ" /env/HIMMEL_REPO | field .scope)" "project"

echo "==== A FAILED RECORD NEVER FAILS THE WIRE ===="
printf 'x' > "$td/not-a-dir"
S2="$td/s2/.claude/settings.json"
err="$(HIMMEL_PROVENANCE_DIR="$td/not-a-dir" bash "$lib/wire-himmel-repo.sh" "$S2" "$HIMMEL_FAKE" 2>&1 >/dev/null)"; rc=$?
check "wire rc=0 when the ledger is unwritable" "$rc" "0"
check "settings still wired"            "$(jq -r .env.HIMMEL_REPO "$S2")" "C:/fake/himmel"
check "a warning names the record failure" "$([ "$(printf '%s' "$err" | grep -c 'provenance')" -ge 1 ] && echo yes || echo no)" "yes"

echo "==== A FAILED WRITE STILL FAILS THE WIRE (never a success echo) ===="
# A directory squatting on the temp path makes the redirect fail, so the settings
# write itself fails. Recording must not turn that into a reported success.
for w in himmel-repo:himmelrepo luna-vault:lunavault handover-dir:handoverdir; do
  lib_name="${w%%:*}"; tmp_tag="${w##*:}"
  WF="$td/wf-$lib_name/.claude/settings.json"; mkdir -p "$WF.$tmp_tag.tmp"
  out="$(bash "$lib/wire-$lib_name.sh" "$WF" "$HIMMEL_FAKE" 2>/dev/null)"; rc=$?
  check "wire-$lib_name rc!=0 when the settings write fails" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
  check "wire-$lib_name prints no success line"              "$(printf '%s' "$out" | grep -c 'set env')" "0"
done
WF="$td/wf-hooks/.claude/settings.json"; mkdir -p "$WF.wirehooks.tmp"
out="$(bash "$lib/wire-pretooluse-hooks.sh" "$WF" "$HIMMEL_FAKE" 2>/dev/null)"; rc=$?
check "wire-pretooluse-hooks rc!=0 when the settings write fails" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "wire-pretooluse-hooks prints no success line"              "$(printf '%s' "$out" | grep -c 'wired')" "0"
out="$(bash "$lib/wire-pretooluse-hooks.sh" --sessionstart "$WF" "$HIMMEL_FAKE" inject-initiative.sh 2>/dev/null)"; rc=$?
check "wire-sessionstart rc!=0 when the settings write fails"     "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "wire-sessionstart prints no success line"                  "$(printf '%s' "$out" | grep -c 'wired')" "0"

[ "$fails" -eq 0 ] && echo "E2E PROVENANCE-SETTINGS ALL PASS" || { echo "$fails E2E PROVENANCE-SETTINGS FAILED"; exit 1; }
