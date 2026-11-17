import { describe, it, expect, afterEach, jest } from '@jest/globals';
import { dataOf } from './helpers/envelope.js';
import { Client, InMemoryTransport } from '@modelcontextprotocol/client';
import jpeg from 'jpeg-js';
import { createMcpServer } from '../src/create-server.js';
import { parseToolsets } from '../src/toolsets.js';
import { TOOL_CONTRACTS } from '../src/tool-contracts.js';
import { publishedDescription } from '../src/list-tools-handler.js';
import type { CallOptions, PluginResponse } from '../src/dispatcher.js';
import type { ToolCaller } from '../src/broker.js';

const TOOL_CLASSES: Record<string, 'read-only' | 'additive' | 'destructive'> = {
  search_photos: 'read-only',
  get_selected_photos: 'read-only',
  get_photo_metadata: 'read-only',
  summarize_develop_settings: 'read-only',
  get_photo_preview: 'read-only',
  get_photo_detail: 'additive',
  get_photo_previews: 'read-only',
  get_photo_stats: 'read-only',
  find_duplicate_groups: 'read-only',
  set_gps: 'destructive',
  set_location: 'destructive',
  set_metadata: 'destructive',
  set_ai_metadata: 'destructive',
  get_ai_metadata: 'read-only',
  list_folders: 'read-only',
  get_folder_photos: 'read-only',
  list_collections: 'read-only',
  create_collection: 'additive',
  create_smart_collection: 'additive',
  add_to_collection: 'additive',
  get_collection_photos: 'read-only',
  remove_from_collection: 'destructive',
  delete_collection: 'destructive',
  set_keywords: 'destructive',
  remove_keyword_subtree: 'destructive',
  list_keywords: 'read-only',
  rename_keyword: 'destructive',
  set_rating_and_flag: 'destructive',
  undo_last_step: 'destructive',
  remove_photos_from_catalog: 'destructive',
  set_color_label: 'destructive',
  import_photos: 'additive',
  export_photos: 'destructive',
  export_photo_metadata: 'destructive',
  list_export_presets: 'read-only',
  list_develop_presets: 'read-only',
  get_develop_preset: 'read-only',
  compare_develop_presets: 'read-only',
  create_develop_preset: 'additive',
  export_develop_preset: 'additive',
  apply_develop_preset: 'destructive',
  copy_develop_settings: 'destructive',
  match_photo_style: 'destructive',
  set_develop_settings: 'destructive',
  set_crop: 'destructive',
  describe_develop_keys: 'read-only',
  get_crop: 'read-only',
  get_lens_blur: 'read-only',
  get_develop_settings: 'read-only',
  get_mask_write_admission: 'read-only',
  set_lens_blur: 'destructive',
  set_process_version: 'destructive',
  list_develop_snapshots: 'read-only',
  create_develop_snapshot: 'destructive',
  create_virtual_copies: 'additive',
  set_treatment: 'destructive',
  apply_develop_snapshot: 'destructive',
  delete_develop_snapshot: 'destructive',
  reset_develop_adjustments: 'destructive',
  apply_denoise: 'destructive',
  apply_auto_adjustments: 'destructive',
  list_masks: 'read-only',
  list_spots: 'read-only',
  update_spot: 'destructive',
  delete_spot: 'destructive',
  create_gradient_mask: 'destructive',
  update_gradient_mask: 'destructive',
  create_brush_mask: 'additive',
  add_brush_strokes: 'destructive',
  create_range_mask: 'destructive',
  delete_masks: 'destructive',
  delete_empty_masks: 'destructive',
  set_mask_adjustments: 'destructive',
  get_mask: 'read-only',
  invert_mask: 'destructive',
  create_mask: 'additive',
  create_mask_batch: 'additive',
  set_mask_curves: 'destructive',
  edit_mask_point_colors: 'destructive',
  combine_mask: 'destructive',
};

interface ToolResult {
  content: Array<{ type: string; text: string }>;
  isError?: boolean;
}

function asToolResult(r: unknown): ToolResult {
  return r as ToolResult;
}

type CallFn = (action: string, params: unknown, timeout?: number, options?: CallOptions) => Promise<PluginResponse>;

interface Pair {
  server: ReturnType<typeof createMcpServer>;
  client: Client;
}

describe('read-only mode', () => {
  let pair: Pair | undefined;
  afterEach(async () => {
    await pair?.client.close();
    await pair?.server.close();
    pair = undefined;
  });

  it('classifies every contract explicitly with the audited read-only annotation', () => {
    expect(Object.keys(TOOL_CLASSES).sort()).toEqual(TOOL_CONTRACTS.map((tool) => tool.name).sort());
    for (const tool of TOOL_CONTRACTS) {
      expect(typeof tool.annotations.readOnlyHint).toBe('boolean');
      expect(tool.annotations.readOnlyHint).toBe(TOOL_CLASSES[tool.name] === 'read-only');
    }
  });

  it.each([undefined, 'core', 'develop', 'masks', 'all'])('lists exactly enabled read tools for %p', async (toolsets) => {
    pair = await connect({ toolsets, readOnly: true });
    const listed = await pair.client.listTools();
    const enabled = new Set(parseToolsets(toolsets));
    expect(listed.tools.map((tool) => tool.name)).toEqual(TOOL_CONTRACTS
      .filter((tool) => enabled.has(tool.toolset) && TOOL_CLASSES[tool.name] === 'read-only')
      .map((tool) => tool.name));
  });

  it('rejects every write, hidden read, unknown and test-only call before dispatch', async () => {
    const call = jest.fn<CallFn>();
    pair = await connect({ readOnly: true, call });
    const names = TOOL_CONTRACTS.filter((tool) => !tool.annotations.readOnlyHint || tool.toolset !== 'core')
      .map((tool) => tool.name);
    for (const name of [...names, 'set_rating', 'set_selection', 'not_a_tool']) {
      const result = asToolResult(await pair.client.callTool({ name, arguments: {} }));
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain('LIGHTROOM_MCP_READ_ONLY');
    }
    expect(call).not.toHaveBeenCalled();
  });

  it('enforces before the broker follower call and fixes the list at startup', async () => {
    const callTool = jest.fn<ToolCaller>().mockResolvedValue({ content: [{ type: 'text', text: 'forwarded' }] });
    const options = { readOnly: true, toolsets: parseToolsets('all') };
    const server = createMcpServer({ callTool }, options);
    const client = new Client({ name: 'follower-test', version: '1.0.0' });
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    pair = { server, client };
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
    const before = await client.listTools();
    options.readOnly = false;
    const blocked = asToolResult(await client.callTool({ name: 'set_rating_and_flag', arguments: { photo_ids: [914], rating: 3 } }));
    expect(blocked.isError).toBe(true);
    expect(callTool).not.toHaveBeenCalled();
    const read = asToolResult(await client.callTool({ name: 'list_collections', arguments: {} }));
    expect(read.content[0].text).toBe('forwarded');
    expect(callTool).toHaveBeenCalledTimes(1);
    expect(await client.listTools()).toEqual(before);
  });

  it.each([undefined, 'all'])('preserves listing bytes and write dispatch when off for %p', async (toolsets) => {
    const call = jest.fn<CallFn>().mockResolvedValue({ id: 'x', result: { success: true } });
    pair = await connect({ toolsets, readOnly: false, call });
    const listed = await pair.client.listTools();
    const enabled = new Set(parseToolsets(toolsets));
    const { listToolsHandler } = await import('../src/list-tools-handler.js');
    expect(listed).toEqual(listToolsHandler(enabled));
    await pair.client.callTool({ name: 'set_rating_and_flag', arguments: { photo_ids: [914], rating: 3 } });
    expect(call).toHaveBeenCalledTimes(1);
    await pair.client.close();
    await pair.server.close();
    pair = await connect({ toolsets });
    expect(JSON.stringify(await pair.client.listTools())).toBe(JSON.stringify(listed));
  });
});

async function connect(opts: { ready?: boolean; call?: CallFn; toolsets?: string; readOnly?: boolean } = {}): Promise<Pair> {
  const server = createMcpServer({
    isReady: () => opts.ready ?? true,
    dispatcher: {
      call: opts.call ?? (async () => ({ id: 'x', result: null })),
    },
  }, { toolsets: parseToolsets(opts.toolsets), readOnly: opts.readOnly ?? false });
  const client = new Client({ name: 'test-client', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  return { server, client };
}

describe('createMcpServer', () => {
  let pair: Pair | null = null;


  it.each(['set_selection', 'cancel', 'ping', 'not_a_tool'])(
    'refuses unpublished tool %s before forwarding to a broker',
    async (name) => {
      const callTool = jest.fn<ToolCaller>().mockResolvedValue({ content: [{ type: 'text', text: 'forwarded' }] });
      const server = createMcpServer({ callTool }, { toolsets: parseToolsets('all'), readOnly: false });
      const client = new Client({ name: 'unpublished-tool-test', version: '1.0.0' });
      const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
      pair = { server, client };
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      const result = asToolResult(await client.callTool({ name, arguments: {} }));
      expect(result).toEqual({
        isError: true, content: [{ type: 'text', text: JSON.stringify({
          outcome: 'failed', error: `Unknown tool "${name}". Only listed tools can be called.`,
        }) }],
      });
      expect(callTool).not.toHaveBeenCalled();
    },
  );

  it('returns static shared instructions to the client on initialize', async () => {
    pair = await connect();
    const instructions = pair.client.getInstructions();
    for (const phrase of [
      'run one at a time in arrival order', 'fails without effect if its turn does not come',
      'certification run', 'process version', 'read back', 'roll back',
      'normalized 0 to 1', 'top-left', 'y increasing down', 'rendered preview',
      'after the develop crop, straighten and displayed orientation', 'about 0.05 of the frame',
      'Photo ids are strings', 'get_develop_settings is the one develop read', 'listed in adjusted',
      'set_crop', 'set_treatment', 'get_photo_detail', 'collapsed stack',
      'describe_develop_keys with mask_id reports where Lightroom\'s live range differs',
      'Every catalog write waits up to 10 s', 'a call that had written nothing is failed',
      'keeps the turn until Lightroom has finished it or 60 s have passed since the timeout',
      'a call still running after that can overlap the next one, and its outcome stays unknown',
    ]) expect(instructions).toContain(phrase);
    const second = await connect();
    try {
      expect(second.client.getInstructions()).toBe(instructions);
    } finally {
      await second.client.close();
      await second.server.close();
    }
  });

  it('keeps load-bearing tool guidance reachable alongside instructions', async () => {
    pair = await connect();
    const instructions = pair.client.getInstructions() ?? '';
    const required: Record<string, string[]> = {
      create_range_mask: ['sRGB', 'copy_sample_from', 'second sample point', 'Lightroom crashes', '0.01', 'different colors'],
      create_mask: ['ErrorReason', 'no alert to dismiss', 'omitted sliders are neutral', 'AI process is running', 'single-person', 'writes nothing more', 'does not prove'],
      create_mask_batch: ['saved settings', 'does not prove', 'reports finding nothing', 'compare previews', 'remaining', '230'],
      invert_mask: ['only one component', 'returned mask_id'],
      combine_mask: ['intersect', 'inverted true', 'ErrorReason', 'saved settings'],
      get_photo_detail: ['render {width, height, jpeg_quality, color_space, output_sharpening, source, left_on_photo}', 'a string ("export" today)', 'a list of phrases', '"the exported mark"'],
      export_photos: ['get_photo_detail or another export', 'refused, not queued', 'separator between names (/ on macOS'],
      set_mask_adjustments: ['saved settings by mask_id', 'six decimal places', 'pending in Develop are committed first', 'one history step', 'naming what Lightroom stored'],
      set_mask_curves: ['saved settings by mask_id', 'at most 16 points', 'pending in Develop are committed first', 'naming what Lightroom stored'],
      edit_mask_point_colors: ['centred on the source', 'already holds', 'six decimals', 'saved settings by mask_id'],
      list_masks: ['empty list means', 'saved settings hold', 'Develop has not loaded them yet', 'click OK in Lightroom', 'call again', 'failed with nothing changed'],
    };
    for (const [name, phrases] of Object.entries(required)) {
      const tool = TOOL_CONTRACTS.find((entry) => entry.name === name);
      expect(tool).toBeDefined();
      const reachable = `${tool ? publishedDescription(tool) : ''} ${JSON.stringify(tool?.inputSchema)} ${instructions}`;
      for (const phrase of phrases) expect(reachable).toContain(phrase);
    }
    for (const name of ['create_gradient_mask', 'update_gradient_mask', 'create_brush_mask', 'add_brush_strokes', 'create_range_mask']) {
      const tool = TOOL_CONTRACTS.find((entry) => entry.name === name);
      expect(tool?.description).toContain('coordinate rules');
      expect(instructions).toContain('Positions for gradient, brush and range masks');
    }
  });

  afterEach(async () => {
    if (pair) {
      await pair.client.close();
      await pair.server.close();
      pair = null;
    }
  });

  describe('toolset selection', () => {
    const coreNames = [
      'search_photos', 'get_selected_photos', 'get_photo_metadata', 'get_photo_preview',
      'get_photo_detail', 'get_photo_previews', 'find_duplicate_groups', 'get_photo_stats', 'set_gps',
      'set_location', 'set_metadata', 'set_ai_metadata', 'get_ai_metadata', 'list_folders',
      'get_folder_photos', 'list_collections', 'create_collection', 'create_smart_collection',
      'add_to_collection', 'get_collection_photos', 'remove_from_collection', 'delete_collection',
      'set_keywords', 'remove_keyword_subtree', 'list_keywords', 'rename_keyword', 'undo_last_step',
      'set_rating_and_flag', 'set_color_label', 'remove_photos_from_catalog', 'import_photos',
      'export_photos', 'export_photo_metadata', 'list_export_presets',
    ];

    it.each([undefined, '', '   ', 'core'])('toolset %p lists only approved core tools', async (toolsets) => {
      pair = await connect({ toolsets });
      expect((await pair.client.listTools()).tools.map((tool) => tool.name).sort()).toEqual([...coreNames].sort());
    });

    it.each([
      ['develop', ['core', 'develop']],
      ['masks', ['core', 'masks']],
      ['develop,masks', ['core', 'develop', 'masks']],
      ['all', ['core', 'develop', 'masks']],
    ] as const)('toolset %s preserves contract order and definitions', async (toolsets, groups) => {
      const privateContracts = JSON.stringify(TOOL_CONTRACTS);
      pair = await connect({ toolsets });
      const first = await pair.client.listTools();
      const contracts = TOOL_CONTRACTS.filter((tool) => groups.some((group) => group === tool.toolset));
      expect(first.tools.map((tool) => tool.name)).toEqual(contracts.map((tool) => tool.name));
      first.tools.forEach((tool, index) => {
        expect(tool.description).toBe(publishedDescription(contracts[index]));
        expect(tool.inputSchema).toEqual(contracts[index].inputSchema);
      });
      expect(JSON.stringify(TOOL_CONTRACTS)).toBe(privateContracts);
      expect(JSON.stringify(await pair.client.listTools())).toBe(JSON.stringify(first));
      expect(pair.client.getServerCapabilities()?.tools).not.toHaveProperty('listChanged');
    });

    it.each([
      ['set_develop_settings', 'develop'], ['create_virtual_copies', 'develop'],
      ['summarize_develop_settings', 'develop'], ['list_masks', 'masks'],
    ])('toolset default refuses hidden %s before dispatcher', async (name, group) => {
      let called = false;
      pair = await connect({ call: async () => { called = true; return { id: '1', result: null }; } });
      const result = asToolResult(await pair.client.callTool({ name, arguments: {} }));
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain('LIGHTROOM_MCP_TOOLSETS');
      expect(result.content[0].text).toContain(group);
      expect(called).toBe(false);
    });

    it('toolset selection copies options at startup and ignores later env changes', async () => {
      const toolsets: Array<'core' | 'develop' | 'masks'> = ['core'];
      const server = createMcpServer({ callTool: async () => ({ content: [{ type: 'text', text: '{}' }] }) }, { toolsets });
      const client = new Client({ name: 'fixed-toolsets', version: '1.0.0' });
      const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      const original = process.env.LIGHTROOM_MCP_TOOLSETS;
      try {
        const first = JSON.stringify(await client.listTools());
        toolsets.push('develop', 'masks');
        process.env.LIGHTROOM_MCP_TOOLSETS = 'all';
        expect(JSON.stringify(await client.listTools())).toBe(first);
        expect((await client.callTool({ name: 'list_masks' })).isError).toBe(true);
      } finally {
        if (original === undefined) delete process.env.LIGHTROOM_MCP_TOOLSETS;
        else process.env.LIGHTROOM_MCP_TOOLSETS = original;
        await client.close();
        await server.close();
      }
    });

    it('toolset gate refuses hidden tools before a forwarding caller', async () => {
      let called = false;
      const server = createMcpServer({ callTool: async () => { called = true; return { content: [{ type: 'text', text: '{}' }] }; } });
      const client = new Client({ name: 'forwarding-toolsets', version: '1.0.0' });
      const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
      await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
      try {
        expect((await client.callTool({ name: 'set_develop_settings' })).isError).toBe(true);
        expect(called).toBe(false);
      } finally {
        await client.close();
        await server.close();
      }
    });
  });

  it('loads only three hot catalog tools upfront over the wire', async () => {
    pair = await connect();
    const { tools } = await pair.client.listTools();
    const hotNames = ['search_photos', 'get_photo_preview', 'set_rating_and_flag'];
    expect(tools.filter((tool) => tool._meta?.['anthropic/alwaysLoad'] === true).map((tool) => tool.name)).toEqual(hotNames);
    for (const tool of tools) {
      if (hotNames.includes(tool.name)) expect(tool._meta).toEqual({ 'anthropic/alwaysLoad': true });
      else expect(tool).not.toHaveProperty('_meta');
    }
  });

  it('keeps tool lists byte-identical across fresh servers', async () => {
    pair = await connect({ toolsets: 'all' });
    const first = await pair.client.listTools();
    const second = await connect({ toolsets: 'all' });
    try {
      expect(JSON.stringify(await second.client.listTools())).toBe(JSON.stringify(first));
    } finally {
      await second.client.close();
      await second.server.close();
    }
  });


  it('sends progress to the connected client without resolving the tool early', async () => {
    pair = await connect({ call: async (_action, _params, _timeout, options) => {
      options?.onProgress?.({ progress: 1, total: 2, message: 'a.jpg' });
      options?.onProgress?.({ progress: 2, total: 2, message: 'b.jpg' });
      return { id: '1', result: { data: { exported: 2 } } };
    } });
    const progress: unknown[] = [];

    const result = asToolResult(await pair.client.callTool({ name: 'export_photos', arguments: {
      photo_ids: ['1', '2'], destination: '/out',
    } }, { onprogress: (value) => progress.push(value) }));

    expect(progress).toEqual([
      { progress: 1, total: 2, message: 'a.jpg' },
      { progress: 2, total: 2, message: 'b.jpg' },
    ]);
    expect(dataOf(result)).toEqual({ exported: 2 });
  });

  it('no progressToken leaves the result unchanged and requests no progress', async () => {
    let reporting = true;
    pair = await connect({ call: async (_action, _params, _timeout, options) => {
      reporting = options?.onProgress !== undefined;
      return { id: '1', result: { data: { exported: 2 } } };
    } });

    const result = asToolResult(await pair.client.callTool({ name: 'export_photos', arguments: {
      photo_ids: ['1', '2'], destination: '/out',
    } }));

    expect(reporting).toBe(false);
    expect(dataOf(result)).toEqual({ exported: 2 });
  });

  it('forwards client cancel to the running dispatcher request', async () => {
    let entered: () => void = () => {};
    const started = new Promise<void>((resolve) => { entered = resolve; });
    let cancelled: () => void = () => {};
    const stopped = new Promise<void>((resolve) => { cancelled = resolve; });
    pair = await connect({ call: async (_action, _params, _timeout, options) => {
      entered();
      await new Promise<void>((resolve) => options?.signal?.addEventListener('abort', () => {
        cancelled(); resolve();
      }, { once: true }));
      return { id: '1', result: { complete: false } };
    } });
    const controller = new AbortController();
    const pending = pair.client.callTool({ name: 'export_photos', arguments: {
      photo_ids: ['1', '2'], destination: '/out',
    } }, { signal: controller.signal });
    const rejection = expect(pending).rejects.toThrow();

    await started;
    controller.abort();

    await stopped;
    await rejection;
  });

  describe('ListTools', () => {
    it('exposes tool annotations and titles for every classified tool', async () => {
      pair = await connect({ toolsets: 'all' });
      const { tools } = await pair.client.listTools();
      expect(tools.map((tool) => tool.name).sort()).toEqual(Object.keys(TOOL_CLASSES).sort());
      for (const tool of tools) {
        const classification = TOOL_CLASSES[tool.name];
        expect({ name: tool.name, title: tool.title }).toEqual({
          name: tool.name,
          title: expect.stringMatching(/\S/),
        });
        expect({ name: tool.name, annotations: tool.annotations }).toEqual({
          name: tool.name,
          annotations: classification === 'read-only'
            ? { readOnlyHint: true, openWorldHint: false }
            : { readOnlyHint: false, destructiveHint: classification === 'destructive', openWorldHint: false },
        });
      }
    });

    it('each tool has a non-empty description and object inputSchema', async () => {
      pair = await connect();
      const { tools } = await pair.client.listTools();
      for (const tool of tools) {
        expect(tool.description!.length).toBeGreaterThan(0);
        expect(tool.inputSchema.type).toBe('object');
      }
    });
  });

  it('preserves preview image blocks over MCP', async () => {
    const image = jpeg.encode({ width: 2, height: 1, data: Buffer.alloc(8, 255) }, 90).data.toString('base64');
    pair = await connect({ call: async () => ({
      id: '1', result: { data: { photo_id: 914, image: { mime_type: 'image/jpeg', data: image } } },
    }) });

    const result = await pair.client.callTool({ name: 'get_photo_preview', arguments: { photo_id: 914 } });

    expect(result.isError).toBeUndefined();
    expect(result.content).toEqual([
      { type: 'text', text: JSON.stringify({ outcome: 'done', data: {
        photo_id: '914', requested_size: 864, width: 2, height: 1, bytes: Buffer.from(image, 'base64').length,
        scaled_by_server: false } }) },
      { type: 'image', data: image, mimeType: 'image/jpeg' },
    ]);
  });

  it('preserves all batch preview image blocks over MCP', async () => {
    const image = jpeg.encode({ width: 2, height: 1, data: Buffer.alloc(8, 255) }, 90).data.toString('base64');
    pair = await connect({ call: async (_action, params) => ({ id: '1', result: { data: {
      photo_id: (params as { photo_ids: number[] }).photo_ids[0], image: { mime_type: 'image/jpeg', data: image },
    } } }) });
    const result = await pair.client.callTool({ name: 'get_photo_previews', arguments: { photo_ids: [1, 2, 3] } });
    expect(result.isError).toBeUndefined();
    expect(result.content).toEqual([
      { type: 'text', text: JSON.stringify({ outcome: 'done', data: { previews: [1, 2, 3].map(id => ({
        photo_id: String(id), requested_size: 256, width: 2, height: 1, bytes: Buffer.from(image, 'base64').length,
        scaled_by_server: false, image_index: id })) } }) },
      ...[1, 2, 3].map(() => ({ type: 'image', data: image, mimeType: 'image/jpeg' })),
    ]);
  });

  it('serves the bundled skill prompt with its workflow references', async () => {
    pair = await connect({ ready: false });
    expect(pair.client.getServerCapabilities()).toMatchObject({ prompts: {}, tools: {} });
    const { prompts } = await pair.client.listPrompts();
    expect(prompts).toHaveLength(1);
    expect(prompts[0].name).toBe('raw-photo-lightroom-preset');
    const result = await pair.client.getPrompt({ name: prompts[0].name });
    expect(result.messages).toEqual([{
      role: 'user',
      content: { type: 'text', text: expect.stringContaining('Judge color only from RAW files rendered by Lightroom/Camera Raw.') },
    }]);
    expect(result.messages[0].content).toMatchObject({
      text: expect.stringContaining('# RAW-First Lightroom Workflow v2'),
    });
  });

  it('rejects an unknown skill prompt', async () => {
    pair = await connect();
    await expect(pair.client.getPrompt({ name: 'unknown' })).rejects.toThrow('Unknown prompt: unknown');
  });

  describe('CallTool — wire arguments', () => {
    it('passes undefined args as empty object to dispatcher', async () => {
      let capturedParams: unknown = 'not-set';
      pair = await connect({
        toolsets: 'all',
        call: async (_action, params) => {
          capturedParams = params;
          return { id: '1', result: null };
        },
      });
      await pair.client.callTool({ name: 'list_develop_presets' });
      expect(capturedParams).toEqual({});
    });
  });
});
