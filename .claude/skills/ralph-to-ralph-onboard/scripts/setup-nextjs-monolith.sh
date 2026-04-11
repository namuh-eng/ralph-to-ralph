#!/usr/bin/env bash
# setup-nextjs-monolith.sh — Scaffolds a Next.js monolith for the dashboard-app stack profile.
# Run by the onboarding agent when the user picks a simple monolith setup.
# Idempotent: safe to run multiple times.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Setting up Next.js monolith..."

# --- 1. Install framework dependencies ---
echo "  Installing Next.js, React, Tailwind..."
npm install --save next@latest react@latest react-dom@latest 2>/dev/null
npm install --save-dev @vitejs/plugin-react @types/react @types/react-dom \
  tailwindcss@latest postcss@latest autoprefixer@latest 2>/dev/null

# --- 2. Create next.config.js ---
if [ ! -f next.config.js ]; then
  cat > next.config.js << 'NEXTCONFIG'
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
};

module.exports = nextConfig;
NEXTCONFIG
  echo "  Created next.config.js"
fi

# --- 3. Create tailwind.config.ts ---
if [ ! -f tailwind.config.ts ]; then
  cat > tailwind.config.ts << 'TAILWIND'
import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  darkMode: "class",
  theme: { extend: {} },
  plugins: [],
};

export default config;
TAILWIND
  echo "  Created tailwind.config.ts"
fi

# --- 4. Create postcss.config.js ---
if [ ! -f postcss.config.js ]; then
  cat > postcss.config.js << 'POSTCSS'
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
};
POSTCSS
  echo "  Created postcss.config.js"
fi

# --- 5. Scaffold src/app/ ---
mkdir -p src/app

if [ ! -f src/app/globals.css ]; then
  cat > src/app/globals.css << 'CSS'
@tailwind base;
@tailwind components;
@tailwind utilities;
CSS
  echo "  Created src/app/globals.css"
fi

if [ ! -f src/app/layout.tsx ]; then
  cat > src/app/layout.tsx << 'LAYOUT'
import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "App",
  description: "Built with ralph-to-ralph",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
LAYOUT
  echo "  Created src/app/layout.tsx"
fi

if [ ! -f src/app/page.tsx ]; then
  cat > src/app/page.tsx << 'PAGE'
export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center p-8">
      <h1 className="text-4xl font-bold">Ready to build</h1>
      <p className="mt-4 text-lg text-gray-600">
        Run the inspect phase to start cloning your target product.
      </p>
    </main>
  );
}
PAGE
  echo "  Created src/app/page.tsx"
fi

# --- 6. Create next-env.d.ts ---
if [ ! -f next-env.d.ts ]; then
  cat > next-env.d.ts << 'NEXTENV'
/// <reference types="next" />
/// <reference types="next/image-types/global" />
NEXTENV
  echo "  Created next-env.d.ts"
fi

# --- 7. Update package.json scripts ---
# Use node to safely merge scripts without clobbering existing ones
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.scripts = {
  ...pkg.scripts,
  dev: 'next dev --port 3015',
  build: 'next build',
  start: 'next start',
};
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
echo "  Updated package.json scripts (dev, build, start)"

# --- 8. Update tsconfig.json for Next.js ---
node -e "
const fs = require('fs');
const tsconfig = JSON.parse(fs.readFileSync('tsconfig.json', 'utf8'));
if (!tsconfig.compilerOptions.jsx) {
  tsconfig.compilerOptions.jsx = 'preserve';
}
if (!tsconfig.compilerOptions.plugins) {
  tsconfig.compilerOptions.plugins = [];
}
if (!tsconfig.compilerOptions.plugins.some(p => p.name === 'next')) {
  tsconfig.compilerOptions.plugins.push({ name: 'next' });
}
if (!tsconfig.include) tsconfig.include = [];
if (!tsconfig.include.includes('next-env.d.ts')) {
  tsconfig.include.push('next-env.d.ts');
}
fs.writeFileSync('tsconfig.json', JSON.stringify(tsconfig, null, 2) + '\n');
"
echo "  Updated tsconfig.json for Next.js"

# --- 9. Update Dockerfile for Next.js standalone ---
cat > Dockerfile << 'DOCKERFILE'
FROM node:20-alpine AS base

FROM base AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --production=false

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
USER nextjs
EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
CMD ["node", "server.js"]
DOCKERFILE
echo "  Updated Dockerfile for Next.js standalone"

echo ""
echo "==> Next.js monolith ready!"
echo "    Run: npm run dev"
echo "    Open: http://localhost:3015"
