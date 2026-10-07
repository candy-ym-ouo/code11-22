#!/usr/bin/env bash
# 备份：数据库自定义格式 dump + 上传目录打包 + 校验清单 + DONE 完成标记。
# 只有出现 DONE 才视为一次完整备份，避免恢复时拿到半截文件。
#
# 用法：bash scripts/backup.sh [目标目录]
set -euo pipefail

BACKUP_DIR_OVERRIDE="${1:-}"
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_db

STAMP="$(date +%Y-%m-%d-%H%M%S)"
DIR="${BACKUP_DIR_OVERRIDE:-$BACKUPS_DIR/$STAMP}"
mkdir -p "$DIR"
rm -f "$DIR/DONE" 2>/dev/null || true

info "导出数据库 → db.dump"
pg_dump "$PG_URL" -Fc > "$DIR/db.dump"
[ -s "$DIR/db.dump" ] || fail "数据库备份为空，请检查 DATABASE_URL 与数据库状态"

info "打包上传目录 → uploads.tar.gz"
mkdir -p "$UPLOADS_DIR"
tar -czf "$DIR/uploads.tar.gz" -C "$(dirname "$UPLOADS_DIR")" "$(basename "$UPLOADS_DIR")"

info "写入 manifest.json"
ITEMS="$(pg_query 'select count(*) from items')"
MEDIA="$(pg_query 'select count(*) from item_media')"
USERS="$(pg_query 'select count(*) from users')"
FAMILIES="$(pg_query 'select count(*) from families where deleted_at is null')"
MIGRATION="$(pg_query 'select migration_name from _prisma_migrations order by finished_at desc nulls last limit 1')"

cat > "$DIR/manifest.json" <<JSON
{
  "app": "家中物品来历册",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(hostname)",
  "database": "$(printf '%s' "$PG_URL" | sed 's#://[^:]*:[^@]*@#://***:***@#')",
  "migration": "$MIGRATION",
  "counts": { "users": $USERS, "families": $FAMILIES, "items": $ITEMS, "media": $MEDIA },
  "files": {
    "db.dump": { "sha256": "$(file_sha256 "$DIR/db.dump")", "bytes": $(wc -c < "$DIR/db.dump" | tr -d ' ') },
    "uploads.tar.gz": { "sha256": "$(file_sha256 "$DIR/uploads.tar.gz")", "bytes": $(wc -c < "$DIR/uploads.tar.gz" | tr -d ' ') }
  }
}
JSON

date -u +%Y-%m-%dT%H:%M:%SZ > "$DIR/DONE"

info "备份完成：$DIR"
echo "  条目 $ITEMS 条 / 媒体 $MEDIA 个 / 家庭 $FAMILIES 个"
echo "  大小 $(du -sh "$DIR" | awk '{print $1}')"

RETENTION="${BACKUP_RETENTION_DAYS:-30}"
if [ -z "$BACKUP_DIR_OVERRIDE" ]; then
  COUNT=0
  # 只清理「时间戳命名且带 DONE」的备份目录；drill-reports 等其他目录不受影响
  for old in $(ls -1dt "$BACKUPS_DIR"/20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9]*/ 2>/dev/null); do
    [ -f "$old/DONE" ] || continue
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -gt "$RETENTION" ]; then
      info "清理过期备份：$old"
      rm -rf "$old"
    fi
  done
fi
