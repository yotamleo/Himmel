#!/usr/bin/env python3
"""
VM SDK (HIMMEL-491) — an easy-to-use class over scripts/lib/vbox.py for driving
the cross-OS test VMs: power, snapshots (so we don't re-provision), shallow
clone, and provision + e2e delegation.

Also covers physical SSH "stations" (HIMMEL-870, registry `kind: "station"`) —
reached via an SSH alias + key auth resolved through ~/.ssh/config instead of
loopback port-forward + password env. Stations share the SSH-generic surface
(run/ssh/trigger_claude/sync_repo/drive_claude) but have no VirtualBox
lifecycle; up/down/snapshot/provision/e2e raise StationLifecycleError.

Stdlib + paramiko + python-dotenv (already deps of the *-vm-setup.py scripts;
no new deps). Loopback-only for VM entries. Reads SSH creds from the PRIMARY
checkout's .env (the gitignored .env is NOT copied into worktrees, so it is
resolved via the parent of `git rev-parse --git-common-dir`, matching
scripts/lib/load-dotenv.sh).

CLI: python scripts/lib/vmsdk.py <vm> <up|down|snapshot NAME [--no-secret-scan]|restore NAME|
                                      baseline NAME|clone [REF]|provision|e2e|
                                      push FILE [DEST]|
                                      trigger HANDOVER [--at TIME] [--cwd DIR] [--long-gap] [--timeout N]>
"""
import hashlib
import fnmatch
import io
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vbox

HOST = "127.0.0.1"
OWNER_REPO = "yotamleo/himmel"  # leak-allow: hostname the actual private repo this SDK clones from
PAT_ENV = "himmel_github_token_vm"
# Standard Git-for-Windows bash, used both to drive the host e2e (avoiding WSL's
# bash, whose ssh can't read a Windows key path) and as the guest's git launcher.
GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"
_REGISTRY = Path(__file__).resolve().parent / "vms.json"

# HIMMEL-2540: basename globs that must never cross host->guest (the
# gitignored-but-present secret set). One boundary with two spellings — keep in
# step with VM_GUEST_SECRET_GLOBS in scripts/lib/vm-guest-excludes.sh (the
# parity test in test-vmsdk.py pins them together).
SECRET_EXCLUDES = (".env", ".env.*", "*.local.json")
# Snapshot scan surface: the home dir plus the fixed staging dirs the tracked VM
# scripts use (REMOTE_DIR in test-install-symmetry-vm.sh / test-luna-upgrade-vm.sh).
# Not all of /tmp: find exits non-zero on root-owned 0700 dirs (systemd-private-*),
# which would refuse every clean running guest. Coverage limits: see the ponytail
# note in scripts/lib/vm-guest-excludes.sh.
_SNAPSHOT_HOME_ROOT = "~"
_SNAPSHOT_STAGING_ROOTS = ("/tmp/himmel-symmetry-vm", "/tmp/himmel-luna-upgrade-vm")
_SCAN_PROFILES = {
    # full: a tree staged from the host — nothing in the set may exist there.
    "full": SECRET_EXCLUDES,
    # env: a guest IMAGE — the guest legitimately grows its own *.local.json
    # (claude writes .claude/settings.local.json), but a .env is the carrier.
    "env": (".env", ".env.*"),
}


# HIMMEL-3236: the scan follows nested DIRECTORY symlinks (a checkout linked into
# the home dir from outside the scanned roots), bounded — see the ponytail note in
# vm-guest-excludes.sh. One POSIX-sh function; the two spellings must stay
# byte-identical (test_scan_command_parity_with_the_bash_helper).
_SCAN_SKIPPED_PREFIX = "scan-skipped: "
_SCAN_SYSTEM_TREES = ("//|/proc/*|/sys/*|/dev/*|/run/*|/usr/*|/bin/*|/sbin/*|/lib/*|"
                      "/lib32/*|/lib64/*|/libx32/*|/etc/*|/boot/*|/snap/*|/var/*")
_SCAN_FN_HEAD = (
    '_s() ( n=$(printf "\\n_"); n=${n%_}; q="$1$n"; v=$n; r=; '
    'while [ -n "$q" ]; do x=${q%%"$n"*}; q=${q#*"$n"}; '
    'd=$(CDPATH= cd -P -- "$x" && pwd -P) || exit 1; '
    'case "$v" in *"$n$d$n"*) continue;; esac; v="$v$d$n"; '
    f'if [ -n "$r" ]; then case "$d/" in {_SCAN_SYSTEM_TREES}) '
    'printf "scan-skipped: %s\\n" "$d" >&2; continue;; esac; fi; r=1; '
    'find -H "$d" -xdev \\( ')
_SCAN_FN_TAIL = (
    " \\) ! -name '.env.example' ! -type d -print || exit 1; "
    'k=$(find -H "$d" -xdev -type l ! -exec test -d {} \\; -print) || exit 1; '
    "[ -z \"$k\" ] || printf '%s\\n' \"$k\" | while IFS= read -r y; do "
    'find -L "$y" -prune >/dev/null 2>&1 || '
    '{ printf "scan-unscanned: %s\\n" "$y" >&2; exit 1; }; '
    'printf "scan-skipped: %s\\n" "$y" >&2; done || exit 1; '
    'l=$(find -H "$d" -xdev -type l -exec test -d {} \\; -print) || exit 1; '
    '[ -z "$l" ] || q="$q$l$n"; done ); ')


def _guest_path(root):
    """`root` as one guest-shell word: a space is allowed and single-quoted
    (a leading `~/` stays outside the quotes so the guest shell still expands it).
    Nothing that could end a word or start an option gets through: no leading
    `-` (it would become a find expression), no quote, `;`, `$`, newline, ...
    (byte-identical to vm_guest_quote_root in vm-guest-excludes.sh)."""
    root = str(root)
    if not re.fullmatch(r"[A-Za-z0-9._/~+][A-Za-z0-9._/~+ -]*", root):
        raise VMError(
            f"secret scan root {root!r}: guest-path characters only (a space is "
            "allowed, not first)")
    if " " not in root:
        return root
    if root.startswith("~/"):
        return "~/'" + root[2:] + "'"
    if root.startswith("~"):
        raise VMError(f"secret scan root {root!r}: a ~user root cannot contain a space")
    return "'" + root + "'"


def _inert_lanes_test():
    """HIMMEL-3252: the find sub-expression that is TRUE for the one file the `full`
    scan may let through -- himmelctl's own lane-profile persistence writes
    scripts/lanes/lanes.local.json during an install, so a guest that has ever been
    through one would otherwise fail every full scan of the clone on the NAME alone.
    A regular file there, <=1 KiB, whose whitespace-stripped bytes match an anchored
    ERE naming exactly lanes / profileAllowlist / profileAllowlistScope with every
    string value from a CLOSED vocabulary (an allowlist of an inert shape, not a hunt
    for secrets). Runs inside `sh -c '...'`, so the JSON quotes are \\" there.
    Byte-identical to _vm_guest_inert_lanes_test in vm-guest-excludes.sh."""
    q = '\\"'
    lane = "(codex-exec|hermes-oneshot)"
    ids = f"({q}{lane}{q}(,{q}{lane}{q})*)?"
    entry = (f"\\{{{q}id{q}:{q}{lane}{q},{q}probe{q}:"
             f"\\{{{q}kind{q}:{q}(always|never){q}\\}}\\}}")
    ere = (f"^\\{{{q}lanes{q}:\\[({entry}(,{entry})*)?\\]"
           f"(,{q}profileAllowlist{q}:\\[{ids}\\]"
           f"(,{q}profileAllowlistScope{q}:\\[{ids}\\])?)?\\}}\\$")
    return ("-type f -path '*/scripts/lanes/lanes.local.json' -size -3 "
            "-exec sh -c 'tr -d \" \\n\\t\\r\" <\"$1\" | "
            f"grep -Eq \"{ere}\"' _ {{}} \\;")


def secret_scan_cmd(root, profile="full"):
    """The portable guest-side command that lists secret-bearing files under root
    (byte-identical to vm_guest_scan_cmd in vm-guest-excludes.sh)."""
    q = _guest_path(root)
    if profile not in _SCAN_PROFILES:
        raise VMError(f"unknown secret-scan profile {profile!r} (full|env)")
    names = " -o ".join(f"-name '{g}'" for g in _SCAN_PROFILES[profile])
    if profile == "full":
        # The one content exemption to the *.local.json name (HIMMEL-3252).
        names = names.replace(
            "-name '*.local.json'",
            f"\\( -name '*.local.json' ! \\( {_inert_lanes_test()} \\) \\)")
    # ! -type d: a directory named .env is a virtualenv convention, not a secret.
    # -H follows a symlinked root; nested directory symlinks are followed by the
    # `_s` recursion; -xdev limit: see vm-guest-excludes.sh.
    return f"{_SCAN_FN_HEAD}{names}{_SCAN_FN_TAIL}_s {q}"


class VMError(RuntimeError):
    pass


class StationLifecycleError(VMError):
    """A VM-lifecycle/provisioning op was invoked on a station entry.

    Stations (HIMMEL-870) are physical SSH hosts — they have no VirtualBox
    power/snapshot/provision surface, only the SSH-generic exec/trigger surface.
    Subclasses VMError so the CLI's ``except VMError`` handler still reports it
    cleanly instead of dumping a traceback. The message names the entry as a
    station and the op as VM-only.
    """
    pass


def _env_path():
    """Path to the PRIMARY checkout's .env (not the worktree's — it has none)."""
    here = Path(__file__).resolve().parent
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=here, capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0 and r.stdout.strip():
            return (here / r.stdout.strip()).resolve().parent / ".env"
    except Exception:
        pass
    return here.parents[1] / ".env"


def _load_dotenv_into_env():
    """Load the primary .env into os.environ (does not override live values)."""
    try:
        from dotenv import load_dotenv
    except ImportError:
        raise VMError("missing dependency: pip install python-dotenv")
    load_dotenv(_env_path())


def _load_registry(path=None):
    p = Path(path) if path else _REGISTRY
    return json.loads(p.read_text())


def _read_ssh_config_text():
    """Return ``~/.ssh/config`` text, or '' if absent/unreadable.

    paramiko does NOT consult ssh_config on connect (the OS ``ssh`` binary
    does), so a station's registry ``host`` is an alias whose real
    HostName/Port/User/IdentityFile live in the operator's ssh_config. This is
    the single read seam — mocked in tests so station ssh() never touches the
    real operator config (hermetic).
    """
    cfg_path = os.path.expanduser("~/.ssh/config")
    try:
        with open(cfg_path) as f:
            return f.read()
    except OSError:
        return ""


def _repo_root():
    return _env_path().parent


class VM:
    def __init__(self, name, registry_path=None):
        reg = _load_registry(registry_path)
        if name not in reg:
            raise VMError(f"unknown VM {name!r}; known: {', '.join(sorted(reg))}")
        spec = reg[name]
        self.name = name
        self.os = spec["os"]
        self.kind = spec.get("kind", "vm")   # "vm" (default, back-compat) | "station"
        self.auth = spec.get("auth", "key" if self.kind == "station" else "password")
        self._client = None
        if self.kind == "station":
            # Physical SSH host (HIMMEL-870): reached by alias + key auth via
            # ~/.ssh/config. No VirtualBox lifecycle, no loopback port-forward,
            # no password env. host/port/identity are resolved at connect time.
            if "host" not in spec:
                raise VMError(f"station {name!r} requires a 'host' (SSH alias)")
            self.host = spec["host"]
            self.port = None
            self.user = spec.get("user")   # ssh_config may also supply it
            self.password = None
            repo_path = spec.get("repo_path")
            self.repo_path = os.path.expanduser(repo_path) if repo_path else None
        else:
            self.port = spec["ssh_port"]
            self.host = HOST
            _load_dotenv_into_env()
            # A literal 'user' in the registry entry wins over 'user_env'
            # (HIMMEL-2623): before this fix a VM-kind spec's 'user' key was
            # never even read here (only the station branch above consulted
            # it), so a stale .env value could never be overridden short of
            # editing .env itself. Surfaced when ubuntu_new's real guest user
            # (himmel) diverged from .env's ubuntu_vm_user (still the retired
            # VM's osboxes) and every VM() consumer failed both password AND
            # key auth — not a dead lane, a wrong username for both attempts.
            # user_env stays the fallback for any entry that sets no literal.
            self.user = spec.get("user") or self._req_env(spec["user_env"])
            self.password = self._req_env(spec["pass_env"])
            self.repo_path = None

    @staticmethod
    def _req_env(key):
        val = os.environ.get(key)
        if not val:
            raise VMError(f"required env key {key!r} not set (check primary .env)")
        return val

    def _require_vm(self, op):
        """Guard a VirtualBox/VM-lifecycle op: stations have no such surface."""
        if self.kind == "station":
            raise StationLifecycleError(
                f"{self.name!r} is a station (physical SSH host), not a "
                f"VirtualBox guest — {op!r} is a VM-only operation")

    # --- lifecycle ---
    def up(self):
        self._require_vm("up")
        vbox.ensure_running(self.name)
        return vbox.wait_for_ssh(self.host, self.port)

    def ensure_up(self):
        self._require_vm("ensure_up")
        try:
            with socket.create_connection((self.host, self.port), timeout=3):
                return None
        except OSError:
            return self.up()

    def down(self, graceful=True):
        self._require_vm("down")
        vbox.power_off(self.name, graceful=graceful)
        self._invalidate()

    # --- ssh / exec ---
    def _invalidate(self):
        if self._client is not None:
            try:
                self._client.close()
            except Exception:
                pass
            self._client = None

    def ssh(self):
        if self._client is not None:
            return self._client
        import paramiko
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        if self.kind == "station":
            # Key-auth via the SSH alias: paramiko does not read ssh_config on
            # connect, so the alias's real HostName/Port/User/IdentityFile are
            # resolved here (the single ssh_config read seam, HIMMEL-870).
            cfg = paramiko.SSHConfig()
            cfg.parse(io.StringIO(_read_ssh_config_text()))
            resolved = cfg.lookup(self.host)
            hostname = resolved.get("hostname", self.host)
            port = int(resolved.get("port", 22))
            user = resolved.get("user") or self.user
            if not user:
                raise VMError(
                    f"station {self.name!r} (alias {self.host!r}) has no SSH user "
                    f"— set 'user' in the vms.json registry entry or 'User' in the "
                    f"~/.ssh/config Host block for {self.host!r}")
            identityfiles = resolved.get("identityfile")
            key_filename = os.path.expanduser(identityfiles[0]) if identityfiles else None
            try:
                client.connect(hostname=hostname, port=port, username=user,
                               key_filename=key_filename, timeout=10)
            except Exception as e:
                raise VMError(
                    f"ssh to station {self.name} (alias {self.host!r}) failed: {e}") from e
            self._client = client
            return client
        try:
            client.connect(hostname=self.host, port=self.port,
                           username=self.user, password=self.password, timeout=10)
        except paramiko.AuthenticationException as pw_err:
            # Password rejected (e.g. password auth disabled) → try key auth.
            # Non-auth failures (timeout, refused) propagate — a key retry
            # would not fix them and would hide the real cause.
            key = os.path.expanduser("~/.ssh/id_ed25519")
            try:
                client.connect(hostname=self.host, port=self.port,
                               username=self.user, key_filename=key, timeout=10)
            except Exception as key_err:
                raise VMError(
                    f"ssh to {self.name} failed: password auth ({pw_err}); "
                    f"key auth ({key_err})") from key_err
        self._client = client
        return client

    def run(self, cmd, sudo=False, timeout=300):
        if sudo and self.os == "windows":
            raise VMError("sudo is not meaningful on a windows VM")
        client = self.ssh()
        if sudo:
            wrapped = f"echo '{self.password}' | sudo -S bash -c {repr(cmd)}"
            _in, out, _err = client.exec_command(wrapped, get_pty=True, timeout=timeout)
            text = out.read().decode(errors="replace")
            return out.channel.recv_exit_status(), text
        _in, out, err = client.exec_command(cmd, timeout=timeout)
        text = out.read().decode(errors="replace") + err.read().decode(errors="replace")
        return out.channel.recv_exit_status(), text

    def close(self):
        self._invalidate()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # --- snapshots ---
    def snapshots(self):
        self._require_vm("snapshots")
        return vbox.list_snapshots(self.name)

    def assert_guest_clean(self, root="~", profile="env"):
        """Refuse (VMError) if the guest holds a secret-bearing file under
        `root`, or cannot be scanned — an unverified guest is not a clean one.
        HIMMEL-2540: a snapshot is durable, so it must never carry a host .env."""
        try:
            rc, out = self.run(secret_scan_cmd(root, profile))
        except VMError:
            raise
        except Exception as e:  # noqa: BLE001 - any transport failure = unverified guest
            raise VMError(
                f"REFUSING: could not scan {self.name}:{root} for secrets: {e!r}") from e
        if rc != 0:
            raise VMError(
                f"REFUSING: could not scan {self.name}:{root} for secrets "
                f"(find rc {rc}): {out.strip()[-200:]}")
        lines = [ln for ln in out.splitlines() if ln.strip()]
        # `scan-skipped:` notes are read-only (a nested link the scan did not
        # follow); they are never hits, but a skip must not be silent.
        skipped = [ln for ln in lines if ln.startswith(_SCAN_SKIPPED_PREFIX)]
        hits = [ln for ln in lines if not ln.startswith(_SCAN_SKIPPED_PREFIX)]
        if skipped:
            print(f"{self.name}:{root}: secret scan did not follow {len(skipped)} "
                  f"nested link(s) (system tree, non-directory or dangling "
                  f"target); first: {skipped[0][len(_SCAN_SKIPPED_PREFIX):]}",
                  file=sys.stderr)
        if hits:
            raise VMError(
                f"REFUSING: secret-bearing files on {self.name} under {root}: "
                + ", ".join(hits[:10]) + (" ..." if len(hits) > 10 else ""))

    def snapshot(self, name, skip_secret_scan=False):
        """Take a named snapshot — after asserting the guest carries no .env.

        A powered-off guest cannot be scanned and is refused; bring it up first.
        `skip_secret_scan=True` (CLI: --no-secret-scan) is the explicit, loud
        escape for an image the operator has verified another way."""
        self._require_vm("snapshot")
        if skip_secret_scan:
            print(f"WARNING: snapshot {name!r} of {self.name} taken WITHOUT the "
                  "secret scan (--no-secret-scan)", file=sys.stderr)
        elif not vbox.is_running(self.name):
            raise VMError(
                f"refusing to snapshot {self.name}: it is not running, so it "
                "cannot be scanned for host secrets (.env). Bring it up first, "
                "or pass --no-secret-scan if you verified the image another way.")
        else:
            self.assert_guest_clean(_SNAPSHOT_HOME_ROOT, "env")
            for root in _SNAPSHOT_STAGING_ROOTS:
                # `test -d` rc 1 = nothing staged there. Any other rc (e.g. an
                # ssh failure) is not "absent" — let the scan itself refuse.
                rc, _ = self.run(f"test -d {root}")
                # A staged tree carries the whole secret set (the copy excludes
                # *.local.json); only ~ is scanned with the narrower env profile.
                if rc != 1:
                    self.assert_guest_clean(root, "full")
        vbox.take_snapshot(self.name, name)

    def restore(self, name):
        self._require_vm("restore")
        vbox.restore_snapshot(self.name, name)
        self._invalidate()

    def baseline(self, snap="clean"):
        self._require_vm("baseline")
        if snap in self.snapshots():
            self.restore(snap)
            self.up()
            return "restored"
        self.up()
        self.provision()
        self.snapshot(snap)
        return "provisioned"

    # --- shallow clone ---
    def clone_himmel(self, ref="main", depth=1, dest=None):
        """Shallow-clone the private repo onto the guest. ref = branch/tag (not a SHA)."""
        if not re.fullmatch(r"[A-Za-z0-9._/-]+", ref):
            raise VMError(f"invalid ref {ref!r}: branch/tag characters only")
        token = self._req_env(PAT_ENV)
        token_url = f"https://x-access-token:{token}@github.com/{OWNER_REPO}.git"
        bare_url = f"https://github.com/{OWNER_REPO}.git"
        if dest is None:
            dest = "~/himmel" if self.os == "ubuntu" else r"C:\himmel"

        if self.os == "ubuntu":
            exists_rc, _ = self.run(f"test -e {dest}")
            if exists_rc == 0:
                raise VMError(f"clone dest {dest} already exists on {self.name}")
            git = "git"
            wrap = lambda c: c
        else:
            # Windows: route through the Git-Bash the provisioner verifies, so git
            # is on PATH without guessing the install root (design F7/round-2 #3).
            bash = GIT_BASH
            exists_rc, _ = self.run(f'if exist {dest} (exit 1) else (exit 0)')
            if exists_rc != 0:
                raise VMError(f"clone dest {dest} already exists on {self.name}")
            git = "git"
            wrap = lambda c: f'"{bash}" -lc {repr(c)}'

        rc, out = self.run(wrap(f"{git} clone --depth {depth} --branch {ref} {token_url} {dest}"))
        if rc != 0:
            raise VMError(f"git clone failed on {self.name} (rc {rc}): {out.strip()[-200:]}")
        # Strip the token from the persisted remote. This is a security guarantee
        # (the PAT must not survive in the guest's .git/config) — fail loudly if
        # the strip does not happen, rather than silently leaving the token.
        rc2, out2 = self.run(wrap(f"{git} -C {dest} remote set-url origin {bare_url}"))
        if rc2 != 0:
            raise VMError(
                f"token-strip set-url failed on {self.name} (rc {rc2}); PAT may "
                f"persist in {dest}/.git/config: {out2.strip()[-200:]}")
        return dest

    # --- per-OS handlers (delegation) ---
    def provision(self):
        self._require_vm("provision")
        root = _repo_root()
        env = {**os.environ, "PYTHONUTF8": "1"}
        if self.os == "ubuntu":
            argv = [sys.executable, str(root / "scripts/machine-setup/ubuntu-vm-setup.py"),
                    "--vm-name", self.name]
        else:
            argv = [sys.executable, str(root / "scripts/machine-setup/windows-vm-setup.py"),
                    "--vm-name", self.name, "--port", str(self.port)]
        r = subprocess.run(argv, cwd=str(root), env=env)
        if r.returncode != 0:
            raise VMError(f"provision {self.name} failed (rc {r.returncode})")

    def sync_repo(self, local_root, dest="~/github/himmel",
                  excludes=(".git", "node_modules", ".claude/worktrees") + SECRET_EXCLUDES):
        """Stage a local checkout onto the guest via a tar-over-ssh pipe.

        Uses a KEY-BASED ssh subprocess (not paramiko) so the tar stream
        flows through a real OS pipe.  On Windows the whole pipe runs
        under Git Bash to avoid WSL bash and Windows-path mangling.
        """
        bash = GIT_BASH if sys.platform == "win32" else "bash"
        local_fwd = str(local_root).replace("\\", "/")
        # shlex.quote: an unquoted --exclude=*.local.json can be glob-expanded by
        # the pipe's own bash before tar sees it, silently dropping the exclusion.
        # The secret set is mandatory: a caller-supplied tuple extends the
        # defaults, it can never replace them.
        excludes = tuple(excludes) + tuple(e for e in SECRET_EXCLUDES if e not in excludes)
        exclude_flags = " ".join(shlex.quote(f"--exclude={e}") for e in excludes)
        if self.kind == "station":
            # Alias-only: hostname/port/identity come from ~/.ssh/config, same
            # as ssh()'s resolution (HIMMEL-870) — no password, no -p/-i. When
            # the registry supplies a user, pin it explicitly so this path
            # can't silently auth as a different user than ssh()'s resolved
            # user (registry user vs. ssh_config User could otherwise diverge).
            target = f"{self.user}@{self.host}" if self.user else self.host
            ssh_target = (f"-o BatchMode=yes -o StrictHostKeyChecking=accept-new "
                          f"{target}")
        else:
            key = os.path.expanduser("~/.ssh/id_ed25519").replace("\\", "/")
            ssh_target = (f"-p {self.port} -i {key} "
                          f"-o BatchMode=yes -o StrictHostKeyChecking=accept-new "
                          f"{self.user}@127.0.0.1")
        # HIMMEL-3228: refuse a dest the post-copy scan could not check BEFORE
        # any file crosses, and quote it (a spaced dest) for the guest shell.
        try:
            secret_scan_cmd(dest, "full")
            guest_dest = _guest_path(dest)
        except VMError as e:
            raise EnvironmentError(str(e)) from e
        remote = f"mkdir -p {guest_dest} && tar xzf - -C {guest_dest}"
        pipe = (
            f"tar czf - {exclude_flags} -C {local_fwd} . "
            f"| ssh {ssh_target} {shlex.quote(remote)}"
        )
        argv = [bash, "-c", pipe]
        r = subprocess.run(argv, capture_output=True)
        if r.returncode != 0:
            stderr = r.stderr.decode(errors="replace") if isinstance(r.stderr, bytes) else str(r.stderr)
            raise EnvironmentError(
                f"sync_repo failed (rc {r.returncode}): {stderr.strip()[-200:]}")
        # Belt and braces (HIMMEL-2540): whatever `excludes` was passed, the
        # staged tree must hold no secret-bearing file.
        try:
            self.assert_guest_clean(dest, "full")
        except VMError as e:
            raise EnvironmentError(str(e)) from e
        return dest

    def install_plugin(self, marketplace_dir, plugin):
        """Install ONE marketplace plugin on the guest and verify presence.

        Steps (each via self.run, checking rc):
        1. Read the marketplace name from marketplace.json (parsed on the host).
        2. Register the marketplace with `claude plugin marketplace add`.
        3. Install the plugin via `claude plugin install <plugin>@<name> --scope user`
           (nonzero rc tolerated — the CLI may exit nonzero on already-installed).
        4. Verify via `claude plugin list` that <plugin>@<name> is present.

        Returns None on success. Raises EnvironmentError on any failure.
        """
        # Step 1: resolve the marketplace name from its marketplace.json
        rc, out = self.run(f"cat {marketplace_dir}/.claude-plugin/marketplace.json")
        if rc != 0:
            raise EnvironmentError(
                f"failed to read marketplace.json from {marketplace_dir} (rc {rc}): {out.strip()[-200:]}")
        name = json.loads(out)["name"]

        # Step 2: register the marketplace (login shell so ~/.local/bin is on PATH)
        rc, out = self.run(f"bash -lc 'claude plugin marketplace add {marketplace_dir}'")
        if rc != 0:
            raise EnvironmentError(
                f"claude plugin marketplace add failed (rc {rc}): {out.strip()[-200:]}")

        # Step 3: install (tolerate nonzero — already-installed exits nonzero)
        spec = f"{plugin}@{name}"
        self.run(f"bash -lc 'claude plugin install {spec} --scope user'")

        # Step 4: verify presence (login shell so ~/.local/bin is on PATH)
        rc, out = self.run("bash -lc 'claude plugin list'")
        if rc != 0 or spec not in out:
            raise EnvironmentError(
                f"plugin {spec!r} not found after install (rc {rc}): {out.strip()[-200:]}")

    def drive_claude(self, prompt, cwd, timeout=600):
        """Drive an interactive claude session on the guest VM.

        Steps (each via self.run):
        1. Locate the claude binary — raises EnvironmentError if absent.
        2. Resolve cwd to an absolute guest path via `cd … && pwd` — raises
           EnvironmentError on failure (~ expansion must happen on the guest
           so that the trust-seed cd can operate in double-quotes).
        3. Pre-seed workspace trust (non-fatal — ignore rc).
        4. Launch: timeout --signal=KILL … bash -lc '…' and return (rc, out).
           rc 124 = guest timeout kill; caller decides whether to retry/raise.

        Positional prompt (not -p/--print) keeps the invocation non-headless
        and billing-safe per HIMMEL-128.
        """
        # Step 1: locate claude (login shell so ~/.local/bin is on PATH)
        rc, claude_path = self.run("bash -lc 'command -v claude'")
        if rc != 0 or not claude_path.strip():
            raise EnvironmentError(
                "claude not found on guest (command -v claude failed or returned empty)")
        claude_bin = claude_path.strip()

        # Step 2: resolve cwd to absolute guest path
        rc, abscwd = self.run(f"cd {cwd} && pwd")
        if rc != 0:
            raise EnvironmentError(
                f"could not resolve cwd {cwd!r} on guest (rc {rc}): {abscwd.strip()[-200:]}")
        abscwd = abscwd.strip()

        # Step 3: pre-seed workspace trust (non-fatal)
        self.run(f"bash ~/github/himmel/scripts/lib/ensure-workspace-trust.sh {abscwd}")

        # Step 4: build and run the drive command.
        # --dangerously-skip-permissions policy (HIMMEL-575): this is the VM
        # driver, and a VM is throwaway + isolated + carries no operator data, so
        # a non-interactive drive (`< /dev/null`, no human to answer a tool-use
        # prompt) skips permissions wholesale — the blast radius is the disposable
        # guest. This is DELIBERATELY different from the *user-facing* unattended
        # path (the pipeline-cadence runner), which must NOT skip permissions: it
        # runs on the operator's real machine and instead injects a curated
        # allowlist+guardrail (`claude --settings <fragment>` wiring the
        # grant-only auto-approve-safe-bash hook). Rule of thumb: VM = run wild;
        # real machine = allowlist.
        inner = f"cd {abscwd} && {claude_bin} {shlex.quote(prompt)} --dangerously-skip-permissions < /dev/null"
        outer = f"timeout --signal=KILL {timeout} bash -lc {shlex.quote(inner)}"
        return self.run(outer)

    @staticmethod
    def _safe_guest_path(p, what):
        """Charset-validate a guest path interpolated into a shell command.

        Guest paths must stay unquoted so the guest shell expands `~`
        (drive_claude's documented constraint), so injection is prevented by
        VALIDATION instead — same pattern as clone_himmel's ref check.
        """
        if not re.fullmatch(r"[A-Za-z0-9._/~-]+", str(p)):
            raise VMError(
                f"{what} {p!r}: guest-path characters only "
                "([A-Za-z0-9._/~-]; no spaces or shell metacharacters)")
        return str(p)

    def push_file(self, local, remote, data=None, skip_if_exists=False):
        """Copy ONE local file (or `data` bytes) to the guest via SFTP,
        atomically: upload to a hidden temp name in the destination dir, then
        posix_rename() into place (mkdir -p the parent first).

        Refuses `.env*` basenames — the same secrets rule sync_repo enforces
        with tar excludes (VM creds + the GitHub PAT must never land on the
        guest). `remote` may use `~` — the parent dir is resolved to an
        absolute guest path first (SFTP does not expand `~`).

        `data`, if given, uploads exactly those bytes instead of re-reading
        `local` from disk — closes a TOCTOU window for callers (trigger_claude)
        that already computed a content digest from bytes read once: without
        this, an edit to `local` between the digest read and this call would
        upload bytes that no longer match the digest `remote` was tagged with.
        `local` is still used for the `.env*` basename guard and (when `data`
        is None) the existence check.

        `skip_if_exists=True` (trigger_claude's digest-addressed inbox paths
        only — a plain `push` overwrites unconditionally) skips the upload
        entirely when `remote` already exists on the guest: the path already
        encodes the content digest, so same path implies same content, and
        skipping removes the rewrite window a same-digest retry would
        otherwise open on a file an already-armed job may be reading.

        Returns the absolute remote path.
        """
        lp = Path(local)
        if data is None and not lp.is_file():
            raise VMError(f"push_file: local file not found: {local}")
        if lp.name.startswith(".env") or any(
                fnmatch.fnmatchcase(lp.name, g) for g in SECRET_EXCLUDES):
            raise VMError(
                "push_file: refusing to push a secret-bearing file "
                f"({'/'.join(SECRET_EXCLUDES)}) to the guest")
        self._safe_guest_path(remote, "push_file: remote")
        remote_dir, _, remote_name = str(remote).rpartition("/")
        if not remote_dir:
            remote_dir = "~"
        if not remote_name:
            remote_name = lp.name
        try:
            rc, out = self.run(f"mkdir -p {remote_dir} && cd {remote_dir} && pwd")
        except Exception as e:
            raise VMError(f"push_file: mkdir -p {remote_dir} failed on {self.name}: {e}") from e
        if rc != 0:
            raise VMError(
                f"push_file: mkdir -p {remote_dir} failed on {self.name} "
                f"(rc {rc}): {out.strip()[-200:]}")
        absdir = out.strip().splitlines()[-1].strip()
        absremote = f"{absdir}/{remote_name}"
        if skip_if_exists:
            try:
                exists_rc, _ = self.run(f"test -f {absremote}")
            except Exception as e:
                raise VMError(
                    f"push_file: existence check for {absremote} failed on {self.name}: {e}") from e
            if exists_rc == 0:
                return absremote
        if data is None:
            data = lp.read_bytes()
        tmp_remote = f"{absdir}/.{remote_name}.tmp-{uuid.uuid4().hex[:8]}"
        sftp = self.ssh().open_sftp()
        try:
            try:
                sftp.putfo(io.BytesIO(data), tmp_remote)
            except Exception as e:
                raise VMError(f"push_file: upload to {self.name} failed ({tmp_remote}): {e}") from e
            try:
                sftp.posix_rename(tmp_remote, absremote)
            except Exception as e:
                raise VMError(f"push_file: rename to {absremote} failed on {self.name}: {e}") from e
        finally:
            sftp.close()
        return absremote

    def trigger_claude(self, handover, cwd=None,
                       when=None, timeout=600, inbox="~/handover-inbox",
                       long_gap=False):
        """Fire a claude session ON the guest from a HOST handover file
        (HIMMEL-835 — the host->VM session-trigger seam).

        Delivers the handover via push_file, then either:
        - when=None: drives an immediate bounded session (drive_claude, which
          keeps the positional-prompt billing guard) whose prompt tells claude
          to load the delivered handover; returns its (rc, out) verbatim
          (rc 124 = guest timeout kill, caller decides).
        - when=<time>: arms the GUEST's own scheduler through the guest
          checkout's arm-resume.sh (Linux at/atd backend — never a hand-rolled
          scheduler, HIMMEL-647). Raises VMError if arming fails; returns
          (0, out) on success.

        cwd=None (sentinel, codex-adv CR): the caller did NOT ask for a
        specific resume cwd. Locating arm-resume.sh (which checkout to `cd`
        into to find the script) is a separate concern from resume ROUTING —
        so a default checkout is still used to find the script, but --cwd is
        NOT passed to arm-resume.sh, letting its own priority run as designed
        (1. --cwd, 2. resume_cwd: frontmatter, 3. auto-detect). Passing --cwd
        unconditionally would hard-fail a resume_worktree: handover (--cwd and
        --worktree are mutually exclusive in arm-resume.sh) and silently
        override resume_cwd: frontmatter on every other one. Only an
        EXPLICITLY passed cwd is forwarded as --cwd.

        The guest session runs on the guest's own claude login (its own quota)
        and commits with the guest's own credentials. Single-writer stays with
        the caller: do not trigger a ticket another writer owns.

        long_gap (HIMMEL-1475): forward arm-resume.sh's --long-gap so a far
          --at TIME (more than 60 min out) does not trip the long-gap guard
          (rc 9). Only meaningful for a SCHEDULED arm (when is set); passing it
          with when=None raises VMError rather than silently ignoring a flag
          the caller believes is in effect.
        """
        locate_cwd = cwd if cwd is not None else "~/Documents/github/himmel"  # leak-allow: hostname default guest working dir for the private repo checkout
        # long_gap only modifies a SCHEDULED arm (when is set): it forwards
        # arm-resume.sh's --long-gap past the HIMMEL-1475 long-gap guard. It is
        # meaningless for an immediate drive (when=None -> drive_claude), so
        # reject the combination loudly instead of silently no-op'ing a flag the
        # caller thinks is in effect.
        if long_gap and when is None:
            raise VMError(
                "trigger_claude: long_gap=True requires a scheduled arm (when=...)")
        self._safe_guest_path(locate_cwd, "trigger_claude: cwd")
        src = Path(handover).resolve()
        # Path(...).resolve() does not require existence — check explicitly so
        # a missing handover raises a clean VMError here instead of a raw
        # FileNotFoundError from the read_bytes() below (which would also make
        # push_file's own is_file() check unreachable).
        if not src.is_file():
            raise VMError(f"trigger: handover file not found: {handover}")
        data = src.read_bytes()
        # Immutable, collision-resistant inbox name (codex-adv CR rounds 1+2):
        # handovers are commonly named next-session-N.md across buckets, so a
        # flat basename lets a later trigger overwrite an earlier delivery; and
        # a path-only tag still lets a RETRY of the same source mutate the file
        # an already-armed job points at, before arm-resume's dedup rejects the
        # re-arm. Tagging with source path + CONTENT digest makes the delivered
        # file immutable by construction: same content -> byte-identical
        # overwrite (harmless idempotent retry); edited content -> a NEW guest
        # path, so a queued job's file is never mutated.
        tag = hashlib.sha1(str(src).encode()).hexdigest()[:8]
        digest = hashlib.sha1(data).hexdigest()[:8]
        # data=data (not re-read from disk) closes the digest/upload TOCTOU: an
        # edit to `handover` between the read above and the upload must not
        # desync the uploaded bytes from the digest tag. skip_if_exists=True:
        # the digest-addressed path already encodes content, so an existing
        # final path is skipped rather than rewritten (an armed job may be
        # reading it).
        guest_handover = self.push_file(
            handover, f"{inbox}/{tag}-{digest}-{src.name}",
            data=data, skip_if_exists=True)
        if when is None:
            prompt = (f"Resume from handover: load {guest_handover} and "
                      f"execute its cold-start instructions.")
            return self.drive_claude(prompt, cwd=locate_cwd, timeout=timeout)
        # No --force: arm-resume's own dedup/collision checks must stay live so
        # a re-trigger cannot silently replace another pending scheduled job
        # (its dedup keys on the handover path, which the hash tag makes
        # per-source; a genuine re-arm of the SAME source is the one case its
        # same-handover dedup rejects — that refusal surfaces as a loud
        # VMError below, operator decides).
        arm = (f"cd {locate_cwd} && bash scripts/handover/arm-resume.sh"
               f" --time {shlex.quote(when)}"
               f" --handover {shlex.quote(guest_handover)}")
        if cwd is not None:
            arm += f" --cwd {cwd}"
        if long_gap:
            arm += " --long-gap"
        try:
            rc, out = self.run(f"bash -lc {shlex.quote(arm)}", timeout=120)
        except Exception as e:
            raise VMError(f"arm-resume on {self.name} failed: {e}") from e
        if rc != 0:
            raise VMError(
                f"arm-resume on {self.name} failed (rc {rc}): {out.strip()[-300:]}")
        return rc, out

    def run_e2e(self):
        self._require_vm("e2e")
        if self.os != "ubuntu":
            raise NotImplementedError(
                "run_e2e is Ubuntu-only today; no host-driven Windows e2e exists "
                "(HIMMEL-494 / CI track)")
        # Run the e2e script that ships in THIS checkout. The script resolves the
        # repo it copies to the VM via its own BASH_SOURCE, so invoking the
        # colocated copy tests the SDK's own tree (the worktree/branch), matching
        # the design's "run_e2e tests THIS worktree". (Provision uses the primary
        # checkout because its provisioner needs the gitignored .env, which lives
        # only there; the e2e script uses key auth and needs no .env.)
        root = Path(__file__).resolve().parents[2]
        # On Windows a bare "bash" resolves to WSL bash (System32\bash.exe), whose
        # ssh cannot read the Windows key path C:/Users/... → publickey rejected.
        # Use Git Bash explicitly (its HOME/ssh read the Windows key fine).
        bash = GIT_BASH if sys.platform == "win32" else "bash"
        # bash mangles backslash path arguments (\ is an escape) — pass the script
        # as a RELATIVE posix path via cwd=root and the identity as forward slashes
        # (ssh -i accepts C:/... fine under Git Bash).
        ident = os.path.expanduser("~/.ssh/id_ed25519").replace("\\", "/")
        argv = [bash, "scripts/test-install-symmetry-vm.sh",
                f"{self.user}@localhost", str(self.port), ident]
        r = subprocess.run(argv, cwd=str(root))
        return r.returncode


_USAGE = ("usage: vmsdk.py <vm> "
          "<up|down|snapshot NAME [--no-secret-scan]|restore NAME|baseline NAME|clone [REF]|provision|e2e|"
          "push FILE [DEST]|"
          "trigger HANDOVER [--at TIME] [--cwd DIR] [--long-gap] [--timeout N]>")


def _parse_trigger_args(rest):
    """Parse `trigger HANDOVER [--at TIME] [--cwd DIR] [--long-gap] [--timeout N]`.

    Returns (handover, kwargs) or raises ValueError on a malformed flag.
    --long-gap (HIMMEL-1475) is a bare flag (forwards arm-resume.sh's --long-gap
    past the long-gap guard) and is only valid alongside --at; on its own it
    raises ValueError so the CLI surfaces exit 2 rather than arming an immediate
    drive with a meaningless flag.
    """
    handover, opts, kw = rest[0], rest[1:], {}
    i = 0
    while i < len(opts):
        flag = opts[i]
        if flag == "--long-gap":
            kw["long_gap"] = True
            i += 1
            continue
        if i + 1 >= len(opts):
            raise ValueError(f"missing value for {flag}")
        val = opts[i + 1]
        if flag == "--at":
            kw["when"] = val
        elif flag == "--cwd":
            kw["cwd"] = val
        elif flag == "--timeout":
            kw["timeout"] = int(val)
        else:
            raise ValueError(f"unknown flag {flag}")
        i += 2
    if kw.get("long_gap") and "when" not in kw:
        raise ValueError(
            "--long-gap requires --at TIME (it modifies a scheduled arm only)")
    return handover, kw


def main(argv):
    if len(argv) < 2:
        print(_USAGE, file=sys.stderr)
        return 2
    name, cmd, rest = argv[0], argv[1], argv[2:]
    try:
        vm = VM(name)
    except VMError as e:
        print(e, file=sys.stderr)
        return 2

    try:
        if cmd == "up":
            print(vm.up())
        elif cmd == "down":
            vm.down()
        elif cmd == "snapshot" and rest:
            vm.snapshot(rest[0], skip_secret_scan="--no-secret-scan" in rest[1:])
        elif cmd == "restore" and rest:
            vm.restore(rest[0])
        elif cmd == "baseline" and rest:
            print(vm.baseline(rest[0]))
        elif cmd == "clone":
            print(vm.clone_himmel(ref=rest[0] if rest else "main"))
        elif cmd == "provision":
            vm.provision()
        elif cmd == "e2e":
            return vm.run_e2e()
        elif cmd == "push" and rest:
            dest = rest[1] if len(rest) > 1 else f"~/handover-inbox/{Path(rest[0]).name}"
            print(vm.push_file(rest[0], dest))
        elif cmd == "trigger" and rest:
            try:
                handover, kw = _parse_trigger_args(rest)
            except ValueError as e:
                print(f"trigger: {e}", file=sys.stderr)
                print(_USAGE, file=sys.stderr)
                return 2
            rc, out = vm.trigger_claude(handover, **kw)
            print(out)
            return rc
        else:
            print(_USAGE, file=sys.stderr)
            return 2
    except NotImplementedError as e:   # windows e2e
        print(e, file=sys.stderr)
        return 4
    except VMError as e:               # operational failure of any verb
        print(e, file=sys.stderr)
        return 1
    except EnvironmentError as e:      # guest-env failure (claude/cwd missing)
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
