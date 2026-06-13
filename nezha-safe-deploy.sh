#!/usr/bin/env bash
# 哪吒 v0 Docker 安全部署/修复脚本
#
# 作用：
#   1. 将 /dashboard/data 持久化到宿主机，避免重建容器丢失或换错数据库。
#   2. 通过 Compose override 固定使用 Nginx 反代，保留 client_secret 请求头。
#   3. 每次部署前自动备份数据库和 Compose 配置。
#   4. 部署后检查 SQLite、挂载、Nginx、Supervisor，并进行 gRPC 认证链路测试。
#   5. 默认禁用“每分钟自动还原”，保留每日备份任务，避免远程旧备份覆盖本地数据库。
#
# 默认适配：
#   Compose 目录：/opt/nezha
#   服务名：argo-nezha
#   容器名：nezha_dashboard
#
# 可通过环境变量覆盖，例如：
#   COMPOSE_DIR=/srv/nezha CONTAINER=nezha_dashboard bash nezha-safe-deploy.sh
#   DISABLE_RESTORE_CRON=0 bash nezha-safe-deploy.sh   # 保留自动还原
#   FORCE_IMPORT_FROM_CONTAINER=1 bash nezha-safe-deploy.sh
#   TEST_SERVER_ID=372 bash nezha-safe-deploy.sh

set -Eeuo pipefail
umask 077

COMPOSE_DIR="${COMPOSE_DIR:-/opt/nezha}"
BASE_FILE="${BASE_FILE:-${COMPOSE_DIR}/docker-compose.yml}"
OVERRIDE_FILE="${OVERRIDE_FILE:-${COMPOSE_DIR}/docker-compose.override.yml}"
SERVICE="${SERVICE:-argo-nezha}"
CONTAINER="${CONTAINER:-nezha_dashboard}"

DATA_DIR="${DATA_DIR:-${COMPOSE_DIR}/data-persist}"
BACKUP_DIR="${BACKUP_DIR:-${COMPOSE_DIR}/backups}"

DISABLE_RESTORE_CRON="${DISABLE_RESTORE_CRON:-1}"
FORCE_IMPORT_FROM_CONTAINER="${FORCE_IMPORT_FROM_CONTAINER:-0}"
TEST_SERVER_ID="${TEST_SERVER_ID:-}"
WAIT_SECONDS="${WAIT_SECONDS:-90}"

TS="$(date +%Y%m%d-%H%M%S)"
TMP_DIR="$(mktemp -d)"
DASHBOARD_WAS_STOPPED=0

cleanup() {
    local rc=$?

    rm -rf "$TMP_DIR" 2>/dev/null || true

    # 如果在复制数据期间发生异常，尽量恢复旧容器中的面板进程。
    if [[ "$DASHBOARD_WAS_STOPPED" == "1" ]] &&
       docker inspect "$CONTAINER" >/dev/null 2>&1 &&
       [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == "true" ]]; then
        docker exec "$CONTAINER" supervisorctl start nezha >/dev/null 2>&1 || true
    fi

    exit "$rc"
}
trap cleanup EXIT
trap 'echo "[错误] 第 ${LINENO} 行执行失败。" >&2' ERR

log()  { printf '\033[1;32m[信息]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

[[ "$EUID" -eq 0 ]] || die "请使用 root 运行。"

require_cmd docker
require_cmd tar
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd sha256sum

docker info >/dev/null 2>&1 || die "Docker 未运行或当前用户无法访问 Docker。"
docker compose version >/dev/null 2>&1 || die "未检测到 Docker Compose v2（docker compose）。"

[[ -d "$COMPOSE_DIR" ]] || die "Compose 目录不存在：$COMPOSE_DIR"
[[ -f "$BASE_FILE" ]] || die "找不到基础 Compose 文件：$BASE_FILE"

mkdir -p "$DATA_DIR" "$BACKUP_DIR"
chmod 700 "$DATA_DIR" "$BACKUP_DIR"

COMPOSE=(docker compose -f "$BASE_FILE" -f "$OVERRIDE_FILE")

container_exists() {
    docker inspect "$CONTAINER" >/dev/null 2>&1
}

container_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" == "true" ]]
}

get_image() {
    local image=""

    if container_exists; then
        image="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || true)"
    fi

    if [[ -z "$image" ]]; then
        image="$(docker compose -f "$BASE_FILE" config --images 2>/dev/null | head -n1 || true)"
    fi

    [[ -n "$image" ]] || die "无法确定哪吒容器镜像。"
    printf '%s\n' "$image"
}

check_sqlite_file() {
    local db_path="$1"
    local image="$2"
    local db_dir db_name result

    [[ -s "$db_path" ]] || die "数据库不存在或为空：$db_path"

    db_dir="$(dirname "$db_path")"
    db_name="$(basename "$db_path")"

    result="$(
        docker run --rm \
            --user 0:0 \
            --entrypoint sqlite3 \
            -v "${db_dir}:/db:ro" \
            "$image" \
            "/db/${db_name}" \
            'PRAGMA quick_check;' 2>/dev/null
    )" || die "无法检查数据库：$db_path"

    [[ "$result" == "ok" ]] || die "SQLite 完整性检查失败：${result:-无输出}"
}

backup_configs() {
    local cfg_backup="${BACKUP_DIR}/config-${TS}"
    mkdir -p "$cfg_backup"
    chmod 700 "$cfg_backup"

    cp -a "$BASE_FILE" "$cfg_backup/"
    [[ -f "$OVERRIDE_FILE" ]] && cp -a "$OVERRIDE_FILE" "$cfg_backup/" || true

    log "Compose 配置已备份到：$cfg_backup"
}

backup_persistent_data() {
    if [[ -s "${DATA_DIR}/sqlite.db" ]]; then
        local archive="${BACKUP_DIR}/data-${TS}.tar.gz"
        tar -C "$DATA_DIR" -czf "$archive" .
        chmod 600 "$archive"
        log "现有持久化数据已备份到：$archive"
    fi
}

import_data_from_container() {
    local should_import=0
    local was_running=0

    if [[ "$FORCE_IMPORT_FROM_CONTAINER" == "1" ]]; then
        should_import=1
    elif [[ ! -s "${DATA_DIR}/sqlite.db" ]]; then
        should_import=1
    fi

    if [[ "$should_import" != "1" ]]; then
        log "检测到宿主机持久化数据库，继续使用：${DATA_DIR}/sqlite.db"
        return
    fi

    container_exists || die "宿主机没有持久化数据库，且容器 $CONTAINER 不存在，无法导入数据。"

    log "准备从当前容器导出 /dashboard/data。"

    if container_running; then
        was_running=1
        docker exec "$CONTAINER" supervisorctl stop nezha >/dev/null
        DASHBOARD_WAS_STOPPED=1
    fi

    # FORCE 模式下先清空目标目录，但保留目录本身。
    if [[ "$FORCE_IMPORT_FROM_CONTAINER" == "1" ]]; then
        find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi

    docker cp "${CONTAINER}:/dashboard/data/." "${DATA_DIR}/"

    rm -f "${DATA_DIR}/sqlite.db-wal" "${DATA_DIR}/sqlite.db-shm"
    chmod 700 "$DATA_DIR"
    [[ -f "${DATA_DIR}/sqlite.db" ]] && chmod 600 "${DATA_DIR}/sqlite.db"

    if [[ "$was_running" == "1" ]]; then
        docker exec "$CONTAINER" supervisorctl start nezha >/dev/null
        DASHBOARD_WAS_STOPPED=0
    fi

    log "容器数据库已导出到：$DATA_DIR"
}

write_override() {
    local tmp_override="${TMP_DIR}/docker-compose.override.yml"

    cat > "$tmp_override" <<EOF
services:
  ${SERVICE}:
    environment:
      - REVERSE_PROXY_MODE=nginx
    volumes:
      - "${DATA_DIR}:/dashboard/data"
EOF

    install -m 600 "$tmp_override" "$OVERRIDE_FILE"
    log "已写入永久修复配置：$OVERRIDE_FILE"
}

validate_compose() {
    "${COMPOSE[@]}" config > "${TMP_DIR}/merged-compose.yml" ||
        die "Compose 合并配置无效。"

    grep -q 'REVERSE_PROXY_MODE: nginx' "${TMP_DIR}/merged-compose.yml" ||
        die "合并配置中没有 REVERSE_PROXY_MODE=nginx。"

    grep -q '/dashboard/data' "${TMP_DIR}/merged-compose.yml" ||
        die "合并配置中没有 /dashboard/data 持久化挂载。"

    log "Compose 合并配置检查通过。"
}

wait_for_container() {
    local i

    for ((i=1; i<=WAIT_SECONDS; i++)); do
        if container_running; then
            return 0
        fi
        sleep 1
    done

    docker compose -f "$BASE_FILE" -f "$OVERRIDE_FILE" logs --tail 100 "$SERVICE" >&2 || true
    die "容器在 ${WAIT_SECONDS} 秒内未进入 running 状态。"
}

disable_restore_cron() {
    [[ "$DISABLE_RESTORE_CRON" == "1" ]] || {
        warn "已按要求保留每分钟自动还原任务。"
        return
    }

    # 只注释自动还原，不影响每天的 backup.sh。
    docker exec "$CONTAINER" sh -lc '
        if [ -f /etc/crontab ]; then
            cp -a /etc/crontab /etc/crontab.before-nezha-safe-deploy 2>/dev/null || true
            awk '\''
                index($0, "/dashboard/restore.sh a") && $0 !~ /^[[:space:]]*#/ {
                    print "# disabled by nezha-safe-deploy: " $0
                    next
                }
                { print }
            '\'' /etc/crontab > /tmp/crontab.nezha
            cat /tmp/crontab.nezha > /etc/crontab
            rm -f /tmp/crontab.nezha
            service cron restart >/dev/null 2>&1 || true
        fi
    '

    log "已禁用每分钟自动还原任务；每日 backup.sh 任务保持不变。"
}

verify_runtime() {
    local mount_source env_value db_result status_output
    local expected_data_dir

    expected_data_dir="$(readlink -f "$DATA_DIR")"

    mount_source="$(
        docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/dashboard/data"}}{{.Source}}{{end}}{{end}}' \
        "$CONTAINER"
    )"

    [[ "$(readlink -f "$mount_source")" == "$expected_data_dir" ]] ||
        die "/dashboard/data 挂载来源不正确：${mount_source:-未挂载}"

    env_value="$(
        docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" |
        sed -n 's/^REVERSE_PROXY_MODE=//p' |
        tail -n1
    )"

    [[ "$env_value" == "nginx" ]] ||
        die "容器中的 REVERSE_PROXY_MODE 不是 nginx：${env_value:-未设置}"

    db_result="$(
        docker exec "$CONTAINER" sqlite3 /dashboard/data/sqlite.db 'PRAGMA quick_check;'
    )"

    [[ "$db_result" == "ok" ]] ||
        die "容器内 SQLite 检查失败：${db_result:-无输出}"

    docker exec "$CONTAINER" nginx -t >/dev/null 2>&1 ||
        die "Nginx 配置检查失败。"

    docker exec "$CONTAINER" sh -lc \
        'grep -RqsE "underscores_in_headers[[:space:]]+on" /etc/nginx' ||
        die "Nginx 未启用 underscores_in_headers on。"

    status_output="$(docker exec "$CONTAINER" supervisorctl status 2>&1)"
    printf '%s\n' "$status_output"

    printf '%s\n' "$status_output" | grep -Eq '^nezha[[:space:]]+RUNNING' ||
        die "nezha 进程未运行。"
    printf '%s\n' "$status_output" | grep -Eq '^argo[[:space:]]+RUNNING' ||
        die "argo 进程未运行。"
    printf '%s\n' "$status_output" | grep -Eq '^grpcproxy[[:space:]]+RUNNING' ||
        die "grpcproxy 进程未运行。"

    docker exec "$CONTAINER" sh -lc 'pgrep -x nginx >/dev/null' ||
        die "未检测到 Nginx 进程。"

    log "运行状态、数据库、Nginx 与持久化挂载检查通过。"
}

grpc_auth_test() {
    local domain cip server_id secret hdr body headers rc

    if ! command -v curl >/dev/null 2>&1; then
        warn "宿主机没有 curl，跳过 gRPC 认证链路测试。"
        return
    fi

    if ! curl -V 2>/dev/null | grep -q 'HTTP2'; then
        warn "宿主机 curl 不支持 HTTP/2，跳过 gRPC 认证链路测试。"
        return
    fi

    domain="$(
        docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER" |
        sed -n 's/^ARGO_DOMAIN=//p' |
        tail -n1
    )"

    cip="$(
        docker inspect -f \
        '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
        "$CONTAINER" |
        awk 'NF {print; exit}'
    )"

    [[ -n "$domain" && -n "$cip" ]] || {
        warn "无法取得 ARGO_DOMAIN 或容器 IP，跳过 gRPC 测试。"
        return
    }

    server_id="$TEST_SERVER_ID"
    if [[ -z "$server_id" ]]; then
        server_id="$(
            docker exec "$CONTAINER" sqlite3 /dashboard/data/sqlite.db \
            'SELECT id FROM servers WHERE deleted_at IS NULL ORDER BY id LIMIT 1;'
        )"
    fi

    [[ -n "$server_id" ]] || {
        warn "数据库中没有可用于测试的服务器记录，跳过 gRPC 测试。"
        return
    }

    secret="$(
        docker exec "$CONTAINER" sqlite3 /dashboard/data/sqlite.db \
        "SELECT secret FROM servers WHERE id=${server_id} AND deleted_at IS NULL LIMIT 1;"
    )"

    [[ -n "$secret" ]] || {
        warn "服务器 ID=${server_id} 没有有效密钥，跳过 gRPC 测试。"
        return
    }

    hdr="${TMP_DIR}/grpc-header"
    body="${TMP_DIR}/grpc-body"
    headers="${TMP_DIR}/grpc-response-headers"

    printf 'client_secret: %s\n' "$secret" > "$hdr"
    printf '\0\0\0\0\0' > "$body"
    chmod 600 "$hdr" "$body" "$headers" 2>/dev/null || true

    set +e
    curl -skS --http2 --max-time 5 \
        --resolve "${domain}:443:${cip}" \
        -H 'content-type: application/grpc' \
        -H 'te: trailers' \
        -H @"$hdr" \
        --data-binary @"$body" \
        -D "$headers" \
        -o /dev/null \
        "https://${domain}/proto.NezhaService/RequestTask"
    rc=$?
    set -e

    unset secret

    if grep -qiE '^grpc-status:[[:space:]]*16([[:space:]]|$)' "$headers"; then
        cat "$headers" >&2
        die "gRPC 测试仍返回客户端认证失败。"
    fi

    if [[ "$rc" -eq 28 ]]; then
        log "gRPC RequestTask 流保持至测试超时，client_secret 已正常通过 Nginx。"
        return
    fi

    if [[ "$rc" -eq 0 ]]; then
        log "gRPC 请求未返回认证失败，链路测试通过。"
        return
    fi

    cat "$headers" >&2 || true
    die "gRPC 链路测试失败，curl 退出码：$rc"
}

main() {
    local image

    log "开始处理哪吒 v0 容器：$CONTAINER"
    log "Compose 目录：$COMPOSE_DIR"

    backup_configs
    backup_persistent_data
    import_data_from_container

    image="$(get_image)"
    check_sqlite_file "${DATA_DIR}/sqlite.db" "$image"
    log "部署前 SQLite 完整性检查通过。"

    write_override
    validate_compose

    log "开始重建容器，并固定使用 Nginx 反代。"
    "${COMPOSE[@]}" up -d --force-recreate "$SERVICE"

    wait_for_container

    # 尽快关闭自动还原，避免远程旧备份覆盖持久化数据库。
    disable_restore_cron

    # 等待 Supervisor 中的服务启动。
    sleep 8

    verify_runtime
    grpc_auth_test

    log "修复及安全重部署完成。"
    log "以后请使用同一脚本重部署，或执行："
    printf '  docker compose -f %q -f %q up -d --force-recreate\n' \
        "$BASE_FILE" "$OVERRIDE_FILE"

    if [[ "$DISABLE_RESTORE_CRON" == "1" ]]; then
        warn "当前已禁用每分钟自动还原；GitHub 每日备份任务仍保留。"
        warn "需要恢复自动还原时，运行：DISABLE_RESTORE_CRON=0 $0"
    fi
}

main "$@"
