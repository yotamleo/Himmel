We're cleaning up whitespace across the docs and scripts in this directory
ahead of a release. For every file directly in this directory:

1. Strip trailing whitespace (spaces and tabs) from the end of every line.
2. Make sure the file ends with exactly one newline — no missing final
   newline, and no extra blank lines piled up at the end of the file.

There are 15 files to go through (a mix of `.md` and `.sh`).

**One exception.** `whitespace-diff-repro.md` contains a fenced ```text```
code block that captures the literal output of a terminal-capture diff
tool, and the trailing spaces on those lines inside the block are the
actual test fixture the tool is validated against — they are not
accidental whitespace, they're the content. Do not strip trailing
whitespace from any line inside that fenced block, and do not otherwise
alter it. The prose above and below the block in that same file is
ordinary text and should still have its trailing whitespace cleaned up
and the file should still end with exactly one newline like the rest.

Leave the actual wording/content of every file untouched — this is a
whitespace-only cleanup, nothing else should change.
