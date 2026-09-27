---
name: jira-comment
description: Add a comment to a Jira issue ("comment on HIMMEL-46 saying ..."). Needs explicit Jira key. Not PR/GitHub comments.
---

Run `/jira-comment <KEY> "<body>"` with the key and the body text the user wants to post. If the user didn't provide the body verbatim, ask via AskUserQuestion.
