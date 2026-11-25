import { describe, it, expect } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { serverIdentity } from '../src/server-identity.js';
import { VERSION } from '../src/version.js';

describe('serverIdentity', () => {
  it('is the compiled version, a digest of every compiled script, which other files do not change, and the paired plug-in build', () => {
    const dist = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-dist-'));
    try {
      fs.writeFileSync(path.join(dist, 'index.js'), 'export {};\n');
      fs.writeFileSync(path.join(dist, 'notes.txt'), 'a');
      const base = serverIdentity(dist, 'p1');
      expect(base).toEqual({
        version: VERSION,
        build: expect.stringMatching(/^[0-9a-f]{16}$/) as unknown,
        plugin: 'p1',
      });

      fs.writeFileSync(path.join(dist, 'notes.txt'), 'b');
      expect(serverIdentity(dist, 'p1')).toEqual(base);

      fs.mkdirSync(path.join(dist, 'lib'));
      fs.writeFileSync(path.join(dist, 'lib', 'tool.js'), 'export const x = 1;\n');
      expect(serverIdentity(dist, 'p1').build).not.toBe(base.build);
    } finally {
      fs.rmSync(dist, { recursive: true, force: true });
    }
  });
});
