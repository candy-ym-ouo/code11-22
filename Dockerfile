# syntax=docker/dockerfile:1
# 家中物品来历册 · 多阶段构建
#
# 产出两个镜像目标（compose 按 target 自动选取）：
#   target=app   heirloom-app   API + 前端静态产物 + 迁移/备份/恢复运维工具
#   target=proxy heirloom-proxy Caddy 反向代理 + 前端静态托管

# ---------- 1. 构建：依赖 + Prisma Client + 全仓构建 ----------
FROM node:20-bookworm-slim AS build
WORKDIR /app

# 构建期只需要 openssl（Prisma 引擎依赖）；npm 随基础镜像自带
RUN apt-get update \
  && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# 固定 pnpm 版本（与 package.json packageManager 一致）
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate

# 先拷 workspace 清单以利用层缓存
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/shared/package.json packages/shared/
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/

# --frozen-lockfile 保证镜像里的依赖与仓库锁定版本一致
RUN pnpm install --frozen-lockfile

# 拷贝源码并构建：shared → prisma generate → api → web
COPY packages packages
COPY apps apps
RUN pnpm --filter @heirloom/shared build \
  && pnpm --filter @heirloom/api exec prisma generate \
  && pnpm --filter @heirloom/api build \
  && pnpm --filter @heirloom/web build

# ---------- 2a. 运行时镜像：app ----------
FROM node:20-bookworm-slim AS app
WORKDIR /app
ENV NODE_ENV=production \
  TZ=Asia/Shanghai

# 运行期依赖：
# - ffmpeg：音频转码与波形生成（不装也能跑，只是不转码）
# - postgresql-client-16：迁移健康探测/备份（pg_dump 自定义格式 -Fc，
#   主/备主版本必须一致，所以跟随镜像用的 postgres:16，从 PGDG 装 16）
# - tini：PID 1 信号转发，保证 SIGTERM 优雅关闭
# - openssl：Prisma 引擎运行依赖
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg tini ffmpeg openssl; \
  install -d /usr/share/postgresql-common/pgdg; \
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg; \
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list; \
  apt-get update; \
  apt-get install -y --no-install-recommends postgresql-client-16; \
  apt-get purge -y --auto-remove gnupg; \
  rm -rf /var/lib/apt/lists/*

# 复用构建阶段装好的 node_modules（含 prisma CLI）与构建产物
COPY --from=build /app /app

# 容器内数据统一落在 /data，由 compose 挂命名卷保证持久化
ENV STORAGE_ROOT=/data/uploads \
  EXPORT_ROOT=/data/exports \
  BACKUP_ROOT=/data/backups \
  WEB_DIST=/app/apps/web/dist

COPY deploy/entrypoint.sh /usr/local/bin/entrypoint
COPY deploy/scheduler.sh /usr/local/bin/scheduler
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/scheduler

# 预建数据/密钥目录并交给 node(uid1000)：首次挂空命名卷时 Docker 会把
# 这些目录的属主复制进卷，让非 root 运行成为可能。当前编排以 root 运行
# （单租户自托管应用，与 systemd 裸跑同威胁模型）；如需收紧，可在 compose
# 里加 user: "1000:1000"，卷属主已就绪。
RUN mkdir -p /data/uploads /data/exports /data/backups /secrets \
  && chown -R node:node /data /secrets

EXPOSE 4000
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint"]
# 默认模式：等数据库 → 迁移 → 启动 API
CMD ["api"]

# ---------- 2b. 反向代理镜像：Caddy + 前端静态托管 ----------
# 官方 caddy 镜像很精简，补一个 curl 供 compose healthcheck 探测 /healthz
FROM caddy:2.8-bookworm AS proxy
RUN apt-get update \
  && apt-get install -y --no-install-recommends curl \
  && mkdir -p /tmp/caddy \
  && rm -rf /var/lib/apt/lists/*
# 静态构建产物：带 hash 指纹的 assets 长缓存，index.html 不缓存
COPY --from=build --chown=1001:0 /app/apps/web/dist /srv/web
COPY deploy/Caddyfile /etc/caddy/Caddyfile
# 以非 root 用户（官方镜像内 uid 1001）运行；只需要静态文件读权限
USER 1001
EXPOSE 8080
