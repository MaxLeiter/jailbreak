import type { MetadataRoute } from "next";
import { APPS } from "@/content/apps";
import { NAV, SITE } from "@/content/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const pages = NAV.map((item) => ({
    url: new URL(item.href, SITE.url).toString(),
    changeFrequency: "weekly" as const,
    priority: item.href === "/" ? 1 : 0.8,
  }));
  const apps = APPS.map((app) => ({
    url: new URL(`/apps/${app.slug}`, SITE.url).toString(),
    changeFrequency: "weekly" as const,
    priority: 0.9,
    images: app.screenshots.map((shot) => shot.url),
  }));
  return [...pages, ...apps];
}
