import type { StaticImageData } from "next/image";

import gimpDesktop from "@/assets/shots/gimp-desktop.jpg";
import gimpNative from "@/assets/shots/gimp-native.jpg";
import gnomeLauncher from "@/assets/shots/gnome-launcher.jpg";
import gnumeric from "@/assets/shots/gnumeric.jpg";
import fuzzel from "@/assets/shots/fuzzel.jpg";
import hitori from "@/assets/shots/hitori.jpg";
import imv from "@/assets/shots/imv.jpg";
import ioscDesktop from "@/assets/shots/iosc-desktop.jpg";
import ioscLauncher from "@/assets/shots/iosc-launcher.jpg";
import kwrite from "@/assets/shots/kwrite.jpg";
import ladybird from "@/assets/shots/ladybird.jpg";
import mpv from "@/assets/shots/mpv.jpg";
import nativeHome from "@/assets/shots/native-home.jpg";
import papers from "@/assets/shots/papers.jpg";
import swayimg from "@/assets/shots/swayimg.jpg";
import thunar from "@/assets/shots/thunar.jpg";
import tofi from "@/assets/shots/tofi.jpg";
import waybar from "@/assets/shots/waybar.jpg";
import yad from "@/assets/shots/yad.jpg";
import zathura from "@/assets/shots/zathura.jpg";

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
  "/shots/gimp-desktop.jpg": gimpDesktop,
  "/shots/gimp-native.jpg": gimpNative,
  "/shots/fuzzel.jpg": fuzzel,
  "/shots/gnome-launcher.jpg": gnomeLauncher,
  "/shots/gnumeric.jpg": gnumeric,
  "/shots/hitori.jpg": hitori,
  "/shots/imv.jpg": imv,
  "/shots/iosc-desktop.jpg": ioscDesktop,
  "/shots/iosc-launcher.jpg": ioscLauncher,
  "/shots/kwrite.jpg": kwrite,
  "/shots/ladybird.jpg": ladybird,
  "/shots/mpv.jpg": mpv,
  "/shots/native-home.jpg": nativeHome,
  "/shots/papers.jpg": papers,
  "/shots/swayimg.jpg": swayimg,
  "/shots/thunar.jpg": thunar,
  "/shots/tofi.jpg": tofi,
  "/shots/waybar.jpg": waybar,
  "/shots/yad.jpg": yad,
  "/shots/zathura.jpg": zathura,
};

/** The clip is referenced by URL, so it stays in public/. */
export const CLIP = {
  width: 720,
  height: 960,
  poster: "/shots/native-switch-poster.jpg",
  webm: "/shots/native-switch.webm",
  mp4: "/shots/native-switch.mp4",
};
