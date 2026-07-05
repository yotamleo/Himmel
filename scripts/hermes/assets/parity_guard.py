#!/usr/bin/env python3
"""parity_guard.py — Hermes pre_tool_call guard (main-tier / Claude-parity).

Installed by scripts/hermes/install-himmel-profile.sh onto the `himmel_agent`
profile. The main tier does real engineering work — edit code, rewrite vault
pages, run git, open PRs — so the WRITE allowlist and the routine git/gh/rm
shell blocks of the junior `luna_vault_guard.py` are DROPPED. What stays is
exactly what the senior tier (Claude / himmel) also enforces:

  SELF-PROTECTION — the agent may not write its own guard, any hermes
                    config.yaml / SOUL.md, or Claude Code's home (no widening
                    its own rules or identity).
  READ fence      — secrets refused (.env, ssh keys, credential stores,
                    channel tokens) — parity with himmel block-read-secrets.
  TERMINAL        — refuses (a) shell that reads secret/guard/Claude-home paths
                    and (b) CATASTROPHIC, shared-machine, or irreversible
                    classes only: recursive/forced deletion (rm -r/-rf, del /s),
                    disk wipe, scheduler mutation, process killing,
                    shutdown/registry/perm tools, force-push, git reset --hard /
                    clean -f / filter-branch, and curl|sh / wget|sh remote-exec.
                    Routine git, gh, mv, cp, and non-recursive rm are ALLOWED
                    (outward-facing ones are governed by SOUL.md "confirm
                    first", not a hard block).

Paths are resolved from the environment so this ships to any machine:
HERMES_HOME (else %LOCALAPPDATA%\\hermes, else ~/.local/share/hermes) and
~/.claude. Wire protocol: JSON on stdin; '{}' = allow,
'{"decision":"block","reason":...}' = block. Fail-CLOSED on any internal error.
"""

import json
import os
import re
import sys


def norm(p: str) -> str:
    return p.replace("\\", "/").strip().strip('"').strip("'").lower()


def _hermes_home() -> str:
    h = os.environ.get("HERMES_HOME")
    if h:
        return h
    la = os.environ.get("LOCALAPPDATA")
    if la:
        return os.path.join(la, "hermes")
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return os.path.join(xdg, "hermes")
    return os.path.join(os.path.expanduser("~"), ".local", "share", "hermes")


HERMES_HOME = norm(_hermes_home())
CLAUDE_HOME = norm(os.path.join(os.path.expanduser("~"), ".claude"))
GUARD_HOME = HERMES_HOME + "/agent-hooks"

WRITE_TOOLS = ("write_file", "patch")
DELETE_TOOLS = ("delete_file", "remove_file", "move_file", "rename_file")
READ_TOOLS = ("read_file", "search_files")

SECRET_READ = re.compile(
    r"(\.env(\.[a-z0-9]+)?$)|(\.envrc$)"
    r"|((^|/)\.ssh/)"
    r"|((^|/)(id_rsa|id_ed25519)$)"
    r"|(\.pem$)|(\.key$)|(\.p12$)|(\.pfx$)"
    r"|(secrets\.ya?ml$)"
    r"|(/\.claude/channels/)"
    r"|(\.git-credentials)"
    r"|(/gh/hosts\.yml$)"
    r"|(credentials\.json$)|(auth\.json$)"
)

# Keys whose value is file CONTENT, not a path — excluded from path checks so
# we don't false-block a write whose body merely mentions a guarded path.
CONTENT_KEYS = ("content", "contents", "text", "body", "data",
                "new_str", "old_str", "new_string", "old_string")

# Shell paths still off-limits: secrets, the guard itself, Claude home.
# (The vault and repos are NOT shell-forbidden — the main tier works there.)
TERMINAL_FORBIDDEN_PATHS = re.compile(
    re.escape(GUARD_HOME)
    + "|" + re.escape(CLAUDE_HOME)
    + r"|\.env\b|/\.ssh/|\.git-credentials|hosts\.yml|\.pem\b|\.key\b"
)

# Catastrophic / shared-machine / irreversible classes only.
# Routine git, gh, mv, cp, and non-recursive rm are intentionally NOT here.
TERMINAL_DESTRUCTIVE = re.compile(
    r"\brm\b[^|;&\n]*\s-\w*r"                 # recursive rm (rm -r / -rf / -Rf)
    r"|\brm\b[^|;&\n]*--recursive"
    r"|\b(del|erase|rd|rmdir)\b[^|;&\n]*/s"   # recursive Windows delete
    r"|\bformat\b|\bmkfs|\bdiskpart\b|\bcipher\s+/w|\bbcdedit\b"
    r"|\bschtasks\b"                          # protects scheduled jobs
    r"|\btaskkill\b|\bstop-process\b|\bpskill\b|\bkill\s+-9"
    r"|\bshutdown\b|\breboot\b|\blogoff\b"
    r"|\breg\s+(add|delete)\b|\bicacls\b|\btakeown\b"
    r"|\bgit\s+push\b[^|;&\n]*(--force|--force-with-lease|\s-f\b)"
    r"|\bgit\s+(reset\s+--hard|clean\s+-\w*f|filter-branch)\b"
    r"|\bcurl[^|;&]*\|\s*(ba)?sh|\bwget[^|;&]*\|\s*(ba)?sh"
)


def block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


def allow() -> None:
    print("{}")
    sys.exit(0)


def _under(path: str, root: str) -> bool:
    """True if `path` is `root` itself or a descendant — boundary-aware so a
    sibling like `<home>-backup` is not a false match (paths are normalized)."""
    return path == root or path.startswith(root + "/")


def check_write_path(path: str) -> None:
    """Block writes to the guard, any hermes config/SOUL, or Claude's home."""
    if _under(path, GUARD_HOME):
        block("Writes to the guard hook are forbidden — the main tier may not "
              "rewrite its own guard. Ask the operator if genuinely needed.")
    if _under(path, HERMES_HOME) and (
        path.endswith("/config.yaml") or path.endswith("/soul.md")
    ):
        block("Writes to a hermes config.yaml / SOUL.md are forbidden — the "
              "main tier may not rewrite its own config or identity.")
    if _under(path, CLAUDE_HOME):
        block("Writes into Claude Code's home are forbidden.")


# --- PHI / data-egress fence (HIMMEL-695, F-B5) ------------------------------
# parity_guard runs on the himmel_agent (CLOUD) profile — every engine hermes
# routes through it (openai/codex AND z.ai/GLM) is a third-party cloud. Sending
# PHI-marked material to any of them is a data-egress violation, so this fence
# fires UNCONDITIONALLY on this profile ("both engines" per F-B5 — no engine
# gate is needed because the profile has no local engine). Semantics mirror
# scripts/telegram/glm-guard.ts checkGlmGuards (KEEP IN SYNC): a path is PHI if
# a `.salus` marker sits at it or any ancestor, or it is under a root listed in
# ~/.config/claude-glm/{phi-roots,egress-denylist}. FAIL-CLOSED: a list file
# that exists but is unreadable REFUSES; there is no override on this lane.
# Known limitations (shared with the sibling guards' string-path contract, all
# fail-SAFE / over-block, never under-block): only STRING path args are checked
# (an array-valued path arg is skipped — no hermes tool schema uses one today),
# and every non-content string arg is treated as a candidate path, so a search
# pattern that happens to resolve under a PHI root over-blocks. The terminal
# scan is command-text best-effort (wrapper/quoting gaps, like block-read-secrets).
# Single source of truth for the PHI/egress root lists — the SAME files
# glm-guard.ts reads (~/.config/claude-glm). CLAUDE_GLM_CONFIG_DIR overrides the
# location (mirrors glm-guard's cfgDir param; lets the test suite point at a
# temp tree without touching the real home).
PHI_CONFIG_DIR = os.environ.get("CLAUDE_GLM_CONFIG_DIR") or os.path.join(
    os.path.expanduser("~"), ".config", "claude-glm")
PHI_ROOT_LISTS = ("phi-roots", "egress-denylist")


def _abs(p: str) -> str:
    """Canonical real OS path for filesystem checks (NOT norm(), which lower-
    cases for regex matching). realpath — not abspath — resolves symlinks and
    Windows junctions, so a link that points INTO a PHI vault cannot bypass the
    ancestor walk / root prefix. Resolves a relative arg against the process cwd."""
    return os.path.realpath(os.path.expanduser(p.strip().strip('"').strip("'")))


def _salus_marked(ap: str) -> bool:
    """True if `ap` (an absolute path) or any ancestor directory holds a
    `.salus` marker — a path anywhere inside a PHI vault is PHI."""
    d = ap if os.path.isdir(ap) else os.path.dirname(ap)
    prev = None
    while d and d != prev:
        try:
            if os.path.exists(os.path.join(d, ".salus")):
                return True
        except OSError:
            pass
        prev, d = d, os.path.dirname(d)
    return False


def _under_any_root(ap: str, listfile: str) -> str:
    """'hit' | 'miss' | 'unreadable' — is absolute `ap` a listed root or a
    descendant of one? Mirrors glm-guard.ts pathUnderAny (fail-closed tri-state)."""
    if not os.path.exists(listfile):
        return "miss"
    try:
        if not os.path.isfile(listfile):
            return "unreadable"
        with open(listfile, "r", encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return "unreadable"
    # normcase folds Windows case+separators; the extra .lower() also folds case
    # on macOS's case-insensitive APFS (normcase is a no-op off Windows). On
    # case-sensitive Linux this can over-block a path that differs from a PHI
    # root only by case — the fail-safe direction for a security fence.
    t = os.path.normcase(ap).lower() + os.sep
    for root in lines:
        root = root.rstrip("\r").rstrip("/\\")
        if not root:  # blank / CR-only line must not become a match-all root
            continue
        r = os.path.normcase(_abs(root)).lower() + os.sep
        if t == r or t.startswith(r):
            return "hit"
    return "miss"


def phi_egress_reason(path: str):
    """Return a block reason if `path` is PHI-marked (fail-closed), else None."""
    ap = _abs(path)
    if _salus_marked(ap):
        return (f"PHI-marked path refused: {path} is inside a .salus vault. "
                "Sensitive/PHI material must never reach a cloud engine "
                "(sensitive-never-cloud, HIMMEL-695).")
    for name in PHI_ROOT_LISTS:
        rc = _under_any_root(ap, os.path.join(PHI_CONFIG_DIR, name))
        if rc == "unreadable":
            return (f"PHI root list {os.path.join(PHI_CONFIG_DIR, name)} exists "
                    "but is not a readable file — failing closed (no cloud egress).")
        if rc == "hit":
            return (f"PHI-marked path refused: {path} is under a {name} root. "
                    "Sensitive-never-cloud (HIMMEL-695).")
    return None


def terminal_phi_egress_reason(cmd_norm: str):
    """Best-effort: refuse a shell command that references a `.salus` vault or a
    configured PHI/egress root. Command-text scanning shares the sibling guards'
    wrapper/quoting limitations (the file tools are the load-bearing egress
    fence); `cmd_norm` is already norm()-ed (lower-cased, forward-slashed).
    Fail-closed on an unreadable list file."""
    if ".salus" in cmd_norm:
        return ("Shell command references a .salus (PHI) vault — refused to "
                "prevent cloud egress (HIMMEL-695).")
    for name in PHI_ROOT_LISTS:
        listfile = os.path.join(PHI_CONFIG_DIR, name)
        if not os.path.exists(listfile):
            continue
        try:
            if not os.path.isfile(listfile):
                return f"PHI root list {listfile} unreadable — failing closed."
            with open(listfile, "r", encoding="utf-8") as fh:
                lines = fh.read().split("\n")
        except OSError:
            return f"PHI root list {listfile} unreadable — failing closed."
        for root in lines:
            root = root.rstrip("\r").rstrip("/\\").strip()
            if root and norm(root) in cmd_norm:
                return (f"Shell command references a {name} root — refused to "
                        "prevent cloud egress (HIMMEL-695).")
    return None


def main() -> None:
    payload = json.load(sys.stdin)
    tool = payload.get("tool_name", "")
    args = payload.get("tool_input") or payload.get("args") or {}

    if tool in WRITE_TOOLS or tool in DELETE_TOOLS:
        # Check EVERY non-content string arg as a candidate path, regardless of
        # key name — a path under a non-standard key must not slip the fence.
        for k, v in args.items():
            if isinstance(v, str) and k not in CONTENT_KEYS:
                check_write_path(norm(v))
                reason = phi_egress_reason(v)  # raw v — real path for fs checks
                if reason:
                    block(reason)
        allow()

    if tool in READ_TOOLS:
        for k, v in args.items():
            if isinstance(v, str) and k not in CONTENT_KEYS:
                if SECRET_READ.search(norm(v)):
                    block("Secret material (.env / keys / credential stores / "
                          "channel tokens) is off-limits to read.")
                reason = phi_egress_reason(v)  # raw v — real path for fs checks
                if reason:
                    block(reason)
        allow()

    if tool == "terminal":
        cmd = norm(str(args.get("command") or args.get("cmd")
                       or json.dumps(args)))
        if TERMINAL_FORBIDDEN_PATHS.search(cmd):
            block("Shell access to secret paths, the guard hook, or Claude "
                  "Code's home is forbidden — use the file tools for those.")
        if TERMINAL_DESTRUCTIVE.search(cmd):
            block("Catastrophic command class refused (recursive deletion, "
                  "disk/scheduler/process/registry mutation, force-push, "
                  "remote-exec). Ask the operator if genuinely needed.")
        reason = terminal_phi_egress_reason(cmd)
        if reason:
            block(reason)
        allow()

    allow()


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # fail-closed: a broken guard never waves through
        print(json.dumps({
            "decision": "block",
            "reason": f"parity_guard internal error ({exc!r}) — "
                      "failing closed; report to the operator.",
        }))
