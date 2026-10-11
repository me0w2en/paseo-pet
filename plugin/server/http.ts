import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { homedir } from "node:os";
import { join } from "node:path";

const HOST = "127.0.0.1";
const FIRST_PORT = 6792;
const LAST_PORT = 6801;
const HEARTBEAT_MS = 15_000;
const MAX_BODY_BYTES = 16 * 1024;

export type PermissionBehavior = "allow" | "deny";

export interface BridgeHandlers {
  snapshot(): unknown;
  respond(agentId: string, requestId: string, behavior: PermissionBehavior): Promise<void>;
  test(): void;
}

export interface Bridge {
  readonly port: number;
  broadcast(event: string, data: unknown): void;
  close(): Promise<void>;
}

function paseoHome(): string {
  return process.env.PASEO_HOME ?? join(homedir(), ".paseo");
}

export function connectionFilePath(): string {
  return join(paseoHome(), "pet-bridge", "connection.json");
}

async function writeConnectionFile(port: number, token: string): Promise<void> {
  const file = connectionFilePath();
  // The pet builds paseo://h/<serverId>/agent/<agentId> links from this.
  const serverId = (await readFile(join(paseoHome(), "server-id"), "utf8").catch(() => "")).trim() || null;
  await mkdir(join(file, ".."), { recursive: true, mode: 0o700 });
  await writeFile(file, JSON.stringify({ url: `http://${HOST}:${port}`, token, serverId, pid: process.pid }), {
    mode: 0o600,
  });
  await chmod(file, 0o600);
}

function tokenMatches(header: string | undefined, token: string): boolean {
  const presented = Buffer.from(header?.replace(/^Bearer\s+/i, "") ?? "");
  const expected = Buffer.from(token);
  return presented.length === expected.length && timingSafeEqual(presented, expected);
}

function sendJson(res: ServerResponse, status: number, value: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(value));
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY_BYTES) {
      throw new Error("request body too large");
    }
    chunks.push(chunk as Buffer);
  }
  const text = Buffer.concat(chunks).toString("utf8");
  return text ? (JSON.parse(text) as Record<string, unknown>) : {};
}

function listen(server: Server, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const onError = () => resolve(false);
    server.once("error", onError);
    server.listen(port, HOST, () => {
      server.off("error", onError);
      resolve(true);
    });
  });
}

export async function startBridge(handlers: BridgeHandlers): Promise<Bridge> {
  const token = randomBytes(24).toString("base64url");
  const streams = new Set<ServerResponse>();

  const server = createServer((req, res) => {
    // Browsers attach Origin; the pet app does not. Refusing it keeps web pages from probing the bridge.
    if (req.headers.origin !== undefined) {
      sendJson(res, 403, { error: "browser requests are not allowed" });
      return;
    }
    if (!tokenMatches(req.headers.authorization, token)) {
      sendJson(res, 401, { error: "invalid token" });
      return;
    }
    const path = (req.url ?? "/").split("?")[0] ?? "/";

    if (req.method === "GET" && path === "/v1/state") {
      sendJson(res, 200, handlers.snapshot());
      return;
    }

    if (req.method === "GET" && path === "/v1/events") {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive",
      });
      res.write(`event: snapshot\ndata: ${JSON.stringify(handlers.snapshot())}\n\n`);
      streams.add(res);
      req.on("close", () => streams.delete(res));
      return;
    }

    if (req.method === "POST" && path === "/v1/test") {
      handlers.test();
      sendJson(res, 200, { ok: true });
      return;
    }

    const permission = /^\/v1\/agents\/([^/]+)\/permissions\/([^/]+)$/.exec(path);
    if (req.method === "POST" && permission) {
      const [, agentId = "", requestId = ""] = permission;
      readJson(req)
        .then(async (body) => {
          const behavior = body.behavior;
          if (behavior !== "allow" && behavior !== "deny") {
            sendJson(res, 400, { error: "behavior must be allow or deny" });
            return;
          }
          await handlers.respond(decodeURIComponent(agentId), decodeURIComponent(requestId), behavior);
          sendJson(res, 200, { ok: true });
        })
        .catch((error: unknown) => {
          sendJson(res, 409, { error: error instanceof Error ? error.message : String(error) });
        });
      return;
    }

    sendJson(res, 404, { error: `no route for ${req.method} ${path}` });
  });

  let port = 0;
  for (let candidate = FIRST_PORT; candidate <= LAST_PORT && port === 0; candidate += 1) {
    if (await listen(server, candidate)) {
      port = candidate;
    }
  }
  if (port === 0) {
    throw new Error(`no free port between ${FIRST_PORT} and ${LAST_PORT}`);
  }
  await writeConnectionFile(port, token);

  const heartbeat = setInterval(() => {
    for (const stream of streams) {
      stream.write(": ping\n\n");
    }
  }, HEARTBEAT_MS);

  return {
    port,
    broadcast(event, data) {
      const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
      for (const stream of streams) {
        stream.write(frame);
      }
    },
    close() {
      clearInterval(heartbeat);
      for (const stream of streams) {
        stream.end();
      }
      return new Promise<void>((done) => {
        server.close(() => done());
        server.closeAllConnections();
      });
    },
  };
}
