import { describe, it, expect, beforeEach, afterEach, jest } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  ensurePluginInstalled,
  findBundledPlugin,
  describeInstall,
  installPlugin,
  lightroomModulesDir,
  lightroomPluginsDir,
} from '../src/install-plugin.js';
import { VERSION } from '../src/version.js';

const realPlatform = process.platform;
const realAppData = process.env.APPDATA;

function setPlatform(p: NodeJS.Platform): void {
  Object.defineProperty(process, 'platform', { value: p, configurable: true });
}

function restoreEnv(): void {
  Object.defineProperty(process, 'platform', { value: realPlatform, configurable: true });
  if (realAppData === undefined) delete process.env.APPDATA;
  else process.env.APPDATA = realAppData;
  jest.restoreAllMocks();
}

describe('lightroomModulesDir', () => {
  afterEach(restoreEnv);

  it('returns a darwin path on macOS', () => {
    setPlatform('darwin');
    expect(lightroomModulesDir().endsWith(
      path.join('Library', 'Application Support', 'Adobe', 'Lightroom', 'Modules'),
    )).toBe(true);
  });

  it('returns an APPDATA-based path on win32', () => {
    setPlatform('win32');
    process.env.APPDATA = path.join('C:', 'Users', 'tester', 'AppData', 'Roaming');
    expect(lightroomModulesDir().endsWith(path.join('Adobe', 'Lightroom', 'Modules'))).toBe(true);
    expect(lightroomModulesDir()).toContain(process.env.APPDATA);
  });

  it('falls back to homedir AppData on win32 when APPDATA unset', () => {
    setPlatform('win32');
    delete process.env.APPDATA;
    expect(lightroomModulesDir()).toContain(path.join('AppData', 'Roaming', 'Adobe'));
  });

  it('returns an XDG-style path on linux', () => {
    setPlatform('linux');
    expect(lightroomModulesDir().endsWith(
      path.join('.local', 'share', 'Adobe', 'Lightroom', 'Modules'),
    )).toBe(true);
  });
});

describe('lightroomPluginsDir', () => {
  afterEach(restoreEnv);

  it('returns a darwin path on macOS', () => {
    setPlatform('darwin');
    expect(lightroomPluginsDir().endsWith(
      path.join('Library', 'Application Support', 'Adobe', 'Lightroom', 'Plugins'),
    )).toBe(true);
  });

  it('returns an APPDATA-based path on win32', () => {
    setPlatform('win32');
    process.env.APPDATA = path.join('C:', 'Users', 'tester', 'AppData', 'Roaming');
    expect(lightroomPluginsDir().endsWith(path.join('Adobe', 'Lightroom', 'Plugins'))).toBe(true);
  });

  it('falls back to homedir AppData on win32 when APPDATA unset', () => {
    setPlatform('win32');
    delete process.env.APPDATA;
    expect(lightroomPluginsDir()).toContain(path.join('AppData', 'Roaming', 'Adobe'));
  });

  it('returns an XDG-style path on linux', () => {
    setPlatform('linux');
    expect(lightroomPluginsDir().endsWith(
      path.join('.local', 'share', 'Adobe', 'Lightroom', 'Plugins'),
    )).toBe(true);
  });
});

describe('installPlugin', () => {
  let tmp: string;
  let home: string;
  let installed: string;

  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-install-'));
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-home-'));
    setPlatform('linux');
    jest.spyOn(os, 'homedir').mockReturnValue(home);
    installed = path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin');
  });

  afterEach(() => {
    restoreEnv();
    fs.rmSync(tmp, { recursive: true, force: true });
    fs.rmSync(home, { recursive: true, force: true });
  });

  function makeFakePlugin(name: string, identity: { id?: string; version?: string | null; build?: string } = {}): string {
    const src = path.join(tmp, name, 'LightroomAgent.lrplugin');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'Info.lua'), `return {\n    LrToolkitIdentifier = '${identity.id ?? 'io.test.agent'}',\n}\n`);
    if (identity.version !== null) {
      fs.writeFileSync(path.join(src, 'Contract.lua'),
        `return {\n    VERSION = "${identity.version ?? '1.0.0'}",\n    BUILD = "${identity.build ?? 'b1'}",\n}\n`);
    }
    fs.writeFileSync(path.join(src, 'Handler.lua'), '-- handler');
    return src;
  }

  it('copies the plugin into Lightroom\'s Modules folder on first install', () => {
    const result = installPlugin({ source: makeFakePlugin('src') });

    expect(result).toEqual({ status: 'installed', destination: installed });
    expect(fs.existsSync(path.join(installed, 'Info.lua'))).toBe(true);
    expect(fs.existsSync(path.join(installed, 'Handler.lua'))).toBe(true);
  });

  it('copies nested directories recursively', () => {
    const source = makeFakePlugin('src');
    fs.mkdirSync(path.join(source, 'sub'));
    fs.writeFileSync(path.join(source, 'sub', 'Nested.lua'), '-- nested');

    installPlugin({ source });

    expect(fs.existsSync(path.join(installed, 'sub', 'Nested.lua'))).toBe(true);
  });

  it('copies regular files only, leaving links behind, dangling ones included', () => {
    if (realPlatform === 'win32') return;
    const source = makeFakePlugin('src');
    fs.symlinkSync('Info.lua', path.join(source, 'Info.link.lua'));
    fs.symlinkSync('gone.lua', path.join(source, 'Dangling.lua'));

    installPlugin({ source });

    expect(fs.readdirSync(installed).sort()).toEqual(['Contract.lua', 'Handler.lua', 'Info.lua']);
  });

  it('leaves a bundle of this plug-in of the same build alone', () => {
    const source = makeFakePlugin('src');
    installPlugin({ source });
    const kept = path.join(installed, 'Handler.lua');
    fs.writeFileSync(kept, '-- modified');

    const result = installPlugin({ source });

    expect(result).toEqual({ status: 'current', destination: installed });
    expect(fs.readFileSync(kept, 'utf8')).toBe('-- modified');
  });

  it.each([
    ['another version', { version: '0.9.0' }, { version: '0.9.0', build: 'b1' }],
    ['another build of the same version', { build: 'b0' }, { version: '1.0.0', build: 'b0' }],
    ['no version', { version: null }, { version: null, build: null }],
  ])('replaces a bundle of this plug-in that reports %s', (_what, installedIdentity, from) => {
    installPlugin({ source: makeFakePlugin('old', installedIdentity) });
    fs.writeFileSync(path.join(installed, 'Stale.lua'), '-- gone in the new build');

    const result = installPlugin({ source: makeFakePlugin('src', { version: '1.0.0' }) });

    expect(result).toEqual({ status: 'replaced', destination: installed, from, to: { version: '1.0.0', build: 'b1' } });
    expect(fs.existsSync(path.join(installed, 'Stale.lua'))).toBe(false);
    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toContain('VERSION = "1.0.0"');
  });

  it('keeps the installed bundle whole when copying its replacement fails', () => {
    installPlugin({ source: makeFakePlugin('old', { version: '0.9.0' }) });
    const copy = fs.copyFileSync;
    let copies = 0;
    jest.spyOn(fs, 'copyFileSync').mockImplementation((from, to, mode) => {
      copies += 1;
      if (copies === 2) throw new Error('disk full');
      copy(from, to, mode);
    });

    expect(() => installPlugin({ source: makeFakePlugin('src', { version: '1.0.0' }) })).toThrow('disk full');

    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toContain('VERSION = "0.9.0"');
    expect(fs.readdirSync(lightroomModulesDir())).toEqual(['LightroomAgent.lrplugin']);
  });

  it('reads the identity of the real bundle: its toolkit id, the server version and the build in its generated contract', () => {
    installPlugin({ source: makeFakePlugin('old', { id: 'io.github.fadeddexofan.lightroomagent', version: '0.0.1' }) });

    const result = installPlugin({ source: path.resolve(process.cwd(), '..', 'plugin', 'LightroomAgent.lrplugin') });

    expect(result).toEqual({ status: 'replaced', destination: installed, from: { version: '0.0.1', build: 'b1' },
      to: { version: VERSION, build: expect.stringMatching(/^[0-9a-f]{16}$/) } });
  });

  it('keeps a whole bundle in place when removing the replaced one is interrupted, and clears the remnant next time', () => {
    installPlugin({ source: makeFakePlugin('old', { version: '0.9.0' }) });
    const remove = fs.rmSync;
    const interrupted = jest.spyOn(fs, 'rmSync').mockImplementation((target, options) => {
      const info = path.join(String(target), 'Info.lua');
      if (fs.existsSync(info)) {
        fs.unlinkSync(info);
        throw new Error('killed');
      }
      remove(target, options);
    });

    expect(() => installPlugin({ source: makeFakePlugin('src', { version: '1.0.0' }) })).toThrow('killed');
    interrupted.mockRestore();

    expect(fs.existsSync(path.join(installed, 'Info.lua'))).toBe(true);
    expect(installPlugin({ source: makeFakePlugin('src', { version: '1.0.0' }) }).status).toBe('current');
    expect(fs.readdirSync(lightroomModulesDir())).toEqual(['LightroomAgent.lrplugin']);
  });

  it('reads a bundle checked out with CRLF line endings as the same build', () => {
    const source = makeFakePlugin('src');
    installPlugin({ source });
    const contract = path.join(installed, 'Contract.lua');
    fs.writeFileSync(contract, fs.readFileSync(contract, 'utf8').replace(/\n/g, '\r\n'));

    expect(installPlugin({ source }).status).toBe('current');
  });

  it('replaces rather than keeps a bundle whose build cannot be read, even when the bundled one cannot either', () => {
    const unreadable = (name: string) => {
      const bundle = makeFakePlugin(name);
      fs.writeFileSync(path.join(bundle, 'Contract.lua'), 'return {\n    VERSION = "1.0.0",\n}\n');
      return bundle;
    };
    installPlugin({ source: unreadable('old') });

    expect(installPlugin({ source: unreadable('src') }).status).toBe('replaced');
  });

  it('leaves another plug-in that sits in the folder alone', () => {
    installPlugin({ source: makeFakePlugin('other', { id: 'com.other.plugin', version: '0.1.0' }) });

    const result = installPlugin({ source: makeFakePlugin('src') });

    expect(result).toEqual({ status: 'foreign', destination: installed, toolkitId: 'com.other.plugin' });
    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toContain('VERSION = "0.1.0"');
  });

  it('replaces an outdated bundle where it is installed, Plugins included', () => {
    const inPlugins = path.join(lightroomPluginsDir(), 'LightroomAgent.lrplugin');
    fs.mkdirSync(path.dirname(inPlugins), { recursive: true });
    fs.cpSync(makeFakePlugin('old', { version: '0.9.0' }), inPlugins, { recursive: true });

    const result = installPlugin({ source: makeFakePlugin('src') });

    expect(result).toEqual({ status: 'replaced', destination: inPlugins, from: { version: '0.9.0', build: 'b1' }, to: { version: '1.0.0', build: 'b1' } });
    expect(fs.existsSync(installed)).toBe(false);
  });

  it.each([
    [{ status: 'installed', destination: '/M/LightroomAgent.lrplugin' }, 'installed /M/LightroomAgent.lrplugin; restart Lightroom to load it'],
    [{ status: 'replaced', destination: '/M/LightroomAgent.lrplugin', from: { version: '0.9.0', build: 'b0' }, to: { version: '1.0.0', build: 'b1' } }, 'replaced /M/LightroomAgent.lrplugin (version 0.9.0 → 1.0.0); restart Lightroom to load it'],
    [{ status: 'replaced', destination: '/M/LightroomAgent.lrplugin', from: { version: null, build: null }, to: { version: '1.0.0', build: 'b1' } }, 'replaced /M/LightroomAgent.lrplugin (version unknown → 1.0.0); restart Lightroom to load it'],
    [{ status: 'replaced', destination: '/M/LightroomAgent.lrplugin', from: { version: '1.0.0', build: 'b0' }, to: { version: '1.0.0', build: 'b1' } }, 'replaced /M/LightroomAgent.lrplugin (version 1.0.0, build b0 → b1); restart Lightroom to load it'],
    [{ status: 'current', destination: '/M/LightroomAgent.lrplugin' }, '/M/LightroomAgent.lrplugin is already this build'],
    [{ status: 'foreign', destination: '/M/LightroomAgent.lrplugin', toolkitId: 'com.other' }, '/M/LightroomAgent.lrplugin holds another plug-in (com.other) and was left alone. Remove it, then install again.'],
    [{ status: 'conflict', conflicting: '/M/LightroomMCP.lrplugin' }, 'The installed /M/LightroomMCP.lrplugin binds the same ports. Quit Lightroom, remove that folder, then install again.'],
  ] as const)('describes %o', (result, line) => {
    expect(describeInstall(result)).toBe(line);
  });
});

describe.each([
  ['Modules', lightroomModulesDir],
  ['Plugins', lightroomPluginsDir],
])('a LightroomMCP.lrplugin in %s', (_where, dirOf) => {
  let home: string;
  let startDir: string;

  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-home-'));
    startDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-start-'));
    setPlatform('linux');
    jest.spyOn(os, 'homedir').mockReturnValue(home);
    const upstream = path.join(dirOf(), 'LightroomMCP.lrplugin');
    fs.mkdirSync(upstream, { recursive: true });
    fs.writeFileSync(path.join(upstream, 'Info.lua'), '-- upstream');
    const bundled = path.join(startDir, 'LightroomAgent.lrplugin');
    fs.mkdirSync(bundled, { recursive: true });
    fs.writeFileSync(path.join(bundled, 'Info.lua'), '-- fake');
    fs.writeFileSync(path.join(bundled, 'Contract.lua'), '-- fake');
  });

  afterEach(() => {
    restoreEnv();
    fs.rmSync(home, { recursive: true, force: true });
    fs.rmSync(startDir, { recursive: true, force: true });
  });

  it('makes install refuse and copy nothing', () => {
    const result = installPlugin({ source: path.join(startDir, 'LightroomAgent.lrplugin') });

    expect(result).toEqual({ status: 'conflict', conflicting: path.join(dirOf(), 'LightroomMCP.lrplugin') });
    expect(fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin'))).toBe(false);
  });

  it('makes the start-up install log the conflict instead of installing', () => {
    const log = jest.fn();

    ensurePluginInstalled(path.join(startDir, 'dist'), log);

    expect(log).toHaveBeenCalledWith(
      `[install-plugin] The installed ${path.join(dirOf(), 'LightroomMCP.lrplugin')} binds the same ports. `
        + 'Quit Lightroom, remove that folder, then install again.',
    );
    expect(fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin'))).toBe(false);
  });
});

describe('findBundledPlugin', () => {
  it('takes the checkout\'s plugin folder over a copy staged into server/ for packing', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-checkout-'));
    try {
      for (const bundle of [path.join(root, 'plugin'), path.join(root, 'server')]) {
        fs.mkdirSync(path.join(bundle, 'LightroomAgent.lrplugin'), { recursive: true });
        fs.writeFileSync(path.join(bundle, 'LightroomAgent.lrplugin', 'Info.lua'), '-- fake');
        fs.writeFileSync(path.join(bundle, 'LightroomAgent.lrplugin', 'Contract.lua'), '-- fake');
      }

      expect(findBundledPlugin(path.join(root, 'server', 'dist')))
        .toEqual({ source: path.join(root, 'plugin', 'LightroomAgent.lrplugin'), layout: 'checkout' });
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it('returns null when no plugin directory found', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-find-'));
    try {
      expect(findBundledPlugin(dir)).toBeNull();
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it('finds the plugin beside server/ in an mcpb bundle', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-find-'));
    try {
      const plug = path.join(root, 'LightroomAgent.lrplugin');
      fs.mkdirSync(plug);
      fs.writeFileSync(path.join(plug, 'Info.lua'), '-- fake');
      fs.writeFileSync(path.join(plug, 'Contract.lua'), '-- fake');
      const child = path.join(root, 'server', 'dist');
      fs.mkdirSync(child, { recursive: true });
      expect(findBundledPlugin(child)).toEqual({ source: path.resolve(plug), layout: 'package' });
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});

describe('ensurePluginInstalled', () => {
  let home: string;
  let startDir: string;

  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-home-'));
    startDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-start-'));
    setPlatform('linux');
    jest.spyOn(os, 'homedir').mockReturnValue(home);
  });

  afterEach(() => {
    restoreEnv();
    fs.rmSync(home, { recursive: true, force: true });
    fs.rmSync(startDir, { recursive: true, force: true });
  });

  function bundlePluginIn(dir: string, version = '1.0.0'): void {
    const src = path.join(dir, 'LightroomAgent.lrplugin');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'Info.lua'), "return {\n    LrToolkitIdentifier = 'io.test.agent',\n}\n");
    fs.writeFileSync(path.join(src, 'Contract.lua'), `return {\n    VERSION = "${version}",\n    BUILD = "b1",\n}\n`);
  }

  it('leaves a bundle of the same build alone without logging', () => {
    bundlePluginIn(startDir);
    bundlePluginIn(lightroomModulesDir());
    const log = jest.fn();
    ensurePluginInstalled(path.join(startDir, 'dist'), log);
    expect(log).not.toHaveBeenCalled();
  });

  it('replaces an outdated bundle of this plug-in and logs both versions', () => {
    bundlePluginIn(startDir, '1.0.0');
    bundlePluginIn(lightroomModulesDir(), '1.0.0-rc.0');
    const log = jest.fn();
    ensurePluginInstalled(path.join(startDir, 'dist'), log);
    expect(log).toHaveBeenCalledWith(`[install-plugin] replaced ${path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin')} `
      + '(version 1.0.0-rc.0 → 1.0.0); restart Lightroom to load it');
  });

  it('does nothing when no bundled plugin can be found', () => {
    const log = jest.fn();
    ensurePluginInstalled(path.join(startDir, 'dist'), log);
    expect(log).not.toHaveBeenCalled();
  });

  it('installs the bundled plugin and logs progress', () => {
    bundlePluginIn(startDir);
    const log = jest.fn();
    ensurePluginInstalled(path.join(startDir, 'dist'), log);
    expect(log).toHaveBeenCalledWith(
      `[install-plugin] installed ${path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin')}; restart Lightroom to load it`);
    expect(
      fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin', 'Info.lua')),
    ).toBe(true);
  });

  it('never auto-installs a plugin found only in the working directory', () => {
    const cwdDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-cwd-'));
    try {
      bundlePluginIn(cwdDir);
      jest.spyOn(process, 'cwd').mockReturnValue(cwdDir);
      const log = jest.fn();
      ensurePluginInstalled(path.join(startDir, 'dist'), log);
      expect(log).not.toHaveBeenCalled();
      expect(fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin'))).toBe(false);
    } finally {
      fs.rmSync(cwdDir, { recursive: true, force: true });
    }
  });

  it('logs a failure message when the install throws', () => {
    bundlePluginIn(startDir);
    jest.spyOn(fs, 'mkdirSync').mockImplementation(() => {
      throw new Error('disk full');
    });
    const log = jest.fn();
    ensurePluginInstalled(path.join(startDir, 'dist'), log);
    expect(log).toHaveBeenCalledWith(expect.stringContaining('failed: disk full'));
  });
});
