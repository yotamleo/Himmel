#!/usr/bin/env bash
# scripts/cr/test-artifact-critic.sh — TDD for artifact-critic.sh (HIMMEL-414 WS4).
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HERE="$(cd "$(dirname "$0")" && pwd)"; AC="$HERE/artifact-critic.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
check(){ if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: got [$2] want [$3]"; fails=$((fails+1)); fi; }
check_contains(){ if grepq "$2" -F -- "$3"; then echo "ok - $1"; else echo "FAIL - $1: missing [$3]"; fails=$((fails+1)); fi; }

ART="$tmp/spec.md"; printf '# T\n## S\nbody\n' > "$ART"
CH="$tmp/charter.md"; printf 'charter role text\n' > "$CH"

# Stub CFP: record argv + stdin-first-line so we can assert the delegation.
STUB="$tmp/cfp-stub.sh"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$tmp/argv"
head -1 > "$tmp/stdin1"
echo "# s First-Pass Review"
EOS
chmod +x "$STUB"

# (f) wrapper delegates with --artifact-mode --charter-file and pipes the artifact
out="$(CRITIC_FIRST_PASS="$STUB" bash "$AC" --artifact "$ART" --charter "$CH" --model x/y --slug s 2>/dev/null)"
argv="$(cat "$tmp/argv")"
check_contains "f: returns CFP output" "$out" "# s First-Pass Review"
check_contains "f: delegates --artifact-mode" "$argv" "--artifact-mode"
check_contains "f: delegates --charter-file" "$argv" "--charter-file $CH"
check_contains "f: passes model" "$argv" "--model x/y"
check "f: artifact piped on stdin (first line)" "$(cat "$tmp/stdin1")" "# T"

# missing artifact file -> exit 2
CRITIC_FIRST_PASS="$STUB" bash "$AC" --artifact "$tmp/nope.md" --charter "$CH" --model x/y >/dev/null 2>&1
check "missing artifact -> exit 2" "$?" "2"

# --- HIMMEL-1646 / HIMMEL-1648: artifact-critic loads the glm lane's .env creds ---
# HIMMEL-1648: the load is pinned to SCRIPT-ROOT resolution
# (load_dotenv --root "$(_load_dotenv_primary_for "$SCRIPT_DIR/../..")"), so a
# script invoked from an UNRELATED git repo reads himmel's .env, not THAT repo's.
# The fixture copies the script + load-dotenv.sh into a fake himmel root (so
# $SCRIPT_DIR/../.. resolves THERE) carrying GLM_API_KEY ONLY in its .env; the
# process cwd is a DIFFERENT git repo whose .env holds a DECOY value. The glm
# artifact row must surface the himmel-root key to the exec'd critic-first-pass
# (here stubbed), never the cwd decoy — the pre-fix CWD-anchored resolution read
# the decoy. A non-glm row must NOT load (gate), and a LIVE process value still
# wins (only-when-unset, HIMMEL-1646).
hroot="$tmp/hroot1648"; mkdir -p "$hroot/scripts/cr" "$hroot/scripts/lib"
cp "$AC" "$hroot/scripts/cr/artifact-critic.sh"
cp "$HERE/../lib/load-dotenv.sh" "$hroot/scripts/lib/load-dotenv.sh"
printf 'GLM_API_KEY=zk-himmel-root\n' > "$hroot/.env"
cwx="$tmp/cwd-unrelated"; mkdir -p "$cwx"; git init -q "$cwx"
git -C "$cwx" config user.name test; git -C "$cwx" config user.email t@e.invalid
printf 'x\n' > "$cwx/README"; git -C "$cwx" add README; git -C "$cwx" commit -q -m init
printf 'GLM_API_KEY=DECOY-cwd-value\n' > "$cwx/.env"
glm_key="$tmp/glm_key"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
printf '%s' "\${GLM_API_KEY:-}" > "$glm_key"
echo "# glm First-Pass Review"
EOS
chmod +x "$STUB"
# glm lane from an UNRELATED cwd repo: the himmel-root key wins over the cwd decoy.
: > "$glm_key"
( cd "$cwx" && unset GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY && CRITIC_FIRST_PASS="$STUB" bash "$hroot/scripts/cr/artifact-critic.sh" --artifact "$ART" --charter "$CH" --model glm-5.2 --slug glm >/dev/null 2>&1 )
check "HIMMEL-1648: glm lane loads the himmel-root .env key (not the cwd repo's decoy)" "$(cat "$glm_key" 2>/dev/null)" "zk-himmel-root"
# non-glm lane: the gate must NOT load -> the exec'd critic-first-pass sees no key.
: > "$glm_key"
( cd "$cwx" && unset GLM_API_KEY ZAI_API_KEY Z_AI_API_KEY && CRITIC_FIRST_PASS="$STUB" bash "$hroot/scripts/cr/artifact-critic.sh" --artifact "$ART" --charter "$CH" --model gpt-5.5 --slug codex >/dev/null 2>&1 )
check "non-glm lane does NOT load the .env key" "$(cat "$glm_key" 2>/dev/null)" ""
# glm lane with a LIVE process value: load_dotenv sets only-when-unset, so the
# .env value must NOT overwrite it (HIMMEL-1646 precedence — pins the half of the
# contract the cwd-discriminator case above cannot detect).
: > "$glm_key"
( cd "$cwx" && GLM_API_KEY=process-key CRITIC_FIRST_PASS="$STUB" bash "$hroot/scripts/cr/artifact-critic.sh" --artifact "$ART" --charter "$CH" --model glm-5.2 --slug glm >/dev/null 2>&1 )
check "glm lane preserves the live process env key over .env" "$(cat "$glm_key" 2>/dev/null)" "process-key"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
