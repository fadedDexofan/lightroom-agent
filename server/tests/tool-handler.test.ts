import { describe, it, expect, jest } from '@jest/globals';
import { createCallToolHandler } from '../src/tool-handler.js';
import { TOOL_CONTRACTS } from '../src/tool-contracts.js';
import { validateToolArgs } from './helpers/validate.js';
import { DEVELOP_KEYS, LOCAL_KEYS } from '../src/develop-keys.js';
import { dataOf, envelopeOf } from './helpers/envelope.js';

import { Dispatcher, PluginNotSentError, PluginTimeoutError, type PluginResponse } from '../src/dispatcher.js';

function makeHandler(opts: {
  ready?: boolean;
  call?: (action: string, params: unknown, budget?: number) => Promise<PluginResponse>;
} = {}) {
  return createCallToolHandler({
    isReady: () => opts.ready ?? true,
    dispatcher: {
      call: opts.call ?? (async () => ({ id: 'x', result: null })),
    },
  });
}

describe('createCallToolHandler', () => {
  it.each([['cull', 864], ['review', 1728]] as const)('get_photo_preview resolves %s before dispatch', async (size, edge) => {
    const args = { photo_id: 914, size };
    let captured: unknown;
    await makeHandler({ call: async (_action, params) => {
      captured = params;
      return { id: '1', result: { not_found: [914] } };
    } })('get_photo_preview', args);
    expect(captured).toEqual({ photo_ids: [914], size: edge });
    expect(args.size).toBe(size);
  });

  it.each([[undefined, 864], [64, 64], [512.5, 512], [1024, 1024], [2048, 2048]])('get_photo_preview sends size %s as edge %s', async (size, edge) => {
    const args = size === undefined ? { photo_id: 914 } : { photo_id: 914, size };
    let captured: unknown;
    await makeHandler({ call: async (_action, params) => {
      captured = params;
      return { id: '1', result: { not_found: [914] } };
    } })('get_photo_preview', args);
    expect(captured).toEqual({ photo_ids: [914], size: edge });
  });

  it('answers invalid arguments as failed without sending anything to Lightroom', async () => {
    let calls = 0;
    const handler = makeHandler({ call: async () => { calls++; return { id: '1', result: {} }; } });

    const result = await handler('set_rating_and_flag', { photo_ids: [914], rating: 6 });

    expect(envelopeOf(result)).toEqual({ outcome: 'failed', error: expect.stringContaining('Invalid arguments for set_rating_and_flag: rating') });
    expect(calls).toBe(0);
  });

  it('refuses a name with no contract without sending it to Lightroom', async () => {
    let calls = 0;
    const handler = makeHandler({ call: async () => { calls++; return { id: '1', result: {} }; } });
    for (const name of ['write_develop_settings', 'set_selection']) {
      expect(envelopeOf(await handler(name, {}))).toEqual({
        outcome: 'failed', error: `Unknown tool "${name}". Only listed tools can be called.`,
      });
    }
    expect(calls).toBe(0);
  });

  it('returns isError when plugin not connected', async () => {
    const handler = makeHandler({ ready: false });
    const result = await handler('list_collections', {});
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/not connected/i);
    expect(result.content[0].text).not.toMatch(/[\r\n]/);
    expect(result.content[0].text.length).toBeLessThan(160);
    expect(result.content[0].text).toContain("click 'Start Server'");
  });

  it('forwards action and args to dispatcher', async () => {
    let captured: { action: string; params: unknown } | null = null;
    const handler = makeHandler({
      call: async (action, params) => {
        captured = { action, params };
        return { id: '1', result: { ok: true } };
      },
    });
    await handler('search_photos', { rating: 5 });
    expect(captured).toEqual({ action: 'search_photos', params: { rating: 5 } });
  });

  it('leaves a result whose image field is not image data as plain JSON', async () => {
    const result = { name: 'Portfolio', image: 'cover.jpg' };
    const handler = makeHandler({ call: async () => ({ id: '1', result: { data: result } }) });
    const res = await handler('list_collections', {});

    expect(res.content).toHaveLength(1);
    expect(dataOf(res)).toEqual(result);
  });

  it('catches dispatcher rejections and returns isError', async () => {
    const handler = makeHandler({
      call: async () => {
        throw new Error('plug-in reply could not be read');
      },
    });
    const result = await handler('search_photos', {});
    expect(result.isError).toBe(true);
    expect(envelopeOf(result)).toEqual({ outcome: 'failed', error: 'plug-in reply could not be read' });
  });

  it('handles non-Error throws by stringifying', async () => {
    const handler = makeHandler({
      call: async () => {
        throw 'raw string';
      },
    });
    const result = await handler('set_rating_and_flag', { photo_ids: [914], rating: 3 });
    expect(result.isError).toBe(true);
    expect(envelopeOf(result)).toEqual({ outcome: 'unknown', error: 'raw string' });
  });
});

describe('result envelope at the call boundary', () => {
  const outcomeOf = async (name: string, args: Record<string, unknown>, reply: PluginResponse | Error) => {
    const result = await makeHandler({ call: async () => {
      if (reply instanceof Error) throw reply;
      return reply;
    } })(name, args);
    const body = JSON.parse(result.content[0].text) as { outcome: string; error?: string; data?: unknown };
    return { isError: result.isError === true, ...body };
  };
  const write = ['set_rating_and_flag', { photo_ids: [1], rating: 3 }] as const;
  const read = ['list_collections', {}] as const;

  it('reports a refusal from a write as failed', async () => {
    expect(await outcomeOf(...write, { id: '1', error: 'Photo not found', effect: 'none' }))
      .toEqual({ isError: true, outcome: 'failed', error: 'Photo not found' });
  });

  it('reports an unmarked error from a write as unknown', async () => {
    expect(await outcomeOf(...write, { id: '1', error: 'Lightroom threw', effect: 'unknown' }))
      .toEqual({ isError: true, outcome: 'unknown', error: 'Lightroom threw' });
  });

  it('reports any error from a read as failed', async () => {
    expect((await outcomeOf(...read, { id: '1', error: 'Lightroom threw', effect: 'unknown' })).outcome).toBe('failed');
  });

  it('wraps a handler result without lists as done', async () => {
    expect(await outcomeOf(...read, { id: '1', result: { data: { collections: [] } } }))
      .toEqual({ isError: false, outcome: 'done', data: { collections: [] } });
  });

  it('reports a write timeout as unknown and a read timeout as failed', async () => {
    expect(await outcomeOf(...write, new PluginTimeoutError(30_000))).toEqual({
      isError: true,
      outcome: 'unknown',
      error: 'Lightroom did not answer within 30s, so the result of set_rating_and_flag is unknown: it may have been applied'
        + ' or may still be running. Read the current state before retrying.',
    });
    expect(await outcomeOf(...read, new PluginTimeoutError(30_000)))
      .toEqual({ isError: true, outcome: 'failed', error: 'Plugin response timeout (30s)' });
  });

  it('reports a request that never left the server as failed', async () => {
    expect((await outcomeOf(...write, new PluginNotSentError('Failed to send request to plugin (socket dropped)'))).outcome)
      .toBe('failed');
  });
});

describe('time budget', () => {
  it('gives every plug-in tool the budget of its contract duration', async () => {
    const budgets: [string, number | undefined][] = [];
    const handler = createCallToolHandler({ isReady: () => true, dispatcher: { call: async (action, _params, budget) => {
      budgets.push([action, budget]);
      return { id: '1', result: { data: {} } };
    } } });
    await handler('export_photos', { photo_ids: [1], destination: '/tmp/out' });
    await handler('list_collections', {});
    expect(budgets).toEqual([['export_photos', 300_000], ['list_collections', 30_000]]);
  });

  it.each([
    ['set_develop_settings', 'get_develop_settings', { photo_id: 914, settings: { GlowStyle: 2 } }],
    ['set_crop', 'plan_crop', { photo_id: 914, aspect: { width: 1, height: 1 } }],
  ])('hands the write of %s the budget left after its pre-read', async (tool, preRead, args) => {
    jest.useFakeTimers();
    try {
      const budgets: [string, number | undefined][] = [];
      const handler = makeHandler({ call: async (action, _params, budget) => {
        budgets.push([action, budget]);
        if (action !== preRead) return { id: '2', result: { data: { photo_id: '914' } } };
        jest.advanceTimersByTime(5_000);
        if (action === 'plan_crop') {
          return { id: '1', result: { data: { photo_id: '914', settings: { CropLeft: 0.1, CropTop: 0.1, CropRight: 0.9, CropBottom: 0.9, CropAngle: 0 }, rectangle: {}, angle: 0, size: {} } } };
        }
        return { id: '1', result: { data: { photos: [{ photo_id: '914', settings: { Glow: 60 }, absent: [] }] } } };
      } });

      expect(envelopeOf(await handler(tool, args)).outcome).toBe('done');
      expect(budgets).toEqual([[preRead, 30_000], ['write_develop_settings', 25_000]]);
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('Develop call queue', () => {
  type Pending = { action: string; budget?: number; resolve: (reply: PluginResponse) => void };
  function gatedDispatcher() {
    const pending: Pending[] = [];
    const call = async (action: string, _params: unknown, budget?: number) =>
      new Promise<PluginResponse>((resolve) => { pending.push({ action, budget, resolve }); });
    const handler = createCallToolHandler({ isReady: () => true, dispatcher: { call } });
    const settle = async () => { for (let i = 0; i < 5; i++) await Promise.resolve(); };
    return { pending, handler, settle };
  }
  const done = (id: string): PluginResponse => ({ id, result: { data: {} } });
  const develop = (id: number) => ['set_develop_settings', { photo_id: id, settings: { Exposure2012: 0.1 } }] as const;

  it('holds the Develop turn after a timed-out call until the plug-in has finished it', async () => {
    let finishLate!: () => void;
    const calls: string[] = [];
    const call = async (action: string) => {
      calls.push(action);
      if (calls.length === 1) throw new PluginTimeoutError(30_000, new Promise<void>((resolve) => { finishLate = resolve; }));
      return { id: '2', result: { data: {} } };
    };
    const handler = createCallToolHandler({ isReady: () => true, dispatcher: { call } });
    const settle = async () => { for (let i = 0; i < 10; i++) await Promise.resolve(); };

    const first = await handler(...develop(1));
    const second = handler(...develop(2));
    await settle();

    expect(envelopeOf(first).outcome).toBe('unknown');
    expect(calls).toEqual(['write_develop_settings']);
    finishLate();
    await second;
    expect(calls).toEqual(['write_develop_settings', 'write_develop_settings']);
  });

  it('sends the next Develop call only after the previous one answered, in arrival order', async () => {
    const { pending, handler, settle } = gatedDispatcher();
    const first = handler(...develop(1));
    const second = handler('list_masks', { photo_id: 2 });
    const third = handler(...develop(3));
    await settle();
    expect(pending.map((entry) => entry.action)).toEqual(['write_develop_settings']);
    pending[0].resolve(done('1'));
    await first;
    await settle();
    expect(pending.map((entry) => entry.action)).toEqual(['write_develop_settings', 'list_masks']);
    pending[1].resolve(done('2'));
    await second;
    await settle();
    expect(pending).toHaveLength(3);
    pending[2].resolve(done('3'));
    expect((await third).isError).toBeUndefined();
  });

  it('runs a call outside the queue alongside a queued one', async () => {
    const { pending, handler, settle } = gatedDispatcher();
    void handler(...develop(1));
    void handler('list_collections', {});
    await settle();
    expect(pending.map((entry) => entry.action).sort()).toEqual(['list_collections', 'write_develop_settings']);
  });

  it('gives up without sending anything when the turn does not come within the budget', async () => {
    jest.useFakeTimers();
    try {
      const { pending, handler, settle } = gatedDispatcher();
      void handler(...develop(1));
      const waiting = handler(...develop(2));
      await settle();
      jest.advanceTimersByTime(30_000);
      const result = await waiting;
      expect(result.isError).toBe(true);
      expect(envelopeOf(result)).toMatchObject({
        outcome: 'failed', error: expect.stringContaining('busy with set_develop_settings'),
      });
      expect(pending).toHaveLength(1);
    } finally {
      jest.useRealTimers();
    }
  });

  it('gives up without sending anything when the turn comes with under a second of the budget left', async () => {
    jest.useFakeTimers();
    try {
      const sent: string[] = [];
      const dispatcher = new Dispatcher({ send: (line) => { sent.push(line); return true; }, getToken: () => 'token', log: () => {} });
      const handler = createCallToolHandler({ isReady: () => true, dispatcher });
      const first = handler(...develop(1));
      const waiting = handler(...develop(2));
      for (let i = 0; i < 5; i++) await Promise.resolve();
      jest.advanceTimersByTime(29_500);
      dispatcher.handleResponseLine(JSON.stringify(done((JSON.parse(sent[0]) as { id: string }).id)));
      await first;
      const result = await waiting;
      expect(envelopeOf(result)).toMatchObject({ outcome: 'failed', error: expect.stringContaining('Only 500 ms of the time budget were left, so write_develop_settings was not sent') });
      expect(sent).toHaveLength(1);
    } finally {
      jest.useRealTimers();
    }
  });

  it('names the timed-out call still finishing when the next call gives up waiting for it', async () => {
    jest.useFakeTimers();
    try {
      const calls: string[] = [];
      const call = async (action: string) => {
        calls.push(action);
        throw new PluginTimeoutError(30_000, new Promise<void>(() => {}));
      };
      const handler = createCallToolHandler({ isReady: () => true, dispatcher: { call } });
      await handler(...develop(1));
      const waiting = handler(...develop(2));
      for (let i = 0; i < 10; i++) await Promise.resolve();
      jest.advanceTimersByTime(30_000);
      expect(envelopeOf(await waiting)).toMatchObject({
        outcome: 'failed', error: expect.stringContaining('busy with set_develop_settings, still finishing in Lightroom after it timed out'),
      });
      expect(calls).toEqual(['write_develop_settings']);
    } finally {
      jest.useRealTimers();
    }
  });

  it('gives up without sending anything when the client aborts while waiting', async () => {
    const { pending, handler, settle } = gatedDispatcher();
    void handler(...develop(1));
    const controller = new AbortController();
    const waiting = handler('set_develop_settings', { photo_id: 2, settings: { Exposure2012: 0.2 } }, { signal: controller.signal });
    await settle();
    controller.abort();
    expect(envelopeOf(await waiting)).toMatchObject({ outcome: 'failed', error: expect.stringContaining('cancelled') });
    expect(pending).toHaveLength(1);
  });

  it('hands the plug-in the budget left after the wait', async () => {
    jest.useFakeTimers();
    try {
      const { pending, handler, settle } = gatedDispatcher();
      const first = handler(...develop(1));
      void handler(...develop(2));
      await settle();
      jest.advanceTimersByTime(10_000);
      pending[0].resolve(done('1'));
      await first;
      await settle();
      expect(pending[1].budget).toBe(20_000);
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('set_develop_settings precision', () => {
  it('writes a value finer than Lightroom keeps rounded to its precision and says so', async () => {
    const calls: [string, unknown][] = [];
    const result = await makeHandler({ call: async (action, params) => {
      calls.push([action, params]);
      return { id: '1', result: { data: { photo_id: '914' } } };
    } })('set_develop_settings', {
      photo_id: 914, settings: { Exposure2012: 0.333333, Contrast2012: 10.4, SharpenRadius: 1.25, Texture: 6 },
    });
    expect(calls).toEqual([['write_develop_settings', {
      photo_id: 914, settings: { Exposure2012: 0.33, Contrast2012: 10, SharpenRadius: 1.3, Texture: 6 },
    }]]);
    expect(envelopeOf(result)).toEqual({ outcome: 'done', data: { photo_id: '914' }, warnings: [
      'Rounded to the precision Lightroom keeps: Exposure2012 0.333333 -> 0.33, Contrast2012 10.4 -> 10, SharpenRadius 1.25 -> 1.3',
    ] });
  });

  it('writes values already at their precision unchanged and without a warning', async () => {
    const calls: unknown[] = [];
    const result = await makeHandler({ call: async (_action, params) => {
      calls.push(params);
      return { id: '1', result: { data: { photo_id: '914' } } };
    } })('set_develop_settings', { photo_id: 914, settings: { Exposure2012: -1.25, WhiteBalance: 'Auto', CropAngle: 1.25 } });
    expect(calls).toEqual([{ photo_id: 914, settings: { Exposure2012: -1.25, WhiteBalance: 'Auto', CropAngle: 1.25 } }]);
    expect(envelopeOf(result).warnings).toBeUndefined();
  });
});

describe('set_develop_settings rules on stored values', () => {
  function photoWith(stored: Record<string, unknown>) {
    const calls: [string, unknown][] = [];
    const handler = makeHandler({ call: async (action, params) => {
      calls.push([action, params]);
      if (action === 'get_develop_settings') {
        const keys = (params as { keys: string[] }).keys;
        const settings = Object.fromEntries(keys.flatMap((key) => (key in stored ? [[key, stored[key]]] : [])));
        return { id: '1', result: { data: { photos: [{ photo_id: '914', settings, absent: [] }] } } };
      }
      return { id: '1', result: { data: { photo_id: '914' } } };
    } });
    return { calls, write: (settings: Record<string, unknown>) => handler('set_develop_settings', { photo_id: 914, settings }) };
  }

  it('refuses a Glow style while the photo has no Glow, reading the stored amount first', async () => {
    const { calls, write } = photoWith({ Glow: 0 });
    const result = await write({ GlowStyle: 2 });
    expect(envelopeOf(result)).toEqual({ outcome: 'failed', error: expect.stringContaining('GlowStyle needs Glow above 0') });
    expect(calls).toEqual([['get_develop_settings', { photo_ids: [914], keys: ['Glow'] }]]);
  });

  it('writes a Glow style when the stored amount or the same write gives Glow', async () => {
    const stored = photoWith({ Glow: 60 });
    expect(envelopeOf(await stored.write({ GlowStyle: 2 })).outcome).toBe('done');
    expect(stored.calls.map(([action]) => action)).toEqual(['get_develop_settings', 'write_develop_settings']);
    const same = photoWith({ Glow: 0 });
    expect(envelopeOf(await same.write({ Glow: 40, GlowStyle: 3, GlowDirection: 90 })).outcome).toBe('done');
    expect(same.calls.map(([action]) => action)).toEqual(['write_develop_settings']);
  });

  it('refuses a Glow direction unless the style is directional', async () => {
    const { calls, write } = photoWith({ Glow: 60, GlowStyle: 1 });
    expect(envelopeOf(await write({ GlowDirection: 90 })).error).toContain('GlowDirection needs GlowStyle 3 (motion) or 4 (streak)');
    expect(calls.map(([action]) => action)).toEqual(['get_develop_settings']);
  });

  it.each([
    [[0, 0, 128, 140, 96, 90, 255, 255]], [[10, 0, 255, 255]], [[0, 0, 250, 255]],
  ])('refuses the point curve %j, which does not start at 0, end at 255 and increase, before anything is sent', async (curve) => {
    const { calls, write } = photoWith({});
    expect(envelopeOf(await write({ ToneCurvePV2012: curve }))).toEqual({
      outcome: 'failed', error: expect.stringContaining('a ToneCurvePV2012 curve must start at input 0, end at input 255 and have strictly increasing inputs'),
    });
    expect(calls).toEqual([]);
  });

  it('refuses a Defringe hue pair closer than 10, against the stored endpoint when only one is written', async () => {
    const { calls, write } = photoWith({ DefringePurpleHueLo: 30, DefringePurpleHueHi: 60 });
    expect(envelopeOf(await write({ DefringePurpleHueLo: 55 })).error)
      .toContain('DefringePurpleHueHi must be at least 10 above DefringePurpleHueLo');
    expect(envelopeOf(await write({ DefringePurpleHueLo: 50 })).outcome).toBe('done');
    expect(envelopeOf(await write({ DefringeGreenHueLo: 45, DefringeGreenHueHi: 50 })).error)
      .toContain('DefringeGreenHueHi must be at least 10 above DefringeGreenHueLo');
    expect(calls.filter(([action]) => action === 'write_develop_settings')).toHaveLength(1);
  });

  it('refuses a B&W mix on a color photo and writes it once the photo is black and white', async () => {
    const color = photoWith({ ConvertToGrayscale: false });
    expect(envelopeOf(await color.write({ GrayMixerRed: -40 })).error)
      .toContain('GrayMixer keys need a black and white photo');
    expect(color.calls).toEqual([['get_develop_settings', { photo_ids: [914], keys: ['ConvertToGrayscale'] }]]);
    const grey = photoWith({ ConvertToGrayscale: true });
    expect(envelopeOf(await grey.write({ GrayMixerRed: -40, GrayMixerBlue: 20 })).outcome).toBe('done');
    expect(grey.calls.map(([action]) => action)).toEqual(['get_develop_settings', 'write_develop_settings']);
  });

  it('checks crop edges against the stored opposite edge', async () => {
    const { write } = photoWith({ CropLeft: 0.1, CropRight: 0.5 });
    expect(envelopeOf(await write({ CropLeft: 0.6 })).error).toContain('CropLeft must be less than CropRight');
    expect(envelopeOf(await write({ CropLeft: 0.6, CropRight: 0.9 })).outcome).toBe('done');
  });

  it('publishes every rule in the tool description', () => {
    const tool = TOOL_CONTRACTS.find((contract) => contract.name === 'set_develop_settings');
    for (const text of ['GlowStyle needs Glow above 0', 'GlowDirection needs GlowStyle 3 (motion) or 4 (streak)',
      'DefringePurpleHueHi must be at least 10 above DefringePurpleHueLo', 'CropLeft must be less than CropRight',
      'GrayMixer keys need a black and white photo']) {
      expect(tool?.description).toContain(text);
    }
  });
});

describe('a read before the write that does not come back', () => {
  const lost = (action: string, failure: () => PluginResponse) => makeHandler({ call: async (called) => {
    if (called === action) return failure();
    throw new Error(`${called} must not be sent`);
  } });

  it.each([
    ['times out', () => { throw new PluginTimeoutError(30_000); }],
    ['answers an error', () => ({ id: '1', error: 'Lightroom is busy', effect: 'unknown' as const })],
  ])('answers failed, nothing written, when the pre-read %s', async (_case, failure) => {
    const develop = lost('get_develop_settings', failure);
    const crop = lost('plan_crop', failure);

    for (const result of [
      await develop('set_develop_settings', { photo_id: 914, settings: { GlowStyle: 2 } }),
      await crop('set_crop', { photo_id: 914, aspect: { width: 1, height: 1 } }),
    ]) {
      expect(envelopeOf(result)).toMatchObject({ outcome: 'failed', error: expect.stringContaining('nothing was written') });
    }
  });
});

describe('set_develop_settings and keys another tool writes', () => {
  it('refuses ConvertToGrayscale before anything is read or written and points to set_treatment', async () => {
    const calls: string[] = [];
    const result = await makeHandler({ call: async (action) => {
      calls.push(action);
      return { id: '1', result: { data: {} } };
    } })('set_develop_settings', { photo_id: 914, settings: { ConvertToGrayscale: true, Exposure2012: 1 } });
    expect(envelopeOf(result)).toEqual({ outcome: 'failed', error: expect.stringContaining('ConvertToGrayscale is written by set_treatment') });
    expect(calls).toEqual([]);
  });

  it('still reads the key but refuses it in a named copy list with the same words', () => {
    expect(validateToolArgs('get_develop_settings', { photo_ids: [914], keys: ['ConvertToGrayscale'] })).toBeNull();
    expect(validateToolArgs('copy_develop_settings', { source_id: 914, target_ids: [915], settings: ['ConvertToGrayscale', 'Exposure2012'] }))
      .toContain('ConvertToGrayscale is written by set_treatment');
    expect(validateToolArgs('copy_develop_settings', { source_id: 914, target_ids: [915] })).toBeNull();
  });
});

describe('set_crop', () => {
  const planned = {
    photo_id: '914',
    settings: { CropLeft: 0.15, CropTop: 0.1, CropRight: 0.92, CropBottom: 0.9, CropAngle: 8.000000001 },
    rectangle: { left: 0.1166, top: 0.1843, right: 0.9534, bottom: 0.8157 },
    angle: 8,
    size: { width: 1255, height: 631 },
  };

  function photo(opts: { plan?: unknown; write?: (settings: Record<string, unknown>) => unknown; warnings?: string[] } = {}) {
    const calls: [string, unknown][] = [];
    const handler = makeHandler({ call: async (action, params) => {
      calls.push([action, params]);
      if (action === 'plan_crop') {
        return { id: '1', result: { data: opts.plan ?? planned, ...(opts.warnings ? { warnings: opts.warnings } : {}) } };
      }
      const { settings } = params as { settings: Record<string, unknown> };
      return { id: '1', result: opts.write?.(settings) ?? { data: { photo_id: '914', settings } } };
    } });
    return { calls, crop: (args: Record<string, unknown>) => handler('set_crop', { photo_id: 914, ...args }) };
  }

  it('answers failed with not_found and writes nothing for a photo the catalog does not have', async () => {
    const calls: string[] = [];
    const handler = makeHandler({ call: async (action) => {
      calls.push(action);
      return { id: '1', result: { not_found: [914] } };
    } });

    expect(envelopeOf(await handler('set_crop', { photo_id: 914, aspect: { width: 1, height: 1 } }))).toEqual({ outcome: 'failed', error: '1 not found', not_found: [914] });
    expect(calls).toEqual(['plan_crop']);
  });

  it('plans in the frame module, writes the planned keys at Lightroom precision, reads them back and answers the frame', async () => {
    const { calls, crop } = photo();

    const result = await crop({ aspect: { width: 2, height: 1 }, center: { x: 0.5, y: 0.5 }, angle: 8 });

    expect(calls.map(([action]) => action)).toEqual(['plan_crop', 'write_develop_settings']);
    expect(calls[1][1]).toEqual({ photo_id: 914, settings: { CropLeft: 0.15, CropTop: 0.1, CropRight: 0.92, CropBottom: 0.9, CropAngle: 8 } });
    expect(envelopeOf(result)).toEqual({ outcome: 'done', data: {
      photo_id: '914', rectangle: planned.rectangle, angle: 8, size: { width: 1255, height: 631 },
      settings: { CropLeft: 0.15, CropTop: 0.1, CropRight: 0.92, CropBottom: 0.9, CropAngle: 8 },
    } });
  });

  it('rounds the requested angle to the precision Lightroom keeps before planning and says so', async () => {
    const { calls, crop } = photo();

    const result = await crop({ rectangle: { left: 0.1, top: 0.1, right: 0.9, bottom: 0.9 }, angle: 8.00004 });

    expect(calls[0]).toEqual(['plan_crop', { photo_id: 914, rectangle: { left: 0.1, top: 0.1, right: 0.9, bottom: 0.9 }, angle: 8 }]);
    expect(envelopeOf(result).warnings).toEqual(['Rounded to the precision Lightroom keeps: CropAngle 8.00004 -> 8']);
  });

  it('plans an angle Lightroom was seen to keep finer than a hundredth as given, with no warning', async () => {
    const { calls, crop } = photo();

    const result = await crop({ rectangle: { left: 0.1, top: 0.1, right: 0.9, bottom: 0.9 }, angle: 0.0037 });

    expect(calls[0]).toEqual(['plan_crop', { photo_id: 914, rectangle: { left: 0.1, top: 0.1, right: 0.9, bottom: 0.9 }, angle: 0.0037 }]);
    expect(envelopeOf(result).warnings).toBeUndefined();
  });

  it('passes on the frame warning of the plan', async () => {
    const { crop } = photo({ warnings: ['Upright, Transform or manual distortion is active'] });

    const result = await crop({ aspect: { width: 1, height: 1 } });

    expect(envelopeOf(result).warnings).toEqual(['Upright, Transform or manual distortion is active']);
  });

  it('refuses a planned frame turned past the range Lightroom keeps before writing', async () => {
    const { calls, crop } = photo({ plan: { ...planned, settings: { ...planned.settings, CropAngle: 47.5 } } });

    const result = await crop({ aspect: { width: 4, height: 5 }, angle: 20, relative_to: 'crop' });

    expect(envelopeOf(result)).toEqual({
      outcome: 'failed',
      error: 'This frame needs CropAngle 47.5, outside the range -45 to 45 Lightroom keeps; nothing was written',
    });
    expect(calls.map(([action]) => action)).toEqual(['plan_crop']);
  });

  it('answers partial with what Lightroom stored when the write read back other crop keys', async () => {
    const adjusted = [{ photo_id: '914', key: 'CropLeft', requested: 0.15, stored: 0 }];
    const { crop } = photo({ write: (settings) => ({
      data: { photo_id: '914', settings: { ...settings, CropLeft: 0 }, adjusted }, problem: 'Lightroom stored other values than written',
    }) });

    const result = envelopeOf(await crop({ aspect: { width: 2, height: 1 } }));

    expect(result).toMatchObject({ outcome: 'partial', error: expect.stringContaining('stored other values') });
    expect(result.data).toMatchObject({ adjusted, settings: { CropLeft: 0 } });
  });

  it('answers unknown when Lightroom does not show the crop keys after the write', async () => {
    const { crop } = photo({ write: () => ({
      data: { photo_id: '914', settings: {} }, unknown: [{ photo_id: '914', reason: 'Lightroom shows no CropLeft after the write' }],
    }) });

    expect(envelopeOf(await crop({ aspect: { width: 2, height: 1 } })).outcome).toBe('unknown');
  });

  it('passes the reference frame to the plan', async () => {
    const { calls, crop } = photo();

    await crop({ aspect: { width: 4, height: 5 }, relative_to: 'crop' });

    expect(calls[0][1]).toMatchObject({ relative_to: 'crop', aspect: { width: 4, height: 5 } });
    expect(validateToolArgs('set_crop', { photo_id: 1, aspect: { width: 4, height: 5 }, relative_to: 'frame' })).toContain('relative_to');
  });

  it('names the reference frame in every frame property instead of a fixed one', () => {
    const properties = TOOL_CONTRACTS.find((contract) => contract.name === 'set_crop')?.inputSchema.properties as Record<string, { description: string }>;
    for (const name of ['rectangle', 'center', 'scale']) {
      expect(properties[name].description).toContain('reference frame relative_to selects');
    }
    expect(properties.scale.description).toContain('stays inside the current crop');
  });

  it('reads the current crop through get_crop', async () => {
    const calls: string[] = [];
    const read = { photo_id: '914', rectangle: { left: 0.1, top: 0.2, right: 0.9, bottom: 0.8 }, angle: 2, size: { width: 1200, height: 600 } };
    const result = await makeHandler({ call: async (action) => {
      calls.push(action);
      return { id: '1', result: { data: read } };
    } })('get_crop', { photo_id: 914 });

    expect(calls).toEqual(['get_crop']);
    expect(envelopeOf(result)).toEqual({ outcome: 'done', data: read });
  });

  it('is pointed to from set_develop_settings for a crop stated in the displayed frame', () => {
    const tool = TOOL_CONTRACTS.find((contract) => contract.name === 'set_develop_settings');
    expect(tool?.description).toContain('set_crop');
  });
});

describe('describe_develop_keys', () => {
  it('answers failed with not_found for a photo the catalog does not have', async () => {
    const handler = makeHandler({ call: async () => ({ id: '1', result: { not_found: [914] } }) });

    expect(envelopeOf(await handler('describe_develop_keys', { photo_id: 914 }))).toEqual({ outcome: 'failed', error: '1 not found', not_found: [914] });
  });

  function lightroom(ranges: Record<string, [number, number]>, localRanges: Record<string, [number, number]> = {}) {
    const calls: [string, unknown][] = [];
    const handler = makeHandler({ call: async (action, params) => {
      calls.push([action, params]);
      return { id: '1', result: { data: {
        photo_id: '914', lightroom: { version: '16.0', build: '16.0.0 build 202611041403' }, process_version: 'Version 6',
        ranges, local_ranges: localRanges,
      } } };
    } });
    return { calls, describe: (args: Record<string, unknown>) => handler('describe_develop_keys', { photo_id: 914, ...args }) };
  }

  type Described = {
    keys: { key: string; kind: string; values?: unknown[]; range?: unknown; live?: unknown; differs?: boolean }[];
    local: { key: string; range: unknown; live: unknown; differs?: boolean }[];
  };

  it('asks Lightroom for the range of every number key and reports it beside the table range', async () => {
    const { calls, describe } = lightroom({ Exposure2012: [-5, 5], Contrast2012: [-50, 50], Temperature: [1500, 50000] });

    const result = await describe({});

    const numberKeys = DEVELOP_KEYS.filter((key) => key.kind === 'number').map((key) => key.name);
    expect(calls).toEqual([['read_develop_ranges', { photo_id: 914, keys: numberKeys }]]);
    const data = dataOf(result) as Described & Record<string, unknown>;
    expect(data.lightroom).toEqual({ version: '16.0', build: '16.0.0 build 202611041403' });
    expect(data.process_version).toBe('Version 6');
    const byKey = new Map(data.keys.map((entry) => [entry.key, entry]));
    expect(byKey.get('Exposure2012')).toEqual({ key: 'Exposure2012', kind: 'number', range: [-5, 5], live: [-5, 5] });
    expect(byKey.get('Contrast2012')).toEqual({ key: 'Contrast2012', kind: 'number', range: [-100, 100], live: [-50, 50], differs: true });
    expect(byKey.get('Temperature')).toEqual({ key: 'Temperature', kind: 'number', range: 'photo', live: [1500, 50000] });
    expect(byKey.get('Texture')).toEqual({ key: 'Texture', kind: 'number', range: [-100, 100], live: null });
    expect(byKey.get('WhiteBalance')).toMatchObject({ key: 'WhiteBalance', kind: 'enum' });
    expect(byKey.get('WhiteBalance')).not.toHaveProperty('live');
    expect(data.keys).toHaveLength(DEVELOP_KEYS.length);
  });

  it('treats a live range within 1e-9 of the table as the same and a larger difference as differing', async () => {
    const { describe } = lightroom({ Contrast2012: [-100, 100.0000000001], Texture: [-100, 100.001] });

    const byKey = new Map((dataOf(await describe({})) as Described).keys.map((entry) => [entry.key, entry]));

    expect(byKey.get('Contrast2012')).toEqual({ key: 'Contrast2012', kind: 'number', range: [-100, 100], live: [-100, 100.0000000001] });
    expect(byKey.get('Texture')).toEqual({ key: 'Texture', kind: 'number', range: [-100, 100], live: [-100, 100.001], differs: true });
  });

  it('reads local ranges only on a mask, and says so without one', async () => {
    const withMask = lightroom({}, { local_Exposure: [-4, 4], local_glow: [0, 100] });
    const local = (dataOf(await withMask.describe({ mask_id: 'M1' })) as Described).local;
    expect(withMask.calls[0][1]).toMatchObject({ mask_id: 'M1', local_keys: LOCAL_KEYS.map((key) => key.name) });
    expect(local.find((entry) => entry.key === 'local_Exposure')).toEqual({ key: 'local_Exposure', range: [-4, 4], live: [-4, 4] });
    expect(local.find((entry) => entry.key === 'local_glow')).toEqual({ key: 'local_glow', range: [-100, 100], live: [0, 100], differs: true });

    const without = lightroom({});
    const result = await without.describe({});
    expect((dataOf(result) as Described).local.every((entry) => entry.live === null)).toBe(true);
    expect(envelopeOf(result).warnings).toEqual([expect.stringContaining('mask_id')]);
  });
});
