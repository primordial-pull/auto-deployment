# syntax=docker/dockerfile:1

# ---------- base: 모든 스테이지 공통 툴링 ----------
FROM node:24-alpine AS base
RUN apk add --no-cache libc6-compat
RUN npm i -g pnpm@11.17.0
ENV NEXT_TELEMETRY_DISABLED=1

# ---------- deps: 락파일이 바뀔 때만 재실행되는 레이어 ----------
FROM base AS deps
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

# ---------- builder: standalone 서버 생성 ----------
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN pnpm build

# ---------- runner: 실행에 필요한 것만 ----------
# 최종 이미지에는 pnpm 이 필요 없다. 빌드 결과물만 실행하면 되므로
# base 스테이지를 상속하지 않고 빈 알파인에서 새로 시작한다.
FROM node:24-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# standalone 은 서버만 담고 있다. static 과 public 은 직접 넣어야 한다.
COPY --from=builder --chown=node:node /app/public ./public
COPY --from=builder --chown=node:node /app/.next/standalone ./
COPY --from=builder --chown=node:node /app/.next/static ./.next/static

# node:alpine 에 기본 포함된 비루트 계정
USER node

EXPOSE 3000

CMD ["node", "server.js"]
