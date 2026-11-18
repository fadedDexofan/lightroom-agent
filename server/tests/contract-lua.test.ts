import { describe, expect, it } from '@jest/globals';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { expectedIdentity, pluginBuild, renderContractLua } from '../src/contract-lua.js';

const PLUGIN_DIR = path.resolve(process.cwd(), '..', 'plugin', 'LightroomAgent.lrplugin');

describe('generated Lua contract module', () => {
  it('matches the tables of the TypeScript contract; run npm run build after changing them', () => {
    const tracked = fs.readFileSync(path.join(PLUGIN_DIR, 'Contract.lua'), 'utf8');
    expect(tracked).toBe(renderContractLua(expectedIdentity(PLUGIN_DIR)));
  });
});

describe('constants shared with the plug-in', () => {
  it('names the detail render folder the server cleans up', async () => {
    const { DETAIL_RENDER_FOLDER } = await import('../src/photo-detail.js');
    expect(renderContractLua(expectedIdentity(PLUGIN_DIR))).toContain(`DETAIL_RENDER_FOLDER = "${DETAIL_RENDER_FOLDER}"`);
  });
});

describe('preview reply reserve', () => {
  it('reaches the plug-in from the one constant the server adds to a preview timeout', async () => {
    const { PREVIEW_REPLY_RESERVE_MS } = await import('../src/preview-item.js');
    expect(renderContractLua(expectedIdentity(PLUGIN_DIR))).toContain(`PREVIEW_REPLY_RESERVE_SECONDS = ${PREVIEW_REPLY_RESERVE_MS / 1000}`);
  });
});

describe('plug-in build identity', () => {
  it('changes with any Lua file of the bundle and the contract body, ignoring line endings, Contract.lua and other files', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-build-'));
    try {
      const write = (file: string, text: string) => {
        fs.mkdirSync(path.dirname(path.join(dir, file)), { recursive: true });
        fs.writeFileSync(path.join(dir, file), text);
      };
      write('Handler.lua', 'return 1\n');
      write('Contract.lua', 'return {}\n');
      write('notes.txt', 'a');
      const base = pluginBuild(dir, 'body');
      expect(base).toMatch(/^[0-9a-f]{16}$/);

      write('Handler.lua', 'return 1\r\n');
      write('Contract.lua', 'return { BUILD = "x" }\n');
      write('notes.txt', 'b');
      expect(pluginBuild(dir, 'body')).toBe(base);

      expect(pluginBuild(dir, 'other body')).not.toBe(base);
      write('sub/Nested.lua', 'return 2\n');
      const nested = pluginBuild(dir, 'body');
      expect(nested).not.toBe(base);
      write('Handler.lua', 'return 3\n');
      expect(pluginBuild(dir, 'body')).not.toBe(nested);
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
