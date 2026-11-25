import { readFile, rename, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { expectedIdentity, renderContractLua } from '../dist/contract-lua.js';
import { manifestTools } from '../dist/manifest-tools.js';
import { PLUGIN_BUILD_RECORD } from '../dist/plugin-pairing.js';
import { writePortDefaults } from '../dist/ports.js';

const pluginDir = new URL('../../plugin/LightroomAgent.lrplugin/', import.meta.url);
const identity = expectedIdentity(fileURLToPath(pluginDir));
await writeFile(new URL('Contract.lua', pluginDir), renderContractLua(identity));

const record = new URL(`../dist/${PLUGIN_BUILD_RECORD}`, import.meta.url);
const partial = new URL(`../dist/${PLUGIN_BUILD_RECORD}.${process.pid}.tmp`, import.meta.url);
await writeFile(partial, `${JSON.stringify({ build: identity.build })}\n`);
await rename(partial, record);

const manifestUrl = new URL('../../mcpb/manifest.json', import.meta.url);
const registryUrl = new URL('../../server.json', import.meta.url);
const manifest = JSON.parse(await readFile(manifestUrl, 'utf8'));
const registry = JSON.parse(await readFile(registryUrl, 'utf8'));
manifest.tools = manifestTools();
writePortDefaults(manifest, registry);
await writeFile(manifestUrl, `${JSON.stringify(manifest, null, 2)}\n`);
await writeFile(registryUrl, `${JSON.stringify(registry, null, 2)}\n`);
