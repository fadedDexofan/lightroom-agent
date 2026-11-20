import { describe, expect, it, jest } from '@jest/globals';
import { envelopeOf } from './helpers/envelope.js';
import { createCallToolHandler } from '../src/tool-handler.js';
import type { PluginResponse } from '../src/dispatcher.js';

const records = { id: 'm', result: { data: { photos: [{ photo_id: '7', rating: 3 }, { photo_id: '9', rating: 0 }] }, not_found: ['/missing.arw'] } };
const lens = {
  id: 'l',
  result: { data: { photos: [
    { photo_id: '7', lens_profile: { enabled: true, setup: 'LensDefaults', name: 'Adobe (Sony FE 16-35mm F2.8 GM)', distortion_scale: 100 } },
    { photo_id: '9', lens_profile: { enabled: false } },
  ] } },
};

function handlerWith(answer: (action: string) => PluginResponse) {
  const call = jest.fn(async (action: string, _params: unknown, _timeout?: number, _options?: unknown) => answer(action));
  return { handler: createCallToolHandler({ admitted: () => 0, dispatcher: { call } }), call };
}

describe('get_photo_metadata', () => {
  it('reads the metadata alone when the lens profile is not asked', async () => {
    const { handler, call } = handlerWith(() => records as PluginResponse);
    const envelope = envelopeOf(await handler('get_photo_metadata', { photo_ids: [7, 9, '/missing.arw'] }));
    expect(call.mock.calls.map(([action, params]) => [action, params])).toEqual([['read_photo_metadata', { photo_ids: [7, 9, '/missing.arw'] }]]);
    expect(envelope.data).toEqual(records.result.data);
    expect(envelope.not_found).toEqual(['/missing.arw']);
  });

  it('adds each found photo its lens profile, read for the found photos only, in request order', async () => {
    const { handler, call } = handlerWith((action) => (action === 'read_photo_metadata' ? records : lens) as PluginResponse);
    const envelope = envelopeOf(await handler('get_photo_metadata', { photo_ids: [7, 9, '/missing.arw'], lens_profile: true }));
    expect(call.mock.calls.map(([action, params]) => [action, params])).toEqual([
      ['read_photo_metadata', { photo_ids: [7, 9, '/missing.arw'] }],
      ['read_lens_profiles', { photo_ids: ['7', '9'] }],
    ]);
    expect(envelope.data).toEqual({ photos: [
      { photo_id: '7', rating: 3, lens_profile: lens.result.data.photos[0].lens_profile },
      { photo_id: '9', rating: 0, lens_profile: { enabled: false } },
    ] });
    expect(envelope.not_found).toEqual(['/missing.arw']);
  });

  it('keeps the metadata and says so when the lens profile read fails', async () => {
    const { handler } = handlerWith((action) => {
      if (action === 'read_photo_metadata') return records as PluginResponse;
      throw new Error('Lightroom is busy with apply_denoise; nothing was done');
    });
    const envelope = envelopeOf(await handler('get_photo_metadata', { photo_ids: [7], lens_profile: true }));
    expect(envelope.data).toEqual(records.result.data);
    expect(envelope.warnings).toEqual(['The lens profile was not read: Lightroom is busy with apply_denoise; nothing was done']);
  });
});
