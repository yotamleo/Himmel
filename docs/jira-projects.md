# Jira Projects

Catalog of Jira projects on the `yotamleo.atlassian.net` instance. Keys are
public — safe to commit. Refresh with `jira projects` (subcommand added in
PR introducing this file).

| Key | ID | Name | Scope | Notes |
|-----|----|------|-------|-------|
| HIMMEL | 10033 | Himmel | himmel repo — engineering, infra, tooling. | Default project for the `jira` CLI (`JIRA_PROJECT_KEY=HIMMEL` in `.env`). All Epics for himmel work live here. Standalones historically NOT tracked here. |
| LUNA | 10066 | Luna | Luna vault (personal second brain). | Created 2026-05-19 via `jira project-create`. Template: Kanban classic. For tickets tracking Luna-specific work. Vault content lives in the `luna` repo; Luna handover docs live in the handover state repo `<state-repo>/handovers/<USER_SLUG>/luna/` (himmel `handovers/` is a stub). |

## Usage

- Default project (HIMMEL): `jira list`, `jira create --type Story --title "..."`
- Non-default project: pass `--project <KEY>` to any subcommand. Example:
  `jira create --project LUNA --type Story --title "..."`
- Refresh this catalog: run `jira projects` and update the table above.

## Conventions

- Epics: `<PROJECT>-N` (e.g. `HIMMEL-29` for VirtualBox VM Management).
- Standalones (himmel concept): historically not in Jira — tracked only in
  `<state-repo>/handovers/<USER_SLUG>/<repo>/standalones/` (`<repo>` ∈ himmel | luna |
  luna_brain | cross; post-HIMMEL-129 bucket layout). New convention from
  2026-05-19 forward files standalones as Stories in their topical project
  (e.g. Luna-related standalones → LUNA-N Story under
  `<state-repo>/handovers/<USER_SLUG>/luna/standalones/`).
