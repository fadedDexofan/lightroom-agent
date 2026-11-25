import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ConnectionLossDeadline } from '../src/connection-loss.js';

describe('ConnectionLossDeadline', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  afterEach(() => {
    vi.useRealTimers();
  });

  it('expires once, counted from the first loss', () => {
    const expired = vi.fn();
    const deadline = new ConnectionLossDeadline(1000, expired);
    deadline.start();
    vi.advanceTimersByTime(600);
    deadline.start();
    vi.advanceTimersByTime(400);
    expect(expired).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(5000);
    expect(expired).toHaveBeenCalledTimes(1);
  });

  it('does not expire after the connection recovers', () => {
    const expired = vi.fn();
    const deadline = new ConnectionLossDeadline(1000, expired);
    deadline.start();
    deadline.clear();
    vi.advanceTimersByTime(5000);
    expect(expired).not.toHaveBeenCalled();
  });

  it('can start again after expiring', () => {
    const expired = vi.fn();
    const deadline = new ConnectionLossDeadline(1000, expired);
    deadline.start();
    vi.advanceTimersByTime(1000);
    deadline.start();
    vi.advanceTimersByTime(1000);
    expect(expired).toHaveBeenCalledTimes(2);
  });
});
