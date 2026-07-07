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
  -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# --- (a) skill/plugin prompt truncation  +  (b) lifecycle hook failure ----------
# Both live in logs_2.sqlite and both re-emit with the session thread_id embedded,
# so scope by $tid to the current session (avoids stale, since-fixed rows).
if [ -f "$LOGDB" ] && [ -n "$tid" ]; then
  runs="$(LC_ALL=C grep -aoE '[[:print:]]{20,}' "$LOGDB" 2>/dev/null | grep -F "$tid" 2>/dev/null || true)"
  hook_hits="$(printf '%s\n' "$runs" | grep -c 'ignoring hooks' 2>/dev/null || true)"
  skill_hits="$(printf '%s\n' "$runs" | grep -cE 'ignoring interface\.defaultPrompt|prompt must be at most|maximum of [0-9]+ prompts' 2>/dev/null || true)"
  hook_hits="${hook_hits//[^0-9]/}";  hook_hits="${hook_hits:-0}"
  skill_hits="${skill_hits//[^0-9]/}"; skill_hits="${skill_hits:-0}"
  [ "$hook_hits" -gt 0 ] && emit hook-failure \
    "codex ignored a lifecycle hooks block in the current session (codex_core_plugins::manifest 'ignoring hooks') — SessionStart/UserPromptSubmit/Stop hooks may not be running"
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
