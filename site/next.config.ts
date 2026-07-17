import type { NextConfig } from "next";

const basePath = "/project/usaige";

const nextConfig: NextConfig = {
  basePath,
  output: "export",
  trailingSlash: true,
};

export default nextConfig;
