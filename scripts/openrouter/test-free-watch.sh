#!/usr/bin/env bash
# Hermetic suite for scripts/openrouter/free-watch.sh (HIMMEL-846).
# No network: catalog + endpoints come from fixtures; state dir is a temp dir.
# The suite is the spec: free-only filter, snapshot diff, pin flags, suggestions.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$DIR/free-watch.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
expect() { # $1=label $2=haystack-file $3=needle
  grep -qF "$3" "$2" || { echo "FAIL $1: missing '$3'"; fail=1; }
}
refute() { # $1=label $2=haystack-file $3=needle
  if grep -qF "$3" "$2"; then echo "FAIL $1: unexpected '$3'"; fail=1; fi
}

mk_catalog() { # $1=outfile, rest = "id ctx name" triples via stdin
  local rows="[]"
  while read -r id ctx name; do
    [ -n "$id" ] || continue
    rows="$(jq --arg id "$id" --argjson ctx "$ctx" --arg name "$name" \
      '. + [{id: $id, name: $name, context_length: $ctx}]' <<<"$rows")"
  done
  jq -n --argjson d "$rows" '{data: $d}' > "$1"
}

# Registry fixture: one openrouter row (pin + fallback) + a non-openrouter row.
cat > "$TMP/registry.json" <<'EOF'
{"panel":[
  {"slug":"qwenor","model":"qwen/qwen3-coder:free","provider":"openrouter","tier":"free",
   "fallback_models":["qwen/qwen3-next-80b-a3b-instruct:free"]},
  {"slug":"codex","model":"gpt-5.5","provider":"openai-codex","tier":"paid"}
]}
EOF

# Endpoints fixtures (filename: id with / and : -> _).
EPD="$TMP/endpoints"; mkdir -p "$EPD"
cat > "$EPD/qwen_qwen3-coder_free.json" <<'EOF'
{"data":{"endpoints":[{"name":"Venice","status":0,"uptime_last_30m":null}]}}
EOF
cat > "$EPD/qwen_qwen3-next-80b-a3b-instruct_free.json" <<'EOF'
{"data":{"endpoints":[{"name":"Venice","status":0,"uptime_last_30m":99.2}]}}
EOF

mk_catalog "$TMP/catalog1.json" <<'EOF'
qwen/qwen3-coder:free 262000 Qwen3 Coder (free)
qwen/qwen3-next-80b-a3b-instruct:free 262144 Qwen3 Next (free)
openai/gpt-5.5 400000 GPT-5.5 paid coder
EOF

run() { # $1=catalog $2=extra-args... ; output -> $TMP/out
  local cat="$1"; shift
  bash "$SUT" --catalog-file "$cat" --endpoints-dir "$EPD" \
    --state-dir "$TMP/state" --registry "$TMP/registry.json" "$@" \
    > "$TMP/out" 2>&1 || { echo "FAIL: run rc=$? for $cat"; fail=1; }
}

# T1 first run: paid ids filtered out of the catalog count; snapshot created;
# healthy pins produce no flags; no suggestion (nothing beats pinned ctx).
run "$TMP/catalog1.json"
expect T1-count   "$TMP/out" "catalog has 2 ':free' models"
expect T1-first   "$TMP/out" "first run - snapshot created"
refute T1-noflag  "$TMP/out" "FLAG"
refute T1-nosug   "$TMP/out" "SUGGEST"
refute T1-nopaid  "$TMP/out" "gpt-5.5"
[ -f "$TMP/state/openrouter-free-catalog.json" ] || { echo "FAIL T1: no snapshot"; fail=1; }

# T2 second run, catalog changed: pinned fallback delisted; a new bigger-ctx
# code model appears -> new-model flag + delisted flags + suggestion (:free only).
mk_catalog "$TMP/catalog2.json" <<'EOF'
qwen/qwen3-coder:free 262000 Qwen3 Coder (free)
cohere/north-mini-code:free 512000 North Mini Code (free)
EOF
run "$TMP/catalog2.json"
expect T2-new     "$TMP/out" "FLAG new-free-model: cohere/north-mini-code:free"
expect T2-gone    "$TMP/out" "FLAG delisted-free-model: qwen/qwen3-next-80b-a3b-instruct:free"
expect T2-pin     "$TMP/out" "FLAG delisted-pin: qwen/qwen3-next-80b-a3b-instruct:free"
expect T2-suggest "$TMP/out" "SUGGEST qwenor-candidate: cohere/north-mini-code:free"

# T3 deranked + uptime-drop: both endpoint degradations flagged.
cat > "$EPD/qwen_qwen3-coder_free.json" <<'EOF'
{"data":{"endpoints":[{"name":"Venice","status":-3,"uptime_last_30m":42.5}]}}
EOF
run "$TMP/catalog2.json"
expect T3-derank  "$TMP/out" "FLAG deranked-pin: qwen/qwen3-coder:free"
expect T3-uptime  "$TMP/out" "FLAG uptime-drop: qwen/qwen3-coder:free"

# T4 missing endpoints fixture = probe failure flag (not a crash).
rm "$EPD/qwen_qwen3-coder_free.json"
run "$TMP/catalog2.json"
expect T4-probe   "$TMP/out" "FLAG probe-failed: qwen/qwen3-coder:free"

# T5 non-free pin violates policy -> flagged, never probed/suggested as-is.
cat > "$TMP/registry.json" <<'EOF'
{"panel":[{"slug":"qwenor","model":"qwen/qwen3-coder-plus","provider":"openrouter","tier":"free"}]}
EOF
run "$TMP/catalog2.json"
expect T5-policy  "$TMP/out" "FLAG non-free-pin: qwen/qwen3-coder-plus"

# T6 --no-probe skips endpoint checks but keeps catalog diff + policy checks.
cat > "$TMP/registry.json" <<'EOF'
{"panel":[{"slug":"qwenor","model":"qwen/qwen3-coder:free","provider":"openrouter","tier":"free"}]}
EOF
run "$TMP/catalog2.json" --no-probe
refute T6-noprobe "$TMP/out" "FLAG probe-failed"

# T7 unreadable catalog -> rc 1.
echo "not json" > "$TMP/bad.json"
if bash "$SUT" --catalog-file "$TMP/bad.json" --state-dir "$TMP/state" \
     --registry "$TMP/registry.json" >/dev/null 2>&1; then
  echo "FAIL T7: bad catalog should rc 1"; fail=1
fi

# T8 malformed registry -> rc 1 AND the previous snapshot survives (the churn
# diff is not lost by a failed run - codex-adv finding, ordering regression).
cp "$TMP/state/openrouter-free-catalog.json" "$TMP/snap-before.json"
echo "not json" > "$TMP/badreg.json"
if bash "$SUT" --catalog-file "$TMP/catalog1.json" --state-dir "$TMP/state" \
     --registry "$TMP/badreg.json" >/dev/null 2>&1; then
  echo "FAIL T8: bad registry should rc 1"; fail=1
fi
if ! diff -q "$TMP/snap-before.json" "$TMP/state/openrouter-free-catalog.json" >/dev/null; then
  echo "FAIL T8: snapshot was replaced despite registry parse failure"; fail=1
fi

# T8.5 partial derank: one endpoint down, one healthy -> partial flag (codex-adv
# round-2 finding: redundancy loss must not read as healthy).
cat > "$TMP/registry.json" <<'EOF'
{"panel":[{"slug":"qwenor","model":"qwen/qwen3-coder:free","provider":"openrouter","tier":"free"}]}
EOF
cat > "$EPD/qwen_qwen3-coder_free.json" <<'EOF'
{"data":{"endpoints":[{"name":"A","status":-1,"uptime_last_30m":null},{"name":"B","status":0,"uptime_last_30m":99.0}]}}
EOF
run "$TMP/catalog2.json"
expect T85-partial "$TMP/out" "FLAG deranked-pin-partial: qwen/qwen3-coder:free (1 of 2"
refute T85-notall  "$TMP/out" "FLAG deranked-pin: qwen/qwen3-coder:free (all"

# T9 OpenRouter fallback on a NON-openrouter row (legacy singular
# fallback_model) is still watched - critic-panel fallback-semantics parity
# (HIMMEL-729 exhaustion path); the alibaba primary (no /) is NOT policy-flagged.
cat > "$TMP/registry.json" <<'EOF'
{"panel":[{"slug":"qwen3coder","model":"qwen3-coder-plus","provider":"alibaba-coding-plan","tier":"free",
  "fallback_model":"qwen/qwen3-next-80b-a3b-instruct:free"}]}
EOF
run "$TMP/catalog2.json" --no-probe
expect T9-fbpin   "$TMP/out" "FLAG delisted-pin: qwen/qwen3-next-80b-a3b-instruct:free"
refute T9-primary "$TMP/out" "FLAG non-free-pin: qwen3-coder-plus"

# T10 corrupted previous snapshot degrades to first-run (rc 0, snapshot healed)
# instead of wedging every later run (silent-failure-hunter Critical 1).
cat > "$TMP/registry.json" <<'EOF'
{"panel":[{"slug":"qwenor","model":"qwen/qwen3-coder:free","provider":"openrouter","tier":"free"}]}
EOF
cat > "$EPD/qwen_qwen3-coder_free.json" <<'EOF'
{"data":{"endpoints":[{"name":"Venice","status":0,"uptime_last_30m":null}]}}
EOF
echo "not json" > "$TMP/state/openrouter-free-catalog.json"
run "$TMP/catalog2.json"
expect T10-degrade "$TMP/out" "previous snapshot unreadable"
expect T10-first   "$TMP/out" "first run - snapshot created"
jq -e 'type == "array"' "$TMP/state/openrouter-free-catalog.json" >/dev/null 2>&1 \
  || { echo "FAIL T10: snapshot not healed"; fail=1; }

# T11 non-numeric OPENROUTER_UPTIME_MIN -> friendly rc 1 at startup, not a
# mid-loop jq crash that skips pin checks (silent-failure-hunter Critical 2).
if OPENROUTER_UPTIME_MIN=abc bash "$SUT" --catalog-file "$TMP/catalog2.json" \
     --state-dir "$TMP/state" --registry "$TMP/registry.json" > "$TMP/out" 2>&1; then
  echo "FAIL T11: non-numeric uptime min should rc 1"; fail=1
fi
expect T11-msg "$TMP/out" "OPENROUTER_UPTIME_MIN must be numeric"

# T12 threshold override honored: 42.5% uptime flags at the default 90 but not
# at 30 (also covers the pr-test-analyzer env-override gap).
cat > "$EPD/qwen_qwen3-coder_free.json" <<'EOF'
{"data":{"endpoints":[{"name":"Venice","status":0,"uptime_last_30m":42.5}]}}
EOF
run "$TMP/catalog2.json"
expect T12-default "$TMP/out" "FLAG uptime-drop: qwen/qwen3-coder:free"
OPENROUTER_UPTIME_MIN=30 bash "$SUT" --catalog-file "$TMP/catalog2.json" \
  --endpoints-dir "$EPD" --state-dir "$TMP/state" --registry "$TMP/registry.json" \
  > "$TMP/out" 2>&1 || { echo "FAIL T12: rc"; fail=1; }
refute T12-lower "$TMP/out" "FLAG uptime-drop"

# T13 zero live endpoints -> its own flag (pr-test-analyzer gap 1).
cat > "$EPD/qwen_qwen3-coder_free.json" <<'EOF'
{"data":{"endpoints":[]}}
EOF
run "$TMP/catalog2.json"
expect T13-none "$TMP/out" "FLAG no-endpoints: qwen/qwen3-coder:free"

# T14 suggestion heuristic: a bigger-context NON-code model is never suggested,
# and substring hits like "Unicode" don't count (code-reviewer + test-analyzer).
mk_catalog "$TMP/catalog3.json" <<'EOF'
qwen/qwen3-coder:free 262000 Qwen3 Coder (free)
acme/big-general:free 999999 Acme General (free)
acme/unicode-9b:free 999999 Unicode 9B (free)
EOF
cat > "$EPD/qwen_qwen3-coder_free.json" <<'EOF'
{"data":{"endpoints":[{"name":"Venice","status":0,"uptime_last_30m":null}]}}
EOF
run "$TMP/catalog3.json"
refute T14-nonsug "$TMP/out" "SUGGEST qwenor-candidate: acme/big-general:free"
refute T14-substr "$TMP/out" "SUGGEST qwenor-candidate: acme/unicode-9b:free"

# T15 registry path that does not exist -> friendly rc 1 (distinct from T8's
# exists-but-malformed path).
if bash "$SUT" --catalog-file "$TMP/catalog2.json" --state-dir "$TMP/state" \
     --registry "$TMP/nope.json" > "$TMP/out" 2>&1; then
  echo "FAIL T15: missing registry should rc 1"; fail=1
fi
expect T15-msg "$TMP/out" "registry not found"

# T16 CRITICS_JSON env tier: with no --registry, the env-named registry is
# scanned (critic-panel.sh precedence parity - codex-adv round-3 finding).
cat > "$TMP/envreg.json" <<'EOF'
{"panel":[{"slug":"qwenor","model":"qwen/gone-model:free","provider":"openrouter","tier":"free"}]}
EOF
CRITICS_JSON="$TMP/envreg.json" bash "$SUT" --catalog-file "$TMP/catalog2.json" \
  --endpoints-dir "$EPD" --state-dir "$TMP/state" --no-probe \
  > "$TMP/out" 2>&1 || { echo "FAIL T16: rc"; fail=1; }
expect T16-env "$TMP/out" "FLAG delisted-pin: qwen/gone-model:free"

# T17 dot-edge uptime values are invalid JSON numbers -> rejected at startup.
for v in . .5 5.; do
  if OPENROUTER_UPTIME_MIN="$v" bash "$SUT" --catalog-file "$TMP/catalog2.json" \
       --state-dir "$TMP/state" --registry "$TMP/registry.json" > "$TMP/out" 2>&1; then
    echo "FAIL T17: OPENROUTER_UPTIME_MIN='$v' should rc 1"; fail=1
  fi
  expect "T17-$v" "$TMP/out" "OPENROUTER_UPTIME_MIN must be numeric"
done

# T18 value-taking flag with no value -> friendly rc 1, not a set -u crash.
if bash "$SUT" --registry > "$TMP/out" 2>&1; then
  echo "FAIL T18: --registry with no value should rc 1"; fail=1
fi
expect T18-msg "$TMP/out" "requires a value"

[ "$fail" -eq 0 ] && echo "PASS test-free-watch" || exit 1
