import type { Metadata } from "next";
import Link from "next/link";
import { PageHeader, Section } from "@/components/ui";
import { DESKTOP_TOOLS, USER_APPS, type XiosApp } from "@/content/apps";
import { OG_IMAGE, SITE } from "@/content/site";

const description =
  "A complete catalog of desktop apps running locally on jailbroken iOS through xiOS, including GIMP, GNOME and KDE apps, terminals, file managers, and desktop tools.";

export const metadata: Metadata = {
  title: "Apps for jailbroken iOS",
  description,
  alternates: { canonical: "/apps" },
  openGraph: {
    type: "website",
    siteName: SITE.name,
    locale: "en_US",
    title: "xiOS | Apps for jailbroken iOS",
    description,
    url: "/apps",
    images: [OG_IMAGE],
  },
  twitter: {
    card: "summary_large_image",
    title: "xiOS | Apps for jailbroken iOS",
    description,
    images: [OG_IMAGE],
  },
};

export default function AppsPage() {
  function cards(apps: XiosApp[]) {
    return (
      <div className="app-grid">
        {apps.map((app) => (
          <Link className="card app-card" href={`/apps/${app.slug}`} key={app.slug}>
            <span className="card-tag">{app.category}</span>
            <h3>{app.name}</h3>
            <p>{app.summary}</p>
            <span className="app-card-link">
              {app.screenshots.length > 0 ? "Screenshots and details" : "Packages and details"} →
            </span>
          </Link>
        ))}
      </div>
    );
  }

  return (
    <>
      <PageHeader
        tag="App catalog"
        title="Desktop apps, running on iOS"
        lede="These are real arm64 iOS builds running locally on a jailbroken iPad—not streamed sessions, web wrappers, or screenshots from another platform."
      />

      <Section num="04A.1" title="Applications">
        {cards(USER_APPS)}
      </Section>

      <Section num="04A.2" title="Desktop tools">
        <div className="prose">
          <p>
            These packages support the desktop itself: launchers, panels,
            notifications, screenshots, wallpaper, selection, and clipboard
            workflows.
          </p>
        </div>
        {cards(DESKTOP_TOOLS)}
      </Section>

      <p className="app-catalog-note">
        The catalog includes every launchable user-facing app and desktop tool in
        the current repository. Libraries, plug-ins, backends, daemons, and
        desktop meta-packages remain available through their parent package or
        environment rather than being mislabeled as standalone apps.
      </p>
    </>
  );
}
