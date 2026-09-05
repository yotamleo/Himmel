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

Deny-escalation (HIMMEL-2025): a block() verdict here is NOT terminal to
hermes — tool_executor.py feeds it back to the model as an ordinary tool
result and the agent may retry the same/an adjacent action indefinitely. When
PARITY_GUARD_STATE_DIR is set (scripts/hermes/invoke.sh creates it per-run and
exports it down to this subprocess), block() counts identical
(tool, args-hash) denies in a row and, at PARITY_GUARD_DENY_ESCALATE_N
(default 3), writes "$PARITY_GUARD_STATE_DIR/abort" — the marker invoke.sh's
watchdog polls to kill the run. Without the state dir (e.g. hermes launched
directly, outside invoke.sh) this is a no-op — the normal block/allow verdict
is unaffected either way.
"""

import hashlib
import json
import os
import re
import shlex
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

# Deny-escalation (HIMMEL-2025) — see module docstring.
DENY_STATE_DIR = os.environ.get("PARITY_GUARD_STATE_DIR", "")
try:
    DENY_ESCALATE_N = int(os.environ.get("PARITY_GUARD_DENY_ESCALATE_N", "3"))
except ValueError:
    DENY_ESCALATE_N = 3
if DENY_ESCALATE_N < 1:
    DENY_ESCALATE_N = 1
# Set by main() before any block() call, read by _maybe_escalate() — avoids
# threading tool/args through every one of the ~15 block() call sites below.
_CUR_TOOL = ""
_CUR_ARGS = {}

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

# ScheduledTasks module WRITE verbs (HIMMEL-1821). Shared by the two anchors
# the rule below applies it under; mirrors the .sh hook's SCHEDVERBS.
_SCHED_VERBS = r"(?:register|unregister|set|start|stop|disable|enable)-scheduledtask(?:[^A-Za-z0-9_.-]|$)"

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
    # HIMMEL-1821: same capability, other spellings — the PowerShell
    # ScheduledTasks module drives the Task Scheduler COM API and never
    # launches schtasks.exe, so the CLI line alone guards one spelling out of
    # several. Read/write split preserved by omission: get-/export-scheduledtask
    # are absent and stay allowed (HIMMEL-1141), and the trailing boundary keeps
    # the object-builder cmdlets (new-scheduledtask itself, plus
    # -trigger/-action/-principal) allowed — they construct an in-memory
    # definition and the register/set that consumes it is refused here.
    # The module-qualified form (scheduledtasks\register-scheduledtask) is
    # absorbed by _EXE_PREFIX after norm() folds "\" to "/" (CR r1).
    # Second alternative is the raw COM route, anchored to the -ComObject
    # ARGUMENT because its idiomatic form is an assignment ($svc = New-Object …)
    # that no command-position anchor sees; PowerShell binds unambiguous
    # parameter prefixes and New-Object has no other -c* parameter, so the flag
    # is matched as -c<word> — scoped to a preceding new-object on the same
    # command so `grep -c Schedule.Service docs/` stays allowed (CR r2), and
    # new-object itself takes the command-position anchor WIDENED by "=" (the
    # assignment form the shared prefix does not recognise), so a grep for the
    # full literal phrase stays allowed too (CR r3). CR r7 tuned both ends: no
    # quote between the anchor and new-object (a string assignment is not an
    # invocation), and the progid tolerates leading (/quotes so the
    # parenthesised -ComObject ('Schedule.Service') form is refused.
    # Both scheduled-task rules also take a LOCAL script-block anchor "{"
    # (CR r8) so ForEach-Object { Register-ScheduledTask … } is refused; "{"
    # cannot go into the shared _CMDPOS_DESTRUCTIVE without refusing
    # jq '{format: .x}', but no JSON key is spelled <verb>-scheduledtask.
    # RESIDUAL (CR r3/r4/r5), the shared no-general-parser limit of
    # _CMDPOS_DESTRUCTIVE rather than anything these rules introduced —
    # measured: brace script blocks for the SHARED atoms (ForEach-Object
    # { schtasks /create … }, { shutdown … }, { taskkill … } are all allowed
    # today, exactly as before this change), string indirection
    # ($p = "Schedule.Service"; New-Object -ComObject $p), backtick line
    # continuation, and the reflective [Type]::GetTypeFromProgID route (a
    # literal-spelling match for that was tried and REMOVED in r5: one variable
    # assignment defeats it, while it denied a plain grep for the API name).
    # A tokenizer closes these, a wider regex does not (HIMMEL-912). Mirrors
    # the .sh hook's ScheduledTasks + Schedule.Service lines
    # (lockstep, HIMMEL-754).
    + r"|" + _CMDPOS_DESTRUCTIVE + _SCHED_VERBS
    + r"|(?:^|[{])\s*[\"']?" + _SCHED_VERBS
    + r"|(?:^|[|;&(={`\n])\s*new-object[^|;&\n]*-c[a-z0-9]*\s*[:=]?\s*[(\"']*schedule\.service(?:[^A-Za-z0-9_.-]|$)"
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


def _deny_key(tool: str, args: dict) -> str:
    """Stable identity for "this exact call" — same tool + same args."""
    try:
        canon = json.dumps(args, sort_keys=True, default=str)
    except (TypeError, ValueError):
        canon = str(args)
    return tool + ":" + hashlib.sha256(canon.encode("utf-8", "replace")).hexdigest()


def _maybe_escalate(reason: str) -> str:
    """Nth identical deny in a row -> write the abort marker invoke.sh polls.

    Best-effort: any filesystem trouble here must not break the normal
    block/allow verdict this guard exists to give, so it falls back to the
    original reason on error rather than raising."""
    if not DENY_STATE_DIR:
        return reason
    key_path = os.path.join(DENY_STATE_DIR, "deny-key.txt")
    count_path = os.path.join(DENY_STATE_DIR, "deny-count.txt")
    try:
        os.makedirs(DENY_STATE_DIR, exist_ok=True)
        key = _deny_key(_CUR_TOOL, _CUR_ARGS)
        prev_key = ""
        if os.path.exists(key_path):
            # errors="replace": a torn write from a prior crash must not raise
            # UnicodeDecodeError here — that would break the block() verdict
            # this guard exists to give, worse than under-counting a streak.
            with open(key_path, "r", encoding="utf-8", errors="replace") as f:
                prev_key = f.read().strip()
        count = 1
        if prev_key == key and os.path.exists(count_path):
            try:
                with open(count_path, "r", encoding="utf-8", errors="replace") as f:
                    count = int(f.read().strip()) + 1
            except (ValueError, OSError):
                count = 1
        with open(key_path, "w", encoding="utf-8") as f:
            f.write(key)
        with open(count_path, "w", encoding="utf-8") as f:
            f.write(str(count))
        if count >= DENY_ESCALATE_N:
            escalated = (
                f"ESCALATED after {count} identical denies in a row for "
                f"tool '{_CUR_TOOL}' — aborting the run ({reason})"
            )
            with open(os.path.join(DENY_STATE_DIR, "abort"), "w", encoding="utf-8") as f:
                f.write(escalated)
            return escalated
    except OSError:
        return reason
    return reason


def block(reason: str) -> None:
    reason = _maybe_escalate(reason)
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(0)


def _reset_deny_streak() -> None:
    """An ALLOW breaks any in-progress identical-deny streak (HIMMEL-2025 CR
    round 1, codex-2): the escalation counts denies IN A ROW, not total
    occurrences scattered across the run — an intervening successful call
    means the run is making progress, not spinning. Best-effort, matching
    _maybe_escalate's error handling."""
    if not DENY_STATE_DIR:
        return
    try:
        for fname in ("deny-key.txt", "deny-count.txt"):
            p = os.path.join(DENY_STATE_DIR, fname)
            if os.path.exists(p):
                os.remove(p)
    except OSError:
        pass


def allow() -> None:
    _reset_deny_streak()
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
#
# WHICH DIRECTORY IS JUDGED (cwd contract, HIMMEL-2008). The guard runs as a
# child of the hermes AGENT process, so its own cwd is the session's LAUNCH dir
# (the primary checkout, usually on main) — never evidence about the worktree
# the agent is working in. Judging that dir refused legitimate worktree writes
# and commits. The agent cwd is therefore taken from `_agent_cwd()` (explicit
# `workdir`/`cwd` tool arg -> $TERMINAL_CWD -> payload `cwd` when it is not
# merely this process's own cwd), a commit additionally honouring whichever
# literal `git -C <dir>` / `cd <dir> &&` / `pushd <dir>` sits NEAREST the commit
# verb. That command-text parse is best-effort and unwrapped-only: a `cd` inside
# a quoted wrapper payload (`sh -c "cd <dir> && git commit"`) is NOT parsed —
# the same limitation terminal_phi_egress_reason carries — so base_cwd is judged
# instead (fail-open, never a stricter refusal). When NONE of those is available
# the target dir is UNDETERMINABLE and the check is SKIPPED (fail-open, same
# stance as a detached HEAD) — os.getcwd() is never substituted. An absolute
# path arg is judged exactly as before, and the PHI fence never fails open: it
# keeps the raw path when the cwd is undeterminable.
# RESIDUAL: $TERMINAL_CWD is a session-START signal, not a live one — after a
# manual `cd` back into the primary checkout the guard still judges the
# worktree, so an on-main write can pass. Undetectable here (hermes keeps the
# live cwd in an in-process registry no hook can read); the CC-side
# block-edit-on-main hook remains the enforcing layer for Claude sessions.
DEFAULT_BRANCHES = ("main", "master")

# git commit at command position (start / after a separator), flag-tolerant, with
# `commit` as the verb (so `commit-graph` / `commit-tree` do NOT match). An
# option VALUE may be quoted-with-spaces (HIMMEL-2008): a bare `\S+` stopped at
# the first space, so `git -C "C:/main repo" commit` did not match this pattern
# AT ALL and the commit locks were never entered.
_QUOTED_OR_BARE = r"\"[^\"]+\"|'[^']+'|\S+"
_GIT_COMMIT = re.compile(
    r"(?:^|[;&|(\n])\s*git(?:\s+-\S+(?:\s+(?:" + _QUOTED_OR_BARE + r"))?)*"
    r"\s+commit(?:\s|$)", re.IGNORECASE)
# Git-level options that move the commit's REPO — the thing the branch lock
# asks about, since HEAD (and so the branch committed to) lives in the git dir
# (HIMMEL-2008). `-C` chdirs, which moves repo DISCOVERY; `--git-dir` names the
# repo outright and OUTRANKS the cwd, so `git --git-dir=<main>/.git commit` run
# from a worker really does land on main's branch. `_git_dir_for` walks UP from
# whatever it is handed, so a `.git` dir resolves to its checkout. Valued
# (`--git-dir <p>`) and attached (`--git-dir=<p>`, `-C<p>`) spellings both.
#
# `--work-tree` is deliberately NOT here: it selects the FILE TREE, not the
# repo. Without `--git-dir` the git dir is still discovered from the cwd, so
# `git --work-tree=<worker> commit` run on main commits to MAIN's branch —
# treating it as the target judged the worker and allowed exactly that.
_GIT_REDIRECTS = ("-C", "--git-dir")
_GIT_REDIRECT_PREFIXES = ("-C", "--git-dir=")
# `git -C <dir>` change-dir options are read TOKEN-WISE by `_commit_dir`, not
# by a regex: a pattern scanning raw text cannot tell a real `-C` from one
# sitting INSIDE a quoted value (`git -c core.pager="less -C <worker>" commit`)
# and chdir'd to it, dropping the branch lock (HIMMEL-2008).


def _shell_tokens(text: str):
    """`text` whitespace-split with QUOTES respected but backslash escaping
    OFF. Neither `shlex.split` default does both: posix=True eats `\\` so a
    Windows `C:\\repo` arrives mangled, and posix=False does not group a quote
    that opens mid-token (`-c core.pager="less -C <x>"`) — which is precisely
    the shape this exists to read. Unbalanced quotes -> no reliable tokens ->
    [] (the caller then judges the cwd the walk already resolved)."""
    lex = shlex.shlex(text, posix=True)
    lex.whitespace_split = True
    lex.commenters = ""
    lex.escape = ""
    try:
        return list(lex)
    except ValueError:
        return []
# `cd <dir>` / `pushd <dir>` / `popd` at command position — how a worker runs a
# command in its worktree. Quoted or bare dir; `cd /d X` (cmd.exe) tolerated. A
# BARE dir stops at the first space, so an unquoted path with spaces
# (`cd C:/Program Files/x && git commit`) truncates -> the truncated parent is
# judged, or nothing resolves -> base_cwd. Quote the path (both quote styles are
# parsed) for the exact dir. `popd` carries no dir: it pops a level `pushd`
# pushed, so `pushd <main> && popd && git commit` does not pin the commit to
# <main> — but it canNOT undo a bare `cd` (see `_commit_dir`).
_CD_OR_POPD = re.compile(
    r"(?:^|[;&|(\n])\s*(?:(popd)|(cd|pushd)\s+(?:/d\s+)?"
    r"(\"[^\"]+\"|'[^']+'|[^\s;&|]+))",
    re.IGNORECASE)
# A subshell's cwd never leaks to its parent — `(cd <main> && git log)` leaves
# the caller where it was. The `(` must be at COMMAND POSITION (start, or after
# a separator), the same convention every matcher above uses: a `(` mid-token
# belongs to a PATH, not a subshell, and blanking it corrupted the dir before
# the walk ever saw it (`cd "C:/Program Files (x86)/repo"`, `cd C:/t(x86)/r`)
# -> an unresolvable dir -> fail-open (HIMMEL-2008). Groups 1-2 re-emit the
# separator so the stripped text still parses; `_commit_dir` loops to a
# fixpoint, so nesting needs no arithmetic here.
_SUBSHELL = re.compile(r"(^|[;&|(\n])(\s*)\([^()]*\)")


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


def _usable_dir(cand) -> str:
    """An absolute, existing directory from `cand`, else "" (unusable)."""
    if not isinstance(cand, str):
        return ""
    d = os.path.expanduser(cand.strip().strip('"').strip("'"))
    return d if d and os.path.isabs(d) and os.path.isdir(d) else ""


def _agent_cwd(payload: dict, args: dict) -> str:
    """The dir the AGENT works in, or "" when undeterminable (HIMMEL-2008).

    Ladder, mirroring hermes' own tools/file_tools.py `_resolve_base_dir`:
      1. an explicit per-call `workdir` / `cwd` tool arg;
      2. $TERMINAL_CWD — the session workspace hermes exports to child
         processes (set by `hermes -w`, `/worktree new`, kanban workers);
      3. the payload `cwd`, but ONLY when it is not simply this guard process's
         own cwd: hermes fills that field with `Path.cwd()` of the AGENT
         process (agent/shell_hooks.py `_serialize_payload`), i.e. the session
         launch dir, which says nothing about where a `cd`-ed agent is working.
    The live per-session terminal cwd hermes tracks for `cd`/`pushd` lives in
    an in-process registry (tools/terminal_tool.py `_session_cwd`) and is not
    exposed to hooks — hence the command-text `cd`/`pushd` parse in
    `_commit_dir` and the fail-open "" here. A RELATIVE explicit arg is
    anchored to rung 2/3 (hermes resolves it the same way) rather than dropped;
    everywhere else only absolute dirs count."""
    # Rungs 2-3 first — they are also what a relative rung-1 arg anchors to.
    base = _usable_dir(os.environ.get("TERMINAL_CWD"))
    if not base:
        d = _usable_dir(payload.get("cwd"))
        if d and os.path.realpath(d) != os.path.realpath(os.getcwd()):
            base = d
    for cand in (args.get("workdir"), args.get("cwd")):
        if not isinstance(cand, str) or not cand.strip():
            continue
        d = _usable_dir(cand) or _usable_dir(_resolve_target(cand, base))
        if d:
            return d
    return base


def _resolve_target(path: str, base_cwd: str) -> str:
    """Absolute form of a path arg, or "" when it is relative and the agent's
    cwd is unknown (undeterminable -> caller skips the branch check)."""
    p = os.path.expanduser(path.strip().strip('"').strip("'"))
    if os.path.isabs(p):
        return p
    return os.path.join(base_cwd, p) if base_cwd else ""


def _commit_dir(raw_cmd: str, base_cwd: str, gc) -> str:
    """Dir the terminal `git commit` matched by `gc` runs in: a `git -C <dir>` on the
    COMMIT INVOCATION itself, else the running cwd left by the command's
    `cd`/`pushd`/`popd`, else base_cwd. A `git -C` scopes only its own git
    call and does not move the shell, so an earlier `git -C <other> status &&`
    never pins the later commit. Relative forms resolve against the dir in
    effect where they appear; "" = undeterminable.

    A HEURISTIC over command text, not a shell. It models three things and
    nothing else: command-position `cd`/`pushd` (they set the dir), `popd` (it
    pops a `pushd`ed level, so `pushd <x> && popd` pins nothing), and `( … )`
    groups at COMMAND POSITION (a subshell's cwd never leaks out, so they are
    dropped before the walk; a `(` mid-token is a path, left alone).
    NOT modelled — each leaves base_cwd judged instead, so the verdict
    is the agent's own cwd rather than a stricter refusal: `cd` inside a quoted
    wrapper payload (`sh -c "cd <x> && git commit"`, the same command-text
    limit terminal_phi_egress_reason carries), `cd -`, and variables.

    QUOTING is not modelled in the `cd` walk, and unlike the cases above it can
    point the OTHER way: a separator inside a quoted ARGUMENT still reads as a
    separator, so `echo "; cd <x>" && git commit` follows a `cd` the shell
    never ran and judges <x> rather than base_cwd. That needs crafted text —
    and this is a HYGIENE guard over command text, not a shell, so a caller
    deliberately shaping input to fool the parser is out of its threat model
    (the CC-side block-edit-on-main hook is the enforcing layer). The `git -C`
    option run IS read quote-aware, via `_shell_tokens` — the walk is not,
    because a token stream cannot tell `( … )` grouping from a path containing
    parens, which the raw-text `_SUBSHELL` pass handles today.

    NOT modelled the other way — a `cd` the walk FOLLOWS that the shell would
    not. Two shapes, both pinned by characterization cases in the suite:
    BRANCHING — no short-circuit or conditional semantics, so a
    command-position `cd` counts as EXECUTED even where the shell skips it
    (`true || cd <x>`, an `if`/loop body). It misjudges either way
    (`… || cd <worker>` allows, `… || cd <main>` refuses) and is statically
    undecidable, turning on the left-hand exit status. PIPELINES — every
    element of `a | b` runs in its own subshell, so `cd <x> | cat` never moves
    the parent, yet the walk follows it. Both are documented rather than
    guessed: closing them needs a quote-aware shell parser, and this is a
    command-text heuristic, not a shell."""
    # Drop `( … )` groups to a FIXPOINT (HIMMEL-2008): one `sub` pass strips
    # only the innermost level, so an outer `(cd <x> && (git log))` kept its
    # `cd` in the walk and REFUSED a commit the subshell never moved. Every
    # pass strictly shortens the text, so this terminates.
    pre = raw_cmd[:gc.start()] if gc else raw_cmd
    while True:
        stripped = _SUBSHELL.sub(r"\1\2 ", pre)
        if stripped == pre:
            break
        pre = stripped
    # A dir STACK walked IN ORDER, so it tracks a running cwd rather than a
    # bag of candidates (HIMMEL-2008). Two shell facts the old
    # nearest-entry-wins walk got wrong, both fail-OPEN (they judged base_cwd
    # while the commit really ran elsewhere): every hop resolves against the
    # hop before it, so a relative chain (`cd ..` then `cd <x>`) lands where
    # the shell lands; and only `pushd` pushes a level, so `popd` cannot undo
    # a bare `cd` — on a 1-deep stack bash errors and leaves the cwd alone.
    st = [base_cwd]  # st[-1] = running cwd ("" once undeterminable)
    for m in _CD_OR_POPD.finditer(pre):
        if m.group(1):  # popd — only pops what a pushd pushed
            if len(st) > 1:
                st.pop()
        else:
            tgt = _resolve_target(m.group(3), st[-1])
            # A `cd`/`pushd` to a dir that is not there FAILS in the shell and
            # leaves the cwd ALONE (HIMMEL-2008). Following it anyway judged a
            # path nothing runs in, and when that path had no repo ancestor the
            # branch lock fell OPEN on a commit still running in the base
            # checkout (`cd <missing>; git commit` on main).
            if not tgt or not os.path.isdir(tgt):
                continue
            if m.group(2).lower() == "pushd":
                st.append(tgt)
            else:
                st[-1] = tgt
    # The commit invocation's OWN redirections (HIMMEL-2008): `-C <dir>` plus
    # `--git-dir` / `--work-tree`, which aim a commit at another checkout
    # entirely. They count only on the commit itself — it scopes that one git
    # call and never moves the shell, so an earlier `git -C <other> status`
    # must not pin the later commit to <other>. Only the PRE-VERB option run is
    # scanned, so every `-C` here is a chdir: `git commit -C <commit-ish>`
    # (--reuse-message) sits AFTER the verb and is never seen. git applies
    # multiple in order, each relative one against the last, so they CHAIN
    # rather than first-wins.
    cur = st[-1]
    gd = ""         # --git-dir, kept APART from the -C cwd it outranks
    toks = _shell_tokens(raw_cmd[gc.start():gc.end()]) if gc else []
    i = 0
    while i < len(toks):
        opt, val, adv = toks[i], "", 1
        if opt in _GIT_REDIRECTS and i + 1 < len(toks):
            val, adv = toks[i + 1], 2
        else:
            for pfx in _GIT_REDIRECT_PREFIXES:              # attached `-C<dir>`
                if opt.startswith(pfx) and len(opt) > len(pfx):
                    opt, val = pfx.rstrip("="), opt[len(pfx):]
                    break
        if val:
            if opt == "--git-dir":
                gd = _resolve_target(val, cur)
            else:                                           # -C chains the cwd
                cur = _resolve_target(val, cur)
        i += adv
    # Precedence, not last-wins: a named repo beats the cwd it was found from.
    return gd or cur


def _commit_dirs(raw_cmd: str, base_cwd: str):
    """The dir EVERY terminal `git commit` in `raw_cmd` runs in — one per
    occurrence, not just the first (HIMMEL-2008). `cd <worker> && git commit &&
    cd <main> && git commit` ran its SECOND commit on main entirely unchecked,
    because only the text before the FIRST commit was ever walked. Each match
    re-walks from the start, so every commit is judged at its own point in the
    command."""
    for gc in _GIT_COMMIT.finditer(raw_cmd):
        yield _commit_dir(raw_cmd, base_cwd, gc)


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
    `.salus` marker — a path anywhere inside a PHI vault is PHI. Also accepts
    `.salus-profile` (HIMMEL-2173: template machinery dropped by the salus
    profile installer) — a defense for deployments that predate the installer
    shipping the real `.salus` guard marker alongside it."""
    d = ap if os.path.isdir(ap) else os.path.dirname(ap)
    prev = None
    while d and d != prev:
        try:
            if os.path.exists(os.path.join(d, ".salus")) or os.path.exists(os.path.join(d, ".salus-profile")):
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


# --- qmd MCP collection fence (HIMMEL-1239) ---------------------------------
# v1 allow-list: ONLY the "himmel" collection (non-sensitive, repo-local
# docs). qmd indexes salus (a PHI medical vault) alongside himmel/luna/
# luna-curated with NO built-in isolation, so a blanket allow of the qmd MCP
# tools would let an untrusted engine egress PHI via the qmd MCP path even
# though the PHI/data-egress fence above hard-denies salus by file path.
# Widening this list (e.g. adding luna-curated) is a SEPARATE named operator
# decision — do not add collections here without one.
QMD_ALLOWED_COLLECTIONS = {"himmel"}

# qmd's findDocument() resolver (qmd src/store.ts) falls back to matching a
# bare/relative filename or a #docid against EVERY collection in turn when no
# `qmd://<collection>/` scheme is given — such an input cannot be positively
# attributed to one collection from the tool-call JSON alone, so only the
# fully-qualified qmd://himmel/... virtual-path form is accepted.
QMD_HIMMEL_SCOPED = re.compile(r"^\s*qmd://himmel/")


def qmd_scope_reason(tool: str, args: dict):
    """Return a block reason if this qmd MCP call (tool startswith
    'mcp__plugin_qmd_qmd__') is not positively scoped to the v1 allow-listed
    collection, else None (allow)."""
    if tool == "mcp__plugin_qmd_qmd__query":
        collections = args.get("collections")
        if not isinstance(collections, list) or not collections:
            return ("qmd query with no 'collections' filter is unscoped "
                    "(falls back to the store's default collections, which "
                    "may include salus) — pass collections=[\"himmel\"] "
                    "(HIMMEL-1239).")
        # isinstance-guard each entry — a non-string entry (e.g. a dict) makes
        # `c not in <set-of-str>` raise TypeError, which would otherwise reach
        # the outer fail-closed catch-all (main()'s try/except) instead of
        # denying with a specific, documented reason (CR round 1, HIMMEL-1239).
        bad = [c for c in collections
               if not isinstance(c, str) or c not in QMD_ALLOWED_COLLECTIONS]
        if bad:
            return (f"qmd query is scoped to the 'himmel' collection only "
                     f"(v1 allow-list, HIMMEL-1239); saw: {bad}.")
        return None
    if tool == "mcp__plugin_qmd_qmd__get":
        file_arg = args.get("file")
        if not isinstance(file_arg, str) or not QMD_HIMMEL_SCOPED.match(file_arg):
            return ("qmd get requires a fully-qualified qmd://himmel/... path "
                     "(v1 allow-list, HIMMEL-1239) — bare paths and #docids "
                     "are cross-collection-ambiguous and denied fail-closed.")
        return None
    if tool == "mcp__plugin_qmd_qmd__multi_get":
        pattern = args.get("pattern")
        if not isinstance(pattern, str) or not pattern:
            return ("qmd multi_get requires a qmd://himmel/... pattern "
                     "(HIMMEL-1239).")
        segs = [s.strip() for s in pattern.split(",")]
        if not all(QMD_HIMMEL_SCOPED.match(s) for s in segs):
            return ("qmd multi_get requires every segment to be a fully-"
                     "qualified qmd://himmel/... path/glob (v1 allow-list, "
                     "HIMMEL-1239).")
        return None
    # status (no scoping input) and any other/future qmd tool: scope cannot
    # be positively determined from the tool-call JSON -> deny fail-closed.
    return (f"qmd tool '{tool}' has no collection-scoping input this guard "
            f"can verify — denied fail-closed (HIMMEL-1239).")


def main() -> None:
    global _CUR_TOOL, _CUR_ARGS
    payload = json.load(sys.stdin)
    tool = payload.get("tool_name", "")
    args = payload.get("tool_input") or payload.get("args") or {}
    _CUR_TOOL, _CUR_ARGS = tool, args if isinstance(args, dict) else {}

    # MCP fence (block-backend-tier / block-glm-external-writes parity, HIMMEL-
    # 731). himmel's CC PreToolUse hooks do NOT load under hermes, so an MCP tool
    # call would reach the engine UNFENCED — a real external-write surface on the
    # default lane. Blanket-deny every mcp__* tool EXCEPT the read-only qmd
    # knowledge-base carve-out (mirrors block-glm-external-writes.sh), which is
    # itself COLLECTION-SCOPED to the "himmel" v1 allow-list (HIMMEL-1239 — see
    # qmd_scope_reason() above). This fires unconditionally on this cloud
    # profile (both engines); the matcher extension in wire_parity_guard.py is
    # what makes the guard see mcp__* tools at all.
    if tool.startswith("mcp__"):
        if tool.startswith("mcp__plugin_qmd_qmd__"):
            reason = qmd_scope_reason(tool, args)
            if reason:
                block(reason)
            allow()
        block(f"MCP tool '{tool}' is refused under hermes — the MCP/backend "
              "surface is an unfenced external-write path on this cloud "
              "profile; only the qmd knowledge-base carve-out is allowed "
              "(block-backend-tier / MCP-fence parity).")

    if tool in WRITE_TOOLS or tool in DELETE_TOOLS:
        base_cwd = _agent_cwd(payload, args)
        # Check EVERY non-content string arg as a candidate path, regardless of
        # key name — a path under a non-standard key must not slip the fence.
        for k, v in args.items():
            if isinstance(v, str) and k not in CONTENT_KEYS:
                check_write_path(norm(v))
                # The REAL target: a relative path belongs to the agent's cwd,
                # not this guard's (HIMMEL-2008). "" = undeterminable.
                target = _resolve_target(v, base_cwd)
                # PHI fence gets the resolved target when known, else raw v —
                # it is never SKIPPED the way the branch check below is. Be
                # exact about what the fallback buys, though: `_abs` resolves a
                # relative v against this guard PROCESS's cwd, which is the
                # session launch dir, so it is a best-effort base and not a
                # guarantee. A relative write whose real cwd is a PHI workspace
                # the launch dir is outside of still slips it — the same
                # unknown-cwd root cause the branch check discloses, with the
                # same remedy (`hermes -w <dir>`). PHI egress is additionally
                # governed by scripts/guardrails/egress-matrix.json and the
                # salus vault guard; this fence is one layer, not the only one.
                reason = phi_egress_reason(target or v)
                if reason:
                    block(reason)
                # Branch check is the fail-OPEN half: skipped when undeterminable.
                if target:
                    reason = _edit_on_main_reason(target)
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
        # EVERY `git commit` in the command is judged, not just the first
        # (HIMMEL-2008) — one refusal is enough to block the whole command.
        for commit_dir in _commit_dirs(raw_cmd, _agent_cwd(payload, args)):
            # "" = that commit's dir is undeterminable (no -C, no cd/pushd, no
            # agent cwd) -> skip both locks rather than judge this guard
            # process's own cwd, which is the session launch dir (HIMMEL-2008).
            if commit_dir:
                reason = _edit_on_main_reason(commit_dir)
                if reason:
                    block(reason)
                # Merged-PR commit lock (block-merged-pr-commit parity): refuse
                # a commit onto a branch whose PR is already MERGED (fail-open).
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
