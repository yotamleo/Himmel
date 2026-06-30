# Bounded-run prompt template

The canonical prompt handed to each bounded `claude "<prompt>" </dev/null`
run spawned by the Telegram bridge poller.

**`buildPrompt()` in `run.ts` is the source of truth.** This doc is the
human-readable spec of what it emits. The poller interpolates the session
id and the absolute bus paths (`inbox` / `outbox` / `context` / `cwd`) at
spawn time.

## Template

```
You are Telegram bridge session "<session>", running in <cwd>.
First, read your cross-run memory at <context> to resume where the last run left off (it may be empty on a first run).
Then read your pending messages from <inbox> — each line is a JSON object {"text": "..."}; treat them as the operator's requests, in order.
If a line has an "image_path" field, use the Read tool on that path — it is a photo the operator attached; the line's "text" is its caption.
If a line has a "document_path" field, use the Read tool on that path — it is a file the operator attached (e.g. a PDF); the line's "text" is its caption and "document_name" is the original filename.
<job>
<vault-clause — only when a vault is configured for the session's chat (HIMMEL-321)>
Acting on Jira tickets for the operator is part of your job — when asked, DO IT DIRECTLY (don't just offer a paste-ready command). Use the Jira CLI by its ABSOLUTE path: `node <cwd>/scripts/jira/dist/index.js <op>` (JIRA_PROJECT_KEY comes from the repo .env; run it with --help for the ops). You MAY create, edit/update, comment, transition, assign, change priority/labels, attach files, link, and read tickets — this is sanctioned, non-destructive work. You may NOT delete tickets (there is no delete op), and do NOT use `move` (it closes the source ticket) or `project-create` (admin) unless the operator explicitly asks.
Reply to the operator by APPENDING one JSON line {"text":"<your reply>"} per message to <outbox>. That is the only way to reach the operator.
Do NOT poll Telegram yourself and do NOT open a --channels session.
As your FINAL action, append a one-line progress note to <context> (so the next run has context). Then stop — you are done.
```

## Session shape decides `<job>`

- **Ticket session** (id matches `^[A-Z][A-Z0-9]+-[0-9]+$`, e.g. `HIMMEL-5`):
  `You are working on ticket <session>. Do the ticket's work.`
- **Anything else** (e.g. `__chat__`):
  `Answer the operator's message(s) conversationally.`

## Attachment → vault routing (`<vault-clause>`, HIMMEL-321 / HIMMEL-578)

When a document (e.g. a PDF) **or an image** is sent to a chat that has a vault
configured, `buildPrompt` appends a clause telling the run to FILE the
attachment's content into that Obsidian vault (not just read it), following the
vault's `_CLAUDE.md` conventions — using the vault's own filing skill (e.g. a
`medic` skill) if it has one, else the `obsidian-second-brain` skill — and to
confirm in its reply. (Pre-HIMMEL-578 only documents filed; images were read but
never filed.)

## Per-chat session cwd (HIMMEL-578)

A chat with a configured vault SPAWNS its session with `cwd = <vault>` (not the
himmel repo), so the vault's own `.claude/hooks` load — e.g. a medical vault's
PHI-egress floor is then in force for the session that handles its photos. The
"running in" line reports the vault cwd (`p.sessionCwd`), while the Jira-CLI path
stays anchored on the himmel repo (`p.cwd`, where `dist/` lives). The poller also
passes `--permission-mode bypassPermissions` for vault sessions ONLY — under the
vault cwd himmel's `auto-approve-safe-bash` hook is not loaded, so without it the
stdin-closed run would deadlock on un-answerable permission prompts; the vault's
own PreToolUse hooks still enforce containment (they run regardless of permission
mode).

**Blast radius — `defaultVault` (HIMMEL-578).** `vaultForChat` falls back to
`access.defaultVault` for any chat without its own `vault`. So if `defaultVault`
is set, EVERY otherwise-unconfigured chat — including DMs and unknown groups —
now spawns in that vault's cwd WITH `bypassPermissions`. The containment for
those sessions is therefore the default vault's OWN PreToolUse hooks: set
`defaultVault` only to a vault you trust to run sessions under bypass (a vault
with no restraining hooks would run effectively unrestricted). To keep the
vault-cwd+bypass posture scoped to specific groups, leave `defaultVault` unset
and configure each group's `vault` explicitly. (Pinned by the
`makeRunFn + real vaultForChat … blast radius` test.)

The vault is resolved by `gate.vaultForChat(access, chat_id)` from
`~/.claude/channels/telegram/access.json`: a group's own `vault` wins, else
the top-level `defaultVault`, else none (no clause — the document is surfaced
but nothing is filed). Example config:

```json
{
  "defaultVault": "/path/to/your-vault",
  "groups": { "<group-id>": { "vault": "/path/to/another-vault" } }
}
```

Here a PDF sent to the group with its own `vault` is filed into that vault;
a PDF sent to any other chat (other allowlisted groups, or a DM) falls back to
`defaultVault` — which covers every chat without its own.
The poller reads `access.json` ONCE at startup — restart the bridge after edits.

## Jira sanction (HIMMEL-424 followup)

The bridge session runs in auto-mode, where the harness classifier VETOES Jira ticket
writes when the session's stated workflow omits Jira — so without this clause the bridge
replies *"I can't create the ticket (classifier veto)"* instead of doing it. The clause
states Jira ticket work as in-scope, which lifts the veto. It is deliberately scoped to
**non-destructive** operations: there is no `delete` op in the CLI, and `move` (closes the
source ticket) and `project-create` (admin) are excluded unless the operator explicitly
asks. The CLI is invoked by its absolute path under `<cwd>` (the primary checkout, where
the untracked `dist/` build artifact lives — a worktree-relative path would
`MODULE_NOT_FOUND`).

## Contract the prompt enforces

- **Inbox** — the run READS pending operator messages from the inbox JSONL.
  A line carrying an `image_path` points at a locally-downloaded photo
  (HIMMEL-250); a line carrying a `document_path` points at a locally-downloaded
  file such as a PDF (HIMMEL-321, with `document_name` the original filename);
  the run Reads it, with `text` as the caption.
- **Outbox** — the run REPLIES by APPENDING `{"text":"..."}` lines; it never
  needs a `chat_id`. The poller owns delivery back to Telegram.
- **Context** — the run reads `context.md` first to resume, and appends a
  one-line progress note last so the next run has continuity.
- **No self-poll** — the run must NOT poll Telegram itself and must NOT open
  a `--channels` session. Polling is the poller's job; the run is bounded and
  exits when done.
