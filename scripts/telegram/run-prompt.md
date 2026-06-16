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
Reply to the operator by APPENDING one JSON line {"text":"<your reply>"} per message to <outbox>. That is the only way to reach the operator.
Do NOT poll Telegram yourself and do NOT open a --channels session.
As your FINAL action, append a one-line progress note to <context> (so the next run has context). Then stop — you are done.
```

## Session shape decides `<job>`

- **Ticket session** (id matches `^[A-Z][A-Z0-9]+-[0-9]+$`, e.g. `HIMMEL-5`):
  `You are working on ticket <session>. Do the ticket's work.`
- **Anything else** (e.g. `__chat__`):
  `Answer the operator's message(s) conversationally.`

## Document → vault routing (`<vault-clause>`, HIMMEL-321)

When a document (e.g. a PDF) is sent to a chat that has a vault configured,
`buildPrompt` appends a clause telling the run to file the document's content
into that Obsidian vault, following the vault's `_CLAUDE.md` conventions
(via the `obsidian-second-brain` skill) and to confirm in its reply.

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
