import { describe, it, expect } from 'vitest';
import { formatTransitions } from './transitions.js';
import type { JiraTransition } from '../types.js';

describe('formatTransitions', () => {
  it('formats id<TAB>name per line', () => {
    const transitions: JiraTransition[] = [
      { id: '11', name: 'To Do' },
      { id: '21', name: 'In Progress' },
      { id: '31', name: 'Done' },
    ];
    expect(formatTransitions(transitions)).toBe(
      '11\tTo Do\n21\tIn Progress\n31\tDone',
    );
  });

  it('reports no transitions when array is empty', () => {
    expect(formatTransitions([])).toBe('No available transitions for this issue.');
  });

  it('preserves order from the API response', () => {
    const transitions: JiraTransition[] = [
      { id: '31', name: 'Done' },
      { id: '11', name: 'To Do' },
    ];
    // API may return transitions in a workflow-defined order that the
    // operator cares about; do not sort.
    expect(formatTransitions(transitions)).toBe('31\tDone\n11\tTo Do');
  });
});
