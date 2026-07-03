import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { postDarwinNotification } from "./notify";

const REQUEST_PATH = "/var/jb/tmp/jarvis-screenshot-request.json";
const STATUS_PATH = "/var/jb/tmp/jarvis-screenshot-status.json";
const NOTIFICATION = "com.max.jarvis.screenshot.capture";

export interface ScreenshotResult {
  path: string;
  width: number;
  height: number;
  bytes: number;
}

interface BridgeStatus {
  ok: boolean;
  seq: string;
  path?: string;
  width?: number;
  height?: number;
  bytes?: number;
  error?: string;
}

export async function captureScreenshot(path = defaultOutputPath()): Promise<ScreenshotResult> {
  if (process.platform !== "darwin") throw new Error("screenshots are only available on Darwin");
  if (!path.startsWith("/var/jb/tmp/") && !path.startsWith("/tmp/")) {
    throw new Error("screenshot path must be under /var/jb/tmp or /tmp");
  }

  const seq = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  await mkdir(dirname(path), { recursive: true });
  await writeFile(REQUEST_PATH, JSON.stringify({ seq, path, requestedAt: Date.now() }));
  postDarwinNotification(NOTIFICATION);

  const status = await waitForStatus(seq);
  if (!status.ok) throw new Error(status.error ?? "screenshot bridge failed");
  if (!status.path || !status.width || !status.height || !status.bytes) {
    throw new Error("screenshot bridge returned incomplete status");
  }

  const s = await stat(status.path);
  return { path: status.path, width: status.width, height: status.height, bytes: s.size || status.bytes };
}

function defaultOutputPath(): string {
  return `/var/jb/tmp/jarvis-screenshot-${Date.now()}-${Math.random().toString(16).slice(2)}.png`;
}

async function waitForStatus(seq: string): Promise<BridgeStatus> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      const raw = await readFile(STATUS_PATH, "utf8");
      const status = JSON.parse(raw) as BridgeStatus;
      if (status.seq === seq) return status;
    } catch {
      // Status file may not exist yet or may be mid-atomic-replace.
    }
    await Bun.sleep(100);
  }
  throw new Error("screenshot bridge timed out; is JarvisScreenshotBridge installed and SpringBoard running?");
}
