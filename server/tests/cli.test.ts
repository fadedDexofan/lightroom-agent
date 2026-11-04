import { describe, it, expect, beforeAll, afterAll, afterEach } from '@jest/globals';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { listToolsHandler } from '../src/list-tools-handler.js';
import { FakePlugin, freePort } from './helpers/fake-plugin.js';
import { parseCli } from '../src/cli.js';

describe('parseCli', () => {
  function p(...args: string[]) {
    return parseCli(['node', 'index.js', ...args]);
  }

  it('defaults to stdio with no args', () => {
    expect(p().command).toBe('stdio');
  });

  it('parses explicit stdio', () => {
    expect(p('stdio').command).toBe('stdio');
  });

  it('parses install-plugin command', () => {
    expect(p('install-plugin').command).toBe('install-plugin');
  });

  it('parses help', () => {
    expect(p('--help').command).toBe('help');
    expect(p('-h').command).toBe('help');
  });

  it('parses version', () => {
    expect(p('--version').command).toBe('version');
    expect(p('-v').command).toBe('version');
  });

  it('throws on unknown command', () => {
    expect(() => p('frobnicate')).toThrow(/Unknown command/);
  });
});


describe('tool command parsing', () => {
  function p(...args: string[]) {
    return parseCli(['node', 'index.js', ...args]);
  }

  it('lists tools or selects one tool by exact name', () => {
    expect(p('tools')).toEqual({ command: 'tools' });
    expect(p('tools', 'get_photo_preview')).toEqual({ command: 'tools', name: 'get_photo_preview' });
  });

  it('parses a tool call with object arguments', () => {
    expect(p('call', 'search_photos', '{"rating":5}')).toEqual({
      command: 'call', name: 'search_photos', args: { rating: 5 },
    });
    expect(p('call', 'list_collections')).toEqual({ command: 'call', name: 'list_collections', args: {} });
  });

  it.each(['null', '[]', '"text"', '1', 'true'])('rejects non-object arguments %s', (args) => {
    expect(() => p('call', 'search_photos', args)).toThrow(/JSON object/);
  });

  it('rejects malformed JSON', () => {
    expect(() => p('call', 'search_photos', '{')).toThrow(/JSON/);
  });

  it('requires a nonempty tool name', () => {
    expect(() => p('call')).toThrow(/tool name/);
    expect(() => p('call', '')).toThrow(/tool name/);
  });

  it('rejects extra arguments to new commands', () => {
    expect(() => p('tools', 'search_photos', 'extra')).toThrow(/Usage/);
    expect(() => p('call', 'search_photos', '{}', 'extra')).toThrow(/Usage/);
  });
});

describe('CLI process', () => {
  let directory: string;
  let build: string;
  let plugin: FakePlugin | undefined;

  beforeAll(async () => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lr-cli-'));
    build = path.join(directory, 'build');
    await promisify(execFile)(process.execPath, [
      path.resolve('node_modules/@typescript/native/bin/tsc'), '--outDir', build,
    ], { cwd: process.cwd() });
    fs.writeFileSync(path.join(build, 'package.json'), '{"type":"module"}');
    fs.symlinkSync(path.resolve('node_modules'), path.join(build, 'node_modules'), 'junction');
    fs.mkdirSync(path.join(build, 'LightroomMCP.lrplugin'));
    fs.writeFileSync(path.join(build, 'LightroomMCP.lrplugin', 'Info.lua'), 'return {}');
  }, 30_000);

  afterEach(async () => {
    await plugin?.stop();
    plugin = undefined;
  });

  afterAll(() => {
    fs.rmSync(directory, { recursive: true, force: true });
  });

  async function run(
    args: string[],
    env: NodeJS.ProcessEnv = {},
    interruption?: { ready: Promise<void>; signal: NodeJS.Signals },
  ) {
    const state = fs.mkdtempSync(path.join(directory, 'state-'));
    const testHome = path.join(state, 'home');
    fs.mkdirSync(testHome);
    const preload = path.join(state, 'home.mjs');
    fs.writeFileSync(preload, `import os from 'node:os'; os.homedir = () => ${JSON.stringify(testHome)};`);
    const result = await new Promise<{ code: number; stdout: string; stderr: string }>((resolve, reject) => {
      const child = execFile(process.execPath, ['--import', pathToFileURL(preload).href, path.join(build, 'index.js'), ...args], {
        env: {
          ...process.env,
          APPDATA: path.join(state, 'appdata'),
          LIGHTROOM_MCP_TOKEN_PATH: path.join(state, 'missing-token'),
          LIGHTROOM_MCP_REQUEST_PORT: 'invalid',
          LIGHTROOM_MCP_RESPONSE_PORT: 'invalid',
          LIGHTROOM_MCP_TOOLSETS: 'core',
          LIGHTROOM_MCP_READ_ONLY: 'false',
          ...env,
        },
        timeout: 10_000,
        maxBuffer: 16 * 1024 * 1024,
      }, (error, stdout, stderr) => {
        if (error && typeof error.code !== 'number') {
          reject(error);
          return;
        }
        resolve({ code: typeof error?.code === 'number' ? error.code : 0, stdout, stderr });
      });
      if (interruption) void interruption.ready.then(() => child.kill(interruption.signal));
    });
    expect(fs.existsSync(path.join(testHome, 'Library'))).toBe(false);
    expect(fs.existsSync(path.join(state, 'appdata'))).toBe(false);
    return { ...result, testHome };
  }

  async function startPlugin(handler: (action: string, params: unknown) => unknown) {
    const requestPort = await freePort();
    let responsePort = await freePort();
    while (responsePort === requestPort) responsePort = await freePort();
    const tokenPath = path.join(directory, 'token');
    const token = 'cli-process-test-token';
    fs.writeFileSync(tokenPath, token);
    plugin = new FakePlugin({ requestPort, responsePort, token, handler, sendWaitMs: 100 });
    await plugin.start();
    return {
      LIGHTROOM_MCP_REQUEST_PORT: String(requestPort),
      LIGHTROOM_MCP_RESPONSE_PORT: String(responsePort),
      LIGHTROOM_MCP_TOKEN_PATH: tokenPath,
    };
  }

  it('discovers schemas without ports, credentials, locks or plugin installation', async () => {
    const result = await run(['tools']);
    expect(result.code).toBe(0);
    expect(result.stderr).toBe('');
    expect(JSON.parse(result.stdout)).toEqual(listToolsHandler());
    expect(fs.readdirSync(result.testHome)).toEqual([]);
  });

  it('discovers one enabled tool and refuses a disabled name', async () => {
    const result = await run(['tools', 'set_develop_settings'], { LIGHTROOM_MCP_TOOLSETS: 'all' });
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual(
      listToolsHandler(new Set(['core', 'develop', 'masks'])).tools.find((tool) => tool.name === 'set_develop_settings'),
    );
    const disabled = await run(['tools', 'set_develop_settings']);
    expect(disabled.code).toBe(1);
    expect(disabled.stdout).toBe('');
    expect(disabled.stderr).toContain('not available');
  });

  it('uses the same read-only discovery policy as MCP', async () => {
    const result = await run(['tools'], { LIGHTROOM_MCP_TOOLSETS: 'all', LIGHTROOM_MCP_READ_ONLY: 'true' });
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual(listToolsHandler(new Set(['core', 'develop', 'masks']), true));
  });

  it('reports invalid call syntax with exit 2 before connection', async () => {
    const result = await run(['call', 'search_photos', '[]']);
    expect(result.code).toBe(2);
    expect(result.stdout).toBe('');
    expect(result.stderr).toContain('JSON object');
  });

  it('returns the complete preview response and exits after releasing its connection', async () => {
    const image = Buffer.alloc(80_000, 'a').toString('base64');
    const called: string[] = [];
    const env = await startPlugin((action, params) => {
      called.push(action);
      if (action === 'ping') return { pong: true };
      expect(params).toEqual({ photo_id: '914' });
      return { photo_id: 914, image: { data: image, mime_type: 'image/jpeg' } };
    });
    const result = await run(['call', 'get_photo_preview', '{"photo_id":"914"}'], env);
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({ content: [
      { type: 'text', text: '{"photo_id":914}' },
      { type: 'image', data: image, mimeType: 'image/jpeg' },
    ] });
    expect(called).toContain('get_photo_preview');
    expect(fs.readdirSync(path.join(result.testHome, '.config', 'lightroom-mcp'))).toEqual([]);
  });

  it('returns the backend error as JSON with a failing exit status', async () => {
    const env = await startPlugin((action) => {
      if (action === 'ping') return { pong: true };
      throw new Error('Missing catalog fixture');
    });
    const result = await run(['call', 'list_collections'], env);
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout)).toEqual({
      isError: true, content: [{ type: 'text', text: 'Error: Missing catalog fixture' }],
    });
  });

  it.each([
    ['read-only', 'set_rating_and_flag', '{"photo_ids":["914"],"rating":5}', { LIGHTROOM_MCP_READ_ONLY: 'true' }],
    ['toolset', 'set_develop_settings', '{"photo_id":"914","settings":{"Exposure2012":1}}', {}],
  ])('refuses %s writes before starting the bridge', async (_label, name, args, settings) => {
    const env = await startPlugin(() => { throw new Error('Must not reach plugin'); });
    const result = await run(['call', name as string, args as string], { ...env, ...settings as NodeJS.ProcessEnv });
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout)).toMatchObject({ isError: true });
    expect(plugin?.events.some((event) => event.kind === 'request_connected')).toBe(false);
    expect(fs.readdirSync(result.testHome)).toEqual([]);
  });


  it.each([...['core', 'all'].flatMap((toolset) => ['set_selection', 'cancel', 'not_a_tool'].map((name) => [toolset, name]))])(
    'refuses unpublished tool %s/%s before starting the bridge',
    async (toolset, name) => {
      const env = await startPlugin(() => ({ success: true }));
      const result = await run(['call', name, '{}'], { ...env, LIGHTROOM_MCP_TOOLSETS: toolset });
      expect(result.code).toBe(1);
      expect(JSON.parse(result.stdout)).toEqual({
        isError: true, content: [{ type: 'text', text: `Unknown tool "${name}". Only listed tools can be called.` }],
      });
      expect(plugin?.events.some((event) => event.kind === 'request_connected')).toBe(false);
      expect(fs.readdirSync(result.testHome)).toEqual([]);
    },
  );

  const signalTest = process.platform === 'win32' ? it.skip : it;
  signalTest.each([['SIGINT', 130], ['SIGTERM', 143]] as const)(
    'does not report success when %s interrupts an in-flight call',
    async (signal, expectedCode) => {
      let entered: () => void = () => {};
      const ready = new Promise<void>((resolve) => { entered = resolve; });
      let finish: () => void = () => {};
      const pending = new Promise<void>((resolve) => { finish = resolve; });
      const env = await startPlugin(async (action) => {
        if (action === 'ping') return { pong: true };
        entered();
        await pending;
        return { success: true };
      });
      try {
        const result = await run(['call', 'list_collections'], env, { ready, signal });
        expect(result.code).toBe(expectedCode);
        expect(result.stdout).toBe('');
      } finally {
        finish();
      }
    },
  );

  it('validates arguments through the common backend without dispatching the operation', async () => {
    const called: string[] = [];
    const env = await startPlugin((action) => { called.push(action); return { pong: true }; });
    const result = await run(['call', 'search_photos', '{"unexpected":true}'], env);
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout)).toMatchObject({ isError: true });
    expect(result.stdout).toContain('unknown property');
    expect(called).not.toContain('search_photos');
  });
});
