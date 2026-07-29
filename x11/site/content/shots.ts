import type { StaticImageData } from "next/image";

import gnomeLauncher from "@/assets/shots/gnome-launcher.jpg";
import ioscDesktop from "@/assets/shots/iosc-desktop.jpg";
import ioscLauncher from "@/assets/shots/iosc-launcher.jpg";
import nativeHome from "@/assets/shots/native-home.jpg";

/**
 * Stills live in assets/, not public/, so only the hashed+optimized copies
 * ship. Static imports give <Shot> intrinsic width/height (no layout shift)
 * and let next/image emit AVIF/WebP at the size actually rendered. Pages keep
 * passing plain "/shots/x.jpg" keys.
 *
 * assets/shots/opencode-kgx.jpg is on hand but unused; add it here when a page
 * wants it.
 */
export const SHOTS: Record<string, StaticImageData> = {
  "/shots/gnome-launcher.jpg": gnomeLauncher,
  "/shots/iosc-desktop.jpg": ioscDesktop,
  "/shots/iosc-launcher.jpg": ioscLauncher,
  "/shots/native-home.jpg": nativeHome,
};

/** The clip is referenced by URL, so it stays in public/. */
export const CLIP = {
  width: 720,
  height: 960,
  poster: "/shots/native-switch-poster.jpg",
  webm: "/shots/native-switch.webm",
  mp4: "/shots/native-switch.mp4",
};
