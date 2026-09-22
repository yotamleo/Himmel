#!/usr/bin/env bash
# test-version.sh — himmel carries a version, and himmelctl reports it.
#
# WHY (HIMMEL-1599): himmel had NO version of its own. The `template-version`
# gate versions the luna TEMPLATE, not the harness, so every measurement we
# take — gate false-positive rates, dispatch-completion rates, suite timings —
# was unattributable: "this run was slower" with nothing to attribute it to.
# A version is the cheapest thing that makes a measurement comparable.
set -uo pipefail

root="$(git rev-parse --show-toplevel)"

[ -f "$root/VERSION" ] || { echo "FAIL - no VERSION file at $root/VERSION"; exit 1; }

# tr strips CR too: the file is read on Windows checkouts where a CRLF would
# otherwise sneak into the semver comparison and fail for a cosmetic reason.
v=$(tr -d ' \n\r' < "$root/VERSION")
printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "FAIL - VERSION is not semver: [$v]"; exit 1; }

# Pin the root the CLI derives: repoRoot() gives HIMMELCTL_REPO_ROOT precedence,
# so an inherited value would have --version read a DIFFERENT checkout's VERSION
# than the "$root/VERSION" this test just compared against.
# -F: the semver's dots are regex wildcards under a plain grep, so a coincidental
# near-miss ("0X1Y0") would satisfy the assertion.
out=$(HIMMELCTL_REPO_ROOT="$root" node "$root/scripts/himmelctl/bin.js" --version 2>&1)
rc=$?
[ "$rc" -eq 0 ] \
  || { echo "FAIL - himmelctl --version exited $rc (it must never throw; got: $out)"; exit 1; }
printf '%s' "$out" | grep -Fq "$v" \
  || { echo "FAIL - himmelctl --version does not report $v (got: $out)"; exit 1; }

# --version must not cannibalise --help: both are pre-parseArgs special cases,
# and an over-broad match would swallow the other.
help_out=$(HIMMELCTL_REPO_ROOT="$root" node "$root/scripts/himmelctl/bin.js" --help 2>&1)
rc=$?
[ "$rc" -eq 0 ] \
  || { echo "FAIL - himmelctl --help exits $rc (got: $help_out)"; exit 1; }
printf '%s' "$help_out" | grep -q 'usage' \
  || { echo "FAIL - --help no longer prints usage"; exit 1; }

# ── HIMMEL-3400: --version also reports the git describe string + the commit ─
# A fixture checkout: one tag, then one commit on top, so describe is the
# `<tag>-1-g<sha>` shape the operator sees between releases.
work=$(mktemp -d "${TMPDIR:-/tmp}/test-version.XXXXXX") || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$work"' EXIT
gitq() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
fx="$work/fx"
mkdir -p "$fx/scripts"
echo "9.8.7" > "$fx/VERSION"
gitq init -q "$fx"
gitq -C "$fx" add VERSION
gitq -C "$fx" commit -q -m one
gitq -C "$fx" tag v9.8.7-pre.6
echo x > "$fx/x"
gitq -C "$fx" add x
gitq -C "$fx" commit -q -m two
head_sha=$(git -C "$fx" rev-parse HEAD)
want_describe=$(git -C "$fx" describe --tags --always)

out=$(HIMMELCTL_REPO_ROOT="$fx" node "$root/scripts/himmelctl/bin.js" --version 2>&1)
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL - --version on a git fixture exited $rc (got: $out)"; exit 1; }
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "himmel 9.8.7" ] \
  || { echo "FAIL - first line must stay 'himmel <VERSION>' (got: $out)"; exit 1; }
grep -Fxq "describe: $want_describe" <<< "$out" \
  || { echo "FAIL - --version lacks 'describe: $want_describe' (got: $out)"; exit 1; }
case "$want_describe" in v9.8.7-pre.6-1-g*) ;; *) echo "FAIL - fixture describe is not tag-N-g<sha>: $want_describe"; exit 1 ;; esac
grep -Fxq "commit: $head_sha" <<< "$out" \
  || { echo "FAIL - --version lacks 'commit: $head_sha' (got: $out)"; exit 1; }

# A root that is not itself a checkout must not read an ENCLOSING repo: its
# describe/commit would be some other project's. Nested dir, VERSION but no .git.
nested="$fx/nested"
mkdir -p "$nested"
echo "1.2.3" > "$nested/VERSION"
out=$(HIMMELCTL_REPO_ROOT="$nested" node "$root/scripts/himmelctl/bin.js" --version 2>&1)
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL - --version on a non-checkout exited $rc (got: $out)"; exit 1; }
grep -Fxq "himmel 1.2.3" <<< "$out" \
  || { echo "FAIL - non-checkout lost its VERSION line (got: $out)"; exit 1; }
grep -Fxq "describe: unknown" <<< "$out" \
  || { echo "FAIL - non-checkout must print 'describe: unknown' (got: $out)"; exit 1; }
grep -Fxq "commit: unknown" <<< "$out" \
  || { echo "FAIL - non-checkout must print 'commit: unknown' (got: $out)"; exit 1; }
grep -Fq "$head_sha" <<< "$out" \
  && { echo "FAIL - non-checkout leaked the enclosing repo's commit (got: $out)"; exit 1; }

# --version --all → himmel-update.sh --versions, rc passed through. The root is a
# fixture whose himmel-update.sh is a stub that records its args: the real
# update engine is never run.
cat > "$fx/scripts/himmel-update.sh" <<'STUB'
#!/usr/bin/env bash
echo "STUB-UPDATE args: $*"
exit 1
STUB
out=$(HIMMELCTL_REPO_ROOT="$fx" node "$root/scripts/himmelctl/bin.js" --version --all 2>&1)
rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL - --version --all must return the report's rc (1), got $rc ($out)"; exit 1; }
grep -Fxq "STUB-UPDATE args: --versions" <<< "$out" \
  || { echo "FAIL - --version --all must run 'himmel-update.sh --versions' and nothing else (got: $out)"; exit 1; }
grep -Fxq "describe: $want_describe" <<< "$out" \
  || { echo "FAIL - --version --all dropped the describe header (got: $out)"; exit 1; }
# --all without --version is not a global flag; it must not reach the update engine.
out=$(HIMMELCTL_REPO_ROOT="$fx" node "$root/scripts/himmelctl/bin.js" --all 2>&1)
grep -Fq "STUB-UPDATE" <<< "$out" \
  && { echo "FAIL - bare --all ran the update engine (got: $out)"; exit 1; }

echo "ok - VERSION is semver ($v), himmelctl reports it with describe+commit, --version --all runs the versions report, --help still works"
