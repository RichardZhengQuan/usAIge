import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "usAIge — Your AI usage, always in sight",
  description: "A native macOS floating rail for live Codex 5-hour and 7-day usage limits.",
  icons: { icon: "/app-icon.png", apple: "/app-icon.png" },
  openGraph: {
    title: "usAIge — Know your AI limits",
    description: "A quiet, private floating usage rail for Codex on macOS.",
    type: "website",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body className={`${geistSans.variable} ${geistMono.variable}`}>{children}</body></html>;
}
