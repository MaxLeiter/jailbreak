// Daemon assembly — the one place the agent is wired together, shared by the CLI
// (main.ts) and the web console (server.ts). Everything that differs between
// them (how permissions are asked, where events go) is injected.

import Anthropic from "@anthropic-ai/sdk";
import {
  PolicyBroker,
  Session,
  TieredRouter,
  makeSpawner,
  type AuditEntry,
  type Mode,
  type PermissionRequest,
  type SessionEvent,
  type TieredModelConfig,
} from "./harness";
import { SqliteAudit, SqliteStore } from "./store";
import { loadMemoryContext } from "./memory";
import { applyIosPolicyOverrides, loadSettings, saveSettings } from "./settings";
import { deviceTools, sessionScrollbackTool, sessionStatusTool, subagentTool, switchModelTool } from "./tools";

export const SYSTEM = [
  "You are Jarvis, an on-device assistant running on the user's own hardware.",
  "You are a practical personal assistant: check device state, answer directly, and take small useful actions when asked.",
  "You have tools to read the filesystem, sense the device, capture the screen, speak aloud, change your speaking voice, remember durable facts, and listen for short replies.",
  "Durable markdown memory is loaded into your prompt. The root memory topic index is always injected first; use it only for the most important standing instructions.",
  "Prefer reading, sensing, or recalling memory over guessing, but never read secrets such as Jarvis' .env.",
  "For ordinary assistant replies, call speak with the reply text before sending the final text whenever act.speech is available; if speech is denied or fails, continue in text. Use listen only when the user explicitly asks you to hear or wait for a spoken reply.",
  "Messages beginning with [voice command] came from the on-device wake loop; answer them briefly and use speak when a spoken reply is appropriate.",
  "When the user asks you to remember something, call remember with their intended memory instead of replying with a canned acknowledgement.",
  "Only switch models when the user explicitly asks you to switch models.",
  "Be concise. When a task has independent parts, spawn subagents to do them in parallel.",
].join(" ");

// The trust boundary in one object: what runs freely, asks, or never runs.
export const DEFAULT_POLICY: Record<string, Mode> = {
  "fs.read": "allow",
  "fs.edit": "ask",
  "sense.power": "allow",
  "sense.screen": "allow",
  "sense.microphone": "ask",
  "memory.read": "allow",
  "memory.write": "ask",
  "session.read": "allow",
  "model.switch": "ask",
  "mcp.configure": "ask",
  "mcp.google_calendar": "ask",
  "mcp.gmail": "ask",
  "mcp.github": "ask",
  "agent.spawn": "allow",
  "act.speech": "ask",
  exec: "ask",
};

// Through Vercel AI Gateway the endpoint is Anthropic-compatible but models are
// `provider/model` slugs; direct Anthropic uses bare ids. One switch, both paths.
export const VIA_GATEWAY =
  !!process.env.AI_GATEWAY_API_KEY ||
  (process.env.ANTHROPIC_BASE_URL ?? "").includes("ai-gateway.vercel.sh");

export const MODELS = VIA_GATEWAY
  ? { base: "anthropic/claude-sonnet-5", heavy: "anthropic/claude-opus-4.8", cheap: "anthropic/claude-haiku-4.5" }
  : { base: "claude-sonnet-5", heavy: "claude-opus-4-8", cheap: "claude-haiku-4-5-20251001" };

export async function gatewayLanguageModels(): Promise<Array<{ id: string; name?: string; type?: string; creator?: string }>> {
  const defaults = [MODELS.base, MODELS.heavy, MODELS.cheap].map((id) => ({
    id,
    name: id.split("/").pop() ?? id,
    type: "language",
  }));
  if (!VIA_GATEWAY) return defaults;

  try {
    const response = await fetch("https://ai-gateway.vercel.sh/v1/models");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const body = (await response.json()) as { data?: Array<Record<string, unknown>> };
    const models = (body.data ?? [])
      .filter((m) => m.type === "language" || m.modelType === "language")
      .map((m) => {
        const id = String(m.id ?? "");
        return {
          id,
          name: String(m.name ?? id.split("/").pop() ?? id),
          type: "language",
          creator: typeof m.creator === "string" ? m.creator : undefined,
        };
      })
      .filter((m) => m.id);
    return models.length ? models : defaults;
  } catch {
    return defaults;
  }
}

export function makeClient(): Anthropic {
  const token = process.env.ANTHROPIC_AUTH_TOKEN || process.env.AI_GATEWAY_API_KEY;
  if (VIA_GATEWAY && token) {
    if (!process.env.ANTHROPIC_API_KEY) delete process.env.ANTHROPIC_API_KEY;
    return new Anthropic({
      baseURL: process.env.ANTHROPIC_BASE_URL || "https://ai-gateway.vercel.sh",
      authToken: token,
    });
  }
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) {
    console.error("set AI_GATEWAY_API_KEY (gateway) or ANTHROPIC_API_KEY (direct)");
    process.exit(1);
  }
  return new Anthropic({ apiKey });
}

export interface Jarvis {
  session: Session;
  broker: PolicyBroker;
  store: SqliteStore;
  audit: SqliteAudit;
  models: () => TieredModelConfig & { cheap: string };
  setBaseModel: (model: string) => void;
}

export function buildJarvis(opts: {
  // How to ask the human for a gated call. CLI auto-denies; the console prompts.
  ask: (req: PermissionRequest) => Promise<boolean>;
  // Structured event stream (turns, tool calls, results) for a UI.
  onEvent?: (e: SessionEvent) => void;
  // Extra audit sink beyond the sqlite log (e.g. mirror to the console UI).
  onAudit?: (e: AuditEntry) => void;
  sessionId?: string;
}): Jarvis {
  const client = makeClient();
  const store = new SqliteStore();
  const audit = new SqliteAudit();
  const settings = loadSettings();

  const broker = new PolicyBroker({
    policy: applyIosPolicyOverrides({ ...DEFAULT_POLICY, ...(settings.policy ?? {}) }),
    defaultMode: "ask",
    audit: (e) => {
      audit.write(e);
      opts.onAudit?.(e);
    },
    ask: opts.ask,
  });

  const router = new TieredRouter({ base: settings.model ?? MODELS.base, heavy: MODELS.heavy, escalateAfterTurns: 3 });

  let session: Session;
  const getSession = () => session;
  const sessionTools = [sessionStatusTool(getSession), sessionScrollbackTool(getSession)];
  const modelTool = switchModelTool({
    getModel: () => router.config().base,
    setModel: (model) => {
      router.setBase(model);
      saveSettings({ ...loadSettings(), model });
    },
    listModels: gatewayLanguageModels,
  });
  const baseTools = [...deviceTools, modelTool, ...sessionTools];
  const spawn = makeSpawner({ client, tools: baseTools, broker, router, systemPrompt: SYSTEM });
  const tools = [...baseTools, subagentTool(spawn)];

  session = new Session(opts.sessionId ?? "main", {
    client,
    tools,
    broker,
    router,
    systemPrompt: SYSTEM,
    systemContext: async () => {
      const memory = await loadMemoryContext();
      return memory ? `Jarvis markdown memory:\n${memory}` : "";
    },
    store,
    spawn,
    onEvent: opts.onEvent,
    compactAt: 120_000,
    compactionModel: MODELS.cheap,
    keepRecent: 8,
    scrollbackLimit: 200,
    log: (m) => console.error(`  · ${m}`),
  });

  return {
    session,
    broker,
    store,
    audit,
    models: () => ({ ...router.config(), cheap: MODELS.cheap }),
    setBaseModel: (model: string) => {
      router.setBase(model);
      saveSettings({ ...loadSettings(), model });
    },
  };
}

export const toolCatalog = [
  ...deviceTools,
  switchModelTool({
    getModel: () => MODELS.base,
    setModel: () => undefined,
    listModels: async () => [],
  }),
  sessionStatusTool(() => {
    throw new Error("tool catalog placeholder");
  }),
  sessionScrollbackTool(() => {
    throw new Error("tool catalog placeholder");
  }),
].map((t) => ({
  name: t.name,
  description: t.description,
  capabilities: t.capabilities,
}));
