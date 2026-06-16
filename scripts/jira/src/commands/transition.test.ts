import { describe, it, expect } from 'vitest';
import { findTransition } from './transition.js';
import type { JiraTransition } from '../types.js';

const transitions: JiraTransition[] = [
  { id: '11', name: 'To Do' },
  { id: '21', name: 'In Progress' },
  { id: '31', name: 'Done' },
];

describe('findTransition', () => {
  it('finds by exact name', () => {
    expect(findTransition(transitions, 'In Progress')).toEqual({
      id: '21',
      name: 'In Progress',
    });
  });

  it('finds case-insensitively', () => {
    expect(findTransition(transitions, 'in progress')).toEqual({
      id: '21',
      name: 'In Progress',
    });
  });

  it('returns undefined when not found', () => {
    expect(findTransition(transitions, 'Nonexistent')).toBeUndefined();
  });
});
