import { describe, expect, it } from '@jest/globals';
import fs from 'node:fs';
import path from 'node:path';
import { renderContractLua } from '../src/contract-lua.js';

describe('generated Lua contract module', () => {
  it('matches the tables of the TypeScript contract; run npm run build after changing them', () => {
    const tracked = fs.readFileSync(
      path.resolve(process.cwd(), '..', 'plugin', 'LightroomAgent.lrplugin', 'Contract.lua'), 'utf8');
    expect(tracked).toBe(renderContractLua());
  });
});

describe('constants shared with the plug-in', () => {
  it('names the detail render folder the server cleans up', async () => {
    const { DETAIL_RENDER_FOLDER } = await import('../src/photo-detail.js');
    expect(renderContractLua()).toContain(`DETAIL_RENDER_FOLDER = "${DETAIL_RENDER_FOLDER}"`);
  });
});

describe('preview reply reserve', () => {
  it('reaches the plug-in from the one constant the server adds to a preview timeout', async () => {
    const { PREVIEW_REPLY_RESERVE_MS } = await import('../src/preview-item.js');
    expect(renderContractLua()).toContain(`PREVIEW_REPLY_RESERVE_SECONDS = ${PREVIEW_REPLY_RESERVE_MS / 1000}`);
  });
});
