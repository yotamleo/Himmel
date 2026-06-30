#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-minerva-scripts-resolution.sh -- HIMMEL-606. The minerva SKILL.md embeds a
# scripts-dir resolver (twice: Mode + Terminal) so it can invoke autonomy-mode.sh
# / legs.sh even when CLAUDE_PLUGIN_ROOT is empty (a Codex skill shell). This test
# EXTRACTS that resolver from the SKILL.md (single source of truth, so the test
# can't drift from the prose), exercises every branch, and asserts the two copies
# are byte-identical. bash-only (the resolver is bash inside the skill). Needs git.
# Mirrors test-himmel-update-cmd-resolution.sh.
set -u
unset CLAUDE_PLUGIN_ROOT HIMMEL_REPO 2>/dev/null || true
here="$(cd "$(dirname "$0")" && pwd)"
skill="$here/../skills/minerva/SKILL.md"
[ -f "$skill" ] || { echo "FATAL: $skill not found"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required for the git-toplevel case"; exit 2; }
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# Extract the Nth resolver block (inclusive of its >>> / <<< marker lines).
extract_block(){ awk -v n="$2" '/# >>> himmel-ops scripts resolver/{c++; if(c==n)f=1} f{print} /# <<< himmel-ops scripts resolver/{if(f)exit}' "$1"; }
snippet="$(extract_block "$skill" 1)"
[ -n "$snippet" ] || { echo "FATAL: could not extract resolver snippet from $skill"; exit 2; }

# Run the snippet in a subshell under the caller's env/CWD; echo the resolved $S.
run_resolver(){ ( eval "$snippet"; printf '%s' "$S" ) 2>/dev/null; }

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
mk_scripts(){ mkdir -p "$1"; : > "$1/autonomy-mode.sh"; }            # the S sentinel
mk_repo(){ mkdir -p "$1/scripts/lib"; : > "$1/scripts/lib/initiative-legs.sh"; mk_scripts "$1/marketplace/plugins/himmel-ops/scripts"; }

# (i) CLAUDE_PLUGIN_ROOT set + valid -> $CLAUDE_PLUGIN_ROOT/scripts (Claude Code).
cpr="$td/cpr"; mk_scripts "$cpr/scripts"
got="$( cd "$td" && CLAUDE_PLUGIN_ROOT="$cpr" HOME="$td/none" run_resolver )"
check "(i) CLAUDE_PLUGIN_ROOT valid" "$cpr/scripts" "$got"

# (ii) CLAUDE_PLUGIN_ROOT empty, HIMMEL_REPO set + valid -> repo plugin scripts.
repo="$td/repo"; mk_repo "$repo"
got="$( cd "$td" && HIMMEL_REPO="$repo" HOME="$td/none" run_resolver )"
check "(ii) HIMMEL_REPO fallback" "$repo/marketplace/plugins/himmel-ops/scripts" "$got"

# (iii) CLAUDE_PLUGIN_ROOT + HIMMEL_REPO empty, CWD inside a git checkout -> toplevel.
gitrepo="$td/gitrepo"; git init -q "$gitrepo"; mk_repo "$gitrepo"
top="$(git -C "$gitrepo" rev-parse --show-toplevel)"
got="$( cd "$gitrepo" && HOME="$td/none" run_resolver )"
check "(iii) git-toplevel fallback" "$top/marketplace/plugins/himmel-ops/scripts" "$got"

# (iv) nothing set, CWD not a repo, himmel at the canonical $HOME path -> canonical.
canon_home="$td/canon"; mk_repo "$canon_home/Documents/github/himmel"
got="$( cd "$td" && HOME="$canon_home" run_resolver )"
check "(iv) canonical install path" "$canon_home/Documents/github/himmel/marketplace/plugins/himmel-ops/scripts" "$got"

# (v) nothing reachable but the Codex plugin cache has it -> cache glob match.
cache_home="$td/cachehome"
cache="$cache_home/.codex/plugins/cache/himmel/himmel-ops/9.9.9/scripts"; mk_scripts "$cache"
got="$( cd "$td" && HOME="$cache_home" run_resolver )"
check "(v) Codex plugin-cache fallback" "$cache" "$got"

# (vi) CLAUDE_PLUGIN_ROOT set but INVALID (dir exists, no autonomy-mode.sh) + HIMMEL_REPO
#      valid -> the `! -f` disjunct of the first guard must fire and fall through. This is
#      the exact targeted Codex failure: a skill shell can export a non-empty but WRONG CPR,
#      not just an empty one. Guards a regression that weakened the guard to a bare `-z`.
badcpr="$td/badcpr"; mkdir -p "$badcpr/scripts"                       # dir present, sentinel absent
repo2="$td/repo2"; mk_repo "$repo2"
got="$( cd "$td" && CLAUDE_PLUGIN_ROOT="$badcpr" HIMMEL_REPO="$repo2" HOME="$td/none" run_resolver )"
check "(vi) invalid CLAUDE_PLUGIN_ROOT falls through to HIMMEL_REPO" "$repo2/marketplace/plugins/himmel-ops/scripts" "$got"

# (vii) CLAUDE_PLUGIN_ROOT valid AND HIMMEL_REPO valid -> CPR wins (precedence is the
#       resolver's contract; a reordering of the chain would otherwise pass silently).
cpr2="$td/cpr2"; mk_scripts "$cpr2/scripts"
repo3="$td/repo3"; mk_repo "$repo3"
got="$( cd "$td" && CLAUDE_PLUGIN_ROOT="$cpr2" HIMMEL_REPO="$repo3" HOME="$td/none" run_resolver )"
check "(vii) CLAUDE_PLUGIN_ROOT precedence over HIMMEL_REPO" "$cpr2/scripts" "$got"

# Parity: the two resolver copies in SKILL.md must be byte-identical.
check "resolver parity (2 copies identical)" "$snippet" "$(extract_block "$skill" 2)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
