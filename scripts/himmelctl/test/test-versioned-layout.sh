#!/usr/bin/env bash
# test-versioned-layout.sh — HIMMEL-3059 S4: the release tarball's versioned
# layout (~/.local/share/himmel/<version>/ + a `current` symlink) and the
# non-git branch of `himmelctl update` (design HIMMEL-3059-linux-packaging.md
# §1.4 / §8 row S4).
#
# Drives the REAL bin.js from a fixture tree laid out exactly as the README
# recipe lays it out, invoked THROUGH `current` (as the launcher and the README
# do). Only scripts/adopt.sh + scripts/setup.sh are stubbed, and `curl` / `gh`
# are PATH stubs serving a locally built release pair — no network, and no
# environment seam steering the download URL (release-check.sh's integrity
# note: the URL is a constant).
#
#   A  install through `current`: the wiring (the root adopt.sh/setup.sh derive
#      HIMMEL_REPO from, the PATH launcher's target) is the `current` path,
#      never the versioned dir — while the ledger's himmel_root records the
#      versioned dir (the bytes that wrote the rows). §1.4's canonicalisation
#      risk.
#   B  `update --dry-run` on the versioned layout names the tarball plan and
#      touches nothing; on a git clone it is the unchanged himmel-update.sh line.
#   C  `update`: download -> sha256 verify -> extract into <base>/<new> ->
#      atomic `current` swap; the previous version dir stays for rollback.
#   D  a bad checksum extracts nothing and never swaps.
#   E  a failed attestation (gh present + authenticated) extracts nothing.
#   F  up to date: nothing downloaded, nothing changed.
#   G  the new version dir already exists: refused, nothing changed.
#   H  a tarball whose top dir is not himmel-<version>/: refused, no swap.
set -uo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
command -v node >/dev/null 2>&1 || fail "node required"
node_bin=$(command -v node)
bash_bin=$(command -v bash)

work=$(mktemp -d -t versioned-layout.XXXXXX) || fail "mktemp failed"
work=$(cd "$work" && pwd -P)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# The fixture is the WORKING tree (tracked + untracked, not ignored), so the
# suite exercises the code under test, not the last commit.
tree_src="$work/tree"
mkdir -p "$tree_src"
git -C "$repo_root" ls-files -co --exclude-standard -z \
  | tar -C "$repo_root" --null --ignore-failed-read -T - -cf - 2>/dev/null \
  | tar -xf - -C "$tree_src" || fail "could not copy the working tree"
[ -f "$tree_src/scripts/himmelctl/bin.js" ] || fail "working-tree copy has no bin.js"
# Stubs derive their root exactly as scripts/adopt.sh does (logical pwd), and
# log it — that root is what adopt.sh writes into env.HIMMEL_REPO and every
# hook command.
for s in adopt.sh setup.sh; do
  # shellcheck disable=SC2016 # expands when the stub RUNS
  printf '#!/usr/bin/env bash\nd="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"\nprintf "%%s\\n" "$d" >> "$INSTALL_CALL_LOG"\n' > "$tree_src/scripts/$s"
  chmod +x "$tree_src/scripts/$s"
done

# A release pair for <version>, built like scripts/release/build-tarball.sh
# (top dir himmel-<version>/, sha256sum-format .sha256).
make_release() { # <version> <outdir> [<topdir>]
  local v="$1" out="$2" top="${3:-himmel-$1}" st
  st=$(mktemp -d "$work/rel.XXXXXX") || fail "mktemp failed"
  cp -a "$tree_src" "$st/$top"
  printf '%s\n' "$v" > "$st/$top/RELEASE-MARKER"
  mkdir -p "$out"
  tar -C "$st" -czf "$out/himmel-$v-linux.tar.gz" "$top"
  (cd "$out" && sha256sum "himmel-$v-linux.tar.gz" > "himmel-$v-linux.tar.gz.sha256")
  rm -rf "$st"
}

# PATH stubs. curl: a release-check.sh lookup (-w, no -o) answers the tag in
# $FAKE_LATEST_TAG; a download (-o dest) copies <basename of url> out of
# $FAKE_RELEASE_DIR and logs it. gh: `auth status` rc $FAKE_GH_AUTH_RC,
# `attestation verify` rc $FAKE_GH_ATTEST_RC.
stubbin="$work/stubbin"
mkdir -p "$stubbin"
cat > "$stubbin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|--proto|--proto-redir|--max-redirs|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [ -n "$out" ]; then
  printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
  cp "$FAKE_RELEASE_DIR/${url##*/}" "$out" || exit 22
  exit 0
fi
printf '{"tag_name":"%s"}\n200' "$FAKE_LATEST_TAG"
EOF
cat > "$stubbin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit "${FAKE_GH_AUTH_RC:-1}" ;;
  "attestation verify") printf 'gh attestation verify %s\n' "$3" >> "$FAKE_CURL_LOG"; exit "${FAKE_GH_ATTEST_RC:-0}" ;;
esac
exit 1
EOF
printf '#!/usr/bin/env bash\necho "[]"\n' > "$stubbin/claude"
chmod +x "$stubbin/curl" "$stubbin/gh" "$stubbin/claude"

# A fresh versioned install: <case>/share/<v>/ + share/current -> <v>, laid out
# as the README recipe does.
new_layout() { # <case-dir> <version>
  mkdir -p "$1/share" "$1/bin" "$1/home" "$1/prov" "$1/cache" "$1/rel"
  cp -a "$tree_src" "$1/share/$2"
  ln -s "$2" "$1/share/current"
  : > "$1/curl.log"
}

run_ctl() { # <case-dir> <args...>  — always through `current`
  local td="$1"; shift
  (cd "$td/home" && HOME="$td/home" USERPROFILE="$(winpath "$td/home")" \
    PATH="$stubbin:$PATH" \
    HIMMELCTL_BASH="$bash_bin" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_CACHE_DIR="$(winpath "$td/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$td/cache/luna-config.json")" \
    HIMMELCTL_BIN_DIR="$td/bin" HIMMELCTL_SHIM_PLATFORM=linux \
    HIMMEL_PROVENANCE_DIR="$td/prov" \
    INSTALL_CALL_LOG="$td/install-calls.log" \
    FAKE_CURL_LOG="$td/curl.log" FAKE_RELEASE_DIR="$td/rel" \
    FAKE_LATEST_TAG="${FAKE_LATEST_TAG:-v0.4.0}" \
    FAKE_GH_AUTH_RC="${FAKE_GH_AUTH_RC:-1}" FAKE_GH_ATTEST_RC="${FAKE_GH_ATTEST_RC:-0}" \
    "$node_bin" "$td/share/current/scripts/himmelctl/bin.js" "$@" </dev/null 2>&1)
}

cat > "$work/profile.json" <<'JSON'
{
  "role": "contributor",
  "tier": "standard",
  "scope": "user",
  "vault": { "mode": "none", "path": "" },
  "handover": { "mode": "inline", "path": "" },
  "pluginSet": "lean",
  "lanes": [],
  "lanesMeaningful": true,
  "alwaysOn": false
}
JSON

# ── A: install through `current` wires `current`, records <v> ────────────────
td="$work/caseA"
new_layout "$td" 0.3.0
out=$(run_ctl "$td" install --from-profile "$work/profile.json"); rc=$?
[ "$rc" -eq 0 ] || fail "caseA: install exited $rc: $out"
roots=$(sort -u "$td/install-calls.log")
[ "$roots" = "$td/share/current" ] \
  || fail "caseA: adopt/setup ran from '$roots', want the stable '$td/share/current' (HIMMEL_REPO and every hook path derive from it; a versioned path strands them on the next update)"
grep -Fq "\"$td/share/current/scripts/himmelctl/bin.js\"" "$td/bin/himmelctl.js" \
  || fail "caseA: PATH launcher does not target current/: $(grep '^const t' "$td/bin/himmelctl.js")"
begin=$(grep '"op":"install-begin"' "$td/prov/provenance.jsonl" | head -n 1)
grepq "$begin" -F "\"himmel_root\":\"$td/share/0.3.0\"" \
  || fail "caseA: ledger himmel_root should be the versioned dir (the bytes that wrote the rows): $begin"
echo "ok: caseA install through current wires current/ (adopt root + launcher) and records share/0.3.0 in the ledger"

# ── B: update --dry-run ──────────────────────────────────────────────────────
out=$(run_ctl "$td" update --dry-run); rc=$?
[ "$rc" -eq 0 ] || fail "caseB: update --dry-run exited $rc: $out"
grepq "$out" -F "versioned tarball update of $td/share" || fail "caseB: dry-run did not name the tarball plan: $out"
grepq "$out" -F 'himmel-update.sh' && fail "caseB: dry-run on a versioned install still routes to himmel-update.sh: $out"
[ -s "$td/curl.log" ] && fail "caseB: dry-run touched the network: $(cat "$td/curl.log")"
[ "$(readlink "$td/share/current")" = 0.3.0 ] || fail "caseB: dry-run moved current"
clone_out=$(HOME="$td/home" USERPROFILE="$(winpath "$td/home")" HIMMELCTL_BASH="$bash_bin" \
  HIMMELCTL_CACHE_DIR="$(winpath "$td/cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$td/cache/luna-config.json")" \
  HIMMELCTL_BIN_DIR="$td/bin" HIMMELCTL_SHIM_PLATFORM=linux HIMMEL_PROVENANCE_DIR="$td/prov" \
  "$node_bin" "$repo_root/scripts/himmelctl/bin.js" update --dry-run 2>&1)
grepq "$clone_out" -Fx "derived: $bash_bin $repo_root/scripts/himmel-update.sh" \
  || fail "caseB: a git clone's update is no longer the himmel-update.sh line: $clone_out"
echo "ok: caseB dry-run names the tarball plan (no network) on the layout; a clone still derives himmel-update.sh"

# ── C: update swaps current to the new version dir ───────────────────────────
make_release 0.4.0 "$td/rel"
out=$(run_ctl "$td" update); rc=$?
[ "$rc" -eq 0 ] || fail "caseC: update exited $rc: $out"
[ "$(readlink "$td/share/current")" = 0.4.0 ] || fail "caseC: current -> '$(readlink "$td/share/current")', want 0.4.0: $out"
[ "$(cat "$td/share/0.4.0/RELEASE-MARKER" 2>/dev/null)" = 0.4.0 ] || fail "caseC: share/0.4.0 is not the release's tree"
[ -f "$td/share/0.3.0/VERSION" ] || fail "caseC: the previous version dir was not kept for rollback"
[ -f "$td/share/current/RELEASE-MARKER" ] || fail "caseC: current/ does not resolve to the new tree"
leftover=$(compgen -G "$td/share/.[!.]*")
[ -z "$leftover" ] || fail "caseC: staging left behind: $leftover"
grep -Fxq "https://github.com/yotamleo/Himmel/releases/download/v0.4.0/himmel-0.4.0-linux.tar.gz" "$td/curl.log" \
  || fail "caseC: tarball not fetched from the release URL: $(cat "$td/curl.log")"
grepq "$out" -F 'ln -sfn 0.3.0' || fail "caseC: no rollback line printed: $out"
grep -Fq "\"$td/share/current/scripts/himmelctl/bin.js\"" "$td/bin/himmelctl.js" \
  || fail "caseC: launcher no longer targets current/ after the update"
echo "ok: caseC update extracts share/0.4.0, swaps current, keeps 0.3.0 for rollback, launcher still on current/"

# ── D: a bad checksum extracts nothing and never swaps ───────────────────────
td="$work/caseD"
new_layout "$td" 0.3.0
make_release 0.4.0 "$td/rel"
printf '%064d  himmel-0.4.0-linux.tar.gz\n' 0 > "$td/rel/himmel-0.4.0-linux.tar.gz.sha256"
out=$(run_ctl "$td" update); rc=$?
[ "$rc" -ne 0 ] || fail "caseD: update with a bad checksum exited 0: $out"
grepq "$out" -i 'checksum' || fail "caseD: failure does not name the checksum: $out"
[ "$(readlink "$td/share/current")" = 0.3.0 ] || fail "caseD: current moved on a failed verify"
[ ! -e "$td/share/0.4.0" ] || fail "caseD: share/0.4.0 extracted despite a failed verify"
[ -z "$(compgen -G "$td/share/.[!.]*")" ] || fail "caseD: staging left behind"
echo "ok: caseD bad checksum -> rc $rc, nothing extracted, current unchanged"

# ── E: a failed attestation (gh present + authenticated) extracts nothing ────
td="$work/caseE"
new_layout "$td" 0.3.0
make_release 0.4.0 "$td/rel"
out=$(FAKE_GH_AUTH_RC=0 FAKE_GH_ATTEST_RC=1 run_ctl "$td" update); rc=$?
[ "$rc" -ne 0 ] || fail "caseE: update with a failed attestation exited 0: $out"
grep -Fq 'gh attestation verify' "$td/curl.log" || fail "caseE: attestation was not checked"
[ "$(readlink "$td/share/current")" = 0.3.0 ] || fail "caseE: current moved on a failed attestation"
[ ! -e "$td/share/0.4.0" ] || fail "caseE: share/0.4.0 extracted despite a failed attestation"
echo "ok: caseE failed attestation -> rc $rc, nothing extracted, current unchanged"

# ── F: up to date — nothing downloaded, nothing changed ──────────────────────
td="$work/caseF"
new_layout "$td" 0.4.0
out=$(run_ctl "$td" update); rc=$?
[ "$rc" -eq 0 ] || fail "caseF: up-to-date update exited $rc: $out"
grepq "$out" -i 'up to date' || fail "caseF: no up-to-date status: $out"
[ -s "$td/curl.log" ] && fail "caseF: downloaded while up to date: $(cat "$td/curl.log")"
[ "$(readlink "$td/share/current")" = 0.4.0 ] || fail "caseF: current moved"
echo "ok: caseF up to date -> nothing fetched, current unchanged"

# ── G: the new version dir already exists — refused ─────────────────────────
td="$work/caseG"
new_layout "$td" 0.3.0
make_release 0.4.0 "$td/rel"
mkdir -p "$td/share/0.4.0" && : > "$td/share/0.4.0/operator-file"
out=$(run_ctl "$td" update); rc=$?
[ "$rc" -ne 0 ] || fail "caseG: update over an existing version dir exited 0: $out"
[ -f "$td/share/0.4.0/operator-file" ] || fail "caseG: the existing version dir was touched"
[ "$(readlink "$td/share/current")" = 0.3.0 ] || fail "caseG: current moved"
[ -s "$td/curl.log" ] && fail "caseG: downloaded although the target exists"
echo "ok: caseG existing share/0.4.0 -> refused before any download, left untouched"

# ── H: a tarball whose top dir is not himmel-<version>/ — refused ────────────
td="$work/caseH"
new_layout "$td" 0.3.0
make_release 0.4.0 "$td/rel" himmel-9.9.9
out=$(run_ctl "$td" update); rc=$?
[ "$rc" -ne 0 ] || fail "caseH: update with a mis-rooted tarball exited 0: $out"
[ "$(readlink "$td/share/current")" = 0.3.0 ] || fail "caseH: current moved"
[ ! -e "$td/share/0.4.0" ] || fail "caseH: share/0.4.0 created from a mis-rooted tarball"
[ -z "$(compgen -G "$td/share/.[!.]*")" ] || fail "caseH: staging left behind"
echo "ok: caseH mis-rooted tarball -> refused, nothing swapped"

# ── I: himmel-update.sh's non-git refusal names `himmelctl update` for the ───
# ── versioned layout, and keeps the package/re-extract route otherwise. ─────
out=$(HOME="$td/home" "$bash_bin" "$td/share/current/scripts/himmel-update.sh" 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "caseI: himmel-update.sh on the layout exited $rc (want the rc 1 refusal): $out"
grepq "$out" -F 'himmelctl update' || fail "caseI: the refusal does not name himmelctl update: $out"
flat="$work/caseI-flat"
cp -a "$tree_src" "$flat"
out=$(HOME="$td/home" "$bash_bin" "$flat/scripts/himmel-update.sh" 2>&1); rc=$?
[ "$rc" -eq 1 ] || fail "caseI: himmel-update.sh on a flat tree exited $rc: $out"
grepq "$out" -F 'himmelctl update' && fail "caseI: a flat (non-versioned) tree was sent to himmelctl update: $out"
grepq "$out" -F 'package manager' || fail "caseI: a flat tree lost the package-manager route: $out"
echo "ok: caseI himmel-update.sh routes the layout to himmelctl update, a flat tree to its package manager"

echo "PASS: test-versioned-layout.sh"
