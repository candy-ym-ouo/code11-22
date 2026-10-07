#!/usr/bin/env bash
# heirloom-app 镜像统一入口。
#
# 模式（CMD 第一个参数）：
#   api       等数据库就绪 →（可选）prisma migrate deploy → 启动 API  [默认]
#   migrate   只执行数据库迁移后退出（升级流水线可用）
#   cron      启动定时备份调度循环（backup 服务）
#   backup    立即执行一次全量备份后退出
#   restore   从 <备份目录> 恢复：restore /data/backups/2026-10-07-023000
#   drill     立即执行一次恢复演练后退出
#   gc        投递垃圾清理/回收站清理任务
#   shell     交互式排障
set -euo pipefail

export LC_ALL=C

log()  { printf '\033[1m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

APP_ROOT=/app
cd "$APP_ROOT"

# DATABASE_URL 去掉 ?schema=... 供 libpq 工具使用（libpq 不认识 Prisma 参数）
export PG_URL="${DATABASE_URL%%\?*}"

# ---------- 通用：等数据库就绪 ----------
wait_for_db() {
  local tries="${DB_WAIT_TRIES:-60}"
  log "等待数据库就绪：${PG_URL%%:*}://***"
  for _ in $(seq 1 "$tries"); do
    if pg_isready -d "$PG_URL" >/dev/null 2>&1; then
      log "数据库已就绪"
      return 0
    fi
    sleep 2
  done
  die "数据库在 ${tries} 次探测后仍不可用"
}

# ---------- JWT 密钥：未显式提供时生成并持久化到 secrets 卷 ----------
# 必须保证重启/重建容器后不变，否则所有已登录会话失效。
ensure_jwt_secret() {
  local secret_file="${SECRET_FILE:-/secrets/jwt_secret}"
  if [ -z "${JWT_SECRET:-}" ]; then
    if [ -f "$secret_file" ] && [ -s "$secret_file" ]; then
      JWT_SECRET="$(cat "$secret_file")"
      log "使用已持久化的 JWT_SECRET（$secret_file）"
    else
      mkdir -p "$(dirname "$secret_file")"
      JWT_SECRET="$(openssl rand -hex 32)"
      printf '%s' "$JWT_SECRET" > "$secret_file"
      chmod 600 "$secret_file"
      log "未设置 JWT_SECRET，已生成并持久化到 $secret_file（生产环境建议显式配置并离线另存）"
    fi
    export JWT_SECRET
  fi
}

# ---------- 数据库迁移（Prisma，仅向前，适合生产） ----------
run_migrations() {
  wait_for_db
  log "执行数据库迁移：prisma migrate deploy"
  # 直接调用容器内已安装的 prisma CLI，不依赖网络下载
  node apps/api/node_modules/prisma/build/index.js migrate deploy --schema apps/api/prisma/schema.prisma
}

# 数据目录（与 compose 挂载保持一致；环境变量覆盖后也能在非容器环境排障）
STORAGE_ROOT="${STORAGE_ROOT:-/data/uploads}"
EXPORT_ROOT="${EXPORT_ROOT:-/data/exports}"
BACKUP_ROOT="${BACKUP_ROOT:-/data/backups}"
export STORAGE_ROOT EXPORT_ROOT BACKUP_ROOT
mkdir -p "$STORAGE_ROOT" "$EXPORT_ROOT" "$BACKUP_ROOT"

mode="${1:-api}"
case "$mode" in
  api)
    ensure_jwt_secret
    if [ "${MIGRATE_ON_START:-true}" = "true" ]; then
      run_migrations
    else
      wait_for_db
    fi
    log "启动 API（含前端托管开关 SERVE_WEB=${SERVE_WEB:-true}）"
    exec node apps/api/dist/index.js
    ;;

  migrate)
    ensure_jwt_secret
    run_migrations
    log "迁移完成"
    ;;

  cron)
    exec /usr/local/bin/scheduler
    ;;

  backup)
    wait_for_db
    exec bash scripts/backup.sh "${2:-}"
    ;;

  restore)
    [ -n "${2:-}" ] || die "用法：restore <备份目录>，例如 /data/backups/2026-10-07-023000"
    wait_for_db
    exec bash scripts/restore.sh "$2"
    ;;

  drill)
    wait_for_db
    exec bash scripts/drill.sh
    ;;

  gc)
    wait_for_db
    exec bash scripts/gc.sh
    ;;

  shell)
    exec /bin/bash
    ;;

  *)
    die "未知模式：$mode（支持 api/migrate/cron/backup/restore/drill/gc/shell）"
    ;;
esac
