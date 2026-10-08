# Local macOS test lane (Docker-OSX) — HIMMEL-4980

A console-owned way to get a real macOS proof for BSD-userland, `ps`/`stat`/`sed`,
`sandbox-exec`, Keychain and launchd/cron fixes, on the Linux station. It is a
**local repro lane only**: it is **not** wired into GitHub CI (EULA; a
self-hosted runner on a public repo is a risk — the GitHub macOS dispatch in
`.github/workflows/os-verify.yml` stays the CI path).

**Status: plan + runner only. Nothing is installed.** The first `docker pull`,
image build and KVM use wait for the operator's explicit go through the console.

## Image choice

| | `sickcodes/docker-osx` | `dockur/macos` |
|---|---|---|
| Boot model | QEMU/KVM + OpenCore (OSX-KVM) | QEMU/KVM, recovery-image install |
| macOS versions | Catalina to Sequoia (Tahoe listed) via `SHORTNAME` | 11 to 15 via `VERSION` (26 "very slow") |
| Headless SSH | **Yes** — `-p 50922:10022`, no display needed; `naked-auto` takes `USERNAME`/`PASSWORD`/`OSX_COMMANDS` | **No documented SSH or unattended path**; setup is interactive in a browser viewer (port 8006) |
| Persistent disk | Bring your own `mac_hdd_ng.img` (`naked` / `naked-auto`) | Container volume, `DISK_SIZE` |
| Maintenance | ~53k stars, GPL-3.0, last push 2025-11-11 (luna note, revalidated 2026-09-14) = **community-thin, stale** | Active, 622 commits; commit dates not visible on the README page |
| EULA text | luna note flags the licensing risk | README: "only run this container on Apple hardware" |

**Choice: `sickcodes/docker-osx:naked-auto`**, pinned to **Monterey (12)** for the
disk build (the most-exercised path; macOS 12 is old enough that bash 3.2 + BSD
tools match what macOS users run, and Homebrew still supports it as tier 3).
Reason: it is the only candidate with a documented headless SSH mode, which is
what a console-driven runner needs. Staleness is the accepted risk — the lane
only needs the container to boot an image we already own. If it stops booting,
`dockur/macos` is the fallback, but it needs a manual first install and an SSH
setup inside the guest. **Re-verify the flags below on the first real run.**

## Host requirements (read-only check, 2026-10-08, this station)

| Need | Station |
|---|---|
| `/dev/kvm` | present (mode 666); `vmx`/`svm` flag count 32 |
| Container runtime | `/usr/bin/docker` present; podman absent |
| Free RAM | 46 GiB total, ~26 GiB available, 38 GiB swap free — tight while a fleet is running |
| Free disk | 3.2 TiB free on `/` and `/home` |
| x86_64 + AVX2 | needed by both images; verify with `grep -c avx2 /proc/cpuinfo` before the go |

## Resource budget

- Guest: **8 GiB RAM, 4 vCPUs** (`HIMMEL_MACOS_LANE_RAM_GB`, `HIMMEL_MACOS_LANE_CPUS`);
  container capped at RAM+2 GiB, `--pids-limit 4096`.
- Disk: ~50 GiB for the persistent image with Xcode CLT, git, bash 5, node, bun, gh.
- Per-run wall clock: boot to SSH ~3-6 min (600 s budget), sync ~1 min, then the suites.
- Do not start it while the fleet is near the RAM ceiling; the console decides.

## One-time setup (needs the operator go; run from a console shell, never a leg)

1. `export HIMMEL_MACOS_LANE_OK=1` in the launching shell.
2. Pull `sickcodes/docker-osx:naked-auto`; produce `mac_hdd_ng.img` under
   `HIMMEL_MACOS_LANE_DIR` (default `$TMPDIR/himmel-macos-lane`) per the upstream
   README (Monterey). Use a persistent dir, not tmp, for the real disk.
3. Boot once, create the `user` account, enable Remote Login.
4. Generate the lane key: `ssh-keygen -t ed25519 -N '' -f $HIMMEL_MACOS_LANE_DIR/id_ed25519`
   and install the public key in the guest. The runner never uses the host's keys or `~/.ssh`.
5. In the guest: Xcode CLT, Homebrew, `bash`, `git`, `node`, `bun`, `gh`, `rsync`; shut down cleanly.
6. Snapshot or copy the disk image so a corrupted run can be reverted.

## Per run

```bash
export HIMMEL_MACOS_LANE_OK=1
L=scripts/macos/macos-lane.sh
bash $L start && bash $L wait-ssh
bash $L sync-worktree <worktree>
bash $L run-suites scripts/test-himmel-doctor.sh scripts/handover/console-kit/test-hook-copy-reaper.sh
bash $L fetch-results <dest>     # <suite>.log + <suite>.rc per suite
bash $L stop
```

Every call is bounded by `timeout` (start 120 s, boot 600 s, sync 300 s, suite 900 s,
fetch 120 s, stop 60 s; override via `HIMMEL_MACOS_LANE_T_*`). Suite paths must be
repo-relative `scripts/**/*.sh` with no `..` or shell metacharacters. The runner
never reads or writes the real HOME or handover state: ssh runs with `-F /dev/null`,
a lane-private key and `known_hosts`, and SSH is published on `127.0.0.1` only.
`bash scripts/macos/macos-lane.sh plan` prints the effective settings.

Tested by `scripts/macos/test-macos-lane.sh` (stubbed docker/ssh/rsync/timeout; no
real container, KVM or network).

## Cost

Per run: a few minutes of boot plus the suites, with ~10 GiB RAM and 4 cores held
for the duration. Standing cost: ~50 GiB of disk. Nothing runs when idle.

## EULA note

Apple's licence permits macOS only on Apple-branded hardware. Docker-OSX on a
non-Apple station is outside that, which is why this is **local, operator-approved
repro only** — never in GitHub CI, never on a shared or hosted runner, never
redistributing the disk image. The operator's call of 2026-10-08 accepts that for
local testing; this doc does not make the licensing question go away.

## Not done yet

- The `himmel-ops:vm`-style entry (item 3 of the ticket) and the real first run
  (`scripts/test-himmel-doctor.sh`, `test-hook-copy-reaper.sh`) wait for the
  operator's go; HIMMEL-4980 stays open.
