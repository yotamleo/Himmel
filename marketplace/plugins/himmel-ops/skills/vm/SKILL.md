---
name: vm
description: Use when bringing up, stopping, snapshotting, provisioning, or running e2e probes against the himmel test VMs (ubuntu_new / win11_base_himmel). Trigger on "start/stop/snapshot a VM", "run the VM e2e", "provision the VM", or "/vm". Front door to the central VM-control SDK (scripts/lib/vmsdk.py, HIMMEL-491/493).
---

# vm — VM lifecycle + e2e runbook (HIMMEL-491/493)

Lean-invoke skill. Invoke on demand when you need to drive a test VM.
Do NOT use this as an always-on rule.

## Safety rails — read first

- **Only ONE VM online at a time.** Power the previous one down before
  starting another.
- **Power the VM OFF when done** — `python scripts/lib/vmsdk.py <vm> down`.
- Creds and the GitHub PAT (`himmel_github_token_vm`) live in the **primary
  checkout's `.env`** — the gitignored `.env` is NOT copied into worktrees.
  The SDK resolves it automatically via `git rev-parse --git-common-dir`, but
  always invoke `vmsdk.py` from the primary checkout root to be safe.
- Ports (loopback only): `ubuntu_new` → **2222**, `win11_base_himmel` → **2223**.

## VM registry

Defined in `scripts/lib/vms.json`. Known VMs:

| VM name | OS | SSH port |
|---|---|---|
| `ubuntu_new` | Ubuntu | 2222 |
| `win11_base_himmel` | Windows 11 | 2223 |

## CLI — `vmsdk.py`

```
python scripts/lib/vmsdk.py <vm> <verb>
```

Full usage line from the script:

```
usage: vmsdk.py <vm> <up|down|snapshot NAME|restore NAME|baseline NAME|clone [REF]|provision|e2e>
```

| Verb | What it does |
|---|---|
| `up` | Power on the VM and wait for SSH |
| `down` | Graceful power-off (pass `graceful=False` in code for hard power-off) |
| `snapshot NAME` | Take a named VirtualBox snapshot |
| `restore NAME` | Restore to a named snapshot (powers off + restores) |
| `baseline NAME` | Restore `NAME` if it exists, else provision from scratch and snapshot it — idempotent clean-state shortcut |
| `clone [REF]` | Shallow-clone the private himmel repo onto the guest (`REF` defaults to `main`) |
| `provision` | Run the per-OS provisioner (`ubuntu-vm-setup.py` or `windows-vm-setup.py`) |
| `e2e` | Run the install/uninstall symmetry e2e against an Ubuntu VM (delegates to `scripts/test-install-symmetry-vm.sh`) |

**All invocations must be from the primary checkout** (not a worktree) — the
SDK resolves `.env` via `git rev-parse --git-common-dir`; worktrees lack `.env`.

## e2e probes

Two probes exist. Run them **after** the VM is up and provisioned.

### Engine pass (deterministic, no LLM — GATING)

```
bash scripts/test-luna-upgrade-vm.sh [user@host] [port] [identity]
```

Defaults: `user@localhost 2222 $HOME/.ssh/id_ed25519`.
Windows VM example:

```
bash scripts/test-luna-upgrade-vm.sh <winuser>@localhost 2223 ~/.ssh/id_ed25519
```

Exit codes: `0` = all assertions passed; `1` = an assertion failed;
`3` = VM unreachable (key auth) — not a code defect, re-run when the VM is up.

This is the deterministic engine test (no claude invocation, no billing).
It proves `upgrade.sh` + the template work correctly on the real VM OS.

### Skill pass (LLM-in-the-loop — NON-GATING)

```
python scripts/test-luna-upgrade-skill-vm.py
```

Requirements: `ubuntu_new` VM up on `127.0.0.1:2222`; `claude` authenticated
on the guest; SSH key at `~/.ssh/id_ed25519`; primary `.env` with VM
credentials.

Exit codes: `0` = all assertions passed; `1` = an assertion failed;
`3` = environment blocker (VM unreachable, claude absent, plugin-install
failure) — not a code defect, re-run when fixed.

**NON-GATING** — this probe is NOT wired into pre-push / pre-commit / PR CI.
An LLM-in-the-loop, VM-dependent, billing-consuming test must never block a
merge. Run manually on demand to dogfood the `/luna-upgrade` skill end-to-end.
The `drive_claude` primitive keeps the invocation non-headless and billing-safe
per HIMMEL-128.

## Central SDK primitives

Three reusable methods on the `VM` class in `scripts/lib/vmsdk.py` that
the e2e harness uses internally:

- **`sync_repo(local_root, dest)`** — stage a local checkout onto the guest
  via a tar-over-ssh pipe (key auth, Git Bash on Windows); used to push the
  current worktree to the VM for testing.
- **`install_plugin(marketplace_dir, plugin)`** — register a marketplace and
  install one plugin on the guest via `claude plugin install`; verifies
  presence after install.
- **`drive_claude(prompt, cwd)`** — drive an interactive `claude "<prompt>"`
  session on the guest (positional prompt, not `-p`/`--print`, so it is
  non-headless and billing-safe per HIMMEL-128); returns `(rc, output)`.

## Typical session

```bash
# 1. Bring the VM up
python scripts/lib/vmsdk.py ubuntu_new up

# 2. Ensure a clean baseline (provision once, snapshot, restore on next run)
python scripts/lib/vmsdk.py ubuntu_new baseline clean

# 3. Sync the current worktree onto the guest
#    (done by the e2e scripts; or call vm.sync_repo() directly in Python)

# 4. Run the deterministic engine pass
bash scripts/test-luna-upgrade-vm.sh

# 5. Optionally run the skill pass dogfood probe
python scripts/test-luna-upgrade-skill-vm.py

# 6. Power the VM OFF when done
python scripts/lib/vmsdk.py ubuntu_new down
```
