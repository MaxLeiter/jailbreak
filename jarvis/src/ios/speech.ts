import { mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { postDarwinNotification } from "./notify";

const REQUEST_PATH = "/var/jb/tmp/jarvis-speech-request.json";
const STATUS_PATH = "/var/jb/tmp/jarvis-speech-status.json";
const NOTIFICATION = "com.max.jarvis.speech.speak";
const VOICES_REQUEST_PATH = "/var/jb/tmp/jarvis-speech-voices-request.json";
const VOICES_STATUS_PATH = "/var/jb/tmp/jarvis-speech-voices-status.json";
const VOICES_NOTIFICATION = "com.max.jarvis.speech.voices";
const SETTINGS_PATH = "/var/jb/var/root/jarvis/speech-settings.json";

export interface SpeakOptions {
  text: string;
  rate?: number;
  voice?: string;
}

export interface SpeechVoice {
  identifier: string;
  name: string;
  language: string;
  quality: number;
}

export interface SpeechSettings {
  voice?: string;
  updatedAt?: number;
}

interface SpeechStatus {
  ok: boolean;
  seq: string;
  started?: boolean;
  spoken?: string;
  error?: string;
}

interface SpeechVoicesStatus {
  ok: boolean;
  seq: string;
  voices?: SpeechVoice[];
  error?: string;
}

export async function speak(opts: SpeakOptions): Promise<{ spoken: string }> {
  if (process.platform !== "darwin") throw new Error("speech is only available on Darwin");
  const text = opts.text.trim();
  if (!text) throw new Error("speech text is empty");
  if (text.length > 500) throw new Error("speech text must be 500 characters or less");

  const settings = await readSpeechSettings();
  const voice = opts.voice ?? settings.voice;
  const seq = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  await writeFile(REQUEST_PATH, JSON.stringify({ seq, text, rate: opts.rate, voice, requestedAt: Date.now() }));
  postDarwinNotification(NOTIFICATION);

  const status = await waitForFinalStatus(seq, speechTimeoutMs(text));
  if (!status.ok) throw new Error(status.error ?? "speech bridge failed");
  return { spoken: status.spoken ?? text };
}

export async function listSpeechVoices(): Promise<{ voices: SpeechVoice[]; current?: string }> {
  if (process.platform !== "darwin") throw new Error("speech voices are only available on Darwin");
  const seq = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  await writeFile(VOICES_REQUEST_PATH, JSON.stringify({ seq, requestedAt: Date.now() }));
  postDarwinNotification(VOICES_NOTIFICATION);

  const status = await waitForVoicesStatus(seq, 5_000);
  if (!status.ok) throw new Error(status.error ?? "speech voice bridge failed");
  const settings = await readSpeechSettings();
  return { voices: status.voices ?? [], current: settings.voice };
}

export async function setDefaultSpeechVoice(voice: string): Promise<SpeechSettings> {
  const available = await listSpeechVoices();
  const found = available.voices.find((v) => v.identifier === voice);
  if (!found) {
    throw new Error(`unknown voice identifier: ${voice}`);
  }
  const settings = { voice, updatedAt: Date.now() };
  await mkdir(dirname(SETTINGS_PATH), { recursive: true });
  await writeFile(SETTINGS_PATH, JSON.stringify(settings, null, 2));
  return settings;
}

export async function clearDefaultSpeechVoice(): Promise<SpeechSettings> {
  try {
    await unlink(SETTINGS_PATH);
  } catch {
    // Already clear.
  }
  return {};
}

export async function readSpeechSettings(): Promise<SpeechSettings> {
  try {
    const parsed = JSON.parse(await readFile(SETTINGS_PATH, "utf8")) as SpeechSettings;
    return typeof parsed.voice === "string" ? { voice: parsed.voice, updatedAt: parsed.updatedAt } : {};
  } catch {
    return {};
  }
}

async function waitForFinalStatus(seq: string, timeoutMs: number): Promise<SpeechStatus> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const raw = await readFile(STATUS_PATH, "utf8");
      const status = JSON.parse(raw) as SpeechStatus;
      if (status.seq === seq && !status.started) return status;
    } catch {
      // Status file may not exist yet or may be mid-atomic-replace.
    }
    await Bun.sleep(100);
  }
  throw new Error("speech bridge timed out; is JarvisScreenshotBridge installed and SpringBoard running?");
}

async function waitForVoicesStatus(seq: string, timeoutMs: number): Promise<SpeechVoicesStatus> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const raw = await readFile(VOICES_STATUS_PATH, "utf8");
      const status = JSON.parse(raw) as SpeechVoicesStatus;
      if (status.seq === seq) return status;
    } catch {
      // Status file may not exist yet or may be mid-atomic-replace.
    }
    await Bun.sleep(100);
  }
  throw new Error("speech voice bridge timed out; is JarvisScreenshotBridge installed and SpringBoard running?");
}

function speechTimeoutMs(text: string): number {
  return Math.min(60_000, Math.max(10_000, text.length * 120));
}
