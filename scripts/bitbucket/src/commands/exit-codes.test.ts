import { describe, it, expect } from 'vitest';
import { exitFor } from './exit-codes.js';
import { BitbucketHttpError } from '../client.js';

describe('exitFor (command-layer error→exit mapping, HIMMEL-341)', () => {
  it('maps a listed status to its special code, surfacing the message verbatim', () => {
    // issue create / issue get: 404 (issues-disabled or gone) → exit 3.
    const err = new BitbucketHttpError(
      'bitbucket: issue create failed: issue tracker is disabled on this repository (404)',
      404,
      null,
    );
    expect(exitFor(err, 'issue create', { 404: 3 })).toEqual({
      code: 3,
      message: err.message,
    });
  });

  it('maps pr merge 400-conflict to exit 2', () => {
    const err = new BitbucketHttpError('bitbucket: pr merge 5 failed: conflict', 400, null);
    expect(exitFor(err, 'pr merge', { 400: 2 })).toEqual({ code: 2, message: err.message });
  });

  it('maps a non-numeric id (synthetic status 0) to exit 1, NOT the 404 special', () => {
    // getIssue throws BitbucketHttpError(..., 0, null) for a non-numeric id.
    // 0 is not in the special map → generic exit 1 with the prefixed message.
    const err = new BitbucketHttpError('bitbucket: issue get requires a numeric id, got: abc', 0, null);
    expect(exitFor(err, 'issue get', { 404: 3 })).toEqual({
      code: 1,
      message: `bitbucket: issue get failed: ${err.message}`,
    });
  });

  it('maps a BitbucketHttpError with an unlisted status to exit 1', () => {
    // pr comments has no special map — a 404 there is just a generic failure.
    const err = new BitbucketHttpError('bitbucket: pr comments failed: HTTP 404', 404, null);
    expect(exitFor(err, 'pr comments')).toEqual({
      code: 1,
      message: `bitbucket: pr comments failed: ${err.message}`,
    });
  });

  it('maps a status that is listed but does not match to exit 1', () => {
    // pr merge maps 400→2; a 500 falls through to generic exit 1.
    const err = new BitbucketHttpError('bitbucket: pr merge failed: HTTP 500', 500, null);
    expect(exitFor(err, 'pr merge', { 400: 2 })).toEqual({
      code: 1,
      message: `bitbucket: pr merge failed: ${err.message}`,
    });
  });

  it('maps a generic non-Bitbucket Error to exit 1 with the prefixed message', () => {
    const err = new Error('ENOENT: no such file');
    expect(exitFor(err, 'issue create', { 404: 3 })).toEqual({
      code: 1,
      message: 'bitbucket: issue create failed: ENOENT: no such file',
    });
  });

  it('does not crash on a thrown non-Error value (String fallback)', () => {
    // The failure path must never throw on a primitive/null throw — it would
    // escape the handler with an unmapped exit code.
    expect(exitFor('boom', 'pr create')).toEqual({
      code: 1,
      message: 'bitbucket: pr create failed: boom',
    });
    expect(exitFor(null, 'pr create')).toEqual({
      code: 1,
      message: 'bitbucket: pr create failed: null',
    });
  });
});
