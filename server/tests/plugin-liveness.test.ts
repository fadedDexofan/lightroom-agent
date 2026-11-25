import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { envelopeOf } from './helpers/envelope.js';
import { PluginLiveness } from '../src/plugin-liveness.js';
import type { Dispatcher } from '../src/dispatcher.js';
import { SHADOW_BRIDGE } from '../src/port-owner.js';
import { createCallToolHandler } from '../src/tool-handler.js';

type Ping = { timeoutMs: number; answer: (version?: string | null, build?: string) => void; fail: () => void };

const INSTALL_FIX =
  "Lightroom has loaded a different plug-in build. If the intended build was installed or repaired, restart Lightroom to load it. Otherwise quit the connected clients, run this build's install-plugin, check its result, restart Lightroom, and reconnect.";

const SERVER_VERSION = '1.2.3';
const SERVER_BUILD = '0123456789abcdef';

function setup(opts: { connected?: () => boolean } = {}) {
  const pings: Ping[] = [];
  const dispatcher: Pick<Dispatcher, 'call'> = {
    call: (action, params, timeoutMs) => {
      expect([action, params]).toEqual(['ping', {}]);
      return new Promise((resolve, reject) => {
        pings.push({
          timeoutMs,
          answer: (version = SERVER_VERSION, build = SERVER_BUILD) =>
            resolve({
              id: 'ping',
              result: { data: version === null ? { pong: true } : { pong: true, version, build } },
            }),
          fail: () => reject(new Error('timeout')),
        });
      });
    },
  };
  const reporter = { report: vi.fn(), clear: vi.fn() };
  const liveness = new PluginLiveness({
    dispatcher,
    connected: opts.connected ?? (() => true),
    reporter,
    heartbeatIntervalMs: 30_000,
    heartbeatTimeoutMs: 10_000,
    probeTimeoutMs: 5_000,
    recoveryIntervalMs: 5_000,
    plugin: { version: SERVER_VERSION, build: SERVER_BUILD },
  });
  return { liveness, pings, reporter };
}

const flush = async () => {
  for (let i = 0; i < 5; i++) await Promise.resolve();
};

describe('PluginLiveness', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('admits no call on a connection before a ping settles', () => {
    const { liveness } = setup();

    expect(liveness.admitted()).toBeNull();
  });

  it('becomes unusable once a probe fails, reports it, and re-probes until one succeeds', async () => {
    const { liveness, pings, reporter } = setup();

    liveness.check();
    pings[0].fail();
    await flush();
    expect(liveness.admitted()).toBeNull();
    expect(reporter.report).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(5_000);
    expect(pings).toHaveLength(2);
    pings[1].answer();
    await flush();
    expect(liveness.admitted()).not.toBeNull();
    expect(reporter.clear).toHaveBeenCalled();

    vi.advanceTimersByTime(20_000);
    expect(pings).toHaveLength(2);
  });

  it('starts the same recovery re-probe when a heartbeat ping fails', async () => {
    const { liveness, pings, reporter } = setup();
    liveness.start();

    vi.advanceTimersByTime(30_000);
    expect(pings.map((ping) => ping.timeoutMs)).toEqual([10_000]);
    pings[0].fail();
    await flush();
    expect(liveness.admitted()).toBeNull();
    expect(reporter.report).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(5_000);
    expect(pings.map((ping) => ping.timeoutMs)).toEqual([10_000, 5_000]);
    pings[1].answer();
    await flush();
    expect(liveness.admitted()).not.toBeNull();
    liveness.stop();
  });

  it('sends no heartbeat ping while a probe is in flight, so the probe verdict stands', async () => {
    const { liveness, pings } = setup();
    liveness.start();

    liveness.check();
    vi.advanceTimersByTime(30_000);
    expect(pings).toHaveLength(1);
    pings[0].answer();
    await flush();

    expect(liveness.admitted()).not.toBeNull();
    liveness.stop();
  });

  it('sends no heartbeat ping while the sockets are down, so the connect probe is not swallowed', async () => {
    let connected = false;
    const { liveness, pings } = setup({ connected: () => connected });
    liveness.start();

    vi.advanceTimersByTime(30_000);
    expect(pings).toHaveLength(0);

    connected = true;
    liveness.check();
    expect(pings.map((ping) => ping.timeoutMs)).toEqual([5_000]);
    pings[0].answer();
    await flush();
    expect(liveness.admitted()).not.toBeNull();
    liveness.stop();
  });

  it('makes callers wait for an in-flight probe instead of racing it', async () => {
    const { liveness, pings } = setup();
    liveness.check();

    let settled = false;
    const waiter = liveness.settled().then(() => {
      settled = true;
    });
    await flush();
    expect(settled).toBe(false);

    pings[0].fail();
    await waiter;

    expect(settled).toBe(true);
    expect(liveness.admitted()).toBeNull();
    liveness.reset();
  });

  it('discards a verdict from a connection already torn down', async () => {
    const { liveness, pings, reporter } = setup();
    liveness.check();

    liveness.reset();
    pings[0].fail();
    await flush();

    expect(liveness.admitted()).toBeNull();
    expect(reporter.report).not.toHaveBeenCalled();
  });

  it('blames no other bridge for a ping that failed because the sockets are down', async () => {
    let connected = true;
    const { liveness, pings, reporter } = setup({ connected: () => connected });
    liveness.start();

    vi.advanceTimersByTime(30_000);
    connected = false;
    pings[0].fail();
    await flush();

    expect(liveness.admitted()).toBeNull();
    expect(reporter.report).not.toHaveBeenCalled();
    liveness.stop();
  });

  it("accepts a plug-in that answers with the version and build of the server's bundled plug-in", async () => {
    const { liveness, pings } = setup();
    liveness.check();
    pings[0].answer();
    await flush();

    expect(liveness.admitted()).not.toBeNull();
    expect(liveness.incompatibility()).toBeNull();
  });

  it.each([
    ['1.2.2', 'version 1.2.2, build 0123456789abcdef'],
    [null, 'an older build that reports no version'],
  ])('refuses a plug-in that answers with version %o, naming both and the fix', async (version, loaded) => {
    const { liveness, pings, reporter } = setup();
    liveness.check();
    pings[0].answer(version);
    await flush();

    expect(liveness.admitted()).toBeNull();
    expect(liveness.incompatibility()).toBe(
      `${INSTALL_FIX} Loaded: ${loaded}; this server's: version 1.2.3, build 0123456789abcdef.`,
    );
    expect(reporter.report).not.toHaveBeenCalled();
  });

  it('refuses a plug-in of the same version but another build, naming both builds and the fix', async () => {
    const { liveness, pings } = setup();
    liveness.check();
    pings[0].answer(SERVER_VERSION, 'fedcba9876543210');
    await flush();

    expect(liveness.admitted()).toBeNull();
    expect(liveness.incompatibility()).toBe(
      `${INSTALL_FIX} Loaded: version 1.2.3, build fedcba9876543210; this server's: version 1.2.3, build 0123456789abcdef.`,
    );
  });

  it('becomes usable once a later ping answers with the server version', async () => {
    const { liveness, pings } = setup();
    liveness.start();
    liveness.check();
    pings[0].answer('1.2.2');
    await flush();

    vi.advanceTimersByTime(30_000);
    pings[1].answer();
    await flush();

    expect(liveness.admitted()).not.toBeNull();
    liveness.stop();
  });

  it('does not block when no probe is in flight', async () => {
    const { liveness } = setup();

    await expect(liveness.settled()).resolves.toBeUndefined();
  });

  it('returns to unknown on reset and stops re-probing', async () => {
    const { liveness, pings } = setup();
    liveness.check();
    pings[0].fail();
    await flush();

    liveness.reset();
    vi.advanceTimersByTime(60_000);

    expect(liveness.admitted()).toBeNull();
    expect(pings).toHaveLength(1);
  });

  it('stops pinging once stopped', () => {
    const { liveness, pings } = setup();
    liveness.start();

    liveness.stop();
    vi.advanceTimersByTime(90_000);

    expect(pings).toHaveLength(0);
  });
});

describe('tool handler readiness message', () => {
  const dispatcher = { call: vi.fn(() => Promise.resolve({ id: 'req_1', result: {} })) };

  it('explains that another bridge owns the plugin when sockets are up but silent', async () => {
    const handler = createCallToolHandler({
      dispatcher,
      admitted: () => null,
      notReadyMessage: () => SHADOW_BRIDGE.message,
    });

    const res = await handler('get_selected_photos', {});

    expect(res.isError).toBe(true);
    expect(envelopeOf(res)).toEqual({ outcome: 'failed', error: SHADOW_BRIDGE.message });
    expect(dispatcher.call).not.toHaveBeenCalled();
  });

  it('waits for readiness to settle before dispatching a call', async () => {
    const { liveness, pings } = setup();
    liveness.check();
    const call = vi.fn(() => Promise.resolve({ id: 'req_1', result: {} }));
    const handler = createCallToolHandler({
      dispatcher: { call },
      admitted: () => liveness.admitted(),
      notReadyMessage: () => SHADOW_BRIDGE.message,
      settleReadiness: () => liveness.settled(),
    });

    const pending = handler('get_selected_photos', {});
    await flush();
    expect(call).not.toHaveBeenCalled();

    pings[0].fail();
    const res = await pending;

    expect(res.isError).toBe(true);
    expect(envelopeOf(res)).toEqual({ outcome: 'failed', error: SHADOW_BRIDGE.message });
    expect(call).not.toHaveBeenCalled();
    liveness.reset();
  });
});
