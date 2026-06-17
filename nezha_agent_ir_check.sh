#!/usr/bin/env bash
# Nezha Agent 远程命令执行取证脚本
# 只读：不会停止服务、删除文件、修改配置或安装软件。
# 重点：尝试还原由 nezha-agent 直接派生的 `sh -c <命令>`、后续子进程、文件操作与上传痕迹。

set -uo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

VERSION="2.0.1"
DAYS=30
MAX_ITEMS=200
NO_COLOR=0
OUTPUT_FILE=""
DEEP_SCAN=0

usage() {
  cat <<'EOF'
用法：
  sudo bash nezha_agent_rce_forensics.sh [选项]

选项：
  -d, --days N       检查最近 N 天，默认 30
  -m, --max N        每类最多显示 N 条，默认 200
  -o, --output FILE  同时保存完整检查结果
      --deep-scan    扫描整个本地根文件系统的近期可疑文件（可能较慢）
      --no-color     禁用彩色输出
  -h, --help         显示帮助

示例：
  sudo bash nezha_agent_rce_forensics.sh
  sudo bash nezha_agent_rce_forensics.sh --days 7 --output /root/nezha-rce-check.log
  sudo bash nezha_agent_rce_forensics.sh --days 90 --deep-scan

退出码：
  0  未发现明确或高风险痕迹
  1  发现已确认命令执行或高风险痕迹
  2  参数/权限/运行错误
EOF
}

while (($#)); do
  case "$1" in
    -d|--days)
      [[ $# -ge 2 ]] || { echo "缺少 --days 参数" >&2; exit 2; }
      DAYS="$2"; shift 2 ;;
    -m|--max)
      [[ $# -ge 2 ]] || { echo "缺少 --max 参数" >&2; exit 2; }
      MAX_ITEMS="$2"; shift 2 ;;
    -o|--output)
      [[ $# -ge 2 ]] || { echo "缺少 --output 参数" >&2; exit 2; }
      OUTPUT_FILE="$2"; shift 2 ;;
    --deep-scan)
      DEEP_SCAN=1; shift ;;
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
[[ "$MAX_ITEMS" =~ ^[0-9]+$ ]] && ((MAX_ITEMS >= 10 && MAX_ITEMS <= 10000)) || {
  echo "--max 必须是 10-10000 的整数" >&2; exit 2;
}

if ((EUID != 0)); then
  echo "需要 root 权限读取 journald、audit、SSH 密钥及所有用户目录。"
  echo "请使用：sudo bash $0 --days $DAYS"
  exit 2
fi

if [[ -n "$OUTPUT_FILE" ]]; then
  mkdir -p -- "$(dirname -- "$OUTPUT_FILE")" 2>/dev/null || {
    echo "无法创建输出目录：$(dirname -- "$OUTPUT_FILE")" >&2; exit 2;
  }
  touch -- "$OUTPUT_FILE" 2>/dev/null || {
    echo "无法写入输出文件：$OUTPUT_FILE" >&2; exit 2;
  }
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

if [[ -t 1 && "$NO_COLOR" -eq 0 ]]; then
  C0=$'\033[0m'; B=$'\033[1m'; RED=$'\033[31m'; YEL=$'\033[33m'
  GRN=$'\033[32m'; BLU=$'\033[34m'; MAG=$'\033[35m'; CYN=$'\033[36m'
else
  C0=""; B=""; RED=""; YEL=""; GRN=""; BLU=""; MAG=""; CYN=""
fi

TMP="$(mktemp -d /tmp/nezha-rce-ir.XXXXXX)" || exit 2
trap 'rm -rf -- "$TMP"' EXIT INT TERM

NOW_EPOCH="$(date +%s)"
START_EPOCH="$(date -d "$DAYS days ago" +%s 2>/dev/null || echo 0)"
START_TEXT="$(date -d "@$START_EPOCH" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo unknown)"
NOW_TEXT="$(date '+%Y-%m-%d %H:%M:%S %z')"

CONFIRMED=0
HIGH=0
SUSPICIOUS=0
RISK=0
INFO=0
ERRORS=0
VISIBILITY_GAPS=0
AUDIT_DIRECT=0
AUDIT_CHILD=0
AUDIT_FILEOPS=0
LIVE_CHILDREN=0
MCP_TEMP_COUNT=0
RECENT_SUSP_FILES=0
PERSIST_COUNT=0
ACCOUNT_COUNT=0
KEY_COUNT=0

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n%s%s== %s ==%s\n' "$B" "$BLU" "$1" "$C0"; }
subsection() { printf '\n%s-- %s --%s\n' "$CYN" "$1" "$C0"; }

finding() {
  local sev="$1"; shift
  case "$sev" in
    CONFIRMED) ((CONFIRMED++)); printf '%s[已确认]%s %s\n' "$B$RED" "$C0" "$*" ;;
    HIGH)      ((HIGH++));      printf '%s[高危]%s %s\n' "$B$RED" "$C0" "$*" ;;
    SUSPICIOUS)((SUSPICIOUS++));printf '%s[可疑]%s %s\n' "$B$MAG" "$C0" "$*" ;;
    RISK)      ((RISK++));      printf '%s[风险]%s %s\n' "$YEL" "$C0" "$*" ;;
    INFO)      ((INFO++));      printf '%s[信息]%s %s\n' "$GRN" "$C0" "$*" ;;
    GAP)       ((VISIBILITY_GAPS++)); printf '%s[取证缺口]%s %s\n' "$YEL" "$C0" "$*" ;;
    ERROR)     ((ERRORS++));    printf '%s[检测失败]%s %s\n' "$RED" "$C0" "$*" ;;
  esac
}

print_limited() {
  local file="$1" max="${2:-$MAX_ITEMS}" count
  [[ -s "$file" ]] || return 1
  sed -n "1,${max}p" "$file"
  count="$(wc -l < "$file" 2>/dev/null || echo 0)"
  if [[ "$count" =~ ^[0-9]+$ ]] && ((count > max)); then
    echo "... 已截断，共 $count 条；可用 --max 增大显示上限"
  fi
}

stat_line() {
  stat -Lc 'mode=%A(%a) owner=%U:%G size=%s mtime=%y ctime=%z path=%n' -- "$1" 2>/dev/null || \
  stat -c  'mode=%A(%a) owner=%U:%G size=%s mtime=%y ctime=%z path=%n' -- "$1" 2>/dev/null || true
}

sha256_file() {
  if have sha256sum; then sha256sum -- "$1" 2>/dev/null || true
  elif have shasum; then shasum -a 256 -- "$1" 2>/dev/null || true
  fi
}

redact_secret_text() {
  sed -E \
    -e 's/([[:space:]]-p[[:space:]]+)[^[:space:];]+/\1<REDACTED>/g' \
    -e 's/(--password[=[:space:]]+)[^[:space:];]+/\1<REDACTED>/Ig' \
    -e 's/(--token[=[:space:]]+)[^[:space:];]+/\1<REDACTED>/Ig' \
    -e 's/(client_secret[[:space:]]*:[[:space:]]*).*/\1<REDACTED>/Ig' \
    -e 's/(agent_secret[[:space:]]*:[[:space:]]*).*/\1<REDACTED>/Ig'
}

is_suspicious_text() {
  grep -Eqi '(^|[ /])(xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|watchbog|watchdogd|dpkgd|masscan|zmap|socat|chisel|frpc|gost|realm)([ /]|$)|stratum(\+tcp)?://|/dev/shm|/var/tmp/\.|/tmp/\.|curl[^|;]*(\||;)[[:space:]]*(ba)?sh|wget[^|;]*(\||;)[[:space:]]*(ba)?sh|base64[[:space:]]+(-d|--decode)|python[^;]*(socket|pty|subprocess)|perl[^;]*socket|nc[[:space:]].*(-e|/bin/sh)|authorized_keys|useradd|adduser|usermod|passwd[[:space:]]|chattr[[:space:]]+\+i|systemctl[[:space:]]+(enable|start)|crontab[[:space:]]|nohup|setsid|tmux|screen|iptables|nft[[:space:]]|history[[:space:]]+-c|rm[[:space:]]+-f[[:space:]]+/var/log|truncate[[:space:]].*/var/log'
}

is_high_risk_command() {
  grep -Eqi 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|stratum|authorized_keys|useradd|adduser|usermod|passwd[[:space:]]|/etc/(passwd|shadow|sudoers)|systemctl[[:space:]]+(enable|start)|crontab|/etc/cron|/dev/shm|curl[^|;]*(\||;)[[:space:]]*(ba)?sh|wget[^|;]*(\||;)[[:space:]]*(ba)?sh|base64[[:space:]]+(-d|--decode)|chattr[[:space:]]+\+i|history[[:space:]]+-c|truncate[[:space:]].*/var/log|rm[[:space:]]+-[^;]*/var/log'
}

printf '%s%sNezha Agent 远程命令执行取证 v%s%s\n' "$B" "$BLU" "$VERSION" "$C0"
printf '主机：%s\n时间：%s\n检查窗口：最近 %s 天（自 %s）\n' \
  "$(hostname -f 2>/dev/null || hostname)" "$NOW_TEXT" "$DAYS" "$START_TEXT"
echo "模式：只读。重点还原 nezha-agent 派生的 sh -c 命令、子进程、上传与落地行为。"

# ---------------------------------------------------------------------------
section "1. Nezha Agent 运行方式与远程执行开关"

UNITS="$TMP/units"
: > "$UNITS"
if have systemctl; then
  {
    systemctl list-unit-files --type=service --no-legend 2>/dev/null || true
    systemctl list-units --all --type=service --no-legend 2>/dev/null || true
  } | awk '{print $1}' | grep -Ei '(^|[-_.])nezha.*agent|agent.*nezha' | sort -u > "$UNITS" || true
fi
for u in nezha-agent.service nezha_agent.service; do
  if systemctl status "$u" >/dev/null 2>&1; then
    grep -qxF "$u" "$UNITS" || echo "$u" >> "$UNITS"
  fi
done
sort -u -o "$UNITS" "$UNITS"

AGENT_PIDS="$TMP/current_agent_pids"
: > "$AGENT_PIDS"
for p in /proc/[0-9]*; do
  [[ -r "$p/cmdline" ]] || continue
  exe="$(readlink -f "$p/exe" 2>/dev/null || true)"
  cmd="$(cat "$p/cmdline" 2>/dev/null | tr '\0' ' ' || true)"
  if [[ "${exe,,}" == *nezha*agent* || "${cmd,,}" == *nezha-agent* || "${cmd,,}" == *'/opt/nezha/agent/'* ]]; then
    basename "$p"
  fi
done | sort -n -u > "$AGENT_PIDS"

if [[ ! -s "$UNITS" && ! -s "$AGENT_PIDS" ]]; then
  finding RISK "未发现当前运行或注册的 nezha-agent；仍继续检查历史痕迹。"
else
  finding INFO "发现 Nezha Agent 服务或进程。"
fi

REMOTE_DISABLED=0
REMOTE_ENABLED=0
CONFIG_FILES="$TMP/config_files"
: > "$CONFIG_FILES"

if [[ -s "$UNITS" ]]; then
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    subsection "systemd：$unit"
    systemctl show "$unit" -p LoadState -p ActiveState -p SubState -p MainPID -p User -p FragmentPath -p ExecStart 2>/dev/null \
      | redact_secret_text || true
    systemctl cat "$unit" 2>/dev/null | redact_secret_text || true

    raw="$(systemctl show "$unit" -p ExecStart --value 2>/dev/null || true)"
    if grep -Eq -- '(^|[[:space:]])--disable-command-execute([=[:space:]]|$)' <<<"$raw"; then
      ((REMOTE_DISABLED++))
      finding INFO "$unit 已通过命令行启用 --disable-command-execute。"
    else
      ((REMOTE_ENABLED++))
      finding RISK "$unit 未在 ExecStart 中启用 --disable-command-execute，面板具备下发命令/终端/文件任务的能力。"
    fi

    # 从 ExecStart 中提取显式配置文件路径。
    printf '%s\n' "$raw" | grep -oE '(^|[[:space:]])(-c|--config)(=|[[:space:]])[^[:space:];}]+' \
      | sed -E 's/^[[:space:]]*(-c|--config)(=|[[:space:]])//' >> "$CONFIG_FILES" || true
  done < "$UNITS"
fi

find /opt/nezha /etc/nezha /usr/local/etc/nezha /root/.config/nezha /root/.nezha \
  -maxdepth 4 -type f \( -iname '*agent*.yml' -o -iname '*agent*.yaml' -o -iname 'config.yml' -o -iname 'config.yaml' \) \
  -print 2>/dev/null >> "$CONFIG_FILES" || true
sort -u -o "$CONFIG_FILES" "$CONFIG_FILES"

if [[ -s "$CONFIG_FILES" ]]; then
  subsection "Agent 配置"
  while IFS= read -r cfg; do
    [[ -r "$cfg" ]] || continue
    echo "[$cfg]"
    stat_line "$cfg"
    grep -Ei '^[[:space:]]*(server|tls|insecure_tls|debug|disable_command_execute|disable_force_update|disable_auto_update|disable_nat|uuid)[[:space:]]*:' "$cfg" 2>/dev/null \
      | redact_secret_text || true
    val="$(awk 'BEGIN{IGNORECASE=1} $0 !~ /^[[:space:]]*#/ && $0 ~ /^[[:space:]]*disable_command_execute[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/["[:space:]]/,""); print tolower($0); exit}' "$cfg" 2>/dev/null || true)"
    if [[ "$val" == "true" ]]; then
      ((REMOTE_DISABLED++))
      finding INFO "$cfg 设置了 disable_command_execute: true。"
    elif [[ -n "$val" ]]; then
      ((REMOTE_ENABLED++))
      finding RISK "$cfg 的 disable_command_execute=$val。"
    fi
  done < "$CONFIG_FILES"
fi

if [[ -s "$AGENT_PIDS" ]]; then
  subsection "当前 Agent 进程"
  while IFS= read -r pid; do
    ps -p "$pid" -o pid=,ppid=,user=,lstart=,etime=,cmd= 2>/dev/null | redact_secret_text || true
    exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
    [[ -n "$exe" && -f "$exe" ]] && { stat_line "$exe"; sha256_file "$exe"; }
  done < "$AGENT_PIDS"
fi

# ---------------------------------------------------------------------------
section "2. 当前仍在运行的 Agent 子进程"

LIVE_OUT="$TMP/live_children"
: > "$LIVE_OUT"
declare -A seen_live=()
queue=()
while IFS= read -r p; do [[ "$p" =~ ^[0-9]+$ ]] && queue+=("$p"); done < "$AGENT_PIDS"

while ((${#queue[@]})); do
  parent="${queue[0]}"
  queue=("${queue[@]:1}")
  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    [[ -n "${seen_live[$child]:-}" ]] && continue
    seen_live[$child]=1
    queue+=("$child")
    ppid="$(awk '{print $4}' "/proc/$child/stat" 2>/dev/null || true)"
    user="$(ps -p "$child" -o user= 2>/dev/null | xargs || true)"
    start="$(ps -p "$child" -o lstart= 2>/dev/null | xargs || true)"
    cmd="$(cat "/proc/$child/cmdline" 2>/dev/null | tr '\0' ' ' || true)"
    [[ -n "$cmd" ]] || cmd="[$(cat "/proc/$child/comm" 2>/dev/null || echo unknown)]"
    printf 'pid=%s ppid=%s user=%s start=%s cmd=%s\n' "$child" "$ppid" "$user" "$start" "$cmd" >> "$LIVE_OUT"
  done < <(pgrep -P "$parent" 2>/dev/null || true)
done

if [[ -s "$LIVE_OUT" ]]; then
  LIVE_CHILDREN="$(wc -l < "$LIVE_OUT")"
  finding HIGH "nezha-agent 当前存在 $LIVE_CHILDREN 个后代进程；可能是远程命令、在线终端或其遗留进程。"
  print_limited "$LIVE_OUT"
  while IFS= read -r line; do
    if grep -Eqi 'cmd=([^ ]*/)?(sh|bash|dash)[[:space:]]+-c[[:space:]]' <<<"$line"; then
      finding CONFIRMED "发现 Agent 当前派生的 shell -c：$line"
    elif is_suspicious_text <<<"$line"; then
      finding HIGH "Agent 子进程命中高风险特征：$line"
    fi
  done < "$LIVE_OUT"
else
  finding INFO "当前未发现 nezha-agent 子进程。"
fi

# ---------------------------------------------------------------------------
section "3. Agent 日志中的任务、终端和文件传输"

JOURNAL_RAW="$TMP/agent_journal.log"
JOURNAL_JSON="$TMP/agent_journal.jsonl"
: > "$JOURNAL_RAW"; : > "$JOURNAL_JSON"

if have journalctl; then
  if [[ -s "$UNITS" ]]; then
    while IFS= read -r unit; do
      journalctl --since "@$START_EPOCH" --no-pager -o short-iso-precise -u "$unit" 2>/dev/null >> "$JOURNAL_RAW" || true
      journalctl --since "@$START_EPOCH" --no-pager -o json -u "$unit" 2>/dev/null >> "$JOURNAL_JSON" || true
    done < "$UNITS"
  fi
  journalctl --since "@$START_EPOCH" --no-pager -o short-iso-precise _COMM=nezha-agent 2>/dev/null >> "$JOURNAL_RAW" || true
  journalctl --since "@$START_EPOCH" --no-pager -o json _COMM=nezha-agent 2>/dev/null >> "$JOURNAL_JSON" || true
fi

JOURNAL_RELEVANT="$TMP/journal_relevant"
grep -Ei 'Executing|Task|Command|terminal|iostream|MCP|FsTransfer|fs\.|upload|download|file|shell|执行|命令|终端|文件|传输|failed|error|panic' \
  "$JOURNAL_RAW" 2>/dev/null | awk '!seen[$0]++' > "$JOURNAL_RELEVANT" || true

if [[ -s "$JOURNAL_RELEVANT" ]]; then
  print_limited "$JOURNAL_RELEVANT"
  if grep -Eqi 'FsTransfer|upload|download|terminal|iostream|Executing.*Task|Command Task|MCP.*exec|在线终端|文件传输' "$JOURNAL_RELEVANT"; then
    finding SUSPICIOUS "Agent 日志出现任务、终端或文件传输相关记录；日志通常不包含完整命令正文。"
  else
    finding INFO "Agent 日志存在异常/重连记录，但未匹配明确任务类型。"
  fi
else
  finding GAP "未找到 Agent 任务日志。日志缺失不能证明从未执行过远程命令。"
fi

# 从 journald JSON 建立历史 Agent PID 时间窗口，减少 PID 复用造成的误报。
PID_WINDOWS="$TMP/agent_pid_windows.tsv"
: > "$PID_WINDOWS"
if have python3 && [[ -s "$JOURNAL_JSON" ]]; then
  python3 - "$JOURNAL_JSON" "$PID_WINDOWS" <<'PY' 2>/dev/null || true
import json, sys
src, dst = sys.argv[1:3]
w = {}
with open(src, 'r', errors='replace') as f:
    for line in f:
        try:
            o = json.loads(line)
            pid = int(o.get('_PID', 0))
            ts = int(o.get('__REALTIME_TIMESTAMP', 0)) // 1_000_000
            comm = str(o.get('_COMM', ''))
            exe = str(o.get('_EXE', ''))
            if pid <= 0 or ts <= 0:
                continue
            if 'nezha' not in (comm + ' ' + exe).lower() and 'agent' not in (comm + ' ' + exe).lower():
                # unit 查询的记录可能包含 systemd 自身信息；只保留 agent 进程。
                continue
            if pid not in w:
                w[pid] = [ts, ts]
            else:
                w[pid][0] = min(w[pid][0], ts)
                w[pid][1] = max(w[pid][1], ts)
        except Exception:
            pass
with open(dst, 'w') as out:
    for pid, (a, b) in sorted(w.items()):
        out.write(f"{pid}\t{a}\t{b}\n")
PY
fi

# 当前 PID 的窗口从进程启动时间延伸到现在。
BOOT_EPOCH="$(awk -v n="$NOW_EPOCH" '{printf "%d", n-$1}' /proc/uptime 2>/dev/null || echo "$START_EPOCH")"
CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"
while IFS= read -r pid; do
  ticks="$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || echo 0)"
  if [[ "$ticks" =~ ^[0-9]+$ && "$CLK_TCK" =~ ^[0-9]+$ && "$CLK_TCK" -gt 0 ]]; then
    start=$((BOOT_EPOCH + ticks / CLK_TCK))
  else
    start="$START_EPOCH"
  fi
  printf '%s\t%s\t%s\n' "$pid" "$start" "$NOW_EPOCH" >> "$PID_WINDOWS"
done < "$AGENT_PIDS"
sort -n -k1,1 -k2,2 -u -o "$PID_WINDOWS" "$PID_WINDOWS"

# ---------------------------------------------------------------------------
section "4. auditd：精确还原 Agent 下发的命令"

echo "判定原理：Linux 版 Nezha 远程命令由 Agent 直接启动 sh -c <命令>。"
echo "若 auditd 当时记录了 EXECVE，可从 a2/PROCTITLE 还原完整命令，并沿 PPID 追踪子进程。"

AUDIT_RULES="$TMP/audit_rules"
: > "$AUDIT_RULES"
AUDIT_ENABLED=0
AUDIT_EXEC_COVERAGE=0
if have auditctl; then
  auditctl -s 2>/dev/null || true
  auditctl -l 2>/dev/null | tee "$AUDIT_RULES" || true
  auditctl -s 2>/dev/null | grep -Eq '^enabled[[:space:]]+[12]' && AUDIT_ENABLED=1 || true
  grep -Eqi '(-S[[:space:]]+([^#]*,)?(execve|execveat)|perm=x|[[:space:]]-S[[:space:]]+all)' "$AUDIT_RULES" && AUDIT_EXEC_COVERAGE=1 || true
fi

AUDIT_FILES=()
while IFS= read -r f; do AUDIT_FILES+=("$f"); done < <(
  find /var/log/audit -maxdepth 1 -type f \( -name 'audit.log' -o -name 'audit.log.*' -o -name 'audit.log*.gz' \) -print 2>/dev/null \
    | xargs -r ls -1tr 2>/dev/null
)

AUDIT_OUT="$TMP/audit_lineage.tsv"
AUDIT_META="$TMP/audit_meta"
: > "$AUDIT_OUT"; : > "$AUDIT_META"

if have python3 && ((${#AUDIT_FILES[@]})); then
  START_EPOCH="$START_EPOCH" PID_WINDOWS="$PID_WINDOWS" python3 - "$AUDIT_OUT" "$AUDIT_META" "${AUDIT_FILES[@]}" <<'PY' || true
import os, re, sys, gzip, ast, datetime
from collections import OrderedDict, defaultdict

out_path, meta_path, *files = sys.argv[1:]
start_epoch = float(os.environ.get('START_EPOCH', '0'))
windows_path = os.environ.get('PID_WINDOWS', '')

kv_re = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*|a\d+)=((?:"(?:\\.|[^"\\])*")|\S+)')
event_re = re.compile(r'msg=audit\((\d+(?:\.\d+)?):(\d+)\)')
type_re = re.compile(r'^type=([^ ]+)')
hex_re = re.compile(r'^[0-9A-Fa-f]+$')

def dec(v):
    if v is None:
        return ''
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        try:
            return ast.literal_eval(v)
        except Exception:
            return v[1:-1].replace('\\"', '"').replace('\\\\', '\\')
    if hex_re.match(v) and len(v) % 2 == 0 and len(v) >= 4:
        try:
            b = bytes.fromhex(v)
            if b'\x00' in b or all((32 <= x < 127) or x in (9,10,13) for x in b):
                return b.decode('utf-8', 'replace').replace('\x00', ' ')
        except Exception:
            pass
    return v

def parse_fields(line):
    return {k: dec(v) for k, v in kv_re.findall(line)}

def opener(path):
    return gzip.open(path, 'rt', errors='replace') if path.endswith('.gz') else open(path, 'r', errors='replace')

def iter_events(paths):
    # Audit records for one serial are normally adjacent. Keep a bounded buffer for occasional interleaving.
    buf = OrderedDict()
    for path in paths:
        try:
            f = opener(path)
        except Exception:
            continue
        with f:
            for line in f:
                m = event_re.search(line)
                if not m:
                    continue
                ts, serial = float(m.group(1)), m.group(2)
                if ts < start_epoch:
                    continue
                key = (ts, serial)
                e = buf.setdefault(key, {'ts': ts, 'serial': serial, 'records': []})
                e['records'].append(line.rstrip('\n'))
                buf.move_to_end(key)
                if len(buf) > 512:
                    _, old = buf.popitem(last=False)
                    yield enrich(old)
    for _, e in buf.items():
        yield enrich(e)

def enrich(e):
    e.update({'pid':0,'ppid':0,'uid':'','euid':'','auid':'','comm':'','exe':'','success':'',
              'argv':{},'proctitle':'','cwd':'','paths':[],'syscall':''})
    for line in e['records']:
        tm = type_re.search(line)
        typ = tm.group(1) if tm else ''
        f = parse_fields(line)
        if typ == 'SYSCALL':
            for k in ('pid','ppid'):
                try: e[k] = int(f.get(k, e[k]) or 0)
                except Exception: pass
            for k in ('uid','euid','auid','comm','exe','success','syscall'):
                if f.get(k, '') != '': e[k] = f[k]
        elif typ == 'EXECVE':
            for k,v in f.items():
                if re.fullmatch(r'a\d+', k):
                    e['argv'][int(k[1:])] = v
        elif typ == 'PROCTITLE':
            e['proctitle'] = dec(f.get('proctitle',''))
        elif typ == 'CWD':
            e['cwd'] = f.get('cwd','')
        elif typ == 'PATH':
            name = f.get('name','')
            if name:
                e['paths'].append((f.get('nametype',''), name))
    return e

def argv_text(e):
    if e['argv']:
        vals = [e['argv'][k] for k in sorted(e['argv'])]
        return ' '.join(vals)
    return e['proctitle'].strip()

def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).astimezone().isoformat(timespec='seconds')

def clean(s):
    return str(s or '').replace('\t',' ').replace('\r',' ').replace('\n',' \\n ')

# Journal/current-PID windows.
windows = defaultdict(list)
if windows_path and os.path.exists(windows_path):
    with open(windows_path, errors='replace') as f:
        for line in f:
            try:
                pid,a,b = map(int, line.rstrip().split('\t')[:3])
                windows[pid].append((a-300, b+3600))
            except Exception:
                pass

# First pass: find agent process starts in audit itself.
agent_starts = []
for e in iter_events(files):
    blob = (e['comm'] + ' ' + e['exe'] + ' ' + argv_text(e)).lower()
    if e['pid'] > 0 and ('nezha-agent' in blob or '/opt/nezha/agent/' in blob):
        agent_starts.append((e['ts'], e['pid']))

# A started agent PID is valid until the next observed agent start, capped at now.
agent_starts.sort()
now = datetime.datetime.now().timestamp()
for i,(ts,pid) in enumerate(agent_starts):
    end = now
    if i+1 < len(agent_starts):
        end = max(ts+60, agent_starts[i+1][0] + 180)
    windows[pid].append((ts-60, end))

def is_agent_pid(pid, ts):
    return any(a <= ts <= b for a,b in windows.get(pid, []))

# Descendant PID -> expiry. Remote command timeout is 2h; allow 4h for nested exec evidence.
lineage = {}
direct_count = child_count = file_count = exec_events = 0
rows = []
seen_rows = set()

for e in iter_events(files):
    if e['argv'] or e['proctitle']:
        exec_events += 1
    ts, pid, ppid = e['ts'], e['pid'], e['ppid']
    direct = ppid > 0 and is_agent_pid(ppid, ts)
    child = ppid in lineage and ts <= lineage.get(ppid, 0)
    current_lineage = pid in lineage and ts <= lineage.get(pid, 0)
    kind = ''
    if direct:
        kind = 'DIRECT'
        lineage[pid] = ts + 4*3600
    elif child:
        kind = 'CHILD'
        lineage[pid] = max(lineage.get(ppid, ts + 4*3600), ts + 600)

    if kind and (e['argv'] or e['proctitle']):
        args = [e['argv'][k] for k in sorted(e['argv'])] if e['argv'] else []
        cmd = argv_text(e)
        exact = ''
        if len(args) >= 3 and os.path.basename(args[0]) in ('sh','dash','bash') and args[1] == '-c':
            exact = ' '.join(args[2:])
        display = exact or cmd
        paths = '; '.join(f'{nt}:{name}' if nt else name for nt,name in e['paths'][:30])
        row = (kind, iso(ts), str(pid), str(ppid), e['exe'], e['cwd'], display, paths)
        if row not in seen_rows:
            seen_rows.add(row); rows.append(row)
            if kind == 'DIRECT': direct_count += 1
            else: child_count += 1

    if (current_lineage or kind) and e['paths']:
        interesting = []
        for nt,name in e['paths']:
            low = name.lower()
            if nt.upper() in ('CREATE','DELETE') or low.startswith(('/tmp/','/var/tmp/','/dev/shm/','/etc/','/root/','/home/','/opt/','/usr/local/')):
                interesting.append(f'{nt}:{name}' if nt else name)
        if interesting:
            cmd = argv_text(e) or e['comm']
            row = ('FILE', iso(ts), str(pid), str(ppid), e['exe'], e['cwd'], cmd, '; '.join(interesting[:50]))
            if row not in seen_rows:
                seen_rows.add(row); rows.append(row); file_count += 1

with open(out_path, 'w') as out:
    for row in sorted(rows, key=lambda r: r[1]):
        out.write('\t'.join(clean(x) for x in row) + '\n')
with open(meta_path, 'w') as m:
    m.write(f'direct={direct_count}\nchild={child_count}\nfile={file_count}\nexec_events={exec_events}\nagent_pids={len(windows)}\n')
PY

  if [[ -s "$AUDIT_META" ]]; then
    AUDIT_DIRECT="$(awk -F= '$1=="direct"{print $2}' "$AUDIT_META" 2>/dev/null || echo 0)"
    AUDIT_CHILD="$(awk -F= '$1=="child"{print $2}' "$AUDIT_META" 2>/dev/null || echo 0)"
    AUDIT_FILEOPS="$(awk -F= '$1=="file"{print $2}' "$AUDIT_META" 2>/dev/null || echo 0)"
    AUDIT_EXEC_EVENTS="$(awk -F= '$1=="exec_events"{print $2}' "$AUDIT_META" 2>/dev/null || echo 0)"
  else
    AUDIT_EXEC_EVENTS=0
  fi

  DIRECT_OUT="$TMP/audit_direct"
  CHILD_OUT="$TMP/audit_child"
  FILE_OUT="$TMP/audit_files"
  awk -F '\t' '$1=="DIRECT" {printf "时间=%s pid=%s ppid=%s exe=%s cwd=%s\n命令=%s\n相关路径=%s\n---\n",$2,$3,$4,$5,$6,$7,$8}' "$AUDIT_OUT" > "$DIRECT_OUT" || true
  awk -F '\t' '$1=="CHILD" {printf "时间=%s pid=%s ppid=%s exe=%s cwd=%s\n子进程=%s\n相关路径=%s\n---\n",$2,$3,$4,$5,$6,$7,$8}' "$AUDIT_OUT" > "$CHILD_OUT" || true
  awk -F '\t' '$1=="FILE" {printf "时间=%s pid=%s ppid=%s exe=%s cwd=%s\n进程=%s\n文件=%s\n---\n",$2,$3,$4,$5,$6,$7,$8}' "$AUDIT_OUT" > "$FILE_OUT" || true

  subsection "已确认由 Agent 直接启动的命令"
  if [[ "$AUDIT_DIRECT" =~ ^[0-9]+$ ]] && ((AUDIT_DIRECT > 0)); then
    finding CONFIRMED "auditd 还原出 $AUDIT_DIRECT 条由 nezha-agent 直接派生的命令。"
    print_limited "$DIRECT_OUT"
    while IFS=$'\t' read -r kind ts pid ppid exe cwd command paths; do
      [[ "$kind" == "DIRECT" ]] || continue
      if is_high_risk_command <<<"$command"; then
        finding HIGH "远程命令包含高风险行为：时间=$ts 命令=$command"
      elif is_suspicious_text <<<"$command"; then
        finding SUSPICIOUS "远程命令包含可疑行为：时间=$ts 命令=$command"
      fi
    done < "$AUDIT_OUT"
  else
    finding INFO "audit 日志中未还原出 Agent 直接派生命令。"
  fi

  subsection "远程命令继续启动的子进程"
  if [[ "$AUDIT_CHILD" =~ ^[0-9]+$ ]] && ((AUDIT_CHILD > 0)); then
    finding SUSPICIOUS "发现 $AUDIT_CHILD 条 Agent 命令的后续子进程执行记录。"
    print_limited "$CHILD_OUT"
  else
    echo "未发现可关联的后续子进程记录。"
  fi

  subsection "Agent 命令进程关联的文件路径"
  if [[ "$AUDIT_FILEOPS" =~ ^[0-9]+$ ]] && ((AUDIT_FILEOPS > 0)); then
    finding SUSPICIOUS "发现 $AUDIT_FILEOPS 条与 Agent 命令进程相关的文件路径记录。"
    print_limited "$FILE_OUT"
  else
    echo "未发现可关联的文件操作记录。"
  fi

  if ((AUDIT_ENABLED == 0)); then
    finding GAP "auditd 当前未启用；日志可能来自旧文件，当前及未来命令不一定被记录。"
  elif ((AUDIT_EXEC_COVERAGE == 0)); then
    finding GAP "未在当前 audit 规则中发现 execve/执行监控规则；即使没有命中，也不能证明未执行命令。"
  else
    finding INFO "当前 audit 规则包含进程执行监控，历史还原可信度较高。"
  fi
  if [[ "$AUDIT_EXEC_EVENTS" =~ ^[0-9]+$ ]] && ((AUDIT_EXEC_EVENTS == 0)); then
    finding GAP "检查窗口内 audit 日志没有 EXECVE/PROCTITLE 记录。"
  fi
else
  if ! have python3; then
    finding GAP "系统没有 python3，无法解析并关联 audit 事件。"
  fi
  if ((${#AUDIT_FILES[@]} == 0)); then
    finding GAP "未找到 /var/log/audit/audit.log*，无法精确还原历史远程命令。"
  fi
  if ((${#AUDIT_FILES[@]})); then
    subsection "audit 日志关键词降级检查"
    zgrep -hEi 'nezha-agent|/opt/nezha/agent|comm="(sh|bash|dash)"|\.mcp-xfer-' "${AUDIT_FILES[@]}" 2>/dev/null \
      | sed -n "1,${MAX_ITEMS}p" || true
  fi
fi

# ---------------------------------------------------------------------------
section "5. 文件上传、脚本落地与近期可执行文件"

SCAN_ROOTS=(/opt/nezha /tmp /var/tmp /dev/shm /root /home /usr/local/bin /usr/local/sbin /etc/systemd/system /etc/cron.d /var/spool/cron /etc/ssh)
if ((DEEP_SCAN)); then
  SCAN_ROOTS=(/)
  finding INFO "已启用深度扫描；将扫描根文件系统并跳过 proc/sys/dev/run。"
fi

MCP_TEMP="$TMP/mcp_temp"
: > "$MCP_TEMP"
if ((DEEP_SCAN)); then
  find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
    -type f -name '.mcp-xfer-*' -print 2>/dev/null > "$MCP_TEMP" || true
else
  for r in "${SCAN_ROOTS[@]}"; do
    [[ -e "$r" ]] || continue
    find "$r" -xdev -type f -name '.mcp-xfer-*' -print 2>/dev/null >> "$MCP_TEMP" || true
  done
fi
sort -u -o "$MCP_TEMP" "$MCP_TEMP"

if [[ -s "$MCP_TEMP" ]]; then
  MCP_TEMP_COUNT="$(wc -l < "$MCP_TEMP")"
  finding HIGH "发现 $MCP_TEMP_COUNT 个 Nezha MCP 文件传输临时文件（.mcp-xfer-*）；可能是中断或失败的上传。"
  while IFS= read -r f; do
    stat_line "$f"
    have file && file -L -- "$f" 2>/dev/null || true
    sha256_file "$f"
  done < <(sed -n "1,${MAX_ITEMS}p" "$MCP_TEMP")
else
  finding INFO "未发现残留的 .mcp-xfer-* 临时上传文件。"
fi

RECENT_FILES="$TMP/recent_susp_files"
: > "$RECENT_FILES"
find_recent() {
  local root="$1"
  [[ -e "$root" ]] || return 0
  find "$root" -xdev -type f -newermt "@$START_EPOCH" \
    \( -perm /111 \
       -o -iname '*.sh' -o -iname '*.bash' -o -iname '*.py' -o -iname '*.pl' -o -iname '*.php' \
       -o -iname '*.so' -o -iname '*.service' -o -iname '*.timer' -o -iname '*.socket' \
       -o -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.zip' -o -iname '*.7z' \
       -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' \
       -o -name 'authorized_keys' -o -name 'authorized_keys2' \) \
    -printf '%T@\t%p\n' 2>/dev/null || true
}

if ((DEEP_SCAN)); then
  find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /var/lib/docker/overlay2 \) -prune -o \
    -type f -newermt "@$START_EPOCH" \
    \( -perm /111 -o -iname '*.sh' -o -iname '*.py' -o -iname '*.service' -o -iname '*.so' \
       -o -iname '*.zip' -o -iname '*.tgz' -o -iname '*.jpg' -o -iname '*.png' -o -name 'authorized_keys' \) \
    -printf '%T@\t%p\n' 2>/dev/null > "$RECENT_FILES" || true
else
  for r in "${SCAN_ROOTS[@]}"; do find_recent "$r" >> "$RECENT_FILES"; done
fi
sort -nr -k1,1 -u "$RECENT_FILES" -o "$RECENT_FILES"

# 仅把高风险目录或高风险文件名计入告警，其余作为时间线信息。
RECENT_HIGH="$TMP/recent_high"
awk -F '\t' 'tolower($2) ~ /^\/(tmp|var\/tmp|dev\/shm)\// || tolower($2) ~ /(xmrig|miner|kdevtmpfsi|kinsing|dpkgd|\.mcp-xfer-|authorized_keys|\/etc\/systemd\/system\/|\/etc\/cron|\/var\/spool\/cron)/ {print}' "$RECENT_FILES" > "$RECENT_HIGH" || true

if [[ -s "$RECENT_FILES" ]]; then
  subsection "近期脚本、可执行文件、压缩包、图片和敏感配置"
  shown=0
  while IFS=$'\t' read -r epoch f; do
    [[ -e "$f" ]] || continue
    stat_line "$f"
    have file && file -L -- "$f" 2>/dev/null || true
    ((shown++))
    ((shown >= MAX_ITEMS)) && break
  done < "$RECENT_FILES"
  total="$(wc -l < "$RECENT_FILES")"
  ((total > MAX_ITEMS)) && echo "... 已截断，共 $total 条"
fi

if [[ -s "$RECENT_HIGH" ]]; then
  RECENT_SUSP_FILES="$(wc -l < "$RECENT_HIGH")"
  finding SUSPICIOUS "发现 $RECENT_SUSP_FILES 个位于高风险位置或名称异常的近期文件，请与远程命令时间对照。"
  cut -f2- "$RECENT_HIGH" | sed -n "1,${MAX_ITEMS}p"
else
  finding INFO "未在重点目录发现明显高风险的近期文件。"
fi

# ---------------------------------------------------------------------------
section "6. 远程命令常见后果：持久化、账号与 SSH 密钥"

PERSIST="$TMP/persistence"
: > "$PERSIST"
find /etc/systemd/system /usr/local/lib/systemd/system -xdev -type f -newermt "@$START_EPOCH" -print 2>/dev/null >> "$PERSIST" || true
for f in /etc/crontab /etc/anacrontab /etc/cron.d/* /var/spool/cron/* /var/spool/cron/crontabs/* /etc/rc.local; do
  [[ -f "$f" ]] || continue
  find "$f" -maxdepth 0 -newermt "@$START_EPOCH" -print 2>/dev/null >> "$PERSIST" || true
done
sort -u -o "$PERSIST" "$PERSIST"

if [[ -s "$PERSIST" ]]; then
  PERSIST_COUNT="$(wc -l < "$PERSIST")"
  finding SUSPICIOUS "最近 $DAYS 天有 $PERSIST_COUNT 个 systemd/Cron/启动文件发生变更。"
  while IFS= read -r f; do
    stat_line "$f"
    grep -Ev '^[[:space:]]*(#|$)' "$f" 2>/dev/null | sed -n '1,80p' || true
    echo "---"
  done < <(sed -n "1,${MAX_ITEMS}p" "$PERSIST")
else
  finding INFO "重点持久化位置未发现检查窗口内的文件变更。"
fi

PERSIST_SUS="$TMP/persistence_suspicious"
: > "$PERSIST_SUS"
while IFS= read -r f; do
  [[ -r "$f" ]] || continue
  grep -Ein 'xmrig|miner|kdevtmpfsi|kinsing|dpkgd|/dev/shm|/var/tmp|/tmp/\.|curl.+\|.*sh|wget.+\|.*sh|base64.+(-d|--decode)|nohup|setsid|socat|chisel|frpc|gost|realm' "$f" 2>/dev/null \
    | sed "s|^|$f:|" >> "$PERSIST_SUS" || true
done < "$PERSIST"
if [[ -s "$PERSIST_SUS" ]]; then
  finding HIGH "持久化配置命中下载执行、挖矿、代理或临时目录特征。"
  print_limited "$PERSIST_SUS"
fi

subsection "账号"
UID_MIN="$(awk '$1=="UID_MIN"{print $2; exit}' /etc/login.defs 2>/dev/null || echo 1000)"
[[ "$UID_MIN" =~ ^[0-9]+$ ]] || UID_MIN=1000
while IFS=: read -r name _ uid gid gecos home shell; do
  [[ "$uid" =~ ^[0-9]+$ ]] || continue
  if ((uid == 0)) && [[ "$name" != root ]]; then
    ((ACCOUNT_COUNT++))
    finding HIGH "发现额外 UID 0 账号：$name home=$home shell=$shell"
  elif ((uid >= UID_MIN)) && [[ "$shell" != */nologin && "$shell" != */false ]]; then
    echo "可登录账号：user=$name uid=$uid gid=$gid home=$home shell=$shell"
  fi
done < /etc/passwd

for f in /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers; do
  [[ -e "$f" ]] || continue
  if find "$f" -maxdepth 0 -newermt "@$START_EPOCH" -print -quit 2>/dev/null | grep -q .; then
    finding RISK "$f 在检查窗口内发生过变更。"
    stat_line "$f"
  fi
done
while IFS= read -r f; do
  finding RISK "sudo 配置近期变更：$f"
  stat_line "$f"
  grep -Ev '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true
done < <(find /etc/sudoers.d -maxdepth 1 -type f -newermt "@$START_EPOCH" -print 2>/dev/null)

subsection "SSH authorized_keys"
AUTH_KEYS="$TMP/authorized_keys"
find /root /home -xdev -type f \( -name authorized_keys -o -name authorized_keys2 \) -print 2>/dev/null | sort -u > "$AUTH_KEYS" || true
if [[ -s "$AUTH_KEYS" ]]; then
  while IFS= read -r f; do
    stat_line "$f"
    nonempty="$(grep -Ev '^[[:space:]]*(#|$)' "$f" 2>/dev/null | wc -l || echo 0)"
    if [[ "$nonempty" =~ ^[0-9]+$ ]] && ((nonempty > 0)); then
      KEY_COUNT=$((KEY_COUNT + nonempty))
      finding SUSPICIOUS "$f 含 $nonempty 条有效公钥，请逐条确认。"
      if have ssh-keygen; then
        ssh-keygen -lf "$f" 2>/dev/null || true
      else
        grep -En '^[[:space:]]*(from=|command=|environment=|no-|restrict|ssh-|ecdsa-)' "$f" 2>/dev/null || true
      fi
    fi
    if find "$f" -maxdepth 0 -newermt "@$START_EPOCH" -print -quit 2>/dev/null | grep -q .; then
      finding RISK "SSH 公钥文件在检查窗口内发生过变更：$f"
    fi
  done < "$AUTH_KEYS"
else
  finding INFO "未发现 authorized_keys 文件。"
fi

subsection "SSH 成功登录来源"
AUTH_LOG="$TMP/auth.log"
: > "$AUTH_LOG"
if have journalctl; then
  journalctl --since "@$START_EPOCH" --no-pager -o short-iso -u ssh.service -u sshd.service 2>/dev/null >> "$AUTH_LOG" || true
fi
for f in /var/log/auth.log /var/log/auth.log.1 /var/log/secure /var/log/secure-*; do
  [[ -r "$f" ]] && cat "$f" >> "$AUTH_LOG" 2>/dev/null || true
done
SSH_SUCCESS="$TMP/ssh_success"
grep -Ei 'Accepted (password|publickey|keyboard-interactive).* for ' "$AUTH_LOG" 2>/dev/null | awk '!seen[$0]++' > "$SSH_SUCCESS" || true
if [[ -s "$SSH_SUCCESS" ]]; then
  print_limited "$SSH_SUCCESS"
  if grep -Eqi 'Accepted (password|publickey|keyboard-interactive).* for root ' "$SSH_SUCCESS"; then
    finding HIGH "检查窗口内存在 root SSH 成功登录；请核对全部来源 IP。"
  fi
else
  finding INFO "可用认证日志中未找到检查窗口内的 SSH 成功登录。"
fi

# ---------------------------------------------------------------------------
section "7. 当前进程、监听端口与恶意特征"

PROC_SUS="$TMP/proc_suspicious"
ps -eo pid=,ppid=,user=,lstart=,%cpu=,%mem=,args= --sort=-%cpu 2>/dev/null \
  | grep -Ei 'xmrig|minerd|cpuminer|kdevtmpfsi|kinsing|watchbog|dpkgd|stratum|/dev/shm|/var/tmp/\.|/tmp/\.|socat|chisel|frpc|gost|realm' \
  | grep -vE 'grep -E|nezha_agent_rce_forensics' > "$PROC_SUS" || true
if [[ -s "$PROC_SUS" ]]; then
  finding SUSPICIOUS "当前进程命中挖矿、代理、隧道或临时目录执行特征。"
  print_limited "$PROC_SUS"
else
  finding INFO "当前进程未命中内置恶意特征。"
fi

if have ss; then
  NET_SUS="$TMP/net_suspicious"
  ss -Hantup 2>/dev/null | grep -Ei ':(3333|4444|5555|7777|8888|9999|14444|14433)([[:space:]]|$)|xmrig|minerd|kdevtmpfsi|kinsing' > "$NET_SUS" || true
  if [[ -s "$NET_SUS" ]]; then
    finding SUSPICIOUS "发现常见矿池端口或相关进程网络连接；端口匹配可能存在误报。"
    print_limited "$NET_SUS"
  fi
  subsection "当前监听端口（前 $MAX_ITEMS 条）"
  ss -Hlntup 2>/dev/null | sed -n "1,${MAX_ITEMS}p" || true
fi

# ---------------------------------------------------------------------------
section "8. 结论"

printf '已确认命令=%s  高危=%s  可疑=%s  风险=%s  取证缺口=%s  检测失败=%s\n' \
  "$CONFIRMED" "$HIGH" "$SUSPICIOUS" "$RISK" "$VISIBILITY_GAPS" "$ERRORS"
printf 'audit直接命令=%s  audit子进程=%s  audit文件记录=%s  当前Agent子进程=%s  MCP临时文件=%s\n' \
  "$AUDIT_DIRECT" "$AUDIT_CHILD" "$AUDIT_FILEOPS" "$LIVE_CHILDREN" "$MCP_TEMP_COUNT"

if ((CONFIRMED > 0)); then
  printf '%s%s结论：已确认 nezha-agent 派生执行过命令。请按上方“命令=”逐条处置，并结合时间检查文件、账号、SSH 和持久化。%s\n' "$B" "$RED" "$C0"
elif ((HIGH > 0 || SUSPICIOUS > 0)); then
  printf '%s%s结论：发现高风险或可疑痕迹，不能判定机器安全。%s\n' "$B" "$RED" "$C0"
elif ((VISIBILITY_GAPS > 0)); then
  printf '%s%s结论：未发现明确入侵痕迹，但历史审计不足，无法证明未通过 Nezha 执行过命令。%s\n' "$B" "$YEL" "$C0"
else
  printf '%s%s机器安全：检查窗口内未发现 nezha-agent 远程命令、上传或持久化痕迹。%s\n' "$B" "$GRN" "$C0"
fi

if ((REMOTE_ENABLED > 0)); then
  echo "建议：确认业务允许后，在 Agent 配置中启用 disable_command_execute: true 或 --disable-command-execute，并轮换面板/Agent 密钥。"
fi
if ((AUDIT_EXEC_COVERAGE == 0)); then
  echo "建议：在处置完成后启用 auditd 的 execve/execveat 审计，以便未来精确还原命令。"
fi
[[ -n "$OUTPUT_FILE" ]] && echo "完整结果已保存：$OUTPUT_FILE"

echo "说明：只读检测无法补回已经被清理或从未记录的历史证据；获得过 root 权限的主机最终仍应从可信镜像重建。"

if ((ERRORS > 0)); then
  exit 2
elif ((CONFIRMED > 0 || HIGH > 0 || SUSPICIOUS > 0)); then
  exit 1
else
  exit 0
fi
