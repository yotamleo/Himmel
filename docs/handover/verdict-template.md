# Verdict template

The file a judge writes to answer one question, per design spec §3.6. It is
the only output a judge produces — a judge session does not open a PR, does
not merge, and does not send its answer as a message. **Transport is the
disk, never a peer message**: a peer message is not authority, and a verdict
that lives only in a message dies with the console's window. Path:

```
<handover_root>/<bucket>/verdicts/<qid>/<judge-name>.md
```

`<qid>` matches the question id the console's judge brief named; `<judge-name>`
is the judge's session name (`HIMMEL-<ticket>-judge-<qid>` for a session,
or the dispatching console's own session name for an in-process judge call).
The console reads this path — never a message — to learn the verdict.

---

```markdown
# VERDICT <qid> — <judge session name>

## Reason (scope asked)

<one line: the exact question this verdict answers, copied from the brief's
"The question" line. Not a summary of the topic — the question, verbatim.>

## Verdict

<the answer itself, in the shape the brief's completion condition asked for
— e.g. CONFIRM/REJECT plus one paragraph of reason, or a chosen disposition
among named options. This is the field the console acts on.>

## Evidence checked

<which of the brief's numbered Evidence items were actually used to reach
the verdict, and how — cite by number. If the judge gathered evidence of its
own (a cold read, a tree walk), name what it found here too, not only what
the brief handed it.>

## Out of scope, noted

<anything the question touched but the verdict does not rule on — a related
finding, a second question folded into the same evidence, a limitation the
judge could not resolve with what it was given. This is where a judge says
"I cannot tell" rather than guessing past its evidence.>
```

---

## Why each field is load-bearing

| Field | What it is for |
|---|---|
| `# VERDICT <qid> — <judge session name>` | Identifies which question this answers and who answered it, so a console juggling several open questions can tell verdicts apart at a glance. |
| `## Reason (scope asked)` | Restates the question verbatim, so a verdict read later — after the brief itself is gone from context — is still self-contained. |
| `## Verdict` | The one field the console acts on. Everything else is provenance for that answer. |
| `## Evidence checked` | Makes the verdict auditable: which evidence actually drove the answer, not just which evidence was offered. A verdict that cites nothing is not distinguishable from a guess. |
| `## Out of scope, noted` | Keeps a judge from silently overreaching past what it was asked, and gives it a place to flag "not enough evidence" instead of forcing a confident-sounding answer. |
