#!/usr/bin/env python3
"""triage-mark-processed.py — the ONE path /triage-clips uses to mark a clip
processed (Phase 7) and move it to Clippings/_evidence/ (Phase 8). HIMMEL-4685.

Why a tool and not prose: the 2026-10-07 cadence run fanned triage out to
parallel subagents that marked and moved clips with their own helper scripts,
skipping the stale-read SHA check and the ln-based move. Both were prose the
agent had to remember. Here they are code, and the runbook routes every mark
and move (main loop, debt drain, any subagent) through this file.

Usage:
  triage-mark-processed.py <vault> <clip> --expect-sha <LAST_WRITE_SHA>
                           [--summary-basis url-only] [--today YYYY-MM-DD] [--dry-run]
  triage-mark-processed.py <vault> <clip> --drain [--dry-run]

The SHA path runs Phase 7 (stale-read guard, then processed/triaged_at/
evidence_pending in ONE frontmatter edit) and then Phase 8. --drain resumes
Phase 8 only, for a clip whose frontmatter already carries processed: true AND
evidence_pending: true (the recorded debt, HIMMEL-1713).

Phase 8, in order: ig_media_pending hold; evidence_kind + quoted, round-tripped
evidence_origin (one edit); the <OLD> identifier set; ambiguity guard; link
the clip to _evidence/<basename>.md (ln then unlink; never overwrite); literal
six-form inbound-link rewrite; verify zero; clear evidence_pending and
evidence_origin (the commit point). Every failure after the mark is
forward-only: the debt marker stays set and the next run's drain resumes.

stdout carries exactly one result line:
  OK moved → _evidence/<basename>.md, <L> links rewritten      exit 0
  DRY-RUN would move → _evidence/<basename>.md, <L> links ...    exit 0
  HELD stays in inbox (ig_media_pending), evidence_pending set   exit 10
  USAGE <reason>                                                 exit 2
  SKIP phase-7-mark: <reason>    (nothing written)               exit 3 stale, 4 other
  SKIP phase-8-move: <reason>    (evidence_pending stays set)    exit 5
The caller logs a SKIP as `⊘ <clip> — skipped (<phase>): <reason>`.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

DELIM = re.compile(r"^---\s*$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
SUMMARY_BASES = ("url-only",)


class Stop(Exception):
    def __init__(self, code, line):
        super().__init__(line)
        self.code = code
        self.line = line


def skip7(reason, code=4):
    return Stop(code, f"SKIP phase-7-mark: {reason}")


def skip8(reason):
    return Stop(5, f"SKIP phase-8-move: {reason}")


# ── file + frontmatter helpers ──────────────────────────────────────────────

def read_text(path):
    # surrogateescape keeps any non-UTF-8 byte intact across a rewrite.
    return Path(path).read_bytes().decode("utf-8", "surrogateescape")


def write_text(path, text):
    """Write via a sibling temp file + rename, so a crash never leaves a
    half-written clip or note."""
    p = Path(path)
    tmp = p.with_name(f".{p.name}.triage-tmp-{os.getpid()}")
    tmp.write_bytes(text.encode("utf-8", "surrogateescape"))
    try:
        os.chmod(tmp, os.stat(p).st_mode & 0o7777)
    except OSError:
        pass
    os.replace(tmp, p)


def split_fm(text):
    """(lines, close_index) for a COMPLETE leading --- block, else None.
    Delimiters match tolerantly so a CRLF clip still has frontmatter."""
    lines = text.splitlines(keepends=True)
    if not lines or not DELIM.match(lines[0].rstrip("\n")):
        return None
    for i in range(1, len(lines)):
        if DELIM.match(lines[i].rstrip("\n")):
            return lines, i
    return None


def fm_lines(fm):
    lines, close = fm
    return [l.rstrip("\r\n") for l in lines[1:close]]


def fm_true(fm, key):
    pat = re.compile(r"^" + re.escape(key) + r":\s*true\s*$")
    return any(pat.match(l) for l in fm_lines(fm))


def fm_has(fm, key):
    return any(l.startswith(key + ":") for l in fm_lines(fm))


def fm_scalar(fm, key):
    for l in fm_lines(fm):
        if l.startswith(key + ":"):
            v = l[len(key) + 1:].strip()
            if len(v) >= 2 and v[0] == v[-1] == "'":
                return v[1:-1].replace("''", "'")
            if len(v) >= 2 and v[0] == v[-1] == '"':
                return v[1:-1]
            return v
    return None


def fm_tags(fm):
    ls = fm_lines(fm)
    for i, l in enumerate(ls):
        if not l.startswith("tags:"):
            continue
        rest = l[5:].strip()
        if rest.startswith("["):
            return [t.strip().strip("'\"") for t in rest.strip("[]").split(",") if t.strip()]
        out = []
        for nxt in ls[i + 1:]:
            m = re.match(r"^\s+-\s+(.*)$", nxt)
            if not m:
                break
            out.append(m.group(1).strip().strip("'\""))
        return out
    return []


def eol_of(fm):
    lines, close = fm
    return "\r\n" if lines[close].endswith("\r\n") else "\n"


def insert_before_close(text, new_lines):
    """Placement contract: new zero-indent keys go immediately before the
    closing ---, i.e. after every existing key and every block list."""
    fm = split_fm(text)
    lines, close = fm
    eol = eol_of(fm)
    return "".join(lines[:close] + [l + eol for l in new_lines] + lines[close:])


def drop_keys(text, keys):
    lines, close = split_fm(text)
    kept = [l for l in lines[1:close] if not any(l.startswith(k + ":") for k in keys)]
    return "".join([lines[0]] + kept + lines[close:])


def yaml_ok(text):
    """Parse-before-write. PyYAML is optional (same stance as
    harvest-clip-body-batch.py): without it, the structural checks stand."""
    fm = split_fm(text)
    if fm is None:
        return False
    try:
        import yaml  # type: ignore
    except ImportError:
        return True
    try:
        return isinstance(yaml.safe_load("".join(fm[0][1:fm[1]])), dict)
    except Exception:
        return False


def yaml_scalar(text, key):
    try:
        import yaml  # type: ignore
    except ImportError:
        return fm_scalar(split_fm(text), key)
    fm = split_fm(text)
    return (yaml.safe_load("".join(fm[0][1:fm[1]])) or {}).get(key)


def quote(s):
    return "'" + s.replace("'", "''") + "'"


def nlink_of(path):
    return os.stat(path).st_nlink


# ── links ───────────────────────────────────────────────────────────────────

def six_forms(ident):
    base = f"[[Clippings/{ident}"
    return [base + "]]", base + "|", base + "#", base + ".md]]", base + ".md|", base + ".md#"]


def vault_md_files(vault):
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in files:
            if f.endswith(".md"):
                yield os.path.join(root, f)


def count_links(vault, members):
    total = 0
    for f in vault_md_files(vault):
        t = read_text(f)
        for m in members:
            for form in six_forms(m):
                total += t.count(form)
    return total


def rewrite_links(vault, members, new):
    for f in vault_md_files(vault):
        t = read_text(f)
        out = t
        for m in members:
            for old_form, new_form in zip(six_forms(m), six_forms(new)):
                out = out.replace(old_form, new_form)
        if out != t:
            write_text(f, out)


# ── the move (ln, then unlink; never overwrite) ─────────────────────────────

def move(clip, dest):
    """Returns None on success, else ALIAS-STUCK / COLLISION / MOVE-FAILED.
    link() is atomic and fails when the destination exists, so the check and
    the claim are one operation. A failed link is NOT a collision unless the
    destination is actually occupied: exFAT and many sync mounts cannot
    hard-link, and there the move degrades to `mv -n` with a postcondition
    check (its exit status varies by coreutils version)."""
    if os.path.lexists(dest) and os.path.exists(dest) and os.path.samefile(clip, dest):
        if os.path.abspath(clip) == os.path.abspath(dest):
            return None  # single name, already at the destination
        if nlink_of(clip) >= 2 and not os.path.islink(dest):
            # An interrupted ln+unlink: both names on one inode. Drop the source.
            try:
                os.unlink(clip)
            except OSError:
                pass
            if os.path.lexists(clip) or not os.path.isfile(dest):
                return "ALIAS-STUCK"
            return None
        # Same inode via a symlink: unlinking the clip would delete its only
        # real entry. Refuse.
        return "ALIAS-STUCK"
    try:
        os.link(clip, dest)
    except OSError:
        if os.path.lexists(dest):
            return "COLLISION"
        subprocess.run(["mv", "-n", "--", clip, dest], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if os.path.lexists(clip):
            return "COLLISION" if os.path.lexists(dest) else "MOVE-FAILED"
        return None
    try:
        os.unlink(clip)
    except OSError:
        pass
    return "ALIAS-STUCK" if os.path.lexists(clip) else None


MOVE_REASONS = {
    "ALIAS-STUCK": "source alias survived unlink; clip is linked at two paths",
    "COLLISION": "_evidence/{b} already holds a different clip; needs an operator rename",
    "MOVE-FAILED": "move to _evidence/{b} failed; will resume next run (evidence_pending set)",
}


# ── phases ──────────────────────────────────────────────────────────────────

def evidence_kind(plugin_dir, fm):
    url = fm_scalar(fm, "harvest_url_canonical") or fm_scalar(fm, "source") or ""
    cmd = ["node", str(plugin_dir / "lib" / "evidence-kind.mjs"),
           "--type", fm_scalar(fm, "type") or "", "--url", url,
           "--tags", ",".join(fm_tags(fm))]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, check=True)
        kinds = json.loads(r.stdout)
    except (OSError, subprocess.CalledProcessError, ValueError) as e:
        raise skip8(f"evidence-kind.mjs failed ({e}); will resume next run (evidence_pending set)")
    if not isinstance(kinds, list) or not kinds:
        raise skip8("evidence-kind.mjs returned no kinds; will resume next run (evidence_pending set)")
    return [str(k) for k in kinds]


def phase8(vault, clip, dry_run, tools_dir):
    clippings = os.path.join(vault, "Clippings")
    evidence = os.path.join(clippings, "_evidence")
    text = read_text(clip)
    fm = split_fm(text)
    if fm is None:
        raise skip8("frontmatter unparseable; will resume next run (evidence_pending set)")
    if fm_true(fm, "ig_media_pending"):
        if dry_run:
            return 0, "DRY-RUN would stay in inbox (ig_media_pending), 0 links would be rewritten"
        return 10, "HELD stays in inbox (ig_media_pending), evidence_pending set"

    basename = os.path.basename(clip)
    dest = os.path.join(evidence, basename)
    in_evidence = os.path.abspath(os.path.dirname(clip)) == os.path.abspath(evidence)
    cur_id = os.path.relpath(clip, clippings).replace(os.sep, "/")[:-3]
    new = "_evidence/" + basename[:-3]
    origin = fm_scalar(fm, "evidence_origin")

    if in_evidence and origin is None:
        raise skip8("evidence_origin missing; needs a manual Phase 8")

    # Step 1: evidence_kind + evidence_origin in ONE edit (idempotent). The
    # origin is checkpointed even when evidence_kind is already present: a
    # moved clip without it can never be resumed.
    need_kind = not fm_has(fm, "evidence_kind")
    if (need_kind or origin is None) and not dry_run:
        add = []
        if need_kind:
            kinds = evidence_kind(tools_dir, fm)
            add = ["evidence_kind:"] + [f"  - {k}" for k in kinds]
        if origin is None:
            add.append("evidence_origin: " + quote(cur_id))
        new_text = insert_before_close(text, add)
        if not yaml_ok(new_text):
            raise skip8("evidence_kind/evidence_origin write would be invalid YAML; will resume next run (evidence_pending set)")
        write_text(clip, new_text)
        if origin is None:
            if yaml_scalar(read_text(clip), "evidence_origin") != cur_id:
                raise skip8("evidence_origin did not round-trip byte for byte; will resume next run (evidence_pending set)")
            origin = cur_id

    # The <OLD> identifier set: the recorded origin is authoritative; the
    # current inbox id joins it only while the clip is still in the inbox.
    members = []
    if origin is not None:
        members.append(origin)
    if not in_evidence and cur_id not in members:
        members.append(cur_id)
    if new in members:
        raise skip8(f"<OLD> set contains the destination {new}; needs a manual Phase 8")

    # Ambiguity guard: [[Clippings/foo.md]] is both foo.md.md's plain link and
    # foo's .md form. Refuse only when the colliding sibling really exists.
    for m in members:
        a = m.endswith(".md") and os.path.exists(os.path.join(clippings, m[:-3] + ".md"))
        b = os.path.exists(os.path.join(clippings, m + ".md.md"))
        if a or b:
            raise skip8(f"[[Clippings/{m}.md]] is claimed by two clips; six-form rewrite cannot disambiguate — rename one of them")

    links = count_links(vault, members)
    if dry_run:
        return 0, f"DRY-RUN would move → _evidence/{basename}, {links} links would be rewritten"

    os.makedirs(evidence, exist_ok=True)
    # Parallel workers own disjoint clips but share the notes that link to
    # them: serialise the move + read-modify-replace rewrite + verify on an
    # exclusive lock held on the Clippings/ directory itself.
    lock = os.open(clippings, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        err = move(clip, dest)
        if err:
            raise skip8(MOVE_REASONS[err].format(b=basename))
        rewrite_links(vault, members, new)
        left = count_links(vault, members)
    finally:
        os.close(lock)
    if left:
        raise skip8(f"{left} links pending; will resume next run (evidence_pending set)")

    # Commit point: the clip owes nothing once the verify is clean.
    write_text(dest, drop_keys(read_text(dest), ("evidence_pending", "evidence_origin")))
    return 0, f"OK moved → _evidence/{basename}, {links} links rewritten"


def phase7(clip, expect_sha, today, summary_basis, dry_run):
    raw = Path(clip).read_bytes()
    if hashlib.sha256(raw).hexdigest() != expect_sha:
        raise skip7("user-edit detected mid-pass (stale read), skipping to avoid clobbering manual edits", code=3)
    text = raw.decode("utf-8", "surrogateescape")
    fm = split_fm(text)
    if fm is None:
        raise skip7("no complete leading frontmatter block")
    if fm_true(fm, "processed"):
        raise skip7("already processed: true; a clip owing Phase 8 is resumed with --drain")
    if dry_run:
        return
    add = ["processed: true", f"triaged_at: {today}", "evidence_pending: true"]
    if summary_basis:
        add.append(f"summary_basis: {summary_basis}")
    # Replace, never duplicate, a prior value of a key this phase owns.
    owned = ("processed", "triaged_at", "evidence_pending", "summary_basis")
    new_text = insert_before_close(drop_keys(text, owned), add)
    if not yaml_ok(new_text):
        raise skip7("proposed frontmatter would be invalid YAML; aborting")
    # Re-check immediately before the write: the guard must hold at the
    # moment of mutation, not only at the top of the call.
    if hashlib.sha256(Path(clip).read_bytes()).hexdigest() != expect_sha:
        raise skip7("user-edit detected mid-pass (stale read), skipping to avoid clobbering manual edits", code=3)
    write_text(clip, new_text)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("vault")
    ap.add_argument("clip")
    ap.add_argument("--expect-sha")
    ap.add_argument("--drain", action="store_true")
    ap.add_argument("--summary-basis", choices=SUMMARY_BASES)
    ap.add_argument("--today", default=datetime.date.today().isoformat())
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)

    vault = os.path.abspath(a.vault)
    clip = os.path.abspath(a.clip)
    clippings = os.path.join(vault, "Clippings")
    tools_dir = Path(__file__).resolve().parent

    def usage(msg):
        print(f"USAGE {msg}")
        return 2

    if not os.path.isdir(clippings):
        return usage(f"no Clippings/ under {vault}")
    if not clip.endswith(".md") or not os.path.isfile(clip):
        return usage(f"clip is not an existing .md file: {clip}")
    if os.path.commonpath([os.path.realpath(clip), os.path.realpath(clippings)]) != os.path.realpath(clippings):
        return usage(f"clip is not under {clippings}")
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", a.today):
        return usage("--today must be YYYY-MM-DD")

    try:
        if a.drain:
            if a.expect_sha or a.summary_basis:
                return usage("--drain resumes Phase 8 only; it takes no --expect-sha or --summary-basis")
            fm = split_fm(read_text(clip))
            if fm is None or not (fm_true(fm, "processed") and fm_true(fm, "evidence_pending")):
                raise skip7("--drain needs processed: true AND evidence_pending: true in frontmatter; an unprocessed clip goes through --expect-sha")
        else:
            if not a.expect_sha:
                return usage("--expect-sha <LAST_WRITE_SHA> is required; the stale-read guard cannot run without it")
            sha = a.expect_sha.split()[0].lower()
            if not SHA_RE.match(sha):
                return usage(f"--expect-sha is not a SHA-256 hex digest: {a.expect_sha!r}")
            phase7(clip, sha, a.today, a.summary_basis, a.dry_run)
        code, line = phase8(vault, clip, a.dry_run, tools_dir)
    except Stop as s:
        print(s.line)
        return s.code
    print(line)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
