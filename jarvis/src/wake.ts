import { unlink } from "node:fs/promises";
import { recordAudio } from "./ios/audio";
import { transcribeAudio } from "./ios/transcription";

export interface WakeState {
  enabled: boolean;
  phrase: string;
  duration: number;
  intervalMs: number;
  cooldownMs: number;
  startedAt?: number;
  lastAt?: number;
  lastTranscript?: string;
  lastCommand?: string;
  lastError?: string;
  lastStatus?: string;
  loops: number;
  commands: number;
}

export interface WakeControllerOptions {
  onState?: (state: WakeState) => void;
  onTranscript?: (transcript: string) => void;
  onCommand: (command: string) => Promise<boolean>;
  onAudit?: (allowed: boolean, scope: string) => void;
}

export class WakeController {
  private abort?: AbortController;
  private stateValue: WakeState = {
    enabled: false,
    phrase: "hey jarvis",
    duration: 3,
    intervalMs: 600,
    cooldownMs: 4_000,
    loops: 0,
    commands: 0,
  };

  constructor(private opts: WakeControllerOptions) {}

  state(): WakeState {
    return { ...this.stateValue };
  }

  start(input: Partial<Pick<WakeState, "phrase" | "duration" | "intervalMs" | "cooldownMs">> = {}) {
    const phrase = input.phrase?.trim() || this.stateValue.phrase;
    this.stateValue = {
      ...this.stateValue,
      enabled: true,
      phrase,
      duration: clamp(input.duration ?? this.stateValue.duration, 1, 8),
      intervalMs: clamp(input.intervalMs ?? this.stateValue.intervalMs, 250, 5_000),
      cooldownMs: clamp(input.cooldownMs ?? this.stateValue.cooldownMs, 1_000, 15_000),
      startedAt: Date.now(),
      lastError: undefined,
      lastStatus: "listening",
    };
    this.opts.onAudit?.(true, `start phrase="${phrase}"`);
    this.emit();

    if (!this.abort) {
      this.abort = new AbortController();
      void this.loop(this.abort.signal);
    }
  }

  stop(reason = "stop") {
    if (!this.stateValue.enabled && !this.abort) return;
    this.stateValue = { ...this.stateValue, enabled: false, lastStatus: "off" };
    this.opts.onAudit?.(true, reason);
    this.abort?.abort();
    this.abort = undefined;
    this.emit();
  }

  private async loop(signal: AbortSignal) {
    let nextListenAt = 0;
    while (!signal.aborted && this.stateValue.enabled) {
      const wait = Math.max(nextListenAt - Date.now(), 0);
      if (wait) await sleep(wait, signal);
      if (signal.aborted || !this.stateValue.enabled) break;

      this.stateValue.loops++;
      this.stateValue.lastAt = Date.now();
      this.stateValue.lastStatus = "recording";
      this.stateValue.lastTranscript = undefined;
      this.emit();

      let path: string | undefined;
      try {
        const recording = await recordAudio({ duration: this.stateValue.duration });
        path = recording.path;
        this.stateValue.lastStatus = "transcribing";
        this.emit();
        const result = await transcribeAudio(recording.path, "en_US", {
          timeoutMs: Math.max(6_000, this.stateValue.duration * 1000 + 4_000),
        });
        const transcript = result.transcript.trim();
        this.stateValue.lastTranscript = transcript;
        this.stateValue.lastError = undefined;
        this.stateValue.lastStatus = transcript ? "heard speech" : "idle";
        if (transcript) this.opts.onTranscript?.(transcript);

        const command = wakeCommand(transcript, this.stateValue.phrase);
        if (command) {
          this.stateValue.commands++;
          this.stateValue.lastCommand = command;
          this.emit();
          const accepted = await this.opts.onCommand(command);
          this.opts.onAudit?.(accepted, `heard "${this.stateValue.phrase}": ${command}`);
          nextListenAt = Date.now() + this.stateValue.cooldownMs;
        } else {
          nextListenAt = Date.now() + this.stateValue.intervalMs;
        }
      } catch (error) {
        const message = (error as Error).message;
        if (isNoSpeech(message)) {
          this.stateValue.lastError = undefined;
          this.stateValue.lastStatus = "idle";
        } else {
          this.stateValue.lastError = message;
          this.stateValue.lastStatus = "error";
        }
        nextListenAt = Date.now() + Math.max(this.stateValue.intervalMs, 1_500);
      } finally {
        if (path) unlink(path).catch(() => undefined);
        this.emit();
      }
    }
    if (this.abort?.signal === signal) this.abort = undefined;
  }

  private emit() {
    this.opts.onState?.(this.state());
  }
}

export function wakeCommand(transcript: string, phrase: string): string | null {
  const haystack = normalize(transcript);
  const needle = normalize(phrase);
  if (!haystack || !needle) return null;

  const idx = ` ${haystack} `.indexOf(` ${needle} `);
  if (idx < 0) return null;

  const after = haystack.slice(idx + needle.length).trim();
  return after || null;
}

function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function clamp(value: number, min: number, max: number): number {
  const n = Number.isFinite(value) ? value : min;
  return Math.min(max, Math.max(min, n));
}

function isNoSpeech(message: string): boolean {
  const lower = message.toLowerCase();
  return lower.includes("no speech detected") || lower.includes("speech recognition timed out");
}

function sleep(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });
}
