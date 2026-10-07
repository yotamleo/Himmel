#!/usr/bin/env bash
# Tests for scripts/lib/project-mode.sh, the tracker/forge mode resolver
# (HIMMEL-4758, HIMMEL-4748 spec section 1).
#
# Walks every row of fixtures/project-modes.tsv and every origin of
# fixtures/forge-origins.tsv. scripts/lib/project-mode.test.mjs walks the same
# two tables against project-mode.mjs, so the shell and JS resolvers give
# identical answers (I2). Each row runs in a fresh directory under `env -i`
# with no global or system git config, so the operator's own environment
# cannot leak into an answer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/project-mode.sh"
MODES_TSV="$SCRIPT_DIR/fixtures/project-modes.tsv"
ORIGINS_TSV="$SCRIPT_DIR/fixtures/forge-origins.tsv"
# shellcheck source=fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fixture-tempdir.sh"
T=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0

# make_dir <origin> <gitconfig> — prints a fresh directory in the state the
# row describes: NOGIT = plain dir; `-` = repo with no remote; else that origin.
make_dir() {
    local origin="$1" cfg="$2" d kv
    d=$(mktemp -d "$T/row.XXXXXX") || return 1
    if [ "$origin" != NOGIT ]; then
        git init -q "$d"
        [ "$origin" = - ] || git -C "$d" remote add origin "$origin"
        if [ "$cfg" != - ]; then
            for kv in $cfg; do git -C "$d" config "${kv%%=*}" "${kv#*=}"; done
        fi
    fi
    printf '%s\n' "$d"
}

# resolve <dir> <env> <fn> — the resolver's answer, in the fixture's encoding.
resolve() {
    local d="$1" envs="$2" fn="$3" out rc=0
    local -a call envarr=()
    case "$fn" in
        tracker)     call=(project_mode_tracker) ;;
        forge)       call=(project_mode_forge) ;;
        forge-guard) call=(project_mode_forge --for-guard) ;;
        pattern)     call=(project_mode_id_pattern) ;;
        required)    call=(project_mode_id_required) ;;
        phases)      call=(project_mode_phases) ;;
        env)         call=(project_mode_env) ;;
        *) printf 'BAD-FN:%s' "$fn"; return ;;
    esac
    [ "$envs" = - ] || read -r -a envarr <<< "$envs"
    # shellcheck disable=SC2016  # $1/$@ belong to the inner bash -c
    out=$(cd "$d" && env -i PATH="$PATH" HOME="$T" GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CEILING_DIRECTORIES="$T" ${envarr[@]+"${envarr[@]}"} \
        bash -c '. "$1" || exit 99; shift; "$@"' _ "$LIB" "${call[@]}" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then printf 'EXIT%s' "$rc"; return; fi
    [ -n "$out" ] || { printf '<empty>'; return; }
    printf '%s' "$out" | sed 's/\t/\\t/g'
}

check() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n    want: %s\n    got:  %s\n' "$name" "$want" "$got"
    fi
}

echo "TEST: RED — TRACKER and JIRA_PROJECT_KEY unset resolve the tracker to local"
d=$(make_dir - -)
check "unset tracker -> local" local "$(resolve "$d" - tracker)"

echo "TEST: every row of fixtures/project-modes.tsv"
rows=0
while IFS=$'\t' read -r fn origin envs cfg want; do
    case "$fn" in ''|'#'*) continue ;; esac
    d=$(make_dir "$origin" "$cfg")
    check "$fn origin=$origin env=$envs cfg=$cfg" "$want" "$(resolve "$d" "$envs" "$fn")"
    rows=$((rows + 1))
done < "$MODES_TSV"
[ "$rows" -ge 50 ] || { echo "  FAIL  only $rows rows read from $MODES_TSV"; FAIL=$((FAIL + 1)); }

echo "TEST: every origin of fixtures/forge-origins.tsv (none -> local-git inside a work tree)"
origins=0
while IFS=$'\t' read -r want url; do
    case "$want" in ''|'#'*) continue ;; esac
    [ "$want" = none ] && want=local-git
    d=$(make_dir "$url" -)
    check "forge $url" "$want" "$(resolve "$d" - forge)"
    check "forge-guard $url" "$want" "$(resolve "$d" - forge-guard)"
    origins=$((origins + 1))
done < "$ORIGINS_TSV"
[ "$origins" -ge 30 ] || { echo "  FAIL  only $origins origins read from $ORIGINS_TSV"; FAIL=$((FAIL + 1)); }

echo "TEST: the I8 refusal names the rule on stderr"
d=$(make_dir https://github.com/o/r -)
# shellcheck disable=SC2016  # $1 belongs to the inner bash -c
msg=$(cd "$d" && env -i PATH="$PATH" HOME="$T" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    FORGE=local-git bash -c '. "$1"; project_mode_forge' _ "$LIB" 2>&1 >/dev/null)
case "$msg" in
    *local-git*github.com*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL  I8 message does not name local-git and github.com: %s\n' "$msg" ;;
esac

echo "TEST: the JS twin agrees (node --test project-mode.test.mjs walks the same tables)"
# CI has no glob for scripts/lib/*.test.mjs, so this suite carries the twin.
if command -v node >/dev/null 2>&1; then
    if node --test "$SCRIPT_DIR/project-mode.test.mjs" >"$T/node.log" 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "  FAIL  project-mode.test.mjs:"; sed 's/^/    /' "$T/node.log"
    fi
else
    FAIL=$((FAIL + 1)); echo "  FAIL  node not found — the JS twin went unchecked"
fi

echo "project-mode: $PASS passed, $FAIL failed ($rows table rows, $origins origins)"
[ "$FAIL" -eq 0 ]
