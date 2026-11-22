import { describe, it, expect, beforeEach, jest } from '@jest/globals';
import { Dispatcher, PluginNotSentError, PluginTimeoutError } from '../src/dispatcher.js';

interface SentRequest {
  id: string;
  action: string;
  params: unknown;
}

const parseSent = (line: string): SentRequest => JSON.parse(line) as SentRequest;

describe('Dispatcher', () => {
  let sent: string[];
  let canSend: boolean;
  let dispatcher: Dispatcher;
  let logs: string[];

  beforeEach(() => {
    sent = [];
    canSend = true;
    logs = [];
    dispatcher = new Dispatcher({
      send: (line) => {
        if (!canSend) return false;
        sent.push(line);
        return true;
      },
      getToken: () => 'test-token',
      log: (msg) => logs.push(msg),
      connectionGeneration: () => 0,
    });
  });

  it('does not send a request with less than a second of its budget left', async () => {
    await expect(dispatcher.call('write_develop_settings', {}, 999)).rejects.toBeInstanceOf(PluginNotSentError);
    await expect(dispatcher.call('write_develop_settings', {}, -5)).rejects.toThrow(/was not sent/);
    expect(sent).toEqual([]);
  });

  it('sends the budget it waits for with every request', () => {
    void dispatcher.call('list_collections', {}, 1000).catch(() => {});
    void dispatcher.call('export_photos', {}, 300_000).catch(() => {});
    const budgets = sent.map((line) => (JSON.parse(line) as { budget_ms: number }).budget_ms);
    dispatcher.rejectPending('done');
    expect(budgets).toEqual([1000, 300_000]);
  });

  it.each(['null', '3', '"text"', '[]'])('ignores the non-object JSON line %s', (line) => {
    expect(() => dispatcher.handleResponseLine(line)).not.toThrow();
    expect(logs.at(-1)).toContain('Non-object JSON');
  });

  it('rejects every pending call with the given reason', async () => {
    const first = dispatcher.call('export_photos', {}, 1000);
    const second = dispatcher.call('ping', {}, 1000);

    dispatcher.rejectPending('connection lost');

    await expect(first).rejects.toThrow('connection lost');
    await expect(second).rejects.toThrow('connection lost');
    dispatcher.handleResponseLine(JSON.stringify({ id: parseSent(sent[0]).id, result: {} }));
    expect(logs.at(-1)).toContain('unknown id');
  });

  it('progress does not resolve a pending request or consume its final response', async () => {
    const progress: unknown[] = [];
    const pending = dispatcher.call('export_photos', {}, 1000, { onProgress: (value) => progress.push(value) });
    const id = parseSent(sent[0]).id;

    dispatcher.handleResponseLine(
      JSON.stringify({ progressFor: id, progress: { progress: 1, total: 2, message: 'a.jpg' } }),
    );

    expect(progress).toEqual([{ progress: 1, total: 2, message: 'a.jpg' }]);
    dispatcher.handleResponseLine(JSON.stringify({ id, result: { exported: 2 } }));
    expect((await pending).result).toEqual({ exported: 2 });
  });

  it('cancel names only its active request and ignores cancellation after completion', async () => {
    const controller = new AbortController();
    const pending = dispatcher.call('export_photos', {}, 1000, { signal: controller.signal });
    const id = parseSent(sent[0]).id;

    controller.abort();

    expect(JSON.parse(sent[1])).toEqual({ hello: 'test-token', action: 'cancel', params: { request_id: id } });
    dispatcher.handleResponseLine(JSON.stringify({ id, result: { exported: 1 } }));
    await pending;
    controller.abort();
    expect(sent).toHaveLength(2);
  });

  it('cancel after a finished call sends no control frame', async () => {
    const controller = new AbortController();
    const pending = dispatcher.call('export_photos', {}, 1000, { signal: controller.signal });
    const id = parseSent(sent[0]).id;
    dispatcher.handleResponseLine(JSON.stringify({ id, result: { exported: 1 } }));
    await pending;

    controller.abort();

    expect(sent).toHaveLength(1);
  });

  it('serializes the call as line-delimited JSON with id, action, params', async () => {
    const promise = dispatcher.call('list_collections', { foo: 'bar' }, 1000);
    expect(sent).toHaveLength(1);
    const sentObj = parseSent(sent[0]);
    expect(sentObj.action).toBe('list_collections');
    expect(sentObj.params).toEqual({ foo: 'bar' });
    expect(typeof sentObj.id).toBe('string');

    dispatcher.handleResponseLine(JSON.stringify({ id: sentObj.id, result: { count: 0 } }));
    const resp = await promise;
    expect(resp).toEqual({ id: sentObj.id, result: { count: 0 } });
  });

  it('routes responses to the correct caller by id', async () => {
    const p1 = dispatcher.call('a', {}, 1000);
    const p2 = dispatcher.call('b', {}, 1000);
    const id1 = parseSent(sent[0]).id;
    const id2 = parseSent(sent[1]).id;
    expect(id1).not.toBe(id2);

    // Resolve in reverse order
    dispatcher.handleResponseLine(JSON.stringify({ id: id2, result: 'second' }));
    dispatcher.handleResponseLine(JSON.stringify({ id: id1, result: 'first' }));

    expect((await p1).result).toBe('first');
    expect((await p2).result).toBe('second');
  });

  it('propagates plugin errors through the response', async () => {
    const promise = dispatcher.call('bogus', {}, 1000);
    const id = parseSent(sent[0]).id;
    dispatcher.handleResponseLine(JSON.stringify({ id, error: 'Unknown action' }));
    const resp = await promise;
    expect(resp.error).toBe('Unknown action');
    expect(resp.result).toBeUndefined();
  });

  it('rejects with timeout if no response arrives within timeoutMs', async () => {
    const promise = dispatcher.call('slow', {}, 1000);
    await expect(promise).rejects.toThrow(/timeout/i);
    dispatcher.handleResponseLine(JSON.stringify({ id: parseSent(sent[0]).id, result: {} }));
    expect(logs.at(-1)).toContain('Late response for timed-out id');
  });

  it('asks the plug-in to stop a request that timed out and settles when its late reply arrives', async () => {
    const promise = dispatcher.call('slow', {}, 1000);
    const id = JSON.parse(sent[0]).id as string;
    const error = (await promise.catch((caught: unknown) => caught)) as PluginTimeoutError;

    expect(error).toBeInstanceOf(PluginTimeoutError);
    expect(JSON.parse(sent[1])).toEqual({ hello: 'test-token', action: 'cancel', params: { request_id: id } });
    let settled = false;
    void error.settled.then(() => {
      settled = true;
    });
    await Promise.resolve();
    expect(settled).toBe(false);
    dispatcher.handleResponseLine(JSON.stringify({ id, result: { data: {} } }));
    await error.settled;
    expect(settled).toBe(true);
  });

  it('settles a timed-out request after the late-reply grace when no reply comes', async () => {
    jest.useFakeTimers();
    try {
      const graced = new Dispatcher({
        send: () => true,
        getToken: () => 'test-token',
        log: () => {},
        lateReplyGraceMs: 50,
        connectionGeneration: () => 0,
      });
      const pending = graced.call('slow', {}, 1000);
      const caught = pending.catch((error: unknown) => error);
      jest.advanceTimersByTime(1000);
      const error = (await caught) as PluginTimeoutError;
      let settled = false;
      void error.settled.then(() => {
        settled = true;
      });
      jest.advanceTimersByTime(49);
      await Promise.resolve();
      expect(settled).toBe(false);
      jest.advanceTimersByTime(1);
      await error.settled;
      expect(settled).toBe(true);
    } finally {
      jest.useRealTimers();
    }
  });

  it('settles a timed-out request when the connection is lost before its late reply', async () => {
    jest.useFakeTimers();
    try {
      const pending = dispatcher.call('slow', {}, 1000);
      const caught = pending.catch((error: unknown) => error);
      jest.advanceTimersByTime(1000);
      const error = (await caught) as PluginTimeoutError;
      let settled = false;
      void error.settled.then(() => {
        settled = true;
      });
      await Promise.resolve();
      expect(settled).toBe(false);
      dispatcher.rejectPending('connection lost');
      await error.settled;
      expect(settled).toBe(true);
    } finally {
      jest.useRealTimers();
    }
  });

  it('throws synchronously if send returns false', async () => {
    canSend = false;
    await expect(dispatcher.call('x', {}, 1000)).rejects.toThrow(/socket dropped/);
  });

  it('drops responses with unknown id without crashing', () => {
    dispatcher.handleResponseLine(JSON.stringify({ id: 'never-sent', result: 'x' }));
    expect(logs.some((l) => l.includes('unknown id'))).toBe(true);
  });

  it('drops malformed JSON without crashing', () => {
    dispatcher.handleResponseLine('not json {{{');
    expect(logs.some((l) => l.includes('Bad JSON'))).toBe(true);
  });

  it('cleans up pending map after response received', async () => {
    const p = dispatcher.call('x', {}, 1000);
    const id = parseSent(sent[0]).id;
    dispatcher.handleResponseLine(JSON.stringify({ id, result: 'ok' }));
    await p;
    dispatcher.handleResponseLine(JSON.stringify({ id, result: 'ok' }));
    expect(logs.at(-1)).toContain('unknown id');
  });

  it('waits for the timeout the call names', async () => {
    jest.useFakeTimers();
    try {
      const pending = dispatcher.call('export_photos', {}, 60_000);
      let settled = false;
      void pending.catch(() => {
        settled = true;
      });
      jest.advanceTimersByTime(59_999);
      await Promise.resolve();
      expect(settled).toBe(false);
      jest.advanceTimersByTime(1);
      await expect(pending).rejects.toThrow(/timeout \(60s\)/);
    } finally {
      jest.useRealTimers();
    }
  });
});

describe('Dispatcher cancels', () => {
  function dispatcherOn() {
    let generation = 0;
    const sent: SentRequest[] = [];
    const dispatcher = new Dispatcher({
      send: (line) => {
        sent.push(parseSent(line));
        return true;
      },
      getToken: () => 't',
      log: () => {},
      connectionGeneration: () => generation,
    });
    return {
      dispatcher,
      sent,
      reconnect: () => {
        generation += 1;
      },
    };
  }

  it("writes a caller's cancel to the connection its request went to, and not to a newer one", () => {
    const same = dispatcherOn();
    const kept = new AbortController();
    void same.dispatcher.call('set_rating', {}, 5_000, { signal: kept.signal }).catch(() => {});
    kept.abort();
    expect(same.sent.map((frame) => frame.action)).toEqual(['set_rating', 'cancel']);

    const moved = dispatcherOn();
    const stale = new AbortController();
    void moved.dispatcher.call('set_rating', {}, 5_000, { signal: stale.signal }).catch(() => {});
    moved.reconnect();
    stale.abort();
    expect(moved.sent.map((frame) => frame.action)).toEqual(['set_rating']);
  });

  it("writes no timeout cancel, a ping's included, to a newer connection", async () => {
    jest.useFakeTimers();
    try {
      const { dispatcher, sent, reconnect } = dispatcherOn();
      const ping = dispatcher.call('ping', {}, 1_000).catch((error: unknown) => error);
      reconnect();
      jest.advanceTimersByTime(1_000);

      expect(await ping).toBeInstanceOf(PluginTimeoutError);
      expect(sent.map((frame) => frame.action)).toEqual(['ping']);
    } finally {
      jest.useRealTimers();
    }
  });
});
