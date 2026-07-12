#!/usr/bin/env bash
# resume-armed.sh — one-command fast-resume. Shells to the bun armed-session-track
# resolver and prints a "you stopped here / agreed continuation" summary.
# Read-only; never launches. HIMMEL-208.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(git -C "$HERE" rev-parse --show-toplevel)"
j=$(bun "$REPO/scripts/telegram/armed-session-track.ts" resolve)
# shellcheck disable=SC2016  # single-quoted body is JS passed to `bun -e`, not shell — no shell expansion intended
printf '%s' "$j" | bun -e '
const d = JSON.parse(await Bun.stdin.text());
const p = (...a) => console.log(...a);
if (!d.found) { p(`No resumable armed session found (source: ${d.source}).`); if (d.ticket) p(`  Last armed ticket: ${d.ticket}`); process.exit(0); }
p(`== Fast-resume (${d.source}) ==`);
if (d.ticket)   p(`Ticket:     ${d.ticket}`);
if (d.handover) p(`Handover:   ${d.handover}`);
p(`Transcript: ${d.transcript ?? ""}`);
p(`Started:    ${d.session_start ?? ""}`);
if (d.first_user)          p(`Resumed with: ${String(d.first_user).trim().slice(0,120)}`);
if (d.last_assistant_text) p(`Last said:    ${String(d.last_assistant_text).trim().slice(0,200)}`);
if (d.last_question) { p(`Stopped at question: ${d.last_question}`); if (d.last_answers) p(`Agreed answer(s):    ${String(d.last_answers).trim().slice(0,200)}`); p(`=> Continuation = the answered decision above.`); }
'
