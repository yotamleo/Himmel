#!/usr/bin/env bash
# Pre-push hook: verify npm package signatures via `npm audit signatures`.
# Catches tampered tarballs and registry-substitution attacks that plain
# `npm audit` does not detect.
set -euo pipefail

# Scoped to scripts/ so we don't recurse into nested worktrees under .claude/.
# bash 3.2-safe (macOS): no mapfile.
pkgs=()
while IFS= read -r _line; do pkgs+=("$_line"); done < <(find scripts -maxdepth 3 -name package.json -not -path '*/node_modules/*')

if [ ${#pkgs[@]} -eq 0 ]; then
    echo "→ npm audit signatures: no package.json found under scripts/ — nothing to verify"
    exit 0
fi

# npm ships its own copy of the registry's public keys, and the bundle in npm
# < 11 carries a key that EXPIRED 2025-01-29. On Debian/Ubuntu's apt npm (9.2.0)
# `npm audit signatures` therefore fails EVERY package with EEXPIREDSIGNATUREKEY
# — which reads like a supply-chain alarm when it is really a stale verifier,
# and it refuses every push on an otherwise-healthy box (HIMMEL-2440). Check the
# tool before believing its verdict. This does NOT weaken the check: an npm too
# old to verify is refused, never waved through.
NPM_MIN_MAJOR=11
npm_checked=0
npm_ok=0
require_npm() {
    if [ "$npm_checked" -eq 0 ]; then
        npm_checked=1
        local ver major
        ver="$(npm --version 2>/dev/null | head -1 | tr -d '\r' || true)"
        major="${ver%%.*}"
        case "$major" in
            ''|*[!0-9]*)
                echo "ERROR: npm did not report a usable version (got: '$ver')." >&2
                echo "       npm >= $NPM_MIN_MAJOR is required to verify registry signatures." >&2 ;;
            *)
                if [ "$major" -ge "$NPM_MIN_MAJOR" ]; then
                    npm_ok=1
                else
                    echo "ERROR: npm $ver is too old to verify registry signatures — need npm >= $NPM_MIN_MAJOR." >&2
                    echo "       npm < $NPM_MIN_MAJOR bundles a registry public key that expired 2025-01-29, so" >&2
                    echo "       every package fails with EEXPIREDSIGNATUREKEY. That is a stale verifier," >&2
                    echo "       not a tampered package. Debian/Ubuntu's apt npm is 9.2.0." >&2
                    echo "       Fix: sudo npm install -g npm@$NPM_MIN_MAJOR" >&2
                    echo "       Pin the major — npm@latest is npm 12, which refuses node 22.22.x with" >&2
                    echo "       EBADENGINE. Re-check with \`npm --version\` (the upgrade lands in" >&2
                    echo "       /usr/local/bin, so a shell that resolves /usr/bin first still sees 9)." >&2
                fi ;;
        esac
    fi
    [ "$npm_ok" -eq 1 ]
}

fail=0
for pkg in "${pkgs[@]}"; do
    dir=$(dirname "$pkg")

    # Bun-package detection (mirrors check-npm-audit.sh): `npm audit signatures`
    # only works on an npm-installed tree with a package-lock; a bun package has
    # no registry-signed npm manifest to verify, so skip it. Detect via a bun
    # lockfile or a package.json that drives `bun install`.
    if [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
        echo "→ npm audit signatures: skipping $dir — bun lockfile present (not an npm package)"
        continue
    fi
    if grep -q '"bun install' "$dir/package.json" 2>/dev/null; then
        echo "→ npm audit signatures: skipping $dir — package.json scripts use 'bun install' (bun package, not npm)"
        continue
    fi

    # Zero-prod-dep carve-out (mirrors the bun skip above): a package that npm
    # installs NO production packages for has no registry-signed tarballs to
    # verify — `npm audit signatures --omit=dev` on it is a no-op, and
    # `npm ci --omit=dev` legitimately materializes no node_modules — so skip
    # rather than block on the empty dir (HIMMEL-502: lets a zero-prod-dep
    # scripts/ package, e.g. a pure vitest/tsc suite, use the npm CI matrix
    # without tripping this gate). Count EVERY field npm installs under
    # --omit=dev — dependencies + optional + peer (npm 7+) + bundled — not just
    # `dependencies`: an optional/peer-only package DOES have signable tarballs,
    # so skipping on empty `dependencies` alone would silently disable the gate
    # for it. Read via node (already required for npm); fs.readFileSync so a
    # "type":"module" package.json still parses under the default CommonJS -e
    # context. A node crash → exit≠0 → NOT skipped → falls through to the real
    # block (fail-safe).
    if (cd "$dir" && node -e 'const p=JSON.parse(require("fs").readFileSync("package.json","utf8"));const n=Object.keys(p.dependencies||{}).length+Object.keys(p.optionalDependencies||{}).length+Object.keys(p.peerDependencies||{}).length+Object.keys(p.bundleDependencies||p.bundledDependencies||{}).length;process.exit(n?1:0)') 2>/dev/null; then
        echo "→ npm audit signatures: skipping $dir — no production/optional/peer dependencies (nothing to verify)"
        continue
    fi

    # Block-by-default: missing node_modules means the registry-signed manifest
    # was never materialized locally, so we cannot verify anything. Letting
    # the push through would silently disable the gate.
    if [ ! -d "$dir/node_modules" ]; then
        echo "ERROR: npm audit signatures cannot run in $dir — no node_modules." >&2
        echo "       Run \`npm ci\` in $dir before pushing." >&2
        fail=1
        continue
    fi
    # Fail fast on an unusable npm rather than surfacing its expired-key error
    # as if the packages were at fault.
    if ! require_npm; then fail=1; continue; fi
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
