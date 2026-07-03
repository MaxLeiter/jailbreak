export type McpTransport = "http" | "sse";

export interface McpPreset {
  id: string;
  name: string;
  provider: string;
  description: string;
  url: string;
  transport: McpTransport;
  auth: string;
  capability: string;
  setup: string[];
}

export interface McpConnection {
  id: string;
  presetId: string;
  name: string;
  provider: string;
  url: string;
  transport: McpTransport;
  capability: string;
  auth: string;
  enabled: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface McpConfig {
  connections: McpConnection[];
}

export const MCP_PRESETS: McpPreset[] = [
  {
    id: "google_calendar",
    name: "Google Calendar",
    provider: "Google Workspace",
    description: "Read calendars, list events, create meetings, suggest times, and update invitations.",
    url: "https://calendarmcp.googleapis.com/mcp/v1",
    transport: "http",
    auth: "Google OAuth 2.0",
    capability: "mcp.google_calendar",
    setup: [
      "Enable Google Calendar API and Google Calendar MCP API in a Google Cloud project.",
      "Configure the OAuth consent screen and an OAuth client for Jarvis.",
    ],
  },
  {
    id: "gmail",
    name: "Gmail",
    provider: "Google Workspace",
    description: "Search threads, read mail, manage labels, and create drafts for review.",
    url: "https://gmailmcp.googleapis.com/mcp/v1",
    transport: "http",
    auth: "Google OAuth 2.0",
    capability: "mcp.gmail",
    setup: [
      "Enable Gmail API and Gmail MCP API in a Google Cloud project.",
      "Configure the OAuth consent screen and an OAuth client for Jarvis.",
    ],
  },
  {
    id: "github",
    name: "GitHub",
    provider: "GitHub",
    description: "Work with repositories, issues, pull requests, notifications, projects, and CI state.",
    url: "https://api.githubcopilot.com/mcp/",
    transport: "http",
    auth: "GitHub OAuth or bearer token in the MCP client",
    capability: "mcp.github",
    setup: [
      "Use GitHub's hosted remote MCP server.",
      "Start with read-only mode or narrow toolsets before enabling write workflows.",
    ],
  },
];

const PRESET_BY_ID = new Map(MCP_PRESETS.map((preset) => [preset.id, preset]));

export function mcpPreset(id: string): McpPreset | undefined {
  return PRESET_BY_ID.get(id);
}

export function normalizeMcpConfig(config: unknown): McpConfig {
  if (!config || typeof config !== "object") return { connections: [] };
  const raw = config as { connections?: unknown };
  if (!Array.isArray(raw.connections)) return { connections: [] };
  const connections = raw.connections.flatMap((entry): McpConnection[] => {
    if (!entry || typeof entry !== "object") return [];
    const c = entry as Partial<McpConnection>;
    const preset = typeof c.presetId === "string" ? mcpPreset(c.presetId) : undefined;
    const url = typeof c.url === "string" && c.url.startsWith("https://") ? c.url : preset?.url;
    if (!preset || !url) return [];
    const now = new Date().toISOString();
    return [
      {
        id: typeof c.id === "string" && c.id.trim() ? c.id.trim() : preset.id,
        presetId: preset.id,
        name: typeof c.name === "string" && c.name.trim() ? c.name.trim() : preset.name,
        provider: preset.provider,
        url,
        transport: c.transport === "sse" ? "sse" : preset.transport,
        capability: preset.capability,
        auth: preset.auth,
        enabled: c.enabled !== false,
        createdAt: typeof c.createdAt === "string" ? c.createdAt : now,
        updatedAt: typeof c.updatedAt === "string" ? c.updatedAt : now,
      },
    ];
  });
  return { connections };
}

export function defaultMcpConnection(presetId: string, enabled = true): McpConnection {
  const preset = mcpPreset(presetId);
  if (!preset) throw new Error(`unknown MCP preset: ${presetId}`);
  const now = new Date().toISOString();
  return {
    id: preset.id,
    presetId: preset.id,
    name: preset.name,
    provider: preset.provider,
    url: preset.url,
    transport: preset.transport,
    capability: preset.capability,
    auth: preset.auth,
    enabled,
    createdAt: now,
    updatedAt: now,
  };
}

export function upsertMcpConnection(config: McpConfig, connection: McpConnection): McpConfig {
  const clean = normalizeMcpConfig(config);
  const next = { ...connection, updatedAt: new Date().toISOString() };
  const index = clean.connections.findIndex((c) => c.id === connection.id);
  if (index === -1) return { connections: [...clean.connections, next] };
  const connections = clean.connections.slice();
  connections[index] = { ...connections[index], ...next, createdAt: connections[index].createdAt };
  return { connections };
}

export function setMcpConnectionEnabled(config: McpConfig, id: string, enabled: boolean): McpConfig {
  const clean = normalizeMcpConfig(config);
  const connections = clean.connections.map((connection) =>
    connection.id === id ? { ...connection, enabled, updatedAt: new Date().toISOString() } : connection,
  );
  return { connections };
}

export function removeMcpConnection(config: McpConfig, id: string): McpConfig {
  const clean = normalizeMcpConfig(config);
  return { connections: clean.connections.filter((connection) => connection.id !== id) };
}

export function mcpClientConfig(config: McpConfig): { mcpServers: Record<string, { type: McpTransport; url: string }> } {
  const servers: Record<string, { type: McpTransport; url: string }> = {};
  for (const connection of normalizeMcpConfig(config).connections) {
    if (connection.enabled) servers[connection.id] = { type: connection.transport, url: connection.url };
  }
  return { mcpServers: servers };
}
