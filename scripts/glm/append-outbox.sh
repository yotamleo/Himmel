#!/usr/bin/env bash
# Append one GLM worker progress note to its dispatcher-minted outbox (HIMMEL-1649).
#
# THIS IS THE OFF-LANE IMPLEMENTATION OF THE SAME PAYLOAD CONTRACT the
# block-glm-external-writes.sh hook enforces. On the GLM lane this file NEVER
# executes: the hook intercepts the report command, performs the decode +
# schema validation + append itself, and denies the Bash call. This copy exists
# for sessions where that hook is absent, and it must stay LOCKSTEP with the
# hook's schema — a divergence here means an off-lane worker writes records the
# adjudicator cannot read (which is exactly what an earlier revision did by
# hardcoding {text}, silently dropping every structured escalation).
#
# Usage: bash scripts/glm/append-outbox.sh <base64url>
# The payload is unpadded canonical base64url ([A-Za-z0-9_-]+), capped at
# 16384 encoded characters. GLM_SESSION_DIR supplies the destination; callers
# cannot name a path. Decoded text is passed to Node as data, never shell source.
#
# Schema (identical to the hook): the decoded payload is parsed as JSON. A plain
# JSON OBJECT must carry type note|escalation; an escalation requires string
# capability/arm/reason/step (ts optional, stamped when absent); unknown keys or
# non-string whitelisted fields fail closed with nothing appended. Anything that
# is not a JSON object — including a bare scalar — is wrapped verbatim as
# {"type":"note","text":<decoded>}. A CONSECUTIVE duplicate payload is
# suppressed via the record's _sig digest.
set -euo pipefail

MAX_PAYLOAD_CHARS=16384

fail() {
    echo "append-outbox: $1" >&2
    exit 2
}

[ "$#" -eq 1 ] || fail "expected exactly one base64url payload argument"
payload=$1
case "$payload" in
    ''|*[!A-Za-z0-9_-]*) fail "payload must contain only unpadded base64url characters [A-Za-z0-9_-]" ;;
esac
[ "${#payload}" -le "$MAX_PAYLOAD_CHARS" ] || fail "payload exceeds the $MAX_PAYLOAD_CHARS-character base64url cap"

# Keep these predicates lockstep with valid_glm_session_dir() in
# scripts/hooks/block-glm-external-writes.sh. They are duplicated deliberately:
# the reporting helper and the security hook each fail closed without depending
# on a sourced file whose lookup could fail differently across plugin installs.
path_norm() {
    printf '%s' "$1" | tr '\134' '/'
}

valid_glm_session_dir() {
    local sd base parent parent_base
    sd=$(path_norm "${GLM_SESSION_DIR:-}")
    sd=${sd%/}
    [ -n "$sd" ] || return 1
    case "$sd" in /*|[A-Za-z]:/*) ;; *) return 1 ;; esac
    case "/$sd/" in */../*|*/./*) return 1 ;; esac
    base=${sd##*/}
    parent=${sd%/*}
    parent_base=${parent##*/}
    [ "$parent_base" = "glm-sessions" ] || return 1
    case "$base" in glm-*) ;; *) return 1 ;; esac
    [ -d "$sd" ] || return 1
    [ ! -L "$sd" ] || return 1
    GLM_SESSION_REAL=$(cd "$sd" 2>/dev/null && pwd -P) || return 1
    [ -n "$GLM_SESSION_REAL" ] || return 1
    GLM_SESSION_NORM=$sd
}

valid_glm_session_dir || fail "GLM_SESSION_DIR is missing or is not a valid dispatcher-minted glm-sessions/glm-* directory"

# Node on Windows accepts C:/... paths, not Git Bash's /c/... spelling. Prefer
# pwd -W there; Unix bash lacks it, so fall back to the physical POSIX path.
session_node=$(cd "$GLM_SESSION_NORM" && pwd -W 2>/dev/null) || session_node="$GLM_SESSION_REAL"
outbox="$session_node/outbox.jsonl"
[ ! -L "$outbox" ] || fail "refusing symlink outbox.jsonl"

# shellcheck disable=SC2016  # fixed Node program is intentionally single-quoted shell data
exec node -e '
const fs = require("node:fs");
const payload = process.argv[1];
const outbox = process.argv[2];
let text;
try {
  if (payload.length % 4 === 1) throw new Error("invalid base64url length");
  const decoded = Buffer.from(payload, "base64url");
  if (decoded.toString("base64url") !== payload) throw new Error("non-canonical base64url");
  text = new TextDecoder("utf-8", { fatal: true }).decode(decoded);
} catch {
  console.error("append-outbox: payload decode failed");
  process.exit(2);
}
// Schema gate — LOCKSTEP with block-glm-external-writes.sh. Only a plain JSON
// object claims structure, so only an object faces the type gate; a bare scalar
// is a note.
let parsed = null;
let structured = false;
try {
  parsed = JSON.parse(text);
  structured = parsed !== null && typeof parsed === "object" && !Array.isArray(parsed);
} catch {
  structured = false;
}
let record;
if (structured) {
  const type = parsed.type;
  if (type !== "note" && type !== "escalation") {
    console.error("append-outbox: structured payload type must be note or escalation");
    process.exit(2);
  }
  const allowed = type === "escalation"
    ? ["type", "capability", "arm", "reason", "step", "ts"]
    : ["type", "text", "ts"];
  for (const key of Object.keys(parsed)) {
    if (!allowed.includes(key)) {
      console.error("append-outbox: unknown key in structured payload: " + key);
      process.exit(2);
    }
  }
  const required = type === "escalation"
    ? ["capability", "arm", "reason", "step"]
    : ["text"];
  for (const key of required) {
    if (typeof parsed[key] !== "string") {
      console.error("append-outbox: field must be a string: " + key);
      process.exit(2);
    }
  }
  if (parsed.ts !== undefined && typeof parsed.ts !== "string") {
    console.error("append-outbox: field must be a string: ts");
    process.exit(2);
  }
  record = parsed;
  if (typeof record.ts !== "string") record.ts = new Date().toISOString();
} else {
  record = { type: "note", text };
}
// Consecutive-duplicate suppression, same rule as the hook — including its
// documented v1 limits (adjudication-blind, unlocked; deferred to HIMMEL-1663).
const rawSig = require("node:crypto").createHash("sha256").update(text, "utf8").digest("hex");
let lastSig = null;
// Torn-tail boundary, lockstep with the hook (HIMMEL-1649 round 4): an
// interrupted earlier append leaves the file ending mid-line, and appending
// onto it would concatenate this record into that partial line — which
// consumers then skip entirely.
let torn = false;
try {
  const prior = fs.readFileSync(outbox, "utf8");
  torn = prior.length > 0 && !prior.endsWith("\n");
  const lines = prior.split("\n").filter((l) => l.trim() !== "");
  if (lines.length > 0) {
    try { lastSig = JSON.parse(lines[lines.length - 1])._sig ?? null; } catch { lastSig = null; }
  }
} catch { lastSig = null; }
if (lastSig !== null && lastSig === rawSig) process.exit(0);
record._sig = rawSig;
try {
  fs.appendFileSync(outbox, (torn ? "\n" : "") + JSON.stringify(record) + "\n", "utf8");
} catch (error) {
  console.error(`append-outbox: append failed: ${error.message}`);
  process.exit(2);
}
' -- "$payload" "$outbox"
