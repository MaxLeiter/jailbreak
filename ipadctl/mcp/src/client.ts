import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  Action,
  ActionsResponse,
  AppInfo,
  DaemonError,
  Info,
  ScreenshotMeta,
  ScreenshotRequest,
} from "./types.ts";

// The token lives in a 0600 file so it never has to sit in plain text in an MCP config.
const tokenFilePath = (env: NodeJS.ProcessEnv) =>
  env.IPADCTL_TOKEN_FILE ?? join(homedir(), ".config", "ipadctl", "token");

function readTokenFile(path: string): string | undefined {
  try {
    return readFileSync(path, "utf8").trim() || undefined;
  } catch {
    return undefined;
  }
}

// Rough upper bound on how long the daemon spends executing `actions` (it runs them
// back to back on one serial queue), mirroring the timings in ipadctl/core/hid.m and
// the daemon's own clamps. Used to size the request timeout: a fixed 20 s abort fired
// in the middle of a valid batch (a 4000-character `type` takes minutes), and the
// model was then told the iPad was unreachable while its actions kept running.
export function estimateActionsMs(actions: Action[], screenshot: boolean): number {
  const clamp = (v: number | undefined, d: number) => Math.min(Math.max(v ?? d, 0), 10_000);
  let ms = screenshot ? 1_500 : 0;
  for (const a of actions) {
    switch (a.type) {
      case "tap": ms += 150; break;
      case "double_tap": ms += 400; break;
      case "long_press": ms += clamp(a.duration_ms, 800) + 150; break;
      case "swipe": ms += clamp(a.duration_ms, 300) + 150; break;
      case "scroll": ms += 1_300; break;
      case "type": ms += Math.min(a.text.length, 4000) * 75; break;
      case "key": ms += 200; break;
      case "button": ms += 200; break;
      case "open_app": case "open_url": ms += 2_000; break;
      case "wait": ms += clamp(a.ms, 0); break;
    }
  }
  return ms;
}

export class DaemonRequestError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly details?: Record<string, unknown>,
  ) {
    super(message);
  }
}

export interface Screenshot {
  jpeg: Uint8Array;
  meta: ScreenshotMeta;
}

export class DaemonClient {
  constructor(
    readonly baseUrl: string,
    private readonly token: string | undefined,
    private readonly timeoutMs = 20_000,
  ) {}

  static fromEnv(env = process.env): DaemonClient {
    return new DaemonClient(
      // `||`, not `??`: the agent runner passes IPADCTL_URL="" when it is unset.
      (env.IPADCTL_URL || "http://MaxsiPad.local:8790").replace(/\/+$/, ""),
      env.IPADCTL_TOKEN || readTokenFile(tokenFilePath(env)),
    );
  }

  private async req(method: string, path: string, body?: unknown, timeoutMs = this.timeoutMs): Promise<Response> {
    if (!this.token) {
      throw new DaemonRequestError(
        `No bearer token: set IPADCTL_TOKEN, or put ipadctld's token in ${tokenFilePath(process.env)} (mode 0600).`,
        "unauthorized",
      );
    }
    let res: Response;
    try {
      res = await fetch(this.baseUrl + path, {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          ...(body === undefined ? {} : { "content-type": "application/json" }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (e) {
      const err = e as Error;
      const timedOut = err.name === "TimeoutError" || err.name === "AbortError";
      if (timedOut && path === "/v1/actions") {
        throw new DaemonRequestError(
          `ipadctld at ${this.baseUrl} did not answer within ${Math.round(timeoutMs / 1000)}s. Some or all of the actions may have run on the iPad. Take a screenshot to see what happened before retrying anything.`,
          "unreachable",
        );
      }
      throw new DaemonRequestError(
        timedOut
          ? `ipadctld at ${this.baseUrl} did not answer within ${Math.round(timeoutMs / 1000)}s. The iPad may be asleep or off the network.`
          : `Cannot reach ipadctld at ${this.baseUrl} (${err.message}). Check that the iPad is awake and on the LAN/Tailscale, ipadctld is running, and IPADCTL_URL is correct.`,
        "unreachable",
      );
    }
    if (!res.ok) {
      let e: DaemonError | undefined;
      try {
        e = ((await res.json()) as { error?: DaemonError }).error;
      } catch {}
      if (res.status === 401) {
        throw new DaemonRequestError("ipadctld rejected the bearer token (401). Check IPADCTL_TOKEN.", "unauthorized");
      }
      throw new DaemonRequestError(
        e?.message ?? `ipadctld returned HTTP ${res.status}`,
        e?.code ?? "internal",
        e?.details,
      );
    }
    return res;
  }

  async info(): Promise<Info> {
    return (await (await this.req("GET", "/v1/info")).json()) as Info;
  }

  async apps(): Promise<AppInfo[]> {
    return ((await (await this.req("GET", "/v1/apps")).json()) as { apps: AppInfo[] }).apps;
  }

  async screenshot(opts: ScreenshotRequest = {}): Promise<Screenshot> {
    const res = await this.req("POST", "/v1/screenshot", opts);
    const h = res.headers;
    const meta: ScreenshotMeta = {
      width: Number(h.get("x-ipad-width")),
      height: Number(h.get("x-ipad-height")),
      scale: Number(h.get("x-ipad-scale")),
      orientation: (h.get("x-ipad-orientation") ?? "landscape_left") as ScreenshotMeta["orientation"],
      frontmost: h.get("x-ipad-frontmost") ?? "unknown",
      locked: h.get("x-ipad-locked") === "true",
    };
    return { jpeg: new Uint8Array(await res.arrayBuffer()), meta };
  }

  async actions(actions: Action[], returnScreenshot: boolean): Promise<ActionsResponse> {
    return (await (
      await this.req(
        "POST",
        "/v1/actions",
        { actions, screenshot: returnScreenshot ? {} : undefined },
        this.timeoutMs + Math.ceil(estimateActionsMs(actions, returnScreenshot) * 1.5),
      )
    ).json()) as ActionsResponse;
  }
}
