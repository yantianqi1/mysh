#!/usr/bin/env bash
set -e

echo "=== Dante SOCKS5 一键部署脚本（最终稳定版）==="

# ---------- 基础检测 ----------
if [[ $EUID -ne 0 ]]; then
  echo "请使用 root 运行（sudo）"
  exit 1
fi

# ---------- 默认值 ----------
DEFAULT_PORT=1080
DEFAULT_USER=proxyuser

# ---------- 环境变量（用于 curl | bash） ----------
MACHINE="${MACHINE_TYPE:-}"
MODE="${AUTH_MODE:-}"
PORT="${PROXY_PORT:-}"
USER_NAME="${PROXY_USER:-}"
PASS_WORD="${PROXY_PASS:-}"

# ---------- 判断是否有交互终端 ----------
HAS_TTY=0
if [[ -t 0 && -t 1 ]]; then
  HAS_TTY=1
fi

# ---------- 获取网卡 ----------
IFACE=$(ip route | awk '/default/ {print $5; exit}')
IFACE=${IFACE:-eth0}

# ---------- 选择机器类型 ----------
if [[ -z "$MACHINE" ]]; then
  if [[ "$HAS_TTY" -eq 1 ]]; then
    echo "请选择机器类型："
    echo "  1) VPS（独立公网 IP）"
    echo "  2) NAT（需要端口映射）"
    read -r -p "选择 [默认 2]: " c
    c=${c:-2}
    [[ "$c" == "1" ]] && MACHINE="vps" || MACHINE="nat"
  else
    MACHINE="nat"
  fi
fi

# ---------- 选择认证模式 ----------
if [[ -z "$MODE" ]]; then
  if [[ "$HAS_TTY" -eq 1 ]]; then
    echo "是否启用用户名密码？"
    echo "  1) 启用（安全）"
    echo "  2) 不启用（仅 socks5://host:port）"
    read -r -p "选择 [默认 2]: " c
    c=${c:-2}
    [[ "$c" == "1" ]] && MODE="auth" || MODE="noauth"
  else
    MODE="noauth"
  fi
fi

# ---------- 端口 ----------
if [[ -z "$PORT" ]]; then
  if [[ "$HAS_TTY" -eq 1 ]]; then
    read -r -p "SOCKS5 监听端口 [默认 ${DEFAULT_PORT}]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}
  else
    PORT=$DEFAULT_PORT
  fi
fi

# ---------- 用户名密码 ----------
if [[ "$MODE" == "auth" ]]; then
  if [[ -z "$USER_NAME" ]]; then
    USER_NAME=$DEFAULT_USER
  fi

  if [[ -z "$PASS_WORD" ]]; then
    if [[ "$HAS_TTY" -eq 1 ]]; then
      echo -n "代理密码："
      stty -echo
      read -r PASS_WORD
      stty echo
      echo
    else
      echo "❌ 无交互模式下请使用 PROXY_PASS 指定密码"
      exit 1
    fi
  fi
fi

# ---------- 安装 ----------
echo "[1/4] 安装 dante-server"
apt update -y >/dev/null
apt install -y dante-server curl >/dev/null

# ---------- 用户 ----------
if [[ "$MODE" == "auth" ]]; then
  id "$USER_NAME" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$USER_NAME"
  echo "$USER_NAME:$PASS_WORD" | chpasswd
fi

# ---------- 配置 ----------
echo "[2/4] 写入配置文件"
if [[ "$MODE" == "auth" ]]; then
cat >/etc/danted.conf <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $PORT
external: $IFACE
method: username
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
}
EOF
else
cat >/etc/danted.conf <<EOF
logoutput: syslog
internal: 0.0.0.0 port = $PORT
external: $IFACE
method: none
user.notprivileged: nobody

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
}

pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  protocol: tcp
}
EOF
fi

# ---------- 启动 ----------
echo "[3/4] 启动服务"
systemctl restart danted
systemctl enable danted >/dev/null

# ---------- 结果 ----------
PUBLIC_IP=$(curl -s ifconfig.me || echo "<公网IP>")

echo
echo "================= 完 成 ================="
echo "机器类型：$MACHINE"
echo "认证模式：$MODE"
echo "监听端口：$PORT"
echo

if [[ "$MACHINE" == "nat" ]]; then
  echo "⚠️ NAT 机器：请在商家后台映射 外部端口 → $PORT (TCP)"
fi

echo
if [[ "$MODE" == "auth" ]]; then
  echo "✅ 最终代理地址："
  echo "socks5://$USER_NAME:$PASS_WORD@$PUBLIC_IP:<端口>"
else
  echo "✅ 最终代理地址："
  echo "socks5://$PUBLIC_IP:<端口>"
fi
echo "========================================"
