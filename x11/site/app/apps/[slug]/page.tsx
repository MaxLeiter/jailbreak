import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Shot } from "@/components/Figures";
import { Ext, PageHeader, Section } from "@/components/ui";
import { APPS, APP_BY_SLUG, packageDepiction } from "@/content/apps";
import { OG_IMAGE, SITE } from "@/content/site";

type Props = {
  params: Promise<{ slug: string }>;
};

export function generateStaticParams() {
  return APPS.map(({ slug }) => ({ slug }));
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params;
  const app = APP_BY_SLUG.get(slug);
  if (!app) return {};

  const url = `/apps/${app.slug}`;
  const screenshot = app.screenshots[0];
  const image = screenshot?.url ?? OG_IMAGE;
  return {
    title: app.name,
    description: app.description,
    keywords: [
      `${app.shortName} iOS`,
      `${app.shortName} iPad`,
      `${app.shortName} iOS jailbreak`,
      `${app.shortName} jailbroken iPad`,
      "xiOS",
    ],
    alternates: { canonical: url },
    openGraph: {
      type: "website",
      siteName: SITE.name,
      locale: "en_US",
      title: `${app.name} | xiOS`,
      description: app.description,
      url,
      images: screenshot ? [{ url: image, alt: screenshot.alt }] : [OG_IMAGE],
    },
    twitter: {
      card: "summary_large_image",
      title: `${app.name} | xiOS`,
      description: app.description,
      images: [image],
    },
  };
}

export default async function AppPage({ params }: Props) {
  const { slug } = await params;
  const app = APP_BY_SLUG.get(slug);
  if (!app) notFound();

  const canonical = `${SITE.url}/apps/${app.slug}`;
  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: app.name,
    alternateName: app.shortName,
    description: app.description,
    url: canonical,
    applicationCategory: app.category,
    operatingSystem: "iOS on a jailbroken iPad",
    image: app.screenshots.map((shot) => shot.url),
    screenshot: app.screenshots.map((shot) => shot.url),
    author: {
      "@type": "Organization",
      name: app.developer,
      url: app.projectUrl,
    },
    offers: {
      "@type": "Offer",
      price: "0",
      priceCurrency: "USD",
      availability: "https://schema.org/InStock",
      url: packageDepiction(app.packages[0]),
    },
  };

  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <PageHeader tag={app.category} title={app.name} lede={app.description} />

      <div className="app-facts" aria-label="App facts">
        <div>
          <span>Runs as</span>
          <strong>{app.modes.join(" · ")}</strong>
        </div>
        <div>
          <span>Packages</span>
          <strong>{app.packages.join(" · ")}</strong>
        </div>
        <div>
          <span>Upstream</span>
          <strong>
            <Ext href={app.projectUrl}>{app.developer}</Ext>
          </strong>
        </div>
      </div>

      <Section num="APP.1" title="What is included">
        <div className="prose">
          <p>{app.summary}</p>
          <ul>
            {app.features.map((feature) => (
              <li key={feature}>{feature}</li>
            ))}
          </ul>
          <p>
            This port requires a compatible rootless jailbreak and xiOS. It is
            not an App Store release.
          </p>
        </div>
        <div className="app-actions">
          {app.packages.map((packageId) => (
            <a href={packageDepiction(packageId)} key={packageId}>
              View <code>{packageId}</code> in the package repo
            </a>
          ))}
        </div>
      </Section>

      {app.screenshots.length > 0 ? (
        <Section num="APP.2" title="On-device screenshots">
          <div className="shot-grid app-shot-grid">
            {app.screenshots.map((shot, index) => (
              <Shot
                key={shot.src}
                src={shot.src}
                alt={shot.alt}
                caption={shot.caption}
                priority={index === 0}
                sizes="(max-width: 900px) 100vw, 720px"
              />
            ))}
          </div>
        </Section>
      ) : null}

      <Link href="/apps" className="app-back-link">
        ← All xiOS apps
      </Link>
    </>
  );
}
