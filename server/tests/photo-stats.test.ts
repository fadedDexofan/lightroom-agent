import { describe, it, expect } from '@jest/globals';
import { dataOf, envelopeOf } from './helpers/envelope.js';
import jpeg from 'jpeg-js';
import { createCallToolHandler } from '../src/tool-handler.js';
import { photoStats } from '../src/photo-stats.js';
import type { PluginResponse } from '../src/dispatcher.js';

function image(width: number, height: number, value: (x: number, y: number) => number) {
  const data = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const offset = (y * width + x) * 4;
      data.fill(Math.round(value(x, y)), offset, offset + 3);
      data[offset + 3] = 255;
    }
  }
  return jpeg.encode({ width, height, data }, 100).data.toString('base64');
}

function handler(call: (action: string, params: unknown, timeoutMs?: number) => Promise<PluginResponse>) {
  return createCallToolHandler({ admitted: () => 0, dispatcher: { call } });
}

function preview(data: string, photoId = '1'): PluginResponse {
  return { id: 'preview', result: { data: { photo_id: photoId, image: { data, mime_type: 'image/jpeg' } } } };
}

describe('photo stats', () => {
  const flat = image(16, 16, () => 128);
  const idOf = (params: unknown) => (params as { photo_ids: number[] }).photo_ids[0];

  it('keeps the results measured when the plug-in call itself fails', async () => {
    const response = await handler(async (_action, params) => {
      if (idOf(params) === 2) throw new Error('Plugin request timed out');
      return preview(flat, String(idOf(params)));
    })('get_photo_stats', { photo_ids: [1, 2, 3] });
    const envelope = envelopeOf(response);
    expect((envelope.data as { results: { photo_id: string }[] }).results.map((result) => result.photo_id)).toEqual(['1']);
    expect(envelope.remaining).toEqual([2, 3]);
    expect(envelope.warnings).toEqual([expect.stringContaining('Plugin request timed out')]);
  });

  it('measures a full-size 20 MP preview', async () => {
    const full = image(5000, 4000, () => 128);
    const response = await handler(async () => preview(full))('get_photo_stats', { photo_ids: [1] });
    const [result] = (dataOf(response) as { results: ReturnType<typeof photoStats>[] }).results;
    expect([result.width, result.height]).toEqual([5000, 4000]);
    expect(result.mean_luminance).toBeCloseTo(128, 0);
  });

  it.each([
    { name: 'white', value: 255, shadow: 0, highlight: 1, bin: 63 },
    { name: 'black', value: 0, shadow: 1, highlight: 0, bin: 0 },
    { name: 'mid-gray', value: 128, shadow: 0, highlight: 0, bin: 32 },
  ])('clipping for $name JPEG', async ({ value, shadow, highlight, bin }) => {
    const call = handler(async (action, params) => {
      expect(action).toBe('render_preview');
      expect(params).toEqual({ photo_ids: [1], size: 512 });
      return preview(image(32, 32, () => value));
    });

    const response = await call('get_photo_stats', { photo_ids: [1] });
    const data = dataOf(response) as { results: ReturnType<typeof photoStats>[] };

    expect(response.content).toHaveLength(1);
    expect(data.results[0].shadow_fraction).toBe(shadow);
    expect(data.results[0].highlight_fraction).toBe(highlight);
    expect(data.results[0].histogram[bin]).toBe(1);
    expect(data.results[0].mean_luminance).toBeCloseTo(value, 0);
    expect(data.results[0].sharpness).toBe(0);
  });

  it('sharpness ranks a checkerboard at least twice its box blur', () => {
    const checker = (x: number, y: number) => (Math.floor(x / 16) + Math.floor(y / 16)) % 2 * 255;
    const rowSums = Array.from({ length: 516 }, (_, y) => Array.from({ length: 512 }, (_, x) => {
      let total = 0;
      for (let dx = -4; dx <= 4; dx++) total += checker(Math.max(0, x + dx), y);
      return total;
    }));
    const blurred = (x: number, y: number) => {
      let total = 0;
      for (let dy = -4; dy <= 4; dy++) total += rowSums[Math.max(0, y + dy)][x];
      return total / 81;
    };

    const sharp = photoStats(Buffer.from(image(512, 512, checker), 'base64'));
    const soft = photoStats(Buffer.from(image(512, 512, blurred), 'base64'));

    expect(sharp.sharpness).toBeGreaterThanOrEqual(soft.sharpness * 2);
  });

  it('scale keeps scores within 25 percent at 512 and 1024 pixels', () => {
    const smaller = image(512, 256, (x, y) => (Math.floor(x / 16) + Math.floor(y / 16)) % 2 * 255);
    const larger = image(1024, 512, (x, y) => (Math.floor(x / 32) + Math.floor(y / 32)) % 2 * 255);

    const ratio = photoStats(Buffer.from(larger, 'base64')).sharpness / photoStats(Buffer.from(smaller, 'base64')).sharpness;

    expect(ratio).toBeGreaterThanOrEqual(0.75);
    expect(ratio).toBeLessThanOrEqual(1.25);
  });

  it('batch preserves input order, names photos by string id and lists an unknown photo as not_found', async () => {
    const encoded = image(8, 8, () => 128);
    const call = handler(async (_action, params) => {
      const { photo_ids } = params as { photo_ids: number[] };
      return photo_ids[0] === 2 ? { id: 'missing', result: { not_found: [2] } } : preview(encoded, String(photo_ids[0]));
    });

    const response = await call('get_photo_stats', { photo_ids: [1, 2, 3] });
    const envelope = envelopeOf(response);

    expect(envelope.outcome).toBe('partial');
    expect(envelope.data).toEqual({ results: [
      expect.objectContaining({ photo_id: '1', mean_luminance: 128 }),
      expect.objectContaining({ photo_id: '3', mean_luminance: 128 }),
    ] });
    expect(envelope.not_found).toEqual([2]);
  });

  it.each([
    { name: 'too many ids', photo_ids: Array<number>(21).fill(1), message: /20/ },
    { name: 'no ids', photo_ids: [], message: /1/ },
  ])('batch rejects $name', async ({ photo_ids, message }) => {
    const call = handler(async () => { throw new Error('unexpected dispatch'); });

    const response = await call('get_photo_stats', { photo_ids });

    expect(response.isError).toBe(true);
    expect(response.content[0].text).toMatch(message);
  });

  it('batch lists invalid JPEG data and a failed preview as failed items', async () => {
    let count = 0;
    const encoded = image(8, 8, () => 110);
    const call = handler(async () => {
      count++;
      if (count === 3) return { id: 'preview', result: { failed: [{ photo_id: '3', reason: 'Preview failed' }] } };
      return preview(count === 2 ? 'broken' : encoded, String(count));
    });

    const response = await call('get_photo_stats', { photo_ids: [1, 2, 3] });
    const envelope = envelopeOf(response);

    expect(envelope.data).toEqual({ results: [expect.objectContaining({ photo_id: '1', mean_luminance: 110 })] });
    expect(envelope.failed).toEqual([
      { photo_id: '2', reason: expect.any(String) },
      { photo_id: '3', reason: 'Preview failed' },
    ]);
  });

  it('size serializes one photo below 1500 characters', async () => {
    const encoded = image(256, 256, (x, y) => (x * 19 + y * 7) % 256);
    const call = handler(async () => preview(encoded));

    const response = await call('get_photo_stats', { photo_ids: [1] });

    expect(response.content[0].text.length).toBeLessThanOrEqual(1500);
  });
});
