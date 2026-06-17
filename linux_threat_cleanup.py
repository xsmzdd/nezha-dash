#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Linux 挖矿/后门/SSH 入侵审计与清理工具

默认只审计。修复模式使用 --remediate；永久删除还需 --purge --yes。
SSH 注入公钥必须通过可信基线或显式白名单判断，避免误删合法密钥。
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import ipaddress
import json
import os
import pwd
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Iterable, Optional

VERSION = "1.0.0"
STATE_DIR = Path("/var/lib/linux-threat-cleanup")
LOG_DIR = Path("/var/log/linux-threat-cleanup")
QUARANTINE_DIR = Path("/var/quarantine/linux-threat-cleanup")

MINER_NAMES = {
    "xmrig", "xmrig-notls", "xmrig-proxy", "minerd", "cpuminer",
    "cpuminer-multi", "ethminer", "nbminer", "lolminer", "nanominer",
    "kinsing", "kdevtmpfsi", "watchbog", "dbused", "sysupdate",
}
MINING_PORTS = {3333, 3334, 4444, 5555, 7777, 8888, 9999, 14444, 19999}
RISKY_PREFIXES = ("/tmp/", "/var/tmp/", "/dev/shm/", "/run/user/")
PROTECTED_PREFIXES = (
    "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/lib/",
    "/usr/lib64/", "/lib/", "/lib64/", "/boot/", "/proc/", "/sys/", "/dev/",
)
SCAN_ROOTS = ("/tmp", "/var/tmp", "/dev/shm", "/run/user", "/usr/local/bin", "/usr/local/sbin", "/opt", "/root", "/home")
PERSISTENCE_FILES = (
    "/etc/crontab", "/etc/rc.local", "/etc/profile", "/etc/bash.bashrc", "/etc/ld.so.preload",
)

CMD_RULES = [
    (re.compile(r"(?i)stratum(?:\+tcp|\+ssl)?://"), 8, "包含 stratum 矿池地址"),
    (re.compile(r"(?i)\b(?:xmrig|minerd|cpuminer|kinsing|kdevtmpfsi|watchbog)\b"), 8, "包含已知挖矿名称"),
    (re.compile(r"(?i)--donate-level\b"), 6, "包含 XMRig 参数"),
    (re.compile(r"(?i)/dev/tcp/[A-Za-z0-9_.:-]+/\d+"), 9, "Bash /dev/tcp 反向连接"),
    (re.compile(r"(?i)\bnc(?:at)?\b.*\s-e\s"), 9, "Netcat -e 反向 Shell"),
    (re.compile(r"(?i)\bsocat\b.*\bexec:"), 9, "Socat EXEC 后门"),
    (re.compile(r"(?i)\bbase64\b.*(?:-d|--decode).*\|\s*(?:ba)?sh"), 8, "Base64 解码后执行"),
]
BYTE_RULES = [
    (re.compile(rb"(?i)stratum(?:\+tcp|\+ssl)?://"), 8, "包含 stratum 矿池地址"),
    (re.compile(rb"(?i)\bxmrig\b"), 8, "包含 XMRig 标识"),
    (re.compile(rb"(?i)--donate-level\b"), 6, "包含 XMRig 参数"),
    (re.compile(rb"(?is)\bcurl\b.{0,400}\|\s*(?:/bin/)?(?:ba)?sh\b"), 7, "curl 下载后执行"),
    (re.compile(rb"(?is)\bwget\b.{0,400}\|\s*(?:/bin/)?(?:ba)?sh\b"), 7, "wget 下载后执行"),
    (re.compile(rb"(?i)/dev/tcp/[A-Za-z0-9_.:-]+/\d+"), 9, "Bash /dev/tcp 反向连接"),
    (re.compile(rb"(?i)\bnc(?:at)?\b.{0,200}\s-e\s"), 9, "Netcat -e 反向 Shell"),
    (re.compile(rb"(?i)\bsocat\b.{0,300}\bexec:"), 9, "Socat EXEC 后门"),
]
LINE_RULES = [
    (re.compile(r"(?i)stratum(?:\+tcp|\+ssl)?://"), 9, "矿池地址"),
    (re.compile(r"(?i)\b(?:xmrig|minerd|cpuminer|kinsing|kdevtmpfsi|watchbog)\b"), 9, "已知挖矿名称"),
    (re.compile(r"(?i)\bcurl\b.{0,400}\|\s*(?:/bin/)?(?:ba)?sh\b"), 8, "curl 管道执行"),
    (re.compile(r"(?i)\bwget\b.{0,400}\|\s*(?:/bin/)?(?:ba)?sh\b"), 8, "wget 管道执行"),
    (re.compile(r"(?i)\bbase64\b.{0,300}(?:-d|--decode).{0,300}\|\s*(?:/bin/)?(?:ba)?sh\b"), 9, "Base64 解码执行"),
    (re.compile(r"(?i)/dev/tcp/[A-Za-z0-9_.:-]+/\d+"), 10, "Bash 反向连接"),
    (re.compile(r"(?i)\bnc(?:at)?\b.{0,200}\s-e\s"), 10, "Netcat -e"),
    (re.compile(r"(?i)\bsocat\b.{0,300}\bexec:"), 10, "Socat EXEC"),
    (re.compile(r"(?i)(?:^|\s)(?:/tmp|/var/tmp|/dev/shm|/run/user)/[^\s;|&]+"), 4, "从临时目录执行"),
    (re.compile(r"(?i)\bLD_PRELOAD\s*="), 7, "LD_PRELOAD 持久化"),
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="检查并清理 Linux 挖矿、后门、恶意文件和 SSH 公钥注入")
    p.add_argument("--remediate", action="store_true", help="执行停止进程、删除注入公钥、修复权限并隔离恶意文件")
    p.add_argument("--purge", action="store_true", help="隔离后永久删除，必须同时使用 --remediate --yes")
    p.add_argument("--yes", action="store_true", help="确认永久删除")
    p.add_argument("--init-ssh-baseline", action="store_true", help="创建可信 SSH 基线")
    p.add_argument("--restore-ssh-baseline", action="store_true", help="修复时恢复 authorized_keys 和 .ssh/config 基线副本")
    p.add_argument("--enforce-key-allowlist", action="store_true", help="无基线时删除不在白名单中的 SSH 公钥")
    p.add_argument("--allow-key", action="append", default=[], help="允许的 SSH 指纹 SHA256:...")
    p.add_argument("--allow-key-file", type=Path, help="SSH 指纹白名单，每行一个")
    p.add_argument("--state-dir", type=Path, default=STATE_DIR)
    p.add_argument("--output-dir", type=Path, default=LOG_DIR)
    p.add_argument("--quarantine-dir", type=Path, default=QUARANTINE_DIR)
    p.add_argument("--scan-root", action="append", default=[], help="扫描目录，可重复")
    p.add_argument("--max-files", type=int, default=50000)
    p.add_argument("--max-file-size", type=int, default=32 * 1024 * 1024)
    p.add_argument("--clamav", choices=("auto", "yes", "no"), default="auto")
    p.add_argument("--since", default="90 days ago", help="journalctl SSH 日志起始时间")
    p.add_argument("--include-system-users", action="store_true")
    p.add_argument("--self-test", action="store_true")
    return p.parse_args()


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
    except FileNotFoundError as e:
        raise RuntimeError(f"命令不存在: {cmd[0]}") from e
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"命令超时: {' '.join(cmd)}") from e


def now() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def protected(path: Path) -> bool:
    p = os.path.abspath(str(path))
    return any(p == x.rstrip("/") or p.startswith(x) for x in PROTECTED_PREFIXES)


def backup(path: Path, state_dir: Path, category: str) -> Optional[Path]:
    if not path.exists() or not path.is_file():
        return None
    private_dir(state_dir / "backups" / category)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    name = str(path).strip("/").replace("/", "__")
    dest = state_dir / "backups" / category / f"{stamp}-{name}"
    shutil.copy2(path, dest)
    os.chmod(dest, 0o600)
    return dest


def atomic_write(path: Path, data: bytes, mode: int, uid: int, gid: int) -> None:
    tmp = path.with_name(path.name + f".tmp-{os.getpid()}")
    with tmp.open("wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.chown(tmp, uid, gid)
    os.replace(tmp, path)


def login_users(include_system: bool) -> list[pwd.struct_passwd]:
    result = []
    for u in pwd.getpwall():
        if not u.pw_dir or not os.path.isdir(u.pw_dir):
            continue
        shell_ok = u.pw_shell not in {"/usr/sbin/nologin", "/sbin/nologin", "/bin/false", "/usr/bin/false"}
        if u.pw_uid == 0 or shell_ok or include_system:
            result.append(u)
    result.sort(key=lambda x: (x.pw_uid != 0, x.pw_uid))
    return result


def key_fingerprint(line: str) -> Optional[str]:
    parts = line.strip().split()
    if not parts or line.lstrip().startswith("#"):
        return None
    idx = next((i for i, x in enumerate(parts) if x.startswith(("ssh-", "ecdsa-", "sk-"))), None)
    if idx is None or idx + 1 >= len(parts):
        return None
    try:
        blob = base64.b64decode(parts[idx + 1], validate=True)
    except Exception:
        return None
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")


def key_options(line: str) -> list[str]:
    parts = line.strip().split()
    idx = next((i for i, x in enumerate(parts) if x.startswith(("ssh-", "ecdsa-", "sk-"))), None)
    if idx in (None, 0):
        return []
    return [x.strip() for x in " ".join(parts[:idx]).split(",") if x.strip()]


def ssh_state(args: argparse.Namespace, copy_dir: Optional[Path] = None) -> dict[str, Any]:
    users: dict[str, Any] = {}
    for u in login_users(args.include_system_users):
        d = Path(u.pw_dir) / ".ssh"
        if not d.exists() and not d.is_symlink():
            continue
        item: dict[str, Any] = {"uid": u.pw_uid, "gid": u.pw_gid, "home": u.pw_dir, "dir": str(d), "files": {}, "keys": []}
        try:
            st = d.lstat()
            item["dir_mode"] = stat.S_IMODE(st.st_mode)
            item["dir_uid"] = st.st_uid
            item["dir_gid"] = st.st_gid
            item["dir_symlink"] = d.is_symlink()
        except OSError:
            pass
        if d.is_dir() and not d.is_symlink():
            for f in d.iterdir():
                try:
                    st = f.lstat()
                except OSError:
                    continue
                rec = {"path": str(f), "mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid, "symlink": f.is_symlink()}
                if stat.S_ISREG(st.st_mode):
                    try:
                        rec["sha256"] = sha256_file(f)
                    except OSError:
                        pass
                item["files"][f.name] = rec
                if f.name in {"authorized_keys", "authorized_keys2"} and f.is_file() and not f.is_symlink():
                    lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
                    for n, line in enumerate(lines, 1):
                        fp = key_fingerprint(line)
                        if fp:
                            item["keys"].append({"file": f.name, "line": n, "fingerprint": fp, "options": key_options(line)})
                    if copy_dir:
                        dest = copy_dir / u.pw_name
                        private_dir(dest)
                        shutil.copy2(f, dest / f.name)
                        os.chmod(dest / f.name, 0o600)
                if f.name == "config" and f.is_file() and not f.is_symlink() and copy_dir:
                    dest = copy_dir / u.pw_name
                    private_dir(dest)
                    shutil.copy2(f, dest / f.name)
                    os.chmod(dest / f.name, 0o600)
        users[u.pw_name] = item
    return {"created_at": now(), "users": users}


def init_baseline(args: argparse.Namespace) -> int:
    if os.geteuid() != 0:
        print("创建基线需要 root", file=sys.stderr)
        return 2
    private_dir(args.state_dir)
    copy_dir = args.state_dir / "ssh_baseline_files"
    if copy_dir.exists():
        shutil.move(str(copy_dir), str(args.state_dir / ("ssh_baseline_files.old-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S"))))
    private_dir(copy_dir)
    data = ssh_state(args, copy_dir)
    data["warning"] = "仅在人工确认当前 SSH 公钥可信后使用此基线"
    path = args.state_dir / "ssh_baseline.json"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(path, 0o600)
    print(f"SSH 基线已创建: {path}")
    return 0


def load_baseline(args: argparse.Namespace) -> Optional[dict[str, Any]]:
    path = args.state_dir / "ssh_baseline.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def allow_keys(args: argparse.Namespace) -> set[str]:
    result = {x.strip() for x in args.allow_key if x.strip()}
    if args.allow_key_file and args.allow_key_file.exists():
        for line in args.allow_key_file.read_text(encoding="utf-8", errors="replace").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                result.add(line)
    return result


def expected_mode(name: str) -> int:
    if name.endswith(".pub"):
        return 0o644
    return 0o600


def remove_keys(path: Path, fps: set[str], u: pwd.struct_passwd, args: argparse.Namespace) -> dict[str, Any]:
    result = {"path": str(path), "removed": [], "status": "NOT_CHANGED"}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    except OSError as e:
        result["status"] = f"ERROR: {e}"
        return result
    kept = []
    for line in lines:
        fp = key_fingerprint(line)
        if fp and fp in fps:
            result["removed"].append(fp)
        else:
            kept.append(line)
    if not result["removed"]:
        return result
    b = backup(path, args.state_dir, "ssh_keys")
    atomic_write(path, "".join(kept).encode(), 0o600, u.pw_uid, u.pw_gid)
    result["status"] = "REMOVED"
    result["backup"] = str(b) if b else None
    return result


def repair_ssh(args: argparse.Namespace) -> dict[str, Any]:
    baseline = load_baseline(args)
    current = ssh_state(args)
    allowed = allow_keys(args)
    user_map = {u.pw_name: u for u in login_users(args.include_system_users)}
    output = {"baseline_loaded": bool(baseline), "tampering_detected": False, "removed_key_count": 0, "permission_repair_count": 0, "users": []}
    for name, cur in current["users"].items():
        u = user_map.get(name)
        if not u:
            continue
        base = ((baseline or {}).get("users") or {}).get(name)
        base_fps = {x["fingerprint"] for x in (base or {}).get("keys", [])}
        cur_fps = {x["fingerprint"] for x in cur.get("keys", [])}
        added = sorted(cur_fps - base_fps) if base else []
        removed = sorted(base_fps - cur_fps) if base else []
        untrusted: set[str] = set()
        method = "NO_BASELINE_NO_DELETION"
        if base:
            untrusted = {x for x in added if x not in allowed}
            method = "BASELINE"
        elif args.enforce_key_allowlist and allowed:
            untrusted = {x for x in cur_fps if x not in allowed}
            method = "ALLOWLIST"
        if added or removed:
            output["tampering_detected"] = True
        changes = []
        base_files = (base or {}).get("files", {})
        for fn, info in cur.get("files", {}).items():
            if fn in base_files and info.get("sha256") != base_files[fn].get("sha256"):
                changes.append(fn)
                output["tampering_detected"] = True
        suspicious_options = []
        for k in cur.get("keys", []):
            bad = [x for x in k.get("options", []) if x.startswith(("command=", "environment=", "permitopen=", "tunnel="))]
            if bad:
                suspicious_options.append({"fingerprint": k["fingerprint"], "options": bad})
        repairs = []
        d = Path(cur["dir"])
        try:
            st = d.lstat()
            if stat.S_IMODE(st.st_mode) != 0o700 or st.st_uid != u.pw_uid or st.st_gid != u.pw_gid:
                output["tampering_detected"] = True
                action = "DETECTED_NOT_REPAIRED"
                if args.remediate and not d.is_symlink():
                    os.chmod(d, 0o700); os.chown(d, u.pw_uid, u.pw_gid)
                    action = "REPAIRED"; output["permission_repair_count"] += 1
                repairs.append({"path": str(d), "status": action})
        except OSError:
            pass
        for fn, info in cur.get("files", {}).items():
            p = Path(info["path"])
            if info.get("symlink"):
                output["tampering_detected"] = True
                repairs.append({"path": str(p), "status": "SYMLINK_DETECTED_NOT_CHANGED"})
                continue
            mode = expected_mode(fn)
            if info.get("mode") != mode or info.get("uid") != u.pw_uid or info.get("gid") != u.pw_gid:
                output["tampering_detected"] = True
                action = "DETECTED_NOT_REPAIRED"
                if args.remediate:
                    try:
                        os.chmod(p, mode); os.chown(p, u.pw_uid, u.pw_gid)
                        action = "REPAIRED"; output["permission_repair_count"] += 1
                    except OSError as e:
                        action = f"ERROR: {e}"
                repairs.append({"path": str(p), "status": action})
        key_actions = []
        if args.remediate and untrusted:
            by_file: dict[str, set[str]] = {}
            for k in cur.get("keys", []):
                if k["fingerprint"] in untrusted:
                    by_file.setdefault(k["file"], set()).add(k["fingerprint"])
            for fn, fps in by_file.items():
                a = remove_keys(d / fn, fps, u, args)
                key_actions.append(a)
                output["removed_key_count"] += len(a.get("removed", []))
        restore = []
        if args.remediate and args.restore_ssh_baseline and base:
            for fn in ("authorized_keys", "authorized_keys2", "config"):
                src = args.state_dir / "ssh_baseline_files" / name / fn
                dst = d / fn
                if src.exists() and (fn not in cur.get("files", {}) or cur["files"][fn].get("sha256") != base_files.get(fn, {}).get("sha256")):
                    b = backup(dst, args.state_dir, "ssh_restore") if dst.exists() else None
                    atomic_write(dst, src.read_bytes(), expected_mode(fn), u.pw_uid, u.pw_gid)
                    restore.append({"path": str(dst), "status": "RESTORED", "backup": str(b) if b else None})
        output["users"].append({"user": name, "method": method, "added_keys": added, "removed_keys": removed, "untrusted_keys": sorted(untrusted), "hash_changes": changes, "suspicious_options": suspicious_options, "permission_repairs": repairs, "key_actions": key_actions, "restore_actions": restore})
    return output


def valid_ips(text: str) -> set[str]:
    result = set()
    for token in re.findall(r"(?:\d{1,3}(?:\.\d{1,3}){3}|[0-9A-Fa-f:]{2,})", text):
        try:
            ip = ipaddress.ip_address(token)
        except ValueError:
            continue
        if not ip.is_unspecified:
            result.add(str(ip))
    return result


def ip_key(x: str) -> tuple[int, int]:
    ip = ipaddress.ip_address(x)
    return ip.version, int(ip)


def ssh_login_ips(since: str) -> dict[str, Any]:
    all_ips: set[str] = set(); sources = []
    if shutil.which("last"):
        p = run(["last", "-i", "-w", "-F", "-n", "10000"], 60)
        ips = valid_ips(p.stdout or ""); all_ips |= ips
        sources.append({"source": "wtmp:last", "ips": sorted(ips, key=ip_key)})
    rx = re.compile(r"(?i)Accepted (?:publickey|password|keyboard-interactive).*? from (\S+)")
    for path in (Path("/var/log/auth.log"), Path("/var/log/auth.log.1"), Path("/var/log/secure"), Path("/var/log/secure-1")):
        if not path.exists():
            continue
        ips = set()
        try:
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                m = rx.search(line)
                if m: ips |= valid_ips(m.group(1))
        except OSError:
            pass
        all_ips |= ips; sources.append({"source": str(path), "ips": sorted(ips, key=ip_key)})
    if shutil.which("journalctl"):
        text = ""
        for unit in ("ssh", "sshd"):
            p = run(["journalctl", "--no-pager", "-u", unit, "--since", since, "-o", "short-iso"], 90)
            text += "\n" + (p.stdout or "")
        ips = set()
        for line in text.splitlines():
            m = rx.search(line)
            if m: ips |= valid_ips(m.group(1))
        all_ips |= ips; sources.append({"source": f"journalctl since {since}", "ips": sorted(ips, key=ip_key)})
    return {"unique_ips": sorted(all_ips, key=ip_key), "unique_count": len(all_ips), "sources": sources}


def network_ports() -> dict[int, set[int]]:
    out: dict[int, set[int]] = {}
    if not shutil.which("ss"):
        return out
    p = run(["ss", "-Hntp"], 30)
    for line in (p.stdout or "").splitlines():
        pids = [int(x) for x in re.findall(r"pid=(\d+)", line)]
        fields = line.split()
        if not pids or len(fields) < 5:
            continue
        m = re.search(r":(\d+)$", fields[4])
        if not m:
            continue
        port = int(m.group(1))
        for pid in pids: out.setdefault(pid, set()).add(port)
    return out


def processes() -> list[dict[str, Any]]:
    p = run(["ps", "-eo", "pid=,ppid=,uid=,user=,pcpu=,pmem=,comm=,args="], 60)
    result = []
    for line in (p.stdout or "").splitlines():
        parts = line.strip().split(None, 7)
        if len(parts) < 8: continue
        try:
            pid, ppid, uid = int(parts[0]), int(parts[1]), int(parts[2])
            cpu, mem = float(parts[4]), float(parts[5])
        except ValueError: continue
        try: exe = os.readlink(f"/proc/{pid}/exe")
        except OSError: exe = ""
        result.append({"pid": pid, "ppid": ppid, "uid": uid, "user": parts[3], "cpu": cpu, "mem": mem, "comm": parts[6], "args": parts[7], "exe": exe})
    return result


def audit_processes(args: argparse.Namespace) -> tuple[dict[str, Any], set[str]]:
    ps = processes(); ports = network_ports(); detections = []; roots = set(); exe_candidates = set()
    for x in ps:
        score = 0; reasons = []
        base = os.path.basename(x["exe"].replace(" (deleted)", "")) or x["comm"]
        if x["comm"].lower() in MINER_NAMES or base.lower() in MINER_NAMES:
            score += 9; reasons.append("进程名匹配已知挖矿程序")
        for rx, pts, why in CMD_RULES:
            if rx.search(x["args"]): score += pts; reasons.append(why)
        if x["exe"].endswith(" (deleted)"): score += 5; reasons.append("可执行文件已删除但进程仍运行")
        clean = x["exe"].replace(" (deleted)", "")
        if clean.startswith(RISKY_PREFIXES): score += 4; reasons.append("从临时/共享内存目录运行")
        mp = sorted(ports.get(x["pid"], set()) & MINING_PORTS)
        if mp: score += 3; reasons.append("连接常见矿池端口: " + ",".join(map(str, mp)))
        if x["cpu"] >= 80: score += 2; reasons.append("CPU 使用率高")
        if score >= 7:
            action = "HIGH_CONFIDENCE_DETECTED" if score >= 10 else "DETECTED_NOT_REMOVED"
            detections.append({"pid": x["pid"], "ppid": x["ppid"], "exe": x["exe"], "args": x["args"][:1000], "score": score, "reasons": sorted(set(reasons)), "action": action})
            if score >= 10:
                roots.add(x["pid"])
                if clean: exe_candidates.add(clean)
    remediation = None
    if args.remediate and roots:
        children: dict[int, list[int]] = {}
        for x in ps: children.setdefault(x["ppid"], []).append(x["pid"])
        allp = set(roots); stack = list(roots)
        while stack:
            for c in children.get(stack.pop(), []):
                if c not in allp: allp.add(c); stack.append(c)
        terminated = []; killed = []; errors = []
        for pid in sorted(allp, reverse=True):
            if pid in {1, os.getpid(), os.getppid()}: continue
            try: os.kill(pid, signal.SIGTERM); terminated.append(pid)
            except ProcessLookupError: pass
            except OSError as e: errors.append(f"{pid}: {e}")
        time.sleep(1)
        for pid in sorted(allp, reverse=True):
            if os.path.exists(f"/proc/{pid}") and pid not in {1, os.getpid(), os.getppid()}:
                try: os.kill(pid, signal.SIGKILL); killed.append(pid)
                except OSError: pass
        remediation = {"terminated": terminated, "killed": killed, "errors": errors}
        for d in detections:
            if d["pid"] in allp: d["action"] = "PROCESS_TERMINATED"
    return {"status": "DETECTED" if detections else "NOT_DETECTED", "detections": detections, "remediation": remediation}, exe_candidates


def score_file(path: Path, max_size: int) -> dict[str, Any]:
    try: st = path.lstat()
    except OSError: return {"score": 0}
    if not stat.S_ISREG(st.st_mode): return {"score": 0}
    score = 0; reasons = []; p = os.path.abspath(str(path))
    if path.name.lower() in MINER_NAMES: score += 9; reasons.append("文件名匹配已知挖矿程序")
    if p.startswith(RISKY_PREFIXES): score += 3; reasons.append("位于临时/共享内存目录")
    try:
        with path.open("rb") as f: data = f.read(max_size)
    except OSError: data = b""
    if data.startswith(b"\x7fELF"): score += 1; reasons.append("ELF 可执行文件")
    elif data.startswith(b"#!"): score += 1; reasons.append("脚本文件")
    for rx, pts, why in BYTE_RULES:
        if rx.search(data): score += pts; reasons.append(why)
    out = {"path": str(path), "score": score, "reasons": sorted(set(reasons)), "protected": protected(path)}
    if score >= 7:
        try: out["sha256"] = sha256_file(path)
        except OSError: pass
    return out


def quarantine(path: Path, reason: str, args: argparse.Namespace) -> dict[str, Any]:
    result = {"original_path": str(path), "status": "DETECTED_NOT_REMOVED", "reason": reason}
    if not args.remediate: return result
    if protected(path): result["status"] = "PROTECTED_PATH_MANUAL_ACTION_REQUIRED"; return result
    if not path.exists() and not path.is_symlink(): result["status"] = "ALREADY_MISSING"; return result
    private_dir(args.quarantine_dir)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    dest = args.quarantine_dir / (stamp + "-" + str(path).strip("/").replace("/", "__"))
    try:
        digest = sha256_file(path) if path.is_file() and not path.is_symlink() else None
        shutil.move(str(path), str(dest))
        if dest.is_file(): os.chmod(dest, 0o600)
        meta = {"original_path": str(path), "sha256": digest, "reason": reason, "time": now()}
        mp = Path(str(dest) + ".metadata.json")
        mp.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"); os.chmod(mp, 0o600)
        result.update({"status": "QUARANTINED", "quarantine_path": str(dest), "sha256": digest})
        if args.purge:
            if dest.is_dir(): shutil.rmtree(dest)
            else: dest.unlink(missing_ok=True)
            result["status"] = "DELETED"
    except OSError as e:
        result["status"] = f"ERROR: {e}"
    return result


def walk_files(roots: Iterable[str], max_files: int) -> Iterable[Path]:
    count = 0; seen = set()
    for root_s in roots:
        root = Path(root_s)
        if not root.exists(): continue
        try: root_dev = root.stat().st_dev
        except OSError: continue
        for cur, dirs, files in os.walk(root, topdown=True, followlinks=False):
            cp = Path(cur)
            dirs[:] = [d for d in dirs if not (cp/d).is_symlink() and d not in {".git", "node_modules", "__pycache__", ".cache"}]
            try:
                if cp.stat().st_dev != root_dev: dirs[:] = []; continue
            except OSError: dirs[:] = []; continue
            for name in files:
                if count >= max_files: return
                p = cp / name
                try: st = p.lstat()
                except OSError: continue
                if not stat.S_ISREG(st.st_mode): continue
                key = (st.st_dev, st.st_ino)
                if key in seen: continue
                seen.add(key); count += 1; yield p


def audit_files(args: argparse.Namespace, process_exes: set[str]) -> dict[str, Any]:
    roots = args.scan_root or list(SCAN_ROOTS)
    files = list(walk_files(roots, args.max_files))
    existing = {os.path.abspath(str(x)) for x in files}
    for e in process_exes:
        if Path(e).exists() and os.path.abspath(e) not in existing: files.append(Path(e))
    detections = []
    for p in files:
        item = score_file(p, args.max_file_size)
        if item.get("score", 0) < 7: continue
        if item["score"] >= 10:
            item["action"] = quarantine(p, "; ".join(item["reasons"]), args)
        else:
            item["action"] = {"status": "DETECTED_NOT_REMOVED"}
        detections.append(item)
    return {"status": "DETECTED" if detections else "NOT_DETECTED", "roots": roots, "files_considered": len(files), "detections": detections}


def persistence_paths() -> list[Path]:
    import glob
    paths = {Path(x) for x in PERSISTENCE_FILES if Path(x).is_file()}
    for pattern in ("/etc/cron.d/*", "/var/spool/cron/*", "/var/spool/cron/crontabs/*", "/etc/profile.d/*", "/etc/systemd/system/**/*.service", "/usr/local/lib/systemd/system/**/*.service"):
        for x in glob.glob(pattern, recursive=True):
            p = Path(x)
            if p.is_file() and not p.is_symlink(): paths.add(p)
    for u in login_users(False):
        for name in (".bashrc", ".bash_profile", ".profile", ".zshrc"):
            p = Path(u.pw_dir) / name
            if p.is_file() and not p.is_symlink(): paths.add(p)
    return sorted(paths)


def redact(line: str) -> str:
    line = re.sub(r"(?i)\b(token|secret|password|authorization|cookie)\s*[:=]\s*\S+", r"\1=<REDACTED>", line.strip())
    return line[:1200]


def clean_lines(path: Path, nums: set[int], args: argparse.Namespace) -> dict[str, Any]:
    result = {"path": str(path), "status": "DETECTED_NOT_REMOVED", "removed_lines": sorted(nums)}
    if not args.remediate: return result
    try:
        st = path.stat(); lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
        b = backup(path, args.state_dir, "persistence")
        kept = [x for i, x in enumerate(lines, 1) if i not in nums]
        atomic_write(path, "".join(kept).encode(), stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid)
        result["status"] = "REMOVED"; result["backup"] = str(b) if b else None
    except OSError as e: result["status"] = f"ERROR: {e}"
    return result


def audit_persistence(args: argparse.Namespace) -> dict[str, Any]:
    detections = []
    for p in persistence_paths():
        try:
            if p.stat().st_size > 4*1024*1024: continue
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError: continue
        bad = []
        for n, line in enumerate(lines, 1):
            score = 0; reasons = []
            for rx, pts, why in LINE_RULES:
                if rx.search(line): score += pts; reasons.append(why)
            if score >= 8: bad.append({"line": n, "score": score, "reasons": sorted(set(reasons)), "text": redact(line)})
        if not bad: continue
        total = sum(x["score"] for x in bad)
        if args.remediate and p.suffix == ".service" and total >= 10 and shutil.which("systemctl"):
            sp = run(["systemctl", "disable", "--now", p.name], 60)
            action = quarantine(p, "高置信度恶意 systemd 持久化", args); action["systemctl_returncode"] = sp.returncode
            run(["systemctl", "daemon-reload"], 30)
        else:
            action = clean_lines(p, {x["line"] for x in bad}, args)
        detections.append({"path": str(p), "score": total, "lines": bad, "action": action})
    return {"status": "DETECTED" if detections else "NOT_DETECTED", "detections": detections}


def clamav(args: argparse.Namespace) -> dict[str, Any]:
    exe = shutil.which("clamscan")
    enabled = args.clamav == "yes" or (args.clamav == "auto" and exe)
    if not enabled: return {"status": "SKIPPED", "reason": "ClamAV 未启用或未安装"}
    if not exe: return {"status": "ERROR", "reason": "找不到 clamscan"}
    roots = [x for x in (args.scan_root or list(SCAN_ROOTS)) if Path(x).exists()]
    p = run([exe, "--infected", "--no-summary", "--recursive", "--cross-fs=no", "--max-filesize=100M", "--max-scansize=200M", *roots], 3600)
    detections = []
    for line in (p.stdout or "").splitlines():
        m = re.match(r"^(.*):\s+(.+)\s+FOUND$", line)
        if not m: continue
        path = Path(m.group(1)); sig = m.group(2)
        detections.append({"path": str(path), "signature": sig, "action": quarantine(path, "ClamAV: " + sig, args)})
    return {"status": "DETECTED" if detections else "NOT_DETECTED", "returncode": p.returncode, "roots": roots, "detections": detections, "stderr": (p.stderr or "")[-2000:]}


def make_summary(report: dict[str, Any]) -> dict[str, Any]:
    proc = len(report["process_scan"]["detections"])
    files = len(report["file_scan"]["detections"])
    pers = len(report["persistence_scan"]["detections"])
    av = len(report["clamav_scan"].get("detections", []))
    keys = sum(len(x["untrusted_keys"]) for x in report["ssh_integrity"]["users"])
    actions = []
    for x in report["file_scan"]["detections"]: actions.append(x["action"].get("status"))
    for x in report["persistence_scan"]["detections"]: actions.append(x["action"].get("status"))
    for x in report["clamav_scan"].get("detections", []): actions.append(x["action"].get("status"))
    detected = proc + files + pers + av + keys
    if detected == 0 and not report["ssh_integrity"]["tampering_detected"]:
        verdict = "未检测出挖矿程序、后门、恶意文件或 SSH 篡改迹象"
    elif report["mode"] == "audit": verdict = "检测到可疑项目；当前为审计模式，未删除"
    else: verdict = "已执行修复；请查看每项处置状态并在重启后复查"
    return {"verdict": verdict, "processes": proc, "files": files, "persistence": pers, "clamav": av, "untrusted_keys": keys, "keys_removed": report["ssh_integrity"]["removed_key_count"], "ssh_repairs": report["ssh_integrity"]["permission_repair_count"], "deleted": sum(x == "DELETED" for x in actions), "quarantined": sum(x == "QUARANTINED" for x in actions), "detected_total": detected}


def text_report(r: dict[str, Any]) -> str:
    s = r["summary"]; lines = ["="*90, "Linux 挖矿、后门、恶意文件与 SSH 安全报告", "="*90, f"时间: {r['scan_time']}", f"主机: {r['hostname']}", f"模式: {r['mode']}", f"结论: {s['verdict']}", "", "[SSH 成功登录 IP（去重）]"]
    lines += ["  " + x for x in r["ssh_login_ips"]["unique_ips"]] or ["  未从当前日志提取到 IP"]
    lines += ["", "[挖矿/可疑进程]"]
    if not r["process_scan"]["detections"]: lines.append("  未检测出")
    for x in r["process_scan"]["detections"]:
        lines.append(f"  PID={x['pid']} score={x['score']} action={x['action']} exe={x['exe']}")
        lines += ["    - " + y for y in x["reasons"]]
    lines += ["", "[SSH 公钥与 .ssh 完整性]", f"  基线: {'已加载' if r['ssh_integrity']['baseline_loaded'] else '不存在'}", f"  是否检测到篡改/权限异常: {'是' if r['ssh_integrity']['tampering_detected'] else '否'}", f"  已删除注入公钥: {r['ssh_integrity']['removed_key_count']}", f"  已修复权限/属主: {r['ssh_integrity']['permission_repair_count']}"]
    for u in r["ssh_integrity"]["users"]:
        if u["added_keys"] or u["removed_keys"] or u["untrusted_keys"] or u["hash_changes"] or u["permission_repairs"]:
            lines.append("  用户: " + u["user"])
            if u["added_keys"]: lines.append("    新增公钥: " + ", ".join(u["added_keys"]))
            if u["untrusted_keys"]: lines.append("    未授权公钥: " + ", ".join(u["untrusted_keys"]))
            for a in u["key_actions"]: lines.append(f"    公钥处置: {a['status']} {a['path']}")
            for a in u["permission_repairs"]: lines.append(f"    权限处置: {a['status']} {a['path']}")
    if not r["ssh_integrity"]["baseline_loaded"]: lines.append("  无可信基线时不会自动删除现有 SSH 公钥。")
    lines += ["", "[持久化后门]"]
    if not r["persistence_scan"]["detections"]: lines.append("  未检测出")
    for x in r["persistence_scan"]["detections"]:
        lines.append(f"  {x['path']} score={x['score']} action={x['action']['status']}")
        for y in x["lines"]: lines.append(f"    行 {y['line']}: {', '.join(y['reasons'])} | {y['text']}")
    lines += ["", "[恶意脚本/二进制]"]
    if not r["file_scan"]["detections"]: lines.append("  未检测出")
    for x in r["file_scan"]["detections"]:
        lines.append(f"  {x['path']} score={x['score']} action={x['action']['status']}")
        if x.get("sha256"): lines.append("    sha256=" + x["sha256"])
        lines += ["    - " + y for y in x["reasons"]]
    lines += ["", "[ClamAV]"]
    if r["clamav_scan"]["status"] == "SKIPPED": lines.append("  已跳过: " + r["clamav_scan"]["reason"])
    elif not r["clamav_scan"].get("detections"): lines.append("  未检测出")
    else:
        for x in r["clamav_scan"]["detections"]: lines.append(f"  {x['path']} {x['signature']} action={x['action']['status']}")
    lines += ["", "[统计]", f"  可疑进程: {s['processes']}", f"  启发式恶意文件: {s['files']}", f"  持久化后门: {s['persistence']}", f"  ClamAV 命中: {s['clamav']}", f"  未授权 SSH 公钥: {s['untrusted_keys']}", f"  已删除公钥: {s['keys_removed']}", f"  已修复 .ssh: {s['ssh_repairs']}", f"  已隔离文件: {s['quarantined']}", f"  已永久删除文件: {s['deleted']}", "", "系统目录中的文件不会被脚本自动删除；发现入侵后建议从可信镜像重装并轮换所有密钥。", "="*90, ""]
    return "\n".join(lines)


def write_reports(r: dict[str, Any], out: Path) -> tuple[Path, Path]:
    private_dir(out); stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    lp = out / f"linux-threat-cleanup-{stamp}.log"; jp = out / f"linux-threat-cleanup-{stamp}.json"
    text = text_report(r); data = json.dumps(r, ensure_ascii=False, indent=2) + "\n"
    lp.write_text(text, encoding="utf-8"); jp.write_text(data, encoding="utf-8")
    (out/"linux-threat-cleanup-latest.log").write_text(text, encoding="utf-8")
    (out/"linux-threat-cleanup-latest.json").write_text(data, encoding="utf-8")
    for p in (lp, jp, out/"linux-threat-cleanup-latest.log", out/"linux-threat-cleanup-latest.json"): os.chmod(p, 0o600)
    return lp, jp


def self_test() -> int:
    failures = []
    blob = b"test-key"; line = "ssh-ed25519 " + base64.b64encode(blob).decode()
    expected = "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
    if key_fingerprint(line) != expected: failures.append("SSH 指纹")
    with tempfile.TemporaryDirectory() as td:
        p = Path(td)/"xmrig"; p.write_bytes(b"\x7fELFstratum+tcp://pool:3333"); p.chmod(0o755)
        if score_file(p, 1024)["score"] < 10: failures.append("挖矿文件")
        b = Path(td)/"ok.sh"; b.write_text("#!/bin/sh\necho ok\n"); b.chmod(0o755)
        if score_file(b, 1024)["score"] >= 7: failures.append("正常脚本误报")
    if failures:
        print("SELF-TEST FAILED: " + ", ".join(failures)); return 1
    print("SELF-TEST PASSED"); return 0


def main() -> int:
    args = parse_args()
    if args.self_test: return self_test()
    if args.purge and (not args.remediate or not args.yes):
        print("--purge 必须同时使用 --remediate --yes", file=sys.stderr); return 2
    if args.restore_ssh_baseline and not args.remediate:
        print("--restore-ssh-baseline 必须与 --remediate 一起使用", file=sys.stderr); return 2
    if args.enforce_key_allowlist and not (args.allow_key or args.allow_key_file):
        print("--enforce-key-allowlist 需要白名单", file=sys.stderr); return 2
    if args.init_ssh_baseline: return init_baseline(args)
    if args.remediate and os.geteuid() != 0:
        print("修复模式必须使用 root", file=sys.stderr); return 2
    if os.geteuid() != 0: print("提示：非 root 运行，检测可能不完整", file=sys.stderr)
    private_dir(args.state_dir); private_dir(args.output_dir); private_dir(args.quarantine_dir)
    mode = "purge" if args.purge else ("remediate" if args.remediate else "audit")
    report: dict[str, Any] = {"schema_version": 1, "script_version": VERSION, "scan_time": now(), "hostname": os.uname().nodename, "mode": mode}
    report["ssh_login_ips"] = ssh_login_ips(args.since)
    report["process_scan"], exes = audit_processes(args)
    report["ssh_integrity"] = repair_ssh(args)
    report["persistence_scan"] = audit_persistence(args)
    report["file_scan"] = audit_files(args, exes)
    report["clamav_scan"] = clamav(args)
    report["summary"] = make_summary(report)
    lp, jp = write_reports(report, args.output_dir)
    s = report["summary"]
    print("="*72); print(s["verdict"]); print("SSH 登录 IP（去重）:")
    if report["ssh_login_ips"]["unique_ips"]:
        for ip in report["ssh_login_ips"]["unique_ips"]: print("  " + ip)
    else: print("  未检测出")
    print(f"可疑进程: {s['processes']}")
    print(f"持久化后门: {s['persistence']}")
    print(f"恶意文件: {s['files'] + s['clamav']}")
    print(f"未授权 SSH 公钥: {s['untrusted_keys']}")
    print(f"已删除公钥: {s['keys_removed']}")
    print(f"已修复 .ssh: {s['ssh_repairs']}")
    print(f"已隔离文件: {s['quarantined']}")
    print(f"已永久删除文件: {s['deleted']}")
    print(f"文本报告: {lp}"); print(f"JSON 报告: {jp}"); print("="*72)
    if s["detected_total"] and not args.remediate: return 10
    if s["detected_total"] and args.remediate: return 11
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
