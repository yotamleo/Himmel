#!/usr/bin/env bash
# startup-health.sh (HIMMEL-747) — surface a DEGRADED Codex CLI startup.
#
# When himmel routes work to the Codex lane, a codex session can start degraded
# in ways that leave the lane LOOKING healthy to the orchestrator: skills/plugin
# prompts silently truncated, lifecycle hooks silently ignored, or an oversized
# _where-are-we context injection. This read-only detector inspects the
# MOST-RECENT codex session's own logs and reports each signal it finds.
#
# GROUNDING (real ~/.codex on the author's Win11 box, 2026-07-07):
#  - Codex writes a tracing DB at $CODEX_HOME/logs_2.sqlite (table `logs`; cols
#    level / target / feedback_log_body). Startup + plugin-load warnings live
#    THERE, not in the per-session rollout .jsonl (whose event_msg payloads are
#    only token_count / agent_message / task_* — no warning event type). The
#    relevant rows are level=WARN, target=codex_core_plugins::manifest, and are
#    re-emitted per-turn INSIDE the session_loop span, so the session thread_id
#    is embedded in the message text. Verified example bodies:
#      * hook-failure     "...load_plugins_from_layer_stack: ignoring hooks:
#                          expected a string, string array, object, or object
#                          array; found object"
#        The SPAN PREFIX is load-bearing (HIMMEL-1104). The identical "ignoring
#        hooks: ..." text is emitted from a SECOND span:
#          "...list_tool_suggest_discoverable_plugins: ignoring hooks: ..."
#        which is codex enumerating NON-INSTALLED marketplace plugins to build
#        "you might want to install this" cards. It parses each manifest with the
#        same code (same text) but throws the hooks away, so it is pure noise —
#        matching the bare string reports a healthy session as DEGRADED.
#      * skill-truncation "ignoring interface.defaultPrompt: maximum of 3 prompts
#                          is supported path=...\.codex-plugin/plugin.json"  and
#                          "ignoring interface.defaultPrompt[0]: prompt must be at
#                          most 128 characters path=..."
#  - The _where-are-we injection is a rollout-jsonl string value that begins
#    "<system-reminder>\n_where-are-we ...\n\n# Where are we\n..." (a healthy one
#    is ~4 KiB; e.g. rollout-2026-07-07T11-56-16-...jsonl was 4138 bytes).
#
# logs_2.sqlite is read WITHOUT a sqlite dependency (mirroring the read-the-bytes
# approach of scripts/telegram/quota-gauge-codex.ts): sqlite stores TEXT inline
# as UTF-8, so printable-run extraction (grep -aoE) + a thread_id filter scopes
# matches to the MOST-RECENT session. That scoping matters: the DB is append-only,
# so a since-FIXED misconfig's stale rows persist forever; filtering by the newest
# session's thread_id means a fixed config stops firing on the next launch.
#
# Output: one `WARN <signal>: <detail>` line per finding, on stdout.
# Exit:   0 = healthy (no findings)   1 = finding(s)   2 = cannot read codex logs.
# Env:    CODEX_HOME (default ~/.codex)
#         WHERE_ARE_WE_BUDGET_BYTES (default 8192 — ~2x a normal ~4 KiB injection)
#
# NON-FATAL by contract: callers (himmel-doctor, scripts/lanes) must treat any
# failure as "no signal". Internal errors degrade to a clean exit, never a crash.
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "startup-health: unknown argument: $1" >&2; exit 2 ;;
esac

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
BUDGET="${WHERE_ARE_WE_BUDGET_BYTES:-8192}"
LOGDB="$CODEX_HOME/logs_2.sqlite"
SESSIONS="$CODEX_HOME/sessions"

# cannot-read: no codex logs at all under CODEX_HOME.
if [ ! -f "$LOGDB" ] && [ ! -d "$SESSIONS" ]; then
  echo "startup-health: no codex logs under $CODEX_HOME (logs_2.sqlite / sessions absent)" >&2
  exit 2
fi

findings=0
emit() { printf 'WARN %s: %s\n' "$1" "$2"; findings=$((findings + 1)); }

# Newest rollout session. Rollout filenames are ISO-timestamp-prefixed
# (rollout-2026-07-07T11-56-16-<uuid>.jsonl), so a lexical sort is chronological
# — no GNU-only `find -printf` / stat (keeps this portable to macOS find).
newest_jsonl=""
if [ -d "$SESSIONS" ]; then
  newest_jsonl="$(find "$SESSIONS" -name 'rollout-*.jsonl' -type f 2>/dev/null | sort | tail -1)"
fi
tid=""
if [ -n "$newest_jsonl" ]; then
  tid="$(basename "$newest_jsonl" | sed -nE 's/.*-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/\1/p')"
fi

# Name the codex plugin-cache hooks.json files carrying a root-level
# `description`. Deterministic JSON key test — no log parsing, no sqlite.
#
# These are CANDIDATES, never proof. codex's "ignoring hooks" row carries NO
# path (verified against real logs), so the failing manifest CANNOT be correlated
# to a cache file from the logs. A scan hit therefore never licenses declaring a
# lane safe: himmel's own hooks could be failing for an unrelated reason while an
# unrelated upstream file merely happens to carry a `description`. Every branch
# below fails CLOSED — the only asymmetry is that a himmel-owned hit escalates.
# ONE scan yields BOTH results, so status can never drift from contents:
#   desc_offenders — newline-separated paths carrying a root-level `description`
#   desc_scan      — ok | incomplete   ("incomplete" = at least one input could
#                    not be enumerated, read, or parsed)
# Anything the scan could not judge makes it INCOMPLETE — never a clean "none
# found". An unreadable or unparseable hooks.json is exactly the shape codex
# rejects, so silently skipping it would assert a fact never checked (the same
# bug class this ticket exists to fix).
scan_plugin_cache() {
  desc_offenders=""; desc_scan=ok
  local cache="$CODEX_HOME/plugins/cache" files f find_rc=0
  if [ ! -d "$cache" ] || ! command -v jq >/dev/null 2>&1; then
    desc_scan=incomplete; return 0
  fi
  files="$(find "$cache" -name hooks.json 2>/dev/null)" || find_rc=$?
  [ "$find_rc" -eq 0 ] || desc_scan=incomplete
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Unreadable, or not valid JSON -> cannot judge it. Mark incomplete, skip.
    if [ ! -r "$f" ] || ! jq empty "$f" >/dev/null 2>&1; then
      desc_scan=incomplete; continue
    fi
    jq -e 'has("description")' "$f" >/dev/null 2>&1 && desc_offenders="${desc_offenders}${f}
"
  done <<EOF
$files
EOF
}

# --- (a) skill/plugin prompt truncation  +  (b) lifecycle hook failure ----------
# Both live in logs_2.sqlite and both re-emit with the session thread_id embedded,
# so scope by $tid to the current session (avoids stale, since-fixed rows).
if [ -f "$LOGDB" ] && [ -n "$tid" ]; then
  runs="$(LC_ALL=C grep -aoE '[[:print:]]{20,}' "$LOGDB" 2>/dev/null | grep -F "$tid" 2>/dev/null || true)"
  # HIMMEL-1104: match the LOAD path only. codex emits the identical
  # "ignoring hooks: ..." text from two spans, and the span name immediately
  # precedes the message on the same row:
  #   load_plugins_from_layer_stack        -> the real hook-load path. REAL.
  #   list_tool_suggest_discoverable_plugins -> a marketplace SUGGESTION scan over
  #     NON-INSTALLED plugins; it parses each manifest with the same code (hence
  #     the same text) but DISCARDS the hooks (ToolSuggestDiscoverablePlugin has
  #     no hooks field). Says nothing about the active session's hooks.
  # Matching the bare string fired DEGRADED on pure suggestion noise and made a
  # session distrust its own guardrails (live 2026-07-16): on the box that hit
  # it, that session had 0 load-path rows and 22 suggestion-scan rows.
  hook_hits="$(printf '%s\n' "$runs" | grep -c 'load_plugins_from_layer_stack: ignoring hooks' 2>/dev/null || true)"
  skill_hits="$(printf '%s\n' "$runs" | grep -cE 'ignoring interface\.defaultPrompt|prompt must be at most|maximum of [0-9]+ prompts' 2>/dev/null || true)"
  hook_hits="${hook_hits//[^0-9]/}";  hook_hits="${hook_hits:-0}"
  skill_hits="${skill_hits//[^0-9]/}"; skill_hits="${skill_hits:-0}"
  if [ "$hook_hits" -gt 0 ]; then
    # Split by BLAST RADIUS — the distinction that decides whether a session may
    # dispatch to the codex CLI lane at all. A dropped hooks block is per-plugin
    # (per-FIELD) isolated: codex's loader loops with no early return, so one bad
    # manifest never collaterally drops another plugin's hooks (verified against
    # core-plugins/src/loader.rs; corroborated by one turn logging 3 separate
    # errors, i.e. it continued past the first two).
    scan_plugin_cache
    himmel_hit=""; upstream_hit=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel="${f##*/plugins/cache/}"
      case "$f" in
        */plugins/cache/himmel/*|*/plugins/cache/qmd/*) himmel_hit="$himmel_hit $rel" ;;
        *)                                              upstream_hit="$upstream_hit $rel" ;;
      esac
    done <<EOF
$desc_offenders
EOF
    scope_note="Scope: the codex CLI only — claudex / cc-glm / hermes are separate surfaces and are NOT implicated by this finding."
    upgrade_note="Most likely fix: upgrade codex to >= rust-v0.143.0, which accepts a root-level 'description' (upstream PR #30229)."
    scan_note=""
    [ "$desc_scan" = "ok" ] || scan_note=" NOTE: the cache scan was INCOMPLETE (a hooks.json could not be enumerated, read, or parsed — jq may be absent), so candidates may be missing."
    if [ -n "$himmel_hit" ]; then
      emit hook-failure \
        "codex CLI ($CODEX_HOME) dropped a lifecycle hooks block, and a HIMMEL-OWNED plugin carries the root-level 'description' that triggers it —${himmel_hit} — GUARDRAILS MAY BE OFF, do not route work to the codex CLI lane until fixed. $upgrade_note $scope_note$scan_note"
    elif [ -n "$upstream_hit" ]; then
      emit hook-failure \
        "codex CLI ($CODEX_HOME) dropped a lifecycle hooks block. Upstream cache candidate(s) carrying a root-level 'description':${upstream_hit}. The log row names NO path, so this is NOT correlated to the failing manifest — himmel's guardrails are NOT proven unaffected. Do not route to the codex CLI lane until ownership is confirmed. $upgrade_note $scope_note$scan_note"
    elif [ "$desc_scan" != "ok" ]; then
      emit hook-failure \
        "codex CLI ($CODEX_HOME) dropped a lifecycle hooks block (codex_core_plugins::manifest 'load_plugins_from_layer_stack: ignoring hooks'), and the plugin cache could NOT be scanned (jq absent, no cache dir, or an unreadable/unparseable hooks.json) — offender unidentified. Do not route to the codex CLI lane until confirmed. $scope_note"
    else
      emit hook-failure \
        "codex CLI ($CODEX_HOME) dropped a lifecycle hooks block (codex_core_plugins::manifest 'load_plugins_from_layer_stack: ignoring hooks'), but no plugin-cache hooks.json carries a root-level 'description' — cause unidentified, inspect $CODEX_HOME/plugins/cache/**/hooks.json by hand. Do not route to the codex CLI lane until confirmed. $scope_note"
    fi
  fi
  [ "$skill_hits" -gt 0 ] && emit skill-truncation \
    "codex truncated $skill_hits skill/plugin prompt field(s) in the current session (codex_core_plugins::manifest 'defaultPrompt ... at most N chars / maximum of N prompts') — skill content silently dropped"
fi

# --- (c) oversized _where-are-we context injection ------------------------------
# The injected block is a rollout-jsonl string value carrying the "# Where are we"
# header; flag when the largest such value exceeds the byte budget. jq is a hard
# dependency of the codex hook adapter's environment; if it is somehow absent we
# skip this signal rather than fail.
if [ -n "$newest_jsonl" ] && command -v jq >/dev/null 2>&1; then
  waw_bytes="$(jq -rn '[inputs | .. | strings | select(test("# Where are we")) | utf8bytelength] | max // 0' "$newest_jsonl" 2>/dev/null || echo 0)"
  waw_bytes="${waw_bytes//[^0-9]/}"; waw_bytes="${waw_bytes:-0}"
  if [ "$waw_bytes" -gt "$BUDGET" ]; then
    emit where-are-we-oversized \
      "the _where-are-we context injected into the most recent codex session is ${waw_bytes} bytes (budget ${BUDGET})"
  fi
fi

[ "$findings" -gt 0 ] && exit 1
exit 0
