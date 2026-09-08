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
  a baseline snapshot (**`suite-ready-v4`**, not `suite-ready`,
  `suite-ready-v2` or `suite-ready-v3`) before every run instead. Do not
  "clean up" an idle `himmel-ar-N` by deleting it — restoring is the
  clean-state mechanism here, not deletion.
- **The baseline snapshot is `suite-ready-v4`; all three older snapshots are
  kept, deliberately.** Three image-level facts, not incident colour —
  introduced at v2/v3 and carried forward unchanged into v4:
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
     per-clone patch, and why v4 bakes its own machine-config change
     (bidirectional clipboard AND drag-and-drop) into the snapshot the same
     way.
  3. A linked clone also INHERITS the source's `/etc/machine-id` and ssh
     host keys verbatim (confirmed empirically: source and clone shared the
     same machine-id and all three host-key fingerprints) — an identity
     collision `suite-ready-v2` still had. Fixed by shipping an
     UNPERSONALISED golden image (`suite-ready-v3`: machine-id zeroed, dbus
     id symlinked to it, host keys removed, a first-boot oneshot
     regenerating both) — each CLONE of it then regenerates its OWN
     identity on its first boot, which is why a clone's own baseline
     snapshot must be taken AFTER that first boot, never before. v4 ships
     the same unpersonalised state, and the HIMMEL-2747 re-clone of
     `himmel-ar-1` reconfirmed this empirically rather than assuming it:
     fresh machine-id `3234173620d64e4abedbf4756cb3812c` and freshly
     generated ECDSA/ED25519/RSA host keys at first boot
     (2026-09-07T11:13:24Z), none inherited from `ubuntu_new`.
  `suite-ready` (v1) is NOT dead weight to tidy up: `himmel-ar-1`'s
  linked-clone disk chain still runs back through it (v4 -> ... -> v1 -> the
  base cloud image, four `ubuntu_new` differencing disks deep).
  `suite-ready-v2` and `suite-ready-v3` also still exist on `ubuntu_new` for
  the same reason: superseded, never deleted, not the default.
- **The default is `suite-ready-v4` (HIMMEL-2738/2681/2747).** v4 adds, over
  v3: VirtualBox Guest Additions userspace (`virtualbox-guest-utils`,
  installed guest-side since the host has no `VBoxGuestAdditions.iso` to
  attach); bidirectional clipboard AND drag-and-drop set as MACHINE CONFIG
  (with the VM powered off, so it lives in the snapshot; draganddrop moved
  disabled -> bidirectional); a tty1 auto-login drop-in so an operator has a
  console at all; and node 24.20.0 + npm 11.19.0 + bun 1.4.2 + unzip +
  Claude Code 2.1.263, closing HIMMEL-2681's runtime-skew precondition (v3
  shipped node 18.19.1 against this repo's `.nvmrc` pin of 24, and no bun).
  The move was made by delete-and-re-clone (HIMMEL-2747, 2026-09-07), not by
  pointing the existing `himmel-ar-1` clone at a newer snapshot name — a
  linked clone's disk chain is bound to the source snapshot it was cut from,
  and no VBoxManage operation re-points it. The operator ran `VBoxManage
  unregistervm himmel-ar-1 --delete` on the old v3-based clone and
  re-created `himmel-ar-1` as a fresh linked clone of
  `ubuntu_new@suite-ready-v4`, booted it once so
  `himmel-firstboot-identity` could regenerate its identity (confirmed, see
  fact 3 above), then powered off and snapshotted the clone's OWN baseline
  as `suite-ready-v4`. Machine config (NAT forward, 4096MB RAM, 4 cpus, vram
  32, vmsvga, nic1 nat) was reproduced from the persisted pre-delete
  baseline, with `draganddrop` moved to `bidirectional` to match the new
  image; guest content (node 24.20.0, npm 11.19.0, bun 1.4.2, claude
  2.1.263) was confirmed present. **Known caveat:** bun is on the
  login-shell PATH via `.bashrc` but NOT on the non-interactive ssh PATH
  `after-report.sh`'s `guest_ssh()` actually uses, so a guest suite run
  through that script does not currently see it — a separate ticket, not
  fixed here. **The vacuous-pass trap for the NEXT migration (v4 -> v5):** a
  snapshot merely NAMED `suite-ready-vN` on a clone that still carries the
  PREVIOUS image's guest content reports green while silently measuring the
  suites on stale software — the exact trap HIMMEL-2681 exists to stop.
  Hand-upgrading the guest inside a clone's own writable differencing disk
  is technically possible and is rejected on MERIT, not impossibility: it
  produces a hand-provisioned near-duplicate of the golden image that no
  longer descends from it, drifting silently — "restore to the baseline"
  would then mean "restore to whatever someone typed into this one clone."
  The only sound path, demonstrated by this migration: delete the clone for
  real (an operator action, refused outright by this harness's auto-mode
  classifier so it cannot happen from a session), re-clone from the new
  golden snapshot, boot once to regenerate identity, verify machine-id/
  host-keys are actually fresh and guest content actually matches the new
  image, THEN move `scripts/vm/after-report.sh`'s, `dry-run-restore.sh`'s
  and this file's default together — `test-after-report.sh`'s T10 asserts
  all three agree.
- **`suite-ready-v4` vs `suite-ready-v4-auth`.** `suite-ready-v4`
  (`92a7e71a-6dbd-48a9-bda3-fc1ef1dadfc7`) is the golden, credential-free,
  cloneable base. `suite-ready-v4-auth` (`eb401446-0b61-4fe5-a679-541b427adfe4`)
  is a separate snapshot taken after the operator's one manual `claude`
  login — it is personalised and must NEVER be the source of an
  after-report linked clone, or of any image handed to another machine.
  The HIMMEL-2457 acceptance cells (K1/K2/K2b/K5) run DIRECTLY on
  `ubuntu_new@suite-ready-v4-auth`, restoring that snapshot BETWEEN cells —
  never on a linked clone of it: a restore-per-cell gives the same "no cell
  inherits another" guarantee a fresh clone would, without replicating the
  operator's OAuth credentials into a second registered VM, which is
  exactly what the v4 / v4-auth split exists to prevent. Cloning a
  credential-bearing image is forbidden; clone `suite-ready-v4` (the
  golden, credential-free base) instead.
- **The golden image is snapshotted UNPERSONALISED.** "Snapshot after a
  first boot" (above) is a rule for a CLONE's own baseline, not for the
  golden image — the golden image is snapshotted BEFORE any identity
  exists. If a leg boots `ubuntu_new` to modify the image, it must
  re-de-personalise before snapshotting: truncate `/etc/machine-id` to 0
  bytes, symlink `/var/lib/dbus/machine-id` to it, remove
  `/etc/ssh/ssh_host_*`, re-create `/etc/himmel-regen-identity` (the
  `himmel-firstboot-identity.service` `ConditionPathExists=|` trigger), and
  confirm that service is `enabled`. Skipping this ships a personalised
  golden image — exactly the machine-id/host-key collision `suite-ready-v3`
  was cut to fix, one level up.
- **No GUI in the guest.** This image has no display manager and no X
  server, so the bidirectional clipboard machine-config setting (above) is
  correct and necessary but has nothing to attach to — `VBoxClient
  --clipboard` needs an X11/Wayland session, and a guest-side clipboard
  round trip is NOT achievable on this image. Do not spend a leg trying to
  verify one. Two host→guest text paths ARE proven: (a) `ssh -p 2222
  himmel@127.0.0.1` from a host terminal, using the HOST's own clipboard;
  (b) `VBoxManage controlvm ubuntu_new keyboardputstring "<text>"` followed
  by `VBoxManage controlvm ubuntu_new keyboardputscancode 1c 9c` (Enter),
  typing straight into the auto-logged-in tty1 console.
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
