export type Track = "X11" | "Wayland" | "Both" | "App" | "Build" | "iOS";
export type State = "live" | "wip" | "planned";

export type Component = {
  name: string;
  role: string;
  track: Track;
  state: State;
};

export const COMPONENTS: Component[] = [
  { name: "Xios.app", role: "The desktop host app (shown as X11). Metal present, UIKit input, IOSurface adopt", track: "App", state: "live" },
  { name: "IOSCHost", role: "The native-mode host app (com.max.iosc.host), one iOS window per Linux app window", track: "App", state: "wip" },
  { name: "Xios", role: "X11 server (Xvfb-derived DDX), draws into IOSurface", track: "X11", state: "live" },
  { name: "iosc", role: "Clean-room Wayland compositor, GPU compositing", track: "Wayland", state: "live" },
  { name: "iosc desktop", role: "The project's own tablet-first shell: panel, dock, overview", track: "Wayland", state: "live" },
  { name: "ANGLE", role: "OpenGL ES translated to Metal, renders into IOSurfaces", track: "Wayland", state: "live" },
  { name: "GTK4", role: "Multi-backend toolkit; same binary on X11 or Wayland", track: "Both", state: "live" },
  { name: "GNOME Console", role: "Terminal app with a live shell", track: "Wayland", state: "live" },
  { name: "gnome-calculator", role: "Vala GNOME app, packaged", track: "Wayland", state: "live" },
  { name: "foot, imv, mpv", role: "Wayland app wave cross-built; mpv does audio and VideoToolbox", track: "Wayland", state: "live" },
  { name: "Qt6 modules", role: "Six-module ladder + Wayland platform plugin", track: "Wayland", state: "live" },
  { name: "Mutter / MetaBackendIOS", role: "GNOME Shell's compositor with a new iOS backend", track: "Wayland", state: "wip" },
  { name: "GNOME Shell 46", role: "Full shell boots and paints on device (first light); packaging remains", track: "Wayland", state: "wip" },
  { name: "GTK4 typelibs", role: "On-device introspection, scanned for the shell", track: "Build", state: "live" },
  { name: "KF6 / Plasma", role: "Qt6 ladder, KF6, and KWin built; Plasma bring-up next", track: "Wayland", state: "wip" },
  { name: "Native mode", role: "Each Linux app window as its own iOS window; runtime switch in the compositor, host in validation", track: "iOS", state: "wip" },
];

export const VALIDATED = [
  "Native X11 server running apps, displayed through Metal",
  "GPU Wayland compositor: zero-copy IOSurface compositing with multi-window stacking",
  "Multi-backend GTK4 on both X11 and Wayland, published to the repo",
  "GNOME Console with a live shell, running through iosc",
  "Interactive touch and keyboard: tap and type into the terminal",
  "GTK4 rendering on the A10 GPU through the ANGLE-to-Metal context",
  "GNOME Shell 46 reaching first light on the A10: it boots, paints, and runs",
];
