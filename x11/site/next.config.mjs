/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  images: {
    // Screenshots are large flat UI captures; AVIF wins big on them.
    formats: ["image/avif", "image/webp"],
  },
  async headers() {
    return [
      {
        // The clip and its poster are served raw (next/image only handles the
        // stills), so give them a real cache window instead of must-revalidate.
        source: "/shots/:path*",
        headers: [
          {
            key: "Cache-Control",
            value: "public, max-age=86400, stale-while-revalidate=2592000",
          },
        ],
      },
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Frame-Options", value: "SAMEORIGIN" },
        ],
      },
    ];
  },
};

export default nextConfig;
