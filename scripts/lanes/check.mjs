// scripts/lanes/check.mjs — HIMMEL-689 drift guard: keep the lane INVENTORY out of CLAUDE.md prose.
// Config-only lanes are guarded (glm/gemini/codex/hermes); a bare "Opus" mention is invariant policy, allowed.
const NEEDLES = ['spawn-glm', 'gemini-subagent', 'CR_PROFILE=paid', 'qwen3coder'];
// The sanctioned pointer line is exempt. Match the backtick-quoted `/lanes` COMMAND token
// (not any '/lanes' substring, R2 M-R2-1) so a prose mention of scripts/lanes/ can't smuggle a needle.
const isPointerLine = (line) => line.includes('`/lanes`');

export function detectInventoryDrift(claudeMd) {
  for (const line of claudeMd.split(/\r?\n/)) {
    if (isPointerLine(line)) continue;                    // exempt the pointer line (I5)
    for (const n of NEEDLES) {
      if (line.includes(n)) return `CLAUDE.md re-introduces a hardcoded lane-inventory token ("${n}"). Move it to scripts/lanes/lanes.json; query via /lanes.`;
    }
  }
  return null;
}

// CLI: read CLAUDE.md bytes from stdin (hook pipes `git show :CLAUDE.md` — the staged index, R1 M7).
if (process.argv[1]?.endsWith('check.mjs')) {
  const chunks = [];
  process.stdin.on('data', (c) => chunks.push(c));
  process.stdin.on('end', () => {
    const drift = detectInventoryDrift(Buffer.concat(chunks).toString('utf8'));
    if (drift) { process.stderr.write('lanes-inventory-guard: ' + drift + '\n'); process.exit(1); }
    process.exit(0);
  });
}
