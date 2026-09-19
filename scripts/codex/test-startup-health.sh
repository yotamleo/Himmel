#!/usr/bin/env bash
# Hermetic tests for startup-health.sh (HIMMEL-747).
# No real Codex install: each case builds a temp CODEX_HOME with a synthetic
# rollout .jsonl (names the session thread_id) + a synthetic logs_2.sqlite. The
# detector reads logs_2.sqlite by printable-run byte extraction (grep -aoE), NOT
# via a sqlite driver, so a plain text file carrying the real WARN message shapes
# is a faithful fixture. Asserts: healthy -> 0; each signal detected -> 1 + its
# WARN line; a marker under an OLD (non-current) thread_id does NOT fire (session
# scoping); oversized _where-are-we -> 1; missing CODEX_HOME -> 2; bad arg -> 2.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/startup-health.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NEW_TID="019f3c01-afbf-7ef3-a689-c5be6d9afde0"
OLD_TID="019f0000-0000-7000-8000-000000000000"

# make_home <name> <tid> <waw_text> -> echoes the CODEX_HOME path (no logs_2.sqlite yet)
make_home() {
  local home="$TMP/$1" tid="$2" waw="$3"
  local dir="$home/sessions/2026/07/07"
  mkdir -p "$dir"
  # Rollout filename ends in the thread_id; lexical sort picks the newest.
  local f="$dir/rollout-2026-07-07T11-56-16-$tid.jsonl"
  # A token_count line (noise) + the where-are-we injection line.
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count"}}' > "$f"
  jq -cn --arg t "$waw" '{type:"response_item",payload:{type:"message",content:[{type:"text",text:$t}]}}' >> "$f"
  # HIMMEL-1145: a fully-registered config.toml, so every case below that is NOT
  # about registration stays healthy. Cases that are overwrite it via write_config.
  write_config "$home" all
  echo "$home"
}

# The expected set comes from the SAME data file the detector reads — this suite
# must not become the second hardcoded copy the ticket forbids.
PLUGIN_SET="$SCRIPT_DIR/himmel-plugin-set.conf"
set_field() { tr -d '\r' < "$1" | awk -F': *' -v k="$2" '$1==k{print $2; exit}'; }
MARKET="$(set_field "$PLUGIN_SET" marketplace)"
DEFAULT_PLUGINS="$(set_field "$PLUGIN_SET" default)"

# write_config <home> <mode> [skip-plugin] — synthesize $CODEX_HOME/config.toml in
# the shape codex itself writes (live-verified: `[marketplaces.himmel]` +
# `[plugins."name@himmel"]` / `enabled = true`).
#   all      marketplace + every default plugin enabled
#   nomarket every default plugin enabled, marketplace table absent
#   skip     everything except <skip-plugin> (absent entirely)
#   disable  everything, but <skip-plugin> carries `enabled = false`
#   empty    an unrelated config only (no himmel registration at all)
write_config() {
  local home="$1" mode="$2" skip="${3:-}" cfg="$1/config.toml" p
  {
    printf 'model = "gpt-5"\n\n[marketplaces.openai-bundled]\nsource_type = "local"\n\n'
    printf '[plugins."browser@openai-bundled"]\nenabled = true\n\n'
    if [ "$mode" != empty ]; then
      [ "$mode" = nomarket ] || printf '[marketplaces.%s]\nsource_type = "local"\nsource = "/x/marketplace"\n\n' "$MARKET"
      for p in $DEFAULT_PLUGINS; do
        if [ "$mode" = skip ] && [ "$p" = "$skip" ]; then continue; fi
        printf '[plugins."%s@%s"]\n' "$p" "$MARKET"
        if [ "$mode" = disable ] && [ "$p" = "$skip" ]; then printf 'enabled = false\n\n'; else printf 'enabled = true\n\n'; fi
      done
    fi
  } > "$cfg"
}

# A real-shape WARN row body (level+target+span+message on one printable line).
db_hook_row()  { printf 'WARN codex_core_plugins::manifest session_loop{thread_id=%s}:submission_dispatch{}:turn: load_plugins_from_layer_stack: ignoring hooks: expected a string, string array, object, or object array; found object\n' "$1"; }
# HIMMEL-1104: the SAME "ignoring hooks" text from the marketplace SUGGESTION
# scan (non-installed plugins; parsed hooks discarded). Real shape, captured live.
db_suggest_row() { printf 'WARN codex_core_plugins::manifest session_loop{thread_id=%s}:submission_dispatch{}:turn:built_tools.load_discoverable_tools:list_tool_suggest_discoverable_tools_with_auth:list_tool_suggest_discoverable_plugins: ignoring hooks: expected a string, string array, object, or object array; found object\n' "$1"; }
# Write a plugin-cache hooks.json fixture: make_hooks <home> <rel-dir> <with_desc>
make_hooks() {
  local dir="$1/plugins/cache/$2"
  mkdir -p "$dir"
  if [ "$3" = "desc" ]; then
    printf '%s\n' '{"description":"x","hooks":{"SessionStart":[]}}' > "$dir/hooks.json"
  else
    printf '%s\n' '{"hooks":{"SessionStart":[]}}' > "$dir/hooks.json"
  fi
}
db_skill_row() { printf 'WARN codex_core_plugins::manifest session_loop{thread_id=%s}:built_tools: ignoring interface.defaultPrompt[0]: prompt must be at most 128 characters path=X/.codex-plugin/plugin.json\n' "$1"; }
db_noise_row() { printf 'INFO codex_core_skills::service session_loop{thread_id=%s}: skills cache cleared (0 entries)\n' "$1"; }

SMALL_WAW="<system-reminder>
_where-are-we

# Where are we

## In flight
(none)"

# check_rc <want> <got> <msg>  /  want_line <needle> <text> <msg>
check_rc()   { if [ "$2" -eq "$1" ]; then pass "$3"; else fail "$3 (got exit $2)"; fi; }
want_line()  { if grepq "$2" "$1"; then pass "$3"; else fail "$3 (out: $2)"; fi; }

# --- 1. healthy: current session, no warn rows, small where-are-we -> exit 0 ----
H="$(make_home healthy "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "healthy -> exit 0"
if [ -z "$out" ]; then pass "healthy -> no findings printed"; else fail "healthy printed: $out"; fi

# --- 2. hook-failure detected (scoped to current tid) -> exit 1 -----------------
H="$(make_home hookfail "$NEW_TID" "$SMALL_WAW")"
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "hook-failure -> exit 1"
want_line '^WARN hook-failure:' "$out" "hook-failure WARN line present"

# --- 2b. HIMMEL-1104: suggestion-scan noise must NOT fire -> exit 0 -------------
# The regression that made a session distrust its own guardrails (live 2026-07-16):
# the marketplace suggestion scan emits the identical "ignoring hooks" text, but
# discards the parsed hooks. Offending plugins present in the cache too, to prove
# it is the SPAN that gates the finding, not the cache contents.
H="$(make_home suggestnoise "$NEW_TID" "$SMALL_WAW")"
make_hooks "$H" "claude-plugins-official/hookify/local/hooks" desc
{ db_noise_row "$NEW_TID"; db_suggest_row "$NEW_TID"; db_suggest_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "suggestion-scan 'ignoring hooks' noise -> exit 0 (not a hook failure)"
if [ -z "$out" ]; then pass "suggestion-scan noise -> no findings printed"; else fail "suggestion noise printed: $out"; fi

# --- 2c. upstream candidate named, but NOT declared safe -> exit 1 --------------
# The log row carries no path, so a cache hit is a CANDIDATE, not proof. Naming an
# upstream candidate must NOT clear himmel's guardrails: himmel's own hooks could
# be failing for an unrelated reason while an upstream file merely happens to
# carry a `description`. Fail closed.
H="$(make_home upstreamoffender "$NEW_TID" "$SMALL_WAW")"
make_hooks "$H" "claude-plugins-official/ralph-loop/1.0.0/hooks" desc
make_hooks "$H" "himmel/himmel-ops/0.4.0/hooks" clean
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "upstream candidate -> exit 1"
want_line 'ralph-loop' "$out" "upstream candidate names the plugin path"
want_line 'NOT correlated' "$out" "upstream candidate is not correlated to the failure"
if grepq "$out" 'safe to route'; then
  fail "upstream candidate must NOT declare the lane safe to route (out: $out)"
else
  pass "upstream candidate does not declare the lane safe (fail-closed)"
fi

# --- 2e. cache unscannable -> offender unidentified, still fail-closed -> exit 1 -
# No plugins/cache at all: must report "could NOT be scanned", never assert that
# no file carries a `description` (a fact never checked).
H="$(make_home noscan "$NEW_TID" "$SMALL_WAW")"
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "unscannable cache -> exit 1"
want_line 'could NOT be scanned' "$out" "unscannable cache says so rather than asserting none found"

# --- 2h. case parity: a `Description` key is NOT the lowercase field ------------
# jq's has("description") and codex's serde field matching are both
# case-sensitive; the ps1 twin must use -ccontains to agree (plain -contains is
# case-INSENSITIVE and would flag this).
H="$(make_home casevariant "$NEW_TID" "$SMALL_WAW")"
mkdir -p "$H/plugins/cache/claude-plugins-official/casey/1.0.0/hooks"
printf '%s\n' '{"Description":"x","hooks":{"SessionStart":[]}}' > "$H/plugins/cache/claude-plugins-official/casey/1.0.0/hooks/hooks.json"
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "case-variant Description -> exit 1"
if grepq "$out" 'casey'; then
  fail "case-variant 'Description' must NOT be flagged as a description offender (out: $out)"
else
  pass "case-variant Description is not flagged (jq/serde case-sensitivity)"
fi

# --- 2f. unparseable hooks.json -> INCOMPLETE, never a clean "none found" -------
# A malformed hooks.json is exactly the shape codex rejects; judging it as
# "no description" would assert a fact never checked.
H="$(make_home badjson "$NEW_TID" "$SMALL_WAW")"
mkdir -p "$H/plugins/cache/himmel/himmel-ops/0.4.0/hooks"
printf '%s\n' '{"hooks":{ THIS IS NOT JSON' > "$H/plugins/cache/himmel/himmel-ops/0.4.0/hooks/hooks.json"
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "unparseable hooks.json -> exit 1"
want_line 'could NOT be scanned' "$out" "unparseable hooks.json marks the scan incomplete"

# --- 2g. incompleteness is surfaced ALONGSIDE a found candidate -----------------
# One good offender + one unparseable file: name the candidate AND admit the scan
# was incomplete (candidates may be missing).
H="$(make_home partial "$NEW_TID" "$SMALL_WAW")"
make_hooks "$H" "claude-plugins-official/ralph-loop/1.0.0/hooks" desc
mkdir -p "$H/plugins/cache/claude-plugins-official/broken/1.0.0/hooks"
printf '%s\n' '{ nope' > "$H/plugins/cache/claude-plugins-official/broken/1.0.0/hooks/hooks.json"
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "candidate + unparseable file -> exit 1"
want_line 'ralph-loop' "$out" "still names the found candidate"
want_line 'INCOMPLETE' "$out" "admits the scan was incomplete alongside the candidate"

# --- 2d. himmel-owned offender -> GUARDRAILS MAY BE OFF -> exit 1 ---------------
H="$(make_home himmeloffender "$NEW_TID" "$SMALL_WAW")"
make_hooks "$H" "himmel/himmel-ops/0.4.0/hooks" desc
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "himmel-owned offender -> exit 1"
want_line 'GUARDRAILS MAY BE OFF' "$out" "himmel offender escalates the finding"
want_line 'himmel-ops' "$out" "himmel offender names the plugin path"

# --- 3. skill-truncation detected -> exit 1 ------------------------------------
H="$(make_home skilltrunc "$NEW_TID" "$SMALL_WAW")"
{ db_skill_row "$NEW_TID"; db_skill_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "skill-truncation -> exit 1"
want_line '^WARN skill-truncation:.*2 skill' "$out" "skill-truncation counts 2"

# --- 4. session scoping: marker under an OLD tid must NOT fire -> exit 0 --------
# Newest session is NEW_TID (healthy); the DB carries hook+skill rows but only for
# the OLD tid (a since-fixed misconfig whose stale rows persist append-only).
H="$(make_home scoping "$NEW_TID" "$SMALL_WAW")"
# add an older session file so the dir has two; NEW_TID sorts later (newest).
mkdir -p "$H/sessions/2026/07/01"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count"}}' > "$H/sessions/2026/07/01/rollout-2026-07-01T00-00-00-$OLD_TID.jsonl"
{ db_hook_row "$OLD_TID"; db_skill_row "$OLD_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "stale-only markers (old tid) -> exit 0 (scoped out)"

# --- 5. oversized _where-are-we -> exit 1 --------------------------------------
BIG_WAW="<system-reminder>
# Where are we
$(printf 'x%.0s' $(seq 1 400))"
H="$(make_home bigwaw "$NEW_TID" "$BIG_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" WHERE_ARE_WE_BUDGET_BYTES=200 bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "oversized where-are-we -> exit 1"
want_line '^WARN where-are-we-oversized:' "$out" "where-are-we-oversized line present"
# same big block stays healthy under a generous budget (proves it is the size, not presence)
rc=0; out="$(CODEX_HOME="$H" WHERE_ARE_WE_BUDGET_BYTES=100000 bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "big block under generous budget -> exit 0"

# --- 8. HIMMEL-1145: himmel plugin registration is asserted PRESENT --------------
# Every check above reads what codex LOGGED. A codex that lost its plugin
# registration loads nothing, parses no manifest and logs nothing, so all of them
# read healthy while every himmel guardrail is absent. The current session below
# is otherwise perfectly clean (noise row only) — only config.toml differs.
# reg_case <name> <mode> [skip-plugin] -> sets $out / $rc
reg_case() {
  local h; h="$(make_home "$1" "$NEW_TID" "$SMALL_WAW")"
  db_noise_row "$NEW_TID" > "$h/logs_2.sqlite"
  write_config "$h" "$2" "${3:-}"
  rc=0; out="$(CODEX_HOME="$h" bash "$DETECT" 2>&1)" || rc=$?
}
reg_case regall all
check_rc 0 "$rc" "fully registered set -> exit 0"

# 8a. no config.toml at all -> the registration cannot be shown -> fail closed
H="$(make_home regnocfg "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"; rm -f "$H/config.toml"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "no config.toml -> exit 1"
want_line '^WARN plugin-unregistered:' "$out" "no config.toml -> plugin-unregistered finding"
want_line 'config.toml' "$out" "no config.toml names the missing file"

# 8b. total loss: no himmel marketplace, no himmel plugin
reg_case regempty empty
check_rc 1 "$rc" "total registration loss -> exit 1"
want_line '^WARN plugin-unregistered:' "$out" "total loss -> plugin-unregistered finding"
for p in $DEFAULT_PLUGINS; do want_line "$p@$MARKET" "$out" "total loss names $p@$MARKET"; done
want_line "marketplace '$MARKET'" "$out" "total loss names the missing marketplace"
want_line 'GUARDRAILS MAY BE OFF' "$out" "total loss escalates to GUARDRAILS MAY BE OFF"
want_line 'codex CLI' "$out" "finding names the surface (codex CLI)"
want_line 'claudex / cc-glm / hermes are separate surfaces' "$out" "finding scopes itself to the codex CLI"
if grepq "$out" 'luna-correlate'; then fail "the opt-in --all extras must NOT be required (out: $out)"; else pass "opt-in extras are not required"; fi

# 8c. marketplace gone, plugin tables still there -> nothing can load
reg_case regnomarket nomarket
check_rc 1 "$rc" "marketplace missing -> exit 1"
want_line "marketplace '$MARKET'" "$out" "marketplace missing is named"
want_line 'GUARDRAILS MAY BE OFF' "$out" "marketplace missing escalates"

# 8d. PARTIAL: the guardrail-carrying plugin disabled, the rest fine
reg_case regdisabled disable himmel-ops
check_rc 1 "$rc" "himmel-ops disabled -> exit 1"
want_line "himmel-ops@$MARKET" "$out" "disabled himmel-ops is named"
want_line 'GUARDRAILS MAY BE OFF' "$out" "himmel-ops missing escalates (it carries the hooks)"
if grepq "$out" "handover@$MARKET"; then fail "a plugin that IS enabled must not be named missing (out: $out)"; else pass "only the missing plugin is named (per-plugin, not all-or-nothing)"; fi

# 8e. PARTIAL: a non-guardrail plugin absent -> named, but no guardrails alarm
reg_case regpartial skip telegram-himmel
check_rc 1 "$rc" "telegram-himmel absent -> exit 1"
want_line "telegram-himmel@$MARKET" "$out" "absent telegram-himmel is named"
if grepq "$out" 'GUARDRAILS MAY BE OFF'; then fail "a lost non-guardrail plugin must not claim guardrails are off (out: $out)"; else pass "non-guardrail loss does not cry GUARDRAILS MAY BE OFF"; fi

# 8f. same plugin name under ANOTHER marketplace does not count
H="$(make_home regforeign "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
sed "s/\"himmel-ops@$MARKET\"/\"himmel-ops@other\"/" "$H/config.toml" > "$H/config.toml.new" && mv "$H/config.toml.new" "$H/config.toml"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "himmel-ops only under another marketplace -> exit 1"
want_line "himmel-ops@$MARKET" "$out" "foreign-marketplace himmel-ops does not satisfy the requirement"

# 8f2. a registration that only appears INSIDE a multiline string is not a
# registration (TOML `"""` and `'''` values carry arbitrary text, e.g. pasted
# instructions) — table headers and `enabled = true` there must not count.
mlno=0
for q in '"""' "'''"; do
  mlno=$((mlno + 1))
  reg_case "regml$mlno" skip himmel-ops
  printf 'note = %s\n[plugins."himmel-ops@%s"]\nenabled = true\n%s\n' "$q" "$MARKET" "$q" >> "$TMP/regml$mlno/config.toml"
  rc=0; out="$(CODEX_HOME="$TMP/regml$mlno" bash "$DETECT" 2>&1)" || rc=$?
  check_rc 1 "$rc" "himmel-ops registered only inside a $q string -> exit 1"
  want_line "himmel-ops@$MARKET" "$out" "himmel-ops inside a $q string is still reported missing"
done

# 8f3. parser fidelity (class sweep with 8f2): a comment mentioning a triple quote
# must not hide the registrations after it; whitespace INSIDE a quoted key is part
# of the key; a literal-quoted ('...') header is the same registration.
for cm in '# stray """ in a full-line comment' 'x = "a" # trailing """ comment'; do
  H="$(make_home regcomment "$NEW_TID" "$SMALL_WAW")"
  db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
  { printf '%s\n' "$cm"; cat "$H/config.toml"; } > "$H/config.toml.new" && mv "$H/config.toml.new" "$H/config.toml"
  rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
  check_rc 0 "$rc" "triple quotes inside a comment ($cm) do not hide later registrations -> exit 0"
done

H="$(make_home regspacekey "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
sed "s/\"himmel-ops@$MARKET\"/\"himmel- ops@$MARKET\"/" "$H/config.toml" > "$H/config.toml.new" && mv "$H/config.toml.new" "$H/config.toml"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "whitespace inside a quoted key is not stripped -> himmel-ops reported missing"
want_line "himmel-ops@$MARKET" "$out" "space-in-key does not satisfy himmel-ops"

H="$(make_home regliteral "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
sed "s/\"himmel-ops@$MARKET\"/'himmel-ops@$MARKET'/" "$H/config.toml" > "$H/config.toml.new" && mv "$H/config.toml.new" "$H/config.toml"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "literal-quoted header is the same registration -> exit 0"

# 8f4. HIMMEL-3234: a QUOTED key is ONE segment. A hand-written top-level
# ["plugins.himmel-ops@himmel"] / ["marketplaces.himmel"] is not the nested
# [plugins."himmel-ops@himmel"] / [marketplaces.himmel] registration, even though
# both used to normalise to the same dotted string. Quoting a SEGMENT
# (["plugins"."himmel-ops@himmel"]) is still the nested form and still counts.
reg_case regqdotplug skip himmel-ops
printf '["plugins.himmel-ops@%s"]\nenabled = true\n' "$MARKET" >> "$TMP/regqdotplug/config.toml"
rc=0; out="$(CODEX_HOME="$TMP/regqdotplug" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "quoted-dotted top-level plugin key is not a registration -> exit 1"
want_line "himmel-ops@$MARKET" "$out" "quoted-dotted plugin key still reports himmel-ops missing"

reg_case regqdotmkt nomarket
printf '["marketplaces.%s"]\nsource_type = "local"\n' "$MARKET" >> "$TMP/regqdotmkt/config.toml"
rc=0; out="$(CODEX_HOME="$TMP/regqdotmkt" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "quoted-dotted top-level marketplace key is not a registration -> exit 1"
want_line "marketplace '$MARKET' is not registered" "$out" "quoted-dotted marketplace key still reports the marketplace missing"

reg_case regqseg skip himmel-ops
printf '["plugins"."himmel-ops@%s"]\nenabled = true\n' "$MARKET" >> "$TMP/regqseg/config.toml"
rc=0; out="$(CODEX_HOME="$TMP/regqseg" bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "quoted segments around an unquoted dot are still the nested registration -> exit 0"

# 8g. no session at all (no sessions dir -> no thread_id): the registration check
# reads config only, so it must not depend on a session existing.
H="$TMP/regnosession"; mkdir -p "$H"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"; write_config "$H" empty
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "no session, lost registration -> exit 1"
want_line '^WARN plugin-unregistered:' "$out" "registration check does not depend on a session"

# 8h. the expected set is DERIVED from the data file, not restated in the detector
mkdir -p "$TMP/derive"
cp "$DETECT" "$TMP/derive/startup-health.sh"
printf 'marketplace: himmel\ndefault: zzz-only-plugin\nall-extra: x\n' > "$TMP/derive/himmel-plugin-set.conf"
H="$(make_home derived "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$TMP/derive/startup-health.sh" 2>&1)" || rc=$?
check_rc 1 "$rc" "custom data file: its plugin absent -> exit 1"
want_line 'zzz-only-plugin@himmel' "$out" "the finding names the plugin the DATA FILE requires"
if grepq "$out" 'himmel-ops'; then fail "detector still requires a plugin the data file does not list (out: $out)"; else pass "no second hardcoded copy of the plugin set"; fi
printf '[marketplaces.himmel]\nsource_type = "local"\n\n[plugins."zzz-only-plugin@himmel"]\nenabled = true\n' > "$H/config.toml"
rc=0; out="$(CODEX_HOME="$H" bash "$TMP/derive/startup-health.sh" 2>&1)" || rc=$?
check_rc 0 "$rc" "custom data file: its plugin present -> exit 0"

# 8i. data file unreadable -> cannot judge -> say so, never a silent pass
mkdir -p "$TMP/nodata"; cp "$DETECT" "$TMP/nodata/startup-health.sh"
H="$(make_home nodatafile "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$TMP/nodata/startup-health.sh" 2>&1)" || rc=$?
check_rc 1 "$rc" "data file missing -> exit 1 (fail closed)"
want_line '^WARN plugin-presence-unchecked:' "$out" "data file missing -> plugin-presence-unchecked, not a clean pass"

# --- 6. missing CODEX_HOME -> exit 2 -------------------------------------------
rc=0; out="$(CODEX_HOME="$TMP/nope/.codex" bash "$DETECT" 2>&1)" || rc=$?
check_rc 2 "$rc" "missing CODEX_HOME -> exit 2"

# --- 7. unknown arg -> exit 2 --------------------------------------------------
rc=0; CODEX_HOME="$H" bash "$DETECT" --bogus >/dev/null 2>&1 || rc=$?
check_rc 2 "$rc" "unknown arg -> exit 2"

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAIL ($fails)"; exit 1; fi
