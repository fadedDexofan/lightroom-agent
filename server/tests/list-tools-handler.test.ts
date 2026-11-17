import { describe, it, expect } from '@jest/globals';
import { Ajv } from 'ajv';
import fs from 'node:fs';
import path from 'node:path';
import { validateToolArgs } from './helpers/validate.js';
import { TOOL_DEFINITIONS, listToolsHandler } from '../src/list-tools-handler.js';
import { manifestTools } from '../src/manifest-tools.js';
import { PLUGIN_ACTIONS, TOOL_CONTRACTS } from '../src/tool-contracts.js';
import {
  MASK_CURVE_CHANNEL_NAMES,
  MASK_TYPE_NAMES,
} from '../src/lightroom-tables.js';
import { DEVELOP_KEYS, LOCAL_KEYS, developKeyNamesSchema, developSettingsSchema, localAdjustmentsSchema, type DevelopKey } from '../src/develop-keys.js';

describe('TOOL_DEFINITIONS', () => {
  it('get_photo_preview describes named sizes, the returned edge and how token cost grows', () => {
    const tool = TOOL_DEFINITIONS.find(tool => tool.name === 'get_photo_preview');
    const sizeSchema = tool?.inputSchema.properties?.size as { description: string };
    const guidance = `${tool?.description} ${sizeSchema.description}`;
    expect(guidance).toMatch(/cull is 864.*review 1728.*default cull/);
    expect(guidance).toMatch(/cull is for choosing among frames, review for a whole-frame look/);
    expect(guidance).toContain('Judge critical sharpness with get_photo_detail, not with a preview');
    expect(guidance).toContain('width x height / 750');
    expect(guidance).toContain('width/height/bytes are actual');
    expect(guidance).toContain('scaled_by_server');
    expect(guidance).toContain('each turn in history');
  });

  it('tool names are unique', () => {
    const names = TOOL_DEFINITIONS.map((t) => t.name);
    expect(new Set(names).size).toBe(names.length);
  });


  it('rejects unknown top-level arguments for every tool', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(tool.inputSchema.additionalProperties).toBe(false);
    }
  });
});

describe('published schema', () => {
  it('is the schema the server enforces, with no root combinator', () => {
    for (const [index, contract] of TOOL_CONTRACTS.entries()) {
      const published = TOOL_DEFINITIONS.find((tool) => tool.name === contract.name)!.inputSchema;
      expect(published).toBe(contract.inputSchema);
      for (const keyword of ['oneOf', 'anyOf', 'allOf']) expect(published).not.toHaveProperty(keyword);
      expect(TOOL_DEFINITIONS[index].name).toBe(contract.name);
    }
  });

  it('states every argument rule in the published description', () => {
    const withRules = TOOL_CONTRACTS.filter((contract) => contract.rules?.length);
    expect(withRules.map((contract) => contract.name)).toEqual(expect.arrayContaining([
      'set_rating_and_flag', 'set_ai_metadata', 'create_smart_collection', 'export_photos',
      'get_develop_preset', 'export_develop_preset', 'apply_develop_preset', 'apply_auto_adjustments',
      'create_gradient_mask', 'create_brush_mask', 'create_range_mask', 'create_mask',
      'get_photo_preview', 'delete_masks',
    ]));
    for (const contract of withRules) {
      const description = TOOL_DEFINITIONS.find((tool) => tool.name === contract.name)!.description;
      for (const rule of contract.rules!) expect(description).toContain(rule.text);
    }
  });

  it('keeps nested selector unions inside compare_develop_presets', () => {
    const validate = new Ajv({ strict: false }).compile(
      TOOL_DEFINITIONS.find(tool => tool.name === 'compare_develop_presets')!.inputSchema);
    expect(validate({ base: {}, candidate: { preset_uuid: 'uuid' } })).toBe(false);
    expect(validate({ base: { preset_name: 'base' }, candidate: { preset_uuid: 'uuid' } })).toBe(true);
  });
});

describe('listToolsHandler', () => {
  it('returns { tools: TOOL_DEFINITIONS }', () => {
    const result = listToolsHandler(new Set(['core', 'develop', 'masks']), false);
    expect(result.tools).toEqual(TOOL_DEFINITIONS);
  });

  it.each(TOOL_DEFINITIONS.filter((tool) => tool._meta?.['anthropic/alwaysLoad'] === true).map((tool) => [tool.name, tool.description] as const))(
    'upfront tool %s stays within the 4096-character description limit', (_name, description) => {
      expect(description).toBeDefined();
      expect(description!.length).toBeLessThanOrEqual(4096);
    },
  );
});

describe('photo list schemas', () => {
  it.each([
    ['search_photos', {}],
    ['get_selected_photos', {}],
    ['get_collection_photos', { collection_name: 'Trips / 2026 / Paris' }],
  ])('%s accepts an optional path opt-in and rejects unknown arguments', (name, args) => {
    const tool = TOOL_DEFINITIONS.find((entry) => entry.name === name)!;
    const validate = new Ajv({ strict: false }).compile(tool.inputSchema);

    expect(validate(args)).toBe(true);
    expect(validate({ ...args, include_path: true })).toBe(true);
    expect(validate({ ...args, include_path: false })).toBe(true);
    expect(validate({ ...args, include_path: 'true' })).toBe(false);
    expect(validate({ ...args, include_path: 1 })).toBe(false);
    expect(validate({ ...args, unknown_field: true })).toBe(false);
  });
});

describe('develop setting schema', () => {
  const sample = (key: DevelopKey): unknown => {
    switch (key.kind) {
      case 'number': return key.range === 'photo' ? 1 : key.range[0];
      case 'enum': return key.values[0];
      case 'boolean': return true;
      case 'text': return 'Linear';
      case 'curve': return [0, 0, 255, 255];
    }
  };
  const settingsValid = new Ajv({ strict: false }).compile(developSettingsSchema());
  const settable = (settings: Record<string, unknown>) => settingsValid(settings);

  it('accepts a valid value of every key and every key in the copy and capture lists', () => {
    for (const key of DEVELOP_KEYS) expect([key.name, settable({ [key.name]: sample(key) })]).toEqual([key.name, true]);
    const names = DEVELOP_KEYS.map((key) => key.name);
    const copyable = DEVELOP_KEYS.filter((key) => key.writtenBy === undefined).map((key) => key.name);
    expect(validateToolArgs('copy_develop_settings', { source_id: 914, target_ids: [915], settings: copyable })).toBeNull();
    expect(validateToolArgs('create_develop_preset', { photo_id: 914, preset_name: 'p', settings: names })).toBeNull();
  });

  it.each([
    ['number', 'Exposure2012', 0.5, '0.5'],
    ['enum', 'WhiteBalance', 'As Shot', 'Sunny'],
    ['boolean', 'ConvertToGrayscale', false, 1],
    ['text', 'ToneCurveName2012', 'Linear', 1],
    ['curve', 'ToneCurvePV2012', [0, 0, 64, 48, 192, 210, 255, 255], [0, 0, 255]],
  ])('checks a %s key by its kind', (_kind, key, valid, invalid) => {
    expect(settable({ [key]: valid })).toBe(true);
    expect(settable({ [key]: invalid })).toBe(false);
  });

  it('names each Glow style as Lightroom 16.0 labels it', () => {
    const settings = developSettingsSchema().properties as Record<string, { description?: string }>;
    expect(settings.GlowStyle.description).toBe('0 diffusion, 1 bloom, 2 halation, 3 motion, 4 streak');
  });

  it('refuses a number outside the range Lightroom keeps before anything is written', () => {
    expect(settable({ Exposure2012: 5 })).toBe(true);
    expect(settable({ Exposure2012: 6 })).toBe(false);
    expect(settable({ Exposure2012: -5.01 })).toBe(false);
    expect(settable({ Contrast2012: 150 })).toBe(false);
    expect(settable({ Shadows2012: -130 })).toBe(false);
    expect(settable({ PerspectiveUpright: 5 })).toBe(false);
    expect(settable({ PerspectiveUpright: 6 })).toBe(false);
    expect(settable({ LensProfileEnable: 0.5 })).toBe(false);
  });

  it.each([
    ['DefringePurpleAmount', 20, 21], ['DefringeGreenHueLo', 50, 51], ['DefringePurpleHueHi', 40, 39],
    ['AutoLateralCA', 1, 0.5], ['SplitToningShadowHue', 360, 361], ['ColorGradeMidtoneSat', 100, 101],
    ['ColorGradeBlending', 0, -1], ['Glow', 100, 101], ['GlowStyle', 4, 5], ['GlowDirection', -180, -181],
    ['ReshapeAmount', 100, 101], ['PerspectiveUpright', 3, 5],
  ])('accepts %s at %s and refuses %s', (key, valid, invalid) => {
    expect(settable({ [key]: valid })).toBe(true);
    expect(settable({ [key]: invalid })).toBe(false);
  });

  it('marks only the keys whose range depends on the photo', () => {
    const photo = new Set(DEVELOP_KEYS.flatMap((key) => ('photo' in key && key.photo ? [key.name] : [])));
    expect(photo.has('ReshapeAmount')).toBe(true);
    expect(photo.has('PerspectiveUpright')).toBe(true);
    expect(photo.has('SplitToningShadowHue') || photo.has('Glow') || photo.has('ColorGradeGlobalHue')).toBe(false);
  });

  it('publishes each numeric range in the schema and leaves photo-dependent ranges to Lightroom', () => {
    const properties = developSettingsSchema().properties as Record<string, { minimum?: number; maximum?: number; description?: string }>;
    expect(properties.Exposure2012).toMatchObject({ minimum: -5, maximum: 5 });
    expect(properties.Contrast2012).toMatchObject({ minimum: -100, maximum: 100 });
    expect(properties.Temperature.minimum).toBeUndefined();
    expect(properties.Temperature.description).toContain('depends on the photo');
    expect(settable({ Temperature: 50000, Tint: -150 })).toBe(true);
  });

  it('makes a key added to the table settable, copyable and capturable with no other edit', () => {
    const keys: DevelopKey[] = [...DEVELOP_KEYS, { name: 'FixtureAmount', kind: 'number', range: [0, 10], precision: 1 }];
    const ajv = new Ajv({ strict: false });
    expect(ajv.compile(developSettingsSchema(keys))({ FixtureAmount: 4 })).toBe(true);
    expect(ajv.compile(developSettingsSchema(keys))({ FixtureAmount: 11 })).toBe(false);
    expect(ajv.compile({ type: 'array', items: developKeyNamesSchema(keys) })(['FixtureAmount'])).toBe(true);
    expect(ajv.compile({ type: 'array', items: developKeyNamesSchema() })(['FixtureAmount'])).toBe(false);
  });

  it('rejects malformed develop settings and point curve payloads before dispatch', () => {
    const check = (curve: unknown[]) => validateToolArgs('set_develop_settings',
      { photo_id: '1', settings: { ToneCurvePV2012: curve } }) === null;

    expect(check([0, 0, 64, 48, 192, 210, 255, 255])).toBe(true);
    expect(check([0, 0, 255, 255])).toBe(true);
    expect(check([0, 0, 128, 120, 255])).toBe(false);
    expect(check([0, 0, 128.5, 120, 255, 255])).toBe(false);
    expect(check([0, 0, 128, 300, 255, 255])).toBe(false);
    expect(check([0, 0, 128, -1, 255, 255])).toBe(false);
    expect(check([0, 0])).toBe(false);
    expect(validateToolArgs('set_develop_settings', { photo_id: 914, settings: { ToneCurvePV2012: 1 } })).toContain('ToneCurvePV2012');
    expect(validateToolArgs('set_develop_settings', { photo_id: 914, settings: { Exposure2012: [0, 0, 255, 255] } })).toContain('Exposure2012');
    expect(validateToolArgs('set_develop_settings', { photo_id: 914, settings: { NotAKey: 1 } })).toContain('NotAKey');
    expect(validateToolArgs('set_develop_settings', { photo_id: 914, settings: {} })).toContain('settings');
    expect(validateToolArgs('copy_develop_settings', { source_id: 914, target_ids: [915], settings: ['NotAKey'] })).toContain('settings');
    expect(validateToolArgs('create_develop_preset', { photo_id: 914, preset_name: 'test', settings: ['NotAKey'] })).toContain('settings');
  });

  it('requires explicit allowlisted keys when creating a preset checkpoint', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'create_develop_preset');
    const properties = tool?.inputSchema.properties as Record<string, { items?: { enum?: readonly string[] } }>;
    const args = { photo_id: 914, preset_name: 'checkpoint' };

    expect(properties.settings.items?.enum).toEqual(DEVELOP_KEYS.map((key) => key.name));
    expect(validateToolArgs('create_develop_preset', { ...args, settings: ['Exposure2012'] })).toBeNull();
    expect(validateToolArgs('create_develop_preset', { ...args, settings: [] })).toContain('settings must NOT have fewer than 1 items');
    expect(validateToolArgs('create_develop_preset', { ...args, settings: ['Exposure2012', 'Exposure2012'] })).toContain('settings must NOT have duplicate items');
  });

});

describe('local adjustment schema', () => {
  const creations: [string, Record<string, unknown>][] = [
    ['create_mask', { photo_id: 1, type: 'sky' }],
    ['create_mask_batch', { photo_ids: [1], type: 'sky' }],
    ['create_gradient_mask', { photo_id: 1, shape: 'linear', start: { x: 0.5, y: 0 }, end: { x: 0.5, y: 0.5 } }],
    ['create_brush_mask', { photo_id: 1, strokes: [{ points: [{ x: 0.5, y: 0.5 }] }] }],
    ['create_range_mask', { photo_id: 1, type: 'luminance', luminance: { min: 0.2, max: 0.6 } }],
  ];

  it('offers every local slider with its range to set_mask_adjustments and every creation tool', () => {
    for (const name of ['set_mask_adjustments', ...creations.map(([tool]) => tool)]) {
      const contract = TOOL_CONTRACTS.find((c) => c.name === name);
      const properties = contract?.inputSchema.properties as Record<string, { properties?: Record<string, { minimum?: number; maximum?: number }> }>;

      expect(Object.keys(properties.adjustments.properties ?? {})).toEqual(LOCAL_KEYS.map((key) => key.name));
      expect(properties.adjustments.properties?.local_Exposure).toMatchObject({ minimum: -4, maximum: 4 });
      expect(properties.adjustments.properties?.local_colorgradeMidtoneHue).toMatchObject({ minimum: 0, maximum: 360 });
    }
  });

  it.each(creations)('%s takes local_* sliders and refuses the old creation names', (tool, args) => {
    expect(validateToolArgs(tool, { ...args, adjustments: { local_Exposure: 1, local_glow: 25 } })).toBeNull();
    expect(validateToolArgs(tool, { ...args, adjustments: { exposure: 1 } })).not.toBeNull();
    expect(validateToolArgs(tool, { ...args, adjustments: { local_colorgradeMidtoneHue: 361 } })).not.toBeNull();
  });

  it('publishes a new local slider from its one table entry', () => {
    const fixture = { name: 'local_Fixture', range: [-10, 10], stored: 'LocalFixture', scale: 100 } as const;

    const schema = localAdjustmentsSchema([...LOCAL_KEYS, fixture]) as { properties: Record<string, unknown> };

    expect(schema.properties.local_Fixture).toEqual({ type: 'number', minimum: -10, maximum: 10 });
  });
});

describe('mask curve schema', () => {
  it('offers every channel as a property of set_mask_curves', () => {
    const contract = TOOL_CONTRACTS.find((c) => c.name === 'set_mask_curves');
    const properties = contract?.inputSchema.properties as Record<string, { properties?: Record<string, unknown> }>;

    expect(Object.keys(properties.curves.properties ?? {})).toEqual([...MASK_CURVE_CHANNEL_NAMES]);
  });
});

describe('AI mask types', () => {
  function typeEnumOf(toolName: string): string[] {
    const contract = TOOL_CONTRACTS.find((c) => c.name === toolName);
    const properties = contract?.inputSchema.properties as Record<string, { enum?: string[] }>;
    return properties.type.enum ?? [];
  }

  it('keeps original SDK types on batch/combine and adds guarded AI types only to create_mask', () => {
    expect(typeEnumOf('create_mask_batch')).toEqual(MASK_TYPE_NAMES);
    expect(typeEnumOf('create_mask')).toEqual([...MASK_TYPE_NAMES, 'people', 'landscape']);
    expect(typeEnumOf('combine_mask')).toEqual(MASK_TYPE_NAMES);
  });
});

describe('mcpb manifest tools', () => {
  it('are generated from the contract, one per tool with its first sentence; run npm run build after changing a contract', () => {
    const manifestPath = path.resolve(process.cwd(), '..', 'mcpb', 'manifest.json');
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as { tools: unknown };
    expect(manifest.tools).toEqual(manifestTools());
  });

  it('describe each tool by the start of its own description', () => {
    const tools = manifestTools();
    expect(tools.map((tool) => tool.name)).toEqual(TOOL_CONTRACTS.map((contract) => contract.name));
    const crop = tools.find((tool) => tool.name === 'set_crop');
    expect(TOOL_CONTRACTS.find((contract) => contract.name === 'set_crop')?.description.startsWith(crop?.description ?? '?')).toBe(true);
    expect(crop?.description).toMatch(/[.!?]$/);
  });
});

describe('plug-in actions outside the tool surface', () => {
  it('keeps internal plug-in actions off the MCP tool surface', () => {
    for (const action of PLUGIN_ACTIONS) {
      expect(TOOL_CONTRACTS.some((contract) => contract.name === action.name)).toBe(false);
    }
  });
});

describe('set_color_label schema', () => {
  const tool = TOOL_DEFINITIONS.find((t) => t.name === 'set_color_label')!;
  const validate = new Ajv({ strict: false }).compile(tool.inputSchema);

  it.each(['red', 'yellow', 'green', 'blue', 'purple', 'none'])('accepts %s', (label) => {
    expect(validate({ photo_ids: ['1'], label })).toBe(true);
  });

  it('rejects pink in set_color_label', () => {
    expect(validate({ photo_ids: ['1'], label: 'pink' })).toBe(false);
  });
});


describe('create_smart_collection schema', () => {
  const smart = TOOL_DEFINITIONS.find((tool) => tool.name === 'create_smart_collection')!;
  const search = TOOL_DEFINITIONS.find((tool) => tool.name === 'search_photos')!;
  const validate = new Ajv({ strict: false }).compile(smart.inputSchema);

  it('shares every search filter definition without pagination', () => {
    const { limit, offset, include_path, ...filters } = search.inputSchema.properties!;
    const { name, parent, ...savedFilters } = smart.inputSchema.properties!;
    expect(limit).toBeDefined();
    expect(offset).toBeDefined();
    expect(include_path).toBeDefined();
    expect(name).toBeDefined();
    expect(parent).toBeDefined();
    expect(savedFilters).toEqual(filters);
  });

  it('saves filters without pagination', () => {
    expect(validate({ name: 'Review', rating: 0 })).toBe(true);
    expect(validate({ name: 'Review', limit: 10 })).toBe(false);
  });
});

describe('keyword subtree description', () => {
  it('explains explicit scope, parent inclusion and retained catalog keywords', () => {
    const tool = TOOL_DEFINITIONS.find((t) => t.name === 'remove_keyword_subtree');
    expect(tool?.description).toMatch(/parent keyword and every descendant/);
    expect(tool?.description).toContain('catalog_wide=true');
    expect(tool?.description).toContain('Keyword nodes stay in the catalog');
    expect(tool?.description).toContain('list_keywords');
  });
});


describe('Remove spot contracts', () => {
  it('accepts only the proven uppercase Opacity field', () => {
    const schema = TOOL_CONTRACTS.find((tool) => tool.name === 'update_spot')!.inputSchema;
    const validate = new Ajv().compile(schema);
    expect(validate({ photo_id: '1', index: 1, params: { Opacity: 0.6 } })).toBe(true);
    expect(validate({ photo_id: '1', index: 1, params: { opacity: 0.6 } })).toBe(false);
    expect(validate({ photo_id: '1', index: 1, params: { Opacity: 2 } })).toBe(false);
    expect(validate({ photo_id: '1', index: 1.5, params: { Opacity: 0.6 } })).toBe(false);
  });
});

describe('Develop-driving reads', () => {
  it('say in their published description that they drive Develop and may commit a pending slider change', () => {
    const reads = TOOL_CONTRACTS.filter((contract) => contract.develop === 'drives' && contract.annotations.readOnlyHint);
    expect(reads.map((contract) => contract.name).sort()).toEqual(['describe_develop_keys', 'get_lens_blur', 'list_masks', 'list_spots']);
    for (const contract of reads) {
      const description = TOOL_DEFINITIONS.find((tool) => tool.name === contract.name)!.description;
      expect(description).toContain('Opens the photo in Develop');
      expect(description).toContain('commits any slider change');
    }
  });
});
