import { describe, it, expect, beforeEach, afterEach, jest } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  ensurePluginInstalled,
  findBundledPlugin,
  findPluginInCwd,
  describeInstall,
  installPlugin,
  lightroomModulesDir,
  lightroomPluginsDir,
} from '../src/install-plugin.js';

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

  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-install-'));
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-home-'));
    setPlatform('linux');
    jest.spyOn(os, 'homedir').mockReturnValue(home);
  });

  afterEach(() => {
    restoreEnv();
    fs.rmSync(tmp, { recursive: true, force: true });
    fs.rmSync(home, { recursive: true, force: true });
  });

  function makeFakePlugin(parent: string, identity: { id?: string; version?: string | null } = {}): string {
    const src = path.join(parent, 'LightroomAgent.lrplugin');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'Info.lua'), `return {\n    LrToolkitIdentifier = '${identity.id ?? 'io.test.agent'}',\n}\n`);
    if (identity.version !== null) {
      fs.writeFileSync(path.join(src, 'Contract.lua'), `return {\n    VERSION = "${identity.version ?? '1.0.0'}",\n}\n`);
    }
    fs.writeFileSync(path.join(src, 'Handler.lua'), '-- handler');
    return src;
  }

  it('copies the plugin into destDir on first install', () => {
    const sourceParent = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-'));
    try {
      const source = makeFakePlugin(sourceParent);
      const result = installPlugin({ source, destDir: tmp });
      expect(result).toEqual({ status: 'installed', destination: path.join(tmp, 'LightroomAgent.lrplugin') });
      expect(fs.existsSync(path.join(tmp, 'LightroomAgent.lrplugin', 'Info.lua'))).toBe(true);
      expect(fs.existsSync(path.join(tmp, 'LightroomAgent.lrplugin', 'Handler.lua'))).toBe(true);
    } finally {
      fs.rmSync(sourceParent, { recursive: true, force: true });
    }
  });

  it('copies nested directories recursively', () => {
    const sourceParent = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-'));
    try {
      const source = makeFakePlugin(sourceParent);
      fs.mkdirSync(path.join(source, 'sub'));
      fs.writeFileSync(path.join(source, 'sub', 'Nested.lua'), '-- nested');
      installPlugin({ source, destDir: tmp });
      expect(fs.existsSync(path.join(tmp, 'LightroomAgent.lrplugin', 'sub', 'Nested.lua'))).toBe(true);
    } finally {
      fs.rmSync(sourceParent, { recursive: true, force: true });
    }
  });

  it('preserves symlinks when copying', () => {
    if (realPlatform === 'win32') return;
    const sourceParent = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-'));
    try {
      const source = makeFakePlugin(sourceParent);
      fs.symlinkSync('Info.lua', path.join(source, 'Info.link.lua'));
      installPlugin({ source, destDir: tmp });
      const copied = path.join(tmp, 'LightroomAgent.lrplugin', 'Info.link.lua');
      expect(fs.lstatSync(copied).isSymbolicLink()).toBe(true);
      expect(fs.readlinkSync(copied)).toBe('Info.lua');
    } finally {
      fs.rmSync(sourceParent, { recursive: true, force: true });
    }
  });

  it('leaves a bundle of this plug-in at the same version alone', () => {
    const source = makeFakePlugin(fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-')));
    installPlugin({ source, destDir: tmp });
    const kept = path.join(tmp, 'LightroomAgent.lrplugin', 'Handler.lua');
    fs.writeFileSync(kept, '-- modified');

    const result = installPlugin({ source, destDir: tmp });

    expect(result).toEqual({ status: 'current', destination: path.join(tmp, 'LightroomAgent.lrplugin') });
    expect(fs.readFileSync(kept, 'utf8')).toBe('-- modified');
  });

  it.each([
    ['another version', '0.9.0', '0.9.0'],
    ['no version', null, null],
  ])('replaces a bundle of this plug-in that reports %s', (_what, installedVersion, from) => {
    installPlugin({ source: makeFakePlugin(fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-old-')), { version: installedVersion }), destDir: tmp });
    fs.writeFileSync(path.join(tmp, 'LightroomAgent.lrplugin', 'Stale.lua'), '-- gone in the new build');

    const result = installPlugin({ source: makeFakePlugin(fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-')), { version: '1.0.0' }), destDir: tmp });

    expect(result).toEqual({ status: 'replaced', destination: path.join(tmp, 'LightroomAgent.lrplugin'), from, to: '1.0.0' });
    expect(fs.existsSync(path.join(tmp, 'LightroomAgent.lrplugin', 'Stale.lua'))).toBe(false);
    expect(fs.readFileSync(path.join(tmp, 'LightroomAgent.lrplugin', 'Contract.lua'), 'utf8')).toContain('VERSION = "1.0.0"');
  });

  it('leaves another plug-in that sits in the folder alone', () => {
    installPlugin({ source: makeFakePlugin(fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-other-')), { id: 'com.other.plugin', version: '0.1.0' }), destDir: tmp });

    const result = installPlugin({ source: makeFakePlugin(fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-'))), destDir: tmp });

    expect(result).toEqual({ status: 'foreign', destination: path.join(tmp, 'LightroomAgent.lrplugin'), toolkitId: 'com.other.plugin' });
    expect(fs.readFileSync(path.join(tmp, 'LightroomAgent.lrplugin', 'Contract.lua'), 'utf8')).toContain('VERSION = "0.1.0"');
  });

  it('replaces an outdated bundle where it is installed, Plugins included', () => {
    const installed = path.join(lightroomPluginsDir(), 'LightroomAgent.lrplugin');
    fs.mkdirSync(path.dirname(installed), { recursive: true });
    fs.cpSync(makeFakePlugin(fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-old-')), { version: '0.9.0' }), installed, { recursive: true });

    const result = installPlugin({ source: makeFakePlugin(fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-'))) });

    expect(result).toEqual({ status: 'replaced', destination: installed, from: '0.9.0', to: '1.0.0' });
    expect(fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin'))).toBe(false);
  });

  it.each([
    [{ status: 'installed', destination: '/M/LightroomAgent.lrplugin' }, 'installed /M/LightroomAgent.lrplugin; restart Lightroom to load it'],
    [{ status: 'replaced', destination: '/M/LightroomAgent.lrplugin', from: '0.9.0', to: '1.0.0' }, 'replaced /M/LightroomAgent.lrplugin (version 0.9.0 → 1.0.0); restart Lightroom to load it'],
    [{ status: 'replaced', destination: '/M/LightroomAgent.lrplugin', from: null, to: '1.0.0' }, 'replaced /M/LightroomAgent.lrplugin (version unknown → 1.0.0); restart Lightroom to load it'],
    [{ status: 'current', destination: '/M/LightroomAgent.lrplugin' }, '/M/LightroomAgent.lrplugin is already this version'],
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

    ensurePluginInstalled(startDir, log);

    expect(log).toHaveBeenCalledWith(
      `[install-plugin] The installed ${path.join(dirOf(), 'LightroomMCP.lrplugin')} binds the same ports. `
        + 'Quit Lightroom, remove that folder, then install again.',
    );
    expect(fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin'))).toBe(false);
  });
});

describe('findBundledPlugin', () => {
  it('returns null when no plugin directory found', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-find-'));
    try {
      expect(findBundledPlugin(dir)).toBeNull();
    } finally {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  it('finds plugin one level up', () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-find-'));
    try {
      const plug = path.join(root, 'LightroomAgent.lrplugin');
      fs.mkdirSync(plug);
      fs.writeFileSync(path.join(plug, 'Info.lua'), '-- fake');
      const child = path.join(root, 'server', 'dist');
      fs.mkdirSync(child, { recursive: true });
      const found = findBundledPlugin(child);
      expect(found).not.toBeNull();
      expect(path.resolve(found!)).toBe(path.resolve(plug));
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });
});

describe('plugin lookup in the cwd', () => {
  let dir: string;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-exe-'));
  });

  afterEach(() => {
    jest.restoreAllMocks();
    fs.rmSync(dir, { recursive: true, force: true });
  });

  function bundlePluginIn(parent: string): string {
    const plug = path.join(parent, 'LightroomAgent.lrplugin');
    fs.mkdirSync(plug, { recursive: true });
    fs.writeFileSync(path.join(plug, 'Info.lua'), '-- fake');
    return path.resolve(plug);
  }

  it('finds the plugin folder in the working directory', () => {
    const plug = bundlePluginIn(dir);
    jest.spyOn(process, 'cwd').mockReturnValue(dir);
    expect(findPluginInCwd()).toBe(plug);
  });

  it('does not walk parent dirs of the working directory', () => {
    bundlePluginIn(path.join(dir, 'plugin'));
    bundlePluginIn(dir);
    const sub = path.join(dir, 'sub');
    fs.mkdirSync(sub);
    jest.spyOn(process, 'cwd').mockReturnValue(sub);
    expect(findPluginInCwd()).toBeNull();
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
    fs.writeFileSync(path.join(src, 'Contract.lua'), `return {\n    VERSION = "${version}",\n}\n`);
  }

  it('leaves a bundle at the server version alone without logging', () => {
    bundlePluginIn(startDir);
    bundlePluginIn(lightroomModulesDir());
    const log = jest.fn();
    ensurePluginInstalled(startDir, log);
    expect(log).not.toHaveBeenCalled();
  });

  it('replaces an outdated bundle of this plug-in and logs both versions', () => {
    bundlePluginIn(startDir, '1.0.0');
    bundlePluginIn(lightroomModulesDir(), '1.0.0-rc.0');
    const log = jest.fn();
    ensurePluginInstalled(startDir, log);
    expect(log).toHaveBeenCalledWith(`[install-plugin] replaced ${path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin')} `
      + '(version 1.0.0-rc.0 → 1.0.0); restart Lightroom to load it');
  });

  it('does nothing when no bundled plugin can be found', () => {
    const log = jest.fn();
    ensurePluginInstalled(startDir, log);
    expect(log).not.toHaveBeenCalled();
  });

  it('installs the bundled plugin and logs progress', () => {
    bundlePluginIn(startDir);
    const log = jest.fn();
    ensurePluginInstalled(startDir, log);
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
      ensurePluginInstalled(startDir, log);
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
    ensurePluginInstalled(startDir, log);
    expect(log).toHaveBeenCalledWith(expect.stringContaining('failed: disk full'));
  });
});
