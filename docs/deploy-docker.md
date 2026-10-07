# 容器化一键部署

不依赖宿主机的 Node / pnpm / PostgreSQL / ffmpeg，只需要 **Docker Engine 24+ 与 Compose v2**。
一条命令完成构建、迁移、启动与就绪检查；数据全部落在命名卷和 `./data/backups`，容器删除重建不丢数据。

## 快速开始（两条命令）

```bash
bash deploy.sh init     # 生成 .env.docker：随机数据库密码 + 64 位 JWT 密钥
bash deploy.sh up       # 构建镜像 → 起数据库 → 跑迁移 → 启动 API/nginx/备份 → 就绪检查
```

打开 <http://localhost:4000>，第一个注册账号自动成为系统管理员。

有域名 / HTTPS 时，先改 `.env.docker`：

```ini
APP_URL=https://heirloom.example.com
COOKIE_SECURE=true
PUBLISHED_PORT=4000        # 或云负载均衡 / Caddy 占用 80/443 时改内部端口
```

TLS 终止交给外层 Caddy / 云 LB / `certbot`，本套编排内部保持明文（compose 网络不对外发布数据库端口）。

## 编排拓扑

```
浏览器 ──▶ web(nginx:80→宿主 ${PUBLISHED_PORT})
             ├── /assets 等静态路径 → 镜像内 /usr/share/nginx/html（前端构建产物）
             ├── /healthz /readyz  ─┐
             └── /api/*             ├─▶ api(node:4000) ──▶ db(postgres:5432)
                                     │       └─ worker（同进程，每日 GC/回收站清理）
                                     └─ 卷：/data/uploads, /data/exports

backup(常驻轮询) ──▶ db（pg_dump）＋ 只读挂 uploads 卷  ──▶ ./data/backups/<时间戳>/
restore(一次性) ──▶ db（pg_restore）＋ uploads 卷（deploy.sh restore 调起）
migrate(一次性) ──▶ db（prisma migrate deploy，成功后 api 才启动）
```

| 服务 | 镜像目标 | 角色 | 数据落点 |
| --- | --- | --- | --- |
| `db` | `postgres:16-bookworm` | 数据库 | 命名卷 `heirloom_pgdata` |
| `migrate` | `Dockerfile::migrate` | 一次性迁移任务，成功退出 | 无 |
| `api` | `Dockerfile::api` | API + worker + 媒体流（非 root、内置 ffmpeg） | 卷 `heirloom_uploads` / `heirloom_exports`，bind `./data/backups` |
| `web` | `Dockerfile::web` | nginx 反向代理 + 前端静态托管 | 无（产物烤进镜像） |
| `backup` | `Dockerfile::backup` | 每日 `BACKUP_TIME` 完整备份 | bind `./data/backups`；uploads 只读挂载 |
| `restore` | 同 backup 镜像 | 一次性恢复（restore profile） | uploads 读写、backups 只读 |

## 数据持久化与可恢复性

- **数据库**：`heirloom_pgdata` 命名卷 = PostgreSQL 完整数据目录。
- **上传媒体**（图片/音频/原稿，不可再生）：`heirloom_uploads` 命名卷，内容寻址存储。
- **导出包**（worker 可重建）：`heirloom_exports` 命名卷。
- **完整备份**：`./data/backups/<时间戳>/`（bind mount，容器外可见、可 rsync 异地）：

```
data/backups/2026-10-07-023000/
├── db.dump           # pg_dump -Fc（自定义格式，支持 --clean 幂等还原）
├── uploads.tar.gz    # 上传目录全量
├── manifest.json     # 条数、迁移版本、每个文件的 sha256
└── DONE              # 完成标记；没有它恢复脚本会拒绝
```

卷位置（Docker Desktop 上在虚拟机磁盘内；Linux 上在 `/var/lib/docker/volumes/`）：

```bash
docker volume inspect heirloom_pgdata heirloom_uploads
```

### 备份

- 自动：`backup` 容器常驻，每日 `BACKUP_TIME`（默认 02:30，遵循 `TZ`）执行，保留 `BACKUP_RETENTION_DAYS`（默认 14）份，未完成的残留目录会被清理。
- 手动：`bash deploy.sh backup`
- 列表：`bash deploy.sh backups`
- 异地保存：直接把 `./data/backups/` 加入既有备份系统（rsync / 网盘 / S3 同步客户端均可），目录自描述、无需任何容器工具即可解读。

### 恢复（已验证可回滚）

```bash
bash deploy.sh restore                 # 恢复最新一份完整备份
bash deploy.sh restore 2026-10-07-023000
```

流程（脚本 `docker/restore.sh`）：

1. 二次确认；**先自动做一份当前状态的保底快照**；
2. 停掉 `api`（无写入方；`db` 与 `nginx` 保持运行）；
3. 检查目标目录的 `DONE` 与 `db.dump` 的 sha256，不符即拒绝；
4. `pg_restore --clean --if-exists` 覆盖还原数据库；
5. 当前 uploads **改名保留**为 `uploads.before-restore.<时间戳>`，再解压备份；
6. 抽样 10 个媒体文件比对库内 sha256 与磁盘文件，不一致/缺失则整体判失败；
7. 重启 `api` 并等待 `/readyz` 通过。

恢复失败时 `api` 保持停止状态，旧目录未被删除，可换备份重试，不会出现"新旧混搭"。

### 灾难重建（新机器）

```bash
# 1. 取回仓库与备份目录（data/backups 放回项目根）
git clone <repo> && cd heirloom
rsync -a backup-host:/srv/backups/ ./data/backups/
# 2. 生成同一份 .env.docker（JWT_SECRET 必须与旧实例一致，否则旧会话失效）
bash deploy.sh init
#   把旧机 .env.docker 拷回来更稳妥（密码、JWT_SECRET 一致才能挂回旧 pgdata）
# 3. 只在「连 pgdata 卷也丢了」时才需要 restore；卷还在则直接 up
bash deploy.sh up
bash deploy.sh restore
```

## 健康检查

| 检查 | 对象 | 含义 |
| --- | --- | --- |
| `db` 容器 healthcheck | `pg_isready` | 数据库接受连接 |
| `api` 容器 healthcheck | `GET /readyz` | DB `SELECT 1` + 存储卷可写探针 + worker 未卡死 |
| `web` 容器 healthcheck | `curl localhost/healthz`（经 nginx → api） | 反代链路与 API 同时存活 |
| `migrate` | 退出码 0 | 迁移成功，否则 `api` 不会启动（compose `service_completed_successfully`） |
| `deploy.sh up` 末尾 | 宿主 `curl /readyz` | 120 秒内未就绪则打印日志并退出非零 |

- `/healthz`：进程存活（不查依赖），适合 Liveness。
- `/readyz`：DB / 存储 / worker 就绪检查，适合 Readiness 与上线门禁。
- 这两个路径不走访问日志（避免探针噪音）。

## 升级

```bash
git pull
bash deploy.sh up
# 等价于：build → 新 migrate 容器执行增量迁移（只前进不回滚）→ 滚动重建 api/web
bash deploy.sh backup     # 升级后顺手再留一份新版本下的备份
```

迁移镜像内置 Prisma schema-engine，运行镜像不携带迁移工具，职责分离。

## 运维命令速查

```bash
bash deploy.sh ps               # 服务状态 + 健康
bash deploy.sh logs api         # 跟踪日志（也可 web / db / backup / migrate）
bash deploy.sh restart api      # 重启单个服务
bash deploy.sh migrate          # 单独再跑一次迁移
bash deploy.sh verify           # 对运行实例跑 63 项闭环断言（scripts/verify-loop.sh）
bash deploy.sh shell            # 进入 api 容器排障
bash deploy.sh down             # 停止（卷与备份保留）
bash deploy.sh prune            # 清理悬挂镜像/构建缓存（不碰数据）
```

需要本机直连数据库（`psql` / Prisma Studio）时，在 `.env.docker` 设：

```ini
DB_PUBLISH_PORT=5432
```

`deploy.sh up` 会生成 `docker-compose.override.yml` 增加端口映射；不用时删掉该变量即可。

## 镜像构建说明

单个 `Dockerfile` 多目标构建：

- `deps`：只拷 package.json / lockfile 后 `pnpm install --frozen-lockfile`，源码变动不击穿依赖缓存；
- `builder`：生成 Prisma Client → 编译 shared → api → web（前端产物随后被 `web` 目标拷入 nginx 镜像）；
- `prod-deps`：`pnpm install --prod --offline` 得到只含生产依赖（含 sharp 原生二进制、Prisma Client）的 node_modules；
- `api`：`node:20-bookworm-slim` + ffmpeg + tini，非 root（uid 1001），不含源码、不含 devDependencies；
- `migrate`：保留完整依赖的构建态，只用于一次性 `migrate deploy`；
- `web`：`nginx:1.27-bookworm`，静态产物烤进镜像，版本与后端同步发布；
- `backup`：`postgres:16-bookworm`（自带 pg_dump/pg_restore 16 客户端）+ 备份恢复脚本。

内网环境可用 build-arg 换源：

```bash
docker build --build-arg NPM_REGISTRY=https://npm.intra \
             --build-arg PRISMA_ENGINES_MIRROR=https://intra/prisma \
             --target api -t heirloom-api:local .
```

## 配置项

容器只识别 `.env.docker`（与本机开发的 `.env` 完全分开），见 `.env.docker.example`。
应用层完整配置含义见根目录 `README.md` 的「配置项」一节；未在 compose 中显式传入的变量保持代码内默认值。
