#!/usr/bin/env bash
# 恢复演练：把最新备份还原到临时库，比对条数与媒体 sha256，并生成演练报告。
# 这个脚本是「备份真的能恢复」的证据来源，建议每月跑一次。
set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

require_db

DRILL_DB="heirloom_drill_$$"
REPORT_DIR="${DRILL_REPORT_ROOT:-$ROOT_DIR/docs}"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/恢复演练报告-$(date +%Y%m%d-%H%M%S).md"
DRILL_URL="$(pg_url_on "$DRILL_DB")"

# 1. 取最新一份完整备份；没有就现做一份
BACKUP_DIR=""
for d in $(ls -1dt "$BACKUPS_DIR"/*/ 2>/dev/null); do
  if [ -f "$d/DONE" ]; then BACKUP_DIR="$d"; break; fi
done
if [ -z "$BACKUP_DIR" ]; then
  info "没有可用备份，先执行一次备份"
  bash "$ROOT_DIR/scripts/backup.sh" >/dev/null
  BACKUP_DIR="$(ls -1dt "$BACKUPS_DIR"/*/ 2>/dev/null | head -1)"
fi
info "使用备份：$BACKUP_DIR"

cleanup() {
  # createdb/dropdb 的位置参数会被当成「库名」，所以连接信息要用 --maintenance-db 传
  dropdb --if-exists --maintenance-db="$PG_URL" "$DRILL_DB" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 2. 建临时库并还原
info "创建临时库 $DRILL_DB 并还原备份"
dropdb --if-exists --maintenance-db="$PG_URL" "$DRILL_DB" >/dev/null 2>&1 || true
createdb --maintenance-db="$PG_URL" "$DRILL_DB"
pg_restore -d "$DRILL_URL" --no-owner --no-privileges < "$BACKUP_DIR/db.dump" >/dev/null 2>&1 || true

# 3. 比对条数
PROD_ITEMS="$(pg_query 'select count(*) from items')"
DRILL_ITEMS="$(pg_query_on "$DRILL_DB" 'select count(*) from items')"
PROD_MEDIA="$(pg_query 'select count(*) from item_media')"
DRILL_MEDIA="$(pg_query_on "$DRILL_DB" 'select count(*) from item_media')"
PROD_USERS="$(pg_query 'select count(*) from users')"
DRILL_USERS="$(pg_query_on "$DRILL_DB" 'select count(*) from users')"

# 4. 抽样校验媒体文件 sha256（库里的值与磁盘文件对得上）
info "抽样校验媒体文件完整性"
SAMPLE_FILE="${TMPDIR:-/tmp}/heirloom-drill-sample.$$"
psql "$PG_URL" -tAc \
  "select id || '|' || sha256 || '|' || storage_key from item_media order by random() limit 10" > "$SAMPLE_FILE"
CHECKED=0
MISMATCH=0
MISSING=0
DETAIL=""
while IFS='|' read -r _mid sha key; do
  [ -n "${key:-}" ] || continue
  file="$UPLOADS_DIR/$key"
  if [ ! -f "$file" ]; then
    MISSING=$((MISSING + 1))
    DETAIL="$DETAIL\n- 文件缺失：$key"
    continue
  fi
  actual="$(file_sha256 "$file")"
  CHECKED=$((CHECKED + 1))
  if [ "$actual" != "$sha" ]; then
    MISMATCH=$((MISMATCH + 1))
    DETAIL="$DETAIL\n- 校验不一致：$key"
  fi
done < "$SAMPLE_FILE"
rm -f "$SAMPLE_FILE"

VERDICT="通过"
[ "$PROD_ITEMS" = "$DRILL_ITEMS" ] || VERDICT="失败"
[ "$PROD_MEDIA" = "$DRILL_MEDIA" ] || VERDICT="失败"
[ "$PROD_USERS" = "$DRILL_USERS" ] || VERDICT="失败"
[ "$MISMATCH" -eq 0 ] || VERDICT="失败"
[ "$MISSING" -eq 0 ] || VERDICT="失败"

{
  echo "# 恢复演练报告"
  echo
  echo "- 演练时间：$(date '+%Y-%m-%d %H:%M:%S')"
  echo "- 使用备份：\`$BACKUP_DIR\`"
  echo "- 临时库：\`$DRILL_DB\`（演练结束后已删除）"
  echo "- 结论：**$VERDICT**"
  echo
  echo "## 条数比对"
  echo
  echo "| 表 | 生产库 | 恢复库 | 一致 |"
  echo "| --- | --- | --- | --- |"
  if [ "$PROD_USERS" = "$DRILL_USERS" ]; then U_OK="✅"; else U_OK="❌"; fi
  if [ "$PROD_ITEMS" = "$DRILL_ITEMS" ]; then I_OK="✅"; else I_OK="❌"; fi
  if [ "$PROD_MEDIA" = "$DRILL_MEDIA" ]; then M_OK="✅"; else M_OK="❌"; fi
  echo "| users | $PROD_USERS | $DRILL_USERS | $U_OK |"
  echo "| items | $PROD_ITEMS | $DRILL_ITEMS | $I_OK |"
  echo "| item_media | $PROD_MEDIA | $DRILL_MEDIA | $M_OK |"
  echo
  echo "## 媒体文件抽样校验（sha256）"
  echo
  echo "- 实际校验文件数：$CHECKED"
  echo "- 校验不一致：$MISMATCH"
  echo "- 文件缺失：$MISSING"
  if [ -n "$DETAIL" ]; then printf '%b\n' "$DETAIL"; fi
  echo
  echo "## 备份文件清单"
  echo
  echo '```'
  ls -lh "$BACKUP_DIR" | sed 's/^/  /'
  echo '```'
} > "$REPORT"

info "演练报告：$REPORT"
echo "  条数：users $PROD_USERS → $DRILL_USERS / items $PROD_ITEMS → $DRILL_ITEMS / media $PROD_MEDIA → $DRILL_MEDIA"
echo "  媒体抽样：校验 $CHECKED 个，不一致 $MISMATCH，缺失 $MISSING"

if [ "$VERDICT" != "通过" ]; then
  fail "恢复演练未通过，请查看报告"
fi
info "恢复演练通过"
