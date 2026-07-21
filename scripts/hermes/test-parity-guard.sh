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
# HIMMEL-1141: schtasks /query is read-only (allowed); other mutating verbs refused.
g "schtasks /query allowed"      allow '{"tool_name":"terminal","tool_input":{"command":"schtasks /query /fo LIST /v"}}'
g "schtasks.exe /query allowed"  allow '{"tool_name":"terminal","tool_input":{"command":"schtasks.exe /query"}}'
g "schtasks /Query mixed case"   allow '{"tool_name":"terminal","tool_input":{"command":"schtasks /Query /fo LIST"}}'
g "schtasks /change refused"     block '{"tool_name":"terminal","tool_input":{"command":"schtasks /change /tn X /disable"}}'
g "schtasks /run refused"        block '{"tool_name":"terminal","tool_input":{"command":"schtasks /run /tn X"}}'
g "schtasks /end refused"        block '{"tool_name":"terminal","tool_input":{"command":"schtasks /end /tn X"}}'
# HIMMEL-1141 security lock: UPPERCASE / mixed-case mutating verbs still refused
# — norm() lowercases before matching, so no case-bypass of the parity guard.
g "schtasks /CREATE upper refused" block '{"tool_name":"terminal","tool_input":{"command":"schtasks /CREATE /tn X /tr Y"}}'
g "schtasks /Delete mixed refused" block '{"tool_name":"terminal","tool_input":{"command":"schtasks /Delete /tn X /f"}}'
g "grep schtasks string allowed" allow '{"tool_name":"terminal","tool_input":{"command":"grep -n schtasks file.sh"}}'

echo "== parity_guard: destructive-floor spec fixes (HIMMEL-851) =="
# U1: /s is bound to the switch, not a path prefix — `rd /scripts` is not a
# recursive-delete switch, it's an argument that merely starts with "/s".
g "rd /scripts (path, not switch)" allow '{"tool_name":"terminal","tool_input":{"command":"rd /scripts foo"}}'
# U2: a quoted -rf flag must not defeat the recursive-rm pattern.
g "rm quoted -rf flag" block '{"tool_name":"terminal","tool_input":{"command":"rm \"-rf\" file"}}'
# U3: ${IFS} (a common word-split bypass) is whitespace-equivalent here.
# shellcheck disable=SC2016  # label is a literal string, not meant to expand
g 'rm ${IFS}-separated -rf' block '{"tool_name":"terminal","tool_input":{"command":"rm${IFS}-rf${IFS}x"}}'
# U3: backslash-newline continuation. Built via python (not hand-escaped bash)
# so the embedded backslash + real newline reach the guard exactly as a shell
# line-continuation would produce them, with correct JSON encoding guaranteed.
CONT_JSON="$("$PY" -c "
import json, sys
cmd = 'rm ' + chr(92) + chr(10) + '-rf x'
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd}}))
")"
g "rm backslash-continuation -rf" block "$CONT_JSON"
# O1: bare command-name atoms (format/schtasks/taskkill/shutdown/icacls
# classes) must only fire in command position, not embedded mid-argument.
g "git log --pretty=format: allowed" allow '{"tool_name":"terminal","tool_input":{"command":"git log --pretty=format:%H -n 5"}}'
g "grep -rn format src/ allowed"     allow '{"tool_name":"terminal","tool_input":{"command":"grep -rn format src/"}}'
g "echo shutdown mid-argument allowed" allow '{"tool_name":"terminal","tool_input":{"command":"echo shutdown"}}'
# CR r1 (HIMMEL-851): bounded launcher-wrapper tolerance in command position -
# wrapped destructive verbs must still be refused, mirroring the .sh CMDPOS.
g "sudo shutdown refused"            block '{"tool_name":"terminal","tool_input":{"command":"sudo shutdown -h now"}}'
g "env-assign prefix shutdown refused" block '{"tool_name":"terminal","tool_input":{"command":"x=1 shutdown -h now"}}'
g "cmd /c shutdown refused"          block '{"tool_name":"terminal","tool_input":{"command":"cmd /c shutdown /s /t 0"}}'
# CR r3 (HIMMEL-851): cmd accepts switches (/d /s /e:on …) before /c.
g "cmd /d /c shutdown refused"       block '{"tool_name":"terminal","tool_input":{"command":"cmd /d /c shutdown /s /t 0"}}'
g "cmd.exe /d /s /c shutdown refused" block '{"tool_name":"terminal","tool_input":{"command":"cmd.exe /d /s /c shutdown /s /t 0"}}'
g "powershell -command stop-process refused" block '{"tool_name":"terminal","tool_input":{"command":"powershell -command stop-process -name foo"}}'
BACKTICK_JSON="$("$PY" -c "
import json
cmd = 'echo ' + chr(96) + 'format c:' + chr(96)
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd}}))
")"
g "backtick-wrapped format refused"  block "$BACKTICK_JSON"
# CR r2 (HIMMEL-851): path-qualified destructive executables - a bounded
# exe-path prefix (optional drive + /-terminated segments) after the anchor,
# mirroring the .sh CMDPOS. The atoms' trailing boundary keeps format-* names
# allowed; mid-argument words stay allowed (not at command position).
g "/sbin/shutdown refused"           block '{"tool_name":"terminal","tool_input":{"command":"/sbin/shutdown -h now"}}'
g "./shutdown relative refused"      block '{"tool_name":"terminal","tool_input":{"command":"./shutdown -h now"}}'
g "drive-path shutdown.exe refused"  block '{"tool_name":"terminal","tool_input":{"command":"c:/windows/system32/shutdown.exe /s /t 0"}}'
QUOTEDPATH_JSON="$("$PY" -c "
import json
q = chr(34)
cmd = 'x; ' + q + 'c:/windows/system32/shutdown.exe' + q + ' /s'
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd}}))
")"
g "quoted drive-path shutdown refused" block "$QUOTEDPATH_JSON"
BSLASHPATH_JSON="$("$PY" -c "
import json
b = chr(92)
cmd = 'c:' + b + 'windows' + b + 'system32' + b + 'shutdown.exe /s /t 0'
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd}}))
")"
g "backslash drive-path shutdown refused" block "$BSLASHPATH_JSON"
g "format-data path basename allowed" allow '{"tool_name":"terminal","tool_input":{"command":"x; foo/format-data bar"}}'
# CR r4 (HIMMEL-851): path-qualified launcher wrappers - the exe-path prefix
# also applies before each wrapper token, mirroring the .sh CMDPOS. Residual
# documented gap (both impls): quoted-payload wrappers (bash -c "...", sh -c,
# xargs / nohup chains) - out of scope per the no-general-parser rule.
g "/usr/bin/env shutdown refused"    block '{"tool_name":"terminal","tool_input":{"command":"/usr/bin/env shutdown -h now"}}'
g "/usr/bin/sudo shutdown refused"   block '{"tool_name":"terminal","tool_input":{"command":"/usr/bin/sudo shutdown -h now"}}'
g "path-qualified cmd.exe /c shutdown refused" block '{"tool_name":"terminal","tool_input":{"command":"c:/windows/system32/cmd.exe /c shutdown /s /t 0"}}'
g "/usr/bin/env python3 benign allowed" allow '{"tool_name":"terminal","tool_input":{"command":"/usr/bin/env python3 build.py"}}'
# CR r5 (HIMMEL-851): assignment VALUE is quote-aware - FOO='a b' <verb> must
# not drop the verb out of command position. Built via python so the embedded
# quotes reach the guard with correct JSON encoding.
SQASSIGN_JSON="$("$PY" -c "
import json
q = chr(39)
cmd = 'foo=' + q + 'a b' + q + ' shutdown -h now'
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd}}))
")"
g "single-quoted assign shutdown refused" block "$SQASSIGN_JSON"
DQASSIGN_JSON="$("$PY" -c "
import json
q = chr(34)
cmd = 'foo=' + q + 'a b' + q + ' schtasks /delete /f'
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd}}))
")"
g "double-quoted assign schtasks refused" block "$DQASSIGN_JSON"
ECHOASSIGN_JSON="$("$PY" -c "
import json
sq, dq = chr(39), chr(34)
cmd = 'echo ' + dq + 'FOO=' + sq + 'a b' + sq + ' shutdown' + dq
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd}}))
")"
g "echo'd quoted assign+verb allowed" allow "$ECHOASSIGN_JSON"
# CR r6 (HIMMEL-851): sudo/env tolerate flag runs (env also assignment args),
# mirroring the .sh CMDPOS. Bounded grammar - further wrapper permutations
# are HIMMEL-912 (shared tokenizer); this + the CC-hook + the auto-mode
# classifier remain the outer defense layers.
g "sudo -n shutdown refused"         block '{"tool_name":"terminal","tool_input":{"command":"sudo -n shutdown -h now"}}'
g "env -i shutdown refused"          block '{"tool_name":"terminal","tool_input":{"command":"env -i shutdown -h now"}}'
g "env -i foo=bar shutdown refused"  block '{"tool_name":"terminal","tool_input":{"command":"env -i foo=bar shutdown -h now"}}'
g "sudo -n apt benign allowed"       allow '{"tool_name":"terminal","tool_input":{"command":"sudo -n apt update"}}'
g "env -i printenv benign allowed"   allow '{"tool_name":"terminal","tool_input":{"command":"env -i printenv"}}'
# CR r7 (HIMMEL-851): wrapper flags may each consume one following value token
# (generic, no per-option table; over-consumes at worst one benign token,
# never a bypass), mirroring the .sh CMDPOS.
g "sudo -u root shutdown refused"    block '{"tool_name":"terminal","tool_input":{"command":"sudo -u root shutdown -h now"}}'
g "env -u path shutdown refused"     block '{"tool_name":"terminal","tool_input":{"command":"env -u path shutdown -h now"}}'
g "sudo -u root -g wheel taskkill refused" block '{"tool_name":"terminal","tool_input":{"command":"sudo -u root -g wheel taskkill /f"}}'
g "sudo -u root ls benign allowed"   allow '{"tool_name":"terminal","tool_input":{"command":"sudo -u root ls"}}'
g "sudo -u root apt benign allowed"  allow '{"tool_name":"terminal","tool_input":{"command":"sudo -u root apt update"}}'
g "env -u path printenv benign allowed" allow '{"tool_name":"terminal","tool_input":{"command":"env -u path printenv"}}'
REBOOT_JSON="$("$PY" -c "
import json
q = chr(34)
cmd = 'git commit -m ' + q + 'fix reboot loop' + q
print(json.dumps({'tool_name': 'terminal', 'tool_input': {'command': cmd, 'cwd': '$FR'}}))
")"
g "commit msg mentions reboot allowed" allow "$REBOOT_JSON"

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
# qmd MCP collection fence (HIMMEL-1239): the KB carve-out is COLLECTION-
# SCOPED to "himmel" only — qmd indexes salus (PHI vault) with no built-in
# isolation, so an unscoped call must deny fail-closed.
g "mcp qmd query unscoped refused"       block '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{}}'
g "mcp qmd query scoped himmel allowed"  allow '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel"]}}'
g "mcp qmd query scoped salus refused"   block '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["salus"]}}'
g "mcp qmd query scoped luna refused"    block '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["luna"]}}'
g "mcp qmd query mixed himmel+salus refused" block '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":["himmel","salus"]}}'
g "mcp qmd query empty collections refused" block '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":[]}}'
g "mcp qmd get scoped himmel allowed"    allow '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"qmd://himmel/README.md"}}'
g "mcp qmd get scoped salus refused"     block '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"qmd://salus/patient.md"}}'
g "mcp qmd get bare filename refused"    block '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"README.md"}}'
g "mcp qmd get docid refused"            block '{"tool_name":"mcp__plugin_qmd_qmd__get","tool_input":{"file":"#abc123"}}'
g "mcp qmd multi_get scoped himmel allowed" allow '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/*.md"}}'
g "mcp qmd multi_get mixed scoped+unscoped refused" block '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://himmel/a.md,notes.md"}}'
g "mcp qmd multi_get luna referenced refused" block '{"tool_name":"mcp__plugin_qmd_qmd__multi_get","tool_input":{"pattern":"qmd://luna/*.md"}}'
g "mcp qmd status refused (no scoping input)" block '{"tool_name":"mcp__plugin_qmd_qmd__status","tool_input":{}}'
# CR round 1 (codex-1): a non-string collections entry (e.g. a dict) must not
# crash the guard via `c not in <set-of-str>` raising TypeError — it must
# deny fail-closed like any other non-"himmel" entry.
g "mcp qmd query non-string collections entry refused (no crash)" block '{"tool_name":"mcp__plugin_qmd_qmd__query","tool_input":{"collections":[{"x":1}]}}'

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
# The ONESHOT signals (what invoke.sh actually exports for --model/--provider)
# naming an untrusted engine are refused despite the opt-in — the real
# dispatch-trusted.sh path never sets HERMES_ENGINE (HIMMEL-916 CR finding).
export HERMES_ONESHOT_MODEL="deepseek-v4-flash"
g "push refused when ONESHOT_MODEL=deepseek" block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
g "gh pr create refused on deepseek oneshot" block '{"tool_name":"terminal","tool_input":{"command":"gh pr create --fill"}}'
unset HERMES_ONESHOT_MODEL
export HERMES_ONESHOT_PROVIDER="deepseek"
g "push refused when ONESHOT_PROVIDER=deepseek" block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ONESHOT_PROVIDER
# Mixed-case signal still caught — the guard lowercases before matching; a
# refactor dropping .lower() must fail here (caller-controlled case, invoke.sh
# forwards whatever the caller passed).
export HERMES_ONESHOT_MODEL="DeepSeek-V4-Flash"
g "push refused on mixed-case DeepSeek-V4-Flash"  block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ONESHOT_MODEL
# deepseek-v4-pro is the lane row's second advertised model — pin it too.
export HERMES_ONESHOT_MODEL="deepseek-v4-pro"
g "push refused when ONESHOT_MODEL=deepseek-v4-pro" block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ONESHOT_MODEL
# Legacy names stay guarded through the 2026-07-24 retirement overlap.
export HERMES_ONESHOT_MODEL="deepseek-chat"
g "push refused on legacy deepseek-chat during overlap" block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ONESHOT_MODEL
export HERMES_ONESHOT_MODEL="deepseek-reasoner"
g "push refused on legacy deepseek-reasoner during overlap" block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ONESHOT_MODEL
# ANY single untrusted signal wins even when another signal is trusted —
# catches a future break/early-return regression inside the signal loop.
export HERMES_ENGINE="codex-5.5" HERMES_ONESHOT_MODEL="deepseek-v4-flash"
g "untrusted oneshot beats trusted engine"    block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ENGINE HERMES_ONESHOT_MODEL
export HERMES_ONESHOT_MODEL="glm-4.7"
g "push refused when ONESHOT_MODEL=glm"      block '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ONESHOT_MODEL
# A TRUSTED oneshot model rides the opt-in unchanged (no over-block).
export HERMES_ONESHOT_MODEL="gpt-5.5"
g "push allowed on trusted oneshot + opt-in" allow '{"tool_name":"terminal","tool_input":{"command":"git push origin main"}}'
unset HERMES_ONESHOT_MODEL
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
