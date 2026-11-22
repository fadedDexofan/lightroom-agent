import { describe, it, expect } from '@jest/globals';
import { Client, InMemoryTransport } from '@modelcontextprotocol/client';
import { VERSION } from '../src/version.js';
import { createMcpServer } from '../src/create-server.js';
import { createToolAccess } from '../src/tool-access.js';
import { createCallToolHandler } from '../src/tool-handler.js';

describe('server version', () => {
  it('MCP server reports the shared version', async () => {
    const server = createMcpServer(
      createCallToolHandler({
        admitted: () => 0,
        dispatcher: { call: async () => ({ id: 'x', result: {} }) },
      }),
      createToolAccess({ toolsets: ['core'], readOnly: false }),
    );
    const client = new Client({ name: 'test-client', version: '1.0.0' });
    const [clientT, serverT] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(serverT), client.connect(clientT)]);
    expect(client.getServerVersion()?.version).toBe(VERSION);
    await client.close();
  });
});
