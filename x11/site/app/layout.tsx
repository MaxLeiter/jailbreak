import type { Metadata } from "next";
import { Archivo, IBM_Plex_Sans, Space_Mono } from "next/font/google";
import { Sidebar } from "@/components/Sidebar";
import "./globals.css";
import "./ui.css";

const archivo = Archivo({
  subsets: ["latin"],
  weight: ["600", "700", "800"],
  variable: "--font-archivo",
  display: "swap",
});

const plex = IBM_Plex_Sans({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-plex",
  display: "swap",
});

const spaceMono = Space_Mono({
  subsets: ["latin"],
  weight: ["400", "700"],
  variable: "--font-space-mono",
  display: "swap",
});

export const metadata: Metadata = {
  title: {
    default: "XIOS, native X11 and Wayland on jailbroken iOS",
    template: "%s / XIOS",
  },
  description:
    "How a real X11 server, a GPU-accelerated Wayland compositor, and GNOME apps run as native arm64 binaries on a jailbroken iOS device, rendered through Metal.",
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
        <div className="shell">
          <Sidebar />
          <main className="main">
            <div className="main-inner">{children}</div>
          </main>
        </div>
      </body>
    </html>
  );
}
