// Jarvis web console — a single Bun.serve process, no framework, no build step.
// It holds one long-lived Session and exposes it as: a live event stream (SSE),
// a chat endpoint, the audit log, the editable policy, and — the point — the
// permission-approval surface, where the agent's "ask" turns into approve/deny
// buttons in your browser. Reachable from any device on the network.
//
//   bun run src/server.ts            # then open http://<device>:8787
//
// Footprint is one bun process + one sqlite file. Fits an on-device budget.

import { file } from "bun";
import { extname } from "node:path";
import { buildJarvis, gatewayLanguageModels, VIA_GATEWAY, toolCatalog } from "./daemon";
import type { PermissionRequest, SessionEvent } from "./harness";
import { speak } from "./ios/speech";
import { ROOT_MEMORY_TOPIC, listMemoryTopics, readMemoryTopic } from "./memory";
import {
  MCP_PRESETS,
  defaultMcpConnection,
  mcpClientConfig,
  mcpPreset,
  normalizeMcpConfig,
  removeMcpConnection,
  setMcpConnectionEnabled,
  upsertMcpConnection,
  type McpConfig,
} from "./mcp";
import { loadIosPreferences, loadSettings, saveSettings } from "./settings";
import { WakeController } from "./wake";

const PORT = Number(process.env.JARVIS_PORT ?? 8787);
// Console path: env override for deployment (bundled builds move the file tree),
// else resolve relative to this module in the source tree.
const CONSOLE = process.env.JARVIS_CONSOLE || new URL("../public/console.html", import.meta.url).pathname;

// --- fan-out to connected browsers (SSE) -----------------------------------

const clients = new Set<ReadableStreamDefaultController>();
const enc = new TextEncoder();

function broadcast(event: string, data: unknown) {
  const chunk = enc.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  for (const c of clients) {
    try {
      c.enqueue(chunk);
    } catch {
      clients.delete(c);
    }
  }
}

// --- pending permission approvals ------------------------------------------

interface Pending {
  id: string;
  tool: string;
  scope: string;
  resolve: (allow: boolean) => void;
}
const pending = new Map<string, Pending>();
let approvalSeq = 0;

// The broker's `ask` hook: register a pending approval, push it to the browser,
// and wait for a click. Auto-deny after 2 minutes so a call can't hang forever.
function askViaWeb(req: PermissionRequest): Promise<boolean> {
  const id = `ap-${++approvalSeq}`;
  return new Promise<boolean>((resolve) => {
    let done = false;
    const settle = (allow: boolean) => {
      if (done) return;
      done = true;
      pending.delete(id);
      broadcast("approval_resolved", { id, allow });
      resolve(allow);
    };
    pending.set(id, { id, tool: req.tool.name, scope: req.scope, resolve: settle });
    broadcast("approval_request", { id, tool: req.tool.name, scope: req.scope });
    setTimeout(() => settle(false), 120_000);
  });
}

// --- the agent -------------------------------------------------------------

let turnHadSpeech = false;

function handleSessionEvent(e: SessionEvent) {
  broadcast("agent", e);
  if (e.type === "turn" && e.turn === 0) turnHadSpeech = false;
  if (e.type === "tool_use" && e.tool === "speak") turnHadSpeech = true;
  if (e.type === "text" && e.text && !turnHadSpeech) void speakFinalText(e.text);
}

const jarvis = buildJarvis({
  ask: askViaWeb,
  onEvent: handleSessionEvent,
  onAudit: (e) => broadcast("audit", e),
});

// Resume prior state if present.
const prior = await jarvis.store.load("main");
if (prior) jarvis.session.restore(prior);

let busy = false;

async function sendVoiceCommand(command: string): Promise<boolean> {
  if (busy) {
    broadcast("wake", { ...wake.state(), lastError: "Jarvis is busy; voice command skipped." });
    return false;
  }
  const message = `[voice command] ${command}`;
  busy = true;
  broadcast("user", { text: message });
  jarvis.session
    .send(message)
    .catch((e) => broadcast("agent", { type: "text", text: `error: ${e.message}` }))
    .finally(() => {
      busy = false;
    });
  return true;
}

const wake = new WakeController({
  onState: (state) => broadcast("wake", state),
  onTranscript: (transcript) => broadcast("wake_transcript", { transcript }),
  onCommand: sendVoiceCommand,
  onAudit: (allowed, scope) => {
    const entry = {
      ts: Date.now(),
      sessionId: "main",
      tool: "wake_loop",
      scope,
      capabilities: ["sense.microphone"],
      mode: "ask",
      allowed,
    };
    jarvis.audit.write(entry);
    broadcast("audit", entry);
  },
});

async function speakFinalText(text: string) {
  const clean = text.trim();
  if (!clean || jarvis.broker.policyView()["act.speech"] !== "allow") return;
  const entry = {
    ts: Date.now(),
    sessionId: "main",
    tool: "speak",
    scope: clean.slice(0, 80),
    capabilities: ["act.speech"],
    mode: "allow" as const,
    allowed: true,
  };
  jarvis.audit.write(entry);
  broadcast("audit", entry);
  try {
    await speak({ text: clean });
  } catch (error) {
    broadcast("agent", {
      type: "tool_result",
      id: `auto-speak-${Date.now()}`,
      tool: "speak",
      isError: true,
      content: `auto speech failed: ${(error as Error).message}`,
    });
  }
}

// --- routes ----------------------------------------------------------------

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function attachmentResponse(path: string): Response {
  if (!path.startsWith("/var/jb/tmp/") && !path.startsWith("/tmp/")) {
    return json({ error: "attachment path denied" }, 403);
  }
  const type =
    extname(path).toLowerCase() === ".png"
      ? "image/png"
      : extname(path).toLowerCase() === ".m4a"
        ? "audio/mp4"
        : "application/octet-stream";
  return new Response(file(path), {
    headers: {
      "content-type": type,
      "cache-control": "no-store",
    },
  });
}

async function memoryState() {
  const topics = await listMemoryTopics().catch(() => []);
  const root = await readMemoryTopic(ROOT_MEMORY_TOPIC).catch(() => null);
  return { rootTopic: ROOT_MEMORY_TOPIC, root, topics };
}

function mcpState() {
  const mcp = normalizeMcpConfig(loadSettings().mcp);
  return { presets: MCP_PRESETS, ...mcp, clientConfig: mcpClientConfig(mcp) };
}

function saveMcpConfig(mcp: McpConfig) {
  const next = normalizeMcpConfig(mcp);
  saveSettings({ ...loadSettings(), mcp: next });
  return next;
}

function auditMcpConfig(scope: string) {
  const entry = {
    ts: Date.now(),
    sessionId: "main",
    tool: "mcp_config",
    scope,
    capabilities: ["mcp.configure"],
    mode: "allow" as const,
    allowed: true,
  };
  jarvis.audit.write(entry);
  broadcast("audit", entry);
}

async function updateMcp(req: Request) {
  const body = (await req.json().catch(() => ({}))) as {
    action?: "addPreset" | "enable" | "disable" | "remove";
    presetId?: string;
    connectionId?: string;
  };
  const action = body.action ?? "addPreset";
  const settings = loadSettings();
  let mcp = normalizeMcpConfig(settings.mcp);

  if (action === "addPreset") {
    const presetId = body.presetId?.trim();
    if (!presetId || !mcpPreset(presetId)) return json({ error: "unknown preset" }, 400);
    mcp = upsertMcpConnection(mcp, defaultMcpConnection(presetId, true));
    auditMcpConfig(`add ${presetId}`);
  } else if (action === "enable" || action === "disable") {
    const id = body.connectionId?.trim() || body.presetId?.trim();
    if (!id || !mcp.connections.some((connection) => connection.id === id)) return json({ error: "unknown connection" }, 404);
    mcp = setMcpConnectionEnabled(mcp, id, action === "enable");
    auditMcpConfig(`${action} ${id}`);
  } else if (action === "remove") {
    const id = body.connectionId?.trim() || body.presetId?.trim();
    if (!id || !mcp.connections.some((connection) => connection.id === id)) return json({ error: "unknown connection" }, 404);
    mcp = removeMcpConnection(mcp, id);
    auditMcpConfig(`remove ${id}`);
  }

  saveMcpConfig(mcp);
  const state = mcpState();
  broadcast("mcp", state);
  return json({ ok: true, ...state });
}

const server = Bun.serve({
  port: PORT,
  idleTimeout: 0, // keep SSE connections open
  async fetch(req) {
    const url = new URL(req.url);
    const { pathname } = url;

    if (pathname === "/" || pathname === "/index.html") {
      return new Response(file(CONSOLE), { headers: { "content-type": "text/html" } });
    }

    if (pathname === "/attachment") {
      return attachmentResponse(url.searchParams.get("path") ?? "");
    }

    // Live event stream.
    if (pathname === "/events") {
      const stream = new ReadableStream({
        start(controller) {
          clients.add(controller);
          controller.enqueue(enc.encode(`event: hello\ndata: {}\n\n`));
        },
        cancel() {
          /* controller removed lazily on next broadcast */
        },
      });
      return new Response(stream, {
        headers: {
          "content-type": "text/event-stream",
          "cache-control": "no-cache",
          connection: "keep-alive",
        },
      });
    }

    // Everything Jarvis currently knows + how it's configured.
    if (pathname === "/state") {
      return json({
        viaGateway: VIA_GATEWAY,
        models: jarvis.models(),
        tools: toolCatalog,
        policy: jarvis.broker.policyView(),
        knowledge: {
          pinned: jarvis.session.pinned,
          summary: jarvis.session.summary,
          messages: jarvis.session.messages.length,
        },
        memory: await memoryState(),
        mcp: mcpState(),
        iosPreferences: loadIosPreferences(),
        session: {
          status: jarvis.session.sessionStatus(),
          scrollback: jarvis.session.getScrollback(0, 200),
        },
        audit: jarvis.audit.recent(50),
        wake: wake.state(),
        busy,
      });
    }

    if (pathname === "/models") {
      return json({ data: await gatewayLanguageModels() });
    }

    if (pathname === "/mcp") {
      if (req.method === "GET") return json(mcpState());
      if (req.method === "POST") return updateMcp(req);
    }

    if (pathname === "/mcp/client-config") {
      return json(mcpState().clientConfig);
    }

    // Send a message; the answer streams back over /events.
    if (pathname === "/chat" && req.method === "POST") {
      if (busy) return json({ error: "busy" }, 409);
      const { message } = (await req.json()) as { message?: string };
      if (!message?.trim()) return json({ error: "empty" }, 400);
      busy = true;
      broadcast("user", { text: message });
      jarvis.session
        .send(message)
        .catch((e) => broadcast("agent", { type: "text", text: `error: ${e.message}` }))
        .finally(() => {
          busy = false;
        });
      return json({ ok: true });
    }

    // Resolve a pending approval.
    if (pathname === "/approve" && req.method === "POST") {
      const { id, allow } = (await req.json()) as { id: string; allow: boolean };
      const p = pending.get(id);
      if (!p) return json({ error: "unknown or expired" }, 404);
      p.resolve(!!allow);
      return json({ ok: true });
    }

    // Edit the trust boundary live.
    if (pathname === "/policy" && req.method === "POST") {
      const { capability, mode, updates } = (await req.json()) as {
        capability?: string;
        mode?: "allow" | "ask" | "deny";
        updates?: Array<{ capability: string; mode: "allow" | "ask" | "deny" }>;
      };
      for (const update of updates ?? []) jarvis.broker.setMode(update.capability, update.mode);
      if (capability && mode) jarvis.broker.setMode(capability, mode);
      if (jarvis.broker.policyView()["sense.microphone"] === "deny") wake.stop("policy blocked microphone");
      saveSettings({ ...loadSettings(), policy: jarvis.broker.policyView() });
      broadcast("policy", jarvis.broker.policyView());
      return json({ ok: true, policy: jarvis.broker.policyView() });
    }

    if (pathname === "/model" && req.method === "POST") {
      const { model } = (await req.json()) as { model?: string };
      if (!model?.trim()) return json({ error: "missing model" }, 400);
      jarvis.setBaseModel(model.trim());
      broadcast("model", jarvis.models());
      return json({ ok: true, models: jarvis.models() });
    }

    if (pathname === "/wake") {
      if (req.method === "GET") return json(wake.state());
      if (req.method === "POST") {
        const body = (await req.json().catch(() => ({}))) as {
          enabled?: boolean;
          phrase?: string;
          duration?: number;
          intervalMs?: number;
          cooldownMs?: number;
        };
        if (body.enabled) {
          if (jarvis.broker.policyView()["sense.microphone"] === "deny") {
            wake.stop("policy blocked microphone");
            return json({ error: "microphone capability is blocked by policy", wake: wake.state() }, 403);
          }
          wake.start(body);
        } else {
          wake.stop("stop");
        }
        return json({ ok: true, wake: wake.state() });
      }
    }

    return new Response("not found", { status: 404 });
  },
});

console.log(`Jarvis console → http://localhost:${server.port}  (${VIA_GATEWAY ? "gateway" : "direct"})`);
