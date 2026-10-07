#!/bin/bash
# 容器内定时备份（backup 服务的默认入口）。
#
# 与宿主机 scripts/backup.sh 产出格式完全一致，保证两条恢复路径互通：
#   /backups/<时间戳>/  db.dump + uploads.tar.gz + manifest.json + DONE
# 只有写完 DONE 才算一份完整备份；恢复只认带 DONE 的目录。
#
# 环境变量：
#   PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE   备份目标库（compose 已注入）
#   UPLOADS_DIR        上传文件卷挂载点，默认 /uploads
#   BACKUP_DIR        备份卷挂载点，默认 /backups
#   EXPORT_DIR         导出文件卷挂载点（可选，默认 /exports，存在才一并打包）
#   BACKUP_ONCE        设为 1 时备份一次即退出（供手动 / 一次性任务使用）
#   BACKUP_CRON        非空则用 cron 表达式调度（需 super-cron，未装）；
#                      默认按 BACKUP_TIME（每日 HH:MM，默认 02:30，容器时区）轮询
#   BACKUP_RETENTION_DAYS  保留份数上限，默认 14
#   TZ                 时区，默认 Asia/Shanghai
set -euo pipefail

export TZ="${TZ:-Asia/Shanghai}"
UPLOADS_DIR="${UPLOADS_DIR:-/uploads}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
EXPORT_DIR="${EXPORT_DIR:-/exports}"
RETENTION="${BACKUP_RETENTION_DAYS:-14}"
BACKUP_TIME="${BACKUP_TIME:-02:30}"
PGPORT="${PGPORT:-5432}"

export PGPASSWORD="${PGPASSWORD:-}"

log() { printf '[backup %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"; }
die() { printf '[backup FATAL] %s\n' "$1" >&2; exit 1; }

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

wait_db() {
    local i
    for i in $(seq 1 60); do
        if pg_isready -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    die "60 秒内连不上数据库 ${PGHOST}:${PGPORT}/${PGDATABASE}"
}

pg_query() {
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc "$1" | tr -d '[:space:]'
}

do_backup() {
    local stamp dir items media users families migration
    stamp="$(date +%Y-%m-%d-%H%M%S)"
    dir="$BACKUP_DIR/$stamp"
    mkdir -p "$dir"
    rm -f "$dir/DONE" 2>/dev/null || true

    log "导出数据库 → db.dump"
    pg_dump -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -Fc > "$dir/db.dump"
    [ -s "$dir/db.dump" ] || die "数据库备份为空"

    log "打包上传目录 → uploads.tar.gz"
    # uploads 是唯一不可再生的用户数据；exports 由 worker 按需重建，不纳入备份
    mkdir -p "$UPLOADS_DIR"
    tar -czf "$dir/uploads.tar.gz" -C "$(dirname "$UPLOADS_DIR")" "$(basename "$UPLOADS_DIR")"

    log "写入 manifest.json"
    items="$(pg_query 'select count(*) from items')"
    media="$(pg_query 'select count(*) from item_media')"
    users="$(pg_query 'select count(*) from users')"
    families="$(pg_query 'select count(*) from families where deleted_at is null')"
    migration="$(pg_query 'select migration_name from _prisma_migrations order by finished_at desc nulls last limit 1')"

    cat > "$dir/manifest.json" <<JSON
{
  "app": "家中物品来历册",
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "container": "$(hostname)",
  "database": "postgresql://${PGUSER}:***@${PGHOST}:${PGPORT}/${PGDATABASE}",
  "migration": "${migration}",
  "counts": { "users": ${users:-0}, "families": ${families:-0}, "items": ${items:-0}, "media": ${media:-0} },
  "files": {
    "db.dump": { "sha256": "$(sha256_of "$dir/db.dump")", "bytes": $(wc -c < "$dir/db.dump" | tr -d ' ') },
    "uploads.tar.gz": { "sha256": "$(sha256_of "$dir/uploads.tar.gz")", "bytes": $(wc -c < "$dir/uploads.tar.gz" | tr -d ' ') }
  }
}
JSON

    date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/DONE"
    log "备份完成：$dir（条目 ${items:-0} / 媒体 ${media:-0} / 家庭 ${families:-0}，$(du -sh "$dir" | awk '{print $1}')）"

    prune_old
}

prune_old() {
    # 按时间排序，只保留最近 $RETENTION 份「带 DONE」的完整备份；不完整的立即清理
    local count=0 d
    while IFS= read -r d; do
        if [ ! -f "$d/DONE" ]; then
            log "清理未完成备份：$d"
            rm -rf "$d"
            continue
        fi
        count=$((count + 1))
        if [ "$count" -gt "$RETENTION" ]; then
            log "清理过期备份：$d"
            rm -rf "$d"
        fi
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
             | sort -rn | awk '{print $2}')
}

wait_db

if [ "${BACKUP_ONCE:-0}" = "1" ]; then
    do_backup
    exit 0
fi

# 每日轮询：到达 BACKUP_TIME 且今天还没备份过就执行；启动后若当天时间已过，立刻补一份
log "定时备份服务已启动，每日 ${BACKUP_TIME}（${TZ}）执行，保留 ${RETENTION} 份"
last_done_date=""
while true; do
    today="$(date +%Y-%m-%d)"
    now="$(date +%H%M)"
    hhmm="${BACKUP_TIME%%:*}"; mmhh="${BACKUP_TIME##*:}"
    target="$((10#$hhmm * 60 + 10#$mmhh))"
    nowmin="$((10#${now%??} * 60 + 10#${now#??}))"
    if [ "$today" != "$last_done_date" ] && [ "$nowmin" -ge "$target" ]; then
        if do_backup; then last_done_date="$today"; fi
    fi
    # 每 60 秒醒一次，足够精确到分钟
    sleep 60
done
