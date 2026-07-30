export type AppScreenshot = {
  src: string;
  url: string;
  alt: string;
  caption: string;
};

export type XiosApp = {
  slug: string;
  name: string;
  shortName: string;
  category: string;
  developer: string;
  description: string;
  summary: string;
  packages: string[];
  modes: string[];
  features: string[];
  screenshots: AppScreenshot[];
  projectUrl: string;
  kind: "app" | "desktop-tool";
};

type CatalogEntry = Pick<
  XiosApp,
  "slug" | "shortName" | "category" | "developer" | "summary" | "projectUrl"
> &
  Partial<
    Pick<
      XiosApp,
      | "name"
      | "description"
      | "packages"
      | "modes"
      | "features"
      | "screenshots"
      | "kind"
    >
  >;

function catalogEntry(entry: CatalogEntry): XiosApp {
  return {
    ...entry,
    name: entry.name ?? `${entry.shortName} for iOS`,
    description:
      entry.description ??
      `Run ${entry.shortName} locally on a jailbroken iPad with xiOS. This is a native arm64 iOS package for the full desktop application, not a remote session or web wrapper.`,
    packages: entry.packages ?? [entry.slug],
    modes: entry.modes ?? ["xiOS desktop window"],
    features: entry.features ?? [
      `${entry.shortName}'s desktop interface and normal application workflow`,
      "Runs locally through Wayland and Metal on the iPad",
      "Touch, pointer, and hardware-keyboard input through xiOS",
    ],
    screenshots: entry.screenshots ?? [],
    kind: entry.kind ?? "app",
  };
}

/**
 * Complete catalog of launchable user-facing packages in the current xiOS
 * repository. Companion packages and backends are grouped with their parent
 * application; daemons and shell utilities are identified as desktop tools.
 */
export const APPS: XiosApp[] = [
  catalogEntry({
    slug: "ark",
    shortName: "Ark",
    category: "Archive manager",
    developer: "KDE",
    summary:
      "KDE's archive manager for opening, inspecting, creating, and extracting common compressed-file formats.",
    projectUrl: "https://apps.kde.org/ark/",
  }),
  catalogEntry({
    slug: "baobab",
    shortName: "Disk Usage Analyzer",
    category: "Storage utility",
    developer: "The GNOME Project",
    summary:
      "GNOME's visual disk-usage analyzer for finding which folders and files occupy space on the iPad filesystem.",
    projectUrl: "https://apps.gnome.org/DiskUsageAnalyzer/",
  }),
  catalogEntry({
    slug: "d-spy",
    shortName: "D-Spy",
    category: "Developer tool",
    developer: "The GNOME Project",
    summary:
      "A GTK4 D-Bus explorer for inspecting services, objects, interfaces, methods, signals, and properties.",
    projectUrl: "https://apps.gnome.org/Dspy/",
  }),
  catalogEntry({
    slug: "dolphin",
    shortName: "Dolphin",
    category: "File manager",
    developer: "KDE",
    summary:
      "KDE's full desktop file manager with tabs, split views, previews, places, and standard file operations.",
    projectUrl: "https://apps.kde.org/dolphin/",
  }),
  catalogEntry({
    slug: "file-roller",
    shortName: "File Roller",
    category: "Archive manager",
    developer: "The GNOME Project",
    summary:
      "GNOME's GTK4 archive manager for browsing, creating, and extracting compressed archives.",
    projectUrl: "https://apps.gnome.org/FileRoller/",
  }),
  catalogEntry({
    slug: "foot",
    shortName: "foot",
    category: "Terminal",
    developer: "Daniel Eklöf",
    summary:
      "A fast, lightweight Wayland terminal emulator for shells, command-line programs, and development workflows.",
    projectUrl: "https://codeberg.org/dnkl/foot",
  }),
  catalogEntry({
    slug: "fuzzel",
    shortName: "Fuzzel",
    category: "App launcher",
    developer: "Daniel Eklöf",
    summary:
      "A compact Wayland application launcher and dmenu replacement for quickly finding and starting installed apps.",
    projectUrl: "https://codeberg.org/dnkl/fuzzel",
    screenshots: [
      {
        src: "/shots/fuzzel.jpg",
        url: "https://repo.maxleiter.com/screenshots/fuzzel/01-fuzzel.jpg",
        alt: "Fuzzel application launcher open in a xiOS desktop session on a jailbroken iPad.",
        caption: "Fuzzel launching apps in xiOS",
      },
    ],
  }),
  catalogEntry({
    slug: "geary",
    shortName: "Geary",
    category: "Email",
    developer: "The GNOME Project",
    summary:
      "GNOME's conversation-based desktop email client, rebuilt for the xiOS GNOME environment.",
    projectUrl: "https://gitlab.gnome.org/GNOME/geary",
  }),
  catalogEntry({
    slug: "gimp",
    name: "GIMP 3.2 for iOS",
    shortName: "GIMP",
    category: "Image editor",
    developer: "The GIMP team",
    description:
      "Run the full desktop GIMP 3.2 image editor locally on a jailbroken iPad with xiOS. This is a native arm64 iOS build, not a remote desktop or web wrapper.",
    summary:
      "The full GTK3 image editor, rebuilt for arm64 iOS with brushes, filters, plug-ins, color tools, layers, and its normal desktop interface.",
    packages: ["gimp", "gimp-native"],
    modes: ["xiOS desktop window", "Native iPadOS host window"],
    features: [
      "GIMP 3.2 with the normal desktop toolbox, docks, layers, and filters",
      "Local execution on the iPad through GTK3, Wayland, and Metal",
      "Touch, pointer, and hardware-keyboard input through xiOS",
      "Optional Home Screen launcher and native iPadOS host window",
    ],
    screenshots: [
      {
        src: "/shots/gimp-desktop.jpg",
        url: "https://repo.maxleiter.com/screenshots/gimp/01-gimp-desktop.jpg",
        alt: "GIMP 3.2.4 running in the xiOS desktop on a jailbroken iPad, showing the welcome screen, toolbox, brushes, and layers dock.",
        caption: "GIMP 3.2.4 in a xiOS desktop session",
      },
      {
        src: "/shots/gimp-native.jpg",
        url: "https://repo.maxleiter.com/screenshots/gimp/02-gimp-painting.jpg",
        alt: "GIMP running locally on a jailbroken iPad with a drawing open, surrounded by the standard toolbox, brushes, and layers panels.",
        caption: "Painting in GIMP on the iPad",
      },
    ],
    projectUrl: "https://www.gimp.org",
  }),
  catalogEntry({
    slug: "gnome-calculator",
    shortName: "GNOME Calculator",
    category: "Calculator",
    developer: "The GNOME Project",
    summary:
      "GNOME's GTK4 calculator with basic, advanced, financial, and programming modes.",
    projectUrl: "https://apps.gnome.org/Calculator/",
  }),
  catalogEntry({
    slug: "gnome-console",
    shortName: "GNOME Console",
    category: "Terminal",
    developer: "The GNOME Project",
    summary:
      "A streamlined GTK4 terminal for interactive shells, command-line tools, and development on the iPad.",
    projectUrl: "https://gitlab.gnome.org/GNOME/console",
  }),
  catalogEntry({
    slug: "gnome-font-viewer",
    shortName: "GNOME Fonts",
    category: "Font viewer",
    developer: "The GNOME Project",
    summary:
      "GNOME's font browser and previewer for inspecting the typefaces installed in the xiOS environment.",
    projectUrl: "https://apps.gnome.org/Fonts/",
  }),
  catalogEntry({
    slug: "gnome-text-editor",
    shortName: "GNOME Text Editor",
    category: "Text editor",
    developer: "The GNOME Project",
    summary:
      "GNOME's modern GTK4 text editor with tabs, search, syntax highlighting, and document preferences.",
    projectUrl: "https://gitlab.gnome.org/GNOME/gnome-text-editor",
  }),
  catalogEntry({
    slug: "gnumeric",
    shortName: "Gnumeric",
    category: "Spreadsheet",
    developer: "The GNOME Project",
    description:
      "Run the desktop Gnumeric spreadsheet locally on a jailbroken iPad with xiOS, rebuilt as a native arm64 iOS package.",
    summary:
      "A fast, formula-capable desktop spreadsheet with charts, formatting, and common workbook import and export support.",
    features: [
      "Desktop spreadsheet formulas, formatting, charts, and worksheets",
      "GTK3 interface running locally on the iPad",
      "Hardware keyboard, pointer, and touch input through xiOS",
    ],
    screenshots: [
      {
        src: "/shots/gnumeric.jpg",
        url: "https://repo.maxleiter.com/screenshots/gnumeric/01-gnumeric.jpg",
        alt: "Gnumeric running in a xiOS desktop session on a jailbroken iPad, showing a worksheet with test data and the desktop dock.",
        caption: "Gnumeric running on the iPad",
      },
    ],
    projectUrl: "https://gitlab.gnome.org/GNOME/gnumeric",
  }),
  catalogEntry({
    slug: "gwenview",
    shortName: "Gwenview",
    category: "Image viewer",
    developer: "KDE",
    summary:
      "KDE's image viewer and organizer with browsing, zooming, metadata, and lightweight editing tools.",
    projectUrl: "https://apps.kde.org/gwenview/",
  }),
  catalogEntry({
    slug: "hitori",
    shortName: "Hitori",
    category: "Puzzle game",
    developer: "The GNOME Project",
    summary:
      "GNOME's version of the Hitori logic puzzle, with desktop controls and multiple board sizes.",
    projectUrl: "https://wiki.gnome.org/Apps/Hitori",
    screenshots: [
      {
        src: "/shots/hitori.jpg",
        url: "https://repo.maxleiter.com/screenshots/hitori/01-hitori.jpg",
        alt: "The Hitori logic puzzle running in a xiOS desktop window on a jailbroken iPad.",
        caption: "Hitori running on the iPad",
      },
    ],
  }),
  catalogEntry({
    slug: "imv",
    shortName: "imv",
    category: "Image viewer",
    developer: "imv contributors",
    summary:
      "A keyboard-driven image viewer for Wayland and X11 with fast navigation and a minimal interface.",
    projectUrl: "https://sr.ht/~exec64/imv/",
    screenshots: [
      {
        src: "/shots/imv.jpg",
        url: "https://repo.maxleiter.com/screenshots/imv/01-imv.jpg",
        alt: "imv displaying a xiOS test image in a Wayland desktop session on a jailbroken iPad.",
        caption: "imv displaying an image through Wayland",
      },
    ],
  }),
  catalogEntry({
    slug: "kate",
    shortName: "Kate",
    category: "Text editor",
    developer: "KDE",
    summary:
      "KDE's advanced text editor with projects, split views, sessions, syntax highlighting, and extensible tools.",
    projectUrl: "https://apps.kde.org/kate/",
  }),
  catalogEntry({
    slug: "kcalc",
    shortName: "KCalc",
    category: "Calculator",
    developer: "KDE",
    summary:
      "KDE's scientific calculator with standard, scientific, statistics, numeral-system, and constants modes.",
    projectUrl: "https://apps.kde.org/kcalc/",
  }),
  catalogEntry({
    slug: "konsole",
    shortName: "Konsole",
    category: "Terminal",
    developer: "KDE",
    summary:
      "KDE's tabbed terminal emulator with profiles, split views, search, and desktop shell integration.",
    projectUrl: "https://apps.kde.org/konsole/",
  }),
  catalogEntry({
    slug: "kwrite",
    shortName: "KWrite",
    category: "Text editor",
    developer: "KDE",
    summary:
      "KDE's focused desktop text editor with syntax highlighting, tabs, search, and editing tools.",
    projectUrl: "https://apps.kde.org/kwrite/",
    screenshots: [
      {
        src: "/shots/kwrite.jpg",
        url: "https://repo.maxleiter.com/screenshots/kwrite/01-kwrite.jpg",
        alt: "KWrite open in a KDE xiOS desktop session on a jailbroken iPad.",
        caption: "KWrite in the xiOS KDE desktop",
      },
    ],
  }),
  catalogEntry({
    slug: "ladybird",
    shortName: "Ladybird",
    category: "Web browser",
    developer: "Ladybird Browser Initiative",
    description:
      "Run the independent Ladybird browser engine locally on a jailbroken iPad as a xiOS Wayland application.",
    summary:
      "Ladybird's independent browser engine and desktop interface, rebuilt for arm64 iOS instead of wrapping WebKit or Chromium.",
    packages: ["ladybird-wayland", "ladybird-app"],
    modes: ["xiOS desktop window", "Standalone iPadOS app"],
    features: [
      "Independent browser engine rather than an embedded WebKit view",
      "Desktop interface rendered through Wayland and Metal",
      "Runs locally as native arm64 iOS packages",
    ],
    screenshots: [
      {
        src: "/shots/ladybird.jpg",
        url: "https://repo.maxleiter.com/screenshots/ladybird-wayland/01-ladybird.jpg",
        alt: "The Ladybird browser running as a window in a xiOS desktop session on a jailbroken iPad.",
        caption: "Ladybird running in a xiOS desktop session",
      },
    ],
    projectUrl: "https://ladybird.org",
  }),
  catalogEntry({
    slug: "mpv",
    shortName: "mpv",
    category: "Media player",
    developer: "mpv contributors",
    summary:
      "A powerful Wayland-native video and audio player with GPU rendering and extensive format support.",
    projectUrl: "https://mpv.io",
    screenshots: [
      {
        src: "/shots/mpv.jpg",
        url: "https://repo.maxleiter.com/screenshots/mpv/01-mpv.jpg",
        alt: "mpv rendering a xiOS test frame in a Wayland desktop session on a jailbroken iPad.",
        caption: "mpv rendering through xiOS Wayland",
      },
    ],
  }),
  catalogEntry({
    slug: "nautilus",
    shortName: "GNOME Files",
    category: "File manager",
    developer: "The GNOME Project",
    summary:
      "GNOME's GTK4 file manager with grid and list views, search, recent files, and standard file operations.",
    projectUrl: "https://apps.gnome.org/Nautilus/",
    packages: ["nautilus"],
  }),
  catalogEntry({
    slug: "nwg-look",
    shortName: "nwg-look",
    category: "Appearance settings",
    developer: "nwg-shell contributors",
    summary:
      "A GTK settings editor for choosing themes, icons, fonts, cursors, and related Wayland desktop preferences.",
    projectUrl: "https://github.com/nwg-piotr/nwg-look",
  }),
  catalogEntry({
    slug: "okular",
    shortName: "Okular",
    category: "Document viewer",
    developer: "KDE",
    summary:
      "KDE's document viewer for PDF and other formats, with search, navigation, selection, and annotation tools.",
    projectUrl: "https://okular.kde.org/",
  }),
  catalogEntry({
    slug: "papers",
    shortName: "Papers",
    category: "Document viewer",
    developer: "The GNOME Project",
    summary:
      "GNOME's modern GTK4 document viewer for opening, navigating, searching, and reading PDF files.",
    projectUrl: "https://gitlab.gnome.org/GNOME/papers",
    screenshots: [
      {
        src: "/shots/papers.jpg",
        url: "https://repo.maxleiter.com/screenshots/papers/01-papers.jpg",
        alt: "Papers document viewer open in a xiOS GNOME desktop session on a jailbroken iPad.",
        caption: "Papers viewing a document in xiOS",
      },
    ],
  }),
  catalogEntry({
    slug: "swayimg",
    shortName: "swayimg",
    category: "Image viewer",
    developer: "swayimg contributors",
    summary:
      "A lightweight Wayland image viewer with directory browsing, scaling, animation, and keyboard controls.",
    projectUrl: "https://github.com/artemsen/swayimg",
    screenshots: [
      {
        src: "/shots/swayimg.jpg",
        url: "https://repo.maxleiter.com/screenshots/swayimg/01-swayimg.jpg",
        alt: "swayimg displaying a xiOS test image in a Wayland desktop session on a jailbroken iPad.",
        caption: "swayimg displaying an image on the iPad",
      },
    ],
  }),
  catalogEntry({
    slug: "thunar",
    shortName: "Thunar",
    category: "File manager",
    developer: "The Xfce Project",
    description:
      "Run the Thunar desktop file manager on a jailbroken iPad with xiOS and browse the device filesystem through a familiar GTK interface.",
    summary:
      "The Xfce file manager, with icon and list views, path navigation, file operations, and access to the jailbreak filesystem.",
    modes: ["xiOS desktop window", "Native iPadOS host window"],
    features: [
      "Icon and list views with normal desktop file operations",
      "Access to the mobile home directory and jailbreak filesystem",
      "Runs in a desktop session or an individual iPadOS host window",
    ],
    screenshots: [
      {
        src: "/shots/thunar.jpg",
        url: "https://repo.maxleiter.com/screenshots/thunar/01-thunar.jpg",
        alt: "Thunar running in an individual xiOS host window on a jailbroken iPad, showing the mobile home directory above the iPad dock.",
        caption: "Thunar browsing the iPad filesystem",
      },
    ],
    projectUrl: "https://docs.xfce.org/xfce/thunar/start",
  }),
  catalogEntry({
    slug: "tofi",
    shortName: "tofi",
    category: "App launcher",
    developer: "tofi contributors",
    summary:
      "A tiny, keyboard-friendly dynamic menu and application launcher designed for Wayland desktops.",
    projectUrl: "https://github.com/philj56/tofi",
    screenshots: [
      {
        src: "/shots/tofi.jpg",
        url: "https://repo.maxleiter.com/screenshots/tofi/01-tofi.jpg",
        alt: "tofi application launcher open in a xiOS desktop session on a jailbroken iPad.",
        caption: "tofi launching apps in xiOS",
      },
    ],
  }),
  catalogEntry({
    slug: "yad",
    shortName: "YAD",
    category: "Dialog utility",
    developer: "YAD contributors",
    summary:
      "A GTK3 utility for building graphical dialogs, forms, file pickers, notifications, and script interfaces.",
    projectUrl: "https://github.com/v1cont/yad",
    screenshots: [
      {
        src: "/shots/yad.jpg",
        url: "https://repo.maxleiter.com/screenshots/yad/01-yad.jpg",
        alt: "A YAD GTK dialog running in a xiOS desktop session on a jailbroken iPad.",
        caption: "A YAD dialog running through xiOS",
      },
    ],
  }),
  catalogEntry({
    slug: "zathura",
    shortName: "Zathura",
    category: "Document viewer",
    developer: "pwmt.org",
    summary:
      "A fast, keyboard-driven document viewer with a minimal interface and the Poppler PDF backend.",
    projectUrl: "https://pwmt.org/projects/zathura/",
    packages: ["zathura", "zathura-pdf-poppler"],
    screenshots: [
      {
        src: "/shots/zathura.jpg",
        url: "https://repo.maxleiter.com/screenshots/zathura/01-zathura.jpg",
        alt: "Zathura displaying a PDF test document in a xiOS Wayland desktop session on a jailbroken iPad.",
        caption: "Zathura viewing a PDF through xiOS",
      },
    ],
  }),
  catalogEntry({
    slug: "dunst",
    shortName: "Dunst",
    category: "Notifications",
    developer: "Dunst contributors",
    summary:
      "A lightweight notification daemon that displays desktop alerts inside Wayland sessions.",
    projectUrl: "https://dunst-project.org/",
    kind: "desktop-tool",
  }),
  catalogEntry({
    slug: "grim",
    shortName: "grim",
    category: "Screenshot tool",
    developer: "grim contributors",
    summary:
      "A Wayland screenshot utility for capturing compositor outputs and selected regions.",
    projectUrl: "https://sr.ht/~emersion/grim/",
    kind: "desktop-tool",
  }),
  catalogEntry({
    slug: "mako",
    shortName: "mako",
    category: "Notifications",
    developer: "mako contributors",
    summary:
      "A compact Wayland notification daemon used to display desktop alerts in xiOS sessions.",
    projectUrl: "https://github.com/emersion/mako",
    kind: "desktop-tool",
  }),
  catalogEntry({
    slug: "slurp",
    shortName: "slurp",
    category: "Screen selection",
    developer: "slurp contributors",
    summary:
      "A Wayland region-selection tool commonly paired with screenshot and screen-capture commands.",
    projectUrl: "https://github.com/emersion/slurp",
    kind: "desktop-tool",
  }),
  catalogEntry({
    slug: "swaybg",
    shortName: "swaybg",
    category: "Wallpaper",
    developer: "Sway contributors",
    summary:
      "A Wayland wallpaper utility for displaying solid colors or images behind desktop windows.",
    projectUrl: "https://github.com/swaywm/swaybg",
    kind: "desktop-tool",
  }),
  catalogEntry({
    slug: "waybar",
    shortName: "Waybar",
    category: "Desktop panel",
    developer: "Waybar contributors",
    summary:
      "A configurable GTK status bar for Wayland desktops, with workspace, system, clock, and custom modules.",
    projectUrl: "https://github.com/Alexays/Waybar",
    kind: "desktop-tool",
    screenshots: [
      {
        src: "/shots/waybar.jpg",
        url: "https://repo.maxleiter.com/screenshots/waybar/01-waybar.jpg",
        alt: "Waybar visible along the top edge of a xiOS Wayland desktop on a jailbroken iPad.",
        caption: "Waybar providing the xiOS desktop panel",
      },
    ],
  }),
  catalogEntry({
    slug: "wl-clipboard",
    shortName: "wl-clipboard",
    category: "Clipboard utility",
    developer: "wl-clipboard contributors",
    summary:
      "Command-line copy and paste tools that connect scripts and terminal workflows to the Wayland clipboard.",
    projectUrl: "https://github.com/bugaevc/wl-clipboard",
    kind: "desktop-tool",
  }),
];

export const USER_APPS = APPS.filter((app) => app.kind === "app");
export const DESKTOP_TOOLS = APPS.filter((app) => app.kind === "desktop-tool");
export const APP_BY_SLUG = new Map(APPS.map((app) => [app.slug, app]));

export function packageDepiction(packageId: string) {
  return `https://repo.maxleiter.com/depictions/${packageId}.html`;
}
