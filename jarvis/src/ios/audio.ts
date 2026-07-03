import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { postDarwinNotification } from "./notify";

const REQUEST_PATH = "/var/jb/tmp/jarvis-audio-record-request.json";
const STATUS_PATH = "/var/jb/tmp/jarvis-audio-record-status.json";
const NOTIFICATION = "com.max.jarvis.audio.record";

export interface RecordAudioOptions {
  duration?: number;
  path?: string;
}

export interface AudioRecording {
  path: string;
  bytes: number;
  duration: number;
}

interface AudioRecordStatus {
  ok: boolean;
  seq: string;
  started?: boolean;
  path?: string;
  bytes?: number;
  duration?: number;
  error?: string;
}

export async function recordAudio(opts: RecordAudioOptions = {}): Promise<AudioRecording> {
  if (process.platform !== "darwin") throw new Error("audio recording is only available on Darwin");
  const duration = Math.min(Math.max(opts.duration ?? 3, 1), 15);
  const path = opts.path ?? defaultOutputPath();
  if (!path.startsWith("/var/jb/tmp/") && !path.startsWith("/tmp/")) {
    throw new Error("audio recording path must be under /var/jb/tmp or /tmp");
  }

  const seq = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  await mkdir(dirname(path), { recursive: true });
  await writeFile(REQUEST_PATH, JSON.stringify({ seq, path, duration, requestedAt: Date.now() }));
  postDarwinNotification(NOTIFICATION);

  const status = await waitForFinalStatus(seq, (duration + 5) * 1000);
  if (!status.ok) throw new Error(status.error ?? "audio recording bridge failed");
  if (!status.path || status.bytes == null || status.duration == null) {
    throw new Error("audio recording bridge returned incomplete status");
  }

  const s = await stat(status.path);
  return { path: status.path, bytes: s.size || status.bytes, duration: status.duration };
}

function defaultOutputPath(): string {
  return `/var/jb/tmp/jarvis-listen-${Date.now()}-${Math.random().toString(16).slice(2)}.m4a`;
}

async function waitForFinalStatus(seq: string, timeoutMs: number): Promise<AudioRecordStatus> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const raw = await readFile(STATUS_PATH, "utf8");
      const status = JSON.parse(raw) as AudioRecordStatus;
      if (status.seq === seq && !status.started) return status;
    } catch {
      // Status file may not exist yet or may be mid-atomic-replace.
    }
    await Bun.sleep(100);
  }
  throw new Error("audio recording bridge timed out; is JarvisScreenshotBridge installed and SpringBoard running?");
}
