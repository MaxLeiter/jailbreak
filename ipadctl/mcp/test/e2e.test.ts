import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { startFakeDaemon } from "../fake-daemon/server.ts";

const daemon = startFakeDaemon();
let client: Client;

const call = async (name: string, args: Record<string, unknown>) =>
  (await client.callTool({ name, arguments: args })) as { content: any[]; isError?: boolean };
const text = (r: { content: any[] }) => r.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
const intent = { app: "com.apple.MobileSMS", target: "Send button in thread with Alex", why: "user asked me to reply" };

beforeAll(async () => {
  client = new Client({ name: "test", version: "0" });
  await client.connect(
    new StdioClientTransport({
      command: "bun",
      args: ["run", `${import.meta.dir}/../src/index.ts`],
      env: { ...process.env, IPADCTL_URL: daemon.url, IPADCTL_TOKEN: daemon.token } as Record<string, string>,
    }),
  );
});
afterAll(async () => {
  await client.close();
  daemon.stop();
});

describe("tool surface", () => {
  test("lists tools with annotations and required intent fields", async () => {
    const { tools } = await client.listTools();
    const by = Object.fromEntries(tools.map((t) => [t.name, t]));
    expect(Object.keys(by).sort()).toEqual(
      ["batch", "button", "double_tap", "key", "list_apps", "long_press", "open_app", "open_url", "screenshot", "scroll", "swipe", "tap", "type", "zoom"],
    );
    for (const n of ["screenshot", "zoom", "list_apps"]) expect(by[n]!.annotations?.readOnlyHint).toBe(true);
    for (const n of ["tap", "double_tap", "long_press", "swipe", "scroll", "type", "key", "button", "open_app", "open_url", "batch"]) {
      expect(by[n]!.annotations?.readOnlyHint).toBe(false);
      expect(by[n]!.annotations?.openWorldHint).toBe(true);
    }
    for (const n of ["tap", "double_tap", "long_press", "swipe", "scroll", "type", "key", "button", "open_app", "open_url"]) {
      const req = (by[n]!.inputSchema as any).required as string[];
      for (const f of ["app", "target", "why"]) expect(req).toContain(f);
    }
    const item = (by.batch!.inputSchema as any).properties.actions.items;
    for (const v of item.oneOf ?? item.anyOf) {
      if (v.properties.type.const === "wait") continue;
      for (const f of ["app", "target", "why"]) expect(v.required).toContain(f);
    }
  });
});

describe("read-only tools", () => {
  test("screenshot returns a JPEG image and a status line", async () => {
    const r = await call("screenshot", {});
    const img = r.content.find((c) => c.type === "image");
    expect(img.mimeType).toBe("image/jpeg");
    expect(Buffer.from(img.data, "base64").subarray(0, 2).toString("hex")).toBe("ffd8");
    expect(text(r)).toContain("frontmost=com.apple.MobileSMS orientation=landscape size=1080x810pt");
  });
  test("zoom crops", async () => {
    const r = await call("zoom", { x: 100, y: 100, width: 200, height: 100 });
    const img = r.content.find((c) => c.type === "image");
    const jpeg = (await import("jpeg-js")).default.decode(Buffer.from(img.data, "base64"));
    expect([jpeg.width, jpeg.height]).toEqual([200, 100]);
  });
  test("list_apps", async () => {
    expect(text(await call("list_apps", {}))).toContain("com.apple.MobileSMS\tMessages");
  });
});

describe("actions", () => {
  test("tap records and returns a screenshot by default", async () => {
    daemon.state.recorded.length = 0;
    const r = await call("tap", { x: 540, y: 405, ...intent });
    expect(r.isError).toBeFalsy();
    expect(r.content.some((c) => c.type === "image")).toBe(true);
    expect(daemon.state.recorded[0]).toMatchObject({ type: "tap", x: 540, y: 405, target: intent.target, why: intent.why });
  });
  test("screenshot_after=false omits image", async () => {
    const r = await call("tap", { x: 1, y: 1, ...intent, screenshot_after: false });
    expect(r.content.some((c) => c.type === "image")).toBe(false);
  });
  test("missing intent fields are rejected before reaching the daemon", async () => {
    daemon.state.recorded.length = 0;
    const r = await call("tap", { x: 5, y: 5, app: "Messages" }).catch((e) => ({ isError: true, content: [{ type: "text", text: String(e) }] }));
    expect(r.isError).toBe(true);
    expect(daemon.state.recorded.length).toBe(0);
  });
  test("app_mismatch surfaces as an error", async () => {
    const r = await call("tap", { x: 5, y: 5, ...intent, app: "com.apple.mobilesafari" });
    expect(r.isError).toBe(true);
    expect(text(r)).toContain("app_mismatch");
  });
  test("accepts app by display name", async () => {
    expect((await call("tap", { x: 5, y: 5, ...intent, app: "Messages" })).isError).toBeFalsy();
  });
  test("app_blocked and locked", async () => {
    daemon.state.frontmost = "com.apple.Preferences";
    expect(text(await call("tap", { x: 5, y: 5, ...intent, app: "Settings" }))).toContain("app_blocked");
    daemon.state.frontmost = "com.apple.MobileSMS";
    daemon.state.locked = true;
    expect(text(await call("tap", { x: 5, y: 5, ...intent }))).toContain("locked");
    daemon.state.locked = false;
  });
  test("batch stops at first failure", async () => {
    daemon.state.recorded.length = 0;
    const r = await call("batch", {
      actions: [
        { type: "tap", x: 10, y: 10, ...intent },
        { type: "open_app", bundle_id: "com.apple.mobilesafari", ...intent, app: "com.apple.mobilesafari" },
        { type: "tap", x: 20, y: 20, ...intent },
      ],
    });
    expect(r.isError).toBe(true);
    const t = text(r);
    expect(t).toContain("1. ok");
    expect(t).toContain("2. FAILED [app_mismatch]");
    expect(t).toContain("3. skipped");
    expect(daemon.state.recorded.length).toBe(1);
  });
  test("open_app then home", async () => {
    await call("open_app", { bundle_id: "com.apple.mobilesafari", ...intent, target: "Safari app" });
    expect(daemon.state.frontmost).toBe("com.apple.mobilesafari");
    await call("button", { name: "home", ...intent, app: "Safari", target: "Home button" });
    expect(daemon.state.frontmost).toBe("com.apple.springboard");
    daemon.state.frontmost = "com.apple.MobileSMS";
  });
});

describe("daemon unreachable", () => {
  test("gives a clear error", async () => {
    const c = new Client({ name: "t", version: "0" });
    await c.connect(
      new StdioClientTransport({
        command: "bun",
        args: ["run", `${import.meta.dir}/../src/index.ts`],
        env: { ...process.env, IPADCTL_URL: "http://127.0.0.1:1", IPADCTL_TOKEN: "x" } as Record<string, string>,
      }),
    );
    const r = (await c.callTool({ name: "screenshot", arguments: {} })) as any;
    await c.close();
    expect(r.isError).toBe(true);
    expect(r.content[0].text).toContain("Cannot reach ipadctld");
  });
});
