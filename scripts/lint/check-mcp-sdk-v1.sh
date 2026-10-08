#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-mcp-sdk-v1.sh — refuse NEW dependencies on, or imports of, the v1
# monolith `@modelcontextprotocol/sdk` (HIMMEL-4866, follow-up to HIMMEL-4819).
# Every first-party MCP server is on the split v2 packages
# (`@modelcontextprotocol/server` 2.3.1); this gate keeps it that way.
#
# Scans tracked files only (`git ls-files` semantics via `git grep`):
#   - package.json            : the v1 package named as a dependency key
#   - npm / bun / yarn / pnpm lockfiles : any v1 entry, direct OR transitive
#   - source (.ts .tsx .js .jsx .mjs .cjs .mts .cts) : import / require /
#     dynamic import of the v1 specifier. A mere mention (a test asserting
#     its absence, prose) is not a hit. The scan is line-based and does not
#     parse comments: commented-out import syntax is refused too (fail-closed;
#     delete the dead line).
#
# Vendored third-party bundles (any `*/.obsidian/plugins/*`) are compiled
# upstream output: the source/manifest rules do not apply, but a bundle that
# embeds the v1 monolith (`node_modules/@modelcontextprotocol/sdk` marker) is
# refused, and a bundle embedding the v2 packages is reported as a NOTE with
# its exact SDK version UNKNOWN — never presented as compliant. Externally
# configured servers (npx, hosted, .mcp.json) are not scanned at all; the
# closing NOTE says so. Re-vendor upstream, do not edit a bundle.
#
# Usage: check-mcp-sdk-v1.sh [repo-root]   (default: this checkout)
# Exit: 0 clean (NOTEs may print) · 1 findings (path:line:match) · 2 cannot evaluate

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="${1:-$(cd "$SELF_DIR/../.." && pwd)}"

git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "check-mcp-sdk-v1: '$ROOT' is not a git checkout" >&2; exit 2; }

found=0
V1='@modelcontextprotocol/sdk'
VENDOR_X=(':!*/.obsidian/plugins/*' ':!.obsidian/plugins/*')

# scan <label> <git-grep-args...> -- <pathspec...>: print each hit, count it.
scan() {
    local label="$1"; shift
    local out rc=0
    out="$(git -C "$ROOT" grep -nIoE "$@")" || rc=$?
    case "$rc" in
        0) found=1; printf '%s\n' "$out" | sed "s|\$| [$label]|" ;;
        1) ;;
        *) echo "check-mcp-sdk-v1: git grep failed (rc=$rc)" >&2; exit 2 ;;
    esac
}

scan "v1 dependency" "\"$V1\"[[:space:]]*:" -- '*package.json' "${VENDOR_X[@]}"
scan "v1 lock entry" "$V1" -- '*package-lock.json' '*npm-shrinkwrap.json' '*bun.lock' '*yarn.lock' '*pnpm-lock.yaml' "${VENDOR_X[@]}"
scan "v1 import" "(from|import|require)[[:space:]]*[(]?[[:space:]]*['\"]${V1}['\"/]" \
    -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.mts' '*.cts' "${VENDOR_X[@]}"
# A specifier alone on its own line: the multiline require(\n'...')/import(\n'...') form.
scan "v1 import" "^[[:space:]]*['\"]${V1}(/[^'\"]*)?['\"][[:space:]]*[,);]*[[:space:]]*(//.*|/[*].*)?$" \
    -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.mts' '*.cts' "${VENDOR_X[@]}"
scan "vendored bundle embeds v1 SDK" "node_modules/${V1}[/@]" -- '*/.obsidian/plugins/*' '.obsidian/plugins/*'

# Vendored bundles on the v2 packages: report, never certify.
notes="$(git -C "$ROOT" grep -lIE 'node_modules/@modelcontextprotocol/(server|core|node|client)[/@]' -- '*/.obsidian/plugins/*' '.obsidian/plugins/*' 2>/dev/null)"
if [ -n "$notes" ]; then
    printf '%s\n' "$notes" | while IFS= read -r f; do
        echo "NOTE vendored bundle $f embeds the split v2 packages; exact SDK version unknown (not verified by this gate)"
    done
fi
echo "NOTE externally configured MCP servers (npx, hosted, .mcp.json) are not scanned; their SDK version is unknown, see docs/internals/mcp-servers.md"

[ "$found" -eq 0 ]
