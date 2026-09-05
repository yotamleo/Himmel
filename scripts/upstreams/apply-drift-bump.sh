#!/usr/bin/env bash
# scripts/upstreams/apply-drift-bump.sh — mechanically apply ONE upstream pin
# bump (HIMMEL-1323).
#
# WHY: the nightly fork-drift workflow (HIMMEL-1046) only DETECTS drift and
# files a tracking issue; every resolution was a hand-driven ticket, and those
# stall — HIMMEL-1260 ("bump graphify 0.9.22 -> 0.9.23") sat in To Do while the
# pin silently advanced past it in unrelated PRs. The bump itself is two edits
# that MUST move together: the in-repo pin literal (what a fresh machine
# actually installs) and `synced_base` in scripts/upstreams.json (what the drift
# guard compares against). Split them and the guard lies in one direction or the
# other. This script is the structural fix: ONE call moves both, verifies the
# result, and restores both files untouched if anything is off.
#
# It deliberately does NOT resolve "what is upstream's latest" — that is
# scripts/check-plugin-drift.sh's job and it already owns the Releases-API /
# highest-stable-tag logic plus the latest_source escape hatch. Duplicating it
# here would mean a second version comparator to keep in sync (see HIMMEL-1054 /
# HIMMEL-1059, which are still chasing the FIRST one). So the caller reads the
# guard's BEHIND line and passes the target version in. That also keeps this
# script hermetic: no network, no gh, unit-testable offline.
#
# AUTO-BUMPABLE means the registry entry declares `version_pin`:
#     "version_pin": { "file": "<repo-relative path>",
#                      "template": "<literal with a {version} placeholder>" }
# The template must match EXACTLY ONCE in the file at the OLD version. An entry
# without `version_pin` is NOT auto-bumpable and exits 3 (SKIP) without writing
# anything — that is the correct answer for qmd, whose in-repo pin is a fork SHA
# rather than a version: moving its synced_base alone would flip the guard to
# CURRENT while the fork sits unrebased, laundering the signal.
#
# Usage:
#   bash scripts/upstreams/apply-drift-bump.sh <name> <new-version> [--dry-run]
#
# Env / test seams:
#   DRIFT_REGISTRY    registry path (default: <repo>/scripts/upstreams.json).
#                     Same variable name check-plugin-drift.sh uses.
#   DRIFT_REPO_ROOT   root that `version_pin.file` resolves against
#                     (default: the repo this script lives in).
#
# Exit codes:
#   0  bumped (or, with --dry-run, would bump)
#   1  nothing to do — synced_base already equals <new-version>
#   2  usage / unknown entry / wrong kind+mode / malformed registry
#   3  SKIP — entry is not auto-bumpable (no version_pin); handle it manually
#   4  bump required but could NOT be applied safely (pin literal missing,
#      ambiguous, or post-write verification failed) — both files left untouched
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="${DRIFT_REPO_ROOT:-$(cd "$SELF_DIR/../.." && pwd)}"
REGISTRY="${DRIFT_REGISTRY:-$REPO_ROOT/scripts/upstreams.json}"

usage() {
  echo "usage: apply-drift-bump.sh <name> <new-version> [--dry-run]" >&2
  echo "  <name>         a tag_release/base entry in scripts/upstreams.json" >&2
  echo "  <new-version>  the upstream version to pin to (leading 'v' optional)" >&2
  echo "  exit: 0 bumped | 1 already current | 2 usage/registry | 3 SKIP not" >&2
  echo "        auto-bumpable (no version_pin) | 4 bump failed, files restored" >&2
}

NAME=""
NEW_VER=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 2 ;;
    -*) echo "apply-drift-bump: unknown flag '$1'" >&2; usage; exit 2 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      elif [ -z "$NEW_VER" ]; then NEW_VER="$1"
      else echo "apply-drift-bump: unexpected extra argument '$1'" >&2; usage; exit 2
      fi
      ;;
  esac
  shift
done

if [ -z "$NAME" ] || [ -z "$NEW_VER" ]; then
  usage
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "apply-drift-bump: python3 not on PATH — cannot parse the registry." >&2
  exit 2
fi
if [ ! -f "$REGISTRY" ]; then
  echo "apply-drift-bump: registry not found: $REGISTRY" >&2
  exit 2
fi

# The whole transaction (validate -> edit both files -> re-verify -> restore on
# any failure) lives in python: it is the only interpreter here that can re-parse
# the JSON to PROVE the edit landed as intended, and reading/writing with
# newline='' keeps CRLF/LF exactly as found (this repo is worked on from Windows).
python3 - "$REGISTRY" "$REPO_ROOT" "$NAME" "$NEW_VER" "$DRY_RUN" <<'PY'
import json, os, re, sys

reg_path, repo_root, name, new_raw, dry = sys.argv[1:6]
dry = dry == "1"

def die(code, msg):
    sys.stderr.write("apply-drift-bump: %s\n" % msg)
    sys.exit(code)

def read_text(p):
    with open(p, "r", encoding="utf-8", newline="") as fh:
        return fh.read()

def write_text(p, s):
    with open(p, "w", encoding="utf-8", newline="") as fh:
        fh.write(s)

VER_RE = re.compile(r'^v?[0-9]+(\.[0-9]+)*([0-9A-Za-z.\-+]*)$')

def norm(v):
    return v[1:] if v.startswith("v") else v

def numeric_key(v):
    # Compare only the leading dotted-numeric run; a trailing suffix
    # (-rc1, .post2, +local) is ignored for ordering. Enough for the ONE
    # question asked here: "is this a downgrade?".
    m = re.match(r'^([0-9]+(?:\.[0-9]+)*)', v)
    if not m:
        return ()
    return tuple(int(x) for x in m.group(1).split("."))

def cmp_ver(a, b):
    ka, kb = numeric_key(a), numeric_key(b)
    n = max(len(ka), len(kb))
    ka = ka + (0,) * (n - len(ka))
    kb = kb + (0,) * (n - len(kb))
    return (ka > kb) - (ka < kb)

if not VER_RE.match(new_raw):
    die(2, "target version %r is not a version string" % new_raw)
new_ver = norm(new_raw)

try:
    reg_text = read_text(reg_path)
    reg = json.loads(reg_text)
except Exception as exc:                     # malformed registry is never a bump
    die(2, "could not parse registry %s: %s" % (reg_path, exc))

entries = reg.get("entries", [])
match = [e for e in entries if e.get("name") == name]
if not match:
    die(2, "no registry entry named %r in %s" % (name, reg_path))
if len(match) > 1:
    die(2, "registry has %d entries named %r — names must be unique" % (len(match), name))
entry = match[0]

if entry.get("kind") != "tag_release" or entry.get("mode") != "base":
    die(2, "entry %r is kind=%s mode=%s — only tag_release/base carries an in-repo "
           "version pin this script can move" % (name, entry.get("kind"), entry.get("mode")))

old_ver = norm(entry.get("synced_base") or "")
if not old_ver:
    die(2, "entry %r has no synced_base" % name)

if old_ver == new_ver:
    print("nothing to do: %s synced_base is already %s" % (name, new_ver))
    sys.exit(1)

if cmp_ver(new_ver, old_ver) < 0:
    # A transient Releases-API blip (or a yanked release) must never roll a pin
    # BACKWARDS unattended — that would silently downgrade every fresh machine.
    die(2, "refusing to downgrade %s: synced_base %s > requested %s" % (name, old_ver, new_ver))

pin = entry.get("version_pin")
if not pin:
    print("SKIP %s: no version_pin declared — not auto-bumpable, handle manually "
          "(%s -> %s)" % (name, old_ver, new_ver))
    sys.exit(3)
if not isinstance(pin, dict) or not pin.get("file") or not pin.get("template"):
    die(2, "entry %r has a malformed version_pin (need {file, template})" % name)

pin_rel, template = pin["file"], pin["template"]
n_ph = template.count("{version}")
if n_ph != 1:
    # EXACTLY one, as documented (CR round-7 codex-2). The old check only
    # required at least one, so a two-placeholder template was accepted and then
    # silently expanded both — the file-level uniqueness check below would catch
    # most of the damage, but the registry is the place to reject a malformed
    # template, not the place to survive one.
    die(2, "entry %r version_pin.template must contain {version} exactly once "
           "(found %d)" % (name, n_ph))
# The registry is in-repo, but a pin path is still a write target: keep it
# provably inside the repo rather than trusting the field.
if os.path.isabs(pin_rel) or ".." in pin_rel.replace("\\", "/").split("/"):
    die(2, "entry %r version_pin.file must be a repo-relative path without '..' "
           "(got %r)" % (name, pin_rel))
pin_path = os.path.join(repo_root, pin_rel)
if not os.path.isfile(pin_path):
    die(4, "version_pin file not found: %s" % pin_path)

old_lit = template.replace("{version}", old_ver)
new_lit = template.replace("{version}", new_ver)

pin_text = read_text(pin_path)
hits = pin_text.count(old_lit)
if hits != 1:
    die(4, "pin literal %r occurs %d time(s) in %s — expected exactly 1; "
           "fix version_pin.template in the registry" % (old_lit, hits, pin_rel))

# --- registry edit: rewrite synced_base INSIDE this entry only ---------------
# A bare `"synced_base": "<old>"` replace would be ambiguous the moment two
# entries share a version, so anchor on this entry's "name" key and take the
# FIRST synced_base after it (name is the entry's leading key in this file).
name_m = re.search(r'"name"\s*:\s*"%s"' % re.escape(name), reg_text)
if not name_m:
    die(4, 'could not locate the "name": "%s" key in %s' % (name, reg_path))
sb_m = re.compile(r'("synced_base"\s*:\s*")%s(")' % re.escape(entry["synced_base"])) \
         .search(reg_text, name_m.end())
if not sb_m:
    die(4, "could not locate this entry's synced_base literal in %s" % reg_path)
new_reg_text = reg_text[:sb_m.start()] + sb_m.group(1) + new_ver + sb_m.group(2) \
             + reg_text[sb_m.end():]
new_pin_text = pin_text.replace(old_lit, new_lit)

files = "%s, %s" % (os.path.relpath(reg_path, repo_root).replace("\\", "/"), pin_rel)
if dry:
    print("DRY %s %s -> %s (files: %s)" % (name, old_ver, new_ver, files))
    sys.exit(0)

# The registry write is inside the restore-protected region too (CR codex-3).
# It used to sit OUTSIDE any try: a failure part-way through THAT write (disk
# full, a lock, a permissions flip) left scripts/upstreams.json truncated or
# half-written with nothing to put it back — the one outcome this script exists
# to make impossible. Restoring from `reg_text` is safe even when the write
# never started, so the guard costs nothing.
try:
    write_text(reg_path, new_reg_text)
except Exception as exc:
    try:
        write_text(reg_path, reg_text)
    except Exception:
        die(4, "could not write %s (%s) AND could not restore it — inspect the "
               "file by hand before re-running" % (reg_path, exc))
    die(4, "could not write %s (%s) — registry restored" % (reg_path, exc))
try:
    write_text(pin_path, new_pin_text)
except Exception as exc:
    # The failed open(p, "w") in write_text TRUNCATED the pin file before the
    # write raised, so restoring only the registry (as this used to) leaves the
    # pin empty — contradicting the "both files are left untouched" invariant
    # restore() below guarantees. Restore the pin from pin_text too (CR round-9).
    try:
        write_text(reg_path, reg_text)
        write_text(pin_path, pin_text)
    except Exception:
        die(4, "could not write %s (%s) AND could not restore the files — inspect "
               "both files by hand before re-running" % (pin_rel, exc))
    die(4, "could not write %s (%s) — both files restored" % (pin_rel, exc))

# --- verify, or put both files back exactly as they were ---------------------
def restore(msg):
    try:
        write_text(reg_path, reg_text)
        write_text(pin_path, pin_text)
    except Exception as exc:
        die(4, "%s — AND the restore failed (%s); inspect both files by hand" % (msg, exc))
    die(4, "%s — both files restored" % msg)

try:
    after = json.loads(read_text(reg_path))
except Exception as exc:
    restore("registry no longer parses after the edit (%s)" % exc)

def without_sb(e):
    return {k: v for k, v in e.items() if k != "synced_base"}

before_entries, after_entries = entries, after.get("entries", [])
if len(after_entries) != len(before_entries):
    restore("entry count changed (%d -> %d)" % (len(before_entries), len(after_entries)))
for b, a in zip(before_entries, after_entries):
    if b.get("name") == name:
        if a.get("synced_base") != new_ver:
            restore("entry %r synced_base is %r, expected %r"
                    % (name, a.get("synced_base"), new_ver))
        if without_sb(a) != without_sb(b):
            restore("entry %r changed beyond synced_base" % name)
    elif a != b:
        restore("unrelated entry %r was modified" % b.get("name"))

verify_pin = read_text(pin_path)
if verify_pin.count(new_lit) != 1 or verify_pin.count(old_lit) != 0:
    restore("pin literal in %s did not land exactly once" % pin_rel)

print("BUMP %s %s -> %s (files: %s)" % (name, old_ver, new_ver, files))
sys.exit(0)
PY
exit $?
