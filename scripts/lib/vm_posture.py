#!/usr/bin/env python3
"""
VM posture / forensic check tool (HIMMEL-495, epic HIMMEL-483) — the
security-posture half of the e2e VM harness.

Replaces the throwaway ``$TEMP`` paramiko forensic sweeps with ONE reusable,
hermetic, read-only posture battery over the existing ``vmsdk.VM`` SSH layer.
It is NOT the *functional* smoke (claude/vault/checkout presence — that is the
``vm-probe*.py`` concern); it audits the guest's *security posture*.

Five read-only checks (the ticket's exact dimensions):
  1. authorized_keys audit       — only the harness host key may be present
  2. listening sockets + NIC     — nothing world-bound except sshd
  3. auth.log non-local auth      — Accepted only from loopback / VBox NAT gw
  4. sudoers audit                — only the HIMMEL-492 scoped NOPASSWD drop-in
  5. IP forwarding / forward      — net.*.forwarding must be off

Cardinal invariant (D5): every command is a READ. Enforced by an explicit
read-only allowlist (``_guard``), not a write-verb denylist. Re-running the
tool changes nothing on the guest.

CLI: python scripts/lib/vm_posture.py <vm> [--json]
  exit 0 — no FAIL (PASS/WARN/SKIP only)
  exit 1 — at least one FAIL (real violation)
  exit 2 — usage / construction error (unknown vm, missing .env creds)
  exit 3 — VM not reachable (bring it up first; the tool never powers it on)
  exit 4 — non-ubuntu guest (v1 is Ubuntu-only)

The check functions are pure ``(runner, ...) -> CheckResult`` so the suite
(``test-vm_posture.py``) injects a fake runner over captured fixtures and needs
no VM. See the design/plan specs (HIMMEL-495) for the full rationale.
"""
import ipaddress
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from vmsdk import VM, VMError  # noqa: E402  (sys.path tweak must precede import)

# --- status / severity vocab ------------------------------------------------
PASS = "PASS"
FAIL = "FAIL"
WARN = "WARN"
SKIP = "SKIP"
_STATUS_ORDER = [FAIL, WARN, SKIP, PASS]  # report grouping order (D4)

SEV_HIGH = "high"
SEV_MEDIUM = "medium"

# --- pinned facts (resolved during plan-critic; see plan "Pinned facts") -----
SUDO_SENTINEL = "__SUDO_OK__"
# Accepted-from sources that are NOT off-box (loopback + VBox NAT gateway).
EXPECTED_AUTH_SOURCES = {"127.0.0.1", "::1", "10.0.2.2"}
# A world-bound listener on one of these ports is known-good (sshd).
KNOWN_GOOD_LISTEN_PORTS = {"22"}
# A burst of failed logins at/above this count raises a brute-force WARN.
FAILED_LOGIN_BURST = 5
# HIMMEL-492 scoped NOPASSWD drop-in (the ONE expected NOPASSWD grant). The
# user is substituted at check time. Source: scripts/machine-setup/
# ubuntu-vm-setup.py (NOPASSWD_CMDS + install_nopasswd_sudoers).
EXPECTED_NOPASSWD_TEMPLATE = (
    "{user} ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, "
    "/usr/bin/dpkg, /usr/bin/systemctl, /usr/bin/tee"
)
# "Expected / non-routable" address ranges (checks 2 & 5). Anything else is
# routable = off-box reachable.
_NONROUTABLE_NETS = [
    ipaddress.ip_network(n) for n in (
        "127.0.0.0/8", "::1/128", "169.254.0.0/16", "fe80::/10", "10.0.2.0/24",
    )
]

# Guest paths (read-only).
_LOGIN_AUTHKEYS = "~/.ssh/authorized_keys"
_ROOT_AUTHKEYS = "/root/.ssh/authorized_keys"
_HOST_PUBKEY = "~/.ssh/id_ed25519.pub"


class PostureError(RuntimeError):
    """A command the tool tried to issue is not on the read-only allowlist."""


@dataclass
class CheckResult:
    id: str
    title: str
    severity: str
    status: str
    detail: str


# --- command allowlist / read-only guard (D5/F8) ----------------------------
# Shell metacharacters that would let a command do more than a single read
# (redirection, pipes, chaining, substitution). None of the tool's real
# commands contain these — a `*` glob is intentionally allowed.
_FORBIDDEN_META = set(";|&<>`$\n\\")


def _no_mutating_ip(parts):
    mutating = {"add", "del", "delete", "set", "flush", "change", "replace", "append"}
    return not (mutating & set(parts[1:]))


def _sysctl_read_only(parts):
    return "-w" not in parts and not any("=" in t for t in parts[1:])


def _sudo_list_only(parts):
    return len(parts) >= 2 and set(parts[1:]) <= {"-l", "-n", "-ln", "-nl"}


# verb -> validator(parts) -> bool. A verb absent here is rejected outright.
_ALLOWED = {
    "ss": lambda p: True,
    "journalctl": lambda p: True,
    "cat": lambda p: True,
    "getent": lambda p: True,
    "echo": lambda p: True,
    "ip": _no_mutating_ip,
    "sysctl": _sysctl_read_only,
    "ssh-keygen": lambda p: "-lf" in p,
    "sudo": _sudo_list_only,
}


def _guard(cmd):
    """Raise PostureError unless cmd is a single read-only allowlisted command."""
    if any(c in _FORBIDDEN_META for c in cmd):
        raise PostureError(f"command contains a shell metacharacter (write risk): {cmd!r}")
    parts = shlex.split(cmd)
    if not parts:
        raise PostureError("empty command")
    verb = parts[0]
    validator = _ALLOWED.get(verb)
    if validator is None:
        raise PostureError(f"command verb not on read-only allowlist: {verb!r}")
    if not validator(parts):
        raise PostureError(f"command not allowed in read-only form: {cmd!r}")
    return cmd


# --- sudo plumbing (D2-sudo / rev3-R1) --------------------------------------
# Strip ONLY the prompt TOKEN (plus its trailing whitespace/newline), not the
# rest of the line — the pty may merge the prompt inline with real output
# ("[sudo] password for u: <output>"), so a greedy `.*$` would eat the output.
_SUDO_PROMPT_RE = re.compile(r"\[sudo\] password for [^:\n]*:\s*")
_SUDO_RETRY_RE = re.compile(r"^Sorry, try again\.\s*$\n?", re.M)


def _strip_sudo_prompt(text):
    """Strip the pty-merged ``[sudo] password for <user>:`` prompt + retry lines.

    VM.run(sudo=True) uses get_pty=True, which folds sudo's prompt into the
    captured stdout. Every sudo-check parser strips it first.
    """
    return _SUDO_RETRY_RE.sub("", _SUDO_PROMPT_RE.sub("", text))


def sudo_available(runner):
    """True iff a sudo sentinel echo round-trips (rev3-R1: decide on the
    SENTINEL STRING, never on rc — stderr is dropped and rc is ambiguous)."""
    _rc, text = runner("echo " + SUDO_SENTINEL, sudo=True)
    return SUDO_SENTINEL in text


# --- shared parsers ---------------------------------------------------------
def _parse_keygen_fingerprints(text):
    """Fingerprints from ``ssh-keygen -lf`` output: ``<bits> <fp> <comment> (<type>)``."""
    fps = set()
    for line in text.splitlines():
        cols = line.split()
        if len(cols) >= 2 and ":" in cols[1]:
            fps.add(cols[1])
    return fps


def _is_nonroutable(addr):
    # ss appends a zone id to addresses bound on a specific interface
    # (e.g. systemd-resolved's "127.0.0.53%lo", or IPv6 link-local
    # "fe80::1%eth0"). Strip it before classification.
    addr = addr.split("%")[0]
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    return any(ip in net for net in _NONROUTABLE_NETS)


def _parse_listeners(text):
    """(addr, port) for each LISTEN row of ``ss -tlnH``.

    Columns: State Recv-Q Send-Q Local:Port Peer:Port — local is col index 3.
    """
    out = []
    for line in text.splitlines():
        cols = line.split()
        if len(cols) < 4:
            continue
        addr, _sep, port = cols[3].rpartition(":")
        out.append((addr.strip("[]"), port))
    return out


def _parse_nic_addrs(text):
    """IP addresses from ``ip -o addr`` (inet/inet6 <cidr>)."""
    addrs = []
    for line in text.splitlines():
        toks = line.split()
        for i, t in enumerate(toks):
            if t in ("inet", "inet6") and i + 1 < len(toks):
                addrs.append(toks[i + 1].split("/")[0])
    return addrs


def _routable_nics(text):
    return [a for a in _parse_nic_addrs(text) if not _is_nonroutable(a)]


def _sysctl_value(text):
    m = re.search(r"=\s*(\S+)", text)
    return m.group(1) if m else None


def _parse_auth(text):
    accepted, failed = [], []
    for line in text.splitlines():
        m = re.search(r"Accepted\b.*?\bfrom (\S+)", line)
        if m:
            accepted.append(m.group(1))
            continue
        m = re.search(r"Failed\b.*?\bfrom (\S+)", line)
        if m:
            failed.append(m.group(1))
    return accepted, failed


def _norm(s):
    return re.sub(r"\s+", " ", s).strip()


def _parse_nopasswd(text):
    return [_norm(l) for l in text.splitlines()
            if "NOPASSWD" in l and not l.strip().startswith("#")]


# --- the five checks (D3) ---------------------------------------------------
def check_authorized_keys(runner, expected_fps, sudo_ok):
    title = "authorized_keys audit"
    sid, sev = "authorized_keys", SEV_HIGH
    rc, out = runner("ssh-keygen -lf " + _LOGIN_AUTHKEYS)
    guest_fps = _parse_keygen_fingerprints(out)
    if sudo_ok:
        _rc, rout = runner("ssh-keygen -lf " + _ROOT_AUTHKEYS, sudo=True)
        guest_fps |= _parse_keygen_fingerprints(_strip_sudo_prompt(rout))
    if not expected_fps:
        return CheckResult(sid, title, sev, WARN,
                           "could not resolve harness host pubkey; cannot verify "
                           f"the {len(guest_fps)} authorized key(s) found")
    if not guest_fps:
        return CheckResult(sid, title, sev, PASS,
                           "no authorized_keys entries found")
    foreign = guest_fps - expected_fps
    if foreign:
        return CheckResult(sid, title, sev, FAIL,
                           "unexpected authorized key(s): " + ", ".join(sorted(foreign)))
    return CheckResult(sid, title, sev, PASS,
                       f"only the harness host key present ({len(guest_fps)} key(s))")


def check_listening_sockets(runner):
    title = "listening sockets + NIC binding"
    sid, sev = "listening_sockets", SEV_HIGH
    _rc, ss_out = runner("ss -tlnH")
    _rc2, ip_out = runner("ip -o addr")
    listeners = _parse_listeners(ss_out)
    violations = [
        f"{a or '*'}:{p}" for a, p in listeners
        if (a in ("0.0.0.0", "::", "*", "") or not _is_nonroutable(a))
        and p not in KNOWN_GOOD_LISTEN_PORTS
    ]
    nics = _parse_nic_addrs(ip_out)
    nic_detail = ("NICs: " + ", ".join(nics)) if nics else "NIC addresses unavailable"
    if violations:
        return CheckResult(sid, title, sev, FAIL,
                           "exposed listener(s): " + ", ".join(violations) + "; " + nic_detail)
    if not nics:
        return CheckResult(sid, title, sev, WARN,
                           "no exposed listeners, but NIC list could not be read")
    return CheckResult(sid, title, sev, PASS,
                       f"no exposed listeners ({len(listeners)} total); " + nic_detail)


def check_auth_log(runner, sudo_ok):
    title = "auth.log non-local authentication"
    sid, sev = "auth_log", SEV_HIGH
    if not sudo_ok:
        return CheckResult(sid, title, sev, SKIP, "sudo unavailable; cannot read auth log")
    rc, out = runner("journalctl -u ssh --no-pager", sudo=True)
    text = _strip_sudo_prompt(out)
    accepted, failed = _parse_auth(text)
    foreign = [ip for ip in accepted if ip not in EXPECTED_AUTH_SOURCES]
    if foreign:
        return CheckResult(sid, title, sev, FAIL,
                           "Accepted login(s) from non-local source(s): "
                           + ", ".join(sorted(set(foreign))))
    if len(failed) >= FAILED_LOGIN_BURST:
        return CheckResult(sid, title, sev, WARN,
                           f"{len(failed)} failed login attempt(s) (possible brute force)")
    return CheckResult(sid, title, sev, PASS,
                       f"all {len(accepted)} accepted login(s) from expected sources")


def check_sudoers(runner, user, sudo_ok):
    title = "sudoers audit"
    sid, sev = "sudoers", SEV_HIGH
    if not sudo_ok:
        return CheckResult(sid, title, sev, SKIP, "sudo unavailable; cannot read sudoers")
    rc, out = runner("cat /etc/sudoers /etc/sudoers.d/*", sudo=True)
    text = _strip_sudo_prompt(out)
    nopasswd = _parse_nopasswd(text)
    expected = _norm(EXPECTED_NOPASSWD_TEMPLATE.format(user=user))
    foreign = [l for l in nopasswd if l != expected]
    if foreign:
        return CheckResult(sid, title, sev, FAIL,
                           "unexpected NOPASSWD grant(s): " + " | ".join(foreign))
    if nopasswd:
        return CheckResult(sid, title, sev, PASS,
                           "only the HIMMEL-492 scoped NOPASSWD drop-in present")
    return CheckResult(sid, title, sev, PASS, "no NOPASSWD grants")


def check_ip_forward(runner):
    title = "IP forwarding / forward exposure"
    sid, sev = "ip_forward", SEV_MEDIUM
    _r1, o1 = runner("sysctl net.ipv4.ip_forward")
    _r2, o2 = runner("sysctl net.ipv6.conf.all.forwarding")
    _r3, ip_out = runner("ip -o addr")
    v4, v6 = _sysctl_value(o1), _sysctl_value(o2)
    routable = _routable_nics(ip_out)
    nic_note = ("; routable NIC(s): " + ", ".join(routable)) if routable else ""
    if v4 == "1" or v6 == "1":
        return CheckResult(sid, title, sev, FAIL,
                           f"IP forwarding enabled (ipv4={v4}, ipv6={v6}){nic_note}")
    return CheckResult(sid, title, sev, PASS,
                       f"IP forwarding off (ipv4={v4}, ipv6={v6}){nic_note}")


# --- host-side helper (NOT a guest command) ---------------------------------
def host_pubkey_fingerprint():
    """Fingerprint of the harness host pubkey, read+fingerprinted LOCALLY
    (host-side ``ssh-keygen -lf``, not a guest command). Empty set if absent."""
    pub = Path(os.path.expanduser(_HOST_PUBKEY))
    if not pub.exists():
        return set()
    try:
        r = subprocess.run(["ssh-keygen", "-lf", str(pub)],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return set()
    if r.returncode != 0:
        return set()
    return _parse_keygen_fingerprints(r.stdout)


# --- report renderer + exit contract (D4) -----------------------------------
def render_json(results):
    return json.dumps([asdict(r) for r in results], indent=2)


def render_text(results):
    by_status = {s: [r for r in results if r.status == s] for s in _STATUS_ORDER}
    lines = []
    for status in _STATUS_ORDER:
        for r in by_status[status]:
            lines.append(f"[{r.status}] {r.title} ({r.severity})")
            lines.append(f"    {r.detail}")
    counts = " ".join(f"{s}={len(by_status[s])}" for s in _STATUS_ORDER)
    lines.append("")
    lines.append("summary: " + counts)
    return "\n".join(lines)


def exit_code(results):
    return 1 if any(r.status == FAIL for r in results) else 0


# --- CLI / orchestration (D1) -----------------------------------------------
_USAGE = "usage: vm_posture.py <vm> [--json]"
_PER_CHECK_TIMEOUT = 60


def _connect_error_types():
    types = [OSError, VMError]
    try:
        import paramiko
        types.append(paramiko.SSHException)
    except Exception:
        pass
    return tuple(types)


def _run_battery(vm, user):
    """Run all five checks against a live VM, returning CheckResult[].

    The runner guards EVERY command through the read-only allowlist before it
    reaches the wire — the single chokepoint that enforces D5 in production.
    """
    def runner(cmd, sudo=False):
        _guard(cmd)
        return vm.run(cmd, sudo=sudo, timeout=_PER_CHECK_TIMEOUT)

    expected_fps = host_pubkey_fingerprint()
    sudo_ok = sudo_available(runner)
    return [
        check_authorized_keys(runner, expected_fps, sudo_ok),
        check_listening_sockets(runner),
        check_auth_log(runner, sudo_ok),
        check_sudoers(runner, user, sudo_ok),
        check_ip_forward(runner),
    ]


def main(argv, vm_factory=VM):
    args = [a for a in argv if a != "--json"]
    as_json = "--json" in argv
    if len(args) != 1:
        print(_USAGE, file=sys.stderr)
        return 2
    name = args[0]
    try:
        vm = vm_factory(name)
    except VMError as e:
        print(e, file=sys.stderr)
        return 2

    if vm.os != "ubuntu":
        print(f"vm_posture is Ubuntu-only (v1); {name!r} is {vm.os!r}", file=sys.stderr)
        return 4

    try:
        results = _run_battery(vm, vm.user)
    except _connect_error_types() as e:
        print(f"{name} not reachable ({e}); bring it up first", file=sys.stderr)
        return 3
    finally:
        try:
            vm.close()
        except Exception:
            pass

    print(render_json(results) if as_json else render_text(results))
    return exit_code(results)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
