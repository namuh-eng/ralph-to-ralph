FROM node:20-alpine AS base

FROM base AS deps
RUN apk add --no-cache libc6-compat
WORKDIR /app
# Copy .npmrc if it exists to handle peer dependency conflicts
COPY package.json package-lock.json .npmrc* ./
RUN npm ci --production=false

FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Set build-time env vars for Next.js client-side hydration
ARG NEXT_PUBLIC_APP_URL
ENV NEXT_PUBLIC_APP_URL=${NEXT_PUBLIC_APP_URL}

RUN npm run build

FROM base AS runner
WORKDIR /app
# Production runtime dependencies
RUN apk add --no-cache openssl

ENV NODE_ENV=production
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Create public dir if it doesn't exist to prevent COPY failure
RUN mkdir -p public

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000
ENV PORT=3000

# Container runtimes often override HOSTNAME; set it inline at process start to ensure 0.0.0.0
CMD ["sh", "-c", "HOSTNAME=0.0.0.0 node server.js"]
