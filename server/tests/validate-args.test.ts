import { describe, it, expect } from 'vitest';
import { Ajv } from 'ajv';
import { validateToolArgs } from './helpers/validate.js';
import { PHOTO_ID_PATTERN, TOOL_CONTRACTS } from '../src/tool-contracts.js';

const OLD_PHOTO_NAMES = new Set(['photo_id', 'source_id', 'target_ids', 'reference_id']);
const ROLE_PHOTO_ID = /^(source|reference)_photo_id$/;
const RECORD_FIELD = 'set_develop_settings_batch.photos[].photo_id';

function children(schema: Record<string, unknown>, path: string): [string, string | null, unknown][] {
  const found: [string, string | null, unknown][] = [];
  for (const [name, property] of Object.entries((schema.properties ?? {}) as Record<string, unknown>)) {
    found.push([`${path}.${name}`, name, property]);
  }
  if (schema.items) found.push([`${path}[]`, null, schema.items]);
  for (const keyword of ['anyOf', 'oneOf', 'allOf']) {
    for (const branch of (schema[keyword] ?? []) as unknown[]) found.push([path, null, branch]);
  }
  for (const keyword of ['if', 'then', 'else']) if (schema[keyword]) found.push([path, null, schema[keyword]]);
  return found;
}

function photoNames(
  schema: unknown,
  path: string,
  found: [string, string, unknown][] = [],
): [string, string, unknown][] {
  if (!schema || typeof schema !== 'object') return found;
  for (const [childPath, name, child] of children(schema as Record<string, unknown>, path)) {
    const items = (child as { items?: unknown } | undefined)?.items;
    const pattern = ((items ?? child) as { pattern?: string } | undefined)?.pattern;
    if (name && (pattern === PHOTO_ID_PATTERN || OLD_PHOTO_NAMES.has(name) || name.endsWith('photo_ids'))) {
      found.push([childPath, name, items ?? child]);
    }
    photoNames(child, childPath, found);
  }
  return found;
}

describe('photo id inputs', () => {
  const schemas = TOOL_CONTRACTS.flatMap((contract) => photoNames(contract.inputSchema, contract.name));

  it('cover every tool that names a photo', () => {
    expect(schemas.length).toBeGreaterThan(60);
  });

  it('name the photos a tool acts on photo_ids and a photo in another role <role>_photo_id', () => {
    const misnamed = schemas
      .filter(([path, name]) => path !== RECORD_FIELD && name !== 'photo_ids' && !ROLE_PHOTO_ID.test(name))
      .map(([path]) => path);
    expect(misnamed).toEqual([]);
  });

  it('walk nested properties, items and combinators', () => {
    const paths = schemas.map(([path]) => path);
    expect(paths).toContain(RECORD_FIELD);
    expect(paths).toContain('create_range_mask.copy_sample_from.source_photo_id');
  });

  it('walk anyOf, oneOf, allOf, if and then', () => {
    const id = { type: 'string', pattern: PHOTO_ID_PATTERN };
    const synthetic = {
      anyOf: [{ properties: { a_photo_id: id } }],
      oneOf: [{ properties: { photo_id: id } }],
      allOf: [{ properties: { b: { items: { properties: { c_photo_id: id } } } } }],
      if: { properties: { source_id: id } },
      then: { properties: { target_ids: { type: 'array', items: id } } },
    };
    expect(photoNames(synthetic, 'x').map(([path]) => path)).toEqual([
      'x.a_photo_id',
      'x.photo_id',
      'x.b[].c_photo_id',
      'x.source_id',
      'x.target_ids',
    ]);
  });

  it.each(schemas)('%s accepts only a canonical id or an absolute path', (_path, _name, schema) => {
    const validate = new Ajv({ strict: false }).compile(schema as object);
    for (const id of [7, '7', '/Users/me/a.nef', 'C:\\Photos\\a.nef', 'D:/a.nef', '\\\\nas\\a.nef']) {
      expect([id, validate(id)]).toEqual([id, true]);
    }
    for (const id of ['001', 1.5, '-5', -5, 0, '0', '', 'a.nef', 'photos/a.nef', ' 7', '7 ', '0x1', '1.0']) {
      expect([id, validate(id)]).toEqual([id, false]);
    }
  });

  it('give every single-photo tool exactly one photo', () => {
    const single = TOOL_CONTRACTS.filter((contract) => {
      const ids = (contract.inputSchema.properties as Record<string, { maxItems?: number }> | undefined)?.photo_ids;
      return ids?.maxItems === 1;
    }).map((contract) => contract.name);
    expect(single.length).toBe(33);
    for (const name of single) {
      const contract = TOOL_CONTRACTS.find((candidate) => candidate.name === name)!;
      const ids = (contract.inputSchema.properties as Record<string, { minItems?: number }>).photo_ids;
      expect([name, ids.minItems]).toEqual([name, 1]);
      const required = (contract.inputSchema.required ?? []) as string[];
      expect([name, required.includes('photo_ids')]).toEqual([name, name !== 'get_mask_write_admission']);
    }
  });
});

describe('copy_develop_settings profile unit', () => {
  it('takes "profile" beside the develop keys in settings', () => {
    expect(
      validateToolArgs('copy_develop_settings', { source_photo_id: 1, photo_ids: [2], settings: ['profile'] }),
    ).toBeNull();
    expect(
      validateToolArgs('copy_develop_settings', {
        source_photo_id: 1,
        photo_ids: [2],
        settings: ['profile', 'Exposure2012'],
      }),
    ).toBeNull();
    expect(
      validateToolArgs('copy_develop_settings', { source_photo_id: 1, photo_ids: [2], settings: ['Look'] }),
    ).toContain('settings.0 must be one of');
    expect(
      validateToolArgs('copy_develop_settings', { source_photo_id: 1, photo_ids: [2], settings: ['CameraProfile'] }),
    ).toContain('use "profile" to copy the profile');
  });
});

describe('set_profile', () => {
  it('takes a proven Adobe Raw profile name or a whole amount, not both', () => {
    expect(validateToolArgs('set_profile', { photo_ids: [1], profile: 'Adobe Color' })).toBeNull();
    expect(validateToolArgs('set_profile', { photo_ids: [1], profile: 'Adobe Landscape' })).toBeNull();
    expect(validateToolArgs('set_profile', { photo_ids: [1], amount: 50 })).toBeNull();
    expect(validateToolArgs('set_profile', { photo_ids: [1], profile: 'Adobe Color', amount: 50 })).toContain(
      'give profile or amount, not both',
    );
    expect(validateToolArgs('set_profile', { photo_ids: [1] })).toContain('give profile or amount, not both');
    expect(validateToolArgs('set_profile', { photo_ids: [1], profile: 'Adobe Vivid' })).toContain(
      'profile must be one of',
    );
    expect(validateToolArgs('set_profile', { photo_ids: [1], amount: 50.5 })).toContain('amount must be integer');
    expect(validateToolArgs('set_profile', { photo_ids: [1], amount: 201 })).toContain('amount must be <= 200');
  });
});

describe('old photo names', () => {
  it.each([
    ['get_crop', { photo_id: 7 }, 'unknown property "photo_id": use photo_ids'],
    ['get_photo_metadata', { photo_id: 7 }, 'unknown property "photo_id": use photo_ids'],
    ['copy_develop_settings', { source_id: 1, target_ids: [2] }, 'unknown property "source_id": use source_photo_id'],
    ['copy_develop_settings', { source_photo_id: 1, target_ids: [2] }, 'unknown property "target_ids": use photo_ids'],
    [
      'match_photo_style',
      { reference_id: 1, photo_ids: [2] },
      'unknown property "reference_id": use reference_photo_id',
    ],
    [
      'create_range_mask',
      { photo_ids: [1], type: 'color', copy_sample_from: { mask_id: '1', tool_id: '2', photo_id: 3 } },
      'copy_sample_from unknown property "photo_id": use source_photo_id',
    ],
  ])('%s refuses %j naming the new name', (name, args, hint) => {
    expect(validateToolArgs(name, args)).toContain(hint);
  });

  it.each([
    ['list_collections', { photo_id: 1 }],
    ['search_photos', { photo_id: 1 }],
    ['set_develop_settings_batch', { photo_id: 1, photos: [{ photo_id: 1, settings: { Exposure2012: 1 } }] }],
  ])('%s, which takes no photo_ids, refuses %j without a rename hint', (name, args) => {
    const message = validateToolArgs(name, args);
    expect(message).toContain('unknown property "photo_id"');
    expect(message).not.toContain('use ');
  });

  it.each([
    ['match_photo_style', { source_id: 1, photo_ids: [2] }, 'unknown property "source_id": use reference_photo_id'],
    [
      'copy_develop_settings',
      { reference_id: 1, photo_ids: [2] },
      'unknown property "reference_id": use source_photo_id',
    ],
    [
      'set_develop_settings_batch',
      { photos: [{ photo_ids: [1], settings: { Exposure2012: 1 } }] },
      'photos.0 unknown property "photo_ids": use photo_id',
    ],
  ])('%s names the role id it takes for %j', (name, args, hint) => {
    expect(validateToolArgs(name, args)).toContain(hint);
  });

  it.each([
    [
      'set_develop_settings',
      { photo_ids: [1], settings: { CameraProfile: 'Adobe Standard' } },
      'settings unknown property "CameraProfile": use set_profile',
    ],
    [
      'set_develop_settings',
      { photo_ids: [1], settings: { Look: {} } },
      'settings unknown property "Look": use set_profile',
    ],
    [
      'set_develop_settings_batch',
      { photos: [{ photo_id: 1, settings: { ProfileAmount: 50 } }] },
      'photos.0.settings unknown property "ProfileAmount": use set_profile',
    ],
  ])('%s points a profile key under settings to set_profile', (name, args, hint) => {
    expect(validateToolArgs(name, args)).toContain(hint);
  });

  it('keeps a photo_id under settings a settings error', () => {
    const message = validateToolArgs('set_develop_settings', { photo_ids: [1], settings: { photo_id: 3 } });
    expect(message).not.toBeNull();
    expect(message).not.toContain('use photo_ids');
  });

  it('points a single-photo tool given several photos to its plural sibling', () => {
    expect(validateToolArgs('get_photo_preview', { photo_ids: [1, 2] })).toContain('use get_photo_previews');
    expect(validateToolArgs('set_develop_settings', { photo_ids: [1, 2], settings: { Exposure2012: 1 } })).toContain(
      'use set_develop_settings_batch',
    );
    expect(validateToolArgs('get_crop', { photo_ids: [1, 2] })).toContain('photo_ids must NOT have more than 1 items');
    expect(validateToolArgs('create_mask', { photo_ids: [1, 2], type: 'sky' })).toContain('use create_mask_batch');
    expect(validateToolArgs('create_mask', { photo_ids: [1, 2], type: 'people' })).not.toContain('create_mask_batch');
  });

  it('answers the mask admission with and without a photo', () => {
    expect(validateToolArgs('get_mask_write_admission', {})).toBeNull();
    expect(validateToolArgs('get_mask_write_admission', { photo_ids: [7] })).toBeNull();
    expect(validateToolArgs('get_mask_write_admission', { photo_ids: [7, 8] })).toContain('more than 1');
  });
});

describe('validateToolArgs', () => {
  it('names the accepted photo id forms', () => {
    const message = 'must be a photo ID (an integer from 1 without a leading zero) or an absolute file path';
    expect(validateToolArgs('get_photo_metadata', { photo_ids: [true] })).toBe(
      `Invalid arguments for get_photo_metadata: photo_ids.0 ${message}`,
    );
    expect(validateToolArgs('set_rating_and_flag', { photo_ids: ['001'], rating: 3 })).toBe(
      `Invalid arguments for set_rating_and_flag: photo_ids.0 ${message}`,
    );
    expect(validateToolArgs('get_photo_preview', { photo_ids: [1.5] })).toBe(
      `Invalid arguments for get_photo_preview: photo_ids.0 ${message}`,
    );
    expect(validateToolArgs('get_photo_metadata', { photo_ids: [''] })).toContain('photo_ids');
    expect(validateToolArgs('get_photo_metadata', { photo_ids: [914] })).toBeNull();
    expect(validateToolArgs('get_photo_metadata', { photo_id: 914 })).toContain(
      'unknown property "photo_id": use photo_ids',
    );
  });

  describe.each([
    ['create_gradient_mask', { photo_ids: [1], shape: 'radial', center: { x: 0.5, y: 0.5 }, width: 0.4, height: 0.6 }],
    ['create_brush_mask', { photo_ids: [1], strokes: [{ points: [{ x: 0.5, y: 0.5 }] }] }],
    ['create_range_mask', { photo_ids: [1], type: 'luminance', luminance: { min: 0.3, max: 0.6 } }],
  ])('%s creation adjustments', (name, base) => {
    it('accepts the set_mask_adjustments slider names and preserves calls without adjustments', () => {
      expect(validateToolArgs(name, base)).toBeNull();
      expect(
        validateToolArgs(name, {
          ...base,
          adjustments: { local_Exposure: 1, local_LuminanceNoise: -20, local_Contrast: 0 },
        }),
      ).toBeNull();
      expect(validateToolArgs(name, { ...base, mask_id: 'existing' })).toBeNull();
    });

    it.each([
      {},
      { local_Exposure: 5 },
      { local_Contrast: -101 },
      { local_Exposure: '1' },
      { exposure: 1 },
      { unknown: 1 },
    ])('rejects invalid adjustments: %o', (adjustments) => {
      expect(validateToolArgs(name, { ...base, adjustments })).toContain(`Invalid arguments for ${name}`);
    });

    it('rejects adjustments on an existing mask', () => {
      expect(validateToolArgs(name, { ...base, mask_id: 'existing', adjustments: { local_Exposure: 1 } })).toContain(
        'adjustments',
      );
    });
  });
  describe('get_photo_metadata batches', () => {
    it('accepts mixed selectors, repeats and the cap', () => {
      for (const photo_ids of [[914, '/a.jpg', 914], Array.from({ length: 100 }, (_, i) => i + 1)]) {
        expect(validateToolArgs('get_photo_metadata', { photo_ids })).toBeNull();
      }
    });

    it.each([
      {},
      { photo_id: 1, photo_ids: [1] },
      { photo_ids: [] },
      { photo_ids: Array.from({ length: 101 }, () => 1) },
      { photo_ids: [null] },
      { photo_ids: [''] },
      { photo_ids: [true] },
      { photo_ids: '914' },
      { photo_ids: ['absent'] },
      { photo_id: null },
      { photo_ids: [1], sections: ['developSettings'] },
      { photo_ids: [1], extra: true },
      false,
    ])('rejects invalid selectors: %o', (args) => {
      expect(validateToolArgs('get_photo_metadata', args)).toContain('Invalid arguments for get_photo_metadata');
    });
  });

  it.each(['cull', 'review', 64, 512.5, 1024, 2048])('get_photo_preview accepts size %s', (size) => {
    expect(validateToolArgs('get_photo_preview', { photo_ids: [914], size })).toBeNull();
  });

  it.each(['huge', 'detail', '512', '', 63, 5000, null, true, {}, NaN, Infinity])(
    'get_photo_preview explains accepted sizes for %s',
    (size) => {
      expect(validateToolArgs('get_photo_preview', { photo_ids: [914], size })).toMatch(/cull.*review.*64.*2048/);
    },
  );

  it('get_photo_previews refuses a size name the vocabulary does not have', () => {
    expect(validateToolArgs('get_photo_previews', { photo_ids: [914], size: 'detail' })).toContain('size');
  });

  it('get_photo_previews takes at most 20 photos', () => {
    expect(
      validateToolArgs('get_photo_previews', { photo_ids: Array.from({ length: 20 }, (_, i) => i + 1) }),
    ).toBeNull();
    expect(
      validateToolArgs('get_photo_previews', { photo_ids: Array.from({ length: 21 }, (_, i) => i + 1) }),
    ).toContain('20');
  });

  it.each([{}, { limit: 0 }, { limit: 10, offset: 2, query: 'vi', folder: 'User Presets' }])(
    'list_develop_presets accepts paging and filters %o',
    (args) => {
      expect(validateToolArgs('list_develop_presets', args)).toBeNull();
    },
  );

  it.each([{ limit: -1 }, { offset: -1 }, { query: '' }, { folder: '' }, { scope: 'plugin' }, { extra: true }])(
    'list_develop_presets rejects invalid arguments %o',
    (args) => {
      expect(validateToolArgs('list_develop_presets', args)).not.toBeNull();
    },
  );

  it.each(['Circle', 'SoapBubble', 'Blade', 'Ring', 'Anamorphic'])('set_lens_blur accepts %s bokeh', (bokeh) => {
    expect(validateToolArgs('set_lens_blur', { photo_ids: [914], bokeh })).toBeNull();
  });

  it.each([
    { bokeh: 'Square' },
    { amount: -1 },
    { amount: 101 },
    { amount: '50' },
    { cat_eye: Infinity },
    { highlights_boost: NaN },
    { active: 1 },
    { focal_range: { near: 0, far: 101 } },
    { focal_range: { near: 0 } },
  ])('set_lens_blur rejects invalid controls %o', (controls) => {
    expect(validateToolArgs('set_lens_blur', { photo_ids: [914], ...controls })).not.toBeNull();
  });

  it('set_lens_blur requires a change and accepts combined controls', () => {
    expect(validateToolArgs('set_lens_blur', { photo_ids: [914] })).not.toBeNull();
    expect(
      validateToolArgs('set_lens_blur', {
        photo_ids: [914],
        active: false,
        amount: 50,
        cat_eye: 0,
        highlights_boost: 100,
        focal_range: { near: 10, far: 30 },
        bokeh: 'Ring',
      }),
    ).toBeNull();
    expect(validateToolArgs('get_lens_blur', { photo_ids: [914] })).toBeNull();
  });

  it.each([
    ['copy_develop_settings', { source_photo_id: 1, photo_ids: [2] }],
    ['apply_develop_preset', { preset_name: 'Heavy', photo_ids: [2] }],
  ])('%s accepts only boolean dry_run values', (name, args) => {
    for (const dry_run of [undefined, false, true]) {
      expect(validateToolArgs(name, { ...args, dry_run })).toBeNull();
    }
    for (const dry_run of ['true', 1, null]) {
      expect(validateToolArgs(name, { ...args, dry_run })).toContain('dry_run');
    }
  });

  const CONFIRM_TOOLS: [string, Record<string, unknown>][] = [
    ['reset_develop_adjustments', { photo_ids: [914] }],
    ['set_process_version', { photo_ids: [914], version: 'Version 6' }],
    ['delete_spot', { photo_ids: [914], index: 1 }],
    ['undo_last_step', {}],
    ['remove_photos_from_catalog', { photo_ids: [914] }],
  ];

  it('the confirm table covers every tool that takes confirm', () => {
    const confirmTools = TOOL_CONTRACTS.filter(
      (contract) => 'confirm' in ((contract.inputSchema as { properties?: object }).properties ?? {}),
    );
    expect(confirmTools.map((contract) => contract.name).sort()).toEqual(CONFIRM_TOOLS.map(([name]) => name).sort());
  });

  it.each(CONFIRM_TOOLS)('%s runs only with literal confirm true', (name, args) => {
    expect(validateToolArgs(name, { ...args, confirm: true })).toBeNull();
    expect(validateToolArgs(name, args)).toContain("required property 'confirm'");
    for (const confirm of [false, 'true', 1, null]) {
      expect([confirm, validateToolArgs(name, { ...args, confirm })]).toEqual([
        confirm,
        expect.stringContaining('confirm must'),
      ]);
    }
  });

  it.each([
    ['add_to_collection', 'photo_ids', { collection_name: 'Trip' }],
    ['remove_from_collection', 'photo_ids', { collection_name: 'Trip' }],
    ['set_gps', 'photo_ids', { latitude: 1, longitude: 2 }],
    ['set_location', 'photo_ids', { city: 'Oslo' }],
    ['set_metadata', 'photo_ids', { title: 'Heron' }],
    ['set_keywords', 'photo_ids', { add_keywords: ['bird'] }],
    ['set_rating_and_flag', 'photo_ids', { rating: 3 }],
    ['set_color_label', 'photo_ids', { label: 'red' }],
    ['export_photos', 'photo_ids', { destination: '/tmp/out' }],
    ['export_photo_metadata', 'photo_ids', { destination: '/tmp/a.json' }],
    ['apply_develop_preset', 'photo_ids', { preset_name: 'Warm film' }],
    ['copy_develop_settings', 'photo_ids', { source_photo_id: 1 }],
    ['match_photo_style', 'photo_ids', { reference_photo_id: 1 }],
    ['delete_empty_masks', 'photo_ids', {}],
  ])('%s takes 1 to 1000 %s', (name, field, args) => {
    const ids = (count: number) => Array.from({ length: count }, (_, i) => i + 2);
    expect(validateToolArgs(name, { ...args, [field]: ids(1) })).toBeNull();
    expect(validateToolArgs(name, { ...args, [field]: ids(1000) })).toBeNull();
    expect(validateToolArgs(name, { ...args, [field]: [] })).toContain(`${field} must NOT have fewer than 1 items`);
    expect(validateToolArgs(name, { ...args, [field]: ids(1001) })).toContain(
      `${field} must NOT have more than 1000 items`,
    );
  });

  it('set_keywords takes up to 1000 keywords per list and a boolean create_missing', () => {
    for (const field of ['add_keywords', 'remove_keywords']) {
      expect(validateToolArgs('set_keywords', { photo_ids: [1], [field]: Array(1000).fill('bird') })).toBeNull();
      expect(validateToolArgs('set_keywords', { photo_ids: [1], [field]: Array(1001).fill('bird') })).toContain(field);
      expect(validateToolArgs('set_keywords', { photo_ids: [1], [field]: [] })).toContain(
        `${field} must NOT have fewer than 1 items`,
      );
    }
    expect(
      validateToolArgs('set_keywords', { photo_ids: [1], add_keywords: ['bird'], create_missing: true }),
    ).toBeNull();
    expect(
      validateToolArgs('set_keywords', { photo_ids: [1], add_keywords: ['bird'], create_missing: 'true' }),
    ).toContain('create_missing');
    expect(validateToolArgs('set_keywords', { add_keywords: ['bird'] })).toContain("required property 'photo_ids'");
  });

  it('remove_photos_from_catalog takes at most 100 photo_ids', () => {
    expect(
      validateToolArgs('remove_photos_from_catalog', {
        photo_ids: Array.from({ length: 100 }, (_, i) => i + 1),
        confirm: true,
      }),
    ).toBeNull();
    expect(
      validateToolArgs('remove_photos_from_catalog', {
        photo_ids: Array.from({ length: 101 }, (_, i) => i + 1),
        confirm: true,
      }),
    ).not.toBeNull();
  });

  it('set_ai_metadata bounds scores and reasons', () => {
    for (const score of [0, 72, 100, '']) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1, 2], score })).toBeNull();
    }
    for (const score of [-1, 101, 1.5, '72', null, false, NaN, Infinity]) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1], score })).not.toBeNull();
    }
    for (const reason of ['', 'eyes closed', 'é'.repeat(1024)]) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1], reason })).toBeNull();
    }
    for (const reason of [42, null, 'a'.repeat(1025), 'é'.repeat(1025)]) {
      expect(validateToolArgs('set_ai_metadata', { photo_ids: [1], reason })).not.toBeNull();
    }
    expect(validateToolArgs('set_ai_metadata', { photo_ids: [], score: 72 })).not.toBeNull();
  });

  it('get_ai_metadata accepts 200 photos and rejects malformed batches', () => {
    expect(validateToolArgs('get_ai_metadata', { photo_ids: Array.from({ length: 200 }, (_, i) => i + 1) })).toBeNull();
    for (const photo_ids of [[], [null], Array.from({ length: 1001 }, () => 1)]) {
      expect(validateToolArgs('get_ai_metadata', { photo_ids })).not.toBeNull();
    }
  });

  it('bounds virtual-copy batches and accepts an optional nonblank copy name', () => {
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [914, '/a.jpg'] })).toBeNull();
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [914], copy_name: 'Experiment' })).toBeNull();
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [] })).toContain('photo_ids');
    expect(validateToolArgs('create_virtual_copies', { photo_ids: Array.from({ length: 26 }, () => 914) })).toContain(
      'photo_ids',
    );
    expect(validateToolArgs('create_virtual_copies', { photo_ids: [914], copy_name: ' ' })).toContain('copy_name');
  });

  it('apply_auto_adjustments accepts either automatic correction and bounds the batch', () => {
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], tone: true })).toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], white_balance: true })).toBeNull();
    expect(
      validateToolArgs('apply_auto_adjustments', { photo_ids: [914], tone: true, white_balance: true }),
    ).toBeNull();
    expect(validateToolArgs('apply_auto_adjustments', { photo_ids: [914], tone: 'true' })).not.toBeNull();
    expect(
      validateToolArgs('apply_auto_adjustments', { photo_ids: Array.from({ length: 101 }, () => '1'), tone: true }),
    ).not.toBeNull();
  });

  it('search_photos accepts intersecting Library filters', () => {
    expect(
      validateToolArgs('search_photos', {
        camera: 'Sony ILCE-7M3',
        lens: '24-70mm',
        iso: 100,
        focal_length: 32,
        flag: 'reject',
        color_label: 'red',
        edited: false,
        file_type: 'RAW',
        folder: 'Photos Travel',
        rating: 5,
      }),
    ).toBeNull();
    for (const flag of ['pick', 'reject', 'none']) {
      expect(validateToolArgs('search_photos', { flag })).toBeNull();
    }
    for (const color_label of ['red', 'yellow', 'green', 'blue', 'purple', 'none']) {
      expect(validateToolArgs('search_photos', { color_label })).toBeNull();
    }
  });

  it.each([
    ['flag', 'maybe'],
    ['file_type', 'GIF'],
    ['color_label', 'pink'],
    ['camera', ''],
    ['lens', 42],
    ['folder', '  '],
    ['iso', 0],
    ['iso', Infinity],
    ['edited', 'false'],
    ['focal_length', 0],
    ['focal_length', -32],
    ['focal_length', Infinity],
    ['focal_length', NaN],
    ['focal_length', '32 mm'],
    ['rating', 6],
    ['rating', -1],
    ['keywords', []],
    ['camera', ' '],
    ['lens', ' '],
    ['start_date', '2024-6-3'],
    ['end_date', '2024-06-3'],
  ])('search_photos rejects invalid %s filter %s', (key, value) => {
    expect(validateToolArgs('search_photos', { [key]: value })).toContain(key);
  });

  it.each([
    ['search_photos', 'camera', {}],
    ['rename_keyword', 'new_name', { keyword: 'zebra' }],
  ])('%s refuses an empty %s with the one non-blank rule, as it refuses a blank one', (tool, key, rest) => {
    expect(validateToolArgs(tool, { ...rest, [key]: '' })).toBe(validateToolArgs(tool, { ...rest, [key]: ' ' }));
  });

  it('accepts arguments that satisfy the published schema', () => {
    expect(validateToolArgs('get_photo_metadata', { photo_ids: [914], sections: ['developSettings'] })).toContain(
      'unknown property "sections"',
    );
    expect(validateToolArgs('get_photo_metadata', { photo_ids: [914, '/a.jpg'] })).toBeNull();
    expect(validateToolArgs('set_rating_and_flag', { photo_ids: [914], rating: 3 })).toBeNull();
    expect(validateToolArgs('search_photos', {})).toBeNull();
  });

  it('takes ratings as whole stars, to write and to search', () => {
    expect(validateToolArgs('set_rating_and_flag', { photo_ids: [914], rating: 2.5 })).toMatch(/rating/);
    expect(validateToolArgs('search_photos', { rating: 3.5 })).toMatch(/rating/);
    expect(validateToolArgs('create_smart_collection', { name: 'x', rating: 4.5 })).toMatch(/rating/);
    expect(validateToolArgs('search_photos', { rating: 4 })).toBeNull();
  });

  it('set_process_version accepts only named versions', () => {
    const args = { photo_ids: [914], version: 'Version 6', confirm: true };
    for (let version = 1; version <= 6; version++) {
      expect(validateToolArgs('set_process_version', { ...args, version: `Version ${version}` })).toBeNull();
    }
    for (const version of ['Version 7', '2012']) {
      expect(validateToolArgs('set_process_version', { ...args, version })).toContain('version');
    }
    expect(
      validateToolArgs('set_process_version', { ...args, photo_ids: Array.from({ length: 101 }, () => '1') }),
    ).toContain('photo_ids');
  });

  it('bounds apply_denoise amount and batch size', () => {
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 45 })).toBeNull();
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 0 })).toContain('amount');
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 101 })).toContain('amount');
    expect(validateToolArgs('apply_denoise', { photo_ids: [914], amount: 30.5 })).toContain('amount');
    expect(validateToolArgs('apply_denoise', { photo_ids: [914] })).toContain('amount');
    const tooMany = Array.from({ length: 101 }, (_, i) => i + 1);
    expect(validateToolArgs('apply_denoise', { photo_ids: tooMany, amount: 30 })).toContain('photo_ids');
  });

  it('requires a single photo for list_masks', () => {
    expect(validateToolArgs('list_masks', { photo_ids: [914] })).toBeNull();
    expect(validateToolArgs('list_masks', { photo_ids: ['/a.dng'] })).toBeNull();
    expect(validateToolArgs('list_masks', {})).toContain('photo_ids');
    expect(validateToolArgs('list_masks', { photo_ids: 914 })).toContain('photo_ids must be array');
    expect(validateToolArgs('list_masks', { photo_ids: [914], extra: 1 })).toContain('unknown property "extra"');
  });

  describe('gradient mask tools', () => {
    const linear = {
      photo_ids: [1],
      shape: 'linear',
      start: { x: 0.5, y: 0.2 },
      end: { x: 0.5, y: 0.6 },
    };
    const radial = {
      photo_ids: ['/a.dng'],
      shape: 'radial',
      center: { x: 0.5, y: 0.5 },
      width: 0.4,
      height: 0.6,
      rotation: 30,
      feather: 20,
      area: 'outside',
      mask_id: 'abc',
      mode: 'subtract',
    };

    it('accepts linear and radial gradients', () => {
      expect(validateToolArgs('create_gradient_mask', linear)).toBeNull();
      expect(validateToolArgs('create_gradient_mask', radial)).toBeNull();
      expect(validateToolArgs('create_gradient_mask', { ...linear, name: 'Sky' })).toBeNull();
    });

    it('requires a photo and a shape', () => {
      expect(validateToolArgs('create_gradient_mask', { shape: 'linear' })).toContain('photo_ids');
      expect(validateToolArgs('create_gradient_mask', { photo_ids: [1] })).toContain('shape');
      expect(validateToolArgs('create_gradient_mask', { ...linear, shape: 'brush' })).toContain('shape');
    });

    it('rejects coordinates outside the image', () => {
      expect(validateToolArgs('create_gradient_mask', { ...linear, end: { x: 0.5, y: 1.1 } })).toContain('end');
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: { x: -0.1, y: 0.5 } })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...radial, center: { x: 2, y: 0.5 } })).toContain('center');
    });

    it('rejects pixel-style or incomplete points and unknown properties', () => {
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: { x: 0.5 } })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: [0.5, 0.5] })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...linear, start: { x: '0.5', y: 0.5 } })).toContain('start');
      expect(validateToolArgs('create_gradient_mask', { ...linear, extra: 1 })).toContain('unknown property "extra"');
    });

    it('bounds the radial fields', () => {
      expect(validateToolArgs('create_gradient_mask', { ...radial, width: 0 })).toContain('width');
      expect(validateToolArgs('create_gradient_mask', { ...radial, height: 3 })).toContain('height');
      expect(validateToolArgs('create_gradient_mask', { ...radial, feather: 101 })).toContain('feather');
      expect(validateToolArgs('create_gradient_mask', { ...radial, rotation: 400 })).toContain('rotation');
      expect(validateToolArgs('create_gradient_mask', { ...radial, area: 'around' })).toContain('area');
      expect(validateToolArgs('create_gradient_mask', { ...radial, mode: 'intersect' })).toContain('mode');
    });

    it('updates a gradient by tool id with any subset of fields', () => {
      expect(validateToolArgs('update_gradient_mask', { photo_ids: [1], tool_id: 'T1', feather: 5 })).toBeNull();
      expect(
        validateToolArgs('update_gradient_mask', {
          photo_ids: [1],
          tool_id: 'T1',
          end: { x: 0.1, y: 0.9 },
          feather: 5,
        }),
      ).toBeNull();
      expect(
        validateToolArgs('update_gradient_mask', { photo_ids: [1], tool_id: 'T1', end: { x: 0.1, y: 0.9 } }),
      ).toBeNull();
      expect(validateToolArgs('update_gradient_mask', { photo_ids: [1], feather: 5 })).toContain('tool_id');
      expect(validateToolArgs('update_gradient_mask', { photo_ids: [1], tool_id: 'T1', feather: 500 })).toContain(
        'feather',
      );
      expect(validateToolArgs('update_gradient_mask', { photo_ids: [1], tool_id: 'T1', shape: 'radial' })).toContain(
        'unknown property "shape"',
      );
    });
  });

  describe('create_mask people and landscape', () => {
    it.each([
      [{ photo_ids: [1], type: 'sky', parts: ['hair'] }, 'parts'],
      [{ photo_ids: [1], type: 'subject', categories: ['sky'] }, 'categories'],
      [{ photo_ids: [1], type: 'background', parts: [] }, 'parts'],
      [{ photo_ids: [1], type: 'people', parts: ['hair'], categories: ['sky'] }, 'categories'],
      [{ photo_ids: [1], type: 'landscape', categories: ['sky'], parts: ['hair'] }, 'parts'],
      [{ photo_ids: [1], type: 'people', parts: ['hair'], adjustments: {} }, 'adjustments'],
      [{ photo_ids: [1], type: 'landscape', categories: ['sky'], adjustments: { local_Exposure: 1 } }, 'adjustments'],
    ])('rejects mismatched fields in %j', (args, field) => {
      expect(validateToolArgs('create_mask', args)).toContain(field);
    });
    it('accepts known parts for all people', () => {
      expect(
        validateToolArgs('create_mask', { type: 'people', photo_ids: [1], parts: ['hair', 'face_skin'] }),
      ).toBeNull();
      expect(validateToolArgs('create_mask', { type: 'people', photo_ids: [1], parts: ['entire_person'] })).toBeNull();
    });

    it('rejects unknown, duplicate or missing people parts and a person option', () => {
      expect(validateToolArgs('create_mask', { type: 'people', photo_ids: [1], parts: ['ears'] })).toContain('parts');
      expect(validateToolArgs('create_mask', { type: 'people', photo_ids: [1], parts: ['hair', 'hair'] })).toContain(
        'parts',
      );
      expect(validateToolArgs('create_mask', { type: 'people', photo_ids: [1], parts: [] })).toContain('parts');
      expect(validateToolArgs('create_mask', { type: 'people', parts: ['hair'] })).toContain('photo_ids');
      expect(validateToolArgs('create_mask', { type: 'people', photo_ids: [1], parts: ['hair'], person: 2 })).toContain(
        'unknown property "person"',
      );
    });

    it('accepts known landscape categories and rejects the rest', () => {
      expect(
        validateToolArgs('create_mask', { type: 'landscape', photo_ids: ['/a.dng'], categories: ['water', 'sky'] }),
      ).toBeNull();
      expect(validateToolArgs('create_mask', { type: 'landscape', photo_ids: [1], categories: ['lava'] })).toContain(
        'categories',
      );
      expect(
        validateToolArgs('create_mask', { type: 'landscape', photo_ids: [1], categories: ['sky', 'sky'] }),
      ).toContain('categories');
      expect(validateToolArgs('create_mask', { type: 'landscape', photo_ids: [1] })).toContain('categories');
      expect(validateToolArgs('create_mask', { type: 'landscape', photo_ids: [1], categories: [] })).toContain(
        'categories',
      );
      expect(
        validateToolArgs('create_mask', { type: 'landscape', photo_ids: [1], categories: ['sky'], extra: 1 }),
      ).toContain('unknown property "extra"');
    });
  });

  describe('brush mask tools', () => {
    const stroke = {
      points: [
        { x: 0.2, y: 0.3 },
        { x: 0.4, y: 0.3 },
      ],
      radius: 0.05,
      flow: 0.5,
    };
    const create = { photo_ids: [1], strokes: [stroke] };

    it('accepts strokes with optional radius and flow', () => {
      expect(validateToolArgs('create_brush_mask', create)).toBeNull();
      expect(validateToolArgs('create_brush_mask', { ...create, name: 'Face' })).toBeNull();
      expect(validateToolArgs('create_brush_mask', { ...create, mask_id: 'abc' })).toBeNull();
      expect(
        validateToolArgs('create_brush_mask', { photo_ids: [1], strokes: [{ points: [{ x: 0, y: 1 }] }] }),
      ).toBeNull();
      expect(validateToolArgs('add_brush_strokes', { ...create, tool_id: 'T1' })).toBeNull();
    });

    it('rejects an empty stroke list, a stroke without points and a missing list', () => {
      expect(validateToolArgs('create_brush_mask', { photo_ids: [1], strokes: [] })).toContain('strokes');
      expect(validateToolArgs('create_brush_mask', { photo_ids: [1], strokes: [{ points: [] }] })).toContain('points');
      expect(validateToolArgs('create_brush_mask', { photo_ids: [1], strokes: [{}] })).toContain('points');
      expect(validateToolArgs('create_brush_mask', { photo_ids: [1] })).toContain('strokes');
      expect(validateToolArgs('add_brush_strokes', { photo_ids: [1], strokes: [stroke] })).toContain('tool_id');
    });

    it('rejects points outside the image', () => {
      expect(
        validateToolArgs('create_brush_mask', { photo_ids: [1], strokes: [{ points: [{ x: 1.2, y: 0.5 }] }] }),
      ).toContain('points');
      expect(
        validateToolArgs('add_brush_strokes', {
          photo_ids: [1],
          tool_id: 'T1',
          strokes: [{ points: [{ x: 0.5, y: -1 }] }],
        }),
      ).toContain('points');
    });

    it('bounds radius and flow', () => {
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, radius: 0 }] })).toContain(
        'radius',
      );
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, radius: 2 }] })).toContain(
        'radius',
      );
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, flow: 0 }] })).toContain('flow');
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, flow: 2 }] })).toContain('flow');
    });

    it('accepts feather, density and erase and bounds them', () => {
      const withExtra = (extra: object) => ({ ...create, strokes: [{ ...stroke, ...extra }] });
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: 0, density: 0.3 }))).toBeNull();
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: 100, density: 1 }))).toBeNull();
      expect(validateToolArgs('create_brush_mask', withExtra({ erase: true, feather: 20 }))).toBeNull();
      expect(
        validateToolArgs('add_brush_strokes', { ...create, tool_id: 'T1', strokes: [{ ...stroke, erase: true }] }),
      ).toBeNull();
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: -1 }))).toContain('feather');
      expect(validateToolArgs('create_brush_mask', withExtra({ feather: 101 }))).toContain('feather');
      expect(validateToolArgs('create_brush_mask', withExtra({ density: 0 }))).toContain('density');
      expect(validateToolArgs('create_brush_mask', withExtra({ density: 2 }))).toContain('density');
      expect(validateToolArgs('create_brush_mask', withExtra({ erase: 'yes' }))).toContain('erase');
    });

    it('has no size option and no whole-brush mode', () => {
      expect(validateToolArgs('create_brush_mask', { ...create, strokes: [{ ...stroke, size: 0.1 }] })).toContain(
        'unknown property "size"',
      );
      expect(validateToolArgs('create_brush_mask', { ...create, mode: 'subtract' })).toContain(
        'unknown property "mode"',
      );
    });
  });

  describe('create_range_mask', () => {
    const luminance = { photo_ids: [1], type: 'luminance', luminance: { min: 0.3, max: 0.6, falloff: 0.1 } };
    const sample = { x: 0.2, y: 0.8, l: 0.46, a: 0.5, b: 0.52 };
    const color = { photo_ids: ['/a.dng'], type: 'color', color: { sample, amount: 0.4 } };
    const depth = { photo_ids: [7], type: 'depth', depth: { min: 0, max: 0.1, falloff: 0.25 } };

    it('accepts luminance, color and depth ranges', () => {
      expect(validateToolArgs('create_range_mask', luminance)).toBeNull();
      expect(validateToolArgs('create_range_mask', color)).toBeNull();
      expect(validateToolArgs('create_range_mask', depth)).toBeNull();
      expect(
        validateToolArgs('create_range_mask', { ...luminance, mask_id: 'C1', mode: 'subtract', invert: true }),
      ).toBeNull();
      expect(validateToolArgs('create_range_mask', { ...color, name: 'Foliage' })).toBeNull();
    });

    it('requires a photo and a type, and rejects an unknown type', () => {
      expect(validateToolArgs('create_range_mask', { type: 'luminance' })).toContain('photo_ids');
      expect(validateToolArgs('create_range_mask', { photo_ids: [1] })).toContain('type');
      expect(validateToolArgs('create_range_mask', { ...luminance, type: 'hue' })).toContain('type');
    });

    it('accepts the whole 0..1 band for luminance and a depth band short of it', () => {
      expect(
        validateToolArgs('create_range_mask', { photo_ids: [1], type: 'luminance', luminance: { min: 0, max: 1 } }),
      ).toBeNull();
      expect(
        validateToolArgs('create_range_mask', { photo_ids: [1], type: 'depth', depth: { min: 0, max: 0.99 } }),
      ).toBeNull();
    });

    it.each(['luminance', 'depth'])('accepts a %s band of 0.01 once rounded to the stored six decimals', (type) => {
      for (const [min, max] of [
        [0.1, 0.11],
        [0.3, 0.31],
        [0.5, 0.51],
        [0.14, 0.15],
        [0, 0.01],
        [0.99, 1],
        [0.2, 0.21],
        [0.7, 0.71],
        [0.2000004, 0.2100004],
      ]) {
        expect(
          validateToolArgs('create_range_mask', { photo_ids: [1], type, [type]: { min, max, falloff: 0 } }),
        ).toBeNull();
      }
    });

    it('bounds the depth numbers and rejects unknown depth properties', () => {
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: -0.1, max: 0.5 } })).toContain(
        'depth.min',
      );
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: 0.1 } })).toContain('max');
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: 0.1, max: 0.5, falloff: 2 } })).toContain(
        'depth.falloff',
      );
      expect(validateToolArgs('create_range_mask', { ...depth, depth: { min: 0.1, max: 0.5, x: 0.5 } })).toContain(
        'unknown property "x"',
      );
    });

    it('accepts one sample point only', () => {
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: [sample, sample] } })).toContain(
        'color.sample',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { samples: [sample] } })).toContain(
        'unknown property "samples"',
      );
    });

    it('accepts copy_sample_from with only its ids required', () => {
      const copy = { photo_ids: [1], type: 'color', copy_sample_from: { mask_id: 'C1', tool_id: 'C1T1' } };
      expect(validateToolArgs('create_range_mask', copy)).toBeNull();
      expect(validateToolArgs('create_range_mask', { ...copy, color: { amount: 0.3 }, invert: true })).toBeNull();
      expect(
        validateToolArgs('create_range_mask', {
          ...copy,
          mask_id: 'C2',
          mode: 'subtract',
          copy_sample_from: { source_photo_id: '/b.dng', mask_id: 'C1', tool_id: 'C1T1' },
        }),
      ).toBeNull();
      expect(validateToolArgs('create_range_mask', { ...copy, copy_sample_from: { mask_id: 'C1' } })).toContain(
        'tool_id',
      );
      expect(validateToolArgs('create_range_mask', { ...copy, copy_sample_from: { tool_id: 'T' } })).toContain(
        'mask_id',
      );
      expect(
        validateToolArgs('create_range_mask', { ...copy, copy_sample_from: { mask_id: 'C1', tool_id: 'T', x: 1 } }),
      ).toContain('unknown property "x"');
      expect(validateToolArgs('create_range_mask', { ...copy, color: { amount: 0 } })).toContain('color.amount');
    });

    it('takes Lightroom l, a and b, not sRGB', () => {
      const { l: _l, a: _a, b: _b, ...position } = sample;
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: position } })).toContain("'l'");
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: { ...sample, red: 0.5 } } })).toContain(
        'unknown property "red"',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: { ...sample, a: 1.5 } } })).toContain(
        'color.sample.a',
      );
    });

    it('bounds the numbers', () => {
      expect(validateToolArgs('create_range_mask', { ...luminance, luminance: { min: -0.1, max: 0.5 } })).toContain(
        'luminance.min',
      );
      expect(validateToolArgs('create_range_mask', { ...luminance, luminance: { min: 0.1 } })).toContain('max');
      expect(
        validateToolArgs('create_range_mask', { ...luminance, luminance: { min: 0.1, max: 0.5, falloff: 2 } }),
      ).toContain('luminance.falloff');
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample: { ...sample, x: 1.5 } } })).toContain(
        'color.sample.x',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample, amount: 0 } })).toContain(
        'color.amount',
      );
      expect(validateToolArgs('create_range_mask', { ...color, color: { sample, amount: 1.1 } })).toContain(
        'color.amount',
      );
      expect(validateToolArgs('create_range_mask', { ...luminance, mode: 'intersect' })).toContain('mode');
    });

    it('rejects unknown properties', () => {
      expect(validateToolArgs('create_range_mask', { ...luminance, hue: {} })).toContain('unknown property "hue"');
      expect(
        validateToolArgs('create_range_mask', { ...luminance, luminance: { min: 0, max: 1, extra: 1 } }),
      ).toContain('unknown property "extra"');
    });
  });

  it('requires a destination or an export preset for export_photos', () => {
    expect(validateToolArgs('export_photos', { photo_ids: [1], destination: '/out' })).toBeNull();
    expect(validateToolArgs('export_photos', { photo_ids: [1], export_preset: 'BlueSky' })).toBeNull();
    expect(
      validateToolArgs('export_photos', { photo_ids: [1], destination: '/out', export_preset: 'BlueSky' }),
    ).toBeNull();
    expect(validateToolArgs('export_photos', { photo_ids: [1] })).toBe(
      'Invalid arguments for export_photos: give destination or export_preset',
    );
    expect(validateToolArgs('export_photos', { photo_ids: [1], export_preset_folder: 'User Presets' })).toContain(
      'give destination or export_preset',
    );
  });

  it('rejects a blank folder for list_export_presets', () => {
    expect(validateToolArgs('list_export_presets', {})).toBeNull();
    expect(validateToolArgs('list_export_presets', { folder: 'User Presets' })).toBeNull();
    expect(validateToolArgs('list_export_presets', { folder: '' })).toContain('folder');
    expect(validateToolArgs('list_export_presets', { folder: '   ' })).toContain('folder');
  });

  it('requires exactly one deletion target for delete_masks', () => {
    expect(validateToolArgs('delete_masks', { photo_ids: [914], mask_ids: ['m-1'] })).toBeNull();
    expect(validateToolArgs('delete_masks', { photo_ids: [914], tool_ids: ['t-1', 't-2'] })).toBeNull();
    expect(validateToolArgs('delete_masks', { photo_ids: ['/a.dng'], all: true })).toBeNull();
    expect(validateToolArgs('delete_masks', { photo_ids: [914] })).toContain('Invalid arguments for delete_masks');
    expect(validateToolArgs('delete_masks', { photo_ids: [914], mask_ids: ['m'], all: true })).toContain(
      'give exactly one of mask_ids, tool_ids or all',
    );
    expect(validateToolArgs('delete_masks', { photo_ids: [914], mask_ids: ['m'], tool_ids: ['t'] })).toContain(
      'give exactly one of mask_ids, tool_ids or all',
    );
    expect(validateToolArgs('delete_masks', { photo_id: 914, all: true })).toContain(
      'unknown property "photo_id": use photo_ids',
    );
    expect(validateToolArgs('delete_masks', { photo_ids: [914], all: false })).toContain('all');
    expect(validateToolArgs('delete_masks', { photo_ids: [914], mask_ids: [] })).toContain('mask_ids');
    expect(validateToolArgs('delete_masks', { photo_ids: [914], mask_ids: [7] })).toContain('mask_ids');
    expect(validateToolArgs('delete_masks', { mask_ids: ['m'] })).toContain('photo_ids');
    const tooMany = Array.from({ length: 101 }, (_, i) => `m-${i}`);
    expect(validateToolArgs('delete_masks', { photo_ids: [914], mask_ids: tooMany })).toContain('mask_ids');
  });

  it('uses only a photo list for delete_empty_masks', () => {
    expect(validateToolArgs('delete_empty_masks', { photo_ids: [914, '/a.dng'] })).toBeNull();
    expect(validateToolArgs('delete_empty_masks', {})).toContain('photo_ids');
    expect(validateToolArgs('delete_empty_masks', { photo_ids: 914 })).toContain('photo_ids');
    expect(validateToolArgs('delete_empty_masks', { photo_ids: [914], photo_id: 914 })).toContain(
      'unknown property "photo_id": use photo_ids',
    );
    expect(validateToolArgs('delete_empty_masks', { photo_ids: [914], all: true })).toContain('unknown property "all"');
    expect(validateToolArgs('delete_empty_masks', { photo_ids: [true] })).toContain('photo_ids');
  });

  it.each([
    ['set_rating_and_flag', { photo_ids: [1] }, 'give rating or flag'],
    ['set_ai_metadata', { photo_ids: [1] }, 'give score or reason'],
    ['create_smart_collection', { name: 'n' }, 'give at least one search filter'],
    ['create_smart_collection', { name: 'n', parent: 'Trips / 2026' }, 'give at least one search filter'],
    ['search_photos', { start_date: '2024-02-30' }, 'start_date and end_date must be real calendar dates'],
    [
      'create_smart_collection',
      { name: 'n', start_date: '2026-02-01', end_date: '2026-02-30' },
      'start_date and end_date must be real calendar dates',
    ],
    ['search_photos', { start_date: '2024-06-03', end_date: '2024-06-02' }, 'start_date must be on or before end_date'],
    [
      'create_smart_collection',
      { name: 'n', start_date: '2024-06-03', end_date: '2024-06-02' },
      'start_date must be on or before end_date',
    ],
    ['rename_keyword', { keyword: 'zebra', new_name: 'Places|Paris' }, 'new_name'],
    ['rename_keyword', { keyword: 'zebra', new_name: ' ' }, 'new_name'],
    ['rename_keyword', { keyword: ' ', new_name: 'x' }, 'keyword'],
    ['delete_collection', { collection_name: '' }, 'collection_name'],
    ['get_collection_photos', { collection_name: '' }, 'collection_name'],
    ['import_photos', { source_path: '/Photos', collection_name: '' }, 'collection_name'],
    ['get_develop_preset', {}, 'give preset_uuid or preset_name'],
    ['apply_auto_adjustments', { photo_ids: [1] }, 'tone or white_balance must be true'],
    ['apply_auto_adjustments', { photo_ids: [1], tone: false }, 'tone or white_balance must be true'],
    [
      'apply_auto_adjustments',
      { photo_ids: [1], tone: false, white_balance: false },
      'tone or white_balance must be true',
    ],
    ['create_mask', { photo_ids: [1], type: 'subject', parts: ['hair'] }, 'parts requires type people'],
    ['create_mask', { photo_ids: [1], type: 'people' }, 'type people requires parts'],
    [
      'create_mask',
      { photo_ids: [1], type: 'landscape', categories: ['sky'], adjustments: { local_Exposure: 1 } },
      'adjustments is not supported for people or landscape',
    ],
    [
      'get_photo_preview',
      { photo_ids: [1], region: { x: 0.6, y: 0, width: 0.5, height: 0.5 } },
      'region must fit within the rendered frame',
    ],
  ])('%s refuses a call that breaks its rule', (name, args, text) => {
    expect(validateToolArgs(name, args)).toContain(text);
  });

  it('requires photo, mask and a known numeric slider for set_mask_adjustments', () => {
    const ok = { photo_ids: [914], mask_id: 'm-1', adjustments: { local_Exposure: 0.5, local_Shadows: -20 } };

    expect(validateToolArgs('set_mask_adjustments', ok)).toBeNull();
    expect(validateToolArgs('set_mask_adjustments', { ...ok, photo_ids: ['/a.dng'] })).toBeNull();
    expect(validateToolArgs('set_mask_adjustments', { ...ok, mask_id: undefined })).toContain('mask_id');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, mask_id: '' })).toContain('mask_id');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: undefined })).toContain('adjustments');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: {} })).toContain('adjustments');
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: { local_Bogus: 1 } })).toContain(
      'unknown property "local_Bogus"',
    );
    expect(validateToolArgs('set_mask_adjustments', { ...ok, adjustments: { local_Exposure: '1' } })).toContain(
      'adjustments.local_Exposure',
    );
    expect(validateToolArgs('set_mask_adjustments', { ...ok, extra: 1 })).toContain('unknown property "extra"');
  });

  it('requires photo and mask for get_mask', () => {
    expect(validateToolArgs('get_mask', { photo_ids: [914], mask_id: 'm-1' })).toBeNull();
    expect(validateToolArgs('get_mask', { photo_ids: [914] })).toContain('mask_id');
    expect(validateToolArgs('get_mask', { mask_id: 'm-1' })).toContain('photo_ids');
    expect(validateToolArgs('get_mask', { photo_ids: [914], mask_id: 7 })).toContain('mask_id');
    const base = { photo_ids: [914], mask_id: 'm-1' };
    expect(validateToolArgs('get_mask', { ...base, kinds: ['curves'] })).toBeNull();
    expect(validateToolArgs('get_mask', { ...base, kinds: ['adjustments', 'point_colors'] })).toBeNull();
    for (const kinds of [[], ['curves', 'curves'], ['unknown'], 'curves', [1]]) {
      expect(validateToolArgs('get_mask', { ...base, kinds })).toContain('kinds');
    }
    expect(validateToolArgs('get_mask', { ...base, extra: 1 })).toContain('unknown property "extra"');
  });

  it('requires a photo, a mask id and a mode for invert_mask', () => {
    const valid = { photo_ids: [914], mask_id: 'abc', mode: 'in_place' };
    expect(validateToolArgs('invert_mask', valid)).toBeNull();
    expect(validateToolArgs('invert_mask', { ...valid, mode: 'copy' })).toBeNull();
    expect(validateToolArgs('invert_mask', { photo_ids: [914], mode: 'copy' })).toContain('mask_id');
    expect(validateToolArgs('invert_mask', { photo_ids: [914], mask_id: 'abc' })).toContain('mode');
    expect(validateToolArgs('invert_mask', { ...valid, mode: 'toggle' })).toContain('mode');
    expect(validateToolArgs('invert_mask', { ...valid, mask_id: '' })).toContain('mask_id');
    expect(validateToolArgs('invert_mask', { ...valid, extra: 1 })).toContain('unknown property "extra"');
  });

  it('validates create_mask type and adjustment ranges', () => {
    expect(validateToolArgs('create_mask', { photo_ids: [914], type: 'sky' })).toBeNull();
    expect(validateToolArgs('create_mask', { photo_ids: ['/a.dng'], type: 'subject', adjustments: {} })).toContain(
      'adjustments',
    );
    expect(
      validateToolArgs('create_mask', {
        photo_ids: [914],
        type: 'background',
        adjustments: { local_Exposure: -4, local_LuminanceNoise: 100, local_Temperature: -100, local_Tint: 12.5 },
      }),
    ).toBeNull();
    expect(validateToolArgs('create_mask', { photo_ids: [914] })).toContain('type');
    expect(validateToolArgs('create_mask', { type: 'sky' })).toContain('photo_ids');
    expect(validateToolArgs('create_mask', { photo_ids: [914, 915], type: 'sky' })).toContain('photo_ids');
    expect(
      validateToolArgs('create_mask', {
        photo_ids: [914],
        type: 'sky',
        adjustments: { local_Exposure: 4.1 },
      }),
    ).toContain('adjustments.local_Exposure');
    expect(
      validateToolArgs('create_mask', {
        photo_ids: [914],
        type: 'sky',
        adjustments: { local_Contrast: -101 },
      }),
    ).toContain('adjustments.local_Contrast');
    expect(
      validateToolArgs('create_mask', {
        photo_ids: [914],
        type: 'sky',
        adjustments: { local_Exposure: '1' },
      }),
    ).toContain('adjustments.local_Exposure');
    expect(
      validateToolArgs('create_mask', {
        photo_ids: [914],
        type: 'sky',
        adjustments: { vibrance: 1 },
      }),
    ).toContain('unknown property "vibrance"');
  });

  it('validates create_mask_batch photo ids, type and adjustment ranges', () => {
    expect(validateToolArgs('create_mask_batch', { photo_ids: [914, '/a.dng'], type: 'sky' })).toBeNull();
    expect(
      validateToolArgs('create_mask_batch', {
        photo_ids: [914],
        type: 'subject',
        adjustments: { local_Exposure: 0.7, local_LuminanceNoise: -100 },
      }),
    ).toBeNull();
    expect(validateToolArgs('create_mask_batch', { type: 'sky' })).toContain('photo_ids');
    expect(validateToolArgs('create_mask_batch', { photo_ids: [914] })).toContain('type');
    expect(validateToolArgs('create_mask_batch', { photo_ids: [], type: 'sky' })).toContain('photo_ids');
    expect(
      validateToolArgs('create_mask_batch', {
        photo_ids: Array.from({ length: 201 }, (_, index) => index + 1),
        type: 'sky',
      }),
    ).toContain('photo_ids');
    expect(
      validateToolArgs('create_mask_batch', {
        photo_ids: Array.from({ length: 200 }, (_, index) => index + 1),
        type: 'sky',
      }),
    ).toBeNull();
    expect(validateToolArgs('create_mask_batch', { photo_ids: [914], type: 'people' })).toContain('type');
    expect(validateToolArgs('create_mask_batch', { photo_ids: 914, type: 'sky' })).toContain('photo_ids');
    expect(
      validateToolArgs('create_mask_batch', {
        photo_ids: [914],
        type: 'sky',
        adjustments: { local_Exposure: 4.1 },
      }),
    ).toContain('adjustments.local_Exposure');
    expect(
      validateToolArgs('create_mask_batch', {
        photo_ids: [914],
        type: 'sky',
        adjustments: { vibrance: 1 },
      }),
    ).toContain('unknown property "vibrance"');
    expect(
      validateToolArgs('create_mask_batch', {
        photo_ids: [914],
        photo_id: 914,
        type: 'sky',
      }),
    ).toContain('unknown property "photo_id": use photo_ids');
  });

  it('validates set_mask_curves channels and point arrays', () => {
    const base = { photo_ids: [914], mask_id: 'm-1' };
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0, 64, 48, 255, 255] } })).toBeNull();
    expect(
      validateToolArgs('set_mask_curves', {
        ...base,
        curves: { red: [0, 0, 255, 255], blue: [0, 10, 255, 255] },
      }),
    ).toBeNull();
    expect(validateToolArgs('set_mask_curves', base)).toContain('curves');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: {} })).toContain('curves');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { alpha: [0, 0, 255, 255] } })).toContain(
      'unknown property "alpha"',
    );
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0] } })).toContain('curves.main');
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0, 256, 255] } })).toContain(
      'curves.main',
    );
    expect(validateToolArgs('set_mask_curves', { ...base, curves: { main: [0, 0, 12.5, 255] } })).toContain(
      'curves.main',
    );
    expect(validateToolArgs('set_mask_curves', { photo_ids: [914], curves: { main: [0, 0, 255, 255] } })).toContain(
      'mask_id',
    );
  });

  it.each([
    ['an odd count', [0, 0, 100, 255, 255], 'curves.green'],
    [
      'inputs not increasing',
      [0, 0, 128, 140, 96, 90, 255, 255],
      'each curve must start at input 0, end at input 255 and have strictly increasing inputs',
    ],
    ['a first input over 0', [10, 0, 255, 255], 'each curve must start at input 0'],
    ['a last input under 255', [0, 0, 250, 255], 'each curve must start at input 0'],
    [
      '17 points',
      Array.from({ length: 17 }, (_, index) => (index === 16 ? 255 : index * 15)).flatMap((input) => [input, input]),
      'curves.green',
    ],
  ])('refuses a set_mask_curves curve with %s before the plug-in sees it', (_case, points, problem) => {
    expect(
      validateToolArgs('set_mask_curves', { photo_ids: [914], mask_id: 'm-1', curves: { green: points } }),
    ).toContain(problem);
  });

  it('takes at most 16 points in a mask curve and in the global point curve', () => {
    const points = (count: number) =>
      Array.from({ length: count }, (_, index) => {
        const input = index === count - 1 ? 255 : index * Math.floor(255 / (count - 1));
        return [input, input];
      }).flat();
    expect(
      validateToolArgs('set_mask_curves', { photo_ids: [914], mask_id: 'm-1', curves: { main: points(16) } }),
    ).toBeNull();
    expect(
      validateToolArgs('set_mask_curves', { photo_ids: [914], mask_id: 'm-1', curves: { main: points(17) } }),
    ).toContain('curves.main');
    expect(
      validateToolArgs('set_develop_settings', { photo_ids: [914], settings: { ToneCurvePV2012: points(16) } }),
    ).toBeNull();
    expect(
      validateToolArgs('set_develop_settings', { photo_ids: [914], settings: { ToneCurvePV2012: points(17) } }),
    ).toContain('ToneCurvePV2012');
  });

  it('takes a swatch Variance from -1 to 1', () => {
    const update = (swatch: Record<string, number>) =>
      validateToolArgs('edit_mask_point_colors', {
        photo_ids: [914],
        mask_id: 'm-1',
        action: 'update',
        index: 1,
        swatch,
      });
    expect(update({ Variance: 0.3 })).toBeNull();
    expect(update({ Variance: -1 })).toBeNull();
    expect(update({ Variance: 1.5 })).toContain('swatch.Variance');
  });

  it.each([
    [
      'add without a source field',
      { action: 'add', swatch: { SrcHue: 1, SrcSat: 0.4 } },
      'add needs a swatch with SrcHue, SrcSat and SrcLum and no index',
    ],
    [
      'add with an index',
      { action: 'add', index: 1, swatch: { SrcHue: 1, SrcSat: 0.4, SrcLum: 0.5 } },
      'add needs a swatch with SrcHue, SrcSat and SrcLum and no index',
    ],
    ['update without an index', { action: 'update', swatch: { SatScale: 0.3 } }, 'update needs index and swatch'],
    ['update without a swatch', { action: 'update', index: 1 }, 'update needs index and swatch'],
    ['delete without an index', { action: 'delete' }, 'delete needs index and no swatch'],
    [
      'delete with a swatch',
      { action: 'delete', index: 1, swatch: { SatScale: 0.3 } },
      'delete needs index and no swatch',
    ],
    ['clear with an index', { action: 'clear', index: 1 }, 'clear takes no index or swatch'],
    [
      'a range missing an edge',
      { action: 'update', index: 1, swatch: { HueRange: { LowerNone: 0, LowerFull: 0.2, UpperFull: 0.6 } } },
      'UpperNone',
    ],
    [
      'update with unordered hue edges',
      {
        action: 'update',
        index: 1,
        swatch: { HueRange: { LowerNone: 0.6, LowerFull: 0.2, UpperFull: 0.9, UpperNone: 0.4 } },
      },
      'each swatch range orders LowerNone <= LowerFull <= UpperFull <= UpperNone (Lightroom drops every swatch of the mask otherwise)',
    ],
    [
      'update with only the inner edges crossed',
      {
        action: 'update',
        index: 1,
        swatch: { LumRange: { LowerNone: 0, LowerFull: 0.7, UpperFull: 0.5, UpperNone: 1 } },
      },
      'each swatch range orders LowerNone <= LowerFull <= UpperFull <= UpperNone (Lightroom drops every swatch of the mask otherwise)',
    ],
    [
      'update with an inner edge past the outer one',
      {
        action: 'update',
        index: 1,
        swatch: { LumRange: { LowerNone: 0, LowerFull: 0.5, UpperFull: 0.9, UpperNone: 0.8 } },
      },
      'each swatch range orders LowerNone <= LowerFull <= UpperFull <= UpperNone (Lightroom drops every swatch of the mask otherwise)',
    ],
    [
      'add with unordered saturation edges',
      {
        action: 'add',
        swatch: {
          SrcHue: 1,
          SrcSat: 0.4,
          SrcLum: 0.5,
          SatRange: { LowerNone: 0.3, LowerFull: 0.2, UpperFull: 0.6, UpperNone: 1 },
        },
      },
      'each swatch range orders LowerNone <= LowerFull <= UpperFull <= UpperNone (Lightroom drops every swatch of the mask otherwise)',
    ],
  ])('refuses edit_mask_point_colors %s before the plug-in sees it', (_case, args, problem) => {
    expect(validateToolArgs('edit_mask_point_colors', { photo_ids: [914], mask_id: 'm-1', ...args })).toContain(
      problem,
    );
  });

  it('validates edit_mask_point_colors actions, indexes and swatch fields', () => {
    const base = { photo_ids: [914], mask_id: 'm-1' };
    const swatch = { SrcHue: 1.5, SrcSat: 0.4, SrcLum: 0.6, HueShift: -0.2 };
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'add', swatch })).toBeNull();
    expect(
      validateToolArgs('edit_mask_point_colors', {
        ...base,
        action: 'update',
        index: 2,
        swatch: { SatScale: 0.3, HueRange: { LowerNone: 0, LowerFull: 0.2, UpperFull: 0.6, UpperNone: 1 } },
      }),
    ).toBeNull();
    expect(
      validateToolArgs('edit_mask_point_colors', {
        ...base,
        action: 'update',
        index: 1,
        swatch: { SatRange: { LowerNone: 0.4, LowerFull: 0.4, UpperFull: 0.4, UpperNone: 0.4 } },
      }),
    ).toBeNull();
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 1 })).toBeNull();
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'clear' })).toBeNull();
    expect(validateToolArgs('edit_mask_point_colors', base)).toContain('action');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'rename' })).toContain('action');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 0 })).toContain('index');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 9 })).toContain('index');
    expect(validateToolArgs('edit_mask_point_colors', { ...base, action: 'delete', index: 1.5 })).toContain('index');
    expect(
      validateToolArgs('edit_mask_point_colors', {
        ...base,
        action: 'add',
        swatch: { ...swatch, SrcHue: 7 },
      }),
    ).toContain('swatch.SrcHue');
    expect(
      validateToolArgs('edit_mask_point_colors', {
        ...base,
        action: 'add',
        swatch: { ...swatch, Brightness: 1 },
      }),
    ).toContain('unknown property "Brightness"');
    expect(
      validateToolArgs('edit_mask_point_colors', {
        ...base,
        action: 'update',
        index: 1,
        swatch: { HueRange: { LowerNone: 0 } },
      }),
    ).toContain('swatch.HueRange');
  });

  it('validates combine_mask operation and type', () => {
    const valid = { photo_ids: [914], mask_id: 'abc', operation: 'subtract', type: 'sky' };
    expect(validateToolArgs('combine_mask', valid)).toBeNull();
    expect(
      validateToolArgs('combine_mask', { ...valid, photo_ids: ['/a.dng'], operation: 'add', type: 'background' }),
    ).toBeNull();
    expect(validateToolArgs('combine_mask', { ...valid, operation: 'intersect', type: 'subject' })).toBeNull();
    expect(validateToolArgs('combine_mask', { ...valid, operation: 'invert' })).toContain('operation');
    expect(validateToolArgs('combine_mask', { ...valid, type: 'people' })).toContain('type');
    expect(validateToolArgs('combine_mask', { ...valid, mask_id: '' })).toContain('mask_id');
    expect(validateToolArgs('combine_mask', { photo_ids: [914], operation: 'add', type: 'sky' })).toContain('mask_id');
    expect(validateToolArgs('combine_mask', { photo_ids: [914], mask_id: 'abc', type: 'sky' })).toContain('operation');
    expect(validateToolArgs('combine_mask', { photo_ids: [914], mask_id: 'abc', operation: 'add' })).toContain('type');
    expect(validateToolArgs('combine_mask', { ...valid, adjustments: {} })).toContain('unknown property "adjustments"');
  });

  it('names a misspelled property instead of silently ignoring it', () => {
    const msg = validateToolArgs('search_photos', { not_a_real_filter: 1 });

    expect(msg).toContain('unknown property "not_a_real_filter"');
  });

  it('enforces documented ranges and types', () => {
    expect(validateToolArgs('search_photos', { limit: 'many' })).toContain('limit');
    expect(
      validateToolArgs('export_photos', {
        photo_ids: [914],
        destination: '/tmp',
        on_existing: 'ask',
      }),
    ).toContain('on_existing');
  });

  it('rejects a non-finite altitude that JSON would turn into null', () => {
    const base = { photo_ids: [914], latitude: 1, longitude: 1 };

    expect(validateToolArgs('set_gps', { ...base, altitude: Infinity })).toContain('altitude');
    expect(validateToolArgs('set_gps', { ...base, altitude: -Infinity })).toContain('altitude');
    expect(validateToolArgs('set_gps', { ...base, altitude: 8848 })).toBeNull();
    expect(validateToolArgs('set_gps', { ...base, clear_altitude: true })).toBeNull();
  });

  it('rejects a control character that would cut the .json path short', () => {
    expect(validateToolArgs('export_photo_metadata', { destination: '/u/.zshrc\u0000.json' })).toContain('destination');
    expect(validateToolArgs('export_photo_metadata', { destination: '/u/a\nb.json' })).toContain('destination');
    expect(validateToolArgs('export_photo_metadata', { destination: '/u/zdjęcia 東京.json' })).toBeNull();
  });

  it('set_rating_and_flag takes a rating from 0 to 5, a flag of pick, reject or none, or both', () => {
    const base = { photo_ids: [914] };

    for (const args of [
      { rating: 0 },
      { rating: 5 },
      { flag: 'pick' },
      { flag: 'reject' },
      { flag: 'none' },
      { rating: 3, flag: 'pick' },
    ]) {
      expect(validateToolArgs('set_rating_and_flag', { ...base, ...args })).toBeNull();
    }
    for (const [args, field] of [
      [{ rating: 6 }, 'rating'],
      [{ rating: -1 }, 'rating'],
      [{ rating: '3' }, 'rating'],
      [{ flag: 'rejected' }, 'flag'],
      [{ flag: -1 }, 'flag'],
      [{ flag: false }, 'flag'],
      [{ rating: 3, label: 'red' }, 'label'],
    ] as const) {
      expect(validateToolArgs('set_rating_and_flag', { ...base, ...args })).toContain(field);
    }
  });

  it('accepts IPTC location strings and rejects other types or unknown fields', () => {
    const base = { photo_ids: [914] };

    expect(validateToolArgs('set_location', { ...base, city: 'Kansas City', iso_country_code: 'US' })).toBeNull();
    expect(validateToolArgs('set_location', { ...base, sublocation: '' })).toBeNull();
    expect(validateToolArgs('set_location', { ...base, city: 42 })).toContain('city');
    expect(validateToolArgs('set_location', { ...base, state: 'Missouri' })).toContain('state');
  });

  it('set_metadata accepts text and rejects other types or unknown fields', () => {
    const base = { photo_ids: [914] };

    expect(validateToolArgs('set_metadata', { ...base, title: 'Dunluce Castle', caption: '' })).toBeNull();
    expect(
      validateToolArgs('set_metadata', { ...base, copyright_info_url: 'https://example.com', creator_url: '' }),
    ).toBeNull();
    expect(validateToolArgs('set_metadata', { ...base, copyright_status: 'copyrighted' })).toContain(
      'copyright_status',
    );
    expect(validateToolArgs('set_metadata', { ...base, title: 7 })).toContain('title');
    expect(validateToolArgs('set_metadata', { ...base, alt_text: 'A red barn', extended_description: '' })).toBeNull();
    expect(validateToolArgs('set_metadata', { ...base, alt_text: 5 })).toContain('alt_text');
    expect(validateToolArgs('set_metadata', { ...base, extended_description: false })).toContain(
      'extended_description',
    );
    expect(validateToolArgs('set_metadata', { ...base, artist: 'Jane' })).toContain('artist');
  });

  it('requires a non-empty keyword and new name to rename', () => {
    expect(validateToolArgs('rename_keyword', { keyword: 'Places|KC', new_name: 'Kansas City' })).toBeNull();
    expect(validateToolArgs('rename_keyword', { keyword: 'person' })).toContain("required property 'new_name'");
    expect(validateToolArgs('rename_keyword', { keyword: '', new_name: 'x' })).toContain('keyword');
  });

  it('requires a collection name to delete and nothing else', () => {
    expect(validateToolArgs('delete_collection', { collection_name: 'Temp' })).toBeNull();
    expect(validateToolArgs('delete_collection', {})).toContain("required property 'collection_name'");
    expect(validateToolArgs('delete_collection', { collection_name: 'Temp', photo_ids: [914] })).toContain('photo_ids');
  });

  it('requires a collection name to list its photos and pages with limit/offset', () => {
    expect(validateToolArgs('get_collection_photos', { collection_name: 'Trip', limit: 10, offset: 20 })).toBeNull();
    expect(validateToolArgs('get_collection_photos', {})).toContain("required property 'collection_name'");
    expect(validateToolArgs('get_collection_photos', { collection_name: 'Trip', offset: -1 })).toContain('offset');
  });

  it('reports a violation that has no field path', () => {
    const msg = validateToolArgs('search_photos', 'not-an-object');

    expect(msg).toContain('Invalid arguments for search_photos');
    expect(msg).toContain('object');
  });
});

describe('paging arguments', () => {
  const paged = TOOL_CONTRACTS.filter((contract) => 'limit' in ((contract.inputSchema.properties ?? {}) as object));

  it('cover the listing tools', () => {
    expect(paged.map((contract) => contract.name).sort()).toEqual([
      'get_collection_photos',
      'get_folder_photos',
      'get_selected_photos',
      'list_collections',
      'list_develop_presets',
      'list_folders',
      'list_keywords',
      'search_photos',
    ]);
  });

  const required: Record<string, object> = {
    get_folder_photos: { folder_path: '/Photos' },
    get_collection_photos: { collection_name: 'Picks' },
  };

  it.each(paged.map((contract) => contract.name))('%s takes whole, non-negative limit and offset', (name) => {
    const base = required[name] ?? {};
    expect(validateToolArgs(name, { ...base, limit: 10, offset: 20 })).toBeNull();
    for (const args of [{ limit: 1.5 }, { offset: 0.5 }, { limit: -1 }, { offset: -1 }]) {
      expect(validateToolArgs(name, { ...base, ...args })).toContain(Object.keys(args)[0]);
    }
  });
});

describe('export and keyword text rules', () => {
  it('export_photos takes export_preset_folder only beside export_preset', () => {
    expect(
      validateToolArgs('export_photos', { photo_ids: [1], destination: '/out', export_preset_folder: 'User Presets' }),
    ).toBe('Invalid arguments for export_photos: export_preset_folder needs export_preset');
    expect(
      validateToolArgs('export_photos', { photo_ids: [1], export_preset: 'Web', export_preset_folder: 'User Presets' }),
    ).toBeNull();
  });

  it.each(['', '  ', '/out\nput', '/out\u0007'])('export_photos refuses destination %j', (destination) => {
    expect(validateToolArgs('export_photos', { photo_ids: [1], destination })).toContain('destination');
  });

  it.each([
    ['parent', ' '],
    ['query', '\t'],
  ])('list_keywords refuses a blank %s', (field, value) => {
    expect(validateToolArgs('list_keywords', { [field]: value })).toContain(field);
  });
});

describe('argument rules the contract decides', () => {
  const sample = { x: 0.5, y: 0.5, l: 0.5, a: 0.5, b: 0.5 };
  const linear = { photo_ids: [1], shape: 'linear', start: { x: 0.5, y: 0.2 }, end: { x: 0.5, y: 0.6 } };
  const band = { min: 0.2, max: 0.6 };
  it.each<readonly [string, unknown, string]>([
    [
      'set_gps',
      { photo_ids: [1], latitude: 1, longitude: 2, altitude: 10, clear_altitude: true },
      'altitude cannot be combined with clear_altitude',
    ],
    ['set_location', { photo_ids: [1] }, 'give at least one of sublocation'],
    ['set_metadata', { photo_ids: [1] }, 'give at least one of title'],
    ['set_keywords', { photo_ids: [1] }, 'give add_keywords or remove_keywords'],
    ['remove_keyword_subtree', { catalog_wide: true }, "required property 'parent'"],
    ['remove_keyword_subtree', { parent: 'AI' }, 'give photo_ids or catalog_wide true, not both'],
    [
      'remove_keyword_subtree',
      { parent: 'AI', photo_ids: [1], catalog_wide: true },
      'give photo_ids or catalog_wide true, not both',
    ],
    ['create_collection', { name: '  ' }, 'name'],
    ['apply_develop_preset', { photo_ids: [1], preset_name: '' }, 'preset_name'],
    ['set_lens_blur', { photo_ids: [1], focal_range: { near: 60, far: 40 } }, 'focal_range needs near <= far'],
    ['create_gradient_mask', { ...linear, mode: 'subtract' }, 'mode "subtract" needs mask_id'],
    [
      'create_range_mask',
      { photo_ids: [1], type: 'color', color: { sample }, mode: 'subtract' },
      'mode "subtract" needs mask_id',
    ],
    ['create_gradient_mask', { ...linear, mask_id: 'm', name: 'Sky' }, 'name applies to a new mask'],
    [
      'create_gradient_mask',
      { photo_ids: [1], shape: 'linear', start: { x: 0.5, y: 0.2 } },
      'shape "linear" needs start and end',
    ],
    [
      'create_gradient_mask',
      { photo_ids: [1], shape: 'linear', end: { x: 0.5, y: 0.2 } },
      'shape "linear" needs start and end',
    ],
    ...[
      { width: 0.4, height: 0.6 },
      { center: { x: 0.5, y: 0.5 }, height: 0.6 },
      { center: { x: 0.5, y: 0.5 }, width: 0.4 },
    ].map(
      (fields) =>
        [
          'create_gradient_mask',
          { photo_ids: [1], shape: 'radial', ...fields },
          'shape "radial" needs center, width and height',
        ] as const,
    ),
    ...[{ feather: 10 }, { area: 'outside' }, { center: { x: 0.5, y: 0.5 } }].map(
      (field) =>
        [
          'create_gradient_mask',
          { ...linear, ...field },
          'start and end apply only to shape "linear"; center, width, height, rotation, feather and area only to shape "radial"',
        ] as const,
    ),
    [
      'create_gradient_mask',
      { photo_ids: [1], shape: 'radial', center: { x: 0.5, y: 0.5 }, width: 0.4, height: 0.6, start: { x: 0, y: 0 } },
      'start and end apply only to shape "linear"',
    ],
    [
      'create_range_mask',
      { photo_ids: [1], type: 'color', color: { sample }, mask_id: 'm', name: 'Sky' },
      'name applies to a new mask',
    ],
    ...[
      { type: 'luminance', luminance: band, color: { amount: 0.3 } },
      { type: 'luminance', luminance: band, depth: band },
      { type: 'depth', depth: band, luminance: band },
      { type: 'color', color: { sample }, luminance: band },
    ].map(
      (args) =>
        [
          'create_range_mask',
          { photo_ids: [1], ...args },
          'luminance, color and depth each apply only to the type of the same name',
        ] as const,
    ),
    ...[{ type: 'luminance' }, { type: 'depth' }, { type: 'color' }, { type: 'color', color: { amount: 0.3 } }].map(
      (args) =>
        [
          'create_range_mask',
          { photo_ids: [1], ...args },
          'type "luminance" needs luminance, type "depth" needs depth, and type "color" needs color.sample or copy_sample_from',
        ] as const,
    ),
    ...[
      { type: 'luminance', luminance: band },
      { type: 'depth', depth: band },
    ].map(
      (args) =>
        [
          'create_range_mask',
          { photo_ids: [1], ...args, copy_sample_from: { mask_id: 'C1', tool_id: 'C1T1' } },
          'copy_sample_from applies only to type "color"',
        ] as const,
    ),
    [
      'create_range_mask',
      { photo_ids: [1], type: 'color', color: { sample }, copy_sample_from: { mask_id: 'C1', tool_id: 'C1T1' } },
      'color.sample and copy_sample_from both give the sample; give one of them',
    ],
    ...['luminance', 'depth'].flatMap((type) =>
      [
        { min: 0.6, max: 0.4 },
        { min: 0.5, max: 0.505 },
        { min: 0.2000005, max: 0.2100004 },
      ].map(
        (values) =>
          [
            'create_range_mask',
            { photo_ids: [1], type, [type]: values },
            `${type}.max must be at least 0.01 above ${type}.min: Lightroom replaces a narrower band with its default`,
          ] as const,
      ),
    ),
    [
      'create_range_mask',
      { photo_ids: [1], type: 'depth', depth: { min: 0, max: 1, falloff: 0.3 } },
      'depth min 0 with max 1 covers the whole scene',
    ],
    [
      'create_brush_mask',
      {
        photo_ids: [1],
        strokes: [{ points: [{ x: 0.1, y: 0.1 }] }, { points: [{ x: 0.2, y: 0.2 }], erase: true, density: 0.5 }],
      },
      'density does not apply to an erase stroke: erasing removes the paint it covers',
    ],
    [
      'add_brush_strokes',
      { photo_ids: [1], tool_id: 'T1', strokes: [{ points: [{ x: 0.2, y: 0.2 }], erase: true, density: 1 }] },
      'density does not apply to an erase stroke',
    ],
    [
      'create_brush_mask',
      { photo_ids: [1], strokes: [{ points: [{ x: 0.1, y: 0.1 }] }], mask_id: 'm', name: 'Sky' },
      'name applies to a new mask',
    ],
    [
      'update_gradient_mask',
      { photo_ids: [1], tool_id: 'T1' },
      'give at least one of start, end, center, width, height, rotation, feather, area',
    ],
    ['set_crop', { photo_ids: [1] }, 'give either rectangle or aspect'],
    [
      'set_crop',
      { photo_ids: [1], rectangle: { left: 0, top: 0, right: 1, bottom: 1 }, aspect: { width: 1, height: 1 } },
      'give either rectangle or aspect',
    ],
    [
      'set_crop',
      { photo_ids: [1], rectangle: { left: 0, top: 0, right: 1, bottom: 1 }, scale: 0.5 },
      'center and scale apply to aspect, not to rectangle',
    ],
    [
      'set_crop',
      { photo_ids: [1], rectangle: { left: 0, top: 0, right: 1, bottom: 1 }, center: { x: 0.5, y: 0.5 } },
      'center and scale apply to aspect, not to rectangle',
    ],
    [
      'set_crop',
      { photo_ids: [1], rectangle: { left: 0.6, top: 0, right: 0.4, bottom: 1 } },
      'rectangle left must be less than right',
    ],
    [
      'set_crop',
      { photo_ids: [1], rectangle: { left: 0, top: 0.6, right: 1, bottom: 0.4 } },
      'rectangle top must be less than bottom',
    ],
  ])('refuses %s %j before anything is sent', (name, args, problem) => {
    expect(validateToolArgs(name, args)).toContain(problem);
  });
});

describe('develop preset selectors', () => {
  const selectorCases: { name: string; valid: Record<string, unknown>[]; invalid: Record<string, unknown>[] }[] = [
    ...['get_develop_preset', 'export_develop_preset', 'apply_develop_preset'].map((name) => {
      const common =
        name === 'apply_develop_preset'
          ? { photo_ids: [914] }
          : name === 'export_develop_preset'
            ? { destination_dir: '/tmp/presets' }
            : {};
      return {
        name,
        valid: [
          { ...common, preset_uuid: 'uuid' },
          { ...common, preset_name: 'name' },
          { ...common, preset_uuid: 'uuid', preset_name: 'name', preset_scope: 'plugin' },
        ],
        invalid: [common, { ...common, preset_uuid: 123 }, { ...common, preset_name: 'name', preset_scope: 'unknown' }],
      };
    }),
  ];

  it.each(selectorCases)('accepts and refuses the selector combinations of $name', ({ name, valid, invalid }) => {
    for (const args of valid) expect(validateToolArgs(name, args)).toBeNull();
    for (const args of [...invalid, ...valid.map((args) => ({ ...args, unknown_field: true }))]) {
      expect(validateToolArgs(name, args)).toContain(`Invalid arguments for ${name}`);
    }
  });
});

describe('get_develop_settings', () => {
  it("reads several photos only by named keys and lists one photo's keys without them", () => {
    expect(validateToolArgs('get_develop_settings', { photo_ids: [914] })).toBeNull();
    expect(validateToolArgs('get_develop_settings', { photo_ids: [914, '/a.cr2'], keys: ['Exposure2012'] })).toBeNull();
    expect(validateToolArgs('get_develop_settings', { photo_ids: [914, 915] })).toBe(
      'Invalid arguments for get_develop_settings: keys is required when photo_ids names more than one photo',
    );
    expect(
      validateToolArgs('get_develop_settings', {
        photo_ids: Array.from({ length: 101 }, (_, i) => i + 1),
        keys: ['A'],
      }),
    ).toContain('photo_ids');
    expect(validateToolArgs('get_develop_settings', { photo_id: 914 })).toContain(
      'unknown property "photo_id": use photo_ids',
    );
  });
});
