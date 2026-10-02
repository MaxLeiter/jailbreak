// Wire types for the ipadctld HTTP contract. See ipadctl/API.md.

export type ErrorCode =
  | "locked"
  | "app_mismatch"
  | "target_mismatch"
  | "app_blocked"
  | "invalid"
  | "unauthorized"
  | "internal";

export interface DaemonError {
  code: ErrorCode;
  message: string;
  /** Extra detail, e.g. {expected, actual} for app_mismatch. */
  details?: Record<string, unknown>;
}

export interface Info {
  screen: {
    width: number;
    height: number;
    scale: number;
    orientation: "portrait" | "portrait_upside_down" | "landscape_left" | "landscape_right";
  };
  frontmost: { bundle_id: string; name: string } | null;
  locked: boolean;
  asleep: boolean;
  daemon_version: string;
}

export interface AppInfo {
  bundle_id: string;
  name: string;
}

/** Fields required on every input action so the caller (and the auto-mode classifier) can see intent. */
export interface Intent {
  app: string;
  target: string;
  why: string;
}

export type Direction = "up" | "down" | "left" | "right";

export type Action =
  | ({ type: "tap"; x: number; y: number } & Intent)
  | ({ type: "double_tap"; x: number; y: number } & Intent)
  | ({ type: "long_press"; x: number; y: number; duration_ms?: number } & Intent)
  | ({ type: "swipe"; x: number; y: number; x2: number; y2: number; duration_ms?: number } & Intent)
  | ({ type: "scroll"; x: number; y: number; direction: Direction; amount?: number } & Intent)
  | ({ type: "type"; text: string } & Intent)
  | ({ type: "key"; key: string } & Intent)
  | ({ type: "button"; name: "home" | "volume_up" | "volume_down" } & Intent)
  | ({ type: "open_app"; bundle_id: string } & Intent)
  | ({ type: "open_url"; url: string } & Intent)
  | { type: "wait"; ms: number };

export interface ActionResult {
  index: number;
  status: "ok" | "failed" | "skipped";
  error?: DaemonError;
}

export interface ScreenshotMeta {
  width: number;
  height: number;
  scale: number;
  orientation: Info["screen"]["orientation"];
  frontmost: string;
  locked: boolean;
}

export interface ActionsResponse {
  ok: boolean;
  results: ActionResult[];
  frontmost: string;
  screenshot?: ScreenshotMeta & { jpeg_base64: string };
}

export interface ScreenshotRequest {
  quality?: number;
  region?: { x: number; y: number; w: number; h: number };
}
