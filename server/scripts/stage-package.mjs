import { cp, rm } from 'node:fs/promises';

const staged = [
  ['../../plugin/LightroomAgent.lrplugin/', '../LightroomAgent.lrplugin/'],
  ['../../skills/lightroom-agent/', '../skills/lightroom-agent/'],
];
for (const [source, destination] of staged) {
  const target = new URL(destination, import.meta.url);
  await rm(target, { recursive: true, force: true });
  await cp(new URL(source, import.meta.url), target, { recursive: true });
}
