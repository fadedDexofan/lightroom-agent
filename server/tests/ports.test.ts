import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'node:fs';
import path from 'node:path';
import { requestPort, responsePort, writePortDefaults } from '../src/ports.js';

describe('ports', () => {
  const originalReq = process.env.LIGHTROOM_AGENT_REQUEST_PORT;
  const originalRes = process.env.LIGHTROOM_AGENT_RESPONSE_PORT;

  beforeEach(() => {
    delete process.env.LIGHTROOM_AGENT_REQUEST_PORT;
    delete process.env.LIGHTROOM_AGENT_RESPONSE_PORT;
  });

  afterEach(() => {
    if (originalReq === undefined) delete process.env.LIGHTROOM_AGENT_REQUEST_PORT;
    else process.env.LIGHTROOM_AGENT_REQUEST_PORT = originalReq;
    if (originalRes === undefined) delete process.env.LIGHTROOM_AGENT_RESPONSE_PORT;
    else process.env.LIGHTROOM_AGENT_RESPONSE_PORT = originalRes;
  });

  it('returns default request port when env unset', () => {
    expect(requestPort()).toBe(58763);
  });

  it('returns default response port when env unset', () => {
    expect(responsePort()).toBe(58764);
  });

  it('treats empty env value as unset', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '';
    process.env.LIGHTROOM_AGENT_RESPONSE_PORT = '   ';
    expect(requestPort()).toBe(58763);
    expect(responsePort()).toBe(58764);
  });

  it('accepts a valid override', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '12345';
    process.env.LIGHTROOM_AGENT_RESPONSE_PORT = '12346';
    expect(requestPort()).toBe(12345);
    expect(responsePort()).toBe(12346);
  });

  it('trims surrounding whitespace', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '  9000  ';
    expect(requestPort()).toBe(9000);
  });

  it('throws on non-numeric value', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = 'abc';
    expect(() => requestPort()).toThrow(/LIGHTROOM_AGENT_REQUEST_PORT/);
    expect(() => requestPort()).toThrow(/abc/);
  });

  it('throws on zero', () => {
    process.env.LIGHTROOM_AGENT_RESPONSE_PORT = '0';
    expect(() => responsePort()).toThrow(/LIGHTROOM_AGENT_RESPONSE_PORT/);
  });

  it('throws on 65536', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '65536';
    expect(() => requestPort()).toThrow(/LIGHTROOM_AGENT_REQUEST_PORT/);
  });

  it('throws on negative', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '-1';
    expect(() => requestPort()).toThrow(/LIGHTROOM_AGENT_REQUEST_PORT/);
  });

  it('throws on float', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '1234.5';
    expect(() => requestPort()).toThrow(/LIGHTROOM_AGENT_REQUEST_PORT/);
  });

  it('accepts boundary values', () => {
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '1';
    expect(requestPort()).toBe(1);
    process.env.LIGHTROOM_AGENT_REQUEST_PORT = '65535';
    expect(requestPort()).toBe(65535);
  });

  it('carries changed defaults into the desktop bundle and the registry, and the bundle hands them to the server', () => {
    type Manifest = Parameters<typeof writePortDefaults>[0];
    type Registry = Parameters<typeof writePortDefaults>[1];
    const read = <T>(file: string): T =>
      JSON.parse(fs.readFileSync(path.resolve(process.cwd(), '..', file), 'utf8')) as T;
    const manifest = read<Manifest>('mcpb/manifest.json');
    const registry = read<Registry>('server.json');

    writePortDefaults(manifest, registry, { request: 50001, response: 50002 });

    const env = manifest.server.mcp_config.env;
    for (const name of ['LIGHTROOM_AGENT_REQUEST_PORT', 'LIGHTROOM_AGENT_RESPONSE_PORT']) {
      process.env[name] = env[name].replace(/^\$\{user_config\.(\w+)\}$/, (_, key: string) =>
        String(manifest.user_config[key].default),
      );
    }
    expect([requestPort(), responsePort()]).toEqual([50001, 50002]);
    const variables = registry.packages
      .flatMap((entry) => entry.environmentVariables ?? [])
      .filter((variable) => variable.name.endsWith('_PORT'));
    expect(variables.map((variable) => [variable.name, variable.default])).toEqual([
      ['LIGHTROOM_AGENT_REQUEST_PORT', '50001'],
      ['LIGHTROOM_AGENT_RESPONSE_PORT', '50002'],
    ]);
  });
});
