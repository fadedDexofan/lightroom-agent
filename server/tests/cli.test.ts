import { describe, it, expect, beforeAll, afterAll, afterEach } from '@jest/globals';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import jpeg from 'jpeg-js';
import { pathToFileURL } from 'node:url';
import { listToolsHandler } from '../src/list-tools-handler.js';
import { FakePlugin } from './helpers/fake-plugin.js';
import { parseCli } from '../src/cli.js';
import { brokerPath } from '../src/broker.js';
import { VERSION } from '../src/version.js';
import { serverIdentity } from '../src/server-identity.js';
import { expectedIdentity, renderContractLua } from '../src/contract-lua.js';
import { Client } from '@modelcontextprotocol/client';
import { StdioClientTransport } from '@modelcontextprotocol/client/stdio';
import type { ToolResponse } from '../src/tool-result.js';

let BUILD = '';

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

const CLI_SPAWN_MS = 30_000;
const CLI_TEST_MS = CLI_SPAWN_MS + 5_000;

describe('CLI process', () => {
  let directory: string;
  let build: string;
  let plugin: FakePlugin | undefined;

  beforeAll(async () => {
    directory = fs.mkdtempSync(path.join(os.tmpdir(), 'lr-cli-'));
    build = path.join(directory, 'package', 'dist');
    await promisify(execFile)(process.execPath, [
      path.resolve('node_modules/@typescript/native/bin/tsc'), '--outDir', build,
    ], { cwd: process.cwd() });
    fs.writeFileSync(path.join(build, 'package.json'), '{"type":"module"}');
    fs.symlinkSync(path.resolve('node_modules'), path.join(build, 'node_modules'), 'junction');
    const bundle = path.join(directory, 'package', 'LightroomAgent.lrplugin');
    fs.mkdirSync(bundle);
    fs.writeFileSync(path.join(bundle, 'Info.lua'), 'return {}');
    BUILD = expectedIdentity(bundle).build;
    fs.writeFileSync(path.join(bundle, 'Contract.lua'), renderContractLua({ version: VERSION, build: BUILD }));
    fs.writeFileSync(path.join(build, 'plugin-build.json'), JSON.stringify({ build: BUILD }));
  }, 30_000);

  afterEach(async () => {
    await plugin?.stop();
    plugin = undefined;
  });

  afterAll(() => {
    fs.rmSync(directory, { recursive: true, force: true });
  });

  type State = { state: string; testHome: string; preload: string };

  function newState(): State {
    const state = fs.mkdtempSync(path.join(directory, 'state-'));
    const testHome = path.join(state, 'home');
    fs.mkdirSync(testHome);
    const preload = path.join(state, 'home.mjs');
    fs.writeFileSync(preload, `import os from 'node:os'; os.homedir = () => ${JSON.stringify(testHome)};`);
    return { state, testHome, preload };
  }

  function processEnv({ state }: State, env: NodeJS.ProcessEnv): Record<string, string> {
    return Object.fromEntries(Object.entries({
      ...process.env,
      APPDATA: path.join(state, 'appdata'),
      LIGHTROOM_AGENT_TOKEN_PATH: path.join(state, 'missing-token'),
      LIGHTROOM_AGENT_REQUEST_PORT: 'invalid',
      LIGHTROOM_AGENT_RESPONSE_PORT: 'invalid',
      LIGHTROOM_AGENT_TOOLSETS: 'core',
      LIGHTROOM_AGENT_READ_ONLY: 'false',
      ...env,
    }).filter((entry): entry is [string, string] => entry[1] !== undefined));
  }

  function checkout(edit: (tree: { dist: string; bundle: string }) => void = () => {}): string {
    const root = fs.mkdtempSync(path.join(directory, 'checkout-'));
    const dist = path.join(root, 'server', 'dist');
    fs.cpSync(build, dist, { recursive: true, verbatimSymlinks: true });
    const bundle = path.join(root, 'plugin', 'LightroomAgent.lrplugin');
    fs.cpSync(path.join(directory, 'package', 'LightroomAgent.lrplugin'), bundle, { recursive: true });
    edit({ dist, bundle });
    return dist;
  }

  const STALE_LUA = ({ bundle }: { bundle: string }) => fs.writeFileSync(path.join(bundle, 'Handler.lua'), 'return 2\n');
  const REBUILD = "This server's build does not match its plug-in folder; rebuild it (npm --prefix server run build in the "
    + 'checkout), then restart your client.';

  const clients: Client[] = [];
  afterEach(async () => {
    while (clients.length > 0) await clients.pop()!.close();
  });

  async function stdio(dist: string, home: State, env: NodeJS.ProcessEnv): Promise<{ client: Client; call: (name: string) => Promise<ToolResponse> }> {
    const client = new Client({ name: 'cli-test', version: '1.0.0' });
    await client.connect(new StdioClientTransport({
      command: process.execPath,
      args: ['--import', pathToFileURL(home.preload).href, path.join(dist, 'index.js')],
      env: processEnv(home, env),
      stderr: 'ignore',
    }));
    clients.push(client);
    return { client, call: async (name) => await client.callTool({ name, arguments: {} }) as ToolResponse };
  }

  async function closeClient(client: Client): Promise<void> {
    clients.splice(clients.indexOf(client), 1);
    await client.close();
  }

  async function run(
    args: string[],
    env: NodeJS.ProcessEnv = {},
    interruption?: { ready: Promise<void>; signal: NodeJS.Signals },
    options: { dist?: string; home?: State } = {},
  ) {
    const home = options.home ?? newState();
    const { state, testHome, preload } = home;
    const result = await new Promise<{ code: number; stdout: string; stderr: string }>((resolve, reject) => {
      const child = execFile(process.execPath, ['--import', pathToFileURL(preload).href, path.join(options.dist ?? build, 'index.js'), ...args], {
        env: processEnv(home, env),
        timeout: CLI_SPAWN_MS,
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
    const ports = [env.LIGHTROOM_AGENT_REQUEST_PORT, env.LIGHTROOM_AGENT_RESPONSE_PORT].map(Number);
    if (interruption && ports.every(Number.isInteger)) fs.rmSync(brokerPath(ports[0], ports[1], path.join(testHome, '.config', 'lightroom-agent')), { force: true });
    if (options.home === undefined) {
      expect(fs.existsSync(path.join(testHome, 'Library'))).toBe(false);
      expect(fs.existsSync(path.join(state, 'appdata'))).toBe(false);
    }
    return { ...result, testHome };
  }

  async function startPlugin(handler: (action: string, params: unknown) => unknown) {
    const tokenPath = path.join(directory, 'token');
    const token = 'cli-process-test-token';
    fs.writeFileSync(tokenPath, token);
    plugin = new FakePlugin({ token, handler, sendWaitMs: 100 });
    await plugin.start();
    return {
      LIGHTROOM_AGENT_REQUEST_PORT: String(plugin.requestPort),
      LIGHTROOM_AGENT_RESPONSE_PORT: String(plugin.responsePort),
      LIGHTROOM_AGENT_TOKEN_PATH: tokenPath,
    };
  }

  it('discovers schemas without ports, credentials, locks or plugin installation', async () => {
    const result = await run(['tools']);
    expect(result.code).toBe(0);
    expect(result.stderr).toBe('');
    expect(JSON.parse(result.stdout)).toEqual(listToolsHandler(new Set(['core']), false));
    expect(fs.readdirSync(result.testHome)).toEqual([]);
  }, CLI_TEST_MS);

  it('discovers one enabled tool', async () => {
    const result = await run(['tools', 'set_develop_settings'], { LIGHTROOM_AGENT_TOOLSETS: 'all' });
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual(
      listToolsHandler(new Set(['core', 'develop', 'masks']), false).tools.find((tool) => tool.name === 'set_develop_settings'),
    );
  }, CLI_TEST_MS);

  it('refuses discovery of a tool its toolset does not enable', async () => {
    const disabled = await run(['tools', 'set_develop_settings']);
    expect(disabled.code).toBe(1);
    expect(disabled.stdout).toBe('');
    expect(disabled.stderr).toContain('not available');
  }, CLI_TEST_MS);

  it('uses the same read-only discovery policy as MCP', async () => {
    const result = await run(['tools'], { LIGHTROOM_AGENT_TOOLSETS: 'all', LIGHTROOM_AGENT_READ_ONLY: 'true' });
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual(listToolsHandler(new Set(['core', 'develop', 'masks']), true));
  }, CLI_TEST_MS);

  it('reports invalid call syntax with exit 2 before connection', async () => {
    const result = await run(['call', 'search_photos', '[]']);
    expect(result.code).toBe(2);
    expect(result.stdout).toBe('');
    expect(result.stderr).toContain('JSON object');
  }, CLI_TEST_MS);

  it('returns the complete preview response and exits after releasing its connection', async () => {
    const pixels = Buffer.alloc(200 * 150 * 4);
    for (let i = 0; i < pixels.length; i++) pixels[i] = (i * 7919) % 251;
    const image = jpeg.encode({ width: 200, height: 150, data: pixels }, 100).data.toString('base64');
    expect(image.length).toBeGreaterThan(80_000);
    const called: string[] = [];
    const env = await startPlugin((action, params) => {
      called.push(action);
      if (action === 'ping') return { pong: true, version: VERSION, build: BUILD };
      expect(params).toEqual({ photo_ids: ['914'], size: 864 });
      return { photo_id: 914, image: { data: image, mime_type: 'image/jpeg' } };
    });
    const result = await run(['call', 'get_photo_preview', '{"photo_id":"914"}'], env);
    expect(result.code).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({ content: [
      { type: 'text', text: JSON.stringify({ outcome: 'done', data: { photo_id: '914', requested_size: 864,
        width: 200, height: 150, bytes: Buffer.from(image, 'base64').length, scaled_by_server: false } }) },
      { type: 'image', data: image, mimeType: 'image/jpeg' },
    ] });
    expect(called).toContain('render_preview');
    const configDir = path.join(result.testHome, '.config', 'lightroom-agent');
    expect(fs.readdirSync(configDir)).toEqual([]);
    expect(fs.existsSync(brokerPath(Number(env.LIGHTROOM_AGENT_REQUEST_PORT), Number(env.LIGHTROOM_AGENT_RESPONSE_PORT), configDir))).toBe(false);
  }, CLI_TEST_MS);

  it('refuses a call, sending nothing, while the plug-in is of another version', async () => {
    const called: string[] = [];
    const env = await startPlugin((action) => {
      called.push(action);
      return { pong: true, version: '0.0.1' };
    });
    const result = await run(['call', 'list_collections'], env);
    expect(result.code).toBe(1);
    expect(result.stdout).toContain(`The installed Lightroom plug-in is version 0.0.1, and this server is version ${VERSION}.`);
    expect(called).not.toContain('list_collections');
  }, CLI_TEST_MS);

  it('returns the backend error as JSON with a failing exit status', async () => {
    const env = await startPlugin((action) => {
      if (action === 'ping') return { pong: true, version: VERSION, build: BUILD };
      throw new Error('Missing catalog fixture');
    });
    const result = await run(['call', 'list_collections'], env);
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout)).toEqual({
      isError: true, content: [{ type: 'text', text: '{"outcome":"failed","error":"Missing catalog fixture"}' }],
    });
  }, CLI_TEST_MS);

  it.each([
    ['read-only', 'set_rating_and_flag', '{"photo_ids":["914"],"rating":5}', { LIGHTROOM_AGENT_READ_ONLY: 'true' }],
    ['toolset', 'set_develop_settings', '{"photo_id":"914","settings":{"Exposure2012":1}}', {}],
  ])('refuses %s writes before starting the bridge', async (_label, name, args, settings) => {
    const env = await startPlugin(() => { throw new Error('Must not reach plugin'); });
    const result = await run(['call', name as string, args as string], { ...env, ...settings as NodeJS.ProcessEnv });
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout)).toMatchObject({ isError: true });
    expect(plugin?.events.some((event) => event.kind === 'request_connected')).toBe(false);
    expect(fs.readdirSync(result.testHome)).toEqual([]);
  }, CLI_TEST_MS);


  it('refuses an unpublished tool before starting the bridge', async () => {
    const env = await startPlugin(() => ({ success: true }));
    const result = await run(['call', 'not_a_tool', '{}'], { ...env, LIGHTROOM_AGENT_TOOLSETS: 'all' });
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout)).toEqual({
      isError: true, content: [{ type: 'text', text: JSON.stringify({
        outcome: 'failed', error: 'Unknown tool "not_a_tool". Only listed tools can be called.',
      }) }],
    });
    expect(plugin?.events.some((event) => event.kind === 'request_connected')).toBe(false);
    expect(fs.readdirSync(result.testHome)).toEqual([]);
  }, CLI_TEST_MS);

  const signalTest = process.platform === 'win32' ? it.skip : it;
  signalTest.each([['SIGINT', 130], ['SIGTERM', 143]] as const)(
    'does not report success when %s interrupts an in-flight call',
    async (signal, expectedCode) => {
      let entered: () => void = () => {};
      const ready = new Promise<void>((resolve) => { entered = resolve; });
      let finish: () => void = () => {};
      const pending = new Promise<void>((resolve) => { finish = resolve; });
      const env = await startPlugin(async (action) => {
        if (action === 'ping') return { pong: true, version: VERSION, build: BUILD };
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
    CLI_TEST_MS,
  );

  it('answers version and tools from a build whose plug-in folder does not match it', async () => {
    const dist = checkout(STALE_LUA);

    expect((await run(['--version'], {}, undefined, { dist })).stdout).toBe(`${VERSION}\n`);
    const tools = await run(['tools'], {}, undefined, { dist });
    expect(tools.code).toBe(0);
    expect(JSON.parse(tools.stdout)).toEqual(listToolsHandler(new Set(['core']), false));
  }, CLI_TEST_MS);

  it('refuses install-plugin from a build whose plug-in folder does not match it, installing nothing', async () => {
    const result = await run(['install-plugin'], {}, undefined, { dist: checkout(STALE_LUA) });

    expect(result.code).toBe(1);
    expect(result.stderr).toContain(REBUILD);
  }, CLI_TEST_MS);

  it('answers every call of a server unpaired from its plug-in folder with its reason, taking no lock, '
    + 'and a paired server started afterwards leads', async () => {
    const env = await startPlugin((action) => (action === 'ping' ? { pong: true, version: VERSION, build: BUILD } : { collections: [] }));
    const home = newState();
    const unpaired = await stdio(checkout(STALE_LUA), home, env);

    const refused = await unpaired.call('list_collections');

    expect(refused).toEqual({ isError: true, content: [{ type: 'text', text: JSON.stringify({ outcome: 'failed', error: REBUILD }) }] });
    expect(plugin?.events.some((event) => event.kind === 'request_connected')).toBe(false);
    expect(fs.existsSync(path.join(home.testHome, '.config', 'lightroom-agent'))).toBe(false);
    const paired = await run(['call', 'list_collections'], env, undefined, { dist: checkout(), home });
    expect(paired.code).toBe(0);
    expect(JSON.parse(paired.stdout)).toMatchObject({ content: [{ text: expect.stringContaining('"outcome":"done"') }] });
  }, CLI_TEST_MS);

  it('stops electing, with its reason, a follower whose plug-in folder changed before its promotion; '
    + 'a paired server then leads', async () => {
    const env = await startPlugin((action) => (action === 'ping' ? { pong: true, version: VERSION, build: BUILD } : { collections: [] }));
    const home = newState();
    const leader = await stdio(checkout(), home, env);
    expect(JSON.stringify(await leader.call('list_collections'))).toContain('done');
    let followerTree: { dist: string; bundle: string } | undefined;
    const follower = await stdio(checkout((tree) => { followerTree = tree; }), home, env);
    expect(JSON.stringify(await follower.call('list_collections'))).toContain('done');
    STALE_LUA(followerTree!);
    const connections = () => plugin!.events.filter((event) => event.kind === 'request_connected').length;
    expect(connections()).toBe(1);

    await closeClient(leader.client);
    await new Promise((resolve) => setTimeout(resolve, 1_500));

    expect(await follower.call('list_collections')).toEqual({
      isError: true, content: [{ type: 'text', text: JSON.stringify({ outcome: 'failed', error: REBUILD }) }],
    });
    expect(connections()).toBe(1);
    const next = await run(['call', 'list_collections'], env, undefined, { dist: checkout(), home });
    expect(next.code).toBe(0);
    expect(connections()).toBe(2);
  }, CLI_TEST_MS);

  it('keeps a build paired after a compiled change outside the contract, as another server build, and refuses '
    + 'one whose compiled contract no longer matches its plug-in folder', async () => {
    const env = await startPlugin((action) => (action === 'ping' ? { pong: true, version: VERSION, build: BUILD } : { collections: [] }));
    const original = serverIdentity(build, BUILD);
    const touched = checkout(({ dist }) => fs.appendFileSync(path.join(dist, 'cli.js'), '\n'));
    expect(serverIdentity(touched, BUILD).build).not.toBe(original.build);
    expect((await run(['call', 'list_collections'], env, undefined, { dist: touched })).code).toBe(0);

    const contract = checkout(({ dist }) => {
      const file = path.join(dist, 'tool-contracts.js');
      fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace(/DEFAULT_PAGE_LIMIT = \d+/, 'DEFAULT_PAGE_LIMIT = 7'));
    });
    const refused = await run(['call', 'list_collections'], env, undefined, { dist: contract });
    expect(refused.code).toBe(1);
    expect(JSON.parse(refused.stdout)).toEqual({ isError: true, content: [{ type: 'text', text: JSON.stringify({ outcome: 'failed', error: REBUILD }) }] });
  }, CLI_TEST_MS);

  it('validates arguments through the common backend without dispatching the operation', async () => {
    const called: string[] = [];
    const env = await startPlugin((action) => { called.push(action); return { pong: true, version: VERSION, build: BUILD }; });
    const result = await run(['call', 'search_photos', '{"unexpected":true}'], env);
    expect(result.code).toBe(1);
    expect(JSON.parse(result.stdout)).toMatchObject({ isError: true });
    expect(result.stdout).toContain('unknown property');
    expect(called).not.toContain('search_photos');
  }, CLI_TEST_MS);
});
