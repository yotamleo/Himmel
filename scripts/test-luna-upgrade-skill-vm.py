#!/usr/bin/env python3
"""
test-luna-upgrade-skill-vm.py — host-driven skill-pass VM e2e for the
/luna-upgrade SKILL roundtrip (HIMMEL-493).

NON-GATING — local on-demand dogfood probe, NOT wired into pre-push/
pre-commit/PR CI.  An LLM-in-the-loop, VM-dependent, billing-consuming test
must never block a merge.  Run manually against a live ubuntu_new VM to verify
that the obsidian-triage:luna-upgrade skill, when driven via an interactive
claude session, correctly upgrades a scaffolded OLD vault on the guest.

PASS/FAIL is deterministic (filesystem state after the claude run); the claude
invocation itself is non-deterministic.

Exit codes:
  0  — all assertions passed (RAN >= 6 floor)
  1  — an assertion failed (or RAN floor not cleared; vacuous-green guard)
  3  — environment blocker (VM unreachable, claude absent / auth failure,
        plugin-install env failure) — NOT a code defect; re-run when fixed

Usage:
  python scripts/test-luna-upgrade-skill-vm.py [--help]

Requirements: ubuntu_new VM up on 127.0.0.1:2222; claude authenticated on
the guest; SSH key in ~/.ssh/id_ed25519; primary .env with VM credentials.
"""

import json
import re
import sys
from pathlib import Path

# _LIB is added to sys.path lazily inside main() so hermetic tests that
# import this module (via importlib) can load the helper functions without
# triggering the vmsdk/vbox/dotenv import chain.
_LIB = Path(__file__).resolve().parent / "lib"

# ---------------------------------------------------------------------------
# DIRECTIVE fed to drive_claude — instructs the LLM to invoke the skill and
# apply the upgrade without pausing.  --dangerously-skip-permissions is on
# the inner bash -lc command built by vm.drive_claude(); it is needed so that
# the non-interactive drive (< /dev/null) does not hang at the first tool-use
# permission prompt inside the throwaway test VM.
# ---------------------------------------------------------------------------
DIRECTIVE = (
    "You are running fully autonomously with NO user able to answer prompts. "
    "Invoke the obsidian-triage:luna-upgrade skill to upgrade the luna vault "
    "at ~/luna-test-vault. "
    "This is an automated test: the confirmation to apply is PRE-GRANTED — "
    "proceed through any confirmation and APPLY the upgrade with --yes; "
    "do not stop to ask. "
    "Do not initialize git or offer to commit."
)

# Strings that indicate an auth / billing / quota blocker (only checked on
# non-zero rc to avoid false-positives on clean output that happens to contain
# common English words like "quota").
_AUTH_PATTERNS = [
    r"not logged in",
    r"please run.*login",
    r"invalid api key",
    r"authentication failed",
    r"credit balance",
    r"\bquota\b",
    r"rate limit",
]
_AUTH_RE = re.compile("|".join(_AUTH_PATTERNS), re.IGNORECASE)

RAN_FLOOR = 6


# ---------------------------------------------------------------------------
# Injectable helper functions (testable WITHOUT a live VM)
# ---------------------------------------------------------------------------

def scaffold_vault(run, vault="~/luna-test-vault", himmel="~/github/himmel"):
    """Copy the template tree onto the guest and plant diverged user content.

    Returns (user_sha, tmpl_setup_sha, tmpl_app_sha) as strings, or raises
    SystemExit(3) on any scaffold step failure.
    """
    tmpl = f"{himmel}/templates/luna-second-brain"

    # Step 0: clear any stale vault from a prior run so `cp -r` lands a fresh
    # tree (otherwise cp copies the template INTO the existing dir, nesting it
    # and diverging the wrong files — breaks idempotent re-runs).
    rc, out = run(f"rm -rf {vault}")
    if rc != 0:
        print(f"[scaffold] rm -rf stale vault failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)

    # Step 1: copy the template to a fresh vault location
    rc, out = run(f"cp -r {tmpl} {vault}")
    if rc != 0:
        print(f"[scaffold] cp -r template failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)

    # Plant pure user content (never shipped by the template)
    daily = f"{vault}/50-Journal/Daily/2026-06-21.md"
    rc, out = run(f"mkdir -p {vault}/50-Journal/Daily")
    if rc != 0:
        print(f"[scaffold] mkdir -p failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)

    rc, out = run(
        f"printf 'my private daily note -- keep me byte-identical\\n' > {daily}"
    )
    if rc != 0:
        print(f"[scaffold] write daily note failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)

    rc, out = run(f"sha256sum {daily}")
    if rc != 0:
        print(f"[scaffold] sha256sum daily failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)
    user_sha = out.strip().split()[0]

    # Capture TEMPLATE shas BEFORE diverging owned files
    rc, out = run(f"sha256sum {tmpl}/scripts/setup.sh")
    if rc != 0:
        print(f"[scaffold] sha256sum template setup.sh failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)
    tmpl_setup_sha = out.strip().split()[0]

    rc, out = run(f"sha256sum {tmpl}/.obsidian/app.json")
    if rc != 0:
        print(f"[scaffold] sha256sum template app.json failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)
    tmpl_app_sha = out.strip().split()[0]

    # Diverge the vault's owned copies so there is real upgrade work to do
    rc, out = run(f"printf 'USER DIVERGED\\n' > {vault}/scripts/setup.sh")
    if rc != 0:
        print(f"[scaffold] diverge setup.sh failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)

    rc, out = run(f"printf 'USER DIVERGED\\n' > {vault}/.obsidian/app.json")
    if rc != 0:
        print(f"[scaffold] diverge app.json failed (rc {rc}): {out.strip()[-200:]}")
        sys.exit(3)

    # Remove the stamp so the vault reads as "behind"
    run(f"rm -f {vault}/.vault-template.json")

    return user_sha, tmpl_setup_sha, tmpl_app_sha


def assert_s1_no_stamp(run, vault="~/luna-test-vault"):
    """S1: assert no .vault-template.json exists after scaffold rm."""
    rc, _out = run(f"test -e {vault}/.vault-template.json")
    return rc != 0  # True = pass (file absent, test -e returned nonzero)


def assert_s2_upgrade_complete(log_text):
    """S2: exactly one 'Upgrade complete' line in drive_claude output."""
    return log_text.count("Upgrade complete") == 1


def assert_s3_owned_files_restored(run, vault, tmpl_setup_sha, tmpl_app_sha):
    """S3: template-owned files restored to template sha (two sub-checks)."""
    rc1, out1 = run(f"sha256sum {vault}/scripts/setup.sh")
    got_setup = out1.strip().split()[0] if rc1 == 0 and out1.strip() else ""

    rc2, out2 = run(f"sha256sum {vault}/.obsidian/app.json")
    got_app = out2.strip().split()[0] if rc2 == 0 and out2.strip() else ""

    setup_ok = (rc1 == 0 and got_setup == tmpl_setup_sha)
    app_ok = (rc2 == 0 and got_app == tmpl_app_sha)
    return setup_ok, app_ok


def assert_s4_user_content(run, vault, user_sha):
    """S4: planted user content byte-identical after upgrade."""
    daily = f"{vault}/50-Journal/Daily/2026-06-21.md"
    rc, out = run(f"sha256sum {daily}")
    if rc != 0 or not out.strip():
        return False
    got = out.strip().split()[0]
    return got == user_sha


def assert_s5_stamp(run, vault, himmel="~/github/himmel"):
    """S5: .vault-template.json exists and its .version matches the NESTED
    template marketplace.json metadata.version (NOT the repo-root marketplace).
    """
    nested_mp = (
        f"{himmel}/templates/luna-second-brain/marketplace"
        f"/.claude-plugin/marketplace.json"
    )

    # Read the stamp from the vault
    rc1, out1 = run(f"cat {vault}/.vault-template.json")
    if rc1 != 0:
        return False

    # Read the NESTED template marketplace.json (contains metadata.version)
    rc2, out2 = run(f"cat {nested_mp}")
    if rc2 != 0:
        return False

    try:
        stamp_ver = json.loads(out1)["version"]
        mp_ver = json.loads(out2)["metadata"]["version"]
    except (json.JSONDecodeError, KeyError):
        return False

    return stamp_ver == mp_ver


def _is_auth_blocker(out, rc):
    """Return True if the output + rc signal an auth/billing/quota env blocker.

    Only fires when rc != 0 to avoid false-positives on a clean run whose
    output happens to contain words like 'quota' or 'rate limit'.
    """
    if rc == 0:
        return False
    lower = out.lower().strip() if out else ""
    if not lower:
        # VM.run merges stdout+stderr, so empty output means the process said
        # NOTHING on either stream -> a genuinely silent nonzero exit (startup
        # crash / env), not a failure that merely logged to stderr.
        return True
    return bool(_AUTH_RE.search(lower))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    if "--help" in sys.argv or "-h" in sys.argv:
        print(__doc__)
        sys.exit(0)

    # Lazy import of vmsdk so hermetic test imports of this module don't
    # trigger the vbox/dotenv chain.
    sys.path.insert(0, str(_LIB))
    from vmsdk import VM  # noqa: PLC0415

    fails = 0
    ran = 0

    def ok(label):
        nonlocal ran
        print(f"PASS  {label}")
        ran += 1

    def fail(label, reason=""):
        nonlocal ran, fails
        msg = f"FAIL  {label}"
        if reason:
            msg += f" -- {reason}"
        print(msg)
        fails += 1
        ran += 1

    # 1. VM up + claude probe (login shell so ~/.local/bin is on PATH)
    vm = VM("ubuntu_new")
    vm.ensure_up()

    rc, _out = vm.run("bash -lc 'command -v claude'")
    if rc != 0:
        print("[env] claude not found on guest (command -v claude failed)")
        sys.exit(3)

    # 2. Sync repo
    local_root = Path(__file__).resolve().parent.parent
    try:
        vm.sync_repo(local_root)  # → ~/github/himmel
    except EnvironmentError as e:
        print(f"[env] sync_repo failed: {e}")
        sys.exit(3)

    # 3. Install obsidian-triage plugin
    try:
        vm.install_plugin("~/github/himmel/marketplace", "obsidian-triage")
    except EnvironmentError as e:
        print(f"[env] plugin install failed: {e}")
        sys.exit(3)
    ok("S0 obsidian-triage plugin installed")

    # 4. Scaffold the vault
    user_sha, tmpl_setup_sha, tmpl_app_sha = scaffold_vault(vm.run)

    # S1: no stamp yet
    if assert_s1_no_stamp(vm.run):
        ok("S1 no .vault-template.json before upgrade")
    else:
        fail("S1 no .vault-template.json before upgrade",
             ".vault-template.json exists after scaffold rm")

    # 5. Drive the skill
    log_dir = Path(__file__).resolve().parent.parent / ".superpowers" / "sdd"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / "skill-vm-run.log"

    rc_drive, out_drive = vm.drive_claude(
        DIRECTIVE, "~/luna-test-vault", timeout=600
    )

    # Tee to log file
    try:
        log_path.write_text(out_drive, encoding="utf-8", errors="replace")
        print(f"[log] drive output written to {log_path}")
    except OSError as e:
        print(f"[log] warning: could not write log: {e}")

    # 6. rc-3 env-block check (BEFORE asserting S2)
    # A timeout kill is an ENVIRONMENT condition (VM too slow / claude stalled),
    # not a skill assertion failure -> exit 3 per the documented contract.
    if rc_drive == 124:
        print("[env] drive_claude timed out (rc 124)")
        sys.exit(3)

    # Crash = signal death (rc >= 128: SIGSEGV 139 / SIGKILL 137 / 128+n). We do
    # NOT also match crash KEYWORDS on an arbitrary nonzero rc: a genuine skill
    # defect that exits rc=1 and merely prints "core dumped" in its output must
    # surface as an assertion failure (rc 1), not be masked as an env crash.
    if rc_drive >= 128:
        print(
            f"[env] claude crashed on guest (rc={rc_drive}); "
            f"this is an environment issue, not a code defect.\n"
            f"Output tail: {(out_drive or '').strip()[-300:]}"
        )
        sys.exit(3)

    if _is_auth_blocker(out_drive, rc_drive):
        print(
            f"[env] auth/billing/quota blocker detected in drive output "
            f"(rc={rc_drive}); this is an environment issue, not a code defect.\n"
            f"Output tail: {out_drive.strip()[-300:]}"
        )
        sys.exit(3)

    # 7. Assertions
    # S2: exactly one "Upgrade complete" in the teed log
    if assert_s2_upgrade_complete(out_drive):
        ok("S2 exactly one 'Upgrade complete' in drive output")
    else:
        count = out_drive.count("Upgrade complete")
        fail("S2 exactly one 'Upgrade complete' in drive output",
             f"found {count}")

    # S3: owned files restored (two sub-checks = ran+=2)
    setup_ok, app_ok = assert_s3_owned_files_restored(
        vm.run, "~/luna-test-vault", tmpl_setup_sha, tmpl_app_sha
    )
    if setup_ok:
        ok("S3a scripts/setup.sh restored to template sha")
    else:
        fail("S3a scripts/setup.sh restored to template sha", "sha mismatch or missing")
    if app_ok:
        ok("S3b .obsidian/app.json restored to template sha")
    else:
        fail("S3b .obsidian/app.json restored to template sha", "sha mismatch or missing")

    # S4: user content untouched
    if assert_s4_user_content(vm.run, "~/luna-test-vault", user_sha):
        ok("S4 planted user content byte-identical")
    else:
        fail("S4 planted user content byte-identical", "sha mismatch or missing")

    # S5: stamp version == nested template marketplace.json metadata.version
    if assert_s5_stamp(vm.run, "~/luna-test-vault"):
        ok("S5 .vault-template.json version matches nested marketplace.json")
    else:
        fail("S5 .vault-template.json version matches nested marketplace.json",
             "version mismatch or file missing")

    print(f"\nRAN: {ran}")
    print(f"RESULT: {fails} failure(s)")

    if fails == 0 and ran >= RAN_FLOOR:
        sys.exit(0)
    else:
        if ran < RAN_FLOOR:
            print(
                f"ABORT: only {ran} assertions ran (floor {RAN_FLOOR}); "
                "possible silent skip — vacuous green guard triggered"
            )
        sys.exit(1)


if __name__ == "__main__":
    main()
