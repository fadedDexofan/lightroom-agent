import { describe, expect, it, jest } from '@jest/globals';
import { dataOf, envelopeOf } from './helpers/envelope.js';
import jpeg from 'jpeg-js';
import { createCallToolHandler } from '../src/tool-handler.js';
import { TOOL_CONTRACTS } from '../src/tool-contracts.js';
import type { PluginResponse } from '../src/dispatcher.js';
import { areaAverage } from '../src/rendered-image.js';

const MAX_BYTES = 3.5 * 1024 * 1024;

function halves(width: number, height: number): string {
  const data = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      data[i + (x < width / 2 ? 0 : 1)] = 255;
      data[i + 3] = 255;
    }
  }
  return jpeg.encode({ width, height, data }, 100).data.toString('base64');
}

function noise(width: number, height: number): string {
  const data = Buffer.alloc(width * height * 4);
  let seed = 7;
  for (let i = 0; i < data.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    data[i] = seed >> 23;
  }
  return jpeg.encode({ width, height, data }, 100).data.toString('base64');
}

function rendered(image: string, photoId: number | string = 914): PluginResponse {
  return { id: 'preview', result: { data: { photo_id: photoId, image: { mime_type: 'image/jpeg', data: image } } } };
}

function makeHandler(response: PluginResponse = rendered(halves(32, 16))) {
  const call = jest.fn(async (_action: string, _args: unknown, _timeout?: number, _options?: unknown) => response);
  return { handler: createCallToolHandler({ isReady: () => true, dispatcher: { call } }), call };
}

function returnedImage(result: Awaited<ReturnType<ReturnType<typeof makeHandler>['handler']>>) {
  const image = result.content[1];
  if (image?.type !== 'image') throw new Error('Expected a JPEG');
  const encoded = Buffer.from(image.data, 'base64');
  return { encoded, decoded: jpeg.decode(encoded) };
}

describe('get_photo_preview', () => {
  it('returns a preview no larger than requested unchanged, byte for byte', async () => {
    const source = halves(32, 16);
    const { handler, call } = makeHandler(rendered(source));
    const result = await handler('get_photo_preview', { photo_id: 914, size: 1024 });
    expect(call).toHaveBeenCalledWith('render_preview', { photo_ids: [914], size: 1024 }, 30_000, undefined);
    const { encoded } = returnedImage(result);
    expect(encoded.toString('base64')).toBe(source);
    expect(dataOf(result)).toEqual({
      photo_id: '914', requested_size: 1024, width: 32, height: 16, bytes: encoded.length, scaled_by_server: false,
    });
  });

  it('scales a preview larger than the requested edge down to that edge', async () => {
    const { handler } = makeHandler(rendered(halves(128, 64)));
    const result = await handler('get_photo_preview', { photo_id: 914, size: 64 });
    const { encoded, decoded } = returnedImage(result);
    expect([decoded.width, decoded.height]).toEqual([64, 32]);
    expect(dataOf(result)).toEqual({
      photo_id: '914', requested_size: 64, width: 64, height: 32, bytes: encoded.length, scaled_by_server: true,
    });
    const at = (x: number) => Array.from(decoded.data.subarray((16 * 64 + x) * 4, (16 * 64 + x) * 4 + 3));
    expect(at(8)[0]).toBeGreaterThan(250);
    expect(at(56)[1]).toBeGreaterThan(250);
  });

  it('brings a full-size JPEG over the byte limit within the edge and byte limits', async () => {
    const source = noise(2400, 1600);
    expect(Buffer.from(source, 'base64').length).toBeGreaterThan(MAX_BYTES);
    const { handler } = makeHandler(rendered(source));
    const result = await handler('get_photo_preview', { photo_id: 914, size: 2048 });
    const { encoded, decoded } = returnedImage(result);
    expect([decoded.width, decoded.height]).toEqual([2000, 1333]);
    expect(encoded.length).toBeLessThanOrEqual(MAX_BYTES);
    expect(dataOf(result)).toMatchObject({ requested_size: 2048, width: 2000, height: 1333, scaled_by_server: true });
  });

  it('asks Lightroom for the cull edge of 864 by default and rounds a fractional size down', async () => {
    const { handler, call } = makeHandler();
    await handler('get_photo_preview', { photo_id: 914 });
    await handler('get_photo_preview', { photo_id: 914, size: 512.5 });
    expect(call.mock.calls.map(([, params]) => params)).toEqual([
      { photo_ids: [914], size: 864 }, { photo_ids: [914], size: 512 },
    ]);
  });

  it('answers an image Lightroom could not render as failed for that photo', async () => {
    const { handler } = makeHandler({ id: 'preview', result: { failed: [{ photo_id: '914', reason: 'Preview failed: file is offline' }] } });
    const result = await handler('get_photo_preview', { photo_id: 914 });
    expect(envelopeOf(result)).toMatchObject({ outcome: 'failed', failed: [{ photo_id: '914', reason: 'Preview failed: file is offline' }] });
  });
});

describe('get_photo_preview region', () => {
  it('returns only the requested pixels and reports encoded dimensions and bytes', async () => {
    const { handler, call } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0.5, y: 0, width: 0.5, height: 0.5 },
    });

    expect(result.isError).toBeUndefined();
    expect(call).toHaveBeenCalledWith('render_preview', { photo_ids: [914], size: 1728 }, 30_000, undefined);
    const { encoded, decoded: cropped } = returnedImage(result);
    expect([cropped.width, cropped.height]).toEqual([16, 8]);
    expect(dataOf(result)).toEqual({
      photo_id: '914', requested_size: 1728, width: 16, height: 8, bytes: encoded.length, scaled_by_server: false,
    });
    for (let i = 0; i < cropped.data.length; i += 4) {
      expect(cropped.data[i]).toBeLessThan(5);
      expect(cropped.data[i + 1]).toBeGreaterThan(250);
      expect(cropped.data[i + 2]).toBeLessThan(5);
    }
  });

  it('crops a source over 2000 pixels after scaling it to a 2000 pixel edge', async () => {
    const { handler } = makeHandler(rendered(halves(2400, 1600)));
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0.5, y: 0, width: 0.5, height: 0.5 },
    });
    const { decoded } = returnedImage(result);
    expect([decoded.width, decoded.height]).toEqual([1000, 667]);
    expect(dataOf(result)).toMatchObject({ requested_size: 1728, width: 1000, height: 667, scaled_by_server: true });
  });

  it.each([
    { size: undefined, expected: 2048 },
    { size: 64, expected: 640 },
    { size: 2048, expected: 2048 },
  ])('requests a larger source for a small region (size=$size)', async ({ size, expected }) => {
    const { handler, call } = makeHandler();
    await handler('get_photo_preview', {
      photo_id: '/photo.raw', ...(size === undefined ? {} : { size }),
      region: { x: 0, y: 0, width: 0.1, height: 0.1 },
    });
    expect(call).toHaveBeenCalledWith('render_preview', { photo_ids: ['/photo.raw'], size: expected }, 30_000, undefined);
  });

  it.each([
    { size: 'cull', expected: 1728 },
    { size: 'review', expected: 2048 },
  ])('normalizes named size $size before applying region source scaling', async ({ size, expected }) => {
    const { handler, call } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, size, region: { x: 0, y: 0, width: 0.5, height: 0.5 },
    });
    expect(result.isError).toBeUndefined();
    expect(call).toHaveBeenCalledWith('render_preview', { photo_ids: [914], size: expected }, 30_000, undefined);
  });

  it('rounds a subpixel region outward to at least one pixel', async () => {
    const { handler } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0.999, y: 0.999, width: 0.001, height: 0.001 },
    });
    expect(result.isError).toBeUndefined();
    expect(dataOf(result)).toMatchObject({ width: 1, height: 1 });
  });

  it('returns a valid pixel when a positive region is smaller than floating-point spacing', async () => {
    const { handler } = makeHandler();
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0.5, y: 0.5, width: 1e-20, height: 1e-20 },
    });
    expect(result.isError).toBeUndefined();
    expect(dataOf(result)).toMatchObject({ width: 1, height: 1 });
    const { decoded } = returnedImage(result);
    expect([decoded.width, decoded.height, decoded.data.length]).toEqual([1, 1, 4]);
  });

  it.each([
    {}, { x: 0, y: 0, width: 0.2 }, null, [],
    { x: 0, y: 0, width: 0, height: 1 },
    { x: 0, y: 0, width: 1, height: -0.1 },
    { x: -0.1, y: 0, width: 0.1, height: 1 },
    { x: 1, y: 0, width: 0.1, height: 1 },
    { x: 0.9, y: 0, width: 0.5, height: 1 },
    { x: 0, y: 0.9, width: 1, height: 0.5 },
    { x: 0, y: 0, width: 0.1, height: 1, extra: true },
  ])('rejects malformed or out-of-frame region %j before rendering', async (region) => {
    const { handler, call } = makeHandler();
    const result = await handler('get_photo_preview', { photo_id: 914, region });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/region|extra/);
    expect(call).not.toHaveBeenCalled();
  });

  it('passes an unknown photo through as not_found instead of cropping nothing', async () => {
    const { handler } = makeHandler({ id: 'preview', result: { not_found: [914] } });
    const result = await handler('get_photo_preview', {
      photo_id: 914, region: { x: 0, y: 0, width: 0.1, height: 0.1 },
    });
    expect(envelopeOf(result)).toEqual({ outcome: 'failed', error: '1 not found', not_found: [914] });
  });

  it.each([
    { id: 'preview', result: null },
    { id: 'preview', result: { data: { photo_id: 914, image: { mime_type: 'image/png', data: 'broken' } } } },
    { id: 'preview', result: { data: { photo_id: 914, image: { mime_type: 'image/jpeg', data: 'broken' } } } },
    { id: 'preview', error: 'Photo not found: 914' },
  ])('returns an error without an image for unusable plugin response %j', async (response) => {
    for (const region of [undefined, { x: 0, y: 0, width: 0.1, height: 0.1 }]) {
      const { handler } = makeHandler(response);
      const result = await handler('get_photo_preview', { photo_id: 914, ...(region ? { region } : {}) });
      expect(result.isError).toBe(true);
      expect(result.content).toHaveLength(1);
    }
  });
});

describe('get_photo_previews', () => {
  type Answer = (id: unknown) => PluginResponse;
  function batch(answer: Answer) {
    const call = jest.fn(async (_action: string, params: unknown, _timeout?: number, _options?: unknown) =>
      answer((params as { photo_ids: unknown[] }).photo_ids[0]));
    return { handler: createCallToolHandler({ isReady: () => true, dispatcher: { call } }), call };
  }
  const images = (result: Awaited<ReturnType<ReturnType<typeof batch>['handler']>>) =>
    result.content.slice(1).map((block) => {
      if (block.type !== 'image') throw new Error('Expected a JPEG');
      return jpeg.decode(Buffer.from(block.data, 'base64'));
    });

  it('renders each photo in input order at the requested edge and maps it to its image', async () => {
    const source = halves(512, 256);
    const { handler, call } = batch((id) => rendered(source, id as number));
    const result = await handler('get_photo_previews', { photo_ids: [3, 1, 2] });
    expect(call.mock.calls.map(([action, params]) => [action, params])).toEqual(
      [3, 1, 2].map((id) => ['render_preview', { photo_ids: [id], size: 256 }]));
    const data = dataOf(result) as { previews: Record<string, unknown>[] };
    expect(data.previews.map(({ photo_id, image_index, width, height, scaled_by_server }) =>
      [photo_id, image_index, width, height, scaled_by_server])).toEqual([
      ['3', 1, 256, 128, true], ['1', 2, 256, 128, true], ['2', 3, 256, 128, true],
    ]);
    expect(images(result).map(({ width, height }) => [width, height])).toEqual([[256, 128], [256, 128], [256, 128]]);
  });

  it('takes the same named sizes as get_photo_preview', async () => {
    const source = halves(512, 256);
    const { handler, call } = batch((id) => rendered(source, id as number));
    await handler('get_photo_previews', { photo_ids: [1], size: 'cull' });
    await handler('get_photo_previews', { photo_ids: [1], size: 'review' });
    expect(call.mock.calls.map(([, params]) => (params as { size: number }).size)).toEqual([864, 1728]);
  });

  it('keeps the good images and lists unknown photos as not_found and unrenderable ones as failed', async () => {
    const { handler } = batch((id) => {
      if (id === 2) return { id: 'preview', result: { not_found: [2] } };
      if (id === 3) return { id: 'preview', result: { failed: [{ photo_id: '3', reason: 'Preview failed: file is offline' }] } };
      if (id === 4) return rendered(Buffer.from('broken').toString('base64'), 4);
      return rendered(halves(32, 16), id as number);
    });
    const result = await handler('get_photo_previews', { photo_ids: [1, 2, 3, 4, 5] });
    const envelope = envelopeOf(result);
    expect(envelope.outcome).toBe('partial');
    expect((envelope.data as { previews: { photo_id: string }[] }).previews.map((preview) => preview.photo_id)).toEqual(['1', '5']);
    expect(envelope.not_found).toEqual([2]);
    expect(envelope.failed).toEqual([
      { photo_id: '3', reason: 'Preview failed: file is offline' },
      { photo_id: '4', reason: expect.any(String) },
    ]);
    expect(images(result)).toHaveLength(2);
  });

  it('leaves the photo that no longer fits the 8 MiB budget, and those after it, remaining', async () => {
    const source = noise(1000, 800);
    const bytes = Buffer.from(source, 'base64').length;
    expect(bytes).toBeLessThanOrEqual(MAX_BYTES);
    expect(3 * bytes).toBeGreaterThan(8 * 1024 * 1024);
    const { handler, call } = batch((id) => rendered(source, id as number));
    const result = await handler('get_photo_previews', { photo_ids: [1, 2, 3, 4], size: 2048 });
    const envelope = envelopeOf(result);
    expect((envelope.data as { previews: { bytes: number }[] }).previews.map((preview) => preview.bytes)).toEqual([bytes, bytes]);
    expect(envelope.remaining).toEqual([3, 4]);
    expect(envelope.failed).toBeUndefined();
    expect(call).toHaveBeenCalledTimes(3);
  });

  it('keeps a photo rendered across the 20 s deadline and leaves the unreached ones remaining', async () => {
    jest.useFakeTimers();
    try {
      const { handler, call } = batch((id) => {
        if (id === 2) jest.advanceTimersByTime(20_001);
        return rendered(halves(32, 16), id as number);
      });
      const envelope = envelopeOf(await handler('get_photo_previews', { photo_ids: [1, 2, 3, 4] }));
      expect((envelope.data as { previews: { photo_id: string }[] }).previews.map((preview) => preview.photo_id)).toEqual(['1', '2']);
      expect(envelope.remaining).toEqual([3, 4]);
      expect(call).toHaveBeenCalledTimes(2);
    } finally {
      jest.useRealTimers();
    }
  });

  it('lists a photo that ran out of time as remaining rather than failed', async () => {
    jest.useFakeTimers();
    try {
      const { handler, call } = batch((id) => {
        if (id !== 2) return rendered(halves(32, 16), id as number);
        jest.advanceTimersByTime(20_001);
        return { id: 'preview', result: { failed: [{ photo_id: '2', reason: "Preview not ready before the request's time ran out" }] } };
      });
      const envelope = envelopeOf(await handler('get_photo_previews', { photo_ids: [1, 2, 3] }));
      expect(envelope.remaining).toEqual([2, 3]);
      expect(envelope.failed).toBeUndefined();
      expect(call).toHaveBeenCalledTimes(2);
    } finally {
      jest.useRealTimers();
    }
  });

  it('hands each plug-in call only the time the batch has left', async () => {
    jest.useFakeTimers();
    try {
      const { handler, call } = batch((id) => {
        if (id === 1) jest.advanceTimersByTime(5_000);
        return rendered(halves(32, 16), id as number);
      });
      await handler('get_photo_previews', { photo_ids: [1, 2] });
      expect(call.mock.calls.map(([, , timeout]) => timeout)).toEqual([30_000, 25_000]);
    } finally {
      jest.useRealTimers();
    }
  });

  it.each<[string, PluginResponse, string]>([
    ['an error', { id: 'preview', error: 'attempt to call a nil value', effect: 'unknown' }, 'attempt to call a nil value'],
    ['no preview', { id: 'preview', result: {} }, 'Plugin returned no preview'],
  ])('lists a photo the plug-in answered with %s as failed and goes on to the next', async (_name, answer, reason) => {
    const { handler, call } = batch((id) => (id === 2 ? answer : rendered(halves(32, 16), id as number)));
    const envelope = envelopeOf(await handler('get_photo_previews', { photo_ids: [1, 2, 3] }));
    expect((envelope.data as { previews: { photo_id: string }[] }).previews.map((preview) => preview.photo_id)).toEqual(['1', '3']);
    expect(envelope.failed).toEqual([{ photo_id: '2', reason }]);
    expect(envelope.remaining).toBeUndefined();
    expect(envelope.warnings).toBeUndefined();
    expect(call).toHaveBeenCalledTimes(3);
  });

  it('keeps the previews made when the plug-in call itself fails, leaving that photo and the rest remaining', async () => {
    const { handler } = batch((id) => {
      if (id === 2) throw new Error('Plugin request timed out');
      return rendered(halves(32, 16), id as number);
    });
    const envelope = envelopeOf(await handler('get_photo_previews', { photo_ids: [1, 2, 3] }));
    expect((envelope.data as { previews: { photo_id: string }[] }).previews.map((preview) => preview.photo_id)).toEqual(['1']);
    expect(envelope.remaining).toEqual([2, 3]);
    expect(envelope.warnings).toEqual([expect.stringContaining('Plugin request timed out')]);
  });
});

describe('the batch preview tools', () => {
  it.each(['get_photo_previews', 'find_duplicate_groups', 'get_photo_stats'])(
    '%s stops starting renders at the time its description names', async (name) => {
      const description = TOOL_CONTRACTS.find((tool) => tool.name === name)?.description ?? '';
      const stated = [...description.matchAll(/(\d+) s\b/g)].map((match) => Number(match[1]));
      expect(stated).toHaveLength(1);
      jest.useFakeTimers();
      try {
        const call = jest.fn(async (_action: string, params: unknown): Promise<PluginResponse> => {
          jest.advanceTimersByTime(2_000);
          const id = (params as { photo_ids: unknown[] }).photo_ids[0];
          return { id: 'p', result: { failed: [{ photo_id: String(id), reason: 'file is offline' }] } };
        });
        await createCallToolHandler({ isReady: () => true, dispatcher: { call } })(name, {
          photo_ids: Array.from({ length: 20 }, (_, i) => i + 1),
        });
        expect(call).toHaveBeenCalledTimes(Math.ceil(stated[0] / 2));
      } finally {
        jest.useRealTimers();
      }
    });
});

describe('area-weighted downsample', () => {
  it.each([
    {
      name: 'a 5x3 ramp to 2x2, splitting source pixels at both cell edges',
      width: 5, height: 3, targetWidth: 2, targetHeight: 2,
      valueAt: (pixel: number) => (pixel % 5) + 10 * Math.floor(pixel / 5),
      expected: [0.8 + 10 / 3, 3.2 + 10 / 3, 0.8 + 50 / 3, 3.2 + 50 / 3],
    },
    {
      name: 'a 2x1 row up to 4x1',
      width: 2, height: 1, targetWidth: 4, targetHeight: 1,
      valueAt: (pixel: number) => [10, 30][pixel],
      expected: [10, 10, 30, 30],
    },
    {
      name: 'a 25x1 row down to 11x1, whose last cell ends past 25 in floating point',
      width: 25, height: 1, targetWidth: 11, targetHeight: 1,
      valueAt: (pixel: number) => Array<number>(25).fill(7)[pixel],
      expected: Array<number>(11).fill(7),
    },
  ])('averages $name by covered area', ({ width, height, targetWidth, targetHeight, valueAt, expected }) => {
    const averages = Array.from(areaAverage(width, height, targetWidth, targetHeight, valueAt));
    expect(averages).toHaveLength(expected.length);
    averages.forEach((value, index) => expect(value).toBeCloseTo(expected[index], 10));
  });
});
