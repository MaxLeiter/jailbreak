import type { Metadata, Viewport } from "next";
import { Analytics } from "@vercel/analytics/next";
import { Archivo, IBM_Plex_Sans, Space_Mono } from "next/font/google";
import { Sidebar } from "@/components/Sidebar";
import { NAV, SITE, SITE_TITLE } from "@/content/site";
import "./globals.css";
import "./ui.css";

const archivo = Archivo({
  subsets: ["latin"],
  weight: ["700", "800"],
  variable: "--font-archivo",
  display: "swap",
});

const plex = IBM_Plex_Sans({
  subsets: ["latin"],
  weight: ["400", "600"],
  variable: "--font-plex",
  display: "swap",
});

const spaceMono = Space_Mono({
  subsets: ["latin"],
  weight: ["400", "700"],
  variable: "--font-space-mono",
  display: "swap",
});

const DESCRIPTION = NAV[0].description;

export const metadata: Metadata = {
  metadataBase: new URL(SITE.url),
  title: {
    default: SITE.name,
    template: `${SITE.name} | %s`,
  },
  description: DESCRIPTION,
  applicationName: SITE.name,
  authors: [{ name: SITE.author, url: SITE.authorUrl }],
  creator: SITE.author,
  publisher: SITE.author,
  category: "technology",
  keywords: [
    "X11 on iOS",
    "Wayland on iOS",
    "Linux on iPad",
    "jailbreak",
    "GNOME on iOS",
    "KDE Plasma on iOS",
    "Procursus",
    "ANGLE",
    "Metal",
    "IOSurface",
    "GTK",
    "Qt",
    "xiOS",
  ],
  alternates: { canonical: "/" },
  openGraph: {
    type: "website",
    siteName: SITE.name,
    locale: "en_US",
    url: "/",
    title: SITE.name,
    description: DESCRIPTION,
  },
  twitter: {
    card: "summary_large_image",
    title: SITE.name,
    description: DESCRIPTION,
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
      "max-video-preview": -1,
    },
  },
  // Standalone (Add to Home Screen) presentation. black-translucent lets the
  // dark page run under the status bar; globals.css pays the safe-area insets.
  appleWebApp: {
    capable: true,
    title: SITE.name,
    statusBarStyle: "black-translucent",
  },
  formatDetection: { telephone: false },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  // Lets the page paint into the notch/home-indicator area; the CSS then pads
  // content back out with env(safe-area-inset-*).
  viewportFit: "cover",
  // Dark-only site: this colors the iOS Safari top/bottom bars and the
  // rubber-band overscroll instead of leaving them white.
  colorScheme: "dark",
  themeColor: SITE.themeColor,
};

const JSON_LD = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  name: SITE.name,
  alternateName: SITE_TITLE,
  url: SITE.url,
  description: DESCRIPTION,
  inLanguage: "en",
  author: {
    "@type": "Person",
    name: SITE.author,
    url: SITE.authorUrl,
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html
      lang="en"
      className={`${archivo.variable} ${plex.variable} ${spaceMono.variable}`}
    >
      <body>
        <script
          type="application/ld+json"
          // Static object, no user input.
          dangerouslySetInnerHTML={{ __html: JSON.stringify(JSON_LD) }}
        />
        <a href="#main" className="skip-link">
          Skip to content
        </a>
        <div className="shell">
          <Sidebar />
          <main className="main" id="main" tabIndex={-1}>
            <div className="main-inner">{children}</div>
          </main>
        </div>
        <Analytics />
      </body>
    </html>
  );
}
