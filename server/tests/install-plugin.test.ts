import { describe, it, expect, beforeEach, afterEach, jest } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  ensurePluginInstalled,
  findBundledPlugin,
  findPluginInCwd,
  installPlugin,
  isPluginInstalledAnywhere,
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

describe('isPluginInstalledAnywhere', () => {
  let home: string;

  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-home-'));
    setPlatform('linux');
    jest.spyOn(os, 'homedir').mockReturnValue(home);
  });

  afterEach(() => {
    restoreEnv();
    fs.rmSync(home, { recursive: true, force: true });
  });

  it('returns false when no plugin is present', () => {
    expect(isPluginInstalledAnywhere()).toBe(false);
  });

  it('returns true when Info.lua is present in the modules dir', () => {
    const dir = path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'Info.lua'), '-- fake');
    expect(isPluginInstalledAnywhere()).toBe(true);
  });

  it('returns true when Info.lua is present in the plugins dir', () => {
    const dir = path.join(lightroomPluginsDir(), 'LightroomAgent.lrplugin');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'Info.lua'), '-- fake');
    expect(isPluginInstalledAnywhere()).toBe(true);
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

  function makeFakePlugin(parent: string): string {
    const src = path.join(parent, 'LightroomAgent.lrplugin');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'Info.lua'), '-- fake');
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

  it('reports already-present without overwriting on second call', () => {
    const sourceParent = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-src-'));
    try {
      const source = makeFakePlugin(sourceParent);
      installPlugin({ source, destDir: tmp });
      const dest = path.join(tmp, 'LightroomAgent.lrplugin', 'Info.lua');
      fs.writeFileSync(dest, '-- modified');
      const result = installPlugin({ source, destDir: tmp });
      expect(result.status).toBe('already-present');
      expect(fs.readFileSync(dest, 'utf8')).toBe('-- modified');
    } finally {
      fs.rmSync(sourceParent, { recursive: true, force: true });
    }
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
      `[install-plugin] ${path.join(dirOf(), 'LightroomMCP.lrplugin')} is installed: upstream's lightroom-mcp plug-in `
        + 'binds the same ports. Quit Lightroom, remove that folder, then install again.',
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

  function bundlePluginIn(dir: string): void {
    const src = path.join(dir, 'LightroomAgent.lrplugin');
    fs.mkdirSync(src, { recursive: true });
    fs.writeFileSync(path.join(src, 'Info.lua'), '-- fake');
  }

  it('returns early without logging when a plugin is already installed', () => {
    const installed = path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin');
    fs.mkdirSync(installed, { recursive: true });
    fs.writeFileSync(path.join(installed, 'Info.lua'), '-- fake');
    const log = jest.fn();
    ensurePluginInstalled(startDir, log);
    expect(log).not.toHaveBeenCalled();
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
    expect(log).toHaveBeenCalledWith(expect.stringContaining('copied'));
    expect(log).toHaveBeenCalledWith(expect.stringContaining('restart Lightroom'));
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
