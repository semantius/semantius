import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Semantius — Next.js sample",
  description:
    "OAuth (auth-code + PKCE) -> request-scoped transaction -> Drizzle under RLS. One flag runs it against PG18 OAUTHBEARER, Neon, and Supabase.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>
        <main>{children}</main>
      </body>
    </html>
  );
}
