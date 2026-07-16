import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import Script from "next/script";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "usAIge — AI usage and agent status, always in sight",
  description: "A native macOS floating rail for live AI usage, breathing Codex task status, and one-click return to work.",
  icons: { icon: "/app-icon.png", apple: "/app-icon.png" },
  openGraph: {
    title: "usAIge — Your AI work, still breathing",
    description: "Live AI usage and aggregate Codex task status in one quiet native macOS rail.",
    type: "website",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>
        <Script
          src="https://vibeloft.ai/telemetry/v1.js"
          strategy="afterInteractive"
          data-vl-product-id="0d5781ba-0024-4ef4-b25d-2853ee434456"
          data-vl-auth-key="vl_web.ABms9507nd0NZCD_gPk4F__qMTs7kE__rxC1LJI94i4"
        />
        {children}
      </body>
    </html>
  );
}
