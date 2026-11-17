import { describe, expect, it } from '@jest/globals';
import { finishLost, finishReply, toolResponse, type PluginReply, type ToolResult } from '../src/tool-result.js';

const photo = (id: string) => ({ photo_id: id, reason: 'refused' });

const cases: Array<[string, boolean, PluginReply, ToolResult['outcome']]> = [
  ['refusal from a write', false, { error: 'no', effect: 'none' }, 'failed'],
  ['unmarked error from a write', false, { error: 'boom', effect: 'unknown' }, 'unknown'],
  ['unmarked error from a read', true, { error: 'boom', effect: 'unknown' }, 'failed'],
  ['data alone', false, { result: { data: { ok: 1 } } }, 'done'],
  ['nothing at all', false, { result: {} }, 'done'],
  ['data with a failed item', false, { result: { data: [1], failed: [photo('2')] } }, 'partial'],
  ['data with not found inputs', true, { result: { data: [1], not_found: ['x'] } }, 'partial'],
  ['data with remaining inputs', false, { result: { data: [1], remaining: [3] } }, 'partial'],
  ['data with a single-target problem', false, { result: { data: { written: 2 }, problem: 'third slider not kept' } }, 'partial'],
  ['failed items without data', false, { result: { failed: [photo('1')] } }, 'failed'],
  ['only not found inputs', false, { result: { not_found: ['x'] } }, 'failed'],
  ['only remaining inputs', false, { result: { remaining: ['1'] } }, 'failed'],
  ['an unknown item with data', false, { result: { data: [1], unknown: [photo('2')] } }, 'unknown'],
  ['an unknown item alone', false, { result: { unknown: [photo('2')], failed: [photo('3')] } }, 'unknown'],
  ['a write left by the call with only remaining inputs', false, { result: { remaining: ['1'], written: ['/out/new'] } }, 'unknown'],
];

describe('finishReply', () => {
  it.each(cases)('maps %s to its outcome', (_name, readOnly, reply, outcome) => {
    const result = finishReply(readOnly, reply);
    expect(result.outcome).toBe(outcome);
    const response = toolResponse(result);
    expect(response.isError === true).toBe(outcome !== 'done');
    if (result.outcome === 'done') {
      for (const key of ['error', 'failed', 'unknown', 'not_found', 'remaining']) expect(result).not.toHaveProperty(key);
    } else {
      expect(result.error.length).toBeGreaterThan(0);
    }
  });

  it('composes the error from the lists and the problem', () => {
    const result = finishReply(false, { result: {
      data: [1], failed: [photo('2')], remaining: [3, 4], problem: 'stopped on cancel',
    } });
    expect(result).toEqual({
      outcome: 'partial', data: [1], failed: [photo('2')], remaining: [3, 4],
      error: '1 failed, 2 not reached (resend remaining); stopped on cancel',
    });
  });

  it('names the writes the call left beside the lists when no item claims them', () => {
    expect(finishReply(false, { result: { failed: [photo('2')], remaining: [3], written: ['/out/new', 'Undo'] } }))
      .toEqual({
        outcome: 'unknown', failed: [photo('2')], remaining: [3],
        error: '1 failed, 1 not reached (resend remaining); written before this stopped: /out/new, Undo',
      });
  });

  it('omits empty lists and keeps warnings with any outcome', () => {
    expect(finishReply(false, { result: { data: 1, failed: [], warnings: ['view not restored'] } }))
      .toEqual({ outcome: 'done', data: 1, warnings: ['view not restored'] });
  });
});

describe('finishLost', () => {
  it.each([
    [false, true, 'unknown'],
    [true, true, 'failed'],
    [false, false, 'failed'],
  ] as const)('a lost reply (read-only %s, sent %s) is %s', (readOnly, sent, outcome) => {
    expect(finishLost(readOnly, 'connection lost', sent)).toEqual({ outcome, error: 'connection lost' });
  });
});

describe('toolResponse', () => {
  it('moves a preview image out of data into an image block', () => {
    const response = toolResponse({ outcome: 'done', data: { width: 2, image: { data: 'abc', mime_type: 'image/jpeg' } } });
    expect(JSON.parse(response.content[0].text)).toEqual({ outcome: 'done', data: { width: 2 } });
    expect(response.content[1]).toEqual({ type: 'image', data: 'abc', mimeType: 'image/jpeg' });
    expect(response.isError).toBeUndefined();
  });
});
