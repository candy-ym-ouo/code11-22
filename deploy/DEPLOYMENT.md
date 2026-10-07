# 一键部署（Docker Compose）

整套应用由四个容器组成，数据全部放在 Docker **命名卷**里，镜像无状态、可随时重建：

| 服务 | 镜像 | 职责 | 持久化卷 |
| --- | --- | --- | --- |
| `db` | `postgres:16-bookworm` | PostgreSQL 16，仅对内网开放 | `pgdata` |
| `api` | `heirloom-app`（本仓构建） | API、后台 worker、启动时自动迁移 | `uploads` `exports` `secrets` |
| `backup` | 复用 `heirloom-app` | 每日 02:30 全量备份 + 每周恢复演练 | `uploads`(读) `backups` |
| `proxy` | `heirloom-proxy`（本仓构建） | Caddy：静态托管前端 + 反代 API | — |

```
宿主机 :8080 ──► proxy(Caddy) ──► 静态文件 /srv/web（apps/web/dist）
                            └──► /api /healthz /readyz → api:4000 ──► db:5432
```

## 前置要求

- Docker Engine 24+ 与 Docker Compose v2（`docker compose version` 可看到版本）
- 首次构建需要联网（拉基础镜像、pnpm 装依赖、Prisma/Postgres 客户端）
- 磁盘：预留至少 2 倍媒体目录大小（上传文件 + 备份副本）

## 起一套（约 3~8 分钟，取决于网络）

```bash
# 可选：修改对外端口、数据库密码、JWT_SECRET
cp deploy/.env.docker.example deploy/.env.docker
$EDITOR deploy/.env.docker

./deploy.sh up              # 等价 docker compose up -d --build
./deploy.sh status          # 全部 healthy 后访问 http://localhost:8080
```

启动顺序由健康检查门控：`db` 健康检查通过后 `api` 才启动；`api` 的 `/readyz`
（数据库、存储卷可写、worker 未卡死）通过后 `proxy` 才接入流量。首个注册用户
自动成为系统管理员。

镜像构建内容：

1. `build` 阶段：`pnpm install --frozen-lockfile` → 构建 shared → `prisma generate` → 构建 api/web；
2. `app` 目标：Node 20 slim + ffmpeg + postgresql-client-16 + tini，拷入构建产物；
3. `proxy` 目标：Caddy 2.8 + 前端 `dist` 静态产物。

## 数据卷与可恢复性

```bash
docker volume ls | grep heirloom        # pgdata / uploads / exports / backups / secrets
docker run --rm -v heirloom_pgdata:/v alpine du -sh /v   # 查看占用
```

- `pgdata`：数据库整目录；`uploads`：sha256 内容寻址的媒体文件；二者构成全部业务数据。
- `backups`：每日 `db.dump`（pg_dump 自定义格式）+ `uploads.tar.gz` + `manifest.json` + `DONE`。
  **只有出现 `DONE` 的备份才允许恢复**，恢复脚本会拒绝半截文件。
- `secrets`：未显式配置 `JWT_SECRET` 时，自动生成的密钥存这里（重建容器会话不丢）。
- `docker compose down` **不删卷**；只有 `down -v` 才会删，生产中永远不要加 `-v`。

### 备份与恢复

```bash
./deploy.sh backup                 # 立即手动备份一次
./deploy.sh list                   # 列出 backups 卷中的完整备份
./deploy.sh drill                  # 恢复演练：还原到临时库并比对条数/媒体 sha256
./deploy.sh restore 2026-10-07-023000   # 从指定备份恢复
```

`restore` 会自动：停 `api`/`proxy`（`db` 保持运行）→ `pg_restore --clean --if-exists`
还原数据库 → 当前 uploads 改名为 `uploads.before-restore.<时间戳>` 后解包 →
跑条数 + 媒体抽样 sha256 校验 → 重新拉起服务。恢复是幂等的，旧上传目录会保留在
`uploads` 卷中，确认无误后可手动删除。

每周日的自动演练报告写在 `backups` 卷的 `/drill-reports/` 下；
**演练通过才说明备份真的能恢复。**

### 把备份复制到卷外（异地副本）

```bash
# 导出某一份备份到宿主机当前目录
docker run --rm -v heirloom_backups:/data/backups -v "$PWD":/out alpine \
  sh -c 'cp -a /data/backups/2026-10-07-023000 /out/'

# 卷外备份灌回卷内（同名目录）后再执行 ./deploy.sh restore
docker run --rm -v heirloom_backups:/data/backups -v "$PWD":/out alpine \
  sh -c 'cp -a /out/2026-10-07-023000 /data/backups/'
```

### 整机/新机器恢复流程

1. 拿到同一份代码（相同版本）与 `deploy/.env.docker`（尤其 `JWT_SECRET`、数据库密码）；
2. 若 `pgdata` 卷也没了：把备份目录灌进新建的 `heirloom_backups` 卷（命令见上）；
3. `./deploy.sh up`（空库会自动迁移）→ `./deploy.sh restore <备份目录>`；
4. `./deploy.sh status` 与 `docker compose exec backup drill` 双重确认。

## 升级

```bash
git pull
./deploy.sh up          # 自动重建镜像；api 启动时执行 prisma migrate deploy
```

迁移只进不退（Prisma deploy 语义）。大版本升级前先 `./deploy.sh backup`；
若想单独控制迁移时机：把 `MIGRATE_ON_START=false` 写入 `deploy/.env.docker`，
部署后手动 `./deploy.sh migrate`。

## 健康检查与排障

| 检查 | 位置 | 含义 |
| --- | --- | --- |
| pg_isready | `db` 容器 | 数据库可连接 |
| `/healthz` | `api` / `proxy` | 进程存活 |
| `/readyz` | `api` | DB 可查 + 存储卷可写探针 + worker 未卡死（10 分钟阈值） |
| 心跳文件 | `backup` | 调度循环 60 秒刷新，90 分钟无更新判不健康 |

```bash
./deploy.sh logs api          # 跟随某个服务日志
docker compose exec api node -e "fetch('http://127.0.0.1:4000/readyz').then(r=>r.json()).then(console.log)"
./deploy.sh psql              # 直接进库排查
```

## 安全边界与运行身份

- `db` **不映射宿主机端口**：只有同一 compose 网络内的 `api`/`backup` 能连，数据库不会暴露到局域网。
- 只暴露 `proxy` 一个端口（默认 8080）；`api` 的 4000 端口仅内网可达。
- 镜像已把 `/data`、`/secrets` 预 chown 给 `node(uid 1000)`。编排默认以 root 运行
  （单租户自托管，与 README 里 systemd 裸跑同一威胁模型）；若要以非 root 运行，
  在 `api` 和 `backup` 服务下加 `user: "1000:1000"` 即可（卷属主已就绪），
  `proxy` 已固定以非 root（uid 1001）运行。
- 生产务必改 `POSTGRES_PASSWORD`、显式设置 `JWT_SECRET`，上公网时打开 `COOKIE_SECURE`。

## 上公网（域名 + HTTPS）

1. `deploy/.env.docker` 设置 `APP_URL=https://你的域名`、`COOKIE_SECURE=true`、`HTTP_PORT=443`；
2. 把 `deploy/Caddyfile` 的站点地址 `:8080` 改成你的域名，并将全局块里的
   `auto_https off` 删除、compose 端口映射改为 `443:443`（可再补 `80:80` 做跳转）。
   Caddy 会自动向 Let's Encrypt 申请并续期证书；
3. `./deploy.sh up`。

反向代理已配置：`client_max_body_size` 等效上限 210MB（≥ 最大音频 200MB +
multipart 开销）、流式转发关闭缓冲（音频 Range 拖动）、`X-Forwarded-*` 透传、
静态 `assets/*` 一年 immutable 缓存、`index.html` 不缓存（SPA 即时更新）。

## 备份/演练时间表调整

改 `deploy/.env.docker` 后 `docker compose up -d backup` 即可：
`BACKUP_HOUR`/`BACKUP_MIN` 调整每日时刻，`DRILL_WEEKDAY` 选演练日（置空关闭），
`BACKUP_RETENTION_DAYS` 控制保留份数，`BACKUP_ON_START=true` 可在容器启动时立即补一次。
