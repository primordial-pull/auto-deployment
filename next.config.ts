import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  /* config options here */
  reactCompiler: true,
  // 런타임에 실제로 필요한 의존성만 추린 서버를 .next/standalone 에 생성한다.
  // 도커 런타임 이미지 크기를 줄이기 위한 설정.
  output: "standalone",
};

export default nextConfig;
