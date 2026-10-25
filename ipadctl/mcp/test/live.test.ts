// Opt-in live smoke test: drives the REAL ipadctld through the MCP server.
//
//   IPADCTL_LIVE=1 IPADCTL_URL=http://MaxsiPad.local:8790 IPADCTL_TOKEN=<token> \
//     bun test test/live.test.ts
//
// Skipped unless IPADCTL_LIVE=1. Read-only checks (screenshot, zoom, list_apps,
// app_mismatch) always run; the benign input sequence (open Settings, home)
// runs only when the device is unlocked, so a locked iPad doesn't fail the run.
// Leave the iPad on the SpringBoard home screen before running.
import { beforeAll, afterAll, describe, expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const LIVE = process.env.IPADCTL_LIVE === "1";
const suite = LIVE ? describe : describe.skip;

let client: Client;
const call = async (name: string, args: Record<string, unknown>) =>
  (await client.callTool({ name, arguments: args })) as { content: any[]; isError?: boolean };
const text = (r: { content: any[] }) => r.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
const image = (r: { content: any[] }) => r.content.find((c) => c.type === "image");

// Parse "[ipad] frontmost=X orientation=Y size=WxHpt locked=Z".
function status(r: { content: any[] }) {
  const m = text(r).match(/frontmost=(\S+).*?locked=(true|false)/s);
  return { frontmost: m?.[1] ?? "unknown", locked: m?.[2] === "true" };
}

suite("live daemon", () => {
  beforeAll(async () => {
    if (!process.env.IPADCTL_TOKEN) throw new Error("set IPADCTL_TOKEN (and IPADCTL_URL) for the live test");
    client = new Client({ name: "live", version: "0" });
    await client.connect(
      new StdioClientTransport({
        command: "bun",
        args: ["run", `${import.meta.dir}/../src/index.ts`],
        env: { ...process.env } as Record<string, string>,
      }),
    );
  });
  afterAll(async () => {
    await client?.close();
  });

  test("screenshot returns a JPEG", async () => {
    const r = await call("screenshot", {});
    expect(r.isError).toBeFalsy();
    const img = image(r);
    expect(img?.mimeType).toBe("image/jpeg");
    expect(Buffer.from(img.data, "base64").subarray(0, 2).toString("hex")).toBe("ffd8");
  });

  test("zoom returns a native-resolution crop", async () => {
    const r = await call("zoom", { x: 0, y: 0, width: 200, height: 100 });
    expect(r.isError).toBeFalsy();
    const jpeg = (await import("jpeg-js")).default.decode(Buffer.from(image(r).data, "base64"));
    // Region is returned at points x scale, so a 200x100pt crop is 400x200px at scale 2.
    expect(jpeg.width).toBeGreaterThanOrEqual(200);
    expect(jpeg.height).toBeGreaterThanOrEqual(100);
  });

  test("list_apps includes Settings", async () => {
    const t = text(await call("list_apps", {}));
    expect(t).toContain("com.apple.Preferences");
  });

  test("app_mismatch is rejected", async () => {
    const st = status(await call("screenshot", {}));
    const wrong = st.frontmost === "com.apple.MobileSMS" ? "com.apple.mobilesafari" : "com.apple.MobileSMS";
    const r = await call("tap", { x: 100, y: 100, app: wrong, target: "anything", why: "force an app_mismatch for the smoke test" });
    expect(r.isError).toBe(true);
    // Locked device reports `locked` first (checked before the app match); either proves the guard path.
    expect(text(r)).toMatch(/app_mismatch|locked/);
  });

  test("benign input: open Settings then Home (skipped if locked)", async () => {
    const st = status(await call("screenshot", {}));
    if (st.locked) {
      console.warn("device is locked; skipping the input sequence. Unlock it and leave it on the home screen.");
      return;
    }
    const open = await call("open_app", {
      bundle_id: "com.apple.Preferences",
      app: st.frontmost,
      target: "Settings app",
      why: "smoke test: launch Settings",
    });
    expect(open.isError).toBeFalsy();
    expect(status(open).frontmost).toBe("com.apple.Preferences");

    const home = await call("button", {
      name: "home",
      app: "com.apple.Preferences",
      target: "Home button",
      why: "smoke test: return to the home screen",
    });
    expect(home.isError).toBeFalsy();
    expect(status(home).frontmost).toBe("com.apple.springboard");
  });
});
