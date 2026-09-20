#!/usr/bin/env bash
# build-tarball.sh -- build the checksummed Linux release tarball (HIMMEL-3059
# slice 1; decision: the ADR "himmel's installable unit is a checksummed
# release tarball").
#
# Emits, into --out:
#   himmel-<version>-linux.tar.gz          the whole himmel tree, PRE-BUILT
#   himmel-<version>-linux.tar.gz.sha256   `sha256sum` line for that exact file
#
# WHY pre-built: the tracked tree is not build-complete -- scripts/jira/dist/,
# scripts/bitbucket/dist/ and their node_modules/ are gitignored and produced by
# setup.sh step [3/9] / adopt.sh build_jira_cli. The tarball carries both, so
# the adopter never runs `npm install` (and adopt.sh's "already built" skip --
# node_modules/ AND dist/index.js both present -- fires).
#
# WHY we hash our OWN asset: the hash covers the BUILT tree the adopter
# installs, and nothing depends on the byte-stability of GitHub's generated
# source archives. The .sha256 names the tarball by its bare filename so the
# adopter's one-liner `sha256sum -c <file>.sha256` works from the download dir.
#
# The tree comes from `git archive HEAD` of --src (tracked files only, no .git,
# no untracked/ignored leftovers -- so a dirty working tree cannot leak into the
# artifact), unpacked into a temp stage, built THERE, then tarred. The source
# checkout is never modified.
#
# USAGE:
#   bash scripts/release/build-tarball.sh --version <v> [--out <dir>] [--src <dir>] [--no-build]
#     --version <v>   tag without the leading `v` (0.3.0, 0.3.0-pre.4); used in filenames
#     --out <dir>     where the two assets land (default: ./dist-release)
#     --src <dir>     git checkout to package (default: this script's repo)
#     --no-build      skip the node builds (fixture/test use ONLY -- the result is
#                     NOT an installable himmel and must never be published)
# ENV:
#   RELEASE_NODE_PKGS   space-separated package dirs to build (relative to the
#                       tree root); default "scripts/jira scripts/bitbucket"
#
# Exit: 0 = both assets written AND self-verified; 2 = usage; 1 = build/verify failure.
set -euo pipefail

die() { echo "build-tarball: $*" >&2; exit 1; }
usage() { sed -n '/^# USAGE:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

version="" out="./dist-release" src="" build=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || usage; version="$2"; shift 2 ;;
    --out)     [ $# -ge 2 ] || usage; out="$2"; shift 2 ;;
    --src)     [ $# -ge 2 ] || usage; src="$2"; shift 2 ;;
    --no-build) build=0; shift ;;
    -h|--help) usage ;;
    *) echo "build-tarball: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$version" ] || usage
# The version becomes a filename and a directory name: no slashes, no dot-dot.
case "$version" in
  [0-9A-Za-z]*) ;;
  *) die "invalid version '$version' (must start with an alphanumeric)" ;;
esac
case "$version" in
  *[!0-9A-Za-z._-]*) die "invalid version '$version' (allowed: A-Za-z0-9 . _ -)" ;;
esac

if [ -z "$src" ]; then
  src="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "--src '$src' is not a git checkout"
mkdir -p "$out"
out="$(cd -- "$out" && pwd)"

name="himmel-${version}-linux.tar.gz"
top="himmel-${version}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

git -C "$src" archive --format=tar --prefix="$top/" HEAD | tar -x -C "$stage"
tree="$stage/$top"

if [ "$build" -eq 1 ]; then
  for pkg in ${RELEASE_NODE_PKGS:-scripts/jira scripts/bitbucket}; do
    [ -f "$tree/$pkg/package.json" ] || die "package '$pkg' has no package.json in the tree"
    # ci = lockfile-exact install; build needs the devDependencies (tsc), then
    # prune to runtime deps so the tarball ships what the CLI actually loads.
    ( cd "$tree/$pkg" && npm ci --silent && npm run build --silent && npm prune --omit=dev --silent ) \
      || die "node build failed in $pkg"
    [ -f "$tree/$pkg/dist/index.js" ] || die "build of $pkg produced no dist/index.js"
    [ -d "$tree/$pkg/node_modules" ] || die "$pkg has no node_modules/ after the build"
  done
fi

tar --owner=0 --group=0 --numeric-owner -C "$stage" -cf - "$top" | gzip -n -9 > "$out/$name"
( cd "$out" && sha256sum "$name" > "$name.sha256" )
# Self-verify with the exact command the README hands the adopter.
( cd "$out" && sha256sum -c "$name.sha256" >/dev/null ) || die "self-verification of $name failed"

echo "asset: $out/$name"
echo "asset: $out/$name.sha256"
