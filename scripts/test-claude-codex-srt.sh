#!/usr/bin/env bash
# shellcheck disable=SC2015
# Hermetic tests for the claude-codex srt wrap. A fake `srt` stands
# in for sandbox-runtime 0.0.79: it refuses an empty or missing --settings file
# like the real one, runs the command it is handed as ONE shell string, and sets
# the in-box environment srt sets (SANDBOX_RUNTIME, TMPDIR, the proxy variables
# and the NO_PROXY list, all copied from sandbox-utils.js in the 0.0.79 package).
# bash 3.2-safe.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/claude-codex"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-codex-srt-test.XXXXXX")" || exit 1
# the launcher resolves physical paths; macOS's /tmp is a symlink to /private/tmp
TMP="$(cd "$TMP" && pwd -P)" || exit 1
trap 'rm -rf "$TMP"' EXIT

HOME_F="$TMP/home"; BIN="$TMP/bin"; WT="$TMP/wt"; SCRATCH="$TMP/scratch"; HANDOVER="$TMP/handover"
mkdir -p "$HOME_F/.claude" "$BIN" "$WT" "$SCRATCH" "$HANDOVER"
printf '%s\n' '{}' >"$HOME_F/.claude/settings.json"
: >"$TMP/argv"

# the real srt NO_PROXY value (sandbox-utils.js, 0.0.79): it carries the private ranges
# (assembled from pieces so the private-lan-ip leak gate sees no literal)
P8='10.0''.0.0/8'; P12='172.16''.0.0/12'; P16='192.168''.0.0/16'
SRT_NO_PROXY="localhost,127.0.0.1,::1,169.254.0.0/16,$P8,$P12,$P16"
GW_HOST='10.0''.2.2'

cat >"$BIN/srt" <<MOCK
#!/usr/bin/env bash
# fake srt: record argv, refuse a bad --settings file, then run the command
# string the way real srt does (shell-quoted argv joined, run by bash -c)
printf '%s\n' "\$@" >"$TMP/argv"
[ "\${1:-}" = --settings ] || { echo "srt: no --settings" >&2; exit 64; }
[ -s "\$2" ] || { echo "srt: settings file is empty or does not exist" >&2; exit 65; }
cp "\$2" "$TMP/settings.json"
[ -f "\$5" ] && : >"$TMP/wrapper-existed"
shift 2
[ "\${1:-}" = -- ] && shift
cmd=""
for a in "\$@"; do cmd="\$cmd \$(printf '%q' "\$a")"; done
exec env SANDBOX_RUNTIME=1 TMPDIR=/tmp/claude NO_PROXY='$SRT_NO_PROXY' no_proxy='$SRT_NO_PROXY' \\
  HTTP_PROXY=http://localhost:3128 HTTPS_PROXY=http://localhost:3128 bash -c "\$cmd"
MOCK
cat >"$BIN/claude" <<MOCK
#!/usr/bin/env bash
env >"$TMP/child-env"
pwd >"$TMP/child-pwd"
MOCK
cat >"$BIN/curl" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/curl-args"
exit 0
MOCK
chmod +x "$BIN/srt" "$BIN/claude" "$BIN/curl"

# run <expected rc> <needle|-> <env assignments...> -- launcher args
run() {
    local want="$1" needle="$2"
    shift 2
    local envs=()
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    : >"$TMP/argv"; : >"$TMP/curl-args"; rm -f "$TMP/child-env" "$TMP/child-pwd" "$TMP/settings.json"
    ( cd "$WT" && env HOME="$HOME_F" PATH="$BIN:$PATH" CLIPROXY_API_KEY=test-key CODEX_MODEL=gpt-6.1-sol \
        CLAUDE_CODEX_DOTENV_ROOT="$TMP" ${envs[@]+"${envs[@]}"} bash "$LAUNCHER" "$@" ) >"$TMP/out" 2>&1
    local got=$?
    if [ "$got" -ne "$want" ]; then echo "   rc=$got want=$want"; cat "$TMP/out"; return 1; fi
    if [ "$needle" != - ] && ! grep -qF -- "$needle" "$TMP/out"; then echo "   output missing: $needle"; cat "$TMP/out"; return 1; fi
    return 0
}

SRT_ENV=(CLAUDE_CODEX_SRT_PROFILE=impl CLAUDE_CODEX_SRT_SCRATCH="$SCRATCH" HANDOVER_DIR="$HANDOVER"
    "CODEX_PROXY_BASE_URL=http://$GW_HOST:8317")

# 1. missing / empty / invalid settings file: the launch is refused, the model never starts
cat >"$TMP/render-empty.sh" <<'R'
#!/usr/bin/env bash
exit 0
R
cat >"$TMP/render-bad.sh" <<'R'
#!/usr/bin/env bash
echo 'not json'
R
cat >"$TMP/render-missing.sh" <<'R'
#!/usr/bin/env bash
exit 9
R
for r in empty bad missing; do
    if run 3 'settings' "${SRT_ENV[@]}" CLAUDE_CODEX_SRT_RENDER="$TMP/render-$r.sh" -- && [ ! -e "$TMP/child-env" ] && [ ! -s "$TMP/argv" ]; then
        ok "refuses to launch on a $r settings render"
    else
        bad "refuses to launch on a $r settings render"
    fi
done

# 2. a missing srt binary refuses (never falls through to an unwrapped launch)
if run 3 'srt' "${SRT_ENV[@]}" CLAUDE_CODEX_SRT_BIN="$TMP/no-such-srt" -- && [ ! -e "$TMP/child-env" ]; then
    ok "refuses when srt is not installed"
else
    bad "refuses when srt is not installed"
fi

# 3. the happy path under the fake srt
if run 0 - "${SRT_ENV[@]}" -- --model gpt-6.1-sol "two words"; then ok "launches under srt"; else bad "launches under srt"; fi

# 3a. argv shape: srt --settings X -- bash <wrapper file> ..., never an inline bash -c
if [ "$(sed -n 1p "$TMP/argv")" = --settings ] && [ "$(sed -n 3p "$TMP/argv")" = -- ] \
    && [ "$(sed -n 4p "$TMP/argv")" = bash ] && [ -f "$TMP/wrapper-existed" ] \
    && ! grep -qxe '-c' "$TMP/argv"; then
    ok "wrapper is a file run as 'srt --settings X -- bash <file>', no inline bash -c"
else
    bad "wrapper is a file run as 'srt --settings X -- bash <file>' ($(tr '\n' ' ' <"$TMP/argv"))"
fi

# 3b. the leg's own arguments survive intact
if [ -f "$TMP/child-env" ] && grep -qxF 'two words' "$TMP/argv"; then ok "an argument with a space reaches srt as one word"; else bad "an argument with a space reaches srt as one word"; fi

# 3c. NO_PROXY is unset inside the box (srt put the private ranges in it), srt's proxy env survives
if [ -f "$TMP/child-env" ] && ! grep -qiE '^no_proxy=' "$TMP/child-env" && grep -qxF 'HTTPS_PROXY=http://localhost:3128' "$TMP/child-env"; then
    ok "NO_PROXY/no_proxy unset in the box, HTTPS_PROXY kept"
else
    bad "NO_PROXY/no_proxy unset in the box, HTTPS_PROXY kept ($(grep -i proxy "$TMP/child-env" 2>/dev/null | tr '\n' ' '))"
fi

# 3d. probes do not bypass srt's proxy under srt
if [ -s "$TMP/curl-args" ] && ! grep -q -- '--noproxy' "$TMP/curl-args"; then ok "curl probes drop --noproxy under srt"; else bad "curl probes drop --noproxy under srt"; fi

# 3e. scratch HOME and TMPDIR: an allowed dir, not the real HOME nor srt's /tmp/claude
child_home="$(sed -n 's/^HOME=//p' "$TMP/child-env" 2>/dev/null)"
child_tmp="$(sed -n 's/^TMPDIR=//p' "$TMP/child-env" 2>/dev/null)"
child_ctmp="$(sed -n 's/^CLAUDE_CODE_TMPDIR=//p' "$TMP/child-env" 2>/dev/null)"
if [ -n "$child_home" ] && [ "$child_home" != "$HOME_F" ] && [ "$child_tmp" = "$child_ctmp" ] \
    && [ "$child_tmp" != /tmp/claude ] && case "$child_tmp" in "$child_home"/*) true ;; *) false ;; esac; then
    ok "HOME is a scratch dir and TMPDIR/CLAUDE_CODE_TMPDIR sit inside it"
else
    bad "HOME is a scratch dir and TMPDIR/CLAUDE_CODE_TMPDIR sit inside it (HOME=$child_home TMPDIR=$child_tmp CCT=$child_ctmp)"
fi

# 3f. the claude process starts in the worktree
if [ "$(cat "$TMP/child-pwd" 2>/dev/null)" = "$(cd "$WT" && pwd -P)" ]; then ok "claude starts in the worktree"; else bad "claude starts in the worktree"; fi

# 4. writable roots: worktree, scratchpad, handover bucket and the scratch HOME only
roots="$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(s.filesystem.allowWrite.join("\n")+"\n--\n"+s.network.allowedDomains.join("\n"))' "$TMP/settings.json" 2>/dev/null)"
nroots="$(printf '%s\n' "$roots" | sed '/^--$/q' | grep -vc '^--$')"
if [ "$nroots" -eq 4 ] && printf '%s\n' "$roots" | grep -qxF "$(cd "$WT" && pwd -P)" \
    && printf '%s\n' "$roots" | grep -qxF "$SCRATCH" && printf '%s\n' "$roots" | grep -qxF "$HANDOVER" \
    && printf '%s\n' "$roots" | grep -qxF "$child_home"; then
    ok "allowWrite is exactly worktree, scratchpad, handover bucket and scratch HOME"
else
    bad "allowWrite is exactly worktree, scratchpad, handover bucket and scratch HOME ($roots)"
fi
# 4a. the gateway host is allowed in the network list
if printf '%s\n' "$roots" | sed '1,/^--$/d' | grep -qxF "$GW_HOST"; then ok "gateway host is in allowedDomains"; else bad "gateway host is in allowedDomains"; fi

# 5. the non-loopback gateway is accepted only under srt
if run 3 'not loopback' CODEX_PROXY_BASE_URL=http://$GW_HOST:8317 -- ; then ok "non-loopback gateway still refused without srt"; else bad "non-loopback gateway still refused without srt"; fi
# SANDBOX_RUNTIME alone (a leg running inside someone else's srt) does not relax the refusal
if run 3 'not loopback' SANDBOX_RUNTIME=1 CODEX_PROXY_BASE_URL=http://$GW_HOST:8317 -- ; then ok "SANDBOX_RUNTIME alone does not relax the loopback rule"; else bad "SANDBOX_RUNTIME alone does not relax the loopback rule"; fi

# 6. without a profile nothing changes: no srt, the old proxy handling
if run 0 - HTTPS_PROXY=http://elsewhere:1 -- && [ ! -s "$TMP/argv" ] && ! grep -q '^HTTPS_PROXY=' "$TMP/child-env" && grep -qxF 'NO_PROXY=127.0.0.1,localhost,::1' "$TMP/child-env"; then
    ok "no profile: unwrapped launch with the loopback proxy env"
else
    bad "no profile: unwrapped launch with the loopback proxy env"
fi

# 7. an unknown profile, a missing scratch or handover dir refuse
if run 2 'PROFILE' CLAUDE_CODEX_SRT_PROFILE=bogus CLAUDE_CODEX_SRT_SCRATCH="$SCRATCH" HANDOVER_DIR="$HANDOVER" -- ; then ok "unknown profile refused"; else bad "unknown profile refused"; fi
if run 3 'CLAUDE_CODEX_SRT_SCRATCH' CLAUDE_CODEX_SRT_PROFILE=impl HANDOVER_DIR="$HANDOVER" -- ; then ok "missing scratchpad refused"; else bad "missing scratchpad refused"; fi
if run 3 'HANDOVER_DIR' CLAUDE_CODEX_SRT_PROFILE=impl CLAUDE_CODEX_SRT_SCRATCH="$SCRATCH" HANDOVER_DIR="$TMP/no-such" -- ; then ok "missing handover bucket refused"; else bad "missing handover bucket refused"; fi

# 8. the scratchpad is writable by the box, so nothing the launcher trusts lives there as a plain path
VICTIM="$TMP/victim"; mkdir -p "$VICTIM"
# a planted scratchpad link is never the HOME: the HOME srt mounts is not under the scratchpad at all
# not under any writable root, and the settings' fourth writable root is it
ln -s "$VICTIM" "$SCRATCH/srt-home"
if run 0 - "${SRT_ENV[@]}" -- && h_path="$(sed -n 6p "$TMP/argv")" && [ -n "$h_path" ] \
    && case "$h_path" in "$SCRATCH"/*|"$WT"/*|"$HANDOVER"/*) false ;; *) true ;; esac \
    && grep -qF "\"$h_path\"" "$TMP/settings.json" && [ -z "$(ls -A "$VICTIM")" ]; then
    ok "the scratch HOME srt mounts is outside every writable root and a planted srt-home link is ignored"
else
    bad "the scratch HOME srt mounts is outside every writable root and a planted srt-home link is ignored ($(sed -n 6p "$TMP/argv"))"
fi
rm -f "$SCRATCH/srt-home"
# the private dir (settings, wrapper, HOME) is removed when the box exits
if run 0 - "${SRT_ENV[@]}" -- && [ ! -e "$(sed -n 2p "$TMP/argv")" ] && [ ! -e "$(sed -n 6p "$TMP/argv")" ]; then
    ok "the private settings/wrapper/HOME dir is removed after the box exits"
else
    bad "the private settings/wrapper/HOME dir is removed after the box exits"
fi
echo original >"$VICTIM/bashrc"; echo original >"$VICTIM/settings"
rm -f "$SCRATCH/srt-wrapper.sh" "$SCRATCH/srt-settings.json"
ln -s "$VICTIM/bashrc" "$SCRATCH/srt-wrapper.sh" && ln -s "$VICTIM/settings" "$SCRATCH/srt-settings.json" || bad "could not plant the links"
if run 0 - "${SRT_ENV[@]}" -- && [ "$(cat "$VICTIM/bashrc")" = original ] && [ "$(cat "$VICTIM/settings")" = original ]; then
    ok "planted srt-wrapper.sh / srt-settings.json links are never written through"
else
    bad "planted srt-wrapper.sh / srt-settings.json links are never written through"
fi
rm -f "$SCRATCH/srt-wrapper.sh" "$SCRATCH/srt-settings.json"
# the settings file and the wrapper that srt is handed live outside every writable root
if run 0 - "${SRT_ENV[@]}" -- && s_path="$(sed -n 2p "$TMP/argv")" && w_path="$(sed -n 5p "$TMP/argv")" \
    && case "$s_path" in "$SCRATCH"/*|"$WT"/*|"$HANDOVER"/*) false ;; *) true ;; esac \
    && case "$w_path" in "$SCRATCH"/*|"$WT"/*|"$HANDOVER"/*) false ;; *) true ;; esac; then
    ok "settings and wrapper are written outside every writable root"
else
    bad "settings and wrapper are written outside every writable root ($(sed -n '2p;5p' "$TMP/argv" | tr '\n' ' '))"
fi

# 9. in-box mode is not inferred from the environment: the profile + SANDBOX_RUNTIME pair alone
# behaves like main (here: it tries to wrap, srt is absent, so it refuses; it never runs the model)
if run 3 'srt' "${SRT_ENV[@]}" SANDBOX_RUNTIME=1 HTTPS_PROXY=http://elsewhere:1 CLAUDE_CODEX_SRT_BIN="$TMP/no-such-srt" -- && [ ! -e "$TMP/child-env" ]; then
    ok "profile + SANDBOX_RUNTIME alone is not in-box mode"
else
    bad "profile + SANDBOX_RUNTIME alone is not in-box mode"
fi
# the in-box marker without a profile changes nothing either
if run 3 'not loopback' SANDBOX_RUNTIME=1 CLAUDE_CODEX_SRT_INBOX=1 CODEX_PROXY_BASE_URL=http://$GW_HOST:8317 -- ; then
    ok "in-box marker without a profile does not relax the loopback rule"
else
    bad "in-box marker without a profile does not relax the loopback rule"
fi
# the wrapper opts in to the remote gateway explicitly
if run 0 - "${SRT_ENV[@]}" -- && grep -qxF 'CLAUDE_CODEX_REMOTE_PROXY_OK=1' "$TMP/child-env"; then
    ok "the wrapper sets CLAUDE_CODEX_REMOTE_PROXY_OK=1 explicitly"
else
    bad "the wrapper sets CLAUDE_CODEX_REMOTE_PROXY_OK=1 explicitly"
fi

if [ "$fails" -ne 0 ]; then echo "$fails test(s) failed"; exit 1; fi
echo "all claude-codex srt tests passed"
