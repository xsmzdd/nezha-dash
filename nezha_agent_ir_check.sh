#!/usr/bin/env bash
# Nezha Agent Linux 入侵痕迹检测脚本
# 只读检测：不会停止服务、删除文件、修改配置或联网。
# 适用：Debian/Ubuntu、RHEL/CentOS/Rocky/Alma、Alpine 等常见 Linux。

set -uo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin

VERSION="1.0.0"
DAYS=30
MAX_ITEMS=120
NO_COLOR=0

usage() {
  cat <<'USAGE'
用法：
  sudo bash nezha_agent_ir_check.sh [选项]

选项：
  -d, --days N       检查最近 N 天，默认 30
  -m, --max N        每一类最多显示 N 条，默认 120
      --no-color     禁用彩色输出
  -h, --help         显示帮助

示例：
  sudo bash nezha_agent_ir_check.sh
  sudo bash nezha_agent_ir_check.sh --days 7
  sudo bash nezha_agent_ir_check.sh -d 90 -m 300

退出码：
  0  未发现明显入侵迹象
  1  发现高置信或可疑入侵迹象
  2  参数错误、权限不足或运行失败
USAGE
}

while (($#)); do
  case "$1" in
    -d|--days)
      [[ $# -ge 2 ]] || { echo "缺少 --days 参数" >&2; exit 2; }
      DAYS="$2"; shift 2 ;;
    -m|--max)
      [[ $# -ge 2 ]] || { echo "缺少 --max 参数" >&2; exit 2; }
      MAX_ITEMS="$2"; shift 2 ;;
    --no-color)
      NO_COLOR=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "未知参数：$1" >&2
      usage
      exit 2 ;;
  esac
done

[[ "$DAYS" =~ ^[0-9]+$ ]] && ((DAYS >= 1 && DAYS <= 3650)) || {
  echo "--days 必须是 1-3650 的整数" >&2; exit 2;
}
[[ "$MAX_ITEMS" =~ ^[0-9]+$ ]] && ((MAX_ITEMS >= 10 && MAX_ITEMS <= 5000)) || {
  echo "--max 必须是 10-5000 的整数" >&2; exit 2;
}

if ((EUID != 0)); then
  echo "本脚本需要 root 权限读取审计日志、SSH 密钥和所有用户目录。"
  echo "请使用：sudo bash $0 --days $DAYS"
  exit 2
fi

if [[ -t 1 && "$NO_COLOR" -eq 0 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'; C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_RED=""; C_YELLOW=""; C_GREEN=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

TMP_ROOT="$(mktemp -d /tmp/nezha-ir.XXXXXX)" || exit 2
trap 'rm -rf -- "$TMP_ROOT"' EXIT INT TERM

START_DATE="$(date -d "$DAYS days ago" '+%Y-%m-%d 00:00:00' 2>/dev/null || date '+%Y-%m-%d 00:00:00')"
NOW="$(date '+%Y-%m-%d %H:%M:%S %z')"

CRITICAL=0
SUSPICIOUS=0
HARDENING=0
INFO_COUNT=0
ERRORS=0

have() { command -v "$1" >/dev/null 2>&1; }

describe_file() {
  local f="$1"
  have file && file -L -- "$f" 2>/dev/null || true
}

hash_file() {
  local f="$1"
  if have sha256sum; then
    sha256sum -- "$f" 2>/dev/null || true
  elif have shasum; then
    shasum -a 256 -- "$f" 2>/dev/null || true
  fi
}

section() {
  printf '\n%s%s== %s ==%s\n' "$C_BOLD" "$C_BLUE" "$1" "$C_RESET"
}

subsection() {
  printf '\n%s-- %s --%s\n' "$C_CYAN" "$1" "$C_RESET"
}

finding() {
  local sev="$1"; shift
  local msg="$*"
  case "$sev" in
    CRITICAL)
      ((CRITICAL++)); printf '%s[严重]%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$msg" ;;
    SUSPICIOUS)
      ((SUSPICIOUS++)); printf '%s[可疑]%s %s\n' "$C_MAGENTA$C_BOLD" "$C_RESET" "$msg" ;;
    HARDENING)
      ((HARDENING++)); printf '%s[风险]%s %s\n' "$C_YELLOW" "$C_RESET" "$msg" ;;
    INFO)
      ((INFO_COUNT++)); printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$msg" ;;
    ERROR)
      ((ERRORS++)); printf '%s[检测失败]%s %s\n' "$C_RED" "$C_RESET" "$msg" ;;
  esac
}

print_limited_file() {
  local file="$1" max="${2:-$MAX_ITEMS}"
  [[ -s "$file" ]] || return 1
  sed -n "1,${max}p" "$file"
  local count
  count="$(wc -l < "$file" 2>/dev/null || echo 0)"
  if [[ "$count" =~ ^[0-9]+$ ]] && ((count > max)); then
    echo "... 已截断，共 $count 条；可用 --max 增大显示上限"
  fi
}

stat_line() {
  local f="$1"
  stat -Lc '%A %a %U:%G size=%s mtime=%y ctime=%z path=%n' -- "$f" 2>/dev/null || \
    stat -c '%A %a %U:%G size=%s mtime=%y ctime=%z path=%n' -- "$f" 2>/dev/null || true
}

is_recent_file() {
  local f="$1"
  find "$f" -maxdepth 0 -newermt "$START_DATE" -print -quit 2>/dev/null | grep -q .
}

redact_config() {
  sed -E \
    -e 's/^([[:space:]]*(client_secret|agent_secret|agent_secret_key|token|password|passwd|secret)[[:space:]]*:[[:space:]]*).*/\1<REDACTED>/I' \
    -e 's/(NZ_CLIENT_SECRET=)[^[:space:]"]+/\1<REDACTED>/Ig' \
    "$1" 2>/dev/null
}

key_value_yaml() {
  local key="$1" file="$2"
  awk -v k="$key" '
    BEGIN{IGNORECASE=1}
    $0 !~ /^[[:space:]]*#/ {
      line=$0
      sub(/[[:space:]]+#.*/, "", line)
      if (line ~ "^[[:space:]]*" k "[[:space:]]*:") {
        sub("^[[:space:]]*" k "[[:space:]]*:[[:space:]]*", "", line)
        gsub(/^["]|["]$/, "", line)
        print line; exit
      }
    }' "$file" 2>/dev/null
}

package_owner() {
  local f="$1"
  if have dpkg-query; then
    dpkg-query -S "$f" 2>/dev/null | head -n1 | cut -d: -f1
  elif have rpm; then
    rpm -qf "$f" 2>/dev/null | head -n1
  elif have apk; then
    apk info --who-owns "$f" 2>/dev/null | head -n1
  fi
}

get_uid_min() {
  local n
  n="$(awk '$1=="UID_MIN"{print $2; exit}' /etc/login.defs 2>/dev/null || true)"
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 1000
}

collect_auth_logs() {
  local out="$1"
  : > "$out"
  if have journalctl; then
    journalctl --since "$START_DATE" --no-pager -o short-iso \
      -u ssh.service -u sshd.service -u systemd-logind.service 2>/dev/null >> "$out" || true
  fi
  local f
  for f in /var/log/auth.log /var/log/auth.log.1 /var/log/secure /var/log/secure-???????? /var/log/messages; do
    [[ -r "$f" ]] || continue
    cat -- "$f" 2>/dev/null >> "$out" || true
  done
}

collect_nezha_units() {
  local out="$1"
  : > "$out"
  if have systemctl; then
    {
      systemctl list-unit-files --type=service --no-legend 2>/dev/null
      systemctl list-units --all --type=service --no-legend 2>/dev/null
    } | awk '{print $1}' | grep -Ei 'nezha.*agent|agent.*nezha' | sort -u > "$out" || true
  fi
}

get_nezha_pids() {
  local out="$1"
  : > "$out"
  local p exe cmd
  for p in /proc/[0-9]*; do
    [[ -r "$p/cmdline" ]] || continue
    exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null || true)"
    if [[ "${exe,,}" == *nezha*agent* || "${cmd,,}" == *nezha-agent* || "${cmd,,}" == *'/opt/nezha/agent/'* ]]; then
      basename "$p"
    fi
  done | sort -n -u > "$out"
}

descendants_of() {
  local root="$1" out="$2"
  : > "$out"
  local -a queue=("$root")
  local current child
  local seen=" $root "
  while ((${#queue[@]})); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    while read -r child; do
      [[ "$child" =~ ^[0-9]+$ ]] || continue
      [[ "$seen" == *" $child "* ]] && continue
      seen+="$child "
      echo "$child" >> "$out"
      queue+=("$child")
    done < <(pgrep -P "$current" 2>/dev/null || true)
  done
}

looks_suspicious_command() {
  grep -Eqi '(^|[ /])(xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|watchbog|watchdogd|dpkgd)([ /]|$)|/dev/shm|/var/tmp|/tmp/\.|curl.+\|[[:space:]]*(ba)?sh|wget.+\|[[:space:]]*(ba)?sh|base64[[:space:]]+-d|chattr[[:space:]]+\+i|authorized_keys|useradd|adduser|usermod|nohup|setsid|systemctl[[:space:]]+(enable|start).*(image-search|xmrig)|stratum\+tcp|pool\.[^ ]+:[0-9]+'
}

printf '%s%sNezha Agent Linux 入侵痕迹检测 v%s%s\n' "$C_BOLD" "$C_BLUE" "$VERSION" "$C_RESET"
printf '主机：%s  时间：%s  检查窗口：最近 %s 天（自 %s）\n' "$(hostname -f 2>/dev/null || hostname)" "$NOW" "$DAYS" "$START_DATE"
echo "模式：只读；不停止服务、不删除文件、不修改系统、不访问互联网。"

section "1. 系统与哪吒 Agent 基线"
uname -a 2>/dev/null || true
[[ -r /etc/os-release ]] && { . /etc/os-release; echo "系统：${PRETTY_NAME:-unknown}"; }
echo "启动时间：$(uptime -s 2>/dev/null || who -b 2>/dev/null | sed 's/^[[:space:]]*//')"

UNITS_FILE="$TMP_ROOT/nezha_units"
PIDS_FILE="$TMP_ROOT/nezha_pids"
collect_nezha_units "$UNITS_FILE"
get_nezha_pids "$PIDS_FILE"

if [[ ! -s "$UNITS_FILE" && ! -s "$PIDS_FILE" ]]; then
  finding INFO "未发现正在运行或已注册的 nezha-agent；仍继续检查历史入侵痕迹。"
else
  finding INFO "发现哪吒 Agent 服务或进程。"
fi

if [[ -s "$UNITS_FILE" ]]; then
  subsection "Agent systemd 服务"
  while read -r unit; do
    [[ -n "$unit" ]] || continue
    echo "[$unit]"
    systemctl show "$unit" -p LoadState -p ActiveState -p SubState -p MainPID -p User \
      -p FragmentPath -p ExecStart -p ActiveEnterTimestamp --no-pager 2>/dev/null || true
  done < "$UNITS_FILE"
fi

if [[ -s "$PIDS_FILE" ]]; then
  subsection "Agent 进程、二进制与当前连接"
  while read -r pid; do
    [[ -d "/proc/$pid" ]] || continue
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    echo "PID=$pid EXE=$exe"
    echo "CMD=$cmd"
    [[ -f "$exe" ]] && {
      stat_line "$exe"
      hash_file "$exe"
      "$exe" -v 2>&1 | head -n2 || true
    }
    if have ss; then
      ss -Hntp 2>/dev/null | grep -E "pid=$pid([,\)])" || true
    elif have lsof; then
      lsof -nP -a -p "$pid" -i 2>/dev/null || true
    fi

    DESC_FILE="$TMP_ROOT/desc_$pid"
    descendants_of "$pid" "$DESC_FILE"
    if [[ -s "$DESC_FILE" ]]; then
      finding SUSPICIOUS "nezha-agent 当前存在子进程；可能是面板远程命令、终端或文件操作产生。"
      while read -r cpid; do
        ps -p "$cpid" -o pid=,ppid=,user=,lstart=,%cpu=,%mem=,args= 2>/dev/null || true
      done < "$DESC_FILE"
    fi
  done < "$PIDS_FILE"
fi

subsection "Agent 配置文件"
CONFIGS_FILE="$TMP_ROOT/configs"
: > "$CONFIGS_FILE"
find /opt/nezha /etc/nezha /usr/local/nezha /root/.nezha -type f \
  \( -iname 'config*.yml' -o -iname 'config*.yaml' \) -print 2>/dev/null >> "$CONFIGS_FILE" || true
while read -r pid; do
  [[ -r "/proc/$pid/cmdline" ]] || continue
  tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -E '^/.*\.ya?ml$' >> "$CONFIGS_FILE" || true
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  [[ -n "$exe" && -f "$(dirname "$exe")/config.yml" ]] && echo "$(dirname "$exe")/config.yml" >> "$CONFIGS_FILE"
done < "$PIDS_FILE"
if have systemctl; then
  while read -r unit; do
    [[ -n "$unit" ]] || continue
    systemctl show "$unit" -p ExecStart --value 2>/dev/null       | grep -Eo '/[^ ;"{}]+\.ya?ml' >> "$CONFIGS_FILE" || true
    unit_exec="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null       | grep -Eo 'path=/[^ ;{}]+' | head -n1 | cut -d= -f2- || true)"
    [[ -n "$unit_exec" && -f "$(dirname "$unit_exec")/config.yml" ]]       && echo "$(dirname "$unit_exec")/config.yml" >> "$CONFIGS_FILE"
  done < "$UNITS_FILE"
fi
sort -u -o "$CONFIGS_FILE" "$CONFIGS_FILE"

if [[ ! -s "$CONFIGS_FILE" ]]; then
  finding INFO "未找到常见路径下的 Agent YAML 配置。"
else
  while read -r cfg; do
    [[ -r "$cfg" ]] || continue
    echo "[$cfg]"
    stat_line "$cfg"
    redact_config "$cfg" | grep -Ei '^[[:space:]]*(server|tls|insecure_tls|debug|disable_command_execute|disable_force_update|disable_auto_update|disable_nat|uuid)[[:space:]]*:' || true

    dce="$(key_value_yaml disable_command_execute "$cfg" | tr '[:upper:]' '[:lower:]')"
    tls="$(key_value_yaml tls "$cfg" | tr '[:upper:]' '[:lower:]')"
    itls="$(key_value_yaml insecure_tls "$cfg" | tr '[:upper:]' '[:lower:]')"
    server="$(key_value_yaml server "$cfg")"

    if [[ "$dce" != "true" ]]; then
      finding HARDENING "$cfg 未明确启用 disable_command_execute: true；面板可下发命令、终端或文件任务。"
    else
      finding INFO "$cfg 已禁用面板命令执行。"
    fi
    [[ "$tls" == "false" ]] && finding HARDENING "$cfg 配置 tls: false，Agent 与面板通信可能未加密。"
    [[ "$itls" == "true" ]] && finding HARDENING "$cfg 配置 insecure_tls: true，证书校验被关闭。"
    [[ -n "$server" ]] && echo "面板地址：$server"
    if is_recent_file "$cfg"; then
      finding HARDENING "Agent 配置在最近 $DAYS 天内发生过内容或时间戳变更，请核对变更来源：$cfg"
    fi
  done < "$CONFIGS_FILE"
fi

subsection "Agent 日志中的任务、终端、文件传输和异常"
NEZHA_LOG="$TMP_ROOT/nezha.log"
: > "$NEZHA_LOG"
if have journalctl; then
  while read -r unit; do
    journalctl -u "$unit" --since "$START_DATE" --no-pager -o short-iso 2>/dev/null >> "$NEZHA_LOG" || true
  done < "$UNITS_FILE"
  journalctl --since "$START_DATE" --no-pager -o short-iso _COMM=nezha-agent 2>/dev/null >> "$NEZHA_LOG" || true
fi
sort -u -o "$NEZHA_LOG" "$NEZHA_LOG" 2>/dev/null || true
NEZHA_RELEVANT="$TMP_ROOT/nezha_relevant"
grep -Ei 'task|command|terminal|iostream|fm|fstransfer|fs(write|read|delete|list)|upload|download|exec|执行|命令|终端|文件|传输|panic|failed|error|reconnect|connection to' "$NEZHA_LOG" 2>/dev/null > "$NEZHA_RELEVANT" || true
if [[ -s "$NEZHA_RELEVANT" ]]; then
  print_limited_file "$NEZHA_RELEVANT"
  if grep -Eqi 'fstransfer|upload|download|terminal|executing.*task|command task|fs(write|delete)|文件传输|在线终端' "$NEZHA_RELEVANT"; then
    finding SUSPICIOUS "Agent 日志出现远程终端、命令或文件操作相关记录，请逐条核对时间和来源。"
  else
    finding INFO "Agent 日志存在连接或任务相关记录，但未匹配到明确的成功命令/上传痕迹。"
  fi
else
  finding INFO "未在 journald 中找到 Agent 任务相关日志；这不代表从未执行过远程命令。"
fi

section "2. 截图所示 IOC 与挖矿/后门特征"
IOC_HIT=0

check_ioc_path() {
  local path="$1" desc="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    finding CRITICAL "命中截图 IOC：$desc：$path"
    stat_line "$path"
    describe_file "$path"
    hash_file "$path"
    IOC_HIT=1
  fi
}

check_ioc_path /usr/bin/dpkgd "疑似伪装 rootkit/后门文件"
check_ioc_path /etc/systemd/system/image-search.service "可疑持久化 systemd 服务"
check_ioc_path /usr/lib/systemd/system/image-search.service "可疑持久化 systemd 服务"
check_ioc_path /lib/systemd/system/image-search.service "可疑持久化 systemd 服务"

IOC_FILES="$TMP_ROOT/ioc_files"
find /opt/nezha /tmp /var/tmp /dev/shm /usr/local/bin /usr/bin /usr/local/sbin /usr/sbin \
  -xdev -type f \( -iname '*xmrig*' -o -iname 'dpkgd' -o -iname '*image-search*' \
  -o -iname '*kdevtmpfsi*' -o -iname '*kinsing*' -o -iname '*minerd*' -o -iname '*cpuminer*' \) \
  -print 2>/dev/null > "$IOC_FILES" || true
if [[ -s "$IOC_FILES" ]]; then
  finding CRITICAL "发现挖矿、伪装系统命令或截图同类 IOC 文件。"
  while read -r f; do
    stat_line "$f"; describe_file "$f"; hash_file "$f"
  done < "$IOC_FILES"
  IOC_HIT=1
fi

MCP_TEMP="$TMP_ROOT/mcp_transfer_temp"
find /opt/nezha /tmp /var/tmp /dev/shm -xdev -type f -name '.mcp-xfer-*' -print 2>/dev/null > "$MCP_TEMP" || true
if [[ -s "$MCP_TEMP" ]]; then
  finding SUSPICIOUS "发现 Nezha MCP 文件传输临时文件，可能存在正在进行或异常中断的面板上传。"
  while read -r f; do stat_line "$f"; describe_file "$f"; hash_file "$f"; done < "$MCP_TEMP"
fi

PROC_ALL="$TMP_ROOT/processes"
ps -eo pid=,ppid=,user=,lstart=,%cpu=,%mem=,args= --sort=-%cpu 2>/dev/null > "$PROC_ALL" || true
PROC_SUS="$TMP_ROOT/process_suspicious"
grep -Ei 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|stratum|/usr/bin/dpkgd|image-search|/dev/shm|/var/tmp|/tmp/\.' "$PROC_ALL" > "$PROC_SUS" || true
if [[ -s "$PROC_SUS" ]]; then
  finding CRITICAL "发现疑似挖矿、后门或从临时目录运行的进程。"
  print_limited_file "$PROC_SUS"
  IOC_HIT=1
else
  finding INFO "未发现典型 XMRig/矿池/临时目录恶意进程。"
fi

subsection "CPU 占用最高的进程"
sed -n '1,15p' "$PROC_ALL"

if have tmux; then
  TMUX_OUT="$TMP_ROOT/tmux"
  tmux ls 2>&1 | tee "$TMUX_OUT" || true
  if grep -Eqi '(^|[[:space:]:])xmr([[:space:]:-]|$)|xmrig' "$TMUX_OUT"; then
    finding CRITICAL "发现名为 xmr/xmrig 的 tmux 会话，与截图特征一致。"
    IOC_HIT=1
  fi
fi
if have screen; then
  SCREEN_OUT="$TMP_ROOT/screen"
  screen -ls 2>&1 | tee "$SCREEN_OUT" || true
  grep -Eqi 'xmr|xmrig' "$SCREEN_OUT" && finding CRITICAL "发现可疑 screen 挖矿会话。"
fi

if have ss; then
  NET_SUS="$TMP_ROOT/net_suspicious"
  ss -Hantp 2>/dev/null | grep -E ':(3333|4444|5555|7777|8888|9999|14444|19999)([[:space:]]|$)|xmrig|minerd|cpuminer' > "$NET_SUS" || true
  if [[ -s "$NET_SUS" ]]; then
    finding SUSPICIOUS "发现常见矿池端口或挖矿进程网络连接。"
    print_limited_file "$NET_SUS"
  fi
fi

section "3. 用户账号、UID 0、sudo 与密码状态"
UID_MIN="$(get_uid_min)"
echo "系统 UID_MIN=$UID_MIN"

UID0_FILE="$TMP_ROOT/uid0"
awk -F: '$3==0{print $1 ": uid=" $3 " gid=" $4 " home=" $6 " shell=" $7}' /etc/passwd > "$UID0_FILE"
cat "$UID0_FILE"
if [[ "$(wc -l < "$UID0_FILE")" -gt 1 ]]; then
  finding CRITICAL "除 root 外存在其他 UID=0 账号。"
fi

LOGIN_USERS="$TMP_ROOT/login_users"
awk -F: -v min="$UID_MIN" '
  $7 !~ /(nologin|false|sync|shutdown|halt)$/ {
    type=($3==0?"UID0":($3>=min?"普通账号":"系统账号"))
    print type ": user=" $1 " uid=" $3 " gid=" $4 " home=" $6 " shell=" $7
  }' /etc/passwd > "$LOGIN_USERS"
subsection "具有可登录 Shell 的账号"
cat "$LOGIN_USERS"
SYSTEM_LOGIN_COUNT="$(grep -c '^系统账号:' "$LOGIN_USERS" 2>/dev/null || true)"
if [[ "$SYSTEM_LOGIN_COUNT" =~ ^[0-9]+$ ]] && ((SYSTEM_LOGIN_COUNT > 0)); then
  finding SUSPICIOUS "存在具有交互 Shell 的低 UID 系统账号，请确认是否符合基线。"
fi

if getent passwd gary >/dev/null 2>&1; then
  finding CRITICAL "命中截图 IOC：发现账号 gary。"
  getent passwd gary
  IOC_HIT=1
fi

EMPTY_PASS="$TMP_ROOT/empty_passwords"
awk -F: '($2==""){print $1}' /etc/shadow 2>/dev/null > "$EMPTY_PASS" || true
if [[ -s "$EMPTY_PASS" ]]; then
  finding CRITICAL "发现密码字段为空的账号：$(paste -sd, "$EMPTY_PASS")"
fi

subsection "管理员组成员"
for grp in sudo wheel admin; do
  getent group "$grp" 2>/dev/null || true
done

SUDOERS_ALL="$TMP_ROOT/sudoers"
: > "$SUDOERS_ALL"
for f in /etc/sudoers /etc/sudoers.d/*; do
  [[ -r "$f" && -f "$f" ]] || continue
  echo "### $f" >> "$SUDOERS_ALL"
  grep -Ev '^[[:space:]]*($|#)' "$f" >> "$SUDOERS_ALL" || true
  if is_recent_file "$f"; then
    finding SUSPICIOUS "sudo 配置在最近 $DAYS 天内有变更：$f"
  fi
done
print_limited_file "$SUDOERS_ALL"
if grep -Eqi 'NOPASSWD' "$SUDOERS_ALL"; then
  finding HARDENING "存在免密 sudo，请核对授权对象。"
fi

for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow; do
  [[ -e "$f" ]] || continue
  stat_line "$f"
  if is_recent_file "$f"; then
    finding HARDENING "$f 在最近 $DAYS 天内发生过内容或时间戳变更；请结合 useradd/usermod 日志核查。"
  fi
done

AUTH_LOG="$TMP_ROOT/auth.log"
collect_auth_logs "$AUTH_LOG"
ACCOUNT_EVENTS="$TMP_ROOT/account_events"
grep -Ei 'useradd|adduser|new user|usermod|userdel|groupadd|chpasswd|passwd.*changed|sudoers|visudo' "$AUTH_LOG" > "$ACCOUNT_EVENTS" || true
if [[ -s "$ACCOUNT_EVENTS" ]]; then
  finding SUSPICIOUS "发现账号、组、密码或 sudo 配置变更日志。"
  print_limited_file "$ACCOUNT_EVENTS"
else
  finding INFO "未在可用认证日志中找到账号创建/修改记录。"
fi

section "4. SSH 公钥、登录来源与 SSH 配置"
AUTHORIZED_FILES="$TMP_ROOT/authorized_files"
find /root /home /etc/ssh -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) -print 2>/dev/null | sort -u > "$AUTHORIZED_FILES" || true

if [[ ! -s "$AUTHORIZED_FILES" ]]; then
  finding INFO "未发现 authorized_keys 文件。"
else
  while read -r ak; do
    echo "[$ak]"
    stat_line "$ak"
    perms="$(stat -Lc '%a' "$ak" 2>/dev/null || stat -c '%a' "$ak" 2>/dev/null || echo unknown)"
    mode3="${perms: -3}"
    if [[ "$mode3" =~ ^[0-7]{3}$ ]]; then
      group_digit="${mode3:1:1}"; other_digit="${mode3:2:1}"
      if (((10#$group_digit & 2) != 0 || (10#$other_digit & 2) != 0)); then
        finding SUSPICIOUS "SSH authorized_keys 对组或其他用户可写：$ak 权限=$perms"
      fi
    fi
    if is_recent_file "$ak"; then
      finding SUSPICIOUS "SSH 公钥文件在最近 $DAYS 天内有变更：$ak"
    fi

    line_no=0
    while IFS= read -r line; do
      ((line_no++))
      [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] || continue
      KEY_TMP="$TMP_ROOT/key_${line_no}_$RANDOM"
      printf '%s\n' "$line" > "$KEY_TMP"
      if have ssh-keygen; then
        fp="$(ssh-keygen -lf "$KEY_TMP" 2>/dev/null || true)"
        if [[ -n "$fp" ]]; then
          echo "  line=$line_no $fp"
        else
          echo "  line=$line_no 非标准或无法解析的公钥行：$(printf '%s' "$line" | cut -c1-120)"
          finding SUSPICIOUS "authorized_keys 中存在无法解析的条目：$ak:$line_no"
        fi
      else
        echo "  line=$line_no key_type=$(printf '%s' "$line" | awk '{print $1}')（未安装 ssh-keygen，无法计算指纹）"
      fi
      if grep -Eqi 'gary@gary|command=|permitopen=|environment=|from=' "$KEY_TMP"; then
        echo "  选项/注释：$(printf '%s' "$line" | sed -E 's/[A-Za-z0-9+\/=]{80,}/<KEY_DATA>/g' | cut -c1-240)"
      fi
      if grep -Eqi 'gary@gary' "$KEY_TMP"; then
        finding CRITICAL "命中截图 IOC：authorized_keys 中发现 gary@gary：$ak:$line_no"
        IOC_HIT=1
      fi
      rm -f "$KEY_TMP"
    done < "$ak"
  done < "$AUTHORIZED_FILES"
fi

PRIVATE_KEYS="$TMP_ROOT/private_keys"
find /root /home -xdev -type f -path '*/.ssh/*' \
  \( -name 'id_*' -o -name '*.pem' -o -name '*.key' \) ! -name '*.pub' -print 2>/dev/null > "$PRIVATE_KEYS" || true
if [[ -s "$PRIVATE_KEYS" ]]; then
  subsection "用户目录中的 SSH 私钥"
  while read -r f; do
    stat_line "$f"
    is_recent_file "$f" && finding SUSPICIOUS "最近出现或变更的 SSH 私钥：$f"
  done < "$PRIVATE_KEYS"
fi

SUCCESS_LOGINS="$TMP_ROOT/success_logins"
grep -Ei 'Accepted (publickey|password|keyboard-interactive)|session opened for user' "$AUTH_LOG" > "$SUCCESS_LOGINS" || true
subsection "成功 SSH 登录记录"
if [[ -s "$SUCCESS_LOGINS" ]]; then
  print_limited_file "$SUCCESS_LOGINS"
  if grep -Eq '103\.151\.172\.96' "$SUCCESS_LOGINS"; then
    finding CRITICAL "命中截图 IOC：发现来自 103.151.172.96 的成功登录。"
    IOC_HIT=1
  fi
  if grep -Eqi 'Accepted publickey for root|Accepted password for root' "$SUCCESS_LOGINS"; then
    finding HARDENING "检查窗口内存在 root 直接 SSH 登录，请核对来源 IP 和密钥指纹。"
  fi
else
  finding INFO "未在可用日志中找到成功 SSH 登录记录，日志可能已轮转、未持久化或被清理。"
fi

FAILED_LOGINS="$TMP_ROOT/failed_logins"
grep -Ei 'Failed password|Invalid user|authentication failure|maximum authentication attempts' "$AUTH_LOG" > "$FAILED_LOGINS" || true
if [[ -s "$FAILED_LOGINS" ]]; then
  subsection "失败 SSH 登录（最后若干条）"
  tail -n "$MAX_ITEMS" "$FAILED_LOGINS"
fi

if have last; then
  subsection "最近登录与重启"
  last -Faiwx 2>/dev/null | head -n 60 || true
fi

if have sshd; then
  SSHD_EFFECTIVE="$TMP_ROOT/sshd_effective"
  sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null \
    | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|authorizedkeysfile|authorizedkeyscommand|allowusers|allowgroups|authenticationmethods|permituserenvironment)' \
    > "$SSHD_EFFECTIVE" || true
  subsection "sshd 有效配置"
  cat "$SSHD_EFFECTIVE"
  grep -Eq '^permitrootlogin yes$' "$SSHD_EFFECTIVE" && finding HARDENING "sshd 允许 root 直接登录。"
  grep -Eq '^passwordauthentication yes$' "$SSHD_EFFECTIVE" && finding HARDENING "sshd 允许密码登录。"
  grep -Eq '^permituserenvironment yes$' "$SSHD_EFFECTIVE" && finding HARDENING "sshd 允许用户通过 environment= 注入环境变量。"
  if grep -Eq '^authorizedkeyscommand ' "$SSHD_EFFECTIVE" && ! grep -Eq '^authorizedkeyscommand none$' "$SSHD_EFFECTIVE"; then
    finding SUSPICIOUS "sshd 配置了外部 AuthorizedKeysCommand，请确认来源。"
  fi
fi

section "5. 命令执行证据：auditd、进程记账与 Shell 历史"
if have auditctl; then
  AUDIT_STATUS="$TMP_ROOT/audit_status"
  auditctl -s 2>/dev/null | tee "$AUDIT_STATUS" || true
  if grep -Eq '^enabled[[:space:]]+1' "$AUDIT_STATUS"; then
    finding INFO "auditd 当前已启用。"
  else
    finding HARDENING "auditd 未启用或不可用，历史命令与文件写入可能无法精确追溯。"
  fi
else
  finding HARDENING "未安装 auditd 工具，无法依赖内核审计还原历史命令。"
fi

if [[ -r /var/log/audit/audit.log ]]; then
  AUDIT_SUS="$TMP_ROOT/audit_suspicious"
  zgrep -hEi 'nezha-agent|/opt/nezha/agent|authorized_keys|/etc/passwd|/etc/shadow|/etc/sudoers|/etc/systemd/system|image-search|xmrig|dpkgd' \
    /var/log/audit/audit.log* 2>/dev/null > "$AUDIT_SUS" || true
  if [[ -s "$AUDIT_SUS" ]]; then
    finding SUSPICIOUS "审计日志命中 Agent、账号、SSH 密钥、持久化或挖矿关键词。"
    print_limited_file "$AUDIT_SUS"
  else
    finding INFO "审计日志未匹配到本脚本关键词；可能未配置相应审计规则。"
  fi
fi

if have lastcomm; then
  LASTCOMM_SUS="$TMP_ROOT/lastcomm_suspicious"
  lastcomm 2>/dev/null | grep -Ei 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|useradd|usermod|chattr|curl|wget|tmux|screen' > "$LASTCOMM_SUS" || true
  if [[ -s "$LASTCOMM_SUS" ]]; then
    finding SUSPICIOUS "进程记账记录中发现敏感命令。"
    print_limited_file "$LASTCOMM_SUS"
  else
    finding INFO "进程记账无匹配记录，或系统未启用 acct/psacct。"
  fi
else
  finding INFO "未安装 lastcomm，无法使用进程记账。"
fi

HISTORY_FILES="$TMP_ROOT/history_files"
find /root /home -xdev -type f \( -name '.bash_history' -o -name '.zsh_history' -o -name '.ash_history' -o -name '.history' \) -print 2>/dev/null > "$HISTORY_FILES" || true
HISTORY_SUS="$TMP_ROOT/history_suspicious"
: > "$HISTORY_SUS"
while read -r hf; do
  [[ -r "$hf" ]] || continue
  grep -Ein 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|image-search|useradd|adduser|usermod|authorized_keys|ssh-(rsa|ed25519)|chattr[[:space:]]+\+i|/dev/shm|curl.+\|.*sh|wget.+\|.*sh|base64[[:space:]]+-d|systemctl[[:space:]]+(enable|start)|tmux|screen|nohup|stratum' "$hf" 2>/dev/null \
    | sed "s#^#$hf:#" >> "$HISTORY_SUS" || true
done < "$HISTORY_FILES"
if [[ -s "$HISTORY_SUS" ]]; then
  finding SUSPICIOUS "Shell 历史记录中出现敏感操作。"
  print_limited_file "$HISTORY_SUS"
else
  finding INFO "Shell 历史未命中关键词；Agent 非交互命令通常不会写入用户 Shell 历史。"
fi

section "6. systemd、Cron、启动项与持久化"
SYSTEMD_RECENT="$TMP_ROOT/systemd_recent"
find /etc/systemd/system /usr/local/lib/systemd/system -xdev -type f \
  \( -name '*.service' -o -name '*.timer' -o -name '*.socket' \) -newermt "$START_DATE" -print 2>/dev/null > "$SYSTEMD_RECENT" || true
if [[ -s "$SYSTEMD_RECENT" ]]; then
  finding HARDENING "最近 $DAYS 天内新增或修改了本地 systemd 单元，请核对变更来源。"
  while read -r f; do
    stat_line "$f"
    grep -E '^[[:space:]]*(ExecStart|ExecStartPre|ExecStartPost|Environment|User)=' "$f" 2>/dev/null || true
  done < "$SYSTEMD_RECENT"
fi

SYSTEMD_SUS="$TMP_ROOT/systemd_suspicious"
: > "$SYSTEMD_SUS"
for f in /etc/systemd/system/*.service /etc/systemd/system/*/*.service /usr/local/lib/systemd/system/*.service \
         /lib/systemd/system/*.service /usr/lib/systemd/system/*.service; do
  [[ -r "$f" && -f "$f" ]] || continue
  if grep -Eqi 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|image-search|/dev/shm|/var/tmp|/tmp/\.|stratum|curl.+\|.*sh|wget.+\|.*sh' "$f"; then
    echo "### $f" >> "$SYSTEMD_SUS"
    grep -Ev '^[[:space:]]*($|#)' "$f" >> "$SYSTEMD_SUS"
  fi
done
if [[ -s "$SYSTEMD_SUS" ]]; then
  finding CRITICAL "systemd 单元中发现挖矿、后门、临时目录或下载执行特征。"
  print_limited_file "$SYSTEMD_SUS"
fi

CRON_ALL="$TMP_ROOT/cron_all"
: > "$CRON_ALL"
for f in /etc/crontab /etc/anacrontab /etc/cron.d/* /var/spool/cron/* /var/spool/cron/crontabs/*; do
  [[ -r "$f" && -f "$f" ]] || continue
  echo "### $f" >> "$CRON_ALL"
  grep -Ev '^[[:space:]]*($|#)' "$f" >> "$CRON_ALL" || true
  is_recent_file "$f" && finding HARDENING "Cron 文件在最近 $DAYS 天内有变更，请核对：$f"
done
subsection "有效 Cron 项"
print_limited_file "$CRON_ALL" || echo "未发现有效 Cron 项。"
if grep -Eqi 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|image-search|/dev/shm|/var/tmp|/tmp/\.|curl.+\|.*sh|wget.+\|.*sh|base64[[:space:]]+-d' "$CRON_ALL"; then
  finding CRITICAL "Cron 中发现挖矿、后门或下载执行特征。"
fi

for f in /etc/rc.local /etc/ld.so.preload /etc/profile /etc/bash.bashrc /root/.bashrc /root/.profile; do
  [[ -e "$f" ]] || continue
  stat_line "$f"
  if [[ "$f" == "/etc/ld.so.preload" && -s "$f" ]]; then
    finding CRITICAL "/etc/ld.so.preload 非空，可能用于用户态 rootkit 注入。"
    cat "$f" 2>/dev/null || true
  elif grep -Eqi 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|image-search|/dev/shm|/var/tmp|/tmp/\.|curl.+\|.*sh|wget.+\|.*sh|base64[[:space:]]+-d' "$f" 2>/dev/null; then
    finding CRITICAL "启动/环境文件中发现挖矿、后门或下载执行特征：$f"
    grep -Ein 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|image-search|/dev/shm|/var/tmp|/tmp/\.|curl.+\|.*sh|wget.+\|.*sh|base64[[:space:]]+-d' "$f" 2>/dev/null | head -n "$MAX_ITEMS" || true
  elif is_recent_file "$f"; then
    finding HARDENING "启动/环境文件在最近 $DAYS 天内有变更，请核对：$f"
  fi
done

PROFILE_RECENT="$TMP_ROOT/profile_recent"
find /etc/profile.d -xdev -type f -newermt "$START_DATE" -print 2>/dev/null > "$PROFILE_RECENT" || true
if [[ -s "$PROFILE_RECENT" ]]; then
  finding HARDENING "最近修改了 /etc/profile.d 下的登录启动脚本，请核对。"
  print_limited_file "$PROFILE_RECENT"
  while read -r f; do
    if grep -Eqi 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|image-search|/dev/shm|/var/tmp|/tmp/\.|curl.+\|.*sh|wget.+\|.*sh|base64[[:space:]]+-d' "$f" 2>/dev/null; then
      finding CRITICAL "profile.d 启动脚本中发现挖矿、后门或下载执行特征：$f"
      grep -Ein 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|dpkgd|image-search|/dev/shm|/var/tmp|/tmp/\.|curl.+\|.*sh|wget.+\|.*sh|base64[[:space:]]+-d' "$f" 2>/dev/null | head -n "$MAX_ITEMS" || true
    fi
  done < "$PROFILE_RECENT"
fi

section "7. 最近文件、疑似上传文件与系统命令完整性"
RECENT_UPLOADS="$TMP_ROOT/recent_uploads"
find /opt/nezha /tmp /var/tmp /dev/shm /root /home \
  -xdev -type f -newermt "$START_DATE" \
  \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \
     -o -iname '*.zip' -o -iname '*.7z' -o -iname '*.rar' -o -iname '*.tar' -o -iname '*.tgz' \
     -o -iname '*.sh' -o -iname '*.py' -o -iname '*.pl' -o -iname '*.so' -o -iname '*.bin' \
     -o -iname '*.elf' -o -iname '*.service' \) -print 2>/dev/null > "$RECENT_UPLOADS" || true
if [[ -s "$RECENT_UPLOADS" ]]; then
  finding SUSPICIOUS "发现最近出现的图片、压缩包、脚本、共享库或服务文件；其中可能包含面板上传文件或截图。"
  while read -r f; do
    stat_line "$f"
    describe_file "$f"
    [[ -x "$f" ]] && hash_file "$f"
  done < <(sed -n "1,${MAX_ITEMS}p" "$RECENT_UPLOADS")
else
  finding INFO "未在常见目录发现最近的图片、压缩包、脚本或二进制上传痕迹。"
fi

TEMP_EXEC="$TMP_ROOT/temp_exec"
find /tmp /var/tmp /dev/shm -xdev -type f -newermt "$START_DATE" \( -perm /111 -o -name '.*' \) -print 2>/dev/null > "$TEMP_EXEC" || true
if [[ -s "$TEMP_EXEC" ]]; then
  finding SUSPICIOUS "临时目录中存在最近的可执行或隐藏文件。"
  while read -r f; do stat_line "$f"; describe_file "$f"; hash_file "$f"; done \
    < <(sed -n "1,${MAX_ITEMS}p" "$TEMP_EXEC")
fi

RECENT_LOCAL_EXEC="$TMP_ROOT/recent_local_exec"
find /opt/nezha /usr/local/bin /usr/local/sbin -xdev -type f -perm /111   -newermt "$START_DATE" -print 2>/dev/null > "$RECENT_LOCAL_EXEC" || true
if [[ -s "$RECENT_LOCAL_EXEC" ]]; then
  finding SUSPICIOUS "哪吒目录或 /usr/local 命令目录中存在最近新增/修改的可执行文件。"
  while read -r f; do stat_line "$f"; describe_file "$f"; hash_file "$f"; done     < <(sed -n "1,${MAX_ITEMS}p" "$RECENT_LOCAL_EXEC")
fi

RECENT_SYSTEM_UNOWNED="$TMP_ROOT/recent_system_unowned"
: > "$RECENT_SYSTEM_UNOWNED"
while read -r f; do
  [[ -f "$f" ]] || continue
  owner="$(package_owner "$f")"
  if [[ -z "$owner" ]]; then
    echo "$f" >> "$RECENT_SYSTEM_UNOWNED"
  fi
done < <(find /usr/bin /usr/sbin /bin /sbin -xdev -type f -newermt "$START_DATE" -print 2>/dev/null | head -n "$((MAX_ITEMS * 5))")
if [[ -s "$RECENT_SYSTEM_UNOWNED" ]]; then
  finding SUSPICIOUS "系统命令目录中存在最近修改且不属于已安装软件包的文件。"
  while read -r f; do stat_line "$f"; describe_file "$f"; hash_file "$f"; done \
    < <(sed -n "1,${MAX_ITEMS}p" "$RECENT_SYSTEM_UNOWNED")
fi

subsection "关键命令文件类型、软件包归属和校验"
KEY_COMMANDS=(ps ss netstat lsof top ls find systemctl ssh sshd sudo dpkg rpm)
for c in "${KEY_COMMANDS[@]}"; do
  path="$(command -v "$c" 2>/dev/null || true)"
  [[ -n "$path" && -e "$path" ]] || continue
  real="$(readlink -f "$path" 2>/dev/null || echo "$path")"
  owner="$(package_owner "$real")"
  printf '%-10s path=%s real=%s package=%s\n' "$c" "$path" "$real" "${owner:-UNOWNED}"
  describe_file "$real"
  if [[ -z "$owner" && "$real" != /usr/local/* ]]; then
    finding SUSPICIOUS "关键命令不属于已安装软件包：$c -> $real"
  fi
  if have dpkg-query && [[ -n "$owner" ]]; then
    VERIFY_OUT="$(dpkg -V "$owner" 2>/dev/null | grep -F " $real" || true)"
    [[ -n "$VERIFY_OUT" ]] && { finding CRITICAL "Debian 软件包校验发现关键命令被修改：$real"; echo "$VERIFY_OUT"; }
  elif have rpm && [[ -n "$owner" ]]; then
    VERIFY_OUT="$(rpm -Vf "$real" 2>/dev/null | grep -F " $real" || true)"
    [[ -n "$VERIFY_OUT" ]] && { finding CRITICAL "RPM 校验发现关键命令被修改：$real"; echo "$VERIFY_OUT"; }
  fi
done

SUID_RECENT="$TMP_ROOT/suid_recent"
find /usr/local /opt /tmp /var/tmp /dev/shm /root /home -xdev -type f \
  \( -perm -4000 -o -perm -2000 \) -perm /111 -uid 0 -newermt "$START_DATE" -print 2>/dev/null > "$SUID_RECENT" || true
if [[ -s "$SUID_RECENT" ]]; then
  finding SUSPICIOUS "最近出现或修改了 SUID/SGID 文件。"
  while read -r f; do stat_line "$f"; describe_file "$f"; hash_file "$f"; done < "$SUID_RECENT"
fi

section "8. 网络监听、已建立连接与日志清理迹象"
if have ss; then
  subsection "监听端口"
  ss -Hlnptu 2>/dev/null | sed -n "1,${MAX_ITEMS}p" || true
  subsection "已建立 TCP 连接"
  ss -Hntp state established 2>/dev/null | sed -n "1,${MAX_ITEMS}p" || true
fi

for f in /var/log/auth.log /var/log/secure /var/log/audit/audit.log /var/log/wtmp /var/log/btmp /var/log/lastlog; do
  [[ -e "$f" ]] || continue
  stat_line "$f"
  if [[ ! -s "$f" && "$f" != /var/log/lastlog ]]; then
    if is_recent_file "$f"; then
      finding SUSPICIOUS "关键安全日志近期变为空或被截断：$f"
    else
      finding INFO "关键安全日志为空：$f（在容器、最小化系统或未启用对应日志时可能正常）"
    fi
  fi
done

if have journalctl; then
  JOURNAL_RANGE="$TMP_ROOT/journal_range"
  journalctl --list-boots --no-pager 2>/dev/null | tee "$JOURNAL_RANGE" || true
  if [[ ! -s "$JOURNAL_RANGE" ]]; then
    finding HARDENING "journald 没有可查询的启动历史，可能未持久化。"
  fi
fi

section "检测结论"
printf '严重=%d  可疑=%d  配置风险=%d  信息=%d  检测失败=%d\n' \
  "$CRITICAL" "$SUSPICIOUS" "$HARDENING" "$INFO_COUNT" "$ERRORS"

if ((CRITICAL == 0 && SUSPICIOUS == 0)); then
  printf '\n%s%s机器安全：未发现明显入侵迹象。%s\n' "$C_GREEN" "$C_BOLD" "$C_RESET"
  echo "说明：该结论仅基于当前仍可见的日志、进程、文件和账号状态，不等同于取证意义上的绝对安全。"
  if ((HARDENING > 0)); then
    echo "另有 $HARDENING 项配置风险，建议完成加固后复查。"
  fi
  exit 0
else
  printf '\n%s%s发现疑似入侵或高风险痕迹，请立即隔离主机并保全证据。%s\n' "$C_RED" "$C_BOLD" "$C_RESET"
  echo "优先动作：不要先删除文件；先保存磁盘/内存快照、journald、audit、auth 日志和面板任务记录，再轮换面板密钥及所有 SSH 密钥。"
  exit 1
fi
