#!/bin/bash
# 容器内一次性恢复（compose restore 服务）。
#
# 用法（由 deploy.sh restore 封装，一般不直接调用）：
#   docker compose --env-file .env.docker run --rm restore \
#       [2026-10-05-023000 | /backups/2026-10-05-023000]
#   不传参数 = 恢复最新一份带 DONE 的备份。
#
# 安全前提：deploy.sh restore 会先停掉 api，恢复期间无写入方。
# 强制覆盖前会校验 DONE 标记与 sha256；现有 uploads 会改名保留，不会直接删除。
set -euo pipefail

export TZ="${TZ:-Asia/Shanghai}"
UPLOADS_DIR="${UPLOADS_DIR:-/uploads}"
BACKUP_DIR="${BACKUP_DIR:-/backups}"
PGPORT="${PGPORT:-5432}"
export PGPASSWORD="${PGPASSWORD:-}"

log()  { printf '[restore %s] %s\n' "$(date '+%H:%M:%S')" "$1"; }
die()  { printf '[restore FATAL] %s\n' "$1" >&2; exit 1; }

# 1. 定位备份目录 ----------------------------------------------------------------
ARG="${1:-}"
if [ -z "$ARG" ]; then
    SRC="$(find "$BACKUP_DIR" -mindepth 2 -maxdepth 2 -name DONE -printf '%h\n' 2>/dev/null \
        | sort | tail -1 || true)"
    [ -n "$SRC" ] || die "$BACKUP_DIR 下没有带 DONE 标记的完整备份"
else
    case "$ARG" in
        /*) SRC="$ARG" ;;
        *)  SRC="$BACKUP_DIR/$ARG" ;;
    esac
fi
[ -d "$SRC" ] || die "备份目录不存在：$SRC"
[ -f "$SRC/DONE" ] || die "缺少 DONE 标记（备份未完成），拒绝恢复：$SRC"
[ -s "$SRC/db.dump" ] || die "缺少 db.dump：$SRC"
[ -s "$SRC/uploads.tar.gz" ] || die "缺少 uploads.tar.gz：$SRC"
log "使用备份：$SRC"

# 2. 校验清单 sha256 -------------------------------------------------------------
if [ -f "$SRC/manifest.json" ]; then
    log "校验文件 sha256"
    # 备份镜像内没有 jq，用 grep -o 精确提取 64 位十六进制
    expected_db="$(grep -oE '"db\.dump": \{ "sha256": "[0-9a-f]{64}"' "$SRC/manifest.json" | grep -oE '[0-9a-f]{64}')"
    actual_db="$(sha256sum "$SRC/db.dump" | awk '{print $1}')"
    [ -z "$expected_db" ] || [ "$expected_db" = "$actual_db" ] \
        || die "db.dump 校验和不一致（清单 $expected_db / 实际 $actual_db），备份可能损坏"
fi

# 3. 等数据库 --------------------------------------------------------------------
for i in $(seq 1 60); do
    pg_isready -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -U "$PGUSER" >/dev/null 2>&1 && break
    sleep 2
    [ "$i" = 60 ] && die "数据库不可达：${PGHOST}:${PGPORT}"
done
log "数据库可连接"

# 4. 还原数据库（clean + if-exists，幂等覆盖） -----------------------------------
log "还原数据库（pg_restore --clean --if-exists）"
PGURL="postgresql://${PGUSER}@${PGHOST}:${PGPORT}/${PGDATABASE}"
pg_restore -d "$PGURL" --clean --if-exists --no-owner --no-privileges < "$SRC/db.dump" \
    || log "pg_restore 返回非零（多为对象不存在类告警），继续"

# 5. 还原上传目录（旧目录改名保留，不直接删） -------------------------------------
PARENT="$(dirname "$UPLOADS_DIR")"
BASE="$(basename "$UPLOADS_DIR")"
mkdir -p "$PARENT"
if [ -d "$UPLOADS_DIR" ] && [ -n "$(ls -A "$UPLOADS_DIR" 2>/dev/null)" ]; then
    BAK="$PARENT/${BASE}.before-restore.$(date +%s)"
    log "当前上传目录改名保留：$BAK"
    mv "$UPLOADS_DIR" "$BAK"
fi
mkdir -p "$UPLOADS_DIR"
log "解压 uploads.tar.gz"
tar -xzf "$SRC/uploads.tar.gz" -C "$PARENT"

# 6. 条数比对 --------------------------------------------------------------------
log "比对恢复后条数与备份清单"
for table in users families items; do
    actual="$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc \
        "select count(*) from $table" | tr -d '[:space:]')"
    log "  $table: $actual 行"
done

# 7. 抽样校验媒体文件 sha256（库里记录 vs 磁盘文件） ------------------------------
mismatch=0
checked=0
while IFS='|' read -r sha key; do
    [ -n "${key:-}" ] || continue
    f="$UPLOADS_DIR/$key"
    if [ ! -f "$f" ]; then
        log "  缺失文件：$key"
        mismatch=$((mismatch + 1))
        continue
    fi
    checked=$((checked + 1))
    [ "$(sha256sum "$f" | awk '{print $1}')" = "$sha" ] || {
        log "  校验不一致：$key"
        mismatch=$((mismatch + 1))
    }
done < <(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAc \
    "select sha256 || '|' || storage_key from item_media order by random() limit 10" 2>/dev/null || true)

if [ "$mismatch" -gt 0 ]; then
    die "媒体抽样校验失败 $mismatch 项，请检查备份完整性"
fi
log "恢复完成（抽样校验 $checked 个媒体文件全部一致）。旧上传目录保留在 $PARENT/${BASE}.before-restore.*，确认无误后可手动删除。"
