# New Machine Setup

Complete checklist for getting a new machine to full working state.

**Adopting himmel on your own repo** (not developing himmel itself)? See [docs/setup/use-on-your-project.md](./use-on-your-project.md) instead — it covers the portable-core flow and tells you which sections here apply to you.

**Setting up a clean Windows machine remotely (over SSH), including the delegation-lane fleet (hermes/codex/…)?** Follow [windows-clean-machine.md](./windows-clean-machine.md) — the ordered walkthrough through this doc plus the remote-drive pattern, lane installs, and always-on hardening (HIMMEL-852).

---

## 1. Required environment (HIMMEL-123)

`scripts/setup.sh` and `scripts/setup.ps1` verify these at step 0 and fail fast with install hints. Run `bash scripts/setup.sh` (or `scripts/setup.ps1`) and the script tells you exactly what's missing.

### Foundational (every platform — verified at setup)

| Tool | Min version | Why |
|---|---|---|
| `bash` | 3.2 (most scripts) · 4.0 (8 scripts use `mapfile`) | macOS ships bash 3.2 — `brew install bash` if you hit `mapfile: command not found` from the 8 bash-4 scripts listed below |
| `git` | 2.30+ | Worktrees + `--show-toplevel` |
| `node` | 18+ to build · **20.17+ to push** | Jira plugin build + plugin-install workflow. The pre-push signature gate needs npm 11, whose own engine floor is `^20.17.0 \|\| >=22.9.0`, so a node-18 box can build and commit but cannot push. |
| `npm` | 11+ (needs node `^20.17.0 \|\| >=22.9.0`) | Lockfile audit hooks + plugin install. NOT bundled on Debian/Ubuntu, and apt's own `npm` is 9.2 — old enough that its expired registry key fails `npm audit signatures` on every push. See the Linux table. |
| `bun` | 1.0+ | Runs the handover armed-resume resolver, the qmd search index, the Telegram bridge, and the obsidian-triage tools. Install: `curl -fsSL https://bun.sh/install \| bash` (Linux/macOS) or `irm bun.sh/install.ps1 \| iex` (Windows) |
| `python3` | 3.10+ | `realpath -m` fallback (macOS) + JSON helpers in 28 scripts. PEP 668 (Ubuntu 24.04+) blocks system pip — use `uv` or `pipx` for pre-commit. |
| `jq` | 1.6+ | Hook input parsing (13 scripts incl. all Claude PreToolUse hooks) |
| `gh` | 2.x | Issue + PR + CR workflows (12 scripts) |
| `mktemp` | BSD or GNU (both fine) | 19 scripts |
| `pre-commit` | 3.5+ | Pre-commit framework |
| `claude` (CLI) | latest | Native installer: `curl -fsSL https://claude.ai/install.sh \| bash` (Linux/macOS) or `irm https://claude.ai/install.ps1 \| iex` (Windows) |

### Per-platform additions

**Linux (Ubuntu / Debian / Arch / Fedora):**

| Tool | How |
|---|---|
| `at` + `atd` running | `sudo apt install at && sudo systemctl enable --now atd` (or distro equivalent). Required by `scripts/handover/arm-resume.sh` for cron-armed Claude relaunches. |
| `realpath -m` (coreutils) | Default on most distros. |
| `shellcheck`, `gitleaks` | `sudo apt-get install -y shellcheck gitleaks`. Both are real apt packages on Ubuntu (verified 26.04: ShellCheck 0.11.0, gitleaks 8.16.0) — the tarball is only needed on distros that do not package gitleaks. Used by pre-commit. |
| `gh` | `sudo apt-get install -y gh` on Ubuntu >= 24.04 / Debian >= 13 — `gh` is a real apt package there. `himmelctl deps ensure` / `setup.sh`'s `[0/9]` preflight asks whichever package manager is present (apt-get/dnf/brew) whether it has a candidate for `gh`, and installs it automatically when the answer is yes (HIMMEL-2548) — not just on apt. When the selected manager has no candidate, the manual routes are the fallback: GitHub's official apt repo (https://cli.github.com/packages) or the release tarball (https://github.com/cli/cli/releases). |
| `uv` OR `pipx` | `curl -LsSf https://astral.sh/uv/install.sh \| sh` (recommended). PEP 668 blocks system pip. |
| `npm` | **Not bundled.** Debian/Ubuntu's `nodejs` package ships without npm, so a box with a working `node` can still fail the install preflight (`ERROR: missing required tools: npm`). `sudo apt-get install -y npm`, or install Node + npm together from [NodeSource](https://github.com/nodesource/distributions). **And apt's npm is too old to push with** — 9.2.0's bundled registry key expired 2025-01-29, so the pre-push `npm audit signatures` gate refuses every push with `EEXPIREDSIGNATUREKEY`. Follow up with `sudo npm install -g npm@11` (npm 12 requires node ^22.22.2; apt ships 22.22.1). |
| `sudo` | The toolchain steps that use `apt-get` need root. `himmelctl deps ensure` does **not** elevate — run the apt lines yourself (see the clean-install walkthrough below). |

**macOS:**

| Tool | How |
|---|---|
| `bash` 4+ | `brew install bash` — system bash is 3.2 and 8 scripts need 4+. Add `/usr/local/bin/bash` (Intel) or `/opt/homebrew/bin/bash` (Apple Silicon) to PATH or use `#!/usr/bin/env bash` (already the convention). |
| `at` daemon | Preinstalled but disabled. Enable: `sudo launchctl load -F /System/Library/LaunchDaemons/com.apple.atrun.plist`. |
| `realpath -m` (optional) | Macos has no `realpath -m`; the 5 scripts that use it (`arm-resume.sh`, `auto-commit.sh`, `block-edit-on-main.sh`, `check-hookspath.sh`) already include a `python3 -c "from pathlib import Path; print(Path(p).resolve(strict=False))"` fallback. Pure-GNU operators: `brew install coreutils && export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"` exposes `grealpath` as plain `realpath`. |
| `uv` OR `pipx` | `brew install uv` (or pipx). |

**Windows (Git Bash via Git for Windows):**

| Tool | How |
|---|---|
| Git Bash 2.40+ | https://git-scm.com — includes bash 4.4+, `realpath -m`, `mktemp`, `cygpath`. |
| `schtasks` | Built-in. Used by `scripts/handover/arm-resume.sh` for cron-armed Claude relaunches. **Always invoke under `MSYS_NO_PATHCONV=1`** (per HIMMEL-125) to prevent Git Bash from mangling `/flag` args into Windows paths. |
| `MSYS_NO_PATHCONV` awareness | Documented in CLAUDE.md handover section. |
| WSL2 / Docker resource caps | If WSL or Docker Desktop is installed, cap them before multi-agent runs. Start with `%UserProfile%\.wslconfig` `memory=16GB`, `processors=8`, `swap=4GB` on a 48 GB / 32-logical-core class host, then tune after measuring. Docker gets separate Desktop/per-container caps. See [environment gotchas](../internals/environment-gotchas.md#windows-wsl--docker-resource-budget). |

PowerShell-only is **NOT sufficient** — most operator-facing tooling needs bash. WSL as a *shell swap* under Windows-native Claude Code is not possible either (see the WSL station profile subsection below); native Git Bash is the tested path.

#### WSL on Windows — two readings, only one of them real (HIMMEL-939)

"Use WSL instead of Git Bash" means two very different setups. The HIMMEL-939
ADR evaluated both (a second Windows station, 2026-07-12):

- **Shell swap (impossible, not just unsupported).** Keeping Claude Code on
  native Windows and pointing its shell at WSL bash does not work, structurally:
  the Bash tool binds Git Bash only (`CLAUDE_CODE_GIT_BASH_PATH` accepts a Git
  Bash, not WSL); Windows `git.exe` runs commit/push gates under its bundled
  MSYS bash regardless of the session shell; and WSL git cannot read
  Windows-created worktrees (the `.git` pointer file carries a `C:/` absolute
  path). There is no setting that makes this configuration exist.
- **WSL station profile (supported).** Claude Code installed *inside* a WSL
  distro — repo clones on ext4 (never `/mnt/c`, see the
  [/mnt/c performance cliff](../internals/environment-gotchas.md#wsl-the-mntc-performance-cliff)),
  toolchain (node/jq/gh/bun/…) provisioned in-distro — is a supported,
  documented Anthropic configuration. Effectively a Linux station that happens
  to run on a Windows host; the Linux column of this doc applies. Windows-side
  control-plane pieces (schtasks arming) remain reachable via interop
  (`schtasks.exe` callable from WSL, ~70 ms overhead).
  **Provisioning gate hooks (HIMMEL-966):** in the in-distro himmel clone,
  run `bash scripts/setup.sh` (it installs all three hook types), or if
  installing manually, ALL THREE:
  `pre-commit install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push`.
  A bare `pre-commit install` installs only the pre-commit hook type — the
  commit-msg + pre-push gates (attestation trailers, CR-marker write,
  conventional-commit lint) are then silently absent and the first push
  goes out ungated (the HIMMEL-955 workday hit exactly this).

**Git Bash remains the tested default** for Windows stations until the
HIMMEL-955 WSL-station pilot reaches an ADOPT verdict. If you run WSL from Git
Bash meanwhile, read the three measured WSL traps in
[environment gotchas](../internals/environment-gotchas.md#wsl-wslexe-invoked-from-git-bash-mangles-mnt-args).

#### WSL station — auxiliary post-install items (HIMMEL-977)

Installing the CLI fleet in-distro (`claude`, `codex`, `hermes`, `copilot`,
`grok`, `coderabbit`) leaves a set of one-time auxiliary steps that the plain
installers do NOT cover. Calibrated on two stations, 2026-07-12:

| Item | Step | Notes |
|---|---|---|
| hermes home | `export HERMES_HOME=$HOME/.hermes` for `scripts/hermes/invoke.sh` calls | Newer hermes installs use `~/.hermes`; the chokepoint's resolver does not probe it yet (fix tracked on HIMMEL-977). |
| hermes profile | `bash scripts/hermes/install-himmel-profile.sh` (with `HERMES_HOME` set), then `hermes profile use himmel_agent` | Installs the senior-reviewer profile + parity_guard hook. |
| hermes hooks | Approve the parity_guard hook once in a live hermes session | Hook approval is interactive; one-shots inherit it afterward. |
| hermes channels | Keep chat channels (telegram etc.) `enabled: false` on stations | ONE poller per bot token, fleet-wide — the host's always-on bridge owns the channel. A station gateway that polls the same token 409-conflicts it. |
| provider auth | Merge/verify the providers your lanes need in `~/.hermes/auth.json` (e.g. the `openai-codex` provider for gpt-5.x one-shots) | A fresh in-distro login may create fewer providers than your primary machine has. |
| codex | `codex login` (ChatGPT OAuth), then `codex login status` | Sandbox-shell posture on Windows hosts: HIMMEL-975. |
| copilot | First run is interactive: login + approve the repo as a trusted folder | Config files alone (`config.json`/`settings.json`) are not sufficient. |
| grok | `grok login` (browser OAuth) per machine | A non-authed station hangs at "Waiting for authorization…" on one-shots. |
| coderabbit | `curl -fsSL https://cli.coderabbit.ai/install.sh \| sh` + `coderabbit auth login` | Absent CLI = the CR lane fails open (review skipped, loudly). |
| jq | `sudo apt install -y jq` (Debian/Ubuntu; use your distro's package manager elsewhere) | Required by most himmel hooks; not preinstalled on minimal distros. |
| claude settings | Ensure in-distro `~/.claude/settings.json` hooks use in-distro paths | Copied Windows settings carry `C:\` hook paths that fail every SessionEnd (noise, not fatal). |
| pre-commit hooks (non-himmel clones) | `pre-commit install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push` in any OTHER repo clone on the station | A bare `pre-commit install` leaves commit-msg + pre-push gates silently absent. The himmel checkout itself no longer needs this: `himmelctl install`/`scripts/setup.sh` place all three hook types by default (HIMMEL-2441, closing HIMMEL-966). |
| GLM wrapper | The `~/.claude-glm` config dir does not follow the fleet install — provision per machine if the GLM lane is used there | Provider API keys (GLM / DashScope / OpenRouter / NVIDIA) travel with the hermes `.env`; the wrapper dir does not. |

### Linux clean install, end to end (verified on Ubuntu 26.04, 2026-09-02)

Walked end to end on an Ubuntu 26.04 guest, 2026-09-02. Every failure, message
and workaround quoted below is reproduced verbatim from that run; where himmel's
own tooling could not do a step, it is called out rather than smoothed over, and
the workaround is the documented path until the linked ticket lands.

Two honest caveats about the walkthrough itself. The guest was not pristine — it
carried a `~/.claude` and an older himmel checkout from earlier test runs, which
is why the hook-rewiring behaviour below could be observed at all. And steps 1-3
are the standard documented installs for tools that box already had (uv,
pre-commit, bun, the claude CLI): they are listed so the sequence is complete,
but the commands exercised on this run were steps 0, 0b and 4 onward. Everything
after step 4 was executed exactly as written.

```bash
# 0. Prerequisites apt owns. node alone is NOT enough: Ubuntu's nodejs
#    package has no npm, and the install preflight hard-fails without it.
sudo apt-get update
sudo apt-get install -y nodejs npm git jq gh shellcheck gitleaks at
sudo systemctl enable --now atd          # arm-resume's scheduler backend

# 0b. npm 11+. Ubuntu's apt npm is 9.2.0, whose bundled registry key EXPIRED
#     2025-01-29 — the pre-push `npm audit signatures` gate then refuses every
#     push with EEXPIREDSIGNATUREKEY. Pin 11 rather than latest: npm 12 wants
#     node ^22.22.2 and apt ships 22.22.1, one patch short.
sudo npm install -g npm@11

# 1. uv (PEP 668 blocks system pip on 24.04+), then pre-commit through it.
curl -LsSf https://astral.sh/uv/install.sh | sh
uv tool install pre-commit

# 2. bun — the official installer, which writes ~/.bun/bin.
curl -fsSL https://bun.sh/install | bash

# 3. The claude CLI, if you do not already have it.
curl -fsSL https://claude.ai/install.sh | bash

# 4. Clone, then run the installer FROM INSIDE the clone. `himmelctl` is not
#    on PATH yet — the launcher is written to ~/.local/bin BY the install —
#    so the first invocation is necessarily clone-relative.
mkdir -p ~/Documents/github && cd ~/Documents/github
git clone https://github.com/yotamleo/himmel.git
cd himmel
node scripts/himmelctl/bin.js install --dry-run | tee dryrun.txt   # the plan
node scripts/himmelctl/bin.js install                             # the real thing
```

(`--dry-run` is teed to a file because the headless workaround below needs the
profile JSON it prints; on a box with a terminal you can drop the `tee`.)

**Two rough edges you will hit on this path today.** Both are filed; both have
a workaround that completes the install.

1. **Run the install in user scope when the adopted project is the himmel
   clone itself** ([HIMMEL-2435](https://yotamleo.atlassian.net/browse/HIMMEL-2435)).
   The default derivation picks project scope with the target set to the
   current directory, and the portable-core copy then tries to copy the
   checkout's files onto themselves:

   ```text
   cp: '.../scripts/hooks/auto-approve-safe-bash.sh' and '.../scripts/hooks/auto-approve-safe-bash.sh' are the same file
   ```

   Answer `user` at the scope question (or pass a profile with
   `"scope": "user"`). User scope skips the portable-core copy entirely and the
   install then completes: plugins, marketplaces, the Jira CLI build, the
   statusline, the launcher, and the hook wiring in `~/.claude/settings.json`.

2. **A headless / SSH-only box needs `--from-profile`, and that path does not
   save the profile** ([HIMMEL-2436](https://yotamleo.atlassian.net/browse/HIMMEL-2436)).
   With no TTY the real install refuses (`non-interactive install requires
   --from-profile <path>`), while `--dry-run` prints a complete profile it does
   not save. Capture the printed JSON block, install from it, then seed the
   cache by hand so `himmelctl status` and `ensure` work afterwards:

   ```bash
   sed -n '/^{$/,/^}$/p' dryrun.txt > profile.json     # the block --dry-run printed
   sed -i 's/"scope": "project"/"scope": "user"/' profile.json
   node scripts/himmelctl/bin.js install --from-profile profile.json
   mkdir -p ~/.claude/himmel && cp profile.json ~/.claude/himmel/install-profile.json
   ```

   On a box with a terminal, answer the questions interactively instead and
   neither step is needed — the interactive path writes the cache itself.

**`himmelctl deps ensure` does not finish the job on Linux**
([HIMMEL-2438](https://yotamleo.atlassian.net/browse/HIMMEL-2438)). On a stock
Ubuntu box it reports `0 installed, 4 failed`: its `apt-get` calls run
unprivileged, gitleaks has no automated recipe, and bun/qmd are not re-resolved
on PATH within the same pass. Install those four from step 0 and step 2 above
and `himmelctl status` goes green on them.

**Expect reds you did not cause.** A lean adopter's first `himmelctl status`
lists rows for opt-in capabilities that were never selected — `hermes-checkout`
in particular reports a Windows `AppData` path on Linux
([HIMMEL-2437](https://yotamleo.atlassian.net/browse/HIMMEL-2437)). Reds for
`graphify`, `rtk`, `jira-env-keys`, and `telegram-bridge` simply mean those
optional pieces are not set up; none of them blocks the core loop.

**The git gates are a separate, manual step — the install does not place
them.** `himmelctl install` wires the Claude-session hooks into
`~/.claude/settings.json` and prints the pre-commit gates as "(optional)". Until
you run

```bash
pre-commit install --install-hooks \
  --hook-type pre-commit --hook-type commit-msg --hook-type pre-push
```

`.git/hooks/` holds nothing but samples and **every commit is ungated** — a
docs commit with no ticket reference and no attestation trailers will succeed
silently. Verified on the guest: the first commit of this very PR was made
before the hooks existed and no gate ran. (This is the same manual step the
"Provisioning gaps" table above lists under *pre-commit hooks* with its
HIMMEL-966 note — spelled out here because on a fresh adopter box it is the
difference between having the git gates and only believing you do. `--hook-type`
without `--install-hooks` places the hooks but leaves their environments to be
built on first use; `scripts/setup.sh` does the whole thing for you inside a
himmel clone.)

**Placement is still changing.** The operator has approved making the installer
place these hooks by default ([HIMMEL-2441](https://yotamleo.atlassian.net/browse/HIMMEL-2441));
until that lands you place them yourself with the command above. Ticket
discipline itself is already default-on
([HIMMEL-2442](https://yotamleo.atlassian.net/browse/HIMMEL-2442)).

Two things to know once they are placed:

- **Ticket discipline is on by default.** The commit-msg gate enforces
  conventional-commit *shape* always, and a ticket reference unless you opt
  out. The pattern comes from `TICKET_ID_PATTERN` if set, else
  `JIRA_PROJECT_KEY` (`PROJECT-123`), else himmel's own `#N` enumeration
  (`#123`) — that enumeration *is* the ticket system for a repo without Jira,
  not a relaxed fallback, and `/handover new-epic` / `/handover new-task`
  allocate the next free number for you. To turn the ticket half off entirely,
  set `TICKET_ID_REQUIRED=0` in the repo's `.env` or the environment; the
  conventional-shape check stays on either way.
- **The lockfile gate finds `bun` for itself now
  ([HIMMEL-2439](https://yotamleo.atlassian.net/browse/HIMMEL-2439)).** It used
  to depend on who ran `git commit`: a hook inherits the environment of the
  invoking git process rather than building a fresh PATH, so a commit from your
  own terminal worked (that shell sourced `~/.bashrc`, where bun's installer put
  `~/.bun/bin`) while the same commit from an SSH command, a script, CI or an
  agent died with `ERROR: bun did not report a version` — on any commit,
  docs-only included. The gate now looks in `PATH`, `$BUN_INSTALL/bin` and
  `$HOME/.bun/bin` in turn, and when it still finds no bun it refuses only the
  commits that stage something under the bun package; a docs commit is skipped
  with a line naming everywhere it looked. Nothing to do on a normal install.

  The symlink below is still worth making — it fixes the same blind spot for
  every *other* non-interactive consumer (cadences, scheduled runs, `himmelctl
  deps ensure`), since `~/.local/bin` is exported by `~/.profile`, which has no
  interactive-only early return — though that only helps a launching chain
  that sources `~/.profile` in the first place (a login shell), not a bare
  `ssh host 'cmd'` or a cron job with neither PATH layer; see
  [the two PATH layers](../internals/environment-gotchas.md#linux-a-stock-ubuntu-user-has-two-path-layers-and-non-interactive-shells-see-only-one):

  ```bash
  ln -sf ~/.bun/bin/bun ~/.local/bin/bun
  ```

**Your first push will take a few rounds, and each refusal is real.** On the
guest it took three attempts, in this order:

1. `npm audit signatures` refused because apt's npm is 9.2 (step 0b above);
   fixed by `sudo npm install -g npm@11`. The gate checks `npm --version` before
   the signature check and says so in as many words
   ([HIMMEL-2440](https://yotamleo.atlassian.net/browse/HIMMEL-2440)); on an npm
   predating that fix you get the raw `EEXPIREDSIGNATUREKEY` per package
   instead, which is the same problem wearing a supply-chain costume.
2. It refused again for `scripts/jira` only: "found no dependencies to audit
   that were installed from a supported registry", because the worktree
   bootstrap had populated `node_modules` without registry provenance. `npm ci`
   in `scripts/jira` fixes it — that is exactly the remediation the gate names.
3. The CR gate refused once to install its own ref-stream hook
   (`pre-push.legacy`) and told you to retry; the retry passes.

Then it goes through. The attestation gates ("Cross-platform attestation",
"Security-review attestation") pass first-try as long as the trailers are in
the FIRST commit — do not try to add them with `git commit --amend` after a
refusal.

**`clean-garden.sh` leaves the new worktree dirty.** It installs the Jira CLI
dependencies, which rewrites `scripts/jira/package-lock.json`. Revert that file
rather than committing it: `git checkout -- scripts/jira/package-lock.json`.

**PATH: `~/.bun/bin` will look missing even when bun works.** See
[the two PATH layers](../internals/environment-gotchas.md#linux-a-stock-ubuntu-user-has-two-path-layers-and-non-interactive-shells-see-only-one)
— this is why a probe can report `bun` (or `claude`) missing on a machine where
both are installed and working.

### Linux station (CachyOS, first fleet day 2026-09-04)

Distinct from the Ubuntu walkthrough above: these surfaced running himmel as
the daily driver on an Arch-family main station, not from a fresh install.

**Lean plugin floor + local override.** See [Lean profile](#lean-profile--disabled-by-default-enable-on-need-himmel-816)
above for how `settings.local.json` overrides the floor in both directions.
The lesson on this box: toggling a plugin off with `claude plugin disable`
alone does not survive the next reconcile if its key is still `true` in
`settings.local.json` — flip the override, not just the live toggle.

**`/plugins` → "enabled in project settings but isn't installed."** A
migrated `~/.claude/settings.json` can carry `false` keys for plugins never
installed on *this* machine — `reconcile-enabled-plugins.sh`'s whitelist
logic carries any unknown live key forward as `false` rather than deleting
it, so a dead entry survives every reconcile untouched. That's an
`enabledPlugins` cleanup, not an install problem:
`f=~/.claude/settings.json; t=$(mktemp "$f.XXXXXX") && jq 'del(.enabledPlugins["<name>"])' "$f" > "$t" && mv "$t" "$f"`
(a `mktemp` beside the target, never a predictable cwd-relative name).

**Toggling a community plugin.** `claude plugin enable/disable <name>` is the
sanctioned toggle. `himmelctl config set hooks.plugin.<name>` only knows the
fixed table in `scripts/machine-setup/full-plugin-enable.json` (the
lean-profile re-enable list above) — it rejects any other plugin name, so
reach for `claude plugin` directly for anything outside that list. That
toggle alone doesn't survive the next reconcile, though (see
[Lean profile](#lean-profile--disabled-by-default-enable-on-need-himmel-816)
above): `claude plugin enable <name>` also needs `"<name>": true` under
`enabledPlugins` in `~/.claude/settings.local.json`, or the next reconcile
drops it back to the floor; `claude plugin disable <name>` mirrors this with
`false` there, or the next reconcile brings it back.

**arm-resume on Linux.** Needs `at` + a running `atd` — on Arch/CachyOS:
`sudo pacman -S at && sudo systemctl enable --now atd`; `cronie` is the
weaker fallback when `at` is absent (see
[§4c](#4c-scheduler-backend-auto-arm-resume-himmel-594) above). The POSIX
launcher in `scripts/handover/arm-resume.sh`'s `schedule_arm` submits an
`at -t <timestamp>` heredoc job whose body is a plain `claude ... --model
...` invocation — no controlling terminal, nothing opens a window.
`--dry-run` is side-effect-free (it prints the exact job body and "dry-run
complete (no changes made)" without touching the `at` queue) and is the safe
way to see what an arm will actually run. Because the fired session has no
TTY/stdin, any permission-gated action it hits resolves as a silent DENY at
rc=0 after a ~3s stdin watchdog rather than hanging — pass `--automerge` if
the arm must push a chain through green PRs unattended (it sets
`ARMAUTOMERGE=1` + `CR_MERGE_GATE_OK=1` on the launched session); without it
the script only WARNs and the chain stops at the first green PR. `.env`'s
`ARMAUTOMERGE` is only the **default** used when `--automerge` was not passed
on this invocation — an explicit flag always wins over it.

**Jira CLI.** Never a `JIRA_PROJECT_KEY=` env-assignment prefix on the
invocation (`JIRA_PROJECT_KEY=… node …/index.js …`) —
`block-jira-compound-write.sh` refuses that command *shape*, not Jira writes
themselves. The sanctioned invocation is the plain `node
<repo-root>/scripts/jira/dist/index.js <op>`, which picks the key up from the
primary checkout's `.env` (see
[Required `.env` values](#required-env-values-per-variable-walkthrough)
above); pass `--project` only for cross-project work.

**Station traps, one line each.** Arch ships `/usr/bin/pre-commit` and
co-locates `node` with coreutils in `/usr/bin` — a hermetic-PATH test fixture
that pins `PATH=/usr/bin:/bin` or scrubs the PATH must **stub** these tools
out, not assume scrubbing `/usr/bin` removes only what the suite intends (it
also silently drops `xargs`). Scripts tracked from Windows commits land mode
100644 (no `+x`) and fail direct invocation with rc=126 on Linux; a
`check-shebang-scripts-are-executable` pre-commit hook now guards new commits
from reintroducing this. `run-shell-tests.sh`'s machine lock leaking
`SUITE_LOCK_WAIT` into `test-suite-concurrency.sh` (a queued after-report
inheriting an unrelated wait budget instead of the suite's own) is fixed.

### Scripts requiring bash 4+

These will error `mapfile: command not found` on macOS system bash (3.2). Either install `bash` 4+ via `brew install bash`, or convert the `mapfile` use to a `while IFS= read` loop (cheap port if needed):

- `scripts/luna/sweep-himmel.sh`
- `scripts/hooks/check-no-headless-claude.sh`
- `scripts/hooks/check-mcp-plugin-refs.sh`
- `scripts/hooks/check-lockfile-integrity.sh`
- `scripts/hooks/check-npm-audit.sh`
- `scripts/hooks/check-npm-audit-signatures.sh`
- `scripts/hooks/check-npm-licenses.sh`
- `scripts/hooks/check-uv-lock.sh`

Every other script is bash 3.2-compatible.

### Single-source tool dependencies

These tools show up in only one script — easy to drop if not on PATH (the affected feature degrades):

- `cygpath` (Windows-only path translation) → `scripts/handover/arm-resume.sh` and `scripts/lib/qmd-bin.sh` (junction creation, HIMMEL-877); falls back to the unconverted path when absent.
- `shellcheck`, `gitleaks` → `scripts/machine-setup/ubuntu.sh` bootstrap only; pre-commit framework re-fetches them per-hook so they don't need to be on PATH for normal use.
- `pipx` → fallback in `setup.sh` + `ubuntu.sh` only (uv is primary).
- `qmd` → `setup.sh` step 4 only (collection register); optional if you don't use qmd search.

### Other tools

- **Obsidian** — https://obsidian.md (for luna vault).
- **Claude Code CLI** — see foundational table above.

### Required `.env` values (per-variable walkthrough)

`scripts/setup.sh` / `setup.ps1` copy `.env.example` → `.env` for you (§4); you
then fill in your own values. Run setup with `--fill-env` (PowerShell:
`-FillEnv`) to be **prompted** for each one — the prompt prints a short help
blurb (what the value is + where to get it, sourced from the `.env.example`
comments) before each field, so you don't have to read the file first. Press
Enter at a prompt to keep the current value; non-interactive shells skip the
prompt entirely.

Two kinds of variable live in `.env` and they reach code **differently** — this
is the classic "I set it in `.env` but nothing happened" tax. The same split is
documented at the top of [`.env.example`](../../.env.example):

- **TOOL-LOADED** — a himmel CLI reads `.env` itself, so a value sitting in the
  file is enough; no shell export needed.
- **PROCESS-ENV** — hooks, shell scripts, and skill tools read the **live**
  environment, not the file. Export these in the shell that launches `claude`,
  or set them in `~/.claude/settings.json` `"env": {}`. A value sitting only in
  `.env` is not seen — **except** the ones bridged from `.env` by
  `scripts/lib/load-dotenv.sh` (`HANDOVER_DIR`, `USER_SLUG`, `CR_PROFILE`, the
  `HIMMEL_INITIATIVE*` set, `HIMMEL_WHERE_ARE_WE` + `_STALE_HOURS` — but NOT
  the statusline-only `_ROLLUP_TTL` / `_SEG_TIMEOUT` knobs, which are live-env
  only — `HIMMEL_DOC_FRESHNESS` and the nudge flags; the full bridged list
  lives in the `.env.example` header), noted
  below. A third class, **SESSION-ONLY** (guardrail bypasses like
  `EDIT_ON_MAIN_OK`, per-launch opt-ins like `TELEGRAM_OWN_POLLER`), is never
  read from `.env` at all — set in the launching shell; inventoried in
  `.env.example`'s SESSION-ONLY section.

**TOOL-LOADED** (a value in `.env` is enough):

| Variable | What it is | Where to get it |
|---|---|---|
| `USER_SLUG` | Operator slug — names handover bucket paths + `registry.json`. Falls back to your git `user.name` slugified if unset. Also bridged into the live env. | Pick a short kebab-case handle. |
| `JIRA_BASE_URL` | Your Atlassian site URL. | `https://<your-site>.atlassian.net` |
| `JIRA_EMAIL` | Atlassian account email. | The address you sign into Jira with. |
| `JIRA_API_TOKEN` | Jira / Confluence CLI auth token. | id.atlassian.com/manage-profile/security/api-tokens |
| `JIRA_PROJECT_KEY` | Default project for `jira` ops. | Your Jira project key (e.g. `ACME`). |
| `JIRA_CLOUD_ID` | Atlassian tenant cloud id (REST / MCP). | Atlassian admin console, or the `getAccessibleAtlassianResources` API. |
| `ZAI_API_KEY` | Z.ai GLM key for the `claude-glm` overflow launcher (see [tooling-catalog](../tooling-catalog.md#claude-glm-scriptsclaude-glm-ps1-twin-himmel-665)). The launcher takes the live process env first, else reads it from `.env`. It cannot distinguish shell env from `settings.json`-injected env — **don't put this key in `settings.json`** (that hands it to every session); use per-launch shell env or `.env`. | z.ai account → API keys. Optional — only if you use `claude-glm`. |

**PROCESS-ENV** (export, or set in `settings.json` `"env"` — a value only in
`.env` is not read unless it's a bridged exception):

| Variable | What it is | Where to get it / note |
|---|---|---|
| `HIMMEL_REPO` | Path to your himmel checkout. | **Auto-set** by setup/adopt into `settings.json`; set explicitly only for a non-default clone path. |
| `HANDOVER_DIR` | Handover state root (Mode B — external state repo). | Run `/handover-setup`. Bridged from `.env`. Unset = inline `<repo>/handovers/`. |
| `LUNA_VAULT_PATH` | Luna vault root for end-session capture. | Your Obsidian vault path. **Not** bridged — export it. Unset → `~/Documents/luna`. |
| `CLAUDE_LANE_AUTO_RESEED` | Optional opt-out for the lane launchers' config auto-refresh (HIMMEL-819). By default `claude-glm`/`claude-routed` re-seed their isolated config dir when your `~/.claude` settings or plugin registry changed, so lane workers pick up plugin-profile changes automatically. Set `0` to restore the once-only seed (first launch + explicit `--reseed`) if the auto-refresh ever blocks a launch in your setup. | Leave unset (default on). **Not** bridged from `.env` — set it in the launching shell. Only relevant if you use the offload lanes. |
| `HIMMEL_INITIATIVE` | Drive-to-ship legs (opt-in, default OFF). | Uncomment one line in `.env` (leg grammar documented inline in `.env.example`); read from `.env` by the SessionStart hook. |
| `PERPLEXITY_API_KEY` | Perplexity Sonar — `/research`, `/research-deep`. **Provisional — pending operator sign-off** (2026-07-29, no active subscription — see `docs/tooling-catalog.md`). | Perplexity API settings. Optional (blank = feature off). |
| `XAI_API_KEY` | xAI Grok — `/x-read`, `/x-pulse`, `/youtube`. **Provisional — pending operator sign-off** (2026-07-29, no active subscription — see `docs/tooling-catalog.md`). | xAI API console. Optional. |
| `GEMINI_API_KEY` | Gemini — `scripts/gemini/invoke.sh`. | Google AI Studio API key. Optional. |

### OLLAMA_NO_CLOUD (optional — ollama zero-egress defense-in-depth pin)

Not a himmel `.env` variable — the `ollama` binary itself reads it, so it must
be set at OS/user scope (not just exported in the shell that launches
`claude`) to reach a background `ollama` service. The primary zero-egress
guarantee for the `ollama-local` lane (see `/lanes`) is structural and holds
without this: bare model names never reach cloud, cloud is opt-in only via
the `-cloud` suffix. `OLLAMA_NO_CLOUD=1` is an additional belt-and-suspenders
pin, checked (advisory, never a hard fail) by `/himmel-doctor`.

| OS | Set command |
|---|---|
| Windows | `setx OLLAMA_NO_CLOUD 1` (new shells only — restart your terminal/Claude Code session after) |
| macOS | `launchctl setenv OLLAMA_NO_CLOUD 1` (current login session) — also add `export OLLAMA_NO_CLOUD=1` to your shell profile so it survives reboots |
| Linux | Add `export OLLAMA_NO_CLOUD=1` to your shell profile, or if `ollama` runs as a systemd user service, a drop-in: `systemctl --user edit ollama.service` → `Environment=OLLAMA_NO_CLOUD=1` |

For the full inventory — optional Bitbucket, Confluence, VM, and hermes keys,
the CR / `pr-check` critic profile (`CR_PROFILE`), handover/overnight tuning,
Telegram bridge flags, and the SESSION-ONLY guardrail-bypass list — read the
annotated [`.env.example`](../../.env.example); it is the single source of
truth (the complete operator flag map, HIMMEL-787) and every entry there
carries its own inline guidance.

---

---

## 2. Global Claude Config

These files live at `~/.claude/` and must be copied on every new machine.

```bash
# Create dir if missing
mkdir -p ~/.claude

# Copy from this repo
cp docs/setup/global-claude-md.md ~/.claude/CLAUDE.md
cp docs/setup/rtk-md.md ~/.claude/RTK.md
```

Source of truth: [`docs/setup/global-claude-md.md`](global-claude-md.md) and [`docs/setup/rtk-md.md`](rtk-md.md).

> `CLAUDE.md` uses `@RTK.md` — both files must be present in `~/.claude/`.

### Two variants of the working principles, activated by profile

The general engineering defaults (think before coding / simplicity first /
surgical changes / goal-driven execution) are **not** in himmel's project
`CLAUDE.md` — that file is held to a byte budget and carries himmel invariants
only (HIMMEL-2038, gate `scripts/ci/check-claude-md-budget.sh`). They ship at
**user scope** instead, in one of two ways:

| Variant | Who gets it | How |
|---|---|---|
| **Operator** | this machine and any other operator station | the manual `cp` above — `global-claude-md.md` is the full personal file, including `@RTK.md` |
| **Adopter** | any `bash scripts/adopt.sh --profile core` run (or `adopt.ps1`), **either scope** | `wire_user_claude_md` appends the fenced block from [`user-scope-claude-md-template.md`](user-scope-claude-md-template.md) to **both** `~/.claude/CLAUDE.md` (Claude Code) and `~/.codex/AGENTS.md` (Codex), creating each file if absent |

The adopter path is idempotent and never destructive: it skips when the
`HIMMEL:working-principles` marker is already present, appends (never
overwrites) when it is not, and also skips on a heuristic phrase match so a
hand-written target that already states the principles is left alone. It runs
against **both** targets, in **both** scopes — the principles live at user
scope whichever way core was installed, and a Claude-only install would
otherwise leave a Codex adopter with the principles nowhere. Hermes is not a
target because it already carries the same four principles in its
`himmel_agent` profile SOUL (`scripts/hermes/assets/himmel-agent.SOUL.md`,
§ How you work), installed by `install-himmel-profile.sh`. Re-running
adopt is also the migration path for an install that predates this, and adds
nothing otherwise.

Existing installs also get a best-effort backfill on the harness self-update
path: `scripts/himmel-update.sh`'s advisory steps run the same two-target
`wire_user_claude_md` install unconditionally on every `himmel-update` (not
under `--check`), so an adopter who already ran `adopt.sh` before HIMMEL-2038
picks the block up on their next update without re-running adopt by hand. Like
the other advisory steps, it never fails the update.

---

## 3. RTK (Rust Token Killer)

RTK is a token-saving CLI proxy that wraps common commands.

```bash
# Install (Linux / macOS)
cargo install rtk   # or download binary from releases

# Install (Windows — single self-contained exe, no cargo needed)
# Download rtk-x86_64-pc-windows-msvc.zip from
# https://github.com/rtk-ai/rtk/releases for the current tag,
# extract, and overwrite the binary at its existing PATH location.

# Verify (must show rtk, NOT reachingforthejack/rtk)
rtk --version
rtk gain
```

⚠️ Name collision risk — see [`docs/setup/rtk-md.md`](rtk-md.md).

### 3a. Expected post-setup state: "No hook installed" banner

After himmel machine-setup, `rtk init --show` reports:

```
[--] Hook: not found
[warn] settings.json: exists but RTK hook not configured
```

And every rewritten command prints `[rtk] /!\ No hook installed` to stderr.

**Both are benign and expected.** himmel replaces rtk's bare `rtk hook claude`
PreToolUse entry with `scripts/hooks/rtk-hook-guard.sh` (HIMMEL-241), which
proxies rtk internally and adds a compound-predicate filter to fix broken
`find` rewrites. rtk's self-check looks for its own `rtk hook claude` signature —
which the guard replaces — so it can't find the hook even though rewriting is
fully operational. `rtk gain` will show real token savings accumulating.

**Do NOT run `rtk init -g` to "fix" it.** That re-adds the bare entry the setup
already replaced. The next run of `reconcile-rtk-hook.sh` collapses it back,
but there's no need to create the problem in the first place.

**If bare entries do accumulate** (e.g. you ran `rtk init -g` outside of
machine-setup), run the idempotent reconciler:

```bash
bash scripts/lib/reconcile-rtk-hook.sh ~/.claude/settings.json <himmel-path>
```

This swaps every bare `rtk hook claude` entry to the guard and collapses the
result to exactly one guard entry. Safe to run multiple times.

---

## 4. himmel Repo

```bash
git clone https://github.com/yotamleo/himmel.git
cd himmel
node scripts/himmelctl/bin.js install
```

**`himmelctl` (HIMMEL-887) is the install wizard and the primary install path.**
It runs the preflight + required-tools gate, then walks you through a few
questions and derives + runs the right underlying command. A missing required
tool (git/jq/python3, or a JS package manager) is auto-fetched via the platform
package manager when possible, else the wizard fails loud and points you at
the required-environment table (HIMMEL-460).

| Question | Choices | Notes |
|---|---|---|
| profile | `starter` \| `luna` \| `operator` \| `custom` | HIMMEL-2308: replaces the old adopter/contributor role fork. Every install now walks the SAME question set; `profile` only SEEDS the default answer at each later question below (a numbered menu with per-option help text) — it never skips one. Default `starter`. The contributor-dev overlay is set only by the `--contribute` flag, never a question (see below). |
| scope | `project` \| `user` | Universal now (no longer role-gated). |
| vault | `none` \| `default-template` \| `existing` | `none` scaffolds no vault; `default-template` scaffolds a luna vault from template — if the destination already exists it is **refused** unless it carries the luna stamp (`adopt.sh` would skip the copy and silently adopt whatever is there), and a stamped destination is reused with the summary saying so rather than claiming a scaffold; `existing` wires a STAMPED luna vault (non-luna→luna conversion deferred — HIMMEL-862). Skipping adopt.sh/setup.sh wiring entirely (no pre-commit hooks/guardrails/statusline/env.HIMMEL_REPO — operator wires manually) has no in-wizard option: don't run the wizard. |
| handover | `inline` \| `external` | `external` persists `HANDOVER_DIR` to an external state repo. |
| pluginSet | `lean` | The only option (HIMMEL-816 default). `full` was dropped (HIMMEL-2304): its enable set didn't reflect what himmel actually runs — see §6 for the documented per-plugin manual recipe instead. |
| lanes | `codex` \| `hermes` \| `none` (comma list) | Universal now. Default `none`. **HIMMEL-2352 (operator ruling 34, 2026-09-01): v1 ships Claude tiers as the only implementation lanes — codex and hermes are offered ONLY as cross-model review (CR) lanes for `/pr-check`, never as implementation lanes.** `ollama-local` and `copilot-cli` — the two lanes this question used to default-select — are dropped from the wizard entirely; they still exist as ordinary (now `dormant`) rows in `scripts/lanes/lanes.json`, reachable only by an operator who opts in directly with that registry's `optInEnv` (`OLLAMA_LOCAL_LANE_OK=1` / `COPILOT_CLI_LANE_OK=1`), never through himmelctl. The interactive menu carries a help line per option naming what it needs (e.g. "codex — requires the codex CLI + its own login; skip if you don't have it") — selecting either AT THE PROMPT is itself the explicit consent `--with-codex` / `--with-hermes` provide non-interactively. The `--lanes` CSV flag stays restricted to `none` only: naming `codex`/`hermes` there is still refused (so the flag never becomes a second, quieter door around that consent), and naming `ollama`/`copilot` there is refused the SAME way — one door, not two — with the refusal naming the `lanes.json` opt-in env instead of pretending a `--with-ollama` flag exists. **Without codex or hermes selected (by either door), `/pr-check`'s review panel runs Claude-only and `CR_REQUIRE_CROSS_MODEL` cannot be satisfied — the wizard discloses this at the question and the summary reflects the resulting floor (HIMMEL-2303).** |
| alwaysOn | `yes` \| `no` | Universal now. Default `no`. Chooses the machine-hardening **checklist** over a one-line pointer — nothing is executed either way (see below). |
| cadences | per-cadence multi-select: `pipeline`, `qmd`, `graphmap`, `codex-sweep` — comma list or `none` | PER-ROW gated, not whole-question vault gated (HIMMEL-2176; per-cadence HIMMEL-2302): `pipeline`/`qmd`/`graphmap` are offered only when vault≠`none`, `codex-sweep` only when the `codex` lane was selected above — asked only when at least one row is offered, so e.g. a vault-less machine with the `codex` lane still gets asked (offering only `codex-sweep`). Replaces the old binary luna-cadence question: pick WHICH recurring cadence jobs to arm now, not all-or-nothing. Enter accepts the profile-seeded recommended set (`operator` seeds `pipeline,qmd,graphmap`; every other profile seeds none). `pipeline` arms via the flags himmelctl derives from `luna.cadence.*` (see [Adopter config file](#adopter-config-file--himmelconfigjson-himmel-2176) below); `qmd`/`graphmap`/`codex-sweep` arm via their own script's all-default invocation (no per-adopter schedule surface yet). `luna.cadence.enabled` mirrors the `pipeline` selection for older readers. If the config document could not be saved it refuses to arm any unit, rather than leaving machine state the config cannot account for. |
| disarm cadence | `yes` \| `no` | Asked only when at least one offered cadence above was declined, naming every declined unit. Default `no`. A `yes` runs each declined unit's own `disarm` subcommand with consent (`--dry-run` shows it) to tear down any already-armed jobs; a `no` leaves them armed and the run's summary says so explicitly, per declined unit, rather than implying `off` already disarmed anything. |
| PHI declaration | `yes` \| `no` | vault≠`none` only. Default `no`. Preceded by a printed, read-only PHI checklist (§4d). Records **only** the operator's yes/no answer at `luna.phi.declared` — himmelctl creates none of the PHI markers themselves (see §4d). |
| secrets walk | `run` \| `skip` | vault≠`none` only. Default `skip`. Walks luna secrets interactively (instruction card + a probe per secret); himmelctl never harvests the secret value itself. HIMMEL-2305: walks only the secrets whose `feature` tag (`scripts/himmelctl/lib/secrets-manifest.json`) matches what you actually selected elsewhere in this run — vault≠`none` for luna-source credentials, telegram bridge `on` for `TELEGRAM_BOT_TOKEN`/`WHISPER_MODEL`. A feature you declined (or never asked about) is skipped, with one line naming how many secrets and why; `.env.example`'s own generated block stays the full union for every adopter, reorganized into the same per-feature sections. |
| telegram bridge | `off` \| `on` | vault≠`none` only. Default `off`. Configures the bridge for voice/text ingestion (see [§8.6](#86-telegram-bridge-onboarding-himmel-227)). |
| bridge .env path / whisper CLI / whisper model | paths (blank = default/autodetect) | Asked only when the telegram-bridge answer above was `on`. Defaults: `~/.claude/channels/telegram/.env`, autodetect, `ggml-small.bin`. |
| bridge persistence | `yes` \| `no` | Asked only when the bridge is `on` **and** this platform has an installer: a HimmelTelegramBridge scheduled task (Windows) or a systemd `--user` unit (`telegram-bridge.service`) + linger (Linux). Default `no`. On any other platform (macOS included) the question is skipped entirely and himmelctl prints a one-line notice to install/enable persistence by hand instead. |

Flags: `--dry-run` prints the derived plan without executing; `--from-profile
<path>` replays a saved answer profile non-interactively (the wizard caches your
answers, so the same install replays verbatim); `--contribute` layers the
contributor-dev `setup.sh`/`setup.ps1` primitive on top of the install (never a
question); `--lanes <csv|none>`,
`--with-codex` and `--with-hermes` answer the lane question up front (all three
are refused alongside `--from-profile` — a saved profile already carries its
lane selection and stays the sole authority on a replay). To offboard later:
`node scripts/himmelctl/bin.js uninstall` — a thin wrapper over
`scripts/uninstall.sh` / `uninstall.ps1` (§8.7).

**What the adopter profile does NOT do (HIMMEL-862 v1, deliberate).** Two
things it reports rather than performs, because in both cases doing them would
mean the installer asserting something it cannot stand behind:

- **Lanes are probed, never installed or force-activated.** The wizard resolves
  each selected lane through the *same* evaluator and the *same* merged
  configuration `/lanes` uses (`scripts/lanes/probe.mjs` + `resolve.mjs`, base
  `lanes.json` overlaid with `lanes.local.json`), so the two can never
  disagree — notably `hermes` is detected via `$HERMES_PY` / venvs under
  `$HERMES_HOME`, not by looking for `hermes` on `PATH`, and a lane you have
  turned off locally reports `DISABLED` (with the `config set` command that
  re-enables it) rather than `available`, and a corrupt `lanes.local.json`
  makes lanes report `UNKNOWN` naming that file rather than quietly falling
  back to the base registry. A single overlay *entry* that is degenerate (a
  null/unknown-kind probe) fails closed the same way the resolver does — the
  lane reads not-usable with the reason named, because `/lanes` excludes it
  too. Whenever a lane needs an overlay fix, the summary lists that fix
  **and** the lane's own setup step, in that order — including the case where
  a lane is both missing *and* locally disabled, where installing the CLI
  alone would leave `/lanes` still excluding it. Under the resolver's
  `LANES_REGISTRY` test override the same replacement-no-overlay semantics
  apply here, so the report never describes a different lane set than
  `/lanes` resolves. Physical presence is always decided by the *base*
  registry probe, never by the overlay: an override can turn a lane off, but
  `config set lanes.<id> on` cannot conjure a binary you never installed —
  that combination reports `MISCONFIGURED` and keeps its install command.
  Note the probes establish that a **binary
  exists** — not that a lane is *configured*: hermes has no richer readiness
  probe, so a present hermes binary always stays listed under `still manual`
  as a verify item (confirm the venv/auth manually). Only a lane with a richer
  readiness probe (codex, via the manifest's provisioning check) can report
  `ready`. A lane whose
  CLI is already present is reported as binary already present and skipped (so a re-run is
  idempotent); a lane that is *absent* is listed under `still manual` with its
  install command. Both that command and the follow-up setup step are chosen
  per platform, so a Linux/macOS adopter is pointed at
  `scripts/codex/install-himmel-codex.sh` and the POSIX branch of
  `docs/hermes-runbook.md` rather than at PowerShell scripts. It is NOT
  installed for you. An applied adopter install writes the top-level
  `profileAllowlist` and `profileAllowlistScope` fields to `lanes.local.json`;
  selected lanes keep their real base probes. It does **not** call
  `himmelctl config set lanes.<id> on`, because that would write
  `probe.kind=always` and make an absent lane report as available.
- **Machine hardening is printed, never executed.** With `alwaysOn=yes` the run
  ends in a checklist of the
  [Phase-6 steps](./windows-clean-machine.md) — power profile, no-lock-on-wake,
  sshd, auto-logon. They are machine-wide, need an elevated shell, and
  `himmelctl uninstall` cannot undo them, so they stay a checklist you run by
  hand.

Every run ends with an honest summary: what was installed, what was skipped and
why, and what remains manual. Under `--dry-run` the first bucket is labelled
`would install` and the `installed` list is empty — a preview never reports
work it did not do.

On an applied adopter install, the selection narrows the runtime `/lanes`
inventory. Non-selected optional lanes whose real probes succeed remain visible
under `suppressed-by-profile`; they are physically available but not routable.
No `profileAllowlist` means the pre-profile resolver behaviour is unchanged.

**Node-less (clean) machine?** `himmelctl install` itself needs node. Run the
bootstrap shim first — it installs node (+ bun on macOS via brew; apt has no
bun package, so Linux gets node + npm and bun stays an optional post-bootstrap
step) via the platform package manager (brew/apt/winget) then hands off to
`himmelctl install` (himmelctl's own preflight covers every other tool):

```bash
bash scripts/himmelctl/bootstrap.sh --dry-run    # Linux/macOS: preview the plan
bash scripts/himmelctl/bootstrap.sh              # then run for real
# Windows (PowerShell — the built-in powershell works on a clean machine; pwsh needs its own
# install. -ExecutionPolicy Bypass because a clean machine's default policy is Restricted):
powershell -ExecutionPolicy Bypass -File scripts/himmelctl/bootstrap.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts/himmelctl/bootstrap.ps1
```

> **Deprecated setup shims — `scripts/machine-setup/win11.ps1` / `ubuntu.sh`
> (HIMMEL-887).** These full-machine provisioning scripts are **soft-deprecated**
> as an install entry point. They still provision the complete toolchain (git /
> python / jq / shellcheck / gitleaks, nvm+node, uv, the Claude CLI, rtk — zero
> capability loss, locked O4) but no longer do himmel/luna *wiring* themselves;
> they print a deprecation notice and delegate the wiring to
> `himmelctl bootstrap` → `himmelctl install`. Prefer `himmelctl install` (above)
> on a machine that already has node, or the bootstrap shim on one that doesn't.
> The hard-remove of this now-deprecated shim script itself (once its
> toolchain-provisioning role is also absorbed) is deferred to HIMMEL-755.

What the wizard runs under the hood no longer depends on a role (HIMMEL-2308
killed that fork): `scripts/adopt.sh` (the portable-core flow — see
[docs/setup/use-on-your-project.md](./use-on-your-project.md)) always runs.
Passing `--contribute` layers `scripts/setup.sh` on top of it afterward
(pre-commit install, Jira CLI build, `.env` from `.env.example`, plugin
install, and wiring the statusline + `env.HIMMEL_REPO` + the **UNIVERSAL
hooks** into `~/.claude/settings.json`, user scope — see §4b) — never instead
of `adopt.sh`, and never asked as a question.

> **Build artifacts are gitignored — build them after cloning (HIMMEL-842).**
> `scripts/jira/dist/index.js` and `scripts/bitbucket/dist/index.js` are TypeScript
> build outputs, NOT tracked. A fresh clone has no `dist/`, so a direct
> `node scripts/jira/dist/index.js list` dies with `MODULE_NOT_FOUND`. `bash scripts/setup.sh`
> builds them (step `[3/10]`, Jira + Bitbucket CLIs). If you skip setup, build by hand:
> ```bash
> cd scripts/jira && npm install && npm run build && cd ../..   # or: bun install && bun run build
> node scripts/jira/dist/index.js list                          # verify
> # same shape for the Bitbucket CLI: cd scripts/bitbucket && npm install && npm run build
> ```
> (Needs Node 18+ with npm, OR bun — see [§1](#1-required-environment-himmel-123).)

To **update** an existing checkout later, run `/himmel-update` (or `bash scripts/himmel-update.sh`):
`git pull` is what delivers himmel updates — marketplace `autoUpdate` does not.
See [`updating.md`](updating.md).

### `himmelctl status` — read-only install-state check (HIMMEL-756)

```bash
node scripts/himmelctl/bin.js status [--items a,b] [--json]
```

Diffs desired state (the manifest at `scripts/install/manifest.json`, crossed
with your recorded install state) against actual state (live probes),
severity-grouped (red/degraded/green/n/a). Read-only: never prompts;
never mutates on repeat runs (the first check for a given target may
persist one derived state entry — the sanctioned derive-write). `--items`
scopes the run to a comma-list of item ids; `--json` emits stable
machine-readable output instead of text.

**Six luna/telegram-bridge items (HIMMEL-2176)** probe subsystems most
adopters never opt into, so a fresh install must not read as a wall of red
for something never turned on:

| id | what it checks |
|---|---|
| `cadence-armed` | whether the configured cadence schedules are actually registered with the OS scheduler |
| `luna-sources` | each configured fetch-health source, via `fetch-health.py --probe <source>` |
| `phi-coherence` | a `.salus` marker under the vault vs. its listing in `phi-roots` — reports `degraded` on a mismatch, **never red** |
| `engine-allowlist` | armed cadence legs' required engines against `cadence-approve-engines.sh --print-engine-list` |
| `bridge-health` | `access.json` + a live `getMe` call + exactly one `getUpdates` consumer (it counts `poller.ts` command lines anchored to THIS checkout, so a supervisor plus its poller child is one consumer, not two). The consumer count is Windows-CIM-only today: elsewhere it reports `degraded` naming process identity as unverified, never a silent pass |
| `bridge-persistence` | whether bridge persistence will actually survive a restart |

`bridge-persistence` is pass/warn/opt-in — it never reports a hard red once
opted in. On Windows it reads `Get-ScheduledTask`'s culture-invariant `State`
enum; a query that FAILS reports `degraded`/unknown, never absent — "not
there" and "could not ask" stay distinct results. On Linux it checks
unit-installed + enabled + linger, each with its own `degraded` reason (a
unit that installs but whose linger step fails is reported as a partial
install with the remediation named, never auto-rolled-back — without
`loginctl enable-linger`, the systemd user unit only runs while that user is
logged in and stops at logout). On macOS it always reports `degraded`, naming
launchd as Stage 2 — an unverified persistence state is never reported as
healthy. When `bridge.enabled` is not `true` in `~/.himmel/config.json`,
`bridge-persistence` and `bridge-health` report a clean absence (`n/a`), not a
failure — opting out is not a fault.

**HIMMEL-2305 — three items scoped by your recorded SELECTIONS, not a config
flag.** `telegram-bridge`, `hermes-lanes` and `codex-cli` carry no
`~/.himmel/config.json` flag of their own (unlike the six above), so their
only record of whether you ever opted in is the cached wizard answers read
from `install-profile.json` (see below). A missing credential/install for a
feature you never selected — telegram bridge `off`, the `hermes`/`codex` lane
not chosen — reports `n/a`, not red; a genuinely selected-but-absent one still
reports red. A machine with no recorded profile at all keeps today's full-nag
behavior rather than going quiet (fail-open, never silent). The same
selection→feature mapping (`adopterProfileLib.resolveActiveFeatures()`) also
scopes the wizard's own secrets walk (previous section).

The scope comes from your last wizard run (the cached
`~/.claude/himmel/install-profile.json`): under **project** scope the target
is keyed by the directory you run it from — run it from the adopted
project's root; under **user** scope the target is the single `user` entry
regardless of cwd. (A per-run scope override lands with the Phase-2 verbs.)
It's the shared pre-check/post-check/enable-time primitive later himmelctl
verbs (install/uninstall/enable) build on.

### `himmelctl ensure` — converge this target (HIMMEL-755)

```bash
node scripts/himmelctl/bin.js ensure [--profile core|luna|all] [--items a,b] [--prune] [--yes] [--dry-run]
```

Three steps: a `status`-shaped pre-check read, driving whatever it reports
red/degraded through the EXISTING install primitives (`adopt.sh`/`setup.sh`/
the `wire-*.sh` libs/`install-plugins.sh`/qmd's `qmd_install` — never
reimplemented), then a `status`-shaped post-check. Idempotent — an
already-green target is a no-op. `--profile` reconciles the target to a
different profile FIRST (so e.g. `ensure --profile luna` on a core-derived
target converges the luna-only items too) before converging. `--items` scopes
the run to a comma-list of item ids. Both `status --items` and `ensure --items`
reject an unknown item id outright (exit 2); what `ensure --items` adds —
**unlike `status`**, which validates ids and nothing further, staying a pure
read/display filter — is that it validates the
selection's dependency closure in BOTH directions before touching anything: a
selection that omits a still-desired, red/degraded prerequisite an item being
converged depends on is **rejected** (exit 2, zero mutation), naming both ids
and the remediation that actually resolves it; the mirror check on the
toward-disabled side rejects unwiring a prerequisite while a still-desired
dependent isn't being unwired too. Naming a prerequisite in `--items` is not
by itself sufficient to satisfy this check if that prerequisite is hint-only
(see below, and the "never fail-closes" caveat there) — only a prerequisite
that will genuinely converge this run does. `--dry-run` prints the
ordered convergence plan and makes **zero mutations** — no primitive is ever
invoked. **Converging and disabling are separately consented, and disabling is
opt-in (HIMMEL-2349).** A default `ensure` converges only: it never disables
anything, whatever the target's state says. Removing wiring requires
`--prune`, and even then it is a **second, independent** `Proceed with
disabling? [Y/n]`, asked after the converge confirm and declinable on its own
— declining it still lets the convergence proceed. Each disable candidate is
printed with per-item evidence naming what the recorded profile says, what the
live probe found, and the exact command the disable would run; `not enabled
for this target (profile/scope)` alone is not something an operator can
consent to. When the recorded profile looks under-recorded relative to live
state, `ensure` says so and refuses to offer mass disables **even under
`--prune`**, pointing at the wizard rather than reconciling reality downward.

Declining the converge confirm aborts the run outright — the `--prune` pass is
not reached, and the message says so. That asymmetry is deliberate: "no" to
the first prompt reads as "stop", and following it by offering to *remove*
things would be a worse answer, not a more independent one.

This replaces the pre-2349 behaviour, in which one consolidated
`himmelctl: about to ...` line could list convergence work ("converge N
item(s): ...") and disable/unwire work ("disable N item(s): ...")
semicolon-joined, and a **single** `Proceed?` authorized everything listed
including the unwiring. That bundling is the incident HIMMEL-2349 fixes: an
operator had to accept eight unwanted disables to take one wanted
convergence. A **non-interactive, non-dry-run** run
(piped/automation — how `ensure` runs outside a Claude session) that has
**any work to perform** (convergence, disable, or both) and passes neither
`--yes` nor `--dry-run` exits **2** with `non-interactive ensure requires
--yes` and makes zero mutations — automation must pass `--yes` explicitly;
there is no silent unattended consent. An already-green run (nothing to
converge or disable) needs no consent and exits **0** whether or not `--yes`
is given.

An item with no automated install path yet (a `config`-type item, pending
sub-ticket D, or one with no `install` descriptor at all) is reported as a
hint. Two distinct guarantees here, not one: once a run is actually
converging, a hint-only item never fail-closes it on its own account — it's
never dispatched, so `ensure` never waits on or blocks over its success.
But `--items` dependency-closure VALIDATION (above) is a separate, EARLIER
gate — naming a dependent whose desired+red prerequisite is hint-only is
rejected before anything runs at all, precisely because that prerequisite
can never converge no matter how it's selected. So a hint-only item CAN
block a selection from proceeding in the first place, even though it never
blocks convergence once a run is genuinely underway. An enabled item the
operator no longer wants converges by its `removable` field: `per-item` runs
the matching `unwire-*.sh` primitive; `full-offboard-only` errors, naming
the item and pointing at `himmelctl uninstall`.

#### `HIMMELCTL_SUDO_PASSWORD` — optional, for unattended Linux dep installs

`ensure` can converge missing host binaries (`dep`-type manifest items —
`jq`, `git`, `shellcheck`, ...) via the platform package manager. On Linux
that means `apt-get`, which needs `sudo`. `HIMMELCTL_SUDO_PASSWORD` is an
**optional** var: set it to let an unattended `ensure` run authenticate and
install via apt non-interactively; leave it unset and `ensure` falls back to
the non-interactive `sudo -n` form, which never prompts and never hangs —
a dep whose sudo would PROMPT for a password fails FAST rather than blocking
forever waiting for interactive input nobody outside a Claude session is
there to provide. `sudo -n` is **not** an unconditional failure: where sudo
is already cached from a recent authentication, or the account is configured
`NOPASSWD`, it succeeds and the dep installs normally — the var only matters
when authentication would actually prompt. Resolution order mirrors every other himmel
`.env`-backed setting: a live `HIMMELCTL_SUDO_PASSWORD` in the process
environment wins; otherwise it's read from the **primary checkout's**
`.env`. Without it configured, `ensure` prints a one-line advisory (once per
run, never per dep item) pointing here — it never reveals whether the var
was merely absent or present-but-empty, only "not configured".

**Security:** the password is passed to `sudo` on **stdin only** (`sudo -S
-p ''`) — never as a command-line argument (`ps`-visible to every user on
the box), never logged, never printed in a `--dry-run` preview or an error
message, and never present in the **child process's environment** either:
`ensure` passes every apt/winget/brew primitive an explicit, scrubbed copy
of its own environment with `HIMMELCTL_SUDO_PASSWORD` deleted — an
inherited env var would otherwise be readable from `/proc/<pid>/environ` by
any other process running as your user for the primitive's whole lifetime,
and would propagate to every grandchild it spawns (apt hooks, postinst
scripts, ...), none of which need it. A timed-out primitive is torn down
tree-wide (not just the direct child) so a wedged installer does not leave a
credential-bearing descendant running in the background — but the two
platforms give **materially different guarantees**, and the POSIX one is
weaker: on Linux/macOS the installer runs in its own process group, killed
as a group on timeout, which is **best-effort** — a descendant that
deliberately leaves that group (a `setsid`, a double-fork — routine daemon
behaviour) is no longer reached by the group kill and survives it. Do not
read the POSIX path as a Job-Object equivalent; it has no comparable
structural teardown. On **Windows**, the installer and every descendant it spawns run
inside a kill-on-close **Job Object** (`scripts/himmelctl/lib/job-run.ps1`,
plain PowerShell + Win32 P/Invoke, zero new npm dependencies) — every
descendant automatically joins the same job at creation, so a timeout can't
leave a survivor even if an intermediate process has already exited and
"re-parented" its own child (exactly what installer postinst/daemon scripts
routinely do), a case a plain process-tree walk can miss. Job Object setup
(creation, limit configuration, assigning the installer process to the job)
is **fail-closed**, not best-effort: if any step of it fails, job-run.ps1
refuses to run the installer at all (or kills it immediately if it had
already started) rather than silently falling back to a weaker
direct-child-only cleanup, so the primitive lands in `failed[]` instead of
running unprotected. One residual gap this doesn't close: the installer
process is assigned to the job in a separate call right after it starts,
not atomically with its own creation (avoiding a `CREATE_SUSPENDED`-based
launch, more Win32 P/Invoke surface than this file otherwise needs) — a
descendant the installer spawns in that sub-millisecond window, before
assignment completes, would not itself inherit job membership and could in
principle survive a later timeout.

Because the value lives in a plaintext `.env` file, treat it like any other
secret in that file:
- The primary checkout's `.env` **must stay untracked** — it is already
  listed in himmel's `.gitignore`; never `git add -f` it or copy its
  contents into a tracked file.
- Give it **owner-only permissions** on Linux/macOS: `chmod 600 .env`.
- Where available, prefer a real secret manager (your OS keychain, `pass`,
  a vault/secrets-manager integration, CI secret store, ...) over a
  plaintext `.env` value — set `HIMMELCTL_SUDO_PASSWORD` in the process
  environment from there instead of writing it to disk at all; recall the
  resolution order above (a live process-env value always wins over the
  `.env` fallback), so this requires no code changes, just not writing the
  file-based fallback.

macOS needs no equivalent for a **standard** Homebrew install: the default,
supported prefix (`/opt/homebrew` on Apple Silicon, `/usr/local` on Intel)
is owned by the invoking user, so `brew install` never prompts for a
password there. A **custom** prefix, or an install directory with
pre-existing permission problems, can still require elevation or fail
outright — `HIMMELCTL_SUDO_PASSWORD` has no effect on brew either way (it's
only ever consumed by the Linux `sudo -S apt-get` path), so a brew failure
of that kind needs manual remediation. Windows dep installs go through
`winget`, also non-interactive (`--silent --disable-interactivity
--accept-*-agreements`), no credential needed.

The three generic guardrails (`auto-approve-safe-bash`, `block-edit-on-main`,
`block-read-secrets`) can live at the **user** scope (protects every repo you
work in) or the **project** scope only. himmel ships them project-level, so if
you also wire them at the user scope they would fire twice inside himmel — a
doubled bash spawn per tool call. `setup-hooks.sh --guardrail-mode` manages the
himmel-owned user-level block so exactly one layer is active:

```bash
# global (default): protect all your repos; inside himmel the user-level copies
# run through guardrail-skip-in-himmel.js (one cheap node spawn, no double bash).
bash scripts/setup-hooks.sh --guardrail-mode global        # add --yes to skip the prompt
# project: drop the user-level block (himmel-only protection; single native spawn).
bash scripts/setup-hooks.sh --guardrail-mode project
```

Windows/PowerShell twin: `pwsh scripts/setup-hooks.ps1 -GuardrailMode global`.
A bare `bash scripts/setup-hooks.sh` installs the git hooks and only *prints* the
current mode. `/himmel-update` reports if a global block's baked node path drifts.

After setup, fill in your `.env` values — see the per-variable walkthrough in
[§1 Required `.env` values](#required-env-values-per-variable-walkthrough), or
re-run setup with `--fill-env` to be prompted with inline help for each field:

```bash
# Fill in Jira token (or run setup with --fill-env for guided prompts)
vi .env   # set JIRA_API_TOKEN=...

# Verify
node scripts/jira/dist/index.js list
pre-commit run --all-files
```

### Adopter config file — `~/.himmel/config.json` (HIMMEL-2176)

The luna-cadence, PHI-declaration and telegram-bridge wizard answers above are
written to a single shared adopter config document, `~/.himmel/config.json`
(override: `HIMMEL_LUNA_CONFIG_PATH`) — the same path on every platform. This
is **not** the wizard's own private answer cache
(`~/.claude/himmel/install-profile.json`, mentioned above) — that file
replays your wizard answers on a `--from-profile` run; this one is the
runtime config document the luna/bridge subsystems themselves read. Writes
are atomic (write-to-temp, validate, rename) and keep one timestamped `.bak`.

Schema v1 — every object node is a **closed shape** (an unknown key is a
validation error); only a schedule's `day` is optional:

| field | type | default |
|---|---|---|
| `version` | exactly `1` | `1` |
| `luna.vaultPath` | string | `~/Documents/luna` |
| `luna.cadence.enabled` | boolean | `false` |
| `luna.cadence.schedules.fetchHealth.time` | `HH:MM` | `01:30` |
| `luna.cadence.schedules.harvest.time` | `HH:MM` | `02:00` |
| `luna.cadence.schedules.synthesize.time` | `HH:MM` | `03:00` |
| `luna.cadence.schedules.health.time` / `.day` | `HH:MM` / weekday (optional) | `04:00` / `SUN` |
| `luna.cadence.models.harvest` / `.synthesize` / `.health` | string | `sonnet` / `sonnet` / `haiku` |
| `luna.phi.declared` | boolean | `false` |
| `bridge.enabled` | boolean | `false` |
| `bridge.envPath` | string | `~/.claude/channels/telegram/.env` |
| `bridge.whisper.cli` | string or `null` | `null` |
| `bridge.whisper.model` | string | `ggml-small.bin` |

`luna.phi.declared` records only the adopter's yes/no **answer** to the PHI
question above — himmelctl creates none of the PHI markers themselves; §4d
below stays the authority on those (the `.salus` marker, the `phi-roots`
listing, the egress-denylist entries).

The wizard writes **only the fields the run actually supplied** — an
unsupplied section (a contributor run, or an adopter who answered
`vault=none` and so never saw these questions) is left exactly as loaded on
disk, never coerced to a default; the write is skipped entirely when nothing
changed.

**Precedence** (governs `WHISPER_CLI` / `WHISPER_MODEL` / `TELEGRAM_ENV`): a
process environment variable overrides the configured value, which overrides
the hardcoded default above.

### 4a. Optional — single-writer opt-out (HIMMEL-404)

For personal repos that commit straight to main (e.g. `luna`, `salus`, your docs/state repo),
opt them out of the `block-edit-on-main` hook by dropping a local `.single-writer`
marker at each repo's root. The marker is gitignored (via global excludes) so it
never propagates to a clone — a checkout without it stays protected.

```bash
# Single-writer opt-out for block-edit-on-main (HIMMEL-404): ignore the marker
# globally (once), then drop one in each single-writer repo.
EX="$(git config --global core.excludesfile)"
[ -z "$EX" ] && EX="$HOME/.config/git/ignore" && mkdir -p "$(dirname "$EX")" && git config --global core.excludesfile "$EX"
grep -qxF ".single-writer" "$EX" 2>/dev/null || printf '.single-writer\n' >> "$EX"
touch ~/Documents/luna/.single-writer ~/Documents/salus/.single-writer ~/Documents/github/work-notes/.single-writer
```

This lets those repos opt out of the on-main edit block locally without the marker
ever being committed.

### 4b. Hook scope: user vs project (HIMMEL-460)

himmel's hooks split into two scopes. `scripts/setup.sh` (and `adopt --scope
user`) wires the **UNIVERSAL** set into your **user-scope** `~/.claude/settings.json`
so they apply to *every* Claude session, in any directory — not just inside the
himmel clone:

- **UNIVERSAL (user scope):** `auto-approve-safe-bash`, `block-edit-on-main`,
  `block-read-secrets` (PreToolUse) + `inject-initiative` (SessionStart). Without
  user-scope wiring, a session launched outside the repo has no auto-approve (so
  the allow-listed Jira CLI gets denied) and no leg-injector (so `HIMMEL_INITIATIVE`
  never fires).
- **HIMMEL-DEV-ONLY (project scope):** `check-cr-marker-on-pr-create`,
  `block-backend-tier`, `auto-arm-on-cap`, `check-update-available`, … — they only
  make sense while working inside the himmel repo, so they stay in the repo's
  committed `.claude/settings.json` and are **not** user-wired.

The hooks reference **this clone's absolute path** and dedup by hook *basename*, so
re-running setup after moving the clone repairs the wiring instead of double-wiring.
A fresh contributor who clones himmel still gets the safety hooks from the committed
project `.claude/settings.json` even before running setup.

**Duplication is benign.** Inside the himmel repo the UNIVERSAL hooks are wired at
both scopes and fire twice — that is idempotent (two auto-approve passes = the same
allow; two block passes = the same block), so setup stays silent about it in-repo.
For *another* adopted project that also carries a project-scope copy, setup prints
an advisory listing the dupes + the `unwire-pretooluse-hooks --scope project
--target <repo>` command to collapse them (never automatic).

`HIMMEL_INITIATIVE` and the overnight pair are read from the himmel clone's `.env`
by the SessionStart hook (a value exported in the launching shell or set in
settings.json `env` still wins); they ship **commented** in `.env.example`, so the
opt-in default-OFF is preserved — uncomment one line to enable.

`scripts/uninstall.sh` step `[6/6]` is the symmetric teardown — it removes exactly
what setup/adopt wired (preserving your non-himmel keys); `--skip-settings` keeps it.

### 4c. Scheduler backend (auto-arm resume) (HIMMEL-594)

The usage-cap auto-resume (`auto-arm-on-cap` → `arm-resume.sh`) schedules a
relaunch via the OS scheduler. The watchdog hook is wired above, but the
*scheduler backend* it relies on must exist or the armed resume silently never
fires:

- **Linux** — needs `at` + a running `atd`. `ubuntu.sh` installs+enables it
  (prompted); or do it by hand: `sudo apt install -y at && sudo systemctl
  enable --now atd`. (crontab is only a weaker fallback when `at` is absent.)
- **macOS** — uses `crontab` (arm-resume skips `at`/atrun, which is
  off-by-default / SIP-fragile). Run `scripts/machine-setup/macos.sh` (**ALPHA**
  — validate it fires and file an issue). cron may need Full Disk Access on
  modern macOS.
- **Windows** — `schtasks` is always present; nothing to do.

Diagnose any existing install with `/himmel-doctor` (the **C9-scheduler** check
reports OK / WARN + the exact per-OS remediation; it never runs a privileged
command).

### 4d. Optional — PHI vault marker for claude-glm (HIMMEL-665)

If you use the `claude-glm` overflow launcher (Claude Code on the Z.ai GLM
flat-rate lane — see [tooling-catalog](../tooling-catalog.md#claude-glm-scriptsclaude-glm-ps1-twin-himmel-665)),
drop a `.salus` marker file at the root of every PHI-bearing vault (e.g.
`~/Documents/salus`). The launcher **refuses to start (exit 3, no override)**
when the marker sits in the directory you launch from — the check is
**per-directory, not subtree**: launching from a subdirectory of a marked
vault does not see the marker. For a hand-rolled PHI vault the marker is
**not placed by any himmel script** — create it by hand (a vault scaffolded
via `setup.sh --medical` gets it automatically, HIMMEL-2173):

```bash
touch ~/Documents/salus/.salus
```

For **whole-subtree** coverage (any launch cwd under the root refused), also
list the absolute PHI roots one-per-line in `~/.config/claude-glm/phi-roots` —
same PHI-tier refusal, but subtree-wide.

### 4e. qmd search bootstrap (optional — HIMMEL-842)

> **Skip** if you don't use qmd semantic search over the himmel docs + luna vault. Optional; the harness runs without it.

qmd is a local markdown search engine (BM25 + vector + rerank). himmel's fork
runs it as a **shared HTTP daemon** (`localhost:8181`, HIMMEL-592) auto-brought-up
by the `qmd` plugin's SessionStart hook, so every session shares one read-only
index. The standalone CLI installs from the **himmel qmd fork**
(`yotamleo/qmd`), pinned to an immutable commit SHA rather than a mutable
branch (HIMMEL-911) — never upstream `bun add -g @tobilu/qmd`, which
EPERM-wedges on this project's machines (zombie `qmd mcp` stdio processes hold
locks) and bun blocks its postinstall script (HIMMEL-877). `bun` itself is
still required to build the clone (project rule: bun, never npm — see §1
foundational table). `bash scripts/setup.sh` step `[4/10]` + `adopt.sh`'s
`wire_qmd_core` already run this install, register the `himmel` collection,
and best-effort `qmd pull`; this section is the **manual bootstrap** if you
skipped those or want the luna vault indexed too.

```bash
# 1. Install the qmd CLI: clone the fork, build it with bun, then junction
#    (Windows) / symlink (POSIX) it onto the bun-global @tobilu/qmd path —
#    scripts/lib/qmd-bin.sh is the single chokepoint (also used by adopt.sh/
#    setup.sh); repo/ref/clone-dir are overridable via QMD_FORK_REPO /
#    QMD_FORK_REF / QMD_FORK_DIR. Idempotent — re-run to update.
bash scripts/lib/qmd-bin.sh install

# 2. Pull the embedding + rerank models. WARNING: ~2.1 GB download — Ctrl-C-safe
#    (re-run resumes); run once. Semantic search needs these.
qmd pull

# 3. Register collections (idempotent; skip ones you don't have).
qmd collection add /path/to/himmel          --name himmel
qmd collection add ~/Documents/luna         --name luna     # your luna vault

# 4. Index + embed. `qmd update` ingests new/changed docs (fast); `qmd embed`
#    builds the vector embeddings — CPU-intensive on a big vault (the luna vault
#    can take tens of minutes on first embed; subsequent runs are incremental).
qmd update
qmd embed

# Verify
qmd collection list
qmd status                    # collections + doc counts (index registered)
```

Notes:
- The qmd Claude plugin ships a path stub in `~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd`
  that references an unbuilt `dist/`; `scripts/lib/fix-qmd-stub.sh` (run by setup +
  adopt) rewrites it to locate the bun-global install so plain `qmd` works everywhere.
- Stop the shared daemon: `qmd mcp stop`. The index is sqlite+WAL read per query, so
  docs added by `qmd update` are live immediately — no daemon restart needed.
- WSL Claude sessions need qmd installed and indexed separately inside WSL. The
  fork is bun-built there, and its sqlite+WAL index must stay on the WSL
  filesystem rather than being shared over `/mnt/c`; this differs from
  graphify's plain-JSON store, which Windows and WSL can share.

### 4f. cc-codex / cc-glm offload shims

`scripts/shell/himmel-offload-shims.sh` provides the `cc-codex` and `cc-glm`
Bash functions in both Git Bash and WSL. `bash scripts/setup.sh` installs the
guarded source line in `~/.bashrc` best-effort; install it directly with:

```bash
bash scripts/shell/himmel-offload-shims.sh install
```

The resulting `~/.bashrc` line sources the checkout's absolute
`scripts/shell/himmel-offload-shims.sh` path only when that file exists.

---

## 5. Luna Vault

> **Skip** if you don't use the Luna vault (the author's personal Obsidian vault). §§5a, 6, 7, 8, 8.6 all depend on it — skip those too.

> Canonical layout (post HIMMEL-96 fix): the vault lives at `~/Documents/luna` — flat, not double-nested. If your machine has `~/Documents/luna/luna` from a pre-HIMMEL-96 clone, `scripts/machine-setup/{ubuntu.sh,win11.ps1}` includes a migration step that flattens it.

```bash
# Clone (or restore from backup) — flat path, NOT ~/Documents/luna/luna
git clone <luna-remote> ~/Documents/luna

# Install pre-commit hooks
cd ~/Documents/luna
uv tool install pre-commit   # or: pipx install pre-commit
pre-commit install
pre-commit install --hook-type commit-msg
pre-commit install --hook-type pre-push

# Verify
pre-commit run --all-files
```

Hooks: `gitleaks` (secrets scan) + standard hooks. Luna-specific rules live in `~/Documents/luna/CLAUDE.md` (not linked here — it's in a different repo).

> Vault not at `~/Documents/luna`, or want to route a repo's session notes to a different vault? Point the end-session-wiki capture at it — see [Choosing the target vault](../luna/end-session-wiki.md#choosing-the-target-vault) (and §7 below).

### 5a. Optional — Obsidian Web Clipper templates ([Jira LUNA-2](https://yotamleo.atlassian.net/browse/LUNA-2))

If you'll be clipping web pages into Luna (X posts, articles, Reddit threads, newsletters, YouTube videos), install the Obsidian Web Clipper Chrome extension + drop in the 6 pre-built JSON templates that ship with Luna. **Skip if you only want to use Luna for native notes.**

```bash
# Templates ship in the Luna repo:
ls ~/Documents/luna/_Templates/Web-Clipper/import/
# 01-General-Article.json, 02-Research-Article.json, 03-Tweet.json,
# 04-Reddit-Thread.json, 05-Newsletter.json, 06-YouTube-Video.json,
# README.md
```

Install:

1. Install [Obsidian Web Clipper](https://obsidian.md/clipper) from the Chrome Web Store.
2. Extension icon → **Settings** (gear) → scroll to **Templates**.
3. **Drag and drop** all 6 `.json` files from `~/Documents/luna/_Templates/Web-Clipper/import/` onto the Templates list. Six templates appear — names, triggers, properties, body all wired up.
4. Mark **General Article** as Default template (it has no triggers → fires when no other template matches).
5. Confirm `path: "Clippings"` matches Luna's `Clippings/` folder (or change in extension settings).
6. Smoke-test: clip any `x.com/...` URL → confirm Tweet template fires + note lands in `Clippings/`.

The drag-and-drop is the entire install. Trigger tables + post-install tuning live in luna at `_Templates/Web-Clipper/import/README.md`; the *why* behind each section lives in luna at `30-Resources/Tech/Obsidian Web Clipper Templates.md` (both in the luna repo, not linkable from himmel).

Triage of clipped notes (action items / labels / Related Notes hygiene) is implemented as the **`obsidian-triage`** plugin shipped from himmel's marketplace — see §6 below for install. Ticket: [LUNA-3](https://yotamleo.atlassian.net/browse/LUNA-3); handover tracked in the operator's private handover repo.

---

## 6. Claude Code Plugins

> **Skip** if you skipped §5 (Luna vault). The plugins in this section are either luna-dependent or personal-workflow tools — none are required for core himmel operation. Install only what you need.

Plugins live at `~/.claude/plugins/`. Different install methods per plugin — read the **Source** column carefully:

| Plugin | Source | Install method | Why |
|--------|--------|----------------|-----|
| `obsidian-second-brain` | `eugeniughelbur/obsidian-second-brain` | manual clone (NOT in himmel marketplace) | Daily notes, kanban, ADRs, vault operating manual |
| `handover` | himmel marketplace | `/plugin install` after adding himmel marketplace | Handover doc workflows for cross-session continuity |
| `obsidian-triage` (LUNA-3) | himmel marketplace | `/plugin install` after adding himmel marketplace | Autonomous triage of Web Clipper output: `/triage-clips` + `/synthesize-clips`. Required only if you set up the Web Clipper templates in §5a |
| `obsidian` (Steph Ango's skills) | himmel marketplace (sources `kepano/obsidian-skills`, SHA-pinned) | `/plugin install` after adding himmel marketplace | `obsidian-markdown`, `obsidian-bases`, `json-canvas`, `obsidian-cli`, `defuddle`. `obsidian-triage` can use `obsidian-markdown` for proper OFM when editing clipped notes (recommended, not required — fallback documented in the command body) |
| `claude-obsidian` | himmel marketplace (sources `yotamleo/claude-obsidian` vendor fork of `AgriciDaniel/claude-obsidian`, SHA-pinned) | `/plugin install` after adding himmel marketplace | Wiki query, save, ingest, lint, autoresearch. Companion to `obsidian-triage` — `wiki-query` optionally powers richer Related Notes inference |

### Lean profile — disabled by default, enable on need (HIMMEL-816)

`docs/setup/settings-template.json` ships **lean**: 16 re-enableable
`@claude-plugins-official` plugins (the table below) and `obsidian@obsidian-skills`
are `false` in `enabledPlugins` — every adopter
and every re-provisioned operator machine gets the minimal set by default instead
of re-creating the maximal 31-plugin install every time. (A 17th
`@claude-plugins-official` entry, `pr-review-toolkit`, is also `false` but is not
listed for re-enable — himmel ships its own `pr-review-toolkit-himmel` fork.)
Turn any of these back on with one command
(`--scope user` shown; swap for `project`/`local` per [Scope](#scope-user-vs-project) above):

| Plugin | Enable command | Note |
|---|---|---|
| `github@claude-plugins-official` | `claude plugin install github@claude-plugins-official --scope user` | gh CLI over MCP is the standing project rule — enable only for a one-off need |
| `feature-dev@claude-plugins-official` | `claude plugin install feature-dev@claude-plugins-official --scope user` | |
| `plugin-dev@claude-plugins-official` | `claude plugin install plugin-dev@claude-plugins-official --scope user` | |
| `code-review@claude-plugins-official` | `claude plugin install code-review@claude-plugins-official --scope user` | himmel ships its own `pr-review-toolkit(-himmel)` critics — enable this only to also run the upstream flow |
| `ralph-loop@claude-plugins-official` | `claude plugin install ralph-loop@claude-plugins-official --scope user` | |
| `pyright-lsp@claude-plugins-official` | `claude plugin install pyright-lsp@claude-plugins-official --scope user` | **operator convention:** don't flip this on at user scope — dispatch a subagent with the plugin enabled for the one python task instead |
| `agent-sdk-dev@claude-plugins-official` | `claude plugin install agent-sdk-dev@claude-plugins-official --scope user` | |
| `claude-code-setup@claude-plugins-official` | `claude plugin install claude-code-setup@claude-plugins-official --scope user` | |
| `code-simplifier@claude-plugins-official` | `claude plugin install code-simplifier@claude-plugins-official --scope user` | |
| `commit-commands@claude-plugins-official` | `claude plugin install commit-commands@claude-plugins-official --scope user` | |
| `playground@claude-plugins-official` | `claude plugin install playground@claude-plugins-official --scope user` | |
| `skill-creator@claude-plugins-official` | `claude plugin install skill-creator@claude-plugins-official --scope user` | |
| `atlassian@claude-plugins-official` | `claude plugin install atlassian@claude-plugins-official --scope user` | **enable-on-need:** Jira is CLI-first per project rules (`scripts/jira/dist/index.js`) — enable only when a session needs interactive Confluence/Atlassian skills. The optional atlassian **MCP** integration is separate (see [Optional integrations](#optional-integrations)) |
| `claude-md-management@claude-plugins-official` | `claude plugin install claude-md-management@claude-plugins-official --scope user` | **powers `/claude-md-audit`:** that command degrades to a one-line re-enable hint while this is off (HIMMEL-1044); re-enable to run CLAUDE.md audits via the `claude-md-improver` skill |
| `hookify@claude-plugins-official` | `claude plugin install hookify@claude-plugins-official --scope user` | Scaffold hooks from a prompt — dev-authoring only |
| `security-guidance@claude-plugins-official` | `claude plugin install security-guidance@claude-plugins-official --scope user` | **redundant with himmel's CR gate — see the note below (HIMMEL-2036).** Enable only if you are running himmel without the critic panel / CodeRabbit |
| `obsidian@obsidian-skills` | `claude plugin marketplace add kepano/obsidian-skills` then `claude plugin install obsidian@obsidian-skills --scope user` | `obsidian-triage` falls back to plain markdown when this isn't enabled (documented in the command body) — enable if you need proper OFM parity |

> **Note (HIMMEL-816):** `scripts/machine-setup/install-plugins.sh` /
> `install-plugins.ps1` only call `claude plugin install` for `enabledPlugins`
> entries flagged `true` — a fresh adopt/re-provision now gets the lean set
> above, not the pre-lean 31-plugin default. Use the per-plugin commands above
> to opt any of them back in.

> **Note (HIMMEL-1032):** the floor is re-applied on every `/himmel-update` by
> `scripts/machine-setup/reconcile-enabled-plugins.sh` — a **whitelist**
> reconciler, not the additive-only installer above: anything `true` in your
> live `enabledPlugins` that isn't `true` in the template is forced back to
> `false`, so a manual "turn it back on" toggle does not survive the next
> update. Preview without writing: `bash
> scripts/machine-setup/reconcile-enabled-plugins.sh --dry-run --scope user`;
> an already-converged machine prints `no drift — already at the lean floor.`
> `~/.claude/settings.local.json` is the one file reconcile never rewrites —
> it is read as an override that wins in **both** directions: a `true` there
> keeps a personal plugin (e.g. `codex@openai-codex`) enabled through every
> reconcile, a `false` there drops a floor plugin (e.g. `playwright`) you
> don't want. Toggling a plugin off with `claude plugin disable` while its key
> is still `true` in `settings.local.json` does not stick — the next
> reconcile reads the override, not the live `claude plugin` state, and turns
> it back on. Change the override, not just the live toggle.

#### `security-guidance` — recommended OFF; **operator decision pending** (HIMMEL-2036)

`security-guidance@claude-plugins-official` runs an **LLM diff review at the end
of every turn**, an **agentic commit review on every `git commit`**, and ~9 hooks
per session (Claude *and* Codex wiring). himmel already gates the same surface,
harder and later: the `/pr-check` cross-model critic panel must be clean before
`gh pr create` (the CR-marker hook blocks it otherwise), and the CodeRabbit App
review — which can only run once the PR exists — must be clean, with zero
unresolved threads, before merge. Running `security-guidance` too means paying a
model call per turn for a weaker version of a check those gates already block
on, and adding process spawns to the pool HIMMEL-1993 traced a kernel-handle
leak to.

**Adopter default: OFF.** `docs/setup/settings-template.json` and the `user`
profile in `scripts/lanes/plugin-profiles.json` both ship it `false` as of
HIMMEL-2036 — no adopter or dispatched lane enables it.

**Operator box: decision pending.** It is still ENABLED on the operator machine
(user scope, Claude + Codex). The recommendation is to disable it —

```bash
claude plugin disable security-guidance@claude-plugins-official
```

— but that is a user-scope change the operator applies, so HIMMEL-2036
deliberately did **not** flip it. Re-enable per-session or per-repo instead if
you ever want the per-turn review back.

### Install sequence

```bash
# 1. obsidian-second-brain — manual clone (no marketplace)
git clone https://github.com/eugeniughelbur/obsidian-second-brain ~/.claude/plugins/obsidian-second-brain

# 2. himmel marketplace (carries handover + obsidian-triage + claude-obsidian)
# inside Claude Code:
#   /plugin marketplace add yotamleo/himmel
#   /plugin install handover
#
#   # Optional — Web Clipper triage stack (skip if §5a was skipped)
#   /plugin install obsidian-triage
#   /plugin install claude-obsidian     # yotamleo/claude-obsidian (vendor fork of AgriciDaniel/claude-obsidian), tag-pinned
#   # obsidian (kepano) is NOT in the himmel marketplace — install from its own:
#   /plugin marketplace add kepano/obsidian-skills && /plugin install obsidian@obsidian-skills
```

After restoring plugins, verify skills load:
```
/obsidian-daily            # from obsidian-second-brain
/triage-clips --dry-run    # from obsidian-triage; should exit 0 with "no Clippings/" or per-clip preview
```

Note: `claude-obsidian` is pinned to an immutable **tag** in himmel's `marketplace/.claude-plugin/marketplace.json` per supply-chain policy (a bare commit SHA is not installable). To update it, follow the Pin update workflow in `marketplace/plugins/obsidian-triage/README.md`. `obsidian` (kepano) is not in himmel's marketplace — install it from `obsidian@obsidian-skills` (HIMMEL-435).

### Scope: user vs project

The `/plugin install` flow above records the plugin at **user scope** (`~/.claude/settings.json`) — enabled for you across every project. That's the right default for personal-workflow plugins. The alternative is **project scope**: declare the marketplace + plugins in a *repo's* `.claude/settings.json`, so anyone who clones that repo gets them auto-known and enabled (each person is still prompted to trust the marketplace on first use).

The setup scripts let you pick: `scripts/machine-setup/install-plugins.{sh,ps1}` take `--scope user|project|local` (default `user`), and the top-level `ubuntu.sh` / `win11.ps1` setup prompts you to choose. For project/local the target is the **current directory**, so run from the repo you want the plugins scoped to. The CLI does it directly too — `claude plugin install <name>@himmel --scope project` writes the block below for you. Same keys, different file:

```jsonc
// <repo>/.claude/settings.json
{
  "extraKnownMarketplaces": {
    "himmel": { "source": { "source": "github", "repo": "yotamleo/himmel" } }
  },
  "enabledPlugins": {
    "obsidian-triage@himmel": true
  }
}
```

Pick by intent: *yours, everywhere* → user scope; *part of this project, shared on clone* → project scope. Committing `extraKnownMarketplaces` ships a "trust this third-party registry" into the repo — fine for your own repos, a supply-chain call if it has outside contributors. (The JSON above is the illustrative hand-edit form. himmel's setup scripts instead read [`settings-template.json`](settings-template.json) — which registers the marketplace from a local `directory` source rather than the GitHub repo shown above — and apply the plugin set at whichever `--scope` you pick.)

### Direct install (copy-paste, no setup script)

The [Install sequence](#install-sequence) above runs as part of the machine
setup. To skip setup and just add the marketplace + the plugins you want —
choosing the scope per command — copy-paste instead:

```bash
# Register the marketplace (once; the GitHub slug is case-insensitive)
claude plugin marketplace add yotamleo/himmel

# Install plugins — --scope user (default, every project) or
# --scope project (this repo's .claude/settings.json, shared on clone)
claude plugin install handover@himmel         --scope user
claude plugin install obsidian-triage@himmel  --scope user
claude plugin install claude-obsidian@himmel  --scope user
claude plugin install himmel-ops@himmel       --scope user
# obsidian (kepano) is NOT in himmel's marketplace (HIMMEL-435) — install from its own:
claude plugin marketplace add kepano/obsidian-skills
claude plugin install obsidian@obsidian-skills --scope user
# optional operator-coupled forks: telegram-himmel@himmel, pr-review-toolkit-himmel@himmel
```

Or install the entire manifest (the himmel plugins plus the official ones it
builds on) in one shot from a clone, at a chosen scope:

```bash
git clone https://github.com/yotamleo/himmel
bash himmel/scripts/machine-setup/install-plugins.sh --scope project
```

The plugins carry their own slash commands + skills — that's all you need to use
them.

### Troubleshooting: `Host key verification failed` on plugin install (HIMMEL-549)

Every `@himmel` plugin installs from the **local** marketplace clone except
`claude-obsidian`, which is sourced from a separate GitHub repo and is the only
one Claude Code must `git clone` over the network. himmel's manifest now points
it at an explicit **HTTPS** url so a fresh machine clones over HTTPS (no SSH
host key needed). If you still hit:

```
Failed to clone repository: ... No ED25519 host key is known for github.com
and you have requested strict checking. Host key verification failed.
```

your git is rewriting HTTPS → SSH (a `url."git@github.com:".insteadOf
"https://github.com/"` in `~/.gitconfig`), so the clone resolves over SSH on a
box with no `github.com` entry in `~/.ssh/known_hosts`. Pre-seed the host key
once, then retry the install:

```bash
ssh-keyscan github.com >> ~/.ssh/known_hosts
claude plugin install claude-obsidian@himmel --scope user
```

### Remove / move between scopes

- **Remove (user scope):** `/plugin uninstall <name>@himmel`.
- **Remove (project scope):** delete that plugin's `enabledPlugins` line from the repo's `.claude/settings.json` (and drop the `extraKnownMarketplaces.himmel` block once no himmel plugin is left).
- **Move user → project:** `/plugin uninstall <name>@himmel`, then add it to the repo's `.claude/settings.json` as above.
- **Move project → user:** remove its `enabledPlugins` line from the repo settings, then `/plugin install <name>@himmel`.

---

## 7. End-session wiki hook (auto-capture to Luna vault)

> **Skip** if you don't use the Luna vault — this hook writes session notes there and has no effect without it.

Every Claude Code session is auto-captured to the Luna vault as a structured note under `sessions/YYYY/MM/YYYY-MM-DD-HHMM-<repo>-<branch>.md` via a `SessionEnd` hook. Built by epic #7 — full schema + opt-out in [`docs/luna/end-session-wiki.md`](../luna/end-session-wiki.md).

**Prompted during setup.** `scripts/machine-setup/win11.ps1` and `scripts/machine-setup/ubuntu.sh` both prompt to register the hook into `~/.claude/settings.json`:

- **Win11:** `[P]owerShell only / [B]ash only (Git Bash) / Both / [S]kip [default: Both]` — Windows machines usually have both interpreters; pick what you actually use.
- **Ubuntu:** `[Y]es / [n]o [default: Y]` — bash-only (no pwsh by default).

The setup also handles the existing-config case: if `hooks.SessionEnd` already exists in your `settings.json`, the script asks `[O]verwrite / [A]ppend / [S]kip`. A backup is written to `~/.claude/settings.json.bak.YYYYMMDD-HHMMSS` before any modification.

**Skipped during setup?** Re-run the setup script (it's idempotent on this step) or manually add the block to `~/.claude/settings.json`:

```json
"SessionEnd": [
  {
    "hooks": [
      {
        "type": "command",
        "command": "bash \"<himmel-path>/scripts/lib/run-pwsh.sh\" \"<himmel-path>/scripts/hooks/end-session-wiki.ps1\"",
        "shell": "bash",
        "timeout": 30
      },
      {
        "type": "command",
        "command": "bash \"<himmel-path>/scripts/hooks/end-session-wiki.sh\"",
        "shell": "bash",
        "timeout": 30
      }
    ]
  }
]
```

The PowerShell twin routes through `scripts/lib/run-pwsh.sh` (rather than a bare `pwsh …`) so that on a host **without** PowerShell it exits silently instead of printing `pwsh: command not found` every session — the bash twin does the capture there. Both twins self-guard by platform, so exactly one writes the note.

For per-repo opt-out, env-var disable, dry-run mode, and full operational reference, see [`docs/luna/end-session-wiki.md`](../luna/end-session-wiki.md).

---

## 8. MCP Servers

`himmelctl status` now reports the `tokensave-mcp` and `graphify-mcp`
items by checking their registrations in `~/.claude.json` (for a focused
check: `node scripts/himmelctl/bin.js status --items tokensave-mcp,graphify-mcp`).

### tokensave — recommended for every adopter (T0 always-on)

tokensave is the code-graph MCP server the harness leans on for
symbol-level code exploration — it is the **T0 always-on** tier in the
MCP fleet map ([`docs/tooling-catalog.md`](../tooling-catalog.md)) and is
included in **every** lean launch profile
(`.claude/mcp-profiles/profiles.json`). Without it, profile generation
fails loudly — the generator exits with `unresolved server "tokensave"`
until the server is registered — and the CLAUDE.md retrieval routing
(qmd → graphify → tokensave) silently degrades: the server just never
comes up.

Install the binary (pick one):

```powershell
# Windows
scoop bucket add tokensave https://github.com/aovestdipaperino/scoop-bucket
scoop install tokensave
```

```bash
# macOS
brew install aovestdipaperino/tap/tokensave
# any platform (Rust)
cargo install tokensave
```

(Prebuilt binaries for macOS/Linux/Windows are also on the
[GitHub releases page](https://github.com/aovestdipaperino/tokensave/releases).)

Register it with Claude Code (writes the MCP server entry into your
global config):

```bash
tokensave install --agent claude
```

Then initialize the knowledge graph **per project** (opt-in by design —
`sync` only updates projects already initialized). tokensave's index is
**per-checkout, not per-machine**: installing the binary once is not enough —
every clone/worktree needs its own `tokensave init`, or `tokensave serve`
exits before answering the MCP `initialize` handshake (codex/Claude Code
report this as "MCP client for `tokensave` failed to start" / "connection
closed: initialize response" — the real cause is a missing `.tokensave/`
index, not a broken server):

```bash
cd /path/to/repo
tokensave init --no-git-hook    # first time — creates .tokensave/ with the graph DB
tokensave sync                  # afterwards — refresh the graph
```

`--no-git-hook` is required: tokensave offers to install its own git hooks,
which must never be layered onto himmel's gated pre-commit chain
(`.git/hooks`) — see HIMMEL-2281. `node scripts/himmelctl/bin.js deps ensure`
now runs this same `tokensave init <checkout> --no-git-hook` automatically
(idempotent — a no-op if the checkout is already indexed) whenever `status`
reports `tokensave-mcp` degraded for exactly this reason.

Verify: run `tokensave doctor` (checks installation, configuration, and
agent integration), then start a fresh Claude Code session in the repo and
confirm the `tokensave` MCP server is connected (`claude mcp list`).

### graphify — optional knowledge-graph CLI + MCP server (HIMMEL-621/891)

graphify powers the structure/architecture leg of the retrieval routing
(qmd finds content, **graphify explains structure**, tokensave serves
code — `CLAUDE.md`). Opt-in — install via setup:

```bash
bash scripts/setup.sh --with-graphify
```

(Installs the himmel fork via `uv tool install` at a pinned commit SHA;
an existing foreign graphify install is adopted as-is, never reinstalled —
see `scripts/lib/graphify-bin.sh`.)

The install exposes two binaries: `graphify` (the CLI) and `graphify-mcp`
(the MCP server). **`setup.sh --with-graphify` (and `adopt.sh --with-graphify`)
now register the MCP server automatically** (HIMMEL-1047) — `setup.sh` at
`user` scope, `adopt.sh` at its `--scope` — so the install delivers the
`mcp__graphify__*` tools, not just the CLI. Registration is idempotent (skips
when graphify is already registered). The entry point is **scope-dependent**:
`user`/`local` (a personal config) registers the **absolute** path — robust in
the MCP launch context, and the form `/himmel-doctor` expects (it flags
PATH-fragile bare entries); `project` (a committed `.mcp.json`) registers the
**bare** name so the path stays portable across teammates' machines.

To register (or re-register) manually — the shared implementation, same as the
installers call — pass the scope explicitly (`user` or `project`, not both;
`[user|project]` below is a placeholder):
`bash scripts/lib/graphify-bin.sh register-mcp user`. For `user`/`local` it
resolves the entry point from the directory `uv tool dir --bin` reports
(usually `~/.local/bin` on Linux/macOS; on Windows the executable is copied
there as `graphify-mcp.exe`). The raw equivalent (user scope):

```bash
claude mcp add --scope user graphify -- "$(uv tool dir --bin)/graphify-mcp"
```

(PowerShell:
`claude mcp add --scope user graphify -- "$(uv tool dir --bin)\graphify-mcp.exe"`.)

Claude Code is the only agent graphify needs — the MCP registration above is
the whole integration (no codex/other-CLI prerequisite).

**Windows + WSL on one machine share ONE graph store.** Graph extraction is
LLM-backed (real spend), so the WSL side must not regenerate what the Windows
side already extracted. The store (`~/.graphify/` — plain JSON, no
sqlite/WAL hazard) is shared automatically: `graphify_install` on WSL
symlinks `~/.graphify` at the Windows user's store — only when that Windows
store exists (manual: `bash scripts/lib/graphify-bin.sh share-store`). Both
sides then read AND contribute to the same graphs. A WSL store that already
has content is never replaced or auto-merged into the Windows one — how to
merge pre-existing WSL data is your call.

Graph refresh stays lean-invoke (`graphify <corpus-copy> --update`), never
a hook; extraction backends are governed by the egress matrix — see the
graphify section in `CLAUDE.md`.

### Optional integrations

> **Skip** if you don't use the Luna vault or Atlassian (Jira/Confluence). Both entries here are optional integrations.

Configure in Claude Code settings (`~/.claude/settings.json`):

- **obsidian-vault**: `uvx mcp-obsidian` pointing to Luna vault path
- **atlassian**: Jira/Confluence MCP (requires token)

---

## 8.6. Telegram bridge onboarding (HIMMEL-227)

> **Skip** if you don't use the Telegram bridge for sending messages to Claude. This is operator-specific infrastructure; it is not required for any core himmel workflow.

`scripts/setup.{sh,ps1}` step `[7/8]` runs
`scripts/setup/onboard-telegram.{sh,ps1}` — **scaffold-only**, also safe to
run standalone. It:

- creates `~/.claude/channels/telegram/` + a `TELEGRAM_BOT_TOKEN=` `.env`
  template (never overwrites an existing `.env`);
- reports `access.json` (pairing) status. Setup **never writes
  `access.json`** — the allowlist is a prompt-injection surface and the live
  bridge must be restarted by the operator after edits. Create it yourself:
  `{"allowFrom":["<your-telegram-user-id>"]}`;
- **never starts the bridge** (one `getUpdates` owner per token — a blind
  start could 409-conflict a live poller). Bring-up after token + pairing:
  `pwsh -File scripts/telegram/restart-bridge.ps1` (Windows) or
  `bash scripts/telegram/restart-bridge.sh start` (Linux/macOS — HIMMEL-2176's
  POSIX twin of the PS1 script). Reboot persistence + full ops:
  [`scripts/telegram/README.md`](../../scripts/telegram/README.md) /
  [`docs/internals/telegram-bridge.md`](../internals/telegram-bridge.md).

To find the ids for `access.json` without guessing, run
`bun scripts/telegram/onboard.ts [--timeout <seconds>]` (default 300s)
**before** bringing the bridge up: it prints a one-time nonce, waits for that
nonce to come back in a Telegram message, then reports the `chat.id` /
`chat.type` / `from.id` it arrived on — the values you hand-copy in. It is a
`getUpdates` consumer itself, so it **refuses to start while a poller is
live** (the same one-owner-per-token rule); stop the bridge first
(`bash scripts/telegram/restart-bridge.sh stop`, or
`bun scripts/telegram/supervisor.ts --kill`) if it is already running. Like
the rest of setup it **never writes `access.json` itself**. Full walkthrough:
[`scripts/telegram/README.md`](../../scripts/telegram/README.md).

## 8.7. Uninstall / offboard (HIMMEL-227)

`scripts/uninstall.{sh,ps1}` is the symmetric teardown of setup +
install-plugins. Run it through the wizard — `node scripts/himmelctl/bin.js
uninstall` — which adds its own one confirm then execs the script below with
`--yes`/`-Yes` (see §4); or invoke the script directly. **Destructive and
fail-closed**: interactive runs prompt; non-interactive runs abort without
`--yes`/`-Yes`. Preview first:

```bash
bash scripts/uninstall.sh --dry-run
```

Steps: (1) stop the telegram bun bridge (`bun supervisor.ts --kill`),
(2) remove telegram pairing + bridge state (`~/.claude/channels/telegram/`
incl. token + `access.json`, `~/.claude/handover/bridge/`) — local delete
does NOT revoke the bot token; revoke via @BotFather when decommissioning,
(3) remove `HIMMEL-Resume-*` scheduled jobs + the `HimmelTelegramBridge`
logon task, (4) uninstall the settings-template plugins + marketplaces via
`scripts/machine-setup/uninstall-plugins.{sh,ps1}` (**user-scope — affects
every repo on the machine**), (5) `pre-commit uninstall` ×3 hook types,
(6) unwire `~/.claude/settings.json` — remove the statusLine, `env.HIMMEL_REPO`,
`env.LUNA_VAULT_PATH`, and the UNIVERSAL hooks that setup/adopt wired (each
helper removes ONLY its own key/stanza; non-himmel keys — your own hooks, MCP
config, the rtk guard — are preserved; HIMMEL-460). Partial offboard via
`--keep-telegram-state` / `--skip-plugins` / `--skip-tasks` / `--skip-hooks` /
`--skip-settings` (PS: `-KeepTelegramState` etc.). Not touched: the himmel
clone + `.env`, your non-himmel `~/.claude/settings.json` keys, handover
state outside the bridge root.

---

## 9. Verification Checklist

### CORE — required for any adopter

- [ ] `rtk --version` works
- [ ] `pre-commit run --all-files` passes in himmel
- [ ] Claude Code loads and hooks fire (run any command; check no hook errors appear)
- [ ] Worktree round-trip: `/worktree test/smoke` creates a worktree; `/clean` removes it after merging

### OPTIONAL — per integration

**tokensave (recommended):**
- [ ] `tokensave --version` works
- [ ] `tokensave doctor` passes
- [ ] `.tokensave/` exists in the repo (`tokensave init` ran) and a fresh session lists the `tokensave` MCP server as connected

**graphify:**
- [ ] `graphify --version` works and a fresh session lists the `graphify` MCP server as connected

**Jira / HIMMEL project:**
- [ ] `node scripts/jira/dist/index.js list` returns HIMMEL issues

**Luna vault:**
- [ ] `pre-commit run --all-files` passes in Luna vault
- [ ] `/obsidian-daily` creates today's note in Luna

**Luna cadence (only if `pipeline` was armed in the wizard's cadences question):**
- [ ] `node scripts/himmelctl/bin.js status --items cadence-armed,engine-allowlist,luna-sources` reports `green`/`n/a`, not `red`

**Telegram bridge:**
- [ ] Bridge responds to a test message sent from Telegram
- [ ] (only if bridge persistence was installed) `node scripts/himmelctl/bin.js status --items bridge-persistence,bridge-health` reports `green`/`n/a`, not `degraded`

---

## `core.hooksPath` gate (HIMMEL-105)

Both machine-setup scripts (`ubuntu.sh`, `win11.ps1`) gate the post-clone
flow on `git config --get core.hooksPath` being either unset OR set to
an existing path inside the himmel working tree. If neither holds, setup
aborts before `pre-commit install` runs.

Why: in HIMMEL-45 the repo on disk was renamed `yotam_internal` → `himmel`,
but the `.git/config` was copied with the old hard-coded `core.hooksPath`
absolute string. Git silently skipped every pre-commit and pre-push hook
for an unknown duration (`no-push-to-main`, `npm-audit`, `npm-licenses`,
`code-review-before-push`, `platforms-tested`). PR #100 (HIMMEL-98) caught
it manually mid-overnight. This gate prevents recurrence.

The same script (`scripts/hooks/check-hookspath.sh` / `.ps1`) is wired in
three other places:

1. `.pre-commit-config.yaml` pre-commit stage — every commit fails if
   misconfigured.
2. Claude Code `~/.claude/settings.json` SessionStart array — prints a
   one-line warning when a session starts on a misconfigured repo.
   Non-blocking. The shared `docs/setup/settings-template.json` does
   NOT carry this entry; instead each platform setup script appends
   the right interpreter sibling so a Windows machine without Git Bash
   (or a Linux machine without pwsh) doesn't get a "command not found"
   line every session start. `scripts/machine-setup/win11.ps1` appends
   the `pwsh` entry; `scripts/machine-setup/ubuntu.sh` appends the
   `bash` entry.
3. The smoke test at `scripts/hooks/test-check-hookspath.sh` covers
   eleven cases: unset, set-inside-repo (absolute + relative), set-but-
   missing, set-outside-repo, bypass-via-env, outside-any-git-repo,
   linked worktree pointing at primary git-common-dir, outside-both-
   worktree-and-git-common-dir, Windows-drive-relative, and Windows
   mixed-case absolute prefix (case-insensitive NTFS).

### Existing machines (not freshly cloned)

The machine-setup scripts patch `~/.claude/settings.json` on every run, so
the SessionStart entries land automatically. If you have an EXISTING
`~/.claude/settings.json` you don't want re-patched, copy ONE of the
following fragments manually into the `SessionStart[0].hooks` array
(replacing `<himmel-path>` with the absolute path to your himmel clone) —
pick the interpreter that's actually on PATH on this machine:

Linux / macOS / Windows-with-Git-Bash:

```json
{
  "type": "command",
  "command": "bash \"<himmel-path>/scripts/hooks/check-hookspath.sh\"",
  "shell": "bash",
  "timeout": 10
}
```

Windows-with-pwsh:

```json
{
  "type": "command",
  "command": "pwsh -NoProfile -File \"<himmel-path>/scripts/hooks/check-hookspath.ps1\"",
  "shell": "powershell",
  "timeout": 10
}
```

### Intentional bypass

If you have a legitimate reason to point `core.hooksPath` outside the repo
(running a custom hook manager, e.g. lefthook, husky-in-parent-dir), set:

```
HOOKSPATH_OK=1 git commit ...
HOOKSPATH_OK=1 bash scripts/machine-setup/ubuntu.sh ...
```

Session-sticky: the env var must be set in the shell that launches the
operation; it cannot be injected per-call by Claude. To restore the gate,
unset the variable and re-launch.

The SessionStart hook has NO bypass — it is non-blocking, the printed
warning IS the affordance.

### Manual repro (verify the gate works)

```bash
# Inside a himmel clone:
git config core.hooksPath /tmp/nope
git commit --allow-empty -m "should be blocked"
# Expect: exit nonzero, "⛔ check-hookspath: core.hooksPath points
# at a path that does not exist" in stderr, no new commit created.
# (The pre-commit framework invokes the bash sibling, which uses ⛔.
# The pwsh sibling — triggered from Claude SessionStart on Windows —
# uses the [BLOCK] prefix instead, same semantics.)
git config --unset core.hooksPath
```
