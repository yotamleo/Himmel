There is a `tickets/` directory containing 20 markdown files, one per support ticket. Each file records five pieces of information about that ticket — a ticket ID, a status, a priority, an assignee, and a title — but the files were written by different people over time and don't all follow the same layout:

- Some files put the ticket ID, status, priority, and assignee in a YAML front-matter block at the top (between `---` lines), with the title given as the `# ` heading below the front matter.
- Some files put the ticket ID and title together in the `# ` heading, formatted as `# TCK-XXX: <title>`, and list status, priority, and assignee as separate lines formatted `**Field:** value`.
- Some files list all five fields as rows in a two-column markdown table with a `| Field | Value |` header.

Read every file in `tickets/` and extract these five fields from each: `ticket_id`, `status`, `priority`, `assignee`, `title`.

Write the result to a single new file named `audit.psv` in this directory (not inside `tickets/`), using `|` (a single pipe character) as the column separator. The first line must be the header row, exactly:

```
ticket_id|status|priority|assignee|title
```

Follow the header with exactly one row per ticket file (20 data rows total), sorted by `ticket_id` ascending. Each row lists the five field values in the same order as the header, separated by `|`, with no surrounding whitespace around a value and no quoting of any kind around values.

Escaping rule: if an extracted field value itself contains a literal `|` character, replace that character with `\|` (a backslash immediately followed by a pipe) before writing it into the row, so it can never be mistaken for a column separator. No other character needs escaping — leave commas, colons, ampersands, and everything else exactly as they appear in the source file.

Do not modify or delete any file under `tickets/`. Do not create any file other than `audit.psv`.
