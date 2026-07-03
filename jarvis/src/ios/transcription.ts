import { readFile } from "node:fs/promises";
import { extname } from "node:path";

export interface Transcription {
  transcript: string;
  final: boolean;
  provider?: string;
}

export interface TranscriptionOptions {
  timeoutMs?: number;
}

interface HelperResponse {
  ok: boolean;
  transcript?: string;
  final?: boolean;
  error?: string;
}

const DEFAULT_HELPER = "/var/jb/var/root/jarvis/JarvisSpeechHelper.app/JarvisSpeechHelper";

export async function transcribeAudio(path: string, locale = "en_US", opts: TranscriptionOptions = {}): Promise<Transcription> {
  const localResult = await transcribeLocal(path, locale, opts.timeoutMs).then(
    (result) => result,
    (error) => error as Error,
  );
  if (!(localResult instanceof Error)) return localResult;

  const token = process.env.AI_GATEWAY_API_KEY || process.env.ANTHROPIC_AUTH_TOKEN;
  const gatewayError = process.env.JARVIS_STT_GATEWAY_FALLBACK === "1" && token
    ? await transcribeGateway(path, token).then(
        (result) => result,
        (error) => error as Error,
      )
    : undefined;
  if (gatewayError && !(gatewayError instanceof Error)) return gatewayError;

  const reasons = [
    `apple-speech: ${localResult.message}`,
    gatewayError instanceof Error ? `ai-gateway: ${gatewayError.message}` : undefined,
  ].filter(Boolean);
  throw new Error(`no transcription provider succeeded (${reasons.join("; ")})`);
}

async function transcribeLocal(path: string, locale: string, timeoutMs = 30_000): Promise<Transcription> {
  const helper = process.env.JARVIS_SPEECH_HELPER || DEFAULT_HELPER;
  const proc = Bun.spawn([helper, "transcribe", path, locale], {
    stdout: "pipe",
    stderr: "pipe",
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill();
  }, Math.max(1_000, timeoutMs));
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]).finally(() => clearTimeout(timer));
  if (timedOut) throw new Error("speech recognition timed out");
  let response: HelperResponse;
  try {
    response = JSON.parse(stdout.trim()) as HelperResponse;
  } catch {
    throw new Error(`speech helper returned invalid JSON (exit ${code}): ${stderr || stdout}`);
  }
  if (!response.ok) throw new Error(response.error ?? `speech helper failed with exit ${code}`);
  return { transcript: response.transcript ?? "", final: !!response.final, provider: "apple-speech" };
}

async function transcribeGateway(path: string, token: string): Promise<Transcription> {
  const audio = await readFile(path);
  const response = await fetch("https://ai-gateway.vercel.sh/v4/ai/transcription-model", {
    method: "POST",
    headers: {
      authorization: `Bearer ${token}`,
      "ai-model-id": process.env.JARVIS_TRANSCRIPTION_MODEL || "openai/whisper-1",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      audio: Buffer.from(audio).toString("base64"),
      mediaType: mediaTypeForPath(path),
    }),
  });
  const result = (await response.json().catch(() => ({}))) as {
    text?: string;
    error?: unknown;
  };
  if (!response.ok) {
    const msg = errorMessage(result.error) ?? `gateway transcription failed: HTTP ${response.status}`;
    throw new Error(msg);
  }
  return { transcript: result.text ?? "", final: true, provider: "ai-gateway" };
}

function errorMessage(error: unknown): string | undefined {
  if (typeof error === "string") return error;
  if (error && typeof error === "object" && "message" in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === "string") return message;
  }
  return undefined;
}

function mediaTypeForPath(path: string): string {
  switch (extname(path).toLowerCase()) {
    case ".mp3":
      return "audio/mpeg";
    case ".wav":
      return "audio/wav";
    case ".aiff":
    case ".aif":
      return "audio/aiff";
    case ".caf":
      return "audio/x-caf";
    case ".m4a":
    default:
      return "audio/mp4";
  }
}
