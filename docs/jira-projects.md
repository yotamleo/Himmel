# Jira Projects

Catalog of Jira projects on the `yotamleo.atlassian.net` instance. Keys are
public — safe to commit. Refresh with `jira projects` (subcommand added in
PR introducing this file).

| Key | ID | Name | Scope | Notes |
|-----|----|------|-------|-------|
| HIMMEL | 10033 | Himmel | himmel repo — engineering, infra, tooling. | Default project for the `jira` CLI (`JIRA_PROJECT_KEY=HIMMEL` in `.env`). All Epics for himmel work live here. Standalones historically NOT tracked here. |
| LUNA | 10066 | Luna | Luna vault (personal second brain). | Created 2026-05-19 via `jira project-create`. Template: Kanban classic. For tickets tracking Luna-specific work. Vault content lives in the `luna` repo; Luna handover docs live in the handover state repo `<state-repo>/handovers/<USER_SLUG>/luna/` (himmel `handovers/` is a stub). |

## Usage

- Default project (HIMMEL): `jira list`, `jira create --type Story --title "..." --sector "Ship loop" --labels standalone`
- Non-default project: pass `--project <KEY>` to any subcommand. Example:
  `jira create --project LUNA --type Story --title "..." --sector "Planning & tracking" --labels standalone`
- A Task, Story or Bug needs `--sector` and either `--parent <epic>` or `--labels standalone` (HIMMEL-6223).
- Refresh this catalog: run `jira projects` and update the table above.

## Conventions

- Epics: `<PROJECT>-N` (e.g. `PROJ-29` for VirtualBox VM Management).
- Standalones (himmel concept): historically not in Jira — tracked only in
  `<state-repo>/handovers/<USER_SLUG>/<repo>/standalones/` (`<repo>` ∈ himmel | luna |
  cross in practice; `luna_brain` remains a built-in resolver bucket but is
  inactive; current bucket layout). New convention from
  2026-05-19 forward files standalones as Stories in their topical project
  (e.g. Luna-related standalones → LUNA-N Story under
  `<state-repo>/handovers/<USER_SLUG>/luna/standalones/`).
- Theme label (HIMMEL-5491): a ticket carries at most one `theme-<slug>` label (`<slug>` is lowercase `a-z0-9` with
  single hyphens, at most 40 characters). The config-ui Kanban theme select writes it through the Jira CLI and
  replaces any other `theme-*` label; other labels are kept. The config-ui roadmap and the console-kit tracker read it
  first and fall back to the plan's stage1 / overlay theme only when no label is set. A slug that matches a plan theme
  (lowercased, non-alphanumerics to `-`) shows that theme's plan name.
