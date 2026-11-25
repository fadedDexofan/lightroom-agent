import { describe, it, expect, afterEach } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { expectedIdentity, renderContractLua } from '../src/contract-lua.js';
import { findBundledPlugin, pairingOf } from '../src/plugin-pairing.js';
import { VERSION } from '../src/version.js';

const roots: string[] = [];

afterEach(() => {
  while (roots.length > 0) fs.rmSync(roots.pop()!, { recursive: true, force: true });
});

const CHECKOUT_FIX =
  "This server's build does not match its plug-in folder; rebuild it (npm --prefix server run build in the checkout), then restart your client.";
const PACKAGE_FIX = "This server's installation is damaged; reinstall lightroom-agent, then restart your client.";
const NO_BUNDLE = 'This server has no bundled Lightroom plug-in; reinstall lightroom-agent.';

type Layout = 'checkout' | 'package';

function regenerate(bundle: string): string {
  fs.writeFileSync(path.join(bundle, 'Contract.lua'), renderContractLua(expectedIdentity(bundle)));
  return expectedIdentity(bundle).build;
}

function built(layout: Layout = 'checkout'): { dist: string; bundle: string; build: string } {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-pairing-'));
  roots.push(root);
  const dist = layout === 'checkout' ? path.join(root, 'server', 'dist') : path.join(root, 'dist');
  const bundle =
    layout === 'checkout'
      ? path.join(root, 'plugin', 'LightroomAgent.lrplugin')
      : path.join(root, 'LightroomAgent.lrplugin');
  fs.mkdirSync(bundle, { recursive: true });
  fs.mkdirSync(dist, { recursive: true });
  fs.writeFileSync(path.join(bundle, 'Info.lua'), "return { LrToolkitIdentifier = 'io.test.agent' }\n");
  fs.writeFileSync(path.join(bundle, 'Handler.lua'), 'return 1\n');
  const build = regenerate(bundle);
  fs.writeFileSync(path.join(dist, 'plugin-build.json'), JSON.stringify({ build }));
  return { dist, bundle, build };
}

describe('pairingOf', () => {
  it.each(['checkout', 'package'] as const)(
    'pairs a %s with the plug-in build its own build step recorded',
    (layout) => {
      const { dist, bundle, build } = built(layout);

      expect(pairingOf(dist)).toEqual({ kind: 'paired', plugin: { version: VERSION, build }, source: bundle, layout });
    },
  );

  it('refuses a checkout whose plug-in Lua was pulled and regenerated after this server was built', () => {
    const { dist, bundle } = built();
    fs.writeFileSync(path.join(bundle, 'Handler.lua'), 'return 2\n');
    regenerate(bundle);

    expect(pairingOf(dist)).toEqual({ kind: 'unpaired', reason: CHECKOUT_FIX });
  });

  it("refuses a bundle whose Contract.lua carries this build's stamp over another contract row", () => {
    const { dist, bundle } = built();
    const file = path.join(bundle, 'Contract.lua');
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace(/DEFAULT_PAGE_LIMIT = \d+/, 'DEFAULT_PAGE_LIMIT = 7'));

    expect(pairingOf(dist)).toEqual({ kind: 'unpaired', reason: CHECKOUT_FIX });
  });

  it('refuses a bundle whose plug-in Lua changed after the build', () => {
    const { dist, bundle } = built();
    fs.writeFileSync(path.join(bundle, 'Handler.lua'), 'return 2\n');

    expect(pairingOf(dist)).toEqual({ kind: 'unpaired', reason: CHECKOUT_FIX });
  });

  it.each([
    ['missing', null],
    ['partial', '{"build":"'],
    ['malformed', '[1]'],
    ['without a build', '{}'],
  ])('refuses, by layout, when the recorded plug-in build is %s', (_what, json) => {
    for (const [layout, reason] of [
      ['checkout', CHECKOUT_FIX],
      ['package', PACKAGE_FIX],
    ] as const) {
      const { dist } = built(layout);
      const record = path.join(dist, 'plugin-build.json');
      if (json === null) fs.rmSync(record);
      else fs.writeFileSync(record, json);

      expect(pairingOf(dist)).toEqual({ kind: 'unpaired', reason });
    }
  });

  it('pairs a bundle checked out with CRLF line endings', () => {
    const { dist, bundle, build } = built();
    for (const file of ['Contract.lua', 'Handler.lua']) {
      const target = path.join(bundle, file);
      fs.writeFileSync(target, fs.readFileSync(target, 'utf8').replace(/\n/g, '\r\n'));
    }

    expect(pairingOf(dist)).toMatchObject({ kind: 'paired', plugin: { build } });
  });

  it.each(['Contract.lua', 'Info.lua'])(
    'does not select a bundle whose %s is a link, even to the right bytes',
    (file) => {
      const { dist, bundle } = built();
      const target = path.join(bundle, file);
      const real = path.join(path.dirname(bundle), file);
      fs.renameSync(target, real);
      fs.symlinkSync(real, target);

      expect(pairingOf(dist)).toEqual({ kind: 'unpaired', reason: NO_BUNDLE });
    },
  );

  it('pairs past a dangling extra Lua link in the bundle', () => {
    const { dist, bundle, build } = built();
    fs.symlinkSync(path.join(bundle, 'gone.lua'), path.join(bundle, 'Extra.lua'));

    expect(pairingOf(dist)).toMatchObject({ kind: 'paired', plugin: { build } });
  });

  it('refuses to pair, saying reinstall, when no bundled plug-in is found', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-pairing-'));
    roots.push(root);

    expect(pairingOf(path.join(root, 'server', 'dist'))).toEqual({ kind: 'unpaired', reason: NO_BUNDLE });
  });
});

describe('findBundledPlugin', () => {
  function bundleIn(dir: string): string {
    const bundle = path.join(dir, 'LightroomAgent.lrplugin');
    fs.mkdirSync(bundle, { recursive: true });
    fs.writeFileSync(path.join(bundle, 'Info.lua'), '-- fake');
    fs.writeFileSync(path.join(bundle, 'Contract.lua'), '-- fake');
    return bundle;
  }

  function root(): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-find-'));
    roots.push(dir);
    return dir;
  }

  it("takes the checkout's plugin folder over a copy staged into server/ for packing", () => {
    const dir = root();
    const checkout = bundleIn(path.join(dir, 'plugin'));
    bundleIn(path.join(dir, 'server'));

    expect(findBundledPlugin(path.join(dir, 'server', 'dist'))).toEqual({ source: checkout, layout: 'checkout' });
  });

  it('finds the plugin beside dist/ in an npm package and beside server/ in an mcpb bundle', () => {
    const npm = root();
    const npmBundle = bundleIn(npm);
    expect(findBundledPlugin(path.join(npm, 'dist'))).toEqual({ source: npmBundle, layout: 'package' });
    const mcpb = root();
    const mcpbBundle = bundleIn(mcpb);
    expect(findBundledPlugin(path.join(mcpb, 'server', 'dist'))).toEqual({ source: mcpbBundle, layout: 'package' });
  });
});
