// Fake ipadctld for testing the MCP server without the iPad. Implements ipadctl/API.md.
//   bun run fake-daemon            # listens on 127.0.0.1:8791, token "test-token"
import jpeg from "jpeg-js";
import type { Action, ActionResult, DaemonError, ErrorCode } from "../src/types.ts";

export const W = 1080;
export const H = 810;

export const FAKE_APPS = [
  { bundle_id: "com.apple.springboard", name: "Home Screen" },
  { bundle_id: "com.apple.MobileSMS", name: "Messages" },
  { bundle_id: "com.apple.mobilesafari", name: "Safari" },
  { bundle_id: "com.apple.Preferences", name: "Settings" },
  { bundle_id: "com.apple.mobilenotes", name: "Notes" },
];
const BLOCKED = new Set(["com.apple.Preferences"]);

export interface FakeState {
  frontmost: string;
  locked: boolean;
  recorded: Action[];
}

function renderRGBA(): Buffer {
  // Gradient with a 90px grid and a red marker at the center.
  const buf = Buffer.alloc(W * H * 4);
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      const grid = x % 90 === 0 || y % 90 === 0;
      const center = Math.abs(x - W / 2) < 12 && Math.abs(y - H / 2) < 12;
      buf[i] = center ? 230 : grid ? 40 : (x * 255) / W;
      buf[i + 1] = center ? 30 : grid ? 40 : (y * 255) / H;
      buf[i + 2] = center ? 30 : grid ? 60 : 180;
      buf[i + 3] = 255;
    }
  return buf;
}
const FRAME = renderRGBA();

function encode(quality: number, region?: { x: number; y: number; w: number; h: number }) {
  const r = region ?? { x: 0, y: 0, w: W, h: H };
  const x0 = Math.max(0, Math.min(W - 1, r.x));
  const y0 = Math.max(0, Math.min(H - 1, r.y));
  const w = Math.max(1, Math.min(W - x0, r.w));
  const h = Math.max(1, Math.min(H - y0, r.h));
  const out = Buffer.alloc(w * h * 4);
  for (let row = 0; row < h; row++) FRAME.copy(out, row * w * 4, ((y0 + row) * W + x0) * 4, ((y0 + row) * W + x0 + w) * 4);
  return { data: jpeg.encode({ data: out, width: w, height: h }, quality).data, w, h };
}

const err = (code: ErrorCode, message: string, details?: Record<string, unknown>): DaemonError => ({ code, message, details });
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

export function startFakeDaemon(opts: { port?: number; token?: string; frontmost?: string } = {}) {
  const token = opts.token ?? "test-token";
  const state: FakeState = { frontmost: opts.frontmost ?? "com.apple.MobileSMS", locked: false, recorded: [] };
  const nameOf = (b: string) => FAKE_APPS.find((a) => a.bundle_id === b)?.name ?? b;

  const matchesApp = (claimed: string) => {
    const c = claimed.trim().toLowerCase();
    return c === state.frontmost.toLowerCase() || c === nameOf(state.frontmost).toLowerCase();
  };

  const shotHeaders = (w: number, h: number): Record<string, string> => ({
    "content-type": "image/jpeg",
    "x-ipad-width": String(w),
    "x-ipad-height": String(h),
    "x-ipad-scale": "2",
    "x-ipad-orientation": "landscape_left",
    "x-ipad-frontmost": state.frontmost,
    "x-ipad-locked": String(state.locked),
  });

  function validate(a: any): DaemonError | null {
    const need = (k: string) => typeof a[k] === "string" && a[k].trim().length > 0;
    const num = (k: string) => Number.isFinite(a[k]);
    if (a.type === "wait") return Number.isFinite(a.ms) ? null : err("invalid", "wait needs ms");
    if (!need("app") || !need("target") || !need("why")) return err("invalid", `${a.type} requires app, target and why`);
    switch (a.type) {
      case "tap": case "double_tap": case "long_press": case "scroll":
        if (!num("x") || !num("y")) return err("invalid", `${a.type} needs x,y`);
        if (a.x < 0 || a.y < 0 || a.x >= W || a.y >= H) return err("invalid", `(${a.x},${a.y}) is outside the ${W}x${H} screen`);
        if (a.type === "scroll" && !["up", "down", "left", "right"].includes(a.direction)) return err("invalid", "bad scroll direction");
        return null;
      case "swipe":
        return num("x") && num("y") && num("x2") && num("y2") ? null : err("invalid", "swipe needs x,y,x2,y2");
      case "type": return need("text") ? null : err("invalid", "type needs text");
      case "key": return need("key") ? null : err("invalid", "key needs key");
      case "button": return ["home", "volume_up", "volume_down"].includes(a.name) ? null : err("invalid", `unknown button '${a.name}' (no lock button)`);
      case "open_app": return FAKE_APPS.some((x) => x.bundle_id === a.bundle_id) ? null : err("invalid", `unknown bundle id ${a.bundle_id}`);
      case "open_url": return need("url") ? null : err("invalid", "open_url needs url");
      default: return err("invalid", `unknown action type '${a.type}'`);
    }
  }

  function run(a: any): DaemonError | null {
    const bad = validate(a);
    if (bad) return bad;
    if (a.type === "wait") return null;
    if (state.locked) return err("locked", "device is locked");
    if (!matchesApp(a.app)) {
      return err("app_mismatch", `expected ${a.app} but frontmost is ${state.frontmost}`, { expected: a.app, actual: state.frontmost });
    }
    if (BLOCKED.has(state.frontmost)) return err("app_blocked", `${nameOf(state.frontmost)} is blocked by policy`);
    if (a.type === "open_app" && BLOCKED.has(a.bundle_id)) return err("app_blocked", `${a.bundle_id} is blocked by policy`);
    state.recorded.push(a);
    if (a.type === "open_app") state.frontmost = a.bundle_id;
    if (a.type === "button" && a.name === "home") state.frontmost = "com.apple.springboard";
    return null;
  }

  const server = Bun.serve({
    port: opts.port ?? 0,
    hostname: "127.0.0.1",
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname.startsWith("/_fake/")) {
        if (url.pathname === "/_fake/state" && req.method === "POST") {
          const b = (await req.json()) as Partial<FakeState>;
          if (b.frontmost !== undefined) state.frontmost = b.frontmost;
          if (b.locked !== undefined) state.locked = b.locked;
        }
        return json(200, state);
      }
      if (req.headers.get("authorization") !== `Bearer ${token}`) return json(401, { error: err("unauthorized", "bad token") });

      if (url.pathname === "/v1/info" && req.method === "GET") {
        return json(200, {
          screen: { width: W, height: H, scale: 2, orientation: "landscape_left" },
          frontmost: state.locked ? null : { bundle_id: state.frontmost, name: nameOf(state.frontmost) },
          locked: state.locked,
          asleep: false,
          daemon_version: "fake-0.1",
          selftest: {
            capture_ok: state.locked ? null : true,
            screen_on: !state.locked,
            detail: state.locked ? "screen is off; capture not verified" : "captured a non-black frame while the screen is on",
          },
        });
      }
      if (url.pathname === "/v1/apps" && req.method === "GET") return json(200, { apps: FAKE_APPS });

      if (url.pathname === "/v1/screenshot" && req.method === "POST") {
        const b = (await req.json().catch(() => ({}))) as any;
        const q = Number.isFinite(b.quality) ? b.quality : 70;
        const r = b.region;
        if (r && !(Number.isFinite(r.x) && Number.isFinite(r.y) && r.w > 0 && r.h > 0)) return json(400, { error: err("invalid", "bad region") });
        const s = encode(q, r);
        return new Response(new Uint8Array(s.data), { headers: shotHeaders(s.w, s.h) });
      }

      if (url.pathname === "/v1/actions" && req.method === "POST") {
        const b = (await req.json().catch(() => null)) as any;
        if (!b || !Array.isArray(b.actions) || b.actions.length === 0) return json(400, { error: err("invalid", "actions must be a non-empty array") });
        const results: ActionResult[] = [];
        let failed = false;
        b.actions.forEach((a: any, index: number) => {
          if (failed) return results.push({ index, status: "skipped" });
          const e = run(a);
          if (e) { failed = true; results.push({ index, status: "failed", error: e }); }
          else results.push({ index, status: "ok" });
        });
        const out: any = { ok: !failed, results, frontmost: state.frontmost };
        if (b.screenshot) {
          const s = encode(Number.isFinite(b.screenshot.quality) ? b.screenshot.quality : 70);
          out.screenshot = {
            jpeg_base64: Buffer.from(s.data).toString("base64"),
            width: s.w, height: s.h, scale: 2, orientation: "landscape_left",
            frontmost: state.frontmost, locked: state.locked,
          };
        }
        return json(200, out);
      }
      return json(404, { error: err("invalid", `no route ${req.method} ${url.pathname}`) });
    },
  });
  return { server, state, url: `http://127.0.0.1:${server.port}`, token, stop: () => server.stop(true) };
}

if (import.meta.main) {
  const d = startFakeDaemon({ port: Number(process.env.PORT ?? 8791), token: process.env.IPADCTL_TOKEN });
  console.log(`fake ipadctld on ${d.url} (token ${d.token}, frontmost ${d.state.frontmost})`);
}
