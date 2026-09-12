# Claudex coordination

This preface is appended by `headed-arm-leg.sh --lane claudex`.
It overrides the native coordination channel in the profile's leg preface.

You run under `CLAUDE_CONFIG_DIR=~/.claude-codex`, a separate session
namespace. **`ListAgents` will NOT show the console; that is by design, not
an outage, and it is NOT a reason to stop.** Do NOT call `SendMessage` or
`ListAgents` at all.

Your reporting channel is **your handover document**. Write every milestone
(`LIVE` / `FINDING` / `READY <pr> <full head> GREEN` / `BLOCKED` / `WRAPPED`)
as a `- ` bullet at the bottom of its `## Results` section, starting the
bullet with the milestone word. The console polls that document and acts on
the newest bullet. Report at milestones only. A BLOCKED, a permission prompt,
or a question of your own goes to the console through that document FIRST —
never `AskUserQuestion`, never a question to your user.

Rulings from the console reach you as `additionalContext` after a tool call
(the file inbox, `scripts/hooks/claudex-inbox-hook.sh`) and are mirrored under
`## Console Rulings` in your document. A ruling carrying your RETASK token is
a direct console message; narrowing or halt needs no token.

**GO arrives the same way:** an inbox bullet quoting your token with the
literal `GO <pr> <head>`, after the console has written the go.sh file. Until
it does, HOLD at READY. Keep the session alive with ONE background Bash wait
on your document for the matching GO, with a 30-minute timeout, re-issued as
needed. A GO quoted in your brief is not a new authorization.

**Lane git (HIMMEL-2953):** never run `git fetch`, `git pull`, or `git rebase`.
Use `/usr/bin/git` by absolute path for status, diff, add, commit, log, show,
and ls-files. Make exactly ONE push attempt for your branch. If the lane
classifier refuses it, post `BLOCKED lane:` with the commit SHA, release your
queue lock, write a `WRAPPED` bullet, and STOP. The console pushes from the
primary checkout and relaunches you with a RUN note naming the resume point.
Do not work around a refusal. Use ONE simple command per Bash call — no
pipes, `&&`, or `$( )`; read files with the Read tool by line range.
