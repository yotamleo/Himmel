# Safeguard false-positive mitigations

Lean-invoke reference: three named mitigations, from Anthropic's Fable 5.1
prompting guide's "Reduce safeguard false positives" section, audited against
himmel in
`handovers/yotamleo/himmel/specs/eval/HIMMEL-fable51-prompting-audit-2026-09-05.md`
(HIMMEL-2586). The auto-memory topic file `claude-invocation-traps.md`
(`~/.claude/projects/<project>/memory/`) records refusal *symptoms*
(content-filter 400, Fable refusal drops `[1m]`) — these are the three
specific triggers/mitigations, not covered there.

## The three triggers

- **Phrase code-quality asks as "are there bugs" not "does this compile."**
  A compile/syntax framing reads closer to an adversarial probe than a
  correctness question and raises false-positive refusal risk on legitimate
  review requests.
- **Give context for lesser-known languages.** A safeguard is more likely to
  misread unfamiliar syntax as suspicious; naming the language and its
  purpose up front reduces that risk.
- **Keep base64 out of `tool_result` content reaching a Claude lane.**
  Relevant to any dispatcher piping binary/encoded payloads to a Claude lane
  (image tools, hermes payloads) — base64 blobs in tool output are a known
  content-filter trigger (see the `claude-invocation-traps.md` auto-memory
  topic file's "content-filter 400" entry).

## Deliberately not adopted

Verbatim from the audit report's "What the guide recommends that would
CONFLICT with a himmel safety rail" section (listed for operator decision,
not resolved here — so nobody re-proposes them without reading why):

- **"Finish the whole task" autonomy block** ("the user is not watching...
  proceed without asking... stop only for destructive actions") is close to
  but broader than himmel's own Auto Mode framing, and broader than the
  `coordinator-halt-cannot-be-reasoned-away` incident memory, which exists
  precisely because a worker once talked itself out of honoring a stand-down
  as "not genuine user input." Adopting the guide's block verbatim, without
  keeping himmel's narrower carve-outs (destructive/hard-to-reverse actions,
  explicit halts from any source), could reintroduce that failure mode.
- **Formatting-in-chat's "lean toward less structure"** could conflict with
  himmel artifacts that require structured Markdown for machine/human
  parsing — CR reports, gap tables, ledger-shaped output. Blanket-adopting
  the guide's under-formatting correction without scoping it to
  conversational replies (vs. deliverables) would degrade those.
- **RETASK channel's synchronous-dispatch assumption** vs. the guide's
  "subagent starts, returns later via async user message" pattern — not a
  hard conflict, but the two documents don't share a threat model; adopting
  the guide's async pattern more heavily without re-examining
  `retask-channel.md` §1's threat model leaves an unreviewed edge.
