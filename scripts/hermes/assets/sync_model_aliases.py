#!/usr/bin/env python3
"""sync_model_aliases.py — sync the top-level `model_aliases:` block from a
hermes root config.yaml into a profile config.yaml. Stdlib only (no PyYAML)
so it runs under any python.

hermes's one-shot dispatch path loads the PROFILE config, not the root
config. The root config carries the `model_aliases:` block (qwen aliases +
openrouter fallback target); a profile cloned before those aliases existed
never picks up new/changed aliases on its own — a bare `-m qwen-plus` then
falls through to catalog detection and breaks (HIMMEL-737). This keeps the
profile's block synced to the root's on every install/refresh.

Behavior:
  - locate the top-level `model_aliases:` block in the root config (the line
    starting `model_aliases:` at column 0 through the last following line
    that is indented or blank, stopping before the next top-level key).
  - if absent: print `SKIP <root>: no model_aliases block` and exit 0,
    leaving the profile untouched.
  - profile lacks the block: append the root's block verbatim at EOF.
  - profile has the block: MERGE, not wholesale replace (codex CR —
    profiles are user-editable and the installer advertises non-destructive
    refresh). Root aliases win for every key present in root; alias keys
    that exist ONLY in the profile are preserved — their whole sub-block is
    appended after the root entries, in stable profile order — and reported
    on one line (`preserved profile-only aliases: x, y`). Within the block
    an alias key line is exactly-2-space indented, first char not
    space/#/-, terminated by the LAST colon at end-of-line or before an
    inline value — so slash keys, plain colon-bearing keys (`a/b:free`) and
    quoted keys all round-trip; one layer of surrounding quotes is stripped
    for the root-vs-profile name comparison. A sub-block runs until the
    next alias key or block end (column-0 comments travel with the
    sub-block they follow). FAIL CLOSED: a non-blank, non-comment
    2-space-indented line that is not a recognizable alias key and has no
    sub-block to attach to aborts the merge — `ERR: cannot merge
    model_aliases in <path>: unrecognized entry '<line>'` + exit 2, profile
    untouched — silent drop is the one forbidden outcome (codex CR).
  - the rest of the profile content is preserved line-for-line (a rewrite
    normalizes line endings to LF: text-mode read + newline="\n" write).
    Idempotent — re-running produces no change. Writes are atomic (codex
    CR): a temp file in the target's directory, then os.replace(), so a
    failed write can never truncate the live profile config.

Usage: sync_model_aliases.py <root_config.yaml> <profile_config.yaml>
Exit 0 on success/skip, exit 2 on bad usage / unreadable or unwritable files.
"""

import os
import re
import sys
import tempfile

# an alias key inside the model_aliases block: exactly-2-space indent, first
# char not space/#/- (deeper nesting, comments and list items excluded). The
# terminating colon is the LAST colon at end-of-line or before an inline
# value, so plain colon-bearing keys round-trip (`  a/b:free:` -> `a/b:free`)
# and quoted keys are captured whole (codex CR round 3 — the narrow
# [A-Za-z0-9_.-]+ matcher silently attached such keys to the previous entry).
ALIAS_KEY_RE = re.compile(r"^  (?![\s#-])(.+):(?:\s.*)?$")


def _key_name(raw):
    """Comparison name for an alias key: one layer of surrounding quotes
    stripped — applied identically to root and profile keys so the
    root-vs-profile set comparison stays consistent."""
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in "\"'":
        return raw[1:-1]
    return raw


def _find_block(lines, key):
    """Return the [start, end) line-index range of the top-level `<key>:`
    block, or None if the key has no top-level occurrence. A column-0
    full-line comment does NOT terminate the block (in YAML it is not a new
    top-level key — treating it as one truncated the copied aliases, codex
    CR); comments adjacent to the block therefore travel with it."""
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith(key + ":") and not ln[:1].isspace():
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        ln = lines[j]
        if ln.strip() and not ln[:1].isspace() and not ln.lstrip().startswith("#"):
            end = j
            break
    return start, end


def _split_aliases(body):
    """Split a model_aliases block body (the lines AFTER the header line)
    into an ordered list of (name, [lines]) sub-blocks. A sub-block runs
    from its alias key line to the next alias key line or block end, so
    comments/blank lines travel with the sub-block they follow. Lines
    before the first alias key are returned separately as the preamble.
    FAIL CLOSED (codex CR round 3): a non-blank, non-comment line at
    exactly-2-space indent that is not a recognizable alias key and has no
    current sub-block to attach to raises ValueError(line) — silently
    dropping a user-edited entry is the one forbidden outcome."""
    preamble, entries = [], []
    cur_name, cur_lines = None, []
    for ln in body:
        m = ALIAS_KEY_RE.match(ln)
        if m:
            if cur_name is not None:
                entries.append((cur_name, cur_lines))
            cur_name, cur_lines = _key_name(m.group(1)), [ln]
        elif cur_name is None:
            stripped = ln.strip()
            if (ln.startswith("  ") and not ln[2:3].isspace()
                    and stripped and not stripped.startswith("#")):
                raise ValueError(ln.rstrip("\n"))
            preamble.append(ln)
        else:
            cur_lines.append(ln)
    if cur_name is not None:
        entries.append((cur_name, cur_lines))
    return preamble, entries


def _write_atomic(path, lines):
    """Write lines to path atomically: temp file in the same directory,
    then os.replace() — a failed write never truncates the live config
    (codex CR). Raises OSError to the caller on either step."""
    d = os.path.dirname(os.path.abspath(path))
    tmp = tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="\n",
                                      dir=d, delete=False)
    try:
        with tmp:
            tmp.writelines(lines)
        os.replace(tmp.name, path)
    except OSError:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass
        raise


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    root_path, profile_path = sys.argv[1], sys.argv[2]

    try:
        with open(root_path, "r", encoding="utf-8") as f:
            root_lines = f.readlines()
    except OSError as e:
        print(f"ERR: cannot read {root_path}: {e}", file=sys.stderr)
        return 2

    span = _find_block(root_lines, "model_aliases")
    if span is None:
        print(f"SKIP {root_path}: no model_aliases block")
        return 0
    r_start, r_end = span
    block = root_lines[r_start:r_end]
    if block and not block[-1].endswith("\n"):
        block[-1] += "\n"

    try:
        with open(profile_path, "r", encoding="utf-8") as f:
            profile_lines = f.readlines()
    except OSError as e:
        print(f"ERR: cannot read {profile_path}: {e}", file=sys.stderr)
        return 2

    p_span = _find_block(profile_lines, "model_aliases")
    preserved_names = []
    if p_span is None:
        if profile_lines and not profile_lines[-1].endswith("\n"):
            profile_lines[-1] += "\n"
        new = profile_lines + block
        action = "appended"
    else:
        p_start, p_end = p_span
        # merge: root block verbatim (root wins for keys present in root),
        # then any profile-only alias sub-blocks, in stable profile order
        try:
            _, root_entries = _split_aliases(block[1:])
        except ValueError as e:
            print(f"ERR: cannot merge model_aliases in {root_path}: "
                  f"unrecognized entry '{e.args[0]}'", file=sys.stderr)
            return 2
        try:
            _, prof_entries = _split_aliases(profile_lines[p_start + 1:p_end])
        except ValueError as e:
            print(f"ERR: cannot merge model_aliases in {profile_path}: "
                  f"unrecognized entry '{e.args[0]}'", file=sys.stderr)
            return 2
        root_names = {name for name, _ in root_entries}
        merged = list(block)
        for name, sub in prof_entries:
            if name not in root_names:
                preserved_names.append(name)
                merged.extend(sub)
        if merged and not merged[-1].endswith("\n"):
            merged[-1] += "\n"
        if profile_lines[p_start:p_end] == merged:
            print(f"OK {profile_path}: model_aliases already in sync")
            return 0
        new = profile_lines[:p_start] + merged + profile_lines[p_end:]
        action = "merged" if preserved_names else "replaced"

    try:
        _write_atomic(profile_path, new)
    except OSError as e:
        print(f"ERR: cannot write {profile_path}: {e}", file=sys.stderr)
        return 2
    if preserved_names:
        print("preserved profile-only aliases: " + ", ".join(preserved_names))
    print(f"{action} model_aliases block in {profile_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
