#!/usr/bin/env python3
"""
VM SDK (HIMMEL-491) — an easy-to-use class over scripts/lib/vbox.py for driving
the cross-OS test VMs: power, snapshots (so we don't re-provision), shallow
clone, and provision + e2e delegation.

Stdlib + paramiko + python-dotenv (already deps of the *-vm-setup.py scripts;
no new deps). Loopback-only. Reads SSH creds from the PRIMARY checkout's .env
(the gitignored .env is NOT copied into worktrees, so it is resolved via the
parent of `git rev-parse --git-common-dir`, matching scripts/lib/load-dotenv.sh).

CLI: python scripts/lib/vmsdk.py <vm> <up|down|snapshot NAME|restore NAME|
                                      baseline NAME|clone [REF]|provision|e2e>
"""
import json
import os
import re
import shlex
import socket
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vbox

HOST = "127.0.0.1"
OWNER_REPO = "yotamleo/himmel-private"
PAT_ENV = "himmel_github_token_vm"
# Standard Git-for-Windows bash, used both to drive the host e2e (avoiding WSL's
# bash, whose ssh can't read a Windows key path) and as the guest's git launcher.
GIT_BASH = r"C:\Program Files\Git\bin\bash.exe"
_REGISTRY = Path(__file__).resolve().parent / "vms.json"


class VMError(RuntimeError):
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
        self.port = spec["ssh_port"]
        self.host = HOST
        _load_dotenv_into_env()
        self.user = self._req_env(spec["user_env"])
        self.password = self._req_env(spec["pass_env"])
        self._client = None

    @staticmethod
    def _req_env(key):
        val = os.environ.get(key)
        if not val:
            raise VMError(f"required env key {key!r} not set (check primary .env)")
        return val

    # --- lifecycle ---
    def up(self):
        vbox.ensure_running(self.name)
        return vbox.wait_for_ssh(self.host, self.port)

    def ensure_up(self):
        try:
            with socket.create_connection((self.host, self.port), timeout=3):
                return None
        except OSError:
            return self.up()

    def down(self, graceful=True):
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
        return vbox.list_snapshots(self.name)

    def snapshot(self, name):
        vbox.take_snapshot(self.name, name)

    def restore(self, name):
        vbox.restore_snapshot(self.name, name)
        self._invalidate()

    def baseline(self, snap="clean"):
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
                  excludes=(".git", "node_modules", ".claude/worktrees",
                            ".env", ".env.*")):
        """Stage a local checkout onto the guest via a tar-over-ssh pipe.

        Uses a KEY-BASED ssh subprocess (not paramiko) so the tar stream
        flows through a real OS pipe.  On Windows the whole pipe runs
        under Git Bash to avoid WSL bash and Windows-path mangling.
        """
        bash = GIT_BASH if sys.platform == "win32" else "bash"
        key = os.path.expanduser("~/.ssh/id_ed25519").replace("\\", "/")
        local_fwd = str(local_root).replace("\\", "/")
        exclude_flags = " ".join(f"--exclude={e}" for e in excludes)
        pipe = (
            f"tar czf - {exclude_flags} -C {local_fwd} . "
            f"| ssh -p {self.port} -i {key} "
            f"-o BatchMode=yes -o StrictHostKeyChecking=accept-new "
            f"{self.user}@127.0.0.1 "
            f"'mkdir -p {dest} && tar xzf - -C {dest}'"
        )
        argv = [bash, "-c", pipe]
        r = subprocess.run(argv, capture_output=True)
        if r.returncode != 0:
            stderr = r.stderr.decode(errors="replace") if isinstance(r.stderr, bytes) else str(r.stderr)
            raise EnvironmentError(
                f"sync_repo failed (rc {r.returncode}): {stderr.strip()[-200:]}")
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

    def run_e2e(self):
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
          "<up|down|snapshot NAME|restore NAME|baseline NAME|clone [REF]|provision|e2e>")


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
            vm.snapshot(rest[0])
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
        else:
            print(_USAGE, file=sys.stderr)
            return 2
    except NotImplementedError as e:   # windows e2e
        print(e, file=sys.stderr)
        return 4
    except VMError as e:               # operational failure of any verb
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
