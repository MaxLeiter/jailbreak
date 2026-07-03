import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { dirname } from "node:path";
import type { Mode } from "./harness";
import { normalizeMcpConfig, type McpConfig } from "./mcp";

const SETTINGS_PATH = process.env.JARVIS_SETTINGS || "/var/jb/var/root/jarvis/settings.json";
const IOS_PREFS_PATH = process.env.JARVIS_IOS_PREFS || "/var/mobile/Library/Preferences/com.max.jarvis.plist";

export interface IosPreferences {
  enabled: boolean;
  quietEnabled: boolean;
  quietStart: string;
  quietEnd: string;
  speechPolicy?: Mode;
  microphonePolicy?: Mode;
  execPolicy?: Mode;
}

export interface JarvisSettings {
  model?: string;
  policy?: Record<string, Mode>;
  mcp?: McpConfig;
}

export function loadSettings(): JarvisSettings {
  try {
    if (!existsSync(SETTINGS_PATH)) return {};
    const parsed = JSON.parse(readFileSync(SETTINGS_PATH, "utf8")) as JarvisSettings;
    return {
      ...(typeof parsed.model === "string" ? { model: parsed.model } : {}),
      ...(parsed.policy && typeof parsed.policy === "object" ? { policy: cleanPolicy(parsed.policy) } : {}),
      mcp: normalizeMcpConfig(parsed.mcp),
    };
  } catch {
    return {};
  }
}

export function saveSettings(settings: JarvisSettings): JarvisSettings {
  mkdirSync(dirname(SETTINGS_PATH), { recursive: true });
  writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2));
  return settings;
}

export function loadIosPreferences(): IosPreferences {
  const fallback: IosPreferences = {
    enabled: true,
    quietEnabled: false,
    quietStart: "23:00",
    quietEnd: "07:00",
  };
  if (!existsSync(IOS_PREFS_PATH)) return fallback;

  const result = spawnSync(
    "/var/jb/usr/bin/python3",
    [
      "-c",
      [
        "import json, plistlib, sys",
        "path = sys.argv[1]",
        "try:",
        "  data = plistlib.load(open(path, 'rb'))",
        "except Exception:",
        "  data = {}",
        "print(json.dumps(data))",
      ].join("\n"),
      IOS_PREFS_PATH,
    ],
    { encoding: "utf8" },
  );
  if (result.status !== 0 || !result.stdout.trim()) return fallback;

  try {
    const parsed = JSON.parse(result.stdout) as Record<string, unknown>;
    return {
      enabled: boolPref(parsed.enabled, fallback.enabled),
      quietEnabled: boolPref(parsed.quietEnabled, fallback.quietEnabled),
      quietStart: stringPref(parsed.quietStart, fallback.quietStart),
      quietEnd: stringPref(parsed.quietEnd, fallback.quietEnd),
      speechPolicy: modePref(parsed.speechPolicy),
      microphonePolicy: modePref(parsed.microphonePolicy),
      execPolicy: modePref(parsed.execPolicy),
    };
  } catch {
    return fallback;
  }
}

export function applyIosPolicyOverrides(policy: Record<string, Mode>): Record<string, Mode> {
  const prefs = loadIosPreferences();
  return {
    ...policy,
    ...(prefs.speechPolicy ? { "act.speech": prefs.speechPolicy } : {}),
    ...(prefs.microphonePolicy ? { "sense.microphone": prefs.microphonePolicy } : {}),
    ...(prefs.execPolicy ? { exec: prefs.execPolicy } : {}),
  };
}

function cleanPolicy(policy: Record<string, unknown>): Record<string, Mode> {
  const clean: Record<string, Mode> = {};
  for (const [capability, mode] of Object.entries(policy)) {
    if (mode === "allow" || mode === "ask" || mode === "deny") clean[capability] = mode;
  }
  return clean;
}

function boolPref(value: unknown, fallback: boolean): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return !["0", "false", "no", "off"].includes(value.toLowerCase());
  if (typeof value === "number") return value !== 0;
  return fallback;
}

function stringPref(value: unknown, fallback: string): string {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function modePref(value: unknown): Mode | undefined {
  return value === "allow" || value === "ask" || value === "deny" ? value : undefined;
}
