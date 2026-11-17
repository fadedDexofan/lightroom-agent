import { readFile, writeFile } from 'node:fs/promises';
import { renderContractLua } from '../dist/contract-lua.js';
import { manifestTools } from '../dist/manifest-tools.js';

await writeFile(new URL('../../plugin/LightroomMCP.lrplugin/Contract.lua', import.meta.url), renderContractLua());

const manifestUrl = new URL('../../mcpb/manifest.json', import.meta.url);
const manifest = JSON.parse(await readFile(manifestUrl, 'utf8'));
manifest.tools = manifestTools();
await writeFile(manifestUrl, `${JSON.stringify(manifest, null, 2)}\n`);
