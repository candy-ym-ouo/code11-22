#!/usr/bin/env bash
# 恢复：停写入 → 还原数据库 → 还原上传目录 → 校验 → 健康检查
# 用法：bash scripts/restore.sh data/backups/2026-10-05-023000
set -euo pipefail

DIR="${1:-}"
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

[ -n "$DIR" ] || fail "用法：bash scripts/restore.sh <备份目录>"
[ -d "$DIR" ] || fail "备份目录不存在：$DIR"
[ -f "$DIR/DONE" ] || fail "该目录没有 DONE 标记，可能是没完成的备份，已中止"
[ -s "$DIR/db.dump" ] || fail "缺少 db.dump"
[ -s "$DIR/uploads.tar.gz" ] || fail "缺少 uploads.tar.gz"

require_db

HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${API_PORT:-4000}/readyz}"
if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
  warn "检测到 API 正在运行（$HEALTH_URL）。恢复期间若有写入，数据会被覆盖。"
  warn "建议先停掉服务：Ctrl+C 或 systemctl stop heirloom"
  if [ -t 0 ]; then
    printf '确认继续？(y/N) '
    read -r answer
    [ "$answer" = "y" ] || fail "已取消"
  else
    warn "非交互模式，继续执行"
  fi
fi

info "第 1 步：还原数据库（--clean --if-exists）"
if ! pg_restore -d "$PG_URL" --clean --if-exists --no-owner --no-privileges < "$DIR/db.dump"; then
  warn "pg_restore 返回非零退出码（通常是「对象不存在」之类的告警），继续校验"
fi

UPLOADS_BASE="$(basename "$UPLOADS_DIR")"
info "第 2 步：还原上传目录（当前目录改名为 ${UPLOADS_BASE}.before-restore.<时间戳>）"
if [ -d "$UPLOADS_DIR" ]; then
  mv "$UPLOADS_DIR" "$(dirname "$UPLOADS_DIR")/${UPLOADS_BASE}.before-restore.$(date +%s)"
fi
mkdir -p "$UPLOADS_DIR"
# 包内顶层目录统一叫 uploads；当前存储目录基名若不同则做一层路径转换
if [ "$UPLOADS_BASE" = "uploads" ]; then
  tar -xzf "$DIR/uploads.tar.gz" -C "$(dirname "$UPLOADS_DIR")"
else
  tar -xzf "$DIR/uploads.tar.gz" --transform "s#^uploads#$UPLOADS_BASE#" -C "$(dirname "$UPLOADS_DIR")"
fi

info "第 3 步：校验（条数 + 媒体抽样 sha256）"
if [ -f "$ROOT_DIR/apps/api/dist/scripts/verify-restore.js" ]; then
  node "$ROOT_DIR/apps/api/dist/scripts/verify-restore.js" --backup "$DIR"
else
  ( cd "$ROOT_DIR/apps/api" && pnpm exec tsx src/scripts/verify-restore.ts --backup "$DIR" )
fi

info "第 4 步：健康检查"
if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
  curl -fsS "$HEALTH_URL" && echo
else
  warn "API 当前没有运行，恢复完成后请重新启动：pnpm start"
fi
info "恢复完成。确认数据无误后可以删除 $(dirname "$UPLOADS_DIR")/${UPLOADS_BASE}.before-restore.* 释放空间。"
