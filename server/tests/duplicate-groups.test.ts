import { describe, it, expect, jest } from '@jest/globals';
import { dataOf, envelopeOf } from './helpers/envelope.js';
import jpeg from 'jpeg-js';
import { createCallToolHandler } from '../src/tool-handler.js';
import type { PluginResponse } from '../src/dispatcher.js';

function image(reverse = false) {
  const data = Buffer.alloc(90 * 80 * 4);
  for (let y = 0; y < 80; y++) {
    for (let x = 0; x < 90; x++) {
      const i = (y * 90 + x) * 4;
      data.fill(reverse ? 250 - x * 2 : x * 2, i, i + 3);
      data[i + 3] = 255;
    }
  }
  return jpeg.encode({ width: 90, height: 80, data }, 100).data.toString('base64');
}
const forward = image(), reversed = image(true);
function preview(id: number, time: number = id, data = forward): PluginResponse {
  return { id: 'test', result: { data: { photo_id: String(id), capture_time: time, image: { mime_type: 'image/jpeg', data } } } };
}
function failed(id: number, reason: string): PluginResponse {
  return { id: 'test', result: { failed: [{ photo_id: String(id), reason }] } };
}
function handler(call: (action: string, args: unknown, timeoutMs?: number) => Promise<PluginResponse>) {
  return createCallToolHandler({ admitted: () => 0, dispatcher: { call } });
}
interface Result {
  groups: { photo_ids: string[] }[];
  photos: { photo_id: string; capture_time: number }[];
}

describe('duplicate groups', () => {
  it('hashes a full-size 20 MP preview', async () => {
    const data = Buffer.alloc(5000 * 4000 * 4, 128);
    const full = jpeg.encode({ width: 5000, height: 4000, data }, 90).data.toString('base64');
    const call = handler(async (_action, args) => preview((args as { photo_ids: number[] }).photo_ids[0], 1, full));
    const response = await call('find_duplicate_groups', { photo_ids: [1] });
    expect(envelopeOf(response).failed).toBeUndefined();
    expect((dataOf(response) as Result).photos).toEqual([{ photo_id: '1', capture_time: 1 }]);
  });

  it('signals require both nearby capture time and similar content', async () => {
    const call = handler(async (action, args) => {
      expect(action).toBe('render_duplicate_preview');
      const id = (args as { photo_ids: number[] }).photo_ids[0];
      return preview(id, id === 3 ? 600 : id, id === 4 ? reversed : forward);
    });
    const response = await call('find_duplicate_groups', { photo_ids: [1, 2, 3, 4] });
    const result = dataOf(response) as Result;
    expect(envelopeOf(response).outcome).toBe('done');
    expect(result.groups).toEqual([{ photo_ids: ['1', '2'] }]);
    expect(result.photos[0]).toEqual({ photo_id: '1', capture_time: 1 });
    expect(response.content).toHaveLength(1);
  });

  it('lists failed previews and invalid JPEGs as failed and unknown photos as not_found', async () => {
    const call = handler(async (_action, args) => {
      const id = (args as { photo_ids: (number | string)[] }).photo_ids[0];
      if (id === 2) return failed(2, 'Preview failed');
      if (id === '/missing.jpg') return { id: 'test', result: { not_found: [id] } };
      return preview(Number(id), 1, id === 4 ? 'broken' : forward);
    });
    const response = await call('find_duplicate_groups', { photo_ids: [1, 2, 4, 5, '/missing.jpg'] });
    const envelope = envelopeOf(response);
    expect(envelope.outcome).toBe('partial');
    expect((envelope.data as Result).groups).toEqual([{ photo_ids: ['1', '5'] }]);
    expect(envelope.failed).toEqual([
      { photo_id: '2', reason: 'Preview failed' },
      { photo_id: '4', reason: expect.any(String) },
    ]);
    expect(envelope.not_found).toEqual(['/missing.jpg']);
    expect(envelope.remaining).toBeUndefined();
  });

  it('limits reject more than 100 ids before dispatch', async () => {
    const dispatch = jest.fn(async () => preview(1));
    const response = await handler(dispatch)('find_duplicate_groups', { photo_ids: Array<number>(101).fill(1) });
    expect(response.isError).toBe(true);
    expect(response.content[0].text).toMatch(/100/);
    expect(dispatch).not.toHaveBeenCalled();
  });

  it('keeps the groups found when the plug-in call itself fails, leaving that frame and the rest remaining', async () => {
    const call = handler(async (_action, args) => {
      const id = (args as { photo_ids: number[] }).photo_ids[0];
      if (id === 3) throw new Error('Plugin request timed out');
      return preview(id);
    });
    const envelope = envelopeOf(await call('find_duplicate_groups', { photo_ids: [1, 2, 3, 4] }));
    expect((envelope.data as Result).groups).toEqual([{ photo_ids: ['1', '2'] }]);
    expect(envelope.remaining).toEqual([3, 4]);
    expect(envelope.warnings).toEqual([expect.stringContaining('Plugin request timed out')]);
  });

  it('deduplicates ids and applies inclusive caller thresholds to every pair', async () => {
    const call = handler(async (_action, args) => {
      const id = (args as { photo_ids: number[] }).photo_ids[0];
      return preview(id, (id - 1) * 5);
    });
    const response = await call('find_duplicate_groups', {
      photo_ids: [1, 1, 2, 3], time_window_seconds: 5, max_hamming_distance: 0,
    });
    expect((dataOf(response) as Result).groups).toEqual([{ photo_ids: ['1', '2'] }]);
  });
});
