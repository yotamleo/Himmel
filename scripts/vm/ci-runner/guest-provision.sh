#!/usr/bin/env bash
# guest-provision.sh — runs ONCE, as root, INSIDE the himmel-ci-1 test VM
# (HIMMEL-5037), while scripts/vm/ci-runner.sh build bakes the ci-runner-v1
# snapshot. Never run it on a station host: it refuses anything
# systemd-detect-virt does not call a VM.
#
#   sudo bash guest-provision.sh <owner/repo>
#
# It installs, and leaves UNREGISTERED (registration happens per job, from the
# host, with a single-use JIT config that never touches this disk):
#   - a non-root `runner` user, outside every sudo/admin group;
#   - the Actions runner, pinned by version AND sha256 (below);
#   - the job-started fork guard (job-started-hook.sh, next to this file),
#     wired through the run-job wrapper's environment;
#   - /usr/local/sbin/himmel-ci-run-job, the one entry the host loop calls:
#     it reads the JIT config from stdin and runs ONE job as `runner`;
#   - an nftables egress filter: the guest may reach the internet (GitHub,
#     package mirrors) and the VirtualBox NAT DNS, but no private, link-local
#     or CGNAT range — so no station LAN. The host loop additionally sets
#     `--nat-localhostreachable1 off` after every restore, so 10.0.2.2 is not  # leak-allow: private-lan-ip VBox NAT address
#     the station's loopback either.
#   - no VirtualBox Guest Additions userspace: the base image carries
#     virtualbox-guest-utils (clipboard and drag-and-drop services), which a
#     job must not have a channel through; nothing the shell-unit shards run
#     needs it. The host also sets both off as machine config.
#   - the packages the ubuntu shell-unit shard otherwise installs with sudo
#     (at/atd, ffmpeg 6.1, pre-commit 4.6.2), since `runner` has no sudo.
# ponytail: egress is a deny-private list, not a GitHub/mirror allow-list (IPs
# rotate); upgrade to a GitHub + package-mirror allow-list per HIMMEL-5041.
set -eu

virt=$(systemd-detect-virt --vm 2>/dev/null || true)
if [ -z "$virt" ] || [ "$virt" = none ]; then
    echo "guest-provision: not a VM (systemd-detect-virt --vm: '${virt:-<none>}') — the runner never installs on a station host" >&2
    exit 3
fi
[ "$(id -u)" = 0 ] || { echo "guest-provision: run as root (sudo)" >&2; exit 3; }
repo="${1:?usage: guest-provision.sh <owner/repo>}"
case "$repo" in
    */*) ;;
    *) echo "guest-provision: '$repo' is not owner/repo" >&2; exit 2 ;;
esac
here="$(cd "$(dirname "$0")" && pwd)"

# Pinned runner. Bump both together from the release's own "BEGIN SHA
# linux-x64" line; GitHub stops serving jobs to a runner left too far behind.
RUNNER_VERSION=2.338.0
RUNNER_SHA256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
RUNNER_DIR=/opt/actions-runner

export DEBIAN_FRONTEND=noninteractive
apt-get update -o Acquire::Retries=3
apt-get install -y --no-install-recommends ca-certificates curl git jq unzip rsync \
    nftables at 'ffmpeg=7:6.1.*' python3-venv
systemctl enable atd
if dpkg -s virtualbox-guest-utils >/dev/null 2>&1 || dpkg -s virtualbox-guest-x11 >/dev/null 2>&1; then
    apt-get purge -y virtualbox-guest-utils virtualbox-guest-x11
fi
python3 -m venv /opt/pre-commit
/opt/pre-commit/bin/pip install --disable-pip-version-check pre-commit==4.6.2
ln -sf /opt/pre-commit/bin/pre-commit /usr/local/bin/pre-commit

id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner
for g in sudo admin wheel; do
    if id -nG runner | tr ' ' '\n' | grep -qx "$g"; then
        gpasswd -d runner "$g"
    fi
done
if sudo -l -U runner 2>/dev/null | grep -q "may run the following"; then
    echo "guest-provision: sudoers grants 'runner' something — refusing to bake this image" >&2
    exit 1
fi
# The job runs as `runner`; every other home (the ssh login the host drives
# the VM through) stays unreadable to it.
for h in /home/*; do
    [ "$h" = /home/runner ] || chmod 700 "$h"
done

curl -fsSL -o /tmp/actions-runner.tgz \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
echo "${RUNNER_SHA256}  /tmp/actions-runner.tgz" | sha256sum -c -
rm -rf "$RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
tar -xzf /tmp/actions-runner.tgz -C "$RUNNER_DIR"
rm -f /tmp/actions-runner.tgz
"$RUNNER_DIR/bin/installdependencies.sh"
chown -R runner:runner "$RUNNER_DIR"

install -d -o root -g root -m 0755 /opt/himmel-ci
install -o root -g root -m 0755 "$here/job-started-hook.sh" /opt/himmel-ci/job-started-hook.sh
printf '%s\n' "$repo" > /opt/himmel-ci/repo
chmod 0644 /opt/himmel-ci/repo

cat > /usr/local/sbin/himmel-ci-run-job <<'EOF'
#!/usr/bin/env bash
# One job as `runner`. Arg: max seconds. Stdin: the single-use JIT config,
# handed to the runner through its ACTIONS_RUNNER_INPUT_JITCONFIG environment
# variable (the runner reads every ACTIONS_RUNNER_INPUT_<arg> as that arg), so
# it never sits in a process listing the way an argv does.
# ponytail: the runner only reads this from its environment, so the config stays
# readable at /proc/PID/environ by the same uid (the job); it is single-use and
# expires, so the exposure is the job's own runner; no same-uid-safe channel
# exists, upgrade path HIMMEL-5108 (runner launched under a different uid).
set -eu
max="${1:?max seconds}"
case "$max" in ''|*[!0-9]*|0*) echo "himmel-ci-run-job: bad max '$max'" >&2; exit 2 ;; esac
IFS= read -r jit
[ -n "$jit" ] || { echo "himmel-ci-run-job: empty JIT config on stdin" >&2; exit 2; }
cd /opt/actions-runner
# The hook is set here, not in the runner's .env: a root-owned wrapper the
# job cannot rewrite, and no .env for the guest secret scan to trip on.
export ACTIONS_RUNNER_INPUT_JITCONFIG="$jit"
unset jit
exec timeout --kill-after=30 "$max" runuser -w ACTIONS_RUNNER_INPUT_JITCONFIG -u runner -- env \
    ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/himmel-ci/job-started-hook.sh \
    HIMMEL_CI_RUNNER_REPO="$(cat /opt/himmel-ci/repo)" \
    ./run.sh
EOF
chmod 0755 /usr/local/sbin/himmel-ci-run-job

cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
# HIMMEL-5037: the CI runner guest reaches the internet and the NAT DNS only.
flush ruleset
table inet himmel_egress {
    chain output {
        type filter hook output priority 0; policy accept;
        oifname "lo" accept
        ct state established,related accept
        ip daddr 10.0.2.3 udp dport 53 accept  # leak-allow: private-lan-ip egress filter ranges
        ip daddr 10.0.2.3 tcp dport 53 accept  # leak-allow: private-lan-ip egress filter ranges
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, 224.0.0.0/4 } counter reject  # leak-allow: private-lan-ip egress filter ranges
        ip6 daddr { fc00::/7, fe80::/10, ff00::/8 } counter reject
    }
}
EOF
systemctl enable nftables
systemctl restart nftables

echo "guest-provision: runner ${RUNNER_VERSION} ready for ${repo} (unregistered)"
