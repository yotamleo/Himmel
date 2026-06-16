# Third-Party Notices

himmel is licensed under the [MIT License](LICENSE). This file attributes the
third-party code it depends on or vendors. The full dependency-license audit
(HIMMEL-309) covered the combined shipping tree — every npm package plus the
folded `templates/luna-second-brain/` second-brain template — and found a clean,
fully permissive posture: no GPL/AGPL/LGPL/SSPL or unknown licenses. MIT is clean
to apply as the root license.

## npm dependencies

himmel's Node packages (`scripts/jira`, `scripts/himmel-run`,
`marketplace/plugins/obsidian-triage/tools`, `marketplace/plugins/telegram-himmel`,
`plugins/himmel-gh`, `plugins/himmel-jira`) declare their dependencies in
`package.json`; the dependencies themselves are **not redistributed in this
repository** — they are fetched by `npm install` and each carries its own license.

Every production dependency resolves to a permissive, MIT-compatible license. The
pre-push gate `scripts/hooks/check-npm-licenses.sh` enforces this allowlist on
every push:

```
MIT  ISC  BSD-2-Clause  BSD-3-Clause  Apache-2.0  CC0-1.0  Unlicense  0BSD  Python-2.0
```

As of the HIMMEL-309 audit, the production dependency tree resolved almost
entirely to MIT and ISC, with a small permissive remainder: Apache-2.0
(`playwright`, `playwright-core`), BSD-2-Clause, and BSD-3-Clause. Two tags worth
a note, both permissive:

- **`Python-2.0`** — `argparse` (a transitive dependency of `js-yaml`). The
  package is dual-licensed MIT / Python-2.0; the PSF License is permissive and
  GPL-compatible.
- **`Unlicense`** — a public-domain dedication (see the vendored Obsidian plugin
  below), imposing no conditions.

himmel's own packages are MIT, except `marketplace/plugins/telegram-himmel`, which
is an Apache-2.0 fork (see Vendored forks).

## Vendored Obsidian plugins

The `templates/luna-second-brain/` template ships a working Obsidian vault that
includes pre-built community plugins under `.obsidian/plugins/`. Each retains its
upstream `LICENSE` file in its plugin directory; all are permissive.

| Plugin | Author | License |
|---|---|---|
| `calendar` | Liam Cain | MIT (© 2021 Liam Cain) |
| `dataview` | Michael Brenan | MIT (© 2021 Michael Brenan) |
| `github-sync` | Kevin Chin | MIT (© 2024 Kevin Chin) |
| `obsidian-banners` | Danny Hernandez | MIT (© 2021 Danny Hernandez) |
| `obsidian-local-rest-api` | Adam Coddington | MIT (© 2023 Adam Coddington) |
| `qmd-as-md-obsidian` | Daniel Borek | Unlicense (public domain) |

## Vendored forks

Two plugins are minimal forks of Anthropic's `claude-plugins-official` plugins,
kept under their upstream **Apache-2.0** license. Each ships its own `LICENSE` and
a `NOTICE` documenting the upstream attribution and the himmel modifications:

- `marketplace/plugins/pr-review-toolkit-himmel` — see its `LICENSE` and `NOTICE`.
- `marketplace/plugins/telegram-himmel` — see its `LICENSE` and `NOTICE`.
