#!/usr/bin/env bash
# HIMMEL-4019: catalog availability vs an independent station observation.
# Contract: fail on absence, undocumented installs, stale prose, malformed input;
# no existing suite compares this boundary. JSON/cache arguments serve real
# station checks too; no test-only production seam or live operator state.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
checker = root / 'scripts/check-tooling-catalog.sh'
# Independent read-only observation, 2026-10-02: registry + retained caches.
# Do not derive this oracle from the catalog or profile registry under test.
groups = {
    'claude-plugins-official': '''agent-sdk-dev claude-code-setup claude-md-management
        code-review code-simplifier coderabbit commit-commands context7 feature-dev
        frontend-design github gopls-lsp hookify mattpocock-skills mcp-server-dev
        playground playwright plugin-dev pr-review-toolkit pyright-lsp ralph-loop
        rust-analyzer-lsp security-guidance skill-creator superpowers telegram typescript-lsp''',
    'himmel': '''ai-image-prompts animejs-skills anthropic-design-skills anydesign
        builder-visual claude-obsidian design-dna diagram-design emilkowalski-skills
        frontend-slides gsap-skills hallmark handover himmel-ops impeccable lean-skills
        lottie-motion-design luna-correlate motion-lexicon obsidian-triage
        plannotator-effective-html platform-design-skills pr-review-toolkit-himmel
        qmd shadcn-mcp taste-skill-core taste-skill-imagegen taste-skill-styles
        telegram-himmel threejs-skills ui-ux-pro-max''',
    'openai-codex': 'codex', 'ponytail': 'ponytail', 'scroll-world': 'scroll-world',
    'obsidian-skills': 'obsidian', 'ui-ux-pro-max-skill': 'ui-ux-pro-max',
    'claude-video': 'watch',
}
snapshot = sorted(f'{name}@{market}' for market, names in groups.items() for name in names.split())
count = 0
with tempfile.TemporaryDirectory(prefix='tooling-catalog-') as tmp:
    tmp = Path(tmp)
    installed, catalog = tmp / 'installed.json', tmp / 'catalog.md'

    def run(label, ids, text=None, expected=0, message=None, extra=()):
        global count
        installed.write_text(json.dumps(ids))
        args = ['bash', str(checker), '--installed', str(installed)]
        if text is not None:
            catalog.write_text(text)
            args += ['--catalog', str(catalog)]
        result = subprocess.run(args + list(extra), capture_output=True, text=True)
        output = result.stdout + result.stderr
        assert result.returncode == expected, f'{label}: rc={result.returncode}\n{output}'
        if message:
            assert message in output, f'{label}: missing {message!r}\n{output}'
        count += 1
        print(f'ok - {label}')

    def table(rows):
        return ('<!-- plugin-installation-inventory -->\n| Plugin ID | Installation |\n'
                '|-----------|--------------|\n' + '\n'.join(f'| `{name}` | {state} |' for name, state in rows)
                + '\n<!-- /plugin-installation-inventory -->\n')

    one = table([('code-review@claude-plugins-official', 'INSTALLED'), ('qmd@qmd', 'NOT INSTALLED')])
    run('station snapshot agrees with real tooling-catalog.md', snapshot)
    run('matching presence and absence', ['code-review@claude-plugins-official'], one)
    run('installed but documented absent', ['qmd@qmd'], one, 1, 'catalog=NOT INSTALLED, observed=INSTALLED')
    run('documented install is missing', [], one, 1, 'catalog=INSTALLED, observed=NOT INSTALLED')
    run('undocumented install is rejected', ['typo@market'], one, 1, 'typo@market: catalog=MISSING')
    run('full IDs distinguish marketplaces', ['code-review@other'], one, 1, 'code-review@other: catalog=MISSING')
    run('duplicate rows rejected', [], table([('qmd@qmd', 'NOT INSTALLED')] * 2), 1, 'duplicate inventory ID')
    run('unknown state rejected', [], table([('qmd@qmd', 'MAYBE')]), 1, 'invalid inventory row')
    # A malformed absent-ID claim must fail, not disappear behind a valid row.
    # Existing malformed-state tests retain the opening backtick and miss this.
    for label, row in (
        ('unquoted ID', '| qmd@qmd | INSTALLED |'),
        ('missing opening backtick', '| qmd@qmd` | INSTALLED |'),
        ('missing closing backtick', '| `qmd@qmd | INSTALLED |'),
        ('missing opening pipe', '`qmd@qmd` | INSTALLED |'),
        ('missing closing pipe', '| `qmd@qmd` | INSTALLED'),
        ('non-table claim', 'qmd@qmd INSTALLED'),
    ):
        malformed = table([('code-review@claude-plugins-official', 'INSTALLED')]).replace(
            '<!-- /plugin-installation-inventory -->', row + '\n<!-- /plugin-installation-inventory -->')
        run(f'{label} rejected', ['code-review@claude-plugins-official'], malformed, 1, 'invalid inventory row')
    run('missing inventory rejected', [], '# empty', 1, 'exactly one plugin installation inventory')
    run('empty inventory rejected', [], table([]), 1, 'inventory is empty')
    run('invalid installed IDs rejected', ['not-an-id'], one, 1, 'array of plugin@marketplace IDs')
    run('malformed registry rejected', {'plugins': []}, one, 1, 'plugins object of record arrays')
    run('native registry accepts nonempty records only', {'plugins': {'code-review@claude-plugins-official': [{}], 'qmd@qmd': []}}, one)
    run('stale descriptive table rejected', ['code-review@claude-plugins-official'],
        '| `code-review` | Review | NOT INSTALLED |\n' + one, 1, 'descriptive tier says NOT INSTALLED')
    cache = tmp / 'cache'
    (cache / 'claude-plugins-official/code-review/1.0.0').mkdir(parents=True)
    (cache / 'temp_git_example/repo/.git').mkdir(parents=True)
    (cache / 'empty/unused').mkdir(parents=True)
    run('cache includes versions, ignores temporary and empty trees', [], one, extra=('--cache', str(cache)))
    run('missing cache fails closed', [], one, 1, 'cache directory is missing', ('--cache', str(tmp / 'missing')))
    installed.write_text('{bad json')
    result = subprocess.run(['bash', str(checker), '--installed', str(installed)], capture_output=True, text=True)
    assert result.returncode == 1 and 'ERR tooling-catalog:' in result.stderr
    count += 1
    print('ok - invalid JSON fails closed')

# Data-only catalog membership must actually produce false in every managed
# profile; candidate names must not silently turn into enabled profiles.
js = '''
import { loadRegistry, resolveProfile } from './scripts/lanes/plugin-profiles.mjs';
const reg = loadRegistry();
const dormant = ['superpowers@claude-plugins-official', 'mattpocock-skills@claude-plugins-official',
                 'coderabbit@claude-plugins-official', 'ponytail@ponytail'];
for (const name of Object.keys(reg.profiles)) {
  if (name === 'operator') continue;
  const map = resolveProfile(reg, name, { installed: dormant }).enabledPlugins;
  for (const id of dormant) if (map[id] !== false) throw new Error(`${name} did not disable ${id}`);
}
'''
result = subprocess.run(['node', '--input-type=module', '-e', js], cwd=root, capture_output=True, text=True)
assert result.returncode == 0, result.stdout + result.stderr
count += 1
print('ok - dormant candidates remain off in every managed profile')
print(f'{count} tooling catalog checks passed')
PY
