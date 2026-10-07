#!/bin/sh
# API 容器入口：确保数据卷目录可写，随后交给主进程。
# 容器以非 root（uid 1001）运行；命名卷首启会被 Docker 按镜像内属主初始化，
# 但主机 bind mount 可能是 root 属主，这里尽量自愈，无法修复时给出明确报错。
set -eu

for d in /data/uploads /data/exports /data/backups; do
    if [ ! -d "$d" ]; then
        mkdir -p "$d" 2>/dev/null || {
            echo "[entrypoint] 无法创建 $d，请在宿主机执行：mkdir -p $d && chown -R 1001:1001 $d" >&2
            exit 1
        }
    fi
    if ! touch "$d/.write-test" 2>/dev/null; then
        echo "[entrypoint] 数据目录 $d 不可写。请在宿主机执行：chown -R 1001:1001 $d" >&2
        exit 1
    fi
    rm -f "$d/.write-test"
done

echo "[entrypoint] 启动：$*"
exec "$@"
