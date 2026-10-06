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

**Fail closed.** A config that exists but cannot be parsed, an unknown mode,
`remote` without `vm.remote.ssh`, or an invalid port, ssh target or identity
resolves to `none`, with a note saying why. Nothing ever releases a hold on a
guess.

Check what is in force:

```bash
bash scripts/lib/vm-mode.sh mode     # local | remote | none
bash scripts/lib/vm-mode.sh route    # the route a vm-proof hold takes
bash scripts/himmel-doctor.sh        # C53-vm-mode: the mode, and whether the VM's ssh port answers
```

The doctor probe only opens a TCP connection to the configured port. It never
starts, stops or provisions a VM. `scripts/test-luna-upgrade-skill-vm.py` drives
a local VirtualBox VM, so it SKIPs under `remote` too, until it gains a remote
route.
