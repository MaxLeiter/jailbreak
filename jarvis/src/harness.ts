// Jarvis harness core.
//
// The whole agent is this file plus a set of tools you hand it. The loop is
// deliberately small; the policy hung off it (permissions, routing, compaction,
// durability) is where the real behaviour lives. Everything the loop touches is
// an interface so the device-specific parts (IOKit, input injection, the model
// provider) plug in without the core knowing about them.

import Anthropic from "@anthropic-ai/sdk";

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

// A capability is a coarse permission tag the broker reasons about, e.g.
// "fs.read", "act.tap", "net.send", "read.messages". Tools declare which ones
// they need; the broker decides whether a given call is allowed.
export type Capability = string;

export interface ToolOutput {
  content: string;
  isError?: boolean;
}

export interface ToolContext {
  sessionId: string;
  // Aborts when the turn is cancelled. Long-running tools must honour it.
  signal: AbortSignal;
  log: (msg: string, extra?: unknown) => void;
  // Spawn a child agent (parallel subagents = call this N times, Promise.all).
  spawn: SpawnFn;
}

export interface Tool<I = any> {
  name: string;
  description: string;
  inputSchema: Anthropic.Tool["input_schema"];
  capabilities: Capability[];
  // Human-readable resource this call touches (a path, a url, an app id).
  // Feeds the permission prompt and the audit log so grants can be scoped.
  scope?(input: I): string;
  run(input: I, ctx: ToolContext): Promise<ToolOutput>;
}

// ---------------------------------------------------------------------------
// Permission broker — sits in the dispatch path, gates every tool call.
// ---------------------------------------------------------------------------

export type Decision = { allow: true } | { allow: false; reason: string };

export interface PermissionRequest {
  tool: Tool;
  input: unknown;
  scope: string;
  sessionId: string;
}

export interface PermissionBroker {
  check(req: PermissionRequest): Promise<Decision>;
}

export type Mode = "allow" | "ask" | "deny";

export interface AuditEntry {
  ts: number;
  sessionId: string;
  tool: string;
  scope: string;
  capabilities: Capability[];
  mode: Mode;
  allowed: boolean;
}

const RANK: Record<Mode, number> = { allow: 0, ask: 1, deny: 2 };
const mostRestrictive = (a: Mode, b: Mode): Mode => (RANK[a] >= RANK[b] ? a : b);

// Default broker: per-capability policy, most-restrictive-wins, with an async
// `ask` hook for the human-in-the-loop and a mandatory audit sink. Every
// decision is recorded whether or not it was allowed.
export class PolicyBroker implements PermissionBroker {
  constructor(
    private opts: {
      policy: Record<Capability, Mode>;
      defaultMode?: Mode;
      ask: (req: PermissionRequest) => Promise<boolean>;
      audit: (entry: AuditEntry) => void;
    },
  ) {}

  // Read/patch the live policy — lets the console show and edit the trust
  // boundary without restarting the daemon.
  policyView(): Record<Capability, Mode> {
    return { ...this.opts.policy };
  }
  setMode(cap: Capability, mode: Mode) {
    this.opts.policy[cap] = mode;
  }

  async check(req: PermissionRequest): Promise<Decision> {
    const caps = req.tool.capabilities;
    let mode: Mode = "allow";
    for (const cap of caps) {
      mode = mostRestrictive(mode, this.opts.policy[cap] ?? this.opts.defaultMode ?? "ask");
    }

    let allowed: boolean;
    if (mode === "deny") allowed = false;
    else if (mode === "allow") allowed = true;
    else allowed = await this.opts.ask(req);

    this.opts.audit({
      ts: nowMs(),
      sessionId: req.sessionId,
      tool: req.tool.name,
      scope: req.scope,
      capabilities: caps,
      mode,
      allowed,
    });

    if (allowed) return { allow: true };
    return { allow: false, reason: mode === "deny" ? "denied by policy" : "denied by user" };
  }
}

// ---------------------------------------------------------------------------
// Model routing — pick the model/limits per turn (cheap heartbeat vs. escalate).
// ---------------------------------------------------------------------------

export interface RouteContext {
  session: Session;
  turn: number; // tool-use turns taken so far this send()
}

export interface ModelRouter {
  pick(ctx: RouteContext): { model: string; maxTokens: number };
}

export interface TieredModelConfig {
  base: string;
  heavy: string;
  escalateAfterTurns?: number;
  maxTokens?: number;
}

// Start on a mid model; escalate to the heavy one once a request has proven it
// needs several tool round-trips (i.e. it's real work, not a one-shot answer).
export class TieredRouter implements ModelRouter {
  constructor(private opts: TieredModelConfig) {}
  pick(ctx: RouteContext) {
    const escalate = ctx.turn >= (this.opts.escalateAfterTurns ?? 3);
    return { model: escalate ? this.opts.heavy : this.opts.base, maxTokens: this.opts.maxTokens ?? 4096 };
  }
  config(): TieredModelConfig {
    return { ...this.opts };
  }
  setBase(model: string): void {
    this.opts = { ...this.opts, base: model };
  }
}

// ---------------------------------------------------------------------------
// Durable state
// ---------------------------------------------------------------------------

export interface SessionSnapshot {
  id: string;
  messages: Anthropic.MessageParam[];
  summary: string; // rolling compaction summary
  pinned: string[]; // durable facts that must survive compaction
  scrollback?: ScrollbackEntry[]; // Maxbot-style bounded transcript outside the live context window
}

export interface SessionStore {
  save(s: SessionSnapshot): Promise<void>;
  load(id: string): Promise<SessionSnapshot | null>;
}

export interface ScrollbackEntry {
  ts: number;
  role: "user" | "assistant";
  text: string;
}

// ---------------------------------------------------------------------------
// Subagents
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Events — the loop emits these so a UI (the web console) can watch the agent
// think in real time without coupling the loop to any transport.
// ---------------------------------------------------------------------------

export type SessionEvent =
  | { type: "turn"; turn: number; model: string }
  | { type: "tool_use"; id: string; tool: string; scope: string; input: unknown }
  | { type: "permission"; id: string; tool: string; scope: string; allowed: boolean; reason?: string }
  | { type: "tool_result"; id: string; tool: string; isError: boolean; content?: string }
  | { type: "compacting"; messages: number }
  | { type: "text"; text: string }
  | { type: "done" };

export interface SpawnRequest {
  prompt: string;
  system?: string;
  toolNames?: string[]; // restrict the child's tools; default = inherit all
  model?: string;
}
export type SpawnFn = (req: SpawnRequest) => Promise<string>;

// ---------------------------------------------------------------------------
// Session — the agent loop.
// ---------------------------------------------------------------------------

export interface SessionDeps {
  client: Anthropic;
  tools: Tool[];
  broker: PermissionBroker;
  router: ModelRouter;
  systemPrompt: string;
  store?: SessionStore;
  // Compact when the last observed context size crosses this many tokens. 0 = off.
  compactAt?: number;
  // Model used only for the compaction summary (keep it cheap).
  compactionModel?: string;
  keepRecent?: number; // messages left verbatim after compaction
  scrollbackLimit?: number;
  systemContext?: () => Promise<string>;
  spawn?: SpawnFn; // subagent spawner exposed to tools; omit to disable
  onEvent?: (e: SessionEvent) => void; // structured stream for a UI/console
  log?: (msg: string, extra?: unknown) => void;
}

export class Session {
  messages: Anthropic.MessageParam[] = [];
  pinned: string[] = [];
  scrollback: ScrollbackEntry[] = [];
  summary = "";
  // Best available proxy for "how big is the context going in next" — the input
  // token count the API reported last turn. Drives compaction.
  lastInputTokens = 0;

  constructor(
    public id: string,
    private deps: SessionDeps,
  ) {}

  private log(msg: string, extra?: unknown) {
    this.deps.log?.(msg, extra);
  }

  private emit(e: SessionEvent) {
    this.deps.onEvent?.(e);
  }

  snapshot(): SessionSnapshot {
    return { id: this.id, messages: this.messages, summary: this.summary, pinned: this.pinned, scrollback: this.scrollback };
  }

  restore(s: SessionSnapshot) {
    this.messages = s.messages;
    this.summary = s.summary;
    this.pinned = s.pinned;
    this.scrollback = s.scrollback ?? [];
  }

  // Pin a durable fact. Pinned state is injected into the system prompt and is
  // never dropped by compaction — this is where "the thing that matters" lives.
  pin(fact: string) {
    this.pinned.push(fact);
  }

  async send(userText: string, signal?: AbortSignal): Promise<string> {
    this.messages.push({ role: "user", content: userText });
    this.recordScrollback("user", userText);
    return this.run(signal ?? new AbortController().signal);
  }

  sessionStatus() {
    return {
      sessionId: this.id,
      liveMessages: this.messages.length,
      scrollbackMessages: this.scrollback.length,
      scrollbackLimit: this.deps.scrollbackLimit ?? 200,
      summaryChars: this.summary.length,
      pinned: this.pinned.length,
      lastInputTokens: this.lastInputTokens,
      compactAt: this.deps.compactAt ?? 0,
      keepRecent: this.deps.keepRecent ?? 8,
    };
  }

  getScrollback(offset = 0, count = 30): ScrollbackEntry[] {
    const safeOffset = Math.max(0, Math.floor(offset));
    const safeCount = Math.min(100, Math.max(1, Math.floor(count)));
    const end = Math.max(0, this.scrollback.length - safeOffset);
    const start = Math.max(0, end - safeCount);
    return this.scrollback.slice(start, end);
  }

  // --- loop ---------------------------------------------------------------

  private async run(signal: AbortSignal): Promise<string> {
    let turn = 0;
    while (true) {
      if (signal.aborted) throw new DOMException("aborted", "AbortError");
      await this.maybeCompact(signal);

      const { model, maxTokens } = this.deps.router.pick({ session: this, turn });
      this.log(`turn ${turn}: ${model}`);
      this.emit({ type: "turn", turn, model });

      const resp = await this.deps.client.messages.create(
        {
          model,
          max_tokens: maxTokens,
          system: await this.buildSystem(),
          tools: this.toolParams(),
          messages: this.messages,
        },
        { signal },
      );

      this.lastInputTokens = resp.usage.input_tokens + resp.usage.output_tokens;
      this.messages.push({ role: "assistant", content: resp.content });
      await this.deps.store?.save(this.snapshot());

      if (resp.stop_reason !== "tool_use") {
        const text = textOf(resp.content);
        this.recordScrollback("assistant", text);
        await this.deps.store?.save(this.snapshot());
        this.emit({ type: "text", text });
        this.emit({ type: "done" });
        return text;
      }

      const uses = resp.content.filter((b): b is Anthropic.ToolUseBlock => b.type === "tool_use");
      // Parallel dispatch: independent tool calls run concurrently. Each one is
      // permission-checked before it executes.
      const results = await Promise.all(uses.map((u) => this.dispatch(u, signal)));
      this.messages.push({ role: "user", content: results });
      await this.deps.store?.save(this.snapshot());
      turn++;
    }
  }

  private async dispatch(
    use: Anthropic.ToolUseBlock,
    signal: AbortSignal,
  ): Promise<Anthropic.ToolResultBlockParam> {
    const tool = this.deps.tools.find((t) => t.name === use.name);
    if (!tool) return errorResult(use.id, `unknown tool: ${use.name}`);

    const scope = tool.scope?.(use.input) ?? "";
    this.emit({ type: "tool_use", id: use.id, tool: tool.name, scope, input: use.input });
    const decision = await this.deps.broker.check({
      tool,
      input: use.input,
      scope,
      sessionId: this.id,
    });
    this.emit({
      type: "permission",
      id: use.id,
      tool: tool.name,
      scope,
      allowed: decision.allow,
      reason: decision.allow ? undefined : decision.reason,
    });
    if (!decision.allow) return errorResult(use.id, `permission denied: ${decision.reason}`);

    try {
      const out = await tool.run(use.input, {
        sessionId: this.id,
        signal,
        log: (m, e) => this.log(`[${tool.name}] ${m}`, e),
        spawn: this.deps.spawn ?? notSpawnable,
      });
      this.emit({ type: "tool_result", id: use.id, tool: tool.name, isError: !!out.isError, content: out.content });
      return { type: "tool_result", tool_use_id: use.id, content: out.content, is_error: out.isError };
    } catch (err) {
      this.emit({ type: "tool_result", id: use.id, tool: tool.name, isError: true, content: `tool error: ${(err as Error).message}` });
      return errorResult(use.id, `tool error: ${(err as Error).message}`);
    }
  }

  // --- prompt assembly ----------------------------------------------------

  // System prefix is stable across a session (prompt + summary + pinned) so we
  // set a cache breakpoint on its last block. Tools get their own breakpoint.
  // These two caches carry most of the always-on cost; owning them is a big
  // reason the loop is hand-rolled rather than delegated.
  private async buildSystem(): Promise<Anthropic.TextBlockParam[]> {
    const blocks: Anthropic.TextBlockParam[] = [{ type: "text", text: this.deps.systemPrompt }];
    const context = await this.deps.systemContext?.();
    if (context) blocks.push({ type: "text", text: context });
    if (this.summary) blocks.push({ type: "text", text: `Conversation so far:\n${this.summary}` });
    if (this.pinned.length) blocks.push({ type: "text", text: `Durable state:\n- ${this.pinned.join("\n- ")}` });
    blocks[blocks.length - 1].cache_control = { type: "ephemeral" };
    return blocks;
  }

  private recordScrollback(role: ScrollbackEntry["role"], text: string) {
    const clean = text.trim();
    if (!clean) return;
    this.scrollback.push({ ts: nowMs(), role, text: clean.length > 4_000 ? `${clean.slice(0, 4_000)}\n...[truncated]` : clean });
    const limit = this.deps.scrollbackLimit ?? 200;
    if (this.scrollback.length > limit) {
      this.scrollback.splice(0, this.scrollback.length - limit);
    }
  }

  private toolParams(): Anthropic.Tool[] {
    const params = this.deps.tools.map((t) => ({
      name: t.name,
      description: t.description,
      input_schema: t.inputSchema,
    })) as Anthropic.Tool[];
    if (params.length) params[params.length - 1].cache_control = { type: "ephemeral" };
    return params;
  }

  // --- compaction ---------------------------------------------------------

  // Fold the old head of the conversation into `this.summary`, leaving recent
  // turns verbatim. The one real subtlety: never cut through a tool_use ↔
  // tool_result pair, or the API rejects the next request. We only cut on a
  // plain-text user turn, which is always a clean round boundary.
  private async maybeCompact(signal: AbortSignal): Promise<void> {
    const threshold = this.deps.compactAt ?? 0;
    if (!threshold || this.lastInputTokens < threshold) return;

    const keep = this.deps.keepRecent ?? 8;
    const cut = safeCutIndex(this.messages, this.messages.length - keep);
    if (cut <= 0) return; // nothing safely compactable yet

    const head = this.messages.slice(0, cut);
    this.log(`compacting ${head.length} messages (ctx≈${this.lastInputTokens} tok)`);
    this.emit({ type: "compacting", messages: head.length });

    const resp = await this.deps.client.messages.create(
      {
        model: this.deps.compactionModel ?? "claude-haiku-4-5-20251001",
        max_tokens: 1024,
        system:
          "You compress an agent's working history. Preserve durable facts, decisions made, " +
          "task state, and anything still needed later. Drop chatter. Be terse and lossless about state.",
        messages: [
          ...head,
          { role: "user", content: "Summarise everything above as compact durable state." },
        ],
      },
      { signal },
    );

    const note = textOf(resp.content);
    this.summary = this.summary ? `${this.summary}\n${note}` : note;
    this.messages = this.messages.slice(cut);
    // Reset the proxy so we don't immediately re-compact before the next real turn.
    this.lastInputTokens = 0;
    await this.deps.store?.save(this.snapshot());
  }
}

// ---------------------------------------------------------------------------
// Subagent spawner factory — builds a SpawnFn bound to shared deps. Child
// sessions reuse the same broker (permissions still enforced) and router.
// ---------------------------------------------------------------------------

export function makeSpawner(
  base: Omit<SessionDeps, "systemPrompt"> & { systemPrompt: string; childCounter?: () => string },
): SpawnFn {
  let n = 0;
  const spawn: SpawnFn = async (req) => {
    const childId = `${base.childCounter?.() ?? `sub-${++n}`}`;
    const tools = req.toolNames
      ? base.tools.filter((t) => req.toolNames!.includes(t.name))
      : base.tools;
    const router: ModelRouter = req.model
      ? { pick: () => ({ model: req.model!, maxTokens: 4096 }) }
      : base.router;
    const child = new Session(childId, {
      ...base,
      tools,
      router,
      systemPrompt: req.system ?? base.systemPrompt,
      // Give the child its own spawner so it can fan out one more level.
      spawn,
      store: undefined, // subagents are ephemeral by default
    });
    return child.send(req.prompt);
  };
  return spawn;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function textOf(content: Anthropic.ContentBlock[]): string {
  return content
    .filter((b): b is Anthropic.TextBlock => b.type === "text")
    .map((b) => b.text)
    .join("\n");
}

function errorResult(id: string, msg: string): Anthropic.ToolResultBlockParam {
  return { type: "tool_result", tool_use_id: id, content: msg, is_error: true };
}

// Largest index <= preferred where messages[index] is a plain-text user turn,
// so slicing there leaves no orphaned tool_result and no dangling tool_use.
function safeCutIndex(messages: Anthropic.MessageParam[], preferred: number): number {
  for (let i = Math.min(preferred, messages.length - 1); i > 0; i--) {
    const m = messages[i];
    if (m.role === "user" && typeof m.content === "string") return i;
  }
  return 0;
}

const notSpawnable: SpawnFn = async () => {
  throw new Error("subagents not configured for this session");
};

// nowMs is isolated so a deterministic clock can be injected in tests.
function nowMs(): number {
  return Date.now();
}
