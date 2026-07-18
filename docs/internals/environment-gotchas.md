# Environment & tool-delivery gotchas

Platform and harness-tool traps that bite when running himmel — especially on
Windows — or when authoring himmel shell scripts. These are generic (no
machine-specific config); they reproduce on any WSL-enabled Windows box, any
bash-5.1+ environment, or any Claude Code session. The Codex-specific hook
wiring trap lives in [`harness-compat.md`](harness-compat.md); guardrail-recovery
escape hatches live in [`stuck-playbook.md`](stuck-playbook.md).

## Windows: bare `bash` resolves to the System32 WSL stub

On a WSL-enabled Windows box, a bare `bash` — from PowerShell, `& bash` in a
`.ps1`, or any tool shelling out — resolves to `C:\WINDOWS\system32\bash.exe`,
the **WSL launcher**, NOT Git Bash. WSL bash cannot read `C:\…` / `C:/…` paths →
it errors `No such file or directory` and exits **127** on a Windows-style script
path (it would need `/mnt/c/…`). `Get-Command bash` confirms the source.

Resolve Git Bash explicitly anywhere a `.ps1` or PS command shells out to a bash
script:

```powershell
$gitBash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path $gitBash)) {
    $bc = Get-Command bash -ErrorAction SilentlyContinue
    $gitBash = if ($bc -and $bc.Source -notmatch 'System32') { $bc.Source } else { $null }
}
& $gitBash "C:/path/to/script.sh" arg1 arg2
```

The `-notmatch 'System32'` clause is the key — it rejects the WSL stub on the
fallback path. Operator hand-off commands that call bash on Windows must use the
full Git Bash path `& "C:\Program Files\Git\bin\bash.exe" …`. (This is the same
stub Codex's hook wrapper has to skip — see `harness-compat.md`.)

## Windows WSL / Docker resource budget

WSL2 and Docker Desktop share the Windows host's CPU, memory, disk IO, and page
cache. They are isolation boundaries, not extra machines. On a multi-agent run,
an unbounded WSL distro plus unbounded Docker containers can starve the host,
Claude/Hermes, editors, browsers, and VirtualBox/e2e VMs.

Operational default for himmel on Windows:

1. **Use Git Bash for the control plane.** Run himmel scripts, Jira, handover,
   PR/check orchestration, and Hermes/Claude launchers from native Git Bash unless
   the task specifically needs Linux kernel semantics or a container.
2. **Cap WSL globally.** Put a conservative `%UserProfile%\.wslconfig` in place
   before using WSL for agents:

   ```ini
   [wsl2]
   memory=16GB
   processors=8
   swap=4GB
   localhostForwarding=true
   ```

   Tune the numbers to the host, but keep real Windows headroom. On a 48 GB / 32
   logical-core workstation, start around 16 GB and 8 processors for WSL; raise
   only after measuring. Apply changes with `wsl --shutdown`.
3. **Cap Docker separately.** Docker Desktop can run through WSL2 and still needs
   its own budget. Prefer Docker Desktop resource limits when available, and add
   per-container caps for agent/build jobs: `--cpus`, `--memory`, Compose
   `deploy.resources`/service limits where supported. Do not run unbounded
   `docker compose up` stacks while also fanning out agents.
4. **One heavy substrate at a time.** For parallel agents, pick the substrate:
   native Git Bash worktrees OR WSL shells OR Docker containers. Mixing all three
   is allowed only with explicit caps and a lower fan-out.
5. **Reserve non-negotiable lanes first.** VirtualBox/e2e VMs, the Windows host,
   the editor/browser, and MCP servers get headroom before agent workers. This is
   the same reservation model as the machine-aware concurrency ADR.
6. **Make profile selection explicit.** Hermes invocations launched from this repo
   should pass the intended profile (`--profile himmel_agent` on the operator's
   current machine; adopters use their own profile) so a WSL shell, Docker shell,
   or native Git Bash shell cannot silently select a different default profile.

Rule of thumb: if CPU stays above ~85%, free RAM drops below ~8 GB, or the host UI
starts lagging, stop spawning and shrink the substrate cap before retrying. Do not
solve host pressure by adding more agents.

## WSL: `wsl.exe` invoked from Git Bash mangles `/mnt` args

Calling `wsl.exe` from a Git Bash session puts every argument through MSYS path
conversion first: `/mnt/c/...` looks like a POSIX absolute path, so MSYS
rewrites it to `C:\msys64\mnt\c\...`-style Windows paths before `wsl.exe` ever
sees it — the command then fails inside the distro on a path that doesn't
exist. Measured live during the HIMMEL-939 eval (win2, 2026-07-12).

Prefix the call with `MSYS_NO_PATHCONV=1`:

```bash
MSYS_NO_PATHCONV=1 wsl.exe -e bash -c 'ls /mnt/c/Users'
```

For `/`-prefixed argument *fragments* that are not standalone paths (flags like
`/tmp/x:/y` mappings, or args where only part is a path), `MSYS_NO_PATHCONV=1`
alone may not cover it — add `MSYS2_ARG_CONV_EXCL='*'` to exclude everything
from conversion. In-repo precedent: `scripts/cr/coderabbit-review.sh:151`
(the CodeRabbit WSL lane, HIMMEL-926).

## WSL: the /mnt/c performance cliff

WSL processes operating on a Windows checkout through `/mnt/c` are not "a bit
slower" — they are the **worst possible configuration**, slower than Git Bash
itself. Measured on the himmel repo (win2, 2026-07-12, HIMMEL-939 eval):

| operation | Git Bash (C:\ checkout) | WSL on `/mnt/c` | WSL on ext4 clone |
|---|---|---|---|
| `git status` | 89–142 ms | **4,290–18,839 ms** | 27 ms (warm) |
| `grep -r` over `scripts/` | 397–480 ms | 4,438–4,472 ms | 24–26 ms |

That is a 30–130× `git status` penalty vs Git Bash, and up to ~700× vs a
WSL-native clone. The 9P filesystem bridge pays per-file round-trip costs that file-heavy
tools (git, grep, build systems) multiply by thousands. The rule, from the
Microsoft filesystem guidance and confirmed by these numbers: **work must live
on the filesystem native to the executing side.** WSL work ⇒ ext4 clone
(`~/...` inside the distro); never route file-heavy WSL commands at `/mnt/c`.
Fork-heavy-but-file-light work (subshell/pipeline benchmarks) is fine either
side — the cliff is filesystem IO, not process spawn.

## WSL: himmel hooks fail closed when the distro lacks the toolchain

himmel's Claude hooks parse their JSON stdin with `jq` and **fail closed** —
a missing `jq` reads as "cannot verify, refuse". In a bare WSL Ubuntu (no
toolchain provisioned), `block-destructive-commands.sh` refused in 240 ms
during the HIMMEL-939 eval: fast, silent, and every guarded operation is
blocked, which presents as "hooks are broken under WSL" when the actual
problem is a missing binary.

A WSL lane or WSL station therefore needs the toolchain **provisioned
in-distro** (`jq`, `node`, `gh`, `bun`, … — `scripts/machine-setup/ubuntu.sh`
is the base), not just bash. The Windows-side installs are invisible to the
distro; Windows interop only exposes `.exe` binaries, and the hooks invoke
plain `jq`/`node`.

## Windows: `python3` / `python` may be the WindowsApps Store stub

On a box with no classic CPython install, `python3` and `python` resolve to the
Microsoft Store WindowsApps stub (`PythonSoftwareFoundation.PythonManager`). The
stub can **wedge machine-wide**: it ignores `SIGTERM` (so GNU `timeout` without
`-k` waits forever, and its orphan child holds inherited stdout pipes so `$(…)`
command substitution blocks even after a kill), and has been observed to then
fail with "The specified disk or diskette cannot be accessed (os error 26)".

Mitigations for scripts that must call `python3`:

- Install a real interpreter (e.g. `uv python install 3.12`) and shim a wrapper
  dir onto `PATH` for test runs.
- Always wrap with `timeout -k 5 10` (the `-k` is mandatory) **and** redirect
  stdout to a file, never command substitution.

## Claude Code Bash tool strips one backslash level vs a `.sh` file

Verifying backslash-sensitive code (sed replacements, regex normalization) by
running a one-liner **through the Bash tool** is unreliable: the tool's command
delivery strips one backslash level that the same code in a written `.sh` **file**
keeps. A form that is correct in a file can look broken when poked via a Bash-tool
one-liner, and vice-versa — this has produced false-positive "Critical" review
findings where the original file form was actually correct.

Rule: never trust a Bash-tool one-liner to validate backslash counts. Write the
snippet to a real `.sh` file and run that, or rely on the script's test suite, and
add a regression test that pins the emitted pattern plus a match so the correct
form can't later be "fixed" wrong. A reviewer's shell reproduction of a backslash
bug is suspect — re-verify in-file.

Sibling MINGW gotcha: `grep -iF` aborts (SIGABRT, rc 134) on the `-i`+`-F`
combination even on pure ASCII input. Use `-F` alone.

## Windows: `graphify install` writes a backslash exe path that dies under Git Bash (Claude hooks)

`graphify install` (graphifyy ≤ 0.9.18) writes hook commands whose executable is
an absolute **Windows path with backslashes** — e.g.
`C:\Users\<you>\.local\bin\graphify.EXE hook-guard search` — into the harness hook
configs. Whether that breaks depends on the shell each harness runs hook commands
through on Windows, which **differs by harness** — so "fix it everywhere the same
way" is wrong:

- **Claude Code runs hook commands through bash** (Git Bash). Bash consumes the
  backslashes, so the command collapses to `C:Usersyou.localbingraphify.EXE` →
  `command not found`, and the hook fails on **every** Bash/Read/Glob call. It is
  *non-blocking*, so the only symptom is a repeated `PreToolUse hook error …
  command not found` line and the graph-context injection silently never firing.
  **This is the breakage you actually observe.**
- **codex and gemini run hook commands through cmd.exe**, not bash — codex via its
  `.codex/run-hook.cmd` cmd wrapper (whose own comments note "bare `bash` via
  cmd.exe hits the WSL System32 stub"), gemini-cli via Node's default Windows
  shell. cmd.exe does **not** eat backslashes, so `C:\Users\…\graphify.EXE …` runs
  there unchanged — the codex/gemini graphify hooks are **not** broken by the
  backslash path. Do **not** "fix" them by copying Claude's MSYS `/c/…` form: see
  the verification below.

Root cause is upstream: `graphify/install.py::_resolve_graphify_exe()` returns
`shutil.which("graphify")` (a backslash path) and the hook builders interpolate it
**unquoted** (`f"{exe} hook-guard search"`; the gemini builder quotes only when the
path contains a space). The in-code "#522 fix" comment ("parses under sh, cmd.exe
and PowerShell alike") does not hold for Windows + a POSIX hook shell.

**Fix — use the forward-slash Windows path, the one form that works in every
executor:** `C:/Users/<you>/.local/bin/graphify.exe hook-guard search`. Verified on
this host: in **bash** both `/c/Users/…` (MSYS) and `C:/Users/…` run; in **cmd.exe**
only `C:/Users/…` runs — the MSYS `/c/…` form returns "the system cannot find the
path specified". So the MSYS `/c/…` form fixes Claude but **breaks** a cmd.exe
harness (codex/gemini); the forward-slash `C:/…` form is universal. Affected
configs: `.claude/settings.json`, `.codex/hooks.json`, `.gemini/settings.json`
(and `~/.claude/settings.json` if installed globally).

**Quote the exe if its path contains a space.** Removing backslashes is not enough
when the path itself has a space — e.g. `C:/Users/Jane Doe/.local/bin/graphify.exe`
— because the command runs through a shell that word-splits an unquoted string
(bash splits on the space; cmd.exe treats `C:/Users/Jane` as the program). Wrap the
executable in quotes inside the command value (JSON-escaped, e.g.
`"\"C:/Users/Jane Doe/.local/bin/graphify.exe\" hook-guard search"`), or install
graphify to a space-free path.

Re-install caveat: 0.9.18 `graphify install` (claude) no longer writes
settings.json hooks (skill + CLAUDE.md + version-stamp refresh only), so a fixed
Claude hook survives re-install — but `graphify codex install` / `graphify gemini
install` still re-emit the backslash path (harmless under cmd.exe, but re-normalize
to the `C:/…` form for consistency + space-safety). A durable himmel-owned
post-install path-normalizer is tracked in HIMMEL-1168.

Upgrade gotcha: `uv tool upgrade graphifyy` from **inside** a live session running
the graphify MCP server + hooks can leave the `graphify` CLI shim unwritten — a
Windows file-lock on the venv `Scripts\` dir (`Access is denied`) — while `uv tool
list` still reports the new version. Repair from a context where `graphify-mcp` is
not running: stop those processes, then `uv tool install "graphifyy[all]" --force`.

## bash 5.1+ treats a literal `&` in `${var//pat/repl}` as the matched text

In a parameter-expansion replacement, bash 5.1+ expands a literal `&` to the
matched text:

```bash
s="${s//</&lt;}"   # yields "<lt;", NOT "&lt;" — the & became the matched "<"
```

So a naive `${//}`-based XML/HTML escaper is silently broken on bash 5.1+, and the
`&`→`&amp;` step only looks right by accident (its match *is* `&`). Pre-5.1 bash
(including the macOS 3.2 baseline) treats `&` literally, so the bug is
version-dependent — it passes on one platform and corrupts on another.

Escape with `sed`, where `\&` is an unambiguous literal ampersand on every
version, and run the `&` rule first so the entities it introduces aren't
re-escaped:

```bash
printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
```

Pin it with a unit test (e.g. `'a & b < c > d'` → `'a &amp; b &lt; c &gt; d'`).

## Windows: `schtasks /create /xml` rejects a UTF-8 prolog

`schtasks /create /xml` rejects an `encoding="UTF-8"` XML prolog with
`"(1,40):: unable to switch the encoding"`. Declaring `encoding="UTF-16"` over
plain-ASCII bytes is accepted. So: write the task XML ASCII-only and declare
UTF-16 (a genuinely non-ASCII value would need a real UTF-16LE+BOM file). The
reason to use `/xml` at all is that `schtasks /create` has no flag for
`StartWhenAvailable` (run a missed scheduled start when next available) — the only
CLI route to that setting is `/create /xml`.

## macOS: qmd's `ggml_metal_library_init_from_source` error is benign noise

On macOS (Apple Silicon), every `qmd embed` / `qmd vsearch` prints
`[node-llama-cpp] ggml_metal_library_init_from_source: error compiling source`
even though GPU embedding **succeeds** (verified on an M5: 423 chunks / 144
docs embedded in 28s right after that line). It reads like a hard failure to
a fresh adopter; it is not — treat it as benign unless the embed itself
errors or hangs. For genuine Metal problems, the underlying
node-llama-cpp/ggml backend exposes a `GGML_METAL_NO_RESIDENCY` residency
knob (per the issue-#276 report; macOS-native layer). Reported on the
fresh-machine adopt run in public issue #276 (G6, HIMMEL-752); the message
is emitted by qmd's upstream node-llama-cpp, so himmel documents it rather
than suppressing stderr (a blanket filter would hide real errors).

## Anthropic output content-filter trips on policy text and minified blobs

The 400 "Output blocked by content filtering policy" error scans the model's
**generated** output. Two things trip it during OSS / community-health work:

1. **Generating Code-of-Conduct / anti-harassment policy text.** Documents like
   the Contributor Covenant enumerate prohibited behaviors (harassment, abuse,
   sexualized language) — a dense cluster of exactly the flagged-category
   vocabulary the filter watches, so writing the policy reads like the content it
   blocks.
2. **Large minified / obfuscated blobs in context** (e.g. a vendored plugin
   `main.js`) — high-entropy payloads read as possible malware.

Workarounds:

- For standard policy docs, **download instead of generate**:
  `curl -fsSL <canonical-url> -o CODE_OF_CONDUCT.md`, then `sed` any placeholder.
  The content lands on disk, never through model output. Don't `cat` it back —
  keep the trigger text out of context for later turns (verify with `grep`/`wc`).
- For code review over vendored bundles, feed reviewers a scoped diff that
  excludes minified js/css and any downloaded policy file.
- It's intermittent (a per-turn classifier threshold) — in an interactive
  terminal a blocked turn is usually transient and re-sending succeeds.

## Claude Code: the safeguards refusal-fallback swaps to the bare fallback model — dropping the `[1m]` suffix

Distinct from the output content-filter above: when a safeguards refusal fires
(`model_refusal_fallback` in the transcript, e.g. an `apiRefusalCategory` of
`cyber` false-positiving on routine agent-harness code), Claude Code switches
the session to a fallback model — and the fallback map picks the **bare** model
id, never the `[1m]` long-context variant. A session running a `[1m]` model
drops to the fallback's plain 200k window; a context already past 200k then
overflows the new window → `<synthetic>` API errors → an unattended/armed
session stalls mid-queue, with no unattended automatic recovery path if
auto-compact is off.

Mitigations:

- **Keep `autoCompactEnabled: true`** for any session leg that runs a `[1m]`
  model unattended — auto-compact is the only automatic recovery path after
  the drop.
- **Delegate drop-risk reads to a subagent.** Content that routinely trips
  safeguards — CI/build failure logs (`gh run view --log-failed`),
  security-scan output, flagged or adversarial code — should be read by a
  subagent whose distilled summary the parent consumes. A model drop then
  costs a disposable child, never the parent loop's accumulated context.
- After any unattended-session stall, grep the transcript for
  `model_refusal_fallback` before blaming the arm environment — refusal flags
  on routine harness code are typically false positives.

## Windows: pre-commit auto-fixers crash on non-ASCII filenames (and mangle the file first)

The pre-commit-hooks `trailing-whitespace` and `end-of-file-fixer` fixers print
the path of each file they touch (e.g. trailing-whitespace's
`print(f'Fixing {filename}')`). On Windows that
`print` goes to a cp1252-encoded stdout, so a filename containing non-ASCII
characters — Hebrew/CJK/accented source notes, common in luna / Salus medical
vaults — raises `UnicodeEncodeError: 'charmap' codec can't encode…` and the hook
exits non-zero. **Worse: the fixer rewrites the file (strips trailing whitespace
across the whole file) *before* it prints, so the abort leaves a silent
whitespace-only diff** — a 217-page verbatim extraction once produced a 20k-line
diff that had to be manually restored.

Two independent mitigations:

- **Repo-config (preferred, inherited):** don't let the auto-fixers run on
  non-code files at all. In a content repo (a vault), notes and ingested sources
  are user data — pre-commit should validate them (gitleaks/check-*) but never
  rewrite them. Constrain both fixers to an ASCII-named code/config **allowlist**
  rather than a denylist (a denylist can't enumerate every non-ASCII name a vault
  might hold):

  ```yaml
  - id: trailing-whitespace
    files: '\.(sh|ps1|yaml|yml|json|toml)$'
  - id: end-of-file-fixer
    files: '\.(sh|ps1|yaml|yml|json|toml)$'
  ```

  This is what the luna-second-brain template ships (HIMMEL-615). pre-commit has
  **no per-hook `env:` key**, so encoding can't be forced from the config itself.
- **Machine env (defense-in-depth, for code repos where the fixers must run on
  arbitrary paths):** export `PYTHONUTF8=1` (or `PYTHONIOENCODING=utf-8`) in the
  shell that runs `git commit`, which forces every Python hook to a UTF-8 stdout
  and stops the crash. Note this only prevents the *crash* — the fixer still
  rewrites the matched file, so it's not a substitute for the allowlist when the
  rewrite itself is unwanted.

## rtk token-proxy rewrites top-level Bash-tool commands

If you run [rtk](../setup/rtk-md.md) as a Claude Code PreToolUse rewrite hook, be
aware it rewrites **top-level** Bash-tool commands (not commands inside a script
file). Notably `git diff` becomes a compressed stat summary rather than a unified
diff, and `grep`/`cat`/`tail` with a file redirection can write rtk's summary text
into the target file. Get a real unified diff with `rtk proxy git diff …`; never
redirect an rtk-intercepted command into a file that matters (use the Read/Write/
Edit tools or run the pipeline inside a script file); and verify any file produced
by a top-level pipeline before trusting it. The benign `[rtk] /!\ No hook installed`
banner under himmel's guard wrapper is covered in
[`enforcement.md`](enforcement.md).

## Windows: `schtasks /create /sd` parses the date in the MACHINE's regional format

The same arm command lands months away on a machine with different locale
settings — a same-day `/sd` date written as MM/DD parses as DD/MM on a
DD/MM-locale machine (observed: a 03:20 same-day task landing three months
out; the task sits `State=Ready`, `LastRun=never`, result `267011` /
`SCHED_S_TASK_HAS_NOT_RUN` — a silent no-launch). After ANY scheduled-task
creation on a machine not yet proven, verify
`(Get-ScheduledTaskInfo <name>).NextRunTime` is the intended datetime — never
trust the creation SUCCESS message.

`arm-resume.sh` is now structurally guarded against this (HIMMEL-938): its
Windows path reads `HKCU\Control Panel\International\sShortDate` and renders
`/sd` in the machine's own pattern (falling back to the old hardcoded
`MM/dd/yyyy` on any registry-read failure), then runs the
`Get-ScheduledTaskInfo` check above after every create — a mismatch beyond a
120s tolerance (or a missing/null `NextRunTime`) deletes the just-created task and refuses
(rc=2) instead of leaving a silent months-out arm. Any OTHER hand-rolled
`schtasks /create /sd` call outside `arm-resume.sh` remains exposed to this
trap (and remains forbidden — go through `arm-resume.sh`).

## MSYS `/tmp` is the Windows user temp dir — temp cleaners delete it under you

In Git Bash, `/tmp` maps to `%LOCALAPPDATA%\Temp`, which Windows Storage Sense
(and other temp cleaners) prune on their own schedule. Anything long-lived
placed there — a git worktree, a patch you plan to apply later — can vanish
mid-flow, leaving `git -C` failing "No such file or directory" plus a dangling
worktree record. Keep work products in the session scratchpad or a home-dir
path, finish flows that stage in `/tmp` in the same sitting, and remember
PowerShell and Windows-native node cannot see MSYS paths — `cygpath -m`
first, or parse JSON files under `/tmp` with `jq` rather than a node
one-liner in Git-Bash pipelines. (`git worktree prune` cleans up the
dangling record afterward.)

## A pruned git worktree directory silently falls through to the PRIMARY repo

When a worktree's admin data is pruned (the `.git` link file and
`.git/worktrees/<name>` removed) but the directory itself survives with files,
any `git -C <dir>` / `cd <dir> && git …` walks UP, finds the primary repo's
`.git`, and runs against the PRIMARY repo — with no error. Red flags:
`status --short` paths prefixed `../../`, the primary's commits in `log`,
`stash push` reporting "No local changes", `merge --ff-only` reporting
"Already up to date". Detect with `git rev-parse --show-toplevel` (must equal
the worktree dir). Habit: before multi-step git surgery in a worktree, capture
`git diff --cached > <scratchpad>/patch` first — if a concurrent prune hits,
the patch is the only thing that survives. (HIMMEL-849 tracks a prune guard.)

## MSYS mangles `git show "rev:.dotfile"` — read dotfiles by blob SHA

Paths starting with `.` in a `rev:path` spec get MSYS path-mangled and the
command SILENTLY returns empty — a grep pipeline over it false-negatives.
Read the blob directly instead: `git ls-tree <rev> -- <path>` →
`git cat-file -p <sha>`; for drift detection compare `ls-tree` blob SHAs.
`MSYS_NO_PATHCONV=1` is unreliable inside `<(…)` substitutions.

## Git-Bash `timeout` does not reap grandchildren holding a `$()` pipe

Under Git Bash, `timeout` kills its direct child, but a grandchild (a `sleep`,
a `curl`) inheriting the command-substitution pipe keeps `$(…)` blocked past
the timeout — the caller hangs and the process leaks. In test stubs, `exec`
the long-running command (`exec sleep 30`) so the timeout target IS the
process holding the pipe; in scripts, avoid `$(timeout … cmd-that-spawns)`
shapes.

## `sed '/<!--/,/-->/d'` swallows the file body on single-line comments

A one-line `<!-- … -->` opens the range but sed only tests the closing
address on LATER lines, so the range runs to the next `-->` or EOF — deleting
real content and making downstream guards vacuously pass. Strip inline spans
first (`sed 's/<!--.*-->//g'`), then range-delete; pair any such guard with a
red-path test plus a non-vacuousness assertion.

## pre-commit shellcheck crashes when a finding must print a non-ASCII line

Under a non-UTF-8 locale, shellcheck exits 2 with `commitBuffer: invalid
argument` whenever it must PRINT a line containing an em-dash/emoji as part of
any finding — even info-level. Keep lines that carry non-ASCII characters
finding-free (no backticks-in-quotes etc.), or add a targeted
`# shellcheck disable=SCxxxx`. Local verify with `shellcheck -f gcc <file>`
(one-line output format dodges the crash).

## Claude Code: a background Bash task snapshots the FOREGROUND cwd at launch

`run_in_background` Bash commands inherit the foreground shell's cwd as of
launch time. In a multi-worktree session the foreground cwd drifts with every
`cd <worktree> && git …`, so a background job touching more than one repo must
`cd` explicitly before EVERY step — never rely on the launch cwd. Sanity-check
that any background review/analysis output cites paths from the intended diff
before acting on it; a silent wrong-branch review is the failure mode.

## Windows: the 1Password SSH agent breaks unattended runs

With 1Password's SSH agent enabled, it hijacks the `\\.\pipe\openssh-ssh-agent`
named pipe and pops a GUI authorization prompt on every signature — fatal to
any unattended/scheduled session that shells out over SSH. Fix: 1Password →
Settings → Developer → untick "Use the SSH agent" (the setting is
integrity-signed; GUI-only), then re-enable the stock agent elevated:
`Set-Service ssh-agent -StartupType Automatic; Start-Service ssh-agent`.
Only native Windows `ssh.exe` hits the pipe — paramiko-based tooling and git
SSH signing via `ssh-keygen.exe` are agent-free. Verify with the native
`ssh-add -l`, not the MSYS one.

## PowerShell 5.1: three silent script-killers fixtures can't catch

Windows PowerShell 5.1 (the OS default that runs hooks and scheduled scripts)
has three traps that parse clean and only fail — or worse, silently no-op —
on the live code path:

- **Read-only automatic variables.** Assigning `$pid` or `$home` throws
  `VariableNotWritable` at runtime, only when that line executes. Use
  distinct locals (`$treePid`, `$userHome`).
- **Dot-sourcing binds params in the CALLER's scope.** `. other.ps1
  -AsLibrary` can clobber a caller variable of the same name — observed
  flipping an early-return guard so the main body never ran (exit 0, no
  output, nothing to debug). Capture such flags into a distinct local
  before any dot-source.
- **`$x = if (cond) {…} else { @() }` assigns `$null`, not `@()`** when the
  taken branch is the empty-array one; a downstream `[Parameter(Mandatory)]`
  bind then fails "because it is null". Wrap the whole conditional:
  `$x = @(if (cond) {…} else {…})`.

Fixture/unit tests miss all three: they pass explicit non-null args or
dot-source directly, so the script-scope + omitted-param code paths never
execute. Require ONE live `powershell -File` run on Windows before trusting
green tests for any `.ps1` destined for exporters or hooks. Cheap review
heuristic: grep new/changed `.ps1` for assignments to
`$pid|$home|$input|$args`, dot-sources below a `param()` block, and `= if (`
with an empty-array branch.

## Windows: `ssh` into a Windows host lands in cmd — multi-line PowerShell needs `-EncodedCommand`

OpenSSH on a Windows target defaults the remote shell to `cmd`. Wrap
one-liners in `powershell -NoProfile -Command "…"`. For MULTI-LINE scripts,
do NOT pipe stdin into `powershell -Command -` — its stdin reader can
silently stop after the first line of multi-line ForEach/try-catch blocks,
with no error. Use `-EncodedCommand` with a UTF-16LE, base64-encoded payload
instead — robust across every quoting layer. Never add
`-ExecutionPolicy Bypass`: the flag sets the policy for the whole
`powershell.exe` session (it is not `-File`-only), an inline
`-Command`/`-EncodedCommand` payload doesn't need it, and it reads as a
security bypass to auto-mode classifiers.

Nested hops multiply the quoting problem: `ssh → cmd → wsl → bash` mangles
inline `$` (a `$HOME` arrives literal). Base64 the bash payload and run
`echo <b64> | base64 -d | bash`. Detach long remote jobs with explicit
stream redirection — `setsid … </dev/null >job.log 2>&1 &`. Bare
`nohup … &` only auto-redirects when attached to a TTY, so over ssh's
non-TTY pipes those streams stay wired to the channel and a drop can still
kill or hang the job; redirect all three explicitly.

## Windows: a scheduled-task-hosted service can be DOWN while its task reads "Ready"

Services hosted as scheduled tasks (a Grafana under an `-AtLogOn` task, a
metrics exporter) fail in ways task state doesn't show:

- **"Ready" means idle, not running.** A stopped `-AtLogOn` Grafana looks
  fine in `Get-ScheduledTask`. Before any API call, `Start-ScheduledTask`
  explicitly, then POLL `/api/health` until it returns `database: ok` or a
  bounded deadline (~30s) expires — don't rely on a fixed sleep, since start
  time varies (first start also initializes its sqlite DB) so a fixed wait is
  either too short or wasteful. On timeout, report the task's current
  `Get-ScheduledTask` state alongside the failure. The failure when skipped is
  connection-refused ("Unable to connect to the remote server") — do NOT
  misdiagnose it as an auth/credentials problem.
- **Restart ≠ new code, and task success ≠ serving.** A restart picks up
  whatever code is ON DISK — update the checkout to the target commit
  BEFORE `Stop-ScheduledTask; Start-Sleep 2; Start-ScheduledTask` — and
  verify by the live endpoint
  (`curl -s http://127.0.0.1:<port>/metrics | findstr <new-field>`), never
  by task state: the task can report success while serving stale code.
- **Never string-interpolate a JSON API body.** A PowerShell double-quoted
  string silently blanks literal `${VAR}`-style tokens that dashboard JSON
  legitimately contains (e.g. `${DS_PROMETHEUS}`). Build request bodies
  with `ConvertFrom-Json` → edit → `ConvertTo-Json -Depth 100`.

## WSL git cannot read a Windows-created worktree

A worktree created on the Windows side stores a Windows-style path in its
`.git` pointer file, which WSL-side git cannot resolve — WSL git commands
against that worktree fail (plain file reads still work). Cross-environment
flows that need git on the WSL side (a WSL review lane over a Windows
worktree) need an explicit temp-clone/copy step; never aim WSL git tooling
directly at a Windows-created worktree.

Sibling worktree trap: a gitignored, locally-overlaid config file (a tool
config tuned in the primary checkout) does not exist in a fresh worktree —
the tool silently falls back to the tracked default, resurrecting items the
overlay deliberately disabled. Run such tools from the primary checkout, or
copy the overlay into the worktree first.

## WSL: boot-time bind mounts belong in `/etc/wsl.conf` `[boot]`, not `/etc/fstab`

A bind mount a WSL-hosted service needs at distro start is not reliably up
when declared in `/etc/fstab` (WSL's boot mount-ordering is not what fstab
implies). Put the mount under `[boot]` in `/etc/wsl.conf`
(`command = mount --bind …`) so it runs at distro init.

## git: a branch with no upstream tracking — `git pull` errors, automation reads it as "no update"

A checkout whose branch has no upstream configured (common after a tool-made
clone or history surgery) fails `git pull` with "There is no tracking
information for the current branch" — loud in a terminal, but a wrapper or
cadence job that swallows stderr surfaces it as the repo silently "not
updating". When a repo that should track a remote stays mysteriously stale,
check `git branch -vv` first; fix with
`git branch --set-upstream-to=<remote>/<branch>` using the branch's
configured remote (e.g. `origin/main`).

## qmd: the bun-shim PATH illusion (WSL), expired-session embeds, index sharing

- **"qmd MISSING" is usually a PATH illusion.** qmd runs via a bun-global
  shim, not a `qmd` binary on PATH; the real gap is often `bun` itself.
  Check with `qmd_fork_served` from `scripts/lib/qmd-bin.sh` before
  reinstalling anything. In non-interactive `bash -lc`, `.bashrc` returns
  early BEFORE its bun PATH line — export `BUN_INSTALL="$HOME/.bun"` and
  prepend `$BUN_INSTALL/bin` to `PATH` manually.
- **`qmd embed` "⚠ Session expired — skipping N chunks" is resumable.** It
  leaves `Pending: N`; re-running resumes. Loop `qmd embed` until no
  `Pending:` line remains, capped at ~10 passes (real backlogs have cleared
  in ~8) — if `Pending:` persists at the cap, stop and investigate the
  session-expiry root cause instead of looping further.
- **Share an index instead of re-embedding on a weak machine.** The index
  lives at `~/.cache/qmd/index.sqlite` (+ `-wal`), collection config at
  `~/.config/qmd/index.yml`. Prefer `VACUUM INTO '<out>.sqlite'` over
  copying files: it snapshots a LIVE WAL database coherently (no need to
  stop the daemon, no `-wal`/`-shm` to carry, freed pages reclaimed in the
  same step). Make sure the target's `index.yml` already lists the
  collections BEFORE you open the copy with qmd — opening an index whose
  config does not match empties `store_collections` (next bullet), so
  verifying can itself mutate what you just shipped. Then `qmd pull` on the
  target (model download only), and verify with `PRAGMA integrity_check`
  plus a real search; do the sqlite-only checks first if the config is not
  in place yet. Live sharing over `/mnt/c` does not work. Never copy an
  index containing sensitive collections (e.g. medical PHI) to another
  machine — share only indexes built from clean collections.
- **Portability is one row.** `documents.path` is RELATIVE to its
  collection root; the only absolute paths live in `store_collections.path`.
  Retargeting an index at a machine with different roots is an UPDATE of
  those rows, not a rewrite. (`index.yml` and `store_collections` are
  reconciled by qmd — running `qmd --index <name> …` against a named index
  with no config entry will empty `store_collections`.)
- **The DB, not the config, is the authority on what an index contains.**
  `qmd status` and `index.yml` enumerate *configured* collections; a
  collection dropped from the config keeps its rows. A live index carried a
  stale `salus` (1138 docs) invisible to both. Always audit with
  `SELECT DISTINCT collection FROM documents` before sharing — the config
  is not a PHI clearance.
- **A shared index carries document TEXT, not just vectors.** `content.doc`
  holds full bodies, so an index stays fully searchable on a machine that
  lacks the source vault — sensitive rows are not inert there. This is why
  the "clean collections only" rule above is load-bearing.
- **Stripping a collection out of an index is surgery.** If you must (a
  full re-embed being the alternative):
  - `vectors_vec` is a `vec0` virtual table. Any external client
    (`sqlite3`, bun:sqlite) fails `no such module: vec0` on reads AND
    deletes until you load qmd's bundled extension
    (`<bun-global>/node_modules/sqlite-vec-<platform>/vec0`). It throws
    rather than half-deleting, so the enclosing transaction rolls back
    intact — a failed strip is not a corrupted index.
  - `content` is hash-deduped and SHARED: byte-identical files across
    collections point at ONE row. Delete only
    `hashes(target) − hashes(keep)` or you punch holes in the collections
    you kept (11 of 1096 hashes were shared in a real run).
  - `documents_fts` is keyed `<collection>/<path>`, and its rowid is NOT
    `documents.id` (FTS covers only `active=1`). Delete by ANCHORED
    filepath (`LIKE 'salus/%'`) — an unanchored `%salus%` also matches
    legitimate `himmel/templates/.../_profiles/salus/*` files. Same
    anchoring lesson as the gitleaks-allowlist bullet below.
  - Verify STRUCTURALLY, not with a text scan: SQL `LIKE '%term%'` is
    substring + case-insensitive, so it false-positives against longer
    clean strings. Assert instead: expected `DISTINCT collection` set only;
    zero content rows unreferenced by any doc; zero content referenced by
    an unexpected collection; zero FTS rows outside expected collections;
    zero `content_vectors`/`vectors_vec_rowids` without a content row;
    `PRAGMA integrity_check` ok; `PRAGMA foreign_key_check` empty
    (`integrity_check` does NOT cover FK violations, and `documents.hash`
    → `content.hash` is a declared FK); SHA256 match across machines.
- **`~/.cache/qmd/mcp.pid` goes stale — it is not proof qmd is idle.** It
  named a dead PID while the real daemon holding the DB ran elsewhere; find
  the holder by command line
  (`Get-CimInstance Win32_Process -Filter "Name='bun.exe'"`) rather than
  trusting the PID file. Pair with the PowerShell trap below: `Move-Item` on
  a file locked by that daemon fails NON-terminating, so a following
  `'OK'` echo still prints and `-ErrorAction SilentlyContinue` hides the
  failure — the step reports success having done nothing. Use
  `-ErrorAction Stop` + try/catch and re-list the directory to confirm.

## Windows PowerShell: embedded double-quotes in native-command args get STRIPPED — and a non-atomic write then blanks the file

Do not pipe a jq filter containing embedded `"` (e.g.
`jq '.enabledPlugins["a@b"]=true' file`) through PowerShell: PowerShell
re-parses native-command arguments and strips the inner double-quotes, so
jq receives `.enabledPlugins[a@b]` → syntax error → **empty stdout**. If
the caller then writes that output non-atomically
(`[IO.File]::WriteAllText($file, $out)`), the config file is blanked —
this live-corrupted a machine's `~/.claude/settings.local.json`.

Three rules:

- **No jq-with-quotes from PowerShell.** Write the literal JSON string
  directly, or do the jq work from Git Bash (jq-in-bash is fine).
- **Config rewrites are temp-file + atomic move, never in-place.** Write
  the temp file on the SAME volume as the target, validate the output
  (non-empty, parses) before the move, and use an atomic rename — under
  those preconditions a mid-pipeline failure cannot blank the live file.
- **Remote multi-shell exec (`ssh → cmd → powershell`/`wsl`): base64 the
  whole script** (`powershell -EncodedCommand <utf16le-b64>`;
  `wsl bash -lc "echo <b64> | base64 -d | bash"`). This kills every layer
  of nested-quote escaping at once — see the `ssh` section above; `\$HOME`
  through ssh'd single-quotes arrives literal, another reason to base64.

## WSL2 cannot reach host `127.0.0.1`-bound services via the gateway IP — use mirrored networking

Services that bind loopback only (Obsidian Local REST API, a local
CLIProxyAPI gateway, most dev servers) are unreachable from WSL2 through
the often-documented NAT gateway IP (`ip route show default`): the request
returns HTTP 000 because the listener is `127.0.0.1:<port>`, not
`0.0.0.0` — and `localhostForwarding` does NOT bridge the WSL→host
direction either. The fix is mirrored networking. In
`%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored

[experimental]
hostAddressLoopback=true
```

then `wsl --shutdown` and restart the distro. Per Microsoft's WSL docs,
mirrored mode itself is what lets WSL reach Windows-host listeners via
`127.0.0.1`; `hostAddressLoopback=true` additionally allows reaching the
host through its assigned IPv4 addresses. The pair above is the
live-verified working config. WSL `127.0.0.1:<port>` then reaches the
host service directly, and because the client connects via `127.0.0.1`,
a self-signed cert bound to `127.0.0.1` keeps its SAN match. Requires
Windows 11 22H2+ (build 22621+). It is a global change
(all distros; can interact with Docker Desktop/VPNs), so gate the
`wsl --shutdown` on the operator — but it solves the whole loopback class
at once, which is why it beats per-service `netsh portproxy` rules.

## Claude Code: a background-task notification's "exit code 0" is the LAST command in the chain

The completion notification for a background Bash task reports the exit
code of the final command in the chain — a trailing `echo`/`tail` masks a
failing gate earlier in the same chain (observed: a merge-gate script
exiting 3 under an "exit code 0" notification because the chain ended in
an echo). Read the task's actual output for the verdict; never trust the
notification's exit code for anything but the last command.

## gitleaks: anchor allowlist regexes — and the pre-push scan covers the staged INDEX

- **Allowlist regexes for a known-benign literal must be anchored**
  (`'''^the-literal$'''`), never a bare substring: an unanchored regex also
  suppresses any REAL secret that merely *contains* the literal — a
  scanner-bypass hole. Verified behaviour: anchored keeps a
  prefixed/suffixed variant flagged; unanchored suppresses both.
- **A correct anchor will still fire on nested contexts** — the same
  benign literal embedded inside other text (e.g. a `printf` line captured
  into a shipped `.patch` file) extracts as a longer candidate secret that
  `^…$` rightly does not match. That firing is correct, not a bug: do NOT
  un-anchor to silence it (that reopens the substring hole). Fix at the
  source (keep the literal out of the shipped text) or add a
  path-scoped allowlist entry.
- **The pre-push hook scans the STAGED INDEX, not just your push range.**
  In a repo shared by concurrent sessions, one session's staged secret
  blocks *every* session's push — and `git log --all -- <file>` finds
  nothing because the file was never committed. Diagnose with
  `git status --short -- <file>` — an `A` in the first column followed by
  a space means staged-new — and let the owning session fix its own
  staged file.
