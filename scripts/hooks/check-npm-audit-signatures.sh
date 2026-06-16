#!/usr/bin/env bash
# Pre-push hook: verify npm package signatures via `npm audit signatures`.
# Catches tampered tarballs and registry-substitution attacks that plain
# `npm audit` does not detect.
set -euo pipefail

# Scoped to scripts/ so we don't recurse into nested worktrees under .claude/.
mapfile -t pkgs < <(find scripts -maxdepth 3 -name package.json -not -path '*/node_modules/*')

if [ ${#pkgs[@]} -eq 0 ]; then
    echo "→ npm audit signatures: no package.json found under scripts/ — nothing to verify"
    exit 0
fi

fail=0
for pkg in "${pkgs[@]}"; do
    dir=$(dirname "$pkg")
    # Block-by-default: missing node_modules means the registry-signed manifest
    # was never materialized locally, so we cannot verify anything. Letting
    # the push through would silently disable the gate.
    if [ ! -d "$dir/node_modules" ]; then
        echo "ERROR: npm audit signatures cannot run in $dir — no node_modules." >&2
        echo "       Run \`npm ci\` in $dir before pushing." >&2
        fail=1
        continue
    fi
    echo "→ npm audit signatures (production) in $dir"
    # --omit=dev: production-only, matching the sibling check-npm-audit.sh
    # contract and the hook's registered name "npm audit signatures
    # (production)". Dev-time tooling with unsigned packages should NOT
    # block the push path.
    if ! (cd "$dir" && npm audit signatures --omit=dev); then
        fail=1
    fi
done

if [ $fail -ne 0 ]; then
    echo "" >&2
    echo "ERROR: npm audit signatures failed (see per-package output above)." >&2
    echo "       The offending package(s) are listed in the output above." >&2
    echo "       Remediation: \`npm ci\` in the affected dir to re-install from" >&2
    echo "       the registry; if the failure persists, the package may be" >&2
    echo "       tampered or unsigned — investigate before pushing." >&2
    echo "" >&2
    echo "       NOTE: there is no per-package allowlist in this hook —" >&2
    echo "       intentionally. Legitimate unsigned packages (e.g. pre-signing-" >&2
    echo "       era deps) must be evaluated by hand; only \`git push --no-verify\`" >&2
    echo "       bypasses the gate. Document the bypass reason in the PR." >&2
fi

exit $fail
