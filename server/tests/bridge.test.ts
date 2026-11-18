import { describe, it, expect, afterEach } from '@jest/globals';
import { createCallToolHandler } from '../src/tool-handler.js';
import type { PluginResponse } from '../src/dispatcher.js';
import { envelopeOf } from './helpers/envelope.js';
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { Bridge, NO_OWNER_MESSAGE, unreachableOwnerMessage, type Leader } from '../src/bridge.js';
import { BrokerClient, BrokerServer, MAX_FRAME_BYTES, NOT_CONNECTED_TO_OWNER_MESSAGE, OWNER_LOST_MESSAGE, brokerPath, signNonce, type ToolCaller } from '../src/broker.js';
import { acquireInstanceLock, LockHeldError, type InstanceLock } from '../src/instance-lock.js';
import type { ToolResponse } from '../src/tool-result.js';
import type { ServerIdentity } from '../src/server-identity.js';
import { PairingLost } from '../src/plugin-pairing.js';

const SERVER: ServerIdentity = { version: '1.0.0', build: 's1', plugin: 'b1' };

function errorText(resp: ToolResponse): string {
  return String(envelopeOf(resp).error);
}

function text(resp: ToolResponse): string {
  return resp.content[0]?.text ?? '';
}

function ok(body: string): ToolResponse {
  return { content: [{ type: 'text', text: body }] };
}

function waitFor(check: () => boolean, timeoutMs = 3000): Promise<void> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const tick = () => {
      if (check()) return resolve();
      if (Date.now() - start > timeoutMs) return reject(new Error('waitFor timeout'));
      setTimeout(tick, 10);
    };
    tick();
  });
}

const tmpDirs: string[] = [];
function tmpDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-'));
  tmpDirs.push(dir);
  return dir;
}

const isWindows = process.platform === 'win32';
const unixOnly = isWindows ? it.skip : it;

function ipcPath(dir: string): string {
  if (isWindows) return `\\\\.\\pipe\\${path.basename(dir)}`;
  return brokerPath(58763, 58764, dir);
}

afterEach(() => {
  while (tmpDirs.length > 0) {
    fs.rmSync(tmpDirs.pop()!, { recursive: true, force: true });
  }
});

describe('brokerPath', () => {
  it('uses a named pipe on Windows', () => {
    expect(brokerPath(1, 2, '/x', 'win32')).toMatch(/^\\\\\.\\pipe\\lightroom-agent-.+-bridge-1-2$/);
  });

  it('uses a socket in the config dir when the path fits', () => {
    expect(brokerPath(1, 2, '/cfg', 'darwin')).toBe(path.join('/cfg', 'bridge-1-2.sock'));
  });

  it('measures the socket path in bytes, not characters', () => {
    const p = brokerPath(1, 2, '/' + 'ż'.repeat(45), 'darwin');
    expect(p.startsWith(os.tmpdir())).toBe(true);
  });

  it('falls back to the temp dir when the config path is too long for a Unix socket', () => {
    const long = '/' + 'a'.repeat(120);
    const p = brokerPath(1, 2, long, 'linux');
    expect(p.startsWith(os.tmpdir())).toBe(true);
    expect(p).toMatch(/bridge-1-2\.sock$/);
  });
});

describe('broker', () => {
  const closers: Array<() => void> = [];
  afterEach(() => {
    while (closers.length > 0) closers.pop()!();
  });

  async function serve(
    callTool: (name: string, args: unknown) => Promise<ToolResponse>,
    token: string | null = 't',
    log: (msg: string) => void = () => {},
    identity: ServerIdentity = SERVER,
  ) {
    const p = ipcPath(tmpDir());
    const server = new BrokerServer({ server: identity, path: p, callTool, readToken: () => token, log });
    await server.listen();
    closers.push(() => server.close());
    return { p, server };
  }

  async function connect(p: string, token: string | null = 't', onClose?: () => void) {
    const client = new BrokerClient({ server: SERVER, path: p, readToken: () => token, onClose });
    await client.connect();
    closers.push(() => client.close());
    return client;
  }

  async function rawHandshake(p: string, token: string, server?: unknown) {
    const sock = net.createConnection(p);
    closers.push(() => sock.destroy());
    sock.setEncoding('utf8');
    const lines: string[] = [];
    let buffer = '';
    sock.on('data', (chunk: string) => {
      buffer += chunk;
      let idx: number;
      while ((idx = buffer.indexOf('\n')) !== -1) {
        lines.push(buffer.slice(0, idx));
        buffer = buffer.slice(idx + 1);
      }
    });
    await new Promise<void>((resolve) => sock.once('connect', () => resolve()));
    sock.write(JSON.stringify({ challenge: 'c', server }) + '\n');
    await waitFor(() => lines.length > 0);
    const hello = JSON.parse(lines.shift()!) as { nonce: string; proof: string };
    expect(hello.proof).toBe(signNonce(token, 'owner:c'));
    return { sock, hello, lines };
  }

  async function serveRawOwner(server?: unknown): Promise<string> {
    const p = ipcPath(tmpDir());
    const owner = net.createServer((sock) => {
      sock.setEncoding('utf8');
      sock.once('data', (line: string) => {
        const { challenge } = JSON.parse(line) as { challenge: string };
        sock.write(JSON.stringify({ nonce: 'n', proof: signNonce('t', `owner:${challenge}`), server }) + '\n');
      });
    });
    await new Promise<void>((resolve) => owner.listen(p, () => resolve()));
    closers.push(() => owner.close());
    return p;
  }

  const refusal = (differences: string) => 'This server and the server that owns the Lightroom connection differ in '
    + `${differences}, so nothing was sent. Use one lightroom-agent build in every client, then restart them.`;

  it.each([
    [{ ...SERVER, build: 's2' }, 'server build (s1 here, s2 there)'],
    [{ ...SERVER, version: '0.9.0', build: 's0' }, 'version (1.0.0 here, 0.9.0 there), server build (s1 here, s0 there)'],
  ])('refuses a follower\'s calls, sending nothing, while the owner is another server build (%o)', async (owner, described) => {
    const calls: string[] = [];
    const { p } = await serve(async (name) => { calls.push(name); return ok('x'); }, 't', () => {}, owner);
    const client = await connect(p);

    const resp = await client.callTool('list_masks', {});

    expect(envelopeOf(resp).outcome).toBe('failed');
    expect(errorText(resp)).toBe(refusal(described));
    expect(calls).toEqual([]);
  });

  it.each([
    ['carries no identity', undefined],
    ['carries an identity without a build', { version: '1.0.0' }],
  ])('refuses a follower\'s calls when the owner\'s greeting %s', async (_what, server) => {
    const client = await connect(await serveRawOwner(server));

    const resp = await client.callTool('list_masks', {});

    expect(errorText(resp)).toBe(refusal(server === undefined
      ? 'version (1.0.0 here, none there), server build (s1 here, none there), plug-in build (b1 here, none there)'
      : 'server build (s1 here, none there), plug-in build (b1 here, none there)'));
  });

  it('answers an older follower whose hello carries no identity with the refusal, never calling the tool', async () => {
    const calls: string[] = [];
    const { p } = await serve(async (name) => { calls.push(name); return ok('x'); });
    const { sock, hello, lines } = await rawHandshake(p, 't');

    sock.write(JSON.stringify({ id: 1, auth: signNonce('t', `follower:${hello.nonce}`), name: 'list_masks', args: {} }) + '\n');
    await waitFor(() => lines.length > 0);

    const reply = JSON.parse(lines.shift()!) as { result: ToolResponse };
    expect(errorText(reply.result)).toBe(
      refusal('version (none here, 1.0.0 there), server build (none here, s1 there), plug-in build (none here, b1 there)'));
    expect(calls).toEqual([]);
  });

  it.each([
    ['of another plug-in build', { ...SERVER, plugin: 'b2' }, 'plug-in build (b2 here, b1 there)'],
    ['without a plug-in build', { version: SERVER.version, build: SERVER.build }, 'plug-in build (none here, b1 there)'],
  ])('refuses, never calling the tool, a follower whose hello names a server %s', async (_what, follower, differences) => {
    const calls: string[] = [];
    const { p } = await serve(async (name) => { calls.push(name); return ok('x'); });
    const { sock, hello, lines } = await rawHandshake(p, 't', follower);

    sock.write(JSON.stringify({ id: 1, auth: signNonce('t', `follower:${hello.nonce}`), name: 'list_masks', args: {} }) + '\n');
    await waitFor(() => lines.length > 0);

    const reply = JSON.parse(lines.shift()!) as { result: ToolResponse };
    expect(envelopeOf(reply.result).outcome).toBe('failed');
    expect(errorText(reply.result)).toBe(refusal(differences));
    expect(calls).toEqual([]);
  });

  it.each([
    ['of another plug-in build', { ...SERVER, plugin: 'b2' }, 'plug-in build (b1 here, b2 there)'],
    ['without a plug-in build', { version: SERVER.version, build: SERVER.build }, 'plug-in build (b1 here, none there)'],
  ])('refuses a follower\'s calls, sending nothing, when the owner\'s greeting names a server %s', async (_what, owner, differences) => {
    const client = await connect(await serveRawOwner(owner));

    const resp = await client.callTool('list_masks', {});

    expect(envelopeOf(resp).outcome).toBe('failed');
    expect(errorText(resp)).toBe(refusal(differences));
  });

  it('queues a forwarded Develop call behind a Develop call of the owning bridge', async () => {
    const pending: Array<{ action: string; resolve: (reply: PluginResponse) => void }> = [];
    const handler = createCallToolHandler({ admitted: () => 0, dispatcher: {
      call: async (action: string) => new Promise<PluginResponse>((resolve) => { pending.push({ action, resolve }); }),
    } });
    const { p } = await serve((name, args) => handler(name, args));
    const client = await connect(p);

    const own = handler('set_develop_settings', { photo_id: 1, settings: { Exposure2012: 0.1 } });
    const forwarded = client.callTool('list_spots', { photo_id: 2 });
    await waitFor(() => pending.length > 0);
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(pending.map((entry) => entry.action)).toEqual(['write_develop_settings']);
    pending[0].resolve({ id: '1', result: { data: {} } });
    await own;
    await waitFor(() => pending.length > 1);
    expect(pending[1].action).toBe('list_spots');
    pending[1].resolve({ id: '2', result: { data: { spots: [] } } });
    expect(envelopeOf(await forwarded).outcome).toBe('done');
  });

  it('forwards tool calls and returns the owner response', async () => {
    const { p } = await serve(async (name, args) => ok(`${name}:${JSON.stringify(args)}`));
    const client = await connect(p);

    const [a, b] = await Promise.all([
      client.callTool('get_selection', {}),
      client.callTool('search_photos', { query: 'x' }),
    ]);

    expect(text(a)).toBe('get_selection:{}');
    expect(text(b)).toBe('search_photos:{"query":"x"}');
  });

  it('returns an error instead of dropping the connection for an oversized reply', async () => {
    const dir = tmpDir();
    const huge = 'x'.repeat(MAX_FRAME_BYTES + 1);
    const server = new BrokerServer({ server: SERVER, path: ipcPath(dir), callTool: async () => ok(huge), readToken: () => 't' });
    await server.listen();
    let closed = false;
    const client = new BrokerClient({ server: SERVER, path: ipcPath(dir), readToken: () => 't', onClose: () => { closed = true; } });
    await client.connect();

    const reply = await client.callTool('search_photos', {});

    expect(reply.isError).toBe(true);
    expect(errorText(reply)).toContain('too large');
    expect(closed).toBe(false);
    client.close();
    await server.close();
  });

  it('refuses to connect a follower whose token does not match', async () => {
    const { p } = await serve(async () => ok('done'));

    await expect(connect(p, 'wrong')).rejects.toThrow(/could not prove/);
    await expect(connect(p, null)).rejects.toThrow(/could not prove/);
  });

  it('rejects a call signed with the wrong token', async () => {
    const calls: string[] = [];
    const { p } = await serve(async (name) => {
      calls.push(name);
      return ok('done');
    });
    const { sock, hello, lines } = await rawHandshake(p, 't');

    sock.write(JSON.stringify({ id: 7, auth: signNonce('wrong', `follower:${hello.nonce}`), name: 'ping' }) + '\n');

    await waitFor(() => lines.length > 0);
    expect(JSON.parse(lines[0]!)).toMatchObject({ id: 7, result: { isError: true } });
    expect(lines[0]).toMatch(/token mismatch/);
    expect(calls).toEqual([]);
  });

  it('fails in-flight calls when the owner goes away', async () => {
    let release: (() => void) | undefined;
    const { p, server } = await serve(
      () => new Promise<ToolResponse>((resolve) => (release = () => resolve(ok('late')))),
    );
    let closed = false;
    const client = await connect(p, 't', () => (closed = true));

    const pending = client.callTool('export_photos', {});
    await waitFor(() => release !== undefined);
    server.close();

    const resp = await pending;
    expect(resp.isError).toBe(true);
    expect(errorText(resp)).toBe(OWNER_LOST_MESSAGE);
    expect(closed).toBe(true);
    expect(errorText(await client.callTool('ping', {}))).toBe(NOT_CONNECTED_TO_OWNER_MESSAGE);
    release?.();
  });

  it('reports when follower calls in flight have finished', async () => {
    let release: (() => void) | undefined;
    const { p, server } = await serve(
      () => new Promise<ToolResponse>((resolve) => (release = () => resolve(ok('late')))),
    );
    const client = await connect(p, 't');

    expect(await server.whenIdle(10)).toBe(true);
    const pending = client.callTool('export_photos', {});
    await waitFor(() => release !== undefined);
    expect(server.inFlightCalls()).toBe(1);
    expect(await server.whenIdle(20)).toBe(false);

    const idle = server.whenIdle(2000);
    release?.();
    expect(await idle).toBe(true);
    expect(text(await pending)).toBe('late');
    expect(server.inFlightCalls()).toBe(0);
  });

  unixOnly('replaces a stale socket file left by a dead owner', async () => {
    const p = ipcPath(tmpDir());
    fs.writeFileSync(p, '', { mode: 0o600, flag: 'wx' });
    const server = new BrokerServer({ server: SERVER, path: p, callTool: async () => ok('x'), readToken: () => 't' });
    await server.listen();
    closers.push(() => server.close());

    const client = await connect(p, 't');
    expect(text(await client.callTool('ping', {}))).toBe('x');
  });

  it('refuses a follower when neither side has a token', async () => {
    const calls: string[] = [];
    const { p } = await serve(async (name) => { calls.push(name); return ok('x'); }, null);
    const client = new BrokerClient({ server: SERVER, path: p, readToken: () => null });
    closers.push(() => client.close());

    await expect(client.connect()).rejects.toThrow(/could not prove/);
    expect(calls).toEqual([]);
  });

  it.each(['not json', 'null', '[]', '1', '"x"', '{"id":"1","name":"ping"}', '{"id":1,"name":"ping","auth":5}'])(
    'survives a malformed request line %s',
    async (line) => {
      const logs: string[] = [];
      const { p } = await serve(async () => ok('x'), 't', (m) => logs.push(m));
      const { sock } = await rawHandshake(p, 't');

      sock.write(line + '\n');

      await waitFor(() => logs.length > 0);
      expect(logs[0]).toMatch(/malformed request/);
      const client = await connect(p);
      expect(text(await client.callTool('ping', {}))).toBe('x');
    },
  );

  it('drops a follower that opens without a challenge', async () => {
    const logs: string[] = [];
    const { p } = await serve(async () => ok('x'), 't', (m) => logs.push(m));
    const sock = net.createConnection(p);
    closers.push(() => sock.destroy());
    const closed = new Promise<void>((resolve) => sock.once('close', () => resolve()));
    await new Promise<void>((resolve) => sock.once('connect', () => resolve()));

    sock.write('{"id":1,"name":"ping","auth":null}\n');

    await closed;
    expect(logs[0]).toMatch(/without a challenge/);
  });

  it('drops a peer that streams an oversized unterminated frame', async () => {
    const { p } = await serve(async () => ok('x'));
    const sock = net.createConnection(p);
    closers.push(() => sock.destroy());
    sock.on('error', () => {});
    const closed = new Promise<void>((resolve) => sock.once('close', () => resolve()));
    await new Promise<void>((resolve) => sock.once('connect', () => resolve()));

    sock.write('x'.repeat(4096));

    await closed;
  });

  it('refuses an impostor owner without leaking the token', async () => {
    const p = ipcPath(tmpDir());
    const received: string[] = [];
    const squatter = net.createServer((sock) => {
      sock.setEncoding('utf8');
      sock.on('data', (chunk: string) => {
        received.push(chunk);
        sock.write(JSON.stringify({ nonce: 'n', proof: 'forged' }) + '\n');
      });
    });
    await new Promise<void>((resolve) => squatter.listen(p, () => resolve()));
    closers.push(() => squatter.close());
    const client = new BrokerClient({ server: SERVER, path: p, readToken: () => 'secret-token' });

    await expect(client.connect()).rejects.toThrow(/could not prove/);
    expect(errorText(await client.callTool('ping', {}))).toBe(NOT_CONNECTED_TO_OWNER_MESSAGE);
    expect(received.join('')).not.toContain('secret-token');
  });

  it('gives up on an owner that never greets', async () => {
    const p = ipcPath(tmpDir());
    const silent = net.createServer(() => {});
    await new Promise<void>((resolve) => silent.listen(p, () => resolve()));
    closers.push(() => silent.close());
    const client = new BrokerClient({ server: SERVER, path: p, readToken: () => null, helloTimeoutMs: 50 });

    await expect(client.connect()).rejects.toThrow(/did not greet/);
    expect(errorText(await client.callTool('ping', {}))).toBe(NOT_CONNECTED_TO_OWNER_MESSAGE);
  });

  it('gives up on an owner that hangs up before greeting', async () => {
    const p = ipcPath(tmpDir());
    const rude = net.createServer((sock) => sock.destroy());
    await new Promise<void>((resolve) => rude.listen(p, () => resolve()));
    closers.push(() => rude.close());
    const client = new BrokerClient({ server: SERVER, path: p, readToken: () => null });

    await expect(client.connect()).rejects.toThrow();
  });
});

describe('Bridge', () => {
  const bridges: Bridge[] = [];
  afterEach(() => {
    while (bridges.length > 0) bridges.pop()!.stop();
  });

  function makeBridge(
    dir: string,
    label: string,
    started: string[],
    stopped: string[] = [],
    call?: ToolCaller,
  ) {
    const bridge = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: (): Leader => {
        started.push(label);
        return {
          callTool: call ?? (async (name) => ok(`${label}:${name}`)),
          stop: () => stopped.push(label),
        };
      },
      readToken: () => 'tok',
      retryMs: 20,
      readyWaitMs: 2000,
      log: () => {},
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(bridge);
    return bridge;
  }


  it('forwards progress and cancel from a follower across the broker', async () => {
    const dir = tmpDir();
    let cancelled = false;
    const a = makeBridge(dir, 'a', [], [], async (_name, _args, options) => {
      options?.onProgress?.({ progress: 1, total: 2, message: 'a.jpg' });
      await new Promise<void>((resolve) => options?.signal?.addEventListener('abort', () => {
        cancelled = true; resolve();
      }, { once: true }));
      return ok('stopped after first photo');
    });
    const b = makeBridge(dir, 'b', []);
    await a.start();
    await b.start();
    const controller = new AbortController();
    const progress: unknown[] = [];

    const pending = b.callTool('export_photos', {}, { signal: controller.signal, onProgress: (value) => {
      progress.push(value); controller.abort();
    } });

    expect(text(await pending)).toBe('stopped after first photo');
    expect(cancelled).toBe(true);
    expect(progress).toEqual([{ progress: 1, total: 2, message: 'a.jpg' }]);
  });

  it('lets a second bridge start and forwards its calls to the owner', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const a = makeBridge(dir, 'a', started);
    const b = makeBridge(dir, 'b', started);

    await a.start();
    await b.start();

    expect(started).toEqual(['a']);
    expect(text(await b.callTool('get_selection', {}))).toBe('a:get_selection');
    expect(text(await a.callTool('get_selection', {}))).toBe('a:get_selection');
  });

  it('promotes a follower when the owner exits', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const stopped: string[] = [];
    const a = makeBridge(dir, 'a', started, stopped);
    const b = makeBridge(dir, 'b', started, stopped);
    await a.start();
    await b.start();

    a.stop();

    await waitFor(() => started.includes('b'));
    expect(stopped).toEqual(['a']);
    expect(started).toEqual(['a', 'b']);
    expect(text(await b.callTool('ping', {}))).toBe('b:ping');
  });

  it('finishes calls from other bridges before shutting down', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const stopped: string[] = [];
    let release: (() => void) | undefined;
    const a = makeBridge(dir, 'a', started, stopped, (name) =>
      new Promise<ToolResponse>((resolve) => (release = () => resolve(ok(`a:${name}`)))),
    );
    const b = makeBridge(dir, 'b', started, stopped);
    await a.start();
    await b.start();

    const pending = b.callTool('apply_denoise', {});
    await waitFor(() => release !== undefined);
    const done = a.shutdown(2000);
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(stopped).toEqual([]);
    release?.();
    await done;
    expect(text(await pending)).toBe('a:apply_denoise');
    expect(stopped).toEqual(['a']);
    await waitFor(() => started.includes('b'));
  });

  it('gives up on calls from other bridges after the grace period', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const stopped: string[] = [];
    let called = false;
    const a = makeBridge(dir, 'a', started, stopped, () => {
      called = true;
      return new Promise<ToolResponse>(() => {});
    });
    const b = makeBridge(dir, 'b', started, stopped);
    await a.start();
    await b.start();

    const pending = b.callTool('export_photos', {});
    await waitFor(() => called);
    await a.shutdown(50);

    expect(errorText(await pending)).toBe(OWNER_LOST_MESSAGE);
    expect(stopped).toEqual(['a']);
  });

  it('shuts down at once when no call from another bridge is running', async () => {
    const dir = tmpDir();
    const stopped: string[] = [];
    const a = makeBridge(dir, 'a', [], stopped);
    const b = makeBridge(dir, 'b', [], stopped);
    await a.start();
    await b.start();
    expect(text(await b.callTool('ping', {}))).toBe('a:ping');

    const startedAt = Date.now();
    await a.shutdown(10_000);

    expect(Date.now() - startedAt).toBeLessThan(1000);
    expect(stopped).toEqual(['a']);
  });

  it('releases the lock and retries when the owner fails to start', async () => {
    const dir = tmpDir();
    let attempts = 0;
    const logs: string[] = [];
    const bridge = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => {
        attempts += 1;
        if (attempts === 1) throw new Error('boom');
        return { callTool: async () => ok('second'), stop: () => {} };
      },
      readToken: () => null,
      retryMs: 20,
      log: (m) => logs.push(m),
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(bridge);

    await bridge.start();

    await waitFor(() => attempts === 2);
    expect(logs[0]).toMatch(/failed to start as owner: boom/);
    expect(text(await bridge.callTool('ping', {}))).toBe('second');
  });

  it('answers its reason from then on, without electing again, once starting as owner finds its pairing lost', async () => {
    const dir = tmpDir();
    let attempts = 0;
    const bridge = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => {
        attempts += 1;
        throw new PairingLost('rebuild it');
      },
      readToken: () => 'tok',
      retryMs: 20,
      readyWaitMs: 60_000,
      log: () => {},
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(bridge);

    expect(errorText(await bridge.callTool('ping', {}))).toBe('rebuild it');
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(attempts).toBe(1);
    expect(errorText(await bridge.callTool('ping', {}))).toBe('rebuild it');
    const next = makeBridge(dir, 'next', []);
    expect(text(await next.callTool('ping', {}))).toBe('next:ping');
  });

  unixOnly('releases the lock without taking the plugin when it cannot serve other bridges', async () => {
    const dir = tmpDir();
    const blocked = path.join(dir, 'b.sock');
    fs.mkdirSync(blocked, { mode: 0o700 });
    fs.writeFileSync(path.join(blocked, 'keep'), '', { mode: 0o600, flag: 'wx' });
    const started: string[] = [];
    const logs: string[] = [];
    const bridge = new Bridge({
      server: SERVER,
      ipcPath: blocked,
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => {
        started.push('x');
        return { callTool: async () => ok('x'), stop: () => {} };
      },
      readToken: () => null,
      retryMs: 1000,
      log: (m) => logs.push(m),
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(bridge);

    await bridge.start();

    expect(started).toEqual([]);
    expect(logs[0]).toMatch(/failed to serve other bridges/);
    expect(() => acquireInstanceLock(58763, 58764, dir).release()).not.toThrow();
  });

  function fakeLock(): { lock: InstanceLock; lose: () => void } {
    let listener: (() => void) | null = null;
    return {
      lock: { release: () => {}, onLost: (l) => (listener = l) },
      lose: () => listener?.(),
    };
  }

  unixOnly('steps down when another bridge reclaims its lock', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const stopped: string[] = [];
    const stale = fakeLock();
    let electionsA = 0;
    const a = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => (electionsA++ === 0 ? stale.lock : acquireInstanceLock(58763, 58764, dir)),
      startLeader: () => {
        started.push('a');
        return { callTool: async (name) => ok(`a:${name}`), stop: () => stopped.push('a') };
      },
      readToken: () => 'tok',
      retryMs: 20,
      log: () => {},
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(a);
    await a.start();
    const b = makeBridge(dir, 'b', started, stopped);
    await b.start();
    expect(started).toEqual(['a', 'b']);

    stale.lose();

    await waitFor(() => stopped.includes('a'));
    expect(stopped).toEqual(['a']);
    expect(text(await a.callTool('ping', {}))).toBe('b:ping');
    expect(fs.existsSync(ipcPath(dir))).toBe(true);
    const c = makeBridge(dir, 'c', started);
    await c.start();
    expect(text(await c.callTool('ping', {}))).toBe('b:ping');
  });

  async function followHungOwner(
    dir: string,
    watch: { holderUnresponsive?: () => boolean; lockHolder?: () => number | null; hungPid?: number },
  ) {
    const hung = fakeLock();
    const a = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => hung.lock,
      startLeader: () => ({ callTool: () => new Promise<ToolResponse>(() => {}), stop: () => {} }),
      readToken: () => 'tok',
      log: () => {},
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(a);
    await a.start();
    let elections = 0;
    let leading = false;
    const logs: string[] = [];
    const b = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => {
        if (elections++ === 0) throw new LockHeldError(watch.hungPid ?? process.pid, 58763, 58764);
        return acquireInstanceLock(58763, 58764, dir);
      },
      startLeader: () => {
        leading = true;
        return { callTool: async (name) => ok(`b:${name}`), stop: () => {} };
      },
      readToken: () => 'tok',
      holderUnresponsive: watch.holderUnresponsive ?? (() => false),
      lockHolder: watch.lockHolder ?? (() => null),
      holderCheckMs: 10,
      retryMs: 20,
      log: (m) => logs.push(m),
    });
    bridges.push(b);
    await b.start();
    expect(leading).toBe(false);
    return { b, logs, elections: () => elections, leading: () => leading };
  }

  it('drops a hung owner once its heartbeat goes stale', async () => {
    let unresponsive = false;
    const { b, logs, elections } = await followHungOwner(tmpDir(), { holderUnresponsive: () => unresponsive });
    const stuck = b.callTool('export_photos', {});

    unresponsive = true;

    expect(errorText(await stuck)).toBe(OWNER_LOST_MESSAGE);
    await waitFor(() => elections() > 1);
    expect(logs).toContain('[bridge] owning bridge stopped responding, re-electing');
  });

  it('drops a hung owner once another follower has taken its lock', async () => {
    const hungPid = 111111;
    let holder = hungPid;
    const { b, logs, elections } = await followHungOwner(tmpDir(), {
      holderUnresponsive: () => false,
      lockHolder: () => holder,
      hungPid,
    });
    const stuck = b.callTool('export_photos', {});

    holder = 222222;

    expect(errorText(await stuck)).toBe(OWNER_LOST_MESSAGE);
    await waitFor(() => elections() > 1);
    expect(logs).toContain('[bridge] another bridge took over from the owning bridge, re-electing');
  });

  // A hung owner on Windows keeps its named pipe, so only Unix can take over its listener.
  unixOnly('takes over from a hung owner that still holds its listener', async () => {
    let unresponsive = false;
    const { b, leading } = await followHungOwner(tmpDir(), { holderUnresponsive: () => unresponsive });

    unresponsive = true;

    await waitFor(leading);
    expect(text(await b.callTool('ping', {}))).toBe('b:ping');
  });

  it('keeps forwarding through a single missed owner beat', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const a = makeBridge(dir, 'a', started);
    await a.start();
    let checks = 0;
    const b = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => ({ callTool: async () => ok('b'), stop: () => {} }),
      readToken: () => 'tok',
      holderUnresponsive: () => checks++ % 2 === 0,
      holderCheckMs: 10,
      log: () => {},
      lockHolder: () => null,
    });
    bridges.push(b);
    await b.start();

    await waitFor(() => checks >= 10);

    expect(text(await b.callTool('ping', {}))).toBe('a:ping');
  });

  it('elects on the first tool call when start was never called', async () => {
    const dir = tmpDir();
    const started: string[] = [];
    const a = makeBridge(dir, 'a', started);

    expect(text(await a.callTool('ping', {}))).toBe('a:ping');
    expect(started).toEqual(['a']);
  });

  it('names the lock holder when it does not serve other bridges', async () => {
    const dir = tmpDir();
    const lock = acquireInstanceLock(58763, 58764, dir);
    const bridge = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(dir),
      acquireLock: () => acquireInstanceLock(58763, 58764, dir),
      startLeader: () => ({ callTool: async () => ok('x'), stop: () => {} }),
      readToken: () => null,
      retryMs: 20,
      readyWaitMs: 50,
      log: () => {},
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(bridge);
    try {
      const resp = await bridge.callTool('ping', {});
      expect(resp.isError).toBe(true);
      expect(errorText(resp)).toBe(unreachableOwnerMessage(process.pid));
    } finally {
      lock.release();
    }
  });

  it('surfaces a lock error instead of a bare retry hint', async () => {
    const logs: string[] = [];
    const bridge = new Bridge({
      server: SERVER,
      ipcPath: ipcPath(tmpDir()),
      acquireLock: () => {
        throw new Error('EACCES: permission denied');
      },
      startLeader: () => ({ callTool: async () => ok('x'), stop: () => {} }),
      readToken: () => null,
      retryMs: 10,
      readyWaitMs: 100,
      log: (m) => logs.push(m),
      holderUnresponsive: () => false,
      lockHolder: () => null,
    });
    bridges.push(bridge);

    const resp = await bridge.callTool('ping', {});

    expect(errorText(resp)).toBe(`${NO_OWNER_MESSAGE} Last error: EACCES: permission denied`);
    expect(logs.filter((m) => m.includes('cannot take the bridge lock'))).toHaveLength(1);
  });
});
