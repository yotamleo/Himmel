#!/usr/bin/env bash
# scripts/upstreams/resync-fork.sh — mechanically audit (and, on request,
# push) a rebase of a TRUE FORK's delta onto a newer upstream base
# (HIMMEL-1323 follow-up).
#
# WHY a third script instead of extending the other two: apply-drift-bump.sh
# moves a version PIN (a text literal); apply-tool-upgrade.sh upgrades an
# INSTALLED BINARY. Neither fits a carried fork. himmel carries both SHA-pinned
# forks (qmd) and installable-tag-pinned forks (claude-obsidian), each with its
# own delta on top of a recorded upstream base (`synced_base` in
# scripts/upstreams.json). When upstream tags past that base, bumping
# synced_base alone would claim the fork sits on a base it never rebased onto
# — laundering the exact signal the entry exists to raise. The honest repair
# is: resolve the current SHA or fork tag to a commit, rebase that delta onto
# the new base, audit whether it is additive, then hand the operator a new SHA
# to review. This script does the mechanical, verifiable half; a human (or an
# agent session) drives the judgment call on the result.
#
# Some forks are deliberately NOT strictly additive. claude-obsidian removes
# upstream hooks and patches locking, so its audit is expected to report
# NON-ADDITIVE (rc=4). That is still a useful nightly result: the cadence stops
# after this report, never pushes, and surfaces rebase feasibility + touched
# paths for operator judgment.
#
# STRICTLY ADDITIVE, defined: every path touched by the fork's own delta
# (the commits reachable from the pinned SHA but not from the recorded base)
# has git diff --name-status code 'A' (Added) against that base — i.e. the
# fork only introduces NEW files; it never modifies or deletes a file that
# already existed in upstream at the base. Anything else (M/D/R/C) means the
# fork's delta touches upstream's own content, which is exactly the risk a
# re-sync is supposed to surface, not paper over. This is checked against the
# delta's OWN base (not the rebase target) because it is a property of what
# the fork carries, independent of which upstream commit it gets replayed
# onto — a clean rebase onto a newer base does not change what the fork
# itself touches.
#
# This is a SEPARATE, and stronger, question than "did the rebase conflict?"
# A rebase can conflict on a pure addition (upstream added the same path with
# different content between base and target — an add/add conflict) even
# though the fork's own delta is perfectly additive; conversely a rebase can
# apply CLEANLY even when the fork modifies an upstream file, if upstream
# never touched that file. Both facts are reported; either one failing means
# a human must look before the pin moves (rc=4).
#
# Never touches a live install or the operator's checkout: all git work
# happens in a throwaway clone under fork.work_dir (env-expanded, cross-
# platform). Never edits fork.pin_file — moving the pin is
# apply-drift-bump.sh-shaped work that happens after review. Never writes to
# any remote unless --push is given, and refuses to push a conflicted or
# non-additive result outright.
#
# Usage:
#   bash scripts/upstreams/resync-fork.sh <name> [--target <ref>] [--dry-run] [--push]
#
# <name>     an entry in scripts/upstreams.json that declares a `fork` block:
#              "fork": {
#                "fork_repo":     "<git URL/path of the himmel fork>",
#                "upstream_repo": "<git URL/path of the true upstream>",
#                "pin_file":      "<repo-relative path carrying the pin>",
#                "pin_template":  "<literal with {sha}, exactly once>" OR
#                "pin_ref_template": "<literal with {ref}, exactly once>",
#                "work_dir":      "<scratch clone location, $VAR/${VAR}/%VAR% expanded>"
#              }
#            declared on a kind=tag_release/mode=base entry (it needs
#            `synced_base` as the resync's base tag). pin_ref_template is for
#            an immutable installable TAG (for example claude-obsidian's
#            marketplace ref); the tag is resolved to a commit before audit.
# --target   upstream ref (tag or branch) to rebase onto. Default: the
#            highest stable version tag on upstream_repo (same discipline as
#            check-plugin-drift.sh — sort -V-shaped comparison, prereleases
#            excluded).
# --dry-run  run the full audit (nothing here mutates fork_repo/upstream_repo
#            or the operator's checkout regardless) but never push, even if
#            --push is also given.
# --push     push the rebased branch to fork_repo, as
#            refs/heads/himmel-resync/<name>, force-updating any prior
#            attempt. Refused outright if the rebase conflicted or the delta
#            is not strictly additive.
#
# Env / test seams (same names + meaning as the sibling scripts):
#   DRIFT_REGISTRY    registry path (default: <repo>/scripts/upstreams.json).
#   DRIFT_REPO_ROOT   root that `fork.pin_file` resolves against
#                     (default: the repo this script lives in).
#
# Exit codes:
#   0  rebase clean, delta strictly additive (report includes the new SHA)
#   1  nothing to do — the target resolves to the same commit as the
#      entry's recorded synced_base (upstream hasn't advanced past it)
#   2  usage / unknown entry / wrong kind+mode / malformed registry or fork
#      block / missing tooling (git, python3) / target or base ref would not
#      resolve
#   3  SKIP — the entry declares no `fork` block (not a tracked resync target)
#   4  rebase CONFLICTED, or the delta is NOT strictly additive, OR a
#      pin-literal failure (PIN_FILE_MISSING / PIN_NOT_FOUND / PIN_AMBIGUOUS —
#      a stale fork.pin_file/pin_template/pin_ref_template, not a rebase
#      problem) — a human must resolve it; nothing was pushed
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="${DRIFT_REPO_ROOT:-$(cd "$SELF_DIR/../.." && pwd)}"
REGISTRY="${DRIFT_REGISTRY:-$REPO_ROOT/scripts/upstreams.json}"

usage() {
  echo "usage: resync-fork.sh <name> [--target <ref>] [--dry-run] [--push]" >&2
  echo "  <name>     a tag_release/base entry in scripts/upstreams.json that declares a 'fork' block" >&2
  echo "  --target   upstream ref to rebase onto (default: latest stable tag)" >&2
  echo "  --dry-run  run the audit, never push (even with --push)" >&2
  echo "  --push     push the rebased branch to fork_repo when clean + additive" >&2
  echo "  exit: 0 clean+additive | 1 already on target | 2 usage/registry/refs" >&2
  echo "        | 3 SKIP no fork block | 4 conflicted/non-additive or pin-literal (PIN_FILE_MISSING/PIN_NOT_FOUND/PIN_AMBIGUOUS)" >&2
}

NAME=""
TARGET=""
DRY_RUN=0
PUSH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target)
      if [ $# -lt 2 ]; then
        echo "resync-fork: --target requires a value" >&2
        usage; exit 2
      fi
      TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#--target=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --push)    PUSH=1; shift ;;
    -h|--help) usage; exit 2 ;;
    -*) echo "resync-fork: unknown flag '$1'" >&2; usage; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then
        NAME="$1"
      else
        echo "resync-fork: unexpected extra argument '$1'" >&2
        usage; exit 2
      fi
      shift ;;
  esac
done

if [ -z "$NAME" ]; then
  usage
  exit 2
fi

# NAME is later composed into CLONE_DIR ("$WORK_DIR/$NAME") which gets
# `rm -rf`'d both before and after the clone -- keep it a plain path
# component, the same discipline the fork.pin_file check below applies to a
# registry-sourced path.
case "$NAME" in
  */*|*..*)
    echo "resync-fork: '$NAME' is not a safe registry entry name (no '/' or '..' allowed) -- refusing to compose a scratch-clone path from it" >&2
    exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "resync-fork: python3 not on PATH — cannot parse the registry." >&2
  exit 2
fi
if ! command -v git >/dev/null 2>&1; then
  echo "resync-fork: git not on PATH — cannot audit anything." >&2
  exit 2
fi
if [ ! -f "$REGISTRY" ]; then
  echo "resync-fork: registry not found: $REGISTRY" >&2
  exit 2
fi

# --------------------------------------------------------------------------
# Resolve the entry + its fork block, and pull the CURRENT pinned SHA out of
# pin_file. One python pass (like apply-drift-bump.sh's transaction): it is
# the only interpreter here that can safely regex the pin literal out of an
# arbitrary text file. Emits ONE \x1f-joined status line; classification
# happens in bash below so every failure gets its own rc + message, mirroring
# apply-drift-bump.sh's die() taxonomy (shape problems -> 2, content problems
# against an existing file -> 4).
#
# `| tr -d '\r'` is load-bearing, not cosmetic: python's stdout is text-mode
# on Windows, so every line comes back CRLF-terminated, which would leave a
# trailing \r baked into the extracted SHA / paths (this bit the sibling
# scripts already — see check-plugin-drift.sh / apply-tool-upgrade.sh).
entry_out=$(python3 - "$REGISTRY" "$NAME" "$REPO_ROOT" <<'PY' 2>&1 | tr -d '\r'
import json, os, re, sys

reg_path, name, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]

def out(status, *fields):
    print('\x1f'.join([status] + [str(f) for f in fields]))

try:
    reg = json.load(open(reg_path, encoding='utf-8'))
except Exception as exc:
    sys.stderr.write('resync-fork: could not parse registry %s: %s\n' % (reg_path, exc))
    sys.exit(2)

entries = reg.get('entries', [])
match = [e for e in entries if e.get('name') == name]
if not match:
    out('NO_ENTRY'); sys.exit(0)
if len(match) > 1:
    out('DUP_ENTRY'); sys.exit(0)
entry = match[0]

fork = entry.get('fork')
if not fork:
    out('NO_FORK'); sys.exit(0)

if entry.get('kind') != 'tag_release' or entry.get('mode') != 'base':
    out('WRONG_KIND', entry.get('kind', ''), entry.get('mode', '')); sys.exit(0)

synced_base = entry.get('synced_base') or ''
if not synced_base:
    out('NO_SYNCED_BASE'); sys.exit(0)

if not isinstance(fork, dict):
    out('MALFORMED_FORK', 'fork is not an object'); sys.exit(0)

required = ['fork_repo', 'upstream_repo', 'pin_file', 'work_dir']
missing = [k for k in required if not fork.get(k)]
if missing:
    out('MALFORMED_FORK', ','.join(missing)); sys.exit(0)

pin_file = fork['pin_file']
sha_template = fork.get('pin_template') or ''
ref_template = fork.get('pin_ref_template') or ''
if bool(sha_template) == bool(ref_template):
    out('MALFORMED_FORK', 'declare exactly one of pin_template or pin_ref_template'); sys.exit(0)
if sha_template:
    pin_kind, pin_template, placeholder = 'sha', sha_template, '{sha}'
else:
    pin_kind, pin_template, placeholder = 'ref', ref_template, '{ref}'

# Same repo-relative safety as apply-drift-bump.sh's version_pin.file: the
# registry is in-repo, but a pin path is still a READ target here (and would
# be a write target for whatever eventually moves the pin), so keep it
# provably inside the repo rather than trusting the field.
if os.path.isabs(pin_file) or '..' in pin_file.replace('\\', '/').split('/'):
    out('BAD_PIN_PATH', pin_file); sys.exit(0)

if pin_template.count(placeholder) != 1:
    out('BAD_PLACEHOLDER', 'pin_template' if pin_kind == 'sha' else 'pin_ref_template', placeholder); sys.exit(0)

pin_path = os.path.join(repo_root, pin_file)
if not os.path.isfile(pin_path):
    out('PIN_FILE_MISSING', pin_path); sys.exit(0)

with open(pin_path, encoding='utf-8', newline='') as fh:
    text = fh.read()

# Unlike apply-drift-bump.sh (which already KNOWS the old version from
# synced_base, so it can look for an exact literal), this script does not know
# the pin in advance — extracting it IS the point. A SHA template accepts a
# short-or-full hex commit; a ref template accepts the installable tag spelling
# from marketplace.json, then the shell resolves that exact tag to a commit.
prefix, suffix = pin_template.split(placeholder)
value_rx = r'([0-9a-fA-F]{7,40})' if pin_kind == 'sha' else r'([0-9A-Za-z][0-9A-Za-z._/-]*)'
rx = re.compile(re.escape(prefix) + value_rx + re.escape(suffix))
hits = rx.findall(text)
if len(hits) == 0:
    out('PIN_NOT_FOUND', pin_template); sys.exit(0)
if len(hits) > 1:
    out('PIN_AMBIGUOUS', str(len(hits))); sys.exit(0)
old_pin = hits[0]

def expand(p):
    # Cross-platform env expansion ($VAR / ${VAR} / %VAR%), mirroring
    # check-plugin-drift.sh's expand() helper so work_dir resolves the same
    # way that script's checkout_path does.
    def rep(m):
        return os.environ.get(m.group(1) or m.group(2), '')
    p = re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)', rep, p)
    p = re.sub(r'%([A-Za-z_][A-Za-z0-9_]*)%', lambda m: os.environ.get(m.group(1), ''), p)
    return os.path.expanduser(p).replace('\\', '/')

work_dir = expand(fork['work_dir'])
# An unresolved $VAR/${VAR}/%VAR% collapses to '', so a work_dir like
# "${HOME}/.himmel/fork-resync" with HOME unset would resolve to
# "/.himmel/fork-resync" -- and this script `rm -rf`s a subdirectory of
# work_dir before every clone. `mkdir -p` on that path usually fails first,
# but not when the process is root (containers/CI), so refuse an expansion
# that plainly didn't fully resolve rather than rely on that.
if not work_dir or work_dir.startswith('/.') or work_dir == '/' or '//' in work_dir:
    out('BAD_WORK_DIR', fork['work_dir'], work_dir); sys.exit(0)

out('OK', fork['fork_repo'], fork['upstream_repo'], pin_file, work_dir, synced_base, pin_kind, old_pin)
PY
)
entry_rc=$?

if [ "$entry_rc" -ne 0 ]; then
  [ -n "$entry_out" ] && printf '%s\n' "$entry_out" >&2
  exit 2
fi

STATUS=""
F1=""; F2=""; F3=""; F4=""; F5=""; F6=""; F7=""
IFS=$'\x1f' read -r STATUS F1 F2 F3 F4 F5 F6 F7 <<< "$entry_out"

case "$STATUS" in
  NO_ENTRY)
    echo "resync-fork: no registry entry named '$NAME' in $REGISTRY" >&2
    exit 2 ;;
  DUP_ENTRY)
    echo "resync-fork: registry has more than one entry named '$NAME' — names must be unique" >&2
    exit 2 ;;
  NO_FORK)
    echo "resync-fork: SKIP $NAME — no 'fork' block declared. This script only resyncs a" >&2
    echo "    true fork (a pinned SHA carrying its own delta); a plain tag_release/commit_head" >&2
    echo "    entry has nothing here to rebase." >&2
    exit 3 ;;
  WRONG_KIND)
    echo "resync-fork: entry '$NAME' is kind=$F1 mode=$F2 — a 'fork' block requires" >&2
    echo "    kind=tag_release mode=base (the resync needs synced_base as the rebase base)." >&2
    exit 2 ;;
  NO_SYNCED_BASE)
    echo "resync-fork: entry '$NAME' has a 'fork' block but no synced_base — malformed." >&2
    exit 2 ;;
  MALFORMED_FORK)
    echo "resync-fork: entry '$NAME' has a malformed 'fork' block: $F1" >&2
    exit 2 ;;
  BAD_PIN_PATH)
    echo "resync-fork: entry '$NAME' fork.pin_file must be a repo-relative path without '..' (got '$F1')" >&2
    exit 2 ;;
  BAD_PLACEHOLDER)
    echo "resync-fork: entry '$NAME' fork.$F1 must contain the $F2 placeholder exactly once" >&2
    exit 2 ;;
  PIN_FILE_MISSING)
    echo "resync-fork: fork.pin_file not found: $F1" >&2
    exit 4 ;;
  PIN_NOT_FOUND)
    echo "resync-fork: pin literal (template '$F1') not found in $REPO_ROOT — fix the fork pin template" >&2
    exit 4 ;;
  PIN_AMBIGUOUS)
    echo "resync-fork: pin literal occurs $F1 time(s) — expected exactly 1; fix the fork pin template" >&2
    exit 4 ;;
  BAD_WORK_DIR)
    echo "resync-fork: entry '$NAME' fork.work_dir did not fully resolve — refusing to mkdir/rm -rf it:" >&2
    echo "    template : $F1" >&2
    echo "    resolved : $F2" >&2
    echo "    likely an unresolved \$VAR/\${VAR}/%VAR% (e.g. HOME unset) collapsing to ''" >&2
    exit 2 ;;
  OK) : ;;
  *)
    echo "resync-fork: internal error — unrecognized parser status '$STATUS'" >&2
    exit 2 ;;
esac

FORK_REPO="$F1"
UPSTREAM_REPO="$F2"
PIN_FILE="$F3"
WORK_DIR="$F4"
SYNCED_BASE="$F5"
PIN_KIND="$F6"
OLD_PIN="$F7"
OLD_SHA=""

# --------------------------------------------------------------------------
# highest_version: same "highest major.minor.patch via sort -V-shaped compare"
# discipline as check-plugin-drift.sh's helper of the same name, reimplemented
# locally rather than sourced — the sibling apply-*.sh scripts each carry
# their own small version comparator instead of a shared lib, and this stays
# consistent with that.
highest_version() {
  python3 -c '
import re, sys
def numprefix(s):
    m = re.match(r"\d+", s)
    return int(m.group()) if m else 0
def key(v):
    v = v.strip().lstrip("vV")
    parts = (v.split(".") + ["0", "0", "0"])[:3]
    return tuple(numprefix(p) for p in parts)
lines = [l.strip() for l in sys.stdin if l.strip()]
if lines:
    print(max(lines, key=key))
' | tr -d '\r'
}

# --------------------------------------------------------------------------
# Scratch clone. A FRESH clone every run (never reused across invocations):
# this is a throwaway audit workspace, not a persistent install, so there is
# no staleness risk worth the complexity of trying to update one in place —
# and starting fresh means a prior run's half-finished rebase can never leak
# into this one's verdict.
if ! mkdir -p "$WORK_DIR" 2>/dev/null; then
  echo "resync-fork: could not create work_dir: $WORK_DIR" >&2
  exit 2
fi
CLONE_DIR="$WORK_DIR/$NAME"
rm -rf "$CLONE_DIR"

clone_err=$(git clone --quiet --origin fork "$FORK_REPO" "$CLONE_DIR" 2>&1)
clone_rc=$?
if [ "$clone_rc" -ne 0 ]; then
  echo "resync-fork: could not clone fork_repo '$FORK_REPO' into $CLONE_DIR" >&2
  printf '%s\n' "$clone_err" >&2
  exit 2
fi

# Local-only identity (never global): a rebase replays each commit as a NEW
# commit object with a fresh committer, which git refuses without an
# identity — and a bare CI runner may have none configured at all.
git -C "$CLONE_DIR" config user.email "resync-fork@himmel.local"
git -C "$CLONE_DIR" config user.name "himmel resync-fork"
# Local-only signing OFF: a machine with commit.gpgsign=true globally (SSH
# signing through an agent — 1Password's SSH agent on this project's own dev
# boxes) would otherwise make every replayed commit block on an interactive
# signing prompt during the rebase below. This is a scratch audit clone, not
# a repo anyone will inspect provenance on, so unsigned commits here are fine
# — the operator's own signing setup is untouched (this is a local, not
# global, override).
git -C "$CLONE_DIR" config commit.gpgsign false
# Local-only, never global: a machine-wide core.hooksPath (some setups wire
# every repo on the box to a shared hooks dir, e.g. for an indexing tool)
# would otherwise fire arbitrary hooks on the checkout below and on every
# replayed commit during the rebase. Pointing hooksPath back at this clone's
# own .git/hooks (populated with only inert *.sample files) restores git's
# real default for this scratch clone specifically.
git -C "$CLONE_DIR" config core.hooksPath .git/hooks

if [ "$PIN_KIND" = "ref" ]; then
  if ! git check-ref-format "refs/tags/$OLD_PIN" >/dev/null 2>&1; then
    echo "resync-fork: pinned ref '$OLD_PIN' (from $PIN_FILE) is not a valid immutable tag name" >&2
    exit 2
  fi
  if ! git -C "$CLONE_DIR" show-ref --verify --quiet "refs/tags/$OLD_PIN"; then
    echo "resync-fork: pinned tag '$OLD_PIN' (from $PIN_FILE) was not found in the fork clone" >&2
    echo "    — is the marketplace pin stale, or was the tag never pushed to fork_repo?" >&2
    exit 2
  fi
  OLD_SHA=$(git -C "$CLONE_DIR" rev-parse "refs/tags/${OLD_PIN}^{commit}")
else
  if ! git -C "$CLONE_DIR" cat-file -e "${OLD_PIN}^{commit}" 2>/dev/null; then
    echo "resync-fork: pinned commit $OLD_PIN (from $PIN_FILE) was not found in the fork clone" >&2
    echo "    — is the pin stale, or does fork_repo not carry the branch it's on?" >&2
    exit 2
  fi
  OLD_SHA=$(git -C "$CLONE_DIR" rev-parse "${OLD_PIN}^{commit}")
fi

if ! git -C "$CLONE_DIR" remote add upstream "$UPSTREAM_REPO" 2>&1; then
  echo "resync-fork: could not add upstream_repo '$UPSTREAM_REPO' as a remote" >&2
  exit 2
fi
# Upstream tags land in a namespace of their own (refs/upstream-tags/*), not
# the standard refs/tags/*: fork and upstream can legitimately carry
# same-named tags (himmel's own fork tags, e.g. v2.6.3-himmel.1, vs upstream's
# v2.6.3), and git tags are not remote-namespaced the way branches are — a
# plain `fetch upstream --tags` would collide them.
fetch_err=$(git -C "$CLONE_DIR" fetch --quiet upstream \
  '+refs/heads/*:refs/remotes/upstream/*' '+refs/tags/*:refs/upstream-tags/*' 2>&1)
fetch_rc=$?
if [ "$fetch_rc" -ne 0 ]; then
  echo "resync-fork: could not fetch upstream_repo '$UPSTREAM_REPO'" >&2
  printf '%s\n' "$fetch_err" >&2
  exit 2
fi

# resolve_upstream_tag <name> — tolerant of a leading 'v' either way (the
# registry's synced_base is typically bare, e.g. "2.5.3", while upstream tags
# are often "v2.5.3"). Prints the resolved commit SHA, rc 1 if none of the
# candidate spellings exist.
resolve_upstream_tag() {
  local want="$1" cand ref
  for cand in "$want" "v$want" "${want#v}"; do
    ref="refs/upstream-tags/$cand"
    if git -C "$CLONE_DIR" show-ref --verify --quiet "$ref"; then
      git -C "$CLONE_DIR" rev-parse "$ref"
      return 0
    fi
  done
  return 1
}

BASE_SHA=$(resolve_upstream_tag "$SYNCED_BASE")
if [ -z "$BASE_SHA" ]; then
  echo "resync-fork: could not resolve synced_base '$SYNCED_BASE' as a tag on upstream_repo" >&2
  echo "    '$UPSTREAM_REPO' (tried with and without a leading 'v')." >&2
  exit 2
fi

TARGET_LABEL=""
TARGET_SHA=""
if [ -n "$TARGET" ]; then
  TARGET_SHA=$(resolve_upstream_tag "$TARGET")
  if [ -z "$TARGET_SHA" ] && git -C "$CLONE_DIR" show-ref --verify --quiet "refs/remotes/upstream/$TARGET"; then
    TARGET_SHA=$(git -C "$CLONE_DIR" rev-parse "refs/remotes/upstream/$TARGET")
  fi
  if [ -z "$TARGET_SHA" ]; then
    echo "resync-fork: could not resolve --target '$TARGET' as a tag or branch on upstream_repo '$UPSTREAM_REPO'" >&2
    exit 2
  fi
  TARGET_LABEL="$TARGET"
else
  tags_raw=$(git -C "$CLONE_DIR" for-each-ref --format='%(refname)' refs/upstream-tags/ \
    | while IFS= read -r ref; do printf '%s\n' "${ref#refs/upstream-tags/}"; done)
  stable=""
  if [ -n "$tags_raw" ]; then
    stable=$(printf '%s\n' "$tags_raw" | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
  fi
  if [ -z "$stable" ]; then
    echo "resync-fork: no stable version tags found on upstream_repo '$UPSTREAM_REPO' — pass --target explicitly" >&2
    exit 2
  fi
  TARGET_LABEL=$(printf '%s\n' "$stable" | highest_version)
  TARGET_SHA=$(resolve_upstream_tag "$TARGET_LABEL")
fi

if [ "$TARGET_SHA" = "$BASE_SHA" ]; then
  echo "resync-fork: $NAME is already on the target base — synced_base '$SYNCED_BASE' and"
  echo "    target '$TARGET_LABEL' both resolve to $TARGET_SHA. Nothing to resync."
  exit 1
fi

# Never resync onto an OLDER upstream base: that would replay the fork's delta
# backwards and, with --push, publish a regression as "clean". apply-drift-bump.sh
# refuses the analogous downgrade for a plain pin; this is the fork equivalent.
if git -C "$CLONE_DIR" merge-base --is-ancestor "$TARGET_SHA" "$BASE_SHA" 2>/dev/null; then
  echo "resync-fork: refusing to resync $NAME BACKWARDS — target '$TARGET_LABEL' ($TARGET_SHA)" >&2
  echo "    is an ancestor of synced_base '$SYNCED_BASE' ($BASE_SHA)." >&2
  exit 2
fi

# --------------------------------------------------------------------------
# The fork's own delta: everything the fork carries that upstream's recorded
# base does not. Computed against BASE_SHA (never the rebase target) — see
# the "STRICTLY ADDITIVE" note in the file header for why.
delta_log=$(git -C "$CLONE_DIR" log --oneline "$BASE_SHA..$OLD_SHA")
delta_stat=$(git -C "$CLONE_DIR" diff --stat "$BASE_SHA" "$OLD_SHA")
delta_status=$(git -C "$CLONE_DIR" diff --name-status "$BASE_SHA" "$OLD_SHA")

NON_ADDITIVE=()
while IFS=$'\t' read -r st a b; do
  [ -n "$st" ] || continue
  if [ "$st" = "A" ]; then
    continue
  fi
  if [ -n "$b" ]; then
    NON_ADDITIVE+=("$st  $a -> $b")
  else
    NON_ADDITIVE+=("$st  $a")
  fi
done <<< "$delta_status"

ADDITIVE=1
if [ "${#NON_ADDITIVE[@]}" -gt 0 ]; then
  ADDITIVE=0
fi

# --------------------------------------------------------------------------
# Attempt the rebase on a disposable temp branch. A conflict is captured
# (unmerged paths named) and then aborted so the clone is left clean — this
# is an audit, not a hand-off of an in-progress conflict for someone else to
# find half-resolved in a shared scratch dir.
git -C "$CLONE_DIR" checkout --quiet -b resync-tmp "$OLD_SHA"
rebase_out=$(git -C "$CLONE_DIR" rebase --onto "$TARGET_SHA" "$BASE_SHA" resync-tmp 2>&1)
rebase_rc=$?

CONFLICT_PATHS=""
NEW_SHA=""
if [ "$rebase_rc" -ne 0 ]; then
  CONFLICT_PATHS=$(git -C "$CLONE_DIR" diff --name-only --diff-filter=U 2>/dev/null)
  git -C "$CLONE_DIR" rebase --abort >/dev/null 2>&1 || true
else
  NEW_SHA=$(git -C "$CLONE_DIR" rev-parse resync-tmp)
fi

# --------------------------------------------------------------------------
# Report, machine-readably enough to grep, human-readably enough to read.
echo "== resync-fork: $NAME =="
echo "  fork_repo:      $FORK_REPO"
echo "  upstream_repo:  $UPSTREAM_REPO"
if [ "$PIN_KIND" = "ref" ]; then
  echo "  pinned tag:     $OLD_PIN -> $OLD_SHA  (from $PIN_FILE)"
else
  echo "  pinned SHA:     $OLD_PIN  (resolved $OLD_SHA; from $PIN_FILE)"
fi
echo "  base:           $SYNCED_BASE  ($BASE_SHA)"
echo "  target:         $TARGET_LABEL  ($TARGET_SHA)"
echo ""
echo "  fork delta (base..pinned):"
if [ -n "$delta_log" ]; then
  printf '%s\n' "$delta_log" | sed 's/^/    /'
else
  echo "    (no commits — the fork is at its own recorded base)"
fi
echo ""
printf '%s\n' "$delta_stat" | sed 's/^/  /'
echo ""
if [ "$ADDITIVE" -eq 1 ]; then
  echo "  additive:       YES — every changed path is a NEW file the fork adds; the delta"
  echo "                  modifies or deletes no file that already existed upstream."
else
  echo "  additive:       NO — the delta touches existing upstream file(s):"
  for line in "${NON_ADDITIVE[@]}"; do
    echo "    $line"
  done
fi
echo ""
if [ "$rebase_rc" -ne 0 ]; then
  echo "  rebase:         CONFLICTED onto $TARGET_LABEL"
  echo "  conflicting paths:"
  if [ -n "$CONFLICT_PATHS" ]; then
    printf '%s\n' "$CONFLICT_PATHS" | sed 's/^/    /'
  else
    echo "    (rebase failed before producing unmerged paths — see below)"
    printf '%s\n' "$rebase_out" | sed 's/^/    /'
  fi
else
  echo "  rebase:         CLEAN onto $TARGET_LABEL"
  echo "  new SHA:        $NEW_SHA"
fi
echo ""

if [ "$rebase_rc" -ne 0 ]; then
  FINAL_RC=4
elif [ "$ADDITIVE" -ne 1 ]; then
  FINAL_RC=4
else
  FINAL_RC=0
fi

if [ "$PUSH" -eq 1 ]; then
  if [ "$FINAL_RC" -ne 0 ]; then
    echo "resync-fork: --push refused — the result above is not clean+additive; nothing was pushed." >&2
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY resync-fork: --dry-run set — would push resync-tmp to $FORK_REPO:refs/heads/himmel-resync/$NAME (skipped)"
  else
    push_ref="refs/heads/himmel-resync/$NAME"
    push_err=$(git -C "$CLONE_DIR" push --quiet --force fork "resync-tmp:$push_ref" 2>&1)
    push_rc=$?
    if [ "$push_rc" -ne 0 ]; then
      echo "resync-fork: push to $FORK_REPO failed:" >&2
      printf '%s\n' "$push_err" >&2
      exit 2
    fi
    echo "resync-fork: pushed rebased branch to $FORK_REPO ($push_ref)"
  fi
fi

if [ "$FINAL_RC" -eq 0 ]; then
  echo "resync-fork: rebase clean, delta additive. Review $CLONE_DIR (branch resync-tmp, $NEW_SHA),"
  echo "    then move the pin by hand — this script never edits $PIN_FILE itself:"
  if [ "$PIN_KIND" = "ref" ]; then
    echo "      1. cut and push a NEW immutable fork tag at $NEW_SHA (current tag: $OLD_PIN)"
    echo "      2. replace $OLD_PIN with that new tag in $PIN_FILE"
    echo "      3. bump synced_base for '$NAME' in scripts/upstreams.json from $SYNCED_BASE to $TARGET_LABEL"
  else
    echo "      1. replace $OLD_PIN with $NEW_SHA in $PIN_FILE"
    echo "      2. bump synced_base for '$NAME' in scripts/upstreams.json from $SYNCED_BASE to $TARGET_LABEL"
  fi
  echo "    (apply-drift-bump.sh does not cover fork SHA/tag pins, so this stays a"
  echo "    reviewed, hand-driven step.)"
else
  echo "resync-fork: a human must review or resolve this before the pin can move (see above)." >&2
fi

exit "$FINAL_RC"
