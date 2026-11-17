import { describe, it, expect, afterEach } from '@jest/globals';
import net from 'node:net';
import { PluginSocket } from '../src/plugin-socket.js';

function listenOnFreePort(target: net.Server): Promise<number> {
  return new Promise((resolve) => {
    target.listen(0, '127.0.0.1', () => {
      const addr = target.address();
      resolve(typeof addr === 'object' && addr ? addr.port : 0);
    });
  });
}

function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.listen(0, () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close(() => resolve(port));
    });
  });
}

function waitFor(check: () => boolean, timeoutMs = 2000): Promise<void> {
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

describe('PluginSocket', () => {
  let server: net.Server | null = null;
  let port: number;
  let serverConn: net.Socket | null = null;
  let socket: PluginSocket | null = null;

  afterEach(async () => {
    socket?.stop();
    socket = null;
    serverConn?.destroy();
    serverConn = null;
    if (server) {
      await new Promise<void>((resolve) => server!.close(() => resolve()));
      server = null;
    }
  });

  it('reports not connected before plugin listens', async () => {
    port = await freePort();
    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();
    expect(socket.isConnected()).toBe(false);
    expect(socket.send('hello')).toBe(false);
  });

  it('connects once plugin starts listening, sends newline-framed messages', async () => {
    port = await freePort();
    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();

    const received: string[] = [];
    server = net.createServer((conn) => {
      serverConn = conn;
      let buf = '';
      conn.setEncoding('utf8');
      conn.on('data', (chunk: string) => {
        buf += chunk;
        let idx;
        while ((idx = buf.indexOf('\n')) !== -1) {
          received.push(buf.slice(0, idx));
          buf = buf.slice(idx + 1);
        }
      });
    });
    await new Promise<void>((resolve) => server!.listen(port, '127.0.0.1', () => resolve()));

    await waitFor(() => socket!.isConnected());
    expect(socket.send('{"id":"a","action":"ping"}')).toBe(true);
    expect(socket.send('{"id":"b","action":"pong"}')).toBe(true);

    await waitFor(() => received.length >= 2);
    expect(received).toEqual(['{"id":"a","action":"ping"}', '{"id":"b","action":"pong"}']);
  });

  it('parses incoming newline-delimited lines including split chunks', async () => {
    const lines: string[] = [];
    server = net.createServer((conn) => {
      serverConn = conn;
      // Send across two chunks split mid-message
      conn.write('{"id":"1","resu');
      setTimeout(() => conn.write('lt":42}\n{"id":"2","result":"x"}\n'), 20);
    });
    port = await listenOnFreePort(server);
    socket = new PluginSocket({
      port,
      label: 'test',
      reconnectDelayMs: 50,
      onLine: (line) => lines.push(line),
      log: () => {},
    });
    socket.connect();

    await waitFor(() => lines.length >= 2);
    expect(lines).toEqual(['{"id":"1","result":42}', '{"id":"2","result":"x"}']);
  });

  it('reconnects after the plugin closes the connection', async () => {
    let connectionCount = 0;
    server = net.createServer((conn) => {
      connectionCount++;
      serverConn = conn;
      if (connectionCount === 1) {
        // Drop first connection immediately
        setTimeout(() => conn.destroy(), 30);
      }
    });
    port = await listenOnFreePort(server);

    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();

    await waitFor(() => connectionCount >= 2, 3000);
    expect(connectionCount).toBeGreaterThanOrEqual(2);
  });

  it('fires onConnect after connecting; first send goes out before later sends', async () => {
    const received: string[] = [];
    server = net.createServer((conn) => {
      serverConn = conn;
      let buf = '';
      conn.setEncoding('utf8');
      conn.on('data', (chunk: string) => {
        buf += chunk;
        let idx;
        while ((idx = buf.indexOf('\n')) !== -1) {
          received.push(buf.slice(0, idx));
          buf = buf.slice(idx + 1);
        }
      });
    });
    port = await listenOnFreePort(server);

    socket = new PluginSocket({
      port,
      label: 'test',
      reconnectDelayMs: 50,
      log: () => {},
      onConnect: () => {
        socket!.send('{"hello":"tok"}');
      },
    });
    socket.connect();

    await waitFor(() => socket!.isConnected());
    expect(socket.send('{"id":"a","action":"ping"}')).toBe(true);

    await waitFor(() => received.length >= 2);
    expect(received[0]).toBe('{"hello":"tok"}');
    expect(received[1]).toBe('{"id":"a","action":"ping"}');
  });

  it('stop() prevents further reconnects', async () => {
    let connectionCount = 0;
    server = net.createServer((conn) => {
      connectionCount++;
      conn.destroy();
    });
    port = await listenOnFreePort(server);

    socket = new PluginSocket({ port, label: 'test', reconnectDelayMs: 50, log: () => {} });
    socket.connect();
    await waitFor(() => connectionCount >= 1);
    socket.stop();

    const countAtStop = connectionCount;
    await new Promise((r) => setTimeout(r, 200));
    expect(connectionCount).toBe(countAtStop);
  });
});
