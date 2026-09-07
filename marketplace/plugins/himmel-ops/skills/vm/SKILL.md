---
name: vm
description: Use to start/stop/snapshot/provision the himmel test VMs, run the VM e2e, or arm a claude session on them. Or /vm.
---

# vm — VM lifecycle + e2e runbook (HIMMEL-491/493)

Lean-invoke skill. Invoke on demand when you need to drive a test VM.
Do NOT use this as an always-on rule.

## Safety rails — read first

- **Concurrency rail (amended HIMMEL-2623):** the old "only ONE VM online at a
  time" rule was Windows-era — it existed for shared loopback ports (2222/2223)
  and host RAM, carried no stated rationale, and blocked exactly the parallel
  linked-clone design HIMMEL-2623 needed on purpose. It is now: **one VM per
  loopback port; clones get distinct loopback ports above the registered
  set — the allocator skips any port a registered VM already claims — and a
  RAM budget (4 GB each, capped via env against free host RAM); the
  wet-suite baseline VM and the audit clone remain exclusive with each
  other.** `ubuntu_new`/`win11_base_himmel` (the wet-suite baselines) and
  `himmel-parity-audit` (the audit clone) still never run alongside each
  other — that exclusivity is unchanged. The after-report clones
  (`himmel-ar-1`..`himmel-ar-$HIMMEL_VM_AR_MAX`, `scripts/vm/after-report.sh`)
  are the first consumer of the new rule: several can run at once, each on
  its own port, because each is genuinely its own host for the machine-lock
  purposes HIMMEL-2623 exists to route around.
- **Power the VM OFF when done** — `python scripts/lib/vmsdk.py <vm> down`
  (after-report.sh does this itself for its own clones, at the end of every
  run).
- Creds and the GitHub PAT (`himmel_github_token_vm`) live in the **primary
  checkout's `.env`** — the gitignored `.env` is NOT copied into worktrees.
  The SDK resolves it automatically via `git rev-parse --git-common-dir`, but
  always invoke `vmsdk.py` from the primary checkout root to be safe.
- Ports (loopback only): `ubuntu_new` → **2222**, `win11_base_himmel` →
  **2223**, `himmel-parity-audit` → **2224**. After-report clones start at
  **2231** and step upward, skipping any port already claimed by a
  registered VM (`scripts/vm/port-alloc.sh`) — never assume a fixed block is
  free; enumerate via `VBoxManage list vms` + `showvminfo --machinereadable`
  before hardcoding a port.
- **After-report clones are PERSISTENT, never deleted** — `VBoxManage
  unregistervm --delete` is refused by this harness's auto-mode classifier,
  so `scripts/vm/after-report.sh` creates each clone ONCE and RESTORES it to
  a baseline snapshot (**`suite-ready-v3`**, not `suite-ready` or
  `suite-ready-v2`) before every run instead. Do not "clean up" an idle
  `himmel-ar-N` by deleting it — restoring is the clean-state mechanism
  here, not deletion.
- **The baseline snapshot is `suite-ready-v3`; both older snapshots are kept,
  deliberately.** Three image-level facts, not incident colour:
  1. `VBoxManage clonevm` regenerates MACs, and the ORIGINAL (`suite-ready`,
     v1) base image's netplan pinned `match: macaddress:` to the SOURCE VM's
     own MAC — so every linked clone of it got a NIC matching nothing: no
     DHCP, no ssh, ever, for ANY clone. Fixed at image level (netplan now
     matches on interface NAME; cloud-init's network config is disabled so
     it cannot regenerate a MAC-pinned file).
  2. `VBoxManage snapshot restore` reverts MACHINE CONFIG, not just disk, so
     a per-clone `modifyvm` fix would be silently undone on the very next
     restore — only an image-level fix persists, which is why the netplan
     fix needed a new base snapshot (`suite-ready-v2`) rather than a
     per-clone patch.
  3. A linked clone also INHERITS the source's `/etc/machine-id` and ssh
     host keys verbatim (confirmed empirically: source and clone shared the
     same machine-id and all three host-key fingerprints) — an identity
     collision `suite-ready-v2` still had. Fixed by shipping an
     UNPERSONALISED golden image (`suite-ready-v3`: machine-id zeroed, dbus
     id symlinked to it, host keys removed, a first-boot oneshot
     regenerating both) — each CLONE of it then regenerates its OWN
     identity on its first boot, which is why a clone's own baseline
     snapshot must be taken AFTER that first boot, never before.
  `suite-ready` (v1) is NOT dead weight to tidy up: `himmel-ar-1`'s disk
  chain is a linked clone that depends on it existing. `suite-ready-v2`
  still exists on `ubuntu_new` too — superseded, not deleted, and not the
  default for the same reason v1 isn't.
- The guest SSH login for `ubuntu_new`-derived VMs is `vms.json`'s
  `ubuntu_new.user` literal (`himmel`) — it wins over the (possibly stale)
  `user_env`-resolved value (HIMMEL-2623). Repoint every consumer at once by
  editing that one JSON field, not by hardcoding a username elsewhere.

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
usage: vmsdk.py <vm> <up|down|snapshot NAME|restore NAME|baseline NAME|clone [REF]|provision|e2e|push FILE [DEST]|trigger HANDOVER [--at TIME] [--cwd DIR] [--long-gap] [--timeout N]>
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
| `push FILE [DEST]` | Copy one host file to the guest via SFTP (`DEST` defaults to `~/handover-inbox/<name>`; `.env*` files refused) |
| `trigger HANDOVER [--at TIME] [--cwd DIR] [--long-gap] [--timeout N]` | Fire a claude session ON the guest from a host handover file (HIMMEL-835): pushes the handover, then either drives an immediate bounded session (default) or, with `--at`, arms the guest's own `arm-resume.sh` (at/atd backend). `--cwd` defaults to the guest's private-checkout path under `~/Documents/github/` (the ubuntu_new layout, verified 2026-07-09). `--long-gap` (HIMMEL-1475) forwards arm-resume's `--long-gap` so a far `--at TIME` (>60 min out) is not refused (rc 9) by the long-gap guard; only valid with `--at`. Single-writer: do not trigger a ticket another writer owns |

**All invocations must be from the primary checkout** (not a worktree) — the
SDK resolves `.env` via `git rev-parse --git-common-dir`; worktrees lack `.env`.

## After-report runner — `scripts/vm/after-report.sh` (HIMMEL-2623)

```bash
bash scripts/vm/after-report.sh <branch> <pr>
```

Runs the shell-unit after-report (`scripts/ci/run-shell-tests.sh
--changed-since origin/main --pr <N>`, the local twin of the public
shell-unit CI job) inside one of the `himmel-ar-1`..`himmel-ar-$HIMMEL_VM_AR_MAX`
linked clones instead of on this host, so it stops contending for the host's
machine-wide suite lock. **Deliberately NOT a `vmsdk.py` verb** — this is a
CI/after-report workflow that happens to use a VM, not a VM-lifecycle
operation, and it calls `scripts/lib/vbox.py`'s primitives rather than
living inside them. Key knobs: `HIMMEL_VM_AR_MAX` (default 2); `VBOXMANAGE_PATH`
+ `HIMMEL_VM_AR_LIVE` as a pair — an UNSET `VBOXMANAGE_PATH` refuses outright
unless `HIMMEL_VM_AR_LIVE=1` is also set for that invocation, and only then
does it fall through to the real default (`/usr/bin/VBoxManage` on this
station); `HIMMEL_VM_PYTHON` (default `~/.himmel/vm-venv/bin/python`). Falls
back loudly — never a silent green — to naming the host invocation when the
VM runner is unavailable. Full env list + design rationale is in the
script's own header comment.

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
  **Permissions policy (HIMMEL-575):** the drive runs with
  `--dangerously-skip-permissions` *on purpose* — a VM is throwaway, isolated,
  and holds no operator data, and the non-interactive drive (`< /dev/null`) has
  no human to answer a tool-use prompt, so the guest is allowed to "run wild";
  the blast radius is the disposable VM. This is intentionally the OPPOSITE of
  the user-facing unattended path (the pipeline-cadence runner on the operator's
  real machine), which never skips permissions and instead injects a curated
  allowlist+guardrail via `claude --settings <fragment>` (the grant-only
  auto-approve-safe-bash hook). **VM = run wild; real machine = allowlist.**

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
