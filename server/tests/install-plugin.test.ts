import { describe, it, expect, beforeEach, afterEach, jest } from '@jest/globals';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  admitLeader,
  describeInstall,
  installPlugin,
  lightroomModulesDir,
  lightroomPluginsDir,
} from '../src/install-plugin.js';
import { expectedIdentity, renderContractLua } from '../src/contract-lua.js';
import { PairingLost, type Paired } from '../src/plugin-pairing.js';
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
    expect(
      lightroomModulesDir().endsWith(path.join('Library', 'Application Support', 'Adobe', 'Lightroom', 'Modules')),
    ).toBe(true);
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
    expect(lightroomModulesDir().endsWith(path.join('.local', 'share', 'Adobe', 'Lightroom', 'Modules'))).toBe(true);
  });
});

describe('lightroomPluginsDir', () => {
  afterEach(restoreEnv);

  it('returns a darwin path on macOS', () => {
    setPlatform('darwin');
    expect(
      lightroomPluginsDir().endsWith(path.join('Library', 'Application Support', 'Adobe', 'Lightroom', 'Plugins')),
    ).toBe(true);
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
    expect(lightroomPluginsDir().endsWith(path.join('.local', 'share', 'Adobe', 'Lightroom', 'Plugins'))).toBe(true);
  });
});

function bundled(root: string, name = 'src', files: Record<string, string> = {}): Paired {
  const source = path.join(root, name, 'LightroomAgent.lrplugin');
  fs.mkdirSync(source, { recursive: true });
  fs.writeFileSync(path.join(source, 'Info.lua'), "return {\n    LrToolkitIdentifier = 'io.test.agent',\n}\n");
  fs.writeFileSync(path.join(source, 'Handler.lua'), '-- handler');
  for (const [file, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(source, file)), { recursive: true });
    fs.writeFileSync(path.join(source, file), text);
  }
  const plugin = expectedIdentity(source);
  fs.writeFileSync(path.join(source, 'Contract.lua'), renderContractLua(plugin));
  return { kind: 'paired', plugin, source, layout: 'checkout' };
}

function placeBundle(
  destination: string,
  identity: { id?: string; version?: string | null; build?: string | null } = {},
): void {
  fs.mkdirSync(destination, { recursive: true });
  fs.writeFileSync(
    path.join(destination, 'Info.lua'),
    `return {\n    LrToolkitIdentifier = '${identity.id ?? 'io.test.agent'}',\n}\n`,
  );
  if (identity.version !== null) {
    const build = identity.build === null ? '' : `    BUILD = "${identity.build ?? 'b1'}",\n`;
    fs.writeFileSync(
      path.join(destination, 'Contract.lua'),
      `return {\n    VERSION = "${identity.version ?? '0.9.0'}",\n${build}}\n`,
    );
  }
  fs.writeFileSync(path.join(destination, 'Handler.lua'), '-- old handler');
}

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

  it("copies the plugin into Lightroom's Modules folder on first install", () => {
    const result = installPlugin(bundled(tmp));

    expect(result).toEqual({ status: 'installed', destination: installed });
    expect(fs.existsSync(path.join(installed, 'Info.lua'))).toBe(true);
    expect(fs.existsSync(path.join(installed, 'Handler.lua'))).toBe(true);
  });

  it('copies nested directories recursively', () => {
    installPlugin(bundled(tmp, 'src', { 'sub/Nested.lua': '-- nested' }));

    expect(fs.existsSync(path.join(installed, 'sub', 'Nested.lua'))).toBe(true);
  });

  it('copies regular files only, leaving links behind, dangling ones included', () => {
    if (realPlatform === 'win32') return;
    const pairing = bundled(tmp);
    fs.symlinkSync('Info.lua', path.join(pairing.source, 'Info.link.lua'));
    fs.symlinkSync('gone.lua', path.join(pairing.source, 'Dangling.lua'));

    expect(installPlugin(pairing).status).toBe('installed');

    expect(fs.readdirSync(installed).sort()).toEqual(['Contract.lua', 'Handler.lua', 'Info.lua']);
  });

  it("leaves an installed bundle with this build's files alone, and repairs one whose files changed under its stamp", () => {
    const pairing = bundled(tmp);
    installPlugin(pairing);
    expect(installPlugin(pairing)).toEqual({ status: 'current', destination: installed });
    const edited = path.join(installed, 'Handler.lua');
    fs.writeFileSync(edited, '-- modified');

    expect(installPlugin(pairing)).toEqual({ status: 'repaired', destination: installed });

    expect(fs.readFileSync(edited, 'utf8')).toBe('-- handler');
  });

  it.each([
    ['another version', { version: '0.9.0' }, { version: '0.9.0', build: 'b1' }],
    ['another build of the same version', { version: VERSION, build: 'b0' }, { version: VERSION, build: 'b0' }],
    ['no version', { version: null }, { version: null, build: null }],
    ['a newer version', { version: '9.0.0' }, { version: '9.0.0', build: 'b1' }],
  ])('replaces a bundle of this plug-in that reports %s', (_what, installedIdentity, from) => {
    placeBundle(installed, installedIdentity);
    fs.writeFileSync(path.join(installed, 'Stale.lua'), '-- gone in the new build');
    const pairing = bundled(tmp);

    const result = installPlugin(pairing);

    expect(result).toEqual({ status: 'replaced', destination: installed, from, to: pairing.plugin });
    expect(fs.existsSync(path.join(installed, 'Stale.lua'))).toBe(false);
    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toBe(
      fs.readFileSync(path.join(pairing.source, 'Contract.lua'), 'utf8'),
    );
  });

  it('keeps the installed bundle whole when copying its replacement fails', () => {
    placeBundle(installed);
    const pairing = bundled(tmp);
    const copy = fs.copyFileSync;
    let copies = 0;
    jest.spyOn(fs, 'copyFileSync').mockImplementation((from, to, mode) => {
      copies += 1;
      if (copies === 2) throw new Error('disk full');
      copy(from, to, mode);
    });

    expect(() => installPlugin(pairing)).toThrow('disk full');

    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toContain('VERSION = "0.9.0"');
    expect(fs.readdirSync(lightroomModulesDir())).toEqual(['LightroomAgent.lrplugin']);
  });

  it('reads the identity of the real bundle: its toolkit id, the server version and the build in its generated contract', () => {
    placeBundle(installed, { id: 'io.github.fadeddexofan.lightroomagent', version: '0.0.1' });
    const source = path.resolve(process.cwd(), '..', 'plugin', 'LightroomAgent.lrplugin');

    const result = installPlugin({ kind: 'paired', plugin: expectedIdentity(source), source, layout: 'checkout' });

    expect(result).toEqual({
      status: 'replaced',
      destination: installed,
      from: { version: '0.0.1', build: 'b1' },
      to: { version: VERSION, build: expect.stringMatching(/^[0-9a-f]{16}$/) },
    });
  });

  it('keeps a whole bundle in place when removing the replaced one is interrupted, and clears the remnant next time', () => {
    placeBundle(installed);
    const pairing = bundled(tmp);
    const remove = fs.rmSync;
    const interrupted = jest.spyOn(fs, 'rmSync').mockImplementation((target, options) => {
      const info = path.join(String(target), 'Info.lua');
      if (fs.existsSync(info)) {
        fs.unlinkSync(info);
        throw new Error('killed');
      }
      remove(target, options);
    });

    expect(() => installPlugin(pairing)).toThrow('killed');
    interrupted.mockRestore();

    expect(fs.existsSync(path.join(installed, 'Info.lua'))).toBe(true);
    expect(installPlugin(pairing).status).toBe('current');
    expect(fs.readdirSync(lightroomModulesDir())).toEqual(['LightroomAgent.lrplugin']);
  });

  it('puts the installed bundle back whole when moving the copy into place fails, then replaces it whole', () => {
    placeBundle(installed);
    const pairing = bundled(tmp);
    const rename = fs.renameSync;
    const interrupted = jest.spyOn(fs, 'renameSync').mockImplementation((from, to) => {
      if (String(from).includes('.installing')) throw new Error('locked');
      rename(from, to);
    });

    expect(() => installPlugin(pairing)).toThrow('locked');
    interrupted.mockRestore();

    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toContain('VERSION = "0.9.0"');
    expect(fs.readdirSync(lightroomModulesDir())).toEqual(['LightroomAgent.lrplugin']);
    expect(installPlugin(pairing)).toEqual({
      status: 'replaced',
      destination: installed,
      from: { version: '0.9.0', build: 'b1' },
      to: pairing.plugin,
    });
  });

  it('names where the previous bundle stays when it cannot be put back either', () => {
    placeBundle(installed);
    const pairing = bundled(tmp);
    const rename = fs.renameSync;
    jest.spyOn(fs, 'renameSync').mockImplementation((from, to) => {
      if (String(from).includes('.installing') || String(from).endsWith('.replaced')) throw new Error('locked');
      rename(from, to);
    });

    expect(() => installPlugin(pairing)).toThrow(`locked; the previous bundle stays at ${installed}.replaced`);
    expect(fs.existsSync(path.join(`${installed}.replaced`, 'Info.lua'))).toBe(true);
  });

  it("reads an installed bundle checked out with CRLF line endings as this build's files", () => {
    const pairing = bundled(tmp);
    installPlugin(pairing);
    for (const file of ['Contract.lua', 'Handler.lua']) {
      const target = path.join(installed, file);
      fs.writeFileSync(target, fs.readFileSync(target, 'utf8').replace(/\n/g, '\r\n'));
    }

    expect(installPlugin(pairing).status).toBe('current');
  });

  it('refuses, leaving the installed bundle alone, a bundled source that does not validate against the build', () => {
    placeBundle(installed);
    const pairing = bundled(tmp);
    fs.writeFileSync(path.join(pairing.source, 'Contract.lua'), `return {\n    VERSION = "${VERSION}",\n}\n`);

    expect(installPlugin(pairing)).toEqual({ status: 'invalid', source: pairing.source });

    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toContain('VERSION = "0.9.0"');
    expect(fs.readdirSync(lightroomModulesDir())).toEqual(['LightroomAgent.lrplugin']);
  });

  it('leaves another plug-in that sits in the folder alone', () => {
    placeBundle(installed, { id: 'com.other.plugin', version: '0.1.0' });

    const result = installPlugin(bundled(tmp));

    expect(result).toEqual({ status: 'foreign', destination: installed, toolkitId: 'com.other.plugin' });
    expect(fs.readFileSync(path.join(installed, 'Contract.lua'), 'utf8')).toContain('VERSION = "0.1.0"');
  });

  it('replaces an outdated bundle where it is installed, Plugins included', () => {
    const inPlugins = path.join(lightroomPluginsDir(), 'LightroomAgent.lrplugin');
    placeBundle(inPlugins);
    const pairing = bundled(tmp);

    const result = installPlugin(pairing);

    expect(result).toEqual({
      status: 'replaced',
      destination: inPlugins,
      from: { version: '0.9.0', build: 'b1' },
      to: pairing.plugin,
    });
    expect(fs.existsSync(installed)).toBe(false);
  });

  it.each([
    [
      { status: 'installed', destination: '/M/LightroomAgent.lrplugin' },
      'installed /M/LightroomAgent.lrplugin; restart Lightroom to load it',
    ],
    [
      {
        status: 'replaced',
        destination: '/M/LightroomAgent.lrplugin',
        from: { version: '0.9.0', build: 'b0' },
        to: { version: '1.0.0', build: 'b1' },
      },
      'replaced /M/LightroomAgent.lrplugin (version 0.9.0 → 1.0.0); restart Lightroom to load it',
    ],
    [
      {
        status: 'replaced',
        destination: '/M/LightroomAgent.lrplugin',
        from: { version: '1.0.0', build: 'b1' },
        to: { version: '1.0.0-rc.2', build: 'b0' },
      },
      'replaced /M/LightroomAgent.lrplugin (version 1.0.0 → 1.0.0-rc.2, older); restart Lightroom to load it',
    ],
    [
      {
        status: 'replaced',
        destination: '/M/LightroomAgent.lrplugin',
        from: { version: null, build: null },
        to: { version: '1.0.0', build: 'b1' },
      },
      'replaced /M/LightroomAgent.lrplugin (version unknown → 1.0.0); restart Lightroom to load it',
    ],
    [
      {
        status: 'replaced',
        destination: '/M/LightroomAgent.lrplugin',
        from: { version: '1.0.0', build: 'b0' },
        to: { version: '1.0.0', build: 'b1' },
      },
      'replaced /M/LightroomAgent.lrplugin (version 1.0.0, build b0 → b1); restart Lightroom to load it',
    ],
    [
      { status: 'repaired', destination: '/M/LightroomAgent.lrplugin' },
      "repaired the installed plug-in's files in /M/LightroomAgent.lrplugin; restart Lightroom to load them",
    ],
    [
      { status: 'current', destination: '/M/LightroomAgent.lrplugin' },
      '/M/LightroomAgent.lrplugin is already this build',
    ],
    [
      { status: 'foreign', destination: '/M/LightroomAgent.lrplugin', toolkitId: 'com.other' },
      '/M/LightroomAgent.lrplugin holds another plug-in (com.other) and was left alone. Remove it, then install again.',
    ],
    [
      { status: 'conflict', conflicting: '/M/LightroomMCP.lrplugin' },
      'The installed /M/LightroomMCP.lrplugin binds the same ports. Quit Lightroom, remove that folder, then install again.',
    ],
    [
      { status: 'invalid', source: '/S/LightroomAgent.lrplugin' },
      "refused: the bundled plug-in /S/LightroomAgent.lrplugin does not validate against this server's build, so nothing was installed",
    ],
  ] as const)('describes %o', (result, line) => {
    expect(describeInstall(result)).toBe(line);
  });
});

describe.each([
  ['Modules', lightroomModulesDir],
  ['Plugins', lightroomPluginsDir],
])('a LightroomMCP.lrplugin in %s', (_where, dirOf) => {
  let home: string;
  let tmp: string;

  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-home-'));
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-start-'));
    setPlatform('linux');
    jest.spyOn(os, 'homedir').mockReturnValue(home);
    const upstream = path.join(dirOf(), 'LightroomMCP.lrplugin');
    fs.mkdirSync(upstream, { recursive: true });
    fs.writeFileSync(path.join(upstream, 'Info.lua'), '-- upstream');
  });

  afterEach(() => {
    restoreEnv();
    fs.rmSync(home, { recursive: true, force: true });
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it('makes install refuse and copy nothing', () => {
    const result = installPlugin(bundled(tmp));

    expect(result).toEqual({ status: 'conflict', conflicting: path.join(dirOf(), 'LightroomMCP.lrplugin') });
    expect(fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin'))).toBe(false);
  });

  it("makes the leader's install log the conflict instead of installing", () => {
    const log = jest.fn();

    admitLeader(bundled(tmp), true, log);

    expect(log).toHaveBeenCalledWith(
      `[install-plugin] The installed ${path.join(dirOf(), 'LightroomMCP.lrplugin')} binds the same ports. ` +
        'Quit Lightroom, remove that folder, then install again.',
    );
    expect(fs.existsSync(path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin'))).toBe(false);
  });
});

describe('admitLeader', () => {
  let home: string;
  let tmp: string;

  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-home-'));
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lragent-start-'));
    setPlatform('linux');
    jest.spyOn(os, 'homedir').mockReturnValue(home);
  });

  afterEach(() => {
    restoreEnv();
    fs.rmSync(home, { recursive: true, force: true });
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  const destination = () => path.join(lightroomModulesDir(), 'LightroomAgent.lrplugin');

  it("leaves a bundle with this build's files alone without logging", () => {
    const pairing = bundled(tmp);
    installPlugin(pairing);
    const log = jest.fn();
    admitLeader(pairing, true, log);
    expect(log).not.toHaveBeenCalled();
  });

  it('replaces an outdated bundle of this plug-in and logs both versions', () => {
    placeBundle(destination(), { version: '0.1.0-rc.0' });
    const log = jest.fn();
    admitLeader(bundled(tmp), true, log);
    expect(log).toHaveBeenCalledWith(
      `[install-plugin] replaced ${destination()} (version 0.1.0-rc.0 → ${VERSION}); restart Lightroom to load it`,
    );
  });

  it('installs the bundled plugin and logs progress', () => {
    const log = jest.fn();
    admitLeader(bundled(tmp), true, log);
    expect(log).toHaveBeenCalledWith(`[install-plugin] installed ${destination()}; restart Lightroom to load it`);
    expect(fs.existsSync(path.join(destination(), 'Info.lua'))).toBe(true);
  });

  it.each([
    [
      'a newer version',
      { version: '9.0.0' },
      (own: Paired['plugin']) =>
        `Lightroom's installed plug-in is version 9.0.0, newer than this server's version ${own.version}, so this server leaves it alone and does not connect to Lightroom. Update lightroom-agent in this client, or remove an outdated server entry, then restart the client.`,
    ],
    [
      'another build of the same version',
      { version: VERSION, build: 'b0' },
      (own: Paired['plugin']) =>
        `Lightroom's installed plug-in is another build (installed: version ${VERSION}, build b0; this server's: version ${own.version}, build ${own.build}), so this server leaves it alone and does not connect to Lightroom. To use this build, quit the other clients, run this build's install-plugin, restart Lightroom, then start the clients again.`,
    ],
    [
      'no readable contract',
      { version: null },
      (own: Paired['plugin']) =>
        `Lightroom's installed plug-in is another build (installed: version unknown, build unknown; this server's: version ${own.version}, build ${own.build}), so this server leaves it alone and does not connect to Lightroom. To use this build, quit the other clients, run this build's install-plugin, restart Lightroom, then start the clients again.`,
    ],
  ] as const)(
    'refuses to lead over an installed bundle of %s, installing or checking alike, and leaves it alone',
    (_what, identity, refusal) => {
      placeBundle(destination(), identity);
      const before = fs
        .readdirSync(destination())
        .map((file) => fs.readFileSync(path.join(destination(), file), 'utf8'));
      const pairing = bundled(tmp);
      const log = jest.fn();

      for (const install of [true, false]) {
        expect(() => admitLeader(pairing, install, log)).toThrow(new PairingLost(refusal(pairing.plugin)));
      }

      expect(
        fs.readdirSync(destination()).map((file) => fs.readFileSync(path.join(destination(), file), 'utf8')),
      ).toEqual(before);
      expect(log).not.toHaveBeenCalled();
    },
  );

  it('admits the leader over an older bundle that carries no build, as 0.1.0-rc.0 did, and replaces it', () => {
    placeBundle(destination(), { version: '0.1.0-rc.0', build: null });
    const log = jest.fn();

    admitLeader(bundled(tmp), true, log);

    expect(log).toHaveBeenCalledWith(
      `[install-plugin] replaced ${destination()} (version 0.1.0-rc.0 → ${VERSION}); restart Lightroom to load it`,
    );
    expect(fs.readFileSync(path.join(destination(), 'Contract.lua'), 'utf8')).toContain(`VERSION = "${VERSION}"`);
  });

  it('repairs an installed bundle of this build whose version cannot be read', () => {
    const pairing = bundled(tmp);
    placeBundle(destination(), { version: 'not a version', build: pairing.plugin.build });
    const log = jest.fn();

    admitLeader(pairing, true, log);

    expect(log).toHaveBeenCalledWith(
      `[install-plugin] repaired the installed plug-in's files in ${destination()}; restart Lightroom to load them`,
    );
  });

  it('checks without installing when it is not to install', () => {
    placeBundle(destination(), { version: '0.0.1' });
    const log = jest.fn();

    admitLeader(bundled(tmp), false, log);

    expect(fs.readFileSync(path.join(destination(), 'Contract.lua'), 'utf8')).toContain('VERSION = "0.0.1"');
    expect(log).not.toHaveBeenCalled();
  });

  it('logs a failure to read the plug-in folders and admits the leader without installing', () => {
    placeBundle(destination(), { version: '0.0.1' });
    const read = fs.readdirSync;
    jest.spyOn(fs, 'readdirSync').mockImplementation(((dir: fs.PathLike, ...rest: never[]) => {
      if (String(dir) === lightroomModulesDir()) throw new Error('EACCES: permission denied');
      return (read as (...args: unknown[]) => unknown)(dir, ...rest);
    }) as typeof fs.readdirSync);
    const log = jest.fn();

    admitLeader(bundled(tmp), true, log);

    expect(log).toHaveBeenCalledWith('[install-plugin] failed: EACCES: permission denied');
    expect(fs.readFileSync(path.join(destination(), 'Contract.lua'), 'utf8')).toContain('VERSION = "0.0.1"');
  });

  it('logs a failure message when the install throws', () => {
    const pairing = bundled(tmp);
    jest.spyOn(fs, 'mkdirSync').mockImplementation(() => {
      throw new Error('disk full');
    });
    const log = jest.fn();
    admitLeader(pairing, true, log);
    expect(log).toHaveBeenCalledWith(expect.stringContaining('failed: disk full'));
  });
});
