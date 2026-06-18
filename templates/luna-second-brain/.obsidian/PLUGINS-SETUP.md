# Optional plugins — install manually

This template ships six community plugins out of the box, each under a
permissive license (see each plugin's `LICENSE`/`LICENCE` file under
`plugins/`): Calendar, Dataview, GitHub Sync, Banners, Local REST API & MCP
Server, and qmd-as-md.

Four plugins the source vault also used are **not bundled** because their
licenses are incompatible with this repository's MIT license (three are
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
