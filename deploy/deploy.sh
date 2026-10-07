#!/usr/bin/env bash
# 一键部署 / 运维入口（对 docker compose 的薄封装，方便记忆）。
#
#   ./deploy.sh up         构建并启动整套（db→迁移→api→proxy）
#   ./deploy.sh down       停止（数据卷保留，重启后数据还在）
#   ./deploy.sh status     查看服务与健康检查状态
#   ./deploy.sh logs [服务] 跟随日志
#   ./deploy.sh backup     立即执行一次全量备份（库 + 上传目录 + 清单 + DONE）
#   ./deploy.sh list       列出可用备份
#   ./deploy.sh drill      立即执行一次恢复演练（还原到临时库并比对）
#   ./deploy.sh restore <备份目录名>   从备份恢复（会先停 api/proxy）
#   ./deploy.sh migrate    手动执行 prisma migrate deploy
#   ./deploy.sh gc         投递回收站/孤儿文件清理任务
#   ./deploy.sh psql       打开数据库 psql
#   ./deploy.sh config     查看 compose 渲染后的最终配置
set -euo pipefail
cd "$(dirname "$0")/.."

# compose 变量从 deploy/.env.docker 读取（存在的话）；不存在就用 compose 内的默认值
ENV_FILE_ARGS=()
if [ -f deploy/.env.docker ]; then
  ENV_FILE_ARGS=(--env-file deploy/.env.docker)
fi

COMPOSE="docker compose ${ENV_FILE_ARGS[*]}"

# 没有任何 compose 参数时 compose 会自己报错，这里给个中文引导
need_cmd() {
  cat <<'USAGE'
用法：./deploy.sh <命令>
  up        构建镜像并后台启动整套服务
  down      停止并移除容器（命名数据卷保留）
  restart   重启
  status    服务与健康检查状态
  logs      跟随全部/指定服务日志：./deploy.sh logs api
  backup    立即全量备份一次
  list      列出 data 卷中的备份
  drill     立即跑一次恢复演练
  restore   从备份恢复：./deploy.sh restore 2026-10-07-023000
  migrate   手动执行数据库迁移
  gc        清理过期回收站内容与孤儿媒体文件
  psql      进入数据库交互式 psql
  config    查看渲染后的 compose 配置
USAGE
}

cmd="${1:-}"
case "$cmd" in
  up)
    $COMPOSE up -d --build
    echo
    echo "启动完成。查看状态：./deploy.sh status；日志：./deploy.sh logs"
    echo "默认地址：http://localhost:${HTTP_PORT:-8080}（用 deploy/.env.docker 的 HTTP_PORT 可改）"
    ;;
  down)       $COMPOSE down ;;
  restart)    shift; $COMPOSE restart "$@" ;;
  status)     $COMPOSE ps ;;
  logs)       shift; $COMPOSE logs -f --tail=200 "$@" ;;
  config)     $COMPOSE config ;;
  backup)
    shift
    $COMPOSE run --rm --no-deps backup backup "$@"
    echo "备份位于 backups 命名卷内，用 ./deploy.sh list 查看"
    ;;
  list)
    $COMPOSE run --rm --no-deps --entrypoint bash backup -c \
      'ls -1dt /data/backups/*/ 2>/dev/null | while read d; do [ -f "$d/DONE" ] && echo "$(basename "$d")  $(du -sh "$d" | cut -f1)"; done'
    ;;
  drill)
    $COMPOSE run --rm --no-deps backup drill
    ;;
  migrate)
    $COMPOSE run --rm --no-deps api migrate
    ;;
  gc)
    $COMPOSE run --rm --no-deps api gc
    ;;
  psql)
    shift
    $COMPOSE exec db psql -U "${POSTGRES_USER:-heirloom}" -d "${POSTGRES_DB:-heirloom}" "$@"
    ;;
  restore)
    target="${2:-}"
    [ -n "$target" ] || { echo "用法：./deploy.sh restore <备份目录名或完整路径>，可用 ./deploy.sh list 查看"; exit 1; }
    case "$target" in
      /*) ;;
      *) target="/data/backups/$target" ;;
    esac
    echo "==> 恢复会先停止 api 与 proxy（数据库 db 保持运行），并把当前 uploads 改名留存"
    $COMPOSE stop api proxy
    $COMPOSE run --rm --no-deps backup restore "$target"
    echo "==> 恢复完成，重新拉起 api 与 proxy"
    $COMPOSE up -d
    ;;
  ""|-h|--help|help) need_cmd ;;
  *) echo "未知命令：$cmd" >&2; need_cmd; exit 1 ;;
esac
