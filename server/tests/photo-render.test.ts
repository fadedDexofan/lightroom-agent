import { afterAll, describe, expect, it } from 'vitest';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import jpeg from 'jpeg-js';
import { envelopeOf } from './helpers/envelope.js';
import { paddedJpeg } from './helpers/jpeg.js';
import { createCallToolHandler } from '../src/tool-handler.js';
import { DETAIL_RENDER_FOLDER } from '../src/photo-detail.js';
import { TOOL_CONTRACTS } from '../src/tool-contracts.js';
import { PluginNotSentError, PluginTimeoutError, type CallOptions, type PluginResponse } from '../src/dispatcher.js';

function jpegOf(width: number, height: number, quality = 80): Buffer {
  const data = Buffer.alloc(width * height * 4);
  let seed = 11;
  for (let i = 0; i < data.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    data[i] = seed >> 23;
  }
  return jpeg.encode({ width, height, data }, quality).data;
}

const tempRoots: string[] = [];
afterAll(() => tempRoots.splice(0).forEach((root) => rmSync(root, { recursive: true, force: true })));

function renderedFile(contents: Buffer): string {
  const root = mkdtempSync(join(tmpdir(), 'lragent-render-test-'));
  tempRoots.push(root);
  const folder = join(root, DETAIL_RENDER_FOLDER, 'call-1');
  mkdirSync(folder, { recursive: true });
  const file = join(folder, 'a.jpg');
  writeFileSync(file, contents);
  return file;
}

const LEFT_ON_PHOTO = ['one Export history step', 'the exported mark'];
const LEFT = '; the render left one Export history step and the exported mark on the photo';
const source = (path: string): PluginResponse => ({
  id: 'r',
  result: { data: { photo_id: '914', path, source: 'export', left_on_photo: LEFT_ON_PHOTO } },
});

type Call = (action: string, params: unknown, timeoutMs?: number, options?: CallOptions) => Promise<PluginResponse>;

function handlerFor(answer: Call) {
  const calls: [string, unknown][] = [];
  const call: Call = async (action, params, timeoutMs, options) => {
    calls.push([action, params]);
    return answer(action, params, timeoutMs, options);
  };
  return { handler: createCallToolHandler({ admitted: () => 0, dispatcher: { call } }), calls };
}

const posixOnly = process.platform === 'win32' ? it.skip : it;

describe('render_photo', () => {
  it('is a write of the core toolset that never destroys anything', () => {
    const contract = TOOL_CONTRACTS.find((tool) => tool.name === 'render_photo');
    expect(contract?.toolset).toBe('core');
    expect(contract?.annotations).toEqual({ readOnlyHint: false, destructiveHint: false, openWorldHint: false });
  });

  it.each<[unknown, number]>([
    [undefined, 1728],
    ['review', 1728],
    ['cull', 864],
    [640.5, 640],
  ])(
    'asks the plug-in for one export rendition of size %o at a long edge of %o, naming itself for the lock',
    async (size, edge) => {
      const path = renderedFile(jpegOf(48, 32));
      const { handler, calls } = handlerFor(async () => source(path));
      await handler('render_photo', { photo_ids: ['/p/a.arw'], ...(size === undefined ? {} : { size }) });
      expect(calls).toEqual([['render_source', { photo_id: '/p/a.arw', long_edge: edge, tool: 'render_photo' }]]);
    },
  );

  it("returns Lightroom's JPEG byte for byte with the canonical photo id and what the render left, and removes the folder", async () => {
    const file = jpegOf(48, 32);
    const path = renderedFile(file);
    const { handler } = handlerFor(async () => source(path));

    const response = await handler('render_photo', { photo_ids: ['/p/a.arw'], size: 'review' });

    const envelope = envelopeOf(response);
    expect(envelope).toEqual({
      outcome: 'done',
      data: {
        photo_id: '914',
        width: 48,
        height: 32,
        bytes: file.length,
        jpeg_quality: 80,
        left_on_photo: LEFT_ON_PHOTO,
      },
    });
    const image = response.content[1];
    expect(image?.type === 'image' && Buffer.from(image.data, 'base64').equals(file)).toBe(true);
    expect(existsSync(dirname(path))).toBe(false);
  });

  it.each<[string, PluginResponse, string, Record<string, unknown>]>([
    [
      'an error with a possible effect',
      { id: 'r', error: 'socket closed mid-render', effect: 'unknown' },
      'unknown',
      { error: 'socket closed mid-render' },
    ],
    [
      'an error with no effect',
      { id: 'r', error: 'Unknown action: render_source', effect: 'none' },
      'failed',
      { error: 'Unknown action: render_source' },
    ],
    [
      'the photo unknown after its export started',
      {
        id: 'r',
        result: {
          unknown: [
            {
              photo_id: '914',
              reason: 'AI Updates Recommended: Cancel; written before this stopped: Export photo 914',
            },
          ],
        },
      },
      'unknown',
      {
        unknown: [
          { photo_id: '914', reason: 'AI Updates Recommended: Cancel; written before this stopped: Export photo 914' },
        ],
      },
    ],
    [
      'the refusal while another export runs',
      { id: 'r', error: 'export_photos is already running; wait for it to finish, then call again', effect: 'none' },
      'failed',
      { error: 'export_photos is already running; wait for it to finish, then call again' },
    ],
    [
      'the photo failed when its render left nothing',
      { id: 'r', result: { failed: [{ photo_id: '914', reason: 'Lightroom rendered no file' }] } },
      'failed',
      { failed: [{ photo_id: '914', reason: 'Lightroom rendered no file' }] },
    ],
  ])('answers %s as the plug-in classed it', async (_what, reply, outcome, expected) => {
    const { handler } = handlerFor(async () => reply);
    const envelope = envelopeOf(await handler('render_photo', { photo_ids: [914] }));
    expect(envelope.outcome).toBe(outcome);
    expect(envelope).toMatchObject(expected);
  });

  it('answers a rendition it cannot decode as unknown, naming what the render left, and removes the folder', async () => {
    const path = renderedFile(Buffer.from('broken'));
    const { handler } = handlerFor(async () => source(path));
    const envelope = envelopeOf(await handler('render_photo', { photo_ids: [914] }));
    expect(envelope.outcome).toBe('unknown');
    expect(String(envelope.error).endsWith(LEFT)).toBe(true);
    expect(existsSync(dirname(path))).toBe(false);
  });

  it('answers a rendition over the 3.5 MiB image limit as unknown, naming what the render left, without re-encoding it', async () => {
    const file = paddedJpeg(jpegOf(16, 16), 3.5 * 1024 * 1024 + 1);
    expect(file.length).toBeGreaterThan(3.5 * 1024 * 1024);
    const path = renderedFile(file);
    const { handler } = handlerFor(async () => source(path));
    const response = await handler('render_photo', { photo_ids: [914], size: 2048 });
    const envelope = envelopeOf(response);
    expect(envelope.outcome).toBe('unknown');
    expect(envelope.error).toBe(
      `Lightroom's rendition is ${file.length} bytes, over the 3.5 MiB image limit; ask for a smaller size${LEFT}`,
    );
    expect(response.content).toHaveLength(1);
  });

  it('uses a reply that arrives after the call was cancelled', async () => {
    const path = renderedFile(jpegOf(48, 32));
    const controller = new AbortController();
    const { handler } = handlerFor(async () => {
      controller.abort();
      return source(path);
    });
    const response = await handler('render_photo', { photo_ids: [914] }, { signal: controller.signal });
    expect(envelopeOf(response).outcome).toBe('done');
    expect(response.content[1]?.type).toBe('image');
  });

  it.each<[string, string, () => never, string]>([
    [
      'cancelled before it was sent',
      'failed',
      () => {
        throw new PluginNotSentError('Request cancelled');
      },
      'Request cancelled',
    ],
    [
      'timed out after it was sent',
      'unknown',
      () => {
        throw new PluginTimeoutError(30_000);
      },
      'Lightroom did not answer within 30s, so the result of render_photo is unknown: it may have been applied or may still be running. Read the current state before retrying.',
    ],
  ])('answers a call %s as %s', async (_what, outcome, raise, error) => {
    const { handler } = handlerFor(async () => raise());
    expect(envelopeOf(await handler('render_photo', { photo_ids: [914] }))).toEqual({ outcome, error });
  });

  posixOnly('warns, naming the folder, when the render folder cannot be removed, and still answers done', async () => {
    const path = renderedFile(jpegOf(48, 32));
    const base = dirname(dirname(path));
    chmodSync(base, 0o555);
    try {
      const { handler } = handlerFor(async () => source(path));
      const envelope = envelopeOf(await handler('render_photo', { photo_ids: [914] }));
      expect(envelope.outcome).toBe('done');
      expect(envelope.warnings).toEqual([
        expect.stringContaining(`Could not remove the render folder ${dirname(path)}`),
      ]);
    } finally {
      chmodSync(base, 0o755);
    }
  });
});
