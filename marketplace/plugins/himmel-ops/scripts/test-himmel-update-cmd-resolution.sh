#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-himmel-update-cmd-resolution.sh -- F2-SC1b (HIMMEL-459). The himmel-update
# slash commands carry an embedded REPO-resolution snippet so they run from ANY
# directory ($HIMMEL_REPO -> git toplevel -> canonical install path -> error).
# This test EXTRACTS that snippet from the command file (single source of truth,
# so the test can't drift from the prose) and exercises every branch.
# bash-only (the snippet is bash inside the command; no .ps1 twin). Needs git.
# HIMMEL_REPO is never exported globally here (only via per-call env prefix) so
# the unset-cases see it genuinely absent.
set -u
# Drop any inherited HIMMEL_REPO (the operator session injects it via settings.json
# env) so the unset-cases below genuinely test absence; case (i) re-supplies it via
# a per-call env prefix.
unset HIMMEL_REPO 2>/dev/null || true
here="$(cd "$(dirname "$0")" && pwd)"
cmd="$here/../commands/himmel-update.md"
[ -f "$cmd" ] || { echo "FATAL: $cmd not found"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git required for the git-toplevel case"; exit 2; }
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

# Extract the resolver: from the `REPO="...` line through the ERR-guard line.
snippet="$(awk '/^REPO="/{f=1} f{print} /cannot locate himmel checkout/{exit}' "$cmd")"
[ -n "$snippet" ] || { echo "FATAL: could not extract resolver snippet from $cmd"; exit 2; }

# Run the snippet in a subshell under the caller's env/CWD; echo the resolved
# REPO (empty when the snippet errored + exited non-zero). HIMMEL_REPO / HOME are
# supplied by the caller via an env prefix on the run_resolver call.
run_resolver(){ ( eval "$snippet" && printf '%s' "$REPO" ) 2>/dev/null; }

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
empty_home="$td/empty-home"; mkdir -p "$empty_home"   # no canonical himmel here

# A fake clone that contains the sentinel script (for the HIMMEL_REPO case).
clone="$td/clone-himmel"; mkdir -p "$clone/scripts"; : > "$clone/scripts/himmel-update.sh"

# (i) HIMMEL_REPO set, CWD outside any repo -> resolves to the clone.
got="$( cd "$td" && HIMMEL_REPO="$clone" HOME="$empty_home" run_resolver )"
check "(i) HIMMEL_REPO from arbitrary dir" "$clone" "$got"

# (ii) HIMMEL_REPO unset, CWD inside a git clone with the script -> git toplevel.
gitclone="$td/gitclone"; mkdir -p "$gitclone/scripts"
git init -q "$gitclone"; : > "$gitclone/scripts/himmel-update.sh"
top="$(git -C "$gitclone" rev-parse --show-toplevel)"
got="$( cd "$gitclone" && HOME="$empty_home" run_resolver )"
check "(ii) git-toplevel fallback (HIMMEL_REPO unset)" "$top" "$got"

# (iii) neither HIMMEL_REPO nor a git repo nor a canonical himmel -> clear error.
got="$( cd "$td" && HOME="$empty_home" run_resolver )"
check "(iii) none -> empty (errored)" "" "$got"

# (iv) canonical default: HIMMEL_REPO unset, non-git CWD, himmel at the canonical
#      $HOME/Documents/github/himmel path -> resolves there (the branch that fixes
#      "from any dir with HIMMEL_REPO unset").
canon_home="$td/canon-home"
canon="$canon_home/Documents/github/himmel"; mkdir -p "$canon/scripts"; : > "$canon/scripts/himmel-update.sh"
got="$( cd "$td" && HOME="$canon_home" run_resolver )"
check "(iv) canonical default install path" "$canon" "$got"

# (v) HIMMEL_REPO SET but STALE (points at a dir lacking the script): the `-f`
#     re-check on the resolver's 2nd line must fall through to the git toplevel.
#     Guards against a future edit dropping that re-check (cases i-iv wouldn't).
bogus="$td/bogus"; mkdir -p "$bogus"   # no scripts/himmel-update.sh inside
got="$( cd "$gitclone" && HIMMEL_REPO="$bogus" HOME="$empty_home" run_resolver )"
check "(v) stale HIMMEL_REPO -> git-toplevel fallback" "$top" "$got"

# Snippet parity: all FOUR command copies (2 marketplace + 2 .claude/commands)
# must carry a byte-identical resolver. Only himmel-update.md is exercised above;
# without this the other three could drift silently and ship a broken resolver.
repo_root="$(git -C "$here" rev-parse --show-toplevel)"
extract(){ awk '/^REPO="/{f=1} f{print} /cannot locate himmel checkout/{exit}' "$1"; }
for f in \
  "$repo_root/marketplace/plugins/himmel-ops/commands/himmel-update-all.md" \
  "$repo_root/.claude/commands/himmel-update.md" \
  "$repo_root/.claude/commands/himmel-update-all.md"; do
  check "snippet parity: ${f#"$repo_root"/}" "$snippet" "$(extract "$f")"
done

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
