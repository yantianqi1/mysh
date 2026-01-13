#!/usr/bin/env bash
set -euo pipefail

# ========== Helpers ==========
need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "请用 root 运行：sudo bash $0" >&2
    exit 1
  fi
}

has_tty() { [[ -t 0 && -t 1 ]]; }

read_default() {
  local prompt="$1" default="$2" v=""
  if has_tty; then
    read -r -p "${prompt} [默认 ${default}]: " v
    echo "${v:-$default}"
  else
    echo "$default"
  fi
}

read_required() {
  local prompt="$1" v=""
  if ! has_tty; then
    echo "非交互模式下缺少必填项：${prompt}" >&2
    exit 1
  fi
  while true; do
    read -r -p "${prompt}: " v
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  done
}

read_secret() {
  local prompt="$1" v=""
  if ! has_tty; then
    echo "非交互模式下无法安全输入密码，请用环境变量 PROXY_PASS 提供。" >&2
    exit 1
  fi
  while true; do
    echo -n "${prompt}（输入不显示）: "
    stty -echo
    read -r v
    stty echo
    echo
    [[ -n "$v" ]] && { echo "$v"; return 0; }
  done
}

detect_iface() {
  local iface
  iface="$(ip route | awk '/default/ {print $5; exit}')"
  echo "${iface:-eth0}"
}

detect_public_ip() {
  curl -s --max-time 5 ifconfig.me 2>/dev/null || true
}

kill_existing_danted() {
  # 尽量彻底，避免端口被旧进程占用
  pkill -9 -x danted 2>/dev/null || true
  pkill -9 -f "/usr/sbin/danted .* -f /etc/danted.conf" 2>/dev/null || true
  sleep 1
}

ensure_cron_reboot() {
  # 去重后再加，避免重复条目
  local line="@reboot nohup /usr/sbin/danted -D -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &"
  ( crontab -l 2>/dev/null | grep -vF "/usr/sbin/danted -D -f /etc/danted.conf" || true
    echo "$line"
  ) | crontab -
}

start_danted_auto() {
  local start_mode=""
  local ok=0

  # 先试 systemd（如果能用就用）
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop danted 2>/dev/null || true
    if systemctl restart danted 2>/dev/null; then
      if systemctl is-active --quiet danted 2>/dev/null; then
        ok=1
        start_mode="systemd"
        systemctl enable danted >/dev/null 2>&1 || true
      fi
    fi
  fi

  # systemd 不行就 fallback 到 nohup（适配 NAMESPACE/LXC）
  if [[ "$ok" -ne 1 ]]; then
    kill_existing_danted
    nohup /usr/sbin/danted -D -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &
    ensure_cron_reboot
    start_mode="nohup"
  fi

  echo "$start_mode"
}

verify_listen() {
  local port="$1"
  ss -lntp | grep -q ":${port}" || return 1
}

# ========== Main ==========
need_root

DEFAULT_PORT="${DEFAULT_PORT:-1080}"
DEFAULT_USER="${DEFAULT_USER:-proxyuser}"

# env for non-interactive (optional)
MACHINE_TYPE="${MACHINE_TYPE:-}"   # nat|vps
AUTH_MODE="${AUTH_MODE:-}"         # noauth|auth
PROXY_PORT="${PROXY_PORT:-}"
EXTERNAL_PORT="${EXTERNAL_PORT:-}" # nat 外部端口（你要的一行地址用这个）
PUBLIC_IP="${PUBLIC_IP:-}"         # 可选：手动指定公网IP/域名
PROXY_USER="${PROXY_USER:-}"
PROXY_PASS="${PROXY_PASS:-}"

IFACE="$(detect_iface)"

# 1) 机器类型
if [[ -z "$MACHINE_TYPE" ]]; then
  if has_tty; then
    echo "请选择机器类型："
    echo "  1) VPS（独立公网 IP）"
    echo "  2) NAT（需要端口映射）"
    c="$(read_default "选择" "2")"
    [[ "$c" == "1" ]] && MACHINE_TYPE="vps" || MACHINE_TYPE="nat"
  else
    MACHINE_TYPE="nat"
  fi
fi
[[ "$MACHINE_TYPE" == "vps" || "$MACHINE_TYPE" == "nat" ]] || { echo "MACHINE_TYPE 只能是 vps 或 nat" >&2; exit 1; }

# 2) 认证模式
if [[ -z "$AUTH_MODE" ]]; then
  if has_tty; then
    echo "是否启用用户名密码？"
    echo "  1) 启用（更安全）"
    echo "  2) 不启用（直接 socks5h://host:port）"
    c="$(read_default "选择" "2")"
    [[ "$c" == "1" ]] && AUTH_MODE="auth" || AUTH_MODE="noauth"
  else
    AUTH_MODE="noauth"
  fi
fi
[[ "$AUTH_MODE" == "auth" || "$AUTH_MODE" == "noauth" ]] || { echo "AUTH_MODE 只能是 auth 或 noauth" >&2; exit 1; }

# 3) 内部监听端口
if [[ -z "$PROXY_PORT" ]]; then
  PROXY_PORT="$(read_default "SOCKS5 内部监听端口" "$DEFAULT_PORT")"
fi

# 4) NAT 外部端口（你要的“一行地址”关键）
#    - NAT 必问（默认等于内部端口，但建议你输入面板外部端口如 11111）
#    - VPS 可选（默认=内部端口）
if [[ "$MACHINE_TYPE" == "nat" ]]; then
  if [[ -z "$EXTERNAL_PORT" ]]; then
    EXTERNAL_PORT="$(read_required "请输入【外部转发端口】（面板外部端口，如 11111）")"
  fi
else
  if [[ -z "$EXTERNAL_PORT" ]]; then
    EXTERNAL_PORT="$PROXY_PORT"
  fi
fi

# 5) 公网IP/域名（默认自动检测）
if [[ -z "$PUBLIC_IP" ]]; then
  if has_tty; then
    ip_guess="$(detect_public_ip)"
    PUBLIC_IP="$(read_default "请输入公网IP/域名（直接回车=自动检测）" "${ip_guess:-<公网IP>}")"
  else
    PUBLIC_IP="$(detect_public_ip)"
    PUBLIC_IP="${PUBLIC_IP:-<公网IP>}"
  fi
fi

# 6) 账号密码（如果需要）
if [[ "$AUTH_MODE" == "auth" ]]; then
  [[ -n "$PROXY_USER" ]] || PROXY_USER="$(read_default "代理用户名" "$DEFAULT_USER")"
  [[ -n "$PROXY_PASS" ]] || PROXY_PASS="$(read_secret "代理密码")"
fi

# 安装
export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null
apt install -y dante-server curl >/dev/null

# 写配置（✅ 关键：clientmethod/socksmethod + socks pass）
if [[ "$AUTH_MODE" == "auth" ]]; then
  id "$PROXY_USER" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$PROXY_USER"
  echo "${PROXY_USER}:${PROXY_PASS}" | chpasswd

  cat >/etc/danted.conf <<EOF
logoutput: stderr

internal: 0.0.0.0 port = ${PROXY_PORT}
external: ${IFACE}

clientmethod: username
socksmethod: username

user.privileged: root
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  command: connect
}
EOF
else
  cat >/etc/danted.conf <<EOF
logoutput: stderr

internal: 0.0.0.0 port = ${PROXY_PORT}
external: ${IFACE}

clientmethod: none
socksmethod: none

user.privileged: root
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  command: connect
}
EOF
fi

# 启动前先清旧进程，避免端口占用
kill_existing_danted

# 启动（systemd 不行就 nohup）
START_MODE="$(start_danted_auto)"

# 校验监听
if ! verify_listen "$PROXY_PORT"; then
  echo "启动失败：未监听端口 ${PROXY_PORT}" >&2
  echo "日志：tail -n 120 /var/log/danted.nohup.log" >&2
  exit 1
fi

# ====== 最终输出：只输出一行地址（方便复制）======
if [[ "$AUTH_MODE" == "auth" ]]; then
  echo "socks5h://${PROXY_USER}:${PROXY_PASS}@${PUBLIC_IP}:${EXTERNAL_PORT}"
else
  echo "socks5h://${PUBLIC_IP}:${EXTERNAL_PORT}"
fi

# 额外：你需要排查时再看这个文件（默认不打印）
# /var/log/danted.nohup.log
