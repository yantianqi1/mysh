#!/usr/bin/env bash
set -e

echo "=== Dante SOCKS5 一键部署脚本（最终正确版：含 socksmethod + 自动兼容容器/NAMESPACE）==="

# --------- root check ----------
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行（sudo）"
  exit 1
fi

# --------- defaults ----------
DEFAULT_PORT=1080
DEFAULT_USER=proxyuser

# --------- env vars for non-interactive ----------
MACHINE="${MACHINE_TYPE:-}"       # nat | vps
MODE="${AUTH_MODE:-}"             # auth | noauth
PORT="${PROXY_PORT:-}"
USER_NAME="${PROXY_USER:-}"
PASS_WORD="${PROXY_PASS:-}"
PUBLIC_IP_OVERRIDE="${PUBLIC_IP:-}"  # optional
EXTERNAL_PORT="${EXTERNAL_PORT:-}"   # optional for NAT final URL display

# --------- tty detect ----------
HAS_TTY=0
if [[ -t 0 && -t 1 ]]; then
  HAS_TTY=1
fi

# --------- iface detect ----------
IFACE=$(ip route | awk '/default/ {print $5; exit}')
IFACE=${IFACE:-eth0}

read_choice() {
  local prompt="$1"
  local default="$2"
  local var
  read -r -p "$prompt" var
  var="${var:-$default}"
  echo "$var"
}

# --------- choose machine ----------
if [[ -z "$MACHINE" ]]; then
  if [[ "$HAS_TTY" -eq 1 ]]; then
    echo "请选择机器类型："
    echo "  1) VPS（独立公网 IP）"
    echo "  2) NAT（需要端口映射）"
    c=$(read_choice "选择 [默认 2]: " "2")
    [[ "$c" == "1" ]] && MACHINE="vps" || MACHINE="nat"
  else
    MACHINE="nat"
  fi
fi
if [[ "$MACHINE" != "vps" && "$MACHINE" != "nat" ]]; then
  echo "MACHINE_TYPE 只能是 vps 或 nat"
  exit 1
fi

# --------- choose auth mode ----------
if [[ -z "$MODE" ]]; then
  if [[ "$HAS_TTY" -eq 1 ]]; then
    echo "是否启用用户名密码？"
    echo "  1) 启用（安全，推荐）"
    echo "  2) 不启用（仅 socks5h://host:port）"
    c=$(read_choice "选择 [默认 2]: " "2")
    [[ "$c" == "1" ]] && MODE="auth" || MODE="noauth"
  else
    MODE="noauth"
  fi
fi
if [[ "$MODE" != "auth" && "$MODE" != "noauth" ]]; then
  echo "AUTH_MODE 只能是 auth 或 noauth"
  exit 1
fi

# --------- choose port ----------
if [[ -z "$PORT" ]]; then
  if [[ "$HAS_TTY" -eq 1 ]]; then
    PORT=$(read_choice "SOCKS5 监听端口 [默认 ${DEFAULT_PORT}]: " "${DEFAULT_PORT}")
  else
    PORT="${DEFAULT_PORT}"
  fi
fi

# --------- auth creds ----------
if [[ "$MODE" == "auth" ]]; then
  if [[ -z "$USER_NAME" ]]; then
    if [[ "$HAS_TTY" -eq 1 ]]; then
      USER_NAME=$(read_choice "代理用户名 [默认 ${DEFAULT_USER}]: " "${DEFAULT_USER}")
    else
      USER_NAME="${DEFAULT_USER}"
    fi
  fi

  if [[ -z "$PASS_WORD" ]]; then
    if [[ "$HAS_TTY" -eq 1 ]]; then
      echo -n "代理密码（输入时不显示）："
      stty -echo
      read -r PASS_WORD
      stty echo
      echo
      if [[ -z "$PASS_WORD" ]]; then
        echo "密码不能为空"
        exit 1
      fi
    else
      echo "无交互模式下请用 PROXY_PASS 提供密码"
      echo "示例：AUTH_MODE=auth PROXY_USER=xx PROXY_PASS='yy' curl ... | sudo -E bash"
      exit 1
    fi
  fi
fi

# --------- install ----------
echo "[1/6] 安装 dante-server"
export DEBIAN_FRONTEND=noninteractive
apt update -y >/dev/null
apt install -y dante-server curl >/dev/null

# --------- create user if auth ----------
if [[ "$MODE" == "auth" ]]; then
  echo "[2/6] 创建/更新代理用户"
  id "$USER_NAME" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$USER_NAME"
  echo "$USER_NAME:$PASS_WORD" | chpasswd
else
  echo "[2/6] 无密码模式：跳过创建用户"
fi

# --------- write config (IMPORTANT: socksmethod!) ----------
echo "[3/6] 写入配置文件 /etc/danted.conf"

if [[ "$MODE" == "auth" ]]; then
cat >/etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = $PORT
external: $IFACE

# 连接到 danted 的认证方式
method: username
# SOCKS5 本身认证方式（关键字段）
socksmethod: username

user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  command: connect
}
EOF
else
cat >/etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = $PORT
external: $IFACE

# 连接到 danted：不认证
method: none
# SOCKS5 本身：不认证（关键字段，否则会卡住）
socksmethod: none

user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
  command: connect
}
EOF
fi

# --------- start strategy ----------
echo "[4/6] 启动 danted（自动兼容 systemd NAMESPACE 限制）"

start_ok=0
start_mode=""

# try systemd
if command -v systemctl >/dev/null 2>&1; then
  systemctl stop danted 2>/dev/null || true
  if systemctl restart danted 2>/dev/null; then
    if systemctl is-active --quiet danted 2>/dev/null; then
      start_ok=1
      start_mode="systemd"
      systemctl enable danted >/dev/null 2>&1 || true
    fi
  fi
fi

# fallback: nohup + @reboot
if [[ "$start_ok" -ne 1 ]]; then
  pkill danted 2>/dev/null || true
  nohup /usr/sbin/danted -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &
  sleep 0.5
  start_mode="nohup"

  ( crontab -l 2>/dev/null; echo "@reboot nohup /usr/sbin/danted -f /etc/danted.conf >/var/log/danted.nohup.log 2>&1 &" ) | crontab -
  start_ok=1
fi

# --------- verify ----------
echo "[5/6] 检查监听端口"
if ss -lntp | grep -q ":${PORT}"; then
  echo "✅ 已监听：0.0.0.0:${PORT} （启动方式：${start_mode}）"
else
  echo "❌ 未监听端口 ${PORT}"
  echo "排查："
  echo "  cat /etc/danted.conf"
  echo "  journalctl -xeu danted.service --no-pager | tail -n 80"
  echo "  tail -n 80 /var/log/danted.nohup.log"
  exit 1
fi

# --------- compute public ip ----------
if [[ -n "$PUBLIC_IP_OVERRIDE" ]]; then
  PUBIP="$PUBLIC_IP_OVERRIDE"
else
  PUBIP="$(curl -s --max-time 5 ifconfig.me || true)"
  PUBIP="${PUBIP:-<公网IP>}"
fi

# --------- output final url ----------
echo "[6/6] 输出最终可用地址"
echo
echo "================= 完 成 ================="
echo "机器类型：$MACHINE"
echo "认证模式：$MODE"
echo "内部监听：0.0.0.0:${PORT}"
echo "出口网卡：${IFACE}"
echo "启动方式：${start_mode}"
echo

if [[ "$MACHINE" == "nat" ]]; then
  echo "⚠️ NAT 机器：请在商家后台做端口映射：外部端口 -> ${PORT} (TCP)"
  if [[ -z "$EXTERNAL_PORT" ]]; then
    echo "提示：设置 EXTERNAL_PORT=外部端口，可直接输出最终一行地址（外部端口）。"
  fi
fi

echo
echo "✅ 推荐给项目使用（DNS 走代理）："
# socks5h is safer in practice (remote DNS)
if [[ "$MODE" == "auth" ]]; then
  if [[ "$MACHINE" == "nat" && -n "$EXTERNAL_PORT" ]]; then
    echo "socks5h://${USER_NAME}:${PASS_WORD}@${PUBIP}:${EXTERNAL_PORT}"
  else
    echo "socks5h://${USER_NAME}:${PASS_WORD}@${PUBIP}:${PORT}"
  fi
else
  if [[ "$MACHINE" == "nat" && -n "$EXTERNAL_PORT" ]]; then
    echo "socks5h://${PUBIP}:${EXTERNAL_PORT}"
  else
    echo "socks5h://${PUBIP}:${PORT}"
  fi
fi

echo
echo "✅ 兼容写法（部分程序只认 socks5）："
if [[ "$MODE" == "auth" ]]; then
  if [[ "$MACHINE" == "nat" && -n "$EXTERNAL_PORT" ]]; then
    echo "socks5://${USER_NAME}:${PASS_WORD}@${PUBIP}:${EXTERNAL_PORT}"
  else
    echo "socks5://${USER_NAME}:${PASS_WORD}@${PUBIP}:${PORT}"
  fi
else
  if [[ "$MACHINE" == "nat" && -n "$EXTERNAL_PORT" ]]; then
    echo "socks5://${PUBIP}:${EXTERNAL_PORT}"
  else
    echo "socks5://${PUBIP}:${PORT}"
  fi
fi
echo "========================================"
