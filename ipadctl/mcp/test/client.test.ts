import { afterAll, describe, expect, test } from "bun:test";
import { DaemonClient, DaemonRequestError, estimateActionsMs } from "../src/client.ts";
import type { Action } from "../src/types.ts";

const intent = { app: "com.apple.MobileSMS", target: "message field", why: "test" };

// A daemon that takes `delay` ms to answer /v1/actions, like the real one does while it
// executes a long batch.
let delay = 0;
const slow = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch() {
    await Bun.sleep(delay);
    return Response.json({ ok: true, results: [{ index: 0, status: "ok" }], frontmost: intent.app });
  },
});
afterAll(() => slow.stop(true));
const url = `http://127.0.0.1:${slow.port}`;

describe("actions timeout", () => {
  test("estimate grows with the work in the batch", () => {
    const tap: Action = { type: "tap", x: 1, y: 1, ...intent };
    const text: Action = { type: "type", text: "x".repeat(4000), ...intent };
    expect(estimateActionsMs([tap], false)).toBeLessThan(1_000);
    expect(estimateActionsMs([text], false)).toBeGreaterThan(200_000);
    expect(estimateActionsMs([{ type: "wait", ms: 10_000 }], true)).toBeGreaterThan(10_000);
    // Clamped like the daemon clamps.
    expect(estimateActionsMs([{ type: "long_press", x: 1, y: 1, duration_ms: 1e9, ...intent }], false)).toBeLessThan(11_000);
  });

  test("a batch that legitimately outlasts the base timeout still gets its answer", async () => {
    delay = 900;
    const client = new DaemonClient(url, "t", 300);
    const r = await client.actions([{ type: "wait", ms: 1_000 }], false);
    expect(r.ok).toBe(true);
  });

  test("a real timeout on actions warns that they may have run", async () => {
    delay = 1_500;
    const client = new DaemonClient(url, "t", 200);
    const err = await client.actions([{ type: "tap", x: 1, y: 1, ...intent }], false).catch((e) => e);
    expect(err).toBeInstanceOf(DaemonRequestError);
    expect(err.code).toBe("unreachable");
    expect(err.message).toContain("may have run");
  });
});

describe("fromEnv", () => {
  test("an empty IPADCTL_URL falls back to the default", () => {
    expect(DaemonClient.fromEnv({ IPADCTL_URL: "", IPADCTL_TOKEN: "t" }).baseUrl).toBe("http://MaxsiPad.local:8790");
  });
});
