import { describe, it, expect } from '@jest/globals';
import { compareVersions } from '../src/build-identity.js';

describe('compareVersions', () => {
  it.each([
    ['0.1.0-rc.2', '0.1.0-rc.10', -1],
    ['0.1.0-rc.10', '0.1.0', -1],
    ['0.1.0', '0.1.1', -1],
    ['0.1.1', '0.2.0', -1],
    ['0.9.9', '1.0.0', -1],
    ['1.0.0-alpha', '1.0.0-beta', -1],
    ['1.0.0-alpha', '1.0.0-alpha.1', -1],
    ['1.0.0-1', '1.0.0-alpha', -1],
    ['0.1.0-rc.2', '0.1.0-rc.2', 0],
    ['1.0.0+a', '1.0.0+b', 0],
  ] as const)('orders %s before or with %s by SemVer precedence', (lower, higher, order) => {
    expect(compareVersions(lower, higher)).toBe(order);
    expect(compareVersions(higher, lower)).toBe(order === 0 ? 0 : 1);
  });

  it.each([
    ['rc.1', '0.1.0'],
    ['0.1.0', null],
    [null, null],
    ['1.0', '1.0.0'],
    ['01.0.0', '1.0.0'],
  ] as const)('gives no order for %o and %o', (left, right) => {
    expect(compareVersions(left, right)).toBeNull();
  });
});
