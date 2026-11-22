import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const basePath = "/project/usaige";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  metadataBase: new URL("https://pmrichq.com"),
  title: "usAIge — AI usage and agent status, always in sight",
  description: "A native macOS floating rail for live AI usage, breathing Codex task status, and one-click return to work.",
  icons: { icon: `${basePath}/app-icon.png`, apple: `${basePath}/app-icon.png` },
  openGraph: {
    title: "usAIge — Your AI work, still breathing",
    description: "Live AI usage and aggregate Codex task status in one quiet native macOS rail.",
    type: "website",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <head />
      <body className={`${geistSans.variable} ${geistMono.variable}`}>
        {children}
      </body>
    </html>
  );
}
