# Optional plugins — install manually

This template ships five community plugins enabled out of the box, each under
a permissive license (see each plugin's `LICENSE`/`LICENCE` file under
`plugins/`): Calendar, Dataview, Banners, Local REST API & MCP Server, and
qmd-as-md.

## GitHub Sync — opt-in, and mutually exclusive with the sweeper

A sixth plugin, **GitHub Sync**, is vendored too (`optional/plugins/github-sync/`
in the template) but **not installed by default** (HIMMEL-3066): it commits
the vault from inside Obsidian on its own ~10-minute tick, which races
`scripts/vault-autosync.ps1`/`.sh` (the sweeper) committing the same working
tree — `vault-autosync.ps1`'s sanity gate refuses to run at all
(`AlarmClass: plugin-resurrected`) if it ever finds `github-sync` enabled.
**Pick one sync mechanism, not both:**

- **Sweeper (default)** — `LUNA_VAULT_AUTOSYNC=1 bash scripts/vault-autosync.sh`
  (or the `.ps1` twin). No plugin install needed.
- **GitHub Sync plugin (opt-in)** — run the upgrader with
  `--with-github-sync` (or `LUNA_WITH_GITHUB_SYNC=1`):
  `bash scripts/upgrade.sh --with-github-sync`. This installs the plugin
  assets into `.obsidian/plugins/github-sync/` and adds it to
  `community-plugins.json`; enable it in Obsidian's Community Plugins list
  afterward and configure its remote/credentials there. A vault that already
  has the plugin installed keeps it (and gets asset updates) on every
  upgrade with no flag needed — the upgrader never uninstalls it.

Four further plugins the source vault also used are **not bundled** because
their licenses are incompatible with this repository's MIT license (three are
AGPL-3.0 copyleft; one is now proprietary). Install them yourself from
Obsidian's Community Plugins browser if you want them — they are entirely
optional and the vault works without them.

To install: open **Settings → Community plugins → Browse**, search the name
below, then **Install** and **Enable**.

| Plugin | Search for | License | Source |
| --- | --- | --- | --- |
| **Templater** | `Templater` | AGPL-3.0 | https://github.com/SilentVoid13/Templater |
| **Excalidraw** | `Excalidraw` | AGPL-3.0 | https://github.com/zsviczian/obsidian-excalidraw-plugin |
| **Thino** (formerly Memos) | `Thino` | Proprietary (closed-source since v2.0.0) | https://github.com/Quorafind/Obsidian-Thino |
| **Charts** | `Charts` | AGPL-3.0 | https://github.com/phibr0/obsidian-charts |

> **Charts** is needed to render the `luna-correlate` `signals.dashboard` note
> (`60-Signals/dashboard.md`) — without it the ```` ```chart ```` blocks show as
> plain code. The dashboard's table and interpretation are fully readable either way.

> The `_Templates/` folder in this vault contains plain-markdown note
> templates that work with Obsidian's built-in **Templates** core plugin, so
> Templater is not required for basic use.
