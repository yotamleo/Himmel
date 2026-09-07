#!/usr/bin/env bash
# Smoke test for scripts/lib/run-node.sh.
# Usage: bash scripts/lib/test-run-node.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
RUN="$REPO_ROOT/scripts/lib/run-node.sh"
[ -f "$RUN" ] || { echo "FAIL: $RUN not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# A realistic "node not on PATH" still needs coreutils — but on apt-node
# systems node LIVES in the coreutils dir (/usr/bin, HIMMEL-966), so use
# a curated symlink dir carrying only the tools these cases need.
UTILS_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-utils.XXXXXX")"
trap 'rm -rf "$UTILS_ROOT"' EXIT
UTILS_DIR="$UTILS_ROOT/utils"
mkdir -p "$UTILS_DIR"
for _t in bash dirname sort tail cat mkdir date; do
    _p="$(command -v "$_t" 2>/dev/null)" && ln -s "$_p" "$UTILS_DIR/$_t" 2>/dev/null
done
# Windows Git Bash: a symlink/copy of an MSYS tool loses its msys-2.0.dll
# neighborhood and won't run — probe, then fall back to the coreutils dir
# (node is never colocated with coreutils on those hosts).
if ! PATH="$UTILS_DIR" bash -c 'sort </dev/null >/dev/null 2>&1 && command -v dirname >/dev/null' 2>/dev/null; then
    UTILS_DIR="$(dirname "$(command -v sort)")"
    # Self-diagnose the one bad combination (fallback dir DOES carry node —
    # the HIMMEL-966 apt-node class): the PATH-cleared cases below will fail;
    # say why up front instead of leaving a puzzling red run.
    if [ -x "$UTILS_DIR/node" ] || [ -x "$UTILS_DIR/node.exe" ]; then
        echo "WARN: curated utils dir unusable AND fallback $UTILS_DIR carries node — PATH-cleared cases will fail (HIMMEL-966)" >&2
    fi
fi

# A fake node: $1 is the "script" path (we route on its basename), rest are args.
make_fake_node() {
    local dir="$1"; mkdir -p "$dir"
    cat > "$dir/node" <<'EOF'
#!/bin/sh
case "$1" in
  *echo-args*) shift; printf 'args:%s\n' "$*" ;;
  *echo-stdin*) cat ;;
  *exit42*) exit 42 ;;
  *) printf 'ran:%s\n' "$1" ;;
esac
EOF
    chmod +x "$dir/node"
}

# Every case below hands run-node.sh the SAME four-var sandbox prefix. All four
# are load-bearing: RESOLVE_NODE_PROBE_DIRS replaces resolve-node.sh's step-3
# well-known-locations list, but step 1 (NVM_SYMLINK + its hardcoded
# /c/nvm4w/nodejs default, via RESOLVE_NODE_NVM4W_DIR) is probed BEFORE both
# PATH and step 3 and stays live under that seam — so on an nvm-windows host
# the REAL node wins and the fake is never consulted (HIMMEL-2252; the seam was
# narrowed to this contract in HIMMEL-2077 and these cases still assumed the
# old one). RESOLVE_NODE_NVM4W_DIR must be set-but-EMPTY, not unset: the
# resolver reads it with ${VAR-default}. Drop any of the four and the case
# silently passes against the host's real node instead of the fake.
echo "== run-node: args pass through + stdout =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-args.XXXXXX")"; make_fake_node "$tmp/bin"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/echo-args.js" A B)"
if [ "$out" = "args:A B" ]; then pass "args -> '$out'"; else fail "args -> '$out'"; fi
rm -rf "$tmp"

echo "== run-node: exit code propagates =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-exit.XXXXXX")"; make_fake_node "$tmp/bin"
PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/exit42.js" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 42 ]; then pass "exit -> 42"; else fail "exit -> $rc (want 42)"; fi
rm -rf "$tmp"

echo "== run-node: stdin reaches the child =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-stdin.XXXXXX")"; make_fake_node "$tmp/bin"
out="$(printf 'PAYLOAD-123' | PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$tmp/bin" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" bash "$RUN" "$tmp/echo-stdin.js")"
if [ "$out" = "PAYLOAD-123" ]; then pass "stdin -> '$out'"; else fail "stdin -> '$out'"; fi
rm -rf "$tmp"

echo "== run-node: no node -> silent, exit 0, one log line =="
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-nonode.XXXXXX")"; cdir="$tmp/claude"
out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" CLAUDE_DIR="$cdir" bash "$RUN" "$tmp/hook.js" 2>"$tmp/err.txt")"
rc=$?
err="$(cat "$tmp/err.txt")"
logc=0; [ -f "$cdir/himmel-node.log" ] && logc="$(wc -l < "$cdir/himmel-node.log" | tr -d ' ')"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ] && [ "$logc" = "1" ]; then
    pass "no-node -> rc0, silent, 1 log line"
else
    fail "no-node -> rc=$rc out='$out' err='$err' logc=$logc"
fi
rm -rf "$tmp"

echo "== run-node: the wired plugin-hook launcher chain fires with node off PATH (HIMMEL-2047) =="
# HIMMEL-2015 gave run-node.sh to individual project hook scripts but left
# every marketplace/plugins/himmel-ops/hooks/hooks.json entry (and
# .claude/settings.json's) invoking run-hook-with-bash.js via a bare `node` —
# which the 2026-08-22 nvm-windows migration proved unresolvable mid-session,
# silently dropping every SessionEnd guardrail. HIMMEL-2047 routes those
# launchers through this same resolver (wire-plugin-hook-bash.mjs's
# wiredCommand()); this reproduces one verbatim, with node off PATH, and
# proves the target hook script still runs end to end.
tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-run-node-plugin-launcher.XXXXXX")"
real_node="$(command -v node 2>/dev/null || true)"
if [ -z "$real_node" ]; then
    echo "  SKIP: no real node on PATH to resolve against"
else
    node_dir="$(dirname "$real_node")"
    hook_dir="$tmp/hooks"; mkdir -p "$hook_dir"
    cat > "$hook_dir/marker-hook.sh" <<'EOF'
#!/usr/bin/env bash
echo HOOK_FIRED
EOF
    chmod +x "$hook_dir/marker-hook.sh"
    # The exact launcher shape wire-plugin-hook-bash.mjs wires into every
    # hooks.json entry (and wire-hook-bash.mjs into settings.json): sourced
    # run-node.sh resolves node at runtime and execs run-hook-with-bash.js,
    # which spawns the target hook under a resolved bash. Only the final
    # target is swapped for the harmless marker script above.
    cmd=". \"$REPO_ROOT/scripts/lib/run-node.sh\" \"$REPO_ROOT/scripts/hooks/run-hook-with-bash.js\" \"$hook_dir/marker-hook.sh\""
    out="$(PATH="$UTILS_DIR" RESOLVE_NODE_PROBE_DIRS="$node_dir" NVM_SYMLINK="" RESOLVE_NODE_NVM4W_DIR="" RESOLVE_NODE_NVM_ROOT="$tmp/none" FNM_DIR="$tmp/none" HOME="${HOME:-}" CLAUDE_PROJECT_DIR="$REPO_ROOT" bash -c "$cmd" 2>"$tmp/err.txt")"
    rc=$?
    err="$(cat "$tmp/err.txt")"
    if [ "$rc" -eq 0 ] && [ "$out" = "HOOK_FIRED" ]; then
        pass "plugin-hook launcher fires with node off PATH (out='$out')"
    else
        fail "plugin-hook launcher with node off PATH -> rc=$rc out='$out' err='$err'"
    fi
fi
rm -rf "$tmp"


# ---------------------------------------------------------------------------
# HIMMEL-2692: run-node.sh is SOURCED by hook commands, and Claude Code runs
# those through /bin/sh — dash on Debian/Ubuntu. A bash-only expansion there is
# fatal (`${BASH_SOURCE[0]}` -> "Bad substitution" -> empty dir -> the `.` fails
# -> rc=2 -> a PreToolUse DENY on EVERY tool call). Neither a bash-run smoke
# test nor `sh -n` on a bash-is-/bin/sh host can see that, so the controls below
# are (a) a literal ban on the expansion in BOTH copies, and (b) an end-to-end
# source of each copy under every NON-BASH POSIX shell this host actually has.
# ---------------------------------------------------------------------------
PLUGIN_HOOKS="$REPO_ROOT/marketplace/plugins/himmel-ops/hooks"
# A bash array, not a whitespace-joined string: a checkout path containing a
# space would otherwise word-split into nonexistent fragments and the checks
# below would silently inspect nothing (codex-4 on the HIMMEL-2692 panel).
COPIES=("$REPO_ROOT/scripts/lib/run-node.sh" "$PLUGIN_HOOKS/run-node.sh")
# HIMMEL-2741: run-node.sh's own body is clean POSIX, but it SOURCES
# resolve-node.sh — a bash-only expansion there (${var//pat/repl}) aborted the
# sourced file under dash exactly the way BASH_SOURCE aborted run-node.sh
# itself, and neither check below saw it because both file lists covered only
# the two run-node.sh copies, not what they source. Cover both files each
# copy actually sources at runtime.
SOURCED_COPIES=("$REPO_ROOT/scripts/lib/resolve-node.sh" "$PLUGIN_HOOKS/resolve-node.sh")
ALL_COPIES=("${COPIES[@]}" "${SOURCED_COPIES[@]}")

echo "== run-node: zero args -> refuse loudly with rc=2, one stderr line (HIMMEL-2758) =="
# A launcher reached with NO script argument has lost its payload — most
# likely a `. run-node.sh <args>` wiring, whose operands dash drops silently
# (see run-node.sh's own header). Confirm the guard added immediately after
# `set -u` fires the same way for both copies under both bash (unaffected by
# the dash bug) and dash (the actual failing platform) — an empty "$@" must
# never again reach the silent `exec "$_node" "$@"` path.
for f in "${COPIES[@]}"; do
    rel="${f#"$REPO_ROOT/"}"
    for shell in bash dash; do
        if ! command -v "$shell" >/dev/null 2>&1; then
            echo "  SKIP: $shell not installed ($rel, 0 args)"
            continue
        fi
        zerr="$UTILS_ROOT/zeroarg-err.txt"
        out="$("$shell" "$f" 2>"$zerr")"
        rc=$?
        errlines="$(wc -l < "$zerr" | tr -d ' ')"
        if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ "$errlines" = "1" ]; then
            pass "$shell $rel (0 args) -> rc=2, 1 stderr line"
        else
            fail "$shell $rel (0 args) -> rc=$rc out='$out' errlines=$errlines"
        fi
    done
done

echo "== run-node: no bash-only expansions in any sourced file's CODE (HIMMEL-2692/2741) =="
# BASH_SOURCE is the run-node.sh-class bashism; \${*//...} / \${*^^} / \${*,,}
# are the resolve-node.sh-class one (HIMMEL-2741: \${var//\\//} aborted dash
# with "Bad substitution" the same way BASH_SOURCE did). Grep is deliberately
# generic (\$\{[A-Za-z_][A-Za-z0-9_]*\(\[[^]]*\]\)\?\(//\|\^\^\|,,\)) rather than
# a literal-string list, so the NEXT bash-only parameter expansion in this
# family is also caught, not just the two that have already bitten us.
BASHISM_PATTERN='BASH_SOURCE|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(//|\^\^|,,)'
for f in "${ALL_COPIES[@]}"; do
    rel="${f#"$REPO_ROOT/"}"
    n="$(grep -v '^[[:space:]]*#' "$f" | grep -Ec "$BASHISM_PATTERN" || true)"
    if [ "$n" = "0" ]; then pass "no bash-only expansion in executable lines of $rel"; else fail "$rel still uses a bash-only expansion in code (${n}x) — dash cannot parse it"; fi
done

echo "== run-node: shellcheck -s sh is clean on every copy, including what it sources (HIMMEL-2692/2741) =="
if command -v shellcheck >/dev/null 2>&1; then
    for f in "${ALL_COPIES[@]}"; do
        rel="${f#"$REPO_ROOT/"}"
        if sc_out="$(shellcheck -s sh -S error "$f" 2>&1)"; then
            pass "shellcheck -s sh clean: $rel"
        else
            fail "shellcheck -s sh on $rel: $sc_out"
        fi
    done
else
    echo "  SKIP: shellcheck not installed"
fi

echo "== run-node: run (via sh, not sourced via .) under a NON-BASH POSIX shell the launcher chain still fires (HIMMEL-2692/2758) =="
# Candidate POSIX shells, most faithful to the reported platform first. dash is
# the exact Debian/Ubuntu /bin/sh; busybox ash and zsh's sh emulation are the
# same class (no BASH_SOURCE, and $0 = the SHELL when a file is sourced).
# Whatever this host has is used; a host with NONE of them prints a loud SKIP
# rather than a green tick, because bash alone cannot reproduce the defect.
posix_shells=''
# /usr/lib/initcpio/busybox is Arch's mkinitcpio busybox — not on PATH, but a
# REAL ash (dash-family) shell, so on a host with no dash it still exercises
# the actual failing platform semantics rather than only zsh's sh emulation.
for _c in dash "busybox sh" "/usr/lib/initcpio/busybox sh" "zsh --emulate sh" mksh yash posh ksh; do
    # shellcheck disable=SC2086  # deliberate word-split: $_c is a shell + flags
    set -- $_c
    command -v "$1" >/dev/null 2>&1 || continue
    posix_shells="${posix_shells}${posix_shells:+|}$_c"
done
if [ -z "$posix_shells" ]; then
    echo "  SKIP: no non-bash POSIX shell on this host (dash/busybox/zsh/mksh/yash/posh/ksh) — the dash path is UNVERIFIED here"
elif ! command -v node >/dev/null 2>&1; then
    echo "  SKIP: no real node on PATH to resolve against"
else
    if ! command -v dash >/dev/null 2>&1; then
        # busybox ash IMPLEMENTS BOTH bashisms found so far — the parameter
        # expansion \${var//pat/repl} (HIMMEL-2741) AND dot-with-operands
        # (HIMMEL-2758: POSIX leaves `.` with operands beyond the filename
        # UNSPECIFIED; dash drops them, busybox ash does not) — so a
        # busybox/zsh/mksh/etc PASS below is NEVER evidence dash would also
        # pass. Say so loudly instead of a silent green tick.
        echo "  SKIP: dash absent — busybox ash is NOT a dash substitute for parameter-expansion or dot-with-operands bashisms (HIMMEL-2741/2758)"
    fi
    # Under $UTILS_ROOT so the file-scope EXIT trap cleans it up.
    ptmp="$UTILS_ROOT/posix"; mkdir -p "$ptmp/hooks"
    cat > "$ptmp/hooks/marker-hook.sh" <<'EOF'
#!/usr/bin/env bash
echo HOOK_FIRED
EOF
    chmod +x "$ptmp/hooks/marker-hook.sh"
    _save_ifs="$IFS"
    IFS='|'
    for sh_cmd in $posix_shells; do
        IFS="$_save_ifs"
        # HIMMEL-2758: exercises the shape actually WIRED — `sh run-node.sh
        # <args>`, run as a child process, not `. run-node.sh <args>`
        # (sourced) — which is exactly the dot shape HIMMEL-2758 removed from
        # every wired hook command (dash drops a sourced `.`'s operands; a run
        # child process always gets its own argv).
        #
        # NOTE on env_root below: with direct/run execution (both launcher
        # shapes below, as opposed to sourcing), $0 names run-node.sh itself, so
        # run-node.sh's `case "$0" in */run-node.sh|run-node.sh)` branch
        # (scripts/lib/run-node.sh:60-66) fires and resolves resolve-node.sh
        # from the FILE'S OWN directory — the CLAUDE_PROJECT_DIR /
        # CLAUDE_PLUGIN_ROOT env-root lanes below are NOT reached on this
        # path. The env_root split is kept for readability (it still selects
        # which copy this iteration targets) but is NOT evidence about the
        # env-root lanes; this leg only proves the launcher chain fires end to
        # end and HOOK_FIRED reaches stdout under each POSIX shell. The
        # env-root lanes themselves are still exercised — by the HIMMEL-2702
        # damaged-plugin-install leg below. That leg also runs run-node.sh via
        # `sh`, but its plugin root deliberately has NO sibling
        # resolve-node.sh, so the `$0` case finds nothing readable, leaves
        # _script_dir empty, and control falls through to the
        # CLAUDE_PLUGIN_ROOT lane — which is precisely the lane that leg
        # asserts on. Neither leg is vacuous; they just enter the resolver at
        # different points.
        for which in repo plugin; do
            if [ "$which" = repo ]; then
                copy="$REPO_ROOT/scripts/lib/run-node.sh"
                env_root="CLAUDE_PROJECT_DIR=$REPO_ROOT"
            else
                copy="$PLUGIN_HOOKS/run-node.sh"
                env_root="CLAUDE_PLUGIN_ROOT=$REPO_ROOT/marketplace/plugins/himmel-ops"
            fi
            # [codex-1] TWO launchers, and the second one is the load-bearing
            # control. `sh` is the shape production actually wires — but a bare
            # `sh` resolves to /bin/sh, which on THIS station is bash
            # (/bin/sh -> /usr/bin/bash). So `dash -c 'sh run-node.sh …'`
            # proves only that the outer shell can spawn the launcher; the
            # BODY of run-node.sh still executes under bash, and a
            # dash-incompatible expansion inside it (the HIMMEL-2741 class)
            # would sail straight through. Executing the copy with $sh_cmd
            # DIRECTLY is what puts run-node.sh's own body under dash. Keep
            # both: drop the `sh` launcher and you stop testing the wired
            # shape; drop the direct one and the dash leg is bash in a hat.
            for launcher in "command -p sh" "$sh_cmd"; do
                cmd="$launcher \"$copy\" \"$REPO_ROOT/scripts/hooks/run-hook-with-bash.js\" \"$ptmp/hooks/marker-hook.sh\""
                # Run from a neutral cwd: when a file is sourced, `dirname $0` is
                # ".", and a cwd that happened to hold resolve-node.sh would mask a
                # broken env-root lookup.
                # shellcheck disable=SC2086  # deliberate word-split: $sh_cmd is a shell + flags
                out="$(cd "$ptmp" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT "$env_root" $sh_cmd -c "$cmd" 2>"$ptmp/err.txt")"
                rc=$?
                err="$(cat "$ptmp/err.txt")"
                if [ "$launcher" = "command -p sh" ]; then _lane="wired shape via \`command -p sh\`"; else _lane="$launcher DIRECTLY (body under $sh_cmd)"; fi
                if [ "$rc" -eq 0 ] && [ "$out" = "HOOK_FIRED" ]; then
                    pass "$sh_cmd + $which copy, $_lane -> HOOK_FIRED rc=0"
                else
                    fail "$sh_cmd + $which copy, $_lane -> rc=$rc out='$out' err='$err'"
                fi
            done
        done
        IFS='|'
    done
    IFS="$_save_ifs"
fi

echo "== run-node: a damaged plugin install NEVER sources the repo under review (HIMMEL-2702) =="
# The cross-trust vector this closes: resolve-node.sh is SOURCED, not executed,
# so a resolver found under CLAUDE_PROJECT_DIR — the repo UNDER REVIEW — runs
# that repo's shell code in the hook's own shell. The old candidate list tried
# the plugin root and then FELL THROUGH to the project root, so a damaged or
# mid-upgrade plugin install (plugin resolver missing/unreadable) would source
# whatever the adopter's repo happened to ship at scripts/lib/resolve-node.sh,
# and a hostile repo could plant one. The lanes are mutually exclusive now: with
# CLAUDE_PLUGIN_ROOT set, a missing plugin resolver must take the FAIL-OPEN path
# (breadcrumb + rc 0), never the project one.
ltmp="$UTILS_ROOT/lane"
mkdir -p "$ltmp/plugin/hooks" "$ltmp/hostile/scripts/lib" "$ltmp/claude"
# Plugin root that is DAMAGED: run-node.sh present, resolve-node.sh ABSENT.
cp "$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/run-node.sh" "$ltmp/plugin/hooks/run-node.sh"
# The "hostile" repo under review: a resolver that drops a marker if sourced.
cat > "$ltmp/hostile/scripts/lib/resolve-node.sh" <<EOF
: > "$ltmp/PWNED"
resolve_node() { return 1; }
EOF
# HIMMEL-2758: run via `sh` (the WIRED shape, not sourced via `.`) — this is
# the actual security control in production, so the leg exercises it, not the
# dot shape HIMMEL-2758 removed. Under `sh` the `$0` case at run-node.sh:60
# fires first and probes $ltmp/plugin/hooks/resolve-node.sh — ABSENT by
# construction above — so _script_dir stays empty and the CLAUDE_PLUGIN_ROOT
# lane under test is still the one that decides. The `$0` case cannot mask
# this leg: its candidate directory IS the plugin root.
lane_out="$(cd "$ltmp" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
    CLAUDE_PLUGIN_ROOT="$ltmp/plugin" CLAUDE_PROJECT_DIR="$ltmp/hostile" \
    CLAUDE_DIR="$ltmp/claude" \
    sh -c "sh \"$ltmp/plugin/hooks/run-node.sh\" hook.js" 2>&1)"
lane_rc=$?
if [ -e "$ltmp/PWNED" ]; then
    fail "damaged plugin install SOURCED the repo under review (rc=$lane_rc out='$lane_out')"
else
    pass "damaged plugin install did not source the repo under review"
fi
# ...and it must fail OPEN, not deny: rc 0, silent, one breadcrumb line.
if [ "$lane_rc" -eq 0 ] && [ -z "$lane_out" ]; then
    pass "damaged plugin install fails open (rc=0, silent)"
else
    fail "damaged plugin install did not fail open -> rc=$lane_rc out='$lane_out'"
fi

echo "== run-node: the wired \`command -p sh\` launcher resolves under a HOSTILE PATH (HIMMEL-2758) =="
# [codex-1 r2 + r4] Replacing the `.` BUILTIN with an external launcher adds a
# PATH lookup the dot form never needed, and the platform this harness must
# survive is the GUI/agent launch with a pinned minimal PATH (the same class as
# the C6-mcp / C6-hooks doctor checks). TWO PATH shapes, because they fail for
# DIFFERENT reasons and only one of them was pinned before:
#
#   unset       exec falls back to the confstr default (/bin:/usr/bin), so even
#               a bare `sh` resolves. This case always passed.
#   /nonexistent  a SET but useless PATH gets no confstr fallback. A bare `sh`
#               dies rc=127 BEFORE run-node.sh runs at all — and the r2 note
#               that used to sit here claimed this case was uncoverable because
#               "the `else` fallback's `node` is equally unresolvable". That
#               was measured against the WRONG artifact: the `else` branch is
#               reached only when run-node.sh is MISSING, and resolve_node()
#               never consults PATH for node anyway — its step 3 probes
#               ABSOLUTE well-known locations (/usr/bin, homebrew, …). So the
#               dot form DID survive a hostile PATH, and a bare-`sh` wiring
#               would have traded a dash-only silent no-op for a
#               restricted-PATH dead chain. `command -p sh` — POSIX for "search
#               the standard utilities PATH" — is what closes it.
#
# Neither case is self-fulfilling: PATH is unset outright or pointed somewhere
# empty, never narrowed to a directory that happens to hold `sh` as well (node
# lives in /usr/bin on this host, and so does sh — pinning PATH there would
# assert nothing). Both shapes actually VARY the suspected cause.
if ! command -v node >/dev/null 2>&1; then
    echo "  SKIP: no real node on PATH to resolve against"
else
    nptmp="$UTILS_ROOT/nopath"; mkdir -p "$nptmp/hooks"
    cat > "$nptmp/hooks/marker-hook.sh" <<'EOF'
#!/usr/bin/env bash
echo HOOK_FIRED
EOF
    chmod +x "$nptmp/hooks/marker-hook.sh"
    for which in repo plugin; do
        if [ "$which" = repo ]; then
            copy="$REPO_ROOT/scripts/lib/run-node.sh"
        else
            copy="$PLUGIN_HOOKS/run-node.sh"
        fi
        for path_shape in unset hostile; do
            # `env` parses options only BEFORE the first NAME=VALUE, so the
            # PATH shape must TRAIL the -u flags: `env PATH=x -u FOO` treats
            # `-u` as the command name and exits 127 — which would look exactly
            # like the rc=127 this leg is trying to detect.
            if [ "$path_shape" = unset ]; then
                path_env="-u PATH"
            else
                path_env="PATH=/nonexistent"
            fi
            # shellcheck disable=SC2086  # deliberate word-split: $path_env is a flag or an assignment
            out="$(cd "$nptmp" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT $path_env /bin/sh -c "command -p sh \"$copy\" \"$REPO_ROOT/scripts/hooks/run-hook-with-bash.js\" \"$nptmp/hooks/marker-hook.sh\"" </dev/null 2>"$nptmp/err.txt")"
            rc=$?
            err="$(cat "$nptmp/err.txt")"
            if [ "$rc" -eq 0 ] && [ "$out" = "HOOK_FIRED" ]; then
                pass "$which copy launches via \`command -p sh\` with PATH $path_shape -> HOOK_FIRED rc=0"
            else
                fail "$which copy failed to launch with PATH $path_shape -> rc=$rc out='$out' err='$err'"
            fi
        done
    done

    # NEGATIVE control: the superseded bare-`sh` launcher must FAIL under the
    # hostile PATH. Without this the leg above could pass for the wrong reason
    # (e.g. if some ambient PATH leaked in), and there would be no evidence the
    # `command -p` prefix is doing anything at all.
    bare_out="$(cd "$nptmp" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_PLUGIN_ROOT PATH=/nonexistent /bin/sh -c "sh \"$REPO_ROOT/scripts/lib/run-node.sh\" \"$REPO_ROOT/scripts/hooks/run-hook-with-bash.js\" \"$nptmp/hooks/marker-hook.sh\"" </dev/null 2>&1)"
    bare_rc=$?
    if [ "$bare_rc" -eq 127 ]; then
        pass "negative control: the superseded bare \`sh\` launcher dies rc=127 under the same hostile PATH"
    else
        fail "negative control did NOT fail as expected -> rc=$bare_rc out='$bare_out' (the hostile-PATH leg above proves nothing)"
    fi
fi

echo "== run-node: no LIVE hook command wires run-node.sh via dot-source (HIMMEL-2758) =="
# The invocation-convention gate: every run-node.sh-mentioning hook command in
# the live settings/hooks files must use the WIRED shape
# (`command -p sh "…run-node.sh" <args>`, run as a child process). BOTH
# superseded launcher tokens are banned, for different reasons:
#
#   `. "…run-node.sh" <args>`   sourced — POSIX leaves operands beyond the
#                               filename unspecified and dash silently DROPS
#                               them, so the hook was a no-op on Debian/Ubuntu.
#   `sh "…run-node.sh" <args>`  a bare PATH lookup the `.` builtin never
#                               needed — dies rc=127 before the chain starts on
#                               any host whose PATH excludes the shell's dir,
#                               where the dot form still worked (resolve_node()
#                               finds node at ABSOLUTE paths, never via PATH).
#
# The patterns tolerate the backslash-escaped quotes JSON serializes a command
# string with (`\"…\"`), and the bare-`sh` pattern is anchored on the
# preceding `then `/`": "` so it cannot match the `command -p sh` form, which
# contains the token `sh` itself. This leg is RED against main before
# HIMMEL-2758: `git show origin/main:.claude/settings.json` matches 14 times.
DOT_WIRE_RE='\. \\?"[^"]*run-node\.sh\\?"'
BARE_SH_WIRE_RE='(then |": \\?")sh \\?"[^"]*run-node\.sh\\?"'
for f in "$REPO_ROOT/.claude/settings.json" "$PLUGIN_HOOKS/hooks.json"; do
    rel="${f#"$REPO_ROOT/"}"
    if [ ! -f "$f" ]; then
        echo "  SKIP: $rel not found (public mirror / adopter checkout lacks the private fixture)"
        continue
    fi
    n="$(grep -Ec "$DOT_WIRE_RE" "$f" || true)"
    if [ "$n" = "0" ]; then
        pass "$rel carries no dot-wired run-node.sh launcher"
    else
        fail "$rel still wires run-node.sh via dot-source (${n}x) — dash silently drops its operands"
    fi
    n="$(grep -Ec "$BARE_SH_WIRE_RE" "$f" || true)"
    if [ "$n" = "0" ]; then
        pass "$rel carries no bare-\`sh\` run-node.sh launcher"
    else
        fail "$rel still wires run-node.sh via a bare \`sh\` (${n}x) — rc=127 under a restricted PATH; use \`command -p sh\`"
    fi
done

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
