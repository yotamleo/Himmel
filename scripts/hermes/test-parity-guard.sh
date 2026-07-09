#!/usr/bin/env bash
# Tests for the security-critical guard + wiring assets (HIMMEL-557).
# Drives parity_guard.py over stdin and asserts block/allow; exercises
# wire_parity_guard.py set/swap. Hermetic: HERMES_HOME points at a temp tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/assets/parity_guard.py"
WIRE="$SCRIPT_DIR/assets/wire_parity_guard.py"
PY="$(command -v python3 || command -v python)" || { echo "SKIP: no python"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hermes/agent-hooks"
# On Git Bash, MSYS rewrites a /tmp env value to Windows form when launching
# the native python — so resolve HERMES_HOME and the payload paths to the SAME
# form (cygpath -m) to avoid a spurious mismatch. No-op off Windows.
H="$TMP/hermes"
if command -v cygpath >/dev/null 2>&1; then H="$(cygpath -m "$TMP/hermes")"; fi
export HERMES_HOME="$H"   # guard lower-cases internally via norm()

# Resolve a temp path to the SAME (Windows) form the native python sees, so a
# path fixture matches what the guard stats. No-op off Windows. Defined early —
# used by both the edit-on-main and the PHI fixture blocks below.
wp() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
GUARD="$(wp "$GUARD")"
WIRE="$(wp "$WIRE")"

# Point the merged-PR guard's gh at a non-existent binary so no test makes a
# real network call (fail-open); the merged-PR cases below drive verdicts via
# the PARITY_GUARD_GH_RESULT test seam instead.
export GH_CMD="$TMP/no-such-gh-binary"
unset HERMES_EXTERNAL_WRITES_OK
unset ANTHROPIC_BASE_URL
unset HERMES_ENGINE

fails=0
# expect = "block" | "allow"
g() {  # g "<label>" "<expect>" '<json payload>'
  out="$(printf '%s' "$3" | "$PY" "$GUARD")"
  case "$out" in
    *'"decision": "block"'*) got=block ;;
    '{}')                     got=allow ;;
    *)                        got="?($out)" ;;
  esac
  if [ "$got" = "$2" ]; then echo "  ok: $1"; else
    echo "  FAIL: $1 — expected $2 got $got" >&2; fails=$((fails + 1)); fi
}

echo "== parity_guard: self-protection (any arg key) =="
g "guard self-write (path key)"   block "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$H/agent-hooks/parity_guard.py\"}}"
g "guard self-write (odd key)"    block "{\"tool_name\":\"write_file\",\"tool_input\":{\"filename\":\"$H/agent-hooks/parity_guard.py\"}}"
g "profile SOUL write (odd key)"  block "{\"tool_name\":\"write_file\",\"tool_input\":{\"output\":\"$H/profiles/x/SOUL.md\"}}"
g "profile config write"          block "{\"tool_name\":\"write_file\",\"tool_input\":{\"target\":\"$H/profiles/x/config.yaml\"}}"

echo "== parity_guard: secret read fence (any arg key + classes) =="
g ".env (path key)"      block '{"tool_name":"read_file","tool_input":{"path":"/x/.env"}}'
g ".env (odd key)"       block '{"tool_name":"read_file","tool_input":{"whatever":"/x/.env"}}'
g ".envrc"               block '{"tool_name":"read_file","tool_input":{"path":"/x/.envrc"}}'
g "id_rsa"               block '{"tool_name":"read_file","tool_input":{"path":"/home/u/id_rsa"}}'
g "relative .ssh/"       block '{"tool_name":"read_file","tool_input":{"path":".ssh/id_ed25519"}}'
g "secrets.yaml"         block '{"tool_name":"read_file","tool_input":{"path":"/x/secrets.yaml"}}'
g "cert.p12"             block '{"tool_name":"read_file","tool_input":{"path":"/x/cert.p12"}}'
g "normal file read"     allow '{"tool_name":"read_file","tool_input":{"path":"/x/README.md"}}'

echo "== parity_guard: writes allowed where they should be =="
g "repo code write"      allow '{"tool_name":"write_file","tool_input":{"path":"/repo/foo.sh"}}'
g "content not over-blocked" allow '{"tool_name":"write_file","tool_input":{"path":"/repo/doc.md","content":"see /x/.env and config.yaml"}}'

# Fake git repos in Windows-resolvable form (same cygpath handling as HERMES_HOME)
# so the native python (Git Bash) stats the real temp tree.
mkdir -p "$TMP/mainrepo/.git" "$TMP/mainrepo/src" \
         "$TMP/featrepo/.git" "$TMP/featrepo/src" \
         "$TMP/mastrepo/.git"
printf 'ref: refs/heads/main\n'   > "$TMP/mainrepo/.git/HEAD"
printf 'ref: refs/heads/feat/x\n' > "$TMP/featrepo/.git/HEAD"
printf 'ref: refs/heads/master\n' > "$TMP/mastrepo/.git/HEAD"
MR="$(wp "$TMP/mainrepo")"; FR="$(wp "$TMP/featrepo")"; MASTR="$(wp "$TMP/mastrepo")"

echo "== parity_guard: terminal classes =="
g "git commit"     allow "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m x\",\"cwd\":\"$FR\"}}"
g "git push force" block '{"tool_name":"terminal","tool_input":{"command":"git push --force"}}'
g "rm -rf"         block '{"tool_name":"terminal","tool_input":{"command":"rm -rf build"}}'
g "plain rm"       allow '{"tool_name":"terminal","tool_input":{"command":"rm tmp.txt"}}'
g "schtasks"       block '{"tool_name":"terminal","tool_input":{"command":"schtasks /delete /tn X"}}'

echo "== parity_guard: block-edit-on-main parity (HIMMEL-731) =="
g "write into repo on main refused"    block "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$MR/src/foo.sh\"}}"
g "delete in repo on main refused"     block "{\"tool_name\":\"delete_file\",\"tool_input\":{\"path\":\"$MR/src/old.sh\"}}"
g "write on worker branch allowed"     allow "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$FR/src/foo.sh\"}}"
g "git commit on master refused"       block "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$MASTR\"}}"
g "git commit on worker branch allowed" allow "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FR\"}}"
# .single-writer marker at the repo root opts the on-main repo out.
: > "$TMP/mainrepo/.single-writer"
g "write on main with .single-writer allowed" allow "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$MR/src/foo.sh\"}}"
# Process-cwd fallback (payload carries NO cwd -> guard resolves os.getcwd()).
# Driven DETERMINISTICALLY by cd-ing into a fixture repo (#975: never inherit
# the suite runner's cwd) — this is the production path for terminal payloads
# that omit cwd, so it keeps a regression guard after the hermetic fix above.
gcwd() {  # gcwd "<label>" "<expect>" "<dir to run the guard from>" '<json payload>'
  out="$(cd "$3" && printf '%s' "$4" | "$PY" "$GUARD")"
  case "$out" in
    *'"decision": "block"'*) got=block ;;
    '{}')                     got=allow ;;
    *)                        got="?($out)" ;;
  esac
  if [ "$got" = "$2" ]; then echo "  ok: $1"; else
    echo "  FAIL: $1 — expected $2 got $got" >&2; fails=$((fails + 1)); fi
}
gcwd "git commit, no payload cwd, guard cwd=master repo refused" block "$TMP/mastrepo" '{"tool_name":"terminal","tool_input":{"command":"git commit -m x"}}'
gcwd "git commit, no payload cwd, guard cwd=worker repo allowed" allow "$TMP/featrepo" '{"tool_name":"terminal","tool_input":{"command":"git commit -m x"}}'

echo "== parity_guard: block-merged-pr-commit parity (HIMMEL-731) =="
# Worker branch fixture; the merged-PR verdict is injected via the
# PARITY_GUARD_GH_RESULT test seam (hermetic — no real gh call).
mkdir -p "$TMP/shiprepo/.git"
printf 'ref: refs/heads/feat/shipped\n' > "$TMP/shiprepo/.git/HEAD"
SR="$(wp "$TMP/shiprepo")"
export PARITY_GUARD_GH_RESULT=1
g "git commit on merged-PR branch refused" block "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m x\",\"cwd\":\"$SR\"}}"
export PARITY_GUARD_GH_RESULT=0
g "git commit on branch with no/open PR allowed" allow "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m x\",\"cwd\":\"$SR\"}}"
export PARITY_GUARD_GH_RESULT=__ERR__
g "merged-PR guard fails open on gh error" allow "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m x\",\"cwd\":\"$SR\"}}"
unset PARITY_GUARD_GH_RESULT
# gh unavailable (GH_CMD -> non-existent) also fails open.
g "merged-PR guard fails open when gh absent" allow "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m x\",\"cwd\":\"$SR\"}}"

echo "== parity_guard: block-docker-privesc parity (HIMMEL-731) =="
g "docker --privileged refused"    block '{"tool_name":"terminal","tool_input":{"command":"docker run --rm --privileged ubuntu bash"}}'
g "docker root bind-mount refused" block '{"tool_name":"terminal","tool_input":{"command":"docker run -v /:/host ubuntu"}}'
g "docker /etc mount refused"      block '{"tool_name":"terminal","tool_input":{"command":"docker run -v /etc:/host:rw ubuntu install"}}'
g "docker socket mount refused"    block '{"tool_name":"terminal","tool_input":{"command":"docker run -v /var/run/docker.sock:/s img"}}'
g "docker --pid=host refused"      block '{"tool_name":"terminal","tool_input":{"command":"docker run --pid=host img"}}'
g "docker cap-add SYS_ADMIN refused" block '{"tool_name":"terminal","tool_input":{"command":"docker run --cap-add SYS_ADMIN img"}}'
g "docker --user root refused"     block '{"tool_name":"terminal","tool_input":{"command":"docker run --user 0 -v /:/h img"}}'
g "podman --privileged refused"    block '{"tool_name":"terminal","tool_input":{"command":"podman run --privileged img"}}'
g "docker ps allowed"              allow '{"tool_name":"terminal","tool_input":{"command":"docker ps"}}'
g "docker project-local mount allowed" allow '{"tool_name":"terminal","tool_input":{"command":"docker run -v ./src:/app node build"}}'

echo "== parity_guard: block-backend-tier / MCP fence parity (HIMMEL-731) =="
g "mcp github tool refused"    block '{"tool_name":"mcp__plugin_github_github__create_pull_request","tool_input":{}}'
g "mcp vercel tool refused"    block '{"tool_name":"mcp__plugin_vercel_vercel__deploy_to_vercel","tool_input":{}}'
g "mcp bare tool refused"      block '{"tool_name":"mcp__whatever__do","tool_input":{}}'
g "mcp qmd KB carve-out allowed"    allow '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{}}'
g "mcp qmd KB get carve-out allowed" allow '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{}}'

echo "== parity_guard: fail-closed on malformed payload =="
g "malformed json" block 'NOT JSON'

echo "== parity_guard: PHI / data-egress fence (HIMMEL-695) =="
# Fixtures in Windows-resolvable form so the native python (Git Bash) stats the
# real temp tree — same cygpath handling as HERMES_HOME above (wp() defined near top).
mkdir -p "$TMP/vault/sub" "$TMP/phi/case" "$TMP/repo" "$TMP/denyroot/pt"
: > "$TMP/vault/.salus"                     # PHI vault marker
CFG="$TMP/glmcfg"; mkdir -p "$CFG"
printf '%s\n' "$(wp "$TMP/phi")" > "$CFG/phi-roots"            # registered PHI root
printf '%s\n' "$(wp "$TMP/denyroot")" > "$CFG/egress-denylist" # registered egress root
CFG_W="$(wp "$CFG")"; export CLAUDE_GLM_CONFIG_DIR="$CFG_W"
WV="$(wp "$TMP/vault")"
g ".salus write refused (ancestor walk)" block "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$WV/sub/note.md\"}}"
g ".salus read refused"        block "{\"tool_name\":\"read_file\",\"tool_input\":{\"path\":\"$WV/patient.md\"}}"
g ".salus search refused"      block "{\"tool_name\":\"search_files\",\"tool_input\":{\"path\":\"$WV\"}}"
g "phi-roots descendant refused" block "{\"tool_name\":\"read_file\",\"tool_input\":{\"path\":\"$(wp "$TMP/phi/case")/pt.md\"}}"
g "non-PHI write still allowed" allow "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$(wp "$TMP/repo")/foo.sh\"}}"
g "terminal .salus ref refused" block '{"tool_name":"terminal","tool_input":{"command":"cat /data/.salus/pt.md"}}'
g "egress-denylist descendant refused" block "{\"tool_name\":\"read_file\",\"tool_input\":{\"path\":\"$(wp "$TMP/denyroot/pt")/x.md\"}}"
g "delete under .salus refused" block "{\"tool_name\":\"delete_file\",\"tool_input\":{\"path\":\"$WV/old.md\"}}"
PHI_W="$(wp "$TMP/phi")"
g "terminal phi-root ref refused" block "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"grep x $PHI_W/case/pt.md\"}}"
# symlink/junction INTO a .salus vault must not bypass the ancestor walk (realpath).
if ln -s "$TMP/vault/sub" "$TMP/lnk" 2>/dev/null && [ -L "$TMP/lnk" ]; then
  g "symlink into .salus refused" block "{\"tool_name\":\"read_file\",\"tool_input\":{\"path\":\"$(wp "$TMP/lnk")/pt.md\"}}"
else
  echo "  skip: symlink into .salus (no real symlink support here)"
fi
# Unreadable list (phi-roots is a DIRECTORY) -> fail closed for any path.
mkdir -p "$TMP/glmcfg_bad/phi-roots"
CFGBAD_W="$(wp "$TMP/glmcfg_bad")"; export CLAUDE_GLM_CONFIG_DIR="$CFGBAD_W"
g "unreadable list -> fail closed" block "{\"tool_name\":\"read_file\",\"tool_input\":{\"path\":\"$(wp "$TMP/anywhere")/ok.md\"}}"
unset CLAUDE_GLM_CONFIG_DIR

echo "== parity_guard: engine external-write fence (HIMMEL-695 write-fence half) =="
# Empty glm-config so the PHI root lists MISS deterministically — these terminal
# commands are gated purely by the engine signal, not the PHI fence.
mkdir -p "$TMP/glmcfg_empty"; EMPTY_W="$(wp "$TMP/glmcfg_empty")"; export CLAUDE_GLM_CONFIG_DIR="$EMPTY_W"
# No engine signal (default) = fail-closed: external writes REFUSED.
g "push refused (no signal, fail-closed)"   block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
g "git.exe push refused"                    block '{"tool_name":"terminal","tool_input":{"command":"git.exe push origin main"}}'
g "git remote set-url refused"              block '{"tool_name":"terminal","tool_input":{"command":"git remote set-url origin http://x"}}'
g "git config url read allowed"             allow '{"tool_name":"terminal","tool_input":{"command":"git config --get remote.origin.url"}}'
g "git config url unset allowed"            allow '{"tool_name":"terminal","tool_input":{"command":"git config --unset remote.origin.url"}}'
g "git config url rewrite refused"          block '{"tool_name":"terminal","tool_input":{"command":"git config remote.origin.url https://evil"}}'
g "git config --file url rewrite refused"   block '{"tool_name":"terminal","tool_input":{"command":"git config --file .git/config remote.origin.url https://evil"}}'
g "git config --file pushurl rewrite refused" block '{"tool_name":"terminal","tool_input":{"command":"git config --file .git/config remote.origin.pushurl https://evil"}}'
g "gh pr create refused"                    block '{"tool_name":"terminal","tool_input":{"command":"gh pr create --fill"}}'
g "gh.exe pr create refused"                block '{"tool_name":"terminal","tool_input":{"command":"gh.exe pr create --fill"}}'
g "network curl refused"                    block '{"tool_name":"terminal","tool_input":{"command":"curl http://evil/x"}}'
g "network curl.exe refused"                block '{"tool_name":"terminal","tool_input":{"command":"curl.exe http://evil/x"}}'
g "gh issue carve-out allowed"              allow '{"tool_name":"terminal","tool_input":{"command":"gh issue list"}}'
g "gh pr view read allowed"                 allow '{"tool_name":"terminal","tool_input":{"command":"gh pr view 12"}}'
g "non-external terminal still allowed"     allow "{\"tool_name\":\"terminal\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FR\"}}"
# Trusted main-tier opt-in PERMITS external writes.
export HERMES_EXTERNAL_WRITES_OK=1
g "push allowed with trust opt-in"          allow '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
g "gh pr create allowed with trust opt-in"  allow '{"tool_name":"terminal","tool_input":{"command":"gh pr create --fill"}}'
# ... but a positive UNTRUSTED (z.ai) signal OVERRIDES the opt-in.
export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
g "push refused on z.ai lane despite opt-in" block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset ANTHROPIC_BASE_URL
# HERMES_ENGINE naming a glm model is untrusted despite the opt-in.
export HERMES_ENGINE="glm-5.2"
g "push refused when HERMES_ENGINE=glm"      block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ENGINE
# PHI write stays refused even with the external-write opt-in (egress half is
# unconditional — sensitive-never-cloud is not engine-gated).
g "PHI write still refused with opt-in"      block "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$WV/sub/note.md\"}}"
unset HERMES_EXTERNAL_WRITES_OK
unset CLAUDE_GLM_CONFIG_DIR

echo "== wire_parity_guard: set (insert + replace) =="
cfg="$(wp "$TMP/c1.yaml")"
printf 'model:\n  default: gpt-5.5\nhooks: {}\nsecurity:\n  redact_secrets: true\n' > "$cfg"
"$PY" "$WIRE" set "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
if grep -q "parity_guard.py" "$cfg" && grep -q "pre_tool_call" "$cfg" && grep -q "redact_secrets" "$cfg" && grep -q "mcp__" "$cfg"; then
  echo "  ok: set inserted hook (matcher covers mcp__), preserved other keys"; else
  echo "  FAIL: set did not wire correctly (mcp__ in matcher?)" >&2; fails=$((fails + 1)); fi
# replace an existing luna_vault_guard block; the top-level key AFTER the hooks
# block (here `trailing:`) MUST survive — guards against truncation.
printf 'hooks:\n  pre_tool_call:\n  - matcher: x\n    command: luna_vault_guard.py\n    timeout: 10\ntrailing: keep-me\n' > "$cfg"
"$PY" "$WIRE" set "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
n="$(grep -c "pre_tool_call" "$cfg")"
if grep -q "parity_guard.py" "$cfg" && ! grep -q "luna_vault_guard" "$cfg" && [ "$n" = "1" ] && grep -q "trailing: keep-me" "$cfg"; then
  echo "  ok: set replaced existing block (no dup, no leftover, trailing key kept)"; else
  echo "  FAIL: set replace wrong (n=$n, trailing key truncated?)" >&2; fails=$((fails + 1)); fi

echo "== wire_parity_guard: swap (non-destructive) =="
printf 'hooks:\n  pre_tool_call:\n  - command: /x/agent-hooks/luna_vault_guard.py\n' > "$cfg"
"$PY" "$WIRE" swap "$cfg" >/dev/null
if grep -q "parity_guard.py" "$cfg" && ! grep -q "luna_vault_guard" "$cfg"; then
  echo "  ok: swap converted luna_vault_guard -> parity_guard"; else
  echo "  FAIL: swap did not convert" >&2; fails=$((fails + 1)); fi
printf 'hooks: {}\n' > "$cfg"
before="$(cat "$cfg")"; "$PY" "$WIRE" swap "$cfg" >/dev/null
if [ "$(cat "$cfg")" = "$before" ]; then
  echo "  ok: swap left guard-less config untouched"; else
  echo "  FAIL: swap modified a guard-less config" >&2; fails=$((fails + 1)); fi

echo "== wire_parity_guard: ensure (universal guard, HIMMEL-744) =="
# branch 1: already on parity_guard -> idempotent no-op
printf 'hooks:\n  pre_tool_call:\n  - command: /x/agent-hooks/parity_guard.py\n' > "$cfg"
before="$(cat "$cfg")"
"$PY" "$WIRE" ensure "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
if [ "$(cat "$cfg")" = "$before" ]; then
  echo "  ok: ensure no-op on an already-parity config"; else
  echo "  FAIL: ensure modified an already-parity config" >&2; fails=$((fails + 1)); fi
# branch 2: carries luna_vault_guard -> swapped
printf 'hooks:\n  pre_tool_call:\n  - command: /x/agent-hooks/luna_vault_guard.py\n' > "$cfg"
"$PY" "$WIRE" ensure "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
if grep -q "parity_guard.py" "$cfg" && ! grep -q "luna_vault_guard" "$cfg"; then
  echo "  ok: ensure swapped luna_vault_guard -> parity_guard"; else
  echo "  FAIL: ensure did not swap luna_vault_guard" >&2; fails=$((fails + 1)); fi
# branch 3: no guard hook, but an UNRELATED hook present -> parity_guard ADDED,
# the unrelated hook + surrounding keys preserved (non-clobbering).
printf 'model:\n  default: gpt-5.5\nhooks:\n  post_tool_call:\n  - command: /x/other_hook.py\n    timeout: 5\nsecurity:\n  redact_secrets: true\n' > "$cfg"
"$PY" "$WIRE" ensure "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
if grep -q "parity_guard.py" "$cfg" && grep -q "pre_tool_call" "$cfg" \
   && grep -q "post_tool_call" "$cfg" && grep -q "other_hook.py" "$cfg" \
   && grep -q "redact_secrets" "$cfg" && grep -q "mcp__" "$cfg"; then
  echo "  ok: ensure added parity_guard, preserved unrelated hook + keys"; else
  echo "  FAIL: ensure add clobbered other hooks/keys (mcp__ matcher?)" >&2; fails=$((fails + 1)); fi
# branch 3b: fully guard-less (hooks: {}) -> parity_guard added, keys preserved
printf 'model:\n  default: gpt-5.5\nhooks: {}\nsecurity:\n  redact_secrets: true\n' > "$cfg"
"$PY" "$WIRE" ensure "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
if grep -q "parity_guard.py" "$cfg" && grep -q "pre_tool_call" "$cfg" && grep -q "redact_secrets" "$cfg"; then
  echo "  ok: ensure wired an empty hooks:{} config"; else
  echo "  FAIL: ensure did not wire hooks:{} config" >&2; fails=$((fails + 1)); fi

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED" >&2; exit 1; fi
