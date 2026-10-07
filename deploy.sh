#!/usr/bin/env bash
# 家中物品来历册 · 一键部署脚本
#
#   bash deploy.sh init               生成 .env.docker（随机数据库密码 + JWT 密钥）
#   bash deploy.sh build              构建全部镜像（api / migrate / web / backup）
#   bash deploy.sh up                 构建 → 迁移 → 启动 → 就绪检查（核心一键命令）
#   bash deploy.sh down               停止全部容器（数据卷与备份保留）
#   bash deploy.sh restart [服务]      重启（默认全部；可传 api / web ...）
#   bash deploy.sh ps                 查看服务与健康状态
#   bash deploy.sh logs [服务]         跟踪日志
#   bash deploy.sh migrate            手动再跑一次 prisma migrate deploy
#   bash deploy.sh backup             立即执行一次完整备份
#   bash deploy.sh backups            列出已有备份
#   bash deploy.sh restore [时间戳]    从备份恢复（停 api → 恢复 → 起 api → 就绪检查）
#   bash deploy.sh verify             对运行中的实例跑宿主机闭环验证脚本
#   bash deploy.sh shell              进入 api 容器排障
#   bash deploy.sh prune              删除旧镜像与悬挂构建缓存（不动数据）
#
# 数据落点（重启 / 重建容器都不丢）：
#   命名卷 heirloom_pgdata   PostgreSQL 数据目录
#   命名卷 heirloom_uploads  用户上传的图片/音频/原稿
#   命名卷 heirloom_exports  导出 ZIP（可重建）
#   bind    ./data/backups   完整备份（db.dump + uploads.tar.gz），可直接拷走
set -euo pipefail

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"
ENV_FILE="$ROOT_DIR/.env.docker"
OVERRIDE_FILE="$ROOT_DIR/docker-compose.override.yml"
COMPOSE=(docker compose --env-file "$ENV_FILE" -f docker-compose.yml)

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_off=$'\033[0m'
info() { printf '%s[deploy]%s %s\n' "$c_bold" "$c_off" "$1"; }
ok()   { printf '%s[ ok ]%s %s\n' "$c_green" "$c_off" "$1"; }
warn() { printf '%s[warn]%s %s\n' "$c_yellow" "$c_off" "$1"; }
die()  { printf '%s[fatal]%s %s\n' "$c_red" "$c_off" "$1" >&2; exit 1; }

need_env() {
    [ -f "$ENV_FILE" ] || die "缺少 .env.docker，先执行：bash deploy.sh init"
    local jwt
    jwt="$(env_get JWT_SECRET || true)"
    [ -n "$jwt" ] || die ".env.docker 缺少 JWT_SECRET，请重新执行 bash deploy.sh init（或手动 openssl rand -hex 32）"
    local pw
    pw="$(env_get POSTGRES_PASSWORD || true)"
    [ -n "$pw" ] && [ "$pw" != change-me-please ] \
        || die ".env.docker 的 POSTGRES_PASSWORD 未修改，请重新执行 bash deploy.sh init"
}

ensure_docker() {
    docker version >/dev/null 2>&1 || die "docker 不可用，请先安装并启动 Docker Engine / Docker Desktop"
    docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose 子命令）"
}

# 从 .env.docker 读取单个键（值里不含空格/特殊符号，source 即可）
env_get() {
    local key="$1" line
    line="$(grep -E "^${key}=" "$ENV_FILE" | tail -1 || true)"
    printf '%s' "${line#*=}"
}

cmd_init() {
    if [ -f "$ENV_FILE" ]; then
        warn ".env.docker 已存在，保留不动（如需重新生成请先手动删除）"
        return
    fi
    [ -f .env.docker.example ] || die "缺少 .env.docker.example"
    cp .env.docker.example "$ENV_FILE"

    local pg_pw jwt
    pg_pw="$(openssl rand -hex 16)"
    jwt="$(openssl rand -hex 32)"
    # macOS sed 与 GNU sed 兼容写法
    sed -i.bak "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${pg_pw}/" "$ENV_FILE" && rm -f "$ENV_FILE.bak"
    # JWT_SECRET 在示例里是注释行，直接追加
    printf '\n# deploy.sh init 生成于 %s\nJWT_SECRET=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$jwt" >> "$ENV_FILE"

    # 备份目录必须对 api 容器的非 root 用户（uid 1001）可写
    mkdir -p "$ROOT_DIR/data/backups"
    if chown -R 1001:1001 "$ROOT_DIR/data/backups" 2>/dev/null; then
        chmod 0755 "$ROOT_DIR/data/backups"
    else
        # 某些环境（如挂载盘）不允许 chown，退而求其次放开写权限
        warn "chown 1001 data/backups 失败（可能是挂载盘），改用 0777 保证可写"
        chmod 0777 "$ROOT_DIR/data/backups" 2>/dev/null || \
            warn "无法设置 data/backups 权限，如启动报只读请手动执行：chown -R 1001:1001 data/backups"
    fi

    ok "已生成 $ENV_FILE"
    cat <<EOF

  下一步：
    1. 按需编辑 $ENV_FILE（APP_URL / PUBLIC_SIGNUP / 备份时间）
    2. bash deploy.sh up       # 一键构建、迁移、启动
    3. 浏览器打开 $(env_get APP_URL)（默认 http://localhost:4000）

  首个注册账号会自动成为系统管理员。
EOF
}

# 若设置了 DB_PUBLISH_PORT，生成 override 暴露数据库端口；否则清掉旧的
sync_override() {
    local db_port
    db_port="$(env_get DB_PUBLISH_PORT || true)"
    if [ -n "$db_port" ]; then
        cat > "$OVERRIDE_FILE" <<EOF
# deploy.sh 自动生成：DB_PUBLISH_PORT=$db_port 时发布数据库端口到宿主机
services:
  db:
    ports:
      - "${db_port}:5432"
EOF
    else
        rm -f "$OVERRIDE_FILE"
    fi
}

compose() {
    if [ -f "$OVERRIDE_FILE" ]; then
        "${COMPOSE[@]}" -f "$OVERRIDE_FILE" "$@"
    else
        "${COMPOSE[@]}" "$@"
    fi
}

cmd_build() {
    need_env; ensure_docker; sync_override
    info "构建镜像（首次较慢，依赖层已缓存的情况下后续很快）"
    compose build api migrate web backup
    ok "镜像构建完成"
}

cmd_up() {
    need_env; ensure_docker; sync_override

    info "构建镜像"
    compose build api migrate web backup

    info "启动数据库并等待健康"
    compose up -d db
    if ! compose_healthy db 60; then
        compose logs --tail=50 db
        die "数据库 60 秒内未就绪，见上方日志"
    fi

    info "执行数据库迁移（prisma migrate deploy）"
    if ! compose up migrate; then
        compose logs --tail=80 migrate || true
        die "数据库迁移失败，已中止上线（数据未受影响，修复后重试）"
    fi

    info "启动应用与反向代理"
    compose up -d api web backup

    info "等待 API 就绪（/readyz：DB / 存储 / worker）"
    local port; port="$(env_get PUBLISHED_PORT)"; port="${port:-4000}"
    if ! compose_healthy api 50; then
        compose ps
        compose logs --tail=80 api
        die "API 在限定时间内未通过健康检查，见上方日志"
    fi
    # 再给外层 nginx 一点时间，并从宿主机验证完整链路
    local ready="" i
    for i in $(seq 1 20); do
        if curl -fsS "http://127.0.0.1:${port}/readyz" >/dev/null 2>&1; then ready=1; break; fi
        sleep 2
    done
    if [ -z "$ready" ]; then
        compose ps
        compose logs --tail=80 web
        die "经 nginx 的外部访问链路 40 秒内未就绪，见上方日志"
    fi

    echo
    compose ps
    echo
    ok "部署完成：http://127.0.0.1:${port}（/healthz 存活，/readyz 就绪）"
    # 启动后 10 秒内若没有任何完整备份，提醒/自动补一份
    if [ -z "$(ls -1 "$ROOT_DIR"/data/backups/*/DONE 2>/dev/null | head -1)" ]; then
        warn "还没有任何备份。上线后建议立即执行：bash deploy.sh backup"
    fi
}

compose_healthy() {
    local svc="$1" tries="${2:-60}"
    local cid status
    for _ in $(seq 1 "$tries"); do
        cid="$(compose ps -q "$svc" 2>/dev/null | head -1 || true)"
        if [ -n "$cid" ]; then
            status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
            [ "$status" = healthy ] && return 0
        fi
        sleep 1
    done
    return 1
}

cmd_down()   { need_env; sync_override; compose down; ok "已停止（数据卷与 ./data/backups 保留）"; }
cmd_ps()     { need_env; sync_override; compose ps; }
cmd_logs() {
    need_env; sync_override
    if [ "$#" -gt 0 ]; then compose logs -f --tail=100 "$@"; else compose logs -f --tail=100; fi
}
cmd_restart() {
    need_env; sync_override
    if [ "$#" -gt 0 ]; then compose restart "$@"; else compose restart; fi
    ok "已重启 ${*:-全部服务}"
}
cmd_shell()  { need_env; sync_override; compose exec api sh; }

cmd_migrate() {
    need_env; ensure_docker; sync_override
    info "执行 prisma migrate deploy"
    compose up --force-recreate migrate
    ok "迁移完成"
}

cmd_backup() {
    need_env; ensure_docker; sync_override
    info "立即备份（数据库 + 上传目录 + 校验清单）"
    compose build backup
    compose run --rm -e BACKUP_ONCE=1 --no-deps backup
    ok "备份完成，目录：$ROOT_DIR/data/backups"
}

cmd_backups() {
    need_env
    local d count=0
    for d in "$ROOT_DIR"/data/backups/*/; do
        [ -d "$d" ] || continue
        if [ -f "$d/DONE" ]; then
            printf '  %s  %8s  %s\n' "✓" "$(du -sh "$d" | awk '{print $1}')" "$(basename "$d")"
        else
            printf '  %s  %8s  %s\n' "✗" "-" "$(basename "$d")（未完成）"
        fi
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || warn "暂无备份，执行 bash deploy.sh backup 创建第一份"
}

cmd_restore() {
    need_env; ensure_docker; sync_override
    local which="${1:-}"

    info "恢复是破坏性操作，会覆盖当前数据库与上传目录"
    if [ -t 0 ]; then
        printf '确认继续？输入 yes：'
        read -r answer
        [ "$answer" = "yes" ] || die "已取消"
    fi

    # 恢复前自动留一份「当前状态」的保底快照（失败不阻断）
    info "恢复前先备份当前数据（保底快照）"
    compose build backup >/dev/null
    compose run --rm -e BACKUP_ONCE=1 --no-deps backup || warn "保底快照失败，继续恢复"

    info "停止 API（nginx 与 db 保持运行，恢复期间无法写入）"
    compose stop api

    set +e
    if [ -n "$which" ]; then
        compose --profile restore run --rm restore "$which"
    else
        compose --profile restore run --rm restore
    fi
    local rc=$?
    set -e

    if [ "$rc" -ne 0 ]; then
        warn "恢复步骤失败（$rc）。API 保持停止状态，请排查后手动 bash deploy.sh up"
        exit "$rc"
    fi

    info "重新启动 API"
    compose up -d api
    local port; port="$(env_get PUBLISHED_PORT)"; port="${port:-4000}"
    local i ok=""
    for i in $(seq 1 30); do
        if curl -fsS "http://127.0.0.1:${port}/readyz" >/dev/null 2>&1; then ok=1; break; fi
        sleep 3
    done
    if [ -z "$ok" ]; then
        compose logs --tail=80 api
        die "恢复后 API 90 秒内未就绪（数据已还原，请检查日志）"
    fi
    curl -fsS "http://127.0.0.1:${port}/readyz" >/dev/null && echo
    ok "恢复完成，服务已就绪"
}

cmd_verify() {
    need_env
    local port; port="$(env_get PUBLISHED_PORT)"; port="${port:-4000}"
    command -v bash >/dev/null || die "需要 bash"
    info "对 http://127.0.0.1:${port} 跑闭环验证（注册→建档→上传→权限→导出…）"
    API="http://127.0.0.1:${port}" bash scripts/verify-loop.sh
}

cmd_prune() {
    info "清理悬挂镜像与构建缓存（不触碰数据卷与备份）"
    docker image prune -f
    docker builder prune -f
    ok "清理完成"
}

usage() {
    # 打印文件顶部「# 家中物品来历册 · 一键部署脚本」到第一个空注释块结束之间的说明
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        init)    shift; cmd_init "$@" ;;
        build)   shift; cmd_build "$@" ;;
        up)      shift; cmd_up "$@" ;;
        down)    shift; cmd_down "$@" ;;
        restart) shift; cmd_restart "$@" ;;
        ps)      shift; cmd_ps "$@" ;;
        logs)    shift; cmd_logs "$@" ;;
        migrate) shift; cmd_migrate "$@" ;;
        backup)  shift; cmd_backup "$@" ;;
        backups) shift; cmd_backups "$@" ;;
        restore) shift; cmd_restore "$@" ;;
        verify)  shift; cmd_verify "$@" ;;
        shell)   shift; cmd_shell "$@" ;;
        prune)   shift; cmd_prune "$@" ;;
        ""|-h|--help|help) usage ;;
        *) die "未知命令：$cmd（bash deploy.sh help 查看用法）" ;;
    esac
}
main "$@"
