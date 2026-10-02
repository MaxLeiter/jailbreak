import type {
  Action,
  ActionsResponse,
  AppInfo,
  DaemonError,
  Info,
  ScreenshotMeta,
  ScreenshotRequest,
} from "./types.ts";

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
      (env.IPADCTL_URL ?? "http://MaxsiPad.local:8790").replace(/\/+$/, ""),
      env.IPADCTL_TOKEN,
    );
  }

  private async req(method: string, path: string, body?: unknown): Promise<Response> {
    if (!this.token) {
      throw new DaemonRequestError(
        "IPADCTL_TOKEN is not set. Set it to the bearer token configured on ipadctld.",
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
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (e) {
      const err = e as Error;
      const timedOut = err.name === "TimeoutError" || err.name === "AbortError";
      throw new DaemonRequestError(
        timedOut
          ? `ipadctld at ${this.baseUrl} did not answer within ${this.timeoutMs / 1000}s. The iPad may be asleep or off the network.`
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
      await this.req("POST", "/v1/actions", { actions, screenshot: returnScreenshot ? {} : undefined })
    ).json()) as ActionsResponse;
  }
}
