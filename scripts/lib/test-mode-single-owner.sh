#!/usr/bin/env bash
# Single-owner lint for the project mode (HIMMEL-4758, HIMMEL-4748 I2).
#
# scripts/lib/project-mode.sh (and its twin project-mode.mjs) is the ONE place
# that decides the tracker from JIRA_PROJECT_KEY and the forge from an origin
# host. This lint greps the surfaces that used to decide it themselves and
# fails on any non-comment line that still does:
#   shell  a `-n` / `-z` test on JIRA_PROJECT_KEY
#   js     a read of env.JIRA_PROJECT_KEY
#   both   a github.com / bitbucket.org host literal
# ALLOW lists the surfaces whose own test is owned by a later work package
# (merge-on-green.sh by WP3b, detect.mjs by WP4); each removes its entry.
# A RED control proves the patterns can fire before the real surfaces are read.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SURFACES="
scripts/setup/check-jira-key.sh
scripts/himmelctl/lib/status-report.js
scripts/hooks/check-commit-msg.sh
scripts/handover/merge-on-green.sh
plugins/himmel-gh/lib/forge/detect.mjs
"
ALLOW="
scripts/handover/merge-on-green.sh
plugins/himmel-gh/lib/forge/detect.mjs
"
SHELL_KEY_TEST='-[nz] +"?\$\{?JIRA_PROJECT_KEY'
JS_KEY_READ='env\.JIRA_PROJECT_KEY'
HOST_LITERAL='github\.com|bitbucket\.org'

# scan <file> — print `<line>: <text>` for every non-comment line that decides
# the mode itself. Comment lines (`#` in shell, `//` or `*` in JS) are skipped.
scan() {
    local f="$1" pat comment
    case "$f" in
        *.js|*.mjs) pat="$JS_KEY_READ|$HOST_LITERAL"; comment='[[:space:]]*(//|\*|/\*)' ;;
        *)          pat="$SHELL_KEY_TEST|$HOST_LITERAL"; comment='[[:space:]]*#' ;;
    esac
    grep -nE -- "$pat" "$f" | grep -vE -- "^[0-9]+:$comment"
}

FAIL=0

echo "TEST: RED control — the patterns fire on a surface that decides the mode itself"
T=$(mktemp -d "${TMPDIR:-/tmp}/mode-owner.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
# shellcheck disable=SC2016  # the control file must hold the literal $JIRA_PROJECT_KEY
printf '#!/usr/bin/env bash\n# [ -n "$JIRA_PROJECT_KEY" ] in a comment is fine\nif [ -n "${JIRA_PROJECT_KEY:-}" ]; then :; fi\ncase "$h" in github.com) ;; esac\n' > "$T/red.sh"
printf '// env.JIRA_PROJECT_KEY in a comment is fine\nconst k = process.env.JIRA_PROJECT_KEY;\nconst bb = host === "bitbucket.org";\n' > "$T/red.js"
red_sh=$(scan "$T/red.sh" | wc -l | tr -d ' ')
red_js=$(scan "$T/red.js" | wc -l | tr -d ' ')
if [ "$red_sh" = 2 ] && [ "$red_js" = 2 ]; then
    echo "  PASS  control flags 2 shell and 2 js lines, and skips the comments"
else
    echo "  FAIL  control flagged $red_sh shell / $red_js js lines (want 2 / 2)"
    FAIL=$((FAIL + 1))
fi

echo "TEST: no surface outside the allow-list decides the tracker or forge itself"
for rel in $SURFACES; do
    f="$ROOT/$rel"
    if [ ! -f "$f" ]; then
        echo "  FAIL  $rel is missing — a renamed surface must be renamed here too"
        FAIL=$((FAIL + 1))
        continue
    fi
    hits=$(scan "$f")
    case "$ALLOW" in
        *"
$rel
"*)
            echo "  ALLOW $rel (owned by a later HIMMEL-4748 work package)"
            continue
            ;;
    esac
    if [ -n "$hits" ]; then
        echo "  FAIL  $rel decides the mode itself; ask scripts/lib/project-mode.sh instead:"
        printf '%s\n' "$hits" | sed 's/^/          /'
        FAIL=$((FAIL + 1))
    else
        echo "  PASS  $rel"
    fi
done

echo "mode-single-owner: $FAIL failure(s)"
[ "$FAIL" -eq 0 ]
