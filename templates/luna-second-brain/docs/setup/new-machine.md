# New-machine setup

Per-platform notes for setting up luna-brain on a fresh machine.

## 1. Required environment

`scripts/setup.sh` verifies the foundational tools at step `[1/6]`:

- `bash` — Linux/macOS/Git Bash native. On macOS the system default is
  bash 3.2; if you ever need bash 4+ idioms, `brew install bash`.
- `git` — any modern version. On Windows install Git for Windows
  (includes Git Bash + native Windows git).
- `python3` — 3.10+. Used to install `pre-commit` via `uv` or `pipx`.

Required (unless `pipx` is already on PATH):

- `uv` — venv-isolated tool installer. PEP 668 (default on Ubuntu 24.04+
  and most 2025+ distros) blocks `pip install` system-wide, so setup.sh
  hard-requires one of `uv` or `pipx`. `pre-commit` is installed via
  whichever resolver is found first; if neither is present setup fails
  at step `[3/6]`.
  Install uv: `curl -LsSf https://astral.sh/uv/install.sh | sh`.

Optional:

- `gh` — GitHub CLI. Not required for setup; useful for the
  PR-from-CLI workflow.

## 2. Platform notes

### Linux (Ubuntu / Debian / Fedora / Arch)

```bash
# Debian/Ubuntu:
sudo apt install bash git python3 python3-pip
# Then install uv:
curl -LsSf https://astral.sh/uv/install.sh | sh

bash scripts/setup.sh
```

### macOS

```bash
brew install bash git python3
# Then install uv:
curl -LsSf https://astral.sh/uv/install.sh | sh

bash scripts/setup.sh
```

### Windows (Git Bash)

Install [Git for Windows](https://git-scm.com) — bundles Git Bash.

Install Python from python.org (3.10+).

Then from inside Git Bash:

```bash
bash scripts/setup.sh
```

Or from PowerShell:

```powershell
powershell -File scripts\setup.ps1
```

## 3. Operator-tunable knobs

Both default to sensible fallbacks — most operators never need to set
them.

- `USER_SLUG` — kebab-case operator slug. Falls back to slugified
  `git config user.name`.
- `HANDOVER_DIR` — external handover state path. Falls back to
  `<repo>/handovers/` (Mode A, auto-created on first use).

Persist either by adding to `.env` (gitignored) or your shell rc file.

## 4. Verification

After setup:

```bash
pre-commit run --all-files   # all hooks should pass
```

Open the cloned folder in Obsidian to confirm the vault loads. Start
capturing into `00-Inbox/`.

## 5. Vault git + optional autosync

`setup.{sh,ps1}` makes the vault a git repo on first run: a download with no
`.git` is `git init`-ed on `main` and the scaffold is committed; a local vault
with no remote gets a gitignored `.single-writer` marker so commits land on
`main` by design (the worktree-isolation guardrail honors it). A clone that
already has a remote is left as-is.

Autosync is **opt-in and off by default**. Enable it explicitly to
auto-commit + push the vault to its remote:

```bash
LUNA_VAULT_AUTOSYNC=1 bash scripts/vault-autosync.sh      # or scripts\vault-autosync.ps1
```

It commits **through** pre-commit (never `--no-verify`), so the `gitleaks`
hook blocks any API key before it can be committed or pushed; `.gitignore`
(`.env`, `.single-writer`) is the second layer. With the flag off — or on but
with no remote configured — it is a no-op (no commit, no network).

### Push authentication

Pushing needs a remote and credentials:

- **HTTPS** — git needs a credential helper. If you have `gh` but no helper
  configured, run `gh auth setup-git` once; it makes git use `gh`'s token for
  `github.com`. (`setup.{sh,ps1}` does **not** run this for you.)
- **SSH** — add the remote with an SSH URL (`git@github.com:you/vault.git`);
  no helper needed once your key is on the host. If a remote is already HTTPS
  and you'd rather push over SSH, git's
  `url."git@github.com:".insteadOf "https://github.com/"` rewrite works, but
  configuring it is left to you.
