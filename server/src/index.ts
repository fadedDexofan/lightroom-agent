#!/usr/bin/env node

import path from "node:path";
import { fileURLToPath } from "node:url";
import { StdioServerTransport } from "@modelcontextprotocol/server/stdio";
import { PluginSocket } from "./plugin-socket.js";
import { Dispatcher } from "./dispatcher.js";
import { readToken, tokenFilePath } from "./token.js";
import { requestPort, responsePort } from "./ports.js";
import { parseToolsets, type Toolset } from "./toolsets.js";
import { TIMEOUT_MS_BY_DURATION } from "./tool-durations.js";
import { parseReadOnly } from "./read-only.js";
import { createMcpServer } from "./create-server.js";
import { createToolAccess } from "./tool-access.js";
import { createCallToolHandler, NOT_CONNECTED_DETAILS, NOT_CONNECTED_MESSAGE } from "./tool-handler.js";
import { Bridge, type Leader } from "./bridge.js";
import { brokerPath } from "./broker.js";
import { parseCli, helpText } from "./cli.js";
import { VERSION } from "./version.js";
import { ConnectionLossDeadline } from "./connection-loss.js";
import { HEARTBEAT_INTERVAL_SECONDS, PluginLiveness } from "./plugin-liveness.js";
import { confirmPairing, pairingOf, type Paired, type Pairing } from "./plugin-pairing.js";
import { serverIdentity } from "./server-identity.js";
import { refusedResponse } from "./tool-result.js";
import { waitUntil } from "./wait-until.js";
import { diagnoseUnresponsive, UnresponsiveReporter } from "./port-owner.js";
import { acquireInstanceLock, LockHeldError, lockHolder, lockHolderUnresponsive, type InstanceLock } from "./instance-lock.js";
import { admitLeader, describeInstall, installPlugin } from "./install-plugin.js";

const PING_TIMEOUT_MS = 10_000;
const RESPONSE_CONNECT_SETTLE_MS = 200;
// Short enough that a tool call waiting on the verdict is not left hanging,
// generous enough for a busy-but-healthy plugin: a ping is a no-op dispatch
// that answered in single-digit milliseconds even mid-export.
const PROBE_TIMEOUT_MS = 5_000;
const PROBE_RECOVERY_INTERVAL_MS = 5_000;
// A client that calls a tool immediately after initialize would otherwise be
// told "plugin not connected" while the sockets are still coming up, which is
// a lie about a perfectly healthy Lightroom. Wait out the connect instead.
const STARTUP_GRACE_MS = 3_000;
const CONNECT_POLL_MS = 50;
const PENDING_AFTER_DISCONNECT_MS = 30_000;
const PLUGIN_RESTARTED_MESSAGE =
  "The Lightroom plug-in restarted during this call, so its result is unknown. Check the catalog before retrying.";
const PLUGIN_CONNECTION_LOST_MESSAGE =
  "The connection to the Lightroom plug-in was lost during this call, so its result is unknown. Check the catalog before retrying.";
const SHUTDOWN_GRACE_MS = Math.max(...Object.values(TIMEOUT_MS_BY_DURATION)) + 5_000;
const SHUTDOWN_EXIT_MARGIN_MS = 1_000;

const here = path.dirname(fileURLToPath(import.meta.url));

type Backend = Pick<Bridge, "callTool" | "start" | "shutdown">;

function refusing(reason: string): Backend {
  return {
    callTool: async () => refusedResponse(reason),
    start: async () => {},
    shutdown: async () => {},
  };
}

async function main() {
  let cli;
  try {
    cli = parseCli(process.argv);
  } catch (err) {
    console.error((err as Error).message);
    process.exit(2);
  }

  if (cli.command === "help") {
    process.stdout.write(helpText());
    return;
  }
  if (cli.command === "version") {
    process.stdout.write(VERSION + "\n");
    return;
  }
  if (cli.command === "install-plugin") {
    runInstallPlugin(pairingOf(here));
    return;
  }

  let toolsets: readonly Toolset[];
  let readOnly: boolean;
  let REQUEST_PORT: number;
  let RESPONSE_PORT: number;
  try {
    toolsets = parseToolsets(process.env.LIGHTROOM_AGENT_TOOLSETS);
    readOnly = parseReadOnly(process.env.LIGHTROOM_AGENT_READ_ONLY);
  } catch (err) {
    console.error((err as Error).message);
    process.exit(1);
  }

  const access = createToolAccess({ toolsets, readOnly });
  if (cli.command === "tools") {
    const { tools } = access;
    if (cli.name === undefined) {
      process.stdout.write(JSON.stringify(tools) + "\n");
      return;
    }
    const tool = tools.tools.find((tool) => tool.name === cli.name);
    if (!tool) {
      console.error(`Tool "${cli.name}" is not available in the selected toolsets and read-only mode.`);
      process.exitCode = 1;
      return;
    }
    process.stdout.write(JSON.stringify(tool) + "\n");
    return;
  }

  try {
    REQUEST_PORT = requestPort();
    RESPONSE_PORT = responsePort();
  } catch (err) {
    console.error((err as Error).message);
    process.exitCode = 1;
    return;
  }

  const pairing = pairingOf(here);
  if (pairing.kind === "unpaired") console.error(pairing.reason);

  const bridge: Backend = pairing.kind === "unpaired" ? refusing(pairing.reason) : new Bridge({
    ipcPath: brokerPath(REQUEST_PORT, RESPONSE_PORT),
    server: serverIdentity(here, pairing.plugin.build),
    acquireLock: () => acquireInstanceLock(REQUEST_PORT, RESPONSE_PORT),
    startLeader: () => startLeader(pairing, REQUEST_PORT, RESPONSE_PORT, cli.command === "stdio"),
    readToken: tryReadToken,
    holderUnresponsive: () => lockHolderUnresponsive(REQUEST_PORT, RESPONSE_PORT),
    lockHolder: () => lockHolder(REQUEST_PORT, RESPONSE_PORT),
  });

  if (cli.command === "call") {
    const callTool = access.restrict(
      (name, args, options) => bridge.callTool(name, args, options),
    );
    try {
      const result = await callTool(cli.name, cli.args);
      process.stdout.write(JSON.stringify(result) + "\n");
      process.exitCode = result.isError ? 1 : 0;
    } finally {
      await bridge.shutdown(SHUTDOWN_GRACE_MS);
    }
    return;
  }

  const server = createMcpServer((name, args, options) => bridge.callTool(name, args, options), access);
  server.oninitialized = () => void bridge.start();

  const transport = new StdioServerTransport();
  await server.connect(transport);

  // Exit when the MCP client goes away. Signal handlers never fire when the
  // parent dies without signaling (typical on Windows), and the live plugin
  // sockets plus the heartbeat interval keep the event loop alive — the
  // orphaned bridge then holds both the single-client plugin connection and
  // the instance lock, so every future bridge instance fails with "Another
  // Lightroom Agent bridge is already running". Stdin EOF is the one reliable
  // cross-platform signal that the client is gone.
  let shuttingDown = false;
  const exitOnClientGone = (reason: string) => () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.error(`Shutting down: ${reason}`);
    setTimeout(() => process.exit(0), SHUTDOWN_GRACE_MS + SHUTDOWN_EXIT_MARGIN_MS).unref();
    void bridge.shutdown(SHUTDOWN_GRACE_MS).finally(() => process.exit(0));
  };
  process.stdin.once("end", exitOnClientGone("stdin ended (client exited)"));
  process.stdin.once("close", exitOnClientGone("stdin closed (client exited)"));

  console.error(`Lightroom Agent server v${VERSION} running on stdio`);
  console.error(access.summary);
  console.error(`Connecting to plugin: request :${REQUEST_PORT}, response :${RESPONSE_PORT}`);
  console.error(`Token file: ${tokenFilePath()}`);
}

function tryReadToken(): string | null {
  try {
    return readToken();
  } catch {
    return null;
  }
}

function startLeader(pairing: Paired, REQUEST_PORT: number, RESPONSE_PORT: number, install: boolean): Leader {
  confirmPairing(pairing);
  admitLeader(pairing, install, (m) => console.error(m));
  let requestSocket: PluginSocket;
  let responseSocket: PluginSocket | null = null;
  let responseConnectTimer: NodeJS.Timeout | null = null;
  const connectionLoss = new ConnectionLossDeadline(PENDING_AFTER_DISCONNECT_MS, () =>
    dispatcher.rejectPending(PLUGIN_CONNECTION_LOST_MESSAGE),
  );
  let connectedToken: string | null = null;
  const dispatcher: Dispatcher = new Dispatcher({
    send: (line) => requestSocket.send(line),
    getToken: () => readToken(),
    connectionGeneration: () => liveness.connectionGeneration(),
  });
  const unresponsive = new UnresponsiveReporter({
    diagnose: () => diagnoseUnresponsive([REQUEST_PORT, RESPONSE_PORT]),
    log: (message) => console.error(`[plugin] ${message}`),
  });
  const liveness: PluginLiveness = new PluginLiveness({
    dispatcher,
    connected: () => socketsConnected(),
    reporter: unresponsive,
    heartbeatIntervalMs: HEARTBEAT_INTERVAL_SECONDS * 1000,
    heartbeatTimeoutMs: PING_TIMEOUT_MS,
    probeTimeoutMs: PROBE_TIMEOUT_MS,
    recoveryIntervalMs: PROBE_RECOVERY_INTERVAL_MS,
    plugin: pairing.plugin,
  });
  const startResponseSocket = () => {
    if (responseSocket || !requestSocket.isConnected()) return;
    responseSocket = new PluginSocket({
      port: RESPONSE_PORT,
      label: "response",
      onLine: (line) => dispatcher.handleResponseLine(line),
      onConnect: () => {
        connectionLoss.clear();
        liveness.check();
      },
      onDisconnect: () => {
        liveness.reset();
        connectionLoss.start();
      },
    });
    responseSocket.connect();
  };
  const stopResponseSocket = () => {
    liveness.reset();
    if (responseConnectTimer) {
      clearTimeout(responseConnectTimer);
      responseConnectTimer = null;
    }
    responseSocket?.stop();
    responseSocket = null;
  };
  requestSocket = new PluginSocket({
    port: REQUEST_PORT,
    label: "request",
    onConnect: () => {
      const token = tryReadToken();
      if (connectedToken !== null && token !== connectedToken) {
        dispatcher.rejectPending(PLUGIN_RESTARTED_MESSAGE);
      }
      connectedToken = token;
      if (responseConnectTimer) clearTimeout(responseConnectTimer);
      responseConnectTimer = setTimeout(() => {
        responseConnectTimer = null;
        startResponseSocket();
      }, RESPONSE_CONNECT_SETTLE_MS);
    },
    onDisconnect: () => {
      stopResponseSocket();
      connectionLoss.start();
    },
  });
  requestSocket.connect();

  const socketsConnected = () =>
    requestSocket.isConnected() && (responseSocket?.isConnected() ?? false);

  liveness.start();
  let loggedIncompatibility: string | null = null;

  const callTool = createCallToolHandler({
    dispatcher,
    admitted: () => (socketsConnected() ? liveness.admitted() : null),
    notReadyMessage: () => {
      const incompatibility = liveness.incompatibility();
      if (incompatibility !== null) {
        if (incompatibility !== loggedIncompatibility) console.error(`[plugin] ${incompatibility}`);
        loggedIncompatibility = incompatibility;
        return incompatibility;
      }
      if (socketsConnected()) return unresponsive.current();
      console.error(`[plugin] ${NOT_CONNECTED_DETAILS}`);
      return NOT_CONNECTED_MESSAGE;
    },
    settleReadiness: async () => {
      await waitUntil(socketsConnected, STARTUP_GRACE_MS, CONNECT_POLL_MS);
      await liveness.settled();
      await unresponsive.settled();
    },
  });

  return {
    callTool,
    stop: () => {
      liveness.stop();
      connectionLoss.clear();
      stopResponseSocket();
      requestSocket.stop();
    },
  };
}

function runInstallPlugin(pairing: Pairing): void {
  if (pairing.kind === "unpaired") {
    console.error(pairing.reason);
    process.exitCode = 1;
    return;
  }
  let lock: InstanceLock;
  try {
    lock = acquireInstanceLock(requestPort(), responsePort());
  } catch (err) {
    console.error(err instanceof LockHeldError
      ? `A running lightroom-agent server owns the plug-in (pid ${err.pid}); quit its clients, then install again`
      : `Install failed: ${(err as Error).message}`);
    process.exitCode = 1;
    return;
  }
  try {
    const result = installPlugin(pairing);
    console.error(describeInstall(result));
    if (result.status === "conflict" || result.status === "foreign" || result.status === "invalid") process.exitCode = 1;
  } catch (err) {
    console.error(`Install failed: ${(err as Error).message}`);
    process.exitCode = 1;
  } finally {
    lock.release();
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
