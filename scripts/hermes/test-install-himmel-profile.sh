#!/usr/bin/env bash
# Hermetic tests for install-himmel-profile.sh (HIMMEL-557).
# No real hermes install needed: a stub CLI simulates `profile list/create`
# and HERMES_HOME points at a throwaway temp tree. Asserts the provisioner is
# additive (only himmel_agent gets the main-tier SOUL + parity_guard) and that
# --parity-guard is non-destructive (swap-only; never clobbers existing hooks).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-himmel-profile.sh"
SYNC_SCRIPT="$SCRIPT_DIR/assets/sync_model_aliases.py"

PYBIN="$(command -v python3 || command -v python)" || {
  echo "SKIP: no python available" >&2; exit 0; }

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
assert_contains() { if grep -qF "$2" "$1"; then pass "$3"; else fail "$3 (missing '$2' in $1)"; fi; }
assert_absent()   { if grep -qF "$2" "$1"; then fail "$3 (unexpected '$2' in $1)"; else pass "$3"; fi; }
assert_file()     { if [ -f "$1" ]; then pass "$2"; else fail "$2 (no file $1)"; fi; }

# --- build a throwaway hermes home + stub CLI --------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/hermes"
mkdir -p "$HOME_DIR/agent-hooks" "$HOME_DIR/profiles"

# a stub `hermes` CLI: profile list / profile create --clone-from default
STUB="$TMP/hermes-stub.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
H="${HERMES_HOME:?}"
if [ "${1:-}" = "profile" ] && [ "${2:-}" = "list" ]; then
  echo "default"
  [ -d "$H/profiles" ] && for d in "$H"/profiles/*/; do
    [ -d "$d" ] && basename "$d"
  done
  exit 0
fi
if [ "${1:-}" = "profile" ] && [ "${2:-}" = "create" ]; then
  name="$3"
  mkdir -p "$H/profiles/$name"
  cp "$H/config.yaml" "$H/profiles/$name/config.yaml"
  cp "$H/SOUL.md" "$H/profiles/$name/SOUL.md"
  exit 0
fi
exit 0
STUB_EOF
chmod +x "$STUB"

seed_default() {  # $1 = hooks-block style: "guard" | "empty"
  cat > "$HOME_DIR/SOUL.md" <<'EOF'
# Hermes Agent Persona
You are the low-risk junior reviewer. (user's own default — must stay untouched)
EOF
  {
    echo "model:"
    echo "  default: gpt-5.5"
    if [ "$1" = "guard" ]; then
      echo "hooks:"
      echo "  pre_tool_call:"
      echo "  - matcher: write_file|patch|terminal"
      echo "    command: '\"$PYBIN\" \"$HOME_DIR/agent-hooks/luna_vault_guard.py\"'"
      echo "    timeout: 10"
    else
      echo "hooks: {}"
    fi
    echo "security:"
    echo "  redact_secrets: true"
  } > "$HOME_DIR/config.yaml"
}

run() { HERMES_HOME="$HOME_DIR" HERMES_BIN="$STUB" HERMES_PY="$PYBIN" \
        bash "$INSTALLER" "$@"; }

echo "== scenario A: fresh default (no guard) -> himmel_agent gets parity_guard =="
seed_default empty
run >/dev/null
assert_file    "$HOME_DIR/agent-hooks/parity_guard.py" "guard asset installed"
assert_contains "$HOME_DIR/profiles/himmel_agent/SOUL.md" "main tier" "himmel_agent has main-tier SOUL"
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "himmel_agent wired to parity_guard"
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "pre_tool_call" "himmel_agent hook block present"
assert_contains "$HOME_DIR/SOUL.md" "junior reviewer" "user default SOUL untouched"

echo "== scenario B: idempotent re-run =="
run >/dev/null
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "still wired after re-run"
# exactly one pre_tool_call entry (no duplication)
n="$(grep -c "pre_tool_call" "$HOME_DIR/profiles/himmel_agent/config.yaml" || true)"
if [ "$n" = "1" ]; then pass "no hook duplication"; else fail "hook duplicated ($n pre_tool_call)"; fi

echo "== scenario C: default had luna_vault_guard -> himmel_agent still parity =="
rm -rf "$HOME_DIR/profiles"; mkdir -p "$HOME_DIR/profiles"
seed_default guard
run >/dev/null
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "cloned-guard config replaced with parity"
assert_absent   "$HOME_DIR/profiles/himmel_agent/config.yaml" "luna_vault_guard.py" "luna_vault_guard removed from himmel_agent"

echo "== scenario D: --parity-guard=default swaps default's guard (non-destructive) =="
run --parity-guard=default >/dev/null
assert_contains "$HOME_DIR/config.yaml" "parity_guard.py" "default swapped to parity_guard"
assert_absent   "$HOME_DIR/config.yaml" "luna_vault_guard.py" "default no longer references luna_vault_guard"

echo "== scenario E: --parity-guard on a guard-less profile now ADDS the guard (HIMMEL-744) =="
mkdir -p "$HOME_DIR/profiles/research"
printf 'model:\n  default: gpt-5.5\nhooks: {}\n' > "$HOME_DIR/profiles/research/config.yaml"
run --parity-guard=research >/dev/null
assert_contains "$HOME_DIR/profiles/research/config.yaml" "parity_guard.py" "guard-less named profile now guarded (ensure adds)"

echo "== scenario F: default (no flag) wires parity_guard into ALL profiles (universal) =="
rm -rf "$HOME_DIR/profiles"; mkdir -p "$HOME_DIR/profiles"
seed_default empty
# a guard-less profile carrying an UNRELATED hook that must survive
mkdir -p "$HOME_DIR/profiles/research"
printf 'model:\n  default: gpt-5.5\nhooks:\n  post_tool_call:\n  - command: /x/logger.py\n    timeout: 5\n' > "$HOME_DIR/profiles/research/config.yaml"
# a profile still on the legacy luna_vault_guard
mkdir -p "$HOME_DIR/profiles/legacy"
printf 'hooks:\n  pre_tool_call:\n  - command: /x/agent-hooks/luna_vault_guard.py\n    timeout: 10\n' > "$HOME_DIR/profiles/legacy/config.yaml"
run >/dev/null
# himmel_agent still owns its whole hooks block (set-mode canonical, mcp__ matcher)
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "himmel_agent wired (set)"
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "mcp__" "himmel_agent canonical matcher (set-mode)"
# default profile guarded by default
assert_contains "$HOME_DIR/config.yaml" "parity_guard.py" "default profile guarded (universal)"
# guard-less profile now guarded, unrelated hook preserved
assert_contains "$HOME_DIR/profiles/research/config.yaml" "parity_guard.py" "guard-less profile now guarded (universal)"
assert_contains "$HOME_DIR/profiles/research/config.yaml" "post_tool_call" "unrelated hook preserved"
assert_contains "$HOME_DIR/profiles/research/config.yaml" "logger.py" "unrelated hook command preserved"
# legacy luna_vault_guard swapped in place
assert_contains "$HOME_DIR/profiles/legacy/config.yaml" "parity_guard.py" "legacy profile swapped to parity"
assert_absent   "$HOME_DIR/profiles/legacy/config.yaml" "luna_vault_guard.py" "legacy luna_vault_guard removed"

echo "== model_aliases sync (HIMMEL-737): sync_model_aliases.py direct =="
MA_TMP="$TMP/model_aliases"
mkdir -p "$MA_TMP"

# (a) root has model_aliases, profile lacks it -> appended
cat > "$MA_TMP/root_with.yaml" <<'EOF'
model:
  default: gpt-5.5
model_aliases:
  qwen-plus:
    model: qwen-plus
    provider: alibaba-coding-plan
EOF
cat > "$MA_TMP/profile_none.yaml" <<'EOF'
model:
  default: gpt-5.5
hooks: {}
EOF
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_none.yaml" >/dev/null
assert_contains "$MA_TMP/profile_none.yaml" "model_aliases:" "(a) block appended when profile lacks it"
assert_contains "$MA_TMP/profile_none.yaml" "qwen-plus" "(a) alias content copied"

# (b) profile has a stale model_aliases block -> replaced by root's
cat > "$MA_TMP/profile_stale.yaml" <<'EOF'
model:
  default: gpt-5.5
model_aliases:
  qwen-plus:
    model: STALE-VALUE
hooks: {}
EOF
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_stale.yaml" >/dev/null
assert_absent   "$MA_TMP/profile_stale.yaml" "STALE-VALUE" "(b) stale alias value replaced"
assert_contains "$MA_TMP/profile_stale.yaml" "alibaba-coding-plan" "(b) root's alias content now present"
assert_contains "$MA_TMP/profile_stale.yaml" "hooks: {}" "(b) rest of profile preserved"

# (c) root lacks model_aliases -> SKIP printed, profile untouched
cat > "$MA_TMP/root_without.yaml" <<'EOF'
model:
  default: gpt-5.5
EOF
cat > "$MA_TMP/profile_c.yaml" <<'EOF'
model:
  default: gpt-5.5
hooks: {}
EOF
cp "$MA_TMP/profile_c.yaml" "$MA_TMP/profile_c.before"
out="$("$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_without.yaml" "$MA_TMP/profile_c.yaml")"
case "$out" in
  SKIP*"no model_aliases block") pass "(c) SKIP printed when root lacks model_aliases" ;;
  *) fail "(c) SKIP not printed (got: $out)" ;;
esac
if diff -q "$MA_TMP/profile_c.before" "$MA_TMP/profile_c.yaml" >/dev/null; then
  pass "(c) profile untouched when root lacks model_aliases"
else
  fail "(c) profile was modified despite root lacking model_aliases"
fi

# (d) idempotence: re-running on an already-synced profile changes nothing
cp "$MA_TMP/profile_none.yaml" "$MA_TMP/profile_none.once"
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_none.yaml" >/dev/null
if diff -q "$MA_TMP/profile_none.once" "$MA_TMP/profile_none.yaml" >/dev/null; then
  pass "(d) idempotent re-run produces identical profile"
else
  fail "(d) re-run changed an already-synced profile"
fi

# (g) column-0 full-line comment INSIDE the block does not truncate the copy
cat > "$MA_TMP/root_comment.yaml" <<'EOF'
model_aliases:
  qwen-plus:
    provider: alibaba-coding-plan
# CR tier below
  qwen3-coder-plus:
    provider: alibaba-coding-plan
security:
  level: high
EOF
cat > "$MA_TMP/profile_g.yaml" <<'EOF'
model:
  default: gpt-5.5
EOF
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_comment.yaml" "$MA_TMP/profile_g.yaml" >/dev/null
assert_contains "$MA_TMP/profile_g.yaml" "qwen3-coder-plus" "(g) alias after column-0 comment synced (not truncated)"
assert_absent   "$MA_TMP/profile_g.yaml" "security:" "(g) next top-level key still terminates the block"

# (e) root block at literal EOF with NO trailing newline -> replace stays well-formed
#     (guards the newline-pad branches; without them writelines glues lines)
printf 'model:\n  default: gpt-5.5\nmodel_aliases:\n  qwen-plus:\n    provider: alibaba-coding-plan' > "$MA_TMP/root_noeol.yaml"
cat > "$MA_TMP/profile_e.yaml" <<'EOF'
model_aliases:
  qwen-plus:
    provider: STALE
hooks: {}
EOF
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_noeol.yaml" "$MA_TMP/profile_e.yaml" >/dev/null
assert_contains "$MA_TMP/profile_e.yaml" "alibaba-coding-plan" "(e) no-eol root block synced"
if grep -q "alibaba-coding-planhooks" "$MA_TMP/profile_e.yaml"; then
  fail "(e) lines glued: newline pad on the root block regressed"
else
  pass "(e) block boundary intact after no-eol root sync"
fi

# (f) profile with NO trailing newline + no model_aliases -> append stays well-formed
printf 'model:\n  default: gpt-5.5\nhooks: {}' > "$MA_TMP/profile_f.yaml"
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_f.yaml" >/dev/null
assert_contains "$MA_TMP/profile_f.yaml" "model_aliases:" "(f) block appended to no-eol profile"
if grep -q "hooks: {}model_aliases" "$MA_TMP/profile_f.yaml"; then
  fail "(f) lines glued: newline pad on the profile tail regressed"
else
  pass "(f) append boundary intact on no-eol profile"
fi

# (h) profile has root aliases (stale) + a profile-only alias -> merge:
#     root values refreshed, profile-only alias preserved, preserved-line printed
cat > "$MA_TMP/profile_h.yaml" <<'EOF'
model:
  default: gpt-5.5
model_aliases:
  qwen-plus:
    model: STALE-VALUE
  my-local:
    model: my-local-model
    provider: custom
hooks: {}
EOF
out="$("$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_h.yaml")"
assert_absent   "$MA_TMP/profile_h.yaml" "STALE-VALUE" "(h) root-shared alias value refreshed"
assert_contains "$MA_TMP/profile_h.yaml" "alibaba-coding-plan" "(h) root's alias content now present"
assert_contains "$MA_TMP/profile_h.yaml" "my-local:" "(h) profile-only alias preserved"
assert_contains "$MA_TMP/profile_h.yaml" "provider: custom" "(h) profile-only sub-block intact"
case "$out" in
  *"preserved profile-only aliases: my-local"*) pass "(h) preserved-line printed" ;;
  *) fail "(h) preserved-line missing (got: $out)" ;;
esac

# (i) idempotence of the MERGED result: second run byte-identical
cp "$MA_TMP/profile_h.yaml" "$MA_TMP/profile_h.once"
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_h.yaml" >/dev/null
if diff -q "$MA_TMP/profile_h.once" "$MA_TMP/profile_h.yaml" >/dev/null; then
  pass "(i) merged result idempotent (second run byte-identical)"
else
  fail "(i) re-run changed an already-merged profile"
fi

# (j) merge ordering: root keys first, then preserved profile-only keys
r_ln="$(grep -n '^  qwen-plus:' "$MA_TMP/profile_h.yaml" | head -1 | cut -d: -f1)"
p_ln="$(grep -n '^  my-local:' "$MA_TMP/profile_h.yaml" | head -1 | cut -d: -f1)"
if [ -n "$r_ln" ] && [ -n "$p_ln" ] && [ "$r_ln" -lt "$p_ln" ]; then
  pass "(j) root keys precede preserved profile-only keys"
else
  fail "(j) merge ordering wrong (root at line ${r_ln:-?}, profile-only at line ${p_ln:-?})"
fi

# (k) profile-only alias with a slash+colon key (openrouter-style) survives a merge
#     (codex CR round 3: the narrow key matcher attached it to the previous entry)
cat > "$MA_TMP/profile_k.yaml" <<'EOF'
model:
  default: gpt-5.5
model_aliases:
  qwen-plus:
    model: STALE-VALUE
  qwen/qwen3-next-80b-a3b-instruct:free:
    provider: openrouter
hooks: {}
EOF
out="$("$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_k.yaml")"
assert_contains "$MA_TMP/profile_k.yaml" "qwen/qwen3-next-80b-a3b-instruct:free:" "(k) slash+colon profile-only key preserved"
assert_contains "$MA_TMP/profile_k.yaml" "provider: openrouter" "(k) its sub-block intact"
assert_absent   "$MA_TMP/profile_k.yaml" "STALE-VALUE" "(k) root-shared key still refreshed"
case "$out" in
  *"preserved profile-only aliases: qwen/qwen3-next-80b-a3b-instruct:free"*) pass "(k) preserved-line names the colon-bearing key" ;;
  *) fail "(k) preserved-line wrong (got: $out)" ;;
esac

# (l) profile-only QUOTED key preserved through a merge
cat > "$MA_TMP/profile_l.yaml" <<'EOF'
model_aliases:
  qwen-plus:
    model: STALE-VALUE
  "my:alias":
    provider: custom
hooks: {}
EOF
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_l.yaml" >/dev/null
assert_contains "$MA_TMP/profile_l.yaml" '"my:alias":' "(l) quoted profile-only key preserved"
assert_contains "$MA_TMP/profile_l.yaml" "provider: custom" "(l) quoted key sub-block intact"

# (m) unparseable 2-space line with no sub-block to attach to -> fail closed:
#     exit 2, ERR on stderr, profile byte-identical (never silently dropped)
cat > "$MA_TMP/profile_m.yaml" <<'EOF'
model_aliases:
  not a parseable entry
  qwen-plus:
    model: STALE-VALUE
hooks: {}
EOF
cp "$MA_TMP/profile_m.yaml" "$MA_TMP/profile_m.before"
rc=0
"$PYBIN" "$SYNC_SCRIPT" "$MA_TMP/root_with.yaml" "$MA_TMP/profile_m.yaml" >/dev/null 2>"$MA_TMP/m.err" || rc=$?
if [ "$rc" = "2" ]; then pass "(m) unparseable entry fails closed (exit 2)"; else fail "(m) expected exit 2, got $rc"; fi
assert_contains "$MA_TMP/m.err" "unrecognized entry" "(m) ERR names the unrecognized entry"
if diff -q "$MA_TMP/profile_m.before" "$MA_TMP/profile_m.yaml" >/dev/null; then
  pass "(m) profile untouched on fail-closed"
else
  fail "(m) profile modified despite fail-closed"
fi

echo "== scenario G: model_aliases synced onto pre-existing himmel_agent (refresh path, HIMMEL-737) =="
rm -rf "$HOME_DIR/profiles"; mkdir -p "$HOME_DIR/profiles"
seed_default empty
# root config carries model_aliases (drift case: added to root after himmel_agent was cloned)
printf 'model_aliases:\n  qwen-plus:\n    model: qwen-plus\n    provider: alibaba-coding-plan\n' >> "$HOME_DIR/config.yaml"
# pre-existing himmel_agent WITHOUT model_aliases (simulates a profile cloned before the block existed)
mkdir -p "$HOME_DIR/profiles/himmel_agent"
printf 'model:\n  default: gpt-5.5\nhooks: {}\n' > "$HOME_DIR/profiles/himmel_agent/config.yaml"
run >/dev/null
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "model_aliases:" "(G) refresh path syncs model_aliases onto existing himmel_agent"
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "alibaba-coding-plan" "(G) synced alias content matches root"
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "(G) hook still wired after alias sync"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED" >&2; exit 1; fi
