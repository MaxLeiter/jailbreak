import type { Metadata } from "next";

export type NavItem = {
  href: string;
  label: string;
  idx: string;
  /** Used for <meta name="description">, OG/Twitter cards and search snippets. */
  description: string;
};

export const NAV: NavItem[] = [
  {
    href: "/",
    label: "Overview",
    idx: "00",
    description:
      "GNOME, KDE, GTK and Qt apps rebuilt as native arm64 iOS binaries on a jailbroken iPad, drawn to the screen through Metal.",
  },
  {
    href: "/architecture",
    label: "Architecture",
    idx: "01",
    description:
      "Jailbroken iOS gives this stack no display server, no DRM/KMS path and no background service that can own the screen. The design funnels desktop sessions through one ordinary app.",
  },
  {
    href: "/display-servers",
    label: "Display servers",
    idx: "02",
    description:
      "Two servers draw the desktop: xiOS speaks X11 and renders in software, iosc speaks Wayland and composites on the GPU. Separate programs that share an output format.",
  },
  {
    href: "/graphics",
    label: "The GPU path",
    idx: "03",
    description:
      "Desktop OpenGL is not available on iOS, but the GPU is, behind Metal. ANGLE translates OpenGL ES into Metal so GLES clients and the compositor render straight into shared IOSurfaces.",
  },
  {
    href: "/flavors",
    label: "Desktop flavors",
    idx: "04",
    description:
      "The same Linux apps, presented three ways: as native iOS Home Screen apps, on the iosc desktop, or inside a full GNOME or KDE Plasma session.",
  },
  {
    href: "/build",
    label: "Build & packaging",
    idx: "05",
    description:
      "Packages are cross-compiled on a Mac in Docker against the Procursus toolchain, patched reproducibly, and shipped as Debian packages to a Sileo repo.",
  },
  {
    href: "/system",
    label: "System integration",
    idx: "06",
    description:
      "Battery, audio, brightness, Bluetooth, keyboard and orientation: iOS exposes all of it, just not where Linux looks. Small daemons translate each one to UPower, PulseAudio and D-Bus.",
  },
  {
    href: "/try",
    label: "Try it yourself",
    idx: "07",
    description:
      "Everything ships as ordinary Debian packages from repo.maxleiter.com. Bring a compatible jailbreak and expect some rough edges.",
  },
];

export const SITE = {
  name: "xiOS",
  tagline: "A native Linux desktop on jailbroken iOS.",
  /** Canonical origin. Also the metadataBase for every relative OG/canonical URL. */
  url: "https://xios.maxleiter.com",
  repo: "https://repo.maxleiter.com",
  author: "Max Leiter",
  authorUrl: "https://maxleiter.com",
  device: "Reference device: iPad 7 (A10), iPadOS 17.6.1",
  /** Matches --bg in globals.css; drives the iOS/Android browser chrome. */
  themeColor: "#090c11",
};

export const SITE_TITLE = "xiOS, native X11 and Wayland on jailbroken iOS";

/**
 * Served by the app/opengraph-image.jpg file convention. Referenced explicitly
 * because a page that defines its own `openGraph` replaces the inherited one,
 * image included, and would otherwise get a preview card with no image.
 */
export const OG_IMAGE = {
  url: "/opengraph-image.jpg",
  width: 1200,
  height: 630,
  alt: "xiOS: X11 and Wayland on iOS. Desktop Linux apps rebuilt for jailbroken devices.",
};

export function siblings(href: string) {
  const i = NAV.findIndex((n) => n.href === href);
  return {
    prev: i > 0 ? NAV[i - 1] : null,
    next: i >= 0 && i < NAV.length - 1 ? NAV[i + 1] : null,
  };
}

/**
 * Per-page metadata: title, description, canonical, and matching OG/Twitter
 * copy. Pages that skip this inherit only the site-wide description, which
 * makes every search result read the same.
 */
export function pageMetadata(href: string): Metadata {
  const item = NAV.find((n) => n.href === href);
  if (!item) return {};
  const title = href === "/" ? undefined : item.label;
  const ogTitle = href === "/" ? SITE_TITLE : `${item.label} / ${SITE.name}`;
  return {
    title,
    description: item.description,
    alternates: { canonical: href },
    // Next replaces (does not merge) these objects, so every field the root
    // layout sets has to be repeated here or it is dropped from the page.
    openGraph: {
      type: "website",
      siteName: SITE.name,
      locale: "en_US",
      title: ogTitle,
      description: item.description,
      url: href,
      images: [OG_IMAGE],
    },
    twitter: {
      card: "summary_large_image",
      title: ogTitle,
      description: item.description,
      images: [OG_IMAGE],
    },
  };
}
