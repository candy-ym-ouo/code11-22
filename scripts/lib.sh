#!/usr/bin/env bash
# 运维脚本共用：加载 .env、定位仓库根、数据库连接与统一日志。
# 依赖本机的 psql / pg_dump / pg_restore（PostgreSQL 客户端工具）。
set -euo pipefail

# 统一 locale：避免 macOS 上 perl/tar 的 "Failed to set default locale" 噪音，
# 同时让 sort/ls 的排序在不同机器上保持一致。
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# 数据目录：本机默认 data/，容器里由编排层覆盖为 /data/...
# （STORAGE_ROOT / EXPORT_ROOT / BACKUP_ROOT 与应用 config.ts 的环境变量同名，
# 相对路径按仓库根解析，保证本机直跑和容器内执行行为一致）
_resolve_data_path() { # _resolve_data_path <env值> <默认相对路径>
  local v="${1:-}" def="$2"
  [ -n "$v" ] || v="$def"
  case "$v" in
    /*) printf '%s' "$v" ;;
    *)
      v="$ROOT_DIR/$v"
      # 去掉 "./" 与重复斜杠，让日志和 tar 路径干净（无需 realpath，允许目标尚不存在）
      v="${v//\/.\//\/}"
      while [[ "$v" == *"//"* ]]; do v="${v//\/\//\/}"; done
      printf '%s' "$v"
      ;;
  esac
}
UPLOADS_DIR="$(_resolve_data_path "${STORAGE_ROOT:-}" "data/uploads")"
EXPORTS_DIR="$(_resolve_data_path "${EXPORT_ROOT:-}" "data/exports")"
BACKUPS_DIR="$(_resolve_data_path "${BACKUP_ROOT:-}" "data/backups")"

info() { printf '\033[1m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$1"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$1"; }
fail() { printf '\033[31m[fail]\033[0m %s\n' "$1" >&2; exit 1; }

command -v psql >/dev/null 2>&1 || fail "找不到 psql，请先安装 PostgreSQL 客户端工具（macOS: brew install postgresql@16）"

[ -n "${DATABASE_URL:-}" ] || fail "请在 .env 中配置 DATABASE_URL"

# Prisma 的 URL 带 ?schema=public，libpq 不认识这个参数，连接前要去掉
PG_URL="${DATABASE_URL%%\?*}"
PG_MAINT_URL="$(printf '%s' "$PG_URL" | sed 's#/[^/]*$#/postgres#')"

# 目标数据库是否可连接
require_db() {
  pg_isready -d "$PG_URL" >/dev/null 2>&1 \
    || fail "连不上数据库（$PG_URL）。本地集群可用 bash scripts/pg.sh start 启动"
}

pg_query() {
  psql "$PG_URL" -tAc "$1" | tr -d '[:space:]'
}

pg_url_on() { # pg_url_on <database>
  printf '%s' "$PG_URL" | sed "s#/[^/]*\$#/$1#"
}

pg_query_on() { # pg_query_on <database> <sql>
  psql "$(pg_url_on "$1")" -tAc "$2" | tr -d '[:space:]'
}

file_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
