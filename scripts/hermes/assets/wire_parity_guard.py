#!/usr/bin/env python3
"""wire_parity_guard.py — point a hermes profile config.yaml's pre_tool_call
hook at parity_guard.py. Stdlib only (no PyYAML) so it runs under any python.

Two modes:
  set   — replace (or insert) the top-level `hooks:` block with our canonical
          parity_guard pre_tool_call hook. Used for the `himmel_agent` profile,
          which this installer owns.
  swap  — non-destructive: if the config already references
          `luna_vault_guard.py`, replace just that filename with
          `parity_guard.py` (keeping the existing interpreter/path and every
          other hook). If no luna_vault_guard reference is found, print SKIP and
          leave the file untouched — never clobbers a user's existing hooks.

Usage: wire_parity_guard.py <mode> <config.yaml> <guard_path> <interpreter>
Idempotent. Exit 0 on success/skip, non-zero only on bad input.
"""

import sys

MATCHER = ("write_file|patch|read_file|search_files|terminal|"
           "delete_file|remove_file|move_file|rename_file")


def canonical_block(interp: str, guard: str) -> str:
    return (
        "hooks:\n"
        "  pre_tool_call:\n"
        f"  - matcher: {MATCHER}\n"
        f"    command: '\"{interp}\" \"{guard}\"'\n"
        "    timeout: 10\n"
    )


def do_set(cfg_path: str, guard: str, interp: str) -> None:
    with open(cfg_path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    block = canonical_block(interp, guard)
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


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    mode, cfg_path = sys.argv[1], sys.argv[2]
    if mode == "set":
        if len(sys.argv) != 5:
            print("set mode needs: <config> <guard> <interpreter>",
                  file=sys.stderr)
            return 2
        do_set(cfg_path, sys.argv[3], sys.argv[4])
    elif mode == "swap":
        do_swap(cfg_path)
    else:
        print(f"unknown mode {mode!r} (set|swap)", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
