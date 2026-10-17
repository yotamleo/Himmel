# domain-modeling@himmel

One skill vendored from [`mattpocock/skills`](https://github.com/mattpocock/skills)
at `49dd158d1076134a641b33efb035946536778336` (MIT, (c) 2026 Matt Pocock).
Inventory and deviations: [`VENDORED.md`](VENDORED.md). Eval:
`docs/tool-adoption/registry.md` (HIMMEL-5498).

| Skill | Use |
|---|---|
| `domain-modeling` | sharpen terminology and keep `docs/glossary.md` to one definition per term, aliases pointing at the canonical term |

The listing is the skill description, about 40 tokens. The plugin ships no
hooks, agents, commands, MCP servers or scripts, and grants no autonomy.

## Where it is on

Only in the `design` profile of `scripts/lanes/plugin-profiles.json`. No base,
floor, leg, lane or console profile enables it, and the catalog resolves it off
for all of them.

## Remove it (one step)

```
claude plugin disable domain-modeling@himmel
```

or, to delete it:

```
claude plugin uninstall domain-modeling@himmel
```
