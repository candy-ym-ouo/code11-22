#!/usr/bin/env bash
# 定时备份调度器（容器内常驻，替代系统 cron）。
#
# 每天 BACKUP_HOUR:BACKUP_MIN（容器时区，默认 Asia/Shanghai 02:30）跑一次全量备份；
# 若当天是 DRILL_WEEKDAY（默认周日），备份成功后追加一次恢复演练。
# 每分钟刷新 /tmp/backup-scheduler.heartbeat，供 compose healthcheck 判定存活。
#
# 所有失败只告警不退出：下一个调度周期会自动重试。
set -euo pipefail

export LC_ALL=C
HOUR="${BACKUP_HOUR:-2}"
MINUTE="${BACKUP_MIN:-30}"
DRILL_WEEKDAY="${DRILL_WEEKDAY:-Sun}"
DRILL_ON_SUCCESS="${DRILL_ON_SUCCESS:-true}"

log()  { printf '\033[1m[%s]\033[0m %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '\033[33m[%s][warn]\033[0m %s\n' "$(date '+%F %T')" "$*" >&2; }

HEARTBEAT=/tmp/backup-scheduler.heartbeat
touch "$HEARTBEAT"

run_backup() {
  log "定时备份开始"
  if bash /app/scripts/backup.sh; then
    log "定时备份完成"
  else
    warn "定时备份失败（退出码 $?），下个周期重试"
    return 0
  fi

  if [ "$DRILL_ON_SUCCESS" = "true" ] && [ -n "$DRILL_WEEKDAY" ] && [ "$(date +%a)" = "$DRILL_WEEKDAY" ]; then
    log "今天是 $DRILL_WEEKDAY，追加恢复演练"
    if bash /app/scripts/drill.sh; then
      log "恢复演练完成"
    else
      warn "恢复演练失败（退出码 $?），请查看 $DRILL_REPORT_ROOT 下的报告"
    fi
  fi
}

# 收到 SIGTERM 干净退出（compose stop 不会等 10 秒超时）
running=1
trap 'running=0; log "收到退出信号，停止调度"' SIGTERM SIGINT

if [ "${BACKUP_ON_START:-false}" = "true" ]; then
  run_backup || true
fi

LAST_RUN=""
while [ "$running" -eq 1 ]; do
  touch "$HEARTBEAT"
  TODAY="$(date +%F)"
  NOW_HM="$(date +%H%M)"
  TARGET_HM="$(printf '%02d%02d' "$HOUR" "$MINUTE")"

  # 只在「今天还没跑过」且「已过目标时刻」时触发；错过（如容器当时重启）
  # 会在恢复后尽快补跑一次。
  if [ "$LAST_RUN" != "$TODAY" ] && [ "$NOW_HM" -ge "$TARGET_HM" ]; then
    LAST_RUN="$TODAY"
    run_backup || true
  fi

  # 每秒醒一次刷心跳并检查信号；每分钟末重新评估调度时刻
  for _ in $(seq 1 60); do
    [ "$running" -eq 1 ] || break
    sleep 1
  done
done

log "调度器已退出"
