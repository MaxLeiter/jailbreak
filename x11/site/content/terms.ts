/**
 * One definition per term, used everywhere the term appears.
 *
 * Pages render these through <T k="..."/> (components/Term.tsx) so a term is
 * glossed identically on every page and only has to be corrected in one place.
 */

export type Term = {
  /** Default visible text. Pass children to <T> to override it. */
  label: string;
  /** The gloss, shown on hover and to screen readers. Keep it one clause. */
  def: string;
};

export const TERMS = {
  // --- iOS and Apple ---
  iosurface: {
    label: "IOSurface",
    def: "an Apple shared graphics buffer that several processes and the GPU can use at once",
  },
  machPort: {
    label: "mach port",
    def: "an iOS kernel channel for handing a resource from one process to another",
  },
  metal: {
    label: "Metal",
    def: "Apple's low-level graphics API, the only route to the GPU on iOS",
  },
  camelayer: {
    label: "CAMetalLayer",
    def: "the UIKit layer that presents Metal-drawn frames on screen",
  },
  entitlement: {
    label: "entitlement",
    def: "a signed capability on an iOS binary; without the GPU one, Metal refuses to start",
  },
  ldid: {
    label: "ldid",
    def: "the tool that ad-hoc signs a Mach-O and attaches its entitlements",
  },
  fakesign: {
    label: "fakesigned",
    def: "ad-hoc signed instead of signed by Apple, which a jailbroken kernel accepts",
  },
  rootless: {
    label: "rootless",
    def: "a jailbreak layout where everything installs under /var/jb instead of /",
  },
  rootful: {
    label: "rootful",
    def: "the older jailbreak layout that writes directly into the system root",
  },

  // --- graphics ---
  angle: {
    label: "ANGLE",
    def: "Google's OpenGL ES implementation, here translating GLES calls into Metal",
  },
  gles: {
    label: "GLES",
    def: "OpenGL ES, the embedded profile of OpenGL that ANGLE implements",
  },
  egl: {
    label: "EGL",
    def: "the API that binds OpenGL ES to a window system and hands out drawing surfaces",
  },
  waylandEgl: {
    label: "wayland-egl",
    def: "the small library that hands a Wayland app a GPU surface to draw into",
  },
  pbuffer: {
    label: "pbuffer",
    def: "an off-screen EGL drawing surface, here backed by an IOSurface",
  },
  drmKms: {
    label: "DRM/KMS",
    def: "the Linux kernel interfaces a desktop normally uses to own a display; iOS has neither",
  },
  glx: {
    label: "GLX",
    def: "the X11 extension that gives X apps OpenGL",
  },
  dri: {
    label: "DRI",
    def: "Direct Rendering Infrastructure, X11's path to direct GPU access",
  },
  glamor: {
    label: "glamor",
    def: "the X server's OpenGL-based 2D acceleration",
  },
  llvmpipe: {
    label: "llvmpipe",
    def: "Mesa's software renderer: OpenGL on the CPU",
  },
  wlShm: {
    label: "wl_shm",
    def: "the Wayland buffer type backed by shared CPU memory rather than the GPU",
  },
  zeroCopy: {
    label: "zero-copy",
    def: "handing a buffer along by reference, with no pixel ever copied through the CPU",
  },

  // --- the project's own pieces ---
  iosc: {
    label: "iosc",
    def: "this project's clean-room Wayland compositor, which composites into the output IOSurface",
  },
  ioscd: {
    label: "ioscd",
    def: "the root daemon that starts, switches and supervises desktop sessions",
  },
  xiosSession: {
    label: "xios-session",
    def: "the command that launches a desktop flavor and tears the previous one down",
  },
  xiosDevice: {
    label: "xios-device",
    def: "the host-side harness that drives the iPad over SSH and collects evidence",
  },
  displaySlot: {
    label: "display slot",
    def: "a named desktop with its own Wayland socket, config and status file",
  },
  iosurfaceProtocol: {
    label: "iosc_iosurface",
    def: "the private Wayland protocol that passes IOSurfaces between clients and the compositor",
  },

  // --- Linux desktop ---
  wayland: {
    label: "Wayland",
    def: "the modern Linux display protocol, where one compositor owns the screen",
  },
  compositor: {
    label: "compositor",
    def: "the program that owns the screen and blends every window into one image",
  },
  textInput: {
    label: "text-input-v3",
    def: "the Wayland protocol an app uses to ask for an on-screen keyboard",
  },
  atspi: {
    label: "AT-SPI",
    def: "the Linux accessibility bus that exposes an app's widgets to screen readers",
  },
  dbus: {
    label: "D-Bus",
    def: "the message bus Linux desktop services use to talk to each other",
  },
  sysfs: {
    label: "sysfs",
    def: "the Linux kernel's file-shaped view of hardware, faked here by a bridge daemon",
  },
  logind: {
    label: "logind",
    def: "the systemd service a desktop asks about sessions, seats and power",
  },
  gjs: {
    label: "gjs",
    def: "GNOME's JavaScript engine; GNOME Shell is written in it",
  },
  typelib: {
    label: "typelib",
    def: "the binary description that lets a scripting language call a C library",
  },
  kf6: {
    label: "KF6",
    def: "KDE Frameworks 6, the library layer under Plasma and the KDE apps",
  },
  kcm: {
    label: "KCM",
    def: "a KDE Configuration Module, one page inside System Settings",
  },

  // --- build and packaging ---
  procursus: {
    label: "Procursus",
    def: "the macOS-hosted bootstrap and cross-compile system this build stands on",
  },
  quilt: {
    label: "quilt",
    def: "a tool for keeping a stack of source-code patches",
  },
  deb: {
    label: "deb",
    def: "a Debian package, the format every jailbreak package manager installs",
  },
  sileo: {
    label: "Sileo",
    def: "the package manager most rootless jailbreaks ship",
  },
  shadowing: {
    label: "shadowing",
    def: "publishing a package that replaces one the bootstrap already provides",
  },
  minos: {
    label: "MinimumOSVersion",
    def: "the iOS floor stamped into a binary, which the store uses to hide it from older devices",
  },
  jit: {
    label: "JIT",
    def: "just-in-time compilation: generating machine code at runtime, which iOS makes hard",
  },
} as const satisfies Record<string, Term>;

export type TermKey = keyof typeof TERMS;
