#!/usr/bin/env bash
# HIMMEL-4019: compare documented availability with an explicit installation
# observation. No implicit HOME access, network, installs or enablement changes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT/docs/tooling-catalog.md" "$@" <<'PY'
import argparse
import json
import re
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description='Check tooling catalog against installed/cached plugin IDs')
parser.add_argument('--catalog', type=Path, default=Path(sys.argv[1]))
parser.add_argument('--installed', type=Path, required=True,
                    help='JSON array of plugin@marketplace IDs, or installed_plugins.json')
parser.add_argument('--cache', type=Path, help='Optional plugin cache directory to include retained artifacts')
args = parser.parse_args(sys.argv[2:])
id_re = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_-]*@[a-zA-Z0-9][a-zA-Z0-9_-]*$')
try:
    data = json.loads(args.installed.read_text())
    if isinstance(data, dict):
        plugins = data.get('plugins')
        if not isinstance(plugins, dict) or any(not isinstance(v, list) for v in plugins.values()):
            raise ValueError('installed registry must contain a plugins object of record arrays')
        data = [k for k, v in plugins.items() if v]
    if not isinstance(data, list) or any(not isinstance(v, str) or not id_re.fullmatch(v) for v in data):
        raise ValueError('installed set must be an array of plugin@marketplace IDs')
    installed = set(data)
    if args.cache is not None:
        if not args.cache.is_dir():
            raise ValueError(f'cache directory is missing: {args.cache}')
        for market in args.cache.iterdir():
            # Claude leaves temporary clone trees alongside marketplace caches.
            if not market.is_dir() or market.name.startswith('temp_'):
                continue
            for plugin in market.iterdir():
                plugin_id = f'{plugin.name}@{market.name}'
                if (plugin.is_dir() and id_re.fullmatch(plugin_id)
                        and any(version.is_dir() for version in plugin.iterdir())):
                    installed.add(plugin_id)
    text = args.catalog.read_text()
    start, end = '<!-- plugin-installation-inventory -->', '<!-- /plugin-installation-inventory -->'
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError('catalog must contain exactly one plugin installation inventory')
    if text.index(end) < text.index(start):
        raise ValueError('inventory end marker must follow start marker')
    section = text.split(start, 1)[1].split(end, 1)[0]
    documented = {}
    for line in section.splitlines():
        line = line.strip()
        if not line:
            continue
        cells = [v.strip() for v in line.strip('|').split('|')]
        if not line.startswith('|') or not line.endswith('|') or len(cells) != 2:
            raise ValueError(f'invalid inventory row: {line}')
        if cells == ['Plugin ID', 'Installation'] or all(re.fullmatch(r':?-+:?', v) for v in cells):
            continue
        quoted_id = re.fullmatch(r'`([^`]+)`', cells[0])
        if not quoted_id:
            raise ValueError(f'invalid inventory row: {line}')
        plugin_id, status = quoted_id.group(1), cells[1]
        if not id_re.fullmatch(plugin_id) or status not in ('INSTALLED', 'NOT INSTALLED'):
            raise ValueError(f'invalid inventory row: {line}')
        if plugin_id in documented:
            raise ValueError(f'duplicate inventory ID: {plugin_id}')
        documented[plugin_id] = status
    if not documented:
        raise ValueError('catalog plugin installation inventory is empty')
except (OSError, ValueError) as exc:
    print(f'ERR tooling-catalog: {exc}', file=sys.stderr)
    sys.exit(1)

errors = []
for plugin_id in sorted(installed | documented.keys()):
    expected = 'INSTALLED' if plugin_id in installed else 'NOT INSTALLED'
    actual = documented.get(plugin_id, 'MISSING')
    if actual != expected:
        errors.append(f'{plugin_id}: catalog={actual}, observed={expected}')
# The descriptive tables must not contradict the inventory. Bare names in the
# official table belong to the official marketplace (lean-skills is the fork).
for line in text.split('## Plugins (third-party marketplaces)', 1)[0].splitlines():
    if not line.startswith('| `'):
        continue
    cells = [v.strip() for v in line.strip().strip('|').split('|')]
    name = cells[0].strip('`')
    if '@' in name or len(cells) != 3:
        continue
    plugin_id = f'{name}@claude-plugins-official'
    if plugin_id in installed and 'NOT INSTALLED' in cells[-1]:
        errors.append(f'{plugin_id}: descriptive tier says NOT INSTALLED but artifact is present')
if errors:
    print('ERR tooling-catalog disagrees with installed set:', file=sys.stderr)
    print('\n'.join(f'  {error}' for error in errors), file=sys.stderr)
    sys.exit(1)
print(f'tooling-catalog: {len(installed)} installed/cached IDs agree ({len(documented)} catalog rows)')
PY
