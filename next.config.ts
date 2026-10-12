import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // infra/Dockerfile copies .next/standalone (server.js) into the image
  output: "standalone",
  cacheComponents: true,
  partialPrefetching: true,
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
