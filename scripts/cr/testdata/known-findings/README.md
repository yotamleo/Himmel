# Known-findings fixtures (HIMMEL-2058)

Deliberate detector bait for scripts/cr/test-known-findings.sh: bare mktemp, GNU timeout,
mapfile, env arithmetic, a literal handovers/ path, a bare fence, a hook with no stated
fail direction. Lives under testdata/ so known-findings.sh --diff skips it (fixtures are
data, not code) — do not "fix" these lines.

HIMMEL-2447 added three bait/control PAIRS to change1.sh, each bait immediately
followed by the correct spelling it must NOT flag:

| line | bait (must fire) | control (must stay silent) |
|---|---|---|
| 14-16 | `.agent_id // empty` | `(.agent_id \| type) == "string"`, and `// empty` on a non-boolean field |
| 17-18 | `[—-]` — an em dash INSIDE a bracket expression | the alternation `(—\|-)` |
| 19-20 | hardcoded `/usr/bin/cat` | the bare `cat "$p"` |
| 22 | `.agent_id // empty \| type` — buggy DESPITE the trailing `\| type` | (its control is line 15 above) |

Line 22 exists because the jq class's exclude once carried a whole-line
`\| type` clause, which suppressed exactly this line. The pair that matters is
22 (must fire) against 15 (must stay silent): 15 is spared by the main pattern
requiring `//`, never by an exclude — which is why the clause was removable.

Line 17 carries a real U+2014 (bytes `e2 80 94`). Keep it — re-saving this file
as ASCII, or "tidying" the dash to a hyphen, makes the non-ascii-bracket-expression
case vacuous while the suite stays green.
