---
name: jira-comment
description: Use when user asks to add a comment to a Jira issue (e.g. "comment on HIMMEL-46 saying ...", "add a note to HIMMEL-99"). MUST contain an explicit Jira key. Do NOT trigger on PR comments or GitHub issue comments — those go to himmel-gh.
---

Run `/jira-comment <KEY> "<body>"` with the key and the body text the user wants to post. If the user didn't provide the body verbatim, ask via AskUserQuestion.
