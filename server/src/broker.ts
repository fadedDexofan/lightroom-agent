/**
 * Local IPC between bridge processes. The plugin serves one client per port,
 * but MCP hosts spawn several bridges at once (Claude Desktop's chat plus its
 * Cowork/Code shared pool, issue 238). One bridge owns the plugin connection
 * and serves tool calls to the others over this channel.
 *
 * Both ends prove they can read the plugin token without sending it: the
 * follower opens with a challenge the owner must sign, and signs each call
 * over the owner's nonce. Whoever squats the socket or pipe name can neither
 * pose as the owner nor learn anything that unlocks the plugin.
 */
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { configDir } from "./config-dir.js";
import { sameIdentity } from "./build-identity.js";
import { serverIdentityIn, type ServerIdentity } from "./server-identity.js";
import { LineBuffer } from "./line-buffer.js";
import type { CallOptions, ToolProgress } from "./dispatcher.js";
import { isReadOnlyTool } from "./tool-contracts.js";
import { finishLost, refusedResponse, toolResponse, type ToolResponse } from "./tool-result.js";

export type ToolCaller = (name: string, args: unknown, options?: CallOptions) => Promise<ToolResponse>;

interface BrokerRequest {
  id: number;
  auth: string | null;
  name: string;
  args: unknown;
  reportProgress?: boolean;
}

interface BrokerReply {
  id: number;
  result: ToolResponse;
}

/** macOS caps sun_path at 104 bytes, Linux at 108. */
const MAX_UNIX_SOCKET_PATH = 100;

/** Unterminated input past these sizes is a hostile or broken peer. */
const MAX_HANDSHAKE_BYTES = 1024;
export const MAX_FRAME_BYTES = 16 * 1024 * 1024;

export function brokerPath(
  requestPort: number,
  responsePort: number,
  baseDir = configDir(),
  platform: NodeJS.Platform = process.platform,
): string {
  const name = `bridge-${requestPort}-${responsePort}`;
  if (platform === "win32") {
    return `\\\\.\\pipe\\lightroom-agent-${os.userInfo().username}-${name}`;
  }
  const preferred = path.join(baseDir, `${name}.sock`);
  if (Buffer.byteLength(preferred) <= MAX_UNIX_SOCKET_PATH) return preferred;
  return path.join(os.tmpdir(), `lightroom-agent-${os.userInfo().uid}-${name}.sock`);
}

export function signNonce(token: string | null, nonce: string): string | null {
  if (token === null) return null;
  return crypto.createHmac("sha256", token).update(nonce).digest("hex");
}

function newNonce(): string {
  return crypto.randomBytes(32).toString("hex");
}

function parseObject(line: string): Record<string, unknown> | null {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return null;
  }
  return typeof raw === "object" && raw !== null && !Array.isArray(raw)
    ? (raw as Record<string, unknown>)
    : null;
}

function authMatches(expected: string | null, actual: string | null): boolean {
  if (expected === null || actual === null) return false;
  const a = Buffer.from(expected);
  const b = Buffer.from(actual);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function parseRequest(line: string): BrokerRequest | null {
  const req = parseObject(line);
  if (!req) return null;
  if (typeof req.id !== "number" || typeof req.name !== "string") return null;
  if (req.auth !== null && typeof req.auth !== "string") return null;
  return { id: req.id, auth: req.auth, name: req.name, args: req.args, reportProgress: req.reportProgress === true };
}

function lostResponse(name: string, text: string): ToolResponse {
  return toolResponse(finishLost(isReadOnlyTool(name), text, true));
}

function describeServer(identity: ServerIdentity): string {
  if (identity.version === null) return "an older server that reports no version";
  return `version ${identity.version} (build ${identity.build ?? "unknown"})`;
}

export function serverMismatch(follower: ServerIdentity, owner: ServerIdentity): string | null {
  if (sameIdentity(follower, owner)) return null;
  return `This server is ${describeServer(follower)}, but the server that owns the Lightroom connection is `
    + `${describeServer(owner)}, so nothing was sent. Use one lightroom-agent version in every client, then restart them.`;
}

function replyFrame(reply: BrokerReply, name: string): string {
  const frame = JSON.stringify(reply);
  if (Buffer.byteLength(frame) < MAX_FRAME_BYTES) return frame;
  return JSON.stringify({
    id: reply.id,
    result: lostResponse(name, "The result is too large to return; request fewer items with limit and offset."),
  } satisfies BrokerReply);
}

function onLines(sock: net.Socket, handle: (line: string) => void, maxBytes: () => number): void {
  const lines = new LineBuffer();
  sock.setEncoding("utf8");
  sock.on("data", (chunk: string) => {
    lines.push(chunk, handle);
    if (lines.pendingBytes() > maxBytes()) {
      lines.clear();
      sock.destroy();
    }
  });
}

export interface BrokerServerOptions {
  path: string;
  server: ServerIdentity;
  callTool: ToolCaller;
  readToken: () => string | null;
  log?: (msg: string) => void;
}

export class BrokerServer {
  private server: net.Server | null = null;
  private readonly clients = new Set<net.Socket>();
  private readonly log: (msg: string) => void;
  private inFlight = 0;
  private idleWaiters: Array<() => void> = [];

  constructor(private readonly opts: BrokerServerOptions) {
    this.log = opts.log ?? ((msg: string) => console.error(msg));
  }

  /**
   * Only the instance-lock holder listens, so a leftover Unix socket file
   * belongs to a dead owner and is safe to remove first.
   */
  async listen(): Promise<void> {
    if (!this.opts.path.startsWith("\\\\")) {
      fs.rmSync(this.opts.path, { force: true });
    }
    const server = net.createServer((sock) => this.accept(sock));
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(this.opts.path, () => {
        server.off("error", reject);
        resolve();
      });
    });
    server.on("error", (err) => this.log(`[broker] server error: ${err.message}`));
    this.server = server;
  }

  private accept(sock: net.Socket): void {
    this.clients.add(sock);
    sock.on("error", () => {});
    sock.on("close", () => this.clients.delete(sock));
    const calls = new Map<number, AbortController>();
    sock.on("close", () => { for (const controller of calls.values()) controller.abort(); });
    const nonce = newNonce();
    let greeted = false;
    let refusal: string | null = null;
    onLines(
      sock,
      (line) => {
        if (!greeted) {
          const follower = this.greet(sock, nonce, line);
          greeted = follower !== undefined;
          if (follower !== undefined) refusal = serverMismatch(follower, this.opts.server);
          return;
        }
        this.handle(sock, nonce, line, calls, refusal).catch((err: unknown) => {
          this.log(`[broker] failed to serve a follower call: ${String(err)}`);
        });
      },
      () => (greeted ? MAX_FRAME_BYTES : MAX_HANDSHAKE_BYTES),
    );
  }

  private greet(sock: net.Socket, nonce: string, line: string): ServerIdentity | undefined {
    const hello = parseObject(line);
    const challenge = hello?.challenge;
    if (typeof challenge !== "string") {
      this.log("[broker] follower opened without a challenge, dropping it");
      sock.destroy();
      return undefined;
    }
    const proof = signNonce(this.opts.readToken(), `owner:${challenge}`);
    sock.write(JSON.stringify({ nonce, proof, server: this.opts.server }) + "\n");
    return serverIdentityIn(hello?.server);
  }

  private async handle(
    sock: net.Socket, nonce: string, line: string, calls: Map<number, AbortController>, refusal: string | null,
  ): Promise<void> {
    const control = parseObject(line);
    if (typeof control?.cancelFor === "number") {
      const auth = typeof control.auth === "string" ? control.auth : null;
      if (authMatches(signNonce(this.opts.readToken(), `follower:${nonce}`), auth)) calls.get(control.cancelFor)?.abort();
      return;
    }
    const req = parseRequest(line);
    if (!req) {
      this.log(`[broker] malformed request from follower: ${line.slice(0, 200)}`);
      return;
    }
    if (!authMatches(signNonce(this.opts.readToken(), `follower:${nonce}`), req.auth)) {
      this.reply(sock, req.id, req.name, refusedResponse("Rejected by the Lightroom Agent bridge: token mismatch."));
      return;
    }
    if (refusal !== null) {
      this.reply(sock, req.id, req.name, refusedResponse(refusal));
      return;
    }
    if (calls.has(req.id)) return;
    const controller = new AbortController();
    calls.set(req.id, controller);
    this.inFlight++;
    let result: ToolResponse;
    try {
      result = await this.opts.callTool(req.name, req.args, {
        signal: controller.signal,
        onProgress: req.reportProgress ? (progress) => {
          if (!sock.destroyed) sock.write(JSON.stringify({ progressFor: req.id, progress }) + "\n");
        } : undefined,
      });
    } catch (err) {
      calls.delete(req.id);
      this.callDone();
      throw err;
    }
    calls.delete(req.id);
    this.reply(sock, req.id, req.name, result, () => this.callDone());
  }

  private reply(sock: net.Socket, id: number, name: string, result: ToolResponse, sent: () => void = () => {}): void {
    if (sock.destroyed) {
      sent();
      return;
    }
    const reply: BrokerReply = { id, result };
    sock.write(replyFrame(reply, name) + "\n", () => sent());
  }

  private callDone(): void {
    this.inFlight--;
    if (this.inFlight > 0) return;
    const waiters = this.idleWaiters;
    this.idleWaiters = [];
    for (const w of waiters) w();
  }

  /** Follower calls being served right now. */
  inFlightCalls(): number {
    return this.inFlight;
  }

  /**
   * Resolves true once no follower call is in flight, or false after
   * timeoutMs with calls still running.
   */
  whenIdle(timeoutMs: number): Promise<boolean> {
    if (this.inFlight === 0) return Promise.resolve(true);
    return new Promise((resolve) => {
      const waiter = () => {
        clearTimeout(timer);
        resolve(true);
      };
      const timer = setTimeout(() => {
        this.idleWaiters = this.idleWaiters.filter((w) => w !== waiter);
        resolve(false);
      }, timeoutMs);
      this.idleWaiters.push(waiter);
    });
  }

  close(): void {
    for (const sock of this.clients) sock.destroy();
    this.clients.clear();
    this.server?.close();
    this.server = null;
  }

  /**
   * Drops every follower but leaves the listener open: closing a Unix socket
   * server unlinks its path, which the bridge that took over has rebound. A
   * named pipe has no path, and holding it would block that bridge, so it is
   * closed.
   */
  abandon(): void {
    if (this.opts.path.startsWith("\\\\")) {
      this.close();
      return;
    }
    for (const sock of this.clients) sock.destroy();
    this.clients.clear();
    this.server?.removeAllListeners("connection");
    this.server?.on("connection", (sock: net.Socket) => sock.destroy());
    this.server?.unref();
    this.server = null;
  }
}

export const NOT_CONNECTED_TO_OWNER_MESSAGE =
  "This process is not connected to the Lightroom Agent process that owns the plugin connection, so nothing was sent. Retry in a few seconds.";

export const OWNER_LOST_MESSAGE =
  "The Lightroom Agent process that owned the plugin connection exited during this call, " +
  "so its result is unknown. Check Lightroom before retrying a call that changes photos.";

export interface BrokerClientOptions {
  path: string;
  server: ServerIdentity;
  readToken: () => string | null;
  onClose?: () => void;
  helloTimeoutMs?: number;
}

export class BrokerClient {
  private sock: net.Socket | null = null;
  private nonce = "";
  private refusal: string | null = null;
  private nextId = 0;
  private readonly pending = new Map<number, { name: string; resolve: (resp: ToolResponse) => void; options?: CallOptions; cleanup: () => void }>();

  constructor(private readonly opts: BrokerClientOptions) {}

  /**
   * Resolves once the owner has proven it can read the plugin token; rejects
   * on a bad proof, a hang-up, or no greeting in time.
   */
  async connect(): Promise<void> {
    const sock = net.createConnection(this.opts.path);
    const challenge = newNonce();
    let greeted: (hello: Record<string, unknown>) => void = () => {};
    const hello = new Promise<Record<string, unknown>>((resolve) => (greeted = resolve));
    onLines(sock, (line) => this.receive(line, greeted), () => MAX_FRAME_BYTES);
    try {
      const greeting = await new Promise<Record<string, unknown>>((resolve, reject) => {
        const timer = setTimeout(
          () => reject(new Error("owning bridge did not greet")),
          this.opts.helloTimeoutMs ?? 2_000,
        );
        sock.once("error", reject);
        sock.once("close", () => reject(new Error("owning bridge closed the connection")));
        sock.once("connect", () => sock.write(JSON.stringify({ challenge, server: this.opts.server }) + "\n"));
        void hello.then((msg) => {
          clearTimeout(timer);
          resolve(msg);
        });
      });
      const proof = typeof greeting.proof === "string" ? greeting.proof : null;
      if (!authMatches(signNonce(this.opts.readToken(), `owner:${challenge}`), proof)) {
        throw new Error("owning bridge could not prove it holds the plugin token");
      }
      this.nonce = greeting.nonce as string;
      this.refusal = serverMismatch(this.opts.server, serverIdentityIn(greeting.server));
    } catch (err) {
      sock.destroy();
      throw err;
    }
    sock.removeAllListeners("error");
    sock.removeAllListeners("close");
    sock.on("error", () => {});
    sock.on("close", () => {
      this.sock = null;
      for (const pending of this.pending.values()) { pending.cleanup(); pending.resolve(lostResponse(pending.name, OWNER_LOST_MESSAGE)); }
      this.pending.clear();
      this.opts.onClose?.();
    });
    this.sock = sock;
  }

  private receive(line: string, greeted: (hello: Record<string, unknown>) => void): void {
    const data = parseObject(line);
    if (!data) return;
    if (typeof data.nonce === "string") {
      greeted(data);
      return;
    }
    if (typeof data.progressFor === "number") {
      this.pending.get(data.progressFor)?.options?.onProgress?.(data.progress as ToolProgress);
      return;
    }
    if (typeof data.id !== "number") return;
    const pending = this.pending.get(data.id);
    this.pending.delete(data.id);
    pending?.cleanup();
    pending?.resolve((data as unknown as BrokerReply).result);
  }

  callTool(name: string, args: unknown, options?: CallOptions): Promise<ToolResponse> {
    if (options?.signal?.aborted) return Promise.resolve(refusedResponse("Request cancelled"));
    const sock = this.sock;
    if (!sock) return Promise.resolve(refusedResponse(NOT_CONNECTED_TO_OWNER_MESSAGE));
    if (this.refusal !== null) return Promise.resolve(refusedResponse(this.refusal));
    const id = this.nextId++;
    const req: BrokerRequest = {
      id,
      auth: signNonce(this.opts.readToken(), `follower:${this.nonce}`),
      name,
      args,
      reportProgress: Boolean(options?.onProgress),
    };
    return new Promise((resolve) => {
      const cancel = () => {
        if (this.pending.has(id)) sock.write(JSON.stringify({ cancelFor: id, auth: req.auth }) + "\n");
      };
      this.pending.set(id, { name, resolve, options, cleanup: () => options?.signal?.removeEventListener("abort", cancel) });
      options?.signal?.addEventListener("abort", cancel, { once: true });
      sock.write(JSON.stringify(req) + "\n");
    });
  }

  close(): void {
    this.sock?.destroy();
  }
}
