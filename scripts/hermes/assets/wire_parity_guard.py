#!/usr/bin/env python3
"""wire_parity_guard.py — point a hermes profile config.yaml's pre_tool_call
hook at parity_guard.py. Stdlib only (no PyYAML) so it runs under any python.

Three modes:
  set    — replace (or insert) the top-level `hooks:` block with our canonical
           parity_guard pre_tool_call hook. Used for the `himmel_agent`
           profile, whose hooks block this installer owns.
  swap   — non-destructive: if the config already references
           `luna_vault_guard.py`, replace just that filename with
           `parity_guard.py` (keeping the existing interpreter/path and every
           other hook). If no luna_vault_guard reference is found, print SKIP
           and leave the file untouched — never clobbers a user's hooks.
  ensure — universal-guard mode (HIMMEL-744): guarantee the profile carries
           parity_guard, whatever guard state it starts in. Already on
           parity_guard -> no-op; carries luna_vault_guard -> swap it; has NO
           guard hook -> ADD the canonical parity_guard pre_tool_call entry
           WITHOUT clobbering any other hooks the profile already has.

`set` optionally also wires the END-side hook (HIMMEL-2021): pass
<node_bin> <repo_root> and the block gains an `on_session_finalize` entry
running himmel's end-side hooks through run-hook-with-bash.js --chain
--lifecycle. on_session_finalize (not on_session_end) is the once-per-identity
teardown; on_session_end is turn-scoped and would fire every turn. Only
himmel_agent gets it -- `ensure` (the universal guard pass over OTHER
profiles) never writes an end hook, because himmel owns only himmel_agent's
hooks block.

Usage: wire_parity_guard.py <mode> <config.yaml> <guard_path> <interpreter>
                            [<node_bin> <repo_root>]      # set mode only
       (swap ignores guard_path/interpreter.)
Idempotent. Exit 0 on success/skip, non-zero only on bad input.
"""

import sys

# `mcp__.*` extends the matcher to every MCP tool so parity_guard's MCP fence
# (block-backend-tier / block-glm-external-writes parity, HIMMEL-731) actually
# fires — without it, MCP tool calls never invoke the guard.
MATCHER = ("write_file|patch|read_file|search_files|terminal|"
           "delete_file|remove_file|move_file|rename_file|mcp__.*")


def _hook_body(interp: str, guard: str) -> str:
    # the pre_tool_call sub-block, 2-space indented (no top-level `hooks:` line)
    return (
        "  pre_tool_call:\n"
        f"  - matcher: {MATCHER}\n"
        f"    command: '\"{interp}\" \"{guard}\"'\n"
        "    timeout: 10\n"
    )


def _list_item(interp: str, guard: str) -> str:
    # a single pre_tool_call list entry (for appending to an existing list)
    return (
        f"  - matcher: {MATCHER}\n"
        f"    command: '\"{interp}\" \"{guard}\"'\n"
        "    timeout: 10\n"
    )


# The end-side members that make sense on hermes. refresh-where-are-we-on-end
# leaves the next session's ledger current; telegram-session-end is the
# operator-reaching relay. Both are enqueue-and-exit through the HIMMEL-2004
# Stop queue, so neither does real work inside the hook's timeout. Deliberately
# NOT here: end-session-wiki (self-guards off on Windows and its config path is
# Claude-scoped), jira-nudge-on-end (its window is a Claude session's commits)
# and session-run-hook.ts (the census is Claude-scoped).
END_MEMBERS = (
    "scripts/hooks/refresh-where-are-we-on-end.sh",
    "scripts/hooks/telegram-session-end.sh",
)


def _end_body(node: str, repo: str) -> str:
    """The `on_session_finalize` sub-block, 2-space indented.

    ONE entry, not one per member: run-hook-with-bash.js --chain runs every
    member from a single node launch (HIMMEL-2002/2003) and resolves Git Bash
    itself, which a bare `bash` from hermes on Windows would not (the
    System32 WSL-stub trap). --lifecycle marks the chain ADVISORY: every member
    runs, stderr is forwarded, and the chain always exits 0, so an end hook can
    never colour a hermes teardown."""
    # Forward slashes throughout the repo half: hermes splits the command with
    # posix shlex, where a backslash inside double quotes is only special before
    # a quote or another backslash — survivable, but not worth relying on. The
    # interpreter path is left exactly as the installer resolved it.
    repo = repo.replace("\\", "/").rstrip("/")
    launcher = f"{repo}/scripts/hooks/run-hook-with-bash.js"
    members = " ".join(f'"{repo}/{m}"' for m in END_MEMBERS)
    command = f'"{node}" "{launcher}" --chain --lifecycle {members}'
    # A YAML single-quoted scalar escapes an apostrophe by doubling it. An
    # interpreter or checkout path containing one (a Windows profile named
    # O'Brien) would otherwise close the scalar early and yield invalid YAML.
    command = command.replace("'", "''")
    return (
        "  on_session_finalize:\n"
        f"  - command: '{command}'\n"
        "    timeout: 20\n"
    )


def canonical_block(interp: str, guard: str, end_hook=None) -> str:
    block = "hooks:\n" + _hook_body(interp, guard)
    if end_hook:
        block += _end_body(*end_hook)
    return block


def do_set(cfg_path: str, guard: str, interp: str, end_hook=None) -> None:
    with open(cfg_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    block = canonical_block(interp, guard, end_hook)
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith("hooks:") and not ln[:1].isspace():
            start = i
            break
    if start is None:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        new = lines + [block]
    else:
        end = len(lines)
        for j in range(start + 1, len(lines)):
            ln = lines[j]
            if ln.strip() and not ln[:1].isspace():
                end = j
                break
        new = lines[:start] + [block] + lines[end:]
    with open(cfg_path, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(new)
    print(f"set parity_guard hook in {cfg_path}")


def do_swap(cfg_path: str) -> None:
    with open(cfg_path, "r", encoding="utf-8") as f:
        text = f.read()
    if "parity_guard.py" in text and "luna_vault_guard.py" not in text:
        print(f"SKIP {cfg_path}: already on parity_guard")
        return
    if "luna_vault_guard.py" not in text:
        print(f"SKIP {cfg_path}: no luna_vault_guard hook to convert "
              "(left untouched — wire a guard manually if desired)")
        return
    text = text.replace("luna_vault_guard.py", "parity_guard.py")
    with open(cfg_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"swapped luna_vault_guard -> parity_guard in {cfg_path}")


def do_add(cfg_path: str, guard: str, interp: str) -> None:
    """Add the canonical parity_guard pre_tool_call hook to a config that has
    no guard hook, without clobbering any other hooks it already carries."""
    with open(cfg_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    start = None
    for i, ln in enumerate(lines):
        if ln.startswith("hooks:") and not ln[:1].isspace():
            start = i
            break
    if start is None:
        # no `hooks:` key at all -> append a whole canonical block
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        new = lines + [canonical_block(interp, guard)]
    elif lines[start].strip() in ("hooks: {}", "hooks:{}"):
        # empty inline hooks -> replace with the canonical block
        new = lines[:start] + [canonical_block(interp, guard)] + lines[start + 1:]
    else:
        # a populated hooks block: find its extent (until the next top-level key)
        end = len(lines)
        for j in range(start + 1, len(lines)):
            if lines[j].strip() and not lines[j][:1].isspace():
                end = j
                break
        ptc = None
        for k in range(start + 1, end):
            if lines[k].lstrip().startswith("pre_tool_call:"):
                ptc = k
                break
        if ptc is not None:
            # a pre_tool_call list exists (non-guard entries) -> prepend our item
            new = lines[:ptc + 1] + [_list_item(interp, guard)] + lines[ptc + 1:]
        else:
            # hooks present but no pre_tool_call -> insert the sub-block, keeping
            # the other hook types (e.g. post_tool_call) untouched
            new = lines[:start + 1] + [_hook_body(interp, guard)] + lines[start + 1:]
    with open(cfg_path, "w", encoding="utf-8", newline="\n") as f:
        f.writelines(new)
    print(f"added parity_guard hook to {cfg_path}")


def do_ensure(cfg_path: str, guard: str, interp: str) -> None:
    with open(cfg_path, "r", encoding="utf-8") as f:
        text = f.read()
    # already on parity_guard, or carrying luna_vault_guard: do_swap covers both
    # (no-op when already parity; converts luna_vault_guard in place otherwise).
    if "luna_vault_guard.py" in text or "parity_guard.py" in text:
        do_swap(cfg_path)
        return
    do_add(cfg_path, guard, interp)


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    mode, cfg_path = sys.argv[1], sys.argv[2]
    if mode == "set":
        if len(sys.argv) not in (5, 7):
            print("set mode needs: <config> <guard> <interpreter> "
                  "[<node_bin> <repo_root>]", file=sys.stderr)
            return 2
        end_hook = tuple(sys.argv[5:7]) or None
        do_set(cfg_path, sys.argv[3], sys.argv[4], end_hook)
    elif mode == "ensure":
        if len(sys.argv) != 5:
            print("ensure mode needs: <config> <guard> <interpreter>",
                  file=sys.stderr)
            return 2
        do_ensure(cfg_path, sys.argv[3], sys.argv[4])
    elif mode == "swap":
        do_swap(cfg_path)
    else:
        print(f"unknown mode {mode!r} (set|ensure|swap)", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
