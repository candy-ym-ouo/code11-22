# syntax=docker/dockerfile:1
# 家中物品来历册 · 多目标镜像
#
#   target=api       生产运行镜像：API（含 worker / ffmpeg），不含前端服务器
#   target=migrate   一次性迁移镜像：跑 prisma migrate deploy 后退出
#   target=web       nginx：反向代理 + 前端静态托管（构建产物在镜像内）
#   target=backup    postgres 客户端 + 备份/恢复脚本（定时备份服务与一次性恢复共用）
#
# 之所以迁移单独成镜像：运行镜像只保留生产依赖（无 prisma CLI），迁移完成即可丢弃。

ARG NODE_IMAGE=node:20-bookworm-slim
ARG PG_IMAGE=postgres:16-bookworm

# ---------------------------------------------------------------------------
# base：pnpm 与基础库
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS base
ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
# ca-certificates：托管 PG 走 TLS；openssl：prisma query engine 运行需要
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates openssl tini \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable && corepack prepare pnpm@9.12.0 --activate \
    && pnpm config set store-dir /pnpm/store
WORKDIR /app

# ---------------------------------------------------------------------------
# deps：先装全部依赖（利用 Docker 层缓存，源码变动不重装）
# ---------------------------------------------------------------------------
FROM base AS deps
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml .npmrc ./
COPY packages/shared/package.json packages/shared/
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/
# 内网构建可在 build-arg 覆盖 npm / prisma 引擎源
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG PRISMA_ENGINES_MIRROR=https://registry.npmmirror.com/-/binary/prisma
ENV PRISMA_ENGINES_MIRROR=${PRISMA_ENGINES_MIRROR}
RUN pnpm install --frozen-lockfile --store-dir /pnpm/store --registry=${NPM_REGISTRY}

# ---------------------------------------------------------------------------
# builder：编译 shared / api / web，并生成 Prisma Client
# ---------------------------------------------------------------------------
FROM deps AS builder
COPY packages packages
COPY apps apps
# 直接用 schema 路径生成，避免依赖 pnpm 过滤与 prisma 的 package.json 配置解析
RUN pnpm --filter @heirloom/shared build \
    && pnpm --filter @heirloom/api exec prisma generate --schema=apps/api/prisma/schema.prisma \
    && pnpm --filter @heirloom/api build \
    && pnpm --filter @heirloom/web build

# ---------------------------------------------------------------------------
# prod-deps：仅生产依赖（prune 后 Prisma Client 生成产物仍保留在 .pnpm 中）
# ---------------------------------------------------------------------------
FROM deps AS prod-deps
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/packages/shared/package.json /app/packages/shared/
COPY --from=builder /app/packages/shared/dist /app/packages/shared/dist
COPY --from=builder /app/apps/api/package.json /app/apps/api/
# --offline 只用 store 缓存，不触网；保留 prisma 生成产物
RUN pnpm install --frozen-lockfile --prod --offline --store-dir /pnpm/store \
    && pnpm --filter @heirloom/api exec prisma generate --schema=apps/api/prisma/schema.prisma

# ---------------------------------------------------------------------------
# target: api —— 生产运行
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS api
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates openssl tini ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1001 heirloom \
    && useradd --system --uid 1001 --gid heirloom --create-home --home-dir /home/heirloom heirloom
ENV NODE_ENV=production \
    PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate
WORKDIR /app

COPY --from=prod-deps --chown=heirloom:heirloom /app/node_modules ./node_modules
COPY --from=prod-deps --chown=heirloom:heirloom /app/packages ./packages
COPY --from=builder --chown=heirloom:heirloom /app/apps/api/dist ./apps/api/dist
COPY pnpm-workspace.yaml package.json pnpm-lock.yaml ./
COPY docker/api-entrypoint.sh /usr/local/bin/api-entrypoint.sh
RUN chmod +x /usr/local/bin/api-entrypoint.sh \
    && mkdir -p /data/uploads /data/exports /data/backups \
    && chown -R heirloom:heirloom /data

USER heirloom
EXPOSE 4000
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/api-entrypoint.sh"]
CMD ["node", "apps/api/dist/index.js"]
# 只探测进程存活；依赖就绪（DB/存储/worker）由 /readyz 经 compose healthcheck 负责
HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=5 \
    CMD node -e "require('node:http').get('http://127.0.0.1:4000/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

# ---------------------------------------------------------------------------
# target: migrate —— 一次性数据库迁移（prisma migrate deploy，只前进）
# ---------------------------------------------------------------------------
FROM base AS migrate
# wait-for-db.sh 用 pg_isready 探活
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
# 迁移需要完整依赖（含 prisma CLI 与 schema-engine）与源码
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/packages ./packages
COPY --from=builder /app/apps/api/dist ./apps/api/dist
COPY apps/api/prisma ./apps/api/prisma
COPY pnpm-workspace.yaml package.json ./
# 等数据库接受连接后再迁移；最多等 60 秒
COPY docker/wait-for-db.sh /usr/local/bin/wait-for-db.sh
RUN chmod +x /usr/local/bin/wait-for-db.sh
ENTRYPOINT ["/usr/local/bin/wait-for-db.sh"]
# 显式指定 schema，工作目录为 /app（filter 只负责找到正确的 prisma 二进制）
CMD ["pnpm", "--filter", "@heirloom/api", "exec", "prisma", "migrate", "deploy", "--schema=apps/api/prisma/schema.prisma"]

# ---------------------------------------------------------------------------
# target: web —— nginx 反向代理 + 前端静态托管
# ---------------------------------------------------------------------------
FROM nginx:1.27-bookworm AS web
# curl：供 compose 健康检查经本机 nginx 反代打到 api 的 /healthz
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/apps/web/dist /usr/share/nginx/html
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
# 容器级自检：确认反代链路（nginx → api）通；api 没起来时该容器也会变 unhealthy
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD curl -fsS http://127.0.0.1/healthz || exit 1

# ---------------------------------------------------------------------------
# target: backup —— 定时备份 / 一次性恢复（postgres:16 自带 pg_dump/pg_restore）
# ---------------------------------------------------------------------------
FROM ${PG_IMAGE} AS backup
# 官方镜像自带 bash/coreutils/gzip/tar/postgresql-client；补 curl 供恢复后健康检查
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
COPY docker/backup.sh /usr/local/bin/container-backup.sh
COPY docker/restore.sh /usr/local/bin/container-restore.sh
RUN chmod +x /usr/local/bin/container-backup.sh /usr/local/bin/container-restore.sh
# 默认进入定时循环；一次性任务由 compose command 覆盖
ENTRYPOINT ["/usr/local/bin/container-backup.sh"]
