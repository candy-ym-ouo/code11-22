#!/bin/bash
# 等待 PostgreSQL 可连接后再执行迁移命令。
# 依赖：DATABASE_URL（prisma 风格，带 ?schema=public，这里用 pg_isready 时剥离参数）。
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL 未设置}"

# 把 postgresql://user:pass@host:port/db?schema=public 拆成 pg_isready 参数
URL_NO_QUERY="${DATABASE_URL%%\?*}"
PG_HOSTPORT="${URL_NO_QUERY#*@}"
PG_HOSTPORT="${PG_HOSTPORT%%/*}"
PG_HOST="${PG_HOSTPORT%%:*}"
PG_PORT="${PG_HOSTPORT##*:}"
[ "$PG_PORT" = "$PG_HOST" ] && PG_PORT=5432
PG_DB="${URL_NO_QUERY##*/}"

echo "[wait-for-db] 等待 ${PG_HOST}:${PG_PORT}（最多 60 秒）..."
for i in $(seq 1 60); do
    if pg_isready -h "$PG_HOST" -p "$PG_PORT" -d "$PG_DB" >/dev/null 2>&1; then
        echo "[wait-for-db] 数据库已就绪"
        exec "$@"
    fi
    sleep 1
done

echo "[wait-for-db] 等待数据库超时（${PG_HOST}:${PG_PORT}）" >&2
exit 1
