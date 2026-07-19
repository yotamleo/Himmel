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
  WRITE-FENCE     — external-write shapes (git push, remote-URL rewrite, gh
                    PR-mutations, network CLIs) are refused unless the active
                    engine is an affirmed TRUSTED main tier — fail-closed on an
                    untrusted (z.ai/GLM) or unknown engine (HIMMEL-695).

Paths are resolved from the environment so this ships to any machine:
HERMES_HOME (else %LOCALAPPDATA%\\hermes, else ~/.local/share/hermes) and
~/.claude. Wire protocol: JSON on stdin; '{}' = allow,
'{"decision":"block","reason":...}' = block. Fail-CLOSED on any internal error.
"""

import json
import os
import re
import shutil
import subprocess
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

# Command position: string start or right after a separator (; & | ( newline).
# Deliberately NOT a plain space/quote, so a blocked verb quoted inside a
# commit message ("… git push later") does not false-block. Used by the EXT_*
# external-write fence further below (moved up here so the destructive variant
# can build on it).
_CMDPOS = r"(?:^|[;&|(\n])\s*"

# Destructive-only command-position anchor (O1 + CR round 1, HIMMEL-851).
# _CMDPOS PLUS, for the TERMINAL_DESTRUCTIVE bare-command-name atoms only
# (format, schtasks, taskkill, shutdown, icacls, …): a backtick separator
# (command substitution is command position) and a BOUNDED tolerance for
# common launcher prefixes — env-var assignments (x=1 cmd), sudo, env,
# cmd /c, powershell/pwsh -c/-command — plus one optional quote before the
# atom (a quoted word in command position still executes) and (CR r2) a
# bounded EXECUTABLE-PATH prefix — optional Windows drive + path segments
# ending in "/" — so `/sbin/shutdown`, `./shutdown`, and
# `c:/windows/system32/shutdown.exe` (quoted or not; norm() folds "\" to "/")
# are refused like the bare name. The path prefix sits AFTER the command-
# position anchor, so mid-argument words (`git log --pretty=format:%H`,
# `grep -rn format src/`, `echo shutdown`, a commit message mentioning
# "reboot") stay allowed, and the atoms' trailing boundary keeps
# `format-table`-style basenames allowed. The exe-path prefix also applies
# before each WRAPPER token (CR r4), so `/usr/bin/env shutdown` /
# `/usr/bin/sudo shutdown` / `c:/windows/system32/cmd.exe /c shutdown` are
# refused like the bare-wrapper forms. sudo/env tolerate their own flag runs
# (CR r6: `sudo -n`, `env -i`), each flag may optionally consume one following
# non-dash value token (CR r7: `sudo -u root`, `env -u PATH` — generic, no
# per-option table; over-consumes at worst one benign token → over-block in
# exotic cases, never a bypass), and env also tolerates assignment arguments
# (`env -i foo=bar shutdown`). Mirrors the .sh CMDPOS idiom (HIMMEL-754) + its
# CR-r1..r7 extensions. Deliberately NOT a general shell parser — the RESIDUAL
# documented gap is QUOTED-PAYLOAD wrappers (`bash -c "shutdown …"`, `sh -c`,
# xargs / nohup chains), which stays out of scope per the ticket's
# no-general-parser rule. This bounded grammar is intentionally NOT an arms
# race: further wrapper permutations belong to the HIMMEL-912 shared-tokenizer
# follow-up, and the .sh CC-hook + auto-mode classifier remain the outer
# defense layers. NOT used by the EXT_* fence — its narrower anchor and
# documented limits are intentional.
# Bounded executable-path prefix: optional quote + optional drive letter +
# one slash-terminated segment run. "/" only — norm() folds "\" to "/".
_EXE_PREFIX = r"[\"']?(?:[a-z]:)?(?:[^\s|;&`\"']*/)?"
# Quote-aware assignment (CR r5): FOO='a b' / FOO="a b" / FOO=bare. Shared by
# the env-prefix assignment tolerance and the leading env-assignment prefix so
# a quoted value's space does not drop the verb out of command position.
_ASSIGN = r"[a-z0-9_]+=(?:'[^']*'|\"[^\"]*\"|[^\s|;&]*)"
_CMDPOS_DESTRUCTIVE = (
    r"(?:^|[;&|(`\n])\s*"
    + r"(?:(?:" + _ASSIGN
    + r"|" + _EXE_PREFIX + r"(?:sudo(?:\s+-\S+(?:\s+[^-\s]\S*)?)*"   # sudo + flags, each with an optional value token (CR r6/r7)
    + r"|env(?:\s+(?:-\S+(?:\s+[^-\s]\S*)?|" + _ASSIGN + r"))*"      # env + flags(+value)/assignments (CR r6/r7)
    + r"|cmd(?:\.exe)?(?:\s+/\w+(?::\w+)?)*\s+/c"        # cmd accepts /d /s /e:on … before /c (CR r3)
    + r"|(?:powershell|pwsh)(?:\.exe)?(?:\s+-\S+)*\s+-c\w*"
    + r"))\s+)*"
    + _EXE_PREFIX
)

# Catastrophic / shared-machine / irreversible classes only.
# Routine git, gh, mv, cp, and non-recursive rm are intentionally NOT here.
TERMINAL_DESTRUCTIVE = re.compile(
    r"\brm\b[^|;&\n]*(?:\s|\$\{ifs\})[\"']?-\w*r"   # recursive rm (rm -r/-rf/-Rf); tolerates a quoted flag + ${IFS} separator (HIMMEL-851 U2/U3)
    + r"|\brm\b[^|;&\n]*--recursive"
    + r"|\b(del|erase|rd|rmdir)\b[^|;&\n]*/s(?:[^A-Za-z0-9_.-]|$)"  # recursive Windows delete; /s bound to the switch, not a path prefix like /scripts (HIMMEL-851 U1)
    + r"|" + _CMDPOS_DESTRUCTIVE + r"(?:(?:format|diskpart|bcdedit)(?:\.exe)?(?:[^A-Za-z0-9_.-]|$)|mkfs)"
    + r"|\bcipher\s+/w"
    # HIMMEL-1141 verb split: schtasks /query is read-only (cadence diagnostic),
    # so only the mutating verbs are refused. Mirrors the .sh hook schtasks line.
    + r"|" + _CMDPOS_DESTRUCTIVE + r"schtasks(?:\.exe)?\s+(/create|/change|/delete|/end|/run|/config)(?:[^A-Za-z0-9_.-]|$)"    # protects scheduled jobs (mutations only)
    + r"|" + _CMDPOS_DESTRUCTIVE + r"(?:taskkill|stop-process|pskill)(?:\.exe)?(?:[^A-Za-z0-9_.-]|$)"
    + r"|\bkill\s+-9"
    + r"|" + _CMDPOS_DESTRUCTIVE + r"(?:shutdown|reboot|logoff)(?:\.exe)?(?:[^A-Za-z0-9_.-]|$)"
    + r"|\breg\s+(add|delete)\b"
    + r"|" + _CMDPOS_DESTRUCTIVE + r"(?:icacls|takeown)(?:\.exe)?(?:[^A-Za-z0-9_.-]|$)"
    + r"|\bgit\s+push\b[^|;&\n]*(--force|--force-with-lease|\s-f\b)"
    + r"|\bgit\s+(reset\s+--hard|clean\s+-\w*f|filter-branch)\b"
    + r"|\bcurl[^|;&]*\|\s*(ba)?sh|\bwget[^|;&]*\|\s*(ba)?sh"
)

# Container privesc shapes (block-docker-privesc parity, HIMMEL-731). Membership
# in the docker group is root-equivalent, so a docker/podman run|exec|create that
# grants root-equivalent host access bypasses the write / secret fences. Regex
# port of the shapes in scripts/hooks/block-docker-privesc.sh (semantics over
# parity-of-implementation — the CC hook's full ro/rw + allowlist parser is not
# replicated): --privileged, --pid host, --volumes-from, a root-equivalent
# --cap-add, the docker socket, a root --user, and a bind mount of a
# secret-bearing host root (/ , /etc , /root). `cmd` is norm()-ed (lower-cased,
# forward-slashed), so cap names + paths are already folded. Accepted limits
# (fail-safe / over-block direction): system-integrity dirs (/usr /var …) and
# the ro/rw distinction are not modelled — the clearly-catastrophic shapes above
# are what this catches; a determined attacker with wrapper displacement is out
# of scope (parity with the CC hook's documented limits).
DOCKER_PRIVESC = re.compile(
    r"\b(?:docker|podman)\b[^\n]*?(?:"
    r"--privileged"
    r"|--pid(?:=|\s+)host\b"
    r"|--volumes-from\b"
    r"|--cap-add(?:=|\s+)(?:cap_)?(?:sys_admin|sys_ptrace|dac_override|dac_read_search|all)\b"
    r"|(?:/var/run/)?docker\.sock\b"
    r"|(?:--user(?:=|\s+)|-u(?:=|\s+)?)(?:0|root)\b"
    r"|(?:-v|--volume)(?:=|\s+)[\"']?/(?:etc\b|root\b|:)"
    r"|--mount(?:=|\s+)\S*\bsource=/(?:etc\b|root\b|:|,)"
    r")"
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


# --- Main-branch edit/commit lock (block-edit-on-main parity, HIMMEL-731) -----
# himmel does NOT load its Claude Code PreToolUse hooks under hermes, so the
# branch-awareness of scripts/hooks/block-edit-on-main.sh has to live here.
# Semantics (semantics over parity-of-implementation): refuse a write/patch/
# delete into a git repo whose checked-out branch is the DEFAULT branch
# (main/master), and refuse a terminal `git commit` in such a repo. CARVE-OUT
# (operator requirement): a worker committing on its OWN `type/slug` worker
# branch is NOT an on-main edit — the guard fires ONLY when the checked-out
# branch IS the default branch, never on a feature branch. Opt-out: a
# `.single-writer` marker at the repo root (mirrors the CC hook). Branch is read
# cheaply from `.git/HEAD` (no git invocation), following the worktree/submodule
# `.git` FILE `gitdir:` indirection. Fail-OPEN on an undeterminable branch
# (detached HEAD / corrupt ref) so a mid-rebase state does not block every write
# — the default-branch check specifically targets main/master, and a detached
# HEAD is neither.
DEFAULT_BRANCHES = ("main", "master")

# git commit at command position (start / after a separator), flag-tolerant, with
# `commit` as the verb (so `commit-graph` / `commit-tree` do NOT match).
_GIT_COMMIT = re.compile(
    r"(?:^|[;&|(\n])\s*git(?:\s+-\S+(?:\s+\S+)?)*\s+commit(?:\s|$)", re.IGNORECASE)
# `git -C <dir>` change-dir (case-SENSITIVE: -C is chdir, -c is config).
_GIT_C_DIR = re.compile(r"(?:^|[;&|(\n])\s*git\s+-C\s+(\S+)")


def _git_dir_for(start: str):
    """Walk up `start`'s real ancestors for a `.git`; return (repo_root, git_path)
    or (None, None). `.git` is a DIRECTORY in a normal checkout, a FILE in a
    linked worktree / submodule."""
    d = os.path.realpath(os.path.expanduser(start.strip().strip('"').strip("'")))
    prev = None
    while d and d != prev:
        g = os.path.join(d, ".git")
        if os.path.exists(g):
            return d, g
        prev, d = d, os.path.dirname(d)
    return None, None


def _current_branch(git_path: str):
    """Checked-out branch from `.git/HEAD`, following the worktree/submodule
    `.git` FILE `gitdir:` indirection. None on a detached HEAD or unreadable ref."""
    head_dir = git_path
    if os.path.isfile(git_path):
        try:
            with open(git_path, "r", encoding="utf-8") as fh:
                content = fh.read().strip()
        except OSError:
            return None
        if not content.startswith("gitdir:"):
            return None
        head_dir = content[len("gitdir:"):].strip()
        if not os.path.isabs(head_dir):
            head_dir = os.path.normpath(
                os.path.join(os.path.dirname(git_path), head_dir))
    try:
        with open(os.path.join(head_dir, "HEAD"), "r", encoding="utf-8") as fh:
            head = fh.read().strip()
    except OSError:
        return None
    if head.startswith("ref:"):
        ref = head[4:].strip()
        pfx = "refs/heads/"
        return ref[len(pfx):] if ref.startswith(pfx) else ref
    return None  # detached HEAD (raw sha) -> undeterminable branch


def _edit_on_main_reason(start: str):
    """Block reason if `start` (a file or dir path) is inside a git repo on the
    default branch, else None. Honors a repo-root `.single-writer` opt-out."""
    repo_root, git_path = _git_dir_for(start)
    if not repo_root:
        return None  # not in any git repo -> allow
    if os.path.exists(os.path.join(repo_root, ".single-writer")):
        return None  # documented single-writer opt-out
    branch = _current_branch(git_path)
    if branch and branch.lower() in DEFAULT_BRANCHES:
        return (f"Refusing the write/commit — the target repo's checked-out "
                f"branch is the default branch ({branch}). Feature work belongs "
                "on a type/slug worker branch or an isolated worktree; touch "
                "'.single-writer' at the repo root to opt out "
                "(block-edit-on-main parity).")
    return None


def _commit_dir(raw_cmd: str, base_cwd: str) -> str:
    """Dir a terminal `git commit` runs in: a literal `git -C <dir>` if present
    (resolved against base_cwd), else base_cwd."""
    m = _GIT_C_DIR.search(raw_cmd)
    if m:
        d = m.group(1).strip().strip('"').strip("'")
        return d if os.path.isabs(d) else os.path.join(base_cwd, d)
    return base_cwd


# --- Merged-PR commit lock (block-merged-pr-commit parity, HIMMEL-731) --------
# HYGIENE guard (NOT a security boundary), so it FAILS-OPEN everywhere except a
# positively confirmed merged-PR branch — mirrors scripts/hooks/block-merged-pr-
# commit.sh. Before allowing a terminal `git commit`, if gh is available, query
# the branch's merged-PR count; refuse on >0. CARVE-OUT: a fresh worker branch
# with no PR (count 0) is NOT a merged-PR branch -> ALLOW. gh absent / errored /
# non-numeric -> ALLOW with a stderr note (fail-open). GH_CMD overrides the gh
# binary (mirrors branch-shipped.sh's seam). PARITY_GUARD_GH_RESULT is a
# test-only override (mirrors block-edit-on-main.sh's CANON_FORCE) that injects
# the raw count so the suite stays hermetic + cross-platform: a digit = that
# count, '__ERR__' = simulate a gh failure (fail-open).


def _merged_pr_count(branch: str, repo_root: str):
    """Merged-PR count for `branch`, or None when undeterminable (caller fails
    open). Test seam PARITY_GUARD_GH_RESULT short-circuits the gh call."""
    forced = os.environ.get("PARITY_GUARD_GH_RESULT")
    if forced is not None:
        forced = forced.strip()
        if forced == "__ERR__":
            return None
        return int(forced) if forced.isdigit() else None
    gh = os.environ.get("GH_CMD") or shutil.which("gh")
    if not gh:
        return None
    try:
        r = subprocess.run(
            [gh, "pr", "list", "--head", branch, "--state", "merged",
             "--json", "number", "--jq", "length"],
            cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=10)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    out = (r.stdout or b"").decode("utf-8", "replace").strip()
    return int(out) if out.isdigit() else None


def _merged_pr_reason(start: str):
    """Block reason if a terminal `git commit` in `start`'s repo lands on a
    branch whose PR is already MERGED, else None (fail-open hygiene guard)."""
    repo_root, git_path = _git_dir_for(start)
    if not repo_root:
        return None
    branch = _current_branch(git_path)
    if not branch or branch == "HEAD" or branch.lower() in DEFAULT_BRANCHES:
        return None  # default / detached branch -> not a merged feature branch
    count = _merged_pr_count(branch, repo_root)
    if count is None:
        sys.stderr.write("parity_guard: merged-PR commit guard skipped "
                         "(gh unavailable/errored) — fail-open.\n")
        return None
    if count > 0:
        return (f"Refusing to commit — branch '{branch}' already has a MERGED "
                "PR; committing onto a shipped branch accumulates unreachable "
                "work. Start a fresh worktree (block-merged-pr-commit parity).")
    return None


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


# --- Engine-specific external-write fence (HIMMEL-695, write-fence half) ------
# The egress half (above) stops PHI from being READ / searched / written on this
# cloud profile. THIS half stops an UNTRUSTED engine from pushing work OUT — git
# push, remote-URL rewrite, gh PR-mutations, network CLIs — the exact shapes
# scripts/hooks/block-glm-external-writes.sh fences on the Claude-Code GLM lane
# (KEEP IN SYNC). It matters here because hermes does NOT load himmel's Claude
# Code PreToolUse hooks, so parity_guard is the SOLE external-write fence for
# EVERY engine the himmel_agent profile is pointed at (openai/codex OR z.ai/GLM).
#
# Engine signal — FAIL-CLOSED. External writes are permitted ONLY when the run
# is affirmatively a trusted main-tier engine:
#   * ANTHROPIC_BASE_URL contains api.z.ai      -> UNTRUSTED (the s29 lead; the
#     signal block-glm-external-writes.sh itself keys on). ALWAYS refused.
#   * HERMES_ENGINE / HERMES_ONESHOT_MODEL / HERMES_ONESHOT_PROVIDER names a
#     z.ai / glm / zhipu / deepseek model -> UNTRUSTED. ALWAYS refused. The
#     ONESHOT signals matter because invoke.sh exports the resolved --model /
#     --provider through them (HERMES_ENGINE is a launcher/operator signal the
#     one-shot dispatch path never sets) — without scanning them,
#     `dispatch-trusted.sh --model deepseek-v4-flash` would ride the wrapper's
#     external-writes opt-in with an untrusted engine (HIMMEL-916 CR finding).
#   * HERMES_EXTERNAL_WRITES_OK=1               -> the operator / gateway affirms
#     a trusted main-tier (codex/openai) engine for this session -> PERMITTED.
#   * anything else (no recognised signal)      -> FAIL-CLOSED -> refused.
# Why default-DENY (not the sibling's allow-off-lane): hermes exposes NO reliable
# positive "this is codex" signal — it selects providers via its own config.yaml
# chain, not ANTHROPIC_BASE_URL — so an unknown engine is genuine ambiguity, and
# sensitive-never-cloud is a LOCKED invariant, so ambiguity refuses. The operator
# opts a trusted run in with ONE session-sticky env var (parity with the sibling's
# GLM_EXTERNAL_WRITES_OK bypass, opposite sense). A positive UNTRUSTED signal wins
# over the opt-in. PHI writes stay refused regardless of this gate (egress half,
# unconditional). Command-text scanning is best-effort: a write verb displaced from
# command position (env-prefix "FOO=1 git push", bash -c / sudo / xargs wrappers,
# hyphenated aliases, scp/ssh/rsync/nc) is MISSED (under-block), matching the sibling
# guard's documented limits. Accepted because the default is fail-closed deny and the
# unconditional PHI read-fence — not this scan — is the load-bearing egress control.
_ENGINE_UNTRUSTED = re.compile(r"z\.ai|glm|zhipu|deepseek")

# _CMDPOS (command-position anchor) is defined above TERMINAL_DESTRUCTIVE —
# shared by both use sites.
EXT_GIT_PUSH = re.compile(_CMDPOS + r"git(?:\.exe)?(?:\s+-\S+(?:\s+\S+)?)*\s+push(?:\s|$)")
EXT_GIT_URL = re.compile(
    _CMDPOS + r"git(?:\.exe)?(?:\s+-\S+(?:\s+\S+)?)*\s+"
    r"(?:remote\s+set-url|config(?:\s+-\S+(?:\s+\S+)?)*\s+\S*url\s+\S+)")
EXT_GH_ANY = re.compile(_CMDPOS + r"gh(?:\.exe)?(?:\s|$)")
# Audited-lane carve-out (block-glm-external-writes.sh policy, 2026-07-03): gh
# issue (reads AND writes — cr-deferred followups are audited gh issues) + the
# read-only pr/run context verbs stay allowed; every other gh use (pr create/
# merge/edit/review, api, repo, release, gist) is an external write and refuses.
EXT_GH_ALLOW = re.compile(
    _CMDPOS + r"gh(?:\.exe)?\s+(?:issue(?:\s|$)"
    r"|pr\s+(?:view|diff|checks|status|list)(?:\s|$)"
    r"|run\s+(?:view|list|watch)(?:\s|$))")
EXT_NET = re.compile(
    _CMDPOS + r"(?:curl|wget|invoke-webrequest|invoke-restmethod|iwr|irm)(?:\.exe)?(?:\s|$)")


def _external_writes_allowed() -> bool:
    """Trusted main-tier engine? Fail-closed — only an affirmative trusted signal
    returns True; a positive untrusted signal (z.ai / glm / zhipu / deepseek, on
    any of HERMES_ENGINE / HERMES_ONESHOT_MODEL / HERMES_ONESHOT_PROVIDER)
    returns False even with the opt-in."""
    if "api.z.ai" in os.environ.get("ANTHROPIC_BASE_URL", "").lower():
        return False
    for sig in ("HERMES_ENGINE", "HERMES_ONESHOT_MODEL", "HERMES_ONESHOT_PROVIDER"):
        if _ENGINE_UNTRUSTED.search(os.environ.get(sig, "").lower()):
            return False
    if os.environ.get("HERMES_EXTERNAL_WRITES_OK") == "1":
        return True
    return False  # unknown / absent engine signal -> fail-closed (refuse)


def terminal_external_write_reason(cmd_norm: str):
    """Return a block reason if `cmd_norm` (already norm()-ed) is an external-write
    shape (git push / remote-URL rewrite / gh PR-mutation / network CLI), else
    None. The caller gates this on an untrusted / unknown engine."""
    if EXT_GIT_PUSH.search(cmd_norm):
        return ("git push is refused on an untrusted/unknown engine — commit "
                "locally; the trusted main tier / operator pushes (HIMMEL-695).")
    if EXT_GIT_URL.search(cmd_norm):
        return ("Rewriting a git remote / push URL is refused on an untrusted/"
                "unknown engine (HIMMEL-695).")
    if len(EXT_GH_ANY.findall(cmd_norm)) > len(EXT_GH_ALLOW.findall(cmd_norm)):
        return ("gh is limited on an untrusted/unknown engine: issue ops + "
                "pr/run reads only; PR mutations belong to the trusted main "
                "tier (HIMMEL-695).")
    if EXT_NET.search(cmd_norm):
        return ("Network CLIs are refused on an untrusted/unknown engine — "
                "chores are repo-local (HIMMEL-695).")
    return None


def main() -> None:
    payload = json.load(sys.stdin)
    tool = payload.get("tool_name", "")
    args = payload.get("tool_input") or payload.get("args") or {}

    # MCP fence (block-backend-tier / block-glm-external-writes parity, HIMMEL-
    # 731). himmel's CC PreToolUse hooks do NOT load under hermes, so an MCP tool
    # call would reach the engine UNFENCED — a real external-write surface on the
    # default lane. Blanket-deny every mcp__* tool EXCEPT the read-only qmd
    # knowledge-base carve-out (mirrors block-glm-external-writes.sh). This fires
    # unconditionally on this cloud profile (both engines); the matcher extension
    # in wire_parity_guard.py is what makes the guard see mcp__* tools at all.
    if tool.startswith("mcp__"):
        if tool.startswith("mcp__plugin_qmd_qmd__"):
            allow()
        block(f"MCP tool '{tool}' is refused under hermes — the MCP/backend "
              "surface is an unfenced external-write path on this cloud "
              "profile; only the qmd knowledge-base carve-out is allowed "
              "(block-backend-tier / MCP-fence parity).")

    if tool in WRITE_TOOLS or tool in DELETE_TOOLS:
        # Check EVERY non-content string arg as a candidate path, regardless of
        # key name — a path under a non-standard key must not slip the fence.
        for k, v in args.items():
            if isinstance(v, str) and k not in CONTENT_KEYS:
                check_write_path(norm(v))
                reason = phi_egress_reason(v)  # raw v — real path for fs checks
                if reason:
                    block(reason)
                reason = _edit_on_main_reason(v)  # raw v — real path for branch
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
        raw_cmd = str(args.get("command") or args.get("cmd") or "")
        cmd = norm(raw_cmd or json.dumps(args))
        if TERMINAL_FORBIDDEN_PATHS.search(cmd):
            block("Shell access to secret paths, the guard hook, or Claude "
                  "Code's home is forbidden — use the file tools for those.")
        if TERMINAL_DESTRUCTIVE.search(cmd):
            block("Catastrophic command class refused (recursive deletion, "
                  "disk/scheduler/process/registry mutation, force-push, "
                  "remote-exec). Ask the operator if genuinely needed.")
        if DOCKER_PRIVESC.search(cmd):
            block("Container privesc shape refused (docker/podman --privileged, "
                  "host-root bind mount, docker.sock, --pid=host, root-"
                  "equivalent --cap-add, --volumes-from, or root --user) — "
                  "docker-group access is root-equivalent and bypasses the "
                  "write/secret fences. Ask the operator if genuinely needed "
                  "(block-docker-privesc parity).")
        reason = terminal_phi_egress_reason(cmd)
        if reason:
            block(reason)
        # Main-branch commit lock (block-edit-on-main parity): a `git commit`
        # in a repo checked out on the default branch is refused; a worker's own
        # type/slug branch commits freely.
        if _GIT_COMMIT.search(raw_cmd):
            base_cwd = str(payload.get("cwd") or args.get("cwd") or os.getcwd())
            commit_dir = _commit_dir(raw_cmd, base_cwd)
            reason = _edit_on_main_reason(commit_dir)
            if reason:
                block(reason)
            # Merged-PR commit lock (block-merged-pr-commit parity): refuse a
            # commit onto a branch whose PR is already MERGED (fail-open).
            reason = _merged_pr_reason(commit_dir)
            if reason:
                block(reason)
        # Engine-specific external-write fence: block push / remote-URL / gh
        # PR-mutation / network CLIs unless the engine is an affirmed trusted
        # main tier (fail-closed on an unknown engine).
        if not _external_writes_allowed():
            reason = terminal_external_write_reason(cmd)
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
