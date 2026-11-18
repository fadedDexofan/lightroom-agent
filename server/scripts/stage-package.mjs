import { cp, rm } from 'node:fs/promises';

const staged = [
  { root: '../LightroomAgent.lrplugin/', copies: [['../../plugin/LightroomAgent.lrplugin/', '../LightroomAgent.lrplugin/']] },
  { root: '../skills/', copies: [['../../skills/lightroom-agent/', '../skills/lightroom-agent/']] },
];
const removing = process.argv.includes('--remove');
for (const { root, copies } of staged) {
  await rm(new URL(root, import.meta.url), { recursive: true, force: true });
  if (removing) continue;
  for (const [source, destination] of copies) {
    await cp(new URL(source, import.meta.url), new URL(destination, import.meta.url), { recursive: true });
  }
}
