import type { MetadataRoute } from "next";
import { NAV, SITE } from "@/content/site";

export default function sitemap(): MetadataRoute.Sitemap {
  return NAV.map((item) => ({
    url: new URL(item.href, SITE.url).toString(),
    changeFrequency: "weekly",
    priority: item.href === "/" ? 1 : 0.8,
  }));
}
