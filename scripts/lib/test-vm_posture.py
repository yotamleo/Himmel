#!/usr/bin/env python3
"""Hermetic tests for vm_posture (stdlib unittest; run:
python scripts/lib/test-vm_posture.py).

NO VM is required: every check is exercised through a FakeRunner over captured
fixtures (sudo fixtures include the pty-merged ``[sudo] password for <user>:``
preamble, per design D2). Mirrors test-vmsdk.py's runner/style.
"""
import json
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vm_posture as vp


class FakeRunner:
    """Returns canned (rc, text) per registered command (D2 testability seam).

    Register exact or substring matches; substring lets a test map a command
    family without pinning every flag. ``record`` captures every issued command
    so allowlist-completeness can be asserted (Task 9).
    """
    def __init__(self, scripts=None):
        self.scripts = scripts or {}
        self.calls = []

    def __call__(self, cmd, sudo=False, **_kw):
        self.calls.append((cmd, sudo))
        if cmd in self.scripts:
            return self.scripts[cmd]
        for key, val in self.scripts.items():
            if key in cmd:
                return val
        return (0, "")


# --- captured-style fixtures (representative of live guest output) ----------
HOST_FP = "SHA256:HARNESShostkeyAAAAAAAAAAAAAAAAAAAAAAAAAAA"
FOREIGN_FP = "SHA256:FOREIGNkeyBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
KEYGEN_HOST_ONLY = f"256 {HOST_FP} harness@host (ED25519)\n"
KEYGEN_WITH_FOREIGN = (f"256 {HOST_FP} harness@host (ED25519)\n"
                       f"256 {FOREIGN_FP} attacker@evil (ED25519)\n")

SS_LOOPBACK_ONLY = (
    "LISTEN 0      4096   127.0.0.1:2222     0.0.0.0:*\n"
    "LISTEN 0      4096        [::1]:2222        [::]:*\n"
)
SS_WORLD_BAD = (
    "LISTEN 0      4096   127.0.0.1:2222     0.0.0.0:*\n"
    "LISTEN 0      128      0.0.0.0:9999      0.0.0.0:*\n"
)
SS_SSHD_WORLD = (
    "LISTEN 0      128      0.0.0.0:22        0.0.0.0:*\n"
    "LISTEN 0      128         [::]:22           [::]:*\n"
)
IP_ADDR = (
    "1: lo    inet 127.0.0.1/8 scope host lo\n"
    "2: enp0s3    inet 10.0.2.15/24 brd 10.0.2.255 scope global enp0s3\n"
)
IP_ADDR_ROUTABLE = (
    "1: lo    inet 127.0.0.1/8 scope host lo\n"
    "2: enp0s3    inet 203.0.113.10/24 brd 203.0.113.255 scope global enp0s3\n"
)

# sudo fixtures: pty-merged prompt preamble MUST be present (D2/F2).
SUDO_PROMPT = "[sudo] password for osboxes: "
JOURNAL_LOCAL = SUDO_PROMPT + (
    "Jun 21 10:00:00 h sshd[1]: Accepted publickey for osboxes from 10.0.2.2 port 5 ssh2\n"
    "Jun 21 10:01:00 h sshd[2]: Accepted password for osboxes from 127.0.0.1 port 6 ssh2\n"
)
JOURNAL_FOREIGN = SUDO_PROMPT + (
    "Jun 21 10:00:00 h sshd[1]: Accepted publickey for osboxes from 203.0.113.7 port 5 ssh2\n"
)
JOURNAL_FAILED_BURST = SUDO_PROMPT + "".join(
    f"Jun 21 10:0{i}:00 h sshd[{i}]: Failed password for invalid user x from 1.2.3.4 port {i} ssh2\n"
    for i in range(6)
)
SUDOERS_492_ONLY = SUDO_PROMPT + (
    "# base sudoers\n"
    "root ALL=(ALL:ALL) ALL\n"
    "osboxes ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg, /usr/bin/systemctl, /usr/bin/tee\n"
)
SUDOERS_FOREIGN = SUDO_PROMPT + (
    "osboxes ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg, /usr/bin/systemctl, /usr/bin/tee\n"
    "baduser ALL=(ALL) NOPASSWD: ALL\n"
)
SYSCTL_OFF_V4 = "net.ipv4.ip_forward = 0\n"
SYSCTL_OFF_V6 = "net.ipv6.conf.all.forwarding = 0\n"
SYSCTL_ON_V4 = "net.ipv4.ip_forward = 1\n"


# --- Task 0: scaffold + CheckResult + FakeRunner ----------------------------
class TestScaffold(unittest.TestCase):
    def test_checkresult_fields(self):
        r = vp.CheckResult(id="x", title="t", severity=vp.SEV_HIGH, status=vp.PASS, detail="d")
        self.assertEqual((r.id, r.title, r.severity, r.status, r.detail),
                         ("x", "t", vp.SEV_HIGH, vp.PASS, "d"))

    def test_status_vocab(self):
        self.assertEqual({vp.PASS, vp.FAIL, vp.WARN, vp.SKIP}, {"PASS", "FAIL", "WARN", "SKIP"})

    def test_fakerunner_exact_and_substring(self):
        fr = FakeRunner({"echo hi": (0, "hi"), "ss": (0, "sock")})
        self.assertEqual(fr("echo hi"), (0, "hi"))
        self.assertEqual(fr("ss -tlnH"), (0, "sock"))   # substring match
        self.assertEqual(fr("unknown"), (0, ""))


# --- Task 1: allowlist + read-only guard ------------------------------------
class TestGuard(unittest.TestCase):
    def test_allowlisted_commands_pass(self):
        for cmd in ("ss -tlnH", "journalctl -u ssh --no-pager", "cat /etc/sudoers /etc/sudoers.d/*",
                    "ssh-keygen -lf ~/.ssh/authorized_keys", "ip -o addr",
                    "sysctl net.ipv4.ip_forward", "sudo -ln", "echo " + vp.SUDO_SENTINEL,
                    "getent passwd"):
            vp._guard(cmd)  # must not raise

    def test_non_allowlisted_verb_rejected(self):
        with self.assertRaises(vp.PostureError):
            vp._guard("rm -rf /")

    def test_redirection_rejected(self):
        with self.assertRaises(vp.PostureError):
            vp._guard("cat foo > bar")

    def test_pipe_and_chain_rejected(self):
        for bad in ("cat a | sh", "ss -tlnH; rm x", "echo $(rm x)"):
            with self.assertRaises(vp.PostureError):
                vp._guard(bad)

    def test_sysctl_write_rejected(self):
        with self.assertRaises(vp.PostureError):
            vp._guard("sysctl -w net.ipv4.ip_forward=1")

    def test_ip_mutation_rejected(self):
        with self.assertRaises(vp.PostureError):
            vp._guard("ip addr add 1.2.3.4/24 dev eth0")

    def test_ssh_keygen_generate_rejected(self):
        with self.assertRaises(vp.PostureError):
            vp._guard("ssh-keygen -t ed25519 -f /tmp/k")

    def test_sudo_non_list_rejected(self):
        with self.assertRaises(vp.PostureError):
            vp._guard("sudo rm -rf /")


# --- Task 2: sudo sentinel probe --------------------------------------------
class TestSudoSentinel(unittest.TestCase):
    def test_sentinel_present_true_ignoring_rc(self):
        fr = FakeRunner({"echo " + vp.SUDO_SENTINEL: (1, SUDO_PROMPT + vp.SUDO_SENTINEL + "\n")})
        self.assertTrue(vp.sudo_available(fr))   # rc=1 but sentinel present

    def test_sentinel_absent_false_ignoring_rc(self):
        fr = FakeRunner({"echo " + vp.SUDO_SENTINEL:
                         (1, SUDO_PROMPT + "\nSorry, try again.\n")})
        self.assertFalse(vp.sudo_available(fr))  # rc=1 and no sentinel

    def test_strip_sudo_prompt(self):
        stripped = vp._strip_sudo_prompt(SUDO_PROMPT + "real output\n")
        self.assertNotIn("password for", stripped)
        self.assertIn("real output", stripped)

    def test_strip_sudo_prompt_inline_preserves_output(self):
        # The pty can merge prompt + first output line; stripping must keep output.
        stripped = vp._strip_sudo_prompt("[sudo] password for osboxes: Accepted from 1.2.3.4")
        self.assertIn("Accepted from 1.2.3.4", stripped)


# --- Task 3: authorized_keys audit ------------------------------------------
class TestAuthorizedKeys(unittest.TestCase):
    def test_only_host_key_pass(self):
        fr = FakeRunner({"ssh-keygen -lf": (0, KEYGEN_HOST_ONLY)})
        r = vp.check_authorized_keys(fr, {HOST_FP}, sudo_ok=False)
        self.assertEqual(r.status, vp.PASS)

    def test_extra_key_fails_listing_fp(self):
        fr = FakeRunner({"ssh-keygen -lf": (0, KEYGEN_WITH_FOREIGN)})
        r = vp.check_authorized_keys(fr, {HOST_FP}, sudo_ok=False)
        self.assertEqual(r.status, vp.FAIL)
        self.assertIn(FOREIGN_FP, r.detail)

    def test_unresolvable_host_key_warns(self):
        fr = FakeRunner({"ssh-keygen -lf": (0, KEYGEN_HOST_ONLY)})
        r = vp.check_authorized_keys(fr, set(), sudo_ok=False)
        self.assertEqual(r.status, vp.WARN)

    def test_root_read_gated_on_sudo(self):
        fr = FakeRunner({"ssh-keygen -lf " + vp._LOGIN_AUTHKEYS: (0, KEYGEN_HOST_ONLY),
                         "ssh-keygen -lf " + vp._ROOT_AUTHKEYS: (0, SUDO_PROMPT + KEYGEN_WITH_FOREIGN)})
        r = vp.check_authorized_keys(fr, {HOST_FP}, sudo_ok=True)
        self.assertEqual(r.status, vp.FAIL)   # foreign key in root's file caught
        # the ROOT-keys read specifically must have used sudo (not just "some call")
        self.assertIn(("ssh-keygen -lf " + vp._ROOT_AUTHKEYS, True), fr.calls)

    def test_no_guest_keys_with_expected_pass(self):
        # expected resolved, but the guest has zero authorized_keys -> PASS branch.
        fr = FakeRunner({"ssh-keygen -lf": (0, "")})
        r = vp.check_authorized_keys(fr, {HOST_FP}, sudo_ok=False)
        self.assertEqual(r.status, vp.PASS)
        self.assertIn("no authorized_keys", r.detail)


# --- Task 4: listening sockets + NIC ----------------------------------------
class TestListeningSockets(unittest.TestCase):
    def test_loopback_only_pass(self):
        fr = FakeRunner({"ss -tlnH": (0, SS_LOOPBACK_ONLY), "ip -o addr": (0, IP_ADDR)})
        r = vp.check_listening_sockets(fr)
        self.assertEqual(r.status, vp.PASS)
        self.assertIn("10.0.2.15", r.detail)   # NIC in detail

    def test_world_bound_unknown_port_fail(self):
        fr = FakeRunner({"ss -tlnH": (0, SS_WORLD_BAD), "ip -o addr": (0, IP_ADDR)})
        r = vp.check_listening_sockets(fr)
        self.assertEqual(r.status, vp.FAIL)
        self.assertIn("9999", r.detail)

    def test_sshd_world_bound_pass(self):
        fr = FakeRunner({"ss -tlnH": (0, SS_SSHD_WORLD), "ip -o addr": (0, IP_ADDR)})
        r = vp.check_listening_sockets(fr)
        self.assertEqual(r.status, vp.PASS)

    def test_ipv6_world_bound_unknown_port_fail(self):
        # bracket-strip on an IPv6 world-bound non-sshd listener must still FAIL.
        ss = "LISTEN 0 128 [::]:9999 [::]:*\n"
        fr = FakeRunner({"ss -tlnH": (0, ss), "ip -o addr": (0, IP_ADDR)})
        r = vp.check_listening_sockets(fr)
        self.assertEqual(r.status, vp.FAIL)
        self.assertIn("9999", r.detail)

    def test_nic_unavailable_warns_when_clean(self):
        fr = FakeRunner({"ss -tlnH": (0, SS_LOOPBACK_ONLY), "ip -o addr": (0, "")})
        r = vp.check_listening_sockets(fr)
        self.assertEqual(r.status, vp.WARN)

    def test_loopback_with_zone_suffix_pass(self):
        # Regression (live smoke): systemd-resolved binds 127.0.0.53%lo:53 — the
        # %lo zone id must be stripped so the loopback classifies as non-routable.
        ss = "LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:*\n"
        fr = FakeRunner({"ss -tlnH": (0, ss), "ip -o addr": (0, IP_ADDR)})
        r = vp.check_listening_sockets(fr)
        self.assertEqual(r.status, vp.PASS)


# --- Task 5: auth.log non-local --------------------------------------------
class TestAuthLog(unittest.TestCase):
    def test_local_only_pass(self):
        fr = FakeRunner({"journalctl": (0, JOURNAL_LOCAL)})
        r = vp.check_auth_log(fr, sudo_ok=True)
        self.assertEqual(r.status, vp.PASS)

    def test_foreign_accepted_fail(self):
        fr = FakeRunner({"journalctl": (0, JOURNAL_FOREIGN)})
        r = vp.check_auth_log(fr, sudo_ok=True)
        self.assertEqual(r.status, vp.FAIL)
        self.assertIn("203.0.113.7", r.detail)

    def test_failed_burst_warn(self):
        fr = FakeRunner({"journalctl": (0, JOURNAL_FAILED_BURST)})
        r = vp.check_auth_log(fr, sudo_ok=True)
        self.assertEqual(r.status, vp.WARN)

    def test_foreign_accepted_outranks_failed_burst(self):
        # FAIL (foreign Accepted = real intrusion) must win over WARN (brute-force
        # burst) — the single most security-relevant precedence in the file.
        combined = JOURNAL_FOREIGN + "".join(
            f"Jun 21 11:0{i}:00 h sshd[{i}]: Failed password for x from 1.2.3.4 port {i} ssh2\n"
            for i in range(6))
        fr = FakeRunner({"journalctl": (0, combined)})
        r = vp.check_auth_log(fr, sudo_ok=True)
        self.assertEqual(r.status, vp.FAIL)

    def test_no_sudo_skip(self):
        fr = FakeRunner()
        r = vp.check_auth_log(fr, sudo_ok=False)
        self.assertEqual(r.status, vp.SKIP)


# --- Task 6: sudoers audit --------------------------------------------------
class TestSudoers(unittest.TestCase):
    def test_only_492_dropin_pass(self):
        fr = FakeRunner({"cat /etc/sudoers": (0, SUDOERS_492_ONLY)})
        r = vp.check_sudoers(fr, user="osboxes", sudo_ok=True)
        self.assertEqual(r.status, vp.PASS)

    def test_foreign_nopasswd_fail(self):
        fr = FakeRunner({"cat /etc/sudoers": (0, SUDOERS_FOREIGN)})
        r = vp.check_sudoers(fr, user="osboxes", sudo_ok=True)
        self.assertEqual(r.status, vp.FAIL)
        self.assertIn("baduser", r.detail)

    def test_no_nopasswd_grants_pass(self):
        # sudo available, sudoers has zero NOPASSWD lines -> "no NOPASSWD" PASS branch.
        text = SUDO_PROMPT + "root ALL=(ALL:ALL) ALL\nosboxes ALL=(ALL) ALL\n"
        fr = FakeRunner({"cat /etc/sudoers": (0, text)})
        r = vp.check_sudoers(fr, user="osboxes", sudo_ok=True)
        self.assertEqual(r.status, vp.PASS)
        self.assertIn("no NOPASSWD", r.detail)

    def test_no_sudo_skip(self):
        r = vp.check_sudoers(FakeRunner(), user="osboxes", sudo_ok=False)
        self.assertEqual(r.status, vp.SKIP)

    def test_cat_command_survives_repr_bash_c_roundtrip(self):
        # F7: the sudo cat command is quote/$/backtick-free, so it survives the
        # vmsdk repr()+bash -c wrapper intact.
        cmd = "cat /etc/sudoers /etc/sudoers.d/*"
        vp._guard(cmd)  # allowlisted + metachar-free
        import shlex as _sh
        wrapped = f"bash -c {repr(cmd)}"
        parts = _sh.split(wrapped)
        self.assertEqual(parts, ["bash", "-c", cmd])


# --- Task 7: ip forwarding --------------------------------------------------
class TestIpForward(unittest.TestCase):
    def test_forwarding_off_pass(self):
        fr = FakeRunner({"sysctl net.ipv4.ip_forward": (0, SYSCTL_OFF_V4),
                         "sysctl net.ipv6.conf.all.forwarding": (0, SYSCTL_OFF_V6),
                         "ip -o addr": (0, IP_ADDR)})
        r = vp.check_ip_forward(fr)
        self.assertEqual(r.status, vp.PASS)

    def test_forwarding_on_fail(self):
        fr = FakeRunner({"sysctl net.ipv4.ip_forward": (0, SYSCTL_ON_V4),
                         "sysctl net.ipv6.conf.all.forwarding": (0, SYSCTL_OFF_V6),
                         "ip -o addr": (0, IP_ADDR)})
        r = vp.check_ip_forward(fr)
        self.assertEqual(r.status, vp.FAIL)

    def test_routable_nic_noted_in_detail(self):
        fr = FakeRunner({"sysctl net.ipv4.ip_forward": (0, SYSCTL_OFF_V4),
                         "sysctl net.ipv6.conf.all.forwarding": (0, SYSCTL_OFF_V6),
                         "ip -o addr": (0, IP_ADDR_ROUTABLE)})
        r = vp.check_ip_forward(fr)
        self.assertIn("203.0.113.10", r.detail)


# --- Task 8: report renderer + exit/JSON contract ---------------------------
class TestRenderer(unittest.TestCase):
    def _mixed(self):
        return [
            vp.CheckResult("a", "A", vp.SEV_HIGH, vp.PASS, "ok"),
            vp.CheckResult("b", "B", vp.SEV_HIGH, vp.FAIL, "bad"),
            vp.CheckResult("c", "C", vp.SEV_HIGH, vp.WARN, "hmm"),
            vp.CheckResult("d", "D", vp.SEV_HIGH, vp.SKIP, "n/a"),
        ]

    def test_text_groups_fail_first_pass_last(self):
        text = vp.render_text(self._mixed())
        order = [text.index(f"[{s}]") for s in (vp.FAIL, vp.WARN, vp.SKIP, vp.PASS)]
        self.assertEqual(order, sorted(order))

    def test_json_schema(self):
        data = json.loads(vp.render_json(self._mixed()))
        self.assertEqual(len(data), 4)
        for d in data:
            self.assertEqual(set(d), {"id", "title", "severity", "status", "detail"})

    def test_text_summary_counts(self):
        text = vp.render_text(self._mixed())
        self.assertIn("FAIL=1", text)
        self.assertIn("WARN=1", text)
        self.assertIn("SKIP=1", text)
        self.assertIn("PASS=1", text)

    def test_exit_code_one_iff_any_fail(self):
        self.assertEqual(vp.exit_code(self._mixed()), 1)
        self.assertEqual(vp.exit_code([r for r in self._mixed() if r.status != vp.FAIL]), 0)

    def test_json_identical_regardless_of_exit(self):
        results = self._mixed()
        before = vp.render_json(results)
        # exit code is derived, not stored — json content must not depend on it
        self.assertEqual(vp.exit_code(results), 1)
        self.assertEqual(vp.render_json(results), before)


# --- Task 9: main CLI wiring + OS guard + reachability ----------------------
class _AssertNoPowerVM:
    """Fake VM whose power/snapshot ops raise if called (no-mutation assertion)."""
    def __init__(self, os_="ubuntu", user="osboxes", run=None):
        self.os = os_
        self.user = user
        self._run = run or (lambda cmd, sudo=False, timeout=None: (0, ""))
    def run(self, cmd, sudo=False, timeout=None):
        return self._run(cmd, sudo=sudo, timeout=timeout)
    def close(self):
        pass
    def up(self, *a, **k):
        raise AssertionError("vm_posture must never power the guest on")
    def down(self, *a, **k):
        raise AssertionError("vm_posture must never power the guest off")
    def baseline(self, *a, **k):
        raise AssertionError("vm_posture must never mutate snapshots")
    def restore(self, *a, **k):
        raise AssertionError("vm_posture must never mutate snapshots")


class TestMain(unittest.TestCase):
    def test_usage_error_exit_2(self):
        self.assertEqual(vp.main([]), 2)
        self.assertEqual(vp.main(["a", "b"]), 2)

    def test_construction_vmerror_exit_2(self):
        def boom(name):
            raise vp.VMError("unknown vm")
        self.assertEqual(vp.main(["nope"], vm_factory=boom), 2)

    def test_non_ubuntu_exit_4(self):
        vm = _AssertNoPowerVM(os_="windows")
        self.assertEqual(vp.main(["win"], vm_factory=lambda n: vm), 4)

    def test_unreachable_raw_transport_exit_3(self):
        # Real vmsdk surfaces a powered-off guest as a RAW transport error
        # (OSError), NOT VMError — main must catch the broad set (plan-critic R1).
        def run(cmd, sudo=False, timeout=None):
            raise OSError("connection refused")
        vm = _AssertNoPowerVM(run=run)
        self.assertEqual(vp.main(["ubuntu_new"], vm_factory=lambda n: vm), 3)

    def test_happy_path_runs_all_checks_no_power_mutation(self):
        scripts = {
            "echo " + vp.SUDO_SENTINEL: (0, SUDO_PROMPT + vp.SUDO_SENTINEL + "\n"),
            "ssh-keygen -lf " + vp._LOGIN_AUTHKEYS: (0, KEYGEN_HOST_ONLY),
            "ssh-keygen -lf " + vp._ROOT_AUTHKEYS: (0, SUDO_PROMPT + KEYGEN_HOST_ONLY),
            "ss -tlnH": (0, SS_LOOPBACK_ONLY),
            "ip -o addr": (0, IP_ADDR),
            "journalctl": (0, JOURNAL_LOCAL),
            "cat /etc/sudoers": (0, SUDOERS_492_ONLY),
            "sysctl net.ipv4.ip_forward": (0, SYSCTL_OFF_V4),
            "sysctl net.ipv6.conf.all.forwarding": (0, SYSCTL_OFF_V6),
        }
        fr = FakeRunner(scripts)
        vm = _AssertNoPowerVM(run=fr)
        with mock.patch.object(vp, "host_pubkey_fingerprint", return_value={HOST_FP}):
            rc = vp.main(["ubuntu_new"], vm_factory=lambda n: vm)
        self.assertEqual(rc, 0)  # all PASS -> exit 0, power ops never tripped

    def test_allowlist_completeness_over_all_checks(self):
        # Every command any check issues must be on the read-only allowlist.
        fr = FakeRunner({
            "echo " + vp.SUDO_SENTINEL: (0, SUDO_PROMPT + vp.SUDO_SENTINEL),
            "ssh-keygen -lf": (0, KEYGEN_HOST_ONLY),
            "ss -tlnH": (0, SS_LOOPBACK_ONLY),
            "ip -o addr": (0, IP_ADDR),
            "journalctl": (0, JOURNAL_LOCAL),
            "cat /etc/sudoers": (0, SUDOERS_492_ONLY),
            "sysctl net.ipv4.ip_forward": (0, SYSCTL_OFF_V4),
            "sysctl net.ipv6.conf.all.forwarding": (0, SYSCTL_OFF_V6),
        })
        sudo_ok = vp.sudo_available(fr)
        vp.check_authorized_keys(fr, {HOST_FP}, sudo_ok)
        vp.check_listening_sockets(fr)
        vp.check_auth_log(fr, sudo_ok)
        vp.check_sudoers(fr, "osboxes", sudo_ok)
        vp.check_ip_forward(fr)
        for cmd, _sudo in fr.calls:
            vp._guard(cmd)  # raises if any issued command is off-allowlist

    def test_json_flag_emits_json_stdout(self):
        scripts = {"echo " + vp.SUDO_SENTINEL: (0, "no sentinel here"),  # sudo unavailable
                   "ssh-keygen -lf": (0, KEYGEN_HOST_ONLY),
                   "ss -tlnH": (0, SS_LOOPBACK_ONLY), "ip -o addr": (0, IP_ADDR),
                   "sysctl net.ipv4.ip_forward": (0, SYSCTL_OFF_V4),
                   "sysctl net.ipv6.conf.all.forwarding": (0, SYSCTL_OFF_V6)}
        vm = _AssertNoPowerVM(run=FakeRunner(scripts))
        import io
        buf = io.StringIO()
        with mock.patch.object(vp, "host_pubkey_fingerprint", return_value={HOST_FP}):
            with mock.patch.object(sys, "stdout", buf):
                rc = vp.main(["ubuntu_new", "--json"], vm_factory=lambda n: vm)
        self.assertEqual(rc, 0)  # sudo SKIPs (3&4), no FAIL -> exit 0 (criterion #5)
        data = json.loads(buf.getvalue())
        statuses = {d["id"]: d["status"] for d in data}
        self.assertEqual(statuses["auth_log"], vp.SKIP)
        self.assertEqual(statuses["sudoers"], vp.SKIP)


if __name__ == "__main__":
    unittest.main()
