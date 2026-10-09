#!/usr/bin/env bash
# scripts/ci/test-pages-workflow.sh -- static suite for HIMMEL-5075: the Pages
# source is build_type=workflow, so pages.yml must deploy ONLY when docs/**
# changes (the legacy branch build redeployed the site on every push to main,
# ~30 deployments in 12 h). Properties asserted over the workflow text:
#   1. triggers are exactly push-to-main with paths docs/** plus
#      workflow_dispatch (no pull_request, no schedule, no tags);
#   2. permissions pages:write + id-token:write + contents:read, nothing wider;
#   3. the three Pages actions run (configure, upload, deploy), upload path is
#      docs, and docs/.nojekyll exists (plain static == the legacy output);
#   4. concurrency group pages, never cancelling a running deploy;
#   5. a timeout-minutes on the job; the workflow is not named `CI`
#      (cut-tag.sh keys on a workflow named exactly CI).
# Mutation controls prove each check can fail; no network.
#
# Usage: bash scripts/ci/test-pages-workflow.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${PAGES_YML:-$ROOT/.github/workflows/pages.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }

# check_file <file> -- print one "name" line per violated property.
check_file() {
    local f="$1" s
    [ -f "$f" ] || { echo "workflow-missing"; return; }
    s=$(strip_comments "$f")
    grep -qE '^name:[[:space:]]*Pages[[:space:]]*$' <<< "$s" || echo "name-not-Pages"
    grep -qE '^[[:space:]]+branches:[[:space:]]*\[main\]' <<< "$s" || echo "push-not-main"
    grep -qE "^[[:space:]]+paths:[[:space:]]*\\['docs/\\*\\*'\\]" <<< "$s" || echo "paths-not-docs"
    grep -qE '^[[:space:]]+workflow_dispatch:' <<< "$s" || echo "no-dispatch"
    grep -qE '^[[:space:]]+(pull_request|pull_request_target|schedule|release|workflow_run|tags|branches-ignore):' <<< "$s" && echo "extra-trigger"
    grep -qE '^[[:space:]]+pages:[[:space:]]*write' <<< "$s" || echo "no-pages-write"
    grep -qE '^[[:space:]]+id-token:[[:space:]]*write' <<< "$s" || echo "no-id-token"
    grep -qE '^[[:space:]]+contents:[[:space:]]*read' <<< "$s" || echo "no-contents-read"
    grep -vE '^[[:space:]]+(pages|id-token):[[:space:]]*write' <<< "$s" | grep -qE '^[[:space:]]+[a-z-]+:[[:space:]]*write[[:space:]]*$' && echo "extra-write-permission" # pipefail-ok: small input
    grep -qE 'uses:[[:space:]]*actions/configure-pages@' <<< "$s" || echo "no-configure-pages"
    grep -qE 'uses:[[:space:]]*actions/upload-pages-artifact@' <<< "$s" || echo "no-upload-pages-artifact"
    grep -qE 'uses:[[:space:]]*actions/deploy-pages@' <<< "$s" || echo "no-deploy-pages"
    grep -qE '^[[:space:]]+path:[[:space:]]*docs[[:space:]]*$' <<< "$s" || echo "upload-path-not-docs"
    grep -qE '^[[:space:]]+group:[[:space:]]*pages[[:space:]]*$' <<< "$s" || echo "no-pages-group"
    grep -qE '^[[:space:]]+cancel-in-progress:[[:space:]]*false' <<< "$s" || echo "cancels-running-deploy"
    grep -qE '^[[:space:]]+timeout-minutes:[[:space:]]*[0-9]+' <<< "$s" || echo "no-timeout"
}

# expect_clean <label> <file> / expect_violation <label> <file> <name>
got=$(check_file "$WF")
if [ -z "$got" ]; then ok "pages.yml satisfies every property"; else bad "pages.yml violates: ${got//$'\n'/ }"; fi

if [ -f "$ROOT/docs/.nojekyll" ]; then
    ok "docs/.nojekyll present (Jekyll off, plain static == legacy output)"
else
    bad "docs/.nojekyll missing -- legacy Pages ran Jekyll on docs/"
fi

# Mutation controls: each rewrite of the real workflow must trip its check.
if [ -f "$WF" ]; then
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/pages-wf.XXXXXX") || exit 1; trap 'rm -rf "$tmp"' EXIT
    mutate() { # <name> <sed-expr>
        sed -e "$2" "$WF" > "$tmp/m.yml"
        if check_file "$tmp/m.yml" | grep -qx "$1"; then ok "control: $1 detected"; else bad "control: $1 NOT detected"; fi
    }
    mutate paths-not-docs "s#docs/\*\*#**#"
    mutate push-not-main "s#\[main\]#[main, dev]#"
    mutate no-dispatch "s#workflow_dispatch:#workflow_x:#"
    mutate no-timeout "s#timeout-minutes:#timeout:#"
    mutate cancels-running-deploy "s#cancel-in-progress: false#cancel-in-progress: true#"
    mutate no-deploy-pages "s#actions/deploy-pages@#actions/other@#"
    mutate name-not-Pages "s#^name: Pages#name: CI#"
    mutate extra-trigger "s#^  workflow_dispatch:#  workflow_run:\n  workflow_dispatch:#"
    mutate extra-write-permission "s#^  contents: read#  contents: read\n  issues: write#"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2; exit 1
