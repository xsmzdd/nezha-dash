#!/usr/bin/env bash
# 禁止 Nezha Agent 面板远程命令、在线终端（WebShell）和文件管理
# 不修改系统 OpenSSH；Agent 的监控上报仍可继续。
set -Eeuo pipefail
IFS=$'\n\t'

VERSION="1.0.0"
LOCK_CONFIG=1
STOP_AGENT=0
ASSUME_YES=0

usage() {
  cat <<'EOF'
用法：
  sudo bash disable_nezha_agent_remote_shell.sh [选项]

选项：
  --yes             不再询问，直接执行
  --no-lock-config  不对 config.yml 设置 immutable；面板以后可能重新改回配置
  --stop-agent      停止并禁用 Agent（最强隔离，但服务器将停止向面板上报）
  -h, --help        显示帮助

默认行为：
  1. 备份 Agent 配置和 systemd 服务文件；
  2. 禁止面板命令执行、在线终端和文件管理；
  3. 保留 Agent 监控上报；
  4. 对 YAML 配置设置 immutable，防止面板远程改回；
  5. 重启并验证 Agent。
EOF
}

log()  { printf '\033[1;34m[信息]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[成功]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --no-lock-config) LOCK_CONFIG=0 ;;
    --stop-agent) STOP_AGENT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
  shift
done

if (( EUID != 0 )); then
  die "请使用 root 运行：sudo bash $0 --yes"
fi

command -v systemctl >/dev/null 2>&1 || die "系统未使用 systemd，当前脚本无法自动处理。"

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="/root/nezha-agent-lockdown-${TS}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

mapfile -t UNITS < <(
  systemctl list-unit-files --type=service --no-legend 2>/dev/null |
  awk '$1 ~ /^nezha-agent([^[:space:]]*)\.service$/ {print $1}' |
  sort -u
)

# 某些旧安装的 unit 没被 list-unit-files 正常列出。
for candidate in nezha-agent.service nezha.service; do
  if systemctl cat "$candidate" >/dev/null 2>&1; then
    found=0
    for u in "${UNITS[@]:-}"; do [[ "$u" == "$candidate" ]] && found=1; done
    (( found )) || UNITS+=("$candidate")
  fi
done

((${#UNITS[@]} > 0)) || die "没有找到 Nezha Agent systemd 服务。"

printf '将处理以下服务：\n'
printf '  - %s\n' "${UNITS[@]}"

if (( STOP_AGENT )); then
  warn "已选择 --stop-agent：Agent 将停止上报监控数据。"
else
  log "将保留监控上报，只关闭面板远程控制能力。"
fi

if (( ! ASSUME_YES )); then
  read -r -p "确认继续？输入 YES：" answer
  [[ "$answer" == "YES" ]] || die "用户取消。"
fi

MANIFEST="$BACKUP_DIR/manifest.txt"
: > "$MANIFEST"
CONFIGS_CHANGED=()
UNITS_CHANGED=()
ACTIVE_BEFORE=()

backup_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local dst="$BACKUP_DIR${src}"
  mkdir -p "$(dirname "$dst")"
  cp -a -- "$src" "$dst"
  printf '%s\n' "$src" >> "$MANIFEST"
}

get_proc_args() {
  local unit="$1" pid
  pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) && [[ -r "/proc/$pid/cmdline" ]]; then
    tr '\0' '\n' < "/proc/$pid/cmdline"
  fi
}

get_config_from_args() {
  local -a args=("$@")
  local i arg
  for ((i=0; i<${#args[@]}; i++)); do
    arg="${args[$i]}"
    case "$arg" in
      -c|--config)
        if (( i + 1 < ${#args[@]} )); then
          printf '%s\n' "${args[$((i+1))]}"
          return 0
        fi
        ;;
      --config=*)
        printf '%s\n' "${arg#--config=}"
        return 0
        ;;
    esac
  done
  return 1
}

has_legacy_server_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -s|--server|-p|--password|--client-secret) return 0 ;;
    esac
  done
  return 1
}

set_yaml_disable() {
  local cfg="$1"
  backup_file "$cfg"

  # 若此前设置过 immutable，先临时移除。
  if command -v lsattr >/dev/null 2>&1 && command -v chattr >/dev/null 2>&1; then
    if lsattr -d "$cfg" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then
      chattr -i "$cfg" || die "无法移除 $cfg 的 immutable 属性。"
    fi
  fi

  python3 - "$cfg" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
raw = p.read_text(encoding="utf-8", errors="surrogateescape")
lines = raw.splitlines(keepends=True)

pattern = re.compile(r"^disable_command_execute\s*:")
out = []
replaced = False

for line in lines:
    # 只处理 YAML 顶层字段，避免误改注释或嵌套字段。
    if line and not line[0].isspace() and pattern.match(line):
        if not replaced:
            newline = "\n" if line.endswith("\n") else ""
            out.append("disable_command_execute: true" + newline)
            replaced = True
        # 删除重复的同名顶层键
        continue
    out.append(line)

if not replaced:
    if out and not out[-1].endswith("\n"):
        out[-1] += "\n"
    out.append("disable_command_execute: true\n")

tmp = p.with_name(p.name + ".nezha-lockdown.tmp")
tmp.write_text("".join(out), encoding="utf-8", errors="surrogateescape")
tmp.chmod(p.stat().st_mode & 0o7777)
tmp.replace(p)
PY

  chown root:root "$cfg" 2>/dev/null || true
  chmod 600 "$cfg" 2>/dev/null || true

  if (( LOCK_CONFIG )); then
    if command -v chattr >/dev/null 2>&1; then
      if chattr +i "$cfg" 2>/dev/null; then
        ok "已锁定配置文件，面板无法远程改回：$cfg"
      else
        warn "文件系统不支持 chattr +i，配置已修改但未锁定：$cfg"
      fi
    else
      warn "系统没有 chattr，配置已修改但未锁定：$cfg"
    fi
  fi

  CONFIGS_CHANGED+=("$cfg")
}

append_legacy_flag_to_unit() {
  local fragment="$1"
  backup_file "$fragment"

  python3 - "$fragment" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
lines = p.read_text(encoding="utf-8", errors="surrogateescape").splitlines(keepends=True)
out = []
i = 0
changed = False
in_service = False

while i < len(lines):
    line = lines[i]
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        in_service = (stripped.lower() == "[service]")

    if in_service and re.match(r"^\s*ExecStart=", line) and "nezha-agent" in line:
        block = [line]
        while block[-1].rstrip("\n").rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            block.append(lines[i])

        joined = "".join(block)
        if "--disable-command-execute" not in joined:
            last = block[-1]
            nl = "\n" if last.endswith("\n") else ""
            body = last[:-1] if nl else last
            block[-1] = body.rstrip() + " --disable-command-execute" + nl
            changed = True
        out.extend(block)
    else:
        out.append(line)
    i += 1

if not changed:
    if any("--disable-command-execute" in x for x in lines):
        sys.exit(0)
    raise SystemExit("没有找到可修改的 Nezha Agent ExecStart 行")

tmp = p.with_name(p.name + ".nezha-lockdown.tmp")
tmp.write_text("".join(out), encoding="utf-8", errors="surrogateescape")
tmp.chmod(p.stat().st_mode & 0o7777)
tmp.replace(p)
PY
  UNITS_CHANGED+=("$fragment")
}

# 先记录服务状态。
for unit in "${UNITS[@]}"; do
  if systemctl is-active --quiet "$unit"; then
    ACTIVE_BEFORE+=("$unit")
  fi
done

if (( STOP_AGENT )); then
  for unit in "${UNITS[@]}"; do
    systemctl stop "$unit" || true
    systemctl disable "$unit" || true
    systemctl mask "$unit" || true
    ok "已停止、禁用并屏蔽：$unit"
  done
else
  for unit in "${UNITS[@]}"; do
    log "处理服务：$unit"

    fragment="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
    [[ -n "$fragment" && -f "$fragment" ]] || die "找不到 $unit 的服务文件。"

    mapfile -t proc_args < <(get_proc_args "$unit")
    if ((${#proc_args[@]} == 0)); then
      # 服务未运行时，从 unit 中提取足够用于判断的文本；不在终端打印，避免泄露密钥。
      mapfile -t proc_args < <(
        systemctl cat "$unit" 2>/dev/null |
        sed -n 's/^[[:space:]]*ExecStart=//p' |
        tr ' ' '\n'
      )
    fi

    binary=""
    if ((${#proc_args[@]} > 0)); then
      binary="${proc_args[0]}"
    fi
    if [[ -z "$binary" || ! -x "$binary" ]]; then
      pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
      if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )); then
        binary="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
      fi
    fi

    config_path="$(get_config_from_args "${proc_args[@]}" 2>/dev/null || true)"
    if [[ -z "$config_path" && -n "$binary" ]]; then
      default_cfg="$(dirname "$binary")/config.yml"
      if [[ -f "$default_cfg" ]] && ! has_legacy_server_args "${proc_args[@]}"; then
        config_path="$default_cfg"
      fi
    fi

    if has_legacy_server_args "${proc_args[@]}"; then
      # 老版本直接通过 -s/-p 启动，使用启动参数禁用远程控制。
      help_text=""
      if [[ -x "$binary" ]]; then
        help_text="$(timeout 8 "$binary" --help 2>&1 || true)"
      fi
      if grep -q -- '--disable-command-execute' <<<"$help_text"; then
        append_legacy_flag_to_unit "$fragment"
        ok "已为旧版 Agent 添加 --disable-command-execute：$unit"
      else
        die "$unit 使用旧版命令行配置，但当前二进制未显示支持 --disable-command-execute。请先升级 Agent，或使用 --stop-agent 完全停止。"
      fi
    elif [[ -n "$config_path" && -f "$config_path" ]]; then
      set_yaml_disable "$config_path"
      ok "已写入 disable_command_execute: true：$config_path"
    else
      # 再尝试常见配置文件。
      found_cfg=""
      for cfg in \
        /opt/nezha/agent/config.yml \
        /opt/nezha/agent/config.yaml \
        /etc/nezha/config.yml \
        /etc/nezha/config.yaml \
        /opt/nezha/config.yml \
        /opt/nezha/config.yaml
      do
        if [[ -f "$cfg" ]]; then found_cfg="$cfg"; break; fi
      done
      if [[ -n "$found_cfg" ]]; then
        set_yaml_disable "$found_cfg"
        ok "已写入 disable_command_execute: true：$found_cfg"
      else
        die "无法确定 $unit 使用的配置方式；为避免破坏服务，已停止处理。备份目录：$BACKUP_DIR"
      fi
    fi
  done

  systemctl daemon-reload

  for unit in "${UNITS[@]}"; do
    # 原来运行中的服务才重启；原来停止的服务保持停止。
    restart_it=0
    for active in "${ACTIVE_BEFORE[@]:-}"; do
      [[ "$active" == "$unit" ]] && restart_it=1
    done
    if (( restart_it )); then
      systemctl restart "$unit"
      sleep 2
      systemctl is-active --quiet "$unit" || {
        journalctl -u "$unit" -n 30 --no-pager >&2 || true
        die "$unit 重启失败。备份目录：$BACKUP_DIR"
      }
      ok "服务已重启并保持运行：$unit"
    else
      log "$unit 原本未运行，保持停止状态。"
    fi
  done
fi

echo
echo "========== 验证结果 =========="

if (( STOP_AGENT )); then
  failed=0
  for unit in "${UNITS[@]}"; do
    if systemctl is-active --quiet "$unit"; then
      warn "$unit 仍在运行"
      failed=1
    else
      ok "$unit 已停止"
    fi
  done
  (( failed == 0 )) || die "仍有 Agent 服务运行。"
  ok "Agent 已完全隔离，无法通过面板打开终端或执行命令。"
else
  verified=0

  for cfg in "${CONFIGS_CHANGED[@]:-}"; do
    if grep -Eq '^disable_command_execute:[[:space:]]*true([[:space:]]*(#.*)?)?$' "$cfg"; then
      ok "配置验证通过：$cfg"
      verified=$((verified + 1))
    else
      warn "配置验证失败：$cfg"
    fi
  done

  for unit in "${UNITS[@]}"; do
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 0 )) && [[ -r "/proc/$pid/cmdline" ]]; then
      if tr '\0' '\n' < "/proc/$pid/cmdline" | grep -qx -- '--disable-command-execute'; then
        ok "启动参数验证通过：$unit"
        verified=$((verified + 1))
      fi
    fi
  done

  (( verified > 0 )) || die "未能验证禁用状态，请检查备份目录：$BACKUP_DIR"

  echo
  ok "Nezha Agent 面板远程命令、在线终端和文件管理已禁用。"
  log "系统 OpenSSH 没有被修改，你仍可正常使用自己的 SSH 连接。"
  log "Agent 的监控数据上报继续运行。"
fi

echo
log "备份目录：$BACKUP_DIR"
log "恢复 YAML 配置前，若文件被锁定，请先执行：chattr -i /路径/config.yml"
