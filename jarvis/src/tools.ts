// Example tool surface. These are in-process — no MCP boundary — because Jarvis
// calls its own device code. Each tool declares capabilities so the broker can
// gate it, and a scope() so grants/audit can be about "this path", not just
// "fs.read in general". On-device, the sense/act tools become thin wrappers over
// FFI (IOKit, the input-injection wire); the shapes below are what the model sees.

import { readdir, stat } from "node:fs/promises";
import { basename, resolve } from "node:path";
import type { Session, SpawnFn, Tool } from "./harness";
import { listMemoryTopics, readMemoryTopic, remember, searchMemory } from "./memory";
import {
  MCP_PRESETS,
  defaultMcpConnection,
  mcpClientConfig,
  normalizeMcpConfig,
  removeMcpConnection,
  setMcpConnectionEnabled,
  upsertMcpConnection,
} from "./mcp";
import { loadSettings, saveSettings } from "./settings";
import { readPowerSource } from "./ios/power";
import { captureScreenshot } from "./ios/screenshot";
import { clearDefaultSpeechVoice, listSpeechVoices, setDefaultSpeechVoice, speak } from "./ios/speech";
import { recordAudio } from "./ios/audio";
import { transcribeAudio } from "./ios/transcription";

// --- sense: read the device ------------------------------------------------

export const readFileTool: Tool<{ path: string }> = {
  name: "read_file",
  description: "Read a UTF-8 text file from the device filesystem.",
  capabilities: ["fs.read"],
  inputSchema: {
    type: "object",
    properties: { path: { type: "string", description: "Absolute path to read." } },
    required: ["path"],
  },
  scope: (i) => resolve(i.path),
  async run(i) {
    const path = resolve(i.path);
    assertReadablePath(path);
    const text = await Bun.file(path).text();
    // Cap so a huge file can't blow the context window in one shot.
    const capped = text.length > 20_000 ? text.slice(0, 20_000) + "\n…[truncated]" : text;
    return { content: capped };
  },
};

export const listDirTool: Tool<{ path: string }> = {
  name: "list_dir",
  description: "List entries in a directory with type and size.",
  capabilities: ["fs.read"],
  inputSchema: {
    type: "object",
    properties: { path: { type: "string" } },
    required: ["path"],
  },
  scope: (i) => resolve(i.path),
  async run(i) {
    const dir = resolve(i.path);
    assertReadablePath(dir);
    const names = await readdir(dir);
    const rows = await Promise.all(
      names.slice(0, 500).map(async (n) => {
        try {
          const s = await stat(resolve(dir, n));
          return `${s.isDirectory() ? "d" : "-"} ${String(s.size).padStart(9)}  ${n}`;
        } catch {
          return `? ${" ".repeat(9)}  ${n}`;
        }
      }),
    );
    return { content: rows.join("\n") || "(empty)" };
  },
};

// --- act: run something (high blast radius → gate hard) --------------------

export const runShellTool: Tool<{ cmd: string }> = {
  name: "run_shell",
  description: "Run a shell command and return combined stdout/stderr.",
  capabilities: ["exec"],
  inputSchema: {
    type: "object",
    properties: { cmd: { type: "string" } },
    required: ["cmd"],
  },
  scope: (i) => i.cmd,
  async run(i, ctx) {
    const proc = Bun.spawn(["/bin/sh", "-c", i.cmd], {
      stdout: "pipe",
      stderr: "pipe",
      signal: ctx.signal,
    });
    const [out, err] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    const code = await proc.exited;
    return { content: `exit ${code}\n${out}${err}`.trim(), isError: code !== 0 };
  },
};

// --- sense: a stubbed hardware read, showing the FFI seam ------------------

export const batteryTool: Tool<Record<string, never>> = {
  name: "battery",
  description: "Current battery level (0-100), charging state, and power source.",
  capabilities: ["sense.power"],
  inputSchema: { type: "object", properties: {} },
  async run() {
    // Real IOKit read over bun:ffi (IOPSCopyPowerSourcesInfo). Works on-device
    // and on macOS laptops; returns nulls where there's no battery.
    try {
      const p = readPowerSource();
      return { content: JSON.stringify({ level: p.level, charging: p.charging, source: p.state }) };
    } catch (e) {
      return { content: `battery read failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const memoryTopicsTool: Tool<Record<string, never>> = {
  name: "memory_topics",
  description: "List Jarvis' markdown memory topics.",
  capabilities: ["memory.read"],
  inputSchema: { type: "object", properties: {} },
  async run() {
    try {
      const topics = await listMemoryTopics();
      return { content: JSON.stringify({ topics }) };
    } catch (e) {
      return { content: `memory topics failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const recallMemoryTool: Tool<{ query?: string; topic?: string; limit?: number }> = {
  name: "recall_memory",
  description:
    "Search or read Jarvis' durable markdown memory. Use topic to read a specific memory file; use query to search across topics.",
  capabilities: ["memory.read"],
  inputSchema: {
    type: "object",
    properties: {
      query: { type: "string", description: "Text to search for across memory topics." },
      topic: { type: "string", description: "Specific topic to read, without .md." },
      limit: { type: "number", description: "Maximum search results, default 8." },
    },
  },
  scope: (i) => i.topic ?? i.query ?? "recent",
  async run(i) {
    try {
      if (i.topic?.trim()) return { content: JSON.stringify(await readMemoryTopic(i.topic)) };
      const hits = await searchMemory(i.query ?? "", Math.min(Math.max(i.limit ?? 8, 1), 20));
      return { content: JSON.stringify({ hits }) };
    } catch (e) {
      return { content: `recall memory failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const rememberTool: Tool<{ topic?: string; content: string; tags?: string[] }> = {
  name: "remember",
  description:
    "Store a durable user preference, instruction, or fact in Jarvis' markdown memory. Use topic=index only for root, highest-priority standing instructions; it is always injected first. Use other topics for ordinary stable information.",
  capabilities: ["memory.write"],
  inputSchema: {
    type: "object",
    properties: {
      topic: { type: "string", description: "Memory topic filename stem, e.g. preferences or device." },
      content: { type: "string", description: "The exact memory note to append." },
      tags: { type: "array", items: { type: "string" }, description: "Optional short tags." },
    },
    required: ["content"],
  },
  scope: (i) => `${i.topic ?? "general"}: ${i.content.slice(0, 80)}`,
  async run(i) {
    try {
      const result = await remember(i.topic ?? "general", i.content, i.tags ?? []);
      return { content: JSON.stringify(result) };
    } catch (e) {
      return { content: `remember failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const screenshotTool: Tool<{ path?: string }> = {
  name: "screenshot",
  description: "Capture the current native iOS screen to a PNG file and return its path and dimensions.",
  capabilities: ["sense.screen"],
  inputSchema: {
    type: "object",
    properties: {
      path: {
        type: "string",
        description: "Optional output path under /var/jb/tmp or /tmp. Defaults to a unique /var/jb/tmp PNG.",
      },
    },
  },
  scope: (i) => i.path ?? "/var/jb/tmp/jarvis-screenshot-*.png",
  async run(i) {
    try {
      const shot = await captureScreenshot(i.path);
      return { content: JSON.stringify(shot) };
    } catch (e) {
      return { content: `screenshot failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const speakTool: Tool<{ text: string; rate?: number; voice?: string }> = {
  name: "speak",
  description: "Speak a short message out loud on the iPad.",
  capabilities: ["act.speech"],
  inputSchema: {
    type: "object",
    properties: {
      text: { type: "string", description: "Text to speak, 500 characters or less." },
      rate: { type: "number", description: "Optional AVSpeech rate." },
      voice: { type: "string", description: "Optional AVSpeech voice identifier." },
    },
    required: ["text"],
  },
  scope: (i) => i.text.slice(0, 80),
  async run(i) {
    try {
      const result = await speak(i);
      return { content: JSON.stringify(result) };
    } catch (e) {
      return { content: `speech failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const changeVoiceTool: Tool<{ action: "list" | "set" | "clear"; voice?: string; preview?: string }> = {
  name: "change_voice",
  description:
    "List installed iOS speech voices, set Jarvis' default speaking voice, or clear the default. " +
    "Use action=list before setting if the user did not provide an exact voice identifier.",
  capabilities: ["act.speech"],
  inputSchema: {
    type: "object",
    properties: {
      action: {
        type: "string",
        enum: ["list", "set", "clear"],
        description: "list voices, set a default voice, or clear the saved default.",
      },
      voice: { type: "string", description: "AVSpeechSynthesisVoice identifier to save when action=set." },
      preview: {
        type: "string",
        description: "Optional text to speak after setting or clearing the voice.",
      },
    },
    required: ["action"],
  },
  scope: (i) => `${i.action}${i.voice ? ` ${i.voice}` : ""}`,
  async run(i) {
    try {
      if (i.action === "list") {
        const result = await listSpeechVoices();
        return { content: JSON.stringify(result) };
      }
      if (i.action === "clear") {
        const settings = await clearDefaultSpeechVoice();
        const preview = i.preview?.trim() ? await speak({ text: i.preview }) : undefined;
        return { content: JSON.stringify({ settings, preview }) };
      }

      const voice = i.voice?.trim();
      if (!voice) throw new Error("voice is required when action=set");
      const settings = await setDefaultSpeechVoice(voice);
      const preview = i.preview?.trim() ? await speak({ text: i.preview, voice }) : undefined;
      return { content: JSON.stringify({ settings, preview }) };
    } catch (e) {
      return { content: `change voice failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const listenTool: Tool<{ duration?: number; path?: string }> = {
  name: "listen",
  description:
    "Record a short microphone clip on the iPad, transcribe it with on-device Speech, and return both.",
  capabilities: ["sense.microphone"],
  inputSchema: {
    type: "object",
    properties: {
      duration: { type: "number", description: "Recording duration in seconds, clamped to 1..15." },
      path: { type: "string", description: "Optional output path under /var/jb/tmp or /tmp." },
    },
  },
  scope: (i) => `${i.duration ?? 3}s ${i.path ?? "/var/jb/tmp/jarvis-listen-*.m4a"}`,
  async run(i) {
    try {
      const recording = await recordAudio(i);
      const transcription = await transcribeAudio(recording.path);
      return { content: JSON.stringify({ ...recording, ...transcription }) };
    } catch (e) {
      return { content: `listen failed: ${(e as Error).message}`, isError: true };
    }
  },
};

// --- subagent tool: lets the model fan out work itself ---------------------

export function subagentTool(spawn: SpawnFn): Tool<{ task: string; tools?: string[] }> {
  return {
    name: "spawn_subagent",
    description:
      "Delegate a self-contained subtask to a fresh agent and get its result. " +
      "Call multiple times in one turn to run subtasks in parallel.",
    capabilities: ["agent.spawn"],
    inputSchema: {
      type: "object",
      properties: {
        task: { type: "string", description: "The subtask, fully specified." },
        tools: {
          type: "array",
          items: { type: "string" },
          description: "Optional whitelist of tool names the child may use.",
        },
      },
      required: ["task"],
    },
    scope: (i) => i.task.slice(0, 60),
    async run(i) {
      const result = await spawn({ prompt: i.task, toolNames: i.tools });
      return { content: result };
    },
  };
}

export function sessionStatusTool(getSession: () => Session): Tool<Record<string, never>> {
  return {
    name: "session_status",
    description: "Get Jarvis' persistent session status: live context size, scrollback size, compaction, and pinned state counts.",
    capabilities: ["session.read"],
    inputSchema: { type: "object", properties: {} },
    async run() {
      return { content: JSON.stringify(getSession().sessionStatus()) };
    },
  };
}

export function sessionScrollbackTool(getSession: () => Session): Tool<{ offset?: number; count?: number }> {
  return {
    name: "session_scrollback",
    description:
      "Retrieve older user/assistant messages from Jarvis' persistent sliding transcript. " +
      "Use when the live context or summary is not enough. Offset skips messages back from the most recent.",
    capabilities: ["session.read"],
    inputSchema: {
      type: "object",
      properties: {
        offset: { type: "number", description: "How many recent transcript messages to skip, default 0." },
        count: { type: "number", description: "How many messages to return, default 30, max 100." },
      },
    },
    scope: (i) => `offset=${i.offset ?? 0} count=${i.count ?? 30}`,
    async run(i) {
      const rows = getSession().getScrollback(i.offset ?? 0, i.count ?? 30);
      const formatted = rows.map((r) => `${new Date(r.ts).toISOString()} ${r.role}: ${r.text}`).join("\n\n");
      return { content: formatted || "(no session scrollback)" };
    },
  };
}

export function switchModelTool(opts: {
  getModel: () => string;
  setModel: (model: string) => void;
  listModels: () => Promise<Array<{ id: string }>>;
}): Tool<{ model: string }> {
  return {
    name: "switch_model",
    description:
      "Switch Jarvis' base AI model. Only use this when the user explicitly asks to switch models. " +
      "Validates against the AI Gateway model list before accepting.",
    capabilities: ["model.switch"],
    inputSchema: {
      type: "object",
      properties: {
        model: {
          type: "string",
          description: "Full model id, e.g. anthropic/claude-sonnet-5 or anthropic/claude-opus-4.8.",
        },
      },
      required: ["model"],
    },
    scope: (i) => i.model,
    async run(i) {
      try {
        const requested = i.model.trim();
        if (!requested) throw new Error("model is required");
        const models = await opts.listModels();
        const ids = models.map((m) => m.id);
        if (!ids.includes(requested)) {
          const matches = ids.filter((id) => id.includes(requested) || requested.includes(id)).slice(0, 5);
          const suggestion = matches.length ? ` did you mean: ${matches.join(", ")}?` : "";
          return { content: `"${requested}" is not a valid model.${suggestion}`, isError: true };
        }
        const previous = opts.getModel();
        opts.setModel(requested);
        return { content: JSON.stringify({ previous, current: requested }) };
      } catch (e) {
        return { content: `switch model failed: ${(e as Error).message}`, isError: true };
      }
    },
  };
}

export const mcpConfigTool: Tool<{
  action?: "list" | "enable_preset" | "enable" | "disable" | "remove";
  presetId?: string;
  connectionId?: string;
}> = {
  name: "mcp_config",
  description:
    "List or configure external MCP server presets for Jarvis. This only changes MCP endpoint configuration; " +
    "it does not store OAuth tokens or call the remote MCP tools.",
  capabilities: ["mcp.configure"],
  inputSchema: {
    type: "object",
    properties: {
      action: {
        type: "string",
        enum: ["list", "enable_preset", "enable", "disable", "remove"],
        description: "Configuration action. Use list unless the user explicitly asks to change MCP setup.",
      },
      presetId: {
        type: "string",
        description: "Preset id to add, e.g. google_calendar, gmail, or github.",
      },
      connectionId: {
        type: "string",
        description: "Configured connection id to enable, disable, or remove.",
      },
    },
  },
  scope: (i) => `${i.action ?? "list"} ${i.presetId ?? i.connectionId ?? "mcp"}`,
  async run(i) {
    try {
      const action = i.action ?? "list";
      const settings = loadSettings();
      let mcp = normalizeMcpConfig(settings.mcp);
      if (action === "enable_preset") {
        if (!i.presetId) throw new Error("presetId is required");
        mcp = upsertMcpConnection(mcp, defaultMcpConnection(i.presetId, true));
        saveSettings({ ...settings, mcp });
      } else if (action === "enable" || action === "disable") {
        const id = i.connectionId ?? i.presetId;
        if (!id) throw new Error("connectionId is required");
        mcp = setMcpConnectionEnabled(mcp, id, action === "enable");
        saveSettings({ ...settings, mcp });
      } else if (action === "remove") {
        const id = i.connectionId ?? i.presetId;
        if (!id) throw new Error("connectionId is required");
        mcp = removeMcpConnection(mcp, id);
        saveSettings({ ...settings, mcp });
      }
      return { content: JSON.stringify({ presets: MCP_PRESETS, ...mcp, clientConfig: mcpClientConfig(mcp) }) };
    } catch (e) {
      return { content: `mcp config failed: ${(e as Error).message}`, isError: true };
    }
  },
};

export const deviceTools: Tool[] = [
  readFileTool,
  listDirTool,
  runShellTool,
  batteryTool,
  memoryTopicsTool,
  recallMemoryTool,
  rememberTool,
  screenshotTool,
  speakTool,
  changeVoiceTool,
  listenTool,
  mcpConfigTool,
];

function assertReadablePath(path: string): void {
  const name = basename(path);
  if (name === ".env" || name.endsWith(".env")) {
    throw new Error("refusing to read secret environment files");
  }
}
