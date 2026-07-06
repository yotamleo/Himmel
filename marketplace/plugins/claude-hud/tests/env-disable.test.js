import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isHudDisabled, main } from '../dist/index.js';
import { DEFAULT_CONFIG } from '../dist/config.js';

function restoreEnvVar(name, value) {
  if (value === undefined) {
    delete process.env[name];
    return;
  }
  process.env[name] = value;
}

test('isHudDisabled: any affirmative value disables the HUD', () => {
  for (const value of ['1', 'true', 'TRUE', 'yes', 'on', ' 1 ', '\ttrue']) {
    assert.equal(isHudDisabled({ CLAUDE_HUD_DISABLE: value }), true, `CLAUDE_HUD_DISABLE=${JSON.stringify(value)}`);
  }
});

test('isHudDisabled: unset, empty, or explicit negatives keep the HUD enabled', () => {
  for (const env of [{}, { CLAUDE_HUD_DISABLE: '' }, { CLAUDE_HUD_DISABLE: ' ' }, { CLAUDE_HUD_DISABLE: '0' }, { CLAUDE_HUD_DISABLE: 'false' }, { CLAUDE_HUD_DISABLE: 'OFF' }, { CLAUDE_HUD_DISABLE: 'no' }]) {
    assert.equal(isHudDisabled(env), false, `env=${JSON.stringify(env)}`);
  }
});

test('main: CLAUDE_HUD_DISABLE=1 exits before reading stdin and prints nothing', async () => {
  const original = process.env.CLAUDE_HUD_DISABLE;
  process.env.CLAUDE_HUD_DISABLE = '1';
  const calls = [];
  try {
    await main({
      readStdin: async () => {
        calls.push('readStdin');
        return null;
      },
      log: (...args) => {
        calls.push(['log', ...args]);
      },
      render: () => {
        calls.push('render');
      },
    });
  } finally {
    restoreEnvVar('CLAUDE_HUD_DISABLE', original);
  }
  assert.deepEqual(calls, []);
});

test('main: explicit negative CLAUDE_HUD_DISABLE value still runs the HUD', async () => {
  const original = process.env.CLAUDE_HUD_DISABLE;
  process.env.CLAUDE_HUD_DISABLE = '0';
  const logged = [];
  try {
    await main({
      readStdin: async () => null,
      loadConfig: async () => DEFAULT_CONFIG,
      log: (...args) => {
        logged.push(args.join(' '));
      },
    });
  } finally {
    restoreEnvVar('CLAUDE_HUD_DISABLE', original);
  }
  assert.ok(logged.length > 0, 'expected the no-stdin setup message to be logged');
});
