import { afterAll, describe, expect, it, jest } from '@jest/globals';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import jpeg from 'jpeg-js';
import { envelopeOf } from './helpers/envelope.js';
import { createCallToolHandler } from '../src/tool-handler.js';
import { DETAIL_RENDER_FOLDER } from '../src/photo-detail.js';
import { TOOL_CONTRACTS } from '../src/tool-contracts.js';
import { cutPixels, pixelBox } from '../src/rendered-image.js';
import { PluginTimeoutError, type PluginResponse } from '../src/dispatcher.js';

function render(width: number, height: number): Buffer {
  const data = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      data[i] = x < width / 2 ? 255 : 0;
      data[i + 1] = y < height / 2 ? 255 : 0;
      data[i + 3] = 255;
    }
  }
  return jpeg.encode({ width, height, data }, 100).data;
}

const tempRoots: string[] = [];
afterAll(() => tempRoots.splice(0).forEach((root) => rmSync(root, { recursive: true, force: true })));
function tempRoot(): string {
  const root = mkdtempSync(join(tmpdir(), 'lragent-detail-test-'));
  tempRoots.push(root);
  return root;
}

function renderedFile(contents: Buffer): string {
  const folder = join(tempRoot(), DETAIL_RENDER_FOLDER, 'call-1');
  mkdirSync(folder, { recursive: true });
  const file = join(folder, 'a.jpg');
  writeFileSync(file, contents);
  return file;
}

const EXPORT_SOURCE = { source: 'export', left_on_photo: ['one Export history step', 'the exported mark'] };
function cropOf(width: number, height: number): PluginResponse {
  return { id: 'c', result: { data: { photo_id: '7', rectangle: { left: 0, top: 0, right: 1, bottom: 1 }, angle: 0, size: { width, height } } } };
}

const LEFT = '; the render left one Export history step and the exported mark on the photo';

function handlerFor(reply: PluginResponse, frame: PluginResponse = cropOf(64, 48)) {
  const calls: { action: string; params: unknown }[] = [];
  const call = async (action: string, params: unknown) => {
    calls.push({ action, params });
    return action === 'get_crop' ? frame : reply;
  };
  return { handler: createCallToolHandler({ admitted: () => 0, dispatcher: { call } }), calls };
}

describe('cutPixels', () => {
  it('returns exactly the pixel box from an image whose every pixel is distinct', () => {
    const width = 7, height = 5;
    const data = new Uint8Array(width * height * 4);
    for (let i = 0; i < width * height; i++) data.set([i, 255 - i, i % 3, 255], i * 4);
    const box = pixelBox({ x: 2 / 7, y: 1 / 5, width: 3 / 7, height: 2 / 5 }, width, height);

    const cut = cutPixels({ width, height, data }, box);

    expect(box).toEqual({ x: 2, y: 1, width: 3, height: 2 });
    const expected = [];
    for (let y = 1; y < 3; y++) for (let x = 2; x < 5; x++) expected.push(...data.subarray((y * width + x) * 4, (y * width + x + 1) * 4));
    expect([...cut]).toEqual(expected);
  });

  it('rounds a fractional box outward', () => {
    expect(pixelBox({ x: 0.15, y: 0.15, width: 0.2, height: 0.2 }, 10, 10)).toEqual({ x: 1, y: 1, width: 3, height: 3 });
  });
});

describe('get_photo_detail', () => {
  it('cuts each region at one rendered pixel per returned pixel, states the render, and removes the file', async () => {
    const path = renderedFile(render(64, 48));
    const { handler, calls } = handlerFor({ id: 'r', result: { data: { photo_id: '7', path, ...EXPORT_SOURCE } } });

    const response = await handler('get_photo_detail', {
      photo_id: 7, regions: [{ x: 0, y: 0, width: 0.5, height: 0.5 }, { x: 0.5, y: 0.5, width: 0.5, height: 0.5 }],
    });

    const envelope = envelopeOf(response);
    expect(envelope.outcome).toBe('done');
    expect(calls.map(({ action, params }) => [action, params])).toEqual([['get_crop', { photo_id: 7 }], ['render_detail_source', { photo_id: 7 }]]);
    const data = envelope.data as { photo_id: string; render: unknown; crop_jpeg_quality: number; regions: { box: unknown; image_index: number }[] };
    expect(data.photo_id).toBe('7');
    expect(data.render).toEqual({
      width: 64, height: 48, jpeg_quality: 100, color_space: 'sRGB', output_sharpening: 'off', ...EXPORT_SOURCE,
    });
    expect(data.crop_jpeg_quality).toBe(95);
    expect(data.regions.map((region) => region.box)).toEqual([
      { x: 0, y: 0, width: 32, height: 24 }, { x: 32, y: 24, width: 32, height: 24 },
    ]);
    expect(data.regions.map((region) => region.image_index)).toEqual([1, 2]);
    const images = response.content.slice(1) as { data: string }[];
    expect(images).toHaveLength(2);
    const first = jpeg.decode(Buffer.from(images[0].data, 'base64'));
    expect([first.width, first.height]).toEqual([32, 24]);
    expect(existsSync(path)).toBe(false);
  });

  it('removes the folder the plug-in rendered into for this call and nothing beside it', async () => {
    const base = join(tempRoot(), 'lightroom-agent-detail');
    const own = join(base, 'call-1');
    const other = join(base, 'call-2');
    mkdirSync(own, { recursive: true });
    mkdirSync(other, { recursive: true });
    const path = join(own, 'a.jpg');
    writeFileSync(path, render(64, 48));
    writeFileSync(join(other, 'b.jpg'), 'x');
    const { handler } = handlerFor({ id: 'r', result: { data: { photo_id: '7', path, ...EXPORT_SOURCE } } });
    await handler('get_photo_detail', { photo_id: 7, regions: [{ x: 0, y: 0, width: 0.5, height: 0.5 }] });
    expect(existsSync(own)).toBe(false);
    expect(existsSync(join(other, 'b.jpg'))).toBe(true);
  });

  it('removes nothing when the plug-in names a path outside a render folder', async () => {
    const path = join(tempRoot(), 'a.jpg');
    writeFileSync(path, render(64, 48));
    const { handler } = handlerFor({ id: 'r', result: { data: { photo_id: '7', path, ...EXPORT_SOURCE } } });
    await handler('get_photo_detail', { photo_id: 7, regions: [{ x: 0, y: 0, width: 0.5, height: 0.5 }] });
    expect(existsSync(path)).toBe(true);
  });

  it('refuses a region over max_edge before rendering, against the cropped frame, with nothing left on the photo', async () => {
    const { handler, calls } = handlerFor({ id: 'r', result: {} }, cropOf(300, 200));

    const response = await handler('get_photo_detail', {
      photo_id: 7, max_edge: 128, regions: [{ x: 0, y: 0, width: 0.2, height: 0.2 }, { x: 0, y: 0, width: 1, height: 0.5 }],
    });

    expect(envelopeOf(response)).toEqual({
      outcome: 'failed',
      error: 'region 2 is 300x100 px, over max_edge 128; this photo allows regions up to width 0.4233 and height 0.635 (cropped frame 300x200); nothing was rendered',
    });
    expect(calls.map(({ action }) => action)).toEqual(['get_crop']);
  });

  it.each<[string, () => Promise<PluginResponse>, string]>([
    ['an error answer', async () => ({ id: 'c', error: 'attempt to index a nil value', effect: 'unknown' }),
      'attempt to index a nil value; nothing was written'],
    ['a timeout', async () => { throw new PluginTimeoutError(30_000); },
      'Plugin response timeout (30s); nothing was written'],
  ])('answers get_crop failing with %s as failed with nothing written, and does not render', async (_name, crop, error) => {
    const calls: string[] = [];
    const call = async (action: string): Promise<PluginResponse> => {
      calls.push(action);
      return action === 'get_crop' ? crop() : { id: 'r', result: {} };
    };
    const handler = createCallToolHandler({ admitted: () => 0, dispatcher: { call } });

    const response = await handler('get_photo_detail', { photo_id: 7, regions: [{ x: 0, y: 0, width: 1, height: 1 }] });

    expect(envelopeOf(response)).toEqual({ outcome: 'failed', error });
    expect(calls).toEqual(['get_crop']);
  });

  it('suggests a region size that fits max_edge wherever the region starts', async () => {
    const { handler, calls } = handlerFor({ id: 'r', result: {} }, cropOf(6000, 4000));
    const refused = envelopeOf(await handler('get_photo_detail', { photo_id: 7, regions: [{ x: 0, y: 0, width: 0.5, height: 0.5 }] }));
    const suggested = /up to width ([\d.]+) and height ([\d.]+)/.exec(String(refused.error));
    expect(suggested).not.toBeNull();
    calls.length = 0;

    await handler('get_photo_detail', {
      photo_id: 7, regions: [{ x: 0.0168, y: 0.0251, width: Number(suggested?.[1]), height: Number(suggested?.[2]) }],
    });

    expect(calls.map(({ action }) => action)).toEqual(['get_crop', 'render_detail_source']);
  });

  it('hands the render only the time get_crop left of the tool\'s budget', async () => {
    jest.useFakeTimers();
    try {
      const path = renderedFile(render(64, 48));
      const timeouts: [string, number | undefined][] = [];
      const call = async (action: string, _params: unknown, timeoutMs?: number): Promise<PluginResponse> => {
        timeouts.push([action, timeoutMs]);
        if (action !== 'get_crop') return { id: 'r', result: { data: { photo_id: '7', path, ...EXPORT_SOURCE } } };
        jest.advanceTimersByTime(5_000);
        return cropOf(64, 48);
      };
      await createCallToolHandler({ admitted: () => 0, dispatcher: { call } })('get_photo_detail', {
        photo_id: 7, regions: [{ x: 0, y: 0, width: 0.5, height: 0.5 }],
      });
      expect(timeouts).toEqual([['get_crop', 300_000], ['render_detail_source', 295_000]]);
    } finally {
      jest.useRealTimers();
    }
  });

  it('answers a render larger than the cropped frame predicted with the region over max_edge as unknown and removes the file', async () => {
    const path = renderedFile(render(300, 200));
    const { handler } = handlerFor({ id: 'r', result: { data: { photo_id: '7', path, ...EXPORT_SOURCE } } }, cropOf(120, 80));

    const response = await handler('get_photo_detail', {
      photo_id: 7, max_edge: 128, regions: [{ x: 0, y: 0, width: 0.2, height: 0.2 }, { x: 0, y: 0, width: 1, height: 0.5 }],
    });

    const envelope = envelopeOf(response);
    expect(envelope.outcome).toBe('unknown');
    expect(envelope.error).toBe(`region 2 is 300x100 px, over max_edge 128; this photo allows regions up to width 0.4233 and height 0.635 (render 300x200)${LEFT}`);
    expect(response.content).toHaveLength(1);
    expect(existsSync(path)).toBe(false);
  });

  it('answers a render it cannot decode as unknown, naming what the render left, and removes the file', async () => {
    const path = renderedFile(Buffer.from('broken'));
    const { handler } = handlerFor({ id: 'r', result: { data: { photo_id: '7', path, ...EXPORT_SOURCE } } });

    const response = await handler('get_photo_detail', { photo_id: 7, regions: [{ x: 0, y: 0, width: 1, height: 1 }] });

    const envelope = envelopeOf(response);
    expect(envelope.outcome).toBe('unknown');
    expect(String(envelope.error).endsWith(LEFT)).toBe(true);
    expect(existsSync(path)).toBe(false);
  });

  it('answers a render that went wrong as unknown and an unknown photo as failed', async () => {
    const unknown = [{ photo_id: '7', reason: 'AI Updates Recommended: Cancel; the photo may have gained one Export history step' }];
    const rendered = handlerFor({ id: 'r', result: { unknown } });
    const renderEnvelope = envelopeOf(await rendered.handler('get_photo_detail', { photo_id: 7, regions: [{ x: 0, y: 0, width: 1, height: 1 }] }));
    expect(renderEnvelope.outcome).toBe('unknown');
    expect(renderEnvelope.unknown).toEqual(unknown);

    const missing = handlerFor({ id: 'r', result: {} }, { id: 'c', result: { not_found: [404] } });
    const missingEnvelope = envelopeOf(await missing.handler('get_photo_detail', { photo_id: 7, regions: [{ x: 0, y: 0, width: 1, height: 1 }] }));
    expect(missingEnvelope.outcome).toBe('failed');
    expect(missingEnvelope.not_found).toEqual([404]);
  });

  it('is not a read: hidden in read-only mode and published with what each call leaves on the photo', () => {
    const contract = TOOL_CONTRACTS.find((tool) => tool.name === 'get_photo_detail');
    expect(contract?.annotations.readOnlyHint).toBe(false);
    expect(contract?.description).toContain('Each call adds one Export history step to the photo and marks it exported');
  });

  it('rejects more than four regions and a region outside the frame before rendering', async () => {
    const { handler, calls } = handlerFor({ id: 'r', result: {} });
    const region = { x: 0, y: 0, width: 0.1, height: 0.1 };
    for (const regions of [[region, region, region, region, region], [{ x: 0.5, y: 0, width: 0.6, height: 0.1 }]]) {
      expect(envelopeOf(await handler('get_photo_detail', { photo_id: 7, regions })).outcome).toBe('failed');
    }
    expect(calls).toHaveLength(0);
  });
});
