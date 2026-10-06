# vm.mode — how "VM proof first" is satisfied

Some steps (a pinned upstream held with `"release": "vm-proof"` in
`scripts/upstreams/pin-holds.json`, the host-driven VM e2e suites) want proof
on a VM before they reach your machine. Whether you have such a VM is your
setting, read by `scripts/lib/vm-mode.sh` from `~/.himmel/config.json`:

```json
{ "vm": { "mode": "remote",
          "remote": { "ssh": "ops@vm.example", "port": 22,
                      "identity": "~/.ssh/id_ed25519" } } }
```

| `vm.mode` | Meaning | A `vm-proof` hold resolves to |
|---|---|---|
| `local` (default: unset, or no config file) | the local test VM, `ssh -p 2222 localhost` ([vms.md](vms.md)) | `local-vm localhost:2222` |
| `remote` | the VM named by `vm.remote.ssh` (`port` defaults to 22, `identity` to `~/.ssh/id_ed25519`) | `remote-vm <host>:<port>` |
| `none` | no VM proof is possible | operator ack plus a rollback point — never auto-released |

Under `none` a VM-proof hold stays HELD until you ack it, after taking a
rollback point (a filesystem snapshot, or a backup of the paths the step
touches, with the restore command written down). The VM e2e suites
(`scripts/test-*-vm.sh`, `scripts/test-luna-upgrade-skill-vm.py`) SKIP with a
`vm.mode=none` reason and exit 3.

`himmel-update` rolls one VM-proof step on its own: the cli-proxy-api host roll
(`sync_cli_proxy`). Under `local` or `remote` it prints the route and rolls.
Under `none` it is HELD and never auto-rolls, in the full update or under
`--only`. To roll it, take the rollback point, then run that one step with the
ack:

```bash
HIMMEL_UPDATE_VM_ACK=<rollback point path> bash scripts/himmel-update.sh --only cli_proxy
```

The path must exist. The full update ignores the ack: it is an operator action,
never an unattended one.

The install wizard (`himmelctl`) asks `vm.mode` (and, for `remote`, the ssh
target, port and identity, checked with the resolver's own rules) right before
the cadences question, whenever a cadence that wants VM proof is offered (today
`vault-stall`). It writes `vm` to `~/.himmel/config.json` only when the answer
changes what the resolver reads. Such a cadence is pre-selected only under
`local` or `remote`. Under `none` it is armed only when you select it yourself
(that selection is the ack), and under a config error it cannot be armed at
all. `--from-profile` never arms it under `none` or an error.

**Fail closed — and an error is not a `none`.** A config path that exists but
is not a readable file (a directory, a dangling symlink), a config that cannot
be parsed (or whose top level or `vm` is not an object), an unknown mode
(including a wrong case such as `"Local"`), `remote` without `vm.remote.ssh`, or
an invalid port, ssh target or identity (whitespace or a leading `-`, checked
after `~` expands) is a **config error**. Every VM-proof hold stays HELD, like
`none`, but an error never offers the operator-ack route: its only route is
"fix the config".

| | configured `none` | config error |
|---|---|---|
| `vm-mode.sh route` | `operator-ack+rollback-point`, exit 1 | `fix-config: <why> -- ...`, exit 2 |
| `vm-mode.sh mode` / `target` | `none` exit 0 / exit 1 | `none` on stdout, exit 2 / exit 2 |
| a `vm-proof` pin hold | HELD, operator ack + rollback point | HELD, fix the config |
| `himmel-update` cli-proxy roll | HELD (exit 0); rolls only with `--only` + the ack | HELD, exit 1; the ack is ignored |
| VM e2e suites | SKIP, exit 3 | CONFIG ERROR, exit 2 (never a SKIP) |

Nothing ever releases a hold on a guess.

Check what is in force:

```bash
bash scripts/lib/vm-mode.sh mode     # local | remote | none (exit 2 on a config error)
bash scripts/lib/vm-mode.sh route    # the route a vm-proof hold takes (exit 1 none, 2 error)
bash scripts/himmel-doctor.sh        # C53-vm-mode: the mode, and whether the VM's ssh port answers
```

The doctor probe only opens a TCP connection to the configured port. It never
starts, stops or provisions a VM. `scripts/test-luna-upgrade-skill-vm.py` drives
a local VirtualBox VM, so it stays local-only: it SKIPs under `remote`, naming
that gap, until it gains a remote route.
