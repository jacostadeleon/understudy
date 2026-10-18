#!/usr/bin/env node
import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// minimal .env loader: KEY=VALUE lines next to the config file
function loadDotEnv() {
  const envPath = path.join(__dirname, ".env");
  try {
    const raw = fs.readFileSync(envPath, "utf8");
    for (const line of raw.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq <= 0) continue;
      const key = trimmed.slice(0, eq).trim();
      let value = trimmed.slice(eq + 1).trim();
      if (
        (value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))
      )
        value = value.slice(1, -1);
      if (!(key in process.env)) process.env[key] = value;
    }
  } catch {}
}
loadDotEnv();

const CONFIG_PATH =
  process.env.UNDERSTUDY_CONFIG || path.join(__dirname, "config.json");

function expandEnv(value) {
  return String(value).replace(
    /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g,
    (match, name) => process.env[name] ?? "",
  );
}

function loadConfig() {
  const raw = fs.readFileSync(CONFIG_PATH, "utf8");
  const visited = new Set();

  function walk(node) {
    if (typeof node === "string") return expandEnv(node);
    if (Array.isArray(node)) return node.map(walk);
    if (node && typeof node === "object") {
      if (visited.has(node)) return node;
      visited.add(node);
      const out = {};
      for (const [key, value] of Object.entries(node)) out[key] = walk(value);
      return out;
    }
    return node;
  }

  return walk(JSON.parse(raw));
}

const cfg = loadConfig();
const PORT = Number(process.env.UNDERSTUDY_PORT) || cfg.port || 8793;
const HOST = process.env.UNDERSTUDY_HOST || "127.0.0.1";
const PASSTHROUGH_BASE = String(
  (cfg.passthrough && cfg.passthrough.base) || "https://api.anthropic.com",
).replace(/\/+$/, "");
const PROVIDERS = cfg.providers || {};
const ROUTE_MARKER = cfg.route_marker || "understudy-route:";
const ROUTE_RE = new RegExp(
  ROUTE_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") +
    "\\s*([A-Za-z0-9_.-]+)\\/([^\\s\"']+)",
);
const SELECTED_RE = new RegExp(
  ROUTE_MARKER.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*selected\\b",
);
const SELECTED_PATH =
  process.env.UNDERSTUDY_SELECTED ||
  path.join(path.dirname(CONFIG_PATH), "selected.json");
const MAX_BODY_BYTES = 256 * 1024 * 1024;

let selectedCache = { mtimeMs: -1, value: null };

function readSelected() {
  try {
    const stat = fs.statSync(SELECTED_PATH);
    if (stat.mtimeMs !== selectedCache.mtimeMs) {
      const raw = JSON.parse(fs.readFileSync(SELECTED_PATH, "utf8"));
      selectedCache = { mtimeMs: stat.mtimeMs, value: raw };
    }
  } catch {
    selectedCache = { mtimeMs: -1, value: null };
  }
  return selectedCache.value;
}

const httpAgent = new http.Agent({ keepAlive: true, maxSockets: 32 });
const httpsAgent = new https.Agent({ keepAlive: true, maxSockets: 32 });

// die with the tray/controller that spawned us (optional, set by tray.ps1)
if (process.env.UNDERSTUDY_PARENT_PID) {
  const parentPid = Number(process.env.UNDERSTUDY_PARENT_PID);
  if (parentPid > 0) {
    const parentWatch = setInterval(() => {
      try {
        process.kill(parentPid, 0);
      } catch (err) {
        // EPERM means the parent exists but is owned by someone else
        if (err && err.code === "EPERM") return;
        clearInterval(parentWatch);
        log(`parent pid ${parentPid} is gone; exiting`);
        serverGracefulShutdown(() => process.exit(0));
        setTimeout(() => process.exit(0), 1500).unref();
      }
    }, 3000);
    parentWatch.unref?.();
  }
}

function sysText(parsedBody) {
  const sys = parsedBody && parsedBody.system;
  if (typeof sys === "string") return sys;
  if (Array.isArray(sys))
    return sys
      .map((block) =>
        block && typeof block === "object" ? String(block.text || "") : "",
      )
      .join("\n");
  return "";
}

function detectRoute(text) {
  if (SELECTED_RE.test(text || "")) {
    const sel = readSelected();
    if (
      sel &&
      !sel.default &&
      sel.provider &&
      sel.model &&
      PROVIDERS[sel.provider]
    ) {
      return {
        name: sel.provider,
        provider: PROVIDERS[sel.provider],
        model: sel.model,
        via: "selected",
      };
    }
    return { via: "selected-default" };
  }
  const match = ROUTE_RE.exec(text || "");
  if (!match) return null;
  const providerName = match[1];
  const provider = PROVIDERS[providerName];
  if (!provider || !provider.base || !provider.key) return null;
  return {
    name: providerName,
    provider,
    model: match[2],
    via: "explicit",
  };
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("request body too large"));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

const HOP_HEADERS = new Set([
  "host",
  "connection",
  "keep-alive",
  "transfer-encoding",
  "upgrade",
  "expect",
  "proxy-authorization",
  "proxy-authenticate",
  "te",
  "trailers",
]);

function cleanHeaders(headers) {
  const out = {};
  for (const [key, value] of Object.entries(headers)) {
    const lower = key.toLowerCase();
    if (HOP_HEADERS.has(lower)) continue;
    if (lower === "content-length" || lower === "accept-encoding") continue;
    out[key] = Array.isArray(value) ? value.join(", ") : value;
  }
  return out;
}

function startUpstream(targetUrl, method, headers, bodyBuf) {
  const url = new URL(targetUrl);
  const isHttps = url.protocol === "https:";
  const transport = isHttps ? https : http;
  const outHeaders = { ...headers };
  if (!Object.keys(outHeaders).some((key) => key.toLowerCase() === "host"))
    outHeaders.host = url.host;
  const req = transport.request({
    hostname: url.hostname,
    port: url.port || (isHttps ? 443 : 80),
    path: url.pathname + url.search,
    method,
    headers: outHeaders,
    agent: isHttps ? httpsAgent : httpAgent,
    setHost: false,
  });
  req.setTimeout(0);
  if (bodyBuf && bodyBuf.length) req.write(bodyBuf);
  req.end();
  return req;
}

function sendUpstreamError(clientRes, err) {
  if (clientRes.headersSent) {
    clientRes.destroy();
    return;
  }
  const payload = Buffer.from(
    JSON.stringify({
      type: "error",
      error: {
        type: "api_error",
        message: `understudy: upstream request failed: ${err.message}`,
      },
    }),
  );
  clientRes.writeHead(502, {
    "content-type": "application/json",
    "content-length": payload.length,
  });
  clientRes.end(payload);
}

function pumpUpstream(clientRes, upstreamRes, upstreamReq) {
  const headers = cleanHeaders(upstreamRes.headers);
  clientRes.writeHead(upstreamRes.statusCode || 502, headers);
  clientRes.socket.setNoDelay(true);
  upstreamRes.pipe(clientRes);
  const close = () => {
    upstreamRes.destroy();
    upstreamReq.destroy();
  };
  clientRes.on("close", close);
  upstreamRes.on("error", () => clientRes.destroy());
}

async function handleRouted(clientReq, clientRes, bodyBuf, route, startedAt) {
  const parsed = JSON.parse(bodyBuf.toString("utf8"));
  parsed.model = route.model;
  const outBuf = Buffer.from(JSON.stringify(parsed));
  const headers = {
    "content-type": "application/json",
    "accept-encoding": "identity",
    "content-length": outBuf.length,
    "x-api-key": route.provider.key,
    authorization: `Bearer ${route.provider.key}`,
    "anthropic-version":
      clientReq.headers["anthropic-version"] || "2023-06-01",
  };
  if (clientReq.headers["anthropic-beta"])
    headers["anthropic-beta"] = clientReq.headers["anthropic-beta"];

  const upstreamReq = startUpstream(
    `${String(route.provider.base).replace(/\/+$/, "")}/v1/messages`,
    clientReq.method,
    headers,
    outBuf,
  );
  let settled = false;
  upstreamReq.on("response", (upstreamRes) => {
    settled = true;
    log(
      `${clientReq.method} ${clientReq.url} -> route=${route.name}/${route.model}(${route.via}) status=${upstreamRes.statusCode} (${Date.now() - startedAt}ms setup)`,
    );
    pumpUpstream(clientRes, upstreamRes, upstreamReq);
  });
  upstreamReq.on("error", (err) => {
    if (!settled) sendUpstreamError(clientRes, err);
  });
  clientRes.on("close", () => upstreamReq.destroy());
}

async function handlePassthrough(clientReq, clientRes, bodyBuf, startedAt) {
  const headers = cleanHeaders(clientReq.headers);
  headers["accept-encoding"] = "identity";
  if (bodyBuf && bodyBuf.length) headers["content-length"] = bodyBuf.length;

  const upstreamReq = startUpstream(
    PASSTHROUGH_BASE + clientReq.url,
    clientReq.method,
    headers,
    bodyBuf,
  );
  let settled = false;
  upstreamReq.on("response", (upstreamRes) => {
    settled = true;
    log(
      `${clientReq.method} ${clientReq.url} -> passthrough=${PASSTHROUGH_BASE} status=${upstreamRes.statusCode} (${Date.now() - startedAt}ms setup)`,
    );
    pumpUpstream(clientRes, upstreamRes, upstreamReq);
  });
  upstreamReq.on("error", (err) => {
    if (!settled) {
      log(`passthrough error: ${err.message}`);
      sendUpstreamError(clientRes, err);
    }
  });
  clientRes.on("close", () => upstreamReq.destroy());
}

function estimateTokens(bodyBuf) {
  const bytes = bodyBuf ? bodyBuf.length : 0;
  return Math.max(1, Math.ceil(bytes / 4));
}

function handleCountTokens(clientRes, bodyBuf) {
  const payload = Buffer.from(
    JSON.stringify({ input_tokens: estimateTokens(bodyBuf) }),
  );
  clientRes.writeHead(200, {
    "content-type": "application/json",
    "content-length": payload.length,
  });
  clientRes.end(payload);
}

function log(line) {
  const now = new Date().toISOString().slice(11, 19);
  console.log(`[${now}] ${line}`);
}

function serverGracefulShutdown(done) {
  log("shutting down");
  server.close(() => done());
}

const server = http.createServer(async (clientReq, clientRes) => {
  const startedAt = Date.now();
  try {
    clientReq.socket.setNoDelay(true);
    const url = new URL(clientReq.url, `http://${HOST}:${PORT}`);

    if (url.pathname === "/healthz") {
      const sel = readSelected();
      const payload = Buffer.from(
        JSON.stringify({
          ok: true,
          version: 2,
          passthrough: PASSTHROUGH_BASE,
          providers: Object.keys(PROVIDERS),
          selected: sel || { default: true },
          routeMarker: ROUTE_MARKER,
          uptimeSec: Math.round(process.uptime()),
        }),
      );
      clientRes.writeHead(200, {
        "content-type": "application/json",
        "content-length": payload.length,
      });
      clientRes.end(payload);
      return;
    }

    if (url.pathname === "/shutdown" && clientReq.method === "POST") {
      const payload = Buffer.from(JSON.stringify({ ok: true }));
      clientRes.writeHead(200, {
        "content-type": "application/json",
        "content-length": payload.length,
      });
      clientRes.end(payload, () => {
        log("shutdown requested via /shutdown");
        serverGracefulShutdown(() => process.exit(0));
        setTimeout(() => process.exit(0), 1500).unref();
      });
      return;
    }

    const hasBody = !["GET", "HEAD", "OPTIONS"].includes(clientReq.method);
    const bodyBuf = hasBody
      ? await readRequestBody(clientReq)
      : Buffer.alloc(0);

    const isMessages =
      clientReq.method === "POST" && /^\/v1\/messages\/?$/.test(url.pathname);
    const isCountTokens =
      clientReq.method === "POST" &&
      /^\/v1\/messages\/count_tokens\/?$/.test(url.pathname);

    let route = null;
    let wantedRoute = false;
    if ((isMessages || isCountTokens) && bodyBuf.length) {
      try {
        route = detectRoute(sysText(JSON.parse(bodyBuf.toString("utf8"))));
        if (route) wantedRoute = route.via !== "selected-default";
        if (route && route.via === "selected-default") route = null;
      } catch {
        route = null;
      }
    }

    if (isCountTokens) {
      if (wantedRoute && route) {
        log(
          `${clientReq.method} ${clientReq.url} -> estimate for ${route.name}(${route.via})`,
        );
        handleCountTokens(clientRes, bodyBuf);
      } else if (wantedRoute) {
        log(
          `${clientReq.method} ${clientReq.url} -> estimate passthrough (route=default)`,
        );
        handleCountTokens(clientRes, bodyBuf);
      } else {
        await handlePassthrough(clientReq, clientRes, bodyBuf, startedAt);
      }
      return;
    }

    if (isMessages && wantedRoute && route) {
      await handleRouted(clientReq, clientRes, bodyBuf, route, startedAt);
      return;
    }

    if (isMessages && wantedRoute) {
      log(`${clientReq.method} ${clientReq.url} -> passthrough (route=default)`);
    }

    await handlePassthrough(clientReq, clientRes, bodyBuf, startedAt);
  } catch (err) {
    sendUpstreamError(clientRes, err);
  }
});

server.requestTimeout = 0;
server.headersTimeout = 65000;
server.keepAliveTimeout = 72000;

server.listen(PORT, HOST, () => {
  log(`understudy listening on http://${HOST}:${PORT}`);
  log(`passthrough -> ${PASSTHROUGH_BASE}`);
  for (const [name, provider] of Object.entries(PROVIDERS))
    log(`provider ${name} -> ${provider.base}`);
});
